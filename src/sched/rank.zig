//! Critical-path ranking — which ready task the frontier starts FIRST.
//!
//! ## What this is worth, stated up front so nobody oversells it later
//!
//! Priority ordering buys **1.05-1.15x on a 20-core box** and **under 5% on
//! the 2-CPU engine node**. On two cores the graph is work-bound, not
//! path-bound: with at most two things in flight there is barely a decision to
//! make, and the makespan is `total_work / 2` plus whatever the tail of the
//! longest chain adds. List scheduling only recovers the difference between a
//! bad order and a good one, and that difference shrinks as the machine
//! narrows.
//!
//! The big lever in the scheduler is **phase fusion** (1.3-1.5x: one frontier instead of
//! Pkg's four sequential phases, so a download and a precompile of unrelated
//! packages overlap at all). The lever after it is the **shared precompile
//! cache** (10x+, because the fastest build is the one that does not happen).
//! Ranking is here because it is nearly free once the graph exists — one
//! reverse pass over edges that are already materialised — not because it is
//! the project. Quote the phase-fusion number when someone asks what the
//! scheduler bought.
//!
//! ## The algorithm: HLFET, one reverse pass
//!
//! Highest Level First with Estimated Times, the textbook list-scheduling
//! heuristic (Adam, Chandy & Dickson 1974; surveyed in Kwok & Ahmad,
//! "Static scheduling algorithms for allocating directed task graphs to
//! multiprocessors", ACM Computing Surveys 31(4), 1999, §5.1). Each node gets
//! its **b-level** — the length of the longest path from it to any sink,
//! counting its own cost:
//!
//!     rank(n) = est_cost(n) + max over successors s of rank(s)
//!
//! and the frontier releases the highest-ranked ready node. The intuition is
//! the only one that matters: the work that gates the most remaining work
//! should not be the work that is still running when everything else is done.
//!
//! Computed in ONE reverse pass. `rank` is a max over successors, so
//! processing nodes in reverse topological order means every successor's value
//! is final before it is read. No fixpoint iteration, no recursion, no
//! memoisation table — Kahn's algorithm for the order, then a backwards walk.
//! O(V + E).
//!
//! ## Edge direction, which is the thing to get wrong
//!
//! `succ[i]` holds the nodes that must WAIT FOR `i` — for a package graph,
//! `succ[dep]` contains each package that depends on `dep`. That is the
//! REVERSE of the adjacency a manifest hands you (`deps = [...]` lists what a
//! package waits for). Pass the wrong direction and every number here is still
//! well-formed and completely meaningless: the ranking will start with the
//! top-level application and finish with the leaf JLLs, which is precisely
//! backwards. `successorsFromDependencies` does the flip; use it rather than
//! doing it inline and hoping.
//!
//! The adjacency is deliberately an abstract `[]const []const u32` rather than
//! a type from the graph module: this file has no idea what a package is, and
//! that keeps it testable on DAGs whose right answer is known by construction.
//!
//! ## Tie-breaking, and why the order is a total one
//!
//! Equal ranks are broken by DOWNSTREAM WEIGHT (total estimated cost of all
//! transitive successors — how much work this node unblocks in aggregate,
//! rather than along one path), then by OUT-DEGREE (how many tasks it unblocks
//! immediately, i.e. how much parallelism it exposes on the next step), then
//! by node index. The last one is not a real heuristic; it is there so the
//! order is TOTAL and therefore identical run to run. A scheduler whose plan
//! reshuffles between runs cannot be debugged from a log.
//!
//! Downstream weight is exact, computed with a reachability bitset in the same
//! reverse pass — summing successors' downstream values would double-count
//! every diamond, and a package graph is mostly diamonds. Cost: `V*ceil(V/64)`
//! words of SCRATCH (freed before returning). At 214 nodes — this repo's
//! `Open-Reality/Manifest.toml` — that is 6.8 KB; at 5000 it is 3 MB; the whole
//! General registry would be 25 MB and no environment is the whole registry.
//!
//! ## Why costs are floored at 1
//!
//! With a zero-cost node, `rank` ties ALONG an edge (`rank(pred) = 0 + max ...
//! = rank(succ)`), the tie-breaks can then order a dependent ahead of its own
//! dependency, and the emitted list stops being readable as a plan. The
//! frontier would not actually run it early — it only ever releases ready
//! nodes — so this is a legibility bug rather than a correctness one, which is
//! exactly the kind that survives for months. Flooring every cost at 1 ms
//! makes `rank` strictly decrease along every edge, which makes the priority
//! order a valid topological order as a byproduct. That property is asserted
//! in the tests below and in `tools/diff_harness/sched_rank.sh`.
//!
//! ## The cost model: `<depot>/ajt/costs.toml`
//!
//! Measured build times per package, read at plan time and written back after
//! a run, so the estimate improves. Shape:
//!
//! ```toml
//! schema = 1
//!
//! [times]
//! Foo = 1234
//! ```
//!
//! Keys are opaque to this module — the caller picks them (a package name, or
//! `Name@version` if it wants versions to age separately). Values are
//! milliseconds.
//!
//! **It degrades, it never refuses.** A scheduler that will not start because
//! a cache of timings is corrupt is a worse tool than one that guesses:
//!
//!   * absent file        -> empty model -> every node gets `default_cost_ms`,
//!                           and uniform costs reduce ranking to pure graph
//!                           depth, which is still a sane plan;
//!   * package not listed -> `default_cost_ms`;
//!   * malformed TOML     -> ignored wholesale, `Health.parse_failed` set so
//!                           the caller can print a note;
//!   * `[times]` not a table, a value that is not a non-negative number, a
//!                           `schema` this build does not know -> ignored, with
//!                           the corresponding `Health` field set;
//!   * unwritable depot   -> the run still succeeds; only the learning is lost.
//!
//! With ONE deliberate exception, because degrading is not the same as
//! destroying: a file that is present but UNREADABLE (root-owned, EACCES,
//! past the size cap) is not treated as empty. `update` publishes by renaming
//! into the directory and so needs no permission on the file itself — reading
//! an unreadable model as empty would let it replace every previous run's
//! measurements with this one run's. So that case sets `Health.unreadable`,
//! `update` declines to write, and the estimates for this run fall back to the
//! default. `ops/usage.zig:544` refuses the analogous case on the same
//! grounds. A corrupt or wrong-schema file is deliberately NOT protected —
//! its contents are already unusable, so replacing it is a repair.
//!
//! New measurements are BLENDED, not replaced: `new = (old + measured + 1) / 2`.
//! One cold-cache run would otherwise pin a wildly high number and one warm
//! no-op run a wildly low one, and both would then steer every future plan.
//! Halving the error each run converges in three or four runs and still tracks
//! a machine that genuinely got faster.
//!
//! ## Allocation
//!
//! `compute` returns a bundle: every slice in the `Ranking` belongs to the
//! `arena` it was given and none of it needs individual freeing. `gpa` is
//! scratch only — the topological order, the in-degree counters and the
//! reachability bitset are all taken from it and returned before `compute`
//! does. `CostModel` likewise hangs entirely off one arena.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const toml_parse = @import("../toml/parse.zig");
const toml_emit = @import("../toml/emit.zig");
const toml_value = @import("../toml/value.zig");

const Table = toml_value.Table;

// ---------------------------------------------------------------------------
// Costs
// ---------------------------------------------------------------------------

/// What a node costs when nothing has ever been measured for it. One second is
/// the right order of magnitude for a Julia package precompile; the exact
/// value is irrelevant when it applies to EVERY node (ranking is
/// scale-invariant then) and only matters as the stand-in for the unmeasured
/// nodes in a partially-warm model.
pub const default_cost_ms: u64 = 1000;

/// Ceiling on any single cost, measured or recorded: 24 hours.
///
/// Not tidiness. `rank` sums costs along a path and `downstream` sums them
/// over a reachable set, so one hand-edited `Foo = 9223372036854775807` would
/// both dominate every rank and risk overflowing the accumulators. Clamping at
/// the entry point means every arithmetic below is bounded by
/// `V * max_cost_ms` — at the u32 node limit that is 2^32 * 8.64e7 ~ 3.7e17,
/// comfortably inside u64.
pub const max_cost_ms: u64 = 24 * 60 * 60 * 1000;

/// Every cost that reaches the arithmetic goes through here: floored at 1 so
/// `rank` strictly decreases along edges (see the module header), capped at
/// `max_cost_ms` so the sums cannot run away.
pub fn clampCost(ms: u64) u64 {
    return std.math.clamp(ms, 1, max_cost_ms);
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

pub const Error = error{
    /// The successor adjacency has a cycle. A build graph with a cycle cannot
    /// be scheduled AT ALL — the frontier would deadlock on it with or without
    /// ranking — so this is reported rather than worked around. It is not the
    /// ranking refusing to start.
    Cycle,
    /// A successor index is >= the node count, or the node count exceeds the
    /// u32 index space. Returned rather than asserted because the adjacency is
    /// built by another module and a release build must not read out of bounds
    /// on its behalf.
    NodeOutOfRange,
    /// `cost.len != succ.len`. Two parallel arrays that disagree about how
    /// many nodes there are is a caller bug worth naming.
    LengthMismatch,
} || Allocator.Error;

/// The plan. All slices are `arena`-owned and parallel: index `i` is node `i`,
/// except `order`, which is a permutation OF node indices.
pub const Ranking = struct {
    /// b-level: `est_cost(n) + max over successors rank(s)`, in milliseconds.
    /// A sink's rank is its own cost. Strictly decreasing along every edge.
    rank: []const u64,
    /// Total estimated cost of everything transitively downstream of `n`,
    /// excluding `n` itself. The first tie-break.
    downstream: []const u64,
    /// `succ[n].len`, kept so the comparator and the caller need not hold the
    /// adjacency. The second tie-break.
    out_degree: []const u32,
    /// Node indices, highest priority first. Because costs are floored at 1
    /// this is also a valid topological order of the graph.
    order: []const u32,
    /// Inverse of `order`: `position[n]` is where `n` sits in it. This is what
    /// a frontier's ready-queue should compare — one `u32` load instead of a
    /// three-key comparison, and it is a total order by construction.
    position: []const u32,

    /// "Does `a` come before `b` in the plan?" Total, antisymmetric, stable
    /// across runs.
    pub fn before(self: Ranking, a: u32, b: u32) bool {
        return self.position[a] < self.position[b];
    }

    pub fn len(self: Ranking) usize {
        return self.rank.len;
    }

    /// The first `k` of `order`, clipped. For reports and eyeball review.
    pub fn top(self: Ranking, k: usize) []const u32 {
        return self.order[0..@min(k, self.order.len)];
    }

    /// The critical path itself, starting at `start` and following the
    /// highest-ranked successor at each step — the chain whose length IS
    /// `rank[start]`. `succ` must be the same adjacency `compute` was given.
    ///
    /// Arena-allocated; the caller owns nothing individually. Terminates
    /// because `rank` strictly decreases along every edge.
    pub fn path(
        self: Ranking,
        arena: Allocator,
        succ: []const []const u32,
        start: u32,
    ) Allocator.Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        var cur = start;
        while (true) {
            try out.append(arena, cur);
            var best: ?u32 = null;
            for (succ[cur]) |s| {
                if (best == null or self.before(s, best.?)) best = s;
            }
            cur = best orelse break;
        }
        return out.items;
    }
};

/// Rank every node in one reverse pass. See the module header for what the
/// numbers mean and what they are worth.
///
/// `succ[i]` lists the nodes that must wait for `i` (dependency -> dependent).
/// `cost[i]` is node `i`'s estimated cost in milliseconds; use `estimates` to
/// build it from a `CostModel`.
///
/// The returned `Ranking` is arena-allocated. `gpa` is scratch and is fully
/// released before this returns.
pub fn compute(
    gpa: Allocator,
    arena: Allocator,
    succ: []const []const u32,
    cost: []const u64,
) Error!Ranking {
    if (cost.len != succ.len) return error.LengthMismatch;
    const n = succ.len;
    if (n > std.math.maxInt(u32)) return error.NodeOutOfRange;

    const rank_out = try arena.alloc(u64, n);
    const down_out = try arena.alloc(u64, n);
    const outdeg = try arena.alloc(u32, n);
    const order = try arena.alloc(u32, n);
    const position = try arena.alloc(u32, n);
    if (n == 0) {
        return .{ .rank = rank_out, .downstream = down_out, .out_degree = outdeg, .order = order, .position = position };
    }

    // --- in-degrees, with bounds validation folded in ------------------------
    const indeg = try gpa.alloc(u32, n);
    defer gpa.free(indeg);
    @memset(indeg, 0);
    for (succ, 0..) |ss, i| {
        outdeg[i] = std.math.cast(u32, ss.len) orelse return error.NodeOutOfRange;
        for (ss) |s| {
            if (s >= n) return error.NodeOutOfRange;
            // A duplicate edge is counted twice here and decremented twice
            // below, so it is harmless rather than a hang.
            indeg[s] += 1;
        }
    }

    // --- Kahn's algorithm; a LIFO because the order among ready nodes is
    // irrelevant to a reverse pass and a stack needs no head index ------------
    const topo = try gpa.alloc(u32, n);
    defer gpa.free(topo);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.ensureTotalCapacityPrecise(gpa, n);
    for (0..n) |i| {
        if (indeg[i] == 0) stack.appendAssumeCapacity(@intCast(i));
    }
    var seen: usize = 0;
    while (stack.pop()) |i| {
        topo[seen] = i;
        seen += 1;
        for (succ[i]) |s| {
            indeg[s] -= 1;
            if (indeg[s] == 0) stack.appendAssumeCapacity(s);
        }
    }
    // Kahn's completeness criterion: anything left with a non-zero in-degree
    // is on, or downstream of, a cycle.
    if (seen != n) return error.Cycle;

    // --- the one reverse pass ------------------------------------------------
    // `reach[i]` is the set of nodes transitively downstream of `i`. Union of
    // the successors' sets plus the successors themselves; exact, so diamonds
    // are not double-counted.
    const words = (n + 63) / 64;
    // `n * words` is ~2^58 at the u32 node ceiling, so it cannot overflow a
    // 64-bit usize -- but a 32-bit target would TRAP on the multiply in a safe
    // build rather than fail the allocation, and "ran out of memory" is the
    // honest answer either way.
    const reach = try gpa.alloc(u64, std.math.mul(usize, n, words) catch return error.OutOfMemory);
    defer gpa.free(reach);
    @memset(reach, 0);

    var k = n;
    while (k > 0) {
        k -= 1;
        const i = topo[k];
        const row = reach[i * words ..][0..words];

        var longest: u64 = 0;
        for (succ[i]) |s| {
            longest = @max(longest, rank_out[s]);
            // `s != i` -- a self-loop is a cycle and was rejected above -- so
            // these two rows never alias and the OR is well defined.
            const srow = reach[s * words ..][0..words];
            for (row, srow) |*w, sw| w.* |= sw;
            row[s / 64] |= @as(u64, 1) << @intCast(s % 64);
        }
        rank_out[i] = clampCost(cost[i]) + longest;

        var sum: u64 = 0;
        for (row, 0..) |w, wi| {
            var bits = w;
            while (bits != 0) {
                const b = @ctz(bits);
                bits &= bits - 1;
                const node = wi * 64 + b;
                // No bit at or above `n` is ever set: bits are only ever set
                // for a validated successor index, and unioned from rows with
                // the same property. Asserted rather than assumed because the
                // padding bits of the last word are the natural place for a
                // future sentinel (`solver/julia_set.zig` reserves exactly such
                // a bit), and adding one here would silently read past `cost`.
                std.debug.assert(node < n);
                sum += clampCost(cost[node]);
            }
        }
        down_out[i] = sum;
    }

    // --- the priority list ---------------------------------------------------
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        rank: []const u64,
        down: []const u64,
        outdeg: []const u32,

        fn less(ctx: @This(), a: u32, b: u32) bool {
            if (ctx.rank[a] != ctx.rank[b]) return ctx.rank[a] > ctx.rank[b];
            if (ctx.down[a] != ctx.down[b]) return ctx.down[a] > ctx.down[b];
            if (ctx.outdeg[a] != ctx.outdeg[b]) return ctx.outdeg[a] > ctx.outdeg[b];
            return a < b;
        }
    };
    std.mem.sort(u32, order, Ctx{ .rank = rank_out, .down = down_out, .outdeg = outdeg }, Ctx.less);
    for (order, 0..) |node, pos| position[node] = @intCast(pos);

    return .{
        .rank = rank_out,
        .downstream = down_out,
        .out_degree = outdeg,
        .order = order,
        .position = position,
    };
}

/// Flip a dependency adjacency (`deps[i]` = what `i` waits for) into the
/// successor adjacency `compute` wants (`succ[i]` = who waits for `i`).
///
/// Exists because the natural direction everywhere else — a manifest, a
/// `Project.toml`, a registry `Deps.toml` — is the opposite of the one a
/// b-level pass needs, and doing the flip inline at each call site is how a
/// graph ends up ranked backwards. Arena-allocated.
pub fn successorsFromDependencies(
    arena: Allocator,
    deps: []const []const u32,
) Error![]const []const u32 {
    const n = deps.len;
    if (n > std.math.maxInt(u32)) return error.NodeOutOfRange;

    const counts = try arena.alloc(u32, n);
    defer arena.free(counts);
    @memset(counts, 0);
    for (deps) |ds| for (ds) |d| {
        if (d >= n) return error.NodeOutOfRange;
        counts[d] += 1;
    };

    const out = try arena.alloc([]u32, n);
    for (out, counts) |*slot, c| slot.* = try arena.alloc(u32, c);
    @memset(counts, 0);
    for (deps, 0..) |ds, i| for (ds) |d| {
        out[d][counts[d]] = @intCast(i);
        counts[d] += 1;
    };
    return out;
}

/// `cost[i]` for each key, from the model, falling back to `default_ms`.
/// Arena-allocated.
pub fn estimates(
    arena: Allocator,
    model: CostModel,
    keys: []const []const u8,
    default_ms: u64,
) Allocator.Error![]u64 {
    const out = try arena.alloc(u64, keys.len);
    for (out, keys) |*slot, key| slot.* = model.get(key) orelse default_ms;
    return out;
}

// ---------------------------------------------------------------------------
// The cost model
// ---------------------------------------------------------------------------

/// Bumped only if the MEANING of a number changes. An unknown schema makes the
/// whole file inert (with a note) rather than reinterpreted, because silently
/// reading seconds as milliseconds would produce a plan that looks fine and is
/// 1000x wrong.
pub const schema_version: i64 = 1;

/// Not machine-generated in the Pkg sense — it is a cache, and saying so stops
/// anyone treating a stale one as a bug report.
pub const banner =
    "# ajt cost model -- measured build times in milliseconds, used to order\n" ++
    "# the build frontier. Safe to delete; it will be re-learned.\n\n";

/// `<depot>/ajt/costs.toml`. Arena-allocated; touches no filesystem, so it is
/// safe to build for a depot that does not exist.
pub fn costsPath(arena: Allocator, depot_root: []const u8) Allocator.Error![]u8 {
    return fspath.join(arena, &.{ depot_root, "ajt", "costs.toml" });
}

/// Everything that was wrong with the file, so a caller can say so once and
/// carry on. Nothing here is an error; see the module header.
pub const Health = struct {
    /// A file was found at all. False means "first run", which is normal and
    /// deserves no note.
    present: bool = false,
    /// A file is there but could not be READ — root-owned, EACCES, past the
    /// size cap. Distinct from `present = false`, and the distinction is
    /// load-bearing: reading it as "empty" would make `update` rewrite the
    /// file with only this run's measurements and silently discard everything
    /// every previous run learned. `ops/usage.zig:544` refuses the analogous
    /// case for the same reason, and this follows it.
    unreadable: bool = false,
    /// The bytes are not TOML. The whole file is ignored.
    parse_failed: bool = false,
    /// `schema` is present and is not `schema_version`. The whole file is
    /// ignored.
    schema_mismatch: bool = false,
    /// `times` exists but is not a table. Ignored.
    shape_wrong: bool = false,
    /// Entries whose value was not a usable non-negative duration.
    dropped: usize = 0,
    /// Entries above `max_cost_ms`, clamped to it.
    clamped: usize = 0,
    /// Usable entries loaded.
    entries: usize = 0,

    pub fn healthy(self: Health) bool {
        return !self.unreadable and !self.parse_failed and !self.schema_mismatch and
            !self.shape_wrong and self.dropped == 0;
    }

    /// "Would rewriting this file lose anything?" True whenever the model on
    /// disk holds entries this process could not read, which is the one case
    /// where publishing a fresh file is destructive rather than merely
    /// wasteful. A corrupt or wrong-schema file is NOT preserved — its
    /// contents are already unusable, so replacing it is a repair.
    pub fn wouldClobber(self: Health) bool {
        return self.unreadable;
    }

    /// One line for a human, or null when there is nothing to say. Arena-owned.
    ///
    /// Two shapes, because the whole-file failures cannot honestly quote a
    /// count -- when the TOML does not parse there is no way to know how many
    /// timings were in it.
    pub fn note(self: Health, arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
        if (self.healthy()) return null;
        const why: ?[]const u8 = if (self.unreadable)
            "exists but could not be read"
        else if (self.parse_failed)
            "is not valid TOML"
        else if (self.schema_mismatch)
            "was written by a different ajt (unknown schema)"
        else if (self.shape_wrong)
            "has no usable [times] table"
        else
            null;
        if (why) |w| return try std.fmt.allocPrint(
            arena,
            "ajt: {s} {s}; ignoring it and using default build-time estimates\n",
            .{ path, w },
        );
        return try std.fmt.allocPrint(
            arena,
            "ajt: ignoring {d} unusable timing(s) in {s}; those packages get the default estimate\n",
            .{ self.dropped, path },
        );
    }
};

/// Measured times, keyed however the caller keys them. Arena-owned: both the
/// map and every key string live in the arena passed to `parse`/`load`.
pub const CostModel = struct {
    times: std.StringHashMapUnmanaged(u64) = .empty,
    health: Health = .{},

    pub fn get(self: CostModel, key: []const u8) ?u64 {
        return self.times.get(key);
    }

    /// The estimate this model would use, defaults included. Never fails.
    pub fn estimate(self: CostModel, key: []const u8, default_ms: u64) u64 {
        return self.times.get(key) orelse default_ms;
    }

    /// Blend a fresh measurement in. See the module header for why this halves
    /// the error rather than replacing outright.
    pub fn record(self: *CostModel, arena: Allocator, key: []const u8, measured_ms: u64) Allocator.Error!void {
        const clamped = @min(measured_ms, max_cost_ms);
        const gop = try self.times.getOrPut(arena, key);
        if (gop.found_existing) {
            gop.value_ptr.* = blend(gop.value_ptr.*, clamped);
        } else {
            // The map must own its keys: callers pass package names borrowed
            // from a manifest document whose arena is usually shorter-lived
            // than the model.
            gop.key_ptr.* = try arena.dupe(u8, key);
            gop.value_ptr.* = clamped;
        }
    }
};

/// `(old + measured + 1) / 2` — half the error each run, rounding up so a
/// 1 ms floor never decays to 0.
pub fn blend(old: u64, measured: u64) u64 {
    return (old +| measured +| 1) / 2;
}

/// Parse cost-model bytes. Total: any malformed input yields an empty model
/// with the corresponding `Health` flag, never an error other than OOM.
///
/// `arena` must be an ARENA (or another allocator reclaimed wholesale). The
/// returned `CostModel` owns a hash map and a copy of every key and has no
/// `deinit`, deliberately — it is a bundle with the lifetime of the plan it
/// feeds, and the two callers in this file both hand it an arena they drop.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!CostModel {
    var model: CostModel = .{ .health = .{ .present = true } };

    var doc = toml_parse.parse(arena, text, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => {
            model.health.parse_failed = true;
            return model;
        },
    };
    // Every string in the document belongs to the document's OWN child arena
    // (`toml/parse.zig:31` builds one from whatever allocator it is handed),
    // which this frees on the way out -- so every key kept below is COPIED.
    // `ops/usage.zig` carries the regression test for skipping that step: the
    // keys read as garbage and, at realistic sizes, segfault inside the
    // emitter.
    defer doc.deinit();
    const root = doc.root;

    if (root.get("schema")) |v| {
        const ok = switch (v) {
            .integer => |i| i == schema_version,
            else => false,
        };
        if (!ok) {
            model.health.schema_mismatch = true;
            return model;
        }
    }

    const times = switch (root.get("times") orelse return model) {
        .table => |t| t,
        else => {
            model.health.shape_wrong = true;
            return model;
        },
    };

    for (times.entries.items) |e| {
        const ms: u64 = switch (e.value) {
            .integer => |i| if (i < 0) {
                model.health.dropped += 1;
                continue;
            } else @intCast(i),
            // A hand-edited `Foo = 1.5` is a number and means what it looks
            // like; rejecting it would be pedantry. NaN and negatives are not.
            .float => |f| blk: {
                if (!std.math.isFinite(f) or f < 0) {
                    model.health.dropped += 1;
                    continue;
                }
                // Saturate BEFORE the conversion: `@intFromFloat` of a value
                // outside the destination range is illegal behaviour, and a
                // hand-edited `Foo = 1e300` is exactly how that arrives. The
                // saturated value then falls through to the same clamp (and
                // the same `clamped` count) as an oversized integer, rather
                // than being quietly capped here and reported as healthy.
                break :blk if (f >= @as(f64, @floatFromInt(max_cost_ms)))
                    std.math.maxInt(u64)
                else
                    @intFromFloat(f);
            },
            else => {
                model.health.dropped += 1;
                continue;
            },
        };
        if (ms > max_cost_ms) model.health.clamped += 1;
        // A duplicate key cannot reach here -- TOML rejects it at parse time.
        try model.times.put(arena, try arena.dupe(u8, e.key), @min(ms, max_cost_ms));
        model.health.entries += 1;
    }
    return model;
}

/// Read `<depot>/ajt/costs.toml`. A missing file, an unreadable one and a
/// corrupt one all yield a usable (possibly empty) model — see the module
/// header. Arena-owned.
pub fn load(arena: Allocator, io: Io, depot_root: []const u8) LoadError!CostModel {
    const path = try costsPath(arena, depot_root);
    // 64 MiB is ~2 million entries; anything larger is not this file.
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        // ABSENT and UNREADABLE are not the same thing, and conflating them is
        // destructive rather than merely imprecise. Absent is the normal
        // first-run path. Unreadable -- root-owned, EACCES, past the size cap
        // -- must be REMEMBERED, because `update` publishes by rename and
        // needs no permission on the file itself: carrying on as if the file
        // were empty would replace a model full of other runs' measurements
        // with a handful from this one. Losing one run's learning is much
        // cheaper. `ops/usage.zig:544` refuses the analogous case on the same
        // grounds.
        error.FileNotFound => return .{},
        else => return .{ .health = .{ .present = true, .unreadable = true } },
    };
    return parse(arena, bytes);
}

pub const LoadError = Allocator.Error || Io.Cancelable;

/// Render a model as the bytes of `costs.toml`, sorted. Caller owns the slice.
pub fn render(gpa: Allocator, model: CostModel) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try Table.create(arena);
    try root.put(arena, "schema", .{ .integer = schema_version });
    const times = try Table.create(arena);
    var it = model.times.iterator();
    while (it.next()) |e| {
        try times.put(arena, e.key_ptr.*, .{ .integer = @intCast(@min(e.value_ptr.*, max_cost_ms)) });
    }
    try root.put(arena, "times", .{ .table = times });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    // `Writer.Allocating` reports its own allocation failure as `WriteFailed`,
    // and there is no other writer here, so there is no other cause.
    aw.writer.writeAll(banner) catch return error.OutOfMemory;
    toml_emit.emit(gpa, &aw.writer, root, .{ .sorted = true }) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

pub const Measured = struct {
    key: []const u8,
    ms: u64,
};

/// What `update` managed to do. `written = false` is not an error: see below.
pub const Saved = struct {
    entries: usize = 0,
    written: bool = false,
};

/// Blend `measured` into `<depot>/ajt/costs.toml` and publish it atomically.
///
/// The file is RE-READ here rather than reusing whatever `load` returned at
/// plan time, so a concurrent ajt's entries mostly survive. There is no lock:
/// the temp-file + rename means a reader never sees a half-written file, and
/// the worst a lost update costs is one run's worth of learning about a few
/// packages. A pidfile lock would buy a timing cache stronger guarantees than
/// the depot's own package installs have.
///
/// Write failures are SWALLOWED — a read-only depot, a full disk or an
/// unwritable parent must not turn a successful build into a failed command.
/// The packages are built either way; only the estimate fails to improve.
/// Cancellation and OOM are not swallowed.
pub fn update(
    gpa: Allocator,
    io: Io,
    depot_root: []const u8,
    measured: []const Measured,
) LoadError!Saved {
    if (measured.len == 0) return .{};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = try load(arena, io, depot_root);
    // A file we could not read still HAS entries; publishing over it would
    // trade every previous run's learning for this one run's. Skip the write
    // and say so. (A corrupt or wrong-schema file is deliberately NOT
    // protected here -- its contents are already unusable, so replacing it is
    // a repair rather than a loss.)
    if (model.health.wouldClobber()) {
        std.debug.print(
            "ajt: {s}/ajt/costs.toml exists but could not be read; leaving it alone rather than " ++
                "replacing it with this run's timings alone\n",
            .{depot_root},
        );
        return .{ .entries = 0, .written = false };
    }
    for (measured) |m| try model.record(arena, m.key, m.ms);

    const bytes = try render(gpa, model);
    defer gpa.free(bytes);

    writeAtomic(arena, io, depot_root, bytes) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        // Said out loud rather than swallowed silently: a depot that never
        // learns looks exactly like one that has nothing to learn, and the
        // symptom (a plan that never improves) is invisible from the outside.
        else => {
            std.debug.print(
                "ajt: could not update {s}/ajt/costs.toml ({s}); build order will keep using the old estimates\n",
                .{ depot_root, @errorName(err) },
            );
            return .{ .entries = model.times.count(), .written = false };
        },
    };
    return .{ .entries = model.times.count(), .written = true };
}

fn writeAtomic(arena: Allocator, io: Io, depot_root: []const u8, bytes: []const u8) !void {
    const dir_path = try fspath.join(arena, &.{ depot_root, "ajt" });
    var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    // A SIBLING temp file, not `$TMPDIR`: `renameat` within one directory is
    // atomic by definition, while a cross-filesystem `mv` degrades to a copy
    // a reader can catch halfway.
    var tmp_name: [tmp_prefix.len + 22]u8 = undefined;
    @memcpy(tmp_name[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(tmp_name[tmp_prefix.len..], &random_bytes);

    // Armed BEFORE the write: a `writeFile` that fails partway still leaves a
    // file, and nothing ever sweeps this directory.
    errdefer dir.deleteFile(io, &tmp_name) catch {};
    try dir.writeFile(io, .{ .sub_path = &tmp_name, .data = bytes });
    try Io.Dir.rename(dir, &tmp_name, dir, "costs.toml", io);
}

const tmp_prefix = ".ajt-costs-";

// ---------------------------------------------------------------------------
// Tests
//
// There is no Julia oracle for a scheduling heuristic, so the DAGs below ARE
// the oracle: each one is built so its answer is forced by construction rather
// than merely plausible, and the comment on each says what forces it.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Ranks a graph with `gpa` as scratch and a caller-owned arena for the
/// result, which is what every test here wants.
fn rankFixture(arena: Allocator, succ: []const []const u32, cost: []const u64) !Ranking {
    return compute(testing.allocator, arena, succ, cost);
}

fn uniform(arena: Allocator, n: usize) ![]u64 {
    const c = try arena.alloc(u64, n);
    @memset(c, default_cost_ms);
    return c;
}

test "a long thin chain ranks head-first, and rank is the path length" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // 0 -> 1 -> 2 -> 3. Forced: only one topological order exists, and the
    // b-level of node i is (4 - i) * cost.
    const succ: []const []const u32 = &.{ &.{1}, &.{2}, &.{3}, &.{} };
    const r = try rankFixture(arena, succ, try uniform(arena, 4));

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, r.order);
    try testing.expectEqualSlices(u64, &.{ 4000, 3000, 2000, 1000 }, r.rank);
    // Downstream weight excludes the node itself.
    try testing.expectEqualSlices(u64, &.{ 3000, 2000, 1000, 0 }, r.downstream);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, try r.path(arena, succ, 0));
}

test "a wide shallow fan ranks the hub first and the leaves by index" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // 0 unblocks 1..5, which unblock nothing. Forced: the hub's b-level is
    // 2 units against every leaf's 1, and the leaves are indistinguishable in
    // rank, downstream (0) and out-degree (0), so only the index tie-break can
    // separate them -- which is exactly the property being pinned.
    const succ: []const []const u32 = &.{ &.{ 1, 2, 3, 4, 5 }, &.{}, &.{}, &.{}, &.{}, &.{} };
    const r = try rankFixture(arena, succ, try uniform(arena, 6));

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, r.order);
    try testing.expectEqual(@as(u64, 2000), r.rank[0]);
    try testing.expectEqual(@as(u64, 1000), r.rank[5]);
    // Five leaves at 1000 each.
    try testing.expectEqual(@as(u64, 5000), r.downstream[0]);
}

test "a thin chain beats a wide fan, which is the whole point of a b-level" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Two disjoint components under uniform cost:
    //   chain: 0 -> 1 -> 2 -> 3 -> 4        (b-level 5)
    //   fan:   5 -> {6,7,8,9,10,11,12,13}   (b-level 2, downstream 8000)
    // The fan carries FOUR TIMES the total work and still loses, because
    // starting it first cannot shorten the chain and the chain is what the
    // makespan is made of. A greedy most-work-first heuristic gets this
    // backwards; that is what the test is here to catch.
    const succ: []const []const u32 = &.{
        &.{1},                            &.{2}, &.{3}, &.{4}, &.{},
        &.{ 6, 7, 8, 9, 10, 11, 12, 13 }, &.{},  &.{},  &.{},  &.{},
        &.{},                             &.{},  &.{},  &.{},
    };
    const r = try rankFixture(arena, succ, try uniform(arena, 14));

    try testing.expectEqual(@as(u32, 0), r.order[0]);
    try testing.expect(r.before(0, 5));
    try testing.expect(r.before(1, 5)); // even the chain's SECOND node outranks the hub
    try testing.expect(r.before(2, 5));
    try testing.expectEqual(@as(u64, 5000), r.rank[0]);
    try testing.expectEqual(@as(u64, 2000), r.rank[5]);

    // Where the chain STOPS winning, which is the honest half of the claim.
    // Node 3 is the chain's last non-sink and ties the hub on rank (both 2000
    // -- one step of work then one sink). The tie goes to the hub on DOWNSTREAM
    // weight, 8000 against 1000, and that is the tie-break behaving as
    // designed: with the critical path no longer at stake, prefer the node that
    // unblocks more work. The first written expectation here said the opposite
    // and the implementation was right.
    try testing.expectEqual(@as(u64, 2000), r.rank[3]);
    try testing.expectEqual(@as(u64, 1000), r.downstream[3]);
    try testing.expectEqual(@as(u64, 8000), r.downstream[5]);
    try testing.expect(r.before(5, 3));
}

test "a diamond ranks the fork first and the join last" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // 0 -> {1,2} -> 3. Forced: 3 is the only sink, 0 the only source, and the
    // two middles are symmetric. The asymmetric cost below breaks the symmetry
    // in a direction that is decided by arithmetic, not by taste.
    const succ: []const []const u32 = &.{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} };
    const cost = try arena.alloc(u64, 4);
    cost[0] = 10;
    cost[1] = 50; // the heavy middle
    cost[2] = 5;
    cost[3] = 10;

    const r = try rankFixture(arena, succ, cost);
    try testing.expectEqualSlices(u64, &.{ 70, 60, 15, 10 }, r.rank);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, r.order);
    // The diamond is why downstream weight is computed exactly: node 3 is
    // reachable through both middles and must be counted ONCE.
    try testing.expectEqual(@as(u64, 65), r.downstream[0]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3 }, try r.path(arena, succ, 0));
}

test "a heavy leaf outranks a longer but cheap chain" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    //        0 (root, 1ms)
    //       / \
    //      1   2 -> 3 -> 4        1 costs 100ms; 2,3,4 cost 1ms each
    //
    // Forced both ways: under UNIFORM costs the three-node chain has b-level 3
    // against the leaf's 1 and must come first; under the real costs the leaf
    // has b-level 100 against the chain's 3 and must come first. The graph is
    // identical, so anything that changes is the cost model doing its job.
    const succ: []const []const u32 = &.{ &.{ 1, 2 }, &.{}, &.{3}, &.{4}, &.{} };

    const flat = try arena.alloc(u64, 5);
    @memset(flat, 1);
    const r_flat = try rankFixture(arena, succ, flat);
    try testing.expect(r_flat.before(2, 1));

    const measured = try arena.alloc(u64, 5);
    @memset(measured, 1);
    measured[1] = 100;
    const r_cost = try rankFixture(arena, succ, measured);
    try testing.expect(r_cost.before(1, 2));
    try testing.expectEqual(@as(u64, 101), r_cost.rank[0]);
}

test "zero costs are floored so the order stays a topological one" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Every cost is 0. Without the floor, rank is 0 everywhere, the rank and
    // downstream tie-breaks are all-equal, out-degree puts the fan-out node
    // first and the INDEX tie-break then orders 1 before 0 -- a dependent
    // ahead of its dependency.
    const succ: []const []const u32 = &.{ &.{}, &.{0}, &.{1} };
    const zero = try arena.alloc(u64, 3);
    @memset(zero, 0);

    const r = try rankFixture(arena, succ, zero);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, r.rank);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, r.order);
}

test "the priority order is always a valid topological order" {
    // The invariant that makes `order` readable as a plan. Checked over 200
    // pseudo-random DAGs (edges only ever point from a lower index to a higher
    // one, so acyclicity is by construction) with pseudo-random costs
    // including zeros. A fixed seed: a scheduler test that fails one run in
    // fifty is a test nobody will trust.
    var prng: std.Random.DefaultPrng = .init(0x5CEDA7A);
    const rnd = prng.random();

    for (0..200) |_| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        const arena = a.allocator();

        const n = 2 + rnd.uintLessThan(usize, 30);
        const succ = try arena.alloc([]u32, n);
        const cost = try arena.alloc(u64, n);
        for (0..n) |i| {
            var list: std.ArrayList(u32) = .empty;
            for (i + 1..n) |j| {
                if (rnd.uintLessThan(u8, 4) == 0) try list.append(arena, @intCast(j));
            }
            succ[i] = list.items;
            cost[i] = rnd.uintLessThan(u64, 2000);
        }

        const r = try compute(testing.allocator, arena, succ, cost);
        for (succ, 0..) |ss, i| {
            for (ss) |s| {
                try testing.expect(r.before(@intCast(i), s));
                // And the invariant the ordering rests on.
                try testing.expect(r.rank[i] > r.rank[s]);
            }
        }
    }
}

test "successorsFromDependencies flips the edges" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // "2 depends on 1, 1 depends on 0" -- the manifest direction.
    const deps: []const []const u32 = &.{ &.{}, &.{0}, &.{1} };
    const succ = try successorsFromDependencies(arena, deps);
    try testing.expectEqualSlices(u32, &.{1}, succ[0]);
    try testing.expectEqualSlices(u32, &.{2}, succ[1]);
    try testing.expectEqualSlices(u32, &.{}, succ[2]);

    // And the ranking that follows starts at the dependency, not the dependent
    // -- the failure this helper exists to prevent.
    const r = try rankFixture(arena, succ, try uniform(arena, 3));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, r.order);
}

test "a cycle is reported, not worked around" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const two: []const []const u32 = &.{ &.{1}, &.{0} };
    try testing.expectError(error.Cycle, rankFixture(arena, two, try uniform(arena, 2)));

    // A self-loop is the degenerate case and must not hang.
    const self: []const []const u32 = &.{&.{0}};
    try testing.expectError(error.Cycle, rankFixture(arena, self, try uniform(arena, 1)));

    // A cycle hanging off an otherwise fine graph still fails: Kahn only
    // counts what it drained.
    const tail: []const []const u32 = &.{ &.{1}, &.{2}, &.{1} };
    try testing.expectError(error.Cycle, rankFixture(arena, tail, try uniform(arena, 3)));
}

test "malformed adjacency is an error, not out-of-bounds" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const oob: []const []const u32 = &.{ &.{7}, &.{} };
    try testing.expectError(error.NodeOutOfRange, rankFixture(arena, oob, try uniform(arena, 2)));
    try testing.expectError(error.LengthMismatch, rankFixture(arena, oob, try uniform(arena, 3)));

    // The empty graph is legal and yields an empty plan.
    const r = try rankFixture(arena, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), r.len());
    try testing.expectEqual(@as(usize, 0), r.top(10).len);
}

test "duplicate edges do not deadlock the topological pass" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The same edge twice: in-degree is incremented twice and decremented
    // twice, so 1 still reaches zero. A guard that skipped the second
    // decrement would leave it stranded and report a phantom cycle.
    const succ: []const []const u32 = &.{ &.{ 1, 1 }, &.{} };
    const r = try rankFixture(arena, succ, try uniform(arena, 2));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, r.order);
    // Counted ONCE in the downstream weight, because reachability is a set.
    try testing.expectEqual(@as(u64, 1000), r.downstream[0]);
}

// --- cost model ------------------------------------------------------------

test "an absent cost model yields uniform estimates" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const model = try load(arena, testing.io, "/nonexistent-depot-for-ajt-tests");
    try testing.expect(!model.health.present);
    try testing.expect(model.health.healthy());
    try testing.expectEqual(@as(?[]const u8, null), try model.health.note(arena, "x"));

    const keys: []const []const u8 = &.{ "Foo", "Bar" };
    const cost = try estimates(arena, model, keys, default_cost_ms);
    try testing.expectEqualSlices(u64, &.{ default_cost_ms, default_cost_ms }, cost);
}

test "a package with no recorded time gets the default" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const model = try parse(arena,
        \\schema = 1
        \\
        \\[times]
        \\Foo = 4200
        \\
    );
    try testing.expect(model.health.healthy());
    try testing.expectEqual(@as(usize, 1), model.health.entries);
    try testing.expectEqual(@as(u64, 4200), model.estimate("Foo", default_cost_ms));
    try testing.expectEqual(default_cost_ms, model.estimate("NeverBuilt", default_cost_ms));
}

test "a malformed cost model is ignored with a note, never a failure" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const model = try parse(arena, "this is not = = toml");
    try testing.expect(model.health.present);
    try testing.expect(model.health.parse_failed);
    try testing.expectEqual(@as(usize, 0), model.health.entries);
    try testing.expectEqual(default_cost_ms, model.estimate("Foo", default_cost_ms));
    const note = (try model.health.note(arena, "/d/ajt/costs.toml")).?;
    try testing.expectEqualStrings(
        "ajt: /d/ajt/costs.toml is not valid TOML; ignoring it and using default build-time estimates\n",
        note,
    );

    // A future schema is inert rather than reinterpreted.
    const future = try parse(arena, "schema = 99\n[times]\nFoo = 1\n");
    try testing.expect(future.health.schema_mismatch);
    try testing.expectEqual(@as(usize, 0), future.health.entries);

    // A `times` that is not a table.
    const wrong = try parse(arena, "schema = 1\ntimes = 5\n");
    try testing.expect(wrong.health.shape_wrong);

    // Individual unusable values are dropped; the usable ones survive.
    const mixed = try parse(arena,
        \\[times]
        \\Good = 10
        \\Negative = -5
        \\Stringy = "slow"
        \\Floaty = 2.7
        \\Huge = 999999999999
        \\
    );
    try testing.expectEqual(@as(usize, 2), mixed.health.dropped);
    try testing.expectEqual(@as(usize, 1), mixed.health.clamped);

    // A float beyond u64 must saturate rather than reach `@intFromFloat`,
    // which is illegal behaviour outside the destination range, and must be
    // COUNTED as clamped rather than quietly capped and reported healthy.
    const huge_float = try parse(arena, "[times]\nBig = 1e300\nInf = inf\nNan = nan\n");
    try testing.expectEqual(max_cost_ms, huge_float.get("Big").?);
    try testing.expectEqual(@as(usize, 1), huge_float.health.clamped);
    try testing.expectEqual(@as(usize, 2), huge_float.health.dropped);
    try testing.expectEqual(@as(u64, 10), mixed.get("Good").?);
    try testing.expectEqual(@as(u64, 2), mixed.get("Floaty").?);
    try testing.expectEqual(max_cost_ms, mixed.get("Huge").?);
    try testing.expectEqual(@as(?u64, null), mixed.get("Negative"));
    try testing.expect(!mixed.health.healthy());
    const dropped_note = (try mixed.health.note(arena, "/d/ajt/costs.toml")).?;
    try testing.expectEqualStrings(
        "ajt: ignoring 2 unusable timing(s) in /d/ajt/costs.toml; those packages get the default estimate\n",
        dropped_note,
    );

    // The keys must outlive the TOML document they were read out of. Size is
    // what makes this bite -- two short keys fit in pages the arena happens to
    // hand back intact -- so this uses enough of them to move real pages.
    var src: std.Io.Writer.Allocating = .init(testing.allocator);
    defer src.deinit();
    try src.writer.writeAll("schema = 1\n\n[times]\n");
    for (0..120) |n| try src.writer.print("SomeLongPackageName_jll{d} = {d}\n", .{ n, n + 1 });
    const big = try parse(arena, src.written());
    try testing.expectEqual(@as(usize, 120), big.health.entries);
    for (0..120) |n| {
        var buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "SomeLongPackageName_jll{d}", .{n});
        try testing.expectEqual(@as(u64, n + 1), big.get(key).?);
    }
}

test "render is sorted, re-parses, and keeps the banner out of the way" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var model: CostModel = .{};
    try model.record(arena, "Zlib_jll", 12);
    try model.record(arena, "Accessors", 3400);
    try model.record(arena, "Weird Name@1.2", 7);

    const bytes = try render(testing.allocator, model);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.startsWith(u8, bytes, "# ajt cost model"));
    const body = bytes[banner.len..];
    try testing.expectEqualStrings(
        \\schema = 1
        \\
        \\[times]
        \\Accessors = 3400
        \\"Weird Name@1.2" = 7
        \\Zlib_jll = 12
        \\
    , body);

    // The point of the quoting: a key with a space and an `@` must survive its
    // own escaping, or every run would grow a second differently-spelled entry.
    const back = try parse(arena, bytes);
    try testing.expect(back.health.healthy());
    try testing.expectEqual(@as(u64, 7), back.get("Weird Name@1.2").?);
    try testing.expectEqual(@as(u64, 3400), back.get("Accessors").?);
}

test "recording blends rather than replacing" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var model: CostModel = .{};
    try model.record(arena, "Foo", 1000);
    try testing.expectEqual(@as(u64, 1000), model.get("Foo").?);
    // One absurd run moves the estimate halfway, not all the way.
    try model.record(arena, "Foo", 100000);
    try testing.expectEqual(@as(u64, 50500), model.get("Foo").?);
    // And it converges back.
    try model.record(arena, "Foo", 1000);
    try model.record(arena, "Foo", 1000);
    try model.record(arena, "Foo", 1000);
    try testing.expect(model.get("Foo").? < 8000);

    // Rounding up, so a 1 ms entry never decays to a 0 the floor would have to
    // rescue.
    try testing.expectEqual(@as(u64, 1), blend(1, 1));
    try testing.expectEqual(@as(u64, 1), blend(1, 0));
    // And saturation rather than a trap on a hostile pair.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) / 2), blend(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "the model round-trips through a real depot and changes the plan" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // Same shape as the heavy-leaf test: a one-node branch against a
    // three-node chain. Names are the cost-model keys.
    const names: []const []const u8 = &.{ "root", "heavy", "c1", "c2", "c3" };
    const succ: []const []const u32 = &.{ &.{ 1, 2 }, &.{}, &.{3}, &.{4}, &.{} };

    // 1. Cold depot: no file at all, so uniform estimates, so the chain wins.
    {
        const model = try load(arena, io, depot);
        try testing.expect(!model.health.present);
        const r = try compute(testing.allocator, arena, succ, try estimates(arena, model, names, default_cost_ms));
        try testing.expect(r.before(2, 1));
    }

    // 2. A run measures what actually happened.
    const saved = try update(testing.allocator, io, depot, &.{
        .{ .key = "heavy", .ms = 100_000 },
        .{ .key = "c1", .ms = 500 },
        .{ .key = "c2", .ms = 500 },
        .{ .key = "c3", .ms = 500 },
    });
    try testing.expect(saved.written);
    try testing.expectEqual(@as(usize, 4), saved.entries);

    // 3. The next plan reads them back and reverses the decision.
    {
        const model = try load(arena, io, depot);
        try testing.expect(model.health.present);
        try testing.expect(model.health.healthy());
        try testing.expectEqual(@as(u64, 100_000), model.get("heavy").?);
        const r = try compute(testing.allocator, arena, succ, try estimates(arena, model, names, default_cost_ms));
        try testing.expect(r.before(1, 2));
        // `root` was never measured and still gets the default.
        try testing.expectEqual(default_cost_ms, model.estimate("root", default_cost_ms));
    }

    // 4. A second update blends against what is on disk rather than starting
    //    over, and leaves no temp file behind.
    _ = try update(testing.allocator, io, depot, &.{.{ .key = "heavy", .ms = 0 }});
    const after = try load(arena, io, depot);
    try testing.expectEqual(@as(u64, 50_000), after.get("heavy").?);
    try testing.expectEqual(@as(u64, 500), after.get("c1").?);

    var dir = try tmp.dir.openDir(io, "ajt", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var names_seen: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expectEqualStrings("costs.toml", e.name);
        names_seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), names_seen);
}

test "an unreadable costs.toml is left alone rather than replaced" {
    // THE destructive case, and the one that distinguishes "absent" from
    // "present but unreadable". `update` publishes by rename into the
    // directory, which needs no permission on the FILE -- so treating an
    // EACCES read as an empty model would happily replace a model holding
    // every previous run's timings with the handful from this one.
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    if (builtin.os.tag == .windows) return;

    _ = try update(testing.allocator, io, depot, &.{.{ .key = "Learned", .ms = 4242 }});

    // A root-owned file cannot be simulated here, but mode 000 produces the
    // same read error for a non-root process.
    const unreadable: Io.File.Permissions = @enumFromInt(0o000);
    const readable: Io.File.Permissions = @enumFromInt(0o644);
    tmp.dir.setFilePermissions(io, "ajt/costs.toml", unreadable, .{}) catch return;
    defer tmp.dir.setFilePermissions(io, "ajt/costs.toml", readable, .{}) catch {};

    const model = try load(arena, io, depot);
    // Running as root (or on a filesystem that ignores the mode) reads it
    // anyway; skipping beats asserting the chmod took effect.
    if (!model.health.unreadable) return;
    try testing.expect(model.health.present);
    try testing.expect(!model.health.healthy());
    try testing.expect(model.health.wouldClobber());

    // The write must be REFUSED outright, not attempted and failed -- the
    // rename would have SUCCEEDED, which is the whole danger.
    const saved = try update(testing.allocator, io, depot, &.{.{ .key = "Fresh", .ms = 1 }});
    try testing.expect(!saved.written);

    // And the bytes on disk are untouched.
    try tmp.dir.setFilePermissions(io, "ajt/costs.toml", readable, .{});
    const after = try Io.Dir.cwd().readFileAlloc(io, try costsPath(arena, depot), arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, after, "Learned = 4242") != null);
    try testing.expect(std.mem.indexOf(u8, after, "Fresh") == null);
}

test "a corrupt costs.toml on disk still produces a plan" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try tmp.dir.createDirPath(io, "ajt");
    try tmp.dir.writeFile(io, .{ .sub_path = "ajt/costs.toml", .data = "[times\nFoo = " });

    const model = try load(arena, io, depot);
    try testing.expect(model.health.parse_failed);

    const succ: []const []const u32 = &.{ &.{1}, &.{} };
    const names: []const []const u8 = &.{ "Foo", "Bar" };
    const r = try compute(testing.allocator, arena, succ, try estimates(arena, model, names, default_cost_ms));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, r.order);

    // And the next write replaces it rather than inheriting the corruption.
    _ = try update(testing.allocator, io, depot, &.{.{ .key = "Foo", .ms = 42 }});
    const fixed = try load(arena, io, depot);
    try testing.expect(fixed.health.healthy());
    try testing.expectEqual(@as(u64, 42), fixed.get("Foo").?);
}
