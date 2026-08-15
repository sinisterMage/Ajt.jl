//! `Pkg.gc()` -- the depot sweeper (`Pkg/src/API.jl:595-1173`).
//!
//! This is the only module in Ajt that unlinks a user's data, and its failure
//! mode is silent and delayed: a package deleted today surfaces as a broken
//! environment next week, in a different process, with no message connecting
//! the two. Everything below is written for that.
//!
//! ## The rule
//!
//! A depot is garbage-collected against exactly one source of truth: the usage
//! logs in `<depot>/logs/` (`ops/usage.zig` writes them). `gc` reads the KEYS
//! out of them -- environment `Manifest.toml`s, package `Artifacts.toml`s,
//! scratchspace directories -- drops every key that is no longer on disk
//! (`API.jl:684-687`), and treats what remains as the complete set of roots.
//! Anything under `packages/`, `clones/`, `artifacts/` or `scratchspaces/` that
//! is not reachable from a root is orphaned, and after `collect_delay` it is
//! deleted. **A key that is not on disk is dead; that is the whole rule.**
//!
//! ## Six phases, and the order is load-bearing
//!
//!  1. **Read** every usage log in every swept depot (`:617-671`).
//!  2. **Liveness**: intersect the union of keys with the filesystem
//!     (`:673-687`).
//!  3. **Condense** the logs back down, one entry per surviving key
//!     (`:689-756`). This is what keeps them from growing without bound, and it
//!     happens before any marking, so a crash later still leaves them tidy.
//!  4. **Mark** -- and `packages` must be marked STRICTLY BEFORE `artifacts`.
//!     `process_artifacts_toml` returns `nothing` for an `Artifacts.toml` that
//!     lives inside a package which is about to be deleted (`:794-802`), so
//!     that the artifacts bound only by that package are reaped with it. Pkg
//!     says so in a comment; get the order wrong and you either keep artifacts
//!     nothing references or, worse, race the two decisions against each other.
//!  5. **Orphanage**: `logs/orphaned.toml` is REWRITTEN with everything that is
//!     orphaned right now, and only the entries that have already aged past
//!     `collect_delay` go on the deletion list (`:1029-1050`). On first
//!     orphaning `free_time == gc_time`, so a default run deletes NOTHING --
//!     that is correct, and it is why any gate over this file must pass
//!     `Second(0)`.
//!  6. **Delete**, packages then repos then artifacts then scratchspaces, then
//!     prune the `packages/<Name>` and `scratchspaces/<uuid>` directories that
//!     are now empty (`:1101-1145`).
//!
//! ## Where this refuses to act
//!
//! Two divergences, both in the direction of deleting less than Pkg, both
//! because the alternative is unrecoverable:
//!
//!  * **An unreadable usage log aborts the whole collection.** `merge` on the
//!    write side treats an unparseable log as empty and rewrites it, which is
//!    right there -- the worst case is a depot left unprotected. Here "empty"
//!    means "nothing in this depot is reachable", i.e. delete all of it. Julia
//!    has no `try` around `reduce_usage!` (`:621-630`) and throws out of
//!    `Pkg.gc()` for the same reason, so this also matches what Pkg actually
//!    does: nothing is collected.
//!  * **A malformed `Artifacts.toml` aborts it too.** `process_artifacts_toml`
//!    indexes `meta["git-tree-sha1"]` unguarded (`:813`), so Pkg throws before
//!    it has deleted anything.
//!
//! Everything else follows Pkg exactly, including the parts that look like
//! bugs. The `clones/` naming asymmetry is the notable one -- see
//! `markManifestRepos`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const usage = @import("usage.zig");
const manifest_mod = @import("../model/manifest.zig");
const artifacts_mod = @import("../install/artifacts.zig");
const git_url = @import("../git/url.zig");
const toml_parse = @import("../toml/parse.zig");
const toml_emit = @import("../toml/emit.zig");
const toml_value = @import("../toml/value.zig");
const registry_ops = @import("registry_ops.zig");

const Value = toml_value.Value;
const Table = toml_value.Table;
const DateTime = toml_value.DateTime;

const StringSet = std.StringHashMapUnmanaged(void);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const hour_ms: i64 = 60 * 60 * 1000;
pub const day_ms: i64 = 24 * hour_ms;

/// `collect_delay::Period = Day(7)` (`API.jl:595`).
pub const default_collect_delay_ms: i64 = 7 * day_ms;

/// What the REPL's `--all` means: `PSA[:name => "all", :api => :collect_delay
/// => Hour(0)]` (`REPLMode/command_declarations.jl:501`). Zero, not "ignore the
/// orphanage" -- the orphanage is still rewritten, everything in it is simply
/// already old enough.
pub const all_collect_delay_ms: i64 = 0;

/// `Operations.PkgUUID` (`Operations.jl:1393`). Compared as a STRING against a
/// directory name, never parsed, because a `scratchspaces/` child that is not
/// a UUID at all still has to be enumerated so it can be orphaned.
pub const pkg_uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f";

/// `mtime(f) < time() - 24*60*60` (`API.jl:1024`) for Pkg's own precompilation
/// marker files.
const suspend_cache_max_age_s: i64 = 24 * 60 * 60;

const suspend_cache_prefixes = [_][]const u8{ "suspend_cache_", "pending_cache_" };

/// `logs/orphaned.toml` -- `gc`'s own bookkeeping, written by nothing else
/// (`API.jl:1029-1050`).
pub const orphaned_log = "orphaned.toml";

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// `collect_delay`, in milliseconds. The default is `Day(7)`; `--all` is
    /// `Hour(0)`.
    collect_delay_ms: i64 = default_collect_delay_ms,

    /// `force = true` sweeps every depot instead of just `depots1()`
    /// (`API.jl:600`). Pkg's REPL does not even expose this, and neither does
    /// `Ajt.gc`'s REPL arm: a stacked `JULIA_DEPOT_PATH` normally has a
    /// READ-ONLY image depot behind the writable one, and collecting that is
    /// either a no-op or a disaster depending on who owns the mount.
    force: bool = false,

    /// Compute and report the deletion set without unlinking anything. Ajt's
    /// own; there is no `Pkg.gc(dry_run = true)`. The orphanage and the
    /// condensed logs are NOT written either, so a dry run is genuinely
    /// read-only and can be diffed against a real one.
    dry_run: bool = false,

    /// `gc_time = now()` (`:875`). Overridable so a test can age the orphanage
    /// without waiting a week.
    now: ?DateTime = null,

    /// `time()` in unix seconds, for the 24-hour `suspend_cache_*` test only.
    now_unix_s: ?i64 = null,
};

pub const Kind = enum {
    package,
    repo,
    artifact,
    scratchspace,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .package => "package",
            .repo => "repo",
            .artifact => "artifact",
            .scratchspace => "scratchspace",
        };
    }
};

pub const Deletion = struct {
    kind: Kind,
    path: []const u8,
    /// `recursive_dir_size` (`:1051-1066`), measured before the unlink.
    bytes: u64,
    /// False when the unlink failed. Julia `@warn`s and counts zero bytes
    /// (`:1084-1087`); the path stays in `orphaned.toml`, so the next run tries
    /// again -- which is exactly why the orphanage is written BEFORE anything
    /// is deleted.
    deleted: bool,
};

pub const Report = struct {
    /// `printpkgstyle(:Active, "manifest files: N found")` (`:864`). These are
    /// the counts of index files that were still readable AND still on disk,
    /// and they are the sharpest evidence available that `gc` actually saw the
    /// logs, as opposed to finding nothing to do.
    active_manifests: usize = 0,
    active_artifacts: usize = 0,
    active_scratchspaces: usize = 0,
    deletions: []const Deletion = &.{},
    dry_run: bool = false,

    pub fn count(self: Report, kind: Kind) usize {
        var n: usize = 0;
        for (self.deletions) |d| {
            if (d.kind == kind) n += 1;
        }
        return n;
    }

    /// Bytes actually freed. A FAILED unlink contributes nothing, matching
    /// `delete_path`'s `return 0` on its `@warn` path (`:1084-1087`) -- so the
    /// count and the size deliberately disagree when something could not be
    /// removed. Under `dry_run` nothing is freed, so the measured size is
    /// reported instead: that is the number the plan is for.
    pub fn bytes(self: Report, kind: Kind) u64 {
        var n: u64 = 0;
        for (self.deletions) |d| {
            if (d.kind == kind and (d.deleted or self.dry_run)) n +|= d.bytes;
        }
        return n;
    }
};

pub const Error = error{
    /// An empty `DEPOT_PATH`. `depots1()` raises "no depots provided"
    /// (`Pkg.jl:29`).
    NoDepot,
    /// A usage log in a swept depot could not be read. NOTHING is collected;
    /// see the module header.
    MalformedUsageLog,
    /// An `Artifacts.toml` reachable from a live log has an entry with no
    /// usable `git-tree-sha1`. Pkg throws here as well, before deleting
    /// anything.
    MalformedArtifactsToml,
    /// A condensed usage log or `logs/orphaned.toml` could not be written.
    /// NOTHING is collected.
    ///
    /// This one is easy to get wrong in the fatal direction, so: Julia writes
    /// both with a bare `open(path, "w")` (`API.jl:699`, `:1047`), which
    /// THROWS. Both writes happen in phases 3 and 5, i.e. strictly before
    /// `delete_path` is ever called, so a `Pkg.gc()` that cannot write its
    /// bookkeeping deletes nothing at all. Warning and carrying on would mean
    /// unlinking a user's packages with no record that it happened -- and the
    /// realistic trigger is not exotic: a root-owned `logs/` in a container, a
    /// full disk (where the delete SUCCEEDS because it frees space), or
    /// `--force` reaching the read-only image depot of a stacked
    /// `JULIA_DEPOT_PATH`.
    DepotNotWritable,
} || depot_mod.ListError || Allocator.Error || Io.Cancelable;

/// Which file could not be read, for an error message that names it. Filled in
/// on `MalformedUsageLog` / `MalformedArtifactsToml`, which are the two errors
/// a user can actually fix.
pub const Diagnostic = struct {
    path: []const u8 = "",
};

// ---------------------------------------------------------------------------
// The collection
// ---------------------------------------------------------------------------

/// `Pkg.gc(; collect_delay, verbose, force)`.
///
/// Arena: every string in the returned `Report` is arena-owned. `gpa` backs
/// transient sets, directory walks and the TOML renders, and is fully released
/// before return.
pub fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    stack: depot_mod.Stack,
    opts: Options,
    diag: ?*Diagnostic,
) Error!Report {
    if (stack.entries.len == 0) return error.NoDepot;

    // `abspath(depot, ...)` is applied by both sides of every comparison below
    // -- `find_installed` builds keep-paths with it (`Operations.jl:36`) and
    // the sweep builds candidate paths with it (`:914`) -- so the roots are
    // normalised ONCE here and plain-joined afterwards. Skip this and a
    // `JULIA_DEPOT_PATH` entry with a trailing slash produces `<d>//packages`
    // on one side and `<d>/packages` on the other, and every install in that
    // depot reads as garbage.
    const all_depots = try arena.alloc([]const u8, stack.entries.len);
    for (stack.entries, 0..) |e, i| all_depots[i] = try absPath(arena, io, e);

    // "Only look at user-depot unless force=true" (`:599-600`).
    const gc_depots: []const []const u8 = if (opts.force) all_depots else all_depots[0..1];

    const gc_time = opts.now orelse usage.nowLocal(gpa, io);
    const gc_ms = usage.toEpochMillis(gc_time);

    // --- phase 1: read the logs -------------------------------------------
    const logs = try arena.alloc(DepotLogs, gc_depots.len);
    // Every slot is a valid, closed `DepotLogs` BEFORE the defer below is
    // armed: `fill` can fail on any depot, and running `deinit` over
    // uninitialised memory would close a garbage fd.
    for (logs, gc_depots) |*l, d| l.* = .{ .root = d };
    // The locks are held from the read until the condensed write, which is the
    // only way they mean anything: the whole operation is a read-modify-rewrite
    // and Pkg does not lock it at all, so a `write_env_usage` landing in the
    // window silently loses its key -- and a lost key is a live environment
    // that the NEXT gc collects. Acquisition order is deterministic (depot
    // order, then manifest/artifact/scratch) and every other writer takes at
    // most one, so no cycle exists.
    defer for (logs) |*l| l.deinit(io);
    for (logs) |*l| try l.fill(arena, io, diag);

    // --- phase 2: liveness -------------------------------------------------
    // "Next, figure out which files are still existent" (`:673-687`).
    var live_manifests: StringSet = .empty;
    defer live_manifests.deinit(gpa);
    var live_artifacts: StringSet = .empty;
    defer live_artifacts.deinit(gpa);
    var live_scratch: StringSet = .empty;
    defer live_scratch.deinit(gpa);
    var live_parents: StringSet = .empty;
    defer live_parents.deinit(gpa);

    for (logs) |l| {
        for (l.manifest.records) |r| {
            if (try isFile(io, r.path)) try live_manifests.put(gpa, r.path, {});
        }
        for (l.artifact.records) |r| {
            if (try isFile(io, r.path)) try live_artifacts.put(gpa, r.path, {});
        }
        for (l.scratch.records) |r| {
            if (try isDir(io, r.path)) try live_scratch.put(gpa, r.path, {});
        }
        // `all_scratch_parents` is unioned over the RAW parent sets, before the
        // per-depot filtering below mutates them (`:677-682` runs before
        // `:742`).
        for (l.scratch.records) |r| {
            for (r.parents) |p| {
                if (try isFile(io, p)) try live_parents.put(gpa, p, {});
            }
        }
    }

    // `filter!(p -> p in all_scratch_parents, parents)` (`:742`) mutates the
    // set stored in `scratch_parents_by_depot` IN PLACE, so every later reader
    // -- including `process_scratchspace` (`:825-845`) -- sees only parents
    // that still exist. Reproducing the mutation rather than the filter at each
    // use site is what keeps the two consumers in agreement.
    for (logs) |*l| l.filterParents(live_parents);

    // --- phase 3: condense the logs back down ------------------------------
    if (!opts.dry_run) {
        for (logs) |*l| try l.writeCondensed(gpa, arena, io, live_manifests, live_artifacts, live_scratch);
    }
    // The locks have done their job; the mark phase below reads manifests and
    // can take a while, and nothing after this point touches a usage log.
    for (logs) |*l| l.releaseLocks(io);

    const live_manifest_paths = try sortedKeys(arena, live_manifests);
    const live_artifact_paths = try sortedKeys(arena, live_artifacts);
    const live_scratch_paths = try sortedKeys(arena, live_scratch);

    var report: Report = .{ .dry_run = opts.dry_run };

    // --- phase 4a: mark packages -------------------------------------------
    var keep_packages: StringSet = .empty;
    defer keep_packages.deinit(gpa);
    var keep_repos: StringSet = .empty;
    defer keep_repos.deinit(gpa);

    // One read of each manifest feeds both `process_manifest_pkgs` (`:758-770`)
    // and `process_manifest_repos` (`:773-792`); Pkg reads it twice and leaves
    // a `# TODO: Merge with function above to not read manifest twice?` at
    // `:772`. The two are equivalent because the repo pass depends on nothing
    // the package pass computes, and a manifest that fails to read is inactive
    // for both.
    const depots1: depot_mod.Depot = .{ .root = all_depots[0] };
    for (live_manifest_paths) |path| {
        const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                warnManifest(path, @errorName(err));
                continue;
            },
        };
        const manifest = manifest_mod.parse(arena, src, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `@warn "Reading manifest file at $path failed with error"`
            // (`:763`), then `return nothing` -- the manifest counts as dead
            // and everything it pins becomes collectable. Said out loud
            // because that is the one warning in this whole command a user
            // must not miss.
            else => {
                warnManifest(path, @errorName(err));
                continue;
            },
        };
        report.active_manifests += 1;

        for (manifest.entries) |e| {
            // `if e.tree_hash !== nothing` (`:769`): a `path`/dev entry pins
            // nothing in `packages/`.
            const th = e.tree_hash orelse continue;
            const found = depot_mod.findInstalled(arena, io, .{ .entries = all_depots }, e.name, e.uuid, th) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.NoDepot => unreachable, // `all_depots` is non-empty
            };
            try keep_packages.put(gpa, found.path, {});
        }

        try markManifestRepos(gpa, arena, io, &keep_repos, depots1, path, manifest);
    }

    // "Do an initial scan of our depots to get a preliminary
    // `packages_to_delete`" (`:910-930`), with an EMPTY old orphanage -- so
    // every orphan's `free_time` is `gc_time` and the list is non-empty only
    // when `collect_delay` is zero. That is not an accident: it is what makes
    // `--all` reap an orphaned package's artifacts in the same pass, and a
    // default `Day(7)` run leave both alone.
    var doomed: std.ArrayList([]const u8) = .empty;
    for (gc_depots) |d| {
        var orphans: std.ArrayList([]const u8) = .empty;
        for (try (depot_mod.Depot{ .root = d }).listPackages(arena, io)) |p| {
            if (!keep_packages.contains(p.path)) try orphans.append(arena, p.path);
        }
        try mergeOrphanages(arena, null, orphans.items, &doomed, null, gc_time, gc_ms, opts.collect_delay_ms);
    }

    // --- phase 4b: mark artifacts, repos and scratchspaces -----------------
    // "Note that we MUST do this after calculating `packages_to_delete`"
    // (`:933-935`).
    var overrides = artifacts_mod.loadOverrides(arena, io, all_depots) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `load_overrides()` is called from `artifact_paths` with no guard; a
        // depot whose Overrides.toml cannot be read would throw there too.
        // Carrying on with no overrides would REDIRECT nothing and so keep the
        // un-overridden `artifacts/<hash>` -- the safe direction, and the only
        // one available without a second failure mode.
        else => artifacts_mod.Overrides.init(arena),
    };

    var keep_artifacts: StringSet = .empty;
    defer keep_artifacts.deinit(gpa);
    for (live_artifact_paths) |path| {
        const paths = try processArtifactsToml(arena, io, all_depots, &overrides, path, doomed.items, diag) orelse continue;
        report.active_artifacts += 1;
        for (paths) |p| try keep_artifacts.put(gpa, p, {});
    }

    var keep_spaces: StringSet = .empty;
    defer keep_spaces.deinit(gpa);
    for (live_scratch_paths) |path| {
        if (!keepScratchspace(logs, path, doomed.items)) continue;
        report.active_scratchspaces += 1;
        try keep_spaces.put(gpa, path, {});
    }

    // --- phase 5: orphanage -------------------------------------------------
    var to_delete: std.ArrayList(Deletion) = .empty;
    for (gc_depots) |d| {
        const d_depot: depot_mod.Depot = .{ .root = d };

        var orphan_packages: std.ArrayList([]const u8) = .empty;
        for (try d_depot.listPackages(arena, io)) |p| {
            if (!keep_packages.contains(p.path)) try orphan_packages.append(arena, p.path);
        }

        var orphan_repos: std.ArrayList([]const u8) = .empty;
        for (try d_depot.listClones(arena, io)) |p| {
            if (!keep_repos.contains(p)) try orphan_repos.append(arena, p);
        }

        var orphan_artifacts: std.ArrayList([]const u8) = .empty;
        for (try d_depot.listArtifacts(arena, io)) |p| {
            if (!keep_artifacts.contains(p)) try orphan_artifacts.append(arena, p);
        }

        var orphan_spaces: std.ArrayList([]const u8) = .empty;
        for (try d_depot.listScratchspaces(arena, io)) |s| {
            if (s.kind == .directory) {
                if (!keep_spaces.contains(s.path)) try orphan_spaces.append(arena, s.path);
            } else if (s.kind == .file and std.mem.eql(u8, s.uuid, pkg_uuid)) {
                // "special cleanup for the precompile cache files that Pkg
                // saves" (`:1019-1026`) -- the one place `gc` collects
                // something that is not a directory, and the one place it uses
                // an mtime rather than the orphanage.
                if (isStaleSuspendCache(io, s, opts)) try orphan_spaces.append(arena, s.path);
            }
        }

        const orphanage_path = try fspath.join(arena, &.{ d, "logs", orphaned_log });
        const old = try readOrphanage(arena, io, orphanage_path);
        const new_orphanage = try Table.create(arena);

        // The four categories in Pkg's own order (`:1039-1042`). Each one both
        // records the orphan and decides whether it has aged out.
        var packages_out: std.ArrayList([]const u8) = .empty;
        var artifacts_out: std.ArrayList([]const u8) = .empty;
        var repos_out: std.ArrayList([]const u8) = .empty;
        var spaces_out: std.ArrayList([]const u8) = .empty;
        try mergeOrphanages(arena, new_orphanage, orphan_packages.items, &packages_out, old, gc_time, gc_ms, opts.collect_delay_ms);
        try mergeOrphanages(arena, new_orphanage, orphan_artifacts.items, &artifacts_out, old, gc_time, gc_ms, opts.collect_delay_ms);
        try mergeOrphanages(arena, new_orphanage, orphan_repos.items, &repos_out, old, gc_time, gc_ms, opts.collect_delay_ms);
        try mergeOrphanages(arena, new_orphanage, orphan_spaces.items, &spaces_out, old, gc_time, gc_ms, opts.collect_delay_ms);

        // Written BEFORE anything is deleted, and written whether or not it is
        // empty -- `TOML.print` of an empty Dict is zero bytes, and the FILE's
        // existence is what `Pkg._auto_gc` stats to decide whether to collect
        // at all (`Pkg.jl:863-889`). "No matter what, store the free time in
        // the new orphanage. This allows something terrible to go wrong while
        // trying to delete ... and it will still try to be deleted next time"
        // (`:882-887`).
        if (!opts.dry_run) try writeOrphanage(gpa, arena, io, d, new_orphanage);

        for (packages_out.items) |p| try to_delete.append(arena, .{ .kind = .package, .path = p, .bytes = 0, .deleted = false });
        for (repos_out.items) |p| try to_delete.append(arena, .{ .kind = .repo, .path = p, .bytes = 0, .deleted = false });
        for (artifacts_out.items) |p| try to_delete.append(arena, .{ .kind = .artifact, .path = p, .bytes = 0, .deleted = false });
        for (spaces_out.items) |p| try to_delete.append(arena, .{ .kind = .scratchspace, .path = p, .bytes = 0, .deleted = false });
    }

    // --- phase 6: delete ---------------------------------------------------
    // Packages, then repos, then artifacts, then scratchspaces (`:1101-1114`).
    // `to_delete` is already grouped per depot; sorting by kind restores Pkg's
    // global order, which matters once `force` sweeps more than one depot.
    std.mem.sort(Deletion, to_delete.items, {}, struct {
        fn lt(_: void, a: Deletion, b: Deletion) bool {
            return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        }
    }.lt);

    for (to_delete.items) |*d| {
        d.bytes = depot_mod.treeSize(gpa, io, d.path);
        if (opts.dry_run) continue;
        if (depot_mod.removeTree(gpa, io, d.path)) |_| {
            d.deleted = true;
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            // `@warn("Failed to delete $path", ...)`; `return 0` (`:1085-1087`).
            else => std.debug.print("ajt gc: failed to delete {s}: {s}\n", .{ d.path, @errorName(err) }),
        }
    }

    if (!opts.dry_run) {
        for (gc_depots) |d| try pruneEmpty(arena, io, d);
    }

    report.deletions = to_delete.items;
    return report;
}

// ---------------------------------------------------------------------------
// Phase 1 + 3: the usage logs of one depot
// ---------------------------------------------------------------------------

const DepotLogs = struct {
    root: []const u8,
    /// `<depot>/logs`, open only when it exists. `null` means there is nothing
    /// to read and nothing to rewrite -- which is the state of a depot that has
    /// never been recorded into, not an error.
    dir: ?Io.Dir = null,
    locks: [3]?registry_ops.Lock = .{ null, null, null },

    manifest: usage.Usage = .{},
    artifact: usage.Usage = .{},
    scratch: usage.Usage = .{},
    /// Parallel to `scratch.records`, filtered in place at `:742`.
    scratch_parents: [][]const []const u8 = &.{},

    const names = [3][]const u8{ usage.manifest_log, usage.artifact_log, usage.scratch_log };

    /// Fills an ALREADY-CONSTRUCTED slot in place, rather than returning a
    /// value.
    ///
    /// That is not a style choice. Written as `logs[i] = try open(...)` with a
    /// local `self` and an `errdefer` that closed the directory, Zig's result
    /// location semantics place `self` AT `logs[i]` -- so on the error path the
    /// errdefer closed the fd and the caller's `defer ... deinit` closed it
    /// again, and `Io` traps the double close as an OS bug. Here `deinit` is
    /// the sole owner of everything this opens, from the moment it opens it.
    fn fill(self: *DepotLogs, arena: Allocator, io: Io, diag: ?*Diagnostic) Error!void {
        const logs_path = try fspath.join(arena, &.{ self.root, "logs" });
        self.dir = Io.Dir.cwd().openDir(io, logs_path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // No `logs/` at all: `isfile(usage_filepath)` is false for all
            // three (`:622`) and `isfile(usage_path)` is false at `:697`, so
            // nothing is read and nothing is written.
            else => return,
        };

        for (names, 0..) |name, i| {
            self.locks[i] = acquireLogLock(arena, io, self.dir.?, name) catch null;
            const path = try fspath.join(arena, &.{ logs_path, name });
            const want_parents = std.mem.eql(u8, name, usage.scratch_log);
            const u = usage.read(arena, io, path, .{ .parents = want_parents }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedUsageLog => {
                    if (diag) |d| d.path = path;
                    return error.MalformedUsageLog;
                },
            };
            switch (i) {
                0 => self.manifest = u,
                1 => self.artifact = u,
                else => self.scratch = u,
            }
        }

        self.scratch_parents = try arena.alloc([]const []const u8, self.scratch.records.len);
        for (self.scratch.records, 0..) |r, i| self.scratch_parents[i] = r.parents;
    }

    fn releaseLocks(self: *DepotLogs, io: Io) void {
        for (&self.locks) |*l| {
            if (l.*) |*lock| lock.release(io);
            l.* = null;
        }
    }

    fn deinit(self: *DepotLogs, io: Io) void {
        self.releaseLocks(io);
        if (self.dir) |*d| d.close(io);
        self.dir = null;
    }

    /// `filter!(p -> p in all_scratch_parents, parents)` (`:742`).
    fn filterParents(self: *DepotLogs, live: StringSet) void {
        for (self.scratch_parents, 0..) |ps, i| {
            var n: usize = 0;
            // The slice is arena-owned and private to this struct, so
            // compacting in place is exactly Julia's in-place `filter!` and
            // costs no allocation.
            //
            // It does leave `scratch.records[i].parents` STALE -- same
            // backing array, old length, reordered contents. Nothing reads it
            // after this point, and nothing should: `scratch_parents` is the
            // filtered view, and it is what both consumers (`writeCondensed`
            // and `keepScratchspace`) take. Julia has the same aliasing, since
            // its `filter!` mutates the very `Set` the parents map holds.
            const mutable = @constCast(ps);
            for (mutable) |p| {
                if (live.contains(p)) {
                    mutable[n] = p;
                    n += 1;
                }
            }
            self.scratch_parents[i] = mutable[0..n];
        }
    }

    /// `write_condensed_toml` (`:690-706`) for all three logs.
    fn writeCondensed(
        self: *DepotLogs,
        gpa: Allocator,
        arena: Allocator,
        io: Io,
        live_manifests: StringSet,
        live_artifacts: StringSet,
        live_scratch: StringSet,
    ) Error!void {
        const dir = self.dir orelse return;

        try self.writeOne(gpa, arena, io, dir, usage.manifest_log, self.manifest, live_manifests, null);
        try self.writeOne(gpa, arena, io, dir, usage.artifact_log, self.artifact, live_artifacts, null);
        try self.writeOne(gpa, arena, io, dir, usage.scratch_log, self.scratch, live_scratch, self.scratch_parents);
    }

    fn writeOne(
        self: *DepotLogs,
        gpa: Allocator,
        arena: Allocator,
        io: Io,
        dir: Io.Dir,
        name: []const u8,
        u: usage.Usage,
        live: StringSet,
        parents: ?[][]const []const u8,
    ) Error!void {
        const root = try Table.create(arena);
        for (u.records, 0..) |r, i| {
            // "Keep only ... markers that are still existent" (`:713`, `:725`,
            // `:735`).
            if (!live.contains(r.path)) continue;

            const entry = try Table.create(arena);
            try entry.put(arena, "time", .{ .datetime = r.time });
            if (parents) |ps| {
                // "Drop scratch spaces whose parents are all non-existent"
                // (`:740-745`). Note this drops the KEY from the log while
                // leaving the directory itself to be judged by
                // `process_scratchspace`, which may still keep it on the
                // strength of another depot's log.
                if (ps[i].len == 0) continue;
                const items = try arena.alloc(Value, ps[i].len);
                for (ps[i], 0..) |p, k| items[k] = .{ .string = p };
                try entry.put(arena, "parent_projects", .{ .array = items });
            }
            const one = try arena.alloc(Value, 1);
            one[0] = .{ .table = entry };
            try root.put(arena, r.path, .{ .array = one });
        }

        // `if !(isempty(usage)::Bool) || isfile(usage_path)` (`:697`): an empty
        // result still TRUNCATES an existing log to zero bytes rather than
        // leaving stale keys in it.
        if (root.count() == 0) {
            const exists = dir.statFile(io, name, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (exists.kind != .file) return;
        }

        const rendered = toml_emit.emitAlloc(gpa, root, .{ .sorted = true }) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        };
        defer gpa.free(rendered);
        writeAtomic(io, dir, name, rendered) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // FATAL, not a warning. Julia's `open(usage_path, "w")` (`:699`)
            // throws, and it throws in phase 3 — before a single path has been
            // marked, let alone deleted. See `Error.DepotNotWritable`: a run
            // that cannot write its own bookkeeping must not go on to unlink
            // anything.
            else => {
                std.debug.print(
                    "ajt gc: could not rewrite {s}/logs/{s} ({s})\n",
                    .{ self.root, name, @errorName(err) },
                );
                return error.DepotNotWritable;
            },
        };
    }
};

fn acquireLogLock(arena: Allocator, io: Io, dir: Io.Dir, log_name: []const u8) !registry_ops.Lock {
    return registry_ops.acquireLock(io, dir, .{
        // The same `<log>.pid` name `write_env_usage` takes (`Types.jl:684`);
        // a different one would mean no mutual exclusion against a concurrent
        // `julia` at all.
        .name = try std.fmt.allocPrint(arena, "{s}.pid", .{log_name}),
        .dir_label = "logs",
        .stale_age_s = 3,
        .refresh_s = 1.5,
    });
}

// ---------------------------------------------------------------------------
// Phase 4: marking
// ---------------------------------------------------------------------------

/// `process_manifest_repos` (`API.jl:773-792`).
///
/// **The `clones/` naming asymmetry lives here, and it is Pkg's, not a bug to
/// be fixed.** This recomputes `Types.add_repo_cache_path(url)` --
/// `clones/<string(hash(url))>`, `depot.zig`'s `cloneUrlDir` -- for every live
/// manifest `repo.source`, and every directory under `clones/` that matches
/// none of them is orphaned. But `install_git` names its clone
/// `clones/<uuid>` (`Operations.jl:842-844`), a form this function can never
/// produce, so a `clones/<uuid>` directory is ALWAYS collected by `Pkg.gc()`
/// and re-cloned on the next install. Reproducing that faithfully is the
/// point; "fixing" it here would leave Ajt keeping directories Pkg deletes,
/// which is a divergence with no upside.
///
/// Two further details that are easy to lose:
///
///  * `add_repo_cache_path` joins onto `depots1()`, NOT onto the depot being
///    swept. Under `force` with a stacked `DEPOT_PATH` that means every clone
///    in a non-first depot matches nothing and is collected. Pkg's behaviour.
///  * A URL is hashed VERBATIM; a path source is `safe_realpath`ed first
///    (`:785-789`). The two are different keys for the same repository and Pkg
///    keeps both directories.
fn markManifestRepos(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    keep: *StringSet,
    depots1: depot_mod.Depot,
    manifest_path: []const u8,
    manifest: manifest_mod.Manifest,
) Error!void {
    const dir = fspath.dirname(manifest_path) orelse ".";
    for (manifest.entries) |e| {
        const source = e.repo_url orelse continue;
        const key = if (git_url.isUrl(source))
            source
        else blk: {
            const abs = if (fspath.isAbsolute(source))
                source
            else
                // `normpath(joinpath(dirname(path), e.repo.source))`.
                try fspath.resolve(arena, &.{ dir, source });
            break :blk try safeRealpath(arena, io, abs, 0);
        };
        try keep.put(gpa, try depots1.cloneUrlDir(arena, key), {});
    }
}

/// `process_artifacts_toml(path, pkgs_to_delete)` (`API.jl:794-823`).
///
/// `null` = this index file is not active, which is BOTH of Pkg's two exits:
/// the file lives under a package that is about to be deleted, or it does not
/// parse. The first is the ordering constraint the module header opens with.
fn processArtifactsToml(
    arena: Allocator,
    io: Io,
    all_depots: []const []const u8,
    overrides: *const artifacts_mod.Overrides,
    path: []const u8,
    doomed_packages: []const []const u8,
    diag: ?*Diagnostic,
) Error!?[]const []const u8 {
    // `any(startswith(path, package_dir) for package_dir in pkgs_to_delete)`
    // (`:800`). A bare prefix test with no separator check -- reproduced as
    // written, because a stricter one would keep artifacts Pkg reaps.
    for (doomed_packages) |pkg_dir| {
        if (std.mem.startsWith(u8, path, pkg_dir)) return null;
    }

    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        // Julia `@warn`s on ANY failure to read this file, not just a parse
        // error (`:804-809` wraps the whole `parse_toml` call). Said out loud
        // for the same reason `warnManifest` is: an index file that cannot be
        // read is an index file whose artifacts are about to be collected.
        else => {
            std.debug.print(
                "ajt gc: reading artifacts file at {s} failed ({s}); the artifacts it binds are now collectable\n",
                .{ path, @errorName(err) },
            );
            return null;
        },
    };
    const doc = toml_parse.parse(arena, src, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `@warn "Reading artifacts file at $path failed"; return nothing`
        // (`:806-809`).
        error.ParseFailed => {
            std.debug.print(
                "ajt gc: reading artifacts file at {s} failed to parse; the artifacts it binds are now collectable\n",
                .{path},
            );
            return null;
        },
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (doc.root.entries.items) |named| {
        // `isa(artifact_dict[name], Vector)` (`:815`): the platform-keyed form
        // is an array of tables, the platform-independent form a single table.
        const metas: []const Value = switch (named.value) {
            .array => |a| a,
            .table => &.{named.value},
            // Julia would index a String/Int here and throw a MethodError.
            else => {
                if (diag) |d| d.path = path;
                return error.MalformedArtifactsToml;
            },
        };
        for (metas) |meta_v| {
            const meta = switch (meta_v) {
                .table => |t| t,
                else => {
                    if (diag) |d| d.path = path;
                    return error.MalformedArtifactsToml;
                },
            };
            // `SHA1(hex2bytes(meta["git-tree-sha1"]))` (`:813`) -- unguarded on
            // Pkg's side, so a missing or malformed hash throws out of
            // `Pkg.gc()` before it has deleted anything. Same here.
            const hex = switch (meta.get("git-tree-sha1") orelse {
                if (diag) |d| d.path = path;
                return error.MalformedArtifactsToml;
            }) {
                .string => |s| s,
                else => {
                    if (diag) |d| d.path = path;
                    return error.MalformedArtifactsToml;
                },
            };
            _ = depot_mod.Sha1.parse(hex) catch {
                if (diag) |d| d.path = path;
                return error.MalformedArtifactsToml;
            };

            // `artifact_paths(hash)` -- one candidate per depot, honouring
            // `Overrides.toml`, which is what makes an overridden artifact's
            // own directory collectable (`Artifacts.jl:224-234`).
            const paths = artifacts_mod.artifactPaths(arena, io, all_depots, hex, overrides, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            for (paths) |p| try out.append(arena, p);
        }
    }
    return out.items;
}

/// `process_scratchspace(path, pkgs_to_delete)` (`API.jl:825-845`).
///
/// The inverse lookup of every other marker: instead of parsing a file to find
/// paths inside it, this searches the already-parsed logs for files pointing AT
/// this directory. Pkg notes the awkwardness at `:829-832`.
///
/// `all(...)` over an EMPTY parent list is `true` in Julia, so a scratchspace
/// whose parents have all been filtered away (they no longer exist) is NOT
/// kept. That is the intended reading -- a scratchspace with no live parent is
/// exactly what this is meant to reap -- and it is worth being explicit about,
/// because the same expression written with `any` would keep it forever.
fn keepScratchspace(logs: []const DepotLogs, path: []const u8, doomed_packages: []const []const u8) bool {
    var saw_live_parent = false;
    for (logs) |l| {
        for (l.scratch.records, 0..) |r, i| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            for (l.scratch_parents[i]) |p| {
                var doomed = false;
                for (doomed_packages) |dir| {
                    if (std.mem.startsWith(u8, p, dir)) {
                        doomed = true;
                        break;
                    }
                }
                if (!doomed) saw_live_parent = true;
            }
        }
    }
    return saw_live_parent;
}

// ---------------------------------------------------------------------------
// Phase 5: the orphanage
// ---------------------------------------------------------------------------

/// `merge_orphanages!` (`API.jl:876-900`).
///
/// Every path is re-recorded in the new orphanage with the time it was FIRST
/// seen orphaned, and only paths that have been orphaned for at least
/// `collect_delay` join the deletion list. "The only time something is removed
/// from an orphanage is when it didn't exist before we even started the `gc`
/// run" (`:886-887`) -- i.e. the file is rewritten from scratch every time, so
/// a path that came back to life simply is not in the new one.
///
/// `new_orphanage` is null for the preliminary package scan at `:929`, which
/// passes a throwaway dict.
fn mergeOrphanages(
    arena: Allocator,
    new_orphanage: ?*Table,
    paths: []const []const u8,
    deletion_list: *std.ArrayList([]const u8),
    old: ?*const Table,
    gc_time: DateTime,
    gc_ms: i64,
    collect_delay_ms: i64,
) Allocator.Error!void {
    for (paths) |path| {
        // `something(get(old_orphanage, path, nothing), gc_time)` (`:878-881`).
        const free_time: DateTime = blk: {
            const o = old orelse break :blk gc_time;
            const v = o.get(path) orelse break :blk gc_time;
            const dt = switch (v) {
                .datetime => |x| x,
                // Julia would fail to `convert` a non-DateTime into
                // `UsageDict`. Reading it as "orphaned right now" is the safe
                // direction: it costs one more `collect_delay`, where the
                // alternative could delete on the strength of a value nobody
                // wrote.
                else => break :blk gc_time,
            };
            break :blk switch (dt.kind) {
                .datetime => dt,
                .date => .{ .kind = .datetime, .year = dt.year, .month = dt.month, .day = dt.day },
                .time => gc_time,
            };
        };

        if (new_orphanage) |t| try t.put(arena, path, .{ .datetime = free_time });

        // `if gc_time - free_time >= collect_delay` (`:895`). On first
        // orphaning the two are equal, so a default run deletes nothing and
        // only records -- which is the behaviour, not a bug in the gate.
        if (gc_ms - usage.toEpochMillis(free_time) >= collect_delay_ms) {
            try deletion_list.append(arena, path);
        }
    }
}

/// `TOML.parse(String(read(orphanage_file)))`, with Julia's bare `catch
/// UsageDict()` (`:1033-1038`).
///
/// An unreadable orphanage is genuinely safe to treat as empty, unlike a usage
/// log: every path in it is re-orphaned from scratch this run, so the only
/// consequence is that each one's clock restarts at `gc_time` and nothing is
/// deleted for another `collect_delay`.
fn readOrphanage(arena: Allocator, io: Io, path: []const u8) Io.Cancelable!?*const Table {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const doc = toml_parse.parse(arena, src, null) catch return null;
    return doc.root;
}

fn writeOrphanage(gpa: Allocator, arena: Allocator, io: Io, depot_root: []const u8, table: *const Table) Error!void {
    const rendered = toml_emit.emitAlloc(gpa, table, .{ .sorted = true }) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    defer gpa.free(rendered);

    // `mkpath(dirname(orphanage_file))` (`:1046`): unlike the condensed logs,
    // this one is created even in a depot that has no `logs/` at all -- which
    // is how a never-recorded depot ends up with an `orphaned.toml` and starts
    // ageing its contents.
    const logs_path = try fspath.join(arena, &.{ depot_root, "logs" });
    var dir = Io.Dir.cwd().createDirPathOpen(io, logs_path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("ajt gc: could not create {s} ({s})\n", .{ logs_path, @errorName(err) });
            return error.DepotNotWritable;
        },
    };
    defer dir.close(io);

    // FATAL. This is the single most important `return` in the file: the
    // orphanage is the ONLY record that a path was condemned, and phase 6 is
    // still ahead. Julia's bare `open` (`:1047`) throws here for the same
    // reason and never reaches `delete_path`.
    writeAtomic(io, dir, orphaned_log, rendered) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print(
                "ajt gc: could not write {s}/{s} ({s}); NOTHING was collected\n",
                .{ logs_path, orphaned_log, @errorName(err) },
            );
            return error.DepotNotWritable;
        },
    };
}

// ---------------------------------------------------------------------------
// Phase 6: pruning
// ---------------------------------------------------------------------------

/// "Prune package paths that are now empty" and the same for scratchspace UUID
/// folders (`API.jl:1117-1145`).
///
/// Non-recursive on purpose: `Base.rm(name_path)` with no `recursive`, guarded
/// by `isempty(readdir())`. A directory that acquired an entry between the two
/// calls survives, which is the whole safety property.
fn pruneEmpty(arena: Allocator, io: Io, depot_root: []const u8) Error!void {
    for ([_][]const u8{ "packages", "scratchspaces" }) |sub| {
        const root = try fspath.join(arena, &.{ depot_root, sub });
        for (try depot_mod.listDir(arena, io, root)) |e| {
            if (e.kind != .directory) continue;
            const path = try fspath.join(arena, &.{ root, e.name });
            const children = try depot_mod.listDir(arena, io, path);
            if (children.len != 0) continue;
            Io.Dir.cwd().deleteDir(io, path) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// `Base.abspath` = `normpath(joinpath(pwd(), path))`. Lexical, and
/// deliberately not `realpath` -- the same rule `ops/usage.zig` follows for log
/// keys, and for the same reason: a depot root that disagreed with the one
/// Julia spells would compare unequal against every `find_installed` result.
fn absPath(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    if (fspath.isAbsolute(path)) return fspath.resolve(arena, &.{path});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return arena.dupe(u8, path);
    return fspath.resolve(arena, &.{ buf[0..n], path });
}

/// `Pkg.safe_realpath` (`utils.jl:82-94`): "try to call realpath on as much as
/// possible". Resolves the longest existing prefix and re-attaches the rest
/// lexically, so a path that does not exist yet still gets its symlinks
/// resolved as far as they go.
fn safeRealpath(arena: Allocator, io: Io, path: []const u8, depth: usize) Allocator.Error![]const u8 {
    // Julia recurses on `splitdir` and is bounded by the path itself; the cap
    // is here only so a pathological input cannot blow the stack.
    if (depth >= 256) return arena.dupe(u8, path);
    if (pathExists(io, path)) {
        return Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch arena.dupe(u8, path);
    }
    const base = fspath.basename(path);
    // `isempty(b) && return path` -- "path cannot be reduced at the root or
    // drive, avoid stack overflow" (`:91-92`).
    if (base.len == 0) return arena.dupe(u8, path);
    const head = try safeRealpath(arena, io, fspath.dirname(path) orelse "", depth + 1);
    // `joinpath("", b) == b`.
    if (head.len == 0) return arena.dupe(u8, base);
    return fspath.join(arena, &.{ head, base });
}

fn pathExists(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// `Pkg.isfile_nothrow` (`utils.jl:107-114`) -- follows symlinks, demands a
/// regular file, and a stat error is `false` rather than an exception.
fn isFile(io: Io, path: []const u8) Io.Cancelable!bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return st.kind == .file;
}

/// `Pkg.isdir_nothrow` (`utils.jl:96-105`).
fn isDir(io: Io, path: []const u8) Io.Cancelable!bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return st.kind == .directory;
}

fn isStaleSuspendCache(io: Io, s: depot_mod.Scratch, opts: Options) bool {
    var matches = false;
    for (suspend_cache_prefixes) |prefix| {
        if (std.mem.startsWith(u8, s.key, prefix)) matches = true;
    }
    if (!matches) return false;

    const st = Io.Dir.cwd().statFile(io, s.path, .{ .follow_symlinks = false }) catch return false;
    const mtime_s: i64 = std.math.cast(i64, @divFloor(st.mtime.nanoseconds, std.time.ns_per_s)) orelse return false;
    const now_s = opts.now_unix_s orelse blk: {
        const raw = @divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
        break :blk std.math.cast(i64, raw) orelse return false;
    };
    return mtime_s < now_s - suspend_cache_max_age_s;
}

fn sortedKeys(arena: Allocator, set: StringSet) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, set.count());
    var it = set.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = e.key_ptr.*;
    // Hash order is not reproducible between runs, and the deletion ORDER is
    // user-visible; nothing here depends on the order semantically.
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

/// A sibling temp file plus `renameat`, in place of Julia's `open(path, "w")`.
/// A reader -- including a concurrent `julia` -- sees the whole old file or the
/// whole new one, never a truncated log. Julia's version can be observed
/// half-written.
fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var tmp_name: [tmp_prefix.len + 22]u8 = undefined;
    @memcpy(tmp_name[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(tmp_name[tmp_prefix.len..], &random_bytes);

    errdefer dir.deleteFile(io, &tmp_name) catch {};
    try dir.writeFile(io, .{ .sub_path = &tmp_name, .data = data });
    try Io.Dir.rename(dir, &tmp_name, dir, name, io);
}

const tmp_prefix = ".ajt-gc-";

fn warnManifest(path: []const u8, why: []const u8) void {
    // Julia's `@warn "Reading manifest file at $path failed with error"`
    // (`:763`). Loud because of what it implies: an unreadable manifest is a
    // manifest whose packages are about to become collectable.
    std.debug.print(
        "ajt gc: reading manifest file at {s} failed ({s}); everything it pins is now collectable\n",
        .{ path, why },
    );
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn stamp(y: u16, mo: u8, d: u8) DateTime {
    return .{ .kind = .datetime, .year = y, .month = mo, .day = d };
}

/// A scratch depot with `logs/`, so no test can reach a real one.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,
    /// Owned by the fixture. `Stack.entries` must point at storage that
    /// outlives the call; `&.{self.root}` would be a temporary whose lifetime
    /// ends with the accessor, which is a dangling slice by the time `run`
    /// reads it.
    entries: [1][]const u8 = undefined,

    fn init(io: Io) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        const root = try tmp.dir.realPathFileAlloc(io, ".", arena_state.allocator());
        return .{ .tmp = tmp, .arena_state = arena_state, .root = root, .entries = .{root} };
    }

    fn deinit(self: *Fixture) void {
        // Installs are published read-only, so the cleanup has to be able to
        // undo that or the temp directory leaks.
        depot_mod.prepareForDeletion(testing.allocator, testing.io, self.root) catch {};
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Fixture, sub: []const u8, data: []const u8) !void {
        if (fspath.dirname(sub)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn mkdir(self: *Fixture, sub: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, sub);
    }

    fn exists(self: *Fixture, sub: []const u8) bool {
        _ = self.tmp.dir.statFile(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn stack(self: *Fixture) depot_mod.Stack {
        return .{ .entries = &self.entries };
    }
};

test "a default run records orphans but deletes nothing" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    try f.write("packages/Foo/aBcDe/Project.toml", "name = \"Foo\"\n");

    // `free_time == gc_time` on first orphaning, so `gc_time - free_time` is
    // zero and the default `Day(7)` cannot be satisfied (`API.jl:895`). This
    // is the single most important thing about `gc` to get right: a gate that
    // ran with the default and saw nothing deleted would prove nothing.
    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{}, null);
    try testing.expectEqual(@as(usize, 0), r.deletions.len);
    try testing.expect(f.exists("packages/Foo/aBcDe"));

    // ...but it IS in the orphanage now, with today's date.
    const orphanage = try f.tmp.dir.readFileAlloc(io, "logs/orphaned.toml", f.arena(), .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, orphanage, "packages/Foo/aBcDe") != null);
}

test "an aged orphanage entry is collected, and the tree really goes" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe/src");
    try f.write("packages/Foo/aBcDe/src/Foo.jl", "module Foo end\n");
    try f.mkdir("artifacts/deadbeef");
    try f.write("artifacts/deadbeef/x", "x");
    // Read-only, the way an install is published -- the delete has to undo it.
    try depot_mod.setReadonlyPath(testing.allocator, io, try fspath.join(f.arena(), &.{ f.root, "packages/Foo/aBcDe" }));

    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);
    try testing.expectEqual(@as(usize, 2), r.deletions.len);
    for (r.deletions) |d| try testing.expect(d.deleted);
    try testing.expect(!f.exists("packages/Foo/aBcDe"));
    try testing.expect(!f.exists("artifacts/deadbeef"));
    // "Prune package paths that are now empty" (`:1117-1130`).
    try testing.expect(!f.exists("packages/Foo"));
    try testing.expect(f.exists("packages"));
}

test "a logged manifest keeps exactly what it pins" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    // StaticArrays at the tree hash whose slug is 0cEwi (see depot.zig).
    try f.mkdir("packages/StaticArrays/0cEwi");
    try f.mkdir("packages/StaticArrays/ffffff");
    try f.mkdir("env");
    const manifest_path = try fspath.join(f.arena(), &.{ f.root, "env", "Manifest.toml" });
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.StaticArrays]]
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\version = "1.9.0"
        \\
    );
    try f.write("logs/manifest_usage.toml", try std.fmt.allocPrint(
        f.arena(),
        "[[\"{s}\"]]\ntime = 2026-07-29T10:00:00.000Z\n",
        .{manifest_path},
    ));

    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);
    try testing.expectEqual(@as(usize, 1), r.active_manifests);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expectEqualStrings("ffffff", fspath.basename(r.deletions[0].path));
    try testing.expect(f.exists("packages/StaticArrays/0cEwi"));
    try testing.expect(!f.exists("packages/StaticArrays/ffffff"));
}

test "a usage log that does not parse collects nothing at all" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    try f.write("logs/manifest_usage.toml", "this is not = = toml");

    var diag: Diagnostic = .{};
    try testing.expectError(
        error.MalformedUsageLog,
        run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, &diag),
    );
    // The whole point: nothing was touched, and the file that stopped it is
    // named. "Treat it as empty" here would mean "nothing is reachable", i.e.
    // delete the depot.
    try testing.expect(f.exists("packages/Foo/aBcDe"));
    try testing.expect(std.mem.endsWith(u8, diag.path, "manifest_usage.toml"));
}

test "the condensed logs drop dead keys and keep parent_projects" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("env");
    try f.write("env/Manifest.toml", "manifest_format = \"2.0\"\n");
    try f.mkdir("scratchspaces/90137ffa-7385-5640-81b9-e52037218182/build");
    const live_manifest = try fspath.join(f.arena(), &.{ f.root, "env", "Manifest.toml" });
    const space = try fspath.join(f.arena(), &.{ f.root, "scratchspaces/90137ffa-7385-5640-81b9-e52037218182/build" });

    try f.write("logs/manifest_usage.toml", try std.fmt.allocPrint(f.arena(),
        \\[["{s}"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
        \\[["{s}"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\
        \\[["/nowhere/at/all/Manifest.toml"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\
    , .{ live_manifest, live_manifest }));
    try f.write("logs/scratch_usage.toml", try std.fmt.allocPrint(f.arena(),
        \\[["{s}"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\parent_projects = ["{s}", "/nowhere/at/all/Project.toml"]
        \\
    , .{ space, live_manifest }));

    _ = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);

    // Condensed to one entry per surviving key, at the MAXIMUM time; the key
    // that is no longer on disk is gone.
    const got = try f.tmp.dir.readFileAlloc(io, "logs/manifest_usage.toml", f.arena(), .limited(1 << 20));
    try testing.expectEqualStrings(try std.fmt.allocPrint(
        f.arena(),
        "[[\"{s}\"]]\ntime = 2026-01-01T00:00:00.000Z\n",
        .{live_manifest},
    ), got);

    // `parent_projects` survives, filtered to parents that still exist. A
    // condensing writer that dropped the key would make every later `Pkg.gc()`
    // throw a KeyError (`API.jl:664`).
    const scratch = try f.tmp.dir.readFileAlloc(io, "logs/scratch_usage.toml", f.arena(), .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, scratch, "parent_projects") != null);
    try testing.expect(std.mem.indexOf(u8, scratch, "/nowhere/at/all/Project.toml") == null);
    try testing.expect(std.mem.indexOf(u8, scratch, live_manifest) != null);
    // ...and the scratchspace itself was kept, because that parent is alive.
    try testing.expect(f.exists("scratchspaces/90137ffa-7385-5640-81b9-e52037218182/build"));
}

test "a scratchspace whose parents are all gone is collected, uuid dir and all" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("scratchspaces/90137ffa-7385-5640-81b9-e52037218182/build");
    const space = try fspath.join(f.arena(), &.{ f.root, "scratchspaces/90137ffa-7385-5640-81b9-e52037218182/build" });
    try f.write("logs/scratch_usage.toml", try std.fmt.allocPrint(f.arena(),
        \\[["{s}"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\parent_projects = ["/nowhere/at/all/Project.toml"]
        \\
    , .{space}));

    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);
    try testing.expectEqual(@as(usize, 0), r.active_scratchspaces);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expectEqual(Kind.scratchspace, r.deletions[0].kind);
    // "Prune scratch space UUID folders that are now empty" (`:1132-1145`).
    try testing.expect(!f.exists("scratchspaces/90137ffa-7385-5640-81b9-e52037218182"));
}

test "clones survive by url hash, and clones/<uuid> never does" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    const url = "https://github.com/JuliaLang/Example.jl.git";
    // The name Pkg's `add_repo_cache_path` computes for that url; the depot
    // gate pins it against `Pkg.Types.add_repo_cache_path` over 14k real URLs.
    try f.mkdir("clones/4643033083726148914");
    try f.mkdir("clones/15037770950778237535"); // the same repo without `.git`
    // `install_git`'s naming (`Operations.jl:842-844`). `process_manifest_repos`
    // can never produce it, so Pkg ALWAYS collects it. Not a bug to fix here.
    try f.mkdir("clones/90137ffa-7385-5640-81b9-e52037218182");

    try f.mkdir("env");
    const manifest_path = try fspath.join(f.arena(), &.{ f.root, "env", "Manifest.toml" });
    try f.write("env/Manifest.toml", try std.fmt.allocPrint(f.arena(),
        \\manifest_format = "2.0"
        \\
        \\[[deps.Example]]
        \\uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        \\repo-url = "{s}"
        \\repo-rev = "master"
        \\
    , .{url}));
    try f.write("logs/manifest_usage.toml", try std.fmt.allocPrint(
        f.arena(),
        "[[\"{s}\"]]\ntime = 2026-07-29T10:00:00.000Z\n",
        .{manifest_path},
    ));

    _ = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);
    try testing.expect(f.exists("clones/4643033083726148914"));
    // The URL is the key VERBATIM: dropping `.git` is a different clone.
    try testing.expect(!f.exists("clones/15037770950778237535"));
    try testing.expect(!f.exists("clones/90137ffa-7385-5640-81b9-e52037218182"));
}

test "an Artifacts.toml under a doomed package stops keeping its artifacts" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    // The artifact is referenced ONLY by an Artifacts.toml inside a package
    // that this same run is about to delete. `process_artifacts_toml` returns
    // `nothing` for it (`:794-802`) so the artifact is reaped too -- which is
    // the reason packages must be marked before artifacts.
    try f.mkdir("packages/Doomed/aBcDe");
    const art_toml = try fspath.join(f.arena(), &.{ f.root, "packages/Doomed/aBcDe/Artifacts.toml" });
    try f.write("packages/Doomed/aBcDe/Artifacts.toml",
        \\[thing]
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\
    );
    try f.mkdir("artifacts/246a8bb2e6667f832eea063c3a56aef96429a3db");
    try f.write("logs/artifact_usage.toml", try std.fmt.allocPrint(
        f.arena(),
        "[[\"{s}\"]]\ntime = 2026-07-29T10:00:00.000Z\n",
        .{art_toml},
    ));

    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null);
    try testing.expectEqual(@as(usize, 0), r.active_artifacts);
    try testing.expect(!f.exists("packages/Doomed/aBcDe"));
    try testing.expect(!f.exists("artifacts/246a8bb2e6667f832eea063c3a56aef96429a3db"));

    // ...and with the default delay NOTHING is doomed yet, so the very same
    // Artifacts.toml IS active and the artifact is kept. Same inputs, opposite
    // answer, decided entirely by the ordering.
    var f2 = try Fixture.init(io);
    defer f2.deinit();
    try f2.mkdir("packages/Doomed/aBcDe");
    const art2 = try fspath.join(f2.arena(), &.{ f2.root, "packages/Doomed/aBcDe/Artifacts.toml" });
    try f2.write("packages/Doomed/aBcDe/Artifacts.toml",
        \\[thing]
        \\git-tree-sha1 = "246a8bb2e6667f832eea063c3a56aef96429a3db"
        \\
    );
    try f2.mkdir("artifacts/246a8bb2e6667f832eea063c3a56aef96429a3db");
    try f2.write("logs/artifact_usage.toml", try std.fmt.allocPrint(
        f2.arena(),
        "[[\"{s}\"]]\ntime = 2026-07-29T10:00:00.000Z\n",
        .{art2},
    ));
    const r2 = try run(testing.allocator, f2.arena(), io, f2.stack(), .{}, null);
    try testing.expectEqual(@as(usize, 1), r2.active_artifacts);
    try testing.expectEqual(@as(usize, 0), r2.deletions.len);
}

test "a malformed Artifacts.toml collects nothing" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    const art_toml = try fspath.join(f.arena(), &.{ f.root, "Artifacts.toml" });
    try f.write("Artifacts.toml", "[thing]\nlazy = true\n"); // no git-tree-sha1
    try f.write("logs/artifact_usage.toml", try std.fmt.allocPrint(
        f.arena(),
        "[[\"{s}\"]]\ntime = 2026-07-29T10:00:00.000Z\n",
        .{art_toml},
    ));

    var diag: Diagnostic = .{};
    try testing.expectError(
        error.MalformedArtifactsToml,
        run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, &diag),
    );
    try testing.expect(f.exists("packages/Foo/aBcDe"));
    try testing.expectEqualStrings(art_toml, diag.path);
}

test "a depot whose logs/ cannot be written collects nothing" {
    // Makes a directory unwritable by mode, which is not how Windows denies
    // access -- and `Permissions.fromMode` does not exist there.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    try f.mkdir("logs");
    // Root-owned `logs/` in a container, a full disk, or `--force` reaching a
    // read-only image depot -- all the same shape. Julia's bare `open(..., "w")`
    // throws in phase 5, BEFORE `delete_path`, so `Pkg.gc()` deletes nothing;
    // warning and carrying on would unlink packages with no record that it
    // happened.
    const logs = try fspath.join(f.arena(), &.{ f.root, "logs" });
    try Io.Dir.cwd().setFilePermissions(io, logs, .fromMode(0o555), .{});
    defer Io.Dir.cwd().setFilePermissions(io, logs, .fromMode(0o755), .{}) catch {};

    try testing.expectError(
        error.DepotNotWritable,
        run(testing.allocator, f.arena(), io, f.stack(), .{ .collect_delay_ms = 0 }, null),
    );
    try testing.expect(f.exists("packages/Foo/aBcDe"));
}

test "a dry run writes nothing and deletes nothing" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{
        .collect_delay_ms = 0,
        .dry_run = true,
    }, null);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expect(!r.deletions[0].deleted);
    try testing.expect(f.exists("packages/Foo/aBcDe"));
    // No orphanage either: a dry run that aged the orphanage would make the
    // NEXT real run delete things the user never saw a plan for.
    try testing.expect(!f.exists("logs/orphaned.toml"));
}

test "an aged orphanage entry survives a run that could not delete it" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("packages/Foo/aBcDe");
    // A first run at the default delay records the orphan at `gc_time`...
    _ = try run(testing.allocator, f.arena(), io, f.stack(), .{ .now = stamp(2026, 1, 1) }, null);
    // ...and a second run a week later collects it, on the strength of the
    // FIRST run's timestamp rather than its own.
    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{ .now = stamp(2026, 1, 9) }, null);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expect(!f.exists("packages/Foo/aBcDe"));

    // The orphanage still NAMES the path it just deleted, because it is
    // written before the delete is attempted ("something terrible to go wrong
    // ... will still try to be deleted next time", `API.jl:882-887`). It is
    // the run AFTER that drops it, by which time it is not on disk to be
    // orphaned -- "the only time something is removed from an orphanage is
    // when it didn't exist before we even started".
    const before = try f.tmp.dir.readFileAlloc(io, "logs/orphaned.toml", f.arena(), .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, before, "packages/Foo/aBcDe") != null);
    _ = try run(testing.allocator, f.arena(), io, f.stack(), .{ .now = stamp(2026, 1, 10) }, null);
    const after = try f.tmp.dir.readFileAlloc(io, "logs/orphaned.toml", f.arena(), .limited(1 << 20));
    try testing.expectEqualStrings("", after);
}

test "Pkg's own suspend_cache markers age out on their own timer" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("scratchspaces/" ++ pkg_uuid);
    try f.write("scratchspaces/" ++ pkg_uuid ++ "/suspend_cache_abc", "");
    try f.write("scratchspaces/" ++ pkg_uuid ++ "/keep_me", "");
    // Another package's scratchspace directory holding a FILE: not Pkg's uuid,
    // so the file is invisible to `gc` entirely (`:1018-1026` only looks under
    // `Operations.PkgUUID`).
    try f.mkdir("scratchspaces/90137ffa-7385-5640-81b9-e52037218182");
    try f.write("scratchspaces/90137ffa-7385-5640-81b9-e52037218182/other", "");

    // Pretend it is a year from now, so the just-written marker is stale.
    const a_year: i64 = 365 * 24 * 60 * 60;
    const now_s = @divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);
    const r = try run(testing.allocator, f.arena(), io, f.stack(), .{
        .collect_delay_ms = 0,
        .now_unix_s = @as(i64, @intCast(now_s)) + a_year,
    }, null);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expect(!f.exists("scratchspaces/" ++ pkg_uuid ++ "/suspend_cache_abc"));
    try testing.expect(f.exists("scratchspaces/" ++ pkg_uuid ++ "/keep_me"));
    try testing.expect(f.exists("scratchspaces/90137ffa-7385-5640-81b9-e52037218182/other"));
}

test "only depots1() is swept unless force" {
    const io = testing.io;
    var f = try Fixture.init(io);
    defer f.deinit();

    try f.mkdir("first/packages/Foo/aBcDe");
    try f.mkdir("second/packages/Bar/aBcDe");
    const first = try fspath.join(f.arena(), &.{ f.root, "first" });
    const second = try fspath.join(f.arena(), &.{ f.root, "second" });
    const stack: depot_mod.Stack = .{ .entries = &.{ first, second } };

    const r = try run(testing.allocator, f.arena(), io, stack, .{ .collect_delay_ms = 0 }, null);
    try testing.expectEqual(@as(usize, 1), r.deletions.len);
    try testing.expect(!f.exists("first/packages/Foo/aBcDe"));
    try testing.expect(f.exists("second/packages/Bar/aBcDe"));

    const forced = try run(testing.allocator, f.arena(), io, stack, .{ .collect_delay_ms = 0, .force = true }, null);
    try testing.expectEqual(@as(usize, 1), forced.deletions.len);
    try testing.expect(!f.exists("second/packages/Bar/aBcDe"));
}
