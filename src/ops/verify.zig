//! `ajt verify` — "is this environment already fully instantiated?", answered
//! without booting Julia.
//!
//! ### Why
//!
//! The shape this exists for is a container entrypoint that used to run
//! `julia -e 'using Pkg; Pkg.instantiate()'` on EVERY start. On a warm depot
//! that call does no work, but it still pays a Julia boot, a `Pkg` load and a
//! walk over every manifest entry before it can say so. This module answers
//! the same question from the three files that actually decide it —
//! `Project.toml`, `Manifest.toml`, and the depot's directory names — so a
//! caller writes `ajt verify || ajt instantiate`: the fast path when there is
//! nothing to do, the real one when there is.
//!
//! ### The question, exactly as Pkg 1.12.6 asks it
//!
//! Two predicates define "instantiated", and the checks below are ports of
//! them, ordered cheapest-first so a failure costs less than a success:
//!
//!  1. `Operations.is_manifest_current(env)` (`Operations.jl:3068-3077`) —
//!     `manifest.other["project_hash"] == workspace_resolve_hash(env)`. This is
//!     the one that actually fires in practice: it goes stale the moment
//!     someone edits `[deps]` or `[compat]`, and it costs one SHA-1 over a few
//!     hundred bytes, so it runs before anything touches the depot.
//!  2. `Operations.is_instantiated(env)` (`Operations.jl:201-221`) — every
//!     dependency's `source_path` exists on disk. `source_path`
//!     (`Operations.jl:48-53`) is a three-way branch and all three are
//!     reproduced here:
//!
//!     | manifest entry has | source is |
//!     |---|---|
//!     | `git-tree-sha1` | `find_installed` → `<depot>/packages/<Name>/<slug>` |
//!     | `path`          | `normpath(joinpath(dirname(manifest_file), path))` |
//!     | neither         | `is_or_was_stdlib(uuid)` ? `stdlib_path(name)` : NOTHING |
//!
//!     The order of those rows is the whole of the rule: an entry carrying BOTH
//!     a tree hash and a path (which `manifest.zig` rejects only when *writing*)
//!     is located by the tree hash. Ahead of all three sits a `[sources]` PATH,
//!     which clears the tree hash outright (`Operations.jl:184-190`).
//!
//!     A `[sources]` **url** is not a fourth case and needs no branch here: it
//!     is resolved into `repo-url` + `git-tree-sha1` by `ops/resolve.zig`
//!     (Pkg does the same in `collect_fixed!`, `Operations.jl:432-444`), so it
//!     arrives as row 1 and is checked by tree hash like any other unpacked
//!     package — including the `--check-hashes` re-derivation, which is a real
//!     test of the materialisation and not a formality.
//!
//!     That last row is why "no `git-tree-sha1` ⇒ skip" is wrong: an entry with
//!     no tree hash that is *not* a stdlib has no source at all, and Julia
//!     calls such an environment un-instantiated. Hence the cross-check against
//!     `julia/stdlibs.zig`, which is keyed on the UUID — the same key
//!     `is_or_was_stdlib` uses — and not on the name.
//!
//! Which entries those predicates cover is itself a trap, and the expensive
//! kind: `instantiate` prunes the manifest to the *loadable closure* first
//! (`prune_manifest`, `API.jl:1326`), so nine of the Open-Reality manifest's
//! 170 tree-hash entries are neither checked nor installed — see `loadable`.
//!
//! ### Two deliberate divergences, both in the strict direction
//!
//! A verdict of "instantiated" makes the caller SKIP work, so every divergence
//! here is chosen to fail rather than to pass:
//!
//!  1. **Artifacts are not checked.** `is_package_downloaded` also runs
//!     `check_artifacts_downloaded` (`Operations.jl:1083-1094`) over each
//!     package's `Artifacts.toml`. That is a per-package TOML parse plus
//!     platform selection — a different unit's code (`install/artifacts.zig`)
//!     and a different order of magnitude of work. A verify that passes here
//!     while an artifact is missing would be a false "instantiated"; that is
//!     the one hole in this module, and it is stated rather than hidden. It
//!     costs a re-run of the slow path at the point where the game actually
//!     fails to load a JLL, not silent corruption.
//!  2. **"Cannot tell" is not "yes".** A manifest with no `project_hash`
//!     (`is_manifest_current` → `nothing`) and an environment whose stdlib
//!     entries cannot be checked for want of a Julia installation both fail
//!     here, where `instantiate` carries on. Both are cases where the honest
//!     answer is "I do not know", and the caller's only use for this command is
//!     deciding whether it may skip work.
//!
//! ### `--frozen`
//!
//! Nothing in this module resolves, downloads or writes — there is no code path
//! that opens a file for writing and none that touches the network. `--frozen`
//! is therefore the *only* behaviour rather than a mode, and the flag exists so
//! the entrypoint's contract ("report, never repair") stays spelled out at the
//! call site when a future `ajt instantiate` gains the ability to fix things.
//!
//! ### Allocation
//!
//! `run` takes an **arena** for everything the `Report` borrows (paths,
//! messages, the parsed models) — bundle-lifetime data, nothing to free
//! individually — plus a general-purpose `scratch` allocator for transient
//! work. The split is load-bearing for `--check-hashes`: `treehash.hashPath`
//! reads every file of a package into a child arena of the allocator it is
//! given and frees it per directory, so handing it the report arena instead
//! would retain the entire installed tree in memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const project_hash = @import("../julia/project_hash.zig");
const slug = @import("../julia/slug.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const treehash = @import("../julia/treehash.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;

/// `Base.project_names` (`base/loading.jl:630`), in probe order. Borrowed from
/// `julia/stdlibs.zig` rather than restated: two copies of a probe order are
/// two chances to disagree with the loader.
pub const project_names = stdlibs_mod.project_names;

/// The version-independent tail of `Base.manifest_names`
/// (`base/loading.jl:631-636`) plus `AppManifest.toml`, which
/// `Types.manifestfile_path` appends (`Types.jl:189`).
///
/// The two names this list CANNOT hold are the version-specific
/// `JuliaManifest-v<major>.<minor>.toml` / `Manifest-v<major>.<minor>.toml`,
/// which sort ahead of all of these and are built at runtime from the Julia
/// version — see `locateManifest`. An environment carrying one of those and a
/// stale `Manifest.toml` beside it is the trap: verifying the wrong file
/// answers a question nobody asked.
pub const manifest_names = [_][]const u8{ "JuliaManifest.toml", "Manifest.toml", "AppManifest.toml" };

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

pub const Error = error{
    /// `JULIA_DEPOT_PATH=""` — a real, reachable configuration with nowhere to
    /// look. Julia raises "no depots provided" here too (`Pkg/src/Pkg.jl:29`).
    NoDepot,
} || Allocator.Error;

/// What went wrong. One value per *cause*, because the whole point of this
/// command is that the caller learns which slow path to take: a stale
/// `project_hash` needs a resolve, a missing package only needs a download.
pub const Kind = enum {
    project_unreadable,
    project_invalid,
    workspace_unsupported,
    manifest_unreadable,
    manifest_invalid,
    manifest_hash_absent,
    project_hash_mismatch,
    direct_dep_unmanifested,
    package_missing,
    dev_path_missing,
    stdlib_missing,
    unresolvable_entry,
    stdlib_check_unavailable,
    tree_hash_mismatch,

    /// What a caller should DO about it. `verify` answers a yes/no question,
    /// but "no" has three different remedies and a single non-zero exit cannot
    /// tell them apart -- which is why the Julia wrapper had to scrape the
    /// report text to find out whether an environment merely needed
    /// installing.
    pub fn remedy(self: Kind) Remedy {
        return switch (self) {
            // Content is missing from the depot. `instantiate` fixes it.
            .package_missing, .dev_path_missing, .stdlib_missing, .unresolvable_entry => .install,
            // The manifest no longer describes the project. A resolve fixes it.
            .manifest_hash_absent, .project_hash_mismatch, .direct_dep_unmanifested => .resolve,
            // Something is wrong with the files or the machine, and no ordinary
            // Pkg operation is the answer.
            .project_unreadable,
            .project_invalid,
            .workspace_unsupported,
            .manifest_unreadable,
            .manifest_invalid,
            .tree_hash_mismatch,
            .stdlib_check_unavailable,
            => .repair,
        };
    }

    /// Message template. Kept next to the enum so a new kind cannot be added
    /// without saying what it means to a human reading container logs.
    pub fn headline(self: Kind) []const u8 {
        return switch (self) {
            .project_unreadable => "cannot read the project file",
            .project_invalid => "project file is not a valid Project.toml",
            .workspace_unsupported => "project defines a [workspace]",
            .manifest_unreadable => "cannot read the manifest",
            .manifest_invalid => "manifest is not a valid Manifest.toml",
            .manifest_hash_absent => "manifest records no project_hash",
            .project_hash_mismatch => "the project changed since the manifest was resolved",
            .direct_dep_unmanifested => "is a direct dependency but has no manifest entry",
            .package_missing => "not installed",
            .dev_path_missing => "developed source directory is missing",
            .stdlib_missing => "stdlib is not present in this Julia installation",
            .unresolvable_entry => "manifest entry has no source",
            .stdlib_check_unavailable => "entries without a git-tree-sha1 could not be checked",
            .tree_hash_mismatch => "installed tree does not match its git-tree-sha1",
        };
    }
};

/// What to do about a failed verify. Ordered by severity: a run that reports
/// several problems takes the worst one.
pub const Remedy = enum { install, resolve, repair };

pub const Problem = struct {
    kind: Kind,
    /// The package name, or the file, this is about.
    subject: []const u8,
    /// Where we looked, or the parse diagnostic. Empty when there is nothing
    /// useful to add.
    detail: []const u8 = "",
    /// The recorded value and the observed one, for the two comparisons.
    want: []const u8 = "",
    got: []const u8 = "",

    /// One line, `subject: headline (detail)`, so a failure reads the same in a
    /// terminal and in a container log aggregator.
    pub fn format(self: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: {s}", .{ self.subject, self.kind.headline() });
        if (self.want.len != 0 or self.got.len != 0) {
            try w.print(" (recorded {s}, found {s})", .{
                if (self.want.len != 0) self.want else "nothing",
                if (self.got.len != 0) self.got else "nothing",
            });
        }
        if (self.detail.len != 0) try w.print(" — {s}", .{self.detail});
    }
};

/// `Operations.is_manifest_current`'s answer (`Operations.jl:3068-3077`), all
/// three of it.
///
/// `nothing` is not a hedge and it is not `false`: it means the manifest
/// records no `project_hash` at all — written by a Pkg older than 1.7, upgraded
/// from the v1 layout, or hand-edited — so there is no recorded value for the
/// project to disagree with. Every caller inside Pkg tests `=== false` rather
/// than `!= true` for exactly that reason (`API.jl:1321`, `Operations.jl:3059`),
/// i.e. Pkg treats "cannot tell" as "carry on". `verify` does not — see the
/// module header's second deliberate divergence — but the distinction still has
/// to be *representable*, because `ops/manifest_ops.zig` exposes it verbatim.
pub const Currency = enum {
    /// `nothing`.
    unknown,
    /// `true`.
    current,
    /// `false`.
    stale,
};

/// The result of one `is_manifest_current`, with the two values that went into
/// it so a caller can say what disagreed.
pub const Comparison = struct {
    answer: Currency,
    /// The `project_hash` the manifest records, verbatim; empty when `.unknown`.
    recorded: []const u8 = "",
    /// `Types.workspace_resolve_hash(env)`. Null when `.unknown` — Julia never
    /// computes it in that branch either, and that ordering is load-bearing;
    /// see `compareProjectHash`.
    computed: ?[40]u8 = null,
};

/// `Operations.is_manifest_current(env)` (`Operations.jl:3068-3077`) — the one
/// implementation of "does this manifest match this project", shared by `run`'s
/// phase 3 and by `ops/manifest_ops.zig`'s port of the public
/// `Pkg.is_manifest_current`. Two copies of this comparison would be two
/// chances to answer the same question differently.
///
/// Two things in here are load-bearing and neither is visible in the signature:
///
///  1. **A missing `project_hash` returns before the digest is taken.** Julia's
///     `else` branch returns `nothing` without calling `workspace_resolve_hash`
///     at all, so a project whose `[compat]` cannot even be rendered still
///     answers `nothing` rather than throwing. `verify` needs the same
///     ordering: `manifest_hash_absent` asks the caller for a *resolve*, where
///     a digest failure reports `project_invalid` and asks for a *repair*.
///  2. **The comparison is on the recorded STRING**, not on the 20 bytes it
///     parses to (`:3070-3072`: `manifest.other["project_hash"] ==
///     workspace_resolve_hash(env)`). `Sha1.parse` accepts uppercase hex, so
///     comparing parsed values would call an uppercase recorded hash a match
///     where Julia calls it a mismatch — a false "current", and the only
///     divergence available here that skips work Julia would have done.
///     `project_hash` survives in `other` untouched (see `Manifest.other`), so
///     the raw text is right there; formatting the parsed value is the fallback
///     for a model built by hand rather than read from a file.
///
/// `arena` holds only that fallback string; `scratch` is the digest's transient
/// workspace.
/// `project` is taken by POINTER, not by value: `Project` owns an
/// `ArenaAllocator` and moving one invalidates its allocator (see
/// `Project.arena`'s doc comment). Nothing here allocates from it — only
/// `other()`, a stored pointer, is read — but a by-value parameter would leave
/// that trap lying in wait for the next line added to this function.
pub fn compareProjectHash(
    arena: Allocator,
    scratch: Allocator,
    project: *const project_mod.Project,
    manifest: manifest_mod.Manifest,
) project_hash.Error!Comparison {
    // Presence is decided by the model field and the text is taken from the raw
    // table. `fromToml` sets the two from the same key (`:428`, `:436-444`) and
    // `setProjectHash` writes both, so for any manifest that came from a file
    // they cannot disagree; Julia keys on `other` alone.
    const parsed = manifest.project_hash orelse return .{ .answer = .unknown };
    const recorded: []const u8 = blk: {
        if (manifest.other) |o| {
            if (o.get("project_hash")) |v| switch (v) {
                .string => |s| break :blk s,
                else => {},
            };
        }
        var buf: [40]u8 = undefined;
        break :blk try arena.dupe(u8, manifest_mod.formatSha1(parsed, &buf));
    };

    const computed = try project_hash.compute(scratch, project.other());
    return .{
        .answer = if (std.mem.eql(u8, recorded, &computed)) .current else .stale,
        .recorded = recorded,
        .computed = computed,
    };
}

/// Whether the stdlib cross-check could run at all.
///
/// `unavailable` is a FAILURE, not a caveat: it raises a
/// `stdlib_check_unavailable` problem and the run exits non-zero. Without a
/// Julia installation to ask, an entry with no `git-tree-sha1` cannot be told
/// apart from a stdlib, and on the real Open-Reality manifest that is 43 of
/// 214 entries going unexamined — a "verified" verdict covering four fifths of
/// the environment is exactly the false "instantiated" this module exists to
/// avoid. It is reachable in production, too: `depot.resolve` only needs a
/// bindir for an EMPTY `JULIA_DEPOT_PATH` entry, so the engine image's
/// `JULIA_DEPOT_PATH=/julia-depot:/julia-depot-image` resolves fine with no
/// `julia` on `$PATH` at all.
pub const StdlibCheck = enum { checked, unavailable, not_needed };

pub const Report = struct {
    project_file: []const u8 = "",
    manifest_file: []const u8 = "",
    /// Manifest entries seen.
    entries: usize = 0,
    /// Entries resolved to an existing `<depot>/packages/<Name>/<slug>`.
    installed: usize = 0,
    /// Entries resolved to an existing `path`/`[sources]` directory.
    developed: usize = 0,
    /// Entries skipped as standard libraries.
    stdlib: usize = 0,
    /// Entries outside the loadable closure — what `prune_manifest` would
    /// delete, and what `instantiate` never looks for. Reported because a large
    /// number here means the manifest is carrying dead weight, not because it
    /// is a problem.
    pruned: usize = 0,
    /// Installed trees re-hashed (`--check-hashes` only).
    rehashed: usize = 0,
    stdlib_check: StdlibCheck = .not_needed,
    problems: []const Problem = &.{},

    pub fn ok(self: Report) bool {
        return self.problems.len == 0;
    }

    /// The worst remedy any problem calls for, or null when there are none.
    /// This is what a caller switches on instead of parsing the report.
    pub fn remedy(self: Report) ?Remedy {
        var worst: ?Remedy = null;
        for (self.problems) |p| {
            const r = p.kind.remedy();
            if (worst == null or @intFromEnum(r) > @intFromEnum(worst.?)) worst = r;
        }
        return worst;
    }
};

pub const Options = struct {
    /// The environment: a directory, or a project file directly. A directory is
    /// probed exactly as `Types.projectfile_path` probes it.
    env_path: []const u8,
    /// Overrides manifest discovery entirely. Relative paths are taken as-is.
    manifest_file: ?[]const u8 = null,
    /// Every depot Julia would search, in order. Read-only, always.
    stack: depot_mod.Stack,
    /// Re-tree-hash every installed directory. OFF by default: it reads every
    /// byte of every installed package, which is seconds, not milliseconds.
    check_hashes: bool = false,
    /// `dirname(Sys.BINDIR)` of the Julia this environment targets. Without it
    /// the stdlib cross-check cannot run (see `StdlibCheck`).
    julia_prefix: ?[]const u8 = null,
    /// e.g. "1.12.6". Selects the `share/julia/stdlib/v<major>.<minor>`
    /// directory and the version-specific manifest names. When null, the
    /// manifest's own `julia_version` is used — it records the Julia that
    /// resolved the environment, which is the closest thing available to the
    /// `VERSION` Julia would use itself.
    julia_version: ?[]const u8 = null,
};

/// The files this run actually read, resolved the way `Types.EnvCache` resolves
/// them (`Types.jl:392-430`). Public because `ops/manifest_ops.zig` addresses
/// an environment the same way and must land on the same two files.
pub const Located = struct {
    project: []const u8,
    dir: []const u8,
};

/// The three `Options` fields `locateManifest` reads. Split out so a caller
/// that has no depot to speak of — `is_manifest_current` never looks in one —
/// can ask which file Julia would read without inventing a `Stack` to do it.
pub const ManifestLocation = struct {
    /// Overrides discovery entirely. Relative paths are taken as-is.
    manifest_file: ?[]const u8 = null,
    julia_prefix: ?[]const u8 = null,
    julia_version: ?[]const u8 = null,
};

pub fn run(arena: Allocator, scratch: Allocator, io: Io, opts: Options) Error!Report {
    var problems: std.ArrayList(Problem) = .empty;
    var rep: Report = .{};

    const loc = try locateProject(arena, io, opts.env_path);
    rep.project_file = loc.project;

    // ---- 1. Project.toml parses -------------------------------------------
    const project_src = Io.Dir.cwd().readFileAlloc(io, loc.project, arena, .limited(max_project_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return try finish(arena, &rep, &problems, .{
            .kind = .project_unreadable,
            .subject = loc.project,
            .detail = @errorName(err),
        });
    };

    var pdiag: project_mod.Diagnostic = .{};
    // `validate = true`: reject exactly what `read_project` rejects. A project
    // Julia refuses to read is not an environment anyone can instantiate, and
    // reporting it here beats reporting it as a mystery hash mismatch.
    var project = project_mod.parse(arena, project_src, .{ .file = loc.project }, &pdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return try finish(arena, &rep, &problems, .{
            .kind = .project_invalid,
            .subject = loc.project,
            .detail = try arena.dupe(u8, pdiag.message()),
        });
    };
    // The Project owns a child arena of `arena`; freeing `arena` frees it, so
    // there is nothing to deinit and nothing that outlives the report.

    // `workspace_resolve_hash` digests EVERY project in a workspace
    // (`Types.jl:645-666` via `load_direct_deps`/`load_workspace_weak_deps`),
    // and `EnvCache` redirects the manifest to the workspace root
    // (`Types.jl:412-419`). Ajt's `project_hash.compute` covers one project, so
    // a workspace would produce a confident wrong answer. Refuse instead.
    if (project.workspace_projects) |ws| {
        if (ws.len != 0) {
            return try finish(arena, &rep, &problems, .{
                .kind = .workspace_unsupported,
                .subject = loc.project,
                .detail = "verify covers a single project; run Pkg.instantiate() for workspaces",
            });
        }
    }

    // ---- 2. Manifest.toml parses ------------------------------------------
    const manifest_file = try locateManifest(arena, io, .{
        .manifest_file = opts.manifest_file,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    }, loc, project.manifest);
    rep.manifest_file = manifest_file;

    const manifest_src = Io.Dir.cwd().readFileAlloc(io, manifest_file, arena, .limited(max_manifest_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return try finish(arena, &rep, &problems, .{
            .kind = .manifest_unreadable,
            .subject = manifest_file,
            .detail = @errorName(err),
        });
    };

    var mdiag: manifest_mod.Diagnostic = .{};
    const manifest = manifest_mod.parse(arena, manifest_src, &mdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return try finish(arena, &rep, &problems, .{
            .kind = .manifest_invalid,
            .subject = manifest_file,
            .detail = if (err == error.ParseFailed)
                try std.fmt.allocPrint(arena, "line {d}, column {d}: {s}", .{ mdiag.line, mdiag.column, mdiag.message })
            else
                @errorName(err),
        });
    };
    rep.entries = manifest.entries.len;

    // ---- 3. project_hash --------------------------------------------------
    //
    // `is_manifest_current`, which lives in `compareProjectHash` because
    // `ops/manifest_ops.zig` exposes the same comparison under Pkg's own name.
    // Cheap (one SHA-1 over a few hundred bytes) and by far the most likely
    // real failure, so it runs before the depot is touched — and returns
    // immediately, because "the project changed" makes every package-level
    // answer below moot: the resolve that follows may well change which
    // packages are even wanted.
    const hashes = compareProjectHash(arena, scratch, &project, manifest) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Unreachable through `parse` with `validate = true` -- it renders every
        // compat through the same `semverSpec` -- but the digest is computed
        // from the raw table, so a table this model never inspected could still
        // trip it. Report it as the project problem it is.
        return try finish(arena, &rep, &problems, .{
            .kind = .project_invalid,
            .subject = loc.project,
            .detail = @errorName(err),
        });
    };
    switch (hashes.answer) {
        .unknown => return try finish(arena, &rep, &problems, .{
            .kind = .manifest_hash_absent,
            .subject = manifest_file,
            .detail = "resolve to record one (Pkg only warns about this; ajt cannot prove the environment matches without it)",
        }),
        .stale => return try finish(arena, &rep, &problems, .{
            .kind = .project_hash_mismatch,
            .subject = loc.project,
            .want = try arena.dupe(u8, hashes.recorded),
            .got = try arena.dupe(u8, &hashes.computed.?),
            .detail = "resolve to update the manifest",
        }),
        .current => {},
    }

    // ---- 4. every LOADABLE entry's source exists --------------------------
    if (opts.stack.entries.len == 0) return error.NoDepot;

    const keep = try loadable(arena, project, manifest);

    // `instantiate` refuses outright when a direct dependency has no manifest
    // entry (`API.jl:1327-1334`) -- the manifest cannot pin what it does not
    // mention, so no amount of downloading fixes it.
    for (project.deps.entries.items) |d| {
        if (manifest.findByUuid(d.uuid) == null) {
            try problems.append(arena, .{
                .kind = .direct_dep_unmanifested,
                .subject = d.name,
                .detail = "resolve to populate the manifest",
            });
        }
    }

    // Loaded at most once, and only if some entry needs it (an environment of
    // nothing but registry packages never pays for it -- and on the engine's
    // manifest it is 44 of 214 entries that do).
    var stdlib_set: ?stdlibs_mod.Set = null;
    var stdlib_tried = false;

    for (manifest.entries) |entry| {
        // Outside the loadable closure: `instantiate` PRUNES these before it
        // looks at anything (`prune_manifest`, `API.jl:1326`), so their absence
        // is not a reason to instantiate. See `loadable` for why this is not
        // optional strictness.
        if (!keep.contains(entry.uuid.bytes)) {
            rep.pruned += 1;
            continue;
        }

        // `[sources]` wins over the manifest: `load_all_deps` CLEARS the entry's
        // tree hash when the project pins a path for that name
        // (`Operations.jl:184-190`), so such a package is loaded from the
        // working tree and its depot slug is irrelevant. That clearing is the
        // only thing that outranks a tree hash — see the branch order below.
        //
        // The base directory differs between the two path sources and it is not
        // cosmetic: a `[sources]` path is PROJECT-relative and Julia rebases it
        // onto the manifest (`get_path_repo` → `project_path_to_manifest_path`,
        // `Types.jl:444-448`) before `source_path` joins it to
        // `dirname(manifest_file)` — net effect, project-relative. A manifest
        // entry's own `path` is manifest-relative already (`Operations.jl:50`).
        // The two directories are the same file until a `manifest = "..."`
        // redirect separates them, which `locateManifest` supports.
        const rebased: ?struct { rel: []const u8, base: []const u8 } = blk: {
            if (project.sourceFor(entry.name)) |s| {
                if (s.path) |p| break :blk .{ .rel = p, .base = loc.dir };
            }
            // `source_path`'s FIRST branch: a tree hash beats a manifest `path`.
            // `manifest.zig` rejects both-at-once only when WRITING (`:314`,
            // JuliaLang/Pkg.jl#4086), so a hand-edited or legacy manifest
            // carrying both reaches this reader, and taking the path branch
            // there would call an uninstalled package installed.
            if (entry.tree_hash != null) break :blk null;
            if (entry.path) |p| break :blk .{ .rel = p, .base = fspath.dirname(manifest_file) orelse "." };
            break :blk null;
        };

        if (rebased) |r| {
            const path = try fspath.resolve(arena, &.{ r.base, r.rel });
            if (isDir(io, path)) {
                rep.developed += 1;
            } else {
                try problems.append(arena, .{
                    .kind = .dev_path_missing,
                    .subject = entry.name,
                    .detail = path,
                });
            }
            continue;
        }

        if (entry.tree_hash) |th| {
            // `find_installed` probes the 5-character slug in every depot
            // before the legacy 4-character one in any of them.
            const found = depot_mod.findInstalled(arena, io, opts.stack, entry.name, entry.uuid, th) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoDepot => return error.NoDepot,
                // A cancelled stat cannot be read as "installed".
                else => depot_mod.Found{ .path = "", .exists = false },
            };
            // `is_package_downloaded` requires `isdir`, while `find_installed`
            // accepts any path (`ispath`) — a FILE at the slug name is a
            // not-installed package, not an installed one.
            if (!found.exists or !isDir(io, found.path)) {
                try problems.append(arena, .{
                    .kind = .package_missing,
                    .subject = try describe(arena, entry),
                    .detail = found.path,
                });
                continue;
            }
            rep.installed += 1;

            if (opts.check_hashes) {
                // Transient by design: `scratch`, never the report arena.
                const got = treehash.hashPath(scratch, io, found.path) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    try problems.append(arena, .{
                        .kind = .tree_hash_mismatch,
                        .subject = try describe(arena, entry),
                        .detail = @errorName(err),
                    });
                    continue;
                };
                rep.rehashed += 1;
                const got_hex = treehash.toHex(got);
                var want_buf: [40]u8 = undefined;
                const want_hex = manifest_mod.formatSha1(th, &want_buf);
                if (!std.mem.eql(u8, &got_hex, want_hex)) {
                    try problems.append(arena, .{
                        .kind = .tree_hash_mismatch,
                        .subject = try describe(arena, entry),
                        .want = try arena.dupe(u8, want_hex),
                        .got = try arena.dupe(u8, &got_hex),
                        .detail = found.path,
                    });
                }
            }
            continue;
        }

        // Neither a tree hash nor a path: Julia's last branch. `stdlib_path`
        // is keyed on the NAME but the predicate is keyed on the UUID, so both
        // have to line up before this entry counts as resolved.
        if (!stdlib_tried) {
            stdlib_tried = true;
            if (loadStdlibs(arena, io, opts, manifest)) |set| {
                stdlib_set = set;
                rep.stdlib_check = .checked;
            } else |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                // No prefix, or no stdlib tree for this version. One problem for
                // the whole run, not one per entry: the cause is a missing Julia
                // installation, and 43 identical lines would bury it. It is a
                // problem rather than a note because `ok()` must not be true
                // while a fifth of the manifest went unexamined.
                rep.stdlib_check = .unavailable;
                try problems.append(arena, .{
                    .kind = .stdlib_check_unavailable,
                    .subject = manifest_file,
                    .detail = "no Julia installation found — pass --julia-prefix (or put julia on PATH)",
                });
            }
        }
        // Already reported once above; the remaining entries are still checked.
        const set = stdlib_set orelse continue;

        const info = set.byUuid(entry.uuid) orelse {
            try problems.append(arena, .{
                .kind = .unresolvable_entry,
                .subject = try describe(arena, entry),
                .detail = "no git-tree-sha1, no path, and its uuid is not a standard library",
            });
            continue;
        };
        if (!std.mem.eql(u8, info.name, entry.name)) {
            try problems.append(arena, .{
                .kind = .stdlib_missing,
                .subject = try describe(arena, entry),
                .want = entry.name,
                .got = info.name,
                .detail = "the uuid is a stdlib, but under a different name",
            });
            continue;
        }
        rep.stdlib += 1;
    }

    rep.problems = try problems.toOwnedSlice(arena);
    return rep;
}

/// The set of manifest entries `instantiate` actually requires:
/// `load_all_deps_loadable` (`Operations.jl:193-199`) — the project's `[deps]`,
/// closed over each entry's own STRONG `deps` by `prune_deps`
/// (`Operations.jl:180-191`), which is reproduced here as the same fixpoint.
///
/// This is not a detail. On the real Open-Reality environment the closure is
/// 204 of 214 entries, and the 10 outside it — `Vulkan`, `VulkanCore`,
/// `Vulkan_Headers_jll`, `BitMasks`, `Compat`, `JuliaSyntax`, `MLStyle`,
/// `ResultTypes`, `StructEquality` and their kin, reachable only through the
/// `[weakdeps]` extension trigger — **are not installed in the depot at all**,
/// while `Pkg.Operations.is_instantiated` still answers `true`. Checking every
/// entry instead (the obvious reading of "verify the manifest") therefore fails
/// a container that Julia would have booted, on nine packages nothing was ever
/// going to download. Measured against the real depot, not reasoned about — the
/// first version of this file got it wrong in exactly that way.
///
/// Weakdeps are deliberately not traversed: `prune_deps` walks `entry.deps`
/// only, so an extension's trigger package is pulled in only when something
/// depends on it strongly.
pub fn loadable(
    arena: Allocator,
    project: project_mod.Project,
    manifest: manifest_mod.Manifest,
) Allocator.Error!std.AutoHashMapUnmanaged([16]u8, void) {
    var keep: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    // `Set{UUID}(values(env.project.deps))` — the post-split `[deps]`, so a
    // name that is in both `[deps]` and `[weakdeps]` at the same uuid is
    // already gone (`project.jl:237-238`).
    for (project.deps.entries.items) |d| try keep.put(arena, d.uuid.bytes, {});

    // Julia's `prune_deps` re-sweeps the whole manifest until a pass adds
    // nothing. Same loop: entry order is arbitrary in a Dict, so a single pass
    // would be order-dependent.
    while (true) {
        var clean = true;
        for (manifest.entries) |e| {
            if (!keep.contains(e.uuid.bytes)) continue;
            for (e.deps) |d| {
                const gop = try keep.getOrPut(arena, d.uuid.bytes);
                if (!gop.found_existing) clean = false;
            }
        }
        if (clean) break;
    }
    return keep;
}

/// `<name> v<version>`, or just the name when the entry carries none (stdlibs
/// without a registered version, `SuiteSparse` and friends).
fn describe(arena: Allocator, entry: manifest_mod.PackageEntry) Allocator.Error![]const u8 {
    const v = entry.version orelse return entry.name;
    return std.fmt.allocPrint(arena, "{s} v{f}", .{ entry.name, v });
}

fn finish(
    arena: Allocator,
    rep: *Report,
    problems: *std.ArrayList(Problem),
    p: Problem,
) Allocator.Error!Report {
    try problems.append(arena, p);
    rep.problems = try problems.toOwnedSlice(arena);
    return rep.*;
}

/// `isdir`. Any error — missing, permission, cancellation — is "no": a
/// directory we cannot see is one Julia's `isdir` would not see either. Public
/// alongside the two locators, for the same reason.
pub fn isDir(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `Types.projectfile_path` (`Types.jl:180-186`): probe `JuliaProject.toml`
/// then `Project.toml` inside a directory; a path that is not a directory is
/// taken as the project file itself.
///
/// Non-strict, so a directory with no project file still comes back naming the
/// file that would go there. `Pkg.is_manifest_current(path)` uses
/// `strict = true` and raises instead (`API.jl:567-570`), which
/// `ops/manifest_ops.zig` reproduces by failing to READ the returned path
/// rather than by a second probe.
pub fn locateProject(arena: Allocator, io: Io, env_path: []const u8) Allocator.Error!Located {
    if (isDir(io, env_path)) {
        for (project_names) |name| {
            const candidate = try fspath.join(arena, &.{ env_path, name });
            if (isFile(io, candidate)) return .{ .project = candidate, .dir = env_path };
        }
        // Non-strict: the would-be path, so the failure names the file the user
        // expected rather than the directory.
        return .{
            .project = try fspath.join(arena, &.{ env_path, project_names[project_names.len - 1] }),
            .dir = env_path,
        };
    }
    return .{ .project = env_path, .dir = fspath.dirname(env_path) orelse "." };
}

pub fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// `Types.manifestfile_path` (`Types.jl:188-204`), plus the `manifest = "..."`
/// redirect `EnvCache` applies first (`Types.jl:411`, `:423-425`).
pub fn locateManifest(
    arena: Allocator,
    io: Io,
    opts: ManifestLocation,
    loc: Located,
    project_manifest: ?[]const u8,
) Allocator.Error![]const u8 {
    if (opts.manifest_file) |m| return m;
    if (project_manifest) |m| {
        if (fspath.isAbsolute(m)) return m;
        return fspath.resolve(arena, &.{ loc.dir, m });
    }

    // The version-specific names sort AHEAD of the plain ones, and Julia builds
    // them from ITS OWN `VERSION` -- so leaving this out whenever
    // `--julia-version` was not passed would mean reading `Manifest.toml` where
    // the running Julia reads `Manifest-v1.12.toml`, i.e. verifying a file
    // nobody loads. The version therefore falls back to the installation's own
    // stdlib directory, which is the only statement of "which Julia" available
    // without running one.
    if (opts.julia_version orelse juliaVersionFromPrefix(arena, io, opts.julia_prefix)) |jv| {
        var it = std.mem.splitScalar(u8, jv, '.');
        const major = it.next() orelse "";
        const minor = it.next() orelse "";
        if (major.len != 0 and minor.len != 0) {
            for ([_][]const u8{ "JuliaManifest", "Manifest" }) |stem| {
                const name = try std.fmt.allocPrint(arena, "{s}-v{s}.{s}.toml", .{ stem, major, minor });
                const candidate = try fspath.join(arena, &.{ loc.dir, name });
                if (isFile(io, candidate)) return candidate;
            }
        }
    }

    for (manifest_names) |name| {
        const candidate = try fspath.join(arena, &.{ loc.dir, name });
        if (isFile(io, candidate)) return candidate;
    }
    // Non-strict fallback (`Types.jl:196-202`): the name Pkg would CREATE, which
    // follows the project file's own spelling. Message-only -- nothing here
    // writes -- but naming `JuliaManifest.toml` for a `JuliaProject.toml`
    // environment is the difference between a report a user can act on and one
    // that sends them looking for the wrong file.
    const stem = if (std.mem.endsWith(u8, loc.project, "JuliaProject.toml")) "JuliaManifest.toml" else "Manifest.toml";
    return fspath.join(arena, &.{ loc.dir, stem });
}

/// `<major>.<minor>` of the Julia installed at `prefix`, read off the single
/// `share/julia/stdlib/v<major>.<minor>` directory it ships.
///
/// Same rule as `stdlibs.resolveStdlibDir`'s discovery path, and deliberately
/// the same strictness: an EXACT `v<major>.<minor>` match, so a sibling
/// `v1.13.0-DEV` next to the real `v1.12` is ignored rather than truncated to a
/// version that does not exist. Highest wins.
///
/// Null on anything unexpected — this only picks a file NAME to probe, and the
/// plain `Manifest.toml` probe below is the right answer whenever the version
/// is unknown.
pub fn juliaVersionFromPrefix(arena: Allocator, io: Io, prefix: ?[]const u8) ?[]const u8 {
    const p = prefix orelse return null;
    const root = fspath.join(arena, &.{ p, "share", "julia", "stdlib" }) catch return null;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?[2]u64 = null;
    var it = dir.iterate();
    while (it.next(io) catch return null) |raw| {
        if (raw.kind == .file) continue;
        if (raw.name.len < 2 or raw.name[0] != 'v') continue;
        var parts = std.mem.splitScalar(u8, raw.name[1..], '.');
        const major = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        const minor = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        if (parts.next() != null) continue; // exactly two components
        if (best == null or major > best.?[0] or (major == best.?[0] and minor > best.?[1])) {
            best = .{ major, minor };
        }
    }
    const mm = best orelse return null;
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ mm[0], mm[1] }) catch null;
}

/// The stdlib set of the Julia this environment targets.
///
/// Version precedence: the caller's `--julia-version` (the running Julia)
/// first, then the manifest's own `julia_version`, which records the Julia that
/// resolved the environment. When they disagree Julia itself only warns
/// (`check_manifest_julia_version_compat`, `manifest.jl:410`); here the
/// difference decides which `share/julia/stdlib/v<major>.<minor>` is read, and
/// a missing one means the check reports "unavailable" rather than inventing an
/// answer.
fn loadStdlibs(
    arena: Allocator,
    io: Io,
    opts: Options,
    manifest: manifest_mod.Manifest,
) !stdlibs_mod.Set {
    const prefix = opts.julia_prefix orelse return error.StdlibDirNotFound;
    if (opts.julia_version) |jv| {
        return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix, .julia_version = jv });
    }
    if (manifest.julia_version) |v| {
        const text = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix, .julia_version = text });
    }
    // No version anywhere: `load` falls back to the highest v<major>.<minor>
    // directory present.
    return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix });
}

// ---------------------------------------------------------------------------
// Tests
//
// The oracle for every expected value here is a real `julia`, run by
// `tools/diff_harness/verify.sh`: the real Open-Reality environment must verify
// clean and agree with `Pkg.Operations.is_instantiated`, and each negative case
// must be rejected for the same reason Julia rejects it. What lives here is the
// hermetic half — the branch structure, on fixtures small enough to reason
// about.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A tiny but REAL environment: one registry package pinned by tree hash, one
/// stdlib entry with no tree hash, and a depot containing the former at the
/// slug `julia/slug.zig` computes.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,

    // StaticArrays at a real tree hash, so the slug is a value a real depot
    // would contain (the landmark in slug.zig's tests).
    const pkg_name = "StaticArrays";
    const pkg_uuid = "90137ffa-7385-5640-81b9-e52037218182";
    const pkg_tree = "0adf069a2a490c47273727e029371b31d44b72b2";
    // LinearAlgebra: a stdlib, so the manifest entry carries no git-tree-sha1.
    const std_name = "LinearAlgebra";
    const std_uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e";

    fn init(buf: []u8) !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .root = "",
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
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

    /// The project the manifest below was resolved against. `project_hash` is
    /// not hard-coded: it is computed by the same function under test, which
    /// would be circular were that function not itself pinned to
    /// `Pkg.Types.workspace_resolve_hash` by its own differential test.
    fn writeEnv(self: *Fixture, extra_dep: ?[]const u8) ![]const u8 {
        var src: std.ArrayList(u8) = .empty;
        const a = self.arena();
        try src.appendSlice(a,
            \\name = "Fixture"
            \\uuid = "11111111-2222-3333-4444-555555555555"
            \\version = "0.1.0"
            \\
            \\[deps]
            \\
        );
        try src.appendSlice(a, "StaticArrays = \"" ++ pkg_uuid ++ "\"\n");
        try src.appendSlice(a, "LinearAlgebra = \"" ++ std_uuid ++ "\"\n");
        if (extra_dep) |d| try src.appendSlice(a, d);
        try self.write("env/Project.toml", src.items);

        const pdoc = try @import("../toml/parse.zig").parse(a, src.items, null);
        const hash = try project_hash.compute(a, pdoc.root);

        const manifest = try std.fmt.allocPrint(a,
            \\julia_version = "1.12.6"
            \\manifest_format = "2.0"
            \\project_hash = "{s}"
            \\
            \\[[deps.StaticArrays]]
            \\git-tree-sha1 = "{s}"
            \\uuid = "{s}"
            \\version = "1.9.13"
            \\
            \\[[deps.LinearAlgebra]]
            \\uuid = "{s}"
            \\
        , .{ &hash, pkg_tree, pkg_uuid, std_uuid });
        try self.write("env/Manifest.toml", manifest);
        return self.join(&.{"env"});
    }

    /// Installs the package into the fixture depot at the slug the loader will
    /// look for.
    fn installPackage(self: *Fixture) ![]const u8 {
        var buf: [8]u8 = undefined;
        const s = slug.versionSlug(
            try Uuid.parse(pkg_uuid),
            try Sha1.parse(pkg_tree),
            &buf,
        );
        const sub = try fspath.join(self.arena(), &.{ "depot", "packages", pkg_name, s });
        try self.write(
            try fspath.join(self.arena(), &.{ sub, "src", pkg_name ++ ".jl" }),
            "module StaticArrays end\n",
        );
        return self.join(&.{sub});
    }

    /// A stdlib tree with the one entry the manifest names.
    fn installStdlibs(self: *Fixture) ![]const u8 {
        try self.write(
            "julia/share/julia/stdlib/v1.12/" ++ std_name ++ "/Project.toml",
            "name = \"" ++ std_name ++ "\"\nuuid = \"" ++ std_uuid ++ "\"\nversion = \"1.12.0\"\n",
        );
        return self.join(&.{"julia"});
    }

    fn stack(self: *Fixture) !depot_mod.Stack {
        const a = self.arena();
        const entries = try a.alloc([]const u8, 1);
        entries[0] = try self.join(&.{"depot"});
        return .{ .entries = entries };
    }
};

fn firstProblem(rep: Report) ?Problem {
    if (rep.problems.len == 0) return null;
    return rep.problems[0];
}

test "a complete environment verifies clean and touches nothing" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 2), rep.entries);
    try testing.expectEqual(@as(usize, 1), rep.installed);
    try testing.expectEqual(@as(usize, 1), rep.stdlib);
    try testing.expectEqual(@as(usize, 0), rep.rehashed);
    try testing.expectEqual(StdlibCheck.checked, rep.stdlib_check);
}

test "an entry outside the loadable closure is pruned, not demanded" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    // `Ghost` is pinned by the manifest but reachable from nothing: not a
    // direct dep, not a dep of any entry. That is the shape of the nine
    // Vulkan-family entries in the real Open-Reality manifest, and they are NOT
    // installed there while `Pkg.Operations.is_instantiated` still says true.
    const a = f.arena();
    const src = try Io.Dir.cwd().readFileAlloc(testing.io, try f.join(&.{ "env", "Manifest.toml" }), a, .limited(1 << 20));
    try f.write("env/Manifest.toml", try std.fmt.allocPrint(a,
        \\{s}
        \\[[deps.Ghost]]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "99999999-8888-7777-6666-555555555555"
        \\version = "0.1.0"
        \\
    , .{src}));

    const rep = try run(a, testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 3), rep.entries);
    try testing.expectEqual(@as(usize, 1), rep.pruned);
    try testing.expectEqual(@as(usize, 1), rep.installed);
}

test "a direct dependency with no manifest entry cannot be downloaded into place" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    // `Dates` is a direct dep of the project but absent from the manifest —
    // `instantiate` pkgerrors on this (`API.jl:1327-1334`) because no download
    // can invent the pin.
    const env = try f.writeEnv("Dates = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\n");
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(!rep.ok());
    const p = firstProblem(rep).?;
    try testing.expectEqual(Kind.direct_dep_unmanifested, p.kind);
    try testing.expectEqualStrings("Dates", p.subject);
}

test "a missing package directory names the package and where it looked" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    const prefix = try f.installStdlibs();
    // Deliberately NOT installed.

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(!rep.ok());
    const p = firstProblem(rep).?;
    try testing.expectEqual(Kind.package_missing, p.kind);
    try testing.expectEqualStrings("StaticArrays v1.9.13", p.subject);
    // The path in the message is the would-be install location, which is what
    // makes the failure actionable.
    try testing.expect(std.mem.indexOf(u8, p.detail, "packages/StaticArrays/") != null);
}

test "a file where the slug directory belongs is not installed" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    const prefix = try f.installStdlibs();

    // `find_installed` accepts any path (`ispath`); `is_package_downloaded`
    // then demands `isdir`. A plain file must therefore read as missing.
    var sbuf: [8]u8 = undefined;
    const s = slug.versionSlug(try Uuid.parse(Fixture.pkg_uuid), try Sha1.parse(Fixture.pkg_tree), &sbuf);
    try f.write(try fspath.join(f.arena(), &.{ "depot", "packages", Fixture.pkg_name, s }), "not a directory\n");

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.package_missing, firstProblem(rep).?.kind);
}

test "an edited Project.toml is reported as a hash mismatch, before any depot work" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    // Add a dep AFTER the manifest was written, exactly as a human edit would.
    const edited =
        \\name = "Fixture"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\
        \\[deps]
        \\StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
        \\LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    ;
    try f.write("env/Project.toml", edited);

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(!rep.ok());
    // Exactly one problem: the mismatch short-circuits, so the report cannot
    // bury the real cause under package-level noise.
    try testing.expectEqual(@as(usize, 1), rep.problems.len);
    const p = rep.problems[0];
    try testing.expectEqual(Kind.project_hash_mismatch, p.kind);
    try testing.expectEqual(@as(usize, 40), p.want.len);
    try testing.expectEqual(@as(usize, 40), p.got.len);
    try testing.expect(!std.mem.eql(u8, p.want, p.got));
}

test "a manifest with no project_hash cannot prove anything" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.StaticArrays]]
        \\git-tree-sha1 = "0adf069a2a490c47273727e029371b31d44b72b2"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\version = "1.9.13"
        \\
    );

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
    });

    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.manifest_hash_absent, firstProblem(rep).?.kind);
}

test "an entry with no tree hash that is not a stdlib is unresolvable" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    // A stdlib tree that does NOT contain LinearAlgebra: the entry now has no
    // tree hash, no path, and a uuid that is not a stdlib -- Julia's
    // `source_path` returns `nothing` for it.
    try f.write(
        "julia/share/julia/stdlib/v1.12/Dates/Project.toml",
        "name = \"Dates\"\nuuid = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\n",
    );

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = try f.join(&.{"julia"}),
    });

    try testing.expect(!rep.ok());
    const p = firstProblem(rep).?;
    try testing.expectEqual(Kind.unresolvable_entry, p.kind);
    try testing.expectEqualStrings("LinearAlgebra", p.subject);
}

test "without a julia prefix, an unexaminable entry FAILS rather than passing quietly" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    // No stdlib tree at all, and no prefix to look for one.

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
    });

    // The dangerous shape: the installable half verifies, so a report that
    // merely NOTED the missing stdlib check would exit 0 having examined a
    // fraction of the manifest. On the real engine manifest that fraction is
    // 43 of 214 entries.
    try testing.expect(!rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.installed);
    try testing.expectEqual(@as(usize, 0), rep.stdlib);
    try testing.expectEqual(StdlibCheck.unavailable, rep.stdlib_check);
    try testing.expectEqual(Kind.stdlib_check_unavailable, firstProblem(rep).?.kind);
    // One line for the whole run, not one per entry.
    try testing.expectEqual(@as(usize, 1), rep.problems.len);
}

test "a tree hash outranks a manifest path, as source_path does" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeEnv(null);
    const prefix = try f.installStdlibs();
    // NOT installed in the depot -- but the entry also carries a `path` that
    // does exist. `source_path` (`Operations.jl:48-53`) tests `tree_hash`
    // first, so this environment is NOT instantiated; taking the path branch
    // would call it clean.
    try f.write("dev/StaticArrays/src/StaticArrays.jl", "module StaticArrays end\n");

    const a = f.arena();
    const src = try Io.Dir.cwd().readFileAlloc(testing.io, try f.join(&.{ "env", "Project.toml" }), a, .limited(1 << 20));
    const pdoc = try @import("../toml/parse.zig").parse(a, src, null);
    const hash = try project_hash.compute(a, pdoc.root);
    try f.write("env/Manifest.toml", try std.fmt.allocPrint(a,
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "{s}"
        \\
        \\[[deps.StaticArrays]]
        \\git-tree-sha1 = "{s}"
        \\path = "../dev/StaticArrays"
        \\uuid = "{s}"
        \\version = "1.9.13"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "{s}"
        \\
    , .{ &hash, Fixture.pkg_tree, Fixture.pkg_uuid, Fixture.std_uuid }));

    const rep = try run(a, testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.package_missing, firstProblem(rep).?.kind);
    try testing.expectEqual(@as(usize, 0), rep.developed);
}

test "a [sources] path is project-relative, not manifest-relative" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    // `manifest = "sub/Manifest.toml"` puts the two base directories in
    // different places, which is the only way to tell the rebasing rules apart
    // (`get_path_repo` -> `project_path_to_manifest_path`, `Types.jl:444-448`).
    const a = f.arena();
    const project = try std.fmt.allocPrint(a,
        \\name = "Fixture"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\manifest = "sub/Manifest.toml"
        \\
        \\[deps]
        \\StaticArrays = "{s}"
        \\LinearAlgebra = "{s}"
        \\
        \\[sources]
        \\StaticArrays = {{path = "dev/StaticArrays"}}
        \\
    , .{ Fixture.pkg_uuid, Fixture.std_uuid });
    try f.write("env/Project.toml", project);
    // Project-relative: env/dev/StaticArrays. Manifest-relative would be
    // env/sub/dev/StaticArrays, which is deliberately left absent.
    try f.write("env/dev/StaticArrays/src/StaticArrays.jl", "module StaticArrays end\n");
    const prefix = try f.installStdlibs();

    const pdoc = try @import("../toml/parse.zig").parse(a, project, null);
    const hash = try project_hash.compute(a, pdoc.root);
    try f.write("env/sub/Manifest.toml", try std.fmt.allocPrint(a,
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "{s}"
        \\
        \\[[deps.StaticArrays]]
        \\git-tree-sha1 = "{s}"
        \\uuid = "{s}"
        \\version = "1.9.13"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "{s}"
        \\
    , .{ &hash, Fixture.pkg_tree, Fixture.pkg_uuid, Fixture.std_uuid }));

    const rep = try run(a, testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"env"}),
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });

    // `[sources]` also CLEARS the tree hash, so the depot is not consulted at
    // all even though the entry has a git-tree-sha1 (`Operations.jl:184-190`).
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.developed);
    try testing.expectEqual(@as(usize, 0), rep.installed);
    try testing.expect(std.mem.endsWith(u8, rep.manifest_file, "sub/Manifest.toml"));
}

test "the recorded project_hash is compared as text, the way Julia compares it" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    // Upper-case the recorded hash. `Sha1.parse` accepts it, so comparing
    // PARSED values would call this a match -- while Julia's `==` on the
    // strings (`Operations.jl:3070-3072`) calls it a mismatch and resolves.
    // Passing here would mean skipping work Julia would have done.
    const a = f.arena();
    const src = try Io.Dir.cwd().readFileAlloc(testing.io, try f.join(&.{ "env", "Manifest.toml" }), a, .limited(1 << 20));
    const upper = try a.dupe(u8, src);
    const key = "project_hash = \"";
    const at = std.mem.indexOf(u8, upper, key).? + key.len;
    for (upper[at .. at + 40]) |*c| c.* = std.ascii.toUpper(c.*);
    try f.write("env/Manifest.toml", upper);

    const rep = try run(a, testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });
    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.project_hash_mismatch, firstProblem(rep).?.kind);
}

test "check-hashes catches a mutated install that the existence check accepts" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    const installed = try f.installPackage();
    const prefix = try f.installStdlibs();

    // Default mode: the directory exists, so it passes.
    const fast = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });
    try testing.expect(fast.ok());
    try testing.expectEqual(@as(usize, 0), fast.rehashed);

    // Deep mode: the content is not what the tree hash pins (the fixture's
    // "install" is a stub, so this is a mismatch by construction).
    const deep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
        .check_hashes = true,
    });
    try testing.expect(!deep.ok());
    try testing.expectEqual(@as(usize, 1), deep.rehashed);
    const p = firstProblem(deep).?;
    try testing.expectEqual(Kind.tree_hash_mismatch, p.kind);
    try testing.expectEqualStrings(Fixture.pkg_tree, p.want);
    try testing.expect(!std.mem.eql(u8, p.want, p.got));
    try testing.expectEqualStrings(installed, p.detail);
}

test "a developed dependency is checked at its path, not in the depot" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeEnv(null);
    const prefix = try f.installStdlibs();
    // Rewrite the manifest so StaticArrays is dev'ed at a relative path.
    const a = f.arena();
    const src = try Io.Dir.cwd().readFileAlloc(testing.io, try f.join(&.{ "env", "Project.toml" }), a, .limited(1 << 20));
    const pdoc = try @import("../toml/parse.zig").parse(a, src, null);
    const hash = try project_hash.compute(a, pdoc.root);
    try f.write("env/Manifest.toml", try std.fmt.allocPrint(a,
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "{s}"
        \\
        \\[[deps.StaticArrays]]
        \\path = "../dev/StaticArrays"
        \\uuid = "{s}"
        \\version = "1.9.13"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "{s}"
        \\
    , .{ &hash, Fixture.pkg_uuid, Fixture.std_uuid }));

    const opts: Options = .{
        .env_path = try f.join(&.{"env"}),
        .stack = try f.stack(),
        .julia_prefix = prefix,
    };

    const before = try run(a, testing.allocator, testing.io, opts);
    try testing.expect(!before.ok());
    try testing.expectEqual(Kind.dev_path_missing, firstProblem(before).?.kind);

    try f.write("dev/StaticArrays/src/StaticArrays.jl", "module StaticArrays end\n");
    const after = try run(a, testing.allocator, testing.io, opts);
    try testing.expect(after.ok());
    try testing.expectEqual(@as(usize, 1), after.developed);
    try testing.expectEqual(@as(usize, 0), after.installed);
}

test "a broken manifest is reported as such, not as a hash mismatch" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    try f.write("env/Manifest.toml", "julia_version = \"1.12.6\"\n[[deps.Broken]]\n");

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
    });
    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.manifest_invalid, firstProblem(rep).?.kind);
}

test "a missing environment reports the file it wanted" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = try f.join(&.{"nope"}),
        .stack = try f.stack(),
    });
    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.project_unreadable, firstProblem(rep).?.kind);
}

test "the version-specific manifest name wins over Manifest.toml" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    _ = try f.installPackage();
    const prefix = try f.installStdlibs();

    // A Manifest-v1.12.toml that is deliberately unparseable: if it is the file
    // being read, the report says so. Base.manifest_names puts it first.
    try f.write("env/Manifest-v1.12.toml", "this is not toml\n");

    const rep = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
        .julia_version = "1.12.6",
    });
    try testing.expect(!rep.ok());
    try testing.expectEqual(Kind.manifest_invalid, firstProblem(rep).?.kind);
    try testing.expect(std.mem.endsWith(u8, rep.manifest_file, "Manifest-v1.12.toml"));

    // With NO --julia-version, the version still comes from the installation's
    // own stdlib tree, so the same file is chosen. Without this fallback the run
    // below would read `Manifest.toml`, pass, and have verified a file the
    // running Julia never loads.
    const derived = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
        .julia_prefix = prefix,
    });
    try testing.expect(!derived.ok());
    try testing.expect(std.mem.endsWith(u8, derived.manifest_file, "Manifest-v1.12.toml"));

    // With no Julia to ask at all there is no version to build the name from,
    // and the plain `Manifest.toml` probe is all that is left. (That run fails
    // for the OTHER reason -- nothing can vouch for its stdlib entry -- which
    // is the point: it does not silently claim to have verified anything.)
    const blind = try run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = try f.stack(),
    });
    try testing.expect(std.mem.endsWith(u8, blind.manifest_file, "env/Manifest.toml"));
    try testing.expectEqual(Kind.stdlib_check_unavailable, firstProblem(blind).?.kind);
}

test "an empty DEPOT_PATH is an error, not a verdict" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(null);
    try testing.expectError(error.NoDepot, run(f.arena(), testing.allocator, testing.io, .{
        .env_path = env,
        .stack = .{ .entries = &.{} },
    }));
}
