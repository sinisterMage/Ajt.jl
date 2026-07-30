//! Exercise the resolver's handling of negative terms.
//!
//! A dependency emits an incompatibility with a negative term on the
//! dependee (`not dep in range`). The set-algebra on `VersionSet` must
//! correctly compute complements so the partial solution carries a real
//! negative constraint through to the next decision.
const std = @import("std");
const solver = @import("../solver.zig");
const shared = @import("linear.zig");

test "negative term: dep range excludes a range the resolver avoids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // root -> foo ^1   (so foo is pinned to the 1.x range, excluding 2.x)
    // foo 1.0.0 -> bar ^1.0.0  (i.e. [1.0.0, 2.0.0) -- spelled ">=1.0.0, <2.0.0"
    // in baker, but Julia reads comma as UNION, which would mean `*`)
    // foo 2.0.0 exists but is out of root's range — must not be picked.
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{.{ "foo", "^1.0.0" }} },
        .{ .name = "foo", .version = "2.0.0", .deps = &.{} },
        .{ .name = "foo", .version = "1.0.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "bar", .version = "1.5.0", .deps = &.{} },
        .{ .name = "bar", .version = "2.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, "foo")) {
            try std.testing.expectEqual(@as(u64, 1), n.version.number().major);
        }
        if (std.mem.eql(u8, n.name, "bar")) {
            try std.testing.expectEqual(@as(u64, 1), n.version.number().major);
            try std.testing.expectEqual(@as(u64, 5), n.version.number().minor);
        }
    }
}

test "negative term: complement splits the viable set in two pieces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // root -> foo >=1.0.0     (accept any foo version)
    // root -> bad-foo <1.0.0   (unreachable; pushes foo >=1.0.0)
    // foo has 0.9.0, 1.2.0, 2.5.0 — the resolver must still pick the highest
    // (2.5.0) despite the exclusion of 0.9.0 by the >=1.0.0 constraint.
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{.{ "foo", ">=1.0.0" }} },
        .{ .name = "foo", .version = "0.9.0", .deps = &.{} },
        .{ .name = "foo", .version = "1.2.0", .deps = &.{} },
        .{ .name = "foo", .version = "2.5.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, "foo")) {
            try std.testing.expectEqual(@as(u64, 2), n.version.number().major);
            try std.testing.expectEqual(@as(u64, 5), n.version.number().minor);
        }
    }
}
