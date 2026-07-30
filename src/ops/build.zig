//! `ajt build` — run each package's `deps/build.jl`, in dependency order,
//! inside a sandbox.
//!
//! ## Why this exists
//!
//! A `deps/build.jl` writes `deps/deps.jl`, and the package's `__init__` reads
//! it. Skip the build and the package installs perfectly and then fails to
//! load — `ERROR: LoadError: ... please run Pkg.build("Foo")`. Until this
//! module existed, `grep -rn build.jl src/` in this repository found one
//! comment, and every such package was silently broken after an Ajt-only
//! install. Ports `Operations.build`, `build_versions`, `gen_build_code` and
//! `dependency_order_uuids` (`Operations.jl:1333-1513`).
//!
//! ## This runs arbitrary user code as the invoking user
//!
//! `build.jl` is not sandboxed in any security sense — Pkg's `sandbox` is an
//! *environment* sandbox, not a privilege one, and the script can do anything
//! this process can. The two things that must therefore be exactly right are
//! `JULIA_DEPOT_PATH` (a wrong one makes the script populate a depot nobody
//! asked about) and `JULIA_LOAD_PATH` (a wrong one lets it import packages the
//! environment does not contain). Both are BUILT rather than inherited, through
//! `child.environ`; nothing here passes the caller's environment through
//! unchanged.
//!
//! ## The three things easiest to get wrong
//!
//! **1. Order.** `dependency_order_uuids` (`:1341-1363`) is a post-order DFS
//! over `entry.deps`, so a package is built after everything it depends on.
//! A cycle is a `@warn("Dependency graph not a DAG, linearizing anyway")` and
//! the walk continues — NOT an error, and not a skip. `sched.graph` refuses to
//! schedule a cyclic manifest; this deliberately does not use it, because
//! refusing would be a behaviour Pkg does not have.
//!
//! **2. Where `build.log` goes**, which is not one place (`:1454-1473`):
//!
//!   * a manifest entry with a **tree hash** — i.e. a registered, content-
//!     addressed package, whose source directory is read-only — gets
//!     `<depots1>/scratchspaces/44cfe95a-…/<tree-hash>/build.log`, plus an
//!     APPEND to `<depots1>/logs/scratch_usage.toml` naming the package's own
//!     project file. That uuid is Pkg's own
//!     (`const PkgUUID = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"`, `:1393`) —
//!     the scratchspace belongs to Pkg, not to the package being built.
//!   * a **path-tracked** entry (a `dev`ed package, or the project itself)
//!     gets `<source>/deps/build.log` — `splitext(build_file)[1] * ".log"` —
//!     and **no usage entry at all**. Writing one would name a scratchspace
//!     that does not exist, and `Pkg.gc()` would carry the dead key forever.
//!
//! **3. The first failure aborts the whole run** (`:1497-1509`). Pkg reads the
//! log back, keeps the last 100 lines when the session is interactive and 5000
//! otherwise, and raises. There is no per-package continue and no summary of
//! several failures — the second package's build may well depend on the first
//! one's output, so continuing would produce a cascade of unrelated errors on
//! top of the real one. `ajt test` does the opposite (it runs every named
//! package and reports); do not conflate them.
//!
//! ## What is deliberately not here
//!
//! `Operations.build` begins with `if any_package_not_installed(manifest) ||
//! !isfile(manifest_file); Pkg.instantiate(ctx, allow_build = false, ...)`
//! (`:1334-1336`). This module does not instantiate: `ajt build` reports
//! `not_installed` and stops, because an implicit download inside a verb the
//! user typed as "build" is the kind of surprise Ajt's other verbs already
//! refuse (`instantiate --frozen`, `resolve` not installing). `ajt instantiate`
//! is one command away and says what it is doing.
//!
//! Parallelism is also absent, and that is Pkg's shape too: `build_versions`
//! is a plain `for` loop. Two builds in one depot can write the same
//! scratchspace and the same artifact; serialising is the cheap correct
//! answer for an operation that is rare and already dominated by the child's
//! startup.
//!
//! ## Allocation
//!
//! `arena` holds the Report and everything it borrows. `gpa` backs the
//! transient side — each child's captured output, each rendered TOML, the
//! child environment map — and all of it is freed before `run` returns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const verify = @import("verify.zig");
const usage = @import("usage.zig");
const sandbox = @import("sandbox.zig");
const child = @import("child.zig");

pub const Uuid = manifest_mod.Uuid;
const PackageEntry = manifest_mod.PackageEntry;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;
/// A `build.jl` can print without limit — a `Downloading` progress bar, a
/// compiler's whole output. The cap stops a wedged child from growing this
/// process without bound; it is not a prediction about any package.
const max_log_bytes = 64 * 1024 * 1024;

/// `const PkgUUID = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"` (`Operations.jl:1393`).
/// `pkg_scratchpath() = joinpath(depots1(), "scratchspaces", PkgUUID)`.
///
/// Pkg's OWN uuid, not the built package's. `Pkg.gc()` sweeps
/// `scratchspaces/<uuid>/<key>` and keeps a key alive through
/// `scratch_usage.toml`; putting the log under the package's uuid instead
/// would put it somewhere `build_versions` never looks and Pkg would rebuild
/// every time.
pub const pkg_uuid_text = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f";

pub const Error = error{
    /// No project file, or it would not parse.
    NoProject,
    /// A manifest entry names a package with no source on disk. Pkg would
    /// `Pkg.instantiate` here; see the module header for why this stops.
    NotInstalled,
} || sandbox.Error || Allocator.Error || Io.Cancelable;

// A failing `build.jl` is NOT in that set. It is reported through
// `Report.failure`, because the message is the product — it carries the tail of
// the log, which is the only actionable thing a failed build produces — and an
// error code would throw it away. `run` still returns a `Report` whose `ok()`
// is false, and the CLI exits non-zero on it.

pub const Options = struct {
    /// The environment: a directory, or a project file directly. Probed
    /// exactly as `Types.projectfile_path` probes it — by `verify`, which is
    /// the only place that probe lives.
    env_path: []const u8,
    manifest_file: ?[]const u8 = null,
    /// The resolved `DEPOT_PATH`. Entry 0 is `depots1()`: where a scratchspace
    /// and its usage log land.
    stack: depot_mod.Stack,

    /// Names (or UUIDs) to build. Empty means Pkg's default: the project's own
    /// package if it has one, otherwise every manifest entry (`API.jl:1206-1214`).
    packages: []const []const u8 = &.{},

    julia_exe: ?[]const u8 = null,
    julia_prefix: ?[]const u8 = null,
    julia_version: ?[]const u8 = null,

    /// The parent environment the children inherit, minus the variables the
    /// sandbox pins. Null hands a child almost nothing — no `PATH`, no `HOME`
    /// — which no real build survives, so supply it.
    environ: ?*const std.process.Environ.Map = null,

    /// `verbose` (`API.jl:1203`). Pkg sends the child's output to `ctx.io` as
    /// well as the log; here it means "also copy the log to stderr", since
    /// stdout carries the machine-readable report.
    verbose: bool = false,

    /// `Base.JLOptions().startupfile == 1 ? "yes" : "no"` (`Operations.jl:1374-1375`)
    /// — "running Pkg.build runs the build in a session with --startup=no
    /// *unless* the parent julia session is started with --startup-file=yes
    /// explicitly". Ajt is not a Julia and has no `JLOptions`, so the caller
    /// states it; the `Ajt.jl` wrapper passes the running session's flag and
    /// the bare CLI defaults to `no`, which is Pkg's answer for every
    /// non-interactive session.
    startup_file: bool = false,

    /// `isinteractive()` (`Operations.jl:1498`), which chooses 100 log lines
    /// in the failure message instead of 5000. Same reasoning as
    /// `startup_file`: only a caller inside a REPL knows.
    interactive: bool = false,

    /// Registry access for the sandbox resolve. Null skips it and uses the
    /// parent dep graph verbatim — see `sandbox`'s header for exactly what
    /// that does and does not catch.
    registry_depot: ?[]const u8 = null,
    registry_name: []const u8 = "General",
    stdlib_dir: ?[]const u8 = null,

    /// Plan and report; run no `build.jl`. The sandbox is not created either —
    /// under `--dry-run` there is nothing for it to hold.
    dry_run: bool = false,
};

/// One package with a `deps/build.jl`.
pub const Build = struct {
    name: []const u8,
    uuid: Uuid,
    /// The package root — `source_path`, not `deps/`.
    source_path: []const u8,
    /// `deps/build.jl`.
    build_file: []const u8,
    /// Where the output went. See the module header: two different places.
    log_file: []const u8,
    /// `entry.tree_hash`, which is what `:1457` tests to choose between the
    /// two log destinations. Null for a path-tracked entry and for the
    /// project's own package.
    tree_hash: ?manifest_mod.Sha1 = null,
    /// True when `log_file` is in a scratchspace, i.e. when a
    /// `scratch_usage.toml` entry was appended for it.
    scratch: bool = false,
    /// Wall time of the child, milliseconds. Zero under `--dry-run`.
    ms: f64 = 0,
    ok: bool = false,
    /// Set when the child ran and exited normally.
    exit_code: ?u8 = null,
    /// The sandbox fell through to a full re-resolve; the versions this build
    /// saw are NOT the environment's.
    reresolved: bool = false,
};

pub const Report = struct {
    project_file: []const u8 = "",
    manifest_file: []const u8 = "",
    julia: []const u8 = "",
    depot_path: []const u8 = "",
    /// In the order they were (or would be) run.
    builds: []const Build = &.{},
    /// How many packages were in the closure at all, before the
    /// `deps/build.jl` filter. `builds.len` is how many had one.
    considered: usize = 0,
    /// The message of the first failure, already carrying the log tail Pkg
    /// would print. Null on success.
    failure: ?[]const u8 = null,

    pub fn ok(self: Report) bool {
        return self.failure == null;
    }
};

/// `Pkg.build` end to end.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, opts: Options) Error!Report {
    var rep: Report = .{};

    // Locate the environment exactly as every other op does, through `verify`.
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
    // `map(abspath, DEPOT_PATH)` (`base/loading.jl:2982`), and not an
    // afterthought: `gen_build_code`'s very next statement is
    // `cd(dirname(build_file))`, so a relative depot entry would be re-anchored
    // to the package's `deps/` directory the moment the script touched it.
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

    // --- the uuid set (`API.jl:1206-1216`, then `get_deps`) ----------------
    var roots: std.ArrayList(Uuid) = .empty;
    if (opts.packages.len == 0) {
        if (proj.uuid) |u| {
            try roots.append(arena, u);
        } else {
            for (manifest.entries) |e| try roots.append(arena, e.uuid);
        }
    } else {
        for (opts.packages) |spec| {
            try roots.append(arena, try resolveSpec(spec, &proj, &manifest));
        }
    }
    const closure = try getDeps(arena, roots.items, &proj, &manifest, sl.uuids);
    rep.considered = closure.len;

    // --- which of them have a deps/build.jl (`Operations.jl:1400-1422`) ----
    var builds: std.ArrayList(Build) = .empty;
    for (closure) |u| {
        // Null is "no source path": a stdlib whose directory this run could not
        // locate, or a uuid the manifest does not list. Pkg reaches neither —
        // `is_stdlib` always answers for it, and it filters a second time at
        // `:1402` — so the honest equivalent is to SKIP, not to fail. Failing
        // would make `ajt build` unusable whenever `--julia-prefix` is missing,
        // because essentially every manifest lists stdlibs.
        const info = try packageInfo(arena, io, u, &proj, &manifest, rep.project_file, rep.manifest_file, opts, sl.dir) orelse
            continue;
        // `ispath(path) || error("Build path for $name does not exist")`
        // (`:1419`) — a manifest entry whose package is not unpacked. THIS is
        // the one that stops the run.
        if (!isDir(io, info.source_path)) return error.NotInstalled;
        const build_file = try fspath.join(arena, &.{ info.source_path, "deps", "build.jl" });
        if (!isFile(io, build_file)) continue;
        try builds.append(arena, .{
            .name = info.name,
            .uuid = u,
            .source_path = info.source_path,
            .build_file = build_file,
            .log_file = "",
            .tree_hash = info.tree_hash,
        });
    }

    // --- toposort (`:1423-1424`) -------------------------------------------
    try sortByDependencyOrder(arena, builds.items, &proj, &manifest);

    // --- run ---------------------------------------------------------------
    for (builds.items, 0..) |*b, i| {
        b.log_file = try logFile(arena, depot, b.*);
        b.scratch = b.tree_hash != null and depot != null;
        if (opts.dry_run) continue;
        try one(gpa, arena, io, opts, &rep, stack, depot, sl.dir, b);
        if (!b.ok) {
            // Only what RAN. The remaining entries were planned and abandoned,
            // and reporting them would print `failed` for packages no child was
            // ever started for — Pkg says nothing about them at all.
            rep.builds = builds.items[0 .. i + 1];
            return rep;
        }
    }
    rep.builds = builds.items;
    return rep;
}

/// One package: sandbox, run, log, and on failure compose Pkg's message.
fn one(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    rep: *Report,
    /// The ABSOLUTISED depot stack — `map(abspath, DEPOT_PATH)`, not
    /// `opts.stack`. The child `cd`s before it touches a depot.
    stack: depot_mod.Stack,
    depot: ?depot_mod.Depot,
    stdlib_dir: ?[]const u8,
    b: *Build,
) Error!void {
    const builddir = try fspath.join(arena, &.{ b.source_path, "deps" });

    // The scratch_usage entry is appended BEFORE the build runs, exactly as
    // `:1457-1470` does — the directory is created and claimed first, so a
    // build that crashes still leaves a log a human can read and a `Pkg.gc()`
    // that will not delete it out from under them.
    if (b.scratch) {
        const d = depot.?;
        const dir = fspath.dirname(b.log_file).?;
        Io.Dir.cwd().createDirPath(io, dir) catch {};
        // `projectfile_path(source_path)` — NON-strict (`:1465`), so it is the
        // would-be `Project.toml` even for a package that has none. Matching
        // matters: `gc` compares this key against files on disk, and a
        // different spelling is a root it can never find.
        const parent_project = try projectFileNonStrict(arena, io, b.source_path);
        _ = usage.appendScratch(gpa, io, d.root, &.{.{
            .dir = dir,
            .parent_projects = &.{parent_project},
        }}, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // `appendScratch` already swallows every write failure itself and
            // says so on stderr — a read-only depot must not turn a successful
            // build into a failed command. The two remaining members of its
            // error set (`ScratchLogUnsupported`, `NoCurrentDir`) belong to
            // `record`'s code path and are unreachable from here.
            else => usage.Recorded{},
        };
    }

    var env = try sandbox.create(gpa, arena, io, .{
        .project_file = rep.project_file,
        .manifest_file = rep.manifest_file,
        .target_name = b.name,
        .target_uuid = b.uuid,
        .source_path = b.source_path,
        .sandbox_path = builddir,
        .target = "build",
        // `Base.LOAD_PATH`'s `@v#.#` (`Operations.jl:1444`, `:1449`). The
        // sandbox already gets the environment under build as its `@`; this is
        // the shared default environment, which is the only other entry on a
        // stock load path that can carry a `LocalPreferences.toml`. Empty when
        // the Julia version is unknown, which costs only those preferences.
        .extra_pref_envs = try sharedEnvDir(arena, depot, opts.julia_version),
        .resolve = if (opts.registry_depot) |rd| .{
            .registry_depot = rd,
            .registry_name = opts.registry_name,
            .depots = opts.stack,
            .julia_prefix = opts.julia_prefix,
            .stdlib_dir = stdlib_dir,
        } else null,
    });
    defer env.destroy(io);
    b.reresolved = env.reresolved;

    // `withenv(fn, "JULIA_LOAD_PATH" => "@:$(tmp)", "JULIA_PROJECT" => nothing)`
    // (`Operations.jl:2310-2311`), plus the depot the whole run is pinned to.
    var environ = try child.environ(gpa, opts.environ, &.{
        .{ .name = "JULIA_DEPOT_PATH", .value = rep.depot_path },
        .{ .name = "JULIA_LOAD_PATH", .value = env.load_path },
        .{ .name = "JULIA_PROJECT", .value = null },
    });
    defer environ.deinit();

    const code = try genBuildCode(arena, stack, opts, b.build_file);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        rep.julia,
        // `-O0` (`:1375`): a build script is run once and its compile time is
        // pure overhead.
        "-O0",
        "--color=no",
        "--history-file=no",
        try std.fmt.allocPrint(arena, "--startup-file={s}", .{if (opts.startup_file) "yes" else "no"}),
        "--eval",
        code,
    });

    var out = child.run(gpa, io, .{
        .argv = argv.items,
        .environ = &environ,
        .stdout_limit = max_log_bytes,
        .stderr_limit = max_log_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            b.ok = false;
            rep.failure = try std.fmt.allocPrint(arena, "Error building `{s}`: could not start {s} ({s})", .{
                b.name, rep.julia, @errorName(err),
            });
            return;
        },
    };
    defer out.deinit(gpa);
    b.ms = out.ms;
    b.exit_code = out.exitCode();

    // `pipeline(cmd, stdout = log, stderr = log)` (`:1488-1495`) — ONE
    // destination for both streams. `std.process.run` reads them into two
    // buffers, so the true interleaving is lost and they are concatenated
    // stdout-then-stderr. For a script that writes to one stream, which is
    // almost all of them, the bytes are identical to Pkg's.
    try writeLog(gpa, io, b.log_file, out.stdout, out.stderr);
    if (opts.verbose) {
        std.debug.print("{s}{s}", .{ out.stdout, out.stderr });
    }

    if (out.succeeded()) {
        b.ok = true;
        return;
    }

    // `:1497-1509`. Read the log BACK rather than reusing the buffer: the log
    // is what the message points at, and if the two ever disagree the file is
    // the one the user will look at.
    const n_lines: usize = if (opts.interactive) 100 else 5000;
    const log = Io.Dir.cwd().readFileAlloc(io, b.log_file, arena, .limited(max_log_bytes)) catch "";
    const total = child.countLines(log);
    const shown = child.tailLines(log, n_lines);
    const truncated = total > n_lines;
    rep.failure = try std.fmt.allocPrint(
        arena,
        "Error building `{s}`{s}: \n{s}{s}",
        .{
            b.name,
            if (truncated)
                try std.fmt.allocPrint(arena, ", showing the last {d} of log", .{n_lines})
            else
                "",
            shown,
            if (truncated)
                try std.fmt.allocPrint(arena, "\n\nFull log at {s}", .{b.log_file})
            else
                "",
        },
    );
}

// ---------------------------------------------------------------------------
// gen_build_code
// ---------------------------------------------------------------------------

/// `gen_build_code(build_file)` (`Operations.jl:1365-1380`).
///
/// ```julia
/// $(Base.load_path_setup_code(false))
/// cd($(repr(dirname(build_file))))
/// include($(repr(build_file)))
/// ```
///
/// `load_path_setup_code(false)` emits ONLY the two `DEPOT_PATH`/`DL_LOAD_PATH`
/// lines (`base/loading.jl:2980-2998`); the `load_path = false` argument is
/// what suppresses the `LOAD_PATH` block, because the sandbox has already put
/// the right value in `JULIA_LOAD_PATH` and re-emitting the PARENT's would
/// undo it. Getting that backwards is the whole bug.
///
/// `DL_LOAD_PATH` is emitted as empty. It is a Julia global that only a
/// `push!` at runtime populates, and Ajt has no parent Julia session to read
/// one from; the default is `String[]` and that is what a child would get with
/// no line at all.
///
/// `repr` is Julia string-literal syntax. `\` and `"` are the only characters
/// a path can contain that matter here, and both are escaped — a Windows path
/// or a directory with a quote in it would otherwise produce code that does
/// not parse, or worse, parses as something else.
fn genBuildCode(
    arena: Allocator,
    /// Already absolutised — `map(abspath, DEPOT_PATH)`. Passing `opts.stack`
    /// here would emit relative entries that the `cd` two lines below
    /// re-anchors to the package's `deps/` directory.
    stack: depot_mod.Stack,
    opts: Options,
    build_file: []const u8,
) Allocator.Error![]const u8 {
    _ = opts;
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(arena, "append!(empty!(Base.DEPOT_PATH), [");
    for (stack.entries, 0..) |d, i| {
        if (i != 0) try buf.appendSlice(arena, ", ");
        try appendJuliaString(arena, &buf, d);
    }
    try buf.appendSlice(arena, "])\n");
    try buf.appendSlice(arena, "append!(empty!(Base.DL_LOAD_PATH), String[])\n");

    try buf.appendSlice(arena, "cd(");
    try appendJuliaString(arena, &buf, fspath.dirname(build_file) orelse ".");
    try buf.appendSlice(arena, ")\ninclude(");
    try appendJuliaString(arena, &buf, build_file);
    try buf.appendSlice(arena, ")\n");
    return buf.items;
}

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
// Ordering
// ---------------------------------------------------------------------------

/// `dependency_order_uuids` (`Operations.jl:1341-1363`) applied as a sort.
///
/// A post-order DFS: `order[uuid] = k += 1` fires only after every dependency
/// has been visited, so the resulting integers sort dependencies first. A uuid
/// already on the `seen` stack is a cycle — Pkg `@warn`s and RETURNS from the
/// visit, which leaves that node unnumbered on this path and lets the outer
/// walk number it later. The graph is linearised, never rejected.
///
/// Stable: `builds` is already in the closure's order, and equal keys keep it.
fn sortByDependencyOrder(
    arena: Allocator,
    builds: []Build,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
) Allocator.Error!void {
    var order: std.AutoHashMapUnmanaged([16]u8, usize) = .empty;
    var seen: std.ArrayList([16]u8) = .empty;
    var k: usize = 0;
    var warned = false;

    for (builds) |b| {
        try visit(arena, b.uuid, proj, manifest, &order, &seen, &k, &warned);
    }

    // Anything the walk never numbered (a cycle victim) sorts last, which is
    // the same place Julia's `Dict` lookup would put it — `order[first(build)]`
    // on a missing key is a `KeyError` in Pkg, reachable only when `visit`
    // returned early from the cycle branch for a ROOT. Sorting rather than
    // raising is the one place this is kinder than Pkg, and it is kinder in
    // the direction of still building the package.
    const Ctx = struct {
        order: *std.AutoHashMapUnmanaged([16]u8, usize),
        fn lessThan(self: @This(), a: Build, b: Build) bool {
            const x = self.order.get(a.uuid.bytes) orelse std.math.maxInt(usize);
            const y = self.order.get(b.uuid.bytes) orelse std.math.maxInt(usize);
            return x < y;
        }
    };
    std.sort.insertion(Build, builds, Ctx{ .order = &order }, Ctx.lessThan);
}

fn visit(
    arena: Allocator,
    uuid: Uuid,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
    order: *std.AutoHashMapUnmanaged([16]u8, usize),
    seen: *std.ArrayList([16]u8),
    k: *usize,
    warned: *bool,
) Allocator.Error!void {
    for (seen.items) |s| {
        if (std.mem.eql(u8, &s, &uuid.bytes)) {
            if (!warned.*) {
                warned.* = true;
                std.debug.print("ajt build: dependency graph not a DAG, linearizing anyway\n", .{});
            }
            return;
        }
    }
    if (order.contains(uuid.bytes)) return;
    try seen.append(arena, uuid.bytes);

    const is_root = if (proj.uuid) |u| std.mem.eql(u8, &u.bytes, &uuid.bytes) else false;
    if (is_root) {
        for (proj.deps.entries.items) |d| try visit(arena, d.uuid, proj, manifest, order, seen, k, warned);
    } else if (manifest.findByUuid(uuid)) |e| {
        for (e.deps) |d| try visit(arena, d.uuid, proj, manifest, order, seen, k, warned);
    }

    _ = seen.pop();
    k.* += 1;
    try order.put(arena, uuid.bytes, k.*);
}

// ---------------------------------------------------------------------------
// The closure, and what each uuid is
// ---------------------------------------------------------------------------

/// `get_deps(env, uuids)` (`Operations.jl:1302-1320`): the transitive closure
/// over `entry.deps`, with stdlibs dropped on the way in — `is_stdlib(uuid) &&
/// continue` (`:1305`), so a stdlib is not collected AND its own deps are not
/// walked.
fn getDeps(
    arena: Allocator,
    roots: []const Uuid,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
    stdlibs: std.AutoHashMapUnmanaged([16]u8, void),
) Allocator.Error![]const Uuid {
    var out: std.ArrayList(Uuid) = .empty;
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    var stack: std.ArrayList(Uuid) = .empty;
    try stack.appendSlice(arena, roots);

    while (stack.pop()) |u| {
        if (stdlibs.contains(u.bytes)) continue;
        const gop = try seen.getOrPut(arena, u.bytes);
        if (gop.found_existing) continue;
        try out.append(arena, u);

        const is_root = if (proj.uuid) |r| std.mem.eql(u8, &r.bytes, &u.bytes) else false;
        if (is_root) {
            for (proj.deps.entries.items) |d| try stack.append(arena, d.uuid);
        } else if (manifest.findByUuid(u)) |e| {
            for (e.deps) |d| try stack.append(arena, d.uuid);
        }
    }
    return out.items;
}

const Info = struct {
    name: []const u8,
    source_path: []const u8,
    tree_hash: ?manifest_mod.Sha1 = null,
};

/// `build_versions`' per-uuid lookup (`Operations.jl:1401-1420`): the project
/// itself, or a manifest entry resolved through `source_path`.
fn packageInfo(
    arena: Allocator,
    io: Io,
    uuid: Uuid,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
    project_file: []const u8,
    manifest_file: []const u8,
    opts: Options,
    stdlib_dir: ?[]const u8,
) Error!?Info {
    if (proj.uuid) |u| {
        if (std.mem.eql(u8, &u.bytes, &uuid.bytes)) return .{
            .name = proj.name orelse "",
            .source_path = fspath.dirname(project_file) orelse ".",
            // The project itself is never content-addressed, so its log always
            // goes to `deps/build.log` (`:1457` tests `entry !== nothing &&
            // entry.tree_hash !== nothing`, and `manifest_info` for the project
            // uuid is normally `nothing`).
            .tree_hash = null,
        };
    }
    const e = manifest.findByUuid(uuid) orelse return null;
    // `source_path(manifest_file, entry)` (`Operations.jl:48-53`): tree hash
    // first, then a manifest `path`, then the stdlib directory.
    if (e.tree_hash) |h| {
        const found = depot_mod.findInstalled(arena, io, opts.stack, e.name, e.uuid, h) catch
            return null;
        return .{ .name = e.name, .source_path = found.path, .tree_hash = h };
    }
    if (e.path) |p| {
        const dir = fspath.dirname(manifest_file) orelse ".";
        return .{
            .name = e.name,
            .source_path = try fspath.resolve(arena, &.{ dir, p }),
        };
    }
    const sd = stdlib_dir orelse return null;
    return .{
        .name = e.name,
        .source_path = try fspath.join(arena, &.{ sd, e.name }),
    };
}

fn resolveSpec(
    spec: []const u8,
    proj: *const project_mod.Project,
    manifest: *const manifest_mod.Manifest,
) Error!Uuid {
    if (Uuid.parse(spec)) |u| return u else |_| {}
    if (proj.name) |n| {
        if (std.mem.eql(u8, n, spec)) {
            if (proj.uuid) |u| return u;
        }
    }
    if (proj.deps.get(spec)) |u| return u;
    if (manifest.findByName(spec)) |e| return e.uuid;
    return error.NotInstalled;
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

/// `Operations.jl:1454-1473`. See the module header: two destinations, and only
/// one of them gets a `scratch_usage.toml` entry.
fn logFile(arena: Allocator, depot: ?depot_mod.Depot, b: Build) Allocator.Error![]const u8 {
    if (b.tree_hash) |th| {
        if (depot) |d| {
            const uuid = Uuid.parse(pkg_uuid_text) catch unreachable;
            var hex: [40]u8 = undefined;
            // `key = string(entry.tree_hash)` (`:1458`) — the 40-character
            // lowercase hex, which is what `Base.SHA1`'s `show` produces and
            // therefore the directory name Pkg would look in.
            const key = manifest_mod.formatSha1(th, &hex);
            const dir = try d.scratchspaceKeyDir(arena, uuid, key);
            return fspath.join(arena, &.{ dir, "build.log" });
        }
    }
    // `splitext(build_file)[1] * ".log"` — `<source>/deps/build.log`.
    return fspath.join(arena, &.{ b.source_path, "deps", "build.log" });
}

fn writeLog(gpa: Allocator, io: Io, path: []const u8, out: []const u8, err: []const u8) !void {
    const bytes = try std.mem.concat(gpa, u8, &.{ out, err });
    defer gpa.free(bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// `projectfile_path(dir)` NON-strict (`Types.jl:180-186`): the first name
/// that exists, else the would-be `<dir>/Project.toml`.
fn projectFileNonStrict(arena: Allocator, io: Io, dir: []const u8) Allocator.Error![]const u8 {
    for (stdlibs_mod.project_names) |name| {
        const candidate = try fspath.join(arena, &.{ dir, name });
        if (isFile(io, candidate)) return candidate;
    }
    return fspath.join(arena, &.{ dir, "Project.toml" });
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// `<depots1>/environments/v<major>.<minor>` — what `@v#.#` expands to
/// (`base/initdefs.jl:300-310`). A one-element slice, or empty when there is no
/// depot or no version to key it on.
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

/// `map(abspath, DEPOT_PATH)` (`base/loading.jl:2982`).
///
/// `Base.abspath` is lexical — `normpath(joinpath(pwd(), path))`, never
/// `realpath` — so this is `fspath.resolve` against the process cwd and not a
/// symlink resolution. An entry that cannot be absolutised (no readable cwd) is
/// passed through unchanged rather than dropped: a relative depot is still
/// better than no depot.
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
/// which `std.process.run` resolves through the PARENT's `PATH`.
fn juliaExe(arena: Allocator, io: Io, opts: Options) Allocator.Error![]const u8 {
    if (opts.julia_exe) |e| return e;
    const p = opts.julia_prefix orelse return "julia";
    const exe = try fspath.join(arena, &.{ p, "bin", "julia" });
    Io.Dir.cwd().access(io, exe, .{}) catch return "julia";
    return exe;
}

const Stdlibs = struct {
    uuids: std.AutoHashMapUnmanaged([16]u8, void) = .empty,
    /// `Types.stdlib_dir()`, once it is known. Reported so `packageInfo` and
    /// the sandbox resolve share one answer rather than each deriving its own.
    dir: ?[]const u8 = null,
};

/// The uuids `is_stdlib(uuid)` is true for (`Types.jl:537`) — the FIXED set
/// only. The upgradable stdlibs resolve from the registry like any other
/// package, so dropping them from the build closure would skip a `build.jl`
/// Pkg runs.
///
/// A prefix that cannot be read is not fatal: the closure is then a superset,
/// which at worst looks for a `deps/build.jl` in a stdlib and does not find
/// one.
fn loadStdlibs(arena: Allocator, io: Io, opts: Options) Allocator.Error!Stdlibs {
    var out: Stdlibs = .{};
    if (opts.stdlib_dir) |d| out.dir = d;
    const prefix = opts.julia_prefix orelse return out;
    const set = stdlibs_mod.load(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = opts.julia_version,
    }) catch return out;
    for (set.fixed) |s| try out.uuids.put(arena, s.uuid.bytes, {});
    if (out.dir == null) out.dir = set.dir;
    return out;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
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

test "gen_build_code: -O0 code sets DEPOT_PATH, cds, includes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = try genBuildCode(arena, .{ .entries = &.{ "/a", "/b" } }, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
    }, "/pkgs/Foo/deps/build.jl");
    try testing.expectEqualStrings(
        \\append!(empty!(Base.DEPOT_PATH), ["/a", "/b"])
        \\append!(empty!(Base.DL_LOAD_PATH), String[])
        \\cd("/pkgs/Foo/deps")
        \\include("/pkgs/Foo/deps/build.jl")
        \\
    , code);
}

test "gen_build_code escapes what repr escapes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A `$` in a path is string interpolation in Julia, so an unescaped one
    // turns a build into an evaluation of whatever follows it.
    const code = try genBuildCode(arena, .{ .entries = &.{} }, .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
    }, "/we\"ird/$x/deps/build.jl");
    try testing.expect(std.mem.indexOf(u8, code, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, code, "\\$") != null);
}

test "dependency order: a package sorts after everything it depends on" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = parseUuid("00000000-0000-0000-0000-0000000000aa");
    const b = parseUuid("00000000-0000-0000-0000-0000000000bb");
    const c = parseUuid("00000000-0000-0000-0000-0000000000cc");

    // C -> B -> A. Fed in the WRONG order, which is the only way this test
    // could pass by accident otherwise.
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "A", .uuid = a },
        .{ .name = "B", .uuid = b, .deps = &.{.{ .name = "A", .uuid = a }} },
        .{ .name = "C", .uuid = c, .deps = &.{.{ .name = "B", .uuid = b }} },
    };
    const manifest: manifest_mod.Manifest = .{ .entries = &entries };
    var proj = try project_mod.empty(testing.allocator);
    defer proj.deinit();

    var builds = [_]Build{
        .{ .name = "C", .uuid = c, .source_path = "", .build_file = "", .log_file = "" },
        .{ .name = "A", .uuid = a, .source_path = "", .build_file = "", .log_file = "" },
        .{ .name = "B", .uuid = b, .source_path = "", .build_file = "", .log_file = "" },
    };
    try sortByDependencyOrder(arena, &builds, &proj, &manifest);
    try testing.expectEqualStrings("A", builds[0].name);
    try testing.expectEqualStrings("B", builds[1].name);
    try testing.expectEqualStrings("C", builds[2].name);
}

test "a dependency cycle warns and linearizes rather than failing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = parseUuid("00000000-0000-0000-0000-0000000000aa");
    const b = parseUuid("00000000-0000-0000-0000-0000000000bb");
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "A", .uuid = a, .deps = &.{.{ .name = "B", .uuid = b }} },
        .{ .name = "B", .uuid = b, .deps = &.{.{ .name = "A", .uuid = a }} },
    };
    const manifest: manifest_mod.Manifest = .{ .entries = &entries };
    var proj = try project_mod.empty(testing.allocator);
    defer proj.deinit();

    var builds = [_]Build{
        .{ .name = "A", .uuid = a, .source_path = "", .build_file = "", .log_file = "" },
        .{ .name = "B", .uuid = b, .source_path = "", .build_file = "", .log_file = "" },
    };
    // The point is that this RETURNS. Both packages keep an order and both get
    // built; Pkg does exactly this and says so out loud.
    try sortByDependencyOrder(arena, &builds, &proj, &manifest);
    try testing.expectEqual(@as(usize, 2), builds.len);
}

test "get_deps drops stdlibs and does not walk through them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = parseUuid("00000000-0000-0000-0000-0000000000aa");
    const sl = parseUuid("00000000-0000-0000-0000-0000000000fe");
    const hidden = parseUuid("00000000-0000-0000-0000-0000000000dd");
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "A", .uuid = a, .deps = &.{.{ .name = "SL", .uuid = sl }} },
        .{ .name = "SL", .uuid = sl, .deps = &.{.{ .name = "Hidden", .uuid = hidden }} },
        .{ .name = "Hidden", .uuid = hidden },
    };
    const manifest: manifest_mod.Manifest = .{ .entries = &entries };
    var proj = try project_mod.empty(testing.allocator);
    defer proj.deinit();

    var stdlibs: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try stdlibs.put(arena, sl.bytes, {});

    const closure = try getDeps(arena, &.{a}, &proj, &manifest, stdlibs);
    // Just A. `SL` is a stdlib so `continue` fires before its deps are pushed,
    // and `Hidden` is therefore never reached -- exactly `_get_deps!`'s shape.
    try testing.expectEqual(@as(usize, 1), closure.len);
    try testing.expectEqualStrings("A", manifest.findByUuid(closure[0]).?.name);
}
