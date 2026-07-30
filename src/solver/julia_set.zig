//! Julia version sets for the PubGrub solver — the version-model seam.
//!
//! This is the replacement for baker's vendored `version.zig` (SemVer 2.0.0),
//! and the reason it exists is a correctness argument rather than a
//! performance one.
//!
//! ## Why a bitset and not a range algebra
//!
//! PubGrub needs a version-set type closed under COMPLEMENT: negative terms
//! are the whole point of the algorithm, and `Term.trueSet` computes
//! `complement(set)` for every one of them. Julia's `VersionSpec` is not a
//! clean lattice to complement over:
//!
//!   * `VersionBound` carries `n`, the count of significant components, and
//!     comparison spans only those — `1.5.99` is inside the bound `1.5`
//!     (`Versions.jl:27-39`).
//!   * `≲` ignores prerelease and build metadata; `VersionNumber` ordering
//!     does not. So the order used to compare bounds and the order used to
//!     compare versions disagree.
//!   * `VersionRange`'s constructor collapses `lo.t == hi.t`, and
//!     `isjoinable` merges adjacent ranges like `1.5` and `1.6`.
//!
//! Complementing that directly means deciding what "just below the lower
//! bound" is in a space where bounds have variable significance and the
//! ordering is not total in the way the bounds pretend. That is a trap.
//!
//! So: for each package, take the FINITE ordered candidate list from its
//! `Versions.toml` and represent every version set as a bitmask over that
//! index space. Complement is `~`, union `|`, intersection `&`, emptiness
//! `popcount == 0`. All of Julia's semantics then collapse into ONE function
//! — "is this version in this spec", `versions.Spec.contains` — which is a
//! small pure port that is differential-tested against Julia in isolation.
//! Exactness becomes a property of one function instead of an emergent
//! property of a set algebra.
//!
//! Cost: the largest package in General has ~1400 versions, so 176 bytes per
//! mask. That is nothing.
//!
//! ## The universe, and why every value carries one
//!
//! A bitset is meaningless without the list it indexes. PubGrub only ever
//! combines sets belonging to the SAME package — `Term.intersect` asserts
//! `a.pkg == b.pkg` — so a set can safely carry a pointer to its package's
//! `Universe`, and every operation asserts the two agree. That assert is not
//! defensive noise: it is the invariant that makes the representation sound,
//! and if the solver ever violated it the bits would silently mean the wrong
//! versions.
//!
//! `Version` carries its universe too, which is what lets
//! `VersionSet.exact(v)` work without the caller threading a registry
//! through — the seam the vendored solver's construction sites need.
//!
//! ## The absent bit, and why the model is broken without it
//!
//! A PubGrub term ranges over a package's versions PLUS the possibility that
//! the package is **not selected at all**. That extra element is load-bearing:
//! a dependency is encoded as the incompatibility `{P@v, ¬dep ∈ range}`, whose
//! second term means "dep is outside range" — and "dep is absent" is precisely
//! one of the ways that can hold.
//!
//! On baker's infinite semver axis the room for it came for free: `¬dep ∈ R`
//! always had somewhere to live outside R. Over a FINITE candidate list it
//! does not. When `range` happens to cover every version a package published
//! — which is the common case, not an exotic one, since `^1` covers all of a
//! package that only ever shipped 1.x — `complement(range)` is EMPTY, the
//! term is unsatisfiable, the incompatibility reads as vacuous, and the
//! dependency is never derived at all. The solver then returns a graph with
//! undecided dependencies in it.
//!
//! So each universe reserves one extra bit at index `n` meaning "absent".
//! `fromSpec` and `exact` never set it (a constraint is about versions);
//! `complement` does (so a negated dependency stays satisfiable); and the
//! selection helpers — `count`, `highest`, `lowest` — ignore it, because no
//! caller ever wants to install "absent".

const std = @import("std");
const Allocator = std.mem.Allocator;
const jver = @import("../julia/version.zig");
const jspec = @import("../julia/versions.zig");

pub const Error = error{
    /// A version that is not in the package's candidate list. Callers get
    /// this rather than a silently-empty set, because "resolve produced an
    /// empty answer" and "you asked about a version that does not exist"
    /// are different bugs.
    UnknownVersion,
} || Allocator.Error;

/// A package's finite, sorted candidate list — the index space every bitset
/// over that package is interpreted against.
///
/// `versions` must be sorted ascending by `jver.Version.order` and must not
/// contain duplicates; `init` asserts both, because a mis-sorted universe
/// would make `indexOf`'s binary search wrong in a way no test above this
/// layer would localise.
pub const Universe = struct {
    name: []const u8,
    versions: []const jver.Version,
    /// Parallel to `versions`. Yanked versions are kept in the universe (so
    /// an error can say "1.2.3 exists but is yanked" rather than "no such
    /// version") but are excluded from the candidate set the solver starts
    /// from. Empty means "nothing yanked".
    yanked: []const bool = &.{},
    words: usize,

    pub fn init(name: []const u8, sorted_versions: []const jver.Version, yanked: []const bool) Universe {
        if (std.debug.runtime_safety and sorted_versions.len > 1) {
            for (sorted_versions[1..], 0..) |v, i| {
                std.debug.assert(jver.Version.order(sorted_versions[i], v) == .lt);
            }
        }
        std.debug.assert(yanked.len == 0 or yanked.len == sorted_versions.len);
        return .{
            .name = name,
            .versions = sorted_versions,
            .yanked = yanked,
            // +1 for the absent bit at index `versions.len`.
            .words = (sorted_versions.len + 1 + 63) / 64,
        };
    }

    pub fn count(self: *const Universe) usize {
        return self.versions.len;
    }

    pub fn isYanked(self: *const Universe, idx: u32) bool {
        return self.yanked.len != 0 and self.yanked[idx];
    }

    /// Index of `v`, or null if this package has no such version.
    pub fn indexOf(self: *const Universe, v: jver.Version) ?u32 {
        var lo: usize = 0;
        var hi: usize = self.versions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (jver.Version.order(self.versions[mid], v)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return @intCast(mid),
            }
        }
        return null;
    }

    pub fn at(self: *const Universe, idx: u32) Version {
        std.debug.assert(idx < self.versions.len);
        return .{ .universe = self, .idx = idx };
    }

    /// Index of the "package not selected" bit.
    pub fn absentIndex(self: *const Universe) u32 {
        return @intCast(self.versions.len);
    }

    /// Number of representable slots: every version, plus absent.
    fn slots(self: *const Universe) usize {
        return self.versions.len + 1;
    }

    /// Mask of the valid bits in the final word, over `slots()`.
    fn tailMask(self: *const Universe) u64 {
        const rem: u6 = @intCast(self.slots() % 64);
        return if (rem == 0) ~@as(u64, 0) else (@as(u64, 1) << rem) - 1;
    }
};

/// A concrete version: an index into a package's universe.
///
/// Deliberately NOT a `jver.Version` copy. Identity is (universe, index), so
/// equality is two integer compares and ordering is one — and it is
/// impossible to hold a version that the package does not actually offer.
pub const Version = struct {
    universe: *const Universe,
    idx: u32,

    /// The Julia `VersionNumber` this stands for.
    pub fn number(self: Version) jver.Version {
        return self.universe.versions[self.idx];
    }

    pub fn isYanked(self: Version) bool {
        return self.universe.isYanked(self.idx);
    }

    pub fn eql(a: Version, b: Version) bool {
        if (a.universe == b.universe) return a.idx == b.idx;
        // Different universes: fall back to the real version numbers, so a
        // version compared across two views of the same package still
        // behaves. Same package name is the caller's responsibility.
        return jver.Version.eql(a.number(), b.number());
    }

    /// Ordering. Within one universe this is index order, which IS version
    /// order because `Universe.init` requires the list sorted.
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.universe == b.universe) return std.math.order(a.idx, b.idx);
        return jver.Version.order(a.number(), b.number());
    }

    pub fn format(self: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f}", .{self.number()});
    }
};

/// A set of versions of ONE package, as a bitmask over its universe.
pub const VersionSet = struct {
    universe: *const Universe,
    /// `universe.words` words; bit i of word w is candidate index w*64+i.
    bits: []u64,

    // -- construction ------------------------------------------------------

    fn alloc(gpa: Allocator, universe: *const Universe) Allocator.Error!VersionSet {
        const bits = try gpa.alloc(u64, universe.words);
        @memset(bits, 0);
        return .{ .universe = universe, .bits = bits };
    }

    /// The empty set over `universe`.
    pub fn empty(gpa: Allocator, universe: *const Universe) Allocator.Error!VersionSet {
        return alloc(gpa, universe);
    }

    /// The whole space: every version AND absent. This is the universal set
    /// the algebra's `isAny` refers to — "no constraint at all".
    pub fn full(gpa: Allocator, universe: *const Universe) Allocator.Error!VersionSet {
        const s = try alloc(gpa, universe);
        @memset(s.bits, ~@as(u64, 0));
        if (s.bits.len != 0) s.bits[s.bits.len - 1] &= universe.tailMask();
        return s;
    }

    /// Every version, INCLUDING yanked ones, but NOT absent. This is what a
    /// requirement means: the package must be installed at one of these.
    pub fn allVersions(gpa: Allocator, universe: *const Universe) Allocator.Error!VersionSet {
        var s = try full(gpa, universe);
        s.clear(universe.absentIndex());
        return s;
    }

    /// Every non-yanked version. This is what a package's candidate set
    /// starts as: yanked versions stay in the universe so errors can mention
    /// them, but are never selectable.
    pub fn unyanked(gpa: Allocator, universe: *const Universe) Allocator.Error!VersionSet {
        var s = try allVersions(gpa, universe);
        for (0..universe.versions.len) |i| {
            if (universe.isYanked(@intCast(i))) s.clear(@intCast(i));
        }
        return s;
    }

    /// The singleton `{v}`.
    pub fn exact(gpa: Allocator, v: Version) Allocator.Error!VersionSet {
        var s = try alloc(gpa, v.universe);
        s.set(v.idx);
        return s;
    }

    /// An empty set over the SAME universe as `like`.
    ///
    /// This is the seam that lets the vendored solver keep its three
    /// `empty_set` construction sites correct. A universe-less empty set
    /// would be unrepresentable here, and — worse — `complement`ing one
    /// (which `negate` + `trueSet` can reach) would have no idea how many
    /// bits to produce.
    pub fn emptyLike(gpa: Allocator, like: VersionSet) Allocator.Error!VersionSet {
        return alloc(gpa, like.universe);
    }

    /// The bridge where Julia's semantics enter, and the ONLY one.
    ///
    /// `spec` is an already-parsed `VersionSpec` — from the registry grammar
    /// (`Spec.parse`) or the Project.toml grammar (`semverSpec`); those two
    /// are mutually incompatible and choosing between them is the caller's
    /// job, not this function's. Every candidate is tested with
    /// `Spec.contains`, which is the literal port of `Versions.jl:179`.
    pub fn fromSpec(gpa: Allocator, universe: *const Universe, spec: jspec.Spec) Allocator.Error!VersionSet {
        var s = try alloc(gpa, universe);
        for (universe.versions, 0..) |v, i| {
            if (spec.contains(v)) s.set(@intCast(i));
        }
        return s;
    }

    /// A dependency's constraint is already a set over the dependency's own
    /// universe in this model, so this is a defensive copy. The name is kept
    /// because the vendored solver calls it at its one `Dependency.range`
    /// construction site.
    pub fn fromRange(gpa: Allocator, r: Range) Allocator.Error!VersionSet {
        return r.clone(gpa);
    }

    pub fn clone(self: VersionSet, gpa: Allocator) Allocator.Error!VersionSet {
        return .{ .universe = self.universe, .bits = try gpa.dupe(u64, self.bits) };
    }

    pub fn deinit(self: VersionSet, gpa: Allocator) void {
        gpa.free(self.bits);
    }

    // -- single-bit access -------------------------------------------------

    fn set(self: *VersionSet, idx: u32) void {
        self.bits[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }

    fn clear(self: *VersionSet, idx: u32) void {
        self.bits[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
    }

    /// Membership of a VERSION index. Out-of-range (including the absent
    /// slot) is false — use `hasAbsent` for that deliberately.
    pub fn has(self: VersionSet, idx: u32) bool {
        if (idx >= self.universe.versions.len) return false;
        return (self.bits[idx / 64] >> @intCast(idx % 64)) & 1 == 1;
    }

    /// Does this set admit the package not being selected at all?
    pub fn hasAbsent(self: VersionSet) bool {
        const i = self.universe.absentIndex();
        return (self.bits[i / 64] >> @intCast(i % 64)) & 1 == 1;
    }

    // -- predicates --------------------------------------------------------

    pub fn isEmpty(self: VersionSet) bool {
        for (self.bits) |w| {
            if (w != 0) return false;
        }
        return true;
    }

    pub fn isAny(self: VersionSet) bool {
        if (self.bits.len == 0) return true;
        for (self.bits[0 .. self.bits.len - 1]) |w| {
            if (w != ~@as(u64, 0)) return false;
        }
        return self.bits[self.bits.len - 1] == self.universe.tailMask();
    }

    pub fn contains(self: VersionSet, v: Version) bool {
        std.debug.assert(self.universe == v.universe);
        return self.has(v.idx);
    }

    pub fn eql(a: VersionSet, b: VersionSet) bool {
        std.debug.assert(a.universe == b.universe);
        return std.mem.eql(u64, a.bits, b.bits);
    }

    /// Is `other` a subset of `self`?
    pub fn containsSet(self: VersionSet, other: VersionSet) bool {
        std.debug.assert(self.universe == other.universe);
        for (self.bits, other.bits) |s, o| {
            if (o & ~s != 0) return false;
        }
        return true;
    }

    /// Number of VERSIONS in the set. Deliberately excludes the absent bit:
    /// every caller uses this to count installable candidates.
    pub fn count(self: VersionSet) usize {
        var n: usize = 0;
        for (self.bits) |w| n += @popCount(w);
        return n - @intFromBool(self.hasAbsent());
    }

    // -- algebra -----------------------------------------------------------

    pub fn unionWith(a: VersionSet, b: VersionSet, gpa: Allocator) Allocator.Error!VersionSet {
        std.debug.assert(a.universe == b.universe);
        const s = try alloc(gpa, a.universe);
        for (s.bits, a.bits, b.bits) |*o, x, y| o.* = x | y;
        return s;
    }

    pub fn intersect(a: VersionSet, b: VersionSet, gpa: Allocator) Allocator.Error!VersionSet {
        std.debug.assert(a.universe == b.universe);
        const s = try alloc(gpa, a.universe);
        for (s.bits, a.bits, b.bits) |*o, x, y| o.* = x & y;
        return s;
    }

    pub fn complement(self: VersionSet, gpa: Allocator) Allocator.Error!VersionSet {
        var s = try alloc(gpa, self.universe);
        for (s.bits, self.bits) |*o, x| o.* = ~x;
        // Bits past the end of the candidate list must stay zero, or
        // `isAny`, `count` and `eql` all disagree with each other.
        if (s.bits.len != 0) s.bits[s.bits.len - 1] &= self.universe.tailMask();
        return s;
    }

    pub fn difference(a: VersionSet, b: VersionSet, gpa: Allocator) Allocator.Error!VersionSet {
        std.debug.assert(a.universe == b.universe);
        const s = try alloc(gpa, a.universe);
        for (s.bits, a.bits, b.bits) |*o, x, y| o.* = x & ~y;
        return s;
    }

    // -- selection ---------------------------------------------------------

    /// The highest version in the set, or null if empty.
    ///
    /// PubGrub's decision rule picks the highest allowed version, and the
    /// universe is sorted ascending, so this is a reverse scan for the top
    /// set bit.
    pub fn highest(self: VersionSet) ?Version {
        // Scan down from the highest VERSION index; the absent bit sits above
        // them all and is never installable.
        var i: usize = self.universe.versions.len;
        while (i > 0) {
            i -= 1;
            if (self.has(@intCast(i))) return self.universe.at(@intCast(i));
        }
        return null;
    }

    /// The lowest version in the set, or null if empty.
    pub fn lowest(self: VersionSet) ?Version {
        for (0..self.universe.versions.len) |i| {
            if (self.has(@intCast(i))) return self.universe.at(@intCast(i));
        }
        return null;
    }

    /// Renders as Julia-ish version ranges rather than as a bit dump, since
    /// this text ends up in resolver error messages. Consecutive candidates
    /// collapse into `lo-hi`; a lone version prints bare.
    pub fn format(self: VersionSet, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isEmpty()) return w.writeAll("∅");
        if (self.isAny()) return w.writeAll("*");
        var first = true;
        if (self.hasAbsent()) {
            try w.writeAll("absent");
            first = false;
        }
        var i: u32 = 0;
        const n: u32 = @intCast(self.universe.versions.len);
        while (i < n) {
            if (!self.has(i)) {
                i += 1;
                continue;
            }
            var j = i;
            while (j + 1 < n and self.has(j + 1)) j += 1;
            if (!first) try w.writeAll(", ");
            first = false;
            if (i == j) {
                try w.print("{f}", .{self.universe.versions[i]});
            } else {
                try w.print("{f}-{f}", .{ self.universe.versions[i], self.universe.versions[j] });
            }
            i = j + 1;
        }
    }
};

/// In the Julia model a dependency's constraint is just a set over the
/// DEPENDENCY's universe, so `Range` and `VersionSet` are the same type. The
/// alias exists because the vendored solver's `manifest.Dependency` names the
/// field `range`.
pub const Range = VersionSet;

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a universe from version strings. Test-only: it leaks into the
/// arena the caller passes, which is what tests want.
fn uni(arena: Allocator, name: []const u8, strs: []const []const u8) !Universe {
    const vs = try arena.alloc(jver.Version, strs.len);
    for (strs, 0..) |s, i| vs[i] = try jver.parse(arena, s);
    return Universe.init(name, vs, &.{});
}

test "universe indexes its candidate list" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "0.1.0", "0.2.0", "1.0.0", "1.1.0" });

    try testing.expectEqual(@as(usize, 4), u.count());
    try testing.expectEqual(@as(?u32, 2), u.indexOf(try jver.parse(g, "1.0.0")));
    try testing.expectEqual(@as(?u32, null), u.indexOf(try jver.parse(g, "9.9.9")));
}

test "set algebra: complement never leaks past the candidate count" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    // 3 versions -> one word with 61 bits that must stay zero.
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0", "2.0.0" });

    const e = try VersionSet.empty(g, &u);
    const f = try VersionSet.full(g, &u);
    try testing.expect(e.isEmpty());
    try testing.expect(f.isAny());
    try testing.expectEqual(@as(usize, 3), f.count());

    // The trap this guards: ~0 has 64 bits set, but only 3 are real.
    const ce = try e.complement(g);
    try testing.expect(ce.isAny());
    try testing.expectEqual(@as(usize, 3), ce.count());
    try testing.expect(ce.eql(f));

    const cf = try f.complement(g);
    try testing.expect(cf.isEmpty());
}

test "complement is exact across a word boundary" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    // 130 versions -> 3 words, the last holding 2 real bits.
    var strs: [130][]const u8 = undefined;
    for (0..130) |i| strs[i] = try std.fmt.allocPrint(g, "1.0.{d}", .{i});
    const u = try uni(g, "Big", &strs);

    const f = try VersionSet.full(g, &u);
    try testing.expectEqual(@as(usize, 130), f.count());
    try testing.expect(f.isAny());

    var one = try VersionSet.exact(g, u.at(129));
    try testing.expectEqual(@as(usize, 1), one.count());
    const rest = try one.complement(g);
    try testing.expectEqual(@as(usize, 129), rest.count());
    try testing.expect(!rest.isAny());
    // Double complement is the identity -- the property that fails first if
    // the tail mask is wrong.
    const back = try rest.complement(g);
    try testing.expect(back.eql(one));
}

test "union, intersect, difference, containsSet" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0", "1.2.0", "2.0.0" });

    var lo = try VersionSet.empty(g, &u);
    lo.set(0);
    lo.set(1);
    var hi = try VersionSet.empty(g, &u);
    hi.set(1);
    hi.set(3);

    const un = try lo.unionWith(hi, g);
    try testing.expectEqual(@as(usize, 3), un.count());
    const in = try lo.intersect(hi, g);
    try testing.expectEqual(@as(usize, 1), in.count());
    try testing.expect(in.has(1));
    const df = try lo.difference(hi, g);
    try testing.expectEqual(@as(usize, 1), df.count());
    try testing.expect(df.has(0));

    try testing.expect(un.containsSet(lo));
    try testing.expect(un.containsSet(hi));
    try testing.expect(!lo.containsSet(hi));
    // Every set contains the empty set, and any set is a subset of itself.
    const e = try VersionSet.empty(g, &u);
    try testing.expect(lo.containsSet(e));
    try testing.expect(lo.containsSet(lo));
}

test "highest and lowest pick real versions" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0", "1.2.0", "2.0.0" });

    const f = try VersionSet.full(g, &u);
    try testing.expectEqualStrings("2.0.0", try std.fmt.allocPrint(g, "{f}", .{f.highest().?}));
    try testing.expectEqualStrings("1.0.0", try std.fmt.allocPrint(g, "{f}", .{f.lowest().?}));

    const e = try VersionSet.empty(g, &u);
    try testing.expect(e.highest() == null);
    try testing.expect(e.lowest() == null);
}

test "fromSpec is where Julia semantics enter" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "0.4.0", "0.5.0", "1.0.0", "1.5.99", "2.0.0" });

    // Registry grammar. `1.5` as a BOUND has significance 2, so 1.5.99 is
    // inside it -- the exact rule a semver range algebra gets wrong.
    const s = try jspec.Spec.parse(g, "1 - 1.5");
    const set = try VersionSet.fromSpec(g, &u, s);
    try testing.expect(!set.has(0)); // 0.4.0
    try testing.expect(!set.has(1)); // 0.5.0
    try testing.expect(set.has(2)); // 1.0.0
    try testing.expect(set.has(3)); // 1.5.99 -- inside the bound `1.5`
    try testing.expect(!set.has(4)); // 2.0.0
}

test "emptyLike keeps the universe so complement stays representable" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0" });

    const some = try VersionSet.full(g, &u);
    const e = try VersionSet.emptyLike(g, some);
    try testing.expect(e.isEmpty());
    try testing.expectEqual(&u, e.universe);
    // The case that motivated it: negating an empty term must yield "any",
    // which is only expressible if the universe survived.
    const neg = try e.complement(g);
    try testing.expect(neg.isAny());
}

test "yanked versions stay in the universe but out of the candidate set" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const vs = try g.alloc(jver.Version, 3);
    for ([_][]const u8{ "1.0.0", "1.1.0", "1.2.0" }, 0..) |s, i| vs[i] = try jver.parse(g, s);
    const yanked = try g.dupe(bool, &.{ false, true, false });
    const u = Universe.init("Foo", vs, yanked);

    const cand = try VersionSet.unyanked(g, &u);
    try testing.expectEqual(@as(usize, 2), cand.count());
    try testing.expect(!cand.has(1));
    // Still addressable, so an error can say "1.1.0 exists but is yanked".
    try testing.expectEqual(@as(?u32, 1), u.indexOf(try jver.parse(g, "1.1.0")));
    try testing.expect(u.at(1).isYanked());
}

test "format renders ranges, not bits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0", "1.2.0", "2.0.0" });

    var s = try VersionSet.empty(g, &u);
    s.set(0);
    s.set(1);
    s.set(3);
    try testing.expectEqualStrings("1.0.0-1.1.0, 2.0.0", try std.fmt.allocPrint(g, "{f}", .{s}));

    const e = try VersionSet.empty(g, &u);
    try testing.expectEqualStrings("∅", try std.fmt.allocPrint(g, "{f}", .{e}));
    const f = try VersionSet.full(g, &u);
    try testing.expectEqualStrings("*", try std.fmt.allocPrint(g, "{f}", .{f}));
}

test "an empty universe is coherent" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    // A registered package with no versions at all -- the resolver has to
    // report "no versions" rather than divide by zero.
    const u = try uni(g, "Nothing", &.{});
    const e = try VersionSet.empty(g, &u);
    const f = try VersionSet.full(g, &u);
    const av = try VersionSet.allVersions(g, &u);
    try testing.expect(e.isEmpty());
    // `full` is NOT empty even here: the absent bit is always representable,
    // which is what lets "this package is not selected" stay expressible for
    // a package with no versions at all -- exactly the case the resolver has
    // to report on.
    try testing.expect(!f.isEmpty());
    try testing.expect(f.isAny());
    try testing.expect(f.hasAbsent());
    try testing.expect(av.isEmpty());
    try testing.expectEqual(@as(usize, 0), f.count());
    try testing.expect(f.highest() == null);
    try testing.expect(f.lowest() == null);
}

test "constraints never admit absent; complement always does" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0" });

    // A spec covering EVERY candidate -- the case that broke propagation
    // before the absent bit existed.
    const spec = try jspec.Spec.parse(g, "1");
    const dep = try VersionSet.fromSpec(g, &u, spec);
    try testing.expectEqual(@as(usize, 2), dep.count());
    try testing.expect(!dep.hasAbsent());
    try testing.expect(!dep.isAny()); // it is NOT "no constraint"

    // `¬dep` must stay satisfiable: "the package is absent" is how a
    // dependency term is negated.
    const neg = try dep.complement(g);
    try testing.expect(!neg.isEmpty());
    try testing.expect(neg.hasAbsent());
    try testing.expectEqual(@as(usize, 0), neg.count());

    // exact() is a constraint too, so it never admits absent.
    const one = try VersionSet.exact(g, u.at(0));
    try testing.expect(!one.hasAbsent());
}

test "version ordering is index ordering" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try uni(g, "Foo", &.{ "1.0.0", "1.1.0", "2.0.0" });

    try testing.expectEqual(std.math.Order.lt, Version.order(u.at(0), u.at(2)));
    try testing.expectEqual(std.math.Order.eq, Version.order(u.at(1), u.at(1)));
    try testing.expectEqual(std.math.Order.gt, Version.order(u.at(2), u.at(0)));
    try testing.expect(Version.eql(u.at(1), u.at(1)));
    try testing.expect(!Version.eql(u.at(0), u.at(1)));
}
