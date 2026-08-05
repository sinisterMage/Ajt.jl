//! Dumps `julia/shell.zig`'s answers for `shell_escape.sh` to diff against
//! `Base`. Not part of the `ajt` binary: this is a harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/shell_escape_dump.zig \
//!     -Majt=src/root.zig -- <corpus-file>
//!
//! The corpus file holds one HEX-encoded input per line, and the output is
//! `<hex of shell_escape>\t<hex of shell_escape_wincmd>` per line, with `-`
//! for a wincmd input that raises (NUL/CR/LF).
//!
//! Hex on both sides, deliberately: the corpus exists to carry quotes,
//! backslashes, `$`, `%`, `!` and non-ASCII whitespace, and any shell-level
//! quoting on the way through would be testing the harness rather than the
//! port. The comparison is then a plain `diff` over two files of hex digits.

const std = @import("std");
const ajt = @import("ajt");
const shell = ajt.julia.shell;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: shell_escape_dump <corpus-file>\n");
        try out.flush();
        return error.MissingArgument;
    }

    const src = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(4 << 20));

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const hex = std.mem.trim(u8, raw, " \r\t");
        if (hex.len == 0) continue;

        // `.` is the wire spelling of the EMPTY input: its hex is the empty
        // string, which would be a blank line the loop above skips -- silently
        // dropping the one case that exercises `shell_escape`'s first branch.
        const input = if (std.mem.eql(u8, hex, ".")) "" else blk: {
            const buf = try arena.alloc(u8, hex.len / 2);
            _ = try std.fmt.hexToBytes(buf, hex);
            break :blk buf;
        };

        const posix = try shell.escape(arena, input);
        try writeHex(out, posix);
        try out.writeByte('\t');

        if (shell.escapeWincmd(arena, input)) |win| {
            try writeHex(out, win);
        } else |_| {
            try out.writeAll("-");
        }
        try out.writeByte('\n');
    }
    try out.flush();
}

fn writeHex(out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| try out.print("{x:0>2}", .{b});
}
