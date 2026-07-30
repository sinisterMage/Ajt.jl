//! A persistent binary registry index (`.aix`), so repeat loads are an mmap.
//!
//! `registry/index.zig` re-reads and re-parses the whole General registry on
//! every invocation: decompress 10.9 MB -> 83.8 MB, index 58,968 tar entries,
//! then parse 13,969 inline tables in `Registry.toml` and four TOML files per
//! package on demand. That is ~1.6 s before any command does its own work,
//! which is fine once and intolerable for a tool you run in a loop.
//!
//! This module bakes the same information into one offset-addressed file that
//! loads with a single `mmap` and **zero pointer fixups**: every cross-reference
//! is a `u32` byte offset or array index, so the mapped bytes are usable as-is.
//!
//! ## Invalidation is the filename, not a heuristic
//!
//! The file lives at
//!
//!     <depot>/scratchspaces/<AJT_UUID>/regindex/<reg-uuid>-<tree-sha1>.aix
//!
//! where `<tree-sha1>` is the registry's own git tree hash, which Pkg already
//! records in `<depot>/registries/<Name>.toml` next to the tarball. Embedding
//! it in the NAME rather than validating it from inside means:
//!
//!   * correctness is automatic — a registry update changes the tree hash, so
//!     it changes the filename, so the stale index is simply never opened;
//!   * no mtime/size heuristic can go wrong (tarballs get rewritten with the
//!     same size, checkouts restore old mtimes, clocks skew);
//!   * a reader that has an older index mapped stays safe, because writers
//!     never mutate an existing file — a new index is a NEW path, written to an
//!     unnamed temporary and atomically linked into place.
//!
//! An index whose `magic` this build does not recognise is likewise ignored
//! rather than repaired, so a format change is a rebuild, never a misparse.
//!
//! ## What is stored, and why in this shape
//!
//! The expensive part of the old path is not reading bytes, it is
//! *uncompressing* `Deps.toml`/`Compat.toml` — expanding each `VersionRange`
//! key across the `first..last` index span (see `index.zig`'s header for the
//! two Julia quirks that rule obeys). So the index stores dependencies
//! **already uncompressed**, but re-compressed losslessly into index RUNS
//! `[lo_ver, hi_ver, dep, compat]`: the runs are over sorted version INDICES,
//! not over version ranges, so replaying them is a linear scan with no version
//! comparisons at all. The resolver never re-runs range expansion.
//!
//! Those runs are produced by feeding `index.loadPackage`'s own output through
//! a run-length encoder — deliberately, so the subtle `uncompress` semantics
//! have exactly ONE implementation in the codebase and this file cannot drift
//! from it.
//!
//! ## Deviations from the obvious layout, and their reasons
//!
//!   * **Version and tree-hash are interned STRINGS, not packed integers.** A
//!     Julia `VersionNumber` carries variable-length prerelease/build identifier
//!     lists (~12.6k version keys in General have them), so there is no fixed
//!     record that holds one. Storing the canonical text and re-parsing is
//!     exact — `parse(format(v))` is equal to `v` for every shape Julia's
//!     grammar admits — and interning makes the repeated text nearly free.
//!   * **Compat is an interned string in the REGISTRY grammar, not packed
//!     `Range` structs.** It round-trips (every rendered string is parsed back
//!     and compared during the build; a mismatch fails the build rather than
//!     silently shipping a wrong constraint), it dedups hard across the
//!     registry, and it keeps the human-readable form available so a resolver
//!     error can quote a constraint instead of a normalised struct dump.
//!   * **Names are NOT assumed unique.** They happen to be in today's General
//!     (13,969 packages, zero duplicates) but nothing in the registry format
//!     requires it, and Julia's own lookup is uuid-keyed. The name map is
//!     therefore a multimap, and `findByName` resolves a collision the same way
//!     `index.zig` does: first entry in `Registry.toml` order wins.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const tarball = @import("tarball.zig");
const index = @import("index.zig");
const toml = @import("../toml/parse.zig");
const slug = @import("../julia/slug.zig");
const version_mod = @import("../julia/version.zig");
const Version = version_mod.Version;
const versions_mod = @import("../julia/versions.zig");
const Spec = versions_mod.Spec;
const Range = versions_mod.Range;
const Bound = versions_mod.Bound;

/// Ajt's own scratchspace UUID. Julia namespaces `<depot>/scratchspaces/` by
/// the UUID of the package that owns the data (`Scratch.jl`), so Ajt takes one
/// too rather than squatting on Pkg's directories: a depot stays valid for
/// stock Julia whether or not Ajt has ever run against it, and `rm -rf` of this
/// one directory fully un-does Ajt's caching.
pub const scratch_uuid = "1b955bda-192c-455f-993b-a4807551239b";

/// Bump on ANY layout change — **and on any change to what
/// `index.loadPackage` returns**, which is the trap. The filename keys off the
/// REGISTRY's tree hash, so it catches a registry update but is blind to Ajt's
/// own semantics changing underneath a cached file: teach `index.zig` to read
/// `WeakDeps.toml`, and every existing `.aix` silently keeps answering the old
/// way. Old files are ignored rather than migrated, so a bump costs exactly one
/// rebuild.
pub const magic: [8]u8 = "AJTIDX02".*;
// 01 -> 02: weak dependency rows. A v1 index carries ONLY strong rows, so it
// does not merely lack a field — it is missing whole dependencies, and reading
// one back would under-report a package's edges. That is exactly the silent
// divergence the header check exists to prevent, so this is a real bump and
// not an over-cautious one.

/// Sentinel for `Row.pkg_idx` when a dependency's UUID is not a registered
/// package — `julia` itself and every stdlib land here.
pub const no_pkg: u32 = std.math.maxInt(u32);

const empty_slot: u32 = std.math.maxInt(u32);

pub const Error = error{
    /// Not an `.aix` file, or one written by a different format version.
    BadMagic,
    /// Header offsets do not describe a self-consistent file.
    CorruptIndex,
    /// The on-disk layout is little-endian and read in place; a big-endian host
    /// would need a byte-swapping reader, which does not exist yet.
    UnsupportedEndian,
    /// A rendered compat string did not parse back to the spec it came from.
    /// Fails the BUILD, so a rendering bug can never reach a resolver.
    CompatRoundTrip,
    /// > 4 GiB of index. Every cross-reference is a u32.
    IndexTooLarge,
    /// `<depot>/registries/<Name>.toml` is missing or lacks uuid/tree hash.
    MissingRegistryStamp,
} || index.Error;

// ---------------------------------------------------------------------------
// On-disk layout. All little-endian; every field is a byte offset or an array
// index, so the mapped bytes need no relocation.
// ---------------------------------------------------------------------------

pub const Header = extern struct {
    magic: [8]u8,
    /// Registry UUID, canonical (wire) byte order.
    reg_uuid: [16]u8,
    /// The registry's git tree hash — the same value the filename carries.
    /// Duplicated inside so a hand-renamed file is caught.
    tree_sha1: [20]u8,
    file_len: u32,
    reg_name_off: u32,
    reg_uuid_off: u32,
    n_pkgs: u32,
    n_versions: u32,
    n_rows: u32,
    strings_off: u32,
    strings_len: u32,
    pkgs_off: u32,
    versions_off: u32,
    rows_off: u32,
    uuid_map_off: u32,
    name_map_off: u32,
    /// Both maps are open-addressed with this many slots minus one as the mask.
    map_mask: u32,
    reserved: [3]u32,
};

/// One package. Sorted by `uuid` across the file, so a uuid range is a slice.
pub const PkgRec = extern struct {
    uuid: [16]u8,
    /// Interned uuid TEXT. `index.zig` compares uuids as strings, so the text
    /// is what round-trips byte-identically.
    uuid_off: u32,
    name_off: u32,
    /// Path inside the tarball, e.g. `S/StaticArrays`. Never reconstructable
    /// from the name — the registry also has a `jll/` subtree (1,798 packages).
    path_off: u32,
    repo_off: u32,
    /// `Package.toml`'s `subdir` for monorepo packages, "" when absent.
    /// `index.zig` does not read it; the installer needs it to know which
    /// directory of a checkout is the package.
    subdir_off: u32,
    /// Position in `Registry.toml`. Only used to break a name collision the
    /// same way a linear scan of `Registry.toml` would.
    order: u32,
    ver_off: u32,
    ver_len: u32,
    row_off: u32,
    row_len: u32,
};

pub const Ver = extern struct {
    /// Interned canonical version text.
    ver_off: u32,
    /// Interned `git-tree-sha1`, verbatim from `Versions.toml`.
    tree_off: u32,
    flags: u32,

    pub const yanked_bit: u32 = 1;

    pub fn yanked(v: Ver) bool {
        return v.flags & yanked_bit != 0;
    }
};

/// One dependency, applied to versions `lo..=hi` of the owning package.
///
/// Runs are emitted in ascending `lo` within ascending dependency name, so a
/// package's rows replay in a single forward scan.
pub const Row = extern struct {
    lo: u32,
    hi: u32,
    /// Index into the package table, or `no_pkg`.
    pkg_idx: u32,
    name_off: u32,
    uuid_off: u32,
    /// Interned compat text in the REGISTRY grammar (`Compat.toml`'s), i.e.
    /// `*`, `1.5`, `1.5-2`, comma-joined for a union, `∅` for the empty set.
    compat_off: u32,
    kind: u32,

    pub const strong: u32 = 0;
    /// A `[weakdeps]` edge, from `WeakDeps.toml`/`WeakCompat.toml`. Stored as
    /// an ordinary row with this discriminant, so weak deps cost no extra
    /// section. 1,597 of General's 13,969 packages have them.
    pub const weak: u32 = 1;
};

comptime {
    // Frozen: these sizes are the file format.
    std.debug.assert(@sizeOf(Header) == 112);
    std.debug.assert(@sizeOf(PkgRec) == 56);
    std.debug.assert(@sizeOf(Ver) == 12);
    std.debug.assert(@sizeOf(Row) == 28);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// A reference to one package. `idx` is the handle every other lookup takes;
/// the slices point into the mapped file and live as long as it does.
pub const Ref = struct {
    idx: u32,
    uuid: []const u8,
    name: []const u8,
    path: []const u8,
    repo: []const u8,
    subdir: []const u8,

    /// The shape `index.zig` hands around, so callers can be backend-agnostic.
    pub fn toPackageRef(r: Ref) index.PackageRef {
        return .{ .uuid = r.uuid, .name = r.name, .path = r.path };
    }
};

/// A loaded index. Borrows `bytes`; owns nothing.
pub const Index = struct {
    bytes: []align(8) const u8,
    header: *const Header,
    strings: []const u8,
    pkgs: []const PkgRec,
    vers: []const Ver,
    rows: []const Row,
    uuid_map: []const u32,
    name_map: []const u32,

    pub fn name(self: Index) []const u8 {
        return self.str(self.header.reg_name_off);
    }

    pub fn uuid(self: Index) []const u8 {
        return self.str(self.header.reg_uuid_off);
    }

    pub fn packageCount(self: Index) usize {
        return self.pkgs.len;
    }

    pub fn str(self: Index, off: u32) []const u8 {
        if (off >= self.strings.len) return "";
        return std.mem.sliceTo(self.strings[off..], 0);
    }

    pub fn refAt(self: Index, idx: u32) Ref {
        const p = self.pkgs[idx];
        return .{
            .idx = idx,
            .uuid = self.str(p.uuid_off),
            .name = self.str(p.name_off),
            .path = self.str(p.path_off),
            .repo = self.str(p.repo_off),
            .subdir = self.str(p.subdir_off),
        };
    }

    /// Matches `index.Registry.findByUuid`: uuid comparison is textual.
    pub fn findByUuid(self: Index, uuid_text: []const u8) ?Ref {
        if (self.uuid_map.len == 0) return null;
        const mask = self.header.map_mask;
        var i: u32 = @intCast(hashStr(uuid_text) & mask);
        // Probing normally stops at an empty slot, which a load factor of 0.5
        // guarantees exists. The trip count is bounded anyway: `self` may be a
        // corrupt file whose map has no empty slot at all, and a lookup miss
        // must not become a hang.
        for (0..self.uuid_map.len) |_| {
            const slot = self.uuid_map[i];
            if (slot == empty_slot) return null;
            if (std.mem.eql(u8, self.str(self.pkgs[slot].uuid_off), uuid_text))
                return self.refAt(slot);
            i = (i + 1) & mask;
        }
        return null;
    }

    /// Matches `index.Registry.findByName`, INCLUDING its collision rule: that
    /// function scans `reg.packages` in `Registry.toml` order and returns the
    /// first hit, so when two packages share a name the earlier one wins. The
    /// package table here is uuid-sorted, so the tie is broken on the recorded
    /// `order` instead.
    pub fn findByName(self: Index, pkg_name: []const u8) ?Ref {
        if (self.name_map.len == 0) return null;
        const mask = self.header.map_mask;
        var best: ?u32 = null;
        var i: u32 = @intCast(hashStr(pkg_name) & mask);
        // Bounded for the same reason as findByUuid.
        for (0..self.name_map.len) |_| {
            const slot = self.name_map[i];
            if (slot == empty_slot) break;
            if (std.mem.eql(u8, self.str(self.pkgs[slot].name_off), pkg_name)) {
                if (best == null or self.pkgs[slot].order < self.pkgs[best.?].order) best = slot;
            }
            i = (i + 1) & mask;
        }
        return if (best) |b| self.refAt(b) else null;
    }

    /// Reconstructs exactly what `index.loadPackage` returns for this package:
    /// versions ascending, dependencies uncompressed per version and sorted by
    /// name, `julia` included.
    ///
    /// Arena-allocated: everything in the result shares the returned
    /// `PackageInfo`'s arena, and string fields additionally borrow the mapped
    /// index, which must outlive it.
    pub fn loadPackage(self: Index, gpa: Allocator, ref: Ref) Error!index.PackageInfo {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const p = self.pkgs[ref.idx];
        const my_vers = self.vers[p.ver_off..][0..p.ver_len];
        const my_rows = self.rows[p.row_off..][0..p.row_len];

        const vinfos = try arena.alloc(index.VersionInfo, my_vers.len);
        for (my_vers, 0..) |v, i| {
            vinfos[i] = .{
                .version = try version_mod.parse(arena, self.str(v.ver_off)),
                .tree_hash = self.str(v.tree_off),
                .yanked = v.yanked(),
            };
        }

        const lists = try arena.alloc(std.ArrayList(index.Dep), my_vers.len);
        for (lists) |*l| l.* = .empty;
        for (my_rows) |row| {
            // Both kinds are real dependencies; `kind` decides the shape of
            // the incompatibility the solver emits, not whether the edge
            // exists. Dropping weak rows here is what made a cached index
            // disagree with a freshly-read one.
            if (row.kind != Row.strong and row.kind != Row.weak) continue;
            // `fromBytes` already established this. Re-asserting costs two
            // compares and keeps an out-of-order run from becoming an illegal
            // `for` range (which traps in Debug and wraps in ReleaseFast)
            // should the gate ever regress.
            if (row.lo > row.hi or row.hi >= my_vers.len) return error.CorruptIndex;
            const spec = try parseCompat(arena, self.str(row.compat_off));
            for (row.lo..row.hi + 1) |i| {
                try lists[i].append(arena, .{
                    .name = self.str(row.name_off),
                    .uuid = self.str(row.uuid_off),
                    .compat = spec,
                    .weak = row.kind == Row.weak,
                });
            }
        }

        const deps = try arena.alloc([]index.Dep, my_vers.len);
        for (lists, 0..) |*l, i| {
            // Same comparator and same (stable) sort as index.zig, so a package
            // that somehow lists one name twice orders identically.
            std.mem.sort(index.Dep, l.items, {}, struct {
                fn lt(_: void, a: index.Dep, b: index.Dep) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lt);
            deps[i] = l.items;
        }

        return .{
            .arena = arena_state,
            .name = ref.name,
            .uuid = ref.uuid,
            .repo = ref.repo,
            .subdir = ref.subdir,
            .versions = vinfos,
            .deps = deps,
        };
    }
};

/// Validates a header and slices the sections. No allocation, no I/O — this is
/// the whole "load" cost once the bytes are mapped.
pub fn fromBytes(bytes: []align(8) const u8) Error!Index {
    if (builtin.cpu.arch.endian() != .little) return error.UnsupportedEndian;
    if (bytes.len < @sizeOf(Header)) return error.BadMagic;
    const h: *const Header = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadMagic;
    if (h.file_len > bytes.len) return error.CorruptIndex;

    const total = h.file_len;
    // Every section is bounds-checked against the header's own file_len before
    // a single element is read, so a truncated or hand-edited file errors out
    // instead of reading past the mapping.
    const strings = try slice(u8, bytes, total, h.strings_off, h.strings_len);
    if (strings.len == 0 or strings[strings.len - 1] != 0) return error.CorruptIndex;
    const pkgs = try slice(PkgRec, bytes, total, h.pkgs_off, h.n_pkgs);
    const vers = try slice(Ver, bytes, total, h.versions_off, h.n_versions);
    const rows = try slice(Row, bytes, total, h.rows_off, h.n_rows);
    // Probing steps with `& mask`, which only enumerates every slot when the
    // slot count is a power of two — so that is a validity condition, not an
    // implementation detail. Computed in u64 because `map_mask` is attacker-
    // controlled and `maxInt(u32) + 1` would overflow the check itself.
    const nslots_u64: u64 = if (h.n_pkgs == 0) 0 else @as(u64, h.map_mask) + 1;
    if (nslots_u64 > std.math.maxInt(u32)) return error.CorruptIndex;
    if (nslots_u64 & (nslots_u64 -% 1) != 0) return error.CorruptIndex;
    const nslots: u32 = @intCast(nslots_u64);
    const uuid_map = try slice(u32, bytes, total, h.uuid_map_off, nslots);
    const name_map = try slice(u32, bytes, total, h.name_map_off, nslots);

    // A bad slot index would be an out-of-bounds package read on every lookup;
    // check once here rather than on the hot path.
    for (uuid_map) |s| {
        if (s != empty_slot and s >= pkgs.len) return error.CorruptIndex;
    }
    for (name_map) |s| {
        if (s != empty_slot and s >= pkgs.len) return error.CorruptIndex;
    }
    // Every cross-reference a reader will follow, checked up front so no code
    // downstream has to. Rows are validated in package context because
    // `Row.hi` addresses that package's version slice, not the global one.
    for (pkgs) |p| {
        if (@as(u64, p.ver_off) + p.ver_len > vers.len) return error.CorruptIndex;
        if (@as(u64, p.row_off) + p.row_len > rows.len) return error.CorruptIndex;
        for (rows[p.row_off..][0..p.row_len]) |row| {
            if (row.lo > row.hi or row.hi >= p.ver_len) return error.CorruptIndex;
            if (row.pkg_idx != no_pkg and row.pkg_idx >= pkgs.len) return error.CorruptIndex;
        }
    }

    return .{
        .bytes = bytes,
        .header = h,
        .strings = strings,
        .pkgs = pkgs,
        .vers = vers,
        .rows = rows,
        .uuid_map = uuid_map,
        .name_map = name_map,
    };
}

fn slice(comptime T: type, bytes: []align(8) const u8, total: u32, off: u32, count: u32) Error![]const T {
    const n = @as(u64, count) * @sizeOf(T);
    if (@as(u64, off) + n > total) return error.CorruptIndex;
    if (off % @alignOf(T) != 0) return error.CorruptIndex;
    const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr + off));
    return ptr[0..count];
}

/// FNV-1a, spelled out rather than pulled from `std.hash`, because the slot
/// layout is ON DISK: a std implementation change would silently invalidate
/// every cached index (or worse, find nothing while looking valid).
fn hashStr(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

// ---------------------------------------------------------------------------
// Compat rendering — must round-trip through the REGISTRY grammar
// ---------------------------------------------------------------------------

/// Renders a `Spec` in the grammar `Compat.toml` uses, such that
/// `parseCompat(render(s))` equals `s`. `renderCompat`/`parseCompat` are the
/// only pair allowed to know this encoding, and `build` verifies the identity
/// for every constraint it writes.
fn renderCompat(w: *std.Io.Writer, spec: Spec) std.Io.Writer.Error!void {
    if (spec.ranges.len == 0) return w.writeAll("∅");
    for (spec.ranges, 0..) |r, i| {
        if (i != 0) try w.writeAll(", ");
        // `Range.parse` splits on '-' and `Bound.parse` accepts `*`, so a bound
        // pair always round-trips. Printing the single-bound form when the two
        // are equal is not cosmetic: `Range.init` collapses `lo.t == hi.t` by
        // adopting the upper bound's significance, and the single form is the
        // one that survives that collapse unchanged.
        if (r.lower.eql(r.upper)) {
            try writeBound(w, r.lower);
        } else {
            try writeBound(w, r.lower);
            try w.writeAll("-");
            try writeBound(w, r.upper);
        }
    }
}

fn writeBound(w: *std.Io.Writer, b: Bound) std.Io.Writer.Error!void {
    if (b.n == 0) return w.writeAll("*");
    for (0..b.n) |i| {
        if (i != 0) try w.writeAll(".");
        try w.print("{d}", .{b.t[i]});
    }
}

/// Inverse of `renderCompat`. Arena-allocated (the spec's ranges live as long
/// as the `PackageInfo` that holds them).
fn parseCompat(arena: Allocator, text: []const u8) Error!Spec {
    if (std.mem.eql(u8, text, "∅")) return .{ .ranges = try arena.alloc(Range, 0) };
    var n: usize = 1;
    for (text) |c| {
        if (c == ',') n += 1;
    }
    const parts = try arena.alloc([]const u8, n);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| : (i += 1) parts[i] = std.mem.trim(u8, part, " ");
    return Spec.parseMany(arena, parts);
}

// ---------------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------------

/// Interns strings into one NUL-separated blob. Offset 0 is always `""`, so an
/// absent optional field needs no sentinel.
const Interner = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    buf: std.ArrayList(u8) = .empty,
    /// Keys must outlive `buf`'s reallocations, so they are duped here.
    keys: std.heap.ArenaAllocator,

    fn init(gpa: Allocator) Interner {
        return .{ .keys = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Interner, gpa: Allocator) void {
        self.map.deinit(gpa);
        self.buf.deinit(gpa);
        self.keys.deinit();
    }

    fn intern(self: *Interner, gpa: Allocator, s: []const u8) Error!u32 {
        if (self.map.get(s)) |off| return off;
        // Widened to u64 first: the operands are file-derived, and doing the
        // subtraction in usize would underflow before the check could fire.
        if (@as(u64, self.buf.items.len) + s.len + 1 > std.math.maxInt(u32))
            return error.IndexTooLarge;
        const off: u32 = @intCast(self.buf.items.len);
        try self.buf.appendSlice(gpa, s);
        try self.buf.append(gpa, 0);
        try self.map.put(gpa, try self.keys.allocator().dupe(u8, s), off);
        return off;
    }
};

const Build = struct {
    gpa: Allocator,
    strings: Interner,
    pkgs: std.ArrayList(PkgRec) = .empty,
    vers: std.ArrayList(Ver) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// Reset (not freed) per compat verification. The check runs once per
    /// dependency per version — ~780k times for General — so a fresh arena
    /// each time would be the dominant allocator traffic of the whole build.
    check: std.heap.ArenaAllocator,
    /// Reusable growable render buffer, also reset rather than freed. It is
    /// growable rather than a fixed stack array on purpose: nothing bounds a
    /// version string or a compat union, and overflowing a fixed buffer would
    /// abort the index build for all 13,969 packages over one odd entry.
    text: std.Io.Writer.Allocating,

    fn deinit(self: *Build) void {
        self.strings.deinit(self.gpa);
        self.pkgs.deinit(self.gpa);
        self.vers.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.check.deinit();
        self.text.deinit();
    }

    /// An empty writer with the previous render's capacity still allocated.
    fn render(self: *Build) *std.Io.Writer {
        self.text.writer.end = 0;
        return &self.text.writer;
    }

    fn rendered(self: *const Build) []const u8 {
        return self.text.writer.buffered();
    }
};

/// Builds a complete `.aix` image from an open registry.
///
/// Returns the whole file as one 8-byte-aligned buffer owned by `gpa`; the
/// caller frees it with `gpa.free`. Writing it out is a separate step so the
/// format can be exercised end to end without touching a filesystem.
///
/// `tree_sha1` is the registry's git tree hash — the invalidation key. It comes
/// from `<depot>/registries/<Name>.toml`; `readStamp` reads it.
pub fn build(gpa: Allocator, reg: *const index.Registry, tree_sha1: slug.Sha1) Error![]align(8) u8 {
    if (builtin.cpu.arch.endian() != .little) return error.UnsupportedEndian;

    var b: Build = .{
        .gpa = gpa,
        .strings = Interner.init(gpa),
        .check = std.heap.ArenaAllocator.init(gpa),
        .text = .init(gpa),
    };
    defer b.deinit();

    _ = try b.strings.intern(gpa, ""); // offset 0
    const reg_name_off = try b.strings.intern(gpa, reg.name);
    const reg_uuid_off = try b.strings.intern(gpa, reg.uuid);

    // --- package table, sorted by uuid ------------------------------------
    const Sortable = struct {
        uuid: [16]u8,
        ref: index.PackageRef,
        order: u32,
    };
    const sorted = try gpa.alloc(Sortable, reg.packages.len);
    defer gpa.free(sorted);
    for (reg.packages, 0..) |ref, i| {
        // A `Registry.toml` package key that is not a UUID is a malformed
        // registry by definition; failing here (and falling back to the direct
        // path) beats indexing something we cannot address.
        const u = slug.Uuid.parse(ref.uuid) catch return error.MalformedRegistry;
        sorted[i] = .{ .uuid = u.bytes, .ref = ref, .order = @intCast(i) };
    }
    std.mem.sort(Sortable, sorted, {}, struct {
        fn lt(_: void, x: Sortable, y: Sortable) bool {
            return switch (std.mem.order(u8, &x.uuid, &y.uuid)) {
                .lt => true,
                .gt => false,
                // Two spellings of one uuid: keep it deterministic.
                .eq => std.mem.lessThan(u8, x.ref.uuid, y.ref.uuid),
            };
        }
    }.lt);

    // Dependency UUIDs resolve to package indices, so the map has to exist
    // before any package is encoded.
    var uuid_to_idx: std.StringHashMapUnmanaged(u32) = .empty;
    defer uuid_to_idx.deinit(gpa);
    try uuid_to_idx.ensureTotalCapacity(gpa, @intCast(sorted.len));
    for (sorted, 0..) |s, i| uuid_to_idx.putAssumeCapacity(s.ref.uuid, @intCast(i));

    try b.pkgs.ensureTotalCapacity(gpa, sorted.len);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (sorted) |s| {
        var pkg = try index.loadPackage(gpa, reg, s.ref);
        defer pkg.deinit();

        _ = scratch.reset(.retain_capacity);

        const rec_ver_off: u32 = @intCast(b.vers.items.len);
        for (pkg.versions) |vi| {
            // The only way an Allocating writer fails is allocation.
            vi.version.format(b.render()) catch return error.OutOfMemory;
            try b.vers.append(gpa, .{
                .ver_off = try b.strings.intern(gpa, b.rendered()),
                .tree_off = try b.strings.intern(gpa, vi.tree_hash),
                .flags = if (vi.yanked) Ver.yanked_bit else 0,
            });
        }

        const rec_row_off: u32 = @intCast(b.rows.items.len);
        try encodeRows(&b, &scratch, pkg, &uuid_to_idx);

        b.pkgs.appendAssumeCapacity(.{
            .uuid = s.uuid,
            .uuid_off = try b.strings.intern(gpa, s.ref.uuid),
            .name_off = try b.strings.intern(gpa, s.ref.name),
            .path_off = try b.strings.intern(gpa, s.ref.path),
            .repo_off = try b.strings.intern(gpa, pkg.repo),
            .subdir_off = try b.strings.intern(gpa, try readSubdir(&scratch, reg, s.ref)),
            .order = s.order,
            .ver_off = rec_ver_off,
            .ver_len = @intCast(pkg.versions.len),
            .row_off = rec_row_off,
            .row_len = @intCast(b.rows.items.len - rec_row_off),
        });
    }

    return try serialize(gpa, &b, reg, tree_sha1, reg_name_off, reg_uuid_off);
}

/// `Package.toml`'s `subdir`, "" when absent. Read separately because
/// `index.loadPackage` only surfaces `repo`.
fn readSubdir(scratch: *std.heap.ArenaAllocator, reg: *const index.Registry, ref: index.PackageRef) Error![]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/Package.toml", .{ref.path}) catch return "";
    const src = (try reg.files.get(path)) orelse return "";
    const doc = try toml.parse(scratch.allocator(), src, null);
    const v = doc.root.get("subdir") orelse return "";
    return switch (v) {
        .string => |str_val| str_val,
        else => "",
    };
}

/// Run-length encodes `pkg.deps` into `Row`s.
///
/// Both the previous and the current version's dependency lists are sorted by
/// name (`index.loadPackage` guarantees it), so the two are merged rather than
/// hashed: a dependency whose name, uuid AND compat text all match the previous
/// version simply extends that version's run. Anything else opens a new one, so
/// a gap in the version span produces two runs and never one that spuriously
/// spans the hole.
fn encodeRows(
    b: *Build,
    scratch: *std.heap.ArenaAllocator,
    pkg: index.PackageInfo,
    uuid_to_idx: *const std.StringHashMapUnmanaged(u32),
) Error!void {
    const sa = scratch.allocator();
    const first_row = b.rows.items.len;

    var prev: []const index.Dep = &.{};
    var prev_rows: []u32 = &.{};

    for (pkg.deps, 0..) |cur, vi| {
        const cur_rows = try sa.alloc(u32, cur.len);
        const cur_compat = try sa.alloc(u32, cur.len);
        for (cur, 0..) |d, i| cur_compat[i] = try internCompat(b, d.compat);

        var a: usize = 0;
        var c: usize = 0;
        while (a < prev.len and c < cur.len) {
            switch (std.mem.order(u8, prev[a].name, cur[c].name)) {
                .lt => a += 1,
                .gt => {
                    cur_rows[c] = try openRow(b, cur[c], cur_compat[c], @intCast(vi), uuid_to_idx);
                    c += 1;
                },
                .eq => {
                    // `kind` is part of identity, and leaving it out was a
                    // silent correctness bug: a dependency that is WEAK at one
                    // version and STRONG at the next, with the same name, uuid
                    // and compat text, extended the previous run and inherited
                    // its kind. Accessors 0.1.42 came back with `Dates` weak
                    // where the registry says strong, which changes the
                    // resolved closure -- a weak edge does not force
                    // selection. Nothing consumed deps through this backend
                    // until `resolve` did, so it never surfaced.
                    const cur_kind: u32 = if (cur[c].weak) Row.weak else Row.strong;
                    const same = std.mem.eql(u8, prev[a].uuid, cur[c].uuid) and
                        b.rows.items[prev_rows[a]].compat_off == cur_compat[c] and
                        b.rows.items[prev_rows[a]].kind == cur_kind;
                    if (same) {
                        b.rows.items[prev_rows[a]].hi = @intCast(vi);
                        cur_rows[c] = prev_rows[a];
                    } else {
                        cur_rows[c] = try openRow(b, cur[c], cur_compat[c], @intCast(vi), uuid_to_idx);
                    }
                    a += 1;
                    c += 1;
                },
            }
        }
        while (c < cur.len) : (c += 1) {
            cur_rows[c] = try openRow(b, cur[c], cur_compat[c], @intCast(vi), uuid_to_idx);
        }

        prev = cur;
        prev_rows = cur_rows;
    }

    // Replay order is (name, lo): a forward scan then yields each version's
    // dependencies already name-sorted, which is the order index.zig produces.
    std.mem.sort(Row, b.rows.items[first_row..], b, struct {
        fn lt(ctx: *Build, x: Row, y: Row) bool {
            const xn = std.mem.sliceTo(ctx.strings.buf.items[x.name_off..], 0);
            const yn = std.mem.sliceTo(ctx.strings.buf.items[y.name_off..], 0);
            return switch (std.mem.order(u8, xn, yn)) {
                .lt => true,
                .gt => false,
                .eq => x.lo < y.lo,
            };
        }
    }.lt);
}

fn openRow(
    b: *Build,
    dep: index.Dep,
    compat_off: u32,
    vi: u32,
    uuid_to_idx: *const std.StringHashMapUnmanaged(u32),
) Error!u32 {
    const idx: u32 = @intCast(b.rows.items.len);
    try b.rows.append(b.gpa, .{
        .lo = vi,
        .hi = vi,
        .pkg_idx = uuid_to_idx.get(dep.uuid) orelse no_pkg,
        .name_off = try b.strings.intern(b.gpa, dep.name),
        .uuid_off = try b.strings.intern(b.gpa, dep.uuid),
        .compat_off = compat_off,
        .kind = if (dep.weak) Row.weak else Row.strong,
    });
    return idx;
}

/// Renders a compat spec, verifies it parses back to an equal spec, and
/// interns it. The verification is the safety net that lets the format store
/// text instead of packed ranges: a rendering bug fails the build loudly
/// instead of shipping a subtly wrong constraint to the resolver.
fn internCompat(b: *Build, spec: Spec) Error!u32 {
    // The only way an Allocating writer fails is allocation.
    renderCompat(b.render(), spec) catch return error.OutOfMemory;
    const text = b.rendered();

    _ = b.check.reset(.retain_capacity);
    // An allocation failure here is NOT a round-trip failure; conflating the
    // two would report a registry bug when the machine simply ran out of RAM.
    const back = parseCompat(b.check.allocator(), text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompatRoundTrip,
    };
    if (!back.eql(spec)) return error.CompatRoundTrip;

    return b.strings.intern(b.gpa, text);
}

fn serialize(
    gpa: Allocator,
    b: *Build,
    reg: *const index.Registry,
    tree_sha1: slug.Sha1,
    reg_name_off: u32,
    reg_uuid_off: u32,
) Error![]align(8) u8 {
    const nslots: u32 = if (b.pkgs.items.len == 0) 0 else blk: {
        // Load factor <= 0.5, which keeps the linear probe short and — more
        // importantly — guarantees an empty slot exists so probing terminates.
        var n: u32 = 16;
        while (n < b.pkgs.items.len * 2) n *= 2;
        break :blk n;
    };
    const mask: u32 = if (nslots == 0) 0 else nslots - 1;

    var off: u32 = @sizeOf(Header);
    const strings_off = off;
    off = try advance(off, b.strings.buf.items.len);
    const pkgs_off = align8(off);
    off = try advance(pkgs_off, b.pkgs.items.len * @sizeOf(PkgRec));
    const versions_off = align8(off);
    off = try advance(versions_off, b.vers.items.len * @sizeOf(Ver));
    const rows_off = align8(off);
    off = try advance(rows_off, b.rows.items.len * @sizeOf(Row));
    const uuid_map_off = align8(off);
    off = try advance(uuid_map_off, @as(usize, nslots) * 4);
    const name_map_off = align8(off);
    off = try advance(name_map_off, @as(usize, nslots) * 4);
    const total = off;

    const out = try gpa.alignedAlloc(u8, .@"8", total);
    errdefer gpa.free(out);
    @memset(out, 0);

    const h: *Header = @ptrCast(out.ptr);
    h.* = .{
        .magic = magic,
        .reg_uuid = regUuidBytes(reg),
        .tree_sha1 = tree_sha1.bytes,
        .file_len = total,
        .reg_name_off = reg_name_off,
        .reg_uuid_off = reg_uuid_off,
        .n_pkgs = @intCast(b.pkgs.items.len),
        .n_versions = @intCast(b.vers.items.len),
        .n_rows = @intCast(b.rows.items.len),
        .strings_off = strings_off,
        .strings_len = @intCast(b.strings.buf.items.len),
        .pkgs_off = pkgs_off,
        .versions_off = versions_off,
        .rows_off = rows_off,
        .uuid_map_off = uuid_map_off,
        .name_map_off = name_map_off,
        .map_mask = mask,
        .reserved = .{ 0, 0, 0 },
    };

    @memcpy(out[strings_off..][0..b.strings.buf.items.len], b.strings.buf.items);
    copyRecords(PkgRec, out, pkgs_off, b.pkgs.items);
    copyRecords(Ver, out, versions_off, b.vers.items);
    copyRecords(Row, out, rows_off, b.rows.items);

    if (nslots != 0) {
        const umap: [*]u32 = @ptrCast(@alignCast(out.ptr + uuid_map_off));
        const nmap: [*]u32 = @ptrCast(@alignCast(out.ptr + name_map_off));
        @memset(umap[0..nslots], empty_slot);
        @memset(nmap[0..nslots], empty_slot);
        for (b.pkgs.items, 0..) |p, i| {
            insert(umap, mask, hashStr(strAt(b, p.uuid_off)), @intCast(i));
            insert(nmap, mask, hashStr(strAt(b, p.name_off)), @intCast(i));
        }
    }

    return out;
}

fn insert(map: [*]u32, mask: u32, h: u64, value: u32) void {
    var i: u32 = @intCast(h & mask);
    while (map[i] != empty_slot) i = (i + 1) & mask;
    map[i] = value;
}

fn strAt(b: *const Build, off: u32) []const u8 {
    return std.mem.sliceTo(b.strings.buf.items[off..], 0);
}

fn copyRecords(comptime T: type, out: []align(8) u8, off: u32, items: []const T) void {
    if (items.len == 0) return;
    const dst: [*]T = @ptrCast(@alignCast(out.ptr + off));
    @memcpy(dst[0..items.len], items);
}

fn align8(x: u32) u32 {
    return (x + 7) & ~@as(u32, 7);
}

/// Advances a section cursor. The headroom of 7 is not slack: every caller
/// feeds the result to `align8`, which would itself overflow on a value within
/// 7 of the u32 ceiling.
fn advance(base: u32, len: usize) Error!u32 {
    const n = @as(u64, base) + len;
    if (n > std.math.maxInt(u32) - 7) return error.IndexTooLarge;
    return @intCast(n);
}

fn regUuidBytes(reg: *const index.Registry) [16]u8 {
    const u = slug.Uuid.parse(reg.uuid) catch return .{0} ** 16;
    return u.bytes;
}

// ---------------------------------------------------------------------------
// Depot plumbing
// ---------------------------------------------------------------------------

/// What `<depot>/registries/<Name>.toml` records about the installed registry.
/// Pkg writes this file next to the tarball, so the tree hash needed for
/// invalidation is already on disk — Ajt never has to hash 84 MB to find out
/// whether its index is current.
pub const Stamp = struct {
    uuid: []const u8,
    tree_sha1: slug.Sha1,
    tree_sha1_text: []const u8,
};

/// Arena-allocated: the returned strings borrow the arena.
pub fn readStamp(arena: Allocator, io: Io, depot: []const u8, reg_name: []const u8) !Stamp {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/registries/{s}.toml", .{ depot, reg_name });
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch
        return error.MissingRegistryStamp;
    var doc = try toml.parse(arena, src, null);
    const uuid_text = switch (doc.root.get("uuid") orelse return error.MissingRegistryStamp) {
        .string => |s| s,
        else => return error.MissingRegistryStamp,
    };
    const th_text = switch (doc.root.get("git-tree-sha1") orelse return error.MissingRegistryStamp) {
        .string => |s| s,
        else => return error.MissingRegistryStamp,
    };
    // Both halves are validated before they become a filename. `uuid` is also
    // the prefix `pruneOlder` matches on, so an empty or `../`-bearing value
    // would let a malformed General.toml delete every other registry's index —
    // or write outside the cache directory entirely.
    _ = slug.Uuid.parse(uuid_text) catch return error.MissingRegistryStamp;
    return .{
        .uuid = uuid_text,
        .tree_sha1 = slug.Sha1.parse(th_text) catch return error.MissingRegistryStamp,
        .tree_sha1_text = th_text,
    };
}

/// `<depot>/scratchspaces/<AJT_UUID>/regindex`.
pub fn cacheDir(buf: []u8, depot: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/scratchspaces/{s}/regindex", .{ depot, scratch_uuid });
}

/// The full path of the index for one registry stamp. The tree hash IS the
/// cache key: a different registry snapshot is a different file, never an
/// overwrite, so a concurrent reader of the old one is never pulled out from
/// under.
pub fn cachePath(buf: []u8, depot: []const u8, stamp: Stamp) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/scratchspaces/{s}/regindex/{s}-{s}.aix", .{
        depot, scratch_uuid, stamp.uuid, stamp.tree_sha1_text,
    });
}

/// A memory-mapped index plus the handles that keep it alive.
pub const Mapped = struct {
    file: Io.File,
    map: Io.File.MemoryMap,
    index: Index,

    pub fn deinit(self: *Mapped, io: Io) void {
        self.map.destroy(io);
        self.file.close(io);
        self.* = undefined;
    }
};

/// Maps an `.aix` file. This is the whole load: no parse, no allocation, no
/// pointer fixups — just a header validation and six slices.
pub fn openFile(io: Io, path: []const u8) !Mapped {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    errdefer file.close(io);
    const len = try file.length(io);
    if (len < @sizeOf(Header) or len > std.math.maxInt(u32)) return error.CorruptIndex;

    var map = try file.createMemoryMap(io, .{
        .len = @intCast(len),
        .protection = .{ .read = true, .write = false },
        // Lazy on purpose: a lookup touches a few pages out of ~20 MB, and
        // prefaulting would trade the win away for read-ahead we do not need.
        .populate = false,
    });
    errdefer map.destroy(io);

    return .{ .file = file, .map = map, .index = try fromBytes(@alignCast(map.memory)) };
}

/// Opens the index for `<depot>/registries/<reg_name>` if a current one exists.
///
/// Returns null — rather than an error — when there is simply no index yet, so
/// callers can fall back to the archive path without inspecting error sets.
/// `arena` holds only the stamp strings.
pub fn openForRegistry(arena: Allocator, io: Io, depot: []const u8, reg_name: []const u8) !?Mapped {
    const stamp = readStamp(arena, io, depot, reg_name) catch return null;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = cachePath(&path_buf, depot, stamp) catch return null;
    const mapped = openFile(io, path) catch return null;
    // Belt and braces against a hand-renamed file: the tree hash is in the
    // header too, and a mismatch means the name lied about the contents.
    if (!std.mem.eql(u8, &mapped.index.header.tree_sha1, &stamp.tree_sha1.bytes)) {
        var m = mapped;
        m.deinit(io);
        return null;
    }
    return mapped;
}

/// Writes `bytes` to the index path for `stamp`, atomically.
///
/// The file is materialised with `link`, which fails if something is already
/// there — and "already there" is treated as success, because the name is
/// content-addressed by the registry tree hash, so whatever another process
/// just wrote is the same index. Older indices for this registry are then
/// unlinked; POSIX keeps them alive for anyone who still has one mapped.
pub fn writeIndex(gpa: Allocator, io: Io, depot: []const u8, stamp: Stamp, bytes: []const u8) !void {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try cacheDir(&dir_buf, depot);
    try Io.Dir.cwd().createDirPath(io, dir_path);

    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var name_buf: [128]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&name_buf, "{s}-{s}.aix", .{ stamp.uuid, stamp.tree_sha1_text });

    // REPLACE, never link-or-skip. The file name carries the REGISTRY's tree
    // hash, not a hash of these bytes, so "the name already exists" does NOT
    // imply "the content is what this encoder would write" -- any change to the
    // encoder or the format produces different bytes under the same name. The
    // previous link-and-ignore-PathAlreadyExists made an existing index
    // permanent: `ajt registry index --rebuild` reported the path and the byte
    // count and changed nothing, so a fixed encoder could never reach disk.
    //
    // Replacing stays safe against a concurrent writer because the rename is
    // atomic -- a reader sees wholly the old file or wholly the new one, both
    // valid indexes for this registry tree -- and an already-mmapped reader
    // keeps its inode until it unmaps.
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);

    pruneOlder(gpa, io, dir, stamp, file_name);
}

/// Removes indices for the same registry built from a different tree hash.
///
/// Best-effort: a failure here costs disk, never correctness. Names are
/// collected before anything is unlinked, because deleting during a `readdir`
/// walk is allowed to skip entries. Unlinking is safe even for an index some
/// other process still has mapped — POSIX keeps the inode alive until it is
/// unmapped, which is the other half of why an index is never rewritten.
fn pruneOlder(gpa: Allocator, io: Io, dir: Io.Dir, stamp: Stamp, keep: []const u8) void {
    var doomed: std.ArrayList([]u8) = .empty;
    defer {
        for (doomed.items) |n| gpa.free(n);
        doomed.deinit(gpa);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".aix")) continue;
        if (!std.mem.startsWith(u8, entry.name, stamp.uuid)) continue;
        if (std.mem.eql(u8, entry.name, keep)) continue;
        doomed.append(gpa, gpa.dupe(u8, entry.name) catch return) catch return;
    }
    for (doomed.items) |n| dir.deleteFile(io, n) catch {};
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// The same fixture `index.zig` uses, so the two backends are compared on data
/// whose expected answers are already pinned there.
fn miniRegistry(gpa: Allocator) !index.Registry {
    const buf = try gpa.alloc(u8, 16384);
    defer gpa.free(buf);
    const entries = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
        \\00000000-0000-0000-0000-0000000000a1 = { name = "Alpha", path = "A/Alpha" }
        \\
        },
        .{ .name = "D/Demo/Package.toml", .data =
        \\name = "Demo"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\repo = "https://example.com/Demo.jl.git"
        \\subdir = "lib/Demo"
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
        .{ .name = "A/Alpha/Package.toml", .data =
        \\name = "Alpha"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\repo = "https://example.com/Alpha.jl.git"
        \\
        },
        .{ .name = "A/Alpha/Versions.toml", .data =
        \\["0.5.0"]
        \\git-tree-sha1 = "dddddddddddddddddddddddddddddddddddddddd"
        \\
        },
    };
    const tar_bytes = buildTar(buf, &entries);
    const archive = try tarball.loadTar(gpa, tar_bytes);
    return index.open(archive);
}

/// Mirrors the tar builder in tarball.zig's tests.
fn buildTar(buf: []u8, entries: anytype) []u8 {
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
        for (h) |bb| sum += bb;
        _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;
        off += 512;
        @memcpy(buf[off..][0..e.data.len], e.data);
        off += std.mem.alignForward(usize, e.data.len, 512);
    }
    off += 1024;
    return buf[0..off];
}

fn testIndex(gpa: Allocator, reg: *const index.Registry) ![]align(8) u8 {
    const sha = try slug.Sha1.parse("c75cb0b99296cb6306fa8e99184bb7495ca20adf");
    return build(gpa, reg, sha);
}

/// Renders a package the way `ajt registry show` does, from either backend, so
/// the two can be compared as bytes.
fn renderPackage(gpa: Allocator, pkg: *const index.PackageInfo) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("== {s} {s} {s}\n", .{ pkg.name, pkg.uuid, pkg.repo });
    for (pkg.versions, 0..) |vi, i| {
        try w.print("{f}", .{vi.version});
        if (vi.yanked) try w.writeAll("  (yanked)");
        try w.print("  {s}\n", .{vi.tree_hash});
        for (pkg.deps[i]) |d| {
            const spec = try d.compat.toString(gpa);
            defer gpa.free(spec);
            // `weak` belongs in the rendering because this is the oracle the
            // round-trip test and tools/diff_harness/aix.sh compare through.
            // While it was omitted, both passed with the bit encoded WRONG.
            try w.print("    {s} {s} {s}{s}\n", .{ d.name, d.uuid, spec, if (d.weak) " weak" else "" });
        }
    }
    return aw.toOwnedSlice();
}

/// A package whose dependency is strong at 1.0, weak at 1.1 and strong again at
/// 1.2 -- the shape that exposed the run-length encoder. Accessors is the real
/// one: `Dates` sits in both Deps.toml and WeakDeps.toml for exactly one
/// version, and a run that spans the flip reports the wrong kind.
fn flipRegistry(gpa: Allocator) !index.Registry {
    const buf = try gpa.alloc(u8, 16384);
    defer gpa.free(buf);
    const entries = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Flip", path = "F/Flip" }
        \\00000000-0000-0000-0000-0000000000a1 = { name = "Alpha", path = "A/Alpha" }
        \\
        },
        .{ .name = "F/Flip/Package.toml", .data =
        \\name = "Flip"
        \\uuid = "90137ffa-7385-5640-81b9-e52037218182"
        \\repo = "https://example.com/Flip.jl.git"
        \\
        },
        .{ .name = "F/Flip/Versions.toml", .data =
        \\["1.0.0"]
        \\git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\
        \\["1.1.0"]
        \\git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\
        \\["1.2.0"]
        \\git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
        \\
        },
        .{ .name = "F/Flip/Deps.toml", .data =
        \\["1"]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
        },
        .{ .name = "F/Flip/WeakDeps.toml", .data =
        \\["1.1"]
        \\Alpha = "00000000-0000-0000-0000-0000000000a1"
        \\
        },
        .{ .name = "F/Flip/Compat.toml", .data =
        \\["1"]
        \\Alpha = "0.5"
        \\
        },
        .{ .name = "A/Alpha/Package.toml", .data =
        \\name = "Alpha"
        \\uuid = "00000000-0000-0000-0000-0000000000a1"
        \\
        },
        .{ .name = "A/Alpha/Versions.toml", .data =
        \\["0.5.0"]
        \\git-tree-sha1 = "dddddddddddddddddddddddddddddddddddddddd"
        \\
        },
    };
    const tar_bytes = buildTar(buf, &entries);
    const archive = try tarball.loadTar(gpa, tar_bytes);
    return index.open(archive);
}

test "a dep that flips strong -> weak -> strong keeps its kind per version" {
    var reg = try flipRegistry(testing.allocator);
    defer reg.deinit();

    const ref = reg.findByName("Flip").?;
    var direct = try index.loadPackage(testing.allocator, &reg, ref);
    defer direct.deinit();

    // The archive reader is the oracle: a name in BOTH tables is weak, so only
    // 1.1.0 is weak here.
    try testing.expectEqual(@as(usize, 3), direct.versions.len);
    try testing.expect(!direct.deps[0][0].weak);
    try testing.expect(direct.deps[1][0].weak);
    try testing.expect(!direct.deps[2][0].weak);

    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);
    const idx = try fromBytes(bytes);
    var viaidx = try idx.loadPackage(testing.allocator, idx.findByName("Flip").?);
    defer viaidx.deinit();

    const want = try renderPackage(testing.allocator, &direct);
    defer testing.allocator.free(want);
    const got = try renderPackage(testing.allocator, &viaidx);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "an index round-trips a registry byte-for-byte against the direct path" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();

    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);
    const idx = try fromBytes(bytes);

    try testing.expectEqualStrings("Mini", idx.name());
    try testing.expectEqualStrings("23338594-aafe-5451-b93e-139f81909106", idx.uuid());
    try testing.expectEqual(@as(usize, 2), idx.packageCount());

    for ([_][]const u8{ "Demo", "Alpha" }) |name| {
        const ref = reg.findByName(name).?;
        var direct = try index.loadPackage(testing.allocator, &reg, ref);
        defer direct.deinit();
        const want = try renderPackage(testing.allocator, &direct);
        defer testing.allocator.free(want);

        const aref = idx.findByName(name).?;
        var viaidx = try idx.loadPackage(testing.allocator, aref);
        defer viaidx.deinit();
        const got = try renderPackage(testing.allocator, &viaidx);
        defer testing.allocator.free(got);

        try testing.expectEqualStrings(want, got);
    }
}

test "lookup by uuid and name agrees with the direct path, including path and subdir" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);
    const idx = try fromBytes(bytes);

    const demo = idx.findByUuid("90137ffa-7385-5640-81b9-e52037218182").?;
    try testing.expectEqualStrings("Demo", demo.name);
    // The path comes from Registry.toml, never reconstructed from the name.
    try testing.expectEqualStrings("D/Demo", demo.path);
    try testing.expectEqualStrings("lib/Demo", demo.subdir);
    try testing.expectEqualStrings("https://example.com/Demo.jl.git", demo.repo);
    // Alpha has no subdir key at all.
    try testing.expectEqualStrings("", idx.findByName("Alpha").?.subdir);

    try testing.expect(idx.findByName("Nope") == null);
    try testing.expect(idx.findByUuid("00000000-0000-0000-0000-000000000000") == null);
}

test "packages are ordered by uuid, and dep rows resolve to package indices" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);
    const idx = try fromBytes(bytes);

    // Alpha's uuid begins 0000…, Demo's 9013…, so Alpha sorts first even
    // though Demo comes first in Registry.toml.
    try testing.expectEqualStrings("Alpha", idx.refAt(0).name);
    try testing.expectEqualStrings("Demo", idx.refAt(1).name);

    const demo = idx.findByName("Demo").?;
    const p = idx.pkgs[demo.idx];
    var saw_alpha = false;
    var saw_julia = false;
    for (idx.rows[p.row_off..][0..p.row_len]) |row| {
        const nm = idx.str(row.name_off);
        if (std.mem.eql(u8, nm, "Alpha")) {
            // Alpha IS registered, so the row carries a direct index.
            try testing.expectEqual(@as(u32, 0), row.pkg_idx);
            // ["1"] covers versions 1.0.0 and 1.1.0 -> one run, not two rows.
            try testing.expectEqual(@as(u32, 0), row.lo);
            try testing.expectEqual(@as(u32, 1), row.hi);
            saw_alpha = true;
        }
        if (std.mem.eql(u8, nm, "julia")) {
            // julia is not a registered package: no index to point at.
            try testing.expectEqual(no_pkg, row.pkg_idx);
            saw_julia = true;
        }
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_julia);
}

test "compat rendering round-trips through the registry grammar" {
    const cases = [_][]const u8{
        "*",
        "0.5",
        "1.6.0 - 1",
        "1-1.11",
        "0",
        "1.2.3",
    };
    for (cases) |src| {
        const spec = try Spec.parse(testing.allocator, src);
        defer spec.deinit(testing.allocator);

        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try renderCompat(&w, spec);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const back = try parseCompat(arena.allocator(), w.buffered());
        try testing.expect(back.eql(spec));
    }

    // A union of two non-joinable ranges renders comma-joined and comes back
    // as the same two ranges. This is the shape ["0.7", "1-1.11"] produces.
    const parts = [_][]const u8{ "0.7", "1-1.11" };
    const spec = try Spec.parseMany(testing.allocator, &parts);
    defer spec.deinit(testing.allocator);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderCompat(&w, spec);
    try testing.expectEqualStrings("0.7, 1-1.11", w.buffered());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try parseCompat(arena.allocator(), w.buffered())).eql(spec));
}

test "an unbounded lower bound and the empty spec survive the round trip" {
    // `>=0.5` is `0.5.0 - *`: an upper bound with n == 0.
    const open = try versions_mod.semverSpec(testing.allocator, ">=0.5");
    defer open.deinit(testing.allocator);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderCompat(&w, open);
    try testing.expectEqualStrings("0.5.0-*", w.buffered());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try parseCompat(arena.allocator(), w.buffered())).eql(open));

    // `union!` drops empty ranges entirely, so "5-1" yields a spec with zero
    // ranges. It has to survive as zero ranges, not as `*`.
    const empty = try Spec.parse(testing.allocator, "5-1");
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.ranges.len);
    var w2 = std.Io.Writer.fixed(&buf);
    try renderCompat(&w2, empty);
    try testing.expectEqualStrings("∅", w2.buffered());
    const back = try parseCompat(arena.allocator(), w2.buffered());
    try testing.expectEqual(@as(usize, 0), back.ranges.len);
}

test "a truncated or foreign file is rejected, never misparsed" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);

    try testing.expectError(error.BadMagic, fromBytes(bytes[0..8]));

    const copy = try testing.allocator.alignedAlloc(u8, .@"8", bytes.len);
    defer testing.allocator.free(copy);
    @memcpy(copy, bytes);
    copy[7] = '9'; // "AJTIDX09"
    try testing.expectError(error.BadMagic, fromBytes(copy));

    @memcpy(copy, bytes);
    const h: *Header = @ptrCast(copy.ptr);
    h.n_pkgs = 1_000_000; // claims more packages than the file holds
    try testing.expectError(error.CorruptIndex, fromBytes(copy));
}

test "corruption that would hang or trap a reader is rejected at open" {
    var reg = try miniRegistry(testing.allocator);
    defer reg.deinit();
    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);

    const copy = try testing.allocator.alignedAlloc(u8, .@"8", bytes.len);
    defer testing.allocator.free(copy);
    const h: *Header = @ptrCast(copy.ptr);

    // A run whose lo exceeds its hi is `for (5..3)` — a trap in Debug and a
    // ~2^64-iteration wrap in ReleaseFast, i.e. memory corruption.
    @memcpy(copy, bytes);
    const rows: [*]Row = @ptrCast(@alignCast(copy.ptr + h.rows_off));
    rows[0].lo = rows[0].hi + 1;
    try testing.expectError(error.CorruptIndex, fromBytes(copy));

    // Probing steps with `& mask`, which only walks every slot when the slot
    // count is a power of two; 6 slots would cycle 0 -> 1 -> 0 forever.
    @memcpy(copy, bytes);
    h.map_mask = 5;
    try testing.expectError(error.CorruptIndex, fromBytes(copy));

    // maxInt(u32) would overflow the `mask + 1` inside the check itself.
    @memcpy(copy, bytes);
    h.map_mask = std.math.maxInt(u32);
    try testing.expectError(error.CorruptIndex, fromBytes(copy));

    // A dependency row pointing outside the package table.
    @memcpy(copy, bytes);
    const rows2: [*]Row = @ptrCast(@alignCast(copy.ptr + h.rows_off));
    rows2[0].pkg_idx = 999;
    try testing.expectError(error.CorruptIndex, fromBytes(copy));

    // A map with no empty slot is structurally VALID (every slot names a real
    // package), so it opens — and then a miss must terminate rather than probe
    // forever. This is the one the bounded probe exists for.
    @memcpy(copy, bytes);
    const umap: [*]u32 = @ptrCast(@alignCast(copy.ptr + h.uuid_map_off));
    const nmap: [*]u32 = @ptrCast(@alignCast(copy.ptr + h.name_map_off));
    @memset(umap[0 .. h.map_mask + 1], 0);
    @memset(nmap[0 .. h.map_mask + 1], 0);
    const idx = try fromBytes(copy);
    try testing.expect(idx.findByUuid("ffffffff-ffff-ffff-ffff-ffffffffffff") == null);
    try testing.expect(idx.findByName("NoSuchPackage") == null);
}

test "two packages sharing a name resolve the way a Registry.toml scan would" {
    // Today's General has 13,969 packages and zero duplicate names, but nothing
    // in the format forbids one — Julia's own lookups are uuid-keyed. The name
    // map is therefore a multimap, and the tie has to break exactly as
    // index.zig's linear scan does: first in Registry.toml order wins.
    const buf = try testing.allocator.alloc(u8, 16384);
    defer testing.allocator.free(buf);
    const tar_bytes = buildTar(buf, &[_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\ffffffff-0000-0000-0000-000000000001 = { name = "Twin", path = "T/TwinA" }
        \\00000000-0000-0000-0000-000000000002 = { name = "Twin", path = "T/TwinB" }
        \\
        },
        .{ .name = "T/TwinA/Versions.toml", .data =
        \\["1.0.0"]
        \\git-tree-sha1 = "1111111111111111111111111111111111111111"
        \\
        },
        .{ .name = "T/TwinB/Versions.toml", .data =
        \\["2.0.0"]
        \\git-tree-sha1 = "2222222222222222222222222222222222222222"
        \\
        },
    });
    var reg = try index.open(try tarball.loadTar(testing.allocator, tar_bytes));
    defer reg.deinit();

    const bytes = try testIndex(testing.allocator, &reg);
    defer testing.allocator.free(bytes);
    const idx = try fromBytes(bytes);

    // TwinA is first in the file but its uuid sorts LAST, so a naive
    // "first matching record" would return TwinB.
    try testing.expectEqualStrings("T/TwinB", idx.refAt(0).path);
    try testing.expectEqualStrings("T/TwinA", idx.refAt(1).path);
    try testing.expectEqualStrings(reg.findByName("Twin").?.path, idx.findByName("Twin").?.path);
    try testing.expectEqualStrings("T/TwinA", idx.findByName("Twin").?.path);

    // Both remain reachable by their own uuid.
    try testing.expectEqualStrings("T/TwinB", idx.findByUuid("00000000-0000-0000-0000-000000000002").?.path);
    try testing.expectEqualStrings("T/TwinA", idx.findByUuid("ffffffff-0000-0000-0000-000000000001").?.path);
}

test "rewriting an index replaces the old bytes rather than keeping them" {
    // The regression this exists for: the write used to `link` and swallow
    // PathAlreadyExists on the theory that an existing name meant identical
    // content. The name carries the REGISTRY tree hash, not a hash of the
    // bytes, so a changed encoder writes different bytes under the same name --
    // and the old file won, permanently. `--rebuild` printed the path and the
    // byte count while changing nothing on disk, which is how a wrong weak bit
    // survived a rebuild and made `resolve` disagree with the archive reader.
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const depot = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const stamp: Stamp = .{
        .uuid = "23338594-aafe-5451-b93e-139f81909106",
        .tree_sha1 = try slug.Sha1.parse("c75cb0b99296cb6306fa8e99184bb7495ca20adf"),
        .tree_sha1_text = "c75cb0b99296cb6306fa8e99184bb7495ca20adf",
    };

    try writeIndex(testing.allocator, io, depot, stamp, "first");
    try writeIndex(testing.allocator, io, depot, stamp, "second-and-longer");

    var path_buf: [512]u8 = undefined;
    const path = try cachePath(&path_buf, depot, stamp);
    const got = try Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("second-and-longer", got);

    // And exactly one file: replacing must not leave the staging temp behind.
    var dir = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}

test "the cache path is content-addressed by the registry tree hash" {
    var buf: [512]u8 = undefined;
    const stamp: Stamp = .{
        .uuid = "23338594-aafe-5451-b93e-139f81909106",
        .tree_sha1 = try slug.Sha1.parse("c75cb0b99296cb6306fa8e99184bb7495ca20adf"),
        .tree_sha1_text = "c75cb0b99296cb6306fa8e99184bb7495ca20adf",
    };
    const path = try cachePath(&buf, "/depot", stamp);
    try testing.expectEqualStrings(
        "/depot/scratchspaces/" ++ scratch_uuid ++
            "/regindex/23338594-aafe-5451-b93e-139f81909106-c75cb0b99296cb6306fa8e99184bb7495ca20adf.aix",
        path,
    );
}
