//! `Base.shell_escape` and `Base.shell_escape_wincmd` (`base/shell.jl`).
//!
//! Ports of the two quoting functions `Pkg.Apps` uses to build an app's shim.
//! `generate_shim` (`Pkg/src/Apps/Apps.jl:490-514`) runs the julia path and the
//! module spec through one of them depending on the host, and the result is
//! written into a file that a shell will later parse — so an escaping
//! difference here is not a cosmetic diff, it is a shim that runs the wrong
//! program or none at all.
//!
//! ## `shell_escape` is not "wrap it in single quotes"
//!
//! It is `print_shell_word` (`shell.jl:179-206`) with `special = ""`, and it has
//! four branches, in this order:
//!
//!   1. empty word            -> `''`
//!   2. nothing special in it -> the word verbatim, unquoted
//!   3. no `'` in it          -> `'word'`
//!   4. otherwise             -> `"word"`, with `"` and `$` backslash-escaped
//!
//! "Special" is `isspace(c) || c=='\\' || c=='\'' || c=='"' || c=='$'`. Branch 2
//! is the one a naive port gets wrong: `/usr/bin/julia` comes back **unquoted**,
//! and a shim that quotes it would still work while differing byte for byte from
//! Pkg's — which `tools/diff_harness/apps.sh` compares.
//!
//! Branch 4 does **not** escape backslashes, only `"` and `$`. That looks like a
//! defect in Julia and is reproduced deliberately: this file's contract is
//! "agrees with `Base`", and a Windows path with both a backslash and an
//! apostrophe is the only input that can tell the difference.
//!
//! `isspace` is Unicode-aware (`base/strings/unicode.jl`) — ASCII space, `\t`
//! through `\r`, U+0085, and category Zs from U+00A0 up. That is 23 code points
//! in total, enumerated in `space_code_points` below rather than approximated by
//! `c <= ' '`, because the difference is a path under a directory named with a
//! U+00A0 that Pkg quotes and a byte-comparing port would not.
//!
//! ## `shell_escape_wincmd` (`shell.jl:263-286`)
//!
//! `^`-escapes `"()!^<>&|`, escapes a LEADING `@` only, passes *pairs* of `"`
//! and everything between them through untouched, and raises on NUL/CR/LF. It
//! deliberately does **not** escape `%`, because cmd.exe expands variable
//! references before it processes `^` — the docstring says so at length, and
//! the caller is expected to know it.
//!
//! No I/O, allocator passed in: the layering rule for everything under
//! `julia/`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Every code point `Base.isspace` accepts, in order.
///
/// `isspace(c) = c == ' ' || '\t' <= c <= '\r' || c == '\u85' || ('\ua0' <= c &&
/// category_code(c) == UTF8PROC_CATEGORY_ZS)`. The Zs tail is a table rather
/// than a category lookup because it is 9 entries and utf8proc is not linked
/// here. Enumerated from a live Julia 1.12.6 over the whole code point range,
/// not from the Unicode data files:
///
/// ```julia
/// [c for cp in 0:0x10FFFF if isvalid(Char, cp) for c in (Char(cp),) if isspace(c)]
/// ```
///
/// Note U+180E is absent: it was Zs once and is Cf in the Unicode version
/// utf8proc ships here, so a table copied from an older reference would be
/// wrong by exactly one entry.
pub const space_code_points = [_]u21{
    0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0,
    0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
    0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000,
};

/// `Base.isspace(::AbstractChar)`.
pub fn isSpace(cp: u21) bool {
    for (space_code_points) |s| if (cp == s) return true;
    return false;
}

/// A decoded character plus the number of bytes it occupied.
///
/// Invalid UTF-8 decodes as the single byte it started with. Julia's `String`
/// can hold invalid UTF-8 too, and iterating it yields a replacement character
/// that is neither space nor special — so treating a bad byte as an ordinary
/// one keeps this total, exactly as `print_shell_word` is total.
const Char = struct { cp: u21, len: usize };

fn next(s: []const u8, i: usize) Char {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// `print_shell_word(io, word, special)` (`shell.jl:179-206`).
///
/// `special` is a set of EXTRA characters to treat as special, given as a
/// string the way Julia gives it. `Pkg.Apps` always passes the default, so
/// `escape` below is the entry point every caller here wants.
pub fn escapeWith(gpa: Allocator, word: []const u8, special: []const u8) Allocator.Error![]u8 {
    var has_single = false;
    var has_special = false;

    var i: usize = 0;
    while (i < word.len) {
        const c = next(word, i);
        i += c.len;
        const is_special = isSpace(c.cp) or
            c.cp == '\\' or c.cp == '\'' or c.cp == '"' or c.cp == '$' or
            (c.cp < 0x80 and std.mem.indexOfScalar(u8, special, @intCast(c.cp)) != null);
        if (!is_special) continue;
        has_special = true;
        if (c.cp == '\'') has_single = true;
    }

    if (word.len == 0) return gpa.dupe(u8, "''");
    if (!has_special) return gpa.dupe(u8, word);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (!has_single) {
        try out.ensureTotalCapacity(gpa, word.len + 2);
        out.appendAssumeCapacity('\'');
        out.appendSliceAssumeCapacity(word);
        out.appendAssumeCapacity('\'');
        return out.toOwnedSlice(gpa);
    }

    // The `"` branch. Backslashes are NOT escaped here -- see the header.
    try out.append(gpa, '"');
    i = 0;
    while (i < word.len) {
        const c = next(word, i);
        if (c.cp == '"' or c.cp == '$') try out.append(gpa, '\\');
        try out.appendSlice(gpa, word[i .. i + c.len]);
        i += c.len;
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

/// `Base.shell_escape(word)` — one word, default `special`.
pub fn escape(gpa: Allocator, word: []const u8) Allocator.Error![]u8 {
    return escapeWith(gpa, word, "");
}

pub const WincmdError = error{ControlCharacter} || Allocator.Error;

/// `Base.shell_escape_wincmd(s)` (`shell.jl:263-286`).
///
/// Raises on NUL, CR and LF, which cmd.exe cannot express at all — Julia throws
/// `ArgumentError("control character unsupported by CMD.EXE")`.
pub fn escapeWincmd(gpa: Allocator, s: []const u8) WincmdError![]u8 {
    for (s) |b| if (b == 0 or b == '\r' or b == '\n') return error.ControlCharacter;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // `if len > 0 && s[1] == '@'` -- the caret goes in FIRST and the `@` is then
    // written by the loop like any other character, so `@foo` becomes `^@foo`.
    if (s.len > 0 and s[0] == '@') try out.append(gpa, '^');

    var i: usize = 0;
    while (i < s.len) {
        const c = next(s, i);
        // A `"` with another `"` after it: the pair AND its contents pass
        // through verbatim, nothing inside is escaped.
        if (c.cp == '"') {
            if (std.mem.indexOfScalarPos(u8, s, i + c.len, '"')) |j| {
                try out.appendSlice(gpa, s[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }
        switch (c.cp) {
            '"', '(', ')', '!', '^', '<', '>', '&', '|' => {
                try out.append(gpa, '^');
                try out.appendSlice(gpa, s[i .. i + c.len]);
            },
            else => try out.appendSlice(gpa, s[i .. i + c.len]),
        }
        i += c.len;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEscape(want: []const u8, word: []const u8) !void {
    const got = try escape(testing.allocator, word);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectWincmd(want: []const u8, s: []const u8) !void {
    const got = try escapeWincmd(testing.allocator, s);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "shell_escape leaves an ordinary path alone" {
    // The branch a naive port misses. Oracle (Julia 1.12.6):
    //   Base.shell_escape("/usr/bin/julia")  => "/usr/bin/julia"
    try expectEscape("/usr/bin/julia", "/usr/bin/julia");
    try expectEscape("Foo.Bar", "Foo.Bar");
    try expectEscape("--threads=4", "--threads=4");
    // `#` and `&` are in `shell_special`, but `shell_escape`'s default
    // `special` is EMPTY, so they are not special here.
    try expectEscape("a&b", "a&b");
}

test "shell_escape single-quotes anything special without an apostrophe" {
    try expectEscape("'/path with space/julia'", "/path with space/julia");
    try expectEscape("'a$b'", "a$b");
    try expectEscape("'a\"b'", "a\"b");
    try expectEscape("'a\\b'", "a\\b");
}

test "shell_escape falls to double quotes once an apostrophe appears" {
    // Only `"` and `$` take a backslash; the backslash itself does not.
    try expectEscape("\"it's\"", "it's");
    try expectEscape("\"it's \\$HOME\"", "it's $HOME");
    try expectEscape("\"it's \\\"q\\\"\"", "it's \"q\"");
    try expectEscape("\"it's a\\b\"", "it's a\\b");
}

test "shell_escape spells the empty word ''" {
    try expectEscape("''", "");
}

test "shell_escape treats every code point Base calls space as special" {
    // U+00A0 is the one that separates a real port from `c <= ' '`.
    try expectEscape("'a\u{00A0}b'", "a\u{00A0}b");
    try expectEscape("'a\u{3000}b'", "a\u{3000}b");
    try expectEscape("'a\u{0085}b'", "a\u{0085}b");
    // U+180E was Zs in an older Unicode and is not one here.
    try expectEscape("a\u{180E}b", "a\u{180E}b");
    // A non-space multi-byte character is passed through unquoted.
    try expectEscape("café", "café");
}

test "shell_escape's `special` set adds characters without removing any" {
    const got = try escapeWith(testing.allocator, "a&b", "&");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("'a&b'", got);
}

test "shell_escape_wincmd carets the metacharacters" {
    try expectWincmd("C:\\julia\\bin\\julia.exe", "C:\\julia\\bin\\julia.exe");
    try expectWincmd("C:\\Users\\test user\\julia.exe", "C:\\Users\\test user\\julia.exe");
    try expectWincmd("a^&b", "a&b");
    try expectWincmd("a^|b^<c^>d", "a|b<c>d");
    try expectWincmd("^(x^)", "(x)");
    try expectWincmd("a^!b", "a!b");
    try expectWincmd("a^^b", "a^b");
    // `%` is deliberately NOT escaped.
    try expectWincmd("%USERPROFILE%", "%USERPROFILE%");
}

test "shell_escape_wincmd escapes @ only at the start" {
    try expectWincmd("^@echo", "@echo");
    try expectWincmd("a@b", "a@b");
}

test "shell_escape_wincmd passes a quoted pair through untouched" {
    // Everything between the two quotes survives verbatim -- including `&`.
    try expectWincmd("\"a&b\"", "\"a&b\"");
    // An unpaired quote is carets instead.
    try expectWincmd("^\"a^&b", "\"a&b");
    // Two pairs.
    try expectWincmd("\"a&b\"x\"c|d\"", "\"a&b\"x\"c|d\"");
}

test "shell_escape_wincmd refuses what cmd.exe cannot express" {
    try testing.expectError(error.ControlCharacter, escapeWincmd(testing.allocator, "a\nb"));
    try testing.expectError(error.ControlCharacter, escapeWincmd(testing.allocator, "a\rb"));
    try testing.expectError(error.ControlCharacter, escapeWincmd(testing.allocator, "a\x00b"));
}

test "the space table is exactly Base.isspace" {
    // Guards the table against a hand edit: the count is what the enumeration
    // in the doc comment returned, and the ASCII run is contiguous.
    try testing.expectEqual(@as(usize, 23), space_code_points.len);
    for (0x09..0x0E) |cp| try testing.expect(isSpace(@intCast(cp)));
    try testing.expect(isSpace(' '));
    try testing.expect(!isSpace(0x08));
    try testing.expect(!isSpace(0x0E));
    try testing.expect(!isSpace('a'));
}
