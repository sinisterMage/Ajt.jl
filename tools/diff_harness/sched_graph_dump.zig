//! Drives `sched/graph.zig` for `sched_graph.sh`. Not part of the `ajt`
//! binary: the M4 CLI surface belongs to the executor unit, and a gate should
//! not have to wait for it to exist.
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/sched_graph_dump.zig \
//!     -Majt=src/root.zig -- <mode> [args]
//!
//! Modes:
//!
//!   manifest <Manifest.toml> [--julia-prefix P] [--inject-cycle]
//!       Build the stage graph for a REAL environment and report its shape.
//!       Artifacts are enumerated from the real depot when the packages happen
//!       to be installed there, and reported as 0 when they are not -- that is
//!       a weaker run, not a failed one, and the header says which it was.
//!       `--inject-cycle` adds one back-edge to a real dependency pair, which
//!       must make `build` refuse.
//!
//!   scenarios
//!       Four hand-built graphs, one per edge-semantics claim, driven to
//!       completion and printed as `<scenario> <node> <status>` lines. The
//!       shell asserts on those lines rather than on a summary, because
//!       "requires cascades and after does not" is a statement about
//!       individual nodes.
//!
//! Everything is `stdout`, one `key value` line per fact, so the gate can
//! `awk` it without parsing prose.

const std = @import("std");
const ajt = @import("ajt");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const graph = ajt.sched.graph;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll("usage: sched_graph_dump <manifest|scenarios> [args]\n");
        return error.MissingArgument;
    }

    if (std.mem.eql(u8, args[1], "scenarios")) return scenarios(arena, out);
    if (std.mem.eql(u8, args[1], "manifest")) return manifestMode(arena, io, init.environ_map, out, args[2..]);

    try out.print("unknown mode: {s}\n", .{args[1]});
    return error.BadMode;
}

// ---------------------------------------------------------------------------
// manifest mode
// ---------------------------------------------------------------------------

fn manifestMode(
    arena: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 1) {
        try out.writeAll("usage: sched_graph_dump manifest <Manifest.toml> [--julia-prefix P] [--inject-cycle]\n");
        return error.MissingArgument;
    }
    const manifest_path = args[0];
    var julia_prefix: ?[]const u8 = null;
    var inject_cycle = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            julia_prefix = args[i];
        } else if (std.mem.eql(u8, args[i], "--inject-cycle")) {
            inject_cycle = true;
        } else return error.BadArgument;
    }

    const src = try Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(64 * 1024 * 1024));
    const man = try ajt.model.manifest.parse(arena, src, null);

    // --- packages -----------------------------------------------------------
    //
    // The classification is the caller's job by design (`sched/graph.zig` takes
    // already-parsed data), and this is the same rule `instantiate` uses:
    // a `git-tree-sha1` means "download it", a `path` means "it is already
    // where it is", and an entry with neither is a stdlib that ships in the
    // sysimage -- nothing to fetch, nothing to precompile, nothing to cache.
    var pkgs = try arena.alloc(graph.Package, man.entries.len);
    var deps_of = try arena.alloc(std.ArrayList(u32), man.entries.len);
    for (deps_of) |*d| d.* = .empty;

    for (man.entries, 0..) |e, pi| {
        const sysimage_stdlib = e.tree_hash == null and e.path == null;
        pkgs[pi] = .{
            .name = e.name,
            .uuid = e.uuid,
            .tree_hash = e.tree_hash,
            .installed = false, // a COLD run: this is the shape the plan sized
            .precompile = !sysimage_stdlib,
            .cacheable = !sysimage_stdlib,
        };
    }

    var dep_edges: u32 = 0;
    var dangling_deps: u32 = 0;
    for (man.entries, 0..) |e, pi| {
        for (e.deps) |d| {
            const di = indexOfUuid(man.entries, d.uuid) orelse {
                // A dep whose UUID is not a manifest entry. Real and legal:
                // weak-dependency triggers can name packages the manifest does
                // not carry. There is no node to point at, so there is no edge.
                dangling_deps += 1;
                continue;
            };
            if (di == pi) continue;
            try deps_of[pi].append(arena, @intCast(di));
            dep_edges += 1;
        }
    }

    // --- artifacts ----------------------------------------------------------
    var artifacts: std.ArrayList(graph.Artifact) = .empty;
    const arts_of = try arena.alloc(std.ArrayList(u32), man.entries.len);
    for (arts_of) |*a| a.* = .empty;
    var artifact_source: []const u8 = "none";

    if (julia_prefix) |prefix| {
        artifact_source = collectArtifacts(arena, io, environ, prefix, man, &artifacts, arts_of) catch |err| blk: {
            try out.print("# artifact enumeration skipped: {s}\n", .{@errorName(err)});
            break :blk "none";
        };
    }

    for (pkgs, 0..) |*p, pi| {
        p.deps = deps_of[pi].items;
        p.artifacts = arts_of[pi].items;
    }

    if (inject_cycle) {
        // Close a real dependency pair back on itself: `p → d` becomes
        // `p → d → p`. Using a live pair rather than a synthetic one keeps the
        // refusal on the same 1,800-node graph everything else is measured on.
        var closed = false;
        for (pkgs, 0..) |p, pi| {
            if (p.deps.len == 0) continue;
            const d: u32 = p.deps[0];
            try deps_of[d].append(arena, @intCast(pi));
            pkgs[d].deps = deps_of[d].items;
            try out.print("injected {s} -> {s}\n", .{ pkgs[d].name, p.name });
            closed = true;
            break;
        }
        if (!closed) return error.NothingToInject;
    }

    // --- build --------------------------------------------------------------
    var diag: graph.Diagnostic = .{};
    const g = graph.build(arena, .{ .packages = pkgs, .artifacts = artifacts.items }, &diag) catch |err| switch (err) {
        // The refusal. `build` never hands back a cyclic graph, so there is no
        // `nodes` line on this path at all -- that absence is what the gate
        // asserts, alongside the printed path.
        error.Cyclic => {
            try out.writeAll("acyclic no\n");
            try out.writeAll("refused Cyclic\n");
            try out.print("cycle_len {d}\n", .{diag.cycle.len});
            try out.print("cycle_closed {s}\n", .{
                if (diag.cycle.len > 1 and diag.cycle[0] == diag.cycle[diag.cycle.len - 1]) "yes" else "no",
            });
            try out.writeAll("cycle ");
            try diag.write(out);
            try out.writeAll("\n");
            try out.flush();
            return;
        },
        else => return err,
    };

    try out.print("manifest {s}\n", .{manifest_path});
    try out.print("artifact_source {s}\n", .{artifact_source});
    try out.print("entries {d}\n", .{man.entries.len});
    try out.print("dep_edges {d}\n", .{dep_edges});
    try out.print("dangling_deps {d}\n", .{dangling_deps});
    try out.print("artifacts {d}\n", .{artifacts.items.len});
    var lazy: u32 = 0;
    for (artifacts.items) |a| {
        if (a.lazy) lazy += 1;
    }
    try out.print("lazy_artifacts {d}\n", .{lazy});
    // Everything below is derived from the Package/Artifact RECORDS, never
    // from the graph. That is the point: it lets `sched_graph.sh` re-derive
    // the node and edge totals by arithmetic and compare against what the
    // builder actually emitted, instead of restating the builder's own answer.
    var fetchable: u32 = 0;
    var cacheable: u32 = 0;
    var dep_attachments: u32 = 0;
    var art_attachments: u32 = 0;
    var lazy_attachments: u32 = 0;
    var compile_heads: u32 = 0;
    var ready_heads: u32 = 0;
    for (pkgs) |p| {
        if (p.tree_hash != null) fetchable += 1;
        const cache = p.precompile and p.cacheable;
        if (cache) cacheable += 1;
        const ntips: u32 = (if (p.precompile) @as(u32, 1) else 0) + (if (cache) @as(u32, 1) else 0);
        const attach: u32 = if (ntips == 0) 1 else ntips;
        dep_attachments += @as(u32, @intCast(p.deps.len)) * attach;
        var live_arts: u32 = 0;
        var strict_arts: u32 = 0;
        for (p.artifacts) |ai| {
            if (artifacts.items[ai].installed) continue;
            live_arts += 1;
            // A lazy artifact's edges are `after`, so they belong to the
            // `after` total the gate re-derives, not the `requires` one -- and
            // they do NOT stop a node from being a chain head, which is what
            // `strict_arts` is counted separately for.
            if (artifacts.items[ai].lazy) lazy_attachments += attach else strict_arts += 1;
        }
        art_attachments += live_arts * attach;

        const has_install = p.tree_hash != null and !p.installed;
        // A chain head is a node with no `requires` in-edge, so only the
        // non-lazy artifacts count here.
        if (p.precompile and !has_install and p.deps.len == 0 and strict_arts == 0) compile_heads += 1;
        // `Ready(p)` is a head only when the package has no arm tip at all,
        // i.e. a sysimage stdlib, and nothing attached to it either.
        if (ntips == 0 and !has_install and p.deps.len == 0 and strict_arts == 0) ready_heads += 1;
    }
    try out.print("fetchable {d}\n", .{fetchable});
    try out.print("cacheable {d}\n", .{cacheable});
    try out.print("lazy_attachments {d}\n", .{lazy_attachments});
    try out.print("dep_attachments {d}\n", .{dep_attachments});
    try out.print("art_attachments {d}\n", .{art_attachments});
    try out.print("compile_heads {d}\n", .{compile_heads});
    try out.print("ready_heads {d}\n", .{ready_heads});
    try out.print("resolve_out {d}\n", .{g.outEdges(0).len});
    try out.print("nodes {d}\n", .{g.nodes.len});
    try out.print("edges {d}\n", .{g.edges.len});
    try out.print("requires {d}\n", .{g.edgeCountByKind(.requires)});
    try out.print("after {d}\n", .{g.edgeCountByKind(.after)});
    try out.print("any_nodes {d}\n", .{g.any_nodes.len});
    try out.writeAll("acyclic yes\n");

    const by_stage = g.countByStage();
    inline for (@typeInfo(graph.Stage).@"enum".fields) |f| {
        const s: graph.Stage = @enumFromInt(f.value);
        try out.print("stage {s} {d}\n", .{ s.label(), by_stage[f.value] });
    }

    // A cold run must be drivable to completion with every node succeeding.
    // If the readiness bookkeeping ever leaked a permanently-pending node this
    // is where a 1,800-node graph would catch it and a 10-node unit test would
    // not.
    const t = try driveAll(arena, &g);
    try out.print("settled {d}\n", .{t.succeeded + t.failed + t.skipped + t.cancelled});
    try out.print("succeeded {d}\n", .{t.succeeded});
    try out.print("cancelled {d}\n", .{t.cancelled});
    try out.print("failed {d}\n", .{t.failed});
    try out.print("skipped {d}\n", .{t.skipped});
    try out.print("stuck {d}\n", .{t.pending + t.ready + t.running});
}

fn indexOfUuid(entries: []const ajt.model.manifest.PackageEntry, u: ajt.julia.Uuid) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, &e.uuid.bytes, &u.bytes)) return i;
    }
    return null;
}

/// Real artifacts from a real depot, deduplicated by tree hash — which is the
/// fan-in `FetchArt`/`InstallArt` exist for. Returns the depot it read.
fn collectArtifacts(
    arena: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    julia_prefix: []const u8,
    man: ajt.model.manifest.Manifest,
    out_arts: *std.ArrayList(graph.Artifact),
    arts_of: []std.ArrayList(u32),
) ![]const u8 {
    const bindir = try std.fs.path.join(arena, &.{ julia_prefix, "bin" });
    const stack = try ajt.depot.resolve(arena, .fromEnviron(environ.*, bindir));
    if (stack.entries.len == 0) return error.NoDepot;

    // The manifest's own `julia_version` is the Julia this environment
    // targets, which is what artifact selection has to match -- and unlike a
    // VERSION file it is guaranteed to be here, since a resolved manifest
    // always carries one (`Pkg/src/manifest.jl:299-301`).
    var vbuf: [64]u8 = undefined;
    var vw = Io.Writer.fixed(&vbuf);
    try (man.julia_version orelse return error.NoJuliaVersion).format(&vw);
    const julia_version = vw.buffered();

    const host = try ajt.julia.platform.detectHost(arena, io, .{
        .julia_prefix = julia_prefix,
        .julia_version = julia_version,
    });

    // `install_artifacts.plan` wants one root per package. Track which package
    // each root belongs to so a job can be attributed back.
    var roots: std.ArrayList(ajt.ops.install_artifacts.Package) = .empty;
    var root_owner: std.ArrayList(u32) = .empty;
    for (man.entries, 0..) |e, pi| {
        const th = e.tree_hash orelse continue;
        const found = try ajt.depot.findInstalled(arena, io, stack, e.name, e.uuid, th);
        if (!found.exists) continue;
        try roots.append(arena, .{ .root = found.path, .uuid = null });
        try root_owner.append(arena, @intCast(pi));
    }
    if (roots.items.len == 0) return error.NoPackagesInstalled;

    const plan = try ajt.ops.install_artifacts.plan(
        arena,
        arena,
        io,
        stack.entries,
        roots.items,
        host,
        .{ .include_lazy = true }, // lazy ones become `after` edges, not absences
    );

    for (plan.jobs) |job| {
        // Deduplicate by tree hash: one artifact, one pair of nodes, however
        // many JLLs name it.
        var idx: ?u32 = null;
        for (out_arts.items, 0..) |a, i| {
            if (std.mem.eql(u8, &a.tree_hash.bytes, &job.hash)) {
                idx = @intCast(i);
                break;
            }
        }
        const ai = idx orelse blk: {
            const n: u32 = @intCast(out_arts.items.len);
            try out_arts.append(arena, .{
                .tree_hash = .{ .bytes = job.hash },
                .name = job.name,
                .lazy = job.lazy,
                .installed = false, // cold run
            });
            break :blk n;
        };

        // Attribute by longest matching root prefix — `Job` carries the
        // `Artifacts.toml` it came from, and that always sits under the
        // package root it was collected from.
        var owner: ?u32 = null;
        var best: usize = 0;
        for (roots.items, 0..) |r, ri| {
            if (std.mem.startsWith(u8, job.artifacts_toml, r.root) and r.root.len > best) {
                best = r.root.len;
                owner = root_owner.items[ri];
            }
        }
        const pi = owner orelse continue;
        var already = false;
        for (arts_of[pi].items) |x| {
            if (x == ai) already = true;
        }
        if (!already) try arts_of[pi].append(arena, ai);
    }

    return stack.entries[0];
}

/// FIFO drive-to-completion with every node succeeding. The real executor is a
/// sibling unit; this is the stand-in that proves the bookkeeping terminates.
fn driveAll(gpa: Allocator, g: *const graph.Graph) !graph.Tally {
    var state = try graph.State.init(gpa, g);
    defer state.deinit(gpa);
    var delta: graph.Delta = .{};
    defer delta.deinit(gpa);
    var queue: std.ArrayList(graph.NodeId) = .empty;
    defer queue.deinit(gpa);

    try state.seed(gpa, &delta);
    for (delta.admitted.items) |n| try queue.append(gpa, n);
    delta.clear();

    var head: usize = 0;
    while (head < queue.items.len) {
        const n = queue.items[head];
        head += 1;
        if (!state.begin(n)) continue;
        _ = try state.settle(gpa, n, true, &delta);
        for (delta.admitted.items) |m| try queue.append(gpa, m);
        delta.clear();
    }
    return state.tally();
}

// ---------------------------------------------------------------------------
// scenarios
// ---------------------------------------------------------------------------

const th1: ajt.julia.Sha1 = .{ .bytes = [_]u8{1} ** 20 };
const th2: ajt.julia.Sha1 = .{ .bytes = [_]u8{2} ** 20 };
const th3: ajt.julia.Sha1 = .{ .bytes = [_]u8{3} ** 20 };

/// A run with a per-node verdict and a fixed settle ORDER preference, so a
/// scenario can say "let the import arm win" without a scheduler.
const Run = struct {
    gpa: Allocator,
    g: *const graph.Graph,
    state: graph.State,
    delta: graph.Delta = .{},
    queue: std.ArrayList(graph.NodeId) = .empty,
    fail: []const graph.NodeId,
    /// Nodes to prefer when several are runnable. Everything else is FIFO.
    prefer: []const graph.NodeId,

    fn init(gpa: Allocator, g: *const graph.Graph, fail: []const graph.NodeId, prefer: []const graph.NodeId) !Run {
        var r: Run = .{
            .gpa = gpa,
            .g = g,
            .state = try graph.State.init(gpa, g),
            .fail = fail,
            .prefer = prefer,
        };
        try r.state.seed(gpa, &r.delta);
        try r.absorb();
        return r;
    }

    fn absorb(self: *Run) !void {
        for (self.delta.admitted.items) |n| try self.queue.append(self.gpa, n);
        self.delta.clear();
    }

    fn pick(self: *Run) ?usize {
        for (self.prefer) |p| {
            for (self.queue.items, 0..) |n, i| {
                if (n == p) return i;
            }
        }
        return if (self.queue.items.len == 0) null else 0;
    }

    fn run(self: *Run) !void {
        while (self.pick()) |i| {
            const n = self.queue.orderedRemove(i);
            if (!self.state.begin(n)) continue;
            var ok = true;
            for (self.fail) |f| {
                if (f == n) ok = false;
            }
            _ = try self.state.settle(self.gpa, n, ok, &self.delta);
            try self.absorb();
        }
    }

    fn deinit(self: *Run) void {
        self.state.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.queue.deinit(self.gpa);
    }
};

fn report(arena: Allocator, out: *Io.Writer, name: []const u8, g: *const graph.Graph, st: *const graph.State) !void {
    for (0..g.nodes.len) |n| {
        try out.print("{s} {s} {t}\n", .{ name, try g.nodeLabel(arena, @intCast(n)), st.status[n] });
    }
}

fn scenarios(arena: Allocator, out: *Io.Writer) !void {
    // --- 1: `requires` cascades transitively --------------------------------
    {
        const pkgs = [_]graph.Package{
            .{ .name = "Base", .tree_hash = th1 },
            .{ .name = "Mid", .tree_hash = th2, .deps = &.{0} },
            .{ .name = "Top", .tree_hash = th3, .deps = &.{1} },
        };
        const g = try graph.build(arena, .{ .packages = &pkgs }, null);
        var r = try Run.init(arena, &g, &.{g.find(.fetch, .{ .package = 0 }).?}, &.{});
        defer r.deinit();
        try r.run();
        try report(arena, out, "requires", &g, &r.state);
    }

    // --- 2: `after` propagates nothing --------------------------------------
    {
        const pkgs = [_]graph.Package{.{ .name = "Foo", .tree_hash = th1 }};
        const g = try graph.build(arena, .{ .packages = &pkgs }, null);
        // Probe fails (a cache miss is not an error) and Publish fails (the
        // object store is down). Neither may cost the package its Ready.
        const fails = [_]graph.NodeId{
            g.find(.probe, .{ .package = 0 }).?,
            g.find(.publish, .{ .package = 0 }).?,
        };
        var r = try Run.init(arena, &g, &fails, &.{});
        defer r.deinit();
        try r.run();
        try report(arena, out, "after", &g, &r.state);
    }

    // --- 3: `any`, import arm wins ------------------------------------------
    {
        const pkgs = [_]graph.Package{.{ .name = "Foo", .tree_hash = th1 }};
        const g = try graph.build(arena, .{ .packages = &pkgs }, null);
        const prefer = [_]graph.NodeId{
            g.find(.probe, .{ .package = 0 }).?,
            g.find(.import, .{ .package = 0 }).?,
            g.find(.verify_cache, .{ .package = 0 }).?,
        };
        var r = try Run.init(arena, &g, &.{}, &prefer);
        defer r.deinit();
        try r.run();
        try report(arena, out, "any-import", &g, &r.state);
    }

    // --- 4: `any`, compile arm wins on a cache miss -------------------------
    {
        const pkgs = [_]graph.Package{.{ .name = "Foo", .tree_hash = th1 }};
        const g = try graph.build(arena, .{ .packages = &pkgs }, null);
        var r = try Run.init(arena, &g, &.{g.find(.import, .{ .package = 0 }).?}, &.{});
        defer r.deinit();
        try r.run();
        try report(arena, out, "any-compile", &g, &r.state);
    }

    // --- 5: a lazy artifact orders but never blocks -------------------------
    //
    // The other `after` population. Worth its own scenario because the real
    // depot enumerates zero lazy artifacts, so nothing else here exercises an
    // `after` edge that is NOT one of the two per-package ones.
    {
        const arts = [_]graph.Artifact{
            .{ .tree_hash = .{ .bytes = [_]u8{8} ** 20 }, .name = "eager" },
            .{ .tree_hash = .{ .bytes = [_]u8{9} ** 20 }, .name = "lazy", .lazy = true },
        };
        const pkgs = [_]graph.Package{
            .{ .name = "Jll", .tree_hash = th1, .artifacts = &.{ 0, 1 } },
        };
        const g = try graph.build(arena, .{ .packages = &pkgs, .artifacts = &arts }, null);
        var r = try Run.init(arena, &g, &.{g.find(.install_art, .{ .artifact = 1 }).?}, &.{});
        defer r.deinit();
        try r.run();
        try report(arena, out, "lazy-art", &g, &r.state);
    }

    // --- 6: both alternatives gone -> Ready blocked -------------------------
    {
        const pkgs = [_]graph.Package{
            .{ .name = "Foo", .tree_hash = th1 },
            .{ .name = "User", .tree_hash = th2, .deps = &.{0} },
        };
        const g = try graph.build(arena, .{ .packages = &pkgs }, null);
        const fails = [_]graph.NodeId{
            g.find(.import, .{ .package = 0 }).?,
            g.find(.compile, .{ .package = 0 }).?,
        };
        var r = try Run.init(arena, &g, &fails, &.{});
        defer r.deinit();
        try r.run();
        try report(arena, out, "any-dead", &g, &r.state);
    }
}
