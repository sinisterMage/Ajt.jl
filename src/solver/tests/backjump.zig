//! Backjumping: the classic PubGrub motivating example.
//!
//! The old DFS resolver picked the highest-ranked candidate and gave up
//! the first time that choice produced a dead-end. The paper-faithful
//! solver must abandon that decision, jump back past it, and try the
//! next-best version.
const std = @import("std");
const solver = @import("../solver.zig");
const shared = @import("linear.zig");

test "backjump: highest version is unsatisfiable, resolver falls back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // root -> foo ^1
    // foo 2.0.0 -> bar ^2   (but bar has no 2.x versions)
    // foo 1.0.0 -> bar ^1   (bar 1.0.0 exists)
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{.{ "foo", "^1.0.0" }} },
        .{ .name = "foo", .version = "2.0.0", .deps = &.{.{ "bar", "^2.0.0" }} },
        .{ .name = "foo", .version = "1.0.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "bar", .version = "1.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    // Must settle on foo 1.0.0 (since foo 2.0.0 is unreachable) and bar 1.0.0.
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, "foo")) {
            try std.testing.expectEqual(@as(u64, 1), n.version.number().major);
        }
        if (std.mem.eql(u8, n.name, "bar")) {
            try std.testing.expectEqual(@as(u64, 1), n.version.number().major);
        }
    }
}

test "backjump: multiple dead-end candidates before a viable one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same idea but with three foo versions where the top two are dead.
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{.{ "foo", "^1.0.0" }} },
        .{ .name = "foo", .version = "1.3.0", .deps = &.{.{ "bar", "^9.0.0" }} },
        .{ .name = "foo", .version = "1.2.0", .deps = &.{.{ "bar", "^8.0.0" }} },
        .{ .name = "foo", .version = "1.1.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "bar", .version = "1.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, "foo")) {
            try std.testing.expectEqual(@as(u64, 1), n.version.number().minor);
        }
    }
}
