//! Depot directory names.
//!
//! Julia's loader locates an installed package at
//! `<depot>/packages/<Name>/<version_slug(uuid, tree_hash)>`, so Ajt has to
//! reproduce that name exactly or stock `julia` will not find what Ajt
//! installed. Port of `base/loading.jl:184-205`.
//!
//! The trap, and it is a silent one: `_crc32c(::UUID)` hashes
//! `uuid.value::UInt128` (`base/uuid.jl:39`) through
//! `ccall(:jl_crc32c, ..., Ref{UInt128}, 16)` (`base/util.jl:532`) -- i.e. the
//! **native little-endian bytes of the integer**, NOT the canonical
//! big-endian UUID wire order. Feeding the canonical order produces a
//! plausible-looking but wrong slug (`wngCP` instead of `0cEwi` for
//! StaticArrays), and nothing would fail until a package silently failed to
//! load. Verified against a real depot in the tests below.
//!
//! The SHA-1 tree hash, by contrast, IS fed in canonical order.

const std = @import("std");

/// `base/loading.jl:184` — 'A'..'Z', then 'a'..'z', then '0'..'9'. The order
/// is load-bearing; it is not the ASCII order.
const slug_chars = blk: {
    var buf: [62]u8 = undefined;
    var i: usize = 0;
    for ('A'..'Z' + 1) |c| {
        buf[i] = c;
        i += 1;
    }
    for ('a'..'z' + 1) |c| {
        buf[i] = c;
        i += 1;
    }
    for ('0'..'9' + 1) |c| {
        buf[i] = c;
        i += 1;
    }
    break :blk buf;
};

pub const Uuid = struct {
    /// Canonical (big-endian / wire) byte order, as written in a TOML file.
    bytes: [16]u8,

    pub fn parse(s: []const u8) error{InvalidUuid}!Uuid {
        if (s.len != 36) return error.InvalidUuid;
        var out: Uuid = .{ .bytes = undefined };
        var bi: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (s[i] != '-') return error.InvalidUuid;
                i += 1;
                continue;
            }
            const hi = std.fmt.charToDigit(s[i], 16) catch return error.InvalidUuid;
            const lo = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidUuid;
            out.bytes[bi] = @as(u8, hi) * 16 + lo;
            bi += 1;
            i += 2;
        }
        if (bi != 16) return error.InvalidUuid;
        return out;
    }

    /// The bytes Julia actually hashes: the UInt128 in native order.
    fn hashOrder(self: Uuid) [16]u8 {
        var le: [16]u8 = undefined;
        for (self.bytes, 0..) |b, i| le[15 - i] = b;
        if (comptime @import("builtin").cpu.arch.endian() == .big) return self.bytes;
        return le;
    }
};

/// A 20-byte git tree hash, in canonical order.
pub const Sha1 = struct {
    bytes: [20]u8,

    pub fn parse(s: []const u8) error{InvalidSha1}!Sha1 {
        if (s.len != 40) return error.InvalidSha1;
        var out: Sha1 = .{ .bytes = undefined };
        for (0..20) |i| {
            const hi = std.fmt.charToDigit(s[i * 2], 16) catch return error.InvalidSha1;
            const lo = std.fmt.charToDigit(s[i * 2 + 1], 16) catch return error.InvalidSha1;
            out.bytes[i] = @as(u8, hi) * 16 + lo;
        }
        return out;
    }
};

/// `slug(x::UInt32, p::Int)` — base-62, **least significant digit first**.
pub fn slug(x: u32, p: usize, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= p);
    const base: u32 = @intCast(slug_chars.len);
    var y: u32 = x;
    for (0..p) |i| {
        const d = y % base;
        y = y / base;
        buf[i] = slug_chars[d];
    }
    return buf[0..p];
}

/// `package_slug(uuid, p=5)`.
pub fn packageSlug(uuid: Uuid, buf: []u8) []const u8 {
    const crc = std.hash.crc.Crc32Iscsi.hash(&uuid.hashOrder());
    return slug(crc, 5, buf);
}

/// `version_slug(uuid, sha1, p=5)` — the directory a package is installed to.
pub fn versionSlug(uuid: Uuid, tree_hash: Sha1, buf: []u8) []const u8 {
    // Julia chains: _crc32c(sha1.bytes, _crc32c(uuid)). Chaining a CRC is the
    // same as hashing the concatenation, so one hasher over both runs works.
    var h = std.hash.crc.Crc32Iscsi.init();
    h.update(&uuid.hashOrder());
    h.update(&tree_hash.bytes);
    return slug(h.final(), 5, buf);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "slug_chars ordering is A-Za-z0-9, not ASCII order" {
    try testing.expectEqual(@as(usize, 62), slug_chars.len);
    try testing.expectEqual(@as(u8, 'A'), slug_chars[0]);
    try testing.expectEqual(@as(u8, 'Z'), slug_chars[25]);
    try testing.expectEqual(@as(u8, 'a'), slug_chars[26]);
    try testing.expectEqual(@as(u8, 'z'), slug_chars[51]);
    try testing.expectEqual(@as(u8, '0'), slug_chars[52]);
    try testing.expectEqual(@as(u8, '9'), slug_chars[61]);
}

test "uuid parsing rejects malformed input" {
    try testing.expectError(error.InvalidUuid, Uuid.parse("too-short"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("90137ffa73855640 81b9e52037218182xx"));
    const u = try Uuid.parse("90137ffa-7385-5640-81b9-e52037218182");
    try testing.expectEqual(@as(u8, 0x90), u.bytes[0]);
    try testing.expectEqual(@as(u8, 0x82), u.bytes[15]);
}

test "versionSlug reproduces real depot directory names" {
    // Ground truth from this machine's depot and Open-Reality's Manifest.toml:
    //   ~/.julia/packages/StaticArrays/0cEwi
    //   ~/.julia/packages/Ark/oUj6u
    // These are the landmark tests for the little-endian UUID trap -- feeding
    // canonical byte order yields "wngCP" for StaticArrays instead.
    const cases = [_]struct {
        uuid: []const u8,
        tree: []const u8,
        want: []const u8,
    }{
        .{
            .uuid = "90137ffa-7385-5640-81b9-e52037218182",
            .tree = "246a8bb2e6667f832eea063c3a56aef96429a3db",
            .want = "0cEwi",
        },
        .{
            .uuid = "56664e29-41e4-4ea5-ab0e-825499acc647",
            .tree = "b9e83c4a75f4a218daf487689193c5be29487ea7",
            .want = "oUj6u",
        },
    };

    for (cases) |c| {
        var buf: [8]u8 = undefined;
        const got = versionSlug(try Uuid.parse(c.uuid), try Sha1.parse(c.tree), &buf);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "slug width is configurable (the loader also probes p=4)" {
    // base/loading.jl:1127 tries version_slug(uuid, hash) and then (…, 4).
    const u = try Uuid.parse("90137ffa-7385-5640-81b9-e52037218182");
    const t = try Sha1.parse("246a8bb2e6667f832eea063c3a56aef96429a3db");
    var h = std.hash.crc.Crc32Iscsi.init();
    h.update(&u.hashOrder());
    h.update(&t.bytes);
    const crc = h.final();

    var b5: [8]u8 = undefined;
    var b4: [8]u8 = undefined;
    const s5 = slug(crc, 5, &b5);
    const s4 = slug(crc, 4, &b4);
    try testing.expectEqualStrings("0cEwi", s5);
    // Least-significant-digit-first means the shorter slug is a prefix.
    try testing.expectEqualStrings(s5[0..4], s4);
}
