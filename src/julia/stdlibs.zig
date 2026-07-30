//! Enumerating a Julia installation's standard libraries.
//!
//! Port of `Pkg/src/Types.jl:501-541` (`UPGRADABLE_STDLIBS`, `load_stdlib`,
//! `stdlibs`, `is_stdlib`, `is_or_was_stdlib`) plus the directory layout from
//! `Pkg/src/utils.jl:30-31` (`stdlib_dir`, `stdlib_path`).
//!
//! Why this module has to be exactly right: the resolver decides a stdlib at
//! level 0 as a SINGLE fixed version and never consults a registry for it. An
//! entry missing from this list gets resolved from the registry instead --
//! which either fails outright (most stdlibs are not registered) or installs a
//! stale standalone copy that shadows the shipped one. An extra entry gets
//! pinned to a version that does not exist. Both failures surface far away
//! from here, which is why `tools/diff_harness/stdlibs.sh` diffs the whole set
//! against `Pkg.Types.stdlibs()` and treats any difference as fatal.
//!
//! Four traps, all of them silent:
//!
//!  1. **`UPGRADABLE_STDLIBS` are NOT stdlibs** (`Types.jl:501, 514-517`).
//!     `DelimitedFiles` and `Statistics` ship in the stdlib directory but
//!     `load_stdlib` `continue`s past them *before* inserting, so
//!     `is_stdlib(uuid)` is false and the resolver must fetch them from the
//!     registry like any other package. Folding them into the fixed set pins
//!     them forever at whatever version the installation happens to carry.
//!     They are kept in `Set.upgradable` here, out of `Set.fixed`, so the two
//!     can never be confused; `isOrWasStdlib` (`Types.jl:539-541`) is the
//!     predicate that spans both.
//!
//!  2. **The name is the DIRECTORY name, not `project["name"]`**
//!     (`Types.jl:506, 514, 520`). `load_stdlib` iterates `readdir` and passes
//!     that string straight into `StdlibInfo`, and the `UPGRADABLE_STDLIBS`
//!     membership test is on it too.
//!
//!  3. **`version` is optional** (`HistoricalStdlibs.jl:7-8`). `SuiteSparse`
//!     ships no `version` key, so its version is `nothing`. `deps_graph`
//!     substitutes the Julia version for it -- `v = something(stdlib_info
//!     .version, VERSION)` (`Operations.jl:678`) -- which is what
//!     `Stdlib.resolvedVersion` reproduces. Defaulting to 0.0.0 instead would
//!     make every `julia`-compat bound reject the package.
//!
//!  4. **`deps`/`weakdeps` are load bearing.** They are not decoration on
//!     `StdlibInfo`: `deps_graph` turns them into the stdlib node's outgoing
//!     edges with an unconstrained `VersionSpec` each (`Operations.jl:681-693`).
//!     Dropping them silently disconnects the stdlib subgraph.
//!
//! Related behaviour the resolver author must know about, deliberately NOT
//! implemented here:
//!
//!  * **`unbind_stdlibs`** (`Operations.jl:556-559`). When resolving for the
//!    running Julia (`julia_version === VERSION`, the only case Ajt targets),
//!    Pkg replaces every manifest-recorded stdlib version with `VersionSpec("*")`
//!    before resolving, so a manifest written by a different Julia does not
//!    pin a stdlib to a version this installation does not have. So the
//!    versions this module reports are the ones the resolver should USE, and a
//!    manifest's stdlib version is input to be discarded, not a constraint.
//!    That is also why 44 of the 214 entries in the engine's manifest carry no
//!    `git-tree-sha1`: nothing is ever fetched for them.
//!
//!  * **Historical stdlib sets** (`Types.jl:544-597`, `STDLIBS_BY_VERSION`).
//!    Resolving "as if" for a different Julia version needs
//!    HistoricalStdlibVersions.jl and errors without it. Ajt only ever
//!    enumerates the installation it is pointed at, which is Julia's
//!    `julia_version == VERSION` fast path (`Types.jl:589-590`).
//!
//!  * `julia` itself (uuid `1222c4b2-…`) is NOT a stdlib -- there is no such
//!    directory, and `is_stdlib` on it returns false. It is injected as a
//!    dependency of every registered package by `registry/index.zig` instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const toml = @import("../toml/parse.zig");
const Table = @import("../toml/value.zig").Table;
const slug = @import("slug.zig");
const version_mod = @import("version.zig");

pub const Uuid = slug.Uuid;
pub const Version = version_mod.Version;

/// `Types.jl:501`. Present in the stdlib directory, but resolved from the
/// registry like ordinary packages.
pub const upgradable_names = [_][]const u8{ "DelimitedFiles", "Statistics" };

/// `Base.project_names`, in probe order -- `JuliaProject.toml` wins over
/// `Project.toml` (`Types.jl:180-186` walks it in that order and returns the
/// first hit).
pub const project_names = [_][]const u8{ "JuliaProject.toml", "Project.toml" };

pub const Error = error{
    StdlibDirNotFound,
    /// The stdlib directory exists but could not be enumerated, or a project
    /// file exists but could not be read. Distinct from `StdlibDirNotFound`
    /// so a permissions or I/O fault is not misreported as "no such Julia".
    ReadFailed,
    /// A `uuid`, `version`, `deps` or `weakdeps` entry was present but not a
    /// well-formed value. Julia throws here too; skipping would silently drop
    /// a stdlib, which is the failure mode this whole module exists to avoid.
    MalformedProjectFile,
    InvalidUuid,
} || toml.Error || version_mod.ParseError || Allocator.Error;

pub const Stdlib = struct {
    /// The DIRECTORY name (trap 2), which is also what `Pkg.Types.stdlibs()`
    /// reports.
    name: []const u8,
    uuid: Uuid,
    /// Canonical text form, exactly as written in the Project.toml. Kept
    /// because manifests and registries are keyed by the string.
    uuid_text: []const u8,
    /// `nothing` for an unregistered stdlib (trap 3).
    version: ?Version = null,
    version_text: ?[]const u8 = null,
    /// `[deps]` values, sorted by uuid for determinism. Julia reads them from
    /// a `Dict` whose iteration order is arbitrary and only ever pushes them
    /// into a set, so order carries no meaning (`Operations.jl:681-684`).
    ///
    /// Always empty when `upgradable`: Julia's `continue` at `Types.jl:516`
    /// lands before the `deps` read at `:518`, and such a package gets its
    /// dependencies from the registry anyway.
    deps: []const Uuid = &.{},
    /// `[weakdeps]` values, same treatment (`Operations.jl:686-693`).
    weakdeps: []const Uuid = &.{},
    /// True for `DelimitedFiles`/`Statistics` (trap 1). Such an entry lives in
    /// `Set.upgradable`, never in `Set.fixed`.
    upgradable: bool = false,

    /// The version `deps_graph` resolves this stdlib at: its own, or the Julia
    /// version when it has none (`Operations.jl:678`).
    pub fn resolvedVersion(self: Stdlib, julia_version: Version) Version {
        return self.version orelse julia_version;
    }
};

/// One installation's stdlib enumeration. Every slice, string and index in
/// here is owned by the arena passed to `load`; there is nothing to free
/// individually.
pub const Set = struct {
    /// The `v<major>.<minor>` directory that was read.
    dir: []const u8,
    /// Exactly `Pkg.Types.stdlibs()` -- the packages the resolver fixes at
    /// level 0. Sorted by name. Excludes the upgradable ones.
    fixed: []const Stdlib = &.{},
    /// `UPGRADABLE_STDLIBS` that are actually present. Sorted by name. These
    /// must be resolved from the registry (trap 1).
    upgradable: []const Stdlib = &.{},

    by_name: std.StringHashMapUnmanaged(*const Stdlib) = .empty,
    by_uuid: std.AutoHashMapUnmanaged([16]u8, *const Stdlib) = .empty,

    /// Looks up either kind. Check `.upgradable` on the result -- or use
    /// `isStdlib`, which already does.
    pub fn byName(self: *const Set, name: []const u8) ?*const Stdlib {
        return self.by_name.get(name);
    }

    pub fn byUuid(self: *const Set, uuid: Uuid) ?*const Stdlib {
        return self.by_uuid.get(uuid.bytes);
    }

    pub fn byUuidText(self: *const Set, text: []const u8) ?*const Stdlib {
        const u = Uuid.parse(text) catch return null;
        return self.byUuid(u);
    }

    /// `Types.jl:537` -- `uuid in keys(stdlib_infos())`. FALSE for the
    /// upgradable ones, which is the whole point of keeping them apart.
    pub fn isStdlib(self: *const Set, uuid: Uuid) bool {
        const e = self.byUuid(uuid) orelse return false;
        return !e.upgradable;
    }

    /// `uuid in UPGRADABLE_STDLIBS_UUIDS` (`Types.jl:502, 515`).
    pub fn isUpgradable(self: *const Set, uuid: Uuid) bool {
        const e = self.byUuid(uuid) orelse return false;
        return e.upgradable;
    }

    /// `is_or_was_stdlib` (`Types.jl:539-541`): shipped in the stdlib tree,
    /// whether or not it is resolver-fixed.
    pub fn isOrWasStdlib(self: *const Set, uuid: Uuid) bool {
        return self.by_uuid.contains(uuid.bytes);
    }
};

pub const Options = struct {
    /// Directory containing `share/julia/stdlib/v<major>.<minor>`. Julia gets
    /// it as `dirname(Sys.BINDIR)` (`utils.jl:30` spells the same thing as
    /// `joinpath(Sys.BINDIR, "..")`).
    julia_prefix: []const u8,
    /// e.g. "1.12.6"; only major and minor are used. When null, the highest
    /// `v<major>.<minor>` directory present is used instead. Julia never
    /// guesses -- it always uses its own `VERSION` (`utils.jl:30`) -- so pass
    /// the version whenever the caller knows it, and treat the discovery path
    /// as a convenience for tools that only have a prefix.
    julia_version: ?[]const u8 = null,
};

/// Enumerates the standard libraries of the installation at
/// `opts.julia_prefix`.
///
/// **Takes an arena.** Every byte of the returned `Set` -- and the transient
/// TOML parse trees, which are not worth a second allocator for ~60 small
/// files -- is allocated from it and never freed individually. Passing a
/// general-purpose allocator here leaks by design.
pub fn load(arena: Allocator, io: Io, opts: Options) Error!Set {
    const dir_path = try resolveStdlibDir(arena, io, opts);

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return error.StdlibDirNotFound;
    defer dir.close(io);

    var fixed: std.ArrayList(Stdlib) = .empty;
    var upgradable: std.ArrayList(Stdlib) = .empty;

    var it = dir.iterate();
    while (it.next(io) catch return error.ReadFailed) |raw| {
        // Deliberately NOT filtered on `raw.kind`: Julia's `readdir` yields
        // files too and lets `projectfile_path`'s `isfile` check drop them
        // (`Types.jl:506-508`), and a stdlib may legitimately be a symlink.
        // Reading `<name>/Project.toml` reproduces both outcomes -- a plain
        // file yields ENOTDIR, a directory without a project file yields
        // ENOENT, and either way we skip.
        const name = try arena.dupe(u8, raw.name);
        const entry = (try readEntry(arena, io, dir, name)) orelse continue;
        if (entry.upgradable) {
            try upgradable.append(arena, entry);
        } else {
            try fixed.append(arena, entry);
        }
    }

    // `readdir` is sorted, `Io.Dir.iterate` is not. Sorting keeps the output
    // reproducible, which is what makes the differential gate a clean diff.
    std.mem.sort(Stdlib, fixed.items, {}, lessByName);
    std.mem.sort(Stdlib, upgradable.items, {}, lessByName);

    var set: Set = .{
        .dir = dir_path,
        .fixed = try fixed.toOwnedSlice(arena),
        .upgradable = try upgradable.toOwnedSlice(arena),
    };
    // Index AFTER the slices are final: these are pointers into them.
    //
    // Two directories carrying the same uuid would leave both in `fixed` while
    // Julia's `Dict` keeps only one, so the counts would disagree -- but the
    // gate compares counts, and inserting in name order means `by_uuid` picks
    // the same winner Julia's readdir-ordered assignment does. No installation
    // has ever shipped such a pair.
    for ([_][]const Stdlib{ set.fixed, set.upgradable }) |group| {
        for (group) |*e| {
            try set.by_name.put(arena, e.name, e);
            try set.by_uuid.put(arena, e.uuid.bytes, e);
        }
    }
    return set;
}

fn lessByName(_: void, a: Stdlib, b: Stdlib) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// `stdlib_dir()` (`utils.jl:30`), with the version either supplied or
/// discovered.
fn resolveStdlibDir(arena: Allocator, io: Io, opts: Options) Error![]const u8 {
    const root = try std.fmt.allocPrint(arena, "{s}/share/julia/stdlib", .{opts.julia_prefix});
    if (opts.julia_version) |v| {
        const mm = majorMinor(v) orelse return error.StdlibDirNotFound;
        return std.fmt.allocPrint(arena, "{s}/v{d}.{d}", .{ root, mm[0], mm[1] });
    }

    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch
        return error.StdlibDirNotFound;
    defer dir.close(io);

    var best: ?[2]u64 = null;
    var it = dir.iterate();
    while (it.next(io) catch return error.ReadFailed) |raw| {
        if (raw.kind == .file) continue;
        // EXACT `v<major>.<minor>` only. A loose prefix match would accept a
        // sibling `v1.13.0-DEV` next to the real `v1.12`, truncate it to 1.13
        // and then fail to open `v1.13` -- turning a working installation into
        // `StdlibDirNotFound`.
        const mm = versionDirName(raw.name) orelse continue;
        if (best == null or mm[0] > best.?[0] or (mm[0] == best.?[0] and mm[1] > best.?[1])) best = mm;
    }
    const mm = best orelse return error.StdlibDirNotFound;
    return std.fmt.allocPrint(arena, "{s}/v{d}.{d}", .{ root, mm[0], mm[1] });
}

/// Leading `MAJOR.MINOR` of a version string; the rest ("6", "-rc1", …) is
/// ignored, because the directory name only ever carries two components.
/// A leading `v`/`V` is stripped, matching `version.zig`'s parser -- otherwise
/// the two entry points into this module would disagree on `"v1.12.6"`.
fn majorMinor(text: []const u8) ?[2]u64 {
    var s = text;
    if (s.len != 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    const major = std.fmt.parseInt(u64, s[0..dot], 10) catch return null;
    var end = dot + 1;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    if (end == dot + 1) return null;
    const minor = std.fmt.parseInt(u64, s[dot + 1 .. end], 10) catch return null;
    return .{ major, minor };
}

/// A directory name that is exactly `v<major>.<minor>` and nothing else.
fn versionDirName(name: []const u8) ?[2]u64 {
    if (name.len < 4 or name[0] != 'v') return null;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    const major = std.fmt.parseInt(u64, name[1..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u64, name[dot + 1 ..], 10) catch return null;
    return .{ major, minor };
}

/// `load_stdlib`'s loop body (`Types.jl:506-521`). Returns null for the cases
/// Julia skips: no project file, and no `uuid` key.
///
/// The statement ORDER below is Julia's, and it is observable: Julia reads and
/// converts `version` at `:511-512`, *before* the `nothing === uuid` skip at
/// `:513`, so a directory with no uuid but a broken `version` throws rather
/// than being skipped. Likewise the `UPGRADABLE_STDLIBS` `continue` at `:516`
/// lands *before* the deps/weakdeps reads at `:518-519`, so a broken `[deps]`
/// in DelimitedFiles or Statistics is never even looked at.
fn readEntry(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8) Error!?Stdlib {
    const src = (try readProjectFile(arena, io, dir, name)) orelse return null;

    const doc = try toml.parse(arena, src, null);
    // NB: `doc`'s arena is built on top of `arena`, so it is released with it
    // and there is nothing to deinit here.
    const root = doc.root;

    // Types.jl:510 -- `::Union{String, Nothing}`. Any other type throws, which
    // is NOT the same as the absent case handled at :513.
    const uuid_text: ?[]const u8 = if (root.get("uuid")) |v| switch (v) {
        .string => |s| s,
        else => return error.MalformedProjectFile,
    } else null;

    // Types.jl:511-512, still ahead of the uuid skip.
    var version: ?Version = null;
    var version_text: ?[]const u8 = null;
    if (root.get("version")) |v| switch (v) {
        .string => |s| {
            version_text = s;
            version = try version_mod.parse(arena, s);
        },
        else => return error.MalformedProjectFile,
    };

    const text = uuid_text orelse return null; // Types.jl:513
    const uuid = try Uuid.parse(text);

    var entry: Stdlib = .{
        // Trap 2: the DIRECTORY name, not `project["name"]` -- and the
        // UPGRADABLE_STDLIBS membership test is on it too (Types.jl:514).
        .name = name,
        .uuid = uuid,
        // Rendered from the bytes rather than echoed: `Uuid.parse` accepts
        // uppercase hex, but `string(::UUID)` is always lowercase, so echoing
        // the source text would produce a key that misses every registry and
        // manifest lookup.
        .uuid_text = try canonicalUuid(arena, uuid),
        .version = version,
        .version_text = version_text,
        .upgradable = isUpgradableName(name),
    };
    if (entry.upgradable) return entry; // Types.jl:516

    entry.deps = try uuidValues(arena, root, "deps");
    entry.weakdeps = try uuidValues(arena, root, "weakdeps");
    return entry;
}

/// Lowercase 8-4-4-4-12, i.e. what Julia's `string(::UUID)` produces.
fn canonicalUuid(arena: Allocator, uuid: Uuid) Allocator.Error![]const u8 {
    const b = uuid.bytes;
    return std.fmt.allocPrint(
        arena,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] },
    );
}

fn isUpgradableName(name: []const u8) bool {
    for (upgradable_names) |u| {
        if (std.mem.eql(u8, u, name)) return true;
    }
    return false;
}

/// First of `Base.project_names` that exists under `<dir>/<name>/`.
fn readProjectFile(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8) Error!?[]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (project_names) |pn| {
        const rel = std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, pn }) catch
            return error.ReadFailed; // name longer than a path: not our case
        const src = dir.readFileAlloc(io, rel, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            // The three shapes of "there is no project file here", which is
            // what Julia's `isfile` check reports (Types.jl:182-183): absent,
            // a plain file where the stdlib directory would be, or the name
            // itself being a directory.
            error.FileNotFound, error.NotDir, error.IsDir => continue,
            error.OutOfMemory => return error.OutOfMemory,
            // Anything else -- unreadable, too large, an I/O fault -- is NOT
            // the absent case: `isfile` is true for a file we cannot read, and
            // Julia then throws inside `parse_toml`. Skipping here would drop
            // a stdlib silently, which is the failure this module exists to
            // prevent.
            else => return error.ReadFailed,
        };
        return src;
    }
    return null;
}

/// `UUID.(values(get(project, key, Dict())))` (`Types.jl:518-519`), sorted.
fn uuidValues(arena: Allocator, root: *const Table, key: []const u8) Error![]const Uuid {
    const tbl = switch (root.get(key) orelse return &.{}) {
        .table => |t| t,
        else => return error.MalformedProjectFile,
    };
    var out: std.ArrayList(Uuid) = .empty;
    for (tbl.entries.items) |kv| {
        const text = switch (kv.value) {
            .string => |s| s,
            else => return error.MalformedProjectFile,
        };
        try out.append(arena, try Uuid.parse(text));
    }
    const items = try out.toOwnedSlice(arena);
    std.mem.sort(Uuid, items, {}, struct {
        fn lt(_: void, a: Uuid, b: Uuid) bool {
            return std.mem.lessThan(u8, &a.bytes, &b.bytes);
        }
    }.lt);
    return items;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const FileSpec = struct { name: []const u8, body: []const u8 };

/// Builds `<tmp>/share/julia/stdlib/<vX.Y>/<name>/` and writes `files` into it.
/// An empty `files` writes `<name>` as a plain FILE containing `raw` instead,
/// which is how the "not a directory at all" case is set up.
const Fixture = struct {
    name: []const u8,
    files: []const FileSpec = &.{},
    raw: []const u8 = "",
};

fn writeFixture(tmp: *std.testing.TmpDir, version_dir: []const u8, cases: []const Fixture) !void {
    const io = testing.io;
    var buf: [512]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, "share/julia/stdlib/{s}", .{version_dir});
    try tmp.dir.createDirPath(io, base);
    for (cases) |c| {
        var pbuf: [512]u8 = undefined;
        const d = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ base, c.name });
        if (c.files.len == 0) {
            try tmp.dir.writeFile(io, .{ .sub_path = d, .data = c.raw });
            continue;
        }
        try tmp.dir.createDirPath(io, d);
        for (c.files) |f| {
            var fbuf: [512]u8 = undefined;
            const p = try std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ d, f.name });
            try tmp.dir.writeFile(io, .{ .sub_path = p, .data = f.body });
        }
    }
}

fn project(comptime body: []const u8) []const FileSpec {
    return &.{.{ .name = "Project.toml", .body = body }};
}

fn tmpPrefix(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(testing.io, buf);
    return buf[0..n];
}

const linalg_uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e";
// Real uuids, read out of the installation via
//   julia -e 'using Pkg; println(Pkg.Types.UPGRADABLE_STDLIBS_UUIDS)'
const delimitedfiles_uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab";
const statistics_uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2";

const fixture_cases = [_]Fixture{
    .{ .name = "LinearAlgebra", .files = project(
        \\name = "LinearAlgebra"
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\version = "1.12.0"
        \\
        \\[deps]
        \\Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
        \\OpenBLAS_jll = "4536629a-c528-5b80-bd46-f80d51c5b363"
        \\libblastrampoline_jll = "8e850b90-86db-534c-a0d3-1478176c7d93"
        \\
    ) },
    // Ships in the stdlib tree but must be resolved from the registry. The
    // project `name` deliberately does NOT match the directory name: Julia
    // tests UPGRADABLE_STDLIBS membership on the DIRECTORY name
    // (Types.jl:506, 514), so reading `project["name"]` here would classify
    // this as an ordinary fixed stdlib. The bogus `[deps]` is never parsed,
    // because the `continue` at Types.jl:516 comes first.
    .{ .name = "DelimitedFiles", .files = project(
        \\name = "NotTheDirectoryName"
        \\uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab"
        \\version = "1.9.1"
        \\
        \\[deps]
        \\Broken = 17
        \\
    ) },
    .{ .name = "Statistics", .files = project(
        \\name = "Statistics"
        \\uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
        \\version = "1.11.1"
        \\
        \\[weakdeps]
        \\SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
        \\
    ) },
    // No `version` key: `StdlibInfo.version === nothing`.
    .{ .name = "SuiteSparse", .files = project(
        \\name = "SuiteSparse"
        \\uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"
        \\
        \\[deps]
        \\Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
        \\
        \\[weakdeps]
        \\Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
        \\
    ) },
    // Both project names present with DIFFERENT versions, so the assertion
    // pins the probe ORDER: `JuliaProject.toml` wins (Base.project_names,
    // walked in order at Types.jl:181-184). Also carries an UPPERCASE uuid,
    // which must come back canonicalised to lowercase.
    .{ .name = "Preferred", .files = &.{
        .{ .name = "JuliaProject.toml", .body =
        \\name = "Preferred"
        \\uuid = "0000000A-0000-0000-0000-00000000000B"
        \\version = "3.0.0"
        \\
        },
        .{ .name = "Project.toml", .body =
        \\name = "Preferred"
        \\uuid = "0000000a-0000-0000-0000-00000000000b"
        \\version = "1.0.0"
        \\
        },
    } },
    // No uuid -> skipped (Types.jl:513).
    .{ .name = "NoUuid", .files = project(
        \\name = "NoUuid"
        \\version = "1.0.0"
        \\
    ) },
    // A directory with no project file at all -> skipped (Types.jl:508).
    .{ .name = "Empty", .files = &.{.{ .name = "README.md", .body = "not a project\n" }} },
    // A plain FILE where a stdlib directory would be. Julia's `readdir` yields
    // it too and its `isfile(joinpath(name, "Project.toml"))` is false.
    .{ .name = "stray.txt", .raw = "loose file\n" },
};

fn loadFixture(arena: Allocator, tmp: *std.testing.TmpDir, opts_version: ?[]const u8) !Set {
    var pbuf: [512]u8 = undefined;
    const prefix = try tmpPrefix(tmp, &pbuf);
    return load(arena, testing.io, .{ .julia_prefix = prefix, .julia_version = opts_version });
}

test "splits the fixed set from UPGRADABLE_STDLIBS" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, "1.12.6");

    // LinearAlgebra, Preferred, SuiteSparse -- NoUuid, Empty and stray.txt are
    // skipped, DelimitedFiles/Statistics are not fixed.
    try testing.expectEqual(@as(usize, 3), set.fixed.len);
    try testing.expectEqualStrings("LinearAlgebra", set.fixed[0].name);
    try testing.expectEqualStrings("Preferred", set.fixed[1].name);
    try testing.expectEqualStrings("SuiteSparse", set.fixed[2].name);

    try testing.expectEqual(@as(usize, 2), set.upgradable.len);
    try testing.expectEqualStrings("DelimitedFiles", set.upgradable[0].name);
    try testing.expectEqualStrings("Statistics", set.upgradable[1].name);
}

test "isStdlib is false for the upgradable ones, isOrWasStdlib is true" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, "1.12.6");

    const la = try Uuid.parse(linalg_uuid);
    const df = try Uuid.parse(delimitedfiles_uuid);
    const st = try Uuid.parse(statistics_uuid);

    try testing.expect(set.isStdlib(la));
    try testing.expect(!set.isUpgradable(la));

    // The landmark: shipped in the tree, but NOT a stdlib to the resolver.
    // Verified against `Pkg.Types.is_stdlib(UUID("8bb1440f-…"))` -> false.
    try testing.expect(!set.isStdlib(df));
    try testing.expect(!set.isStdlib(st));
    try testing.expect(set.isUpgradable(df));
    try testing.expect(set.isUpgradable(st));
    try testing.expect(set.isOrWasStdlib(df));
    try testing.expect(set.isOrWasStdlib(st));

    // `julia` itself is not a stdlib.
    const julia = try Uuid.parse("1222c4b2-2114-5bfd-aeef-88e4692bbb3e");
    try testing.expect(!set.isStdlib(julia));
    try testing.expect(!set.isOrWasStdlib(julia));
}

test "lookup by name and by uuid reaches both groups" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, "1.12.6");

    const la = set.byName("LinearAlgebra").?;
    try testing.expectEqualStrings(linalg_uuid, la.uuid_text);
    try testing.expect(!la.upgradable);
    try testing.expectEqual(la, set.byUuid(try Uuid.parse(linalg_uuid)).?);
    try testing.expectEqual(la, set.byUuidText(linalg_uuid).?);

    const df = set.byName("DelimitedFiles").?;
    try testing.expect(df.upgradable);
    // The DIRECTORY name, not `project["name"]` (which says something else).
    try testing.expectEqualStrings("DelimitedFiles", df.name);
    try testing.expect(set.byName("NotTheDirectoryName") == null);

    // `uuid_text` is canonicalised: the fixture writes it uppercase.
    const pref = set.byName("Preferred").?;
    try testing.expectEqualStrings("0000000a-0000-0000-0000-00000000000b", pref.uuid_text);

    try testing.expect(set.byName("NoUuid") == null);
    try testing.expect(set.byName("Nope") == null);
    try testing.expect(set.byUuidText("not-a-uuid") == null);
}

test "version is optional and falls back to the Julia version" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try loadFixture(arena, &tmp, "1.12.6");

    const la = set.byName("LinearAlgebra").?;
    try testing.expectEqual(@as(u64, 1), la.version.?.major);
    try testing.expectEqual(@as(u64, 12), la.version.?.minor);

    // SuiteSparse ships no `version` key; Julia reports `nothing`.
    const ss = set.byName("SuiteSparse").?;
    try testing.expect(ss.version == null);
    try testing.expect(ss.version_text == null);

    // `deps_graph` substitutes VERSION for it (Operations.jl:678). Defaulting
    // to 0.0.0 instead would fail every `julia` compat bound.
    const jv = try version_mod.parse(arena, "1.12.6");
    try testing.expect(ss.resolvedVersion(jv).eql(jv));
    try testing.expect(la.resolvedVersion(jv).eql(la.version.?));
}

test "deps and weakdeps are read, but never for an upgradable stdlib" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, "1.12.6");

    // Julia reports 3 deps / 0 weakdeps for LinearAlgebra on this install.
    const la = set.byName("LinearAlgebra").?;
    try testing.expectEqual(@as(usize, 3), la.deps.len);
    try testing.expectEqual(@as(usize, 0), la.weakdeps.len);
    // Sorted by uuid bytes: 4536629a… < 8e850b90… < 8f399da3…
    try testing.expectEqual(@as(u8, 0x45), la.deps[0].bytes[0]);
    try testing.expectEqual(@as(u8, 0x8e), la.deps[1].bytes[0]);
    try testing.expectEqual(@as(u8, 0x8f), la.deps[2].bytes[0]);

    const ss = set.byName("SuiteSparse").?;
    try testing.expectEqual(@as(usize, 1), ss.deps.len);
    try testing.expectEqual(@as(usize, 1), ss.weakdeps.len);

    // The `continue` at Types.jl:516 lands BEFORE the deps read at :518, so
    // an upgradable stdlib never contributes them -- and the DelimitedFiles
    // fixture's `Broken = 17` (an integer where a uuid string belongs) proves
    // the table is not even looked at. Parsing it would abort the load.
    try testing.expectEqual(@as(usize, 0), set.byName("DelimitedFiles").?.deps.len);
    try testing.expectEqual(@as(usize, 0), set.byName("Statistics").?.weakdeps.len);
}

test "JuliaProject.toml takes precedence over Project.toml" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, "1.12.6");

    // `Preferred` ships BOTH, at versions 3.0.0 and 1.0.0 respectively.
    // `Base.project_names` is walked in order and the first hit wins
    // (Types.jl:181-184), so 3.0.0 is the answer.
    try testing.expectEqual(@as(u64, 3), set.byName("Preferred").?.version.?.major);
}

test "the version directory is discovered when no julia version is given" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(&tmp, "v1.12", &fixture_cases);
    // v1.9 sorts ABOVE v1.12 as a string, which is why discovery compares
    // components numerically rather than comparing names.
    try writeFixture(&tmp, "v1.9", &.{fixture_cases[0]});
    try writeFixture(&tmp, "v1.10", &.{fixture_cases[0]});
    // A three-component sibling must be ignored entirely: truncating it to
    // v1.13 would select a directory that does not exist.
    try writeFixture(&tmp, "v1.13.0-DEV", &.{fixture_cases[0]});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try loadFixture(arena_state.allocator(), &tmp, null);
    try testing.expect(std.mem.endsWith(u8, set.dir, "/v1.12"));
    try testing.expectEqual(@as(usize, 3), set.fixed.len);

    // An explicit version pins the directory even when others exist, and a
    // leading `v` is tolerated the way version.zig's parser tolerates it.
    for ([_][]const u8{ "1.10.9", "v1.10.9", "1.10" }) |v| {
        const older = try loadFixture(arena_state.allocator(), &tmp, v);
        try testing.expect(std.mem.endsWith(u8, older.dir, "/v1.10"));
        try testing.expectEqual(@as(usize, 1), older.fixed.len);
    }
}

test "a missing installation is an error, not an empty set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Silently returning an empty set here would let the resolver believe
    // there are no stdlibs and try to fetch all 61 from the registry.
    try testing.expectError(error.StdlibDirNotFound, load(
        arena_state.allocator(),
        testing.io,
        .{ .julia_prefix = "/nonexistent/julia", .julia_version = "1.12.6" },
    ));
    try testing.expectError(error.StdlibDirNotFound, load(
        arena_state.allocator(),
        testing.io,
        .{ .julia_prefix = "/nonexistent/julia" },
    ));
}

test "malformed project files fail loudly instead of dropping the stdlib" {
    // Julia throws on every one of these. Skipping instead would silently
    // shrink the fixed set, which is the corruption this module guards.
    const cases = [_]struct { want: anyerror, body: []const u8 }{
        .{ .want = error.InvalidUuid, .body =
        \\name = "Bad"
        \\uuid = "not-a-uuid"
        \\
        },
        // `::Union{String, Nothing}` type assertion, Types.jl:510.
        .{ .want = error.MalformedProjectFile, .body =
        \\name = "Bad"
        \\uuid = 42
        \\
        },
        // Types.jl:511 asserts the same for `version`...
        .{ .want = error.MalformedProjectFile, .body =
        \\name = "Bad"
        \\uuid = "00000000-0000-0000-0000-000000000001"
        \\version = 3
        \\
        },
        // ...and :512 constructs a VersionNumber from it.
        .{ .want = error.InvalidVersion, .body =
        \\name = "Bad"
        \\uuid = "00000000-0000-0000-0000-000000000001"
        \\version = "not.a.version"
        \\
        },
        // Both of the above are evaluated BEFORE the missing-uuid skip at
        // :513, so a broken version still throws when there is no uuid.
        .{ .want = error.InvalidVersion, .body =
        \\name = "Bad"
        \\version = "not.a.version"
        \\
        },
        // `UUID.(values(...))` over a non-table / a non-string value.
        .{ .want = error.MalformedProjectFile, .body =
        \\name = "Bad"
        \\uuid = "00000000-0000-0000-0000-000000000001"
        \\deps = 7
        \\
        },
        .{ .want = error.MalformedProjectFile, .body =
        \\name = "Bad"
        \\uuid = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\Other = 9
        \\
        },
        .{ .want = error.InvalidUuid, .body =
        \\name = "Bad"
        \\uuid = "00000000-0000-0000-0000-000000000001"
        \\
        \\[deps]
        \\Other = "nope"
        \\
        },
    };

    for (cases) |c| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try writeFixture(&tmp, "v1.12", &.{.{
            .name = "Bad",
            .files = &.{.{ .name = "Project.toml", .body = c.body }},
        }});

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectError(c.want, loadFixture(arena_state.allocator(), &tmp, "1.12.6"));
    }
}

test "majorMinor takes the first two components only" {
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), majorMinor("1.12.6"));
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), majorMinor("1.12"));
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), majorMinor("1.12.0-rc1"));
    try testing.expectEqual(@as(?[2]u64, .{ 10, 0 }), majorMinor("10.0.0"));
    // A leading `v`/`V`, as version.zig:128 accepts.
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), majorMinor("v1.12.6"));
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), majorMinor("V1.12"));
    try testing.expectEqual(@as(?[2]u64, null), majorMinor("1"));
    try testing.expectEqual(@as(?[2]u64, null), majorMinor("1."));
    try testing.expectEqual(@as(?[2]u64, null), majorMinor("x.y"));
    try testing.expectEqual(@as(?[2]u64, null), majorMinor(""));
}

test "versionDirName matches only an exact v<major>.<minor>" {
    try testing.expectEqual(@as(?[2]u64, .{ 1, 12 }), versionDirName("v1.12"));
    try testing.expectEqual(@as(?[2]u64, .{ 10, 4 }), versionDirName("v10.4"));
    // The whole point: no truncating prefix match.
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("v1.13.0-DEV"));
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("v1.12-beta"));
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("1.12"));
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("vX.Y"));
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("v1."));
    try testing.expectEqual(@as(?[2]u64, null), versionDirName("compiled"));
}

test "canonicalUuid renders lowercase 8-4-4-4-12" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Julia's `string(::UUID)` is always lowercase; a registry or manifest
    // lookup keyed on the uppercase source text would silently miss.
    const u = try Uuid.parse("8BB1440F-4735-579B-A4AB-409B98DF4DAB");
    try testing.expectEqualStrings(delimitedfiles_uuid, try canonicalUuid(arena, u));
    // Leading zeros must survive.
    const z = try Uuid.parse("00000000-0000-0000-0000-000000000001");
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000001", try canonicalUuid(arena, z));
}
