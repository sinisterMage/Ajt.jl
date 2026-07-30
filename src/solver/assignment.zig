//! PubGrub partial solution (§2 of the paper).
//!
//! A `PartialSolution` is the chronologically-ordered list of `Assignment`s
//! (decisions and derivations) plus two derived indices for fast lookup:
//!
//! - `decisions`: for each already-decided package, its pinned version.
//! - `package_terms`: for each package, the intersection of every term
//!   that currently constrains it. This is the "pkg_term" the paper
//!   refers to when it computes the relation of an incompatibility to
//!   the partial solution.
//!
//! Mutation shape:
//!
//! - `decide(pkg, v)` bumps `decision_level` and appends a decision
//!   assignment (term: `{pkg = v}` positive singleton).
//! - `derive(term, cause)` appends a derivation assignment at the current
//!   decision level, caused by `cause`.
//! - `backtrack(level)` truncates to the first assignment recorded at a
//!   level greater than `level`, then rebuilds the derived indices.
//!
//! Allocations flow through the caller-provided allocator (the solver's
//! arena in practice); the partial solution never frees, only truncates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ver = @import("julia_set.zig");
const term_mod = @import("term.zig");
const inc_mod = @import("incompatibility.zig");

pub const Version = ver.Version;
pub const VersionSet = ver.VersionSet;
pub const Term = term_mod.Term;
pub const Incompatibility = inc_mod.Incompatibility;

pub const Decision = struct {
    pkg: []const u8,
    version: Version,
    level: usize,
};

pub const Derivation = struct {
    term: Term,
    cause: *Incompatibility,
    level: usize,
};

pub const Assignment = union(enum) {
    decision: Decision,
    derivation: Derivation,

    pub fn level(self: Assignment) usize {
        return switch (self) {
            .decision => |d| d.level,
            .derivation => |d| d.level,
        };
    }

    pub fn termFor(self: Assignment, allocator: Allocator) Allocator.Error!Term {
        return switch (self) {
            .decision => |d| try Term.exact(allocator, d.pkg, d.version),
            .derivation => |d| d.term,
        };
    }

    pub fn pkg(self: Assignment) []const u8 {
        return switch (self) {
            .decision => |d| d.pkg,
            .derivation => |d| d.term.pkg,
        };
    }
};

/// Relation of an incompatibility to a partial solution. Mirrors the
/// paper's four-way classification.
pub const Relation = union(enum) {
    /// Every term is satisfied by the partial solution — *conflict*.
    satisfied,
    /// At least one term is contradicted; the incompatibility can't be
    /// violated and is useless for propagation.
    contradicted,
    /// Exactly one term is "inconclusive" (neither satisfied nor
    /// contradicted). Its negation can be derived. The payload is that
    /// lone unsatisfied term as it appears in the incompatibility.
    almost_satisfied: Term,
    /// More than one term is unsatisfied — no propagation possible.
    inconclusive,
};

pub const PartialSolution = struct {
    allocator: Allocator,
    assignments: std.ArrayList(Assignment),
    /// For each package, the intersected term of every assignment that
    /// mentions it (the "pkg_term" in the paper). Always stored as a
    /// positive term over the true set.
    package_terms: std.StringHashMap(Term),
    /// Decided packages and their pinned versions.
    decisions: std.StringHashMap(Version),
    /// Current decision level (0 before any decision; incremented by each
    /// `decide()` call).
    decision_level: usize,

    pub fn init(allocator: Allocator) PartialSolution {
        return .{
            .allocator = allocator,
            .assignments = std.ArrayList(Assignment).empty,
            .package_terms = std.StringHashMap(Term).init(allocator),
            .decisions = std.StringHashMap(Version).init(allocator),
            .decision_level = 0,
        };
    }

    pub fn deinit(self: *PartialSolution) void {
        self.assignments.deinit(self.allocator);
        self.package_terms.deinit();
        self.decisions.deinit();
    }

    /// Append a decision at a new decision level.
    pub fn decide(self: *PartialSolution, pkg: []const u8, v: Version) !void {
        self.decision_level += 1;
        const d: Decision = .{ .pkg = pkg, .version = v, .level = self.decision_level };
        try self.assignments.append(self.allocator, .{ .decision = d });
        const t = try Term.exact(self.allocator, pkg, v);
        try self.intersectInto(pkg, t);
        try self.decisions.put(pkg, v);
    }

    /// Append a derivation at the current decision level.
    pub fn derive(self: *PartialSolution, term: Term, cause: *Incompatibility) !void {
        const d: Derivation = .{ .term = term, .cause = cause, .level = self.decision_level };
        try self.assignments.append(self.allocator, .{ .derivation = d });
        try self.intersectInto(term.pkg, term);
    }

    /// Truncate to assignments at decision levels ≤ `to_level` and rebuild
    /// the derived indices. Assignments are appended in non-decreasing
    /// level order, so we can scan left-to-right for the cut point.
    pub fn backtrack(self: *PartialSolution, to_level: usize) !void {
        var cut: usize = self.assignments.items.len;
        for (self.assignments.items, 0..) |a, i| {
            if (a.level() > to_level) {
                cut = i;
                break;
            }
        }
        self.assignments.items.len = cut;
        self.decision_level = to_level;

        self.package_terms.clearRetainingCapacity();
        self.decisions.clearRetainingCapacity();
        for (self.assignments.items) |a| {
            const t = try a.termFor(self.allocator);
            try self.intersectInto(t.pkg, t);
            if (a == .decision) {
                try self.decisions.put(a.decision.pkg, a.decision.version);
            }
        }
    }

    fn intersectInto(self: *PartialSolution, pkg: []const u8, term: Term) !void {
        if (self.package_terms.getPtr(pkg)) |existing| {
            const merged = try Term.intersect(existing.*, term, self.allocator);
            if (merged) |m| {
                existing.* = m;
            } else {
                // Empty intersection — store an explicit empty term. This
                // state is transient: propagation will see the conflict.
                existing.* = .{
                    .pkg = pkg,
                    // emptyLike, not a bare empty: the bitset model needs the
                    // universe, and negate()+trueSet() can complement this.
                    .set = try VersionSet.emptyLike(self.allocator, existing.set),
                    .positive = true,
                };
            }
        } else {
            try self.package_terms.put(pkg, term);
        }
    }

    /// Compute the relation of `ic` to this partial solution.
    pub fn relation(
        self: *PartialSolution,
        ic: *Incompatibility,
        allocator: Allocator,
    ) !Relation {
        var unsatisfied_count: usize = 0;
        var unsatisfied_term: ?Term = null;
        for (ic.terms) |t| {
            if (self.package_terms.get(t.pkg)) |pkg_term| {
                const r = (try pkg_term.relation(t, allocator)) orelse continue;
                switch (r) {
                    .subset => {},
                    .disjoint => return .contradicted,
                    .overlapping => {
                        unsatisfied_count += 1;
                        unsatisfied_term = t;
                    },
                }
            } else {
                unsatisfied_count += 1;
                unsatisfied_term = t;
            }
        }
        if (unsatisfied_count == 0) return .satisfied;
        if (unsatisfied_count == 1) return .{ .almost_satisfied = unsatisfied_term.? };
        return .inconclusive;
    }

    /// Find the satisfier of `ic` — the earliest prefix of assignments
    /// whose combined terms already satisfy every term of `ic`. Returns
    /// the index of the assignment that completed satisfaction, plus the
    /// "previous satisfier level" (the highest level among the earlier
    /// per-term satisfiers — used to choose the backtrack target during
    /// conflict resolution). When the satisfier is the only contributor
    /// (decision level 0 or 1), `previous_level` is clamped to 0.
    pub const SatisfierInfo = struct {
        satisfier_index: usize,
        satisfier_term: Term,
        previous_level: usize,
    };

    pub fn findSatisfier(
        self: *PartialSolution,
        ic: *Incompatibility,
        allocator: Allocator,
    ) !SatisfierInfo {
        // For each term in ic, find the smallest prefix that satisfies it.
        var latest_idx: usize = 0;
        var latest_term: Term = ic.terms[0];
        var other_max_level: usize = 0;

        var first = true;
        for (ic.terms) |t| {
            const idx = (try firstSatisfierIndex(self, t, allocator)) orelse {
                // Should not happen: the caller guarantees ic is satisfied
                // when they call findSatisfier. If the term is never
                // satisfied, something went wrong upstream.
                return error.InternalSatisfierMissing;
            };
            if (first) {
                latest_idx = idx;
                latest_term = t;
                first = false;
                continue;
            }
            if (idx > latest_idx) {
                other_max_level = @max(other_max_level, self.assignments.items[latest_idx].level());
                latest_idx = idx;
                latest_term = t;
            } else {
                other_max_level = @max(other_max_level, self.assignments.items[idx].level());
            }
        }

        return .{
            .satisfier_index = latest_idx,
            .satisfier_term = latest_term,
            .previous_level = other_max_level,
        };
    }
};

fn firstSatisfierIndex(
    ps: *PartialSolution,
    term: Term,
    allocator: Allocator,
) !?usize {
    // Build up the incremental intersected pkg_term for `term.pkg` and
    // stop when it becomes a subset of `term` (i.e., the partial prefix
    // satisfies the term).
    var acc: ?Term = null;
    for (ps.assignments.items, 0..) |a, i| {
        if (!std.mem.eql(u8, a.pkg(), term.pkg)) continue;
        const t = try a.termFor(allocator);
        if (acc) |cur| {
            const merged = try Term.intersect(cur, t, allocator);
            acc = merged orelse Term{
                .pkg = term.pkg,
                .set = try VersionSet.emptyLike(allocator, cur.set),
                .positive = true,
            };
        } else {
            acc = t;
        }
        const rel = (try acc.?.relation(term, allocator)).?;
        if (rel == .subset) return i;
    }
    return null;
}
