const std = @import("std");
const solver = @import("../solver.zig");
const shared = @import("linear.zig");

test "diamond dependency converges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{
            .{ "a", "^1.0.0" },
            .{ "b", "^1.0.0" },
        } },
        .{ .name = "a", .version = "1.0.0", .deps = &.{.{ "c", "^1.2.0" }} },
        .{ .name = "b", .version = "1.0.0", .deps = &.{.{ "c", "^1.3.0" }} },
        .{ .name = "c", .version = "1.3.5", .deps = &.{} },
        .{ .name = "c", .version = "1.2.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);
    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);

    // c must have been picked as 1.3.5 to satisfy both branches.
    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.name, "c")) {
            try std.testing.expectEqual(@as(u64, 3), n.version.number().minor);
        }
    }
}
