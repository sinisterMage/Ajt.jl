//! `Manifest.toml`, format 2.0 — read and write.
//!
//! This is the file stock `julia` reads to locate every package it loads, so
//! it is the most compatibility-critical structure Ajt owns: a manifest Julia
//! cannot read is a broken environment, and one Julia reads *differently* is
//! worse. Port of `Pkg/src/manifest.jl` — reading at `:185-243`, writing
//! (`destructure`) at `:280-399`.
//!
//! Shape, top level (`:297-310`):
//!
//! ```toml
//! julia_version = "1.12.6"      # omitted entirely when null (:299-301)
//! manifest_format = "2.0"       # TWO components, never "2.0.0" (:305)
//! project_hash = "5e05dae8..."
//!
//! [[deps.Accessors]]            # keyed by NAME, value is an ARRAY (:306, :371)
//! uuid = "7d9f7c33-..."
//! ```
//!
//! `deps` maps a name to an *array* of entries because two packages may share
//! a name under different UUIDs; every consumer must handle the array, not
//! assume one element.
//!
//! ## The traps, all of them verified against Julia rather than reasoned about
//!
//!  * **`manifest_format` loses its patch component on write.** Julia parses
//!    it as a `VersionNumber` (`v"2.0.0"`) but writes
//!    `string(major, ".", minor)` (`:305`). Emitting `"2.0.0"` produces a file
//!    Julia still reads but no longer byte-matches, which silently defeats
//!    every differential check downstream.
//!
//!  * **`git-tree-sha1` and `path` are mutually exclusive** — Pkg asserts it
//!    on write (`:314`, JuliaLang/Pkg.jl#4086). A tree hash means "installed
//!    from a registry into the depot"; a path means "developed in place".
//!    Both at once makes the loader's answer depend on which branch it checks
//!    first. `destructure` returns `error.TreeHashAndPath`.
//!
//!  * **`deps`/`weakdeps` have two encodings and the choice is not free**
//!    (`:334-347`). An array of bare names is emitted only when every name is
//!    present in *this* manifest **and** unique there; otherwise a
//!    name → UUID table. Both appear in one real file: `ColorTypes` writes
//!    `weakdeps = ["StyledStrings"]` (in the manifest) while
//!    `ColorVectorSpace` writes a `[deps.ColorVectorSpace.weakdeps]` table for
//!    `SpecialFunctions` (not in the manifest — a weak dependency need not be
//!    installed). The loader accepts both (`base/loading.jl:1020, :1033,
//!    :1540`), so this only matters for round-trip stability — but getting it
//!    wrong rewrites half the file on the first `ajt add`.
//!
//!  * **`extensions` values are `String` *or* `Vector{String}`**
//!    (`base/loading.jl:1043-1045`), e.g.
//!    `VulkanFixedPointNumbersColorTypesExt = ["ColorTypes", "FixedPointNumbers"]`.
//!    Collapsing a one-element vector to a string, or vice versa, changes the
//!    file for no reason.
//!
//!  * **Unknown keys must survive.** Pkg keeps the whole raw entry table in
//!    `entry.other` and *starts writing from it* (`:316`), overwriting the
//!    keys it understands and deleting the ones whose model value is null.
//!    `PackageEntry.other` is that table; `destructure` shallow-clones it.
//!
//! ## Three places where Ajt deliberately does NOT match Pkg
//!
//! All three are data loss in Pkg, confirmed by running it, and the first two
//! would fail the byte-identity gate in
//! `tools/diff_harness/manifest_model.sh` (which diffs against a raw
//! `TOML.parsefile`/`TOML.print` round-trip, not against Pkg):
//!
//!  1. **`entryfile` is silently dropped by Pkg 1.12.6.** The read path
//!     (`:210-222`) never populates `entry.entryfile`, so `:326` deletes the
//!     key on the next write. But `base/loading.jl:1111-1113` *uses* the
//!     manifest's `entryfile` to find a package's entry point, so dropping it
//!     breaks loading for any package that set one. Oracle:
//!
//!     ```
//!     entryfile field = nothing
//!     destructured entry keys = ["git-tree-sha1", "unknown_key", "uuid", "version"]
//!     ```
//!
//!     (an entry written with `entryfile` comes back without it, while an
//!     unrelated unknown key survives). Ajt reads and re-emits it.
//!
//!  2. **App-level unknown keys are dropped by Pkg.** `destructure` builds a
//!     fresh dict per app (`:355-366`) instead of starting from
//!     `AppInfo.other`. Ajt starts from `other`, as it does for entries.
//!
//!  3. **Two entries sharing one UUID collapse in Pkg, nondeterministically.**
//!     Its model is `Dict{UUID, PackageEntry}` (`:156-158`), so the second
//!     `deps[uuid] = entry` overwrites the first and *which* one survives
//!     depends on `Dict` iteration order. Oracle: a file with `Foo` and `Bar`
//!     both at `1111…` reads back as ONE entry. `Manifest.entries` is a
//!     file-ordered slice instead, so nothing is dropped. Consequences:
//!     `findByUuid` and `validateGraph` resolve a UUID to the FIRST matching
//!     entry (Julia's `Dict` effectively resolves to the last), and both
//!     names count toward the `unique_name` histogram that picks the
//!     `deps` encoding. This only bites on an already-corrupt manifest.
//!
//! ## Allocation
//!
//! Everything here is arena-allocated with a manifest's lifetime: `parse`,
//! `fromToml` and `destructure` all take an `arena` and hand back values that
//! borrow from it (and, for `parse`, from the source text). There is nothing
//! to free individually and no `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const toml_parse = @import("../toml/parse.zig");
const toml_emit = @import("../toml/emit.zig");
const value_mod = @import("../toml/value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const slug = @import("../julia/slug.zig");
const version_mod = @import("../julia/version.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;
pub const Version = version_mod.Version;
pub const Diagnostic = toml_parse.Diagnostic;

pub const Error = error{
    /// The top level is not the shape a manifest has at all.
    MalformedManifest,
    /// A field Julia asserts is a `String` (`read_field`, `:173-183`) is not.
    ExpectedString,
    /// `pinned` must be a TOML boolean (`read_pinned`, `:186-190`).
    ExpectedBool,
    ExpectedTable,
    /// `read_field("uuid", ...)::UUID` (`:211`) — a missing `uuid` is a
    /// TypeError in Julia, i.e. every entry must carry one.
    MissingUuid,
    /// `:121-123` — the array form may not repeat a name.
    DuplicateDependency,
    /// `:136-141` — an array-form dep names a package that is absent from the
    /// manifest, or present more than once, so its UUID cannot be inferred.
    /// Julia's message is "should have used dict format instead of vector
    /// format", and it applies to `weakdeps` too.
    AmbiguousDependency,
    /// `:128-133` / `:166-171` — a strong dep points at a UUID with no entry.
    UnknownDependency,
    /// `:172-177` — a strong dep's name disagrees with the entry it points at.
    DependencyNameMismatch,
    /// `:314` — an entry carries both `git-tree-sha1` and `path`.
    TreeHashAndPath,
    /// `manifest_format` has a major other than 1 or 2. Julia only *warns* on
    /// read (`:190-196`), but `destructure`'s `if major == 1 / elseif major
    /// == 2` chain leaves `raw` unbound, so its writer dies with
    /// `UndefVarError: 'raw' not defined` (verified on 1.12.6). Ajt refuses
    /// explicitly rather than rewriting a layout it cannot vouch for.
    UnsupportedManifestFormat,
    /// An `apps` entry without `julia_command`; Julia substitutes the running
    /// julia's own path (`:357`), which Ajt refuses to bake into a file that
    /// is supposed to be portable.
    MissingJuliaCommand,
} || error{ InvalidUuid, InvalidSha1 } || version_mod.ParseError || toml_parse.Error;

/// One resolved dependency edge: a name plus the UUID it resolves to. Both
/// manifest encodings collapse to this (`normalize_deps`, `:119-145`).
pub const Dep = struct {
    name: []const u8,
    uuid: Uuid,
};

/// The right-hand side of an `extensions` entry. Julia's own field type is
/// `Dict{String, Union{Vector{String}, String}}` (`Types.jl:291`) and the
/// loader branches on it at `base/loading.jl:1034`, so the two forms are not
/// interchangeable.
pub const ExtTargets = union(enum) {
    /// `FooExt = "Bar"`
    one: []const u8,
    /// `FooExt = ["Bar", "Baz"]`
    many: []const []const u8,
};

pub const Extension = struct {
    name: []const u8,
    targets: ExtTargets,
};

/// `AppInfo` (`Types.jl:247-253`). Only `AppManifest.toml` uses this.
pub const AppInfo = struct {
    name: []const u8,
    /// Required on read (`read_apps`, `:259`).
    julia_command: []const u8,
    submodule: ?[]const u8 = null,
    julia_flags: []const []const u8 = &.{},
    /// Raw app table, for key passthrough. See the header: Pkg drops these.
    other: ?*Table = null,
};

/// `PackageEntry` (`Types.jl:281-295`) plus the `name` that is the key of the
/// `deps` table it lives under.
pub const PackageEntry = struct {
    name: []const u8,
    uuid: Uuid,
    version: ?Version = null,
    /// `git-tree-sha1`. Mutually exclusive with `path` — see `:314`.
    tree_hash: ?Sha1 = null,
    /// Emitted only when true (`:320`, `default = false`).
    pinned: bool = false,
    path: ?[]const u8 = null,
    entryfile: ?[]const u8 = null,
    repo_url: ?[]const u8 = null,
    repo_rev: ?[]const u8 = null,
    repo_subdir: ?[]const u8 = null,
    deps: []const Dep = &.{},
    weakdeps: []const Dep = &.{},
    exts: []const Extension = &.{},
    apps: []const AppInfo = &.{},
    /// The raw TOML table this entry was read from, kept verbatim so keys Ajt
    /// does not model survive a rewrite (`:228` stores it, `:316` writes from
    /// it). `destructure` shallow-clones it: only top-level keys are ever
    /// replaced, so nested values may be shared.
    other: ?*Table = null,
};

pub const Manifest = struct {
    /// `nothing` until something resolves the environment; omitted from the
    /// file entirely in that case (`:299-301`).
    julia_version: ?Version = null,
    project_hash: ?Sha1 = null,
    /// Parsed from the `manifest_format` string. Only `major`/`minor` are ever
    /// written back (`:305`). Major 1 selects the pre-1.6.2 layout where the
    /// deps table IS the document root.
    format: Version = .{ .major = 2, .minor = 0, .patch = 0 },
    /// Read order preserved. Julia keys these by UUID in a `Dict`, so ITS
    /// order is hash order; ours is the file's, which keeps `destructure`
    /// deterministic when two entries share a name.
    entries: []const PackageEntry = &.{},
    /// Top-level keys other than `julia_version`/`deps`/`manifest_format`
    /// (`:235-241`).
    ///
    /// TRAP: `project_hash` is NOT excluded there, so it lands in `other` too,
    /// and `:307-309` re-copies `other` over the value `:302-304` just wrote.
    /// Assigning `manifest.project_hash` and writing therefore has no effect
    /// in Pkg. Verified:
    ///
    /// ```
    /// m.project_hash = SHA1("000...0"); destructure(m)["project_hash"]
    ///   => "5e05dae87664a72319978725911531ada717de0f"   # the old one
    /// ```
    ///
    /// `destructure` reproduces that ordering exactly, so use
    /// `setProjectHash` — it updates both places.
    other: ?*Table = null,

    pub fn findByName(self: *const Manifest, name: []const u8) ?*const PackageEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn findByUuid(self: *const Manifest, uuid: Uuid) ?*const PackageEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, &e.uuid.bytes, &uuid.bytes)) return e;
        }
        return null;
    }

    /// Sets `project_hash` in BOTH the model and the `other` passthrough, so
    /// the write actually takes effect. See the `other` field's doc comment.
    /// `arena` must be the manifest's arena.
    ///
    /// No-op on a format-1 manifest: that layout has no top level to put it
    /// in, and `destructure` never writes one (`:295-296`).
    pub fn setProjectHash(self: *Manifest, arena: Allocator, hash: ?Sha1) Error!void {
        self.project_hash = hash;
        const o = self.other orelse blk: {
            const t = try Table.create(arena);
            self.other = t;
            break :blk t;
        };
        if (hash) |h| {
            try tset(arena, o, "project_hash", .{ .string = try fmtSha1(arena, h) });
        } else {
            try tdel(arena, o, "project_hash");
        }
    }

    /// Rebuilds the raw TOML table Julia would write (`destructure`,
    /// `:280-375`). Allocated from `arena`, which must outlive the result.
    pub fn destructure(self: *const Manifest, arena: Allocator) Error!*Table {
        // Julia's writer has branches for major 1 and 2 only, and falling off
        // the end leaves `raw` unbound — `manifest_format = "3.0"` warns on
        // read and then dies with `UndefVarError: 'raw' not defined` (verified
        // on 1.12.6). Refuse up front instead of guessing.
        if (self.format.major != 1 and self.format.major != 2) {
            return error.UnsupportedManifestFormat;
        }

        // `unique_name` (:289-292): true iff exactly one entry bears the name.
        // Note Julia's expression `unique_name[name] = !haskey(unique_name, name)`
        // flips back to `false` on the third sighting only because it is
        // already false; counting is the same predicate and easier to read.
        var counts: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.entries) |e| {
            const gop = try counts.getOrPut(arena, e.name);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }

        const root = try Table.create(arena);
        var deps_tbl = root;

        if (self.format.major != 1) {
            if (self.julia_version) |v| {
                try tset(arena, root, "julia_version", .{ .string = try fmtVersion(arena, v) });
            }
            if (self.project_hash) |h| {
                try tset(arena, root, "project_hash", .{ .string = try fmtSha1(arena, h) });
            }
            // Two components, not three (:305).
            try tset(arena, root, "manifest_format", .{
                .string = try std.fmt.allocPrint(arena, "{d}.{d}", .{ self.format.major, self.format.minor }),
            });
            try tset(arena, root, "deps", .{ .table = try Table.create(arena) });

            // Merged AFTER the fields above, exactly as Julia does (:307-309).
            if (self.other) |o| {
                for (o.entries.items) |e| try tset(arena, root, e.key, e.value);
            }
            // Julia re-reads `raw["deps"]` on every push (:371), so a `deps`
            // key smuggled in through `other` would win there too. Re-read.
            deps_tbl = switch (root.get("deps").?) {
                .table => |t| t,
                else => return error.MalformedManifest,
            };
            // ...but only an EMPTY one is usable. `fromToml` excludes `deps`
            // from `other` (:237), so this is unreachable via `parse`; a
            // hand-built model could still get here, and the loop below would
            // then skip slot allocation for a name that is already present and
            // trip over a missing cursor. Refuse rather than panic — and note
            // that writing into a table borrowed from someone else's document
            // would be a second, quieter bug.
            if (deps_tbl.count() != 0) return error.MalformedManifest;
        }

        // One array per distinct name, sized up front: appending to a
        // `[]Value` in an arena would leak a copy per push.
        var cursor: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.entries) |e| {
            if (deps_tbl.contains(e.name)) continue;
            const slot = try arena.alloc(Value, counts.get(e.name).?);
            try tset(arena, deps_tbl, e.name, .{ .array = slot });
            try cursor.put(arena, e.name, 0);
        }
        for (self.entries) |e| {
            const t = try entryTable(arena, &e, counts);
            const at = cursor.getPtr(e.name).?;
            const idx = deps_tbl.index.get(e.name).?;
            deps_tbl.entries.items[idx].value.array[at.*] = .{ .table = t };
            at.* += 1;
        }
        return root;
    }

    /// Renders the whole file, including the machine-generated banner Pkg
    /// writes (`:393`) and the `sorted = true` key order it uses (`:394`).
    /// `arena` holds the intermediate raw table; `gpa` is scratch for the
    /// emitter.
    pub fn write(self: *const Manifest, gpa: Allocator, arena: Allocator, w: *Writer) (Error || Writer.Error)!void {
        const raw = try self.destructure(arena);
        try w.writeAll(banner);
        try toml_emit.emit(gpa, w, raw, .{ .sorted = true });
    }
};

/// `write_manifest(io, raw_manifest)` (`:393`). Byte-exact, trailing blank
/// line included.
pub const banner = "# This file is machine-generated - editing it directly is not advised\n\n";

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// Parses a manifest from TOML source. Everything — including the intermediate
/// TOML document — is allocated from `arena`; the returned `Manifest` also
/// borrows from `src`, so both must outlive it.
pub fn parse(arena: Allocator, src: []const u8, diag: ?*Diagnostic) Error!Manifest {
    // The document's own arena is a child of `arena`, so it needs no deinit:
    // freeing `arena` frees it. Same trick as `registry/index.zig`.
    const doc = try toml_parse.parse(arena, src, diag);
    return fromToml(arena, doc.root);
}

/// `Base.is_v1_format_manifest` (`base/loading.jl:970-981`).
///
/// A manifest with no `manifest_format` key is the pre-1.6.2 layout, where the
/// document root IS the deps table. The `Dict` check exists for the
/// "off-chance where an old format manifest has a dep called manifest_format"
/// — reproduced as written, including the fact that a v1 dep is normally an
/// ARRAY of tables and so would not hit it anyway.
pub fn isV1Format(root: *const Table) bool {
    const mf = root.get("manifest_format") orelse return true;
    return switch (mf) {
        .table => |t| t.contains("uuid"),
        else => false,
    };
}

/// Builds the model from an already-parsed TOML table (`Manifest(raw, ...)`,
/// `:185-243`, plus `read_manifest`'s v1 conversion at `:257-263`). Allocates
/// from `arena` and borrows the table's strings, so both must outlive it.
pub fn fromToml(arena: Allocator, root: *const Table) Error!Manifest {
    var m: Manifest = .{};

    var deps_raw: ?*const Table = null;
    if (root.entries.items.len == 0) {
        // `read_manifest` (:257-261): "treat an empty Manifest file as v2
        // format for convenience". An empty file has no `manifest_format`, so
        // it looks v1 — and a freshly created environment is EXACTLY that
        // file. Without this the first write emits the pre-1.6.2 layout, and
        // stock Julia then reads it back with the "old format ... is being
        // maintained" warning (:383-385) and no `julia_version`/`project_hash`
        // at all. Oracle: an empty (or comment-only) file reads as format
        // 2.0.0 and writes `manifest_format = "2.0"` plus an empty `[deps]`.
        m.format = .{ .major = 2, .minor = 0, .patch = 0 };
        m.other = try Table.create(arena);
    } else if (isV1Format(root)) {
        // `convert_v1_format_manifest` (:270-277): the old root becomes `deps`
        // and the format becomes 1.0. `julia_version` is deliberately not set
        // — an old manifest does not record it.
        m.format = .{ .major = 1, .minor = 0, .patch = 0 };
        deps_raw = root;
    } else {
        m.format = try version_mod.parse(arena, try readString(root, "manifest_format") orelse
            return error.MalformedManifest);
        if (try readString(root, "julia_version")) |s| m.julia_version = try version_mod.parse(arena, s);
        if (try readString(root, "project_hash")) |s| m.project_hash = try Sha1.parse(s);

        // `deps` is absent when the environment has no dependencies (:198).
        if (root.get("deps")) |v| deps_raw = switch (v) {
            .table => |t| t,
            else => return error.MalformedManifest,
        };

        // Everything except the three keys at :237 — note `project_hash` is
        // NOT excluded, which is the trap documented on `Manifest.other`.
        const other = try Table.create(arena);
        for (root.entries.items) |e| {
            if (std.mem.eql(u8, e.key, "julia_version")) continue;
            if (std.mem.eql(u8, e.key, "deps")) continue;
            if (std.mem.eql(u8, e.key, "manifest_format")) continue;
            try tset(arena, other, e.key, e.value);
        }
        m.other = other;
    }

    // --- stage 1: entries with deps still in whichever form the file used ---
    const Stage1 = struct {
        entry: PackageEntry,
        deps: RawDeps,
        weakdeps: RawDeps,
    };
    var stage1: std.ArrayList(Stage1) = .empty;

    if (deps_raw) |dt| {
        for (dt.entries.items) |named| {
            const infos = switch (named.value) {
                .array => |a| a,
                else => return error.MalformedManifest,
            };
            for (infos) |info_v| {
                const info = switch (info_v) {
                    .table => |t| t,
                    else => return error.MalformedManifest,
                };
                var s: Stage1 = .{
                    .entry = .{
                        .name = named.key,
                        .uuid = undefined,
                        .other = info,
                    },
                    .deps = try readRawDeps(arena, info, "deps"),
                    .weakdeps = try readRawDeps(arena, info, "weakdeps"),
                };
                const e = &s.entry;
                e.uuid = try Uuid.parse(try readString(info, "uuid") orelse return error.MissingUuid);
                if (try readString(info, "version")) |x| e.version = try version_mod.parse(arena, x);
                if (try readString(info, "git-tree-sha1")) |x| e.tree_hash = try Sha1.parse(x);
                e.pinned = try readBool(info, "pinned") orelse false;
                // Julia additionally applies `safe_path` here (`:213`,
                // defined at `:232-238`), which rebuilds a RELATIVE path with
                // `\` separators on Windows. Identity on every platform Ajt
                // runs on — same caveat as `normalizePathForToml` on the
                // write side, and the same single place to fix.
                e.path = try readString(info, "path");
                // Not read by Pkg 1.12.6 — see the header, trap 1.
                e.entryfile = try readString(info, "entryfile");
                e.repo_url = try readString(info, "repo-url");
                e.repo_rev = try readString(info, "repo-rev");
                e.repo_subdir = try readString(info, "repo-subdir");
                e.exts = try readExtensions(arena, info);
                e.apps = try readApps(arena, info);
                try stage1.append(arena, s);
            }
        }
    }

    // --- resolve the array form against the manifest itself (:119-145) ------
    var by_name: std.StringHashMapUnmanaged(NameSlot) = .empty;
    for (stage1.items) |s| {
        const gop = try by_name.getOrPut(arena, s.entry.name);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
        } else {
            gop.value_ptr.* = .{ .count = 1, .uuid = s.entry.uuid };
        }
    }

    const entries = try arena.alloc(PackageEntry, stage1.items.len);
    for (stage1.items, 0..) |s, i| {
        entries[i] = s.entry;
        entries[i].deps = try normalizeDeps(arena, s.deps, by_name, false);
        entries[i].weakdeps = try normalizeDeps(arena, s.weakdeps, by_name, true);
    }
    m.entries = entries;

    try validateGraph(entries);
    return m;
}

const NameSlot = struct { count: u32, uuid: Uuid };

/// `deps`/`weakdeps` exactly as the file spelled them.
const RawDeps = union(enum) {
    /// Key absent — `read_deps(::Nothing)` yields an empty set (`:236`).
    none,
    /// `deps = ["A", "B"]` (`read_deps(::AbstractVector)`, `:238-245`).
    names: []const []const u8,
    /// `[deps.X.deps]` with `A = "<uuid>"` (`read_deps(::Dict)`, `:247-253`).
    pairs: []const Dep,
};

fn readRawDeps(arena: Allocator, info: *const Table, key: []const u8) Error!RawDeps {
    const v = info.get(key) orelse return .none;
    switch (v) {
        .array => |items| {
            // `::Union{Nothing, Dict{String,Any}, Vector{String}}` (:219-220)
            // is a TYPE assertion, and Julia's TOML parser gives an empty
            // array the type `Vector{Any}` — so `deps = []` is a hard
            // TypeError there, not an empty set. Verified. Accepting it would
            // let Ajt produce a model whose source file Pkg cannot read.
            if (items.len == 0) return error.MalformedManifest;
            const names = try arena.alloc([]const u8, items.len);
            for (items, 0..) |item, i| names[i] = switch (item) {
                .string => |s| s,
                else => return error.ExpectedString,
            };
            return .{ .names = names };
        },
        .table => |t| {
            const pairs = try arena.alloc(Dep, t.entries.items.len);
            for (t.entries.items, 0..) |e, i| {
                const s = switch (e.value) {
                    .string => |s| s,
                    else => return error.ExpectedString,
                };
                pairs[i] = .{ .name = e.key, .uuid = try Uuid.parse(s) };
            }
            return .{ .pairs = pairs };
        },
        // `read_deps(deps) = pkgerror("Expected `deps` field to be either a
        // list or a table.")` (:237).
        else => return error.MalformedManifest,
    }
}

/// `normalize_deps` (`:119-145`). The array form carries no UUIDs, so each
/// name is looked up in the manifest — which is why it is only legal when the
/// name is there exactly once.
fn normalizeDeps(arena: Allocator, raw: RawDeps, by_name: std.StringHashMapUnmanaged(NameSlot), is_ext: bool) Error![]const Dep {
    switch (raw) {
        .none => return &.{},
        .pairs => |p| return p,
        .names => |names| {
            for (names, 0..) |n, i| {
                for (names[i + 1 ..]) |o| {
                    if (std.mem.eql(u8, n, o)) return error.DuplicateDependency;
                }
            }
            const out = try arena.alloc(Dep, names.len);
            for (names, 0..) |n, i| {
                const slot = by_name.get(n) orelse {
                    // A strong dep that is not in the manifest is "no such
                    // entry exists" (:128-133); for `weakdeps` that check is
                    // skipped, but the ambiguity check below still fires — a
                    // weak dep outside the manifest MUST use the table form.
                    if (!is_ext) return error.UnknownDependency;
                    return error.AmbiguousDependency;
                };
                if (slot.count != 1) return error.AmbiguousDependency;
                out[i] = .{ .name = n, .uuid = slot.uuid };
            }
            return out;
        },
    }
}

/// The graph half of `validate_manifest` (`:160-181`): strong deps must point
/// at an entry that exists and whose name matches. Weak deps are exempt —
/// they routinely reference packages that were never installed.
fn validateGraph(entries: []const PackageEntry) Error!void {
    for (entries) |e| {
        for (e.deps) |d| {
            const target = for (entries) |*o| {
                if (std.mem.eql(u8, &o.uuid.bytes, &d.uuid.bytes)) break o;
            } else return error.UnknownDependency;
            if (!std.mem.eql(u8, target.name, d.name)) return error.DependencyNameMismatch;
        }
    }
}

/// `entry.exts = get(Dict{String, String}, info, "extensions")` (`:222`),
/// widened by the field's declared type to `String | Vector{String}`.
fn readExtensions(arena: Allocator, info: *const Table) Error![]const Extension {
    const v = info.get("extensions") orelse return &.{};
    const t = switch (v) {
        .table => |t| t,
        else => return error.ExpectedTable,
    };
    const out = try arena.alloc(Extension, t.entries.items.len);
    for (t.entries.items, 0..) |e, i| {
        out[i] = .{
            .name = e.key,
            .targets = switch (e.value) {
                .string => |s| .{ .one = s },
                .array => |items| blk: {
                    const many = try arena.alloc([]const u8, items.len);
                    for (items, 0..) |item, j| many[j] = switch (item) {
                        .string => |s| s,
                        else => return error.ExpectedString,
                    };
                    break :blk .{ .many = many };
                },
                else => return error.ExpectedString,
            },
        };
    }
    return out;
}

/// `read_apps` (`:255-278`).
fn readApps(arena: Allocator, info: *const Table) Error![]const AppInfo {
    const v = info.get("apps") orelse return &.{};
    const t = switch (v) {
        .table => |t| t,
        else => return error.ExpectedTable,
    };
    const out = try arena.alloc(AppInfo, t.entries.items.len);
    for (t.entries.items, 0..) |e, i| {
        const app = switch (e.value) {
            .table => |a| a,
            else => return error.ExpectedTable,
        };
        var flags: []const []const u8 = &.{};
        if (app.get("julia_flags")) |fv| {
            const items = switch (fv) {
                .array => |a| a,
                else => return error.MalformedManifest,
            };
            const buf = try arena.alloc([]const u8, items.len);
            for (items, 0..) |item, j| buf[j] = switch (item) {
                .string => |s| s,
                else => return error.ExpectedString,
            };
            flags = buf;
        }
        out[i] = .{
            .name = e.key,
            .julia_command = try readString(app, "julia_command") orelse return error.MissingJuliaCommand,
            .submodule = try readString(app, "submodule"),
            .julia_flags = flags,
            .other = app,
        };
    }
    return out;
}

/// `read_field(name, nothing, info, map)` (`:173-183`): absent yields null, a
/// non-string value is an error rather than a coercion.
fn readString(t: *const Table, key: []const u8) Error!?[]const u8 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

/// `read_pinned` (`:186-190`).
fn readBool(t: *const Table, key: []const u8) Error!?bool {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => error.ExpectedBool,
    };
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// One entry's raw table (`:312-372`).
fn entryTable(arena: Allocator, e: *const PackageEntry, counts: std.StringHashMapUnmanaged(u32)) Error!*Table {
    // JuliaLang/Pkg.jl#4086 (:314). A tree hash means "materialised from the
    // registry into the depot"; a path means "developed in place". With both,
    // which one wins depends on the reader.
    if (e.tree_hash != null and e.path != null) return error.TreeHashAndPath;

    const t = if (e.other) |o| try cloneShallow(arena, o) else try Table.create(arena);

    try tset(arena, t, "uuid", .{ .string = try fmtUuid(arena, e.uuid) });
    try setOrDelete(arena, t, "version", if (e.version) |v| try fmtVersion(arena, v) else null);
    try setOrDelete(arena, t, "git-tree-sha1", if (e.tree_hash) |h| try fmtSha1(arena, h) else null);
    // `entry!(..., "pinned", entry.pinned; default = false)` (:320).
    if (e.pinned) {
        try tset(arena, t, "pinned", .{ .boolean = true });
    } else {
        try tdel(arena, t, "pinned");
    }
    // `normalize_path_for_toml` (`utils.jl:48-53`) only rewrites separators on
    // Windows, and `isurl` at :328 only gates that same call, so on every
    // other platform both are the identity. Kept as a named no-op so the
    // Windows port has one place to touch.
    try setOrDelete(arena, t, "path", normalizePathForToml(e.path));
    try setOrDelete(arena, t, "entryfile", e.entryfile);
    try setOrDelete(arena, t, "repo-url", normalizePathForToml(e.repo_url));
    try setOrDelete(arena, t, "repo-rev", e.repo_rev);
    try setOrDelete(arena, t, "repo-subdir", e.repo_subdir);

    try writeDeps(arena, t, "deps", e.deps, counts);
    try writeDeps(arena, t, "weakdeps", e.weakdeps, counts);

    // Note the asymmetry with the fields above: Julia only ever SETS these two
    // (:350, :354) and never deletes, so an `extensions = {}` left in `other`
    // survives an otherwise-empty model. Reproduced.
    if (e.exts.len != 0) {
        const x = try Table.create(arena);
        for (e.exts) |ext| {
            try tset(arena, x, ext.name, switch (ext.targets) {
                .one => |s| Value{ .string = s },
                .many => |many| blk: {
                    const items = try arena.alloc(Value, many.len);
                    for (many, 0..) |s, i| items[i] = .{ .string = s };
                    break :blk Value{ .array = items };
                },
            });
        }
        try tset(arena, t, "extensions", .{ .table = x });
    }

    if (e.apps.len != 0) {
        const apps = try Table.create(arena);
        for (e.apps) |app| {
            // Julia builds this fresh (:358), dropping unknown app keys; we
            // start from `other` for the same reason entries do.
            const a = if (app.other) |o| try cloneShallow(arena, o) else try Table.create(arena);
            try tset(arena, a, "julia_command", .{ .string = app.julia_command });
            try setOrDelete(arena, a, "submodule", app.submodule);
            if (app.julia_flags.len != 0) {
                const items = try arena.alloc(Value, app.julia_flags.len);
                for (app.julia_flags, 0..) |s, i| items[i] = .{ .string = s };
                try tset(arena, a, "julia_flags", .{ .array = items });
            } else {
                try tdel(arena, a, "julia_flags");
            }
            try tset(arena, apps, app.name, .{ .table = a });
        }
        try tset(arena, t, "apps", .{ .table = apps });
    }

    return t;
}

/// The dual encoding (`:334-347`) — the subtlest rule in the format.
///
/// An array of bare names is only readable when the reader can recover each
/// UUID from the manifest, so it is emitted only when EVERY name is present
/// exactly once. Otherwise a name → UUID table. `counts` is the whole
/// manifest's name histogram, not this entry's.
fn writeDeps(
    arena: Allocator,
    t: *Table,
    key: []const u8,
    deps: []const Dep,
    counts: std.StringHashMapUnmanaged(u32),
) Error!void {
    if (deps.len == 0) return tdel(arena, t, key);

    var array_form = true;
    for (deps) |d| {
        const c = counts.get(d.name) orelse {
            array_form = false;
            break;
        };
        if (c != 1) {
            array_form = false;
            break;
        }
    }

    if (array_form) {
        // `sort(collect(keys(deptype)))` (:339).
        const names = try arena.alloc(Value, deps.len);
        for (deps, 0..) |d, i| names[i] = .{ .string = d.name };
        std.mem.sort(Value, names, {}, struct {
            fn lt(_: void, a: Value, b: Value) bool {
                return std.mem.lessThan(u8, a.string, b.string);
            }
        }.lt);
        try tset(arena, t, key, .{ .array = names });
    } else {
        const tbl = try Table.create(arena);
        for (deps) |d| try tset(arena, tbl, d.name, .{ .string = try fmtUuid(arena, d.uuid) });
        try tset(arena, t, key, .{ .table = tbl });
    }
}

/// `entry!` (`:281-287`): a null value DELETES the key rather than leaving
/// whatever `other` had there.
fn setOrDelete(arena: Allocator, t: *Table, key: []const u8, v: ?[]const u8) Error!void {
    if (v) |s| {
        try tset(arena, t, key, .{ .string = s });
    } else {
        try tdel(arena, t, key);
    }
}

/// `normalize_path_for_toml` (`utils.jl:48-53`). Identity off Windows.
fn normalizePathForToml(path: ?[]const u8) ?[]const u8 {
    if (@import("builtin").os.tag != .windows) return path;
    // Windows: relative paths are rewritten with forward slashes; absolute
    // ones are left alone because they are platform-specific anyway. Ajt does
    // not run there yet, so this is deliberately unimplemented rather than
    // half-implemented.
    return path;
}

// ---------------------------------------------------------------------------
// Table helpers
//
// `toml/value.zig`'s Table is append-only by design (TOML forbids duplicate
// keys, so the parser never needs upsert). `destructure` is a rewrite, not a
// parse, so it needs both upsert and delete.
// ---------------------------------------------------------------------------

fn tset(arena: Allocator, t: *Table, key: []const u8, v: Value) Allocator.Error!void {
    if (t.index.get(key)) |i| {
        t.entries.items[i].value = v;
        return;
    }
    try t.put(arena, key, v);
}

fn tdel(arena: Allocator, t: *Table, key: []const u8) Allocator.Error!void {
    const i = t.index.get(key) orelse return;
    _ = t.entries.orderedRemove(i);
    // Every index past `i` shifted down, so the side index is rebuilt whole.
    // Entries are single digits per manifest entry; this is not a hot path.
    t.index.clearRetainingCapacity();
    for (t.entries.items, 0..) |e, j| try t.index.put(arena, e.key, @intCast(j));
}

/// Only top-level keys are ever replaced in a cloned entry table, so nested
/// values may stay shared with the original.
fn cloneShallow(arena: Allocator, src: *const Table) Allocator.Error!*Table {
    const out = try Table.create(arena);
    // Inline-ness is part of how a table PRINTS (`emit.zig` honours it under
    // `respect_inline`), so it has to survive the clone or an entry written as
    // `deps.Foo = [{ uuid = "..." }]` would come back expanded while its
    // untouched nested tables stayed inline. The other flags
    // (`explicitly_defined`/`from_dotted_key`/`closed`) are parser bookkeeping
    // and mean nothing to a rebuilt table.
    out.is_inline = src.is_inline;
    for (src.entries.items) |e| try out.put(arena, e.key, e.value);
    return out;
}

// ---------------------------------------------------------------------------
// Scalar formatting — `string(::UUID)`, `string(::SHA1)`, `string(::VersionNumber)`
// as the closure at :394-397 applies them. All lowercase-canonical, which is
// also what normalises a hand-edited uppercase UUID on the next write.
// ---------------------------------------------------------------------------

const hex_digits = "0123456789abcdef";

pub fn formatUuid(u: Uuid, buf: *[36]u8) []const u8 {
    var i: usize = 0;
    for (u.bytes) |b| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex_digits[b >> 4];
        buf[i + 1] = hex_digits[b & 0x0F];
        i += 2;
    }
    return buf;
}

pub fn formatSha1(h: Sha1, buf: *[40]u8) []const u8 {
    for (h.bytes, 0..) |b, i| {
        buf[i * 2] = hex_digits[b >> 4];
        buf[i * 2 + 1] = hex_digits[b & 0x0F];
    }
    return buf;
}

fn fmtUuid(arena: Allocator, u: Uuid) Allocator.Error![]const u8 {
    var buf: [36]u8 = undefined;
    return arena.dupe(u8, formatUuid(u, &buf));
}

fn fmtSha1(arena: Allocator, h: Sha1) Allocator.Error![]const u8 {
    var buf: [40]u8 = undefined;
    return arena.dupe(u8, formatSha1(h, &buf));
}

fn fmtVersion(arena: Allocator, v: Version) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{v});
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parses `src`, re-emits it the way `Pkg.write_manifest` would minus the
/// banner, and returns the text. Caller frees.
fn roundTrip(gpa: Allocator, src: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try parse(arena, src, null);
    const raw = try m.destructure(arena);
    return toml_emit.emitAlloc(gpa, raw, .{ .sorted = true });
}

test "top-level shape: manifest_format has two components and null julia_version is omitted" {
    // Expectation generated by the oracle, not written by hand:
    //   julia> m = Pkg.Types.read_manifest(f); TOML.print(destructure(m), sorted=true)
    // Note `manifest_format = "2.0"` even though the input said "2.0.0"
    // (:305 writes major.minor only), and that no `julia_version` line appears.
    const out = try roundTrip(testing.allocator,
        \\manifest_format = "2.0.0"
        \\project_hash = "5e05dae87664a72319978725911531ada717de0f"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\project_hash = "5e05dae87664a72319978725911531ada717de0f"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , out);
}

test "deps is keyed by name and holds an array: two UUIDs may share one name" {
    // With `Foo` appearing twice, `unique_name["Foo"]` is false, so `Bar`'s
    // dependency on it can no longer be written as a bare name — it degrades
    // to the table form (:338). This is the whole reason the array exists.
    const out = try roundTrip(testing.allocator,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Foo]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
        \\[[deps.Bar]]
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
        \\    [deps.Bar.deps]
        \\    Foo = "11111111-1111-1111-1111-111111111111"
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Bar]]
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
        \\    [deps.Bar.deps]
        \\    Foo = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\[[deps.Foo]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
    , out);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try parse(arena_state.allocator(),
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Foo]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
    , null);
    try testing.expectEqual(@as(usize, 2), m.entries.len);
    try testing.expectEqualStrings("Foo", m.entries[0].name);
    try testing.expectEqualStrings("Foo", m.entries[1].name);
}

test "deps/weakdeps dual encoding: array iff every name is in the manifest and unique" {
    // The two real cases from Open-Reality/Manifest.toml, side by side:
    // `StyledStrings` IS an entry, so ColorTypes keeps the array form;
    // `SpecialFunctions` is not (a weak dep need not be installed), so
    // ColorVectorSpace must spell out the UUID.
    const out = try roundTrip(testing.allocator,
        \\manifest_format = "2.0"
        \\
        \\[[deps.ColorTypes]]
        \\uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
        \\weakdeps = ["StyledStrings"]
        \\
        \\[[deps.ColorVectorSpace]]
        \\uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
        \\
        \\    [deps.ColorVectorSpace.weakdeps]
        \\    SpecialFunctions = "276daf66-3868-5448-9aa4-cd146d93841b"
        \\
        \\[[deps.StyledStrings]]
        \\uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.ColorTypes]]
        \\uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
        \\weakdeps = ["StyledStrings"]
        \\
        \\[[deps.ColorVectorSpace]]
        \\uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
        \\
        \\    [deps.ColorVectorSpace.weakdeps]
        \\    SpecialFunctions = "276daf66-3868-5448-9aa4-cd146d93841b"
        \\
        \\[[deps.StyledStrings]]
        \\uuid = "f489334b-da3d-4c2e-b8f0-e476e12c162b"
        \\
    , out);
}

test "array-form deps are re-sorted and resolve to the manifest's UUIDs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.A]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\deps = ["C", "B"]
        \\
        \\[[deps.B]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
        \\[[deps.C]]
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
    , null);

    // The array form carries no UUIDs, so reading must recover them from the
    // manifest (:142) — that is what makes it legal only for unique names.
    const a = m.findByName("A").?;
    try testing.expectEqual(@as(usize, 2), a.deps.len);
    var buf: [36]u8 = undefined;
    try testing.expectEqualStrings("33333333-3333-3333-3333-333333333333", formatUuid(a.deps[0].uuid, &buf));

    const raw = try m.destructure(arena);
    const out = try toml_emit.emitAlloc(testing.allocator, raw, .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "deps = [\"B\", \"C\"]") != null);
}

test "extensions values may be a String or a Vector of Strings" {
    // `VulkanFixedPointNumbersColorTypesExt = ["ColorTypes", "FixedPointNumbers"]`
    // is the real shape (base/loading.jl:1043-1045); a one-element vector must
    // NOT collapse to a bare string.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Vulkan]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\    [deps.Vulkan.extensions]
        \\    OneExt = "ColorTypes"
        \\    OneElementVectorExt = ["ColorTypes"]
        \\    TwoExt = ["ColorTypes", "FixedPointNumbers"]
        \\
    ;
    const m = try parse(arena_state.allocator(), src, null);
    const v = m.findByName("Vulkan").?;
    try testing.expectEqual(@as(usize, 3), v.exts.len);
    try testing.expect(v.exts[0].targets == .one);
    try testing.expect(v.exts[1].targets == .many);
    try testing.expectEqual(@as(usize, 1), v.exts[1].targets.many.len);
    try testing.expectEqual(@as(usize, 2), v.exts[2].targets.many.len);

    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    // `OneElementVectorExt` sorts before `OneExt` ('E' < 'x'), so this is not
    // the input order. Taken from the oracle after the hand-written version
    // guessed wrong.
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Vulkan]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\    [deps.Vulkan.extensions]
        \\    OneElementVectorExt = ["ColorTypes"]
        \\    OneExt = "ColorTypes"
        \\    TwoExt = ["ColorTypes", "FixedPointNumbers"]
        \\
    , out);
}

test "unknown keys round-trip; entryfile survives (Pkg drops it)" {
    // Oracle for the divergence, from Julia 1.12.6:
    //   entryfile field = nothing
    //   destructured entry keys = ["git-tree-sha1", "unknown_key", "uuid", "version"]
    // i.e. Pkg keeps `unknown_key` but loses `entryfile`, even though
    // base/loading.jl:1111-1113 needs it to find the package's entry point.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\entryfile = "src/Other.jl"
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\unknown_key = "kept"
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "pinned is written only when true" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\pinned = false
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Bar]]
        \\pinned = true
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
    , null);
    try testing.expect(m.findByName("Bar").?.pinned);
    try testing.expect(!m.findByName("Foo").?.pinned);

    const raw = try m.destructure(arena);
    const out = try toml_emit.emitAlloc(testing.allocator, raw, .{ .sorted = true });
    defer testing.allocator.free(out);
    // `entry!(..., default = false)` DELETES the key, so an explicit
    // `pinned = false` in the input does not survive (:320).
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Bar]]
        \\pinned = true
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , out);
}

test "git-tree-sha1 and path may not coexist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reading is permissive (Julia's is too — the assert is on the WRITE side,
    // :314) so that a corrupt file can be inspected and repaired.
    const m = try parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\path = "."
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null);
    try testing.expectError(error.TreeHashAndPath, m.destructure(arena));
}

test "the path-only entry (a dev'd package) keeps its path" {
    // Open-Reality's own entry: `path = "."`, no tree hash.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.OpenReality]]
        \\deps = ["Ark"]
        \\path = "."
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "0.1.0"
        \\
        \\[[deps.Ark]]
        \\uuid = "56664e29-41e4-4ea5-ab0e-825499acc647"
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Ark]]
        \\uuid = "56664e29-41e4-4ea5-ab0e-825499acc647"
        \\
        \\[[deps.OpenReality]]
        \\deps = ["Ark"]
        \\path = "."
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "0.1.0"
        \\
    , out);
}

test "malformed entries are rejected the way Julia rejects them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Missing uuid: `read_field(...)::UUID` is a TypeError in Julia (:211).
    try testing.expectError(error.MissingUuid, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\version = "1.0.0"
        \\
    , null));

    // Array-form dep naming a package that is not in the manifest (:128-133).
    try testing.expectError(error.UnknownDependency, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\deps = ["Nope"]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null));

    // Same, but as a weakdep: the "no such entry" check is skipped for
    // extensions, yet the UUID still cannot be inferred (:136-141).
    try testing.expectError(error.AmbiguousDependency, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\weakdeps = ["Nope"]
        \\
    , null));

    // Duplicate name in the array form (:121-123).
    try testing.expectError(error.DuplicateDependency, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\deps = ["Bar", "Bar"]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\[[deps.Bar]]
        \\uuid = "22222222-2222-2222-2222-222222222222"
        \\
    , null));

    // Table-form dep pointing at a UUID that belongs to a different name
    // (:172-177).
    try testing.expectError(error.DependencyNameMismatch, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\    [deps.Foo.deps]
        \\    Bar = "33333333-3333-3333-3333-333333333333"
        \\
        \\[[deps.Baz]]
        \\uuid = "33333333-3333-3333-3333-333333333333"
        \\
    , null));

    // `pinned` must be a boolean, not the string "true" (:186-190).
    try testing.expectError(error.ExpectedBool, parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\pinned = "true"
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null));
}

test "setProjectHash beats the passthrough that would otherwise win" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try parse(arena,
        \\manifest_format = "2.0"
        \\project_hash = "5e05dae87664a72319978725911531ada717de0f"
        \\
    , null);

    // What Pkg does: the field is set, `other` still holds the old string, and
    // :307-309 copies it back over. Verified against Julia 1.12.6.
    //
    // The trailing `[deps]` is Julia's too: `raw["deps"]` is created
    // unconditionally at :306, so a dependency-free manifest still carries an
    // empty table. (Oracle, again after guessing wrong.)
    m.project_hash = try Sha1.parse("0000000000000000000000000000000000000000");
    {
        const raw = try m.destructure(arena);
        const out = try toml_emit.emitAlloc(testing.allocator, raw, .{ .sorted = true });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            \\manifest_format = "2.0"
            \\project_hash = "5e05dae87664a72319978725911531ada717de0f"
            \\
            \\[deps]
            \\
        , out);
    }

    try m.setProjectHash(arena, try Sha1.parse("0000000000000000000000000000000000000000"));
    {
        const raw = try m.destructure(arena);
        const out = try toml_emit.emitAlloc(testing.allocator, raw, .{ .sorted = true });
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            \\manifest_format = "2.0"
            \\project_hash = "0000000000000000000000000000000000000000"
            \\
            \\[deps]
            \\
        , out);
    }
}

test "write prepends the banner Pkg writes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null);

    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try m.write(testing.allocator, arena, &aw.writer);
    try testing.expectEqualStrings(
        "# This file is machine-generated - editing it directly is not advised\n" ++
            "\n" ++
            "manifest_format = \"2.0\"\n" ++
            "\n" ++
            "[[deps.Foo]]\n" ++
            "uuid = \"11111111-1111-1111-1111-111111111111\"\n",
        aw.written(),
    );
}

test "a v1 manifest is the deps table itself" {
    // `is_v1_format_manifest` (base/loading.jl:970-981) + the conversion at
    // Pkg manifest.jl:270-277. Writing keeps the format (:295-296, :368-369),
    // so a v1 file round-trips as v1 rather than being silently upgraded.
    const src =
        \\[[Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\version = "1.0.0"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try parse(arena_state.allocator(), src, null);
    try testing.expectEqual(@as(u64, 1), m.format.major);
    try testing.expectEqual(@as(usize, 1), m.entries.len);

    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an empty manifest is v2, not v1" {
    // The regression this guards: an empty file has no `manifest_format`, so
    // `is_v1_format_manifest` says v1 — but `read_manifest` special-cases it
    // (:257-261), because an empty Manifest.toml is what a freshly created
    // environment looks like. Getting this wrong makes the first write emit
    // the pre-1.6.2 layout that Julia warns about ever after.
    //
    // Oracle (Julia 1.12.6), for both an empty and a comment-only file:
    //   format = 2.0.0
    //   manifest_format = "2.0"
    //
    //   [deps]
    for ([_][]const u8{ "", "# nothing here\n", "\n\n" }) |src| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const m = try parse(arena_state.allocator(), src, null);
        try testing.expectEqual(@as(u64, 2), m.format.major);
        try testing.expectEqual(@as(usize, 0), m.entries.len);

        const out = try roundTrip(testing.allocator, src);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("manifest_format = \"2.0\"\n\n[deps]\n", out);
    }
}

test "an unknown manifest_format major is refused rather than rewritten" {
    // Julia warns on read (:190-196) and then its writer dies with
    // `UndefVarError: 'raw' not defined` (verified), because `destructure`
    // only has branches for major 1 and 2. Reading stays permissive so a
    // future-format file can still be inspected.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try parse(arena,
        \\manifest_format = "3.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null);
    try testing.expectEqual(@as(u64, 3), m.format.major);
    try testing.expectError(error.UnsupportedManifestFormat, m.destructure(arena));
}

test "an empty deps array is rejected, as Julia rejects it" {
    // `deps = []` parses as `Vector{Any}`, which fails the `Vector{String}`
    // type assertion at :219 with a TypeError. Verified. Silently treating it
    // as "no deps" would let Ajt emit a model whose source Pkg cannot load.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.MalformedManifest, parse(arena_state.allocator(),
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\deps = []
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null));
}

test "a deps table smuggled through `other` is refused, not tripped over" {
    // Unreachable through `parse` (:237 excludes `deps` from `other`), but
    // `Manifest` is a write model with public fields: without the guard the
    // slot-allocation loop skips a name that is already present and the fill
    // loop then unwraps a missing cursor.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = try parse(arena,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
    , null);

    const smuggled = try Table.create(arena);
    try tset(arena, smuggled, "Foo", .{ .integer = 1 });
    const other = try Table.create(arena);
    try tset(arena, other, "deps", .{ .table = smuggled });
    m.other = other;

    try testing.expectError(error.MalformedManifest, m.destructure(arena));
}

test "uuid and sha1 are re-emitted lowercase-canonical" {
    // `string(::UUID)` / `bytes2hex` are lowercase, so a hand-edited uppercase
    // UUID is normalised on the next write — same as Pkg.
    const out = try roundTrip(testing.allocator,
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\git-tree-sha1 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        \\uuid = "11111111-1111-1111-1111-AAAAAAAAAAAA"
        \\
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\uuid = "11111111-1111-1111-1111-aaaaaaaaaaaa"
        \\
    , out);
}

test "apps round-trip, including unknown app keys" {
    // AppManifest.toml only. Pkg rebuilds the app dict from scratch (:355-366)
    // and so loses `unknown_app_key`; Ajt keeps it.
    const src =
        \\manifest_format = "2.0"
        \\
        \\[[deps.Foo]]
        \\uuid = "11111111-1111-1111-1111-111111111111"
        \\
        \\    [deps.Foo.apps.foo]
        \\    julia_command = "/usr/bin/julia"
        \\    julia_flags = ["--startup-file=no"]
        \\    submodule = "FooApp"
        \\    unknown_app_key = "kept"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try parse(arena_state.allocator(), src, null);
    const foo = m.findByName("Foo").?;
    try testing.expectEqual(@as(usize, 1), foo.apps.len);
    try testing.expectEqualStrings("foo", foo.apps[0].name);
    try testing.expectEqualStrings("FooApp", foo.apps[0].submodule.?);
    try testing.expectEqual(@as(usize, 1), foo.apps[0].julia_flags.len);

    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}
