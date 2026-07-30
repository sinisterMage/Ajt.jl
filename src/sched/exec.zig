//! The worker loop that drives a `graph.State` to completion.
//!
//! `graph.zig` owns the frontier's semantics — `unmet`/`blocked`, the `any`
//! arbitration, the cascade — and is deliberately free of I/O and threads.
//! This file adds the three things a real run needs on top of that, and
//! nothing else:
//!
//!   * **Priority.** `graph.State` hands back an unordered `Delta.admitted`;
//!     the ready set here is a min-heap on `rank.Ranking.position`, so the
//!     longest critical path goes first. `position` is a total order by
//!     construction, so the frontier is deterministic given the same costs.
//!   * **Throttling.** Each stage maps to a `resources.Class`, and a worker
//!     holds that class's permit for exactly as long as the action runs.
//!   * **Concurrency.** Workers pull from the heap; one mutex serialises every
//!     `State` call, which is what makes `State`'s single-threaded contract
//!     true in a threaded run.
//!
//! It contains no scheduling policy of its own. Anything that decides what may
//! run belongs in `graph.zig`, where it is testable without threads.
//!
//! ## Why the action returns only a bool
//!
//! `skipped` and `cancelled` are conclusions the state machine reaches, never
//! things an action reports: a worker cannot know that a rival alternative won
//! while it was running. It reports success or failure and `settle` decides the
//! rest — including discarding the result entirely when the node was cancelled
//! mid-flight, which is the documented resolution of that race.
//!
//! ## Cancellation is advisory
//!
//! Nothing here can stop a running worker. A cancelled node is settled at once
//! and the worker's eventual result is dropped, so actions must be safe to
//! abandon — which for this codebase they are: every one of them stages into a
//! temp and renames.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const graph_mod = @import("graph.zig");
const resources = @import("resources.zig");

const Graph = graph_mod.Graph;
const NodeId = graph_mod.NodeId;
const Stage = graph_mod.Stage;

pub const Error = error{
    /// `position.len` disagrees with the graph's node count.
    LengthMismatch,
} || Allocator.Error;

/// What a node costs to run, so the loop takes the right permit. `null` is
/// bookkeeping-only work — `Resolve` and `Ready` settle without doing anything,
/// and taking a permit for them would waste a slot and, for `cpu`, a memory
/// reservation no forked Julia is going to use.
pub fn classOf(stage: Stage) ?resources.Class {
    return switch (stage) {
        .fetch, .fetch_art => .net_pkgserver,
        .probe, .import, .publish => .net_cachestore,
        .verify, .install, .install_art, .verify_cache => .disk,
        .compile => .cpu,
        .resolve, .ready => null,
    };
}

/// The caller's per-node work. `ctx` is opaque so this file stays non-generic:
/// one instantiation however many callers it has.
///
/// Runs with no lock held. Returns true on success; the frontier concludes
/// everything else on its own.
pub const Action = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, io: Io, g: *const Graph, node: NodeId) bool,
};

pub const Options = struct {
    /// Upper bound on workers in flight across all classes. The real width is
    /// whatever the resource classes allow.
    workers: u32 = 1,
    /// Estimated resident set per compile, for the memory bucket.
    est_rss: u64 = resources.default_est_rss,
};

pub const Summary = struct {
    tally: graph_mod.Tally,
    nodes: usize,
    /// Every node settled. False means the loop ran out of both ready and
    /// in-flight work without finishing, which an acyclic graph cannot do — so
    /// it is an invariant check, not an expected outcome.
    complete: bool,
    /// A worker hit an allocation failure in the cascade. Reported rather than
    /// returned because the run still unwinds cleanly and the partial tally is
    /// worth having.
    oom: bool,
};

/// A min-heap of admitted nodes ordered by `position`. Capacity is `nodes.len`:
/// `State` admits each node at most once, so it cannot overflow.
const Heap = struct {
    items: []NodeId,
    len: usize = 0,
    position: []const u32,

    fn push(h: *Heap, n: NodeId) void {
        h.items[h.len] = n;
        h.len += 1;
        var i = h.len - 1;
        while (i != 0) {
            const parent = (i - 1) / 2;
            if (h.position[h.items[i]] >= h.position[h.items[parent]]) break;
            std.mem.swap(NodeId, &h.items[i], &h.items[parent]);
            i = parent;
        }
    }

    fn pop(h: *Heap) ?NodeId {
        if (h.len == 0) return null;
        const top = h.items[0];
        h.len -= 1;
        if (h.len == 0) return top;
        h.items[0] = h.items[h.len];
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            const r = l + 1;
            var best = i;
            if (l < h.len and h.position[h.items[l]] < h.position[h.items[best]]) best = l;
            if (r < h.len and h.position[h.items[r]] < h.position[h.items[best]]) best = r;
            if (best == i) return top;
            std.mem.swap(NodeId, &h.items[i], &h.items[best]);
            i = best;
        }
    }
};

const Shared = struct {
    gpa: Allocator,
    io: Io,
    graph: *const Graph,
    state: *graph_mod.State,
    delta: *graph_mod.Delta,
    heap: *Heap,
    pool: *resources.Pool,
    action: Action,
    opts: Options,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    in_flight: u32 = 0,
    /// Set when a worker cannot make progress — OOM in the cascade, a cancelled
    /// wait, or a frontier that emptied with nothing running. Keeps the other
    /// workers from waiting forever.
    giving_up: bool = false,
    oom: bool = false,
};

/// Drive the graph to completion.
///
/// Failure is data, not an error: a node whose action fails settles failed and
/// its dependents settle skipped, and the summary reports both. `position` is
/// `rank.Ranking.position` for this graph.
pub fn run(
    gpa: Allocator,
    io: Io,
    g: *const Graph,
    position: []const u32,
    pool: *resources.Pool,
    action: Action,
    opts: Options,
) Error!Summary {
    if (position.len != g.nodes.len) return error.LengthMismatch;
    if (g.nodes.len == 0) {
        return .{ .tally = .{}, .nodes = 0, .complete = true, .oom = false };
    }

    var state = try graph_mod.State.init(gpa, g);
    defer state.deinit(gpa);

    var delta: graph_mod.Delta = .{};
    defer delta.deinit(gpa);

    const items = try gpa.alloc(NodeId, g.nodes.len);
    defer gpa.free(items);
    var heap: Heap = .{ .items = items, .position = position };

    try state.seed(gpa, &delta);
    for (delta.admitted.items) |n| heap.push(n);
    delta.clear();

    var shared: Shared = .{
        .gpa = gpa,
        .io = io,
        .graph = g,
        .state = &state,
        .delta = &delta,
        .heap = &heap,
        .pool = pool,
        .action = action,
        .opts = opts,
    };

    const n_workers = @max(@as(usize, opts.workers), 1);
    const futures = try gpa.alloc(?Io.Future(void), n_workers);
    defer gpa.free(futures);
    @memset(futures, null);

    // Worker 0 runs inline, so a single-threaded `Io` needs no special case —
    // the same shape `installArtifacts` uses.
    for (futures[1..]) |*f| {
        f.* = io.concurrent(worker, .{&shared}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => null,
        };
    }
    worker(&shared);
    for (futures[1..]) |*f| {
        if (f.*) |*fut| fut.await(io) else worker(&shared);
    }

    return .{
        .tally = state.tally(),
        .nodes = g.nodes.len,
        .complete = state.done(),
        .oom = shared.oom,
    };
}

fn worker(shared: *Shared) void {
    const io = shared.io;
    while (true) {
        shared.mutex.lockUncancelable(io);
        const node = claim(shared, io) orelse {
            shared.mutex.unlock(io);
            return;
        };
        shared.mutex.unlock(io);

        const ok = execute(shared, io, node);

        shared.mutex.lockUncancelable(io);
        // `settle` returns false for a node a rival cancelled while it ran: the
        // result is dropped and nothing cascades, which is exactly right.
        _ = shared.state.settle(shared.gpa, node, ok, shared.delta) catch {
            shared.oom = true;
            shared.giving_up = true;
        };
        for (shared.delta.admitted.items) |n| shared.heap.push(n);
        shared.delta.clear();
        shared.in_flight -= 1;
        shared.cond.broadcast(io);
        shared.mutex.unlock(io);
    }
}

/// Called with the mutex held. Returns null when this worker should exit.
fn claim(shared: *Shared, io: Io) ?NodeId {
    while (true) {
        if (shared.state.done() or shared.giving_up) {
            shared.cond.broadcast(io);
            return null;
        }
        if (shared.heap.pop()) |node| {
            // A node cancelled between admission and pickup is dropped
            // silently rather than run for a result nobody wants.
            if (!shared.state.begin(node)) continue;
            shared.in_flight += 1;
            return node;
        }
        if (shared.in_flight == 0) {
            // Nothing ready, nothing running, not done. Unreachable on an
            // acyclic graph, and `build` refuses cyclic ones — so this exists
            // to fail the run rather than hang it if that ever stops holding.
            shared.giving_up = true;
            shared.cond.broadcast(io);
            return null;
        }
        shared.cond.wait(io, &shared.mutex) catch {
            shared.giving_up = true;
            shared.cond.broadcast(io);
            return null;
        };
    }
}

fn execute(shared: *Shared, io: Io, node: NodeId) bool {
    const stage = shared.graph.nodes[node].stage;
    const class = classOf(stage) orelse
        return shared.action.run(shared.action.ctx, io, shared.graph, node);

    // A compile takes memory before CPU — `acquireCompile` documents why that
    // order is the one that cannot deadlock against `yieldCpu`.
    if (class == .cpu) {
        var slot = shared.pool.acquireCompile(io, shared.opts.est_rss) catch return false;
        defer slot.release(io);
        return shared.action.run(shared.action.ctx, io, shared.graph, node);
    }

    const permit = shared.pool.acquire(io, class) catch return false;
    defer permit.release(io);
    return shared.action.run(shared.action.ctx, io, shared.graph, node);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn testPool() resources.Pool {
    return .init(.{
        .net_pkgserver = 2,
        .net_cachestore = 2,
        .disk = 2,
        .cpu = 2,
        .memory_bytes = 8 * resources.default_est_rss,
    });
}

/// Node order, for the tests whose subject is not priority.
fn identity(arena: Allocator, n: usize) ![]u32 {
    const p = try arena.alloc(u32, n);
    for (p, 0..) |*x, i| x.* = @intCast(i);
    return p;
}

test "every stage maps to a resource class, or to none deliberately" {
    // A stage added to the graph without a class here would silently run
    // unthrottled, so this asserts the mapping is total and intentional.
    try testing.expectEqual(resources.Class.net_pkgserver, classOf(.fetch).?);
    try testing.expectEqual(resources.Class.net_pkgserver, classOf(.fetch_art).?);
    try testing.expectEqual(resources.Class.net_cachestore, classOf(.probe).?);
    try testing.expectEqual(resources.Class.net_cachestore, classOf(.publish).?);
    try testing.expectEqual(resources.Class.disk, classOf(.install).?);
    try testing.expectEqual(resources.Class.disk, classOf(.verify_cache).?);
    try testing.expectEqual(resources.Class.cpu, classOf(.compile).?);
    try testing.expect(classOf(.resolve) == null);
    try testing.expect(classOf(.ready) == null);
}

test "the heap pops in priority order regardless of admission order" {
    var items: [5]NodeId = undefined;
    const position = [_]u32{ 40, 10, 30, 0, 20 };
    var h: Heap = .{ .items = &items, .position = &position };
    for ([_]NodeId{ 0, 1, 2, 3, 4 }) |n| h.push(n);
    try testing.expectEqual(@as(NodeId, 3), h.pop().?);
    try testing.expectEqual(@as(NodeId, 1), h.pop().?);
    try testing.expectEqual(@as(NodeId, 4), h.pop().?);
    try testing.expectEqual(@as(NodeId, 2), h.pop().?);
    try testing.expectEqual(@as(NodeId, 0), h.pop().?);
    try testing.expect(h.pop() == null);
}

test "a run drives every node of a real-shaped graph exactly once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pkgs = [_]graph_mod.Package{
        .{ .name = "A", .tree_hash = .{ .bytes = [_]u8{1} ** 20 }, .cacheable = false },
        .{ .name = "B", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .cacheable = false, .deps = &.{0} },
    };
    var g = try graph_mod.build(arena, .{ .packages = &pkgs }, null);
    const position = try identity(arena, g.nodes.len);

    const Counter = struct {
        runs: std.atomic.Value(u32) = .init(0),
        fn act(ctx: *anyopaque, _: Io, _: *const Graph, _: NodeId) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.runs.fetchAdd(1, .monotonic);
            return true;
        }
    };
    var counter: Counter = .{};
    var pool = testPool();

    const sum = try run(
        testing.allocator,
        testing.io,
        &g,
        position,
        &pool,
        .{ .ctx = &counter, .run = Counter.act },
        .{ .workers = 4 },
    );

    try testing.expect(sum.complete);
    try testing.expect(!sum.oom);
    try testing.expectEqual(@as(u32, @intCast(g.nodes.len)), sum.tally.succeeded);
    // Exactly once: no double-dispatch, nothing dropped.
    try testing.expectEqual(@as(u32, @intCast(g.nodes.len)), counter.runs.load(.monotonic));
}

test "a failing action cascades to skipped instead of hanging the frontier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pkgs = [_]graph_mod.Package{.{
        .name = "A",
        .tree_hash = .{ .bytes = [_]u8{1} ** 20 },
        .cacheable = false,
    }};
    var g = try graph_mod.build(arena, .{ .packages = &pkgs }, null);
    const position = try identity(arena, g.nodes.len);
    const fetch = g.find(.fetch, .{ .package = 0 }).?;

    const Failer = struct {
        target: NodeId,
        fn act(ctx: *anyopaque, _: Io, _: *const Graph, node: NodeId) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return node != self.target;
        }
    };
    var failer: Failer = .{ .target = fetch };
    var pool = testPool();

    const sum = try run(
        testing.allocator,
        testing.io,
        &g,
        position,
        &pool,
        .{ .ctx = &failer, .run = Failer.act },
        .{ .workers = 2 },
    );

    // That the run FINISHES is the property under test: a frontier that cannot
    // settle a failure is a hang with no stack trace.
    try testing.expect(sum.complete);
    try testing.expectEqual(@as(u32, 1), sum.tally.failed);
    try testing.expect(sum.tally.skipped > 0);
}

test "a cache hit cancels the compile, and the compile is never dispatched" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pkgs = [_]graph_mod.Package{.{ .name = "A", .installed = true }};
    var g = try graph_mod.build(arena, .{ .packages = &pkgs }, null);

    const ready = g.find(.ready, .{ .package = 0 }).?;
    const compile = g.find(.compile, .{ .package = 0 }).?;
    const verify_cache = g.find(.verify_cache, .{ .package = 0 }).?;
    try testing.expect(g.anyOf(ready) != null);

    // Which alternative wins is a PRIORITY question, not an accident of node
    // numbering: give the cache arm the front of the queue. Left to node order
    // `Compile` can pop first and legitimately win, which is correct behaviour
    // and a useless test.
    const position = try arena.alloc(u32, g.nodes.len);
    for (position, 0..) |*p, i| p.* = @intCast(100 + i);
    position[g.find(.probe, .{ .package = 0 }).?] = 1;
    position[g.find(.import, .{ .package = 0 }).?] = 2;
    position[verify_cache] = 3;

    const Spy = struct {
        compile: NodeId,
        compiled: std.atomic.Value(bool) = .init(false),
        fn act(ctx: *anyopaque, _: Io, _: *const Graph, node: NodeId) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (node == self.compile) self.compiled.store(true, .release);
            return true;
        }
    };
    var spy: Spy = .{ .compile = compile };
    // One worker: with the cache arm ranked first, the compile cannot be picked
    // up before `VerifyCache` settles and cancels it.
    var pool = testPool();

    const sum = try run(
        testing.allocator,
        testing.io,
        &g,
        position,
        &pool,
        .{ .ctx = &spy, .run = Spy.act },
        .{ .workers = 1 },
    );

    try testing.expect(sum.complete);
    try testing.expect(sum.tally.cancelled > 0);
    // The point of the cache: the compile never ran at all.
    try testing.expect(!spy.compiled.load(.acquire));
}

test "workers respect the class width they are given" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Eight independent packages: after Resolve, eight Fetch nodes are ready at
    // once, so the only thing bounding concurrency is the net permit.
    var pkgs: [8]graph_mod.Package = undefined;
    for (&pkgs, 0..) |*p, i| {
        p.* = .{
            .name = "P",
            .tree_hash = .{ .bytes = [_]u8{@intCast(i + 1)} ** 20 },
            .cacheable = false,
        };
    }
    var g = try graph_mod.build(arena, .{ .packages = &pkgs }, null);
    const position = try identity(arena, g.nodes.len);

    const Watcher = struct {
        live: std.atomic.Value(u32) = .init(0),
        peak_fetch: std.atomic.Value(u32) = .init(0),
        fn act(ctx: *anyopaque, _: Io, g2: *const Graph, node: NodeId) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (g2.nodes[node].stage != .fetch) return true;
            const now = self.live.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak_fetch.fetchMax(now, .acq_rel);
            std.atomic.spinLoopHint();
            _ = self.live.fetchSub(1, .acq_rel);
            return true;
        }
    };
    var watcher: Watcher = .{};
    var pool: resources.Pool = .init(.{
        .net_pkgserver = 2,
        .net_cachestore = 2,
        .disk = 4,
        .cpu = 4,
        .memory_bytes = 8 * resources.default_est_rss,
    });

    const sum = try run(
        testing.allocator,
        testing.io,
        &g,
        position,
        &pool,
        .{ .ctx = &watcher, .run = Watcher.act },
        .{ .workers = 8 },
    );

    try testing.expect(sum.complete);
    try testing.expect(watcher.peak_fetch.load(.acquire) <= 2);
}
