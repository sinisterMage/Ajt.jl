//! Dumps `julia/string_hash.zig`'s output for `string_hash.sh` to diff against
//! `Base.hash(::String, ::UInt)`. Not part of the `ajt` binary: this is a
//! harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/string_hash_dump.zig -Majt=src/root.zig \
//!     -- <corpus-file>
//!
//! The corpus is one **hex-encoded** string per line. Hex rather than raw text
//! because the interesting cases are precisely the ones a line-oriented text
//! format cannot carry: an embedded NUL, a newline, and byte sequences that are
//! not valid UTF-8 at all. Julia's `String` holds arbitrary bytes and `hash`
//! runs over `sizeof(s)` of them, so those are in scope for the port, not
//! edge-case theatre.
//!
//! The **empty string is written `-`**, not as an empty line. Hex cannot encode
//! it — an empty line is indistinguishable from a blank one, and both sides
//! skip blanks — so `hash("")`, the one landmark value anybody would check by
//! hand, was the single input the corpus silently omitted. The gate's own
//! capable-of-failing assertion caught that; the sentinel is the fix.
//!
//! Output, one record per corpus line, in corpus order:
//!
//!   <hex> <hash(s,0)> <hash(s,1)> <hash(s,typemax(UInt))> <clone-dir-name>
//!
//! Three seeds because the seed enters twice — once added into `h` before the
//! call and once truncated to `UInt32` as Murmur's own seed — so a port that
//! got the truncation wrong would still agree on `h = 0`, which is the only
//! seed `add_repo_cache_path` ever uses. The fifth column is
//! `string(hash(url))`, the actual directory name, so the gate can compare
//! against `Pkg.Types.add_repo_cache_path` rather than only against `hash`.

const std = @import("std");
const ajt = @import("ajt");

const string_hash = ajt.julia.string_hash;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: string_hash_dump <corpus-file>\n");
        try out.flush();
        return error.MissingArgument;
    }

    const src = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 << 20));

    var lines = std.mem.splitScalar(u8, src, '\n');
    var buf: [20]u8 = undefined;
    while (lines.next()) |line| {
        const hex = std.mem.trim(u8, line, " \t\r");
        if (hex.len == 0) continue;

        const bytes = if (std.mem.eql(u8, hex, "-")) &[_]u8{} else blk: {
            if (hex.len % 2 != 0) return error.OddLengthHex;
            const b = try arena.alloc(u8, hex.len / 2);
            _ = try std.fmt.hexToBytes(b, hex);
            break :blk b;
        };

        const h0 = string_hash.hash(bytes, 0);
        try out.print("{s} {d} {d} {d} {s}\n", .{
            hex,
            h0,
            string_hash.hash(bytes, 1),
            string_hash.hash(bytes, std.math.maxInt(u64)),
            string_hash.decimal(h0, &buf),
        });
    }
    try out.flush();
}
