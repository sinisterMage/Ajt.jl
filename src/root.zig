//! Ajt — Advanced Julia Tools.
//!
//! A drop-in replacement for Julia's Pkg.jl. This module is the library root;
//! the CLI in src/main.zig is a thin shell over it.
//!
//! Layering rule: `toml/`, and later `julia/` and `solver/`, perform no I/O and
//! allocate only through a passed-in allocator. That is what makes them
//! exhaustively unit-testable and fuzzable, and correctness lives there.

const std = @import("std");

/// Ports of Julia's own semantics. No I/O, allocator passed in -- these are
/// the modules where "agrees with Julia exactly" is the whole specification,
/// so they are differential-tested against Julia rather than reasoned about.
pub const julia = struct {
    pub const slug = @import("julia/slug.zig");
    pub const version = @import("julia/version.zig");
    pub const versions = @import("julia/versions.zig");
    pub const project_hash = @import("julia/project_hash.zig");
    pub const treehash = @import("julia/treehash.zig");
    pub const platform = @import("julia/platform.zig");
    pub const stdlibs = @import("julia/stdlibs.zig");
    pub const preferences = @import("julia/preferences.zig");
    /// `Base.get_bool_env` — the truthy/falsy tables `JULIA_PKG_OFFLINE` and
    /// `JULIA_PKG_UNPACK_REGISTRY` are both read through.
    pub const env = @import("julia/env.zig");
    /// `Base.hash(::String)` — the number `clones/<name>` is spelled with.
    pub const string_hash = @import("julia/string_hash.zig");

    pub const Uuid = slug.Uuid;
    pub const Sha1 = slug.Sha1;
    pub const packageSlug = slug.packageSlug;
    pub const versionSlug = slug.versionSlug;
    pub const Version = version.Version;
    pub const VersionSpec = versions.Spec;
    pub const semverSpec = versions.semverSpec;
    pub const projectHash = project_hash.compute;
    pub const stringHash = string_hash.hashString;
};

pub const registry = struct {
    pub const tarball = @import("registry/tarball.zig");
    pub const index = @import("registry/index.zig");
    pub const aix = @import("registry/aix.zig");
    /// Which backend a registry read comes from. `auto` prefers the `.aix`
    /// index (an mmap) over re-parsing the tarball (~1.5 s).
    pub const source = @import("registry/source.zig");
    pub const Backend = source.Backend;
    pub const openSource = source.open;
    pub const Archive = tarball.Archive;
    pub const Registry = index.Registry;
    pub const open = index.open;
    /// The same, for `registries/<Name>/` — a git clone, an unpacked
    /// snapshot, or a symlink to either.
    pub const openDir = index.openDir;
    pub const loadPackage = index.loadPackage;
};

/// PubGrub dependency resolution, vendored from baker. See src/solver/VENDOR.md.
pub const solver = @import("solver/solver.zig");

/// The Julia version-set model that replaces baker's semver `version.zig`
/// at the solver seam. Bitsets over each package's candidate list.
pub const julia_set = @import("solver/julia_set.zig");

/// Turns a Julia environment (registry + stdlibs + project) into the inputs
/// the pure solver consumes. Package identity is the UUID.
pub const encode = @import("solver/encode.zig");

/// The Pkg-server transport: protocol headers, bearer tokens, redirects and
/// retry. The ONLY part of Ajt that talks to the network.
pub const net = struct {
    pub const http = @import("net/http.zig");
    pub const auth = @import("net/auth.zig");

    pub const Client = http.Client;
    pub const Config = http.Config;
    pub const pkgServer = auth.pkgServer;
};

/// The install pipeline: verified content on its way into the depot, and what
/// a package's `Artifacts.toml` resolves to for this host.
pub const install = struct {
    pub const extract = @import("install/extract.zig");
    pub const artifacts = @import("install/artifacts.zig");

    pub const verifyAndExtractTar = extract.verifyAndExtractTar;
    pub const verifyAndExtractGzip = extract.verifyAndExtractGzip;
    pub const treeHashOfTar = extract.treeHashOfTar;
    pub const treeHashOfGzip = extract.treeHashOfGzip;
    pub const TarballShape = extract.Shape;
};

/// Git: what Ajt needs from a repository, behind a backend vtable so the call
/// sites, the manifest shapes and the differential gates can all be written
/// and gated against the `git` subprocess backend before any C exists.
///
/// `url` is pure and answers three separate questions -- Pkg's own `isurl`
/// predicate, which transport a URL names, and what may be logged about it.
pub const git = struct {
    pub const core = @import("git/git.zig");
    pub const url = @import("git/url.zig");
    pub const auth = @import("git/auth.zig");
    pub const cli = @import("git/cli.zig");
    /// The libgit2 backend. Present unconditionally; without `-Dgit` every one
    /// of its entry points reports `BackendUnavailable` and no libgit2 symbol
    /// is linked at all.
    pub const lib = @import("git/lib.zig");
    // `git/c.zig` (the hand-written libgit2 declarations) and `git/tls.zig`
    // (the registered `git_stream`) are deliberately NOT re-exported. Naming
    // them here would put their `extern` declarations in the root namespace's
    // debug info, which links them into every build -- including the one
    // without `-Dgit`, where there is no libgit2 to link against.

    pub const Backend = core.Backend;
    pub const Which = core.Which;
    pub const Rev = core.Rev;
    pub const TreeId = core.TreeId;
    pub const Error = core.Error;
    pub const refspecs_heads = core.refspecs_heads;
    pub const refspecs_all = core.refspecs_all;
    pub const selectBackend = core.selectFromEnv;
    pub const Cli = cli.Cli;
    pub const Lib = lib.Lib;
    pub const haveLibgit2 = lib.enabled;

    pub const Kind = url.Kind;
    pub const classify = url.classify;
    pub const isUrl = url.isUrl;
    pub const Credentials = url.Credentials;
    pub const decideCredentials = auth.decide;
};

/// Depot layout (`DEPOT_PATH`, `packages/<Name>/<slug>`, `artifacts/<hex>`, ...)
/// and the rename-based atomic install that publishes into it.
pub const depot = @import("depot.zig");

/// The shared content-addressed precompile cache: the four halves of "can one
/// machine's precompilation be reused by another".
///
/// `key` is what a store object is NAMED by — a recursive derivation hash, so
/// a hit for a package implies a hit for its whole closure. `slug` is where a
/// cache entry LANDS on this machine, which is deliberately machine-local.
/// `jicache` reads and verifies the `.ji` header before anything is trusted,
/// re-running exactly what `stale_cachefile` will check. `store` moves the
/// bytes, hash-verified before any of them reach the depot.
///
/// `compiled/` itself is still written by Julia and never forged here — see
/// `depot.zig`. This namespace reads, verifies and transports; the import step
/// rewrites only the slug path, never a byte of a header.
pub const cache = struct {
    pub const key = @import("cache/key.zig");
    pub const slug = @import("cache/slug.zig");
    pub const jicache = @import("cache/jicache.zig");
    pub const store = @import("cache/store.zig");

    pub const Key = key.Key;
    pub const cacheKey = key.compute;
    pub const cacheKeysForManifest = key.computeManifest;

    pub const cachePath = slug.cachePath;
    pub const CacheFlags = slug.Flags;
    pub const CacheInputs = slug.Inputs;
    pub const PkgId = slug.PkgId;

    pub const Header = jicache.Header;
    pub const parseJiHeader = jicache.parse;
    pub const verifyJi = jicache.verify;
    pub const isRelocatable = jicache.isRelocatable;

    pub const Store = store.Store;
    pub const Manifest = store.Manifest;
    pub const ManifestEntry = store.Entry;
};

/// End-to-end operations: a whole Pkg verb each, composed from the layers
/// below. These are the only modules that read an environment AND a depot in
/// one breath.
pub const ops = struct {
    pub const verify = @import("ops/verify.zig");
    pub const install_packages = @import("ops/install_packages.zig");
    pub const installPackages = install_packages.install;
    pub const fixupsFromProjectFile = install_packages.fixupsFromProjectFile;
    pub const install_artifacts = @import("ops/install_artifacts.zig");
    pub const registry_ops = @import("ops/registry_ops.zig");
    /// `<depot>/logs/*_usage.toml` — what stops `Pkg.gc()` from collecting
    /// everything Ajt installed.
    pub const usage = @import("ops/usage.zig");
    pub const recordUsage = usage.record;
    /// `Pkg.gc()` — the depot sweeper, and the ONLY module in Ajt that
    /// unlinks a user's files.
    pub const gc = @import("ops/gc.zig");
    /// The whole of `Pkg.instantiate`, composed from every module above.
    pub const instantiate = @import("ops/instantiate.zig");
    /// PubGrub over a real environment.
    pub const resolve = @import("ops/resolve.zig");
    pub const edit = @import("ops/edit.zig");
    pub const why = @import("ops/why.zig");
    /// `Pkg.is_manifest_current` (the tri-state) and `Pkg.upgrade_manifest`
    /// (the one-shot v1→v2 migration).
    pub const manifest_ops = @import("ops/manifest_ops.zig");
    /// `Pkg.generate` — the two files it writes and nothing else.
    pub const generate = @import("ops/generate.zig");
    /// `Pkg.compat(name, spec)`. The interactive editor stays with Pkg.
    pub const compat = @import("ops/compat.zig");
    /// `Pkg.status` — the one verb whose product is the printed report.
    pub const status = @import("ops/status.zig");
    /// `Pkg.precompile()`'s per-package invocation and ordering. The only
    /// module that spawns a child process -- Julia still writes `compiled/`.
    pub const precompile = @import("ops/precompile.zig");
    /// Running a child `julia`: the seam `precompile`, `build` and `test`
    /// share. `std.process.run`, one process per unit of work, and an
    /// environment that is BUILT rather than inherited.
    pub const child = @import("ops/child.zig");
    /// `Operations.sandbox` -- the throwaway environment `build` and `test`
    /// run a package's own code inside.
    pub const sandbox = @import("ops/sandbox.zig");
    /// `Pkg.build`: `deps/build.jl` in dependency order, in a sandbox.
    pub const build = @import("ops/build.zig");
    /// `Pkg.test`: `test/runtests.jl` in a child Julia, in a sandbox built
    /// from the package's test target. Spelled `test_op` because `test` is a
    /// Zig keyword and `@"test"` at every call site would be worse.
    pub const test_op = @import("ops/test.zig");
};

/// The dynamic frontier scheduler: one dependency graph over
/// resolve/fetch/verify/install/precompile in place of Pkg's four sequential
/// phases, plus the resource classes that decide how much of each kind of work
/// runs at once.
///
/// `graph` is the pure data structure -- per-stage nodes, `requires`/`after`
/// edges, `any`-nodes and the readiness bookkeeping -- with no I/O in it at
/// all, so the whole of the ordering policy is unit-testable. `resources` is
/// the half that must look at the machine: the four semaphores and the memory
/// token bucket.
pub const sched = struct {
    pub const graph = @import("sched/graph.zig");
    pub const resources = @import("sched/resources.zig");
    /// Critical-path (HLFET) ranking — which ready task the frontier starts
    /// first — plus the `<depot>/ajt/costs.toml` cost model it estimates from.
    pub const rank = @import("sched/rank.zig");
    pub const exec = @import("sched/exec.zig");

    pub const Graph = graph.Graph;
    pub const buildGraph = graph.build;
    pub const findCycle = graph.findCycle;

    pub const Pool = resources.Pool;
    pub const Widths = resources.Widths;
    pub const Machine = resources.Machine;
    pub const detect = resources.detect;

    pub const Ranking = rank.Ranking;
    pub const CostModel = rank.CostModel;
};

/// Read/write models for the files Julia itself reads. Byte-for-byte
/// compatibility with Pkg's writers is the specification here.
pub const model = struct {
    pub const manifest = @import("model/manifest.zig");
    pub const project = @import("model/project.zig");

    pub const Manifest = manifest.Manifest;
    pub const PackageEntry = manifest.PackageEntry;
    pub const Project = project.Project;
    pub const readProject = project.parse;
};

pub const toml = struct {
    pub const value = @import("toml/value.zig");
    pub const parse_mod = @import("toml/parse.zig");
    pub const emit_mod = @import("toml/emit.zig");

    pub const Value = value.Value;
    pub const Table = value.Table;
    pub const Entry = value.Entry;
    pub const DateTime = value.DateTime;
    pub const Document = value.Document;

    pub const parse = parse_mod.parse;
    pub const Diagnostic = parse_mod.Diagnostic;
    pub const ParseError = parse_mod.Error;

    pub const emit = emit_mod.emit;
    pub const EmitOptions = emit_mod.Options;
};

test {
    // Pull every module's test blocks into the test binary. Zig 0.16 dropped
    // testing.refAllDeclsRecursive, and the non-recursive refAllDecls does not
    // reach through the nested `toml` namespace, so reference them directly.
    _ = @import("toml/value.zig");
    _ = @import("toml/parse.zig");
    _ = @import("toml/emit.zig");
    _ = @import("julia/slug.zig");
    _ = @import("julia/version.zig");
    _ = @import("julia/versions.zig");
    _ = @import("julia/project_hash.zig");
    _ = @import("julia/treehash.zig");
    _ = @import("julia/platform.zig");
    _ = @import("julia/stdlibs.zig");
    _ = @import("julia/preferences.zig");
    _ = @import("julia/string_hash.zig");
    _ = @import("julia/env.zig");
    _ = @import("registry/tarball.zig");
    _ = @import("registry/index.zig");
    _ = @import("solver/solver.zig");
    _ = @import("solver/julia_set.zig");
    _ = @import("solver/encode.zig");
    _ = @import("net/http.zig");
    _ = @import("net/auth.zig");
    _ = @import("install/extract.zig");
    _ = @import("depot.zig");
    _ = @import("model/manifest.zig");
    _ = @import("model/project.zig");
    _ = @import("install/artifacts.zig");
    _ = @import("registry/aix.zig");
    _ = @import("registry/source.zig");
    _ = @import("ops/verify.zig");
    _ = @import("ops/install_packages.zig");
    _ = @import("ops/install_artifacts.zig");
    _ = @import("ops/registry_ops.zig");
    _ = @import("ops/usage.zig");
    _ = @import("ops/gc.zig");
    _ = @import("ops/instantiate.zig");
    _ = @import("ops/resolve.zig");
    _ = @import("ops/edit.zig");
    _ = @import("ops/why.zig");
    _ = @import("ops/manifest_ops.zig");
    _ = @import("ops/generate.zig");
    _ = @import("ops/compat.zig");
    _ = @import("ops/status.zig");
    _ = @import("sched/resources.zig");
    _ = @import("sched/graph.zig");
    _ = @import("sched/rank.zig");
    _ = @import("sched/exec.zig");
    _ = @import("ops/precompile.zig");
    _ = @import("ops/child.zig");
    _ = @import("ops/sandbox.zig");
    _ = @import("ops/build.zig");
    _ = @import("ops/test.zig");
    _ = @import("cache/jicache.zig");
    _ = @import("cache/key.zig");
    _ = @import("cache/slug.zig");
    _ = @import("cache/store.zig");
    _ = @import("git/url.zig");
    _ = @import("git/auth.zig");
    _ = @import("git/git.zig");
    _ = @import("git/cli.zig");
    _ = @import("git/lib.zig");
    // Only when libgit2 is actually linked. The condition is comptime-known, so
    // the branch is pruned outright and these files' tests -- every one of
    // which calls into C -- are not compiled into a build that has no C to call.
    if (git.lib.enabled) {
        _ = @import("git/c.zig");
        _ = @import("git/tls.zig");
    }
}
