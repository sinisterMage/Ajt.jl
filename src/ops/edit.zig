//! `ajt add`, `ajt rm`, `ajt up` — the three operations that change what an
//! environment asks for.
//!
//! Each is a small edit to `Project.toml` followed (except for `rm`) by a
//! resolve and a manifest write, so almost everything here is the edit and the
//! argument handling; `ops/resolve.zig` does the work.
//!
//! ## `rm` does not resolve, and that is not an optimisation
//!
//! `Operations.rm` (`Operations.jl:1522-1591`) drops the names from
//! `project.deps`, filters `compat`/`sources`/`targets` down to what is left,
//! runs `prune_manifest`, records the project hash and writes. There is no
//! resolve anywhere in it. Every surviving manifest entry keeps the exact
//! version it had — which is the behaviour people rely on when removing one
//! package out of a working environment, and which a re-resolve would quietly
//! break by also moving everything else.
//!
//! ## `add` writes no `[compat]`
//!
//! `Pkg.add("Foo@1.2")` constrains the RESOLVE and records nothing:
//! `update_package_add` (`:1596-1626`) puts the version on the PackageSpec,
//! and the project gains only `Foo = "<uuid>"` under `[deps]`. Writing a
//! compat bound would be a different, louder thing than the user asked for —
//! `Pkg.compat` is the command that does that.
//!
//! ## `up` is a per-package constraint plus PRESERVE_DIRECT
//!
//! `up_load_versions!` (`:1863-1899`) turns the upgrade level into a version
//! range around what the manifest already records — `VersionRange(major,
//! minor)` for `--patch`, `VersionRange(major)` for `--minor`, unconstrained
//! for `--major` — and then `up` resolves with everything ELSE at
//! `PRESERVE_DIRECT` (`:2004`), or `PRESERVE_NONE` when the level is `fixed`.
//! So `up Foo` moves Foo as far as its level allows, holds the other direct
//! deps, and lets the transitive closure follow.
//!
//! A pinned entry ignores its level entirely (`:1866-1871`) — `pin` means what
//! it says, and `up` is not how you undo it.
//!
//! ## `pin`, `free` and `dev` edit the MANIFEST, which is why they look different
//!
//! `add`/`rm`/`up` change `[deps]` and let the resolve produce a manifest.
//! `pin`, `free` and `dev <path>` change a *manifest entry* — `pinned`, or
//! `path` — and the resolver reads both off the manifest (`resolve.zig:362`,
//! the `isfixed` predicate). So they hand their edit to the resolve through
//! `manifest_source`, the same seam `add` uses for `project_source`, and for
//! the same reason: a resolve that fails must leave both files exactly as they
//! were.
//!
//! ## The repository arms: `add <url>` and `dev <url>`
//!
//! Both clone, and they clone to different places for different reasons.
//!
//! `add <url>` is `handle_repo_add!` (`Types.jl:928-1050`). The clone is a
//! CACHE at `clones/<string(hash(url))>` (`add_repo_cache_path`, `:901`),
//! bare, shared between environments, and keyed on the URL byte-for-byte —
//! `Pkg.gc()` recomputes that name and deletes every `clones/` directory that
//! matches none of the ones it recomputed, so a "better" key would make Ajt's
//! clones collectable rather than reusable. What lands in the environment is
//! not the clone but the TREE: peeled from the rev, materialised at
//! `packages/<Name>/<slug>` exactly where `source_path` will look for it, and
//! recorded in the manifest as `repo-url`/`repo-rev`/`repo-subdir` plus a
//! `git-tree-sha1`.
//!
//! `dev <url>` is `handle_repo_develop!`'s clone arm (`Types.jl:830-846`). Its
//! clone is the PRODUCT: a working tree at `<depot>/dev/<Name>` (or
//! `<env>/dev/<Name>` with `shared = false`) that a human edits, so it is not
//! bare, not content-addressed, and recorded as a manifest `path` like any
//! other develop.
//!
//! The local-path arm of `dev` is unchanged and is what `handle_repo_develop!`
//! (`Types.jl:776-811`) does for a path.
//!
//! ## Which of the six precompile afterwards, and why it is not all of them
//!
//! Pkg auto-precompiles after `add`, `up`, `pin` and `free` — and after
//! neither `rm` nor `develop`. That set is not stated anywhere in one place;
//! it falls out of two unrelated pieces of code, which is exactly why it is
//! worth writing down:
//!
//!   * `up`, `pin`, `free` (and `build`) get it from the generated API
//!     wrapper: `$(f in (:up, :pin, :free, :build)) && Pkg._auto_precompile(ctx)`
//!     (`API.jl:170`). `add`, `develop` and `rm` are absent from that tuple.
//!   * `add` gets it from inside `Operations.add` instead
//!     (`Operations.jl:1828`), as the last statement of the `target == :deps`
//!     branch — so `Pkg.add(...; target = :weakdeps)` does not precompile
//!     either.
//!   * `develop` gets it from NOWHERE. `Operations.develop`
//!     (`Operations.jl:1839-1857`) ends at `build_versions` with no
//!     `_auto_precompile` call, and `develop` is not in the API.jl tuple. So
//!     `Pkg.develop(path=...)` leaves the environment uncompiled. Whether that
//!     is deliberate or an oversight in Pkg, it is the behaviour, and Ajt
//!     matches it — `ajt dev --precompile` is the opt-in.
//!   * `rm` never installs anything, so there is nothing new to compile.
//!
//! `AutoPrecompile.auto` is that table; see `Verb.autoPrecompiles`.
//!
//! ## The pass runs HERE, not in the install pass
//!
//! `finishInner` installs by calling `ops/instantiate.zig`, and both of them
//! could plausibly own the precompile. Only one may, or `ajt add Foo` starts
//! two compile passes over the same environment. It is this one, because it is
//! where Pkg puts it: `Operations.add` calls `download_source` and
//! `download_artifacts` DIRECTLY and then `_auto_precompile` once
//! (`Operations.jl:1804-1828`) — it never calls `Pkg.instantiate`. And on the
//! rare occasions Pkg does nest an instantiate inside another verb it passes
//! `allow_autoprecomp = false` every single time (`API.jl:1249`,
//! `Operations.jl:1335`, `:2395`, `:2438`). So "the inner instantiate never
//! auto-precompiles" is not a tie-break invented here; it is Pkg's own rule,
//! and `finishInner` passes `.precompile = false` to say so.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const resolve_mod = @import("resolve.zig");
const index = @import("../registry/index.zig");
const tarball = @import("../registry/tarball.zig");
const source_mod = @import("../registry/source.zig");
const jver = @import("../julia/version.zig");
const jspec = @import("../julia/versions.zig");
const slug = @import("../julia/slug.zig");
const project_mod = @import("../model/project.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_hash_mod = @import("../julia/project_hash.zig");
const instantiate_mod = @import("instantiate.zig");
const precompile_mod = @import("precompile.zig");
const depot = @import("../depot.zig");
const git_url = @import("../git/url.zig");
const git_core = @import("../git/git.zig");

pub const Uuid = slug.Uuid;

pub const Error = error{
    NoProject,
    /// A name that is in no reachable registry. Pkg's
    /// "The following package names could not be resolved".
    NotRegistered,
    /// A name carried by more than one registered package. Pkg prompts; a
    /// non-interactive tool must refuse and say which UUIDs it saw.
    AmbiguousName,
    /// `rm` was given a name the project does not depend on.
    NotADependency,
    /// `pin`/`free` were given a name with no manifest entry. Pkg:
    /// "package … not found in the manifest, run `Pkg.resolve()` and retry"
    /// (`Operations.jl:2013`).
    NotInManifest,
    /// `free` on a package that is neither pinned nor tracking a path or a
    /// repository (`Operations.jl:2107-2111`).
    NotFreeable,
    /// `free` untracking a package no registry carries — there is nothing to
    /// go back to. "unable to free unregistered package" (`:2078-2080`).
    FreeUnregistered,
    /// `pin Foo@1.2` — a pin needs a single version, not a range
    /// (`API.jl:487-489`).
    PinNeedsExactVersion,
    /// `dev <path>` where the path is not a directory (`Types.jl:797-803`).
    DevPathMissing,
    /// `dev <path>` where the directory has no `Project.toml`, or one without
    /// a name and uuid. `resolve_projectfile!` (`Types.jl:722-744`).
    DevPathNotAPackage,
    /// A spec named a repository but no git backend was configured. Never a
    /// silent fallback to the registry: `add Foo#main` and `add Foo` are
    /// different requests and only one of them is answerable without git.
    GitUnavailable,
    /// `add Foo@1.2#main` — *"version specification invalid when tracking a
    /// repository"* (`API.jl:313-320`). The rev decides the version; a range
    /// alongside it has nothing to constrain.
    VersionWithRev,
    /// `add Name#rev` where neither the manifest nor the registry names a
    /// repository to clone. `set_repo_source_from_registry!`'s *"Repository
    /// for package with UUID `…` could not be found in a registry"*
    /// (`Types.jl:923`).
    NoRepoSource,
    /// The tree that was checked out has no `Project.toml`/`JuliaProject.toml`
    /// naming a package. `resolve_projectfile!`'s *"could not find project
    /// file … maybe `subdir` needs to be specified"* (`Types.jl:1084-1090`).
    RepoNotAPackage,
    /// `--url` was given something `Pkg.isurl` calls a path. Pkg accepts a
    /// local repository there (`Types.jl:947-980`: `.git` probe, dirty-tree
    /// warning, `safe_realpath`, and a manifest-relative `repo-url`); Ajt does
    /// not implement that arm, and treating a path as a URL would record a
    /// `repo-url` Pkg would have written differently.
    RepoPathUnsupported,
    /// A repository operation needs a depot to clone into and install to, and
    /// `JULIA_DEPOT_PATH=""` resolves to none.
    NoDepotForRepo,
    /// `dev <url>#rev`. *"rev argument not supported by `develop`; consider
    /// using `add` instead"* (`API.jl:260-262`) — Pkg refuses it before
    /// anything is cloned, because a develop tracks a working tree and a rev
    /// would only describe the state it was checked out at.
    DevRevUnsupported,
    /// `pin`/`free` were handed a repository spec. Pkg has no grammar for one
    /// there either: `pin` resolves a name against the project
    /// (`project_deps_resolve!`, `API.jl:493`), and silently ignoring the rev
    /// would pin the package the user did not ask about.
    RepoSpecNotAllowed,
};

/// `Pkg.PackageSpec` as far as these commands need one.
pub const Spec = struct {
    /// Empty when only a URL was given: the name is whatever the checked-out
    /// `Project.toml` says it is, and nothing may guess it from the URL.
    name: []const u8,
    /// `Foo@1.2` — constrains the resolve, and is NOT written to `[compat]`.
    version: ?jspec.Spec = null,
    /// Kept for the message when a version was asked for and refused.
    version_text: ?[]const u8 = null,
    /// `pkg.repo.source`. Only ever a URL by `Pkg.isurl`'s answer — see
    /// `Error.RepoPathUnsupported`.
    url: ?[]const u8 = null,
    /// `pkg.repo.rev` — a branch, a tag, or a commit. Null with a `url` means
    /// "the default branch", which is resolved from the clone, not guessed
    /// (`Types.jl:996-999`).
    rev: ?[]const u8 = null,
    /// `pkg.repo.subdir` — the package's directory inside a monorepo.
    subdir: ?[]const u8 = null,

    /// True for anything that has to go through a clone.
    ///
    /// A `rev` with no `url` is one of them: `add Foo#main` is a repository
    /// add whose source comes from the manifest or the registry
    /// (`Types.jl:930-947`), not a registry add with a decoration.
    pub fn isRepo(self: Spec) bool {
        return self.url != null or self.rev != null;
    }

    /// `add`'s grammar: `Name`, `Name@1.2`, `<url>`, `Name#rev`, `<url>#rev`.
    ///
    /// **`#` is split before `@`, and the order is the contract.** `Name@1.2`
    /// is a version and `#rev` is a rev, so `Name@1.2#main` has to come out as
    /// all three parts — splitting `@` first would hand `1.2#main` to
    /// `semver_spec`. (Pkg's own REPL splits the other way and produces
    /// exactly that; the combination is refused by `API.jl:313-320` either
    /// way, so being right here costs nothing and reports better.)
    ///
    /// The rev is everything after the FIRST `#`, matching
    /// `extract_revision`'s `findfirst('#', input)`
    /// (`REPLMode/argument_parsers.jl:124-134`). A `#` in a package name is
    /// therefore not expressible this way, which is what the explicit
    /// `--url`/`--rev`/`--subdir` form is for.
    ///
    /// `isUrl` decides path-or-URL before `@` is looked at, because a URL may
    /// carry userinfo (`https://user@host/r`) — and it is `Pkg.isurl`, not
    /// `classify`, for the reason `git/url.zig`'s header gives.
    pub fn parse(arena: Allocator, text: []const u8) !Spec {
        const split = splitRev(text);
        if (git_url.isUrl(split.head)) {
            return .{ .name = "", .url = split.head, .rev = split.rev };
        }
        const at = std.mem.indexOfScalar(u8, split.head, '@') orelse
            return .{ .name = split.head, .rev = split.rev };
        if (at == 0) return Error.NotRegistered;
        const vtext = split.head[at + 1 ..];
        return .{
            .name = split.head[0..at],
            .version = try jspec.semverSpec(arena, vtext),
            .version_text = vtext,
            .rev = split.rev,
        };
    }

    /// `dev`'s grammar: a local path or a URL, optionally `#rev`, and **no
    /// version at all**.
    ///
    /// `parse_path_with_specifiers` (`argument_parsers.jl:266-290`) has no
    /// version token either, and the reason matters here: a directory may
    /// legitimately contain an `@` (`/home/u@corp/pkg`), so `Spec.parse`'s
    /// version split would tear a perfectly good path in half.
    pub fn parseSource(text: []const u8) Spec {
        const split = splitRev(text);
        if (git_url.isUrl(split.head)) {
            return .{ .name = "", .url = split.head, .rev = split.rev };
        }
        return .{ .name = split.head, .rev = split.rev };
    }

    const Split = struct { head: []const u8, rev: ?[]const u8 };

    fn splitRev(text: []const u8) Split {
        const hash = std.mem.indexOfScalar(u8, text, '#') orelse
            return .{ .head = text, .rev = null };
        const rev = text[hash + 1 ..];
        // `Foo#` is `Foo`, not `Foo` at the empty rev: an empty rev resolves
        // nothing, and reporting "did not find rev `` " would be a worse
        // answer than the one the user obviously meant.
        return .{ .head = text[0..hash], .rev = if (rev.len == 0) null else rev };
    }
};

/// Which of the six verbs is running. Only the auto-precompile rule needs to
/// know — everything else about the six is already decided by which entry
/// point the caller reached — so this is an argument to `finish*` rather than
/// a field on `Options` a caller could contradict.
pub const Verb = enum {
    add,
    rm,
    up,
    pin,
    free,
    dev,

    /// Pkg's table, derived in the module header. `rm` is here for
    /// completeness even though it never reaches `finishInner`.
    pub fn autoPrecompiles(self: Verb) bool {
        return switch (self) {
            .add, .up, .pin, .free => true,
            .rm, .dev => false,
        };
    }
};

/// What to do about `Pkg._auto_precompile` (`Pkg.jl:896-900`) after the
/// install pass.
pub const AutoPrecompile = enum {
    /// Never. The default, because `Options` is also what the tests and every
    /// library caller construct, and a default that spawns `julia` children
    /// would change what those mean. `ajt add` passes `.auto`.
    off,
    /// Pkg's rule for this verb (`Verb.autoPrecompiles`), still subject to
    /// `JULIA_PKG_PRECOMPILE_AUTO`.
    auto,
    /// Whatever the verb, still subject to `JULIA_PKG_PRECOMPILE_AUTO`.
    ///
    /// The env var is deliberately NOT overridden here. Its whole purpose is
    /// "nothing in this environment precompiles implicitly" — a container
    /// build, a CI job that precompiles once at the end — and a flag that
    /// ignored it would make that promise unreliable. `ajt precompile` is the
    /// command that precompiles because you asked it to; `--precompile` on an
    /// edit verb only widens the set of verbs, not the veto.
    force,
};

pub const Options = struct {
    project_file: []const u8,
    manifest_file: []const u8,
    registry_depot: []const u8,
    registry_name: []const u8 = "General",
    julia_prefix: ?[]const u8 = null,
    julia_version: ?jver.Version = null,
    depots: ?depot.Stack = null,
    /// `add` defaults to `PRESERVE_TIERED` exactly as Pkg does
    /// (`default_preserve`, `Operations.jl:23-29`); `up` overrides it per its
    /// own rule.
    tier: resolve_mod.Tier = .tiered,
    /// `Pkg.OFFLINE_MODE[]`. Reaches BOTH halves of this operation: the resolve
    /// below restricts its candidates to what the depot already has
    /// (`Operations.jl:500`), and the install pass gets it on its transport
    /// config so a download that should not be needed cannot happen silently
    /// anyway. See `resolve_mod.Options.offline`.
    offline: bool = false,
    fixups: bool = true,
    dry_run: bool = false,
    /// Download and unpack what the resolve chose. `Pkg.add` installs — it is
    /// not a manifest editor — so `add Foo` followed by `using Foo` has to
    /// work. Off for `rm` (nothing new to fetch) and available as an escape
    /// hatch for a caller that only wants the manifest moved.
    install: bool = true,
    /// Registry seam for the install pass's GitHub-tarball fallback URLs.
    /// `.none` costs only that fallback — the Pkg server serves by UUID and
    /// tree hash alone, and everything `add` just resolved is registered by
    /// construction — so a caller with no registry handy is not blocked.
    registry: ?instantiate_mod.Registry = null,
    diagnostic: ?*resolve_mod.Diagnostic = null,

    /// Precompile the environment after the install pass — `Pkg.add` and
    /// `Pkg.up` both do, which is why `add Foo` followed by `using Foo` is
    /// fast under Pkg and was not under Ajt.
    precompile: AutoPrecompile = .off,
    /// The parent environment the precompile children inherit. Without it they
    /// get a two-variable environment with no `PATH` and no `HOME` — and it is
    /// also where `JULIA_PKG_PRECOMPILE_AUTO` is read from, so `.auto` with a
    /// null environ precompiles unconditionally.
    environ: ?*const std.process.Environ.Map = null,
    /// The `julia` the precompile children run. Null derives it from
    /// `julia_prefix`.
    julia_exe: ?[]const u8 = null,
    /// Children compiling at once. Null detects it from the machine.
    precompile_jobs: ?u32 = null,
    /// `precompile.Options.cache_url` — the shared store, read-only (no token
    /// is threaded, so an auto-precompile imports and never publishes). Null is
    /// Pkg's behaviour: compile locally, talk to nothing. See
    /// `instantiate.Options.precompile_cache_url` for why it is threaded at all.
    precompile_cache_url: ?[]const u8 = null,
    /// The git backend for the repository arms. Null makes a repo spec fail
    /// with `GitUnavailable`; it never degrades into a registry add.
    git: ?git_core.Backend = null,
    /// Scratch for the git backend, which frees what it allocates here itself.
    /// Defaults to `arena`, which is correct but keeps a clone's `git archive`
    /// output alive for the rest of the process — pass a real allocator from a
    /// caller that does more than one `add`.
    gpa: ?Allocator = null,
    /// `Pkg.devdir()` — `JULIA_PKG_DEVDIR`, else `<depots1>/dev`
    /// (`Types.jl:762-766`). Read only by `dev <url>`, and only when `shared`.
    devdir: ?[]const u8 = null,
    /// `Pkg.develop(shared = …)`, whose default is `true`. False puts the
    /// clone in `<env>/dev/<Name>` and records a manifest-relative path.
    /// Ignored by the local-path arm, exactly as `handle_repo_develop!`
    /// ignores it there.
    shared: bool = true,
};

/// Why the auto-precompile pass did not run. Null on `Report` means it did.
pub const PrecompileSkipped = enum {
    /// `Options.precompile == .off`.
    disabled,
    /// `.auto`, and this verb is one Pkg does not precompile after — `dev`.
    /// See the module header for where that table comes from.
    not_this_verb,
    /// `JULIA_PKG_PRECOMPILE_AUTO` parsed falsy (`Pkg.jl:65`).
    env_disabled,
    /// `--dry-run`. Nothing was installed, so there is nothing to compile.
    dry_run,
    /// No depot, so no install pass ran either.
    no_depot,
    /// `Options.install == false` — the manifest moved and the depot did not.
    no_install,
    /// The install pass reported failures. Pkg's `download_source` throws on
    /// one (`Operations.jl:1112-1247`) and never reaches `_auto_precompile`;
    /// compiling anyway would answer `source_missing` for every package that
    /// is missing because of the failure already in this Report.
    install_failed,
    /// Every download succeeded and the environment still does not verify — a
    /// missing artifact, a `[sources]` checkout, a Julia installation the
    /// stdlib cross-check could not find. Distinct from `install_failed`
    /// because nothing here is retryable by re-running the download: the two
    /// have different fixes and collapsing them would point at the wrong one.
    not_instantiated,
};

pub const Report = struct {
    /// Packages whose `[deps]` membership changed, with what happened.
    changes: []const Change = &.{},
    /// Packages the install pass SUCCEEDED on, when one ran. Null means no
    /// install was attempted (`rm`, `--dry-run`, or no depot to install into).
    installed: ?usize = null,
    /// Packages the install pass tried and failed. Non-zero means the manifest
    /// is resolved but the environment is not usable yet.
    failed_installs: usize = 0,
    /// Null for `rm`, which never resolves — the manifest it writes is the old
    /// one with unreachable entries pruned, not a new solution.
    resolve: ?resolve_mod.Report = null,
    /// Entry count of the manifest as written, whether it came from a resolve
    /// or from `rm`'s prune. Null when there was no manifest to touch.
    manifest_entries: ?usize = null,
    manifest_written: bool = false,
    project_written: bool = false,
    /// The auto-precompile pass, when one ran.
    precompile: ?precompile_mod.Report = null,
    /// Why it did not, when it did not. Null together with `precompile` means
    /// the verb never got as far as the install pass at all (`rm`).
    precompile_skipped: ?PrecompileSkipped = null,

    /// Did the auto-precompile pass, if one ran, end where Pkg would have left
    /// it? True when none ran — a skip is an answer, not a failure.
    ///
    /// Deliberately narrower than "did this run succeed": `failed_installs`
    /// has always been reported without failing the command, and widening that
    /// here would change `ajt add`'s exit code for a reason unrelated to
    /// precompilation.
    pub fn precompileOk(self: Report) bool {
        const p = self.precompile orelse return true;
        return p.ok();
    }

    pub const Change = struct {
        name: []const u8,
        uuid: Uuid,
        kind: enum { added, already_present, removed, pinned, freed, developed },
    };
};

// ---------------------------------------------------------------------------
// add

pub fn add(arena: Allocator, io: Io, opts: Options, specs: []const Spec) !Report {
    var proj = try readProject(arena, io, opts.project_file, .create);

    // The registry is needed before anything is written: an unregistered name
    // must leave `Project.toml` untouched, not half-edited.
    var reg = try source_mod.open(arena, arena, io, opts.registry_depot, opts.registry_name, .auto);

    // Does anything here need a clone? Only then is the manifest read and
    // handed to the resolve as `manifest_source`; a registry-only `add` takes
    // exactly the path it always took.
    var any_repo = false;
    for (specs) |s| {
        if (s.isRepo()) any_repo = true;
    }

    var changes: std.ArrayList(Report.Change) = .empty;
    var overrides: std.ArrayList(resolve_mod.Override) = .empty;

    if (!any_repo) {
        for (specs) |s| {
            try addRegistered(arena, &reg, &proj, &changes, &overrides, s);
        }
        return finish(arena, io, opts, .add, &proj, changes.items, overrides.items);
    }

    // A missing manifest is normal: `add <url>` into a fresh directory is how
    // an environment tracking a repository starts.
    var man = (try readManifest(arena, io, opts.manifest_file)) orelse
        manifest_mod.Manifest{};
    var entries: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    try entries.appendSlice(arena, man.entries);

    for (specs) |s| {
        if (!s.isRepo()) {
            try addRegistered(arena, &reg, &proj, &changes, &overrides, s);
            continue;
        }
        // "version specification invalid when tracking a repository"
        // (`API.jl:313-320`), checked before anything is cloned.
        if (s.version != null) return Error.VersionWithRev;

        const got = try addRepo(arena, io, opts, &reg, entries.items, s);
        const had = proj.deps.get(got.name) != null;
        _ = try proj.weakdeps.remove(proj.arena(), got.name);
        try proj.addDep(got.name, got.uuid);

        // **A pinned entry wins, and everything just cloned is discarded.**
        // `update_package_add` (`Operations.jl:1597-1606`) rebuilds the spec
        // from the manifest entry — `pinned`, its version, its tree hash, its
        // path and its repo — the moment `entry.pinned` is true, and prints
        // *"`Foo` is pinned at `vX`: maintaining pinned version"*. The clone
        // above still happened, because `handle_repo_add!` runs first and does
        // not know it is about to be overruled; only the manifest is spared.
        //
        // Looked up by UUID rather than by name, and the difference is real:
        // by the time this runs the package has been identified from its own
        // checked-out project file (`:1781`), so a bare-URL add of an
        // already-pinned package finds the pin too.
        const prior = findEntryByUuid(entries.items, got.uuid);
        if (prior == null or !entries.items[prior.?].pinned) {
            // `update_manifest!` (`Operations.jl:224-247`) writes the whole
            // entry back from the PackageSpec `handle_repo_add!` filled in:
            // version from the checked-out project file, the tree hash it
            // peeled, and the three `repo-*` fields. `path` and `pinned` go
            // with it — a package that was dev'd and is now tracked by url is
            // no longer path-tracked.
            const entry: manifest_mod.PackageEntry = .{
                .name = got.name,
                .uuid = got.uuid,
                .version = got.version,
                .tree_hash = got.tree,
                .repo_url = got.url,
                .repo_rev = got.rev,
                .repo_subdir = got.subdir,
                .deps = got.deps,
            };
            if (prior) |idx| {
                entries.items[idx] = entry;
            } else {
                try entries.append(arena, entry);
            }
        }
        try changes.append(arena, .{
            .name = got.name,
            .uuid = got.uuid,
            .kind = if (had) .already_present else .added,
        });
    }
    man.entries = entries.items;

    return finishWithManifest(arena, io, opts, .add, &proj, &man, changes.items, overrides.items);
}

/// The registry arm of `add`, unchanged and factored out only so the repo arm
/// can sit beside it.
fn addRegistered(
    arena: Allocator,
    reg: *const source_mod.Backend,
    proj: *project_mod.Project,
    changes: *std.ArrayList(Report.Change),
    overrides: *std.ArrayList(resolve_mod.Override),
    s: Spec,
) !void {
    const uuid = try resolveName(arena, reg, s.name);
    const had = proj.deps.get(s.name) != null;
    // "delete!(ctx.env.project.weakdeps, pkg.name)" (`:1779`): adding a
    // package as a strong dependency takes it out of `[weakdeps]`, or the
    // project would declare it both ways.
    _ = try proj.weakdeps.remove(proj.arena(), s.name);
    try proj.addDep(s.name, uuid);
    try changes.append(arena, .{
        .name = s.name,
        .uuid = uuid,
        .kind = if (had) .already_present else .added,
    });
    if (s.version) |v| {
        try overrides.append(arena, .{ .uuid = try uuidText(arena, uuid), .spec = v });
    }
}

/// Everything `handle_repo_add!` (`Types.jl:928-1050`) resolves about one
/// repository spec, in its order.
const RepoAdd = struct {
    name: []const u8,
    uuid: Uuid,
    /// `collect_project` (`Operations.jl:369-375`): the checked-out project's
    /// own `version`, or `0.0.0` when it declares none.
    version: jver.Version,
    tree: manifest_mod.Sha1,
    url: []const u8,
    rev: []const u8,
    subdir: ?[]const u8,
    /// `[deps]` **and** `[weakdeps]` of the checked-out project, which is what
    /// `collect_project` pushes into one `requires` list (`:359-368`). The
    /// weak ones drop back out in the fixups pass (`:283-285`), the same route
    /// the project's own entry takes.
    deps: []const manifest_mod.Dep,
};

fn addRepo(
    arena: Allocator,
    io: Io,
    opts: Options,
    reg: *const source_mod.Backend,
    entries: []const manifest_mod.PackageEntry,
    spec: Spec,
) !RepoAdd {
    const backend = opts.git orelse return Error.GitUnavailable;
    const gpa = opts.gpa orelse arena;
    const stack = opts.depots orelse return Error.NoDepotForRepo;
    const write = stack.writeDepot() orelse return Error.NoDepotForRepo;

    const src = try repoSource(arena, reg, entries, spec);
    // Refused HERE, with `git/git.zig`'s message, rather than by whichever
    // backend happens to be wired up: "Unsupported URL protocol" from libgit2
    // is true, unactionable, and indistinguishable from a typo in the scheme.
    if (!git_url.classify(src.url).supported()) return git_core.Error.SshUnsupported;

    // `add_repo_cache_path(url)` — `clones/<string(hash(url))>` (`:901`), on
    // the URL verbatim. `Pkg.gc()` recomputes exactly this name.
    const clone = try write.cloneUrlDir(arena, src.url);
    try backend.ensureClone(gpa, io, clone, src.url, .{ .bare = true });

    // "If the user didn't specify rev, assume they want the default (master)
    // branch if on a branch, otherwise the current commit" (`:996-999`).
    const rev = spec.rev orelse try backend.defaultRev(gpa, arena, io, clone);

    // `get_object_or_branch`, then fetch-and-retry twice: branches only first
    // (`refspecs`), then everything (`refspecs_fallback`), because the second
    // also drags every tag and pull-request ref on a large repository
    // (`:1000-1010`).
    var fetched = false;
    var found = try backend.resolveRev(gpa, io, clone, rev);
    if (found == null) {
        fetched = true;
        try backend.fetch(gpa, io, clone, src.url, git_core.refspecs_heads);
        found = try backend.resolveRev(gpa, io, clone, rev);
        if (found == null) {
            try backend.fetch(gpa, io, clone, src.url, git_core.refspecs_all);
            found = try backend.resolveRev(gpa, io, clone, rev);
        }
        // "Did not find rev $rev in repository" (`:1009`).
        if (found == null) return git_core.Error.RevNotFound;
    }

    // "If we are tracking a branch and are not pinned we want to update the
    // repo if we haven't done that yet" (`:1014-1020`). This is what makes
    // `add Foo#main` follow the branch rather than pin whatever the cache
    // already held — and why `resolveRev` reporting `is_branch` matters.
    //
    // `ispinned` is read from the manifest entry for the package's UUID
    // (`:1015`) — and at this point in `handle_repo_add!` that uuid exists
    // only if `manifest_resolve!` ran, which happens **only when the spec
    // carried no source of its own** (`:930-947`). So a spec with an explicit
    // url is never "pinned" here, even when the manifest does pin that
    // package: `manifest_info(::Manifest, ::Nothing)` is `nothing`
    // (`Types.jl:1328`). It costs one redundant fetch and nothing else —
    // `update_package_add` throws the whole result away for a pinned entry
    // regardless (see the caller).
    const pinned = if (spec.url != null or spec.name.len == 0) false else blk: {
        const idx = findEntry(entries, spec.name) orelse break :blk false;
        break :blk entries[idx].pinned;
    };
    if (found.?.is_branch and !fetched and !pinned) {
        try backend.fetch(gpa, io, clone, src.url, git_core.refspecs_heads);
        found = (try backend.resolveRev(gpa, io, clone, rev)) orelse found;
    }

    const commit_hex = std.fmt.bytesToHex(found.?.commit.bytes, .lower);
    // Peel to the tree, descending into the subdir if there is one — "Did not
    // find subdirectory `$subdir`" (`:1023-1030`).
    const tree = try backend.treeOf(gpa, io, clone, &commit_hex, src.subdir);

    const installed = try installTree(arena, io, opts, backend, clone, tree);
    return .{
        .name = installed.name,
        .uuid = installed.uuid,
        .version = installed.version,
        .tree = tree,
        .url = src.url,
        .rev = rev,
        .subdir = src.subdir,
        .deps = installed.deps,
    };
}

const RepoSource = struct { url: []const u8, subdir: ?[]const u8 };

/// "The first goal is to populate `pkg.repo.source` if that wasn't given
/// explicitly" (`Types.jl:930-947`): the manifest entry first — which is also
/// how *"switch the tracking branch"* works without touching the network — and
/// only then the registry's `repo` field.
///
/// Both of those overwrite `subdir` rather than merging with an explicit one,
/// because Pkg does: the manifest branch assigns `pkg.repo.subdir =
/// entry.repo.subdir` unconditionally (`:940`), and the registry branch
/// assigns whenever the registry records one (`:917-919`). A monorepo package
/// tracked by name therefore keeps the subdir its source knows about.
fn repoSource(
    arena: Allocator,
    reg: *const source_mod.Backend,
    entries: []const manifest_mod.PackageEntry,
    spec: Spec,
) !RepoSource {
    if (spec.url) |u| {
        if (!git_url.isUrl(u)) return Error.RepoPathUnsupported;
        return .{ .url = u, .subdir = spec.subdir };
    }
    if (findEntry(entries, spec.name)) |idx| {
        if (entries[idx].repo_url) |u| {
            return .{ .url = u, .subdir = entries[idx].repo_subdir };
        }
    }
    const uuid = try resolveName(arena, reg, spec.name);
    const found = try reg.repoSourceForUuid(arena, arena, try uuidText(arena, uuid));
    const rs = found orelse return Error.NoRepoSource;
    if (rs.url.len == 0) return Error.NoRepoSource;
    return .{
        .url = rs.url,
        .subdir = if (rs.subdir.len != 0) rs.subdir else spec.subdir,
    };
}

const InstalledTree = struct {
    name: []const u8,
    uuid: Uuid,
    version: jver.Version,
    deps: []const manifest_mod.Dep,
};

/// `handle_repo_add!`'s tail (`Types.jl:1032-1050`): check the tree out, read
/// the package's own project file, and publish it where `source_path` will
/// look — `find_installed(name, uuid, tree_hash)`, i.e.
/// `packages/<Name>/<version_slug>`.
///
/// The staging directory is a sibling of `packages/`, not `$TMPDIR`. Pkg
/// stages under `mktempdir()` and finishes with `mv`, which silently degrades
/// to a non-atomic copy across filesystems (`EXDEV`) — and a depot on its own
/// volume is the normal case, not the exotic one. See `depot.zig`'s header.
fn installTree(
    arena: Allocator,
    io: Io,
    opts: Options,
    backend: git_core.Backend,
    clone: []const u8,
    tree: manifest_mod.Sha1,
) !InstalledTree {
    const gpa = opts.gpa orelse arena;
    const stack = opts.depots orelse return Error.NoDepotForRepo;
    const write = stack.writeDepot() orelse return Error.NoDepotForRepo;

    const packages = try write.packagesDir(arena);
    try Io.Dir.cwd().createDirPath(io, packages);

    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var enc: [16]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&enc, &random_bytes);
    const staging = try std.fmt.allocPrint(arena, "{s}/.ajt-add-{s}", .{ packages, enc });
    try Io.Dir.cwd().createDirPath(io, staging);
    errdefer Io.Dir.cwd().deleteTree(io, staging) catch {};

    // The subdir was already applied when the tree was peeled, so what lands
    // here IS the package — `resolve_projectfile!` reads it directly (`:1043`).
    try backend.materialise(gpa, io, clone, tree, staging);
    const target = readTargetProject(arena, io, staging) catch return Error.RepoNotAPackage;

    const found = try depot.findInstalled(arena, io, stack, target.name, target.uuid, tree);
    if (found.exists) {
        // "isdir(version_path) && return false" (`:1046`) — already installed,
        // by an earlier add or by Pkg itself. The tree hash is the identity, so
        // there is nothing to compare and nothing to overwrite.
        Io.Dir.cwd().deleteTree(io, staging) catch {};
    } else {
        if (std.fs.path.dirname(found.path)) |parent| {
            try Io.Dir.cwd().createDirPath(io, parent);
        }
        Io.Dir.rename(Io.Dir.cwd(), staging, Io.Dir.cwd(), found.path, io) catch |err| switch (err) {
            error.Canceled => return err,
            // Lost a race with another installer, or the directory appeared
            // between the probe and the rename. Either way the content at that
            // path is named by this tree hash and is therefore this tree.
            else => {
                Io.Dir.cwd().deleteTree(io, staging) catch {};
                _ = Io.Dir.cwd().statFile(io, found.path, .{}) catch return err;
            },
        };
        // "set_readonly(version_path)" (`:1050`).
        depot.setReadonlyPath(gpa, io, found.path) catch {};
    }

    return .{
        .name = target.name,
        .uuid = target.uuid,
        // `collect_project`: "project file for $name is missing a `version`
        // entry" is a warning Pkg has commented out, and the value it settles
        // on is `VersionNumber(0)` (`Operations.jl:369-375`).
        .version = target.version orelse zero_version,
        .deps = target.deps,
    };
}

const zero_version: jver.Version = .{ .major = 0, .minor = 0, .patch = 0 };

// ---------------------------------------------------------------------------
// rm

pub fn rm(arena: Allocator, io: Io, opts: Options, names: []const []const u8) !Report {
    var proj = try readProject(arena, io, opts.project_file, .require);

    var changes: std.ArrayList(Report.Change) = .empty;
    for (names) |name| {
        const uuid = proj.deps.get(name) orelse return Error.NotADependency;
        _ = try proj.removeDep(name);
        try changes.append(arena, .{ .name = name, .uuid = uuid, .kind = .removed });
    }

    // "only declare `compat` for remaining direct or `extra` dependencies"
    // (`:1568-1571`). `julia` is always kept — it is an implicit direct dep
    // and its bound is the one that decides which Julias can load this
    // project at all.
    var compat_i: usize = 0;
    while (compat_i < proj.compat.items.len) {
        const name = proj.compat.items[compat_i].name;
        if (std.mem.eql(u8, name, "julia") or proj.deps.contains(name) or
            proj.extras.contains(name) or proj.weakdeps.contains(name))
        {
            compat_i += 1;
        } else {
            _ = proj.removeCompat(name);
        }
    }
    // `[sources]` survives only for deps and extras (`:1573-1575`) — note
    // weakdeps are NOT in that list, unlike compat.
    var src_i: usize = 0;
    while (src_i < proj.sources.items.len) {
        const name = proj.sources.items[src_i].name;
        if (proj.deps.contains(name) or proj.extras.contains(name)) {
            src_i += 1;
        } else {
            _ = proj.removeSource(name);
        }
    }

    // Pkg also rewrites `[targets]` (`:1577-1580`), dropping names that are no
    // longer deps-or-extras and then dropping any target left empty.
    try pruneTargets(&proj);

    // No resolve. Just prune what the manifest can no longer reach and rewrite
    // the hash — see the header.
    var man = try readManifest(arena, io, opts.manifest_file);
    var manifest_written = false;
    if (man) |*m| {
        m.entries = try resolve_mod.pruneManifest(arena, m.entries, &proj, proj.uuid != null and proj.name != null);
        // From `destructure`, NOT from `other()`. `other()` is the table as
        // PARSED, and `removeDep` edits the model — so after a removal the raw
        // table still lists the package that was just dropped, and the hash
        // would describe a project that no longer exists. It agreed with Pkg
        // on every other field and differed on exactly this one.
        const table = try proj.destructure(arena);
        try m.setProjectHash(arena, try manifest_mod.Sha1.parse(&try project_hash_mod.compute(arena, table)));
        if (!opts.dry_run) {
            const current = Io.Dir.cwd().readFileAlloc(io, opts.manifest_file, arena, .limited(64 << 20)) catch "";
            manifest_written = try @import("instantiate.zig").writeIfChanged(arena, io, m, opts.manifest_file, current);
        }
    }

    const project_written = if (opts.dry_run) false else try writeProject(arena, io, &proj, opts.project_file);
    return .{
        .changes = changes.items,
        .manifest_entries = if (man) |m| m.entries.len else null,
        .manifest_written = manifest_written,
        .project_written = project_written,
    };
}

// ---------------------------------------------------------------------------
// up

pub const Level = enum {
    fixed,
    patch,
    minor,
    major,

    pub fn parse(text: []const u8) ?Level {
        inline for (.{
            .{ "fixed", Level.fixed },
            .{ "patch", Level.patch },
            .{ "minor", Level.minor },
            .{ "major", Level.major },
        }) |row| {
            if (std.mem.eql(u8, text, row[0])) return row[1];
        }
        return null;
    }
};

/// `up`. With no names, every direct dependency moves — `Pkg.update()` with no
/// arguments in project mode.
pub fn up(arena: Allocator, io: Io, opts: Options, names: []const []const u8, level: Level) !Report {
    var proj = try readProject(arena, io, opts.project_file, .require);
    const man = try readManifest(arena, io, opts.manifest_file);

    // `up` runs in PKGMODE_PROJECT by default, where a name that is not a
    // direct dependency is an error rather than a no-op — `project_deps_resolve!`
    // refuses it. Silently updating nothing would be the worse answer: the
    // command appears to succeed and the package does not move.
    for (names) |n| {
        if (!proj.deps.contains(n)) return Error.NotADependency;
    }

    var overrides: std.ArrayList(resolve_mod.Override) = .empty;
    for (proj.deps.entries.items) |d| {
        if (names.len != 0) {
            var named = false;
            for (names) |n| {
                if (std.mem.eql(u8, n, d.name)) named = true;
            }
            if (!named) continue;
        }
        const ut = try uuidText(arena, d.uuid);
        const entry = if (man) |m| m.findByUuid(d.uuid) else null;
        // "entry.version !== nothing || return false" (`:1865`) — nothing
        // recorded, nothing to build a range around, so the package is simply
        // left to the tier.
        const e = entry orelse continue;
        const v = e.version orelse continue;
        if (e.pinned or level == .fixed) {
            try overrides.append(arena, .{ .uuid = ut, .pin = v });
            continue;
        }
        const range_text: ?[]const u8 = switch (level) {
            // `VersionRange(major, minor)` and `VersionRange(major)` are the
            // REGISTRY grammar's `1.2` and `1` — a bound with fewer than three
            // significant components, which is a range, not a point.
            .patch => try std.fmt.allocPrint(arena, "{d}.{d}", .{ v.major, v.minor }),
            .minor => try std.fmt.allocPrint(arena, "{d}", .{v.major}),
            // `VersionRange()` — unconstrained.
            .major => null,
            .fixed => unreachable,
        };
        try overrides.append(arena, .{
            .uuid = ut,
            .spec = if (range_text) |t| try jspec.Spec.parse(arena, t) else try jspec.Spec.all(arena),
            // An override with no pin and an all-versions spec still has to be
            // RECORDED, or the tier below would pin this package instead.
        });
    }

    var o = opts;
    // `:2004` — everything not named keeps its recorded version, unless the
    // level is `fixed`, in which case nothing is held and only the explicit
    // pins above apply.
    o.tier = if (level == .fixed) .none else .direct;
    return finish(arena, io, o, .up, &proj, &.{}, overrides.items);
}

// ---------------------------------------------------------------------------
// pin / free / dev — the three that edit a manifest entry

/// `Pkg.pin` (`API.jl:460-497`, `Operations.jl:2011-2038`).
///
/// Sets `pinned = true` on the manifest entry, which is all a pin IS: the
/// resolver already reads that flag (`resolve.zig:362`) and holds such an entry
/// at its recorded version through every tier.
///
/// With no version this is a pure edit and the resolve that follows is a no-op
/// by construction — `PRESERVE_TIERED` starts at `PRESERVE_ALL`, which keeps
/// every recorded version, and the newly pinned one is now held even harder.
/// Pkg resolves anyway, with a `# TODO: change pin to not take a version` next
/// to it (`Operations.jl:2046`); running it too keeps the written manifest
/// byte-identical rather than merely equivalent.
///
/// With `Foo@1.2.3` the pin is a genuine move, and the version must be exact:
/// `pinning a package requires a single version, not a versionrange`
/// (`API.jl:487-489`). `Foo@1.2` is a RANGE in the project grammar, so it is
/// refused here rather than silently pinning to something in `[1.2, 2)`.
pub fn pin(arena: Allocator, io: Io, opts: Options, specs: []const Spec) !Report {
    var proj = try readProject(arena, io, opts.project_file, .require);
    var man = (try readManifest(arena, io, opts.manifest_file)) orelse return Error.NotInManifest;

    var changes: std.ArrayList(Report.Change) = .empty;
    var overrides: std.ArrayList(resolve_mod.Override) = .empty;
    var entries = try arena.dupe(manifest_mod.PackageEntry, man.entries);

    for (specs) |s| {
        // `pin` shares `Spec.parse` with `add`, so `pin Foo#main` parses. It
        // must not then pin `Foo` and drop the rev on the floor — a pin has no
        // repository grammar, and silently ignoring the part the user cared
        // about is the worst of the three possible answers.
        if (s.isRepo() or s.subdir != null) return Error.RepoSpecNotAllowed;

        // `project_deps_resolve!` (`API.jl:493`) — `pin` resolves the name
        // against the PROJECT, so a transitive dependency is refused:
        //   "JSON (… in manifest but not in project)"
        // `free` deliberately differs: it uses `manifest_resolve!` (`:521`)
        // and accepts any manifest entry. Verified by running both; the
        // asymmetry is not obvious from either signature.
        if (!proj.deps.contains(s.name)) return Error.NotADependency;
        const idx = findEntry(entries, s.name) orelse return Error.NotInManifest;
        entries[idx].pinned = true;

        if (s.version) |v| {
            const exact = v.exact() orelse return Error.PinNeedsExactVersion;
            entries[idx].version = exact;
            // A moving pin still goes through the solver: its dependencies may
            // not be satisfiable at the new version, and that is the answer the
            // user wants rather than a manifest that no longer loads.
            try overrides.append(arena, .{
                .uuid = try uuidText(arena, entries[idx].uuid),
                .pin = exact,
            });
        }
        try changes.append(arena, .{
            .name = entries[idx].name,
            .uuid = entries[idx].uuid,
            .kind = .pinned,
        });
    }
    man.entries = entries;

    return finishWithManifest(arena, io, opts, .pin, &proj, &man, changes.items, overrides.items);
}

/// `Pkg.free` (`API.jl:500-527`, `Operations.jl:2085-2126`).
///
/// One verb, two operations — Pkg says so itself (`# TODO: this is two
/// technically different operations with the same name`, `:2083`):
///
///   * an entry that is `pinned` is un-pinned and goes back to tracking the
///     registry at whatever version resolves;
///   * an entry tracking a `path` or a repository stops doing so, which also
///     means dropping its `[sources]` entry (`:2089`).
///
/// Anything else is an error rather than a no-op — *"expected package … to be
/// pinned, tracking a path, or tracking a repository"* (`:2107-2111`) — because
/// `free` on an ordinary registry package is a mistake worth naming.
///
/// Untracking also requires the package to BE registered: there has to be
/// something to go back to (`is_all_registered`, `:2074-2077`). Checking it
/// here rather than letting the resolve discover it is what turns a PubGrub
/// derivation tree over a bare UUID — an unregistered package has no name to
/// print either — into one line naming the package and the reason.
pub fn free(arena: Allocator, io: Io, opts: Options, names: []const []const u8) !Report {
    var proj = try readProject(arena, io, opts.project_file, .require);
    var man = (try readManifest(arena, io, opts.manifest_file)) orelse return Error.NotInManifest;

    var changes: std.ArrayList(Report.Change) = .empty;
    var entries = try arena.dupe(manifest_mod.PackageEntry, man.entries);
    // Opened lazily: freeing a pin needs no registry, and only the untracking
    // arm below has anything to look up.
    var reg: ?source_mod.Backend = null;

    for (names) |name| {
        const idx = findEntry(entries, name) orelse return Error.NotInManifest;
        const e = &entries[idx];
        if (!e.pinned and e.path == null and e.repo_url == null) return Error.NotFreeable;

        if (e.path != null or e.repo_url != null) {
            if (reg == null) {
                reg = try source_mod.open(arena, arena, io, opts.registry_depot, opts.registry_name, .auto);
            }
            _ = resolveName(arena, &reg.?, name) catch |err| switch (err) {
                // `Error.AmbiguousName` still means "registered", and picking
                // between the candidates is the resolve's problem, not this
                // check's.
                Error.NotRegistered => return Error.FreeUnregistered,
                else => {},
            };
        }

        // "delete!(ctx.env.project.sources, pkg.name)" (`:2089`) — unconditional
        // in Pkg, before it even looks at what kind of entry this is.
        _ = proj.removeSource(name);

        e.pinned = false;
        // Untracking is what turns the entry back into something the resolver
        // looks UP rather than injects, so the version has to go too: it was
        // whatever the checkout declared, and there is no reason the registry
        // carries it. `update_package_free!` (`:2067-2076`) leaves the fields
        // on the PackageSpec for a re-resolve to overwrite; here the manifest
        // entry IS the input, so they are cleared.
        if (e.path != null or e.repo_url != null) {
            e.path = null;
            e.repo_url = null;
            e.repo_rev = null;
            e.repo_subdir = null;
            e.version = null;
            e.tree_hash = null;
        }
        try changes.append(arena, .{ .name = e.name, .uuid = e.uuid, .kind = .freed });
    }
    man.entries = entries;

    return finishWithManifest(arena, io, opts, .free, &proj, &man, changes.items, &.{});
}

/// `Pkg.develop` for a LOCAL PATH — `handle_repo_develop!`'s
/// `is_local_path` arm (`Types.jl:776-811`).
///
/// Writes two things and lets the resolve do the rest:
///
///   1. `[deps] Name = "<uuid>"`, from the target's own `Project.toml`;
///   2. a manifest entry carrying `path = "<manifest-relative>"`, which is what
///      makes `resolve.zig`'s `isfixed` treat it as decided rather than
///      resolved and inject its dependencies (`resolve.zig:896-952`).
///
/// **It writes no `[sources]`, because Pkg does not.** That was worth checking
/// rather than assuming: `[sources]` looks like where a develop belongs, and
/// `free` deletes from it (`Operations.jl:2089`), so it reads as symmetrical.
/// But nothing in Pkg ever ADDS to `project.sources` — the only writes are
/// `rm`'s filter (`:1581`) and `test`'s copy (`:2363`) — and running
/// `Pkg.develop(path="../MyPkg")` on 1.12.6 produces a `Project.toml` with
/// `[deps]` and nothing else. `[sources]` is a hand-authored declaration; the
/// manifest `path` is what `develop` records. Writing both would make
/// `ajt dev` and `Pkg.develop` produce different `Project.toml` files for the
/// same operation, which is the one thing this project cannot do.
pub fn dev(arena: Allocator, io: Io, opts: Options, specs: []const Spec) !Report {
    var proj = try readProject(arena, io, opts.project_file, .create);
    // A missing manifest is not an error for `dev`: developing into a fresh
    // environment is a normal first move, and the resolve below writes the
    // manifest that results.
    var man = (try readManifest(arena, io, opts.manifest_file)) orelse
        manifest_mod.Manifest{};

    var changes: std.ArrayList(Report.Change) = .empty;
    var entries: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    try entries.appendSlice(arena, man.entries);

    for (specs) |spec| {
        // Refused before anything is cloned, exactly where Pkg refuses it
        // (`API.jl:260-262`): a develop tracks a working tree, and there is
        // nothing in `handle_repo_develop!` that would honour a rev anyway.
        if (spec.rev != null) return Error.DevRevUnsupported;

        // `isurl` FIRST, `classify` only after — see `git/url.zig`'s header for
        // why the order is part of the contract. `Spec.parseSource` has already
        // asked it; a `url` field means it said yes.
        if (spec.url != null) {
            try devClone(arena, io, opts, &proj, &entries, &changes, spec);
            continue;
        }
        const raw = spec.name;

        // The argument is relative to the user's cwd, not to the project: a
        // shell user typing `ajt dev ../MyPkg` means the directory they can see.
        //
        // The subdir is joined on BEFORE the directory is probed and before the
        // path is recorded, which is what `handle_repo_develop!` does:
        // `dev_path = joinpath(dev_path, pkg.repo.subdir)` sits between the two
        // (`Types.jl:788-790`), so `dev ../mono --subdir pkgs/Foo` requires
        // `../mono/pkgs/Foo` to exist and records exactly that.
        //
        // `original_source_was_absolute` is still decided by what the USER
        // typed (`:780`), not by the joined path, which is why `raw` is what
        // the test below looks at.
        const abs = if (spec.subdir) |d|
            try std.fs.path.join(arena, &.{ try absPath(arena, io, raw), d })
        else
            try absPath(arena, io, raw);
        const target = try readTargetProject(arena, io, abs);

        try proj.addDep(target.name, target.uuid);
        // "delete!(ctx.env.project.weakdeps, pkg.name)" — the same rule `add`
        // follows: a package cannot be declared both ways.
        _ = try proj.weakdeps.remove(proj.arena(), target.name);

        // **Whether the user typed an absolute path is preserved**, exactly as
        // `handle_repo_develop!` does:
        //
        //   original_source_was_absolute = is_local_path && isabspath(...)
        //   pkg.path = original_source_was_absolute ? dev_path
        //                                          : relative_project_path(manifest_file, dev_path)
        //   (`Types.jl:780`, `:805`, `:878`)
        //
        // So `ajt dev ../MyPkg` records `../MyPkg` and `ajt dev /abs/MyPkg`
        // records `/abs/MyPkg`. Always relativising looks tidier and is wrong:
        // it makes the manifest differ from Pkg's for the same operation, which
        // `resolve.sh` caught the moment it ran the absolute form.
        const man_rel = if (std.fs.path.isAbsolute(raw))
            abs
        else
            try relativeTo(arena, try absPath(arena, io, std.fs.path.dirname(opts.manifest_file) orelse "."), abs);
        if (findEntry(entries.items, target.name)) |idx| {
            entries.items[idx].path = man_rel;
            entries.items[idx].version = target.version;
            // A dev'd entry is not content-addressed: there is no tarball and
            // no tree hash, and leaving a stale one behind makes `verify`
            // report a package whose bytes do not match a hash nobody meant.
            entries.items[idx].tree_hash = null;
            entries.items[idx].repo_url = null;
            entries.items[idx].repo_rev = null;
            entries.items[idx].repo_subdir = null;
            entries.items[idx].pinned = false;
        } else {
            try entries.append(arena, .{
                .name = target.name,
                .uuid = target.uuid,
                .version = target.version,
                .path = man_rel,
            });
        }
        try changes.append(arena, .{ .name = target.name, .uuid = target.uuid, .kind = .developed });
    }
    man.entries = entries.items;

    return finishWithManifest(arena, io, opts, .dev, &proj, &man, changes.items, &.{});
}

/// `handle_repo_develop!`'s clone arm (`Types.jl:830-882`).
///
/// Clone to a temporary directory, read the project file to learn the name,
/// then MOVE the whole clone to `devpath(name, shared)` — `<depot>/dev/<Name>`
/// shared, `<env>/dev/<Name>` local (`:762-766`). The move is why the clone
/// starts in a temporary directory at all: the destination is named after
/// something only the clone's own `Project.toml` knows.
///
/// Three details that are easy to get wrong and are all Pkg's:
///
///   * an existing `dev_path` is REUSED, not re-cloned — *"Path `…` exists and
///     looks like the correct repo. Using existing path."* (`:852-854`). It is
///     a working tree somebody may have local commits in.
///   * with a `subdir`, the directory is named after the REPOSITORY rather
///     than the package: the last `/`-separated component of the URL with a
///     trailing `.git` and then a trailing `.jl` chopped (`:843-849`). The
///     recorded path is then `dev_path/<subdir>` (`:879-881`).
///   * `shared` decides absolute-vs-relative for a clone (`:876-878`), which
///     is a different rule from the local-path arm's, where what the user
///     typed decides.
///
/// The clone is NOT bare: it becomes a directory a human edits.
fn devClone(
    arena: Allocator,
    io: Io,
    opts: Options,
    proj: *project_mod.Project,
    entries: *std.ArrayList(manifest_mod.PackageEntry),
    changes: *std.ArrayList(Report.Change),
    spec: Spec,
) !void {
    const backend = opts.git orelse return Error.GitUnavailable;
    const gpa = opts.gpa orelse arena;
    const url = spec.url.?;
    if (!git_url.classify(url).supported()) return git_core.Error.SshUnsupported;

    // `devpath`'s parent (`Types.jl:758-766`):
    //
    //     dev_dir = shared ? abspath(Pkg.devdir()) : joinpath(dirname(project_file), "dev")
    //
    // Note the `abspath` on the shared side. `Pkg.devdir()` is
    // `get(ENV, "JULIA_PKG_DEVDIR", joinpath(depots1(), "dev"))` (`Pkg.jl:42`),
    // so a RELATIVE `JULIA_PKG_DEVDIR` is a reachable configuration — and the
    // shared arm records `dev_path` verbatim into the manifest, so leaving it
    // relative writes a different file from Pkg's for the same operation.
    const env_dir = std.fs.path.dirname(opts.project_file) orelse ".";
    const dev_root = if (opts.shared)
        try absPath(arena, io, opts.devdir orelse blk: {
            const stack = opts.depots orelse return Error.NoDepotForRepo;
            const write = stack.writeDepot() orelse return Error.NoDepotForRepo;
            break :blk try write.devDir(arena);
        })
    else
        try std.fs.path.join(arena, &.{ try absPath(arena, io, env_dir), "dev" });
    try Io.Dir.cwd().createDirPath(io, dev_root);

    // With a subdir the destination is known before the clone (it comes from
    // the URL), so the clone can go straight there. Without one it is not, so
    // the clone lands in a staging sibling and is renamed.
    var staging: ?[]const u8 = null;
    const dev_path = if (spec.subdir) |_|
        try std.fs.path.join(arena, &.{ dev_root, repoName(url) })
    else blk: {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var enc: [16]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&enc, &random_bytes);
        const s = try std.fmt.allocPrint(arena, "{s}/.ajt-dev-{s}", .{ dev_root, enc });
        try Io.Dir.cwd().createDirPath(io, s);
        staging = s;
        errdefer Io.Dir.cwd().deleteTree(io, s) catch {};
        try backend.ensureClone(gpa, io, s, url, .{ .bare = false });
        const t = readTargetProject(arena, io, s) catch return Error.RepoNotAPackage;
        break :blk try std.fs.path.join(arena, &.{ dev_root, t.name });
    };
    errdefer if (staging) |s| Io.Dir.cwd().deleteTree(io, s) catch {};

    // "Path exists and looks like the correct repo. Using existing path."
    const exists = if (Io.Dir.cwd().statFile(io, dev_path, .{})) |st|
        st.kind == .directory
    else |err| switch (err) {
        error.Canceled => return err,
        else => false,
    };
    if (exists) {
        if (staging) |s| Io.Dir.cwd().deleteTree(io, s) catch {};
    } else if (staging) |s| {
        Io.Dir.rename(Io.Dir.cwd(), s, Io.Dir.cwd(), dev_path, io) catch |err| switch (err) {
            error.Canceled => return err,
            else => {
                Io.Dir.cwd().deleteTree(io, s) catch {};
                _ = Io.Dir.cwd().statFile(io, dev_path, .{}) catch return err;
            },
        };
    } else {
        // The subdir case: `ensure_clone` straight into `dev_path` (`:861`).
        try backend.ensureClone(gpa, io, dev_path, url, .{ .bare = false });
    }

    // `resolve_projectfile!(pkg, joinpath(dev_path, subdir))` (`:867-869`) —
    // read AFTER the move, and from inside the subdir when there is one.
    const package_path = if (spec.subdir) |d|
        try std.fs.path.join(arena, &.{ dev_path, d })
    else
        dev_path;
    const target = readTargetProject(arena, io, package_path) catch return Error.RepoNotAPackage;

    try proj.addDep(target.name, target.uuid);
    _ = try proj.weakdeps.remove(proj.arena(), target.name);

    // `pkg.path = shared ? dev_path : relative_project_path(manifest_file,
    // dev_path)` (`:876-878`), then `joinpath(pkg.path, subdir)` (`:879-881`).
    const base = if (opts.shared)
        dev_path
    else
        try relativeTo(arena, try absPath(arena, io, std.fs.path.dirname(opts.manifest_file) orelse "."), dev_path);
    const man_rel = if (spec.subdir) |d| try std.fs.path.join(arena, &.{ base, d }) else base;

    const entry: manifest_mod.PackageEntry = .{
        .name = target.name,
        .uuid = target.uuid,
        .version = target.version,
        .path = man_rel,
    };
    if (findEntry(entries.items, target.name)) |idx| {
        entries.items[idx] = entry;
    } else {
        try entries.append(arena, entry);
    }
    try changes.append(arena, .{ .name = target.name, .uuid = target.uuid, .kind = .developed });
}

/// The directory name `handle_repo_develop!` gives a subdir checkout
/// (`Types.jl:843-849`): the last `/`-separated component of the source, with
/// a trailing `.git` and then a trailing `.jl` chopped — in that order, so
/// `Example.jl.git` becomes `Example`.
///
/// `split(source, '/', keepempty = false)[end]`, so a trailing slash is
/// skipped rather than producing an empty name.
fn repoName(url: []const u8) []const u8 {
    var last: []const u8 = url;
    var it = std.mem.splitScalar(u8, url, '/');
    while (it.next()) |part| {
        if (part.len != 0) last = part;
    }
    if (std.mem.endsWith(u8, last, ".git")) last = last[0 .. last.len - 4];
    if (std.mem.endsWith(u8, last, ".jl")) last = last[0 .. last.len - 3];
    return last;
}

const TargetProject = struct {
    name: []const u8,
    uuid: Uuid,
    version: ?jver.Version,
    /// `[deps]` + `[weakdeps]`, in that order — `collect_project`'s single
    /// `requires` list (`Operations.jl:359-368`). Only the repository arms
    /// record these: a path-tracked entry's dependencies are read back off
    /// disk by the resolve, which is where the `[compat]` bounds come from
    /// too.
    deps: []const manifest_mod.Dep,
};

/// `resolve_projectfile!` (`Types.jl:722-744`): the directory must exist, must
/// carry a project file, and that file must name a package.
fn readTargetProject(arena: Allocator, io: Io, dir: []const u8) !TargetProject {
    const st = Io.Dir.cwd().statFile(io, dir, .{}) catch return Error.DevPathMissing;
    if (st.kind != .directory) return Error.DevPathMissing;

    // `projectfile_path` tries `JuliaProject.toml` before `Project.toml`
    // (`project.jl:5-15`), and the order matters for a repository that carries
    // both — the Julia-specific one wins.
    for ([_][]const u8{ "JuliaProject.toml", "Project.toml" }) |base| {
        const pf = try std.fs.path.join(arena, &.{ dir, base });
        const src = Io.Dir.cwd().readFileAlloc(io, pf, arena, .limited(8 << 20)) catch continue;
        const p = project_mod.parse(arena, src, .{ .file = pf }, null) catch
            return Error.DevPathNotAPackage;
        // A bare ENVIRONMENT has neither; only a PACKAGE can be developed,
        // because a dep needs a uuid to be referred to by.
        const name = p.name orelse return Error.DevPathNotAPackage;
        const uuid = p.uuid orelse return Error.DevPathNotAPackage;
        var deps: std.ArrayList(manifest_mod.Dep) = .empty;
        for ([_]*const project_mod.DepMap{ &p.deps, &p.weakdeps }) |m| {
            for (m.entries.items) |d| {
                try deps.append(arena, .{ .name = d.name, .uuid = d.uuid });
            }
        }
        return .{ .name = name, .uuid = uuid, .version = p.version, .deps = deps.items };
    }
    return Error.DevPathNotAPackage;
}

fn findEntry(entries: []const manifest_mod.PackageEntry, name: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// The manifest is keyed by UUID (`manifest_info`, `Types.jl:1328-1331`), and
/// the repository arms need that key rather than the name: a package cloned
/// from a URL is identified by its own project file, so its name arrives with
/// the checkout rather than with the request.
fn findEntryByUuid(entries: []const manifest_mod.PackageEntry, uuid: Uuid) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, &e.uuid.bytes, &uuid.bytes)) return i;
    }
    return null;
}

/// `Base.abspath` — `normpath(joinpath(pwd(), path))`, lexical and NOT
/// `realpath`, matching `ops/usage.zig:absPath` and Julia. Resolving symlinks
/// here would record a path that disagrees with the one a user typed and that
/// Pkg would write differently.
fn absPath(arena: Allocator, io: Io, path: []const u8) !([]const u8) {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(arena, &.{path});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return Error.DevPathMissing;
    return std.fs.path.resolve(arena, &.{ buf[0..n], path });
}

/// `relpath(target, from)`, and `.` rather than the empty string when they are
/// the same directory — `[sources] path = ""` is not a path Julia resolves.
///
/// Both arguments are already absolute (`absPath`), so the `cwd` argument
/// `std.fs.path.relative` takes is only there for the case this one has
/// already excluded; `"/"` is a placeholder it can never reach.
fn relativeTo(arena: Allocator, from: []const u8, target: []const u8) Allocator.Error![]const u8 {
    const rel = try std.fs.path.relative(arena, "/", null, from, target);
    return if (rel.len == 0) "." else rel;
}

// ---------------------------------------------------------------------------

/// The shared tail of `add` and `up`: resolve with the overrides, write the
/// manifest, then write the project — in that order, so a resolve that fails
/// leaves `Project.toml` alone.
fn finish(
    arena: Allocator,
    io: Io,
    opts: Options,
    verb: Verb,
    proj: *project_mod.Project,
    changes: []const Report.Change,
    overrides: []const resolve_mod.Override,
) !Report {
    return finishInner(arena, io, opts, verb, proj, null, changes, overrides);
}

/// `finish` for the three verbs whose edit is to the MANIFEST. Renders the
/// edited manifest to bytes and hands them to the resolve through
/// `manifest_source`, so `pinned`/`path` are visible to `isfixed`
/// (`resolve.zig:362`) without either file having been written yet.
fn finishWithManifest(
    arena: Allocator,
    io: Io,
    opts: Options,
    verb: Verb,
    proj: *project_mod.Project,
    man: *const manifest_mod.Manifest,
    changes: []const Report.Change,
    overrides: []const resolve_mod.Override,
) !Report {
    var buf: Io.Writer.Allocating = .init(arena);
    var render_arena: std.heap.ArenaAllocator = .init(arena);
    defer render_arena.deinit();
    try man.write(arena, render_arena.allocator(), &buf.writer);
    return finishInner(arena, io, opts, verb, proj, buf.written(), changes, overrides);
}

fn finishInner(
    arena: Allocator,
    io: Io,
    opts: Options,
    verb: Verb,
    proj: *project_mod.Project,
    manifest_source: ?[]const u8,
    changes: []const Report.Change,
    overrides: []const resolve_mod.Override,
) !Report {
    // The resolver reads the project from DISK, so the edit has to be visible
    // to it. Writing first and rolling back on failure would leave a wrong
    // Project.toml behind if the process died in between; resolving against an
    // in-memory copy keeps the file untouched until there is an answer.
    const edited = try proj.serialize(arena);

    const ropts: resolve_mod.Options = .{
        .manifest_source = manifest_source,
        .project_file = opts.project_file,
        .manifest_file = opts.manifest_file,
        .registry_depot = opts.registry_depot,
        .registry_name = opts.registry_name,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
        .tier = opts.tier,
        .offline = opts.offline,
        .build_manifest = true,
        .write_to = if (opts.dry_run) null else opts.manifest_file,
        .depots = opts.depots,
        .fixups = opts.fixups,
        .diagnostic = opts.diagnostic,
        .project_source = edited,
        .overrides = overrides,
        .git = opts.git,
        // `scratch` is left null, so the git backend borrows `arena`. An `add`
        // is a one-shot process and the only thing that would hold is a single
        // `git archive` of a `[sources]` package; paying for a second allocator
        // through six CLI entry points to reclaim it early is not the trade.
    };
    const rep = try resolve_mod.run(arena, io, ropts);

    // The project is written BEFORE the install: from here on the manifest on
    // disk is the resolved one, and a Project.toml that still lacks the new
    // dependency would describe an environment that no longer exists. An
    // install failure then leaves a consistent pair that `instantiate` can
    // finish later, rather than a manifest nobody asked for.
    const project_written = if (opts.dry_run) false else try writeProject(arena, io, proj, opts.project_file);

    var installed: ?usize = null;
    var failed_installs: usize = 0;
    var converged = false;
    if (opts.install and !opts.dry_run) {
        if (opts.depots) |stack| {
            const ires = try instantiate_mod.run(arena, arena, io, .{
                .env_path = std.fs.path.dirname(opts.project_file) orelse ".",
                .manifest_file = opts.manifest_file,
                .stack = stack,
                .julia_prefix = opts.julia_prefix,
                .registry_depot = opts.registry_depot,
                .registry_name = opts.registry_name,
                // `net` is otherwise left at its default here (the server is
                // off, so the install pass uses the GitHub fallback), but the
                // offline bit still has to travel: it is what collapses
                // `registry_policy` to `.never` and what makes an unexpected
                // download an error rather than a request.
                .net = .{ .offline = opts.offline },
                // The manifest was just written by the resolve above; letting
                // instantiate rewrite it would put the fixups pass's output
                // through a second writer for no reason.
                .write_manifest = false,
                // The install pass, not the verb. See "The pass runs HERE" in
                // the module header: Pkg passes `allow_autoprecomp = false` at
                // every internal instantiate, and the one call this function
                // makes below is the verb's single pass.
                .precompile = false,
            }, opts.registry orelse .none);
            // SUCCESSES, not results. `packages` includes failures, and a
            // count that rises when nothing landed is worse than no count --
            // it is what made an install that downloaded nothing report "5".
            var ok_count: usize = 0;
            for (ires.packages) |r| {
                if (r.ok()) ok_count += 1;
            }
            installed = ok_count;
            if (ok_count != ires.packages.len) {
                failed_installs = ires.packages.len - ok_count;
            }
            converged = ires.converged();
        }
    }

    // `Pkg._auto_precompile(ctx)` — `Operations.jl:1828` for `add`, `API.jl:170`
    // for `up`/`pin`/`free`. Conditions are the install pass's own, plus Pkg's
    // per-verb table and `JULIA_PKG_PRECOMPILE_AUTO`.
    var pre: ?precompile_mod.Report = null;
    const skipped: ?PrecompileSkipped = blk: {
        switch (opts.precompile) {
            .off => break :blk .disabled,
            .auto => if (!verb.autoPrecompiles()) break :blk .not_this_verb,
            .force => {},
        }
        if (opts.dry_run) break :blk .dry_run;
        if (!opts.install) break :blk .no_install;
        if (!precompile_mod.autoEnabled(opts.environ)) break :blk .env_disabled;
        const stack = opts.depots orelse break :blk .no_depot;
        if (stack.writeDepot() == null) break :blk .no_depot;
        // The install has to have LANDED, or the compile pass reports
        // `source_missing` for every package whose real problem is already in
        // this Report. Pkg gets the same guarantee from control flow: its
        // `download_source` throws, so `_auto_precompile` is simply never
        // reached.
        if (failed_installs != 0) break :blk .install_failed;
        if (!converged) break :blk .not_instantiated;

        // gpa and arena are the same allocator, exactly as they are for the
        // install pass above: `finishInner` is only ever reached from a
        // one-shot CLI verb that exits immediately afterwards, and threading a
        // second allocator through five public entry points to reclaim a few
        // hundred KB at process teardown would buy nothing.
        pre = try precompile_mod.run(arena, arena, io, .{
            .env_path = opts.project_file,
            .manifest_file = opts.manifest_file,
            .stack = stack,
            .julia_exe = opts.julia_exe,
            .julia_prefix = opts.julia_prefix,
            // `precompile` wants the text form; `edit` carries the parsed one.
            .julia_version = if (opts.julia_version) |v|
                try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch })
            else
                null,
            .environ = opts.environ,
            .jobs = opts.precompile_jobs,
            .cache_url = opts.precompile_cache_url,
        });
        break :blk null;
    };

    return .{
        .changes = changes,
        .resolve = rep,
        .manifest_entries = if (rep.manifest) |m| m.entries.len else null,
        .manifest_written = rep.manifest_written,
        .project_written = project_written,
        .installed = installed,
        .failed_installs = failed_installs,
        .precompile = pre,
        .precompile_skipped = skipped,
    };
}

/// `create` makes a missing file an empty project rather than an error, which
/// is what `read_project` itself does (`project.jl:248`) and what `Pkg.add`
/// relies on: adding into a bare directory is how every environment starts, and
/// Pkg writes both files. `rm` and `up` pass `.require`, because removing from
/// or updating a project that does not exist is a mistake worth naming.
fn readProject(
    arena: Allocator,
    io: Io,
    path: []const u8,
    missing: enum { require, create },
) !project_mod.Project {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => switch (missing) {
            .require => return Error.NoProject,
            // Marked dirty so the write actually happens: a project nobody
            // edited is not written back, and this one exists only in memory.
            .create => {
                var p = try project_mod.empty(arena);
                p.dirty = true;
                return p;
            },
        },
        else => return Error.NoProject,
    };
    return project_mod.parse(arena, src, .{ .file = path }, null);
}

fn readManifest(arena: Allocator, io: Io, path: []const u8) !?manifest_mod.Manifest {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch return null;
    return try manifest_mod.parse(arena, src, null);
}

/// Atomic, and a no-op when nothing changed — `pendingWrite` returns null on a
/// clean project, which is how `add`ing a package that is already a dependency
/// leaves the file's mtime alone.
///
/// Public for the same reason `instantiate.writeIfChanged` is: the tmp-file
/// dance, the errdefer unlink and the "unchanged means do not touch the file"
/// rule are three things a second implementation gets subtly wrong. `compat`
/// writes projects too.
pub fn writeProject(arena: Allocator, io: Io, proj: *const project_mod.Project, path: []const u8) !bool {
    const body = try proj.pendingWrite(arena) orelse return false;
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name_buf: [".ajt-project-".len + 16 + ".tmp".len]u8 = undefined;
    @memcpy(name_buf[0..".ajt-project-".len], ".ajt-project-");
    _ = std.base64.url_safe_no_pad.Encoder.encode(name_buf[".ajt-project-".len..][0..16], &random_bytes);
    @memcpy(name_buf[".ajt-project-".len + 16 ..], ".tmp");
    const tmp_name: []const u8 = &name_buf;
    {
        var file = try dir.createFile(io, tmp_name, .{});
        errdefer dir.deleteFile(io, tmp_name) catch {};
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(body);
        try w.interface.flush();
    }
    errdefer dir.deleteFile(io, tmp_name) catch {};
    try Io.Dir.rename(dir, tmp_name, dir, base, io);
    return true;
}

/// `[targets]` after a removal (`Operations.jl:1577-1580`): each target's list
/// loses names that are no longer a dep or an extra, and a target left with an
/// empty list is dropped.
fn pruneTargets(proj: *project_mod.Project) !void {
    const a = proj.arena();
    var out: std.ArrayList(project_mod.Target) = .empty;
    for (proj.targets.items) |t| {
        var kept: std.ArrayList([]const u8) = .empty;
        for (t.deps) |name| {
            if (proj.deps.contains(name) or proj.extras.contains(name)) {
                try kept.append(a, name);
            }
        }
        if (kept.items.len == 0) {
            proj.dirty = true;
            continue;
        }
        if (kept.items.len != t.deps.len) proj.dirty = true;
        try out.append(a, .{ .name = t.name, .deps = kept.items });
    }
    proj.targets = out;
}

/// Name -> UUID through the registry. `check_registered` (`Operations.jl`) is
/// the equivalent, and the ambiguity case is real: General carries packages
/// that share a name, which is the reason the solver keys on UUIDs at all.
fn resolveName(arena: Allocator, reg: *const source_mod.Backend, name: []const u8) !Uuid {
    _ = arena;
    var found: ?Uuid = null;
    var count: usize = 0;
    // A full scan rather than `findByName`, because the ambiguity matters:
    // General carries distinct packages sharing a name, and picking the first
    // would silently resolve to the wrong one.
    var i: usize = 0;
    while (reg.refAt(i)) |p| : (i += 1) {
        if (!std.mem.eql(u8, p.name(), name)) continue;
        count += 1;
        found = Uuid.parse(p.uuid()) catch continue;
    }
    if (count == 0) return Error.NotRegistered;
    if (count > 1) return Error.AmbiguousName;
    return found.?;
}

fn uuidText(arena: Allocator, u: Uuid) Allocator.Error![]const u8 {
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

// ---------------------------------------------------------------------------

const testing = std.testing;

test "Spec.parse splits Name@version with the PROJECT grammar" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    const bare = try Spec.parse(g, "DataFrames");
    try testing.expectEqualStrings("DataFrames", bare.name);
    try testing.expect(bare.version == null);

    // `Pkg.add("Foo@1.2")` means [1.2, 2), NOT == 1.2 — the caret grammar.
    const pinned = try Spec.parse(g, "DataFrames@1.2");
    try testing.expectEqualStrings("DataFrames", pinned.name);
    try testing.expect(pinned.version != null);
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{pinned.version.?});
    try testing.expectEqualStrings("1.2.0 - 1", w.buffered());
}

test "Spec.parse splits # before @, and asks isUrl before either" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // `Name#rev` — a repository add whose source comes from the manifest or
    // the registry, not a registry add with a decoration.
    const rev = try Spec.parse(g, "Example#master");
    try testing.expectEqualStrings("Example", rev.name);
    try testing.expectEqualStrings("master", rev.rev.?);
    try testing.expect(rev.url == null);
    try testing.expect(rev.isRepo());

    // THE ordering case. Split `@` first and `semver_spec` is handed
    // `1.2#main`; `add` then refuses the pair (`API.jl:313-320`) having
    // correctly understood it, rather than failing to parse it.
    const both = try Spec.parse(g, "Example@1.2#main");
    try testing.expectEqualStrings("Example", both.name);
    try testing.expectEqualStrings("main", both.rev.?);
    try testing.expect(both.version != null);

    // A URL is recognised before `@` is looked at, so userinfo survives.
    const url = try Spec.parse(g, "https://user@github.com/o/r.jl.git#v1.2.3");
    try testing.expectEqualStrings("https://user@github.com/o/r.jl.git", url.url.?);
    try testing.expectEqualStrings("v1.2.3", url.rev.?);
    try testing.expectEqualStrings("", url.name);

    // The rev is everything after the FIRST `#`, as `extract_revision` does.
    const hashy = try Spec.parse(g, "https://github.com/o/r.git#feature#2");
    try testing.expectEqualStrings("feature#2", hashy.rev.?);

    // `Foo#` is `Foo`: an empty rev resolves nothing, and reporting "did not
    // find rev ``" would be a worse answer than the obvious one.
    const empty = try Spec.parse(g, "Example#");
    try testing.expectEqualStrings("Example", empty.name);
    try testing.expect(empty.rev == null);
    try testing.expect(!empty.isRepo());

    // And the plain forms still are what they were.
    const plain = try Spec.parse(g, "Example");
    try testing.expect(!plain.isRepo());
    const versioned = try Spec.parse(g, "Example@1.2");
    try testing.expect(!versioned.isRepo());
    try testing.expect(versioned.version != null);
}

test "dev's grammar has no version token, because a path may contain @" {
    // `parse_path_with_specifiers` (`argument_parsers.jl:266-290`) extracts a
    // subdir and a rev and never a version. Running a path through `add`'s
    // grammar instead tears `/home/u@corp/pkg` in half at the `@` and then
    // fails to `semver_spec` the rest — which is a parse error on a directory
    // that exists.
    const at = Spec.parseSource("/home/u@corp/MyPkg");
    try testing.expectEqualStrings("/home/u@corp/MyPkg", at.name);
    try testing.expect(at.version == null);
    try testing.expect(at.url == null);

    const rel = Spec.parseSource("../MyPkg");
    try testing.expectEqualStrings("../MyPkg", rel.name);
    try testing.expect(!rel.isRepo());

    const url = Spec.parseSource("https://github.com/JuliaLang/Example.jl#master");
    try testing.expectEqualStrings("https://github.com/JuliaLang/Example.jl", url.url.?);
    try testing.expectEqualStrings("master", url.rev.?);
}

test "repoName is Pkg's dev-directory name for a subdir checkout" {
    // `split(source, '/', keepempty=false)[end]`, `.git` chopped, then `.jl`
    // (`Types.jl:843-849`) — in that order, so both come off `Example.jl.git`.
    try testing.expectEqualStrings("Example", repoName("https://github.com/JuliaLang/Example.jl.git"));
    try testing.expectEqualStrings("Example", repoName("https://github.com/JuliaLang/Example.jl"));
    try testing.expectEqualStrings("Example", repoName("https://github.com/JuliaLang/Example"));
    // `keepempty = false`: a trailing slash is skipped, not taken as the name.
    try testing.expectEqualStrings("Example", repoName("https://github.com/JuliaLang/Example.jl/"));
    // `.jl` is only chopped from the END, so a repository that merely
    // contains it keeps its name.
    try testing.expectEqualStrings("Example.jlx", repoName("https://x/Example.jlx"));
}

test "a pin needs an exact version, and the project grammar rarely gives one" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // `Foo@1.2.3` — three components, so `semver_spec` produces `1.2.3 - 1`…
    // which is a RANGE, and therefore not pinnable either. This is the trap
    // `API.jl:487-489` is guarding: the string after `@` goes through the
    // project grammar, where nothing a user is likely to type denotes a single
    // version. `pin Foo` (no version) is the usual form for that reason.
    const three = try Spec.parse(g, "Foo@1.2.3");
    try testing.expect(three.version.?.exact() == null);
    const two = try Spec.parse(g, "Foo@1.2");
    try testing.expect(two.version.?.exact() == null);

    // The registry grammar's `1.2.3 - 1.2.3` IS a single version, and that is
    // what a caller constructing a pin programmatically produces.
    const point = try jspec.Spec.parse(g, "1.2.3 - 1.2.3");
    const v = point.exact().?;
    try testing.expectEqual(@as(u32, 1), v.major);
    try testing.expectEqual(@as(u32, 2), v.minor);
    try testing.expectEqual(@as(u32, 3), v.patch);

    // `1.2 - 1.2` has equal bounds and still spans every patch of 1.2, so it
    // must NOT read as exact.
    const minor_range = try jspec.Spec.parse(g, "1.2 - 1.2");
    try testing.expect(minor_range.exact() == null);
}

test "relativeTo answers `.` rather than the empty string" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    try testing.expectEqualStrings("../MyPkg", try relativeTo(g, "/w/env", "/w/MyPkg"));
    try testing.expectEqualStrings("sub/MyPkg", try relativeTo(g, "/w", "/w/sub/MyPkg"));
    // `[sources] path = ""` is not a path Julia resolves, and a manifest
    // `path = ""` is worse — it reads as "the environment directory itself".
    try testing.expectEqualStrings(".", try relativeTo(g, "/w/env", "/w/env"));
}

test "findEntry matches a manifest entry by name" {
    const entries = [_]manifest_mod.PackageEntry{
        .{ .name = "Aa", .uuid = try Uuid.parse("00000000-0000-0000-0000-00000000000a") },
        .{ .name = "Bb", .uuid = try Uuid.parse("00000000-0000-0000-0000-00000000000b") },
    };
    try testing.expectEqual(@as(usize, 0), findEntry(&entries, "Aa").?);
    try testing.expectEqual(@as(usize, 1), findEntry(&entries, "Bb").?);
    try testing.expect(findEntry(&entries, "Cc") == null);
    // Not a prefix match: `A` is a different package from `Aa`.
    try testing.expect(findEntry(&entries, "A") == null);
}

test "Level.parse covers exactly Pkg's four" {
    try testing.expectEqual(Level.fixed, Level.parse("fixed").?);
    try testing.expectEqual(Level.patch, Level.parse("patch").?);
    try testing.expectEqual(Level.minor, Level.parse("minor").?);
    try testing.expectEqual(Level.major, Level.parse("major").?);
    try testing.expect(Level.parse("patchy") == null);
}
