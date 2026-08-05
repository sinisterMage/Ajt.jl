//! `Project.toml` — read, validate, write.
//!
//! Port of `Pkg/src/project.jl` (the `Project` struct itself lives at
//! `Pkg/src/Types.jl:254-276`). Ajt has to be a *drop-in* replacement, so the
//! bar is not "understands Project.toml" but "produces the file Pkg would have
//! produced, byte for byte, and rejects exactly what Pkg rejects, with the same
//! message". Everything below is pinned against a running `julia` rather than
//! reasoned about; `tools/diff_harness/project_model.sh` is the gate.
//!
//! Four things bite, in rough order of how quietly they do it:
//!
//! **1. Unknown keys survive only by passthrough.** Julia keeps the whole raw
//! table in `Project.other` (`project.jl:217`) and `destructure` starts from
//! `deepcopy(project.other)`, overwriting only the sections it knows
//! (`:280-305`). `[extensions]`, `[apps]`, `authors`, `keywords`, `license`,
//! `desc` and every unrecognised key ride along in that copy — note that
//! `extensions` and `apps` are *read* into typed fields but never written back
//! from them, so a programmatic edit to `exts`/`apps` is silently dropped.
//! Ajt mirrors the structure exactly: `other` is the parsed root, and
//! `destructure` deep-copies it and patches the known sections in place.
//!
//! **2. `deps ∩ weakdeps` is split at parse time** (`:237-238`) and re-merged
//! at write time (`:286`). The intersection is over `Dict` *pairs*, so it only
//! fires when the name **and** the parsed UUID match — a name in both tables
//! with two different UUIDs stays in both, untouched. And because the split
//! empties the name out of `deps`, `[sources]` for such a package is rejected
//! (`listed_deps(...; include_weak=false)` no longer lists it) while `[compat]`
//! for it is fine. Both verified against Julia.
//!
//! **3. The write is key-ordered by `_project_key_order`** (`:309-311`) via
//! `TOML.print(...; by)`, and `by` is threaded through *every* nesting level of
//! the printer (`TOML/src/print.jl:205`). So a `[compat]` entry for a package
//! named `version` sorts ahead of `julia` inside `[compat]`. `toml/emit.zig`
//! has no `by` hook, so `destructure` returns its table already in that order
//! and the emitter runs with `sorted = false`; `[sources]` sub-tables are
//! flagged inline (`:318-325`), which is the one place `respect_inline` is on.
//!
//! **4. Writing normalises.** UUIDs round-trip through `Base.UUID` and print
//! lowercase; `version = "1.0"` becomes `"1.0.0"`; `path = ...` is *read* as
//! `entryfile` but the passthrough keeps the original key, so the file gains an
//! `entryfile` line and keeps its `path` line; an empty `[deps]`/`[sources]`
//! table is deleted. `[compat]` is the exception — `destructure` writes the
//! verbatim source string (`:304`), never the canonical `VersionSpec`
//! rendering, so `"0.4.0"` stays `"0.4.0"` even though it digests as `0.4` in
//! `project_hash`.
//!
//! Because normalisation is real, this model does **not** rewrite a file that
//! nobody changed: `pendingWrite` returns null while the project is clean, and
//! `serialize` hands back the original bytes, so comments, spacing and
//! non-canonical spellings survive an `ajt` invocation that had nothing to say.
//! (Pkg rewrites unconditionally and loses all three.) That is only worth
//! anything if "changed" is honest, so the mutators compare before they dirty:
//! adding a dep that is already present at the same UUID is a no-op, not a
//! reformat.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("../toml/value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const Entry = value_mod.Entry;
const Document = value_mod.Document;
const toml_parse = @import("../toml/parse.zig");
const toml_emit = @import("../toml/emit.zig");
const versions = @import("../julia/versions.zig");
const version_mod = @import("../julia/version.zig");
const Version = version_mod.Version;
const Uuid = @import("../julia/slug.zig").Uuid;

pub const Error = error{InvalidProject} || toml_parse.Error || Allocator.Error;

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Why a Project.toml was rejected. `message` reproduces Julia's `pkgerror`
/// text byte for byte (including the odd leading indentation and trailing
/// newlines that come from Julia's triple-quoted literals) so an Ajt error
/// reads exactly like the Pkg error a user already knows. `kind` is the
/// machine-readable form for callers that need to branch.
pub const Diagnostic = struct {
    kind: Kind = .none,
    buf: [1024]u8 = undefined,
    len: usize = 0,
    /// Populated instead of `kind` when the file was not valid TOML at all.
    toml: toml_parse.Diagnostic = .{},

    pub const Kind = enum {
        none,
        toml_syntax,
        // reading (project.jl:30-160)
        field_not_a_string,
        project_uuid_not_string,
        project_uuid_malformed,
        project_version_not_string,
        project_version_malformed,
        dep_section_not_a_table,
        dep_uuid_malformed,
        extensions_not_a_table,
        source_field_not_a_string,
        app_submodule_not_a_string,
        targets_not_a_table,
        target_not_a_list,
        compat_not_a_table,
        compat_not_a_string,
        compat_malformed,
        sources_not_a_table,
        source_not_a_table,
        source_invalid_key,
        source_path_and_url,
        workspace_not_a_table,
        workspace_invalid_key,
        workspace_entry_not_a_string,
        apps_not_a_table,
        app_not_a_table,
        app_julia_flags_not_strings,
        extension_trigger_not_a_string,
        // validating (project.jl:163-213)
        duplicate_dep_uuid,
        duplicate_weakdep_uuid,
        duplicate_extra_uuid,
        target_dep_named_twice,
        target_dep_not_listed,
        compat_not_listed,
        source_not_listed,
    };

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

pub const Dep = struct {
    name: []const u8,
    uuid: Uuid,
};

/// `Dict{String, UUID}` with a stable order.
///
/// Julia's `Dict` is unordered and the writer sorts anyway, so order is not
/// semantically load-bearing — it is kept because a deterministic model is far
/// easier to test, and because a caller that never mutates gets its own file's
/// order back from `entries`.
pub const DepMap = struct {
    entries: std.ArrayList(Dep) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn count(self: *const DepMap) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const DepMap, name: []const u8) ?Uuid {
        const i = self.index.get(name) orelse return null;
        return self.entries.items[i].uuid;
    }

    pub fn contains(self: *const DepMap, name: []const u8) bool {
        return self.index.contains(name);
    }

    /// Insert or replace; returns whether anything actually changed.
    ///
    /// Low-level and BORROWING: `name` is stored as given, so it must outlive
    /// the arena. The reader passes keys straight out of the parsed document
    /// (already arena-owned, so no copy); `Project.addDep` is the public door
    /// and copies first. `name` is only retained on insert — replacing an
    /// existing entry keeps the stored key.
    pub fn put(self: *DepMap, arena: Allocator, name: []const u8, uuid: Uuid) Allocator.Error!bool {
        if (self.index.get(name)) |i| {
            if (std.mem.eql(u8, &self.entries.items[i].uuid.bytes, &uuid.bytes)) return false;
            self.entries.items[i].uuid = uuid;
            return true;
        }
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(arena, .{ .name = name, .uuid = uuid });
        try self.index.put(arena, name, idx);
        return true;
    }

    /// Ordered removal, so the surviving entries keep their relative order.
    /// Returns whether anything was removed.
    pub fn remove(self: *DepMap, arena: Allocator, name: []const u8) Allocator.Error!bool {
        const i = self.index.get(name) orelse return false;
        _ = self.entries.orderedRemove(i);
        _ = self.index.remove(name);
        // Every entry after the hole shifted down by one.
        for (self.entries.items[i..], i..) |e, j| try self.index.put(arena, e.name, @intCast(j));
        return true;
    }
};

/// One `[compat]` entry. `str` is the source text and `spec` is
/// `semver_spec(str)`.
///
/// Both are kept because they are used in different places: `destructure`
/// writes `str` verbatim (`project.jl:304`) while the resolver and
/// `project_hash` use the canonical `spec`. Julia guards the pair with an
/// explicit consistency check before every write (`:266-271`); here the
/// invariant is structural instead — `setCompat` is the only way to set either,
/// so they cannot drift. Do not assign `spec` directly.
pub const Compat = struct {
    name: []const u8,
    str: []const u8,
    spec: versions.Spec,
};

pub const Target = struct {
    name: []const u8,
    deps: []const []const u8,
};

/// A `[sources]` entry. `read_project_sources` (`project.jl:125-142`) accepts
/// exactly these four keys, so the struct is lossless — nothing to pass
/// through.
pub const Source = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    subdir: ?[]const u8 = null,
};

/// An `[extensions]` entry. The TOML value is a string or a list of strings;
/// both are normalised to a trigger list here. Read-only in practice: nothing
/// writes `exts` back (see the module header), so this is a view onto `other`.
pub const Extension = struct {
    name: []const u8,
    triggers: []const []const u8,
};

/// An `[apps]` entry (`project.jl:85-107`). Also read-only — `destructure`
/// never writes it back.
pub const App = struct {
    name: []const u8,
    submodule: ?[]const u8 = null,
    julia_flags: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Project
// ---------------------------------------------------------------------------

pub const Project = struct {
    /// Owns the arena AND `root`, which is Julia's `Project.other`: the raw
    /// parsed table, untouched, carrying every key this model does not model.
    doc: Document,
    /// The bytes this was parsed from, copied into the arena. Kept so a clean
    /// project can be written back verbatim.
    source: []const u8,
    /// Path used in validation messages; Julia appends ` at "<file>".` to the
    /// six `validate` errors and to none of the read errors.
    file: ?[]const u8,
    /// Set by every mutator. While false, the file on disk is authoritative.
    dirty: bool = false,

    name: ?[]const u8 = null,
    uuid: ?Uuid = null,
    version: ?Version = null,
    manifest: ?[]const u8 = null,
    /// `read_project` takes this from `path` first and `entryfile` second
    /// (`project.jl:220-223`) but always *writes* it as `entryfile`.
    entryfile: ?[]const u8 = null,

    deps: DepMap = .{},
    /// `Project._deps_weak`: names that appeared in both `[deps]` and
    /// `[weakdeps]` with the same UUID. Removed from `deps` so they are ignored
    /// as direct dependencies, remembered so the write can put them back.
    deps_weak: DepMap = .{},
    weakdeps: DepMap = .{},
    extras: DepMap = .{},

    /// Keyed by `name`, which is unique because it came out of a TOML table.
    /// `setCompat` preserves that; pushing onto this list directly does not, and
    /// a duplicate name would make `setCompat` no-op against the FIRST entry
    /// while `destructure`'s last-write-wins emits the SECOND.
    compat: std.ArrayList(Compat) = .empty,
    targets: std.ArrayList(Target) = .empty,
    sources: std.ArrayList(Source) = .empty,
    exts: []const Extension = &.{},
    apps: []const App = &.{},
    /// `[workspace] projects`. Null when there is no workspace section, or an
    /// empty one — Julia deletes an empty `workspace` table on write either way.
    workspace_projects: ?[]const []const u8 = null,

    pub fn deinit(self: *Project) void {
        self.doc.deinit();
    }

    /// The arena everything in this project hangs off. Anything handed to a
    /// mutator must live at least this long.
    ///
    /// The returned `Allocator` closes over `&self.doc.arena`, so it is
    /// invalidated by moving the Project. Take it fresh each time rather than
    /// caching it in a struct.
    pub fn arena(self: *Project) Allocator {
        return self.doc.allocator();
    }

    /// `Project.other` — the raw parsed table. `project_hash.compute` takes
    /// exactly this.
    pub fn other(self: *const Project) *Table {
        return self.doc.root;
    }

    pub fn compatFor(self: *const Project, dep: []const u8) ?Compat {
        for (self.compat.items) |c| if (std.mem.eql(u8, c.name, dep)) return c;
        return null;
    }

    pub fn sourceFor(self: *const Project, dep: []const u8) ?Source {
        for (self.sources.items) |s| if (std.mem.eql(u8, s.name, dep)) return s;
        return null;
    }

    // -- mutators ------------------------------------------------------------
    //
    // Two rules hold for all of them, and both exist to protect the file on
    // disk:
    //
    //  * Every string argument is COPIED into the project's arena. A caller
    //    formatting a compat bound into a stack buffer is the natural thing to
    //    write, and borrowing it would put freed bytes straight into
    //    Project.toml with nothing to crash on.
    //  * `dirty` is set only when the value actually changed. `ajt add Foo`
    //    where Foo is already a dep must stay a no-op, or the write would
    //    reorder keys, lowercase UUIDs, expand `version = "1.0"` and drop every
    //    comment — the churn `pendingWrite` exists to avoid.
    //
    // None of them re-run `validate`: call it yourself before writing if the
    // edits could have broken an invariant.

    pub fn setName(self: *Project, new_name: ?[]const u8) Allocator.Error!void {
        if (eqlOptStr(self.name, new_name)) return;
        self.name = if (new_name) |n| try self.arena().dupe(u8, n) else null;
        self.dirty = true;
    }

    pub fn setUuid(self: *Project, new_uuid: ?Uuid) void {
        if (self.uuid) |old| {
            if (new_uuid) |new| if (std.mem.eql(u8, &old.bytes, &new.bytes)) return;
        } else if (new_uuid == null) return;
        self.uuid = new_uuid;
        self.dirty = true;
    }

    /// A `Version` borrows its string idents from whatever was parsed, so the
    /// idents are deep-copied here too — `v"1.0.0-alpha"` off a stack buffer
    /// would otherwise dangle exactly like a borrowed name.
    pub fn setVersion(self: *Project, new_version: ?Version) Allocator.Error!void {
        if (self.version) |old| {
            if (new_version) |new| if (old.eql(new)) return;
        } else if (new_version == null) return;
        self.version = if (new_version) |v| try dupeVersion(self.arena(), v) else null;
        self.dirty = true;
    }

    /// Sets `entryfile` — the absolute path to the module's entry `.jl`.
    ///
    /// `Pkg.Apps` is the only writer of this key: `_resolve` bolts it onto the
    /// copy of a package's project it puts in the app environment, so that
    /// environment can load the package from the depot without a `[deps]` entry
    /// for itself (`Apps.jl:167-171`).
    ///
    /// The read path takes `path` first and `entryfile` second and the write
    /// path always emits `entryfile` (`project.jl:220-223`, `:285`), so setting
    /// this on a project that was read from a `path` key leaves BOTH keys in
    /// the file — `path` survives in the passthrough. That is Pkg's behaviour
    /// and the module header covers it; it is only reachable on a project that
    /// already had `path`, which no registered package has.
    pub fn setEntryfile(self: *Project, new_entryfile: ?[]const u8) Allocator.Error!void {
        if (eqlOptStr(self.entryfile, new_entryfile)) return;
        self.entryfile = if (new_entryfile) |e| try self.arena().dupe(u8, e) else null;
        self.dirty = true;
    }

    pub fn addDep(self: *Project, name: []const u8, uuid: Uuid) Allocator.Error!void {
        // A name split into `_deps_weak` is still written into `[deps]` by the
        // merge (`project.jl:286`), so re-adding it at the same UUID changes
        // nothing on disk. Without this check `deps` and `deps_weak` would both
        // hold it and the file would be rewritten to produce identical content.
        if (self.deps_weak.get(name)) |w| {
            if (std.mem.eql(u8, &w.bytes, &uuid.bytes)) return;
        }
        const a = self.arena();
        // `put` only retains the key on insert, so copying is only needed then.
        const owned = if (self.deps.contains(name)) name else try a.dupe(u8, name);
        if (try self.deps.put(a, owned, uuid)) self.dirty = true;
    }

    /// Removes `name` from `deps` — and from `_deps_weak`, or the write would
    /// merge it straight back in (`project.jl:286`).
    pub fn removeDep(self: *Project, name: []const u8) Allocator.Error!bool {
        const a = self.arena();
        const gone = try self.deps.remove(a, name);
        const gone_weak = try self.deps_weak.remove(a, name);
        if (gone or gone_weak) self.dirty = true;
        return gone or gone_weak;
    }

    /// Sets `[compat] <name> = <spec_str>`, parsing `spec_str` with the
    /// **Project** grammar (`semver_spec`), not the registry one.
    pub fn setCompat(
        self: *Project,
        name: []const u8,
        spec_str: []const u8,
    ) (versions.ParseError || Allocator.Error)!void {
        for (self.compat.items) |c| {
            if (std.mem.eql(u8, c.name, name) and std.mem.eql(u8, c.str, spec_str)) return;
        }
        const a = self.arena();
        // Copy first, parse second, assign last: a malformed spec must leave
        // the model exactly as it was.
        const owned_str = try a.dupe(u8, spec_str);
        const spec = try versions.semverSpec(a, owned_str);
        for (self.compat.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) {
                // Dirty on the parsed SPEC, not on the string — because Pkg
                // does. `Base.:(==)(::Compat, ::Compat)` compares `val` alone
                // and ignores `str` (`Types.jl:244`), so `write_env`'s
                // `env.project != env.original_project` test (`:1336`) is
                // false for a bound that changed spelling but not meaning, and
                // the file is not rewritten at all. Verified against 1.12.6:
                // `Pkg.compat("A", "^1.2")` on `A = "1.2"` leaves the file
                // byte-identical, `"1.3"` rewrites it.
                //
                // The new string is still recorded, exactly as Pkg records it
                // — so a LATER edit that does dirty the project writes the new
                // spelling, which is what Pkg's `destructure` would emit too.
                if (!c.spec.eql(spec)) self.dirty = true;
                c.str = owned_str;
                c.spec = spec;
                return;
            }
        }
        try self.compat.append(a, .{
            .name = try a.dupe(u8, name),
            .str = owned_str,
            .spec = spec,
        });
        self.dirty = true;
    }

    pub fn removeCompat(self: *Project, name: []const u8) bool {
        for (self.compat.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) {
                _ = self.compat.orderedRemove(i);
                self.dirty = true;
                return true;
            }
        }
        return false;
    }

    pub fn setSource(self: *Project, src: Source) Allocator.Error!void {
        // Compare BEFORE copying. An arena never frees, so duping first meant a
        // no-op `setSource` in a loop grew the project without bound (measured:
        // 5 KB -> 110 KB over 20k no-op rounds).
        for (self.sources.items) |s| {
            if (std.mem.eql(u8, s.name, src.name) and eqlSource(s, src)) return;
        }
        const a = self.arena();
        const owned: Source = .{
            .name = try a.dupe(u8, src.name),
            .path = if (src.path) |x| try a.dupe(u8, x) else null,
            .url = if (src.url) |x| try a.dupe(u8, x) else null,
            .rev = if (src.rev) |x| try a.dupe(u8, x) else null,
            .subdir = if (src.subdir) |x| try a.dupe(u8, x) else null,
        };
        for (self.sources.items) |*s| {
            if (std.mem.eql(u8, s.name, src.name)) {
                s.* = owned;
                self.dirty = true;
                return;
            }
        }
        try self.sources.append(a, owned);
        self.dirty = true;
    }

    pub fn removeSource(self: *Project, name: []const u8) bool {
        for (self.sources.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) {
                _ = self.sources.orderedRemove(i);
                self.dirty = true;
                return true;
            }
        }
        return false;
    }

    // -- writing -------------------------------------------------------------

    /// The bytes that should end up on disk, or null when the file already
    /// holds them — in which case the caller must not open the file at all.
    ///
    /// This is the whole reason the model keeps `source`. Pkg rewrites
    /// unconditionally, so a no-op `Pkg.instantiate` can reorder keys, lowercase
    /// a UUID and drop every comment. Ajt only writes when it has something to
    /// say. Caller owns the returned slice.
    pub fn pendingWrite(self: *const Project, gpa: Allocator) Error!?[]u8 {
        if (!self.dirty) return null;
        return try self.render(gpa);
    }

    /// The full contents of the file, whether or not anything changed: the
    /// ORIGINAL bytes while clean, `render` once dirty. Caller owns the slice.
    ///
    /// Use this when the destination is not the file it was read from (a
    /// `--output`, a tarball, a diff) and skipping the write is not an option;
    /// use `pendingWrite` when it is.
    pub fn serialize(self: *const Project, gpa: Allocator) Error![]u8 {
        if (!self.dirty) return gpa.dupe(u8, self.source);
        return try self.render(gpa);
    }

    /// `write_project` (`project.jl:313-331`): `destructure`, then
    /// `TOML.print(..., sorted = true, by = project_key_order)` with the
    /// `[sources]` sub-tables inline. Caller owns the returned slice.
    pub fn render(self: *const Project, gpa: Allocator) Error![]u8 {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const raw = try self.destructure(scratch.allocator());
        // `sorted = false` is not a bug: `destructure` has already put every
        // table in `by` order, which `Options.sorted` cannot express.
        //
        // The sink is an Allocating writer, so its only failure mode is a
        // failed allocation; fold WriteFailed back into OutOfMemory rather than
        // leak an unreachable error into the public set.
        return toml_emit.emitAlloc(gpa, raw, .{ .sorted = false, .respect_inline = true }) catch |err| switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => |e| e,
        };
    }

    /// `destructure` (`project.jl:263-307`) plus the key ordering the printer
    /// would otherwise apply.
    ///
    /// Takes an **arena**: the result is a whole tree of tables used and dropped
    /// together, and it *borrows* every string from `self`, so the arena must
    /// not outlive the project.
    pub fn destructure(self: *const Project, scratch: Allocator) Allocator.Error!*Table {
        const raw = try copyTable(scratch, self.doc.root);

        try entryStr(scratch, raw, "name", self.name);
        try entryStr(scratch, raw, "uuid", if (self.uuid) |u| try formatUuid(scratch, u) else null);
        try entryStr(scratch, raw, "version", if (self.version) |v| try formatVersion(scratch, v) else null);
        try entryStr(scratch, raw, "manifest", self.manifest);
        try entryStr(scratch, raw, "entryfile", self.entryfile);

        // `merge(project.deps, project._deps_weak)` — the weak split undone.
        const deps_tbl = try Table.create(scratch);
        for ([_]*const DepMap{ &self.deps, &self.deps_weak }) |m| {
            for (m.entries.items) |d| {
                try tableSet(scratch, deps_tbl, d.name, .{ .string = try formatUuid(scratch, d.uuid) });
            }
        }
        try entryTable(scratch, raw, "deps", deps_tbl);
        try entryTable(scratch, raw, "weakdeps", try depTable(scratch, &self.weakdeps));

        const sources_tbl = try Table.create(scratch);
        for (self.sources.items) |s| {
            const st = try Table.create(scratch);
            // The one place `respect_inline` matters: `write_project` pushes
            // every source table into `inline_tables` (project.jl:318-325).
            st.is_inline = true;
            // NB `normalize_path_for_toml` (Pkg/src/utils.jl:48-53) only does
            // anything on Windows, where it flips separators on a relative
            // path. Nothing to do here, and doing it unconditionally would
            // corrupt a POSIX path that legitimately contains a backslash.
            if (s.path) |p| try tableSet(scratch, st, "path", .{ .string = p });
            if (s.url) |u| try tableSet(scratch, st, "url", .{ .string = u });
            if (s.rev) |r| try tableSet(scratch, st, "rev", .{ .string = r });
            if (s.subdir) |d| try tableSet(scratch, st, "subdir", .{ .string = d });
            try tableSet(scratch, sources_tbl, s.name, .{ .table = st });
        }
        try entryTable(scratch, raw, "sources", sources_tbl);
        try entryTable(scratch, raw, "extras", try depTable(scratch, &self.extras));

        const compat_tbl = try Table.create(scratch);
        for (self.compat.items) |c| {
            // The SOURCE string, not `c.spec` rendered (project.jl:304).
            try tableSet(scratch, compat_tbl, c.name, .{ .string = c.str });
        }
        try entryTable(scratch, raw, "compat", compat_tbl);

        const targets_tbl = try Table.create(scratch);
        for (self.targets.items) |t| {
            const items = try scratch.alloc(Value, t.deps.len);
            for (t.deps, 0..) |d, i| items[i] = .{ .string = d };
            try tableSet(scratch, targets_tbl, t.name, .{ .array = items });
        }
        try entryTable(scratch, raw, "targets", targets_tbl);

        const ws_tbl = try Table.create(scratch);
        if (self.workspace_projects) |projects| {
            const items = try scratch.alloc(Value, projects.len);
            for (projects, 0..) |p, i| items[i] = .{ .string = p };
            try tableSet(scratch, ws_tbl, "projects", .{ .array = items });
        }
        try entryTable(scratch, raw, "workspace", ws_tbl);

        try sortTable(scratch, raw);
        return raw;
    }

    // -- validation ----------------------------------------------------------

    /// `validate` (`project.jl:163-213`). Re-runnable after mutation.
    pub fn validate(self: *const Project, gpa: Allocator, diag: ?*Diagnostic) Error!void {
        var v: Validator = .{ .p = self, .gpa = gpa, .diag = diag };
        return v.run();
    }
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Reported in validation messages, exactly as `read_project`'s `file=`.
    /// Must outlive the returned `Project`.
    file: ?[]const u8 = null,
    /// Julia's `read_project` runs `validate` unconditionally; turning it off
    /// is for tooling that wants to *report* on a broken file rather than
    /// refuse it.
    validate: bool = true,
};

/// Parses and validates a Project.toml. `source` is copied into the project's
/// arena, so the caller may free it immediately.
pub fn parse(gpa: Allocator, source: []const u8, opts: Options, diag: ?*Diagnostic) Error!Project {
    var sink: Diagnostic = .{};
    const d = diag orelse &sink;

    const doc = toml_parse.parse(gpa, source, &d.toml) catch |err| switch (err) {
        error.ParseFailed => {
            d.kind = .toml_syntax;
            const written = std.fmt.bufPrint(
                &d.buf,
                "Could not parse project: line {d}, column {d}: {s}",
                .{ d.toml.line, d.toml.column, d.toml.message },
            ) catch d.buf[0..0];
            d.len = written.len;
            return error.ParseFailed;
        },
        else => |e| return e,
    };

    // The Project is built FIRST and every allocation goes through `p.doc`,
    // never through the `doc` temporary. `ArenaAllocator.allocator()` closes
    // over `&self`, so allocating through a copy that is about to be
    // overwritten records the new buffers in the wrong struct and the ones
    // added after the copy are simply never freed. (Cost of learning this the
    // usual way: four leaked allocations and a confusing stack trace.)
    var p: Project = .{ .doc = doc, .source = "", .file = opts.file };
    errdefer p.doc.deinit();
    const a = p.doc.allocator();
    p.source = try a.dupe(u8, source);

    var r: Reader = .{ .p = &p, .arena = a, .diag = d };
    try r.run();
    if (opts.validate) try p.validate(gpa, d);
    // Returning by value copies the arena struct once more, but every
    // allocation is already recorded in `p.doc.state` by now, so the copy is
    // complete. The corollary for callers: an `Allocator` obtained from
    // `arena()` dangles if the Project is subsequently moved.
    return p;
}

/// An empty project — `read_project` returns this for a file that does not
/// exist (`project.jl:248`).
pub fn empty(gpa: Allocator) Allocator.Error!Project {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try Table.create(a);
    return .{
        .doc = .{ .arena = arena, .root = root },
        .source = "",
        .file = null,
    };
}

const Reader = struct {
    p: *Project,
    arena: Allocator,
    diag: *Diagnostic,

    fn run(self: *Reader) Error!void {
        const raw = self.p.doc.root;

        self.p.name = try self.optString(raw, "name");
        self.p.manifest = try self.optString(raw, "manifest");
        // `path` wins over `entryfile` (project.jl:220-223). Because `path`
        // also survives in `other`, a project written with `path` comes back
        // with BOTH keys — Julia does this too; verified against the oracle.
        self.p.entryfile = try self.optString(raw, "path") orelse try self.optString(raw, "entryfile");

        if (raw.get("uuid")) |v| {
            const s = switch (v) {
                .string => |s| s,
                // read_project_uuid(uuid) — the catch-all method.
                else => return self.fail(
                    .project_uuid_not_string,
                    "Expected project UUID to be a string",
                    .{},
                ),
            };
            self.p.uuid = Uuid.parse(s) catch return self.fail(
                .project_uuid_malformed,
                "Could not parse project UUID as a UUID",
                .{},
            );
        }

        if (raw.get("version")) |v| {
            const s = switch (v) {
                .string => |s| s,
                else => return self.fail(
                    .project_version_not_string,
                    "Expected project version to be a string",
                    .{},
                ),
            };
            self.p.version = version_mod.parse(self.arena, s) catch return self.fail(
                .project_version_malformed,
                "Could not parse project version as a version",
                .{},
            );
        }

        try self.readDeps(&self.p.deps, "deps");
        try self.readDeps(&self.p.weakdeps, "weakdeps");
        try self.readExtensions();
        try self.readSources();
        try self.readDeps(&self.p.extras, "extras");
        try self.readCompat();
        try self.readTargets();
        try self.readWorkspace();
        try self.readApps();
        try self.splitWeakDeps();
    }

    /// `get(raw, k, nothing)::Union{String, Nothing}` (`project.jl:218-223`).
    ///
    /// A non-string here is a hard error, not "absent". Julia raises a bare
    /// `TypeError: in typeassert, expected Union{Nothing, String}, ...` — there
    /// is no pkgerror to copy, so the message below is in the style of its
    /// siblings. Treating it as absent instead would be worse than a wording
    /// mismatch: `destructure` would then DELETE the key from the passthrough
    /// copy and the write would silently drop data from a file Pkg refuses to
    /// load at all.
    fn optString(self: *Reader, t: *const Table, key: []const u8) Error!?[]const u8 {
        const v = t.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => self.fail(.field_not_a_string, "Expected `{s}` to be a string", .{key}),
        };
    }

    /// `read_project_deps` (`project.jl:53-69`).
    fn readDeps(self: *Reader, out: *DepMap, section: []const u8) Error!void {
        const v = self.p.doc.root.get(section) orelse return;
        const t = switch (v) {
            .table => |t| t,
            else => return self.fail(
                .dep_section_not_a_table,
                "Expected `{s}` section to be a key-value list",
                .{section},
            ),
        };
        for (t.entries.items) |e| {
            // `read_project_deps` calls `UUID(uuid)` with no type guard, and
            // `UUID(::Integer)` exists — so Julia genuinely accepts `A = 1`,
            // `A = true` and `A = 1.0` here and writes them back as
            // 00000000-0000-0000-0000-000000000001. Reproduced so the
            // round-trip does not diverge on a file Pkg would load. A negative
            // or fractional number is an InexactError there and an error here.
            const uuid = switch (e.value) {
                .string => |s| Uuid.parse(s) catch return self.failDepUuid(e.key, section),
                .integer => |n| if (n >= 0) uuidFromInt(@intCast(n)) else return self.failDepUuid(e.key, section),
                .boolean => |b| uuidFromInt(@intFromBool(b)),
                .float => |f| blk: {
                    // `UInt128(f)` is an InexactError for NaN, ±Inf, a
                    // fraction, a negative, or anything >= 2^128 — and nothing
                    // else. `!(f >= 0)` rather than `f < 0` so NaN lands on the
                    // reject side. Verified: `A = 1e20` is legal in Pkg and
                    // digests as 00000000-0000-0005-6bc7-5e2d63100000.
                    if (!(f >= 0) or f != @floor(f) or f >= 340282366920938463463374607431768211456.0) {
                        return self.failDepUuid(e.key, section);
                    }
                    break :blk uuidFromInt(@intFromFloat(f));
                },
                else => return self.failDepUuid(e.key, section),
            };
            _ = try out.put(self.arena, e.key, uuid);
        }
    }

    fn failDepUuid(self: *Reader, name: []const u8, section: []const u8) error{ InvalidProject, OutOfMemory } {
        return self.fail(
            .dep_uuid_malformed,
            "Malformed value for `{s}` in `{s}` section.",
            .{ name, section },
        );
    }

    /// `project.exts = get(Dict{String,String}, raw, "extensions")`
    /// (`project.jl:228`). The declared field type is
    /// `Dict{String, Union{Vector{String}, String}}`, so a scalar and a list of
    /// triggers are both legal and anything else fails to convert.
    fn readExtensions(self: *Reader) Error!void {
        const v = self.p.doc.root.get("extensions") orelse return;
        const t = switch (v) {
            .table => |t| t,
            // `convert(Dict{String,...}, 1)` — a MethodError in Julia, so this
            // file does not load there either.
            else => return self.fail(
                .extensions_not_a_table,
                "Expected `extensions` section to be a key-value list",
                .{},
            ),
        };
        var list: std.ArrayList(Extension) = .empty;
        for (t.entries.items) |e| {
            const triggers: []const []const u8 = switch (e.value) {
                .string => |s| blk: {
                    const one = try self.arena.alloc([]const u8, 1);
                    one[0] = s;
                    break :blk one;
                },
                .array => |items| blk: {
                    // Same Vector{Any} narrowing trap as [targets]: `[]` does
                    // not convert to Union{String, Vector{String}} either.
                    if (items.len == 0) return self.failExtension(e.key);
                    const many = try self.arena.alloc([]const u8, items.len);
                    for (items, 0..) |item, i| many[i] = switch (item) {
                        .string => |s| s,
                        else => return self.failExtension(e.key),
                    };
                    break :blk many;
                },
                else => return self.failExtension(e.key),
            };
            try list.append(self.arena, .{ .name = e.key, .triggers = triggers });
        }
        self.p.exts = list.items;
    }

    fn failExtension(self: *Reader, name: []const u8) error{ InvalidProject, OutOfMemory } {
        return self.fail(
            .extension_trigger_not_a_string,
            "Expected trigger for extension `{s}` to be a string",
            .{name},
        );
    }

    /// `read_project_sources` (`project.jl:125-142`).
    fn readSources(self: *Reader) Error!void {
        const v = self.p.doc.root.get("sources") orelse return;
        const t = switch (v) {
            .table => |t| t,
            // read_project_sources has no fallback method, so a scalar
            // `sources` is a MethodError in Julia rather than a pkgerror; give
            // it the shape of its sibling messages.
            else => return self.fail(
                .sources_not_a_table,
                "Expected `sources` section to be a key-value list",
                .{},
            ),
        };
        for (t.entries.items) |e| {
            const st = switch (e.value) {
                .table => |st| st,
                else => return self.fail(
                    .source_not_a_table,
                    "Expected `source` section to be a table",
                    .{},
                ),
            };
            // THREE passes, in Julia's order, because a source table with two
            // faults must report the one Julia reports. `read_project_sources`
            // (project.jl:133-138) scans the keys and checks the conflict; the
            // string typing only happens later, at assignment
            // (project.jl:236 -> `Dict{String, Dict{String, String}}`,
            // Types.jl:274). Typing inside the key loop made
            // `{branch = 1}` and `{path = 1, url = "u"}` report the type error
            // instead of the invalid key / conflict Julia reports.
            for (st.entries.items) |f| {
                const valid = std.mem.eql(u8, f.key, "path") or
                    std.mem.eql(u8, f.key, "url") or
                    std.mem.eql(u8, f.key, "rev") or
                    std.mem.eql(u8, f.key, "subdir");
                if (!valid) return self.fail(
                    .source_invalid_key,
                    "Invalid key `{s}` in `source` section",
                    .{f.key},
                );
            }
            // Note `url` and `rev` together are fine; only `path` conflicts.
            if (st.contains("path") and (st.contains("url") or st.contains("rev"))) {
                return self.fail(
                    .source_path_and_url,
                    "Both `path` and `url` or `rev` are specified in `source` section",
                    .{},
                );
            }
            var s: Source = .{ .name = e.key };
            for (st.entries.items) |f| {
                // A non-string field is a conversion error in Julia. Refusing
                // matters: silently nulling it would let `destructure` write
                // the source back as `{}`.
                const fv: []const u8 = switch (f.value) {
                    .string => |x| x,
                    else => return self.fail(
                        .source_field_not_a_string,
                        "Expected `{s}` for source `{s}` to be a string",
                        .{ f.key, e.key },
                    ),
                };
                if (std.mem.eql(u8, f.key, "path")) {
                    s.path = fv;
                } else if (std.mem.eql(u8, f.key, "url")) {
                    s.url = fv;
                } else if (std.mem.eql(u8, f.key, "rev")) {
                    s.rev = fv;
                } else {
                    s.subdir = fv;
                }
            }
            try self.p.sources.append(self.arena, s);
        }
    }

    /// `read_project_compat` (`project.jl:109-123`).
    fn readCompat(self: *Reader) Error!void {
        const v = self.p.doc.root.get("compat") orelse return;
        const t = switch (v) {
            .table => |t| t,
            else => return self.fail(
                .compat_not_a_table,
                "Expected `compat` section to be a key-value list",
                .{},
            ),
        };
        for (t.entries.items) |e| {
            const s = switch (e.value) {
                .string => |s| s,
                // `version::String` sits OUTSIDE Julia's try block, so this is
                // a raw TypeError there, not the "Could not parse" pkgerror.
                else => return self.fail(
                    .compat_not_a_string,
                    "Expected compatibility version for dependency `{s}` to be a string",
                    .{e.key},
                ),
            };
            // The PROJECT grammar. `semverSpec`, not `Spec.parse` — the
            // registry's `"1-2"` is an error here and `"^0.4, 0.5"` is not.
            const spec = versions.semverSpec(self.arena, s) catch return self.fail(
                .compat_malformed,
                "Could not parse compatibility version for dependency `{s}`",
                .{e.key},
            );
            try self.p.compat.append(self.arena, .{ .name = e.key, .str = s, .spec = spec });
        }
    }

    /// `read_project_targets` (`project.jl:71-83`).
    fn readTargets(self: *Reader) Error!void {
        const v = self.p.doc.root.get("targets") orelse return;
        const t = switch (v) {
            .table => |t| t,
            else => return self.fail(
                .targets_not_a_table,
                "Expected `targets` section to be a key-value list",
                .{},
            ),
        };
        for (t.entries.items) |e| {
            const items = switch (e.value) {
                // An EMPTY array is rejected: Julia's TOML parser narrows
                // `["a"]` to Vector{String} but leaves `[]` as Vector{Any},
                // which fails `deps isa Vector{String}` (project.jl:74).
                .array => |items| if (items.len == 0) return self.failTargetShape(e.key) else items,
                else => return self.failTargetShape(e.key),
            };
            const deps = try self.arena.alloc([]const u8, items.len);
            for (items, 0..) |item, i| deps[i] = switch (item) {
                .string => |s| s,
                else => return self.failTargetShape(e.key),
            };
            try self.p.targets.append(self.arena, .{ .name = e.key, .deps = deps });
        }
    }

    /// Julia's triple-quoted literal dedents to four leading spaces and keeps
    /// its trailing newline. Faithfully ugly.
    fn failTargetShape(self: *Reader, target: []const u8) error{ InvalidProject, OutOfMemory } {
        return self.fail(
            .target_not_a_list,
            "    Expected value for target `{s}` to be a list of dependency names.\n",
            .{target},
        );
    }

    /// `read_project_workspace` (`project.jl:144-160`).
    fn readWorkspace(self: *Reader) Error!void {
        const v = self.p.doc.root.get("workspace") orelse return;
        const t = switch (v) {
            .table => |t| t,
            else => return self.fail(
                .workspace_not_a_table,
                "Expected `workspace` section to be a key-value list",
                .{},
            ),
        };
        for (t.entries.items) |e| {
            if (!std.mem.eql(u8, e.key, "projects")) {
                return self.fail(.workspace_invalid_key, "Invalid key `{s}` in `workspace`", .{e.key});
            }
            const items = switch (e.value) {
                .array => |items| items,
                else => return self.failWorkspaceEntry(),
            };
            const projects = try self.arena.alloc([]const u8, items.len);
            for (items, 0..) |item, i| projects[i] = switch (item) {
                .string => |s| s,
                else => return self.failWorkspaceEntry(),
            };
            self.p.workspace_projects = projects;
        }
    }

    fn failWorkspaceEntry(self: *Reader) error{ InvalidProject, OutOfMemory } {
        return self.fail(
            .workspace_entry_not_a_string,
            "Expected entry in `projects` to be strings",
            .{},
        );
    }

    /// `read_project_apps` (`project.jl:85-107`).
    fn readApps(self: *Reader) Error!void {
        const v = self.p.doc.root.get("apps") orelse return;
        const t = switch (v) {
            .table => |t| t,
            else => return self.fail(
                .apps_not_a_table,
                "Expected `apps` section to be a key-value list",
                .{},
            ),
        };
        var list: std.ArrayList(App) = .empty;
        for (t.entries.items) |e| {
            const at = switch (e.value) {
                .table => |at| at,
                else => return self.fail(
                    .app_not_a_table,
                    "    Expected value for app `{s}` to be a dictionary.\n",
                    .{e.key},
                ),
            };
            var app: App = .{ .name = e.key };
            // `julia_flags` FIRST. Julia reads `submodule` unchecked
            // (project.jl:95), pkgerrors on `julia_flags` (:102), and only
            // converts `submodule` when it builds the `AppInfo` (:104) — so an
            // app with both fields wrong reports the julia_flags error.
            if (at.get("julia_flags")) |fv| {
                const items = switch (fv) {
                    .array => |items| items,
                    else => return self.failJuliaFlags(e.key),
                };
                const flags = try self.arena.alloc([]const u8, items.len);
                for (items, 0..) |item, i| flags[i] = switch (item) {
                    .string => |s| s,
                    else => return self.failJuliaFlags(e.key),
                };
                app.julia_flags = flags;
            }
            // `AppInfo.submodule::Union{String, Nothing}`, so a non-string is a
            // conversion error in Julia, not a missing submodule.
            if (at.get("submodule")) |sv| app.submodule = switch (sv) {
                .string => |s| s,
                else => return self.fail(
                    .app_submodule_not_a_string,
                    "Expected `submodule` for app `{s}` to be a string",
                    .{e.key},
                ),
            };
            try list.append(self.arena, app);
        }
        self.p.apps = list.items;
    }

    fn failJuliaFlags(self: *Reader, name: []const u8) error{ InvalidProject, OutOfMemory } {
        return self.fail(
            .app_julia_flags_not_strings,
            "Expected `julia_flags` for app `{s}` to be an array of strings",
            .{name},
        );
    }

    /// `project._deps_weak = Dict(intersect(project.deps, project.weakdeps))`
    /// then `filter!` (`project.jl:237-238`).
    ///
    /// `intersect` on two `Dict`s intersects their *pairs*, so this only fires
    /// when the name AND the parsed UUID match. A name present in both with two
    /// different UUIDs stays in `deps` and in `weakdeps`, and is then a direct
    /// dependency and a weak one at once. Verified against Julia; getting this
    /// wrong changes `project_hash` and therefore invalidates every manifest.
    fn splitWeakDeps(self: *Reader) Error!void {
        var i: usize = 0;
        while (i < self.p.deps.entries.items.len) {
            const d = self.p.deps.entries.items[i];
            const w = self.p.weakdeps.get(d.name);
            if (w != null and std.mem.eql(u8, &w.?.bytes, &d.uuid.bytes)) {
                _ = try self.p.deps_weak.put(self.arena, d.name, d.uuid);
                // `d` came out of `deps.entries[i]`, so the removal cannot
                // miss; asserting it turns a would-be infinite loop (the
                // `continue` below does not advance `i`) into a crash. Bound to
                // a local first so the side effect is plainly not inside the
                // assert, whatever a reader assumes about release builds.
                const removed = try self.p.deps.remove(self.arena, d.name);
                std.debug.assert(removed);
                continue; // the entries shifted down; re-check this index
            }
            i += 1;
        }
    }

    fn fail(
        self: *Reader,
        kind: Diagnostic.Kind,
        comptime fmt: []const u8,
        args: anytype,
    ) error{ InvalidProject, OutOfMemory } {
        // Read errors carry no location suffix; only `validate`'s do.
        setMessage(self.diag, kind, null, fmt, args);
        return error.InvalidProject;
    }
};

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const Validator = struct {
    p: *const Project,
    gpa: Allocator,
    diag: ?*Diagnostic,

    fn run(self: *Validator) Error!void {
        try self.uniqueUuids(
            &self.p.deps,
            .duplicate_dep_uuid,
            "Two different dependencies can not have the same uuid",
        );
        try self.uniqueUuids(
            &self.p.weakdeps,
            .duplicate_weakdep_uuid,
            "Two different weak dependencies can not have the same uuid",
        );
        try self.uniqueUuids(
            &self.p.extras,
            .duplicate_extra_uuid,
            "Two different `extra` dependencies can not have the same uuid",
        );

        for (self.p.targets.items) |t| {
            // Julia nests this check inside `for ..., dep in deps`, so an empty
            // target list skips it. Same outcome, no allocation.
            for (t.deps, 0..) |a, i| {
                for (t.deps[i + 1 ..]) |b| {
                    if (std.mem.eql(u8, a, b)) return self.failNoLoc(
                        .target_dep_named_twice,
                        "A dependency was named twice in target `{s}`",
                        .{t.name},
                    );
                }
            }
            for (t.deps) |dep| {
                if (!self.listed(dep, true)) return self.fail(
                    .target_dep_not_listed,
                    // Julia's triple-quoted literal keeps a trailing newline,
                    // and the location suffix lands AFTER it.
                    "Dependency `{s}` in target `{s}` not listed in `deps`, `weakdeps` or `extras` section\n",
                    .{ dep, t.name },
                );
            }
        }

        for (self.p.compat.items) |c| {
            // `julia` is the one compat key that names no dependency.
            if (std.mem.eql(u8, c.name, "julia")) continue;
            if (!self.listed(c.name, true)) return self.fail(
                .compat_not_listed,
                "Compat `{s}` not listed in `deps`, `weakdeps` or `extras` section",
                .{c.name},
            );
        }

        for (self.p.sources.items) |s| {
            // include_weak = FALSE here (project.jl:207), unlike targets and
            // compat. A package that is in both [deps] and [weakdeps] has been
            // split out of `deps` by now, so it is NOT listed and its [sources]
            // entry is rejected — surprising, and exactly what Julia does.
            if (!self.listed(s.name, false)) return self.fail(
                .source_not_listed,
                "Sources for `{s}` not listed in `deps` or `extras` section",
                .{s.name},
            );
        }
    }

    /// `listed_deps` (`project.jl:4-5`).
    fn listed(self: *Validator, name: []const u8, include_weak: bool) bool {
        if (self.p.deps.contains(name)) return true;
        if (self.p.extras.contains(name)) return true;
        return include_weak and self.p.weakdeps.contains(name);
    }

    fn uniqueUuids(
        self: *Validator,
        m: *const DepMap,
        kind: Diagnostic.Kind,
        comptime msg: []const u8,
    ) Error!void {
        var seen: std.AutoHashMapUnmanaged([16]u8, void) = .empty;
        defer seen.deinit(self.gpa);
        try seen.ensureTotalCapacity(self.gpa, @intCast(m.count()));
        for (m.entries.items) |d| {
            const gop = seen.getOrPutAssumeCapacity(d.uuid.bytes);
            if (gop.found_existing) return self.fail(kind, msg, .{});
        }
    }

    fn fail(
        self: *Validator,
        kind: Diagnostic.Kind,
        comptime fmt: []const u8,
        args: anytype,
    ) error{InvalidProject} {
        setMessage(self.diag, kind, self.p.file, fmt, args);
        return error.InvalidProject;
    }

    fn failNoLoc(
        self: *Validator,
        kind: Diagnostic.Kind,
        comptime fmt: []const u8,
        args: anytype,
    ) error{InvalidProject} {
        setMessage(self.diag, kind, null, fmt, args);
        return error.InvalidProject;
    }
};

fn setMessage(
    diag: ?*Diagnostic,
    kind: Diagnostic.Kind,
    file: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const d = diag orelse return;
    d.kind = kind;
    var w = std.Io.Writer.fixed(&d.buf);
    // A message that overflows the buffer is truncated rather than lost; these
    // are diagnostics, not control flow.
    w.print(fmt, args) catch {};
    if (file) |f| w.print(" at \"{s}\".", .{f}) catch {};
    d.len = w.end;
}

// ---------------------------------------------------------------------------
// Write-side helpers
// ---------------------------------------------------------------------------

/// `_project_key_order` (`project.jl:309`). Note `extensions` is in the list
/// even though `destructure` never writes it — the passthrough copy carries it,
/// and this is what places it between `[sources]` and `[compat]`.
const project_key_order = [_][]const u8{
    "name",      "uuid",   "keywords", "license",  "desc",       "version",
    "workspace", "deps",   "weakdeps", "sources",  "extensions", "compat",
};

/// `project_key_order(key)` (`project.jl:310-311`): the position in the list, or
/// one past the end for everything else. A linear scan over twelve entries
/// beats a map here.
fn projectKeyOrder(key: []const u8) usize {
    for (project_key_order, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) return i;
    }
    return project_key_order.len;
}

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Compares everything except `name`, which the callers have already matched.
///
/// The field-count assert is the point: a new `Source` field would otherwise be
/// silently excluded here, and a real change would then look like a no-op and
/// never be written. Same reasoning in `dupeVersion`.
fn eqlSource(a: Source, b: Source) bool {
    comptime std.debug.assert(@typeInfo(Source).@"struct".fields.len == 5);
    return eqlOptStr(a.path, b.path) and eqlOptStr(a.url, b.url) and
        eqlOptStr(a.rev, b.rev) and eqlOptStr(a.subdir, b.subdir);
}

/// Deep-copies a `Version` into `arena`. `version.parse` leaves string idents
/// pointing into the text it was given (`version.zig:124-126`), so a Version
/// handed to `setVersion` is only as long-lived as that text.
fn dupeVersion(arena: Allocator, v: Version) Allocator.Error!Version {
    // Every Version field has a default, so a new borrowing field added
    // upstream would be silently DEFAULTED here rather than copied. Fail the
    // build instead.
    comptime std.debug.assert(@typeInfo(Version).@"struct".fields.len == 5);
    return .{
        .major = v.major,
        .minor = v.minor,
        .patch = v.patch,
        .prerelease = try dupeIdents(arena, v.prerelease),
        .build = try dupeIdents(arena, v.build),
    };
}

fn dupeIdents(arena: Allocator, idents: []const version_mod.Ident) Allocator.Error![]const version_mod.Ident {
    if (idents.len == 0) return &.{};
    const out = try arena.alloc(version_mod.Ident, idents.len);
    for (idents, 0..) |id, i| out[i] = switch (id) {
        .num => id,
        .str => |s| .{ .str = try arena.dupe(u8, s) },
    };
    return out;
}

fn lessByKeyOrder(_: void, a: Entry, b: Entry) bool {
    const ao = projectKeyOrder(a.key);
    const bo = projectKeyOrder(b.key);
    if (ao != bo) return ao < bo;
    return std.mem.lessThan(u8, a.key, b.key);
}

fn lessPlain(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Puts every table in the order `TOML.print(...; sorted = true, by)` would
/// have produced, so the emitter can run unsorted.
///
/// `by` is threaded all the way down the printer (`TOML/src/print.jl:205`), so
/// this recurses; an INLINE table is the exception, because
/// `print_inline_table` sorts with a bare `sort!` and ignores `by`
/// (`print.jl:120-123`).
fn sortTable(scratch: Allocator, t: *Table) Allocator.Error!void {
    if (t.is_inline) {
        std.mem.sort(Entry, t.entries.items, {}, lessPlain);
    } else {
        std.mem.sort(Entry, t.entries.items, {}, lessByKeyOrder);
    }
    t.index.clearRetainingCapacity();
    for (t.entries.items, 0..) |e, i| try t.index.put(scratch, e.key, @intCast(i));
    for (t.entries.items) |e| switch (e.value) {
        .table => |sub| try sortTable(scratch, sub),
        .array => |items| for (items) |item| {
            if (item == .table) try sortTable(scratch, item.table);
        },
        else => {},
    };
}

/// `deepcopy(project.other)` (`project.jl:264`) — structure only. Strings are
/// borrowed from the source document, which outlives the scratch arena.
///
/// Inline-ness is deliberately DROPPED: `TOML.parsefile` returns plain `Dict`s,
/// so Julia has no way to know a table was written `{ ... }`, and only the
/// `[sources]` tables that `write_project` builds are re-flagged inline.
fn copyTable(scratch: Allocator, src: *const Table) Allocator.Error!*Table {
    const out = try Table.create(scratch);
    for (src.entries.items) |e| try out.put(scratch, e.key, try copyValue(scratch, e.value));
    return out;
}

fn copyValue(scratch: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .table => |t| .{ .table = try copyTable(scratch, t) },
        .array => |items| blk: {
            const out = try scratch.alloc(Value, items.len);
            for (items, 0..) |item, i| out[i] = try copyValue(scratch, item);
            break :blk .{ .array = out };
        },
        else => v,
    };
}

fn tableSet(scratch: Allocator, t: *Table, key: []const u8, v: Value) Allocator.Error!void {
    if (t.index.get(key)) |i| {
        t.entries.items[i].value = v;
        return;
    }
    try t.put(scratch, key, v);
}

fn tableDelete(scratch: Allocator, t: *Table, key: []const u8) Allocator.Error!void {
    const i = t.index.get(key) orelse return;
    _ = t.entries.orderedRemove(i);
    _ = t.index.remove(key);
    for (t.entries.items[i..], i..) |e, j| try t.index.put(scratch, e.key, @intCast(j));
}

/// `entry!` for a scalar (`project.jl:275-278`): `nothing` deletes the key.
fn entryStr(scratch: Allocator, t: *Table, key: []const u8, v: ?[]const u8) Allocator.Error!void {
    if (v) |s| return tableSet(scratch, t, key, .{ .string = s });
    return tableDelete(scratch, t, key);
}

/// `entry!` for a table: `should_delete(x::Dict) = isempty(x)`, so an EMPTY
/// section is removed from the file rather than written as a bare header.
fn entryTable(scratch: Allocator, t: *Table, key: []const u8, sub: *Table) Allocator.Error!void {
    if (sub.count() == 0) return tableDelete(scratch, t, key);
    return tableSet(scratch, t, key, .{ .table = sub });
}

fn depTable(scratch: Allocator, m: *const DepMap) Allocator.Error!*Table {
    const t = try Table.create(scratch);
    for (m.entries.items) |d| {
        try tableSet(scratch, t, d.name, .{ .string = try formatUuid(scratch, d.uuid) });
    }
    return t;
}

/// `string(::UUID)` — canonical 8-4-4-4-12, always LOWERCASE. This is why a
/// project whose UUIDs are upper-case in the file comes back lower-case.
fn formatUuid(scratch: Allocator, u: Uuid) Allocator.Error![]const u8 {
    const hex = "0123456789abcdef";
    const out = try scratch.alloc(u8, 36);
    var i: usize = 0;
    for (u.bytes, 0..) |byte, b| {
        if (b == 4 or b == 6 or b == 8 or b == 10) {
            out[i] = '-';
            i += 1;
        }
        out[i] = hex[byte >> 4];
        out[i + 1] = hex[byte & 0xf];
        i += 2;
    }
    return out;
}

/// `UUID(::Integer)` — the integer as a UInt128 in canonical (big-endian) byte
/// order. `u128`, not `u64`: Julia's UUID IS a UInt128, so `A = 1e30` is a legal
/// (if deranged) dep value there and must be one here.
fn uuidFromInt(n: u128) Uuid {
    var u: Uuid = .{ .bytes = @splat(0) };
    var v = n;
    var i: usize = 16;
    while (v != 0 and i > 0) {
        i -= 1;
        u.bytes[i] = @truncate(v);
        v >>= 8;
    }
    return u;
}

/// `string(::VersionNumber)`, which always prints all three components — this
/// is what turns `version = "1.0"` into `version = "1.0.0"` on write.
fn formatVersion(scratch: Allocator, v: Version) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(scratch);
    errdefer aw.deinit();
    v.format(&aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
//
// Every expectation below came out of julia 1.12.6 via
// tools/diff_harness/project_model.sh, not out of reading project.jl.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The real Open-Reality Project.toml: 21 deps, 1 weakdep + 1 extension, 18
/// compat entries, [extras] and [targets], plus an unknown `authors` key.
const open_reality =
    \\name = "OpenReality"
    \\uuid = "b08b1914-4d33-46de-8c63-ba029b7f1c5f"
    \\version = "0.1.0"
    \\authors = ["OpenReality Contributors"]
    \\
    \\[deps]
    \\Ark = "56664e29-41e4-4ea5-ab0e-825499acc647"
    \\Base64 = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
    \\ColorTypes = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
    \\CompositionsBase = "a33af91c-f02d-484b-be07-31d278c5ca2b"
    \\FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    \\FreeTypeAbstraction = "663a7486-cb36-511b-a19d-713bb74d65c9"
    \\GLFW = "f7f18e0c-5ee9-5ccd-a5bf-e8befd85ed98"
    \\GLTF = "aeeaf58c-ab4d-11e9-3a9f-9b6bf58b5bc3"
    \\GeometryBasics = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
    \\ImageIO = "82e4d734-157c-48bb-816b-45c225c6df19"
    \\Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
    \\LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
    \\MeshIO = "7269a6da-0436-5bbc-96c2-40638cbb6118"
    \\ModernGL = "66fc600b-dfda-50eb-8b99-91cfa97b1301"
    \\Observables = "510215fc-4207-5dde-b226-833fc4488ee2"
    \\OpenAL_jll = "c52b6589-6b5d-587d-9bb5-adf8a44d3946"
    \\Quaternions = "94ee1d12-ae83-5a48-8b1c-48b8ff168ae0"
    \\Serialization = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
    \\StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    \\TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    \\glslang_jll = "6fd5517d-459c-5c5a-9b1a-c968b4e37a81"
    \\
    \\[weakdeps]
    \\Vulkan = "9f14b124-c50e-4008-a7d4-969b3a6cd68a"
    \\
    \\[extensions]
    \\OpenRealityVulkanExt = "Vulkan"
    \\
    \\[compat]
    \\Ark = "0.4"
    \\Base64 = "1.11.0"
    \\ColorTypes = "0.11, 0.12"
    \\CompositionsBase = "0.1.2"
    \\FileIO = "1.18.0"
    \\GLFW = "3"
    \\GLTF = "0.4.0"
    \\GeometryBasics = "0.4"
    \\ImageIO = "0.6.9"
    \\MeshIO = "0.4.13"
    \\ModernGL = "1"
    \\Observables = "0.5"
    \\OpenAL_jll = "1.21 - 1.23"
    \\Quaternions = "0.7.7"
    \\StaticArrays = "1.5"
    \\TOML = "1.0.3"
    \\Vulkan = "0.6.29"
    \\julia = "1.9"
    \\
    \\[extras]
    \\Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    \\Vulkan = "9f14b124-c50e-4008-a7d4-969b3a6cd68a"
    \\
    \\[targets]
    \\test = ["Test"]
    \\
;

test "the real Open-Reality project parses into the fields Julia reports" {
    var p = try parse(testing.allocator, open_reality, .{}, null);
    defer p.deinit();

    try testing.expectEqualStrings("OpenReality", p.name.?);
    try testing.expectEqualStrings("0.1.0", try formatVersion(p.arena(), p.version.?));
    try testing.expectEqualStrings(
        "b08b1914-4d33-46de-8c63-ba029b7f1c5f",
        try formatUuid(p.arena(), p.uuid.?),
    );
    try testing.expectEqual(@as(usize, 21), p.deps.count());
    try testing.expectEqual(@as(usize, 1), p.weakdeps.count());
    try testing.expectEqual(@as(usize, 0), p.deps_weak.count());
    try testing.expectEqual(@as(usize, 2), p.extras.count());
    try testing.expectEqual(@as(usize, 18), p.compat.items.len);
    try testing.expectEqual(@as(usize, 1), p.targets.items.len);
    try testing.expectEqual(@as(usize, 1), p.exts.len);
    try testing.expectEqualStrings("OpenRealityVulkanExt", p.exts[0].name);
    try testing.expectEqualStrings("Vulkan", p.exts[0].triggers[0]);
    try testing.expectEqualStrings("test", p.targets.items[0].name);
    try testing.expectEqualStrings("Test", p.targets.items[0].deps[0]);
    try testing.expectEqual(@as(?[]const u8, null), p.manifest);
    try testing.expectEqual(@as(?[]const u8, null), p.entryfile);
    try testing.expect(p.workspace_projects == null);

    // [compat] keeps the SOURCE string; the canonical spec is separate.
    const gltf = p.compatFor("GLTF").?;
    try testing.expectEqualStrings("0.4.0", gltf.str);
    const rendered = try gltf.spec.toString(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("0.4", rendered);
}

test "rendering the real project reproduces it byte for byte" {
    var p = try parse(testing.allocator, open_reality, .{}, null);
    defer p.deinit();

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(open_reality, out);

    // ...and a clean project asks for no write at all.
    try testing.expect(try p.pendingWrite(testing.allocator) == null);
}

test "unknown keys survive by passthrough, in _project_key_order" {
    // `keywords`/`license`/`desc` are unknown to the model but named in
    // _project_key_order, so they sort between `uuid` and `version`; `authors`
    // and `[wat]` are unknown to both and sort last within their pass.
    const src =
        \\name = "Foo"
        \\desc = "a package"
        \\license = "MIT"
        \\keywords = ["a", "b"]
        \\authors = ["me"]
        \\
        \\[extensions]
        \\E = "A"
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[wat]
        \\x = 1
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\keywords = ["a", "b"]
        \\license = "MIT"
        \\desc = "a package"
        \\authors = ["me"]
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[extensions]
        \\E = "A"
        \\
        \\[wat]
        \\x = 1
        \\
    , out);
}

test "the deps-weakdeps split is by PAIR and is undone on write" {
    const src =
        \\name = "Foo"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[weakdeps]
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[extensions]
        \\FooBExt = "B"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 1), p.deps.count());
    try testing.expect(p.deps.contains("A"));
    try testing.expect(!p.deps.contains("B"));
    try testing.expectEqual(@as(usize, 1), p.deps_weak.count());
    try testing.expect(p.deps_weak.contains("B"));

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a name in deps and weakdeps with DIFFERENT uuids is not split" {
    const src =
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000002"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.deps.count());
    try testing.expectEqual(@as(usize, 0), p.deps_weak.count());
    try testing.expectEqual(@as(usize, 1), p.weakdeps.count());

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "sources are written inline, with their keys plainly sorted" {
    const src =
        \\name = "Foo"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources.A]
        \\url = "https://example.com/A.git"
        \\rev = "main"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {rev = "main", url = "https://example.com/A.git"}
        \\
    , out);
}

test "the key order applies inside nested tables too" {
    // The proof that `by` is threaded through every level: a [compat] entry for
    // a package called `version` sorts ahead of `julia`, which a plain sort
    // would never do.
    const src =
        \\[extras]
        \\version = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\julia = "1.9"
        \\version = "1"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[compat]
        \\version = "1"
        \\julia = "1.9"
        \\
        \\[extras]
        \\version = "00000000-0000-0000-0000-000000000001"
        \\
    , out);
}

test "writing normalises uuid case, version significance and empty sections" {
    const src =
        \\name = "Foo"
        \\uuid = "B08B1914-4D33-46DE-8C63-BA029B7F1C5F"
        \\version = "1.0"
        \\
        \\[deps]
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\uuid = "b08b1914-4d33-46de-8c63-ba029b7f1c5f"
        \\version = "1.0.0"
        \\
    , out);

    // The point of pendingWrite: none of that normalisation happens to a file
    // nobody asked to change.
    try testing.expect(try p.pendingWrite(testing.allocator) == null);
}

test "`path` is read as entryfile and both keys end up in the file" {
    const src =
        \\name = "Foo"
        \\path = "src/Other.jl"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    try testing.expectEqualStrings("src/Other.jl", p.entryfile.?);
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\entryfile = "src/Other.jl"
        \\path = "src/Other.jl"
        \\
    , out);
}

test "setEntryfile adds the key an app environment needs" {
    // What `ajt app add` does to the copy of a package's project it puts in
    // `<depot>/environments/apps/<Pkg>/`: the package is loaded from the depot
    // by path rather than resolved as a dependency of itself.
    const src =
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\
        \\[deps]
        \\Example = "7876af07-990d-54b4-ab0e-23690620f79a"
        \\
        \\[apps]
        \\foo = {}
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(?[]const u8, null), p.entryfile);
    try testing.expect(!p.dirty);

    try p.setEntryfile("/depot/packages/Foo/abcd/src/Foo.jl");
    try testing.expect(p.dirty);
    // Idempotent: setting the same value again must not re-dirty a clean file.
    p.dirty = false;
    try p.setEntryfile("/depot/packages/Foo/abcd/src/Foo.jl");
    try testing.expect(!p.dirty);

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    // `entryfile` is not in `_project_key_order`, so it sorts past every named
    // key -- and the emitter still has to put a scalar ahead of every table,
    // which is what makes the result valid TOML rather than an `entryfile`
    // stranded inside `[deps]`. `[apps]` rides through the passthrough
    // untouched: nothing here writes it, and nothing needs to.
    //
    // The inline `foo = {}` comes back out as a `[apps.foo]` header, which is
    // what Julia does with the same input -- `TOML.print` over the parsed data
    // (which is exactly what `Apps._resolve` calls, `Apps.jl:169-171`) prints
    // an empty sub-table as a header too. Verified on 1.12.6.
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\uuid = "11111111-2222-3333-4444-555555555555"
        \\version = "0.1.0"
        \\entryfile = "/depot/packages/Foo/abcd/src/Foo.jl"
        \\
        \\[deps]
        \\Example = "7876af07-990d-54b4-ab0e-23690620f79a"
        \\
        \\[apps.foo]
        \\
    , out);
}

test "an integer dep value is a UUID, as it is in Julia" {
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = 1
        \\
    , .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
    , out);
}

test "mutation marks the project dirty and re-serialises" {
    var p = try parse(testing.allocator,
        \\name = "Foo"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
    , .{}, null);
    defer p.deinit();

    try testing.expect(try p.pendingWrite(testing.allocator) == null);
    try p.addDep("B", try Uuid.parse("00000000-0000-0000-0000-000000000002"));
    try p.setCompat("B", "0.4");

    const out = (try p.pendingWrite(testing.allocator)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[compat]
        \\B = "0.4"
        \\
    , out);
    try p.validate(testing.allocator, null);
}

test "a mutation that changes nothing does not dirty the project" {
    // The regression this guards: `ajt add Foo` where Foo is already a dep used
    // to flip `dirty`, and the resulting rewrite lowercased the UUID, expanded
    // `version = "1.0"` to `"1.0.0"` and dropped the comments — all for an
    // operation that changed nothing.
    const src =
        \\# my project
        \\name = "Foo"
        \\uuid = "B08B1914-4D33-46DE-8C63-BA029B7F1C5F"
        \\version = "1.0"
        \\
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001" # pinned
        \\
        \\[compat]
        \\A = "0.4"
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();

    try p.addDep("A", try Uuid.parse("00000000-0000-0000-0000-000000000001"));
    try p.setCompat("A", "0.4");
    try p.setName("Foo");
    p.setUuid(try Uuid.parse("b08b1914-4d33-46de-8c63-ba029b7f1c5f")); // case-insensitive
    try p.setVersion(try version_mod.parse(p.arena(), "1.0"));
    try p.setSource(.{ .name = "A", .path = "../A" });
    try testing.expect(p.removeSource("A")); // and back again
    p.dirty = false; // the two source edits DID change something; start clean

    try p.addDep("A", try Uuid.parse("00000000-0000-0000-0000-000000000001"));
    try testing.expect(!p.dirty);
    try testing.expect(try p.pendingWrite(testing.allocator) == null);

    // serialize still hands back the file verbatim -- comments and all.
    const bytes = try p.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(src, bytes);

    // ...and a real change does dirty it.
    try p.addDep("A", try Uuid.parse("00000000-0000-0000-0000-000000000002"));
    try testing.expect(p.dirty);
}

test "mutators copy their arguments instead of borrowing them" {
    // Formatting a value into a stack buffer is the natural call site, so
    // borrowing would put freed bytes into Project.toml with nothing to crash
    // on. Everything below is deliberately clobbered after the call.
    var p = try parse(testing.allocator,
        \\name = "Foo"
        \\
    , .{}, null);
    defer p.deinit();

    {
        var buf: [64]u8 = undefined;
        try p.setCompat(
            try std.fmt.bufPrint(buf[0..16], "B", .{}),
            try std.fmt.bufPrint(buf[16..32], "^{d}.{d}", .{ 1, 2 }),
        );
        try p.addDep(try std.fmt.bufPrint(buf[32..40], "B", .{}), try Uuid.parse("00000000-0000-0000-0000-000000000002"));
        try p.setName(try std.fmt.bufPrint(buf[40..48], "Bar", .{}));
        try p.setVersion(try version_mod.parse(p.arena(), try std.fmt.bufPrint(buf[48..64], "1.0.0-alpha.1", .{})));
        @memset(&buf, 'X');
    }
    {
        var buf: [32]u8 = undefined;
        try p.setSource(.{
            .name = try std.fmt.bufPrint(buf[0..8], "B", .{}),
            .path = try std.fmt.bufPrint(buf[8..24], "../B", .{}),
        });
        @memset(&buf, 'X');
    }

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\name = "Bar"
        \\version = "1.0.0-alpha.1"
        \\
        \\[deps]
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[sources]
        \\B = {path = "../B"}
        \\
        \\[compat]
        \\B = "^1.2"
        \\
    , out);
}

test "a malformed compat spec leaves the model untouched" {
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\A = "0.4"
        \\
    , .{}, null);
    defer p.deinit();

    // "1-2" is the REGISTRY grammar and invalid in a Project.
    try testing.expectError(error.InvalidVersionSpec, p.setCompat("A", "1-2"));
    try testing.expectEqualStrings("0.4", p.compatFor("A").?.str);
    try testing.expect(!p.dirty);
}

test "removeDep also clears _deps_weak, or the merge would resurrect it" {
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
    , .{}, null);
    defer p.deinit();

    // Re-adding it at the same UUID changes nothing the merge would not
    // already produce, so it must not dirty the project.
    try p.addDep("A", try Uuid.parse("00000000-0000-0000-0000-000000000001"));
    try testing.expect(!p.dirty);

    try testing.expect(try p.removeDep("A"));
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    // [deps] is now empty and therefore deleted; [weakdeps] is untouched.
    try testing.expectEqualStrings(
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
    , out);
}

fn expectRejected(src: []const u8, kind: Diagnostic.Kind, msg: []const u8, file: ?[]const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(
        error.InvalidProject,
        parse(testing.allocator, src, .{ .file = file }, &diag),
    );
    try testing.expectEqual(kind, diag.kind);
    try testing.expectEqualStrings(msg, diag.message());
}

test "validation rejects exactly what Pkg rejects, with Pkg's message" {
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000001"
        \\
    , .duplicate_dep_uuid, "Two different dependencies can not have the same uuid", null);

    try expectRejected(
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000001"
        \\
    , .duplicate_weakdep_uuid, "Two different weak dependencies can not have the same uuid", null);

    try expectRejected(
        \\[extras]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000001"
        \\
    , .duplicate_extra_uuid, "Two different `extra` dependencies can not have the same uuid", null);

    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[targets]
        \\test = ["Nope"]
        \\
    , .target_dep_not_listed, "Dependency `Nope` in target `test` not listed in `deps`, `weakdeps` or `extras` section\n", null);

    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[targets]
        \\test = ["A", "A"]
        \\
    , .target_dep_named_twice, "A dependency was named twice in target `test`", null);

    try expectRejected(
        \\[compat]
        \\Nope = "1"
        \\
    , .compat_not_listed, "Compat `Nope` not listed in `deps`, `weakdeps` or `extras` section", null);

    try expectRejected(
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = "../A"}
        \\
    , .source_not_listed, "Sources for `A` not listed in `deps` or `extras` section", null);

    // The location suffix is appended to validate errors only.
    try expectRejected(
        \\[compat]
        \\Nope = "1"
        \\
    , .compat_not_listed, "Compat `Nope` not listed in `deps`, `weakdeps` or `extras` section at \"/tmp/Project.toml\".", "/tmp/Project.toml");
}

test "a weakdep that is also a dep loses its right to a [sources] entry" {
    // The split emptied A out of `deps`, and `listed_deps(include_weak=false)`
    // is what [sources] is checked against.
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = "../A"}
        \\
    , .source_not_listed, "Sources for `A` not listed in `deps` or `extras` section", null);

    // ...but [compat] for it is fine, because that check includes weakdeps.
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\A = "1"
        \\
    , .{}, null);
    defer p.deinit();
}

test "compat julia needs no dependency" {
    var p = try parse(testing.allocator,
        \\[compat]
        \\julia = "1.9"
        \\
    , .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.compat.items.len);
}

test "read errors carry Pkg's message and no location" {
    try expectRejected("uuid = \"zzz\"\n", .project_uuid_malformed, "Could not parse project UUID as a UUID", "/tmp/P.toml");
    try expectRejected("uuid = 1\n", .project_uuid_not_string, "Expected project UUID to be a string", null);
    try expectRejected("version = \"not.a.version\"\n", .project_version_malformed, "Could not parse project version as a version", null);
    try expectRejected("version = 1\n", .project_version_not_string, "Expected project version to be a string", null);
    try expectRejected("deps = 1\n", .dep_section_not_a_table, "Expected `deps` section to be a key-value list", null);
    try expectRejected("weakdeps = 1\n", .dep_section_not_a_table, "Expected `weakdeps` section to be a key-value list", null);
    try expectRejected("extras = 1\n", .dep_section_not_a_table, "Expected `extras` section to be a key-value list", null);
    try expectRejected(
        \\[deps]
        \\A = "not-a-uuid"
        \\
    , .dep_uuid_malformed, "Malformed value for `A` in `deps` section.", null);
    try expectRejected("targets = 1\n", .targets_not_a_table, "Expected `targets` section to be a key-value list", null);
    try expectRejected(
        \\[targets]
        \\test = "A"
        \\
    , .target_not_a_list, "    Expected value for target `test` to be a list of dependency names.\n", null);
    try expectRejected("compat = 1\n", .compat_not_a_table, "Expected `compat` section to be a key-value list", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\A = "1-2"
        \\
    , .compat_malformed, "Could not parse compatibility version for dependency `A`", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = "../A"
        \\
    , .source_not_a_table, "Expected `source` section to be a table", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {branch = "main"}
        \\
    , .source_invalid_key, "Invalid key `branch` in `source` section", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = "../A", rev = "r"}
        \\
    , .source_path_and_url, "Both `path` and `url` or `rev` are specified in `source` section", null);
    try expectRejected(
        \\[workspace]
        \\nope = 1
        \\
    , .workspace_invalid_key, "Invalid key `nope` in `workspace`", null);
    try expectRejected(
        \\[workspace]
        \\projects = [1]
        \\
    , .workspace_entry_not_a_string, "Expected entry in `projects` to be strings", null);
    try expectRejected("workspace = 1\n", .workspace_not_a_table, "Expected `workspace` section to be a key-value list", null);
    try expectRejected(
        \\[apps]
        \\myapp = 1
        \\
    , .app_not_a_table, "    Expected value for app `myapp` to be a dictionary.\n", null);
    try expectRejected(
        \\[apps.myapp]
        \\julia_flags = 1
        \\
    , .app_julia_flags_not_strings, "Expected `julia_flags` for app `myapp` to be an array of strings", null);
}

test "a non-string scalar field is refused, not silently dropped" {
    // Julia raises a bare TypeError for each of these, so the wording is Ajt's
    // own — but the REJECTION is the part that matters. Accepting them would
    // mean `destructure` deletes the key and the write loses data.
    try expectRejected("name = 1\n", .field_not_a_string, "Expected `name` to be a string", null);
    try expectRejected("manifest = 1\n", .field_not_a_string, "Expected `manifest` to be a string", null);
    try expectRejected("path = 1\n", .field_not_a_string, "Expected `path` to be a string", null);
    try expectRejected("entryfile = 1\n", .field_not_a_string, "Expected `entryfile` to be a string", null);
    try expectRejected("extensions = 1\n", .extensions_not_a_table, "Expected `extensions` section to be a key-value list", null);
    try expectRejected("sources = 1\n", .sources_not_a_table, "Expected `sources` section to be a key-value list", null);
    try expectRejected("apps = 1\n", .apps_not_a_table, "Expected `apps` section to be a key-value list", null);
    try expectRejected(
        \\[extensions]
        \\E = [1]
        \\
    , .extension_trigger_not_a_string, "Expected trigger for extension `E` to be a string", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[compat]
        \\A = 1
        \\
    , .compat_not_a_string, "Expected compatibility version for dependency `A` to be a string", null);
}

test "a two-fault input reports the fault Julia reports first" {
    // Single-fault fixtures cannot pin check ORDER -- with one fault there is
    // only one message to produce. Each of these regressed once, when a type
    // check was added ahead of a check Julia performs first.
    //
    // `read_project_sources` scans keys (project.jl:133), then checks the
    // path/url conflict (:136), and only types the fields later at assignment
    // (:236 -> Types.jl:274).
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {branch = 1}
        \\
    , .source_invalid_key, "Invalid key `branch` in `source` section", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = 1, url = "u"}
        \\
    , .source_path_and_url, "Both `path` and `url` or `rev` are specified in `source` section", null);
    try expectRejected(
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = "p", rev = 1}
        \\
    , .source_path_and_url, "Both `path` and `url` or `rev` are specified in `source` section", null);

    // `read_project_apps` reads submodule unchecked (:95), pkgerrors on
    // julia_flags (:102), converts submodule only at AppInfo (:104).
    try expectRejected(
        \\[apps.myapp]
        \\submodule = 1
        \\julia_flags = 1
        \\
    , .app_julia_flags_not_strings, "Expected `julia_flags` for app `myapp` to be an array of strings", null);
}

test "dep UUIDs convert through UInt128, not UInt64" {
    // `A = 1e20` is a legal dep value in Pkg. A u64 conversion rejects it.
    var p = try parse(testing.allocator,
        \\[deps]
        \\F = 1e20
        \\G = 1e30
        \\
    , .{}, null);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[deps]
        \\F = "00000000-0000-0005-6bc7-5e2d63100000"
        \\G = "0000000c-9f2c-9cd0-4675-000000000000"
        \\
    , out);

    // ...and the far side of the range, plus the non-finite floats that
    // `!(f >= 0)` exists to catch, are refused exactly as Julia refuses them.
    for ([_][]const u8{ "1e40", "nan", "inf", "-inf", "1.5", "-1" }) |bad| {
        var buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "[deps]\nA = {s}\n", .{bad});
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidProject, parse(testing.allocator, src, .{}, &diag));
        try testing.expectEqual(Diagnostic.Kind.dep_uuid_malformed, diag.kind);
    }
}

test "a no-op setSource does not grow the arena" {
    // An arena never frees, so duping before comparing turned a repeated no-op
    // into unbounded growth (5 KB -> 110 KB over 20k rounds).
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {path = "../A"}
        \\
    , .{}, null);
    defer p.deinit();

    const before = p.doc.arena.queryCapacity();
    for (0..5000) |_| try p.setSource(.{ .name = "A", .path = "../A" });
    try testing.expect(!p.dirty);
    try testing.expectEqual(before, p.doc.arena.queryCapacity());
}

test "an extensions entry may list several triggers" {
    const src =
        \\[weakdeps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\B = "00000000-0000-0000-0000-000000000002"
        \\
        \\[extensions]
        \\E = ["A", "B"]
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.exts[0].triggers.len);
    try testing.expectEqualStrings("A", p.exts[0].triggers[0]);
    try testing.expectEqualStrings("B", p.exts[0].triggers[1]);

    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "url and rev together are legal; only path conflicts" {
    var p = try parse(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
        \\[sources]
        \\A = {url = "u", rev = "r"}
        \\
    , .{}, null);
    defer p.deinit();
    const s = p.sourceFor("A").?;
    try testing.expectEqualStrings("u", s.url.?);
    try testing.expectEqualStrings("r", s.rev.?);
    try testing.expect(s.path == null);
}

test "workspace round-trips" {
    const src =
        \\name = "Foo"
        \\
        \\[workspace]
        \\projects = ["sub/a", "sub/b"]
        \\
    ;
    var p = try parse(testing.allocator, src, .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.workspace_projects.?.len);
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "validate = false surfaces a broken file instead of refusing it" {
    var p = try parse(testing.allocator,
        \\[compat]
        \\Nope = "1"
        \\
    , .{ .validate = false }, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.compat.items.len);
    try testing.expectError(error.InvalidProject, p.validate(testing.allocator, null));
}

test "a TOML syntax error is reported as one" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, parse(testing.allocator, "name = \n", .{}, &diag));
    try testing.expectEqual(Diagnostic.Kind.toml_syntax, diag.kind);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "Could not parse project: line "));
}

test "an empty project renders to nothing" {
    var p = try empty(testing.allocator);
    defer p.deinit();
    const out = try p.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "destructure feeds project_hash unchanged" {
    // project_hash.compute wants a plain Table, and the destructured one has
    // deps re-merged — which is what `other` looked like in the first place, so
    // the digest is unaffected.
    const project_hash = @import("../julia/project_hash.zig");
    var p = try parse(testing.allocator, open_reality, .{}, null);
    defer p.deinit();

    const from_raw = try project_hash.compute(testing.allocator, p.other());
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const from_destructured = try project_hash.compute(
        testing.allocator,
        try p.destructure(scratch.allocator()),
    );
    try testing.expectEqualStrings(&from_raw, &from_destructured);
    try testing.expectEqualStrings("5e05dae87664a72319978725911531ada717de0f", &from_raw);
}
