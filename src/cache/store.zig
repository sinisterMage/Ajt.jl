//! The precompile-cache object store: immutable blobs over plain HTTP, with
//! the hash checked before a single byte reaches the depot.
//!
//! Three namespaces under one configured base URL:
//!
//!   * `<base>/objects/<blake3>.tar.zst` — one archived build product. The
//!     name IS the BLAKE3 of the stored bytes, so the store is
//!     content-addressed, deduplicating, and safe to cache forever.
//!   * `<base>/manifests/<blake3>.json` — what to fetch and what it costs.
//!   * `<base>/keys/<derivation-key>.json` — the LOOKUP. See `keyUrl`: the
//!     first two are addressed by the hash of their own bytes, which makes
//!     them immutable and also means a client cannot ask for one until
//!     somebody tells it a hash. A derivation key is computed rather than
//!     announced, so this is the namespace a cold machine can actually start
//!     from, and it is why using the store needs no configuration beyond the
//!     base URL itself.
//!
//! `<base>` is configuration and nothing else: this module hardcodes no host,
//! no bucket and no prefix. A deployment that serves the store from an object
//! bucket behind a reverse proxy passes the proxied prefix in; one that serves
//! it from the Pkg server passes that. Only `objects/` and `manifests/` are
//! ours, because those are the wire format rather than somebody's topology.
//!
//! Sizing, so the shape is not a surprise: ~300 MB of deduplicated cache
//! compresses to ~80–110 MB at zstd-19, which is why this is worth a transport
//! at all rather than a rebuild.
//!
//! ## Verify before write, for the same reason `install/extract.zig` does
//!
//! `install/extract.zig` exists because Pkg unpacks a package tarball and
//! hashes the result, leaving a window in which unverified network bytes are
//! real files on the machine. This module makes the same promise about cache
//! objects, and keeps it the same way: the object is hashed **in memory**,
//! compared, and only then does anything touch the filesystem. On a mismatch
//! `fetchObject` returns before `depot.begin` runs, so not even the staging
//! directory — nor the parent chain `begin` would create — comes into
//! existence. That is a slightly stronger guarantee than the artifact
//! installer makes, and it is free here: an object is buffered anyway, because
//! you cannot hash a stream you have already written out.
//!
//! Stated precisely, because the absolute version would be wrong: no byte of
//! NETWORK CONTENT reaches the filesystem before it verifies. One unrelated
//! write can still happen underneath a fetch — `net/auth.zig`'s token refresh
//! rewrites `servers/<host>/auth.toml` when the depot's own credential has
//! expired. That is the caller's credential, not the store's content, and it
//! is the same write any `ajt` GET performs.
//!
//! **The hash is over the COMPRESSED bytes**, i.e. over exactly what the URL
//! names. Two reasons, and they are the same two that put the sha256 check
//! ahead of `gunzip` in `ops/install_artifacts.zig`:
//!
//!   1. It is checkable without decompressing anything, so a hostile or broken
//!      store cannot get a zstd bomb as far as the decompressor.
//!   2. zstd is not canonical. Hashing the decompressed tar would mean the same
//!      content recompressed at a different level is a different object name,
//!      which defeats the dedup the whole store is for.
//!
//! Be honest about what that does NOT prove: it pins what the store served,
//! not what the archive means. There is no equivalent of a registry's
//! `git-tree-sha1` here — nobody has pinned the "right" build product in
//! advance. What backstops it is that a wrong-but-well-formed cache entry
//! costs a recompile and never a mis-load: Julia's `stale_cachefile` re-checks
//! every dependency's build_id and every include's `@depot` resolution, and an
//! entry that fails is silently rebuilt. Level-1 verification (parsing the
//! `.ji` header before import, so the rejection is a millisecond instead of a
//! multi-minute recompile) is a separate module's job; this one is the wire.
//!
//! ## Why the manifest carries build times
//!
//! A manifest entry is `(key, object, size, build_ms)`, not just
//! `(key, object)`. The scheduler ranks the critical path by measured build
//! cost, and a cold machine has measured nothing. Shipping the cost model
//! beside the plan means one GET gives a fresh machine a good ranking on its
//! FIRST request rather than after its first build — which is precisely the
//! machine where the ranking matters, since a warm one mostly has cache hits
//! and nothing to order.
//!
//! ## The zstd asymmetry
//!
//! Zig 0.16.0's std ships a zstd DEcompressor and no compressor
//! (`std.compress.zstd` is `Decompress` and tables). So the read path is
//! complete and the write path cannot compress: `putObject` sends the bytes it
//! is given. `rawFrame` wraps arbitrary bytes in a valid — but uncompressed —
//! zstd frame so that a store can always be written without an external tool;
//! a real publisher pipes through `zstd -19` first and gets the 80–110 MB
//! above instead of 300. `rawFrame` is a framer, not a compressor, and says so
//! in its own doc comment.
//!
//! ## Errors: the machine versus one object
//!
//! Same split as `ops/install_artifacts.zig`. Out of memory, cancellation and
//! a depot that cannot be staged into are ERRORS — nothing about this run will
//! work. A 404, a corrupt object, a malformed manifest are `Failure` values on
//! the result: a store miss is the normal case (that is what a cache is), and
//! one bad object must never take down the other two hundred.
//!
//! ## Allocation
//!
//! Every function that returns a bundle of allocations takes an `arena` and
//! says so. Object bodies are the exception worth stating: they are hundreds
//! of megabytes, they are retried, and `net/http.zig`'s `get` reuses its arena
//! across attempts by design. So the retry loop lives HERE, over a scratch
//! arena that is reset between tries, exactly as `ops/install_artifacts.zig`
//! does and for exactly that reason. What that bounds is the number of FAILED
//! bodies held at once, which is one; it is not a claim that only one copy
//! exists, since a verified body is duplicated into the caller's arena while
//! the scratch copy is still live, and `fetchObject` then holds the
//! decompressed archive alongside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const net_http = @import("../net/http.zig");
const extract = @import("../install/extract.zig");
const depot_mod = @import("../depot.zig");

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

/// BLAKE3-256. The store's whole naming scheme.
pub const Hash = [Blake3.digest_length]u8;
const Blake3 = std.crypto.hash.Blake3;

pub const hex_len = 2 * @sizeOf(Hash);

pub fn hashBytes(bytes: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(bytes, &out, .{});
    return out;
}

pub fn toHex(h: Hash) [hex_len]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

/// Parses the canonical lowercase hex form. Uppercase is accepted on the way
/// IN (a hand-written manifest is a real thing) but never produced: the object
/// name has to be one string or the store stops deduplicating.
pub fn parseHash(hex: []const u8) error{InvalidHash}!Hash {
    if (hex.len != hex_len) return error.InvalidHash;
    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
    return out;
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

/// `<base>/objects/<hex>.tar.zst`. Arena-allocated.
pub fn objectUrl(arena: Allocator, base_url: []const u8, hash: Hash) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/objects/{s}.tar.zst", .{ trimSlash(base_url), &toHex(hash) });
}

/// `<base>/manifests/<hex>.json`. Arena-allocated.
pub fn manifestUrl(arena: Allocator, base_url: []const u8, hash: Hash) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/manifests/{s}.json", .{ trimSlash(base_url), &toHex(hash) });
}

/// `<base>/keys/<derivation-key-hex>.json`. Arena-allocated.
///
/// The third namespace, and the one that makes the store usable without being
/// told anything. `objects/` and `manifests/` are both addressed by the hash of
/// their own bytes, which is what makes them immutable and cacheable forever —
/// and also means a client cannot ask for one until somebody has told it a
/// hash. There was no mechanism for that, and inventing a `--cache-manifest
/// <64 hex chars>` flag would have been a configuration burden with no
/// equivalent anywhere in Pkg.
///
/// A derivation key needs no such introduction: the client COMPUTES it, from
/// the manifest it already has and the machine it is already running on
/// (`cache/key.zig`). So `keys/<key>` is the lookup, and what it returns is a
/// `Pointer` naming the object. Two GETs instead of one, and no discovery at
/// all.
///
/// This namespace is the only mutable one, in the narrow sense that republishing
/// a key may point it at different bytes — a rebuild of the same package on a
/// different day is not byte-identical. Nothing is trusted because of where it
/// was found: the pointer carries the object's BLAKE3, that is checked before a
/// byte reaches the depot, and `jicache.zig` reads the `.ji` header before the
/// entry is believed. A hostile `keys/` entry costs a recompile.
pub fn keyUrl(arena: Allocator, base_url: []const u8, key_hex: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/keys/{s}.json", .{ trimSlash(base_url), key_hex });
}

/// The same URL with any `user:password@` removed, for the copy that ends up
/// in a result struct.
///
/// `Object.url` is a diagnostics field — callers print it, and a failed fetch
/// is exactly when they do. A base URL of the shape
/// `https://key:secret@bucket.example/ajt` is a plausible way to configure an
/// object bucket, and echoing it into a log is a credential disclosure that has
/// nothing to do with the failure being reported. The REQUEST always uses the
/// unredacted URL; only the reported copy is scrubbed. Arena-allocated, and
/// borrowing the input unchanged when there is nothing to strip.
fn redactUrl(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const authority = scheme_end + 3;
    // Userinfo, if present, ends at the first `@` BEFORE the first `/` — a
    // later `@` is in the path and is nobody's password.
    const path_start = std.mem.indexOfScalarPos(u8, url, authority, '/') orelse url.len;
    const at = std.mem.indexOfScalarPos(u8, url, authority, '@') orelse return url;
    if (at > path_start) return url;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ url[0..authority], url[at + 1 ..] });
}

/// A base URL configured with a trailing slash is the single most likely
/// operator typo, and `//objects/` is a DIFFERENT path to most proxies. Strip
/// it rather than serve 404s that look like cache misses.
fn trimSlash(base: []const u8) []const u8 {
    var end = base.len;
    while (end > 0 and base[end - 1] == '/') end -= 1;
    return base[0..end];
}

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

/// The wire schema version. Bumped only when an OLD reader would misread a NEW
/// manifest; additive fields do not need it, because unknown fields are
/// ignored (see `Manifest.parse`).
pub const schema_version: u32 = 1;

/// One object, and what it costs.
pub const Entry = struct {
    /// The derivation key the scheduler asks by — opaque to the transport,
    /// which never computes or interprets it. Unique within a manifest.
    key: []const u8,
    /// Diagnostics only. Two entries may share a name (two builds of one
    /// package); they may never share a `key`.
    name: []const u8 = "",
    /// BLAKE3 of the stored `.tar.zst` bytes.
    object: Hash,
    /// Size of those stored bytes. Lets a fetcher budget, and lets it set a
    /// per-object cap before it has seen a single byte.
    size: u64,
    /// Measured wall-clock build time. The scheduler's cost model; see the
    /// module docs for why it travels with the plan.
    build_ms: u64,
};

/// What one GET of a manifest yields: the plan and its cost model.
///
/// `parse` and `render` are inverses through the canonical form: `render`
/// always sorts by `key`, so identical content is identical bytes and
/// therefore ONE object in a content-addressed store.
pub const Manifest = struct {
    schema: u32 = schema_version,
    entries: []const Entry = &.{},

    pub const ParseError = error{
        MalformedJson,
        /// `schema` names a version this reader does not understand. Refused
        /// loudly: a cache that silently ignores a schema bump is how you get
        /// an import that half-works.
        UnsupportedSchema,
        /// An `object` field that is not 64 hex characters.
        MalformedHash,
        /// Two entries claim the same `key`. Picking one is exactly the kind
        /// of silent divergence this project refuses elsewhere.
        DuplicateKey,
    } || Allocator.Error;

    /// Arena-lifetime: every string in the result comes from `arena`, which
    /// may therefore outlive `json_bytes`.
    pub fn parse(arena: Allocator, json_bytes: []const u8) ParseError!Manifest {
        const wire = std.json.parseFromSliceLeaky(Wire, arena, json_bytes, .{
            // Additive fields must not break an older reader; that is what
            // makes `schema` a rare event rather than a per-release ritual.
            .ignore_unknown_fields = true,
            // The body is borrowed from a scratch arena that gets reset
            // between retries, so nothing may alias it.
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedJson,
        };
        if (wire.schema != schema_version) return error.UnsupportedSchema;

        const entries = try arena.alloc(Entry, wire.objects.len);
        for (wire.objects, entries) |w, *slot| {
            slot.* = .{
                .key = w.key,
                .name = w.name,
                .object = parseHash(w.object) catch return error.MalformedHash,
                .size = w.size,
                .build_ms = w.build_ms,
            };
        }
        std.mem.sort(Entry, entries, {}, lessByKey);
        // Sorted, so duplicates are adjacent. A `while` whose condition is
        // tested first, rather than a slice pair or a `1..len` range: an EMPTY
        // manifest is a real document — a store with nothing published yet —
        // and on a zero-length `entries` both of the tidier spellings panic
        // rather than skipping the loop (`entries[1..]` is a bounds violation,
        // `1..entries.len` overflows computing its own length).
        var i: usize = 1;
        while (i < entries.len) : (i += 1) {
            if (std.mem.eql(u8, entries[i - 1].key, entries[i].key)) return error.DuplicateKey;
        }
        return .{ .schema = wire.schema, .entries = entries };
    }

    /// The canonical bytes: sorted by `key`, minified, fields in declaration
    /// order. Arena-allocated.
    ///
    /// Deterministic on purpose. A manifest is itself stored by the hash of
    /// its bytes, so a renderer that reordered anything would mint a new
    /// object for content that had not changed.
    pub fn render(self: Manifest, arena: Allocator) Allocator.Error![]const u8 {
        const sorted = try arena.dupe(Entry, self.entries);
        std.mem.sort(Entry, sorted, {}, lessByKey);

        const objects = try arena.alloc(WireEntry, sorted.len);
        for (sorted, objects) |e, *slot| {
            slot.* = .{
                .key = e.key,
                .name = e.name,
                .object = try arena.dupe(u8, &toHex(e.object)),
                .size = e.size,
                .build_ms = e.build_ms,
            };
        }

        var aw: Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(
            Wire{ .schema = self.schema, .objects = objects },
            .{},
            &aw.writer,
        ) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// The entry for `key`, or null. Linear because a manifest is the size of
    /// an environment (a few hundred), not of a registry.
    pub fn find(self: Manifest, key: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    fn lessByKey(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }

    /// The JSON shape. Separate from `Entry` because the wire carries the hash
    /// as hex and the model carries it as bytes; conflating the two is how a
    /// parser ends up trusting an unvalidated string.
    const Wire = struct {
        schema: u32,
        objects: []WireEntry,
    };

    const WireEntry = struct {
        key: []const u8,
        name: []const u8 = "",
        object: []const u8,
        size: u64,
        build_ms: u64,
    };
};

/// What `keys/<derivation-key>.json` holds: one entry, without the manifest
/// wrapper.
///
/// The same three fields a `Manifest.Entry` carries minus the key itself, which
/// is in the URL. Kept as its own type rather than reusing `Manifest` with one
/// element, because the two answer different questions and a reader that
/// accepted either would have to decide what a two-entry document meant at a
/// single key's address.
pub const Pointer = struct {
    schema: u32 = schema_version,
    /// BLAKE3 of the stored `.tar.zst`, which is where `objects/` finds it.
    object: Hash,
    size: u64 = 0,
    /// Measured build time, so a cold machine can rank its critical path from
    /// the first lookup instead of after its first build.
    build_ms: u64 = 0,
    /// Diagnostics only.
    name: []const u8 = "",

    pub const ParseError = error{
        MalformedJson,
        UnsupportedSchema,
        MalformedHash,
    } || Allocator.Error;

    /// Arena-lifetime: every string in the result comes from `arena`.
    pub fn parse(arena: Allocator, json_bytes: []const u8) ParseError!Pointer {
        const wire = std.json.parseFromSliceLeaky(Wire, arena, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedJson,
        };
        if (wire.schema != schema_version) return error.UnsupportedSchema;
        return .{
            .schema = wire.schema,
            .object = parseHash(wire.object) catch return error.MalformedHash,
            .size = wire.size,
            .build_ms = wire.build_ms,
            .name = wire.name,
        };
    }

    pub fn render(self: Pointer, arena: Allocator) Allocator.Error![]const u8 {
        var aw: Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(Wire{
            .schema = self.schema,
            .object = try arena.dupe(u8, &toHex(self.object)),
            .size = self.size,
            .build_ms = self.build_ms,
            .name = self.name,
        }, .{}, &aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    const Wire = struct {
        schema: u32,
        object: []const u8,
        size: u64 = 0,
        build_ms: u64 = 0,
        name: []const u8 = "",
    };
};

/// What one GET of a key yields.
pub const FetchedPointer = struct {
    url: []const u8 = "",
    failure: ?Failure = null,
    status: ?http.Status = null,
    attempts: u32 = 0,
    pointer: ?Pointer = null,

    /// A MISS is not a failure — it is the normal case for a cache, and the
    /// caller compiles. This distinguishes "the store said no" from "the store
    /// is broken", which matters only for whether anything gets logged.
    pub fn miss(self: FetchedPointer) bool {
        return self.pointer == null;
    }
};

// ---------------------------------------------------------------------------
// zstd framing
// ---------------------------------------------------------------------------

/// Wraps `bytes` in a valid zstd frame built entirely from RAW blocks.
///
/// **This is a framer, not a compressor.** Output is slightly LARGER than
/// input (3 bytes of block header per 128 KiB, plus a 2-byte frame header).
/// It exists because Zig 0.16.0's std has a zstd decompressor and no
/// compressor, and a store you can read but not write is not a store. A
/// deployment that cares about the 300 MB → 80–110 MB win pipes through
/// `zstd -19` and hands the result to `putObject` directly; everything
/// downstream — the hash, the URL, the decompressor — is identical either way,
/// because the frame is well-formed zstd in both cases.
///
/// The window is declared as 8 MiB, matching `zstd.default_window_len` and
/// zstd's own level-19 window, so a reader sized for real `-19` output reads
/// these too. Held in `gpa`; the caller frees.
pub fn rawFrame(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    // Block_Maximum_Size is Min(Window_Size, 128 KiB), and `Window_Size` below
    // is 8 MiB, so 128 KiB is the cap.
    const max_block = std.compress.zstd.block_size_max;
    const blocks = @max(1, (bytes.len + max_block - 1) / max_block);

    var out: std.ArrayList(u8) = try .initCapacity(gpa, 6 + bytes.len + 3 * blocks);
    errdefer out.deinit(gpa);

    // Magic_Number, little-endian.
    out.appendSliceAssumeCapacity(&[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    // Frame_Header_Descriptor: Frame_Content_Size_flag 0, Single_Segment_flag
    // 0, no checksum, no dictionary. Single_Segment is deliberately OFF: with
    // it set, Window_Size becomes the whole content size, which would demand a
    // decompressor buffer as large as the object.
    out.appendAssumeCapacity(0x00);
    // Window_Descriptor: Exponent 13, Mantissa 0 ->
    // Window_Size = 1 << (10 + 13) = 8 MiB.
    out.appendAssumeCapacity(13 << 3);

    var offset: usize = 0;
    while (true) {
        const n = @min(max_block, bytes.len - offset);
        const last = offset + n >= bytes.len;
        // Block_Header, 3 bytes little-endian:
        // bit 0 Last_Block, bits 1-2 Block_Type (0 = Raw), bits 3.. Block_Size.
        const header: u32 = (@as(u32, @intCast(n)) << 3) | @intFromBool(last);
        out.appendSliceAssumeCapacity(&[_]u8{
            @truncate(header),
            @truncate(header >> 8),
            @truncate(header >> 16),
        });
        out.appendSliceAssumeCapacity(bytes[offset..][0..n]);
        if (last) break;
        offset += n;
    }
    return out.toOwnedSlice(gpa);
}

pub const DecompressError = error{ DecompressFailed, ObjectTooLarge } || Allocator.Error;

/// One zstd frame to bytes, under a hard cap. Held in `gpa`; the caller frees.
///
/// `max_uncompressed` is the zip-bomb guard and it is enforced DURING the
/// read, not after: an object that expands without bound must not be able to
/// exhaust memory first and be rejected second.
///
/// **Publishers must not exceed windowLog 23 (8 MiB).** The window is pinned
/// at `zstd.default_window_len`, which is what `zstd -19` declares, so the
/// documented publisher path fits exactly. `zstd -20` and above, and any use
/// of `--long`, declare a larger window; the decompressor rejects those and
/// this reports `Failure.decompress_failed` — i.e. an unsupported object is
/// indistinguishable from a corrupt one. Raising the ceiling is not free: the
/// buffer is `window_len + block_size_max` and is allocated per fetch, so
/// accommodating windowLog 27 would mean 128 MiB per concurrent object.
pub fn unzstd(gpa: Allocator, frame: []const u8, max_uncompressed: usize) DecompressError![]u8 {
    var in = Io.Reader.fixed(frame);
    const window_len = std.compress.zstd.default_window_len;
    // The decompressor asserts this exact capacity; an under-sized buffer is a
    // panic, not an error return.
    const buf = try gpa.alloc(u8, window_len + std.compress.zstd.block_size_max);
    defer gpa.free(buf);
    var d: std.compress.zstd.Decompress = .init(&in, buf, .{ .window_len = window_len });
    // `Limit.limited(n)` only succeeds when EndOfStream arrives BEFORE the
    // limit is consumed, so n + 1 makes the cap inclusive — same off-by-one as
    // `net/http.zig`'s `max_body_bytes`.
    const cap: Io.Limit = if (max_uncompressed == std.math.maxInt(usize))
        .unlimited
    else
        .limited(max_uncompressed + 1);
    return d.reader.allocRemaining(gpa, cap) catch |err| switch (err) {
        // Out of memory must not be laundered into "the store served junk":
        // one means try again elsewhere, the other means stop.
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.ObjectTooLarge,
        else => return error.DecompressFailed,
    };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// Why one request did not produce a usable object. Success is `failure ==
/// null`, not a member here.
pub const Failure = enum {
    /// Non-2xx. `status` carries the code; `.not_found` is a cache MISS, which
    /// is the ordinary case and not a problem.
    http_status,
    /// Connect/TLS/read failure, or a malformed URL.
    transport,
    /// Body exceeded the configured cap, on the wire or after decompression.
    too_large,
    /// The bytes are not the object the name says they are. `computed` has
    /// what actually arrived.
    hash_mismatch,
    /// The manifest is not JSON, not this schema, or self-contradictory.
    malformed_manifest,
    decompress_failed,
    malformed_archive,
    /// A path whose meaning on disk differs from its meaning in the archive —
    /// `..`, a symlink used as a directory prefix, a duplicate. See
    /// `install/extract.zig`.
    unsafe_archive,
    /// Verified content the filesystem refused, during extraction or during
    /// the rename that publishes it.
    write_failed,
};

/// A fetched object. `bytes` is the VERIFIED stored form — still zstd, because
/// the hash names the compressed bytes.
pub const Object = struct {
    hash: Hash,
    url: []const u8,
    bytes: []const u8 = "",
    failure: ?Failure = null,
    status: ?http.Status = null,
    /// Hex of what actually arrived, on `hash_mismatch`. A mismatch reported
    /// with one side is undiagnosable.
    computed: ?[]const u8 = null,
    /// Requests actually issued. Diagnostics, and the only way a test can
    /// observe that retry stopped rather than looped.
    attempts: u32 = 0,

    pub fn ok(self: Object) bool {
        return self.failure == null;
    }

    /// A plain cache miss: the store has never heard of this object. Distinct
    /// from every other failure, because it is the one that is not a problem.
    pub fn miss(self: Object) bool {
        return self.failure == .http_status and self.status == .not_found;
    }
};

pub const FetchedManifest = struct {
    hash: Hash,
    url: []const u8,
    manifest: Manifest = .{},
    failure: ?Failure = null,
    status: ?http.Status = null,
    computed: ?[]const u8 = null,
    attempts: u32 = 0,

    pub fn ok(self: FetchedManifest) bool {
        return self.failure == null;
    }

    pub fn miss(self: FetchedManifest) bool {
        return self.failure == .http_status and self.status == .not_found;
    }
};

pub const Outcome = enum {
    /// This process published it.
    installed,
    /// The destination already existed, or another process won the rename.
    /// Success: the path is content-addressed, so their bytes are ours.
    already_present,
};

pub const Installed = struct {
    object: Object,
    /// Null when `object.failure` is set — nothing was written.
    outcome: ?Outcome = null,
    /// Where it now is. Empty on failure.
    path: []const u8 = "",
};

/// Machine-level failure: nothing about this run will work. Everything that is
/// about ONE object is a `Failure` on the result instead.
pub const Error = Allocator.Error || Io.Cancelable;
pub const FetchError = Error || depot_mod.BeginError;

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Attempts per request, driven here rather than by `net/http.zig` so that
    /// a scratch arena can be reset between them — see the module docs.
    /// Retrying a GET is always safe; retrying the PUT is safe because the
    /// object path is the hash of the body.
    retry: net_http.Retry = .{ .attempts = 3, .delay = .{ .nanoseconds = std.time.ns_per_s } },
    /// Cap on one object's stored bytes. Enforced DURING the read by
    /// `net/http.zig`, not after.
    max_object_bytes: usize = 1024 * 1024 * 1024,
    /// Cap on one object after decompression. Zip-bomb guard.
    max_uncompressed: usize = 4 * 1024 * 1024 * 1024,
    /// A manifest is a few hundred entries of a few hundred bytes.
    max_manifest_bytes: usize = 16 * 1024 * 1024,
    /// A pointer is five short fields. The cap is generous by three orders of
    /// magnitude and still refuses a store that answers a key lookup with a
    /// disk image.
    max_pointer_bytes: usize = 64 * 1024,
    /// `set_readonly` on the published tree. FALSE here, unlike artifacts:
    /// what lands is Julia's own `compiled/` territory, and Julia replaces
    /// cache files in place. A read-only tree there converts a cache hit into
    /// a permission error the next time Julia precompiles anything.
    set_readonly: bool = false,
    commit_retry: depot_mod.Retry = .{},
};

/// A configured object store over one HTTP client.
///
/// `client` is borrowed and must outlive the `Store`. That is deliberate:
/// `net/http.zig` is the only module in Ajt that talks to the network, and one
/// client per process is what keeps the connection pool and the depot's auth
/// state in one place.
pub const Store = struct {
    client: *net_http.Client,
    /// Configured base URL. Everything deployment-specific lives here.
    base_url: []const u8,
    /// Bearer credential for the WRITE path only.
    ///
    /// Null means "use whatever `net/auth.zig` decides", which attaches a
    /// depot token only when the URL targets the configured Pkg server and
    /// nothing otherwise. Set it when the store is somewhere else — that is
    /// the whole of the write-path auth story, and it is why this module does
    /// not need an S3 client: an object bucket behind a reverse proxy takes a
    /// bearer token like anything else.
    ///
    /// It is never sent on a read (the read path is a public GET) and never
    /// survives a redirect, because `net/http.zig`'s `put` does not follow
    /// redirects at all.
    write_token: ?[]const u8 = null,
    options: Options = .{},

    /// GET and verify one object. Nothing is written anywhere; the caller gets
    /// the stored (still zstd) bytes.
    ///
    /// Arena-lifetime: `bytes` and every string on the result come from
    /// `arena`. `gpa` backs a scratch arena that is reset between retries and
    /// released before return, so the peak is ONE object body however many
    /// attempts a flaky store costs.
    pub fn getObject(self: *const Store, gpa: Allocator, arena: Allocator, hash: Hash) Error!Object {
        const url = try objectUrl(arena, self.base_url, hash);
        return self.getVerified(gpa, arena, url, hash, self.options.max_object_bytes);
    }

    /// GET, verify and parse one manifest.
    ///
    /// The blake3 is checked over the raw bytes BEFORE the JSON is parsed —
    /// the same ordering as everything else here. Feeding an unverified
    /// document to a parser is a smaller risk than feeding one to a
    /// decompressor, but it is not zero, and the check costs one pass.
    pub fn getManifest(self: *const Store, gpa: Allocator, arena: Allocator, hash: Hash) Error!FetchedManifest {
        const url = try manifestUrl(arena, self.base_url, hash);
        const got = try self.getVerified(gpa, arena, url, hash, self.options.max_manifest_bytes);
        var out: FetchedManifest = .{
            .hash = got.hash,
            .url = got.url,
            .failure = got.failure,
            .status = got.status,
            .computed = got.computed,
            .attempts = got.attempts,
        };
        if (got.failure != null) return out;

        out.manifest = Manifest.parse(arena, got.bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                out.failure = .malformed_manifest;
                return out;
            },
        };
        return out;
    }

    /// GET, verify, decompress and extract one object into `dest_path`,
    /// published by a single rename.
    ///
    /// **Nothing at all happens on the filesystem unless the object verified.**
    /// The hash check, the decompression and the path-safety pass all run
    /// before `depot.begin`, so a rejected object leaves no staging directory
    /// and — unlike the artifact installer, which stages before it hashes — not
    /// even the parent chain `begin` would otherwise create.
    ///
    /// `dest_path` is a DIRECTORY the caller names. Deciding what that
    /// directory is — which is where the slug-rename-on-import lives — is the
    /// importer's job, not the transport's.
    ///
    /// Arena-lifetime: the result comes from `arena`. `gpa` backs the object
    /// body, the decompressed archive and the safety pass, all of which are
    /// freed before return.
    pub fn fetchObject(
        self: *const Store,
        gpa: Allocator,
        arena: Allocator,
        io: Io,
        hash: Hash,
        dest_path: []const u8,
    ) FetchError!Installed {
        const got = try self.getObject(gpa, arena, hash);
        if (!got.ok()) return .{ .object = got };

        const tar_bytes = unzstd(gpa, got.bytes, self.options.max_uncompressed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ObjectTooLarge => return .{ .object = withFailure(got, .too_large) },
            error.DecompressFailed => return .{ .object = withFailure(got, .decompress_failed) },
        };
        defer gpa.free(tar_bytes);

        // `install/extract.zig`'s guard, reused rather than reimplemented: it
        // rejects every archive shape whose meaning on disk differs from its
        // meaning in the archive (`..`, a symlink used as a directory prefix,
        // a path claimed twice). A cache object lands under a depot the loader
        // reads, so an escaping path is not a theoretical concern. `.top_level`
        // because a store object is the tree, with no generated wrapper.
        //
        // What is deliberately NOT reused is `verifyAndExtractTar`: that
        // compares a git tree hash, and no such pin exists for a build product.
        var norm = extract.normalize(gpa, tar_bytes, .top_level) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsafePath, error.PathTooDeep, error.SymlinkPrefix, error.ConflictingPaths => return .{
                .object = withFailure(got, .unsafe_archive),
            },
            else => return .{ .object = withFailure(got, .malformed_archive) },
        };
        defer norm.deinit(gpa);

        // ---- Nothing above this line touched the filesystem. ----
        var install = try depot_mod.begin(arena, io, dest_path);
        defer install.deinit(io);

        var reader = Io.Reader.fixed(norm.bytes);
        std.tar.extract(io, install.dir, &reader, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // Unreachable with `diagnostics = null`, but spelled out so a
            // machine-level condition can never be laundered into "this object
            // is bad" if that ever changes.
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .object = withFailure(got, .write_failed) },
        };

        const outcome = install.commit(gpa, io, .{
            .retry = self.options.commit_retry,
            .set_readonly = self.options.set_readonly,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return .{ .object = withFailure(got, .write_failed) },
        };

        return .{
            .object = got,
            .outcome = switch (outcome) {
                .installed => .installed,
                .already_present => .already_present,
            },
            .path = dest_path,
        };
    }

    /// PUT `bytes` as an object, named by their own BLAKE3.
    ///
    /// The name is computed here, from the body, and is returned — a caller
    /// cannot address an object as something it is not. That is also what
    /// makes the retry in `net/http.zig`'s `put` safe: a re-sent request is
    /// byte-identical and lands at the same immutable URL.
    pub fn putObject(self: *const Store, arena: Allocator, bytes: []const u8) Error!Object {
        const hash = hashBytes(bytes);
        const url = try objectUrl(arena, self.base_url, hash);
        return self.putTo(arena, url, hash, bytes, "application/zstd");
    }

    /// Render a manifest canonically and PUT it, returning the hash it is now
    /// addressable by — which is the handle a deployment tags an image or a
    /// build with.
    pub fn putManifest(self: *const Store, arena: Allocator, manifest: Manifest) Error!Object {
        const bytes = try manifest.render(arena);
        const hash = hashBytes(bytes);

        // `render` is a serialiser, not a validator: it will happily emit
        // duplicate keys or a schema no reader accepts, and the store is
        // immutable, so publishing one of those is permanent. Re-reading our
        // own bytes before sending them closes that: a manifest goes into the
        // store only if a reader can get it back out. Manifests are a few
        // hundred entries, so the parse is free next to the request.
        _ = Manifest.parse(arena, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .hash = hash,
                .url = try manifestUrl(arena, self.base_url, hash),
                .failure = .malformed_manifest,
            },
        };
        const url = try manifestUrl(arena, self.base_url, hash);
        return self.putTo(arena, url, hash, bytes, "application/json");
    }

    // -- internals ----------------------------------------------------------

    /// GET `url`, retry, and check the BLAKE3 before returning a single byte
    /// to the caller.
    /// Look one derivation key up. A miss is a `FetchedPointer` with no
    /// pointer, not an error.
    ///
    /// **This is the one GET whose body cannot be checked against its own
    /// address**, because a key names a derivation and not a byte string. So
    /// the trust chain is one hop longer and ends in the same place: the
    /// pointer names an object by BLAKE3, `fetchObject` refuses anything whose
    /// bytes do not hash to it, and `jicache.zig` parses the `.ji` header
    /// before the entry is believed. Nothing here is trusted because a store
    /// said it.
    ///
    /// A 404 is the common case and is deliberately not a `Failure`: on a cold
    /// machine most of the environment misses, and a run that logged each one
    /// would bury the entries it did find.
    pub fn getPointer(
        self: *const Store,
        gpa: Allocator,
        arena: Allocator,
        key_hex: []const u8,
    ) Error!FetchedPointer {
        const url = try keyUrl(arena, self.base_url, key_hex);
        var out: FetchedPointer = .{ .url = redactUrl(arena, url) catch url };

        var scratch_state: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_state.deinit();

        const total = @max(self.options.retry.attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            out.attempts = attempt;
            out.failure = null;
            out.status = null;

            const res = self.client.get(scratch_state.allocator(), url, .{
                .retry = .none,
                .max_body_bytes = self.options.max_pointer_bytes,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.ResponseTooLarge => blk: {
                    out.failure = .too_large;
                    break :blk null;
                },
                else => blk: {
                    out.failure = .transport;
                    break :blk null;
                },
            };

            if (res) |r| {
                out.status = r.status;
                if (r.ok()) {
                    out.pointer = Pointer.parse(arena, r.body) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            out.failure = .malformed_manifest;
                            return out;
                        },
                    };
                    return out;
                }
                // A miss. Reported as a status and no failure, so a caller can
                // tell "not here" from "could not ask".
                if (r.status == .not_found) return out;
                out.failure = .http_status;
            }

            const retryable = switch (out.failure.?) {
                .transport => true,
                .http_status => out.status.?.class() == .server_error,
                else => false,
            };
            if (!retryable or attempt >= total) return out;
            _ = scratch_state.reset(.free_all);
            try self.client.io.sleep(self.options.retry.delay, .awake);
        }
    }

    /// Publish `keys/<key>.json`. The object itself must already be in
    /// `objects/`, or the pointer names bytes nobody can fetch — `putObject`
    /// first, then this, never the other way round.
    pub fn putPointer(
        self: *const Store,
        arena: Allocator,
        key_hex: []const u8,
        pointer: Pointer,
    ) Error!Object {
        const url = try keyUrl(arena, self.base_url, key_hex);
        const body = try pointer.render(arena);
        return self.putTo(arena, url, hashBytes(body), body, "application/json");
    }

    fn getVerified(
        self: *const Store,
        gpa: Allocator,
        arena: Allocator,
        url: []const u8,
        want: Hash,
        max_bytes: usize,
    ) Error!Object {
        // The REQUEST uses `url`; the result carries a redacted copy, because
        // `Object.url` is a diagnostics field callers print.
        var out: Object = .{ .hash = want, .url = redactUrl(arena, url) catch url };

        var scratch_state: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_state.deinit();

        const total = @max(self.options.retry.attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            out.attempts = attempt;
            out.failure = null;
            out.status = null;
            out.computed = null;
            out.bytes = "";

            const res = self.client.get(scratch_state.allocator(), url, .{
                // One try per call: the loop is ours so the scratch arena can
                // be reset between attempts.
                .retry = .none,
                .max_body_bytes = max_bytes,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.ResponseTooLarge => blk: {
                    out.failure = .too_large;
                    break :blk null;
                },
                else => blk: {
                    out.failure = .transport;
                    break :blk null;
                },
            };

            if (res) |r| {
                out.status = r.status;
                if (r.ok()) {
                    const got = hashBytes(r.body);
                    if (std.mem.eql(u8, &got, &want)) {
                        // Copy into the caller's arena only once the bytes are
                        // known to be the right ones: a rejected object is not
                        // worth an allocation that outlives this loop.
                        out.bytes = try arena.dupe(u8, r.body);
                        return out;
                    }
                    out.failure = .hash_mismatch;
                    out.computed = try arena.dupe(u8, &toHex(got));
                } else {
                    out.failure = .http_status;
                }
            }

            // Only a transport-level failure can change on a second try. A
            // corrupt object and a 404 are both stable answers, and a store
            // that serves the wrong bytes will serve them again — the same
            // reasoning `ops/install_artifacts.zig` applies to a mirror.
            const retryable = switch (out.failure.?) {
                .transport => true,
                .http_status => out.status.?.class() == .server_error,
                else => false,
            };
            if (!retryable or attempt >= total) return out;

            _ = scratch_state.reset(.free_all);
            // `.awake` is the monotonic clock that does not tick while
            // suspended, which is the right one for a backoff.
            try self.client.io.sleep(self.options.retry.delay, .awake);
        }
    }

    fn putTo(
        self: *const Store,
        arena: Allocator,
        url: []const u8,
        hash: Hash,
        bytes: []const u8,
        content_type: []const u8,
    ) Error!Object {
        var out: Object = .{ .hash = hash, .url = redactUrl(arena, url) catch url };

        var headers: []const http.Header = &.{};
        if (self.write_token) |token| {
            const hs = try arena.alloc(http.Header, 1);
            hs[0] = .{
                .name = "Authorization",
                .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}),
            };
            headers = hs;
        }

        // The retry loop is HERE, not in `net/http.zig`'s `put`, for the two
        // reasons `getVerified` keeps its own:
        //
        //   * `Object.attempts` promises "requests actually issued", and a
        //     loop one layer down cannot report through it.
        //   * A write body is up to hundreds of megabytes, and `Client.put`'s
        //     own loop repeats on ANY non-2xx. Re-streaming an object three
        //     times because a store said 403 — or 400, or 413 — spends minutes
        //     to arrive at the same answer. Only a transport failure or a 5xx
        //     can change, which is exactly the classification the read side
        //     already makes.
        const total = @max(self.options.retry.attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            out.attempts = attempt;
            out.failure = null;
            out.status = null;

            const res = self.client.put(arena, url, bytes, .{
                // One try per call; the loop is ours.
                .retry = .none,
                // An explicit store credential replaces the depot lookup
                // rather than joining it: two `Authorization` headers is a
                // request no server has to make sense of.
                .authenticate = self.write_token == null,
                .content_type = content_type,
                .extra_headers = headers,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.ResponseTooLarge => blk: {
                    out.failure = .too_large;
                    break :blk null;
                },
                else => blk: {
                    out.failure = .transport;
                    break :blk null;
                },
            };

            if (res) |r| {
                out.status = r.status;
                if (r.ok()) return out;
                out.failure = .http_status;
            }

            const retryable = switch (out.failure.?) {
                .transport => true,
                .http_status => out.status.?.class() == .server_error,
                else => false,
            };
            if (!retryable or attempt >= total) return out;
            try self.client.io.sleep(self.options.retry.delay, .awake);
        }
    }
};

fn withFailure(o: Object, f: Failure) Object {
    var out = o;
    out.failure = f;
    // The verified bytes are no longer the interesting part of the story once
    // something downstream rejected them, and leaving them attached invites a
    // caller to use an object it was told to throw away.
    out.bytes = "";
    return out;
}

// ---------------------------------------------------------------------------
// Tests
//
// There is no Julia oracle for any of this: Pkg has no object store, and the
// hash is BLAKE3, which Julia does not ship. What stands in for one is
// twofold — the official BLAKE3 reference vectors (checked here, and again in
// `tools/diff_harness/cache_store.sh`), and the real `zstd` CLI, which the
// harness uses to prove that a frame this module wrote is a frame the
// reference implementation reads.
//
// The transport itself gets a loopback server, following `net/http.zig` and
// `ops/install_artifacts.zig`: scripted raw responses, one request per
// connection, and a log of what each request carried. That log is the only way
// to observe the assertions that matter — that a PUT really sent the body and
// the credential, and that a retry stopped when it should.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an object name is the BLAKE3 of its bytes" {
    // Official BLAKE3 reference vectors, input_len 0 and 1. Source:
    // https://github.com/BLAKE3-team/BLAKE3/blob/master/test_vectors/test_vectors.json
    // (the same file std's own blake3 tests are generated from). The input for
    // a case of length n is the 251-byte repeating pattern 0,1,...,250,0,1,...
    try testing.expectEqualStrings(
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
        &toHex(hashBytes("")),
    );
    try testing.expectEqualStrings(
        "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
        &toHex(hashBytes(&[_]u8{0})),
    );

    const h = hashBytes("cache object");
    try testing.expectEqual(h, try parseHash(&toHex(h)));
    // Uppercase parses; only lowercase is ever produced, or the store stops
    // deduplicating.
    var upper: [hex_len]u8 = undefined;
    _ = std.ascii.upperString(&upper, &toHex(h));
    try testing.expectEqual(h, try parseHash(&upper));
    try testing.expectError(error.InvalidHash, parseHash("deadbeef"));
    try testing.expectError(error.InvalidHash, parseHash("z" ** hex_len));
}

test "URLs put the deployment in the base and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h = try parseHash("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    try testing.expectEqualStrings(
        "https://cdn.example/ajt/objects/00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.tar.zst",
        try objectUrl(arena, "https://cdn.example/ajt", h),
    );
    try testing.expectEqualStrings(
        "https://cdn.example/ajt/manifests/00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.json",
        try manifestUrl(arena, "https://cdn.example/ajt", h),
    );
    // A trailing slash in the configured base must not become `//objects/`,
    // which most proxies treat as a different path.
    try testing.expectEqualStrings(
        "https://cdn.example/ajt/objects/00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.tar.zst",
        try objectUrl(arena, "https://cdn.example/ajt///", h),
    );
}

test "a raw zstd frame round-trips, at every size that changes its block layout" {
    const gpa = testing.allocator;
    const max_block = std.compress.zstd.block_size_max;

    const sizes = [_]usize{ 0, 1, 4096, max_block - 1, max_block, max_block + 1, 3 * max_block + 7 };
    for (sizes) |n| {
        const src = try gpa.alloc(u8, n);
        defer gpa.free(src);
        // A pattern, not zeros: zeros would round-trip through a framer that
        // dropped the payload entirely.
        for (src, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

        const frame = try rawFrame(gpa, src);
        defer gpa.free(frame);
        // Real zstd magic, so `file`, `zstd -d` and std all agree it is one.
        try testing.expectEqualSlices(u8, &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD }, frame[0..4]);

        const back = try unzstd(gpa, frame, 1 << 30);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, src, back);
    }
}

test "the decompression cap is enforced during the read" {
    const gpa = testing.allocator;
    const src = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(src);
    @memset(src, 'x');
    const frame = try rawFrame(gpa, src);
    defer gpa.free(frame);

    try testing.expectError(error.ObjectTooLarge, unzstd(gpa, frame, 1024));
    // Exactly at the cap is allowed -- "max" reads as inclusive.
    const back = try unzstd(gpa, frame, src.len);
    defer gpa.free(back);
    try testing.expectEqual(src.len, back.len);

    // Not zstd at all.
    try testing.expectError(error.DecompressFailed, unzstd(gpa, "not a frame", 1 << 20));
    // A truncated frame: the magic and header are right, the payload is not.
    try testing.expectError(error.DecompressFailed, unzstd(gpa, frame[0 .. frame.len - 16], 1 << 20));
}

test "a manifest round-trips hashes, sizes and build times, canonically" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m: Manifest = .{ .entries = &.{
        .{ .key = "kzzz", .name = "Zlib_jll", .object = hashBytes("z"), .size = 12, .build_ms = 40 },
        .{ .key = "kaaa", .name = "Adapt", .object = hashBytes("a"), .size = 3_456_789, .build_ms = 91_234 },
        .{ .key = "kmmm", .name = "Makie", .object = hashBytes("m"), .size = 0, .build_ms = 0 },
    } };

    const bytes = try m.render(arena);
    const back = try Manifest.parse(arena, bytes);
    try testing.expectEqual(@as(usize, 3), back.entries.len);
    for (back.entries) |e| {
        const orig = m.find(e.key).?;
        try testing.expectEqualStrings(orig.name, e.name);
        try testing.expectEqual(orig.object, e.object);
        try testing.expectEqual(orig.size, e.size);
        // The cost model is the reason this file exists at all; a round trip
        // that dropped it would still look fine to every other assertion.
        try testing.expectEqual(orig.build_ms, e.build_ms);
    }

    // Canonical: sorted by key, so identical content is identical bytes and
    // therefore ONE object in a content-addressed store.
    try testing.expectEqualStrings("kaaa", back.entries[0].key);
    try testing.expectEqualStrings("kmmm", back.entries[1].key);
    try testing.expectEqualStrings("kzzz", back.entries[2].key);
    const shuffled: Manifest = .{ .entries = &.{ m.entries[1], m.entries[2], m.entries[0] } };
    try testing.expectEqualStrings(bytes, try shuffled.render(arena));
    try testing.expectEqualStrings(bytes, try back.render(arena));

    // An EMPTY manifest is a legitimate document: a store with nothing
    // published yet, or an environment every entry of which was filtered out.
    // It has to parse, render and re-parse like any other.
    const empty = try Manifest.parse(arena, "{\"schema\":1,\"objects\":[]}");
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expectEqualStrings("{\"schema\":1,\"objects\":[]}", try empty.render(arena));
    try testing.expectEqual(@as(usize, 0), (try Manifest.parse(arena, try (Manifest{}).render(arena))).entries.len);

    // A large build time survives as an integer, not as a float that rounds.
    const big: Manifest = .{ .entries = &.{
        .{ .key = "k", .object = hashBytes("k"), .size = 9_007_199_254_740_993, .build_ms = 1_234_567_890 },
    } };
    const reparsed = try Manifest.parse(arena, try big.render(arena));
    try testing.expectEqual(@as(u64, 9_007_199_254_740_993), reparsed.entries[0].size);
    try testing.expectEqual(@as(u64, 1_234_567_890), reparsed.entries[0].build_ms);
}

test "a manifest that cannot be trusted is refused, not half-read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.MalformedJson, Manifest.parse(arena, "{"));
    try testing.expectError(error.MalformedJson, Manifest.parse(arena, "{\"schema\":1}"));
    try testing.expectError(
        error.UnsupportedSchema,
        Manifest.parse(arena, "{\"schema\":2,\"objects\":[]}"),
    );
    try testing.expectError(error.MalformedHash, Manifest.parse(arena,
        \\{"schema":1,"objects":[{"key":"k","object":"nope","size":1,"build_ms":2}]}
    ));
    // Two entries for one key: picking one silently is how a cache imports the
    // wrong build.
    try testing.expectError(error.DuplicateKey, Manifest.parse(arena,
        \\{"schema":1,"objects":[
        \\ {"key":"k","object":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","size":1,"build_ms":2},
        \\ {"key":"k","object":"ff112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","size":1,"build_ms":2}]}
    ));

    // An unknown field is additive and must NOT break an older reader -- that
    // is what keeps `schema` a rare event.
    const forward = try Manifest.parse(arena,
        \\{"schema":1,"unknown":true,"objects":[
        \\ {"key":"k","name":"N","object":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        \\  "size":1,"build_ms":2,"future":"x"}]}
    );
    try testing.expectEqual(@as(usize, 1), forward.entries.len);
    try testing.expectEqual(@as(u64, 2), forward.entries[0].build_ms);
    // `name` is optional; a manifest without it still parses.
    const nameless = try Manifest.parse(arena,
        \\{"schema":1,"objects":[{"key":"k",
        \\ "object":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","size":1,"build_ms":2}]}
    );
    try testing.expectEqualStrings("", nameless.entries[0].name);
}

// ---------------------------------------------------------------------------
// Loopback tests
// ---------------------------------------------------------------------------

/// Scripted loopback HTTP server, following `ops/install_artifacts.zig`'s: one
/// request per connection, `Connection: close` on every response, and a log of
/// method, target, `Authorization` and body.
const TestServer = struct {
    server: Io.net.Server,
    port: u16,
    count: usize = 0,
    lines: [max_requests][160]u8 = undefined,
    line_len: [max_requests]usize = @splat(0),
    auths: [max_requests][96]u8 = undefined,
    auth_len: [max_requests]usize = @splat(0),
    bodies: [max_requests][512]u8 = undefined,
    body_len: [max_requests]usize = @splat(0),

    const max_requests = 8;

    /// A range of its own, disjoint from the other two loopback suites: with
    /// SO_REUSEPORT a second listen on a live port SUCCEEDS and the kernel
    /// load-balances between them, which would show up as a request landing on
    /// the wrong server.
    const port_base = 43871;
    const port_span = 500;
    var next_offset: std.atomic.Value(u16) = .init(0);

    fn start(io: Io) !TestServer {
        const first = next_offset.fetchAdd(1, .monotonic);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // An EXCLUSIVE bind: `reuse_address` would set SO_REUSEPORT, under
            // which a second `listen` on a live port succeeds and the kernel
            // load-balances connections between the two servers. See the long
            // note on `LoopbackServer.start` in `src/net/http.zig`.
            const srv = addr.listen(io, .{}) catch continue;
            return .{ .server = srv, .port = port };
        }
        return error.NoFreePort;
    }

    fn deinit(self: *TestServer, io: Io) void {
        self.server.deinit(io);
    }

    fn baseUrl(self: *const TestServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    /// `GET /objects/<hex>.tar.zst HTTP/1.1`, verbatim.
    fn requestLine(self: *const TestServer, i: usize) []const u8 {
        return self.lines[i][0..self.line_len[i]];
    }
    fn authorization(self: *const TestServer, i: usize) []const u8 {
        return self.auths[i][0..self.auth_len[i]];
    }
    fn body(self: *const TestServer, i: usize) []const u8 {
        return self.bodies[i][0..self.body_len[i]];
    }

    /// Serves exactly `script.len` requests, then returns. Every test must
    /// issue exactly that many, or the two sides deadlock rather than fail.
    fn serve(io: Io, self: *TestServer, script: []const []const u8) void {
        for (script) |response| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            const r = &sr.interface;

            const i = self.count;
            if (i >= max_requests) return;
            self.count += 1;

            const request_line = r.takeDelimiterInclusive('\n') catch return;
            const trimmed = std.mem.trimEnd(u8, request_line, "\r\n");
            const n = @min(trimmed.len, self.lines[i].len);
            @memcpy(self.lines[i][0..n], trimmed[0..n]);
            self.line_len[i] = n;

            var content_length: usize = 0;
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break; // the blank line ending the head
                if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                    const v = std.mem.trim(u8, line["authorization:".len..], " \t\r\n");
                    const m = @min(v.len, self.auths[i].len);
                    @memcpy(self.auths[i][0..m], v[0..m]);
                    self.auth_len[i] = m;
                }
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const v = std.mem.trim(u8, line["content-length:".len..], " \t\r\n");
                    content_length = std.fmt.parseInt(usize, v, 10) catch 0;
                }
            }
            if (content_length != 0) {
                // The body is READ, not just counted: proving a PUT sent the
                // right bytes is the only assertion the write path has.
                const want = @min(content_length, self.bodies[i].len);
                r.readSliceAll(self.bodies[i][0..want]) catch return;
                self.body_len[i] = want;
                if (content_length > want) r.discardAll(content_length - want) catch return;
            }

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            sw.interface.writeAll(response) catch {};
            sw.interface.flush() catch {};
        }
    }
};

fn okBody(arena: Allocator, payload: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ payload.len, payload },
    );
}

const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const server_error = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const created = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// A tar with a subdirectory and an executable file -- the shape a `compiled/`
/// object really has.
fn sampleTar(gpa: Allocator) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try tw.writeFileBytes("Example/abcde.ji", "\xfe\xff not really a cache header\n", .{ .mode = 0o644 });
    try tw.writeFileBytes("Example/abcde.so", "\x7fELF\n", .{ .mode = 0o755 });
    try tw.finishPedantically();
    return out.toOwnedSlice();
}

fn dirEntries(io: Io, dir: Io.Dir, sub: []const u8) !usize {
    var d = try dir.openDir(io, sub, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "an object round-trips: PUT names it by its hash, GET verifies and extracts it" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const tar = try sampleTar(gpa);
    defer gpa.free(tar);
    const object = try rawFrame(gpa, tar);
    defer gpa.free(object);
    const hash = hashBytes(object);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{ created, try okBody(arena, object) };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{ .depot = depot });
    defer client.deinit();
    const store: Store = .{
        .client = &client,
        .base_url = base,
        .write_token = "s3cret",
        .options = .{ .retry = .none },
    };

    // ---- write ----
    const put = try store.putObject(arena, object);
    try testing.expect(put.ok());
    try testing.expectEqual(hash, put.hash);

    // ---- read ----
    const dest = try std.fs.path.join(arena, &.{ depot, "compiled", "v1.12" });
    const got = try store.fetchObject(gpa, arena, io, hash, dest);
    task.await(io);

    try testing.expect(got.object.ok());
    try testing.expectEqual(Outcome.installed, got.outcome.?);

    // The PUT went to the content-addressed path, carried the body, and
    // carried the store credential.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "PUT /objects/{s}.tar.zst HTTP/1.1", .{&toHex(hash)}),
        srv.requestLine(0),
    );
    try testing.expectEqualStrings("Bearer s3cret", srv.authorization(0));
    try testing.expectEqualSlices(u8, object[0..@min(object.len, 512)], srv.body(0));
    // ...and the GET asked for the same URL, without the write credential.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "GET /objects/{s}.tar.zst HTTP/1.1", .{&toHex(hash)}),
        srv.requestLine(1),
    );
    try testing.expectEqualStrings("", srv.authorization(1));

    // The content is on disk, at the path the caller named.
    const ji = try Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(arena, &.{ dest, "Example", "abcde.ji" }),
        gpa,
        .limited(1024),
    );
    defer gpa.free(ji);
    try testing.expectEqualStrings("\xfe\xff not really a cache header\n", ji);
    // Not read-only: `compiled/` is Julia's to rewrite.
    const st = try Io.Dir.cwd().statFile(
        io,
        try std.fs.path.join(arena, &.{ dest, "Example", "abcde.ji" }),
        .{},
    );
    try testing.expect(!st.permissions.readOnly());
    // No staging leftovers beside it.
    try testing.expectEqual(@as(usize, 1), try dirEntries(io, tmp.dir, "compiled"));
}

test "a corrupted object is rejected with nothing written" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const tar = try sampleTar(gpa);
    defer gpa.free(tar);
    const object = try rawFrame(gpa, tar);
    defer gpa.free(object);
    const hash = hashBytes(object);

    // One byte of PAYLOAD flipped. The frame stays structurally valid and
    // would decompress and extract perfectly well -- only the name no longer
    // describes it, which is the whole point of checking.
    const bad = try gpa.dupe(u8, object);
    defer gpa.free(bad);
    bad[bad.len - 4] +%= 1;

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{try okBody(arena, bad)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{ .depot = depot });
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    // The destination's PARENT is created up front, so "nothing was written"
    // is an assertion about an empty directory rather than a missing one.
    try tmp.dir.createDirPath(io, "compiled");
    const dest = try std.fs.path.join(arena, &.{ depot, "compiled", "v1.12" });

    const got = try store.fetchObject(gpa, arena, io, hash, dest);
    task.await(io);

    try testing.expect(!got.object.ok());
    try testing.expectEqual(Failure.hash_mismatch, got.object.failure.?);
    try testing.expect(got.outcome == null);
    // Both sides of the mismatch, or it cannot be diagnosed.
    try testing.expectEqualStrings(&toHex(hashBytes(bad)), got.object.computed.?);
    try testing.expect(!std.mem.eql(u8, &toHex(hash), got.object.computed.?));
    // A hash mismatch is not retried: the store will serve the same bytes.
    try testing.expectEqual(@as(u32, 1), got.object.attempts);

    // THE assertion: not a byte, and not a staging directory either. Unlike
    // the artifact installer, this path returns before `depot.begin`, so even
    // the destination's own parent chain is untouched.
    try testing.expectEqual(@as(usize, 0), try dirEntries(io, tmp.dir, "compiled"));
}

test "a store miss is a 404, and is not a failure to shout about" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{not_found};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{
        .retry = .{ .attempts = 3, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    } };

    const got = try store.getObject(gpa, arena, hashBytes("absent"));
    task.await(io);

    try testing.expect(!got.ok());
    try testing.expect(got.miss());
    // A 404 is a stable answer; retrying one only burns the caller's time.
    try testing.expectEqual(@as(u32, 1), got.attempts);
    try testing.expectEqual(@as(usize, 1), srv.count);
}

test "retry survives a flaky store and then gives up cleanly" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const object = try rawFrame(gpa, "payload");
    defer gpa.free(object);
    const hash = hashBytes(object);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{
        server_error,
        server_error,
        try okBody(arena, object),
        // The give-up half: three more failures against a 3-attempt budget.
        server_error,
        server_error,
        server_error,
    };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{
        .retry = .{ .attempts = 3, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    } };

    const good = try store.getObject(gpa, arena, hash);
    try testing.expect(good.ok());
    try testing.expectEqual(@as(u32, 3), good.attempts);
    try testing.expectEqualSlices(u8, object, good.bytes);

    // The bytes must have been COPIED out of the scratch arena, which
    // `getObject` released on the way out. Churning the same allocator makes
    // it reuse those very pages, so a returned slice that still pointed into
    // them would come back changed -- a use-after-free this assertion can see
    // and a plain equality check immediately after the call cannot.
    for (0..8) |_| {
        const churn = try gpa.alloc(u8, 64 * 1024);
        @memset(churn, 0xAA);
        gpa.free(churn);
    }
    try testing.expectEqualSlices(u8, object, good.bytes);

    // Budget exhausted: a Failure, not a hang and not an error.
    const bad = try store.getObject(gpa, arena, hash);
    task.await(io);
    try testing.expect(!bad.ok());
    try testing.expectEqual(Failure.http_status, bad.failure.?);
    try testing.expectEqual(http.Status.service_unavailable, bad.status.?);
    try testing.expectEqual(@as(u32, 3), bad.attempts);
    try testing.expectEqual(@as(usize, 6), srv.count);
}

test "a manifest round-trips over the wire, hashes, sizes and build times intact" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m: Manifest = .{ .entries = &.{
        .{ .key = "k2", .name = "Zlib_jll", .object = hashBytes("two"), .size = 4_096, .build_ms = 12_500 },
        .{ .key = "k1", .name = "Adapt", .object = hashBytes("one"), .size = 1_048_576, .build_ms = 340 },
    } };
    const bytes = try m.render(arena);
    const hash = hashBytes(bytes);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{ created, try okBody(arena, bytes) };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const put = try store.putManifest(arena, m);
    try testing.expect(put.ok());
    // The publisher learns the handle the manifest is now addressable by.
    try testing.expectEqual(hash, put.hash);

    const got = try store.getManifest(gpa, arena, hash);
    task.await(io);
    try testing.expect(got.ok());
    try testing.expectEqual(@as(usize, 2), got.manifest.entries.len);

    const adapt = got.manifest.find("k1").?;
    try testing.expectEqualStrings("Adapt", adapt.name);
    try testing.expectEqual(hashBytes("one"), adapt.object);
    try testing.expectEqual(@as(u64, 1_048_576), adapt.size);
    try testing.expectEqual(@as(u64, 340), adapt.build_ms);
    const zlib = got.manifest.find("k2").?;
    try testing.expectEqual(@as(u64, 12_500), zlib.build_ms);

    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "PUT /manifests/{s}.json HTTP/1.1", .{&toHex(hash)}),
        srv.requestLine(0),
    );
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "GET /manifests/{s}.json HTTP/1.1", .{&toHex(hash)}),
        srv.requestLine(1),
    );
}

test "a key round-trips: the lookup a cold machine can make without being told anything" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A derivation key as `cache/key.zig` renders one: 64 hex characters.
    const key_hex = "9f" ** 32;
    const p: Pointer = .{
        .object = hashBytes("the archived .ji"),
        .size = 4_096,
        .build_ms = 12_500,
        .name = "StaticArrays",
    };

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{ created, try okBody(arena, try p.render(arena)) };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const put = try store.putPointer(arena, key_hex, p);
    try testing.expect(put.ok());

    const got = try store.getPointer(gpa, arena, key_hex);
    task.await(io);
    try testing.expect(!got.miss());
    try testing.expectEqual(p.object, got.pointer.?.object);
    try testing.expectEqual(@as(u64, 12_500), got.pointer.?.build_ms);
    try testing.expectEqualStrings("StaticArrays", got.pointer.?.name);

    // The address is the key itself — nothing had to be discovered to build it.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "PUT /keys/{s}.json HTTP/1.1", .{key_hex}),
        srv.requestLine(0),
    );
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "GET /keys/{s}.json HTTP/1.1", .{key_hex}),
        srv.requestLine(1),
    );
}

test "a key that is not in the store is a miss, not a failure" {
    // The common case on a cold machine: most of the environment misses, and a
    // caller that treated each one as an error would log a screenful and then
    // compile anyway.
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{not_found};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const got = try store.getPointer(gpa, arena, "ab" ** 32);
    task.await(io);
    try testing.expect(got.miss());
    try testing.expect(got.failure == null);
    try testing.expectEqual(std.http.Status.not_found, got.status.?);
}

test "a key whose body is not a pointer is a failure, not a silent miss" {
    // A miss means "compile it"; a malformed answer means the store is broken.
    // Collapsing the two would let a misconfigured base URL that 200s an HTML
    // error page look like an empty cache forever.
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{try okBody(arena, "<html>not found</html>")};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const got = try store.getPointer(gpa, arena, "cd" ** 32);
    task.await(io);
    try testing.expect(got.miss());
    try testing.expectEqual(Failure.malformed_manifest, got.failure.?);
}

test "a pointer with an unreadable object hash is refused at parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(
        error.MalformedHash,
        Pointer.parse(arena, "{\"schema\":1,\"object\":\"nothex\",\"size\":1,\"build_ms\":1}"),
    );
    // A schema nobody understands is refused loudly rather than half-read, for
    // the same reason `Manifest.parse` refuses one.
    try testing.expectError(
        error.UnsupportedSchema,
        Pointer.parse(arena, "{\"schema\":99,\"object\":\"" ++ "00" ** 32 ++ "\"}"),
    );
}

test "a manifest that verifies but does not parse is a failure, not a crash" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Correctly named -- the blake3 matches -- and still not a manifest. The
    // hash pins what the store served, never what it means.
    const junk = "{\"schema\":99,\"objects\":[]}";
    const hash = hashBytes(junk);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{try okBody(arena, junk)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const got = try store.getManifest(gpa, arena, hash);
    task.await(io);
    try testing.expect(!got.ok());
    try testing.expectEqual(Failure.malformed_manifest, got.failure.?);
    try testing.expectEqual(@as(usize, 0), got.manifest.entries.len);
}

test "an object whose archive escapes its destination is refused before any write" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // A symlink used as a directory prefix: extraction would follow it and
    // write OUTSIDE the staging directory. The object is perfectly well named
    // -- the attack does not need a hash collision, which is exactly why the
    // path guard cannot be skipped just because the blake3 matched.
    var tar_out: Io.Writer.Allocating = .init(gpa);
    defer tar_out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
    try tw.writeLink("Example", "../../escaped", .{});
    try tw.writeFileBytes("Example/pwned.ji", "owned\n", .{ .mode = 0o644 });
    try tw.finishPedantically();

    const object = try rawFrame(gpa, tar_out.written());
    defer gpa.free(object);
    const hash = hashBytes(object);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{try okBody(arena, object)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    try tmp.dir.createDirPath(io, "compiled");
    const dest = try std.fs.path.join(arena, &.{ depot, "compiled", "v1.12" });
    const got = try store.fetchObject(gpa, arena, io, hash, dest);
    task.await(io);

    try testing.expectEqual(Failure.unsafe_archive, got.object.failure.?);
    try testing.expectEqual(@as(usize, 0), try dirEntries(io, tmp.dir, "compiled"));
}

test "an object that is not a zstd frame fails as a decompression, not a write" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const junk = "this is not a zstd frame at all";
    const hash = hashBytes(junk);

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const script = [_][]const u8{try okBody(arena, junk)};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    try tmp.dir.createDirPath(io, "compiled");
    const dest = try std.fs.path.join(arena, &.{ depot, "compiled", "v1.12" });
    const got = try store.fetchObject(gpa, arena, io, hash, dest);
    task.await(io);

    try testing.expectEqual(Failure.decompress_failed, got.object.failure.?);
    try testing.expectEqual(@as(usize, 0), try dirEntries(io, tmp.dir, "compiled"));
}

test "an unreachable store is a transport failure on every attempt, never a hang" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    // Port 1 is reserved and never listening, so the connect refuses at once.
    const store: Store = .{ .client = &client, .base_url = "http://127.0.0.1:1/ajt", .options = .{
        .retry = .{ .attempts = 2, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    } };

    const got = try store.getObject(gpa, arena, hashBytes("anything"));
    try testing.expectEqual(Failure.transport, got.failure.?);
    // A transport failure IS worth repeating, and the budget still bounds it.
    try testing.expectEqual(@as(u32, 2), got.attempts);

    const put = try store.putObject(arena, "bytes");
    try testing.expectEqual(Failure.transport, put.failure.?);
}

test "a rejected write is not re-sent, but a 5xx one is" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    const script = [_][]const u8{
        // A 403 is a stable answer. Re-streaming an object that can be
        // hundreds of megabytes to be told the same thing costs minutes.
        forbidden,
        // A 5xx is not, so this one IS repeated: two failures then success.
        server_error,
        server_error,
        created,
    };
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{
        .retry = .{ .attempts = 3, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    } };

    const rejected = try store.putObject(arena, "payload");
    try testing.expectEqual(Failure.http_status, rejected.failure.?);
    try testing.expectEqual(http.Status.forbidden, rejected.status.?);
    // THE assertion: one request, not three.
    try testing.expectEqual(@as(u32, 1), rejected.attempts);
    try testing.expectEqual(@as(usize, 1), srv.count);

    const eventually = try store.putObject(arena, "payload");
    task.await(io);
    try testing.expect(eventually.ok());
    // ...and `attempts` reports what was actually issued, which it cannot do
    // if the retry loop lives one layer down in net/http.zig.
    try testing.expectEqual(@as(u32, 3), eventually.attempts);
    try testing.expectEqual(@as(usize, 4), srv.count);
}

test "a credential in the configured base URL does not reach the reported URL" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `Object.url` is printed by callers, and a failed fetch is exactly when
    // they print it. An object bucket configured with inline credentials must
    // not turn every log line into a disclosure.
    try testing.expectEqualStrings(
        "https://bucket.example/ajt/objects/x",
        try redactUrl(arena, "https://key:secret@bucket.example/ajt/objects/x"),
    );
    try testing.expectEqualStrings(
        "https://bucket.example/ajt",
        try redactUrl(arena, "https://token@bucket.example/ajt"),
    );
    // An `@` in the PATH is not a credential and must survive untouched.
    try testing.expectEqualStrings(
        "https://bucket.example/ajt/a@b",
        try redactUrl(arena, "https://bucket.example/ajt/a@b"),
    );
    try testing.expectEqualStrings(
        "https://bucket.example/ajt",
        try redactUrl(arena, "https://bucket.example/ajt"),
    );
    try testing.expectEqualStrings("not a url", try redactUrl(arena, "not a url"));
}

test "a manifest no reader would accept is not published" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    // Port 1 refuses immediately, so if the guard failed to fire the test
    // would report a transport failure rather than hanging.
    const store: Store = .{ .client = &client, .base_url = "http://127.0.0.1:1/ajt", .options = .{ .retry = .none } };

    // `render` is a serialiser and will emit either of these happily. The
    // store is immutable, so publishing one is permanent.
    const dup: Manifest = .{ .entries = &.{
        .{ .key = "same", .object = hashBytes("a"), .size = 1, .build_ms = 1 },
        .{ .key = "same", .object = hashBytes("b"), .size = 2, .build_ms = 2 },
    } };
    const r1 = try store.putManifest(arena, dup);
    try testing.expectEqual(Failure.malformed_manifest, r1.failure.?);
    // Refused before the request, not after it.
    try testing.expectEqual(@as(u32, 0), r1.attempts);

    const wrong_schema: Manifest = .{ .schema = 7, .entries = &.{} };
    const r2 = try store.putManifest(arena, wrong_schema);
    try testing.expectEqual(Failure.malformed_manifest, r2.failure.?);
}

test "a store that rejects a write says so instead of pretending" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var srv = try TestServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, srv.baseUrl(&url_buf));

    const forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    const script = [_][]const u8{forbidden};
    var task = try io.concurrent(TestServer.serve, .{ io, &srv, script[0..] });

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();
    const store: Store = .{ .client = &client, .base_url = base, .options = .{ .retry = .none } };

    const put = try store.putObject(arena, "payload");
    task.await(io);
    try testing.expectEqual(Failure.http_status, put.failure.?);
    try testing.expectEqual(http.Status.forbidden, put.status.?);
    // No credential configured and the URL is not the Pkg server, so
    // `net/auth.zig` attached nothing -- a depot token never travels to a host
    // it was not issued for.
    try testing.expectEqualStrings("", srv.authorization(0));
}
