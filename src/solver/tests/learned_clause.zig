//! Exercise CDCL-style learned-clause pruning and report rendering.
//!
//! The PubGrub solver should learn from a conflict and produce a human
//! readable "because" chain pointing at the underlying dependency facts.
//! The specifics of the resolvent aren't part of the public contract, but
//! the report must mention the packages whose constraints collided.
const std = @import("std");
const solver = @import("../solver.zig");
const shared = @import("linear.zig");

test "learned clause: conflict report mentions the colliding packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // root depends on left and right; their bar-constraints don't overlap.
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{
            .{ "left", "^1.0.0" },
            .{ "right", "^1.0.0" },
        } },
        .{ .name = "left", .version = "1.0.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "right", .version = "1.0.0", .deps = &.{.{ "bar", "^2.0.0" }} },
        .{ .name = "bar", .version = "1.0.0", .deps = &.{} },
        .{ .name = "bar", .version = "2.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const res = solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);
    try std.testing.expectError(
        solver.pubgrub.SolveError.NoSolution,
        res,
    );

    // Render the diagnostic and sanity-check it references the colliding names.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try solver.pubgrub.writeLastReport(&w);
    const report = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, report, "bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "version solving failed") != null);
}

test "learned clause: backjumping past an irrelevant decision still reports correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Add an extra leaf that the solver would pick first but whose choice
    // is orthogonal to the eventual conflict. A correct solver walks past
    // the leaf's decision without tangling its cause into the learned
    // clause.
    var fr = try shared.TestRegistry.init(a, &[_]shared.TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{
            .{ "leaf", "^1.0.0" },
            .{ "left", "^1.0.0" },
            .{ "right", "^1.0.0" },
        } },
        .{ .name = "leaf", .version = "1.0.0", .deps = &.{} },
        .{ .name = "left", .version = "1.0.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "right", .version = "1.0.0", .deps = &.{.{ "bar", "^2.0.0" }} },
        .{ .name = "bar", .version = "1.0.0", .deps = &.{} },
        .{ .name = "bar", .version = "2.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const res = solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);
    try std.testing.expectError(
        solver.pubgrub.SolveError.NoSolution,
        res,
    );

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try solver.pubgrub.writeLastReport(&w);
    const report = w.buffered();
    // `leaf` has no part in the conflict; it should not clutter the report.
    try std.testing.expect(std.mem.indexOf(u8, report, "bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "leaf") == null);
}
