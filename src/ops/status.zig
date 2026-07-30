//! `ajt status` — the report `Pkg.status` prints, byte for byte.
//!
//! Port of `API.status` (`API.jl:1405-1415`) over `Operations.status`
//! (`Operations.jl:3021-3066`), `print_status` (`:2783-2986`), `stat_rep`
//! (`:2576-2587`), `diff_array` (`:2697-2721`), `status_compat_info`
//! (`:2612-2694`), `status_ext_info` (`:2731-2769`) and `print_compat`
//! (`:3099-3110`).
//!
//! ### Why this is a printer and not a data structure
//!
//! Every other native verb produces a FILE, and "agrees with Pkg" is decided by
//! comparing bytes on disk. Here the bytes on stdout *are* the product, so this
//! module writes them itself rather than handing a caller a `Report` to render
//! — two renderers is two chances to drift, and `tools/diff_harness/status.sh`
//! compares this writer's output against `Pkg.status(...; io)` for a
//! non-terminal `io`. `why` set the precedent (`ops/why.zig`); status is the
//! same contract with about forty times the formatting.
//!
//! Colour is the reason a non-terminal `io` is the specification rather than a
//! convenience. Pkg emits every marker through `printstyled`, and
//! `printstyled` consults `get(io, :color, false)`: an `IOBuffer` or a
//! redirected stdout gets none, a TTY gets escapes. Ajt never emits escapes, so
//! the two agree exactly where the gate can compare them and Ajt loses only
//! colour in a terminal — the same trade `why` already documents.
//!
//! ### What decides a line
//!
//! `print_status` builds one row per package out of four independent questions,
//! and the answers interact in ways the output makes visible:
//!
//!  * **downloaded** — `is_package_downloaded` (`:2723-2729`): `source_path`
//!    exists as a directory AND `check_artifacts_downloaded` passes. A "no"
//!    prints `→` and, crucially, widens the gutter for EVERY row in the report
//!    (`lpadding = 3`, `:2874-2877`) — but only when the same package also
//!    carries an upgrade marker, so a report can have one-space or two-space
//!    gutters depending on a package that is nowhere near the row you are
//!    reading.
//!  * **upgradable / heldback** — both come from `status_compat_info`, which
//!    consults the REGISTRY. That is why the default `status` is not a
//!    file-only operation: `⌃` and `⌅` need to know the latest registered
//!    version of every package, `--outdated` merely prints the reasoning.
//!  * **extensions** — `status_ext_info` reads the manifest entry's
//!    `[weakdeps]`/`[extensions]` pair; a package with one and not the other
//!    contributes nothing.
//!  * **the legend** — the trailing `Info` line is chosen by which markers
//!    actually appeared (`:2967-2980`), and is suppressed entirely under
//!    `--outdated`.
//!
//! ### Three parts of Pkg's report that are deliberately absent
//!
//! Each is a property of the Julia SESSION Pkg is running inside, and a
//! separate process cannot observe it. Guessing would be worse than saying so;
//! all three are listed in `Ajt.DIFFERENCES[:status]`.
//!
//!  1. **`[loaded: v…]`** (`:2921-2938`). Pkg compares each package against
//!     `Base.loaded_modules` and annotates a version mismatch between what is
//!     loaded and what the manifest pins. There is no loaded module here.
//!  2. **`[sysimage]`** as a held-back reason (`:2635-2641`). Requires
//!     `Base.in_sysimage` and `Base.pkgorigins` of the running image.
//!  3. **extension/weakdep colouring** (`:2946-2952`) — green for a loaded
//!     extension, grey otherwise. Invisible on a non-colour `io`, which is
//!     exactly the `io` the gate compares, so this one costs nothing there.
//!
//! `--diff` and `--workspace` are refused rather than ignored; see the CLI.
//!
//! ### The two places Julia's `Dict` order leaks into the output
//!
//! Pkg iterates `Dict`s to print `--compat` (`project.deps`, `:3106`) and the
//! per-package extension lines (`manifest_info.exts`, `:2739`). `Dict`
//! iteration order is a function of `Base.hash(::String)`, the table size and
//! the INSERTION sequence — reproducible in principle, not reproducible without
//! porting `Base.Dict` itself. Ajt emits both in a deterministic order instead
//! (project-file order for compat, manifest order — which is sorted, since the
//! file is machine-generated — for extensions). With one entry the two orders
//! coincide, which is the case the gate compares byte for byte; with more, the
//! SET of lines still matches and the order may not. Named in `DIFFERENCES`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const depot_mod = @import("../depot.zig");
const manifest_mod = @import("../model/manifest.zig");
const project_mod = @import("../model/project.zig");
const platform_mod = @import("../julia/platform.zig");
const slug = @import("../julia/slug.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const version_mod = @import("../julia/version.zig");
const versions_mod = @import("../julia/versions.zig");
const source_mod = @import("../registry/source.zig");
const arts = @import("install_artifacts.zig");
const verify = @import("verify.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;
pub const Version = version_mod.Version;
pub const Platform = platform_mod.Platform;

/// The markers, spelled once. `sprint(printstyled, …; context = io)` on a
/// colourless `io` is the character and nothing else (`:2786-2788`).
const not_installed = "\u{2192}"; // →
const upgradable = "\u{2303}"; // ⌃
const heldback = "\u{2305}"; // ⌅
const pinned_mark = "\u{26B2}"; // ⚲

/// `Pkg.utils.jl:2` — `textwidth(string(:Precompiling))`, the width every
/// `printpkgstyle` header is right-aligned in when `ignore_indent` is false.
/// `status` passes true everywhere except `print_compat`, which is why the
/// `Compat` header is the one indented line in this whole module.
const pkgstyle_indent = 12;

const max_project_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024 * 1024;

pub const Error = error{
    /// `[workspace]`. `EnvCache` redirects the manifest to the workspace root
    /// and `load_direct_deps` merges every member project's `[deps]`
    /// (`Types.jl:412-419`, `Operations.jl:84-109`); a single-project report
    /// over a workspace environment is confidently wrong rather than absent.
    WorkspaceUnsupported,
    /// No Julia to read `Types.stdlibs()` from. Every row's sort key starts
    /// with `is_stdlib(uuid)` (`:2825`) and every registry lookup is skipped
    /// for a stdlib (`:2845`), so without the set the report is not merely
    /// missing something — it is in the wrong ORDER, which reads as correct.
    StdlibsUnavailable,
} || Allocator.Error || Io.Cancelable;

/// `PKGMODE_PROJECT` / `PKGMODE_MANIFEST`. `PKGMODE_COMBINED` exists in Pkg but
/// no REPL flag or `status` call site selects it, so it is not exposed here
/// either; its only visible effect is one extra condition on the legend line
/// (`:2969`), which is vacuously true for both modes below.
pub const Mode = enum { project, manifest };

pub const Options = struct {
    /// The environment: a directory, or a project file directly. Probed the
    /// way `Types.projectfile_path` probes it.
    env_path: []const u8 = ".",
    /// Overrides manifest discovery entirely.
    manifest_file: ?[]const u8 = null,
    mode: Mode = .project,
    outdated: bool = false,
    extensions: bool = false,
    /// `--compat`, which is a different report entirely (`print_compat`) and
    /// refuses to combine with the others exactly as `API.status` does
    /// (`API.jl:1406-1410`).
    compat: bool = false,
    /// Positional package filters: a name or a UUID, matching Pkg's
    /// `filter_names` / `filter_uuids` (`:3049-3050`).
    filters: []const []const u8 = &.{},
    /// Every depot Julia would search, in DEPOT_PATH order. Read-only.
    stack: depot_mod.Stack,
    /// Pins the registry to one depot. Null scans `stack` in DEPOT_PATH order
    /// and takes the first depot that has one — the same search
    /// `Registry.reachable_registries()` does, stopping at the first hit
    /// instead of merging. A stack with no registry anywhere disables the
    /// registry half: no `⌃`/`⌅` markers and an empty `--outdated`, which is
    /// exactly what Pkg prints when `reachable_registries()` is empty.
    registry_depot: ?[]const u8 = null,
    registry_name: []const u8 = "General",
    /// `dirname(Sys.BINDIR)`. Required: see `Error.StdlibsUnavailable`.
    julia_prefix: ?[]const u8 = null,
    /// Selects the stdlib tree and stands in for `VERSION` in the "julia is
    /// holding this back" test (`:2678-2688`). Falls back to the manifest's
    /// own `julia_version`, which records the Julia that resolved it.
    julia_version: ?[]const u8 = null,
    /// `$HOME`, for `Base.contractuser` in `pathrepr`. Null disables the `~`
    /// contraction, which is only ever cosmetic.
    home: ?[]const u8 = null,
    /// Host platform for the artifact half of `is_package_downloaded`. Null
    /// skips that half — see `isPackageDownloaded`.
    host: ?Platform = null,
};

// ---------------------------------------------------------------------------
// PackageSpec — only the seven fields the report reads
// ---------------------------------------------------------------------------

/// `Types.PackageSpec` (`Types.jl:91-103`) reduced to what `stat_rep`,
/// `is_instantiated`, `is_package_downloaded` and `status_compat_info` touch.
///
/// `version == null` is Julia's `VersionSpec()` — the "no version" sentinel
/// `load_version` returns for an entry with no `version` key
/// (`Operations.jl:55-66`). It is NOT the same as version 0.0.0, and the
/// difference is visible: `stat_rep` prints nothing at all for it (`:2578`).
const Spec = struct {
    name: []const u8,
    uuid: Uuid,
    version: ?Version = null,
    tree_hash: ?Sha1 = null,
    path: ?[]const u8 = null,
    repo_source: ?[]const u8 = null,
    repo_rev: ?[]const u8 = null,
    repo_subdir: ?[]const u8 = null,
    pinned: bool = false,

    /// `Operations.jl:380-382`.
    fn trackingPath(self: Spec) bool {
        return self.path != null;
    }
    fn trackingRepo(self: Spec) bool {
        return self.repo_source != null or self.repo_rev != null;
    }
};

/// One rendered extension: the name Julia prints and its trigger list. The
/// `loaded` booleans Pkg carries alongside (`ExtInfo`, `:2771-2774`) decide
/// colour only, and there is no colour here.
const ExtInfo = struct {
    ext: []const u8,
    weakdeps: []const []const u8,
};

/// `status_compat_info`'s return (`:2693`): why a package is not at the latest
/// registered version, and what that version is.
const CompatData = struct {
    /// `packages_holding_back`, already sorted and deduplicated. The two
    /// single-element sentinels `["compat"]` and `["sysimage"]` print
    /// differently from a list of package names (`:2911-2919`); only the first
    /// is produced here.
    holding_back: []const []const u8,
    max_version: Version,
    max_version_in_compat: Version,
};

/// `Operations.PackageStatusData` (`:2775-2782`), minus the diff halves.
const Row = struct {
    uuid: Uuid,
    spec: Spec,
    downloaded: bool,
    upgradable: bool,
    heldback: bool,
    compat_data: ?CompatData,
    ext_info: ?[]const ExtInfo,
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Everything the report borrows comes from `arena`; `gpa` is scratch for the
/// registry (whose archive backend owns ~84 MB) and for artifact planning.
pub fn run(arena: Allocator, gpa: Allocator, io: Io, opts: Options, w: *Io.Writer) !void {
    const loc = try verify.locateProject(arena, io, opts.env_path);

    // `read_project` on a file that does not exist returns an EMPTY project
    // (`project.jl:248`), and `Pkg.status` in an empty directory duly prints
    // "(empty project)" rather than failing. Same here.
    var project = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, loc.project, arena, .limited(max_project_bytes)) catch
            break :blk try project_mod.empty(arena);
        break :blk try project_mod.parse(arena, src, .{ .file = loc.project }, null);
    };
    if (project.workspace_projects) |ws| {
        if (ws.len != 0) return Error.WorkspaceUnsupported;
    }

    // `pathrepr` is given ABSOLUTE paths by Pkg — `EnvCache` abspaths both
    // files (`Types.jl:392-420`) — so a relative `--env .` must be expanded
    // before it is printed, or every header line differs from Pkg's.
    const project_file = try absolute(arena, io, loc.project);

    if (opts.compat) {
        // `print_compat` needs no stdlib set of its own, but `pathrepr` does —
        // and unlike the main report, `--compat` reads nothing whose ORDER
        // depends on it, so a missing Julia degrades one cosmetic rewrite
        // rather than invalidating the answer. Hence the fallback, where the
        // main path raises `StdlibsUnavailable`.
        const set = loadStdlibs(arena, io, opts, .{}) catch stdlibs_mod.Set{ .dir = "" };
        return printCompat(arena, opts, set, &project, project_file, w);
    }

    // `env_path`/`stack` are not on `ManifestLocation`: a sibling unit
    // refactored `locateManifest` to take the already-resolved `Located` (which
    // carries the directory) as its own argument, so passing the path a second
    // time would be two sources for one answer.
    const manifest_rel = try verify.locateManifest(arena, io, .{
        .manifest_file = opts.manifest_file,
        .julia_prefix = opts.julia_prefix,
        .julia_version = opts.julia_version,
    }, loc, project.manifest);
    const manifest_file = try absolute(arena, io, manifest_rel);

    // `read_manifest` of a missing file is an empty Manifest, same as above.
    const manifest: manifest_mod.Manifest = blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, manifest_file, arena, .limited(max_manifest_bytes)) catch
            break :blk manifest_mod.Manifest{};
        break :blk try manifest_mod.parse(arena, src, null);
    };

    const stdlibs = try loadStdlibs(arena, io, opts, manifest);

    // `header === nothing && env.pkg !== nothing` (`:3027-3029`). `env.pkg` is
    // set exactly when the project has BOTH a name and a uuid
    // (`Types.jl:398-407`), and its version defaults to v"0.0" — which
    // `string(::VersionNumber)` renders with all three components.
    if (project.name != null and project.uuid != null) {
        const v = project.version orelse Version{ .major = 0, .minor = 0, .patch = 0 };
        try printPkgStyle(w, "Project", try std.fmt.allocPrint(arena, "{s} v{f}", .{ project.name.?, v }), true);
    }

    var reg: ?source_mod.Backend = null;
    defer if (reg) |*r| r.deinit(io);
    // A depot with no registry is not an error: Pkg's `registries` is then an
    // empty vector and `status_compat_info` returns `nothing` for everything,
    // which is a report with no upgrade markers. Scanning the WHOLE stack
    // rather than `depots1()` is what makes that rare: a scratch depot in front
    // of a warm `~/.julia` — the shape every harness and every container uses —
    // has its registry in the second entry.
    if (opts.registry_depot) |d| {
        reg = source_mod.open(gpa, arena, io, d, opts.registry_name, .auto) catch null;
    } else for (opts.stack.entries) |d| {
        reg = source_mod.open(gpa, arena, io, d, opts.registry_name, .auto) catch continue;
        break;
    }

    const ctx: Ctx = .{
        .arena = arena,
        .gpa = gpa,
        .io = io,
        .opts = opts,
        .project = &project,
        .project_file = project_file,
        .manifest = manifest,
        .manifest_file = manifest_file,
        .stdlibs = stdlibs,
        .reg = if (reg == null) null else &reg.?,
        .julia_version = try effectiveJuliaVersion(arena, opts, manifest),
    };

    try printStatus(ctx, w);

    // `is_manifest_current(env) === false` (`:3062-3066`). `=== nothing` — a
    // manifest with no `project_hash` at all — prints nothing, so the absence
    // of the key is silence rather than a warning.
    if (try manifestCurrent(gpa, &project, manifest)) |current| {
        if (!current) try printPkgStyle(
            w,
            "Warning",
            "The project dependencies or compat requirements have changed since the manifest was last resolved." ++
                " It is recommended to `Pkg.resolve()` or consider `Pkg.update()` if necessary.",
            true,
        );
    }
}

const Ctx = struct {
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    opts: Options,
    project: *const project_mod.Project,
    project_file: []const u8,
    manifest: manifest_mod.Manifest,
    manifest_file: []const u8,
    stdlibs: stdlibs_mod.Set,
    reg: ?*const source_mod.Backend,
    julia_version: ?Version,

    /// `Types.is_stdlib(uuid)` (`Types.jl:537`) — the FIXED set, which excludes
    /// `UPGRADABLE_STDLIBS`. That exclusion is visible in the output: a real
    /// `Pkg.status -m` sorts `Statistics` among the ordinary packages and
    /// `LinearAlgebra` among the stdlibs.
    fn isStdlib(self: Ctx, uuid: Uuid) bool {
        return self.stdlibs.isStdlib(uuid);
    }
};

// ---------------------------------------------------------------------------
// print_status
// ---------------------------------------------------------------------------

fn printStatus(ctx: Ctx, w: *Io.Writer) !void {
    const manifest_view = ctx.opts.mode == .manifest;
    const target_file = if (manifest_view) ctx.manifest_file else ctx.project_file;

    var xs = if (manifest_view)
        try loadAllDepsLoadable(ctx)
    else
        try loadProjectDeps(ctx);

    // `isempty(xs) && !diff` (`:2794-2801`).
    if (xs.len == 0) {
        try printPkgStyle(w, "Status", try std.fmt.allocPrint(ctx.arena, "{s} (empty {s})", .{
            try pathrepr(ctx.arena, ctx.opts, ctx.stdlibs, target_file),
            if (manifest_view) "manifest" else "project",
        }), true);
        return;
    }

    // `no_changes = all(p -> p[2] == p[3], xs)` (`:2802`). Without a diff the
    // old side is `nothing` for every row and the new side never is, so this
    // is false whenever `xs` is non-empty — i.e. always, here. Kept named
    // because the two footer conditions below read it.
    const no_changes = false;

    if (ctx.opts.filters.len != 0) {
        xs = try applyFilter(ctx, xs);
        if (xs.len == 0) {
            try printPkgStyle(w, "No Matches", try std.fmt.allocPrint(ctx.arena, "in {s}", .{
                try pathrepr(ctx.arena, ctx.opts, ctx.stdlibs, target_file),
            }), true);
            return;
        }
    }

    try printPkgStyle(w, "Status", try pathrepr(ctx.arena, ctx.opts, ctx.stdlibs, target_file), true);

    // `sort!(xs, by = x -> (is_stdlib(uuid), endswith(name, "_jll"), name, uuid))`
    // (`:2825`).
    const SortCtx = struct {
        c: Ctx,
        fn lt(s: @This(), a: Spec, b: Spec) bool {
            const a_std = s.c.isStdlib(a.uuid);
            const b_std = s.c.isStdlib(b.uuid);
            if (a_std != b_std) return b_std;
            const a_jll = std.mem.endsWith(u8, a.name, "_jll");
            const b_jll = std.mem.endsWith(u8, b.name, "_jll");
            if (a_jll != b_jll) return b_jll;
            const ord = std.mem.order(u8, a.name, b.name);
            if (ord != .eq) return ord == .lt;
            // `isless(::UUID, ::UUID)` compares the 128-bit value, and a UUID's
            // bytes are big-endian, so a plain byte comparison is that order.
            return std.mem.order(u8, &a.uuid.bytes, &b.uuid.bytes) == .lt;
        }
    };
    std.mem.sort(Spec, xs, SortCtx{ .c = ctx }, SortCtx.lt);

    var rows: std.ArrayList(Row) = .empty;
    var all_downloaded = true;
    var none_upgradable = true;
    var no_visible_heldback = true;
    var lpadding: usize = 2;

    for (xs) |spec| {
        // `Types.is_project_uuid(env, uuid)` (`:2838-2840`). `load_project_deps`
        // pushes the project itself as a row and `print_status` then drops it;
        // the round trip is not pointless, because its presence is what keeps
        // an otherwise-empty project from printing "(empty project)".
        if (ctx.project.uuid) |pu| {
            if (std.mem.eql(u8, &pu.bytes, &spec.uuid.bytes)) continue;
        }

        var latest_version = true;
        var cinfo: ?CompatData = null;
        var ext_info: ?[]const ExtInfo = null;
        const is_std = ctx.isStdlib(spec.uuid);

        if (!is_std) {
            cinfo = try statusCompatInfo(ctx, spec);
            if (cinfo != null) latest_version = false;
        }
        // `outdated` shows ONLY upper-bounded packages (`:2853`).
        if (ctx.opts.outdated and latest_version) continue;

        if (!is_std) ext_info = try statusExtInfo(ctx, spec);
        if (ctx.opts.extensions and ext_info == null) continue;

        // `is_instantiated(x) = x.version != VersionSpec() || is_stdlib(x.uuid)`
        // (`:2591`): an entry with no version at all is not something that
        // could be downloaded, so it is never marked missing.
        const instantiated = spec.version != null or is_std;
        const downloaded = !instantiated or isPackageDownloaded(ctx, spec);

        const new_ver_avail = !latest_version and !spec.trackingRepo() and !spec.trackingPath();
        const up = new_ver_avail and cinfo.?.holding_back.len == 0;
        const held = new_ver_avail and cinfo.?.holding_back.len != 0;

        // Gutter width is a property of the WHOLE report, decided by any one
        // package that is both missing and outdated (`:2874-2877`).
        if (!downloaded and (up or held)) lpadding = 3;
        all_downloaded = all_downloaded and downloaded;
        none_upgradable = none_upgradable and !up;
        no_visible_heldback = no_visible_heldback and !held;

        try rows.append(ctx.arena, .{
            .uuid = spec.uuid,
            .spec = spec,
            .downloaded = downloaded,
            .upgradable = up,
            .heldback = held,
            .compat_data = cinfo,
            .ext_info = ext_info,
        });
    }

    for (rows.items) |row| {
        var pad: usize = 0;
        if (!row.downloaded) {
            try w.writeAll(not_installed);
            pad += 1;
        } else if (lpadding > 2) {
            try w.writeAll(" ");
            pad += 1;
        }
        if (row.upgradable) {
            try w.writeAll(upgradable);
            pad += 1;
        } else if (row.heldback) {
            try w.writeAll(heldback);
            pad += 1;
        }
        while (pad < lpadding) : (pad += 1) try w.writeAll(" ");

        var ubuf: [36]u8 = undefined;
        const utext = manifest_mod.formatUuid(row.uuid, &ubuf);
        try w.print("[{s}] ", .{utext[0..8]});

        try statRep(ctx, w, row.spec);

        if (ctx.opts.outdated) {
            if (row.compat_data) |cd| try printOutdated(w, row.spec, cd);
        }

        if (ctx.opts.extensions) {
            if (row.ext_info) |exts| try printExtensions(w, exts);
        }

        try w.writeAll("\n");
    }

    // `:2963-2965`.
    if (!no_changes and !all_downloaded) {
        try printPkgStyle(w, "Info", "Packages marked with " ++ not_installed ++
            " are not downloaded, use `instantiate` to download", true);
    }
    if (!ctx.opts.outdated) {
        const tipend = if (manifest_view) " -m" else "";
        if (!none_upgradable and no_visible_heldback) {
            try printPkgStyle(w, "Info", "Packages marked with " ++ upgradable ++
                " have new versions available and may be upgradable.", true);
        }
        if (!no_visible_heldback and none_upgradable) {
            try printPkgStyle(w, "Info", try std.fmt.allocPrint(ctx.arena, "Packages marked with " ++ heldback ++
                " have new versions available but compatibility constraints restrict them from upgrading." ++
                " To see why use `status --outdated{s}`", .{tipend}), true);
        }
        if (!no_visible_heldback and !none_upgradable) {
            try printPkgStyle(w, "Info", try std.fmt.allocPrint(ctx.arena, "Packages marked with " ++ upgradable ++
                " and " ++ heldback ++ " have new versions available. Those with " ++ upgradable ++
                " may be upgradable, but those with " ++ heldback ++
                " are restricted by compatibility constraints from upgrading." ++
                " To see why use `status --outdated{s}`", .{tipend}), true);
        }
        // The fourth branch (`:2978-2980`) is guarded by `hidden_upgrades_info`,
        // which only `show_update` sets — never `API.status`.
    }
}

/// `xs = [… for … if (id in uuids || something(new, old).name in names)]`
/// (`:2811`). One positional is matched against both the UUID and the name,
/// because `PackageSpec("…")` fills whichever field the string parses as.
fn applyFilter(ctx: Ctx, xs: []Spec) Allocator.Error![]Spec {
    var kept: std.ArrayList(Spec) = .empty;
    outer: for (xs) |spec| {
        for (ctx.opts.filters) |f| {
            if (std.mem.eql(u8, f, spec.name)) {
                try kept.append(ctx.arena, spec);
                continue :outer;
            }
            if (Uuid.parse(f)) |u| {
                if (std.mem.eql(u8, &u.bytes, &spec.uuid.bytes)) {
                    try kept.append(ctx.arena, spec);
                    continue :outer;
                }
            } else |_| {}
        }
    }
    return kept.items;
}

// ---------------------------------------------------------------------------
// stat_rep and the per-row extras
// ---------------------------------------------------------------------------

/// `stat_rep(x; name = true)` (`:2576-2587`) — `join(filter(!isempty, [name,
/// version, repo, path, pinned]), " ")`, so an empty component contributes no
/// separator either.
fn statRep(ctx: Ctx, w: *Io.Writer, spec: Spec) !void {
    try w.writeAll(spec.name);
    if (spec.version) |v| try w.print(" v{f}", .{v});
    if (spec.trackingRepo()) {
        // `occursin(r"\b([a-f0-9]{40})\b", rev) ? rev[1:7] : rev` (`:2581`): a
        // full lowercase SHA-1 is abbreviated, anything else — a branch name, a
        // tag, an already-short hash — is printed whole.
        const rev = spec.repo_rev orelse "";
        const shown = if (isFullSha1(rev)) rev[0..7] else rev;
        try w.print(" `{s}", .{spec.repo_source orelse ""});
        if (spec.repo_subdir) |s| try w.print(":{s}", .{s});
        try w.print("#{s}`", .{shown});
    }
    if (spec.path) |p| try w.print(" {s}", .{try pathrepr(ctx.arena, ctx.opts, ctx.stdlibs, p)});
    if (spec.pinned) try w.writeAll(" " ++ pinned_mark);
}

/// `\b([a-f0-9]{40})\b` against the whole rev. A rev that merely CONTAINS one
/// also matches in Julia, but a rev is either a hash or a ref name, never both,
/// so the whole-string test is the same predicate on every reachable input.
fn isFullSha1(rev: []const u8) bool {
    if (rev.len != 40) return false;
    for (rev) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// `:2905-2920`. Note the comma: it is printed after the `]` of the compat
/// bound, not before the `(`, so the two forms are `… [<v1.2.3], (<v2.0.0)`
/// and `… (<v2.0.0)`.
fn printOutdated(w: *Io.Writer, spec: Spec, cd: CompatData) !void {
    const at_compat_max = if (spec.version) |v| v.eql(cd.max_version_in_compat) else false;
    if (!at_compat_max and !cd.max_version_in_compat.eql(cd.max_version)) {
        try w.print(" [<v{f}]", .{cd.max_version_in_compat});
        try w.writeAll(",");
    }
    try w.print(" (<v{f})", .{cd.max_version});
    if (cd.holding_back.len == 1 and std.mem.eql(u8, cd.holding_back[0], "compat")) {
        try w.writeAll(" [compat]");
    } else if (cd.holding_back.len != 0) {
        try w.writeAll(": ");
        for (cd.holding_back, 0..) |h, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(h);
        }
    }
}

/// `:2940-2960`. The 14-space indent is a literal in Pkg and lines the tree up
/// under the package name for the default two-space gutter — it does NOT track
/// `lpadding`, so a report with a `→` in it has visibly misaligned tree glyphs.
/// Reproduced, misalignment included.
fn printExtensions(w: *Io.Writer, exts: []const ExtInfo) !void {
    try w.writeAll("\n");
    for (exts, 0..) |e, i| {
        const last = i == exts.len - 1;
        try w.writeAll("              ");
        try w.writeAll(if (last) "\u{2514}" else "\u{251C}");
        try w.writeAll("\u{2500} ");
        try w.writeAll(e.ext);
        try w.writeAll(" [");
        for (e.weakdeps, 0..) |d, j| {
            if (j != 0) try w.writeAll(", ");
            try w.writeAll(d);
        }
        try w.writeAll("]");
        if (!last) try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// diff_array's `new` side
// ---------------------------------------------------------------------------

/// `load_project_deps(env.project, env.project_file, env.manifest,
/// env.manifest_file)` (`Operations.jl:111-140`) — the project's own package
/// followed by one spec per `[deps]` entry, each merged with its manifest entry.
fn loadProjectDeps(ctx: Ctx) Allocator.Error![]Spec {
    var out: std.ArrayList(Spec) = .empty;
    try appendProjectPackage(ctx, &out);
    for (ctx.project.deps.entries.items) |d| {
        try out.append(ctx.arena, try directSpec(ctx, d.name, d.uuid));
    }
    return out.items;
}

fn appendProjectPackage(ctx: Ctx, out: *std.ArrayList(Spec)) Allocator.Error!void {
    const name = ctx.project.name orelse return;
    const uuid = ctx.project.uuid orelse return;
    try out.append(ctx.arena, .{
        .name = name,
        .uuid = uuid,
        .version = ctx.project.version,
        // `Types.relative_project_path(manifest_file, dirname(project_file))`
        // (`Operations.jl:118`). This row is dropped by the `is_project_uuid`
        // guard before it can be printed, so the path is only ever material to
        // a `--diff` this module does not implement — but computing it keeps
        // the row identical to Pkg's for the emptiness and filter tests that
        // DO see it.
        .path = relativeProjectPath(ctx.arena, ctx.io, ctx.manifest_file, fspath.dirname(ctx.project_file) orelse ".") catch ".",
    });
}

/// One `[deps]` entry as `load_project_deps` builds it (`:120-138`).
fn directSpec(ctx: Ctx, name: []const u8, uuid: Uuid) Allocator.Error!Spec {
    const sp = try sourcePathRepo(ctx, name);
    const entry = ctx.manifest.findByUuid(uuid) orelse return .{
        .name = name,
        .uuid = uuid,
        .path = sp.path,
        .repo_source = sp.url,
        .repo_rev = sp.rev,
        .repo_subdir = sp.subdir,
    };
    // `repo == GitRepo() ? entry.repo : repo` — the `[sources]` repo replaces
    // the manifest's WHOLE repo when it sets any of url/rev/subdir, rather
    // than merging field by field.
    const src_repo_set = sp.url != null or sp.rev != null or sp.subdir != null;
    return .{
        .name = name,
        .uuid = uuid,
        .path = sp.path orelse entry.path,
        .repo_source = if (src_repo_set) sp.url else entry.repo_url,
        .repo_rev = if (src_repo_set) sp.rev else entry.repo_rev,
        .repo_subdir = if (src_repo_set) sp.subdir else entry.repo_subdir,
        .pinned = entry.pinned,
        .tree_hash = entry.tree_hash,
        .version = entry.version,
    };
}

/// `load_all_deps_loadable(env)` (`:192-199`): every manifest entry, with
/// `[sources]` applied, plus the direct deps the manifest does not mention,
/// restricted to the loadable closure of `project.deps`.
fn loadAllDepsLoadable(ctx: Ctx) Allocator.Error![]Spec {
    var out: std.ArrayList(Spec) = .empty;

    for (ctx.manifest.entries) |e| {
        var spec: Spec = .{
            .name = e.name,
            .uuid = e.uuid,
            .version = e.version,
            .tree_hash = e.tree_hash,
            .path = e.path,
            .repo_source = e.repo_url,
            .repo_rev = e.repo_rev,
            .repo_subdir = e.repo_subdir,
            .pinned = e.pinned,
        };
        // `[sources]` takes precedence over the manifest, and a path source
        // CLEARS the tree hash and repo outright (`:172-189`) — the package is
        // loaded from the working tree, so its depot slug is irrelevant.
        const sp = try sourcePathRepo(ctx, e.name);
        if (sp.path) |p| {
            spec.tree_hash = null;
            spec.repo_source = null;
            spec.repo_rev = null;
            spec.repo_subdir = null;
            spec.path = p;
        }
        if (sp.url) |u| {
            spec.path = null;
            spec.repo_source = u;
        }
        if (sp.rev) |r| spec.repo_rev = r;
        try out.append(ctx.arena, spec);
    }

    // `load_direct_deps(env, pkgs)`: the project package and every direct dep
    // that is not already present, appended AFTER the manifest entries.
    const present = struct {
        fn has(list: []const Spec, u: Uuid) bool {
            for (list) |s| if (std.mem.eql(u8, &s.uuid.bytes, &u.bytes)) return true;
            return false;
        }
    }.has;
    if (ctx.project.uuid) |pu| {
        if (!present(out.items, pu)) try appendProjectPackage(ctx, &out);
    }
    for (ctx.project.deps.entries.items) |d| {
        if (present(out.items, d.uuid)) continue;
        try out.append(ctx.arena, try directSpec(ctx, d.name, d.uuid));
    }

    // `keep = Set(values(project.deps)); prune_deps(manifest, keep)` — the same
    // fixpoint `verify` already computes, reused rather than restated.
    const keep = try verify.loadable(ctx.arena, ctx.project.*, ctx.manifest);
    var kept: std.ArrayList(Spec) = .empty;
    for (out.items) |s| {
        if (keep.contains(s.uuid.bytes)) try kept.append(ctx.arena, s);
    }
    return kept.items;
}

const SourceInfo = struct {
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    subdir: ?[]const u8 = null,
};

/// `get_path_repo` (`project.jl:7-25`). The path rebase is the part worth
/// naming: `[sources]` records a PROJECT-relative path and every consumer wants
/// a MANIFEST-relative one, so Julia round-trips it through `realpath`
/// (`project_path_to_manifest_path`, `Types.jl:444-448`). The two are the same
/// string until a `manifest = "…"` redirect separates the files.
fn sourcePathRepo(ctx: Ctx, name: []const u8) Allocator.Error!SourceInfo {
    const s = ctx.project.sourceFor(name) orelse return .{};
    var info: SourceInfo = .{ .url = s.url, .rev = s.rev, .subdir = s.subdir };
    if (s.path) |p| {
        if (fspath.isAbsolute(p)) {
            info.path = p;
        } else {
            const joined = try fspath.join(ctx.arena, &.{ fspath.dirname(ctx.project_file) orelse ".", p });
            const abs = safeRealPath(ctx.arena, ctx.io, joined) catch joined;
            const base = safeRealPath(ctx.arena, ctx.io, fspath.dirname(ctx.manifest_file) orelse ".") catch
                (fspath.dirname(ctx.manifest_file) orelse ".");
            info.path = relpath(ctx.arena, abs, base) catch p;
        }
    }
    return info;
}

fn relativeProjectPath(arena: Allocator, io: Io, manifest_file: []const u8, dir: []const u8) ![]const u8 {
    const a = safeRealPath(arena, io, dir) catch dir;
    const b = safeRealPath(arena, io, fspath.dirname(manifest_file) orelse ".") catch
        (fspath.dirname(manifest_file) orelse ".");
    return relpath(arena, a, b);
}

// ---------------------------------------------------------------------------
// status_compat_info
// ---------------------------------------------------------------------------

/// `status_compat_info(pkg, env, regs)` (`:2612-2694`).
///
/// Five early exits, in Julia's order, and the order matters: a package with no
/// version, absent from every registry, or already AT the newest registered
/// version produces no marker at all, and only what survives those gets the
/// (expensive) reverse-dependency scan.
///
/// One divergence: Julia iterates every reachable registry and takes the
/// maximum across all of them. Ajt reads a single registry (`--registry`,
/// default General). On a machine with one registry — which is every machine
/// that has not deliberately added a second — the two are the same computation.
fn statusCompatInfo(ctx: Ctx, spec: Spec) Allocator.Error!?CompatData {
    const version = spec.version orelse return null;
    const reg = ctx.reg orelse return null;

    var ubuf: [36]u8 = undefined;
    const uuid_text = manifest_mod.formatUuid(spec.uuid, &ubuf);
    const ref = reg.findByUuid(uuid_text) orelse return null;
    var info = reg.loadPackage(ctx.gpa, ref) catch return null;
    defer info.deinit();

    const zero: Version = .{};
    var max_version: Version = zero;
    var max_in_compat: Version = zero;
    // `get_compat_workspace(env, name)` with no workspace is the project's own
    // `[compat]`, or an unbounded spec where there is none (`:327`).
    const compat_spec: ?versions_mod.Spec = if (ctx.project.compatFor(spec.name)) |c| c.spec else null;

    for (info.versions) |vi| {
        // `filter(v -> !isyanked(info, v), versions)` — but ONLY for the
        // registry maximum. `versions_in_compat` is computed from the
        // unfiltered `keys(reg_compat_info)` (`:2626`), so a yanked version
        // inside the compat bound still raises `max_version_in_compat`. That
        // asymmetry is Pkg's, not a transcription slip.
        if (!vi.yanked and max_version.lessThan(vi.version)) max_version = vi.version;
        const in_compat = if (compat_spec) |cs| cs.contains(vi.version) else true;
        if (in_compat and max_in_compat.lessThan(vi.version)) max_in_compat = vi.version;
    }

    if (max_version.eql(zero)) return null;
    if (!version.lessThan(max_version)) return null;

    // `["sysimage"]` (`:2635-2641`) needs the running image; see the header.

    if (version.eql(max_in_compat) and !max_in_compat.eql(max_version)) {
        const one = try ctx.arena.alloc([]const u8, 1);
        one[0] = "compat";
        return .{ .holding_back = one, .max_version = max_version, .max_version_in_compat = max_in_compat };
    }

    // `manifest_info === nothing && return nothing` (`:2652-2653`): a spec with
    // no manifest entry has no reverse edges to scan.
    _ = ctx.manifest.findByUuid(spec.uuid) orelse return null;

    var holding: std.ArrayList([]const u8) = .empty;
    for (ctx.manifest.entries) |dep| {
        if (ctx.isStdlib(dep.uuid)) continue;
        var depends = false;
        for (dep.deps) |d| {
            if (std.mem.eql(u8, &d.uuid.bytes, &spec.uuid.bytes)) depends = true;
        }
        if (!depends) continue;
        const dep_version = dep.version orelse continue;

        var dbuf: [36]u8 = undefined;
        const dep_uuid_text = manifest_mod.formatUuid(dep.uuid, &dbuf);
        const dep_ref = reg.findByUuid(dep_uuid_text) orelse continue;
        var dep_info = reg.loadPackage(ctx.gpa, dep_ref) catch continue;
        defer dep_info.deinit();
        const idx = dep_info.indexOfVersion(dep_version) orelse continue;
        for (dep_info.deps[idx]) |d| {
            if (!std.mem.eql(u8, d.uuid, uuid_text)) continue;
            if (!d.compat.contains(max_version)) try holding.append(ctx.arena, dep.name);
        }
    }

    // "Check compat with Julia itself" (`:2676-2690`): the newest version is
    // only reachable if it declares compatibility with the running Julia.
    // Julia builds the whole compatible SET and asks whether `max_version` is
    // in it; membership depends only on that version's own entry, so the set is
    // skipped here. With no Julia version to test against (no
    // `--julia-version` and a manifest carrying no `julia_version`) the reason
    // cannot be computed and is left out rather than guessed at.
    if (ctx.julia_version) |jv| {
        var julia_ok = false;
        for (info.versions, 0..) |vi, i| {
            if (!vi.version.eql(max_version)) continue;
            for (info.deps[i]) |d| {
                if (!std.mem.eql(u8, d.name, "julia")) continue;
                if (d.compat.contains(jv)) julia_ok = true;
            }
        }
        if (!julia_ok) try holding.append(ctx.arena, "julia");
    }

    return .{
        .holding_back = try sortedUnique(ctx.arena, holding.items),
        .max_version = max_version,
        .max_version_in_compat = max_in_compat,
    };
}

/// `sort!(unique!(v))` — Julia sorts a `Vector{String}` in plain byte order.
fn sortedUnique(arena: Allocator, items: [][]const u8) Allocator.Error![]const []const u8 {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |s| {
        if (out.items.len != 0 and std.mem.eql(u8, out.items[out.items.len - 1], s)) continue;
        try out.append(arena, s);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// status_ext_info
// ---------------------------------------------------------------------------

/// `status_ext_info(pkg, env)` (`:2731-2769`). Both `[weakdeps]` and
/// `[extensions]` must be non-empty, which is what makes `--extensions` a
/// filter rather than an annotation.
fn statusExtInfo(ctx: Ctx, spec: Spec) Allocator.Error!?[]const ExtInfo {
    const entry = ctx.manifest.findByUuid(spec.uuid) orelse return null;
    if (entry.weakdeps.len == 0 or entry.exts.len == 0) return null;

    const out = try ctx.arena.alloc(ExtInfo, entry.exts.len);
    for (entry.exts, 0..) |e, i| {
        const triggers: []const []const u8 = switch (e.targets) {
            // `extdeps isa String && (extdeps = String[extdeps])` (`:2739`).
            .one => |s| blk: {
                const one = try ctx.arena.alloc([]const u8, 1);
                one[0] = s;
                break :blk one;
            },
            .many => |m| m,
        };
        // Julia raises when a trigger is in neither `[deps]` nor `[weakdeps]`
        // (`:2745-2750`); it resolves the uuid only to look the module up in
        // `Base.loaded_modules`, which decides COLOUR. With no colour there is
        // nothing to resolve and nothing to raise about, so a malformed
        // manifest prints rather than throws.
        out[i] = .{ .ext = e.name, .weakdeps = triggers };
    }
    return out;
}

// ---------------------------------------------------------------------------
// is_package_downloaded
// ---------------------------------------------------------------------------

/// `is_package_downloaded(manifest_file, pkg)` (`:2723-2729`): `source_path`
/// resolves, is a directory, and every artifact it declares is in the depot.
///
/// The artifact half diverges from Pkg in one respect, and it is Pkg's own
/// quirk that makes byte-identity impossible rather than a shortcut here:
/// `check_artifacts_downloaded` (`:1083-1094`) `break`s after the FIRST key of
/// each `Artifacts.toml`'s selected-artifact `Dict`, so it checks one artifact
/// per file and which one depends on Julia's `Dict` iteration order. Ajt checks
/// all of them, which is strictly stronger and deterministic. It differs only
/// for a package with several artifacts of which some are present — a
/// half-installed depot.
///
/// With no host platform (`--julia-prefix` absent, so `HostPlatform()` cannot be
/// constructed) the artifact half is skipped entirely and only the source
/// directory decides. Under-reporting `→` is the safe direction: it points at
/// `instantiate`, which would have re-checked anyway.
fn isPackageDownloaded(ctx: Ctx, spec: Spec) bool {
    const root = sourcePath(ctx, spec) orelse return false;
    if (!verify.isDir(ctx.io, root)) return false;

    const host = ctx.opts.host orelse return true;
    if (ctx.opts.stack.entries.len == 0) return true;
    const plan = arts.plan(ctx.arena, ctx.gpa, ctx.io, ctx.opts.stack.entries, &.{.{ .root = root }}, host, .{}) catch
        return true;
    for (plan.jobs) |j| {
        if (!j.present) return false;
    }
    return true;
}

/// `source_path(manifest_file, pkg)` (`:48-53`), three branches in Julia's
/// order — a tree hash beats a `path`, and only an entry with neither falls
/// through to the stdlib tree.
fn sourcePath(ctx: Ctx, spec: Spec) ?[]const u8 {
    if (spec.tree_hash) |th| {
        const found = depot_mod.findInstalled(ctx.arena, ctx.io, ctx.opts.stack, spec.name, spec.uuid, th) catch
            return null;
        return if (found.exists) found.path else null;
    }
    if (spec.path) |p| {
        return fspath.resolve(ctx.arena, &.{ fspath.dirname(ctx.manifest_file) orelse ".", p }) catch null;
    }
    // `is_or_was_stdlib`, which includes `UPGRADABLE_STDLIBS` — those are
    // resolved from the registry but still ship in the stdlib tree.
    if (ctx.stdlibs.isOrWasStdlib(spec.uuid)) {
        return fspath.join(ctx.arena, &.{ ctx.stdlibs.dir, spec.name }) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// print_compat
// ---------------------------------------------------------------------------

/// `print_compat(ctx, pkgs; io)` (`:3099-3110`) — a different report that
/// happens to share a flag.
///
/// Two things here are unlike everything else in this module. The header goes
/// through `printpkgstyle` with the DEFAULT `ignore_indent = false`, so it is
/// right-aligned in 12 columns (`      Compat …`) where every `Status` line is
/// flush left. And the gutter is 13 characters wide either way: `"  ["` + 8 hex
/// + `"] "` for a dep, and `indent * 11 spaces` for the `julia` row that has no
/// uuid (`:3086-3090`).
fn printCompat(
    arena: Allocator,
    opts: Options,
    stdlibs: stdlibs_mod.Set,
    project: *const project_mod.Project,
    project_file: []const u8,
    w: *Io.Writer,
) !void {
    try printPkgStyle(w, "Compat", try pathrepr(arena, opts, stdlibs, project_file), false);

    var deps: std.ArrayList(project_mod.Dep) = .empty;
    var add_julia = opts.filters.len == 0;
    for (project.deps.entries.items) |d| {
        if (opts.filters.len == 0) {
            try deps.append(arena, d);
            continue;
        }
        for (opts.filters) |f| {
            if (std.mem.eql(u8, f, d.name)) {
                try deps.append(arena, d);
                break;
            }
        }
    }
    for (opts.filters) |f| {
        if (std.mem.eql(u8, f, "julia")) add_julia = true;
    }

    // `isempty(pkgs) ? length("julia") : max(maximum(length, keys(pkgs)), 5)`
    // (`:3103`) — the floor is `"julia"` whether or not that row is printed,
    // and a filtered-out dep is out of the maximum, so `status -c Colors` pads
    // to 6 where `status -c` in the same project might pad to 12.
    var longest: usize = "julia".len;
    for (deps.items) |d| longest = @max(longest, d.name.len);

    if (add_julia) {
        try compatLine(w, "julia", null, compatStr(project, "julia"), longest);
    }
    for (deps.items) |d| {
        try compatLine(w, d.name, d.uuid, compatStr(project, d.name), longest);
    }
}

fn compatStr(project: *const project_mod.Project, name: []const u8) ?[]const u8 {
    const c = project.compatFor(name) orelse return null;
    return c.str;
}

fn compatLine(
    w: *Io.Writer,
    name: []const u8,
    uuid: ?Uuid,
    str: ?[]const u8,
    longest: usize,
) !void {
    if (uuid) |u| {
        var ubuf: [36]u8 = undefined;
        const utext = manifest_mod.formatUuid(u, &ubuf);
        try w.print("  [{s}] ", .{utext[0..8]});
    } else {
        try w.writeAll("  " ++ "           ");
    }
    try w.writeAll(name);
    if (name.len < longest) try w.splatByteAll(' ', longest - name.len);
    if (str) |s| {
        try w.print(" {s}", .{s});
    } else {
        try w.writeAll(" none");
    }
    try w.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Small ports
// ---------------------------------------------------------------------------

/// `printpkgstyle` (`utils.jl:4-10`): `lpad(cmd, indent)`, a space, the text, a
/// newline. `printstyled` adds nothing on a colourless sink.
fn printPkgStyle(w: *Io.Writer, cmd: []const u8, text: []const u8, ignore_indent: bool) !void {
    const indent: usize = if (ignore_indent) 0 else pkgstyle_indent;
    if (cmd.len < indent) try w.splatByteAll(' ', indent - cmd.len);
    try w.writeAll(cmd);
    try w.writeAll(" ");
    try w.writeAll(text);
    try w.writeAll("\n");
}

/// `pathrepr(path)` (`utils.jl:33-39`): a stdlib path collapses to
/// `@stdlib/Name`, then `Base.contractuser` swaps `$HOME` for `~`, then the
/// whole thing is wrapped in backticks.
fn pathrepr(arena: Allocator, opts: Options, stdlibs: stdlibs_mod.Set, path: []const u8) Allocator.Error![]const u8 {
    var p = path;
    if (stdlibs.dir.len != 0 and std.mem.startsWith(u8, p, stdlibs.dir)) {
        p = try std.fmt.allocPrint(arena, "@stdlib/{s}", .{fspath.basename(p)});
    }
    if (opts.home) |home| {
        if (home.len != 0) {
            if (std.mem.eql(u8, p, home)) {
                p = "~";
            } else if (std.mem.startsWith(u8, p, home)) {
                // `joinpath("~", relpath(path, home))` — a PREFIX test, not a
                // path-component test, so `/home/ada2` under `$HOME=/home/ada`
                // contracts to `~/../ada2`. Julia's quirk, reproduced.
                const rel = relpath(arena, p, home) catch p;
                p = try std.fmt.allocPrint(arena, "~/{s}", .{rel});
            }
        }
    }
    return std.fmt.allocPrint(arena, "`{s}`", .{p});
}

/// `Base.relpath` (`base/path.jl:531-...`), purely lexical. Both arguments are
/// absolute here, so the `abspath` calls Julia makes are no-ops.
///
/// The shape worth keeping is the last branch: when the common prefix is
/// shorter than `startpath`, the result is `../` repeated and then `..` — so
/// `relpath("/a", "/a/b")` is `".."` and not `"../"`.
fn relpath(arena: Allocator, path: []const u8, startpath: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, path, startpath)) return ".";
    const pa = try splitPath(arena, path);
    const sa = try splitPath(arena, startpath);

    var i: usize = 0;
    while (i < @min(pa.len, sa.len)) {
        if (!std.mem.eql(u8, pa[i], sa[i])) break;
        i += 1;
    }
    const last_p = lastNonEmpty(pa);
    const last_s = lastNonEmpty(sa);

    var parts: std.ArrayList([]const u8) = .empty;
    if (i < last_p) try parts.appendSlice(arena, pa[i..last_p]);
    const pathpart = try std.mem.join(arena, "/", parts.items);

    if (last_s >= i + 1) {
        const prefix_num = last_s - i - 1;
        var buf: std.ArrayList(u8) = .empty;
        for (0..prefix_num) |_| try buf.appendSlice(arena, "../");
        try buf.appendSlice(arena, "..");
        if (pathpart.len != 0) {
            try buf.appendSlice(arena, "/");
            try buf.appendSlice(arena, pathpart);
        }
        return buf.items;
    }
    return if (pathpart.len == 0) "." else pathpart;
}

/// `split(p, r"/+")` — runs of separators collapse, and a leading `/` yields a
/// leading empty component.
fn splitPath(arena: Allocator, p: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var start: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] != '/') continue;
        try out.append(arena, p[start..i]);
        while (i + 1 < p.len and p[i + 1] == '/') i += 1;
        start = i + 1;
    }
    try out.append(arena, p[start..]);
    return out.items;
}

/// `something(findlast(x -> !isempty(x), arr), 0)`, as a 1-based index.
fn lastNonEmpty(arr: []const []const u8) usize {
    var n: usize = arr.len;
    while (n > 0) : (n -= 1) {
        if (arr[n - 1].len != 0) return n;
    }
    return 0;
}

/// `Pkg.safe_realpath` (`utils.jl:82-88`): `realpath` when the path exists,
/// the path itself otherwise.
fn safeRealPath(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    // `Dir.realPath` resolves the directory it is called ON (zig 0.16 dropped
    // the sub-path form), so the path has to be opened first. Every call site
    // here passes a directory, which is also the only thing Pkg passes.
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return path;
    defer dir.close(io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return path;
    return arena.dupe(u8, buf[0..n]);
}

/// `abspath`. `EnvCache` abspaths both files before anything prints them, so a
/// relative `--env` must be expanded or every header line differs.
fn absolute(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    if (fspath.isAbsolute(path)) return path;
    // `Dir.cwd()` is the AT_FDCWD sentinel rather than an open handle, and
    // `realPath` on it does not answer — it has to be opened first. Getting
    // this wrong is invisible until you run `ajt status` from inside an
    // environment, where the header then reads `` `./Project.toml` `` against
    // Pkg's absolute path.
    var dir = Io.Dir.cwd().openDir(io, ".", .{}) catch return path;
    defer dir.close(io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return path;
    return fspath.resolve(arena, &.{ buf[0..n], path });
}

/// `Operations.is_manifest_current(env)` (`:3068-3077`), tri-state: `null` when
/// the manifest records no `project_hash` at all, which Pkg treats as "cannot
/// say" and prints nothing about.
fn manifestCurrent(
    gpa: Allocator,
    project: *const project_mod.Project,
    manifest: manifest_mod.Manifest,
) Allocator.Error!?bool {
    const other = manifest.other orelse return null;
    const recorded = switch (other.get("project_hash") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const computed = @import("../julia/project_hash.zig").compute(gpa, project.other()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    // Julia compares the recorded STRING, so an uppercase-hex hash is a
    // mismatch there and must be one here too (see `verify.zig:406-414`).
    return std.mem.eql(u8, recorded, &computed);
}

fn loadStdlibs(arena: Allocator, io: Io, opts: Options, manifest: manifest_mod.Manifest) Error!stdlibs_mod.Set {
    const prefix = opts.julia_prefix orelse return Error.StdlibsUnavailable;
    if (opts.julia_version) |jv| {
        return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix, .julia_version = jv }) catch
            return Error.StdlibsUnavailable;
    }
    if (manifest.julia_version) |v| {
        const text = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix, .julia_version = text }) catch
            return Error.StdlibsUnavailable;
    }
    return stdlibs_mod.load(arena, io, .{ .julia_prefix = prefix }) catch return Error.StdlibsUnavailable;
}

/// The `VERSION` `status_compat_info` tests registry compat against. `--julia-version`
/// first, then the manifest's own `julia_version` — the Julia that resolved this
/// environment, and the only statement of "which Julia" a file can make.
fn effectiveJuliaVersion(arena: Allocator, opts: Options, manifest: manifest_mod.Manifest) Allocator.Error!?Version {
    if (opts.julia_version) |t| {
        return version_mod.parse(arena, t) catch null;
    }
    return manifest.julia_version;
}

// ---------------------------------------------------------------------------
// Tests
//
// The oracle for every expected string here is a real `Pkg.status(...; io)`,
// run by `tools/diff_harness/status.sh`. What lives here is the hermetic half:
// the branch structure and the two lexical ports (`relpath`, `pathrepr`), on
// fixtures small enough to reason about.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "relpath matches Base.relpath on the shapes pathrepr produces" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // Verified against `julia -e 'print(relpath(p, s))'` for each pair.
    try testing.expectEqualStrings("b/c", try relpath(g, "/a/b/c", "/a"));
    try testing.expectEqualStrings("..", try relpath(g, "/a", "/a/b"));
    try testing.expectEqualStrings("../../x", try relpath(g, "/a/x", "/a/b/c"));
    try testing.expectEqualStrings(".", try relpath(g, "/a/b", "/a/b"));
    // A trailing separator must not add a phantom component.
    try testing.expectEqualStrings("b", try relpath(g, "/a/b/", "/a"));
    // Runs of separators collapse, as `r"/+"` does.
    try testing.expectEqualStrings("b/c", try relpath(g, "/a//b//c", "/a"));
}

test "pathrepr collapses a stdlib path and contracts the home directory" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    const set: stdlibs_mod.Set = .{ .dir = "/opt/julia/share/julia/stdlib/v1.12" };
    try testing.expectEqualStrings(
        "`@stdlib/LinearAlgebra`",
        try pathrepr(g, .{ .stack = .{ .entries = &.{} } }, set, "/opt/julia/share/julia/stdlib/v1.12/LinearAlgebra"),
    );
    try testing.expectEqualStrings(
        "`~/work/Foo`",
        try pathrepr(g, .{ .stack = .{ .entries = &.{} }, .home = "/home/ada" }, .{ .dir = "" }, "/home/ada/work/Foo"),
    );
    try testing.expectEqualStrings(
        "`~`",
        try pathrepr(g, .{ .stack = .{ .entries = &.{} }, .home = "/home/ada" }, .{ .dir = "" }, "/home/ada"),
    );
    // Not under home: untouched, backticks only.
    try testing.expectEqualStrings(
        "`/srv/Foo`",
        try pathrepr(g, .{ .stack = .{ .entries = &.{} }, .home = "/home/ada" }, .{ .dir = "" }, "/srv/Foo"),
    );
}

test "a full lowercase sha1 rev abbreviates, anything else does not" {
    try testing.expect(isFullSha1("0adf069a2a490c47273727e029371b31d44b72b2"));
    try testing.expect(!isFullSha1("main"));
    try testing.expect(!isFullSha1("0ADF069A2A490C47273727E029371B31D44B72B2"));
    try testing.expect(!isFullSha1("0adf069"));
}

/// A whole environment on disk, rendered through `run` into a buffer. This is
/// the same shape `status.sh` compares against Pkg — only the oracle differs.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,

    fn init(buf: []u8) !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .root = "",
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
        const n = try f.tmp.dir.realPath(testing.io, buf);
        f.root = buf[0..n];
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (fspath.dirname(sub_path)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn join(self: *Fixture, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(self.arena(), self.root);
        try all.appendSlice(self.arena(), parts);
        return fspath.join(self.arena(), all.items);
    }

    /// A stdlib tree with LinearAlgebra in it, so `is_stdlib` has something to
    /// answer with. Everything in this module needs the set to exist.
    fn installStdlibs(self: *Fixture) ![]const u8 {
        try self.write(
            "julia/share/julia/stdlib/v1.12/LinearAlgebra/Project.toml",
            "name = \"LinearAlgebra\"\nuuid = \"37e2e46d-f89d-539d-b4ee-838fcccc9c8e\"\nversion = \"1.12.0\"\n",
        );
        return self.join(&.{"julia"});
    }

    fn render(self: *Fixture, opts_in: Options) ![]const u8 {
        var opts = opts_in;
        opts.env_path = try self.join(&.{"env"});
        opts.julia_prefix = try self.join(&.{"julia"});
        opts.julia_version = "1.12.6";
        opts.stack = .{ .entries = try self.arena().dupe([]const u8, &.{try self.join(&.{"depot"})}) };
        var buf: [64 * 1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try run(self.arena(), testing.allocator, testing.io, opts, &w);
        return self.arena().dupe(u8, w.buffered());
    }
};

test "an empty project prints the empty-project line and nothing else" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml", "[deps]\n");

    const out = try f.render(.{ .stack = undefined });
    const env = try f.join(&.{"env"});
    const want = try std.fmt.allocPrint(f.arena(), "Status `{s}/Project.toml` (empty project)\n", .{env});
    try testing.expectEqualStrings(want, out);
}

test "a stdlib sorts after an ordinary package and a _jll after both" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();

    // `Zzz` is the load-bearing row: it sorts AFTER `Zed_jll` by name, so only
    // the `endswith(name, "_jll")` component of the key can put `Zed_jll` last.
    // Without it the expected order and the plain alphabetical one coincide and
    // this test proves nothing — which is exactly what it did until a
    // deliberately broken sort key sailed straight through it.
    try f.write("env/Project.toml",
        \\[deps]
        \\LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\Zed_jll = "00000000-0000-0000-0000-0000000000aa"
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\Zzz = "00000000-0000-0000-0000-0000000000bb"
        \\
    );
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\[[deps.Zed_jll]]
        \\uuid = "00000000-0000-0000-0000-0000000000aa"
        \\version = "2.0.0"
        \\
        \\[[deps.Zzz]]
        \\uuid = "00000000-0000-0000-0000-0000000000bb"
        \\version = "3.0.0"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
    );

    const out = try f.render(.{ .stack = undefined });
    const env = try f.join(&.{"env"});
    // Alpha and Zed_jll declare a version but have no source anywhere — Julia's
    // `source_path` returns nothing for such an entry, so both carry `→` and
    // the report earns its footer. LinearAlgebra resolves to the fixture
    // stdlib tree and does not.
    const want = try std.fmt.allocPrint(f.arena(),
        \\Status `{s}/Project.toml`
        \\{s} [00000000] Alpha v1.0.0
        \\{s} [00000000] Zzz v3.0.0
        \\{s} [00000000] Zed_jll v2.0.0
        \\  [37e2e46d] LinearAlgebra
        \\Info Packages marked with {s} are not downloaded, use `instantiate` to download
        \\
    , .{ env, not_installed, not_installed, not_installed, not_installed });
    try testing.expectEqualStrings(want, out);
}

test "a positional filter that matches nothing prints No Matches" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
    );
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
    );

    const filters = try f.arena().dupe([]const u8, &.{"Nope"});
    const out = try f.render(.{ .stack = undefined, .filters = filters });
    const env = try f.join(&.{"env"});
    const want = try std.fmt.allocPrint(f.arena(), "No Matches in `{s}/Project.toml`\n", .{env});
    try testing.expectEqualStrings(want, out);
}

test "a path entry prints its path, a pinned one its glyph, and the project its header" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\name = "Host"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.4.0"
        \\
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\Beta = "00000000-0000-0000-0000-0000000000b2"
        \\
    );
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\path = "../alpha"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\[[deps.Beta]]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\pinned = true
        \\uuid = "00000000-0000-0000-0000-0000000000b2"
        \\version = "2.0.0"
        \\
    );

    // The path entry's directory EXISTS, which is what separates "resolved
    // through the manifest-relative path" from the blanket `→` an entry with no
    // source at all gets.
    try f.write("alpha/src/Alpha.jl", "module Alpha end\n");

    const out = try f.render(.{ .stack = undefined });
    const env = try f.join(&.{"env"});
    // Beta is pinned by a tree hash that is not in the depot, so it earns the
    // not-downloaded marker — and with no upgrade marker anywhere the gutter
    // stays two wide.
    const want = try std.fmt.allocPrint(f.arena(),
        \\Project Host v0.4.0
        \\Status `{s}/Project.toml`
        \\  [00000000] Alpha v1.0.0 `../alpha`
        \\{s} [00000000] Beta v2.0.0 ⚲
        \\Info Packages marked with {s} are not downloaded, use `instantiate` to download
        \\
    , .{ env, not_installed, not_installed });
    try testing.expectEqualStrings(want, out);
}

test "manifest mode prunes what instantiate would prune" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
    );
    // Ghost is in the manifest but reachable from nothing — outside the
    // loadable closure, so `load_all_deps_loadable` drops it. Gamma is a
    // transitive dep and must survive.
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\deps = ["Gamma"]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\[[deps.Gamma]]
        \\uuid = "00000000-0000-0000-0000-0000000000c3"
        \\version = "3.0.0"
        \\
        \\[[deps.Ghost]]
        \\uuid = "00000000-0000-0000-0000-0000000000f0"
        \\version = "9.0.0"
        \\
    );

    const out = try f.render(.{ .stack = undefined, .mode = .manifest });
    try testing.expect(std.mem.indexOf(u8, out, "Gamma v3.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Ghost") == null);
}

test "--compat indents its header and pads every name to the longest" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
        \\[compat]
        \\Alpha = "1.2"
        \\julia = "1.10"
        \\
    );

    const out = try f.render(.{ .stack = undefined, .compat = true });
    const env = try f.join(&.{"env"});
    const want = try std.fmt.allocPrint(f.arena(),
        \\      Compat `{s}/Project.toml`
        \\             julia 1.10
        \\  [00000000] Alpha 1.2
        \\
    , .{env});
    try testing.expectEqualStrings(want, out);
}

test "extensions are a filter, not an annotation" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\Beta = "00000000-0000-0000-0000-0000000000b2"
        \\
    );
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\path = "../alpha"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\    [deps.Alpha.extensions]
        \\    AlphaGammaExt = "Gamma"
        \\
        \\    [deps.Alpha.weakdeps]
        \\    Gamma = "00000000-0000-0000-0000-0000000000c3"
        \\
        \\[[deps.Beta]]
        \\uuid = "00000000-0000-0000-0000-0000000000b2"
        \\version = "2.0.0"
        \\
    );

    try f.write("alpha/src/Alpha.jl", "module Alpha end\n");

    const out = try f.render(.{ .stack = undefined, .extensions = true });
    const env = try f.join(&.{"env"});
    // Beta declares no extensions, so `--extensions` drops it entirely — the
    // flag filters the report rather than annotating it.
    const want = try std.fmt.allocPrint(f.arena(),
        \\Status `{s}/Project.toml`
        \\  [00000000] Alpha v1.0.0 `../alpha`
        \\              └─ AlphaGammaExt [Gamma]
        \\
    , .{env});
    try testing.expectEqualStrings(want, out);
}

test "a stale project_hash produces the resolve warning" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
    );
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\project_hash = "0000000000000000000000000000000000000000"
        \\
        \\[[deps.Alpha]]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
    );

    const out = try f.render(.{ .stack = undefined });
    try testing.expect(std.mem.indexOf(u8, out, "Warning The project dependencies") != null);

    // And a manifest with no project_hash at all says nothing — Pkg's tri-state
    // `nothing`, which is silence rather than a warning.
    try f.write("env/Manifest.toml",
        \\julia_version = "1.12.6"
        \\manifest_format = "2.0"
        \\
        \\[[deps.Alpha]]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
    );
    const out2 = try f.render(.{ .stack = undefined });
    try testing.expect(std.mem.indexOf(u8, out2, "Warning") == null);
}

test "a [workspace] is refused rather than reported on" {
    var buf: [512]u8 = undefined;
    var f = try Fixture.init(&buf);
    defer f.deinit();
    _ = try f.installStdlibs();
    try f.write("env/Project.toml",
        \\[deps]
        \\
        \\[workspace]
        \\projects = ["sub"]
        \\
    );
    try testing.expectError(Error.WorkspaceUnsupported, f.render(.{ .stack = undefined }));
}
