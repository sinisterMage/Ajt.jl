//! TOML v1.0.0 parser.
//!
//! Targets the whole spec rather than the subset the General registry happens
//! to use, because the same parser has to round-trip arbitrary user
//! `Project.toml` files including keys Ajt does not understand.
//!
//! Errors carry a `Diagnostic` (line, column, message) instead of a large
//! error set -- a package manager's job is to tell a human what is wrong with
//! their file, and `error.ParseFailed` plus a sentence beats twenty error tags.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Table = value_mod.Table;
const Document = value_mod.Document;
const DateTime = value_mod.DateTime;

pub const Error = error{ParseFailed} || Allocator.Error;

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("line {d}, column {d}: {s}", .{ self.line, self.column, self.message });
    }
};

pub fn parse(gpa: Allocator, text: []const u8, diag: ?*Diagnostic) Error!Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try Table.create(a);
    root.explicitly_defined = true;

    var sink: Diagnostic = .{};
    var p: Parser = .{
        .src = text,
        .arena = a,
        .root = root,
        .current = root,
        .diag = diag orelse &sink,
    };
    try p.parseDocument();

    return .{ .arena = arena, .root = root };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    line_start: usize = 0,
    arena: Allocator,
    root: *Table,
    current: *Table,
    diag: *Diagnostic,

    fn fail(self: *Parser, msg: []const u8) Error {
        self.diag.* = .{
            .line = self.line,
            .column = self.pos - self.line_start + 1,
            .message = msg,
        };
        return error.ParseFailed;
    }

    fn eof(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peekAt(self: *const Parser, off: usize) ?u8 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else null;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            self.pos += 1;
        }
    }

    fn accept(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.advance();
            return true;
        }
        return false;
    }

    /// Horizontal whitespace only.
    fn skipSpace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') self.advance() else break;
        }
    }

    fn skipComment(self: *Parser) void {
        if (self.peek() != '#') return;
        while (self.peek()) |c| {
            if (c == '\n') break;
            self.advance();
        }
    }

    /// Whitespace, comments and newlines -- i.e. everything between statements.
    fn skipTrivia(self: *Parser) void {
        while (self.peek()) |c| switch (c) {
            ' ', '\t', '\r', '\n' => self.advance(),
            '#' => self.skipComment(),
            else => return,
        };
    }

    /// After a statement: optional space, optional comment, then a newline or EOF.
    fn expectEol(self: *Parser) Error!void {
        self.skipSpace();
        self.skipComment();
        if (self.eof()) return;
        if (self.accept('\r')) {}
        if (self.accept('\n')) return;
        return self.fail("expected end of line");
    }

    fn parseDocument(self: *Parser) Error!void {
        while (true) {
            self.skipTrivia();
            if (self.eof()) return;
            if (self.peek() == '[') {
                try self.parseHeader();
            } else {
                try self.parseKeyValue(self.current);
                try self.expectEol();
            }
        }
    }

    // --- headers: [a.b] and [[a.b]] ----------------------------------------

    fn parseHeader(self: *Parser) Error!void {
        std.debug.assert(self.accept('['));
        const is_array = self.accept('[');

        self.skipSpace();
        const path = try self.parseKeyPath();
        self.skipSpace();
        if (!self.accept(']')) return self.fail("expected ']' closing table header");
        if (is_array and !self.accept(']')) return self.fail("expected ']]' closing array-of-tables header");

        self.current = if (is_array)
            try self.resolveArrayHeader(path)
        else
            try self.resolveTableHeader(path);

        try self.expectEol();
    }

    /// Walks/creates the intermediate tables for a header path. Intermediates
    /// are implicit: `[a.b]` may legally create `a`, and `a` stays open for a
    /// later explicit `[a]`.
    fn descend(self: *Parser, path: []const []const u8) Error!*Table {
        var t = self.root;
        for (path[0 .. path.len - 1]) |part| {
            if (t.getPtr(part)) |existing| {
                switch (existing.*) {
                    .table => |sub| {
                        if (sub.closed) return self.fail("cannot extend an inline table");
                        if (sub.from_dotted_key) return self.fail("cannot extend a table defined by a dotted key");
                        t = sub;
                    },
                    // Walking *through* an array of tables targets its last element.
                    .array => |items| {
                        if (!existing.isArrayOfTables()) return self.fail("key is not a table");
                        t = items[items.len - 1].table;
                    },
                    else => return self.fail("key is already defined as a non-table value"),
                }
            } else {
                const sub = try Table.create(self.arena);
                try t.put(self.arena, part, .{ .table = sub });
                t = sub;
            }
        }
        return t;
    }

    fn resolveTableHeader(self: *Parser, path: []const []const u8) Error!*Table {
        const parent = try self.descend(path);
        const last = path[path.len - 1];

        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .table => |sub| {
                    if (sub.explicitly_defined) return self.fail("table defined more than once");
                    if (sub.closed) return self.fail("cannot extend an inline table");
                    if (sub.from_dotted_key) return self.fail("cannot extend a table defined by a dotted key");
                    sub.explicitly_defined = true;
                    return sub;
                },
                else => return self.fail("key is already defined as a non-table value"),
            }
        }
        const sub = try Table.create(self.arena);
        sub.explicitly_defined = true;
        try parent.put(self.arena, last, .{ .table = sub });
        return sub;
    }

    fn resolveArrayHeader(self: *Parser, path: []const []const u8) Error!*Table {
        const parent = try self.descend(path);
        const last = path[path.len - 1];

        const elem = try Table.create(self.arena);
        elem.explicitly_defined = true;

        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .array => |items| {
                    if (items.len > 0 and !existing.isArrayOfTables())
                        return self.fail("cannot append a table to a non-table array");
                    const grown = try self.arena.alloc(Value, items.len + 1);
                    @memcpy(grown[0..items.len], items);
                    grown[items.len] = .{ .table = elem };
                    existing.* = .{ .array = grown };
                    return elem;
                },
                else => return self.fail("key is already defined as a non-array value"),
            }
        }
        const one = try self.arena.alloc(Value, 1);
        one[0] = .{ .table = elem };
        try parent.put(self.arena, last, .{ .array = one });
        return elem;
    }

    // --- keys ---------------------------------------------------------------

    fn parseKeyPath(self: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpace();
            try parts.append(self.arena, try self.parseKeyPart());
            self.skipSpace();
            if (!self.accept('.')) break;
        }
        return parts.items;
    }

    fn parseKeyPart(self: *Parser) Error![]const u8 {
        const c = self.peek() orelse return self.fail("expected a key");
        if (c == '"') return try self.parseBasicString();
        if (c == '\'') return try self.parseLiteralString();
        const start = self.pos;
        while (self.peek()) |ch| {
            if (isBareKeyChar(ch)) self.advance() else break;
        }
        if (self.pos == start) return self.fail("expected a key");
        return self.src[start..self.pos];
    }

    // --- key = value --------------------------------------------------------

    fn parseKeyValue(self: *Parser, table: *Table) Error!void {
        const path = try self.parseKeyPath();
        self.skipSpace();
        if (!self.accept('=')) return self.fail("expected '=' after key");
        self.skipSpace();

        // Dotted keys create intermediate tables that are sealed against later
        // header definitions (`a.b = 1` then `[a.b]` is an error).
        var t = table;
        for (path[0 .. path.len - 1]) |part| {
            if (t.getPtr(part)) |existing| {
                switch (existing.*) {
                    .table => |sub| {
                        if (sub.closed or sub.explicitly_defined)
                            return self.fail("cannot extend this table with a dotted key");
                        t = sub;
                    },
                    else => return self.fail("key is already defined as a non-table value"),
                }
            } else {
                const sub = try Table.create(self.arena);
                sub.from_dotted_key = true;
                try t.put(self.arena, part, .{ .table = sub });
                t = sub;
            }
        }

        const last = path[path.len - 1];
        if (t.contains(last)) return self.fail("duplicate key");
        const v = try self.parseValue();
        try t.put(self.arena, last, v);
    }

    // --- values -------------------------------------------------------------

    fn parseValue(self: *Parser) Error!Value {
        const c = self.peek() orelse return self.fail("expected a value");
        return switch (c) {
            '"' => .{ .string = try self.parseStringValue() },
            '\'' => .{ .string = try self.parseStringValue() },
            '[' => try self.parseArray(),
            '{' => try self.parseInlineTable(),
            't', 'f' => try self.parseBool(),
            else => try self.parseNumberOrDate(),
        };
    }

    fn parseStringValue(self: *Parser) Error![]const u8 {
        if (self.peek() == '"') {
            if (self.peekAt(1) == '"' and self.peekAt(2) == '"') return try self.parseMultilineBasicString();
            return try self.parseBasicString();
        }
        if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') return try self.parseMultilineLiteralString();
        return try self.parseLiteralString();
    }

    fn parseBool(self: *Parser) Error!Value {
        if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
            for (0..4) |_| self.advance();
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
            for (0..5) |_| self.advance();
            return .{ .boolean = false };
        }
        return self.fail("invalid value");
    }

    fn parseArray(self: *Parser) Error!Value {
        std.debug.assert(self.accept('['));
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            self.skipTrivia(); // arrays may span lines and hold comments
            if (self.eof()) return self.fail("unterminated array");
            if (self.accept(']')) break;
            try items.append(self.arena, try self.parseValue());
            self.skipTrivia();
            if (self.accept(',')) continue;
            self.skipTrivia();
            if (self.accept(']')) break;
            return self.fail("expected ',' or ']' in array");
        }
        return .{ .array = items.items };
    }

    fn parseInlineTable(self: *Parser) Error!Value {
        std.debug.assert(self.accept('{'));
        const t = try Table.create(self.arena);
        t.is_inline = true;
        t.closed = true;
        t.explicitly_defined = true;

        self.skipSpace();
        if (self.accept('}')) return .{ .table = t };
        while (true) {
            self.skipSpace();
            try self.parseKeyValue(t);
            self.skipSpace();
            if (self.accept(',')) continue;
            if (self.accept('}')) break;
            return self.fail("expected ',' or '}' in inline table");
        }
        return .{ .table = t };
    }

    // --- numbers and dates --------------------------------------------------

    fn parseNumberOrDate(self: *Parser) Error!Value {
        // Dates are unambiguous by shape: `dddd-` is a date, `dd:` is a time.
        if (self.isDigit(0) and self.isDigit(1) and self.isDigit(2) and self.isDigit(3) and self.peekAt(4) == '-')
            return try self.parseDateTime();
        if (self.isDigit(0) and self.isDigit(1) and self.peekAt(2) == ':')
            return try self.parseDateTime();

        const start = self.pos;
        if (self.peek() == '+' or self.peek() == '-') self.advance();

        // inf / nan, with the sign already consumed
        if (std.mem.startsWith(u8, self.src[self.pos..], "inf")) {
            for (0..3) |_| self.advance();
            const neg = self.src[start] == '-';
            return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "nan")) {
            for (0..3) |_| self.advance();
            return .{ .float = std.math.nan(f64) };
        }

        // Radix-prefixed integers never carry a sign or a fractional part.
        if (self.peek() == '0') {
            if (self.peekAt(1)) |r| switch (r) {
                'x', 'o', 'b' => return try self.parseRadixInteger(r),
                else => {},
            };
        }

        var is_float = false;
        while (self.peek()) |c| {
            switch (c) {
                '0'...'9', '_', '+', '-' => self.advance(),
                '.' => {
                    is_float = true;
                    self.advance();
                },
                'e', 'E' => {
                    is_float = true;
                    self.advance();
                },
                else => break,
            }
        }
        const lexeme = self.src[start..self.pos];
        if (lexeme.len == 0) return self.fail("expected a value");

        var buf: [64]u8 = undefined;
        const clean = stripUnderscores(&buf, lexeme) orelse return self.fail("number literal is too long");

        if (is_float) {
            const f = std.fmt.parseFloat(f64, clean) catch return self.fail("invalid float literal");
            return .{ .float = f };
        }
        const i = std.fmt.parseInt(i64, clean, 10) catch return self.fail("invalid integer literal");
        return .{ .integer = i };
    }

    fn parseRadixInteger(self: *Parser, radix_char: u8) Error!Value {
        self.advance(); // '0'
        self.advance(); // radix
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') self.advance() else break;
        }
        var buf: [64]u8 = undefined;
        const clean = stripUnderscores(&buf, self.src[start..self.pos]) orelse
            return self.fail("integer literal is too long");
        const base: u8 = switch (radix_char) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => unreachable,
        };
        const i = std.fmt.parseInt(i64, clean, base) catch return self.fail("invalid integer literal");
        return .{ .integer = i };
    }

    fn isDigit(self: *const Parser, off: usize) bool {
        const c = self.peekAt(off) orelse return false;
        return c >= '0' and c <= '9';
    }

    fn parseDateTime(self: *Parser) Error!Value {
        var dt: DateTime = .{ .kind = .date };

        // time-only
        if (self.isDigit(0) and self.isDigit(1) and self.peekAt(2) == ':') {
            dt.kind = .time;
            try self.readTime(&dt);
            return .{ .datetime = dt };
        }

        dt.year = @intCast(try self.readFixedInt(4));
        if (!self.accept('-')) return self.fail("expected '-' in date");
        dt.month = @intCast(try self.readFixedInt(2));
        if (!self.accept('-')) return self.fail("expected '-' in date");
        dt.day = @intCast(try self.readFixedInt(2));

        const sep = self.peek() orelse return .{ .datetime = dt };
        if (sep != 'T' and sep != 't' and sep != ' ') return .{ .datetime = dt };
        // A bare `space` only starts a time if digits follow (otherwise it is
        // just the whitespace before a comment or newline).
        if (sep == ' ' and !(self.isDigit(1) and self.isDigit(2) and self.peekAt(3) == ':'))
            return .{ .datetime = dt };

        self.advance();
        dt.kind = .datetime;
        try self.readTime(&dt);

        // Timezone offset is parsed and discarded, matching Julia's parser.
        if (self.peek()) |z| switch (z) {
            'Z', 'z' => self.advance(),
            '+', '-' => {
                self.advance();
                _ = try self.readFixedInt(2);
                if (!self.accept(':')) return self.fail("expected ':' in timezone offset");
                _ = try self.readFixedInt(2);
            },
            else => {},
        };
        return .{ .datetime = dt };
    }

    fn readTime(self: *Parser, dt: *DateTime) Error!void {
        dt.hour = @intCast(try self.readFixedInt(2));
        if (!self.accept(':')) return self.fail("expected ':' in time");
        dt.minute = @intCast(try self.readFixedInt(2));
        if (!self.accept(':')) return self.fail("expected ':' in time");
        dt.second = @intCast(try self.readFixedInt(2));
        if (self.accept('.')) {
            // Julia formats milliseconds, so keep 3 digits and drop the rest.
            var digits: usize = 0;
            var ms: u16 = 0;
            while (self.peek()) |c| {
                if (c < '0' or c > '9') break;
                if (digits < 3) ms = ms * 10 + @as(u16, c - '0');
                digits += 1;
                self.advance();
            }
            if (digits == 0) return self.fail("expected fractional seconds");
            while (digits < 3) : (digits += 1) ms *= 10;
            dt.millisecond = ms;
        }
    }

    fn readFixedInt(self: *Parser, n: usize) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            const c = self.peek() orelse return self.fail("unexpected end of date/time");
            if (c < '0' or c > '9') return self.fail("expected a digit in date/time");
            v = v * 10 + (c - '0');
            self.advance();
        }
        return v;
    }

    // --- strings ------------------------------------------------------------

    fn parseBasicString(self: *Parser) Error![]const u8 {
        std.debug.assert(self.accept('"'));
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated string");
            switch (c) {
                '"' => {
                    self.advance();
                    return out.items;
                },
                '\n' => return self.fail("newline in single-line string"),
                '\\' => {
                    self.advance();
                    try self.parseEscape(&out);
                },
                else => {
                    try out.append(self.arena, c);
                    self.advance();
                },
            }
        }
    }

    fn parseMultilineBasicString(self: *Parser) Error![]const u8 {
        for (0..3) |_| self.advance();
        // A newline immediately after the opening delimiter is trimmed.
        if (self.peek() == '\r') self.advance();
        if (self.peek() == '\n') self.advance();

        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line string");
            if (c == '"' and self.peekAt(1) == '"' and self.peekAt(2) == '"') {
                for (0..3) |_| self.advance();
                // TOML allows up to two extra quotes to abut the delimiter.
                var extra: usize = 0;
                while (extra < 2 and self.peek() == '"') : (extra += 1) {
                    try out.append(self.arena, '"');
                    self.advance();
                }
                return out.items;
            }
            if (c == '\\') {
                // A backslash before a newline swallows all following whitespace.
                var look = self.pos + 1;
                while (look < self.src.len and (self.src[look] == ' ' or self.src[look] == '\t' or self.src[look] == '\r')) look += 1;
                if (look < self.src.len and self.src[look] == '\n') {
                    self.advance();
                    while (self.peek()) |w| {
                        if (w == ' ' or w == '\t' or w == '\r' or w == '\n') self.advance() else break;
                    }
                    continue;
                }
                self.advance();
                try self.parseEscape(&out);
                continue;
            }
            try out.append(self.arena, c);
            self.advance();
        }
    }

    fn parseLiteralString(self: *Parser) Error![]const u8 {
        std.debug.assert(self.accept('\''));
        const start = self.pos;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated literal string");
            if (c == '\n') return self.fail("newline in single-line literal string");
            if (c == '\'') {
                const s = self.src[start..self.pos];
                self.advance();
                return s;
            }
            self.advance();
        }
    }

    fn parseMultilineLiteralString(self: *Parser) Error![]const u8 {
        for (0..3) |_| self.advance();
        if (self.peek() == '\r') self.advance();
        if (self.peek() == '\n') self.advance();
        const start = self.pos;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line literal string");
            if (c == '\'' and self.peekAt(1) == '\'' and self.peekAt(2) == '\'') {
                const s = self.src[start..self.pos];
                for (0..3) |_| self.advance();
                return s;
            }
            self.advance();
        }
    }

    fn parseEscape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        const c = self.peek() orelse return self.fail("unterminated escape sequence");
        self.advance();
        const simple: ?u8 = switch (c) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0C,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'e' => 0x1B, // TOML 1.1; harmless to accept
            else => null,
        };
        if (simple) |s| {
            try out.append(self.arena, s);
            return;
        }
        const width: usize = switch (c) {
            'u' => 4,
            'U' => 8,
            else => return self.fail("unknown escape sequence"),
        };
        var cp: u32 = 0;
        for (0..width) |_| {
            const h = self.peek() orelse return self.fail("truncated unicode escape");
            const d = std.fmt.charToDigit(h, 16) catch return self.fail("invalid hex digit in unicode escape");
            cp = cp * 16 + d;
            self.advance();
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return self.fail("unicode escape is not a valid scalar value");
        try out.appendSlice(self.arena, buf[0..n]);
    }
};

/// Matches Julia's `isvalid_barekey_char` (base/toml_parser.jl:590-594).
pub fn isBareKeyChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_';
}

fn stripUnderscores(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(src: []const u8) !Document {
    return parse(testing.allocator, src, null);
}

test "scalars, arrays and nested tables" {
    var doc = try parseForTest(
        \\name = "OpenReality"
        \\version = "0.1.0"
        \\count = 42
        \\ratio = 1.5
        \\yes = true
        \\list = ["a", "b"]
        \\
        \\[deps]
        \\Ark = "56664e29-41e4-4ea5-ab0e-825499acc647"
        \\
        \\[compat]
        \\julia = "1.9"
    );
    defer doc.deinit();

    try testing.expectEqualStrings("OpenReality", doc.root.get("name").?.string);
    try testing.expectEqual(@as(i64, 42), doc.root.get("count").?.integer);
    try testing.expectEqual(@as(f64, 1.5), doc.root.get("ratio").?.float);
    try testing.expect(doc.root.get("yes").?.boolean);
    try testing.expectEqual(@as(usize, 2), doc.root.get("list").?.array.len);

    const deps = doc.root.get("deps").?.table;
    try testing.expectEqualStrings("56664e29-41e4-4ea5-ab0e-825499acc647", deps.get("Ark").?.string);
    try testing.expectEqualStrings("1.9", doc.root.get("compat").?.table.get("julia").?.string);
}

test "array of tables accumulates elements" {
    var doc = try parseForTest(
        \\[[deps.Foo]]
        \\uuid = "aaa"
        \\
        \\[[deps.Foo]]
        \\uuid = "bbb"
    );
    defer doc.deinit();

    const foo = doc.root.get("deps").?.table.get("Foo").?;
    try testing.expect(foo.isArrayOfTables());
    try testing.expectEqual(@as(usize, 2), foo.array.len);
    try testing.expectEqualStrings("aaa", foo.array[0].table.get("uuid").?.string);
    try testing.expectEqualStrings("bbb", foo.array[1].table.get("uuid").?.string);
}

test "inline tables and dotted keys" {
    var doc = try parseForTest(
        \\a = { x = 1, y = "two" }
        \\b.c.d = true
    );
    defer doc.deinit();

    const a = doc.root.get("a").?.table;
    try testing.expect(a.is_inline);
    try testing.expectEqual(@as(i64, 1), a.get("x").?.integer);
    try testing.expect(doc.root.get("b").?.table.get("c").?.table.get("d").?.boolean);
}

test "string forms" {
    var doc = try parseForTest(
        \\basic = "a\tb\ncA"
        \\literal = 'raw\nnot escaped'
        \\multi = """
        \\line1
        \\line2"""
    );
    defer doc.deinit();

    try testing.expectEqualStrings("a\tb\ncA", doc.root.get("basic").?.string);
    try testing.expectEqualStrings("raw\\nnot escaped", doc.root.get("literal").?.string);
    try testing.expectEqualStrings("line1\nline2", doc.root.get("multi").?.string);
}

test "numbers: radix, underscores, exponents, inf/nan" {
    var doc = try parseForTest(
        \\hex = 0xFF
        \\oct = 0o755
        \\bin = 0b1011
        \\big = 1_000_000
        \\neg = -17
        \\exp = 1e3
        \\pinf = inf
        \\ninf = -inf
        \\nn = nan
    );
    defer doc.deinit();

    try testing.expectEqual(@as(i64, 255), doc.root.get("hex").?.integer);
    try testing.expectEqual(@as(i64, 493), doc.root.get("oct").?.integer);
    try testing.expectEqual(@as(i64, 11), doc.root.get("bin").?.integer);
    try testing.expectEqual(@as(i64, 1000000), doc.root.get("big").?.integer);
    try testing.expectEqual(@as(i64, -17), doc.root.get("neg").?.integer);
    try testing.expectEqual(@as(f64, 1000), doc.root.get("exp").?.float);
    try testing.expect(std.math.isPositiveInf(doc.root.get("pinf").?.float));
    try testing.expect(std.math.isNegativeInf(doc.root.get("ninf").?.float));
    try testing.expect(std.math.isNan(doc.root.get("nn").?.float));
}

test "dates decompose for Julia-compatible re-formatting" {
    var doc = try parseForTest(
        \\dt = 1979-05-27T07:32:00Z
        \\d = 1979-05-27
        \\t = 07:32:00.5
    );
    defer doc.deinit();

    const dt = doc.root.get("dt").?.datetime;
    try testing.expectEqual(DateTime.Kind.datetime, dt.kind);
    try testing.expectEqual(@as(u16, 1979), dt.year);
    try testing.expectEqual(@as(u8, 7), dt.hour);

    try testing.expectEqual(DateTime.Kind.date, doc.root.get("d").?.datetime.kind);
    // .5 must widen to 500 milliseconds, not stay 5.
    try testing.expectEqual(@as(u16, 500), doc.root.get("t").?.datetime.millisecond);
}

test "comments and blank lines are ignored" {
    var doc = try parseForTest(
        \\# leading comment
        \\a = 1 # trailing comment
        \\
        \\# another
        \\[t] # after header
        \\b = 2
    );
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.root.get("t").?.table.get("b").?.integer);
}

test "multi-line arrays with trailing commas" {
    var doc = try parseForTest(
        \\deps = [
        \\  "A", # first
        \\  "B",
        \\]
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.get("deps").?.array.len);
}

test "rejects duplicate keys and redefined tables" {
    var d: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, parse(testing.allocator, "a = 1\na = 2\n", &d));
    try testing.expectEqualStrings("duplicate key", d.message);
    try testing.expectError(error.ParseFailed, parse(testing.allocator, "[t]\n[t]\n", &d));
    try testing.expectError(error.ParseFailed, parse(testing.allocator, "a = { x = 1 }\n[a.b]\n", &d));
}

test "quoted keys" {
    var doc = try parseForTest(
        \\"quoted key" = 1
        \\'lit' = 2
        \\[a."b.c"]
        \\d = 3
    );
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.get("quoted key").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.root.get("lit").?.integer);
    try testing.expectEqual(@as(i64, 3), doc.root.get("a").?.table.get("b.c").?.table.get("d").?.integer);
}
