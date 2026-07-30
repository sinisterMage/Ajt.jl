//! `Pkg.is_manifest_current` and `Pkg.upgrade_manifest` — the two public Pkg
//! entry points that are about the manifest FILE and never about the depot.
//!
//! ### `is_manifest_current`
//!
//! `Operations.is_manifest_current(env)` (`Operations.jl:3068-3077`) is nine
//! lines and returns **three** values, which is the whole reason it exists:
//!
//! ```julia
//! if haskey(env.manifest.other, "project_hash")
//!     return env.manifest.other["project_hash"] == Types.workspace_resolve_hash(env)
//! else
//!     return nothing        # "no hash recorded" — not `false`
//! end
//! ```
//!
//! Four situations reach `nothing` rather than `false`, and only the first is
//! obvious:
//!
//!  1. The manifest has no `project_hash` key. Anything Pkg wrote before 1.7,
//!     or a hand edit that dropped the line.
//!  2. **There is no manifest file at all.** `read_manifest` returns a bare
//!     `Manifest()` for a path that is not a file (`manifest.jl:245-250`), and
//!     an empty `Manifest` has an empty `other` — so a project with no manifest
//!     beside it answers `nothing`, not `false`. `Pkg.is_manifest_current`'s
//!     own docstring says so (`Pkg.jl:809`).
//!  3. **A v1 manifest.** `convert_v1_format_manifest` (`manifest.jl:257-263`)
//!     moves the whole old root under `"deps"` and leaves only
//!     `manifest_format` beside it, both of which `Manifest(raw, …)` excludes
//!     from `other` (`:235-241`). A `project_hash` key in a v1 file is a
//!     *package named `project_hash`*, not a top-level hash, so it can never
//!     surface here.
//!  4. **An empty manifest file**, which `read_manifest` promotes to v2 for
//!     convenience (`:257-261`) — still no `project_hash`.
//!
//! `false` therefore means one specific thing: a hash is recorded and it does
//! not match. Collapsing `nothing` into it would turn "I was never told" into
//! "the environment is stale", and `Pkg` itself relies on the difference — both
//! internal callers test `=== false` (`API.jl:1321` in `instantiate`,
//! `Operations.jl:3059` in `status`), so `nothing` means *carry on*.
//!
//! The comparison itself is not duplicated here: it is `verify.compareProjectHash`,
//! the same code `ajt verify`'s phase 3 runs. `verify` answers a superset
//! question and deliberately treats `nothing` as a failure; this module reports
//! it as `nothing`, which is what makes the two commands different rather than
//! redundant.
//!
//! ### `upgrade_manifest`
//!
//! `API.jl:1715-1726`, and it does *less* than its name suggests — worth
//! stating because the obvious guesses are all wrong:
//!
//!  * it does **not** re-record `project_hash` (a v1 manifest has none, and the
//!    upgraded file still has none — `Pkg.resolve()` is what records one, which
//!    is exactly what the printed follow-up advice says at `manifest.jl:385`);
//!  * it does **not** prune, re-resolve, or touch a single entry;
//!  * it does **not** record `julia_version` either (`convert_v1_format_manifest`
//!    deliberately leaves it unset: "it is unknown in old manifests");
//!  * on an **already-v2** manifest it raises — it is not idempotent, and a
//!    caller running it twice gets an error, not a no-op.
//!
//! All it changes is `manifest_format`, from `1.0` to `2.0`, and then rewrites
//! the file through the ordinary writer. Everything else in the output is a
//! consequence of `destructure` re-emitting the same entries under the v2
//! layout. `model/manifest.zig` already reads and writes both layouts, so the
//! whole of the port is the three-way branch on the recorded format plus a
//! write.
//!
//! The version test is EXACT-equality on a `VersionNumber`, not a major
//! comparison (`before_format == v"2.0"` / `!= v"1.0"`), so `manifest_format =
//! "1.1"` and `"2.1"` are both "unrecognized" and neither is upgraded. That is
//! reproduced rather than smoothed over: Ajt refusing a file Pkg refuses costs
//! nothing, and Ajt rewriting a file Pkg refuses is a layout nobody has agreed
//! on.
//!
//! ### Allocation
//!
//! `isCurrent` takes an **arena** for everything the `Answer` borrows and a
//! `scratch` allocator for the digest. `upgrade` additionally takes a `gpa`,
//! because `writeIfChanged` renders the whole file into a child arena of it and
//! frees it again — handing it the report arena would retain a second copy of
//! the manifest for no reason.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const verify = @import("verify.zig");
const instantiate = @import("instantiate.zig");

pub const Currency = verify.Currency;
pub const Version = manifest_mod.Version;

/// `manifest_format = "2.0"`, the only version `upgrade_manifest` ever writes
/// (`API.jl:1723`).
pub const format_v2: Version = .{ .major = 2, .minor = 0, .patch = 0 };
/// The only version it upgrades FROM (`API.jl:1720`).
pub const format_v1: Version = .{ .major = 1, .minor = 0, .patch = 0 };

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

pub const Error = error{
    /// `projectfile_path(path, strict = true) === nothing` — Pkg raises
    /// "could not find project file at `$path`" (`API.jl:567-570`).
    ProjectNotFound,
    ProjectUnreadable,
    ProjectInvalid,
    /// `workspace_resolve_hash` digests EVERY project in a workspace
    /// (`Types.jl:645-666`) and `EnvCache` redirects the manifest to the
    /// workspace root (`Types.jl:411-419`). Ajt's `project_hash.compute` covers
    /// one project, so a workspace would get a confident wrong answer. Same
    /// refusal `verify` makes, for the same reason.
    WorkspaceUnsupported,
    ManifestUnreadable,
    ManifestInvalid,
    /// `upgrade` only: the file parsed and the migration was legal, but the
    /// rewrite failed. Distinct from `ManifestUnreadable` because the two mean
    /// opposite things to a caller — nothing was changed either way, but only
    /// this one says the manifest itself was fine.
    ManifestUnwritable,
    /// `upgrade` only: `manifest_format` is already exactly `2.0`.
    AlreadyUpToDate,
    /// `upgrade` only: `manifest_format` is neither exactly `1.0` nor `2.0`.
    UnrecognizedFormat,
} || Allocator.Error;

/// Why a call failed, in the words a person should read. Filled in on error
/// only; `message` is arena-owned or static.
pub const Diagnostic = struct {
    message: []const u8 = "",
    /// The file the failure is about.
    file: []const u8 = "",

    fn set(self: ?*Diagnostic, file: []const u8, message: []const u8) void {
        const d = self orelse return;
        d.file = file;
        d.message = message;
    }
};

pub const Options = struct {
    /// The environment: a directory, or a project file directly.
    env_path: []const u8,
    /// Overrides manifest discovery entirely.
    manifest_file: ?[]const u8 = null,
    /// Only ever used to pick between `Manifest.toml` and the version-specific
    /// `Manifest-v<major>.<minor>.toml`; nothing here reads a depot.
    julia_prefix: ?[]const u8 = null,
    julia_version: ?[]const u8 = null,
};

pub const Answer = struct {
    /// Julia's `true` / `false` / `nothing`.
    currency: Currency,
    project_file: []const u8,
    /// The manifest Julia would read. Named even when it does not exist —
    /// which is one of the two ways to reach `.unknown`.
    manifest_file: []const u8,
    /// Present iff `currency != .unknown`.
    recorded: []const u8 = "",
    computed: []const u8 = "",
};

/// `Pkg.is_manifest_current(path)` (`API.jl:566-574`).
///
/// `path` is an environment: `projectfile_path` joins it with each of
/// `Base.project_names` and raises when none exists. Ajt additionally accepts a
/// project file directly, because `verify.locateProject` does and a superset
/// costs nothing here.
pub fn isCurrent(
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    opts: Options,
    diag: ?*Diagnostic,
) Error!Answer {
    const loc = try verify.locateProject(arena, io, opts.env_path);

    const project_src = Io.Dir.cwd().readFileAlloc(io, loc.project, arena, .limited(max_project_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // `strict = true`'s `nothing` and an unreadable file are two different
        // failures, and only the first is the one Pkg names.
        if (err == error.FileNotFound) {
            Diagnostic.set(diag, loc.project, "could not find project file");
            return error.ProjectNotFound;
        }
        Diagnostic.set(diag, loc.project, @errorName(err));
        return error.ProjectUnreadable;
    };

    var pdiag: project_mod.Diagnostic = .{};
    const project = project_mod.parse(arena, project_src, .{ .file = loc.project }, &pdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        Diagnostic.set(diag, loc.project, try arena.dupe(u8, pdiag.message()));
        return error.ProjectInvalid;
    };

    if (project.workspace_projects) |ws| {
        if (ws.len != 0) {
            Diagnostic.set(diag, loc.project, "project defines a [workspace]; workspace_resolve_hash digests every project in it");
            return error.WorkspaceUnsupported;
        }
    }

    const manifest_file = try verify.locateManifest(arena, io, .{
        .manifest_file = opts.manifest_file,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    }, loc, project.manifest);

    const manifest_src = try readManifestOrEmpty(arena, io, manifest_file, diag);

    var mdiag: manifest_mod.Diagnostic = .{};
    const manifest = manifest_mod.parse(arena, manifest_src, &mdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Julia raises here too: `pkgerror("Could not parse manifest: ", …)`.
        Diagnostic.set(diag, manifest_file, if (err == error.ParseFailed)
            try std.fmt.allocPrint(arena, "line {d}, column {d}: {s}", .{ mdiag.line, mdiag.column, mdiag.message })
        else
            @errorName(err));
        return error.ManifestInvalid;
    };

    const cmp = verify.compareProjectHash(arena, scratch, &project, manifest) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        Diagnostic.set(diag, loc.project, @errorName(err));
        return error.ProjectInvalid;
    };

    return .{
        .currency = cmp.answer,
        .project_file = loc.project,
        .manifest_file = manifest_file,
        .recorded = cmp.recorded,
        .computed = if (cmp.computed) |c| try arena.dupe(u8, &c) else "",
    };
}

pub const UpgradeOptions = struct {
    /// An environment directory, or a `Manifest.toml` directly — Pkg has one
    /// entry point for each (`upgrade_manifest(ctx)` and
    /// `upgrade_manifest(man_path::String)`), and the two differ only in which
    /// file they end up holding.
    path: []const u8,
    /// Report what would happen; write nothing.
    dry_run: bool = false,
    julia_prefix: ?[]const u8 = null,
    julia_version: ?[]const u8 = null,
};

pub const Upgrade = struct {
    manifest_file: []const u8,
    /// The `manifest_format` that was recorded. Always `1.0` on success.
    from: Version,
    to: Version = format_v2,
    entries: usize,
    /// False under `--dry-run`, and false if the rendered bytes were already
    /// what the file held — see `writeIfChanged`.
    written: bool,
};

/// `Pkg.upgrade_manifest` (`API.jl:1706-1726`).
///
/// The write goes through `ops/instantiate.zig`'s `writeIfChanged`: the same
/// render-to-a-temp-sibling-and-rename every other manifest write in Ajt uses,
/// so an interrupted upgrade cannot leave a half-written manifest, and an
/// upgrade that would produce the bytes already on disk moves no mtime. Pkg's
/// `write_manifest` is an unconditional `write(manifest_file, str)`
/// (`manifest.jl:400-405`).
pub fn upgrade(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: UpgradeOptions,
    diag: ?*Diagnostic,
) Error!Upgrade {
    const manifest_file = try resolveManifestPath(arena, io, opts, diag);

    // `upgrade_manifest(man_path)` copies the file and would raise from `cp`
    // for a path that is not there; `upgrade_manifest(ctx)` reaches
    // `read_manifest` on a missing `manifest_file` and gets an empty v2
    // `Manifest`, i.e. "already up to date". Both are reproduced:
    // `resolveManifestPath` has already refused a `path` that names nothing,
    // so a non-file here can only be the ctx-shaped case.
    const src = try readManifestOrEmpty(arena, io, manifest_file, diag);

    var mdiag: manifest_mod.Diagnostic = .{};
    var manifest = manifest_mod.parse(arena, src, &mdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        Diagnostic.set(diag, manifest_file, if (err == error.ParseFailed)
            try std.fmt.allocPrint(arena, "line {d}, column {d}: {s}", .{ mdiag.line, mdiag.column, mdiag.message })
        else
            @errorName(err));
        return error.ManifestInvalid;
    };

    // `API.jl:1717-1722`, exact-equality and in this order. Note that the
    // "already up to date" arm fires BEFORE the unrecognized one, so `2.0` gets
    // its own message; `2.0.1` does not.
    const before = manifest.format;
    if (eqVersion(before, format_v2)) {
        Diagnostic.set(diag, manifest_file, try std.fmt.allocPrint(
            arena,
            "Format of manifest file at `{s}` already up to date: manifest_format == {f}",
            .{ manifest_file, before },
        ));
        return error.AlreadyUpToDate;
    }
    if (!eqVersion(before, format_v1)) {
        Diagnostic.set(diag, manifest_file, try std.fmt.allocPrint(
            arena,
            "Format of manifest file at `{s}` version is unrecognized: manifest_format == {f}",
            .{ manifest_file, before },
        ));
        return error.UnrecognizedFormat;
    }

    // The whole of the migration (`API.jl:1723`). Everything else in the
    // rewritten file follows from `destructure` taking the major-2 branch:
    // `julia_version` and `project_hash` are still null and still omitted, and
    // `other` is empty because a v1 root is entirely deps.
    manifest.format = format_v2;

    const written = if (opts.dry_run)
        false
    else
        instantiate.writeIfChanged(gpa, io, &manifest, manifest_file, src) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            Diagnostic.set(diag, manifest_file, @errorName(err));
            return error.ManifestUnwritable;
        };

    return .{
        .manifest_file = manifest_file,
        .from = before,
        .entries = manifest.entries.len,
        .written = written,
    };
}

/// The manifest source, or the empty string when there is no manifest to read.
///
/// `read_manifest` (`manifest.jl:245-250`) is
/// `isfile(f_or_io) ? parse_toml(f_or_io) : return Manifest()`, and the
/// predicate is `isfile` — NOT "the open failed with ENOENT". The difference is
/// reachable: `locateManifest`'s non-strict fallback, a `--manifest` argument
/// and a `manifest = "…"` redirect can all land on a DIRECTORY named
/// `Manifest.toml`, where Julia answers `nothing` (or "already up to date") and
/// an ENOENT-keyed reader would raise `IsDir` instead. Keying on `isFile` first
/// is the same test Julia makes, in the same order.
///
/// An empty source is not a special case downstream: `fromToml` already maps an
/// empty table to `read_manifest`'s "treat an empty Manifest file as v2 format
/// for convenience" (`:257-261`), so there is one code path, not two.
fn readManifestOrEmpty(
    arena: Allocator,
    io: Io,
    manifest_file: []const u8,
    diag: ?*Diagnostic,
) Error![]const u8 {
    if (!verify.isFile(io, manifest_file)) return "";
    return Io.Dir.cwd().readFileAlloc(io, manifest_file, arena, .limited(max_manifest_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // It WAS a file a moment ago, so this is a permission problem, a race,
        // or a manifest past `max_manifest_bytes` — all of which Julia would
        // raise on too.
        Diagnostic.set(diag, manifest_file, @errorName(err));
        return error.ManifestUnreadable;
    };
}

/// Which file `upgrade` is about. A directory is an environment and gets the
/// full `EnvCache` treatment — including the `manifest = "…"` redirect a
/// project may declare, which is the difference between upgrading the file
/// Julia reads and upgrading one nobody does. Anything else is taken as the
/// manifest itself.
fn resolveManifestPath(
    arena: Allocator,
    io: Io,
    opts: UpgradeOptions,
    diag: ?*Diagnostic,
) Error![]const u8 {
    if (!verify.isDir(io, opts.path)) {
        if (verify.isFile(io, opts.path)) return opts.path;
        Diagnostic.set(diag, opts.path, "no such file or directory");
        return error.ManifestUnreadable;
    }

    const loc = try verify.locateProject(arena, io, opts.path);
    // The redirect is the only thing the project is read for, and a project
    // that cannot be read is not a reason to refuse: `upgrade_manifest` on a
    // bare directory of manifests is a legitimate use, and Julia's own
    // `Pkg.activate(tmpdir)` path runs with no project file at all
    // (`API.jl:1706-1713`).
    const redirect: ?[]const u8 = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, loc.project, arena, .limited(max_project_bytes)) catch break :blk null;
        const p = project_mod.parse(arena, src, .{ .file = loc.project }, null) catch break :blk null;
        break :blk p.manifest;
    };
    return verify.locateManifest(arena, io, .{
        .manifest_file = null,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    }, loc, redirect);
}

/// `VersionNumber` equality, which is what `API.jl:1717-1720` tests. All three
/// components, so `2.0.1` is not `v"2.0"`.
fn eqVersion(a: Version, b: Version) bool {
    return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
}

// ---------------------------------------------------------------------------
// Tests
//
// The oracle for every expected value here is a real `julia`, run by
// `tools/diff_harness/manifest_ops.sh`: `Pkg.is_manifest_current` must agree on
// all three answers, and `Pkg.upgrade_manifest` must produce the same bytes for
// a real v1 manifest out of the depot. What lives here is the hermetic half —
// the branch structure, on fixtures small enough to reason about.
// ---------------------------------------------------------------------------

const testing = std.testing;
const fspath = std.fs.path;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(buf: []u8) !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .root = "",
        };
        const n = try f.tmp.dir.realPath(testing.io, buf);
        f.root = buf[0..n];
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (fspath.dirname(sub_path)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn join(self: *Fixture, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(self.arena(), self.root);
        try all.appendSlice(self.arena(), parts);
        return fspath.join(self.arena(), all.items);
    }

    fn read(self: *Fixture, sub_path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, self.arena(), .limited(1 << 20));
    }

    const project_src =
        \\name = "Fixture"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\
        \\[deps]
        \\LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
    ;

    /// The project, plus its true `project_hash` computed by the same function
    /// `verify` compares against (itself pinned to
    /// `Pkg.Types.workspace_resolve_hash` by `julia/project_hash.zig`'s own
    /// differential test).
    fn writeProject(self: *Fixture) ![40]u8 {
        try self.write("env/Project.toml", project_src);
        const doc = try @import("../toml/parse.zig").parse(self.arena(), project_src, null);
        return @import("../julia/project_hash.zig").compute(self.arena(), doc.root);
    }
};

test "a manifest recording the project's own hash is current" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const hash = try f.writeProject();
    try f.write("env/Manifest.toml", try std.fmt.allocPrint(f.arena(),
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "{s}"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
    , .{&hash}));

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.current, a.currency);
    try testing.expectEqualStrings(&hash, a.recorded);
    try testing.expectEqualStrings(&hash, a.computed);
}

test "a hash that is recorded but wrong is FALSE, and reports both values" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const hash = try f.writeProject();
    try f.write("env/Manifest.toml",
        \\manifest_format = "2.0"
        \\project_hash = "0000000000000000000000000000000000000000"
        \\
    );

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.stale, a.currency);
    try testing.expectEqualStrings("0000000000000000000000000000000000000000", a.recorded);
    try testing.expectEqualStrings(&hash, a.computed);
}

test "no project_hash key is NOTHING, not false, and the digest is never taken" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeProject();
    try f.write("env/Manifest.toml",
        \\manifest_format = "2.0"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
    );

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.unknown, a.currency);
    // Julia's `else` branch never calls `workspace_resolve_hash`; reporting a
    // computed value here would be reporting one it never took.
    try testing.expectEqualStrings("", a.computed);
}

test "no manifest file at all is NOTHING, and names the file Julia would read" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeProject();
    // Deliberately no Manifest.toml.

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.unknown, a.currency);
    try testing.expect(std.mem.endsWith(u8, a.manifest_file, "Manifest.toml"));
}

test "a v1 manifest is NOTHING: its root is all deps, so it has no top-level hash" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeProject();
    // `project_hash` here is a PACKAGE NAME in the v1 layout, which is exactly
    // the confusion `convert_v1_format_manifest` makes impossible.
    try f.write("env/Manifest.toml",
        \\[[LinearAlgebra]]
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
    );

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.unknown, a.currency);
}

test "a DIRECTORY named Manifest.toml is NOTHING, because the predicate is isfile" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeProject();
    // `read_manifest` is `isfile(f_or_io) ? parse_toml(...) : return Manifest()`
    // (`manifest.jl:245-250`). Keying the empty case on ENOENT instead would
    // raise `IsDir` here, where Julia answers `nothing`.
    try f.tmp.dir.createDirPath(testing.io, "env/Manifest.toml");

    const a = try isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, null);
    try testing.expectEqual(Currency.unknown, a.currency);

    // And `upgrade` sees the same empty v2 manifest Pkg's ctx form sees, so it
    // refuses with Pkg's "already up to date" rather than an IO error.
    var diag: Diagnostic = .{};
    try testing.expectError(error.AlreadyUpToDate, upgrade(testing.allocator, f.arena(), testing.io, .{
        .path = try f.join(&.{"env"}),
    }, &diag));
}

test "no project file is an error, not an answer" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    try f.write("env/README", "");
    var diag: Diagnostic = .{};
    const err = isCurrent(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
    }, &diag);
    try testing.expectError(error.ProjectNotFound, err);
    try testing.expect(std.mem.indexOf(u8, diag.message, "project file") != null);
}

test "a v1 manifest upgrades to the v2 layout and nothing else changes" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    // The shape of a real one: root arrays, an array-form `deps`, a stdlib
    // entry with only a uuid.
    try f.write("env/Manifest.toml",
        \\# This file is machine-generated - editing it directly is not advised
        \\
        \\[[Dates]]
        \\deps = ["Printf"]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
        \\[[Printf]]
        \\uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
        \\
    );

    const path = try f.join(&.{ "env", "Manifest.toml" });
    const up = try upgrade(testing.allocator, f.arena(), testing.io, .{ .path = path }, null);
    try testing.expect(up.written);
    try testing.expectEqual(@as(usize, 2), up.entries);
    try testing.expectEqual(@as(u64, 1), up.from.major);

    // `manifest_format = "2.0"` and NOTHING else at the top level: no
    // `project_hash`, no `julia_version`. Both are things `upgrade_manifest`
    // conspicuously does not add.
    try testing.expectEqualStrings(
        manifest_mod.banner ++
            \\manifest_format = "2.0"
            \\
            \\[[deps.Dates]]
            \\deps = ["Printf"]
            \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
            \\
            \\[[deps.Printf]]
            \\uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
            \\
        ,
        try f.read("env/Manifest.toml"),
    );
}

test "an already-v2 manifest is refused, not rewritten" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const src =
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "0000000000000000000000000000000000000000"
        \\
    ;
    try f.write("env/Manifest.toml", src);

    var diag: Diagnostic = .{};
    const err = upgrade(testing.allocator, f.arena(), testing.io, .{
        .path = try f.join(&.{ "env", "Manifest.toml" }),
    }, &diag);
    try testing.expectError(error.AlreadyUpToDate, err);
    // Pkg's own sentence, `manifest_format == 2.0.0` included: three components,
    // because it interpolates a `VersionNumber`.
    try testing.expect(std.mem.endsWith(u8, diag.message, "already up to date: manifest_format == 2.0.0"));
    // Untouched, banner-less and unsorted exactly as written.
    try testing.expectEqualStrings(src, try f.read("env/Manifest.toml"));
}

test "a format neither 1.0 nor 2.0 is unrecognized, whatever its major" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    // `2.1` shares major 2 with the layout Ajt writes, and Pkg STILL refuses it:
    // the test is `before_format != v"1.0"` after `== v"2.0"` failed.
    try f.write("env/Manifest.toml", "manifest_format = \"2.1\"\n");
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnrecognizedFormat, upgrade(testing.allocator, f.arena(), testing.io, .{
        .path = try f.join(&.{ "env", "Manifest.toml" }),
    }, &diag));
    try testing.expect(std.mem.endsWith(u8, diag.message, "unrecognized: manifest_format == 2.1.0"));
}

test "upgrading a directory finds the manifest the way EnvCache does" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeProject();
    try f.write("env/Manifest.toml",
        \\[[Printf]]
        \\uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
        \\
    );

    const up = try upgrade(testing.allocator, f.arena(), testing.io, .{
        .path = try f.join(&.{"env"}),
    }, null);
    try testing.expect(std.mem.endsWith(u8, up.manifest_file, "Manifest.toml"));
    try testing.expect(up.written);
}

test "--dry-run leaves the file byte-identical" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const src =
        \\[[Printf]]
        \\uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
        \\
    ;
    try f.write("env/Manifest.toml", src);

    const up = try upgrade(testing.allocator, f.arena(), testing.io, .{
        .path = try f.join(&.{ "env", "Manifest.toml" }),
        .dry_run = true,
    }, null);
    try testing.expect(!up.written);
    try testing.expectEqualStrings(src, try f.read("env/Manifest.toml"));
}
