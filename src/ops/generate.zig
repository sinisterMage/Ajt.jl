//! `ajt generate <path>` — scaffold a new package.
//!
//! Port of the whole of `Pkg/src/generate.jl` (75 lines). The striking thing
//! about that file is how little it does: **two** files, `Project.toml` and
//! `src/<Pkg>.jl`, and nothing else. No `.gitignore`, no `test/runtests.jl`,
//! no LICENSE, no `git init`. Every generator that grew those conveniences is
//! a different tool (PkgTemplates.jl); reproducing them here would make
//! `ajt generate` produce a directory `Pkg.generate` never would, which is the
//! one thing a drop-in may not do.
//!
//! Four corners carry all the risk, and three of them are invisible in the
//! output until you diff against Pkg:
//!
//! **1. The name is `basename`, `.jl` chopped, and must be an identifier**
//! (`generate.jl:4-6`). `basename` is Julia's, not the platform's — see
//! `juliaBasename` — and `endswith(lowercase(base), ".jl")` means `Foo.JL`
//! chops too. The check is `Base.isidentifier`, so `1Foo`, `Foo-Bar`, `true`
//! and the empty string are all refused *before* the directory is looked at.
//!
//! **2. The authors string ends in a space when there is no email.** The
//! source is `"$name " * (email === nothing ? "" : "<$email>")`
//! (`generate.jl:47`) — the space is *outside* the conditional, so a package
//! generated on a machine with a git `user.name` and no `user.email` gets
//! `authors = ["Ada Lovelace "]`. It looks like a bug and it is in every
//! Project.toml Pkg has ever generated without an email; a "tidier" trailing
//! `strip` here would make the two tools produce different bytes for the same
//! machine.
//!
//! **3. An env var set to the EMPTY STRING wins the fallback.** The git config
//! is skipped when empty (`isempty(gitname) || (name = gitname)`), but the ENV
//! loop breaks on `!== nothing` (`:31-35`), so `USER=` yields `name = ""` and
//! the `"Unknown"` default never fires. `authors = [" <a@b>"]` is a real Pkg
//! output.
//!
//! **4. Name and email fall back INDEPENDENTLY.** Git supplying `user.name`
//! does not stop the email chain from running, so a git-configured name can be
//! paired with `$EMAIL`. Two separate loops, not one.
//!
//! ## Where the git config comes from
//!
//! Pkg reads it with `LibGit2.getconfig(name, "")` (`generate.jl:25-28`), which
//! is libgit2's `git_config_open_default` — **no repository is opened**, so the
//! levels it sees are programdata (Windows), system, XDG and global, and
//! emphatically *not* the local `.git/config` of whatever directory you happen
//! to be standing in.
//!
//! A plain `git config --get user.name` would therefore be wrong: run inside a
//! repository that sets a local `user.name`, it answers with an identity Pkg
//! cannot see. `git config --global --get` is the match — git's "global" scope
//! is `$XDG_CONFIG_HOME/git/config` plus `~/.gitconfig`, exactly libgit2's two
//! upper levels, with the same precedence — and `--system --get` covers
//! `/etc/gitconfig` underneath it. `git/cli.zig:configGet` runs those two, in
//! that order.
//!
//! `git` may be missing entirely, which is not an error: libgit2 finding no
//! `user.name` and `git` not existing produce the same empty string, and the
//! ENV chain takes over. That path is the one to keep working — it is what a
//! container without git does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const project_mod = @import("../model/project.zig");
const version_mod = @import("../julia/version.zig");
const value_mod = @import("../toml/value.zig");
const slug = @import("../julia/slug.zig");
const git_cli = @import("../git/cli.zig");

pub const Uuid = slug.Uuid;

pub const Error = error{
    /// `Base.isidentifier(pkg)` was false (`generate.jl:6`).
    InvalidPackageName,
    /// The name is outside ASCII, where `Base.isidentifier` needs Unicode
    /// general categories that Ajt does not carry. Refused rather than guessed
    /// — see `isIdentifier`.
    NonAsciiPackageName,
    /// `isdir(path)` (`generate.jl:7`).
    AlreadyExists,
};

/// Identity inputs, injected rather than read, so the whole fallback chain is
/// unit-testable without a git config or a process environment to corrupt.
/// `null` means "absent"; an empty string is NOT absent for `environ` lookups
/// (corner 3 in the header) but IS for the two git fields (`isempty(...)`).
pub const Identity = struct {
    git_name: ?[]const u8 = null,
    git_email: ?[]const u8 = null,
    environ: ?*const std.process.Environ.Map = null,
};

pub const Options = struct {
    /// The path as the user typed it. Both the package name and the directory
    /// come from this, and it is NOT normalised first — see `juliaBasename`.
    path: []const u8,
    /// Where the `authors` entry comes from. `.probe` runs `git config` and
    /// reads the environment — and does so only AFTER the name and the
    /// directory have been accepted, so `ajt generate Bad-Name` spawns nothing.
    /// `.given` is the seam the unit tests drive the whole fallback chain
    /// through without a git config or a process environment to corrupt.
    identity: union(enum) {
        given: Identity,
        probe: ?*const std.process.Environ.Map,
    } = .{ .given = .{} },
    /// The 16 raw entropy bytes for the uuid. Null draws from `io.random`,
    /// which is the CSPRNG; a test passes its own so the output is checkable.
    entropy: ?[16]u8 = null,
};

pub const Report = struct {
    /// `basename(path)` with `.jl` chopped.
    pkg: []const u8,
    uuid: Uuid,
    /// The two paths, in the order `generate` prints them. Arena-owned.
    project_file: []const u8,
    entry_file: []const u8,
};

/// `generate(path)` (`generate.jl:3-12`). The order matters: the NAME is
/// validated before the directory is checked, so `ajt generate ./Foo-Bar` on an
/// existing `Foo-Bar/` reports the name, exactly as Pkg does.
pub fn run(arena: Allocator, io: Io, opts: Options) !Report {
    const pkg = try packageName(juliaBasename(opts.path));

    // `isdir(path)` — a symlink to a directory counts, which is what both
    // Julia's `isdir` and `openDir` do.
    if (Io.Dir.cwd().openDir(io, opts.path, .{})) |d| {
        var dir = d;
        dir.close(io);
        return Error.AlreadyExists;
    } else |_| {}

    const src_dir = try std.fs.path.join(arena, &.{ opts.path, "src" });
    const project_file = try std.fs.path.join(arena, &.{ opts.path, "Project.toml" });
    const entry_file = try std.fmt.allocPrint(arena, "{s}{c}{s}.jl", .{ src_dir, std.fs.path.sep, pkg });

    var entropy: [16]u8 = undefined;
    if (opts.entropy) |e| entropy = e else io.random(&entropy);
    const uuid = uuid4(entropy);

    // Both refusals are behind us, so this is the first point at which spawning
    // `git` can possibly be useful.
    const identity: Identity = switch (opts.identity) {
        .given => |id| id,
        .probe => |environ| gitIdentity(arena, io, environ),
    };

    // `project` (`:22-59`): mkpath the directory, then genfile writes.
    try Io.Dir.cwd().createDirPath(io, opts.path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = project_file,
        .data = try renderProject(arena, pkg, uuid, try authors(arena, identity)),
    });

    // `entrypoint` (`:61-75`). `genfile` mkpaths `dirname(path)`, which is the
    // only reason `src/` exists.
    try Io.Dir.cwd().createDirPath(io, src_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = entry_file,
        .data = try entrypoint(arena, pkg),
    });

    return .{
        .pkg = pkg,
        .uuid = uuid,
        .project_file = project_file,
        .entry_file = entry_file,
    };
}

// ---------------------------------------------------------------------------
// The package name

/// `basename(path)` as **Julia** computes it (`base/path.jl:187`,
/// `path_dir_splitter = r"^(.*?)(/+)([^/]*)$"`): everything after the last `/`,
/// with no trailing-separator handling at all.
///
/// `std.fs.path.basename` is not a substitute and the difference is reachable
/// from the command line: it strips trailing slashes, so `ajt generate Foo/`
/// would yield `Foo` and scaffold a package, where `Pkg.generate("Foo/")` gets
/// the empty string and errors with `"" is not a valid package name`.
///
/// POSIX only. Julia also splits on `\` under Windows (`path_dir_splitter`
/// differs per platform); Ajt has no Windows path handling anywhere yet, and
/// half of it here would be worse than none.
pub fn juliaBasename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// `endswith(lowercase(base), ".jl") ? chop(base, tail = 3) : base`, then
/// `Base.isidentifier` (`generate.jl:4-6`).
///
/// `chop(base, tail = 3)` counts **characters**, not bytes; for a name ending
/// in ASCII `.jl` those are the same three bytes, and the lowercase compare has
/// already established that they are ASCII.
pub fn packageName(base: []const u8) Error![]const u8 {
    const pkg = if (base.len >= 3 and std.ascii.eqlIgnoreCase(base[base.len - 3 ..], ".jl"))
        base[0 .. base.len - 3]
    else
        base;
    if (!try isIdentifier(pkg)) return Error.InvalidPackageName;
    return pkg;
}

/// `Base.isidentifier` (`base/show.jl:1565-1572`) for ASCII.
///
/// The character classes are `jl_id_start_char`/`jl_id_char` in
/// `src/flisp/julia_extensions.c`, whose ASCII arms are `A-Za-z_` for the first
/// character and `A-Za-z_0-9!` for the rest — pinned by asking the running
/// Julia for every codepoint below 128 rather than transcribing the C. `true`
/// and `false` are special-cased, and the empty string is false.
///
/// Above ASCII the C consults utf8proc general categories (`Lu Ll Lt Lm Lo Nl
/// Sc`, most of `So`, plus the combining/number/prime classes for continuation
/// characters, with arrows and a handful of individual codepoints carved out).
/// Shipping that table for a package name is not proportionate, and *guessing*
/// is the failure this codebase exists to avoid — a permissive guess would
/// scaffold a package Julia's parser cannot name, a restrictive one would
/// refuse a package Pkg generates happily. So a non-ASCII name is a distinct,
/// visible refusal, and `Ajt.jl` delegates that case to Pkg, where the real
/// tables live. Note that everything in 0x80..0xA0 is unconditionally NOT an
/// identifier character (`wc < 0xA1` in the C), so only 0xA1 and above are
/// genuinely undecidable here.
pub fn isIdentifier(s: []const u8) Error!bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return false;
    if (!try idChar(s[0], .start)) return false;
    for (s[1..]) |c| {
        if (!try idChar(c, .continuation)) return false;
    }
    return true;
}

/// `jl_id_start_char` / `jl_id_char`, which differ only in the four extra
/// classes the continuation form accepts.
fn idChar(c: u8, kind: enum { start, continuation }) Error!bool {
    if (c >= 0x80) return Error.NonAsciiPackageName;
    return switch (c) {
        'A'...'Z', 'a'...'z', '_' => true,
        '0'...'9', '!' => kind == .continuation,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// The uuid

/// `UUIDs.uuid4` (`UUIDs.jl:116-121`), which masks a random `UInt128` with
/// `0xffffffffffff0fff3fffffffffffffff` and ors in
/// `0x00000000000040008000000000000000`.
///
/// In the canonical byte order `Uuid` stores (big-endian, the order the text
/// form is written in) those two constants land on exactly two bytes: byte 6
/// carries the version nibble `4` in its high half, and byte 8 carries the
/// RFC 4122 variant `10` in its top two bits — so the printed uuid has a `4` at
/// text position 14 and one of `8 9 a b` at position 19. Taking the mask
/// literally against a little-endian u128 would put both in the wrong half of
/// the string.
pub fn uuid4(entropy: [16]u8) Uuid {
    var u: Uuid = .{ .bytes = entropy };
    u.bytes[6] = (u.bytes[6] & 0x0f) | 0x40;
    u.bytes[8] = (u.bytes[8] & 0x3f) | 0x80;
    return u;
}

// ---------------------------------------------------------------------------
// The authors entry

/// The `authors` string (`generate.jl:24-47`) — one entry, and the fallback
/// chain in the header. Arena-owned.
pub fn authors(arena: Allocator, id: Identity) Allocator.Error![]const u8 {
    // Two chains, written as two, because in `generate.jl` they ARE two: git
    // supplying a name does not stop the email chain (corner 4). `"Unknown"`
    // sits at the end of the first and has no counterpart in the second, which
    // is why one falls out non-optional and the other does not.
    const name: []const u8 = nonEmpty(id.git_name) orelse
        firstEnv(id.environ, &.{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER", "USERNAME", "NAME" }) orelse
        "Unknown";
    const email: ?[]const u8 = nonEmpty(id.git_email) orelse
        firstEnv(id.environ, &.{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL" });

    // `"$name " * (email === nothing ? "" : "<$email>")` — the trailing space
    // is unconditional. See corner 2 in the header.
    if (email) |e| return std.fmt.allocPrint(arena, "{s} <{s}>", .{ name, e });
    return std.fmt.allocPrint(arena, "{s} ", .{name});
}

/// `isempty(gitname) || (name = gitname)`: libgit2's default for a missing key
/// is `""`, so empty and absent are the same thing for the two GIT fields —
/// and only for them. `firstEnv` deliberately does not do this.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

/// `get(ENV, env, nothing)` over a list, breaking on the first key that is
/// PRESENT — an empty value is present, which is corner 3.
fn firstEnv(environ: ?*const std.process.Environ.Map, keys: []const []const u8) ?[]const u8 {
    const env = environ orelse return null;
    for (keys) |k| if (env.get(k)) |v| return v;
    return null;
}

/// The two `git config` probes libgit2's default config is equivalent to; see
/// the header. Returns `null` fields when neither scope answers, which includes
/// `git` not being installed.
///
/// Takes the allocator that will OWN the two strings — pass the arena the
/// generate call runs on. `configGet` allocates through it and the caller
/// otherwise has to remember to free two optionals it never looks at again.
pub fn gitIdentity(arena: Allocator, io: Io, environ: ?*const std.process.Environ.Map) Identity {
    // `git.Cli.program`'s default, and the same name `git_cli.available` is
    // asked about. A host that spells it otherwise configures the Cli backend,
    // which this is deliberately not part of — see `configGet`'s header.
    const program = git_cli.Cli.default_program;
    return .{
        .git_name = git_cli.configGet(arena, io, program, environ, "user.name"),
        .git_email = git_cli.configGet(arena, io, program, environ, "user.email"),
        .environ = environ,
    };
}

// ---------------------------------------------------------------------------
// The two files

/// The `Project.toml` body (`generate.jl:48-57`).
///
/// Built through `model.Project` rather than printed by hand, so the key order
/// is the one `render` already implements — `_project_key_order` puts `name`
/// and `uuid` first and `version` sixth, while `authors` is unlisted and
/// therefore sorts last. (Pkg calls `TOML.print` directly here rather than
/// `write_project`; the difference is `inline_tables` and a value-transform
/// closure, and this table has neither a sub-table nor a non-string value, so
/// the two produce the same bytes.)
pub fn renderProject(
    arena: Allocator,
    pkg: []const u8,
    uuid: Uuid,
    author: []const u8,
) !([]u8) {
    var p = try project_mod.empty(arena);
    defer p.deinit();
    try p.setName(pkg);
    p.setUuid(uuid);
    try p.setVersion(try version_mod.parse(p.arena(), "0.1.0"));

    // `authors` has no typed field — `destructure` carries it through
    // `Project.other` untouched (`project.jl:264`), which is the same route it
    // survives a round-trip by.
    const items = try p.arena().alloc(value_mod.Value, 1);
    items[0] = .{ .string = try p.arena().dupe(u8, author) };
    try p.other().put(p.arena(), "authors", .{ .array = items });

    return p.render(arena);
}

/// `entrypoint` (`:61-75`). Copied character for character from the
/// triple-quoted literal, trailing newline included.
pub fn entrypoint(arena: Allocator, pkg: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena,
        \\module {s}
        \\
        \\greet() = print("Hello World!")
        \\
        \\end # module {s}
        \\
    , .{ pkg, pkg });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "package name: .jl is chopped case-insensitively, basename is Julia's" {
    try testing.expectEqualStrings("Foo", try packageName(juliaBasename("Foo")));
    try testing.expectEqualStrings("Foo", try packageName(juliaBasename("Foo.jl")));
    try testing.expectEqualStrings("Foo", try packageName(juliaBasename("Foo.JL")));
    try testing.expectEqualStrings("Foo", try packageName(juliaBasename("a/b/Foo.jl")));
    // `.jl` alone chops to the empty string, which is not an identifier.
    try testing.expectError(Error.InvalidPackageName, packageName(juliaBasename(".jl")));
    // The trailing-slash divergence: std.fs.path.basename would say "Foo".
    try testing.expectEqualStrings("", juliaBasename("Foo/"));
    try testing.expectError(Error.InvalidPackageName, packageName(juliaBasename("Foo/")));
}

test "isIdentifier matches Base.isidentifier on ASCII" {
    try testing.expect(try isIdentifier("Foo"));
    try testing.expect(try isIdentifier("_x9!"));
    try testing.expect(!try isIdentifier(""));
    try testing.expect(!try isIdentifier("1Foo"));
    try testing.expect(!try isIdentifier("Foo-Bar"));
    try testing.expect(!try isIdentifier("Foo Bar"));
    try testing.expect(!try isIdentifier("!x"));
    // The two reserved words `Base.isidentifier` names explicitly.
    try testing.expect(!try isIdentifier("true"));
    try testing.expect(!try isIdentifier("false"));
    try testing.expectError(Error.NonAsciiPackageName, isIdentifier("Ωmega"));
}

test "uuid4 sets the version and variant nibbles where the TEXT shows them" {
    const u = uuid4(@splat(0xff));
    try testing.expectEqual(@as(u8, 0x4f), u.bytes[6]);
    try testing.expectEqual(@as(u8, 0xbf), u.bytes[8]);
    // And from all-zero entropy, the two bits that must still be set.
    const z = uuid4(@splat(0x00));
    try testing.expectEqual(@as(u8, 0x40), z.bytes[6]);
    try testing.expectEqual(@as(u8, 0x80), z.bytes[8]);
}

test "authors: the trailing space, the empty-env win, and independent fallback" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    // Nothing at all -> "Unknown ", space included.
    try testing.expectEqualStrings("Unknown ", try authors(g, .{ .environ = &env }));

    // git name, no git email, no env -> the trailing space that looks like a
    // typo and is not.
    try testing.expectEqualStrings("Ada ", try authors(g, .{
        .git_name = "Ada",
        .git_email = "",
        .environ = &env,
    }));

    // Name from git, email from ENV: the two chains run independently.
    try env.put("EMAIL", "ada@example.com");
    try testing.expectEqualStrings("Ada <ada@example.com>", try authors(g, .{
        .git_name = "Ada",
        .environ = &env,
    }));

    // An env var set to the EMPTY STRING wins, and "Unknown" never fires.
    try env.put("USER", "");
    try testing.expectEqualStrings(" <ada@example.com>", try authors(g, .{ .environ = &env }));

    // Order within a chain: GIT_AUTHOR_NAME beats USER.
    try env.put("GIT_AUTHOR_NAME", "Grace");
    try testing.expectEqualStrings("Grace <ada@example.com>", try authors(g, .{ .environ = &env }));
}

test "generate writes exactly two files, in project key order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    const target = try std.fs.path.join(g, &.{ base, "Foo.jl" });
    const rep = try run(g, testing.io, .{
        .path = target,
        .identity = .{ .given = .{ .git_name = "Ada", .git_email = "ada@example.com", .environ = &env } },
        .entropy = @splat(0xab),
    });
    try testing.expectEqualStrings("Foo", rep.pkg);

    // The directory is `Foo.jl`, the package is `Foo`, and the entry point is
    // `src/Foo.jl` — three different strings that a naive port collapses.
    const proj = try td.dir.readFileAlloc(testing.io, "Foo.jl/Project.toml", g, .limited(4096));
    try testing.expectEqualStrings(
        \\name = "Foo"
        \\uuid = "abababab-abab-4bab-abab-abababababab"
        \\version = "0.1.0"
        \\authors = ["Ada <ada@example.com>"]
        \\
    , proj);

    const entry = try td.dir.readFileAlloc(testing.io, "Foo.jl/src/Foo.jl", g, .limited(4096));
    try testing.expectEqualStrings(
        \\module Foo
        \\
        \\greet() = print("Hello World!")
        \\
        \\end # module Foo
        \\
    , entry);

    // Exactly two files and one directory: no .gitignore, no test/, no LICENSE.
    var names: std.ArrayList([]const u8) = .empty;
    var dir = try td.dir.openDir(testing.io, "Foo.jl", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| try names.append(g, try g.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("Project.toml", names.items[0]);
    try testing.expectEqualStrings("src", names.items[1]);
}

test "generate: refuses an existing directory, and the NAME first" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();

    var td = testing.tmpDir(.{});
    defer td.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try td.dir.realPath(testing.io, &path_buf)];

    try td.dir.createDirPath(testing.io, "Taken");
    try td.dir.createDirPath(testing.io, "Not-An-Identifier");

    try testing.expectError(Error.AlreadyExists, run(g, testing.io, .{
        .path = try std.fs.path.join(g, &.{ base, "Taken" }),
        .entropy = @splat(0),
    }));
    // Name before directory: this one exists AND is invalid, and Pkg reports
    // the name (`generate.jl:6` precedes `:7`).
    try testing.expectError(Error.InvalidPackageName, run(g, testing.io, .{
        .path = try std.fs.path.join(g, &.{ base, "Not-An-Identifier" }),
        .entropy = @splat(0),
    }));
}
