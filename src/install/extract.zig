//! Verify-before-extract: turn a downloaded tarball into an installed tree,
//! and write nothing at all unless the content is provably the tree the
//! registry pinned.
//!
//! **The ordering is the point of this module.** Pkg does it the other way
//! round: `install_archive` unpacks the tarball into a temp directory, and
//! only then walks what landed on disk and compares
//! `GitTools.tree_hash(unpacked)` to the registry's `git-tree-sha1`
//! (`Pkg/src/Operations.jl:800-818`). On a mismatch it warns, throws the
//! directory away, and tries the next URL. So between "download finished" and
//! "hash checked" there is a window in which unverified bytes from the
//! network exist as real files, with real modes, on the machine — created by
//! an external `7z`/`tar` process at that (`PlatformEngines.unpack`).
//!
//! Ajt closes that window. The tree hash is computed FROM THE STREAM
//! (`treehash.hashTar`, which is a port of `Tar.tree_hash` and is gated
//! against it over the whole General registry), compared, and only if it
//! matches does anything reach the filesystem. Julia has the same primitive
//! and uses it for registries and artifacts —
//! `PlatformEngines.verify_archive_tree_hash` (`PlatformEngines.jl:692-699`)
//! hashes `7z x … -so` before unpacking — it just does not use it on the
//! package install path.
//!
//! ## The two tarball shapes
//!
//! `Operations.jl` builds a candidate list of `url => top` pairs and the
//! `top` flag is what tells the two apart:
//!
//!   * `top = true` — the Pkg-server tarball,
//!     `$server/package/$uuid/$tree_hash` (`Operations.jl:1163-1170`). Its
//!     contents are at the TOP LEVEL, so the extraction directory *is* the
//!     package (`Operations.jl:800-801`). `Shape.top_level`.
//!   * `top = false` — the GitHub fallback,
//!     `https://api.github.com/repos/O/R/tarball/<ref>`
//!     (`get_archive_url_for_version`, `Operations.jl:762-768`). `git archive`
//!     wraps everything in ONE generated directory named
//!     `<owner>-<repo>-<short-sha>`, so Pkg strips it after the fact by
//!     asserting the extraction directory has exactly one child
//!     (`Operations.jl:802-807`) — after filtering out a spurious
//!     `pax_global_header` that 7z on Windows materialises as a top-level
//!     file. `Shape.github_tarball`.
//!
//! Ajt cannot fix either of those up after extraction, because there is no
//! "after extraction" before the hash is known: the hash it must reproduce is
//! the hash of the tree INSIDE the wrapper. So `normalize` rewrites the
//! archive in memory first, and the hash and the extraction then run over the
//! very same bytes — hash and content cannot drift apart because they are
//! literally the same buffer.
//!
//! The shape is an explicit parameter, never sniffed. Pkg knows which URL it
//! asked for and so does the caller; guessing "does this archive have exactly
//! one top-level directory?" would silently strip a legitimate single-
//! directory package tarball.
//!
//! ## Empty directories
//!
//! `treehash.hashTar` takes `skip_empty` because `Tar.tree_hash` does
//! (`Tar.jl:397-398`), and the two Julia hashers disagree: `Tar.tree_hash`
//! keeps empty directories by default, `GitTools.tree_hash` prunes them via
//! `contains_files` (`GitTools.jl:280-300`). The install path must match
//! `GitTools.tree_hash`, because that is the function Pkg actually compares
//! against the registry's `git-tree-sha1` (`Operations.jl:812`) — hence
//! `Options.skip_empty` defaults to TRUE here even though `Tar.tree_hash`
//! defaults to false. For a tarball made from a git tree the two agree
//! trivially (git cannot store an empty directory); the default only matters
//! for a tarball that has one, and there the Pkg-compatible answer is to
//! ignore it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const treehash = @import("../julia/treehash.zig");
const slug = @import("../julia/slug.zig");

pub const Hash = treehash.Hash;

pub const Error = error{
    /// The gzip member did not decompress (truncated, wrong CRC, or larger
    /// than `Options.max_uncompressed`).
    DecompressFailed,
    /// Unreadable tar, or an entry whose header cannot be re-emitted.
    MalformedTar,
    /// An entry path that would mean one thing to the hasher and another to
    /// the extractor. See `canonicalize`.
    UnsafePath,
    /// A path nested deeper than `treehash.hashTar` can represent. See
    /// `max_path_components`.
    PathTooDeep,
    /// An entry is nested under a path an earlier entry declared to be a
    /// symlink. Julia refuses this by name — "Refusing to extract — possible
    /// attack!" (`Tar/src/extract.jl:361-368`) — and so does Ajt. See
    /// `PathGuard`.
    SymlinkPrefix,
    /// Two entries claim the same path with incompatible meanings (the same
    /// file twice, or a name used as both a file and a directory). See
    /// `PathGuard`.
    ConflictingPaths,
    /// A `github_tarball` did not have exactly one root directory. This is
    /// Pkg's `@assert length(dirs) == 1` (`Operations.jl:806`) moved ahead of
    /// extraction.
    NotSingleRooted,
    /// The archive is not the tree the registry pinned. Nothing was written.
    TreeHashMismatch,
    /// The content verified, but writing it out failed — out of space, denied,
    /// a name the filesystem rejects. The destination may hold a partial tree;
    /// it is the caller's temp directory to delete.
    ExtractFailed,
} || Allocator.Error;

/// Where the package tree sits inside the archive. Chosen by the caller from
/// the URL it downloaded, never guessed from the bytes.
pub const Shape = enum {
    /// Pkg-server tarball: the package tree is the archive
    /// (`Operations.jl:1167`, `top = true`).
    top_level,
    /// GitHub `/tarball/<ref>`: one generated wrapper directory to strip, plus
    /// a `pax_global_header` to drop (`Operations.jl:762-768`, `:802-807`).
    github_tarball,
};

pub const Options = struct {
    shape: Shape = .top_level,
    /// Prune empty directories, matching `GitTools.tree_hash` — the hasher
    /// Pkg compares against `git-tree-sha1` (`Operations.jl:812`). See the
    /// module doc comment for why this does NOT default to `Tar.tree_hash`'s
    /// `false`.
    skip_empty: bool = true,
    /// Zip-bomb guard for the gzip entry points. General is ~84 MB
    /// decompressed; no package comes close.
    max_uncompressed: usize = 1 << 30,
    /// Receives the hash actually computed, on success and on mismatch alike,
    /// so a rejection can be reported with both sides.
    computed: ?*Hash = null,
};

/// `git archive` writes the archive's global pax header as an entry with
/// typeflag `g`, which every sane reader — including `std.tar.Iterator`,
/// which discards it at `tar.zig:460-462` — treats as metadata. 7z on Windows
/// instead materialises it as a real top-level file, which is why Pkg filters
/// this exact name out of the extracted listing (`Operations.jl:803-805`).
/// Ajt filters it for the same reason plus one more: it has to be gone before
/// "which directory is the root?" can be answered.
const pax_global_header = "pax_global_header";

/// Parses the 40-character `git-tree-sha1` a registry records into the form
/// this module compares. Same parse as `slug.Sha1.parse`, re-exported so a
/// caller of the installer need not reach into the slug module.
pub fn parseHash(hex: []const u8) error{InvalidSha1}!Hash {
    return (try slug.Sha1.parse(hex)).bytes;
}

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

/// The archive reduced to the package tree itself: the exact bytes that get
/// hashed AND extracted.
pub const Normalized = struct {
    bytes: []const u8,
    /// Non-null when `bytes` was rewritten and must be freed. For
    /// `.top_level` the input needs no rewriting and is borrowed, so the
    /// common install path pays no extra copy.
    owned: ?[]u8 = null,

    pub fn deinit(self: *Normalized, gpa: Allocator) void {
        if (self.owned) |o| gpa.free(o);
        self.* = undefined;
    }
};

/// Rewrites `tar_bytes` so that its root is the package tree. Purely
/// in-memory; touches no filesystem.
pub fn normalize(gpa: Allocator, tar_bytes: []const u8, shape: Shape) Error!Normalized {
    switch (shape) {
        .top_level => {
            try checkPaths(gpa, tar_bytes);
            return .{ .bytes = tar_bytes, .owned = null };
        },
        .github_tarball => {
            const rewritten = try stripRoot(gpa, tar_bytes);
            return .{ .bytes = rewritten, .owned = rewritten };
        },
    }
}

/// Canonical form of a tar entry path: components joined by single slashes,
/// with empty and `.` components dropped. Returns a slice of `buf`, which
/// only ever shrinks relative to `name`. An empty result means the entry names
/// the archive root itself (`tar -C dir -cf … .` emits `./`), which carries no
/// content and is skipped by callers.
///
/// Julia normalises the same way before hashing
/// (`Tar/src/extract.jl:358-366`) and rejects the dangerous shapes in
/// `check_header` (`Tar/src/header.jl:92-101`): empty path, NUL bytes,
/// absolute path, any `..` component.
///
/// **Why `..` must be a hard error here specifically.** `treehash.hashTar`
/// treats `..` as an ordinary directory NAME, while `std.tar.extract`
/// RESOLVES it — `std.tar`'s own test pins `sanitizePath("a/x/y/../../b/c")`
/// to `a/b/c` (`tar.zig:719`). So an archive containing `a/x/y/../../b/c`
/// would hash as a six-level tree and land on disk as a three-level one: the
/// hash Ajt verified would not describe the bytes Ajt wrote, which is exactly
/// the guarantee this module exists to make. Neither git nor Pkg can produce
/// such a path, so refusing costs nothing.
fn canonicalize(buf: []u8, name: []const u8) Error![]const u8 {
    if (name.len == 0) return error.UnsafePath;
    if (name[0] == '/') return error.UnsafePath;
    var n: usize = 0;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.UnsafePath;
        if (std.mem.indexOfScalar(u8, part, 0) != null) return error.UnsafePath;
        depth += 1;
        if (depth > max_path_components) return error.PathTooDeep;
        if (n != 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    return buf[0..n];
}

/// `treehash.hashTar` splits a path into a fixed `[64][]const u8` and stops
/// filling it once full (`treehash.zig:368-376`), so a 65-component path is
/// hashed as its first 64 components with the 64th standing in for the leaf —
/// while `std.tar.extract` writes the whole thing. Refusing beyond the limit
/// keeps the two views identical. Julia has no such cap, but no git tree comes
/// close either: this is a guard on a port detail, not a compatibility rule.
const max_path_components = 64;

/// What an entry claims a path is. Directories are also claimed IMPLICITLY,
/// by every entry nested under them.
const NodeKind = enum { dir, file, symlink };

/// Rejects the archive shapes where `treehash.hashTar`'s tree and
/// `std.tar.extract`'s filesystem would disagree about the same bytes.
/// `canonicalize` handles the ones visible in a single path; these need the
/// entries seen so far.
///
///  * **A symlink used as a directory prefix.** This is the dangerous one.
///    `hashTar` OVERWRITES the symlink node with a fresh directory when a
///    later entry descends through it (`getOrCreateDir`, `treehash.zig:
///    303-306`), so the symlink disappears from the hash entirely — an
///    attacker does not need a collision, they can take any legitimately
///    pinned tree and prepend a symlink that hashes away. Extraction does the
///    opposite: `std.tar.extract` creates the symlink and then opens the
///    nested path through it with a plain `openat` (`tar.zig:650-661`), so
///    the write follows the link and lands outside the destination
///    directory — outside the temp dir the whole verify-then-rename model
///    rests on. Julia refuses the same shape explicitly, and refuses it in the
///    HASHER, not just the extractor: `Tar.tree_hash` on such an archive
///    throws "Tarball contains path with symlink prefix … Refusing to
///    extract — possible attack!" (`Tar/src/extract.jl:361-368`, reached from
///    `git_tree_hash` via `read_tarball`). `treehash.hashTar` is a port of the
///    hashing, not of that check, so the check has to live here for Ajt to
///    match Julia — verified against the real `Tar.tree_hash` in
///    `tools/diff_harness/extract.sh`.
///  * **A path claimed twice.** `hashTar` is last-one-wins
///    (`treehash.zig:317-327`) while `std.tar.extract` creates with
///    `.exclusive = true`, so the tree that verified describes the second
///    body and the disk holds the first — and only after a partial tree has
///    already been written.
///  * **A name used as both a file and a directory**, in either order, for
///    the same reason.
///
/// A duplicate *directory* entry is the one benign repeat (both hashers are
/// idempotent about it) and is allowed: `tar` emits explicit directory entries
/// that nested entries also imply.
const PathGuard = struct {
    arena: Allocator,
    seen: std.StringHashMapUnmanaged(NodeKind) = .empty,

    fn visit(self: *PathGuard, path: []const u8, kind: NodeKind) Error!void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |s| {
            try self.claim(path[0..s], .dir);
            i = s + 1;
        }
        try self.claim(path, kind);
    }

    fn claim(self: *PathGuard, p: []const u8, kind: NodeKind) Error!void {
        if (self.seen.get(p)) |prev| {
            if (prev == .dir and kind == .dir) return;
            if (prev == .symlink and kind == .dir) return error.SymlinkPrefix;
            return error.ConflictingPaths;
        }
        const owned = try self.arena.dupe(u8, p);
        try self.seen.put(self.arena, owned, kind);
    }
};

fn nodeKind(kind: std.tar.FileKind) NodeKind {
    return switch (kind) {
        .directory => .dir,
        .sym_link => .symlink,
        .file => .file,
        // std.tar.FileKind has exactly these three; no else prong.
    };
}

/// An entry's declared size is an unvalidated header field — base-256 encoding
/// reaches `maxInt(u64)` (`tar.zig:212-228`) and a pax `size` attribute can
/// set it too. Both `hashTar` and `stripRoot` allocate a body of that size, so
/// a 512-byte header would otherwise buy an arbitrary allocation, reported as
/// `OutOfMemory` (indistinguishable from real memory pressure, which is the
/// difference between "try the next mirror" and "abort the run") or, where
/// `usize` is 32 bits, as a narrowing panic. No body can exceed the archive
/// that contains it.
fn checkSize(entry: std.tar.Iterator.File, tar_len: usize) Error!void {
    if (entry.size > tar_len) return error.MalformedTar;
}

/// Walks the archive rejecting any path whose hashed meaning differs from its
/// on-disk meaning, and any header whose declared size is a lie. Entry bodies
/// are skipped rather than copied, so this is a pass over headers.
fn checkPaths(gpa: Allocator, tar_bytes: []const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var guard: PathGuard = .{ .arena = arena_state.allocator() };

    var reader = Io.Reader.fixed(tar_bytes);
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var canon_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });
    while (it.next() catch return error.MalformedTar) |entry| {
        try checkSize(entry, tar_bytes.len);
        const path = try canonicalize(&canon_buf, entry.name);
        const kind = nodeKind(entry.kind);
        if (path.len == 0) {
            // `./` — the archive root, which only a directory entry may name.
            // Julia rejects the rest for the same reason
            // (`Tar/src/header.jl:117-118`); `hashTar` would skip such an
            // entry while `std.tar.extract` fails on it mid-way.
            if (kind != .dir) return error.UnsafePath;
            continue;
        }
        try guard.visit(path, kind);
    }
}

/// An `Io.Writer.Allocating` only ever fails to write because it failed to
/// allocate; the tar writer's other two errors mean a header this archive
/// cannot be re-expressed with.
fn writeErr(e: anyerror) Error {
    return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => error.MalformedTar,
    };
}

/// Rewrites a GitHub `/tarball` archive with its single generated root
/// directory removed and `pax_global_header` dropped.
///
/// Re-emitting rather than patching headers in place is deliberate: entry
/// names arrive in three encodings (ustar name+prefix, GNU `L`, pax `x`) and
/// `std.tar.Writer` picks a valid one for the shortened name, whereas an
/// in-place edit would have to preserve whichever encoding the producer chose.
/// Everything `hashTar` reads — name, kind, link target, size, `mode & 0o100`,
/// and content — survives the round trip; mtime/uid/gid do not, and do not
/// participate in a git tree hash.
fn stripRoot(gpa: Allocator, tar_bytes: []const u8) Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &out.writer };

    // One file body at a time; reset instead of free so the peak is the
    // largest single file, not the archive.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    // The guard runs on the STRIPPED paths, because those are what gets
    // hashed and extracted.
    var guard_arena: std.heap.ArenaAllocator = .init(gpa);
    defer guard_arena.deinit();
    var guard: PathGuard = .{ .arena = guard_arena.allocator() };

    var reader = Io.Reader.fixed(tar_bytes);
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var canon_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var root: ?[]const u8 = null;

    var it: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (it.next() catch return error.MalformedTar) |entry| {
        try checkSize(entry, tar_bytes.len);
        const path = try canonicalize(&canon_buf, entry.name);
        const kind = nodeKind(entry.kind);
        if (path.len == 0) {
            if (kind != .dir) return error.UnsafePath;
            continue; // the archive root entry, e.g. "./"
        }

        const slash = std.mem.indexOfScalar(u8, path, '/');
        const first = if (slash) |s| path[0..s] else path;

        // Drop the spurious header BEFORE deciding what the root is — Pkg's
        // `filter!` likewise runs before its `@assert length(dirs) == 1`
        // (`Operations.jl:803-806`). Without this an archive carrying one
        // would look like it had two roots.
        if (slash == null and std.mem.eql(u8, first, pax_global_header)) continue;

        if (root) |r| {
            if (!std.mem.eql(u8, r, first)) return error.NotSingleRooted;
        } else {
            @memcpy(root_buf[0..first.len], first);
            root = root_buf[0..first.len];
        }

        const sub = if (slash) |s| path[s + 1 ..] else "";
        if (sub.len == 0) {
            // The root's own entry. It has to BE the wrapper directory: a
            // lone top-level file is not a `top = false` archive at all, and
            // stripping it would silently install the empty tree. Pkg reaches
            // the same verdict the slow way — its `readdir` lists files too,
            // so a stray one breaks `@assert length(dirs) == 1`
            // (`Operations.jl:802-806`).
            if (kind != .dir) return error.NotSingleRooted;
            continue;
        }
        try guard.visit(sub, kind);

        switch (entry.kind) {
            .directory => tw.writeDir(sub, .{}) catch |e| return writeErr(e),
            .sym_link => tw.writeLink(sub, entry.link_name, .{}) catch |e| return writeErr(e),
            .file => {
                _ = scratch.reset(.retain_capacity);
                const body = try scratch.allocator().alloc(u8, @intCast(entry.size));
                var body_writer = Io.Writer.fixed(body);
                // streamRemaining, not the reader directly: it is what clears
                // the iterator's unread-bytes counter, and skipping it makes
                // `next()` discard the following header as leftover payload.
                it.streamRemaining(entry, &body_writer) catch return error.MalformedTar;
                tw.writeFileBytes(sub, body, .{ .mode = entry.mode }) catch |e| return writeErr(e);
            },
            // std.tar.FileKind has exactly these three; no else prong.
        }
    }

    if (root == null) return error.NotSingleRooted;
    tw.finishPedantically() catch |e| return writeErr(e);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Hash / verify / extract
// ---------------------------------------------------------------------------

fn hashOf(gpa: Allocator, tar_bytes: []const u8, skip_empty: bool) Error!Hash {
    return treehash.hashTar(gpa, tar_bytes, skip_empty) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed, error.NotADirectory => error.MalformedTar,
        // The hasher now refuses escapes itself (`..`, or nesting under a
        // symlink), matching Julia's Tar.tree_hash. This module already
        // rejects both independently, so reaching here means the hasher saw
        // it first; map onto the same error so callers see one contract.
        error.UnsafeTarPath => error.UnsafePath,
    };
}

/// The `git-tree-sha1` this tarball would install as. No filesystem access,
/// so it is safe to call on bytes that have not been trusted yet — that is
/// the whole reason it exists as a separate entry point.
pub fn treeHashOfTar(gpa: Allocator, tar_bytes: []const u8, opts: Options) Error!Hash {
    var norm = try normalize(gpa, tar_bytes, opts.shape);
    defer norm.deinit(gpa);
    const h = try hashOf(gpa, norm.bytes, opts.skip_empty);
    if (opts.computed) |slot| slot.* = h;
    return h;
}

/// Decompresses one gzip member. Held in `gpa`; the caller frees.
pub fn gunzip(gpa: Allocator, gz: []const u8, max_uncompressed: usize) Error![]u8 {
    var gz_reader = Io.Reader.fixed(gz);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var decompress = std.compress.flate.Decompress.init(&gz_reader, .gzip, window);
    // OutOfMemory must not be laundered into DecompressFailed: an installer
    // reacts to "this mirror served junk" by trying the next URL, and to "this
    // machine is out of memory" by stopping.
    return decompress.reader.allocRemaining(gpa, .limited(max_uncompressed)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DecompressFailed,
    };
}

/// Same as `treeHashOfTar` for a gzipped archive.
pub fn treeHashOfGzip(gpa: Allocator, gz: []const u8, opts: Options) Error!Hash {
    const tar_bytes = try gunzip(gpa, gz, opts.max_uncompressed);
    defer gpa.free(tar_bytes);
    return treeHashOfTar(gpa, tar_bytes, opts);
}

/// Extracts `tar_bytes` into `dest` **only if** its tree hash is `expected`.
///
/// `dest` is a directory the caller owns and is expected to be a temp
/// directory: promoting it into the depot by an atomic rename is `depot.zig`'s
/// job, not this module's.
///
/// Guarantee: every error except `ExtractFailed` is returned before the first
/// filesystem call, so on `TreeHashMismatch` — or a malformed archive, or an
/// unsafe path — `dest` is exactly as the caller left it. `ExtractFailed`
/// means the content was already proven correct and the environment refused
/// it, so the partial tree is garbage for the caller to delete.
pub fn verifyAndExtractTar(
    gpa: Allocator,
    io: Io,
    tar_bytes: []const u8,
    expected: Hash,
    dest: Io.Dir,
    opts: Options,
) Error!void {
    var norm = try normalize(gpa, tar_bytes, opts.shape);
    defer norm.deinit(gpa);

    const got = try hashOf(gpa, norm.bytes, opts.skip_empty);
    if (opts.computed) |slot| slot.* = got;
    if (!std.mem.eql(u8, &got, &expected)) return error.TreeHashMismatch;

    // ---- Nothing above this line touched the filesystem. ----
    // Extraction reads the same buffer that was just hashed, so the two
    // cannot describe different trees.
    //
    // `mode_mode` is left at `.executable_bit_only`, which copies the owner
    // execute bit and nothing else — the same rule the hash used
    // (`mode & 0o100`, `GitTools.jl:214`), so re-walking the result with
    // `treehash.hashPath` reproduces `expected`.
    //
    // That round trip has exactly one exception, and it is safe: `hashPath`
    // skips `.git` (`GitTools.jl:271-273`) while `hashTar` does not, so an
    // archive carrying a `.git` entry hashes differently from the tree it
    // extracts to. Since a git tree can never contain `.git`, such an archive
    // never matches its pin and is rejected here rather than reaching disk —
    // which is stricter than Pkg, whose post-extraction `GitTools.tree_hash`
    // would ignore the smuggled directory entirely.
    var reader = Io.Reader.fixed(norm.bytes);
    std.tar.extract(io, dest, &reader, .{}) catch return error.ExtractFailed;
}

/// `verifyAndExtractTar` for a gzipped archive — the shape a Pkg server or
/// GitHub actually serves.
pub fn verifyAndExtractGzip(
    gpa: Allocator,
    io: Io,
    gz: []const u8,
    expected: Hash,
    dest: Io.Dir,
    opts: Options,
) Error!void {
    const tar_bytes = try gunzip(gpa, gz, opts.max_uncompressed);
    defer gpa.free(tar_bytes);
    return verifyAndExtractTar(gpa, io, tar_bytes, expected, dest, opts);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    name: []const u8,
    kind: std.tar.Writer.Header.FileType = .regular,
    data: []const u8 = "",
    link: []const u8 = "",
    mode: u32 = 0o644,
};

/// Builds a tar in memory through `std.tar.Writer`, so the tests need no
/// fixture files on disk.
fn buildTar(gpa: Allocator, entries: []const Fixture) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var tw: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (entries) |e| switch (e.kind) {
        .directory => try tw.writeDir(e.name, .{ .mode = e.mode }),
        .symbolic_link => try tw.writeLink(e.name, e.link, .{ .mode = e.mode }),
        else => try tw.writeFileBytes(e.name, e.data, .{ .mode = e.mode }),
    };
    try tw.finishPedantically();
    return out.toOwnedSlice();
}

/// Plants an entry with a raw typeflag byte, which `std.tar.Writer` cannot
/// emit — its `FileType` is an exhaustive enum with no `g` member. Written by
/// hand so the tests can exercise a genuine global-extended-header block.
fn appendRawEntry(gpa: Allocator, tar: []const u8, typeflag: u8, name: []const u8, data: []const u8) ![]u8 {
    const padded = std.mem.alignForward(usize, data.len, 512);
    const start = tar.len - 1024; // overwrite the terminating zero blocks
    const buf = try gpa.alloc(u8, start + 512 + padded + 1024);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    @memcpy(buf[0..start], tar[0..start]);

    const h = buf[start..][0..512];
    @memcpy(h[0..name.len], name);
    _ = std.fmt.bufPrint(h[100..][0..8], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
    _ = std.fmt.bufPrint(h[124..][0..12], "{o:0>11}", .{data.len}) catch unreachable;
    _ = std.fmt.bufPrint(h[136..][0..12], "{o:0>11}", .{@as(u32, 0)}) catch unreachable;
    h[156] = typeflag;
    @memcpy(h[257..][0..6], "ustar\x00");
    @memcpy(h[263..][0..2], "00");
    @memset(h[148..][0..8], ' '); // checksum is summed as if it were spaces
    var sum: u32 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;

    @memcpy(buf[start + 512 ..][0..data.len], data);
    return buf;
}

/// `testing.tmpDir` lives at a fixed cwd-relative location, which is how a
/// test hands one to `treehash.hashPath` (that takes a path, not a Dir).
fn tmpPath(buf: []u8, tmp: *const testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
}

const sample = [_]Fixture{
    .{ .name = "a.txt", .data = "hello\n" },
    .{ .name = "sub", .kind = .directory, .mode = 0o755 },
    .{ .name = "sub/b.txt", .data = "world\n" },
    .{ .name = "run.sh", .data = "#!/bin/sh\n", .mode = 0o755 },
    .{ .name = "link", .kind = .symbolic_link, .link = "a.txt" },
};

fn prefixed(gpa: Allocator, root: []const u8, entries: []const Fixture) ![]Fixture {
    const out = try gpa.alloc(Fixture, entries.len);
    for (entries, out) |e, *o| {
        o.* = e;
        o.name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, e.name });
    }
    return out;
}

test "top_level hash matches the same tree wrapped and stripped" {
    const gpa = testing.allocator;

    const flat = try buildTar(gpa, &sample);
    defer gpa.free(flat);
    const flat_hash = try treeHashOfTar(gpa, flat, .{});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wrapped_entries = try prefixed(arena.allocator(), "JuliaLang-Example-1a2b3c4", &sample);
    const wrapped = try buildTar(gpa, wrapped_entries);
    defer gpa.free(wrapped);

    const stripped_hash = try treeHashOfTar(gpa, wrapped, .{ .shape = .github_tarball });
    try testing.expectEqualStrings(&treehash.toHex(flat_hash), &treehash.toHex(stripped_hash));

    // Sanity: without stripping, the wrapper changes the hash. Otherwise the
    // test above would pass even if `stripRoot` did nothing.
    const unstripped = try treeHashOfTar(gpa, wrapped, .{});
    try testing.expect(!std.mem.eql(u8, &flat_hash, &unstripped));
}

test "the exec bit and the symlink target are part of the hash" {
    const gpa = testing.allocator;

    const base = try buildTar(gpa, &sample);
    defer gpa.free(base);
    const base_hash = try treeHashOfTar(gpa, base, .{});

    var no_exec = sample;
    no_exec[3].mode = 0o644;
    const t1 = try buildTar(gpa, &no_exec);
    defer gpa.free(t1);
    const h1 = try treeHashOfTar(gpa, t1, .{});
    try testing.expect(!std.mem.eql(u8, &base_hash, &h1));

    var other_target = sample;
    other_target[4].link = "sub/b.txt";
    const t2 = try buildTar(gpa, &other_target);
    defer gpa.free(t2);
    const h2 = try treeHashOfTar(gpa, t2, .{});
    try testing.expect(!std.mem.eql(u8, &base_hash, &h2));
}

test "pax_global_header is dropped, as a 'g' block and as a plain file" {
    const gpa = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wrapped_entries = try prefixed(arena.allocator(), "O-R-deadbee", &sample);
    const wrapped = try buildTar(gpa, wrapped_entries);
    defer gpa.free(wrapped);
    const want = try treeHashOfTar(gpa, wrapped, .{ .shape = .github_tarball });

    // 7z on Windows shape: a real top-level FILE with that name. Without the
    // filter this looks like a second root and `NotSingleRooted` fires.
    const with_file = try buildTar(gpa, try prependPax(arena.allocator(), wrapped_entries));
    defer gpa.free(with_file);
    const h_file = try treeHashOfTar(gpa, with_file, .{ .shape = .github_tarball });
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(h_file));

    // git archive shape: a real typeflag 'g' block, which the tar iterator
    // discards as metadata before we ever see it.
    const with_g = try appendRawEntry(gpa, wrapped, 'g', pax_global_header, "52 comment=deadbeef\n");
    defer gpa.free(with_g);
    const h_g = try treeHashOfTar(gpa, with_g, .{ .shape = .github_tarball });
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(h_g));
}

fn prependPax(arena: Allocator, entries: []const Fixture) ![]Fixture {
    const out = try arena.alloc(Fixture, entries.len + 1);
    out[0] = .{ .name = pax_global_header, .data = "52 comment=deadbeef\n" };
    @memcpy(out[1..], entries);
    return out;
}

test "two roots in a github tarball are rejected, not silently mangled" {
    const gpa = testing.allocator;
    const tar = try buildTar(gpa, &.{
        .{ .name = "one/a.txt", .data = "x\n" },
        .{ .name = "two/b.txt", .data = "y\n" },
    });
    defer gpa.free(tar);
    try testing.expectError(
        error.NotSingleRooted,
        treeHashOfTar(gpa, tar, .{ .shape = .github_tarball }),
    );
}

test "'..' in an entry path is refused in both shapes" {
    const gpa = testing.allocator;
    // std.tar.extract resolves this to `a/b.txt`; hashTar would hash it as
    // a/x/../b.txt. Rather than pick a winner, refuse the archive.
    const tar = try buildTar(gpa, &.{
        .{ .name = "root/a/x/../b.txt", .data = "x\n" },
    });
    defer gpa.free(tar);
    try testing.expectError(error.UnsafePath, treeHashOfTar(gpa, tar, .{}));
    try testing.expectError(
        error.UnsafePath,
        treeHashOfTar(gpa, tar, .{ .shape = .github_tarball }),
    );
}

test "a symlink used as a directory prefix is refused, in both shapes" {
    const gpa = testing.allocator;
    const io = testing.io;

    // The attack: `hashTar` overwrites the `src` symlink node with a real
    // directory the moment something nests under it, so this archive hashes
    // as the perfectly ordinary tree {src/{pwned.txt}} — no collision
    // needed — while extraction writes pwned.txt THROUGH the symlink, outside
    // `dest` entirely.
    const tar = try buildTar(gpa, &.{
        .{ .name = "src", .kind = .symbolic_link, .link = "../escaped" },
        .{ .name = "src/pwned.txt", .data = "owned\n" },
    });
    defer gpa.free(tar);

    try testing.expectError(error.SymlinkPrefix, treeHashOfTar(gpa, tar, .{}));

    const wrapped = try buildTar(gpa, &.{
        .{ .name = "O-R-abc/src", .kind = .symbolic_link, .link = "../escaped" },
        .{ .name = "O-R-abc/src/pwned.txt", .data = "owned\n" },
    });
    defer gpa.free(wrapped);
    try testing.expectError(
        error.SymlinkPrefix,
        treeHashOfTar(gpa, wrapped, .{ .shape = .github_tarball }),
    );

    // And the refusal happens before the filesystem is touched. Pass the hash
    // of the tree the attacker was aiming at, so a missing guard would extract.
    const target = try buildTar(gpa, &.{.{ .name = "src/pwned.txt", .data = "owned\n" }});
    defer gpa.free(target);
    const aimed_at = try treeHashOfTar(gpa, target, .{});

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectError(
        error.SymlinkPrefix,
        verifyAndExtractTar(gpa, io, tar, aimed_at, tmp.dir, .{}),
    );
    var it = tmp.dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "a path claimed twice, or as both file and directory, is refused" {
    const gpa = testing.allocator;

    // hashTar is last-one-wins; std.tar.extract creates exclusively, so the
    // hash would describe "second" while the disk held "first".
    const dup = try buildTar(gpa, &.{
        .{ .name = "a.txt", .data = "first\n" },
        .{ .name = "a.txt", .data = "second\n" },
    });
    defer gpa.free(dup);
    try testing.expectError(error.ConflictingPaths, treeHashOfTar(gpa, dup, .{}));

    const file_then_dir = try buildTar(gpa, &.{
        .{ .name = "x", .data = "content\n" },
        .{ .name = "x/y.txt", .data = "nested\n" },
    });
    defer gpa.free(file_then_dir);
    try testing.expectError(error.ConflictingPaths, treeHashOfTar(gpa, file_then_dir, .{}));

    const dir_then_file = try buildTar(gpa, &.{
        .{ .name = "x/y.txt", .data = "nested\n" },
        .{ .name = "x", .data = "content\n" },
    });
    defer gpa.free(dir_then_file);
    try testing.expectError(error.ConflictingPaths, treeHashOfTar(gpa, dir_then_file, .{}));

    // A repeated DIRECTORY entry is the benign case and must still pass: tar
    // emits explicit directory entries that nested entries also imply.
    const redundant = try buildTar(gpa, &.{
        .{ .name = "sub", .kind = .directory, .mode = 0o755 },
        .{ .name = "sub/b.txt", .data = "world\n" },
        .{ .name = "sub", .kind = .directory, .mode = 0o755 },
    });
    defer gpa.free(redundant);
    _ = try treeHashOfTar(gpa, redundant, .{});
}

test "a path deeper than the hasher can represent is refused" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 64 components: the deepest treehash.hashTar keeps intact.
    var name: std.ArrayList(u8) = .empty;
    for (0..max_path_components - 1) |_| try name.appendSlice(a, "d/");
    try name.appendSlice(a, "f.txt");
    const deep_ok = try buildTar(gpa, &.{.{ .name = name.items, .data = "x\n" }});
    defer gpa.free(deep_ok);
    _ = try treeHashOfTar(gpa, deep_ok, .{});

    // 65: hashTar would silently drop the tail and hash a different tree than
    // std.tar.extract writes.
    try name.insertSlice(a, 0, "d/");
    const deep_bad = try buildTar(gpa, &.{.{ .name = name.items, .data = "x\n" }});
    defer gpa.free(deep_bad);
    try testing.expectError(error.PathTooDeep, treeHashOfTar(gpa, deep_bad, .{}));
}

test "a lone top-level file is not a github tarball" {
    const gpa = testing.allocator;
    // Root detection keys on the first path component, so without a kind
    // check this looks like a wrapper directory and strips to the EMPTY tree —
    // silently installing nothing instead of failing over to the next URL.
    const tar = try buildTar(gpa, &.{.{ .name = "LICENSE", .data = "MIT\n" }});
    defer gpa.free(tar);
    try testing.expectError(
        error.NotSingleRooted,
        treeHashOfTar(gpa, tar, .{ .shape = .github_tarball }),
    );
}

test "a header that lies about its size is malformed, not out of memory" {
    const gpa = testing.allocator;
    const tar = try buildTar(gpa, &.{.{ .name = "root/a.txt", .data = "hello\n" }});
    defer gpa.free(tar);

    // Rewrite the size field of the first header to 4 GiB — the largest the
    // 11-digit octal field holds, and base-256 encoding reaches maxInt(u64).
    // Without the bound this buys an allocation that big off a 512-byte
    // header, reported as OutOfMemory.
    const bad = try gpa.dupe(u8, tar);
    defer gpa.free(bad);
    _ = std.fmt.bufPrint(bad[124..][0..12], "{o:0>11}", .{@as(u64, 1) << 32}) catch unreachable;
    @memset(bad[148..][0..8], ' ');
    var sum: u32 = 0;
    for (bad[0..512]) |b| sum += b;
    _ = std.fmt.bufPrint(bad[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;

    try testing.expectError(error.MalformedTar, treeHashOfTar(gpa, bad, .{}));
    try testing.expectError(
        error.MalformedTar,
        treeHashOfTar(gpa, bad, .{ .shape = .github_tarball }),
    );
}

test "skip_empty follows GitTools, not Tar's default" {
    const gpa = testing.allocator;
    const tar = try buildTar(gpa, &.{
        .{ .name = "a.txt", .data = "hello\n" },
        .{ .name = "hollow", .kind = .directory, .mode = 0o755 },
    });
    defer gpa.free(tar);

    const no_empty = try buildTar(gpa, &.{.{ .name = "a.txt", .data = "hello\n" }});
    defer gpa.free(no_empty);

    // Default (skip_empty = true) prunes `hollow/`, matching what
    // GitTools.tree_hash would report for the extracted directory.
    const pruned_ref = try treeHashOfTar(gpa, no_empty, .{});
    const pruned = try treeHashOfTar(gpa, tar, .{});
    try testing.expectEqualStrings(&treehash.toHex(pruned_ref), &treehash.toHex(pruned));

    // Tar.tree_hash's own default keeps it, and therefore differs.
    const kept_ref = try treeHashOfTar(gpa, no_empty, .{ .skip_empty = false });
    const kept = try treeHashOfTar(gpa, tar, .{ .skip_empty = false });
    try testing.expect(!std.mem.eql(u8, &kept_ref, &kept));
}

test "a corrupt tarball is rejected with an empty destination" {
    const gpa = testing.allocator;
    const io = testing.io;

    const tar = try buildTar(gpa, &sample);
    defer gpa.free(tar);
    const good = try treeHashOfTar(gpa, tar, .{});

    // Flip one byte of file content. The archive stays structurally valid.
    const bad = try gpa.dupe(u8, tar);
    defer gpa.free(bad);
    const at = std.mem.indexOf(u8, bad, "hello\n").?;
    bad[at] = 'j';

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var got: Hash = undefined;
    try testing.expectError(error.TreeHashMismatch, verifyAndExtractTar(
        gpa,
        io,
        bad,
        good,
        tmp.dir,
        .{ .computed = &got },
    ));
    try testing.expect(!std.mem.eql(u8, &good, &got));

    // The property that matters: not one byte was written.
    var it = tmp.dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "a verified tarball extracts to a tree that re-hashes to the same value" {
    const gpa = testing.allocator;
    const io = testing.io;

    const tar = try buildTar(gpa, &sample);
    defer gpa.free(tar);
    const want = try treeHashOfTar(gpa, tar, .{});

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try verifyAndExtractTar(gpa, io, tar, want, tmp.dir, .{});

    // Walk what landed on disk with the OTHER hasher — the port of
    // GitTools.tree_hash, which is what Pkg runs post-extraction
    // (Operations.jl:812). Stream hash and disk hash agreeing is the whole
    // contract, and it is also what pins the exec bit and the symlink through
    // the real filesystem rather than through the tar headers.
    var path_buf: [64]u8 = undefined;
    const on_disk = try treehash.hashPath(gpa, io, tmpPath(&path_buf, &tmp));
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(on_disk));

    const body = try tmp.dir.readFileAlloc(io, "sub/b.txt", gpa, .limited(64));
    defer gpa.free(body);
    try testing.expectEqualStrings("world\n", body);
}

test "a github tarball extracts without its wrapper directory" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wrapped = try buildTar(gpa, try prefixed(arena.allocator(), "O-R-abc1234", &sample));
    defer gpa.free(wrapped);

    const flat = try buildTar(gpa, &sample);
    defer gpa.free(flat);
    const want = try treeHashOfTar(gpa, flat, .{});

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try verifyAndExtractTar(gpa, io, wrapped, want, tmp.dir, .{ .shape = .github_tarball });

    const body = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(body);
    try testing.expectEqualStrings("hello\n", body);

    var path_buf: [64]u8 = undefined;
    const on_disk = try treehash.hashPath(gpa, io, tmpPath(&path_buf, &tmp));
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(on_disk));
}

test "gzip round trip, and a corrupt gzip writes nothing either" {
    const gpa = testing.allocator;
    const io = testing.io;

    const tar = try buildTar(gpa, &sample);
    defer gpa.free(tar);
    const want = try treeHashOfTar(gpa, tar, .{});

    // initCapacity, not init: Compress.init asserts its output has a buffer
    // bigger than the gzip header it is about to stage there.
    var out: Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer out.deinit();
    const cbuf = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(cbuf);
    var comp = try std.compress.flate.Compress.init(&out.writer, cbuf, .gzip, .default);
    try comp.writer.writeAll(tar);
    try comp.finish();
    const gz = out.written();

    const gz_hash = try treeHashOfGzip(gpa, gz, .{});
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(gz_hash));

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try verifyAndExtractGzip(gpa, io, gz, want, tmp.dir, .{});
    var path_buf: [64]u8 = undefined;
    const on_disk = try treehash.hashPath(gpa, io, tmpPath(&path_buf, &tmp));
    try testing.expectEqualStrings(&treehash.toHex(want), &treehash.toHex(on_disk));

    // Truncated stream: fails in the decompressor, still before any write.
    var tmp2 = testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try testing.expectError(error.DecompressFailed, verifyAndExtractGzip(
        gpa,
        io,
        gz[0 .. gz.len - 8],
        want,
        tmp2.dir,
        .{},
    ));
    var it2 = tmp2.dir.iterate();
    try testing.expect((try it2.next(io)) == null);
}

test "parseHash round-trips the registry's hex form" {
    const h = try parseHash("c75cb0b99296cb6306fa8e99184bb7495ca20adf");
    try testing.expectEqualStrings("c75cb0b99296cb6306fa8e99184bb7495ca20adf", &treehash.toHex(h));
    try testing.expectError(error.InvalidSha1, parseHash("nope"));
}
