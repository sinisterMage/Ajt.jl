//! Loads a Julia registry tarball into memory.
//!
//! Pkg keeps the General registry COMPRESSED on disk as
//! `registries/General.tar.gz` plus a `General.toml` pointer, and reads it
//! in-memory rather than unpacking (`Registry/Registry.jl:218-222`, unless
//! `JULIA_PKG_UNPACK_REGISTRY` is set). Ajt does the same.
//!
//! Measured on the real General registry: 10.9 MB compressed -> 83.8 MB and
//! 58,941 files. That is a textbook arena workload -- parse it, use it, drop
//! the whole thing at once -- so everything here hangs off one arena and there
//! is no per-entry ownership to get wrong.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    DecompressFailed,
    MalformedTar,
} || Allocator.Error;

/// An in-memory registry tarball: a map from archive path to file contents.
pub const Archive = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Archive) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Archive, path: []const u8) ?[]const u8 {
        return self.files.get(path);
    }

    pub fn count(self: *const Archive) usize {
        return self.files.count();
    }
};

/// Indexes every regular file in an uncompressed tar.
///
/// `tar_bytes` is borrowed; the Archive owns copies of what it keeps.
pub fn loadTar(gpa: Allocator, tar_bytes: []const u8) Error!Archive {
    var archive: Archive = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer archive.deinit();
    const arena = archive.arena.allocator();

    var tar_reader = Io.Reader.fixed(tar_bytes);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (it.next() catch return error.MalformedTar) |entry| {
        if (entry.kind != .file) continue;
        const name = try arena.dupe(u8, entry.name);
        const buf = try arena.alloc(u8, @intCast(entry.size));
        var w = Io.Writer.fixed(buf);
        it.streamRemaining(entry, &w) catch return error.MalformedTar;
        try archive.files.put(arena, name, buf);
    }

    return archive;
}

/// Decompresses gzip'd tar bytes and indexes every regular file.
///
/// The decompressed tar is held in `gpa` and freed once its contents have been
/// copied into the Archive's arena, so steady-state memory is one copy of the
/// registry (~84 MB for General) rather than two.
pub fn loadGzipped(gpa: Allocator, gz: []const u8) Error!Archive {
    var gz_reader = Io.Reader.fixed(gz);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var decompress = std.compress.flate.Decompress.init(&gz_reader, .gzip, window);
    const tar_bytes = decompress.reader.allocRemaining(gpa, .limited(1 << 30)) catch
        return error.DecompressFailed;
    defer gpa.free(tar_bytes);
    return loadTar(gpa, tar_bytes);
}

/// Convenience: read `<depot>/registries/<name>.tar.gz` and load it.
pub fn loadFromDepot(gpa: Allocator, io: Io, depot: []const u8, name: []const u8) !Archive {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/registries/{s}.tar.gz", .{ depot, name });
    const gz = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(gz);
    return loadGzipped(gpa, gz);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a minimal ustar archive in `buf`, so the test needs no fixture file.
fn buildTar(buf: []u8, entries: []const struct { name: []const u8, data: []const u8 }) []u8 {
    @memset(buf, 0);
    var off: usize = 0;
    for (entries) |e| {
        const h = buf[off..][0..512];
        @memcpy(h[0..e.name.len], e.name);
        _ = std.fmt.bufPrint(h[100..][0..8], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(h[108..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[116..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[124..][0..12], "{o:0>11}", .{e.data.len}) catch unreachable;
        _ = std.fmt.bufPrint(h[136..][0..12], "{o:0>11}", .{@as(u32, 0)}) catch unreachable;
        h[156] = '0'; // typeflag: regular file
        @memcpy(h[257..][0..6], "ustar\x00");
        @memcpy(h[263..][0..2], "00");

        // Checksum is computed with the checksum field itself read as spaces.
        @memset(h[148..][0..8], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;

        off += 512;
        @memcpy(buf[off..][0..e.data.len], e.data);
        off += std.mem.alignForward(usize, e.data.len, 512);
    }
    off += 1024; // two zero blocks terminate the archive
    return buf[0..off];
}

test "loadTar indexes regular files by path" {
    const buf = try testing.allocator.alloc(u8, 8192);
    defer testing.allocator.free(buf);
    const tar_bytes = buildTar(buf, &.{
        .{ .name = "Registry.toml", .data = "name = \"General\"\n" },
        .{ .name = "S/StaticArrays/Versions.toml", .data = "[\"1.0.0\"]\ngit-tree-sha1 = \"abc\"\n" },
    });

    var archive = try loadTar(testing.allocator, tar_bytes);
    defer archive.deinit();

    try testing.expectEqual(@as(usize, 2), archive.count());
    try testing.expectEqualStrings("name = \"General\"\n", archive.get("Registry.toml").?);
    try testing.expect(archive.get("S/StaticArrays/Versions.toml") != null);
    try testing.expect(archive.get("nope") == null);
}

test "loadGzipped round-trips through a real gzip stream" {
    const raw = try testing.allocator.alloc(u8, 8192);
    defer testing.allocator.free(raw);
    const tar_bytes = buildTar(raw, &.{
        .{ .name = "Registry.toml", .data = "name = \"General\"\n" },
    });

    // Compress with std so the test exercises the actual gzip path.
    const outbuf = try testing.allocator.alloc(u8, 16384);
    defer testing.allocator.free(outbuf);
    var out = std.Io.Writer.fixed(outbuf);
    const cbuf = try testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer testing.allocator.free(cbuf);
    var comp = try std.compress.flate.Compress.init(&out, cbuf, .gzip, .default);
    try comp.writer.writeAll(tar_bytes);
    try comp.finish();

    var archive = try loadGzipped(testing.allocator, out.buffered());
    defer archive.deinit();
    try testing.expectEqualStrings("name = \"General\"\n", archive.get("Registry.toml").?);
}
