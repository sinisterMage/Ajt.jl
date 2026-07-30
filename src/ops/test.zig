//! `ajt test` — run a package's `test/runtests.jl` in a child Julia, inside a
//! sandbox environment built from its test dependencies.
//!
//! Ports `Pkg.API.test` (`API.jl:529-565`) and `Operations.test`
//! (`Operations.jl:2387-2544`), plus `gen_test_code` (`:2113-2121`) and
//! `gen_subprocess_flags` (`:2136-2156`).
//!
//! ## The environment the tests run in
//!
//! Two shapes, and the precedence is `isfile(projectfile_path(testdir))`
//! (`:2468`) — nothing else is consulted:
//!
//!   * the package ships **`test/Project.toml`** → that file IS the sandbox
//!     project. Pkg passes `sandbox_project_override = nothing` and lets
//!     `sandbox` read it (`:2469`, `Operations.jl:2233-2235`), which is also
//!     what `ops/sandbox.zig` does when it finds one.
//!   * otherwise → `gen_target_project(ctx, pkg, source_path, "test")`
//!     (`:2474`): the package's own `[deps]` and `[sources]`, plus each name in
//!     `targets["test"]` looked up in **`[extras]` first, then `[weakdeps]`**,
//!     with `[compat]` carried for whatever ended up in the result. A name in
//!     neither list is `pkgerror("`$name` declared as a `test` dependency, but
//!     no such entry in `extras` or `weakdeps`")`.
//!
//! Either way the package under test is force-added to the sandbox project's
//! `[deps]` (`Operations.jl:2283`) and injected into the sandbox manifest as a
//! `path` entry pointing at its source (`sandbox_preserve`, `:2175-2180`) —
//! that is the whole of "the package under test is `dev`'d into it". Nothing is
//! copied: the tests import the working tree, so an edit is visible to the next
//! `ajt test` with no reinstall.
//!
//! The rest of the environment — the pruned parent manifest, the merged
//! preferences, `JULIA_LOAD_PATH="@:<tmp>"` with `JULIA_PROJECT` unset — is
//! `ops/sandbox.zig`, shared verbatim with `ajt build`. Its header is the place
//! to read about all of it. The one option `test` needs and `build` does not is
//! `Options.stdlibs`: a `[targets] test` almost always names `Test`, `[extras]`
//! are never resolved into an environment's manifest, and Pkg fills the gap
//! with its unconditional sandbox resolve. See that header.
//!
//! ## What actually runs
//!
//! ```julia
//! $(Base.load_path_setup_code(false))
//! cd("<source>/test")
//! append!(empty!(ARGS), ["…"])     # test_args
//! include("<source>/test/runtests.jl")
//! ```
//!
//! in `julia --threads=… <flags> --eval <code>` (`:2494-2495`). `runtests.jl`
//! is the only entry point; a package without one is an error naming it, not a
//! silent pass (`:2421-2427`).
//!
//! ## Three things this does differently from `ajt build`
//!
//! **1. A failure does not stop the run.** `build_versions` aborts on the first
//! failing script because the next package's build often consumes its output;
//! `test` collects `pkgs_errored` and raises once at the end (`:2430`,
//! `:2525-2543`), because two test suites are independent and a user who asked
//! for both wants both answers. Do not conflate the two.
//!
//! **2. The child's output is not captured.** `subprocess_handler`
//! (`:2547-2572`) hands the child the parent's own stdout and stderr, so a
//! suite prints as it runs. `child.runStreamed` is that; `child.run`, which
//! `build` uses because a `build.log` is a file, would hold ten minutes of
//! output until the process exited.
//!
//! **3. The exit status is the product.** `Pkg.test` raises, so `julia -e
//! 'Pkg.test()'` exits non-zero; `ajt test` exits 1 with the same message. A CI
//! job's entire contract with this command is that number.
//!
//! ## What is deliberately not here
//!
//! `Operations.test` opens with `Pkg.instantiate(ctx; allow_autoprecomp =
//! false)` (`:2395`) and precompiles the sandbox before running (`:2487-2490`).
//! Neither happens here, for the same reason `ajt build` does not instantiate:
//! an implicit download inside a verb the user typed as "test" is a surprise,
//! and `ajt instantiate --frozen` is one command away. Julia still precompiles
//! on demand inside the test child, so the tests run either way — the output
//! just arrives in the child's stderr instead of in a progress bar.
//!
//! Pkg's workspace fast path (`:2434-2464`), which activates a test directory
//! that is already a workspace member instead of building a sandbox, is not
//! reproduced; `ajt` has no workspace support anywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const verify = @import("verify.zig");
const sandbox = @import("sandbox.zig");
const child = @import("child.zig");

pub const Uuid = manifest_mod.Uuid;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

pub const Error = error{
    /// No project file at `env_path`, or it would not parse.
    NoProject,
} || sandbox.Error || Allocator.Error || Io.Cancelable;

// Everything Pkg raises through `pkgerror` — an unresolvable name, a missing
// `test/runtests.jl`, a suite that errored — comes back as `Report.failure`
// instead. All three are the same class of thing to a caller (a sentence, and
// exit 1), and only the last of them can carry the information a user needs,
// so making two of them Zig errors would split one contract in half.

/// `coverage` (`Operations.jl:2137-2144`), which is a `Bool` OR a string.
pub const Coverage = union(enum) {
    /// `false` → `--code-coverage=none`.
    off,
    /// `true` → `--code-coverage=@<source_path>`, and note the source path is
    /// the package ROOT rather than its `src/`, "so `ext` etc. is included"
    /// (`:2138`).
    on,
    /// A string is passed through verbatim, so `--coverage=user` and
    /// `--coverage=@/some/dir` both work exactly as they do in Pkg.
    arg: []const u8,
};

pub const Options = struct {
    /// The environment: a directory, or a project file directly. Probed by
    /// `verify`, which is where that probe lives.
    env_path: []const u8,
    manifest_file: ?[]const u8 = null,
    stack: depot_mod.Stack,

    /// Names (or UUIDs) to test. Empty means the project's own package
    /// (`API.jl:544-546`).
    packages: []const []const u8 = &.{},

    julia_exe: ?[]const u8 = null,
    julia_prefix: ?[]const u8 = null,
    julia_version: ?[]const u8 = null,

    /// The parent environment the test child inherits, minus what the sandbox
    /// pins. A test suite legitimately needs `PATH`, `HOME` and whatever else
    /// the user's shell exports, so supply it.
    environ: ?*const std.process.Environ.Map = null,

    // --- gen_subprocess_flags (`Operations.jl:2136-2156`) ------------------
    //
    // Every one of these describes the JULIA THAT CALLED `Pkg.test`, through
    // `Base.JLOptions()` or `Base.have_color`. `ajt` is not a Julia and has no
    // `JLOptions`, so each is stated by the caller instead of guessed: the
    // `Ajt.jl` wrapper passes the running session's values, and the bare CLI
    // defaults to what a non-interactive session reports.
    coverage: Coverage = .off,
    /// `Base.have_color === nothing ? "auto" : have_color ? "yes" : "no"`.
    color: []const u8 = "auto",
    /// `JLOptions().depwarn == 2 ? "error" : "yes"`. Note there is no "no":
    /// Pkg turns deprecation warnings ON for a test run whatever the parent had.
    depwarn: []const u8 = "yes",
    /// `Bool(JLOptions().can_inline) ? "yes" : "no"`.
    inlining: []const u8 = "yes",
    /// `JLOptions().startupfile == 1 ? "yes" : "no"`.
    startup_file: bool = false,
    /// `("none", "user", "all")[JLOptions().malloc_log + 1]`.
    track_allocation: []const u8 = "none",
    /// `get_threads_spec()` (`:2124-2134`): `ENV["JULIA_NUM_THREADS"]` when set,
    /// else the parent's `nthreads(:default)[,nthreads(:interactive)]`. Null
    /// omits `--threads` entirely, which leaves the child on Julia's own
    /// default — identical to Pkg whenever `JULIA_NUM_THREADS` is what decided
    /// it, and different only for a parent started with `-t N` on its command
    /// line, which is a fact no separate process can read.
    threads: ?[]const u8 = null,
    /// Appended AFTER the flags above, exactly as `$(julia_args)` is
    /// (`:2154`), so a repeated option overrides — `--julia-args
    /// --check-bounds=no` really does undo the `--check-bounds=yes` Pkg puts
    /// there.
    julia_args: []const []const u8 = &.{},
    /// `append!(empty!(ARGS), …)` inside the test process (`:2118`).
    test_args: []const []const u8 = &.{},

    /// Registry access for the sandbox resolve. Null skips it — see
    /// `ops/sandbox.zig`'s header for exactly what that does and does not
    /// catch, and `Options.stdlibs` there for the part `test` cannot skip.
    registry_depot: ?[]const u8 = null,
    registry_name: []const u8 = "General",
    stdlib_dir: ?[]const u8 = null,

    /// Where the sandbox is created. Null means `/tmp`.
    tmp_dir: ?[]const u8 = null,
    /// Leave the sandbox behind instead of deleting it. The report names it
    /// either way; this is what makes "why could my suite not load Foo" a
    /// question with an answer.
    keep_sandbox: bool = false,

    /// Build the sandbox and report it; start no child.
    dry_run: bool = false,
};

/// One package's test run.
pub const Run = struct {
    name: []const u8,
    uuid: Uuid,
    /// The package root — `source_path`, not `src/` and not `test/`.
    source_path: []const u8,
    /// `<source>/test/runtests.jl`.
    test_file: []const u8,
    /// The temp environment. Still on disk only under `keep_sandbox`.
    sandbox_dir: []const u8 = "",
    /// The package ships its own `test/Project.toml`, so no target project was
    /// generated from `[extras]`/`[targets]`.
    has_test_project: bool = false,
    /// Entries in the sandbox manifest, and how many of them the stdlib fill
    /// contributed.
    entries: usize = 0,
    filled: usize = 0,
    /// Test dependencies the sandbox could not supply — see
    /// `sandbox.Env.missing`. The suite is about to fail to load these.
    missing: []const []const u8 = &.{},
    /// The sandbox resolve fell through to a full re-resolve.
    reresolved: bool = false,

    ms: f64 = 0,
    ok: bool = false,
    /// Set when the child ran and exited normally.
    exit_code: ?u8 = null,
    /// Set when a signal ended it instead.
    signal: ?std.posix.SIG = null,
};

pub const Report = struct {
    project_file: []const u8 = "",
    manifest_file: []const u8 = "",
    julia: []const u8 = "",
    depot_path: []const u8 = "",
    /// In the order they were named.
    runs: []const Run = &.{},
    /// Pkg's `pkgerror` message, already composed. Null on success.
    failure: ?[]const u8 = null,

    pub fn ok(self: Report) bool {
        return self.failure == null;
    }
};

/// `Pkg.test` end to end.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, opts: Options) Error!Report {
    var rep: Report = .{};

    const before = verify.run(arena, gpa, io, .{
        .env_path = opts.env_path,
        .manifest_file = opts.manifest_file,
        .stack = opts.stack,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    }) catch return error.NoProject;
    rep.project_file = before.project_file;
    rep.manifest_file = before.manifest_file;

    const depot = opts.stack.writeDepot();
    // `map(abspath, DEPOT_PATH)` (`base/loading.jl:2982`). Absolute because the
    // generated code's very next statement is `cd(<testdir>)`, which would
    // re-anchor a relative depot entry to the package's `test/` directory.
    const stack: depot_mod.Stack = .{ .entries = try absDepots(arena, io, opts.stack) };
    rep.depot_path = try joinDepots(arena, stack);
    rep.julia = try juliaExe(arena, io, opts);

    const project_src = Io.Dir.cwd().readFileAlloc(io, rep.project_file, arena, .limited(max_project_bytes)) catch
        return error.NoProject;
    var proj = project_mod.parse(arena, project_src, .{ .file = rep.project_file }, null) catch
        return error.NoProject;

    var manifest: manifest_mod.Manifest = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, rep.manifest_file, arena, .limited(max_manifest_bytes)) catch |err| switch (err) {
            error.FileNotFound => break :blk manifest_mod.Manifest{},
            else => return error.NoProject,
        };
        break :blk manifest_mod.parse(arena, src, null) catch return error.NoProject;
    };

    const sl = try loadStdlibs(arena, io, opts);

    // --- which packages (`API.jl:544-551`) ---------------------------------
    var targets: std.ArrayList(Target) = .empty;
    if (opts.packages.len == 0) {
        // `ctx.env.pkg === nothing` is `name === nothing || uuid === nothing`,
        // and the message names the file rather than the package because there
        // is no package to name.
        const name = proj.name orelse return pkgerror(&rep, no_pkg_message);
        const uuid = proj.uuid orelse return pkgerror(&rep, no_pkg_message);
        try targets.append(arena, .{ .name = name, .uuid = uuid });
    } else {
        var unresolved: std.ArrayList([]const u8) = .empty;
        for (opts.packages) |spec| {
            if (try resolveSpec(arena, spec, &proj, &manifest)) |t| {
                try targets.append(arena, t);
            } else try unresolved.append(arena, spec);
        }
        if (unresolved.items.len != 0) {
            return pkgerror(&rep, try unresolvedMessage(arena, unresolved.items));
        }
    }

    // --- do they all have a test/runtests.jl (`:2413-2427`) ----------------
    //
    // Checked for EVERY named package before ANY of them runs. A user who
    // typed three names and misspelled the third should not watch two suites
    // pass before being told.
    const runs = try arena.alloc(Run, targets.items.len);
    var missing_runtests: std.ArrayList([]const u8) = .empty;
    for (targets.items, runs) |t, *r| {
        const source = try sourcePath(arena, io, t, &proj, &manifest, rep.project_file, rep.manifest_file, opts, sl.dir) orelse
            // `source_path` returning `nothing` — no tree hash, no path, no
            // stdlib of that name. Pkg would `MethodError` on `testfile(nothing)`;
            // reporting it as "no test/runtests.jl" is the same conclusion
            // reached politely.
            "";
        r.* = .{
            .name = t.name,
            .uuid = t.uuid,
            .source_path = source,
            .test_file = if (source.len == 0) "" else try fspath.join(arena, &.{ source, "test", "runtests.jl" }),
        };
        if (r.test_file.len == 0 or !isFile(io, r.test_file)) try missing_runtests.append(arena, t.name);
    }
    if (missing_runtests.items.len != 0) {
        rep.runs = runs;
        return pkgerror(&rep, try missingRuntestsMessage(arena, missing_runtests.items));
    }

    // --- run them (`:2431-2503`) -------------------------------------------
    var errored: std.ArrayList(*const Run) = .empty;
    for (runs) |*r| {
        try one(gpa, arena, io, opts, &rep, stack, depot, &sl, r);
        // NOT a break. See the module header: `test` collects failures where
        // `build` aborts on the first one.
        if (!r.ok and !opts.dry_run) try errored.append(arena, r);
    }
    rep.runs = runs;

    if (errored.items.len != 0) rep.failure = try erroredMessage(arena, errored.items);
    return rep;
}

/// One package: sandbox, child, verdict.
fn one(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    rep: *Report,
    /// The ABSOLUTISED depot stack.
    stack: depot_mod.Stack,
    depot: ?depot_mod.Depot,
    sl: *const Stdlibs,
    r: *Run,
) Error!void {
    const testdir = try fspath.join(arena, &.{ r.source_path, "test" });

    var env = try sandbox.create(gpa, arena, io, .{
        .project_file = rep.project_file,
        .manifest_file = rep.manifest_file,
        .target_name = r.name,
        .target_uuid = r.uuid,
        .source_path = r.source_path,
        .sandbox_path = testdir,
        .target = "test",
        .tmp_parent = opts.tmp_dir,
        // `Base.LOAD_PATH`'s `@v#.#` for the preferences merge — see
        // `sandbox.writePreferences`.
        .extra_pref_envs = try sharedEnvDir(arena, depot, opts.julia_version),
        // The one thing a test sandbox cannot do without. `[extras]` never
        // reach an environment's manifest, so `Test` has no entry to preserve.
        .stdlibs = if (sl.set) |*s| s else null,
        .resolve = if (opts.registry_depot) |rd| .{
            .registry_depot = rd,
            .registry_name = opts.registry_name,
            .depots = opts.stack,
            .julia_prefix = opts.julia_prefix,
            .stdlib_dir = sl.dir,
        } else null,
    });
    // `mktempdir() do … end` deletes on the way out (`Operations.jl:2225`), and
    // so does this — unless the caller asked to keep it, in which case the
    // report's `sandbox` field is the only record of where it went.
    defer if (!opts.keep_sandbox) env.destroy(io);

    r.sandbox_dir = env.dir;
    r.has_test_project = env.has_sandbox_project;
    r.entries = env.entries;
    r.filled = env.filled;
    r.missing = env.missing;
    r.reresolved = env.reresolved;
    if (opts.dry_run) return;

    // `withenv(fn, "JULIA_LOAD_PATH" => "@:$(tmp)", "JULIA_PROJECT" => nothing)`
    // (`Operations.jl:2311`), plus the depot the run is pinned to.
    var environ = try child.environ(gpa, opts.environ, &.{
        .{ .name = "JULIA_DEPOT_PATH", .value = rep.depot_path },
        .{ .name = "JULIA_LOAD_PATH", .value = env.load_path },
        .{ .name = "JULIA_PROJECT", .value = null },
    });
    defer environ.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, rep.julia);
    if (opts.threads) |t| try argv.append(arena, try std.fmt.allocPrint(arena, "--threads={s}", .{t}));
    try appendSubprocessFlags(arena, &argv, opts, r.source_path);
    try argv.append(arena, "--eval");
    try argv.append(arena, try genTestCode(arena, stack, opts, r.test_file));

    const out = child.runStreamed(io, argv.items, &environ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            // Not "the tests failed" — the child never started. Said plainly,
            // because a missing `julia` and a failing suite are two different
            // problems and one of them is not in the package.
            r.ok = false;
            std.debug.print("ajt test: could not start {s} for {s} ({s})\n", .{ rep.julia, r.name, @errorName(err) });
            return;
        },
    };
    r.ms = out.ms;
    r.exit_code = out.exitCode();
    r.signal = out.signal();
    r.ok = out.succeeded();
}

// ---------------------------------------------------------------------------
// The child's command line
// ---------------------------------------------------------------------------

/// `gen_subprocess_flags(source_path; coverage, julia_args)`
/// (`Operations.jl:2136-2156`), in order.
///
/// The order is not cosmetic: `julia_args` comes last so a caller can override
/// any of the fixed flags, which is the documented way to run a suite with
/// `--check-bounds=no`.
fn appendSubprocessFlags(
    arena: Allocator,
    argv: *std.ArrayList([]const u8),
    opts: Options,
    source_path: []const u8,
) Allocator.Error!void {
    const coverage_arg: []const u8 = switch (opts.coverage) {
        .off => "none",
        .on => try std.fmt.allocPrint(arena, "@{s}", .{source_path}),
        .arg => |a| a,
    };
    try argv.appendSlice(arena, &.{
        try std.fmt.allocPrint(arena, "--code-coverage={s}", .{coverage_arg}),
        try std.fmt.allocPrint(arena, "--color={s}", .{opts.color}),
        // Fixed in Pkg, and deliberately so: a test run checks bounds and warns
        // about method overwrites whatever the parent session was doing.
        "--check-bounds=yes",
        "--warn-overwrite=yes",
        try std.fmt.allocPrint(arena, "--depwarn={s}", .{opts.depwarn}),
        try std.fmt.allocPrint(arena, "--inline={s}", .{opts.inlining}),
        try std.fmt.allocPrint(arena, "--startup-file={s}", .{if (opts.startup_file) "yes" else "no"}),
        try std.fmt.allocPrint(arena, "--track-allocation={s}", .{opts.track_allocation}),
    });
    try argv.appendSlice(arena, opts.julia_args);
}

/// `gen_test_code(source_path; test_args)` (`Operations.jl:2113-2121`).
///
/// ```julia
/// $(Base.load_path_setup_code(false))
/// cd($(repr(dirname(test_file))))
/// append!(empty!(ARGS), $(repr(test_args.exec)))
/// include($(repr(test_file)))
/// ```
///
/// `load_path_setup_code(false)` emits ONLY the `DEPOT_PATH`/`DL_LOAD_PATH`
/// pair (`base/loading.jl:2980-2998`) — the `false` suppresses the `LOAD_PATH`
/// block, because the sandbox has already put the right value in
/// `JULIA_LOAD_PATH` and re-emitting the parent's would undo it. It also ends
/// in a newline, so the interpolation leaves a BLANK LINE before `cd`;
/// reproduced, since this string is what a `--eval` transcript shows.
///
/// `repr(test_args.exec)` is Julia's own `Vector{String}` literal: `String[]`
/// when empty, `["a", "b"]` otherwise. An empty `[]` would be a
/// `Vector{Any}` and `append!` onto `ARGS::Vector{String}` would still work,
/// but the transcript would not be Pkg's.
fn genTestCode(
    arena: Allocator,
    /// Already absolutised — `map(abspath, DEPOT_PATH)`.
    stack: depot_mod.Stack,
    opts: Options,
    test_file: []const u8,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(arena, "append!(empty!(Base.DEPOT_PATH), [");
    for (stack.entries, 0..) |d, i| {
        if (i != 0) try buf.appendSlice(arena, ", ");
        try appendJuliaString(arena, &buf, d);
    }
    try buf.appendSlice(arena, "])\n");
    // Emitted empty: `DL_LOAD_PATH` is a global only a runtime `push!`
    // populates, and Ajt has no parent Julia session to read one from.
    try buf.appendSlice(arena, "append!(empty!(Base.DL_LOAD_PATH), String[])\n");
    try buf.append(arena, '\n');

    try buf.appendSlice(arena, "cd(");
    try appendJuliaString(arena, &buf, fspath.dirname(test_file) orelse ".");
    try buf.appendSlice(arena, ")\n");

    try buf.appendSlice(arena, "append!(empty!(ARGS), ");
    if (opts.test_args.len == 0) {
        try buf.appendSlice(arena, "String[]");
    } else {
        try buf.append(arena, '[');
        for (opts.test_args, 0..) |a, i| {
            if (i != 0) try buf.appendSlice(arena, ", ");
            try appendJuliaString(arena, &buf, a);
        }
        try buf.append(arena, ']');
    }
    try buf.appendSlice(arena, ")\n");

    try buf.appendSlice(arena, "include(");
    try appendJuliaString(arena, &buf, test_file);
    try buf.appendSlice(arena, ")\n");
    return buf.items;
}

/// Julia string-literal syntax. `\` and `"` are the two characters a path can
/// contain that would end the literal; `$` is interpolation, which turns a
/// directory named `$(rm("-rf"))` into an evaluation.
fn appendJuliaString(arena: Allocator, buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try buf.append(arena, '"');
    for (s) |c| switch (c) {
        '\\' => try buf.appendSlice(arena, "\\\\"),
        '"' => try buf.appendSlice(arena, "\\\""),
        '$' => try buf.appendSlice(arena, "\\$"),
        else => try buf.append(arena, c),
    };
    try buf.append(arena, '"');
}

// ---------------------------------------------------------------------------
// Which packages
// ---------------------------------------------------------------------------

const Target = struct {
    name: []const u8,
    uuid: Uuid,
};

/// `project_resolve!` → `project_deps_resolve!` → `manifest_resolve!` →
/// `ensure_resolved` (`API.jl:547-550`, `Types.jl:1127-1174`), collapsed into
/// one lookup because all four of them only ever fill in the half of a
/// name/uuid pair that was missing.
///
/// The order matters and the last step is the surprising one: `manifest_resolve!`
/// searches the WHOLE manifest, so `ajt test Foo` accepts a package that is
/// nobody's direct dependency. That is not an oversight in Pkg and it is not
/// symmetric with its neighbours — `Pkg.pin` stops at `project_deps_resolve!`
/// and refuses a transitive dependency, while `Pkg.free` and this go on to the
/// manifest. Measured, by running `Pkg.test` on a manifest-only entry: it
/// resolves, sandboxes and runs.
///
/// `ensure_resolved` is then only a report: anything still missing a uuid here
/// comes back null and the caller composes Pkg's message.
fn resolveSpec(
    arena: Allocator,
    spec: []const u8,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
) Allocator.Error!?Target {
    // A uuid positional is `pkg> test`'s grammar (`parse_package`), not the
    // API's — `Pkg.test(["<uuid>"])` builds `PackageSpec(name = "<uuid>")` and
    // fails to resolve it. Accepted here for the same reason `ajt status`
    // accepts one, and noted in `Ajt.DIFFERENCES[:test]`.
    if (Uuid.parse(spec)) |u| {
        if (proj.uuid) |p| {
            if (std.mem.eql(u8, &p.bytes, &u.bytes)) return .{ .name = proj.name orelse spec, .uuid = u };
        }
        if (manifest.findByUuid(u)) |e| return .{ .name = e.name, .uuid = e.uuid };
        return null;
    } else |_| {}

    // `project_resolve!` (`Types.jl:1127-1137`): the environment's own package.
    if (proj.name) |n| {
        if (std.mem.eql(u8, n, spec)) {
            if (proj.uuid) |u| return .{ .name = n, .uuid = u };
        }
    }
    // `project_deps_resolve!` (`:1140-1155`).
    if (proj.deps.get(spec)) |u| return .{ .name = try arena.dupe(u8, spec), .uuid = u };
    // `manifest_resolve!` (`:1158-1174`). Julia takes the entry only when the
    // name is UNIQUE in the manifest (`length(uuids[pkg.name]) == 1`); two
    // entries sharing a name leave it unresolved and `ensure_resolved` prints
    // "… in manifest but not in project".
    var found: ?Target = null;
    for (manifest.entries) |e| {
        if (!std.mem.eql(u8, e.name, spec)) continue;
        if (found != null) return null;
        found = .{ .name = e.name, .uuid = e.uuid };
    }
    return found;
}

const Stdlibs = struct {
    set: ?stdlibs_mod.Set = null,
    /// `Types.stdlib_dir()`, once it is known.
    dir: ?[]const u8 = null,
};

/// The installation's stdlibs, for the sandbox fill and for `source_path`'s
/// last branch.
///
/// A prefix that cannot be read is not fatal here — it costs the fill, which
/// surfaces as `Run.missing` naming `Test`, which is a far better error than a
/// refusal to run at all on a machine where `--julia-prefix` was not passed.
fn loadStdlibs(arena: Allocator, io: Io, opts: Options) Allocator.Error!Stdlibs {
    var out: Stdlibs = .{};
    if (opts.stdlib_dir) |d| out.dir = d;
    const prefix = opts.julia_prefix orelse return out;
    const set = stdlibs_mod.load(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = opts.julia_version,
    }) catch return out;
    out.set = set;
    if (out.dir == null) out.dir = set.dir;
    return out;
}

/// `source_path(manifest_file, pkg, julia_version)` (`Operations.jl:48-53`)
/// after `Operations.test`'s metadata loop (`:2398-2411`) has filled the spec
/// in from the manifest.
///
/// Tree hash first, then a manifest `path`, then the stdlib directory — and the
/// project's own package before any of them, since `:2400-2402` gives it
/// `dirname(ctx.env.project_file)` rather than consulting the manifest at all.
///
/// `find_installed` returns the WOULD-BE path when nothing is unpacked
/// (`:31-41`), so an uninstalled package reaches the `test/runtests.jl` check
/// and is reported as not providing one. That is Pkg's behaviour and not a
/// rounding of it: `Pkg.test` instantiates first, so it never gets here.
fn sourcePath(
    arena: Allocator,
    io: Io,
    t: Target,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
    project_file: []const u8,
    manifest_file: []const u8,
    opts: Options,
    stdlib_dir: ?[]const u8,
) Allocator.Error!?[]const u8 {
    // `Types.is_project_uuid(ctx.env, pkg.uuid)` wins over any manifest entry
    // (`:2400-2402`). It matters: a package's own manifest carries its root as
    // a `path = "."` entry, and while resolving that against
    // `dirname(manifest_file)` happens to give the same directory, a project
    // whose `manifest` key redirects elsewhere would land somewhere else
    // entirely.
    if (proj.uuid) |u| {
        if (std.mem.eql(u8, &u.bytes, &t.uuid.bytes)) return fspath.dirname(project_file) orelse ".";
    }

    const e = manifest.findByUuid(t.uuid) orelse {
        // Not in the manifest and not the project: a stdlib named directly.
        // `is_or_was_stdlib(pkg.uuid) ? Types.stdlib_path(pkg.name) : nothing`
        // (`Operations.jl:48-53`).
        const sd = stdlib_dir orelse return null;
        return try fspath.join(arena, &.{ sd, t.name });
    };

    if (e.tree_hash) |h| {
        const found = depot_mod.findInstalled(arena, io, opts.stack, e.name, e.uuid, h) catch return null;
        return found.path;
    }
    if (e.path) |p| {
        const dir = fspath.dirname(manifest_file) orelse ".";
        return try fspath.resolve(arena, &.{ dir, p });
    }
    const sd = stdlib_dir orelse return null;
    return try fspath.join(arena, &.{ sd, e.name });
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

const no_pkg_message = "The Project.toml of the package being tested must have a name and a UUID entry";

/// Pkg raises; this returns a report whose `ok()` is false and whose `failure`
/// is the sentence Pkg would have raised with. The CLI prints it and exits 1,
/// so the observable behaviour is the same.
fn pkgerror(rep: *Report, msg: []const u8) Report {
    rep.failure = msg;
    return rep.*;
}

/// `ensure_resolved`'s message (`Types.jl:1235-1259`), for the case that
/// matters: a name in neither the project nor the manifest.
///
/// Pkg's version also prints fuzzy-matched suggestions from
/// `available_names(ctx)`. Not reproduced — see `Ajt.DIFFERENCES[:test]`.
fn unresolvedMessage(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "The following package names could not be resolved:");
    for (names) |n| {
        try buf.appendSlice(arena, "\n * ");
        try buf.appendSlice(arena, n);
        try buf.appendSlice(arena, " (not found in project or manifest)");
    }
    return buf.items;
}

/// `:2421-2427`. Singular/plural on the WORD, comma-joined names, and the
/// backticks around the filename are Pkg's.
fn missingRuntestsMessage(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, if (names.len == 1) "Package " else "Packages ");
    for (names, 0..) |n, i| {
        if (i != 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, n);
    }
    try buf.appendSlice(arena, " did not provide a `test/runtests.jl` file");
    return buf.items;
}

/// `:2525-2543`, including `reason(p)` (`:2526-2534`).
///
/// `reason` is empty for the ordinary case — a suite that threw exits 1 — and
/// says something only when the exit code is *not* 1 or a signal ended the
/// process. That asymmetry is the point: "exit code: 1" would be noise on every
/// failing test run, and "received signal: KILL" is the one line that tells a
/// user their suite was OOM-killed rather than wrong.
fn erroredMessage(arena: Allocator, errored: []const *const Run) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (errored.len == 1) {
        try buf.appendSlice(arena, "Package ");
        try buf.appendSlice(arena, errored[0].name);
        try buf.appendSlice(arena, " errored during testing");
        try appendReason(arena, &buf, errored[0]);
        return buf.items;
    }
    try buf.appendSlice(arena, "Packages errored during testing:");
    for (errored) |r| {
        // U+2022, as Pkg writes it.
        try buf.appendSlice(arena, "\n• ");
        try buf.appendSlice(arena, r.name);
        try appendReason(arena, &buf, r);
    }
    return buf.items;
}

fn appendReason(arena: Allocator, buf: *std.ArrayList(u8), r: *const Run) Allocator.Error!void {
    if (r.signal) |s| {
        try buf.appendSlice(arena, " (received signal: ");
        try buf.appendSlice(arena, try signalName(arena, s));
        try buf.append(arena, ')');
        return;
    }
    if (r.exit_code) |c| {
        if (c != 1) try buf.appendSlice(arena, try std.fmt.allocPrint(arena, " (exit code: {d})", .{c}));
    }
}

/// `signal_name` (`:2506-2522`): six names, and the raw number for anything
/// else. `Base.SIGHUP` and friends are the only ones Pkg spells out, so a
/// suite killed by `SIGSEGV` reports `11` on both sides.
fn signalName(arena: Allocator, s: std.posix.SIG) Allocator.Error![]const u8 {
    return switch (s) {
        .HUP => "HUP",
        .INT => "INT",
        .QUIT => "QUIT",
        .KILL => "KILL",
        .PIPE => "PIPE",
        .TERM => "TERM",
        else => try std.fmt.allocPrint(arena, "{d}", .{@intFromEnum(s)}),
    };
}

/// The `failure` record's encoding. A record is one tab-separated LINE, and
/// the failure message Pkg composes spans lines ("Packages errored during
/// testing:\n• Foo") — so the three characters that would break the framing
/// are escaped, C-style: `\` → `\\`, tab → `\t`, newline → `\n`. The Julia
/// wrapper's `_unescape_record` is the inverse; the pair exists so the wrapper
/// can re-raise the message VERBATIM as a `PkgError`, whatever shape it took.
pub fn escapeMessage(arena: Allocator, msg: []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (msg) |c| switch (c) {
        '\\' => try buf.appendSlice(arena, "\\\\"),
        '\t' => try buf.appendSlice(arena, "\\t"),
        '\n' => try buf.appendSlice(arena, "\\n"),
        else => try buf.append(arena, c),
    };
    return buf.items;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// `<depots1>/environments/v<major>.<minor>` — what `@v#.#` expands to
/// (`base/initdefs.jl:300-310`), for the preferences merge only.
fn sharedEnvDir(
    arena: Allocator,
    depot: ?depot_mod.Depot,
    version: ?[]const u8,
) Allocator.Error![]const []const u8 {
    const d = depot orelse return &.{};
    const v = version orelse return &.{};
    var it = std.mem.splitScalar(u8, v, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return &.{}, 10) catch return &.{};
    const minor = std.fmt.parseInt(u32, it.next() orelse return &.{}, 10) catch return &.{};
    const name = try depot_mod.defaultEnvironmentName(arena, major, minor);
    const out = try arena.alloc([]const u8, 1);
    out[0] = try d.environmentDir(arena, name);
    return out;
}

/// `map(abspath, DEPOT_PATH)` (`base/loading.jl:2982`) — lexical, never
/// `realpath`. An entry that cannot be absolutised is passed through unchanged:
/// a relative depot is still better than no depot.
fn absDepots(arena: Allocator, io: Io, stack: depot_mod.Stack) Allocator.Error![]const []const u8 {
    var out = try arena.alloc([]const u8, stack.entries.len);
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd: ?[]const u8 = blk: {
        const n = std.process.currentPath(io, &cwd_buf) catch break :blk null;
        break :blk cwd_buf[0..n];
    };
    for (stack.entries, 0..) |e, i| {
        out[i] = if (fspath.isAbsolute(e))
            try fspath.resolve(arena, &.{e})
        else if (cwd) |c|
            try fspath.resolve(arena, &.{ c, e })
        else
            e;
    }
    return out;
}

fn joinDepots(arena: Allocator, stack: depot_mod.Stack) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (stack.entries, 0..) |e, i| {
        if (i != 0) try buf.append(arena, fspath.delimiter);
        try buf.appendSlice(arena, e);
    }
    return buf.items;
}

/// `<julia_prefix>/bin/julia` when the prefix names one, else the bare name,
/// which `std.process.spawn` resolves through the PARENT's `PATH`.
fn juliaExe(arena: Allocator, io: Io, opts: Options) Allocator.Error![]const u8 {
    if (opts.julia_exe) |e| return e;
    const p = opts.julia_prefix orelse return "julia";
    const exe = try fspath.join(arena, &.{ p, "bin", "julia" });
    Io.Dir.cwd().access(io, exe, .{}) catch return "julia";
    return exe;
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseUuid(text: []const u8) Uuid {
    return Uuid.parse(text) catch unreachable;
}

test "gen_test_code: depot, blank line, cd, ARGS, include" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = try genTestCode(arena, .{ .entries = &.{ "/a", "/b" } }, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
        .test_args = &.{ "x", "y z" },
    }, "/pkgs/Foo/test/runtests.jl");
    // The blank line after DL_LOAD_PATH is `load_path_setup_code`'s trailing
    // newline meeting the template's own. Verified against
    // `Pkg.Operations.gen_test_code` directly.
    try testing.expectEqualStrings(
        \\append!(empty!(Base.DEPOT_PATH), ["/a", "/b"])
        \\append!(empty!(Base.DL_LOAD_PATH), String[])
        \\
        \\cd("/pkgs/Foo/test")
        \\append!(empty!(ARGS), ["x", "y z"])
        \\include("/pkgs/Foo/test/runtests.jl")
        \\
    , code);
}

test "gen_test_code with no test_args writes String[], not []" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = try genTestCode(arena, .{ .entries = &.{} }, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
    }, "/pkgs/Foo/test/runtests.jl");
    try testing.expect(std.mem.indexOf(u8, code, "append!(empty!(ARGS), String[])") != null);
    // A `$` in a path is interpolation, so an unescaped one turns a test run
    // into an evaluation of whatever follows it.
    const evil = try genTestCode(arena, .{ .entries = &.{} }, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
    }, "/we\"ird/$x/test/runtests.jl");
    try testing.expect(std.mem.indexOf(u8, evil, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, evil, "\\$") != null);
}

test "subprocess flags: Pkg's order, coverage shapes, julia_args last" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    try appendSubprocessFlags(arena, &argv, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
        .coverage = .on,
        .julia_args = &.{"--check-bounds=no"},
    }, "/pkgs/Foo");
    try testing.expectEqualStrings("--code-coverage=@/pkgs/Foo", argv.items[0]);
    try testing.expectEqualStrings("--color=auto", argv.items[1]);
    try testing.expectEqualStrings("--check-bounds=yes", argv.items[2]);
    try testing.expectEqualStrings("--warn-overwrite=yes", argv.items[3]);
    try testing.expectEqualStrings("--depwarn=yes", argv.items[4]);
    try testing.expectEqualStrings("--inline=yes", argv.items[5]);
    try testing.expectEqualStrings("--startup-file=no", argv.items[6]);
    try testing.expectEqualStrings("--track-allocation=none", argv.items[7]);
    // LAST, so that the caller's `--check-bounds=no` is the one Julia honours.
    try testing.expectEqualStrings("--check-bounds=no", argv.items[8]);

    var off: std.ArrayList([]const u8) = .empty;
    try appendSubprocessFlags(arena, &off, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
    }, "/pkgs/Foo");
    try testing.expectEqualStrings("--code-coverage=none", off.items[0]);

    var str: std.ArrayList([]const u8) = .empty;
    try appendSubprocessFlags(arena, &str, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
        .coverage = .{ .arg = "user" },
    }, "/pkgs/Foo");
    try testing.expectEqualStrings("--code-coverage=user", str.items[0]);
}

test "resolveSpec reaches the whole manifest, not just the direct deps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = parseUuid("00000000-0000-0000-0000-000000000099");
    const direct = parseUuid("00000000-0000-0000-0000-0000000000d1");
    const trans = parseUuid("00000000-0000-0000-0000-0000000000d2");
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "Direct", .uuid = direct, .deps = &.{.{ .name = "Trans", .uuid = trans }} },
        .{ .name = "Trans", .uuid = trans },
    };
    const manifest: manifest_mod.Manifest = .{ .entries = &entries };

    var proj = try project_mod.empty(testing.allocator);
    defer proj.deinit();
    proj.name = "Root";
    proj.uuid = root;
    try proj.addDep("Direct", direct);

    // The project's own package, by name and by uuid.
    try testing.expectEqual(root, (try resolveSpec(arena, "Root", &proj, &manifest)).?.uuid);
    try testing.expectEqual(root, (try resolveSpec(arena, "00000000-0000-0000-0000-000000000099", &proj, &manifest)).?.uuid);
    // A direct dependency.
    try testing.expectEqual(direct, (try resolveSpec(arena, "Direct", &proj, &manifest)).?.uuid);
    // And the one `pin` would refuse: a manifest entry nothing depends on
    // directly. `Pkg.test` takes it, `Pkg.pin` does not.
    try testing.expectEqual(trans, (try resolveSpec(arena, "Trans", &proj, &manifest)).?.uuid);
    try testing.expect((try resolveSpec(arena, "Nope", &proj, &manifest)) == null);
}

test "resolveSpec refuses a name two manifest entries share" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = parseUuid("00000000-0000-0000-0000-0000000000aa");
    const b = parseUuid("00000000-0000-0000-0000-0000000000bb");
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "Dup", .uuid = a },
        .{ .name = "Dup", .uuid = b },
    };
    const manifest: manifest_mod.Manifest = .{ .entries = &entries };
    var proj = try project_mod.empty(testing.allocator);
    defer proj.deinit();

    // `length(uuids[pkg.name]) == 1` (`Types.jl:1167`) — two candidates leave
    // it unresolved rather than picking the first.
    try testing.expect((try resolveSpec(arena, "Dup", &proj, &manifest)) == null);
}

test "the failure messages Pkg raises" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "Package Foo did not provide a `test/runtests.jl` file",
        try missingRuntestsMessage(arena, &.{"Foo"}),
    );
    try testing.expectEqualStrings(
        "Packages Foo, Bar did not provide a `test/runtests.jl` file",
        try missingRuntestsMessage(arena, &.{ "Foo", "Bar" }),
    );
    try testing.expectEqualStrings(
        "The following package names could not be resolved:\n * Nope (not found in project or manifest)",
        try unresolvedMessage(arena, &.{"Nope"}),
    );

    // Exit code 1 is the ordinary "the suite threw" case and gets NO reason.
    const plain: Run = .{ .name = "Foo", .uuid = parseUuid("00000000-0000-0000-0000-0000000000aa"), .source_path = "", .test_file = "", .exit_code = 1 };
    try testing.expectEqualStrings(
        "Package Foo errored during testing",
        try erroredMessage(arena, &.{&plain}),
    );
    const odd: Run = .{ .name = "Bar", .uuid = parseUuid("00000000-0000-0000-0000-0000000000bb"), .source_path = "", .test_file = "", .exit_code = 42 };
    try testing.expectEqualStrings(
        "Package Bar errored during testing (exit code: 42)",
        try erroredMessage(arena, &.{&odd}),
    );
    const killed: Run = .{ .name = "Baz", .uuid = parseUuid("00000000-0000-0000-0000-0000000000cc"), .source_path = "", .test_file = "", .signal = .KILL };
    try testing.expectEqualStrings(
        "Package Baz errored during testing (received signal: KILL)",
        try erroredMessage(arena, &.{&killed}),
    );
    try testing.expectEqualStrings(
        "Packages errored during testing:\n• Foo\n• Baz (received signal: KILL)",
        try erroredMessage(arena, &.{ &plain, &killed }),
    );
    // A signal Pkg does not name comes out as the number, on both sides.
    const segv: Run = .{ .name = "Q", .uuid = parseUuid("00000000-0000-0000-0000-0000000000dd"), .source_path = "", .test_file = "", .signal = .SEGV };
    try testing.expectEqualStrings(
        "Package Q errored during testing (received signal: 11)",
        try erroredMessage(arena, &.{&segv}),
    );
}

test "escapeMessage keeps a multi-line failure inside one record" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "Packages errored during testing:\\n\xe2\x80\xa2 Foo\\n\xe2\x80\xa2 Bar (exit code: 42)",
        try escapeMessage(arena, "Packages errored during testing:\n• Foo\n• Bar (exit code: 42)"),
    );
    // A literal backslash round-trips: escaping it is what keeps `\n` in a
    // path distinguishable from an escaped newline on the way back.
    try testing.expectEqualStrings("C:\\\\new\\tab", try escapeMessage(arena, "C:\\new\tab"));
}
