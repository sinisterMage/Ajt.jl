//! Minimal logging seam for the vendored solver.
//!
//! Baker's `util/log.zig` uses `std.Thread.Mutex` and `std.fs.File.stderr()`,
//! both of which moved in Zig 0.16 (`std.Io.Mutex`, `std.Io.File`). Rather
//! than port a logger Ajt does not otherwise need, this provides the same
//! call surface over `std.debug.print`, which is already unbuffered and
//! serialised.
//!
//! The solver only emits at debug/warn level and never depends on output, so
//! this is a behavioural no-op for resolution. Replace it if Ajt grows a real
//! logging story.

const std = @import("std");

pub const Level = enum { debug, info, warn, err };

var current_level: Level = .warn;

pub fn setLevel(level: Level) void {
    current_level = level;
}

pub fn levelEnabled(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(current_level);
}

pub fn emit(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!levelEnabled(level)) return;
    std.debug.print(fmt ++ "\n", args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    emit(.debug, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}
