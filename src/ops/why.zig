//! `ajt why <package>` — why is this in the manifest?
//!
//! Port of `Pkg.why` (`API.jl:1556-1612`). It answers with every dependency
//! path from one of the project's direct dependencies down to the package, and
//! the direction of the walk is the whole trick: it builds the REVERSE graph
//! from the manifest — "who depends on me" — and walks upward from the target
//! until it reaches something the project asks for directly.
//!
//! Three details that are easy to get subtly wrong, all of them visible in the
//! output:
//!
//!  1. **Reaching a direct dependency records a path but does not stop the
//!     walk** (`:1582-1583`). A package can be both a direct dependency and a
//!     dependency of another direct dependency, and both routes are true
//!     answers. The walk only stops where nothing depends on the current
//!     package.
//!  2. **Cycles are skipped, not errors** (`:1585-1591`). A manifest edited by
//!     hand can contain one, and `why` is exactly the command someone reaches
//!     for when trying to understand such a file.
//!  3. **Paths are a SET** (`:1601`), so two routes that differ only in the
//!     order they were discovered collapse into one, and the printed order is
//!     `sort!(by = x -> (x, length(x)))` over the NAME vectors.
//!
//! This reads the manifest and nothing else: no registry, no depot, no
//! resolve. `why` on an environment whose packages are not installed still
//! works, which matters because "why is this thing here" is usually asked
//! before deciding whether to install it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const project_mod = @import("../model/project.zig");
const manifest_mod = @import("../model/manifest.zig");

pub const Uuid = manifest_mod.Uuid;

pub const Error = error{
    NoProject,
    NoManifest,
    /// Pkg's `ensure_resolved` — the name is in neither the manifest nor the
    /// project, so there is nothing to explain.
    NotInManifest,
};

pub const Options = struct {
    project_file: []const u8,
    manifest_file: []const u8,
};

/// One route, from a direct dependency of the project down to the target.
pub const Path = struct {
    names: []const []const u8,
};

/// Every distinct path, sorted as Pkg sorts them. Arena-owned.
pub fn run(arena: Allocator, io: Io, opts: Options, name: []const u8) ![]const Path {
    const proj_src = Io.Dir.cwd().readFileAlloc(io, opts.project_file, arena, .limited(8 << 20)) catch
        return Error.NoProject;
    const proj = try project_mod.parse(arena, proj_src, .{ .file = opts.project_file }, null);
    const man_src = Io.Dir.cwd().readFileAlloc(io, opts.manifest_file, arena, .limited(64 << 20)) catch
        return Error.NoManifest;
    const man = try manifest_mod.parse(arena, man_src, null);

    const target = man.findByName(name) orelse return Error.NotInManifest;

    // The reverse graph: for each entry, an edge from each of its deps back to
    // it (`:1564-1570`).
    var incoming = std.AutoHashMapUnmanaged([16]u8, std.ArrayListUnmanaged([16]u8)).empty;
    for (man.entries) |e| {
        for (e.deps) |d| {
            const gop = try incoming.getOrPut(arena, d.uuid.bytes);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, e.uuid.bytes);
        }
    }

    var direct = std.AutoHashMapUnmanaged([16]u8, void).empty;
    for (proj.deps.entries.items) |d| try direct.put(arena, d.uuid.bytes, {});

    var found: std.ArrayList([]const [16]u8) = .empty;
    var path: std.ArrayList([16]u8) = .empty;
    try walk(arena, target.uuid.bytes, incoming, direct, &path, &found);

    // uuid paths -> name paths, reversed so they read from the project
    // downward (`:1603-1604`).
    var out: std.ArrayList(Path) = .empty;
    for (found.items) |p| {
        const names = try arena.alloc([]const u8, p.len);
        for (p, 0..) |u, i| {
            const entry = man.findByUuid(.{ .bytes = u });
            names[p.len - 1 - i] = if (entry) |e| e.name else "?";
        }
        // `final_paths` is a Set: two walks that produce the same name vector
        // are one answer.
        var dup = false;
        for (out.items) |existing| {
            if (eqlNames(existing.names, names)) dup = true;
        }
        if (!dup) try out.append(arena, .{ .names = names });
    }

    std.mem.sort(Path, out.items, {}, lessThan);
    return out.items;
}

fn walk(
    arena: Allocator,
    current: [16]u8,
    incoming: std.AutoHashMapUnmanaged([16]u8, std.ArrayListUnmanaged([16]u8)),
    direct: std.AutoHashMapUnmanaged([16]u8, void),
    path: *std.ArrayList([16]u8),
    found: *std.ArrayList([]const [16]u8),
) Allocator.Error!void {
    try path.append(arena, current);
    // Recorded, and then the walk CONTINUES — see the header.
    if (direct.contains(current)) try found.append(arena, try arena.dupe([16]u8, path.items));
    const preds = incoming.get(current) orelse return;
    for (preds.items) |p| {
        var seen = false;
        for (path.items) |q| {
            if (std.mem.eql(u8, &q, &p)) seen = true;
        }
        if (seen) continue; // a cycle, skipped rather than raised
        var branch: std.ArrayList([16]u8) = .empty;
        try branch.appendSlice(arena, path.items);
        try walk(arena, p, incoming, direct, &branch, found);
    }
}

fn eqlNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// `sort!(final_paths_names, by = x -> (x, length(x)))` — lexicographic on the
/// name vector first, which already decides every pair that differs, so the
/// length is only a tie-break for identical prefixes.
fn lessThan(_: void, a: Path, b: Path) bool {
    const n = @min(a.names.len, b.names.len);
    for (0..n) |i| {
        const ord = std.mem.order(u8, a.names[i], b.names[i]);
        if (ord != .eq) return ord == .lt;
    }
    return a.names.len < b.names.len;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "why records a direct dependency and keeps walking past it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();

    // Target is BOTH a direct dep and a dep of another direct dep, which is
    // the case that distinguishes "record and continue" from "record and
    // return" — the latter would print one path where Pkg prints two.
    try td.dir.writeFile(testing.io, .{ .sub_path = "Project.toml", .data =
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\Target = "00000000-0000-0000-0000-0000000000ff"
        \\
    });
    try td.dir.writeFile(testing.io, .{ .sub_path = "Manifest.toml", .data =
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\deps = ["Target"]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\[[deps.Target]]
        \\uuid = "00000000-0000-0000-0000-0000000000ff"
        \\version = "2.0.0"
        \\
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];
    const paths = try run(g, testing.io, .{
        .project_file = try std.fs.path.join(g, &.{ base, "Project.toml" }),
        .manifest_file = try std.fs.path.join(g, &.{ base, "Manifest.toml" }),
    }, "Target");

    try testing.expectEqual(@as(usize, 2), paths.len);
    // Sorted lexicographically by name vector: ["Alpha","Target"] first.
    try testing.expectEqualStrings("Alpha", paths[0].names[0]);
    try testing.expectEqualStrings("Target", paths[0].names[1]);
    try testing.expectEqual(@as(usize, 1), paths[1].names.len);
    try testing.expectEqualStrings("Target", paths[1].names[0]);
}
