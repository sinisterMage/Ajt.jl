//! `ajt precompile` — fill Julia's precompilation cache for an environment, one
//! `julia` process per package, in dependency order.
//!
//! ### Ajt still does not write `compiled/`
//!
//! `depot.zig`'s header (`:27-33`) states the invariant: `compiled/v<major>.<minor>`
//! is written by Julia itself, keyed on a Julia version Ajt does not control,
//! and Ajt "exposes the path so it can be reported and garbage-collected
//! against, and never writes there". **This module does not change that.** It
//! never opens a `.ji`, never renames one into place and never forges a cache
//! header. It decides *which* package Julia should compile and *when*, and
//! Julia — a real `julia` child process running the real `Base.compilecache` —
//! does the writing. `Depot.compiledDir()` (`depot.zig:316`) is used here only
//! to report where that happened.
//!
//! Say it explicitly because the shared cache breaks the symmetry: the shared
//! precompile cache DOES import `.ji` objects across depots, and at that point
//! Ajt starts moving cache files around. The distinction that will matter then
//! is the one drawn here — *producing* a cache entry is Julia's job forever;
//! *placing* one is a thing Ajt may eventually do.
//!
//! ### What this is, and what it deliberately is not
//!
//! `base/precompilation.jl:506-1123` is a good scheduler: one `Base.Event` per
//! node, a pre-start SCC scan that skips circular packages, a semaphore that is
//! *released* while a task waits on another process's pidlock, per-config cache
//! flags, extensions as first-class graph nodes, and a live terminal display.
//! None of that is reimplemented here. This module is the **per-package
//! invocation and the ordering** — the seam a scheduler drives and the thing the
//! cache measures against. Concretely, what is NOT implemented:
//!
//!   * **Parallelism.** Independent packages compile at once, over the
//!     frontier in `sched/exec.zig`. What must be preserved is the ORDER, not
//!     the seriality: `create_expr_cache` runs the child with
//!     `--pkgimages=existing`-style semantics, so a package's dependencies must
//!     already have caches before it is compiled — exactly what Pkg's
//!     `wait(was_processed[dep])` (`precompilation.jl:1031`) buys with an
//!     `Event`. The scheduler keeps it structurally: `Compile(p)` sits behind
//!     `Ready(d)` for every dependency `d`, so nothing can start early however
//!     many workers are running. `--jobs 1` walks the topological order
//!     serially instead, and so does a manifest with a dependency cycle, which
//!     `sched.graph.build` refuses to schedule rather than silently skip.
//!   * **Multiple cache configurations.** `configs` is one `(``, CacheFlags())`
//!     pair here, Pkg's default.
//!   * **`strict` and the failure taxonomy.** Every per-package failure is
//!     recorded and the run continues; nothing is raised.
//!
//! ### The set of packages, and why it is not simply "the manifest"
//!
//! `Pkg.precompile()` walks `_collect_reachable!` from `env.project_deps` over
//! the manifest's STRONG deps (`precompilation.jl:613-618`), then drops every
//! node for which `Base.in_sysimage(pkg)` is true (`:624-626`). Both rules bite:
//!
//!  1. **The project's own package is a root.** `ExplicitEnv` inserts
//!     `project_deps[proj_name] = proj_uuid` when the project has BOTH a name
//!     and a uuid (`precompilation.jl:80-91`), and gives it the project's
//!     `[deps]` as its edges (`:197-203`). So `ajt precompile` on a package
//!     environment precompiles that package, and an implementation that walked
//!     only `[deps]` would leave the one module the user actually cares about
//!     uncached. (A name in both `[deps]` and `[weakdeps]` is deleted from
//!     `project_deps` first, `:75-78` — which the project model already models
//!     as `deps_weak`, so `project.deps` is the right list to read.)
//!  2. **Sysimage packages are not compiled at all.** Measured on this host:
//!     `Random`, `SHA` and `FileWatching` answer `in_sysimage` true, `Unicode`,
//!     `Dates`, `Printf`, `TOML` and `UUIDs` answer false. That is a property of
//!     how *this* Julia was built, not of the manifest, so it is asked of Julia
//!     rather than derived from a stdlib list — see `probe_source`. Getting it
//!     wrong is not a no-op: compiling a sysimage package writes a
//!     `compiled/v1.12/<Name>/` directory that `Pkg.precompile()` never creates.
//!
//! Everything else about the set follows from the probe: a package whose source
//! matches `\b__precompile__\(\s*false\s*\)` is skipped exactly as Pkg skips it
//! (`precompilation.jl:1024-1027`), a package already fresh by
//! `Base.isprecompiled` is not spawned for at all, and a package in (or
//! downstream of) a dependency cycle is skipped the way Pkg's SCC scan skips it
//! (`:762-800`).
//!
//! ### Extensions are nodes, and they are what makes the environment finished
//!
//! A package extension has no manifest entry: it is a module under the parent's
//! `ext/` that Julia loads once every trigger is loaded, and it gets a cache
//! entry of its own. Pkg makes each one a graph node (`:626-668`), and until
//! this module did the same, `ajt precompile` left an environment that looked
//! complete and was not — 17 entries short on the engine, every one of which
//! `Pkg.precompile()` would then build. `addExtensionNodes` and
//! `extensionEdges` carry the four rules between them.
//!
//! Two things about them are worth knowing before touching this:
//!
//!   * **Julia mints the uuid, not Ajt.** It is `Base.uuid5(parent, ext_name)`,
//!     and that function (`loading.jl:147-157`) is not RFC 4122 — it is a
//!     bespoke construction over Julia's internal `hash`, labelled "fake uuid5"
//!     with a TODO to delete it. The probe asks for it. See `Node.uuid`.
//!   * **`Base.EXT_PRIMED` is not needed here, and an earlier version of this
//!     comment said it was.** In an EXPLICIT environment `Base.locate_package`
//!     finds an extension's source through the manifest's `extensions` table
//!     (`loading.jl:1091-1100`), and `create_expr_cache`'s `EXT_PRIMED` lookup
//!     (`:3072-3086`) only fires for an implicit env, where `project_file` is
//!     `true`. Confirmed by execution rather than by reading: a cold `julia`
//!     compiled `ConstructionBaseLinearAlgebraExt` with an empty `EXT_PRIMED`,
//!     to the same cache path a primed one produced.
//!
//! ### The pidlock, which is the whole reason this is not `system("julia -e ...")`
//!
//! A depot is routinely shared — a container plus a writable overlay, a CI
//! matrix, a developer's REPL running `Pkg.precompile()` against the same depot
//! while a deploy runs `ajt precompile`. Julia's answer is a pidfile next to the
//! cache entry, at `Base.compilecache_pidfile_path(pkg; flags)` — which is
//! `compilecache_path(pkg, UInt64(0); project = "", flags) * ".pidfile"`
//! (`loading.jl:3871`), i.e. deliberately keyed WITHOUT the active project and
//! WITHOUT the preferences hash so that two projects compiling the same source
//! contend for one lock. The protocol, ported verbatim from
//! `precompile_pkgs_maybe_cachefile_lock` (`precompilation.jl:1253-1293`):
//!
//!   1. `trymkpidlock(pidfile; stale_age = 10)`. Got it → re-check
//!      `isprecompiled` *inside* the lock, then `compilecache`.
//!   2. Refused → someone else is compiling this exact entry. Block on
//!      `mkpidlock` until they finish, then re-check `isprecompiled`: fresh
//!      means they did it (`waited`), stale means they died and we do it.
//!
//! Skipping step 2 is not "a bit slower"; it is two processes writing one cache
//! entry, which is a corrupt `.ji` and a `Invalid header in cache file` that
//! survives until someone deletes the depot. Verified against a real holder: an
//! unlocked compile of `Parsers` took 4.2 s, the same compile with the pidlock
//! held by another process for 9 s took 10.0 s and produced one correct entry.
//!
//! `stale_age = 10` and the mtime refresh that keeps a long compile from having
//! its own lock stolen both live in `FileWatching.Pidfile`; `using FileWatching`
//! in the child is what installs `Base.mkpidlock_hook` and friends
//! (`FileWatching.jl:1004-1006`, hooks declared at `loading.jl:3863-3866`). It
//! costs nothing on this host — `FileWatching` is in the sysimage.
//!
//! ### Spawning a child process, which nothing else in Ajt does
//!
//! This is the first module in the package to run another program. Three
//! choices worth stating:
//!
//!   * **`std.process.run`, not a long-lived `Child` with pipes.** Each
//!     invocation is one short-lived process whose entire output fits in
//!     memory, and `run` is the only form that reads stdout and stderr
//!     concurrently — a `Child` with two pipes read in sequence deadlocks the
//!     moment a package writes more than a pipe buffer of precompile warnings.
//!   * **One process per package, not one process for the whole graph.** A
//!     package that OOMs or segfaults the compiler takes down its own child and
//!     is recorded as `failed`; the other 213 still get caches. It is also the
//!     seam the scheduler needs: a work queue of independent processes.
//!   * **The child's environment is built, not inherited.** `JULIA_DEPOT_PATH`
//!     is set from `opts.stack` because `compilecache_dir` writes to
//!     `DEPOT_PATH[1]` (`loading.jl:3147-3150`) and the caller's ambient depot
//!     must not receive the caches. `JULIA_LOAD_PATH` is pinned to `@:@stdlib`
//!     so the environment under test plus the stdlibs are the only things that
//!     can satisfy a `using`: the default path also contains `@v#.#`, and a
//!     package silently satisfied from the user's shared environment is a cache
//!     that will not reproduce anywhere else. Everything else — `PATH`,
//!     `HOME`, and critically `JULIA_CPU_TARGET`, which is mixed into the cache
//!     filename (`loading.jl:3164-3169`) — is inherited unchanged.
//!
//! ### Allocation
//!
//! `arena` holds the Report and everything it borrows: the parsed models, the
//! graph, every `Result` and every captured stderr tail. It is bundle-lifetime
//! data; the caller drops the arena when it has finished printing. `gpa` backs
//! the transient side — the child environment map and each child's stdout and
//! stderr buffers — and all of it is freed before `run` returns, except the
//! few hundred bytes per package copied into `arena` for the report.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const verify = @import("verify.zig");
const sched_graph = @import("../sched/graph.zig");
const sched_rank = @import("../sched/rank.zig");
const sched_exec = @import("../sched/exec.zig");
const resources = @import("../sched/resources.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const cache_key = @import("../cache/key.zig");
const cache_slug = @import("../cache/slug.zig");
const jicache = @import("../cache/jicache.zig");
const store_mod = @import("../cache/store.zig");
const net_http = @import("../net/http.zig");
/// The child-process seam. Extracted from this module so `build` and `test`
/// get the same three choices (`std.process.run`, one process per unit of
/// work, a BUILT environment) rather than three near-copies of them; the
/// choices themselves and the reasoning are unchanged and now live in
/// `child.zig`'s header.
const child = @import("child.zig");

pub const Uuid = manifest_mod.Uuid;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

/// The probe prints one short line per package; 214 entries is ~40 KB. The cap
/// exists so a wedged child cannot make this process grow without bound.
const max_probe_stdout = 8 * 1024 * 1024;
/// `compilecache` streams the package's own precompile output — `@warn`s,
/// `Downloading artifact` chatter, occasionally a megabyte of method-overwrite
/// warnings — into the stderr this module captures.
const max_child_stderr = child.default_stderr_limit;
const max_child_stdout = child.default_stdout_limit;
/// How much of a failing child's stderr is kept in the Report. The last bytes,
/// not the first: Julia prints the error and the stacktrace last.
const detail_bytes = 4096;
/// The last `detail_bytes` of a failing child's stderr. `child.tail`.
const tail = child.tail;
/// A sysimage is ~150 MB on this Julia and is read once per run to be hashed.
/// The cap is a guard against a path that is not a sysimage at all, not a
/// prediction about how big one can get.
const max_sysimage_bytes = 4 * 1024 * 1024 * 1024;

/// `LOAD_PATH` for every child. See the module header.
const child_load_path = "@:@stdlib";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// The environment: a directory, or a project file directly. Probed exactly
    /// as `Types.projectfile_path` probes it — by `verify`, which is the only
    /// place that probe lives.
    env_path: []const u8,
    /// Overrides manifest discovery entirely.
    manifest_file: ?[]const u8 = null,
    /// Restrict the run to the nodes with these NAMES plus everything they
    /// depend on — `Pkg.precompile(pkgs)`'s filter, ported from
    /// `base/precompilation.jl:786-812`. Matching is by name against EVERY
    /// graph node (a package or an extension), each match pulling in its
    /// transitive dep closure (`collect_all_deps`, `:788`); then one pass in
    /// node order re-admits any extension whose entire dep closure is already
    /// kept (`:806-811` — Pkg compiles the extensions of what you asked for
    /// without being asked). Everything else is DROPPED from the run — not
    /// compiled, not reported — exactly as Pkg's `filter!` (`:811`) drops it
    /// from the queue. A name matching nothing contributes nothing, silently,
    /// which is also Pkg: after the filter it just returns (`:814-822`).
    ///
    /// Null means no filter. The distinction matters for an image build that
    /// has copied only Project.toml + Manifest.toml: the project itself has no
    /// source yet, so an unfiltered run counts it `source_missing` — a FAILURE
    /// — while `only = <the direct deps>` precompiles the same closure Pkg's
    /// `Pkg.precompile(collect(keys(deps)))` does, without the project node.
    only: ?[]const []const u8 = null,
    /// The resolved `DEPOT_PATH`. Handed to the children verbatim, so entry 0
    /// is where every cache entry lands (`compilecache_dir`,
    /// `loading.jl:3147-3150`) and the rest are searched for existing ones.
    stack: depot_mod.Stack,

    /// The `julia` to run. Null means `<julia_prefix>/bin/julia` when a prefix
    /// is known, else the bare name `julia`, which `std.process.spawn` resolves
    /// through the parent's `PATH`.
    ///
    /// It matters which one: `compilecache_path` mixes `JLOptions().julia_bin`
    /// and the sysimage path into the cache filename (`loading.jl:3160-3162`),
    /// so two Julias produce two different, non-interchangeable entries.
    julia_exe: ?[]const u8 = null,
    /// `dirname(Sys.BINDIR)`, used to locate `julia` and passed through to
    /// `verify` for its stdlib cross-check.
    julia_prefix: ?[]const u8 = null,
    /// e.g. "1.12.6". Only used by `verify` and to report `compiled/v<x>.<y>`;
    /// the child is authoritative about its own version. Defaults to the
    /// manifest's `julia_version`.
    julia_version: ?[]const u8 = null,

    /// The parent environment the children inherit. Cloned, then
    /// `JULIA_DEPOT_PATH` and `JULIA_LOAD_PATH` are overwritten. Null hands the
    /// children an environment containing only those two, which is almost
    /// certainly not what a caller wants — `PATH` and `HOME` are gone — so
    /// supply it.
    environ: ?*const std.process.Environ.Map = null,

    /// Base URL of the shared precompile cache, or null for none.
    ///
    /// **Null is the default and means "behave exactly as Pkg does": compile
    /// locally, talk to nothing.** There is no public Ajt cache to point at, so
    /// a built-in default would be a URL that 404s on every lookup — slower
    /// than no cache and harder to explain. What there IS instead is one
    /// environment variable, `AJT_CACHE_URL`, in the shape `JULIA_PKG_SERVER`
    /// already established: a deployment that has a store sets it once in the
    /// image, and nobody types a flag.
    cache_url: ?[]const u8 = null,
    /// Bearer credential for the store's WRITE path. Null means read-only,
    /// which is the right default: a developer pulls, a deploy publishes.
    cache_token: ?[]const u8 = null,
    /// `Pkg.OFFLINE_MODE[]` (`Pkg/src/Pkg.jl:45`). Turns the shared store OFF
    /// for this run; local compilation is unaffected, which is the whole of
    /// what `Pkg.precompile()` does anyway.
    ///
    /// It disables the store rather than letting its requests be refused one
    /// by one, and that choice is the reason this is a field and not something
    /// read off a transport config: the store is a pure accelerator with no
    /// Pkg counterpart, so the honest offline answer is "do not use it", not
    /// two hundred logged refusals with the same cause.
    offline: bool = false,

    /// Probe and report; compile nothing.
    ///
    /// This is not a no-op process-wise: the probe child still runs, because
    /// "what would be compiled" is a question only Julia can answer. That child
    /// loads no package and writes nothing.
    dry_run: bool = false,
    /// How many `julia` children may compile at once. Null detects it from the
    /// machine (and from the cgroup quota, so a 2-CPU container does not fork
    /// 20 children). 1 forces the serial walk.
    jobs: ?u32 = null,
};

// ---------------------------------------------------------------------------
// Auto-precompile: should this run at all?
// ---------------------------------------------------------------------------
//
// `Pkg.add`, `Pkg.up`, `Pkg.pin`, `Pkg.free`, `Pkg.build` and `Pkg.instantiate`
// all end by precompiling the environment they just changed, through
// `Pkg._auto_precompile` (`Pkg.jl:896-900`) — which does nothing unless
// `should_autoprecompile()` says yes:
//
//     should_autoprecompile() = Base.JLOptions().use_compiled_modules == 1 &&
//         Base.get_bool_env("JULIA_PKG_PRECOMPILE_AUTO", true)   -- Pkg.jl:65
//
// The first conjunct has no honest port. `JLOptions().use_compiled_modules` is
// `julia --compiled-modules=no` on the RUNNING process, and Ajt is not that
// process: the flag belongs to whichever `julia` a user might later start, and
// asking the child would answer for a `julia` Ajt itself invoked with no such
// flag. So it is not approximated — it is recorded as an explicit entry in
// `Ajt.jl`'s `DIFFERENCES`, and only the environment variable is read here.
// Consequence, stated so nobody has to discover it: a Julia started with
// `--compiled-modules=no` gets no auto-precompile from Pkg and DOES get one
// from Ajt.

/// The three answers `Base.parse_bool_env` can give (`base/env.jl:150-160`).
/// It is a tri-state, not a bool, and that matters — see `getBoolEnv`.
pub const BoolEnv = enum { truthy, falsy, unrecognized };

/// `Base.parse_bool_env` (`base/env.jl:150-160`), against the two tuples at
/// `base/env.jl:117-127`.
///
/// **The sets include the Capitalized and UPPERCASE spellings**, which is the
/// trap: `src/git/git.zig`'s `boolEnv` matches only the lowercase five, so it
/// answers `false` for `JULIA_PKG_USE_CLI_GIT=TRUE` where Julia answers true.
/// A narrower set here would make `JULIA_PKG_PRECOMPILE_AUTO=NO` mean "on" and
/// precompile in an environment that asked not to be precompiled.
pub fn parseBoolEnv(val: []const u8) BoolEnv {
    const truthy = [_][]const u8{
        "t",    "T",
        "true", "True",
        "TRUE", "y",
        "Y",    "yes",
        "Yes",  "YES",
        "1",
    };
    const falsy = [_][]const u8{
        "f",     "F",
        "false", "False",
        "FALSE", "n",
        "N",     "no",
        "No",    "NO",
        "0",
    };
    for (truthy) |t| {
        if (std.mem.eql(u8, val, t)) return .truthy;
    }
    for (falsy) |f| {
        if (std.mem.eql(u8, val, f)) return .falsy;
    }
    return .unrecognized;
}

/// `Base.get_bool_env(name, default)` (`base/env.jl:142-151`).
///
/// Two things about it that a signature does not show:
///
///   * **An EMPTY value is not false, it is the default.** `get_bool_env`
///     tests `haskey(ENV, name) && !isempty(val)` before it parses, so
///     `JULIA_PKG_PRECOMPILE_AUTO=""` precompiles. `boolEnv("")` would say no.
///   * **An unrecognised value is neither.** Julia returns `nothing`, and
///     `should_autoprecompile()` then evaluates `true && nothing` to `nothing`,
///     which `_auto_precompile`'s `if` raises a `TypeError` on — i.e. Pkg
///     CRASHES on `JULIA_PKG_PRECOMPILE_AUTO=off`, after the install has
///     already happened. Ajt cannot honestly reproduce a crash at that point:
///     the manifest is written and the packages are on disk, and throwing away
///     the Report over a typo in an environment variable would be worse than
///     either answer. It takes the default, which is what Julia does for every
///     other shape of "I did not understand this".
pub fn getBoolEnv(
    environ: ?*const std.process.Environ.Map,
    name: []const u8,
    default: bool,
) bool {
    const map = environ orelse return default;
    const val = map.get(name) orelse return default;
    if (val.len == 0) return default;
    return switch (parseBoolEnv(val)) {
        .truthy => true,
        .falsy => false,
        .unrecognized => default,
    };
}

/// `JULIA_PKG_PRECOMPILE_AUTO`, the half of `Pkg.should_autoprecompile()`
/// (`Pkg.jl:65`) that a separate process can answer. Defaults to ON, as Pkg's
/// does — the documented way to turn it off is `ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0`
/// (`Pkg.jl:206`).
pub fn autoEnabled(environ: ?*const std.process.Environ.Map) bool {
    return getBoolEnv(environ, "JULIA_PKG_PRECOMPILE_AUTO", true);
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

/// What happened to one package in the closure.
pub const Outcome = enum {
    /// This run built the cache entry.
    compiled,
    /// The shared store had it, and this run wrote it into the depot instead
    /// of compiling. Distinct from `compiled` because the two cost wildly
    /// different amounts and a report that conflated them would hide the whole
    /// point of having a cache.
    imported,
    /// `Base.isprecompiled` was already true, so no child was spawned. The
    /// steady state, and what makes a second `ajt precompile` free.
    already_precompiled,
    /// Another process held the pidlock; we blocked on it and it produced the
    /// entry. Not a failure and not a no-op — it is the contended path working.
    waited,
    /// `Base.in_sysimage` — Pkg never compiles these (`precompilation.jl:624`).
    in_sysimage,
    /// `__precompile__(false)` in the source (`precompilation.jl:1024-1027`),
    /// or `Base.compilecache` returned a `PrecompilableError`, which is the
    /// same declaration detected by Julia itself.
    not_precompilable,
    /// The cache is stale and the source is on disk: this is what a compile
    /// pass consumes. It is the FINAL outcome only under `dry_run`, where it is
    /// the plan; seeing it after a real run means the compile pass skipped a
    /// package it was handed, which is a bug and is reported as one.
    stale,
    /// `Base.locate_package` found no source — the environment is not
    /// instantiated. A FAILURE, not a skip: Pkg puts it straight into
    /// `failed_deps` (`precompilation.jl:1017-1021`) and `Pkg.precompile()`
    /// ultimately raises on a non-empty `failed_deps`. Reported per package
    /// rather than raised, so the other 200 still get their caches.
    source_missing,
    /// In, or downstream of, a dependency cycle. Pkg skips these before
    /// starting (`precompilation.jl:762-800`).
    circular,
    /// The child exited non-zero, or could not be spawned at all. `detail` has
    /// the tail of its stderr.
    failed,
    /// The probe could not answer for this package. Nothing was attempted.
    unknown,
};

pub const Result = struct {
    name: []const u8,
    uuid: Uuid,
    outcome: Outcome = .unknown,
    /// Wall time of the child, in milliseconds. Zero for anything that did not
    /// spawn one — which is every outcome except `compiled`, `waited` and
    /// `failed`.
    ms: f64 = 0,
    /// Exit status when a child ran and exited normally.
    exit_code: ?u8 = null,
    /// Name of the parent package when this is an extension, empty otherwise.
    ///
    /// Display only, and it has to be display only: the compile child builds a
    /// `Base.PkgId` from `name`, which must stay the bare extension name. Two
    /// parents can declare extensions with the SAME name — `Accessors` and
    /// `FieldViews` both have a `StaticArraysExt` in the engine's own
    /// environment — so a report that prints `name` alone shows two identical
    /// rows for two different compiles. Pkg renders `parent → Ext` for exactly
    /// this reason (`full_name`, `precompilation.jl:416-418`).
    ext_parent: []const u8 = "",
    /// `Base.locate_package`'s answer: the file the child compiles. Set for
    /// every package the probe could locate, so `--dry-run` can print the plan
    /// and a failure can say which file was being compiled.
    ///
    /// Deliberately its own field rather than a second use of `detail`: those
    /// two are read on the same code paths, and one function forgetting to
    /// clear the other turns a source path into an error message.
    source: []const u8 = "",
    /// Tail of the child's stderr, kept only when something went wrong.
    detail: []const u8 = "",

    /// Did this package end where Pkg would have left it?
    ///
    /// `stale` is judged by the Report, which knows whether this was a dry run;
    /// on its own it is neither good nor bad.
    pub fn ok(self: Result) bool {
        return switch (self.outcome) {
            .failed, .unknown, .source_missing, .stale => false,
            else => true,
        };
    }
};

pub const Report = struct {
    /// How many children were allowed to run at once. 1 means the serial walk
    /// -- either asked for, or forced by a cycle the frontier refuses.
    width: u32 = 1,
    project_file: []const u8 = "",
    manifest_file: []const u8 = "",
    /// The `julia` that was (or would have been) invoked.
    julia: []const u8 = "",
    /// `JULIA_DEPOT_PATH` handed to the children.
    depot_path: []const u8 = "",
    /// `<depots1>/compiled/v<major>.<minor>`, where the entries land. Empty
    /// when no Julia version could be determined, which costs only the report
    /// line — the child computes the real path itself.
    compiled_dir: []const u8 = "",
    /// Shared-cache addresses, indexed exactly as `packages` is. Empty when the
    /// probe never answered; an entry is empty for a node that has no key
    /// (every extension, and anything in the sysimage).
    keys: []const KeyRecord = &.{},
    /// Why no key could be computed, when that is the reason `keys` is empty.
    /// A key is an optimisation, so this never stops a run — but silence about
    /// a cache that is quietly doing nothing is exactly how a 10x lever goes
    /// unnoticed for a month.
    key_error: ?[]const u8 = null,
    /// What the shared cache did this run. Null when none was configured.
    cache_stats: ?CacheStats = null,
    /// What the probe found out about the Julia doing the compiling.
    ///
    /// Reported because these three decide whether one machine's cache entries
    /// mean anything on another, and because `JULIA_CPU_TARGET` in particular
    /// is a silent-staleness trap: a depot built at `native` and loaded by a
    /// Julia that inherited a different default produces cache misses with no
    /// error anywhere. Printing it makes a mismatch visible in a log rather
    /// than only in a wall-clock number.
    params: ?JuliaParams = null,

    /// Entries in the manifest.
    entries: usize = 0,
    /// Nodes reachable from the project's deps, plus every loadable extension —
    /// the set Pkg considers, before the sysimage filter. One `Result` per
    /// node, so this counts packages AND extensions; `extensions` says how
    /// many of it are the latter.
    considered: usize = 0,
    /// Extension nodes in the walk. Counted separately from `considered`'s
    /// packages because "173 packages" and "173 packages and 17 extensions"
    /// are different runs, and because an environment where this is zero and
    /// `extensions_dormant` is not says something specific: the manifest
    /// declares extensions and none of them can load.
    extensions: usize = 0,
    /// Declared extensions left out because a trigger is not in the closure.
    /// Pkg leaves these alone too — they are not a gap.
    extensions_dormant: usize = 0,

    /// In the order they were visited, which is a topological order of the
    /// closure.
    packages: []const Result = &.{},

    /// The probe child failed as a whole; nothing was compiled. Recorded rather
    /// than raised, so the caller still gets the located paths and the plan.
    probe_error: ?[]const u8 = null,
    /// Set when the run stopped before doing anything, because no amount of
    /// compiling fixes it: an unreadable project, an unparseable manifest, or a
    /// workspace root.
    blocked: ?verify.Problem = null,

    dry_run: bool = false,

    /// Did every package that was looked at end in a state Pkg would also have
    /// reached?
    ///
    /// `circular` and `not_precompilable` count as fine: Pkg skips both and
    /// reports success. `source_missing` does NOT — see its doc comment.
    ///
    /// Extensions are the one gap this deliberately does not fail on: they were
    /// never made nodes, so no `Result` carries them, and `extensions_skipped`
    /// is the number that says how much was left undone. A documented gap that
    /// the CLI shouts about on stderr is more useful than an exit code that
    /// makes every environment with an extension look broken.
    pub fn ok(self: Report) bool {
        if (self.blocked != null) return false;
        if (self.probe_error != null) return false;
        for (self.packages) |p| {
            // Under `--dry-run` a stale package is the ANSWER, not a failure:
            // nothing was compiled because nothing was meant to be.
            if (self.dry_run and p.outcome == .stale) continue;
            if (!p.ok()) return false;
        }
        return true;
    }

    pub fn countOf(self: Report, outcome: Outcome) usize {
        var n: usize = 0;
        for (self.packages) |p| {
            if (p.outcome == outcome) n += 1;
        }
        return n;
    }

    /// Packages this run (or a process it waited on) actually built.
    pub fn compiledCount(self: Report) usize {
        return self.countOf(.compiled) + self.countOf(.waited);
    }

    pub fn failedCount(self: Report) usize {
        return self.countOf(.failed) + self.countOf(.unknown) + self.countOf(.source_missing);
    }
};

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

/// Precompile `opts.env_path` into `opts.stack`.
///
/// Per-package failures never abort: one package whose `__init__` throws must
/// not stop the other 213, and the Report is worth more than the first error.
/// What DOES propagate is the machine going wrong — out of memory,
/// cancellation, an environment whose files cannot be read at all.
///
/// The error set is inferred: this fans out into `verify`, the two models and
/// `std.process`, whose sets have nothing in common, and spelling their union
/// here would be a list that goes stale rather than a contract anyone reads.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, opts: Options) !Report {
    var rep: Report = .{ .dry_run = opts.dry_run };

    // ---- 0. where are we? --------------------------------------------------
    //
    // `verify` owns the `Types.projectfile_path`/`manifestfile_path` probe
    // order, including the version-specific `Manifest-v1.12.toml` names. A
    // second copy of that probe here is a second chance to read a file nobody
    // loads.
    const before = try verify.run(arena, gpa, io, .{
        .env_path = opts.env_path,
        .manifest_file = opts.manifest_file,
        .stack = opts.stack,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    });
    rep.project_file = before.project_file;
    rep.manifest_file = before.manifest_file;

    if (blocking(before)) |p| {
        rep.blocked = p;
        return rep;
    }

    // A missing or half-installed package is deliberately NOT blocking. It
    // surfaces per package as `source_missing` from the probe, which is what
    // Pkg does (`precompilation.jl:1017-1021`) and which leaves the other
    // packages compilable.

    const project_src = try Io.Dir.cwd().readFileAlloc(io, rep.project_file, arena, .limited(max_project_bytes));
    var pdiag: project_mod.Diagnostic = .{};
    const project = project_mod.parse(arena, project_src, .{ .file = rep.project_file }, &pdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        rep.blocked = .{
            .kind = .project_invalid,
            .subject = rep.project_file,
            .detail = try arena.dupe(u8, pdiag.message()),
        };
        return rep;
    };

    const manifest_src = try Io.Dir.cwd().readFileAlloc(io, rep.manifest_file, arena, .limited(max_manifest_bytes));
    var mdiag: manifest_mod.Diagnostic = .{};
    const manifest = manifest_mod.parse(arena, manifest_src, &mdiag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        rep.blocked = .{
            .kind = .manifest_invalid,
            .subject = rep.manifest_file,
            .detail = try std.fmt.allocPrint(arena, "line {d}, column {d}: {s}", .{
                mdiag.line, mdiag.column, mdiag.message,
            }),
        };
        return rep;
    };
    rep.entries = manifest.entries.len;

    // ---- 1. the graph, and the order it has to be walked in ----------------
    const graph = try buildGraph(arena, project, manifest);
    const keep = if (opts.only) |names| try keepOf(arena, graph, names) else null;
    const order = try topoOrder(arena, graph, keep);
    rep.considered = order.nodes.len;
    // Counted from the ORDER, not the graph: with `only` set, extension nodes
    // outside the kept set are dropped from the run, and the `extensions`
    // report line must count what this run walks, not what the graph holds.
    // Without a filter the two are equal (every extension node is a root, so
    // every one is in the order).
    rep.extensions = blk: {
        var n: usize = 0;
        for (order.nodes) |i| {
            if (graph.nodes[i].ext != null) n += 1;
        }
        break :blk n;
    };
    rep.extensions_dormant = graph.extensions_dormant;

    // ---- 2. where the children write, and with what --------------------
    const julia_version = opts.julia_version orelse blk: {
        const v = manifest.julia_version orelse break :blk null;
        break :blk try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    };
    rep.julia = opts.julia_exe orelse try defaultJulia(arena, io, opts.julia_prefix);
    rep.depot_path = try std.mem.join(arena, &.{fspath.delimiter}, opts.stack.entries);
    rep.compiled_dir = try compiledDir(arena, opts.stack, julia_version);

    const results = try arena.alloc(Result, order.nodes.len);
    for (results, order.nodes) |*r, n| {
        r.* = .{ .name = graph.nodes[n].name, .uuid = graph.nodes[n].uuid };
        if (graph.nodes[n].ext) |x| r.ext_parent = graph.nodes[x.parent].name;
        if (graph.nodes[n].circular) r.outcome = .circular;
    }
    rep.packages = results;
    if (results.len == 0) return rep;

    if (opts.stack.entries.len == 0) {
        // `JULIA_DEPOT_PATH=""` is a real configuration and Julia raises rather
        // than picking a depot; there is nowhere for a cache entry to go.
        rep.probe_error = "NoDepot";
        return rep;
    }

    var environ = try childEnviron(gpa, opts, rep.depot_path);
    defer environ.deinit();

    // ---- 3. one probe process for the whole environment --------------------
    //
    // Three facts per package that only Julia can supply: is it in the
    // sysimage, where is its source, and is its cache already current. Asking
    // once rather than per package is what keeps a warm run at ONE child
    // process instead of 214 — and a warm run is the common one, since this is
    // what a container entrypoint calls on every boot.
    probe(gpa, arena, io, rep.julia, rep.project_file, &environ, graph, order, results, &rep.params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            rep.probe_error = @errorName(err);
            return rep;
        },
    };

    // ---- 3b. the derivation keys ------------------------------------------
    //
    // Only when something will read them: a configured store, or `--dry-run`,
    // which is exactly when someone is asking what a cache entry WOULD be
    // addressed by. Not free — a key hashes the sysimage, and this Julia's is
    // 312 MB, which is under a second in a release build and half a minute in
    // a debug one. A run with no cache configured should not pay it at all.
    if (rep.params) |p| if (opts.cache_url != null or opts.dry_run) {
        rep.keys = computeKeys(gpa, arena, io, opts, manifest, p, order, graph, results) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A key is an optimisation. Failing to build one must never stop a
            // compile that would otherwise succeed, so the reason is reported
            // and the run continues without a cache.
            else => blk: {
                rep.key_error = @errorName(err);
                break :blk &.{};
            },
        };
    };

    if (opts.dry_run) return rep;

    // ---- 4. compile ---------------------------------------------------------
    //
    // The ORDER is the correctness argument: a package's dependencies must
    // already have caches when its child runs, because `create_expr_cache`
    // starts a Julia that loads them (`loading.jl:3062-3110`). Pkg gets that
    // from `wait(was_processed[dep])` (`precompilation.jl:1031`).
    //
    // A topological walk gets it for free and is what this did at first, but it
    // also serialises 214 `julia -e` invocations that mostly do not depend on
    // each other. The frontier keeps the same guarantee -- `Compile(p)` still
    // sits behind `Ready(d)` for every dependency `d` -- and runs the
    // independent ones at once, bounded by the CPU class and the memory bucket
    // rather than by the shape of the manifest.
    const width = opts.jobs orelse resources.widths(resources.detect(io, .{}), .{}).cpu;
    rep.width = @max(width, 1);

    // The store, when one is configured and there is anything addressable to
    // ask it about. Sized to the `net_cachestore` permit — no more clients can
    // be in flight than that lets through.
    var cache: ?Cache = null;
    defer if (cache) |*c| c.deinit();
    if (if (opts.offline) null else opts.cache_url) |url| {
        if (rep.keys.len == results.len) {
            const net_width = resources.widths(resources.detect(io, .{}), .{}).net_cachestore;
            cache = Cache.init(gpa, io, url, net_width, opts.cache_token) catch |err| blk: {
                rep.key_error = @errorName(err);
                break :blk null;
            };
        }
    }

    if (rep.width > 1 and try compileFrontier(gpa, arena, io, .{
        .julia = rep.julia,
        .project_file = rep.project_file,
        .environ = &environ,
        .width = rep.width,
        .cache = if (cache) |*c| c else null,
        .stack = opts.stack,
        .params = rep.params,
    }, graph, order, results, rep.keys)) {
        if (cache) |*c| rep.cache_stats = .{
            .hits = c.hits,
            .misses = c.misses,
            .imported = c.imported,
            .published = c.published,
            .errors = c.errors,
        };
        return rep;
    }

    // Serial fallback: one worker was asked for, or the graph has a cycle in it
    // and `sched.graph.build` refuses those rather than silently skipping.
    rep.width = 1;
    const loadable = try loadableExts(arena, graph, order, results);
    for (results, order.nodes, 0..) |*r, n, i| {
        // `stale` is the only state the compile pass owns. Everything else the
        // probe already decided, and re-deciding it here would be a second
        // opinion about a question Julia has already answered.
        if (r.outcome != .stale) continue;
        compileOne(gpa, arena, io, .{
            .julia = rep.julia,
            .project_file = rep.project_file,
            .environ = &environ,
            .name = r.name,
            .uuid = r.uuid,
            .source = r.source,
            .is_ext = graph.nodes[n].ext != null,
            .loadable_exts = loadable[i].uuids,
            .loadable_ext_names = loadable[i].names,
        }, r) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // A child that could not even be spawned is this package's
            // failure, not the run's: `julia` may have been replaced under us,
            // the fork may have hit RLIMIT_NPROC. The other packages still get
            // their turn.
            else => {
                r.outcome = .failed;
                r.detail = try arena.dupe(u8, @errorName(err));
            },
        };
    }

    return rep;
}

// ---------------------------------------------------------------------------
// The frontier
// ---------------------------------------------------------------------------

const FrontierRequest = struct {
    julia: []const u8,
    project_file: []const u8,
    environ: *const std.process.Environ.Map,
    width: u32,
    /// What the probe learned about the running Julia; `verify_cache` compares
    /// the imported header's flags against it.
    params: ?JuliaParams = null,
    /// Null when no store is configured, which is the default and collapses
    /// every package to `cacheable = false` — no Probe, no Import, no Publish.
    cache: ?*Cache = null,
    /// Every depot, so an imported entry can be checked against the same
    /// search path Julia will use.
    stack: depot_mod.Stack = .{ .entries = &.{} },
};

/// The shared store, plus the clients that talk to it.
///
/// **One HTTP client per worker, behind a mutex.** `std.http.Client`'s
/// connection pool is not shared across threads — `ops/install_packages.zig`
/// reached the same conclusion and solved it the same way — and
/// `sched/exec.zig` hands an action no worker index, so a small pool with a
/// free-list is what turns "this thread needs a client" into an answer. The
/// pool is sized to the `net_cachestore` permit, which is the only thing that
/// can be in a store call at once anyway.
const Cache = struct {
    gpa: Allocator,
    io: Io,
    clients: []net_http.Client,
    stores: []store_mod.Store,
    /// `false` = this client is free.
    busy: []bool,
    mutex: Io.Mutex = .init,
    /// Diagnostics, all under `mutex`.
    hits: usize = 0,
    misses: usize = 0,
    imported: usize = 0,
    published: usize = 0,
    errors: usize = 0,

    fn init(gpa: Allocator, io: Io, base_url: []const u8, n: usize, token: ?[]const u8) !Cache {
        const width = @max(n, 1);
        const clients = try gpa.alloc(net_http.Client, width);
        errdefer gpa.free(clients);
        const stores = try gpa.alloc(store_mod.Store, width);
        errdefer gpa.free(stores);
        const busy = try gpa.alloc(bool, width);
        errdefer gpa.free(busy);
        @memset(busy, false);
        for (clients, stores) |*c, *s| {
            c.* = net_http.Client.init(gpa, io, .{});
            s.* = .{ .client = c, .base_url = base_url, .write_token = token };
        }
        return .{ .gpa = gpa, .io = io, .clients = clients, .stores = stores, .busy = busy };
    }

    fn deinit(self: *Cache) void {
        for (self.clients) |*c| c.deinit();
        self.gpa.free(self.clients);
        self.gpa.free(self.stores);
        self.gpa.free(self.busy);
    }

    /// Blocks until one is free. The `net_cachestore` permit already bounds
    /// how many callers can be here, so "blocks" is a formality — but it is a
    /// formality that keeps the invariant true even if that permit ever grows
    /// past the pool.
    fn acquire(self: *Cache, io: Io) usize {
        while (true) {
            self.mutex.lockUncancelable(io);
            for (self.busy, 0..) |*b, i| {
                if (!b.*) {
                    b.* = true;
                    self.mutex.unlock(io);
                    return i;
                }
            }
            self.mutex.unlock(io);
            io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        }
    }

    fn release(self: *Cache, io: Io, i: usize) void {
        self.mutex.lockUncancelable(io);
        self.busy[i] = false;
        self.mutex.unlock(io);
    }

    fn note(self: *Cache, io: Io, comptime field: []const u8) void {
        self.mutex.lockUncancelable(io);
        @field(self, field) += 1;
        self.mutex.unlock(io);
    }
};

/// Compile through `sched/exec.zig` instead of walking `order`.
///
/// Returns false when the graph cannot be scheduled -- a manifest with a
/// dependency cycle, which `sched.graph.build` REFUSES rather than skipping
/// past. The caller falls back to the serial walk, which tolerates it because
/// `topoOrder` has already marked those packages `.circular` and the loop skips
/// anything that is not `.stale`.
fn compileFrontier(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    req: FrontierRequest,
    g: Graph,
    order: Order,
    results: []Result,
    keys: []const KeyRecord,
) !bool {
    // `results[i]` is `order.nodes[i]`; the scheduler indexes packages by `i`,
    // so dependencies have to be translated out of graph-node space.
    const slot = try gpa.alloc(u32, g.nodes.len);
    defer gpa.free(slot);
    @memset(slot, std.math.maxInt(u32));
    for (order.nodes, 0..) |n, i| slot[n] = @intCast(i);

    var frontier_arena: std.heap.ArenaAllocator = .init(gpa);
    defer frontier_arena.deinit();
    const fa = frontier_arena.allocator();

    // The one graph rule that could not be applied when the graph was built:
    // a package waits for every extension it could load. See `extensionEdges`.
    const ext_edges = try extensionEdges(fa, g, order, results, slot);

    const packages = try fa.alloc(sched_graph.Package, results.len);
    for (results, order.nodes, 0..) |*r, n, i| {
        if (r.outcome == .circular) return false;
        var deps: std.ArrayList(u32) = .empty;
        for (g.nodes[n].deps) |d| {
            const at = slot[d];
            // A dependency outside the walked set cannot be waited on and does
            // not need to be: the probe already decided it needs nothing.
            if (at == std.math.maxInt(u32) or at == i) continue;
            try deps.append(fa, at);
        }
        for (ext_edges[i]) |at| {
            if (at == i) continue;
            if (std.mem.indexOfScalar(u32, deps.items, at) != null) continue;
            try deps.append(fa, at);
        }
        packages[i] = .{
            .name = r.name,
            .uuid = r.uuid,
            // The source is on disk already -- this op never downloads -- so
            // there is no Fetch/Verify/Install. What the store adds on top is
            // Probe/Import/VerifyCache and Publish, and only for a package that
            // HAS an address: an extension or a checkout has no key, so there
            // is nothing to ask the store for and nothing it could be given.
            .installed = true,
            .deps = deps.items,
            .precompile = r.outcome == .stale,
            .cacheable = req.cache != null and keys.len == results.len and keys[i].hex.len != 0,
        };
    }

    var built = sched_graph.build(fa, .{ .packages = packages }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Cyclic, self-dependent or malformed: refuse to schedule it and let
        // the serial walk deal with the manifest it was given.
        else => return false,
    };

    // Rank by the critical path, so the package the most others are waiting on
    // starts first. Cost is uniform here -- a measured cost model is what
    // `<depot>/ajt/costs.toml` is for, and feeding it in is a later change.
    const succ = try fa.alloc([]const u32, built.nodes.len);
    for (succ, 0..) |*sl, n| {
        const out = built.outEdges(@intCast(n));
        const to = try fa.alloc(u32, out.len);
        for (out, to) |ei, *dst| dst.* = built.edges[ei].to;
        sl.* = to;
    }
    const cost = try fa.alloc(u64, built.nodes.len);
    @memset(cost, sched_rank.default_cost_ms);
    const ranking = sched_rank.compute(gpa, fa, succ, cost) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };

    // **Ask the store before starting a compiler.**
    //
    // `Ready` is an `any` over `VerifyCache` and `Compile`, so both arms are
    // admitted at once and, on a wide machine, both RUN. The graph cancels the
    // compile the moment `VerifyCache` succeeds — but a cancelled compile that
    // already started has still cost a `julia` process and most of a second,
    // which is the entire saving the cache exists to make. `sched/exec.zig`'s
    // own test says as much in its comment: which alternative wins is a
    // PRIORITY question, not an accident of node numbering.
    //
    // So the three cache stages are moved into a band ahead of everything
    // else, preserving their order within it. The cost is one store round trip
    // before the first compile of each package; the saving is the compile. On
    // a miss that round trip is milliseconds against seconds, and on a store
    // that is down it is bounded by the retry policy and counted as an error
    // rather than retried forever.
    const position = try fa.alloc(u32, built.nodes.len);
    const band: u32 = @intCast(built.nodes.len + 1);
    for (position, ranking.position, 0..) |*p, base, n| {
        p.* = switch (built.nodes[n].stage) {
            .probe, .import, .verify_cache => base,
            else => base +| band,
        };
    }

    const is_ext = try fa.alloc(bool, results.len);
    for (order.nodes, 0..) |n, i| is_ext[i] = g.nodes[n].ext != null;

    var ctx: FrontierCtx = .{
        .gpa = gpa,
        .arena = arena,
        .req = req,
        .results = results,
        .loadable = try loadableExts(fa, g, order, results),
        .is_ext = is_ext,
        .keys = keys,
        .found = try fa.alloc(?store_mod.Pointer, results.len),
        .arm = try fa.alloc(ArmState, results.len),
    };
    @memset(ctx.found, null);
    // A package the store will never be asked about must not make a compile
    // wait: only a cacheable one starts `pending`.
    for (ctx.arm, packages) |*a, pkg| a.* = if (pkg.cacheable) .pending else .lost;
    // The machine's own widths, with `cpu` pinned to what the caller asked
    // for. The memory bucket matters more than the CPU count here: `--jobs 20`
    // on a 4 GB box would otherwise fork 20 Julias and get the run OOM-killed,
    // and `acquireCompile` reserves before it takes a CPU precisely so the
    // bucket is what decides.
    var pool_widths = resources.widths(resources.detect(io, .{}), .{});
    pool_widths.cpu = req.width;
    var pool: resources.Pool = .init(pool_widths);

    _ = sched_exec.run(gpa, io, &built, position, &pool, .{
        .ctx = &ctx,
        .run = FrontierCtx.act,
    }, .{ .workers = req.width }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}

/// Rule 4 of the extension graph: **a package waits for every extension it
/// could load** (`precompilation.jl:698-716`).
///
/// It is separated from the other three (`addExtensionNodes`) for one reason:
/// it is the only one that needs `Base.in_sysimage`, and nothing knows that
/// until the probe has run. Julia never puts a sysimage package in
/// `direct_deps` at all (`:623`), so both the extension's own trigger list and
/// the candidate's dependency closure are filtered here before they are
/// compared — an unfiltered comparison asks whether a package depends on
/// `LinearAlgebra`, which is not the question.
///
/// The last clause is the one worth spelling out: an edge is added only when
/// the extension is loadable in the package and in NONE of that package's
/// dependencies. Without it every package downstream of a trigger would wait
/// on the extension, which is a correct order and a much worse one.
///
/// Returns, per `order` position, the slots to add as dependencies. It cannot
/// introduce a cycle into an acyclic graph: an edge `p -> ext` requires `p` to
/// depend on every trigger, and `ext` depends only on triggers, so a cycle
/// through it would need one among the packages already.
fn extensionEdges(
    arena: Allocator,
    g: Graph,
    order: Order,
    results: []const Result,
    slot: []const u32,
) Allocator.Error![]const []const u32 {
    const n = order.nodes.len;
    const none = std.math.maxInt(u32);
    const out = try arena.alloc([]const u32, n);
    @memset(out, &.{});
    if (g.extension_count == 0) return out;

    const is_ext = try arena.alloc(bool, n);
    const is_sys = try arena.alloc(bool, n);
    for (order.nodes, 0..) |node, i| {
        is_ext[i] = g.nodes[node].ext != null;
        is_sys[i] = results[i].outcome == .in_sysimage;
    }

    // `direct_deps`, sysimage-filtered, in slot space.
    const direct = try arena.alloc([]const u32, n);
    for (order.nodes, 0..) |node, i| {
        var list: std.ArrayList(u32) = .empty;
        for (g.nodes[node].deps) |d| {
            const at = slot[d];
            if (at == none or at == i or is_sys[at]) continue;
            if (std.mem.indexOfScalar(u32, list.items, at) != null) continue;
            try list.append(arena, at);
        }
        direct[i] = list.items;
    }

    // `indirect_deps` (`:673-696`): the transitive closure of `direct`. A
    // dense bitset because it is asked about O(exts x packages) times and the
    // whole thing is 200 x 200 bits.
    const words = (n + 63) / 64;
    const reach = try arena.alloc(u64, n * words);
    @memset(reach, 0);
    // `order` is topological with DEPENDENCIES FIRST, so a node's deps all sit
    // at lower indices and one FORWARD pass closes everything: by the time `i`
    // is reached, every `reach[d]` it unions in is already complete. Walking
    // this backwards instead gives each node its direct deps and nothing
    // transitive, which is a subtler wrong answer than an empty one — the
    // shallow extensions still get their edges and the deep ones silently do
    // not.
    for (0..n) |i| {
        const row = reach[i * words ..][0..words];
        for (direct[i]) |d| {
            row[d / 64] |= @as(u64, 1) << @intCast(d % 64);
            const drow = reach[d * words ..][0..words];
            for (row, drow) |*w, dw| w.* |= dw;
        }
    }

    var adds = try arena.alloc(std.ArrayList(u32), n);
    @memset(adds, .empty);
    for (0..n) |e| {
        if (!is_ext[e]) continue;
        const loadable = try arena.alloc(bool, n);
        @memset(loadable, false);
        for (0..n) |p| {
            if (is_ext[p] or is_sys[p]) continue;
            if (std.mem.indexOfScalar(u32, direct[e], @intCast(p)) != null) continue; // is_trigger
            const row = reach[p * words ..][0..words];
            var has_all = true;
            for (direct[e]) |t| {
                if (row[t / 64] & (@as(u64, 1) << @intCast(t % 64)) == 0) {
                    has_all = false;
                    break;
                }
            }
            loadable[p] = has_all;
        }
        for (0..n) |p| {
            if (!loadable[p]) continue;
            var shadowed = false;
            for (direct[p]) |d| {
                if (loadable[d]) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) try adds[p].append(arena, @intCast(e));
        }
    }
    for (out, adds) |*o, a| o.* = a.items;
    return out;
}

const FrontierCtx = struct {
    gpa: Allocator,
    /// Shared, so every write into it is under `mutex`. An ArenaAllocator is
    /// not thread-safe and `compileOne` allocates freely, which is why each
    /// compile gets a scratch arena of its own and only the surviving strings
    /// are copied across.
    arena: Allocator,
    req: FrontierRequest,
    results: []Result,
    /// Per `order` position, indexed exactly as `results` is. Read-only during
    /// the run, so it needs no lock.
    loadable: []const LoadableExts,
    is_ext: []const bool,
    /// Per `order` position. Empty when no keys were computed.
    keys: []const KeyRecord,
    /// The pointer `Probe` found, per `order` position. Written by Probe and
    /// read by Import, both under `mutex`.
    found: []?store_mod.Pointer,
    /// Whether the import arm is still in play, per `order` position.
    ///
    /// `Ready` is an `any`, so the graph admits `Compile` and the cache arm
    /// together and cancels whichever loses. On a wide machine both are
    /// dispatched in the same instant and the compile is already running when
    /// the cancel arrives — the graph is satisfied, and a `julia` has still
    /// been forked, which is the whole cost the cache was meant to avoid.
    /// Priority alone cannot fix that: with twenty workers and ten admitted
    /// packages there is a free worker for every node, and `sched/exec.zig`'s
    /// own test pins this behaviour with ONE worker for exactly that reason.
    ///
    /// So the compile action waits for this to leave `pending`. The wait is a
    /// store round trip — milliseconds against the seconds a compile costs —
    /// and it is bounded by the store's own retry policy, after which the arm
    /// resolves `lost` and the compile proceeds. A package with no key starts
    /// `lost`, so nothing waits on a store it was never going to ask.
    arm: []ArmState,
    mutex: Io.Mutex = .init,

    fn act(raw: *anyopaque, io: Io, g: *const sched_graph.Graph, node: sched_graph.NodeId) bool {
        const self: *FrontierCtx = @ptrCast(@alignCast(raw));
        const nd = g.nodes[node];
        const i = switch (nd.subject) {
            .package => |p| p,
            // Resolve has no subject; artifacts are not scheduled by this op.
            else => return true,
        };
        switch (nd.stage) {
            .compile => {},
            .probe => return self.probeStore(io, i),
            .import => return self.importEntry(io, i),
            .verify_cache => return self.verifyImported(io, i),
            .publish => return self.publishEntry(io, i),
            // Ready is bookkeeping.
            else => return true,
        }
        // The import arm gets to answer first. See `FrontierCtx.arm`.
        if (self.awaitArm(io, i) == .won) return true;
        const r = &self.results[i];

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        var local = r.*;
        compileOne(self.gpa, scratch.allocator(), io, .{
            .julia = self.req.julia,
            .project_file = self.req.project_file,
            .environ = self.req.environ,
            .name = r.name,
            .uuid = r.uuid,
            .source = r.source,
            .is_ext = self.is_ext[i],
            .loadable_exts = self.loadable[i].uuids,
            .loadable_ext_names = self.loadable[i].names,
        }, &local) catch |err| {
            local.outcome = .failed;
            local.detail = @errorName(err);
        };

        // `detail` points into the scratch arena; copy it before that dies.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        r.outcome = local.outcome;
        r.ms = local.ms;
        r.exit_code = local.exit_code;
        r.detail = self.arena.dupe(u8, local.detail) catch "";
        return local.outcome != .failed;
    }

    /// `Probe`: is this package's derivation key in the store?
    ///
    /// **A miss returns FALSE, and that is not a bug.** `sched/graph.zig`
    /// models `Ready` as an `any` node over `VerifyCache` and `Compile`, so a
    /// failing Probe fails only the import ARM: `Import` and `VerifyCache` are
    /// skipped, `Compile` still runs, `Ready` still succeeds (the graph's own
    /// test, "any: a cache miss falls through to Compile"). Returning true on a
    /// miss would let `Import` run with nothing to import.
    fn probeStore(self: *FrontierCtx, io: Io, i: usize) bool {
        const cache = self.req.cache orelse {
            self.settleArm(io, i, .lost);
            return false;
        };
        const key = self.keyOf(i) orelse {
            self.settleArm(io, i, .lost);
            return false;
        };

        const slot = cache.acquire(io);
        defer cache.release(io, slot);

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        const got = cache.stores[slot].getPointer(self.gpa, scratch.allocator(), key.hex) catch {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };
        const p = got.pointer orelse {
            // A 404 is the normal case on a cold machine and is counted, not
            // logged; anything else is the store misbehaving.
            if (got.failure == null) cache.note(io, "misses") else cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };

        self.mutex.lockUncancelable(io);
        self.found[i] = .{
            .schema = p.schema,
            .object = p.object,
            .size = p.size,
            .build_ms = p.build_ms,
            .name = self.arena.dupe(u8, p.name) catch "",
        };
        self.mutex.unlock(io);
        cache.note(io, "hits");
        return true;
    }

    /// `Import`: fetch the object the probe found and put its files where
    /// Julia will look for them.
    ///
    /// The `.ji` is written VERBATIM. Nothing inside it needs rewriting for
    /// this machine: `@depot` tags are resolved by Julia at load time
    /// (`parse_cache_header`, `loading.jl:3500-3576`), and no project path,
    /// `julia_bin` or `image_file` is stored in the file at all — that is the
    /// whole argument in `cache/slug.zig` for why a shared cache can work.
    /// What changes is the NAME: the entry lands at the slug computed from
    /// this machine's own `JLOptions()`, which `KeyRecord.path` already holds.
    fn importEntry(self: *FrontierCtx, io: Io, i: usize) bool {
        const cache = self.req.cache orelse return false;
        const key = self.keyOf(i) orelse return false;
        if (key.path.len == 0) {
            self.settleArm(io, i, .lost);
            return false;
        }

        self.mutex.lockUncancelable(io);
        const pointer = self.found[i];
        self.mutex.unlock(io);
        const p = pointer orelse {
            self.settleArm(io, i, .lost);
            return false;
        };

        const slot = cache.acquire(io);
        defer cache.release(io, slot);

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // Staged inside the depot rather than in /tmp, so the final move is a
        // rename on one filesystem and can be atomic.
        const staging = fspath.join(sa, &.{ fspath.dirname(key.path) orelse ".", ".ajt-import", key.hex }) catch {
            self.settleArm(io, i, .lost);
            return false;
        };
        defer Io.Dir.cwd().deleteTree(io, staging) catch {};

        const got = cache.stores[slot].fetchObject(self.gpa, sa, io, p.object, staging) catch {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };
        if (!got.object.ok()) {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        }

        // The two files an entry is made of. The `.so` is optional: an entry
        // built with `--pkgimages=no` has none, and `stale_cachefile` only
        // demands one when the flags say to (`missing_ocachefile`).
        const ji_src = fspath.join(sa, &.{ staging, object_ji_name }) catch {
            self.settleArm(io, i, .lost);
            return false;
        };
        const so_src = fspath.join(sa, &.{ staging, object_so_name }) catch {
            self.settleArm(io, i, .lost);
            return false;
        };
        const so_dst = cache_slug.objectPath(sa, key.path, cache_slug.host_dlext) catch {
            self.settleArm(io, i, .lost);
            return false;
        };

        makeParent(io, key.path);
        moveFile(io, ji_src, key.path) catch {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };
        // A missing `.so` is fine; a present one that will not move is not,
        // because a `.ji` without its object file is the `missing_ocachefile`
        // rejection and costs a recompile that looks like a mystery.
        moveFile(io, so_src, so_dst) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                cache.note(io, "errors");
                self.settleArm(io, i, .lost);
                return false;
            },
        };

        cache.note(io, "imported");
        return true;
    }

    /// `VerifyCache`: read the header of what was just imported before anything
    /// depends on it.
    ///
    /// Level-1 verification, and its value is entirely in WHEN it fails. Julia
    /// would reject a bad entry too — `stale_cachefile` re-checks every
    /// dependency build_id and every include — but it would do so at load time,
    /// after the whole environment had been imported and a user was waiting.
    /// Parsing the header costs a millisecond and turns that into a miss, which
    /// the scheduler already knows how to handle: this returning false skips
    /// nothing but the import arm, and `Compile` runs.
    fn verifyImported(self: *FrontierCtx, io: Io, i: usize) bool {
        const cache = self.req.cache orelse return false;
        const key = self.keyOf(i) orelse return false;
        if (key.path.len == 0) {
            self.settleArm(io, i, .lost);
            return false;
        }

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const bytes = Io.Dir.cwd().readFileAlloc(io, key.path, sa, .limited(max_ji_bytes)) catch {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };
        var hdr = jicache.parse(sa, bytes) catch {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        };
        // The flags the loading process will demand. A mismatch here is the
        // `mismatched_flags` rejection, and it is worth catching now because it
        // means the store served an entry built for a different configuration
        // — which the derivation key was supposed to prevent, so it is also a
        // signal that something upstream is wrong.
        const params = self.req.params orelse {
            self.settleArm(io, i, .won);
            return true;
        };
        if (!jicache.matchCacheFlags(params.cacheflags, hdr.flags)) {
            cache.note(io, "errors");
            self.settleArm(io, i, .lost);
            return false;
        }
        // `@depot` tags resolve against THIS machine's depots, which is the
        // check that a cross-machine entry actually landed somewhere usable.
        jicache.restoreDepots(sa, io, &hdr, self.req.stack.entries) catch {
            self.settleArm(io, i, .lost);
            return false;
        };

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.arm[i] = .won;
        self.results[i].outcome = .imported;
        return true;
    }

    /// `Publish`: hand the entry this run just built to the store.
    ///
    /// Best-effort by construction. `Publish` is a leaf — nothing waits on it —
    /// so returning false records the failure and costs nothing else. A machine
    /// with no write credential simply fails every publish, which is the
    /// intended read-only configuration and not an error worth shouting about.
    ///
    /// `putObject` BEFORE `putPointer`, always: the pointer names the object by
    /// hash, so publishing it first would advertise bytes nobody can fetch and
    /// every reader would take an import failure instead of a clean miss.
    fn publishEntry(self: *FrontierCtx, io: Io, i: usize) bool {
        const cache = self.req.cache orelse return false;
        const key = self.keyOf(i) orelse return false;
        if (key.path.len == 0) return false;

        // Only what this run actually built. Republishing an entry that came
        // from the store would be a no-op at best (the object is
        // content-addressed) and a re-upload of hundreds of megabytes at worst.
        self.mutex.lockUncancelable(io);
        const outcome = self.results[i].outcome;
        const built_ms = self.results[i].ms;
        const name = self.results[i].name;
        self.mutex.unlock(io);
        if (outcome != .compiled) return false;

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const ji = Io.Dir.cwd().readFileAlloc(io, key.path, sa, .limited(max_ji_bytes)) catch return false;

        // Refuse to publish what another machine could not load. An entry whose
        // includes are absolute paths, or are tracked by mtime rather than by
        // content, is only meaningful where it was built (`publishRefusal`).
        var hdr = jicache.parse(sa, ji) catch return false;
        if (jicache.publishRefusal(&hdr) != null) return false;

        const so_path = cache_slug.objectPath(sa, key.path, cache_slug.host_dlext) catch return false;
        const so: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, so_path, sa, .limited(max_ji_bytes)) catch null;

        const tar = buildObject(sa, ji, so) catch return false;
        // Zig 0.16's std has a zstd DEcompressor and no compressor, so this is
        // a valid but uncompressed frame. A deployment that wants the 300 MB ->
        // 80-110 MB win pipes through `zstd -19`; everything downstream is
        // identical either way. See `store.rawFrame`.
        const framed = store_mod.rawFrame(self.gpa, tar) catch return false;
        defer self.gpa.free(framed);

        const slot = cache.acquire(io);
        defer cache.release(io, slot);

        const put = cache.stores[slot].putObject(sa, framed) catch {
            cache.note(io, "errors");
            return false;
        };
        if (!put.ok()) {
            cache.note(io, "errors");
            return false;
        }
        const ptr = cache.stores[slot].putPointer(sa, key.hex, .{
            .object = put.hash,
            .size = framed.len,
            .build_ms = @intFromFloat(@max(built_ms, 0)),
            .name = name,
        }) catch {
            cache.note(io, "errors");
            return false;
        };
        if (!ptr.ok()) {
            cache.note(io, "errors");
            return false;
        }
        cache.note(io, "published");
        return true;
    }

    /// Block until this package's import arm has won or lost.
    ///
    /// Polling rather than a condition variable because the wait is short by
    /// construction and there is exactly one waiter per package. The cap is a
    /// backstop against a store that accepts a connection and then never
    /// answers: `net/http.zig` bounds its own attempts, so reaching it means
    /// something pathological, and compiling is always a correct fallback.
    fn awaitArm(self: *FrontierCtx, io: Io, i: usize) ArmState {
        var waited_ms: u64 = 0;
        while (waited_ms < arm_wait_cap_ms) {
            self.mutex.lockUncancelable(io);
            const s = self.arm[i];
            self.mutex.unlock(io);
            if (s != .pending) return s;
            io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch return .lost;
            waited_ms += 1;
        }
        return .lost;
    }

    fn settleArm(self: *FrontierCtx, io: Io, i: usize, s: ArmState) void {
        self.mutex.lockUncancelable(io);
        self.arm[i] = s;
        self.mutex.unlock(io);
    }

    fn keyOf(self: *const FrontierCtx, i: usize) ?KeyRecord {
        if (self.keys.len != self.results.len) return null;
        const k = self.keys[i];
        if (k.hex.len == 0) return null;
        return k;
    }
};

/// Whether a package's import arm is still in play. See `FrontierCtx.arm`.
const ArmState = enum { pending, won, lost };

/// How long a compile will wait for the store to answer before giving up and
/// compiling. Generous: the store's own retry policy resolves the arm long
/// before this, so reaching it means a connection that was accepted and then
/// abandoned.
const arm_wait_cap_ms: u64 = 120_000;

/// The two names inside a cache object. Fixed, so the importer never has to
/// guess: the slug they were built under is meaningless on the machine that
/// fetches them, which is the entire reason this indirection exists.
const object_ji_name = "cache.ji";
const object_so_name = "cache.so";

/// A `.ji` is tens of megabytes; the `.so` beside it can be larger.
const max_ji_bytes = 2 * 1024 * 1024 * 1024;

/// The tar an object is: the `.ji`, and the `.so` when there is one.
fn buildObject(arena: Allocator, ji: []const u8, so: ?[]const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var w: std.tar.Writer = .{ .underlying_writer = &aw.writer };
    try w.writeFileBytes(object_ji_name, ji, .{});
    if (so) |bytes| try w.writeFileBytes(object_so_name, bytes, .{});
    try w.finishPedantically();
    return aw.toOwnedSlice();
}

/// `mkdir -p` of a file path's parent, ignoring "already there".
fn makeParent(io: Io, path: []const u8) void {
    const dir = fspath.dirname(path) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch {};
}

/// Rename, falling back to copy+delete across filesystems.
fn moveFile(io: Io, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.rename(from, cwd, to, io) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => {
            try cwd.copyFile(from, cwd, to, io, .{});
            cwd.deleteFile(io, from) catch {};
        },
    };
}

// ---------------------------------------------------------------------------
// Blocking problems
// ---------------------------------------------------------------------------

/// Problems no amount of compiling fixes.
///
/// Deliberately short. `package_missing`, `dev_path_missing` and every hash
/// mismatch are NOT here: they make individual packages `source_missing` or
/// make their compile fail, and refusing to precompile the other 200 over one
/// broken entry is the worse failure for a container entrypoint — the same
/// judgement `instantiate.blocking` makes.
fn blocking(rep: verify.Report) ?verify.Problem {
    for (rep.problems) |p| switch (p.kind) {
        .project_unreadable,
        .project_invalid,
        .workspace_unsupported,
        .manifest_unreadable,
        .manifest_invalid,
        => return p,
        else => {},
    };
    return null;
}

// ---------------------------------------------------------------------------
// The graph
// ---------------------------------------------------------------------------

const Node = struct {
    name: []const u8,
    /// The package's own uuid.
    ///
    /// For an EXTENSION node this is the PARENT's uuid until `probe` overwrites
    /// it with the one Julia minted. It cannot be computed here: `Base.uuid5`
    /// is not RFC 4122 — `loading.jl:147-157` is a bespoke construction over
    /// Julia's internal `hash`, carrying the comment "fake uuid5 function" and
    /// a TODO to delete it. Porting that would pin Ajt to an implementation
    /// detail Julia has said it intends to change, so the probe asks instead.
    uuid: Uuid,
    /// Indices into `Graph.nodes`. Strong deps only — `prune_deps` and
    /// `_collect_reachable!` both walk `entry.deps`, never `weakdeps`, so an
    /// extension trigger is pulled in only when something depends on it
    /// strongly.
    deps: []const usize = &.{},
    /// True once `topoOrder` has decided it is in, or downstream of, a cycle.
    circular: bool = false,
    /// Set on extension nodes only.
    ext: ?Ext = null,
};

/// What makes an extension node different from a package node.
const Ext = struct {
    /// Node index of the package that declares it.
    parent: usize,
    /// `triggers[ext]` (`precompilation.jl:631-641`): the parent first, then
    /// every trigger, as node indices.
    ///
    /// Deliberately NOT filtered by the sysimage, because the rule that reads
    /// it — the ext-to-ext superset test at `:664-668` — compares `triggers`
    /// and not `direct_deps`. The filtered form is a scheduling concern and
    /// lives where the sysimage flags are known, which is after the probe.
    triggers: []const usize,
};

const Graph = struct {
    nodes: []Node,
    /// Node indices that are roots: the project's `[deps]`, plus the project
    /// itself when it is a package (`precompilation.jl:87-91`).
    roots: []const usize,
    /// Extension nodes in `nodes` — the ones Pkg would compile, i.e. those
    /// whose every trigger is in the package closure.
    extension_count: usize,
    /// Declared extensions that are NOT nodes because a trigger is absent from
    /// the closure (`all_triggers_available`, `:643`). Pkg does not compile
    /// these either; the count is reported so "no extensions here" and "17 of
    /// them were dropped" cannot look the same.
    extensions_dormant: usize,
};

/// The nodes and edges of `ExplicitEnv` as `_collect_reachable!` sees them
/// (`precompilation.jl:56-260`), restricted to what this unit walks.
///
/// One node per manifest entry, plus a synthetic node for the project when it
/// is a package whose uuid the manifest does not carry. Julia always has that
/// node (`:197-203` inserts `deps_expanded[proj_uuid]` before the manifest loop
/// can), so an environment whose manifest happens not to mention itself must
/// still precompile itself.
///
/// A dep pointing at a uuid with no entry contributes no edge. Julia would
/// `KeyError` on such a manifest while expanding the compressed `deps` form
/// (`:218`); `manifest.zig`'s `normalizeDeps` has already rejected it for the
/// strong-dep case, so this is reachable only through a hand-written expanded
/// manifest, and dropping the edge is strictly safer than inventing a node.
///
/// Arena: every slice returned belongs to `arena`.
fn buildGraph(
    arena: Allocator,
    project: project_mod.Project,
    manifest: manifest_mod.Manifest,
) Allocator.Error!Graph {
    var by_uuid: std.AutoHashMapUnmanaged([16]u8, usize) = .empty;
    var nodes: std.ArrayList(Node) = .empty;

    for (manifest.entries) |e| {
        const gop = try by_uuid.getOrPut(arena, e.uuid.bytes);
        // A manifest with two entries under one uuid collapses in Julia's
        // `Dict{UUID,PackageEntry}` at read time; the model preserves file
        // order and both survive. Keep the FIRST, which is the one Julia's
        // last-write-wins would have kept had the file been written by Pkg —
        // and, more importantly, keep exactly one, so the package is not
        // compiled twice.
        if (gop.found_existing) continue;
        gop.value_ptr.* = nodes.items.len;
        try nodes.append(arena, .{ .name = e.name, .uuid = e.uuid });
    }

    // The project's own node.
    const project_node: ?usize = blk: {
        const uuid = project.uuid orelse break :blk null;
        // `env.pkg`/`project_is_package` requires BOTH (`precompilation.jl:85`,
        // `Types.jl:400-409`); a nameless project with a uuid is legal and is
        // not a package.
        const name = project.name orelse break :blk null;
        if (by_uuid.get(uuid.bytes)) |i| break :blk i;
        const i = nodes.items.len;
        try by_uuid.put(arena, uuid.bytes, i);
        try nodes.append(arena, .{ .name = name, .uuid = uuid });
        break :blk i;
    };

    // Edges.
    //
    // `filled` rather than "does this node already have deps?": a package with
    // genuinely no dependencies has an empty `deps` slice forever, so an
    // emptiness test cannot tell "not visited yet" from "visited, has none" —
    // and on a duplicate-uuid manifest that difference decides whether the
    // SECOND entry's deps silently overwrite the first entry's none.
    const filled = try arena.alloc(bool, nodes.items.len);
    @memset(filled, false);

    for (manifest.entries) |e| {
        const i = by_uuid.get(e.uuid.bytes).?;
        if (filled[i]) continue; // a second entry under one uuid; keep the first
        filled[i] = true;
        var deps: std.ArrayList(usize) = .empty;
        for (e.deps) |d| {
            const j = by_uuid.get(d.uuid.bytes) orelse continue;
            try deps.append(arena, j);
        }
        nodes.items[i].deps = deps.items;
    }
    if (project_node) |i| {
        // Only when the manifest does not describe the project. When it does —
        // the usual `path = "."` self-entry — Julia's manifest loop at `:205`
        // overwrites the `deps_expanded[proj_uuid]` that `:198` had just set,
        // so the manifest entry wins there too.
        if (!filled[i]) {
            filled[i] = true;
            var deps: std.ArrayList(usize) = .empty;
            for (project.deps.entries.items) |d| {
                const j = by_uuid.get(d.uuid.bytes) orelse continue;
                if (j == i) continue; // `filter!(!=(proj_uuid), ...)` (`:198`)
                try deps.append(arena, j);
            }
            nodes.items[i].deps = deps.items;
        }
    }

    var roots: std.ArrayList(usize) = .empty;
    for (project.deps.entries.items) |d| {
        // `project.deps` already excludes the names that also appear in
        // `[weakdeps]` (the model's `deps_weak`), which is Julia's
        // `delete!(project_deps, name)` at `precompilation.jl:75-78`.
        const j = by_uuid.get(d.uuid.bytes) orelse continue;
        try roots.append(arena, j);
    }
    if (project_node) |i| try roots.append(arena, i);

    var g: Graph = .{
        .nodes = nodes.items,
        .roots = roots.items,
        .extension_count = 0,
        .extensions_dormant = 0,
    };
    try addExtensionNodes(arena, &g, &nodes, &by_uuid, project, project_node, manifest);
    return g;
}

/// The extension nodes, appended to a graph that already has every package.
///
/// Ported from `precompilation.jl:620-668`. Three rules, and the order they
/// run in is the whole of it:
///
///  1. **Only reachable parents, and only fully-triggered extensions.** An
///     extension becomes a node when its parent is in the package closure AND
///     every one of its triggers is too (`all_triggers_available`, `:637-643`).
///     One absent trigger and Julia will never load it, so compiling it would
///     produce a cache entry nothing looks for.
///  2. **`deps = parent ++ triggers`** (`:644`). This is what makes the
///     ordering correct: `create_expr_cache` starts a child that loads the
///     parent and every trigger, so their caches must exist first.
///  3. **An extension depends on another whose trigger set it strictly
///     contains** (`:664-668`). Compared on `triggers`, not on the
///     sysimage-filtered `direct_deps` — see `Ext.triggers`.
///
/// The fourth rule, package-depends-on-extension (`:698-716`), is NOT here: it
/// needs `Base.in_sysimage` per node, which only the probe knows. It is a
/// scheduling edge rather than a correctness one, and it is applied in
/// `compileFrontier` where those flags exist.
///
/// A trigger NAME that resolves to no manifest entry makes the extension
/// dormant rather than raising. Julia would `KeyError` there
/// (`name_to_uuid[trigger]`, `:237`), but only on a manifest no Pkg version
/// writes: the compressed `weakdeps = [...]` form is emitted precisely when
/// every name is an entry, and the expanded table form carries the uuid
/// alongside the name. Refusing to precompile because of a hand-edited
/// manifest would be a worse answer than skipping the one extension.
fn addExtensionNodes(
    arena: Allocator,
    g: *Graph,
    nodes: *std.ArrayList(Node),
    by_uuid: *const std.AutoHashMapUnmanaged([16]u8, usize),
    project: project_mod.Project,
    project_node: ?usize,
    manifest: manifest_mod.Manifest,
) Allocator.Error!void {
    // `_collect_reachable!` (`:616-619`) over the PACKAGE nodes. Extensions are
    // appended after, so they can neither pull a package into the closure nor
    // qualify each other as triggers.
    const reachable = try closureOf(arena, g.nodes, g.roots);
    const package_count = nodes.items.len;

    // `name_to_uuid` (`:120`, `:138`, `:217`). Manifest entries first, then
    // every expanded dep and weakdep table, which is what puts a name like
    // `Vulkan` — a weakdep of the project with no manifest entry of its own —
    // in reach of an extension trigger. Ajt normalises both dep encodings to
    // (name, uuid) pairs, and the compressed form's names are entries anyway,
    // so one pass over the normalised deps reproduces both of Julia's.
    var name_to_uuid: std.StringHashMapUnmanaged(Uuid) = .empty;
    for (manifest.entries) |e| try name_to_uuid.put(arena, e.name, e.uuid);
    for (manifest.entries) |e| {
        for (e.deps) |d| try name_to_uuid.put(arena, d.name, d.uuid);
        for (e.weakdeps) |d| try name_to_uuid.put(arena, d.name, d.uuid);
    }

    // The project's own extensions resolve their triggers against a DIFFERENT
    // map: `project_uuid_to_name` (`:55`, `:60-72`), built from the project's
    // `[deps]`, `[weakdeps]` and `[extras]` — not from the manifest. A trigger
    // that is only a manifest entry is an error there, not a lookup.
    var project_names: std.StringHashMapUnmanaged(Uuid) = .empty;
    for ([_]project_mod.DepMap{ project.deps, project.deps_weak, project.weakdeps, project.extras }) |m| {
        for (m.entries.items) |d| try project_names.put(arena, d.name, d.uuid);
    }

    const Candidate = struct {
        parent: usize,
        name: []const u8,
        /// Trigger names, both manifest encodings already flattened.
        triggers: []const []const u8,
        project_scoped: bool,
    };
    var candidates: std.ArrayList(Candidate) = .empty;
    for (manifest.entries) |e| {
        const parent = by_uuid.get(e.uuid.bytes) orelse continue;
        if (!reachable[parent]) continue;
        for (e.exts) |x| try candidates.append(arena, .{
            .parent = parent,
            .name = x.name,
            .triggers = switch (x.targets) {
                .one => |s| try arena.dupe([]const u8, &.{s}),
                .many => |list| list,
            },
            .project_scoped = false,
        });
    }
    if (project_node) |pn| {
        // Only when the manifest does not already describe the project. With
        // the usual `path = "."` self-entry it does, and the loop above has
        // already taken its extensions from there — which is also the entry
        // Julia's `:205` lets win.
        var described = false;
        for (manifest.entries) |e| {
            if (by_uuid.get(e.uuid.bytes)) |i| {
                if (i == pn) described = true;
            }
        }
        if (!described and reachable[pn]) {
            for (project.exts) |x| try candidates.append(arena, .{
                .parent = pn,
                .name = x.name,
                .triggers = x.triggers,
                .project_scoped = true,
            });
        }
    }

    var triggers_of: std.ArrayList([]const usize) = .empty;
    for (candidates.items) |c| {
        var triggers: std.ArrayList(usize) = .empty;
        try triggers.append(arena, c.parent); // parent is always first (`:633`)
        var available = true;
        for (c.triggers) |tn| {
            const map = if (c.project_scoped) &project_names else &name_to_uuid;
            const tu = map.get(tn) orelse {
                available = false;
                break;
            };
            const ti = by_uuid.get(tu.bytes) orelse {
                available = false;
                break;
            };
            if (!reachable[ti]) {
                available = false;
                break;
            }
            try triggers.append(arena, ti);
        }
        if (!available) {
            g.extensions_dormant += 1;
            continue;
        }
        try nodes.append(arena, .{
            .name = c.name,
            // The parent's, as a placeholder — `probe` replaces it with the id
            // `Base.uuid5` mints. See `Node.uuid`.
            .uuid = nodes.items[c.parent].uuid,
            .deps = triggers.items,
            .ext = .{ .parent = c.parent, .triggers = triggers.items },
        });
        try triggers_of.append(arena, triggers.items);
    }

    // Rule 3: an extension depends on any extension whose trigger set is a
    // STRICT subset of its own (`:664-668`). Quadratic in the extension count,
    // which is what Julia does and is nothing at these sizes.
    for (package_count..nodes.items.len) |a| {
        const ta = triggers_of.items[a - package_count];
        var deps: std.ArrayList(usize) = .empty;
        try deps.appendSlice(arena, nodes.items[a].deps);
        for (package_count..nodes.items.len) |b| {
            if (a == b) continue;
            const tb = triggers_of.items[b - package_count];
            if (strictSuperset(ta, tb)) try deps.append(arena, b);
        }
        nodes.items[a].deps = deps.items;
    }

    // Every extension node is also a ROOT.
    //
    // Not decoration: `topoOrder` walks the closure of `roots`, and nothing in
    // a manifest ever points AT an extension — the edges all run the other way,
    // from the extension to its parent and triggers. Left out of the roots an
    // extension node would sit in the graph and never be visited, which is the
    // same as not having built it. Julia has the same property for the same
    // reason: its walk is over `keys(direct_deps)`, and every extension is a
    // key (`:644`).
    var roots: std.ArrayList(usize) = .empty;
    try roots.appendSlice(arena, g.roots);
    for (package_count..nodes.items.len) |i| try roots.append(arena, i);

    g.nodes = nodes.items;
    g.roots = roots.items;
    g.extension_count = nodes.items.len - package_count;
}

/// `a ⊋ b` over two trigger sets. Both are small (a parent plus one or two
/// triggers) and duplicate-free by construction, so a linear scan beats
/// building sets.
fn strictSuperset(a: []const usize, b: []const usize) bool {
    if (a.len <= b.len) return false;
    for (b) |x| {
        if (std.mem.indexOfScalar(usize, a, x) == null) return false;
    }
    return true;
}

/// The `only` filter (`base/precompilation.jl:786-812`): which nodes a
/// name-restricted run keeps.
///
/// Three steps, in Pkg's order:
///   1. every node whose name is in `names` — packages and extensions alike,
///      because by the time Pkg filters, `direct_deps` holds both and the test
///      is `dep_pkgid.name in pkg_names` (`:787`);
///   2. the transitive dep closure of each match (`collect_all_deps`, `:788`)
///      — for an extension node the `deps` edges already carry the parent,
///      the triggers, and the rule-3 ext-to-ext edges, so `closureOf` IS
///      `collect_all_deps`;
///   3. ONE pass over extension nodes in node order (`:806-811`): an extension
///      whose entire dep closure is already kept is kept too. One pass, not a
///      fixpoint — Pkg iterates `keys(ext_to_parent)` once, so an extension
///      that qualifies only because a LATER one was admitted stays out there
///      as well; node order here makes the same rule deterministic.
fn keepOf(arena: Allocator, graph: Graph, names: []const []const u8) Allocator.Error![]bool {
    var matched: std.ArrayList(usize) = .empty;
    defer matched.deinit(arena);
    for (graph.nodes, 0..) |nd, i| {
        for (names) |want| {
            if (std.mem.eql(u8, nd.name, want)) {
                try matched.append(arena, i);
                break;
            }
        }
    }
    const keep = try closureOf(arena, graph.nodes, matched.items);
    for (graph.nodes, 0..) |nd, i| {
        if (nd.ext == null or keep[i]) continue;
        const cl = try closureOf(arena, graph.nodes, &.{i});
        const admitted = for (cl, 0..) |in_cl, j| {
            if (in_cl and j != i and !keep[j]) break false;
        } else true;
        if (admitted) keep[i] = true;
    }
    return keep;
}

/// `_collect_reachable!` (`precompilation.jl:69-75`): everything reachable from
/// `roots` over `deps`. Iterative, because the input is a file.
fn closureOf(arena: Allocator, nodes: []const Node, roots: []const usize) Allocator.Error![]bool {
    const in_closure = try arena.alloc(bool, nodes.len);
    @memset(in_closure, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(arena);
    for (roots) |r| {
        if (in_closure[r]) continue;
        in_closure[r] = true;
        try stack.append(arena, r);
        while (stack.pop()) |i| {
            for (nodes[i].deps) |j| {
                if (in_closure[j]) continue;
                in_closure[j] = true;
                try stack.append(arena, j);
            }
        }
    }
    return in_closure;
}

const Order = struct {
    /// Node indices, dependencies first. Cyclic nodes come last, in node order,
    /// flagged `circular`.
    nodes: []const usize,
};

/// `_collect_reachable!` (`precompilation.jl:69-75`) followed by a topological
/// sort of what it found.
///
/// Kahn's algorithm over the closure, with dependencies emitted before their
/// dependents. Whatever never reaches in-degree zero is in a cycle or depends
/// on one — precisely the set `scan_pkg!` marks (`precompilation.jl:766-800`),
/// because that function returns true both for a package inside a cycle and for
/// one that transitively depends on a cycle. Pkg skips them all, so they are
/// emitted last and flagged rather than dropped: an environment with a cycle
/// should say so, not silently precompile 12 of 14 packages.
///
/// Ties are broken by node index, which is manifest file order — so the order
/// is deterministic across runs, which matters when the output is diffed.
///
/// Arena: the returned slice belongs to `arena`; `graph.nodes[*].circular` is
/// mutated in place.
fn topoOrder(arena: Allocator, graph: Graph, keep: ?[]const bool) Allocator.Error!Order {
    const n = graph.nodes.len;
    const in_closure = try closureOf(arena, graph.nodes, graph.roots);
    // The `only` filter, as one more mask on the closure. Intersected rather
    // than replacing it: Pkg's keep-filter runs over a map that never held an
    // unreachable entry in the first place (`direct_deps` is built by
    // `_collect_reachable!`), so a kept name that is unreachable from the
    // project must stay out here too.
    if (keep) |k| {
        for (in_closure, k) |*c, kk| c.* = c.* and kk;
    }

    const indegree = try arena.alloc(usize, n);
    @memset(indegree, 0);
    for (0..n) |i| {
        if (!in_closure[i]) continue;
        // One edge per DISTINCT dependency: a manifest that lists the same dep
        // twice would otherwise leave a permanent in-degree and turn a healthy
        // package into a phantom cycle.
        for (graph.nodes[i].deps, 0..) |j, k| {
            if (!in_closure[j]) continue;
            if (std.mem.indexOfScalar(usize, graph.nodes[i].deps[0..k], j) != null) continue;
            indegree[i] += 1;
        }
    }

    var out: std.ArrayList(usize) = .empty;
    var ready: std.ArrayList(usize) = .empty;
    defer ready.deinit(arena);
    for (0..n) |i| {
        if (in_closure[i] and indegree[i] == 0) try ready.append(arena, i);
    }

    var emitted = try arena.alloc(bool, n);
    @memset(emitted, false);
    while (ready.items.len != 0) {
        // Lowest index first, so the order is manifest order among the nodes
        // that are simultaneously ready.
        var pick: usize = 0;
        for (ready.items, 0..) |v, k| {
            if (v < ready.items[pick]) pick = k;
        }
        const i = ready.swapRemove(pick);
        emitted[i] = true;
        try out.append(arena, i);
        for (0..n) |j| {
            if (!in_closure[j] or emitted[j]) continue;
            var seen = false;
            for (graph.nodes[j].deps, 0..) |d, k| {
                if (d != i) continue;
                if (std.mem.indexOfScalar(usize, graph.nodes[j].deps[0..k], d) != null) continue;
                seen = true;
                break;
            }
            if (!seen) continue;
            indegree[j] -= 1;
            if (indegree[j] == 0) try ready.append(arena, j);
        }
    }

    for (0..n) |i| {
        if (!in_closure[i] or emitted[i]) continue;
        graph.nodes[i].circular = true;
        try out.append(arena, i);
    }

    return .{ .nodes = out.items };
}

// ---------------------------------------------------------------------------
// The children
// ---------------------------------------------------------------------------

/// `<prefix>/bin/julia` when it exists, else the bare name for `PATH` lookup.
fn defaultJulia(arena: Allocator, io: Io, prefix: ?[]const u8) Allocator.Error![]const u8 {
    const p = prefix orelse return "julia";
    const exe = try fspath.join(arena, &.{ p, "bin", "julia" });
    Io.Dir.cwd().access(io, exe, .{}) catch return "julia";
    return exe;
}

/// `<depots1>/compiled/v<major>.<minor>` — reported, never written. Empty when
/// there is no depot or no version to key it on.
fn compiledDir(arena: Allocator, stack: depot_mod.Stack, version: ?[]const u8) Allocator.Error![]const u8 {
    const d = stack.writeDepot() orelse return "";
    const v = version orelse return "";
    var it = std.mem.splitScalar(u8, v, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return "", 10) catch return "";
    const minor = std.fmt.parseInt(u32, it.next() orelse return "", 10) catch return "";
    return d.compiledDir(arena, major, minor);
}

/// The environment every child gets. See the module header for why these two
/// variables are set and everything else is inherited; `child.environ` is the
/// mechanism and states the rule for all three callers.
fn childEnviron(
    gpa: Allocator,
    opts: Options,
    depot_path: []const u8,
) Allocator.Error!std.process.Environ.Map {
    return child.environ(gpa, opts.environ, &.{
        .{ .name = "JULIA_DEPOT_PATH", .value = depot_path },
        .{ .name = "JULIA_LOAD_PATH", .value = child_load_path },
    });
}

/// One `julia` that answers, for every node, the three questions this module
/// cannot answer itself. See `probe_source`.
///
/// Writes its answers straight into `results`: an outcome for everything it can
/// decide, and `.stale` plus a `Result.source` for the ones the compile pass
/// has to take. Nothing is left in an in-between state — after this returns,
/// every `Result` carries a verdict a caller can print.
fn probe(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    julia: []const u8,
    project_file: []const u8,
    environ: *const std.process.Environ.Map,
    graph: Graph,
    order: Order,
    results: []Result,
    params: *?JuliaParams,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        julia,
        "--startup-file=no",
        "--history-file=no",
        "--color=no",
        try std.fmt.allocPrint(arena, "--project={s}", .{project_file}),
        "-e",
        probe_source,
        "--",
    });
    for (order.nodes) |i| {
        var buf: [36]u8 = undefined;
        // For an extension the uuid sent is the PARENT's, and the child mints
        // the real one with `Base.uuid5`. See `Node.uuid`.
        try argv.append(gpa, if (graph.nodes[i].ext == null) "pkg" else "ext");
        try argv.append(gpa, try arena.dupe(u8, manifest_mod.formatUuid(graph.nodes[i].uuid, &buf)));
        try argv.append(gpa, graph.nodes[i].name);
    }

    var res = try child.run(gpa, io, .{
        .argv = argv.items,
        .environ = environ,
        .stdout_limit = max_probe_stdout,
        .stderr_limit = max_child_stderr,
    });
    defer res.deinit(gpa);

    switch (res.term) {
        .exited => |code| if (code != 0) return error.ProbeFailed,
        else => return error.ProbeFailed,
    }

    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const kind = f.next() orelse continue;
        // The three inputs a derivation key needs that are properties of this
        // Julia rather than of the environment. Asked once per run, in the
        // process that is already being started, rather than by a second child
        // or by guessing from a path.
        if (std.mem.eql(u8, kind, "params")) {
            params.* = .{
                .image_file = try arena.dupe(u8, f.next() orelse continue),
                .cacheflags = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue,
                .cpu_target = try arena.dupe(u8, f.next() orelse continue),
                .julia_bin = try arena.dupe(u8, f.next() orelse continue),
                // The active project can legitimately be empty (`--project=@`
                // with nothing to find), so `f.rest()` rather than `f.next()`:
                // a trailing empty field is a value, not a missing one.
                .active_project = try arena.dupe(u8, f.rest()),
            };
            continue;
        }
        const is_probe = std.mem.eql(u8, kind, "probe");
        if (!is_probe and !std.mem.eql(u8, kind, "probe-error")) continue;
        const idx = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        if (idx >= results.len) continue;
        const name = f.next() orelse continue;
        // Positional agreement, asserted rather than assumed: a mismatch means
        // this process and the child disagree about which package is which,
        // and every outcome after it would be attributed to the wrong name.
        if (!std.mem.eql(u8, name, results[idx].name)) return error.ProbeMisaligned;
        // A node already ruled out by the SCC scan keeps its verdict: Pkg does
        // not look at a circular package's cache either.
        if (results[idx].outcome == .circular) continue;

        if (!is_probe) {
            results[idx].outcome = .failed;
            results[idx].detail = try arena.dupe(u8, f.rest());
            continue;
        }

        // The uuid the child ended up with. For a package it is the one we
        // sent; for an extension it is what `Base.uuid5` minted, and this is
        // the only place Ajt learns it.
        const uuid_text = f.next() orelse continue;
        results[idx].uuid = Uuid.parse(uuid_text) catch return error.ProbeMisaligned;

        const sys = std.mem.eql(u8, f.next() orelse continue, "1");
        const fresh = std.mem.eql(u8, f.next() orelse continue, "1");
        const nopre = std.mem.eql(u8, f.next() orelse continue, "1");
        const source = f.rest();

        // `-` is the child's "no source", and it is checked before the flags
        // that only make sense once there is a file: a sysimage package is
        // never located at all, and `fresh`/`nopre` are false by construction
        // when `src === nothing`.
        if (sys) {
            results[idx].outcome = .in_sysimage;
        } else if (std.mem.eql(u8, source, "-")) {
            results[idx].outcome = .source_missing;
        } else {
            results[idx].source = try arena.dupe(u8, source);
            results[idx].outcome = if (nopre)
                .not_precompilable
            else if (fresh)
                .already_precompiled
            else
                .stale;
        }
    }

    // Anything the probe never mentioned is still `.unknown`. That is a real
    // failure — the child answered for some packages and not others — and
    // saying so beats handing the compile pass a package with no source path.
    for (results) |*r| {
        if (r.outcome != .unknown) continue;
        r.outcome = .failed;
        r.detail = "the probe returned no answer for this package";
    }
}

/// What the shared store did over one run.
pub const CacheStats = struct {
    /// Keys the store had.
    hits: usize = 0,
    /// Keys it did not — the normal case on a cold machine, and not a failure.
    misses: usize = 0,
    /// Entries actually written into the depot from the store.
    imported: usize = 0,
    /// Entries this run built and handed back.
    published: usize = 0,
    /// Anything that was neither a hit nor a clean miss: a malformed pointer, a
    /// corrupt object, a refused write. Counted separately so "the cache is
    /// off" and "the cache is broken" do not look the same.
    errors: usize = 0,
};

/// A package's shared-cache address, in `order` positions.
pub const KeyRecord = struct {
    /// Hex, as the store's `keys/` namespace spells it.
    hex: []const u8,
    /// Where the entry would land on THIS machine. Empty when the local slug
    /// could not be computed. Deliberately separate from `hex`: one is what
    /// every machine agrees on, the other is what only this one does, and
    /// `cache/slug.zig` exists because they are not the same thing.
    path: []const u8 = "",
};

/// Derivation keys for the walked packages, indexed by position in `order`.
///
/// Three things go in that the manifest does not carry, and all three come
/// from the probe's `params`: the sysimage's CONTENT (not its path — that is
/// the whole point, two machines install Julia at different prefixes), the
/// `CacheFlags` byte, and the effective `JULIA_CPU_TARGET`.
///
/// Extensions get no key. They have no manifest entry, so `cache/key.zig` —
/// which walks the manifest — has nothing to hash for them. They are cheap
/// relative to their parents and they compile locally; sharing them would need
/// a key derivation of their own, which is a later question and not a silent
/// gap: `KeyRecord.hex` is empty for every extension node and the publish path
/// skips what it cannot address.
///
/// No `local` is passed, deliberately. The environment's own package is a
/// checkout and so is every `develop`, and addressing one means tree-hashing
/// its working directory — 7.4 GB for this repo's engine, almost all of it
/// Rust build output, and for an address that embeds the absolute path and so
/// could never hit on another machine anyway. Those entries come back unkeyed
/// (`Keys.unkeyed`), along with anything depending on them, which for the
/// engine is exactly one entry that nothing else depends on.
fn computeKeys(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    manifest: manifest_mod.Manifest,
    params: JuliaParams,
    order: Order,
    graph: Graph,
    results: []const Result,
) ![]const KeyRecord {
    // The sysimage is hashed by CONTENT. It is ~150 MB and read once per run.
    const image = Io.Dir.cwd().readFileAlloc(io, params.image_file, gpa, .limited(max_sysimage_bytes)) catch
        return error.SysimageUnreadable;
    defer gpa.free(image);
    var sysimage: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &sysimage, .{});

    const prefix = opts.julia_prefix orelse return error.NoJuliaPrefix;
    const set = try stdlibs_mod.load(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = opts.julia_version,
    });

    const keys = try cache_key.computeManifest(arena, &manifest, .{
        .params = .{
            .sysimage = sysimage,
            .cacheflags = params.cacheflags,
            .cpu_target = params.cpu_target,
        },
        .stdlibs = &set,
    });

    const out = try arena.alloc(KeyRecord, order.nodes.len);
    @memset(out, .{ .hex = "" });

    // The local path needs a write depot and a Julia version; without either
    // the KEY is still perfectly good — it is the machine-independent half —
    // so this reports keys with empty paths rather than nothing at all.
    const write_depot = opts.stack.writeDepot();
    const jv = majorMinor(opts.julia_version) orelse blk: {
        const v = manifest.julia_version orelse break :blk null;
        break :blk MajorMinor{
            .major = std.math.cast(u32, v.major) orelse break :blk null,
            .minor = std.math.cast(u32, v.minor) orelse break :blk null,
        };
    };

    for (out, order.nodes, results) |*slot, n, r| {
        // An extension has no manifest entry and therefore no key.
        if (graph.nodes[n].ext != null) continue;
        const k = keys.get(r.uuid) orelse continue;
        slot.hex = try arena.dupe(u8, &cache_key.toHex(k));
        const dep = write_depot orelse continue;
        const v = jv orelse continue;
        slot.path = cache_slug.cachePath(arena, dep, v.major, v.minor, .{
            .name = r.name,
            .uuid = r.uuid,
        }, .{
            .project = params.active_project,
            .image_file = params.image_file,
            .julia_bin = params.julia_bin,
            .flags = cache_slug.Flags.fromByte(params.cacheflags),
            .cpu_target = params.cpu_target,
        }) catch "";
    }
    return out;
}

const MajorMinor = struct { major: u32, minor: u32 };

fn majorMinor(version: ?[]const u8) ?MajorMinor {
    const v = version orelse return null;
    var it = std.mem.splitScalar(u8, v, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor };
}

/// The three facts about the running Julia that a derivation key is built on,
/// as the probe reported them.
///
/// All three are properties of the INSTALLATION, not of the environment, and
/// all three change what a cache entry means: a different sysimage, a different
/// `CacheFlags` byte or a different `JULIA_CPU_TARGET` all produce a `.ji` the
/// other machine must not load. `cache/key.zig` mixes them into every key for
/// exactly that reason, so two machines that differ in any of them simply miss
/// each other's entries instead of trading unusable ones.
pub const JuliaParams = struct {
    /// `unsafe_string(JLOptions().image_file)`. The PATH; the key hashes the
    /// file's CONTENTS, which is what makes it comparable across machines that
    /// install Julia at different prefixes.
    image_file: []const u8,
    /// `Base._cacheflag_to_uint8(Base.CacheFlags())`.
    cacheflags: u8,
    /// `JULIA_CPU_TARGET` if set, else `JLOptions().cpu_target`.
    cpu_target: []const u8,
    /// `unsafe_string(JLOptions().julia_bin)`.
    ///
    /// Not part of the derivation key, and deliberately so — it is an absolute
    /// path that differs between any two machines. It is needed for the LOCAL
    /// filename: `precompile_slug` crc32c's it (`loading.jl:3152-3172`), which
    /// is what `cache/slug.zig` means by the slug not being a sharing key.
    julia_bin: []const u8,
    /// `something(Base.active_project(), "")`. Also local-only, and also
    /// hashed into the slug rather than into the key.
    active_project: []const u8,
};

/// `loadable_exts` for every walked node, indexed by position in `order`.
///
/// `haskey(ext_to_parent, pkg) ? filter(is_ext, direct_deps[pkg]) : nothing`
/// (`precompilation.jl:1070`) — so this is populated only for extension nodes,
/// and a package's entry stays empty and is sent as `nothing`.
///
/// Must run AFTER the probe: an extension's uuid is minted by Julia, and until
/// the probe has answered, `Result.uuid` still holds the parent's placeholder.
/// Naming an extension by its parent's uuid here would restrict a compile to a
/// module that does not exist.
fn loadableExts(
    arena: Allocator,
    graph: Graph,
    order: Order,
    results: []const Result,
) Allocator.Error![]const LoadableExts {
    const slot = try arena.alloc(usize, graph.nodes.len);
    @memset(slot, std.math.maxInt(usize));
    for (order.nodes, 0..) |n, i| slot[n] = i;

    const out = try arena.alloc(LoadableExts, order.nodes.len);
    for (out, order.nodes) |*o, n| {
        o.* = .{};
        if (graph.nodes[n].ext == null) continue;
        var uuids: std.ArrayList(Uuid) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (graph.nodes[n].deps) |d| {
            if (graph.nodes[d].ext == null) continue;
            const at = slot[d];
            if (at == std.math.maxInt(usize)) continue;
            try uuids.append(arena, results[at].uuid);
            try names.append(arena, graph.nodes[d].name);
        }
        o.* = .{ .uuids = uuids.items, .names = names.items };
    }
    return out;
}

const LoadableExts = struct {
    uuids: []const Uuid = &.{},
    names: []const []const u8 = &.{},
};

const CompileRequest = struct {
    julia: []const u8,
    project_file: []const u8,
    environ: *const std.process.Environ.Map,
    name: []const u8,
    uuid: Uuid,
    source: []const u8,
    /// `loadable_exts` (`precompilation.jl:1070`), as `<uuid> <name>` pairs.
    ///
    /// Empty for a package, and that is not the same as empty for an
    /// extension: Pkg passes `nothing` for a package, meaning "you may load
    /// any extension", and for an extension passes the subset of its own
    /// direct dependencies that are themselves extensions, meaning "these and
    /// no others". `is_ext` is what tells the child which of the two an empty
    /// list means.
    loadable_exts: []const Uuid = &.{},
    loadable_ext_names: []const []const u8 = &.{},
    is_ext: bool = false,
};

/// One package, one `julia`, under the pidlock. See `compile_source`.
///
/// **No timeout, deliberately.** `std.process.run`'s default `.none` means this
/// blocks for as long as the child does, and the child can legitimately block
/// for a long time: on a big package the compile itself is minutes, and on a
/// contended depot it sits in `mkpidlock` waiting for whoever is already
/// building this entry. `Pkg.precompile()` blocks in exactly the same place
/// (`precompilation.jl:1280-1289`) and Julia's own staleness rules — the lock
/// is stolen after `stale_age` seconds if the holder is gone, `stale_age * 5`
/// if it is alive — are what bounds the wait. A timeout here could only make
/// things worse: killing a child mid-`compilecache` is how a half-written cache
/// entry gets left behind, which is the failure this whole protocol exists to
/// prevent.
fn compileOne(gpa: Allocator, arena: Allocator, io: Io, req: CompileRequest, out: *Result) !void {
    var uuid_buf: [36]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        req.julia,
        "--startup-file=no",
        "--history-file=no",
        "--color=no",
        try std.fmt.allocPrint(arena, "--project={s}", .{req.project_file}),
        "-e",
        compile_source,
        "--",
        manifest_mod.formatUuid(req.uuid, &uuid_buf),
        req.name,
        req.source,
        // ARGS[4]: whether ARGS[5..] is a restriction or an absence.
        if (req.is_ext) "ext" else "pkg",
    });
    for (req.loadable_exts, req.loadable_ext_names) |u, n| {
        var buf: [36]u8 = undefined;
        try argv.append(gpa, try arena.dupe(u8, manifest_mod.formatUuid(u, &buf)));
        try argv.append(gpa, n);
    }

    var res = try child.run(gpa, io, .{
        .argv = argv.items,
        .environ = req.environ,
        .stdout_limit = max_child_stdout,
        .stderr_limit = max_child_stderr,
    });
    defer res.deinit(gpa);
    out.ms = res.ms;

    switch (res.term) {
        .exited => |code| {
            out.exit_code = code;
            if (code != 0) {
                out.outcome = .failed;
                out.detail = try arena.dupe(u8, tail(res.stderr, detail_bytes));
                return;
            }
        },
        // A signal is not an exit status. A package big enough to be OOM-killed
        // (or a compiler that segfaults on it) lands here, and the distinction
        // is worth keeping: the stderr tail is usually empty and the exit code
        // would be a lie.
        else => {
            out.outcome = .failed;
            out.detail = try std.fmt.allocPrint(arena, "child terminated abnormally ({s})", .{
                tail(res.stderr, detail_bytes),
            });
            return;
        },
    }

    out.outcome = parseOutcome(res.stdout) orelse {
        out.outcome = .failed;
        out.detail = try arena.dupe(u8, tail(res.stderr, detail_bytes));
        return;
    };
}

/// The child's single machine-readable line: `outcome\t<word>`.
fn parseOutcome(stdout: []const u8) ?Outcome {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "outcome\t")) continue;
        const word = std.mem.trimEnd(u8, line["outcome\t".len..], "\r");
        if (std.mem.eql(u8, word, "compiled")) return .compiled;
        if (std.mem.eql(u8, word, "already_precompiled")) return .already_precompiled;
        if (std.mem.eql(u8, word, "waited")) return .waited;
        if (std.mem.eql(u8, word, "not_precompilable")) return .not_precompilable;
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The Julia this module runs
// ---------------------------------------------------------------------------

/// The probe. Reads; writes nothing, loads no package.
///
/// One line per package, positionally aligned with the `(uuid, name)` pairs in
/// `ARGS` and carrying the index anyway so the parent can assert the alignment:
///
/// ```text
/// probe\t<idx>\t<name>\t<in_sysimage>\t<fresh>\t<no_precompile>\t<source|->
/// probe-error\t<idx>\t<name>\t<message>
/// ```
///
/// Each package is wrapped in its own `try`, so one unreadable source file
/// costs one package rather than the whole plan — the same rule the Zig side
/// follows.
///
/// `Base.isprecompiled(pkg; ignore_loaded = true)` is Pkg's own staleness test
/// (`precompilation.jl:1036`); `ignore_loaded` matches `precompilepkgs`'
/// default, which is what makes the answer independent of what happens to be
/// loaded in this particular process. The `__precompile__(false)` regex is
/// `precompilation.jl:1025` verbatim, and it is checked BEFORE `isprecompiled`
/// because a package that refuses precompilation has no cache to be fresh.
const probe_source =
    \\println("params\t", unsafe_string(Base.JLOptions().image_file), "\t",
    \\        Base._cacheflag_to_uint8(Base.CacheFlags()), "\t",
    \\        get(ENV, "JULIA_CPU_TARGET", unsafe_string(Base.JLOptions().cpu_target)), "\t",
    \\        unsafe_string(Base.JLOptions().julia_bin), "\t",
    \\        something(Base.active_project(), ""))
    \\for i in 1:3:length(ARGS)
    \\    idx = div(i - 1, 3)
    \\    name = ARGS[i + 2]
    \\    try
    \\        given = Base.UUID(ARGS[i + 1])
    \\        uuid = ARGS[i] == "ext" ? Base.uuid5(given, name) : given
    \\        pkg = Base.PkgId(uuid, name)
    \\        sys = Base.in_sysimage(pkg)
    \\        src = sys ? nothing : Base.locate_package(pkg)
    \\        fresh = false
    \\        nopre = false
    \\        if src !== nothing
    \\            nopre = occursin(r"\b__precompile__\(\s*false\s*\)", read(src, String))
    \\            nopre || (fresh = Base.isprecompiled(pkg; ignore_loaded = true))
    \\        end
    \\        println("probe\t", idx, "\t", name, "\t", uuid, "\t", sys ? 1 : 0, "\t",
    \\                fresh ? 1 : 0, "\t", nopre ? 1 : 0, "\t",
    \\                src === nothing ? "-" : src)
    \\    catch err
    \\        println("probe-error\t", idx, "\t", name, "\t", sprint(showerror, err))
    \\    end
    \\end
;

/// One package, under the pidlock — a port of
/// `precompile_pkgs_maybe_cachefile_lock` (`precompilation.jl:1253-1293`) with
/// the semaphore and the terminal display removed, because this process
/// compiles exactly one package and holds no limiter.
///
/// `ARGS` is `<uuid> <name> <sourcepath> <pkg|ext> [<ext-uuid> <ext-name>]...`;
/// the one machine-readable line on stdout is
/// `outcome\t<compiled|already_precompiled|waited|not_precompilable>`.
///
/// The fourth argument decides what `loadable_exts` is, and the distinction is
/// Pkg's (`precompilation.jl:1068-1072`): `nothing` for a package — "any
/// extension may load during this compile, every trigger is accounted for" —
/// and a LIST for an extension, holding the extensions among its own direct
/// dependencies. An empty list is therefore meaningful: an extension with no
/// extension dependencies may load none. Passing `nothing` there instead would
/// be quietly more permissive than Pkg and could bake a different cache.
/// Everything the compile itself prints goes to stderr, so stdout stays
/// parseable — Pkg funnels both into one pipe (`precompilation.jl:1043-1044`)
/// because it renders them; here they must be separable.
///
/// `using FileWatching` is what installs `Base.mkpidlock_hook`,
/// `Base.trymkpidlock_hook` and `Base.parse_pidfile_hook`
/// (`FileWatching.jl:1004-1006`); the guard below mirrors
/// `precompilation.jl:1255-1257`, which falls through to an unlocked compile
/// when they are absent rather than refusing to work.
///
/// `Base.compilecache(pkg, src, stderr, stderr, false; cacheflags)` — the fifth
/// positional is `keep_loaded_modules`, and `false` is what Pkg passes
/// (`keep_loaded_modules = !ignore_loaded`, `precompilation.jl:1067`).
const compile_source =
    \\using FileWatching
    \\pkg = Base.PkgId(Base.UUID(ARGS[1]), ARGS[2])
    \\src = ARGS[3]
    \\loadable_exts = ARGS[4] == "ext" ? Base.PkgId[] : nothing
    \\if loadable_exts !== nothing
    \\    for i in 5:2:length(ARGS)
    \\        push!(loadable_exts, Base.PkgId(Base.UUID(ARGS[i]), ARGS[i + 1]))
    \\    end
    \\end
    \\cacheflags = Base.CacheFlags()
    \\stale_age = Base.compilecache_pidlock_stale_age
    \\pidfile = Base.compilecache_pidfile_path(pkg; flags = cacheflags)
    \\work = function ()
    \\    Base.isprecompiled(pkg; ignore_loaded = true, flags = cacheflags) && return "already_precompiled"
    \\    ret = Base.compilecache(pkg, src, stderr, stderr, false; cacheflags, loadable_exts)
    \\    return ret isa Base.PrecompilableError ? "not_precompilable" : "compiled"
    \\end
    \\if !(isdefined(Base, :mkpidlock_hook) && isdefined(Base, :trymkpidlock_hook) &&
    \\     isdefined(Base, :parse_pidfile_hook))
    \\    println("outcome\t", work())
    \\    exit(0)
    \\end
    \\r = @invokelatest Base.trymkpidlock_hook(work, pidfile; stale_age = stale_age)
    \\if r === false
    \\    pid, host, age = @invokelatest Base.parse_pidfile_hook(pidfile)
    \\    println(stderr, "ajt precompile: ", ARGS[2], " is being precompiled by pid ", pid,
    \\            isempty(host) ? "" : string(" on ", host), "; waiting on ", pidfile)
    \\    flush(stderr)
    \\    r = @invokelatest Base.mkpidlock_hook(work, pidfile; stale_age = stale_age)
    \\    r = r == "already_precompiled" ? "waited" : r
    \\end
    \\println("outcome\t", r)
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The graph half is pure and is tested here; the child-process half is tested
// differentially against `Pkg.precompile()` by tools/diff_harness/precompile.sh,
// which is the only place a claim about `compiled/` can honestly be made.

const testing = std.testing;

const TestEnv = struct {
    arena_state: std.heap.ArenaAllocator,
    project: project_mod.Project,
    manifest: manifest_mod.Manifest,

    fn init(project_src: []const u8, manifest_src: []const u8) !TestEnv {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const a = arena_state.allocator();
        var pdiag: project_mod.Diagnostic = .{};
        const p = try project_mod.parse(a, project_src, .{}, &pdiag);
        var mdiag: manifest_mod.Diagnostic = .{};
        const m = try manifest_mod.parse(a, manifest_src, &mdiag);
        return .{ .arena_state = arena_state, .project = p, .manifest = m };
    }

    fn deinit(self: *TestEnv) void {
        self.arena_state.deinit();
    }

    fn names(self: *TestEnv, allocator: Allocator) ![]const []const u8 {
        return self.namesOnly(allocator, null);
    }

    /// `names`, through the `only` filter — the graph walk `Options.only`
    /// produces, without a probe or a child Julia.
    fn namesOnly(self: *TestEnv, allocator: Allocator, only: ?[]const []const u8) ![]const []const u8 {
        const g = try buildGraph(allocator, self.project, self.manifest);
        const keep = if (only) |o| try keepOf(allocator, g, o) else null;
        const o = try topoOrder(allocator, g, keep);
        const out = try allocator.alloc([]const u8, o.nodes.len);
        for (o.nodes, out) |i, *slot| slot.* = g.nodes[i].name;
        return out;
    }
};

fn expectOrder(actual: []const []const u8, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "closure and order: dependencies come before dependents" {
    // The fixture the differential harness uses, with the UUIDs Julia's General
    // registry actually carries. Order verified against Pkg.precompile()'s own
    // output on this environment: Unicode, Preferences, PrecompileTools, Parsers
    // are the four it compiles.
    var env = try TestEnv.init(
        \\name = "AjtPrecompileFixture"
        \\uuid = "1a2b3c4d-0000-4000-8000-000000000001"
        \\
        \\[deps]
        \\Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
        \\
    ,
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Parsers]]
        \\deps = ["Dates", "PrecompileTools"]
        \\uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
        \\version = "2.8.6"
        \\
        \\[[deps.PrecompileTools]]
        \\deps = ["Preferences"]
        \\uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
        \\version = "1.3.4"
        \\
        \\[[deps.Preferences]]
        \\deps = ["TOML"]
        \\uuid = "21216c6a-2e73-6563-6e65-726566657250"
        \\version = "1.5.2"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\version = "1.11.0"
        \\
        \\[[deps.TOML]]
        \\deps = ["Dates"]
        \\uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
        \\version = "1.0.3"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try env.names(arena_state.allocator());

    // Dates before TOML before Preferences before PrecompileTools before
    // Parsers; the project itself last, because it depends on Parsers.
    try expectOrder(got, &.{
        "Dates",
        "TOML",
        "Preferences",
        "PrecompileTools",
        "Parsers",
        "AjtPrecompileFixture",
    });
}

test "only: a name keeps its dep closure and drops everything else" {
    // `Pkg.precompile(["PrecompileTools"])` on the fixture environment:
    // Preferences and TOML and Dates ride along as `collect_all_deps`
    // (`precompilation.jl:788`), Parsers and the PROJECT are dropped by the
    // `filter!` (`:811`). The project dropping out is the case the flag exists
    // for -- an image build with no src/ yet names the direct deps and the
    // project stops counting as source_missing.
    var env = try TestEnv.init(
        \\name = "AjtPrecompileFixture"
        \\uuid = "1a2b3c4d-0000-4000-8000-000000000001"
        \\
        \\[deps]
        \\Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
        \\
    ,
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Parsers]]
        \\deps = ["Dates", "PrecompileTools"]
        \\uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
        \\version = "2.8.6"
        \\
        \\[[deps.PrecompileTools]]
        \\deps = ["Preferences"]
        \\uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
        \\version = "1.3.4"
        \\
        \\[[deps.Preferences]]
        \\deps = ["TOML"]
        \\uuid = "21216c6a-2e73-6563-6e65-726566657250"
        \\version = "1.5.2"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\version = "1.11.0"
        \\
        \\[[deps.TOML]]
        \\deps = ["Dates"]
        \\uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
        \\version = "1.0.3"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try expectOrder(
        try env.namesOnly(a, &.{"PrecompileTools"}),
        &.{ "Dates", "TOML", "Preferences", "PrecompileTools" },
    );
    // A name matching nothing contributes nothing, silently (`:814-822`).
    try expectOrder(try env.namesOnly(a, &.{"NoSuchPackage"}), &.{});
    // And the unfiltered walk is untouched by the machinery existing.
    try expectOrder(
        try env.names(a),
        &.{ "Dates", "TOML", "Preferences", "PrecompileTools", "Parsers", "AjtPrecompileFixture" },
    );
}

test "only: an unreachable manifest entry stays out even when named" {
    // Pkg's filter runs over `direct_deps`, which `_collect_reachable!` built
    // -- an orphan entry was never in the map, so asking for it by name keeps
    // nothing. The keep mask INTERSECTS the closure rather than replacing it.
    var env = try TestEnv.init(
        \\[deps]
        \\Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\version = "1.11.0"
        \\
        \\[[deps.Orphan]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectOrder(try env.namesOnly(arena_state.allocator(), &.{"Orphan"}), &.{});
}

test "only: extensions of the kept set come along uninvited" {
    // `Pkg.precompile(["B"])` where A extends on trigger B: the extension's
    // dep closure is {A, B}, so keeping B alone is NOT enough (A stays out and
    // the ext with it), while keeping A pulls B in as a dep and the extension
    // qualifies under `issubset(collect_all_deps(ext), keep)`
    // (`precompilation.jl:806-811`) without being named.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    LiveExt = "B"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try expectOrder(try env.namesOnly(a, &.{"A"}), &.{ "B", "A", "LiveExt" });
    try expectOrder(try env.namesOnly(a, &.{"B"}), &.{"B"});
    // Naming the extension itself keeps it AND its closure (`:787` matches
    // extension PkgIds too -- their names are in `direct_deps` by then).
    try expectOrder(try env.namesOnly(a, &.{"LiveExt"}), &.{ "B", "A", "LiveExt" });
}

test "the project is a root only when it has BOTH a name and a uuid" {
    // `project_is_package = proj_name !== nothing && proj_uuid !== nothing`
    // (precompilation.jl:85). A uuid alone must not make a node.
    var env = try TestEnv.init(
        \\uuid = "1a2b3c4d-0000-4000-8000-000000000001"
        \\
        \\[deps]
        \\Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\version = "1.11.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectOrder(try env.names(arena_state.allocator()), &.{"Dates"});
}

test "unreachable manifest entries are not considered" {
    // `_collect_reachable!` walks from the project's deps only, so a manifest
    // entry nothing depends on is invisible -- the same reason instantiate does
    // not install the nine pruned Open-Reality entries.
    var env = try TestEnv.init(
        \\[deps]
        \\Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\version = "1.11.0"
        \\
        \\[[deps.Orphan]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectOrder(try env.names(arena_state.allocator()), &.{"Dates"});
}

test "weak dependencies are not edges" {
    // `_collect_reachable!` walks env.deps, never weakdeps -- which is why the
    // Vulkan family is neither installed nor precompiled for Open-Reality.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\weakdeps = ["W"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.W]]
        \\uuid = "dddddddd-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectOrder(try env.names(arena_state.allocator()), &.{"A"});
}

// ---------------------------------------------------------------------------
// Extensions
//
// The absolute values these assert -- which extensions the engine's own
// environment yields, and the uuid each one gets -- are not asserted here.
// They cannot be: the uuid comes from `Base.uuid5`, which is a Julia function
// and not a portable one. `tools/diff_harness/precompile.sh` compares the
// whole set against Julia; what these tests own is the RULE, exercised on
// shapes a real manifest rarely has all at once.
// ---------------------------------------------------------------------------

/// The extension nodes of a graph, as `parent → name`, in node order.
fn extNames(arena: Allocator, g: Graph) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (g.nodes) |nd| {
        const x = nd.ext orelse continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s} → {s}", .{
            g.nodes[x.parent].name, nd.name,
        }));
    }
    return out.items;
}

test "an extension becomes a node only when every trigger is in the closure" {
    // A declares two extensions: one triggered by B (which the project depends
    // on) and one by W (a weakdep, so not in the closure). Pkg builds a node
    // for the first and leaves the second dormant -- `all_triggers_available`
    // at precompilation.jl:637-643.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\weakdeps = ["W"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    LiveExt = "B"
        \\    DormantExt = "W"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.W]]
        \\uuid = "dddddddd-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);

    try testing.expectEqual(@as(usize, 1), g.extension_count);
    try testing.expectEqual(@as(usize, 1), g.extensions_dormant);
    try expectOrder(try extNames(a, g), &.{"A → LiveExt"});

    // And it is WALKED. An extension node nothing points at is invisible to
    // the closure unless it is also a root, which is the bug this catches.
    const o = try topoOrder(a, g, null);
    var found = false;
    for (o.nodes) |i| {
        if (g.nodes[i].ext != null) found = true;
    }
    try testing.expect(found);
}

test "an extension is ordered after its parent and every trigger" {
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    AExt = "B"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);
    const o = try topoOrder(a, g, null);

    var pos_a: ?usize = null;
    var pos_b: ?usize = null;
    var pos_ext: ?usize = null;
    for (o.nodes, 0..) |n, i| {
        if (g.nodes[n].ext != null) pos_ext = i;
        if (g.nodes[n].ext == null and std.mem.eql(u8, g.nodes[n].name, "A")) pos_a = i;
        if (g.nodes[n].ext == null and std.mem.eql(u8, g.nodes[n].name, "B")) pos_b = i;
    }
    // The correctness argument, not a preference: `create_expr_cache` starts a
    // child that loads the parent and the trigger, so both caches must exist.
    try testing.expect(pos_a.? < pos_ext.?);
    try testing.expect(pos_b.? < pos_ext.?);
}

test "the parent is first in the trigger list, as Julia records it" {
    // `triggers[ext] = Base.PkgId[pkg]` before any trigger is pushed
    // (`:633`). The superset rule compares these sets, so a missing parent
    // would silently change which extensions depend on which.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    AExt = "B"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);

    for (g.nodes) |nd| {
        const x = nd.ext orelse continue;
        try testing.expectEqual(x.parent, x.triggers[0]);
        try testing.expectEqualStrings("A", g.nodes[x.triggers[0]].name);
        try testing.expectEqual(@as(usize, 2), x.triggers.len);
    }
}

test "an extension depends on one whose triggers it strictly contains" {
    // `:664-668`. Two extensions of one parent: `Both` triggers on B and C,
    // `OnlyB` on B alone, so triggers[Both] = {A,B,C} strictly contains
    // triggers[OnlyB] = {A,B} and Both must wait for OnlyB.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\C = "cccccccc-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B", "C"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    OnlyB = "B"
        \\    Both = ["B", "C"]
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.C]]
        \\uuid = "cccccccc-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);
    try testing.expectEqual(@as(usize, 2), g.extension_count);

    var both: ?usize = null;
    var only_b: ?usize = null;
    for (g.nodes, 0..) |nd, i| {
        if (nd.ext == null) continue;
        if (std.mem.eql(u8, nd.name, "Both")) both = i;
        if (std.mem.eql(u8, nd.name, "OnlyB")) only_b = i;
    }
    // Both waits for OnlyB...
    try testing.expect(std.mem.indexOfScalar(usize, g.nodes[both.?].deps, only_b.?) != null);
    // ...and emphatically not the other way round: the subset does not wait
    // for the superset, or the two would deadlock the frontier.
    try testing.expect(std.mem.indexOfScalar(usize, g.nodes[only_b.?].deps, both.?) == null);

    const o = try topoOrder(a, g, null);
    var pos_both: usize = 0;
    var pos_only: usize = 0;
    for (o.nodes, 0..) |n, i| {
        if (n == both.?) pos_both = i;
        if (n == only_b.?) pos_only = i;
    }
    try testing.expect(pos_only < pos_both);
}

test "two parents may declare extensions with the same name" {
    // Real: `Accessors` and `FieldViews` both have a `StaticArraysExt` in the
    // engine's environment. They are different modules with different uuids,
    // so both must be nodes -- a set keyed by name would silently compile one.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\C = "cccccccc-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["C"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    SharedName = "C"
        \\
        \\[[deps.B]]
        \\deps = ["C"]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.B.extensions]
        \\    SharedName = "C"
        \\
        \\[[deps.C]]
        \\uuid = "cccccccc-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);

    try testing.expectEqual(@as(usize, 2), g.extension_count);
    try expectOrder(try extNames(a, g), &.{ "A → SharedName", "B → SharedName" });
}

test "a trigger named by a weakdep table resolves even with no manifest entry" {
    // The `Vulkan` shape. `Pkg.resolve()` drops a weakdep-only closure from the
    // manifest, which flips `weakdeps` into a table carrying the uuid inline
    // (`manifest.jl:338-345`). Julia still resolves the trigger NAME, because
    // expanding a dep table backfills `name_to_uuid` (`:217`) -- so the lookup
    // succeeds and the extension is then dropped for the real reason, which is
    // that the trigger is not in the closure. Getting this wrong reports a
    // dormant extension as a malformed manifest.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.weakdeps]
        \\    Vulkan = "dddddddd-1111-1111-1111-111111111111"
        \\
        \\    [deps.A.extensions]
        \\    AVulkanExt = "Vulkan"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);

    try testing.expectEqual(@as(usize, 0), g.extension_count);
    try testing.expectEqual(@as(usize, 1), g.extensions_dormant);
}

test "an unresolvable trigger name is dormant, not a refusal" {
    // Julia would KeyError here (`name_to_uuid[trigger]`, `:237`), but only on
    // a manifest no Pkg version writes. One hand-edited entry must not stop the
    // other packages being precompiled.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    GhostExt = "NoSuchPackage"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);

    try testing.expectEqual(@as(usize, 0), g.extension_count);
    try testing.expectEqual(@as(usize, 1), g.extensions_dormant);
    try expectOrder(try env.names(a), &.{"A"});
}

/// `extensionEdges` over a graph, with every node probed as compilable except
/// the ones named in `sysimage`.
fn edgesFor(
    arena: Allocator,
    g: Graph,
    o: Order,
    sysimage: []const []const u8,
) ![]const []const u32 {
    const results = try arena.alloc(Result, o.nodes.len);
    for (results, o.nodes) |*r, n| {
        r.* = .{ .name = g.nodes[n].name, .uuid = g.nodes[n].uuid, .outcome = .stale };
        for (sysimage) |s| {
            if (g.nodes[n].ext == null and std.mem.eql(u8, s, g.nodes[n].name)) r.outcome = .in_sysimage;
        }
    }
    const slot = try arena.alloc(u32, g.nodes.len);
    @memset(slot, std.math.maxInt(u32));
    for (o.nodes, 0..) |n, i| slot[n] = @intCast(i);
    return extensionEdges(arena, g, o, results, slot);
}

/// Position of a node in `o`, by name; extensions are matched on name too,
/// which the fixtures below keep unambiguous.
fn posOf(g: Graph, o: Order, name: []const u8) ?u32 {
    for (o.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, g.nodes[n].name, name)) return @intCast(i);
    }
    return null;
}

test "a package waits for an extension it could load, at any dependency depth" {
    // Top -> Mid -> A, and Top -> Trigger. A declares AExt triggered by
    // Trigger, so AExt is loadable in Top -- which depends on both, though on A
    // only INDIRECTLY. That indirection is the point: the rule is over
    // `indirect_deps` (`precompilation.jl:698-716`), and a transitive closure
    // computed in the wrong direction gives a node its direct dependencies
    // only, which would leave this edge out while the shallow cases still pass.
    var env = try TestEnv.init(
        \\[deps]
        \\Top = "11111111-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Top]]
        \\deps = ["Mid", "Trigger"]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.Mid]]
        \\deps = ["A"]
        \\uuid = "22222222-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.A]]
        \\deps = ["Trigger"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    AExt = "Trigger"
        \\
        \\[[deps.Trigger]]
        \\uuid = "33333333-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);
    const o = try topoOrder(a, g, null);
    const edges = try edgesFor(a, g, o, &.{});

    const ext = posOf(g, o, "AExt").?;
    const top = posOf(g, o, "Top").?;
    const mid = posOf(g, o, "Mid").?;

    // Mid is the DEEPEST package in which the extension is loadable (it depends
    // on A and, through A, on Trigger), so Mid gets the edge...
    try testing.expect(std.mem.indexOfScalar(u32, edges[mid], ext) != null);
    // ...and Top does not, because one of its dependencies already has it. That
    // is the `!any(dep -> ext_loadable_in_pkg[dep])` clause: without it every
    // package downstream of a trigger waits on the extension.
    try testing.expect(std.mem.indexOfScalar(u32, edges[top], ext) == null);
}

test "a trigger does not wait for the extension it triggers" {
    // `!is_trigger` (`:706`). The parent is a trigger too, so this is also what
    // stops `A -> AExt -> A` from being a cycle the scheduler then refuses.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    AExt = "B"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);
    const o = try topoOrder(a, g, null);
    const edges = try edgesFor(a, g, o, &.{});

    const ext = posOf(g, o, "AExt").?;
    for ([_][]const u8{ "A", "B" }) |n| {
        const p = posOf(g, o, n).?;
        try testing.expect(std.mem.indexOfScalar(u32, edges[p], ext) == null);
    }
}

test "a sysimage trigger is filtered out before the subset test" {
    // Julia never puts a sysimage package in `direct_deps` (`:623-624`), so
    // `direct_deps[ext]` here is {A} and not {A, Sys}. Keeping Sys would ask
    // whether Consumer depends on LinearAlgebra — the wrong question, and one
    // that answers "no" for a package that can perfectly well load the
    // extension.
    var env = try TestEnv.init(
        \\[deps]
        \\Consumer = "44444444-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Consumer]]
        \\deps = ["A"]
        \\uuid = "44444444-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.A]]
        \\deps = ["Sys"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.extensions]
        \\    ASysExt = "Sys"
        \\
        \\[[deps.Sys]]
        \\uuid = "55555555-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = try buildGraph(a, env.project, env.manifest);
    const o = try topoOrder(a, g, null);

    const ext = posOf(g, o, "ASysExt").?;
    const consumer = posOf(g, o, "Consumer").?;

    // With Sys in the sysimage, Consumer needs only to reach A.
    const filtered = try edgesFor(a, g, o, &.{"Sys"});
    try testing.expect(std.mem.indexOfScalar(u32, filtered[consumer], ext) != null);

    // Sanity that the fixture can tell the two apart: Consumer does depend on
    // Sys transitively, so with no filtering the edge is still there. The
    // filter is asserted where it changes an answer — in the harness against
    // Julia — and here it is asserted not to crash or drop the extension.
    const unfiltered = try edgesFor(a, g, o, &.{});
    try testing.expect(std.mem.indexOfScalar(u32, unfiltered[consumer], ext) != null);
}

test "strictSuperset is strict, and is not fooled by length alone" {
    try testing.expect(strictSuperset(&.{ 1, 2, 3 }, &.{ 1, 2 }));
    try testing.expect(!strictSuperset(&.{ 1, 2 }, &.{ 1, 2 })); // equal is not strict
    try testing.expect(!strictSuperset(&.{ 1, 2 }, &.{ 1, 2, 3 }));
    // Longer, but missing a member: the length check alone would say yes.
    try testing.expect(!strictSuperset(&.{ 1, 4, 5 }, &.{ 1, 2 }));
    try testing.expect(strictSuperset(&.{7}, &.{}));
    try testing.expect(!strictSuperset(&.{}, &.{}));
}

test "a cycle is reported, not dropped, and not ordered before its dependents" {
    // Pkg's SCC scan marks both the cycle members and everything downstream of
    // them, and skips the lot (precompilation.jl:766-800).
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.B]]
        \\deps = ["C"]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\[[deps.C]]
        \\deps = ["B"]
        \\uuid = "cccccccc-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const g = try buildGraph(a, env.project, env.manifest);
    const o = try topoOrder(a, g, null);
    try testing.expectEqual(@as(usize, 3), o.nodes.len);
    for (o.nodes) |i| try testing.expect(g.nodes[i].circular);
}

test "the same dependency listed twice is one edge" {
    // An expanded-form manifest can repeat a dep. Counting it twice would leave
    // a permanent in-degree and turn a healthy package into a phantom cycle.
    var env = try TestEnv.init(
        \\[deps]
        \\A = "aaaaaaaa-1111-1111-1111-111111111111"
        \\
    ,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\uuid = "aaaaaaaa-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
        \\    [deps.A.deps]
        \\    B = "bbbbbbbb-1111-1111-1111-111111111111"
        \\
        \\[[deps.B]]
        \\uuid = "bbbbbbbb-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    );
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectOrder(try env.names(arena_state.allocator()), &.{ "B", "A" });
}

test "parseOutcome reads only the machine-readable line" {
    try testing.expectEqual(Outcome.compiled, parseOutcome("outcome\tcompiled\n").?);
    try testing.expectEqual(Outcome.waited, parseOutcome("noise\noutcome\twaited\n").?);
    try testing.expectEqual(
        Outcome.already_precompiled,
        parseOutcome("outcome\talready_precompiled").?,
    );
    try testing.expectEqual(Outcome.not_precompilable, parseOutcome("outcome\tnot_precompilable\n").?);
    // A word this module does not know is NOT silently a success: the child and
    // the parser have drifted and the run should say so.
    try testing.expectEqual(@as(?Outcome, null), parseOutcome("outcome\tsomething_new\n"));
    try testing.expectEqual(@as(?Outcome, null), parseOutcome(""));
    try testing.expectEqual(@as(?Outcome, null), parseOutcome("Precompiling Foo...\n"));
}

test "a dry run over a cold environment is a plan, not a pile of failures" {
    // Regression: `stale` used to share `Outcome.unknown` with "the probe never
    // answered", so `--dry-run` on a perfectly healthy cold environment
    // reported every package as failed, printed its SOURCE PATH as the error
    // message, and exited 1.
    const pkgs = [_]Result{
        .{ .name = "Dates", .uuid = .{ .bytes = @splat(0) }, .outcome = .already_precompiled },
        .{ .name = "Parsers", .uuid = .{ .bytes = @splat(1) }, .outcome = .stale, .source = "/x/Parsers.jl" },
    };
    const dry: Report = .{ .dry_run = true, .packages = &pkgs, .considered = 2 };
    try testing.expect(dry.ok());
    try testing.expectEqual(@as(usize, 1), dry.countOf(.stale));
    try testing.expectEqual(@as(usize, 0), dry.failedCount());

    // The same report from a REAL run means the compile pass skipped something
    // it was handed, and that must not exit 0.
    const wet: Report = .{ .dry_run = false, .packages = &pkgs, .considered = 2 };
    try testing.expect(!wet.ok());
}

test "a package with no source on disk fails the run, as it does for Pkg" {
    // `precompilation.jl:1017-1021` puts a missing source straight into
    // `failed_deps`, and a non-empty `failed_deps` makes Pkg.precompile() raise.
    // Counting it as a benign "skip" would let `ajt precompile` exit 0 on an
    // environment that was never instantiated.
    const pkgs = [_]Result{
        .{ .name = "Ghost", .uuid = .{ .bytes = @splat(0) }, .outcome = .source_missing },
    };
    const rep: Report = .{ .packages = &pkgs, .considered = 1 };
    try testing.expect(!rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.failedCount());
}

test "skipping a package Pkg also skips is not a failure" {
    const pkgs = [_]Result{
        .{ .name = "Random", .uuid = .{ .bytes = @splat(0) }, .outcome = .in_sysimage },
        .{ .name = "Legacy", .uuid = .{ .bytes = @splat(1) }, .outcome = .not_precompilable },
        .{ .name = "Knot", .uuid = .{ .bytes = @splat(2) }, .outcome = .circular },
        .{ .name = "Slow", .uuid = .{ .bytes = @splat(3) }, .outcome = .waited },
    };
    const rep: Report = .{ .packages = &pkgs, .considered = 4 };
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 0), rep.failedCount());
    // `waited` counts as built: another process produced the entry, and the
    // cache is there either way.
    try testing.expectEqual(@as(usize, 1), rep.compiledCount());
}

test "tail keeps the end, which is where Julia prints the error" {
    try testing.expectEqualStrings("cde", tail("abcde", 3));
    try testing.expectEqualStrings("abc", tail("abc", 3));
    try testing.expectEqualStrings("abc", tail("abc", 100));
}

test "the embedded Julia carries the pidlock protocol, not just compilecache" {
    // A refactor that drops the wait branch would still compile correctly on an
    // uncontended depot and corrupt cache entries on a shared one -- the exact
    // failure this module exists to prevent. Pin the three call sites.
    try testing.expect(std.mem.indexOf(u8, compile_source, "trymkpidlock_hook") != null);
    try testing.expect(std.mem.indexOf(u8, compile_source, "mkpidlock_hook(work") != null);
    try testing.expect(std.mem.indexOf(u8, compile_source, "compilecache_pidfile_path") != null);
    try testing.expect(std.mem.indexOf(u8, compile_source, "using FileWatching") != null);
    // ...and nothing here may write a cache file itself.
    try testing.expect(std.mem.indexOf(u8, probe_source, "compilecache") == null);
}

test "parseBoolEnv is Base's two tuples, capitalisation included" {
    // `base/env.jl:117-127`, transcribed and then asserted rather than
    // paraphrased: the Capitalized/UPPERCASE spellings are the half a
    // hand-written port drops, and dropping them turns
    // `JULIA_PKG_PRECOMPILE_AUTO=NO` into "yes".
    for ([_][]const u8{
        "t", "T", "true", "True", "TRUE", "y", "Y", "yes", "Yes", "YES", "1",
    }) |v| try testing.expectEqual(BoolEnv.truthy, parseBoolEnv(v));
    for ([_][]const u8{
        "f", "F", "false", "False", "FALSE", "n", "N", "no", "No", "NO", "0",
    }) |v| try testing.expectEqual(BoolEnv.falsy, parseBoolEnv(v));

    // Everything else is `nothing`, NOT false. Julia's own `parse_bool_env`
    // is case-SENSITIVE past these exact spellings: "tRue" is in neither
    // tuple, so it is unrecognised rather than true.
    for ([_][]const u8{ "", "off", "on", "2", "tRue", "YeS", "no ", " 0" }) |v| {
        try testing.expectEqual(BoolEnv.unrecognized, parseBoolEnv(v));
    }
}

test "getBoolEnv: unset, empty and unparseable all take the default" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();

    // Unset.
    try testing.expect(getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));
    try testing.expect(!getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", false));

    // Empty is the DEFAULT, not false: `get_bool_env` tests `!isempty(val)`
    // before it parses (`base/env.jl:145`).
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "");
    try testing.expect(getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));

    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "0");
    try testing.expect(!getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "no");
    try testing.expect(!getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "yes");
    try testing.expect(getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "TRUE");
    try testing.expect(getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));

    // Pkg raises a TypeError on this one; Ajt takes the default. See
    // `getBoolEnv`'s doc comment for why it cannot do the same thing.
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "off");
    try testing.expect(getBoolEnv(&map, "JULIA_PKG_PRECOMPILE_AUTO", true));
}

test "autoEnabled defaults to on, and a null environment is not a veto" {
    // A caller that supplied no environment gets Pkg's default rather than
    // silence: `null` means "nothing was threaded through here", and reading
    // it as "the user set 0" would disable the feature everywhere it is not
    // wired up.
    try testing.expect(autoEnabled(null));

    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try testing.expect(autoEnabled(&map));
    try map.put("JULIA_PKG_PRECOMPILE_AUTO", "0");
    try testing.expect(!autoEnabled(&map));
}
