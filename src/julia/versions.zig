//! `VersionBound` / `VersionRange` / `VersionSpec` and the two compat grammars.
//!
//! Port of `Pkg/src/Versions.jl`. This is the most load-bearing file in the
//! whole port: `project_hash` depends on the *canonical rendering* of a
//! `VersionSpec` (not on the source string), and the resolver depends on its
//! containment and set algebra.
//!
//! Two things routinely trip people up here, so they are called out:
//!
//! **1. There are TWO grammars, and they are not compatible.**
//!
//! | Where | Parser | Accepts |
//! |---|---|---|
//! | `Project.toml [compat]` | `semverSpec` | `^`/`~`/bare, `>= <= = <`, `A - B` (spaces REQUIRED), comma unions |
//! | registry `Compat.toml` | `VersionSpec.parse` | hyphen ranges only, no caret/tilde/inequality, spaces optional |
//!
//! So `"1-1.11"` is legal in the registry and an error in a Project, and
//! `"^0.4, 0.5"` is the reverse. Mixing them up produces wrong-but-plausible
//! resolutions rather than errors.
//!
//! **2. A `VersionBound` carries `n`, the number of *significant* components**,
//! and comparison is only over those. `VersionBound("1.5")` has n=2, so
//! `1.5.99 ≲ 1.5` is TRUE. This is why the bound type cannot be collapsed to a
//! plain 3-tuple.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Version = @import("version.zig").Version;

pub const ParseError = error{InvalidVersionSpec};

// ---------------------------------------------------------------------------
// VersionBound
// ---------------------------------------------------------------------------

pub const Bound = struct {
    t: [3]u32 = .{ 0, 0, 0 },
    /// 0 means "unbounded" (`*`); 1..3 is major/minor/patch significance.
    n: u8 = 0,

    pub fn init(parts: []const u32) Bound {
        std.debug.assert(parts.len <= 3);
        var b: Bound = .{ .n = @intCast(parts.len) };
        for (parts, 0..) |p, i| b.t[i] = p;
        return b;
    }

    pub fn fromVersion(v: Version) Bound {
        return .{ .t = .{ @intCast(v.major), @intCast(v.minor), @intCast(v.patch) }, .n = 3 };
    }

    /// `VersionBound(s)` (Versions.jl:92-116).
    pub fn parse(text: []const u8) ParseError!Bound {
        const s0 = std.mem.trim(u8, text, " \t");
        if (std.mem.eql(u8, s0, "*")) return .{};
        var s = s0;
        if (s.len != 0 and s[0] == 'v') s = s[1..];
        if (s.len == 0) return error.InvalidVersionSpec;

        var parts: [3]u32 = .{ 0, 0, 0 };
        var n: u8 = 0;
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |part| {
            if (n >= 3) return error.InvalidVersionSpec;
            parts[n] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersionSpec;
            n += 1;
        }
        return .{ .t = parts, .n = n };
    }

    /// `v ≲ b` (Versions.jl:27-32): is the version at or below this UPPER bound.
    pub fn versionAtOrBelow(b: Bound, v: Version) bool {
        return switch (b.n) {
            0 => true,
            1 => v.major <= b.t[0],
            2 => tupleLE(.{ v.major, v.minor }, .{ b.t[0], b.t[1] }),
            else => tupleLE3(.{ v.major, v.minor, v.patch }, b.t),
        };
    }

    /// `b ≲ v` (Versions.jl:34-39): is the version at or above this LOWER bound.
    pub fn versionAtOrAbove(b: Bound, v: Version) bool {
        return switch (b.n) {
            0 => true,
            1 => v.major >= b.t[0],
            2 => tupleGE(.{ v.major, v.minor }, .{ b.t[0], b.t[1] }),
            else => tupleGE3(.{ v.major, v.minor, v.patch }, b.t),
        };
    }

    /// Comparison of two LOWER bounds (Versions.jl:41-48): ties break by
    /// *fewer* significant components sorting first.
    pub fn lessLower(a: Bound, b: Bound) bool {
        const m = @min(a.n, b.n);
        for (0..m) |i| {
            if (a.t[i] < b.t[i]) return true;
            if (a.t[i] > b.t[i]) return false;
        }
        return a.n < b.n;
    }

    /// Comparison of two UPPER bounds (Versions.jl:53-60): ties break the other
    /// way -- *more* significant components sorts first, because `1.2` as an
    /// upper bound is looser than `1.2.0`.
    pub fn lessUpper(a: Bound, b: Bound) bool {
        const m = @min(a.n, b.n);
        for (0..m) |i| {
            if (a.t[i] < b.t[i]) return true;
            if (a.t[i] > b.t[i]) return false;
        }
        return a.n > b.n;
    }

    pub fn stricterLower(a: Bound, b: Bound) Bound {
        return if (lessLower(a, b)) b else a;
    }

    pub fn stricterUpper(a: Bound, b: Bound) Bound {
        return if (lessUpper(a, b)) a else b;
    }

    pub fn eql(a: Bound, b: Bound) bool {
        return a.n == b.n and std.mem.eql(u32, &a.t, &b.t);
    }

    /// `isjoinable(up, lo)` (Versions.jl:69-87): can `[.., up]` and `[lo, ..]`
    /// merge into one range. Adjacency counts, which is why `1.5` joins `1.6`.
    pub fn joinable(up: Bound, lo: Bound) bool {
        if (up.n == 0 and lo.n == 0) return true;
        if (up.n == lo.n) {
            const n = up.n;
            if (n == 0) return true;
            for (0..n - 1) |i| {
                if (up.t[i] > lo.t[i]) return true;
                if (up.t[i] < lo.t[i]) return false;
            }
            // The adjacency rule. Guard the underflow Julia gets for free.
            const last = n - 1;
            if (lo.t[last] == 0) return true;
            if (up.t[last] < lo.t[last] - 1) return false;
            return true;
        }
        const l = @min(up.n, lo.n);
        for (0..l) |i| {
            if (up.t[i] > lo.t[i]) return true;
            if (up.t[i] < lo.t[i]) return false;
        }
        return true;
    }
};

fn tupleLE(a: [2]u64, b: [2]u32) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] <= b[1];
}
fn tupleGE(a: [2]u64, b: [2]u32) bool {
    if (a[0] != b[0]) return a[0] > b[0];
    return a[1] >= b[1];
}
fn tupleLE3(a: [3]u64, b: [3]u32) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    if (a[1] != b[1]) return a[1] < b[1];
    return a[2] <= b[2];
}
fn tupleGE3(a: [3]u64, b: [3]u32) bool {
    if (a[0] != b[0]) return a[0] > b[0];
    if (a[1] != b[1]) return a[1] > b[1];
    return a[2] >= b[2];
}

// ---------------------------------------------------------------------------
// VersionRange
// ---------------------------------------------------------------------------

pub const Range = struct {
    lower: Bound = .{},
    upper: Bound = .{},

    /// The inner constructor's normalisation (Versions.jl:125-131):
    /// when the raw tuples are equal, the LOWER bound adopts the upper's `n`.
    /// This is what makes `Ark = "0.4"` render as `0.4` rather than
    /// `0.4.0 - 0.4`, and getting it wrong silently changes `project_hash`.
    pub fn init(lo: Bound, hi: Bound) Range {
        var l = lo;
        if (std.mem.eql(u32, &lo.t, &hi.t)) l = hi;
        return .{ .lower = l, .upper = hi };
    }

    /// The REGISTRY grammar (Versions.jl:140-149): `a` or `a-b`, nothing else.
    pub fn parse(text: []const u8) ParseError!Range {
        var it = std.mem.splitScalar(u8, text, '-');
        const first = it.next() orelse return error.InvalidVersionSpec;
        const lower = try Bound.parse(first);
        const second = it.next();
        if (it.next() != null) return error.InvalidVersionSpec; // more than 2 parts
        const upper = if (second) |sec| try Bound.parse(sec) else lower;
        return init(lower, upper);
    }

    pub fn isEmpty(r: Range) bool {
        const m = @min(r.lower.n, r.upper.n);
        for (0..m) |i| {
            if (r.lower.t[i] > r.upper.t[i]) return true;
            if (r.lower.t[i] < r.upper.t[i]) return false;
        }
        return false;
    }

    pub fn contains(r: Range, v: Version) bool {
        return r.lower.versionAtOrAbove(v) and r.upper.versionAtOrBelow(v);
    }

    pub fn intersect(a: Range, b: Range) Range {
        return init(
            Bound.stricterLower(a.lower, b.lower),
            Bound.stricterUpper(a.upper, b.upper),
        );
    }

    pub fn eql(a: Range, b: Range) bool {
        return a.lower.eql(b.lower) and a.upper.eql(b.upper);
    }

    /// `Base.print(::VersionRange)` (Versions.jl:159-176).
    ///
    /// Two quirks reproduced verbatim because `project_hash` hashes this text:
    /// the `m == 0` branch emits `"0 -"` with NO trailing space, and both
    /// unbounded branches join the FULL 3-tuple rather than the significant
    /// prefix.
    pub fn format(r: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const m = r.lower.n;
        const n = r.upper.n;
        if (m == 0 and n == 0) return w.writeAll("*");
        if (m == 0) {
            try w.writeAll("0 -");
            return joinAll(w, r.upper.t);
        }
        if (n == 0) {
            try joinAll(w, r.lower.t);
            return w.writeAll(" - *");
        }
        try joinPrefix(w, r.lower.t, m);
        if (!r.lower.eql(r.upper)) {
            try w.writeAll(" - ");
            try joinPrefix(w, r.upper.t, n);
        }
    }
};

fn joinAll(w: *std.Io.Writer, t: [3]u32) std.Io.Writer.Error!void {
    try w.print("{d}.{d}.{d}", .{ t[0], t[1], t[2] });
}

fn joinPrefix(w: *std.Io.Writer, t: [3]u32, n: u8) std.Io.Writer.Error!void {
    for (0..n) |i| {
        if (i != 0) try w.writeAll(".");
        try w.print("{d}", .{t[i]});
    }
}

// ---------------------------------------------------------------------------
// VersionSpec
// ---------------------------------------------------------------------------

pub const Spec = struct {
    ranges: []Range,

    pub fn deinit(self: Spec, gpa: Allocator) void {
        gpa.free(self.ranges);
    }

    /// `VersionSpec(::Vector{VersionRange})` — always normalised through
    /// `union!`, so two specs describing the same set compare equal and print
    /// identically.
    pub fn fromRanges(gpa: Allocator, ranges: []Range) Allocator.Error!Spec {
        return .{ .ranges = try unionInPlace(gpa, ranges) };
    }

    pub fn all(gpa: Allocator) Allocator.Error!Spec {
        const r = try gpa.alloc(Range, 1);
        r[0] = .{};
        return .{ .ranges = r };
    }

    /// The single version this spec denotes, or null if it denotes a set.
    ///
    /// `Pkg.pin` needs exactly this test: *"pinning a package requires a single
    /// version, not a versionrange"* (`API.jl:487-489`, which checks
    /// `ranges[1].lower != ranges[1].upper`). Note that the project grammar
    /// makes `Foo@1.2` a RANGE — `[1.2.0, 2)` — so a caller that took the
    /// lower bound of whatever it was handed would pin `Foo@1.2` to `1.2.0`
    /// while the user was asking for something else entirely.
    ///
    /// Both bounds must also be fully significant (`n == 3`): `1.2 - 1.2` has
    /// equal bounds and still spans every patch release of 1.2.
    pub fn exact(self: Spec) ?Version {
        if (self.ranges.len != 1) return null;
        const r = self.ranges[0];
        if (r.lower.n != 3 or r.upper.n != 3) return null;
        if (!std.mem.eql(u32, &r.lower.t, &r.upper.t)) return null;
        return .{ .major = r.lower.t[0], .minor = r.lower.t[1], .patch = r.lower.t[2] };
    }

    /// The REGISTRY grammar, single range or an array of them.
    pub fn parse(gpa: Allocator, text: []const u8) (ParseError || Allocator.Error)!Spec {
        const r = try gpa.alloc(Range, 1);
        errdefer gpa.free(r);
        r[0] = try Range.parse(text);
        return fromRanges(gpa, r);
    }

    pub fn parseMany(gpa: Allocator, texts: []const []const u8) (ParseError || Allocator.Error)!Spec {
        const r = try gpa.alloc(Range, texts.len);
        errdefer gpa.free(r);
        for (texts, 0..) |t, i| r[i] = try Range.parse(t);
        return fromRanges(gpa, r);
    }

    pub fn isEmpty(self: Spec) bool {
        for (self.ranges) |r| {
            if (!r.isEmpty()) return false;
        }
        return true;
    }

    pub fn contains(self: Spec, v: Version) bool {
        for (self.ranges) |r| {
            if (r.contains(v)) return true;
        }
        return false;
    }

    pub fn eql(a: Spec, b: Spec) bool {
        if (a.ranges.len != b.ranges.len) return false;
        for (a.ranges, b.ranges) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    pub fn intersect(gpa: Allocator, a: Spec, b: Spec) Allocator.Error!Spec {
        if (a.isEmpty() or b.isEmpty()) return .{ .ranges = try gpa.alloc(Range, 0) };
        const out = try gpa.alloc(Range, a.ranges.len * b.ranges.len);
        var i: usize = 0;
        for (a.ranges) |x| {
            for (b.ranges) |y| {
                out[i] = Range.intersect(x, y);
                i += 1;
            }
        }
        return fromRanges(gpa, out);
    }

    /// `Base.print(::VersionSpec)` (Versions.jl:272-281). This exact text is
    /// what `project_hash` digests.
    pub fn format(self: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isEmpty()) return w.writeAll("∅");
        if (self.ranges.len == 1) return self.ranges[0].format(w);
        try w.writeAll("[");
        for (self.ranges, 0..) |r, i| {
            if (i != 0) try w.writeAll(", ");
            try r.format(w);
        }
        try w.writeAll("]");
    }

    pub fn toString(self: Spec, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        self.format(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

/// `Base.union!(::Vector{VersionRange})` (Versions.jl:183-214). Sorts, then
/// coalesces adjacent/overlapping ranges. Takes ownership of `ranges` and
/// returns a resized slice.
fn unionInPlace(gpa: Allocator, ranges: []Range) Allocator.Error![]Range {
    if (ranges.len == 0) return ranges;

    std.mem.sort(Range, ranges, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            if (Bound.lessLower(a.lower, b.lower)) return true;
            if (a.lower.eql(b.lower)) return Bound.lessUpper(a.upper, b.upper);
            return false;
        }
    }.lt);

    var ks: ?usize = null;
    for (ranges, 0..) |r, i| {
        if (!r.isEmpty()) {
            ks = i;
            break;
        }
    }
    const start = ks orelse return gpa.realloc(ranges, 0) catch ranges[0..0];

    var lo = ranges[start].lower;
    var up = ranges[start].upper;
    var k0: usize = 0;

    for (ranges[start + 1 ..]) |r| {
        if (r.isEmpty()) continue;
        if (Bound.joinable(up, r.lower)) {
            if (Bound.lessUpper(up, r.upper)) up = r.upper;
            continue;
        }
        ranges[k0] = Range.init(lo, up);
        k0 += 1;
        lo = r.lower;
        up = r.upper;
    }
    const last = Range.init(lo, up);
    if (!last.isEmpty()) {
        ranges[k0] = last;
        k0 += 1;
    }
    return gpa.realloc(ranges, k0) catch ranges[0..k0];
}

// ---------------------------------------------------------------------------
// semver_spec — the Project.toml [compat] grammar
// ---------------------------------------------------------------------------

/// `semver_spec(s)` (Versions.jl:303-325): comma-separated union of terms,
/// each matched against three alternatives in order (caret/tilde, inequality,
/// hyphen). Zig has no regex, so the alternatives are hand-parsed; the tests
/// below pin the behaviour against Julia.
pub fn semverSpec(gpa: Allocator, text: []const u8) (ParseError || Allocator.Error)!Spec {
    var list: std.ArrayList(Range) = .empty;
    errdefer list.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " \t");
        if (term.len == 0) return error.InvalidVersionSpec;
        try list.append(gpa, try parseSemverTerm(term));
    }
    if (list.items.len == 0) return error.InvalidVersionSpec;
    return Spec.fromRanges(gpa, try list.toOwnedSlice(gpa));
}

const Numeric = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    /// How many components were actually written: 1, 2 or 3.
    significant: u8 = 0,
};

/// `v?([0-9]+)(\.([0-9]+))?(\.([0-9]+))?` anchored to the whole slice.
fn parseNumeric(text: []const u8) ParseError!Numeric {
    var s = text;
    if (s.len != 0 and s[0] == 'v') s = s[1..];
    if (s.len == 0) return error.InvalidVersionSpec;

    var out: Numeric = .{};
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (out.significant >= 3) return error.InvalidVersionSpec;
        if (part.len == 0) return error.InvalidVersionSpec;
        const n = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersionSpec;
        switch (out.significant) {
            0 => out.major = n,
            1 => out.minor = n,
            else => out.patch = n,
        }
        out.significant += 1;
    }
    return out;
}

fn parseSemverTerm(term: []const u8) ParseError!Range {
    // Alternative 3 (hyphen) is checked first in practice because its ` - `
    // separator is unambiguous; Julia reaches the same result by anchoring.
    if (std.mem.indexOf(u8, term, " - ")) |at| {
        const lo = try parseNumeric(std.mem.trim(u8, term[0..at], " \t"));
        const hi = try parseNumeric(std.mem.trim(u8, term[at + 3 ..], " \t"));
        return Range.init(
            Bound.init(sigSlice(lo)[0..lo.significant]),
            Bound.init(sigSlice(hi)[0..hi.significant]),
        );
    }

    // Alternative 2: inequality prefixes.
    const ineq = [_][]const u8{ ">=", "≥", "<", "=" };
    for (ineq) |op| {
        if (std.mem.startsWith(u8, term, op)) {
            const rest = std.mem.trim(u8, term[op.len..], " \t");
            const num = try parseNumeric(rest);
            return inequalityInterval(op, num);
        }
    }

    // Alternative 1: caret / tilde / bare.
    var typ: u8 = '^';
    var rest = term;
    if (term.len != 0 and (term[0] == '^' or term[0] == '~')) {
        typ = term[0];
        rest = term[1..];
    }
    const num = try parseNumeric(rest);
    return semverInterval(typ, num);
}

fn sigSlice(n: Numeric) [3]u32 {
    return .{ n.major, n.minor, n.patch };
}

/// `semver_interval` (Versions.jl:327-361).
fn semverInterval(typ: u8, num: Numeric) ParseError!Range {
    if (num.significant == 3 and num.major == 0 and num.minor == 0 and num.patch == 0)
        return error.InvalidVersionSpec; // "0.0.0" is rejected outright

    const v0 = Bound.init(&.{ num.major, num.minor, num.patch });

    if (typ == '^') {
        if (num.major != 0) return Range.init(v0, Bound.init(&.{num.major}));
        if (num.minor != 0) return Range.init(v0, Bound.init(&.{ num.major, num.minor }));
        return switch (num.significant) {
            1 => Range.init(v0, Bound.init(&.{0})),
            2 => Range.init(v0, Bound.init(&.{ 0, 0 })),
            else => Range.init(v0, Bound.init(&.{ 0, 0, num.patch })),
        };
    }
    // tilde
    if (num.significant >= 2) return Range.init(v0, Bound.init(&.{ num.major, num.minor }));
    return Range.init(v0, Bound.init(&.{num.major}));
}

/// `inequality_interval` (Versions.jl:364-394).
fn inequalityInterval(op: []const u8, num: Numeric) ParseError!Range {
    if (num.significant == 3 and num.major == 0 and num.minor == 0 and num.patch == 0)
        return error.InvalidVersionSpec;

    const v = Bound.init(&.{ num.major, num.minor, num.patch });

    if (std.mem.eql(u8, op, "<")) {
        // Decrement to make the bound exclusive.
        var v1: Bound = undefined;
        if (v.t[2] == 0) {
            if (v.t[1] == 0) {
                if (v.t[0] == 0) return error.InvalidVersionSpec;
                v1 = Bound.init(&.{v.t[0] - 1});
            } else {
                v1 = Bound.init(&.{ v.t[0], v.t[1] - 1 });
            }
        } else {
            v1 = Bound.init(&.{ v.t[0], v.t[1], v.t[2] - 1 });
        }
        return Range.init(Bound.init(&.{ 0, 0, 0 }), v1);
    }
    if (std.mem.eql(u8, op, "=")) return Range.init(v, v);
    // ">=" or "≥"
    return Range.init(v, .{});
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const parseVersion = @import("version.zig").parse;

fn specString(s: Spec) ![]u8 {
    return s.toString(testing.allocator);
}

test "the four canonical renderings from Open-Reality's Project.toml" {
    // These exact strings are what project_hash digests; the committed hash
    // 5e05dae… depends on every one of them. Verified against
    //   julia -e 'using Pkg; print(Pkg.Versions.semver_spec("0.4"))'
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "0.4", .want = "0.4" }, // NOT "0.4.0 - 0.4"
        .{ .in = "3", .want = "3" },
        .{ .in = "0.11, 0.12", .want = "0.11 - 0.12" }, // merged by union!
        .{ .in = "1.5", .want = "1.5.0 - 1" },
        // Both bounds keep n=2, so neither is padded to three components.
        .{ .in = "1.21 - 1.23", .want = "1.21 - 1.23" },
        .{ .in = "0.1.2", .want = "0.1.2 - 0.1" },
        .{ .in = "1.18.0", .want = "1.18.0 - 1" },
        .{ .in = "0.7.7", .want = "0.7.7 - 0.7" },
    };
    for (cases) |c| {
        const spec = try semverSpec(testing.allocator, c.in);
        defer spec.deinit(testing.allocator);
        const got = try specString(spec);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "caret rules key on significance, not magnitude" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "1.5", .want = "1.5.0 - 1" },
        .{ .in = "^1.5", .want = "1.5.0 - 1" },
        .{ .in = "0.4", .want = "0.4" },
        // `0` and `~1` collapse: Range.init sees equal raw tuples and adopts
        // the upper bound's significance, so they print as a single component
        // rather than a range. This collapse is exactly what makes
        // project_hash reproducible.
        .{ .in = "0", .want = "0" },
        .{ .in = "0.0", .want = "0.0" },
        .{ .in = "0.0.3", .want = "0.0.3" },
        .{ .in = "~0.3.2", .want = "0.3.2 - 0.3" },
        .{ .in = "~1", .want = "1" },
    };
    for (cases) |c| {
        const spec = try semverSpec(testing.allocator, c.in);
        defer spec.deinit(testing.allocator);
        const got = try specString(spec);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    // 0.0.0 is rejected outright (Versions.jl:334-336).
    try testing.expectError(error.InvalidVersionSpec, semverSpec(testing.allocator, "0.0.0"));
}

test "inequality forms" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "<0.2", .want = "0.0.0 - 0.1" },
        .{ .in = ">=0.5", .want = "0.5.0 - *" },
        .{ .in = "=1.2.3", .want = "1.2.3" },
    };
    for (cases) |c| {
        const spec = try semverSpec(testing.allocator, c.in);
        defer spec.deinit(testing.allocator);
        const got = try specString(spec);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "registry grammar accepts hyphens the Project grammar rejects" {
    // "1-1.11" appears verbatim in S/StaticArrays/Compat.toml.
    const spec = try Spec.parse(testing.allocator, "1-1.11");
    defer spec.deinit(testing.allocator);
    const got = try specString(spec);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("1 - 1.11", got);

    // The two grammars are genuinely different: caret is meaningless in the
    // registry grammar, so it fails to parse rather than being honoured.
    try testing.expectError(error.InvalidVersionSpec, Spec.parse(testing.allocator, "^0.4"));
}

test "significance-aware containment" {
    const v = try parseVersion(testing.allocator, "1.5.99");
    defer if (v.prerelease.len != 0) testing.allocator.free(v.prerelease);

    // Bound("1.5") has n=2, so only major/minor are compared: 1.5.99 fits.
    const spec = try Spec.parse(testing.allocator, "1.5");
    defer spec.deinit(testing.allocator);
    try testing.expect(spec.contains(v));

    const narrow = try Spec.parse(testing.allocator, "1.5.0");
    defer narrow.deinit(testing.allocator);
    try testing.expect(!narrow.contains(v));
}

test "union merges adjacent ranges, keeps disjoint ones" {
    const merged = try semverSpec(testing.allocator, "0.11, 0.12");
    defer merged.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), merged.ranges.len);

    const disjoint = try semverSpec(testing.allocator, "0.1, 0.9");
    defer disjoint.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), disjoint.ranges.len);
    const got = try specString(disjoint);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[0.1, 0.9]", got);
}

test "unbounded spec prints as *" {
    const spec = try Spec.all(testing.allocator);
    defer spec.deinit(testing.allocator);
    const got = try specString(spec);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("*", got);
}

test "intersect narrows to the overlap" {
    const a = try semverSpec(testing.allocator, "1");
    defer a.deinit(testing.allocator);
    const b = try semverSpec(testing.allocator, ">=1.5");
    defer b.deinit(testing.allocator);
    const c = try Spec.intersect(testing.allocator, a, b);
    defer c.deinit(testing.allocator);

    const v14 = try parseVersion(testing.allocator, "1.4.0");
    const v15 = try parseVersion(testing.allocator, "1.5.0");
    try testing.expect(!c.contains(v14));
    try testing.expect(c.contains(v15));
}
