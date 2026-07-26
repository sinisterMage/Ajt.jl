//! Julia `VersionNumber`: parsing and ordering.
//!
//! Port of `base/version.jl` (regex at :111-121, `ident_cmp` at :176-188,
//! `isless` at :201-218). Julia's ordering is *not* plain semver, and the
//! differences are load-bearing for a resolver:
//!
//!  * Identifiers are a mix of integers and strings, and comparing across the
//!     two kinds has an asymmetric rule keyed on emptiness (`:177-178`).
//!  * A trailing `+` with nothing after it ("supbuild", `:199`) sorts ABOVE
//!     every ordinary build of the same version. Pkg leans on this to express
//!     an open upper bound.
//!  * Prerelease sorts below release, but build metadata still participates in
//!     ordering -- unlike strict semver, which ignores it.
//!
//! The General registry contains ~12.6k version keys with prerelease or build
//! parts (mostly JLLs like `1.2.1-1+0`), so none of this is hypothetical.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ident = union(enum) {
    num: u64,
    str: []const u8,
};

pub const Version = struct {
    major: u64 = 0,
    minor: u64 = 0,
    patch: u64 = 0,
    prerelease: []const Ident = &.{},
    build: []const Ident = &.{},

    /// `issupbuild` (version.jl:199): build is exactly one empty string.
    pub fn isSupbuild(self: Version) bool {
        return self.build.len == 1 and self.build[0] == .str and self.build[0].str.len == 0;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);

        // A prerelease sorts BELOW the corresponding release (:208-209).
        const a_pre = a.prerelease.len != 0;
        const b_pre = b.prerelease.len != 0;
        if (a_pre and !b_pre) return .lt;
        if (!a_pre and b_pre) return .gt;

        switch (identListCmp(a.prerelease, b.prerelease)) {
            .lt => return .lt,
            .gt => return .gt,
            .eq => {},
        }

        // Supbuild (`1.2.3+`) sorts above any ordinary build (:213-214).
        const a_sup = a.isSupbuild();
        const b_sup = b.isSupbuild();
        if (!a_sup and b_sup) return .lt;
        if (a_sup and !b_sup) return .gt;

        return identListCmp(a.build, b.build);
    }

    pub fn lessThan(a: Version, b: Version) bool {
        return a.order(b) == .lt;
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.order(b) == .eq;
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease.len != 0) {
            try writer.writeAll("-");
            try writeIdents(writer, self.prerelease);
        }
        if (self.build.len != 0) {
            try writer.writeAll("+");
            try writeIdents(writer, self.build);
        }
    }
};

fn writeIdents(writer: *std.Io.Writer, idents: []const Ident) std.Io.Writer.Error!void {
    for (idents, 0..) |id, i| {
        if (i != 0) try writer.writeAll(".");
        switch (id) {
            .num => |n| try writer.print("{d}", .{n}),
            .str => |s| try writer.writeAll(s),
        }
    }
}

/// `ident_cmp` on scalars (version.jl:176-179). The cross-kind rule is keyed
/// on emptiness, not on kind precedence, which is the surprising part.
fn identCmp(a: Ident, b: Ident) std.math.Order {
    return switch (a) {
        .num => |an| switch (b) {
            .num => |bn| std.math.order(an, bn),
            .str => |bs| if (bs.len == 0) .gt else .lt,
        },
        .str => |as| switch (b) {
            .num => if (as.len == 0) .lt else .gt,
            .str => |bs| std.mem.order(u8, as, bs),
        },
    };
}

/// `ident_cmp` on tuples (version.jl:181-188): elementwise, then by length.
fn identListCmp(a: []const Ident, b: []const Ident) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const c = identCmp(a[i], b[i]);
        if (c != .eq) return c;
    }
    return std.math.order(a.len, b.len);
}

pub const ParseError = error{InvalidVersion} || Allocator.Error;

/// Parses `v?MAJOR[.MINOR[.PATCH]][-PRERELEASE][+BUILD]`.
///
/// Idents are allocated from `gpa`; a `Version` borrows from the input string
/// for its string idents, so the source must outlive it.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Version {
    var s = text;
    if (s.len != 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (s.len == 0) return error.InvalidVersion;

    var v: Version = .{};

    // Numeric core.
    var i: usize = 0;
    v.major = try readNumber(s, &i);
    if (i < s.len and s[i] == '.') {
        i += 1;
        v.minor = try readNumber(s, &i);
        if (i < s.len and s[i] == '.') {
            i += 1;
            v.patch = try readNumber(s, &i);
        }
    }

    if (i < s.len and s[i] == '-') {
        i += 1;
        const start = i;
        while (i < s.len and s[i] != '+') i += 1;
        // A bare `-` yields the single empty ident, per the `(-)` alternative
        // in VERSION_REGEX.
        v.prerelease = try splitIdents(gpa, s[start..i]);
    }

    if (i < s.len and s[i] == '+') {
        i += 1;
        v.build = try splitIdents(gpa, s[i..]);
        i = s.len;
    }

    if (i != s.len) return error.InvalidVersion;
    return v;
}

fn readNumber(s: []const u8, i: *usize) error{InvalidVersion}!u64 {
    const start = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') i.* += 1;
    if (i.* == start) return error.InvalidVersion;
    return std.fmt.parseInt(u64, s[start..i.*], 10) catch error.InvalidVersion;
}

/// `split_idents` (version.jl:123-125): dot-separated; an all-digit component
/// becomes an integer, everything else stays a string.
fn splitIdents(gpa: Allocator, s: []const u8) Allocator.Error![]const Ident {
    var out: std.ArrayList(Ident) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        var all_digits = part.len != 0;
        for (part) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            const n = std.fmt.parseInt(u64, part, 10) catch {
                try out.append(gpa, .{ .str = part });
                continue;
            };
            try out.append(gpa, .{ .num = n });
        } else {
            try out.append(gpa, .{ .str = part });
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn p(s: []const u8) !Version {
    return parse(testing.allocator, s);
}

fn freeV(v: Version) void {
    if (v.prerelease.len != 0) testing.allocator.free(v.prerelease);
    if (v.build.len != 0) testing.allocator.free(v.build);
}

test "parses the numeric core with optional components" {
    const cases = [_]struct { s: []const u8, maj: u64, min: u64, pat: u64 }{
        .{ .s = "1", .maj = 1, .min = 0, .pat = 0 },
        .{ .s = "1.2", .maj = 1, .min = 2, .pat = 0 },
        .{ .s = "1.2.3", .maj = 1, .min = 2, .pat = 3 },
        .{ .s = "v1.2.3", .maj = 1, .min = 2, .pat = 3 },
        .{ .s = "0.0.0", .maj = 0, .min = 0, .pat = 0 },
    };
    for (cases) |c| {
        const v = try p(c.s);
        defer freeV(v);
        try testing.expectEqual(c.maj, v.major);
        try testing.expectEqual(c.min, v.minor);
        try testing.expectEqual(c.pat, v.patch);
    }
    try testing.expectError(error.InvalidVersion, p(""));
    try testing.expectError(error.InvalidVersion, p("1.2.3.4"));
    try testing.expectError(error.InvalidVersion, p("abc"));
}

test "prerelease and build idents split on dots, digits become numbers" {
    const v = try p("1.2.3-alpha.1+build.7");
    defer freeV(v);
    try testing.expectEqual(@as(usize, 2), v.prerelease.len);
    try testing.expectEqualStrings("alpha", v.prerelease[0].str);
    try testing.expectEqual(@as(u64, 1), v.prerelease[1].num);
    try testing.expectEqual(@as(usize, 2), v.build.len);
    try testing.expectEqualStrings("build", v.build[0].str);
    try testing.expectEqual(@as(u64, 7), v.build[1].num);
}

test "the JLL shape 1.2.1-1+0 parses as numeric idents" {
    // ~12.6k version keys in General look like this.
    const v = try p("1.2.1-1+0");
    defer freeV(v);
    try testing.expectEqual(@as(u64, 1), v.prerelease[0].num);
    try testing.expectEqual(@as(u64, 0), v.build[0].num);
}

test "supbuild: a bare trailing + sorts above ordinary builds" {
    const sup = try p("1.2.3+");
    defer freeV(sup);
    try testing.expect(sup.isSupbuild());

    const plain = try p("1.2.3");
    defer freeV(plain);
    const withbuild = try p("1.2.3+9");
    defer freeV(withbuild);

    try testing.expect(plain.lessThan(sup));
    try testing.expect(withbuild.lessThan(sup));
    try testing.expect(!sup.lessThan(withbuild));
}

test "prerelease sorts below release" {
    const pre = try p("1.2.3-alpha");
    defer freeV(pre);
    const rel = try p("1.2.3");
    defer freeV(rel);
    try testing.expect(pre.lessThan(rel));
    try testing.expect(!rel.lessThan(pre));
}

test "ident_cmp cross-kind rule keys on emptiness, not kind" {
    // Integer vs non-empty String -> Integer is LESS (version.jl:177).
    try testing.expectEqual(std.math.Order.lt, identCmp(.{ .num = 5 }, .{ .str = "a" }));
    // Integer vs EMPTY String -> Integer is GREATER.
    try testing.expectEqual(std.math.Order.gt, identCmp(.{ .num = 5 }, .{ .str = "" }));
    try testing.expectEqual(std.math.Order.gt, identCmp(.{ .str = "a" }, .{ .num = 5 }));
    try testing.expectEqual(std.math.Order.lt, identCmp(.{ .str = "" }, .{ .num = 5 }));
    try testing.expectEqual(std.math.Order.lt, identCmp(.{ .num = 1 }, .{ .num = 2 }));
    try testing.expectEqual(std.math.Order.lt, identCmp(.{ .str = "a" }, .{ .str = "b" }));
}

test "shorter ident list sorts first when it is a prefix" {
    const a = try p("1.0.0-alpha");
    defer freeV(a);
    const b = try p("1.0.0-alpha.1");
    defer freeV(b);
    try testing.expect(a.lessThan(b));
}

test "formats back to the canonical string" {
    for ([_][]const u8{ "1.2.3", "1.2.3-alpha.1", "1.2.3+build.7", "1.2.1-1+0" }) |s| {
        const v = try p(s);
        defer freeV(v);
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try v.format(&aw.writer);
        try testing.expectEqualStrings(s, aw.written());
    }
}
