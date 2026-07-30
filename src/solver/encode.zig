//! Turning a Julia environment into PubGrub inputs.
//!
//! The solver is pure and knows nothing about Julia: it asks a `Registry`
//! vtable for "what versions does package X have" and "what does X@v depend
//! on". This module is the only place that answers those in Julia's terms —
//! the General registry, the stdlib set, the running Julia's own version, and
//! the project being resolved.
//!
//! ## Identity is the UUID, not the name
//!
//! Julia identifies a package by UUID; the name is a label that is NOT unique
//! (General really does carry distinct packages sharing a name, and a manifest
//! can legitimately contain both). The solver keys packages by an opaque
//! `[]const u8`, so that key is the **UUID text**, and `displayName` maps it
//! back for rendering. Keying by name would silently merge two different
//! packages into one — a wrong answer that resolves cleanly, which is the
//! worst kind.
//!
//! ## What each kind of package encodes to
//!
//! | Julia concept | Universe |
//! |---|---|
//! | registered package | its `Versions.toml` list, ascending, yanked flagged |
//! | `julia` itself | exactly ONE candidate: the version being targeted |
//! | stdlib (non-upgradable) | exactly ONE candidate: `resolvedVersion` |
//! | upgradable stdlib | resolved from the registry like any package |
//! | the project | exactly ONE candidate, injected by the caller |
//! | unregistered | an EMPTY universe, so the solver reports "no versions" |
//!
//! `julia` as a real single-version package is what makes the compat check
//! fall out of ordinary propagation rather than being a special case: every
//! registry version carries an implicit `julia` dependency
//! (`registry_instance.jl:227`), so a package whose `julia` compat excludes
//! the running version gets an EMPTY constraint set on construction and is
//! simply never selectable — and the derivation tree can then say exactly
//! that.
//!
//! ## Weak dependencies
//!
//! A `[weakdeps]` edge does not require its package — it constrains it only if
//! something else selects it. The encoder passes `weak` straight through and
//! the solver emits a different incompatibility shape for it (both terms
//! positive, complement taken over versions only so "absent" stays allowed).
//! Treating one as strong silently WIDENS the resolved set, which is a wrong
//! answer that resolves cleanly.
//!
//! ## Yanked
//!
//! Yanked versions stay IN the universe but out of the candidate set, so the
//! resolver can distinguish "no such version" from "that version exists but
//! was yanked" when it explains itself.

const std = @import("std");
const Allocator = std.mem.Allocator;

const jset = @import("julia_set.zig");
const solver = @import("solver.zig");
const sman = @import("manifest.zig");
const index = @import("../registry/index.zig");
const source_mod = @import("../registry/source.zig");
const aix = @import("../registry/aix.zig");
const jver = @import("../julia/version.zig");
const jspec = @import("../julia/versions.zig");
const stdlib_mod = @import("../julia/stdlibs.zig");

pub const Error = error{
    UnknownPackage,
    UnknownVersion,
    // The `.aix` backend's decode errors reach here through
    // `Backend.loadPackage`, which answers from whichever registry the caller
    // opened. A corrupt index is not something this module can recover from;
    // it is named so the caller can say which file was bad.
} || index.Error || aix.Error || Allocator.Error;

/// A package the caller injects rather than the registry supplying: the
/// project being resolved, a `[sources]` entry, or a dev'd path.
pub const Injected = struct {
    uuid: []const u8,
    name: []const u8,
    version: jver.Version,
    /// Already-resolved dependency constraints, as (uuid, spec) pairs.
    deps: []const Dep,

    pub const Dep = struct {
        uuid: []const u8,
        /// `null` means "any version" — Julia's absent `[compat]` entry.
        spec: ?jspec.Spec = null,
        /// An EXACT pin, which wins over `spec`. Used by PRESERVE_ALL to hold
        /// every manifest entry at the version already recorded.
        ///
        /// Deliberately a version rather than a spec string: the caller has a
        /// `VersionNumber` from a manifest, and `pinned` is the one place that
        /// knows what Pkg turns one into.
        pin: ?jver.Version = null,
        /// A constraint the PRESERVE tier imposes on top of `[compat]` —
        /// `semver_spec` of the recorded version at `PRESERVE_SEMVER`. Separate
        /// from `spec` because they have different origins and a conflict
        /// between them should be explicable as such.
        tier_spec: ?jspec.Spec = null,
    };
};

/// Canonical 8-4-4-4-12 text for a `Uuid`. `slug.Uuid` stores canonical
/// (wire) byte order but exposes no renderer, and the solver keys packages by
/// the TEXT form, so stdlib dependency lists — which are `Uuid` values — have
/// to be spelled out here.
fn uuidText(arena: Allocator, u: stdlib_mod.Uuid) Allocator.Error![]const u8 {
    const hex = "0123456789abcdef";
    const out = try arena.alloc(u8, 36);
    var oi: usize = 0;
    for (u.bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0xf];
        oi += 2;
    }
    return out;
}

/// `installed_only` (`Operations.jl:705-708`): restrict a package's candidates
/// to versions already unpacked in the depot, which is what makes
/// `PRESERVE_ALL_INSTALLED` resolve with no network.
///
/// TWO things turn this on, and they are not the same kind of thing —
/// `installed_only = installed_only || OFFLINE_MODE[]` (`:500`). The tier is a
/// preference the tiered sequence may walk past; offline is a hard constraint
/// re-applied at every tier. Both arrive here as the same filter because Pkg
/// collapses them into one boolean at exactly that line; see
/// `ops/resolve.zig`'s "Offline is not a tier".
///
/// A callback rather than a depot handle, because `src/solver/` does no I/O —
/// that is what makes it exhaustively unit-testable, and a filter that stats
/// the filesystem would end that. The caller in `ops/` owns the depot.
pub const Installed = struct {
    ctx: *const anyopaque,
    /// Is this exact (package, tree hash) unpacked anywhere in the depot?
    /// Keyed by tree hash because that is what the on-disk slug is derived
    /// from — two versions can share a name but never a hash.
    lookup: *const fn (ctx: *const anyopaque, name: []const u8, uuid: []const u8, tree_hash: []const u8) bool,
};

pub const Encoder = struct {
    /// Everything here is arena-owned: universes, candidate lists and the
    /// `PackageInfo`s are all live for exactly as long as one resolve.
    arena: Allocator,
    reg: *const source_mod.Backend,
    stdlibs: *const stdlib_mod.Set,
    /// The Julia this environment targets. Decides the single `julia`
    /// candidate and every unversioned stdlib's resolved version.
    julia_version: jver.Version,
    /// Non-null only for the `*_INSTALLED` preserve tiers.
    installed: ?Installed = null,

    universes: std.StringHashMapUnmanaged(*jset.Universe) = .empty,
    infos: std.StringHashMapUnmanaged(*index.PackageInfo) = .empty,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    injected: std.StringHashMapUnmanaged(Injected) = .empty,

    pub fn init(
        arena: Allocator,
        reg: *const source_mod.Backend,
        stdlibs: *const stdlib_mod.Set,
        julia_version: jver.Version,
    ) Encoder {
        return .{ .arena = arena, .reg = reg, .stdlibs = stdlibs, .julia_version = julia_version };
    }

    /// Register a package the registry does not supply. Must be called before
    /// the first `universeFor` on that uuid.
    pub fn inject(self: *Encoder, p: Injected) Allocator.Error!void {
        try self.injected.put(self.arena, p.uuid, p);
        try self.names.put(self.arena, p.uuid, p.name);
    }

    /// What was injected for this uuid, if anything.
    ///
    /// `composeManifest` needs it for a `develop`ed or repo-tracked entry: such
    /// a package's dependency list exists only in its own `Project.toml`, which
    /// `injectUntracked` already read, and Pkg writes back exactly that list
    /// (`final_deps_map`'s `fixed` branch reads `fixed[uuid].requires`,
    /// `Operations.jl:602-610`) rather than anything from the registry.
    pub fn injectedFor(self: *const Encoder, uuid: []const u8) ?Injected {
        return self.injected.get(uuid);
    }

    /// The human-readable name for a solver package key.
    pub fn displayName(self: *const Encoder, uuid: []const u8) []const u8 {
        return self.names.get(uuid) orelse uuid;
    }

    /// `displayName` as the reporter's `Names` hook, so a failed solve renders
    /// package names rather than the UUIDs it keys on.
    pub fn nameResolver(self: *const Encoder) solver.Names {
        return .{ .ctx = @ptrCast(self), .lookup = lookupName };
    }

    fn lookupName(ctx: *const anyopaque, key: []const u8) []const u8 {
        const self: *const Encoder = @ptrCast(@alignCast(ctx));
        return self.displayName(key);
    }

    fn makeUniverse(
        self: *Encoder,
        uuid: []const u8,
        name: []const u8,
        vs: []const jver.Version,
        yanked: []const bool,
    ) Allocator.Error!*jset.Universe {
        const u = try self.arena.create(jset.Universe);
        u.* = jset.Universe.init(name, vs, yanked);
        try self.universes.put(self.arena, uuid, u);
        try self.names.put(self.arena, uuid, name);
        return u;
    }

    fn single(self: *Encoder, uuid: []const u8, name: []const u8, v: jver.Version) Allocator.Error!*jset.Universe {
        const vs = try self.arena.alloc(jver.Version, 1);
        vs[0] = v;
        return self.makeUniverse(uuid, name, vs, &.{});
    }

    /// The candidate list for a package, built on first use.
    pub fn universeFor(self: *Encoder, uuid: []const u8) Error!*const jset.Universe {
        if (self.universes.get(uuid)) |u| return u;

        // 1. The project / injected packages win over everything: a `[sources]`
        //    or dev'd entry deliberately shadows the registry.
        if (self.injected.get(uuid)) |p| return self.single(uuid, p.name, p.version);

        // 2. `julia` is a real package with exactly one candidate, which is
        //    what turns every `julia` compat bound into ordinary propagation.
        if (std.mem.eql(u8, uuid, index.julia_uuid)) {
            return self.single(uuid, "julia", self.julia_version);
        }

        // 3. Stdlibs are fixed at the version shipped with this Julia — except
        //    the upgradable ones (`UPGRADABLE_STDLIBS`), which resolve from the
        //    registry like any other package and so fall through.
        if (self.stdlibs.byUuidText(uuid)) |sl| {
            if (!sl.upgradable) {
                return self.single(uuid, sl.name, sl.resolvedVersion(self.julia_version));
            }
        }

        // 4. The registry.
        if (self.reg.findByUuid(uuid)) |ref| {
            const info = try self.arena.create(index.PackageInfo);
            info.* = try self.reg.loadPackage(self.arena, ref);
            try self.infos.put(self.arena, uuid, info);

            const vs = try self.arena.alloc(jver.Version, info.versions.len);
            const yanked = try self.arena.alloc(bool, info.versions.len);
            var any_yanked = false;
            var n: usize = 0;
            for (info.versions) |vi| {
                // The filter runs BEFORE the universe is built, not as a
                // constraint over it: `installed_only` removes candidates from
                // the graph entirely (`Operations.jl:705-708`), so a version
                // that is not unpacked must not even be nameable — otherwise
                // an error could suggest it.
                if (self.installed) |f| {
                    if (!f.lookup(f.ctx, ref.name(), uuid, vi.tree_hash)) continue;
                }
                vs[n] = vi.version;
                yanked[n] = vi.yanked;
                any_yanked = any_yanked or vi.yanked;
                n += 1;
            }
            return self.makeUniverse(uuid, ref.name(), vs[0..n], if (any_yanked) yanked[0..n] else &.{});
        }

        // 5. Not registered anywhere. An EMPTY universe rather than an error:
        //    the solver's own `no_versions` incompatibility explains this far
        //    better than a hard failure here could, and it can name the
        //    package that asked for it.
        return self.makeUniverse(uuid, uuid, &.{}, &.{});
    }

    /// The registry entry behind a uuid — versions, tree hashes and the
    /// uncompressed dependency lists — or null when this package does not come
    /// from the registry at all (injected, `julia`, a fixed stdlib, or simply
    /// not registered). Builds it on first use, exactly as `universeFor` does,
    /// so a caller that only wants tree hashes pays for nothing else.
    pub fn infoFor(self: *Encoder, uuid: []const u8) Error!?*const index.PackageInfo {
        _ = try self.universeFor(uuid);
        return self.infos.get(uuid);
    }

    /// The constraint set a spec denotes over a package's candidates.
    /// `null` spec means unconstrained — every version, but NOT absent, since
    /// a dependency still requires the package to be present.
    pub fn constraint(self: *Encoder, dep_uuid: []const u8, spec: ?jspec.Spec) Error!jset.VersionSet {
        const u = try self.universeFor(dep_uuid);
        if (spec) |sp| return jset.VersionSet.fromSpec(self.arena, u, sp);
        return jset.VersionSet.allVersions(self.arena, u);
    }

    /// The constraint a manifest-recorded version imposes — `VersionSpec(v)`,
    /// which is NOT the singleton `{v}`.
    ///
    /// `VersionBound(v::VersionNumber)` keeps `(major, minor, patch)` and
    /// nothing else (`Versions.jl:27-39`), so the requirement Pkg builds from a
    /// recorded version admits every version sharing that triple. Confirmed by
    /// running it rather than by reading it:
    ///
    /// ```julia
    /// v"1.2.3+1" in VersionSpec(v"1.2.3+0")   # true
    /// v"1.2.3"   in VersionSpec(v"1.2.3-rc1") # true
    /// ```
    ///
    /// Encoding it as an exact index match is stricter than Pkg, and the
    /// difference is not academic: JLLs really do get republished with a new
    /// build number, and a manifest pinning `1.2.3+0` after the registry moved
    /// to `1.2.3+1` resolves in Pkg and would be UNSOLVABLE here. That is also
    /// the reason `Operations.jl:564-580` exists — Pkg lets the resolver pick
    /// the newer build and then puts the recorded one back.
    pub fn pinned(self: *Encoder, dep_uuid: []const u8, v: jver.Version) Error!jset.VersionSet {
        const u = try self.universeFor(dep_uuid);
        // The registry grammar's `a` is `VersionRange(Bound(a), Bound(a))`,
        // which is exactly what `VersionSpec(::VersionNumber)` constructs.
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch
            return jset.VersionSet.empty(self.arena, u);
        const spec = try jspec.Spec.parse(self.arena, text);
        return jset.VersionSet.fromSpec(self.arena, u, spec);
    }

    // -- the vtable ---------------------------------------------------------

    pub fn registry(self: *Encoder) solver.Registry {
        return .{ .ctx = @ptrCast(self), .vtable = &.{
            .list_versions = listVersions,
            .get_manifest = getManifest,
        } };
    }

    fn listVersions(
        ctx: *anyopaque,
        uuid: []const u8,
        out: *std.ArrayList(solver.Version),
        gpa: Allocator,
    ) anyerror!void {
        const self: *Encoder = @ptrCast(@alignCast(ctx));
        const u = try self.universeFor(uuid);
        for (0..u.count()) |i| {
            // Yanked versions are not candidates. They stay in the universe so
            // an error can say "1.2.3 exists but is yanked" instead of the
            // much less useful "no such version".
            if (u.isYanked(@intCast(i))) continue;
            try out.append(gpa, u.at(@intCast(i)));
        }
    }

    fn getManifest(
        ctx: *anyopaque,
        uuid: []const u8,
        version: solver.Version,
        gpa: Allocator,
    ) anyerror!sman.Manifest {
        const self: *Encoder = @ptrCast(@alignCast(ctx));
        _ = gpa; // everything hangs off the resolve arena

        if (self.injected.get(uuid)) |p| {
            const deps = try self.arena.alloc(sman.Dependency, p.deps.len);
            for (p.deps, 0..) |d, i| {
                // A pin and a `[compat]` entry are two SEPARATE requirements in
                // Pkg and both apply: the preserved version enters through
                // `reqs` (`Operations.jl:559`) and the project's compat through
                // the fixed project's own `requires` (`:359-362`). Pkg
                // intersects them explicitly and errors on an empty result —
                // "empty intersection between $pkg@$version and project
                // compatibility" (`:538-546`). Taking only the pin would let a
                // manifest that predates a tightened `[compat]` resolve here
                // and fail there.
                var range = try self.constraint(d.uuid, d.spec);
                if (d.tier_spec) |ts| {
                    range = try range.intersect(try self.constraint(d.uuid, ts), self.arena);
                }
                if (d.pin) |pv| {
                    range = try range.intersect(try self.pinned(d.uuid, pv), self.arena);
                }
                deps[i] = .{ .name = d.uuid, .range = range };
            }
            return .{ .name = uuid, .version = version, .depends = deps };
        }

        // `julia` and the fixed stdlibs. Stdlib deps are UUID lists with no
        // constraint — they are pinned by the Julia install, not resolved.
        if (std.mem.eql(u8, uuid, index.julia_uuid)) {
            return .{ .name = uuid, .version = version, .depends = &.{} };
        }
        if (self.stdlibs.byUuidText(uuid)) |sl| {
            if (!sl.upgradable) {
                const deps = try self.arena.alloc(sman.Dependency, sl.deps.len);
                for (sl.deps, 0..) |d, i| {
                    const text = try uuidText(self.arena, d);
                    deps[i] = .{ .name = text, .range = try self.constraint(text, null) };
                }
                return .{ .name = uuid, .version = version, .depends = deps };
            }
        }

        const info = self.infos.get(uuid) orelse blk: {
            _ = try self.universeFor(uuid);
            break :blk self.infos.get(uuid) orelse return Error.UnknownPackage;
        };
        const vi = info.indexOfVersion(version.number()) orelse return Error.UnknownVersion;
        const raw = info.deps[vi];
        const deps = try self.arena.alloc(sman.Dependency, raw.len);
        for (raw, 0..) |d, i| deps[i] = .{
            .name = d.uuid,
            .range = try self.constraint(d.uuid, d.compat),
            .weak = d.weak,
        };
        return .{
            .name = uuid,
            .version = version,
            .depends = deps,
            // Deliberately false. Baker used `no_versioning` for packages that
            // cannot be installed side by side, emitting pairwise-exclusion
            // incompatibilities and promoting failures to `SingletonConflict`.
            // In Julia NO package can coexist with itself — but PubGrub already
            // guarantees that structurally, since `decisions` holds one entry
            // per package key. Setting it true would add O(v²) redundant
            // incompatibilities and make EVERY conflict report as a singleton
            // conflict, which classifies nothing.
            .no_versioning = false,
        };
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "uuidText round-trips through Uuid.parse" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    // A hand-rolled hex formatter is exactly the sort of thing that is wrong
    // in the dash positions and right everywhere else, so check real uuids
    // including one with leading zeros in several groups.
    for ([_][]const u8{
        index.julia_uuid,
        "3da002f7-5984-5a60-b8a6-cbb66c0b333f",
        "00000000-0000-0000-0000-000000000000",
        "0f1e2d3c-0b0a-0908-0706-050403020100",
    }) |text| {
        const parsed = try stdlib_mod.Uuid.parse(text);
        try testing.expectEqualStrings(text, try uuidText(g, parsed));
    }
}

test "julia is a single-candidate package, so compat bounds propagate" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var reg: source_mod.Backend = .{ .archive = .{ .files = undefined } };
    var set: stdlib_mod.Set = .{ .dir = "v1.12" };
    var enc = Encoder.init(g, &reg, &set, try jver.parse(g, "1.12.6"));

    const u = try enc.universeFor(index.julia_uuid);
    try testing.expectEqual(@as(usize, 1), u.count());
    try testing.expectEqualStrings("julia", enc.displayName(index.julia_uuid));

    // A package requiring julia 1.6-1.10 gets an EMPTY constraint on 1.12.6,
    // so it can never be selected — no special case anywhere in the solver.
    const excl = try enc.constraint(index.julia_uuid, try jspec.Spec.parse(g, "1.6 - 1.10"));
    try testing.expect(excl.isEmpty());

    const ok = try enc.constraint(index.julia_uuid, try jspec.Spec.parse(g, "1.6 - 1.12"));
    try testing.expectEqual(@as(usize, 1), ok.count());
}

test "an unregistered uuid gets an empty universe, not an error" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var reg: source_mod.Backend = .{ .archive = .{ .files = undefined } };
    var set: stdlib_mod.Set = .{ .dir = "v1.12" };
    var enc = Encoder.init(g, &reg, &set, try jver.parse(g, "1.12.6"));

    const u = try enc.universeFor("00000000-0000-0000-0000-000000000000");
    try testing.expectEqual(@as(usize, 0), u.count());
    // Still constrainable, and the constraint is empty — which is what makes
    // the solver emit `no_versions` naming the package that asked for it.
    const c = try enc.constraint("00000000-0000-0000-0000-000000000000", null);
    try testing.expect(c.isEmpty());
}

test "an injected package shadows the registry and pins one version" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var reg: source_mod.Backend = .{ .archive = .{ .files = undefined } };
    var set: stdlib_mod.Set = .{ .dir = "v1.12" };
    var enc = Encoder.init(g, &reg, &set, try jver.parse(g, "1.12.6"));

    const uuid = "11111111-2222-3333-4444-555555555555";
    try enc.inject(.{
        .uuid = uuid,
        .name = "MyProject",
        .version = try jver.parse(g, "0.1.0"),
        .deps = &.{.{ .uuid = index.julia_uuid, .spec = null }},
    });

    const u = try enc.universeFor(uuid);
    try testing.expectEqual(@as(usize, 1), u.count());
    try testing.expectEqualStrings("MyProject", enc.displayName(uuid));

    var r = enc.registry();
    const mf = try r.getManifest(uuid, u.at(0), g);
    try testing.expectEqual(@as(usize, 1), mf.depends.len);
    try testing.expectEqualStrings(index.julia_uuid, mf.depends[0].name);
    // A null spec means "present at any version", NOT "no constraint": the
    // absent bit must stay clear or the dependency would be droppable.
    try testing.expect(!mf.depends[0].range.hasAbsent());
    try testing.expectEqual(@as(usize, 1), mf.depends[0].range.count());
}

test "a manifest pin admits exactly what VersionSpec(v) does" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    // Generated by running Julia, not by reading Versions.jl:
    //
    //   using Pkg; V = Pkg.Versions
    //   v"1.2.3+1" in V.VersionSpec(v"1.2.3+0")   # true
    //   v"1.2.3"   in V.VersionSpec(v"1.2.3-rc1") # true
    //   v"2.0.1"   in V.VersionSpec(v"2.0.0")     # false
    //
    // The point of each case: a pin is NOT the singleton it looks like. It is
    // the whole (major, minor, patch) triple, so builds and prereleases of the
    // same triple all satisfy it.
    const cases = [_]struct {
        recorded: []const u8,
        candidates: []const []const u8,
        in_spec: []const bool,
    }{
        .{
            .recorded = "1.2.3+0",
            .candidates = &.{ "1.2.3", "1.2.3+0", "1.2.3+1", "1.2.4" },
            .in_spec = &.{ true, true, true, false },
        },
        .{
            // Ascending in JULIA's order, which a universe requires:
            // `sort([v"1.2.3-rc1", v"1.2.3-rc2", v"1.2.3", v"1.2.2"])`
            // is `1.2.2 < 1.2.3-rc1 < 1.2.3-rc2 < 1.2.3`.
            .recorded = "1.2.3-rc1",
            .candidates = &.{ "1.2.2", "1.2.3-rc1", "1.2.3-rc2", "1.2.3" },
            .in_spec = &.{ false, true, true, true },
        },
        .{
            .recorded = "2.0.0",
            .candidates = &.{ "2.0.0-beta", "2.0.0", "2.0.0+3", "2.0.1" },
            .in_spec = &.{ true, true, true, false },
        },
    };

    for (cases, 0..) |c, ci| {
        var reg: source_mod.Backend = .{ .archive = .{ .files = undefined } };
        var set: stdlib_mod.Set = .{ .dir = "v1.12" };
        var enc = Encoder.init(g, &reg, &set, try jver.parse(g, "1.12.6"));

        const uuid = try std.fmt.allocPrint(g, "aaaaaaaa-0000-0000-0000-{d:0>12}", .{ci});
        const vs = try g.alloc(jver.Version, c.candidates.len);
        for (c.candidates, vs) |text, *v| v.* = try jver.parse(g, text);
        _ = try enc.makeUniverse(uuid, "Pinned", vs, &.{});

        const got = try enc.pinned(uuid, try jver.parse(g, c.recorded));
        for (c.in_spec, 0..) |want, i| {
            try testing.expectEqual(want, got.has(@intCast(i)));
        }
        // And never "absent": a pinned dependency is still required to exist.
        try testing.expect(!got.hasAbsent());
    }
}

test "listVersions skips yanked but the universe keeps them" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var reg: source_mod.Backend = .{ .archive = .{ .files = undefined } };
    var set: stdlib_mod.Set = .{ .dir = "v1.12" };
    var enc = Encoder.init(g, &reg, &set, try jver.parse(g, "1.12.6"));

    const uuid = "aaaaaaaa-0000-0000-0000-000000000000";
    const vs = try g.alloc(jver.Version, 3);
    for ([_][]const u8{ "1.0.0", "1.1.0", "1.2.0" }, 0..) |t, i| vs[i] = try jver.parse(g, t);
    _ = try enc.makeUniverse(uuid, "Yanky", vs, try g.dupe(bool, &.{ false, true, false }));

    var out = std.ArrayList(solver.Version).empty;
    var r = enc.registry();
    try r.listVersions(uuid, &out, g);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // The yanked one is still addressable for diagnostics.
    const u = try enc.universeFor(uuid);
    try testing.expectEqual(@as(usize, 3), u.count());
    try testing.expect(u.at(1).isYanked());
}
