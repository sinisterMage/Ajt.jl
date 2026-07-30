//! `ajt compat <Name> [spec]` — set, change or delete one `[compat]` entry.
//!
//! Port of `Pkg.compat(ctx, pkg, compat_str)` (`API.jl:1509-1547`) plus
//! `Operations.set_compat` (`Operations.jl:329-338`). Only the **programmatic**
//! form. Pkg's zero-argument `compat()` is a hand-rolled raw-mode line editor
//! over a menu of the project's dependencies; it refuses to run outside a
//! `fancy terminal` anyway, and `Ajt.jl` keeps `:compat` partially delegated so
//! that form still reaches Pkg's.
//!
//! Five behaviours, each of which is a different verb if you get it wrong:
//!
//! **1. `"Julia"` is normalised to `"julia"`** (`:1511`), and only that one
//! spelling — `"JULIA"` is not a dependency and is refused. The compat key
//! Julia itself reads is lower-case, so the alias exists because the language
//! is capitalised in prose.
//!
//! **2. The spec is stripped of surrounding quote characters** (`:1512`),
//! `strip(s, '"')`, which removes *every* leading and trailing `"` rather than
//! one pair. `pkg> compat Foo "1.2"` goes through the REPL parser as a quoted
//! argument and arrives here already unquoted; the strip is for the API caller
//! who passes `"\"1.2\""`.
//!
//! **3. The package must be in `[deps]`, or be `julia`** (`:1523`), else
//! `No package named $pkg in current Project`. That test is `haskey(project.deps, pkg)`
//! and it is taken AFTER `read_project` has performed the deps∩weakdeps split
//! (`project.jl:237-238`) — so a package listed in both tables at the same uuid
//! has been moved out of `deps` and `compat` refuses to set a bound for it,
//! even though `validate` accepts one written by hand and `destructure` merges
//! the name straight back into `[deps]` on the way out. Ajt's model reproduces
//! the split exactly (`Project.deps_weak`), so testing `deps` reproduces the
//! refusal.
//!
//! **4. An invalid spec is an error, not a no-op** (`:1525`).
//! `set_compat` returns `false` rather than throwing, and the caller turns that
//! into `invalid compat version specifier "…"`. The grammar is `semver_spec`,
//! the PROJECT one: `"1-2"` is registry syntax and is invalid here.
//!
//! **5. No spec DELETES the entry** (`:1524`, the `isnothing`/`isempty` arms).
//! `Pkg.compat("Foo")` removes `Foo`'s bound. In an interactive session Pkg
//! asks first (`:1515-1522`, issue 3567); a non-interactive one just does it,
//! and `ajt` is never interactive.
//!
//! ## The resolve is CHECKED, not enforced
//!
//! After writing, Pkg re-resolves "for compliance with the new compat rules"
//! and **catches** a `ResolverError`, printing it plus `Call `update` to attempt
//! to meet the compatibility requirements.` (`:1532-1543`). It does not
//! rethrow, does not roll the file back, and returns normally — exit 0.
//!
//! That is the whole point of the design and it is easy to lose. Tightening
//! `[compat]` on a package the manifest has *above* the new bound is the normal
//! way to use this command: you set the bound, the resolve at PRESERVE_ALL
//! (every recorded version pinned) cannot satisfy it, and Pkg tells you to run
//! `update`. A `compat` that erred out there would refuse to record the bound
//! that makes `update` do the right thing.
//!
//! So: the project is written BEFORE the resolve, exactly as Pkg writes it
//! before calling `resolve(ctx)`, and `error.NoSolution`/`error.SingletonConflict`
//! become `Report.resolve_failed` rather than a returned error. Everything else
//! propagates, which is Pkg's `else rethrow()`.
//!
//! ## A bound that changes SPELLING but not MEANING is not written
//!
//! Pkg's `write_env` writes the project only when `env.project !=
//! env.original_project` (`Types.jl:1336`), and `Base.:(==)(::Compat,
//! ::Compat)` compares the parsed `VersionSpec` and ignores the source string
//! (`:244`). So `Pkg.compat("A", "^1.2")` against `A = "1.2"` records the new
//! string in memory and leaves the FILE byte-identical — `^1.2` and `1.2` are
//! the same set in the project grammar. Verified on 1.12.6.
//!
//! `Project.setCompat` reproduces that: it dirties on the spec, not on the
//! string. Without it Ajt rewrote the file to a spelling Pkg would not have
//! changed, which is precisely the churn `pendingWrite` exists to avoid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const project_mod = @import("../model/project.zig");
const resolve_mod = @import("resolve.zig");
const edit_mod = @import("edit.zig");
const jver = @import("../julia/version.zig");
const depot = @import("../depot.zig");

pub const Error = error{
    NoProject,
    /// `No package named $pkg in current Project` (`API.jl:1546`).
    NotADependency,
    /// `invalid compat version specifier "$compat_str"` (`API.jl:1525`).
    InvalidSpec,
};

pub const Options = struct {
    project_file: []const u8,
    manifest_file: []const u8,
    /// The compliance resolve. **No default**: Pkg always runs it, so skipping
    /// it is a divergence, and a divergence has to be something a call site
    /// writes down rather than something it forgets. `.skip` exists for an
    /// environment with no depot to find a registry in, where the alternative
    /// is a `compat` that cannot record a bound at all.
    resolve: union(enum) {
        /// The depot to read the registry from.
        compliance: []const u8,
        skip,
    },
    registry_name: []const u8 = "General",
    julia_prefix: ?[]const u8 = null,
    julia_version: ?jver.Version = null,
    depots: ?depot.Stack = null,
    fixups: bool = true,
    diagnostic: ?*resolve_mod.Diagnostic = null,
    /// Filled with Pkg's own refusal wording when `run` returns one of the
    /// three `Error`s. Without it a caller has only the error tag and has to
    /// re-derive the normalised name and spec to rebuild a sentence `run`
    /// already had in hand — which is what the CLI and the differential probe
    /// both did, identically, before this existed.
    refusal: ?*?[]const u8 = null,
};

pub const Report = struct {
    /// The normalised name — `Julia` has already become `julia`.
    name: []const u8,
    /// The bound as recorded, or null when the entry was deleted.
    spec: ?[]const u8,
    /// What `[compat]` held before, for Pkg's `entry removed: … = <existing>`
    /// line. Null when there was none — and Pkg still prints the removal line
    /// in that case, with `nothing` for the value.
    existing: ?[]const u8,
    project_written: bool,
    /// The compliance resolve failed with a resolver error, which is caught
    /// rather than raised — the bound IS recorded. The explanation is in the
    /// caller's own `Options.diagnostic`, which is where `cmdResolve` reads it
    /// from too; copying it onto the report would be a second name for it.
    resolve_failed: bool = false,
    resolve: ?resolve_mod.Report = null,
};

/// `pkg = pkg == "Julia" ? "julia" : pkg` (`API.jl:1511`). Exactly that one
/// spelling: `JULIA` is not a dependency and is refused.
fn normaliseName(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "Julia")) "julia" else name;
}

/// `isnothing(compat_str) || (compat_str = string(strip(compat_str, '"')))`
/// followed by the `isempty` arm of `:1524`.
///
/// `strip(s, '"')` takes a CHARACTER, so it removes every leading and trailing
/// quote and **no whitespace at all** — `compat Foo " 1.2 "` records the string
/// with its spaces intact, and `[compat] Foo = " 1.2 "` is what lands in the
/// file. `semver_spec` trims each comma-separated term itself, so the spec is
/// still valid; the surprise is only that the source string is stored verbatim
/// (`project.jl:304`).
fn normaliseSpec(spec: ?[]const u8) ?[]const u8 {
    const s = spec orelse return null;
    const stripped = std.mem.trim(u8, s, "\"");
    return if (stripped.len == 0) null else stripped;
}

/// `spec_str = null` deletes. Note the empty string deletes too (`:1524`), so a
/// caller cannot distinguish "no argument" from `""` — and neither can Pkg's.
pub fn run(
    arena: Allocator,
    io: Io,
    opts: Options,
    name_arg: []const u8,
    spec_arg: ?[]const u8,
) !Report {
    const name = normaliseName(name_arg);
    const spec = normaliseSpec(spec_arg);

    // Pkg's refusal text, byte for byte, recorded on the way out so the CLI and
    // the differential gate read the same string a user does.
    const refuse = struct {
        fn f(a: Allocator, o: Options, comptime fmt: []const u8, args: anytype, e: Error) Error {
            const slot = o.refusal orelse return e;
            slot.* = std.fmt.allocPrint(a, fmt, args) catch null;
            return e;
        }
    }.f;

    const src = Io.Dir.cwd().readFileAlloc(io, opts.project_file, arena, .limited(8 << 20)) catch
        return refuse(arena, opts, "no Project.toml at {s}", .{opts.project_file}, Error.NoProject);
    var proj = try project_mod.parse(arena, src, .{ .file = opts.project_file }, null);

    const existing: ?[]const u8 = if (proj.compatFor(name)) |c| c.str else null;

    // `haskey(ctx.env.project.deps, pkg) || pkg == "julia"` — see corner 3.
    if (!proj.deps.contains(name) and !std.mem.eql(u8, name, "julia")) {
        // `API.jl:1546`.
        return refuse(arena, opts, "No package named {s} in current Project", .{name}, Error.NotADependency);
    }

    if (spec) |s| {
        // `setCompat` copies before it parses, so a malformed spec leaves the
        // model exactly as it was — which is what makes the InvalidSpec arm
        // safe to return from without a rollback.
        proj.setCompat(name, s) catch |err| switch (err) {
            // `API.jl:1525` — and it interpolates the STRIPPED string.
            error.InvalidVersionSpec => return refuse(
                arena,
                opts,
                "invalid compat version specifier \"{s}\"",
                .{s},
                Error.InvalidSpec,
            ),
            else => |e| return e,
        };
    } else {
        // `delete!` on a missing key succeeds, and Pkg still prints the
        // removal line. `removeCompat` returning false is that same non-event.
        _ = proj.removeCompat(name);
    }

    var report: Report = .{
        .name = name,
        .spec = spec,
        .existing = existing,
        // BEFORE the resolve, as Pkg's `write_env(ctx.env)` is (`:1526`). A
        // resolver error must not cost the user the bound they just set.
        .project_written = try edit_mod.writeProject(arena, io, &proj, opts.project_file),
    };

    const reg = switch (opts.resolve) {
        .skip => return report,
        .compliance => |d| d,
    };

    // `resolve(ctx)` = `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST)`
    // (`API.jl:454-457`), i.e. PRESERVE_ALL: every manifest entry held at the
    // version it records. That is exactly the tier that turns a tightened
    // bound into the conflict the catch below exists for.
    report.resolve = resolve_mod.run(arena, io, .{
        .project_file = opts.project_file,
        // The bytes just written, handed over rather than read back — the seam
        // `add`/`rm` use (`resolve.zig:245-247`). `serialize` returns the
        // original source when nothing changed, so the resolve always sees
        // exactly what is on disk.
        .project_source = try proj.serialize(arena),
        .manifest_file = opts.manifest_file,
        .registry_depot = reg,
        .registry_name = opts.registry_name,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
        .tier = .all,
        .build_manifest = true,
        .write_to = opts.manifest_file,
        .depots = opts.depots,
        .fixups = opts.fixups,
        .diagnostic = opts.diagnostic,
    }) catch |err| switch (err) {
        // `catch e; if e isa ResolverError || e isa ResolverTimeoutError`
        // (`:1535-1542`). Reported, not raised.
        error.NoSolution, error.SingletonConflict => {
            report.resolve_failed = true;
            return report;
        },
        // `else rethrow()`.
        else => |e| return e,
    };
    return report;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    td: std.testing.TmpDir,
    base: []const u8,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn init(body: []const u8) !Fixture {
        var f: Fixture = .{ .td = testing.tmpDir(.{}), .base = "" };
        try f.td.dir.writeFile(testing.io, .{ .sub_path = "Project.toml", .data = body });
        return f;
    }
    fn deinit(self: *Fixture) void {
        self.td.cleanup();
    }
    fn projectFile(self: *Fixture, g: Allocator) ![]const u8 {
        const base = self.buf[0..try self.td.dir.realPath(testing.io, &self.buf)];
        return std.fs.path.join(g, &.{ base, "Project.toml" });
    }
    fn read(self: *Fixture, g: Allocator) ![]const u8 {
        return self.td.dir.readFileAlloc(testing.io, "Project.toml", g, .limited(1 << 20));
    }
};

const two_deps =
    \\name = "Env"
    \\
    \\[deps]
    \\A = "00000000-0000-0000-0000-000000000001"
    \\B = "00000000-0000-0000-0000-000000000002"
    \\
    \\[compat]
    \\A = "1.2"
    \\julia = "1.9"
    \\
;

test "compat sets, replaces and deletes, and normalises Julia" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var f = try Fixture.init(two_deps);
    defer f.deinit();
    const pf = try f.projectFile(g);
    const opts: Options = .{
        .project_file = pf,
        .manifest_file = "/nonexistent",
        // No registry here: these fixtures name unregistered packages,
        // and the edit is what is under test.
        .resolve = .skip,
    };

    // New entry. `[compat]` keeps `_project_key_order` INSIDE the section, so
    // the write is `A`, `B`, `julia` — a plain sort would agree here, but see
    // the `version`-vs-`julia` case in project_model.sh.
    const r1 = try run(g, testing.io, opts, "B", "^2.1");
    try testing.expect(r1.project_written);
    try testing.expectEqualStrings("^2.1", r1.spec.?);
    try testing.expect(r1.existing == null);

    // `Julia` -> `julia`, replacing the existing bound.
    const r2 = try run(g, testing.io, opts, "Julia", "1.10");
    try testing.expectEqualStrings("julia", r2.name);
    try testing.expectEqualStrings("1.9", r2.existing.?);
    try testing.expectEqualStrings(
        \\name = "Env"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[compat]
        \\A = "1.2"
        \\B = "^2.1"
        \\julia = "1.10"
        \\
    , try f.read(g));

    // No spec deletes.
    const r3 = try run(g, testing.io, opts, "A", null);
    try testing.expect(r3.spec == null);
    try testing.expectEqualStrings("1.2", r3.existing.?);
    // An empty string deletes too, and deleting what is not there is a
    // success, not an error.
    const r4 = try run(g, testing.io, opts, "B", "");
    try testing.expect(r4.spec == null);
    const r5 = try run(g, testing.io, opts, "B", "");
    try testing.expect(!r5.project_written);
    try testing.expect(r5.existing == null);
}

test "compat: a bound that means the same thing does not touch the file" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // Comments and non-canonical spacing survive only because nothing is
    // written; this is the assertion that would fail if `setCompat` dirtied
    // the model on string inequality.
    var f = try Fixture.init(
        \\# hand-written, and it stays that way
        \\[deps]
        \\A   = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\A = "1.2"
        \\
    );
    defer f.deinit();
    const pf = try f.projectFile(g);
    const opts: Options = .{
        .project_file = pf,
        .manifest_file = "/nonexistent",
        // No registry here: these fixtures name unregistered packages,
        // and the edit is what is under test.
        .resolve = .skip,
    };
    const before = try f.read(g);

    // Literally the same string, and the surrounding quotes Pkg strips.
    try testing.expect(!(try run(g, testing.io, opts, "A", "\"1.2\"")).project_written);
    // A different SPELLING of the same VersionSpec: `^` is the default, and
    // `strip` removes no whitespace so `" 1.2 "` is stored verbatim — Pkg
    // records both in memory and rewrites the file for neither.
    try testing.expect(!(try run(g, testing.io, opts, "A", "^1.2")).project_written);
    try testing.expect(!(try run(g, testing.io, opts, "A", " 1.2 ")).project_written);
    try testing.expectEqualStrings(before, try f.read(g));

    // A different SET does write.
    try testing.expect((try run(g, testing.io, opts, "A", "1.3")).project_written);
}

test "compat refuses a non-dependency, a split weakdep, and a bad spec" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var f = try Fixture.init(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\W = "00000000-0000-0000-0000-00000000000f"
        \\
        \\[weakdeps]
        \\W = "00000000-0000-0000-0000-00000000000f"
        \\
        \\[extensions]
        \\Ext = "W"
        \\
    );
    defer f.deinit();
    const pf = try f.projectFile(g);
    var refusal: ?[]const u8 = null;
    const opts: Options = .{
        .project_file = pf,
        .manifest_file = "/nonexistent",
        // No registry here: these fixtures name unregistered packages,
        // and the edit is what is under test.
        .resolve = .skip,
        .refusal = &refusal,
    };
    const before = try f.read(g);

    try testing.expectError(Error.NotADependency, run(g, testing.io, opts, "Nope", "1"));
    try testing.expectEqualStrings("No package named Nope in current Project", refusal.?);
    // Only the exact spelling `Julia` is aliased — and the message names the
    // NORMALISED spelling, which for anything but `Julia` is what was given.
    try testing.expectError(Error.NotADependency, run(g, testing.io, opts, "JULIA", "1"));
    try testing.expectEqualStrings("No package named JULIA in current Project", refusal.?);
    // W is in [deps] in the FILE, but read_project's deps∩weakdeps split moved
    // it out of `deps`, and Pkg's haskey test therefore fails. Corner 3.
    try testing.expectError(Error.NotADependency, run(g, testing.io, opts, "W", "1"));
    // `1-2` is registry grammar; [compat] uses semver_spec. The message quotes
    // the STRIPPED spec, so the surrounding quotes never reach it.
    try testing.expectError(Error.InvalidSpec, run(g, testing.io, opts, "A", "\"1-2\""));
    try testing.expectEqualStrings("invalid compat version specifier \"1-2\"", refusal.?);

    // Every one of those left the file untouched.
    try testing.expectEqualStrings(before, try f.read(g));
}
