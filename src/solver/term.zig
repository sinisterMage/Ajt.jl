//! PubGrub terms built on top of `VersionSet`.
//!
//! A `Term` is an assertion about a single package's allowed versions. It
//! can be positive (the package's version must be in `set`) or negative
//! (it must *not* be in `set`). This implementation reifies terms as
//! `VersionSet`s so `relation`, `intersect`, `negate`, and `isEmpty` all
//! fall out of real set algebra — no approximations.
//!
//! Conceptually, the "true set" of a term is:
//!
//!   positive → set
//!   negative → complement(set)
//!
//! All comparison/combination operations reduce to true-set algebra.
const std = @import("std");
const ver = @import("julia_set.zig");
const Allocator = std.mem.Allocator;

pub const VersionSet = ver.VersionSet;
pub const Version = ver.Version;
pub const Range = ver.Range;

pub const PackageRef = struct {
    name: []const u8,
    version: Version,

    pub fn eql(a: PackageRef, b: PackageRef) bool {
        return std.mem.eql(u8, a.name, b.name) and Version.eql(a.version, b.version);
    }
};

/// A PubGrub term: a positive or negative assertion about a single
/// package's versions.
pub const Term = struct {
    pkg: []const u8,
    set: VersionSet,
    /// `true` → versions in `set` satisfy the term.
    /// `false` → versions *outside* `set` satisfy the term.
    positive: bool,

    /// `{v}` (positive exact singleton).
    pub fn exact(allocator: Allocator, pkg: []const u8, v: Version) Allocator.Error!Term {
        return .{
            .pkg = pkg,
            .set = try VersionSet.exact(allocator, v),
            .positive = true,
        };
    }

    /// Positive term wrapping a `Range`.
    pub fn positiveRange(allocator: Allocator, pkg: []const u8, r: Range) Allocator.Error!Term {
        return .{
            .pkg = pkg,
            .set = try VersionSet.fromRange(allocator, r),
            .positive = true,
        };
    }

    /// Return the true set (the actual set of versions that satisfy the
    /// term, computing the complement for negative terms).
    pub fn trueSet(self: Term, allocator: Allocator) Allocator.Error!VersionSet {
        if (self.positive) return self.set;
        return self.set.complement(allocator);
    }

    pub fn satisfiesVersion(self: Term, v: Version) bool {
        const in = self.set.contains(v);
        return if (self.positive) in else !in;
    }

    /// Lazy negation — just flips the sign bit. `relation` and friends do
    /// the actual set algebra on demand.
    pub fn negate(self: Term) Term {
        return .{ .pkg = self.pkg, .set = self.set, .positive = !self.positive };
    }

    /// Is the term the empty constraint (no version satisfies it)?
    pub fn isEmpty(self: Term, allocator: Allocator) Allocator.Error!bool {
        const ts = try self.trueSet(allocator);
        return ts.isEmpty();
    }

    /// Is the term the universal constraint (every version satisfies it)?
    pub fn isAny(self: Term, allocator: Allocator) Allocator.Error!bool {
        const ts = try self.trueSet(allocator);
        return ts.isAny();
    }

    /// Intersection of two terms over the same package. Returns `null` if
    /// the intersection is empty. The result is always a positive term
    /// whose `set` is the intersected true set.
    pub fn intersect(
        a: Term,
        b: Term,
        allocator: Allocator,
    ) Allocator.Error!?Term {
        std.debug.assert(std.mem.eql(u8, a.pkg, b.pkg));
        const sa = try a.trueSet(allocator);
        const sb = try b.trueSet(allocator);
        const inter = try sa.intersect(sb, allocator);
        if (inter.isEmpty()) return null;
        return .{ .pkg = a.pkg, .set = inter, .positive = true };
    }

    /// Union of two terms over the same package. Produces a positive term
    /// whose `set` is the unioned true set. If the result is the universal
    /// set, returns `null` — callers treat that as "no constraint" (the
    /// term is trivially satisfied everywhere).
    pub fn unionWith(
        a: Term,
        b: Term,
        allocator: Allocator,
    ) Allocator.Error!?Term {
        std.debug.assert(std.mem.eql(u8, a.pkg, b.pkg));
        const sa = try a.trueSet(allocator);
        const sb = try b.trueSet(allocator);
        const u = try sa.unionWith(sb, allocator);
        if (u.isAny()) return null;
        return .{ .pkg = a.pkg, .set = u, .positive = true };
    }

    pub fn format(self: Term, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.positive) try w.writeAll("not ");
        try w.print("{s} {f}", .{ self.pkg, self.set });
    }

    /// Subset / disjoint / overlapping, per PubGrub §4. The relation is
    /// *set-theoretic* on the terms' true sets — this replaces the old
    /// single-range approximation.
    pub const Relation = enum { disjoint, overlapping, subset };

    /// Relation of `self` to `other` (both over the same package).
    /// Returns `null` if the package names differ.
    pub fn relation(
        self: Term,
        other: Term,
        allocator: Allocator,
    ) Allocator.Error!?Relation {
        if (!std.mem.eql(u8, self.pkg, other.pkg)) return null;
        const a = try self.trueSet(allocator);
        const b = try other.trueSet(allocator);
        // An empty true set is VACUOUSLY a subset of every set, and this
        // must be tested before disjointness: the empty set intersects
        // nothing, so the naive disjoint test below would report
        // `.contradicted` for a term that is really just unsatisfiable.
        //
        // Baker could skip this because an empty true set was unreachable in
        // its model -- a positive range is never empty on an infinite version
        // axis, and neither is the complement of one. Over a FINITE candidate
        // list both are routine: `bar ^9.0.0` where bar only ever published
        // 1.0.0 is the empty set on construction. Getting this wrong stalls
        // propagation completely -- the enclosing incompatibility never reads
        // as satisfied, so conflict resolution never runs and the solver
        // returns a graph with undecided dependencies in it.
        if (a.isEmpty()) return .subset;
        const inter = try a.intersect(b, allocator);
        if (inter.isEmpty()) return .disjoint;
        if (b.containsSet(a)) return .subset;
        return .overlapping;
    }
};

// ---------------------------------------------------------------------------
// Tests. Ported to the Julia version model.
//
// These exercise the SET ALGEBRA, not a range grammar, so they now build sets
// from explicit version lists over one shared universe. That is both closer to
// what they actually assert and immune to the trap that bit the port: baker
// wrote one constraint as `">=1.2.0, <1.8.0"`, where comma is conjunction. In
// Julia's `semver_spec` comma is a UNION (`Versions.jl:303-325`), so the same
// string means `*` — every version — and the test would have gone green while
// asserting nothing.
const jver = @import("../julia/version.zig");

/// The candidate axis for these tests, chosen so every constraint below is
/// distinguishable from its neighbours.
const axis = [_][]const u8{ "1.0.0", "1.1.0", "1.2.0", "1.5.0", "1.8.0", "2.0.0", "2.5.0", "3.0.0" };

fn testUniverse(a: std.mem.Allocator) !*ver.Universe {
    const vs = try a.alloc(jver.Version, axis.len);
    for (axis, 0..) |t, i| vs[i] = try jver.parse(a, t);
    const u = try a.create(ver.Universe);
    u.* = ver.Universe.init("x", vs, &.{});
    return u;
}

/// A set holding exactly the listed versions.
fn setOf(a: std.mem.Allocator, u: *const ver.Universe, want: []const []const u8) !VersionSet {
    var s = try VersionSet.empty(a, u);
    for (want) |t| {
        const v = try jver.parse(a, t);
        const idx = u.indexOf(v) orelse return error.NotInAxis;
        // `set` is private to the module; go through the public singleton
        // union so the test uses the same path production code does.
        const one = try VersionSet.exact(a, u.at(idx));
        s = try s.unionWith(one, a);
    }
    return s;
}

fn vOf(u: *const ver.Universe, a: std.mem.Allocator, t: []const u8) !Version {
    return u.at(u.indexOf(try jver.parse(a, t)) orelse return error.NotInAxis);
}

// The intervals baker's strings denoted, over `axis`.
const caret_1_0 = [_][]const u8{ "1.0.0", "1.1.0", "1.2.0", "1.5.0", "1.8.0" }; // ^1.0.0
const caret_1_1 = [_][]const u8{ "1.1.0", "1.2.0", "1.5.0", "1.8.0" }; // ^1.1.0
const caret_2_0 = [_][]const u8{ "2.0.0", "2.5.0" }; // ^2.0.0
const caret_3_0 = [_][]const u8{"3.0.0"}; // ^3.0.0
const ge12_lt18 = [_][]const u8{ "1.2.0", "1.5.0" }; // >=1.2.0, <1.8.0

test "term satisfies via true set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUniverse(a);

    const t = Term{ .pkg = "x", .set = try setOf(a, u, &caret_1_0), .positive = true };
    try std.testing.expect(t.satisfiesVersion(try vOf(u, a, "1.5.0")));
    try std.testing.expect(!t.satisfiesVersion(try vOf(u, a, "2.0.0")));

    const n = t.negate();
    try std.testing.expect(!n.satisfiesVersion(try vOf(u, a, "1.5.0")));
    try std.testing.expect(n.satisfiesVersion(try vOf(u, a, "2.0.0")));
}

test "term relation on positive-only ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUniverse(a);

    const t1 = Term{ .pkg = "foo", .set = try setOf(a, u, &caret_1_0), .positive = true };
    const t2 = Term{ .pkg = "foo", .set = try setOf(a, u, &caret_1_1), .positive = true };
    try std.testing.expectEqual(Term.Relation.subset, (try t2.relation(t1, a)).?);
    try std.testing.expectEqual(Term.Relation.overlapping, (try t1.relation(t2, a)).?);

    const t3 = Term{ .pkg = "foo", .set = try setOf(a, u, &caret_2_0), .positive = true };
    try std.testing.expectEqual(Term.Relation.disjoint, (try t1.relation(t3, a)).?);
}

test "term relation with negative terms (no asRange approximation)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUniverse(a);

    // Positive ^1 is a subset of not-^2 (everything except [2.0, 3.0)).
    const pos = Term{ .pkg = "x", .set = try setOf(a, u, &caret_1_0), .positive = true };
    const neg = (Term{ .pkg = "x", .set = try setOf(a, u, &caret_2_0), .positive = true }).negate();
    try std.testing.expectEqual(Term.Relation.subset, (try pos.relation(neg, a)).?);

    // Two negatives over disjoint ranges both cover most of the axis; their
    // true sets overlap heavily, they are not disjoint.
    const neg2 = (Term{ .pkg = "x", .set = try setOf(a, u, &caret_3_0), .positive = true }).negate();
    try std.testing.expectEqual(Term.Relation.overlapping, (try neg.relation(neg2, a)).?);
}

test "term intersect returns null when disjoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUniverse(a);

    const t1 = Term{ .pkg = "foo", .set = try setOf(a, u, &caret_1_0), .positive = true };
    const t2 = Term{ .pkg = "foo", .set = try setOf(a, u, &caret_3_0), .positive = true };
    try std.testing.expect(try Term.intersect(t1, t2, a) == null);

    const t3 = Term{ .pkg = "foo", .set = try setOf(a, u, &ge12_lt18), .positive = true };
    const i = (try Term.intersect(t1, t3, a)).?;
    try std.testing.expect(i.positive);
    try std.testing.expect(i.satisfiesVersion(try vOf(u, a, "1.5.0")));
    try std.testing.expect(!i.satisfiesVersion(try vOf(u, a, "1.8.0")));
}
