//! The recursive derivation key for the shared precompile cache.
//!
//! ```
//! key(P) = blake3("ajt-v1", sha256(sysimage bytes), uuid(P), tree_hash(P),
//!                 cacheflags, cpu_target, prefs_hash(P),
//!                 sorted[ key(D) for D in non-sysimage direct deps ])
//! ```
//!
//! **Why the recursion is load-bearing.** `stale_cachefile` re-checks every
//! `required_modules[i]`'s build_id before it will accept a `.ji`
//! (`base/loading.jl:4046-4079`): one differing dependency build rejects the
//! cache file, and since that dependency's own cache was rejected for the same
//! reason one level down, a single differing leaf poisons the whole subtree. A
//! recursive key makes that failure impossible to reach by construction — a
//! store hit for `P` *implies* hits for its entire closure, so the scheduler
//! can plan `Ready(P)` from the manifest alone, before fetching anything. A
//! flat key would let Ajt download an object whose dependencies then turn out
//! to be wrong, and only discover it at load time, after paying for the
//! download.
//!
//! **This is not Julia's cache slug.** `compilecache_path`
//! (`base/loading.jl:3152-3172`) chains crc32c over the active project **path
//! string**, `JLOptions().image_file`, `JLOptions().julia_bin`, the cache-flags
//! byte, `cpu_target` and `prefs_hash`. That is a local-disambiguation slug,
//! not a sharing key: it says nothing about source content or about dependency
//! builds, and two machines that installed Julia at different paths never agree
//! on it even for byte-identical work. The slug is still needed — it is the
//! name an imported object must be *written under* — but it is computed from
//! the LOCAL `JLOptions()` at import time and lives in its own module. Nothing
//! path-derived may enter this key.
//!
//! ## Field order — documented once, never reordered
//!
//! `"ajt-v1"` is the domain separator and the version tag in one. **Any change
//! to what goes into the hash, or to the order it goes in, is a new tag.**
//! Silently changing the key means every machine's cache misses at once, every
//! CI job recompiles, and nothing anywhere reports an error — the store simply
//! stops having what anyone asks for. A version bump at least makes the miss
//! explicable.
//!
//! ```text
//! offset  size  field
//!      0     6  "ajt-v1"                      domain separator / version tag
//!      6     1  0x00                          NUL, so the tag can never run into the digest
//!      7    32  sha256(sysimage bytes)        the sysimage IS the stdlib closure
//!     39    16  uuid(P)                       canonical (wire) order, as written in TOML
//!     55     1  content tag                   0 = registered tree, 1 = local path entry
//!     56    20  tree_hash(P)                  raw git tree hash
//!     76        [content tag 1 only] u32 LE path length, then the path bytes
//!             1  cacheflags                   `_cacheflag_to_uint8(CacheFlags())`, loading.jl:1725
//!             4  u32 LE cpu_target length
//!                cpu_target bytes             `JULIA_CPU_TARGET` or `JLOptions().cpu_target`
//!             8  prefs_hash, LITTLE-endian
//!             4  u32 LE dependency count
//!            32  each dependency key, ascending by raw bytes
//! ```
//!
//! Three properties that the layout exists to guarantee:
//!
//!  1. **Injective.** Every variable-length field carries an explicit length,
//!     so no two distinct inputs share a preimage. Concatenating
//!     `cpu_target` and a local `path` without lengths would let
//!     `("a", "bc")` and `("ab", "c")` collide, and a collision here is a
//!     *wrong cache hit* — the one failure mode this design otherwise cannot
//!     produce.
//!  2. **Endian-independent.** Every integer is written little-endian
//!     explicitly, never as native bytes. Julia's own slug gets this wrong in
//!     the opposite direction — `_crc32c(::UUID)` hashes the UInt128 in
//!     *native* order (`base/util.jl:532`, see `julia/slug.zig`) — and a key
//!     that is not portable across architectures is not a sharing key.
//!  3. **Path-free** for the `tree` variant. Nothing derived from where Julia
//!     or the project is installed appears, which is exactly what
//!     `compilecache_path` cannot say.
//!
//! ## What is excluded, and why
//!
//! * **Sysimage packages contribute no dep key.** Their code is *in* the
//!   sysimage, whose sha256 is already field 3, so recursing into them would
//!   add nothing and would require inventing a tree hash for a package that
//!   has none. The predicate is `stdlibs.Set.isStdlib`, **not**
//!   `isOrWasStdlib`: `DelimitedFiles` and `Statistics` ship in the stdlib
//!   directory but `load_stdlib` skips them (`Pkg/src/Types.jl:501, 514-517`),
//!   so they are resolved from the registry, are NOT in the sysimage, and must
//!   be keyed like any other package. Folding them in with the stdlibs would
//!   make two different installed versions of `Statistics` share a key.
//!
//! * **Weak dependencies contribute nothing.** A package's own `.ji` records
//!   only the modules it actually required; a weakdep is not loaded for the
//!   base module, so it cannot appear in `required_modules` and cannot make
//!   the base cache stale. An extension's cache file is a *separate* object
//!   and needs its own key — `key(ext) = f(key(P), sorted[key(trigger)])` —
//!   which is deliberately not implemented here.
//!
//! * **The julia binary path and the active project path** — see above. They
//!   belong to the slug, not the key.
//!
//! ## Path entries have no key unless the caller supplies one
//!
//! A manifest entry with `path = "."` — the environment's own package, and
//! every `develop`ed dependency — has no `git-tree-sha1`, so there is nothing
//! content-addressed to key on. Such an entry comes back **unkeyed**, and so
//! does anything that transitively depends on it: a package compiled against a
//! directory somebody may be editing is no more shareable than the directory.
//! `Keys.unkeyed` lists them, so "the cache is doing nothing here" is a
//! reportable fact rather than an inference.
//!
//! Unkeyed is deliberately not an ERROR, and this module used to get that
//! wrong. `error.NotContentAddressed` made a whole environment unkeyable
//! because one entry was a checkout — which is the shape of every package
//! project — and the only way to satisfy it was to tree-hash the working
//! directory on every run. That is not a small cost on a real checkout:
//! `Open-Reality/` is 7.4 GB, 6.9 GB of it Rust build output, and hashing it
//! took longer than the compile it was meant to avoid. Worse, it bought
//! nothing, because a `Local` key embeds the absolute path and can never be a
//! hit on another machine.
//!
//! A caller that genuinely CAN address a checkout still may, by passing
//! `Local` — a tree hash over the directory (`julia/treehash.zig`) plus the
//! absolute source path. That is the container case and it is a real one:
//! source mounted at a fixed `/engine` is the same content everywhere that
//! mounts it. The path is IN the key because such a cache is frequently **not
//! relocatable** — `OpenReality`'s `.ji` carries 231 absolute paths and zero
//! `@depot` tags, because `src/OpenReality.jl:364` includes a file above the
//! package root — so keying it without the path would offer a container-built
//! cache to a dev box that cannot load it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;

const slug = @import("../julia/slug.zig");
const stdlibs_mod = @import("../julia/stdlibs.zig");
const preferences = @import("../julia/preferences.zig");
const manifest_mod = @import("../model/manifest.zig");
const Table = @import("../toml/value.zig").Table;

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;

/// Domain separator AND version tag. Bump on ANY change to the preimage.
pub const domain = "ajt-v1";

/// A derivation key: the 32-byte BLAKE3 digest of the preimage above.
pub const Key = [Blake3.digest_length]u8;

/// Byte offsets of the fixed-size prefix, exposed so the differential harness
/// can assert the documented field ORDER directly rather than inferring it
/// from a digest that changed.
pub const offset = struct {
    pub const tag = 0;
    pub const nul = domain.len;
    pub const sysimage = domain.len + 1;
    pub const uuid = sysimage + 32;
    pub const content_tag = uuid + 16;
    pub const tree_hash = content_tag + 1;
    /// End of the fixed prefix; what follows depends on the content tag.
    pub const after_tree_hash = tree_hash + 20;
};

pub const EncodeError = error{
    /// A cpu_target or path longer than 4 GiB. Impossible in practice; refused
    /// rather than truncated, because a truncated length prefix is exactly the
    /// ambiguity the prefixes exist to prevent.
    InputTooLarge,
} || Allocator.Error;

pub const Error = error{
    /// A strong dependency's UUID is in no manifest entry and is not a
    /// sysimage package, so its key cannot be derived. `model/manifest.zig`
    /// rejects this at parse time; reaching it here means the manifest was
    /// built programmatically.
    UnknownDependency,
    /// The dependency graph has a cycle, so no key is well-founded. Julia's
    /// package graph is acyclic and `Pkg.why` treats a cycle as a hand-edit
    /// (`API.jl:1585-1591`); a key that recursed through one would not
    /// terminate.
    DependencyCycle,
    /// Two manifest entries share a UUID, so one `PkgId` would get two keys.
    ///
    /// Pkg cannot represent this — its manifest is a `Dict{UUID,PackageEntry}`
    /// — but `model/manifest.zig` deliberately preserves both entries rather
    /// than collapsing them, and `validateGraph` does not reject it. Keying
    /// both is the worst option available: dependents fold in whichever entry
    /// the index happened to keep, while the store receives two objects for one
    /// `PkgId`, so a scheduler can fetch the object the closure was NOT keyed
    /// against. That is a stale hit — the single failure this design otherwise
    /// rules out — so it is refused instead. Found by review, not by a test.
    DuplicateUuid,
    /// A `Local` was supplied for an entry that already carries a
    /// `git-tree-sha1`. The two are mutually exclusive in any manifest Julia
    /// would accept (`Types.jl:314`, mirrored as `manifest.Error.TreeHashAndPath`),
    /// so this is always a caller mistake — and a silent one, since it would
    /// swap a portable content key for a machine-specific path-tainted one.
    LocalForRegisteredPackage,
} || EncodeError;

/// The inputs that are the same for every package in one environment.
pub const Params = struct {
    /// SHA-256 over the **bytes of the sysimage file** (`JLOptions().image_file`).
    /// Not its path: two machines with the same Julia build must agree.
    sysimage: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    /// `_cacheflag_to_uint8(CacheFlags())` — pkgimages, debug level, bounds
    /// checking, inlining, opt level packed into one byte
    /// (`base/loading.jl:1725-1735`). Julia hashes exactly this byte into its
    /// own slug (`:3162`), and `stale_cachefile` rejects a mismatch outright
    /// (`:3993-3997`).
    cacheflags: u8,
    /// `JULIA_CPU_TARGET` when set, else `JLOptions().cpu_target`
    /// (`base/loading.jl:3164-3168`). The string, verbatim.
    cpu_target: []const u8,
};

/// A path/dev manifest entry's stand-in for a registry tree hash.
pub const Local = struct {
    /// `julia/treehash.zig` over the working directory. Content addressing is
    /// still content addressing when the content is on disk.
    tree: Sha1,
    /// The absolute, canonical source path. Deliberately machine-specific —
    /// see the header on relocatability.
    path: []const u8,
};

/// How a package's content is addressed. The tag byte is in the preimage, so a
/// registered package and a local one can never collide even with equal trees.
pub const Content = union(enum) {
    /// The registry's `git-tree-sha1`. The normal case.
    tree: Sha1,
    local: Local,

    fn tagByte(self: Content) u8 {
        return switch (self) {
            .tree => 0,
            .local => 1,
        };
    }
};

fn keyLess(_: void, a: Key, b: Key) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn writeLen(w: *std.Io.Writer, n: usize) EncodeError!void {
    const v = std.math.cast(u32, n) orelse return error.InputTooLarge;
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    w.writeAll(&buf) catch return error.OutOfMemory;
}

/// Builds the exact bytes that get digested, caller-owned.
///
/// Exposed separately from `compute` for the same reason
/// `project_hash.digestString` is: a byte diff is debuggable and a digest diff
/// is not. `dep_keys` is sorted internally, so callers cannot get the order
/// wrong; the slice itself is not mutated.
pub fn encode(
    gpa: Allocator,
    params: Params,
    uuid: Uuid,
    content: Content,
    prefs_hash: u64,
    dep_keys: []const Key,
) EncodeError![]u8 {
    const sorted = try gpa.dupe(Key, dep_keys);
    defer gpa.free(sorted);
    std.mem.sort(Key, sorted, {}, keyLess);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    w.writeAll(domain) catch return error.OutOfMemory;
    w.writeByte(0) catch return error.OutOfMemory;
    w.writeAll(&params.sysimage) catch return error.OutOfMemory;
    w.writeAll(&uuid.bytes) catch return error.OutOfMemory;

    w.writeByte(content.tagByte()) catch return error.OutOfMemory;
    switch (content) {
        .tree => |t| w.writeAll(&t.bytes) catch return error.OutOfMemory,
        .local => |l| {
            w.writeAll(&l.tree.bytes) catch return error.OutOfMemory;
            try writeLen(w, l.path.len);
            w.writeAll(l.path) catch return error.OutOfMemory;
        },
    }

    w.writeByte(params.cacheflags) catch return error.OutOfMemory;
    try writeLen(w, params.cpu_target.len);
    w.writeAll(params.cpu_target) catch return error.OutOfMemory;

    var prefs_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &prefs_buf, prefs_hash, .little);
    w.writeAll(&prefs_buf) catch return error.OutOfMemory;

    try writeLen(w, sorted.len);
    for (sorted) |k| w.writeAll(&k) catch return error.OutOfMemory;

    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

/// BLAKE3 of `encode`. `gpa` is only used for the transient preimage.
pub fn compute(
    gpa: Allocator,
    params: Params,
    uuid: Uuid,
    content: Content,
    prefs_hash: u64,
    dep_keys: []const Key,
) EncodeError!Key {
    const pre = try encode(gpa, params, uuid, content, prefs_hash, dep_keys);
    defer gpa.free(pre);
    var out: Key = undefined;
    Blake3.hash(pre, &out, .{});
    return out;
}

pub fn toHex(k: Key) [2 * Blake3.digest_length]u8 {
    var out: [2 * Blake3.digest_length]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&k}) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------
// The recursive driver, over a whole manifest.

/// A per-package preference hash. Absent means 0, which is also what Julia
/// produces for a package with no preferences (`get_preferences_hash` starts
/// at `UInt(0)` and every lookup misses, `base/loading.jl:3819-3837`).
pub const PrefsHash = struct {
    uuid: Uuid,
    hash: u64,
};

/// Content for a manifest entry that carries `path` instead of
/// `git-tree-sha1`.
pub const LocalEntry = struct {
    uuid: Uuid,
    content: Local,
};

pub const Options = struct {
    params: Params,
    /// The installation's stdlibs. `null` means "no package is in the
    /// sysimage", which is only ever right for a synthetic manifest — a real
    /// environment without this would try to key ~43 versionless entries and
    /// fail with `NotContentAddressed`.
    stdlibs: ?*const stdlibs_mod.Set = null,
    prefs: []const PrefsHash = &.{},
    local: []const LocalEntry = &.{},
};

pub const Entry = struct {
    name: []const u8,
    uuid: Uuid,
    key: Key,
};

/// Every keyed package of one manifest. Sysimage packages are absent: they
/// have no cache object of their own to share.
pub const Keys = struct {
    /// Manifest order, minus the sysimage entries. Manifest order is the file's
    /// own (`model/manifest.zig` preserves it), so this is deterministic.
    entries: []const Entry,
    /// Sysimage entries that were skipped, in manifest order. Reported rather
    /// than dropped silently, so a caller can tell "in the sysimage" from
    /// "absent from the environment".
    skipped: []const Uuid,
    /// Entries with no derivation key, in manifest order: an unaddressable
    /// checkout, or anything that (transitively) depends on one. See
    /// `Walk.resolve`.
    ///
    /// A SEPARATE list from `skipped`, because the two mean opposite things to
    /// a caller. A sysimage entry has no cache object of its own and never
    /// will; an unkeyed one has a perfectly real cache entry that simply
    /// cannot be shared. Folding them together would make "the cache is doing
    /// nothing on this environment" indistinguishable from "there is nothing
    /// here to cache", which is exactly the diagnosis someone will need.
    unkeyed: []const Uuid = &.{},

    pub fn get(self: *const Keys, uuid: Uuid) ?Key {
        for (self.entries) |e| {
            if (std.mem.eql(u8, &e.uuid.bytes, &uuid.bytes)) return e.key;
        }
        return null;
    }

    pub fn getByName(self: *const Keys, name: []const u8) ?Key {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.key;
        }
        return null;
    }
};

const State = enum { unvisited, in_progress, done };

const Walk = struct {
    arena: Allocator,
    manifest: *const manifest_mod.Manifest,
    opts: Options,
    index: std.AutoHashMapUnmanaged([16]u8, usize),
    state: []State,
    keys: []?Key,

    fn isSysimage(self: *const Walk, uuid: Uuid) bool {
        const set = self.opts.stdlibs orelse return false;
        // `isStdlib`, NOT `isOrWasStdlib` — see the header. The upgradable
        // pair is resolved from the registry and is not in the sysimage.
        return set.isStdlib(uuid);
    }

    fn prefsHash(self: *const Walk, uuid: Uuid) u64 {
        for (self.opts.prefs) |p| {
            if (std.mem.eql(u8, &p.uuid.bytes, &uuid.bytes)) return p.hash;
        }
        return 0;
    }

    /// How this entry is addressed, or null when it cannot be.
    ///
    /// Null is not an error. A manifest entry with `path` and no `Local` from
    /// the caller is a working COPY — a directory somebody may be editing right
    /// now — and it has no identity any other machine could reproduce. Saying
    /// so is the honest answer; the alternative this function used to give,
    /// `error.NotContentAddressed`, made the whole environment unkeyable
    /// because one entry was a checkout, which is the normal shape of every
    /// package project (`path = "."` self-entry) and of every `develop`.
    ///
    /// A caller that CAN address one still may, by passing `local`: source
    /// mounted at a fixed absolute path inside a container is genuinely the
    /// same content on every machine that mounts it. That is opt-in because
    /// building the address means tree-hashing the directory, and a working
    /// checkout is routinely enormous — 7.4 GB for the engine, almost all of
    /// it Rust build output — so it must never be on the default path.
    fn contentOf(self: *const Walk, entry: *const manifest_mod.PackageEntry) Error!?Content {
        const local: ?Local = for (self.opts.local) |l| {
            if (std.mem.eql(u8, &l.uuid.bytes, &entry.uuid.bytes)) break l.content;
        } else null;

        // `git-tree-sha1` WINS, and a `Local` alongside it is refused rather
        // than allowed to override: silently preferring the caller's Local
        // would turn a portable, registry-content key into a path-tainted one
        // that no other machine can reproduce. Still an ERROR, because unlike
        // an unaddressable checkout this one is a caller bug.
        if (entry.tree_hash) |th| {
            if (local != null) return error.LocalForRegisteredPackage;
            return .{ .tree = th };
        }
        return .{ .local = local orelse return null };
    }

    /// Depth-first, memoised. Recursion depth is bounded by the longest chain
    /// in the dependency graph (tens, on a 214-entry environment).
    ///
    /// **Null propagates up the graph, and that is the point.** A package that
    /// depends on an unaddressable one was compiled against source that exists
    /// on one machine, so its own cache entry is no more shareable than the
    /// checkout underneath it. Stopping the null at the path entry would mint
    /// keys for its dependents that two machines could agree on while their
    /// contents differed — the one failure this whole scheme exists to make
    /// impossible.
    fn resolve(self: *Walk, idx: usize) Error!?Key {
        switch (self.state[idx]) {
            .done => return self.keys[idx],
            .in_progress => return error.DependencyCycle,
            .unvisited => {},
        }
        self.state[idx] = .in_progress;

        const entry = &self.manifest.entries[idx];

        var dep_keys: std.ArrayList(Key) = .empty;
        var addressable = true;
        for (entry.deps) |d| {
            if (self.isSysimage(d.uuid)) continue;
            const di = self.index.get(d.uuid.bytes) orelse return error.UnknownDependency;
            // Every dependency is still VISITED even once one has come back
            // null: the walk is what detects cycles, and skipping the rest
            // would make cycle detection depend on which entry happened to be
            // a checkout.
            const dk = try self.resolve(di);
            if (dk) |k| try dep_keys.append(self.arena, k) else addressable = false;
        }

        const content = try self.contentOf(entry);
        if (content == null or !addressable) {
            self.keys[idx] = null;
            self.state[idx] = .done;
            return null;
        }

        const key = try compute(
            self.arena,
            self.opts.params,
            entry.uuid,
            content.?,
            self.prefsHash(entry.uuid),
            dep_keys.items,
        );
        self.keys[idx] = key;
        self.state[idx] = .done;
        return key;
    }
};

/// Derivation keys for every non-sysimage entry of `manifest`.
///
/// **Takes an arena.** The returned `Keys` is entirely arena-owned — the entry
/// slice AND the names, which are copied out of the manifest rather than
/// borrowed — so it outlives the manifest and its source text. The walk's own
/// scratch (the index map, the per-node state, every transient preimage) comes
/// from the same arena and is never freed individually. Passing a
/// general-purpose allocator here leaks by design.
///
/// Recursion depth is bounded by `manifest.entries.len`, since every node is
/// marked `.in_progress` before its children are visited and a repeat visit is
/// `error.DependencyCycle`.
pub fn computeManifest(
    arena: Allocator,
    manifest: *const manifest_mod.Manifest,
    opts: Options,
) Error!Keys {
    var walk: Walk = .{
        .arena = arena,
        .manifest = manifest,
        .opts = opts,
        .index = .empty,
        .state = try arena.alloc(State, manifest.entries.len),
        .keys = try arena.alloc(?Key, manifest.entries.len),
    };
    @memset(walk.state, .unvisited);

    // A UUID must identify exactly one entry: it is the whole of a `PkgId`'s
    // identity here, and two entries under one UUID would be keyed separately
    // while their dependents folded in only one of them. See `DuplicateUuid`.
    for (manifest.entries, 0..) |e, i| {
        const gop = try walk.index.getOrPut(arena, e.uuid.bytes);
        if (gop.found_existing) return error.DuplicateUuid;
        gop.value_ptr.* = i;
    }

    var out: std.ArrayList(Entry) = .empty;
    var skipped: std.ArrayList(Uuid) = .empty;
    var unkeyed: std.ArrayList(Uuid) = .empty;
    for (manifest.entries, 0..) |e, i| {
        if (walk.isSysimage(e.uuid)) {
            try skipped.append(arena, e.uuid);
            continue;
        }
        const key = try walk.resolve(i) orelse {
            try unkeyed.append(arena, e.uuid);
            continue;
        };
        // The name is COPIED. `PackageEntry.name` borrows from the manifest's
        // source text, so returning it directly would make `Keys` outlive-safe
        // only while that buffer is also alive — a caller who parses from a
        // scratch buffer and keeps the arena would read freed memory.
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .uuid = e.uuid, .key = key });
    }

    return .{
        .entries = try out.toOwnedSlice(arena),
        .skipped = try skipped.toOwnedSlice(arena),
        .unkeyed = try unkeyed.toOwnedSlice(arena),
    };
}

// ---------------------------------------------------------------------------

/// The `prefs_hash` Ajt keys on: `get_preferences_hash` with `prefs_list` set
/// to **every** top-level key of the merged preference table, sorted.
///
/// Julia's own `prefs_hash` is over the `prefs_list` recorded *inside* the
/// `.ji` (`base/loading.jl:3245` reads it back out of the file that was just
/// written, and `:4146-4147` re-derives it at load time), i.e. the set of
/// preferences the package actually read while compiling. Julia says so itself
/// in the comment right above that read (`:3244`): "we don't actually know what
/// the list of compile-time preferences are without compiling". Ajt has to key
/// *before* compiling, when that list does not exist yet. Hashing every key
/// instead is deliberately CONSERVATIVE: it can only over-invalidate — a
/// preference the package never reads changes the key and costs one recompile
/// — and over-invalidation is the safe direction. Under-invalidating would
/// hand out a `.ji` whose `prefs_hash` Julia then rejects at load, which is a
/// silent full recompile plus a wasted download.
///
/// `prefs` may be null (no preferences at all), which is 0 — the same value
/// Julia's `uuid === nothing` short-circuit produces (`:3823`).
pub fn conservativePrefsHash(gpa: Allocator, prefs: ?*const Table) (preferences.HashError || Allocator.Error)!u64 {
    const t = prefs orelse return 0;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (t.entries.items) |e| try names.append(gpa, e.key);
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    return preferences.preferencesHash(t, names.items);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const parseToml = @import("../toml/parse.zig").parse;

const test_params: Params = .{
    .sysimage = [_]u8{0xAB} ** 32,
    .cacheflags = 0x0b,
    .cpu_target = "native",
};

fn uuidOf(comptime last: u8) Uuid {
    var u: Uuid = .{ .bytes = [_]u8{0} ** 16 };
    u.bytes[15] = last;
    return u;
}

fn sha1Of(comptime b: u8) Sha1 {
    return .{ .bytes = [_]u8{b} ** 20 };
}

test "preimage is exactly the documented layout" {
    const pre = try encode(
        testing.allocator,
        test_params,
        uuidOf(0x07),
        .{ .tree = sha1Of(0x11) },
        0x0102030405060708,
        &.{},
    );
    defer testing.allocator.free(pre);

    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(testing.allocator);
    try expect.appendSlice(testing.allocator, "ajt-v1");
    try expect.append(testing.allocator, 0);
    try expect.appendSlice(testing.allocator, &([_]u8{0xAB} ** 32));
    try expect.appendSlice(testing.allocator, &uuidOf(0x07).bytes);
    try expect.append(testing.allocator, 0); // content tag: registered tree
    try expect.appendSlice(testing.allocator, &([_]u8{0x11} ** 20));
    try expect.append(testing.allocator, 0x0b); // cacheflags
    try expect.appendSlice(testing.allocator, &[_]u8{ 6, 0, 0, 0 }); // len("native")
    try expect.appendSlice(testing.allocator, "native");
    // prefs_hash, LITTLE-endian.
    try expect.appendSlice(testing.allocator, &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 });
    try expect.appendSlice(testing.allocator, &[_]u8{ 0, 0, 0, 0 }); // no deps

    try testing.expectEqualSlices(u8, expect.items, pre);

    // And the offsets the harness probes agree with it.
    try testing.expectEqualStrings(domain, pre[offset.tag..][0..domain.len]);
    try testing.expectEqual(@as(u8, 0), pre[offset.nul]);
    try testing.expectEqualSlices(u8, &test_params.sysimage, pre[offset.sysimage..][0..32]);
    try testing.expectEqualSlices(u8, &uuidOf(0x07).bytes, pre[offset.uuid..][0..16]);
    try testing.expectEqual(@as(u8, 0), pre[offset.content_tag]);
    try testing.expectEqualSlices(u8, &sha1Of(0x11).bytes, pre[offset.tree_hash..][0..20]);
    try testing.expectEqual(@as(usize, 76), offset.after_tree_hash);
}

test "a local entry carries a length-prefixed path and its own content tag" {
    const pre = try encode(
        testing.allocator,
        test_params,
        uuidOf(0x07),
        .{ .local = .{ .tree = sha1Of(0x11), .path = "/engine" } },
        0,
        &.{},
    );
    defer testing.allocator.free(pre);

    try testing.expectEqual(@as(u8, 1), pre[offset.content_tag]);
    try testing.expectEqualSlices(u8, &sha1Of(0x11).bytes, pre[offset.tree_hash..][0..20]);
    try testing.expectEqualSlices(u8, &[_]u8{ 7, 0, 0, 0 }, pre[offset.after_tree_hash..][0..4]);
    try testing.expectEqualStrings("/engine", pre[offset.after_tree_hash + 4 ..][0..7]);

    // Same tree hash, different variant: the tag byte must keep them apart.
    const other = try compute(testing.allocator, test_params, uuidOf(0x07), .{ .tree = sha1Of(0x11) }, 0, &.{});
    var here: Key = undefined;
    Blake3.hash(pre, &here, .{});
    try testing.expect(!std.mem.eql(u8, &other, &here));
}

test "length prefixes make the encoding injective across adjacent strings" {
    // Constructed so that DELETING the two length prefixes makes these two
    // preimages byte-identical, rather than merely different-looking. Strip
    // them and the layout between the tree hash and prefs_hash becomes
    // `path ++ cacheflags ++ cpu_target`, so with cacheflags = 98 = 'b':
    //
    //     "a"  ++ 'b' ++ "bc"  ==  61 62 62 63  ==  "ab" ++ 'b' ++ "c"
    //
    // A preimage collision is a WRONG CACHE HIT, not a miss — the one failure
    // this design otherwise cannot produce. Pick the cacheflags byte carelessly
    // and this test passes against an encoder with no length prefixes at all.
    var p1 = test_params;
    p1.cacheflags = 'b';
    p1.cpu_target = "bc";
    var p2 = p1;
    p2.cpu_target = "c";
    const k1 = try compute(testing.allocator, p1, uuidOf(1), .{ .local = .{ .tree = sha1Of(2), .path = "a" } }, 0, &.{});
    const k2 = try compute(testing.allocator, p2, uuidOf(1), .{ .local = .{ .tree = sha1Of(2), .path = "ab" } }, 0, &.{});
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "dependency keys are sorted, so the caller's order cannot matter" {
    const a: Key = [_]u8{0xF0} ** 32;
    const b: Key = [_]u8{0x0F} ** 32;
    const k1 = try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 0, &.{ a, b });
    const k2 = try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 0, &.{ b, a });
    try testing.expectEqualSlices(u8, &k1, &k2);

    // ...but the caller's slice is not disturbed.
    var live = [_]Key{ a, b };
    _ = try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 0, &live);
    try testing.expectEqualSlices(u8, &a, &live[0]);
}

test "every field changes the key" {
    const base = try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 7, &.{});

    var p = test_params;
    p.sysimage[0] = 0xAC;
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, p, uuidOf(1), .{ .tree = sha1Of(2) }, 7, &.{})));

    p = test_params;
    p.cacheflags = 0x0c;
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, p, uuidOf(1), .{ .tree = sha1Of(2) }, 7, &.{})));

    p = test_params;
    p.cpu_target = "generic;sandybridge,clone_all";
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, p, uuidOf(1), .{ .tree = sha1Of(2) }, 7, &.{})));

    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, test_params, uuidOf(2), .{ .tree = sha1Of(2) }, 7, &.{})));
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(3) }, 7, &.{})));
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 8, &.{})));
    const d: Key = [_]u8{0x01} ** 32;
    try testing.expect(!std.mem.eql(u8, &base, &try compute(testing.allocator, test_params, uuidOf(1), .{ .tree = sha1Of(2) }, 7, &.{d})));
}

// --- the recursive driver ---------------------------------------------------

/// A → B → C, plus an unrelated D. Written in manifest v2 layout.
const chain_manifest =
    \\julia_version = "1.12.6"
    \\manifest_format = "2.0"
    \\
    \\[[deps.A]]
    \\deps = ["B"]
    \\git-tree-sha1 = "1111111111111111111111111111111111111111"
    \\uuid = "00000000-0000-0000-0000-0000000000a1"
    \\version = "1.0.0"
    \\
    \\[[deps.B]]
    \\deps = ["C"]
    \\git-tree-sha1 = "2222222222222222222222222222222222222222"
    \\uuid = "00000000-0000-0000-0000-0000000000b1"
    \\version = "1.0.0"
    \\
    \\[[deps.C]]
    \\git-tree-sha1 = "3333333333333333333333333333333333333333"
    \\uuid = "00000000-0000-0000-0000-0000000000c1"
    \\version = "1.0.0"
    \\
    \\[[deps.D]]
    \\git-tree-sha1 = "4444444444444444444444444444444444444444"
    \\uuid = "00000000-0000-0000-0000-0000000000d1"
    \\version = "1.0.0"
    \\
;

fn keysOf(arena: Allocator, src: []const u8, opts: Options) !Keys {
    const m = try manifest_mod.parse(arena, src, null);
    return computeManifest(arena, &m, opts);
}

test "a dependency's tree hash propagates to its dependents and nowhere else" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const before = try keysOf(a1.allocator(), chain_manifest, .{ .params = test_params });

    // C's content changes.
    const mutated = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        chain_manifest,
        "3333333333333333333333333333333333333333",
        "3333333333333333333333333333333333333330",
    );
    defer testing.allocator.free(mutated);

    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const after = try keysOf(a2.allocator(), mutated, .{ .params = test_params });

    try testing.expectEqual(@as(usize, 4), after.entries.len);
    // C itself, and its transitive dependents B and A.
    try testing.expect(!std.mem.eql(u8, &before.getByName("C").?, &after.getByName("C").?));
    try testing.expect(!std.mem.eql(u8, &before.getByName("B").?, &after.getByName("B").?));
    try testing.expect(!std.mem.eql(u8, &before.getByName("A").?, &after.getByName("A").?));
    // Nothing else.
    try testing.expectEqualSlices(u8, &before.getByName("D").?, &after.getByName("D").?);
}

test "the key is deterministic across runs and independent of manifest dep order" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const first = try keysOf(a1.allocator(), chain_manifest, .{ .params = test_params });

    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const second = try keysOf(a2.allocator(), chain_manifest, .{ .params = test_params });
    for (first.entries, second.entries) |x, y| try testing.expectEqualSlices(u8, &x.key, &y.key);

    // Two deps listed in either order must key the same.
    const two_deps =
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B", "C"]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\
        \\[[deps.B]]
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\uuid = "00000000-0000-0000-0000-0000000000b1"
        \\
        \\[[deps.C]]
        \\git-tree-sha1 = "3333333333333333333333333333333333333333"
        \\uuid = "00000000-0000-0000-0000-0000000000c1"
        \\
    ;
    const swapped = try std.mem.replaceOwned(u8, testing.allocator, two_deps, "[\"B\", \"C\"]", "[\"C\", \"B\"]");
    defer testing.allocator.free(swapped);

    var a3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a3.deinit();
    const k3 = try keysOf(a3.allocator(), two_deps, .{ .params = test_params });
    var a4 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a4.deinit();
    const k4 = try keysOf(a4.allocator(), swapped, .{ .params = test_params });
    try testing.expectEqualSlices(u8, &k3.getByName("A").?, &k4.getByName("A").?);
}

test "a different sysimage changes every key" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const before = try keysOf(a1.allocator(), chain_manifest, .{ .params = test_params });

    var p = test_params;
    p.sysimage = [_]u8{0xCD} ** 32;
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const after = try keysOf(a2.allocator(), chain_manifest, .{ .params = p });

    for (before.entries, after.entries) |x, y| {
        try testing.expect(!std.mem.eql(u8, &x.key, &y.key));
    }
}

test "sysimage packages are skipped, and the upgradable pair is not" {
    // `Statistics` is in the stdlib directory but is NOT a stdlib
    // (Types.jl:501, 514-517), so it must be keyed like a registry package.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["LinearAlgebra", "Statistics"]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\
        \\[[deps.LinearAlgebra]]
        \\uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
        \\
        \\[[deps.Statistics]]
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
        \\version = "1.11.1"
        \\
    ;
    const la: stdlibs_mod.Stdlib = .{
        .name = "LinearAlgebra",
        .uuid = try Uuid.parse("37e2e46d-f89d-539d-b4ee-838fcccc9c8e"),
        .uuid_text = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e",
    };
    const st: stdlibs_mod.Stdlib = .{
        .name = "Statistics",
        .uuid = try Uuid.parse("10745b16-79ce-11e8-11f9-7d13ad32a3b2"),
        .uuid_text = "10745b16-79ce-11e8-11f9-7d13ad32a3b2",
        .upgradable = true,
    };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var set: stdlibs_mod.Set = .{ .dir = "", .fixed = &.{la}, .upgradable = &.{st} };
    try set.by_uuid.put(arena, la.uuid.bytes, &set.fixed[0]);
    try set.by_uuid.put(arena, st.uuid.bytes, &set.upgradable[0]);

    const keys = try keysOf(arena, src, .{ .params = test_params, .stdlibs = &set });

    // LinearAlgebra has no tree hash and would come back unkeyed if it
    // were not recognised as a sysimage package.
    try testing.expectEqual(@as(usize, 2), keys.entries.len);
    try testing.expectEqual(@as(usize, 1), keys.skipped.len);
    try testing.expect(keys.getByName("LinearAlgebra") == null);
    try testing.expect(keys.getByName("Statistics") != null);

    // A's key must fold in Statistics but not LinearAlgebra: computing it by
    // hand with exactly one dep key reproduces it.
    const expect_a = try compute(
        arena,
        test_params,
        try Uuid.parse("00000000-0000-0000-0000-0000000000a1"),
        .{ .tree = try Sha1.parse("1111111111111111111111111111111111111111") },
        0,
        &.{keys.getByName("Statistics").?},
    );
    try testing.expectEqualSlices(u8, &expect_a, &keys.getByName("A").?);
}

test "a path entry needs an explicit Local, and the path is in its key" {
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Self]]
        \\path = "."
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "0.1.0"
        \\
    ;
    // With no `Local`, the entry is UNKEYED — not an error. A package project
    // always has this shape (`path = "."`), so refusing here made every real
    // environment unkeyable over one entry.
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const bare = try keysOf(a1.allocator(), src, .{ .params = test_params });
    try testing.expectEqual(@as(usize, 0), bare.entries.len);
    try testing.expectEqual(@as(usize, 1), bare.unkeyed.len);
    try testing.expect(bare.getByName("Self") == null);

    const uuid = try Uuid.parse("00000000-0000-0000-0000-0000000000a1");
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const at_engine = try keysOf(a2.allocator(), src, .{
        .params = test_params,
        .local = &.{.{ .uuid = uuid, .content = .{ .tree = sha1Of(9), .path = "/engine" } }},
    });
    var a3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a3.deinit();
    const at_home = try keysOf(a3.allocator(), src, .{
        .params = test_params,
        .local = &.{.{ .uuid = uuid, .content = .{ .tree = sha1Of(9), .path = "/home/dev/Open-Reality" } }},
    });
    try testing.expect(!std.mem.eql(u8, &at_engine.getByName("Self").?, &at_home.getByName("Self").?));
}

test "unaddressability propagates to everything that depends on it" {
    // `Dev` is a checkout; `Mid` depends on it and `Top` depends on `Mid`.
    // None of the three can be shared: whatever `Top` compiles to was built
    // against source that exists on one machine. `Side` is off that subtree and
    // must keep its key, or one `develop` would disable the cache entirely.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Top]]
        \\deps = ["Mid", "Side"]
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\git-tree-sha1 = "5555555555555555555555555555555555555555"
        \\
        \\[[deps.Mid]]
        \\deps = ["Dev"]
        \\uuid = "00000000-0000-0000-0000-0000000000b1"
        \\version = "1.0.0"
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\
        \\[[deps.Dev]]
        \\path = "/home/dev/Checkout"
        \\uuid = "00000000-0000-0000-0000-0000000000c1"
        \\version = "1.0.0"
        \\
        \\[[deps.Side]]
        \\uuid = "00000000-0000-0000-0000-0000000000d1"
        \\version = "1.0.0"
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\
    ;
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const k = try keysOf(a1.allocator(), src, .{ .params = test_params });

    try testing.expect(k.getByName("Dev") == null);
    try testing.expect(k.getByName("Mid") == null);
    try testing.expect(k.getByName("Top") == null);
    try testing.expect(k.getByName("Side") != null);
    try testing.expectEqual(@as(usize, 3), k.unkeyed.len);
    try testing.expectEqual(@as(usize, 1), k.entries.len);

    // Non-vacuity: give `Dev` an address and all four come back. Without this
    // the test above would pass just as well against an implementation that
    // keyed nothing at all.
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const all = try keysOf(a2.allocator(), src, .{
        .params = test_params,
        .local = &.{.{
            .uuid = try Uuid.parse("00000000-0000-0000-0000-0000000000c1"),
            .content = .{ .tree = sha1Of(9), .path = "/home/dev/Checkout" },
        }},
    });
    try testing.expectEqual(@as(usize, 0), all.unkeyed.len);
    try testing.expectEqual(@as(usize, 4), all.entries.len);
    // ...and `Side`, which never depended on the checkout, is unmoved by it.
    try testing.expectEqualSlices(u8, &k.getByName("Side").?, &all.getByName("Side").?);
}

test "a cycle is still a cycle when one of its members is unaddressable" {
    // The walk visits every dependency even after one has come back null, so
    // that cycle detection does not depend on which entry happens to be a
    // checkout. Short-circuiting on the first null would turn this into a
    // silent unkeyed pair.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\path = "/home/dev/A"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\version = "1.0.0"
        \\
        \\[[deps.B]]
        \\deps = ["A"]
        \\uuid = "00000000-0000-0000-0000-0000000000b1"
        \\version = "1.0.0"
        \\git-tree-sha1 = "3333333333333333333333333333333333333333"
        \\
    ;
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    try testing.expectError(error.DependencyCycle, keysOf(a1.allocator(), src, .{ .params = test_params }));
}

test "a Local alongside a git-tree-sha1 is still a caller bug, not an unkeyed entry" {
    // The one refusal that survives. An unaddressable checkout is a property of
    // the environment; supplying a path address for a registered package is a
    // mistake, and silently preferring one over the other would swap a portable
    // key for a machine-local one.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Reg]]
        \\uuid = "00000000-0000-0000-0000-0000000000e1"
        \\version = "1.0.0"
        \\git-tree-sha1 = "4444444444444444444444444444444444444444"
        \\
    ;
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    try testing.expectError(error.LocalForRegisteredPackage, keysOf(a1.allocator(), src, .{
        .params = test_params,
        .local = &.{.{
            .uuid = try Uuid.parse("00000000-0000-0000-0000-0000000000e1"),
            .content = .{ .tree = sha1Of(9), .path = "/anywhere" },
        }},
    }));
}

test "preferences shift only the package they belong to" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    const before = try keysOf(a1.allocator(), chain_manifest, .{ .params = test_params });

    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const after = try keysOf(a2.allocator(), chain_manifest, .{
        .params = test_params,
        .prefs = &.{.{ .uuid = try Uuid.parse("00000000-0000-0000-0000-0000000000c1"), .hash = 42 }},
    });
    try testing.expect(!std.mem.eql(u8, &before.getByName("C").?, &after.getByName("C").?));
    try testing.expect(!std.mem.eql(u8, &before.getByName("A").?, &after.getByName("A").?));
    try testing.expectEqualSlices(u8, &before.getByName("D").?, &after.getByName("D").?);
}

test "two entries under one UUID are refused, not keyed twice" {
    // `model/manifest.zig` preserves both (Pkg's Dict{UUID,PackageEntry} cannot
    // represent it, and `validateGraph` does not reject it), so the guard has to
    // live here. Keying both gives one PkgId two store objects while dependents
    // fold in only the first — a stale hit.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Dup]]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "00000000-0000-0000-0000-0000000000d1"
        \\
        \\[[deps.Other]]
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\uuid = "00000000-0000-0000-0000-0000000000d1"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.DuplicateUuid, keysOf(arena_state.allocator(), src, .{ .params = test_params }));
}

test "a Local for a package that has a tree hash is refused, not silently preferred" {
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.LocalForRegisteredPackage, keysOf(arena_state.allocator(), src, .{
        .params = test_params,
        .local = &.{.{
            .uuid = try Uuid.parse("00000000-0000-0000-0000-0000000000a1"),
            .content = .{ .tree = sha1Of(9), .path = "/engine" },
        }},
    }));
}

test "the returned names survive the manifest source buffer" {
    // `Entry.name` is copied, not borrowed: parse from a buffer that is freed
    // immediately afterwards and the names must still read back.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scratch = try testing.allocator.dupe(u8, chain_manifest);
    const m = try manifest_mod.parse(arena, scratch, null);
    const keys = try computeManifest(arena, &m, .{ .params = test_params });
    @memset(scratch, 0xAA);
    testing.allocator.free(scratch);

    try testing.expect(keys.getByName("A") != null);
    try testing.expect(keys.getByName("D") != null);
}

test "a dependency cycle is refused rather than recursed into" {
    // `model/manifest.zig` accepts this — both UUIDs resolve — so the guard has
    // to be here.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\deps = ["B"]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\
        \\[[deps.B]]
        \\deps = ["A"]
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\uuid = "00000000-0000-0000-0000-0000000000b1"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.DependencyCycle, keysOf(arena_state.allocator(), src, .{ .params = test_params }));
}

test "conservative prefs hash folds every key, sorted" {
    // Oracle (julia 1.12.6), which is `get_preferences_hash` with prefs_list =
    // sorted(keys(prefs)):
    //
    //   prefs = Dict{String,Any}("zeta" => 3, "alpha" => "x", "mid" => true)
    //   h = UInt(0)
    //   for n in sort(collect(keys(prefs)))
    //       v = get(prefs, n, nothing); v !== nothing && (h = hash(v, h))
    //   end
    //   UInt64(h)  =>  0xf142e86c551e683b
    var doc = try parseToml(testing.allocator,
        \\zeta = 3
        \\alpha = "x"
        \\mid = true
        \\
    , null);
    defer doc.deinit();

    const got = try conservativePrefsHash(testing.allocator, doc.root);
    try testing.expectEqual(@as(u64, 0xf142e86c551e683b), got);

    // The order in the FILE must not matter; the sort is what decides.
    var doc2 = try parseToml(testing.allocator,
        \\mid = true
        \\alpha = "x"
        \\zeta = 3
        \\
    , null);
    defer doc2.deinit();
    try testing.expectEqual(got, try conservativePrefsHash(testing.allocator, doc2.root));

    try testing.expectEqual(@as(u64, 0), try conservativePrefsHash(testing.allocator, null));
}
