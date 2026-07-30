//! `ajt instantiate --frozen` — take an environment whose `Manifest.toml` is
//! already complete and make the depot satisfy it.
//!
//! This is the composition step: every part of the work is a module that is
//! already merged and already differentially gated (`registry_ops`,
//! `install_packages`, `install_artifacts`, `verify`). Nothing here downloads,
//! extracts, verifies a hash or writes a depot entry itself; it decides *what*
//! those modules are asked to do, in Pkg's order, and reports what happened.
//!
//! ### `--frozen` does not mean "read-only"
//!
//! Say it plainly, because the word invites the wrong reading: **`--frozen`
//! means the manifest is authoritative and no version selection ever happens.**
//! It does not mean the run writes nothing. A frozen instantiate still
//! downloads registries, packages and artifacts, still publishes them into the
//! depot, and still writes the `fixups_from_projectfile!` metadata back into
//! `Manifest.toml` — all of which `Pkg.instantiate()` also does. What it never
//! does is *resolve*: no PubGrub, no version bumps, no compat evaluation, no
//! change to any `git-tree-sha1`. The pins in the file are the answer.
//!
//! `ajt verify --frozen` is the other verb and there `--frozen` really is the
//! only behaviour (see `verify.zig`); the same flag on two commands means the
//! same thing — "never re-resolve" — and only differs in how much each of them
//! had to do anyway.
//!
//! ### The pipeline, and where Pkg does each step
//!
//! `Pkg.API.instantiate` (`API.jl:1274-1400`), with the branches this unit does
//! not implement (workspaces, build scripts) called out rather than
//! silently skipped:
//!
//! ```text
//!  0. verify.run                       API.jl:1321-1340  is_manifest_current + is_instantiated
//!  1. prune_manifest                   API.jl:1326       Operations.jl:1252-1277
//!  2. direct deps are manifested       API.jl:1327-1334  pkgerror, not a download
//!  3. registry, if anything is missing API.jl:1347-1355  check_registered / update_registries
//!  4. download_source                  API.jl:1392       Operations.jl:1112-1247
//!  5. download_artifacts               API.jl:1394       Operations.jl:918-1078
//!  6. fixups_from_projectfile!         Operations.jl:253-291   (see the divergence below)
//!  7. verify.run again                 —                 converge on our own checker
//!  8. _auto_precompile                 API.jl:1398       Pkg.jl:896-900 (see `Options.precompile`)
//! ```
//!
//! **Step 8 runs after step 7, not before it.** Pkg reaches
//! `allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)`
//! as the last statement of `instantiate` (`API.jl:1398`), and the ordering is
//! load-bearing here for a second reason: `precompile` refuses a package whose
//! source is not on disk (`source_missing`), so the converge measurement is
//! worth having BEFORE a compile pass turns one missing tarball into a wall of
//! per-package failures. `run` reads the same converge answer and skips the
//! pass when the install did not land — see `Report.precompile_skipped`.
//!
//! **Step 6 is a deliberate superset.** `Pkg.instantiate` does *not* call
//! `fixups_from_projectfile!` — only `add`/`develop`/`up`/`pin`/`free` do
//! (`Operations.jl:1804`, `:1853`, `:2004`, `:2051`, `:2101`). It is run here
//! because the metadata that pass copies (`weakdeps`, `extensions`,
//! `entryfile`) is unreadable until the packages are on disk, so a manifest
//! produced by anything other than a full Pkg session can be missing it, and
//! the loader then loads an extension's trigger unconditionally. The pass is
//! idempotent on a manifest Pkg itself wrote — the committed
//! `Open-Reality/Manifest.toml` round-trips byte-for-byte through it — so on a
//! healthy environment step 6 writes nothing at all.
//!
//! ### Why steps 4 and 5 are still two phases
//!
//! They are the two `@sync` barriers `sched/` was built to delete, and the
//! obvious next move is to run them as one frontier: collect a JLL's artifacts
//! the instant its tarball is published and let them stream while the other 130
//! tarballs are still arriving. That was built and measured, and **it is
//! slower**. The numbers are here so nobody spends the day twice.
//!
//! Interleaved, `ReleaseFast`, fresh empty depot each run, on the 173-entry
//! Open-Reality environment (131 package jobs / 30 MB, 52 artifacts / 225 MB),
//! median of 3:
//!
//! ```text
//!                                              peak sockets   wall
//!   two phases,  --jobs 8                            8       14.9 s
//!   ONE frontier, --jobs 8 shared by both halves     8       16.6 s   1.12x SLOWER
//!   two phases,  --jobs 16                          16       10.2 s
//!   ONE frontier, --jobs 8 per half                 16       12.3 s   1.21x slower
//! ```
//!
//! **At equal peak concurrency the barrier wins, in both directions.** The
//! fusion works — sampled every 0.5 s, artifacts start landing at t=5.0 s while
//! packages keep arriving until t=15.5 s, against t=13.0 s for the phased run —
//! it just does not pay, and the reason is that the two halves are bounded by
//! the *same* resource:
//!
//!   * The artifact half's throughput scales with the number of open
//!     connections (measured against a warm-package depot: `--jobs` 8/16/24 →
//!     4.6 s / 2.9 s / 2.6 s, i.e. 49/78/88 MB/s). It needs its connections in
//!     a **block**, and interleaving hands it roughly three of the eight.
//!   * The package half is round-trip-bound — 131 requests for 30 MB, 0.47 s
//!     each at 8-wide, and a cold run is 18% CPU — so a longer wall-clock
//!     window buys it nothing.
//!
//! A barrier only costs something when the phases either side of it queue on
//! different resources. `download_source` and `download_artifacts` queue on the
//! same one: Pkg says so itself, constructing `Base.Semaphore(
//! ctx.num_concurrent_downloads)` in each of them (`Operations.jl:1049` for the
//! artifacts) and never running the two together. The phase fusion the plan
//! sized at 1.3–1.5x is the one between downloading and **compiling** — network
//! against CPU and RAM, which really are different resources — and that is what
//! `ops/precompile.zig`'s frontier already exploits (321 s → 80 s).
//!
//! What would change the answer: a Pkg server on a link that saturates well
//! below `--jobs` connections (fusing then costs the artifact half nothing), or
//! putting `Compile` in this graph. `tools/diff_harness/instantiate.sh`'s
//! section 8 is the check that keeps the premise honest — it re-instantiates at
//! twice the width and reports when doubling `--jobs` stops buying a large
//! fraction of the run, i.e. when this stops being connection-bound.
//!
//! ### Two traps that decide correctness
//!
//!  1. **The pruned manifest is what gets DOWNLOADED; the whole manifest is
//!     what gets WRITTEN.** `prune_manifest` mutates `env.manifest` in memory
//!     (`Operations.jl:1268`) and `download_source` then iterates that pruned
//!     dict — which is why nine of Open-Reality's 170 tree-hash entries (the
//!     `Vulkan` family, reachable only through a `[weakdeps]` extension
//!     trigger) are **never installed**, while `is_instantiated` still answers
//!     true. Installing them would be wrong. Pkg gets away with the mutation
//!     because `instantiate` never writes the manifest back; this unit does
//!     write it, so the pruned view is kept as a separate value and the file
//!     always carries all 214 entries. Measured, not reasoned about:
//!     `length(env.manifest)` is 214, `prune_manifest` leaves 205, and
//!     `count(tree_hash !== nothing)` goes 170 → 161.
//!
//!  2. **The closure keeps the project's OWN uuid, and `verify`'s does not.**
//!     `prune_manifest(env)` seeds `keep` with `values(env.project.deps)` *plus*
//!     `env.pkg.uuid` when the environment is itself a package
//!     (`Operations.jl:1259-1261`), whereas `load_all_deps_loadable` — which
//!     `verify.loadable` reproduces — seeds it with the deps alone
//!     (`Operations.jl:192-198`). On Open-Reality that is exactly the
//!     difference between 205 and 204: the manifest carries its own
//!     `OpenReality` entry at `path = "."`. So this file cannot simply call
//!     `verify`'s closure; it ports the other function, and the two are pinned
//!     to each other by the fact that step 7 verifies with `verify`'s rule
//!     after installing with this one. The extra entry has no `git-tree-sha1`,
//!     so on this environment the download set is the same either way — but a
//!     package whose own manifest pins it by tree hash would diverge, and
//!     silently.
//!
//! ### What is not implemented, and where it diverges
//!
//!  * **Git checkouts** are folded into step 4 rather than run as the separate
//!    pass Pkg has. `Pkg.instantiate` clones `pkg.repo.source` entries in a
//!    loop of its own BEFORE `download_source` (`API.jl:1358-1390`), which
//!    then skips them; here `jobsFromManifest` emits them as jobs with no
//!    archive candidate and `install_packages`' git pass clones them after the
//!    download workers join. Same clone directory (`add_repo_cache_path`),
//!    same destination, same order relative to artifacts and build steps —
//!    one queue instead of two. With `Options.git` null nothing clones and
//!    they surface as `package_missing` in the converge report, which is what
//!    this unit did for every one of them before.
//!    re-clones a `repo-url` entry whose tree is missing from the depot; that
//!    branch is not here, so such an entry surfaces as `package_missing` in the
//!    converge report. It is NOT the `[sources]` url case: a `[sources]` entry
//!    carrying a `url` is materialised by `ops/resolve.zig` — which is where
//!    Pkg does it too, in `collect_fixed!` (`Operations.jl:432-444`) — and by
//!    the time a manifest naming one reaches here the tree is already unpacked
//!    under its slug, so `sourcePath`'s tree-hash branch finds it and step 7
//!    passes. `sourcePath`'s branch order is therefore unchanged by that unit:
//!    urls never reach the `[sources]` branch below, because after a resolve
//!    they are an ordinary `git-tree-sha1`.
//!  * **Build scripts and precompilation.** `build_versions` and
//!    `_auto_precompile` are out of scope for a package manager that is not
//!    also a build system yet.
//!  * **Workspace ROOTS are refused** by `verify` in step 0. A workspace
//!    MEMBER is not detected: `[workspace]` lives only in the root's project
//!    file, and Julia finds the root by walking up (`find_root_base_project`,
//!    `Types.jl:348-356`) and redirects the manifest to it (`Types.jl:414-417`).
//!    A member normally degrades to `manifest_unreadable` and blocks; a member
//!    carrying a stale `Manifest.toml` of its own would be instantiated as if
//!    it were a standalone project. `verify` has the identical gap.
//!  * **An entry with no source at all** (`unresolvable_entry`: no tree hash, no
//!    path, uuid not a stdlib) makes Julia's `is_package_downloaded` `pkgerror`,
//!    so `Pkg.instantiate` aborts inside `is_instantiated` at `API.jl:1337`
//!    without downloading anything. Here it is NOT a block: the other 160
//!    packages install and the converge report names the entry. Refusing to fix
//!    an environment that is 99% fixable, over one entry a resolve has to
//!    repair anyway, is the worse failure for a container entrypoint. The same
//!    reasoning covers `stdlib_missing`.
//!  * **`[sources]` is honoured for artifact roots, where Pkg's is not.**
//!    `download_artifacts` iterates the raw manifest entries and calls
//!    `source_path` directly (`Operations.jl:930-933`); the `[sources]` rewrite
//!    lives in `load_all_deps` (`:174-179`), which neither `download_artifacts`
//!    nor `download_source` calls. So on a manifest not re-resolved after a
//!    `[sources]` edit, Pkg collects artifacts from the tree-hash location and
//!    this collects them from the `[sources]` directory. That agrees with
//!    `is_instantiated` (which goes through `load_all_deps`) and therefore with
//!    step 7, which is why it is the choice made — but it is a divergence from
//!    `Operations.jl`, not fidelity to it.
//!  * **A manifest with two entries under one uuid** is processed twice. Julia's
//!    manifest is a `Dict{UUID,PackageEntry}`, so the duplicate collapses at
//!    read time; the model here preserves file order (`manifest.zig`) and both
//!    survive. Only reachable on a hand-corrupted file.
//!
//! ### Allocation
//!
//! `arena` holds everything the `Report` borrows — the parsed models, every
//! path, every per-package and per-artifact record. It is **bundle-lifetime**
//! data: nothing in it is freed individually and the caller drops the whole
//! arena when it is done printing. `gpa` backs the transient side — HTTP
//! connection pools, the per-worker download scratch, the TOML emitter — and
//! everything taken from it is released before `run` returns. The split is
//! load-bearing: a 500 MB artifact set flows through `gpa` one tarball at a
//! time, and putting it in `arena` would hold the whole download in memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const git_mod = @import("../git/git.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const platform_mod = @import("../julia/platform.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const net_http = @import("../net/http.zig");

const pkgs = @import("install_packages.zig");
const arts = @import("install_artifacts.zig");
const regops = @import("registry_ops.zig");
const verify = @import("verify.zig");
const usage = @import("usage.zig");
const precompile_mod = @import("precompile.zig");

pub const Platform = platform_mod.Platform;
pub const Uuid = manifest_mod.Uuid;

/// `ctx.num_concurrent_downloads` (`Types.jl:463-467`), reached through the
/// transport so the number lives in one place.
pub const default_jobs = pkgs.default_concurrency;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

// ---------------------------------------------------------------------------
// The registry seam
// ---------------------------------------------------------------------------

/// When to go to the network for the registry.
///
/// The registry is needed for exactly one thing here: `find_urls`
/// (`Operations.jl:1096-1107`), i.e. the `repo` field that becomes the GitHub
/// tarball fallback URL. A fully pinned manifest downloads fine from the Pkg
/// server without it, because that server is addressed by UUID and tree hash
/// alone — so this only ever costs the fallback.
pub const RegistryPolicy = enum {
    /// Never touch the network for the registry. Whatever is installed is used.
    never,
    /// `registry add` when none is installed. Pkg's own shape: `check_registered`
    /// fails, `update_registries(force = false)` runs, `check_registered` is
    /// retried (`API.jl:1347-1355`).
    if_missing,
    /// `registry update` (or `add`) every time.
    always,

    /// What the policy actually is once offline mode has had its say.
    ///
    /// Offline does not get a switch of its own here: `update_registries`
    /// opens with `OFFLINE_MODE[] && return` (`Operations.jl:1629`), which is
    /// precisely `.never` and nothing more — the registry that IS installed is
    /// still read, and a missing one is still not an error, exactly as when a
    /// caller asks for `.never` directly. Two flags meaning the same thing
    /// would only give them room to disagree.
    pub fn effective(self: RegistryPolicy, offline: bool) RegistryPolicy {
        return if (offline) .never else self;
    }
};

/// How `find_urls` is answered.
///
/// A vtable rather than a concrete registry, for the same reason
/// `install_packages.RepoLookup` is one: this module must not know whether the
/// caller opened a `.aix` index or a tarball, and `open` must not run until
/// after the registry has been ensured present — a lookup opened too early
/// would miss the registry this very run installed.
pub const Registry = struct {
    ctx: *anyopaque,
    /// Called at most once per run, and never before step 3 has had its chance
    /// to run. Under `--dry-run` step 3 makes no network call at all, so this
    /// may be called with the registry in whatever state it was already in —
    /// which is the point: a dry run should predict the URL list a real run
    /// would build, and a real run on a COLD depot has a registry by then.
    open: *const fn (ctx: *anyopaque) pkgs.RepoLookup,

    fn openNone(_: *anyopaque) pkgs.RepoLookup {
        return .none;
    }

    /// No registry at all: every package's only candidate is the Pkg server.
    pub const none: Registry = .{ .ctx = undefined, .open = openNone };
};

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
    /// The resolved `DEPOT_PATH`. Every entry is searched; `stack.writeDepot()`
    /// (entry 0) is the only one written to — `Pkg.depots1()`.
    stack: depot_mod.Stack,

    /// `dirname(Sys.BINDIR)`. Needed for the stdlib cross-check in steps 0/7,
    /// for `Types.stdlib_dir()` in step 6, and to detect the host platform in
    /// step 5. Without it the artifact half cannot run at all — see
    /// `Report.artifacts_skipped`.
    julia_prefix: ?[]const u8 = null,
    /// e.g. "1.12.6". Defaults to the manifest's own `julia_version`, which
    /// records the Julia that resolved the environment.
    julia_version: ?[]const u8 = null,
    /// `Types.stdlib_dir()`. Derived from `julia_prefix` + the version when null.
    stdlib_dir: ?[]const u8 = null,
    /// The platform artifacts are selected for. Detected from `julia_prefix` +
    /// the version when null. **Must have come from `platform.construct` /
    /// `constructHost`** — a hand-assembled tag list skips the normalisation
    /// (auto `libc`, arch aliases, version rounding) that decides which variant
    /// wins, and picks the wrong tarball on exactly the hosts that matters for.
    host: ?Platform = null,

    /// Transport config: the `Julia-*` protocol headers and the depot the
    /// bearer token is read from. Supply it; a default-constructed one sends
    /// empty protocol headers and finds no `servers/<host>/auth.toml`.
    net: net_http.Config = .{},
    /// `pkg_server()`, already normalised.
    ///
    /// **Null means "not supplied", not "off".** It falls back to `net.server`,
    /// because a caller that built a `Config` from the environment and did not
    /// think about this field should not silently lose the server. To express
    /// what `JULIA_PKG_SERVER=""` means — the protocol disabled, leaving only
    /// the GitHub tarball fallback — null BOTH this and `net.server`, which is
    /// what the CLI does for `--server ""`. There is no third state, and
    /// inventing a sentinel for one would put an `?[]const u8` in every call
    /// site of four other modules that already spell it this way.
    server: ?[]const u8 = null,
    /// The git backend the install falls back to, for a `repo-url` manifest
    /// entry and for a package no archive can serve
    /// (`install_packages.Options.git`). Null installs from archives only,
    /// which is what a build with no git support has to do.
    git: ?git_mod.Backend = null,
    /// Concurrent downloads, for BOTH halves. Pkg's default is 8
    /// (`Types.jl:463-467`).
    ///
    /// It has to cover the artifacts, and the measurement says so: on the
    /// Open-Reality environment the artifacts are 516 MB against 33 MB of
    /// package source, and a cold instantiate that fetched the packages 8-wide
    /// and the artifacts one at a time took 88 s where `Pkg.instantiate()` —
    /// which spawns a task per artifact (`Operations.jl:1023-1050`) — took 55 s.
    /// Driving both halves at 8 brings it to 27 s. See `installArtifacts`.
    jobs: u32 = default_jobs,

    /// Resolve and report; download nothing, write nothing, not even the
    /// manifest.
    dry_run: bool = false,

    registry_policy: RegistryPolicy = .if_missing,
    registry_name: []const u8 = "General",
    /// Depot that owns `registries/`. Defaults to `stack.writeDepot()`.
    registry_depot: ?[]const u8 = null,
    /// Raw `JULIA_PKG_UNPACK_REGISTRY`.
    unpack_registry: ?[]const u8 = null,

    /// `select_downloadable_artifacts(...; include_lazy)`.
    include_lazy: bool = false,
    honor_overrides: bool = true,

    /// Step 5. Off leaves the environment loadable but JLL-less, so it is a
    /// debugging switch, not a mode: `Report.ok()` still requires that the step
    /// either ran or was explicitly turned off.
    artifacts: bool = true,
    /// Step 6.
    fixups: bool = true,
    /// Whether step 6 may write `Manifest.toml` back. The write happens only
    /// when the rendered bytes actually differ from the file — see `run`.
    write_manifest: bool = true,

    /// Step 8: `Pkg._auto_precompile(ctx, already_instantiated = true)`
    /// (`API.jl:1398`). Still subject to `JULIA_PKG_PRECOMPILE_AUTO`, which is
    /// checked here rather than by the caller — `precompile.autoEnabled` is
    /// the port of `should_autoprecompile` and there must be exactly one of it.
    ///
    /// **Off by default, where Pkg's `allow_autoprecomp` is on.** That is not
    /// a disagreement about the behaviour, it is about who this struct's
    /// default serves. `run` is also the install pass of `ops/edit.zig` and
    /// the fixture of half the tests in this file, and a default that spawns
    /// `julia` children would change what both of those mean. Pkg draws the
    /// line in the same place, from the other side: EVERY internal caller
    /// passes `allow_autoprecomp = false` (`API.jl:1249`, `Operations.jl:1335`,
    /// `:2395`, `:2438`), and only the user-facing `Pkg.instantiate()` leaves
    /// it on. `ajt instantiate` turns it on; `ajt add`'s inner instantiate does
    /// not, because `add` precompiles once for itself afterwards.
    precompile: bool = false,
    /// The parent environment the precompile children inherit. Without it they
    /// get a two-variable environment with no `PATH` and no `HOME`, so a
    /// caller that sets `precompile` should set this too.
    environ: ?*const std.process.Environ.Map = null,
    /// The `julia` the precompile children run. Null derives it from
    /// `julia_prefix`, exactly as `precompile.Options` does.
    julia_exe: ?[]const u8 = null,
    /// Children compiling at once. Null detects it from the machine.
    precompile_jobs: ?u32 = null,
    /// `precompile.Options.cache_url`, threaded rather than dropped.
    ///
    /// It has to be: without it the shared store is unreachable on the path
    /// that matters. A deploy runs `ajt instantiate` and then `ajt precompile`,
    /// so if step 8 compiled locally the second command would find every entry
    /// already fresh and never look the key up — the cache would be wired and
    /// dead. Null (the default, and what `$AJT_CACHE_URL` unset means) is
    /// exactly Pkg's behaviour: compile locally, talk to nothing.
    ///
    /// Read-only on purpose: no token is threaded, so an auto-precompile
    /// IMPORTS from the store and never publishes to it. Publishing is a
    /// deliberate act by whatever builds the image, which is `ajt precompile`.
    precompile_cache_url: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

/// What step 3 did.
pub const RegistryStep = struct {
    /// False when nothing had to be looked up (every package already installed)
    /// or the policy forbade it.
    attempted: bool = false,
    name: []const u8 = "",
    action: ?regops.Action = null,
    /// A registry failure is NOT fatal: the Pkg server serves by UUID and tree
    /// hash, so it costs only the GitHub fallback. Recorded so that "the
    /// fallback was unavailable" and "the fallback was not needed" do not look
    /// identical in the output.
    err: ?[]const u8 = null,
};

/// Why the artifact half did not run. Null means it ran.
pub const ArtifactsSkipped = enum {
    /// No `--host` and no `--julia-prefix` to detect one from. Installing the
    /// wrong platform's tarballs fails at `dlopen` time, in a game, months
    /// later; refusing is the only honest option.
    no_host,
    /// An `(Julia)Artifacts.toml` could not be READ (as opposed to parsed —
    /// that is `artifact_problems`). `collect_artifacts` propagates this in Pkg
    /// too; it is recorded rather than raised so the 161 packages that already
    /// installed are still reported. `Report.artifacts_error` has the errno.
    plan_failed,
    /// The caller asked for `artifacts = false`. The only value here that does
    /// NOT make `ok()` false, because it is what was asked for.
    disabled,
};

/// Why step 8 did not run. Null means it did.
///
/// Every value here is a case where Pkg would also not have precompiled — or,
/// for `not_instantiated`, one where Pkg never gets that far because the step
/// before it threw. They are named individually rather than collapsed into a
/// bool because "you turned it off" and "the install failed so there was
/// nothing worth compiling" are the same silence otherwise, and only one of
/// them is a problem.
pub const PrecompileSkipped = enum {
    /// `allow_autoprecomp = false` — the caller asked for no pass. What
    /// `ops/edit.zig` passes for its install pass, and what `--no-precompile`
    /// sets.
    disabled,
    /// `JULIA_PKG_PRECOMPILE_AUTO` parsed falsy (`Pkg.jl:65`).
    env_disabled,
    /// `dry_run`. Julia has no dry run; the flag's contract is that it creates
    /// nothing under the depot, and a `.ji` is very much something.
    dry_run,
    /// `Report.ok()` or `Report.converged()` came back false. Pkg's
    /// `download_source` THROWS on a failed download (`Operations.jl:1112-1247`)
    /// so `_auto_precompile` is never reached; Ajt reports failures instead of
    /// throwing, and running the compile pass anyway would turn one 404 into a
    /// `source_missing` line per package.
    ///
    /// This is deliberately the WIDER of the two conditions, and the width has
    /// a cost worth naming: `ok()` also covers a failed
    /// `logs/manifest_usage.toml` write and an `Artifacts.toml` Pkg would have
    /// thrown on, and `converged()` covers a stdlib cross-check that could not
    /// run for want of a `julia_prefix`. That last one is a case where Pkg
    /// WOULD still precompile. Skipping is the conservative side of a divergence
    /// with no good answer — the alternative is a compile pass over an
    /// environment nothing has verified — and the CLI supplies a prefix on
    /// every invocation, so it is not reachable from `ajt instantiate`.
    not_instantiated,
    /// `JULIA_DEPOT_PATH=""`. Nowhere to write a cache entry.
    no_depot,
};

/// One `write_env_usage` call.
///
/// Julia catches its own write failure, `@error`s it and returns normally
/// (`Types.jl:722-724`), so a log that could not be written does not fail the
/// operation — the packages are on disk either way and the only consequence is
/// that a later `Pkg.gc()` may collect them. `usage.record` matches that, which
/// leaves `err` set only for the failures Julia does NOT swallow: a
/// `scratch_usage.toml` request, no current directory, OOM, cancellation.
///
/// Those are raised by `record` rather than returned, and letting them out of
/// `run` would discard the whole Report — every package result, both verify
/// passes — so they are caught and recorded here, with `ok()` reading them.
pub const UsageStep = struct {
    /// Keys stamped, after non-existent sources are filtered (`Types.jl:674`).
    /// Zero with no error means there was nothing to record, which is the
    /// normal outcome for an environment whose manifest does not exist yet.
    keys: usize = 0,
    /// False when the write was attempted and failed — a read-only depot, a
    /// full disk, a lock held by a wedged peer. Not an error (see above), but
    /// it IS the difference between a depot `Pkg.gc()` spares and one it eats,
    /// so the fallback gates assert on it.
    written: bool = false,
    err: ?[]const u8 = null,

    pub fn ok(self: UsageStep) bool {
        return self.err == null;
    }
};

pub const Report = struct {
    project_file: []const u8 = "",
    manifest_file: []const u8 = "",
    /// Entries in the file. All of them are written back; only the pruned
    /// subset is downloaded.
    entries: usize = 0,
    /// Entries `prune_manifest` drops — trap 1 in the module header.
    pruned: usize = 0,

    /// `is_instantiated` before and after. `before` also supplies the located
    /// project/manifest paths, so the probe order lives in exactly one module.
    ///
    /// Under `dry_run`, `after` IS `before`: nothing was changed, so nothing
    /// was re-measured, and `converged()` therefore answers the question "was it
    /// already instantiated?" rather than "did this run instantiate it?".
    before: verify.Report = .{},
    after: verify.Report = .{},

    registry: RegistryStep = .{},

    /// `download_source`'s `pkgs_to_install`, before the depot is consulted.
    package_jobs: []const pkgs.Job = &.{},
    /// Empty under `dry_run`.
    packages: []const pkgs.Result = &.{},

    /// `download_artifacts`' `pkg_roots` (`Operations.jl:930-936`).
    package_roots: usize = 0,
    artifact_jobs: []const arts.Job = &.{},
    /// Empty under `dry_run`.
    artifacts: []const arts.Result = &.{},
    /// `Artifacts.toml` files Pkg itself would have thrown on.
    artifact_problems: []const arts.FileProblem = &.{},
    artifacts_skipped: ?ArtifactsSkipped = null,
    /// The error behind `artifacts_skipped == .plan_failed`.
    artifacts_error: ?[]const u8 = null,

    fixups: []const pkgs.Fixup = &.{},
    /// Entries the fixups pass could not locate because no `stdlib_dir` was
    /// known. Julia cannot reach this state; it is a gap in what the caller
    /// supplied, so it is counted rather than swallowed.
    stdlib_skipped: usize = 0,
    /// True only when the rendered manifest differed from the file on disk.
    manifest_written: bool = false,

    /// `<depot>/logs/manifest_usage.toml` — `Types.jl:426`, stamped by the
    /// `EnvCache` constructor, so Pkg records it on every environment load.
    usage_manifest: UsageStep = .{},
    /// `<depot>/logs/artifact_usage.toml` — `Operations.jl:1080`, the last
    /// statement of `download_artifacts`.
    usage_artifact: UsageStep = .{},

    /// Step 8, when it ran. Null means it did not, and `precompile_skipped`
    /// says why.
    precompile: ?precompile_mod.Report = null,
    precompile_skipped: ?PrecompileSkipped = null,

    dry_run: bool = false,
    /// Set when the run stopped before doing anything, because no download can
    /// fix the problem: an unreadable project, an unparseable manifest, a
    /// workspace, or a direct dependency with no manifest entry.
    blocked: ?verify.Problem = null,

    /// Did every step that ran succeed?
    ///
    /// Deliberately does NOT include `after.ok()`: converging is a separate
    /// question with a separate answer (`converged`), because an environment
    /// can be installed perfectly and still fail to verify — a `[sources]` git
    /// checkout this unit does not implement, or a Julia installation it could
    /// not find to check the stdlib entries against.
    ///
    /// `artifact_problems` counts: a non-empty list means Pkg would have THROWN
    /// on that `Artifacts.toml` (`SHA1(meta["git-tree-sha1"])`,
    /// `Artifacts.jl:458`), so an install that quietly skipped the entry and
    /// reported success would be claiming an environment Pkg refuses to load.
    ///
    /// `stdlib_skipped` deliberately does not, because it cannot occur alone:
    /// it is set exactly when no `stdlib_dir` was known, which is the same
    /// condition that makes `verify`'s stdlib cross-check unavailable — so
    /// `converged()` is already false and the CLI already exits non-zero.
    pub fn ok(self: Report) bool {
        if (self.blocked != null) return false;
        if (self.artifacts_skipped) |why| switch (why) {
            .disabled => {},
            .no_host, .plan_failed => return false,
        };
        if (self.artifact_problems.len != 0) return false;
        for (self.packages) |p| {
            if (!p.ok()) return false;
        }
        for (self.artifacts) |a| {
            if (a.outcome == .failed) return false;
        }
        if (!self.usage_manifest.ok() or !self.usage_artifact.ok()) return false;
        // A failed auto-precompile counts. `Pkg.precompile` raises on a
        // non-empty `failed_deps`, and it is called from the last statement of
        // `Pkg.instantiate` (`API.jl:1398`), so an environment whose packages
        // will not compile makes `Pkg.instantiate()` throw. Reporting success
        // here would be claiming an environment Pkg refuses to finish.
        //
        // Not in `converged()`: that answers "does the depot satisfy the
        // manifest", which is true whether or not a `.ji` exists.
        if (self.precompile) |p| {
            if (!p.ok()) return false;
        }
        return true;
    }

    /// Does the environment now satisfy `is_instantiated`, i.e. would
    /// `Pkg.instantiate()` do nothing?
    ///
    /// `verify` answers most of that but **deliberately does not check
    /// artifacts** (`verify.zig`'s divergence 1), while Julia's
    /// `is_instantiated` runs `check_artifacts_downloaded` on every package root
    /// and on the project directory (`Operations.jl:209-221` via
    /// `is_package_downloaded`). Delegating to `verify` alone would therefore
    /// answer `true` for an environment with every JLL missing — a green exit
    /// code on a depot that fails at the first `dlopen`. So the artifact half is
    /// folded in here: every planned artifact must have ended up present, and a
    /// step that could not run at all counts as not converged.
    ///
    /// `artifacts = false` is the one exception. The caller opted out, so this
    /// answers for the package half only; that is stated rather than hidden
    /// because it is the one configuration where a `true` here does not mean
    /// `Pkg.instantiate()` would be silent.
    pub fn converged(self: Report) bool {
        if (self.blocked != null) return false;
        if (!self.after.ok()) return false;
        if (self.artifacts_skipped) |why| switch (why) {
            .disabled => return true,
            .no_host, .plan_failed => return false,
        };
        if (self.artifact_problems.len != 0) return false;
        // Under `dry_run` nothing was installed, so the plan itself is the
        // answer: an artifact already `present` needs no download.
        if (self.dry_run) {
            for (self.artifact_jobs) |j| {
                if (!j.present) return false;
            }
            return true;
        }
        for (self.artifacts) |a| {
            if (a.outcome == .failed) return false;
        }
        // One result per planned job, or the pool lost one.
        return self.artifacts.len == self.artifact_jobs.len;
    }

    /// Packages this run actually fetched (as opposed to found in the depot).
    ///
    /// A `switch` rather than an `==` so that adding an outcome is a compile
    /// error here: `installed_git` was added after this function and a
    /// two-branch test would have silently reported "1 job, 0 installed" for
    /// every cloned package.
    pub fn installedCount(self: Report) usize {
        var n: usize = 0;
        for (self.packages) |p| switch (p.outcome) {
            .installed, .installed_git => n += 1,
            .already_present, .needs_git_clone, .failed => {},
        };
        return n;
    }

    /// Artifacts this run actually downloaded.
    pub fn artifactsInstalledCount(self: Report) usize {
        var n: usize = 0;
        for (self.artifacts) |a| {
            if (a.outcome == .installed) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

/// Instantiate `opts.env_path` into `opts.stack`.
///
/// Per-item failures never abort: one 404'd package must not stop the other
/// 160, and one artifact must not stop the other 81. They are reported in
/// `Report.packages` / `Report.artifacts`; use `Report.ok()` to collapse them.
/// The errors that DO propagate are the ones about the machine rather than
/// about a mirror — out of memory, cancellation, an unwritable depot.
///
/// The error set is inferred: this function fans out into four modules whose
/// sets have little in common, and enumerating their union here would be a
/// list that goes stale rather than a contract anyone reads.
pub fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    registry: Registry,
) !Report {
    var rep: Report = .{ .dry_run = opts.dry_run };

    const vopts: verify.Options = .{
        .env_path = opts.env_path,
        .manifest_file = opts.manifest_file,
        .stack = opts.stack,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    };

    // ---- 0. where are we, and is there anything to do? --------------------
    //
    // `verify` owns the `Types.projectfile_path`/`manifestfile_path` probe
    // order (including the version-specific `Manifest-v1.12.toml` names), so
    // this is also how the two files are LOCATED — a second copy of that probe
    // is a second chance to read a file nobody loads.
    rep.before = try verify.run(arena, gpa, io, vopts);
    rep.project_file = rep.before.project_file;
    rep.manifest_file = rep.before.manifest_file;

    // `write_env_usage(manifest_file, "manifest_usage.toml")` (`Types.jl:426`).
    //
    // Placed here for the same reason Julia places it in the `EnvCache`
    // constructor: it runs as soon as the manifest PATH is known, before the
    // file is parsed, so an unparseable manifest is still recorded as live.
    // Without this stamp `Pkg.gc()` treats every package this run installs as
    // unreferenced and deletes it.
    //
    // Divergence, deliberate: `dry_run` skips it. Julia has no dry run, and
    // 206's contract for the flag is that it creates nothing under the depot —
    // the same rule that stops `--dry-run` from taking a lock in `registries/`.
    if (!opts.dry_run) rep.usage_manifest = recordUsage(
        gpa,
        io,
        opts.stack,
        usage.manifest_log,
        &.{rep.manifest_file},
    );

    if (blocking(rep.before)) |p| {
        rep.blocked = p;
        return rep;
    }

    // ---- read the two models ----------------------------------------------
    //
    // `verify` parsed both and kept neither; re-reading a few hundred KB is
    // cheaper than widening its Report into a model cache that only this
    // caller wants.
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
    var manifest = manifest_mod.parse(arena, manifest_src, &mdiag) catch |err| {
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

    const manifest_dir = fspath.dirname(rep.manifest_file) orelse ".";
    const project_dir = fspath.dirname(rep.project_file) orelse ".";

    // ---- 1. prune_manifest -------------------------------------------------
    //
    // A VIEW, not a replacement: `manifest` keeps all its entries, because it
    // is the thing step 6 writes back. See trap 1. Null from `pruneKeep` is
    // "this environment is not pruned at all" — see its doc comment.
    var pruned_view = manifest;
    if (try pruneKeep(arena, project, manifest, project_dir, manifest_dir)) |keep| {
        var kept: std.ArrayList(manifest_mod.PackageEntry) = .empty;
        for (manifest.entries) |e| {
            if (keep.contains(e.uuid.bytes)) try kept.append(arena, e) else rep.pruned += 1;
        }
        pruned_view.entries = kept.items;
    }

    // ---- 2. every direct dep has an entry (API.jl:1327-1334) ---------------
    //
    // A `pkgerror` in Pkg, and rightly: the manifest cannot pin what it does
    // not mention, so no amount of downloading fixes it.
    for (project.deps.entries.items) |d| {
        if (manifest.findByUuid(d.uuid) == null) {
            rep.blocked = .{
                .kind = .direct_dep_unmanifested,
                .subject = d.name,
                .detail = "resolve to populate the manifest",
            };
            return rep;
        }
    }

    // ---- what is actually missing? ----------------------------------------
    //
    // `download_source`'s `ispath(path) && continue` (`Operations.jl:1118`),
    // asked here rather than inside `install`, because it is also the answer to
    // "does anything have to be looked UP?" — and therefore whether step 3
    // needs to happen at all.
    //
    // **A `repo-url` entry is missing too, but it does not count HERE**, and
    // the distinction is the whole reason this loop skips it rather than the
    // `path` test alone doing so. Such an entry is installed by cloning the URL
    // it already names (`API.jl:1358-1390`), so a registry cannot help it, and
    // Pkg agrees: `check_registered` filters to `tracking_registered_version`
    // before asking any registry anything (`Operations.jl:1637`). That it is
    // missing at all is enforced downstream — `jobsFromManifest` emits a job
    // for it and `verify` reports `package_missing` until it is on disk.
    var missing: usize = 0;
    for (pruned_view.entries) |e| {
        const th = e.tree_hash orelse continue;
        if (e.path != null or e.repo_url != null) continue;
        const found = try depot_mod.findInstalled(arena, io, opts.stack, e.name, e.uuid, th);
        if (!found.exists) missing += 1;
    }

    // ---- 3. the registry ---------------------------------------------------
    if (missing != 0) try ensureRegistry(gpa, arena, io, opts, &rep);

    // ---- 4. download_source ------------------------------------------------
    //
    // With nothing missing, the candidate URLs are never consulted — every job
    // resolves to `already_present` from the depot lookup alone — so the
    // registry is not opened at all. On the `.aix` backend that is an mmap
    // saved; on the archive backend it is an 84 MB re-parse saved, on the exact
    // path (a second `instantiate`) where the whole point is to be fast.
    const repo_lookup = if (missing == 0 and !opts.dry_run) pkgs.RepoLookup.none else registry.open(registry.ctx);
    rep.package_jobs = try pkgs.jobsFromManifest(arena, &pruned_view, repo_lookup, manifest_dir);

    // One server for the whole run. The package candidate list, the registry
    // download and the artifact mirror list must not be able to disagree about
    // which server they were built for — that is why `install_packages` also
    // overwrites `net.server` from `Options.server` rather than letting the two
    // coexist. A caller that set only `net.server` has it adopted rather than
    // silently dropped; a caller that genuinely wants the protocol OFF
    // (`JULIA_PKG_SERVER=""`) sets both to null, which is what the CLI does.
    const server = opts.server orelse opts.net.server;
    var net_config = opts.net;
    net_config.server = server;

    if (!opts.dry_run and rep.package_jobs.len != 0) {
        rep.packages = try pkgs.install(gpa, arena, io, opts.stack, rep.package_jobs, .{
            .server = net_config.server,
            .net = net_config,
            .concurrency = @max(opts.jobs, 1),
            // Null leaves the archive-only behaviour: a `repo-url` entry, and
            // anything no mirror can serve, comes back `needs_git_clone`.
            .git = opts.git,
        });
    }

    // ---- the Julia installation, for steps 5 and 6 -------------------------
    const julia_version = opts.julia_version orelse blk: {
        const v = manifest.julia_version orelse break :blk null;
        break :blk try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    };
    const stdlib_dir = opts.stdlib_dir orelse try resolveStdlibDir(arena, io, opts.julia_prefix, julia_version);

    // ---- 5. download_artifacts ---------------------------------------------
    if (!opts.artifacts) {
        rep.artifacts_skipped = .disabled;
    } else if (try hostPlatform(arena, io, opts, julia_version)) |host| {
        const roots = try packageRoots(arena, io, .{
            .stack = opts.stack,
            .project = project,
            .entries = pruned_view.entries,
            .manifest_dir = manifest_dir,
            .project_dir = project_dir,
            .stdlib_dir = stdlib_dir,
        });
        rep.package_roots = roots.len;

        // Recorded, not raised. `collect_artifacts` propagates an unreadable
        // `Artifacts.toml` (`install_artifacts.zig`'s `PlanError`), and letting
        // that out of `run` would return NO Report at all — throwing away the
        // 161 package results, the registry step and both verify reports over
        // one file. `ok()` is false either way.
        const plan = arts.plan(arena, gpa, io, opts.stack.entries, roots, host, .{
            .include_lazy = opts.include_lazy,
            .honor_overrides = opts.honor_overrides,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => blk: {
                rep.artifacts_skipped = .plan_failed;
                rep.artifacts_error = @errorName(err);
                // `artifact_tomls` empty is the honest value here: the plan
                // failed, so we do not know which files were read, and
                // stamping a guess into `logs/artifact_usage.toml` would pin
                // artifacts we never installed.
                break :blk arts.Plan{
                    .jobs = &.{},
                    .problems = &.{},
                    .artifact_tomls = &.{},
                    .overrides = .init(arena),
                };
            },
        };
        rep.artifact_jobs = plan.jobs;
        rep.artifact_problems = plan.problems;

        if (!opts.dry_run and rep.artifacts_skipped == null) {
            rep.artifacts = try installArtifacts(gpa, arena, io, .{
                .config = net_config,
                .depots = opts.stack.entries,
                .jobs = plan.jobs,
                .concurrency = @max(opts.jobs, 1),
            });

            // `return write_env_usage(used_artifact_tomls, "artifact_usage.toml")`
            // — the last statement of `download_artifacts` (`Operations.jl:1080`),
            // reached only when nothing failed: the `pkgerror` at `:1075` throws
            // first. Ajt reports failures rather than throwing, so the condition
            // Julia gets from control flow is spelled out.
            //
            // The list is `plan.artifact_tomls`, every file READ — not one per
            // job. A package whose artifacts are all lazy or all already present
            // yields no job and still pins its artifacts.
            var any_failed = false;
            for (rep.artifacts) |a| {
                if (a.outcome == .failed) any_failed = true;
            }
            if (!any_failed) rep.usage_artifact = recordUsage(
                gpa,
                io,
                opts.stack,
                usage.artifact_log,
                plan.artifact_tomls,
            );
        }
    } else {
        rep.artifacts_skipped = .no_host;
    }

    // ---- 6. fixups_from_projectfile! ---------------------------------------
    if (opts.fixups and !opts.dry_run) {
        rep.fixups = try pkgs.fixupsFromProjectFile(gpa, arena, io, opts.stack, &manifest, .{
            .manifest_dir = manifest_dir,
            .stdlib_dir = stdlib_dir,
        });
        for (rep.fixups) |f| {
            if (f.skipped == .stdlib_dir_unknown) rep.stdlib_skipped += 1;
        }
        if (opts.write_manifest) {
            rep.manifest_written = try writeIfChanged(gpa, io, &manifest, rep.manifest_file, manifest_src);
        }
    }

    // ---- 7. converge -------------------------------------------------------
    //
    // Re-asked rather than inferred. Everything above reports what it BELIEVES
    // it did; this is the only statement in the Report that was measured
    // against the depot afterwards, and it is the one the caller acts on.
    rep.after = if (opts.dry_run) rep.before else try verify.run(arena, gpa, io, vopts);

    // ---- 8. _auto_precompile ----------------------------------------------
    //
    // `allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)`
    // — the last statement of `Pkg.instantiate` (`API.jl:1398`).
    //
    // `already_instantiated = true` is why there is no re-entry here: it is
    // what stops `Pkg.precompile` from calling `instantiate` back
    // (`API.jl:1248-1250`), and steps 0-7 above ARE that instantiate.
    try autoPrecompile(gpa, arena, io, opts, &rep);
    return rep;
}

/// Step 8, split out only so `run`'s tail stays readable.
///
/// Every early return records WHY in `rep.precompile_skipped`; a silent one
/// would make "precompiled nothing because there was nothing to do" and
/// "precompiled nothing because a flag said not to" indistinguishable in a
/// build log, and those two have different fixes.
fn autoPrecompile(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    rep: *Report,
) !void {
    if (!opts.precompile) {
        rep.precompile_skipped = .disabled;
        return;
    }
    if (opts.dry_run) {
        rep.precompile_skipped = .dry_run;
        return;
    }
    if (!precompile_mod.autoEnabled(opts.environ)) {
        rep.precompile_skipped = .env_disabled;
        return;
    }
    if (opts.stack.writeDepot() == null) {
        rep.precompile_skipped = .no_depot;
        return;
    }
    // The install has to have LANDED. `ok()` covers the failed downloads and
    // `converged()` the environment as a whole; either one false means the
    // compile pass would be reporting `source_missing` for packages whose real
    // problem is already in this Report.
    if (!rep.ok() or !rep.converged()) {
        rep.precompile_skipped = .not_instantiated;
        return;
    }

    rep.precompile = try precompile_mod.run(gpa, arena, io, .{
        // The project file `verify` located, not `opts.env_path`: a `--manifest`
        // pointing elsewhere, or an environment given as a directory, must
        // resolve to the same pair both halves of this function used.
        .env_path = rep.project_file,
        .manifest_file = rep.manifest_file,
        .stack = opts.stack,
        .julia_exe = opts.julia_exe,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
        .environ = opts.environ,
        .jobs = opts.precompile_jobs,
        .cache_url = opts.precompile_cache_url,
    });
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// `write_env_usage`, reported rather than raised. See `UsageStep`.
///
/// Writes to `depots1()` only — `Pkg.logdir()` takes no depot argument and
/// resolves to the first entry (`Pkg/src/Pkg.jl:41`), so a stacked depot
/// records usage in the writable head and nowhere else.
fn recordUsage(
    gpa: Allocator,
    io: Io,
    stack: depot_mod.Stack,
    log_name: []const u8,
    sources: []const []const u8,
) UsageStep {
    const write_depot = stack.writeDepot() orelse return .{
        // `JULIA_DEPOT_PATH=""` is a real configuration, and Pkg raises "no
        // depots provided" rather than picking one. Nothing was installed
        // either, so there is nothing to protect from `gc`.
        .err = "NoDepot",
    };
    if (sources.len == 0) return .{};

    const done = usage.record(gpa, io, write_depot.root, log_name, sources, .{}) catch |err| {
        return .{ .err = @errorName(err) };
    };
    return .{ .keys = done.keys, .written = done.written };
}

/// Problems that no amount of downloading fixes, i.e. the ones `instantiate`
/// must not paper over.
///
/// Everything else is deliberately NOT here, and each omission is a case where
/// Pkg carries on:
///
///   * `project_hash_mismatch` — `instantiate` only `@warn`s (`API.jl:1321`).
///     The manifest is still authoritative; that is what `--frozen` means.
///   * `manifest_hash_absent` — `is_manifest_current` returns `nothing` and
///     `API.jl:1321` treats that as "not false".
///   * `package_missing` / `dev_path_missing` — the entire reason to run.
///   * `stdlib_check_unavailable` — costs the converge verdict, not the work.
///
/// `verify` short-circuits on the two hash cases, so when one of them fires the
/// report below has not looked at anything else. That is why the direct-dep
/// check is repeated in `run` against the parsed models rather than read out of
/// this report.
fn blocking(rep: verify.Report) ?verify.Problem {
    for (rep.problems) |p| switch (p.kind) {
        .project_unreadable,
        .project_invalid,
        .workspace_unsupported,
        .manifest_unreadable,
        .manifest_invalid,
        .direct_dep_unmanifested,
        => return p,
        else => {},
    };
    return null;
}

/// `Operations.prune_manifest(env)`'s `keep` set (`Operations.jl:1252-1271`),
/// closed over each entry's own STRONG `deps` by `prune_deps`
/// (`Operations.jl:1279-1293`).
///
/// **Null means "do not prune at all".** `prune_manifest` only prunes in its
/// `else` branch: when the project redirects to a manifest in a DIFFERENT
/// directory and there is no workspace, it instead rewrites that one entry's
/// deps and leaves every other entry alone (`:1254-1257`). So a `manifest =
/// "../shared/Manifest.toml"` project — which `verify.locateManifest` supports,
/// and which `--manifest` reaches directly — installs its whole manifest,
/// unreachable entries included. Pruning it anyway would build a strictly
/// smaller download set than `Pkg.instantiate` and leave the environment
/// un-instantiated in a way nothing else in this pipeline would notice.
///
/// The directory comparison is a plain string compare of `dirname`, exactly as
/// Julia's is: `EnvCache` stores the paths it computed and never realpaths them
/// for this test, so a relative `--manifest` alongside an absolute project file
/// reads as "redirected" in both implementations.
///
/// Two differences from `verify.loadable`, both from `prune_manifest` seeding
/// `keep` differently than `load_all_deps_loadable` does:
///
///   * the project's own uuid joins the set when the environment is a package
///     (`:1259-1261`) — trap 2 in the module header. `env.pkg` is non-null only
///     when the project has BOTH a name and a uuid (`Types.jl:400-409`), and
///     `validate` does not require a name alongside a uuid, so a nameless
///     project with a uuid is legal and must NOT seed the set;
///   * workspace member projects contribute their deps (`:1262-1267`), which
///     is moot because `verify` refuses a workspace root outright in step 0.
///
/// Weakdeps are not traversed: `prune_deps` walks `entry.deps` only, so an
/// extension's trigger is pulled in only when something depends on it strongly.
/// That is the whole of why the `Vulkan` family is not installed.
fn pruneKeep(
    arena: Allocator,
    project: project_mod.Project,
    manifest: manifest_mod.Manifest,
    project_dir: []const u8,
    manifest_dir: []const u8,
) Allocator.Error!?std.AutoHashMapUnmanaged([16]u8, void) {
    if (!std.mem.eql(u8, project_dir, manifest_dir)) return null;

    var keep: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    for (project.deps.entries.items) |d| try keep.put(arena, d.uuid.bytes, {});
    if (project.uuid) |u| {
        if (project.name != null) try keep.put(arena, u.bytes, {});
    }

    // The fixpoint, not one pass: entry order is arbitrary in Julia's Dict, so
    // a single sweep would be order-dependent.
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

/// Step 3. Never fatal — see `RegistryStep.err`.
fn ensureRegistry(gpa: Allocator, arena: Allocator, io: Io, opts: Options, rep: *Report) !void {
    rep.registry.name = opts.registry_name;
    // `opts.net.offline` is the offline bit for this whole operation — the
    // downloads below read it off the same Config — so the registry step reads
    // it from there too rather than from a field of its own.
    if (opts.registry_policy.effective(opts.net.offline) == .never) return;

    const depot = opts.registry_depot orelse blk: {
        const d = opts.stack.writeDepot() orelse {
            rep.registry.err = "no depot to install a registry into";
            return;
        };
        break :blk d.root;
    };

    // Is one already there? `readInstalled` recognises BOTH layouts — the
    // `<Name>.toml` stamp and the unpacked `<Name>/.tree_info.toml` — which is
    // the check `reachable_registries` makes (`registry_instance.jl:437-455`).
    // Looking for only one of them made `registry update` fail forever after an
    // `--unpack` install; that bug is not worth re-introducing here.
    const installed: ?regops.Installed = blk: {
        const regdir_path = try fspath.join(arena, &.{ depot, "registries" });
        var regdir = Io.Dir.cwd().openDir(io, regdir_path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => break :blk null,
        };
        defer regdir.close(io);
        // Cancellation must not read as "no registry installed": that would
        // flip the mode from `update` to `add` and re-download 11 MB. (OOM is
        // not in `readInstalled`'s error set — it already folds an allocation
        // failure into `null` itself, which is that module's call to make.)
        break :blk regops.readInstalled(arena, io, regdir, opts.registry_name) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
    };
    if (installed != null and opts.registry_policy == .if_missing) return;

    rep.registry.attempted = true;

    // `registry_ops.run` honours `dry_run` for the DOWNLOAD, but it still
    // `mkpath`s `registries/`, takes the directory lock and fetches the server
    // index before it gets there — three writes and a round trip that a dry run
    // has no business making, one of them into the user's real depot if that is
    // what `--registry-depot` points at. So the whole call is skipped and the
    // verdict is derived from what is on disk.
    //
    // The cost is one bit of precision: without the server's index we cannot
    // tell an installed registry that is stale from one that is current, so
    // `.always` on an installed registry reports `would_update` rather than
    // possibly `would_be_up_to_date`.
    if (opts.dry_run) {
        rep.registry.action = if (installed != null) .would_update else .would_add;
        return;
    }

    var config = opts.net;
    config.server = opts.server orelse opts.net.server;
    // The bearer token and the metadata headers belong to the depot being
    // written, which for a registry is the one that owns `registries/` and not
    // necessarily `depots1()`.
    config.depot = depot;

    var client: net_http.Client = .init(gpa, io, config);
    defer client.deinit();

    const r = regops.run(gpa, arena, io, &client, .{
        .mode = if (installed != null) .update else .add,
        .depot = depot,
        .name = opts.registry_name,
        .server = config.server,
        .unpack_env = opts.unpack_registry,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        // Everything else — no server, not on the server, a 500, a bad
        // tarball — costs the GitHub fallback and nothing more.
        else => {
            rep.registry.err = @errorName(err);
            return;
        },
    };
    rep.registry.action = r.action;
    rep.registry.name = r.name;
}

const RootsRequest = struct {
    stack: depot_mod.Stack,
    project: project_mod.Project,
    entries: []const manifest_mod.PackageEntry,
    manifest_dir: []const u8,
    project_dir: []const u8,
    stdlib_dir: ?[]const u8,
};

/// `download_artifacts`' `pkg_roots` (`Operations.jl:930-936`): `source_path`
/// of every (pruned) manifest entry, plus `dirname(env.project_file)`.
///
/// That last one is not decoration — an environment that is itself a package
/// can carry its own `Artifacts.toml`, and `is_instantiated` checks it
/// separately — as a synthetic `path` entry when it IS a package
/// (`Operations.jl:209-215`), and through a bare `check_artifacts_downloaded`
/// when it is not (`:216-219`).
///
/// `Package.uuid` is left null on purpose: `collect_artifacts` calls
/// `select_downloadable_artifacts` WITHOUT `pkg_uuid` (`Operations.jl:901`), so
/// stock Pkg's download path never resolves a UUID/name override. Supplying one
/// here would install a different artifact than Pkg installs.
fn packageRoots(arena: Allocator, io: Io, req: RootsRequest) ![]const arts.Package {
    var out: std.ArrayList(arts.Package) = .empty;
    for (req.entries) |e| {
        const p = (try sourcePath(arena, io, req, e)) orelse continue;
        try out.append(arena, .{ .root = p, .uuid = null });
    }
    try out.append(arena, .{ .root = req.project_dir, .uuid = null });
    return out.items;
}

/// `Operations.source_path(manifest_file, pkg, julia_version)`
/// (`Operations.jl:48-53`), with the `[sources]` override `load_all_deps`
/// applies first (`Operations.jl:174-179`).
///
/// Branch order is the whole rule, and it is the same order `verify` walks for
/// the same reason: an entry carrying BOTH a tree hash and a `path` is located
/// by the tree hash, so taking the path branch would hand `collect_artifacts` a
/// directory that is not where the package is.
///
/// The tree-hash branch returns the WOULD-BE path even when nothing is
/// installed there, exactly as `find_installed` does; `collect_artifacts` then
/// finds no `Artifacts.toml` and contributes nothing, which is the same outcome
/// as skipping it and one branch fewer.
fn sourcePath(
    arena: Allocator,
    io: Io,
    req: RootsRequest,
    e: manifest_mod.PackageEntry,
) !?[]const u8 {
    // `[sources]` CLEARS the tree hash, so it outranks everything. Its path is
    // PROJECT-relative and gets rebased onto the manifest by `get_path_repo`
    // (`project.jl:7-25`, via `project_path_to_manifest_path`,
    // `Types.jl:446-450`) before `source_path` joins it back to
    // `dirname(manifest_file)` — net effect, project-relative, which is what is
    // done directly here. A manifest entry's own `path` is manifest-relative
    // already; the two directories differ the moment a `manifest = "..."`
    // redirect separates them.
    if (req.project.sourceFor(e.name)) |s| {
        if (s.path) |p| return try fspath.resolve(arena, &.{ req.project_dir, p });
    }
    if (e.tree_hash) |th| {
        const found = try depot_mod.findInstalled(arena, io, req.stack, e.name, e.uuid, th);
        return found.path;
    }
    if (e.path) |p| return try fspath.resolve(arena, &.{ req.manifest_dir, p });

    // Julia's last branch is `is_or_was_stdlib(uuid) ? stdlib_path(name) :
    // nothing`, keyed on the UUID. Testing for the DIRECTORY instead is weaker
    // in one direction only: a non-stdlib entry that happens to share a name
    // with a stdlib would contribute that stdlib's root. It cannot change what
    // is installed — no stdlib in Julia 1.12.6 ships an `Artifacts.toml` at all
    // (measured: 0 of the 43 stdlib roots in the Open-Reality environment) —
    // and it avoids loading the whole stdlib set for a list of directories.
    const dir = req.stdlib_dir orelse return null;
    const cand = try fspath.join(arena, &.{ dir, e.name });
    const st = Io.Dir.cwd().statFile(io, cand, .{}) catch |err| switch (err) {
        // A cancelled stat is not "no such stdlib"; it is a run that should
        // stop. Everything else — missing, ENOTDIR, permission — is a no.
        error.Canceled => return error.Canceled,
        else => return null,
    };
    if (st.kind != .directory) return null;
    return cand;
}

const ArtifactRequest = struct {
    config: net_http.Config,
    depots: []const []const u8,
    jobs: []const arts.Job,
    concurrency: u32,
    opts: arts.InstallOptions = .{},
};

/// `install_artifacts.installAll`, driven by a pool instead of a loop.
///
/// **Why this is not just a call to `installAll`.** That function is the gated
/// entry point and it is serial by construction: "`installJob` over a whole
/// plan, in plan order". Pkg is not — `download_artifacts` builds a
/// `Dict{SHA1, Function}` of download jobs and `Threads.@spawn`s them behind
/// `Base.Semaphore(ctx.num_concurrent_downloads)` (`Operations.jl:1023-1060`),
/// i.e. the same width `download_source` gets, out of a semaphore of its own —
/// and on a real environment the difference is not academic. Measured on
/// Open-Reality into an empty depot: 82 artifacts
/// totalling 516 MB, fetched serially, made a cold `ajt instantiate` take 88 s
/// against `Pkg.instantiate()`'s 55 s. The package half was already 8-wide, so
/// the artifacts were the whole gap — driving them at 8 too brings the same run
/// to 27 s.
///
/// So the per-JOB seam (`installJob`, public, and the same one `installAll`
/// calls) is reused and only the driver is new. The pool is the one
/// `install_packages.installWithCandidates` already proved, with the same three
/// rules that make it safe without a lock:
///
///   * `results` is allocated up front by this thread and every element is
///     written by exactly one worker — disjoint elements, never resized;
///   * each worker gets its OWN arena and its OWN `http.Client`, because
///     neither an arena nor a connection pool is threadsafe;
///   * work is claimed with one atomic `fetchAdd`, so a job cannot be dropped
///     or run twice.
///
/// The worker arenas are freed before returning, so everything the caller keeps
/// is copied into `arena` first. That copy is the reason this is not simply
/// `installAll` with a different allocator: a `Result` handed back borrowing a
/// worker arena would be freed memory the moment the pool tears down.
///
/// **`concurrency = 1` goes through the same pool** rather than falling back to
/// `installAll`, and that is deliberate: `installAll` does `try installJob(...)`
/// in a loop (`install_artifacts.zig:694-698`), so one artifact's
/// `depot.begin` failure aborts the whole run and `instantiate` returns an
/// error instead of a Report — losing the 161 package results that already
/// succeeded. The pool contains that per job. With one worker the pool IS the
/// loop: `workers[1..]` is empty and worker 0 runs inline on this thread.
fn installArtifacts(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    req: ArtifactRequest,
) ![]const arts.Result {
    if (req.jobs.len == 0) return &.{};

    const results = try arena.alloc(arts.Result, req.jobs.len);
    for (results, req.jobs) |*r, job| {
        r.* = .{ .job = job, .outcome = .failed, .path = "", .attempts = &.{} };
    }

    const n = @min(@as(usize, @max(req.concurrency, 1)), req.jobs.len);
    const workers = try gpa.alloc(ArtWorker, n);
    defer gpa.free(workers);
    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.deinit();
    while (made < n) : (made += 1) {
        workers[made] = .{ .arena_state = .init(gpa), .client = .init(gpa, io, req.config) };
    }

    var shared: ArtShared = .{
        .gpa = gpa,
        .io = io,
        .depots = req.depots,
        .jobs = req.jobs,
        .results = results,
        .opts = req.opts,
    };

    const futures = try gpa.alloc(?Io.Future(void), n);
    defer gpa.free(futures);
    @memset(futures, null);
    // Worker 0 runs inline, so a single-threaded `Io` needs no special case.
    for (workers[1..], futures[1..]) |*w, *f| {
        f.* = io.concurrent(runArtWorker, .{ &shared, w }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => null,
        };
    }
    runArtWorker(&shared, &workers[0]);
    for (futures[1..], workers[1..]) |*f, *w| {
        if (f.*) |*fut| fut.await(io) else runArtWorker(&shared, w);
    }

    // Off the worker arenas, before the `defer` above frees them.
    for (results) |*r| {
        r.path = try arena.dupe(u8, r.path);
        const atts = try arena.alloc(arts.Attempt, r.attempts.len);
        for (r.attempts, atts) |src, *dst| {
            dst.* = src;
            dst.url = try arena.dupe(u8, src.url);
            if (src.computed) |c| dst.computed = try arena.dupe(u8, c);
        }
        r.attempts = atts;
    }
    return results;
}

const ArtWorker = struct {
    /// Holds only the `Result`, its `Attempt` list and the source URLs — a few
    /// hundred bytes per job. The tarballs go through a scratch arena
    /// `installJob` builds from `gpa` and tears down per job, so a worker's
    /// peak is one archive however many mirrors it burns through.
    arena_state: std.heap.ArenaAllocator,
    client: net_http.Client,

    fn deinit(self: *ArtWorker) void {
        self.client.deinit();
        self.arena_state.deinit();
    }
};

const ArtShared = struct {
    gpa: Allocator,
    io: Io,
    depots: []const []const u8,
    jobs: []const arts.Job,
    results: []arts.Result,
    opts: arts.InstallOptions,
    cursor: std.atomic.Value(usize) = .init(0),
};

fn runArtWorker(shared: *ArtShared, w: *ArtWorker) void {
    while (true) {
        const i = shared.cursor.fetchAdd(1, .monotonic);
        if (i >= shared.jobs.len) return;
        shared.results[i] = arts.installJob(
            shared.gpa,
            w.arena_state.allocator(),
            shared.io,
            &w.client,
            shared.depots,
            shared.jobs[i],
            shared.opts,
        ) catch {
            // `InstallError` is the machine-level set — OOM, cancellation, a
            // depot that cannot be staged into. A worker has nowhere to return
            // it to, and unwinding the pool would throw away the other 81
            // results, so it lands as a failed artifact. `Report.ok()` is false
            // either way and the caller stops.
            //
            // The pre-seeded `.failed` value already says this; re-stating it
            // keeps the assignment total, so a future `installJob` that returns
            // without writing cannot leave a stale entry.
            shared.results[i] = .{
                .job = shared.jobs[i],
                .outcome = .failed,
                .path = "",
                .attempts = &.{},
            };
            continue;
        };
    }
}

/// `Types.stdlib_dir()` — `<prefix>/share/julia/stdlib/v<major>.<minor>`.
///
/// Taken from `stdlibs.load`'s own resolution rather than re-joined here: that
/// function also handles the version-less case by picking the highest
/// `v<major>.<minor>` directory that EXACTLY matches, which a naive join would
/// get wrong next to a `v1.13.0-DEV` sibling. Null when there is no Julia to
/// ask, which downgrades the fixups pass on stdlib entries to a counted skip.
///
/// `OutOfMemory` is re-raised rather than folded into that null. Swallowing it
/// would turn "the machine is out of memory" into "this Julia has no stdlibs",
/// and the consequence is not cosmetic: a null here makes step 6 skip every
/// stdlib entry and step 5 collect no stdlib package roots, and then the
/// manifest is WRITTEN in that degraded state. (`stdlibs.load` folds
/// cancellation into `ReadFailed` itself, so `Canceled` is not in its set.)
fn resolveStdlibDir(arena: Allocator, io: Io, prefix: ?[]const u8, version: ?[]const u8) !?[]const u8 {
    const p = prefix orelse return null;
    const set = stdlibs_mod.load(arena, io, .{
        .julia_prefix = p,
        .julia_version = version,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return set.dir;
}

/// The platform artifacts are selected for.
///
/// Always through `platform.detectHost`, which ends in `constructHost`. There
/// is no path in this module that assembles a tag list by hand: the
/// constructor's normalisation (auto `libc = glibc` on linux, arch aliasing,
/// `libstdcxx_version` rounding) is what `match_loss` ranks variants by, so a
/// hand-built host silently selects a different tarball.
fn hostPlatform(arena: Allocator, io: Io, opts: Options, julia_version: ?[]const u8) !?Platform {
    if (opts.host) |h| return h;
    const prefix = opts.julia_prefix orelse return null;
    const version = julia_version orelse return null;
    return platform_mod.detectHost(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = version,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Render the manifest and write it only if the bytes changed.
///
/// **The comparison is the point, not an optimisation.** `instantiate` is meant
/// to be run repeatedly — a container entrypoint runs it on every start — and a
/// write that only updates an mtime is indistinguishable, to everything
/// downstream, from a write that changed the pins. It is also what makes the
/// idempotence gate meaningful: a second run must leave every path, size and
/// mtime under the environment exactly as the first left them.
///
/// **The write is a rename, not a truncate.** `write_manifest` in Pkg opens the
/// file for writing and streams into it (`Types.jl:391-395`), so an interrupted
/// Pkg leaves a half-written manifest — every pin in the environment gone, and
/// no way to tell that from a manifest that was legitimately shortened. The
/// bytes are already fully rendered in memory before anything is opened here,
/// so writing them to a sibling and renaming costs one extra `link`-sized
/// operation and makes the failure mode "the old manifest is still there".
///
/// The render goes through a CHILD arena of `gpa`, never the report arena.
/// `Manifest.write` is `destructure(arena)` followed by `emit(gpa, ...)`
/// (`manifest.zig:360-364`), and `destructure` clones the entire manifest table
/// — all 214 entries — into whichever arena it is handed. Passing the report
/// arena would retain that clone for the lifetime of the whole run, for bytes
/// that are compared once and dropped.
/// Public because `ops/resolve.zig` writes manifests too and this is the only
/// correct way to do it — the tmp-file-and-rename, the render into a child
/// arena, and the "unchanged means do not touch the file" rule are all things
/// a second implementation would get subtly wrong rather than obviously wrong.
pub fn writeIfChanged(
    gpa: Allocator,
    io: Io,
    m: *const manifest_mod.Manifest,
    path: []const u8,
    current: []const u8,
) !bool {
    var render_arena: std.heap.ArenaAllocator = .init(gpa);
    defer render_arena.deinit();

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try m.write(gpa, render_arena.allocator(), &buf.writer);
    const rendered = buf.written();
    if (std.mem.eql(u8, rendered, current)) return false;

    // A SIBLING of the destination, so the rename cannot cross a filesystem.
    const dir_path = fspath.dirname(path) orelse ".";
    const base = fspath.basename(path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    // Entropy from `io`, the same source `depot.begin` uses for its staging
    // names — two concurrent instantiates of the same environment must not
    // collide on the temp file and then rename each other's half.
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name_buf: [".ajt-manifest-".len + 16 + ".tmp".len]u8 = undefined;
    @memcpy(name_buf[0..".ajt-manifest-".len], ".ajt-manifest-");
    _ = std.base64.url_safe_no_pad.Encoder.encode(name_buf[".ajt-manifest-".len..][0..16], &random_bytes);
    @memcpy(name_buf[".ajt-manifest-".len + 16 ..], ".tmp");
    const tmp_name: []const u8 = &name_buf;
    {
        var file = try dir.createFile(io, tmp_name, .{});
        errdefer dir.deleteFile(io, tmp_name) catch {};
        defer file.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.writeAll(rendered);
        try fw.interface.flush();
    }
    errdefer dir.deleteFile(io, tmp_name) catch {};
    try Io.Dir.rename(dir, tmp_name, dir, base, io);
    return true;
}

// ---------------------------------------------------------------------------
// Tests
//
// The oracle for the numbers quoted in this module's doc comment is a real
// `julia`, run by `tools/diff_harness/instantiate.sh`: 214/205/170/161 all came
// out of `Pkg.Operations.prune_manifest` on the real Open-Reality environment,
// and the end-to-end claim (a full instantiate into a fresh depot, after which
// `Pkg.instantiate()` does no work and `using OpenReality` loads) is only
// checkable there. What lives here is the hermetic half: the composition's
// decisions, on fixtures small enough to reason about, plus one test that pins
// this file's closure against `verify`'s so trap 2 cannot regress unnoticed.
// ---------------------------------------------------------------------------

const testing = std.testing;
const slug = @import("../julia/slug.zig");
const project_hash = @import("../julia/project_hash.zig");

/// A real, tiny environment: a project that is itself a package, one registry
/// package pinned by tree hash, a stdlib entry, and an entry reachable from
/// nothing at all.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,

    const proj_uuid = "11111111-2222-3333-4444-555555555555";
    const pkg_name = "StaticArrays";
    const pkg_uuid = "90137ffa-7385-5640-81b9-e52037218182";
    const pkg_tree = "0adf069a2a490c47273727e029371b31d44b72b2";
    const std_name = "LinearAlgebra";
    const std_uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e";
    const ghost_uuid = "99999999-8888-7777-6666-555555555555";

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

    /// The environment. `self_entry` puts the project's OWN uuid in the
    /// manifest, which is the shape trap 2 is about.
    fn writeEnv(self: *Fixture, self_entry: bool) ![]const u8 {
        const a = self.arena();
        const src = std.fmt.comptimePrint(
            \\name = "Fixture"
            \\uuid = "{s}"
            \\version = "0.1.0"
            \\
            \\[deps]
            \\StaticArrays = "{s}"
            \\LinearAlgebra = "{s}"
            \\
        , .{ proj_uuid, pkg_uuid, std_uuid });
        try self.write("env/Project.toml", src);

        const pdoc = try @import("../toml/parse.zig").parse(a, src, null);
        const hash = try project_hash.compute(a, pdoc.root);

        var m: std.ArrayList(u8) = .empty;
        try m.appendSlice(a, try std.fmt.allocPrint(a,
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
            \\[[deps.Ghost]]
            \\git-tree-sha1 = "1111111111111111111111111111111111111111"
            \\uuid = "{s}"
            \\version = "0.1.0"
            \\
        , .{ &hash, pkg_tree, pkg_uuid, std_uuid, ghost_uuid }));
        if (self_entry) {
            try m.appendSlice(a, std.fmt.comptimePrint(
                \\
                \\[[deps.Fixture]]
                \\path = "."
                \\uuid = "{s}"
                \\version = "0.1.0"
                \\
            , .{proj_uuid}));
        }
        try self.write("env/Manifest.toml", m.items);
        return self.join(&.{"env"});
    }

    fn installPackage(self: *Fixture) !void {
        var buf: [8]u8 = undefined;
        const s = slug.versionSlug(
            try slug.Uuid.parse(pkg_uuid),
            try slug.Sha1.parse(pkg_tree),
            &buf,
        );
        const sub = try fspath.join(self.arena(), &.{ "depot", "packages", pkg_name, s });
        try self.write(
            try fspath.join(self.arena(), &.{ sub, "src", pkg_name ++ ".jl" }),
            "module StaticArrays end\n",
        );
        try self.write(
            try fspath.join(self.arena(), &.{ sub, "Project.toml" }),
            "name = \"" ++ pkg_name ++ "\"\nuuid = \"" ++ pkg_uuid ++ "\"\nversion = \"1.9.13\"\n",
        );
    }

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

    fn options(self: *Fixture, env: []const u8, prefix: ?[]const u8) !Options {
        return .{
            .env_path = env,
            .stack = try self.stack(),
            .julia_prefix = prefix,
            // Nothing in these tests may reach the network. `registry_policy =
            // .never` and `artifacts = false` are what guarantee that, and a
            // test that needs either of them tests it against a loopback
            // server in the module that owns it, not here.
            .registry_policy = .never,
            .artifacts = false,
        };
    }
};

test "a complete environment instantiates to a no-op and converges" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    var opts = try f.options(env, prefix);
    // The manifest is hand-written, so the fixups pass WOULD normalise it;
    // this test is about the download half.
    opts.fixups = false;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    try testing.expect(rep.ok());
    try testing.expect(rep.converged());
    try testing.expectEqual(@as(usize, 3), rep.entries);
    // Ghost is reachable from nothing: pruned, and therefore not even a job.
    try testing.expectEqual(@as(usize, 1), rep.pruned);
    try testing.expectEqual(@as(usize, 1), rep.package_jobs.len);
    try testing.expectEqual(@as(usize, 0), rep.installedCount());
    try testing.expect(!rep.manifest_written);
}

test "the pruned entry is never a download job, but survives in the file" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    var opts = try f.options(env, prefix);
    opts.dry_run = true;
    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    // Ghost carries a git-tree-sha1 and is NOT installed, so an instantiate
    // that skipped the closure would list it here and then fail to download it
    // forever — which is precisely the Vulkan-family shape on the real
    // Open-Reality environment.
    try testing.expectEqual(@as(usize, 1), rep.package_jobs.len);
    try testing.expectEqualStrings("StaticArrays", rep.package_jobs[0].name);

    // ...and nothing was written under dry-run, including the manifest.
    try testing.expect(!rep.manifest_written);
    const on_disk = try Io.Dir.cwd().readFileAlloc(
        testing.io,
        try f.join(&.{ "env", "Manifest.toml" }),
        f.arena(),
        .limited(1 << 20),
    );
    try testing.expect(std.mem.indexOf(u8, on_disk, "Ghost") != null);
}

test "a dry run does not create registries/, or anything else" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    const prefix = try f.installStdlibs();
    // NOT installed, so `missing != 0` and step 3 is reached — the only path
    // that would go to the network, and the one that used to `mkpath` the
    // depot's `registries/` and take a lock in it before noticing `dry_run`.
    // With `--registry-depot` pointing at a real ~/.julia that was a write into
    // the user's depot from a command whose whole contract is that it writes
    // nothing.
    var opts = try f.options(env, prefix);
    opts.dry_run = true;
    opts.registry_policy = .always;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(rep.registry.attempted);
    try testing.expectEqual(regops.Action.would_add, rep.registry.action.?);

    // The depot holds exactly what the fixture put there: nothing.
    const depot_path = try f.join(&.{"depot"});
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, depot_path, .{}));
}

test "offline collapses even --registry-policy always to never" {
    // `update_registries`' `OFFLINE_MODE[] && return` (`Operations.jl:1629`)
    // fires ahead of the `force` check on the very next line, so an offline
    // run does not refresh the registry however emphatically it was asked to.
    try testing.expectEqual(RegistryPolicy.never, RegistryPolicy.always.effective(true));
    try testing.expectEqual(RegistryPolicy.never, RegistryPolicy.if_missing.effective(true));
    try testing.expectEqual(RegistryPolicy.always, RegistryPolicy.always.effective(false));

    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    const prefix = try f.installStdlibs();
    // Same shape as the dry-run test above: nothing installed, so `missing`
    // is non-zero and step 3 is genuinely reached.
    var opts = try f.options(env, prefix);
    opts.dry_run = true;
    opts.registry_policy = .always;
    opts.net.offline = true;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(!rep.registry.attempted);
    try testing.expect(rep.registry.action == null);

    // The landmark: the same options WITHOUT the offline bit do attempt it.
    // Otherwise this would pass equally well if step 3 had stopped running at
    // all.
    opts.net.offline = false;
    const online = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(online.registry.attempted);
    try testing.expectEqual(regops.Action.would_add, online.registry.action.?);
}

test "instantiate stamps the manifest usage log, and a dry run does not" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    var opts = try f.options(env, prefix);
    opts.fixups = false;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(rep.ok());

    // Without this, `Pkg.gc()` sees no environment referencing the depot and
    // collects everything the run just installed. `usage.sh` proves that
    // failure mode against a real `Pkg.gc`; this pins the wiring, which is the
    // part that silently regresses — `run` composing six modules, and this one
    // being the only one whose absence changes nothing observable until later.
    try testing.expect(rep.usage_manifest.written);
    try testing.expectEqual(@as(usize, 1), rep.usage_manifest.keys);

    const log = try f.join(&.{ "depot", "logs", "manifest_usage.toml" });
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, log, f.arena(), .limited(1 << 20));
    // Keyed on the ABSOLUTE manifest path (`Types.jl:422-425`), which is what
    // `gc` filters through `isfile_nothrow` at `API.jl:684-685`.
    const manifest_path = try f.join(&.{ "env", "Manifest.toml" });
    try testing.expect(std.mem.indexOf(u8, text, manifest_path) != null);
    try testing.expect(std.mem.indexOf(u8, text, "time = ") != null);

    // The dry run reaches the same code path and must still write nothing —
    // the depot below is untouched because `f` is a fresh fixture.
    var f2buf: [512]u8 = undefined;
    var f2 = try Fixture.init(&f2buf);
    defer f2.deinit();
    const env2 = try f2.writeEnv(false);
    try f2.installPackage();
    const prefix2 = try f2.installStdlibs();
    var opts2 = try f2.options(env2, prefix2);
    opts2.fixups = false;
    opts2.dry_run = true;
    const rep2 = try run(testing.allocator, f2.arena(), testing.io, opts2, .none);
    try testing.expect(!rep2.usage_manifest.written);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(
        testing.io,
        try f2.join(&.{ "depot", "logs" }),
        .{},
    ));
}

test "the closure keeps the project's own uuid where verify's does not" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    // The manifest now carries a `Fixture` entry at `path = "."`, reachable
    // from nothing but the project's own identity.
    const env = try f.writeEnv(true);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    var opts = try f.options(env, prefix);
    opts.fixups = false;
    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    // `prune_manifest` keeps it (Operations.jl:1259-1261) -> 1 pruned (Ghost).
    try testing.expectEqual(@as(usize, 4), rep.entries);
    try testing.expectEqual(@as(usize, 1), rep.pruned);
    // `load_all_deps_loadable` does not -> verify prunes 2. The divergence is
    // real, it is Julia's, and this is the test that says so out loud: if the
    // two ever agree again, one of them has silently changed.
    try testing.expectEqual(@as(usize, 2), rep.after.pruned);
}

test "a direct dependency with no manifest entry blocks before any work" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    // Added AFTER the manifest was written; the project_hash goes stale too,
    // which is exactly the ordering Pkg has (`@warn` on the hash at
    // API.jl:1321, then `pkgerror` on the missing entry at :1327).
    try f.write("env/Project.toml", std.fmt.comptimePrint(
        \\name = "Fixture"
        \\uuid = "{s}"
        \\version = "0.1.0"
        \\
        \\[deps]
        \\StaticArrays = "{s}"
        \\LinearAlgebra = "{s}"
        \\Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    , .{ Fixture.proj_uuid, Fixture.pkg_uuid, Fixture.std_uuid }));

    const rep = try run(testing.allocator, f.arena(), testing.io, try f.options(env, prefix), .none);

    try testing.expect(!rep.ok());
    try testing.expect(!rep.converged());
    try testing.expectEqual(verify.Kind.direct_dep_unmanifested, rep.blocked.?.kind);
    try testing.expectEqualStrings("Dates", rep.blocked.?.subject);
    // Blocked means blocked: no jobs were even built.
    try testing.expectEqual(@as(usize, 0), rep.package_jobs.len);
}

test "a stale project_hash is a warning, not a block — the pins still rule" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    // A compat entry: the hash changes, the dependency set does not.
    try f.write("env/Project.toml", std.fmt.comptimePrint(
        \\name = "Fixture"
        \\uuid = "{s}"
        \\version = "0.1.0"
        \\
        \\[deps]
        \\StaticArrays = "{s}"
        \\LinearAlgebra = "{s}"
        \\
        \\[compat]
        \\StaticArrays = "1"
        \\
    , .{ Fixture.proj_uuid, Fixture.pkg_uuid, Fixture.std_uuid }));

    var opts = try f.options(env, prefix);
    opts.fixups = false;
    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    // `instantiate` only @warns here (API.jl:1321-1324) and carries on with
    // the manifest as written. Blocking instead would turn every edited
    // Project.toml into a hard failure of the container entrypoint.
    try testing.expect(rep.blocked == null);
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.package_jobs.len);
    // It cannot CONVERGE, though — verify is stricter, and says why.
    try testing.expect(!rep.converged());
    try testing.expectEqual(verify.Kind.project_hash_mismatch, rep.after.problems[0].kind);
}

test "an unparseable manifest blocks instead of installing something arbitrary" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.write("env/Manifest.toml", "this is not toml\n");

    const rep = try run(testing.allocator, f.arena(), testing.io, try f.options(env, null), .none);

    try testing.expect(!rep.ok());
    try testing.expectEqual(verify.Kind.manifest_invalid, rep.blocked.?.kind);
}

test "fixups rewrite the manifest once and then leave it alone" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();
    const mpath = try f.join(&.{ "env", "Manifest.toml" });

    var opts = try f.options(env, prefix);
    opts.stdlib_dir = try fspath.join(f.arena(), &.{ prefix, "share", "julia", "stdlib", "v1.12" });

    // First run: the hand-written manifest is not what Pkg's writer emits (no
    // banner, unsorted), so it is normalised.
    const first = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(first.ok());
    try testing.expect(first.manifest_written);
    const after_first = try Io.Dir.cwd().readFileAlloc(testing.io, mpath, f.arena(), .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, after_first, manifest_mod.banner));

    // Second run: byte-identical render, so nothing is written at all. This is
    // the property the idempotence gate measures with mtimes, asserted here
    // where the cause is visible.
    const second = try run(testing.allocator, f.arena(), testing.io, opts, .none);
    try testing.expect(second.ok());
    try testing.expect(!second.manifest_written);
    const after_second = try Io.Dir.cwd().readFileAlloc(testing.io, mpath, f.arena(), .limited(1 << 20));
    try testing.expectEqualStrings(after_first, after_second);

    // The pruned entry is still in the file. Persisting the pruning would
    // delete nine entries from the real Open-Reality manifest, and the next
    // resolve would have to invent them again.
    try testing.expect(std.mem.indexOf(u8, after_second, "Ghost") != null);

    // And `project_hash` survived the destructure/emit round trip. That is not
    // free: `manifest.zig` documents that `destructure` re-copies `other` over
    // the value it just wrote, so a writer that only set the model field would
    // emit the OLD hash — and the next `verify` would call a perfectly good
    // environment stale. Asserted through `converged()`, which is the
    // consumer that would break.
    try testing.expect(second.converged());
}

test "no host platform is a refusal, not a silently artifact-less install" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    var opts = try f.options(env, prefix);
    opts.fixups = false;
    // Artifacts requested, but the fixture's fake Julia tree has no
    // `share/julia/base/build_h.jl`, so no host can be detected.
    opts.artifacts = true;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    // The packages installed fine and `verify` is happy — it does not check
    // artifacts at all (its stated divergence 1). Both verdicts must still be
    // false: `Pkg.instantiate()` runs `check_artifacts_downloaded`
    // (`Operations.jl:209-221`), so an exit code of 0 here would tell a
    // container entrypoint the environment is ready when the first `dlopen`
    // will fail. This is the exact shape a reviewer caught the first version
    // getting wrong — it reported `converged()` true.
    try testing.expect(rep.after.ok());
    try testing.expectEqual(ArtifactsSkipped.no_host, rep.artifacts_skipped.?);
    try testing.expect(!rep.ok());
    try testing.expect(!rep.converged());
}

test "a redirected manifest is not pruned at all" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    _ = try f.writeEnv(false);
    try f.installPackage();
    const prefix = try f.installStdlibs();

    // `prune_manifest` prunes ONLY in its `else` branch: with no workspace and
    // `dirname(project_file) != dirname(manifest_file)` it rewrites the project
    // entry's deps and leaves every other entry alone (`Operations.jl:1254-1257`).
    // So `Ghost` — unreachable from the project's deps, and the entry the other
    // tests watch get pruned — survives here, and an implementation that pruned
    // anyway would build a strictly smaller download set than Pkg.
    const a = f.arena();
    const mpath = try f.join(&.{ "env", "Manifest.toml" });
    const src = try Io.Dir.cwd().readFileAlloc(testing.io, mpath, a, .limited(1 << 20));
    try f.write("shared/Manifest.toml", src);

    var opts = try f.options(try f.join(&.{"env"}), prefix);
    opts.manifest_file = try f.join(&.{ "shared", "Manifest.toml" });
    opts.fixups = false;

    const rep = try run(testing.allocator, a, testing.io, opts, .none);

    try testing.expectEqual(@as(usize, 3), rep.entries);
    try testing.expectEqual(@as(usize, 0), rep.pruned);
    // Ghost is now a download job, and it cannot be served, so the run fails —
    // which is what Pkg does with this environment too.
    try testing.expectEqual(@as(usize, 2), rep.package_jobs.len);
    try testing.expect(!rep.ok());
}

test "a package missing from the depot becomes a job, and its absence is reported" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();

    const env = try f.writeEnv(false);
    const prefix = try f.installStdlibs();
    // Deliberately NOT installed, and no registry and no server: every
    // candidate list is empty, so the job exhausts immediately.
    var opts = try f.options(env, prefix);
    opts.fixups = false;

    const rep = try run(testing.allocator, f.arena(), testing.io, opts, .none);

    try testing.expect(!rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.packages.len);
    try testing.expectEqual(pkgs.Outcome.needs_git_clone, rep.packages[0].outcome);
    try testing.expectEqual(@as(usize, 0), rep.packages[0].attempts.len);
    try testing.expect(!rep.converged());
}
