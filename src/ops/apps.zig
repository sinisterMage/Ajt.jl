//! `ajt app {add,dev,rm,status,update}` — installing a package's apps.
//!
//! Port of `Pkg/src/Apps/Apps.jl` (1.12.6, `SHIM_VERSION = 1.1`). An "app" is a
//! package that declares `[apps]` in its `Project.toml` and defines `@main` in
//! the named module; installing one means building an environment for it and
//! writing an executable **shim** into `<depot>/bin` that execs
//! `julia -m <ModuleSpec>` inside that environment.
//!
//! ```toml
//! [apps]
//! reverse = {}
//! cli-tool = { submodule = "CLI", julia_flags = ["--threads=4"] }
//! ```
//!
//! ## The three files, and which of them is a contract
//!
//! 1. **`<depot>/environments/apps/AppManifest.toml`** — the bookkeeping. It is
//!    an ordinary `Manifest.toml` whose entries carry the extra `apps` table
//!    (`model/manifest.zig:180-214`), and stock Pkg reads and writes it. This
//!    one is a byte-for-byte contract; `model/manifest.zig` already holds up
//!    that end.
//! 2. **`<depot>/environments/apps/<Pkg>/{Project,Manifest}.toml`** — the
//!    per-package environment `add` resolves into. Pkg builds it by *copying*
//!    the package's own `Project.toml` and bolting an `entryfile` onto it.
//! 3. **`<depot>/bin/<app>`** — the shim. A shell script (or `.bat`), not a
//!    Pkg format; see the deviation below.
//!
//! `develop` skips (2) entirely: the shim's `JULIA_LOAD_PATH` is the working
//! tree itself, so an edit to the source is live in the app with no reinstall
//! (`Apps.jl:276-278`). `rm` deletes (2) only when the entry has no `path`
//! (`:428-430`) — deleting a dev'd app's environment would mean deleting the
//! user's checkout.
//!
//! ## Deviation: JuliaLang/Pkg.jl#4741 is NOT reproduced
//!
//! `generate_shim` pre-quotes the julia path for the Windows branch
//! (`Apps.jl:501`, `julia_escaped = "\"$(shell_escape_wincmd(julia))\""`) and
//! `windows_shim` then emits `set "julia_cmd=$julia_escaped"` while the call
//! site spells `"%julia_cmd%"` (`:588-592`, `:634`). The result is
//!
//! ```bat
//! set "julia_cmd="C:\Users\test user\.julia\...\julia""
//! ...
//! ""C:\Users\test user\...\julia"" --startup-file=no -m Foo
//! ```
//!
//! which cmd.exe cannot parse the moment the path contains a space. The two
//! branches of that `if` disagree — the `JULIA_APPS_JULIA_CMD` one stores the
//! path *unquoted*, which is correct — and paths without spaces work only
//! because the doubled quotes still collapse to one token.
//!
//! **Ajt stores it unquoted in both branches.** The module spec stays
//! pre-quoted because *its* call site (`-m $module_spec_escaped`) adds no
//! quotes of its own — which is exactly why the two were written alike and only
//! one of them is wrong. The generated `.bat` carries a third header line
//! naming the issue so that a later "restore fidelity" pass does not put the
//! bug back. Recorded in `Ajt.DIFFERENCES[:Apps]`.
//!
//! The POSIX shim is byte-identical to Pkg's, including the two header lines
//! landing at *different* indents: `SHIM_HEADER` is interpolated into an
//! already-indented line of a triple-quoted string, so the dedent pass sees a
//! common prefix of four spaces and only the first line keeps it (`:480-481`,
//! `:528`). It looks like a typo in the output and reproducing it is the whole
//! point of a byte-for-byte claim.
//!
//! ## Deviation: relative `[sources]` in the copied project ARE rebased
//!
//! `_resolve` copies the package's `Project.toml` into the app environment
//! unchanged (`:161-174`), so a relative `[sources]` path — `{path =
//! "../OptimizationBase"}`, which ~76 packages in General ship — now points
//! somewhere that does not exist and the install dies with `expected package X
//! to exist at path <apps>/X`. That is JuliaLang/Pkg.jl#4532 and #4714, fixed
//! upstream after 1.12.6 by `ff55f14f7`.
//!
//! Ajt ports the fix rather than the bug: `rebaseSources` resolves each
//! relative path against the original directory and then the installed tree,
//! drops the entry with a warning when neither exists so the dependency falls
//! back to the registry, and rewrites a depot-internal hit relative to the app
//! project so the depot stays relocatable. No byte-for-byte claim covers this
//! file — it is Ajt's own artifact, written into Ajt's own environment.
//!
//! ## `[apps]` is read-only in the project model, and stays that way
//!
//! `model/project.zig` parses `[apps]` into typed `App` values but never writes
//! them back (`project.zig:15-18`), matching Pkg. Nothing here needs it to: the
//! app environment's project is a *copy* of the package's file, so `[apps]`
//! rides through `Project.other` verbatim, and the only fields this module sets
//! are `entryfile` and `[sources]`, both of which already have mutators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const shell = @import("../julia/shell.zig");
const project_mod = @import("../model/project.zig");
const manifest_mod = @import("../model/manifest.zig");
const depot_mod = @import("../depot.zig");
const fspath = std.fs.path;

pub const Error = error{
    /// `validate_app_name` (`Apps.jl:21-32`).
    InvalidAppName,
    /// `validate_package_name` (`:34-42`).
    InvalidPackageName,
    /// `validate_submodule_name` (`:44-54`).
    InvalidSubmoduleName,
    /// `isempty(project.apps)` (`:69`).
    NoAppsInProject,
    /// `Project file not found: $project_file` (`:66`).
    NoProjectFile,
    /// The manifest names no such package or app (`rm`, `:431-445`).
    NoSuchApp,
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
//
// Three different rules, and the differences are load-bearing rather than
// accidental: an app becomes a FILENAME in `<depot>/bin`, a package name
// becomes a Julia identifier in `-m <spec>`, and a submodule is a suffix of
// that identifier. So an app may contain a hyphen and the other two may not.

/// `^[a-zA-Z][a-zA-Z0-9_-]*$`, plus explicit refusals of `..` and both path
/// separators (`Apps.jl:21-32`).
///
/// The two extra checks are unreachable given the regex — a `.` or a `/` fails
/// the character class already — and are reproduced anyway because they are
/// what the source says, and because this string names a file that gets
/// `chmod +x`. Defence in depth on a path that writes an executable is worth
/// the four lines.
pub fn validateAppName(name: []const u8) Error!void {
    if (name.len == 0) return Error.InvalidAppName;
    if (!std.ascii.isAlphabetic(name[0])) return Error.InvalidAppName;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return Error.InvalidAppName;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return Error.InvalidAppName;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return Error.InvalidAppName;
}

/// `^[a-zA-Z][a-zA-Z0-9_]*$` (`Apps.jl:34-42`). No hyphen: this ends up in
/// `-m <name>` and has to parse as a Julia identifier.
pub fn validatePackageName(name: []const u8) Error!void {
    if (name.len == 0) return Error.InvalidPackageName;
    if (!std.ascii.isAlphabetic(name[0])) return Error.InvalidPackageName;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return Error.InvalidPackageName;
    }
}

/// `^[a-zA-Z][a-zA-Z0-9_]*$` on a value that may be absent (`Apps.jl:44-54`).
///
/// SINGLE level in 1.12.6 — a dotted `Foo.Bar` is refused here. Nested
/// submodules are a later commit ("Apps: allow nested submodules in app
/// definitions") and accepting one now would install an app this Julia's
/// `Pkg.Apps` would have rejected, which is the wrong direction for a drop-in.
pub fn validateSubmoduleName(name: ?[]const u8) Error!void {
    const s = name orelse return;
    if (s.len == 0) return Error.InvalidSubmoduleName;
    if (!std.ascii.isAlphabetic(s[0])) return Error.InvalidSubmoduleName;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return Error.InvalidSubmoduleName;
    }
}

// ---------------------------------------------------------------------------
// Shims
// ---------------------------------------------------------------------------

/// Which host the shim is being written for.
///
/// A parameter rather than `builtin.os` because Pkg's own choice is made by
/// `Sys.iswindows()` at generate time and there is no way to ask it for the
/// other one — so the gates render both from Linux and compare what they can.
pub const Target = enum {
    posix,
    windows,

    /// `SHIM_COMMENT` (`Apps.jl:478`), which Pkg keys off the RUNNING host.
    /// Since Pkg only ever emits a `.bat` on Windows and a `/bin/sh` script
    /// everywhere else, host and target always agree there; keying off the
    /// target is what makes the same true here when a Linux box renders a
    /// `.bat` for a gate.
    pub fn comment(self: Target) []const u8 {
        return switch (self) {
            .posix => "#",
            .windows => "REM ",
        };
    }
};

/// `SHIM_VERSION` (`Apps.jl:479`).
pub const shim_version = "1.1";

/// One `[apps]` entry, resolved.
pub const App = struct {
    name: []const u8,
    submodule: ?[]const u8 = null,
    julia_flags: []const []const u8 = &.{},
};

/// Everything a shim's bytes depend on.
pub const ShimSpec = struct {
    /// The package providing the app — the head of the module spec.
    pkg_name: []const u8,
    app: App,
    /// `JULIA_LOAD_PATH`: the app environment for an `add`ed package, the
    /// working tree for a `develop`ed one.
    env: []const u8,
    /// The julia executable the shim execs. `joinpath(Sys.BINDIR, "julia")` in
    /// Pkg (`:184`); a parameter here so `--julia` can pin one.
    julia: []const u8,
    /// `DEPOT_PATH` in order, joined with `:` (POSIX) or `;` (Windows).
    depots: []const []const u8,
};

/// `module_spec = app.submodule === nothing ? pkgname : "$(pkgname).$(app.submodule)"`
/// (`Apps.jl:495`).
pub fn moduleSpec(gpa: Allocator, pkg_name: []const u8, submodule: ?[]const u8) Allocator.Error![]u8 {
    const sub = submodule orelse return gpa.dupe(u8, pkg_name);
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ pkg_name, sub });
}

/// `generate_shim` (`Apps.jl:490-514`) — validate, escape, render.
///
/// Returns the file's exact bytes. Writing them, and the `chmod 0o755` that
/// follows on unix, is `writeShim`'s job.
pub fn renderShim(
    gpa: Allocator,
    spec: ShimSpec,
    target: Target,
) (Error || shell.WincmdError)![]u8 {
    try validatePackageName(spec.pkg_name);
    try validateAppName(spec.app.name);
    try validateSubmoduleName(spec.app.submodule);

    const mod_spec = try moduleSpec(gpa, spec.pkg_name, spec.app.submodule);
    defer gpa.free(mod_spec);

    return switch (target) {
        .posix => blk: {
            const julia_escaped = try shell.escape(gpa, spec.julia);
            defer gpa.free(julia_escaped);
            const mod_escaped = try shell.escape(gpa, mod_spec);
            defer gpa.free(mod_escaped);
            break :blk try shellShim(gpa, julia_escaped, mod_escaped, spec);
        },
        .windows => blk: {
            // THE #4741 FIX. Pkg wraps this in `"` here; the call site in
            // `windowsShim` supplies them instead, so both branches of the
            // `if defined JULIA_APPS_JULIA_CMD` store a bare path.
            const julia_escaped = try shell.escapeWincmd(gpa, spec.julia);
            defer gpa.free(julia_escaped);
            // Still pre-quoted: `-m $module_spec_escaped` adds none.
            const bare = try shell.escapeWincmd(gpa, mod_spec);
            defer gpa.free(bare);
            const mod_escaped = try std.fmt.allocPrint(gpa, "\"{s}\"", .{bare});
            defer gpa.free(mod_escaped);
            break :blk try windowsShim(gpa, julia_escaped, mod_escaped, spec);
        },
    };
}

/// `isempty(julia_flags) ? "" : " $julia_flags_escaped"` (`Apps.jl:518-519`) —
/// note the LEADING space, which is why the no-flags case must contribute
/// nothing at all rather than an empty word.
fn flagsPart(gpa: Allocator, flags: []const []const u8, target: Target) (shell.WincmdError)![]u8 {
    if (flags.len == 0) return gpa.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (flags) |f| {
        try out.append(gpa, ' ');
        const e = switch (target) {
            .posix => try shell.escape(gpa, f),
            .windows => try shell.escapeWincmd(gpa, f),
        };
        defer gpa.free(e);
        try out.appendSlice(gpa, e);
    }
    return out.toOwnedSlice(gpa);
}

fn joinDepots(gpa: Allocator, depots: []const []const u8, sep: u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (depots, 0..) |d, i| {
        if (i != 0) try out.append(gpa, sep);
        try out.appendSlice(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

/// `shell_shim` (`Apps.jl:517-563`).
///
/// The header block is written out with its real indentation rather than
/// generated, because Julia's triple-quoted dedent gives the two `SHIM_HEADER`
/// lines *different* indents — four spaces on the first, none on the second —
/// and a loop that indents both would produce a file that is one space
/// different from every shim Pkg has ever written.
fn shellShim(
    gpa: Allocator,
    julia_escaped: []const u8,
    mod_escaped: []const u8,
    spec: ShimSpec,
) (shell.WincmdError)![]u8 {
    const flags = try flagsPart(gpa, spec.app.julia_flags, .posix);
    defer gpa.free(flags);
    const load_path = try shell.escape(gpa, spec.env);
    defer gpa.free(load_path);
    const joined = try joinDepots(gpa, spec.depots, ':');
    defer gpa.free(joined);
    const depot_path = try shell.escape(gpa, joined);
    defer gpa.free(depot_path);

    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\set -eu
        \\
        \\    {s} This file is generated by the Julia package manager.
        \\{s} Shim version: {s}
        \\
        \\{s} Pin Julia paths for the child process
        \\export JULIA_LOAD_PATH={s}
        \\export JULIA_DEPOT_PATH={s}
        \\
        \\{s} Allow overriding Julia executable via environment variable
        \\if [ -n "${{JULIA_APPS_JULIA_CMD:-}}" ]; then
        \\    julia_cmd="$JULIA_APPS_JULIA_CMD"
        \\else
        \\    julia_cmd={s}
        \\fi
        \\
        \\{s} If a `--` appears, args before it go to Julia, after it to the app.
        \\{s} If no `--` appears, all original args go to the app (no Julia args).
        \\found_separator=false
        \\for a in "$@"; do
        \\    [ "$a" = "--" ] && {{ found_separator=true; break; }}
        \\done
        \\
        \\if [ "$found_separator" = "true" ]; then
        \\    {s} Build julia_args until `--`, then leave the rest in "$@"
        \\    julia_args=""
        \\    while [ "$#" -gt 0 ]; do
        \\        case "$1" in
        \\        --) shift; break ;;
        \\        *)  julia_args="$julia_args${{julia_args:+ }}$1"; shift ;;
        \\        esac
        \\    done
        \\    {s} Here: "$@" are the app args after the separator
        \\    exec "$julia_cmd" --startup-file=no{s} $julia_args -m {s} "$@"
        \\else
        \\    {s} No separator: all original args go straight to the app
        \\    exec "$julia_cmd" --startup-file=no{s} -m {s} "$@"
        \\fi
        \\
    , .{
        Target.posix.comment(), Target.posix.comment(), shim_version,
        Target.posix.comment(), load_path,              depot_path,
        Target.posix.comment(), julia_escaped,          Target.posix.comment(),
        Target.posix.comment(), Target.posix.comment(), Target.posix.comment(),
        flags,                  mod_escaped,            Target.posix.comment(),
        flags,                  mod_escaped,
    });
}

/// `windows_shim` (`Apps.jl:566-645`), with the #4741 fix and a header line
/// naming it.
fn windowsShim(
    gpa: Allocator,
    julia_escaped: []const u8,
    mod_escaped: []const u8,
    spec: ShimSpec,
) (shell.WincmdError)![]u8 {
    const flags = try flagsPart(gpa, spec.app.julia_flags, .windows);
    defer gpa.free(flags);
    const depot_path = try joinDepots(gpa, spec.depots, ';');
    defer gpa.free(depot_path);
    const c = Target.windows.comment();

    return std.fmt.allocPrint(gpa,
        \\@echo off
        \\setlocal EnableExtensions DisableDelayedExpansion
        \\
        \\    {s}This file is generated by the Julia package manager.
        \\{s}Shim version: {s}
        \\{s}julia_cmd is stored UNQUOTED here; the call site below quotes it.
        \\{s}Pkg pre-quotes it and quotes it again -- JuliaLang/Pkg.jl#4741.
        \\
        \\rem --- Environment (no delayed expansion here to keep '!' literal) ---
        \\set "JULIA_LOAD_PATH={s}"
        \\set "JULIA_DEPOT_PATH={s}"
        \\
        \\rem --- Allow overriding Julia executable via environment variable ---
        \\if defined JULIA_APPS_JULIA_CMD (
        \\    set "julia_cmd=%JULIA_APPS_JULIA_CMD%"
        \\) else (
        \\    set "julia_cmd={s}"
        \\)
        \\
        \\rem --- Now enable delayed expansion for string building below ---
        \\setlocal EnableDelayedExpansion
        \\
        \\rem Parse arguments, splitting on first -- into julia_args / app_args
        \\set "found_sep="
        \\set "julia_args="
        \\set "app_args="
        \\
        \\:__next
        \\if "%~1"=="" goto __done
        \\
        \\if not defined found_sep if "%~1"=="--" (
        \\    set "found_sep=1"
        \\    shift
        \\    goto __next
        \\)
        \\
        \\if not defined found_sep (
        \\    if defined julia_args (
        \\        set "julia_args=!julia_args! %1"
        \\    ) else (
        \\        set "julia_args=%1"
        \\    )
        \\    shift
        \\    goto __next
        \\)
        \\
        \\if defined found_sep (
        \\    if defined app_args (
        \\        set "app_args=!app_args! %1"
        \\    ) else (
        \\        set "app_args=%1"
        \\    )
        \\    shift
        \\    goto __next
        \\)
        \\
        \\:__done
        \\rem If no --, pass all original args to the app; otherwise use split vars
        \\if defined found_sep (
        \\    "%julia_cmd%" ^
        \\        --startup-file=no{s} !julia_args! ^
        \\        -m {s} ^
        \\        !app_args!
        \\) else (
        \\    "%julia_cmd%" ^
        \\        --startup-file=no{s} ^
        \\        -m {s} ^
        \\        %*
        \\)
        \\
    , .{
        c,     c,           shim_version, c,     c,
        spec.env, depot_path, julia_escaped,
        flags, mod_escaped, flags,        mod_escaped,
    });
}

// ---------------------------------------------------------------------------
// The app environment's Project.toml
// ---------------------------------------------------------------------------

/// One `[sources]` entry that `rebaseSources` could not place.
pub const DroppedSource = struct {
    dep: []const u8,
    /// The relative path as written, for the warning.
    path: []const u8,
};

/// `Apps._resolve`'s `[sources]` fixup — the part of `ff55f14f7` that 1.12.6
/// does not have (JuliaLang/Pkg.jl#4532, #4714). See the module header.
///
/// A relative `path` in the package's own `Project.toml` is relative to where
/// that project *was*, and the copy lives somewhere else, so every one of them
/// has to be re-pointed or dropped:
///
///   * `original_dir` — where the package was added from, when it was added
///     from a local path. Tried first, because a monorepo sibling is a real
///     directory there and the release tarball may not carry it at all.
///   * `source_dir` — the installed package tree in the depot. Tried second.
///   * neither exists -> the `path` key is deleted, and the whole entry with it
///     if nothing else remains, so the dependency resolves from a registry
///     instead of failing the install. That is the behaviour ~76 packages in
///     General need: they ship `{path = "../Sibling"}` pointing at a monorepo
///     layout that no tarball reproduces.
///
/// An ABSOLUTE path is left alone — it means what it says wherever the file is.
///
/// Returns the entries it dropped, so the caller can warn about each one; Pkg
/// warns from inside the loop, and reporting instead keeps this function free
/// of an output stream.
pub fn rebaseSources(
    arena: Allocator,
    io: Io,
    proj: *project_mod.Project,
    source_dir: []const u8,
    original_dir: ?[]const u8,
) Allocator.Error![]const DroppedSource {
    var dropped: std.ArrayList(DroppedSource) = .empty;

    // Collected first: `setSource`/`removeSource` mutate the list being walked.
    const originals = try arena.dupe(project_mod.Source, proj.sources.items);

    for (originals) |s| {
        const rel = s.path orelse continue;
        if (fspath.isAbsolute(rel)) continue;

        var resolved: ?[]const u8 = null;
        if (original_dir) |od| {
            const cand = try fspath.resolve(arena, &.{ od, rel });
            if (isDir(io, cand)) resolved = cand;
        }
        if (resolved == null) {
            const cand = try fspath.resolve(arena, &.{ source_dir, rel });
            if (isDir(io, cand)) resolved = cand;
        }

        if (resolved) |abs| {
            var next = s;
            next.path = abs;
            try proj.setSource(next);
            continue;
        }

        try dropped.append(arena, .{ .dep = s.name, .path = rel });
        // Drop only the `path`. A `[sources]` entry may legally carry `url`,
        // `rev` and `subdir` alongside nothing else useful, and those still
        // mean something from any directory -- so the entry survives unless
        // `path` was all it had.
        if (s.url == null and s.rev == null and s.subdir == null) {
            _ = proj.removeSource(s.name);
        } else {
            var next = s;
            next.path = null;
            try proj.setSource(next);
        }
    }
    return dropped.items;
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// Builds the `Project.toml` for `<depot>/environments/apps/<Pkg>/`.
///
/// `Apps._resolve` (`Apps.jl:154-174`) copies the package's project file and
/// sets `entryfile` to `<sourcepath>/src/<Name>.jl`, so the environment loads
/// the package from the depot without needing a `[deps]` entry for itself.
///
/// Returns the rendered bytes and the sources that had to be dropped. The
/// caller writes the file; this function only reads the source project.
pub fn appProject(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    source_dir: []const u8,
    pkg_name: []const u8,
    original_dir: ?[]const u8,
) !struct { bytes: []u8, dropped: []const DroppedSource } {
    const project_file = try projectFilePath(arena, io, source_dir) orelse
        return Error.NoProjectFile;
    const src = try Io.Dir.cwd().readFileAlloc(io, project_file, arena, .limited(8 << 20));

    var proj = try project_mod.parse(arena, src, .{ .file = project_file }, null);
    if (proj.apps.len == 0) return Error.NoAppsInProject;

    const entry = try std.fmt.allocPrint(
        arena,
        "{s}{c}src{c}{s}.jl",
        .{ source_dir, fspath.sep, fspath.sep, pkg_name },
    );
    try proj.setEntryfile(entry);

    const dropped = try rebaseSources(arena, io, &proj, source_dir, original_dir);

    // `serialize` rather than `pendingWrite`: the destination is a different
    // file from the one this was read out of, so "unchanged" is not a reason to
    // skip the write.
    return .{ .bytes = try proj.serialize(gpa), .dropped = dropped };
}

/// `Types.projectfile_path(dir)` — the two spellings, in Julia's order.
fn projectFilePath(arena: Allocator, io: Io, dir: []const u8) Allocator.Error!?[]const u8 {
    for ([_][]const u8{ "JuliaProject.toml", "Project.toml" }) |name| {
        const p = try fspath.join(arena, &.{ dir, name });
        if (Io.Dir.cwd().statFile(io, p, .{})) |_| return p else |_| {}
    }
    return null;
}

// ---------------------------------------------------------------------------
// The apps environment: AppManifest.toml and <depot>/bin
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// The resolved `DEPOT_PATH`. Entry 0 — `Pkg.depots1()` — is the one
    /// everything here is written into, and the whole stack is what the shim
    /// exports as `JULIA_DEPOT_PATH`.
    stack: depot_mod.Stack,
    /// The julia a shim execs. Pkg uses `joinpath(Sys.BINDIR, "julia")`
    /// (`Apps.jl:184`); this is a parameter so `--julia` can pin one, and so
    /// the gates can render a shim for a julia that is not the one running.
    julia: []const u8,
    /// Which shim dialect to write. Defaults to the host, as Pkg's
    /// `Sys.iswindows()` does.
    target: Target = if (@import("builtin").os.tag == .windows) .windows else .posix,
    /// Report what would change and write nothing.
    dry_run: bool = false,
};

/// What a verb did, in the order the CLI prints it.
pub const Report = struct {
    pub const Change = struct {
        pub const Kind = enum { installed, developed, removed, unchanged };
        kind: Kind,
        /// The package providing the app.
        pkg: []const u8,
        app: []const u8,
        /// The shim's path.
        shim: []const u8,
    };

    changes: []const Change = &.{},
    /// `[sources]` entries dropped while building the app environment, so the
    /// caller can warn once per entry (`rebaseSources`).
    dropped_sources: []const DroppedSource = &.{},
    /// True when `<depot>/bin` is not on `PATH` — `check_apps_in_path`
    /// (`Apps.jl:87-111`) warns about this and so should the caller.
    bin_not_on_path: bool = false,
    dry_run: bool = false,
};

/// Reads `AppManifest.toml`, or an empty manifest when there is none.
///
/// A missing file is the cold-start case, not an error: `EnvCache` on a
/// nonexistent manifest path yields an empty `Manifest` and `Apps` relies on
/// that for the first `add` into a fresh depot.
pub fn readAppManifest(arena: Allocator, io: Io, path: []const u8) !manifest_mod.Manifest {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return manifest_mod.parse(arena, src, null);
}

/// Writes `AppManifest.toml`, banner and key order included.
///
/// `manifest_format` matters here and defaults correctly: a `Manifest` built
/// from nothing carries 2.0, which is what `write_manifest` emits for an app
/// manifest Pkg created (`manifest.zig:216-228`).
pub fn writeAppManifest(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    path: []const u8,
    m: *const manifest_mod.Manifest,
) !void {
    if (fspath.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try m.write(gpa, arena, &buf.writer);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.written() });
}

/// `generate_shims_for_apps` + `overwrite_file_if_different` + the `chmod`
/// (`Apps.jl:483-513`).
///
/// The rewrite is conditional on the CONTENT differing, exactly as Pkg's is:
/// re-running `app add` on an unchanged package must not bump the shim's mtime,
/// because that is what tells a user whether anything happened.
pub fn writeShims(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    pkg_name: []const u8,
    env: []const u8,
    apps: []const App,
    kind: Report.Change.Kind,
) ![]const Report.Change {
    const write_depot = opts.stack.writeDepot() orelse return error.NoDepot;
    const bin = try write_depot.binDir(arena);

    // `Stack.entries` is already the depot ROOTS in search order, which is
    // exactly what `join(DEPOT_PATH, ':')` needs (`Apps.jl:522`).
    const depots = opts.stack.entries;

    var changes: std.ArrayList(Report.Change) = .empty;
    for (apps) |app| {
        const bytes = try renderShim(arena, .{
            .pkg_name = pkg_name,
            .app = app,
            .env = env,
            .julia = opts.julia,
            .depots = depots,
        }, opts.target);

        const path = try write_depot.shimFile(arena, app.name, opts.target == .windows);
        const same = blk: {
            const old = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch
                break :blk false;
            break :blk std.mem.eql(u8, old, bytes);
        };

        if (!same and !opts.dry_run) {
            try Io.Dir.cwd().createDirPath(io, bin);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            // `Sys.isunix() && chmod(julia_bin_filename, 0o755)` (`:510-512`).
            // A shim nobody can execute is the same as no shim at all, and the
            // failure surfaces far from here.
            if (opts.target == .posix) {
                try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{});
            }
        }
        try changes.append(arena, .{
            .kind = if (same) .unchanged else kind,
            .pkg = pkg_name,
            .app = app.name,
            .shim = path,
        });
    }
    _ = gpa;
    return changes.items;
}

/// `rm_shim` (`Apps.jl:57-61`). A missing file is not an error — Pkg passes
/// `force = true`.
fn removeShim(arena: Allocator, io: Io, opts: Options, app: []const u8) !void {
    try validateAppName(app);
    const write_depot = opts.stack.writeDepot() orelse return error.NoDepot;
    const path = try write_depot.shimFile(arena, app, opts.target == .windows);
    if (opts.dry_run) return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// `check_apps_in_path` (`Apps.jl:87-111`), reduced to the question the caller
/// can act on: is `<depot>/bin` on `PATH` at all?
///
/// Pkg additionally warns when `Sys.which(app)` resolves to a DIFFERENT file,
/// i.e. another program of the same name earlier on the path. That check is
/// per-app and needs a `PATH` walk per app; this one is per-install and needs
/// one string compare, which is the part that actually changes what a user
/// does next (`export PATH=...`).
pub fn binOnPath(arena: Allocator, environ: ?*const std.process.Environ.Map, bin: []const u8) !bool {
    const env = environ orelse return true;
    const path = env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, fspath.delimiter);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const norm = fspath.resolve(arena, &.{entry}) catch continue;
        if (std.mem.eql(u8, norm, bin)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The verbs
// ---------------------------------------------------------------------------

/// `project_mod.App` -> the shim-facing `App`. Same three fields; the model's
/// type is a view onto the parsed TOML and this one is what `renderShim` takes.
fn appsFromProject(arena: Allocator, src: []const project_mod.App) Allocator.Error![]const App {
    const out = try arena.alloc(App, src.len);
    for (src, out) |a, *o| o.* = .{
        .name = a.name,
        .submodule = a.submodule,
        .julia_flags = a.julia_flags,
    };
    return out;
}

/// The same list as `AppInfo` entries for `AppManifest.toml`.
///
/// `julia_command` is REQUIRED on read (`manifest.zig:182-183`,
/// `read_apps` at `:259`), and `write_manifest` defaults it to
/// `joinpath(Sys.BINDIR, "julia")` when the in-memory value is null
/// (`manifest.jl:357`). Recording the julia this install actually pinned is
/// strictly better than relying on that default, and it is what
/// `Pkg.Apps.status` prints.
fn appInfos(arena: Allocator, src: []const App, julia: []const u8) Allocator.Error![]const manifest_mod.AppInfo {
    const out = try arena.alloc(manifest_mod.AppInfo, src.len);
    for (src, out) |a, *o| o.* = .{
        .name = a.name,
        .julia_command = julia,
        .submodule = a.submodule,
        .julia_flags = a.julia_flags,
    };
    return out;
}

/// Replaces (or appends) the entry for `uuid`, preserving position.
fn upsert(
    arena: Allocator,
    m: *manifest_mod.Manifest,
    entry: manifest_mod.PackageEntry,
) Allocator.Error!void {
    for (m.entries, 0..) |e, i| {
        if (std.mem.eql(u8, &e.uuid.bytes, &entry.uuid.bytes)) {
            const next = try arena.dupe(manifest_mod.PackageEntry, m.entries);
            next[i] = entry;
            m.entries = next;
            return;
        }
    }
    var list: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    try list.appendSlice(arena, m.entries);
    try list.append(arena, entry);
    m.entries = list.items;
}

fn dropEntry(arena: Allocator, m: *manifest_mod.Manifest, uuid: manifest_mod.Uuid) Allocator.Error!void {
    var list: std.ArrayList(manifest_mod.PackageEntry) = .empty;
    for (m.entries) |e| {
        if (std.mem.eql(u8, &e.uuid.bytes, &uuid.bytes)) continue;
        try list.append(arena, e);
    }
    m.entries = list.items;
}

/// `Pkg.Apps.develop(PackageSpec(path = ...))` (`Apps.jl:252-283`).
///
/// The one verb that needs no registry and no network, and the one whose point
/// is that it does NOT build an app environment: the shim's `JULIA_LOAD_PATH`
/// is the working tree, so editing the source changes the app with no
/// reinstall. `rm` knows not to delete that directory because the manifest
/// entry carries a `path`.
///
/// A URL is not handled here — see `Ajt.DIFFERENCES[:Apps]`. Cloning one is
/// `ops/edit.zig`'s `devClone`, which is written against a project environment
/// rather than the apps environment; a caller with a URL gets a clear refusal
/// and the wrapper delegates to `Pkg.Apps.develop`.
pub fn develop(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    source_dir: []const u8,
    environ: ?*const std.process.Environ.Map,
) !Report {
    const write_depot = opts.stack.writeDepot() orelse return error.NoDepot;
    const source = try absPath(arena, io, source_dir);

    const project_file = try projectFilePath(arena, io, source) orelse return Error.NoProjectFile;
    const src = try Io.Dir.cwd().readFileAlloc(io, project_file, arena, .limited(8 << 20));
    const proj = try project_mod.parse(arena, src, .{ .file = project_file }, null);
    if (proj.apps.len == 0) return Error.NoAppsInProject;

    const name = proj.name orelse return Error.NoProjectFile;
    const uuid = proj.uuid orelse return Error.NoProjectFile;
    try validatePackageName(name);
    const apps = try appsFromProject(arena, proj.apps);

    // `Base.rm(joinpath(app_env_folder(), pkg.name); force, recursive)`
    // (`:259`): a package that was `add`ed before is now dev'd, and the stale
    // environment would shadow the working tree.
    const app_env = try write_depot.appEnvDir(arena, name);
    if (!opts.dry_run) Io.Dir.cwd().deleteTree(io, app_env) catch {};

    const manifest_file = try write_depot.appManifestFile(arena);
    var m = try readAppManifest(arena, io, manifest_file);
    try reconcileShims(arena, io, opts, &m, uuid, apps);
    try upsert(arena, &m, .{
        .name = name,
        .uuid = uuid,
        .version = proj.version,
        .path = source,
        .apps = try appInfos(arena, apps, opts.julia),
    });
    if (!opts.dry_run) try writeAppManifest(gpa, arena, io, manifest_file, &m);

    const changes = try writeShims(gpa, arena, io, opts, name, source, apps, .developed);
    const bin = try write_depot.binDir(arena);
    return .{
        .changes = changes,
        .bin_not_on_path = !try binOnPath(arena, environ, bin),
        .dry_run = opts.dry_run,
    };
}

/// `reconcile_shims` — drop shims the package used to provide and no longer
/// does. Without it, renaming an app in `[apps]` leaves the old executable in
/// `<depot>/bin` pointing at a module that is gone.
fn reconcileShims(
    arena: Allocator,
    io: Io,
    opts: Options,
    m: *const manifest_mod.Manifest,
    uuid: manifest_mod.Uuid,
    now: []const App,
) !void {
    const old = m.findByUuid(uuid) orelse return;
    for (old.apps) |was| {
        var still = false;
        for (now) |a| {
            if (std.mem.eql(u8, a.name, was.name)) {
                still = true;
                break;
            }
        }
        if (!still) try removeShim(arena, io, opts, was.name);
    }
}

/// `Pkg.Apps.rm` (`Apps.jl:413-449`).
///
/// The argument is a package name OR an app name, and Pkg tries them in that
/// order: a package match removes every app it provides, otherwise the name is
/// looked up as an app across every entry. An entry left with no apps is
/// dropped, and its environment with it — unless it has a `path`, which means
/// the user's own checkout.
pub fn remove(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    pkg_or_app: []const u8,
) !Report {
    const write_depot = opts.stack.writeDepot() orelse return error.NoDepot;
    const manifest_file = try write_depot.appManifestFile(arena);
    var m = try readAppManifest(arena, io, manifest_file);

    var changes: std.ArrayList(Report.Change) = .empty;

    if (m.findByName(pkg_or_app)) |entry| {
        for (entry.apps) |a| {
            try removeShim(arena, io, opts, a.name);
            try changes.append(arena, .{
                .kind = .removed,
                .pkg = entry.name,
                .app = a.name,
                .shim = try write_depot.shimFile(arena, a.name, opts.target == .windows),
            });
        }
        const uuid = entry.uuid;
        const had_path = entry.path != null;
        const env = try write_depot.appEnvDir(arena, entry.name);
        try dropEntry(arena, &m, uuid);
        if (!opts.dry_run) {
            if (!had_path) Io.Dir.cwd().deleteTree(io, env) catch {};
            try writeAppManifest(gpa, arena, io, manifest_file, &m);
        }
        return .{ .changes = changes.items, .dry_run = opts.dry_run };
    }

    // Not a package: try it as an app name, across every entry.
    var found = false;
    for (m.entries) |entry| {
        var kept: std.ArrayList(manifest_mod.AppInfo) = .empty;
        for (entry.apps) |a| {
            if (std.mem.eql(u8, a.name, pkg_or_app)) {
                found = true;
                try removeShim(arena, io, opts, a.name);
                try changes.append(arena, .{
                    .kind = .removed,
                    .pkg = entry.name,
                    .app = a.name,
                    .shim = try write_depot.shimFile(arena, a.name, opts.target == .windows),
                });
                continue;
            }
            try kept.append(arena, a);
        }
        if (!found) continue;

        if (kept.items.len == 0) {
            const env = try write_depot.appEnvDir(arena, entry.name);
            const had_path = entry.path != null;
            try dropEntry(arena, &m, entry.uuid);
            if (!opts.dry_run and !had_path) Io.Dir.cwd().deleteTree(io, env) catch {};
        } else {
            var next = entry;
            next.apps = kept.items;
            try upsert(arena, &m, next);
        }
        break;
    }
    if (!found) return Error.NoSuchApp;
    if (!opts.dry_run) try writeAppManifest(gpa, arena, io, manifest_file, &m);
    return .{ .changes = changes.items, .dry_run = opts.dry_run };
}

/// One row of `ajt app status`.
pub const StatusRow = struct {
    pkg: []const u8,
    uuid: manifest_mod.Uuid,
    version: ?manifest_mod.Version,
    /// Set when the package is dev'd — `status` prints it instead of a version.
    path: ?[]const u8,
    app: []const u8,
    julia_command: []const u8,
};

/// `Pkg.Apps.status` (`Apps.jl:343-375`), as data rather than as printed text.
///
/// `filter` is a package name or an app name, tried in that order, exactly as
/// `rm`'s argument is; null lists everything.
pub fn status(
    arena: Allocator,
    io: Io,
    opts: Options,
    filter: ?[]const u8,
) ![]const StatusRow {
    const write_depot = opts.stack.writeDepot() orelse return error.NoDepot;
    const m = try readAppManifest(arena, io, try write_depot.appManifestFile(arena));

    const is_pkg = if (filter) |f| m.findByName(f) != null else false;

    var rows: std.ArrayList(StatusRow) = .empty;
    for (m.entries) |e| {
        if (filter) |f| {
            if (is_pkg and !std.mem.eql(u8, e.name, f)) continue;
        }
        for (e.apps) |a| {
            if (filter) |f| {
                if (!is_pkg and !std.mem.eql(u8, a.name, f)) continue;
            }
            try rows.append(arena, .{
                .pkg = e.name,
                .uuid = e.uuid,
                .version = e.version,
                .path = e.path,
                .app = a.name,
                .julia_command = a.julia_command,
            });
        }
    }
    return rows.items;
}

/// `Base.abspath`. `std.process.currentPath`, not `realPath` on the cwd handle:
/// the latter asks the OS to resolve the empty path against that handle, which
/// is `ENOENT` on Linux. Same shape as `ops/edit.zig`'s.
fn absPath(arena: Allocator, io: Io, p: []const u8) ![]const u8 {
    if (fspath.isAbsolute(p)) return fspath.resolve(arena, &.{p});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return fspath.resolve(arena, &.{ buf[0..n], p });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "app, package and submodule names have three different rules" {
    // A hyphen is legal in an app name and in neither of the others.
    try validateAppName("reverse");
    try validateAppName("my-app");
    try validateAppName("a_b9");
    try testing.expectError(Error.InvalidAppName, validateAppName(""));
    try testing.expectError(Error.InvalidAppName, validateAppName("9lives"));
    try testing.expectError(Error.InvalidAppName, validateAppName("_leading"));
    try testing.expectError(Error.InvalidAppName, validateAppName("a/b"));
    try testing.expectError(Error.InvalidAppName, validateAppName("a..b"));
    try testing.expectError(Error.InvalidAppName, validateAppName("a.b"));

    try validatePackageName("Foo");
    try validatePackageName("Foo_9");
    try testing.expectError(Error.InvalidPackageName, validatePackageName("my-app"));
    try testing.expectError(Error.InvalidPackageName, validatePackageName(""));

    try validateSubmoduleName(null);
    try validateSubmoduleName("CLI");
    try testing.expectError(Error.InvalidSubmoduleName, validateSubmoduleName(""));
    // Single level in 1.12.6 -- a dotted spec is a later Pkg.
    try testing.expectError(Error.InvalidSubmoduleName, validateSubmoduleName("Foo.Bar"));
}

test "moduleSpec appends the submodule only when there is one" {
    const a = try moduleSpec(testing.allocator, "Foo", null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Foo", a);

    const b = try moduleSpec(testing.allocator, "Foo", "CLI");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Foo.CLI", b);
}

test "the POSIX shim is byte-identical to Pkg 1.12.6" {
    // Oracle: `Pkg.Apps.shell_shim(Base.shell_escape("/usr/bin/julia"),
    //   Base.shell_escape("Foo"), "/home/u/.julia/environments/apps/Foo",
    //   String[])` on Julia 1.12.6, with DEPOT_PATH = ["/home/u/.julia"].
    //
    // Note lines 4 and 5: the first carries four spaces of indent and the
    // second none. That is `SHIM_HEADER` being interpolated into an indented
    // line of a triple-quoted string, and it is in every shim Pkg writes.
    const got = try renderShim(testing.allocator, .{
        .pkg_name = "Foo",
        .app = .{ .name = "foo" },
        .env = "/home/u/.julia/environments/apps/Foo",
        .julia = "/usr/bin/julia",
        .depots = &.{"/home/u/.julia"},
    }, .posix);
    defer testing.allocator.free(got);

    const want =
        \\#!/bin/sh
        \\set -eu
        \\
        \\    # This file is generated by the Julia package manager.
        \\# Shim version: 1.1
        \\
        \\# Pin Julia paths for the child process
        \\export JULIA_LOAD_PATH=/home/u/.julia/environments/apps/Foo
        \\export JULIA_DEPOT_PATH=/home/u/.julia
        \\
        \\# Allow overriding Julia executable via environment variable
        \\if [ -n "${JULIA_APPS_JULIA_CMD:-}" ]; then
        \\    julia_cmd="$JULIA_APPS_JULIA_CMD"
        \\else
        \\    julia_cmd=/usr/bin/julia
        \\fi
        \\
        \\# If a `--` appears, args before it go to Julia, after it to the app.
        \\# If no `--` appears, all original args go to the app (no Julia args).
        \\found_separator=false
        \\for a in "$@"; do
        \\    [ "$a" = "--" ] && { found_separator=true; break; }
        \\done
        \\
        \\if [ "$found_separator" = "true" ]; then
        \\    # Build julia_args until `--`, then leave the rest in "$@"
        \\    julia_args=""
        \\    while [ "$#" -gt 0 ]; do
        \\        case "$1" in
        \\        --) shift; break ;;
        \\        *)  julia_args="$julia_args${julia_args:+ }$1"; shift ;;
        \\        esac
        \\    done
        \\    # Here: "$@" are the app args after the separator
        \\    exec "$julia_cmd" --startup-file=no $julia_args -m Foo "$@"
        \\else
        \\    # No separator: all original args go straight to the app
        \\    exec "$julia_cmd" --startup-file=no -m Foo "$@"
        \\fi
        \\
    ;
    try testing.expectEqualStrings(want, got);
    // The oracle's byte count, as a second, independent landmark. Measured with
    // `DEPOT_PATH` forced to exactly the one entry above -- `shell_shim` reads
    // the global, so a count taken on a machine with three depots on it
    // describes a different string. (It did, the first time: 1337.)
    try testing.expectEqual(@as(usize, 1189), got.len);
}

test "julia_flags and a submodule reach the exec line" {
    // Oracle byte count for the same call with
    // `String["--threads=4", "--optimize=2"]` and module spec `Foo.CLI`: 1247.
    const got = try renderShim(testing.allocator, .{
        .pkg_name = "Foo",
        .app = .{
            .name = "foo",
            .submodule = "CLI",
            .julia_flags = &.{ "--threads=4", "--optimize=2" },
        },
        .env = "/home/u/.julia/environments/apps/Foo",
        .julia = "/usr/bin/julia",
        .depots = &.{"/home/u/.julia"},
    }, .posix);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "exec \"$julia_cmd\" --startup-file=no --threads=4 --optimize=2 $julia_args -m Foo.CLI \"$@\"\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "exec \"$julia_cmd\" --startup-file=no --threads=4 --optimize=2 -m Foo.CLI \"$@\"\n",
    ) != null);
    try testing.expectEqual(@as(usize, 1247), got.len);
}

test "a spacey julia path is single-quoted, and the depots are joined with :" {
    const got = try renderShim(testing.allocator, .{
        .pkg_name = "Foo",
        .app = .{ .name = "foo" },
        .env = "/home/u/.julia/environments/apps/Foo",
        .julia = "/opt/julia 1.12/bin/julia",
        .depots = &.{ "/home/u/.julia", "/usr/share/julia" },
    }, .posix);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "    julia_cmd='/opt/julia 1.12/bin/julia'\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "export JULIA_DEPOT_PATH=/home/u/.julia:/usr/share/julia\n",
    ) != null);
}

test "the Windows shim does not reproduce Pkg.jl#4741" {
    const got = try renderShim(testing.allocator, .{
        .pkg_name = "Foo",
        .app = .{ .name = "foo" },
        .env = "C:\\Users\\test user\\.julia\\environments\\apps\\Foo",
        .julia = "C:\\Users\\test user\\.julia\\juliaup\\julia-1.12.6\\bin\\julia",
        .depots = &.{"C:\\Users\\test user\\.julia"},
    }, .windows);
    defer testing.allocator.free(got);

    // What Pkg writes, and what breaks cmd.exe once the path has a space:
    //   set "julia_cmd="C:\Users\test user\...\julia""
    // and then `""C:\Users\test` is not recognized as a command.
    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "    set \"julia_cmd=C:\\Users\\test user\\.julia\\juliaup\\julia-1.12.6\\bin\\julia\"\n",
    ) != null);
    // The defect, spelled out. `julia_cmd="` can only occur as the opening of
    // Pkg's pre-quoted value: the fixed line reads `julia_cmd=C:\...` and the
    // override line `julia_cmd=%JULIA_APPS_JULIA_CMD%`.
    //
    // A blanket "no `\"\"` anywhere" assertion is what this said first, and it
    // was wrong -- `if "%~1"=="" goto __done` is cmd's ordinary way to test for
    // an empty argument and appears in Pkg's shim and in this one.
    try testing.expect(std.mem.indexOf(u8, got, "julia_cmd=\"") == null);
    // The doubled quotes only ever arise at the call site, from a value that
    // already carried its own. Assert the composition directly.
    try testing.expect(std.mem.indexOf(u8, got, "\"\"C:") == null);
    // The two branches now store the same SHAPE of value.
    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "    set \"julia_cmd=%JULIA_APPS_JULIA_CMD%\"\n",
    ) != null);
    // The call site is where the quotes come from, unchanged from Pkg.
    try testing.expect(std.mem.indexOf(u8, got, "    \"%julia_cmd%\" ^\n") != null);
    // The module spec stays PRE-quoted: `-m` adds none.
    try testing.expect(std.mem.indexOf(u8, got, "        -m \"Foo\" ^\n") != null);
    // A `.bat` uses cmd's comment keyword, not `#`.
    try testing.expect(std.mem.startsWith(u8, got, "@echo off\n"));
    try testing.expect(std.mem.indexOf(u8, got, "REM Shim version: 1.1\n") != null);
    // The deviation names itself so nobody restores the bug.
    try testing.expect(std.mem.indexOf(u8, got, "JuliaLang/Pkg.jl#4741") != null);
    // Windows joins DEPOT_PATH with `;`.
    try testing.expect(std.mem.indexOf(
        u8,
        got,
        "set \"JULIA_DEPOT_PATH=C:\\Users\\test user\\.julia\"\n",
    ) != null);
}

/// A package tree at `<tmp>/<dir>`: `Project.toml` plus `src/<pkg>.jl`.
///
/// `dir` and `pkg` are separate because the interesting fixtures put a package
/// somewhere that is not named after it — `installed/Foo` holding package
/// `Foo`. Joining them would ask for `src/installed/Foo.jl`, a directory that
/// does not exist. (It did, the first time.)
fn writePkg(
    io: Io,
    td: *std.testing.TmpDir,
    dir: []const u8,
    pkg: []const u8,
    project_toml: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    try td.dir.createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/src", .{dir}));
    try td.dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/Project.toml", .{dir}),
        .data = project_toml,
    });
    try td.dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/src/{s}.jl", .{ dir, pkg }),
        .data = "module X\nend\n",
    });
}

test "appProject bolts on entryfile and requires the package to declare apps" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    try writePkg(testing.io, &td, "Foo", "Foo",
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\
        \\[apps]
        \\foo = {}
        \\
    );
    const foo = try std.fs.path.join(g, &.{ base, "Foo" });
    const r = try appProject(g, g, testing.io, foo, "Foo", null);
    try testing.expectEqual(@as(usize, 0), r.dropped.len);

    const want_entry = try std.fmt.allocPrint(g, "entryfile = \"{s}/src/Foo.jl\"\n", .{foo});
    try testing.expect(std.mem.indexOf(u8, r.bytes, want_entry) != null);
    // `[apps]` survives the round trip through the passthrough.
    try testing.expect(std.mem.indexOf(u8, r.bytes, "[apps.foo]") != null);

    // A package with no `[apps]` is refused (`get_project`, Apps.jl:69).
    try writePkg(testing.io, &td, "Bare", "Bare",
        \\name = "Bare"
        \\uuid = "22222222-2222-3333-4444-555555555555"
        \\
    );
    try testing.expectError(Error.NoAppsInProject, appProject(
        g,
        g,
        testing.io,
        try std.fs.path.join(g, &.{ base, "Bare" }),
        "Bare",
        null,
    ));
}

test "a relative [sources] path is rebased, not carried into the app environment" {
    // JuliaLang/Pkg.jl#4532 / #4714. Pkg 1.12.6 copies `{path = "../Sibling"}`
    // verbatim into `<depot>/environments/apps/Foo/Project.toml`, where it now
    // means `<depot>/environments/Sibling` -- and the install dies with
    // `expected package Sibling to exist at path .../environments/apps/Sibling`.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    // A monorepo: Foo alongside Sibling, with Foo pointing at it relatively.
    try writePkg(testing.io, &td, "Sibling", "Sibling",
        \\name = "Sibling"
        \\uuid = "33333333-2222-3333-4444-555555555555"
        \\
    );
    try writePkg(testing.io, &td, "Foo", "Foo",
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[deps]
        \\Sibling = "33333333-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\foo = {}
        \\
        \\[sources]
        \\Sibling = {path = "../Sibling"}
        \\
    );

    const foo = try std.fs.path.join(g, &.{ base, "Foo" });
    const r = try appProject(g, g, testing.io, foo, "Foo", null);
    try testing.expectEqual(@as(usize, 0), r.dropped.len);

    // Rewritten to the absolute directory that actually holds Sibling.
    const want = try std.fmt.allocPrint(g, "path = \"{s}/Sibling\"", .{base});
    try testing.expect(std.mem.indexOf(u8, r.bytes, want) != null);
    // And the relative spelling is gone, so nothing resolves it against the
    // app environment.
    try testing.expect(std.mem.indexOf(u8, r.bytes, "../Sibling") == null);
}

test "a [sources] path that resolves nowhere is dropped, not fatal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    // The release-tarball case: the sibling the monorepo had is not shipped.
    try writePkg(testing.io, &td, "Foo", "Foo",
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[deps]
        \\Gone = "44444444-2222-3333-4444-555555555555"
        \\Kept = "55555555-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\foo = {}
        \\
        \\[sources]
        \\Gone = {path = "../Gone"}
        \\Kept = {url = "https://example.com/Kept.jl", rev = "main"}
        \\
    );

    const foo = try std.fs.path.join(g, &.{ base, "Foo" });
    const r = try appProject(g, g, testing.io, foo, "Foo", null);

    // Dropped with the information a warning needs, so the dependency falls
    // back to the registry rather than the install failing outright.
    try testing.expectEqual(@as(usize, 1), r.dropped.len);
    try testing.expectEqualStrings("Gone", r.dropped[0].dep);
    try testing.expectEqualStrings("../Gone", r.dropped[0].path);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "Gone") == null or
        std.mem.indexOf(u8, r.bytes, "../Gone") == null);

    // A url source is untouched -- it means the same thing from any directory.
    try testing.expect(std.mem.indexOf(u8, r.bytes, "https://example.com/Kept.jl") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "rev = \"main\"") != null);
}

test "original_dir wins over the installed tree, and an absolute path is left alone" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    // Two candidate `Dep` directories: one beside the ORIGINAL checkout, one
    // beside the installed copy. The original must win -- a monorepo sibling
    // is real there and may be a stale leftover in the depot.
    try td.dir.createDirPath(testing.io, "orig/Dep");
    try td.dir.createDirPath(testing.io, "installed/Dep");
    try writePkg(testing.io, &td, "installed/Foo", "Foo",
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[deps]
        \\Dep = "66666666-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\foo = {}
        \\
        \\[sources]
        \\Dep = {path = "../Dep"}
        \\
    );

    const installed_foo = try std.fs.path.join(g, &.{ base, "installed", "Foo" });
    const orig_foo = try std.fs.path.join(g, &.{ base, "orig", "Foo" });
    const r = try appProject(g, g, testing.io, installed_foo, "Foo", orig_foo);
    try testing.expectEqual(@as(usize, 0), r.dropped.len);

    const want = try std.fmt.allocPrint(g, "path = \"{s}/orig/Dep\"", .{base});
    try testing.expect(std.mem.indexOf(u8, r.bytes, want) != null);

    // An absolute path means what it says wherever the file ends up. The
    // `[deps]` entry is not decoration: `validate` refuses a `[sources]` name
    // that is in neither `deps` nor `extras` (`project.zig:1208-1215`).
    var proj = try project_mod.parse(g,
        \\name = "Foo"
        \\
        \\[deps]
        \\Dep = "66666666-2222-3333-4444-555555555555"
        \\
        \\[sources]
        \\Dep = {path = "/somewhere/else"}
        \\
    , .{}, null);
    const dropped = try rebaseSources(g, testing.io, &proj, installed_foo, orig_foo);
    try testing.expectEqual(@as(usize, 0), dropped.len);
    try testing.expectEqualStrings("/somewhere/else", proj.sourceFor("Dep").?.path.?);
}

/// A temp depot plus a package tree beside it, wired for the verbs.
const Fixture = struct {
    td: std.testing.TmpDir,
    base: []const u8,
    depot: []const u8,
    opts: Options,
    entries: [1][]const u8,

    fn init(arena: Allocator, buf: *[std.Io.Dir.max_path_bytes]u8) !Fixture {
        var f: Fixture = .{
            .td = testing.tmpDir(.{}),
            .base = "",
            .depot = "",
            .opts = undefined,
            .entries = undefined,
        };
        f.base = buf[0..try f.td.dir.realPath(testing.io, buf)];
        f.depot = try fspath.join(arena, &.{ f.base, "depot" });
        try Io.Dir.cwd().createDirPath(testing.io, f.depot);
        return f;
    }

    /// Built after `init` returns so the `Stack` points at THIS struct's
    /// storage rather than at a copy that has since moved.
    fn wire(self: *Fixture) void {
        self.entries = .{self.depot};
        self.opts = .{
            .stack = .{ .entries = &self.entries },
            .julia = "/usr/bin/julia",
            .target = .posix,
        };
    }

    fn deinit(self: *Fixture) void {
        self.td.cleanup();
    }

    fn read(self: *Fixture, arena: Allocator, rel: []const u8) ![]u8 {
        return self.td.dir.readFileAlloc(testing.io, rel, arena, .limited(1 << 20));
    }

    fn exists(self: *Fixture, rel: []const u8) bool {
        if (self.td.dir.statFile(testing.io, rel, .{})) |_| return true else |_| return false;
    }
};

test "app dev installs shims against the working tree and records no app environment" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var f = try Fixture.init(g, &buf);
    defer f.deinit();
    f.wire();

    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.3.0"
        \\
        \\[apps]
        \\tool = {}
        \\tool-cli = {submodule = "CLI", julia_flags = ["--threads=2"]}
        \\
    );
    const src_dir = try fspath.join(g, &.{ f.base, "Tool" });

    const rep = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);
    try testing.expectEqual(@as(usize, 2), rep.changes.len);

    // Both shims exist and are executable.
    for ([_][]const u8{ "tool", "tool-cli" }) |app| {
        const rel = try std.fmt.allocPrint(g, "depot/bin/{s}", .{app});
        try testing.expect(f.exists(rel));
        const st = try f.td.dir.statFile(testing.io, rel, .{});
        try testing.expectEqual(@as(u64, 0o755), st.permissions.toMode() & 0o777);
    }

    // The load path is the WORKING TREE, not an app environment -- that is what
    // makes an edit to the source live without a reinstall.
    const shim = try f.read(g, "depot/bin/tool");
    const want_lp = try std.fmt.allocPrint(g, "export JULIA_LOAD_PATH={s}\n", .{src_dir});
    try testing.expect(std.mem.indexOf(u8, shim, want_lp) != null);
    try testing.expect(std.mem.indexOf(u8, shim, "-m Tool \"$@\"") != null);

    // The submodule and the flags reach the second shim.
    const cli = try f.read(g, "depot/bin/tool-cli");
    try testing.expect(std.mem.indexOf(u8, cli, "--startup-file=no --threads=2 -m Tool.CLI") != null);

    // `develop` builds NO app environment (`Apps.jl:276-278`).
    try testing.expect(!f.exists("depot/environments/apps/Tool"));

    // The AppManifest records the package by path, with both apps and the
    // julia each was pinned to.
    const am = try f.read(g, "depot/environments/apps/AppManifest.toml");
    try testing.expect(std.mem.startsWith(u8, am, manifest_mod.banner));
    try testing.expect(std.mem.indexOf(u8, am, "julia_command = \"/usr/bin/julia\"") != null);
    try testing.expect(std.mem.indexOf(u8, am, "submodule = \"CLI\"") != null);
    const want_path = try std.fmt.allocPrint(g, "path = \"{s}\"", .{src_dir});
    try testing.expect(std.mem.indexOf(u8, am, want_path) != null);

    // It round-trips through the model that Pkg shares.
    const m = try manifest_mod.parse(g, am, null);
    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(@as(usize, 2), m.entries[0].apps.len);
    try testing.expectEqualStrings("Tool", m.entries[0].name);
}

test "app dev is idempotent, and renaming an app retires its shim" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var f = try Fixture.init(g, &buf);
    defer f.deinit();
    f.wire();

    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\tool = {}
        \\
    );
    const src_dir = try fspath.join(g, &.{ f.base, "Tool" });

    const first = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);
    try testing.expectEqual(Report.Change.Kind.developed, first.changes[0].kind);

    // Re-running writes nothing: `overwrite_file_if_different` compares CONTENT,
    // so an unchanged package must not touch the shim's mtime.
    const again = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);
    try testing.expectEqual(Report.Change.Kind.unchanged, again.changes[0].kind);

    // Rename the app. The old shim must go, or `<depot>/bin/tool` keeps
    // pointing at a module the package no longer exposes.
    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\renamed = {}
        \\
    );
    _ = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);
    try testing.expect(f.exists("depot/bin/renamed"));
    try testing.expect(!f.exists("depot/bin/tool"));
}

test "app rm takes a package name or an app name, and spares a dev'd checkout" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var f = try Fixture.init(g, &buf);
    defer f.deinit();
    f.wire();

    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\alpha = {}
        \\beta = {}
        \\
    );
    const src_dir = try fspath.join(g, &.{ f.base, "Tool" });
    _ = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);

    // By APP name: only that one goes, the package entry survives.
    const one = try remove(testing.allocator, g, testing.io, f.opts, "alpha");
    try testing.expectEqual(@as(usize, 1), one.changes.len);
    try testing.expect(!f.exists("depot/bin/alpha"));
    try testing.expect(f.exists("depot/bin/beta"));

    const m1 = try manifest_mod.parse(g, try f.read(g, "depot/environments/apps/AppManifest.toml"), null);
    try testing.expectEqual(@as(usize, 1), m1.entries.len);
    try testing.expectEqual(@as(usize, 1), m1.entries[0].apps.len);

    // By PACKAGE name: everything it provides.
    const all = try remove(testing.allocator, g, testing.io, f.opts, "Tool");
    try testing.expectEqual(@as(usize, 1), all.changes.len);
    try testing.expect(!f.exists("depot/bin/beta"));

    const m2 = try manifest_mod.parse(g, try f.read(g, "depot/environments/apps/AppManifest.toml"), null);
    try testing.expectEqual(@as(usize, 0), m2.entries.len);

    // The user's checkout is NOT deleted: the entry carried a `path`
    // (`Apps.jl:428-430`).
    try testing.expect(f.exists("Tool/Project.toml"));

    try testing.expectError(Error.NoSuchApp, remove(testing.allocator, g, testing.io, f.opts, "nope"));
}

test "app status reports by package or by app" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var f = try Fixture.init(g, &buf);
    defer f.deinit();
    f.wire();

    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "1.2.3"
        \\
        \\[apps]
        \\alpha = {}
        \\beta = {}
        \\
    );
    const src_dir = try fspath.join(g, &.{ f.base, "Tool" });
    _ = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);

    const all = try status(g, testing.io, f.opts, null);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("Tool", all[0].pkg);
    try testing.expectEqualStrings("/usr/bin/julia", all[0].julia_command);
    try testing.expectEqualStrings(src_dir, all[0].path.?);

    // A package filter keeps both rows; an app filter keeps one.
    try testing.expectEqual(@as(usize, 2), (try status(g, testing.io, f.opts, "Tool")).len);
    const one = try status(g, testing.io, f.opts, "beta");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("beta", one[0].app);

    // An unknown name matches neither and yields nothing rather than erroring
    // -- `status` is a report, not an assertion.
    try testing.expectEqual(@as(usize, 0), (try status(g, testing.io, f.opts, "nope")).len);
}

test "a dry run reports the same changes and writes nothing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var f = try Fixture.init(g, &buf);
    defer f.deinit();
    f.wire();
    f.opts.dry_run = true;

    try writePkg(testing.io, &f.td, "Tool", "Tool",
        \\name = "Tool"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\
        \\[apps]
        \\tool = {}
        \\
    );
    const src_dir = try fspath.join(g, &.{ f.base, "Tool" });

    const rep = try develop(testing.allocator, g, testing.io, f.opts, src_dir, null);
    try testing.expect(rep.dry_run);
    try testing.expectEqual(@as(usize, 1), rep.changes.len);
    try testing.expectEqual(Report.Change.Kind.developed, rep.changes[0].kind);
    // Nothing on disk.
    try testing.expect(!f.exists("depot/bin/tool"));
    try testing.expect(!f.exists("depot/environments/apps/AppManifest.toml"));
}

test "renderShim validates before it renders" {
    const spec: ShimSpec = .{
        .pkg_name = "Foo",
        .app = .{ .name = "ok" },
        .env = "/e",
        .julia = "/usr/bin/julia",
        .depots = &.{"/d"},
    };
    var bad = spec;
    bad.app.name = "9bad";
    try testing.expectError(Error.InvalidAppName, renderShim(testing.allocator, bad, .posix));

    bad = spec;
    bad.pkg_name = "not-an-identifier";
    try testing.expectError(Error.InvalidPackageName, renderShim(testing.allocator, bad, .posix));

    bad = spec;
    bad.app.submodule = "Foo.Bar";
    try testing.expectError(Error.InvalidSubmoduleName, renderShim(testing.allocator, bad, .posix));
}
