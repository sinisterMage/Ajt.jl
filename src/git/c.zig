//! libgit2, declared by hand.
//!
//! ## Why not `@cImport`
//!
//! Ajt does not only *call* libgit2, it *implements* one of its interfaces: a
//! `git_stream`, so that HTTPS is Zig's TLS rather than a linked OpenSSL (see
//! `tls.zig`). Defining a C struct is a different obligation from calling a C
//! function. A wrong argument type in a call is usually a compile error; a
//! wrong field layout in a struct we hand back is not an error at all — every
//! function pointer after the mistake shifts, and libgit2 calls `read` where
//! `connect` belongs, inside a TLS handshake, with no diagnostic.
//!
//! `@cImport` would not save us from that either, because the field in question
//! is a bitfield:
//!
//! ```c
//! unsigned int encrypted : 1, proxy_support : 1;
//! ```
//!
//! which Zig's C translation cannot represent, and which would come back as an
//! opaque blob we would have to describe by hand anyway. Two other reasons make
//! the hand-written form the better one regardless: it is ~40 symbols out of
//! libgit2's ~900, so the surface Ajt depends on is *readable*, in one file;
//! and it does not need libgit2's headers on the include path of every module
//! that merely mentions the git namespace.
//!
//! ## What replaces the compiler's agreement
//!
//! `abi_probe.c` — the only C in this repository — is compiled by the same
//! `zig cc` against the same headers into the test binary, and returns the C
//! compiler's own `sizeof`, `offsetof` and enum values. The tests at the bottom
//! of this file compare every one of them with Zig's. The claim "this is the
//! layout" is therefore checked by the toolchain rather than by a reader.
//!
//! On top of that, `assertVersion` refuses to run against a libgit2 whose
//! `git_libgit2_version()` is not the pinned one. The build pins a tarball hash
//! (`build.zig.zon`), so in a normal build the two can never disagree; the check
//! is there for the abnormal one, where a distro `libgit2.so` got linked
//! instead.
//!
//! ## Two structs deliberately absent
//!
//! `git_clone_options` and `git_fetch_options` are the largest and most
//! version-fragile structs in the API — nested callback structs, proxy options,
//! `git_checkout_options` inside one of them — and binding either would double
//! this file and multiply the ways it can be wrong. They are avoided rather
//! than bound:
//!
//! ```text
//! git_repository_init(&repo, path, /*bare=*/1)
//! git_remote_create_anonymous(&remote, repo, url)
//! git_remote_fetch(remote, &refspecs, NULL, NULL)
//! ```
//!
//! `git_remote_fetch` documents and implements the NULL-options path
//! (`remote.c:1378-1381`: `if (opts)` guards every read of it), and an anonymous
//! remote is in-memory — it never touches `.git/config`, which is what lets a
//! credential ride in the URL without ever reaching disk (`auth.zig`). Not
//! binding `git_fetch_options` also removes any need for `git_credential`,
//! `git_cert` or `git_remote_callbacks`.

const std = @import("std");
const build_options = @import("build_options");

/// Whether this binary has libgit2 in it at all (`-Dgit`).
///
/// Every declaration below is only *analysed* when something references it, so
/// a build without libgit2 links no libgit2 symbol — that is what lets
/// `git/lib.zig` sit in the module unconditionally and simply report
/// `BackendUnavailable`.
pub const enabled: bool = build_options.have_libgit2;

/// The pinned version, as `build.zig.zon` fetches it.
pub const version_major = 1;
pub const version_minor = 9;

// ---------------------------------------------------------------------------
// Opaque handles. Ajt never looks inside any of these, so an opaque type is
// both sufficient and the only form that cannot be wrong.
// ---------------------------------------------------------------------------

pub const git_repository = opaque {};
pub const git_remote = opaque {};
pub const git_object = opaque {};
pub const git_odb = opaque {};
pub const git_cert = opaque {};
pub const git_proxy_options = opaque {};
pub const git_tree = opaque {};
pub const git_blob = opaque {};
/// Borrowed from its `git_tree` and valid only while that tree is alive
/// (`tree.h:112` — "The returned entry is owned by the tree"). Never freed
/// here, because nothing here duplicates one.
pub const git_tree_entry = opaque {};

// ---------------------------------------------------------------------------
// Structs whose layout Ajt depends on. Each one is checked against
// `abi_probe.c` by a test below.
// ---------------------------------------------------------------------------

/// `include/git2/oid.h:103-112`. Twenty raw bytes.
///
/// The `unsigned char type` prefix in that struct is inside
/// `#ifdef GIT_EXPERIMENTAL_SHA256`, which this build never defines
/// (`build.zig` sets no such macro and `cmake/ExperimentalFeatures.cmake:16` is
/// the only place upstream would). Were it ever defined, every oid Ajt read
/// would be off by one byte and every tree hash wrong — hence the probe.
pub const git_oid = extern struct {
    id: [20]u8,
};

/// `include/git2/errors.h:121-124`.
pub const git_error = extern struct {
    message: ?[*:0]const u8,
    klass: c_int,
};

/// `include/git2/strarray.h:22-25`.
pub const git_strarray = extern struct {
    strings: ?[*]const ?[*:0]const u8,
    count: usize,
};

/// `include/git2/net.h:41-51` — one advertised ref.
pub const git_remote_head = extern struct {
    local: c_int,
    oid: git_oid,
    /// The peeled target, for an annotated tag.
    loid: git_oid,
    name: ?[*:0]const u8,
    symref_target: ?[*:0]const u8,
};

/// The C bitfield `unsigned int encrypted : 1, proxy_support : 1;`
/// (`include/git2/sys/stream.h:40-41`), as a packed struct over one `unsigned
/// int` of storage.
///
/// This is the single most dangerous declaration in Ajt. The System V ABI puts
/// the first bitfield member at the least-significant end of its storage unit
/// on little-endian targets, and a `packed struct(c_uint)` lays its first field
/// out the same way — but "same way" is exactly the sort of claim that is right
/// until it is not, so `abi_probe.c:ajt_abi_stream_prefix` builds the same
/// bytes in C and a test compares all eight of them.
pub const StreamFlags = packed struct(c_uint) {
    encrypted: bool = false,
    proxy_support: bool = false,
    _reserved: std.meta.Int(.unsigned, @bitSizeOf(c_uint) - 2) = 0,
};

/// `include/git2/sys/stream.h:37-63`.
///
/// Note that `timeout` and `connect_timeout` are ints, NOT callbacks — they
/// were added in 1.7 and sit between the flags and `connect`. Reading them as
/// function pointers is the mistake this struct exists to not make.
pub const git_stream = extern struct {
    version: c_int = stream_version,
    flags: StreamFlags = .{},
    /// Read/write timeout in milliseconds; 0 blocks indefinitely.
    timeout: c_int = 0,
    /// Connect timeout in milliseconds; 0 means the system default.
    connect_timeout: c_int = 0,

    connect: ?*const fn (*git_stream) callconv(.c) c_int = null,
    certificate: ?*const fn (**git_cert, *git_stream) callconv(.c) c_int = null,
    set_proxy: ?*const fn (*git_stream, ?*const git_proxy_options) callconv(.c) c_int = null,
    read: ?*const fn (*git_stream, ?*anyopaque, usize) callconv(.c) isize = null,
    write: ?*const fn (*git_stream, [*]const u8, usize, c_int) callconv(.c) isize = null,
    close: ?*const fn (*git_stream) callconv(.c) c_int = null,
    free: ?*const fn (*git_stream) callconv(.c) void = null,
};

/// `include/git2/sys/stream.h:65-94`.
///
/// Note what is NOT here: a user-data pointer. `init` gets a host and a port
/// and nothing else, which is why `tls.zig` has to keep its allocator and `Io`
/// in process globals rather than in a context.
pub const git_stream_registration = extern struct {
    version: c_int = stream_version,
    init: ?*const fn (**git_stream, [*:0]const u8, [*:0]const u8) callconv(.c) c_int = null,
    /// TLS over an established stream, i.e. an HTTP CONNECT proxy. Left null:
    /// leaving it null is documented as "HTTP CONNECT proxies will not be
    /// supported", which is a refusal rather than a silent plaintext fallback.
    wrap: ?*const fn (**git_stream, *git_stream, [*:0]const u8) callconv(.c) c_int = null,
};

// ---------------------------------------------------------------------------
// Enum values, spelled as integers. Every one is checked against the C
// compiler's by `abi probe: the enum values c.zig hard-codes`.
// ---------------------------------------------------------------------------

pub const stream_version: c_int = 1;
pub const GIT_STREAM_TLS: c_int = 2;

pub const GIT_ENOTFOUND: c_int = -3;
pub const GIT_EEXISTS: c_int = -4;

pub const GIT_OPT_ENABLE_STRICT_HASH_VERIFICATION: c_int = 22;
pub const GIT_OPT_SET_SERVER_CONNECT_TIMEOUT: c_int = 39;
pub const GIT_OPT_SET_SERVER_TIMEOUT: c_int = 41;

pub const GIT_FEATURE_HTTPS: c_int = 1 << 1;
pub const GIT_FEATURE_SSH: c_int = 1 << 2;

pub const GIT_OBJECT_ANY: c_int = -2;
pub const GIT_OBJECT_COMMIT: c_int = 1;
pub const GIT_OBJECT_TREE: c_int = 2;
pub const GIT_OBJECT_BLOB: c_int = 3;
pub const GIT_OBJECT_TAG: c_int = 4;

pub const GIT_ERROR_NOMEMORY: c_int = 1;
pub const GIT_ERROR_NET: c_int = 12;
pub const GIT_ERROR_SSL: c_int = 16;

pub const GIT_DIRECTION_FETCH: c_int = 0;

/// `git_filemode_t` (`include/git2/types.h:238-245`) — the six values a tree
/// entry's mode can take.
///
/// `c_uint` rather than `c_int` because every enumerator is a non-negative
/// octal file mode; with no negative value the two candidate underlying types
/// are bit-identical in the return register, so the choice is about reading
/// `0o100755` as a mode rather than about the ABI. The values themselves are
/// checked against the C compiler's by the probe below, because they are what
/// decides whether a blob is written executable, as a symlink, or refused —
/// and a wrong constant would silently write the wrong kind of thing.
pub const GIT_FILEMODE_UNREADABLE: c_uint = 0o000000;
pub const GIT_FILEMODE_TREE: c_uint = 0o040000;
pub const GIT_FILEMODE_BLOB: c_uint = 0o100644;
pub const GIT_FILEMODE_BLOB_EXECUTABLE: c_uint = 0o100755;
pub const GIT_FILEMODE_LINK: c_uint = 0o120000;
pub const GIT_FILEMODE_COMMIT: c_uint = 0o160000;

// ---------------------------------------------------------------------------
// The functions. Roughly forty, out of libgit2's ~900.
// ---------------------------------------------------------------------------

pub extern fn git_libgit2_init() c_int;
pub extern fn git_libgit2_shutdown() c_int;
pub extern fn git_libgit2_version(major: *c_int, minor: *c_int, rev: *c_int) c_int;
pub extern fn git_libgit2_features() c_int;
/// Variadic. Every call site here passes exactly one `c_int` after the option.
pub extern fn git_libgit2_opts(option: c_int, ...) c_int;

pub extern fn git_error_last() ?*const git_error;
/// `include/git2/sys/errors.h:60`. Called from the stream callbacks: libgit2
/// reports "-1" and then reads whatever the last error was, so a `-1` returned
/// without setting one surfaces as somebody else's stale message.
pub extern fn git_error_set_str(error_class: c_int, string: [*:0]const u8) c_int;

pub extern fn git_stream_register(stream_type: c_int, registration: ?*git_stream_registration) c_int;

pub extern fn git_repository_open(out: **git_repository, path: [*:0]const u8) c_int;
pub extern fn git_repository_init(out: **git_repository, path: [*:0]const u8, is_bare: c_uint) c_int;
pub extern fn git_repository_free(repo: *git_repository) void;
pub extern fn git_repository_odb(out: **git_odb, repo: *git_repository) c_int;

pub extern fn git_remote_create_anonymous(out: **git_remote, repo: *git_repository, url: [*:0]const u8) c_int;
/// A remote with no repository behind it at all (`remote.h:191-206`). Used only
/// by `ls-remote`, where there is nothing to fetch into and where "consider no
/// local configuration" is the point.
pub extern fn git_remote_create_detached(out: **git_remote, url: [*:0]const u8) c_int;
pub extern fn git_remote_fetch(
    remote: *git_remote,
    refspecs: ?*const git_strarray,
    opts: ?*const anyopaque,
    reflog_message: ?[*:0]const u8,
) c_int;
pub extern fn git_remote_connect(
    remote: *git_remote,
    direction: c_int,
    callbacks: ?*const anyopaque,
    proxy_opts: ?*const anyopaque,
    custom_headers: ?*const git_strarray,
) c_int;
pub extern fn git_remote_ls(out: *[*]const *const git_remote_head, size: *usize, remote: *git_remote) c_int;
pub extern fn git_remote_disconnect(remote: *git_remote) c_int;
pub extern fn git_remote_free(remote: *git_remote) void;

pub extern fn git_revparse_single(out: **git_object, repo: *git_repository, spec: [*:0]const u8) c_int;
pub extern fn git_object_id(obj: *const git_object) *const git_oid;
pub extern fn git_object_type(obj: *const git_object) c_int;
pub extern fn git_object_peel(peeled: **git_object, obj: *const git_object, target_type: c_int) c_int;
pub extern fn git_object_free(obj: *git_object) void;

// The tree walk `materialise` is. No `git_checkout_*` anywhere in this file:
// see `lib.zig`'s header for why a checkout is the wrong instrument and what
// binding `git_checkout_options` would have cost.
pub extern fn git_tree_lookup(out: **git_tree, repo: *git_repository, id: *const git_oid) c_int;
pub extern fn git_tree_free(tree: *git_tree) void;
pub extern fn git_tree_entrycount(tree: *const git_tree) usize;
/// Null when `idx` is out of range (`tree.c:283`), which the caller treats as
/// the end rather than as an error.
pub extern fn git_tree_entry_byindex(tree: *const git_tree, idx: usize) ?*const git_tree_entry;
pub extern fn git_tree_entry_name(entry: *const git_tree_entry) ?[*:0]const u8;
pub extern fn git_tree_entry_id(entry: *const git_tree_entry) *const git_oid;
/// The NORMALISED mode: `tree.c:254-257` runs `entry->attr` through
/// `normalize_filemode` (`:35-55`), which folds every historical spelling onto
/// the six `GIT_FILEMODE_*` values. `git_tree_entry_filemode_raw` returns the
/// byte pattern actually stored in the tree object and is deliberately NOT
/// bound: the raw value is for rebuilding an identical tree object, whereas
/// what `materialise` needs is "what kind of thing do I write".
pub extern fn git_tree_entry_filemode(entry: *const git_tree_entry) c_uint;

pub extern fn git_blob_lookup(out: **git_blob, repo: *git_repository, id: *const git_oid) c_int;
pub extern fn git_blob_free(blob: *git_blob) void;
/// The blob's bytes, unfiltered and owned by the blob (`blob.h:96`). The
/// filtered counterpart is `git_blob_filter`, which is exactly what must not
/// happen here.
pub extern fn git_blob_rawcontent(blob: *const git_blob) ?*const anyopaque;
/// `git_object_size_t`, i.e. `uint64_t` (`types.h:67`) — 64-bit even on a
/// 32-bit target, so it is not `usize`.
pub extern fn git_blob_rawsize(blob: *const git_blob) u64;

pub extern fn git_odb_exists(db: *git_odb, id: *const git_oid) c_int;
/// Four arguments, not five: the five-argument form is behind
/// `GIT_EXPERIMENTAL_SHA256` (`include/git2/odb.h:504` vs `:539`) and this
/// build never defines it. Getting this wrong reads a garbage `oid_type` off
/// the stack.
pub extern fn git_odb_hash(oid: *git_oid, data: ?*const anyopaque, len: usize, object_type: c_int) c_int;
pub extern fn git_odb_free(db: *git_odb) void;

/// libgit2-internal, not `GIT_EXTERN`, but a plain global in the static
/// archive. Bound for one reason: it is the ONLY caller of the platform
/// `qsort_r` (`src/util/util.c:724-733`), and the musl signature trap below is
/// otherwise untestable from outside.
pub extern fn git__qsort_r(
    els: ?*anyopaque,
    nel: usize,
    elsize: usize,
    cmp: *const fn (?*const anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    payload: ?*anyopaque,
) void;

// ---------------------------------------------------------------------------

pub const VersionError = error{LibgitVersionMismatch};

/// Refuse to run against a libgit2 that is not the pinned one.
///
/// Everything in this file is a layout guess that happens to be right for
/// 1.9.x. A build that somehow linked a different libgit2 — a distro `.so`
/// picked up by a packager, say — would not fail to link, because the symbol
/// NAMES are stable across releases; it would fail by writing the wrong bytes
/// into somebody's depot. Checking the version is one call and turns that into
/// a refusal at startup.
///
/// Patch releases are accepted: libgit2 does not change public struct layout in
/// one, and pinning to 1.9.1 exactly would make a security patch a code change.
pub fn assertVersion() VersionError!void {
    var major: c_int = 0;
    var minor: c_int = 0;
    var rev: c_int = 0;
    _ = git_libgit2_version(&major, &minor, &rev);
    if (major != version_major or minor != version_minor) return error.LibgitVersionMismatch;
}

/// The last error message, or a stand-in. Never null, and never owned by the
/// caller: libgit2 keeps it in thread-local storage until the next error.
pub fn lastError() []const u8 {
    const e = git_error_last() orelse return "(no libgit2 error recorded)";
    const msg = e.message orelse return "(libgit2 error with no message)";
    return std.mem.span(msg);
}

// ---------------------------------------------------------------------------
// Tests. Every one of them exists because the failure it catches is silent.
// ---------------------------------------------------------------------------

const testing = std.testing;

extern fn ajt_abi_probe(which: c_int) c_long;
extern fn ajt_abi_stream_prefix(encrypted: c_int, proxy_support: c_int) c_ulonglong;

/// Landmark: index 48 is `sizeof(size_t)`, so a probe that silently returned
/// its default would be caught before any layout claim is believed.
fn probe(which: c_int) i64 {
    return @intCast(ajt_abi_probe(which));
}

test "abi probe: the probe itself ran, and answers about this target" {
    // Nothing below exists without `-Dgit`. The condition is comptime-known,
    // so the rest of this body is not even analysed -- which is what keeps
    // c.zig's `extern` declarations out of a build with no libgit2 to link.
    if (!enabled) return error.SkipZigTest;
    // If `abi_probe.c` were not linked this would not build; if it were linked
    // but broken, `default:` returns a large negative sentinel. Assert a fact
    // whose value we know independently.
    try testing.expectEqual(@as(i64, @sizeOf(usize)), probe(48));
    try testing.expectEqual(@as(i64, -0x7fffffff), probe(9999));
}

test "abi probe: git_stream, the struct Ajt implements" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(i64, @sizeOf(git_stream)), probe(0));
    try testing.expectEqual(@as(i64, @alignOf(git_stream)), probe(1));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "version")), probe(2));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "timeout")), probe(3));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "connect_timeout")), probe(4));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "connect")), probe(5));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "certificate")), probe(6));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "set_proxy")), probe(7));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "read")), probe(8));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "write")), probe(9));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "close")), probe(10));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream, "free")), probe(11));
}

test "abi probe: the encrypted/proxy_support bitfield lands on the same bits" {
    if (!enabled) return error.SkipZigTest;
    // The one field `offsetof` cannot describe, and the one whose mislayout is
    // silent: every function pointer after it would shift by four or eight
    // bytes and libgit2 would call `read` where `connect` belongs.
    //
    // Build the same eight leading bytes on both sides and compare. All four
    // combinations, because a swapped pair passes any single one of them.
    for ([_][2]bool{
        .{ false, false },
        .{ true, false },
        .{ false, true },
        .{ true, true },
    }) |combo| {
        var s: git_stream = .{
            .version = 0,
            .flags = .{ .encrypted = combo[0], .proxy_support = combo[1] },
        };
        var zig_bytes: [8]u8 = @splat(0);
        const raw: [*]const u8 = @ptrCast(&s);
        @memcpy(&zig_bytes, raw[0..8]);
        const zig_prefix = std.mem.readInt(u64, &zig_bytes, .little);

        const c_prefix = ajt_abi_stream_prefix(@intFromBool(combo[0]), @intFromBool(combo[1]));
        try testing.expectEqual(@as(u64, @intCast(c_prefix)), zig_prefix);
    }
}

test "abi probe: git_stream_registration" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(i64, @sizeOf(git_stream_registration)), probe(12));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream_registration, "version")), probe(13));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream_registration, "init")), probe(14));
    try testing.expectEqual(@as(i64, @offsetOf(git_stream_registration, "wrap")), probe(15));
}

test "abi probe: git_oid is twenty bytes and nothing else" {
    if (!enabled) return error.SkipZigTest;
    // 20, not 21 and not 32: the `type` prefix only exists under
    // GIT_EXPERIMENTAL_SHA256. This is the assertion that stops every hash Ajt
    // reads from being shifted by a byte.
    try testing.expectEqual(@as(i64, 20), probe(16));
    try testing.expectEqual(@as(i64, @sizeOf(git_oid)), probe(16));
    try testing.expectEqual(@as(i64, @alignOf(git_oid)), probe(17));
    try testing.expectEqual(@as(i64, @offsetOf(git_oid, "id")), probe(18));
}

test "abi probe: git_error, git_strarray, git_remote_head" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(i64, @sizeOf(git_error)), probe(19));
    try testing.expectEqual(@as(i64, @offsetOf(git_error, "message")), probe(20));
    try testing.expectEqual(@as(i64, @offsetOf(git_error, "klass")), probe(21));

    try testing.expectEqual(@as(i64, @sizeOf(git_strarray)), probe(22));
    try testing.expectEqual(@as(i64, @offsetOf(git_strarray, "strings")), probe(23));
    try testing.expectEqual(@as(i64, @offsetOf(git_strarray, "count")), probe(24));

    try testing.expectEqual(@as(i64, @sizeOf(git_remote_head)), probe(25));
    try testing.expectEqual(@as(i64, @offsetOf(git_remote_head, "local")), probe(26));
    try testing.expectEqual(@as(i64, @offsetOf(git_remote_head, "oid")), probe(27));
    try testing.expectEqual(@as(i64, @offsetOf(git_remote_head, "loid")), probe(28));
    try testing.expectEqual(@as(i64, @offsetOf(git_remote_head, "name")), probe(29));
    try testing.expectEqual(@as(i64, @offsetOf(git_remote_head, "symref_target")), probe(30));
}

test "abi probe: the enum values c.zig hard-codes" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(i64, stream_version), probe(31));
    try testing.expectEqual(@as(i64, GIT_STREAM_TLS), probe(32));
    try testing.expectEqual(@as(i64, GIT_ENOTFOUND), probe(33));
    try testing.expectEqual(@as(i64, GIT_EEXISTS), probe(34));
    // The three `git_libgit2_opts` selectors. These are positional in an
    // unnumbered enum, so a release that inserts an option anywhere above them
    // silently changes what `opts(22, 1)` means -- from "verify hashes" to
    // something else entirely.
    try testing.expectEqual(@as(i64, GIT_OPT_ENABLE_STRICT_HASH_VERIFICATION), probe(35));
    try testing.expectEqual(@as(i64, GIT_OPT_SET_SERVER_TIMEOUT), probe(36));
    try testing.expectEqual(@as(i64, GIT_OPT_SET_SERVER_CONNECT_TIMEOUT), probe(37));
    try testing.expectEqual(@as(i64, GIT_FEATURE_HTTPS), probe(38));
    try testing.expectEqual(@as(i64, GIT_FEATURE_SSH), probe(39));
    try testing.expectEqual(@as(i64, GIT_OBJECT_ANY), probe(40));
    try testing.expectEqual(@as(i64, GIT_OBJECT_COMMIT), probe(41));
    try testing.expectEqual(@as(i64, GIT_OBJECT_TREE), probe(42));
    try testing.expectEqual(@as(i64, GIT_OBJECT_BLOB), probe(43));
    try testing.expectEqual(@as(i64, GIT_OBJECT_TAG), probe(44));
    try testing.expectEqual(@as(i64, GIT_ERROR_NET), probe(45));
    try testing.expectEqual(@as(i64, GIT_ERROR_NOMEMORY), probe(49));
    try testing.expectEqual(@as(i64, GIT_ERROR_SSL), probe(46));
    try testing.expectEqual(@as(i64, GIT_DIRECTION_FETCH), probe(47));
}

test "abi probe: git_filemode_t, which is what materialise switches on" {
    if (!enabled) return error.SkipZigTest;
    // Unlike the option selectors above, these are EXPLICIT values in the enum
    // (`types.h:238-245`) rather than positional ones, so a release cannot
    // renumber them by inserting a row. They are probed anyway because the
    // failure is silent in the worst possible way: `materialise` decides
    // "regular file / executable / symlink / subdirectory / submodule" from
    // this one number, and a wrong constant writes the wrong KIND of thing --
    // which then re-hashes to something other than the tree that was asked
    // for, with nothing pointing at the mode as the cause.
    try testing.expectEqual(@as(i64, GIT_FILEMODE_UNREADABLE), probe(50));
    try testing.expectEqual(@as(i64, GIT_FILEMODE_TREE), probe(51));
    try testing.expectEqual(@as(i64, GIT_FILEMODE_BLOB), probe(52));
    try testing.expectEqual(@as(i64, GIT_FILEMODE_BLOB_EXECUTABLE), probe(53));
    try testing.expectEqual(@as(i64, GIT_FILEMODE_LINK), probe(54));
    try testing.expectEqual(@as(i64, GIT_FILEMODE_COMMIT), probe(55));

    // And they are git's on-disk modes, which is a fact about the FORMAT
    // rather than about libgit2: `100644` and friends are what a tree object
    // literally contains, and what `julia/treehash.zig` writes back into the
    // hash it recomputes from disk.
    try testing.expectEqual(@as(c_uint, 0o100644), GIT_FILEMODE_BLOB);
    try testing.expectEqual(@as(c_uint, 0o100755), GIT_FILEMODE_BLOB_EXECUTABLE);
    try testing.expectEqual(@as(c_uint, 0o120000), GIT_FILEMODE_LINK);
    try testing.expectEqual(@as(c_uint, 0o160000), GIT_FILEMODE_COMMIT);
}

test "the linked libgit2 is the pinned one" {
    if (!enabled) return error.SkipZigTest;
    try assertVersion();
}

test "the feature header is what build.zig thinks it is" {
    if (!enabled) return error.SkipZigTest;
    // One line, and it proves the whole `git2_features.h` story: neither TLS
    // backend nor SSH is compiled in, so `https://` working at all is proof
    // that the registered `git_stream` is carrying it -- and `ssh://` failing
    // is a fact rather than a hope.
    const features = git_libgit2_features();
    try testing.expectEqual(@as(c_int, 0), features & GIT_FEATURE_HTTPS);
    try testing.expectEqual(@as(c_int, 0), features & GIT_FEATURE_SSH);
}

fn cmpWithPayload(a: ?*const anyopaque, b: ?*const anyopaque, payload: ?*anyopaque) callconv(.c) c_int {
    const pa: *const u32 = @ptrCast(@alignCast(a.?));
    const pb: *const u32 = @ptrCast(@alignCast(b.?));
    // The payload decides the direction. If the comparator were called with the
    // wrong argument registers -- which is exactly what the musl `qsort_r`
    // trap produces -- this dereferences whatever happened to be in that
    // register, and the test either mis-sorts or crashes. Both are failures.
    const descending: *const bool = @ptrCast(@alignCast(payload.?));
    const lt = if (descending.*) pa.* > pb.* else pa.* < pb.*;
    if (lt) return -1;
    if (pa.* == pb.*) return 0;
    return 1;
}

test "qsort_r reaches the comparator with three arguments and the payload" {
    if (!enabled) return error.SkipZigTest;
    // The musl trap, made loud.
    //
    // `git__qsort_r` (`src/util/util.c:724-733`) calls the platform `qsort_r`
    // directly under `GIT_QSORT_GNU`. musl 1.2.5 HAS the GNU-signature
    // `qsort_r`, but declares it only under `_GNU_SOURCE`. Without that
    // declaration, C's implicit-declaration rule invents a two-argument
    // comparator, the payload never reaches the callback, and the sort is
    // silently wrong -- no link error, no crash on glibc, and a package
    // manager that orders things wrongly.
    //
    // Ten thousand elements, because a small array can come out sorted by luck
    // and because the GNU qsort switches strategy on size.
    const n = 10_000;
    const gpa = testing.allocator;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);

    // A fixed shuffle: deterministic, and not already sorted in either
    // direction.
    var prng: std.Random.DefaultPrng = .init(0x5eed_1234);
    const rand = prng.random();
    for (xs, 0..) |*x, i| x.* = @intCast(i);
    rand.shuffle(u32, xs);

    var descending = false;
    git__qsort_r(xs.ptr, n, @sizeOf(u32), cmpWithPayload, &descending);
    for (xs, 0..) |x, i| try testing.expectEqual(@as(u32, @intCast(i)), x);

    // And again through the payload, so that "the payload arrived" is asserted
    // rather than merely "the array is ordered".
    rand.shuffle(u32, xs);
    descending = true;
    git__qsort_r(xs.ptr, n, @sizeOf(u32), cmpWithPayload, &descending);
    for (xs, 0..) |x, i| try testing.expectEqual(@as(u32, @intCast(n - 1 - i)), x);
}
