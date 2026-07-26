//! Platform matching and artifact selection.
//!
//! Port of the parts of `base/binaryplatforms.jl` that artifact installation
//! needs: `platforms_match` (:1020-1051), `select_platform` (:1079-1110),
//! `triplet` (:514-544), and the `compare_version_cap` strategy (:300-317).
//!
//! A `Platform` here is just an ordered set of string tags. That is exactly
//! what Julia's is, and it matters: `unpack_platform`
//! (`Artifacts/src/Artifacts.jl:280-304`) builds one from an `Artifacts.toml`
//! entry by taking **every String-valued key** as a tag and then deleting
//! `os`, `arch` and `git-tree-sha1` before re-adding os/arch positionally. So
//! artifact platforms carry arbitrary extra tags, and matching has to cope.
//!
//! Two rules carry all the subtlety:
//!
//!  1. **A key present on only one side is SKIPPED, not a mismatch**
//!     (:1026-1028). An artifact built without a `libc` tag matches a host
//!     that has one. Treating absence as inequality rejects almost every real
//!     artifact.
//!  2. **`os_version` and `libstdcxx_version` are UPPER BOUNDS on the host
//!     side.** `HostPlatform(p)` (:330-338) attaches `compare_version_cap` to
//!     those two keys, and only to a host. So an artifact built against
//!     libstdcxx 3.4.26 runs on a host capping at 3.4.30, but not the reverse.
//!     When *both* sides declare the cap strategy it degrades to equality
//!     (:305-307).

const std = @import("std");
const Allocator = std.mem.Allocator;
const version_mod = @import("version.zig");

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

pub const Platform = struct {
    tags: []const Tag,
    /// True for the machine we are selecting FOR. Only a host treats
    /// `os_version`/`libstdcxx_version` as caps rather than exact values.
    is_host: bool = false,

    pub fn get(self: Platform, key: []const u8) ?[]const u8 {
        for (self.tags) |t| {
            if (std.mem.eql(u8, t.key, key)) return t.value;
        }
        return null;
    }

    pub fn has(self: Platform, key: []const u8) bool {
        return self.get(key) != null;
    }
};

fn isCapKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "os_version") or std.mem.eql(u8, key, "libstdcxx_version");
}

/// Parses the loose version strings these tags carry (`3.4.26`, `10.11`, `14`).
fn parseVer(s: []const u8) ?version_mod.Version {
    var v: version_mod.Version = .{};
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        const x = std.fmt.parseInt(u64, part, 10) catch return null;
        switch (n) {
            0 => v.major = x,
            1 => v.minor = x,
            2 => v.patch = x,
            else => return null,
        }
    }
    if (n == 0) return null;
    return v;
}

/// `platforms_match` (binaryplatforms.jl:1020-1051).
pub fn platformsMatch(a: Platform, b: Platform) bool {
    // Julia iterates the UNION of both key sets, but a key present on only one
    // side hits the `ak === nothing` skip (:1026-1028) and contributes nothing.
    // So iterating a's keys alone is equivalent, and avoids a second pass.
    for (a.tags) |ta| {
        const bv = b.get(ta.key) orelse continue; // rule 1: absent => skip
        if (!compareTag(ta.key, ta.value, bv, a.is_host, b.is_host)) return false;
    }
    return true;
}

fn compareTag(
    key: []const u8,
    av: []const u8,
    bv: []const u8,
    a_is_host: bool,
    b_is_host: bool,
) bool {
    const a_cap = a_is_host and isCapKey(key);
    const b_cap = b_is_host and isCapKey(key);
    if (!a_cap and !b_cap) return std.mem.eql(u8, av, bv);

    const a_ver = parseVer(av) orelse return std.mem.eql(u8, av, bv);
    const b_ver = parseVer(bv) orelse return std.mem.eql(u8, av, bv);

    // Both sides claim the cap strategy -> equality (:305-307).
    if (a_cap and b_cap) return a_ver.eql(b_ver);
    // The capped side is the upper bound.
    if (a_cap) return b_ver.order(a_ver) != .gt;
    return a_ver.order(b_ver) != .gt;
}

/// `triplet(p)` (:514-544). Needed because `select_platform` breaks ties by
/// reverse triplet order, which is how a `libgfortran5` build wins over
/// `libgfortran3`.
pub fn triplet(gpa: Allocator, p: Platform) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    const arch = p.get("arch") orelse "unknown";
    w.writeAll(arch) catch return error.OutOfMemory;

    const os = p.get("os") orelse "unknown";
    if (std.mem.eql(u8, os, "linux")) {
        w.writeAll("-linux") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, os, "macos")) {
        if (p.get("os_version")) |osv| {
            const v = parseVer(osv);
            if (v) |vv| {
                w.print("-apple-darwin{d}", .{vv.major}) catch return error.OutOfMemory;
            } else w.writeAll("-apple-darwin") catch return error.OutOfMemory;
        } else w.writeAll("-apple-darwin") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, os, "windows")) {
        w.writeAll("-w64-mingw32") catch return error.OutOfMemory;
    } else {
        w.print("-{s}", .{os}) catch return error.OutOfMemory;
    }

    if (p.get("libc")) |lc| {
        if (std.mem.eql(u8, lc, "glibc")) {
            w.writeAll("-gnu") catch return error.OutOfMemory;
        } else {
            w.print("-{s}", .{lc}) catch return error.OutOfMemory;
        }
    }
    if (p.get("call_abi")) |ca| w.writeAll(ca) catch return error.OutOfMemory;

    if (p.get("libgfortran_version")) |lg| {
        if (parseVer(lg)) |v| w.print("-libgfortran{d}", .{v.major}) catch return error.OutOfMemory;
    }
    if (p.get("cxxstring_abi")) |cx| w.print("-{s}", .{cx}) catch return error.OutOfMemory;
    if (p.get("libstdcxx_version")) |ls| {
        // Note: the PATCH component, not the major (:533).
        if (parseVer(ls)) |v| w.print("-libstdcxx{d}", .{v.patch}) catch return error.OutOfMemory;
    }

    // Any remaining tag is rendered as `-key+value` (:536-542).
    for (p.tags) |t| {
        if (isStructuralKey(t.key)) continue;
        w.print("-{s}+{s}", .{ t.key, t.value }) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

fn isStructuralKey(k: []const u8) bool {
    const structural = [_][]const u8{
        "os",              "arch",              "libc",       "call_abi",
        "libgfortran_version", "libstdcxx_version", "cxxstring_abi", "os_version",
    };
    for (structural) |s| {
        if (std.mem.eql(u8, k, s)) return true;
    }
    return false;
}

/// `match_loss` (:1090-1094): how far apart two tag key SETS are.
fn matchLoss(a: Platform, b: Platform) usize {
    var inter: usize = 0;
    for (a.tags) |ta| {
        if (b.has(ta.key)) inter += 1;
    }
    const uni = a.tags.len + b.tags.len - inter;
    return uni - inter;
}

/// `select_platform` (:1079-1110): among the candidates that match `host`,
/// prefer the closest tag-set match, then the highest triplet.
///
/// Returns an index into `candidates`, or null when nothing matches.
pub fn selectPlatform(gpa: Allocator, candidates: []const Platform, host: Platform) Allocator.Error!?usize {
    var best: ?usize = null;
    var best_loss: usize = 0;
    var best_triplet: []u8 = &.{};
    defer if (best_triplet.len != 0) gpa.free(best_triplet);

    for (candidates, 0..) |c, i| {
        if (!platformsMatch(c, host)) continue;
        const loss = matchLoss(c, host);
        const trip = try triplet(gpa, c);

        if (best == null or loss < best_loss or
            (loss == best_loss and std.mem.order(u8, trip, best_triplet) == .gt))
        {
            if (best_triplet.len != 0) gpa.free(best_triplet);
            best = i;
            best_loss = loss;
            best_triplet = trip;
        } else {
            gpa.free(trip);
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Host detection
// ---------------------------------------------------------------------------

/// The host platform Julia would report, i.e. `host_triplet()` as tags.
///
/// Julia derives this by introspecting ITS OWN process: `detect_libstdcxx_version`
/// and friends filter `Libdl.dllist()` (:853-903). Ajt links neither libstdc++
/// nor libgfortran, so self-inspection would give the wrong answer — it has to
/// inspect the *target Julia installation* instead. Three sources:
///
///   1. `<prefix>/share/julia/base/build_h.jl` -> `BUILD_TRIPLET`, which
///      carries arch/os/libc/libgfortran/cxxstring_abi. It is a plain text
///      constant, so no Julia process is needed to read it.
///   2. `<prefix>/lib/julia/libstdc++.so.6` -> the highest `GLIBCXX_3.4.N`
///      version string, **capped at N = 30**. The cap is not cosmetic: Julia
///      counts down from `max_minor_version = 30` (:895) and returns the first
///      hit, so a library exporting 3.4.33 still reports 3.4.30. Verified on a
///      real install whose libstdc++ exports up to 3.4.33.
///   3. The Julia version, appended as a `julia_version` tag.
///
/// Reading the ELF's version strings rather than `dlopen`+`dlsym` keeps this a
/// pure file read and avoids loading a foreign libstdc++ into our address space.
pub const HostOptions = struct {
    /// Directory containing `share/julia` and `lib/julia`.
    julia_prefix: []const u8,
    /// e.g. "1.12.6".
    julia_version: []const u8,
    /// Julia's own default (`detect_libstdcxx_version`).
    max_libstdcxx_minor: u32 = 30,
};

pub const DetectError = error{BuildTripletNotFound} || Allocator.Error;

/// All allocations have the returned Platform's lifetime and are never freed
/// individually, so `arena` must be an arena-like allocator that the caller
/// drops wholesale. Passing a general-purpose allocator here leaks by design.
pub fn detectHost(arena: Allocator, io: std.Io, opts: HostOptions) DetectError!Platform {
    const gpa = arena;
    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(gpa);

    var path_buf: [1024]u8 = undefined;

    // 1. BUILD_TRIPLET
    const build_h = std.fmt.bufPrint(&path_buf, "{s}/share/julia/base/build_h.jl", .{opts.julia_prefix}) catch
        return error.BuildTripletNotFound;
    const src = std.Io.Dir.cwd().readFileAlloc(io, build_h, gpa, .limited(4 * 1024 * 1024)) catch
        return error.BuildTripletNotFound;
    defer gpa.free(src);

    const marker = "const BUILD_TRIPLET = \"";
    const at = std.mem.indexOf(u8, src, marker) orelse return error.BuildTripletNotFound;
    const rest = src[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.BuildTripletNotFound;
    const build_triplet = rest[0..end];

    try parseBuildTriplet(gpa, build_triplet, &tags);

    // 2. libstdc++
    const libpath = std.fmt.bufPrint(&path_buf, "{s}/lib/julia/libstdc++.so.6", .{opts.julia_prefix}) catch null;
    if (libpath) |lp| {
        if (std.Io.Dir.cwd().readFileAlloc(io, lp, gpa, .limited(256 * 1024 * 1024))) |so| {
            defer gpa.free(so);
            if (highestGlibcxx(so, opts.max_libstdcxx_minor)) |minor| {
                const v = try std.fmt.allocPrint(gpa, "3.4.{d}", .{minor});
                try tags.append(gpa, .{ .key = "libstdcxx_version", .value = v });
            }
        } else |_| {}
    }

    // 3. julia_version
    try tags.append(gpa, .{ .key = "julia_version", .value = try gpa.dupe(u8, opts.julia_version) });

    return .{ .tags = try tags.toOwnedSlice(gpa), .is_host = true };
}

/// Highest N in `GLIBCXX_3.4.N` present in `bytes`, capped at `max_minor`.
fn highestGlibcxx(bytes: []const u8, max_minor: u32) ?u32 {
    const needle = "GLIBCXX_3.4.";
    var best: ?u32 = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, needle)) |at| {
        i = at + needle.len;
        var j = i;
        while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') j += 1;
        if (j > i) {
            if (std.fmt.parseInt(u32, bytes[i..j], 10)) |n| {
                if (n <= max_minor and (best == null or n > best.?)) best = n;
            } else |_| {}
        }
    }
    return best;
}

/// Parses the canonical `BUILD_TRIPLET` shape into tags.
///
/// This handles the machine-generated forms Julia actually ships
/// (`x86_64-linux-gnu-libgfortran5-cxx11`, `aarch64-apple-darwin20`,
/// `x86_64-w64-mingw32-libgfortran5-cxx11`, ...) rather than reimplementing
/// Julia's full `parse(Platform, ::String)` regex, which also accepts hand
/// written triplets Ajt never has to read here.
fn parseBuildTriplet(gpa: Allocator, triplet_str: []const u8, tags: *std.ArrayList(Tag)) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, triplet_str, '-');
    const arch = it.next() orelse return;
    try tags.append(gpa, .{ .key = "arch", .value = try gpa.dupe(u8, arch) });

    var os_set = false;
    var libc: ?[]const u8 = null;
    while (it.next()) |part| {
        if (!os_set) {
            if (std.mem.eql(u8, part, "linux")) {
                try tags.append(gpa, .{ .key = "os", .value = "linux" });
                os_set = true;
                continue;
            }
            if (std.mem.eql(u8, part, "apple")) continue; // next part is darwinNN
            if (std.mem.startsWith(u8, part, "darwin")) {
                try tags.append(gpa, .{ .key = "os", .value = "macos" });
                os_set = true;
                continue;
            }
            if (std.mem.eql(u8, part, "w64")) continue; // next part is mingw32
            if (std.mem.eql(u8, part, "mingw32")) {
                try tags.append(gpa, .{ .key = "os", .value = "windows" });
                os_set = true;
                continue;
            }
            if (std.mem.startsWith(u8, part, "freebsd")) {
                try tags.append(gpa, .{ .key = "os", .value = "freebsd" });
                os_set = true;
                continue;
            }
            if (std.mem.startsWith(u8, part, "openbsd")) {
                try tags.append(gpa, .{ .key = "os", .value = "openbsd" });
                os_set = true;
                continue;
            }
            continue; // vendor field, e.g. `unknown`
        }

        if (std.mem.eql(u8, part, "gnu")) {
            libc = "glibc";
        } else if (std.mem.eql(u8, part, "musl")) {
            libc = "musl";
        } else if (std.mem.startsWith(u8, part, "libgfortran")) {
            const n = part["libgfortran".len..];
            const v = try std.fmt.allocPrint(gpa, "{s}.0.0", .{n});
            try tags.append(gpa, .{ .key = "libgfortran_version", .value = v });
        } else if (std.mem.startsWith(u8, part, "cxx")) {
            try tags.append(gpa, .{ .key = "cxxstring_abi", .value = try gpa.dupe(u8, part) });
        }
    }
    if (libc) |lc| try tags.append(gpa, .{ .key = "libc", .value = lc });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn plat(tags: []const Tag) Platform {
    return .{ .tags = tags };
}
fn hostPlat(tags: []const Tag) Platform {
    return .{ .tags = tags, .is_host = true };
}

test "a key present on only one side is skipped, not a mismatch" {
    const artifact = plat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "arch", .value = "x86_64" },
    });
    const host = hostPlat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "libc", .value = "glibc" },
        .{ .key = "cxxstring_abi", .value = "cxx11" },
    });
    try testing.expect(platformsMatch(artifact, host));
}

test "a differing shared key is a mismatch" {
    const a = plat(&.{ .{ .key = "os", .value = "linux" }, .{ .key = "arch", .value = "x86_64" } });
    const b = hostPlat(&.{ .{ .key = "os", .value = "linux" }, .{ .key = "arch", .value = "aarch64" } });
    try testing.expect(!platformsMatch(a, b));
}

test "libstdcxx_version is an upper bound on the host side" {
    const host = hostPlat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "libstdcxx_version", .value = "3.4.30" },
    });
    const older = plat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "libstdcxx_version", .value = "3.4.26" },
    });
    const newer = plat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "libstdcxx_version", .value = "3.4.33" },
    });
    // An artifact needing an OLDER libstdcxx runs on a newer host.
    try testing.expect(platformsMatch(older, host));
    // One needing a NEWER libstdcxx does not.
    try testing.expect(!platformsMatch(newer, host));

    // Two hosts both claiming the cap degrade to equality (:305-307).
    const host2 = hostPlat(&.{
        .{ .key = "os", .value = "linux" },
        .{ .key = "libstdcxx_version", .value = "3.4.26" },
    });
    try testing.expect(!platformsMatch(host, host2));
}

test "a non-cap key is compared exactly even when it looks like a version" {
    const host = hostPlat(&.{.{ .key = "libgfortran_version", .value = "5.0.0" }});
    const art = plat(&.{.{ .key = "libgfortran_version", .value = "4.0.0" }});
    try testing.expect(!platformsMatch(art, host));
}

test "triplet rendering" {
    const gpa = testing.allocator;
    const cases = [_]struct { p: Platform, want: []const u8 }{
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "x86_64" },
            .{ .key = "os", .value = "linux" },
            .{ .key = "libc", .value = "glibc" },
        }), .want = "x86_64-linux-gnu" },
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "x86_64" },
            .{ .key = "os", .value = "linux" },
            .{ .key = "libc", .value = "musl" },
            .{ .key = "libgfortran_version", .value = "5.0.0" },
            .{ .key = "cxxstring_abi", .value = "cxx11" },
        }), .want = "x86_64-linux-musl-libgfortran5-cxx11" },
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "aarch64" },
            .{ .key = "os", .value = "macos" },
        }), .want = "aarch64-apple-darwin" },
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "x86_64" },
            .{ .key = "os", .value = "windows" },
        }), .want = "x86_64-w64-mingw32" },
        // libstdcxx uses the PATCH component.
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "x86_64" },
            .{ .key = "os", .value = "linux" },
            .{ .key = "libc", .value = "glibc" },
            .{ .key = "libstdcxx_version", .value = "3.4.26" },
        }), .want = "x86_64-linux-gnu-libstdcxx26" },
        // Unknown tags become -key+value.
        .{ .p = plat(&.{
            .{ .key = "arch", .value = "x86_64" },
            .{ .key = "os", .value = "linux" },
            .{ .key = "libc", .value = "glibc" },
            .{ .key = "julia_version", .value = "1.12.6" },
        }), .want = "x86_64-linux-gnu-julia_version+1.12.6" },
    };
    for (cases) |c| {
        const got = try triplet(gpa, c.p);
        defer gpa.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "select_platform prefers the closest tag set, then the highest triplet" {
    const gpa = testing.allocator;
    const host = hostPlat(&.{
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "os", .value = "linux" },
        .{ .key = "libc", .value = "glibc" },
        .{ .key = "libgfortran_version", .value = "5.0.0" },
    });

    // Same tag sets; libgfortran5 must beat libgfortran3 via the triplet
    // tiebreak. (Both match because the host declares libgfortran 5.)
    const c0 = plat(&.{
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "os", .value = "linux" },
        .{ .key = "libc", .value = "glibc" },
    });
    const c1 = plat(&.{
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "os", .value = "linux" },
        .{ .key = "libc", .value = "glibc" },
        .{ .key = "libgfortran_version", .value = "5.0.0" },
    });
    // A non-matching candidate must never be chosen.
    const c2 = plat(&.{
        .{ .key = "arch", .value = "aarch64" },
        .{ .key = "os", .value = "linux" },
    });

    const pick = (try selectPlatform(gpa, &.{ c0, c1, c2 }, host)).?;
    // c1 shares all four keys with the host -> loss 0; c0 -> loss 1.
    try testing.expectEqual(@as(usize, 1), pick);

    // Nothing matches -> null.
    const none = try selectPlatform(gpa, &.{c2}, host);
    try testing.expect(none == null);
}

test "GLIBCXX scan takes the highest version at or below the cap" {
    // Julia counts DOWN from max_minor_version=30 and returns the first hit,
    // so a library exporting 3.4.33 still reports 3.4.30. Real installs do
    // ship such libraries.
    const blob = "junk GLIBCXX_3.4.29 more GLIBCXX_3.4.33 GLIBCXX_3.4.30 tail GLIBCXX_3.4.21";
    try testing.expectEqual(@as(?u32, 30), highestGlibcxx(blob, 30));
    try testing.expectEqual(@as(?u32, 33), highestGlibcxx(blob, 40));
    try testing.expectEqual(@as(?u32, 21), highestGlibcxx(blob, 21));
    try testing.expectEqual(@as(?u32, null), highestGlibcxx("nothing here", 30));
}

test "BUILD_TRIPLET parses into the tags Julia reports" {
    const gpa = testing.allocator;
    var tags: std.ArrayList(Tag) = .empty;
    defer {
        for (tags.items) |t| {
            // Only heap-allocated values need freeing; the static ones don't.
            if (std.mem.eql(u8, t.key, "arch") or
                std.mem.eql(u8, t.key, "libgfortran_version") or
                std.mem.eql(u8, t.key, "cxxstring_abi")) gpa.free(@constCast(t.value));
        }
        tags.deinit(gpa);
    }
    try parseBuildTriplet(gpa, "x86_64-linux-gnu-libgfortran5-cxx11", &tags);
    const p: Platform = .{ .tags = tags.items };
    try testing.expectEqualStrings("x86_64", p.get("arch").?);
    try testing.expectEqualStrings("linux", p.get("os").?);
    try testing.expectEqualStrings("glibc", p.get("libc").?);
    try testing.expectEqualStrings("5.0.0", p.get("libgfortran_version").?);
    try testing.expectEqualStrings("cxx11", p.get("cxxstring_abi").?);
}

test "BUILD_TRIPLET: macos and windows shapes" {
    const gpa = testing.allocator;
    inline for (.{
        .{ "aarch64-apple-darwin20", "aarch64", "macos" },
        .{ "x86_64-w64-mingw32-libgfortran5-cxx11", "x86_64", "windows" },
        .{ "x86_64-linux-musl-libgfortran5-cxx11", "x86_64", "linux" },
    }) |c| {
        var tags: std.ArrayList(Tag) = .empty;
        defer {
            for (tags.items) |t| {
                if (std.mem.eql(u8, t.key, "arch") or
                    std.mem.eql(u8, t.key, "libgfortran_version") or
                    std.mem.eql(u8, t.key, "cxxstring_abi")) gpa.free(@constCast(t.value));
            }
            tags.deinit(gpa);
        }
        try parseBuildTriplet(gpa, c[0], &tags);
        const p: Platform = .{ .tags = tags.items };
        try testing.expectEqualStrings(c[1], p.get("arch").?);
        try testing.expectEqualStrings(c[2], p.get("os").?);
    }
    // musl must not be mistaken for glibc.
    var tags: std.ArrayList(Tag) = .empty;
    defer {
        for (tags.items) |t| {
            if (std.mem.eql(u8, t.key, "arch") or
                std.mem.eql(u8, t.key, "libgfortran_version") or
                std.mem.eql(u8, t.key, "cxxstring_abi")) gpa.free(@constCast(t.value));
        }
        tags.deinit(gpa);
    }
    try parseBuildTriplet(gpa, "x86_64-linux-musl-libgfortran5-cxx11", &tags);
    const p: Platform = .{ .tags = tags.items };
    try testing.expectEqualStrings("musl", p.get("libc").?);
}
