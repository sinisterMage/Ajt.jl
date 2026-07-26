//! TOML emitter, byte-compatible with Julia's `TOML.print`.
//!
//! This is a deliberate reimplementation of
//! `stdlib/v1.12/TOML/src/print.jl`, not a general pretty-printer. Byte
//! identity with Julia is not required at runtime by anything -- but it is the
//! sharpest available signal in the differential harness, so it is treated as
//! a testable invariant.
//!
//! The three details that are easy to get wrong, all reproduced here:
//!
//!  * Scalars are indented `4*max(0, indent-1)`, table headers `4*indent`
//!    (`print.jl:178` vs `:199`). The off-by-one is intentional in Julia.
//!  * A table gets NO `[header]` line when it is non-empty and every one of
//!    its values is itself tabular (`print.jl:194`). This is why a real
//!    Manifest.toml has no `[deps]` line but does have
//!    `[deps.Accessors.extensions]`.
//!  * `indent` advances by the *header* flag, not unconditionally
//!    (`print.jl:205`), so a headerless table does not indent its children.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const DateTime = value_mod.DateTime;
const isBareKeyChar = @import("parse.zig").isBareKeyChar;

pub const Options = struct {
    /// Sort keys with Julia's `isless(::String, ::String)` (bytewise, then
    /// length). Pkg writes manifests with `sorted = true`.
    sorted: bool = false,

    /// Re-emit tables that were written as `{ k = v }` inline.
    ///
    /// Defaults to FALSE on purpose. Julia's parser discards inline-ness --
    /// `TOML.parsefile` returns plain `Dict`s -- so `TOML.print(TOML.parsefile(f))`
    /// turns an inline table into a `[header]` table. Matching that round-trip
    /// is what the differential gate checks, so the default has to behave the
    /// same way. Pkg's own writer opts specific tables back into inline form
    /// via an `inline_tables` IdSet (e.g. `[sources]`, `project.jl:318-325`);
    /// that is what this flag is for.
    respect_inline: bool = false,
};

pub const Error = Writer.Error || Allocator.Error;

pub fn emit(gpa: Allocator, w: *Writer, root: *const Table, opts: Options) Error!void {
    var ks: std.ArrayList([]const u8) = .empty;
    defer ks.deinit(gpa);
    try printTable(gpa, w, root, &ks, 0, true, opts);
}

/// Renders to a caller-owned slice. Convenience for tests and `ajt fmt`.
pub fn emitAlloc(gpa: Allocator, root: *const Table, opts: Options) Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try emit(gpa, &aw.writer, root, opts);
    return aw.toOwnedSlice();
}

fn isInline(t: *const Table, opts: Options) bool {
    return opts.respect_inline and t.is_inline;
}

/// Julia's `is_tabular(value) && !(value in inline_tables)` test, i.e. "does
/// this value get deferred to the header section".
fn deferred(v: Value, opts: Options) bool {
    if (!v.isTabular()) return false;
    return switch (v) {
        .table => |t| !isInline(t, opts),
        else => true,
    };
}

fn printTable(
    gpa: Allocator,
    w: *Writer,
    a: *const Table,
    ks: *std.ArrayList([]const u8),
    indent: usize,
    first_block_in: bool,
    opts: Options,
) Error!void {
    if (isInline(a, opts)) return printInlineTable(gpa, w, a, opts);

    var first_block = first_block_in;

    var keys_buf: ?[]const []const u8 = null;
    defer if (keys_buf) |k| gpa.free(k);
    const akeys: []const []const u8 = if (opts.sorted) blk: {
        const sorted = try a.sortedKeys(gpa);
        keys_buf = sorted;
        break :blk sorted;
    } else blk: {
        const in_order = try gpa.alloc([]const u8, a.entries.items.len);
        keys_buf = in_order;
        for (a.entries.items, 0..) |e, i| in_order[i] = e.key;
        break :blk in_order;
    };

    // Pass 1: every non-deferred (scalar or inline) entry.
    for (akeys) |key| {
        const v = a.get(key).?;
        if (deferred(v, opts)) continue;
        try writeSpaces(w, 4 * (if (indent > 0) indent - 1 else 0));
        try printKey(w, &.{key});
        try w.writeAll(" = ");
        try printValue(gpa, w, v, opts);
        try w.writeAll("\n");
        first_block = false;
    }

    // Pass 2: sub-tables and arrays-of-tables, each under a header.
    for (akeys) |key| {
        const v = a.get(key).?;
        switch (v) {
            .table => |sub| {
                if (isInline(sub, opts)) continue;
                try ks.append(gpa, key);
                defer _ = ks.pop();

                // A header is omitted only when every value is itself tabular,
                // so the child's own headers fully describe the path.
                var header = sub.count() == 0;
                if (!header) {
                    for (sub.entries.items) |e| {
                        if (!deferred(e.value, opts)) {
                            header = true;
                            break;
                        }
                    }
                }
                if (header) {
                    if (!first_block) try w.writeAll("\n");
                    first_block = false;
                    try writeSpaces(w, 4 * indent);
                    try w.writeAll("[");
                    try printKey(w, ks.items);
                    try w.writeAll("]\n");
                }
                try printTable(gpa, w, sub, ks, indent + @intFromBool(header), header, opts);
            },
            .array => {
                if (!v.isArrayOfTables()) continue;
                if (!first_block) try w.writeAll("\n");
                first_block = false;
                try ks.append(gpa, key);
                defer _ = ks.pop();
                for (v.array) |elem| {
                    try writeSpaces(w, 4 * indent);
                    try w.writeAll("[[");
                    try printKey(w, ks.items);
                    try w.writeAll("]]\n");
                    try printTable(gpa, w, elem.table, ks, indent + 1, true, opts);
                }
            },
            else => {},
        }
    }
}

fn writeSpaces(w: *Writer, n: usize) Writer.Error!void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(" ");
}

fn printKey(w: *Writer, parts: []const []const u8) Writer.Error!void {
    for (parts, 0..) |k, i| {
        if (i != 0) try w.writeAll(".");
        if (k.len == 0) {
            try w.writeAll("\"\"");
            continue;
        }
        var bare = true;
        for (k) |c| {
            if (!isBareKeyChar(c)) {
                bare = false;
                break;
            }
        }
        if (bare) {
            try w.writeAll(k);
        } else {
            try w.writeAll("\"");
            try printEscaped(w, k);
            try w.writeAll("\"");
        }
    }
}

/// `print_toml_escaped` (print.jl:8-34). Byte-wise iteration is equivalent to
/// Julia's char-wise loop: every byte that needs escaping is ASCII, and UTF-8
/// continuation bytes are >= 0x80, so they pass through untouched.
fn printEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        0x08 => try w.writeAll("\\b"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        0x0C => try w.writeAll("\\f"),
        '\r' => try w.writeAll("\\r"),
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => {
            if (c <= 0x1F or c == 0x7F) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
}

fn printValue(gpa: Allocator, w: *Writer, v: Value, opts: Options) Error!void {
    switch (v) {
        .string => |s| {
            // NB: Julia picks `"""` when the string contains a newline but
            // STILL escapes that newline as \n (print.jl:104-107). Odd, but
            // reproduced deliberately -- diverging here breaks byte identity.
            const q: []const u8 = if (std.mem.indexOfScalar(u8, s, '\n') != null) "\"\"\"" else "\"";
            try w.writeAll(q);
            try printEscaped(w, s);
            try w.writeAll(q);
        },
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try printFloat(w, f),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |dt| try printDateTime(w, dt),
        .array => |items| {
            try w.writeAll("[");
            for (items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try printValue(gpa, w, item, opts);
            }
            try w.writeAll("]");
        },
        .table => |t| try printInlineTable(gpa, w, t, opts),
    }
}

fn printInlineTable(gpa: Allocator, w: *Writer, t: *const Table, opts: Options) Error!void {
    var keys_buf: ?[]const []const u8 = null;
    defer if (keys_buf) |k| gpa.free(k);
    const vkeys: []const []const u8 = if (opts.sorted) blk: {
        const s = try t.sortedKeys(gpa);
        keys_buf = s;
        break :blk s;
    } else blk: {
        const in_order = try gpa.alloc([]const u8, t.entries.items.len);
        keys_buf = in_order;
        for (t.entries.items, 0..) |e, i| in_order[i] = e.key;
        break :blk in_order;
    };

    try w.writeAll("{");
    for (vkeys, 0..) |k, i| {
        if (i != 0) try w.writeAll(", ");
        try printKey(w, &.{k});
        try w.writeAll(" = ");
        try printValue(gpa, w, t.get(k).?, opts);
    }
    try w.writeAll("}");
}

/// `Dates.format(..., "YYYY-mm-dd\THH:MM:SS.sss\Z")` and friends
/// (print.jl:96-98).
fn printDateTime(w: *Writer, dt: DateTime) Writer.Error!void {
    switch (dt.kind) {
        .date => try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ dt.year, dt.month, dt.day }),
        .time => try w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ dt.hour, dt.minute, dt.second, dt.millisecond }),
        .datetime => try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.millisecond,
        }),
    }
}

/// Julia prints floats with `Base.print(io, Float64(value))`, i.e. Ryu
/// shortest-round-trip, using FIXED notation when the normalised base-10
/// exponent is in [-4, 5] and SCIENTIFIC otherwise. Both forms always carry a
/// decimal point: `100000.0`, `1.0e6`, `0.0001`, `1.0e-5`, `2.5e-10`.
/// (Determined empirically against Julia 1.12.6.)
///
/// No TOML file in the General registry or a full depot contains a float --
/// 377 scanned, zero hits -- so this is correctness for its own sake rather
/// than a hot path.
fn printFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f > 0) "+inf" else "-inf");

    // Shortest round-trip scientific form, e.g. "1.5e2" / "-1e-7".
    var buf: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&buf, "{e}", .{f}) catch return w.print("{d}", .{f});

    const e_at = std.mem.indexOfScalar(u8, sci, 'e') orelse return w.print("{d}", .{f});
    var mantissa = sci[0..e_at];
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch return w.print("{d}", .{f});

    var negative = false;
    if (mantissa.len > 0 and mantissa[0] == '-') {
        negative = true;
        mantissa = mantissa[1..];
    }
    // Digits of the mantissa with the point removed: "1.5" -> "15".
    var digits: [32]u8 = undefined;
    var ndigits: usize = 0;
    for (mantissa) |c| {
        if (c == '.') continue;
        if (ndigits >= digits.len) return w.print("{d}", .{f});
        digits[ndigits] = c;
        ndigits += 1;
    }
    while (ndigits > 1 and digits[ndigits - 1] == '0') ndigits -= 1;
    const d = digits[0..ndigits];

    if (negative) try w.writeAll("-");

    if (exp >= -4 and exp <= 5) {
        if (exp >= 0) {
            const int_len: usize = @intCast(exp + 1);
            if (d.len > int_len) {
                try w.writeAll(d[0..int_len]);
                try w.writeAll(".");
                try w.writeAll(d[int_len..]);
            } else {
                try w.writeAll(d);
                var pad = int_len - d.len;
                while (pad > 0) : (pad -= 1) try w.writeAll("0");
                try w.writeAll(".0");
            }
        } else {
            try w.writeAll("0.");
            var z: i32 = -1;
            while (z > exp) : (z -= 1) try w.writeAll("0");
            try w.writeAll(d);
        }
    } else {
        try w.writeAll(d[0..1]);
        try w.writeAll(".");
        if (d.len > 1) try w.writeAll(d[1..]) else try w.writeAll("0");
        try w.print("e{d}", .{exp});
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const parseToml = @import("parse.zig").parse;

fn roundTrip(src: []const u8, opts: Options) ![]u8 {
    var doc = try parseToml(testing.allocator, src, null);
    defer doc.deinit();
    return emitAlloc(testing.allocator, doc.root, opts);
}

test "scalars come before headers, with Julia's indentation" {
    const out = try roundTrip(
        \\[b]
        \\y = 2
        \\[a]
        \\x = 1
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[a]
        \\x = 1
        \\
        \\[b]
        \\y = 2
        \\
    , out);
}

test "header omitted when every value is tabular" {
    // The Manifest.toml shape: no [deps] line, but [deps.Foo] exists.
    //
    // Note the LEADING blank line. `deps` prints no header (all its values are
    // tabular), so it recurses with first_block = header = false, and the
    // first child header then satisfies `first_block || println(io)`
    // (print.jl:197). Expectation taken from the oracle, not guessed:
    //   julia -e 'using TOML; TOML.print(stdout, TOML.parsefile(f), sorted=true)'
    const out = try roundTrip(
        \\[deps.Foo]
        \\uuid = "a"
        \\[deps.Bar]
        \\uuid = "b"
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "\n[deps.Bar]\nuuid = \"b\"\n\n[deps.Foo]\nuuid = \"a\"\n",
        out,
    );
}

test "array of tables" {
    // Julia emits the separating blank line ONCE before the whole array
    // (print.jl:209), not between elements, and each element recurses with the
    // default first_block = true. So repeated same-key [[...]] blocks abut.
    // Verified against the oracle.
    const out = try roundTrip(
        \\[[deps.Foo]]
        \\uuid = "a"
        \\
        \\[[deps.Foo]]
        \\uuid = "b"
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "\n[[deps.Foo]]\nuuid = \"a\"\n[[deps.Foo]]\nuuid = \"b\"\n",
        out,
    );
}

test "inline tables become headers by default, matching Julia's round-trip" {
    const out = try roundTrip("a = { x = 1 }\n", .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[a]
        \\x = 1
        \\
    , out);

    const kept = try roundTrip("a = { x = 1 }\n", .{ .sorted = true, .respect_inline = true });
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("a = {x = 1}\n", kept);
}

test "keys are quoted and escaped only when necessary" {
    // Sorting compares the RAW key, not its quoted rendering, so `bare-key_9`
    // precedes `needs quotes` ('b' < 'n') even though the latter emits a
    // leading quote character.
    const out = try roundTrip(
        \\"needs quotes" = 1
        \\bare-key_9 = 2
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\bare-key_9 = 2
        \\"needs quotes" = 1
        \\
    , out);
}

test "string escaping, including the triple-quote-but-still-escaped case" {
    const out = try roundTrip(
        \\a = "tab\there"
        \\b = "quote\"inside"
        \\c = "multi\nline"
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\a = "tab\there"
        \\b = "quote\"inside"
        \\c = """multi\nline"""
        \\
    , out);
}

test "arrays print with ', ' separators" {
    const out = try roundTrip("deps = [\"A\", \"B\"]\nempty = []\n", .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("deps = [\"A\", \"B\"]\nempty = []\n", out);
}

test "float formatting matches Julia" {
    const cases = [_]struct { f: f64, want: []const u8 }{
        .{ .f = 1.0, .want = "1.0" },
        .{ .f = 1.5, .want = "1.5" },
        .{ .f = 0.1, .want = "0.1" },
        .{ .f = 100.0, .want = "100.0" },
        .{ .f = 100000.0, .want = "100000.0" },
        .{ .f = 1e6, .want = "1.0e6" },
        .{ .f = 1.234567e6, .want = "1.234567e6" },
        .{ .f = 0.0001, .want = "0.0001" },
        .{ .f = 1e-5, .want = "1.0e-5" },
        .{ .f = 2.5e-10, .want = "2.5e-10" },
        .{ .f = -17.25, .want = "-17.25" },
    };
    for (cases) |c| {
        var aw: Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try printFloat(&aw.writer, c.f);
        try testing.expectEqualStrings(c.want, aw.written());
    }

    for ([_]struct { f: f64, want: []const u8 }{
        .{ .f = std.math.nan(f64), .want = "nan" },
        .{ .f = std.math.inf(f64), .want = "+inf" },
        .{ .f = -std.math.inf(f64), .want = "-inf" },
    }) |c| {
        var aw: Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try printFloat(&aw.writer, c.f);
        try testing.expectEqualStrings(c.want, aw.written());
    }
}

test "nested tables indent by header depth" {
    const out = try roundTrip(
        \\[a]
        \\x = 1
        \\[a.b]
        \\y = 2
    , .{ .sorted = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[a]
        \\x = 1
        \\
        \\    [a.b]
        \\    y = 2
        \\
    , out);
}
