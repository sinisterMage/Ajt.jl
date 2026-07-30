//! Julia `.ji` precompile-cache headers: parse them, and re-run Julia's own
//! staleness verdict without booting Julia.
//!
//! ### Why this exists
//!
//! The shared precompile cache downloads `.ji` objects that were built on
//! *some other machine*. Without this module a bad object is discovered by
//! Julia at load time, and the way it is "discovered" is that `stale_cachefile`
//! quietly returns `true` and the package is recompiled — a multi-minute stall
//! with no error, no log line and nothing to grep for. With this module the
//! same object is rejected in milliseconds, before it is ever unpacked into the
//! depot, carrying a reason string a person can act on ("include_dependency
//! fhash change", "nonresolveable depot", "mismatched flags").
//!
//! The failure mode is safe by construction, and that is the whole argument for
//! importing someone else's compiled artifacts at all. An `@depot` tag that
//! resolves to nothing is rejected outright by `any_includes_stale`
//! (`loading.jl:3919-3923`) — it does not fall back to a guess, and it cannot
//! be mistaken for a path that happens to exist. So the worst outcome of a
//! wrong import is the recompile that would have happened anyway; there is no
//! path on which a mismatched object is silently *loaded*. Everything below is
//! an attempt to reach that verdict earlier and to say why.
//!
//! ### This module reads headers. It does not write them.
//!
//! `depot.zig` (lines 27-33) states the standing invariant that Ajt never
//! writes into `compiled/`, "because doing so would mean forging a `.ji` cache
//! header, which is a much larger compatibility surface than the depot layout."
//! That line has been *moved*, not broken, and this is where it now sits:
//!
//!   * Ajt parses and verifies headers (this module).
//!   * The later import step publishes a `.ji` by writing the bytes it received
//!     **unchanged** under a different slug path. The only thing that varies is
//!     the file name; not one byte of the header is synthesized, edited or
//!     re-checksummed by Ajt.
//!   * Nothing here can produce a `.ji` that did not come out of a real
//!     `julia` process.
//!
//! Header *forging* remains out of bounds. Verifying a foreign header before
//! trusting it is the opposite discipline, and it is what makes copying one
//! safe.
//!
//! ### The format
//!
//! There is no specification; the code that writes it is the specification.
//! Everything here is a port of `base/loading.jl` (Julia 1.12.6) plus the byte
//! layout of `jl_read_verify_header`, which is C and was recovered by reading
//! real files and checking every offset against `Base._parse_cache_header`.
//!
//! A `.ji` is:
//!
//! ```text
//!   preamble   (jl_read_verify_header; 104 bytes on x86_64-linux/1.12.6)
//!     "\xfbjli\r\n\x1a\n"        8 bytes  magic
//!     u16                        format version (12 for 1.12.6)
//!     u16                        0xFEFF byte-order mark
//!     u8                         sizeof(void*)
//!     NUL-terminated             JL_BUILD_UNAME     ("Linux")
//!     NUL-terminated             JL_BUILD_ARCH      ("x86_64")
//!     NUL-terminated             JULIA_VERSION_STRING
//!     NUL-terminated             git branch
//!     NUL-terminated             git commit
//!     u8                         pkgimage flag (nonzero => this is a .so, not a .ji)
//!     u64                        checksum       (0xfafbfcfd_xxxxxxxx)
//!     i64                        dataStartPos
//!     i64                        dataEndPos
//!   header     (_parse_cache_header, loading.jl:3427-3497)
//!     u8                         cache flags
//!     module list                (read_module_list, no build-id high word)
//!     u64                        totbytes -- a running byte budget, see below
//!     dep records                until a zero-length name
//!     preference names           until a zero-length name
//!     u64                        prefs_hash
//!     i64                        srctextpos
//!     module list                required_modules (WITH build-id high word)
//!     i32 + bytes                clone_targets
//!   ...serialized data...
//!   srctext    (at srctextpos: i32 len, name, u64 len, bytes; ... ; i32 0)
//!   trailer
//!     u32                        crc32c of the companion .so   (pkgimage only)
//!     u32                        crc32c of this file's first (len-4) bytes
//! ```
//!
//! Four details in there are each individually capable of a plausible-looking
//! wrong parse:
//!
//!  1. **Two different UUID encodings in one file.** `read_module_list`
//!     (`loading.jl:3408-3420`) reads a UUID as `(read UInt64, read UInt64)` —
//!     high word FIRST, each word little-endian. `binunpack` (`pkgid.jl:38-45`),
//!     which decodes the `requires` records, reads one little-endian `UInt128`
//!     — low word first. Using either encoding for both produces UUIDs whose
//!     halves are swapped, which still looks like a UUID.
//!  2. **`totbytes` is a budget, not a length.** It is decremented by every
//!     field of the dependency and preference sections and asserted to reach
//!     exactly zero (`loading.jl:3487`). It is the format's only internal
//!     consistency check, and it is worth reproducing: a parser that is off by
//!     one field still terminates on the zero sentinel and returns a
//!     *plausible* header. Here it becomes `error.CorruptHeader`.
//!  3. **The high word of a build id lives in two places.** `modules` entries
//!     carry only the low 64 bits; the full `UInt128` that `stale_cachefile`
//!     compares is `(UInt128(checksum) << 64) | (id_build % UInt64)`
//!     (`loading.jl:4032`), where `checksum` comes from the *preamble*.
//!     `required_modules` entries, by contrast, carry both words inline.
//!  4. **A dep record whose name begins with `\0` is not a file.** It is a
//!     `binpack`ed `PkgId` and belongs to `requires`, not `includes`
//!     (`loading.jl:3468-3472`).
//!
//! ### `@depot` relocation, and why it is what makes sharing work
//!
//! Julia rewrites every path under a depot to a `@depot/...` tag when it writes
//! the header (`replace_depot_path`, `loading.jl:3381-3390`) and resolves it
//! back against the *reader's* `DEPOT_PATH` when it reads one
//! (`resolve_depot`/`restore_depot_path`, `loading.jl:3406-3410`, applied at
//! `loading.jl:3515-3572`). Depot independence therefore comes for free: a
//! `.ji` whose every include is `@depot`-tagged does not care where the depot
//! is mounted. That is the entire technical basis for shipping one machine's
//! `compiled/` to another, and `isrelocatable` (`loading.jl:1923-1941`) is
//! Julia's own name for the predicate.
//!
//! Two rules govern the resolution and both matter:
//!
//!   * `include()` files (those whose source text is stored in the cache) must
//!     all resolve to the SAME depot, or none of them is rewritten
//!     (`loading.jl:3541-3562`) — a half-populated depot must not be able to
//!     satisfy half a package.
//!   * `include_dependency()` files may each resolve to a different depot
//!     (`loading.jl:3564-3574`, Julia issue #52161).
//!
//! ### What must never be published
//!
//! Two categories, both detected here so the publish side can refuse rather
//! than ship an object that will always miss:
//!
//!   * **Not relocatable** (`isrelocatable`, `loading.jl:1923-1941`): an
//!     include recorded as an absolute path. On this host that is every package
//!     developed out of a working tree — the path names someone's checkout, and
//!     it will not exist on the machine that downloads it.
//!   * **mtime-tracked `include_dependency`**: a dep recorded with a real mtime
//!     rather than `-1.0` is compared against the file's mtime on disk, and an
//!     mtime does not survive a tarball, a `git clone`, a container layer or a
//!     `cp`. Julia's own pile of compensations at `loading.jl:3937-3942` —
//!     Docker rounding, CircleCI truncation, GlusterFS microseconds, Nix's
//!     `mtime == 1.0`, Windows tar's one-microsecond skew — is the evidence
//!     that this is unsalvageable in general. `publishRefusal` rejects these.
//!
//! ### Layering
//!
//! `parse` is pure: bytes in, an arena-allocated `Header` out, no I/O. Only
//! `restoreDepots` and `verify` touch the filesystem, because resolving a
//! depot and re-hashing an include are both questions about a real machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const slug = @import("../julia/slug.zig");
const preferences = @import("../julia/preferences.zig");
const Table = @import("../toml/value.zig").Table;

pub const Uuid = slug.Uuid;

/// `_crc32c` (`base/util.jl`) is CRC-32C / Castagnoli. `Crc32Iscsi` has
/// matching parameters (poly 0x1EDC6F41 reflected, init/xorout 0xFFFFFFFF).
pub const Crc32c = std.hash.crc.Crc32Iscsi;

/// `JI_MAGIC` from `src/staticdata.c`.
pub const magic = "\xfbjli\r\n\x1a\n";

/// The byte-order mark `jl_read_verify_header` compares against.
pub const bom: u16 = 0xFEFF;

/// `JI_FORMAT_VERSION` for Julia 1.12.6, read out of every `.ji` on this host.
///
/// `jl_read_verify_header` compares it for EQUALITY and answers 0 on anything
/// else, so a different version is not "a newer file we can partly read" — it
/// is a file whose layout is undefined here. `parsePreamble` refuses it for the
/// same reason: half-parsing an unknown layout is how a wrong-but-plausible
/// header gets accepted.
pub const ji_format_version: u16 = 12;

/// `Filesystem.pathsep()` on the platforms Ajt targets. The `@depot` tag is
/// always written with it (`loading.jl:3383`).
const pathsep = '/';

/// The tag `replace_depot_path` substitutes for a depot root
/// (`loading.jl:3381-3390`).
pub const depot_tag = "@depot";

// ===========================================================================
// Types
// ===========================================================================

/// `Base.PkgId` (`pkgid.jl:3-10`). A null `uuid` is Julia's `nothing`, which it
/// stores for a top-level module and for the `PkgId("")` placeholder that a
/// dep record with module index 0 decodes to.
pub const PkgId = struct {
    uuid: ?Uuid,
    name: []const u8,

    pub const none: PkgId = .{ .uuid = null, .name = "" };

    /// `==(a::PkgId, b::PkgId)` (`pkgid.jl:17`).
    pub fn eql(a: PkgId, b: PkgId) bool {
        if ((a.uuid == null) != (b.uuid == null)) return false;
        if (a.uuid) |au| if (!std.mem.eql(u8, &au.bytes, &b.uuid.?.bytes)) return false;
        return std.mem.eql(u8, a.name, b.name);
    }
};

/// One `PkgId => build_id` pair out of `read_module_list` (`loading.jl:3408-3420`).
///
/// For the `modules` list the high 64 bits are always zero — they are supplied
/// by the preamble checksum, see `fullBuildId`. For `required_modules` they are
/// stored inline and are already correct.
pub const ModuleEntry = struct {
    id: PkgId,
    build_id: u128,
};

/// A `CacheHeaderIncludes` (`loading.jl:3366-3375`).
pub const Include = struct {
    /// The module that performed the `include`, or `PkgId.none` when the
    /// record's module index was 0 (`loading.jl:3457`).
    id: PkgId,
    /// As stored, until `restoreDepots` rewrites an `@depot` tag in place.
    filename: []const u8,
    /// `filename` exactly as the file records it, never rewritten.
    ///
    /// Kept because the publish-side predicates ask "is this path
    /// `@depot`-relative?", and after `restoreDepots` every path is absolute —
    /// so `isRelocatable` on a restored header would answer `false` for a cache
    /// that is perfectly relocatable. `verify` restores as a matter of course
    /// (`stale_cachefile` calls the public `parse_cache_header`), which makes
    /// "verify it, then decide whether to publish it" the natural and, without
    /// this field, silently wrong order.
    raw_filename: []const u8,
    fsize: u64,
    hash: u32,
    /// `-1.0` means "tracked by content" — the `fsize`/`hash` pair is
    /// authoritative and the mtime is not consulted (`loading.jl:3933`).
    mtime: f64,
    modpath: []const []const u8,
    /// Whether this file's SOURCE TEXT is stored in the cache, i.e. whether it
    /// is in `srctext_files`. This is how `parse_cache_header` tells an
    /// `include()` from an `include_dependency()` (`loading.jl:3506-3512`), and
    /// it must be decided before `restoreDepots` rewrites `filename`.
    is_srcfile: bool,
};

/// A `requires` entry: `require(from, to.name)` must resolve to `to`
/// (`loading.jl:4114-4121`).
pub const Require = struct {
    from: PkgId,
    to: PkgId,
};

/// Everything `jl_read_verify_header` consumes, plus where it stopped.
pub const Preamble = struct {
    format_version: u16,
    pointer_size: u8,
    build_uname: []const u8,
    build_arch: []const u8,
    julia_version: []const u8,
    git_branch: []const u8,
    git_commit: []const u8,
    /// Nonzero means the file is a pkgimage (`.so`), not a `.ji`.
    /// `isvalid_cache_header` treats that as an invalid header
    /// (`loading.jl:3352-3355`).
    pkgimage: u8,
    checksum: u64,
    /// The two `Int64`s after the checksum, in FILE order.
    ///
    /// `jl_read_verify_header`'s third and fourth out-parameters arrive
    /// SWAPPED relative to the file: for `ArgTools/aGHFV_HGYMs.ji` the bytes
    /// hold `832` then `1277628`, and the ccall reports `dataStartPos =
    /// 1277628` (which is also `srctextpos`, i.e. the END) and `dataEndPos =
    /// 832`. Nothing in Base notices, because `isvalid_cache_header` passes two
    /// throwaway `Ref{Int64}()`s and discards both (`loading.jl:3350`). Named
    /// here for what the file says; the harness asserts the ccall's order so
    /// the claim cannot rot.
    data_start: i64,
    data_end: i64,
    /// Byte offset where `_parse_cache_header` begins. 104 for
    /// x86_64-linux/1.12.6; derived, never assumed.
    header_offset: usize,
};

/// The parsed result of `_parse_cache_header` (`loading.jl:3427-3497`) plus
/// `srctext_files` (`loading.jl:3658-3670`).
///
/// Strings borrow the `bytes` slice passed to `parse`; the arena holds only the
/// arrays and, after `restoreDepots`, the rewritten filenames. Keep `bytes`
/// alive for as long as the header.
pub const Header = struct {
    preamble: Preamble,
    flags: u8,
    modules: []const ModuleEntry,
    includes: []Include,
    requires: []const Require,
    prefs: []const []const u8,
    prefs_hash: u64,
    srctextpos: i64,
    required_modules: []const ModuleEntry,
    clone_targets: []const u8,
    /// Names from the source-text section, sorted for lookup. Julia keeps them
    /// in a `Set{String}` (`loading.jl:3659`); order is never significant.
    srctext_files: []const []const u8,
    /// Set by `restoreDepots`, which must run at most once.
    depots_restored: bool = false,

    /// The `UInt128` build id `stale_cachefile` compares (`loading.jl:4032`):
    /// the preamble checksum in the high word, the module list's id in the low.
    pub fn fullBuildId(self: *const Header, entry: ModuleEntry) u128 {
        return (@as(u128, self.preamble.checksum) << 64) |
            @as(u128, @as(u64, @truncate(entry.build_id)));
    }

    /// `pkgimage = !isempty(clone_targets)` (`loading.jl:4001`). Non-empty
    /// means a companion `.so` must exist and match.
    pub fn isPkgimage(self: *const Header) bool {
        return self.clone_targets.len != 0;
    }

    pub fn cacheFlags(self: *const Header) CacheFlags {
        return CacheFlags.fromU8(self.flags);
    }
};

// ===========================================================================
// Cache flags
// ===========================================================================

/// `Base.CacheFlags` (`loading.jl:1690-1706`). Bit layout `OOICCDDP`.
pub const CacheFlags = struct {
    use_pkgimages: bool,
    debug_level: u2,
    check_bounds: u2,
    inlining: bool,
    opt_level: u2,

    /// `CacheFlags(f::UInt8)` (`loading.jl:1698-1706`).
    pub fn fromU8(f: u8) CacheFlags {
        return .{
            .use_pkgimages = (f & 1) != 0,
            .debug_level = @truncate(f >> 1),
            .check_bounds = @truncate(f >> 3),
            .inlining = ((f >> 5) & 1) != 0,
            .opt_level = @truncate(f >> 6),
        };
    }

    /// `_cacheflag_to_uint8` (`loading.jl:1725-1733`).
    pub fn toU8(self: CacheFlags) u8 {
        return (@as(u8, @intFromBool(self.use_pkgimages)) << 0) |
            (@as(u8, self.debug_level) << 1) |
            (@as(u8, self.check_bounds) << 3) |
            (@as(u8, @intFromBool(self.inlining)) << 5) |
            (@as(u8, self.opt_level) << 6);
    }

    /// `DefaultCacheFlags` (`loading.jl:1723`) for a non-debug build:
    /// `use_pkgimages=true, debug_level=1, check_bounds=0, inline=true,
    /// opt_level=2` — the 0xA3 that every `.ji` in a stock depot carries.
    pub const default: CacheFlags = .{
        .use_pkgimages = true,
        .debug_level = 1,
        .check_bounds = 0,
        .inlining = true,
        .opt_level = 2,
    };
};

/// `jl_match_cache_flags(requested, actual)` — C, in `src/staticdata.c`, with
/// no Julia-level mirror to port. Derived instead from its full 256x256 truth
/// table, dumped by ccall and reproduced exactly (0 mismatches over all 65536
/// pairs); `tools/diff_harness/jicache.sh` regenerates and re-checks it.
///
/// The rule, once recovered, is readable:
///
///   * two plain `.ji`s (neither side wanting pkgimages) match unconditionally
///     — the remaining flags describe native code that is not there;
///   * otherwise the pkgimage bits must agree exactly;
///   * `debug_level` and `opt_level` in the CACHE may EXCEED what was asked for
///     (a more-optimized, more-debuggable object still satisfies a weaker
///     request);
///   * `check_bounds` and `inline` must match exactly, because those change
///     semantics rather than quality.
pub fn matchCacheFlags(requested: u8, actual: u8) bool {
    // For .ji-only loading, the other flags are ignored entirely.
    if ((requested & 1) == 0 and (actual & 1) == 0) return true;
    const r = CacheFlags.fromU8(requested);
    const a = CacheFlags.fromU8(actual);
    if (r.use_pkgimages != a.use_pkgimages) return false;
    if (a.debug_level < r.debug_level) return false;
    if (a.check_bounds != r.check_bounds) return false;
    if (a.inlining != r.inlining) return false;
    if (a.opt_level < r.opt_level) return false;
    return true;
}

// ===========================================================================
// Byte reader
// ===========================================================================

pub const ParseError = error{
    /// A field ran past the end of the file.
    Truncated,
    /// Not a `.ji` at all: bad magic, wrong format version, wrong BOM, or a
    /// pointer size this build cannot read. Julia's `isvalid_cache_header`
    /// answers 0 for all of these (`loading.jl:3348-3357`).
    BadHeader,
    /// The preamble says this is a pkgimage (`.so`). `isvalid_cache_header`
    /// explicitly refuses those (`loading.jl:3352-3355`).
    IsPkgimage,
    /// `totbytes` did not land on zero (`loading.jl:3487`), or a length field
    /// was negative. The file is damaged in a way that a lenient parse would
    /// hide.
    CorruptHeader,
} || Allocator.Error;

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn remaining(self: Cursor) usize {
        return self.bytes.len - self.pos;
    }

    fn take(self: *Cursor, n: usize) ParseError![]const u8 {
        if (n > self.remaining()) return error.Truncated;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn u8_(self: *Cursor) ParseError!u8 {
        return (try self.take(1))[0];
    }

    fn int(self: *Cursor, comptime T: type) ParseError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, (try self.take(n))[0..n], .little);
    }

    fn f64_(self: *Cursor) ParseError!f64 {
        return @bitCast(try self.int(u64));
    }

    /// A NUL-terminated string, as `readstr_verify` consumes one.
    fn cstr(self: *Cursor) ParseError![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse
            return error.Truncated;
        const out = self.bytes[self.pos..end];
        self.pos = end + 1;
        return out;
    }

    /// An `Int32` length field. Julia reads these signed and would throw on a
    /// negative; here it is a corrupt header rather than a giant allocation.
    fn len32(self: *Cursor) ParseError!u32 {
        const n = try self.int(i32);
        if (n < 0) return error.CorruptHeader;
        return @intCast(n);
    }
};

// ===========================================================================
// Parsing
// ===========================================================================

/// `jl_read_verify_header` (C, `src/staticdata.c`), reproduced from the byte
/// layout of real files and cross-checked against `Base.isvalid_cache_header`
/// plus the stream position it leaves behind.
///
/// The *structural* fields are validated here and each is fatal, exactly as
/// `jl_read_verify_header` treats them: magic, format version, BOM, pointer
/// size, pkgimage flag. The five identity strings are returned rather than
/// compared, because the comparison needs the `julia` that will do the
/// loading — that is `verify`'s job, via `VerifyOptions.expect`.
pub fn parsePreamble(bytes: []const u8) ParseError!Preamble {
    var c: Cursor = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try c.take(magic.len), magic)) return error.BadHeader;
    const format_version = try c.int(u16);
    if (format_version != ji_format_version) return error.BadHeader;
    if (try c.int(u16) != bom) return error.BadHeader;
    // `read_uint8(s) == sizeof(void*)`. Ajt and the `julia` that will load the
    // cache are on the same machine, so its pointer size is this binary's.
    const pointer_size = try c.u8_();
    if (pointer_size != @sizeOf(usize)) return error.BadHeader;
    const build_uname = try c.cstr();
    const build_arch = try c.cstr();
    const julia_version = try c.cstr();
    const git_branch = try c.cstr();
    const git_commit = try c.cstr();
    const pkgimage = try c.u8_();
    // `isvalid_cache_header` reads the checksum and then throws the whole
    // result away if the pkgimage byte was set (loading.jl:3352-3355), so a
    // `.so` never reaches `_parse_cache_header`.
    if (pkgimage != 0) return error.IsPkgimage;
    const checksum = try c.int(u64);
    const data_start = try c.int(i64);
    const data_end = try c.int(i64);
    return .{
        .format_version = format_version,
        .pointer_size = pointer_size,
        .build_uname = build_uname,
        .build_arch = build_arch,
        .julia_version = julia_version,
        .git_branch = git_branch,
        .git_commit = git_commit,
        .pkgimage = pkgimage,
        .checksum = checksum,
        .data_start = data_start,
        .data_end = data_end,
        .header_offset = c.pos,
    };
}

/// `read_module_list(f, has_buildid_hi)` (`loading.jl:3408-3420`).
///
/// The UUID is `(read UInt64, read UInt64)` — HIGH word first, each word
/// little-endian — which is not the encoding `binunpack` uses for the same
/// type five lines away. See detail 1 in the module doc.
fn readModuleList(arena: Allocator, c: *Cursor, has_buildid_hi: bool) ParseError![]ModuleEntry {
    var out: std.ArrayList(ModuleEntry) = .empty;
    while (true) {
        const n = try c.len32();
        if (n == 0) break;
        const name = try c.take(n);
        const hi = try c.int(u64);
        const lo = try c.int(u64);
        const uuid_val = (@as(u128, hi) << 64) | @as(u128, lo);
        const build_hi: u128 = if (has_buildid_hi) @as(u128, try c.int(u64)) << 64 else 0;
        const build_id = build_hi | @as(u128, try c.int(u64));
        try out.append(arena, .{
            .id = .{ .uuid = uuidFromU128(uuid_val), .name = name },
            .build_id = build_id,
        });
    }
    return out.toOwnedSlice(arena);
}

/// `PkgId(u::UUID, name)` stores `nothing` when the UUID is all zeros
/// (`pkgid.jl:7`).
pub fn uuidFromU128(v: u128) ?Uuid {
    if (v == 0) return null;
    var out: Uuid = .{ .bytes = undefined };
    for (&out.bytes, 0..) |*b, i| b.* = @truncate(v >> @intCast(8 * (15 - i)));
    return out;
}

/// Canonical lowercase 8-4-4-4-12 text, i.e. what `string(::UUID)` prints.
/// Arena-allocated.
pub fn uuidText(arena: Allocator, u: Uuid) Allocator.Error![]const u8 {
    const b = u.bytes;
    return std.fmt.allocPrint(
        arena,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] },
    );
}

/// `binunpack(s)` (`pkgid.jl:38-45`): a leading NUL, then ONE little-endian
/// `UInt128` (low word first — the opposite of `read_module_list`), then the
/// name as the rest of the string.
fn binunpack(s: []const u8) ParseError!PkgId {
    if (s.len < 17 or s[0] != 0) return error.CorruptHeader;
    const v = std.mem.readInt(u128, s[1..17], .little);
    return .{ .uuid = uuidFromU128(v), .name = s[17..] };
}

/// `_parse_cache_header` (`loading.jl:3427-3497`) followed by `srctext_files`
/// (`loading.jl:3658-3670`).
///
/// `bytes` must be the WHOLE file: `srctextpos` is an absolute offset into it,
/// and `verify` also needs the trailer. Everything the returned `Header` points
/// at either borrows `bytes` or lives in `arena`.
///
/// `@depot` tags are left as stored. Run `restoreDepots` to get what the public
/// `parse_cache_header` returns.
pub fn parse(arena: Allocator, bytes: []const u8) ParseError!Header {
    const preamble = try parsePreamble(bytes);
    var c: Cursor = .{ .bytes = bytes, .pos = preamble.header_offset };

    const flags = try c.u8_();
    const modules = try readModuleList(arena, &c, false);

    // `totbytes` budgets the dependency and preference sections and must land
    // exactly on zero. It is signed in Julia and is allowed to go negative
    // transiently only in the sense that a corrupt file would; track it as i64.
    var totbytes: i64 = @bitCast(try c.int(u64));

    var includes: std.ArrayList(Include) = .empty;
    var requires: std.ArrayList(Require) = .empty;

    while (true) {
        const n2 = try c.len32();
        totbytes -= 4;
        if (n2 == 0) break;
        const depname = try c.take(n2);
        totbytes -= @intCast(n2);
        const fsize = try c.int(u64);
        totbytes -= 8;
        const hash = try c.int(u32);
        totbytes -= 4;
        const mtime = try c.f64_();
        totbytes -= 8;
        var n1 = try c.len32();
        totbytes -= 4;

        var modkey: PkgId = .none;
        var modpath: std.ArrayList([]const u8) = .empty;
        if (n1 != 0) {
            if (n1 > modules.len) return error.CorruptHeader;
            modkey = modules[n1 - 1].id;
            while (true) {
                n1 = try c.len32();
                totbytes -= 4;
                if (n1 == 0) break;
                try modpath.append(arena, try c.take(n1));
                totbytes -= @intCast(n1);
            }
        }

        // A name beginning with NUL is a `binpack`ed PkgId, not a path
        // (loading.jl:3468-3472).
        if (depname[0] == 0) {
            try requires.append(arena, .{ .from = modkey, .to = try binunpack(depname) });
        } else {
            try includes.append(arena, .{
                .id = modkey,
                .filename = depname,
                .raw_filename = depname,
                .fsize = fsize,
                .hash = hash,
                .mtime = mtime,
                .modpath = try modpath.toOwnedSlice(arena),
                .is_srcfile = false, // filled in below, once srctext is read
            });
        }
    }

    var prefs: std.ArrayList([]const u8) = .empty;
    while (true) {
        const n2 = try c.len32();
        totbytes -= 4;
        if (n2 == 0) break;
        try prefs.append(arena, try c.take(n2));
        totbytes -= @intCast(n2);
    }

    const prefs_hash = try c.int(u64);
    totbytes -= 8;
    const srctextpos = try c.int(i64);
    totbytes -= 8;
    if (totbytes != 0) return error.CorruptHeader;

    const required_modules = try readModuleList(arena, &c, true);
    const clone_len = try c.len32();
    const clone_targets = try c.take(clone_len);

    const srctext_files = try readSrctextFiles(arena, bytes, srctextpos);
    for (includes.items) |*inc| {
        inc.is_srcfile = isSrctextFile(srctext_files, inc.filename);
    }

    return .{
        .preamble = preamble,
        .flags = flags,
        .modules = modules,
        .includes = try includes.toOwnedSlice(arena),
        .requires = try requires.toOwnedSlice(arena),
        .prefs = try prefs.toOwnedSlice(arena),
        .prefs_hash = prefs_hash,
        .srctextpos = srctextpos,
        .required_modules = required_modules,
        .clone_targets = clone_targets,
        .srctext_files = srctext_files,
    };
}

/// `srctext_files(f, srctextpos, includes)` (`loading.jl:3658-3670`), sorted.
///
/// Julia stops on a zero-length name or at EOF. EOF matters: the last four
/// bytes of the file are the crc32c trailer, so a file without the zero
/// sentinel must not be read into it.
fn readSrctextFiles(arena: Allocator, bytes: []const u8, srctextpos: i64) ParseError![]const []const u8 {
    if (srctextpos == 0) return &.{};
    if (srctextpos < 0 or @as(u64, @intCast(srctextpos)) > bytes.len) return error.CorruptHeader;
    var c: Cursor = .{ .bytes = bytes, .pos = @intCast(srctextpos) };
    var out: std.ArrayList([]const u8) = .empty;
    while (c.remaining() >= 4) {
        const n = try c.len32();
        if (n == 0) break;
        try out.append(arena, try c.take(n));
        const len = try c.int(u64);
        if (len > c.remaining()) return error.Truncated;
        c.pos += @intCast(len);
    }
    const files = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, files, {}, lessThanString);
    return files;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isSrctextFile(sorted: []const []const u8, name: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sorted[mid], name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

// ===========================================================================
// Clone targets
// ===========================================================================

/// One entry of the `clone_targets` blob (`parse_image_target`,
/// `loading.jl:1768-1778`).
pub const ImageTarget = struct {
    name: []const u8,
    flags: i32,
    ext_features: []const u8,
    features_en: []const u8,
    features_dis: []const u8,
};

/// `parse_image_targets(targets)` (`loading.jl:1780-1789`).
///
/// An EMPTY blob is `error.Truncated`, not zero targets — Julia reads the count
/// unconditionally and would raise `EOFError`. Every caller in Base is guarded
/// by `pkgimage = !isempty(clone_targets)` (`loading.jl:4001`), and a `.ji`
/// built with `--pkgimages=no` carries no blob at all, so check
/// `Header.isPkgimage` first.
///
/// Purely informational here: what the blob *means* is decided by
/// `jl_check_pkgimage_clones` in C, which does a CPU-feature subset test that
/// cannot be ported without the per-architecture feature tables. `verify` uses
/// the conservative rule instead — see `VerifyOptions.clone_targets`.
pub fn parseImageTargets(arena: Allocator, targets: []const u8) ParseError![]const ImageTarget {
    var c: Cursor = .{ .bytes = targets };
    const n = try c.len32();
    // Every target costs at least 5 length fields, so a count larger than the
    // blob is corrupt. Checked BEFORE allocating: a 4-byte blob can otherwise
    // ask for ~170 GB, and `nfeature` would wrap `4 * n` on a 32-bit target.
    if (n > c.remaining()) return error.CorruptHeader;
    const out = try arena.alloc(ImageTarget, n);
    for (out) |*t| {
        const flags = try c.int(i32);
        const nfeature = try c.len32();
        if (nfeature > c.remaining() / 4) return error.CorruptHeader;
        const features_en = try c.take(4 * @as(usize, nfeature));
        const features_dis = try c.take(4 * @as(usize, nfeature));
        const name_len = try c.len32();
        const name = try c.take(name_len);
        const ext_len = try c.len32();
        const ext_features = try c.take(ext_len);
        t.* = .{
            .name = name,
            .flags = flags,
            .ext_features = ext_features,
            .features_en = features_en,
            .features_dis = features_dis,
        };
    }
    return out;
}

// ===========================================================================
// @depot resolution
// ===========================================================================

/// `restore_depot_path(path, depot)` (`loading.jl:3404-3406`):
/// `replace(path, r"^@depot" => depot; count=1)`. Note the regex is not
/// anchored to a following separator — `restore_depot_path(p, "")` is how
/// `_read_dependency_src` strips the tag (`loading.jl:3630`).
pub fn restoreDepotPath(arena: Allocator, path: []const u8, depot: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, depot_tag)) return path;
    return std.mem.concat(arena, u8, &.{ depot, path[depot_tag.len..] });
}

pub const DepotResolution = union(enum) {
    /// The path is absolute, not `@depot`-tagged: it names a location on the
    /// machine that built the cache and nothing can be done about it.
    not_relocatable,
    /// Tagged, but no depot on `DEPOT_PATH` contains it.
    no_depot_found,
    /// The depot (an entry of `DEPOT_PATH`) that contains it.
    depot: []const u8,
};

/// `resolve_depot(inc)` (`loading.jl:3408-3414`).
///
/// Requires the tag to be followed by a path separator, unlike
/// `restore_depot_path`.
pub fn resolveDepot(
    arena: Allocator,
    io: Io,
    inc: []const u8,
    depot_path: []const []const u8,
) (Allocator.Error || error{Canceled})!DepotResolution {
    if (!std.mem.startsWith(u8, inc, depot_tag ++ [_]u8{pathsep})) return .not_relocatable;
    for (depot_path) |depot| {
        const p = try restoreDepotPath(arena, inc, depot);
        if (try existsPath(io, p)) return .{ .depot = depot };
    }
    return .no_depot_found;
}

/// The second half of the public `parse_cache_header` (`loading.jl:3500-3576`),
/// which is the part that turns `@depot` tags back into real paths.
///
/// Two different rules, deliberately (`loading.jl:3515-3527` explains all four
/// cases in Julia's own words):
///
///   * `include()` files must agree on ONE depot. If they resolve to several,
///     none is rewritten and the tags survive into `any_includes_stale`, which
///     rejects the cache. A relocatable path that resolves nowhere is still
///     rewritten with the depot the others agreed on, so the rejection comes
///     from the resolved path not existing rather than from the tag.
///   * `include_dependency()` files resolve one at a time (Julia issue #52161).
///
/// Idempotent: a second call is a no-op, because the tags are gone.
pub fn restoreDepots(
    arena: Allocator,
    io: Io,
    hdr: *Header,
    depot_path: []const []const u8,
) (Allocator.Error || error{Canceled})!void {
    if (hdr.depots_restored) return;
    hdr.depots_restored = true;

    // The depot is chosen from the SOURCE TEXT names, not from the includes:
    // Julia wants to scan every stored source file so its diagnostics can see
    // a depot that is missing some of them (loading.jl:3521-3527).
    var srcdepot: ?[]const u8 = null;
    var multiple_depots_found = false;
    for (hdr.srctext_files) |src| {
        switch (try resolveDepot(arena, io, src, depot_path)) {
            .not_relocatable, .no_depot_found => {},
            .depot => |d| {
                if (srcdepot) |s| {
                    if (!std.mem.eql(u8, s, d)) multiple_depots_found = true;
                } else srcdepot = d;
            },
        }
    }

    if (!multiple_depots_found) {
        if (srcdepot) |d| {
            for (hdr.includes) |*inc| {
                if (inc.is_srcfile) inc.filename = try restoreDepotPath(arena, inc.filename, d);
            }
        }
    }

    for (hdr.includes) |*inc| {
        if (inc.is_srcfile) continue;
        switch (try resolveDepot(arena, io, inc.filename, depot_path)) {
            .not_relocatable, .no_depot_found => {},
            .depot => |d| inc.filename = try restoreDepotPath(arena, inc.filename, d),
        }
    }
}

// ===========================================================================
// Publish side
// ===========================================================================

/// Why an object must not be uploaded to a shared cache.
pub const PublishRefusal = union(enum) {
    /// `isrelocatable` says no: an include is recorded as an absolute path.
    not_relocatable: []const u8,
    /// An `include_dependency` recorded by mtime. See the module doc.
    mtime_tracked: []const u8,

    pub fn reason(self: PublishRefusal) []const u8 {
        return switch (self) {
            .not_relocatable => "include path is not @depot-relative",
            .mtime_tracked => "include_dependency is tracked by mtime, not content",
        };
    }

    pub fn path(self: PublishRefusal) []const u8 {
        return switch (self) {
            .not_relocatable => |p| p,
            .mtime_tracked => |p| p,
        };
    }
};

/// `Base.isrelocatable(pkg)` (`loading.jl:1923-1941`), applied to an
/// already-parsed header instead of to a `PkgId` in the active project.
///
/// One quirk is reproduced rather than fixed, because agreeing with Julia is
/// the specification. Julia writes
///
/// ```julia
/// _, (includes, includes_srcfiles, _), _... = _parse_cache_header(io, path)
/// for inc in includes
///     !startswith(inc.filename, "@depot") && return false
///     if inc ∉ includes_srcfiles          # <-- inc is a CacheHeaderIncludes,
///         track_content = inc.mtime == -1.0   #   includes_srcfiles is a Set{String}
///         track_content || return false
///     end
/// end
/// ```
///
/// `_parse_cache_header` returns the source-text names as a `Set{String}`
/// (`loading.jl:3495`), so `inc ∉ includes_srcfiles` compares a struct against
/// a set of strings and is therefore ALWAYS true. The mtime test consequently
/// applies to every include, not only to `include_dependency` ones, making
/// `isrelocatable` stricter than it reads. Over the 392 `.ji` files in this
/// host's depot the two readings agree on every file (no `.ji` records a
/// non-`-1.0` mtime at all), so the difference is currently unobservable — and
/// the stricter one is the right side to be on for a publish gate anyway.
pub fn isRelocatable(hdr: *const Header) bool {
    return publishRefusal(hdr) == null;
}

/// `isRelocatable` with the reason and the offending path attached, because
/// "this package cannot be shared" is useless without "…because of this file".
///
/// Reads `raw_filename`, so the answer does not depend on whether
/// `restoreDepots` has already run.
pub fn publishRefusal(hdr: *const Header) ?PublishRefusal {
    for (hdr.includes) |inc| {
        if (!std.mem.startsWith(u8, inc.raw_filename, depot_tag)) {
            return .{ .not_relocatable = inc.raw_filename };
        }
        if (inc.mtime != -1.0) return .{ .mtime_tracked = inc.raw_filename };
    }
    return null;
}

/// How many includes are tracked by mtime rather than by content. Reported by
/// the harness because it measures how much of a depot is publishable at all.
pub fn mtimeTrackedCount(hdr: *const Header) usize {
    var n: usize = 0;
    for (hdr.includes) |inc| {
        if (inc.mtime != -1.0) n += 1;
    }
    return n;
}

// ===========================================================================
// Verification
// ===========================================================================

/// The reason vocabulary is Julia's, verbatim: these are the strings
/// `record_reason` accumulates (`loading.jl:3906-3908`) and that
/// `list_reasons` prints as "(cache misses: ...)". Matching them means an Ajt
/// rejection and a `JULIA_DEBUG=loading` line say the same words about the same
/// object.
pub const Reason = enum {
    incompatible_header,
    empty_module_list,
    mismatched_flags,
    requires_pkgimages,
    target_mismatch,
    missing_ocachefile,
    for_different_pkgid,
    for_different_buildid,
    dep_missing_source,
    wrong_dep_buildid,
    wrong_source,
    nonresolveable_depot,
    missing_sourcefile,
    include_dependency_mtime_change,
    include_dependency_fsize_change,
    include_dependency_fhash_change,
    invalid_checksum,
    ocachefile_invalid_checksum,
    preferences_hash_mismatch,

    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .incompatible_header => "incompatible header",
            // Julia returns true here without recording a reason
            // (`loading.jl:3988-3990`); the name is Ajt's.
            .empty_module_list => "empty module list",
            .mismatched_flags => "mismatched flags",
            .requires_pkgimages => "requires pkgimages",
            .target_mismatch => "target mismatch",
            .missing_ocachefile => "missing ocachefile",
            .for_different_pkgid => "for different pkgid",
            .for_different_buildid => "for different buildid",
            .dep_missing_source => "dep missing source",
            .wrong_dep_buildid => "wrong dep buildid",
            .wrong_source => "wrong source",
            .nonresolveable_depot => "nonresolveable depot",
            .missing_sourcefile => "missing sourcefile",
            .include_dependency_mtime_change => "include_dependency mtime change",
            .include_dependency_fsize_change => "include_dependency fsize change",
            .include_dependency_fhash_change => "include_dependency fhash change",
            .invalid_checksum => "invalid checksum",
            .ocachefile_invalid_checksum => "ocachefile invalid checksum",
            .preferences_hash_mismatch => "preferences hash mismatch",
        };
    }
};

/// A rejection carries the Julia reason *and* a sentence a person can act on.
/// The whole point of doing this in Ajt rather than letting Julia discover it
/// is that Julia's discovery is a silent recompile.
pub const Rejection = struct {
    reason: Reason,
    /// Arena-allocated; modelled on the corresponding `@debug` message.
    detail: []const u8,
};

/// The five identity strings `jl_read_verify_header` compares byte for byte
/// (`readstr_verify(..., 1)`), any one of which answers 0 and sends Julia
/// straight to a recompile.
///
/// **No field has a default, and `VerifyOptions.expect` has no default either.**
/// That is deliberate: these are precisely the fields that differ when a `.ji`
/// was built by a *different* Julia — another version, another architecture,
/// another commit — which for a shared cache is the single most likely thing to
/// be wrong. An optional check defaults to silence, and silence here means
/// "accept a foreign object", so the compiler is made to insist instead.
///
/// Fill them from the `julia` that will load the cache:
///
/// ```julia
/// Sys.KERNEL, Sys.ARCH, Base.VERSION,
/// Base.GIT_VERSION_INFO.branch, Base.GIT_VERSION_INFO.commit
/// ```
///
/// Verified equal to the bytes in every `.ji` on this host by
/// `tools/diff_harness/jicache.sh`.
pub const PreambleExpectation = struct {
    /// `JL_BUILD_UNAME`, e.g. "Linux".
    build_uname: []const u8,
    /// `JL_BUILD_ARCH`, e.g. "x86_64".
    build_arch: []const u8,
    /// `JULIA_VERSION_STRING`, e.g. "1.12.6".
    julia_version: []const u8,
    git_branch: []const u8,
    git_commit: []const u8,
};

/// `fixup_stdlib_path` (`methodshow.jl:130-148`), reduced to the substitution
/// that actually fires: a Julia built somewhere other than where it is
/// installed records stdlib sources under `Sys.BUILD_STDLIB_PATH`, and the
/// loader maps them onto `Sys.STDLIB` before deciding a file is missing
/// (`loading.jl:3924-3928`). On this host the two differ
/// (`/build/julia-1.12.6/usr/...` vs `/nix/store/...`), so it is not
/// hypothetical.
///
/// Julia `normpath`s both sides first. Ajt substitutes literally: every path in
/// a `.ji` was written by `abspath`, so it is already normal, and a path that
/// is not merely fails to be fixed up — which costs a recompile, never a
/// mis-load. The `Core.Compiler` branch of `fixup_stdlib_path` is not modelled;
/// package caches do not `include()` compiler sources, and on this host the
/// folder it compares against is a relative path that matches nothing.
pub const StdlibFixup = struct {
    build_stdlib_path: []const u8,
    stdlib_path: []const u8,
};

pub const VerifyOptions = struct {
    /// `DEPOT_PATH`, in order. Used to resolve `@depot` tags.
    depot_path: []const []const u8,
    /// `_cacheflag_to_uint8(CacheFlags())` for the loading `julia`.
    requested_flags: u8 = CacheFlags.default.toU8(),
    /// `JLOptions().use_pkgimages != 0` (`loading.jl:4003`).
    use_pkgimages: bool = true,
    /// No default on purpose — see `PreambleExpectation`.
    expect: PreambleExpectation,
    /// The `.so` beside the `.ji` (`ocachefile_from_cachefile`). Required when
    /// the header carries clone targets; `null` skips both the existence check
    /// and the pkgimage crc.
    ocachefile: ?[]const u8 = null,
    /// This machine's `jl_reflect_clone_targets()` blob.
    ///
    /// The authoritative check is `jl_check_pkgimage_clones`, C code that tests
    /// whether any target in the image is a feature-subset of this CPU; it
    /// cannot be ported without the per-architecture feature tables. Ajt
    /// substitutes byte equality of the blob, which is STRICTLY STRONGER: it
    /// can reject an object Julia would have accepted (cost: one recompile) and
    /// can never accept one Julia would reject. `null` skips the check.
    clone_targets: ?[]const u8 = null,
    /// The `PkgId` the caller asked for. `null` skips the check, exactly as
    /// `stale_cachefile(modpath, cachefile)` passes `PkgId("")`
    /// (`loading.jl:3968-3970`).
    modkey: ?PkgId = null,
    /// The `UInt128` build id the caller requires (`loading.jl:4033-4039`).
    build_id: ?u128 = null,
    /// The package source file the cache is supposed to be for. Compared with
    /// `includes[1].filename` (`loading.jl:4104-4113`). Julia uses `samefile`,
    /// i.e. device+inode; Zig 0.16's `Io.File.Stat` exposes no device, so this
    /// compares the paths after resolving symlinks. The two differ only for
    /// hard links, and only in the strict direction.
    modpath: ?[]const u8 = null,
    /// The modules available to satisfy `required_modules`, with their full
    /// `UInt128` build ids. This is the dependency-closure check
    /// (`loading.jl:4044-4079`): every required module must be present at
    /// exactly the build id recorded here. `null` skips it.
    available: ?[]const ModuleEntry = null,
    /// The merged preferences for this environment, as
    /// `julia/preferences.zig` produces them. `null` models
    /// `get_preferences_hash`'s `uuid === nothing` short circuit, which returns
    /// 0 (`loading.jl:3819-3822`), so pass `null` only when that is what you
    /// mean.
    prefs: ?*const Table = null,
    /// `isvalid_file_crc` (`loading.jl:3358`) over the whole file. Cheap
    /// (~1 GB/s) and it is the check that catches a truncated or corrupted
    /// download, so it defaults on.
    check_file_crc: bool = true,
    stdlib_fixup: ?StdlibFixup = null,
};

/// `error.Canceled` is deliberately in here rather than being folded into a
/// staleness verdict: a cancelled I/O is not evidence that anyone's source file
/// changed, and reporting it as "include_dependency fhash change" would send a
/// person looking at the wrong thing.
pub const VerifyError = Allocator.Error || preferences.HashError || error{Canceled};

/// Everything `stale_cachefile` (`loading.jl:3971-4152`) decides, minus the
/// parts that need a live Julia, in Julia's order.
///
/// Returns `null` when the object is acceptable, or the first rejection.
/// `hdr` is mutated: `restoreDepots` runs first, exactly as `stale_cachefile`
/// calls the public `parse_cache_header`.
///
/// Two checks are deliberately not performed, and both are named here so a
/// reader does not assume they were forgotten:
///
///   * **`requires`** (`loading.jl:4114-4121`) verifies that
///     `identify_package(from, to.name) == to`, which needs the full load-path
///     resolver. The `available` closure check covers the case that matters for
///     an imported object: a cache built against a different `Foo` names a
///     different build id for it, and that is rejected at
///     `wrong_dep_buildid`.
///   * **`maybe_loaded_precompile` / `_concrete_dependencies`**
///     (`loading.jl:4048-4094`) are about modules already loaded in a running
///     session. An importer has no session.
///
/// `arena` holds the rejection detail and the paths built while resolving
/// depots.
pub fn verify(
    arena: Allocator,
    io: Io,
    bytes: []const u8,
    hdr: *Header,
    opts: VerifyOptions,
) VerifyError!?Rejection {
    // --- the preamble's identity strings (jl_read_verify_header) -----------
    if (try checkPreamble(arena, hdr.preamble, opts.expect)) |r| return r;

    // `if isempty(modules) return true` (loading.jl:3988-3990).
    if (hdr.modules.len == 0) {
        return reject(arena, .empty_module_list, "cache file declares no modules", .{});
    }

    // --- flags (loading.jl:3993-4000) --------------------------------------
    if (!matchCacheFlags(opts.requested_flags, hdr.flags)) {
        return reject(arena, .mismatched_flags, "requested flags {x:0>2} != cache flags {x:0>2}", .{
            opts.requested_flags, hdr.flags,
        });
    }

    // --- pkgimage (loading.jl:4001-4024) -----------------------------------
    if (hdr.isPkgimage()) {
        if (!opts.use_pkgimages) {
            return reject(arena, .requires_pkgimages, "cache carries native code but pkgimages are disabled", .{});
        }
        if (opts.clone_targets) |want| {
            if (!std.mem.eql(u8, want, hdr.clone_targets)) {
                return reject(arena, .target_mismatch, "cache was built for a different CPU target set ({d} bytes vs {d})", .{
                    hdr.clone_targets.len, want.len,
                });
            }
        }
        if (opts.ocachefile) |so| {
            if (!try existsPath(io, so)) {
                return reject(arena, .missing_ocachefile, "pkgimage {s} was not found", .{so});
            }
        }
    }

    // --- identity (loading.jl:4025-4040) -----------------------------------
    const first = hdr.modules[0];
    if (opts.modkey) |want| {
        // `id.first != modkey && modkey != PkgId("")` (`loading.jl:4029`): the
        // empty PkgId DISABLES the check rather than being something to match,
        // which is how `stale_cachefile(modpath, cachefile)` asks the question
        // without naming a package (`loading.jl:3968-3970`).
        if (!want.eql(PkgId.none) and !want.eql(first.id)) {
            return reject(arena, .for_different_pkgid, "cache is for {s}, not {s}", .{ first.id.name, want.name });
        }
    }
    const id_build = hdr.fullBuildId(first);
    if (opts.build_id) |want| {
        if (want != 0 and id_build != want) {
            return reject(arena, .for_different_buildid, "cache provides build id 0x{x:0>32}, wanted 0x{x:0>32}", .{ id_build, want });
        }
    }

    // --- dependency closure (loading.jl:4044-4079) -------------------------
    if (opts.available) |available| {
        for (hdr.required_modules) |req| {
            const found = for (available) |a| {
                if (a.id.eql(req.id)) break a;
            } else null;
            const got = found orelse return reject(
                arena,
                .dep_missing_source,
                "required module {s} is not available",
                .{req.id.name},
            );
            if (got.build_id != req.build_id) {
                return reject(arena, .wrong_dep_buildid, "required module {s} is available at build id 0x{x:0>32}, cache wants 0x{x:0>32}", .{
                    req.id.name, got.build_id, req.build_id,
                });
            }
        }
    }

    // Everything below reads paths out of the header, so the tags must go
    // first. `stale_cachefile` gets this for free by calling the public
    // `parse_cache_header` (loading.jl:3991).
    try restoreDepots(arena, io, hdr, opts.depot_path);

    // --- the cache is for this source file (loading.jl:4104-4113) ----------
    if (opts.modpath) |want| {
        if (hdr.includes.len == 0) {
            return reject(arena, .wrong_source, "cache records no include() files", .{});
        }
        const got = hdr.includes[0].filename;
        if (!try sameFile(arena, io, got, want, opts.stdlib_fixup)) {
            return reject(arena, .wrong_source, "cache is for file {s}, not {s}", .{ got, want });
        }
    }

    // --- any_includes_stale (loading.jl:3916-3964) -------------------------
    if (try includesStale(arena, io, hdr, opts)) |r| return r;

    // --- isvalid_file_crc (loading.jl:4123-4127) ---------------------------
    if (opts.check_file_crc) {
        if (bytes.len < 4) {
            return reject(arena, .invalid_checksum, "file is too short to carry a checksum", .{});
        }
        const want = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
        const got = Crc32c.hash(bytes[0 .. bytes.len - 4]);
        if (got != want) {
            return reject(arena, .invalid_checksum, "crc32c is 0x{x:0>8}, header says 0x{x:0>8}", .{ got, want });
        }
    }

    // --- isvalid_pkgimage_crc (loading.jl:3360-3366, 4129-4134) ------------
    if (hdr.isPkgimage() and opts.ocachefile != null and bytes.len >= 8) {
        const want = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
        const got = (try crc32cFile(io, opts.ocachefile.?)) orelse {
            return reject(arena, .ocachefile_invalid_checksum, "could not read pkgimage {s}", .{opts.ocachefile.?});
        };
        if (got != want) {
            return reject(arena, .ocachefile_invalid_checksum, "pkgimage {s} hashes to 0x{x:0>8}, cache says 0x{x:0>8}", .{ opts.ocachefile.?, got, want });
        }
    }

    // --- prefs_hash (loading.jl:4136-4142) ---------------------------------
    const curr = try preferences.preferencesHash(opts.prefs, hdr.prefs);
    if (curr != hdr.prefs_hash) {
        return reject(arena, .preferences_hash_mismatch, "preferences hash is 0x{x:0>16}, cache was built with 0x{x:0>16}", .{ curr, hdr.prefs_hash });
    }

    return null;
}

/// The format version, BOM and pointer size are already fatal in
/// `parsePreamble`, so what is left here is the five identity strings.
fn checkPreamble(arena: Allocator, p: Preamble, e: PreambleExpectation) Allocator.Error!?Rejection {
    const pairs = [_]struct { got: []const u8, want: []const u8, what: []const u8 }{
        .{ .got = p.build_uname, .want = e.build_uname, .what = "kernel" },
        .{ .got = p.build_arch, .want = e.build_arch, .what = "architecture" },
        .{ .got = p.julia_version, .want = e.julia_version, .what = "julia version" },
        .{ .got = p.git_branch, .want = e.git_branch, .what = "git branch" },
        .{ .got = p.git_commit, .want = e.git_commit, .what = "git commit" },
    };
    for (pairs) |pr| {
        if (!std.mem.eql(u8, pr.want, pr.got)) {
            return reject(arena, .incompatible_header, "cache {s} is {s}, this julia is {s}", .{ pr.what, pr.got, pr.want });
        }
    }
    return null;
}

/// `any_includes_stale` (`loading.jl:3916-3964`).
///
/// The first branch is the load-bearing one for a shared cache: a filename that
/// still starts with `@depot/` here means `restoreDepots` could not place it,
/// and the answer is an immediate rejection — never a guess. That is what makes
/// an optimistic import safe: the worst case is the recompile that would have
/// happened anyway.
fn includesStale(arena: Allocator, io: Io, hdr: *const Header, opts: VerifyOptions) VerifyError!?Rejection {
    for (hdr.includes) |inc| {
        const f = inc.filename;
        if (std.mem.startsWith(u8, f, depot_tag ++ [_]u8{pathsep})) {
            return reject(arena, .nonresolveable_depot, "no depot on DEPOT_PATH contains {s}", .{f});
        }
        const stat = try statPath(io, f);
        if (stat == null) {
            // The stdlib-relocation fallback (loading.jl:3924-3928).
            const fixed = try fixupStdlibPath(arena, f, opts.stdlib_fixup);
            if (!std.mem.eql(u8, fixed, f)) {
                if (try statPath(io, fixed)) |st| {
                    if (st.kind == .file and
                        std.mem.startsWith(u8, fixed, opts.stdlib_fixup.?.stdlib_path))
                    {
                        continue;
                    }
                }
            }
            return reject(arena, .missing_sourcefile, "{s} does not exist", .{f});
        }
        if (inc.mtime >= 0.0) {
            const ftime = timestampSeconds(stat.?.mtime);
            if (mtimeIsStale(ftime, inc.mtime)) {
                return reject(arena, .include_dependency_mtime_change, "mtime of include_dependency {s} has changed (mtime {d}, before {d})", .{ f, ftime, inc.mtime });
            }
        } else {
            // No exemption for directories: `any_includes_stale` compares
            // `filesize(fstat)` unconditionally (`loading.jl:3949-3953`) and
            // `_include_dependency!` records a directory's real `st_size`
            // (`loading.jl:2276-2278`). A directory's size and its
            // `join(readdir(...))` decouple — adding and removing files can
            // leave the listing identical while `st_size` grows — so skipping
            // this check accepts a cache Julia would reject.
            if (stat.?.size != inc.fsize) {
                return reject(arena, .include_dependency_fsize_change, "file size of {s} has changed (file size {d}, before {d})", .{ f, stat.?.size, inc.fsize });
            }
            const hash = if (stat.?.kind == .directory)
                try crc32cDirListing(arena, io, f)
            else
                try crc32cFile(io, f);
            const got = hash orelse return reject(arena, .missing_sourcefile, "{s} could not be read", .{f});
            if (got != inc.hash) {
                return reject(arena, .include_dependency_fhash_change, "hash of {s} has changed (hash {d}, before {d})", .{ f, got, inc.hash });
            }
        }
    }
    return null;
}

/// The mtime staleness expression at `loading.jl:3936-3942`, fudge factors and
/// all. Every one of those six clauses is a bug report about a filesystem or a
/// CI cache mangling timestamps, and together they are the argument for
/// refusing to publish an mtime-tracked dependency rather than trying to make
/// one survive a transfer.
fn mtimeIsStale(ftime: f64, ftime_req: f64) bool {
    if (ftime == ftime_req) return false;
    if (ftime == @floor(ftime_req)) return false; // Docker image mtime rounding
    if (ftime == @ceil(ftime_req)) return false; // CircleCI cache truncation
    if (ftime == truncDigits6(ftime_req)) return false; // GlusterFS microseconds
    if (ftime == 1.0) return false; // Nix sets mtime to 1
    if (0 < (ftime_req - ftime) and (ftime_req - ftime) < 1e-6) return false; // Windows tar
    return true;
}

/// `trunc(x, digits=6)`, which is `round(x * 10^6, RoundToZero) / 10^6`
/// (`Base._round_invstep`). Pinned against Julia in the tests below rather than
/// reasoned about; the intermediate rounding is observable
/// (`1234.9999995 -> 1234.999999`).
fn truncDigits6(x: f64) f64 {
    return @trunc(x * 1e6) / 1e6;
}

/// `mtime(path)`, which is `(double)tv_sec + tv_nsec * 1e-9` in libuv, not
/// `nanoseconds / 1e9` — the two round differently.
fn timestampSeconds(t: Io.Timestamp) f64 {
    const ns_per_s = std.time.ns_per_s;
    const sec = @divFloor(t.nanoseconds, ns_per_s);
    const nsec = t.nanoseconds - sec * ns_per_s;
    return @as(f64, @floatFromInt(sec)) + @as(f64, @floatFromInt(nsec)) * 1e-9;
}

fn fixupStdlibPath(arena: Allocator, path: []const u8, fixup: ?StdlibFixup) Allocator.Error![]const u8 {
    const fx = fixup orelse return path;
    if (!std.mem.startsWith(u8, path, fx.build_stdlib_path)) return path;
    return std.mem.concat(arena, u8, &.{ fx.stdlib_path, path[fx.build_stdlib_path.len..] });
}

fn reject(
    arena: Allocator,
    r: Reason,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!?Rejection {
    return Rejection{ .reason = r, .detail = try std.fmt.allocPrint(arena, fmt, args) };
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------

/// `ispath` — follows symlinks, true for any file type.
///
/// Every error except cancellation means "not there": Julia's `ispath` is a
/// `stat` whose failure is indistinguishable from absence, so matching it is
/// matching Julia. Cancellation is not a filesystem fact and propagates.
fn existsPath(io: Io, path: []const u8) error{Canceled}!bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return true;
}

fn statPath(io: Io, path: []const u8) error{Canceled}!?Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => null,
    };
}

/// `samefile(a, b)`, approximated by comparing symlink-resolved paths. See
/// `VerifyOptions.modpath`.
fn sameFile(arena: Allocator, io: Io, a: []const u8, b: []const u8, fixup: ?StdlibFixup) VerifyError!bool {
    if (std.mem.eql(u8, a, b)) return true;
    const fa = try fixupStdlibPath(arena, a, fixup);
    if (std.mem.eql(u8, fa, b)) return true;
    var buf_a: [Io.Dir.max_path_bytes]u8 = undefined;
    var buf_b: [Io.Dir.max_path_bytes]u8 = undefined;
    const na = Io.Dir.cwd().realPathFile(io, fa, &buf_a) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    const nb = Io.Dir.cwd().realPathFile(io, b, &buf_b) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return std.mem.eql(u8, buf_a[0..na], buf_b[0..nb]);
}

/// `open(_crc32c, f, "r")` — streamed, because an include can be any size and a
/// verify pass walks hundreds of them.
fn crc32cFile(io: Io, path: []const u8) error{Canceled}!?u32 {
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer file.close(io);
    var crc = Crc32c.init();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var one = [_][]u8{&buf};
        // End of stream is an ERROR here, not a zero-length read, and a short
        // read is legal at any point (`Io/File.zig:467-471`). Treating 0 as EOF
        // hashes an empty prefix and reports every file as changed.
        const n = file.readStreaming(io, &one) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Canceled => return error.Canceled,
            else => return null,
        };
        crc.update(buf[0..n]);
    }
    return crc.final();
}

/// `_crc32c(join(readdir(f)))` for a directory dependency
/// (`loading.jl:3955`). `readdir` sorts, and `join` uses no separator.
fn crc32cDirListing(arena: Allocator, io: Io, path: []const u8) VerifyError!?u32 {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    }) |e| {
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    var crc = Crc32c.init();
    for (names.items) |n| crc.update(n);
    return crc.final();
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "cache flag bits round-trip through Julia's layout" {
    // 0xA3 is what every .ji in a stock 1.12.6 depot carries; verified against
    // `Base.CacheFlags(0xa3)` == CacheFlags(use_pkgimages=true, debug_level=1,
    // check_bounds=0, inline=true, opt_level=2).
    const f = CacheFlags.fromU8(0xa3);
    try testing.expect(f.use_pkgimages);
    try testing.expectEqual(@as(u2, 1), f.debug_level);
    try testing.expectEqual(@as(u2, 0), f.check_bounds);
    try testing.expect(f.inlining);
    try testing.expectEqual(@as(u2, 2), f.opt_level);
    try testing.expectEqual(@as(u8, 0xa3), f.toU8());
    try testing.expectEqual(@as(u8, 0xa3), CacheFlags.default.toU8());

    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        const x: u8 = @intCast(b);
        try testing.expectEqual(x, CacheFlags.fromU8(x).toU8());
    }
}

test "matchCacheFlags reproduces jl_match_cache_flags" {
    // Spot values lifted from the ccall'd truth table; the harness re-checks
    // all 65536 pairs.
    //
    // Both plain .ji: everything else is ignored.
    try testing.expect(matchCacheFlags(0b0000_0000, 0b1111_1110));
    // pkgimage bits must agree once either side wants one.
    try testing.expect(!matchCacheFlags(0b0000_0001, 0b0000_0000));
    try testing.expect(!matchCacheFlags(0b0000_0000, 0b0000_0001));
    // debug_level may be HIGHER in the cache (req 0b1 vs act 0b11 => match).
    try testing.expect(matchCacheFlags(0b0000_0001, 0b0000_0011));
    try testing.expect(!matchCacheFlags(0b0000_0011, 0b0000_0001));
    // opt_level may be higher too.
    try testing.expect(matchCacheFlags(0b0100_0001, 0b1000_0001));
    try testing.expect(!matchCacheFlags(0b1000_0001, 0b0100_0001));
    // check_bounds and inline must match exactly.
    try testing.expect(!matchCacheFlags(0b0000_1001, 0b0001_0001));
    try testing.expect(!matchCacheFlags(0b0010_0001, 0b0000_0001));
    // The real-world case: the depot's 0xa3 against a default request.
    try testing.expect(matchCacheFlags(0xa3, 0xa3));
}

test "uuid decoding follows read_module_list, not binunpack" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // SimpleTraits, read out of ~/.julia/compiled/v1.12/SimpleTraits/pLp8z_3FUgb.ji:
    // the module list stores hi=0x699a6c99e7fa54fc lo=0x8d7647d257e15c1d and
    // Julia reports 699a6c99-e7fa-54fc-8d76-47d257e15c1d.
    const hi: u64 = 0x699a6c99e7fa54fc;
    const lo: u64 = 0x8d7647d257e15c1d;
    const u = uuidFromU128((@as(u128, hi) << 64) | @as(u128, lo)).?;
    try testing.expectEqualStrings(
        "699a6c99-e7fa-54fc-8d76-47d257e15c1d",
        try uuidText(arena, u),
    );

    // binunpack reads the SAME type in the opposite word order: a
    // little-endian UInt128, low word first.
    var packed_bytes: [17 + 10]u8 = undefined;
    packed_bytes[0] = 0;
    std.mem.writeInt(u128, packed_bytes[1..17], (@as(u128, hi) << 64) | @as(u128, lo), .little);
    @memcpy(packed_bytes[17..], "MacroTools"[0..10]);
    const id = try binunpack(&packed_bytes);
    try testing.expectEqualStrings("MacroTools", id.name);
    try testing.expectEqualStrings(
        "699a6c99-e7fa-54fc-8d76-47d257e15c1d",
        try uuidText(arena, id.uuid.?),
    );

    // A zero UUID is Julia's `nothing`.
    try testing.expectEqual(@as(?Uuid, null), uuidFromU128(0));

    // Every byte gets two hex digits: a leading-zero group is where a
    // hand-rolled formatter silently loses a nibble.
    try testing.expectEqualStrings(
        "00000001-0002-0003-0004-000000000506",
        try uuidText(arena, uuidFromU128(0x00000001_0002_0003_0004_000000000506).?),
    );
}

test "restore_depot_path and resolve_depot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "/home/u/.julia/packages/A/xyz/src/A.jl",
        try restoreDepotPath(arena, "@depot/packages/A/xyz/src/A.jl", "/home/u/.julia"),
    );
    // The regex is `^@depot` with no separator requirement, which is how
    // `_read_dependency_src` strips the tag.
    try testing.expectEqualStrings(
        "/packages/A/xyz/src/A.jl",
        try restoreDepotPath(arena, "@depot/packages/A/xyz/src/A.jl", ""),
    );
    // An absolute path is untouched.
    try testing.expectEqualStrings(
        "/abs/path.jl",
        try restoreDepotPath(arena, "/abs/path.jl", "/depot"),
    );

    // resolve_depot, unlike restore_depot_path, insists on the separator.
    const io = testing.io;
    try testing.expectEqual(
        DepotResolution.not_relocatable,
        try resolveDepot(arena, io, "/abs/path.jl", &.{}),
    );
    try testing.expectEqual(
        DepotResolution.not_relocatable,
        try resolveDepot(arena, io, "@depotish/path.jl", &.{}),
    );
    try testing.expectEqual(
        DepotResolution.no_depot_found,
        try resolveDepot(arena, io, "@depot/packages/A/xyz/src/A.jl", &.{"/nonexistent-depot"}),
    );
}

test "trunc(x, digits=6) matches Julia bit for bit" {
    // Generated by `julia -e 'trunc(x, digits=6)'`; the intermediate rounding
    // is observable, so these are pinned rather than reasoned about.
    const cases = [_]struct { x: u64, want: u64 }{
        .{ .x = 0x3ff0000000000000, .want = 0x3ff0000000000000 }, // 1.0
        .{ .x = 0x41da21125807e6b7, .want = 0x41da21125807e6b4 }, // 1.7535000001234567e9
        .{ .x = 0x41da211258200000, .want = 0x41da211258200000 }, // 1.7535000005e9
        .{ .x = 0x40934bffffde7211, .want = 0x40934bffffbce421 }, // 1234.9999995 -> 1234.999999
        .{ .x = 0x0000000000000000, .want = 0x0000000000000000 }, // 0.0
        .{ .x = 0x41cdcd6500000008, .want = 0x41cdcd6500000008 }, // 1.000000000000001e9
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, @as(u64, @bitCast(truncDigits6(@bitCast(c.x)))));
    }
}

test "mtime staleness reproduces every fudge factor" {
    const req: f64 = 1753500000.123456789;
    // Exact match.
    try testing.expect(!mtimeIsStale(req, req));
    // Docker rounds down, CircleCI rounds up.
    try testing.expect(!mtimeIsStale(@floor(req), req));
    try testing.expect(!mtimeIsStale(@ceil(req), req));
    // GlusterFS truncates to microseconds.
    try testing.expect(!mtimeIsStale(truncDigits6(req), req));
    // Nix stamps everything with 1.
    try testing.expect(!mtimeIsStale(1.0, req));
    // Windows tar can be up to a microsecond EARLY (and only early).
    try testing.expect(!mtimeIsStale(req - 5e-7, req));
    try testing.expect(mtimeIsStale(req + 5e-7, req));
    // A real change.
    try testing.expect(mtimeIsStale(req + 10.0, req));
}

test "publishRefusal names the file that blocks publication" {
    var hdr: Header = .{
        .preamble = undefined,
        .flags = 0xa3,
        .modules = &.{},
        .includes = &.{},
        .requires = &.{},
        .prefs = &.{},
        .prefs_hash = 0,
        .srctextpos = 0,
        .required_modules = &.{},
        .clone_targets = &.{},
        .srctext_files = &.{},
    };

    var relocatable = [_]Include{
        .{ .id = .none, .filename = "@depot/packages/A/xyz/src/A.jl", .raw_filename = "@depot/packages/A/xyz/src/A.jl", .fsize = 1, .hash = 2, .mtime = -1.0, .modpath = &.{}, .is_srcfile = true },
    };
    hdr.includes = &relocatable;
    try testing.expect(isRelocatable(&hdr));
    try testing.expectEqual(@as(usize, 0), mtimeTrackedCount(&hdr));

    // An absolute path -- the shape every package developed out of a working
    // tree has.
    var absolute = [_]Include{
        .{ .id = .none, .filename = "/home/u/dev/A/src/A.jl", .raw_filename = "/home/u/dev/A/src/A.jl", .fsize = 1, .hash = 2, .mtime = -1.0, .modpath = &.{}, .is_srcfile = true },
    };
    hdr.includes = &absolute;
    try testing.expect(!isRelocatable(&hdr));
    try testing.expectEqualStrings("/home/u/dev/A/src/A.jl", publishRefusal(&hdr).?.path());
    try testing.expectEqualStrings(
        "include path is not @depot-relative",
        publishRefusal(&hdr).?.reason(),
    );

    // Relocatable, but tracked by mtime: an mtime does not survive a tarball.
    var by_mtime = [_]Include{
        .{ .id = .none, .filename = "@depot/packages/A/xyz/src/A.jl", .raw_filename = "@depot/packages/A/xyz/src/A.jl", .fsize = 1, .hash = 2, .mtime = -1.0, .modpath = &.{}, .is_srcfile = true },
        .{ .id = .none, .filename = "@depot/packages/A/xyz/deps/build.log", .raw_filename = "@depot/packages/A/xyz/deps/build.log", .fsize = 3, .hash = 4, .mtime = 1753500000.0, .modpath = &.{}, .is_srcfile = false },
    };
    hdr.includes = &by_mtime;
    try testing.expect(!isRelocatable(&hdr));
    try testing.expectEqual(@as(usize, 1), mtimeTrackedCount(&hdr));
    try testing.expectEqualStrings(
        "include_dependency is tracked by mtime, not content",
        publishRefusal(&hdr).?.reason(),
    );
}

test "reason strings are Julia's record_reason vocabulary" {
    // These exact strings appear in `JULIA_DEBUG=loading` output as
    // "(cache misses: <reason> (n))", so a divergence here makes an ajt
    // rejection and a julia rejection unrelatable.
    try testing.expectEqualStrings("nonresolveable depot", Reason.nonresolveable_depot.text());
    try testing.expectEqualStrings("include_dependency fhash change", Reason.include_dependency_fhash_change.text());
    try testing.expectEqualStrings("include_dependency fsize change", Reason.include_dependency_fsize_change.text());
    try testing.expectEqualStrings("include_dependency mtime change", Reason.include_dependency_mtime_change.text());
    try testing.expectEqualStrings("mismatched flags", Reason.mismatched_flags.text());
    try testing.expectEqualStrings("preferences hash mismatch", Reason.preferences_hash_mismatch.text());
    try testing.expectEqualStrings("invalid checksum", Reason.invalid_checksum.text());
}

// --- a synthetic .ji, built to the layout above -----------------------------
//
// Round-tripping a hand-built file is the only way to unit-test the parser
// without a depot; the harness does the real work against every .ji on the
// machine.

/// The identity strings `buildSyntheticJi` writes, i.e. what this host's julia
/// reports (`Sys.KERNEL`, `Sys.ARCH`, `Base.VERSION`,
/// `Base.GIT_VERSION_INFO.branch/.commit`).
const synthetic_expect: PreambleExpectation = .{
    .build_uname = "Linux",
    .build_arch = "x86_64",
    .julia_version = "1.12.6",
    .git_branch = "HEAD",
    .git_commit = "15346901f0039751c5488744f1f62de7d87510a8",
};

const Builder = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn bytes(self: *Builder, b: []const u8) !void {
        try self.buf.appendSlice(self.gpa, b);
    }
    fn u8v(self: *Builder, v: u8) !void {
        try self.buf.append(self.gpa, v);
    }
    fn int(self: *Builder, comptime T: type, v: T) !void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.bytes(&tmp);
    }
    fn cstr(self: *Builder, s: []const u8) !void {
        try self.bytes(s);
        try self.u8v(0);
    }
    /// An i32 length followed by the bytes.
    fn lenStr(self: *Builder, s: []const u8) !void {
        try self.int(i32, @intCast(s.len));
        try self.bytes(s);
    }
};

fn buildSyntheticJi(gpa: Allocator, opts: struct {
    include_hash: u32 = 0x11223344,
    include_name: []const u8 = "@depot/packages/A/xyz/src/A.jl",
    flags: u8 = 0xa3,
}) ![]u8 {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);

    try b.bytes(magic);
    try b.int(u16, 12);
    try b.int(u16, bom);
    try b.u8v(8);
    try b.cstr("Linux");
    try b.cstr("x86_64");
    try b.cstr("1.12.6");
    try b.cstr("HEAD");
    try b.cstr("15346901f0039751c5488744f1f62de7d87510a8");
    try b.u8v(0); // not a pkgimage
    try b.int(u64, 0xfafbfcfd_deadbeef);
    try b.int(i64, 0);
    try b.int(i64, 0);
    const header_offset = b.buf.items.len;
    try testing.expectEqual(@as(usize, 104), header_offset);

    try b.u8v(opts.flags);
    // modules: one entry, no build-id high word.
    try b.lenStr("A");
    try b.int(u64, 0x0102030405060708); // uuid hi
    try b.int(u64, 0x090a0b0c0d0e0f10); // uuid lo
    try b.int(u64, 0xcafef00dbaadf00d); // build id (low word only)
    try b.int(i32, 0); // end of module list

    // Build the dependency + preference sections separately so totbytes can be
    // computed the way the writer does: as their exact byte length.
    var dep: Builder = .{ .gpa = gpa };
    defer dep.buf.deinit(gpa);
    // one include, owned by module 1
    try dep.lenStr(opts.include_name);
    try dep.int(u64, 6); // fsize
    try dep.int(u32, opts.include_hash);
    try dep.int(u64, @bitCast(@as(f64, -1.0))); // mtime
    try dep.int(i32, 1); // module index
    try dep.lenStr("A"); // modpath
    try dep.int(i32, 0); // end of modpath
    // one `requires` record: binpack(PkgId(uuid, "B")) begins with NUL
    var req_name: std.ArrayList(u8) = .empty;
    defer req_name.deinit(gpa);
    try req_name.append(gpa, 0);
    var uuid_bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &uuid_bytes, 0x1914dd2f81c65fcd87196d5c9610ff09, .little);
    try req_name.appendSlice(gpa, &uuid_bytes);
    try req_name.appendSlice(gpa, "B");
    try dep.lenStr(req_name.items);
    try dep.int(u64, 0);
    try dep.int(u32, 0);
    try dep.int(u64, @bitCast(@as(f64, -1.0)));
    try dep.int(i32, 0); // module index 0 -> PkgId("")
    try dep.int(i32, 0); // end of dependency records
    // preferences
    try dep.lenStr("some_pref");
    try dep.int(i32, 0); // end of preferences

    // prefs_hash and srctextpos are inside the budget too.
    const totbytes: u64 = dep.buf.items.len + 8 + 8;
    try b.int(u64, totbytes);
    try b.bytes(dep.buf.items);
    try b.int(u64, 0); // prefs_hash
    const srctextpos_at = b.buf.items.len;
    try b.int(i64, 0); // patched below

    // required_modules, WITH the build-id high word.
    try b.lenStr("Base");
    try b.int(u64, 0);
    try b.int(u64, 0);
    try b.int(u64, 0xfdfcfbfa9bf6bd1d);
    try b.int(u64, 0x0446df671eedd9e7);
    try b.int(i32, 0);

    // clone_targets: one target named "native", no features.
    var ct: Builder = .{ .gpa = gpa };
    defer ct.buf.deinit(gpa);
    try ct.int(i32, 1);
    try ct.int(i32, 0); // flags
    try ct.int(i32, 0); // nfeature
    try ct.lenStr("native");
    try ct.lenStr(""); // ext_features
    try b.int(i32, @intCast(ct.buf.items.len));
    try b.bytes(ct.buf.items);

    // srctext section: the include's source, then the zero sentinel.
    const srctextpos = b.buf.items.len;
    std.mem.writeInt(i64, b.buf.items[srctextpos_at..][0..8], @intCast(srctextpos), .little);
    try b.lenStr(opts.include_name);
    try b.int(u64, 6);
    try b.bytes("hello\n");
    try b.int(i32, 0);

    // trailer: pkgimage crc, then the file crc over everything before it.
    try b.int(u32, 0xdeadbeef);
    const crc = Crc32c.hash(b.buf.items);
    try b.int(u32, crc);

    return b.buf.toOwnedSlice(gpa);
}

test "parse round-trips a synthetic .ji" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hdr = try parse(arena, raw);

    try testing.expectEqual(@as(u16, 12), hdr.preamble.format_version);
    try testing.expectEqual(@as(u8, 8), hdr.preamble.pointer_size);
    try testing.expectEqualStrings("Linux", hdr.preamble.build_uname);
    try testing.expectEqualStrings("x86_64", hdr.preamble.build_arch);
    try testing.expectEqualStrings("1.12.6", hdr.preamble.julia_version);
    try testing.expectEqualStrings("HEAD", hdr.preamble.git_branch);
    try testing.expectEqual(@as(u64, 0xfafbfcfd_deadbeef), hdr.preamble.checksum);
    try testing.expectEqual(@as(usize, 104), hdr.preamble.header_offset);

    try testing.expectEqual(@as(u8, 0xa3), hdr.flags);
    try testing.expectEqual(@as(usize, 1), hdr.modules.len);
    try testing.expectEqualStrings("A", hdr.modules[0].id.name);
    // The low word only; the high word comes from the preamble checksum.
    try testing.expectEqual(@as(u128, 0xcafef00dbaadf00d), hdr.modules[0].build_id);
    try testing.expectEqual(
        (@as(u128, 0xfafbfcfd_deadbeef) << 64) | 0xcafef00dbaadf00d,
        hdr.fullBuildId(hdr.modules[0]),
    );

    try testing.expectEqual(@as(usize, 1), hdr.includes.len);
    try testing.expectEqualStrings("@depot/packages/A/xyz/src/A.jl", hdr.includes[0].filename);
    try testing.expectEqual(@as(u64, 6), hdr.includes[0].fsize);
    try testing.expectEqual(@as(u32, 0x11223344), hdr.includes[0].hash);
    try testing.expectEqual(@as(f64, -1.0), hdr.includes[0].mtime);
    try testing.expectEqualStrings("A", hdr.includes[0].id.name);
    try testing.expectEqual(@as(usize, 1), hdr.includes[0].modpath.len);
    // Its source text IS stored, so it is an include(), not an
    // include_dependency().
    try testing.expect(hdr.includes[0].is_srcfile);

    // The NUL-prefixed record went to `requires`, not to `includes`.
    try testing.expectEqual(@as(usize, 1), hdr.requires.len);
    try testing.expectEqualStrings("B", hdr.requires[0].to.name);
    try testing.expectEqual(@as(?Uuid, null), hdr.requires[0].from.uuid);

    try testing.expectEqual(@as(usize, 1), hdr.prefs.len);
    try testing.expectEqualStrings("some_pref", hdr.prefs[0]);
    try testing.expectEqual(@as(u64, 0), hdr.prefs_hash);

    try testing.expectEqual(@as(usize, 1), hdr.required_modules.len);
    try testing.expectEqual(
        (@as(u128, 0xfdfcfbfa9bf6bd1d) << 64) | 0x0446df671eedd9e7,
        hdr.required_modules[0].build_id,
    );

    try testing.expect(hdr.isPkgimage());
    const targets = try parseImageTargets(arena, hdr.clone_targets);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings("native", targets[0].name);

    try testing.expectEqual(@as(usize, 1), hdr.srctext_files.len);
    try testing.expect(isRelocatable(&hdr));
}

test "a truncated or damaged .ji is refused, not half-parsed" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Bad magic.
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        bad[1] = 'X';
        try testing.expectError(error.BadHeader, parse(arena, bad));
    }
    // Wrong BOM (i.e. the file came off a big-endian machine).
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        std.mem.writeInt(u16, bad[10..12], 0xFFFE, .little);
        try testing.expectError(error.BadHeader, parse(arena, bad));
    }
    // A format version this parser was not written against. Confirmed with
    // Julia: bumping the version makes `Base.isvalid_cache_header` answer 0, so
    // half-reading it would ACCEPT an object julia rejects.
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        std.mem.writeInt(u16, bad[8..10], ji_format_version + 1, .little);
        try testing.expectError(error.BadHeader, parse(arena, bad));
    }
    // A pointer size that is not this machine's — likewise fatal in julia.
    // 32 is also the value that used to overflow the `pointer_size * 8` in the
    // rejection message.
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        bad[12] = 32;
        try testing.expectError(error.BadHeader, parse(arena, bad));
        bad[12] = 4;
        try testing.expectError(error.BadHeader, parse(arena, bad));
    }
    // The preamble says pkgimage: `isvalid_cache_header` refuses these
    // outright (loading.jl:3352-3355).
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        bad[79] = 1;
        try testing.expectError(error.IsPkgimage, parse(arena, bad));
    }
    // Truncated mid-header.
    try testing.expectError(error.Truncated, parse(arena, raw[0 .. raw.len - 200]));
    // totbytes no longer adds up. Without this check the parse still finds the
    // zero sentinel and returns a plausible header.
    {
        const bad = try gpa.dupe(u8, raw);
        defer gpa.free(bad);
        // totbytes sits right after the module list terminator.
        const at = 104 + 1 + (4 + 1) + 8 + 8 + 8 + 4;
        const cur = std.mem.readInt(u64, bad[at..][0..8], .little);
        std.mem.writeInt(u64, bad[at..][0..8], cur + 1, .little);
        try testing.expectError(error.CorruptHeader, parse(arena, bad));
    }
}

test "every identity string is compared, and PkgId(\"\") disables the pkgid check" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each of the five in turn: `jl_read_verify_header` compares all of them,
    // and for a shared cache these are exactly the fields that differ when an
    // object was built by SOMEONE ELSE'S julia.
    const fields = [_][]const u8{ "build_uname", "build_arch", "julia_version", "git_branch", "git_commit" };
    inline for (fields) |f| {
        var hdr = try parse(arena, raw);
        var e = synthetic_expect;
        @field(e, f) = "definitely-not-what-the-file-says";
        const r = (try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = e,
        })).?;
        try testing.expectEqual(Reason.incompatible_header, r.reason);
    }

    // `PkgId("")` is how `stale_cachefile(modpath, cachefile)` asks without
    // naming a package (loading.jl:3968-3970, 4029). Treating it as a name to
    // match would reject every cache.
    {
        var hdr = try parse(arena, raw);
        const r = try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = synthetic_expect,
            .modkey = PkgId.none,
        });
        // It gets past the pkgid check; whatever it fails on next, it is not
        // that one.
        if (r) |rej| try testing.expect(rej.reason != .for_different_pkgid);
    }
    // A real, different key still rejects.
    {
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = synthetic_expect,
            .modkey = .{ .uuid = null, .name = "NotA" },
        })).?;
        try testing.expectEqual(Reason.for_different_pkgid, r.reason);
    }
}

test "publishRefusal is unaffected by restoreDepots" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "packages/A/xyz/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "packages/A/xyz/src/A.jl", .data = "hello\n" });
    var depot_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const depot = depot_buf[0..try tmp.dir.realPath(testing.io, &depot_buf)];

    var hdr = try parse(arena, raw);
    try testing.expect(isRelocatable(&hdr));

    // After restoration every filename is absolute. Asking the publish-side
    // question against `filename` would now answer "not relocatable" about a
    // cache that plainly is — and `verify` restores as a matter of course, so
    // that is the order a caller naturally ends up in.
    try restoreDepots(arena, testing.io, &hdr, &.{depot});
    try testing.expect(!std.mem.startsWith(u8, hdr.includes[0].filename, depot_tag));
    try testing.expect(isRelocatable(&hdr));
    try testing.expectEqual(@as(?PublishRefusal, null), publishRefusal(&hdr));
}

test "parseImageTargets refuses a count the blob cannot hold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An empty blob is EOF, not zero targets (loading.jl:1781).
    try testing.expectError(error.Truncated, parseImageTargets(arena, ""));

    // A four-byte blob claiming 2^30 targets would otherwise ask the allocator
    // for ~170 GB before reading a single target byte.
    var blob: [4]u8 = undefined;
    std.mem.writeInt(i32, &blob, 1 << 30, .little);
    try testing.expectError(error.CorruptHeader, parseImageTargets(arena, &blob));

    // …and a plausible count with an implausible feature vector.
    var blob2: [16]u8 = undefined;
    std.mem.writeInt(i32, blob2[0..4], 1, .little); // one target
    std.mem.writeInt(i32, blob2[4..8], 0, .little); // flags
    std.mem.writeInt(i32, blob2[8..12], 1 << 29, .little); // nfeature
    std.mem.writeInt(i32, blob2[12..16], 0, .little);
    try testing.expectError(error.CorruptHeader, parseImageTargets(arena, &blob2));
}

test "verify rejects an unresolvable @depot tag with a reason" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hdr = try parse(arena, raw);
    const r = (try verify(arena, testing.io, raw, &hdr, .{
        .depot_path = &.{"/definitely-not-a-depot"},
        .expect = synthetic_expect,
        .ocachefile = null,
    })).?;
    // This is the property the whole optimistic-import design rests on: an
    // unplaceable path is rejected, never guessed at.
    try testing.expectEqual(Reason.nonresolveable_depot, r.reason);
    try testing.expect(std.mem.indexOf(u8, r.detail, "@depot/packages/A/xyz/src/A.jl") != null);
}

test "verify rejects mismatched flags before touching the filesystem" {
    const gpa = testing.allocator;
    // opt_level 0 in the cache, opt_level 2 requested: the cache is less
    // optimized than asked for, which `jl_match_cache_flags` refuses.
    const raw = try buildSyntheticJi(gpa, .{ .flags = 0x23 });
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hdr = try parse(arena, raw);
    const r = (try verify(arena, testing.io, raw, &hdr, .{ .depot_path = &.{}, .expect = synthetic_expect })).?;
    try testing.expectEqual(Reason.mismatched_flags, r.reason);
}

test "verify rejects a wrong julia version and a wrong dep build id" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = blk: {
                var e = synthetic_expect;
                e.julia_version = "1.11.5";
                break :blk e;
            },
        })).?;
        try testing.expectEqual(Reason.incompatible_header, r.reason);
    }
    {
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = synthetic_expect,
            .available = &.{.{ .id = .{ .uuid = null, .name = "Base" }, .build_id = 1 }},
        })).?;
        try testing.expectEqual(Reason.wrong_dep_buildid, r.reason);
    }
    {
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{
            .depot_path = &.{},
            .expect = synthetic_expect,
            .available = &.{},
        })).?;
        try testing.expectEqual(Reason.dep_missing_source, r.reason);
    }
}

test "verify accepts a real-shaped cache and rejects a flipped include hash" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A depot on disk, with the include where the @depot tag says it is.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "packages/A/xyz/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "packages/A/xyz/src/A.jl", .data = "hello\n" });
    var depot_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const depot = depot_buf[0..try tmp.dir.realPath(testing.io, &depot_buf)];

    const good_hash = Crc32c.hash("hello\n");
    const raw = try buildSyntheticJi(gpa, .{ .include_hash = good_hash });
    defer gpa.free(raw);

    {
        var hdr = try parse(arena, raw);
        const r = try verify(arena, testing.io, raw, &hdr, .{ .depot_path = &.{depot}, .expect = synthetic_expect });
        if (r) |rej| {
            std.debug.print("unexpected rejection: {s}: {s}\n", .{ rej.reason.text(), rej.detail });
            return error.TestUnexpectedResult;
        }
        // …and the tag really was replaced by the depot on THIS machine.
        try testing.expect(std.mem.startsWith(u8, hdr.includes[0].filename, depot));
    }

    // One bit off in the recorded crc32c: this is the shape of a shared-cache
    // object whose source moved underneath it.
    {
        const bad = try buildSyntheticJi(gpa, .{ .include_hash = good_hash ^ 1 });
        defer gpa.free(bad);
        var hdr = try parse(arena, bad);
        const r = (try verify(arena, testing.io, bad, &hdr, .{ .depot_path = &.{depot}, .expect = synthetic_expect })).?;
        try testing.expectEqual(Reason.include_dependency_fhash_change, r.reason);
    }

    // A size change is reported before the hash, because it is cheaper.
    {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "packages/A/xyz/src/A.jl", .data = "hello!\n" });
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{ .depot_path = &.{depot}, .expect = synthetic_expect })).?;
        try testing.expectEqual(Reason.include_dependency_fsize_change, r.reason);
    }

    // And a missing file is its own reason.
    {
        try tmp.dir.deleteFile(testing.io, "packages/A/xyz/src/A.jl");
        var hdr = try parse(arena, raw);
        const r = (try verify(arena, testing.io, raw, &hdr, .{ .depot_path = &.{depot}, .expect = synthetic_expect })).?;
        // With the file gone the @depot tag no longer resolves, which is the
        // earlier and stricter of the two verdicts.
        try testing.expectEqual(Reason.nonresolveable_depot, r.reason);
    }
}

test "verify rejects a corrupted file crc" {
    const gpa = testing.allocator;
    const raw = try buildSyntheticJi(gpa, .{});
    defer gpa.free(raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Flip a byte inside a stored source-text BODY, which the parser skips
    // over: the header still parses cleanly, so only the trailing crc32c can
    // catch it. That is exactly the download corruption a shared cache has to
    // survive. Layout from the end: [4 file crc][4 .so crc][4 sentinel][6 body].
    const bad = try gpa.dupe(u8, raw);
    defer gpa.free(bad);
    bad[bad.len - 15] ^= 0xff;

    var hdr = try parse(arena, bad);
    const r = (try verify(arena, testing.io, bad, &hdr, .{
        .depot_path = &.{},
        .expect = synthetic_expect,
        .check_file_crc = true,
    })).?;
    // The depot check comes first in Julia's order; assert the crc separately.
    try testing.expectEqual(Reason.nonresolveable_depot, r.reason);

    const want = std.mem.readInt(u32, bad[bad.len - 4 ..][0..4], .little);
    try testing.expect(Crc32c.hash(bad[0 .. bad.len - 4]) != want);
    try testing.expectEqual(want, Crc32c.hash(raw[0 .. raw.len - 4]));
}
