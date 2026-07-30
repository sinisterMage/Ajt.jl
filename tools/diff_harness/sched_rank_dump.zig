//! Drives `sched/rank.zig` for `sched_rank.sh`. Not part of the `ajt` binary:
//! this is a harness fixture (M4's CLI surface belongs to a different unit),
//! run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/sched_rank_dump.zig \
//!     -Majt=src/root.zig -- <mode> ...
//!
//! Four modes, all printing one fact per line so the shell can assert on
//! exact strings rather than parsing prose:
//!
//!   dag <file> [--depot D] [--default MS]
//!     Ranks a hand-built graph. The file is one directive per line:
//!         node <name>            declare (fixes the index tie-break order)
//!         cost <name> <ms>       explicit cost; overrides the model
//!         edge <a> <b>           a must finish before b
//!     Names are first-seen-first-indexed, so the file's own order is the
//!     tie-break order and a test can pin it. Prints:
//!         order <name> <name> ...
//!         rank <name> <rank> <downstream> <outdeg>
//!         health ...
//!
//!   manifest <Manifest.toml> [--depot D] [--top N]
//!     Ranks a real Julia environment. Prints `nodes`, `top`, the critical
//!     path itself, and `health`.
//!
//!   costs <depot> <key>...      one `estimate <key> <ms>` line each, + health
//!   record <depot> <key>=<ms>...  blends measurements into the model
//!
//! `--depot` is what makes the cost model observable: with it, a node's cost
//! is `<depot>/ajt/costs.toml`'s entry for its NAME, falling back to
//! `--default`. Without it the model is empty and every cost is the default,
//! which is the uniform-estimate degradation path.

const std = @import("std");
const ajt = @import("ajt");
const rank_mod = ajt.sched.rank;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: sched_rank_dump <dag|manifest|costs|record> ...\n");
        try out.flush();
        return error.MissingArgument;
    }

    const mode = args[1];
    if (std.mem.eql(u8, mode, "dag")) {
        try runDag(arena, io, out, args[2..]);
    } else if (std.mem.eql(u8, mode, "manifest")) {
        try runManifest(arena, io, out, args[2..]);
    } else if (std.mem.eql(u8, mode, "costs")) {
        try runCosts(arena, io, out, args[2..]);
    } else if (std.mem.eql(u8, mode, "record")) {
        try runRecord(arena, io, out, args[2..]);
    } else {
        try out.print("unknown mode: {s}\n", .{mode});
        try out.flush();
        return error.BadMode;
    }
    try out.flush();
}

// ---------------------------------------------------------------------------

const Graph = struct {
    names: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    succ: std.ArrayList(std.ArrayList(u32)) = .empty,
    explicit_cost: std.ArrayList(?u64) = .empty,

    fn intern(self: *Graph, arena: std.mem.Allocator, name: []const u8) !u32 {
        if (self.index.get(name)) |i| return i;
        const i: u32 = @intCast(self.names.items.len);
        const owned = try arena.dupe(u8, name);
        try self.names.append(arena, owned);
        try self.index.put(arena, owned, i);
        try self.succ.append(arena, .empty);
        try self.explicit_cost.append(arena, null);
        return i;
    }

    fn edge(self: *Graph, arena: std.mem.Allocator, from: u32, to: u32) !void {
        try self.succ.items[from].append(arena, to);
    }

    fn adjacency(self: *const Graph, arena: std.mem.Allocator) ![]const []const u32 {
        const out = try arena.alloc([]const u32, self.succ.items.len);
        for (out, self.succ.items) |*slot, list| slot.* = list.items;
        return out;
    }
};

/// Costs from the model, with any explicit per-node override winning. The
/// override exists so a DAG fixture can pin a shape without a depot at all.
fn costsFor(
    arena: std.mem.Allocator,
    g: *const Graph,
    model: rank_mod.CostModel,
    default_ms: u64,
) ![]u64 {
    const cost = try arena.alloc(u64, g.names.items.len);
    for (cost, 0..) |*slot, i| {
        slot.* = g.explicit_cost.items[i] orelse model.estimate(g.names.items[i], default_ms);
    }
    return cost;
}

/// The invariant that lets `order` be read as a plan: rank strictly decreases
/// along every edge, so the priority order is also a topological order.
/// Checked here rather than in the shell because the shell would have to
/// re-derive the edges to do it, and a gate that re-implements the thing it is
/// gating proves less than one that does not.
fn printTopoOk(out: *std.Io.Writer, r: rank_mod.Ranking, succ: []const []const u32) !void {
    var ok = true;
    var head_indegree: usize = 0;
    for (succ, 0..) |ss, i| {
        for (ss) |s| {
            if (!r.before(@intCast(i), s) or r.rank[i] <= r.rank[s]) ok = false;
            if (r.len() != 0 and s == r.order[0]) head_indegree += 1;
        }
    }
    try out.print("topo_ok {d} head_indegree {d}\n", .{ @intFromBool(ok), head_indegree });
}

fn printHealth(out: *std.Io.Writer, h: rank_mod.Health) !void {
    try out.print(
        "health present={d} parse_failed={d} schema_mismatch={d} shape_wrong={d} dropped={d} clamped={d} entries={d}\n",
        .{
            @intFromBool(h.present),         @intFromBool(h.parse_failed),
            @intFromBool(h.schema_mismatch), @intFromBool(h.shape_wrong),
            h.dropped,                       h.clamped,
            h.entries,
        },
    );
}

// ---------------------------------------------------------------------------

fn runDag(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const path = args[0];
    var depot: ?[]const u8 = null;
    var default_ms: u64 = rank_mod.default_cost_ms;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depot") and i + 1 < args.len) {
            depot = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--default") and i + 1 < args.len) {
            default_ms = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else return error.BadArgument;
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024));
    var g: Graph = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const verb = it.next() orelse continue;
        if (std.mem.eql(u8, verb, "node")) {
            _ = try g.intern(arena, it.next() orelse return error.BadDirective);
        } else if (std.mem.eql(u8, verb, "cost")) {
            const n = try g.intern(arena, it.next() orelse return error.BadDirective);
            g.explicit_cost.items[n] = try std.fmt.parseInt(u64, it.next() orelse return error.BadDirective, 10);
        } else if (std.mem.eql(u8, verb, "edge")) {
            const a = try g.intern(arena, it.next() orelse return error.BadDirective);
            const b = try g.intern(arena, it.next() orelse return error.BadDirective);
            try g.edge(arena, a, b);
        } else return error.BadDirective;
    }

    const model = if (depot) |d| try rank_mod.load(arena, io, d) else rank_mod.CostModel{};
    const succ = try g.adjacency(arena);
    const cost = try costsFor(arena, &g, model, default_ms);
    const r = try rank_mod.compute(arena, arena, succ, cost);

    try out.writeAll("order");
    for (r.order) |n| try out.print(" {s}", .{g.names.items[n]});
    try out.writeAll("\n");
    for (r.order) |n| {
        try out.print("rank {s} {d} {d} {d}\n", .{
            g.names.items[n], r.rank[n], r.downstream[n], r.out_degree[n],
        });
    }
    try printTopoOk(out, r, succ);
    try printHealth(out, model.health);
}

// ---------------------------------------------------------------------------

fn runManifest(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const path = args[0];
    var depot: ?[]const u8 = null;
    var top: usize = 10;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depot") and i + 1 < args.len) {
            depot = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--top") and i + 1 < args.len) {
            top = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else return error.BadArgument;
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
    const manifest = try ajt.model.manifest.parse(arena, text, null);

    // Index by UUID, not by name: a v2 manifest may legitimately carry two
    // entries with the same name and different UUIDs, and collapsing them
    // would fuse two unrelated packages into one node.
    var by_uuid: std.AutoHashMapUnmanaged([16]u8, u32) = .empty;
    const names = try arena.alloc([]const u8, manifest.entries.len);
    for (manifest.entries, 0..) |e, n| {
        names[n] = e.name;
        try by_uuid.put(arena, e.uuid.bytes, @intCast(n));
    }

    // The manifest direction is dependency-wards; the ranking needs the flip.
    const deps = try arena.alloc([]u32, manifest.entries.len);
    var dangling: usize = 0;
    for (manifest.entries, 0..) |e, n| {
        var list: std.ArrayList(u32) = .empty;
        for (e.deps) |d| {
            if (by_uuid.get(d.uuid.bytes)) |target| {
                try list.append(arena, target);
            } else dangling += 1;
        }
        deps[n] = list.items;
    }
    const succ = try rank_mod.successorsFromDependencies(arena, deps);

    const model = if (depot) |d| try rank_mod.load(arena, io, d) else rank_mod.CostModel{};
    const cost = try rank_mod.estimates(arena, model, names, rank_mod.default_cost_ms);
    const r = try rank_mod.compute(arena, arena, succ, cost);

    var edges: usize = 0;
    for (succ) |s| edges += s.len;
    try out.print("nodes {d} edges {d} dangling {d}\n", .{ manifest.entries.len, edges, dangling });

    for (r.top(top), 0..) |n, place| {
        try out.print("top {d} {s} {d} {d} {d}\n", .{
            place + 1, names[n], r.rank[n], r.downstream[n], r.out_degree[n],
        });
    }

    if (r.len() != 0) {
        try out.writeAll("path");
        for (try r.path(arena, succ, r.order[0])) |n| try out.print(" {s}", .{names[n]});
        try out.writeAll("\n");
    }
    try printTopoOk(out, r, succ);
    try printHealth(out, model.health);
}

// ---------------------------------------------------------------------------

fn runCosts(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    const model = try rank_mod.load(arena, io, args[0]);
    for (args[1..]) |key| {
        try out.print("estimate {s} {d}\n", .{ key, model.estimate(key, rank_mod.default_cost_ms) });
        try out.print("known {s} {d}\n", .{ key, @intFromBool(model.get(key) != null) });
    }
    if (try model.health.note(arena, try rank_mod.costsPath(arena, args[0]))) |n| try out.print("note {s}", .{n});
    try printHealth(out, model.health);
}

fn runRecord(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return error.MissingArgument;
    var measured: std.ArrayList(rank_mod.Measured) = .empty;
    for (args[1..]) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadArgument;
        try measured.append(arena, .{
            .key = pair[0..eq],
            .ms = try std.fmt.parseInt(u64, pair[eq + 1 ..], 10),
        });
    }
    const saved = try rank_mod.update(arena, io, args[0], measured.items);
    try out.print("written {d} entries {d}\n", .{ @intFromBool(saved.written), saved.entries });
}
