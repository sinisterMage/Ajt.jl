//! Reading a Julia package registry.
//!
//! Port of the parts of `Pkg/src/Registry/registry_instance.jl` that the
//! resolver needs: the package table, per-package versions, and the
//! *uncompressed* dependency and compat maps.
//!
//! The subtle piece is `uncompress` (`registry_instance.jl:70-102`).
//! `Deps.toml`/`Compat.toml` are keyed by a `VersionRange`, and expanding one
//! is NOT "apply to every version satisfying the range". It is:
//!
//!   * find the FIRST index whose version satisfies the range,
//!   * find the LAST index whose version satisfies the range,
//!   * apply the entry to every index in `first..last` **inclusive**.
//!
//! So a version sitting between those endpoints inherits the entry even if it
//! does not itself satisfy the range. Implementing the intuitive reading gives
//! subtly different dependency sets for exactly the packages whose version
//! lists are non-contiguous — a bug that would surface as a mysterious
//! resolution difference much later.
//!
//! A duplicate DEP key across two overlapping spans is an error ("Overlapping
//! ranges"), not a last-one-wins merge.
//!
//! Separately, two textually different SECTION keys can normalise to the same
//! `VersionRange` (because its constructor collapses `lo.t == hi.t`), in which
//! case Julia's `Dict`-keyed storage silently drops one — see
//! `supersededLater` below. Found by differential testing, not by reading:
//! one file in all of General hits it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tarball = @import("tarball.zig");
const toml = @import("../toml/parse.zig");
const Table = @import("../toml/value.zig").Table;
const Value = @import("../toml/value.zig").Value;
const version_mod = @import("../julia/version.zig");
const Version = version_mod.Version;
const versions_mod = @import("../julia/versions.zig");
const Spec = versions_mod.Spec;

/// Every registered package implicitly depends on julia
/// (`registry_instance.jl:104`, injected at `:227`).
pub const julia_uuid = "1222c4b2-2114-5bfd-aeef-88e4692bbb3e";

pub const Error = error{
    MalformedRegistry,
    OverlappingRanges,
    UnknownPackage,
} || toml.Error || versions_mod.ParseError || version_mod.ParseError || Allocator.Error;

pub const PackageRef = struct {
    uuid: []const u8,
    name: []const u8,
    /// Path within the archive, e.g. `S/StaticArrays`. NEVER reconstruct this
    /// from the name: the registry also contains a `jll/` subtree, so the
    /// `<Letter>/<Name>` shape does not hold universally.
    path: []const u8,
};

pub const Registry = struct {
    archive: tarball.Archive,
    name: []const u8 = "",
    uuid: []const u8 = "",
    packages: []PackageRef = &.{},

    pub fn deinit(self: *Registry) void {
        self.archive.deinit();
    }

    pub fn findByName(self: *const Registry, name: []const u8) ?PackageRef {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn findByUuid(self: *const Registry, uuid: []const u8) ?PackageRef {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.uuid, uuid)) return p;
        }
        return null;
    }
};

/// Parses `Registry.toml` out of an already-loaded archive. Takes ownership of
/// the archive.
pub fn open(archive: tarball.Archive) Error!Registry {
    var reg: Registry = .{ .archive = archive };
    const arena = reg.archive.arena.allocator();

    const src = reg.archive.get("Registry.toml") orelse return error.MalformedRegistry;
    var doc = try toml.parse(arena, src, null);
    // NB: doc's arena IS the archive arena, so no separate deinit.

    if (doc.root.get("name")) |v| switch (v) {
        .string => |s| reg.name = s,
        else => {},
    };
    if (doc.root.get("uuid")) |v| switch (v) {
        .string => |s| reg.uuid = s,
        else => {},
    };

    const pkgs_tbl: *Table = if (doc.root.get("packages")) |v| switch (v) {
        .table => |t| t,
        else => return error.MalformedRegistry,
    } else return error.MalformedRegistry;

    var list = try arena.alloc(PackageRef, pkgs_tbl.entries.items.len);
    var n: usize = 0;
    for (pkgs_tbl.entries.items) |e| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const nm = switch (t.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const pth = switch (t.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        list[n] = .{ .uuid = e.key, .name = nm, .path = pth };
        n += 1;
    }
    reg.packages = list[0..n];
    return reg;
}

pub const VersionInfo = struct {
    version: Version,
    tree_hash: []const u8,
    yanked: bool = false,
};

pub const Dep = struct {
    name: []const u8,
    uuid: []const u8,
    /// Already uncompressed; `*` when the registry records no constraint.
    compat: Spec,
};

/// A package's registry entry, fully uncompressed. Owns its own arena.
pub const PackageInfo = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    uuid: []const u8,
    repo: []const u8 = "",
    /// Ascending by version.
    versions: []VersionInfo,
    /// `deps[i]` are the dependencies of `versions[i]`.
    deps: [][]Dep,

    pub fn deinit(self: *PackageInfo) void {
        self.arena.deinit();
    }

    pub fn indexOfVersion(self: *const PackageInfo, v: Version) ?usize {
        for (self.versions, 0..) |vi, i| {
            if (vi.version.eql(v)) return i;
        }
        return null;
    }
};

/// Reads and uncompresses one package's registry entry.
pub fn loadPackage(gpa: Allocator, reg: *const Registry, ref: PackageRef) Error!PackageInfo {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buf: [512]u8 = undefined;

    // --- Package.toml -------------------------------------------------------
    var repo: []const u8 = "";
    if (reg.archive.get(try join(&path_buf, ref.path, "Package.toml"))) |src| {
        var doc = try toml.parse(arena, src, null);
        if (doc.root.get("repo")) |v| switch (v) {
            .string => |s| repo = s,
            else => {},
        };
    }

    // --- Versions.toml ------------------------------------------------------
    const versions_src = reg.archive.get(try join(&path_buf, ref.path, "Versions.toml")) orelse
        return error.MalformedRegistry;
    const vdoc = try toml.parse(arena, versions_src, null);

    var vlist: std.ArrayList(VersionInfo) = .empty;
    for (vdoc.root.entries.items) |e| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const th = switch (t.get("git-tree-sha1") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const yanked = if (t.get("yanked")) |y| switch (y) {
            .boolean => |b| b,
            else => false,
        } else false;
        try vlist.append(arena, .{
            .version = try version_mod.parse(arena, e.key),
            .tree_hash = th,
            .yanked = yanked,
        });
    }
    std.mem.sort(VersionInfo, vlist.items, {}, struct {
        fn lt(_: void, a: VersionInfo, b: VersionInfo) bool {
            return a.version.lessThan(b.version);
        }
    }.lt);
    const vsorted = vlist.items;

    // --- Deps.toml / Compat.toml -------------------------------------------
    // Per version: name -> uuid, and name -> spec.
    const dep_maps = try arena.alloc(std.StringHashMapUnmanaged([]const u8), vsorted.len);
    const compat_maps = try arena.alloc(std.StringHashMapUnmanaged(Spec), vsorted.len);
    for (dep_maps, compat_maps) |*d, *c| {
        d.* = .empty;
        c.* = .empty;
    }

    if (reg.archive.get(try join(&path_buf, ref.path, "Deps.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressDeps(arena, doc.root, vsorted, dep_maps);
    }
    if (reg.archive.get(try join(&path_buf, ref.path, "Compat.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressCompat(arena, doc.root, vsorted, compat_maps);
    }

    // --- stitch deps + compat ----------------------------------------------
    const deps = try arena.alloc([]Dep, vsorted.len);
    for (0..vsorted.len) |i| {
        var out: std.ArrayList(Dep) = .empty;
        var it = dep_maps[i].iterator();
        while (it.next()) |kv| {
            const dname = kv.key_ptr.*;
            const spec = compat_maps[i].get(dname) orelse try Spec.all(arena);
            try out.append(arena, .{ .name = dname, .uuid = kv.value_ptr.*, .compat = spec });
        }
        // Everything depends on julia (registry_instance.jl:227). Its constraint
        // comes from Compat.toml like any other dep.
        if (dep_maps[i].get("julia") == null) {
            const spec = compat_maps[i].get("julia") orelse try Spec.all(arena);
            try out.append(arena, .{ .name = "julia", .uuid = julia_uuid, .compat = spec });
        }
        std.mem.sort(Dep, out.items, {}, struct {
            fn lt(_: void, a: Dep, b: Dep) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        deps[i] = out.items;
    }

    return .{
        .arena = arena_state,
        .name = ref.name,
        .uuid = ref.uuid,
        .repo = repo,
        .versions = vsorted,
        .deps = deps,
    };
}

fn join(buf: []u8, dir: []const u8, file: []const u8) Allocator.Error![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, file }) catch return error.OutOfMemory;
}

/// True when a LATER section in the same file parses to an equal `VersionRange`.
///
/// Julia stores these files as `Dict{VersionRange, ...}` and assigns
/// `compat[vr] = d` per section (`registry_instance.jl:210-214`), so when two
/// textually different keys normalise to the same range, one section is
/// silently DROPPED. `VersionRange`'s constructor collapses `lo.t == hi.t`, so
/// e.g. `["2 - 2.0"]` and `["2.0"]` are the same key.
///
/// This is real: `O/OrdinaryDiffEqNonlinearSolve/Compat.toml` contains exactly
/// that pair, and it is the ONLY such file among 29,381 in General. Julia's
/// winner depends on `Dict` hash iteration order, so it is not reproducible by
/// construction; Ajt takes the LAST section in file order, which is
/// deterministic and happens to agree with Julia on the one real instance.
///
/// Applying both sections instead would arguably be more faithful to what the
/// registry author wrote, but it would diverge from Julia and could hand the
/// resolver two conflicting constraints for one version span.
fn supersededLater(entries: []const @import("../toml/value.zig").Entry, i: usize, r: versions_mod.Range) bool {
    for (entries[i + 1 ..]) |later| {
        const lr = versions_mod.Range.parse(later.key) catch continue;
        if (lr.eql(r)) return true;
    }
    return false;
}

/// Finds the `first..last` index span a range key covers. Returns null when the
/// range matches nothing.
fn rangeSpan(range_text: []const u8, vsorted: []const VersionInfo) Error!?struct { first: usize, last: usize } {
    const range = try versions_mod.Range.parse(range_text);
    var first: ?usize = null;
    for (vsorted, 0..) |vi, i| {
        if (range.contains(vi.version)) {
            first = i;
            break;
        }
    }
    const f = first orelse return null;
    var last: usize = f;
    var i: usize = vsorted.len;
    while (i > 0) {
        i -= 1;
        if (range.contains(vsorted[i].version)) {
            last = i;
            break;
        }
    }
    return .{ .first = f, .last = last };
}

fn uncompressDeps(
    arena: Allocator,
    root: *const Table,
    vsorted: []const VersionInfo,
    out: []std.StringHashMapUnmanaged([]const u8),
) Error!void {
    for (root.entries.items, 0..) |e, ei| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const parsed = versions_mod.Range.parse(e.key) catch continue;
        if (supersededLater(root.entries.items, ei, parsed)) continue;
        const span = (try rangeSpan(e.key, vsorted)) orelse continue;
        for (span.first..span.last + 1) |i| {
            for (t.entries.items) |kv| {
                const uuid = switch (kv.value) {
                    .string => |s| s,
                    else => continue,
                };
                if (out[i].contains(kv.key)) return error.OverlappingRanges;
                try out[i].put(arena, kv.key, uuid);
            }
        }
    }
}

fn uncompressCompat(
    arena: Allocator,
    root: *const Table,
    vsorted: []const VersionInfo,
    out: []std.StringHashMapUnmanaged(Spec),
) Error!void {
    for (root.entries.items, 0..) |e, ei| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const parsed = versions_mod.Range.parse(e.key) catch continue;
        if (supersededLater(root.entries.items, ei, parsed)) continue;
        const span = (try rangeSpan(e.key, vsorted)) orelse continue;
        for (span.first..span.last + 1) |i| {
            for (t.entries.items) |kv| {
                // A compat value is either one range string or an array of them.
                const spec: Spec = switch (kv.value) {
                    .string => |s| try Spec.parse(arena, s),
                    .array => |items| blk: {
                        const parts = try arena.alloc([]const u8, items.len);
                        for (items, 0..) |item, j| parts[j] = switch (item) {
                            .string => |s| s,
                            else => return error.MalformedRegistry,
                        };
                        break :blk try Spec.parseMany(arena, parts);
                    },
                    else => continue,
                };
                if (out[i].contains(kv.key)) return error.OverlappingRanges;
                try out[i].put(arena, kv.key, spec);
            }
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn miniRegistry(gpa: Allocator) !Registry {
    const buf = try gpa.alloc(u8, 16384);
    defer gpa.free(buf);
    const entries = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
        \\
        },
        .{ .name = "D/Demo/Package.toml", .data =
        \\name = "Demo"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\repo = "https://example.com/Demo.jl.git"
        \\
        },
        .{ .name = "D/Demo/Versions.toml", .data =
        \\["1.0.0"]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\
        \\["1.1.0"]
        \\git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\
        \\["2.0.0"]
        \\git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
        \\yanked = true
        \\
        },
        .{ .name = "D/Demo/Deps.toml", .data =
        \\["1"]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
        \\["2"]
        \\Beta = "00000000-0000-0000-0000-0000000000b1"
        \\
        },
        .{ .name = "D/Demo/Compat.toml", .data =
        \\["1"]
        \\Alpha = "0.5"
        \\julia = "1.6.0 - 1"
        \\
        \\["2"]
        \\Beta = ["0.7", "1-1.11"]
        \\
        },
    };
    const tar_bytes = tarball_buildTar(buf, &entries);
    const archive = try tarball.loadTar(gpa, tar_bytes);
    return open(archive);
}

/// Mirrors the tar builder in tarball.zig's tests.
fn tarball_buildTar(buf: []u8, entries: anytype) []u8 {
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
    return buf[0..off];
}

test "opens a registry and lists packages" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();

    try testing.expectEqualStrings("Mini", reg.name);
    try testing.expectEqual(@as(usize, 1), reg.packages.len);
    try testing.expectEqualStrings("Demo", reg.packages[0].name);
    // Path comes from Registry.toml, never reconstructed from the name.
    try testing.expectEqualStrings("D/Demo", reg.packages[0].path);
    try testing.expect(reg.findByName("Demo") != null);
    try testing.expect(reg.findByName("Nope") == null);
}

test "loads versions sorted, with tree hashes and yank flags" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();

    try testing.expectEqualStrings("https://example.com/Demo.jl.git", pkg.repo);
    try testing.expectEqual(@as(usize, 3), pkg.versions.len);
    try testing.expectEqual(@as(u64, 1), pkg.versions[0].version.major);
    try testing.expectEqual(@as(u64, 1), pkg.versions[1].version.minor);
    try testing.expectEqual(@as(u64, 2), pkg.versions[2].version.major);
    try testing.expect(!pkg.versions[0].yanked);
    try testing.expect(pkg.versions[2].yanked);
    try testing.expectEqualStrings("aaaa" ++ "a" ** 36, pkg.versions[0].tree_hash);
}

test "deps and compat are uncompressed per version, with julia injected" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();

    // 1.0.0 and 1.1.0 both fall in the ["1"] range -> Alpha.
    for ([_]usize{ 0, 1 }) |i| {
        try testing.expectEqual(@as(usize, 2), pkg.deps[i].len); // Alpha + julia
        try testing.expectEqualStrings("Alpha", pkg.deps[i][0].name);
        try testing.expectEqualStrings("julia", pkg.deps[i][1].name);

        const alpha = try pkg.deps[i][0].compat.toString(testing.allocator);
        defer testing.allocator.free(alpha);
        try testing.expectEqualStrings("0.5", alpha);

        const jl = try pkg.deps[i][1].compat.toString(testing.allocator);
        defer testing.allocator.free(jl);
        try testing.expectEqualStrings("1.6.0 - 1", jl);
    }

    // 2.0.0 falls in ["2"] -> Beta, and julia is unconstrained there.
    try testing.expectEqual(@as(usize, 2), pkg.deps[2].len);
    try testing.expectEqualStrings("Beta", pkg.deps[2][0].name);
    const beta = try pkg.deps[2][0].compat.toString(testing.allocator);
    defer testing.allocator.free(beta);
    // A compat ARRAY is a union of ranges. `0.7` and `1-1.11` are NOT
    // joinable -- isjoinable compares up=(0,7) against lo=(1) over their
    // common prefix, and 0 < 1 ends it -- so they stay two ranges and the
    // spec prints in bracket form. Confirmed against
    //   julia -e 'print(Pkg.Versions.VersionSpec(["0.7","1-1.11"]))'
    try testing.expectEqualStrings("[0.7, 1 - 1.11]", beta);

    const jl2 = try pkg.deps[2][1].compat.toString(testing.allocator);
    defer testing.allocator.free(jl2);
    try testing.expectEqualStrings("*", jl2);
}

test "a range covering nothing contributes nothing" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();
    // Every version got exactly one real dep plus julia; nothing leaked across.
    for (pkg.deps) |d| try testing.expectEqual(@as(usize, 2), d.len);
}
