//! Dumps `cache/key.zig`'s derivation keys for `cache_key.sh`. Not part of the
//! `ajt` binary: this is a harness fixture, run with
//!
//!   zig run --dep ajt -Mroot=tools/diff_harness/cache_key_dump.zig -Majt=src/root.zig \
//!     -- <manifest.toml> --sysimage <64hex> --cacheflags <u8> --cpu-target <str> [...]
//!
//! Options:
//!   --julia-prefix <p> [--julia-version <v>]   enumerate the real stdlibs, so
//!                                              sysimage packages are skipped
//!   --local <uuid>=<40hex>:<path>              content for a `path` entry
//!   --prefs <uuid>=<decimal u64>               that package's prefs_hash
//!   --preimage <uuid>                          also dump that key's preimage
//!   --raw <uuid>=<40hex>:<path>                key ONE synthetic local package
//!                                              with no deps, and print nothing
//!                                              else. The manifest is not read.
//!
//! Output, one record per line, in manifest order:
//!
//!   params <sysimage-hex> <cacheflags> <cpu_target>
//!   count <keyed> <skipped>
//!   skip <uuid>
//!   key <name> <uuid> <64hex>
//!   preimage <uuid> <hex>          (only with --preimage)
//!   raw <64hex>                    (only with --raw, and the only line)
//!
//! The `params` echo exists so the gate can prove both sides of a comparison
//! were handed the same environment inputs; a gate that silently compared two
//! runs with different sysimage hashes would report a spurious pass on
//! requirement 3 and a spurious failure everywhere else.

const std = @import("std");
const ajt = @import("ajt");

const key_mod = ajt.cache.key;
const Uuid = ajt.julia.Uuid;
const Sha1 = ajt.julia.Sha1;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll("usage: cache_key_dump <manifest.toml> --sysimage <64hex> ...\n");
        try out.flush();
        return error.MissingArgument;
    }

    var manifest_path: ?[]const u8 = null;
    var sysimage_hex: []const u8 = "";
    var cacheflags: u8 = 0;
    var cpu_target: []const u8 = "native";
    var julia_prefix: ?[]const u8 = null;
    var julia_version: ?[]const u8 = null;
    var preimage_of: ?Uuid = null;
    var raw: ?key_mod.LocalEntry = null;

    var locals: std.ArrayList(key_mod.LocalEntry) = .empty;
    var prefs: std.ArrayList(key_mod.PrefsHash) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--sysimage")) {
            i += 1;
            sysimage_hex = args[i];
        } else if (std.mem.eql(u8, a, "--cacheflags")) {
            i += 1;
            cacheflags = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, a, "--cpu-target")) {
            i += 1;
            cpu_target = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--preimage")) {
            i += 1;
            preimage_of = try Uuid.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--local") or std.mem.eql(u8, a, "--raw")) {
            i += 1;
            // <uuid>=<40hex>:<path> — both prefixes are fixed width, so a path
            // containing ':' or '=' still parses.
            const spec = args[i];
            if (spec.len < 36 + 1 + 40 + 1 or spec[36] != '=' or spec[36 + 1 + 40] != ':')
                return error.BadLocalSpec;
            const entry: key_mod.LocalEntry = .{
                .uuid = try Uuid.parse(spec[0..36]),
                .content = .{
                    .tree = try Sha1.parse(spec[37..77]),
                    .path = spec[78..],
                },
            };
            if (std.mem.eql(u8, a, "--raw")) raw = entry else try locals.append(arena, entry);
        } else if (std.mem.eql(u8, a, "--prefs")) {
            i += 1;
            const spec = args[i];
            if (spec.len < 38 or spec[36] != '=') return error.BadPrefsSpec;
            try prefs.append(arena, .{
                .uuid = try Uuid.parse(spec[0..36]),
                .hash = try std.fmt.parseInt(u64, spec[37..], 10),
            });
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownArgument;
        } else {
            manifest_path = a;
        }
    }

    if (sysimage_hex.len != 64) return error.BadSysimageHex;

    var params: key_mod.Params = .{
        .sysimage = undefined,
        .cacheflags = cacheflags,
        .cpu_target = cpu_target,
    };
    _ = try std.fmt.hexToBytes(&params.sysimage, sysimage_hex);

    // One synthetic package, no deps, no manifest: the collision probe needs an
    // input whose key cannot move for any reason other than the field being
    // probed. Keying a real manifest entry instead would let a change in
    // `cpu_target` reach it through its DEPENDENCIES' keys, which silently
    // turns a collision probe into a tautology.
    if (raw) |r| {
        const k = try key_mod.compute(arena, params, r.uuid, .{ .local = r.content }, 0, &.{});
        try out.print("raw {s}\n", .{&key_mod.toHex(k)});
        try out.flush();
        return;
    }

    const path = manifest_path orelse return error.MissingArgument;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    const manifest = try ajt.model.manifest.parse(arena, src, null);

    var stdlib_set: ?ajt.julia.stdlibs.Set = null;
    if (julia_prefix) |p| {
        stdlib_set = try ajt.julia.stdlibs.load(arena, io, .{
            .julia_prefix = p,
            .julia_version = julia_version,
        });
    }

    const opts: key_mod.Options = .{
        .params = params,
        .stdlibs = if (stdlib_set) |*s| s else null,
        .prefs = prefs.items,
        .local = locals.items,
    };

    const keys = try key_mod.computeManifest(arena, &manifest, opts);

    try out.print("params {s} {d} {s}\n", .{ sysimage_hex, cacheflags, cpu_target });
    try out.print("count {d} {d}\n", .{ keys.entries.len, keys.skipped.len });

    var uuid_buf: [36]u8 = undefined;
    for (keys.skipped) |u| {
        try out.print("skip {s}\n", .{ajt.model.manifest.formatUuid(u, &uuid_buf)});
    }
    for (keys.entries) |e| {
        try out.print("key {s} {s} {s}\n", .{
            e.name,
            ajt.model.manifest.formatUuid(e.uuid, &uuid_buf),
            &key_mod.toHex(e.key),
        });
    }

    // The preimage is dumped for exactly one package so the gate can assert the
    // documented FIELD ORDER against byte offsets it computed itself, rather
    // than inferring order from a digest.
    if (preimage_of) |want| {
        const entry = manifest.findByUuid(want) orelse return error.NoSuchPackage;
        var dep_keys: std.ArrayList(key_mod.Key) = .empty;
        for (entry.deps) |d| {
            if (stdlib_set) |s| if (s.isStdlib(d.uuid)) continue;
            try dep_keys.append(arena, keys.get(d.uuid) orelse return error.UnknownDependency);
        }
        var content: key_mod.Content = undefined;
        if (entry.tree_hash) |t| {
            content = .{ .tree = t };
        } else {
            content = .{ .local = for (locals.items) |l| {
                if (std.mem.eql(u8, &l.uuid.bytes, &entry.uuid.bytes)) break l.content;
            } else return error.NotContentAddressed };
        }
        var prefs_hash: u64 = 0;
        for (prefs.items) |p| {
            if (std.mem.eql(u8, &p.uuid.bytes, &entry.uuid.bytes)) prefs_hash = p.hash;
        }
        const pre = try key_mod.encode(arena, params, entry.uuid, content, prefs_hash, dep_keys.items);
        try out.print("preimage {s} {x}\n", .{ ajt.model.manifest.formatUuid(want, &uuid_buf), pre });
    }

    try out.flush();
}
