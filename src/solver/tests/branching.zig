const std = @import("std");
const solver = @import("../solver.zig");
const shared = @import("linear.zig");

test "branching dependency resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{
            .{ "left", "^1.0.0" },
            .{ "right", "^1.0.0" },
        } },
        .{ .name = "left", .version = "1.0.0", .deps = &.{.{ "shared", "^1.0.0" }} },
        .{ .name = "right", .version = "1.0.0", .deps = &.{.{ "shared", "^1.0.0" }} },
        .{ .name = "shared", .version = "1.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
}

test "branching with incompatible sub-deps fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{
            .{ "left", "^1.0.0" },
            .{ "right", "^1.0.0" },
        } },
        .{ .name = "left", .version = "1.0.0", .deps = &.{.{ "shared", "^2.0.0" }} },
        .{ .name = "right", .version = "1.0.0", .deps = &.{.{ "shared", "^3.0.0" }} },
        .{ .name = "shared", .version = "2.0.0", .deps = &.{} },
        .{ .name = "shared", .version = "3.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const res = solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);
    try std.testing.expectError(solver.pubgrub.SolveError.NoSolution, res);
}
