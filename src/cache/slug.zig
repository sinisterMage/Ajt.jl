//! Where a precompile cache entry has to LAND on this machine.
//!
//! Julia names a `.ji` file
//!
//! ```text
//! <depot1>/compiled/v<major>.<minor>/<Name>/<package_slug(uuid)>_<precompile_slug>.ji
//! ```
//!
//! and `precompile_slug` is a crc32c chain (`base/loading.jl:3152-3172`) over,
//! in this exact order:
//!
//!  1. the **active project path string** (`something(Base.active_project(), "")`),
//!  2. `unsafe_string(JLOptions().image_file)` -- the sysimage,
//!  3. `unsafe_string(JLOptions().julia_bin)` -- the julia binary,
//!  4. one byte of cache flags (`_cacheflag_to_uint8`, `loading.jl:1725-1733`),
//!  5. `ENV["JULIA_CPU_TARGET"]` if set, else `JLOptions().cpu_target`,
//!  6. `prefs_hash` as a `UInt64` (`julia/preferences.zig` computes it),
//!
//! rendered base-62 at width 5 by the same `slug` as the package directory
//! name (`julia/slug.zig`). The directory component before it is
//! `cache_file_entry` (`loading.jl:1203-1210`).
//!
//! ## This slug is NOT a sharing key -- and that is the point
//!
//! `julia_bin` and the project path are absolute paths that differ between any
//! two machines: CI has `/opt/hostedtoolcache/julia/.../bin` and
//! `${{ github.workspace }}/Open-Reality`, the engine image has
//! `/usr/local/julia/bin` and `/engine`, this dev box has a `/nix/store/...`
//! prefix that changes on every Julia rebuild. Level-1 slugs therefore **never
//! match across machines**, and a shared cache keyed on them would never hit.
//!
//! What makes a shared cache work anyway is that **nothing derived from either
//! path lives inside the `.ji`**. `_parse_cache_header`
//! (`loading.jl:3430-3497`) reads: the flags byte, the module list, include
//! records, `requires` edges, the preference names, `prefs_hash`, the source
//! text offset, the required-module list and the clone targets. No project
//! path, no `julia_bin`, no `image_file`. So a cache object fetched from
//! anywhere can be written at the slug computed from the **local**
//! `JLOptions()` and it just works -- which is strictly better than forcing
//! every machine onto a uniform install prefix, because the install prefix is
//! exactly the thing a package manager does not control.
//!
//! Hence this module's shape: it takes the local inputs and produces a path.
//! Content addressing of the *object* is a different key, computed elsewhere.
//!
//! (`depot.zig`'s `compiledDir` used to say "**Ajt never writes here**". The
//! shared cache is what changed that, deliberately: writing a `.ji` Julia
//! produced is not the same thing as forging a cache header, which remains out
//! of scope. That comment now says so.)
//!
//! ## `JULIA_CPU_TARGET` changes this path, but it does NOT cause a miss
//!
//! It is crc32c'd in at step 5, read straight from the environment
//! (`loading.jl:3163-3167`), so build time and run time disagreeing on it puts
//! entries under a different filename. It is tempting -- and this comment
//! previously did it -- to conclude the runtime then recompiles everything.
//! Measured on 1.12.6, it does not: compile 26 entries under
//! `generic;haswell,clone_all`, load under `generic`, and NOTHING recompiles,
//! because `find_all_in_cache_path` (`loading.jl:1212-1227`) globs every
//! `<name>_*.ji` and validates each by content. This is a WRITE address, not a
//! lookup filter.
//!
//! What actually rejects a depot built for the wrong machine is
//! `check_clone_targets` (`loading.jl:3856-3858`). RealityForge still pins the
//! variable as an image ENV (`backend/Dockerfile`) so the baked precompile step
//! and the running container agree -- a drifting value scatters entries across
//! slugs even though each remains findable.
//!
//! ## The endianness trap, again
//!
//! `_crc32c(x::UInt64, crc)` is
//! `ccall(:jl_crc32c, ..., Ref{UInt64}, 8)` (`base/util.jl:535-536`), i.e. the
//! **native little-endian bytes of the integer** -- the same trap that
//! `julia/slug.zig` documents for `_crc32c(::UUID)`. Feeding `prefs_hash`
//! big-endian produces a perfectly plausible wrong slug (`Pwohw` instead of
//! `ikcUB` for the fixture below) and nothing fails; the cache just never hits.
//! The landmark tests below pin both.
//!
//! The other five inputs are strings, hashed as their raw UTF-8 bytes
//! (`_crc32c(::String)`, `util.jl:515-517`), and the flags byte is a single
//! byte (`util.jl:541-542`), so none of them has an ordering question.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fspath = std.fs.path;

// The base-62 rendering and the package slug both live here; never inline a
// second copy of either -- `julia/slug.zig` is where the byte-order trap is
// documented and differentially tested.
const pkg_slug = @import("../julia/slug.zig");
const depot_mod = @import("../depot.zig");

pub const Uuid = pkg_slug.Uuid;
pub const Depot = depot_mod.Depot;

/// `slug(crc, 5)` -- `package_slug` and the precompile slug are both width 5
/// (`loading.jl:197`, `loading.jl:3171`).
pub const slug_len = 5;

// ---------------------------------------------------------------------------
// Cache flags
// ---------------------------------------------------------------------------

/// `Base.CacheFlags` (`loading.jl:1690-1706`), the bit layout `OOICCDDP`.
///
/// Only the packed byte participates in the slug, but the fields are modelled
/// individually because that is how a caller thinks about them (`-O2`,
/// `--check-bounds=no`) and because the packing is asymmetric: `CacheFlags(f)`
/// masks each field on the way in (`:1699-1703`) while `_cacheflag_to_uint8`
/// shifts without masking on the way out (`:1725-1733`). A `debug_level` of 4
/// would therefore corrupt the neighbouring field in Julia; the `u2` fields
/// here make that unrepresentable.
pub const Flags = struct {
    /// `--pkgimages=yes|no`. When true the `.ji` has a native-code sibling --
    /// see `objectPath`.
    use_pkgimages: bool = true,
    /// `-g<n>`. Julia's default is 1, or 2 on a debug build (`loading.jl:1723`).
    debug_level: u2 = 1,
    /// `--check-bounds=auto|yes|no` as 0|1|2 (`loading.jl:1739`).
    check_bounds: u2 = 0,
    /// `--inline=yes|no`. Named `inline` in Julia, which is a Zig keyword.
    inlining: bool = true,
    /// `-O<n>`.
    opt_level: u2 = 2,

    /// `Base.DefaultCacheFlags` (`loading.jl:1723`) for a release build --
    /// packed byte `0xa3`, confirmed against `_cacheflag_to_uint8` on a real
    /// Julia 1.12.6.
    pub const default: Flags = .{};

    /// `_cacheflag_to_uint8(cf)` (`loading.jl:1725-1733`).
    pub fn toByte(self: Flags) u8 {
        var f: u8 = 0;
        f |= @as(u8, @intFromBool(self.use_pkgimages)) << 0;
        f |= @as(u8, self.debug_level) << 1;
        f |= @as(u8, self.check_bounds) << 3;
        f |= @as(u8, @intFromBool(self.inlining)) << 5;
        f |= @as(u8, self.opt_level) << 6;
        return f;
    }

    /// `CacheFlags(f::UInt8)` (`loading.jl:1698-1705`). This is also the byte
    /// stored at the head of a `.ji` (`_parse_cache_header`,
    /// `loading.jl:3431`), so it is how a fetched cache object reports the
    /// flags it was built with.
    pub fn fromByte(b: u8) Flags {
        return .{
            .use_pkgimages = (b & 1) != 0,
            .debug_level = @truncate(b >> 1),
            .check_bounds = @truncate(b >> 3),
            .inlining = ((b >> 5) & 1) != 0,
            .opt_level = @truncate(b >> 6),
        };
    }
};

// ---------------------------------------------------------------------------
// The chain
// ---------------------------------------------------------------------------

/// Everything `compilecache_path` hashes. All of it is local machine state;
/// none of it is a property of the package being cached.
pub const Inputs = struct {
    /// `something(Base.active_project(), "")` (`loading.jl:3152`) -- the path
    /// **string**, hashed as-is. Julia does not normalise or `abspath` it here,
    /// so a caller that passes `./Project.toml` where Julia would have had
    /// `/abs/Project.toml` gets a different, wrong slug. Pass exactly what
    /// `Base.active_project()` would return. The empty string models
    /// "no active project", which is a reachable state (`julia --project=@`
    /// with nothing to find).
    project: []const u8,
    /// `unsafe_string(JLOptions().image_file)` -- the sysimage in use.
    image_file: []const u8,
    /// `unsafe_string(JLOptions().julia_bin)` -- the julia binary that is
    /// running. Together with `project` this is what makes the slug
    /// machine-local; see the module doc.
    julia_bin: []const u8,
    /// The cache flags of the process that will LOAD the entry.
    flags: Flags = .default,
    /// `ENV["JULIA_CPU_TARGET"]` if set, else `JLOptions().cpu_target`. Use
    /// `cpuTarget` rather than reproducing the fallback.
    cpu_target: []const u8,
    /// `Base.get_preferences_hash(uuid, prefs_list)`; see
    /// `julia/preferences.zig`. Zero for the overwhelmingly common
    /// "this package has no preferences" case, and also for `uuid === nothing`.
    prefs_hash: u64 = 0,
};

/// `loading.jl:3164-3167`: the environment wins if the variable is **set**,
/// including when it is set to the empty string -- `get(ENV, k, nothing)`
/// returns `""` for that, not `nothing`. Hence `?[]const u8` rather than a
/// non-empty check; conflating the two silently changes the slug on any host
/// that exports an empty `JULIA_CPU_TARGET`.
pub fn cpuTarget(env_julia_cpu_target: ?[]const u8, jl_options_cpu_target: []const u8) []const u8 {
    return env_julia_cpu_target orelse jl_options_cpu_target;
}

/// The crc32c chain of `loading.jl:3159-3170`.
///
/// Chaining `_crc32c` calls is the same as hashing the concatenation, so one
/// hasher over all six pieces reproduces it exactly (the same argument
/// `julia/slug.zig:versionSlug` makes).
pub fn crc(in: Inputs) u32 {
    var h = std.hash.crc.Crc32Iscsi.init();
    h.update(in.project);
    h.update(in.image_file);
    h.update(in.julia_bin);
    h.update(&[_]u8{in.flags.toByte()});
    h.update(in.cpu_target);
    h.update(&prefsHashBytes(in.prefs_hash));
    return h.final();
}

/// `_crc32c(x::UInt64, crc)` passes `Ref{UInt64}` with a length of 8
/// (`base/util.jl:535-536`), so the C function sees the integer's NATIVE
/// bytes. On every host Julia supports in practice that is little-endian; the
/// big-endian branch is written out rather than assumed, exactly as
/// `Uuid.hashOrder` does.
fn prefsHashBytes(prefs_hash: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, prefs_hash, comptime builtin.cpu.arch.endian());
    return out;
}

/// `project_precompile_slug` (`loading.jl:3171`). Writes into `buf` and
/// returns a slice of it, so this allocates nothing.
pub fn precompileSlug(in: Inputs, buf: *[slug_len]u8) []const u8 {
    return pkg_slug.slug(crc(in), slug_len, buf);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// A `Base.PkgId`: a name, plus a UUID for everything that is not a bare
/// script. `uuid == null` takes a different, un-slugged branch through
/// `cache_file_entry` and `compilecache_path`.
pub const PkgId = struct {
    name: []const u8,
    uuid: ?Uuid = null,
};

/// `compilecache_dir(pkg)` (`loading.jl:3147-3150`): where the entry's files
/// live, `<depot1>/compiled/v<major>.<minor>/<Name>`.
///
/// For a UUID-less `PkgId` the name component is empty
/// (`cache_file_entry`, `loading.jl:1208`) and the directory is just
/// `<depot1>/compiled/v<major>.<minor>`; Julia's `joinpath(..., "")` leaves a
/// trailing separator there, which this drops because no consumer of a
/// directory path can tell the difference.
///
/// Arena-allocated: the returned slice has the arena's lifetime.
pub fn cacheDir(
    arena: Allocator,
    dep: Depot,
    major: u32,
    minor: u32,
    pkg: PkgId,
) Allocator.Error![]u8 {
    const base = try dep.compiledDir(arena, major, minor);
    if (pkg.uuid == null) return base;
    return fspath.join(arena, &.{ base, pkg.name });
}

/// `Base.compilecache_path(pkg, prefs_hash; flags, project)`
/// (`loading.jl:3152-3173`) -- the absolute path of the `.ji`.
///
/// Two branches, and the UUID-less one ignores `in` entirely: a `PkgId`
/// without a UUID caches to `<depot1>/compiled/v<major>.<minor>/<Name>.ji`
/// with no slug at all (`loading.jl:3156-3157`), so nothing about the local
/// machine distinguishes two such entries.
///
/// WHICH depot is the caller's decision, and it is not the same one for
/// reading and writing. Julia writes to `DEPOT_PATH[1]` (`loading.jl:3154`)
/// but `find_all_in_cache_path` (`loading.jl:1212-1227`) *searches every*
/// entry, which is exactly what RealityForge's engine image relies on
/// (`JULIA_DEPOT_PATH=/julia-depot:/julia-depot-image`, a writable overlay in
/// front of a read-only baked layer). So a shared-cache writer must pass
/// `Stack.writeDepot()` and a lookup must iterate `Stack.entries` -- passing
/// entry 0 to a lookup silently misses everything the image baked in.
///
/// Julia finishes with `abspath(cachepath, ...)`, which both resolves a
/// relative depot root against the process cwd AND normalises the result
/// (`abspath("/a//b/../c", "d.ji") == "/a/c/d.ji"`, verified). This joins
/// without doing either, because Ajt's depot roots always come from
/// `depot.resolve`, which yields absolute, already-clean paths -- an
/// unnormalised or relative root here is a caller bug, not a supported mode.
///
/// Unlike Julia's version this creates no directories. `compilecache_path`
/// `mkpath`s the parent as a side effect (`loading.jl:3155`); a path
/// calculation that mutates the depot is not something a caller can use to ask
/// a question, so the two jobs stay separate.
///
/// Arena-allocated.
pub fn cachePath(
    arena: Allocator,
    dep: Depot,
    major: u32,
    minor: u32,
    pkg: PkgId,
    in: Inputs,
) Allocator.Error![]u8 {
    const dir = try cacheDir(arena, dep, major, minor, pkg);
    const uuid = pkg.uuid orelse {
        const file = try std.fmt.allocPrint(arena, "{s}.ji", .{pkg.name});
        return fspath.join(arena, &.{ dir, file });
    };
    var entry_buf: [slug_len]u8 = undefined;
    var pre_buf: [slug_len]u8 = undefined;
    const file = try std.fmt.allocPrint(arena, "{s}_{s}.ji", .{
        pkg_slug.packageSlug(uuid, &entry_buf),
        precompileSlug(in, &pre_buf),
    });
    return fspath.join(arena, &.{ dir, file });
}

/// The host's `Libc.Libdl.dlext`, the extension `ocachefile_from_cachefile`
/// substitutes.
pub const host_dlext: []const u8 = switch (builtin.os.tag) {
    .windows => "dll",
    .macos, .ios, .tvos, .watchos, .visionos => "dylib",
    else => "so",
};

/// `ocachefile_from_cachefile(cachefile)` (`loading.jl:1264`): the native-code
/// sibling of a `.ji`, same stem, `.so`/`.dylib`/`.dll` instead.
///
/// It exists only when the entry was built with `use_pkgimages` (the default);
/// without it Julia rejects the `.ji` outright (`loading.jl:4020-4022`), which
/// is the failure mode of a cache transfer that copies one file and not the
/// other.
///
/// A path that does not end in `.ji` is returned unchanged, matching
/// `chopsuffix`. Arena-allocated.
pub fn objectPath(arena: Allocator, cache_path: []const u8, dlext: []const u8) Allocator.Error![]u8 {
    const stem = if (std.mem.endsWith(u8, cache_path, ".ji"))
        cache_path[0 .. cache_path.len - 3]
    else
        cache_path;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ stem, dlext });
}

// ---------------------------------------------------------------------------
// Debugging
// ---------------------------------------------------------------------------

/// The exact chain `crc` performs, rendered as text.
///
/// Same reasoning as `preferences.hashInput` and `project_hash.digestString`:
/// when a slug disagrees with Julia there is nothing to look at, and the usual
/// cause is one input differing by a character (a trailing slash on the project
/// path, a `JULIA_CPU_TARGET` that is set on one side only). So print every
/// input verbatim with the running crc after it.
///
/// Caller owns the returned slice.
pub fn crcTrace(gpa: Allocator, in: Inputs) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    var h = std.hash.crc.Crc32Iscsi.init();
    // `final()` is taken on a COPY at each step: whether it is destructive is a
    // std implementation detail, and a trace that quietly changed the answer it
    // is explaining would be worse than no trace.
    const peek = struct {
        fn run(hasher: std.hash.crc.Crc32Iscsi) u32 {
            var copy = hasher;
            return copy.final();
        }
    }.run;

    const strings = [_]struct { label: []const u8, bytes: []const u8 }{
        .{ .label = "project   ", .bytes = in.project },
        .{ .label = "image_file", .bytes = in.image_file },
        .{ .label = "julia_bin ", .bytes = in.julia_bin },
    };
    for (strings) |s| {
        h.update(s.bytes);
        w.print("{s} = \"{s}\"  -> crc = 0x{x:0>8}\n", .{ s.label, s.bytes, peek(h) }) catch
            return error.OutOfMemory;
    }

    const flag_byte = in.flags.toByte();
    h.update(&[_]u8{flag_byte});
    w.print(
        "flags     = 0x{x:0>2} (pkgimages={}, g={d}, check_bounds={d}, inline={}, O{d})" ++
            "  -> crc = 0x{x:0>8}\n",
        .{
            flag_byte,
            in.flags.use_pkgimages,
            in.flags.debug_level,
            in.flags.check_bounds,
            in.flags.inlining,
            in.flags.opt_level,
            peek(h),
        },
    ) catch return error.OutOfMemory;

    h.update(in.cpu_target);
    w.print("cpu_target = \"{s}\"  -> crc = 0x{x:0>8}\n", .{ in.cpu_target, peek(h) }) catch
        return error.OutOfMemory;

    const prefs_bytes = prefsHashBytes(in.prefs_hash);
    h.update(&prefs_bytes);
    const final = peek(h);
    w.print("prefs_hash = 0x{x:0>16} as bytes {x}  -> crc = 0x{x:0>8}\n", .{
        in.prefs_hash,
        prefs_bytes,
        final,
    }) catch return error.OutOfMemory;

    var buf: [slug_len]u8 = undefined;
    w.print("slug = {s}\n", .{pkg_slug.slug(final, slug_len, &buf)}) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ===========================================================================

const testing = std.testing;

/// Synthetic inputs, short enough to read. Every expectation that uses them
/// came out of `Base._crc32c` on Julia 1.12.6, never out of a head.
const fixture: Inputs = .{
    .project = "/p/Project.toml",
    .image_file = "/i/sys.so",
    .julia_bin = "/b/julia",
    .flags = .default,
    .cpu_target = "native",
    .prefs_hash = 0,
};

test "the default cache-flags byte is 0xa3" {
    // `_cacheflag_to_uint8(Base.CacheFlags())` and
    // `_cacheflag_to_uint8(Base.DefaultCacheFlags)` both print 163 on a release
    // Julia 1.12.6.
    try testing.expectEqual(@as(u8, 0xa3), Flags.default.toByte());
    try testing.expectEqual(@as(u8, 163), Flags.default.toByte());
}

test "flag byte round-trips through every field" {
    try testing.expectEqual(Flags.default, Flags.fromByte(0xa3));
    const odd: Flags = .{
        .use_pkgimages = false,
        .debug_level = 2,
        .check_bounds = 1,
        .inlining = false,
        .opt_level = 3,
    };
    try testing.expectEqual(odd, Flags.fromByte(odd.toByte()));
    // Bit positions, spelled out: OOICCDDP.
    try testing.expectEqual(@as(u8, 0b11_0_01_10_0), odd.toByte());
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        const f = Flags.fromByte(@intCast(b));
        try testing.expectEqual(@as(u8, @intCast(b)), f.toByte());
    }
}

test "crc chain reproduces Base._crc32c on synthetic inputs" {
    // Ground truth, each from
    //   crc = _crc32c(project); crc = _crc32c(image, crc); crc = _crc32c(bin, crc)
    //   crc = _crc32c(UInt8(flags), crc); crc = _crc32c(cpu, crc)
    //   crc = _crc32c(UInt64(prefs), crc); slug(crc, 5)
    // on Julia 1.12.6.
    const cases = [_]struct { in: Inputs, crc: u32, want: []const u8 }{
        // A: the fixture itself.
        .{ .in = fixture, .crc = 0xabfa502c, .want = "OhcQJ" },
        // B: the deployment's pinned CPU target (backend/Dockerfile:137).
        .{
            .in = .{
                .project = "/p/Project.toml",
                .image_file = "/i/sys.so",
                .julia_bin = "/b/julia",
                .cpu_target = "generic;haswell,clone_all",
            },
            .crc = 0xfb393ea5,
            .want = "RiAPl",
        },
        // C: a non-zero prefs_hash -- the little-endian landmark.
        .{
            .in = .{
                .project = "/p/Project.toml",
                .image_file = "/i/sys.so",
                .julia_bin = "/b/julia",
                .cpu_target = "native",
                .prefs_hash = 0x0102030405060708,
            },
            .crc = 0x012be0ba,
            .want = "ikcUB",
        },
        // D: a different project path.
        .{
            .in = .{
                .project = "/other/Project.toml",
                .image_file = "/i/sys.so",
                .julia_bin = "/b/julia",
                .cpu_target = "native",
            },
            .crc = 0x6c81bc23,
            .want = "1BYM9",
        },
        // E: a different julia binary.
        .{
            .in = .{
                .project = "/p/Project.toml",
                .image_file = "/i/sys.so",
                .julia_bin = "/b2/julia",
                .cpu_target = "native",
            },
            .crc = 0x39b446d4,
            .want = "8KHgD",
        },
        // F: a different sysimage.
        .{
            .in = .{
                .project = "/p/Project.toml",
                .image_file = "/i2/sys.so",
                .julia_bin = "/b/julia",
                .cpu_target = "native",
            },
            .crc = 0x19cb3456,
            .want = "GavRd",
        },
        // G: one flag bit apart (opt_level 2 -> 0, i.e. byte 0xa3 -> 0xa2 is
        // not reachable; this is use_pkgimages=false).
        .{
            .in = .{
                .project = "/p/Project.toml",
                .image_file = "/i/sys.so",
                .julia_bin = "/b/julia",
                .flags = .{ .use_pkgimages = false },
                .cpu_target = "native",
            },
            .crc = 0xcc74ad2d,
            .want = "bVvIu",
        },
        // H: every string empty and the flag byte zero -- the degenerate input
        // is a real one (`compilecache_path(...; project="")`).
        .{
            .in = .{
                .project = "",
                .image_file = "",
                .julia_bin = "",
                .flags = .{
                    .use_pkgimages = false,
                    .debug_level = 0,
                    .check_bounds = 0,
                    .inlining = false,
                    .opt_level = 0,
                },
                .cpu_target = "",
            },
            .crc = 0xbbe568a3,
            .want = "rcCVb",
        },
    };

    for (cases, 0..) |c, i| {
        errdefer std.debug.print("case {d} failed\n", .{i});
        try testing.expectEqual(c.crc, crc(c.in));
        var buf: [slug_len]u8 = undefined;
        try testing.expectEqualStrings(c.want, precompileSlug(c.in, &buf));
    }
}

test "prefs_hash is hashed little-endian, not big-endian" {
    // The whole trap in one assertion. Big-endian bytes for the same value
    // give 0x615bfd27 / "Pwohw" -- confirmed by feeding
    // UInt8[0x01,...,0x08] to _crc32c, and equally plausible on inspection.
    const in: Inputs = .{
        .project = "/p/Project.toml",
        .image_file = "/i/sys.so",
        .julia_bin = "/b/julia",
        .cpu_target = "native",
        .prefs_hash = 0x0102030405060708,
    };
    try testing.expectEqual(@as(u32, 0x012be0ba), crc(in));
    try testing.expect(crc(in) != 0x615bfd27);

    try testing.expectEqualSlices(
        u8,
        &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 },
        &prefsHashBytes(0x0102030405060708),
    );
}

test "every input is load-bearing" {
    // A slug that ignores one of its inputs collides across machines, and the
    // collision is silent -- the runtime loads a cache built for a different
    // sysimage or a different project. Each of these must move the slug.
    const base = crc(fixture);
    var mut = fixture;

    mut = fixture;
    mut.project = "/p/Project.toml/";
    try testing.expect(crc(mut) != base);

    mut = fixture;
    mut.image_file = "/i/sys.dylib";
    try testing.expect(crc(mut) != base);

    mut = fixture;
    mut.julia_bin = "/b/julia1";
    try testing.expect(crc(mut) != base);

    mut = fixture;
    mut.cpu_target = "generic;haswell,clone_all";
    try testing.expect(crc(mut) != base);

    mut = fixture;
    mut.prefs_hash = 1;
    try testing.expect(crc(mut) != base);

    // Every single flag bit, one at a time.
    var bit: u3 = 0;
    while (true) : (bit += 1) {
        const flipped = Flags.fromByte(Flags.default.toByte() ^ (@as(u8, 1) << bit));
        mut = fixture;
        mut.flags = flipped;
        try testing.expect(crc(mut) != base);
        if (bit == 7) break;
    }

    // ...and changing nothing must not move it.
    try testing.expectEqual(base, crc(fixture));
}

test "cpuTarget prefers a SET environment variable, empty string included" {
    try testing.expectEqualStrings("native", cpuTarget(null, "native"));
    try testing.expectEqualStrings("generic", cpuTarget("generic", "native"));
    // Set-but-empty is not unset; `get(ENV, k, nothing)` returns "".
    try testing.expectEqualStrings("", cpuTarget("", "native"));
}

test "cachePath reproduces a real .ji on this depot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Ground truth: the file
    //   /home/ofekb/.julia/compiled/v1.12/StaticArrays/yY9vm_3FUgb.ji
    // exists on the dev box, and
    //   Base.compilecache_path(PkgId(UUID("90137ffa-…"), "StaticArrays"), UInt64(0);
    //                          project="/home/ofekb/ReailtyForge/Open-Reality/Project.toml")
    // returns exactly that string. The JLOptions values below are that
    // machine's, verbatim -- which is the module's whole point: the slug is a
    // function of the install, not of the package.
    const dep: Depot = .{ .root = "/home/ofekb/.julia" };
    const pkg: PkgId = .{
        .name = "StaticArrays",
        .uuid = try Uuid.parse("90137ffa-7385-5640-81b9-e52037218182"),
    };
    const in: Inputs = .{
        .project = "/home/ofekb/ReailtyForge/Open-Reality/Project.toml",
        .image_file = "/nix/store/p6zk0sffyz9kzrvjn32c4y4wv90rbfah-julia-1.12.6/lib/julia/sys.so",
        .julia_bin = "/nix/store/p6zk0sffyz9kzrvjn32c4y4wv90rbfah-julia-1.12.6/bin/julia",
        .cpu_target = "native",
    };

    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/StaticArrays/yY9vm_3FUgb.ji",
        try cachePath(a, dep, 1, 12, pkg, in),
    );
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/StaticArrays",
        try cacheDir(a, dep, 1, 12, pkg),
    );
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/StaticArrays/yY9vm_3FUgb.so",
        try objectPath(a, try cachePath(a, dep, 1, 12, pkg, in), "so"),
    );

    // The same package under the default shared environment is a DIFFERENT
    // file, and it also exists on that machine (yY9vm_7ItZt.ji).
    var other = in;
    other.project = "/home/ofekb/.julia/environments/v1.12/Project.toml";
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/StaticArrays/yY9vm_7ItZt.ji",
        try cachePath(a, dep, 1, 12, pkg, other),
    );

    // ...and with no active project at all (`project=""`).
    var none = in;
    none.project = "";
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/StaticArrays/yY9vm_CfnKq.ji",
        try cachePath(a, dep, 1, 12, pkg, none),
    );
}

test "a UUID-less PkgId gets no slug and no name directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Base.compilecache_path(Base.PkgId("MyScript"), UInt64(0); project="/p/Project.toml")
    //   -> /home/ofekb/.julia/compiled/v1.12/MyScript.ji
    // and cache_file_entry gives ("compiled/v1.12/", "MyScript").
    const dep: Depot = .{ .root = "/home/ofekb/.julia" };
    const pkg: PkgId = .{ .name = "MyScript" };
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12/MyScript.ji",
        try cachePath(a, dep, 1, 12, pkg, fixture),
    );
    try testing.expectEqualStrings(
        "/home/ofekb/.julia/compiled/v1.12",
        try cacheDir(a, dep, 1, 12, pkg),
    );

    // None of the local inputs reach that branch, so nothing distinguishes two
    // machines' entries for a UUID-less PkgId.
    var other = fixture;
    other.project = "/somewhere/else/Project.toml";
    other.prefs_hash = 12345;
    try testing.expectEqualStrings(
        try cachePath(a, dep, 1, 12, pkg, fixture),
        try cachePath(a, dep, 1, 12, pkg, other),
    );
}

test "objectPath swaps only a trailing .ji" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("/x/a_b.so", try objectPath(a, "/x/a_b.ji", "so"));
    try testing.expectEqualStrings("/x/a_b.dylib", try objectPath(a, "/x/a_b.ji", "dylib"));
    try testing.expectEqualStrings("/x/a_b.dll", try objectPath(a, "/x/a_b.ji", "dll"));
    // chopsuffix on a non-match leaves the string alone.
    try testing.expectEqualStrings("/x/a_b.so", try objectPath(a, "/x/a_b", "so"));
    try testing.expectEqualStrings("/x/.ji.d.so", try objectPath(a, "/x/.ji.d", "so"));
    try testing.expect(host_dlext.len >= 2);
}

test "crcTrace prints every input and the running crc" {
    const text = try crcTrace(testing.allocator, fixture);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "project    = \"/p/Project.toml\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "image_file = \"/i/sys.so\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "julia_bin  = \"/b/julia\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "flags     = 0xa3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cpu_target = \"native\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "prefs_hash = 0x0000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-> crc = 0xabfa502c") != null);
    try testing.expect(std.mem.indexOf(u8, text, "slug = OhcQJ\n") != null);
}
