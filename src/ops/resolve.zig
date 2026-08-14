//! `ajt resolve` — run PubGrub over a real Julia environment.
//!
//! This is the first thing that drives `solver/encode.zig` against the actual
//! General registry rather than a fixture, and the first that produces a
//! version selection Julia can be asked to agree with.
//!
//! ## Preserve tiers
//!
//! Pkg's `resolve`/`instantiate` run at `PRESERVE_ALL`: the existing manifest
//! is authoritative and every already-recorded version stays put. That is the
//! common case by a wide margin, and it is also the one worth implementing
//! first because it has a checkable answer — the committed manifest itself.
//!
//! It is encoded exactly as the plan describes, as **extra root
//! incompatibilities**: the project gains one dependency per manifest entry,
//! pinned to that entry's recorded version. No solver change is needed, and
//! the pins are visible to the derivation tree, so a conflict names the pin
//! that caused it rather than surfacing as an anonymous dead end.
//!
//! ## Offline is not a tier
//!
//! `Options.offline` looks like `all_installed` and is a different kind of
//! thing. A preserve tier is a preference about which versions to HOLD, and
//! `tiered` walks past one that does not work out; offline is a constraint
//! about which versions EXIST, and it is re-applied at every tier the sequence
//! reaches (`resolve_versions!` is per-attempt, and `installed_only` is OR'd
//! there — `Operations.jl:500`). They compose rather than override: offline
//! `--preserve none` is a full re-resolve over installed candidates only.
//!
//! `.none` drops the pins and resolves from `[compat]` alone — a real
//! re-resolve. It is the tier that can legitimately disagree with the
//! committed manifest, so nothing compares its output to one. The manifest is
//! still READ at that tier — it is what the report diffs against, and a
//! re-resolve whose output cannot be compared to the environment it came from
//! is not worth much.
//!
//! ## A manifest entry is not the same thing as a recorded version
//!
//! These are three different states and the report keeps them apart:
//!
//! | manifest | version key | report |
//! |---|---|---|
//! | absent | — | `added` — the resolve introduced it |
//! | present | yes | `held` / `changed` |
//! | present | no | `unversioned` |
//!
//! The third row is not a curiosity. `stdlib_version` returns `nothing` for an
//! unversioned stdlib (`Types.jl:600-609`) and `update_manifest!` writes that
//! straight through (`Operations.jl:238-240`), so Pkg records such an entry
//! with a `uuid` and `deps` and NO `version` — while the resolver still has to
//! give it one, namely `something(stdlib_info.version, VERSION)`
//! (`Operations.jl:678`). Collapsing "no version to compare" into "not in the
//! manifest" reports a package Pkg chose too as one Ajt invented.
//!
//! On Julia 1.12 exactly one package is in that state — `SuiteSparse`, the
//! only stdlib shipping no `version` key — which is precisely why it took a
//! corpus to surface: Open-Reality and DataFrames do not pull it, Makie and
//! Flux do (via `ArrayInterface` 7 - 7.12).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const solver = @import("../solver/solver.zig");
const encode = @import("../solver/encode.zig");
const jset = @import("../solver/julia_set.zig");
const index = @import("../registry/index.zig");
const tarball = @import("../registry/tarball.zig");
const source_mod = @import("../registry/source.zig");
const jver = @import("../julia/version.zig");
const jspec = @import("../julia/versions.zig");
const stdlib_mod = @import("../julia/stdlibs.zig");
const project_hash_mod = @import("../julia/project_hash.zig");
const project_mod = @import("../model/project.zig");
const manifest_mod = @import("../model/manifest.zig");
const install_packages = @import("install_packages.zig");
const instantiate = @import("instantiate.zig");
const depot = @import("../depot.zig");
const git_mod = @import("../git/git.zig");
const treehash = @import("../julia/treehash.zig");

pub const Error = error{
    NoProject,
    NoJuliaVersion,
    /// `PRESERVE_ALL_INSTALLED`, or `Options.offline`, was asked for with no
    /// depot to look in.
    NoDepotForInstalled,
    /// A `[sources]` entry carries a `url` and no git backend was supplied.
    /// Refused rather than ignored: ignoring it is what produced a manifest
    /// with no `git-tree-sha1` and an `instantiate` that then reported the
    /// package missing.
    NoGitBackend,
    /// A `[sources]` url has to be cloned into `depots1()/clones` and
    /// materialised into `depots1()/packages`, and there is no depot stack.
    NoDepotForRepoSource,
    /// `resolve_projectfile!` (`Types.jl:1071-1092`): the materialised tree has
    /// no `Project.toml`/`JuliaProject.toml`, or its `uuid`/`name` is not the
    /// one `[deps]` names.
    SourceProjectMismatch,
};

/// The root key for a project with no `uuid` of its own.
const nil_uuid: stdlib_mod.Uuid = .{ .bytes = @splat(0) };

//  returns an INFERRED error set. The domain errors above are the ones a
// caller can act on; everything else that reaches it is file I/O, TOML syntax
// or registry decoding, and enumerating those here only produced a 30-name
// union that had to be edited every time a layer below grew an error.

/// `PreserveLevel` (`Types.jl:75`). All of it is two decisions, and both come
/// straight out of Pkg:
///
///  1. WHICH packages carry a requirement — `load_all_deps` for the two `all`
///     tiers, `load_direct_deps` for the rest (`Operations.jl:1746-1752`). A
///     tier that loads only direct deps leaves the whole transitive closure
///     free to move.
///  2. WHAT that requirement is — `load_version` (`:56-68`), which is four
///     lines and the entire difference between the tiers.
///
/// Two rules cut across all of them. An entry with no `version` key is
/// unconstrained at every tier (`:57-58`), and a FIXED entry — path-tracked,
/// repo-tracked or pinned — keeps its version at every tier (`:59-60`), which
/// is why `pin` survives a `--preserve none`.
pub const Tier = enum {
    /// `PRESERVE_ALL`: every manifest entry held at its recorded version. What
    /// `Pkg.resolve` and `Pkg.instantiate` run.
    all,
    /// `PRESERVE_ALL_INSTALLED`: as `all`, but candidates are restricted to
    /// versions already unpacked in the depot, so a resolve can succeed with
    /// no network.
    all_installed,
    /// `PRESERVE_DIRECT`: direct deps held, transitive deps free to move.
    direct,
    /// `PRESERVE_SEMVER`: direct deps allowed to move within `semver_spec` of
    /// their recorded version, i.e. compatibly.
    semver,
    /// `PRESERVE_NONE`: ignore the manifest; resolve from `[compat]` alone.
    none,
    /// `PRESERVE_TIERED`: try `all`, `direct`, `semver`, `none` and take the
    /// first that resolves — the default for `add` (`Operations.jl:23-29`).
    tiered,
    /// `PRESERVE_TIERED_INSTALLED`: `all_installed` first, then the above.
    tiered_installed,

    /// The tiers actually attempted, in order (`tiered_resolve`, `:1712-1743`).
    pub fn sequence(self: Tier) []const Tier {
        return switch (self) {
            .tiered => &.{ .all, .direct, .semver, .none },
            .tiered_installed => &.{ .all_installed, .all, .direct, .semver, .none },
            else => switch (self) {
                .all => &.{.all},
                .all_installed => &.{.all_installed},
                .direct => &.{.direct},
                .semver => &.{.semver},
                .none => &.{.none},
                else => unreachable,
            },
        };
    }

    /// `targeted_resolve` (`:1746-1749`): do manifest entries that are not
    /// direct dependencies carry a requirement at all?
    pub fn loadsAllDeps(self: Tier) bool {
        return self == .all or self == .all_installed;
    }

    pub fn parse(text: []const u8) ?Tier {
        const table = .{
            .{ "all", Tier.all },
            .{ "installed", Tier.all_installed },
            .{ "all_installed", Tier.all_installed },
            .{ "direct", Tier.direct },
            .{ "semver", Tier.semver },
            .{ "none", Tier.none },
            .{ "tiered", Tier.tiered },
            .{ "tiered_installed", Tier.tiered_installed },
        };
        inline for (table) |row| {
            if (std.mem.eql(u8, text, row[0])) return row[1];
        }
        return null;
    }
};

pub const Selection = struct {
    uuid: []const u8,
    name: []const u8,
    version: jver.Version,
    /// The version the manifest recorded, when it had one. Null both for a
    /// package the resolve introduced and for a manifest entry carrying no
    /// `version` key — `in_manifest` is what tells those apart.
    was: ?jver.Version = null,
    /// Whether the environment's manifest has an entry for this package at
    /// all, irrespective of what that entry records.
    in_manifest: bool = false,
};

pub const Report = struct {
    selections: []Selection,
    /// Entries whose resolved version differs from the manifest's. Always
    /// empty for a correct `PRESERVE_ALL` run — that IS the gate.
    changed: usize = 0,
    /// Manifest entries carrying no version (unversioned stdlibs, path
    /// entries), which are not pinned and have no version to compare.
    unversioned: usize = 0,
    /// Selections with no manifest entry at all. Under `PRESERVE_ALL` the only
    /// legitimate one is `julia`, which is Ajt's synthetic package and is
    /// never a manifest entry; anything else means the resolve widened the
    /// closure.
    added: usize = 0,
    /// The composed manifest, when `Options.build_manifest` asked for one.
    /// Arena-owned like everything else here.
    manifest: ?manifest_mod.Manifest = null,
    /// True when `Options.write_to` was set AND the bytes differed from what
    /// was already there. False for both "not asked to write" and "wrote
    /// nothing because nothing changed", which the caller distinguishes by
    /// whether it passed a path.
    manifest_written: bool = false,
    /// Entries the fixups pass could not read a `Project.toml` for, because
    /// the package is not installed. Their `weakdeps`/`extensions`/`entryfile`
    /// are therefore ABSENT rather than wrong — Pkg only ever runs this pass
    /// after guaranteeing every source is on disk, so a non-empty list here
    /// means the manifest is resolve-accurate but fixup-incomplete. Names, not
    /// a count: "9 entries are missing something" is not actionable and does
    /// not let a reader judge whether it matters.
    fixups_missing_source: []const []const u8 = &.{},
    /// The `[sources]` entries carrying a `url` that this resolve turned into
    /// repo-tracked manifest entries. Named rather than counted, because the
    /// interesting part is WHICH rev each one landed on: a `rev` naming a
    /// branch is re-fetched on every resolve and its tree hash legitimately
    /// moves, while a tag or a sha never does, and a report that said "1 repo
    /// source" could not tell those apart.
    repo_sources: []const RepoSource = &.{},
    /// The tier that actually produced this solution. Equal to `Options.tier`
    /// except for the two tiered levels, where it is the first member of the
    /// sequence that resolved — which is the only way to tell a `tiered` run
    /// that held everything from one that fell through to a full re-resolve.
    tier_used: Tier = .all,
    elapsed_ms: f64 = 0,
};

/// One `[sources]` entry carrying a `url`, after `handle_repo_add!` has run
/// over it (`Types.jl:928-1050`). Everything here is what the manifest entry
/// ends up recording.
pub const RepoSource = struct {
    name: []const u8,
    /// What `repo-url` becomes. The `[sources]` url verbatim when it IS a url;
    /// the rebased local path when it names a directory (`Types.jl:948-984`).
    url: []const u8,
    /// What `repo-rev` becomes — the `rev` given, or the clone's default
    /// branch when `[sources]` named none (`Types.jl:996-999`).
    rev: []const u8,
    subdir: ?[]const u8 = null,
    tree_hash: manifest_mod.Sha1,
    outcome: Outcome,

    pub const Outcome = enum {
        /// `isdir(version_path) && return false` (`Types.jl:1037`, `:1044`) —
        /// the tree was already unpacked under its slug, so nothing was
        /// written. This is the steady state: a second resolve of an unmoved
        /// rev does one `git fetch` and no install.
        already_installed,
        /// The tree was written into `packages/<Name>/<slug>` by this run.
        materialised,
    };
};

pub const Options = struct {
    project_file: []const u8,
    manifest_file: ?[]const u8 = null,
    registry_depot: []const u8,
    registry_name: []const u8 = "General",
    /// Which registry backend to read. `auto` uses the `.aix` index when one
    /// matches the installed registry; `archive` forces the tarball, which the
    /// differential gates use to compare the two.
    registry_source: source_mod.Preference = .auto,
    julia_prefix: ?[]const u8 = null,
    /// Defaults to the manifest's own `julia_version`, which is what Pkg
    /// resolves against for an existing environment. Required only when there
    /// is no manifest to read it from.
    julia_version: ?jver.Version = null,
    tier: Tier = .all,
    /// `Pkg.OFFLINE_MODE[]` (`Pkg/src/Pkg.jl:45`) — the RESOLVER half of it,
    /// and the substantive one. `resolve_versions!` ORs it into `installed_only`
    /// (`Operations.jl:500`), which restricts every registry package's
    /// candidates to versions already unpacked in the depot
    /// (`:702-708`). Without it an offline resolve happily proposes a manifest
    /// the machine has no way to instantiate.
    ///
    /// A plain field rather than something read from `net/http.zig`: a resolve
    /// makes no requests, so making it depend on the transport's state would
    /// put a socket-shaped global in the one operation that is pure enough to
    /// unit-test end to end. The CLI sets both from the same bit.
    ///
    /// Requires `depots`; without one, `Error.NoDepotForInstalled`.
    offline: bool = false,
    /// Compose `Report.manifest` from the selection. Off by default: printing
    /// a selection needs no tree hashes, and reading them costs a registry
    /// lookup per package.
    build_manifest: bool = false,
    /// Where to write the composed manifest. Implies `build_manifest`. The
    /// write is atomic and skipped entirely when the bytes are unchanged, so
    /// pointing this at the environment's own `Manifest.toml` is safe.
    write_to: ?[]const u8 = null,
    /// The depot search stack. Three things need it: the fixups pass, which
    /// reads `weakdeps`/`extensions`/`entryfile` out of each installed
    /// package's own `Project.toml` (`Operations.jl:250-252`), the
    /// `*_INSTALLED` tiers, and `offline` — the last two for the same reason,
    /// to ask what is already unpacked.
    depots: ?depot.Stack = null,
    /// Run the fixups pass. Off leaves `weakdeps`/`extensions`/`entryfile`
    /// absent from every entry, which is a manifest Julia loads and Pkg
    /// rewrites — so it is a debugging switch, not an optimisation.
    fixups: bool = true,
    /// `Types.stdlib_dir()`, so the fixups pass can find a stdlib's project.
    stdlib_dir: ?[]const u8 = null,
    /// Resolve against these bytes rather than reading `project_file`. `add`
    /// and `rm` use it to resolve an edit they have not written yet, so a
    /// failed resolve leaves `Project.toml` exactly as it was.
    project_source: ?[]const u8 = null,
    /// The same seam for `Manifest.toml`. `dev`, `pin` and `free` need it for
    /// a reason `add` does not: their edit is to the MANIFEST — a `path` entry,
    /// or the `pinned` flag — and `collect_fixed!`'s equivalent here reads
    /// those off the manifest, not the project (`:362`). So the edit has to be
    /// visible to this resolve while still not being on disk if it fails.
    manifest_source: ?[]const u8 = null,
    /// Per-package requirements that override the tier's.
    overrides: []const Override = &.{},
    /// How a `[sources]` entry carrying a `url` is cloned and materialised.
    /// Consulted only when the project HAS such an entry, so a caller that
    /// never sees one pays nothing for leaving it null — and one that does see
    /// one gets `NoGitBackend` rather than a silently url-less manifest.
    git: ?git_mod.Backend = null,
    /// Transient scratch for the git backend, which buffers a whole
    /// `git archive` in memory. Defaults to `arena`, which is correct but
    /// means the tarball is not returned until the resolve ends — fine for the
    /// small package a `[sources]` url normally names, wasteful for a large
    /// one. Everything the Report borrows still comes from `arena`.
    scratch: ?Allocator = null,
    /// Filled in when the solve fails. Without it the caller gets an error
    /// code and nothing else: the derivation tree is built from state that
    /// lives inside this function, and the only thing that can turn its
    /// package keys back into names is the encoder, which dies with the frame.
    diagnostic: ?*Diagnostic = null,
};

/// A requirement supplied by the CALLER, replacing whatever the preserve tier
/// would have produced for that package. This is how `add Foo@1.2` and
/// `up Foo --minor` constrain one package without disturbing the rest: Pkg
/// builds the same thing by putting a version on the PackageSpec before
/// `load_direct_deps` fills in the others (`Operations.jl:1863-1899`).
pub const Override = struct {
    uuid: []const u8,
    spec: ?jspec.Spec = null,
    pin: ?jver.Version = null,
};

/// What a failed resolve has to say for itself.
pub const Diagnostic = struct {
    /// The rendered derivation tree, arena-owned.
    report: ?[]const u8 = null,
    /// Display names of the packages the derivation blames, most relevant
    /// first — this is the actionable part, and it is the part the tree buries
    /// under its own nesting.
    blamed: []const []const u8 = &.{},
};

/// Resolve, using `arena` for everything. The Report borrows from it.
pub fn run(arena: Allocator, io: Io, opts: Options) !Report {
    const t0 = Io.Clock.awake.now(io);

    const proj_src = opts.project_source orelse
        Io.Dir.cwd().readFileAlloc(io, opts.project_file, arena, .limited(8 << 20)) catch
        return Error.NoProject;
    const proj = try project_mod.parse(arena, proj_src, .{}, null);
    // A PACKAGE's Project.toml has name+uuid; a plain ENVIRONMENT's (what
    // `Pkg.add` into an empty dir produces) has neither, and that is the
    // common case for anything that is not itself a library. Julia resolves
    // such a project perfectly happily — the root simply has no identity —
    // so synthesise one rather than refusing.
    //
    // The nil UUID is safe as the root key: it is not a registered package,
    // so nothing in the registry can collide with it, and the root is
    // injected (shadowing any registry lookup) before it is ever resolved.
    const proj_uuid = proj.uuid orelse nil_uuid;

    // ARENA, not a gpa. Every universe borrows package names and version
    // strings straight out of the registry, so it has to outlive the Report --
    // which means it cannot be freed here, and freeing it in the caller would
    // be a lifetime rule nobody remembers. Tying it to the resolve arena makes
    // that automatic.
    //
    // `.auto` prefers the `.aix` index, which is an mmap rather than a 1.5 s
    // parse of an 84 MB tarball. This used to call `tarball.loadFromDepot`
    // unconditionally, and the cost was real: a benchmark against Pkg put
    // `resolve` at parity when three quarters of the time was reading a file
    // it did not need to read.
    var reg = try source_mod.open(arena, arena, io, opts.registry_depot, opts.registry_name, opts.registry_source);

    var man: ?manifest_mod.Manifest = if (opts.manifest_source) |src|
        try manifest_mod.parse(arena, src, null)
    else if (opts.manifest_file) |mf| blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, mf, arena, .limited(64 << 20)) catch break :blk null;
        break :blk try manifest_mod.parse(arena, src, null);
    } else null;

    // Membership as the FILE recorded it, captured BEFORE the `[sources]` merge
    // below is allowed to append to it. Without this snapshot a `[sources]` url
    // the manifest has never seen would be reported as `held` at the version the
    // merge had just invented for it — the same class of mistake the header
    // warns about in the other direction, and it would make `added` read 0 on
    // the one resolve that genuinely introduced a package.
    var on_disk: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    if (man) |m| for (m.entries) |e| try on_disk.put(arena, e.uuid.bytes, {});

    // `[sources]` entries carrying a `url`, resolved into ordinary repo-tracked
    // manifest entries before anything below can look at one. See
    // `applySourceRepos` for why this is a resolve step and not an install
    // step; everything downstream — `fixed`, `injectUntracked`,
    // `composeManifest` — then treats them exactly as it treats an entry a
    // previous `Pkg.add https://…` left behind, because after this they ARE
    // that.
    const repo_sources = try applySourceRepos(arena, io, opts, &proj, &man);

    // An environment with no manifest has no recorded `julia_version`, and Pkg
    // simply resolves for `VERSION` in that case. So does this: the Julia at
    // `--julia-prefix` is the one whose stdlib set is about to be loaded, and
    // resolving for a different Julia than the stdlibs came from would be
    // incoherent. `include/julia/julia_version.h` is the cheapest honest
    // source — it ships with every install and needs no subprocess.
    const target_julia = opts.julia_version orelse
        (if (man) |m| m.julia_version else null) orelse
        (if (opts.julia_prefix) |p| try juliaVersionAt(arena, io, p) else null) orelse
        return Error.NoJuliaVersion;

    var stdlibs: stdlib_mod.Set = if (opts.julia_prefix) |p|
        try stdlib_mod.load(arena, io, .{
            .julia_prefix = p,
            .julia_version = try std.fmt.allocPrint(arena, "{f}", .{target_julia}),
        })
    else
        .{ .dir = "" };

    const root_uuid = try uuidText(arena, proj_uuid);

    // --- what the manifest records ------------------------------------------
    var unversioned: usize = 0;
    var recorded = std.StringHashMapUnmanaged(jver.Version).empty;
    // Membership, which is a weaker statement than `recorded` and the one the
    // report needs: an entry with no `version` key is in here and not there.
    var members = std.StringHashMapUnmanaged(void).empty;
    // Fixed entries — path-tracked, repo-tracked or pinned. `isfixed`
    // (`Operations.jl:380-383`), and `load_version` returns their version
    // unchanged at EVERY tier.
    var fixed = std.StringHashMapUnmanaged(void).empty;
    // The subset that is NOT tracking the registry — `develop`ed or repo-added.
    // These have to be INJECTED rather than looked up: no registry has heard of
    // them, so `universeFor` would hand back an empty universe and every
    // requirement on them would be unsatisfiable. `collect_fixed!` filters on
    // exactly this predicate (`Operations.jl:559`, `is_tracking_registry` at
    // `:380-382`) — note `pinned` alone does NOT belong here, because a pinned
    // registry package still resolves from the registry.
    var untracked: std.ArrayList(manifest_mod.PackageEntry) = .empty;

    if (man) |m| {
        for (m.entries) |e| {
            const uuid_text = try uuidText(arena, e.uuid);
            // The project's own entry (`path = "."`) is the root; pinning
            // the root as its own dependency would be a self-edge.
            if (std.mem.eql(u8, uuid_text, root_uuid)) continue;
            // `fixed` and `untracked` describe what the SOLVE is given, so an
            // entry the `[sources]` merge invented belongs in both. `members`,
            // `recorded` and `unversioned` describe what the FILE said, so it
            // belongs in none of them.
            if (e.path != null or e.repo_url != null or e.pinned) {
                try fixed.put(arena, uuid_text, {});
            }
            if (e.path != null or e.repo_url != null) try untracked.append(arena, e);
            if (!on_disk.contains(e.uuid.bytes)) continue;
            try members.put(arena, uuid_text, {});
            const v = e.version orelse {
                unversioned += 1;
                continue;
            };
            try recorded.put(arena, uuid_text, v);
        }
    }

    // --- solve, walking down the tiers --------------------------------------
    //
    // A single tier is a one-element sequence, so there is one code path.
    const sequence = opts.tier.sequence();
    var enc: *encode.Encoder = undefined;
    var graph: solver.DependencyGraph = undefined;
    var tier_used: Tier = sequence[0];
    var solved = false;
    // Which packages entered the solve with an EXACT version requirement.
    // `jll_fix` is built from `pkg.version isa VersionNumber`
    // (`Operations.jl:511-516`), so a package constrained by a RANGE — every
    // direct dep under `up --major`, and every transitive dep at any tier —
    // is not a fixup candidate and must be allowed to move to a new build.
    var exact_req = std.StringHashMapUnmanaged(void).empty;

    // Hoisted OUT of the attempt loop, unlike the encoder: the encoder caches
    // the FILTERED candidate list and so must not survive a tier change, while
    // this caches only "is this tree hash unpacked", which no tier can change
    // and neither can the filesystem mid-resolve. Sharing it is what stops a
    // `--preserve tiered` offline resolve from re-stat'ing the whole registry
    // once per attempt — on a 200-entry environment that is ~8k lookups a
    // depot deep, four times over.
    var installed_ctx: InstalledCtx = .{
        .arena = arena,
        .io = io,
        .stack = opts.depots orelse .{ .entries = &.{} },
    };

    for (sequence, 0..) |tier, attempt| {
        // A fresh encoder per attempt: universes cache the candidate list, and
        // `all_installed` narrows it, so reusing one across tiers would carry
        // the previous tier's filtering into the next.
        const e = try arena.create(encode.Encoder);
        e.* = encode.Encoder.init(arena, &reg, &stdlibs, target_julia);
        // `installed_only = installed_only || OFFLINE_MODE[]`
        // (`Operations.jl:500`) — the tier's half OR'd with offline's. See
        // "Offline is not a tier" at the top of this file for why the second
        // operand is re-applied at every attempt rather than being one more
        // tier in the sequence.
        if (tier == .all_installed or opts.offline) {
            // Without a depot there is nothing to call "installed", and
            // answering "nothing is" would silently turn the tier into an
            // unsatisfiable one that the tiered sequence then skips past.
            _ = opts.depots orelse return Error.NoDepotForInstalled;
            e.installed = .{ .ctx = @ptrCast(&installed_ctx), .lookup = InstalledCtx.lookup };
        }

        // Inject the `develop`ed and repo-added entries BEFORE anything can ask
        // for a universe on them. `inject` must precede the first `universeFor`
        // for a uuid, and the root's dependency list below is exactly such an
        // ask.
        for (untracked.items) |entry| try injectUntracked(arena, io, e, entry, opts);

        var deps = std.ArrayList(encode.Injected.Dep).empty;
        if (tier.loadsAllDeps()) {
            if (man) |m| {
                for (m.entries) |entry| {
                    const uuid_text = try uuidText(arena, entry.uuid);
                    if (std.mem.eql(u8, uuid_text, root_uuid)) continue;
                    if (try loadVersion(arena, entry, tier, fixed.contains(uuid_text))) |req| {
                        try deps.append(arena, req.dep(uuid_text));
                    }
                }
            }
        }

        // The project's own `[deps]`, constrained by `[compat]` — and, when the
        // manifest has an entry for one, ALSO by whatever this tier preserves.
        // Both requirements apply; see `getManifest` in the encoder.
        for (proj.deps.entries.items) |d| {
            const uuid_text = try uuidText(arena, d.uuid);
            var req: encode.Injected.Dep = .{ .uuid = uuid_text, .spec = compatFor(&proj, d.name) };
            if (man) |m| {
                if (m.findByUuid(d.uuid)) |entry| {
                    if (try loadVersion(arena, entry.*, tier, fixed.contains(uuid_text))) |lv| {
                        req.pin = lv.pin;
                        req.tier_spec = lv.spec;
                    }
                }
            }
            // Under `loadsAllDeps` the loop above may already have emitted a
            // requirement for this uuid; a second one would be redundant but
            // harmless. Skip it so the derivation tree names each constraint
            // once — asking `deps` itself rather than using `recorded` as the
            // proxy, because `recorded` now answers "the FILE recorded this"
            // and a `[sources]` url the file never mentioned does get a
            // requirement out of the loop above.
            if (tier.loadsAllDeps()) {
                var already = false;
                for (deps.items) |*existing| {
                    if (std.mem.eql(u8, existing.uuid, uuid_text)) {
                        // ...except for the compat, which the manifest loop
                        // cannot know about. Replace rather than append.
                        existing.spec = req.spec;
                        already = true;
                        break;
                    }
                }
                if (already) continue;
            }
            try deps.append(arena, req);
        }

        // Caller overrides REPLACE the tier's requirement for a package, both
        // fields at once: leaving a `PRESERVE_DIRECT` pin in place next to an
        // `up --major` spec would intersect to the pin and the package could
        // not move at all.
        for (opts.overrides) |ov| {
            var placed = false;
            for (deps.items) |*d| {
                if (!std.mem.eql(u8, d.uuid, ov.uuid)) continue;
                d.pin = ov.pin;
                d.tier_spec = ov.spec;
                placed = true;
                break;
            }
            if (!placed) {
                try deps.append(arena, .{ .uuid = ov.uuid, .pin = ov.pin, .tier_spec = ov.spec });
            }
        }

        try e.inject(.{
            .uuid = root_uuid,
            .name = proj.name orelse "project",
            .version = proj.version orelse zero_version,
            .deps = deps.items,
        });

        var registry = e.registry();
        const root_u = try e.universeFor(root_uuid);
        graph = solver.solve(.{ .name = root_uuid, .version = root_u.at(0) }, &registry, arena) catch |err| {
            const last = attempt + 1 == sequence.len;
            // Only a resolution failure falls through to the next tier;
            // `tiered_resolve` rethrows anything that is not a ResolverError
            // (`Operations.jl:1721`), and so must this.
            const resolver_error = err == error.NoSolution or err == error.SingletonConflict;
            if (!resolver_error or last) {
                if (opts.diagnostic) |d| try renderDiagnostic(arena, e, root_uuid, d);
                return err;
            }
            continue;
        };
        exact_req.clearRetainingCapacity();
        for (deps.items) |d| {
            if (d.pin != null) try exact_req.put(arena, d.uuid, {});
        }
        enc = e;
        tier_used = tier;
        solved = true;
        break;
    }
    if (!solved) return error.NoSolution;

    // --- report -------------------------------------------------------------
    var sel = std.ArrayList(Selection).empty;
    var changed: usize = 0;
    var added: usize = 0;
    var jll_fixed: usize = 0;
    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, root_uuid)) continue;
        const was = recorded.get(n.name);
        const known = members.contains(n.name);
        var version = n.version.number();

        // JLL build-number fixup (`Operations.jl:564-580`). A recorded version
        // constrains only `(major, minor, patch)`, so a JLL republished as
        // `1.2.3+1` satisfies a manifest that says `1.2.3+0` — and the solver,
        // preferring the highest, picks the new build. Pkg puts the recorded
        // one back whenever the triple is unchanged. Without this a re-resolve
        // rewrites the same JLLs on every run and the manifest never settles.
        if (was) |w| {
            if (exact_req.contains(n.name) and
                thisPatchEql(w, version) and !jver.Version.eql(w, version) and
                std.mem.endsWith(u8, enc.displayName(n.name), "_jll") and
                stdlibs.byUuidText(n.name) == null)
            {
                version = w;
                jll_fixed += 1;
            }
        }

        if (was) |w| {
            if (!jver.Version.eql(w, version)) changed += 1;
        }
        if (!known) added += 1;
        try sel.append(arena, .{
            .uuid = n.name,
            .name = enc.displayName(n.name),
            .version = version,
            .was = was,
            .in_manifest = known,
        });
    }
    std.mem.sort(Selection, sel.items, {}, struct {
        fn lt(_: void, a: Selection, b: Selection) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var built: ?manifest_mod.Manifest = null;
    var missing_source: std.ArrayList([]const u8) = .empty;
    var wrote = false;
    if (opts.build_manifest or opts.write_to != null) {
        var m = try composeManifest(
            arena,
            enc,
            &stdlibs,
            &proj,
            root_uuid,
            man,
            sel.items,
            target_julia,
            opts.project_file,
            opts.manifest_file orelse opts.project_file,
        );
        // `fixups_from_projectfile!` is a SEPARATE pass in Pkg too, run after
        // the sources are on disk (`Operations.jl:250-252`), because weakdeps
        // and extensions exist only in each package's own Project.toml and
        // nowhere in the registry. Without it every entry would be missing
        // them, which is a manifest stock Julia loads and stock Pkg rewrites.
        if (if (opts.fixups) opts.depots else null) |stack| {
            const fixups = try install_packages.fixupsFromProjectFile(arena, arena, io, stack, &m, .{
                .manifest_dir = std.fs.path.dirname(opts.manifest_file orelse opts.project_file) orelse ".",
                // The stdlib set is already loaded here, and its `dir` is the
                // path `Types.stdlib_dir()` returns, so this needs no flag of
                // its own: a resolve that could encode stdlibs at all can also
                // find their project files.
                .stdlib_dir = opts.stdlib_dir orelse
                    (if (stdlibs.dir.len == 0) null else stdlibs.dir),
            });
            // `fixups[i]` describes `m.entries[i]` — the pass rewrites the
            // slice in place and in order — so the uuid has to be taken now,
            // before the prune below reorders what survives.
            var skipped: std.ArrayList(manifest_mod.PackageEntry) = .empty;
            for (fixups, m.entries) |f, e| {
                if (f.skipped != .no) try skipped.append(arena, e);
            }

            // `fixups_from_projectfile!` ends with `prune_manifest(env)`
            // (`Operations.jl:291`), and not redundantly: the pass deletes weak
            // names from `deps`, which can orphan a subtree that was reachable
            // before it ran. On Open-Reality that is the entire Vulkan closure
            // — reachable only because the root's `requires` carries its
            // `[weakdeps]` until this pass takes them back out again.
            m.entries = try pruneManifest(arena, m.entries, &proj, proj.name != null and proj.uuid != null);

            // Only entries that SURVIVED. A package whose source is missing
            // and which is then pruned has lost nothing, and reporting it
            // would make a complete manifest look incomplete — on Open-Reality
            // it reported all nine pruned entries and no real gap.
            for (skipped.items) |e| {
                for (m.entries) |kept| {
                    if (std.mem.eql(u8, &kept.uuid.bytes, &e.uuid.bytes)) {
                        try missing_source.append(arena, e.name);
                        break;
                    }
                }
            }
        }
        if (opts.write_to) |dest| {
            // The current bytes, so an unchanged manifest is left alone —
            // including its mtime, which is what `Pkg.gc()` and every build
            // system downstream key off.
            const current = Io.Dir.cwd().readFileAlloc(io, dest, arena, .limited(64 << 20)) catch "";
            wrote = try instantiate.writeIfChanged(arena, io, &m, dest, current);
        }
        built = m;
    }

    return .{
        .selections = sel.items,
        .changed = changed,
        .unversioned = unversioned,
        .added = added,
        .manifest = built,
        .manifest_written = wrote,
        .repo_sources = repo_sources,
        .tier_used = tier_used,
        .fixups_missing_source = missing_source.items,
        .elapsed_ms = @as(f64, @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds)) / 1e6,
    };
}

/// Render everything a failed solve knows, while the encoder that can name its
/// packages is still alive. Never fails the caller: a resolve that could not
/// find a solution has already failed, and losing the explanation to an
/// allocation error would leave the user with an error code and no text.
fn renderDiagnostic(
    arena: Allocator,
    enc: *const encode.Encoder,
    root_uuid: []const u8,
    d: *Diagnostic,
) Allocator.Error!void {
    var buf: Io.Writer.Allocating = .init(arena);
    solver.writeLastReportNamed(&buf.writer, enc.nameResolver()) catch {};
    if (buf.written().len != 0) d.report = buf.written();

    var keys: std.ArrayList([]const u8) = .empty;
    solver.lastBlamed(&keys, arena) catch {};
    var named: std.ArrayList([]const u8) = .empty;
    for (keys.items) |k| {
        // The project itself is always blamed — every requirement enters
        // through it — and it is the one thing the user cannot relax by
        // editing someone else's [compat].
        if (std.mem.eql(u8, k, root_uuid)) continue;
        try named.append(arena, enc.displayName(k));
    }
    d.blamed = named.items;
}

// ---------------------------------------------------------------------------
// Composing the manifest
//
// `update_manifest!` (`Operations.jl:224-248`) opens with `empty!(manifest)`
// and rebuilds every entry from the resolve. That is not a detail: it means a
// resolve DROPS `weakdeps`, `extensions`, `entryfile` and every unmodelled key
// from the old file, and `fixups_from_projectfile!` puts the first three back
// afterwards by reading each installed package's own `Project.toml`. Composing
// entries fresh here is therefore the faithful behaviour, not a shortcut — and
// carrying the old entry's `other` table across would be the divergence.
//
// Four fields are inputs rather than outputs and DO come from the old entry:
// `path`, `repo-url`/`repo-rev`/`repo-subdir` and `pinned`. `load_project_deps`
// (`:110-140`) reads exactly those off the existing manifest entry when it
// builds the PackageSpec a resolve starts from, so a dev'd or pinned package
// stays dev'd or pinned across one.
// ---------------------------------------------------------------------------

fn composeManifest(
    arena: Allocator,
    enc: *encode.Encoder,
    stdlibs: *const stdlib_mod.Set,
    proj: *const project_mod.Project,
    root_uuid: []const u8,
    old: ?manifest_mod.Manifest,
    sel: []const Selection,
    julia_version: jver.Version,
    project_file: []const u8,
    manifest_file: []const u8,
) !manifest_mod.Manifest {
    // Everything the manifest will contain, which is what every dependency
    // list is filtered against: `uuid in pkgs_uuids || continue` (`:616`).
    var selected: std.StringHashMapUnmanaged(jver.Version) = .empty;
    for (sel) |s| {
        if (std.mem.eql(u8, s.uuid, index.julia_uuid)) continue;
        try selected.put(arena, s.uuid, s.version);
    }
    const root_selected = proj.name != null and proj.uuid != null;
    if (root_selected) try selected.put(arena, root_uuid, proj.version orelse zero_version);

    var entries: std.ArrayList(manifest_mod.PackageEntry) = .empty;

    // --- the project's own entry -------------------------------------------
    //
    // `load_project_deps` (`:115-119`) adds it whenever the project has BOTH a
    // name and a uuid — a package, as opposed to a bare environment — with its
    // path relative to the manifest. Its dependency list comes from
    // `collect_project` (`:359-368`), which pushes `[deps]` AND `[weakdeps]`
    // into the same `requires`; the weak ones then drop out either because
    // they were not selected or, later, because the fixups pass deletes them.
    if (root_selected) {
        var deps: std.ArrayList(manifest_mod.Dep) = .empty;
        for ([_]*const project_mod.DepMap{ &proj.deps, &proj.weakdeps }) |m| {
            for (m.entries.items) |d| {
                const ut = try uuidText(arena, d.uuid);
                if (!selected.contains(ut)) continue;
                try deps.append(arena, .{ .name = d.name, .uuid = d.uuid });
            }
        }
        try entries.append(arena, .{
            .name = proj.name.?,
            .uuid = proj.uuid.?,
            .version = proj.version orelse zero_version,
            .path = try relativeProjectPath(arena, manifest_file, project_file),
            .deps = deps.items,
        });
    }

    // --- one entry per selected package ------------------------------------
    for (sel) |s| {
        if (std.mem.eql(u8, s.uuid, index.julia_uuid)) continue;
        if (std.mem.eql(u8, s.uuid, root_uuid)) continue;

        const prior: ?*const manifest_mod.PackageEntry = if (old) |m|
            m.findByUuid(try manifest_mod.Uuid.parse(s.uuid))
        else
            null;

        var e: manifest_mod.PackageEntry = .{
            .name = s.name,
            .uuid = try manifest_mod.Uuid.parse(s.uuid),
            .version = s.version,
        };
        if (prior) |p| {
            e.path = p.path;
            e.repo_url = p.repo_url;
            e.repo_rev = p.repo_rev;
            e.repo_subdir = p.repo_subdir;
            e.pinned = p.pinned;
        }

        if (stdlibs.byUuidText(s.uuid)) |sl| if (!sl.upgradable) {
            // `stdlib_version` (`Types.jl:600-609`) — `nothing` for a stdlib
            // that ships no `version` key, and `load_tree_hash!` (`:299-304`)
            // explicitly CLEARS any tree hash a stdlib carries.
            e.version = sl.version;
            e.tree_hash = null;
            e.deps = try stdlibDeps(arena, enc, sl, selected);
            try entries.append(arena, e);
            continue;
        };

        // A `develop`ed or repo-added entry is not in any registry, so there is
        // no version list to look a tree hash or a dependency set up in. Its
        // record is what the manifest already said plus the deps the solver was
        // given — `update_manifest!` writes back exactly the fixed package it
        // was handed (`Operations.jl:602-610`, the `fixed` branch of
        // `final_deps_map`, which reads `fixed[uuid].requires` rather than the
        // registry). Keeping its `path`/`repo-*` and its tree hash is already
        // handled above.
        if (e.path != null or e.repo_url != null) {
            var deps: std.ArrayList(manifest_mod.Dep) = .empty;
            // The INJECTED requires first, and `prior` only as a fallback.
            // `injectUntracked` read them out of the package's own
            // `Project.toml` — the only place they exist — and Pkg writes back
            // exactly that (`fixed[uuid].requires`), never the old manifest
            // entry.
            //
            // Reading `prior` alone was wrong in a way that only shows on the
            // FIRST `dev` of a package: with no prior entry the list came out
            // empty, `pruneManifest` then found the package's whole closure
            // unreachable, and the manifest was written with one entry where
            // Pkg writes fifteen. An environment that already had the entry
            // looked perfectly correct.
            if (enc.injectedFor(s.uuid)) |inj| {
                for (inj.deps) |d| {
                    if (!selected.contains(d.uuid)) continue;
                    try deps.append(arena, .{
                        .name = enc.displayName(d.uuid),
                        .uuid = try manifest_mod.Uuid.parse(d.uuid),
                    });
                }
            } else if (prior) |p| {
                for (p.deps) |d| {
                    const ut = try uuidText(arena, d.uuid);
                    if (!selected.contains(ut)) continue;
                    try deps.append(arena, d);
                }
            }
            e.deps = deps.items;
            if (prior) |p| e.tree_hash = p.tree_hash;
            try entries.append(arena, e);
            continue;
        }

        const info = (try enc.infoFor(s.uuid)) orelse {
            // Selected, but the registry does not have it and nothing injected
            // it. The solver cannot reach this — an unregistered uuid gets an
            // empty universe and is unselectable — so it means the encoder and
            // this function disagree about what a package is.
            return error.UnknownPackage;
        };
        const vi = info.indexOfVersion(s.version) orelse return error.UnknownVersion;

        // `tracking_registered_version` (`:299-320`): a path- or repo-tracked
        // entry keeps whatever hash the manifest had, and gets none from the
        // registry.
        if (e.path == null and e.repo_url == null) {
            e.tree_hash = try manifest_mod.Sha1.parse(info.versions[vi].tree_hash);
        } else if (prior) |p| {
            e.tree_hash = p.tree_hash;
        }

        var deps: std.ArrayList(manifest_mod.Dep) = .empty;
        for (info.deps[vi]) |d| {
            // "julia is an implicit dependency" and is filtered out by name
            // right before the map is stored (`:624`).
            if (std.mem.eql(u8, d.uuid, index.julia_uuid)) continue;
            // A weak edge is not a manifest `deps` entry. Pkg reaches the same
            // place by a different route — it writes the strong table, which
            // still holds names that are ALSO weak, and the fixups pass then
            // deletes exactly those (`:283-285`). Both land on: not here.
            if (d.weak) continue;
            if (!selected.contains(d.uuid)) continue;
            try deps.append(arena, .{
                .name = d.name,
                .uuid = try manifest_mod.Uuid.parse(d.uuid),
            });
        }
        e.deps = deps.items;
        try entries.append(arena, e);
    }

    var m: manifest_mod.Manifest = .{
        .julia_version = julia_version,
        .format = .{ .major = 2, .minor = 0, .patch = 0 },
        .entries = try pruneManifest(arena, entries.items, proj, root_selected),
    };
    // `record_project_hash` (`:246`). Goes through the setter because the
    // model's plain field is not what `destructure` emits — see the `other`
    // doc comment in `model/manifest.zig`.
    const digest = try project_hash_mod.compute(arena, proj.other());
    try m.setProjectHash(arena, try manifest_mod.Sha1.parse(&digest));
    return m;
}

const zero_version: jver.Version = .{ .major = 0, .minor = 0, .patch = 0 };

/// What one manifest entry contributes as a requirement, at one tier.
const Requirement = struct {
    pin: ?jver.Version = null,
    spec: ?jspec.Spec = null,

    fn dep(self: Requirement, uuid: []const u8) encode.Injected.Dep {
        return .{ .uuid = uuid, .pin = self.pin, .tier_spec = self.spec };
    }
};

/// `load_version` (`Operations.jl:56-68`), which is the whole of the tier
/// semantics. `null` means "no requirement at all" — `VersionSpec()` in Julia,
/// which is every version.
fn loadVersion(
    arena: Allocator,
    entry: manifest_mod.PackageEntry,
    tier: Tier,
    is_fixed: bool,
) !?Requirement {
    // ":57-58 — some stdlibs dont have a version". Unconstrained at every
    // tier, which is also why `unbind_stdlibs` never has to special-case them.
    const v = entry.version orelse return null;
    // ":59-60 — dont change state if a package is fixed". A dev'd, repo-tracked
    // or pinned entry holds even under `--preserve none`.
    if (is_fixed) return .{ .pin = v };
    return switch (tier) {
        .all, .all_installed, .direct => .{ .pin = v },
        // `semver_spec("$major.$minor.$patch")` — the CARET grammar, so 1.2.3
        // means [1.2.3, 2.0.0). Note this is the Project.toml grammar, not the
        // registry one a pin goes through; conflating the two is the trap
        // called out in the plan.
        .semver => .{ .spec = try jspec.semverSpec(
            arena,
            try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }),
        ) },
        .none => null,
        // `sequence()` expands these before anything reaches here.
        .tiered, .tiered_installed => unreachable,
    };
}

/// The version of the Julia installed at `prefix`, from
/// `include/julia/julia_version.h`'s `JULIA_VERSION_STRING`. Null when the
/// header is missing or unparseable — a caller that needs a version then says
/// so itself, rather than this guessing one.
fn juliaVersionAt(arena: Allocator, io: Io, prefix: []const u8) !?jver.Version {
    const path = try std.fs.path.join(arena, &.{ prefix, "include", "julia", "julia_version.h" });
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch return null;
    const needle = "#define JULIA_VERSION_STRING";
    const at = std.mem.indexOf(u8, src, needle) orelse return null;
    var rest = src[at + needle.len ..];
    const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    rest = rest[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return jver.parse(arena, rest[0..q2]) catch null;
}

/// Inject one `develop`ed or repo-added manifest entry as a fixed package.
///
/// `collect_fixed!` (`Operations.jl:418-475`) does the same thing: such a
/// package is not resolved, it is DECIDED — its version is whatever the source
/// on disk declares, and its dependencies become unconstrained requirements on
/// whatever else the environment holds. Without this the package is simply
/// absent from every registry, `universeFor` returns an empty universe, and any
/// requirement on it is unsatisfiable — which is exactly how this surfaced: a
/// `Pkg.develop`ed dependency made the whole resolve fail, and the error named
/// a bare UUID because an unregistered package has no name to print either.
///
/// Deps come from the package's own `Project.toml` when it can be read
/// (`collect_project`, `:350-378`, which reads `[deps]` AND `[weakdeps]`), and
/// fall back to the manifest entry's recorded `deps` when it cannot — a
/// repo-added package whose checkout is missing should still resolve from what
/// the manifest already knows rather than failing outright.
fn injectUntracked(
    arena: Allocator,
    io: Io,
    enc: *encode.Encoder,
    entry: manifest_mod.PackageEntry,
    opts: Options,
) !void {
    const uuid_text = try uuidText(arena, entry.uuid);
    var deps: std.ArrayList(encode.Injected.Dep) = .empty;

    // `source_path` (`Operations.jl:48-54`) in its own order: a TREE HASH
    // beats a `path`, and only then does `path` resolve against the manifest.
    // A repo-added entry has the first and not the second, and its source sits
    // at `find_installed(name, uuid, tree_hash)` — which is exactly where
    // `handle_repo_add!` put it. Reading it matters for the same reason the
    // `path` branch does: the manifest's own `deps` list carries uuids and no
    // `[compat]`, so falling back to it silently drops every bound the
    // repository's own project file declares.
    const source_dir: ?[]const u8 = blk: {
        if (entry.repo_url != null) {
            const th = entry.tree_hash orelse break :blk null;
            const stack = opts.depots orelse break :blk null;
            const found = depot.findInstalled(arena, io, stack, entry.name, entry.uuid, th) catch
                break :blk null;
            break :blk if (found.exists) found.path else null;
        }
        const rel = entry.path orelse break :blk null;
        const base = std.fs.path.dirname(opts.manifest_file orelse opts.project_file) orelse ".";
        break :blk try std.fs.path.resolve(arena, &.{ base, rel });
    };

    var from_project = false;
    if (source_dir) |dir| {
        const pf = try std.fs.path.join(arena, &.{ dir, "Project.toml" });
        if (Io.Dir.cwd().readFileAlloc(io, pf, arena, .limited(8 << 20))) |src| {
            if (project_mod.parse(arena, src, .{ .file = pf }, null)) |p| {
                for ([_]*const project_mod.DepMap{ &p.deps, &p.weakdeps }) |m| {
                    for (m.entries.items) |d| {
                        try deps.append(arena, .{
                            .uuid = try uuidText(arena, d.uuid),
                            .spec = compatFor(&p, d.name),
                        });
                    }
                }
                from_project = true;
            } else |_| {}
        } else |_| {}
    }
    if (!from_project) {
        for (entry.deps) |d| {
            try deps.append(arena, .{ .uuid = try uuidText(arena, d.uuid) });
        }
    }

    try enc.inject(.{
        .uuid = uuid_text,
        .name = entry.name,
        .version = entry.version orelse zero_version,
        .deps = deps.items,
    });
}

/// Where `collect_fixed!` reads a fixed package's own `Project.toml` from:
/// `source_path(env.manifest_file, pkg)` (`Operations.jl:445-451`, then
/// `:48-53`).
///
/// The branch ORDER is the point and it is `source_path`'s, not this module's
/// convenience: **the tree hash outranks the path.** A repo-added entry has no
/// `path` at all and lives under its depot slug, so keying on `entry.path` — as
/// this did before `[sources]` urls existed — gave a repo entry no project file
/// to read, an EMPTY injected dependency list, and a `pruneManifest` that then
/// deleted the package's whole closure. On a first resolve of a `[sources]` url
/// the manifest has no `deps` to fall back on either, so the closure simply
/// vanished.
///
/// The tree-hash branch is guarded on `repo_url` rather than taken
/// unconditionally, and that is deliberate conservatism rather than fidelity: a
/// `[sources]` PATH entry has its tree hash cleared by `load_all_deps`
/// (`Operations.jl:174-179`) and so never reaches the first branch in Pkg, but
/// Ajt does not yet apply that clearing, and a hand-edited manifest carrying
/// both keys would otherwise have flipped from the path to a stale slug.
fn untrackedSourceDir(
    arena: Allocator,
    io: Io,
    entry: manifest_mod.PackageEntry,
    opts: Options,
) !?[]const u8 {
    if (entry.repo_url != null) {
        const th = entry.tree_hash orelse return null;
        const stack = opts.depots orelse return null;
        const found = depot.findInstalled(arena, io, stack, entry.name, entry.uuid, th) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return if (found.exists) found.path else null;
    }
    const rel = entry.path orelse return null;
    const base = std.fs.path.dirname(opts.manifest_file orelse opts.project_file) orelse ".";
    return try std.fs.path.resolve(arena, &.{ base, rel });
}

// ---------------------------------------------------------------------------
// `[sources]` entries carrying a `url`
// ---------------------------------------------------------------------------
//
// ## Why this is a RESOLVE step
//
// The tempting change is in `instantiate`: `source_path` already has a
// `[sources]` branch, so teaching it about urls looks like the small edit. It
// is the wrong one. `get_path_repo` (`project.jl:7-25`) hands a `[sources]`
// entry back as `(path, GitRepo(url, rev, subdir))`, and a GitRepo is not a
// location — it is an instruction to go and FIND one. Pkg carries it out in
// `collect_fixed!` (`Operations.jl:432-444`), during resolution, and the answer
// — `git-tree-sha1` plus `repo-url`/`repo-rev`/`repo-subdir` — is written into
// the manifest by `update_manifest!` (`:224-248`). After that the entry is an
// ordinary repo-tracked entry that every later step already understands, which
// is why nothing downstream of here needed a url branch.
//
// Doing it in `instantiate` would also make the manifest a lie: it would record
// no tree hash for a package whose bytes are pinned by one, so `verify` could
// not check the source it installed and a second machine reading the file could
// not reproduce the same tree.
//
// ## Where the network actually happens
//
// Only when the source is not already unpacked. `collect_fixed!` guards the
// whole thing with `(path === nothing || !isdir(path))` (`:436`), so the steady
// state — a manifest that already pins the tree hash and a depot that already
// has it — touches no remote at all. A branch rev that IS unpacked is likewise
// left alone here; Pkg re-fetches a branch inside `handle_repo_add!`, which
// this only reaches when something is missing.

/// `load_all_deps`' `[sources]`-over-manifest merge for the url case
/// (`Operations.jl:170-186`), followed by `handle_repo_add!`
/// (`Types.jl:928-1050`) for whatever that merge left unresolved.
///
/// Mutates `man` — appending an entry for a `[sources]` url the manifest has
/// never seen, patching one it has — because that is precisely what Pkg does:
/// `load_manifest_deps` builds each PackageSpec FROM the manifest entry and the
/// override writes back into the same GitRepo object, and `update_manifest!`
/// then persists the mutated spec. Doing it here rather than in
/// `composeManifest` means `fixed`, `untracked` and `prior` all see one
/// consistent picture and none of them needs a `[sources]` special case.
///
/// **`subdir` is merged, not overwritten.** `load_all_deps` copies `.source`
/// and `.rev` out of the `[sources]` repo and nothing else (`:180-186`), while
/// `pkg.repo` still IS the manifest entry's GitRepo — so a manifest that
/// already records a `repo-subdir` keeps it, and the `[sources]` `subdir` only
/// applies where there is nothing to keep. That asymmetry is worth stating
/// because it means editing `subdir` in `Project.toml` does not move an
/// existing entry; `Pkg.rm` + `Pkg.add` does.
fn applySourceRepos(
    arena: Allocator,
    io: Io,
    opts: Options,
    proj: *const project_mod.Project,
    man: *?manifest_mod.Manifest,
) ![]const RepoSource {
    // The overwhelmingly common case: no `[sources]` at all, or only paths.
    // Checked before anything is allocated or any option is validated, so an
    // environment without a url source never needs `Options.git` set.
    var any = false;
    for (proj.sources.items) |s| {
        if (s.url != null) any = true;
    }
    if (!any) return &.{};

    const backend = opts.git orelse return Error.NoGitBackend;
    const scratch = opts.scratch orelse arena;
    const stack = opts.depots orelse return Error.NoDepotForRepoSource;
    const depot1 = stack.writeDepot() orelse return Error.NoDepotForRepoSource;
    const manifest_dir = std.fs.path.dirname(opts.manifest_file orelse opts.project_file) orelse ".";

    var entries: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    if (man.*) |m| try entries.appendSlice(arena, m.entries);

    var out: std.ArrayList(RepoSource) = .empty;

    for (proj.sources.items) |s| {
        const url_raw = s.url orelse continue;

        // Which package is this? `[deps]` first — that is `load_project_deps`
        // (`Operations.jl:122-126`), the path by which a `[sources]` entry
        // becomes a PackageSpec for a package the manifest has never heard of —
        // then any manifest entry of the same name, which is the `load_all_deps`
        // override (`:172-186`). A name that is neither (a `[sources]` entry for
        // an `[extras]`-only package, which `read_project_sources` permits)
        // never reaches a resolve in Pkg either, so it is skipped rather than
        // refused.
        const uuid = uuidForSourceName(proj, entries.items, s.name) orelse continue;

        var idx: usize = entries.items.len;
        for (entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, &e.uuid.bytes, &uuid.bytes)) {
                idx = i;
                break;
            }
        }
        if (idx == entries.items.len) {
            try entries.append(arena, .{ .name = s.name, .uuid = uuid });
        }
        const e = &entries.items[idx];

        // `repo_source` (`Types.jl:948-984`): a url is used verbatim; anything
        // else names a local git repository, resolved against the MANIFEST's
        // directory and canonicalised before it becomes the clone cache key.
        const source = try repoSource(arena, io, url_raw, manifest_dir);

        // `:176-186`. The repo takes precedence over any `path` the manifest
        // recorded; `rev` is replaced only when `[sources]` supplies one.
        e.path = null;
        e.repo_url = source.recorded;
        if (s.rev) |r| e.repo_rev = r;
        if (e.repo_subdir == null) e.repo_subdir = s.subdir;

        // `collect_fixed!`'s guard (`Operations.jl:434-436`): the repository is
        // only touched when the source is not already on disk.
        var installed: ?[]const u8 = null;
        if (e.tree_hash) |th| {
            const found = try depot.findInstalled(arena, io, stack, e.name, e.uuid, th);
            if (found.exists) installed = found.path;
        }

        var outcome: RepoSource.Outcome = .already_installed;
        if (installed == null) {
            const added = try handleRepoAdd(arena, scratch, io, opts, .{
                .backend = backend,
                .stack = stack,
                .clone_dir = try depot1.cloneUrlDir(arena, source.clone_key),
                .remote = source.clone_key,
                .name = e.name,
                .uuid = e.uuid,
                .rev = e.repo_rev,
                .subdir = e.repo_subdir,
                .tree_hash = e.tree_hash,
                .pinned = e.pinned,
            });
            e.tree_hash = added.tree;
            e.repo_rev = added.rev;
            outcome = if (added.materialised) .materialised else .already_installed;
            const found = try depot.findInstalled(arena, io, stack, e.name, e.uuid, added.tree);
            installed = found.path;
        }

        // `resolve_projectfile!` (`Types.jl:1071-1092`) and `collect_project`'s
        // version read (`Operations.jl:360-372`). The version of a fixed package
        // is whatever its own `Project.toml` declares — never the registry, and
        // never the old manifest entry — so this is the only place the written
        // `version = "…"` can come from.
        e.version = try sourceProjectVersion(arena, io, opts, installed.?, e.name, e.uuid);

        try out.append(arena, .{
            .name = e.name,
            .url = e.repo_url.?,
            .rev = e.repo_rev orelse "",
            .subdir = e.repo_subdir,
            .tree_hash = e.tree_hash.?,
            .outcome = outcome,
        });
    }

    if (man.*) |*m| {
        m.entries = entries.items;
    } else {
        man.* = .{ .entries = entries.items };
    }
    return out.items;
}

/// The uuid a `[sources]` name resolves to. See `applySourceRepos` for the
/// order and why a name in neither place is skipped.
fn uuidForSourceName(
    proj: *const project_mod.Project,
    entries: []const manifest_mod.PackageEntry,
    name: []const u8,
) ?stdlib_mod.Uuid {
    for (proj.deps.entries.items) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.uuid;
    }
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.uuid;
    }
    return null;
}

/// What `pkg.repo.source` becomes, and what it is cloned FROM
/// (`Types.jl:948-984`).
///
/// These are two different strings for a local repository and one string for a
/// url, which is the only reason this is a struct. Pkg canonicalises a local
/// path with `safe_realpath` *before* hashing it into the clone cache name
/// (`:975-977`) — so two spellings of the same directory share one clone — and
/// then records it back either absolute or manifest-relative, matching the form
/// the user wrote (`:978`).
const RepoSourcePaths = struct {
    /// Goes into `repo-url`.
    recorded: []const u8,
    /// Goes to `git clone`, and is the string `add_repo_cache_path` hashes.
    clone_key: []const u8,
};

fn repoSource(
    arena: Allocator,
    io: Io,
    raw: []const u8,
    manifest_dir: []const u8,
) !RepoSourcePaths {
    // `isurl` first, `classify` after — a url is never a path, and asking the
    // filesystem about `https://…` would be nonsense.
    if (git_mod.url.isUrl(raw)) return .{ .recorded = raw, .clone_key = raw };

    const absolute = std.fs.path.isAbsolute(raw);
    const joined = if (absolute) raw else try std.fs.path.resolve(arena, &.{ manifest_dir, raw });
    // `safe_realpath` — "safe" in Pkg means it returns the input unchanged when
    // the path does not resolve, rather than throwing (`utils.jl:24-31`). The
    // clone step then fails with a message naming the directory, which is a
    // better error than one naming `realpath`.
    const real = Io.Dir.cwd().realPathFileAlloc(io, joined, arena) catch joined;
    // `relative_project_path` realpaths BOTH sides (`Types.jl:749-753`), and it
    // has to: `relpath` compares components textually, so a symlinked start and
    // a resolved path would produce a chain of `..` that climbs out of the
    // environment.
    const base = Io.Dir.cwd().realPathFileAlloc(io, manifest_dir, arena) catch manifest_dir;
    return .{
        .recorded = if (absolute) real else try relpath(arena, real, base),
        .clone_key = real,
    };
}

const RepoAdd = struct {
    backend: git_mod.Backend,
    stack: depot.Stack,
    clone_dir: []const u8,
    remote: []const u8,
    name: []const u8,
    uuid: manifest_mod.Uuid,
    rev: ?[]const u8,
    subdir: ?[]const u8,
    tree_hash: ?manifest_mod.Sha1,
    pinned: bool,
};

const RepoAdded = struct {
    tree: manifest_mod.Sha1,
    rev: []const u8,
    materialised: bool,
};

/// `handle_repo_add!` (`Types.jl:988-1050`), from `ensure_clone` to the
/// `mv temp_path version_path` — the half that runs once the source is known to
/// be a repository. Everything above it (`set_repo_source_from_registry!`,
/// the local-directory validation) is either not reachable from `[sources]` —
/// which always supplies the url — or handled by `repoSource`.
///
/// Three sequencing traps, all of them Pkg's and all of them load-bearing:
///
///  1. **`rev_or_hash` is the TREE HASH when the manifest has one** (`:1000`).
///     A cold depot re-installing an entry the manifest already pins therefore
///     asks git for the tree object, not for the branch — which is what makes
///     the reinstall reproduce the pinned bytes instead of silently following
///     the branch forward. It also means `subdir` is applied a SECOND time in
///     that case, because the recorded hash is already the sub-tree's; Pkg has
///     the same defect and it surfaces as "Did not find subdirectory".
///  2. **Two fetches, in this order** (`:1003-1010`): branches first
///     (`refspecs`), everything second (`refspecs_fallback`). The fallback drags
///     every tag and every pull-request ref on a large repository, which is why
///     it is not simply the first attempt.
///  3. **An unpinned BRANCH is re-fetched before its tree is taken**
///     (`:1014-1020`), and only when the first two steps did not already fetch.
///     This is the entire difference between `rev = "main"` and `rev = "v1.0"`:
///     a branch resolve is expected to move, so a resolve that skipped this
///     would pin whatever the local clone happened to have.
fn handleRepoAdd(
    arena: Allocator,
    scratch: Allocator,
    io: Io,
    opts: Options,
    req: RepoAdd,
) !RepoAdded {
    const backend = req.backend;

    backend.ensureClone(scratch, io, req.clone_dir, req.remote, .{ .bare = true }) catch |err| switch (err) {
        // The two REFUSALS get their own sentences, because "CloneFailed" on an
        // `ssh://` or an `ext::` url reads as a network problem and sends the
        // user looking in the wrong place entirely.
        error.SshUnsupported => {
            noteFailure(opts, arena, "[sources] url `{s}`: {s}\n", .{
                req.remote, git_mod.ssh_unsupported_message,
            });
            return err;
        },
        error.TransportHelperUnsupported => {
            noteFailure(opts, arena, "[sources] url `{s}`: {s}\n", .{
                req.remote, git_mod.transport_helper_message,
            });
            return err;
        },
        else => {
            noteFailure(opts, arena, "failed to clone `{s}` ({s})\n", .{ req.remote, @errorName(err) });
            return err;
        },
    };

    // `:996-999` — no rev given means the clone's default branch, or its
    // current commit when HEAD is detached.
    const rev = if (req.rev) |r| r else backend.defaultRev(scratch, arena, io, req.clone_dir) catch |err| {
        noteFailure(opts, arena, "invalid git HEAD in `{s}`\n", .{req.clone_dir});
        return err;
    };

    var hash_buf: [40]u8 = undefined;
    const rev_or_hash = if (req.tree_hash) |th| manifest_mod.formatSha1(th, &hash_buf) else rev;

    var fetched = false;
    var obj = try backend.resolveRev(scratch, io, req.clone_dir, rev_or_hash);
    if (obj == null) {
        fetched = true;
        try backend.fetch(scratch, io, req.clone_dir, req.remote, git_mod.refspecs_heads);
        obj = try backend.resolveRev(scratch, io, req.clone_dir, rev_or_hash);
        if (obj == null) {
            try backend.fetch(scratch, io, req.clone_dir, req.remote, git_mod.refspecs_all);
            obj = try backend.resolveRev(scratch, io, req.clone_dir, rev_or_hash);
        }
    }
    var resolved = obj orelse {
        // `:1009`, verbatim.
        noteFailure(opts, arena, "Did not find rev {s} in repository\n", .{rev_or_hash});
        return error.RevNotFound;
    };

    if (resolved.is_branch and !fetched and !req.pinned) {
        try backend.fetch(scratch, io, req.clone_dir, req.remote, git_mod.refspecs_heads);
        // Pkg destructures the retry without a null check (`:1019`), i.e. a rev
        // that vanished between the two calls is an unhandled MethodError there.
        resolved = (try backend.resolveRev(scratch, io, req.clone_dir, rev_or_hash)) orelse {
            noteFailure(opts, arena, "Did not find rev {s} in repository\n", .{rev_or_hash});
            return error.RevNotFound;
        };
    }

    const commit_hex = std.fmt.bytesToHex(resolved.commit.bytes, .lower);
    const tree = backend.treeOf(scratch, io, req.clone_dir, &commit_hex, req.subdir) catch |err| {
        if (err == error.SubdirNotFound) {
            // `:1029`, verbatim.
            noteFailure(opts, arena, "Did not find subdirectory `{s}`\n", .{req.subdir.?});
        }
        return err;
    };

    // `:1035-1038` — a known uuid means the canonical path can be computed
    // before anything is written, and an already-unpacked tree needs no work.
    const found = try depot.findInstalled(arena, io, req.stack, req.name, req.uuid, tree);
    if (found.exists) return .{ .tree = tree, .rev = rev, .materialised = false };

    // Pkg stages under `mktempdir()` and finishes with `mv`, which degrades to
    // a non-atomic copy across filesystems (`:1040-1047`). `depot.begin` stages
    // a SIBLING of the destination, so the publish is one `renameat` and a
    // concurrent installer either sees the old state or the new one.
    var inst = try depot.begin(arena, io, found.path);
    defer inst.deinit(io);
    const staging = try std.fs.path.join(arena, &.{
        std.fs.path.dirname(found.path) orelse ".",
        &inst.tmp_name,
    });
    try backend.materialise(scratch, io, req.clone_dir, tree, staging);

    // `git.zig`'s hard postcondition, checked rather than trusted: the depot
    // slug is `versionSlug(uuid, tree_hash)`, so publishing a directory that
    // does not hash to `tree` would name it by a hash its contents do not have.
    // Pkg never makes this check — `checkout_tree_to_path` can rewrite line
    // endings through `.gitattributes` and nothing notices.
    const got = try treehash.hashPath(scratch, io, staging);
    if (!std.mem.eql(u8, &got, &tree.bytes)) {
        noteFailure(opts, arena, "materialised tree of `{s}` hashes to {s}, not {s}\n", .{
            req.name,
            &treehash.toHex(got),
            manifest_mod.formatSha1(tree, &hash_buf),
        });
        return error.TreeHashMismatch;
    }

    _ = try inst.commit(scratch, io, .{});
    return .{ .tree = tree, .rev = rev, .materialised = true };
}

/// `resolve_projectfile!` (`Types.jl:1071-1092`) plus the version half of
/// `collect_project` (`Operations.jl:360-372`).
///
/// Pkg splits these across two call sites and they read the same file; keeping
/// them together here is the one liberty taken, because the checks only make
/// sense against the project that supplied the version. A package whose
/// `Project.toml` declares no `version` is `VersionNumber(0)` (`:365-369`), NOT
/// "unversioned" — the manifest gets `version = "0.0.0"`.
fn sourceProjectVersion(
    arena: Allocator,
    io: Io,
    opts: Options,
    dir: []const u8,
    name: []const u8,
    uuid: manifest_mod.Uuid,
) !jver.Version {
    // `projectfile_path(path; strict = true)` — `JuliaProject.toml` first.
    var src: ?[]const u8 = null;
    var file: []const u8 = "";
    for (stdlib_mod.project_names) |base| {
        const path = try std.fs.path.join(arena, &.{ dir, base });
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20))) |s| {
            src = s;
            file = path;
            break;
        } else |err| switch (err) {
            error.Canceled => return err,
            error.OutOfMemory => return err,
            else => {},
        }
    }
    const text = src orelse {
        noteFailure(opts, arena, "could not find project file (Project.toml or JuliaProject.toml) in package at `{s}` " ++
            "maybe `subdir` needs to be specified\n", .{dir});
        return Error.SourceProjectMismatch;
    };

    const p = project_mod.parse(arena, text, .{ .file = file }, null) catch {
        noteFailure(opts, arena, "could not read project file `{s}`\n", .{file});
        return Error.SourceProjectMismatch;
    };
    if (p.uuid) |u| {
        if (!std.mem.eql(u8, &u.bytes, &uuid.bytes)) {
            noteFailure(opts, arena, "UUID `{s}` given by project file `{s}` does not match given UUID `{s}`\n", .{
                try uuidText(arena, u), file, try uuidText(arena, uuid),
            });
            return Error.SourceProjectMismatch;
        }
    }
    if (p.name) |n| {
        if (!std.mem.eql(u8, n, name)) {
            noteFailure(opts, arena, "name `{s}` given by project file `{s}` does not match given name `{s}`\n", .{ n, file, name });
            return Error.SourceProjectMismatch;
        }
    }
    return p.version orelse zero_version;
}

/// Leave a user-facing explanation on the diagnostic before returning a domain
/// error, so `ajt resolve` can print Pkg's own sentence instead of dumping a
/// Zig stack trace through the git backend. Silent when there is no diagnostic
/// and silent on allocation failure — a failure path must not fail.
fn noteFailure(opts: Options, arena: Allocator, comptime fmt: []const u8, args: anytype) void {
    const d = opts.diagnostic orelse return;
    d.report = std.fmt.allocPrint(arena, fmt, args) catch return;
}

/// The depot side of `installed_only`. Lives here rather than in the encoder
/// because it stats the filesystem, and `src/solver/` does not.
///
/// **One known gap, and it is Pkg's predicate that is wider.**
/// `is_package_downloaded` (`Operations.jl:2723-2729`) is
/// `isdir(source_path) && check_artifacts_downloaded(sourcepath; platform)` —
/// a package whose SOURCE is unpacked but whose artifacts are not counts as
/// NOT downloaded, and Pkg therefore drops that version as a candidate. This
/// checks only the source directory, so it would keep it. The two agree on
/// every package with no artifacts and on any depot that was never interrupted
/// mid-install; they part company on a half-installed JLL. Recorded in
/// `Ajt.DIFFERENCES[:offline]` rather than papered over, because closing it
/// means giving the resolver a host platform and an `Artifacts.toml` reader,
/// which is a change to what a resolve IS.
const InstalledCtx = struct {
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    /// Memo, keyed by tree hash. A hash names one tree and therefore one
    /// (package, version) globally, so it is a complete key on its own — and
    /// it is already arena-owned by `index.PackageInfo`, so nothing is copied
    /// to store it. Sound because the answer cannot change during a resolve:
    /// this module installs nothing.
    seen: std.StringHashMapUnmanaged(bool) = .empty,

    fn lookup(ctx: *const anyopaque, name: []const u8, uuid_text: []const u8, tree_hash: []const u8) bool {
        // Const-cast: `encode.Installed` hands out a `*const anyopaque` because
        // a filter has no business mutating the resolve, and the memo does not
        // — it only remembers. Keeping the vtable pointer const is worth this
        // one line.
        const self: *InstalledCtx = @ptrCast(@alignCast(@constCast(ctx)));
        if (self.seen.get(tree_hash)) |hit| return hit;

        const answer = blk: {
            const uuid = stdlib_mod.Uuid.parse(uuid_text) catch break :blk false;
            const hash = manifest_mod.Sha1.parse(tree_hash) catch break :blk false;
            break :blk depot.installedExists(self.io, self.stack, name, uuid, hash);
        };
        // A memo that cannot be written is a slow memo, not a wrong one.
        self.seen.put(self.arena, tree_hash, answer) catch {};
        return answer;
    }
};

/// `Base.thispatch(a) == Base.thispatch(b)` — equal on `(major, minor, patch)`,
/// ignoring prerelease and build. The predicate the JLL fixup turns on.
fn thisPatchEql(a: jver.Version, b: jver.Version) bool {
    return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
}

/// `prune_manifest` (`Operations.jl:1252-1292`): keep the project's own uuid
/// and its direct `[deps]`, then close over `entry.deps` to a fixpoint and drop
/// everything else.
///
/// This is not tidying, and skipping it is not conservative. Two consequences,
/// both observed on Open-Reality:
///
///  1. A manifest can carry entries no strong edge reaches. Its committed
///     manifest has nine — `Vulkan`, `VulkanCore`, `Vulkan_Headers_jll` and the
///     rest of that closure — reachable only through the `[weakdeps]` of the
///     `OpenRealityVulkanExt` extension, which `prune_deps` does NOT follow. So
///     stock `Pkg.resolve()` writes 205 entries where the committed file has
///     214. The committed file is therefore not what Pkg produces today, and
///     "reproduce the committed bytes" would have been a gate against a target
///     Pkg itself misses.
///  2. Pruning changes how OTHER entries render. `weakdeps` emits as a sorted
///     name array only when every name is itself a manifest entry
///     (`manifest.jl:338-345`), so dropping `Vulkan` flips `OpenReality`'s
///     `weakdeps = ["Vulkan"]` into a `[deps.OpenReality.weakdeps]` table. A
///     writer that skipped the prune would differ from Pkg in a second place
///     that looks unrelated to the first.
pub fn pruneManifest(
    arena: Allocator,
    entries: []const manifest_mod.PackageEntry,
    proj: *const project_mod.Project,
    keep_root: bool,
) Allocator.Error![]const manifest_mod.PackageEntry {
    var keep: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
    for (proj.deps.entries.items) |d| try keep.put(arena, d.uuid.bytes, {});
    if (keep_root) {
        if (proj.uuid) |u| try keep.put(arena, u.bytes, {});
    }

    // `prune_deps`' own shape: sweep until a pass adds nothing. Quadratic in
    // the worst case and irrelevant at manifest sizes — 214 entries settle in
    // three passes.
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

    var kept: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    for (entries) |e| {
        if (keep.contains(e.uuid.bytes)) try kept.append(arena, e);
    }
    return kept.items;
}

/// A fixed stdlib's manifest `deps`: its `[deps]` uuids, filtered to what the
/// manifest holds. `deps_graph` gives a stdlib node one unconstrained edge per
/// entry in `stdlib_info.deps` (`Operations.jl:681-684`), and those edges are
/// what `final_deps_map` then reads back.
fn stdlibDeps(
    arena: Allocator,
    enc: *const encode.Encoder,
    sl: *const stdlib_mod.Stdlib,
    selected: std.StringHashMapUnmanaged(jver.Version),
) !([]const manifest_mod.Dep) {
    var deps: std.ArrayList(manifest_mod.Dep) = .empty;
    for (sl.deps) |d| {
        const ut = try uuidText(arena, d);
        if (!selected.contains(ut)) continue;
        try deps.append(arena, .{ .name = enc.displayName(ut), .uuid = d });
    }
    return deps.items;
}

/// `Types.relative_project_path` (`Types.jl:749-753`): `relpath` of the
/// project directory against the manifest's, after resolving symlinks. The
/// answer is `"."` for the overwhelmingly common case of the two files sitting
/// side by side, and that is the only value a Pkg-written manifest for a
/// package project normally contains — but "normally" is not "always", so the
/// general form is here rather than a hardcoded dot.
fn relativeProjectPath(
    arena: Allocator,
    manifest_file: []const u8,
    project_file: []const u8,
) Allocator.Error![]const u8 {
    const from = std.fs.path.dirname(manifest_file) orelse ".";
    const to = std.fs.path.dirname(project_file) orelse ".";
    return relpath(arena, to, from);
}

/// POSIX `relpath(path, start)`. Julia's own is `Base.relpath`, which splits
/// both on the separator, drops the common prefix, and emits one `..` per
/// remaining component of `start` — including the rule that no remainder on
/// either side is `"."` rather than the empty string.
fn relpath(arena: Allocator, path: []const u8, start: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, path, start)) return ".";

    var pit = std.mem.tokenizeScalar(u8, path, '/');
    var sit = std.mem.tokenizeScalar(u8, start, '/');
    var pcomp: std.ArrayList([]const u8) = .empty;
    var scomp: std.ArrayList([]const u8) = .empty;
    while (pit.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        try pcomp.append(arena, c);
    }
    while (sit.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        try scomp.append(arena, c);
    }
    // An absolute path relative to a relative start (or the reverse) has no
    // meaningful answer without a cwd; hand back the path itself, which is
    // what Julia's relpath effectively does once the prefixes cannot align.
    if (std.fs.path.isAbsolute(path) != std.fs.path.isAbsolute(start)) {
        return arena.dupe(u8, path);
    }

    var common: usize = 0;
    while (common < pcomp.items.len and common < scomp.items.len and
        std.mem.eql(u8, pcomp.items[common], scomp.items[common])) : (common += 1)
    {}

    var out: std.ArrayList(u8) = .empty;
    for (common..scomp.items.len) |_| {
        if (out.items.len != 0) try out.append(arena, '/');
        try out.appendSlice(arena, "..");
    }
    for (pcomp.items[common..]) |c| {
        if (out.items.len != 0) try out.append(arena, '/');
        try out.appendSlice(arena, c);
    }
    if (out.items.len == 0) return ".";
    return out.items;
}

fn compatFor(proj: *const project_mod.Project, name: []const u8) ?jspec.Spec {
    for (proj.compat.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.spec;
    }
    return null;
}

/// Canonical 8-4-4-4-12 text. Duplicated from `solver/encode.zig` rather than
/// exported from it, because that one is private to the encoder's own needs;
/// if a third caller appears this belongs in `julia/slug.zig`.
fn uuidText(arena: Allocator, u: stdlib_mod.Uuid) Allocator.Error![]const u8 {
    const hex = "0123456789abcdef";
    const out = try arena.alloc(u8, 36);
    var oi: usize = 0;
    for (u.bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0xf];
        oi += 2;
    }
    return out;
}

test {
    _ = Tier;
    _ = Report;
}

const testing = std.testing;

test "relpath reproduces Base.relpath" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // Every expectation here was printed by `julia -e 'relpath(p, s)'`, not
    // reasoned out: the ".." counting is exactly the kind of thing that is
    // right for the cases you think of and off by one for the others.
    const cases = [_]struct { p: []const u8, s: []const u8, want: []const u8 }{
        .{ .p = "/a/b", .s = "/a/b", .want = "." },
        .{ .p = "/a/b/c", .s = "/a/b", .want = "c" },
        .{ .p = "/a/b", .s = "/a/b/c", .want = ".." },
        .{ .p = "/a/b/c", .s = "/a/x/y", .want = "../../b/c" },
        .{ .p = "/a", .s = "/a/b/c/d", .want = "../../.." },
        .{ .p = "a/b", .s = "a", .want = "b" },
        .{ .p = "/e", .s = "/e/shared", .want = ".." },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.want, try relpath(g, c.p, c.s));
    }
}

test "relativeProjectPath is '.' for a manifest beside its project" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    try testing.expectEqualStrings(
        ".",
        try relativeProjectPath(g, "/env/Manifest.toml", "/env/Project.toml"),
    );
    // `[manifest] = "../shared/Manifest.toml"` — the case `verify` already
    // supports and the reason this is not hardcoded to a dot.
    try testing.expectEqualStrings(
        "..",
        try relativeProjectPath(g, "/env/shared/Manifest.toml", "/env/Project.toml"),
    );
}

test "pruneManifest keeps the strong closure and nothing else" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var proj = try project_mod.parse(g,
        \\name = "Root"
        \\uuid = "00000000-0000-0000-0000-0000000000f0"
        \\
        \\[deps]
        \\Direct = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\Weak = "00000000-0000-0000-0000-000000000003"
        \\
    , .{}, null);

    const u = struct {
        fn p(text: []const u8) manifest_mod.Uuid {
            return manifest_mod.Uuid.parse(text) catch unreachable;
        }
    };
    const root = u.p("00000000-0000-0000-0000-00000000f000");
    const direct = u.p("00000000-0000-0000-0000-000000000001");
    const trans = u.p("00000000-0000-0000-0000-000000000002");
    const weak = u.p("00000000-0000-0000-0000-000000000003");
    const orphan = u.p("00000000-0000-0000-0000-000000000004");

    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "Root", .uuid = root, .deps = &.{.{ .name = "Direct", .uuid = direct }} },
        .{ .name = "Direct", .uuid = direct, .deps = &.{.{ .name = "Trans", .uuid = trans }} },
        .{ .name = "Trans", .uuid = trans },
        // Reachable only as a `[weakdeps]` of the root. `prune_deps` walks
        // `entry.deps` and nothing else, so this goes — which is exactly what
        // costs Open-Reality's committed manifest its nine Vulkan entries.
        .{ .name = "Weak", .uuid = weak },
        .{ .name = "Orphan", .uuid = orphan },
    };

    // `keep_root = false`: the project's uuid here is not one of the entries'
    // (Root's entry uuid differs deliberately), so this exercises the closure
    // from `[deps]` alone.
    const kept = try pruneManifest(g, &entries, &proj, false);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("Direct", kept[0].name);
    try testing.expectEqualStrings("Trans", kept[1].name);
}

// ---------------------------------------------------------------------------
// `[sources]` urls
// ---------------------------------------------------------------------------

/// A git backend that answers from a script instead of a repository.
///
/// The point of the tests below is the ORDER of the calls `handle_repo_add!`
/// makes — clone, then resolve, then two fetches with different refspecs, then
/// the branch re-fetch — and that order is invisible to an end-to-end test
/// against a real remote, which succeeds on the first probe every time. So the
/// backend records every call and the tests assert the transcript.
const FakeGit = struct {
    arena: Allocator,
    /// How many `resolveRev` calls return null before one succeeds. 0 is the
    /// warm clone, 1 forces the branch fetch, 2 the fallback fetch, more the
    /// "Did not find rev" refusal.
    null_until: usize = 0,
    resolves: usize = 0,
    is_branch: bool = false,
    tree: git_mod.TreeId = .{ .bytes = @splat(0) },
    subdir_missing: bool = false,
    /// Written into the staging directory by `materialise`, as name/bytes
    /// pairs. Left empty when the test expects no materialisation at all.
    files: []const [2][]const u8 = &.{},
    head: []const u8 = "master",
    log: std.ArrayList([]const u8) = .empty,

    fn backend(self: *FakeGit) git_mod.Backend {
        return .{ .ctx = self, .vtable = &fake_vtable, .which = .cli };
    }

    fn note(self: *FakeGit, what: []const u8) Allocator.Error!void {
        try self.log.append(self.arena, what);
    }

    fn ensureClone(ctx: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: git_mod.CloneOptions) git_mod.Error!void {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note("clone");
    }

    fn defaultRev(ctx: *anyopaque, _: Allocator, arena: Allocator, _: Io, _: []const u8) git_mod.Error![]const u8 {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note("defaultRev");
        return arena.dupe(u8, self.head);
    }

    fn fetch(ctx: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, refspec: []const u8) git_mod.Error!void {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note(if (std.mem.eql(u8, refspec, git_mod.refspecs_heads)) "fetch:heads" else "fetch:all");
    }

    fn resolveRev(ctx: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git_mod.Error!?git_mod.Rev {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note("resolve");
        defer self.resolves += 1;
        if (self.resolves < self.null_until) return null;
        return .{ .commit = .{ .bytes = @splat(0xab) }, .is_branch = self.is_branch };
    }

    fn treeOf(ctx: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, subdir: ?[]const u8) git_mod.Error!git_mod.TreeId {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note("tree");
        if (subdir != null and self.subdir_missing) return error.SubdirNotFound;
        return self.tree;
    }

    fn hasObject(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: git_mod.Sha1) git_mod.Error!bool {
        return true;
    }

    fn materialise(ctx: *anyopaque, _: Allocator, io: Io, _: []const u8, _: git_mod.TreeId, dest: []const u8) git_mod.Error!void {
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        try self.note("materialise");
        var dir = Io.Dir.cwd().openDir(io, dest, .{}) catch return error.CloneFailed;
        defer dir.close(io);
        for (self.files) |f| {
            dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] }) catch return error.CloneFailed;
        }
    }

    fn unsupportedClone(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git_mod.Error!void {
        return error.Unsupported;
    }
    fn unsupportedBool(_: *anyopaque, _: Allocator, _: Io, _: []const u8) git_mod.Error!bool {
        return error.Unsupported;
    }
    fn unsupportedOptStr(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8) git_mod.Error!?[]const u8 {
        return error.Unsupported;
    }
    fn unsupportedRemoteUrl(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8, _: []const u8) git_mod.Error!?[]const u8 {
        return error.Unsupported;
    }
    fn unsupportedBranchBool(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git_mod.Error!bool {
        return error.Unsupported;
    }
    fn unsupportedRebase(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git_mod.Error!void {
        return error.Unsupported;
    }
};

const fake_vtable: git_mod.Backend.VTable = .{
    .ensureClone = FakeGit.ensureClone,
    .defaultRev = FakeGit.defaultRev,
    .fetch = FakeGit.fetch,
    .resolveRev = FakeGit.resolveRev,
    .treeOf = FakeGit.treeOf,
    .hasObject = FakeGit.hasObject,
    .materialise = FakeGit.materialise,
    // The six repository operations a sibling unit added for `registry update`
    // on a git clone. This fake drives `handle_repo_add!` and nothing else, so
    // they are `Unsupported` rather than a second fake nobody reads.
    .cloneWorking = FakeGit.unsupportedClone,
    .isDirty = FakeGit.unsupportedBool,
    .headBranch = FakeGit.unsupportedOptStr,
    .remoteUrl = FakeGit.unsupportedRemoteUrl,
    .fastForward = FakeGit.unsupportedBranchBool,
    .rebase = FakeGit.unsupportedRebase,
};

fn expectTranscript(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

const example_uuid = "7876af07-990d-54b4-ab0e-23690620f79a";

const FakePackage = struct { src: []const u8, tree: git_mod.TreeId };

/// A one-file package's `Project.toml`, and the tree hash a directory holding
/// only it will have.
///
/// Both are needed together: `handleRepoAdd` verifies the materialised bytes
/// against the tree it was told to fetch, so a test that invents a tree id gets
/// `TreeHashMismatch` rather than the path it meant to exercise.
fn fakePackage(arena: Allocator, io: Io, tmp: *std.testing.TmpDir) !FakePackage {
    const body =
        \\name = "Example"
        \\uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        \\version = "0.5.5"
        \\
    ;
    try tmp.dir.createDirPath(io, "model");
    try tmp.dir.writeFile(io, .{ .sub_path = "model/Project.toml", .data = body });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const model = try std.fs.path.join(arena, &.{ root, "model" });
    return .{ .src = body, .tree = .{ .bytes = try treehash.hashPath(arena, io, model) } };
}

test "handle_repo_add! probes, then fetches branches, then fetches everything" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const pkg = try fakePackage(arena, io, &tmp);
    const depot_root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const stack: depot.Stack = .{ .entries = try arena.dupe([]const u8, &.{depot_root}) };
    const opts: Options = .{ .project_file = "Project.toml", .registry_depot = depot_root };
    const clone_dir = try std.fs.path.join(arena, &.{ depot_root, "clones", "1" });
    const uuid = try manifest_mod.Uuid.parse(example_uuid);

    // Cold clone: the rev is not present, the branch fetch does not produce it,
    // and only the `refspecs_fallback` fetch does. Getting the two refspecs the
    // wrong way round would still pass an end-to-end test while dragging every
    // tag and pull-request ref of every repository into every clone.
    var fake: FakeGit = .{
        .arena = arena,
        .null_until = 2,
        .tree = pkg.tree,
        .files = &.{.{ "Project.toml", pkg.src }},
    };
    const added = try handleRepoAdd(arena, arena, io, opts, .{
        .backend = fake.backend(),
        .stack = stack,
        .clone_dir = clone_dir,
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = uuid,
        .rev = "v0.5.5",
        .subdir = null,
        .tree_hash = null,
        .pinned = false,
    });
    try expectTranscript(&.{
        "clone", "resolve", "fetch:heads", "resolve", "fetch:all", "resolve", "tree", "materialise",
    }, fake.log.items);
    try testing.expect(added.materialised);
    try testing.expectEqualStrings("v0.5.5", added.rev);
    try testing.expectEqualSlices(u8, &pkg.tree.bytes, &added.tree.bytes);

    // ...and the tree landed under its slug, so a second call finds it there
    // and stops before writing anything (`Types.jl:1035-1038`).
    var again: FakeGit = .{ .arena = arena, .tree = pkg.tree };
    const second = try handleRepoAdd(arena, arena, io, opts, .{
        .backend = again.backend(),
        .stack = stack,
        .clone_dir = clone_dir,
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = uuid,
        .rev = "v0.5.5",
        .subdir = null,
        .tree_hash = null,
        .pinned = false,
    });
    try expectTranscript(&.{ "clone", "resolve", "tree" }, again.log.items);
    try testing.expect(!second.materialised);
}

test "an unpinned branch is re-fetched before its tree is taken; a pinned one is not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const pkg = try fakePackage(arena, io, &tmp);
    const depot_root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const stack: depot.Stack = .{ .entries = try arena.dupe([]const u8, &.{depot_root}) };
    const opts: Options = .{ .project_file = "Project.toml", .registry_depot = depot_root };

    const req: RepoAdd = .{
        .backend = undefined,
        .stack = stack,
        .clone_dir = try std.fs.path.join(arena, &.{ depot_root, "clones", "1" }),
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = try manifest_mod.Uuid.parse(example_uuid),
        .rev = null,
        .subdir = null,
        .tree_hash = null,
        .pinned = false,
    };

    // `:1014-1020`. The rev resolved on the first probe (so nothing was
    // fetched) AND it came back through a branch ref, so the branch is
    // refreshed and re-resolved before its tree is read. Without this an
    // `ajt resolve` on `rev = "main"` pins whatever the local clone last saw.
    var branch: FakeGit = .{
        .arena = arena,
        .is_branch = true,
        .tree = pkg.tree,
        .files = &.{.{ "Project.toml", pkg.src }},
    };
    var r = req;
    r.backend = branch.backend();
    _ = try handleRepoAdd(arena, arena, io, opts, r);
    try expectTranscript(&.{
        // `defaultRev` because `rev` is null: a `[sources]` url with no `rev`
        // records the clone's default branch, and that IS a branch.
        "clone", "defaultRev", "resolve", "fetch:heads", "resolve", "tree", "materialise",
    }, branch.log.items);

    // Pinned: same branch, no re-fetch. A `Pkg.pin`ned repo package must not
    // move when the branch does.
    var pinned: FakeGit = .{ .arena = arena, .is_branch = true, .tree = pkg.tree };
    var p = req;
    p.backend = pinned.backend();
    p.pinned = true;
    _ = try handleRepoAdd(arena, arena, io, opts, p);
    try expectTranscript(&.{ "clone", "defaultRev", "resolve", "tree" }, pinned.log.items);

    // A tag or a sha is not a branch, so it is not re-fetched either — the
    // whole reason `get_object_or_branch` reports `is_branch` at all.
    var tag: FakeGit = .{ .arena = arena, .is_branch = false, .tree = pkg.tree };
    var t = req;
    t.backend = tag.backend();
    t.rev = "v0.5.5";
    _ = try handleRepoAdd(arena, arena, io, opts, t);
    try expectTranscript(&.{ "clone", "resolve", "tree" }, tag.log.items);
}

test "a rev or subdir that is not there is Pkg's sentence, not a crash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot_root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const stack: depot.Stack = .{ .entries = try arena.dupe([]const u8, &.{depot_root}) };

    var diag: Diagnostic = .{};
    const opts: Options = .{
        .project_file = "Project.toml",
        .registry_depot = depot_root,
        .diagnostic = &diag,
    };

    var fake: FakeGit = .{ .arena = arena, .null_until = 99 };
    const req: RepoAdd = .{
        .backend = fake.backend(),
        .stack = stack,
        .clone_dir = try std.fs.path.join(arena, &.{ depot_root, "clones", "1" }),
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = try manifest_mod.Uuid.parse(example_uuid),
        .rev = "nope",
        .subdir = null,
        .tree_hash = null,
        .pinned = false,
    };
    try testing.expectError(error.RevNotFound, handleRepoAdd(arena, arena, io, opts, req));
    // Three probes and two fetches, then it gives up (`Types.jl:1003-1010`);
    // it does NOT keep fetching.
    try expectTranscript(&.{
        "clone", "resolve", "fetch:heads", "resolve", "fetch:all", "resolve",
    }, fake.log.items);
    try testing.expectEqualStrings("Did not find rev nope in repository\n", diag.report.?);

    // ...and a subdir that is not in the tree is the other verbatim sentence
    // (`:1029`), which is what a typo in `[sources] subdir` produces.
    var sub: FakeGit = .{ .arena = arena, .subdir_missing = true };
    var s = req;
    s.backend = sub.backend();
    s.subdir = "lib/Nope";
    try testing.expectError(error.SubdirNotFound, handleRepoAdd(arena, arena, io, opts, s));
    try testing.expectEqualStrings("Did not find subdirectory `lib/Nope`\n", diag.report.?);
}

test "a recorded tree hash outranks the rev, which still goes into the manifest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const pkg = try fakePackage(arena, io, &tmp);
    const depot_root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const stack: depot.Stack = .{ .entries = try arena.dupe([]const u8, &.{depot_root}) };
    const opts: Options = .{ .project_file = "Project.toml", .registry_depot = depot_root };

    // `rev_or_hash = pkg.tree_hash === nothing ? pkg.repo.rev : pkg.tree_hash`
    // (`Types.jl:1000`). With a hash recorded, `defaultRev` is still consulted
    // — the rev is what the manifest records — but the OBJECT looked up is the
    // hash, which is what makes a cold reinstall reproduce the pinned bytes
    // rather than following the branch forward. It is also why a cold reinstall
    // of a `subdir` entry descends into the subdir a SECOND time and fails;
    // Pkg does exactly the same and `instantiate.sh` pins the two together.
    var fake: FakeGit = .{
        .arena = arena,
        .tree = pkg.tree,
        .files = &.{.{ "Project.toml", pkg.src }},
    };
    const added = try handleRepoAdd(arena, arena, io, opts, .{
        .backend = fake.backend(),
        .stack = stack,
        .clone_dir = try std.fs.path.join(arena, &.{ depot_root, "clones", "1" }),
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = try manifest_mod.Uuid.parse(example_uuid),
        .rev = null,
        .subdir = null,
        .tree_hash = .{ .bytes = @splat(0x11) },
        .pinned = false,
    });
    try testing.expectEqualStrings("master", added.rev);
    try testing.expectEqualSlices(u8, &pkg.tree.bytes, &added.tree.bytes);
}

test "materialised bytes that do not hash to the tree are refused, not published" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const pkg = try fakePackage(arena, io, &tmp);
    const depot_root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const stack: depot.Stack = .{ .entries = try arena.dupe([]const u8, &.{depot_root}) };
    const uuid = try manifest_mod.Uuid.parse(example_uuid);
    var diag: Diagnostic = .{};
    const opts: Options = .{
        .project_file = "Project.toml",
        .registry_depot = depot_root,
        .diagnostic = &diag,
    };

    // The backend claims `pkg.tree` and writes something else. Pkg never checks
    // this — `checkout_tree_to_path` can rewrite line endings through a
    // `.gitattributes` and nothing notices — so this is Ajt's own guard, and it
    // has to hold: the depot slug IS `versionSlug(uuid, tree_hash)`, so
    // publishing would name a directory by a hash its contents do not have.
    var fake: FakeGit = .{
        .arena = arena,
        .tree = pkg.tree,
        .files = &.{.{ "Project.toml", "name = \"Tampered\"\n" }},
    };
    try testing.expectError(error.TreeHashMismatch, handleRepoAdd(arena, arena, io, opts, .{
        .backend = fake.backend(),
        .stack = stack,
        .clone_dir = try std.fs.path.join(arena, &.{ depot_root, "clones", "1" }),
        .remote = "https://example.invalid/Example.jl",
        .name = "Example",
        .uuid = uuid,
        .rev = "v0.5.5",
        .subdir = null,
        .tree_hash = null,
        .pinned = false,
    }));
    // Nothing was published: staging is a sibling of the destination and
    // `deinit` took it away, so the slug does not exist.
    const found = try depot.findInstalled(arena, io, stack, "Example", uuid, pkg.tree);
    try testing.expect(!found.exists);
}

test "[sources] with no url never reaches the git backend" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    // `Options.git` and `Options.depots` are both null, so anything that
    // touched a repository would fail loudly. A `[sources]` PATH must not:
    // that is the shape every `Pkg.develop` on 1.11+ writes, and it resolved
    // before urls existed.
    const proj = try project_mod.parse(arena,
        \\[deps]
        \\Local = "99999999-8888-7777-6666-555555555555"
        \\
        \\[sources]
        \\Local = {path = "../Local"}
        \\
    , .{}, null);
    var man: ?manifest_mod.Manifest = null;
    const opts: Options = .{ .project_file = "Project.toml", .registry_depot = "" };
    try testing.expectEqual(@as(usize, 0), (try applySourceRepos(arena, io, opts, &proj, &man)).len);
    try testing.expect(man == null);

    // ...whereas a url with no backend is REFUSED rather than ignored. Being
    // ignored is exactly what shipped before this unit, and it did not fail —
    // it wrote a manifest pinning the registry version of the package instead,
    // silently, which is the worst of the three outcomes.
    const withurl = try project_mod.parse(arena,
        \\[deps]
        \\Example = "7876af07-990d-54b4-ab0e-23690620f79a"
        \\
        \\[sources]
        \\Example = {url = "https://example.invalid/Example.jl"}
        \\
    , .{}, null);
    try testing.expectError(
        Error.NoGitBackend,
        applySourceRepos(arena, io, opts, &withurl, &man),
    );
}

test "uuidForSourceName prefers [deps], then any manifest entry of that name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const proj = try project_mod.parse(arena,
        \\[deps]
        \\Direct = "00000000-0000-0000-0000-000000000001"
        \\
        \\[extras]
        \\OnlyExtra = "00000000-0000-0000-0000-000000000009"
        \\
    , .{}, null);
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "Indirect", .uuid = try manifest_mod.Uuid.parse("00000000-0000-0000-0000-000000000002") },
    };

    try testing.expectEqualSlices(
        u8,
        &(try manifest_mod.Uuid.parse("00000000-0000-0000-0000-000000000001")).bytes,
        &(uuidForSourceName(&proj, &entries, "Direct").?).bytes,
    );
    try testing.expectEqualSlices(
        u8,
        &(try manifest_mod.Uuid.parse("00000000-0000-0000-0000-000000000002")).bytes,
        &(uuidForSourceName(&proj, &entries, "Indirect").?).bytes,
    );
    // `read_project_sources` permits a `[sources]` entry for an `[extras]`-only
    // package, and no resolve in Pkg ever carries one: `load_project_deps`
    // walks `project.deps` and `load_all_deps` walks the manifest. Null means
    // "skipped", not "error".
    try testing.expect(uuidForSourceName(&proj, &entries, "OnlyExtra") == null);
    try testing.expect(uuidForSourceName(&proj, &entries, "Nobody") == null);
}

test "repoSource keeps a url verbatim and canonicalises a local path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    // `isurl` first: nothing about `https://…` is a filesystem question, and
    // the clone cache key is `hash(url)` over the string EXACTLY as written —
    // Pkg does not strip a trailing `.git` or lowercase the host, and neither
    // may this, or `Pkg.gc()` deletes the clone as unreferenced.
    const u = try repoSource(arena, io, "https://github.com/JuliaLang/Example.jl", ".");
    try testing.expectEqualStrings("https://github.com/JuliaLang/Example.jl", u.recorded);
    try testing.expectEqualStrings("https://github.com/JuliaLang/Example.jl", u.clone_key);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "env");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const env = try std.fs.path.join(arena, &.{ root, "env" });
    const repo = try std.fs.path.join(arena, &.{ root, "repo" });

    // A RELATIVE local source is recorded manifest-relative (`Types.jl:978`)
    // and cloned from the absolute path, so the same directory reached by two
    // spellings shares one `clones/` entry.
    const rel = try repoSource(arena, io, "../repo", env);
    try testing.expectEqualStrings("../repo", rel.recorded);
    try testing.expectEqualStrings(repo, rel.clone_key);

    // An ABSOLUTE one is recorded absolute — the form the user wrote survives.
    const abs = try repoSource(arena, io, repo, env);
    try testing.expectEqualStrings(repo, abs.recorded);
    try testing.expectEqualStrings(repo, abs.clone_key);
}
