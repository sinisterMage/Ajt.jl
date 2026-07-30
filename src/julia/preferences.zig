//! Preferences and `prefs_hash`.
//!
//! The precompile cache filename is a crc32c chain over the active project
//! path, the sysimage path, the julia binary, the cache flags, the CPU target
//! and **`prefs_hash`** (`base/loading.jl:3152-3172`), and the same hash is
//! re-derived and compared when a `.ji` is loaded (`base/loading.jl:4145-4152`).
//! Get it wrong and every cache entry silently misses -- no error, just a full
//! recompile, forever.
//!
//! ## There is no `Preferences.toml`
//!
//! A common misconception, worth stating up front because it makes the rest of
//! this file read differently. Julia's loader knows exactly two preference
//! sources, and neither is named `Preferences.toml`:
//!
//!   1. the `[preferences]` table **inside** `Project.toml` (`loading.jl:3736`), and
//!   2. a sidecar next to it, named from
//!      `preferences_names = ("JuliaLocalPreferences.toml", "LocalPreferences.toml")`
//!      (`loading.jl:637`, used at `loading.jl:3740-3750`).
//!
//! `Preferences.jl` (the package) writes into one of those two; it never
//! creates a third file. `grep -rn "Preferences.toml"` over Julia 1.12.6's
//! `share/julia/` finds only the `LocalPreferences` names.
//!
//! ## Composition rules, and where each comes from
//!
//! * `collect_preferences` (`loading.jl:3718-3752`) returns an ordered list of
//!   dicts for ONE project file: first `Project.toml`'s `[preferences]`, then
//!   at most one sidecar. `JuliaLocalPreferences.toml` wins outright -- the
//!   loop `break`s on the first name that exists (`loading.jl:3746-3748`), so
//!   a `LocalPreferences.toml` beside it is never read.
//! * Per-package keying: everything is filtered through
//!   `filter_preferences` (`loading.jl:3710-3716`), i.e. the tables are keyed
//!   by package **name**, and the name is resolved from the requested UUID by
//!   `get_uuid_name` (`loading.jl:3676-3701`) against *that* project file. If
//!   the UUID is not the project itself and appears in none of its
//!   `deps`/`extras`/`weakdeps`, `collect_preferences` returns an EMPTY list
//!   (`loading.jl:3729-3731`) -- that env contributes nothing at all, not even
//!   its sidecar.
//! * Merging is `recursive_prefs_merge` (`loading.jl:3761-3784`): later
//!   overrides win, nested tables merge recursively rather than replacing, and
//!   a `__clear__` key holding a `Vector{String}` deletes those keys from the
//!   accumulated result *before* the rest of that same override is applied
//!   (`loading.jl:3765-3770`). `__clear__` itself survives into the merged
//!   dict, because the copy loop does not special-case it.
//! * `get_preferences` (`loading.jl:3797-3817`) walks the load path in
//!   **reverse**, so the active project is merged last and wins; the first
//!   load-path entry is expanded to itself plus its workspace ancestors first
//!   (`get_projects_workspace_to_root`, `loading.jl:3786-3795`).
//!
//! ## The hash itself
//!
//! `get_preferences_hash(uuid, prefs_list)` (`loading.jl:3819-3837`):
//!
//! ```julia
//! h = UInt(0)
//! uuid === nothing && return UInt64(h)
//! prefs = get_preferences(uuid)
//! for name in prefs_list
//!     prefs_value = get(prefs, name, nothing)
//!     prefs_value !== nothing && (h = hash(prefs_value, h))
//! end
//! return UInt64(h)
//! ```
//!
//! So: **only the values participate, never the keys**, and they are folded in
//! `prefs_list` order -- the order is load-bearing, `["a","b"]` and `["b","a"]`
//! give different hashes (verified against Julia). Absent names are skipped
//! silently. A `nothing` UUID short-circuits to 0, which is also what the
//! common "this project has no preferences at all" case produces, since an
//! empty merged dict makes every lookup miss.
//!
//! That leaves `Base.hash` as the real work. It is not a stable published
//! format, it is whatever `base/hashing.jl` does, so this file ports it:
//! `hash_64_64` (`hashing.jl:43-53`), integers (`:87-89`), `Float64`
//! (`:105-121`), strings (`:196-201`), tuples (`base/tuple.jl:578-580`),
//! arrays (`base/abstractarray.jl:3570-3583`) and dicts
//! (`base/abstractdict.jl:540-546`).
//!
//! Traps found while porting, each of which yields a plausible wrong answer:
//!
//!  1. `hash(::String)` bottoms out in the C `memhash_seed`, which is the
//!     **second** 64-bit word of `MurmurHash3_x64_128` -- not the first, and
//!     not MurmurHash64A. Confirmed by differential test against
//!     `ccall(:memhash_seed, ...)` on three inputs; the first word is a
//!     perfectly plausible wrong answer.
//!  2. `hash(-0.0) != hash(0.0)`. `hash(::Float64)` routes integral values
//!     through `hash(::Int64)` only if `isequal(trunc(x), x)`, and Julia's
//!     `isequal` compares sign bits, so `-0.0` falls through to the raw
//!     bit-pattern path. A plain `==` here silently merges the two.
//!  3. The array hash mixes in `map(first, axes(A))` and `map(last, axes(A))`
//!     as 1-tuples, i.e. `(1,)` and `(length,)` -- an empty array is NOT just
//!     the seed.
//!  4. The dict hash is XOR-folded over `hash(k, hash(v))` (note: `hash(v)`
//!     seeded with 0, not with the running `h`), so it is order-independent,
//!     and only then mixed with `h`.
//!
//! Values are hashed exactly as `Base.parsed_toml` types them, which is
//! `Dict{String,Any}` / `Vector{...}` / `String` / `Int64` / `Float64` /
//! `Bool`. Element types do not affect the array hash, so the parser's
//! narrowing (`["a","b"] -> Vector{String}`, `[] -> Vector{Any}`) only matters
//! for the `__clear__` `isa Vector{String}` test.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const value_mod = @import("../toml/value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const parse_mod = @import("../toml/parse.zig");
const Uuid = @import("slug.zig").Uuid;

pub const HashError = error{
    /// A TOML date/time reached the hasher. Julia would fall back to the
    /// generic `hash(@nospecialize(x), h) = hash_uint(3h - objectid(x))`
    /// (`hashing.jl:37`) over a `Base.TOML.Date`/`DateTime`/`Time`, whose
    /// `objectid` is an internal C detail. Rather than guess, refuse: no real
    /// preference has ever been a date, and a wrong guess would be invisible.
    UnsupportedPreferenceValue,
    /// `hash(::AbstractArray)` switches to a Fibonacci-sampling scheme at
    /// 8192 elements (`abstractarray.jl:3577`). Only the short path is ported;
    /// the long one needs `isequal`/`findprev` over TOML values and no
    /// preference is remotely that large. Refusing beats guessing.
    ArrayTooLongToHash,
};

pub const Error = HashError || error{
    /// A project or preferences file has the right shape but the wrong types
    /// (e.g. `preferences` is not a table). Julia raises a `TypeError` from
    /// the `::Dict{String,Any}` assertions in `collect_preferences`.
    InvalidPreferences,
} || error{InvalidUuid} || Allocator.Error;

// ===========================================================================
// Base.hash
// ===========================================================================

/// `hash_64_64` (`base/hashing.jl:43-53`). Thomas Wang's 64-bit mix; every
/// operation wraps.
pub fn hash64_64(n: u64) u64 {
    var a: u64 = n;
    a = ~a +% (a << 21);
    a = a ^ (a >> 24);
    a = a +% (a << 3) +% (a << 8);
    a = a ^ (a >> 14);
    a = a +% (a << 2) +% (a << 4);
    a = a ^ (a >> 28);
    a = a +% (a << 31);
    return a;
}

fn rotl64(x: u64, comptime r: u6) u64 {
    return (x << r) | (x >> @intCast(64 - @as(u7, r)));
}

fn fmix64(k0: u64) u64 {
    var k = k0;
    k ^= k >> 33;
    k *%= 0xff51afd7ed558ccd;
    k ^= k >> 33;
    k *%= 0xc4ceb9fe1a85ec53;
    k ^= k >> 33;
    return k;
}

/// `memhash_seed` from Julia's `src/support/hashing.c`: MurmurHash3_x64_128
/// with the given seed, returning the **second** output word.
///
/// The halves are not interchangeable and both look equally plausible in
/// isolation, so this is pinned by a differential test against
/// `ccall(:memhash_seed, UInt64, (Ptr{UInt8}, Csize_t, UInt32), ...)` below.
///
/// Block loads are native-endian, matching the C `getblock64`. Julia's string
/// hash is therefore endianness-dependent by construction; so is this port.
pub fn memhashSeed(data: []const u8, seed: u32) u64 {
    const c1: u64 = 0x87c37b91114253d5;
    const c2: u64 = 0x4cf5ad432745937f;
    const endian = comptime builtin.cpu.arch.endian();

    var h1: u64 = seed;
    var h2: u64 = seed;

    const nblocks = data.len / 16;
    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        var k1 = std.mem.readInt(u64, data[i * 16 ..][0..8], endian);
        var k2 = std.mem.readInt(u64, data[i * 16 + 8 ..][0..8], endian);

        k1 *%= c1;
        k1 = rotl64(k1, 31);
        k1 *%= c2;
        h1 ^= k1;
        h1 = rotl64(h1, 27);
        h1 +%= h2;
        h1 = h1 *% 5 +% 0x52dce729;

        k2 *%= c2;
        k2 = rotl64(k2, 33);
        k2 *%= c1;
        h2 ^= k2;
        h2 = rotl64(h2, 31);
        h2 +%= h1;
        h2 = h2 *% 5 +% 0x38495ab5;
    }

    const tail = data[nblocks * 16 ..];
    var k1: u64 = 0;
    var k2: u64 = 0;
    // Fall-through switch in the C original; written as an if-ladder here.
    if (tail.len >= 15) k2 ^= @as(u64, tail[14]) << 48;
    if (tail.len >= 14) k2 ^= @as(u64, tail[13]) << 40;
    if (tail.len >= 13) k2 ^= @as(u64, tail[12]) << 32;
    if (tail.len >= 12) k2 ^= @as(u64, tail[11]) << 24;
    if (tail.len >= 11) k2 ^= @as(u64, tail[10]) << 16;
    if (tail.len >= 10) k2 ^= @as(u64, tail[9]) << 8;
    if (tail.len >= 9) {
        k2 ^= @as(u64, tail[8]);
        k2 *%= c2;
        k2 = rotl64(k2, 33);
        k2 *%= c1;
        h2 ^= k2;
    }
    if (tail.len >= 8) k1 ^= @as(u64, tail[7]) << 56;
    if (tail.len >= 7) k1 ^= @as(u64, tail[6]) << 48;
    if (tail.len >= 6) k1 ^= @as(u64, tail[5]) << 40;
    if (tail.len >= 5) k1 ^= @as(u64, tail[4]) << 32;
    if (tail.len >= 4) k1 ^= @as(u64, tail[3]) << 24;
    if (tail.len >= 3) k1 ^= @as(u64, tail[2]) << 16;
    if (tail.len >= 2) k1 ^= @as(u64, tail[1]) << 8;
    if (tail.len >= 1) {
        k1 ^= @as(u64, tail[0]);
        k1 *%= c1;
        k1 = rotl64(k1, 31);
        k1 *%= c2;
        h1 ^= k1;
    }

    h1 ^= @as(u64, data.len);
    h2 ^= @as(u64, data.len);
    h1 +%= h2;
    h2 +%= h1;
    h1 = fmix64(h1);
    h2 = fmix64(h2);
    h1 +%= h2;
    h2 +%= h1;
    return h2;
}

/// `hashing.jl:196` — `memhash_seed = 0x71e729fd56419c81` on 64-bit.
const memhash_seed_const: u64 = 0x71e729fd56419c81;
/// `base/tuple.jl:578`.
const tuplehash_seed: u64 = 0x77cfa1eef01bca90;
/// `base/abstractarray.jl:3570`.
const hash_abstractarray_seed: u64 = 0x7e2d6fb6448beb77;
/// `base/abstractdict.jl:540`.
const hasha_seed: u64 = 0x6d35bb51952d5539;
/// `hashing.jl:104` — `hash_uint64(reinterpret(UInt64, NaN))`.
const hx_nan: u64 = hash64_64(0x7ff8000000000000);

/// `hash(s::String, h::UInt)` (`hashing.jl:198-201`).
pub fn hashString(s: []const u8, h0: u64) u64 {
    const h = h0 +% memhash_seed_const;
    return memhashSeed(s, @truncate(h)) +% h;
}

/// `hash(x::UInt64, h::UInt)` (`hashing.jl:88`).
pub fn hashU64(x: u64, h: u64) u64 {
    return hash64_64(x) -% (3 *% h);
}

/// `hash(x::Int64, h::UInt)` (`hashing.jl:87`). `Bool`/`Int8`..`UInt32` all
/// widen to this (`hashing.jl:89`).
pub fn hashI64(x: i64, h: u64) u64 {
    return hashU64(@bitCast(x), h);
}

pub fn hashBool(x: bool, h: u64) u64 {
    return hashI64(@intFromBool(x), h);
}

/// `hash(x::Float64, h::UInt)` (`hashing.jl:105-121`).
///
/// Integral values are re-hashed as `Int64` (or `UInt64` above the `Int64`
/// range) so that `hash(1) == hash(1.0)`. The gate is `isequal`, not `==`,
/// which is what keeps `-0.0` out of the integer path: `isequal(0, -0.0)` is
/// `false` in Julia because the sign bits differ, and `hash(-0.0)` therefore
/// comes from the raw bit pattern. Verified against Julia
/// (`hash(0.0) = 0x77cfa1eef01bca90`, `hash(-0.0) = 0x3be7d0f7780de548`).
///
/// The range tests use 2^63 / 2^64 rather than `typemax(Int64)` /
/// `typemax(UInt64)`: no `f64` lies strictly between those typemaxes and the
/// next power of two (the ulp there is 2048), so the tests are equivalent and
/// these bounds are exactly representable.
pub fn hashF64(x: f64, h: u64) u64 {
    const two_63: f64 = 9223372036854775808.0;
    const two_64: f64 = 18446744073709551616.0;
    if (x >= -two_63 and x < two_63) {
        const xi: i64 = @intFromFloat(x);
        const back: f64 = @floatFromInt(xi);
        if (back == x and std.math.signbit(back) == std.math.signbit(x)) return hashI64(xi, h);
    } else if (x >= 0.0 and x < two_64) {
        const xu: u64 = @intFromFloat(x);
        const back: f64 = @floatFromInt(xu);
        if (back == x) return hashU64(xu, h);
    } else if (std.math.isNan(x)) {
        // NaN has no stable bit pattern, so Julia XORs a precomputed constant.
        return hx_nan ^ h;
    }
    return hashU64(@bitCast(x), h);
}

/// `hash(t::Tuple, h)` for a 1-tuple (`base/tuple.jl:579-580`):
/// `hash(x, h + tuplehash_seed)`.
fn hashTuple1(x: i64, h: u64) u64 {
    return hashI64(x, h +% tuplehash_seed);
}

/// `hash(A::AbstractArray, h)` (`base/abstractarray.jl:3571-3583`), short path.
///
/// The axes contribute as two 1-tuples: `map(first, axes(A))` is `(1,)` and
/// `map(last, axes(A))` is `(length(A),)` for the 1-D vectors TOML produces.
/// Omitting them is the classic wrong answer -- it happens to still vary with
/// the contents, so it looks fine until compared with Julia.
pub fn hashArray(items: []const Value, h0: u64) HashError!u64 {
    if (items.len >= 8192) return error.ArrayTooLongToHash;
    var h = h0 +% hash_abstractarray_seed;
    h = hashTuple1(1, h);
    h = hashTuple1(@intCast(items.len), h);
    for (items) |v| h = try hashValue(v, h);
    return h;
}

/// `hash(a::AbstractDict, h)` (`base/abstractdict.jl:541-546`).
///
/// XOR-folded, hence order-independent -- which is the only reason it is safe
/// for Ajt's insertion-ordered `Table` to stand in for Julia's `Dict`. Note
/// the inner `hash(v)` is seeded with 0, not with the running `h`.
pub fn hashTable(t: *const Table, h: u64) HashError!u64 {
    var hv: u64 = hasha_seed;
    for (t.entries.items) |e| {
        hv ^= hashString(e.key, try hashValue(e.value, 0));
    }
    return hashU64(hv, h);
}

/// `hash(value, h)` dispatched over the TOML value model.
pub fn hashValue(v: Value, h: u64) HashError!u64 {
    return switch (v) {
        .string => |s| hashString(s, h),
        .integer => |i| hashI64(i, h),
        .float => |f| hashF64(f, h),
        .boolean => |b| hashBool(b, h),
        .array => |items| try hashArray(items, h),
        .table => |t| try hashTable(t, h),
        .datetime => error.UnsupportedPreferenceValue,
    };
}

// ===========================================================================
// Collection and merging
// ===========================================================================

/// `preferences_names` (`loading.jl:637`), in priority order. The first that
/// exists wins outright; the loop `break`s (`loading.jl:3746-3748`).
pub const preferences_names = [_][]const u8{ "JuliaLocalPreferences.toml", "LocalPreferences.toml" };

/// `project_names` (`loading.jl:630`), in priority order.
pub const project_names = [_][]const u8{ "JuliaProject.toml", "Project.toml" };

/// One resolved environment: a parsed project file plus the sidecar that sits
/// beside it, if any.
pub const Env = struct {
    /// Parsed `(Julia)Project.toml`.
    project: *const Table,
    /// Parsed `(Julia)LocalPreferences.toml` from the same directory.
    local: ?*const Table = null,
};

/// `get_uuid_name(project, uuid)` (`loading.jl:3676-3701`): map a UUID to the
/// name its preferences are filed under *in this project file*.
///
/// Julia scans `deps` twice (once alone, once as the first of
/// `("deps", "extras", "weakdeps")`), which is harmless; reproduced here only
/// in effect. If two names share a UUID, Julia's answer depends on `Dict`
/// iteration order and is not well-defined -- ours is file order.
///
/// A malformed UUID string raises in Julia (`UUID(v::String)` throws), so it
/// is an error here too rather than a silent skip.
pub fn getUuidName(project: *const Table, uuid: Uuid) Error!?[]const u8 {
    const self_name: ?[]const u8 = if (project.get("name")) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidPreferences,
    } else null;
    const self_uuid: ?[]const u8 = if (project.get("uuid")) |v| switch (v) {
        .string => |s| s,
        else => return error.InvalidPreferences,
    } else null;
    if (self_name != null and self_uuid != null) {
        const parsed = try Uuid.parse(self_uuid.?);
        if (std.mem.eql(u8, &parsed.bytes, &uuid.bytes)) return self_name.?;
    }

    for ([_][]const u8{ "deps", "extras", "weakdeps" }) |subkey| {
        const sub = project.get(subkey) orelse continue;
        const tbl = switch (sub) {
            .table => |t| t,
            else => return error.InvalidPreferences,
        };
        for (tbl.entries.items) |e| {
            const s = switch (e.value) {
                .string => |s| s,
                else => return error.InvalidPreferences,
            };
            const parsed = try Uuid.parse(s);
            if (std.mem.eql(u8, &parsed.bytes, &uuid.bytes)) return e.key;
        }
    }
    return null;
}

/// `filter_preferences(prefs, pkg_name)` (`loading.jl:3710-3716`): the whole
/// table when no UUID was requested, otherwise the `[pkg_name]` sub-table
/// (empty if absent).
fn filterPreferences(prefs: *const Table, pkg_name: ?[]const u8) Error!?*const Table {
    const name = pkg_name orelse return prefs;
    const v = prefs.get(name) orelse return null;
    return switch (v) {
        .table => |t| t,
        else => error.InvalidPreferences,
    };
}

/// `collect_preferences(project_toml, uuid)` (`loading.jl:3718-3752`).
///
/// Returns the dicts contributed by ONE environment, in merge order (project
/// first, sidecar second). Empty when the UUID cannot be named from this
/// project file -- the env then contributes nothing at all, sidecar included.
///
/// Julia always pushes the project's dict even when it is empty
/// (`loading.jl:3737`); this omits absent tables instead, because merging an
/// empty dict is a no-op and the count is not otherwise observable.
///
/// Arena-allocated: the returned slice has the arena's lifetime; the tables
/// inside it are borrowed from the parsed documents.
pub fn collect(arena: Allocator, env: Env, uuid: ?Uuid) Error![]const *const Table {
    var dicts: std.ArrayList(*const Table) = .empty;

    var pkg_name: ?[]const u8 = null;
    if (uuid) |u| {
        pkg_name = try getUuidName(env.project, u) orelse return dicts.items;
    }

    const proj_prefs: ?*const Table = if (env.project.get("preferences")) |v| switch (v) {
        .table => |t| t,
        else => return error.InvalidPreferences,
    } else null;
    if (proj_prefs) |p| {
        if (try filterPreferences(p, pkg_name)) |f| try dicts.append(arena, f);
    }

    if (env.local) |l| {
        if (try filterPreferences(l, pkg_name)) |f| try dicts.append(arena, f);
    }

    return dicts.items;
}

/// True for what Julia's TOML parser types as `Vector{String}`, the only shape
/// `__clear__` honours (`loading.jl:3766`).
///
/// Empirically, `Base.parsed_toml` narrows `["a","b"]` to `Vector{String}` but
/// leaves `[]` as `Vector{Any}`, so the emptiness test is not pedantry -- it
/// is the observed narrowing. (It also happens not to change behaviour: an
/// empty clear list deletes nothing either way.)
fn isVectorOfString(v: Value) bool {
    const items = switch (v) {
        .array => |a| a,
        else => return false,
    };
    if (items.len == 0) return false;
    for (items) |item| if (item != .string) return false;
    return true;
}

const Scratch = std.StringArrayHashMapUnmanaged(Value);

fn materialize(arena: Allocator, scratch: *const Scratch) Allocator.Error!*Table {
    const t = try Table.create(arena);
    for (scratch.keys(), scratch.values()) |k, v| try t.put(arena, k, v);
    return t;
}

fn mergeOverride(arena: Allocator, scratch: *Scratch, override: *const Table) Error!void {
    // Clears run before this override's own assignments, and against the
    // accumulated result -- so an earlier override in the same call can have
    // its keys removed again (`loading.jl:3765-3770`).
    if (override.get("__clear__")) |cv| {
        if (isVectorOfString(cv)) {
            for (cv.array) |item| _ = scratch.orderedRemove(item.string);
        }
    }
    for (override.entries.items) |e| {
        const existing = scratch.get(e.key);
        if (existing != null and existing.? == .table and e.value == .table) {
            const merged = try merge(arena, existing.?.table, &.{e.value.table});
            try scratch.put(arena, e.key, .{ .table = merged });
        } else {
            try scratch.put(arena, e.key, e.value);
        }
    }
}

/// `recursive_prefs_merge(base, overrides...)` (`loading.jl:3761-3784`).
///
/// Arena-allocated: the result and every table it creates live on `arena`.
/// Values that are not merged are shared with the inputs, which is safe
/// because nothing here mutates an input table.
pub fn merge(arena: Allocator, base: *const Table, overrides: []const *const Table) Error!*Table {
    var scratch: Scratch = .empty;
    for (base.entries.items) |e| try scratch.put(arena, e.key, e.value);
    for (overrides) |o| try mergeOverride(arena, &scratch, o);
    return materialize(arena, &scratch);
}

/// `get_preferences(uuid)` (`loading.jl:3797-3817`) over an explicit,
/// already-resolved environment list.
///
/// `envs` must be in Julia's `projects_to_merge_prefs` order
/// (`loading.jl:3800-3806`): the active project, then its workspace ancestors
/// leaf-to-root, then the remaining load-path entries. Merging walks that list
/// in REVERSE, so `envs[0]` has the highest precedence.
///
/// Load-path resolution itself is deliberately not done here: it depends on
/// `JULIA_LOAD_PATH`, `@`/`@v#.#`/`@stdlib` expansion and the depot layout.
/// `loadEnvs` below does the filesystem half for the common case.
///
/// Arena-allocated.
pub fn getPreferences(arena: Allocator, envs: []const Env, uuid: ?Uuid) Error!*Table {
    var merged = try Table.create(arena);
    var i = envs.len;
    while (i > 0) {
        i -= 1;
        const dicts = try collect(arena, envs[i], uuid);
        merged = try merge(arena, merged, dicts);
    }
    return merged;
}

/// `get_preferences_hash(uuid, prefs_list)` (`loading.jl:3819-3837`), given an
/// already-merged preferences table.
///
/// `prefs_list` order is part of the hash. Pass `null` for `prefs` to model
/// the `uuid === nothing` short-circuit, which returns 0.
pub fn preferencesHash(prefs: ?*const Table, prefs_list: []const []const u8) HashError!u64 {
    var h: u64 = 0;
    const p = prefs orelse return h;
    for (prefs_list) |name| {
        const v = p.get(name) orelse continue;
        h = try hashValue(v, h);
    }
    return h;
}

/// The exact fold that `preferencesHash` performs, rendered as text.
///
/// Same idea as `project_hash.digestString`: when a hash disagrees with Julia
/// there is nothing to look at, so expose the input. Each participating name
/// is printed with its value and the running hash after it is mixed in;
/// skipped names are printed too, because "the key was not in the merged
/// dict" is by far the most common cause of a mismatch.
///
/// Caller owns the returned slice.
pub fn hashInput(gpa: Allocator, prefs: ?*const Table, prefs_list: []const []const u8) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (prefs == null) {
        w.writeAll("# uuid === nothing -> 0\n") catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
    var h: u64 = 0;
    for (prefs_list) |name| {
        const v = prefs.?.get(name) orelse {
            w.print("{s} = <absent, skipped>\n", .{name}) catch return error.OutOfMemory;
            continue;
        };
        w.print("{s} = ", .{name}) catch return error.OutOfMemory;
        try renderValue(gpa, w, v);
        h = try hashValue(v, h);
        w.print("  -> h = 0x{x:0>16}\n", .{h}) catch return error.OutOfMemory;
    }
    w.print("prefs_hash = 0x{x:0>16}\n", .{h}) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Compact, deterministic rendering for `hashInput`. Table keys are sorted so
/// two runs are comparable; the hash itself does not care about order.
fn renderValue(gpa: Allocator, w: *std.Io.Writer, v: Value) Error!void {
    switch (v) {
        .string => |s| w.print("\"{s}\"", .{s}) catch return error.OutOfMemory,
        .integer => |i| w.print("{d}", .{i}) catch return error.OutOfMemory,
        .float => |f| w.print("{d}", .{f}) catch return error.OutOfMemory,
        .boolean => |b| w.print("{s}", .{if (b) "true" else "false"}) catch return error.OutOfMemory,
        .datetime => w.writeAll("<datetime>") catch return error.OutOfMemory,
        .array => |items| {
            w.writeAll("[") catch return error.OutOfMemory;
            for (items, 0..) |item, i| {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                try renderValue(gpa, w, item);
            }
            w.writeAll("]") catch return error.OutOfMemory;
        },
        .table => |t| {
            const entries = t.entries.items;
            const idx = try gpa.alloc(usize, entries.len);
            defer gpa.free(idx);
            for (idx, 0..) |*slot, i| slot.* = i;
            std.mem.sort(usize, idx, entries, struct {
                fn lt(es: []const value_mod.Entry, a: usize, b: usize) bool {
                    return std.mem.lessThan(u8, es[a].key, es[b].key);
                }
            }.lt);
            w.writeAll("{") catch return error.OutOfMemory;
            for (idx, 0..) |ei, i| {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("{s} = ", .{entries[ei].key}) catch return error.OutOfMemory;
                try renderValue(gpa, w, entries[ei].value);
            }
            w.writeAll("}") catch return error.OutOfMemory;
        },
    }
}

// ===========================================================================
// Filesystem resolution
// ===========================================================================

pub const IoError = Error || error{ReadFailed} || parse_mod.Error;

pub const ResolveOptions = struct {
    /// `base_project` stops climbing at the home-directory boundary, but only
    /// if it started inside home (`loading.jl:675-690`). Pass the real `$HOME`
    /// -- Zig 0.16 has no `std.posix.getenv`, and guessing it wrong changes
    /// which workspace root is found. `null` disables the boundary entirely,
    /// i.e. climb to the filesystem root.
    home_dir: ?[]const u8 = null,
    /// Follow `[workspace] projects` upwards from the first load-path entry
    /// (`get_projects_workspace_to_root`, `loading.jl:3786-3795`).
    walk_workspace: bool = true,
};

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `locate_project_file(env)` (`loading.jl:639-648`) composed with
/// `env_project_file(env)` (`loading.jl:653-671`): resolve a load-path entry
/// to the project file it designates, or null.
///
/// Arena-allocated.
pub fn envProjectFile(arena: Allocator, io: Io, env: []const u8) Allocator.Error!?[]const u8 {
    if (isDir(io, env)) {
        for (project_names) |p| {
            const candidate = try std.fs.path.join(arena, &.{ env, p });
            if (isFile(io, candidate)) return candidate;
        }
        return null;
    }
    const base = std.fs.path.basename(env);
    for (project_names) |p| {
        if (std.mem.eql(u8, base, p) and isFile(io, env)) return env;
    }
    return null;
}

/// The plain-path half of `load_path_expand` (`initdefs.jl:311-322`): make the
/// entry absolute, and if it is a directory holding a project file, return
/// that file instead.
///
/// `load_path()` applies this before `get_preferences` ever sees an entry, so
/// a directory entry and the project file it designates are the same input to
/// Julia -- but NOT to the workspace walk, which keys off `dirname`. Skipping
/// this step makes `<workspace>/member` climb from the workspace root instead
/// of from the member, and quietly lose the root's preferences.
///
/// `@`-prefixed names (`@`, `@v#.#`, `@stdlib`, ...) are out of scope: they
/// need the depot layout and the active project. So is the de-duplication
/// `load_path()` does, which cannot change a hash anyway because merging the
/// same environment twice is idempotent.
///
/// Arena-allocated.
pub fn expandLoadPathEntry(arena: Allocator, io: Io, env: []const u8) Allocator.Error![]const u8 {
    const path = try std.fs.path.resolve(arena, &.{env});
    if (isDir(io, path)) {
        for (project_names) |p| {
            const file = try std.fs.path.join(arena, &.{ path, p });
            if (isFile(io, file)) return file;
        }
    }
    return path;
}

/// The sidecar beside `project_file`, honouring the first-name-wins `break`
/// (`loading.jl:3740-3750`).
///
/// Arena-allocated.
pub fn localPreferencesFile(arena: Allocator, io: Io, project_file: []const u8) Allocator.Error!?[]const u8 {
    const dir = std.fs.path.dirname(project_file) orelse ".";
    for (preferences_names) |name| {
        const candidate = try std.fs.path.join(arena, &.{ dir, name });
        if (isFile(io, candidate)) return candidate;
    }
    return null;
}

fn parseFile(arena: Allocator, io: Io, path: []const u8) IoError!*Table {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch
        return error.ReadFailed;
    // Backing the document's arena with ours means its `deinit` is unnecessary
    // and every string it hands out lives as long as the caller's arena.
    const doc = try parse_mod.parse(arena, src, null);
    return doc.root;
}

/// `base_project(project_file)` (`loading.jl:674-712`): the enclosing
/// workspace root, if this project is listed in one.
///
/// `project_file` need not exist, and need not even be a project file: Julia
/// only ever takes its `dirname` (`loading.jl:676`), and `get_preferences`
/// hands it the raw first load-path entry. That is load-bearing -- see
/// `loadEnvs`.
///
/// Deviation, deliberate and small: Julia's `samefile` compares stat
/// dev+inode; this compares lexically resolved absolute paths. They differ
/// only when a workspace member is reached through a symlink, which no
/// generator produces.
///
/// Arena-allocated.
fn baseProject(arena: Allocator, io: Io, project_file: []const u8, opts: ResolveOptions) IoError!?[]const u8 {
    const project_dir = try std.fs.path.resolve(arena, &.{std.fs.path.dirname(project_file) orelse "."});
    const home: ?[]const u8 = if (opts.home_dir) |h| try std.fs.path.resolve(arena, &.{h}) else null;
    // Julia only applies the boundary if it STARTED inside home
    // (`loading.jl:679`); a project outside home climbs to the filesystem root.
    const started_in_home = if (home) |hd| std.mem.startsWith(u8, project_dir, hd) else false;

    var current: []const u8 = project_dir;
    while (true) {
        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        if (started_in_home and !std.mem.startsWith(u8, parent, home.?)) return null;

        if (try envProjectFile(arena, io, parent)) |base_file| {
            const d = try parseFile(arena, io, base_file);
            if (d.get("workspace")) |wv| {
                if (wv == .table) {
                    if (wv.table.get("projects")) |pv| {
                        if (pv == .array) {
                            const root = std.fs.path.dirname(base_file) orelse ".";
                            for (pv.array) |item| {
                                const rel = switch (item) {
                                    .string => |s| s,
                                    else => continue,
                                };
                                const p = try std.fs.path.resolve(arena, &.{ root, rel });
                                if (isDir(io, p) and std.mem.eql(u8, p, project_dir)) return base_file;
                            }
                        }
                    }
                }
            }
        }
        current = parent;
    }
}

/// Resolve a load path into the `Env` list `getPreferences` expects, including
/// the workspace prefix Julia prepends for the first entry
/// (`loading.jl:3800-3806`).
///
/// Entries go through `expandLoadPathEntry` first, so either a directory or
/// the project file it designates works; `@`-names must already be expanded.
/// An entry that names no project file is skipped, as Julia does
/// (`loading.jl:3810-3813`).
///
/// Two things here are easy to get subtly wrong, and both were:
///
///  1. **The workspace walk starts from the (expanded) first entry itself**,
///     not from a project file that must exist.
///     `get_projects_workspace_to_root` is handed `first(loadpath)` unfiltered
///     (`loading.jl:3805`) and `base_project` only takes its `dirname`. So an
///     entry naming a project file that does not exist yet -- exactly what
///     `julia --project=<new workspace member>` produces -- still picks up the
///     workspace root's preferences. Gating the walk on the entry resolving to
///     an existing project file silently returns 0 in that case.
///  2. **The sidecar is not read when the UUID cannot be named** from an env's
///     project file: `collect_preferences` returns before it looks
///     (`loading.jl:3729-3731`). Reading it anyway turns an unparseable
///     `LocalPreferences.toml` in some unrelated env on the load path into a
///     hard failure where Julia happily returns a hash. Hence the `uuid`
///     parameter.
///
/// Arena-allocated.
pub fn loadEnvs(
    arena: Allocator,
    io: Io,
    load_path: []const []const u8,
    uuid: ?Uuid,
    opts: ResolveOptions,
) IoError![]const Env {
    // Julia builds the entry list first and only calls `env_project_file` on
    // each element inside the merge loop -- which is why the workspace walk
    // below runs on the entry itself, existing project file or not.
    var entries: std.ArrayList([]const u8) = .empty;
    if (load_path.len >= 1) {
        const first = try expandLoadPathEntry(arena, io, load_path[0]);
        try entries.append(arena, first);
        if (opts.walk_workspace) {
            var cur = first;
            while (try baseProject(arena, io, cur, opts)) |up| {
                try entries.append(arena, up);
                cur = up;
            }
        }
    }
    for (load_path[@min(1, load_path.len)..]) |entry| {
        try entries.append(arena, try expandLoadPathEntry(arena, io, entry));
    }

    var envs: std.ArrayList(Env) = .empty;
    for (entries.items) |entry| {
        // `get_preferences` skips entries with no explicit project file
        // (`loading.jl:3810-3813`).
        const f = try envProjectFile(arena, io, entry) orelse continue;
        const project = try parseFile(arena, io, f);

        var local: ?*const Table = null;
        const nameable = if (uuid) |u| (try getUuidName(project, u)) != null else true;
        if (nameable) {
            if (try localPreferencesFile(arena, io, f)) |lp| local = try parseFile(arena, io, lp);
        }
        try envs.append(arena, .{ .project = project, .local = local });
    }
    return envs.items;
}

/// End-to-end `get_preferences_hash` for a load path on disk.
///
/// Arena-allocated: everything read and merged along the way stays on `arena`.
pub fn hashForLoadPath(
    arena: Allocator,
    io: Io,
    load_path: []const []const u8,
    uuid: ?Uuid,
    prefs_list: []const []const u8,
    opts: ResolveOptions,
) IoError!u64 {
    // `uuid === nothing` short-circuits before anything is read
    // (`loading.jl:3822`).
    const u = uuid orelse return 0;
    const envs = try loadEnvs(arena, io, load_path, u, opts);
    const prefs = try getPreferences(arena, envs, u);
    return preferencesHash(prefs, prefs_list);
}

// ===========================================================================

const testing = std.testing;

test "memhashSeed is the SECOND word of MurmurHash3_x64_128" {
    // Ground truth from
    //   ccall(:memhash_seed, UInt64, (Ptr{UInt8}, Csize_t, UInt32), s, n, seed)
    // on Julia 1.12.6. The first word for "abc"/0 is 0xb4963f3f3fad7867 --
    // equally plausible, and wrong.
    try testing.expectEqual(@as(u64, 0x0000000000000000), memhashSeed("", 0));
    try testing.expectEqual(@as(u64, 0x3ba2744126ca2d52), memhashSeed("abc", 0));
    try testing.expectEqual(@as(u64, 0xca12c88bf31b256c), memhashSeed("abc", 1));
    // 16 bytes exercises the block loop, which the short inputs never reach.
    try testing.expectEqual(@as(u64, 0x87c35b5c63a708da), memhashSeed("0123456789abcdef", 0));
}

test "scalar hashes match Julia" {
    // All values from `repr(hash(x, UInt(0)))` on Julia 1.12.6.
    try testing.expectEqual(@as(u64, 0xbd32f78d463d7cfb), hashString("", 0));
    try testing.expectEqual(@as(u64, 0x7690a66f302b3f70), hashString("abc", 0));
    try testing.expectEqual(@as(u64, 0x540c2b5f6ea3f59f), hashString("hello", 12345));
    try testing.expectEqual(@as(u64, 0x5bca7c69b794f8ce), hashI64(1, 0));
    try testing.expectEqual(@as(u64, 0xa7140a8dcea49bc9), hashI64(-3, 0));
    try testing.expectEqual(@as(u64, 0x5bca7c69b794f8ce), hashBool(true, 0));
    try testing.expectEqual(@as(u64, 0x9121e7fcc717d8e9), hashF64(1.5, 0));
    try testing.expectEqual(@as(u64, 0x77cfa1eef01bca90), hashF64(0.0, 0));
    // Trap 2: -0.0 does NOT take the integer path.
    try testing.expectEqual(@as(u64, 0x3be7d0f7780de548), hashF64(-0.0, 0));
    try testing.expect(hashF64(0.0, 0) != hashF64(-0.0, 0));
    // 2^63 leaves the Int64 range and lands on the UInt64 branch.
    try testing.expectEqual(@as(u64, 0x3be7d0f7780de548), hashF64(9223372036854775808.0, 0));
    try testing.expectEqual(@as(u64, 0x807bb202c9cbfc6f), hashF64(std.math.inf(f64), 0));
    try testing.expectEqual(@as(u64, 0x15d7d083d04ecb90), hashF64(std.math.nan(f64), 0));
    // hash(1) == hash(1.0), which is the point of the integral fast path.
    try testing.expectEqual(hashI64(1, 0), hashF64(1.0, 0));
}

test "container hashes match Julia" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // hash(["a","b"], UInt(0)) -- and hash(Any["a","b"], …) is the same value,
    // which is why the parser's eltype narrowing does not matter here.
    const two = try a.alloc(Value, 2);
    two[0] = .{ .string = "a" };
    two[1] = .{ .string = "b" };
    try testing.expectEqual(@as(u64, 0xe155e15987806d5c), try hashArray(two, 0));

    // hash(String[], UInt(0)) -- the axes tuples still contribute.
    const empty: []Value = &.{};
    try testing.expectEqual(@as(u64, 0xa2e6e5b3d2eee6b5), try hashArray(empty, 0));

    // hash(Dict{String,Any}(), UInt(0))
    const t0 = try Table.create(a);
    try testing.expectEqual(@as(u64, 0x172af099a2a3a421), try hashTable(t0, 0));

    // hash(Dict{String,Any}("a"=>1,"b"=>"x"), UInt(0))
    const t1 = try Table.create(a);
    try t1.put(a, "a", .{ .integer = 1 });
    try t1.put(a, "b", .{ .string = "x" });
    try testing.expectEqual(@as(u64, 0xbe3cff90a20d3bbc), try hashTable(t1, 0));

    // XOR fold => insertion order cannot matter.
    const t2 = try Table.create(a);
    try t2.put(a, "b", .{ .string = "x" });
    try t2.put(a, "a", .{ .integer = 1 });
    try testing.expectEqual(try hashTable(t1, 0), try hashTable(t2, 0));

    // hash(Dict{String,Any}("o"=>Dict{String,Any}("i"=>[1,2,3])), UInt(0))
    const inner_items = try a.alloc(Value, 3);
    inner_items[0] = .{ .integer = 1 };
    inner_items[1] = .{ .integer = 2 };
    inner_items[2] = .{ .integer = 3 };
    const inner = try Table.create(a);
    try inner.put(a, "i", .{ .array = inner_items });
    const outer = try Table.create(a);
    try outer.put(a, "o", .{ .table = inner });
    try testing.expectEqual(@as(u64, 0x9175f4a43ddd6176), try hashTable(outer, 0));
}

/// The fixture used by tools/diff_harness/preferences.sh case (d).
const fixture_project =
    \\name = "App"
    \\uuid = "11111111-1111-1111-1111-111111111111"
    \\
    \\[deps]
    \\Foo = "22222222-2222-2222-2222-222222222222"
    \\
    \\[preferences.Foo]
    \\a = 1
    \\b = "from-project"
    \\nest = { x = 1, y = 2 }
    \\
;

const fixture_local =
    \\[Foo]
    \\b = "from-local"
    \\c = true
    \\nest = { y = 99 }
    \\
;

fn envFromSources(arena: Allocator, project_src: []const u8, local_src: ?[]const u8) !Env {
    const pd = try parse_mod.parse(arena, project_src, null);
    var env: Env = .{ .project = pd.root };
    if (local_src) |s| {
        const ld = try parse_mod.parse(arena, s, null);
        env.local = ld.root;
    }
    return env;
}

test "LocalPreferences overrides Project.toml and nested tables merge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try envFromSources(a, fixture_project, fixture_local);
    const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");
    const prefs = try getPreferences(a, &.{env}, uuid);

    // Julia: Dict("c"=>true, "b"=>"from-local", "a"=>1, "nest"=>Dict("x"=>1,"y"=>99))
    try testing.expectEqual(@as(i64, 1), prefs.get("a").?.integer);
    try testing.expectEqualStrings("from-local", prefs.get("b").?.string);
    try testing.expectEqual(true, prefs.get("c").?.boolean);
    const nest = prefs.get("nest").?.table;
    try testing.expectEqual(@as(i64, 1), nest.get("x").?.integer);
    try testing.expectEqual(@as(i64, 99), nest.get("y").?.integer);

    // Values from `Base.get_preferences_hash(uuid, [...])` with
    // JULIA_LOAD_PATH pointed at this fixture.
    try testing.expectEqual(@as(u64, 0x5bca7c69b794f8ce), try preferencesHash(prefs, &.{"a"}));
    try testing.expectEqual(@as(u64, 0x92124f0fb125a65f), try preferencesHash(prefs, &.{"b"}));
    try testing.expectEqual(
        @as(u64, 0xdb84e8af55a2accd),
        try preferencesHash(prefs, &.{ "a", "b", "c", "nest" }),
    );
    // Order is load-bearing.
    try testing.expectEqual(@as(u64, 0x4897cc4aaa146982), try preferencesHash(prefs, &.{ "nest", "a" }));
    // Absent names are skipped, so they leave h at 0.
    try testing.expectEqual(@as(u64, 0), try preferencesHash(prefs, &.{"zzz"}));
    // uuid === nothing short-circuits.
    try testing.expectEqual(@as(u64, 0), try preferencesHash(null, &.{"a"}));
}

test "a UUID that is not nameable from the project contributes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try envFromSources(a, fixture_project, fixture_local);
    const stranger = try Uuid.parse("33333333-3333-3333-3333-333333333333");
    const dicts = try collect(a, env, stranger);
    try testing.expectEqual(@as(usize, 0), dicts.len);

    const prefs = try getPreferences(a, &.{env}, stranger);
    try testing.expectEqual(@as(usize, 0), prefs.count());
    try testing.expectEqual(@as(u64, 0), try preferencesHash(prefs, &.{ "a", "b" }));
}

test "no preferences anywhere is the cheap default hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try envFromSources(a,
        \\name = "App"
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[deps]
        \\Foo = "22222222-2222-2222-2222-222222222222"
        \\
    , null);
    const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");
    const prefs = try getPreferences(a, &.{env}, uuid);
    try testing.expectEqual(@as(usize, 0), prefs.count());
    try testing.expectEqual(@as(u64, 0), try preferencesHash(prefs, &.{ "a", "b", "c" }));
}

test "__clear__ deletes keys before the rest of its own override lands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try envFromSources(a, fixture_project,
        \\[Foo]
        \\__clear__ = ["a", "nest"]
        \\b = "cleared-then-set"
        \\
    );
    const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");
    const prefs = try getPreferences(a, &.{env}, uuid);

    try testing.expect(prefs.get("a") == null);
    try testing.expect(prefs.get("nest") == null);
    try testing.expectEqualStrings("cleared-then-set", prefs.get("b").?.string);
    // `__clear__` itself survives the merge -- the copy loop does not skip it.
    try testing.expect(prefs.get("__clear__") != null);
}

test "__clear__ is ignored unless it is a Vector{String}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "[Foo]\n__clear__ = \"a\"\n",
        "[Foo]\n__clear__ = []\n",
        "[Foo]\n__clear__ = [1, 2]\n",
        "[Foo]\n__clear__ = [\"a\", 1]\n",
    }) |local_src| {
        const env = try envFromSources(a, fixture_project, local_src);
        const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");
        const prefs = try getPreferences(a, &.{env}, uuid);
        try testing.expectEqual(@as(i64, 1), prefs.get("a").?.integer);
    }
}

test "later load-path entries lose to earlier ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const active = try envFromSources(a,
        \\name = "App"
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[deps]
        \\Foo = "22222222-2222-2222-2222-222222222222"
        \\
        \\[preferences.Foo]
        \\k = "active"
        \\
    , null);
    const shared = try envFromSources(a,
        \\[deps]
        \\Foo = "22222222-2222-2222-2222-222222222222"
        \\
        \\[preferences.Foo]
        \\k = "shared"
        \\only_shared = 7
        \\
    , null);
    const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");

    const prefs = try getPreferences(a, &.{ active, shared }, uuid);
    try testing.expectEqualStrings("active", prefs.get("k").?.string);
    try testing.expectEqual(@as(i64, 7), prefs.get("only_shared").?.integer);
}

test "getUuidName finds the project itself, its deps, extras and weakdeps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parse_mod.parse(a,
        \\name = "App"
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[deps]
        \\Foo = "22222222-2222-2222-2222-222222222222"
        \\
        \\[extras]
        \\Bar = "33333333-3333-3333-3333-333333333333"
        \\
        \\[weakdeps]
        \\Baz = "44444444-4444-4444-4444-444444444444"
        \\
    , null);
    const p = doc.root;

    try testing.expectEqualStrings("App", (try getUuidName(p, try Uuid.parse("11111111-1111-1111-1111-111111111111"))).?);
    try testing.expectEqualStrings("Foo", (try getUuidName(p, try Uuid.parse("22222222-2222-2222-2222-222222222222"))).?);
    try testing.expectEqualStrings("Bar", (try getUuidName(p, try Uuid.parse("33333333-3333-3333-3333-333333333333"))).?);
    try testing.expectEqualStrings("Baz", (try getUuidName(p, try Uuid.parse("44444444-4444-4444-4444-444444444444"))).?);
    try testing.expect((try getUuidName(p, try Uuid.parse("55555555-5555-5555-5555-555555555555"))) == null);
}

test "hashInput exposes the fold, including skipped names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try envFromSources(a, fixture_project, fixture_local);
    const uuid = try Uuid.parse("22222222-2222-2222-2222-222222222222");
    const prefs = try getPreferences(a, &.{env}, uuid);

    const text = try hashInput(testing.allocator, prefs, &.{ "a", "zzz", "nest" });
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "a = 1  -> h = 0x5bca7c69b794f8ce\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zzz = <absent, skipped>\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "nest = {x = 1, y = 99}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "prefs_hash = 0x") != null);
}

test "datetimes and huge arrays are refused, not guessed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(
        error.UnsupportedPreferenceValue,
        hashValue(.{ .datetime = .{ .kind = .date, .year = 1979, .month = 5, .day = 27 } }, 0),
    );
    const big = try a.alloc(Value, 8192);
    for (big) |*v| v.* = .{ .integer = 0 };
    try testing.expectError(error.ArrayTooLongToHash, hashArray(big, 0));
}
