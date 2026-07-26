//! Ajt CLI.
//!
//! A thin shell over the library in src/root.zig -- all real logic lives
//! there, so it can be unit-tested without spawning a process.

const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");

const usage =
    \\ajt — Advanced Julia Tools
    \\
    \\Usage:
    \\  ajt fmt [options] <file.toml>...   Normalise TOML the way Julia's TOML.print does
    \\  ajt tree-hash <dir>...             git tree hash of a directory (what
    \\                                     git-tree-sha1 in a registry pins)
    \\  ajt project-hash <Project.toml>    The hash Pkg records in a Manifest
    \\  ajt host-platform --julia-prefix P --julia-version V
    \\                                     The host tag set Julia would report
    \\  ajt select-artifact --host <tags> <Artifacts.toml>...
    \\                                     Which artifact variant a host selects
    \\  ajt registry status                Summarise the installed General registry
    \\  ajt registry show <package>        Versions + uncompressed deps of a package
    \\  ajt version                        Print the version
    \\  ajt help                           This message
    \\
    \\registry options:
    \\  --depot PATH        Depot to read from (default: $JULIA_DEPOT_PATH's first
    \\                      entry, else ~/.julia)
    \\  --registry NAME     Registry name (default: General)
    \\
    \\fmt options:
    \\  --sorted            Sort keys (what Pkg uses when writing manifests)
    \\  --respect-inline    Keep `{k = v}` tables inline instead of expanding them
    \\                      to [headers]. Off by default so output matches
    \\                      TOML.print(TOML.parsefile(f)), which loses inlineness.
    \\  --filelist FILE     Read input paths from FILE, one per line
    \\  --outdir DIR        Write each input's output to DIR/<n>.out (1-based, in
    \\                      input order) instead of concatenating to stdout.
    \\                      Together these format a whole corpus in one process,
    \\                      which is the difference between the differential gate
    \\                      taking seconds and taking many minutes.
    \\
;

const version = "0.0.1";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll(usage);
        try out.flush();
        return error.MissingCommand;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try out.print("ajt {s}\n", .{version});
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "fmt")) {
        try cmdFmt(gpa, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "tree-hash")) {
        try cmdTreeHash(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "project-hash")) {
        try cmdProjectHash(gpa, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "host-platform")) {
        try cmdHostPlatform(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "select-artifact")) {
        try cmdSelectArtifact(gpa, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "registry")) {
        try cmdRegistry(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }

    try out.writeAll(usage);
    try out.flush();
    return error.UnknownCommand;
}

fn cmdFmt(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const []const u8) !void {
    var opts: ajt.toml.EmitOptions = .{};
    var outdir: ?[]const u8 = null;
    var filelist: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--sorted")) {
            opts.sorted = true;
        } else if (std.mem.eql(u8, arg, "--respect-inline")) {
            opts.respect_inline = true;
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            i += 1;
            if (i >= args.len) return missingValue("--outdir");
            outdir = args[i];
        } else if (std.mem.eql(u8, arg, "--filelist")) {
            i += 1;
            if (i >= args.len) return missingValue("--filelist");
            filelist = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("ajt fmt: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        } else {
            try files.append(gpa, arg);
        }
    }

    // A file list is read wholesale and sliced in place; the backing buffer
    // must outlive the loop below, hence the deferred free rather than a
    // scoped one.
    var list_buf: ?[]u8 = null;
    defer if (list_buf) |b| gpa.free(b);
    if (filelist) |lf| {
        const buf = Io.Dir.cwd().readFileAlloc(io, lf, gpa, .limited(256 * 1024 * 1024)) catch |err| {
            std.debug.print("ajt fmt: cannot read file list '{s}': {s}\n", .{ lf, @errorName(err) });
            return err;
        };
        list_buf = buf;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) try files.append(gpa, trimmed);
        }
    }

    if (files.items.len == 0) {
        std.debug.print("ajt fmt: no input files\n", .{});
        return error.MissingArgument;
    }

    var failures: usize = 0;
    for (files.items, 1..) |path, n| {
        const src = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("ajt fmt: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
            if (outdir == null) return err;
            failures += 1;
            continue;
        };
        defer gpa.free(src);

        var diag: ajt.toml.Diagnostic = .{};
        var doc = ajt.toml.parse(gpa, src, &diag) catch |err| {
            std.debug.print("{s}: line {d}, column {d}: {s}\n", .{ path, diag.line, diag.column, diag.message });
            // In batch mode a single bad file must not abort the corpus; the
            // harness needs a result for every entry to report against.
            if (outdir == null) return err;
            failures += 1;
            continue;
        };
        defer doc.deinit();

        if (outdir) |dir| {
            const rendered = try ajt.toml.emit_mod.emitAlloc(gpa, doc.root, opts);
            defer gpa.free(rendered);
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{d}.out", .{n});
            var sub = try Io.Dir.cwd().openDir(io, dir, .{});
            defer sub.close(io);
            try sub.writeFile(io, .{ .sub_path = name, .data = rendered });
        } else {
            try ajt.toml.emit(gpa, out, doc.root, opts);
        }
    }

    if (failures > 0) {
        std.debug.print("ajt fmt: {d} of {d} file(s) failed\n", .{ failures, files.items.len });
        return error.SomeFilesFailed;
    }
}

/// `ajt tree-hash <dir>...` — prints `<sha1>  <dir>` per argument, so it can be
/// diffed directly against Julia's `Pkg.GitTools.tree_hash`.
fn cmdTreeHash(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--filelist")) {
            i += 1;
            if (i >= args.len) return missingValue("--filelist");
            // Read into the PROCESS arena, not gpa: the path slices below
            // borrow from this buffer for the rest of the run, and the arena
            // is exactly the allocator meant for process-lifetime data.
            const buf = try Io.Dir.cwd().readFileAlloc(io, args[i], arena, .limited(64 * 1024 * 1024));
            var it = std.mem.splitScalar(u8, buf, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len != 0) try paths.append(gpa, t);
            }
        } else {
            try paths.append(gpa, args[i]);
        }
    }
    if (paths.items.len == 0) {
        std.debug.print("ajt tree-hash: no directories given\n", .{});
        return error.MissingArgument;
    }

    for (paths.items) |p| {
        // A `.tar` argument is hashed from the STREAM (Tar.tree_hash), which is
        // how a downloaded archive gets verified before anything is written to
        // disk. A directory uses the filesystem walker (GitTools.tree_hash).
        // The two differ on empty-directory handling, so the distinction is
        // not cosmetic.
        if (std.mem.endsWith(u8, p, ".tar")) {
            const bytes = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 30)) catch |err| {
                std.debug.print("ajt tree-hash: {s}: {s}\n", .{ p, @errorName(err) });
                try out.print("ERROR  {s}\n", .{p});
                continue;
            };
            defer gpa.free(bytes);
            const th = try ajt.julia.treehash.hashTar(gpa, bytes, false);
            try out.print("{s}  {s}\n", .{ ajt.julia.treehash.toHex(th), p });
            continue;
        }
        const h = ajt.julia.treehash.hashPath(gpa, io, p) catch |err| {
            std.debug.print("ajt tree-hash: {s}: {s}\n", .{ p, @errorName(err) });
            try out.print("ERROR  {s}\n", .{p});
            continue;
        };
        try out.print("{s}  {s}\n", .{ ajt.julia.treehash.toHex(h), p });
    }
}

fn cmdProjectHash(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("ajt project-hash: no Project.toml given\n", .{});
        return error.MissingArgument;
    }
    for (args) |path| {
        const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(src);
        var diag: ajt.toml.Diagnostic = .{};
        var doc = ajt.toml.parse(gpa, src, &diag) catch |err| {
            std.debug.print("{s}: line {d}: {s}\n", .{ path, diag.line, diag.message });
            return err;
        };
        defer doc.deinit();
        const h = try ajt.julia.project_hash.compute(gpa, doc.root);
        try out.print("{s}  {s}\n", .{ h, path });
    }
}

/// `ajt registry status|show <pkg>`.
fn cmdRegistry(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depot: ?[]const u8 = null;
    var reg_name: []const u8 = "General";
    var sub: ?[]const u8 = null;
    // Multiple targets per invocation: loading the General registry costs
    // ~1.6s, so a per-package process would make any broad gate impractical.
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            depot = args[i];
        } else if (std.mem.eql(u8, args[i], "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            reg_name = args[i];
        } else if (sub == null) {
            sub = args[i];
        } else {
            try targets.append(gpa, args[i]);
        }
    }

    // A stacked JULIA_DEPOT_PATH writes to its FIRST entry, which is also
    // where registries live; mirror that rather than assuming ~/.julia.
    const resolved_depot = depot orelse blk: {
        if (environ.get("JULIA_DEPOT_PATH")) |v| {
            if (v.len != 0) {
                const first = std.mem.sliceTo(v, ':');
                if (first.len != 0) break :blk first;
            }
        }
        const home = environ.get("HOME") orelse {
            std.debug.print("ajt registry: cannot locate a depot (set --depot)\n", .{});
            return error.MissingArgument;
        };
        // Process-lifetime string -> process arena, not gpa.
        break :blk try std.fmt.allocPrint(arena, "{s}/.julia", .{home});
    };

    var reg = blk: {
        const archive = ajt.registry.tarball.loadFromDepot(gpa, io, resolved_depot, reg_name) catch |err| {
            std.debug.print("ajt registry: cannot load {s} from {s}: {s}\n", .{ reg_name, resolved_depot, @errorName(err) });
            return err;
        };
        break :blk try ajt.registry.open(archive);
    };
    defer reg.deinit();

    const which = sub orelse "status";

    if (std.mem.eql(u8, which, "status")) {
        try out.print("registry  {s}\n", .{reg.name});
        try out.print("uuid      {s}\n", .{reg.uuid});
        try out.print("depot     {s}\n", .{resolved_depot});
        try out.print("packages  {d}\n", .{reg.packages.len});
        try out.print("files     {d}\n", .{reg.archive.count()});
        return;
    }

    if (std.mem.eql(u8, which, "show")) {
        if (targets.items.len == 0) {
            std.debug.print("ajt registry show: no package given\n", .{});
            return error.MissingArgument;
        }
        for (targets.items) |name| {
            const ref = reg.findByName(name) orelse reg.findByUuid(name) orelse {
                try out.print("== {s}\nMISSING {s}\n", .{ name, name });
                continue;
            };
            var pkg = try ajt.registry.loadPackage(gpa, &reg, ref);
            defer pkg.deinit();

            try out.print("== {s}\n", .{pkg.name});
            for (pkg.versions, 0..) |vi, vidx| {
                try out.print("{f}", .{vi.version});
                if (vi.yanked) try out.writeAll("  (yanked)");
                try out.print("  {s}\n", .{vi.tree_hash});
                for (pkg.deps[vidx]) |d| {
                    const spec = try d.compat.toString(gpa);
                    defer gpa.free(spec);
                    try out.print("    {s} {s}\n", .{ d.name, spec });
                }
            }
        }
        return;
    }

    std.debug.print("ajt registry: unknown subcommand '{s}'\n", .{which});
    return error.UnknownCommand;
}

/// `ajt select-artifact --host <k=v,...> <Artifacts.toml>...`
///
/// Prints `<artifact name>  <chosen git-tree-sha1>` per entry. The host tag set
/// is passed in rather than detected, so this exercises matching + selection in
/// isolation; host detection (BUILD_TRIPLET + the libstdcxx probe) is a
/// separate concern with its own failure modes.
fn cmdSelectArtifact(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var host_spec: []const u8 = "";
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host")) {
            i += 1;
            if (i >= args.len) return missingValue("--host");
            host_spec = args[i];
        } else try files.append(gpa, args[i]);
    }
    if (files.items.len == 0) {
        std.debug.print("ajt select-artifact: no Artifacts.toml given\n", .{});
        return error.MissingArgument;
    }

    var host_tags: std.ArrayList(ajt.julia.platform.Tag) = .empty;
    defer host_tags.deinit(gpa);
    var hit = std.mem.splitScalar(u8, host_spec, ',');
    while (hit.next()) |kv| {
        const t = std.mem.trim(u8, kv, " ");
        if (t.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        try host_tags.append(gpa, .{ .key = t[0..eq], .value = t[eq + 1 ..] });
    }
    const host: ajt.julia.platform.Platform = .{ .tags = host_tags.items, .is_host = true };

    for (files.items) |path| {
        const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(src);
        var doc = ajt.toml.parse(gpa, src, null) catch continue;
        defer doc.deinit();
        const arena = doc.allocator();

        for (doc.root.entries.items) |entry| {
            const items = switch (entry.value) {
                .array => |a| a,
                // A non-array entry is a platform-independent artifact.
                .table => {
                    try out.print("{s}  (unplatformed)\n", .{entry.key});
                    continue;
                },
                else => continue,
            };

            var cands: std.ArrayList(ajt.julia.platform.Platform) = .empty;
            defer cands.deinit(gpa);
            var hashes: std.ArrayList([]const u8) = .empty;
            defer hashes.deinit(gpa);

            for (items) |it| {
                const t = switch (it) {
                    .table => |t| t,
                    else => continue,
                };
                // unpack_platform: every String-valued key is a tag, minus
                // os/arch/git-tree-sha1, then os+arch re-added.
                var tags: std.ArrayList(ajt.julia.platform.Tag) = .empty;
                const os = switch (t.get("os") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const arch = switch (t.get("arch") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                try tags.append(arena, .{ .key = "arch", .value = arch });
                try tags.append(arena, .{ .key = "os", .value = os });
                for (t.entries.items) |kv| {
                    const sv = switch (kv.value) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, kv.key, "os") or
                        std.mem.eql(u8, kv.key, "arch") or
                        std.mem.eql(u8, kv.key, "git-tree-sha1")) continue;
                    try tags.append(arena, .{ .key = kv.key, .value = sv });
                }
                const th = switch (t.get("git-tree-sha1") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                try cands.append(gpa, .{ .tags = tags.items });
                try hashes.append(gpa, th);
            }

            if (cands.items.len == 0) continue;
            const pick = try ajt.julia.platform.selectPlatform(gpa, cands.items, host);
            if (pick) |p| {
                try out.print("{s}  {s}\n", .{ entry.key, hashes.items[p] });
            } else {
                try out.print("{s}  NONE\n", .{entry.key});
            }
        }
    }
}

/// `ajt host-platform` — prints the detected host tags as sorted `k=v,k=v`,
/// the same shape `--host` accepts and the same shape the gate compares.
fn cmdHostPlatform(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var prefix: []const u8 = "";
    var jversion: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            prefix = args[i];
        } else if (std.mem.eql(u8, args[i], "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            jversion = args[i];
        }
    }
    if (prefix.len == 0 or jversion.len == 0) {
        std.debug.print("ajt host-platform: --julia-prefix and --julia-version are required\n", .{});
        return error.MissingArgument;
    }

    // Arena: detectHost's allocations all share the Platform's lifetime.
    const host = ajt.julia.platform.detectHost(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = jversion,
    }) catch |err| {
        std.debug.print("ajt host-platform: {s}\n", .{@errorName(err)});
        return err;
    };

    const sorted = try gpa.dupe(ajt.julia.platform.Tag, host.tags);
    defer gpa.free(sorted);
    std.mem.sort(ajt.julia.platform.Tag, sorted, {}, struct {
        fn lt(_: void, a: ajt.julia.platform.Tag, b: ajt.julia.platform.Tag) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    for (sorted, 0..) |t, n| {
        if (n != 0) try out.writeAll(",");
        try out.print("{s}={s}", .{ t.key, t.value });
    }
    try out.writeAll("\n");
}

fn missingValue(opt: []const u8) error{MissingArgument} {
    std.debug.print("ajt fmt: '{s}' requires a value\n", .{opt});
    return error.MissingArgument;
}
