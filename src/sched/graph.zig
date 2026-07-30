//! The stage graph — one dependency graph for the whole of `instantiate`,
//! with per-stage nodes, two edge kinds, and a hard refusal on cycles.
//!
//! ## What this replaces
//!
//! `Pkg.API.instantiate` runs four `@sync` barriers back to back
//! (`Pkg/src/API.jl:1391-1397`):
//!
//! ```text
//!     Operations.download_source(ctx)                  # every tarball
//!     Operations.download_artifacts(ctx; platform)     # every artifact
//!     Operations.build_versions(ctx, ...)              # every deps/build.jl
//!     Pkg._auto_precompile(ctx)                        # every cache file
//! ```
//!
//! Each has its own concurrency pool and none of them overlaps with the next.
//! On a cold Open-Reality boot that means 516 MB of artifacts stream down with
//! every core idle, and then ~170 packages compile with the network idle. The
//! fix is not a bigger pool; it is deleting the barriers, which requires
//! knowing — per package, per artifact, per *stage* — what actually has to
//! precede what. That is this file.
//!
//! Base's own precompile scheduler (`base/precompilation.jl`) already does the
//! deleting-barriers trick for the compile phase alone and is genuinely good.
//! What it cannot do is start `Compile(JLLWrappers)` while artifacts are still
//! downloading, because by the time it runs, `download_artifacts` has already
//! returned.
//!
//! ## The stages
//!
//! ```text
//!   Resolve
//!     ├─ Fetch(p) ─req→ Verify(p) ─req→ Install(p) ─┬─req→ Compile(p) ─┐
//!     │                                             │                  ├→ Ready(p)
//!     ├─ Probe(p) ─after→ Import(p) ─req→ VerifyCache(p) ──────────────┘   (any)
//!     │                                             │
//!     └─ FetchArt(a) ─req→ InstallArt(a) ─req→ ─────┘
//!
//!                             Compile(p) ─after→ Publish(p)
//! ```
//!
//! `FetchArt`/`InstallArt` are keyed by artifact **tree-sha1**, not by the JLL
//! that mentions the artifact: one artifact is routinely named by several JLLs
//! and by several `Artifacts.toml` entries, and a per-package node would
//! download it more than once. Their fan-in is their whole point.
//!
//! `LoadCheck` — named in the plan as an `after`-edge example — is deliberately
//! NOT emitted. A node that runs `Base.require` after `Ready` is a diagnostic,
//! not a prerequisite, and adding one now would put an unmeasured `julia -e`
//! per package into every run. `EdgeKind.after` is exactly the seam it would
//! attach through if a caller wants it.
//!
//! ## The two edge kinds
//!
//! Straight from the `dynamod` model, and the distinction is the whole
//! failure-handling policy:
//!
//!   * **`requires`** — failure propagates. If the predecessor does not
//!     succeed the successor goes BLOCKED and cascades transitively.
//!     `Fetch→Verify→Install`, `Install(p)→Compile(p)`, `Ready(d)→Compile(p)`,
//!     `InstallArt(a)→Compile(jll)`.
//!   * **`after`** — pure ordering. Failure never propagates.
//!     `Probe(p)→Import(p)` (a cache MISS is the expected case, not an error),
//!     `Compile(p)→Publish(p)` (an object store being down must never fail an
//!     install), and lazy artifacts (`Artifacts/src/Artifacts.jl:459-468`
//!     excludes them from the download set; `:578-586` materialises them on
//!     demand, so their absence is not a failure of anything).
//!
//! ### Why `Ready(d)` gates `VerifyCache(p)` as well as `Compile(p)`
//!
//! The plan lists `Ready(d)→Compile(p)` "because `compilecache` *loads* `d`'s
//! cache" — `create_expr_cache` (`base/loading.jl:3062-3160`) spawns a Julia
//! that `require`s the package, which loads every dependency from ITS cache.
//! True, and not the whole story: `stale_cachefile` walks
//! `required_modules` and rejects the cache unless every dependency can be
//! located and its `build_id` matched (`base/loading.jl:4046-4082`). So
//! *checking* an imported cache needs the deps ready for the same reason
//! *building* one does.
//!
//! That is why every "p is usable" prerequisite — `Install(p)`, `Ready(d)` for
//! each direct dep, `InstallArt(a)` for each artifact — attaches to **each
//! existing arm tip** (`Compile(p)`, `VerifyCache(p)`) rather than to
//! `Ready(p)`. Attaching to `Ready(p)` instead would be fewer edges and wrong:
//! `Compile(p)` would become admissible before its deps were ready. Attaching
//! to only ONE arm is worse — it lets whichever arm was left ungated declare a
//! package ready with its dependencies missing, which then surfaces as a
//! `Compile` failure in some unrelated dependent. A package with no arm tips
//! at all (a sysimage stdlib: nothing to compile, nothing to cache) gets them
//! on `Ready(p)` directly, which keeps the invariant "`Ready(p)` is
//! transitively after `Ready(d)`" true for every package in the graph.
//!
//! ## The one extension beyond dynamod: `any`-nodes
//!
//! `Ready(p)` is satisfied by *either* `Import`+`VerifyCache` *or* `Compile`.
//! dynamod has no substitutes because init units have none. A package
//! manager's whole value is that a cache hit substitutes for work, so the
//! model needs them.
//!
//! An `any` node carries a list of `Alternative`s. Each names a **tip** — the
//! node whose success satisfies the `any` — and an **arm**, every node that
//! exists only to make that tip happen. The first tip to succeed wins; every
//! node in every losing arm is cancelled, including ones a worker is running
//! right now. Arms are explicit rather than derived: "the ancestors reachable
//! only through this tip" is computable, but it is a set-difference over the
//! whole ancestor closure recomputed at cancel time, and the builder knows the
//! answer for free.
//!
//! An `any` node may also have ORDINARY in-edges; they are not alternatives
//! and they behave exactly as they do on an `all` node. Distinguishing them
//! costs no third edge kind: an in-edge is an alternative iff its `from` is a
//! tip of the `any` node it points at.
//!
//! `Publish(p)` belongs to the compile arm — it exists to push what
//! `Compile(p)` built — so a cache hit cancels it along with the compile.
//! That leaves one deliberate asymmetry: a `Compile` that is **skipped**
//! (blocked by a failed dependency) does NOT block its `Publish`, because
//! their edge is `after`, and the plan classifies `Publish` under `after` so
//! that a dead object store can never fail an install. The executor's publish
//! action therefore has to tolerate "nothing was built" as a no-op. Making the
//! edge `requires` would model it more tightly and would make the store part
//! of the install's success criteria, which is the trade the classification
//! already refused.
//!
//! ## The readiness rule
//!
//! Exactly dynamod's, split so `after` can never block:
//!
//!   * `unmet[n]` counts in-edges not yet settled — **every** in-edge, both
//!     kinds. Ordering is ordering.
//!   * `blocked[n]` is set when a `requires` predecessor settles anything
//!     other than SUCCEEDED.
//!   * `unmet == 0 && !blocked` → admit.
//!   * `unmet == 0 && blocked` → settle SKIPPED, and cascade — a SKIPPED node
//!     is itself an unsuccessful predecessor, which is what makes the block
//!     transitive.
//!
//! There is **no upfront topological sort**. A sort would impose an order the
//! frontier is meant to discover at runtime from what actually finishes first,
//! and it would have to be recomputed every time an `any` node cancelled an
//! arm.
//!
//! Note what the rule does NOT say: a blocked node is not settled the moment
//! it is blocked. It waits until all of its in-edges have settled. That delay
//! is deliberate — settling early would leave predecessors decrementing an
//! `unmet` that no longer means anything, and would report SKIPPED for a node
//! whose other predecessors are still running.
//!
//! ## Cycles: refuse, do not skip
//!
//! Three-colour DFS before any worker starts. `build` returns
//! `error.Cyclic` and fills a `Diagnostic` with the cycle path, so there is no
//! way to obtain a `Graph` value that a `State` could then be started on. That
//! is deliberately stricter than Base, which scans for cycles
//! (`base/precompilation.jl:770-784`), `@warn`s, and then silently precompiles
//! everything else (`:1148-1150` reports "N skipped due to circular
//! dependency"). Base can afford that: a skipped package still loads, just
//! slowly. Ajt cannot — a cycle here means the manifest describes an
//! environment that cannot be installed, and finishing 99% of it while
//! printing a warning is how a container entrypoint ends up in a crash loop
//! with the real cause thirty lines up.
//!
//! ## No I/O
//!
//! Nothing in this file opens a file, touches a depot or talks to a network.
//! The builder takes already-parsed data — the caller resolves a manifest into
//! `Package`/`Artifact` records first. That is what keeps the edge semantics
//! and the readiness bookkeeping exhaustively unit-testable, which matters
//! more here than in most modules: every bug in this file shows up as a hang
//! or as work that ran in the wrong order, and neither has a stack trace.
//!
//! ## Allocation
//!
//! `build` takes an `arena` and returns a bundle of allocations that borrow
//! from it — nodes, edges, the CSR index, the alternative arms, every label —
//! plus the `Package`/`Artifact` slices the caller passed in, which are
//! borrowed, not copied. Drop the arena and the whole graph goes.
//!
//! `State` is the mutable half and is separate on purpose: the graph is shared
//! immutably by every worker, the state is owned by the one thread that runs
//! the frontier. It allocates from a `gpa` and has a `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const slug = @import("../julia/slug.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;

pub const NodeId = u32;

/// `NodeId` sentinel: "this stage has no node for this subject".
pub const no_node: NodeId = std.math.maxInt(NodeId);

const no_any: u32 = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

pub const Stage = enum(u8) {
    /// The single graph root. It is not work the scheduler performs — the
    /// manifest is already resolved by the time a graph exists — it is the
    /// node that makes "nothing may start before the environment is known" a
    /// structural fact rather than a convention.
    resolve,

    // --- per package -------------------------------------------------------
    /// Ask the shared content-addressed store whether it has a cache entry for
    /// this package's derivation key. A miss is not a failure.
    probe,
    /// Download the package tarball.
    fetch,
    /// sha256 of the tarball and the git tree hash of its content.
    verify,
    /// Publish the extracted tree into `<depot>/packages/<Name>/<slug>`.
    install,
    /// Pull the cache entry the probe found.
    import,
    /// `stale_cachefile` against the imported entry.
    verify_cache,
    /// Precompile locally.
    compile,
    /// `any`: the package is loadable. Satisfied by `verify_cache` OR
    /// `compile`; an `all` node when only one of them exists.
    ready,
    /// Push the freshly built cache entry to the shared store.
    publish,

    // --- per artifact, keyed by tree-sha1 ----------------------------------
    fetch_art,
    install_art,

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .resolve => "Resolve",
            .probe => "Probe",
            .fetch => "Fetch",
            .verify => "Verify",
            .install => "Install",
            .import => "Import",
            .verify_cache => "VerifyCache",
            .compile => "Compile",
            .ready => "Ready",
            .publish => "Publish",
            .fetch_art => "FetchArt",
            .install_art => "InstallArt",
        };
    }
};

/// Package stages, in the order they are slotted into `Graph.pkg_nodes`.
/// `Graph.find` is a table lookup rather than a scan because the executor
/// asks "is `Ready(d)` done" once per dependency edge per settle.
const pkg_stages = [_]Stage{
    .probe, .fetch, .verify, .install, .import, .verify_cache, .compile, .ready, .publish,
};
const art_stages = [_]Stage{ .fetch_art, .install_art };

fn pkgSlot(s: Stage) ?usize {
    inline for (pkg_stages, 0..) |ps, i| {
        if (ps == s) return i;
    }
    return null;
}

fn artSlot(s: Stage) ?usize {
    inline for (art_stages, 0..) |as, i| {
        if (as == s) return i;
    }
    return null;
}

/// What a node is about. Package and artifact indices are into the `Input`
/// slices the graph borrows, so a node can always name itself.
pub const Subject = union(enum) {
    global,
    package: u32,
    artifact: u32,
};

pub const Kind = enum {
    /// Every `requires` in-edge must succeed.
    all,
    /// One `Alternative` must succeed. Non-alternative in-edges still behave
    /// as they do on an `all` node.
    any,
};

pub const Node = struct {
    stage: Stage,
    subject: Subject,
    kind: Kind = .all,
};

pub const EdgeKind = enum {
    /// Failure propagates: the successor goes BLOCKED and cascades.
    requires,
    /// Ordering only: failure never propagates.
    after,
};

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    kind: EdgeKind,
};

/// One way to satisfy an `any` node.
pub const Alternative = struct {
    /// The node whose SUCCESS satisfies the `any`. It always has an in-edge
    /// into the `any` node, and that in-edge is what makes it an alternative.
    tip: NodeId,
    /// Every node that exists only to make `tip` happen, `tip` included.
    /// Cancelled as one unit when a rival wins.
    arm: []const NodeId,
};

pub const AnyNode = struct {
    node: NodeId,
    alts: []const Alternative,
};

// ---------------------------------------------------------------------------
// Builder input
// ---------------------------------------------------------------------------

/// One package as the scheduler sees it. The caller has already read the
/// manifest, consulted the depot and decided each of these — this module is
/// deliberately not the place where "is it a stdlib" is answered.
pub const Package = struct {
    name: []const u8,
    /// Unused by the graph itself — nodes are labelled by name and nothing
    /// keys on the UUID. It is carried because `Graph` borrows these records,
    /// so `graph.packages[i].uuid` is how the executor gets from a node back
    /// to a depot slug without threading the manifest alongside the graph.
    uuid: Uuid = .{ .bytes = [_]u8{0} ** 16 },
    /// `git-tree-sha1`. `null` means there is nothing to download: a stdlib,
    /// a `path`/dev entry, or a `[sources]` checkout. No `Fetch`/`Verify`/
    /// `Install` nodes are emitted for it.
    tree_hash: ?Sha1 = null,
    /// The source is already in the depot. Same effect as a null tree hash on
    /// the node set, different reason, so it is a separate field: a caller
    /// that got this wrong would silently re-download an installed package.
    installed: bool = false,
    /// DIRECT dependencies, as indices into `Input.packages`. Direct, not
    /// transitive: `Ready(d)` for a transitive dep is already ordered before
    /// `Compile(p)` through the direct chain, and adding the closure would put
    /// ~30k redundant edges in an Open-Reality-sized graph.
    deps: []const u32 = &.{},
    /// Indices into `Input.artifacts`.
    artifacts: []const u32 = &.{},
    /// This package needs a precompile cache of its own. False for a package
    /// that is already in the sysimage — there is nothing to build and
    /// nothing to import.
    precompile: bool = true,
    /// The shared store (B6) can serve this package. False collapses `Ready`
    /// from an `any` node to an ordinary one: no `Probe`/`Import`/
    /// `VerifyCache`/`Publish` at all. Ignored when `precompile` is false,
    /// since a package with no cache has no cache to share.
    cacheable: bool = true,
};

/// One artifact, keyed by its tree hash — the thing that is actually shared.
pub const Artifact = struct {
    /// The git tree hash of the artifact content. This IS its identity and
    /// its depot directory name (`Pkg/src/Artifacts.jl:341`).
    tree_hash: Sha1,
    /// Diagnostics only. An artifact has as many names as the JLLs that
    /// mention it; the first one wins.
    name: []const u8 = "",
    /// `lazy = true` (`Artifacts/src/Artifacts.jl:459-468`). Downloaded only
    /// on demand, so its edges into `Compile` are `after`, not `requires`.
    lazy: bool = false,
    /// Already in `<depot>/artifacts/<hash>`: no nodes at all.
    installed: bool = false,
};

pub const Input = struct {
    packages: []const Package = &.{},
    artifacts: []const Artifact = &.{},
};

pub const Error = error{
    /// A `Package.deps` entry is not a valid package index.
    BadDepIndex,
    /// A `Package.artifacts` entry is not a valid artifact index.
    BadArtifactIndex,
    /// A package depends on itself. Caught here rather than by the cycle
    /// scan because the self-edge would otherwise become `Ready(p)→Compile(p)`
    /// plus `Compile(p)→Ready(p)`, and the reported cycle would be two Ajt
    /// stages rather than the manifest defect it actually is.
    SelfDependency,
    /// The graph has a cycle. `Diagnostic.cycle` holds the path. This is the
    /// refusal: there is no way to get a `Graph` out of a cyclic input.
    Cyclic,
} || Allocator.Error;

/// Filled in on `error.Cyclic`. Modelled on `toml/parse.zig`'s `Diagnostic`:
/// the failure carries what a person needs to act on it, not just a tag.
pub const Diagnostic = struct {
    /// The cycle in traversal order with the entry node repeated at the end,
    /// so `a → b → c → a` is `{a, b, c, a}`. Empty on success.
    cycle: []const NodeId = &.{},
    /// `cycle`'s nodes already rendered — `"Compile(A)"`, `"Ready(B)"`, ... —
    /// because the graph they index into is exactly what `build` could not
    /// return.
    path: []const []const u8 = &.{},

    pub fn write(self: *const Diagnostic, w: *Writer) Writer.Error!void {
        if (self.path.len == 0) return;
        for (self.path, 0..) |label, i| {
            if (i != 0) try w.writeAll(" -> ");
            try w.writeAll(label);
        }
    }

    pub fn format(self: Diagnostic, w: *Writer) Writer.Error!void {
        try self.write(w);
    }
};

// ---------------------------------------------------------------------------
// The graph
// ---------------------------------------------------------------------------

pub const Graph = struct {
    /// Borrowed from the caller's `Input`, not copied.
    packages: []const Package,
    artifacts: []const Artifact,

    nodes: []const Node,
    edges: []const Edge,

    /// CSR over out-edges: the edge indices leaving node `n` are
    /// `out_edges[out_start[n]..out_start[n + 1]]`. `out_start` has
    /// `nodes.len + 1` entries.
    out_start: []const u32,
    out_edges: []const u32,

    /// In-degree over BOTH edge kinds — the initial value of `State.unmet`.
    in_degree: []const u32,

    any_nodes: []const AnyNode,
    /// node → index into `any_nodes`, or `no_any`. Dense because the settle
    /// path asks it for every successor of every settled node.
    any_index: []const u32,

    /// `packages.len * pkg_stages.len`, `no_node` where the stage was not
    /// emitted.
    pkg_nodes: []const NodeId,
    /// `artifacts.len * art_stages.len`.
    art_nodes: []const NodeId,

    pub fn outEdges(self: *const Graph, n: NodeId) []const u32 {
        return self.out_edges[self.out_start[n]..self.out_start[n + 1]];
    }

    /// The node for a (stage, subject) pair, or null if it was not emitted.
    pub fn find(self: *const Graph, stage: Stage, subject: Subject) ?NodeId {
        switch (subject) {
            .global => {
                if (stage != .resolve) return null;
                return if (self.nodes.len == 0) null else 0;
            },
            .package => |i| {
                if (i >= self.packages.len) return null;
                const slot = pkgSlot(stage) orelse return null;
                const id = self.pkg_nodes[i * pkg_stages.len + slot];
                return if (id == no_node) null else id;
            },
            .artifact => |i| {
                if (i >= self.artifacts.len) return null;
                const slot = artSlot(stage) orelse return null;
                const id = self.art_nodes[i * art_stages.len + slot];
                return if (id == no_node) null else id;
            },
        }
    }

    pub fn anyOf(self: *const Graph, n: NodeId) ?*const AnyNode {
        const i = self.any_index[n];
        if (i == no_any) return null;
        return &self.any_nodes[i];
    }

    /// `Compile(StaticArrays)`, `InstallArt(a1b2c3d4…)`, `Resolve`.
    pub fn writeNode(self: *const Graph, n: NodeId, w: *Writer) Writer.Error!void {
        const node = self.nodes[n];
        try w.writeAll(node.stage.label());
        switch (node.subject) {
            .global => {},
            .package => |i| try w.print("({s})", .{self.packages[i].name}),
            .artifact => |i| {
                const hex = std.fmt.bytesToHex(self.artifacts[i].tree_hash.bytes, .lower);
                // The first 8 hex characters identify an artifact as reliably
                // as git's short hashes do, and a 40-character node name makes
                // a cycle path unreadable.
                try w.print("({s})", .{hex[0..8]});
            },
        }
    }

    pub fn nodeLabel(self: *const Graph, arena: Allocator, n: NodeId) Allocator.Error![]const u8 {
        var aw: Writer.Allocating = .init(arena);
        errdefer aw.deinit();
        self.writeNode(n, &aw.writer) catch return error.OutOfMemory;
        return try aw.toOwnedSlice();
    }

    /// Node counts per stage, indexed by `@intFromEnum(Stage)`. For gates and
    /// for `--verbose`; nothing in the scheduler needs it.
    pub const stage_count = @typeInfo(Stage).@"enum".fields.len;

    pub fn countByStage(self: *const Graph) [stage_count]u32 {
        var out = [_]u32{0} ** stage_count;
        for (self.nodes) |node| out[@intFromEnum(node.stage)] += 1;
        return out;
    }

    pub fn edgeCountByKind(self: *const Graph, kind: EdgeKind) u32 {
        var n: u32 = 0;
        for (self.edges) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

const Wip = struct {
    arena: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    any_nodes: std.ArrayList(AnyNode) = .empty,

    fn addNode(self: *Wip, stage: Stage, subject: Subject, kind: Kind) Allocator.Error!NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena, .{ .stage = stage, .subject = subject, .kind = kind });
        return id;
    }

    fn addEdge(self: *Wip, from: NodeId, to: NodeId, kind: EdgeKind) Allocator.Error!void {
        try self.edges.append(self.arena, .{ .from = from, .to = to, .kind = kind });
    }
};

/// Build the stage graph. Returns `error.Cyclic` — with `diag` filled in — if
/// the result would contain a cycle, so a caller cannot hold a cyclic graph.
///
/// Everything reachable from the returned `Graph` is `arena`-allocated except
/// `input.packages` / `input.artifacts`, which are borrowed. Both must outlive
/// the graph.
pub fn build(arena: Allocator, input: Input, diag: ?*Diagnostic) Error!Graph {
    var wip: Wip = .{ .arena = arena };

    // Node 0 is always Resolve. Several places rely on it (`find(.resolve,
    // .global)`, the cycle scan's start order), so it is asserted rather than
    // assumed.
    const resolve_id = try wip.addNode(.resolve, .global, .all);
    std.debug.assert(resolve_id == 0);

    const np = input.packages.len;
    const na = input.artifacts.len;

    const pkg_nodes = try arena.alloc(NodeId, np * pkg_stages.len);
    @memset(pkg_nodes, no_node);
    const art_nodes = try arena.alloc(NodeId, na * art_stages.len);
    @memset(art_nodes, no_node);

    const slot_probe = comptime pkgSlot(.probe).?;
    const slot_fetch = comptime pkgSlot(.fetch).?;
    const slot_verify = comptime pkgSlot(.verify).?;
    const slot_install = comptime pkgSlot(.install).?;
    const slot_import = comptime pkgSlot(.import).?;
    const slot_vcache = comptime pkgSlot(.verify_cache).?;
    const slot_compile = comptime pkgSlot(.compile).?;
    const slot_ready = comptime pkgSlot(.ready).?;
    const slot_publish = comptime pkgSlot(.publish).?;
    const slot_fetch_art = comptime artSlot(.fetch_art).?;
    const slot_install_art = comptime artSlot(.install_art).?;

    // --- pass 1: nodes ------------------------------------------------------
    //
    // Ids are allocated before any edge is emitted because the dependency
    // edges point at OTHER packages' nodes, which may not exist yet in a
    // single-pass walk. Two passes cost one extra loop and remove the whole
    // class of "forward reference to a node that turned out not to exist".
    for (input.packages, 0..) |p, pi| {
        const subject: Subject = .{ .package = @intCast(pi) };
        const base = pi * pkg_stages.len;
        const needs_source = p.tree_hash != null and !p.installed;
        const cache = p.precompile and p.cacheable;

        if (needs_source) {
            pkg_nodes[base + slot_fetch] = try wip.addNode(.fetch, subject, .all);
            pkg_nodes[base + slot_verify] = try wip.addNode(.verify, subject, .all);
            pkg_nodes[base + slot_install] = try wip.addNode(.install, subject, .all);
        }
        if (cache) {
            pkg_nodes[base + slot_probe] = try wip.addNode(.probe, subject, .all);
            pkg_nodes[base + slot_import] = try wip.addNode(.import, subject, .all);
            pkg_nodes[base + slot_vcache] = try wip.addNode(.verify_cache, subject, .all);
            pkg_nodes[base + slot_publish] = try wip.addNode(.publish, subject, .all);
        }
        if (p.precompile) {
            pkg_nodes[base + slot_compile] = try wip.addNode(.compile, subject, .all);
        }
        // `Ready` always exists. Dependents point at it, and a package with
        // nothing to do still has to be reportable as done.
        pkg_nodes[base + slot_ready] = try wip.addNode(.ready, subject, if (cache and p.precompile) .any else .all);
    }

    for (input.artifacts, 0..) |a, ai| {
        if (a.installed) continue;
        const subject: Subject = .{ .artifact = @intCast(ai) };
        const base = ai * art_stages.len;
        art_nodes[base + slot_fetch_art] = try wip.addNode(.fetch_art, subject, .all);
        art_nodes[base + slot_install_art] = try wip.addNode(.install_art, subject, .all);
    }

    // --- pass 2: edges ------------------------------------------------------
    for (input.packages, 0..) |p, pi| {
        const base = pi * pkg_stages.len;
        const fetch = pkg_nodes[base + slot_fetch];
        const verify = pkg_nodes[base + slot_verify];
        const install = pkg_nodes[base + slot_install];
        const probe = pkg_nodes[base + slot_probe];
        const import = pkg_nodes[base + slot_import];
        const vcache = pkg_nodes[base + slot_vcache];
        const compile = pkg_nodes[base + slot_compile];
        const ready = pkg_nodes[base + slot_ready];
        const publish = pkg_nodes[base + slot_publish];

        if (fetch != no_node) {
            try wip.addEdge(fetch, verify, .requires);
            try wip.addEdge(verify, install, .requires);
        }
        if (probe != no_node) {
            // A cache MISS is the expected outcome half the time, so a failed
            // probe must not block the import that would report the same miss
            // more slowly. `after` is the whole reason this edge kind exists.
            try wip.addEdge(probe, import, .after);
            try wip.addEdge(import, vcache, .requires);
        }
        if (compile != no_node and publish != no_node) {
            try wip.addEdge(compile, publish, .after);
        }

        // The arm tips, and where the "p is usable" prerequisites attach. See
        // the module docs: BOTH tips, or `Ready` when there is no tip.
        var tip_buf: [2]NodeId = undefined;
        var ntips: usize = 0;
        if (compile != no_node) {
            tip_buf[ntips] = compile;
            ntips += 1;
        }
        if (vcache != no_node) {
            tip_buf[ntips] = vcache;
            ntips += 1;
        }
        const attach: []const NodeId = if (ntips == 0) &.{ready} else tip_buf[0..ntips];

        if (install != no_node) {
            for (attach) |t| try wip.addEdge(install, t, .requires);
        }
        for (p.deps) |di| {
            if (di >= input.packages.len) return error.BadDepIndex;
            if (di == pi) return error.SelfDependency;
            const dep_ready = pkg_nodes[di * pkg_stages.len + slot_ready];
            std.debug.assert(dep_ready != no_node);
            for (attach) |t| try wip.addEdge(dep_ready, t, .requires);
        }
        for (p.artifacts) |ai| {
            if (ai >= input.artifacts.len) return error.BadArtifactIndex;
            const art = input.artifacts[ai];
            const install_art = art_nodes[ai * art_stages.len + slot_install_art];
            if (install_art == no_node) continue; // already in the depot
            const kind: EdgeKind = if (art.lazy) .after else .requires;
            for (attach) |t| try wip.addEdge(install_art, t, kind);
        }

        // The alternatives. Emitted last so the tip in-edges are the LAST
        // in-edges of `Ready` — irrelevant to correctness, but it keeps a
        // dumped graph readable.
        if (compile != no_node) try wip.addEdge(compile, ready, .requires);
        if (vcache != no_node) try wip.addEdge(vcache, ready, .requires);

        if (wip.nodes.items[ready].kind == .any) {
            std.debug.assert(compile != no_node and vcache != no_node);
            // The import arm is everything that only exists to produce an
            // imported cache; the compile arm is the compile itself plus the
            // publish that has nothing to push if the compile is cancelled.
            const import_arm = try arena.dupe(NodeId, &.{ probe, import, vcache });
            const compile_arm = try arena.dupe(NodeId, &.{ compile, publish });
            const alts = try arena.dupe(Alternative, &.{
                .{ .tip = vcache, .arm = import_arm },
                .{ .tip = compile, .arm = compile_arm },
            });
            try wip.any_nodes.append(arena, .{ .node = ready, .alts = alts });
        }
    }

    for (input.artifacts, 0..) |_, ai| {
        const base = ai * art_stages.len;
        const fetch_art = art_nodes[base + slot_fetch_art];
        if (fetch_art == no_node) continue;
        try wip.addEdge(fetch_art, art_nodes[base + slot_install_art], .requires);
    }

    // --- pass 3: hang every chain head off Resolve --------------------------
    //
    // The property worth having is "a failed Resolve blocks the whole graph",
    // and it only holds if every node is reachable from `Resolve` along
    // `requires` edges. So the head test is **no `requires` in-edge**, not "no
    // in-edge at all". The difference is not cosmetic: `Import(p)`'s only
    // in-edge is `Probe(p) --after→`, so under an in-degree-0 test it would
    // have no requires-predecessor anywhere, a failed `Resolve` would leave it
    // admissible, and a run whose manifest could not be read would still go
    // and ask an object store about packages it had failed to identify.
    // Verified by the "a failed Resolve blocks the entire graph" test, which
    // found exactly that (4 of 19 nodes survived).
    //
    // Only the heads need an edge: everything deeper inherits the ordering
    // transitively, and `Resolve → n` for all n would double the edge count to
    // say nothing new.
    {
        const req_in = try arena.alloc(u32, wip.nodes.items.len);
        defer arena.free(req_in);
        @memset(req_in, 0);
        for (wip.edges.items) |e| {
            if (e.kind == .requires) req_in[e.to] += 1;
        }
        for (1..wip.nodes.items.len) |n| {
            if (req_in[n] == 0) try wip.addEdge(resolve_id, @intCast(n), .requires);
        }
    }

    // --- pass 4: freeze -----------------------------------------------------
    const nodes = wip.nodes.items;
    const edges = wip.edges.items;

    const in_degree = try arena.alloc(u32, nodes.len);
    @memset(in_degree, 0);
    const out_count = try arena.alloc(u32, nodes.len);
    @memset(out_count, 0);
    for (edges) |e| {
        in_degree[e.to] += 1;
        out_count[e.from] += 1;
    }

    const out_start = try arena.alloc(u32, nodes.len + 1);
    var acc: u32 = 0;
    for (nodes, 0..) |_, i| {
        out_start[i] = acc;
        acc += out_count[i];
    }
    out_start[nodes.len] = acc;

    const out_edges = try arena.alloc(u32, edges.len);
    const cursor = try arena.alloc(u32, nodes.len);
    @memcpy(cursor, out_start[0..nodes.len]);
    for (edges, 0..) |e, ei| {
        out_edges[cursor[e.from]] = @intCast(ei);
        cursor[e.from] += 1;
    }
    arena.free(cursor);
    arena.free(out_count);

    const any_index = try arena.alloc(u32, nodes.len);
    @memset(any_index, no_any);
    for (wip.any_nodes.items, 0..) |an, i| any_index[an.node] = @intCast(i);

    const g: Graph = .{
        .packages = input.packages,
        .artifacts = input.artifacts,
        .nodes = nodes,
        .edges = edges,
        .out_start = out_start,
        .out_edges = out_edges,
        .in_degree = in_degree,
        .any_nodes = wip.any_nodes.items,
        .any_index = any_index,
        .pkg_nodes = pkg_nodes,
        .art_nodes = art_nodes,
    };

    // The four properties `State`'s `any` handling actually rests on. All four
    // hold by construction for the builder above; they are asserted because
    // the next person to add an alternative (or to hang a `LoadCheck` off
    // `Compile`) will break one of them, and each break is a hang or a
    // cancelled prerequisite rather than an error.
    if (std.debug.runtime_safety) {
        for (g.any_nodes) |an| {
            // (1) An `any` with one alternative is an `all` with extra steps.
            std.debug.assert(an.alts.len >= 2);
            for (an.alts, 0..) |alt, i| {
                // (2) Each tip really has an in-edge into the `any` node —
                // that edge is the only thing that makes it an alternative,
                // and `alt_left` counts on exactly one of them per tip.
                var edges_in: u32 = 0;
                for (g.outEdges(alt.tip)) |ei| {
                    if (g.edges[ei].to == an.node) edges_in += 1;
                }
                std.debug.assert(edges_in == 1);

                // (3) Arms are pairwise disjoint. `cancelLosers` skips only
                // the WINNING arm, so a node shared with a losing arm would be
                // cancelled even though its own alternative won.
                for (an.alts[i + 1 ..]) |other| {
                    for (alt.arm) |m| {
                        for (other.arm) |o| std.debug.assert(m != o);
                    }
                }

                // (4) An arm is closed: nothing inside it feeds anything
                // outside the arm except the `any` node itself. This is the
                // property that makes "cancel the whole losing arm" safe — a
                // stray out-edge would take a node something else still needs
                // down with it.
                for (alt.arm) |m| {
                    if (m == no_node) continue;
                    for (g.outEdges(m)) |ei| {
                        const to = g.edges[ei].to;
                        if (to == an.node) continue;
                        var inside = false;
                        for (alt.arm) |o| {
                            if (o == to) inside = true;
                        }
                        std.debug.assert(inside);
                    }
                }
            }
        }
    }

    // --- the refusal --------------------------------------------------------
    if (try findCycle(arena, &g)) |cycle| {
        if (diag) |d| {
            const path = try arena.alloc([]const u8, cycle.len);
            for (cycle, 0..) |n, i| path[i] = try g.nodeLabel(arena, n);
            d.* = .{ .cycle = cycle, .path = path };
        }
        return error.Cyclic;
    }

    return g;
}

// ---------------------------------------------------------------------------
// Cycle detection
// ---------------------------------------------------------------------------

const Colour = enum(u8) { white, grey, black };

/// Three-colour DFS. Returns the first cycle found, in traversal order with
/// the entry node repeated at the end (`a → b → c → a` is `{a, b, c, a}`), or
/// null when the graph is acyclic.
///
/// Iterative, not recursive: an Open-Reality-sized graph is ~1,800 nodes and
/// the deepest package chain is well short of that, but "well short" is not a
/// bound, and a stack overflow in the pre-flight check of a package manager
/// would be an especially stupid way to fail.
///
/// BOTH edge kinds are traversed. An `after` cycle never propagates a failure,
/// which is exactly why it is worth refusing: it does not fail, it *hangs* —
/// two nodes each waiting for the other's `unmet` to reach zero, with no
/// worker to blame.
pub fn findCycle(arena: Allocator, g: *const Graph) Allocator.Error!?[]const NodeId {
    if (g.nodes.len == 0) return null;

    const colour = try arena.alloc(Colour, g.nodes.len);
    defer arena.free(colour);
    @memset(colour, .white);

    const Frame = struct { node: NodeId, cursor: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(arena);

    for (0..g.nodes.len) |start| {
        if (colour[start] != .white) continue;
        colour[start] = .grey;
        try stack.append(arena, .{ .node = @intCast(start), .cursor = 0 });

        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const out = g.outEdges(top.node);
            if (top.cursor < out.len) {
                const e = g.edges[out[top.cursor]];
                top.cursor += 1;
                switch (colour[e.to]) {
                    .white => {
                        colour[e.to] = .grey;
                        try stack.append(arena, .{ .node = e.to, .cursor = 0 });
                    },
                    // Grey means "on the current DFS path", so the path from
                    // its frame to the top IS the cycle.
                    .grey => {
                        var at: usize = 0;
                        while (stack.items[at].node != e.to) : (at += 1) {}
                        const cycle = try arena.alloc(NodeId, stack.items.len - at + 1);
                        for (stack.items[at..], 0..) |f, i| cycle[i] = f.node;
                        cycle[cycle.len - 1] = e.to;
                        return cycle;
                    },
                    .black => {},
                }
            } else {
                colour[top.node] = .black;
                _ = stack.pop();
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Runtime state — the readiness bookkeeping
// ---------------------------------------------------------------------------

pub const Status = enum(u8) {
    /// Waiting on in-edges.
    pending,
    /// `unmet == 0 && !blocked`. The executor may run it.
    ready,
    /// Handed to a worker.
    running,
    succeeded,
    failed,
    /// `unmet == 0 && blocked`: a `requires` predecessor did not succeed.
    skipped,
    /// An `any` rival won. Distinct from `skipped` because a cancelled node
    /// may have been mid-flight and the executor has to abort it, whereas a
    /// skipped one never started.
    cancelled,

    pub fn settled(self: Status) bool {
        return switch (self) {
            .pending, .ready, .running => false,
            .succeeded, .failed, .skipped, .cancelled => true,
        };
    }
};

/// What one `settle` (or `seed`) changed. The executor drains it and clears
/// it; the lists are additive within a call.
///
/// A node can appear in BOTH lists across a run — admitted, then cancelled
/// before a worker picked it up. That is not a bug and does not need
/// filtering: `begin` is the single point that decides whether a node is
/// actually run, and it returns false for anything that is no longer `.ready`.
pub const Delta = struct {
    admitted: std.ArrayList(NodeId) = .empty,
    cancelled: std.ArrayList(NodeId) = .empty,

    /// `gpa` must be the same allocator every `seed`/`settle` call was given —
    /// they grow these lists, and `State.reserve` pre-sizes them so the
    /// cascade itself cannot fail partway.
    pub fn deinit(self: *Delta, gpa: Allocator) void {
        self.admitted.deinit(gpa);
        self.cancelled.deinit(gpa);
        self.* = undefined;
    }

    pub fn clear(self: *Delta) void {
        self.admitted.clearRetainingCapacity();
        self.cancelled.clearRetainingCapacity();
    }
};

pub const Tally = struct {
    pending: u32 = 0,
    ready: u32 = 0,
    running: u32 = 0,
    succeeded: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    cancelled: u32 = 0,
};

/// The mutable half of the frontier: everything the readiness rule reads and
/// writes. One `State` per run, owned by whichever thread drives the frontier;
/// the `Graph` it points at is immutable and shared.
pub const State = struct {
    graph: *const Graph,
    status: []Status,
    /// In-edges not yet settled.
    unmet: []u32,
    /// A `requires` predecessor settled unsuccessfully.
    blocked: []bool,
    /// Per `any` node: alternatives whose tip has not settled yet.
    alt_left: []u32,
    /// Per `any` node: an alternative has already succeeded.
    alt_won: []bool,
    settled_count: u32 = 0,
    /// Cascade work list. Holds nodes whose status is already assigned and
    /// whose out-edges still have to be walked. Reused across calls.
    queue: std.ArrayList(NodeId) = .empty,

    pub fn init(gpa: Allocator, g: *const Graph) Allocator.Error!State {
        const status = try gpa.alloc(Status, g.nodes.len);
        errdefer gpa.free(status);
        @memset(status, .pending);

        const unmet = try gpa.alloc(u32, g.nodes.len);
        errdefer gpa.free(unmet);
        @memcpy(unmet, g.in_degree);

        const blocked = try gpa.alloc(bool, g.nodes.len);
        errdefer gpa.free(blocked);
        @memset(blocked, false);

        const alt_left = try gpa.alloc(u32, g.any_nodes.len);
        errdefer gpa.free(alt_left);
        for (g.any_nodes, 0..) |an, i| alt_left[i] = @intCast(an.alts.len);

        const alt_won = try gpa.alloc(bool, g.any_nodes.len);
        errdefer gpa.free(alt_won);
        @memset(alt_won, false);

        return .{
            .graph = g,
            .status = status,
            .unmet = unmet,
            .blocked = blocked,
            .alt_left = alt_left,
            .alt_won = alt_won,
        };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        gpa.free(self.status);
        gpa.free(self.unmet);
        gpa.free(self.blocked);
        gpa.free(self.alt_left);
        gpa.free(self.alt_won);
        self.queue.deinit(gpa);
        self.* = undefined;
    }

    /// Admit every node with no in-edges — on a graph from `build` that is
    /// `Resolve` alone. Call once, before the first `settle`.
    pub fn seed(self: *State, gpa: Allocator, delta: *Delta) Allocator.Error!void {
        try self.reserve(gpa, delta);
        for (self.status, 0..) |*s, n| {
            if (s.* != .pending or self.unmet[n] != 0) continue;
            // A `blocked` node cannot exist before anything has settled, so
            // there is no skip branch here.
            s.* = .ready;
            delta.admitted.appendAssumeCapacity(@intCast(n));
        }
    }

    /// `.ready` → `.running`. Returns false when the node is no longer
    /// runnable — an `any` rival cancelled it between admission and pickup —
    /// which is the executor's cue to drop it silently rather than run work
    /// whose result will be discarded.
    pub fn begin(self: *State, n: NodeId) bool {
        if (self.status[n] != .ready) return false;
        self.status[n] = .running;
        return true;
    }

    /// Reserve enough room for the worst case of ONE cascade, so that
    /// everything after it is infallible.
    ///
    /// This is not micro-optimisation, it is the only way the cascade can be
    /// crash-safe. A settle that gave up halfway — status written, node never
    /// queued for propagation — leaves every successor's `unmet` one
    /// decrement short *forever*, and a short `unmet` never reaches zero. That
    /// is a silent hang, which is strictly worse than the `error.OutOfMemory`
    /// it came from. So all the allocation happens up front, before a single
    /// byte of state is touched, and the cascade itself cannot fail.
    ///
    /// The bound is `nodes.len` on each list: `mark` settles any node at most
    /// once, so one cascade can queue, cancel or admit each node at most once.
    fn reserve(self: *State, gpa: Allocator, delta: *Delta) Allocator.Error!void {
        const n = self.status.len;
        try self.queue.ensureTotalCapacity(gpa, n);
        // `ensureUNUSED` because a Delta accumulates until the caller clears it.
        try delta.admitted.ensureUnusedCapacity(gpa, n);
        try delta.cancelled.ensureUnusedCapacity(gpa, n);
    }

    /// Record an outcome and cascade.
    ///
    /// Returns false when `n` was ALREADY settled, in which case `ok` is
    /// discarded and nothing cascades. That is not defensive noise: it is the
    /// documented resolution of the one race the `any` extension creates — a
    /// worker finishing an `Import` a nanosecond after the rival `Compile`
    /// cancelled it. Without it the cancelled node would settle twice and
    /// every successor's `unmet` would go one too low, which admits work whose
    /// prerequisites have not finished.
    ///
    /// The only error it can return comes from `reserve`, which runs before
    /// anything is mutated — so an error leaves the `State` exactly as it was
    /// and the call may be retried.
    pub fn settle(self: *State, gpa: Allocator, n: NodeId, ok: bool, delta: *Delta) Allocator.Error!bool {
        if (self.status[n].settled()) return false;
        // `begin` is the single admission point. Settling a node that never
        // went through it means work ran whose prerequisites had not finished
        // — the exact silent mis-ordering this module exists to prevent, and
        // one that leaves no trace at runtime. Checked, not tolerated.
        std.debug.assert(self.status[n] == .running);
        try self.reserve(gpa, delta);

        self.queue.clearRetainingCapacity();
        self.mark(n, if (ok) .succeeded else .failed, delta);

        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            self.propagate(self.queue.items[i], delta);
        }
        return true;
    }

    /// Assign a final status and queue the node for propagation. Marking is
    /// separated from propagating so that a whole losing ARM is marked
    /// cancelled before any of it propagates — otherwise cancelling `Probe`
    /// would admit `Import` (their edge is `after`, so nothing blocks) one
    /// instant before cancelling `Import` too.
    ///
    /// Infallible: `reserve` has already made room. See its doc comment.
    fn mark(self: *State, n: NodeId, final: Status, delta: *Delta) void {
        std.debug.assert(final.settled());
        if (self.status[n].settled()) return;
        self.status[n] = final;
        self.settled_count += 1;
        if (final == .cancelled) delta.cancelled.appendAssumeCapacity(n);
        self.queue.appendAssumeCapacity(n);
    }

    fn propagate(self: *State, n: NodeId, delta: *Delta) void {
        const g = self.graph;
        const final = self.status[n];
        const succeeded = final == .succeeded;

        for (g.outEdges(n)) |ei| {
            const e = g.edges[ei];
            const s = e.to;
            std.debug.assert(self.unmet[s] > 0);
            self.unmet[s] -= 1;

            var handled_as_alternative = false;
            if (g.anyOf(s)) |an| {
                if (altIndexOfTip(an, n)) |k| {
                    handled_as_alternative = true;
                    const ai = g.any_index[s];
                    // Each tip has exactly one edge into its `any` node and
                    // `mark` propagates each node once, so this counter tracks
                    // the tips one-for-one. Asserted because an underflow here
                    // never reaches zero, which means `blocked` is never set
                    // and the `any` node hangs instead of failing.
                    std.debug.assert(self.alt_left[ai] > 0);
                    self.alt_left[ai] -= 1;
                    if (succeeded and !self.alt_won[ai]) {
                        self.alt_won[ai] = true;
                        self.cancelLosers(an, k, delta);
                    } else if (!self.alt_won[ai] and self.alt_left[ai] == 0) {
                        // Every way of satisfying the `any` is gone. Only NOW
                        // is it blocked -- one failed alternative is the
                        // ordinary case, not an error.
                        self.blocked[s] = true;
                    }
                }
            }
            if (!handled_as_alternative and e.kind == .requires and !succeeded) {
                self.blocked[s] = true;
            }

            // The successor may already be settled: `cancelLosers` marks whole
            // arms, including nodes whose predecessors are still running.
            if (self.status[s].settled()) continue;
            if (self.unmet[s] != 0) continue;
            if (self.blocked[s]) {
                self.mark(s, .skipped, delta);
            } else {
                self.status[s] = .ready;
                delta.admitted.appendAssumeCapacity(s);
            }
        }
    }

    fn cancelLosers(self: *State, an: *const AnyNode, winner: usize, delta: *Delta) void {
        for (an.alts, 0..) |alt, k| {
            if (k == winner) continue;
            for (alt.arm) |m| {
                if (m == no_node) continue;
                self.mark(m, .cancelled, delta);
            }
        }
    }

    pub fn done(self: *const State) bool {
        return self.settled_count == self.status.len;
    }

    pub fn tally(self: *const State) Tally {
        var t: Tally = .{};
        for (self.status) |s| {
            switch (s) {
                .pending => t.pending += 1,
                .ready => t.ready += 1,
                .running => t.running += 1,
                .succeeded => t.succeeded += 1,
                .failed => t.failed += 1,
                .skipped => t.skipped += 1,
                .cancelled => t.cancelled += 1,
            }
        }
        return t;
    }
};

fn altIndexOfTip(an: *const AnyNode, tip: NodeId) ?usize {
    for (an.alts, 0..) |alt, i| {
        if (alt.tip == tip) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Drive a graph to completion with a caller-supplied verdict per node. The
/// executor is a sibling unit; this is the two-line stand-in that lets the
/// readiness rule be tested on its own.
const Driver = struct {
    state: State,
    delta: Delta = .{},
    /// Nodes admitted and not yet settled, in admission order.
    queue: std.ArrayList(NodeId) = .empty,

    fn init(gpa: Allocator, g: *const Graph) !Driver {
        var d: Driver = .{ .state = try State.init(gpa, g) };
        try d.state.seed(gpa, &d.delta);
        try d.drain(gpa);
        return d;
    }

    fn deinit(self: *Driver, gpa: Allocator) void {
        self.state.deinit(gpa);
        self.delta.deinit(gpa);
        self.queue.deinit(gpa);
    }

    fn drain(self: *Driver, gpa: Allocator) !void {
        for (self.delta.admitted.items) |n| try self.queue.append(gpa, n);
        self.delta.clear();
    }

    /// Settle the oldest admitted node. `verdict` decides success per node.
    fn step(self: *Driver, gpa: Allocator, verdict: *const fn (NodeId) bool) !?NodeId {
        while (self.queue.items.len != 0) {
            const n = self.queue.orderedRemove(0);
            if (!self.state.begin(n)) continue; // cancelled under us
            _ = try self.state.settle(gpa, n, verdict(n), &self.delta);
            try self.drain(gpa);
            return n;
        }
        return null;
    }

    fn runAll(self: *Driver, gpa: Allocator, verdict: *const fn (NodeId) bool) !void {
        while (try self.step(gpa, verdict) != null) {}
    }
};

fn allOk(_: NodeId) bool {
    return true;
}

test "a single leaf package gets one node per stage" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    // Resolve + Fetch/Verify/Install + Probe/Import/VerifyCache/Publish +
    // Compile + Ready.
    try testing.expectEqual(@as(usize, 10), g.nodes.len);
    const by_stage = g.countByStage();
    inline for (.{ .resolve, .probe, .fetch, .verify, .install, .import, .verify_cache, .compile, .ready, .publish }) |s| {
        try testing.expectEqual(@as(u32, 1), by_stage[@intFromEnum(@as(Stage, s))]);
    }
    try testing.expectEqual(@as(u32, 0), by_stage[@intFromEnum(Stage.fetch_art)]);

    // Ready is the `any` node; nothing else is.
    const ready = g.find(.ready, .{ .package = 0 }).?;
    try testing.expectEqual(Kind.any, g.nodes[ready].kind);
    try testing.expectEqual(@as(usize, 1), g.any_nodes.len);
    try testing.expectEqual(ready, g.any_nodes[0].node);

    // Only Resolve is a source.
    for (g.in_degree, 0..) |d, n| {
        if (n == 0) try testing.expectEqual(@as(u32, 0), d) else try testing.expect(d > 0);
    }

    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try g.writeNode(ready, &w);
    try testing.expectEqualStrings("Ready(Foo)", w.buffered());
}

test "an installed stdlib collapses to a single Ready node" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "LinearAlgebra", .precompile = false, .cacheable = false }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    try testing.expectEqual(@as(usize, 2), g.nodes.len); // Resolve + Ready
    const ready = g.find(.ready, .{ .package = 0 }).?;
    try testing.expectEqual(Kind.all, g.nodes[ready].kind);
    try testing.expect(g.find(.compile, .{ .package = 0 }) == null);
    try testing.expect(g.find(.probe, .{ .package = 0 }) == null);
    try testing.expectEqual(@as(usize, 0), g.any_nodes.len);
}

test "prerequisites attach to BOTH arm tips, or to Ready when there is none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const arts = [_]Artifact{.{ .tree_hash = .{ .bytes = [_]u8{9} ** 20 } }};
    const pkgs = [_]Package{
        .{ .name = "Dep", .precompile = false, .cacheable = false },
        .{ .name = "Jll", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0}, .artifacts = &.{0} },
    };
    const g = try build(arena, .{ .packages = &pkgs, .artifacts = &arts }, null);

    const dep_ready = g.find(.ready, .{ .package = 0 }).?;
    const compile = g.find(.compile, .{ .package = 1 }).?;
    const vcache = g.find(.verify_cache, .{ .package = 1 }).?;
    const install = g.find(.install, .{ .package = 1 }).?;
    const install_art = g.find(.install_art, .{ .artifact = 0 }).?;

    try testing.expect(hasEdge(&g, dep_ready, compile, .requires));
    try testing.expect(hasEdge(&g, dep_ready, vcache, .requires));
    try testing.expect(hasEdge(&g, install, compile, .requires));
    try testing.expect(hasEdge(&g, install, vcache, .requires));
    try testing.expect(hasEdge(&g, install_art, compile, .requires));
    try testing.expect(hasEdge(&g, install_art, vcache, .requires));

    // ...and NOT straight to Ready, which would let a cache hit declare the
    // package ready with its source missing.
    const ready = g.find(.ready, .{ .package = 1 }).?;
    try testing.expect(!hasEdge(&g, install, ready, .requires));
}

test "a lazy artifact orders but never blocks" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const arts = [_]Artifact{.{ .tree_hash = .{ .bytes = [_]u8{7} ** 20 }, .lazy = true }};
    const pkgs = [_]Package{.{ .name = "Jll", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .artifacts = &.{0} }};
    const g = try build(arena, .{ .packages = &pkgs, .artifacts = &arts }, null);

    const install_art = g.find(.install_art, .{ .artifact = 0 }).?;
    const compile = g.find(.compile, .{ .package = 0 }).?;
    try testing.expect(hasEdge(&g, install_art, compile, .after));
    try testing.expect(!hasEdge(&g, install_art, compile, .requires));
}

test "an already-installed artifact gets no nodes at all" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const arts = [_]Artifact{.{ .tree_hash = .{ .bytes = [_]u8{7} ** 20 }, .installed = true }};
    const pkgs = [_]Package{.{ .name = "Jll", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .artifacts = &.{0} }};
    const g = try build(arena, .{ .packages = &pkgs, .artifacts = &arts }, null);

    try testing.expect(g.find(.fetch_art, .{ .artifact = 0 }) == null);
    try testing.expect(g.find(.install_art, .{ .artifact = 0 }) == null);
    try testing.expectEqual(@as(u32, 0), g.countByStage()[@intFromEnum(Stage.fetch_art)]);
}

test "requires: a failed Fetch cascades BLOCKED transitively" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{
        .{ .name = "Base", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } },
        .{ .name = "Mid", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
        .{ .name = "Top", .tree_hash = .{ .bytes = [_]u8{3} ** 20 }, .deps = &.{1} },
    };
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    const fetch0 = g.find(.fetch, .{ .package = 0 }).?;
    const Fail = struct {
        var target: NodeId = 0;
        fn verdict(n: NodeId) bool {
            return n != target;
        }
    };
    Fail.target = fetch0;
    try d.runAll(testing.allocator, Fail.verdict);

    try testing.expect(d.state.done());
    // Base's whole chain dies...
    try testing.expectEqual(Status.failed, d.state.status[fetch0]);
    for ([_]Stage{ .verify, .install, .compile, .verify_cache, .ready }) |st| {
        const n = g.find(st, .{ .package = 0 }).?;
        try testing.expectEqual(Status.skipped, d.state.status[n]);
    }
    // ...and so does everything downstream of Ready(Base), transitively.
    for ([_]usize{ 1, 2 }) |pi| {
        for ([_]Stage{ .compile, .verify_cache, .ready }) |st| {
            const n = g.find(st, .{ .package = @intCast(pi) }).?;
            try testing.expectEqual(Status.skipped, d.state.status[n]);
        }
    }
    // But their OWN downloads had no failed predecessor and still ran.
    try testing.expectEqual(Status.succeeded, d.state.status[g.find(.install, .{ .package = 1 }).?]);
    try testing.expectEqual(Status.succeeded, d.state.status[g.find(.install, .{ .package = 2 }).?]);
}

test "after: a failed Probe blocks nothing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    const probe = g.find(.probe, .{ .package = 0 }).?;
    const import = g.find(.import, .{ .package = 0 }).?;
    const Fail = struct {
        var target: NodeId = 0;
        fn verdict(n: NodeId) bool {
            return n != target;
        }
    };
    Fail.target = probe;
    try d.runAll(testing.allocator, Fail.verdict);

    try testing.expect(d.state.done());
    try testing.expectEqual(Status.failed, d.state.status[probe]);
    // The import ran anyway -- a store that cannot be probed is not an error.
    try testing.expectEqual(Status.succeeded, d.state.status[import]);
    try testing.expect(!d.state.blocked[import]);
}

test "after: a failed Publish never fails the install" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    // Make the cache miss so Compile wins and Publish actually runs.
    const import = g.find(.import, .{ .package = 0 }).?;
    const publish = g.find(.publish, .{ .package = 0 }).?;
    const Fail = struct {
        var a_target: NodeId = 0;
        var b_target: NodeId = 0;
        fn verdict(n: NodeId) bool {
            return n != a_target and n != b_target;
        }
    };
    Fail.a_target = import;
    Fail.b_target = publish;
    try d.runAll(testing.allocator, Fail.verdict);

    try testing.expect(d.state.done());
    try testing.expectEqual(Status.failed, d.state.status[publish]);
    try testing.expectEqual(Status.succeeded, d.state.status[g.find(.ready, .{ .package = 0 }).?]);
}

test "any: a cache hit satisfies Ready and cancels the compile arm" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var st = try State.init(testing.allocator, &g);
    defer st.deinit(testing.allocator);
    var delta: Delta = .{};
    defer delta.deinit(testing.allocator);

    const gpa = testing.allocator;
    try st.seed(gpa, &delta);
    try testing.expect(st.begin(0));
    try testing.expect(try st.settle(gpa, 0, true, &delta)); // Resolve

    // Walk the import arm to VerifyCache. Install has to run on the way: it
    // gates VerifyCache too, which is the point of the both-tips rule.
    for ([_]Stage{ .probe, .fetch, .verify, .install, .import, .verify_cache }) |s| {
        const n = g.find(s, .{ .package = 0 }).?;
        try testing.expect(st.begin(n));
        try testing.expect(try st.settle(gpa, n, true, &delta));
    }

    const ready = g.find(.ready, .{ .package = 0 }).?;
    const compile = g.find(.compile, .{ .package = 0 }).?;
    const publish = g.find(.publish, .{ .package = 0 }).?;
    try testing.expectEqual(Status.ready, st.status[ready]);
    try testing.expectEqual(Status.cancelled, st.status[compile]);
    try testing.expectEqual(Status.cancelled, st.status[publish]);
    // Cancelled means "abort it if you started it" -- the executor is told.
    try testing.expect(std.mem.indexOfScalar(NodeId, delta.cancelled.items, compile) != null);
    // ...and a worker that finishes the cancelled node anyway is refused.
    try testing.expect(!st.begin(compile));
    try testing.expect(!try st.settle(gpa, compile, true, &delta));
    try testing.expectEqual(Status.cancelled, st.status[compile]);

    try testing.expect(st.begin(ready));
    try testing.expect(try st.settle(gpa, ready, true, &delta));
    try testing.expect(st.done());
}

test "any: a cache miss falls through to Compile" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } }};
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    const import = g.find(.import, .{ .package = 0 }).?;
    const Miss = struct {
        var target: NodeId = 0;
        fn verdict(n: NodeId) bool {
            return n != target;
        }
    };
    Miss.target = import;
    try d.runAll(testing.allocator, Miss.verdict);

    try testing.expect(d.state.done());
    try testing.expectEqual(Status.failed, d.state.status[import]);
    // The import arm's tip is skipped, NOT the Ready it feeds.
    try testing.expectEqual(Status.skipped, d.state.status[g.find(.verify_cache, .{ .package = 0 }).?]);
    try testing.expectEqual(Status.succeeded, d.state.status[g.find(.compile, .{ .package = 0 }).?]);
    try testing.expectEqual(Status.succeeded, d.state.status[g.find(.ready, .{ .package = 0 }).?]);
}

test "any: Ready is blocked only when every alternative is gone" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{
        .{ .name = "Foo", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } },
        .{ .name = "Bar", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
    };
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    const Fail = struct {
        var import: NodeId = 0;
        var compile: NodeId = 0;
        fn verdict(n: NodeId) bool {
            return n != import and n != compile;
        }
    };
    Fail.import = g.find(.import, .{ .package = 0 }).?;
    Fail.compile = g.find(.compile, .{ .package = 0 }).?;
    try d.runAll(testing.allocator, Fail.verdict);

    try testing.expect(d.state.done());
    const ready0 = g.find(.ready, .{ .package = 0 }).?;
    try testing.expect(d.state.blocked[ready0]);
    try testing.expectEqual(Status.skipped, d.state.status[ready0]);
    // And the dependent dies with it, through both of its tips.
    try testing.expectEqual(Status.skipped, d.state.status[g.find(.compile, .{ .package = 1 }).?]);
    try testing.expectEqual(Status.skipped, d.state.status[g.find(.verify_cache, .{ .package = 1 }).?]);
    try testing.expectEqual(Status.skipped, d.state.status[g.find(.ready, .{ .package = 1 }).?]);
}

test "a blocked node waits for its other predecessors before it is skipped" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // Compile(Top) has three requires-preds: Install(Top), Ready(A), Ready(B).
    const pkgs = [_]Package{
        .{ .name = "A", .precompile = false, .cacheable = false },
        .{ .name = "B", .precompile = false, .cacheable = false },
        .{ .name = "Top", .tree_hash = .{ .bytes = [_]u8{3} ** 20 }, .deps = &.{ 0, 1 } },
    };
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var st = try State.init(testing.allocator, &g);
    defer st.deinit(testing.allocator);
    var delta: Delta = .{};
    defer delta.deinit(testing.allocator);
    const gpa = testing.allocator;
    try st.seed(gpa, &delta);

    const ready_a = g.find(.ready, .{ .package = 0 }).?;
    const ready_b = g.find(.ready, .{ .package = 1 }).?;
    const compile = g.find(.compile, .{ .package = 2 }).?;

    try testing.expect(st.begin(0));
    _ = try st.settle(gpa, 0, true, &delta); // Resolve
    try testing.expect(st.begin(ready_a));
    _ = try st.settle(gpa, ready_a, false, &delta);

    // Blocked, but NOT settled: Ready(B) and Install(Top) are still out there.
    try testing.expect(st.blocked[compile]);
    try testing.expectEqual(Status.pending, st.status[compile]);

    try testing.expect(st.begin(ready_b));
    _ = try st.settle(gpa, ready_b, true, &delta);
    try testing.expectEqual(Status.pending, st.status[compile]);

    for ([_]Stage{ .fetch, .verify, .install }) |s| {
        const n = g.find(s, .{ .package = 2 }).?;
        try testing.expect(st.begin(n));
        _ = try st.settle(gpa, n, true, &delta);
    }
    try testing.expectEqual(Status.skipped, st.status[compile]);
}

test "everything settles exactly once on a clean run" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const arts = [_]Artifact{
        .{ .tree_hash = .{ .bytes = [_]u8{8} ** 20 } },
        .{ .tree_hash = .{ .bytes = [_]u8{9} ** 20 }, .lazy = true },
    };
    const pkgs = [_]Package{
        .{ .name = "Zlib_jll", .tree_hash = .{ .bytes = [_]u8{1} ** 20 }, .artifacts = &.{ 0, 1 } },
        .{ .name = "Mid", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
        .{ .name = "Top", .tree_hash = .{ .bytes = [_]u8{3} ** 20 }, .deps = &.{ 0, 1 } },
        .{ .name = "Stdlib", .precompile = false, .cacheable = false },
    };
    const g = try build(arena, .{ .packages = &pkgs, .artifacts = &arts }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);
    try d.runAll(testing.allocator, allOk);

    try testing.expect(d.state.done());
    const t = d.state.tally();
    try testing.expectEqual(@as(u32, 0), t.failed);
    try testing.expectEqual(@as(u32, 0), t.skipped);
    try testing.expectEqual(@as(u32, 0), t.pending);
    try testing.expectEqual(@as(u32, 0), t.ready);
    try testing.expectEqual(@as(u32, 0), t.running);

    // The invariant is per-package, not a global count: WHICH arm wins depends
    // on which tip the executor happens to settle first, and the exact number
    // of cancelled nodes with it (a losing compile arm is two nodes, a losing
    // import arm is one, since Probe and Import are already settled by then).
    // Asserting a constant here pins the driver's scheduling order rather than
    // the rule -- which is exactly what it did on the first run.
    for (0..3) |pi| {
        const vc = d.state.status[g.find(.verify_cache, .{ .package = @intCast(pi) }).?];
        const cp = d.state.status[g.find(.compile, .{ .package = @intCast(pi) }).?];
        try testing.expect((vc == .succeeded) != (cp == .succeeded)); // exactly one
        try testing.expect(vc == .cancelled or cp == .cancelled);
        try testing.expectEqual(Status.succeeded, d.state.status[g.find(.ready, .{ .package = @intCast(pi) }).?]);
    }
    try testing.expect(t.cancelled >= 3);

    // Every unmet counter drained; nothing is waiting on a phantom edge.
    for (d.state.unmet) |u| try testing.expectEqual(@as(u32, 0), u);
}

test "an ordering rule the frontier must not break: no successor runs before its predecessor" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{
        .{ .name = "A", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } },
        .{ .name = "B", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
        .{ .name = "C", .tree_hash = .{ .bytes = [_]u8{3} ** 20 }, .deps = &.{ 0, 1 } },
    };
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);

    var order: std.ArrayList(NodeId) = .empty;
    defer order.deinit(testing.allocator);
    while (try d.step(testing.allocator, allOk)) |n| try order.append(testing.allocator, n);

    const seen = try testing.allocator.alloc(bool, g.nodes.len);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    for (order.items) |n| {
        // Every in-edge's source must already have been settled -- either it
        // ran, or it was cancelled/skipped, which the status array records.
        for (g.edges) |e| {
            if (e.to != n) continue;
            try testing.expect(seen[e.from] or d.state.status[e.from].settled());
        }
        seen[n] = true;
    }
}

test "cycles are refused, with the path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // A ↔ B. Julia manifests can express this; Base warns and skips
    // (`precompilation.jl:770-784`), Ajt refuses.
    const pkgs = [_]Package{
        .{ .name = "A", .tree_hash = .{ .bytes = [_]u8{1} ** 20 }, .deps = &.{1} },
        .{ .name = "B", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
    };
    var diag: Diagnostic = .{};
    try testing.expectError(error.Cyclic, build(arena, .{ .packages = &pkgs }, &diag));

    try testing.expect(diag.cycle.len >= 3);
    try testing.expectEqual(diag.cycle[0], diag.cycle[diag.cycle.len - 1]);
    try testing.expectEqual(diag.cycle.len, diag.path.len);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try diag.write(&w);
    const text = w.buffered();
    // Both packages appear, and the rendering is the arrow path a person can
    // read off the terminal.
    try testing.expect(std.mem.indexOf(u8, text, "(A)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(B)") != null);
    try testing.expect(std.mem.indexOf(u8, text, " -> ") != null);
}

test "a three-package cycle is refused too, and a diamond is not" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const cyc = [_]Package{
        .{ .name = "A", .deps = &.{1} },
        .{ .name = "B", .deps = &.{2} },
        .{ .name = "C", .deps = &.{0} },
    };
    try testing.expectError(error.Cyclic, build(arena, .{ .packages = &cyc }, null));

    // The same shape without the back-edge: a diamond, which is emphatically
    // legal and is what a shared JLL looks like.
    const dag = [_]Package{
        .{ .name = "Base" },
        .{ .name = "L", .deps = &.{0} },
        .{ .name = "R", .deps = &.{0} },
        .{ .name = "Top", .deps = &.{ 1, 2 } },
    };
    const g = try build(arena, .{ .packages = &dag }, null);
    try testing.expect(try findCycle(arena, &g) == null);
}

test "a package that depends on itself is named as such" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{.{ .name = "Self", .deps = &.{0} }};
    try testing.expectError(error.SelfDependency, build(arena, .{ .packages = &pkgs }, null));
}

test "bad indices are refused rather than read" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const bad_dep = [_]Package{.{ .name = "A", .deps = &.{7} }};
    try testing.expectError(error.BadDepIndex, build(arena, .{ .packages = &bad_dep }, null));

    const bad_art = [_]Package{.{ .name = "A", .artifacts = &.{7} }};
    try testing.expectError(error.BadArtifactIndex, build(arena, .{ .packages = &bad_art }, null));
}

test "an empty environment is a graph with just Resolve" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const g = try build(arena, .{}, null);
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectEqual(@as(usize, 0), g.edges.len);
    try testing.expectEqual(@as(?NodeId, 0), g.find(.resolve, .global));

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);
    try d.runAll(testing.allocator, allOk);
    try testing.expect(d.state.done());
}

test "a failed Resolve blocks the entire graph" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const pkgs = [_]Package{
        .{ .name = "A", .tree_hash = .{ .bytes = [_]u8{1} ** 20 } },
        .{ .name = "B", .tree_hash = .{ .bytes = [_]u8{2} ** 20 }, .deps = &.{0} },
    };
    const g = try build(arena, .{ .packages = &pkgs }, null);

    var d = try Driver.init(testing.allocator, &g);
    defer d.deinit(testing.allocator);
    const NoResolve = struct {
        fn verdict(n: NodeId) bool {
            return n != 0;
        }
    };
    try d.runAll(testing.allocator, NoResolve.verdict);

    try testing.expect(d.state.done());
    const t = d.state.tally();
    try testing.expectEqual(@as(u32, 1), t.failed);
    // EVERY other node, including `Import` and `Publish`, whose only
    // non-Resolve in-edge is `after`. That is what pass 3's requires-in-degree
    // head test buys; under an in-degree-0 head test four of these nineteen
    // ran anyway.
    try testing.expectEqual(@as(u32, @intCast(g.nodes.len)) - 1, t.skipped);
    try testing.expectEqual(@as(u32, 0), t.succeeded);
    for (1..g.nodes.len) |n| try testing.expect(d.state.blocked[n]);
}

fn hasEdge(g: *const Graph, from: NodeId, to: NodeId, kind: EdgeKind) bool {
    for (g.outEdges(from)) |ei| {
        const e = g.edges[ei];
        if (e.to == to and e.kind == kind) return true;
    }
    return false;
}
