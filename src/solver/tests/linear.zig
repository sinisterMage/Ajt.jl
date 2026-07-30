//! Linear dependency resolver smoke test, plus the shared in-memory test
//! registry the other six vendored solver tests import.
//!
//! ## Ported to the Julia version model
//!
//! Baker's tests were written against its SemVer `VersionSet`. The solver now
//! runs on `julia_set.zig` — bitsets over each package's candidate list — so
//! this harness builds a `Universe` per package name and hands out
//! `{universe, index}` versions.
//!
//! The test SCENARIOS and assertions are unchanged. One dependency STRING had
//! to be translated, and it is worth stating exactly why, because it is a
//! silent trap:
//!
//!   `">=1.0.0, <2.0.0"` means `[1.0.0, 2.0.0)` in semver — comma is
//!   conjunction. In Julia's `semver_spec` comma is a **union**
//!   (`Versions.jl:303-325`), so that same string parses to
//!   `>=1.0.0 ∪ <2.0.0` = `*`, which admits every version including 0.5.0.
//!   Verified against Julia, not assumed. `negative_term.zig` therefore now
//!   spells that constraint `"^1.0.0"`, which is the interval the test's own
//!   comment says it means.
//!
//! Every other string the vendored tests use (`^X.Y.Z`, `>=X.Y.Z`, `=X.Y.Z`)
//! was checked against `Pkg.Versions.semver_spec` over the full candidate set
//! these tests use and selects exactly the same versions in both grammars.
const std = @import("std");
const solver = @import("../solver.zig");
const jset = @import("../julia_set.zig");
const jver = @import("../../julia/version.zig");
const jspec = @import("../../julia/versions.zig");

test "linear dependency resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fr = try TestRegistry.init(a, &[_]TestPkg{
        .{ .name = "root", .version = "1.0.0", .deps = &.{.{ "foo", "^1.0.0" }} },
        .{ .name = "foo", .version = "1.0.0", .deps = &.{.{ "bar", "^1.0.0" }} },
        .{ .name = "bar", .version = "1.0.0", .deps = &.{} },
    });
    defer fr.deinit();

    var reg = fr.registry();
    const graph = try solver.solve(.{
        .name = "root",
        .version = try fr.versionOf("root", "1.0.0"),
    }, &reg, a);

    // 3 nodes in the closure.
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
}

// ---- in-memory test registry ----

pub const TestPkgDep = struct { []const u8, []const u8 };
pub const TestPkg = struct {
    name: []const u8,
    version: []const u8,
    deps: []const TestPkgDep = &.{},
    no_versioning: bool = false,
};

pub const TestRegistry = struct {
    allocator: std.mem.Allocator,
    pkgs: []TestPkg,
    /// One universe per package name, each owning a sorted candidate list.
    /// Boxed because every `Version` and `VersionSet` holds a stable pointer
    /// to its universe — a value stored inline in a resizing map would move.
    universes: std.StringHashMapUnmanaged(*jset.Universe),

    pub fn init(allocator: std.mem.Allocator, pkgs: []const TestPkg) !TestRegistry {
        const owned = try allocator.dupe(TestPkg, pkgs);
        var self: TestRegistry = .{
            .allocator = allocator,
            .pkgs = owned,
            .universes = .empty,
        };

        // Group by name, then sort each group ascending: `Universe.init`
        // requires it, and the declaration order above is deliberately not
        // sorted (negative_term.zig lists foo 2.0.0 before 1.0.0).
        for (owned) |p| {
            if (self.universes.contains(p.name)) continue;
            var vs = std.ArrayList(jver.Version).empty;
            for (owned) |q| {
                if (!std.mem.eql(u8, q.name, p.name)) continue;
                try vs.append(allocator, try jver.parse(allocator, q.version));
            }
            const slice = try vs.toOwnedSlice(allocator);
            std.mem.sort(jver.Version, slice, {}, struct {
                fn lt(_: void, x: jver.Version, y: jver.Version) bool {
                    return jver.Version.order(x, y) == .lt;
                }
            }.lt);
            const u = try allocator.create(jset.Universe);
            u.* = jset.Universe.init(p.name, slice, &.{});
            try self.universes.put(allocator, p.name, u);
        }
        return self;
    }

    pub fn deinit(self: *TestRegistry) void {
        self.allocator.free(self.pkgs);
        self.universes.deinit(self.allocator);
    }

    /// The universe for `name`, creating an empty one for a package that is
    /// depended on but not registered — the solver must then report "no
    /// versions" rather than crash.
    fn universeFor(self: *TestRegistry, name: []const u8) !*jset.Universe {
        if (self.universes.get(name)) |u| return u;
        const u = try self.allocator.create(jset.Universe);
        u.* = jset.Universe.init(name, &.{}, &.{});
        try self.universes.put(self.allocator, name, u);
        return u;
    }

    /// Resolve a version string to the `{universe, index}` pair the solver
    /// speaks. Tests use this instead of the old `Version.parse`.
    pub fn versionOf(self: *TestRegistry, name: []const u8, version: []const u8) !solver.Version {
        const u = try self.universeFor(name);
        const v = try jver.parse(self.allocator, version);
        return u.at(u.indexOf(v) orelse return error.NotFound);
    }

    pub fn registry(self: *TestRegistry) solver.Registry {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &.{
                .list_versions = listVersions,
                .get_manifest = getManifest,
            },
        };
    }

    fn listVersions(
        ctx: *anyopaque,
        name: []const u8,
        out: *std.ArrayList(solver.Version),
        allocator: std.mem.Allocator,
    ) anyerror!void {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        const u = try self.universeFor(name);
        for (0..u.count()) |i| try out.append(allocator, u.at(@intCast(i)));
    }

    fn getManifest(
        ctx: *anyopaque,
        name: []const u8,
        version: solver.Version,
        allocator: std.mem.Allocator,
    ) anyerror!solver.manifest.Manifest {
        const self: *TestRegistry = @ptrCast(@alignCast(ctx));
        for (self.pkgs) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            const pv = try self.versionOf(p.name, p.version);
            if (!solver.Version.eql(pv, version)) continue;
            const deps = try allocator.alloc(solver.manifest.Dependency, p.deps.len);
            for (p.deps, 0..) |d, i| {
                const du = try self.universeFor(d[0]);
                // Project.toml grammar (`semver_spec`), which is what these
                // `^`/`>=`/`=` strings are written in — NOT the registry's
                // `VersionSpec` grammar. The two are mutually incompatible.
                const spec = try jspec.semverSpec(allocator, d[1]);
                deps[i] = .{
                    .name = try allocator.dupe(u8, d[0]),
                    .range = try jset.VersionSet.fromSpec(allocator, du, spec),
                };
            }
            return .{
                .name = try allocator.dupe(u8, p.name),
                .version = pv,
                .depends = deps,
                .no_versioning = p.no_versioning,
            };
        }
        return error.NotFound;
    }
};
