//! Paper-faithful PubGrub solver.
//!
//! This is the full algorithm from Natalie Weizenbaum's
//! "PubGrub: Next-Generation Version Solving":
//!
//! * A `PartialSolution` tracks decisions and derivations with decision
//!   levels (see `assignment.zig`).
//! * `unitPropagation` scans incompatibilities whose mentioned packages
//!   just changed. For each incompat it asks the partial solution for a
//!   relation: a satisfied incompat is a conflict; an almost-satisfied
//!   one lets us derive the negation of its lone unsatisfied term.
//! * `conflictResolution` walks the partial solution backwards from the
//!   conflict, resolving the incompat against the cause of each satisfier
//!   derivation (the classic prior-cause resolvent) until the satisfier
//!   is either a decision, or a derivation at a strictly higher decision
//!   level than every other term's satisfier. At that point we backjump
//!   to the previous-satisfier level and the learned incompat is
//!   almost-satisfied, driving the next derivation.
//! * `decisionMaking` picks an undecided package with the fewest viable
//!   versions (first-fail heuristic), generates a dependency
//!   incompatibility per dep of the selected version, and either decides
//!   the version or — if a dep incompat is already satisfied — loops
//!   back into propagation.
//!
//! Negative terms are handled symbolically via `VersionSet`'s complement
//! (see `julia_set.zig`), so there is no range-approximation fallback.
//!
//! On failure, the final unresolvable incompatibility (the "root cause")
//! is written to the thread-local `last_root_cause` so callers can render
//! a `writeReport` without threading a diagnostic through the public
//! `solve()` signature.
const std = @import("std");
const Allocator = std.mem.Allocator;

const ver = @import("julia_set.zig");
const term_mod = @import("term.zig");
const inc_mod = @import("incompatibility.zig");
const asn = @import("assignment.zig");
const manifest = @import("manifest.zig");
const log_mod = @import("log.zig");

pub const Version = ver.Version;
pub const Range = ver.Range;
pub const VersionSet = ver.VersionSet;
pub const Term = term_mod.Term;
pub const PackageRef = term_mod.PackageRef;
pub const Incompatibility = inc_mod.Incompatibility;
pub const Cause = inc_mod.Cause;
pub const PartialSolution = asn.PartialSolution;
pub const Assignment = asn.Assignment;

pub const SolveError = error{
    NoSolution,
    SingletonConflict,
    OutOfMemory,
    RegistryError,
    InvalidVersion,
    InvalidRange,
    InternalSatisfierMissing,
};

/// Diagnostic side-channel: on every failed `solve()` call the last
/// unresolvable incompatibility is written here so `writeLastReport` can
/// render it. Thread-local so concurrent solves don't stomp each other.
pub threadlocal var last_root_cause: ?*Incompatibility = null;

/// Registry interface consumed by the resolver. Any backing store (network,
/// in-memory, test fixture) can implement it.
pub const Registry = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list_versions: *const fn (ctx: *anyopaque, name: []const u8, out: *std.ArrayList(Version), allocator: Allocator) anyerror!void,
        get_manifest: *const fn (ctx: *anyopaque, name: []const u8, version: Version, allocator: Allocator) anyerror!manifest.Manifest,
    };

    pub fn listVersions(
        self: *Registry,
        name: []const u8,
        out: *std.ArrayList(Version),
        allocator: Allocator,
    ) !void {
        return self.vtable.list_versions(self.ctx, name, out, allocator);
    }

    pub fn getManifest(
        self: *Registry,
        name: []const u8,
        version: Version,
        allocator: Allocator,
    ) !manifest.Manifest {
        return self.vtable.get_manifest(self.ctx, name, version, allocator);
    }
};

/// A resolved node in the dependency graph.
pub const ResolvedPkg = struct {
    name: []const u8,
    version: Version,
    manifest: manifest.Manifest,
    /// Indices into `DependencyGraph.nodes` of direct dependencies.
    deps: []usize,
};

pub const DependencyGraph = struct {
    nodes: []ResolvedPkg,
    root_index: usize,

    pub fn topoOrder(self: DependencyGraph, allocator: Allocator) ![]usize {
        const n = self.nodes.len;
        var in_degree = try allocator.alloc(usize, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);
        for (self.nodes) |node| {
            for (node.deps) |d| in_degree[d] += 1;
        }
        var order = try allocator.alloc(usize, n);
        var queue = std.ArrayList(usize).empty;
        defer queue.deinit(allocator);
        for (in_degree, 0..) |d, i| {
            if (d == 0) try queue.append(allocator, i);
        }
        var oi: usize = 0;
        var qhead: usize = 0;
        while (qhead < queue.items.len) {
            const u = queue.items[qhead];
            qhead += 1;
            order[oi] = u;
            oi += 1;
            for (self.nodes[u].deps) |v| {
                in_degree[v] -= 1;
                if (in_degree[v] == 0) try queue.append(allocator, v);
            }
        }
        if (oi != n) return error.DependencyCycle;
        return order;
    }
};

/// Resolve the dependency closure rooted at `root`. Returns a fully-pinned
/// graph on success. On failure, `last_root_cause` holds the root
/// incompatibility for `writeLastReport`.
pub fn solve(
    root: PackageRef,
    registry: *Registry,
    allocator: Allocator,
) SolveError!DependencyGraph {
    last_root_cause = null;

    var solver = Solver{
        .allocator = allocator,
        .registry = registry,
        .ps = PartialSolution.init(allocator),
        .incompats = std.ArrayList(*Incompatibility).empty,
        .manifests = std.StringHashMap(manifest.Manifest).init(allocator),
        .singleton_versions = std.StringHashMap(std.ArrayList(Version)).init(allocator),
        .singleton_packages = std.StringHashMap(void).init(allocator),
        .root_name = root.name,
    };

    // Seed with the root incompat: `{not root in {root.version}}`. When
    // propagation runs on the root, the partial solution is missing any
    // constraint on `root`, so the term is "inconclusive" → the incompat
    // is almost-satisfied → the negation (`root = root.version`) is
    // derived at level 0.
    const root_set = try VersionSet.exact(allocator, root.version);
    const root_ic = inc_mod.make(allocator, &.{.{
        .pkg = root.name,
        .set = root_set,
        .positive = false,
    }}, .root) catch return SolveError.OutOfMemory;
    solver.incompats.append(allocator, root_ic) catch return SolveError.OutOfMemory;

    var next_pkg: ?[]const u8 = root.name;
    while (next_pkg) |pkg| {
        solver.unitPropagation(pkg) catch |e| return mapSolveError(e);
        next_pkg = solver.decisionMaking() catch |e| return mapSolveError(e);
    }

    return solver.buildGraph();
}

fn mapSolveError(e: anyerror) SolveError {
    return switch (e) {
        error.NoSolution => SolveError.NoSolution,
        error.SingletonConflict => SolveError.SingletonConflict,
        error.OutOfMemory => SolveError.OutOfMemory,
        error.RegistryError => SolveError.RegistryError,
        error.InvalidVersion => SolveError.InvalidVersion,
        error.InvalidRange => SolveError.InvalidRange,
        error.InternalSatisfierMissing => SolveError.InternalSatisfierMissing,
        else => SolveError.RegistryError,
    };
}

/// Render the last failed solve's derivation tree. Returns an error if no
/// solve has recorded a root cause (e.g., the last solve succeeded).
pub fn writeLastReport(w: *std.Io.Writer) !void {
    return writeLastReportNamed(w, null);
}

/// As `writeLastReport`, with package keys resolved through `names`.
pub fn writeLastReportNamed(w: *std.Io.Writer, names: ?inc_mod.Names) !void {
    const ic = last_root_cause orelse return error.NoDiagnostic;
    return inc_mod.writeReportNamed(ic, w, names);
}

/// The packages the last failed solve blames, deduplicated. Keys, not display
/// names — the caller owns the mapping.
pub fn lastBlamed(out: *std.ArrayList([]const u8), gpa: Allocator) !void {
    const ic = last_root_cause orelse return error.NoDiagnostic;
    return inc_mod.collectBlamed(ic, out, gpa);
}

// -----------------------------------------------------------------------
// Internal solver state
// -----------------------------------------------------------------------

const Solver = struct {
    allocator: Allocator,
    registry: *Registry,
    ps: PartialSolution,
    incompats: std.ArrayList(*Incompatibility),
    manifests: std.StringHashMap(manifest.Manifest),
    /// For each `no_versioning` package, the list of versions we've
    /// already committed to via a decision. Used to emit explicit pairwise
    /// singleton incompatibilities eagerly.
    singleton_versions: std.StringHashMap(std.ArrayList(Version)),
    /// Every package name we've ever observed with `no_versioning = true`
    /// in a fetched manifest. Used post-hoc by `terminalError` to
    /// distinguish `SingletonConflict` from generic `NoSolution` even
    /// when the conflict is driven by two `.dependency` incompats whose
    /// dependee happens to be a singleton (the common shape in practice:
    /// two packages depending on different exact versions of libc).
    singleton_packages: std.StringHashMap(void),
    root_name: []const u8,

    fn unitPropagation(self: *Solver, start_pkg: []const u8) !void {
        var changed = std.ArrayList([]const u8).empty;
        defer changed.deinit(self.allocator);
        try changed.append(self.allocator, start_pkg);

        while (changed.pop()) |pkg| {
            // Snapshot length — any new incompats appended during this
            // iteration (e.g., by conflict resolution) get picked up on
            // the next outer iteration anyway via `changed`.
            var i: usize = 0;
            while (i < self.incompats.items.len) : (i += 1) {
                const ic = self.incompats.items[i];
                if (!ic.mentions(pkg)) continue;

                const rel = try self.ps.relation(ic, self.allocator);
                switch (rel) {
                    .satisfied => {
                        const root_cause = try self.conflictResolution(ic);
                        // After resolution, the partial solution has been
                        // backtracked and the learned incompat is
                        // almost-satisfied. Derive its lone unsatisfied
                        // term's negation.
                        const after = try self.ps.relation(root_cause, self.allocator);
                        switch (after) {
                            .almost_satisfied => |t| {
                                try self.ps.derive(t.negate(), root_cause);
                                changed.clearRetainingCapacity();
                                try changed.append(self.allocator, t.pkg);
                            },
                            else => {
                                // Very unusual but defensive: treat as
                                // unsolvable.
                                last_root_cause = root_cause;
                                return self.terminalError(root_cause);
                            },
                        }
                        // Break out of the `for ic in incompats` loop;
                        // restart with the new `changed` set.
                        break;
                    },
                    .almost_satisfied => |t| {
                        try self.ps.derive(t.negate(), ic);
                        try changed.append(self.allocator, t.pkg);
                    },
                    .contradicted, .inconclusive => {},
                }
            }
        }
    }

    fn conflictResolution(
        self: *Solver,
        initial: *Incompatibility,
    ) !*Incompatibility {
        var incompat: *Incompatibility = initial;
        var new_incompat = false;

        while (true) {
            // Terminal: the empty incompatibility means every possible
            // resolution is ruled out.
            if (incompat.terms.len == 0) {
                last_root_cause = incompat;
                return self.terminalError(incompat);
            }
            // Terminal: the root incompat being the only blame means the
            // root version itself is unsatisfiable.
            if (incompat.cause == .root and !new_incompat) {
                last_root_cause = incompat;
                return self.terminalError(incompat);
            }

            const info = try self.ps.findSatisfier(incompat, self.allocator);
            const satisfier = self.ps.assignments.items[info.satisfier_index];
            const satisfier_level = satisfier.level();

            if (new_incompat) {
                try self.incompats.append(self.allocator, incompat);
            }

            const is_decision = satisfier == .decision;
            if (is_decision or satisfier_level > info.previous_level) {
                // Backjump to previous_level (clamped at 0).
                try self.ps.backtrack(info.previous_level);
                return incompat;
            }

            // Resolve with the satisfier derivation's cause.
            const cause_ic = satisfier.derivation.cause;
            incompat = try self.priorCause(incompat, cause_ic, info.satisfier_term.pkg);
            new_incompat = true;
        }
    }

    /// Combine two incompatibilities on the given package. See
    /// `incompatibility.Cause.conflict`.
    fn priorCause(
        self: *Solver,
        a: *Incompatibility,
        b: *Incompatibility,
        pkg: []const u8,
    ) !*Incompatibility {
        const ta = a.termFor(pkg) orelse return error.InternalSatisfierMissing;
        const tb = b.termFor(pkg) orelse return error.InternalSatisfierMissing;

        var out = std.ArrayList(Term).empty;
        defer out.deinit(self.allocator);

        // Merge non-`pkg` terms: for packages appearing in both sides,
        // intersect. For packages in one side, copy.
        var seen = std.StringHashMap(usize).init(self.allocator);
        defer seen.deinit();

        for (a.terms) |t| {
            if (std.mem.eql(u8, t.pkg, pkg)) continue;
            try seen.put(t.pkg, out.items.len);
            try out.append(self.allocator, t);
        }
        for (t_iter: {
            break :t_iter b.terms;
        }) |t| {
            if (std.mem.eql(u8, t.pkg, pkg)) continue;
            if (seen.get(t.pkg)) |idx| {
                const merged = try Term.intersect(out.items[idx], t, self.allocator);
                if (merged) |m| {
                    out.items[idx] = m;
                } else {
                    // Intersection is empty — the two sides have
                    // disjoint constraints for this package. Keep the
                    // merged term as an explicit empty so the resolvent
                    // remains structurally correct; propagation will
                    // treat it as contradicted.
                    out.items[idx] = .{
                        .pkg = t.pkg,
                        .set = try VersionSet.emptyLike(self.allocator, t.set),
                        .positive = true,
                    };
                }
            } else {
                try seen.put(t.pkg, out.items.len);
                try out.append(self.allocator, t);
            }
        }

        // Combined pkg term = ta ∪ tb. If universal, omit it entirely.
        const merged_pkg = try Term.unionWith(ta, tb, self.allocator);
        if (merged_pkg) |m| {
            try out.append(self.allocator, m);
        }

        return inc_mod.make(self.allocator, out.items, .{
            .conflict = .{ .a = a, .b = b, .pkg = pkg },
        });
    }

    fn decisionMaking(self: *Solver) !?[]const u8 {
        // Pick an undecided package with the fewest viable versions.
        var best_pkg: ?[]const u8 = null;
        var best_term: ?Term = null;
        var best_viable: []Version = &.{};
        var best_count: usize = std.math.maxInt(usize);

        var it = self.ps.package_terms.iterator();
        while (it.next()) |entry| {
            const pkg = entry.key_ptr.*;
            if (self.ps.decisions.contains(pkg)) continue;
            const term = entry.value_ptr.*;

            // Must be an actual "require some version" intent. Skip terms
            // whose true set is universal (no constraint at all) or empty
            // (contradicted — propagation handles it).
            //
            // "Universal" here means versions AND absent. A requirement that
            // merely permits every published version — `^1` on a package that
            // only shipped 1.x — is NOT universal, because it still excludes
            // absent, so it is correctly decided rather than skipped. That
            // distinction only exists because the universe carries an absent
            // bit; without one this check silently discarded the root itself.
            // Decide a package only when something REQUIRES it. The precise
            // test is the absent bit: if the accumulated constraint still
            // admits the package not being selected, nothing requires it.
            //
            // The sign of the term cannot answer this. `PartialSolution.addTerm`
            // merges via `Term.intersect`, which normalises its result to a
            // POSITIVE term over the intersected true set — so two derivations
            // that each only said "avoid these versions" combine into a
            // positive term, and reading that as a requirement selects a
            // package nobody asked for. That is exactly how a `[weakdeps]`
            // edge, whose whole point is that absence is allowed, pulled Adapt
            // into the resolved set.
            //
            // `isAny` is subsumed (a universal set contains absent) but kept:
            // it is the cheap check and states the common case.
            const ts = try term.trueSet(self.allocator);
            if (ts.isEmpty()) continue;
            if (ts.hasAbsent()) continue;

            const viable = try self.listViable(pkg, term);
            if (viable.len < best_count) {
                best_pkg = pkg;
                best_term = term;
                best_viable = viable;
                best_count = viable.len;
                if (best_count == 0) break; // can't do better than this
            }
        }

        const pkg = best_pkg orelse return null;
        const term = best_term.?;

        if (best_viable.len == 0) {
            // Synthesize a no_versions incompat — its one positive term
            // claims pkg has some version in `term.set`, but the registry
            // has none.
            const ic = try inc_mod.make(self.allocator, &.{.{
                .pkg = pkg,
                .set = term.set,
                .positive = true,
            }}, .{ .no_versions = pkg });
            try self.incompats.append(self.allocator, ic);
            return pkg;
        }

        // Sort descending and walk down until we find a version whose
        // dependency incompatibilities aren't already satisfied.
        std.mem.sort(Version, best_viable, {}, struct {
            fn gt(_: void, a: Version, b: Version) bool {
                return Version.order(a, b) == .gt;
            }
        }.gt);

        for (best_viable) |v| {
            const mf = self.registry.getManifest(pkg, v, self.allocator) catch |e| {
                log_mod.err("getManifest({s}@{f}) failed: {s}", .{ pkg, v, @errorName(e) });
                return error.RegistryError;
            };
            try self.manifests.put(try mkKey(self.allocator, pkg, v), mf);
            if (mf.no_versioning) {
                try self.singleton_packages.put(pkg, {});
            }

            var new_ics = std.ArrayList(*Incompatibility).empty;
            defer new_ics.deinit(self.allocator);

            for (mf.depends) |d| {
                const dep_set = try VersionSet.fromRange(self.allocator, d.range);
                const pkg_term: Term = .{
                    .pkg = pkg,
                    .set = try VersionSet.exact(self.allocator, v),
                    .positive = true,
                };
                // A STRONG dep is `{P@v, ¬dep ∈ R}` — "P@v with dep outside R
                // is impossible", and since the negation admits `dep` being
                // absent, propagation derives that dep must exist in R.
                //
                // A WEAK dep must NOT force existence. Its incompatibility is
                // `{P@v, W ∈ (V_W \ R)}` with BOTH terms positive: it fires
                // only when W has independently been selected AND landed
                // outside R. The complement is taken over versions ONLY —
                // never including the absent bit — because "W is absent" is
                // precisely the case a weak edge has to tolerate.
                const dep_term: Term = if (d.weak) blk: {
                    const all = try VersionSet.allVersions(self.allocator, dep_set.universe);
                    break :blk .{
                        .pkg = d.name,
                        .set = try all.difference(dep_set, self.allocator),
                        .positive = true,
                    };
                } else .{
                    .pkg = d.name,
                    .set = dep_set,
                    .positive = false,
                };
                const ic = try inc_mod.make(self.allocator, &.{ pkg_term, dep_term }, .{
                    .dependency = .{
                        .depender_name = pkg,
                        .depender_version = v,
                        .dependee_name = d.name,
                    },
                });
                try new_ics.append(self.allocator, ic);

                // Cheap singleton probe: if this dep is pinned to one
                // specific version (exact range), peek at its manifest
                // so we learn `no_versioning` status before a decision
                // on it is ever made. This is what lets the terminal
                // error promote `NoSolution` → `SingletonConflict` when
                // two exact-pin deps on the same singleton collide.
                if (exactPinned(d.range)) |pinned_v| {
                    const key = try mkKey(self.allocator, d.name, pinned_v);
                    if (self.manifests.get(key) == null) {
                        if (self.registry.getManifest(d.name, pinned_v, self.allocator)) |dep_mf| {
                            try self.manifests.put(key, dep_mf);
                            if (dep_mf.no_versioning) {
                                try self.singleton_packages.put(d.name, {});
                            }
                        } else |_| {
                            // Probe failures aren't fatal — decision
                            // making will surface them at its own
                            // getManifest call.
                        }
                    }
                }
            }

            // Singleton: emit pairwise exclusion incompats for any OTHER
            // singleton version of this package we've already seen. This
            // is how no_versioning conflicts enter CDCL.
            if (mf.no_versioning) {
                const existing = self.singleton_versions.getPtr(pkg);
                if (existing) |list_ptr| {
                    for (list_ptr.items) |other_v| {
                        if (Version.eql(other_v, v)) continue;
                        const this_term: Term = .{
                            .pkg = pkg,
                            .set = try VersionSet.exact(self.allocator, v),
                            .positive = true,
                        };
                        const other_term: Term = .{
                            .pkg = pkg,
                            .set = try VersionSet.exact(self.allocator, other_v),
                            .positive = true,
                        };
                        const ic = try inc_mod.make(
                            self.allocator,
                            &.{ this_term, other_term },
                            .{ .singleton = pkg },
                        );
                        try new_ics.append(self.allocator, ic);
                    }
                }
            }

            // Append all the new incompats to the store regardless (paper
            // §3.4: they're kept even when we skip the version).
            for (new_ics.items) |ic| try self.incompats.append(self.allocator, ic);

            // Check if any of the newly-added incompats is already
            // satisfied by the partial solution — if so, skip this
            // version and try the next.
            var conflict_here = false;
            for (new_ics.items) |ic| {
                const r = try self.ps.relation(ic, self.allocator);
                if (r == .satisfied) {
                    conflict_here = true;
                    break;
                }
            }
            if (conflict_here) continue;

            // Commit the decision.
            try self.ps.decide(pkg, v);
            if (mf.no_versioning) {
                const gop = try self.singleton_versions.getOrPut(pkg);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(Version).empty;
                }
                var already = false;
                for (gop.value_ptr.items) |ex| {
                    if (Version.eql(ex, v)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try gop.value_ptr.append(self.allocator, v);
            }
            return pkg;
        }

        // Every viable version conflicted. Treat as no_versions.
        const ic = try inc_mod.make(self.allocator, &.{.{
            .pkg = pkg,
            .set = term.set,
            .positive = true,
        }}, .{ .no_versions = pkg });
        try self.incompats.append(self.allocator, ic);
        return pkg;
    }

    fn listViable(self: *Solver, pkg: []const u8, term: Term) ![]Version {
        var vs = std.ArrayList(Version).empty;
        defer vs.deinit(self.allocator);
        self.registry.listVersions(pkg, &vs, self.allocator) catch {
            return error.RegistryError;
        };
        var out = std.ArrayList(Version).empty;
        for (vs.items) |v| {
            if (term.satisfiesVersion(v)) try out.append(self.allocator, v);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn terminalError(self: *Solver, ic: *Incompatibility) SolveError {
        const scan = SingletonScan{ .singleton_packages = &self.singleton_packages };
        if (scan.visit(ic)) return SolveError.SingletonConflict;
        return SolveError.NoSolution;
    }

    fn buildGraph(self: *Solver) !DependencyGraph {
        // All decisions in order → graph nodes.
        var decision_list = std.ArrayList(asn.Decision).empty;
        defer decision_list.deinit(self.allocator);
        for (self.ps.assignments.items) |a| {
            if (a == .decision) try decision_list.append(self.allocator, a.decision);
        }

        const n = decision_list.items.len;
        const nodes = try self.allocator.alloc(ResolvedPkg, n);
        var index_of = std.StringHashMap(usize).init(self.allocator);
        defer index_of.deinit();

        for (decision_list.items, 0..) |d, i| {
            try index_of.put(d.pkg, i);
        }

        for (decision_list.items, 0..) |d, i| {
            const key = try mkKey(self.allocator, d.pkg, d.version);
            const mf = self.manifests.get(key) orelse blk: {
                // Fetch on the fly — this path is only hit for the root.
                const m = self.registry.getManifest(d.pkg, d.version, self.allocator) catch {
                    return error.RegistryError;
                };
                try self.manifests.put(key, m);
                break :blk m;
            };
            // Weak deps that nothing selected are simply absent from the
            // graph, so the edge list is built by appending rather than by
            // index — it can be shorter than `mf.depends`.
            var dep_list = try std.ArrayList(usize).initCapacity(self.allocator, mf.depends.len);
            for (mf.depends) |dep| {
                if (index_of.get(dep.name)) |di| {
                    dep_list.appendAssumeCapacity(di);
                    continue;
                }
                if (dep.weak) continue; // not selected: that is the whole point
                {
                    // PubGrub didn't make a decision for this dep name
                    // even though the decided manifest references it.
                    // This usually means the dep's version constraints
                    // couldn't be satisfied and no alternative was picked
                    // (e.g. a `Provides:`-aliased lookup picked a name
                    // whose versions don't actually match). Log before
                    // bailing so `baker port` operators see something
                    // actionable instead of an empty derivation tree.
                    log_mod.err(
                        "pubgrub buildGraph: {s}@{f} references undecided dep \"{s}\" — likely a version/provides mismatch",
                        .{ d.pkg, d.version, dep.name },
                    );
                    return SolveError.NoSolution;
                }
            }
            nodes[i] = .{
                .name = d.pkg,
                .version = d.version,
                .manifest = mf,
                .deps = dep_list.items,
            };
        }

        const root_index = index_of.get(self.root_name) orelse return SolveError.NoSolution;
        return .{ .nodes = nodes, .root_index = root_index };
    }
};

/// A constraint that admits exactly ONE candidate. Used by the singleton
/// probe in decision-making.
///
/// Baker spelled this "both bounds are the same version and both inclusive",
/// i.e. a literal `=x.y.z` range. Over a bitset the property is directly
/// expressible — popcount == 1 — and that is deliberately WIDER: `^1.2` also
/// qualifies when 1.2.0 happens to be the package's only matching candidate.
///
/// Widening is safe here and nowhere else, which is why it is not done
/// generally. The caller is a non-fatal pre-fetch that warms a manifest to
/// learn `no_versioning` early; its own comment notes probe failures are not
/// fatal, and anything it fetches is a manifest decision-making would fetch
/// anyway. So a wider predicate warms strictly more of the right cases and
/// can cost at most one speculative lookup.
fn exactPinned(r: Range) ?Version {
    if (r.count() != 1) return null;
    return r.highest();
}

/// Terminal-error classification: walk the derivation tree and decide
/// whether this unresolvable failure is a generic `NoSolution` or the
/// more specific `SingletonConflict`. A singleton conflict is declared
/// whenever the tree contains either an explicit `.singleton` cause or a
/// `.dependency` cause whose dependee is known to be a singleton (via
/// `Solver.singleton_packages`).
const SingletonScan = struct {
    singleton_packages: *std.StringHashMap(void),

    fn visit(self: SingletonScan, ic: *Incompatibility) bool {
        switch (ic.cause) {
            .singleton => return true,
            .dependency => |d| return self.singleton_packages.contains(d.dependee_name),
            .conflict => |c| return self.visit(c.a) or self.visit(c.b),
            else => return false,
        }
    }
};

fn mkKey(allocator: Allocator, name: []const u8, v: Version) ![]const u8 {
    // `{f}` renders the underlying VersionNumber, including prerelease and
    // build, so two distinct candidates of one package never collide.
    return try std.fmt.allocPrint(allocator, "{s}@{f}", .{ name, v });
}

test "resolver registry vtable compiles" {
    _ = Registry;
    _ = SolveError;
    _ = PartialSolution;
}
