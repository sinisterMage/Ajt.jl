//! The package install pipeline: turn a resolved `Manifest.toml` into packages
//! on disk that stock `julia` can `using`.
//!
//! Port of `download_source` (`Pkg/src/Operations.jl:1112-1245`) plus the
//! `fixups_from_projectfile!` pass that has to run after it
//! (`Operations.jl:253-291`). Everything that actually *verifies* or *writes*
//! is delegated: `install/extract.zig` hashes the tarball from the stream and
//! extracts only on a match, and `depot.zig` publishes by `renameat`. This
//! module is the part in between — which URLs to try, in what order, how many
//! at once, and what to do with the manifest afterwards.
//!
//! ## The candidate list is ordered, and the order is a fallback chain
//!
//! `download_source` builds `Vector{Pair{String, Bool}}` where the `Bool` is
//! `top` — whether the package tree is at the archive root (`:1160-1177`):
//!
//!   1. `$server/package/$uuid/$tree_hash` => `true`. The Pkg server, added
//!      only when one is configured and the package is in a tracked registry.
//!   2. `get_archive_url_for_version(repo_url, tree_hash)` => `false`, once per
//!      registry `repo` field (`find_urls`, `:1096-1107`). Only GitHub URLs
//!      produce anything (`:762-768`); everything else yields `nothing`.
//!   3. Nothing else. When every archive fails, Pkg falls back to `install_git`
//!      (`:830-880`), a real clone — which is the second pass below.
//!
//! `top` maps exactly onto `extract.Shape`: the Pkg server serves the tree at
//! the top level, GitHub's `/tarball` wraps it in one generated directory and
//! may carry a spurious `pax_global_header`. The shape is carried per
//! candidate, never sniffed — see `extract.zig`'s header for why guessing is
//! unsafe.
//!
//! ## Two passes, and why the second one is sequential
//!
//! `installGitPass` clones what the archives could not serve. It runs AFTER
//! every download worker has finished, never inside one, and that is Pkg's own
//! shape rather than a simplification: `download_source` accumulates failures
//! into `missed_packages` inside the `@sync` block and only walks them —
//! serially — after `close(jobs)` (`Operations.jl:1230-1243`).
//!
//! Ajt keeps it for a harder reason. `runJob` is a worker on a shared cursor
//! with its own scratch arena and its own `http.Client`; a `git.Backend` is
//! process-global in both implementations (libgit2 keeps a global stream
//! registry, the CLI backend spawns children), so a clone inside `runJob` would
//! make the backend shared mutable state reached from N threads.
//!
//! Two kinds of job reach that pass, and they differ only in which directory
//! under `clones/` they use — **both keyings are Pkg's, and `Pkg.gc()` deletes
//! anything under a third** (see `depot.zig`'s `clonesDir`):
//!
//!   * an archive job that exhausted its candidates — `clones/<uuid>`,
//!     `install_git` (`Operations.jl:842-844`);
//!   * a manifest entry carrying `repo-url` — `clones/<hash(url)>`,
//!     `add_repo_cache_path` (`Types.jl:901`), which is what
//!     `Pkg.instantiate`'s own repo loop uses (`API.jl:1358-1390`). Such an
//!     entry never had an archive candidate at all: `download_source` filters
//!     it out (`tracking_registered_version`, `Operations.jl:43-46`).
//!
//! With `Options.git` null neither happens and an exhausted job still comes
//! back as `Outcome.needs_git_clone`, which `check` turns into
//! `error.GitCloneRequired` — today's behaviour, unchanged.
//!
//! ## Concurrency
//!
//! Julia runs `ctx.num_concurrent_downloads` (default 8, `Types.jl:463-467`)
//! `@async` consumers over one `Channel` of jobs (`:1141-1194`). Ajt does the
//! same shape with `Io.concurrent` workers pulling from one atomic cursor. This
//! is deliberately NOT a general scheduler: there is one job list, it is known
//! up front, and each job is independent. The frontier scheduler that overlaps
//! resolution with downloads is the frontier scheduler's job, not this one's.
//!
//! Everything a worker touches is allocated **before** the workers start, so no
//! two workers ever share an allocator: install paths, candidate URLs and the
//! `Attempt` slots all come out of the caller's `arena` in the main thread, and
//! each worker gets its own scratch arena (reset per package, because a tarball
//! is megabytes) and its own HTTP client. `gpa` is still shared — the scratch
//! arenas and `std.http.Client`'s connection pool grow through it — so it must
//! be threadsafe. `std.process.Init.gpa` and `std.testing.allocator` both are.
//!
//! ## Allocation
//!
//! `arena` is bundle-lifetime: every string reachable from a `Result` (paths,
//! URLs) and from a `FixupReport` is allocated there and freed only when the
//! arena is. Nothing returned by this module needs individual freeing, and
//! there is no `deinit`. `gpa` is scratch only, always released before return.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot = @import("../depot.zig");
const extract = @import("../install/extract.zig");
const git = @import("../git/git.zig");
const http = @import("../net/http.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const slug = @import("../julia/slug.zig");
const stdlibs = @import("../julia/stdlibs.zig");
const treehash = @import("../julia/treehash.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;
pub const Manifest = manifest_mod.Manifest;
pub const PackageEntry = manifest_mod.PackageEntry;

/// `num_concurrent_downloads()` (`Types.jl:463-467`). Re-exported from the
/// transport so a caller reads one number from one place; `net/http.zig` also
/// knows how to parse `JULIA_PKG_CONCURRENT_DOWNLOADS` into it.
pub const default_concurrency = http.default_concurrency;

pub const Error = error{
    /// Every archive URL failed and Pkg would now clone the repository
    /// (`install_git`, `Operations.jl:830-880`), but nobody cloned: either no
    /// `Options.git` backend was supplied, or no remote is known for the
    /// package at all — see `Outcome.needs_git_clone`.
    GitCloneRequired,
    /// At least one job failed for a reason other than "needs a git clone".
    /// The per-job `Attempt` list says which URL failed and how.
    InstallFailed,
} || Allocator.Error;

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

/// One package to materialise, i.e. one element of `pkgs_to_install`
/// (`Operations.jl:1113`).
pub const Job = struct {
    name: []const u8,
    uuid: Uuid,
    /// `git-tree-sha1`. The pin the download is checked against, and half of
    /// the version slug the install path is named for.
    tree_hash: Sha1,
    /// `find_urls` (`:1096-1107`): the `repo` field of every registry that
    /// carries this UUID.
    ///
    /// Julia collects these into a `Set{String}`, so with two registries its
    /// iteration order is unspecified. Ajt keeps the caller's order, because a
    /// candidate list that differs run to run cannot be differentially tested
    /// and, more practically, cannot be reported in a bug.
    repo_urls: []const []const u8 = &.{},
    /// `haskey(reg, pkg.uuid)` (`:1168`). False suppresses the server
    /// candidate.
    ///
    /// **This is a deliberately WEAKER test than Pkg's**, and the difference
    /// is worth naming. `download_source` also requires
    /// `Registry.pkg_server_registry_info()` to be non-`nothing` and to list
    /// this registry's UUID (`:1165-1167`) — a live
    /// `GET $server/registries` whose failure mode is "emit no server
    /// candidate at all". Ajt does not make that request, so against a server
    /// that does not track the registry it will try a URL Pkg would not.
    ///
    /// The cost of being wrong is one 404 and a fall through to the GitHub
    /// tarball, which is precisely what the ordered candidate list is built to
    /// absorb; the cost of making the extra request is a round trip per
    /// install even when nothing needs it. If a private-registry setup ever
    /// needs the exact behaviour, the seam is `installWithCandidates`.
    in_registry: bool = true,
    /// Set when the manifest entry tracks a git repository (`repo-url`)
    /// instead of a registered version. Non-null takes the job straight to the
    /// git pass with no archive candidate at all; see `Repo` and the module
    /// header.
    repo: ?Repo = null,
};

/// A manifest entry's `[[deps.X]] repo-url` / `repo-rev` / `repo-subdir`, i.e.
/// Julia's `PackageEntry.repo::GitRepo` (`Types.jl:280-300`).
///
/// Its presence changes exactly two things about the install: the clone is
/// keyed by URL rather than by uuid (`add_repo_cache_path`, `Types.jl:901`),
/// and there is no archive to try first — `download_source` never sees such an
/// entry (`tracking_registered_version`, `Operations.jl:43-46`), and
/// `Pkg.instantiate` installs it by cloning in a loop of its own
/// (`API.jl:1358-1390`).
pub const Repo = struct {
    /// `repo-url`, ready to hand to git. Julia's `pkg.repo.source`, which may
    /// also be a local DIRECTORY rather than a URL — `Pkg.add(path = …)`
    /// records one — in which case `jobsFromManifest` has already resolved it
    /// against the manifest's directory, exactly as `instantiate` does
    /// (`if !isurl(repo_source); repo_source = manifest_rel_path(…)`,
    /// `API.jl:1362-1367`).
    ///
    /// That resolution is not cosmetic: `clones/<hash(url)>` hashes THIS
    /// string, and Pkg hashes the resolved one (`add_repo_cache_path` is called
    /// after the rewrite, `API.jl:1376`). Cloning a relative path verbatim
    /// would also resolve it against the process's cwd rather than the
    /// environment's.
    url: []const u8,
    /// `repo-rev`. Recorded because the entry carries it; **not consulted by
    /// the install.** The manifest is already resolved — the tree hash is the
    /// pin, and Pkg's own instantiate path never looks at `repo.rev` either
    /// (`API.jl:1370-1385` uses `pkg.tree_hash` alone).
    rev: ?[]const u8 = null,
    /// `repo-subdir`. Also **not consulted**, and re-descending into it would
    /// be a silent bug: `handle_repo_add!` already applied the subdir when it
    /// computed the hash (`tree_hash_object[pkg.repo.subdir]`,
    /// `Types.jl:1023-1030`), so `git-tree-sha1` IS the sub-tree's own hash and
    /// materialising it needs no further descent.
    subdir: ?[]const u8 = null,
};

/// How the registry answers "which repos serve this UUID?". A vtable rather
/// than a concrete registry so this module stays independent of *which*
/// registry backend (tarball or `.aix`) the caller opened — and so tests can
/// answer without a registry at all.
pub const RepoLookup = struct {
    ctx: *anyopaque,
    /// Null when the UUID is in no registry at all, which is what clears
    /// `Job.in_registry`. An empty (non-null) slice means "registered, but the
    /// registry records no `repo`" — a real shape, and not the same thing.
    find: *const fn (ctx: *anyopaque, arena: Allocator, uuid_text: []const u8) Allocator.Error!?[]const []const u8,

    fn nothing(_: *anyopaque, _: Allocator, _: []const u8) Allocator.Error!?[]const []const u8 {
        return null;
    }

    /// No registry: every job gets an empty candidate list and therefore needs
    /// a git clone. Useful for testing the ordering logic in isolation.
    pub const none: RepoLookup = .{ .ctx = undefined, .find = nothing };
};

/// `download_source`'s filter (`Operations.jl:1114-1121`), minus the
/// `ispath(path)` test — that one needs the depot and is done inside `install`,
/// which has to compute the same path anyway — **plus** the entries
/// `Pkg.instantiate` installs in its own repo loop (`API.jl:1358-1390`).
///
/// The three conditions of `tracking_registered_version`
/// (`Operations.jl:43-46`) are: not a stdlib, no `path`, no `repo.source`.
///
///   * `path` is skipped here as it is there: a dev'd package is on disk by
///     definition, and nothing may be downloaded over it.
///   * `is_stdlib` needs no separate test: a current stdlib entry carries
///     neither a tree hash nor a path, and the tree hash is what the download
///     is keyed on, so the first condition already filters it.
///   * `repo.source` is NOT skipped. Pkg excludes it from `download_source`
///     only because `instantiate` already cloned it a few lines earlier
///     (`API.jl:1358-1390`) — the entry still has to end up in `packages/` at
///     the same slug. Dropping it here is how an environment that is missing a
///     git-tracked package reports "nothing to do". It becomes a job with
///     `Job.repo` set and, by `candidates`, no archive URL at all.
///
/// The registry is not consulted for a repo-tracked entry: `find_urls` is
/// reached only from `download_source`, which never sees one.
///
/// `manifest_dir` is `dirname(env.manifest_file)`, and it is needed for one
/// case only: a `repo-url` that is a local PATH rather than a URL. Null leaves
/// such a path verbatim, which is right for a caller that has no environment
/// (a test) and wrong for one that does — see `Repo.url`.
///
/// Arena: the returned jobs and their URL lists live in `arena`.
pub fn jobsFromManifest(
    arena: Allocator,
    m: *const Manifest,
    lookup: RepoLookup,
    manifest_dir: ?[]const u8,
) Allocator.Error![]const Job {
    var out: std.ArrayList(Job) = .empty;
    var uuid_buf: [36]u8 = undefined;
    for (m.entries) |e| {
        const th = e.tree_hash orelse continue;
        if (e.path != null) continue;
        if (e.repo_url) |repo_url| {
            try out.append(arena, .{
                .name = e.name,
                .uuid = e.uuid,
                .tree_hash = th,
                // `find_urls` was never asked, so "is it in a registry?" is
                // unanswered rather than false — and false is the safe
                // spelling, because it is what suppresses the Pkg-server
                // candidate. `candidates` refuses one for a repo job anyway.
                .in_registry = false,
                .repo = .{
                    .url = try repoSource(arena, repo_url, manifest_dir),
                    .rev = e.repo_rev,
                    .subdir = e.repo_subdir,
                },
            });
            continue;
        }

        const uuid_text = manifest_mod.formatUuid(e.uuid, &uuid_buf);
        const urls = try lookup.find(lookup.ctx, arena, uuid_text);
        try out.append(arena, .{
            .name = e.name,
            .uuid = e.uuid,
            .tree_hash = th,
            .repo_urls = urls orelse &.{},
            .in_registry = urls != null,
        });
    }
    return out.items;
}

/// `repo_source` as `instantiate` canonicalises it (`API.jl:1362-1367`):
///
/// ```julia
/// if !isurl(repo_source)
///     repo_source = manifest_rel_path(ctx.env, repo_source)
/// end
/// ```
///
/// `isurl` is Pkg's own regex, bug-compatible quirks and all (`url.isUrl`,
/// `utils.jl:27-28`) — asking `classify` instead would send `HTTPS://…`, which
/// Pkg treats as a PATH, down the wrong branch.
///
/// `manifest_rel_path` is `normpath(joinpath(dirname(manifest_file), path))`
/// (`utils.jl:140`) and `fspath.resolve` is exactly that — it collapses
/// `.`/`..` and **does not absolutise** (`std/fs/path.zig:1097`). Julia's
/// result IS absolute only because `EnvCache` holds an absolute
/// `manifest_file`; ajt's `manifest_dir` is whatever the caller typed, so the
/// `Base.abspath` step happens later, in `installOneGit`, where an `Io` exists
/// to ask for the cwd. It has to happen SOMEWHERE: `clones/<hash(url)>` hashes
/// this string and `Pkg.gc()` recomputes it from Pkg's absolute one.
///
/// Julia additionally `pkgerror`s when the resolved path is neither a URL nor a
/// directory (`API.jl:1365-1367`). Not reproduced here: this function does no
/// I/O, and the clone that follows fails with the path in hand anyway.
fn repoSource(
    arena: Allocator,
    repo_url: []const u8,
    manifest_dir: ?[]const u8,
) Allocator.Error![]const u8 {
    if (git.url.isUrl(repo_url)) return repo_url;
    const dir = manifest_dir orelse return repo_url;
    return fspath.resolve(arena, &.{ dir, repo_url });
}

// ---------------------------------------------------------------------------
// Candidate URLs
// ---------------------------------------------------------------------------

pub const Candidate = struct {
    url: []const u8,
    /// `top` in `Operations.jl:1160-1177`, as the flag `extract.zig` takes.
    shape: extract.Shape,
};

pub const Options = struct {
    /// `pkg_server()`, already normalised by `net/auth.zig`'s `pkgServer`.
    /// Null — which is what `JULIA_PKG_SERVER=""` means — drops candidate 1.
    server: ?[]const u8 = null,
    /// The transport config the download client is built from: the `Julia-*`
    /// protocol headers (`PlatformEngines.jl:220-252`) and the depot the
    /// bearer token is read out of (`depots1()`).
    ///
    /// Supply it. A default-constructed one sends `Julia-Version:` and
    /// `Julia-System:` EMPTY and finds no `servers/<host>/auth.toml`, which a
    /// public server tolerates and a private one answers with a 401 — a
    /// failure that then looks like "the package is missing" rather than "you
    /// are not authenticated". `server` still wins over `net.server`, so the
    /// two cannot disagree about which server the candidate list was built for.
    net: http.Config = .{},
    /// `ctx.num_concurrent_downloads` (`Types.jl:463-467`).
    concurrency: u32 = default_concurrency,
    /// Ceiling on one downloaded archive. General's largest package tarball is
    /// a few hundred megabytes of test data; this is a guard against a server
    /// that answers with an endless stream, enforced DURING the read by
    /// `net/http.zig`, not after.
    max_archive_bytes: usize = 1 << 30,
    /// Per-URL retry. Julia's `install_archive` does NOT retry a URL — it
    /// moves to the next candidate (`Operations.jl:778-787`), which is the
    /// better behaviour when a mirror is down — so this defaults to a single
    /// attempt, matching.
    retry: http.Retry = .none,
    /// Packages are content-addressed and Pkg makes them read-only
    /// (`Operations.jl:1180`, `set_readonly` at `utils.jl:55-78`). Unlike
    /// `registries/`, which stays writable.
    commit: depot.CommitOptions = .{ .set_readonly = true },
    /// The backend `installGitPass` clones with. **Null is today's behaviour**:
    /// no clone happens, an exhausted job stays `needs_git_clone`, and `check`
    /// raises `error.GitCloneRequired`.
    ///
    /// Pkg has no switch here — `install_git` is unconditional — but Ajt's
    /// backends are `git.cli` (a `git` subprocess) and, behind `-Dgit`,
    /// libgit2, and a build with neither must still install every package an
    /// archive can serve rather than refusing to run.
    git: ?git.Backend = null,
};

/// The candidate list for one job, in Pkg's order (`Operations.jl:1160-1177`).
/// Pure; arena-allocated.
pub fn candidates(arena: Allocator, job: Job, server: ?[]const u8) Allocator.Error![]const Candidate {
    // A repo-tracked entry has no archive at all. `download_source` filters it
    // out before any URL is built (`tracking_registered_version`,
    // `Operations.jl:43-46`, `:1115`) and `instantiate` clones it instead
    // (`API.jl:1358-1390`). Stated here as well as in `jobsFromManifest`
    // because `installWithCandidates` lets a caller supply its own list, and
    // an archive fetched for such an entry would be a tree nobody pinned.
    if (job.repo != null) return &.{};

    var out: std.ArrayList(Candidate) = .empty;

    if (job.in_registry) if (server) |s| {
        var uuid_buf: [36]u8 = undefined;
        var hash_buf: [40]u8 = undefined;
        try out.append(arena, .{
            .url = try std.fmt.allocPrint(arena, "{s}/package/{s}/{s}", .{
                trimTrailingSlash(s),
                manifest_mod.formatUuid(job.uuid, &uuid_buf),
                manifest_mod.formatSha1(job.tree_hash, &hash_buf),
            }),
            .shape = .top_level,
        });
    };

    var hash_buf: [40]u8 = undefined;
    const ref = manifest_mod.formatSha1(job.tree_hash, &hash_buf);
    for (job.repo_urls) |repo_url| {
        const url = try githubArchiveUrl(arena, repo_url, ref) orelse continue;
        try out.append(arena, .{ .url = url, .shape = .github_tarball });
    }

    return out.items;
}

/// `pkg_server()` already strips a trailing slash (`PlatformEngines.jl:29-36`),
/// so this only matters for a `server` handed in by hand. Julia interpolates
/// `"$server/package/..."` blindly and would produce a `//`.
fn trimTrailingSlash(s: []const u8) []const u8 {
    return if (s.len > 1 and s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
}

/// `get_archive_url_for_version` (`Operations.jl:762-768`):
///
/// ```julia
/// if (m = match(r"https://github.com/(.*?)/(.*?).git", url)) !== nothing
///     return "https://api.github.com/repos/$(m.captures[1])/$(m.captures[2])/tarball/$(ref)"
/// end
/// ```
///
/// Reimplemented literally, because three details of that regex are load-
/// bearing and none of them is what a hand-written parser would do. All four
/// were confirmed by running the real function on 1.12.6:
///
///   * **`.` matches any character, including `/`.** So capture 2 spans
///     slashes: `https://github.com/Org/Sub.Group/Repo.jl.git` yields
///     `repos/Org/Sub.Group/Repo.jl`, not `repos/Org/Sub.Group`. Splitting on
///     `/` would silently target the wrong repository.
///   * **`.git` is `<any char>git`, not a literal.** `https://github.com/O/R.git.git`
///     yields `repos/O/R` — the FIRST position where any character is followed
///     by `git` wins, because both groups are lazy.
///   * **`match` is unanchored.** `"prefix https://github.com/O/R.jl.git"`
///     matches. A `startsWith` check would reject a URL Pkg accepts.
///   * A URL with no `.git` suffix (`https://github.com/O/R`) yields null, and
///     so does an SSH remote (`git@github.com:O/R.git`) — the pattern demands
///     the `https://github.com/` prefix verbatim.
///
/// Returns null where Julia returns `nothing`. Arena-allocated.
pub fn githubArchiveUrl(
    arena: Allocator,
    repo_url: []const u8,
    ref: []const u8,
) Allocator.Error!?[]u8 {
    const m = matchGithubRepo(repo_url) orelse return null;
    return try std.fmt.allocPrint(
        arena,
        "https://api.github.com/repos/{s}/{s}/tarball/{s}",
        .{ m.owner, m.repo, ref },
    );
}

const GithubMatch = struct { owner: []const u8, repo: []const u8 };

/// PCRE leftmost-then-lazy semantics for `https://github.com/(.*?)/(.*?).git`.
///
/// The outer loop is "leftmost match wins": `match` scans start positions left
/// to right. The two inner loops are the lazy quantifiers: the shortest capture
/// 1 that is followed by `/` and admits some capture 2 wins, and for that
/// capture 1 the shortest capture 2 followed by `<any>git` wins. The `!= '\n'`
/// conditions are `.` not matching a newline without the `s` flag — a URL can
/// never contain one, but reproducing the pattern is cheaper than arguing
/// about it.
fn matchGithubRepo(url: []const u8) ?GithubMatch {
    const prefix = "https://github.com/";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, url, start, prefix)) |i| : (start = i + 1) {
        const after = i + prefix.len;
        var j = after;
        // Capture 1: `(.*?)` then a literal `/`.
        while (j < url.len and url[j] != '\n') : (j += 1) {
            if (url[j] != '/') continue;
            // Capture 2: `(.*?)` then `.git`, i.e. any character then "git".
            // Reaching index k means every position in j+1..k-1 was inspected
            // and none was a newline, so the span is newline-free by induction.
            var k = j + 1;
            while (k + 4 <= url.len and url[k] != '\n') : (k += 1) {
                if (std.mem.eql(u8, url[k + 1 ..][0..3], "git")) {
                    return .{ .owner = url[after..j], .repo = url[j + 1 .. k] };
                }
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

/// One URL tried, and how it went. Kept for every candidate so a failure can be
/// reported as "the server 404'd and GitHub's tarball did not match the pin"
/// rather than as a bare error code — Pkg only `@warn`s these and moves on,
/// which is exactly why an install that quietly did nothing is hard to debug.
pub const Attempt = struct {
    /// Which pass made it. An `Attempt` is the only record a caller gets of a
    /// failure, and "the GitHub tarball 404'd" and "the clone could not reach
    /// the remote" are different problems with different fixes.
    pub const Kind = enum { archive, git };

    /// The archive URL for `.archive`. For `.git`, the remote that was cloned
    /// or fetched — **always through `git.url.redact`**, so a credential
    /// embedded in a URL cannot reach a log (`git/url.zig`'s header) — except
    /// on the final publish attempt of a git job, where it is the local clone
    /// directory the tree was materialised out of.
    url: []const u8,
    kind: Kind = .archive,
    /// Null for `.git`: a clone has no archive layout to interpret.
    shape: ?extract.Shape = null,
    /// The refspec a `.git` fetch used, so two attempts against the same
    /// remote are distinguishable — `refspecs_heads` then `refspecs_all` is
    /// Pkg's own two-step (`Types.jl:1004-1006`).
    refspec: ?[]const u8 = null,
    /// Null on the attempt that succeeded, and on attempts never reached.
    err: ?anyerror = null,
    /// Set instead of a transport error when the server answered with a
    /// non-2xx status. A 404 from the Pkg server for a package it does not
    /// mirror is the normal path to the GitHub fallback, not a fault.
    status: ?std.http.Status = null,
    /// The hash the archive actually had, when `err` is `TreeHashMismatch`.
    /// Pkg discards this ("tarball content does not match git-tree-sha1",
    /// `Operations.jl:813`) and leaves you with no way to tell a corrupted
    /// mirror from a wrong pin.
    computed: ?[40]u8 = null,
    /// True once this attempt was actually made; the rest were never reached.
    tried: bool = false,
};

pub const Outcome = enum {
    /// This process downloaded an archive, verified it and published the tree.
    installed,
    /// This process cloned the repository and published the tree
    /// (`install_git`, `Operations.jl:830-880`, or `instantiate`'s repo loop,
    /// `API.jl:1358-1390`). Distinguished from `installed` because the two
    /// paths have entirely different failure modes and a report that conflated
    /// them could not say which one ran. `Result.source` is null here — the
    /// remote is in the `.git` attempts.
    installed_git,
    /// The install path already existed — either from an earlier run or from a
    /// competitor that won the rename race. Success either way: the path is
    /// content-addressed.
    already_present,
    /// Every archive candidate failed and Pkg would fall back to
    /// `install_git` — but nothing cloned. Two ways to get here, and both mean
    /// "nothing was tried", which is why it is not `failed`:
    ///
    ///   * no `Options.git` backend was supplied; or
    ///   * no remote is known at all — an unregistered package whose registry
    ///     yielded no `repo`. `install_git` cannot start either: `first(urls)`
    ///     throws on an empty `Set{String}` (`Operations.jl:846`).
    ///
    /// With a backend AND a remote, a job never ends here: it becomes
    /// `installed_git` or `failed`.
    needs_git_clone,
    /// An archive candidate reached the filesystem and failed there (no space,
    /// permission denied), or the git pass ran and could not produce the tree.
    /// Distinct from `needs_git_clone`, which means "nobody tried".
    failed,
};

pub const Result = struct {
    name: []const u8,
    uuid: Uuid,
    tree_hash: Sha1,
    /// Where the package is (or was going to be):
    /// `<depot>/packages/<Name>/<version slug>`.
    path: []const u8,
    outcome: Outcome,
    /// Which candidate installed it, or null.
    source: ?Candidate = null,
    attempts: []Attempt = &.{},

    pub fn ok(self: Result) bool {
        return switch (self.outcome) {
            .installed, .installed_git, .already_present => true,
            .needs_git_clone, .failed => false,
        };
    }
};

/// Turns per-job outcomes into one error, so a caller that just wants
/// "did it work?" does not have to walk the results.
pub fn check(results: []const Result) Error!void {
    var needs_git = false;
    var failed = false;
    for (results) |r| switch (r.outcome) {
        .installed, .installed_git, .already_present => {},
        .needs_git_clone => needs_git = true,
        .failed => failed = true,
    };
    // `failed` first: it is the more actionable of the two, and a caller that
    // implements the git fallback still cannot proceed past a full disk.
    if (failed) return error.InstallFailed;
    if (needs_git) return error.GitCloneRequired;
}

/// How much of a worker's scratch arena survives a reset. Big enough that a
/// typical package (tens of KB compressed, a few hundred KB unpacked) never
/// re-allocates, small enough that a huge one is not held for the whole run.
const scratch_retain_limit = 8 << 20;

const Worker = struct {
    scratch: std.heap.ArenaAllocator,
    client: http.Client,

    fn deinit(self: *Worker) void {
        self.client.deinit();
        self.scratch.deinit();
    }
};

const Shared = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    jobs: []const Job,
    results: []Result,
    cursor: std.atomic.Value(usize) = .init(0),
};

/// Download and install every job that is not already in the depot.
///
/// `stack` is the resolved `DEPOT_PATH`: every entry is searched for an
/// existing install, and `stack.writeDepot()` (entry 0) is where new ones land
/// — `Pkg.depots1()` (`Pkg/src/Pkg.jl:24-32`).
///
/// Arena: the returned slice and every string it reaches live in `arena`. `gpa`
/// backs the per-worker scratch arenas and the HTTP connection pools, all
/// released before returning; it must be threadsafe (see the module header).
///
/// Per-job failures are reported in the `Result`, never raised: a 404 for one
/// package must not abort the other 200. Use `check` to collapse them.
pub fn install(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    jobs: []const Job,
    opts: Options,
) (Error || depot.FindError)![]const Result {
    const lists = try arena.alloc([]const Candidate, jobs.len);
    for (jobs, lists) |job, *l| l.* = try candidates(arena, job, opts.server);
    return installWithCandidates(gpa, arena, io, stack, jobs, lists, opts);
}

/// `install` with the candidate list supplied per job instead of derived from
/// `Options.server` and the job's registry URLs.
///
/// This is the seam Pkg does not have: `download_source` builds the list inline
/// (`Operations.jl:1160-1177`). Splitting it lets the fallthrough behaviour —
/// server 404 to GitHub tarball — be tested against a loopback server instead
/// of against api.github.com, and lets a caller with its own mirror policy
/// substitute one without reimplementing the install loop.
pub fn installWithCandidates(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    jobs: []const Job,
    lists: []const []const Candidate,
    opts: Options,
) (Error || depot.FindError)![]const Result {
    std.debug.assert(jobs.len == lists.len);
    const results = try arena.alloc(Result, jobs.len);

    // --- everything allocated up front, in this thread --------------------
    //
    // A worker must not touch `arena` (it is not threadsafe) and must not need
    // to allocate a path or a URL mid-flight. So the install path and the
    // `Attempt` slots are all built here; workers only fill in POD fields.
    var pending: usize = 0;
    var with_candidates: usize = 0;
    for (jobs, lists, results) |job, cands, *r| {
        const found = try depot.findInstalled(arena, io, stack, job.name, job.uuid, job.tree_hash);
        r.* = .{
            .name = job.name,
            .uuid = job.uuid,
            .tree_hash = job.tree_hash,
            .path = found.path,
            .outcome = if (found.exists) .already_present else .needs_git_clone,
        };
        if (found.exists) continue;

        const attempts = try arena.alloc(Attempt, cands.len);
        for (cands, attempts) |c, *a| a.* = .{ .url = c.url, .shape = c.shape };
        r.attempts = attempts;
        pending += 1;
        if (cands.len != 0) with_candidates += 1;
    }
    if (pending == 0) return results;

    // --- pass 1: archives, concurrently ------------------------------------
    //
    // Skipped entirely when no job has a candidate — an environment of nothing
    // but `repo-url` entries, or a run with no registry and no server. Each
    // worker builds an `http.Client` (a connection pool, a TLS context), and
    // there is no request for any of them to make.
    if (with_candidates != 0) {
        var shared: Shared = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .jobs = jobs,
            .results = results,
        };

        const n = @min(@as(usize, @max(opts.concurrency, 1)), pending);
        const workers = try gpa.alloc(Worker, n);
        defer gpa.free(workers);
        var made: usize = 0;
        defer for (workers[0..made]) |*w| w.deinit();
        // One client per worker. `std.http.Client`'s connection pool is shared
        // state, and nothing here needs cross-worker connection reuse: each
        // worker makes at most one request at a time to one host.
        var net_config = opts.net;
        net_config.server = opts.server;
        while (made < n) : (made += 1) {
            workers[made] = .{
                .scratch = .init(gpa),
                .client = .init(gpa, io, net_config),
            };
        }

        const futures = try gpa.alloc(?Io.Future(void), n);
        defer gpa.free(futures);
        @memset(futures, null);
        // Worker 0 runs inline: with `concurrency = 1` that is the whole job,
        // and it also means a single-threaded `Io` needs no special case.
        for (workers[1..], futures[1..]) |*w, *f| {
            f.* = io.concurrent(runWorker, .{ &shared, w }) catch |err| switch (err) {
                // `Io.concurrent` refuses when the implementation offers no
                // concurrency at all. Fall back to running everything inline
                // rather than failing an install over a scheduling preference.
                error.ConcurrencyUnavailable => null,
            };
        }
        runWorker(&shared, &workers[0]);
        for (futures[1..], workers[1..]) |*f, *w| {
            if (f.*) |*fut| fut.await(io) else runWorker(&shared, w);
        }
    }

    // --- pass 2: whatever is left, cloned ----------------------------------
    // `missed_packages`, after `close(jobs)` (`Operations.jl:1230-1243`).
    try installGitPass(gpa, arena, io, stack, jobs, results, opts);

    return results;
}

fn runWorker(shared: *Shared, w: *Worker) void {
    while (true) {
        const i = shared.cursor.fetchAdd(1, .monotonic);
        if (i >= shared.jobs.len) return;
        // `results[i]` is written by exactly one worker, so the slice needs no
        // lock: the elements are disjoint and never resized.
        const r = &shared.results[i];
        if (r.outcome == .already_present) continue;
        runJob(shared, w, r);
    }
}

/// `install_archive` for one package (`Operations.jl:770-822`), with the
/// verify-then-write order that module deliberately inverts.
fn runJob(shared: *Shared, w: *Worker, r: *Result) void {
    const io = shared.io;
    for (r.attempts) |*at| {
        at.tried = true;
        // One tarball at a time, so the worker's peak is the largest single
        // archive rather than the sum of the run.
        //
        // `retain_with_limit`, not `retain_capacity`: the latter pre-heats to
        // everything allocated since the last reset and NEVER shrinks, so one
        // 300 MB package would pin 300 MB per worker — 8× that at the default
        // concurrency — for the rest of the run. The limit keeps the common
        // case allocation-free (General's median package is well under it)
        // while letting an outlier's memory go.
        _ = w.scratch.reset(.{ .retain_with_limit = scratch_retain_limit });
        const sa = w.scratch.allocator();

        const res = w.client.get(sa, at.url, .{
            .max_body_bytes = shared.opts.max_archive_bytes,
            .retry = shared.opts.retry,
        }) catch |err| {
            at.err = err;
            continue;
        };
        if (!res.ok()) {
            at.status = res.status;
            at.err = error.HttpRequestFailed;
            continue;
        }

        // Staging is a SIBLING of the destination, so the publish is a
        // same-filesystem `renameat`; see `depot.begin`.
        var inst = depot.begin(sa, io, r.path) catch |err| {
            at.err = err;
            continue;
        };
        // Runs on every path out of this iteration, including the `return`
        // below, where it is a no-op because `commit` consumed the staging dir.
        defer inst.deinit(io);

        var computed: extract.Hash = undefined;
        // Non-null by construction: every attempt this loop sees was built
        // from a `Candidate`, which always carries a shape.
        const eopts: extract.Options = .{ .shape = at.shape.?, .computed = &computed };
        // Pkg's `unpack` shells out to 7z/tar, which sniff the container. Both
        // real sources serve gzip; a bare tar is accepted because deciding from
        // two magic bytes is more honest than trusting the URL.
        const verified = if (isGzip(res.body))
            extract.verifyAndExtractGzip(shared.gpa, io, res.body, r.tree_hash.bytes, inst.dir, eopts)
        else
            extract.verifyAndExtractTar(shared.gpa, io, res.body, r.tree_hash.bytes, inst.dir, eopts);
        verified catch |err| {
            at.err = err;
            if (err == error.TreeHashMismatch) at.computed = treehash.toHex(computed);
            continue;
        };

        const outcome = inst.commit(shared.gpa, io, shared.opts.commit) catch |err| {
            at.err = err;
            // The content verified and the environment refused it. A different
            // mirror would serve the same bytes and hit the same wall, so stop.
            r.outcome = .failed;
            return;
        };
        r.source = .{ .url = at.url, .shape = at.shape.? };
        r.outcome = switch (outcome) {
            .installed => .installed,
            .already_present => .already_present,
        };
        return;
    }
    // Out of archives. `installGitPass` is next (`Operations.jl:1233-1245`),
    // and leaves this alone if there is no backend to clone with.
    r.outcome = .needs_git_clone;
}

fn isGzip(b: []const u8) bool {
    return b.len >= 2 and b[0] == 0x1f and b[1] == 0x8b;
}

// ---------------------------------------------------------------------------
// install_git — the second pass
// ---------------------------------------------------------------------------

/// Clone whatever the archive pass could not serve.
///
/// Sequential, in the caller's thread, after every worker has joined. See the
/// module header for why that is not negotiable and where Pkg does the same.
///
/// A no-op when `opts.git` is null, which leaves every exhausted job at
/// `needs_git_clone` — the behaviour before this pass existed, and the reason
/// `check` still has `error.GitCloneRequired`.
///
/// Arena: attempt records, clone paths and staging paths are arena-allocated,
/// which is safe here precisely because nothing else is running. `gpa` is the
/// backend's scratch.
fn installGitPass(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    jobs: []const Job,
    results: []Result,
    opts: Options,
) (Error || depot.FindError)!void {
    const backend = opts.git orelse return;

    var any = false;
    for (results) |r| {
        if (r.outcome == .needs_git_clone) {
            any = true;
            break;
        }
    }
    // Not merely an optimisation: `writeDepot` below is fallible, and an
    // install with nothing left to do must not fail over a depot it was never
    // going to write to.
    if (!any) return;

    // `joinpath(depots1(), "clones")` (`Operations.jl:842`) — the clone cache
    // is written to depot 1 even when the package itself was found elsewhere.
    const write = stack.writeDepot() orelse return error.NoDepot;

    for (jobs, results) |job, *r| {
        if (r.outcome != .needs_git_clone) continue;
        try installOneGit(gpa, arena, io, write, backend, job, r, opts);
    }
}

/// One package, cloned. `install_git` (`Operations.jl:830-880`) for an
/// exhausted archive job, and `instantiate`'s repo loop
/// (`API.jl:1358-1390`) for a `repo-url` entry — the same six steps with two
/// parameters different.
///
/// Failures are recorded in `r.attempts` and turn the outcome into `.failed`,
/// never raised: one unreachable repository must not abandon the packages that
/// installed. Pkg has no such tolerance here (`install_git` throws and
/// `download_source` propagates), but it also prints as it goes; a report that
/// is returned rather than printed has to carry the failure.
fn installOneGit(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    write: depot.Depot,
    backend: git.Backend,
    job: Job,
    r: *Result,
    opts: Options,
) Allocator.Error!void {
    var attempts: std.ArrayList(Attempt) = .empty;
    try attempts.appendSlice(arena, r.attempts);
    // On every path out, including each failure below.
    defer r.attempts = attempts.items;

    // --- which remotes, and which clone directory --------------------------
    //
    // The two keyings are both Pkg's and a third would be collected by
    // `Pkg.gc()`; see `depot.zig`'s `clonesDir`.
    // The one-element list a repo job fetches from lives on the stack: it does
    // not escape (`addGitAttempt` copies what it records).
    var repo_url_buf: [1][]const u8 = undefined;
    const urls: []const []const u8 = if (job.repo) |repo| blk: {
        repo_url_buf[0] = try absoluteSource(arena, io, repo.url);
        break :blk &repo_url_buf;
    } else job.repo_urls;

    const clone_dir = if (job.repo != null)
        // `add_repo_cache_path(repo_source)` (`Types.jl:901`, used at
        // `API.jl:1376`): keyed on the URL because the user named it, and
        // shared with `add`/`develop` of the same repository. Keyed on the
        // ABSOLUTISED source, which is what Pkg hashes — the rewrite at
        // `API.jl:1366` happens before the call at `:1376`.
        try write.cloneUrlDir(arena, urls[0])
    else
        // `joinpath(clones_dir, string(uuid))` (`Operations.jl:844`).
        try write.cloneUuidDir(arena, job.uuid);

    // `first(urls)` on an empty `Set{String}` throws in Julia
    // (`Operations.jl:846`), so an unregistered package with no URL at all
    // cannot be cloned there either. Leave `needs_git_clone` standing: nothing
    // was tried, and that is exactly what the outcome means.
    if (urls.len == 0) return;

    // `Types.refspecs` then `refspecs_fallback` (`Types.jl:746-747`).
    //
    // **The two call sites differ and Ajt takes the wider one.** `install_git`
    // fetches `+refs/*:refs/remotes/cache/*` only (`Operations.jl:829`), while
    // `instantiate`'s repo loop fetches heads only and gives up
    // (`API.jl:1379`) — so Pkg cannot install a `repo-url` entry whose tree is
    // reachable from a tag alone. Doing heads-then-everything is not an
    // invention: it is verbatim what `handle_repo_add!` does for the same
    // clone directory (`Types.jl:1000-1008`), i.e. what put that tree hash in
    // the manifest in the first place. Divergence direction: Ajt installs
    // strictly more than Pkg here, never a different tree — the hash is
    // re-derived from disk below.
    const refspecs: []const []const u8 = if (job.repo != null)
        &.{ git.refspecs_heads, git.refspecs_all }
    else
        &.{git.refspecs_all};

    // --- ensure_clone (`Operations.jl:845-848`, `API.jl:1377`) -------------
    const clone_at = try addGitAttempt(arena, &attempts, urls[0]);
    backend.ensureClone(gpa, io, clone_dir, urls[0], .{ .bare = true }) catch |err| {
        attempts.items[clone_at].err = err;
        r.outcome = .failed;
        return;
    };

    // --- fetch until the tree object is present ---------------------------
    //
    // `install_git` probes the object BEFORE each fetch and breaks as soon as
    // it is there (`Operations.jl:850-859`); a fresh clone of the first URL
    // usually already has it, which is why the probe comes first. Checking
    // after each fetch instead of before the next one is the same sequence of
    // operations with the final `GitObject` re-check (`:860-865`) folded in.
    var have = backend.hasObject(gpa, io, clone_dir, job.tree_hash) catch |err| {
        attempts.items[clone_at].err = err;
        r.outcome = .failed;
        return;
    };
    if (!have) {
        fetching: for (urls) |u| {
            for (refspecs) |spec| {
                const at = try addGitAttempt(arena, &attempts, u);
                attempts.items[at].refspec = spec;
                backend.fetch(gpa, io, clone_dir, u, spec) catch |err| {
                    attempts.items[at].err = err;
                    continue;
                };
                have = backend.hasObject(gpa, io, clone_dir, job.tree_hash) catch |err| {
                    attempts.items[at].err = err;
                    r.outcome = .failed;
                    return;
                };
                if (have) break :fetching;
            }
        }
    }

    // Everything from here on is local, so it is one record: the clone
    // directory the tree came out of. A path, never a URL — no credential can
    // ride on it.
    const publish = try addGitAttempt(arena, &attempts, clone_dir);
    if (!have) {
        // "$name: git object $(string(hash)) could not be found"
        // (`Operations.jl:862`) / "Did not find tree_hash …" (`API.jl:1382`).
        attempts.items[publish].err = error.ObjectNotFound;
        r.outcome = .failed;
        return;
    }

    // --- materialise into staging, verify, publish ------------------------
    //
    // Pkg `mkpath(version_path)` and checks out straight into it
    // (`Operations.jl:867-868`), so an interrupted clone leaves a partial
    // package at the slug that `find_installed` will call installed forever
    // after. Staging plus `renameat` is the same rule as the archive path.
    var inst = depot.begin(arena, io, r.path) catch |err| {
        attempts.items[publish].err = err;
        r.outcome = .failed;
        return;
    };
    defer inst.deinit(io);

    // `materialise` takes a path and `Install` holds an open handle plus the
    // staging basename. The staging directory is a SIBLING of the destination
    // by construction (`depot.begin`), so this names the very directory
    // `inst.dir` has open.
    const staging = try fspath.join(arena, &.{
        fspath.dirname(r.path) orelse ".",
        &inst.tmp_name,
    });
    backend.materialise(gpa, io, clone_dir, job.tree_hash, staging) catch |err| {
        attempts.items[publish].err = err;
        r.outcome = .failed;
        return;
    };

    // **The check Pkg does not make.** `checkout_tree_to_path` passes only
    // `CHECKOUT_FORCE` (`GitTools.jl:83-91`) and never re-verifies, so a
    // `.gitattributes` carrying `text=auto` or `eol=crlf` silently writes a
    // tree whose hash is not the one the directory is NAMED for — and the name
    // is `versionSlug(uuid, tree_hash)`. Ajt re-hashes what actually landed,
    // with its own hasher, before anything is published. See `git.zig`'s
    // header for the two ways a backend can get this wrong.
    const got = treehash.hashPath(gpa, io, staging) catch |err| {
        attempts.items[publish].err = err;
        r.outcome = .failed;
        return;
    };
    if (!std.mem.eql(u8, &got, &job.tree_hash.bytes)) {
        attempts.items[publish].err = error.TreeHashMismatch;
        attempts.items[publish].computed = treehash.toHex(got);
        r.outcome = .failed;
        return;
    }

    const outcome = inst.commit(gpa, io, opts.commit) catch |err| {
        attempts.items[publish].err = err;
        r.outcome = .failed;
        return;
    };
    r.outcome = switch (outcome) {
        // `readonly && set_readonly(path)` (`Operations.jl:1235`) — the git
        // path gets the same mode rule as the archive one.
        .installed => .installed_git,
        .already_present => .already_present,
    };
}

/// `Base.abspath` on a `repo-url` that names a directory rather than a remote
/// — `normpath(joinpath(pwd(), path))`, lexical and deliberately NOT
/// `realpath` (same rule, and the same reason, as `ops/usage.zig`'s `absPath`:
/// Julia does not resolve symlinks here, and a key that disagreed with the one
/// `julia` computes would name a clone directory `Pkg.gc()` deletes).
///
/// `jobsFromManifest` has already joined it onto the manifest's directory
/// (`repoSource`); this only supplies the cwd that Julia gets for free from
/// `EnvCache`'s absolute `manifest_file`. A URL is returned untouched — Pkg's
/// `isurl` guards the same rewrite at `API.jl:1362`.
///
/// A cwd that cannot be read leaves the path relative rather than failing the
/// install: git resolves it against the same cwd and the clone still works;
/// only the cache key is then one `Pkg.gc()` will not recompute.
fn absoluteSource(arena: Allocator, io: Io, url: []const u8) Allocator.Error![]const u8 {
    if (git.url.isUrl(url)) return url;
    if (fspath.isAbsolute(url)) return url;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return url;
    return fspath.resolve(arena, &.{ buf[0..n], url });
}

/// Append one `.git` attempt and return its INDEX.
///
/// An index rather than a pointer on purpose: the list grows, and a `*Attempt`
/// held across the next `append` is a dangling pointer into a freed array.
fn addGitAttempt(
    arena: Allocator,
    list: *std.ArrayList(Attempt),
    url: []const u8,
) Allocator.Error!usize {
    const i = list.items.len;
    try list.append(arena, .{
        .kind = .git,
        // Redacted at the point of record, not at the point of print: this
        // struct is what a caller logs (`git/url.zig`'s header).
        .url = try git.url.redact(arena, url),
        .tried = true,
    });
    return i;
}

// ---------------------------------------------------------------------------
// fixups_from_projectfile!
// ---------------------------------------------------------------------------
//
// This pass exists because extension metadata is NOT resolvable. `weakdeps`,
// `extensions` and `entryfile` live in the package's own `Project.toml`, which
// does not exist until the package is on disk — hence the comment right above
// the function in Pkg: "This has to be done after the packages have been
// downloaded since we need access to the Project file to read the information
// about extensions" (`Operations.jl:250-252`).

pub const FixupOptions = struct {
    /// `dirname(env.manifest_file)`. `path` entries resolve against it
    /// (`source_path`, `Operations.jl:48-53`), then get `abspath`'d
    /// (`:271-273`).
    manifest_dir: []const u8 = ".",
    /// `Types.stdlib_dir()` —
    /// `<prefix>/share/julia/stdlib/v<major>.<minor>`. Only reached by an entry
    /// with neither a tree hash nor a path, which is exactly a current stdlib.
    /// Null leaves those entries untouched.
    stdlib_dir: ?[]const u8 = null,
};

pub const FixupError = error{
    /// `source_path` returned nothing — "could not find source path for
    /// package X based on manifest Y" (`Operations.jl:273-275`), which is a
    /// `pkgerror`, i.e. FATAL, not a skip. An entry with no tree hash, no path
    /// and no stdlib directory of that name has no source at all.
    NoSourcePath,
} || project_mod.Error || Allocator.Error || depot.FindError ||
    Io.Dir.StatFileError || Io.Dir.ReadFileAllocError;

/// Why an entry was left untouched. Reported rather than silent, because
/// "the fixups pass ran and did nothing" and "the fixups pass could not see
/// this package" look identical in the resulting manifest.
pub const Skipped = enum {
    /// Not skipped.
    no,
    /// `locate_project_file` found neither `JuliaProject.toml` nor
    /// `Project.toml` at the source path — Julia's `project_file isa String &&
    /// isfile(project_file)` guard (`Operations.jl:279`) fails and the entry is
    /// left alone. Normal for a package that is not installed.
    no_project_file,
    /// The entry is a stdlib and `FixupOptions.stdlib_dir` was not supplied, so
    /// its source could not be located. Julia cannot reach this state — it
    /// always knows `Sys.STDLIB` — so it is a gap in what the CALLER told this
    /// function, and callers are expected to surface it.
    stdlib_dir_unknown,
};

/// What one entry's fixup did, so a caller can report it and a gate can diff it.
pub const Fixup = struct {
    name: []const u8,
    /// The `Project.toml`/`JuliaProject.toml` that was read, or null when the
    /// entry was skipped — see `skipped` for which of the two reasons.
    project_file: ?[]const u8 = null,
    skipped: Skipped = .no,
    /// Names removed from `entry.deps` by the `:283-285` rule.
    removed_deps: []const []const u8 = &.{},
    changed: bool = false,
};

/// `fixups_from_projectfile!` (`Operations.jl:253-291`), the `else` branch —
/// the one that runs whenever `ctx.julia_version == VERSION`, i.e. always
/// outside historical-stdlib resolution.
///
/// For every manifest entry whose source is on disk, read that package's own
/// `Project.toml` and copy three fields out of it:
///
/// ```julia
/// pkg.weakdeps = p.weakdeps
/// pkg.exts     = p.exts
/// pkg.entryfile = p.entryfile
/// for (name, _) in p.weakdeps
///     if !haskey(p.deps, name)
///         delete!(pkg.deps, name)
///     end
/// end
/// ```
///
/// **The deletion is subtler than it looks**, and it is why this cannot be done
/// from the registry. `Types.read_project` has already moved every name that
/// appears in BOTH `[deps]` and `[weakdeps]` *with the same UUID* out of
/// `p.deps` into `p._deps_weak` (`project.jl:236-238`, and note it splits by
/// PAIR — same name under two different UUIDs stays in both). So
/// `haskey(p.deps, name)` is false for exactly those, and the manifest entry
/// loses them from its `deps`: a package that declares a dependency as weak
/// must not have it recorded as strong in the manifest, or the loader would
/// load the extension's trigger unconditionally.
///
/// Pkg finishes with `prune_manifest(env)`, which is environment-level
/// reachability pruning and not part of this pass; it is left to the caller.
///
/// Arena: `m.entries` is replaced with a fresh arena-allocated slice, and every
/// string copied out of a package's `Project.toml` is duped into `arena` — the
/// parsed project owns its own arena and is freed per entry.
pub fn fixupsFromProjectFile(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    m: *Manifest,
    opts: FixupOptions,
) FixupError![]const Fixup {
    const entries = try arena.alloc(PackageEntry, m.entries.len);
    @memcpy(entries, m.entries);

    const report = try arena.alloc(Fixup, entries.len);
    for (entries, report) |*e, *f| {
        f.* = .{ .name = e.name };

        const source = switch (try sourcePath(arena, io, stack, e, opts)) {
            .path => |p| p,
            .stdlib_dir_unknown => {
                f.skipped = .stdlib_dir_unknown;
                continue;
            },
        };
        const project_file = try locateProjectFile(arena, io, source) orelse {
            f.skipped = .no_project_file;
            continue;
        };
        f.project_file = project_file;

        const src = try Io.Dir.cwd().readFileAlloc(io, project_file, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(src);
        var p = try project_mod.parse(gpa, src, .{ .file = project_file }, null);
        defer p.deinit();

        f.changed = try applyProject(arena, e, &p, f);
    }

    m.entries = entries;
    return report;
}

/// The three assignments plus the deletion. Split out so the ordering is
/// visible in one screen and so a unit test can drive it from a hand-built
/// project.
fn applyProject(
    arena: Allocator,
    e: *PackageEntry,
    p: *const project_mod.Project,
    f: *Fixup,
) (error{InvalidProject} || Allocator.Error)!bool {
    var changed = false;

    // --- pkg.weakdeps = p.weakdeps ----------------------------------------
    const weakdeps = try arena.alloc(manifest_mod.Dep, p.weakdeps.count());
    for (p.weakdeps.entries.items, weakdeps) |src, *dst| {
        dst.* = .{ .name = try arena.dupe(u8, src.name), .uuid = src.uuid };
    }
    if (!depsEql(e.weakdeps, weakdeps)) changed = true;
    e.weakdeps = weakdeps;

    // --- pkg.exts = p.exts ------------------------------------------------
    //
    // Read from the RAW table rather than from `p.exts`. Julia's field is
    // `Dict{String, Union{Vector{String}, String}}` (`Types.jl:291`) and
    // `pkg.exts = p.exts` carries the union through to the manifest verbatim —
    // `AxisKeysExt = "AxisKeys"` stays a string. `project.Extension.triggers`
    // normalises a lone string to a one-element list, which is the right model
    // for asking "what triggers this?" and the wrong one for round-tripping:
    // it would rewrite every scalar in the file as `["X"]`.
    const exts = try readRawExtensions(arena, p);
    if (!extsEql(e.exts, exts)) changed = true;
    e.exts = exts;

    // --- pkg.entryfile = p.entryfile --------------------------------------
    const entryfile = if (p.entryfile) |x| try arena.dupe(u8, x) else null;
    if (!optEql(e.entryfile, entryfile)) changed = true;
    e.entryfile = entryfile;

    // --- delete!(pkg.deps, name) for weak-but-not-strong ------------------
    var kept: std.ArrayList(manifest_mod.Dep) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    for (e.deps) |d| {
        if (p.weakdeps.contains(d.name) and !p.deps.contains(d.name)) {
            try removed.append(arena, d.name);
        } else {
            try kept.append(arena, d);
        }
    }
    if (removed.items.len != 0) {
        e.deps = kept.items;
        f.removed_deps = removed.items;
        changed = true;
    }

    return changed;
}

/// `p.exts` straight off the parsed document, preserving string-vs-list.
/// `project_mod.parse` has already rejected every other shape (`readExtensions`,
/// `project.zig`), so the `else` prong is unreachable via `parse` and exists
/// only to keep a hand-built `Project` from producing a nonsense manifest.
fn readRawExtensions(
    arena: Allocator,
    p: *const project_mod.Project,
) (error{InvalidProject} || Allocator.Error)![]const manifest_mod.Extension {
    const v = p.doc.root.get("extensions") orelse return &.{};
    const t = switch (v) {
        .table => |t| t,
        else => return error.InvalidProject,
    };
    const out = try arena.alloc(manifest_mod.Extension, t.entries.items.len);
    for (t.entries.items, out) |kv, *dst| {
        const targets: manifest_mod.ExtTargets = switch (kv.value) {
            .string => |s| .{ .one = try arena.dupe(u8, s) },
            .array => |items| blk: {
                const many = try arena.alloc([]const u8, items.len);
                for (items, many) |item, *slot| slot.* = switch (item) {
                    .string => |s| try arena.dupe(u8, s),
                    else => return error.InvalidProject,
                };
                break :blk .{ .many = many };
            },
            else => return error.InvalidProject,
        };
        dst.* = .{ .name = try arena.dupe(u8, kv.key), .targets = targets };
    }
    return out;
}

const Source = union(enum) {
    path: []const u8,
    /// The entry is a stdlib but `FixupOptions.stdlib_dir` is null, so where
    /// its source lives is simply not known here.
    stdlib_dir_unknown,
};

/// `source_path(manifest_file, pkg)` (`Operations.jl:48-53`).
///
/// Note the tree-hash branch returns `find_installed`'s *would-be* path when
/// nothing is installed, exactly as Julia does; `locateProjectFile` then finds
/// no project file there and the entry is left alone. That is the normal state
/// for a manifest entry whose package has not been downloaded.
///
/// **The third branch is where Julia fails loudly and it would be easy not
/// to.** `:51` is
/// `is_or_was_stdlib(pkg.uuid, julia_version) ? Types.stdlib_path(pkg.name) : nothing`,
/// and a `nothing` there is a `pkgerror` at the call site (`:273-275`), not a
/// skip. Since `Types.stdlib_path(name)` is literally
/// `joinpath(stdlib_dir(), name)`, "is there a directory of that name under
/// `stdlib_dir`?" IS the predicate — so when `stdlib_dir` is known, an entry
/// with no tree hash, no path and no such directory has no source anywhere and
/// raises `NoSourcePath` exactly as Julia does. Re-deriving `is_or_was_stdlib`
/// from a version table would need the same directory as input and could only
/// disagree with the filesystem it is standing on.
///
/// When `stdlib_dir` is NOT known the two cases cannot be told apart, so this
/// reports `stdlib_dir_unknown` instead of guessing — a state Julia never has,
/// because it always knows `Sys.STDLIB`.
fn sourcePath(
    arena: Allocator,
    io: Io,
    stack: depot.Stack,
    e: *const PackageEntry,
    opts: FixupOptions,
) FixupError!Source {
    if (e.tree_hash) |h| {
        const found = try depot.findInstalled(arena, io, stack, e.name, e.uuid, h);
        return .{ .path = found.path };
    }
    if (e.path) |p| {
        // `normpath(joinpath(dirname(manifest_file), path))`, then `abspath`
        // at the call site (`:271-273`). `fspath.resolve` is both: it collapses
        // `..`/`.` and absolutises a relative result against the process cwd.
        return .{ .path = try fspath.resolve(arena, &.{ opts.manifest_dir, p }) };
    }
    const dir = opts.stdlib_dir orelse return .stdlib_dir_unknown;
    const candidate = try fspath.join(arena, &.{ dir, e.name });
    const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.NoSourcePath,
    };
    if (st.kind != .directory) return error.NoSourcePath;
    return .{ .path = candidate };
}

/// `Base.locate_project_file` (`base/loading.jl:639-647`) followed by Pkg's own
/// `isfile` re-check (`Operations.jl:279`).
///
/// Julia returns `true` — not a path — when neither name is present, and the
/// `isa String` test at the call site turns that into "skip this entry". Null
/// here is that same signal. The name order is `JuliaProject.toml` first,
/// which is what lets a package ship a Pkg-specific project alongside another
/// tool's `Project.toml`.
fn locateProjectFile(arena: Allocator, io: Io, dir: []const u8) FixupError!?[]const u8 {
    for (stdlibs.project_names) |name| {
        const candidate = try fspath.join(arena, &.{ dir, name });
        // `isfile_casesensitive` on a case-insensitive filesystem; a plain
        // stat everywhere Ajt runs. `statFile` follows symlinks, as `isfile`
        // does.
        const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        if (st.kind == .file) return candidate;
    }
    return null;
}

fn depsEql(a: []const manifest_mod.Dep, b: []const manifest_mod.Dep) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!std.mem.eql(u8, &x.uuid.bytes, &y.uuid.bytes)) return false;
    }
    return true;
}

fn extsEql(a: []const manifest_mod.Extension, b: []const manifest_mod.Extension) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        switch (x.targets) {
            .one => |s| switch (y.targets) {
                .one => |t| if (!std.mem.eql(u8, s, t)) return false,
                .many => return false,
            },
            .many => |xs| switch (y.targets) {
                .one => return false,
                .many => |ys| {
                    if (xs.len != ys.len) return false;
                    for (xs, ys) |s, t| if (!std.mem.eql(u8, s, t)) return false;
                },
            },
        }
    }
    return true;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "get_archive_url_for_version, case by case from the real function" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every expectation below was produced by running
    //   Pkg.Operations.get_archive_url_for_version(url, "abc123")
    // on Julia 1.12.6, not by reading the regex.
    const cases = [_]struct { url: []const u8, want: ?[]const u8 }{
        .{
            .url = "https://github.com/JuliaArrays/StaticArrays.jl.git",
            .want = "https://api.github.com/repos/JuliaArrays/StaticArrays.jl/tarball/abc123",
        },
        .{
            .url = "https://github.com/JuliaLang/Example.jl.git",
            .want = "https://api.github.com/repos/JuliaLang/Example.jl/tarball/abc123",
        },
        // No `.git` suffix: `nothing`. Pkg then has no GitHub candidate at all.
        .{ .url = "https://github.com/JuliaArrays/StaticArrays.jl", .want = null },
        // An SSH remote does not match the literal prefix.
        .{ .url = "git@github.com:JuliaArrays/StaticArrays.jl.git", .want = null },
        .{ .url = "https://gitlab.com/foo/bar.jl.git", .want = null },
        // `.git` is `<any>git` and both groups are lazy, so the FIRST such
        // position wins and the rest of the URL is discarded.
        .{
            .url = "https://github.com/a/b.git/extra",
            .want = "https://api.github.com/repos/a/b/tarball/abc123",
        },
        .{
            .url = "https://github.com/O/R.git.git",
            .want = "https://api.github.com/repos/O/R/tarball/abc123",
        },
        // `.` matches `/` too: capture 2 spans the slash. Splitting on `/`
        // would target `Org/Sub.Group`, a different repository.
        .{
            .url = "https://github.com/Org/Sub.Group/Repo.jl.git",
            .want = "https://api.github.com/repos/Org/Sub.Group/Repo.jl/tarball/abc123",
        },
        // `match` is unanchored.
        .{
            .url = "prefix https://github.com/O/R.jl.git suffix",
            .want = "https://api.github.com/repos/O/R.jl/tarball/abc123",
        },
    };

    for (cases) |c| {
        errdefer std.debug.print("url: {s}\n", .{c.url});
        const got = try githubArchiveUrl(arena, c.url, "abc123");
        if (c.want) |w| {
            try testing.expectEqualStrings(w, got.?);
        } else {
            try testing.expect(got == null);
        }
    }
}

const demo_uuid = "90137ffa-7385-5640-81b9-e52037218182";
const demo_tree = "246a8bb2e6667f832eea063c3a56aef96429a3db";

test "candidate order is server first, then one GitHub URL per registry repo" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job: Job = .{
        .name = "Demo",
        .uuid = try Uuid.parse(demo_uuid),
        .tree_hash = try Sha1.parse(demo_tree),
        .repo_urls = &.{
            "https://github.com/One/Demo.jl.git",
            // Not GitHub: contributes nothing, and must not shift the others.
            "https://gitlab.com/two/Demo.jl.git",
            "https://github.com/Three/Demo.jl.git",
        },
    };

    const with_server = try candidates(arena, job, "https://pkg.julialang.org");
    try testing.expectEqual(@as(usize, 3), with_server.len);
    try testing.expectEqualStrings(
        "https://pkg.julialang.org/package/" ++ demo_uuid ++ "/" ++ demo_tree,
        with_server[0].url,
    );
    try testing.expectEqual(extract.Shape.top_level, with_server[0].shape);
    try testing.expectEqualStrings(
        "https://api.github.com/repos/One/Demo.jl/tarball/" ++ demo_tree,
        with_server[1].url,
    );
    try testing.expectEqual(extract.Shape.github_tarball, with_server[1].shape);
    try testing.expectEqualStrings(
        "https://api.github.com/repos/Three/Demo.jl/tarball/" ++ demo_tree,
        with_server[2].url,
    );

    // `JULIA_PKG_SERVER=""` drops the first candidate entirely.
    const no_server = try candidates(arena, job, null);
    try testing.expectEqual(@as(usize, 2), no_server.len);
    try testing.expectEqualStrings(with_server[1].url, no_server[0].url);

    // Not in any registry: the server has nothing to serve either
    // (`haskey(reg, pkg.uuid)`, `Operations.jl:1168`).
    var unregistered = job;
    unregistered.in_registry = false;
    unregistered.repo_urls = &.{};
    try testing.expectEqual(
        @as(usize, 0),
        (try candidates(arena, unregistered, "https://pkg.julialang.org")).len,
    );

    // A hand-supplied server with a trailing slash must not produce `//`.
    const trimmed = try candidates(arena, job, "https://pkg.julialang.org/");
    try testing.expectEqualStrings(with_server[0].url, trimmed[0].url);
}

test "jobsFromManifest keeps registry-tracked and repo-tracked tree hashes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Downloaded]]
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
        \\[[deps.Dev]]
        \\path = "."
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Stdlib]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
        \\[[deps.GitCheckout]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\repo-rev = "main"
        \\repo-subdir = "lib/Sub"
        \\repo-url = "https://github.com/x/y.jl.git"
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
    , null);

    const Fake = struct {
        fn find(_: *anyopaque, a: Allocator, uuid_text: []const u8) Allocator.Error!?[]const []const u8 {
            if (!std.mem.eql(u8, uuid_text, demo_uuid)) return null;
            const urls = try a.alloc([]const u8, 1);
            urls[0] = "https://github.com/JuliaLang/Demo.jl.git";
            return urls;
        }
    };

    const jobs = try jobsFromManifest(arena, &m, .{ .ctx = undefined, .find = Fake.find }, null);
    // The dev'd package (`path`) and the stdlib (no tree hash) are excluded
    // (`Operations.jl:43-46`, `:1115`). The git checkout is NOT: Pkg leaves it
    // out of `download_source` only because `instantiate` cloned it a few
    // lines earlier (`API.jl:1358-1390`), and it still has to reach
    // `packages/<Name>/<slug>`.
    try testing.expectEqual(@as(usize, 2), jobs.len);
    try testing.expectEqualStrings("Downloaded", jobs[0].name);
    try testing.expect(jobs[0].in_registry);
    try testing.expect(jobs[0].repo == null);
    try testing.expectEqual(@as(usize, 1), jobs[0].repo_urls.len);

    try testing.expectEqualStrings("GitCheckout", jobs[1].name);
    try testing.expectEqualStrings("https://github.com/x/y.jl.git", jobs[1].repo.?.url);
    try testing.expectEqualStrings("main", jobs[1].repo.?.rev.?);
    try testing.expectEqualStrings("lib/Sub", jobs[1].repo.?.subdir.?);
    // No archive is ever tried for it, not even the Pkg server's — the entry
    // is not `tracking_registered_version`, so `download_source` builds no URL
    // list for it at all.
    try testing.expectEqual(@as(usize, 0), (try candidates(arena, jobs[1], "https://s")).len);
    // ...and the registry was not consulted: `find_urls` is only reachable
    // from `download_source`, which never sees this entry.
    try testing.expectEqual(@as(usize, 0), jobs[1].repo_urls.len);

    // A URL is left alone whatever `manifest_dir` says: `isurl` is true, so
    // `manifest_rel_path` never runs (`API.jl:1362-1367`).
    const rooted = try jobsFromManifest(arena, &m, .none, "/env/sub");
    try testing.expectEqualStrings("https://github.com/x/y.jl.git", rooted[1].repo.?.url);

    // An unregistered package still becomes a job — Pkg would try a git clone
    // for it — but with no candidates at all.
    const none = try jobsFromManifest(arena, &m, .none, null);
    try testing.expectEqual(@as(usize, 2), none.len);
    try testing.expect(!none[0].in_registry);
    try testing.expectEqual(@as(usize, 0), (try candidates(arena, none[0], "https://s")).len);
}

test "a repo-url that is a local path is resolved against the manifest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `Pkg.add(path = "…")` records the path, not a URL, and `instantiate`
    // rewrites it with `manifest_rel_path` before hashing it into a clone
    // directory name (`API.jl:1362-1376`). Leaving it verbatim would clone
    // relative to the process cwd AND key the cache under a name `Pkg.gc()`
    // does not recompute.
    const m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Local]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\repo-url = "../vendor/Local.jl"
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
    , null);

    const jobs = try jobsFromManifest(arena, &m, .none, "/srv/env");
    try testing.expectEqualStrings("/srv/vendor/Local.jl", jobs[0].repo.?.url);

    // Without a manifest directory there is nothing to resolve against, and
    // guessing would be worse than passing it through.
    const bare = try jobsFromManifest(arena, &m, .none, null);
    try testing.expectEqualStrings("../vendor/Local.jl", bare[0].repo.?.url);
}

/// Builds a gzipped tar of a tiny package, plus its `git-tree-sha1`, the way a
/// Pkg server would serve it.
fn buildPackageTarball(
    gpa: Allocator,
    files: []const struct { name: []const u8, data: []const u8 },
) !struct { gz: []u8, hash: extract.Hash } {
    var tar_out: Io.Writer.Allocating = .init(gpa);
    defer tar_out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    for (files) |f| try tw.writeFileBytes(f.name, f.data, .{ .mode = 0o644 });
    try tw.finishPedantically();

    const hash = try extract.treeHashOfTar(gpa, tar_out.written(), .{});

    var gz_out: Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    errdefer gz_out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var comp = try std.compress.flate.Compress.init(&gz_out.writer, window, .gzip, .default);
    try comp.writer.writeAll(tar_out.written());
    try comp.finish();

    return .{ .gz = try gz_out.toOwnedSlice(), .hash = hash };
}

test "install downloads, verifies and publishes, and is a no-op the second time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    const built = try buildPackageTarball(gpa, &.{
        .{ .name = "Project.toml", .data = "name = \"Demo\"\nuuid = \"" ++ demo_uuid ++ "\"\n" },
        .{ .name = "src/Demo.jl", .data = "module Demo end\n" },
    });
    defer gpa.free(built.gz);

    var srv = try TarballServer.start(io, built.gz);
    defer srv.deinit(io);
    var task = try io.concurrent(TarballServer.serve, .{ io, &srv, @as(usize, 1) });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const stack: depot.Stack = .{ .entries = &.{root} };

    const job: Job = .{
        .name = "Demo",
        .uuid = try Uuid.parse(demo_uuid),
        .tree_hash = .{ .bytes = built.hash },
    };
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    const results = try install(gpa, arena, io, stack, &.{job}, .{ .server = server });
    task.await(io);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(Outcome.installed, results[0].outcome);
    try check(results);
    try testing.expect(results[0].source != null);
    try testing.expectEqual(extract.Shape.top_level, results[0].source.?.shape);

    // It landed at the version slug stock julia looks in, with Pkg's mode rule:
    // files read-only, directories not (`utils.jl:59-63`).
    var slug_buf: [8]u8 = undefined;
    const s = slug.versionSlug(job.uuid, job.tree_hash, &slug_buf);
    const rel = try std.fmt.allocPrint(arena, "packages/Demo/{s}", .{s});
    try testing.expectEqualStrings(
        try fspath.join(arena, &.{ root, rel }),
        results[0].path,
    );
    const entry_file = try std.fmt.allocPrint(arena, "{s}/src/Demo.jl", .{rel});
    try testing.expect((try tmp.dir.statFile(io, entry_file, .{})).permissions.readOnly());
    try testing.expect(!(try tmp.dir.statFile(io, rel, .{})).permissions.readOnly());
    const body = try tmp.dir.readFileAlloc(io, entry_file, arena, .limited(256));
    try testing.expectEqualStrings("module Demo end\n", body);

    // Second run: `ispath(path)` short-circuits before any network call, which
    // is why no second response is scripted.
    const again = try install(gpa, arena, io, stack, &.{job}, .{ .server = server });
    try testing.expectEqual(Outcome.already_present, again[0].outcome);
    try testing.expectEqual(@as(usize, 0), again[0].attempts.len);
    try check(again);
}

test "a tarball that does not match its pin writes nothing and falls through" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    const built = try buildPackageTarball(gpa, &.{
        .{ .name = "src/Demo.jl", .data = "module Demo end\n" },
    });
    defer gpa.free(built.gz);

    var srv = try TarballServer.start(io, built.gz);
    defer srv.deinit(io);
    var task = try io.concurrent(TarballServer.serve, .{ io, &srv, @as(usize, 1) });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // Ask for a DIFFERENT tree than the server serves.
    const job: Job = .{
        .name = "Demo",
        .uuid = try Uuid.parse(demo_uuid),
        .tree_hash = try Sha1.parse(demo_tree),
    };
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    const results = try install(gpa, arena, io, .{ .entries = &.{root} }, &.{job}, .{ .server = server });
    task.await(io);

    // No archive worked, so Pkg would clone. `check` says so rather than
    // reporting a silent success.
    try testing.expectEqual(Outcome.needs_git_clone, results[0].outcome);
    try testing.expectError(error.GitCloneRequired, check(results));
    try testing.expectEqual(@as(usize, 1), results[0].attempts.len);
    try testing.expectEqual(@as(?anyerror, error.TreeHashMismatch), results[0].attempts[0].err);
    // The hash it actually had, which Pkg discards.
    const computed = results[0].attempts[0].computed.?;
    try testing.expectEqualStrings(&treehash.toHex(built.hash), &computed);

    // And nothing was published: no tree at the version slug, and no staging
    // leftover beside it. `packages/Demo/` itself DOES survive — `depot.begin`
    // creates the parent chain and deliberately does not remove it on abort,
    // because that would race a concurrent installer holding it open. Pkg
    // leaves the same empty directory (`Operations.jl:820`).
    var pkg_dir = try tmp.dir.openDir(io, "packages/Demo", .{ .iterate = true });
    defer pkg_dir.close(io);
    var it = pkg_dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "the server 404 falls through to the GitHub candidate" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    // The GitHub shape: one generated wrapper directory around the tree.
    const inner = try buildPackageTarball(gpa, &.{
        .{ .name = "src/Demo.jl", .data = "module Demo end\n" },
    });
    defer gpa.free(inner.gz);
    const wrapped = try buildPackageTarball(gpa, &.{
        .{ .name = "JuliaLang-Demo.jl-abc1234/src/Demo.jl", .data = "module Demo end\n" },
    });
    defer gpa.free(wrapped.gz);

    var srv = try TarballServer.start(io, wrapped.gz);
    // The first request (the Pkg server candidate) 404s; the second (GitHub)
    // serves the wrapped tarball.
    srv.first_status_404 = true;
    defer srv.deinit(io);
    var task = try io.concurrent(TarballServer.serve, .{ io, &srv, @as(usize, 2) });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    const job: Job = .{
        .name = "Demo",
        .uuid = try Uuid.parse(demo_uuid),
        .tree_hash = .{ .bytes = inner.hash },
    };
    // Point the "GitHub" candidate at the same loopback server: only the host
    // differs from what `githubArchiveUrl` would build. Driving the list
    // directly is what keeps a unit test off api.github.com.
    const cands = try arena.alloc(Candidate, 2);
    cands[0] = (try candidates(arena, job, server))[0];
    cands[1] = .{
        .url = try std.fmt.allocPrint(arena, "{s}/tarball", .{server}),
        .shape = .github_tarball,
    };

    const results = try installWithCandidates(gpa, arena, io, .{ .entries = &.{root} }, &.{job}, &.{cands}, .{});
    task.await(io);

    try testing.expectEqual(Outcome.installed, results[0].outcome);
    try testing.expectEqual(extract.Shape.github_tarball, results[0].source.?.shape);
    try testing.expectEqual(@as(?anyerror, error.HttpRequestFailed), results[0].attempts[0].err);
    try testing.expectEqual(std.http.Status.not_found, results[0].attempts[0].status.?);
    // The wrapper directory did not survive.
    var slug_buf: [8]u8 = undefined;
    const s = slug.versionSlug(job.uuid, job.tree_hash, &slug_buf);
    const rel = try std.fmt.allocPrint(arena, "packages/Demo/{s}/src/Demo.jl", .{s});
    _ = try tmp.dir.statFile(io, rel, .{});
}

/// A loopback HTTP server that answers every request with one tarball.
///
/// The download path has no Julia oracle — Pkg delegates it to libcurl and to
/// an external `tar` — so it gets a real socket instead: that is the only way
/// to observe the fallthrough from a 404 to the next candidate, and to prove
/// that a mismatching tarball leaves the depot untouched.
const TarballServer = struct {
    server: Io.net.Server,
    port: u16,
    body: []const u8,
    first_status_404: bool = false,
    served: usize = 0,

    // 42871, not 40871: `registry_ops.zig`'s ScriptedServer owns 40871-41370
    // and the two used to be identical. Each has its own `next_offset`, so two
    // servers alive in one process could pick the same port — silently, until
    // the binds became exclusive (see `net/http.zig`'s note), and wastefully
    // even now. The five ranges are disjoint with a 500-port gap between them:
    // http 39871+1000, registry_ops 40871+500, install_artifacts 41871+500,
    // install_packages 42871+500, cache/store 43871+500.
    const port_base = 42871;
    const port_span = 500;
    var next_offset: std.atomic.Value(u16) = .init(0);

    fn start(io: Io, body: []const u8) !TarballServer {
        const first = next_offset.fetchAdd(1, .monotonic);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // An EXCLUSIVE bind: `reuse_address` would set SO_REUSEPORT, under
            // which a second `listen` on a live port succeeds and the kernel
            // load-balances connections between the two servers. See the long
            // note on `LoopbackServer.start` in `src/net/http.zig`.
            const srv = addr.listen(io, .{}) catch continue;
            return .{ .server = srv, .port = port, .body = body };
        }
        return error.NoFreePort;
    }

    fn deinit(self: *TarballServer, io: Io) void {
        self.server.deinit(io);
    }

    /// Serves exactly `count` requests, one per connection, then returns. Every
    /// response says `Connection: close`, or the client keeps the connection
    /// pooled and this loop deadlocks in `accept` instead of failing.
    fn serve(io: Io, self: *TarballServer, count: usize) void {
        for (0..count) |_| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            while (true) {
                const line = sr.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }

            const n = self.served;
            self.served += 1;

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            if (n == 0 and self.first_status_404) {
                sw.interface.writeAll(
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                ) catch {};
            } else {
                sw.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{self.body.len},
                ) catch {};
                sw.interface.writeAll(self.body) catch {};
            }
            sw.interface.flush() catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// The git pass, against a real repository.
//
// Skipped rather than failed without `git`: every other test in this file is
// still meaningful on a machine that has none.
// ---------------------------------------------------------------------------

const git_cli = @import("../git/cli.zig");

/// A `git` invocation that builds the fixture, with a deterministic identity
/// and no signing. Mirrors `git/cli.zig`'s own helper rather than sharing it,
/// because a test helper exported from a library module is a public API nobody
/// asked for.
fn fixtureGit(gpa: Allocator, io: Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HOME", cwd);
    try environ.put("GIT_CONFIG_NOSYSTEM", "1");
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    try environ.put("GIT_AUTHOR_NAME", "ajt");
    try environ.put("GIT_AUTHOR_EMAIL", "ajt@example.invalid");
    try environ.put("GIT_COMMITTER_NAME", "ajt");
    try environ.put("GIT_COMMITTER_EMAIL", "ajt@example.invalid");
    try environ.put("GIT_AUTHOR_DATE", "2000-01-01T00:00:00+0000");
    try environ.put("GIT_COMMITTER_DATE", "2000-01-01T00:00:00+0000");

    // No PATH: `std.process.run` resolves argv[0] through the PARENT
    // environment regardless of `environ_map`.
    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("fixture `git {s}` failed ({d}): {s}\n", .{ args[0], c, res.stderr });
            return error.FixtureFailed;
        },
        else => return error.FixtureFailed,
    }
}

test "a package with no archive is cloned, re-hashed and published" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (!git_cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // --- a package that only exists as a git repository --------------------
    const src = try fspath.join(arena, &.{ root, "src" });
    try tmp.dir.createDirPath(io, "src/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/Project.toml",
        .data = "name = \"Demo\"\nuuid = \"" ++ demo_uuid ++ "\"\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/src/Demo.jl", .data = "module Demo end\n" });
    try fixtureGit(gpa, io, src, &.{ "init", "--quiet", "--initial-branch=main" });
    try fixtureGit(gpa, io, src, &.{ "add", "-A" });
    try fixtureGit(gpa, io, src, &.{ "commit", "--quiet", "-m", "initial" });

    // The pin, taken from the working tree with Ajt's own hasher — the same
    // number `git rev-parse HEAD^{tree}` would print, and the same one a
    // manifest carries.
    const tree = git.TreeId{ .bytes = try treehash.hashPath(gpa, io, src) };
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{src});

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    var cli: git_cli.Cli = .{ .environ = &environ };

    const stack: depot.Stack = .{ .entries = &.{root} };
    const uuid = try Uuid.parse(demo_uuid);
    var slug_buf: [8]u8 = undefined;
    const s = slug.versionSlug(uuid, tree, &slug_buf);

    // --- 1. a repo-url manifest entry --------------------------------------
    // No archive candidate is even built for it, so this exercises the pass in
    // isolation: the ONLY way the package can land is the clone.
    const repo_job: Job = .{
        .name = "Demo",
        .uuid = uuid,
        .tree_hash = tree,
        .in_registry = false,
        .repo = .{ .url = remote, .rev = "main" },
    };
    const opts: Options = .{ .git = cli.backend(), .commit = .{ .set_readonly = true } };
    const rep = try install(gpa, arena, io, stack, &.{repo_job}, opts);
    try check(rep);
    try testing.expectEqual(Outcome.installed_git, rep[0].outcome);
    // No archive was tried: every attempt is a git one.
    for (rep[0].attempts) |at| try testing.expectEqual(Attempt.Kind.git, at.kind);

    // It landed at the version slug stock julia looks in...
    const rel = try std.fmt.allocPrint(arena, "packages/Demo/{s}", .{s});
    try testing.expectEqualStrings(try fspath.join(arena, &.{ root, rel }), rep[0].path);
    const entry_file = try std.fmt.allocPrint(arena, "{s}/src/Demo.jl", .{rel});
    try testing.expectEqualStrings(
        "module Demo end\n",
        try tmp.dir.readFileAlloc(io, entry_file, arena, .limited(256)),
    );
    // ...with `set_readonly`'s mode rule, exactly as the archive path leaves
    // it (`Operations.jl:1235`).
    try testing.expect((try tmp.dir.statFile(io, entry_file, .{})).permissions.readOnly());
    try testing.expect(!(try tmp.dir.statFile(io, rel, .{})).permissions.readOnly());
    // ...and no staging directory survived.
    var pkg_dir = try tmp.dir.openDir(io, "packages/Demo", .{ .iterate = true });
    defer pkg_dir.close(io);
    var it = pkg_dir.iterate();
    var seen: usize = 0;
    while (try it.next(io)) |_| seen += 1;
    try testing.expectEqual(@as(usize, 1), seen);

    // The clone is keyed by URL — `add_repo_cache_path` (`Types.jl:901`), the
    // name `Pkg.gc()` recomputes. Under any other name it would be deleted the
    // next time somebody runs it.
    const write = stack.writeDepot().?;
    _ = try Io.Dir.cwd().statFile(io, try write.cloneUrlDir(arena, remote), .{});

    // A second run never reaches git at all: the path exists.
    const again = try install(gpa, arena, io, stack, &.{repo_job}, opts);
    try testing.expectEqual(Outcome.already_present, again[0].outcome);
    try testing.expectEqual(@as(usize, 0), again[0].attempts.len);

    // --- 2. the archive fallback, into a second depot -----------------------
    // A registry-tracked job whose candidate list is empty (no server, and the
    // repo URL is not GitHub so `get_archive_url_for_version` yields nothing).
    // That is `install_git`'s own entry condition, and its clone is keyed by
    // UUID (`Operations.jl:842-844`), not by URL.
    try tmp.dir.createDirPath(io, "depot2");
    const root2 = try fspath.join(arena, &.{ root, "depot2" });
    const stack2: depot.Stack = .{ .entries = &.{root2} };
    const archive_job: Job = .{
        .name = "Demo",
        .uuid = uuid,
        .tree_hash = tree,
        .repo_urls = try arena.dupe([]const u8, &.{remote}),
    };
    try testing.expectEqual(@as(usize, 0), (try candidates(arena, archive_job, null)).len);

    const rep2 = try install(gpa, arena, io, stack2, &.{archive_job}, opts);
    try check(rep2);
    try testing.expectEqual(Outcome.installed_git, rep2[0].outcome);
    _ = try Io.Dir.cwd().statFile(io, try (depot.Depot{ .root = root2 }).cloneUuidDir(arena, uuid), .{});
    _ = try Io.Dir.cwd().statFile(io, try fspath.join(arena, &.{ root2, rel, "src", "Demo.jl" }), .{});

    // --- 3. without a backend, nothing clones -------------------------------
    // The pre-existing contract: `check` says a clone is required rather than
    // reporting a silent success.
    try tmp.dir.createDirPath(io, "depot3");
    const stack3: depot.Stack = .{ .entries = &.{try fspath.join(arena, &.{ root, "depot3" })} };
    const rep3 = try install(gpa, arena, io, stack3, &.{repo_job}, .{});
    try testing.expectEqual(Outcome.needs_git_clone, rep3[0].outcome);
    try testing.expectError(error.GitCloneRequired, check(rep3));

    // --- 4. a tree hash the repository does not have ------------------------
    // Every refspec is fetched and the object still is not there: Pkg's
    // "git object … could not be found" (`Operations.jl:862`). It must NOT
    // stay `needs_git_clone` — the clone happened and did not help.
    const missing_job: Job = .{
        .name = "Demo",
        .uuid = uuid,
        .tree_hash = try Sha1.parse("0" ** 40),
        .in_registry = false,
        .repo = .{ .url = remote },
    };
    const rep4 = try install(gpa, arena, io, stack3, &.{missing_job}, opts);
    try testing.expectEqual(Outcome.failed, rep4[0].outcome);
    try testing.expectError(error.InstallFailed, check(rep4));
    const last = rep4[0].attempts[rep4[0].attempts.len - 1];
    try testing.expectEqual(@as(?anyerror, error.ObjectNotFound), last.err);
    // Both refspecs were tried, in Pkg's order (`Types.jl:1004-1006`).
    try testing.expectEqualStrings(git.refspecs_heads, rep4[0].attempts[1].refspec.?);
    try testing.expectEqualStrings(git.refspecs_all, rep4[0].attempts[2].refspec.?);
    // And nothing was published at the slug it would have gone to.
    var bad_slug_buf: [8]u8 = undefined;
    const bad_rel = try std.fmt.allocPrint(arena, "depot3/packages/Demo/{s}", .{
        slug.versionSlug(uuid, missing_job.tree_hash, &bad_slug_buf),
    });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, bad_rel, .{}));
}

test "a .gitattributes that would rewrite the checkout does not change the tree" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (!git_cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // A `.gitattributes` that rewrites line endings on checkout is the exact
    // shape `git.zig`'s header warns about: Pkg's `checkout_tree_to_path`
    // would write `\r\n` and name the directory after a hash the content does
    // not have. `cli.zig` suppresses it and the re-hash below is what proves
    // the suppression held — this test fails loudly if a backend ever stops
    // honouring it, instead of installing a mis-named tree.
    const src = try fspath.join(arena, &.{ root, "src" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitattributes", .data = "* text eol=crlf\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "one\ntwo\n" });
    try fixtureGit(gpa, io, src, &.{ "init", "--quiet", "--initial-branch=main" });
    try fixtureGit(gpa, io, src, &.{ "add", "-A" });
    try fixtureGit(gpa, io, src, &.{ "commit", "--quiet", "-m", "initial" });

    const tree = git.TreeId{ .bytes = try treehash.hashPath(gpa, io, src) };
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{src});

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli: git_cli.Cli = .{ .environ = &environ };

    const uuid = try Uuid.parse(demo_uuid);
    const job: Job = .{
        .name = "Demo",
        .uuid = uuid,
        .tree_hash = tree,
        .in_registry = false,
        .repo = .{ .url = remote },
    };
    const rep = try install(gpa, arena, io, .{ .entries = &.{root} }, &.{job}, .{ .git = cli.backend() });
    try check(rep);
    try testing.expectEqual(Outcome.installed_git, rep[0].outcome);

    var slug_buf: [8]u8 = undefined;
    const file = try std.fmt.allocPrint(arena, "packages/Demo/{s}/a.txt", .{
        slug.versionSlug(uuid, tree, &slug_buf),
    });
    try testing.expectEqualStrings(
        "one\ntwo\n",
        try tmp.dir.readFileAlloc(io, file, arena, .limited(64)),
    );
}

/// A backend that reports success and writes something that is NOT the tree it
/// was asked for.
///
/// Every real backend is built not to do this — `cli.zig` disables the export
/// filters, the libgit2 one writes raw blobs — which is exactly why the branch
/// that catches it cannot be reached with a real one. It has to be reachable:
/// it is the check Pkg does not make (`checkout_tree_to_path` never
/// re-verifies, `GitTools.jl:83-91`), and without it a mis-materialised tree is
/// published under a slug named for a hash its contents do not have.
const LyingBackend = struct {
    const vtable: git.Backend.VTable = .{
        .ensureClone = ensureClone,
        .fetch = fetch,
        .resolveRev = resolveRev,
        .treeOf = treeOf,
        .hasObject = hasObject,
        // The seven operations this fake does not model. It exists to exercise
        // ONE branch — a materialise that lies about what it wrote — so every
        // repository operation outside the install path is `Unsupported`
        // rather than a second fake nobody reads.
        .cloneWorking = unsupportedClone,
        .isDirty = unsupportedBool,
        .headBranch = unsupportedOptStr,
        .remoteUrl = unsupportedRemoteUrl,
        .fastForward = unsupportedBranchBool,
        .rebase = unsupportedRebase,
        .defaultRev = unsupportedStr,
        .materialise = materialise,
    };

    var instance: u8 = 0;

    fn backend() git.Backend {
        return .{ .ctx = @ptrCast(&instance), .vtable = &vtable, .which = .cli };
    }

    fn ensureClone(_: *anyopaque, _: Allocator, io: Io, path: []const u8, _: []const u8, _: git.CloneOptions) git.Error!void {
        Io.Dir.cwd().createDirPath(io, path) catch return error.CloneFailed;
    }
    fn fetch(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: []const u8) git.Error!void {}
    fn unsupportedClone(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git.Error!void {
        return error.Unsupported;
    }
    fn unsupportedBool(_: *anyopaque, _: Allocator, _: Io, _: []const u8) git.Error!bool {
        return error.Unsupported;
    }
    fn unsupportedOptStr(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8) git.Error!?[]const u8 {
        return error.Unsupported;
    }
    fn unsupportedRemoteUrl(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8, _: []const u8) git.Error!?[]const u8 {
        return error.Unsupported;
    }
    fn unsupportedBranchBool(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git.Error!bool {
        return error.Unsupported;
    }
    fn unsupportedRebase(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git.Error!void {
        return error.Unsupported;
    }
    fn unsupportedStr(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8) git.Error![]const u8 {
        return error.Unsupported;
    }
    fn resolveRev(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) git.Error!?git.Rev {
        return null;
    }
    fn treeOf(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: ?[]const u8) git.Error!git.TreeId {
        return error.Unsupported;
    }
    /// "Yes, I have it" — so the fetch loop stops at once and the failure below
    /// is unambiguously the re-hash.
    fn hasObject(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: git.Sha1) git.Error!bool {
        return true;
    }
    fn materialise(_: *anyopaque, _: Allocator, io: Io, _: []const u8, _: git.TreeId, dest: []const u8) git.Error!void {
        var dir = Io.Dir.cwd().openDir(io, dest, .{}) catch return error.CloneFailed;
        defer dir.close(io);
        dir.writeFile(io, .{ .sub_path = "wrong.txt", .data = "not the tree that was asked for\n" }) catch
            return error.CloneFailed;
    }
};

test "a materialised tree that does not hash to the pin is refused, not published" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const uuid = try Uuid.parse(demo_uuid);
    const job: Job = .{
        .name = "Demo",
        .uuid = uuid,
        .tree_hash = try Sha1.parse(demo_tree),
        .in_registry = false,
        .repo = .{ .url = "https://example.invalid/Demo.jl.git" },
    };

    const rep = try install(gpa, arena, io, .{ .entries = &.{root} }, &.{job}, .{
        .git = LyingBackend.backend(),
    });

    // `.failed`, not `needs_git_clone`: the clone happened and did not produce
    // the tree, so there is nothing left to try.
    try testing.expectEqual(Outcome.failed, rep[0].outcome);
    try testing.expectError(error.InstallFailed, check(rep));

    const last = rep[0].attempts[rep[0].attempts.len - 1];
    try testing.expectEqual(@as(?anyerror, error.TreeHashMismatch), last.err);
    // The hash it actually had, which Pkg's git path never even computes.
    try testing.expect(last.computed != null);
    try testing.expect(!std.mem.eql(u8, &last.computed.?, demo_tree));

    // And NOTHING was published: no tree at the slug, and no staging leftover
    // beside it. `packages/Demo/` itself survives — `depot.begin` creates the
    // parent chain and deliberately does not remove it on abort.
    var slug_buf: [8]u8 = undefined;
    const rel = try std.fmt.allocPrint(arena, "packages/Demo/{s}", .{
        slug.versionSlug(uuid, job.tree_hash, &slug_buf),
    });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, rel, .{}));
    var pkg_dir = try tmp.dir.openDir(io, "packages/Demo", .{ .iterate = true });
    defer pkg_dir.close(io);
    var it = pkg_dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "fixups copies weakdeps, extensions and entryfile, and drops weak-only deps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const uuid = try Uuid.parse(demo_uuid);
    const tree = try Sha1.parse(demo_tree);
    var slug_buf: [8]u8 = undefined;
    const dir = try std.fmt.allocPrint(arena, "packages/Demo/{s}", .{
        slug.versionSlug(uuid, tree, &slug_buf),
    });
    try tmp.dir.createDirPath(io, dir);
    // `Weak` is in BOTH [deps] and [weakdeps] with the same UUID, so
    // `read_project` moves it out of `deps` (`project.jl:236-238`) and the
    // manifest entry must then lose it (`Operations.jl:283-285`). `Strong`
    // stays. Note `OneExt` is a bare string and `TwoExt` a list: the manifest
    // has to preserve the difference.
    try tmp.dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/Project.toml", .{dir}),
        .data =
        \\name = "Demo"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\entryfile = "src/Other.jl"
        \\
        \\[deps]
        \\Strong = "44444444-4444-4444-4444-444444444444"
        \\Weak = "55555555-5555-5555-5555-555555555555"
        \\
        \\[weakdeps]
        \\Weak = "55555555-5555-5555-5555-555555555555"
        \\Absent = "66666666-6666-6666-6666-666666666666"
        \\
        \\[extensions]
        \\OneExt = "Weak"
        \\TwoExt = ["Weak", "Absent"]
        \\
        ,
    });

    // `Strong` and `Weak` have to be entries in their own right: a strong dep
    // pointing at a UUID with no entry is what `validate_manifest` rejects
    // (`manifest.jl:166-171`). `Absent` is only ever a WEAK dep, and weak deps
    // are exempt — a package need not be installed to trigger an extension.
    var m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Demo]]
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
        \\    [deps.Demo.deps]
        \\    Strong = "44444444-4444-4444-4444-444444444444"
        \\    Weak = "55555555-5555-5555-5555-555555555555"
        \\
        \\[[deps.NotInstalled]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\uuid = "77777777-7777-7777-7777-777777777777"
        \\
        \\[[deps.Strong]]
        \\uuid = "44444444-4444-4444-4444-444444444444"
        \\
        \\[[deps.Weak]]
        \\uuid = "55555555-5555-5555-5555-555555555555"
        \\
    , null);

    const report = try fixupsFromProjectFile(gpa, arena, io, .{ .entries = &.{root} }, &m, .{});
    try testing.expectEqual(@as(usize, 4), report.len);
    try testing.expect(report[0].changed);
    try testing.expectEqual(@as(usize, 1), report[0].removed_deps.len);
    try testing.expectEqualStrings("Weak", report[0].removed_deps[0]);
    // Nothing is installed at that path, so `locate_project_file` finds no
    // file and the entry is left exactly as it was.
    try testing.expect(report[1].project_file == null);
    try testing.expect(!report[1].changed);

    const demo = m.findByName("Demo").?;
    try testing.expectEqual(@as(usize, 1), demo.deps.len);
    try testing.expectEqualStrings("Strong", demo.deps[0].name);
    try testing.expectEqual(@as(usize, 2), demo.weakdeps.len);
    try testing.expectEqualStrings("src/Other.jl", demo.entryfile.?);
    try testing.expectEqual(@as(usize, 2), demo.exts.len);
    try testing.expect(demo.exts[0].targets == .one);
    try testing.expect(demo.exts[1].targets == .many);

    // ...and it round-trips through the writer in the manifest's own encoding:
    // `deps` is down to the array form with `Weak` gone, `weakdeps` degrades to
    // the table form because `Absent` is not an entry, and `OneExt` stays a
    // bare string rather than becoming `["Weak"]`.
    const raw = try m.destructure(arena);
    const out = try @import("../toml/emit.zig").emitAlloc(gpa, raw, .{ .sorted = true });
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Demo]]
        \\deps = ["Strong"]
        \\entryfile = "src/Other.jl"
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
        \\    [deps.Demo.extensions]
        \\    OneExt = "Weak"
        \\    TwoExt = ["Weak", "Absent"]
        \\
        \\    [deps.Demo.weakdeps]
        \\    Absent = "66666666-6666-6666-6666-666666666666"
        \\    Weak = "55555555-5555-5555-5555-555555555555"
        \\
        \\[[deps.NotInstalled]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\uuid = "77777777-7777-7777-7777-777777777777"
        \\
        \\[[deps.Strong]]
        \\uuid = "44444444-4444-4444-4444-444444444444"
        \\
        \\[[deps.Weak]]
        \\uuid = "55555555-5555-5555-5555-555555555555"
        \\
    , out);
}

test "fixups leaves a strong dep alone when the project keeps it in [deps]" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const uuid = try Uuid.parse(demo_uuid);
    const tree = try Sha1.parse(demo_tree);
    var slug_buf: [8]u8 = undefined;
    const dir = try std.fmt.allocPrint(arena, "packages/Demo/{s}", .{
        slug.versionSlug(uuid, tree, &slug_buf),
    });
    try tmp.dir.createDirPath(io, dir);
    // The split is by PAIR (`project.jl:237`): `Same` under two DIFFERENT
    // UUIDs stays in `deps`, so `haskey(p.deps, "Same")` holds and the
    // manifest entry keeps it. A by-name split would delete it.
    try tmp.dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/JuliaProject.toml", .{dir}),
        .data =
        \\name = "Demo"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
        \\[deps]
        \\Same = "44444444-4444-4444-4444-444444444444"
        \\
        \\[weakdeps]
        \\Same = "55555555-5555-5555-5555-555555555555"
        \\
        ,
    });

    var m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Demo]]
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
        \\    [deps.Demo.deps]
        \\    Same = "44444444-4444-4444-4444-444444444444"
        \\
        \\[[deps.Same]]
        \\uuid = "44444444-4444-4444-4444-444444444444"
        \\
    , null);

    const report = try fixupsFromProjectFile(gpa, arena, io, .{ .entries = &.{root} }, &m, .{});
    // `JuliaProject.toml` wins over `Project.toml` and is what got read.
    try testing.expect(std.mem.endsWith(u8, report[0].project_file.?, "JuliaProject.toml"));
    try testing.expectEqual(@as(usize, 0), report[0].removed_deps.len);
    try testing.expectEqual(@as(usize, 1), m.findByName("Demo").?.deps.len);
}

test "an entry with no source at all is fatal, not skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // Neither a tree hash nor a path: the shape a stdlib entry has.
    var m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dates]]
        \\uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        \\
    , null);

    // With no stdlib directory the two cases are indistinguishable, so the
    // entry is skipped — but REPORTED, not silently passed over.
    const unknown = try fixupsFromProjectFile(gpa, arena, io, .{ .entries = &.{root} }, &m, .{});
    try testing.expectEqual(Skipped.stdlib_dir_unknown, unknown[0].skipped);

    // With one supplied, `Types.stdlib_path` resolves and the directory is
    // there: an ordinary fixup that finds no project file.
    try tmp.dir.createDirPath(io, "stdlib/Dates");
    const stdlib = try fspath.join(arena, &.{ root, "stdlib" });
    const found = try fixupsFromProjectFile(gpa, arena, io, .{ .entries = &.{root} }, &m, .{
        .stdlib_dir = stdlib,
    });
    try testing.expectEqual(Skipped.no_project_file, found[0].skipped);

    // ...and with the directory absent, the entry has no source anywhere.
    // Julia `pkgerror`s here (`Operations.jl:273-275`); swallowing it would
    // mean a manifest that silently keeps stale extension metadata.
    const empty = try fspath.join(arena, &.{ root, "no-stdlib-here" });
    try testing.expectError(error.NoSourcePath, fixupsFromProjectFile(
        gpa,
        arena,
        io,
        .{ .entries = &.{root} },
        &m,
        .{ .stdlib_dir = empty },
    ));
}

test "fixups resolves a dev'd package against the manifest directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // `path = "sub"` is relative to `dirname(manifest_file)`, not to cwd
    // (`Operations.jl:49`).
    try tmp.dir.createDirPath(io, "env/sub");
    try tmp.dir.writeFile(io, .{
        .sub_path = "env/sub/Project.toml",
        .data =
        \\name = "Dev"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\entryfile = "src/Elsewhere.jl"
        \\
        ,
    });

    var m = try manifest_mod.parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dev]]
        \\path = "sub"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\
    , null);

    const report = try fixupsFromProjectFile(gpa, arena, io, .{ .entries = &.{root} }, &m, .{
        .manifest_dir = try fspath.join(arena, &.{ root, "env" }),
    });
    try testing.expect(report[0].project_file != null);
    try testing.expectEqualStrings("src/Elsewhere.jl", m.findByName("Dev").?.entryfile.?);
}
