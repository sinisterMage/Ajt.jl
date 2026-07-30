//! Artifact install: pick the sources, verify TWICE, publish atomically.
//!
//! Port of the download half of `Pkg/src/Artifacts.jl`
//! (`try_artifact_download_sources` `:471-533`, `download_artifact`
//! `:324-416`) plus `Operations.download_artifacts`' job collection
//! (`Operations.jl:918-1081`). By bytes this is most of an instantiate: the
//! Open-Reality environment is 98 JLLs and ~516 MB of artifacts, against
//! ~10 MB of package source.
//!
//! A bare `:NNN` citation below is `Pkg/src/Artifacts.jl`; every other file is
//! named. Note the two same-named files: `Pkg/src/Artifacts.jl` is the
//! download/install half ported here, `Artifacts/src/Artifacts.jl` is the Base
//! stdlib that reads the TOML and resolves paths (ported in
//! `install/artifacts.zig`).
//!
//! `install/artifacts.zig` already decides WHAT to install and is gated
//! against `Pkg.Artifacts.artifact_meta` over the whole depot corpus. This
//! module is the DOING half, and everything interesting about it is an
//! ordering rule.
//!
//! ## The two verifications are independent, and neither implies the other
//!
//! A downloaded tarball is checked twice:
//!
//!   * **sha256 of the compressed bytes**, from the `[[X.download]]` entry
//!     (`Artifacts.jl:508-509` reads it, `PlatformEngines.jl:645-668` checks
//!     it). This pins what the mirror served.
//!   * **the git tree hash of the extracted content** against the entry's
//!     `git-tree-sha1` (`Artifacts.jl:359-362`). This pins what lands on disk.
//!
//! It is tempting to treat one as implying the other. It does not, in either
//! direction:
//!
//!   * The Pkg-server source carries **no sha256 at all** — `:488` calls
//!     `download_artifact(hash, url)` with no tarball hash — so for that
//!     source the tree hash is the only check there is.
//!   * A `[[download]]` mirror can serve a tarball whose sha256 matches the
//!     entry while its CONTENT is not the pinned tree: gzip is not canonical,
//!     the same tree recompressed has a different sha256, and conversely an
//!     entry whose sha256 was updated for a re-uploaded tarball but whose
//!     `git-tree-sha1` was not is a real registry mistake, not a hypothetical.
//!
//! So both run, always, and neither `PlanOptions` nor `InstallOptions` has a
//! switch to skip one.
//!
//! **Order matters too.** sha256 is checked BEFORE decompression, as Julia
//! does it (`download_verify` runs on the tarball file, `unpack` only
//! afterwards, `PlatformEngines.jl:523-548`): it is the one check that can be
//! made without feeding unverified bytes to a decompressor, so making it first
//! keeps a zip bomb from a compromised mirror out of `gunzip` entirely.
//!
//! ## Nothing unverified reaches the filesystem
//!
//! Pkg unpacks into a temp directory and hashes the RESULT
//! (`Artifacts.jl:354-359`), so between "download finished" and "hash checked"
//! unverified bytes exist as real files. Ajt hashes from the stream and writes
//! only on a match — that is `install/extract.zig`'s whole contract, and this
//! module is its first real consumer. The staging directory is created before
//! extraction (as Julia's `mktempdir(artifacts_dir)` is) but stays empty on a
//! rejection and is deleted on the way out, so a rejected artifact leaves
//! nothing IN `artifacts/`. Two things it does not promise, both of them
//! `depot.zig`'s documented behaviour rather than an oversight: `begin`
//! creates the parent chain and that survives an abandoned install
//! (`depot.zig:690-693` — removing it would race a concurrent installer), so
//! a cold depot is left holding an empty `artifacts/`; and a failure AFTER the
//! rename means the content is already published and only the permission pass
//! failed (`depot.zig:573-576`).
//!
//! ## Traps, each of which changes what gets installed
//!
//!  1. **The Pkg server is tried FIRST and unconditionally** (`:483-484`),
//!     before any `[[X.download]]` URL, even when the artifact lists mirrors
//!     and even when the server has never heard of it (Pkg's own TODO at
//!     `:482` says as much). `$server/artifact/<hex tree hash>` is addressed by
//!     the very hash being verified, so it needs no sha256. Reordering these
//!     works — until a mirror is down.
//!  2. **The install destination is not `artifact_path`.** Julia writes to
//!     `first(artifacts_dirs())/<hex>` (`:338-341`), i.e. the FIRST depot,
//!     with overrides ignored. Overrides decide only whether the artifact
//!     counts as already present (`artifact_exists` honours them by default,
//!     `Artifacts/src/Artifacts.jl:270`, and `download_artifact` returns early
//!     on it at `:333`). Installing to the resolved path instead would write
//!     into whatever directory the user redirected the artifact to.
//!  3. **Jobs are keyed by tree hash**, not by (file, name)
//!     (`Operations.jl:936`, `:981`): the same content selected twice must be
//!     downloaded once. Two packages resolving to one artifact is normal —
//!     that is what content addressing is for.
//!  4. **An entry with `download = []` has zero sources but is still
//!     "downloadable"** (`install/artifacts.zig` keeps `has_download`
//!     separate from `downloads.len` for this). With no Pkg server configured
//!     such a job fails with no attempts at all, which is Julia's behaviour
//!     too: the "no download section" error at `:502-503` fires on the missing
//!     KEY, and an empty array falls through the loop into the generic
//!     "Unable to automatically download/install" error with an empty source
//!     list.
//!  5. **A losing rename is success.** `depot.commit` reports
//!     `already_present` when another process published first; the directory
//!     is content-addressed, so their bytes are ours (`Artifacts.jl:79`,
//!     `:91-92`).
//!
//! ## Allocation
//!
//! Bundle-lifetime data — the `Plan`, every `Job`, every `Result` and the
//! strings inside them — is arena-allocated and lives as long as the caller's
//! arena; there is no `deinit` on any of it. The downloaded tarball and its
//! decompressed form are NOT: they go in a scratch arena that is reset after
//! every try — not merely after every source, which would still hold each
//! failed retry's body — and freed when `installJob` returns. A single
//! artifact can be 100 MB (BerkeleyDB_jll), so the difference between "one
//! resident" and "all of them" is 100 MB against 516 MB, and the difference
//! between per-try and per-source is another 3x on a flaky mirror.
//!
//! ## Two things Pkg does that this does not, deliberately
//!
//!   * **Concurrency.** Julia runs the download jobs under a
//!     `Base.Semaphore(num_concurrent_downloads)` with `Threads.@spawn`
//!     (`Operations.jl:1049-1062`, the knob at `Types.jl:463-471`, which
//!     `net.Config` already carries). Here they run one at a time:
//!     `net/http.zig` deliberately ships no scheduler, and parallelising is a
//!     performance change with its own failure modes.
//!
//! Usage bookkeeping is NOT one of them: `download_artifacts` finishes by
//! recording every `Artifacts.toml` it consulted in
//! `<depot>/logs/artifact_usage.toml` (`Operations.jl:1080`), which is what
//! stops `Pkg.gc()` from collecting the artifacts as unreferenced. `plan`
//! collects that list into `Plan.artifact_tomls` and the CLI hands it to
//! `ops/usage.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const artifacts = @import("../install/artifacts.zig");
const extract = @import("../install/extract.zig");
const depot_mod = @import("../depot.zig");
const treehash = @import("../julia/treehash.zig");
const platform_mod = @import("../julia/platform.zig");
const net_http = @import("../net/http.zig");

pub const Platform = platform_mod.Platform;
pub const Hash = treehash.Hash;
pub const Download = artifacts.Download;

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

/// One installed package to collect artifacts from: the directory holding its
/// `(Julia)Artifacts.toml`, i.e. `Operations.jl:932`'s `source_path`.
pub const Package = struct {
    root: []const u8,
    /// The package's UUID, needed only for UUID/name overrides
    /// (`Artifacts.jl:341-372`). Null means "unknown", which is also what
    /// `Operations.collect_artifacts` effectively passes — it calls
    /// `select_downloadable_artifacts` WITHOUT `pkg_uuid`
    /// (`Operations.jl:901`), so stock
    /// Pkg's download path never resolves a UUID/name override even though
    /// `ensure_artifact_installed` documents one. Supplying the UUID here
    /// honours it; leaving it null reproduces `Operations.jl` exactly.
    uuid: ?[]const u8 = null,
};

pub const PlanOptions = struct {
    /// `select_downloadable_artifacts(...; include_lazy)`
    /// (`Artifacts/src/Artifacts.jl:456-476`).
    include_lazy: bool = false,
    /// Passed through to `artifact_exists`/`artifact_path`.
    honor_overrides: bool = true,
};

/// One artifact to put in the depot.
pub const Job = struct {
    /// The `(Julia)Artifacts.toml` it came from. Diagnostics; a job is
    /// identified by its hash.
    artifacts_toml: []const u8,
    name: []const u8,
    /// `bytes2hex(hash.bytes)` — canonical lowercase, which is also the
    /// directory name (`:341`). NOT the string as written in the TOML, which
    /// may be uppercase.
    hash_hex: []const u8,
    hash: Hash,
    /// `[[X.download]]` in FILE ORDER; Julia tries them in that order and
    /// stops at the first success (`:507-523`).
    downloads: []const Download,
    lazy: bool,
    /// `artifact_exists(hash)` said yes, so there is nothing to download
    /// (`:333`, `:459`). Overrides are honoured here per `PlanOptions`.
    present: bool,
    /// Where it IS when `present`, else where it WILL land. These are
    /// different functions on purpose — see trap 2 in the module docs.
    path: []const u8,
};

/// A parse problem in one package's `Artifacts.toml`, forwarded so a caller
/// can report it. See `install/artifacts.zig`'s `Problem`: a non-empty list
/// means real Pkg would have thrown on the file.
pub const FileProblem = struct {
    artifacts_toml: []const u8,
    problem: artifacts.Problem,
};

pub const Plan = struct {
    jobs: []const Job,
    problems: []const FileProblem,
    /// `used_artifact_tomls` (`Operations.jl:952`): every `(Julia)Artifacts.toml`
    /// that was READ, deduplicated — not just the ones that yielded a job. A
    /// file whose artifacts are all lazy, or all already installed, still
    /// belongs in `logs/artifact_usage.toml`, and dropping it there is what
    /// makes `Pkg.gc()` collect the artifacts it pins.
    artifact_tomls: []const []const u8,
    /// Every depot's `Overrides.toml`, already merged and with any UUID/name
    /// entries expanded to hash entries. Kept because it is what `Job.present`
    /// and `Job.path` were decided by: without it a caller cannot interpret
    /// either without re-reading every depot.
    overrides: artifacts.Overrides,
};

pub const PlanError = artifacts.Error || Io.Dir.ReadFileAllocError;

/// `Operations.jl:877-908`'s `collect_artifacts` over several package roots,
/// plus the `artifact_exists` skip that `ensure_artifact_installed` applies
/// per artifact (`:459`).
///
/// `depots` is DEPOT_PATH order: everything is SEARCHED, only `depots[0]` is
/// written to (`Pkg.jl:24-32`). An empty list is rejected rather than guessed
/// at, same as `depot.findInstalled`.
///
/// Arena-lifetime: the returned `Plan` and every string reachable from it come
/// from `arena`. `gpa` is scratch for platform selection only.
///
/// A package root without an `Artifacts.toml` contributes nothing — that is
/// the common case (`collect_artifacts` returns its empty vector,
/// `Operations.jl:907`), not an error. A file that cannot be READ, on the
/// other hand, is a real failure and is propagated: silently installing fewer artifacts than the environment
/// asks for produces a `dlopen` failure much later and somewhere else.
pub fn plan(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    depots: []const []const u8,
    packages: []const Package,
    host: Platform,
    opts: PlanOptions,
) (PlanError || error{NoDepot})!Plan {
    if (depots.len == 0) return error.NoDepot;

    var jobs: std.ArrayList(Job) = .empty;
    var problems: std.ArrayList(FileProblem) = .empty;
    var tomls: std.ArrayList([]const u8) = .empty;
    var overrides = try artifacts.loadOverrides(arena, io, depots);
    const write_depot: depot_mod.Depot = .{ .root = depots[0] };

    for (packages) |pkg| {
        const toml_path = (try artifacts.findArtifactsToml(arena, io, pkg.root)) orelse continue;
        // Recorded BEFORE the selection, and regardless of what it yields:
        // `Set(map(first, all_collected_artifacts))` (`Operations.jl:952`) is
        // over every collected pair, empty ones included. Two package roots
        // can name the same file (a symlinked depot), hence the dedup that
        // `Set{String}` provides on Julia's side.
        for (tomls.items) |t| {
            if (std.mem.eql(u8, t, toml_path)) break;
        } else try tomls.append(arena, toml_path);

        const file = try artifacts.load(arena, io, toml_path);
        for (file.problems) |p| {
            try problems.append(arena, .{ .artifacts_toml = toml_path, .problem = p });
        }

        // `process_overrides` runs at Artifacts.toml LOAD time and mints hash
        // overrides for every variant (`Artifacts/src/Artifacts.jl:341-372`),
        // so it has to happen before any existence check below.
        if (opts.honor_overrides) {
            if (pkg.uuid) |u| try artifacts.processOverrides(&overrides, file, u);
        }

        const selected = try artifacts.selectDownloadable(arena, gpa, file, host, opts.include_lazy);
        for (selected) |s| {
            // `select` guarantees a non-null git-tree-sha1
            // (`Artifacts/src/Artifacts.jl:422-429`), but not that it PARSES:
            // `SHA1(meta["git-tree-sha1"])` (`:458`) is where Julia throws on
            // a malformed one. Skip it and say so rather than inventing a
            // directory name.
            const raw = s.variant.git_tree_sha1.?;
            const hash = extract.parseHash(raw) catch {
                try problems.append(arena, .{
                    .artifacts_toml = toml_path,
                    .problem = .{ .artifact = s.name, .index = s.variant.index, .reason = .malformed_value },
                });
                continue;
            };
            const hex = try arena.dupe(u8, &treehash.toHex(hash));

            // Dedup by hash, not by name: `download_jobs` is a
            // `Dict{SHA1, Function}` (`Operations.jl:936`).
            //
            // Julia's `download_jobs[hash] = ...` (`Operations.jl:981`) is a
            // plain assignment, so on a collision the LAST file's download sources
            // survive; this keeps the FIRST. That difference cannot change
            // what gets installed: the key IS the content hash, so any mirror
            // list serving something else fails the tree-hash check rather
            // than installing it. (Julia's iteration over that Dict is
            // unordered anyway, so there is no order to be faithful to.)
            for (jobs.items) |existing| {
                if (std.mem.eql(u8, existing.hash_hex, hex)) break;
            } else {
                const present = try artifacts.artifactExists(
                    arena,
                    io,
                    depots,
                    hex,
                    &overrides,
                    opts.honor_overrides,
                );
                const path = if (present)
                    try artifacts.artifactPath(arena, io, depots, hex, &overrides, opts.honor_overrides)
                else
                    // NOT artifactPath: an override must never redirect a
                    // write (trap 2).
                    try write_depot.artifactDir(arena, .{ .bytes = hash });
                try jobs.append(arena, .{
                    .artifacts_toml = toml_path,
                    .name = s.name,
                    .hash_hex = hex,
                    .hash = hash,
                    .downloads = s.variant.downloads,
                    .lazy = s.variant.lazy,
                    .present = present,
                    .path = path,
                });
            }
        }
    }

    return .{
        .jobs = try jobs.toOwnedSlice(arena),
        .problems = try problems.toOwnedSlice(arena),
        .artifact_tomls = try tomls.toOwnedSlice(arena),
        .overrides = overrides,
    };
}

// ---------------------------------------------------------------------------
// Installing
// ---------------------------------------------------------------------------

pub const InstallOptions = struct {
    /// Attempts per source, driven by `installJob` rather than by
    /// `net/http.zig`. `download_verify` retries the download itself three
    /// times, one second apart, and gives up immediately on a system error
    /// (`PlatformEngines.jl:358-372`).
    retry: net_http.Retry = .{ .attempts = 3, .delay = .{ .nanoseconds = std.time.ns_per_s } },
    /// Cap on one downloaded tarball. The largest artifact in the
    /// Open-Reality environment is BerkeleyDB_jll at 102 MB; 512 MB leaves
    /// room without letting a hostile server stream forever. Enforced DURING
    /// the read by `net/http.zig`, not after.
    max_tarball_bytes: usize = 512 * 1024 * 1024,
    /// Zip-bomb guard on the decompressed tar.
    max_uncompressed: usize = 2 * 1024 * 1024 * 1024,
    /// `set_readonly(new_path)` (`Artifacts.jl:88`). True for artifacts: the
    /// directory name IS the hash of its contents, so editing it in place
    /// silently invalidates the name.
    set_readonly: bool = true,
    commit_retry: depot_mod.Retry = .{},
};

/// Why one source did not produce an installed artifact (success is a null
/// `Attempt.failure`, not a member here). Every one of these means "try the
/// next URL", which is what Julia does with the error objects it accumulates
/// in `errors` (`:496`, `:521`).
pub const Failure = enum {
    /// A non-2xx response. `Attempt.status` carries the code.
    http_status,
    /// Connect/TLS/read failure, a redirect loop, a malformed URL.
    transport,
    /// Body exceeded `max_tarball_bytes`.
    too_large,
    /// The entry's `sha256` is not 64 hex characters. Julia raises from
    /// `verify` (`PlatformEngines.jl:591-601`), which `download_artifact`
    /// catches and turns into a failed source.
    sha256_malformed,
    /// The bytes are not what the entry says they are.
    sha256_mismatch,
    /// bzip2/xz. `p7zip` handles them for Julia (`PlatformEngines.jl:546`);
    /// no BinaryBuilder artifact uses anything but gzip, so rather than
    /// pretend, say so.
    unsupported_compression,
    decompress_failed,
    /// The archive is well-formed and correctly signed for, and still not the
    /// tree the registry pinned. `Attempt.computed` has what it really was.
    tree_hash_mismatch,
    malformed_archive,
    /// A path whose hashed meaning differs from its on-disk meaning — `..`, a
    /// symlink used as a directory prefix, a duplicate. See `extract.zig`.
    unsafe_archive,
    /// Verified content that the filesystem refused — during extraction, or
    /// during the rename/permission pass that publishes it.
    write_failed,
};

pub const Attempt = struct {
    url: []const u8,
    source: enum {
        /// `$server/artifact/<hash>` (`:484`).
        pkg_server,
        /// A `[[X.download]]` entry (`:507-509`).
        download,
    },
    /// Null on success.
    failure: ?Failure,
    status: ?std.http.Status = null,
    /// The hash actually computed, hex, when that is what failed. Reporting a
    /// mismatch without both sides makes it undiagnosable.
    computed: ?[]const u8 = null,
};

pub const Outcome = enum {
    /// This process published it.
    installed,
    /// Already in a depot before we started (`:333`), or another process won
    /// the rename (`:79`).
    already_present,
    /// Every source failed. `Result.attempts` says how.
    failed,
};

pub const Result = struct {
    job: Job,
    outcome: Outcome,
    /// Where it now is. Empty when `failed`.
    path: []const u8,
    attempts: []const Attempt,
};

/// Errors that are about the MACHINE rather than about a source, so retrying
/// another mirror cannot help: out of memory, cancellation, and a depot that
/// cannot be staged into at all. Everything else — including a failed
/// publish — is a `Failure` in `Result.attempts`, so one bad artifact never
/// takes down the other 97.
pub const InstallError = Allocator.Error || Io.Cancelable || depot_mod.BeginError;

/// Install one artifact: Pkg server first, then every `[[X.download]]` entry
/// in file order, stopping at the first source that verifies
/// (`try_artifact_download_sources`, `:471-533`).
///
/// Arena-lifetime: the `Result` and its attempts come from `arena`. The
/// tarball does not — it lives in a scratch arena that is reset after every
/// try, so the peak is ONE tarball however many mirrors and retries a job
/// burns through.
pub fn installJob(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *net_http.Client,
    depots: []const []const u8,
    job: Job,
    opts: InstallOptions,
) InstallError!Result {
    var attempts: std.ArrayList(Attempt) = .empty;

    if (job.present) {
        return .{ .job = job, .outcome = .already_present, .path = job.path, .attempts = &.{} };
    }

    // Sources in Julia's order: the Pkg server first and unconditionally
    // (`:483-484`) — it is addressed BY the tree hash, so it needs no sha256 —
    // then each `[[X.download]]` entry as written (`:507-523`).
    const Source = struct {
        url: []const u8,
        kind: @FieldType(Attempt, "source"),
        sha256: ?[]const u8,
    };
    var sources: std.ArrayList(Source) = .empty;
    if (client.config.server) |server| {
        try sources.append(arena, .{
            .url = try std.fmt.allocPrint(arena, "{s}/artifact/{s}", .{ server, job.hash_hex }),
            .kind = .pkg_server,
            .sha256 = null,
        });
    }
    for (job.downloads) |d| {
        try sources.append(arena, .{ .url = d.url, .kind = .download, .sha256 = d.sha256 });
    }

    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();

    for (sources.items) |src| {
        // Julia checks existence twice, and the second check is per SOURCE:
        // `ensure_artifact_installed` checks once (`:459`, which is what
        // `plan` reproduces) and every `download_artifact` call checks again
        // on entry (`:333`). A 98-JLL install runs for minutes, so a
        // concurrent `julia` or `ajt` sharing the depot really can publish
        // this hash between two of our mirrors. Overrides were resolved at
        // plan time and do not change during a run, so the depot lookup is all
        // that is left to re-ask.
        if (try artifacts.artifactExists(scratch_state.allocator(), io, depots, job.hash_hex, null, false)) {
            _ = scratch_state.reset(.free_all);
            // Resolved, not `job.path`: the winner may have installed into a
            // different depot than the one this run writes to, and reporting a
            // path that does not exist is worse than reporting none.
            const found = try artifacts.artifactPath(arena, io, depots, job.hash_hex, null, false);
            return .{
                .job = job,
                .outcome = .already_present,
                .path = found,
                .attempts = try attempts.toOwnedSlice(arena),
            };
        }
        _ = scratch_state.reset(.free_all);

        // The retry lives HERE rather than in `net/http.zig`'s `get`, which
        // has one. `Client.get` reuses the arena it was handed for every
        // attempt and says so (`net/http.zig:333-336`), so three failed tries
        // under a 512 MB cap would be resident at once. Driving the loop here
        // lets the scratch arena be reset between tries, which is what makes
        // the "one tarball" claim above true. Julia has the same loop one
        // level down, in `download_verify` (`PlatformEngines.jl:358-372`),
        // re-downloading to a fresh file for the same reason.
        const total = @max(opts.retry.attempts, 1);
        var attempt_no: u32 = 1;
        while (true) : (attempt_no += 1) {
            const r = try tryOne(gpa, arena, io, client, scratch_state.allocator(), .{
                .url = src.url,
                .source = src.kind,
                .sha256 = src.sha256,
                .job = job,
                .opts = opts,
            });
            try attempts.append(arena, r.attempt);
            if (r.installed) |outcome| {
                return .{
                    .job = job,
                    .outcome = outcome,
                    .path = r.path,
                    .attempts = try attempts.toOwnedSlice(arena),
                };
            }
            _ = scratch_state.reset(.free_all);

            // Only a transport-level failure is worth repeating, and Julia
            // agrees in both directions: `download_verify` gives up at once on
            // a `SystemError` (`PlatformEngines.jl:366`), and a FRESH download
            // that fails verification is never re-fetched — the re-download at
            // `:376-386` is guarded by `file_existed`, so a fresh one falls
            // straight through to `@label verification_failed`.
            const retryable = switch (r.attempt.failure.?) {
                .http_status, .transport => true,
                else => false,
            };
            if (!retryable or attempt_no >= total) break;
            // `.awake` is the monotonic clock that does not tick while
            // suspended, which is the right one for a backoff.
            try io.sleep(opts.retry.delay, .awake);
        }
    }

    return .{ .job = job, .outcome = .failed, .path = "", .attempts = try attempts.toOwnedSlice(arena) };
}

const SourceRequest = struct {
    url: []const u8,
    source: @FieldType(Attempt, "source"),
    /// Null for the Pkg server, which has no sha256 to offer (`:488`).
    sha256: ?[]const u8,
    job: Job,
    opts: InstallOptions,
};

const SourceResult = struct {
    attempt: Attempt,
    /// Null unless the artifact is now in the depot.
    installed: ?Outcome = null,
    path: []const u8 = "",
};

/// Download from one URL, verify twice, publish. The order of the four steps
/// is the module's whole point: fetch, sha256, tree hash, write.
fn tryOne(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *net_http.Client,
    scratch: Allocator,
    req: SourceRequest,
) InstallError!SourceResult {
    const base: Attempt = .{ .url = req.url, .source = req.source, .failure = null };
    const fail = struct {
        fn f(a: Attempt, reason: Failure) SourceResult {
            var out = a;
            out.failure = reason;
            return .{ .attempt = out };
        }
    }.f;

    // ---- 1. fetch --------------------------------------------------------
    // `.none`: one try per call. The retry loop is `installJob`'s, so that it
    // can reset the scratch arena between tries — see the note there.
    const res = client.get(scratch, req.url, .{
        .retry = .none,
        .max_body_bytes = req.opts.max_tarball_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.ResponseTooLarge => return fail(base, .too_large),
        else => return fail(base, .transport),
    };
    if (!res.ok()) {
        var a = base;
        a.status = res.status;
        return fail(a, .http_status);
    }

    // ---- 2. sha256 of the COMPRESSED bytes, before anything decompresses --
    if (req.sha256) |want| {
        if (!isSha256Hex(want)) return fail(base, .sha256_malformed);
        const got = sha256Hex(res.body);
        // `hash = lowercase(hash)` before the compare
        // (`PlatformEngines.jl:603`): a registry entry may be uppercase.
        if (!std.ascii.eqlIgnoreCase(want, &got)) {
            var a = base;
            a.computed = try arena.dupe(u8, &got);
            return fail(a, .sha256_mismatch);
        }
    }

    // ---- 3. decompress ---------------------------------------------------
    const tar_bytes = switch (compressionOf(res.body)) {
        .gzip => extract.gunzip(scratch, res.body, req.opts.max_uncompressed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(base, .decompress_failed),
        },
        .tar => res.body,
        .unsupported => return fail(base, .unsupported_compression),
    };

    // ---- 4. tree hash, then write, in that order and never the other way --
    //
    // The staging directory is a sibling of the destination so the publish is
    // a rename and not a cross-device copy (`depot.begin`). It is created
    // before the tree hash is known — as Julia's `mktempdir(artifacts_dir)` is
    // (`:351`) — but `verifyAndExtractTar` returns before its first filesystem
    // call on any mismatch, so a rejected artifact leaves it empty and
    // `deinit` takes it away.
    var install = try depot_mod.begin(arena, io, req.job.path);
    defer install.deinit(io);

    var computed: Hash = undefined;
    extract.verifyAndExtractTar(gpa, io, tar_bytes, req.job.hash, install.dir, .{
        .shape = .top_level,
        // GitTools.tree_hash semantics — the hasher Pkg compares against
        // `git-tree-sha1` (`Artifacts.jl:359`). extract.zig defaults to this;
        // spelled out because the OTHER default (Tar.tree_hash) is a
        // silently different answer for a tarball with an empty directory.
        .skip_empty = true,
        // No `max_uncompressed` here: that option only guards extract.zig's
        // GZIP entry points, and the decompression already happened above
        // under exactly that cap.
        .computed = &computed,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TreeHashMismatch => {
            var a = base;
            a.computed = try arena.dupe(u8, &treehash.toHex(computed));
            return fail(a, .tree_hash_mismatch);
        },
        error.UnsafePath, error.PathTooDeep, error.SymlinkPrefix, error.ConflictingPaths => return fail(base, .unsafe_archive),
        error.DecompressFailed => return fail(base, .decompress_failed),
        error.MalformedTar, error.NotSingleRooted => return fail(base, .malformed_archive),
        error.ExtractFailed => return fail(base, .write_failed),
    };

    // A publish failure is this SOURCE's failure, not the run's: Julia wraps
    // `_mv_temp_artifact_dir` in the same try/catch as the download and hands
    // the error object back as a failed source (`:398`, caught at `:400-405`).
    // Aborting instead would take down the other 97 JLLs over one artifact.
    //
    // `depot.commit` can also fail with the content ALREADY PUBLISHED — it
    // documents that the permission pass runs after the rename
    // (`depot.zig:573-576`). That is why this is not a lie: the next source,
    // or the next run, finds the destination in place and reports
    // `already_present` rather than re-downloading.
    const outcome = install.commit(gpa, io, .{
        .retry = req.opts.commit_retry,
        .set_readonly = req.opts.set_readonly,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return fail(base, .write_failed),
    };

    return .{
        .attempt = base,
        .installed = switch (outcome) {
            .installed => .installed,
            .already_present => .already_present,
        },
        .path = req.job.path,
    };
}

/// `installJob` over a whole plan, in plan order. Present jobs pass straight
/// through so a caller can report every artifact, not only the downloaded
/// ones.
pub fn installAll(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *net_http.Client,
    depots: []const []const u8,
    jobs: []const Job,
    opts: InstallOptions,
) InstallError![]const Result {
    const out = try arena.alloc(Result, jobs.len);
    for (jobs, out) |job, *slot| {
        slot.* = try installJob(gpa, arena, io, client, depots, job, opts);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const Compression = enum { gzip, tar, unsupported };

/// Sniffed from the bytes, not from the URL. Julia hands the file to `7z`,
/// which does the same (`PlatformEngines.jl:546`); its own extension guess
/// (`PlatformEngines.jl:485-507`) only picks a temp FILE NAME and defaults to
/// `.gz` regardless.
fn compressionOf(body: []const u8) Compression {
    if (std.mem.startsWith(u8, body, "\x1f\x8b")) return .gzip;
    if (std.mem.startsWith(u8, body, "BZh")) return .unsupported;
    if (std.mem.startsWith(u8, body, "\xfd7zXZ\x00")) return .unsupported;
    if (std.mem.startsWith(u8, body, "\x28\xb5\x2f\xfd")) return .unsupported; // zstd
    return .tar;
}

/// `occursin(r"^[0-9a-f]{64}$"i, hash)` (`PlatformEngines.jl:591`).
fn isSha256Hex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ---------------------------------------------------------------------------
// Tests
//
// The pipeline has no Julia oracle that a unit test can call: `download_artifact`
// wants a real URL. So the network is real but local — a loopback server that
// serves scripted bodies and logs what each request asked for. That log is the
// only way to observe the ordering rules (server before mirrors, mirrors in
// file order) as opposed to merely observing that something got installed.
// The differential gate in tools/diff_harness/install_artifacts.sh does the
// other half: it installs REAL JLL artifacts and hands the result to
// `Pkg.GitTools.tree_hash` and `Pkg.Artifacts.artifact_exists`.
// ---------------------------------------------------------------------------

const testing = std.testing;

const linux_host = [_]platform_mod.Tag{
    .{ .key = "arch", .value = "x86_64" },
    .{ .key = "os", .value = "linux" },
    .{ .key = "libc", .value = "glibc" },
};

fn hostPlatform() Platform {
    return .{ .tags = &linux_host, .is_host = true };
}

/// A tar holding a subdirectory, an executable file and a symlink — the three
/// things a git tree hash treats differently from plain bytes.
fn buildSampleTar(gpa: Allocator) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try tw.writeFileBytes("lib/libfoo.so", "\x7fELF not really\n", .{ .mode = 0o755 });
    try tw.writeFileBytes("README.md", "artifact\n", .{ .mode = 0o644 });
    try tw.writeLink("lib/libfoo.so.1", "libfoo.so", .{});
    try tw.finishPedantically();
    return out.toOwnedSlice();
}

fn gzipOf(gpa: Allocator, bytes: []const u8) ![]u8 {
    // initCapacity, not init: Compress.init asserts its output buffer is
    // bigger than the gzip header it stages there.
    var out: Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var comp = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try comp.writer.writeAll(bytes);
    try comp.finish();
    return out.toOwnedSlice();
}

/// Scripted loopback HTTP server: one request per connection, `Connection:
/// close` on every response, and a log of what each hop asked for.
const TestServer = struct {
    server: Io.net.Server,
    port: u16,
    count: usize = 0,
    targets: [max_requests][128]u8 = undefined,
    target_len: [max_requests]usize = @splat(0),

    const max_requests = 8;

    /// A range of its own, disjoint from net/http.zig's loopback tests: with
    /// SO_REUSEPORT a second listen on a live port SUCCEEDS and the kernel
    /// load-balances between them, which would show up as a request going to
    /// the wrong server.
    const port_base = 41871;
    const port_span = 500;
    var next_offset: std.atomic.Value(u16) = .init(0);

    fn start(io: Io) !TestServer {
        const first = next_offset.fetchAdd(1, .monotonic);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // An EXCLUSIVE bind: `reuse_address` would set SO_REUSEPORT, under
            // which a second `listen` on a live port succeeds and the kernel
            // load-balances connections between the two servers. See the long
            // note on `LoopbackServer.start` in `src/net/http.zig`.
            const srv = addr.listen(io, .{}) catch continue;
            return .{ .server = srv, .port = port };
        }
        return error.NoFreePort;
    }

    fn deinit(self: *TestServer, io: Io) void {
        self.server.deinit(io);
    }

    fn baseUrl(self: *const TestServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    fn target(self: *const TestServer, i: usize) []const u8 {
        return self.targets[i][0..self.target_len[i]];
    }

    /// Serves exactly `script.len` requests, then returns. Every test must
    /// issue exactly that many, or the two sides deadlock rather than fail.
    fn serve(io: Io, self: *TestServer, script: []const []const u8) void {
        for (script) |response| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            const r = &sr.interface;

            const i = self.count;
            if (i >= max_requests) return;
            self.count += 1;

            const request_line = r.takeDelimiterInclusive('\n') catch return;
            if (std.mem.indexOfScalar(u8, request_line, ' ')) |sp| {
                const rest = request_line[sp + 1 ..];
                const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                const t = rest[0..@min(end, self.targets[i].len)];
                @memcpy(self.targets[i][0..t.len], t);
                self.target_len[i] = t.len;
            }
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            sw.interface.writeAll(response) catch {};
            sw.interface.flush() catch {};
        }
    }
};

fn okBody(arena: Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
}

const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const server_error = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Writes a package root with an `Artifacts.toml` naming one artifact with
/// `mirrors` download entries, and returns the root path.
fn writePackage(
    arena: Allocator,
    io: Io,
    root: []const u8,
    hash_hex: []const u8,
    mirrors: []const Download,
    extra: []const u8,
) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, root);
    var src: Io.Writer.Allocating = .init(arena);
    try src.writer.print(
        \\[[libfoo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "{s}"
        \\{s}
        \\
    , .{ hash_hex, extra });
    for (mirrors) |m| {
        try src.writer.print(
            \\
            \\    [[libfoo.download]]
            \\    url = "{s}"
            \\    sha256 = "{s}"
            \\
        , .{ m.url, m.sha256 });
    }
    const path = try std.fs.path.join(arena, &.{ root, "Artifacts.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src.written() });
    return root;
}

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    depot: []const u8,
    tar: []u8,
    gz: []u8,
    hash_hex: []const u8,
    sha256: []const u8,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var f: Fixture = .{
            .arena_state = .init(gpa),
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .depot = undefined,
            .tar = try buildSampleTar(gpa),
            .gz = undefined,
            .hash_hex = undefined,
            .sha256 = undefined,
        };
        const arena = f.arena_state.allocator();
        f.gz = try gzipOf(gpa, f.tar);
        f.depot = try f.tmp.dir.realPathFileAlloc(io, ".", arena);
        f.hash_hex = try arena.dupe(u8, &treehash.toHex(try extract.treeHashOfTar(gpa, f.tar, .{})));
        f.sha256 = try arena.dupe(u8, &sha256Hex(f.gz));
        return f;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        gpa.free(self.tar);
        gpa.free(self.gz);
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn allocator(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    /// Creates `<depot>/artifacts` up front, so that a later "wrote nothing"
    /// assertion is about an EMPTY directory rather than a MISSING one.
    /// Without this the sha256-rejection tests would be vacuous: that path
    /// returns before `depot.begin`, which is the only thing that creates
    /// `artifacts/`, so the count would be zero however broken the code was.
    fn makeArtifactsDir(self: *Fixture, io: Io) !void {
        try self.tmp.dir.createDirPath(io, "artifacts");
    }

    /// How many entries `<depot>/artifacts` holds — 0 proves a rejected
    /// install left neither content nor a staging directory behind. Errors
    /// rather than assuming zero when the directory is absent; see
    /// `makeArtifactsDir`.
    fn artifactEntries(self: *Fixture, io: Io) !usize {
        var dir = try self.tmp.dir.openDir(io, "artifacts", .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var n: usize = 0;
        while (try it.next(io)) |_| n += 1;
        return n;
    }
};

test "the Pkg server is tried first, and its tarball installs atomically" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const server = try arena.dupe(u8, srv.baseUrl(&url_buf));

    // A mirror is listed AND would work; the server must still win.
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), fx.hash_hex, &.{
        .{ .url = "http://127.0.0.1:1/never-reached.tar.gz", .sha256 = fx.sha256 },
    }, "");

    const script = [_][]const u8{try okBody(arena, fx.gz)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = fx.depot });
    defer client.deinit();

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    try testing.expectEqual(@as(usize, 1), p.jobs.len);
    try testing.expect(!p.jobs[0].present);

    const results = try installAll(gpa, arena, io, &client, &.{fx.depot}, p.jobs, .{ .retry = .none });
    task.await(io);

    try testing.expectEqual(Outcome.installed, results[0].outcome);
    try testing.expectEqual(@as(usize, 1), results[0].attempts.len);
    try testing.expectEqual(@as(usize, 1), srv.count);
    // `$server/artifact/<hex tree hash>` (:484), and the hex is canonical.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "/artifact/{s}", .{fx.hash_hex}),
        srv.target(0),
    );

    // It landed where stock julia looks, and re-hashes to the name it was
    // given -- checked with the OTHER hasher (the filesystem walker), which is
    // what proves the stream hash described the bytes that got written.
    const installed = try std.fs.path.join(arena, &.{ fx.depot, "artifacts", fx.hash_hex });
    const on_disk = try treehash.hashPath(gpa, io, installed);
    try testing.expectEqualStrings(fx.hash_hex, &treehash.toHex(on_disk));
    // Content-addressed, so it is published read-only (`Artifacts.jl:88`).
    const st = try Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ installed, "README.md" }), .{});
    try testing.expect(st.permissions.readOnly());
    // No staging leftovers.
    try testing.expectEqual(@as(usize, 1), try fx.artifactEntries(io));

    // A second plan sees it, and installJob then does no I/O at all. The
    // server is pointed at a dead port first: its scripted responses are used
    // up, but its socket is still listening, so a regression that DID issue a
    // request would block in accept forever instead of failing -- and `zig
    // build test` has no timeout. Port 1 is reserved and refuses immediately.
    client.config.server = "http://127.0.0.1:1";
    const p2 = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    try testing.expect(p2.jobs[0].present);
    const again = try installAll(gpa, arena, io, &client, &.{fx.depot}, p2.jobs, .{ .retry = .none });
    try testing.expectEqual(Outcome.already_present, again[0].outcome);
    try testing.expectEqual(@as(usize, 0), again[0].attempts.len);
}

test "a failing server falls through to the download entries in file order" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const server = try arena.dupe(u8, srv.baseUrl(&url_buf));

    // Both mirrors point at the same loopback server so one script drives all
    // three hops; the PATHS are what distinguish them.
    const mirror1 = try std.fmt.allocPrint(arena, "{s}/mirror1/libfoo.tar.gz", .{server});
    const mirror2 = try std.fmt.allocPrint(arena, "{s}/mirror2/libfoo.tar.gz", .{server});
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), fx.hash_hex, &.{
        .{ .url = mirror1, .sha256 = fx.sha256 },
        .{ .url = mirror2, .sha256 = fx.sha256 },
    }, "");

    const script = [_][]const u8{
        not_found, // the server has never heard of this artifact
        server_error, // mirror 1 is down
        try okBody(arena, fx.gz), // mirror 2 serves it
    };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = fx.depot });
    defer client.deinit();

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    const results = try installAll(gpa, arena, io, &client, &.{fx.depot}, p.jobs, .{ .retry = .none });
    task.await(io);

    try testing.expectEqual(Outcome.installed, results[0].outcome);
    const at = results[0].attempts;
    try testing.expectEqual(@as(usize, 3), at.len);
    try testing.expectEqual(Failure.http_status, at[0].failure.?);
    try testing.expectEqual(std.http.Status.not_found, at[0].status.?);
    try testing.expectEqual(Failure.http_status, at[1].failure.?);
    try testing.expect(at[2].failure == null);
    // Order is the assertion: server, then mirrors as written in the file.
    try testing.expect(std.mem.startsWith(u8, srv.target(0), "/artifact/"));
    try testing.expectEqualStrings("/mirror1/libfoo.tar.gz", srv.target(1));
    try testing.expectEqualStrings("/mirror2/libfoo.tar.gz", srv.target(2));

    const on_disk = try treehash.hashPath(gpa, io, results[0].path);
    try testing.expectEqualStrings(fx.hash_hex, &treehash.toHex(on_disk));
}

test "a wrong sha256 is rejected and nothing reaches artifacts/" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const server = try arena.dupe(u8, srv.baseUrl(&url_buf));
    const mirror = try std.fmt.allocPrint(arena, "{s}/mirror/libfoo.tar.gz", .{server});

    try fx.makeArtifactsDir(io);

    // The BYTES are the real artifact and would pass the tree-hash check --
    // only the recorded sha256 disagrees. That isolates this check from the
    // other one: a corrupt body that still matches its sha256 is not
    // constructible, so the two paths have to be forced separately.
    const wrong = "0" ** 64;
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), fx.hash_hex, &.{
        .{ .url = mirror, .sha256 = wrong },
    }, "");

    const script = [_][]const u8{try okBody(arena, fx.gz)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    // No Pkg server configured, so the mirror is the only source and the
    // single scripted response is consumed exactly once.
    var client: net_http.Client = .init(gpa, io, .{ .depot = fx.depot });
    defer client.deinit();

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    const results = try installAll(gpa, arena, io, &client, &.{fx.depot}, p.jobs, .{ .retry = .none });
    task.await(io);

    try testing.expectEqual(Outcome.failed, results[0].outcome);
    try testing.expectEqual(@as(usize, 1), results[0].attempts.len);
    try testing.expectEqual(Failure.sha256_mismatch, results[0].attempts[0].failure.?);
    // Both sides of the mismatch are reported, or it cannot be diagnosed.
    try testing.expectEqualStrings(fx.sha256, results[0].attempts[0].computed.?);
    // THE assertion: not a byte, and not a staging directory either.
    try testing.expectEqual(@as(usize, 0), try fx.artifactEntries(io));

    // A malformed sha256 is a different failure, and Julia throws on it too
    // (PlatformEngines.jl:591-601).
    try testing.expect(!isSha256Hex("deadbeef"));
    try testing.expect(!isSha256Hex("z" ** 64));
    try testing.expect(isSha256Hex(fx.sha256));
    // ...and the compare is case-insensitive, because Julia lowercases first.
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, fx.sha256);
    try testing.expect(std.ascii.eqlIgnoreCase(&upper, fx.sha256));
}

test "a correct sha256 with the wrong tree hash is still rejected" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const server = try arena.dupe(u8, srv.baseUrl(&url_buf));
    const mirror = try std.fmt.allocPrint(arena, "{s}/mirror/libfoo.tar.gz", .{server});

    try fx.makeArtifactsDir(io);

    // The download entry is internally consistent -- correct sha256 for the
    // bytes served -- and the artifact is pinned to a DIFFERENT tree. This is
    // the shape sha256 alone cannot catch, which is why both checks exist.
    const other_hash = "0123456789abcdef0123456789abcdef01234567";
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), other_hash, &.{
        .{ .url = mirror, .sha256 = fx.sha256 },
    }, "");

    const script = [_][]const u8{try okBody(arena, fx.gz)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{ .depot = fx.depot });
    defer client.deinit();

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    const results = try installAll(gpa, arena, io, &client, &.{fx.depot}, p.jobs, .{ .retry = .none });
    task.await(io);

    try testing.expectEqual(Outcome.failed, results[0].outcome);
    try testing.expectEqual(Failure.tree_hash_mismatch, results[0].attempts[0].failure.?);
    try testing.expectEqualStrings(fx.hash_hex, results[0].attempts[0].computed.?);
    try testing.expectEqual(@as(usize, 0), try fx.artifactEntries(io));
}

test "an empty download array is a job with no sources at all" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    try fx.makeArtifactsDir(io);

    // Trap 4: `download = []` is "downloadable" by KEY PRESENCE, so it plans
    // as a job, and with no Pkg server there is then nothing to try. Julia
    // ends up in the same place — its "no download section" error
    // (`:502-503`) tests `haskey`, so an empty array falls through the loop
    // into the generic failure with an empty source list.
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), fx.hash_hex, &.{}, "download = []");

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    try testing.expectEqual(@as(usize, 1), p.jobs.len);
    try testing.expectEqual(@as(usize, 0), p.jobs[0].downloads.len);

    var client: net_http.Client = .init(gpa, io, .{ .depot = fx.depot });
    defer client.deinit();
    const r = try installJob(gpa, arena, io, &client, &.{fx.depot}, p.jobs[0], .{ .retry = .none });
    try testing.expectEqual(Outcome.failed, r.outcome);
    try testing.expectEqual(@as(usize, 0), r.attempts.len);
    try testing.expectEqual(@as(usize, 0), try fx.artifactEntries(io));
}

test "an artifact that appears between planning and downloading is not downloaded" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    // Port 1 is reserved and never listening, so any attempt to fetch shows
    // up as a failed transport attempt rather than as a hang.
    const root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "pkg" }), fx.hash_hex, &.{
        .{ .url = "http://127.0.0.1:1/libfoo.tar.gz", .sha256 = "ab" ** 32 },
    }, "");

    const p = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = root }}, hostPlatform(), .{});
    try testing.expect(!p.jobs[0].present);

    // ...and now a concurrent installer publishes it. A 98-JLL install is
    // minutes long, so this window is real, and Julia closes it with a second
    // existence check inside download_artifact (:333).
    try Io.Dir.cwd().createDirPath(io, p.jobs[0].path);

    var client: net_http.Client = .init(gpa, io, .{ .depot = fx.depot });
    defer client.deinit();
    const r = try installJob(gpa, arena, io, &client, &.{fx.depot}, p.jobs[0], .{ .retry = .none });
    try testing.expectEqual(Outcome.already_present, r.outcome);
    try testing.expectEqual(@as(usize, 0), r.attempts.len);
}

test "planning: lazy and download-less artifacts, dedup by hash, and overrides" {
    const gpa = testing.allocator;
    const io = testing.io;

    var fx = try Fixture.init(gpa, io);
    defer fx.deinit(gpa);
    const arena = fx.allocator();

    // Two packages selecting the SAME artifact: one job, not two
    // (Operations.jl:936 keys download_jobs by SHA1).
    const dl = [_]Download{.{ .url = "https://example.invalid/a.tar.gz", .sha256 = "ab" ** 32 }};
    const a = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "a" }), fx.hash_hex, &dl, "");
    const b = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "b" }), fx.hash_hex, &dl, "");

    const one = try plan(arena, gpa, io, &.{fx.depot}, &.{ .{ .root = a }, .{ .root = b } }, hostPlatform(), .{});
    try testing.expectEqual(@as(usize, 1), one.jobs.len);
    // The install destination is depot[0]/artifacts/<hex>, never artifact_path.
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ fx.depot, "artifacts", fx.hash_hex }),
        one.jobs[0].path,
    );

    // Lazy: excluded by default, included on request
    // (Artifacts/src/Artifacts.jl:468).
    const lazy_root = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "lazy" }), fx.hash_hex, &dl, "lazy = true");
    const eager = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = lazy_root }}, hostPlatform(), .{});
    try testing.expectEqual(@as(usize, 0), eager.jobs.len);
    const with_lazy = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = lazy_root }}, hostPlatform(), .{ .include_lazy = true });
    try testing.expectEqual(@as(usize, 1), with_lazy.jobs.len);
    try testing.expect(with_lazy.jobs[0].lazy);

    // No download stanza at all: never a job, whatever include_lazy says.
    const local = try writePackage(arena, io, try std.fs.path.join(arena, &.{ fx.depot, "local" }), fx.hash_hex, &.{}, "");
    const none = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = local }}, hostPlatform(), .{ .include_lazy = true });
    try testing.expectEqual(@as(usize, 0), none.jobs.len);

    // A package root with no Artifacts.toml contributes nothing rather than
    // failing (`collect_artifacts` returns empty, Operations.jl:907).
    const bare = try std.fs.path.join(arena, &.{ fx.depot, "bare" });
    try Io.Dir.cwd().createDirPath(io, bare);
    const empty = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = bare }}, hostPlatform(), .{});
    try testing.expectEqual(@as(usize, 0), empty.jobs.len);

    // An override pointing at an existing directory makes the artifact
    // "present" without anything being installed under artifacts/<hex>
    // (artifact_exists honours overrides by default).
    const elsewhere = try std.fs.path.join(arena, &.{ fx.depot, "elsewhere" });
    try Io.Dir.cwd().createDirPath(io, elsewhere);
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ fx.depot, "artifacts" }));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ fx.depot, "artifacts", "Overrides.toml" }),
        .data = try std.fmt.allocPrint(arena, "{s} = \"{s}\"\n", .{ fx.hash_hex, elsewhere }),
    });
    const overridden = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = a }}, hostPlatform(), .{});
    try testing.expect(overridden.jobs[0].present);
    try testing.expectEqualStrings(elsewhere, overridden.jobs[0].path);

    // ...and honor_overrides = false looks straight through it again.
    const raw = try plan(arena, gpa, io, &.{fx.depot}, &.{.{ .root = a }}, hostPlatform(), .{ .honor_overrides = false });
    try testing.expect(!raw.jobs[0].present);

    try testing.expectError(error.NoDepot, plan(arena, gpa, io, &.{}, &.{.{ .root = a }}, hostPlatform(), .{}));
}

test "compression is sniffed from the bytes, and what 7z would handle is refused loudly" {
    const gpa = testing.allocator;
    const tar = try buildSampleTar(gpa);
    defer gpa.free(tar);
    const gz = try gzipOf(gpa, tar);
    defer gpa.free(gz);

    try testing.expectEqual(Compression.gzip, compressionOf(gz));
    try testing.expectEqual(Compression.tar, compressionOf(tar));
    try testing.expectEqual(Compression.unsupported, compressionOf("BZh91AY&SY"));
    try testing.expectEqual(Compression.unsupported, compressionOf("\xfd7zXZ\x00\x00"));
    // An empty body is not gzip; it fails later as a malformed tar, which is
    // the honest answer for "the mirror served nothing".
    try testing.expectEqual(Compression.tar, compressionOf(""));
}
