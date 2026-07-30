//! Where a registry read comes from, and the one type everything downstream
//! should hold.
//!
//! There are two backends and they answer identically. `registry/index.zig`
//! parses `General.tar.gz` — 84 MB, ~59k files, about 1.5 s every time.
//! `registry/aix.zig` maps a prebuilt binary index of the same content, which
//! costs about 1 ms. Both hand back an `index.PackageRef` and an
//! `index.PackageInfo`, so a caller that goes through this union never has to
//! know which one it got.
//!
//! ## Three on-disk shapes, not one
//!
//! `open` probes the shapes Pkg's `reachable_registries` accepts
//! (`registry_instance.jl:429-441`), in its order of preference:
//!
//!   1. `<Name>.toml` + `<Name>.tar.gz` — the compressed layout, read either
//!      through a matching `.aix` index or by parsing the tarball.
//!   2. `<Name>/` — a DIRECTORY holding `Registry.toml`. A git clone, a
//!      `JULIA_PKG_UNPACK_REGISTRY=true` install, a hand-unpacked snapshot or
//!      a symlink to one; Pkg cannot tell them apart and neither does this.
//!
//! The stamp winning over a same-named directory is Pkg's rule, not a
//! preference: `reachable_registries` drops any directory whose basename
//! matches a `*.toml` in `registries/` (`:436-439`), so a depot holding both
//! must be read through the tarball or the two tools disagree about which
//! snapshot is installed.
//!
//! Shape 2 was invisible here until git-cloned registries were supported, and
//! its absence was not a missing feature so much as a wrong answer: `ajt add`,
//! `ajt resolve`, `ajt instantiate` and `ajt registry status` all failed with
//! `FileNotFound` on `General.tar.gz` against a depot that Pkg reads fine —
//! including one Pkg itself created with `JULIA_PKG_UNPACK_REGISTRY=true`.
//!
//! ## Why this lives in the library rather than the CLI
//!
//! It used to be private to `main.zig`, and the cost of that was measured
//! rather than argued: `ops/resolve.zig` could not reach it, so it called
//! `tarball.loadFromDepot` directly and every `resolve`, `add` and `up` paid
//! the full 1.5 s tarball parse with a matching `.aix` index sitting unused on
//! disk. A head-to-head benchmark against Pkg is what surfaced it — resolve
//! came out at parity when roughly three quarters of Ajt's time was a file it
//! did not need to read.
//!
//! ## `auto` is the whole point
//!
//! Use the index when one matches the installed registry, fall back to the
//! tarball when it does not, with no user action either way. The index
//! filename embeds the registry's git tree hash, so "matches" is exact and a
//! stale index is never chosen — invalidation is a name comparison, not an
//! mtime heuristic. `.aix` and `.archive` exist so a differential gate can pin
//! a side and compare the two.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const index = @import("index.zig");
const aix = @import("aix.zig");
const tarball = @import("tarball.zig");
const depot_mod = @import("../depot.zig");

pub const Preference = enum { auto, aix, archive };

/// A package located in whichever backend is open. Keeps the backend's native
/// reference rather than collapsing to `index.PackageRef`, because the `.aix`
/// reference carries a row index that its `loadPackage` needs — flattening it
/// would force a second lookup per package.
pub const Ref = union(enum) {
    archive: index.PackageRef,
    aix: aix.Ref,

    pub fn name(self: Ref) []const u8 {
        return switch (self) {
            .archive => |r| r.name,
            .aix => |r| r.name,
        };
    }

    pub fn uuid(self: Ref) []const u8 {
        return switch (self) {
            .archive => |r| r.uuid,
            .aix => |r| r.uuid,
        };
    }

    /// The `repo` field, or an empty string when the registry records none.
    /// Empty is a real third answer and not the same as "not registered":
    /// Julia skips such a package rather than treating it as missing
    /// (`Operations.jl:1099-1104`). Only `.aix` can answer without a parse.
    pub fn repoIfCheap(self: Ref) ?[]const u8 {
        return switch (self) {
            .aix => |r| r.repo,
            .archive => null,
        };
    }
};

/// A registry opened through either backend.
pub const Backend = union(enum) {
    archive: index.Registry,
    aix: aix.Mapped,

    pub fn deinit(self: *Backend, io: Io) void {
        switch (self.*) {
            .archive => |*r| r.deinit(),
            .aix => |*m| m.deinit(io),
        }
    }

    /// Which shape answered, for `ajt registry status` and for a gate that
    /// needs to prove WHICH reader ran. `archive` and `directory` are both
    /// `index.Registry`, so the distinction has to come from inside it —
    /// reporting a git clone as "archive" would make the one assertion that
    /// pins the new arm unfalsifiable.
    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| switch (r.files) {
                .archive => "archive",
                .dir => "directory",
            },
            .aix => "aix",
        };
    }

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| r.name,
            .aix => |m| m.index.name(),
        };
    }

    pub fn uuid(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| r.uuid,
            .aix => |m| m.index.uuid(),
        };
    }

    pub fn packageCount(self: Backend) usize {
        return switch (self) {
            .archive => |r| r.packages.len,
            .aix => |m| m.index.packageCount(),
        };
    }

    pub fn findByUuid(self: *const Backend, uuid_text: []const u8) ?Ref {
        return switch (self.*) {
            .archive => |*r| if (r.findByUuid(uuid_text)) |x| .{ .archive = x } else null,
            .aix => |*m| if (m.index.findByUuid(uuid_text)) |x| .{ .aix = x } else null,
        };
    }

    pub fn findByName(self: *const Backend, pkg_name: []const u8) ?Ref {
        return switch (self.*) {
            .archive => |*r| if (r.findByName(pkg_name)) |x| .{ .archive = x } else null,
            .aix => |*m| if (m.index.findByName(pkg_name)) |x| .{ .aix = x } else null,
        };
    }

    /// Every package, by index. For the callers that must scan — resolving a
    /// name to a UUID has to notice when two registered packages share a name.
    pub fn refAt(self: *const Backend, i: usize) ?Ref {
        return switch (self.*) {
            .archive => |*r| if (i < r.packages.len) .{ .archive = r.packages[i] } else null,
            .aix => |*m| if (i < m.index.packageCount()) .{ .aix = m.index.refAt(@intCast(i)) } else null,
        };
    }

    /// The package's full registry entry: versions, tree hashes, and the
    /// uncompressed deps and compat. Identical output from either backend.
    pub fn loadPackage(self: *const Backend, gpa: Allocator, ref: Ref) !index.PackageInfo {
        return switch (self.*) {
            .archive => |*r| index.loadPackage(gpa, r, ref.archive),
            .aix => |*m| m.index.loadPackage(gpa, ref.aix),
        };
    }

    /// Name first, then uuid — the order `ajt registry show` has always used.
    pub fn load(self: *const Backend, gpa: Allocator, target: []const u8) !?index.PackageInfo {
        const ref = self.findByName(target) orelse self.findByUuid(target) orelse return null;
        return try self.loadPackage(gpa, ref);
    }

    /// `find_urls`' registry half: the `repo` for a UUID, null when the
    /// registry does not carry the package at all. The archive backend has to
    /// parse the whole entry to reach `Package.toml`, which is one more reason
    /// `auto` prefers the index for anything whole-manifest sized.
    pub fn repoForUuid(
        self: *const Backend,
        gpa: Allocator,
        arena: Allocator,
        uuid_text: []const u8,
    ) !?[]const u8 {
        const ref = self.findByUuid(uuid_text) orelse return null;
        if (ref.repoIfCheap()) |repo| return try arena.dupe(u8, repo);
        var pkg = try self.loadPackage(gpa, ref);
        defer pkg.deinit();
        return try arena.dupe(u8, pkg.repo);
    }

    /// `set_repo_source_from_registry!` (`Types.jl:903-924`): the `repo` a
    /// package is cloned from, plus the `subdir` it lives in when the registry
    /// records one.
    ///
    /// Separate from `repoForUuid` because that one answers the install
    /// pipeline's question (a GitHub tarball URL, where a subdir is
    /// irrelevant) and is called once per manifest entry. This one is called
    /// once per `add Name#rev`, so the archive backend's whole-entry parse
    /// costs nothing worth avoiding — and dropping the subdir here would clone
    /// a monorepo and then read the WRONG package's `Project.toml`.
    pub fn repoSourceForUuid(
        self: *const Backend,
        gpa: Allocator,
        arena: Allocator,
        uuid_text: []const u8,
    ) !?RepoSource {
        const ref = self.findByUuid(uuid_text) orelse return null;
        switch (ref) {
            // The `.aix` index carries both fields inline; no parse at all.
            .aix => |r| return .{
                .url = try arena.dupe(u8, r.repo),
                .subdir = try arena.dupe(u8, r.subdir),
            },
            .archive => {
                var pkg = try self.loadPackage(gpa, ref);
                defer pkg.deinit();
                return .{
                    .url = try arena.dupe(u8, pkg.repo),
                    .subdir = try arena.dupe(u8, pkg.subdir),
                };
            },
        }
    }
};

/// What a registry says about where a package's source lives. Both fields are
/// `""` rather than null when the registry records nothing — empty is the
/// answer `Package.toml` gives by omission, and Julia skips such a package
/// rather than treating it as missing (`Operations.jl:1099-1104`).
pub const RepoSource = struct {
    url: []const u8,
    subdir: []const u8,
};

pub const OpenError = error{NoIndexForRegistry} || Allocator.Error;

/// Open a registry, preferring the index unless told otherwise.
///
/// `arena` holds the mapped index's path strings; `gpa` owns the archive's
/// ~84 MB when that is the branch taken. The returned `Backend` must be
/// `deinit`ed, and it borrows from both.
pub fn open(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    depot: []const u8,
    reg_name: []const u8,
    pref: Preference,
) !Backend {
    if (pref != .archive) {
        if (try aix.openForRegistry(arena, io, depot, reg_name)) |mapped| return .{ .aix = mapped };
        // `.aix` was demanded and there is none: say so rather than silently
        // costing the caller a 1.5 s parse it explicitly opted out of.
        if (pref == .aix) return OpenError.NoIndexForRegistry;
    }
    var archive = tarball.loadFromDepot(gpa, io, depot, reg_name) catch |err| switch (err) {
        // No `<Name>.tar.gz`. That is not "no registry" — the same name may be
        // installed as a directory, which is a first-class Pkg layout. Only
        // this error falls through: a tarball that exists but will not
        // decompress is a corrupt install and must be reported as one rather
        // than papered over by a directory that may be a stale shadow of it.
        error.FileNotFound => return openDirectory(gpa, arena, io, depot, reg_name, err),
        else => return err,
    };
    // `index.open` takes ownership only on SUCCESS; on a malformed
    // Registry.toml the arena is still ours to free.
    errdefer archive.deinit();
    return .{ .archive = try index.open(archive) };
}

/// `<depot>/registries/<Name>/Registry.toml`, read in place.
///
/// `fallback` is the error the tarball attempt produced, returned unchanged
/// when there is no directory either: "General.tar.gz not found" names the
/// thing a user is far more likely to be missing than a directory they never
/// had, and it is what every existing diagnostic already says.
fn openDirectory(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    depot: []const u8,
    reg_name: []const u8,
    fallback: anyerror,
) !Backend {
    const d: depot_mod.Depot = .{ .root = depot };
    const path = try d.registryDir(arena, reg_name);
    return .{ .archive = index.openDir(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return fallback,
        else => return err,
    } };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a Ref keeps its backend's native reference" {
    // The point of not flattening to `index.PackageRef`: the aix side carries a
    // row index its loadPackage needs, and losing it would cost a second
    // lookup per package on the hot path.
    const a: Ref = .{ .archive = .{ .uuid = "u", .name = "Foo", .path = "F/Foo" } };
    try testing.expectEqualStrings("Foo", a.name());
    try testing.expectEqualStrings("u", a.uuid());
    try testing.expect(a.repoIfCheap() == null);

    const x: Ref = .{ .aix = .{
        .idx = 7,
        .uuid = "u",
        .name = "Foo",
        .path = "F/Foo",
        .repo = "https://example/Foo.jl",
        .subdir = "",
    } };
    try testing.expectEqualStrings("Foo", x.name());
    try testing.expectEqual(@as(u32, 7), x.aix.idx);
    try testing.expectEqualStrings("https://example/Foo.jl", x.repoIfCheap().?);
}

test "open finds a registry that is a directory, and says which shape answered" {
    // The depot here holds `registries/Mini/` and no `Mini.tar.gz` — the shape
    // a git clone and a `JULIA_PKG_UNPACK_REGISTRY=true` install both have,
    // and the one that used to fail with FileNotFound.
    const gpa = testing.allocator;
    const io = testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try tmp.dir.createDirPath(io, "registries/Mini/D/Demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "registries/Mini/Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
        \\
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "registries/Mini/D/Demo/Versions.toml",
        .data = "[\"1.0.0\"]\ngit-tree-sha1 = \"" ++ "a" ** 40 ++ "\"\n",
    });

    var backend = try open(gpa, arena, io, depot, "Mini", .auto);
    defer backend.deinit(io);

    try testing.expectEqualStrings("directory", backend.label());
    try testing.expectEqualStrings("Mini", backend.name());
    try testing.expectEqual(@as(usize, 1), backend.packageCount());
    var pkg = (try backend.load(gpa, "Demo")).?;
    defer pkg.deinit();
    try testing.expectEqualStrings("a" ** 40, pkg.versions[0].tree_hash);

    // A name with neither shape still reports the tarball's FileNotFound,
    // which is the error every diagnostic downstream already prints.
    try testing.expectError(error.FileNotFound, open(gpa, arena, io, depot, "Absent", .auto));
}
