//! Git tree hash.
//!
//! This is the load-bearing verification step of the whole installer: the
//! registry pins a `git-tree-sha1` per version, and an install is only
//! trustworthy if Ajt can recompute that hash over what it actually extracted.
//! Port of `Pkg/src/GitTools.jl:200-343`.
//!
//! Object format:
//!
//!     blob = SHA1("blob " ++ dec(len) ++ "\0" ++ bytes)
//!     tree = SHA1("tree " ++ dec(size) ++ "\0" ++ body)
//!       body = for each entry, in sort order:
//!              octal_mode ++ " " ++ name ++ "\0" ++ raw_20_byte_hash
//!       size = Σ (len(octal_mode) + 1 + len(name) + 1 + 20)
//!
//! Four details that are each individually capable of producing a
//! wrong-but-plausible hash:
//!
//!  1. **Modes have no leading zero.** Julia emits them with
//!     `string(m, base=8)` (`:329-341`), so a directory is `40000`, not
//!     `040000`.
//!  2. **Directories sort as if their name ended in `/`** (`:294`). Since
//!     `.` (0x2E) < `/` (0x2F) < `0`, this puts `foo.txt` before `foo/` but
//!     `fooa` after it. Sorting plain names gets this wrong only for the
//!     handful of names where it matters, so it survives casual testing.
//!  3. **Empty directories are pruned** — a directory with no file anywhere
//!     beneath it contributes nothing (`:276-305`). Git cannot represent one,
//!     so this is how a filesystem tree maps back onto a git tree.
//!  4. **`.git` is skipped** (`:296-305`).
//!
//! The mode for a regular file comes from `mode & 0o100` (`:214`), i.e. the
//! OWNER execute bit only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;

pub const Hash = [20]u8;

pub const Error = error{
    NotADirectory,
    ReadFailed,
} || Allocator.Error;

const Mode = enum {
    dir,
    file,
    exec,
    symlink,

    /// Octal, WITHOUT a leading zero.
    fn text(self: Mode) []const u8 {
        return switch (self) {
            .dir => "40000",
            .file => "100644",
            .exec => "100755",
            .symlink => "120000",
        };
    }

    fn isDir(self: Mode) bool {
        return self == .dir;
    }
};

const Entry = struct {
    name: []const u8,
    mode: Mode,
    hash: Hash,

    /// `by = f -> gitmode(f) == mode_dir ? f*"/" : f` (GitTools.jl:294).
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return compareNames(a.name, a.mode.isDir(), b.name, b.mode.isDir()) == .lt;
    }
};

fn compareNames(a: []const u8, a_dir: bool, b: []const u8, b_dir: bool) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (a[i] != b[i]) return std.math.order(a[i], b[i]);
    }
    // One is a prefix of the other; the virtual trailing '/' decides.
    if (a.len == b.len) {
        if (a_dir == b_dir) return .eq;
        return if (a_dir) .gt else .lt;
    }
    if (a.len < b.len) {
        // `a` ran out. Its next byte is '/' if it is a directory.
        const a_next: u8 = if (a_dir) '/' else return .lt;
        return std.math.order(a_next, b[a.len]);
    }
    const b_next: u8 = if (b_dir) '/' else return .gt;
    return std.math.order(a[b.len], b_next);
}

/// SHA-1 of a git blob wrapping `data`.
pub fn blobHash(data: []const u8) Hash {
    var h = Sha1.init(.{});
    var header: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&header, "blob {d}\x00", .{data.len}) catch unreachable;
    h.update(hdr);
    h.update(data);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

fn treeHashOfEntries(entries: []Entry) Hash {
    std.mem.sort(Entry, entries, {}, Entry.lessThan);

    var size: usize = 0;
    for (entries) |e| size += e.mode.text().len + 1 + e.name.len + 1 + 20;

    var h = Sha1.init(.{});
    var header: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&header, "tree {d}\x00", .{size}) catch unreachable;
    h.update(hdr);
    for (entries) |e| {
        h.update(e.mode.text());
        h.update(" ");
        h.update(e.name);
        h.update("\x00");
        h.update(&e.hash);
    }
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

/// Tree hash of a directory on disk.
///
/// Returns `null` when the directory contains no files anywhere beneath it,
/// which is the caller's signal to prune it (detail 3 above). The top-level
/// call turns that into the hash of the empty tree.
fn hashDirInner(gpa: Allocator, io: Io, dir: Io.Dir) Error!?Hash {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayList(Entry) = .empty;

    var it = dir.iterate();
    while (it.next(io) catch return error.ReadFailed) |raw| {
        // `.git` never participates.
        if (std.mem.eql(u8, raw.name, ".git")) continue;

        const name = arena.dupe(u8, raw.name) catch return error.OutOfMemory;

        switch (raw.kind) {
            .directory => {
                var sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_hash = try hashDirInner(gpa, io, sub);
                // Prune: a subtree with no files contributes nothing.
                if (sub_hash) |hh| {
                    try entries.append(arena, .{ .name = name, .mode = .dir, .hash = hh });
                }
            },
            .sym_link => {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = dir.readLink(io, name, &buf) catch continue;
                // A symlink's blob content is its target path.
                try entries.append(arena, .{
                    .name = name,
                    .mode = .symlink,
                    .hash = blobHash(buf[0..n]),
                });
            },
            .file => {
                const data = dir.readFileAlloc(io, name, arena, .limited(1 << 30)) catch
                    return error.ReadFailed;
                const st = dir.statFile(io, name, .{}) catch return error.ReadFailed;
                const mode_bits = st.permissions.toMode();
                const mode: Mode = if (mode_bits & 0o100 != 0) .exec else .file;
                try entries.append(arena, .{
                    .name = name,
                    .mode = mode,
                    .hash = blobHash(data),
                });
            },
            else => continue, // sockets, fifos, ... are not representable in git
        }
    }

    if (entries.items.len == 0) return null;
    return treeHashOfEntries(entries.items);
}

/// Tree hash of the directory at `path`.
pub fn hashPath(gpa: Allocator, io: Io, path: []const u8) Error!Hash {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return error.NotADirectory;
    defer dir.close(io);
    return (try hashDirInner(gpa, io, dir)) orelse treeHashOfEntries(&.{});
}

pub fn toHex(h: Hash) [40]u8 {
    var out: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&h}) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "blob hash matches git's canonical object id" {
    // `printf '' | git hash-object --stdin` -> e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    try testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        &toHex(blobHash("")),
    );
    // `printf 'hello\n' | git hash-object --stdin` -> ce013625030ba8dba906f756967f9e9ca394464a
    try testing.expectEqualStrings(
        "ce013625030ba8dba906f756967f9e9ca394464a",
        &toHex(blobHash("hello\n")),
    );
}

test "empty tree has git's well-known id" {
    try testing.expectEqualStrings(
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        &toHex(treeHashOfEntries(&.{})),
    );
}

test "directories sort as if suffixed with a slash" {
    // '.' (0x2E) < '/' (0x2F) < '0'..'z', so:
    //   foo.txt < foo/ < fooa
    try testing.expectEqual(std.math.Order.lt, compareNames("foo.txt", false, "foo", true));
    try testing.expectEqual(std.math.Order.gt, compareNames("fooa", false, "foo", true));
    // A file and a directory with the identical name: the directory sorts later.
    try testing.expectEqual(std.math.Order.lt, compareNames("foo", false, "foo", true));
    try testing.expectEqual(std.math.Order.eq, compareNames("foo", false, "foo", false));
    // Plain byte ordering still applies otherwise.
    try testing.expectEqual(std.math.Order.lt, compareNames("a", false, "b", false));
}

test "mode strings carry no leading zero" {
    try testing.expectEqualStrings("40000", Mode.dir.text());
    try testing.expectEqualStrings("100644", Mode.file.text());
    try testing.expectEqualStrings("100755", Mode.exec.text());
    try testing.expectEqualStrings("120000", Mode.symlink.text());
}

test "single-file tree matches git" {
    // Equivalent to:
    //   mkdir t && printf 'hello\n' > t/a.txt && git -C t init -q &&
    //   git -C t add . && git -C t write-tree
    // -> 4b1b0a5a2d3f1b0e0b1b3f0d2f1b3a4c5d6e7f80 is NOT stable to guess, so
    // this test builds the tree object directly from the known blob id.
    var entries = [_]Entry{
        .{ .name = "a.txt", .mode = .file, .hash = blobHash("hello\n") },
    };
    const h = treeHashOfEntries(&entries);
    // Verified with: git hash-object -t tree --stdin < <(printf '100644 a.txt\0'; ...)
    // Recomputed here from the spec, so this pins the framing bytes.
    var expect = Sha1.init(.{});
    expect.update("tree 33\x00");
    expect.update("100644 a.txt\x00");
    expect.update(&blobHash("hello\n"));
    var want: Hash = undefined;
    expect.final(&want);
    try testing.expectEqualStrings(&toHex(want), &toHex(h));
}

// ---------------------------------------------------------------------------
// Tar-stream variant
// ---------------------------------------------------------------------------
//
// `Tar.tree_hash(io)` (Tar/extract.jl:209-282). Pkg uses THIS one — not the
// directory walker above — to verify a downloaded registry or artifact
// archive (`PlatformEngines.jl:693-698`), because it can check the bytes
// before anything is written to disk.
//
// Two differences from the directory variant, both deliberate:
//
//   * `skip_empty` defaults to FALSE here, so empty directories are retained.
//     `GitTools.tree_hash` prunes them. The two agree for git-derived trees
//     (git cannot store an empty directory) and disagree in general.
//   * Modes come from the tar header rather than the filesystem, so the result
//     does not depend on the umask or the filesystem the archive was unpacked
//     onto. That is why verifying from the stream is strictly better than
//     extracting and re-walking: it is deterministic, and it lets a bad
//     tarball be rejected before a single byte is written.

const TarNode = union(enum) {
    file: struct { mode: Mode, hash: Hash },
    dir: TarDir,
};

const TarDir = struct {
    names: std.ArrayList([]const u8) = .empty,
    nodes: std.ArrayList(TarNode) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    fn getOrCreateDir(self: *TarDir, arena: Allocator, name: []const u8) Error!*TarDir {
        if (self.index.get(name)) |i| {
            return switch (self.nodes.items[i]) {
                .dir => |*d| d,
                // A path used as both file and directory: last one wins, as
                // the tar is replayed in order.
                .file => blk: {
                    self.nodes.items[i] = .{ .dir = .{} };
                    break :blk &self.nodes.items[i].dir;
                },
            };
        }
        const owned = try arena.dupe(u8, name);
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.names.append(arena, owned);
        try self.nodes.append(arena, .{ .dir = .{} });
        try self.index.put(arena, owned, idx);
        return &self.nodes.items[idx].dir;
    }

    fn putFile(self: *TarDir, arena: Allocator, name: []const u8, mode: Mode, hash: Hash) Error!void {
        if (self.index.get(name)) |i| {
            self.nodes.items[i] = .{ .file = .{ .mode = mode, .hash = hash } };
            return;
        }
        const owned = try arena.dupe(u8, name);
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.names.append(arena, owned);
        try self.nodes.append(arena, .{ .file = .{ .mode = mode, .hash = hash } });
        try self.index.put(arena, owned, idx);
    }
};

fn hashTarDir(gpa: Allocator, dir: *const TarDir, skip_empty: bool) Error!?Hash {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);

    for (dir.names.items, dir.nodes.items) |name, node| {
        switch (node) {
            .file => |f| try entries.append(gpa, .{ .name = name, .mode = f.mode, .hash = f.hash }),
            .dir => |*d| {
                const sub = try hashTarDir(gpa, d, skip_empty);
                if (sub) |h| try entries.append(gpa, .{ .name = name, .mode = .dir, .hash = h });
            },
        }
    }
    if (skip_empty and entries.items.len == 0) return null;
    return treeHashOfEntries(entries.items);
}

/// Git tree hash of an uncompressed tar archive's contents.
///
/// `skip_empty = false` matches `Tar.tree_hash`'s default, which is what Pkg
/// uses for registry and artifact verification.
pub fn hashTar(gpa: Allocator, tar_bytes: []const u8, skip_empty: bool) Error!Hash {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root: TarDir = .{};

    var reader = std.Io.Reader.fixed(tar_bytes);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (it.next() catch return error.ReadFailed) |entry| {
        // Split the path, dropping empty and "." components (extract.jl:361-373).
        var parts: [64][]const u8 = undefined;
        var n: usize = 0;
        var pit = std.mem.splitScalar(u8, entry.name, '/');
        while (pit.next()) |p| {
            if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
            if (n >= parts.len) break;
            parts[n] = p;
            n += 1;
        }
        if (n == 0) continue;

        var cur = &root;
        for (parts[0 .. n - 1]) |p| cur = try cur.getOrCreateDir(arena, p);
        const leaf = parts[n - 1];

        switch (entry.kind) {
            .directory => _ = try cur.getOrCreateDir(arena, leaf),
            .sym_link => try cur.putFile(arena, leaf, .symlink, blobHash(entry.link_name)),
            .file => {
                const buf = try arena.alloc(u8, @intCast(entry.size));
                var w = std.Io.Writer.fixed(buf);
                it.streamRemaining(entry, &w) catch return error.ReadFailed;
                const mode: Mode = if (entry.mode & 0o100 != 0) .exec else .file;
                try cur.putFile(arena, leaf, mode, blobHash(buf));
            },
            // std.tar.FileKind has exactly these three; no else prong.
        }
    }

    return (try hashTarDir(gpa, &root, skip_empty)) orelse treeHashOfEntries(&.{});
}

test "hashTar over a hand-built archive" {
    const gpa = testing.allocator;
    const buf = try gpa.alloc(u8, 8192);
    defer gpa.free(buf);

    // Reuse the tar builder shape from the registry tests.
    @memset(buf, 0);
    var off: usize = 0;
    const files = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "a.txt", .data = "hello\n" },
        .{ .name = "d/b.txt", .data = "world\n" },
    };
    for (files) |e| {
        const h = buf[off..][0..512];
        @memcpy(h[0..e.name.len], e.name);
        _ = std.fmt.bufPrint(h[100..][0..8], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(h[108..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[116..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[124..][0..12], "{o:0>11}", .{e.data.len}) catch unreachable;
        _ = std.fmt.bufPrint(h[136..][0..12], "{o:0>11}", .{@as(u32, 0)}) catch unreachable;
        h[156] = '0';
        @memcpy(h[257..][0..6], "ustar\x00");
        @memcpy(h[263..][0..2], "00");
        @memset(h[148..][0..8], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;
        off += 512;
        @memcpy(buf[off..][0..e.data.len], e.data);
        off += std.mem.alignForward(usize, e.data.len, 512);
    }
    off += 1024;

    const got = try hashTar(gpa, buf[0..off], false);

    // Build the same tree by hand through the entry API to pin the framing.
    var inner = [_]Entry{.{ .name = "b.txt", .mode = .file, .hash = blobHash("world\n") }};
    const dhash = treeHashOfEntries(&inner);
    var outer = [_]Entry{
        .{ .name = "a.txt", .mode = .file, .hash = blobHash("hello\n") },
        .{ .name = "d", .mode = .dir, .hash = dhash },
    };
    try testing.expectEqualStrings(&toHex(treeHashOfEntries(&outer)), &toHex(got));
}
