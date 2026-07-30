//! Dumps `cache/jicache.zig`'s view of a list of `.ji` files for
//! `jicache.sh` to diff against `Base.parse_cache_header`. Not part of the
//! `ajt` binary: this is a harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/jicache_dump.zig -Majt=src/root.zig \
//!     -- <list-file> <depot1:depot2:...> [mode] [uname arch version branch commit]
//!
//! `<list-file>` holds one absolute `.ji` path per line. Both sides read the
//! SAME list so the two dumps can never disagree merely about which files they
//! looked at.
//!
//! `mode` selects the output:
//!
//!   * `dump` (default) — one tab-separated record per field, in file order,
//!     matching `jicache_oracle.jl` byte for byte. Empty package names print as
//!     `-`, as does an absent UUID; neither can collide with a real value.
//!   * `flags` — the 256x256 `matchCacheFlags` truth table, for the ccall
//!     comparison. Ignores the list file.
//!   * `verify` — run the L1 verifier over each file and print its verdict, so
//!     the gate can hold it against `Base.stale_cachefile`. This mode needs the
//!     five identity strings (`Sys.KERNEL`, `Sys.ARCH`, `Base.VERSION`,
//!     `Base.GIT_VERSION_INFO.branch/.commit`) as trailing arguments, because
//!     `VerifyOptions.expect` has no default — an unsupplied expectation would
//!     silently accept a `.ji` from someone else's julia.
//!
//! The `.ji` is read whole because `srctextpos` is an absolute offset into it
//! and the crc32c trailer covers all of it; the largest in a real depot is
//! ~3 MB.

const std = @import("std");
const ajt = @import("ajt");
const ji = ajt.cache.jicache;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_ji_bytes = 256 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [1024 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll("usage: jicache_dump <list-file> <depots> [dump|flags|verify] " ++
            "[uname arch version branch commit]\n");
        return error.MissingArgument;
    }

    const mode = if (args.len > 3) args[3] else "dump";
    if (std.mem.eql(u8, mode, "flags")) return dumpFlagTable(out);

    const verify_mode = std.mem.eql(u8, mode, "verify");
    var expect: ?ji.PreambleExpectation = null;
    if (args.len >= 9) {
        expect = .{
            .build_uname = args[4],
            .build_arch = args[5],
            .julia_version = args[6],
            .git_branch = args[7],
            .git_commit = args[8],
        };
    } else if (verify_mode) {
        try out.writeAll("verify mode needs: <uname> <arch> <version> <branch> <commit>\n");
        return error.MissingArgument;
    }

    const list = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(16 << 20));
    const depots = try splitDepots(arena, if (args.len > 2) args[2] else "");

    var it = std.mem.tokenizeScalar(u8, list, '\n');
    while (it.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        try dumpOne(io, out, path, depots, if (verify_mode) expect.? else null);
    }
}

fn splitDepots(arena: Allocator, spec: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    while (it.next()) |d| try out.append(arena, d);
    return out.toOwnedSlice(arena);
}

fn dumpOne(
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    depots: []const []const u8,
    /// Non-null selects `verify` mode.
    expect: ?ji.PreambleExpectation,
) !void {
    // One arena per file, backed by the page allocator rather than by the
    // process arena: a whole depot is ~600 MB of `.ji`, and an arena nested in
    // an arena cannot give any of it back.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try out.print("=== {s}\n", .{path});

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_ji_bytes)) catch |err| {
        try out.print("error\tread\t{s}\n", .{@errorName(err)});
        return;
    };

    var hdr = ji.parse(arena, bytes) catch |err| {
        try out.print("error\tparse\t{s}\n", .{@errorName(err)});
        return;
    };

    const p = hdr.preamble;
    try out.print("pre\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{x:0>16}\t{d}\t{d}\t{d}\n", .{
        p.format_version, p.pointer_size, p.build_uname, p.build_arch,
        p.julia_version,  p.git_branch,   p.git_commit,  p.pkgimage,
        p.checksum,       p.data_start,   p.data_end,    p.header_offset,
    });
    try out.print("flags\t{d}\n", .{hdr.flags});

    for (hdr.modules) |m| {
        try out.print("mod\t{s}\t{x:0>32}\t{s}\n", .{
            try idText(arena, m.id.uuid), m.build_id, nameText(m.id.name),
        });
    }
    if (hdr.modules.len != 0) {
        try out.print("buildid\t{x:0>32}\n", .{hdr.fullBuildId(hdr.modules[0])});
    }

    for (hdr.includes) |inc| {
        try out.print("inc\t{s}\t{s}\t{d}\t{d}\t{x:0>16}\t{s}\t{s}\t{s}\n", .{
            try idText(arena, inc.id.uuid),
            nameText(inc.id.name),
            inc.fsize,
            inc.hash,
            @as(u64, @bitCast(inc.mtime)),
            if (inc.is_srcfile) "src" else "dep",
            try joinModpath(arena, inc.modpath),
            inc.filename,
        });
    }

    for (hdr.requires) |r| {
        try out.print("req\t{s}\t{s}\t{s}\t{s}\n", .{
            try idText(arena, r.from.uuid), nameText(r.from.name),
            try idText(arena, r.to.uuid),   nameText(r.to.name),
        });
    }

    for (hdr.prefs) |pref| try out.print("pref\t{s}\n", .{pref});
    try out.print("prefshash\t{x:0>16}\n", .{hdr.prefs_hash});
    try out.print("srctextpos\t{d}\n", .{hdr.srctextpos});

    for (hdr.required_modules) |m| {
        try out.print("rmod\t{s}\t{x:0>32}\t{s}\n", .{
            try idText(arena, m.id.uuid), m.build_id, nameText(m.id.name),
        });
    }

    try out.print("clone\t{d}\t{x:0>8}\n", .{
        hdr.clone_targets.len, ji.Crc32c.hash(hdr.clone_targets),
    });
    // An EMPTY blob is not "zero targets": `parse_image_targets` reads its
    // count unconditionally and EOFs. Julia never hits it because every caller
    // is guarded by `pkgimage = !isempty(clone_targets)` (loading.jl:4001), and
    // a `.ji` built with `--pkgimages=no` carries none at all.
    if (hdr.isPkgimage()) {
        if (ji.parseImageTargets(arena, hdr.clone_targets)) |targets| {
            for (targets) |t| {
                try out.print("ctarget\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{
                    t.flags, t.features_en.len, t.features_dis.len, t.ext_features, t.name,
                });
            }
        } else |err| {
            try out.print("error\tclone_targets\t{s}\n", .{@errorName(err)});
        }
    }

    // srctext_files is already sorted by `parse`.
    for (hdr.srctext_files) |s| try out.print("srcfile\t{s}\n", .{s});

    // Publish-side verdicts, computed BEFORE restoration (which is what
    // `Base.isrelocatable` does: it reads `_parse_cache_header`).
    try out.print("reloc\t{d}\n", .{@intFromBool(ji.isRelocatable(&hdr))});
    try out.print("mtimetracked\t{d}\n", .{ji.mtimeTrackedCount(&hdr)});

    // isvalid_file_crc.
    const crc_ok = bytes.len >= 4 and
        ji.Crc32c.hash(bytes[0 .. bytes.len - 4]) ==
            std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
    try out.print("filecrc\t{d}\n", .{@intFromBool(crc_ok)});

    if (expect) |e| {
        const so = try ocachefileFromCachefile(arena, path);
        const rejection = ji.verify(arena, io, bytes, &hdr, .{
            .depot_path = depots,
            .expect = e,
            .ocachefile = so,
        }) catch |err| {
            try out.print("error\tverify\t{s}\n", .{@errorName(err)});
            return;
        };
        if (rejection) |r| {
            try out.print("verdict\tstale\t{s}\t{s}\n", .{ r.reason.text(), r.detail });
        } else {
            try out.print("verdict\tfresh\t-\t-\n", .{});
        }
    } else {
        // The restored filenames, i.e. what the PUBLIC parse_cache_header
        // returns. Run after every raw field has been printed.
        try ji.restoreDepots(arena, io, &hdr, depots);
        for (hdr.includes) |inc| try out.print("rinc\t{s}\n", .{inc.filename});
    }
}

/// `ocachefile_from_cachefile(cachefile)`: the same path with a `.so` suffix.
fn ocachefileFromCachefile(arena: Allocator, path: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, path, ".ji")) path[0 .. path.len - 3] else path;
    return std.mem.concat(arena, u8, &.{ stem, ".so" });
}

fn idText(arena: Allocator, u: ?ji.Uuid) ![]const u8 {
    return if (u) |v| try ji.uuidText(arena, v) else "-";
}

fn nameText(name: []const u8) []const u8 {
    return if (name.len == 0) "-" else name;
}

fn joinModpath(arena: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "-";
    return std.mem.join(arena, ",", parts);
}

/// The whole `jl_match_cache_flags` domain, one line per pair. Compared against
/// the ccall'd values; 65536 lines is nothing and sampling would miss exactly
/// the asymmetric `>=` cases that make the function interesting.
fn dumpFlagTable(out: *Io.Writer) !void {
    var r: u16 = 0;
    while (r < 256) : (r += 1) {
        var a: u16 = 0;
        while (a < 256) : (a += 1) {
            try out.print("{d} {d} {d}\n", .{
                r, a, @intFromBool(ji.matchCacheFlags(@intCast(r), @intCast(a))),
            });
        }
    }
}
