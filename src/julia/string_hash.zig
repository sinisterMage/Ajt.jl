//! `Base.hash(::String, ::UInt)`.
//!
//! Port of `base/hashing.jl:195-201`:
//!
//! ```julia
//! const memhash      = UInt === UInt64 ? :memhash_seed : :memhash32_seed
//! const memhash_seed = UInt === UInt64 ? 0x71e729fd56419c81 : 0x56419c81
//!
//! @assume_effects :total function hash(s::String, h::UInt)
//!     h += memhash_seed
//!     ccall(memhash, UInt, (Ptr{UInt8}, Csize_t, UInt32), s, sizeof(s), h % UInt32) + h
//! end
//! ```
//!
//! ## Why a package manager needs this
//!
//! `Pkg.Types.add_repo_cache_path(url) = joinpath(depots1(), "clones",
//! string(hash(url)))` (`Types.jl:901`) — a git clone's directory name IS this
//! number in base 10. And `Pkg.gc()` recomputes it for every live manifest
//! `repo.source` and **orphans every other directory under `clones/`**
//! (`API.jl:772-791`, `:985-994`). So a clone Ajt writes under any other name
//! is garbage to Pkg, in exactly the way `ops/usage.zig` exists to prevent for
//! `packages/` and `artifacts/`.
//!
//! Note there are *two* real keyings of `clones/` and they do not agree:
//! `install_git` uses `clones/<uuid>` (`Operations.jl:842-844`), while
//! `handle_repo_add!` uses this one. Both are Pkg's; see `depot.zig`.
//!
//! ## The one thing this must never do
//!
//! Julia does not promise `hash` stability across versions — it is documented
//! as an implementation detail, and the seed has changed before. A caller must
//! therefore treat a miss as **"re-clone"**, never as an error: the number is a
//! cache key, and the worst a wrong one can cost is a redundant fetch. Do not
//! build anything on top of this that fails closed.
//!
//! ## The algorithm
//!
//! `memhash_seed` (`src/support/hashing.c`) is MurmurHash3_x64_128 returning
//! **`out[1]`, the SECOND 64-bit word** — not the first, and not a 64-bit
//! variant of Murmur. Feeding back `out[0]` gives a plausible number that is
//! wrong for every input (`hash("") == 15888878324965942306` instead of
//! `13633231208144796923`), which is why the landmark tests below are captured
//! from a running Julia rather than reasoned about.
//!
//! Only the 64-bit build is ported. `memhash32_seed` exists for 32-bit `UInt`,
//! which no Julia Ajt targets uses.

const std = @import("std");

/// `memhash_seed` (`hashing.jl:196`), the 64-bit value.
pub const seed: u64 = 0x71e729fd56419c81;

/// `hash(s::String, h::UInt)`.
pub fn hash(bytes: []const u8, h_in: u64) u64 {
    const h = h_in +% seed;
    // `h % UInt32` on an unsigned integer is a truncation to the low 32 bits.
    return memhashSeed(bytes, @truncate(h)) +% h;
}

/// `hash(s::String)` — the one-argument form, i.e. `hash(s, zero(UInt))`.
pub fn hashString(bytes: []const u8) u64 {
    return hash(bytes, 0);
}

/// The directory component `Pkg` names a clone with: `string(hash(url))`,
/// Julia's decimal rendering of a `UInt64`. Returns a slice of `buf`, which
/// must hold 20 bytes (`maxInt(u64)` is 20 digits).
pub fn decimal(h: u64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{h}) catch unreachable;
}

/// `memhash_seed(buf, n, seed)` (`src/support/hashing.c`).
pub fn memhashSeed(bytes: []const u8, murmur_seed: u32) u64 {
    return murmur3X64_128(bytes, murmur_seed)[1];
}

// ---------------------------------------------------------------------------
// MurmurHash3_x64_128 (`src/support/MurmurHash3.c`), public domain.
//
// Julia's copy differs from Appleby's original only in reading blocks through
// an explicit unaligned load rather than a cast, which cannot change the
// result. The 128-bit x64 variant is NOT interchangeable with the x86 one.
// ---------------------------------------------------------------------------

const c1: u64 = 0x87c37b91114253d5;
const c2: u64 = 0x4cf5ad432745937f;

fn fmix64(k_in: u64) u64 {
    var k = k_in;
    k ^= k >> 33;
    k *%= 0xff51afd7ed558ccd;
    k ^= k >> 33;
    k *%= 0xc4ceb9fe1a85ec53;
    k ^= k >> 33;
    return k;
}

fn murmur3X64_128(data: []const u8, murmur_seed: u32) [2]u64 {
    var h1: u64 = murmur_seed;
    var h2: u64 = murmur_seed;

    const nblocks = data.len / 16;
    for (0..nblocks) |i| {
        var k1 = std.mem.readInt(u64, data[i * 16 ..][0..8], .little);
        var k2 = std.mem.readInt(u64, data[i * 16 + 8 ..][0..8], .little);

        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;

        h1 = std.math.rotl(u64, h1, 27);
        h1 +%= h2;
        h1 = h1 *% 5 +% 0x52dce729;

        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;

        h2 = std.math.rotl(u64, h2, 31);
        h2 +%= h1;
        h2 = h2 *% 5 +% 0x38495ab5;
    }

    const tail = data[nblocks * 16 ..];
    var k1: u64 = 0;
    var k2: u64 = 0;

    // The tail is folded in high byte first, exactly as the C switch's
    // fallthrough does (`case 15: k2 ^= tail[14] << 48;` downwards).
    var i: usize = tail.len;
    while (i > 8) {
        i -= 1;
        k2 ^= @as(u64, tail[i]) << @intCast(8 * (i - 8));
    }
    if (tail.len > 8) {
        k2 *%= c2;
        k2 = std.math.rotl(u64, k2, 33);
        k2 *%= c1;
        h2 ^= k2;
    }
    while (i > 0) {
        i -= 1;
        k1 ^= @as(u64, tail[i]) << @intCast(8 * i);
    }
    if (tail.len > 0) {
        k1 *%= c1;
        k1 = std.math.rotl(u64, k1, 31);
        k1 *%= c2;
        h1 ^= k1;
    }

    h1 ^= data.len;
    h2 ^= data.len;

    h1 +%= h2;
    h2 +%= h1;

    h1 = fmix64(h1);
    h2 = fmix64(h2);

    h1 +%= h2;
    h2 +%= h1;

    return .{ h1, h2 };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Captured from `julia --startup-file=no` on 1.12.6. Every tail length 0..16
/// is covered (the `switch` fallthrough is where a hand port goes wrong), plus
/// the block boundaries at 16/17 and 32/33, multi-byte UTF-8, and the URL
/// shapes `add_repo_cache_path` actually sees.
const Case = struct { s: []const u8, h0: u64, h1: u64, hmax: u64 };
const cases = [_]Case{
    .{ .s = "", .h0 = 13633231208144796923, .h1 = 14947065367464324388, .hmax = 9376320745370213716 },
    .{ .s = "a", .h0 = 18024302447460810957, .h1 = 9594914582942601857, .hmax = 15728110948991490826 },
    .{ .s = "ab", .h0 = 14211029945665094363, .h1 = 8569949336069419982, .hmax = 11661017618515812350 },
    .{ .s = "abc", .h0 = 8543511489601552240, .h1 = 8006508443328030574, .hmax = 7011598215462029348 },
    .{ .s = "abcd", .h0 = 11951860218303682075, .h1 = 141230037799191106, .hmax = 1705378119781094758 },
    .{ .s = "abcde", .h0 = 7325686699491011209, .h1 = 17353983318563782390, .hmax = 2038264216792567954 },
    .{ .s = "abcdef", .h0 = 3894003395932859521, .h1 = 2813017003607323813, .hmax = 386554353617032151 },
    .{ .s = "abcdefg", .h0 = 7194630088097970786, .h1 = 10584399756700450525, .hmax = 13212598810433339110 },
    .{ .s = "abcdefgh", .h0 = 12979263501484760675, .h1 = 9264326732479977127, .hmax = 8861853772127768020 },
    .{ .s = "abcdefghi", .h0 = 9095924067446971869, .h1 = 7453294187879115077, .hmax = 6050042817036460863 },
    .{ .s = "abcdefghij", .h0 = 9000423535604021156, .h1 = 4373259483241152185, .hmax = 15037919608557538419 },
    .{ .s = "abcdefghijk", .h0 = 3005940564445150958, .h1 = 1154146538349806366, .hmax = 1242070843002813397 },
    .{ .s = "abcdefghijkl", .h0 = 4422626671479359732, .h1 = 12232266378440681151, .hmax = 3128901743397844803 },
    .{ .s = "abcdefghijklm", .h0 = 862015212205199993, .h1 = 12314093244574115230, .hmax = 4217963634871138986 },
    .{ .s = "abcdefghijklmn", .h0 = 10773947608266705270, .h1 = 17478558142520239182, .hmax = 18417831766334042184 },
    .{ .s = "abcdefghijklmno", .h0 = 1120374965977382876, .h1 = 11369807238913208072, .hmax = 1105606173024992896 },
    // Exactly one block: the tail is empty and only the body loop runs.
    .{ .s = "abcdefghijklmnop", .h0 = 3257230385288674194, .h1 = 15281779197097427761, .hmax = 9509849936935423105 },
    .{ .s = "abcdefghijklmnopq", .h0 = 14312299878918410009, .h1 = 6635257856189175162, .hmax = 10693850887238788456 },
    // Two full blocks, then three-plus blocks with a tail.
    .{ .s = "abcdefghijklmnopqrstuvwxyzab", .h0 = 7158978172373788135, .h1 = 12124787788737048518, .hmax = 13881080168335566440 },
    .{ .s = "abcdefghijklmnopqrstuvwxyzabcdef", .h0 = 17028726329424746891, .h1 = 8460599224389132309, .hmax = 8529519473507394782 },
    .{ .s = "abcdefghijklmnopqrstuvwxyzabcdefg", .h0 = 16562435689907765952, .h1 = 14184872046788534696, .hmax = 11582300214048194895 },
    // Bytes, not codepoints: `sizeof(s)` is the UTF-8 length.
    .{ .s = "é", .h0 = 17670732648015665040, .h1 = 14046251891873846984, .hmax = 13032997712351421986 },
    .{ .s = "你好世界", .h0 = 1881456236142447942, .h1 = 5093241274720000040, .hmax = 12987542247474785300 },
    .{ .s = "a b", .h0 = 15697591309375675424, .h1 = 17799433313311481323, .hmax = 3151663677965684933 },
    // The shapes `add_repo_cache_path` is handed.
    .{ .s = "https://github.com/JuliaLang/Example.jl.git", .h0 = 4643033083726148914, .h1 = 3363645993123607313, .hmax = 9268072145729183423 },
    .{ .s = "https://github.com/JuliaLang/Example.jl", .h0 = 15037770950778237535, .h1 = 8719611264940874194, .hmax = 14059647031249556892 },
    .{ .s = "git@github.com:JuliaLang/Example.jl.git", .h0 = 6754066352740396075, .h1 = 15969904827304839471, .hmax = 4465239647032594021 },
    .{ .s = "https://github.com/MakieOrg/Makie.jl.git", .h0 = 553969327920365557, .h1 = 11935787324150150994, .hmax = 16852603605501658878 },
};

test "hash agrees with Base.hash(::String, ::UInt) on captured fixtures" {
    for (cases) |c| {
        try testing.expectEqual(c.h0, hashString(c.s));
        try testing.expectEqual(c.h0, hash(c.s, 0));
        try testing.expectEqual(c.h1, hash(c.s, 1));
        try testing.expectEqual(c.hmax, hash(c.s, std.math.maxInt(u64)));
    }
}

test "long inputs exercise the body loop" {
    // repeat("x", 128) — eight whole blocks, no tail.
    const xs = "x" ** 128;
    try testing.expectEqual(@as(u64, 17343101463144295148), hashString(xs));
    // repeat("Pkg", 100) — 300 bytes: 18 blocks and a 12-byte tail.
    const pkgs = "Pkg" ** 100;
    try testing.expectEqual(@as(u64, 8713093183007798212), hashString(pkgs));
}

test "memhash_seed returns the SECOND murmur word" {
    // The landmark for the out[0]/out[1] trap. out[0] for the empty string
    // under the derived seed is 15888878324965942306; taking it would make
    // every clone directory name wrong and nothing would fail loudly.
    const h = seed; // 0 +% seed
    const both = murmur3X64_128("", @truncate(h));
    try testing.expectEqual(@as(u64, 15888878324965942306), both[0] +% h);
    try testing.expectEqual(@as(u64, 13633231208144796923), both[1] +% h);
}

test "decimal renders the clone directory name" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings(
        "4643033083726148914",
        decimal(hashString("https://github.com/JuliaLang/Example.jl.git"), &buf),
    );
    // The buffer is exactly wide enough for the largest UInt64.
    try testing.expectEqualStrings("18446744073709551615", decimal(std.math.maxInt(u64), &buf));
}

test "hashing is over bytes, so a NUL is content like any other" {
    // Julia strings may contain NUL and `sizeof` counts it; a C-string port
    // that stopped at the first NUL would agree on every fixture above and
    // disagree here.
    try testing.expect(hashString("a\x00b") != hashString("a"));
    try testing.expectEqual(@as(usize, 3), "a\x00b".len);
}
