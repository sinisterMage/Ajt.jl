//! Dumps `git/url.zig`'s classification for `git_url.sh` to diff against Pkg.
//! Not part of the `ajt` binary: this is a harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/git_url_dump.zig -Majt=src/root.zig \
//!     -- <corpus-file>
//!
//! The corpus is one hex-encoded string per line, `-` for the empty string —
//! the same encoding `string_hash_dump.zig` uses, and for the same reason: the
//! inputs worth testing include ones a line-oriented text format cannot carry.
//!
//! Output, one record per corpus line, in corpus order:
//!
//!   <hex> <isurl:0|1> <kind> <normalized-hex>
//!
//! `isurl` is the column with a Julia oracle (`Pkg.isurl`). `kind` and
//! `normalized` have none — `classify` answers a question Pkg never asks as
//! one question, and `normalize` is only `GitTools.normalize_url`'s default
//! branch — so the gate treats them as invariants to check against `isurl`
//! rather than as values to diff.

const std = @import("std");
const ajt = @import("ajt");

const url_mod = ajt.git.url;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: git_url_dump <corpus-file>\n");
        try out.flush();
        return error.MissingArgument;
    }

    const src = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 << 20));

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const hex = std.mem.trim(u8, line, " \t\r");
        if (hex.len == 0) continue;

        const bytes = if (std.mem.eql(u8, hex, "-")) &[_]u8{} else blk: {
            if (hex.len % 2 != 0) return error.OddLengthHex;
            const b = try arena.alloc(u8, hex.len / 2);
            _ = try std.fmt.hexToBytes(b, hex);
            break :blk b;
        };

        const norm = url_mod.normalize(bytes);
        const norm_hex = try arena.alloc(u8, norm.len * 2);
        _ = std.fmt.bufPrint(norm_hex, "{x}", .{norm}) catch unreachable;

        try out.print("{s} {d} {s} {s}\n", .{
            hex,
            @intFromBool(url_mod.isUrl(bytes)),
            @tagName(url_mod.classify(bytes)),
            if (norm.len == 0) "-" else norm_hex,
        });
    }
    try out.flush();
}
