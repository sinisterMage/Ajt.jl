//! Reading a Julia package registry.
//!
//! Port of the parts of `Pkg/src/Registry/registry_instance.jl` that the
//! resolver needs: the package table, per-package versions, and the
//! *uncompressed* dependency and compat maps.
//!
//! The subtle piece is `uncompress` (`registry_instance.jl:70-102`).
//! `Deps.toml`/`Compat.toml` are keyed by a `VersionRange`, and expanding one
//! is NOT "apply to every version satisfying the range". It is:
//!
//!   * find the FIRST index whose version satisfies the range,
//!   * find the LAST index whose version satisfies the range,
//!   * apply the entry to every index in `first..last` **inclusive**.
//!
//! So a version sitting between those endpoints inherits the entry even if it
//! does not itself satisfy the range. Implementing the intuitive reading gives
//! subtly different dependency sets for exactly the packages whose version
//! lists are non-contiguous — a bug that would surface as a mysterious
//! resolution difference much later.
//!
//! A duplicate DEP key across two overlapping spans is an error ("Overlapping
//! ranges"), not a last-one-wins merge.
//!
//! Separately, two textually different SECTION keys can normalise to the same
//! `VersionRange` (because its constructor collapses `lo.t == hi.t`), in which
//! case Julia's `Dict`-keyed storage silently drops one — see
//! `supersededLater` below. Found by differential testing, not by reading:
//! one file in all of General hits it.
//!
//! ## Two places the same files can come from
//!
//! Pkg reads a registry either out of an in-memory tarball or straight off the
//! filesystem, and it does so behind ONE pair of accessors — `parsefile` and
//! `custom_isfile` (`registry_instance.jl:212-224`), which take an
//! `in_memory_registry::Union{Dict, Nothing}` and dispatch on its being
//! `nothing`. Everything above them is written once.
//!
//! `Files` below is that seam. `registries/General.tar.gz` is one arm;
//! `registries/General/` — a git clone, a hand-unpacked snapshot, or a
//! `JULIA_PKG_UNPACK_REGISTRY=true` install — is the other, and it is a
//! first-class Pkg layout (`registry_instance.jl:337-342`,
//! `:429-441`), not a fallback. Only the ~six-line reader differs; the
//! uncompression rules below, which are the part that is hard to get right,
//! are shared by construction.
//!
//! The directory arm is also LAZY, again like Pkg: `open` reads one
//! `Registry.toml` and `loadPackage` reads at most six small files per
//! package, where the tarball arm has to inflate and index all ~59,000 of
//! them up front.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tarball = @import("tarball.zig");
const toml = @import("../toml/parse.zig");
const Table = @import("../toml/value.zig").Table;
const Value = @import("../toml/value.zig").Value;
const version_mod = @import("../julia/version.zig");
const Version = version_mod.Version;
const versions_mod = @import("../julia/versions.zig");
const Spec = versions_mod.Spec;

/// Every registered package implicitly depends on julia
/// (`registry_instance.jl:104`, injected at `:227`).
pub const julia_uuid = "1222c4b2-2114-5bfd-aeef-88e4692bbb3e";

pub const Error = error{
    MalformedRegistry,
    OverlappingRanges,
    UnknownPackage,
    /// A file in a directory-backed registry exists but could not be read —
    /// a permission problem, a dangling symlink, a directory where a file
    /// belongs. Deliberately NOT folded into "the file is absent": absence is
    /// a legal answer for every registry file except `Registry.toml` and
    /// `Versions.toml`, so reporting an unreadable `Deps.toml` as missing
    /// would silently produce a package with no dependencies.
    RegistryReadFailed,
    /// A `packages.<uuid>.path` in `Registry.toml` that names something
    /// outside the registry directory. See `safeSubPath`.
    UnsafePackagePath,
} || toml.Error || versions_mod.ParseError || version_mod.ParseError || Allocator.Error || Io.Cancelable;

pub const PackageRef = struct {
    uuid: []const u8,
    name: []const u8,
    /// Path within the archive, e.g. `S/StaticArrays`. NEVER reconstruct this
    /// from the name: the registry also contains a `jll/` subtree, so the
    /// `<Letter>/<Name>` shape does not hold universally.
    path: []const u8,
};

/// Where a registry's files come from: an in-memory tarball, or a directory.
///
/// The union stands in for Pkg's `in_memory_registry::Union{Dict, Nothing}`
/// (`registry_instance.jl:212-224`) and answers the same two questions —
/// "give me this file" and, through a null return, "is this file here at all"
/// (`custom_isfile`).
pub const Files = union(enum) {
    archive: tarball.Archive,
    dir: Dir,

    pub fn deinit(self: *Files) void {
        switch (self.*) {
            .archive => |*a| a.deinit(),
            .dir => |*d| d.deinit(),
        }
    }

    /// The file's bytes, or null when it is not there. The returned slice
    /// lives as long as the `Files` does, whichever arm answered.
    pub fn get(self: *const Files, path: []const u8) Error!?[]const u8 {
        return switch (self.*) {
            .archive => |*a| a.get(path),
            .dir => |*d| d.read(path),
        };
    }

    /// Where parsed values are allocated. For the tarball arm this is the
    /// archive's own arena, which is what makes a `PackageRef` borrowed from
    /// `Registry.toml` live exactly as long as the archive; the directory arm
    /// keeps an arena with the same lifetime for the same reason.
    pub fn arena(self: *Files) Allocator {
        return switch (self.*) {
            .archive => |*a| a.arena.allocator(),
            .dir => |*d| d.arena_state.allocator(),
        };
    }
};

/// A registry read straight off the filesystem: `<depot>/registries/<Name>/`
/// holding `Registry.toml` and the `<X>/<Name>/` package tree.
///
/// This is what a `git clone` of General looks like, what
/// `JULIA_PKG_UNPACK_REGISTRY=true` installs (`Registry.jl:242-251`), and what
/// somebody who unpacked a snapshot by hand has. Pkg treats all three
/// identically — `reachable_registries` calls every directory under
/// `registries/` a candidate and loads any that has a `Registry.toml`
/// (`registry_instance.jl:429-441`).
pub const Dir = struct {
    /// The registry root, held open for the `Registry`'s lifetime so every
    /// read is an `openat` relative to one fd rather than a path walk, and so
    /// the directory cannot be swapped underneath a half-finished parse.
    root: Io.Dir,
    io: Io,
    /// Owns every byte read out of the directory. Heap-allocated because
    /// `loadPackage` takes a `*const Registry`, and an inline
    /// `ArenaAllocator` cannot be allocated from through a const receiver.
    arena_state: *std.heap.ArenaAllocator,

    /// A registry file will not be larger than this. General's own
    /// `Registry.toml` is the biggest file in it at ~2.7 MB; the cap exists so
    /// that a hostile or corrupt registry cannot turn one `readFileAlloc` into
    /// an unbounded allocation.
    const max_file_bytes = 64 * 1024 * 1024;

    /// Open `path` as a registry directory. The caller owns the result and
    /// must `deinit` it.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !Dir {
        var root = try Io.Dir.cwd().openDir(io, path, .{});
        errdefer root.close(io);
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        return .{ .root = root, .io = io, .arena_state = state };
    }

    pub fn deinit(self: *Dir) void {
        const gpa = self.arena_state.child_allocator;
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
        self.root.close(self.io);
    }

    /// `parsefile`'s filesystem branch (`registry_instance.jl:214`), with
    /// `custom_isfile` folded in as a null return (`:223`).
    ///
    /// Paths are the same forward-slash archive paths the tarball arm uses,
    /// which `Io.Dir` accepts as relative sub-paths. Julia converts in the
    /// other direction, with `to_tar_path_format` (`:9-14`) rewriting `\` to
    /// `/` for the in-memory case only.
    pub fn read(self: *const Dir, path: []const u8) Error!?[]const u8 {
        if (!safeSubPath(path)) return error.UnsafePackagePath;
        const arena = self.arena_state.allocator();
        return self.root.readFileAlloc(self.io, path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
            // The only "no" answer. `custom_isfile` is a plain `isfile`, and
            // every caller below treats false as "this registry records
            // nothing here".
            error.FileNotFound => null,
            error.Canceled => |e| e,
            error.OutOfMemory => |e| e,
            else => error.RegistryReadFailed,
        };
    }
};

/// Reject a registry-internal path that could climb out of the registry
/// directory, before it reaches `openat`.
///
/// **Pkg does not check this.** `PkgEntry.path` comes from the `path` field of
/// a `Registry.toml` entry (`registry_instance.jl:363`) and is joined onto the
/// registry root unexamined (`:190`), so a registry declaring
/// `path = "../../../../etc"` reads outside the depot on the directory arm.
/// The tarball arm cannot express it — a lookup there is a hash-map hit, not a
/// path walk — so this is the one arm where the guard is needed. Same argument
/// as `ops/registry_ops.zig:checkRegistryName`: registry metadata is
/// attacker-influenced data being used as a path.
fn safeSubPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

pub const Registry = struct {
    files: Files,
    name: []const u8 = "",
    uuid: []const u8 = "",
    packages: []PackageRef = &.{},

    pub fn deinit(self: *Registry) void {
        self.files.deinit();
    }

    /// How many files the backing archive holds, or null when the registry is
    /// a directory and nothing has been counted. `ajt registry status` prints
    /// it; there is no cheap equivalent for a lazily-read directory, and
    /// walking one to invent a number would be a `stat` per file for a
    /// diagnostic line.
    pub fn fileCount(self: *const Registry) ?usize {
        return switch (self.files) {
            .archive => |a| a.count(),
            .dir => null,
        };
    }

    pub fn findByName(self: *const Registry, name: []const u8) ?PackageRef {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn findByUuid(self: *const Registry, uuid: []const u8) ?PackageRef {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.uuid, uuid)) return p;
        }
        return null;
    }
};

/// Parses `Registry.toml` out of an already-loaded archive. Takes ownership of
/// the archive.
pub fn open(archive: tarball.Archive) Error!Registry {
    var reg: Registry = .{ .files = .{ .archive = archive } };
    try parseRegistryToml(&reg);
    return reg;
}

/// The same, for a registry that is a DIRECTORY: a git clone, a hand-unpacked
/// snapshot, or a `JULIA_PKG_UNPACK_REGISTRY=true` install.
///
/// `path` is the registry root — `<depot>/registries/<Name>` — i.e. the
/// directory holding `Registry.toml`, which is exactly what
/// `RegistryInstance(path)` takes (`registry_instance.jl:329`).
///
/// Takes ownership of nothing on failure: the opened directory and its arena
/// are released before the error propagates, so a caller that retries another
/// backend leaks neither.
pub fn openDir(gpa: Allocator, io: Io, path: []const u8) !Registry {
    var dir = try Dir.open(gpa, io, path);
    errdefer dir.deinit();
    var reg: Registry = .{ .files = .{ .dir = dir } };
    try parseRegistryToml(&reg);
    return reg;
}

/// `d = parsefile(in_memory_registry, path, "Registry.toml")` and the
/// `d["packages"]` loop that follows it (`registry_instance.jl:357-366`),
/// written once for both arms.
fn parseRegistryToml(reg: *Registry) Error!void {
    const arena = reg.files.arena();

    const src = (try reg.files.get("Registry.toml")) orelse return error.MalformedRegistry;
    var doc = try toml.parse(arena, src, null);
    // NB: doc's arena hangs off the files' arena, so no separate deinit.

    if (doc.root.get("name")) |v| switch (v) {
        .string => |s| reg.name = s,
        else => {},
    };
    if (doc.root.get("uuid")) |v| switch (v) {
        .string => |s| reg.uuid = s,
        else => {},
    };

    const pkgs_tbl: *Table = if (doc.root.get("packages")) |v| switch (v) {
        .table => |t| t,
        else => return error.MalformedRegistry,
    } else return error.MalformedRegistry;

    var list = try arena.alloc(PackageRef, pkgs_tbl.entries.items.len);
    var n: usize = 0;
    for (pkgs_tbl.entries.items) |e| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const nm = switch (t.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const pth = switch (t.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        list[n] = .{ .uuid = e.key, .name = nm, .path = pth };
        n += 1;
    }
    reg.packages = list[0..n];
}

pub const VersionInfo = struct {
    version: Version,
    tree_hash: []const u8,
    yanked: bool = false,
};

pub const Dep = struct {
    name: []const u8,
    uuid: []const u8,
    /// Already uncompressed; `*` when the registry records no constraint.
    compat: Spec,
    /// From `WeakDeps.toml` rather than `Deps.toml`. A weak edge does NOT
    /// require the package: it only constrains it IF something else selects
    /// it. Treating one as strong silently widens the dependency set — on
    /// Open-Reality it pulled in Adapt, GPUArraysCore and RecipesBase, none of
    /// which Julia's own manifest contains.
    weak: bool = false,
};

/// A package's registry entry, fully uncompressed. Owns its own arena.
pub const PackageInfo = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    uuid: []const u8,
    repo: []const u8 = "",
    /// `Package.toml`'s `subdir` for a package that lives inside a monorepo,
    /// `""` when it does not. `set_repo_source_from_registry!` copies it onto
    /// the spec alongside `repo` (`Types.jl:917-919`), so `add Foo#main` on
    /// such a package clones the repository and then descends.
    subdir: []const u8 = "",
    /// Ascending by version.
    versions: []VersionInfo,
    /// `deps[i]` are the dependencies of `versions[i]`.
    deps: [][]Dep,

    pub fn deinit(self: *PackageInfo) void {
        self.arena.deinit();
    }

    pub fn indexOfVersion(self: *const PackageInfo, v: Version) ?usize {
        for (self.versions, 0..) |vi, i| {
            if (vi.version.eql(v)) return i;
        }
        return null;
    }
};

/// Reads and uncompresses one package's registry entry.
pub fn loadPackage(gpa: Allocator, reg: *const Registry, ref: PackageRef) Error!PackageInfo {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buf: [512]u8 = undefined;

    // --- Package.toml -------------------------------------------------------
    var repo: []const u8 = "";
    var subdir: []const u8 = "";
    if (try reg.files.get(try join(&path_buf, ref.path, "Package.toml"))) |src| {
        var doc = try toml.parse(arena, src, null);
        if (doc.root.get("repo")) |v| switch (v) {
            .string => |s| repo = s,
            else => {},
        };
        if (doc.root.get("subdir")) |v| switch (v) {
            .string => |s| subdir = s,
            else => {},
        };
    }

    // --- Versions.toml ------------------------------------------------------
    const versions_src = (try reg.files.get(try join(&path_buf, ref.path, "Versions.toml"))) orelse
        return error.MalformedRegistry;
    const vdoc = try toml.parse(arena, versions_src, null);

    var vlist: std.ArrayList(VersionInfo) = .empty;
    for (vdoc.root.entries.items) |e| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const th = switch (t.get("git-tree-sha1") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const yanked = if (t.get("yanked")) |y| switch (y) {
            .boolean => |b| b,
            else => false,
        } else false;
        try vlist.append(arena, .{
            .version = try version_mod.parse(arena, e.key),
            .tree_hash = th,
            .yanked = yanked,
        });
    }
    std.mem.sort(VersionInfo, vlist.items, {}, struct {
        fn lt(_: void, a: VersionInfo, b: VersionInfo) bool {
            return a.version.lessThan(b.version);
        }
    }.lt);
    const vsorted = vlist.items;

    // --- Deps.toml / Compat.toml -------------------------------------------
    // Per version: name -> uuid, and name -> spec.
    const dep_maps = try arena.alloc(std.StringHashMapUnmanaged([]const u8), vsorted.len);
    const compat_maps = try arena.alloc(std.StringHashMapUnmanaged(Spec), vsorted.len);
    for (dep_maps, compat_maps) |*d, *c| {
        d.* = .empty;
        c.* = .empty;
    }

    if (try reg.files.get(try join(&path_buf, ref.path, "Deps.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressDeps(arena, doc.root, vsorted, dep_maps);
    }
    if (try reg.files.get(try join(&path_buf, ref.path, "Compat.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressCompat(arena, doc.root, vsorted, compat_maps);
    }

    // WeakDeps.toml / WeakCompat.toml use the identical compressed-range
    // encoding, so they go through the same two uncompressors. 1,597 of
    // General's 13,969 packages have weak deps; ignoring them is not a rare
    // edge case.
    const weak_dep_maps = try arena.alloc(std.StringHashMapUnmanaged([]const u8), vsorted.len);
    const weak_compat_maps = try arena.alloc(std.StringHashMapUnmanaged(Spec), vsorted.len);
    for (weak_dep_maps, weak_compat_maps) |*d, *c| {
        d.* = .empty;
        c.* = .empty;
    }
    if (try reg.files.get(try join(&path_buf, ref.path, "WeakDeps.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressDeps(arena, doc.root, vsorted, weak_dep_maps);
    }
    if (try reg.files.get(try join(&path_buf, ref.path, "WeakCompat.toml"))) |src| {
        const doc = try toml.parse(arena, src, null);
        try uncompressCompat(arena, doc.root, vsorted, weak_compat_maps);
    }

    // --- stitch deps + compat ----------------------------------------------
    const deps = try arena.alloc([]Dep, vsorted.len);
    for (0..vsorted.len) |i| {
        var out: std.ArrayList(Dep) = .empty;
        var it = dep_maps[i].iterator();
        while (it.next()) |kv| {
            const dname = kv.key_ptr.*;
            const spec = compat_maps[i].get(dname) orelse try Spec.all(arena);
            try out.append(arena, .{ .name = dname, .uuid = kv.value_ptr.*, .compat = spec });
        }
        // A name in BOTH tables is WEAK for that version. Do not reach for the
        // `Project.toml` deps∩weakdeps analogy here -- it points the other way
        // and is wrong. `initialize_uncompressed!` (`registry_instance.jl:105`)
        // does not subtract weak names from the strong set, but
        // `Operations.jl:732` then records `weak_compat_u[v] = keys(...)` from
        // the weak table, and that is what the resolver consults to decide
        // which edges force installation.
        //
        // This is not hypothetical: OffsetArrays declares `Adapt` strong for
        // `1.4-1` in Deps.toml AND weak for `1.13-1` in WeakDeps.toml. Reading
        // it as strong pulls Adapt into the resolved set, which Julia's own
        // manifest for Open-Reality does not contain.
        var wit = weak_dep_maps[i].iterator();
        while (wit.next()) |kv| {
            const dname = kv.key_ptr.*;
            const spec = weak_compat_maps[i].get(dname) orelse try Spec.all(arena);
            for (out.items) |*existing| {
                if (std.mem.eql(u8, existing.name, dname)) {
                    existing.weak = true;
                    break;
                }
            } else {
                try out.append(arena, .{
                    .name = dname,
                    .uuid = kv.value_ptr.*,
                    .compat = spec,
                    .weak = true,
                });
            }
        }
        // Everything depends on julia (registry_instance.jl:227). Its constraint
        // comes from Compat.toml like any other dep.
        if (dep_maps[i].get("julia") == null) {
            const spec = compat_maps[i].get("julia") orelse try Spec.all(arena);
            try out.append(arena, .{ .name = "julia", .uuid = julia_uuid, .compat = spec });
        }
        std.mem.sort(Dep, out.items, {}, struct {
            fn lt(_: void, a: Dep, b: Dep) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        deps[i] = out.items;
    }

    return .{
        .arena = arena_state,
        .name = ref.name,
        .uuid = ref.uuid,
        .repo = repo,
        .subdir = subdir,
        .versions = vsorted,
        .deps = deps,
    };
}

fn join(buf: []u8, dir: []const u8, file: []const u8) Allocator.Error![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, file }) catch return error.OutOfMemory;
}

/// True when a LATER section in the same file parses to an equal `VersionRange`.
///
/// Julia stores these files as `Dict{VersionRange, ...}` and assigns
/// `compat[vr] = d` per section (`registry_instance.jl:210-214`), so when two
/// textually different keys normalise to the same range, one section is
/// silently DROPPED. `VersionRange`'s constructor collapses `lo.t == hi.t`, so
/// e.g. `["2 - 2.0"]` and `["2.0"]` are the same key.
///
/// This is real: `O/OrdinaryDiffEqNonlinearSolve/Compat.toml` contains exactly
/// that pair, and it is the ONLY such file among 29,381 in General. Julia's
/// winner depends on `Dict` hash iteration order, so it is not reproducible by
/// construction; Ajt takes the LAST section in file order, which is
/// deterministic and happens to agree with Julia on the one real instance.
///
/// Applying both sections instead would arguably be more faithful to what the
/// registry author wrote, but it would diverge from Julia and could hand the
/// resolver two conflicting constraints for one version span.
fn supersededLater(entries: []const @import("../toml/value.zig").Entry, i: usize, r: versions_mod.Range) bool {
    for (entries[i + 1 ..]) |later| {
        const lr = versions_mod.Range.parse(later.key) catch continue;
        if (lr.eql(r)) return true;
    }
    return false;
}

/// Finds the `first..last` index span a range key covers. Returns null when the
/// range matches nothing.
fn rangeSpan(range_text: []const u8, vsorted: []const VersionInfo) Error!?struct { first: usize, last: usize } {
    const range = try versions_mod.Range.parse(range_text);
    var first: ?usize = null;
    for (vsorted, 0..) |vi, i| {
        if (range.contains(vi.version)) {
            first = i;
            break;
        }
    }
    const f = first orelse return null;
    var last: usize = f;
    var i: usize = vsorted.len;
    while (i > 0) {
        i -= 1;
        if (range.contains(vsorted[i].version)) {
            last = i;
            break;
        }
    }
    return .{ .first = f, .last = last };
}

fn uncompressDeps(
    arena: Allocator,
    root: *const Table,
    vsorted: []const VersionInfo,
    out: []std.StringHashMapUnmanaged([]const u8),
) Error!void {
    for (root.entries.items, 0..) |e, ei| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const parsed = versions_mod.Range.parse(e.key) catch continue;
        if (supersededLater(root.entries.items, ei, parsed)) continue;
        const span = (try rangeSpan(e.key, vsorted)) orelse continue;
        for (span.first..span.last + 1) |i| {
            for (t.entries.items) |kv| {
                const uuid = switch (kv.value) {
                    .string => |s| s,
                    else => continue,
                };
                if (out[i].contains(kv.key)) return error.OverlappingRanges;
                try out[i].put(arena, kv.key, uuid);
            }
        }
    }
}

fn uncompressCompat(
    arena: Allocator,
    root: *const Table,
    vsorted: []const VersionInfo,
    out: []std.StringHashMapUnmanaged(Spec),
) Error!void {
    for (root.entries.items, 0..) |e, ei| {
        const t = switch (e.value) {
            .table => |t| t,
            else => continue,
        };
        const parsed = versions_mod.Range.parse(e.key) catch continue;
        if (supersededLater(root.entries.items, ei, parsed)) continue;
        const span = (try rangeSpan(e.key, vsorted)) orelse continue;
        for (span.first..span.last + 1) |i| {
            for (t.entries.items) |kv| {
                // A compat value is either one range string or an array of them.
                const spec: Spec = switch (kv.value) {
                    .string => |s| try Spec.parse(arena, s),
                    .array => |items| blk: {
                        const parts = try arena.alloc([]const u8, items.len);
                        for (items, 0..) |item, j| parts[j] = switch (item) {
                            .string => |s| s,
                            else => return error.MalformedRegistry,
                        };
                        break :blk try Spec.parseMany(arena, parts);
                    },
                    else => continue,
                };
                if (out[i].contains(kv.key)) return error.OverlappingRanges;
                try out[i].put(arena, kv.key, spec);
            }
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// One registry, in the form both arms have to agree on. Shared between the
/// tarball fixture and the directory fixture so "the two backends read the
/// same registry" is true by construction rather than by two copies of a
/// literal drifting apart.
const mini_entries = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "Registry.toml", .data =
    \\name = "Mini"
    \\uuid = "23338594-aafe-5451-b93e-139f81909106"
    \\
    \\[packages]
    \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
    \\
    },
    .{ .name = "D/Demo/Package.toml", .data =
    \\name = "Demo"
    \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
    \\repo = "https://example.com/Demo.jl.git"
    \\
    },
    .{ .name = "D/Demo/Versions.toml", .data =
    \\["1.0.0"]
    \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    \\
    \\["1.1.0"]
    \\git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    \\
    \\["2.0.0"]
    \\git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
    \\yanked = true
    \\
    },
    .{ .name = "D/Demo/Deps.toml", .data =
    \\["1"]
    \\Alpha = "00000000-0000-0000-0000-0000000000a1"
    \\
    \\["2"]
    \\Beta = "00000000-0000-0000-0000-0000000000b1"
    \\
    },
    .{ .name = "D/Demo/Compat.toml", .data =
    \\["1"]
    \\Alpha = "0.5"
    \\julia = "1.6.0 - 1"
    \\
    \\["2"]
    \\Beta = ["0.7", "1-1.11"]
    \\
    },
};

fn miniRegistry(gpa: Allocator) !Registry {
    const buf = try gpa.alloc(u8, 16384);
    defer gpa.free(buf);
    const tar_bytes = tarball_buildTar(buf, &mini_entries);
    const archive = try tarball.loadTar(gpa, tar_bytes);
    return open(archive);
}

/// The same registry, written out as a directory under `root`.
fn writeMiniDir(io: std.Io, root: std.Io.Dir) !void {
    for (mini_entries) |e| {
        if (std.fs.path.dirname(e.name)) |parent| try root.createDirPath(io, parent);
        try root.writeFile(io, .{ .sub_path = e.name, .data = e.data });
    }
}

/// Mirrors the tar builder in tarball.zig's tests.
fn tarball_buildTar(buf: []u8, entries: anytype) []u8 {
    @memset(buf, 0);
    var off: usize = 0;
    for (entries) |e| {
        const h = buf[off..][0..512];
        @memcpy(h[0..e.name.len], e.name);
        _ = std.fmt.bufPrint(h[100..][0..8], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(h[108..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[116..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[124..][0..12], "{o:0>11}", .{e.data.len}) catch unreachable;
        _ = std.fmt.bufPrint(h[136..][0..12], "{o:0>11}", .{@as(u32, 0)}) catch unreachable;
        h[156] = '0';
        @memcpy(h[257..][0..6], "ustar\x00");
        @memcpy(h[263..][0..2], "00");
        @memset(h[148..][0..8], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;
        off += 512;
        @memcpy(buf[off..][0..e.data.len], e.data);
        off += std.mem.alignForward(usize, e.data.len, 512);
    }
    off += 1024;
    return buf[0..off];
}

test "opens a registry and lists packages" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();

    try testing.expectEqualStrings("Mini", reg.name);
    try testing.expectEqual(@as(usize, 1), reg.packages.len);
    try testing.expectEqualStrings("Demo", reg.packages[0].name);
    // Path comes from Registry.toml, never reconstructed from the name.
    try testing.expectEqualStrings("D/Demo", reg.packages[0].path);
    try testing.expect(reg.findByName("Demo") != null);
    try testing.expect(reg.findByName("Nope") == null);
}

test "loads versions sorted, with tree hashes and yank flags" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();

    try testing.expectEqualStrings("https://example.com/Demo.jl.git", pkg.repo);
    try testing.expectEqual(@as(usize, 3), pkg.versions.len);
    try testing.expectEqual(@as(u64, 1), pkg.versions[0].version.major);
    try testing.expectEqual(@as(u64, 1), pkg.versions[1].version.minor);
    try testing.expectEqual(@as(u64, 2), pkg.versions[2].version.major);
    try testing.expect(!pkg.versions[0].yanked);
    try testing.expect(pkg.versions[2].yanked);
    try testing.expectEqualStrings("aaaa" ++ "a" ** 36, pkg.versions[0].tree_hash);
}

test "deps and compat are uncompressed per version, with julia injected" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();

    // 1.0.0 and 1.1.0 both fall in the ["1"] range -> Alpha.
    for ([_]usize{ 0, 1 }) |i| {
        try testing.expectEqual(@as(usize, 2), pkg.deps[i].len); // Alpha + julia
        try testing.expectEqualStrings("Alpha", pkg.deps[i][0].name);
        try testing.expectEqualStrings("julia", pkg.deps[i][1].name);

        const alpha = try pkg.deps[i][0].compat.toString(testing.allocator);
        defer testing.allocator.free(alpha);
        try testing.expectEqualStrings("0.5", alpha);

        const jl = try pkg.deps[i][1].compat.toString(testing.allocator);
        defer testing.allocator.free(jl);
        try testing.expectEqualStrings("1.6.0 - 1", jl);
    }

    // 2.0.0 falls in ["2"] -> Beta, and julia is unconstrained there.
    try testing.expectEqual(@as(usize, 2), pkg.deps[2].len);
    try testing.expectEqualStrings("Beta", pkg.deps[2][0].name);
    const beta = try pkg.deps[2][0].compat.toString(testing.allocator);
    defer testing.allocator.free(beta);
    // A compat ARRAY is a union of ranges. `0.7` and `1-1.11` are NOT
    // joinable -- isjoinable compares up=(0,7) against lo=(1) over their
    // common prefix, and 0 < 1 ends it -- so they stay two ranges and the
    // spec prints in bracket form. Confirmed against
    //   julia -e 'print(Pkg.Versions.VersionSpec(["0.7","1-1.11"]))'
    try testing.expectEqualStrings("[0.7, 1 - 1.11]", beta);

    const jl2 = try pkg.deps[2][1].compat.toString(testing.allocator);
    defer testing.allocator.free(jl2);
    try testing.expectEqualStrings("*", jl2);
}

test "a range covering nothing contributes nothing" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    var pkg = try loadPackage(testing.allocator, &reg, reg.findByName("Demo").?);
    defer pkg.deinit();
    // Every version got exactly one real dep plus julia; nothing leaked across.
    for (pkg.deps) |d| try testing.expectEqual(@as(usize, 2), d.len);
}

// ---------------------------------------------------------------------------
// The directory arm.
// ---------------------------------------------------------------------------

test "a registry read from a directory answers exactly as the tarball does" {
    // The assertion that matters is not "the directory arm returns something"
    // but "it returns the SAME thing", field for field, from byte-identical
    // content. Anything less would let the two readers drift — and the one
    // that drifts is the one nothing else in the test suite exercises.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Mini");
    var root = try tmp.dir.openDir(io, "Mini", .{});
    defer root.close(io);
    try writeMiniDir(io, root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const path = try tmp.dir.realPathFileAlloc(io, "Mini", arena_state.allocator());

    var dir_reg = try openDir(gpa, io, path);
    defer dir_reg.deinit();
    var tar_reg = try miniRegistry(gpa);
    defer tar_reg.deinit();

    try testing.expectEqualStrings(tar_reg.name, dir_reg.name);
    try testing.expectEqualStrings(tar_reg.uuid, dir_reg.uuid);
    try testing.expectEqual(tar_reg.packages.len, dir_reg.packages.len);
    try testing.expectEqualStrings("D/Demo", dir_reg.packages[0].path);
    // The tarball arm can count its files; a lazily-read directory cannot, and
    // must say so rather than invent a number.
    try testing.expect(tar_reg.fileCount().? == 5);
    try testing.expect(dir_reg.fileCount() == null);

    var a = try loadPackage(gpa, &dir_reg, dir_reg.findByName("Demo").?);
    defer a.deinit();
    var b = try loadPackage(gpa, &tar_reg, tar_reg.findByName("Demo").?);
    defer b.deinit();

    try testing.expectEqualStrings(b.repo, a.repo);
    try testing.expectEqual(b.versions.len, a.versions.len);
    for (a.versions, b.versions) |va, vb| {
        try testing.expect(va.version.eql(vb.version));
        try testing.expectEqualStrings(vb.tree_hash, va.tree_hash);
        try testing.expectEqual(vb.yanked, va.yanked);
    }
    for (a.deps, b.deps) |da, db| {
        try testing.expectEqual(db.len, da.len);
        for (da, db) |x, y| {
            try testing.expectEqualStrings(y.name, x.name);
            try testing.expectEqualStrings(y.uuid, x.uuid);
            try testing.expectEqual(y.weak, x.weak);
            const sx = try x.compat.toString(gpa);
            defer gpa.free(sx);
            const sy = try y.compat.toString(gpa);
            defer gpa.free(sy);
            try testing.expectEqualStrings(sy, sx);
        }
    }

    // An absent optional file is a legal answer on both arms (`custom_isfile`);
    // this registry carries no WeakDeps.toml and both read it as "no weak deps".
    try testing.expect((try dir_reg.files.get("D/Demo/WeakDeps.toml")) == null);
}

test "a directory registry whose Registry.toml points outside itself is refused" {
    // Pkg joins `packages.<uuid>.path` onto the registry root unexamined
    // (`registry_instance.jl:190`), so on the directory arm a hostile registry
    // reads whatever it names. The tarball arm cannot express this at all —
    // its lookup is a hash-map hit — which is exactly why the guard belongs
    // here and not in the shared code above it.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Evil");
    try tmp.dir.writeFile(io, .{ .sub_path = "Evil/Registry.toml", .data =
        \\name = "Evil"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "../../../etc" }
        \\
    });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const path = try tmp.dir.realPathFileAlloc(io, "Evil", arena_state.allocator());

    var reg = try openDir(gpa, io, path);
    defer reg.deinit();
    try testing.expectError(
        error.UnsafePackagePath,
        loadPackage(gpa, &reg, reg.findByName("Demo").?),
    );
    try testing.expect(safeSubPath("D/Demo/Deps.toml"));
    try testing.expect(!safeSubPath("../x"));
    try testing.expect(!safeSubPath("a/../../b"));
    try testing.expect(!safeSubPath("/etc/passwd"));
}

test "a directory with no Registry.toml is not a registry" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Empty");

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const path = try tmp.dir.realPathFileAlloc(io, "Empty", arena_state.allocator());

    // And the directory handle plus its arena are released on the way out —
    // `openDir` takes ownership only on success, so the leak checker in this
    // allocator is the assertion.
    try testing.expectError(error.MalformedRegistry, openDir(gpa, io, path));
    try testing.expectError(error.FileNotFound, openDir(gpa, io, "no/such/registry"));
}
