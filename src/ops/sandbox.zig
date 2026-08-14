//! The Julia sandbox: a throwaway environment a package's own code runs in.
//!
//! `Pkg.build` and `Pkg.test` both need the same thing — run a script that
//! lives *inside* a package, with that package importable, with its `build`/
//! `test` target dependencies importable, and with the parent environment's
//! resolved versions held wherever they still work. `Operations.sandbox`
//! (`Operations.jl:2217-2320`) is that machinery, shared verbatim between the
//! two verbs, which is why it is its own module here rather than a private
//! helper inside `build.zig`. `ajt test` and `Apps` are the next two callers.
//!
//! ### What gets built
//!
//! `mktempdir()` holding three files (`:2225-2228`):
//!
//! ```text
//! <tmp>/Project.toml              the target project (below)
//! <tmp>/Manifest.toml             the parent's, pruned to the target's closure
//! <tmp>/JuliaLocalPreferences.toml   the merged preferences, when there are any
//! ```
//!
//! and the child then runs under `JULIA_LOAD_PATH="@:<tmp>"` with
//! `JULIA_PROJECT` **unset** (`:2312-2313`). Both halves matter. The `@` is the
//! active project, which `JULIA_PROJECT=nothing` plus a `--project` the child
//! never gets makes resolve to `<tmp>` itself; leaving a stale `JULIA_PROJECT`
//! set would silently run the script against the caller's environment instead.
//!
//! The preferences file is `first(Base.preferences_names)` (`:2228`), and that
//! is **`JuliaLocalPreferences.toml`**, not `LocalPreferences.toml` —
//! `preferences_names = ("JuliaLocalPreferences.toml", "LocalPreferences.toml")`
//! (`base/loading.jl:637`). Writing the second name would still be *read* by
//! Julia, but only if the first is absent, so the difference is invisible until
//! a package ships a `JuliaLocalPreferences.toml` of its own.
//!
//! ### `gen_target_project` — where the target's deps come from
//!
//! `Operations.jl:2336-2378`. The package's `[deps]` and `[sources]` are copied
//! wholesale, then each name in `project.targets[target]` is resolved by
//! looking in **`extras` first, then `weakdeps`** (`:2367-2371`) and erroring
//! naming the target if it is in neither. Finally every dep that has a
//! `[compat]` entry in the source project carries it over (`:2379-2383`).
//!
//! A package with **no project file at all** takes the REQUIRE branch
//! (`:2339-2358`): deps come from the parent manifest entry. `test/REQUIRE` is
//! not ported — it is deprecated in Pkg itself, warns when used, and only
//! applies to `test`.
//!
//! If the package ships its own `deps/Project.toml` (or `test/Project.toml`),
//! that file is used **instead** of a generated one (`:1443-1445`,
//! `:2233-2242`). Both branches absolutise `[sources]`, but against **different
//! directories**, and the difference is not decorative:
//!
//!   * generated -> `abspath!(ctx.env, override)` at `:2240-2242`, i.e. against
//!     the PARENT project's directory — even though the sources were copied out
//!     of the *package's* project. That is a Pkg bug, reproduced rather than
//!     fixed: a relative `[sources]` path in a package's own `Project.toml` is
//!     resolved against the environment that depends on it.
//!   * shipped -> `abspath!(sandbox_env, temp_ctx.env.project)` at `:2280-2281`,
//!     against `dirname(projectfile_path(sandbox_path))`, i.e. the `deps/`
//!     directory the file ships in. That one is right. Pkg does it late, after
//!     re-reading `<tmp>/Project.toml` inside `with_temp_env`, and persists it
//!     with `write_env` (`:2307`); doing it before this module's single write
//!     lands the same bytes in the same file.
//!
//! ### `sandbox_preserve` — the manifest
//!
//! `:2172-2193`. Deep-copy the parent's, then:
//!
//!   1. **Inject the root package as a path entry** — `PackageEntry(name =
//!      env.pkg.name, path = dirname(env.project_file), deps =
//!      env.project.deps)`. Without it a dependency that points back at the
//!      project under test resolves to nothing.
//!   2. **Bump `manifest_format` to 2.0** if it is older, "so that warnings
//!      aren't thrown for the temp sandbox manifest" (`:2181-2184`).
//!   3. **Re-record the project hash** (`record_project_hash`, `:2189`) — the
//!      hash of the PARENT project, because the manifest still describes the
//!      parent's resolve.
//!   4. **Prune to the target's closure**: keep `{target.uuid} ∪
//!      values(sandbox_project.deps)` and close over `entry.deps`.
//!
//! Then `abspath!` rewrites every surviving `path` entry against
//! `dirname(env.manifest_file)` (`:2195-2202`, `Pkg/src/utils.jl:140`) —
//! mandatory, since the manifest is about to move to `<tmp>` and a relative
//! path would resolve against the wrong directory.
//!
//! ### Resolving inside
//!
//! Pkg runs `Pkg.resolve(temp_ctx; skip_writing_project = true)` and, on a
//! `ResolverError` with `allow_reresolve`, falls back to `Pkg.update`
//! (`:2294-2304`). The success path is the interesting one and Pkg labels it
//! `@debug "Using _parent_ dep graph"`: the pinned versions already satisfy the
//! target project, and the resolve is a CHECK, not a change.
//!
//! Ajt makes that check **optional**, via `Options.resolve`, and says so
//! plainly rather than pretending otherwise. With no registry configured there
//! is nothing to re-resolve *against* — Ajt's resolver reads a registry, and a
//! build sandbox is frequently created in a container that has one package and
//! no `General`. Skipping it takes Pkg's success path unconditionally: the
//! parent dep graph, verbatim. What is then NOT caught is a `deps/Project.toml`
//! demanding a version the parent manifest does not hold, which Pkg would
//! re-resolve for and this reports as a plain load failure from the child.
//! `Env.resolved` says which of the two happened, so a caller never has to
//! guess.
//!
//! ### `Options.stdlibs` — the one thing skipping the resolve cannot afford
//!
//! Pkg's resolve is not only a check. `Pkg.resolve` is
//! `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST)` (`API.jl:455-457`), and
//! `update_manifest!` (`:224-248`) writes an entry for every package in the
//! solved graph — **including the target's `test`/`build` dependencies, which
//! the parent manifest has no reason to carry**. `[extras]` are not resolved
//! into an environment's manifest, so a package whose `[targets] test` names
//! `Test` — that is, essentially every package — has no `Test` entry to
//! preserve. A sandbox manifest missing it is not a smaller manifest: Julia
//! resolves a name through `explicit_manifest_uuid_path`, and an absent entry
//! is `ERROR: Package Test not found in current path` from the child
//! (`base/loading.jl`; the entry with neither `path` nor `git-tree-sha1` is
//! precisely what makes Julia fall back to `Sys.STDLIB`).
//!
//! So when `Options.stdlibs` is supplied, every dep of the sandbox project that
//! the working manifest does not hold and that IS a stdlib is added — name,
//! uuid, its own `version` (`stdlib_version`, `Types.jl:603-609`: the stdlib's
//! own, and `nothing` for an unversioned one like `SuiteSparse`) and its own
//! `[deps]`/`[weakdeps]` — then closed over those deps to a fixpoint. That is
//! exactly the subgraph `deps_graph` would have produced for them: a stdlib is
//! decided at level 0 as a single fixed version and never consulted for in a
//! registry (`julia/stdlibs.zig`), so there is nothing here a resolve could
//! have decided differently.
//!
//! What is NOT filled is a NON-stdlib test dependency the parent manifest does
//! not carry — that one genuinely needs a registry. Those names come back in
//! `Env.missing` rather than being silently dropped, so the caller can say
//! which package the child is about to fail to load and why.
//!
//! ### Allocation and lifetime
//!
//! Everything the `Env` names lives on the caller's `arena`. The temp
//! DIRECTORY does not: it is a real directory that must be removed, and
//! `Env.destroy` is the only thing that removes it. `mktempdir() do ... end`
//! deletes on the way out of the block including on error, so callers must
//! `defer env.destroy(io)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const project_hash_mod = @import("../julia/project_hash.zig");
const preferences = @import("../julia/preferences.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const toml_emit = @import("../toml/emit.zig");
const resolve_ops = @import("resolve.zig");

pub const Uuid = manifest_mod.Uuid;
const Manifest = manifest_mod.Manifest;
const PackageEntry = manifest_mod.PackageEntry;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

/// `Base.project_names` (`loading.jl:630`) — `JuliaProject.toml` first.
const project_names = preferences.project_names;
/// `Base.manifest_names`, restricted to the two unversioned spellings a
/// package's own `deps/`/`test/` directory can plausibly carry.
const manifest_names = [_][]const u8{ "JuliaManifest.toml", "Manifest.toml" };
/// `first(Base.preferences_names)` (`Operations.jl:2228`). See the header:
/// this is `JuliaLocalPreferences.toml`, not the name most people expect.
const preferences_name = preferences.preferences_names[0];

pub const Error = error{
    /// A name in `[targets] <target>` is in neither `[extras]` nor
    /// `[weakdeps]` — `pkgerror("`$name` declared as a `$target` dependency,
    /// but no such entry in `extras` or `weakdeps`")` (`Operations.jl:2373`).
    TargetDepUnknown,
    /// The parent project or manifest would not parse.
    BadEnvironment,
    /// The sandbox resolve failed and `allow_reresolve` was off, or the
    /// fallback failed too.
    ResolveFailed,
} || project_hash_mod.Error || project_mod.Error || manifest_mod.Error || Allocator.Error ||
    Io.Dir.StatFileError || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError ||
    Io.Dir.CreateDirPathOpenError || Io.Dir.CreateDirError || Io.Dir.RealPathFileAllocError;

/// The resolve step. Null on `Options.resolve` skips it; see the header for
/// what that costs.
pub const ResolveConfig = struct {
    /// Depot holding `registries/<registry_name>`.
    registry_depot: []const u8,
    registry_name: []const u8 = "General",
    /// The full depot search stack, for the fixups pass and the
    /// `*_INSTALLED` tiers.
    depots: ?depot_mod.Stack = null,
    julia_prefix: ?[]const u8 = null,
    stdlib_dir: ?[]const u8 = null,
    /// `allow_reresolve` (`Operations.jl:2221`). On a `ResolverError` Pkg
    /// falls through to `Pkg.update`, i.e. a full re-resolve that is allowed
    /// to move versions; off, it rethrows.
    allow_reresolve: bool = true,
};

pub const Options = struct {
    /// The PARENT environment. Both paths are used as given — `abspath!`
    /// resolves against their directories, so a relative pair works but a
    /// caller that has absolute paths should pass those.
    project_file: []const u8,
    manifest_file: []const u8,

    /// The package the sandbox exists for: it is force-added to the temp
    /// project's `[deps]` (`:2283`) and kept by the prune.
    target_name: []const u8,
    target_uuid: Uuid,
    /// `source_path(manifest_file, pkg)` — the package's root directory.
    source_path: []const u8,
    /// `sandbox_path`: `<source>/deps` for build, `<source>/test` for test.
    sandbox_path: []const u8,
    /// The `[targets]` key: `"build"` or `"test"`.
    target: []const u8,

    /// Where the temp environment is created. Null means `$TMPDIR`-ish; see
    /// `tempParent`.
    tmp_parent: ?[]const u8 = null,
    /// Extra load-path entries for the preferences merge, after the package's
    /// own project and the environment under build. In a real Julia this is
    /// `["@", "@v#.#", "@stdlib"]`; Ajt cannot expand those itself, so a
    /// caller that knows the shared default environment passes it here.
    extra_pref_envs: []const []const u8 = &.{},

    /// The installation's stdlibs, used to fill the target dependencies the
    /// parent manifest cannot have — see the header. Null leaves the working
    /// manifest exactly as `sandbox_preserve` pruned it, which is right for a
    /// `build` target (those name real packages far more often than stdlibs)
    /// and wrong for a `test` one.
    stdlibs: ?*const stdlibs_mod.Set = null,

    resolve: ?ResolveConfig = null,
};

pub const Env = struct {
    /// The temp directory. Owned by this struct until `destroy`.
    dir: []const u8,
    project_file: []const u8,
    manifest_file: []const u8,
    /// Written unconditionally (`:2272-2276`), empty table and all — see
    /// `writePreferences`. Null only when the merge itself could not be done.
    preferences_file: ?[]const u8 = null,
    /// `"@:<tmp>"` — the value of `JULIA_LOAD_PATH` for the child
    /// (`:2312-2313`). Not `@:@stdlib`: a sandbox must see `<tmp>` and must NOT
    /// see the default `@v#.#`, or a package satisfied from the user's shared
    /// environment turns a missing target dependency into a passing build.
    load_path: []const u8,
    /// The package shipped its own `deps/Project.toml`, so no target project
    /// was generated. Changes what `[compat]` the sandbox has and is worth
    /// reporting.
    has_sandbox_project: bool = false,
    /// Whether the resolve step ran at all (`Options.resolve != null`).
    resolved: bool = false,
    /// The resolve fell through to a full re-resolve — Pkg's "Could not use
    /// exact versions of packages in manifest. Re-resolving dependencies"
    /// (`:2302`). A caller should say so: the versions the child sees are then
    /// NOT the environment's.
    reresolved: bool = false,
    /// Entries the pruned manifest kept. Reported so a gate can assert the
    /// prune did something.
    entries: usize = 0,
    /// How many entries `Options.stdlibs` added on top of the prune. Zero when
    /// no fill was asked for.
    filled: usize = 0,
    /// Deps of the sandbox project with no manifest entry and no stdlib of that
    /// uuid — the ones a registry would have been needed for. The child WILL
    /// fail to load these; the caller is expected to say so before it does,
    /// because "Package Foo not found in current path" out of a test suite
    /// looks like the suite's bug rather than the sandbox's.
    missing: []const []const u8 = &.{},

    /// `mktempdir() do ... end` deletes the directory on the way out of the
    /// block, error or not (`base/file.jl`). Nothing else does, so this must
    /// be `defer`red at the call site.
    ///
    /// Failure is swallowed: a leaked temp directory is a tidiness problem and
    /// must not turn a successful build into a failed command.
    pub fn destroy(self: *const Env, io: Io) void {
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
    }
};

/// Build the temp environment. The caller runs the child; this never spawns
/// one.
pub fn create(gpa: Allocator, arena: Allocator, io: Io, opts: Options) Error!Env {
    const dir = try makeTempDir(arena, io, opts.tmp_parent);
    errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const tmp_project = try fspath.join(arena, &.{ dir, "Project.toml" });
    const tmp_manifest = try fspath.join(arena, &.{ dir, "Manifest.toml" });

    // --- the parent environment -------------------------------------------
    const parent_dir = fspath.dirname(opts.project_file) orelse ".";
    const manifest_dir = fspath.dirname(opts.manifest_file) orelse ".";

    var parent_proj = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, opts.project_file, arena, .limited(max_project_bytes)) catch
            return error.BadEnvironment;
        break :blk project_mod.parse(arena, src, .{ .file = opts.project_file }, null) catch
            return error.BadEnvironment;
    };
    var parent_manifest = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, opts.manifest_file, arena, .limited(max_manifest_bytes)) catch |err| switch (err) {
            error.FileNotFound => break :blk manifest_mod.Manifest{},
            else => return error.BadEnvironment,
        };
        break :blk manifest_mod.parse(arena, src, null) catch return error.BadEnvironment;
    };

    // --- the sandbox project (`:2226-2240`) --------------------------------
    const sandbox_project_file = try locate(arena, io, opts.sandbox_path, &project_names);
    var has_sandbox_project = false;
    var proj: project_mod.Project = if (sandbox_project_file) |f| blk: {
        has_sandbox_project = true;
        const src = try Io.Dir.cwd().readFileAlloc(io, f, arena, .limited(max_project_bytes));
        break :blk try project_mod.parse(arena, src, .{ .file = f }, null);
    } else try genTargetProject(arena, io, opts, &parent_manifest);
    // Two different anchors, one per branch — see the header. Getting this
    // wrong is silent: the sandbox resolves, and a `[sources]` path simply
    // points at nothing under `<tmp>`.
    try abspathSources(arena, &proj, if (has_sandbox_project) opts.sandbox_path else parent_dir);

    // The target is force-added to the temp project's deps (`:2283`). Done
    // BEFORE the prune so `keep` sees it through `project.deps` as well as
    // through `target.uuid` — Pkg reaches the same set by a different route
    // (`keep = Set([target.uuid]); union!(keep, values(project.deps))`, `:2188-2189`).
    try proj.addDep(opts.target_name, opts.target_uuid);

    {
        const bytes = try proj.serialize(gpa);
        defer gpa.free(bytes);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_project, .data = bytes });
    }

    // --- sandbox_preserve (`:2172-2193`) -----------------------------------
    var working = try sandboxPreserve(arena, &parent_manifest, &parent_proj, opts, &proj, parent_dir);
    // `abspath!(ctx.env, working_manifest)` (`:2249`).
    try abspathEntries(arena, &working, manifest_dir);

    // --- merge the sandbox's own manifest, if it ships one (`:2251-2264`) --
    try mergeSandboxManifest(arena, io, &working, opts, &parent_proj);

    // --- what the skipped resolve would still have written (see the header) -
    const before_fill = working.entries.len;
    const missing = try fillStdlibs(arena, &working, &proj, opts);

    try writeManifest(gpa, arena, io, tmp_manifest, &working);

    // --- preferences (`:2272-2276`, `Operations.jl:1440-1451`) -------------
    const prefs_file = try writePreferences(gpa, arena, io, dir, opts, sandbox_project_file, parent_dir);

    var env: Env = .{
        .dir = dir,
        .project_file = tmp_project,
        .manifest_file = tmp_manifest,
        .preferences_file = prefs_file,
        .load_path = try std.fmt.allocPrint(arena, "@{c}{s}", .{ fspath.delimiter, dir }),
        .has_sandbox_project = has_sandbox_project,
        .entries = working.entries.len,
        .filled = working.entries.len - before_fill,
        .missing = missing,
    };

    // --- resolve (`:2294-2304`) --------------------------------------------
    if (opts.resolve) |cfg| {
        env.resolved = true;
        env.reresolved = try resolveInside(arena, io, tmp_project, tmp_manifest, cfg);
    }
    return env;
}

// ---------------------------------------------------------------------------
// gen_target_project
// ---------------------------------------------------------------------------

/// `gen_target_project(ctx, pkg, source_path, target)` (`Operations.jl:2336-2384`).
///
/// The result is backed by `arena`, not by a general-purpose allocator, and
/// deliberately so: it is returned BY VALUE into `create`, which never calls
/// `deinit` on it, so a `gpa`-backed `Project` here would leak the whole parsed
/// document on every build. Everything else the sandbox reads is on `arena`
/// too; the temp environment is one lifetime.
fn genTargetProject(
    arena: Allocator,
    io: Io,
    opts: Options,
    parent_manifest: *const Manifest,
) Error!project_mod.Project {
    var out = try project_mod.empty(arena);

    // `projectfile_path(source_path; strict = true) === nothing` (`:2339`) —
    // the pre-Project.toml world. Deps come from the manifest entry and
    // nothing else; `test/REQUIRE` is not ported (see the header).
    const source_project_file = try locate(arena, io, opts.source_path, &project_names) orelse {
        if (parent_manifest.findByUuid(opts.target_uuid)) |e| {
            for (e.deps) |d| try out.addDep(d.name, d.uuid);
        }
        return out;
    };

    const src = try Io.Dir.cwd().readFileAlloc(io, source_project_file, arena, .limited(max_project_bytes));
    var source_proj = try project_mod.parse(arena, src, .{ .file = source_project_file }, null);

    // `test_project.deps = source_env.project.deps` (`:2362`).
    for (source_proj.deps.entries.items) |d| try out.addDep(d.name, d.uuid);
    // `test_project.sources = source_env.project.sources` (`:2363`).
    for (source_proj.sources.items) |s| try out.setSource(s);

    // `:2365-2375`: extras FIRST, then weakdeps, and a name in neither is a
    // hard error naming the target — not a silently-dropped dependency, which
    // is what a `orelse continue` here would produce and which the build would
    // then fail on with an unrelated `ArgumentError: Package X not found`.
    for (source_proj.targets.items) |t| {
        if (!std.mem.eql(u8, t.name, opts.target)) continue;
        for (t.deps) |name| {
            const uuid = source_proj.extras.get(name) orelse
                source_proj.weakdeps.get(name) orelse
                return error.TargetDepUnknown;
            try out.addDep(name, uuid);
        }
    }

    // `:2379-2383`: every dep of the RESULT that the SOURCE project has a
    // compat string for. Note the iteration is over `test_project.deps`, so a
    // `[compat]` entry naming something not in the target project is dropped —
    // and `set_compat` with a spec that will not parse is a silent no-op
    // (`:329-334` returns false), which this reproduces by ignoring the parse
    // error rather than failing the build.
    for (out.deps.entries.items) |d| {
        const c = source_proj.compatFor(d.name) orelse continue;
        out.setCompat(d.name, c.str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// sandbox_preserve
// ---------------------------------------------------------------------------

/// `sandbox_preserve(env, target, test_project)` (`Operations.jl:2172-2193`).
fn sandboxPreserve(
    arena: Allocator,
    parent_manifest: *const Manifest,
    parent_proj: *const project_mod.Project,
    opts: Options,
    sandbox_proj: *const project_mod.Project,
    parent_dir: []const u8,
) Error!Manifest {
    var out = parent_manifest.*;

    // 1. Inject the root (`:2175-2180`). Only when the project HAS an
    // identity: `env.pkg !== nothing` is `name !== nothing && uuid !== nothing`
    // (`Types.jl`), and a bare environment has neither.
    if (parent_proj.name != null and parent_proj.uuid != null) {
        const root_uuid = parent_proj.uuid.?;
        var deps = try arena.alloc(manifest_mod.Dep, parent_proj.deps.count());
        for (parent_proj.deps.entries.items, 0..) |d, i| deps[i] = .{ .name = d.name, .uuid = d.uuid };
        const root: PackageEntry = .{
            .name = parent_proj.name.?,
            .uuid = root_uuid,
            // `path = dirname(env.project_file)`. `abspathEntries` runs after
            // this and joins it to `dirname(manifest_file)`, which is the same
            // directory in the normal case and the RIGHT one when a project
            // redirects its manifest elsewhere.
            .path = parent_dir,
            .deps = deps,
        };
        var entries: std.ArrayList(PackageEntry) = .empty;
        var replaced = false;
        for (out.entries) |e| {
            if (std.mem.eql(u8, &e.uuid.bytes, &root_uuid.bytes)) {
                try entries.append(arena, root);
                replaced = true;
            } else try entries.append(arena, e);
        }
        if (!replaced) try entries.append(arena, root);
        out.entries = entries.items;
    }

    // 2. `manifest_format < v"2.0"` -> 2.0 (`:2181-2184`).
    if (out.format.major < 2) out.format = .{ .major = 2, .minor = 0, .patch = 0 };

    // 3. The project hash — and it is the SANDBOX project's, not the parent's.
    //
    // `sandbox_preserve` records the parent's (`record_project_hash(env)`,
    // `:2190`), and then the resolve two steps later overwrites it:
    // `Pkg.resolve` is `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST)`
    // (`API.jl:455-457`) and `update_manifest!` ends with
    // `record_project_hash(env)` over the TEMP env (`:246`). Pkg's resolve is
    // unconditional, so the parent's value never survives into a written
    // sandbox — measured, by capturing `<tmp>` from inside `Pkg.test`'s
    // `test_fn` and hashing both projects: the manifest carries the sandbox
    // project's hash in every case.
    //
    // Ajt's resolve is optional, so recording the parent's here and stopping
    // would leave the one state Pkg never produces. Stamping the sandbox
    // project's is also the honest answer to what `project_hash` asks — "was
    // this manifest resolved from the project next to it" — since the file this
    // manifest is about to sit beside is `<tmp>/Project.toml`.
    {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        const table = try sandbox_proj.destructure(scratch.allocator());
        const hex = try project_hash_mod.compute(scratch.allocator(), table);
        try out.setProjectHash(arena, try manifest_mod.Sha1.parse(&hex));
    }

    // 4. Prune (`:2185-2192`). `keep = {target.uuid} ∪ values(project.deps)`,
    // where `project` is the sandbox project as WRITTEN — which already holds
    // the target, since `create` added it before serialising.
    var keep: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try keep.put(arena, opts.target_uuid.bytes, {});
    for (sandbox_proj.deps.entries.items) |d| try keep.put(arena, d.uuid.bytes, {});
    out.entries = try pruneTo(arena, out.entries, &keep);
    return out;
}

/// `prune_manifest(manifest, keep)` (`Operations.jl:1273-1292`): close `keep`
/// over `entry.deps` to a fixpoint, then filter.
///
/// Note `prune_deps` follows STRONG deps only — never `weakdeps` — which is
/// why a manifest can legitimately carry entries no strong edge reaches. Same
/// rule as `resolve.pruneManifest`, which cannot be reused here because it
/// seeds `keep` from a project rather than from a caller-supplied set.
fn pruneTo(
    arena: Allocator,
    entries: []const PackageEntry,
    keep: *std.AutoHashMapUnmanaged([16]u8, void),
) Allocator.Error![]const PackageEntry {
    while (true) {
        var clean = true;
        for (entries) |e| {
            if (!keep.contains(e.uuid.bytes)) continue;
            for (e.deps) |d| {
                const gop = try keep.getOrPut(arena, d.uuid.bytes);
                if (!gop.found_existing) clean = false;
            }
        }
        if (clean) break;
    }
    var kept: std.ArrayList(PackageEntry) = .empty;
    for (entries) |e| {
        if (keep.contains(e.uuid.bytes)) try kept.append(arena, e);
    }
    return kept.items;
}

// ---------------------------------------------------------------------------
// The stdlib fill
// ---------------------------------------------------------------------------

/// Add a manifest entry for every dep of the sandbox project the pruned
/// manifest does not carry and the installation ships as a stdlib, closed over
/// those entries' own `[deps]`. See the module header for why this exists at
/// all; this is the mechanism.
///
/// Each entry is what `update_manifest!` (`Operations.jl:224-248`) would have
/// written for a stdlib: `name`, `uuid`, `version = stdlib_version(uuid, …)` —
/// the stdlib's OWN version, null for an unversioned one (`Types.jl:603-609`) —
/// and its `[deps]`/`[weakdeps]` as read from its `Project.toml`. Deliberately
/// no `path` and no `git-tree-sha1`: an entry with neither is exactly what
/// makes Julia's `explicit_manifest_uuid_path` fall back to `Sys.STDLIB`, and
/// writing a path would pin the child to this run's stdlib directory.
///
/// The walk follows STRONG deps only, like `prune_deps`. A stdlib's weakdeps
/// are recorded on the entry (`fixups_from_projectfile!` sets them, `:280`) but
/// not chased: on a stock 1.12 installation the only fixed stdlib with any is
/// `Pkg` itself.
///
/// Returns the names it could NOT fill — deps that are neither in the manifest
/// nor stdlibs, i.e. the ones that genuinely needed a registry.
fn fillStdlibs(
    arena: Allocator,
    m: *Manifest,
    sandbox_proj: *const project_mod.Project,
    opts: Options,
) Allocator.Error![]const []const u8 {
    const set = opts.stdlibs orelse return &.{};

    // `seen` is "this uuid needs no further thought", which covers both the
    // entries already present and the ones this pass adds or gives up on. A
    // second `queue` hit for the same uuid — normal, since several stdlibs
    // depend on `StyledStrings` — must not append it twice.
    var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    for (m.entries) |e| try seen.put(arena, e.uuid.bytes, {});

    var entries: std.ArrayList(PackageEntry) = .empty;
    try entries.appendSlice(arena, m.entries);
    var missing: std.ArrayList([]const u8) = .empty;

    var queue: std.ArrayList(manifest_mod.Dep) = .empty;
    for (sandbox_proj.deps.entries.items) |d| {
        try queue.append(arena, .{ .name = d.name, .uuid = d.uuid });
    }

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const want = queue.items[i];
        const gop = try seen.getOrPut(arena, want.uuid.bytes);
        if (gop.found_existing) continue;

        // `is_stdlib(uuid)` is FALSE for `DelimitedFiles`/`Statistics`
        // (`Types.jl:501, 514-517`): they ship in the stdlib tree and are still
        // resolved from a registry, so filling one would pin it forever at
        // whatever version this installation happens to carry. They belong in
        // `missing`, with everything else a registry decides.
        const sl = set.byUuid(want.uuid) orelse {
            try missing.append(arena, want.name);
            continue;
        };
        if (sl.upgradable) {
            try missing.append(arena, want.name);
            continue;
        }

        var deps: std.ArrayList(manifest_mod.Dep) = .empty;
        for (sl.deps) |u| {
            // A dep of a stdlib is always another stdlib, so this never fires
            // in practice; a name-less dep would render as a manifest entry
            // nothing can resolve, so skipping beats inventing one.
            const dep = set.byUuid(u) orelse continue;
            try deps.append(arena, .{ .name = dep.name, .uuid = u });
            try queue.append(arena, .{ .name = dep.name, .uuid = u });
        }
        var weakdeps: std.ArrayList(manifest_mod.Dep) = .empty;
        for (sl.weakdeps) |u| {
            const dep = set.byUuid(u) orelse continue;
            try weakdeps.append(arena, .{ .name = dep.name, .uuid = u });
        }

        try entries.append(arena, .{
            .name = sl.name,
            .uuid = want.uuid,
            .version = sl.version,
            .deps = deps.items,
            .weakdeps = weakdeps.items,
        });
    }

    m.entries = entries.items;
    return missing.items;
}

/// `abspath!(env, manifest)` (`Operations.jl:2195-2202`) — every `path` entry
/// becomes `normpath(joinpath(dirname(env.manifest_file), path))`
/// (`utils.jl:140`).
///
/// Not cosmetic. The manifest is copied to `<tmp>`, and a `path = "../Foo"`
/// left alone would then resolve against `<tmp>`, i.e. to nothing.
fn abspathEntries(arena: Allocator, m: *Manifest, manifest_dir: []const u8) Allocator.Error!void {
    var out = try arena.alloc(PackageEntry, m.entries.len);
    for (m.entries, 0..) |e, i| {
        out[i] = e;
        if (e.path) |p| out[i].path = try fspath.resolve(arena, &.{ manifest_dir, p });
    }
    m.entries = out;
}

/// `abspath!(env, project)` (`Operations.jl:2204-2213`): `[sources]` `path`
/// keys are PROJECT-relative, so they join with `dirname(env.project_file)` —
/// deliberately not the manifest's directory, and Pkg's own comment says so.
fn abspathSources(arena: Allocator, p: *project_mod.Project, project_dir: []const u8) Allocator.Error!void {
    for (p.sources.items) |s| {
        const rel = s.path orelse continue;
        var copy = s;
        copy.path = try fspath.resolve(arena, &.{ project_dir, rel });
        try p.setSource(copy);
    }
}

/// `:2245-2264` — fold the sandbox directory's OWN manifest into the working
/// one, "really only need to copy over 'special' nodes".
///
/// The collision rule is worth reading twice, because the branch that warns
/// does NOT assign: an entry that differs from the parent's, for anything
/// other than the root package, is warned about and the PARENT's is kept. Only
/// an entry that is absent, identical, or the root package is taken from the
/// sandbox.
fn mergeSandboxManifest(
    arena: Allocator,
    io: Io,
    working: *Manifest,
    opts: Options,
    parent_proj: *const project_mod.Project,
) Error!void {
    const file = try locate(arena, io, opts.sandbox_path, &manifest_names) orelse return;
    const src = try Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(max_manifest_bytes));
    var sandbox_m = manifest_mod.parse(arena, src, null) catch return error.BadEnvironment;
    try abspathEntries(arena, &sandbox_m, fspath.dirname(file) orelse ".");

    var entries: std.ArrayList(PackageEntry) = .empty;
    try entries.appendSlice(arena, working.entries);
    outer: for (sandbox_m.entries) |e| {
        for (entries.items) |*w| {
            if (!std.mem.eql(u8, &w.uuid.bytes, &e.uuid.bytes)) continue;
            // `entry_working != entry && (env.pkg !== nothing && env.pkg.uuid != uuid)`
            // -> warn and keep the parent's. Equality here is by the fields a
            // manifest entry is identified by; a deep structural compare would
            // flag two entries that render identically.
            //
            // `env.pkg !== nothing` is `name !== nothing && uuid !== nothing`
            // (`Types.jl:400-409`), not either one alone: a project with a name
            // and no uuid is not a package, and Pkg then TAKES the sandbox's
            // entry rather than warning about it.
            const has_pkg = parent_proj.name != null and parent_proj.uuid != null;
            const is_root = has_pkg and std.mem.eql(u8, &parent_proj.uuid.?.bytes, &e.uuid.bytes);
            if (!entryEql(w.*, e) and has_pkg and !is_root) {
                std.debug.print(
                    "ajt: manifest in \"{s}\" disagrees with \"{s}\" about \"{s}\"; keeping the environment's\n",
                    .{ opts.sandbox_path, opts.manifest_file, w.name },
                );
                continue :outer;
            }
            w.* = e;
            continue :outer;
        }
        try entries.append(arena, e);
    }
    working.entries = entries.items;
}

fn entryEql(a: PackageEntry, b: PackageEntry) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if ((a.version == null) != (b.version == null)) return false;
    if (a.version) |v| if (v.order(b.version.?) != .eq) return false;
    if ((a.tree_hash == null) != (b.tree_hash == null)) return false;
    if (a.tree_hash) |h| if (!std.mem.eql(u8, &h.bytes, &b.tree_hash.?.bytes)) return false;
    if ((a.path == null) != (b.path == null)) return false;
    if (a.path) |p| if (!std.mem.eql(u8, p, b.path.?)) return false;
    if (a.pinned != b.pinned) return false;
    if (a.deps.len != b.deps.len) return false;
    for (a.deps, b.deps) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!std.mem.eql(u8, &x.uuid.bytes, &y.uuid.bytes)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

/// `Base.get_preferences()` under the load path Pkg installs for the build
/// (`Operations.jl:1440-1451`), written to `<tmp>/JuliaLocalPreferences.toml`.
///
/// Pkg's load path is `[builddir(source_path), Base.LOAD_PATH...]` when the
/// package ships `deps/Project.toml`, and `[projectfile_path(source_path),
/// Base.LOAD_PATH...]` otherwise. `Base.LOAD_PATH` in a stock session is
/// `["@", "@v#.#", "@stdlib"]`, and Ajt cannot expand those from outside a
/// Julia: `@` is the environment being built (which the caller knows and this
/// supplies), `@v#.#` is `Options.extra_pref_envs`' job, and `@stdlib` carries
/// no preferences at all.
fn writePreferences(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    dir: []const u8,
    opts: Options,
    sandbox_project_file: ?[]const u8,
    parent_dir: []const u8,
) Error!?[]const u8 {
    var load_path: std.ArrayList([]const u8) = .empty;
    // The FIRST entry differs by branch, exactly as `:1440-1451` does.
    if (sandbox_project_file != null) {
        try load_path.append(arena, opts.sandbox_path);
    } else if (try locate(arena, io, opts.source_path, &project_names)) |f| {
        try load_path.append(arena, f);
    }
    try load_path.append(arena, parent_dir);
    try load_path.appendSlice(arena, opts.extra_pref_envs);

    // `uuid = nothing`: `Base.get_preferences()` with no argument merges every
    // env's tables unfiltered (`loading.jl:3819`), so nothing is keyed to a
    // package here.
    //
    // A read or parse failure yields NO file rather than a partial one. Julia
    // would throw; writing a half-merged table would be worse than either,
    // because preferences feed `prefs_hash` and a wrong one silently misses
    // every cache entry compiled in the sandbox.
    const envs = preferences.loadEnvs(arena, io, load_path.items, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const merged = preferences.getPreferences(arena, envs, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    // Written even when the merge is empty. `sandbox`'s guard is
    // `preferences !== nothing` (`:2272`), and `build_versions` always passes a
    // `Dict` — `Base.get_preferences()` returns one, never `nothing`
    // (`loading.jl:3819-3837`) — so the file is always there in Pkg's sandbox,
    // as zero bytes when there is nothing to say. Skipping it would be a
    // difference for no gain: an empty table contributes nothing to a merge and
    // nothing to `prefs_hash`.

    const bytes = toml_emit.emitAlloc(gpa, merged, .{ .sorted = false }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    defer gpa.free(bytes);
    const path = try fspath.join(arena, &.{ dir, preferences_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    return path;
}

// ---------------------------------------------------------------------------
// Resolve
// ---------------------------------------------------------------------------

/// `Pkg.resolve(temp_ctx; skip_writing_project = true)` with Pkg's
/// `ResolverError` fallback (`Operations.jl:2294-2304`). Returns whether the
/// fallback was taken.
///
/// `skip_writing_project` is why only the manifest is given a `write_to`: the
/// temp project was written above and must not be rewritten with the
/// resolver's idea of `[compat]`.
fn resolveInside(
    arena: Allocator,
    io: Io,
    project_file: []const u8,
    manifest_file: []const u8,
    cfg: ResolveConfig,
) Error!bool {
    const base: resolve_ops.Options = .{
        .project_file = project_file,
        .manifest_file = manifest_file,
        .registry_depot = cfg.registry_depot,
        .registry_name = cfg.registry_name,
        .julia_prefix = cfg.julia_prefix,
        .stdlib_dir = cfg.stdlib_dir,
        .depots = cfg.depots,
        .build_manifest = true,
        .write_to = manifest_file,
    };
    var all = base;
    all.tier = .all;
    if (resolve_ops.run(arena, io, all)) |_| {
        return false;
    } else |err| switch (err) {
        // Only a resolver verdict may fall through to the re-resolve. Pkg
        // rethrows anything that is not a `ResolverError` (`:2297`), and so
        // must this: retrying a full solve after an out-of-memory or a
        // cancelled read would burn the whole registry read to reach the same
        // failure.
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    }

    if (!cfg.allow_reresolve) return error.ResolveFailed;
    // `Pkg.update(temp_ctx; skip_writing_project = true, update_registry = false)`
    // — a resolve that is allowed to move versions. `tiered` is Ajt's
    // equivalent: `all`, then `direct`, `semver`, `none`.
    var tiered = base;
    tiered.tier = .tiered;
    _ = resolve_ops.run(arena, io, tiered) catch return error.ResolveFailed;
    return true;
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

/// `projectfile_path(dir; strict = true)` / `manifestfile_path(dir; strict = true)`:
/// the first of `names` that exists in `dir`, or null.
fn locate(arena: Allocator, io: Io, dir: []const u8, names: []const []const u8) Allocator.Error!?[]const u8 {
    for (names) |name| {
        const candidate = try fspath.join(arena, &.{ dir, name });
        const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (st.kind == .file) return candidate;
    }
    return null;
}

fn writeManifest(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    path: []const u8,
    m: *const Manifest,
) Error!void {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    m.write(gpa, arena, &aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

const tmp_prefix = "ajt-sandbox-";

/// `mktempdir()`. A fresh directory nobody else can be holding, named
/// unguessably: the child runs arbitrary user code with this on its
/// `LOAD_PATH`, so a predictable name in a world-writable directory is a
/// package-substitution hole.
fn makeTempDir(arena: Allocator, io: Io, parent_opt: ?[]const u8) Error![]const u8 {
    const parent = parent_opt orelse tempParent();
    var parent_dir = try Io.Dir.cwd().createDirPathOpen(io, parent, .{});
    defer parent_dir.close(io);

    var name: [tmp_prefix.len + 22]u8 = undefined;
    @memcpy(name[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(name[tmp_prefix.len..], &random_bytes);

    try parent_dir.createDir(io, &name, .default_dir);
    // Armed before the `realPath`, not after: the caller's `errdefer` keys off
    // the path this function returns, so a failure below would leave a
    // directory nothing knows the name of.
    errdefer parent_dir.deleteTree(io, &name) catch {};
    // Absolute, because the child is given this path in `JULIA_LOAD_PATH` and
    // `cd`s into the package's `deps/` before it uses it.
    return parent_dir.realPathFileAlloc(io, &name, arena);
}

/// Zig 0.16 has no `std.posix.getenv`, and this is deliberately not read from
/// the caller's environment map: the temp directory must be somewhere this
/// process can definitely write, and `/tmp` is that on every platform Ajt
/// targets. A caller with an opinion passes `Options.tmp_parent`.
fn tempParent() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => ".",
        else => "/tmp",
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseUuid(text: []const u8) Uuid {
    return Uuid.parse(text) catch unreachable;
}

test "gen_target_project: extras before weakdeps, compat carried, unknown name errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try tmp.dir.writeFile(io, .{ .sub_path = "Project.toml", .data =
        \\name = "Fixture"
        \\uuid = "00000000-0000-0000-0000-0000000000f1"
        \\
        \\[deps]
        \\Dep = "00000000-0000-0000-0000-0000000000d1"
        \\
        \\[weakdeps]
        \\Weak = "00000000-0000-0000-0000-0000000000aa"
        \\
        \\[extras]
        \\Extra = "00000000-0000-0000-0000-0000000000e1"
        \\Unrelated = "00000000-0000-0000-0000-0000000000c0"
        \\Weak = "00000000-0000-0000-0000-0000000000ff"
        \\
        \\[compat]
        \\Dep = "1.2"
        \\Extra = "0.5"
        \\Unrelated = "3"
        \\
        \\[targets]
        \\build = ["Extra", "Weak"]
        \\
    });

    const empty_manifest: Manifest = .{};
    var proj = try genTargetProject(arena, io, .{
        .project_file = "unused",
        .manifest_file = "unused",
        .target_name = "Fixture",
        .target_uuid = parseUuid("00000000-0000-0000-0000-0000000000f1"),
        .source_path = root,
        .sandbox_path = root,
        .target = "build",
    }, &empty_manifest);
    // No `deinit`: the project is arena-backed, exactly as `create` gets it.
    try testing.expectEqual(@as(usize, 3), proj.deps.count());
    try testing.expect(proj.deps.contains("Dep"));
    try testing.expect(proj.deps.contains("Extra"));
    // `Weak` is in BOTH lists and `extras` is searched first, so the uuid must
    // be the extras one (`...ff`), not the weakdeps one. Getting this backwards
    // produces a project that resolves a different package under the same name.
    var uuid_buf: [36]u8 = undefined;
    try testing.expectEqualStrings(
        "00000000-0000-0000-0000-0000000000ff",
        manifest_mod.formatUuid(proj.deps.get("Weak").?, &uuid_buf),
    );
    // Compat only for names that made it into the target project.
    try testing.expect(proj.compatFor("Dep") != null);
    try testing.expect(proj.compatFor("Extra") != null);
    try testing.expect(proj.compatFor("Unrelated") == null);

    // A target naming something in neither `extras` nor `weakdeps` is a hard
    // error — and it IS reachable from a project that validates, because the
    // project validator's `listed` predicate also accepts `[deps]`
    // (`project.jl:200-206`) while `gen_target_project` searches only the
    // other two (`:2367-2371`). So `targets.build = ["Dep"]` for a plain
    // dependency parses fine and then fails here, exactly as Pkg does.
    try tmp.dir.writeFile(io, .{ .sub_path = "Project.toml", .data =
        \\name = "Fixture"
        \\uuid = "00000000-0000-0000-0000-0000000000f1"
        \\
        \\[deps]
        \\Dep = "00000000-0000-0000-0000-0000000000d1"
        \\
        \\[targets]
        \\build = ["Dep"]
        \\
    });
    try testing.expectError(error.TargetDepUnknown, genTargetProject(arena, io, .{
        .project_file = "unused",
        .manifest_file = "unused",
        .target_name = "Fixture",
        .target_uuid = parseUuid("00000000-0000-0000-0000-0000000000f1"),
        .source_path = root,
        .sandbox_path = root,
        .target = "build",
    }, &empty_manifest));
}

test "pruneTo closes over strong deps only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = parseUuid("00000000-0000-0000-0000-0000000000aa");
    const b = parseUuid("00000000-0000-0000-0000-0000000000bb");
    const c = parseUuid("00000000-0000-0000-0000-0000000000cc");
    const w = parseUuid("00000000-0000-0000-0000-0000000000ee");

    const entries = [_]PackageEntry{
        .{ .name = "A", .uuid = a, .deps = &.{.{ .name = "B", .uuid = b }}, .weakdeps = &.{.{ .name = "W", .uuid = w }} },
        .{ .name = "B", .uuid = b },
        .{ .name = "C", .uuid = c },
        .{ .name = "W", .uuid = w },
    };

    var keep: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    try keep.put(arena, a.bytes, {});
    const kept = try pruneTo(arena, &entries, &keep);
    // A and its strong dep B. NOT W -- `prune_deps` never follows weakdeps --
    // and not C, which nothing reaches.
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("A", kept[0].name);
    try testing.expectEqualStrings("B", kept[1].name);
}
