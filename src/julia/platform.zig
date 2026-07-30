//! Platform construction, matching and artifact selection.
//!
//! Port of the parts of `base/binaryplatforms.jl` that artifact installation
//! needs: the `Platform` **constructor** (:44-107), `platforms_match`
//! (:1020-1051), `select_platform` (:1079-1110), `triplet` (:514-544), and the
//! `compare_version_cap` strategy (:300-317).
//!
//! A `Platform` here is just an ordered set of string tags. That is exactly
//! what Julia's is, and it matters: `unpack_platform`
//! (`Artifacts/src/Artifacts.jl:280-304`) builds one from an `Artifacts.toml`
//! entry by taking **every String-valued key** as a tag and then deleting
//! `os`, `arch` and `git-tree-sha1` before re-adding os/arch positionally. So
//! artifact platforms carry arbitrary extra tags, and matching has to cope.
//!
//! **Every `Platform` must be built by `construct`** (or `constructHost`).
//! Julia has no other way to make one, and the constructor is not a formality:
//! it rewrites tags in ways that change which artifact wins (see `construct`'s
//! doc comment). A hand-assembled tag list is a platform Julia would never
//! produce, and it diverges silently — the failure surfaces as the wrong
//! tarball installed, not as an error. The only tag lists built by hand are in
//! this file's own tests, where bypassing the rule IS the thing under test.
//!
//! Three rules carry all the subtlety:
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
//!  3. **`julia_version` compares MAJOR AND MINOR ONLY** (:101-105). That
//!     strategy is attached by the constructor, to any platform carrying the
//!     tag, host or not — so whenever the key is compared at all both sides
//!     have it and both request the strategy. Verified against Julia: an
//!     artifact tagged `1.12.0` matches a host on `1.12.6`, and `1.11.0` does
//!     not.

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
        return if (findTag(self.tags, key)) |i| self.tags[i].value else null;
    }

    pub fn has(self: Platform, key: []const u8) bool {
        return self.get(key) != null;
    }
};

// ---------------------------------------------------------------------------
// The Platform constructor (binaryplatforms.jl:44-107)
// ---------------------------------------------------------------------------

pub const ConstructError = error{
    /// `add_tag!` rejects the key or the value (`binaryplatforms.jl:126-142`).
    /// Julia throws `ArgumentError`.
    InvalidTagCharacter,
    /// A tag whose key lowercases to `arch`/`os` (`:57-60`). Julia throws
    /// `ArgumentError("Cannot double-pass key ...")`.
    DoublePassedKey,
} || Allocator.Error;

/// `Platform(arch, os, tags)` (`binaryplatforms.jl:44-107`).
///
/// This lives here, with the type, because the normalisation it performs is
/// **observable in artifact selection** and must not be reinvented by callers:
///
///   * a linux platform with no `libc` GAINS `libc = glibc` (:87-90);
///   * a 32-bit-ARM linux platform with no `call_abi` GAINS
///     `call_abi = eabihf` (:91-94);
///   * `arch` is alias-folded by `CPUID.normalize_arch` (`base/cpuid.jl:81-97`)
///     and `os`, every tag key and every tag value are lowercased;
///   * `libgfortran_version`/`libstdcxx_version`/`os_version` are rounded
///     through `VersionNumber`, so `"10.11"` becomes `"10.11.0"` (:68-77).
///
/// The gained tags are the sharp edge. `match_loss` (:1090-1094) counts the
/// symmetric difference of the two tag KEY SETS, so a tag that appears out of
/// nowhere changes the ranking and therefore which variant is installed. Six
/// entries in the 83-file depot corpus gain a `call_abi` this way, and the
/// `auto_libc`/`auto_call_abi` fixtures in `artifacts_model.sh` pin the flip in
/// both directions.
///
/// `extra` is the raw tag list in source order, keys and values exactly as
/// written; `construct` owns all the folding. Julia's `tags` is a `Dict`, so a
/// later tag REPLACES an earlier one that lowercases to the same key rather
/// than adding a second entry — that is what keeps `match_loss` counting
/// distinct keys. (Which of two case-variant spellings wins is Julia hash
/// order, i.e. arbitrary; only the resulting tag COUNT is well defined, and
/// that is the part selection reads. Verified by running Julia: both insertion
/// orders of `"Libc"`/`"libc"` yield 3 tags.)
///
/// Arena-lifetime: rewritten strings are allocated from `arena`; strings that
/// need no rewriting are borrowed from `extra`.
pub fn construct(
    arena: Allocator,
    raw_arch: []const u8,
    raw_os: []const u8,
    extra: []const Tag,
) ConstructError!Platform {
    const os = try lower(arena, raw_os);
    const arch = try normalizeArch(arena, raw_arch);

    var tags: std.ArrayList(Tag) = .empty;
    // arch/os are written straight into the tag dict (:51-54), NOT through
    // `add_tag!`, so they skip the forbidden-character check entirely.
    try tags.append(arena, .{ .key = "arch", .value = arch });
    try tags.append(arena, .{ .key = "os", .value = os });

    for (extra) |raw| {
        const key = try lower(arena, raw.key);
        if (std.mem.eql(u8, key, "os") or std.mem.eql(u8, key, "arch")) {
            return error.DoublePassedKey;
        }
        // Version rounding happens BEFORE `add_tag!` (:68-81), which is why a
        // value that only rounds into a forbidden character still throws.
        const versioned = if (isVersionTag(key)) try versionText(arena, raw.value, .full) else raw.value;
        const value = try lower(arena, versioned);
        if (hasForbiddenChar(key) or hasForbiddenChar(value)) return error.InvalidTagCharacter;
        try setTag(arena, &tags, key, value);
    }

    // Auto-mapped defaults (:84-94).
    if (std.mem.eql(u8, os, "linux")) {
        if (findTag(tags.items, "libc") == null) {
            try tags.append(arena, .{ .key = "libc", .value = "glibc" });
        }
        if ((std.mem.eql(u8, arch, "armv7l") or std.mem.eql(u8, arch, "armv6l")) and
            findTag(tags.items, "call_abi") == null)
        {
            try tags.append(arena, .{ .key = "call_abi", .value = "eabihf" });
        }
    }

    return .{ .tags = try tags.toOwnedSlice(arena), .is_host = false };
}

/// `HostPlatform(Platform(arch, os, tags))`: `construct` plus the one thing
/// `HostPlatform(p)` does, which is to make `os_version`/`libstdcxx_version`
/// compare as caps (:330-338).
///
/// Exists so no caller has to remember the second step. Forgetting it fails
/// SILENTLY -- the cap comparisons quietly degrade to equality and artifacts
/// built against an older libstdcxx stop matching.
pub fn constructHost(
    arena: Allocator,
    raw_arch: []const u8,
    raw_os: []const u8,
    extra: []const Tag,
) ConstructError!Platform {
    var p = try construct(arena, raw_arch, raw_os, extra);
    p.is_host = true;
    return p;
}

/// `Dict` assignment: replace in place, or append. Replacing in place rather
/// than moving the key to the end keeps `triplet`'s trailing `-key+value` run
/// in source order, which is the only order any caller can rely on (Julia's is
/// hash order).
fn setTag(arena: Allocator, tags: *std.ArrayList(Tag), key: []const u8, value: []const u8) Allocator.Error!void {
    if (findTag(tags.items, key)) |i| {
        tags.items[i].value = value;
        return;
    }
    try tags.append(arena, .{ .key = key, .value = value });
}

fn findTag(tags: []const Tag, key: []const u8) ?usize {
    for (tags, 0..) |t, i| {
        if (std.mem.eql(u8, t.key, key)) return i;
    }
    return null;
}

fn isVersionTag(key: []const u8) bool {
    return std.mem.eql(u8, key, "libgfortran_version") or
        std.mem.eql(u8, key, "libstdcxx_version") or
        std.mem.eql(u8, key, "os_version");
}

/// `add_tag!`'s rejected set (`binaryplatforms.jl:126`): `+- /<>:"'\|?*`.
fn hasForbiddenChar(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "+- /<>:\"'\\|?*") != null;
}

/// Borrows `s` when it is already lowercase. That is the common case (every
/// BinaryBuilder-emitted tag), and it keeps the arena free of copies of strings
/// the TOML document already owns.
fn lower(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(arena, s);
    }
    return s;
}

/// `CPUID.normalize_arch` (`base/cpuid.jl:81-97`). Every alias below was read
/// back out of a real `Platform` built by Julia 1.12.6.
fn normalizeArch(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const a = try lower(arena, raw);
    const aliases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "amd64", .to = "x86_64" },
        .{ .from = "i386", .to = "i686" },
        .{ .from = "i486", .to = "i686" },
        .{ .from = "i586", .to = "i686" },
        .{ .from = "armv6", .to = "armv6l" },
        .{ .from = "arm", .to = "armv7l" },
        .{ .from = "armv7", .to = "armv7l" },
        .{ .from = "armv8", .to = "armv7l" },
        .{ .from = "armv8l", .to = "armv7l" },
        .{ .from = "arm64", .to = "aarch64" },
        .{ .from = "ppc64le", .to = "powerpc64le" },
    };
    for (aliases) |al| {
        if (std.mem.eql(u8, a, al.from)) return al.to;
    }
    return a;
}

/// How `versionText` renders a parsed version.
const VersionForm = enum {
    /// `string(v)` -- what the constructor stores for a version tag.
    full,
    /// `string(VersionNumber(v.major, v.minor, v.patch))` -- drops prerelease
    /// and build metadata, which is what `host_triplet()` does to `VERSION`
    /// before appending it as a `julia_version` tag (:982-983).
    release_only,
};

/// `tryparse(VersionNumber, v)` then `string(v)` (`:70-77`). A value that does
/// not parse is passed through UNCHANGED -- Julia deliberately tolerates it
/// ("in our effort to be extremely compatible"), and for `release_only` that
/// keeps a caller-supplied oddity visible instead of collapsing it to `0.0.0`.
///
/// `version.zig`'s parser is not byte-for-byte Julia's `VERSION_REGEX`
/// (`version.jl:111-121`): it does not enforce the `[0-9a-z-]` identifier
/// charset, and it requires an explicit `-` before a prerelease. Only the
/// second gap is observable, and only on a hand-written tag:
///
///   * `"1.2.3-01.alpha_beta"` -- Julia rejects the parse and leaves the value
///     alone, we canonicalise it to `"1.2.3-1.alpha_beta"`. Both then hit the
///     forbidden `-` in `add_tag!`, so BOTH reject the entry. Not observable.
///   * `"10.11rc1"` -- Julia parses it to `"10.11.0-rc1"`, which then throws in
///     `add_tag!` on the `-`; we leave it alone and accept the tag. **This one
///     is a real divergence** (verified by running Julia 1.12.6), reachable
///     only from a hand-written `Artifacts.toml`. Every BinaryBuilder-emitted
///     `os_version`/`libstdcxx_version`/`libgfortran_version` is plain dotted
///     decimal, which the two engines agree on exactly.
fn versionText(arena: Allocator, s: []const u8, form: VersionForm) Allocator.Error![]const u8 {
    const v = version_mod.parse(arena, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidVersion => return s,
    };
    return switch (form) {
        .full => std.fmt.allocPrint(arena, "{f}", .{v}),
        .release_only => std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }),
    };
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

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
    // `julia_version` compares major/minor only (:101-105). The constructor
    // attaches that strategy to ANY platform carrying the tag, and
    // `platforms_match` only reaches a key both sides have -- so by the time we
    // are here both sides requested it and host-ness is irrelevant. Julia would
    // throw on an unparseable value (`VersionNumber(a)`); we fall back to
    // string equality rather than failing a whole file over one tag.
    if (std.mem.eql(u8, key, "julia_version")) {
        const a_jv = parseVer(av) orelse return std.mem.eql(u8, av, bv);
        const b_jv = parseVer(bv) orelse return std.mem.eql(u8, av, bv);
        return a_jv.major == b_jv.major and a_jv.minor == b_jv.minor;
    }

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
///   3. The Julia version, appended as a `julia_version` tag -- **truncated to
///      `major.minor.patch`**, because `host_triplet()` appends
///      `VersionNumber(VERSION.major, VERSION.minor, VERSION.patch)` (:982-983)
///      rather than `VERSION` itself. On a release that is a no-op; on a
///      nightly (`1.13.0-DEV.1234`) it is the difference between a working host
///      and an `ArgumentError`, since `add_tag!` rejects the `-`.
///
/// Reading the ELF's version strings rather than `dlopen`+`dlsym` keeps this a
/// pure file read and avoids loading a foreign libstdc++ into our address space.
///
/// The collected tags then go through `construct`, exactly as Julia's
/// `HostPlatform()` runs `parse(Platform, host_triplet())` (:996-998) -- so the
/// host is normalised by the same rule as every artifact platform, and only
/// then marked `is_host` (which is all `HostPlatform(p)` does, :330-338).
pub const HostOptions = struct {
    /// Directory containing `share/julia` and `lib/julia`.
    julia_prefix: []const u8,
    /// e.g. "1.12.6".
    julia_version: []const u8,
    /// Julia's own default (`detect_libstdcxx_version`).
    max_libstdcxx_minor: u32 = 30,
};

pub const DetectError = error{BuildTripletNotFound} || ConstructError;

/// All allocations have the returned Platform's lifetime and are never freed
/// individually, so `arena` must be an arena-like allocator that the caller
/// drops wholesale. Passing a general-purpose allocator here leaks by design.
pub fn detectHost(arena: Allocator, io: std.Io, opts: HostOptions) DetectError!Platform {
    const gpa = arena;
    // Everything but arch/os: `construct` takes those positionally.
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

    const target = try parseBuildTriplet(gpa, build_triplet, &tags);

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

    // 3. julia_version, minus any prerelease/build metadata (:982-983).
    try tags.append(gpa, .{
        .key = "julia_version",
        .value = try versionText(gpa, opts.julia_version, .release_only),
    });

    return constructHost(arena, target.arch, target.os, tags.items);
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

/// Splits the canonical `BUILD_TRIPLET` shape into `arch`, `os` and the
/// remaining tags. The three are handed to `construct` separately because that
/// is the constructor's signature -- and because routing arch/os through it is
/// what applies `normalize_arch` and the auto-mapped `libc`/`call_abi`.
///
/// This handles the machine-generated forms Julia actually ships
/// (`x86_64-linux-gnu-libgfortran5-cxx11`, `aarch64-apple-darwin20`,
/// `x86_64-w64-mingw32-libgfortran5-cxx11`, ...) rather than reimplementing
/// Julia's full `parse(Platform, ::String)` regex, which also accepts hand
/// written triplets Ajt never has to read here.
fn parseBuildTriplet(
    gpa: Allocator,
    triplet_str: []const u8,
    tags: *std.ArrayList(Tag),
) Allocator.Error!struct { arch: []const u8, os: []const u8 } {
    var it = std.mem.splitScalar(u8, triplet_str, '-');
    // `splitScalar` always yields at least one element, so the arch is never
    // missing -- an empty BUILD_TRIPLET yields an empty arch, which `construct`
    // then carries through as-is.
    //
    // The dupe is load-bearing: `triplet_str` borrows the `build_h.jl` buffer
    // that `detectHost` frees on return, and an already-lowercase arch is
    // handed straight back out by `lower`, so without a copy the returned
    // Platform points at freed memory. (Caught by `select_artifact.sh`, which
    // printed `arch=` followed by garbage.) `os` needs no copy -- it is always
    // one of the string literals below.
    const arch = try gpa.dupe(u8, it.next().?);
    var os: []const u8 = "unknown";

    var os_set = false;
    var libc: ?[]const u8 = null;
    while (it.next()) |part| {
        if (!os_set) {
            if (std.mem.eql(u8, part, "linux")) {
                os = "linux";
                os_set = true;
                continue;
            }
            if (std.mem.eql(u8, part, "apple")) continue; // next part is darwinNN
            if (std.mem.startsWith(u8, part, "darwin")) {
                os = "macos";
                os_set = true;
                continue;
            }
            if (std.mem.eql(u8, part, "w64")) continue; // next part is mingw32
            if (std.mem.eql(u8, part, "mingw32")) {
                os = "windows";
                os_set = true;
                continue;
            }
            if (std.mem.startsWith(u8, part, "freebsd")) {
                os = "freebsd";
                os_set = true;
                continue;
            }
            if (std.mem.startsWith(u8, part, "openbsd")) {
                os = "openbsd";
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
    // Left implicit on a `-gnu`-less linux triplet: `construct` supplies glibc.
    if (libc) |lc| try tags.append(gpa, .{ .key = "libc", .value = lc });
    return .{ .arch = arch, .os = os };
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

/// `parseBuildTriplet` + `construct`, i.e. exactly what `detectHost` does with
/// a BUILD_TRIPLET once the file has been read. Arena-only, like the real path.
fn hostFromTriplet(arena: Allocator, triplet_str: []const u8) !Platform {
    var tags: std.ArrayList(Tag) = .empty;
    const target = try parseBuildTriplet(arena, triplet_str, &tags);
    return constructHost(arena, target.arch, target.os, tags.items);
}

test "BUILD_TRIPLET parses into the tags Julia reports" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const p = try hostFromTriplet(a.allocator(), "x86_64-linux-gnu-libgfortran5-cxx11");
    try testing.expectEqualStrings("x86_64", p.get("arch").?);
    try testing.expectEqualStrings("linux", p.get("os").?);
    try testing.expectEqualStrings("glibc", p.get("libc").?);
    try testing.expectEqualStrings("5.0.0", p.get("libgfortran_version").?);
    try testing.expectEqualStrings("cxx11", p.get("cxxstring_abi").?);
}

test "BUILD_TRIPLET: macos and windows shapes" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    inline for (.{
        .{ "aarch64-apple-darwin20", "aarch64", "macos" },
        .{ "x86_64-w64-mingw32-libgfortran5-cxx11", "x86_64", "windows" },
    }) |c| {
        const p = try hostFromTriplet(a.allocator(), c[0]);
        try testing.expectEqualStrings(c[1], p.get("arch").?);
        try testing.expectEqualStrings(c[2], p.get("os").?);
    }
    // musl must not be mistaken for glibc, i.e. the auto-mapped default must
    // not fire when the triplet already named a libc.
    const musl = try hostFromTriplet(a.allocator(), "x86_64-linux-musl-libgfortran5-cxx11");
    try testing.expectEqualStrings("x86_64", musl.get("arch").?);
    try testing.expectEqualStrings("linux", musl.get("os").?);
    try testing.expectEqualStrings("musl", musl.get("libc").?);
    // ...and a linux triplet with no libc field gets glibc from `construct`.
    const bare = try hostFromTriplet(a.allocator(), "armv7l-linux");
    try testing.expectEqualStrings("glibc", bare.get("libc").?);
    try testing.expectEqualStrings("eabihf", bare.get("call_abi").?);
}

test "the host's julia_version drops prerelease metadata" {
    // `host_triplet()` appends VersionNumber(major, minor, patch) (:982-983),
    // never VERSION itself. Keeping the `-DEV` would make `add_tag!` throw in
    // Julia, so a nightly must not produce a tag Julia cannot.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("1.13.0", try versionText(arena, "1.13.0-DEV.1234", .release_only));
    try testing.expectEqualStrings("1.12.6", try versionText(arena, "1.12.6", .release_only));
    // Unparseable input survives verbatim rather than collapsing to 0.0.0.
    try testing.expectEqualStrings("not-a-version", try versionText(arena, "not-a-version", .release_only));
}

// --- the constructor -------------------------------------------------------
//
// Every expectation below was produced by RUNNING Julia 1.12.6
// (`Platform(arch, os, Dict{String,Any}(...))` then reading `tags(p)` back).

test "construct: linux gains glibc, 32-bit ARM gains eabihf" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const arm = try construct(arena, "armv7l", "linux", &.{});
    try testing.expectEqualStrings("glibc", arm.get("libc").?);
    try testing.expectEqualStrings("eabihf", arm.get("call_abi").?);
    try testing.expectEqual(@as(usize, 4), arm.tags.len);

    const arm6 = try construct(arena, "armv6l", "linux", &.{});
    try testing.expectEqualStrings("eabihf", arm6.get("call_abi").?);

    // 64-bit ARM gets libc but NOT call_abi.
    const arm64 = try construct(arena, "aarch64", "linux", &.{});
    try testing.expectEqualStrings("glibc", arm64.get("libc").?);
    try testing.expect(arm64.get("call_abi") == null);

    // Neither default fires off linux.
    const mac = try construct(arena, "armv7l", "macos", &.{});
    try testing.expect(mac.get("libc") == null);
    try testing.expect(mac.get("call_abi") == null);
    try testing.expectEqual(@as(usize, 2), mac.tags.len);

    // An explicit call_abi suppresses the default.
    const explicit = try construct(arena, "armv7l", "linux", &.{.{ .key = "call_abi", .value = "eabi" }});
    try testing.expectEqualStrings("eabi", explicit.get("call_abi").?);
}

test "construct: arch aliases and case folding" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    inline for (.{
        .{ "AMD64", "x86_64" }, .{ "amd64", "x86_64" }, .{ "i386", "i686" },
        .{ "i486", "i686" },    .{ "i586", "i686" },    .{ "ARM", "armv7l" },
        .{ "armv6", "armv6l" }, .{ "armv7", "armv7l" }, .{ "armv8", "armv7l" },
        .{ "armv8l", "armv7l" }, .{ "arm64", "aarch64" }, .{ "ppc64le", "powerpc64le" },
        .{ "x86_64", "x86_64" },
    }) |c| {
        const p = try construct(arena, c[0], "Linux", &.{});
        try testing.expectEqualStrings(c[1], p.get("arch").?);
        try testing.expectEqualStrings("linux", p.get("os").?);
    }
    // Keys and values fold too.
    const p = try construct(arena, "x86_64", "linux", &.{.{ .key = "CXXString_ABI", .value = "CXX11" }});
    try testing.expectEqualStrings("cxx11", p.get("cxxstring_abi").?);
}

test "construct: version tags round through VersionNumber" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    inline for (.{
        .{ "os_version", "10.11", "10.11.0" },
        .{ "os_version", "14", "14.0.0" },
        .{ "libstdcxx_version", "3.4", "3.4.0" },
        .{ "libgfortran_version", "5", "5.0.0" },
        // Julia keeps an unparseable value verbatim ("extremely compatible").
        .{ "os_version", "notaversion", "notaversion" },
    }) |c| {
        const p = try construct(arena, "x86_64", "macos", &.{.{ .key = c[0], .value = c[1] }});
        try testing.expectEqualStrings(c[2], p.get(c[0]).?);
    }
    // A non-version tag is NOT rounded.
    const p = try construct(arena, "x86_64", "linux", &.{.{ .key = "cuda", .value = "10.1" }});
    try testing.expectEqualStrings("10.1", p.get("cuda").?);
}

test "construct: rejected tags" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    // A key that lowercases to os/arch is a double-pass, not a second tag --
    // appending it would inflate the tag count and shift `match_loss`.
    try testing.expectError(error.DoublePassedKey, construct(arena, "x86_64", "linux", &.{.{ .key = "OS", .value = "windows" }}));
    try testing.expectError(error.DoublePassedKey, construct(arena, "x86_64", "linux", &.{.{ .key = "Arch", .value = "aarch64" }}));
    // `add_tag!`'s forbidden characters, in the key and in the value.
    try testing.expectError(error.InvalidTagCharacter, construct(arena, "x86_64", "linux", &.{.{ .key = "we-ird", .value = "x" }}));
    try testing.expectError(error.InvalidTagCharacter, construct(arena, "x86_64", "linux", &.{.{ .key = "flavour", .value = "a+b" }}));
    // arch/os themselves skip the check (they bypass `add_tag!`).
    const p = try construct(arena, "x86_64", "linux-ish", &.{});
    try testing.expectEqualStrings("linux-ish", p.get("os").?);
}

test "construct: a repeated key replaces rather than appends" {
    // Julia's tag store is a Dict, and `match_loss` reads `Set(keys(...))`, so
    // two spellings of one key must not count twice. (Which spelling's VALUE
    // wins is Julia hash order and therefore arbitrary; the COUNT is not.)
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const p = try construct(a.allocator(), "x86_64", "linux", &.{
        .{ .key = "Libc", .value = "musl" },
        .{ .key = "libc", .value = "glibc" },
    });
    try testing.expectEqual(@as(usize, 3), p.tags.len); // arch, os, libc
    try testing.expectEqualStrings("glibc", p.get("libc").?);
}

test "construct: normalisation changes which variant select_platform picks" {
    // The reason this rule lives with the type and not in the caller.
    //
    // Oracled against Julia 1.12.6: with
    //   host = HostPlatform(Platform("x86_64","linux"; cxxstring_abi="cxx11"))
    //   A    = Platform("x86_64","linux"; libc="glibc")
    //   B    = Platform("x86_64","linux"; cxxstring_abi="cxx11")
    // Julia reports match_loss A=1, B=0 and `select_platform` returns B.
    // B only reaches loss 0 because the constructor GAVE it `libc = glibc`.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const host = try constructHost(arena, "x86_64", "linux", &.{.{ .key = "cxxstring_abi", .value = "cxx11" }});

    const explicit_libc = try construct(arena, "x86_64", "linux", &.{.{ .key = "libc", .value = "glibc" }});
    const gained_libc = try construct(arena, "x86_64", "linux", &.{.{ .key = "cxxstring_abi", .value = "cxx11" }});
    try testing.expectEqual(@as(usize, 1), (try selectPlatform(arena, &.{ explicit_libc, gained_libc }, host)).?);

    // The same two entries with the auto-mapping skipped: B is now one tag
    // short, ties A on match_loss, and loses the triplet tiebreak
    // ("x86_64-linux-gnu" > "x86_64-linux-cxx11"). A wins, i.e. the WRONG
    // tarball -- which is precisely the bug this normalisation prevents.
    const unnormalised = plat(&.{
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "os", .value = "linux" },
        .{ .key = "cxxstring_abi", .value = "cxx11" },
    });
    try testing.expectEqual(@as(usize, 0), (try selectPlatform(arena, &.{ explicit_libc, unnormalised }, host)).?);
}

test "julia_version compares major and minor only" {
    // Verified against Julia 1.12.6: 1.12.0 and 1.12.99 both match a host on
    // 1.12.6; 1.11.0 does not. The strategy is attached by the constructor to
    // any platform carrying the tag, so it is NOT host-conditional.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const host = try constructHost(arena, "x86_64", "linux", &.{.{ .key = "julia_version", .value = "1.12.6" }});
    inline for (.{ .{ "1.12.0", true }, .{ "1.12.6", true }, .{ "1.12.99", true }, .{ "1.11.0", false } }) |c| {
        const art = try construct(arena, "x86_64", "linux", &.{.{ .key = "julia_version", .value = c[0] }});
        try testing.expectEqual(c[1], platformsMatch(art, host));
    }
    // Two non-hosts use the same strategy (Julia's zero-field closures are
    // egal, so :1035-1037 does not throw).
    const p1 = try construct(arena, "x86_64", "linux", &.{.{ .key = "julia_version", .value = "1.12.0" }});
    const p2 = try construct(arena, "x86_64", "linux", &.{.{ .key = "julia_version", .value = "1.12.9" }});
    try testing.expect(platformsMatch(p1, p2));
}
