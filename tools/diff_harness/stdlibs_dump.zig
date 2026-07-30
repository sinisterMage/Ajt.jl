//! Dumps `julia/stdlibs.zig`'s enumeration for `stdlibs.sh` to diff against
//! Julia. Not part of the `ajt` binary: this is a harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/stdlibs_dump.zig -Majt=src/root.zig \
//!     -- <julia-prefix> [julia-version]
//!
//! Output starts with two header lines --
//!
//!   dir <the vX.Y directory that was read>
//!   names <comma-separated upgradable_names>
//!
//! so the gate can confirm both sides looked at the same installation and hold
//! the compiled-in `UPGRADABLE_STDLIBS` list against Julia's, rather than
//! trusting two hardcoded names. Then one entry per line, sorted by name:
//!
//!   <kind> <name> <uuid> <version|-> <ndeps> <nweakdeps>
//!
//! where <kind> is `stdlib` for the resolver-fixed set (Julia's `stdlibs()`)
//! and `upgradable` for `UPGRADABLE_STDLIBS`. Keeping the two in one stream
//! with a distinguishing column is deliberate -- it lets the gate catch an
//! entry that moved between the groups, which a per-group diff would show as
//! an unrelated add plus an unrelated delete.

const std = @import("std");
const ajt = @import("ajt");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: stdlibs_dump <julia-prefix> [julia-version]\n");
        try out.flush();
        return error.MissingArgument;
    }

    const set = try ajt.julia.stdlibs.load(arena, io, .{
        .julia_prefix = args[1],
        .julia_version = if (args.len > 2) args[2] else null,
    });

    try out.print("dir {s}\n", .{set.dir});
    try out.writeAll("names ");
    for (ajt.julia.stdlibs.upgradable_names, 0..) |n, i| {
        if (i != 0) try out.writeAll(",");
        try out.writeAll(n);
    }
    try out.writeAll("\n");

    for (set.fixed) |e| try emit(out, "stdlib", e);
    for (set.upgradable) |e| try emit(out, "upgradable", e);
    try out.flush();
}

fn emit(out: *std.Io.Writer, kind: []const u8, e: ajt.julia.stdlibs.Stdlib) !void {
    try out.print("{s} {s} {s} ", .{ kind, e.name, e.uuid_text });
    if (e.version) |v| try v.format(out) else try out.writeAll("-");
    try out.print(" {d} {d}\n", .{ e.deps.len, e.weakdeps.len });
}
