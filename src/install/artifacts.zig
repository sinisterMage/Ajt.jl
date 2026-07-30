//! `Artifacts.toml`: the model that decides which binary a JLL installs.
//!
//! Port of `Artifacts/src/Artifacts.jl` (the reading half) plus the pieces of
//! `Pkg/src/Artifacts.jl` that the install pipeline needs. Getting the selection
//! wrong here is not a cosmetic bug: it is the difference between a working
//! engine and a `dlopen` failure, and the failure shows up far from the cause.
//!
//! Four subtleties carry almost all the risk.
//!
//!  1. **`unpack_platform` is not "read the tags you know about"** (`:280-304`).
//!     It takes **every String-valued key** in the entry as a tag, then deletes
//!     `os`, `arch` and `git-tree-sha1`, then hands arch+os to the `Platform`
//!     constructor separately. Unknown tags therefore FLOW THROUGH into
//!     matching -- `cuda = "10.1"` is a real example -- so neither matching nor
//!     `triplet` may assume a closed key set.
//!
//!  2. **The `Platform` constructor normalises**, observably
//!     (`base/binaryplatforms.jl:44-107`), and that changes which variant wins.
//!     The rule lives with the type, in `julia/platform.zig`'s `construct`;
//!     this module only decides WHICH tags to hand it and must not re-derive
//!     any of it.
//!
//!  3. **`git-tree-sha1` is validated AFTER selection, not before**
//!     (`:423-429`). An entry missing it still competes; if it wins, the whole
//!     artifact resolves to `nothing`. Filtering such entries out early would
//!     silently install the runner-up.
//!
//!  4. **`download` is checked by KEY PRESENCE, not by content** (`:468`). An
//!     entry with `download = []` is "downloadable" with zero sources. That is
//!     why `has_download` is stored separately from `downloads.len`.
//!
//! Platform construction and matching are NOT reimplemented here:
//! `julia/platform.zig` ports the constructor plus
//! `platforms_match`/`select_platform`/`triplet`, and is gated against Julia
//! across the whole depot. This module's job is to decide which tags to hand
//! the constructor, and to interpret the answer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const toml = @import("../toml/parse.zig");
const tv = @import("../toml/value.zig");
const Table = tv.Table;
const Value = tv.Value;
const platform_mod = @import("../julia/platform.zig");
const slug = @import("../julia/slug.zig");

pub const Platform = platform_mod.Platform;
pub const Tag = platform_mod.Tag;

/// `artifact_names` (`Artifacts.jl:37`). ORDER IS LOAD-BEARING: a package
/// shipping both files is read from `JuliaArtifacts.toml`.
pub const artifact_names = [_][]const u8{ "JuliaArtifacts.toml", "Artifacts.toml" };

/// A malformed *entry* is never an error here; it lands in `File.problems`.
/// That is a deliberate divergence -- most of those cases THROW in Julia. See
/// `Problem`. Only a TOML syntax error or OOM stops us.
pub const Error = toml.Error || Allocator.Error;

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One `[[X.download]]` stanza. Julia tries these in file order and stops at
/// the first success (`Pkg/src/Artifacts.jl:507-523`), so order is meaningful.
pub const Download = struct {
    url: []const u8,
    sha256: []const u8,
};

/// One entry for an artifact name: either the single table of a
/// platform-independent artifact, or one element of the array-of-tables.
pub const Variant = struct {
    /// `null` exactly when the artifact was written as a plain table rather
    /// than an array of tables -- Julia never calls `unpack_platform` on that
    /// shape and never platform-filters it (`:409-420`).
    platform: ?Platform,
    /// `null` when the entry has no `git-tree-sha1`. Deliberately not a parse
    /// error: see trap 3 in the module docs.
    git_tree_sha1: ?[]const u8,
    /// Presence of the `download` KEY, independent of how many sources it has.
    has_download: bool,
    downloads: []const Download,
    lazy: bool,
    /// Position within the array-of-tables (0 for a bare table). Diagnostics
    /// only; nothing selects on it.
    index: usize,
    /// The raw TOML table, so callers can read keys this model does not name.
    meta: *const Table,
};

pub const Artifact = struct {
    name: []const u8,
    variants: []const Variant,

    /// True for the bare-table shape. Such an artifact has exactly one variant
    /// and is returned regardless of platform.
    pub fn isPlatformIndependent(self: Artifact) bool {
        return self.variants.len == 1 and self.variants[0].platform == null;
    }
};

/// A dropped entry, and why.
///
/// **DELIBERATE DIVERGENCE, verified by running Julia 1.12.6.** Except for
/// `malformed_value`, every reason below makes real Julia THROW, and the throw
/// escapes `artifact_meta` uncaught — so `select_downloadable_artifacts`, which
/// calls `artifact_meta` for every name (`:461-463`), aborts resolution of the
/// WHOLE FILE, not just the bad entry:
///
///   * `missing_os` / `missing_arch`: `unpack_platform` does `@error` and
///     return `nothing` (`:282-290`), but the caller immediately asserts
///     `unpack_platform(...)::Platform` (`:413`) -> `TypeError`.
///   * `not_a_table`: `x = x::Dict{String, Any}` (`:412`) -> `TypeError`.
///   * `invalid_tag_character`: `add_tag!` throws `ArgumentError` outright
///     (`binaryplatforms.jl:126-142`).
///   * `double_passed_key`: `ArgumentError("Cannot double-pass key ...")`
///     (`binaryplatforms.jl:57-60`).
///
/// Ajt skips the entry instead, per this module's contract: it is the front
/// half of an installer that must report which entry is wrong rather than die
/// on the file. The cost is that a bad file resolves HERE and blows up under
/// real Pkg, so a non-empty `problems` means "Julia would refuse this file" and
/// callers should surface it. `malformed_value` is the one reason Julia really
/// does tolerate (`@error` + `return nothing`, `:417-419`).
pub const Problem = struct {
    artifact: []const u8,
    index: usize,
    reason: Reason,

    pub const Reason = enum {
        /// `:282-285` -- no `os` key. Julia: `TypeError` via `:413`.
        missing_os,
        /// `:287-290` -- no `arch` key. Julia: `TypeError` via `:413`.
        missing_arch,
        /// The array element was not a table. Julia: `TypeError` via `:412`.
        not_a_table,
        /// A tag key or value contains one of `add_tag!`'s forbidden
        /// characters (`binaryplatforms.jl:126-142`). Julia: `ArgumentError`.
        invalid_tag_character,
        /// A key that lowercases to `os`/`arch` (e.g. a literal `OS =`) and so
        /// escapes the exact-case delete at `:300-301`.
        /// Julia: `ArgumentError("Cannot double-pass key ...")`.
        double_passed_key,
        /// `:417-419` -- the value was neither an array nor a table. This is
        /// the only reason Julia handles gracefully.
        malformed_value,
    };
};

/// A parsed `(Julia)Artifacts.toml`.
///
/// Everything hangs off the arena passed to `parse`/`load`; there is no
/// per-node ownership and no `deinit`. Drop the arena to free the lot.
pub const File = struct {
    path: []const u8,
    artifacts: []const Artifact,
    /// Non-empty means real Julia would have THROWN on this file (see
    /// `Problem`), so anything selected from it is Ajt being lenient, not Ajt
    /// agreeing with Pkg. Surface it.
    problems: []const Problem,

    pub fn find(self: File, name: []const u8) ?*const Artifact {
        for (self.artifacts) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// `find_artifacts_toml`'s leaf step (`:517-522`): probe `artifact_names` in a
/// single directory. Allocates the returned path from `arena`.
///
/// Only the leaf is ported. The walk-up-to-the-project-root loop matters for
/// `@artifact_str` inside a source file; the installer already knows the
/// package root, and walking up from there would escape into the depot.
///
/// The result is `pkg_root` joined verbatim, where Julia returns `abspath(...)`
/// (`:520`) -- identical for the absolute package roots this pipeline deals in.
pub fn findArtifactsToml(arena: Allocator, io: Io, pkg_root: []const u8) Allocator.Error!?[]const u8 {
    // At most one probe path is left behind in the arena, which owns it; no
    // per-name free, in keeping with the rest of this module.
    for (artifact_names) |name| {
        const p = try std.fs.path.join(arena, &.{ pkg_root, name });
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch continue;
        // `isfile` in Julia follows symlinks and rejects directories; statFile
        // follows by default, so only the kind check is left to do.
        if (st.kind == .file) return p;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parses `src` as an `Artifacts.toml`. `path` is kept for diagnostics only.
///
/// Arena-lifetime: every string in the result borrows either from `src` or from
/// `arena`, so `arena` must outlive the returned `File`.
pub fn parse(arena: Allocator, src: []const u8, path: []const u8) Error!File {
    const doc = try toml.parse(arena, src, null);
    // NB: `toml.parse` builds its own ArenaAllocator on top of `arena`, so the
    // document dies with `arena` and must NOT be deinit'd here -- the same
    // pattern registry/index.zig uses for an archive-backed document.
    return fromTable(arena, doc.root, path);
}

/// Reads and parses the file at `path`.
pub fn load(arena: Allocator, io: Io, path: []const u8) (Error || Io.Dir.ReadFileAllocError)!File {
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
    return parse(arena, src, path);
}

/// The pure half of `parse`, exposed for callers that already hold a TOML tree.
pub fn fromTable(arena: Allocator, root: *const Table, path: []const u8) Error!File {
    var artifacts: std.ArrayList(Artifact) = .empty;
    var problems: std.ArrayList(Problem) = .empty;

    for (root.entries.items) |entry| {
        var variants: std.ArrayList(Variant) = .empty;
        switch (entry.value) {
            // Array of tables: platform-specific variants (`:409-415`).
            .array => |items| {
                for (items, 0..) |item, i| {
                    const t = switch (item) {
                        .table => |t| t,
                        else => {
                            try problems.append(arena, .{ .artifact = entry.key, .index = i, .reason = .not_a_table });
                            continue;
                        },
                    };
                    const p = unpackPlatform(arena, t) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MissingOs,
                        error.MissingArch,
                        error.InvalidTagCharacter,
                        error.DoublePassedKey,
                        => {
                            try problems.append(arena, .{
                                .artifact = entry.key,
                                .index = i,
                                .reason = switch (err) {
                                    error.MissingOs => .missing_os,
                                    error.MissingArch => .missing_arch,
                                    error.DoublePassedKey => .double_passed_key,
                                    else => .invalid_tag_character,
                                },
                            });
                            continue;
                        },
                    };
                    try variants.append(arena, try readVariant(arena, t, p, i));
                }
            },
            // A bare table is a platform-independent artifact (`:30-37`).
            .table => |t| {
                try variants.append(arena, try readVariant(arena, t, null, 0));
            },
            // "artifact '$name' malformed, must be array or dict!" (`:417-419`).
            // The NAME still exists as far as Julia is concerned -- it just
            // resolves to nothing. Dropping it here instead would make the
            // artifact silently invisible rather than visibly unresolvable.
            else => {
                try problems.append(arena, .{ .artifact = entry.key, .index = 0, .reason = .malformed_value });
            },
        }
        try artifacts.append(arena, .{
            .name = entry.key,
            .variants = try variants.toOwnedSlice(arena),
        });
    }

    return .{
        .path = path,
        .artifacts = try artifacts.toOwnedSlice(arena),
        .problems = try problems.toOwnedSlice(arena),
    };
}

fn readVariant(arena: Allocator, t: *const Table, p: ?Platform, index: usize) Allocator.Error!Variant {
    var downloads: std.ArrayList(Download) = .empty;
    var has_download = false;
    if (t.get("download")) |dv| {
        // Presence of the key is what `select_downloadable_artifacts` tests
        // (`:468`); an empty or malformed array still counts as present.
        has_download = true;
        if (dv == .array) {
            for (dv.array) |d| {
                const dt = switch (d) {
                    .table => |dt| dt,
                    else => continue,
                };
                const url = stringOf(dt.get("url")) orelse continue;
                const sha256 = stringOf(dt.get("sha256")) orelse continue;
                try downloads.append(arena, .{ .url = url, .sha256 = sha256 });
            }
        }
    }

    // `get(meta, "lazy", false)` is spliced straight into a `&&`
    // (`:468`), so a non-Bool `lazy` is a TypeError in Julia. We treat only a
    // literal `true` as lazy, which is the same answer for every well-formed
    // file and degrades to "eager" rather than to a crash.
    const lazy = if (t.get("lazy")) |lv| (lv == .boolean and lv.boolean) else false;

    return .{
        .platform = p,
        .git_tree_sha1 = stringOf(t.get("git-tree-sha1")),
        .has_download = has_download,
        .downloads = try downloads.toOwnedSlice(arena),
        .lazy = lazy,
        .index = index,
        .meta = t,
    };
}

fn stringOf(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// unpack_platform
// ---------------------------------------------------------------------------

pub const UnpackError = error{
    MissingOs,
    MissingArch,
} || platform_mod.ConstructError;

/// `unpack_platform` (`Artifacts.jl:280-304`): the SELECTION of tags only --
/// pull `os`/`arch` out, take every other String-valued key, drop the three
/// keys Julia deletes, hand the rest to the constructor. Julia's version has
/// the same shape, ending in `return Platform(arch, os, tags)`.
///
/// Arena-lifetime: `construct` allocates rewritten tag strings from `arena`;
/// unmodified ones borrow from the TOML document.
pub fn unpackPlatform(arena: Allocator, entry: *const Table) UnpackError!Platform {
    const raw_os = stringOf(entry.get("os")) orelse return error.MissingOs;
    const raw_arch = stringOf(entry.get("arch")) orelse return error.MissingArch;

    var tags: std.ArrayList(Tag) = .empty;
    for (entry.entries.items) |kv| {
        // "Collect all String-valued mappings ... and use them as tags"
        // (`:292-298`): a non-String value is skipped, not an error. This is
        // what lets `[[X.download]]` (an array) sit inside the entry.
        const raw_value = switch (kv.value) {
            .string => |s| s,
            else => continue,
        };
        // "Removing some known entries that shouldn't be passed through"
        // (`:299-302`). The delete is EXACT-CASE (Julia deletes from a Dict),
        // so a literal `OS = "..."` key survives it -- and then the constructor
        // lowercases the key and throws "Cannot double-pass key os"
        // (`binaryplatforms.jl:57-60`), which is why `construct` and not this
        // loop is the one that has to notice.
        if (std.mem.eql(u8, kv.key, "os") or
            std.mem.eql(u8, kv.key, "arch") or
            std.mem.eql(u8, kv.key, "git-tree-sha1")) continue;

        try tags.append(arena, .{ .key = kv.key, .value = raw_value });
    }

    return platform_mod.construct(arena, raw_arch, raw_os, tags.items);
}

// ---------------------------------------------------------------------------
// Selection (artifact_meta)
// ---------------------------------------------------------------------------

/// `artifact_meta` (`Artifacts.jl:401-433`): the platform-collapsed entry for
/// `name`, or `null` when nothing matches or the winner has no
/// `git-tree-sha1`.
///
/// `gpa` is scratch only (triplet rendering inside `select_platform`); the
/// result borrows from the `File`'s arena.
pub fn select(gpa: Allocator, art: *const Artifact, host: Platform) Allocator.Error!?*const Variant {
    if (art.variants.len == 0) return null;

    const winner: *const Variant = if (art.isPlatformIndependent())
        &art.variants[0]
    else blk: {
        // `dl_dict[unpack_platform(x)] = x` is a Dict keyed by Platform
        // (`:410-414`), so two entries that unpack to the SAME tag set collapse
        // and the LAST one in file order wins. Keep that, or a file with a
        // duplicated variant resolves to the wrong tarball.
        var cands: std.ArrayList(Platform) = .empty;
        defer cands.deinit(gpa);
        var picks: std.ArrayList(*const Variant) = .empty;
        defer picks.deinit(gpa);

        for (art.variants) |*v| {
            const p = v.platform orelse continue;
            var replaced = false;
            for (cands.items, 0..) |c, i| {
                if (tagsEqual(c, p)) {
                    cands.items[i] = p;
                    picks.items[i] = v;
                    replaced = true;
                    break;
                }
            }
            if (replaced) continue;
            try cands.append(gpa, p);
            try picks.append(gpa, v);
        }
        if (cands.items.len == 0) return null;

        const idx = try platform_mod.selectPlatform(gpa, cands.items, host) orelse return null;
        break :blk picks.items[idx];
    };

    // "This is such a no-no, we are going to call it out right here, right
    // now" (`:422-429`): the sha1 check happens AFTER selection, and its
    // absence sinks the whole artifact rather than the one entry.
    if (winner.git_tree_sha1 == null) return null;
    return winner;
}

/// Julia's `Platform` stores tags in a `Dict`, so key ORDER is not part of
/// identity. Two tag lists are equal iff they are equal as sets.
fn tagsEqual(a: Platform, b: Platform) bool {
    if (a.tags.len != b.tags.len) return false;
    for (a.tags) |ta| {
        const bv = b.get(ta.key) orelse return false;
        if (!std.mem.eql(u8, ta.value, bv)) return false;
    }
    return true;
}

pub const Selected = struct {
    name: []const u8,
    variant: *const Variant,
};

/// `select_downloadable_artifacts` (`:456-476`): everything that resolves for
/// `host`, has a `download` key, and is not lazily gated out.
///
/// The result slice is allocated from `arena`; `gpa` is scratch.
pub fn selectDownloadable(
    arena: Allocator,
    gpa: Allocator,
    file: File,
    host: Platform,
    include_lazy: bool,
) Allocator.Error![]const Selected {
    var out: std.ArrayList(Selected) = .empty;
    for (file.artifacts) |*art| {
        const v = (try select(gpa, art, host)) orelse continue;
        if (!v.has_download) continue;
        if (v.lazy and !include_lazy) continue;
        try out.append(arena, .{ .name = art.name, .variant = v });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Overrides.toml
// ---------------------------------------------------------------------------

/// What an override redirects to (`:196-198`).
pub const Target = union(enum) {
    /// An absolute on-disk path, used verbatim.
    path: []const u8,
    /// Another artifact's content hash; resolved through `artifactPath` again,
    /// which is how a chain of overrides works.
    hash: []const u8,
};

/// The loaded `<depot>/artifacts/Overrides.toml` set (`:112-193`).
///
/// Arena-allocated in full; `processOverrides` mutates `by_hash` in place, so
/// the arena must stay alive for as long as the overrides are consulted.
pub const Overrides = struct {
    arena: Allocator,
    by_hash: std.StringHashMapUnmanaged(Target) = .empty,
    by_uuid: std.StringHashMapUnmanaged(NameMap) = .empty,

    pub const NameMap = std.StringHashMapUnmanaged(Target);

    pub fn init(arena: Allocator) Overrides {
        return .{ .arena = arena };
    }

    /// `query_override(hash)` (`:206-209`), minus the path mapping -- callers
    /// go through `artifactPath` for that, because a hash target has to be
    /// re-resolved rather than formatted.
    pub fn queryHash(self: *const Overrides, hash_hex: []const u8) ?Target {
        var buf: [40]u8 = undefined;
        const key = normalizeHash(hash_hex, &buf) orelse return null;
        return self.by_hash.get(key);
    }

    /// `query_override(uuid, name)` (`:210-216`).
    pub fn queryUuidName(self: *const Overrides, uuid: []const u8, name: []const u8) ?Target {
        var buf: [36]u8 = undefined;
        const key = normalizeUuid(uuid, &buf) orelse return null;
        const names = self.by_uuid.get(key) orelse return null;
        return names.get(name);
    }

    fn putHash(self: *Overrides, hash_hex: []const u8, target: Target) Allocator.Error!void {
        var buf: [40]u8 = undefined;
        const key = normalizeHash(hash_hex, &buf) orelse return;
        try self.by_hash.put(self.arena, try self.arena.dupe(u8, key), target);
    }

    fn deleteHash(self: *Overrides, hash_hex: []const u8) void {
        var buf: [40]u8 = undefined;
        const key = normalizeHash(hash_hex, &buf) orelse return;
        _ = self.by_hash.remove(key);
    }
};

/// Julia keys the override dicts by `SHA1`/`UUID` VALUES, not by the strings
/// written in the file, so `ABC...` and `abc...` are the same key. We key by
/// string, hence the normalisation to canonical lowercase hex.
fn normalizeHash(s: []const u8, buf: *[40]u8) ?[]const u8 {
    _ = slug.Sha1.parse(s) catch return null;
    // The bound comes from slug.Sha1.parse's exact `s.len != 40` check, which
    // is a file away; assert it here so the copy below is locally obviously safe.
    std.debug.assert(s.len == buf.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..40];
}

fn normalizeUuid(s: []const u8, buf: *[36]u8) ?[]const u8 {
    _ = slug.Uuid.parse(s) catch return null;
    std.debug.assert(s.len == buf.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..36];
}

/// `load_overrides` (`:112-193`) over the given depot list.
///
/// The reverse iteration at `:127` is the whole point: later writes overwrite
/// earlier ones, so processing the LAST depot first makes the FIRST depot win.
/// Iterate forwards and a stacked `JULIA_DEPOT_PATH` silently resolves
/// artifacts from the wrong depot.
///
/// Arena-lifetime: the returned `Overrides` and every string in it live in
/// `arena`.
pub fn loadOverrides(arena: Allocator, io: Io, depots: []const []const u8) Error!Overrides {
    var ov = Overrides.init(arena);

    var i = depots.len;
    while (i > 0) {
        i -= 1;
        const path = try std.fs.path.join(arena, &.{ depots[i], "artifacts", "Overrides.toml" });
        const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch continue;
        const doc = toml.parse(arena, src, null) catch continue;
        try applyOverrideTable(&ov, doc.root);
    }
    return ov;
}

/// INVARIANT: `root` must have been parsed into `ov.arena` (or an arena that
/// outlives it). Override targets and UUID/name keys are stored as borrowed
/// slices into the document -- only the SHA1/UUID keys are duplicated, and only
/// because normalising them to lowercase produces a stack buffer.
fn applyOverrideTable(ov: *Overrides, root: *const Table) Allocator.Error!void {
    for (root.entries.items) |e| {
        switch (e.value) {
            // A direct mapping is a HASH override (`:142-155`).
            .string => |s| {
                const t = parseMapping(s) orelse continue; // `:80` -- unparseable, drop
                switch (t) {
                    // "If this mapping is the empty string, un-override it"
                    // (`:151-152`).
                    .path => |p| if (p.len == 0) ov.deleteHash(e.key) else try ov.putHash(e.key, t),
                    .hash => try ov.putHash(e.key, t),
                }
            },
            // A sub-table is a UUID/name override (`:156-178`).
            .table => |sub| {
                var buf: [36]u8 = undefined;
                const uuid = normalizeUuid(e.key, &buf) orelse continue;
                const gop = try ov.by_uuid.getOrPut(ov.arena, uuid);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try ov.arena.dupe(u8, uuid);
                    gop.value_ptr.* = .empty;
                }
                for (sub.entries.items) |ne| {
                    const s = switch (ne.value) {
                        .string => |s| s,
                        else => continue,
                    };
                    // ASYMMETRY, verified by running Julia: a bad TOP-LEVEL
                    // mapping really is tolerated -- `parse_mapping` returns
                    // `nothing` and the caller guards on it (`:135-139`). A bad
                    // NESTED one is not: `overrides_uuid[uuid][name] =
                    // override_value::Union{SHA1,String}` (`:176`) type-asserts
                    // the `nothing` and throws, killing `load_overrides` for
                    // every depot. We drop it, same as the top-level case.
                    const t = parseMapping(s) orelse continue;
                    if (t == .path and t.path.len == 0) {
                        _ = gop.value_ptr.remove(ne.key);
                    } else {
                        try gop.value_ptr.put(ov.arena, ne.key, t);
                    }
                }
            },
            else => continue,
        }
    }
}

/// `parse_mapping(::String)` (`:76-84`): an absolute path stays a path, the
/// empty string stays a (sentinel) empty path, anything else must be a SHA1 or
/// the entry is dropped entirely.
fn parseMapping(s: []const u8) ?Target {
    if (s.len == 0) return .{ .path = s };
    if (std.fs.path.isAbsolute(s)) return .{ .path = s };
    _ = slug.Sha1.parse(s) catch return null;
    return .{ .hash = s };
}

// ---------------------------------------------------------------------------
// artifact_path / artifact_exists
// ---------------------------------------------------------------------------

/// Chain depth cap for hash->hash overrides. Julia recurses without one and
/// hangs on a cycle; we stop and fall back to the un-overridden path.
const max_override_depth = 32;

/// `artifact_paths` (`:224-234`): where an artifact could live, most-preferred
/// first. An honoured override collapses the list to a single entry.
///
/// Arena-lifetime: the slice and its strings come from `arena`.
pub fn artifactPaths(
    arena: Allocator,
    io: Io,
    depots: []const []const u8,
    hash_hex: []const u8,
    overrides: ?*const Overrides,
    honor_overrides: bool,
) Allocator.Error![]const []const u8 {
    return artifactPathsDepth(arena, io, depots, hash_hex, overrides, honor_overrides, 0);
}

fn artifactPathsDepth(
    arena: Allocator,
    io: Io,
    depots: []const []const u8,
    hash_hex: []const u8,
    overrides: ?*const Overrides,
    honor_overrides: bool,
    depth: usize,
) Allocator.Error![]const []const u8 {
    if (honor_overrides and depth < max_override_depth) {
        if (overrides) |ov| {
            if (ov.queryHash(hash_hex)) |t| switch (t) {
                .path => |p| {
                    const one = try arena.alloc([]const u8, 1);
                    one[0] = p;
                    return one;
                },
                // `map_override_path(::SHA1) = artifact_path(x)` (`:197`): a
                // hash target resolves to the RESOLVED path of that hash, not
                // to a candidate list -- so this branch collapses too.
                .hash => |h| {
                    const one = try arena.alloc([]const u8, 1);
                    one[0] = try artifactPathDepth(arena, io, depots, h, overrides, true, depth + 1);
                    return one;
                },
            };
        }
    }

    // `artifacts_dirs(bytes2hex(hash.bytes))` (`:233`): the directory name is
    // the CANONICAL lowercase hex of the parsed SHA1, not the string as
    // written. An uppercase `git-tree-sha1` would otherwise resolve to a
    // directory that cannot exist. A value that is not a SHA1 at all (Julia
    // would have thrown by now) is passed through unchanged.
    var hash_buf: [40]u8 = undefined;
    const dir_name = normalizeHash(hash_hex, &hash_buf) orelse hash_hex;

    const out = try arena.alloc([]const u8, depots.len);
    for (depots, 0..) |d, i| {
        out[i] = try std.fs.path.join(arena, &.{ d, "artifacts", dir_name });
    }
    return out;
}

/// `artifact_path` (`:245-258`): the first candidate that is a directory, else
/// the first candidate. "Else the first" is what makes this usable as an
/// install destination.
pub fn artifactPath(
    arena: Allocator,
    io: Io,
    depots: []const []const u8,
    hash_hex: []const u8,
    overrides: ?*const Overrides,
    honor_overrides: bool,
) Allocator.Error![]const u8 {
    return artifactPathDepth(arena, io, depots, hash_hex, overrides, honor_overrides, 0);
}

fn artifactPathDepth(
    arena: Allocator,
    io: Io,
    depots: []const []const u8,
    hash_hex: []const u8,
    overrides: ?*const Overrides,
    honor_overrides: bool,
    depth: usize,
) Allocator.Error![]const u8 {
    const paths = try artifactPathsDepth(arena, io, depots, hash_hex, overrides, honor_overrides, depth);
    for (paths) |p| {
        if (isDir(io, p)) return p;
    }
    if (paths.len == 0) return "";
    return paths[0];
}

/// `artifact_exists` (`:270-272`): ANY candidate being a directory is enough --
/// the artifact may be installed in a depot other than the first.
pub fn artifactExists(
    arena: Allocator,
    io: Io,
    depots: []const []const u8,
    hash_hex: []const u8,
    overrides: ?*const Overrides,
    honor_overrides: bool,
) Allocator.Error!bool {
    const paths = try artifactPathsDepth(arena, io, depots, hash_hex, overrides, honor_overrides, 0);
    for (paths) |p| {
        if (isDir(io, p)) return true;
    }
    return false;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `process_overrides` (`:341-372`): a UUID/name override is resolved at
/// `Artifacts.toml` load time by minting hash overrides for EVERY variant of
/// the named artifact -- including the ones that will not be selected. All
/// redirection then goes through the hash table, which is why `artifact_path`
/// needs no knowledge of packages.
pub fn processOverrides(ov: *Overrides, file: File, pkg_uuid: []const u8) Allocator.Error!void {
    var buf: [36]u8 = undefined;
    const uuid = normalizeUuid(pkg_uuid, &buf) orelse return;
    const names = ov.by_uuid.get(uuid) orelse return;

    for (file.artifacts) |art| {
        const target = names.get(art.name) orelse continue;
        for (art.variants) |v| {
            // Julia indexes directly -- `entry["git-tree-sha1"]::String`
            // (`:362`) -- so a variant without one raises an uncaught
            // `KeyError` that takes down `load_artifacts_toml` entirely
            // (verified against Julia). Skipping just that variant is the same
            // deliberate leniency as everywhere else in this module; the entry
            // is already reported through `File.problems` upstream.
            const h = v.git_tree_sha1 orelse continue;
            try ov.putHash(h, target);
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn hostFor(tags: []const Tag) Platform {
    return .{ .tags = tags, .is_host = true };
}

const linux_host = [_]Tag{
    .{ .key = "arch", .value = "x86_64" },
    .{ .key = "os", .value = "linux" },
    .{ .key = "libc", .value = "glibc" },
    .{ .key = "cxxstring_abi", .value = "cxx11" },
    .{ .key = "libgfortran_version", .value = "5.0.0" },
    .{ .key = "julia_version", .value = "1.12.6" },
};

test "an unknown String key becomes a matchable tag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\cuda = "10.1"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
    ;
    const f = try parse(arena, src, "test");
    const art = f.find("Foo").?;
    const p = art.variants[0].platform.?;
    try testing.expectEqualStrings("10.1", p.get("cuda").?);

    // A host that says nothing about cuda still matches: a key present on only
    // one side is skipped (binaryplatforms.jl:1026-1028).
    const sel = try select(testing.allocator, art, hostFor(&linux_host));
    try testing.expect(sel != null);

    // A host that DISAGREES about cuda does not.
    const disagree = [_]Tag{
        .{ .key = "arch", .value = "x86_64" },
        .{ .key = "os", .value = "linux" },
        .{ .key = "libc", .value = "glibc" },
        .{ .key = "cuda", .value = "11.0" },
    };
    try testing.expect((try select(testing.allocator, art, hostFor(&disagree))) == null);
}

test "the Platform constructor's auto-tags change the tag set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 6 entries in the depot corpus look exactly like this: armv7l linux with
    // libc but no call_abi.
    const src =
        \\[[Foo]]
        \\arch = "armv7l"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[Bar]]
        \\arch = "x86_64"
        \\os = "linux"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    const foo = f.find("Foo").?.variants[0].platform.?;
    try testing.expectEqualStrings("eabihf", foo.get("call_abi").?);
    // ...and a 64-bit entry gets no call_abi.
    const bar = f.find("Bar").?.variants[0].platform.?;
    try testing.expect(bar.get("call_abi") == null);
    // A linux entry with no libc defaults to glibc.
    try testing.expectEqualStrings("glibc", bar.get("libc").?);
}

test "version tags are rounded through VersionNumber" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "macos"
        \\os_version = "10.11"
        \\libstdcxx_version = "3.4.26"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
    ;
    const f = try parse(arena, src, "test");
    const p = f.find("Foo").?.variants[0].platform.?;
    // "10.11" is NOT a valid tag value to compare textually against a host's
    // "10.11.0" -- Julia canonicalises, so we must too.
    try testing.expectEqualStrings("10.11.0", p.get("os_version").?);
    try testing.expectEqualStrings("3.4.26", p.get("libstdcxx_version").?);
}

test "arch aliases and case are normalised" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[[Foo]]
        \\arch = "AMD64"
        \\os = "Linux"
        \\libc = "GLIBC"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
    ;
    const f = try parse(arena, src, "test");
    const p = f.find("Foo").?.variants[0].platform.?;
    try testing.expectEqualStrings("x86_64", p.get("arch").?);
    try testing.expectEqualStrings("linux", p.get("os").?);
    try testing.expectEqualStrings("glibc", p.get("libc").?);
    try testing.expect((try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))) != null);
}

test "an entry missing os or arch is skipped -- where Julia would throw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[[Foo]]
        \\os = "linux"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    // Julia raises `TypeError: expected Platform, got Nothing` here and never
    // returns a value at all (`:413`). Ajt records the entry and carries on --
    // and `problems` is how a caller learns that Pkg would have refused.
    try testing.expectEqual(@as(usize, 1), f.problems.len);
    try testing.expectEqual(Problem.Reason.missing_arch, f.problems[0].reason);
    const sel = (try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))).?;
    try testing.expectEqualStrings("0000000000000000000000000000000000000002", sel.git_tree_sha1.?);
}

test "a winner with no git-tree-sha1 sinks the whole artifact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The x86_64/glibc entry wins selection and has no hash; the aarch64
    // fallback must NOT be promoted in its place.
    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\
        \\[[Foo]]
        \\arch = "aarch64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expect((try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))) == null);
}

test "a forbidden tag character drops the entry -- where Julia would throw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `add_tag!` rejects `+- /<>:"'\|?*` in a tag NAME or VALUE and throws
    // ArgumentError (binaryplatforms.jl:126-142). Note `git-tree-sha1` itself
    // contains a `-` and would trip it -- which is exactly why unpack_platform
    // deletes it before construction.
    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\flavour = "with-dash"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expectEqual(@as(usize, 1), f.problems.len);
    try testing.expectEqual(Problem.Reason.invalid_tag_character, f.problems[0].reason);
    const sel = (try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))).?;
    try testing.expectEqualStrings("0000000000000000000000000000000000000002", sel.git_tree_sha1.?);
}

test "a case-variant OS key drops the entry -- where Julia would throw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `delete!(tags, "os")` is exact-case, so `OS` survives it and then trips
    // the constructor's "Cannot double-pass key os". Silently keeping it as a
    // SECOND os tag would inflate the tag count and shift match_loss.
    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\OS = "trusty"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expectEqual(@as(usize, 1), f.problems.len);
    try testing.expectEqual(Problem.Reason.double_passed_key, f.problems[0].reason);
    const sel = (try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))).?;
    try testing.expectEqualStrings("0000000000000000000000000000000000000002", sel.git_tree_sha1.?);
}

test "a non-table array element drops the entry -- where Julia would throw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Julia does `x = x::Dict{String, Any}` (:412) and raises a TypeError.
    const src =
        \\Foo = ["not a table"]
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expectEqual(@as(usize, 1), f.problems.len);
    try testing.expectEqual(Problem.Reason.not_a_table, f.problems[0].reason);
    try testing.expect((try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))) == null);
}

test "a malformed value keeps the name but resolves to nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\Junk = "not a table or an array"
        \\
        \\[[Good]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expectEqual(@as(usize, 1), f.problems.len);
    try testing.expectEqual(Problem.Reason.malformed_value, f.problems[0].reason);
    // Julia's artifact_meta returns `nothing` for such a name -- it does not
    // pretend the name is absent, and neither do we.
    const junk = f.find("Junk").?;
    try testing.expectEqual(@as(usize, 0), junk.variants.len);
    try testing.expect((try select(testing.allocator, junk, hostFor(&linux_host))) == null);
    try testing.expect((try select(testing.allocator, f.find("Good").?, hostFor(&linux_host))) != null);
}

test "a bare table is platform independent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[Data]
        \\git-tree-sha1 = "0000000000000000000000000000000000000009"
        \\
        \\    [[Data.download]]
        \\    url = "https://example.invalid/data.tar.gz"
        \\    sha256 = "ff"
        \\
    ;
    const f = try parse(arena, src, "test");
    const art = f.find("Data").?;
    try testing.expect(art.isPlatformIndependent());
    // Any host resolves it, including one that shares no tags at all.
    const alien = [_]Tag{.{ .key = "os", .value = "haiku" }};
    const sel = (try select(testing.allocator, art, hostFor(&alien))).?;
    try testing.expectEqualStrings("0000000000000000000000000000000000000009", sel.git_tree_sha1.?);
    try testing.expectEqualStrings("https://example.invalid/data.tar.gz", sel.downloads[0].url);
}

test "lazy and download-less artifacts are filtered by select_downloadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[Eager]
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\    [[Eager.download]]
        \\    url = "u1"
        \\    sha256 = "s1"
        \\
        \\[Lazy]
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\lazy = true
        \\
        \\    [[Lazy.download]]
        \\    url = "u2"
        \\    sha256 = "s2"
        \\
        \\[LocalOnly]
        \\git-tree-sha1 = "0000000000000000000000000000000000000003"
        \\
    ;
    const f = try parse(arena, src, "test");
    const host = hostFor(&linux_host);

    const eager = try selectDownloadable(arena, testing.allocator, f, host, false);
    try testing.expectEqual(@as(usize, 1), eager.len);
    try testing.expectEqualStrings("Eager", eager[0].name);

    const with_lazy = try selectDownloadable(arena, testing.allocator, f, host, true);
    try testing.expectEqual(@as(usize, 2), with_lazy.len);
    try testing.expectEqualStrings("Lazy", with_lazy[1].name);
}

test "an empty download array still counts as downloadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Julia tests `haskey(meta, "download")` (:468), not the source count.
    const src =
        \\[Odd]
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\download = []
        \\
    ;
    const f = try parse(arena, src, "test");
    const sel = try selectDownloadable(arena, testing.allocator, f, hostFor(&linux_host), false);
    try testing.expectEqual(@as(usize, 1), sel.len);
    try testing.expectEqual(@as(usize, 0), sel[0].variant.downloads.len);
}

test "duplicate platforms collapse to the last entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Julia keys `dl_dict` by Platform, so the second entry overwrites the
    // first. Keeping the first would install a different tarball.
    const src =
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[Foo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    const sel = (try select(testing.allocator, f.find("Foo").?, hostFor(&linux_host))).?;
    try testing.expectEqualStrings("0000000000000000000000000000000000000002", sel.git_tree_sha1.?);
}

test "multiple download sources keep file order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[Multi]
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\    [[Multi.download]]
        \\    url = "first"
        \\    sha256 = "a"
        \\
        \\    [[Multi.download]]
        \\    url = "second"
        \\    sha256 = "b"
        \\
    ;
    const f = try parse(arena, src, "test");
    const v = f.find("Multi").?.variants[0];
    try testing.expectEqual(@as(usize, 2), v.downloads.len);
    try testing.expectEqualStrings("first", v.downloads[0].url);
    try testing.expectEqualStrings("second", v.downloads[1].url);
}

test "Overrides.toml: hash to path, hash to hash, and un-override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h1 = "1111111111111111111111111111111111111111";
    const h2 = "2222222222222222222222222222222222222222";
    const h3 = "3333333333333333333333333333333333333333";
    const src = try std.fmt.allocPrint(arena,
        \\{s} = "/replacement"
        \\{s} = "{s}"
        \\{s} = ""
        \\
    , .{ h1, h2, h3, h3 });

    const doc = try toml.parse(arena, src, null);
    var ov = Overrides.init(arena);
    try applyOverrideTable(&ov, doc.root);

    try testing.expectEqualStrings("/replacement", ov.queryHash(h1).?.path);
    try testing.expectEqualStrings(h3, ov.queryHash(h2).?.hash);
    // An empty mapping deletes rather than sets (:151-152).
    try testing.expect(ov.queryHash(h3) == null);
    // Hash keys are values, not strings: case must not matter.
    try testing.expect(ov.queryHash("1111111111111111111111111111111111111111") != null);
}

test "Overrides.toml: a relative non-SHA1 mapping drops the entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h1 = "1111111111111111111111111111111111111111";
    const src = try std.fmt.allocPrint(arena, "{s} = \"not/absolute\"\n", .{h1});
    const doc = try toml.parse(arena, src, null);
    var ov = Overrides.init(arena);
    try applyOverrideTable(&ov, doc.root);
    try testing.expect(ov.queryHash(h1) == null);
}

test "processOverrides mints hash overrides for every variant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uuid = "d57dbccd-ca19-4d82-b9b8-9d660942965b";
    const ov_src = try std.fmt.allocPrint(arena,
        \\[{s}]
        \\libfoo = "/opt/libfoo"
        \\
    , .{uuid});
    const ov_doc = try toml.parse(arena, ov_src, null);
    var ov = Overrides.init(arena);
    try applyOverrideTable(&ov, ov_doc.root);
    try testing.expectEqualStrings("/opt/libfoo", ov.queryUuidName(uuid, "libfoo").?.path);

    const src =
        \\[[libfoo]]
        \\arch = "x86_64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000001"
        \\
        \\[[libfoo]]
        \\arch = "aarch64"
        \\os = "linux"
        \\libc = "glibc"
        \\git-tree-sha1 = "0000000000000000000000000000000000000002"
        \\
    ;
    const f = try parse(arena, src, "test");
    try testing.expect(ov.queryHash("0000000000000000000000000000000000000001") == null);
    try processOverrides(&ov, f, uuid);
    // EVERY variant is overridden, not just the selected one (:357-364).
    try testing.expectEqualStrings("/opt/libfoo", ov.queryHash("0000000000000000000000000000000000000001").?.path);
    try testing.expectEqualStrings("/opt/libfoo", ov.queryHash("0000000000000000000000000000000000000002").?.path);
}

test "artifactPaths lists one candidate per depot, most preferred first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();
    const h = "0000000000000000000000000000000000000001";
    const paths = try artifactPaths(arena, io, &.{ "/d1", "/d2" }, h, null, true);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/d1/artifacts/" ++ h, paths[0]);
    try testing.expectEqualStrings("/d2/artifacts/" ++ h, paths[1]);

    // An override collapses the list to exactly one entry (:226-231).
    var ov = Overrides.init(arena);
    try ov.putHash(h, .{ .path = "/elsewhere" });
    const one = try artifactPaths(arena, io, &.{ "/d1", "/d2" }, h, &ov, true);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("/elsewhere", one[0]);

    // ...and honour_overrides=false ignores it entirely.
    const ignored = try artifactPaths(arena, io, &.{ "/d1", "/d2" }, h, &ov, false);
    try testing.expectEqual(@as(usize, 2), ignored.len);
}

test "the artifact directory is canonical lowercase hex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();
    const upper = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const paths = try artifactPaths(arena, io, &.{"/d1"}, upper, null, true);
    try testing.expectEqualStrings("/d1/artifacts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", paths[0]);

    // Also on the far side of a hash->hash override: Julia round-trips the
    // target through a real SHA1 and renders it with bytes2hex, so an
    // uppercase target in Overrides.toml still names a lowercase directory.
    var ov = Overrides.init(arena);
    const src = "1111111111111111111111111111111111111111";
    try ov.putHash(src, .{ .hash = upper });
    const chained = try artifactPaths(arena, io, &.{"/d1"}, src, &ov, true);
    try testing.expectEqualStrings("/d1/artifacts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", chained[0]);
}

test "a hash override chain terminates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();
    const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var ov = Overrides.init(arena);
    // A cycle: Julia would recurse forever; we cap and fall back.
    try ov.putHash(a, .{ .hash = b });
    try ov.putHash(b, .{ .hash = a });
    const p = try artifactPath(arena, io, &.{"/d1"}, a, &ov, true);
    try testing.expect(p.len != 0);
}
