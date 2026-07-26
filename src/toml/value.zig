//! TOML value model.
//!
//! Two properties matter here and drive every design choice:
//!
//!  1. **Order preserving.** Ajt must round-trip files whose unknown keys it
//!     does not understand (Pkg keeps these in an `other` passthrough table),
//!     so a plain hash map is not enough -- entries keep insertion order and a
//!     side index provides O(1) lookup for the big tables (the General
//!     registry's Registry.toml has ~14k entries in a single table, where a
//!     linear scan would be quadratic).
//!
//!  2. **Arena allocated.** A TOML document is parsed, used, and dropped whole.
//!     Every string and table hangs off one arena, so there is no per-node
//!     ownership to get wrong and teardown is a single free.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: DateTime,
    array: []Value,
    table: *Table,

    /// Julia's TOML printer treats tables and non-empty arrays-of-tables as
    /// "tabular" and emits them after all scalar keys, under a header.
    /// `TOML/src/print.jl:141-147`. Note an EMPTY array is deliberately not
    /// tabular -- it prints inline as `key = []`.
    pub fn isTabular(self: Value) bool {
        return switch (self) {
            .table => true,
            .array => |items| items.len > 0 and blk: {
                for (items) |v| if (v != .table) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    pub fn isArrayOfTables(self: Value) bool {
        return switch (self) {
            .array => self.isTabular(),
            else => false,
        };
    }
};

/// TOML dates. Ajt never does date arithmetic, but it cannot keep the raw
/// lexeme either: Julia's printer normalises to
/// `YYYY-mm-ddTHH:MM:SS.sssZ` / `YYYY-mm-dd` / `HH:MM:SS.sss`
/// (`TOML/src/print.jl:96-98`), and byte-identity against that is the goal.
/// So we decompose on parse and re-format on emit. Any timezone offset is
/// dropped, which is what Julia's parser does too.
pub const DateTime = struct {
    kind: Kind,
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,

    pub const Kind = enum { datetime, date, time };
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    /// Written as `{ k = v }`. Julia keeps an `inline_tables` IdSet and emits
    /// those inline even in table position (`print.jl:158-161, 174, 191`).
    is_inline: bool = false,
    /// Created by an explicit `[header]`/`[[header]]` rather than implied by a
    /// dotted key or a parent header. Needed to reject redefinition.
    explicitly_defined: bool = false,
    /// Created by a dotted key inside a table body (`a.b = 1`). TOML forbids
    /// later opening such a table with a header.
    from_dotted_key: bool = false,
    /// Closed to further modification: an inline table, or a table reached
    /// through one, may never be extended.
    closed: bool = false,

    pub fn get(self: *const Table, key: []const u8) ?Value {
        const i = self.index.get(key) orelse return null;
        return self.entries.items[i].value;
    }

    pub fn getPtr(self: *Table, key: []const u8) ?*Value {
        const i = self.index.get(key) orelse return null;
        return &self.entries.items[i].value;
    }

    pub fn contains(self: *const Table, key: []const u8) bool {
        return self.index.contains(key);
    }

    pub fn count(self: *const Table) usize {
        return self.entries.items.len;
    }

    /// Appends a new entry. The caller must have checked for duplicates; TOML
    /// duplicate-key handling is a parse error, not a silent overwrite.
    pub fn put(self: *Table, arena: Allocator, key: []const u8, value: Value) !void {
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(arena, .{ .key = key, .value = value });
        try self.index.put(arena, key, idx);
    }

    pub fn create(arena: Allocator) !*Table {
        const t = try arena.create(Table);
        t.* = .{};
        return t;
    }

    /// Key order for `sorted = true` emission. Julia sorts with the default
    /// `isless(::String, ::String)`, which compares bytes over the shared
    /// prefix and then falls back to length -- exactly `std.mem.lessThan`.
    /// Verified against the real manifest: `FieldViews` < `FileIO` and
    /// `GStreamer_jll` < `Gdbm_jll` (uppercase sorts before lowercase).
    pub fn sortedKeys(self: *const Table, gpa: Allocator) ![]const []const u8 {
        const keys = try gpa.alloc([]const u8, self.entries.items.len);
        for (self.entries.items, 0..) |e, i| keys[i] = e.key;
        std.mem.sort([]const u8, keys, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return keys;
    }
};

/// A parsed document plus the arena that owns every byte of it.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

test "isTabular follows Julia's rules" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tbl = try Table.create(a);
    try t.expect((Value{ .table = tbl }).isTabular());
    try t.expect(!(Value{ .integer = 1 }).isTabular());

    // An empty array is NOT an array of tables -- it prints inline as `[]`.
    const empty: []Value = &.{};
    try t.expect(!(Value{ .array = empty }).isTabular());

    // An array of tables is tabular.
    const two = try a.alloc(Value, 2);
    two[0] = .{ .table = try Table.create(a) };
    two[1] = .{ .table = try Table.create(a) };
    try t.expect((Value{ .array = two }).isTabular());

    // A mixed array is not.
    const mixed = try a.alloc(Value, 2);
    mixed[0] = .{ .table = try Table.create(a) };
    mixed[1] = .{ .integer = 3 };
    try t.expect(!(Value{ .array = mixed }).isTabular());
}

test "sortedKeys matches Julia string ordering" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tbl = try Table.create(a);
    for ([_][]const u8{ "FileIO", "GStreamer_jll", "FieldViews", "Gdbm_jll" }) |k| {
        try tbl.put(a, k, .{ .integer = 0 });
    }
    const keys = try tbl.sortedKeys(t.allocator);
    defer t.allocator.free(keys);
    try t.expectEqualStrings("FieldViews", keys[0]);
    try t.expectEqualStrings("FileIO", keys[1]);
    try t.expectEqualStrings("GStreamer_jll", keys[2]);
    try t.expectEqualStrings("Gdbm_jll", keys[3]);
}
