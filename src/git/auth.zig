//! Credentials for a git fetch over HTTPS.
//!
//! Only the *decision* lives here, like `net/auth.zig`: `decide` is handed the
//! environment values and the `.netrc` **contents**, never a path, so the whole
//! table is reachable from a unit test with no filesystem and no HOME.
//!
//! ## Why credentials travel in the URL
//!
//! libgit2's credential hook lives on `git_remote_callbacks`, which is reached
//! through `git_fetch_options` — between them the two largest and most
//! version-fragile structs in the API, and `src/git/c.zig` binds neither
//! (see its header). `git_remote_fetch(remote, refspecs, NULL, NULL)` takes a
//! documented NULL-options path instead, and libgit2's own `git_net_url`
//! parser feeds userinfo straight into the HTTP auth layer. So the credential
//! goes in through `url.withCredentials` and comes back out through
//! `url.redact`, and neither struct has to be described in Zig.
//!
//! The cost of that choice is one rule this module cannot enforce alone:
//! **the authenticated URL must never be written to disk.** It is handed to
//! `git_remote_create_anonymous`, which keeps the remote in memory and never
//! touches `.git/config`. Anything that persists or logs a URL takes the
//! redacted form.
//!
//! ## What Pkg does, and where this differs
//!
//! Pkg hands LibGit2 a `CachedCredentials` and lets libgit2's credential
//! callback run the full ladder: the git credential helper, `~/.git-credentials`,
//! ssh-agent, and an interactive prompt (`LibGit2/src/callbacks.jl`). Ajt does
//! **two** of those — an explicit token and `.netrc` — and no prompting, because
//! a package manager that can block on a TTY inside `instantiate` is a package
//! manager that hangs a CI job. Everything else is out of scope and named as
//! such in `Ajt.jl`'s `DIFFERENCES`, not silently absent.
//!
//! Nothing here ever *requires* a credential: a public repository fetches with
//! `.none`, which is the overwhelmingly common case and the only one the engine
//! cutover needs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const url_mod = @import("url.zig");

pub const Credentials = url_mod.Credentials;

/// Where a credential came from. Reported so a 401 says which of four things
/// was tried, rather than "authentication failed".
pub const Source = enum {
    none,
    /// `GH_TOKEN`. Checked before `GITHUB_TOKEN`, matching the `gh` CLI's own
    /// precedence — a machine that sets both is a machine where somebody has
    /// deliberately overridden Actions' automatic `GITHUB_TOKEN`.
    gh_token,
    /// `GITHUB_TOKEN`, which GitHub Actions injects.
    github_token,
    /// A `machine <host>` or `default` entry in `.netrc`.
    netrc,

    pub fn text(self: Source) []const u8 {
        return switch (self) {
            .none => "none",
            .gh_token => "GH_TOKEN",
            .github_token => "GITHUB_TOKEN",
            .netrc => ".netrc",
        };
    }
};

pub const Decision = struct {
    creds: ?Credentials = null,
    source: Source = .none,
};

pub const Options = struct {
    /// The host to authenticate to, already lower-cased by the caller if it
    /// cares; matching here is case-insensitive either way.
    host: []const u8,
    /// The URL's scheme. A credential is only ever attached to `https`:
    /// sending a bearer token over plaintext `http://` or the unauthenticated
    /// `git://` protocol would be handing it to anyone on the path, and `git`
    /// itself refuses `.netrc` over http for the same reason.
    kind: url_mod.Kind,
    gh_token: ?[]const u8 = null,
    github_token: ?[]const u8 = null,
    /// The CONTENTS of `~/.netrc` (or `~/.netrc.gpg`-decrypted, or
    /// `%HOME%/_netrc`), not a path. Reading it is the caller's job.
    netrc: ?[]const u8 = null,
};

/// The token env vars only apply to GitHub. Sending a GitHub token to an
/// arbitrary host because `GITHUB_TOKEN` happened to be exported — which it
/// always is inside Actions — would leak it to whatever that host is.
fn isGitHub(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "github.com") or
        std.ascii.eqlIgnoreCase(host, "www.github.com");
}

/// `x-access-token` is the username GitHub documents for token-over-HTTPS. The
/// username is not checked by GitHub, but using the documented one keeps the
/// request indistinguishable from `gh`'s and `actions/checkout`'s.
pub const github_token_user = "x-access-token";

pub fn decide(opts: Options) Decision {
    // Only https carries a credential. Everything else falls through to
    // anonymous, including `file://` and a local path, which need none.
    if (opts.kind != .https) return .{};

    if (isGitHub(opts.host)) {
        if (nonEmpty(opts.gh_token)) |t| {
            return .{ .creds = .{ .user = github_token_user, .password = t }, .source = .gh_token };
        }
        if (nonEmpty(opts.github_token)) |t| {
            return .{ .creds = .{ .user = github_token_user, .password = t }, .source = .github_token };
        }
    }

    if (opts.netrc) |src| {
        if (lookupNetrc(src, opts.host)) |c| return .{ .creds = c, .source = .netrc };
    }
    return .{};
}

/// An env var set to the empty string is "unset" here, not "authenticate with
/// an empty password". `GITHUB_TOKEN=` appears in CI configs that mean to
/// disable it, and an empty Basic credential is a guaranteed 401 that reads as
/// a server problem.
fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ---------------------------------------------------------------------------
// .netrc
// ---------------------------------------------------------------------------

/// The `.netrc` entry for `host`, or the `default` entry if there is one and
/// no `machine` matched.
///
/// The format is a flat, whitespace-separated token stream — newlines are not
/// significant — with these tokens (curl's `netrc.c`, and `ftp(1)`, agree):
///
///   * `machine <name>`  starts an entry, ending the previous one
///   * `default`         starts a catch-all entry that matches any host
///   * `login <user>`, `password <pass>`, `account <acct>`  fill the entry
///   * `macdef <name>`   a macro definition, terminated by a BLANK LINE
///
/// `macdef` is the one place newlines matter, and skipping it wrong is how a
/// naive tokeniser leaks: a macro body containing the word `password` would
/// otherwise be read as one. It is handled explicitly below.
///
/// A `default` entry must come last to be meaningful and is applied only when
/// no `machine` matched, which is what curl does.
pub fn lookupNetrc(src: []const u8, host: []const u8) ?Credentials {
    var it: Tokenizer = .{ .src = src };

    var in_default = false;
    var matching = false;
    var cur: Credentials = .{ .user = "", .password = "" };
    var default_entry: ?Credentials = null;

    const finish = struct {
        fn f(active: bool, is_default: bool, c: Credentials, out_default: *?Credentials) ?Credentials {
            if (c.user.len == 0 and c.password.len == 0) return null;
            if (active) return c;
            if (is_default and out_default.* == null) out_default.* = c;
            return null;
        }
    }.f;

    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "machine")) {
            if (finish(matching, in_default, cur, &default_entry)) |c| return c;
            const name = it.next() orelse break;
            matching = std.ascii.eqlIgnoreCase(name, host);
            in_default = false;
            cur = .{ .user = "", .password = "" };
        } else if (std.mem.eql(u8, tok, "default")) {
            if (finish(matching, in_default, cur, &default_entry)) |c| return c;
            matching = false;
            in_default = true;
            cur = .{ .user = "", .password = "" };
        } else if (std.mem.eql(u8, tok, "login")) {
            cur.user = it.next() orelse break;
        } else if (std.mem.eql(u8, tok, "password")) {
            cur.password = it.next() orelse break;
        } else if (std.mem.eql(u8, tok, "account")) {
            _ = it.next() orelse break;
        } else if (std.mem.eql(u8, tok, "macdef")) {
            _ = it.next() orelse break; // the macro name
            it.skipToBlankLine();
        }
        // Anything else is an unknown token; skip it rather than abandoning
        // the file, matching curl's tolerance.
    }
    if (finish(matching, in_default, cur, &default_entry)) |c| return c;
    return default_entry;
}

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        while (self.pos < self.src.len and !isSpace(self.src[self.pos])) self.pos += 1;
        return self.src[start..self.pos];
    }

    /// Advance past a `macdef` body, which runs to the first empty line.
    fn skipToBlankLine(self: *Tokenizer) void {
        // Move to the end of the current line first: the body starts after it.
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
        while (self.pos < self.src.len) {
            self.pos += 1; // consume the '\n'
            const line_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            const line = self.src[line_start..self.pos];
            if (std.mem.trim(u8, line, " \t\r").len == 0) return;
        }
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a public https fetch needs no credential" {
    try testing.expectEqual(Source.none, decide(.{ .host = "github.com", .kind = .https }).source);
    try testing.expect(decide(.{ .host = "github.com", .kind = .https }).creds == null);
}

test "GH_TOKEN beats GITHUB_TOKEN, and both are GitHub-only" {
    const both = decide(.{
        .host = "github.com",
        .kind = .https,
        .gh_token = "gh_secret",
        .github_token = "actions_secret",
    });
    try testing.expectEqual(Source.gh_token, both.source);
    try testing.expectEqualStrings("gh_secret", both.creds.?.password);
    try testing.expectEqualStrings(github_token_user, both.creds.?.user);

    const only_actions = decide(.{ .host = "github.com", .kind = .https, .github_token = "actions_secret" });
    try testing.expectEqual(Source.github_token, only_actions.source);

    // A GitHub token must NOT be sent to another host. `GITHUB_TOKEN` is
    // exported for every step of every Actions job, so a host check is the
    // only thing standing between it and an arbitrary git server.
    const elsewhere = decide(.{
        .host = "gitlab.com",
        .kind = .https,
        .gh_token = "gh_secret",
        .github_token = "actions_secret",
    });
    try testing.expectEqual(Source.none, elsewhere.source);
    try testing.expect(elsewhere.creds == null);
}

test "a credential is only ever attached to https" {
    for ([_]url_mod.Kind{ .http, .git_proto, .ssh, .file, .local_path }) |k| {
        const d = decide(.{
            .host = "github.com",
            .kind = k,
            .gh_token = "gh_secret",
            .netrc = "machine github.com login u password p\n",
        });
        try testing.expectEqual(Source.none, d.source);
        try testing.expect(d.creds == null);
    }
}

test "an empty token is unset, not an empty password" {
    const d = decide(.{ .host = "github.com", .kind = .https, .gh_token = "", .github_token = "" });
    try testing.expectEqual(Source.none, d.source);
}

test "netrc: machine entries, case-insensitive host, and default last" {
    const src =
        \\machine example.invalid
        \\  login alice
        \\  password s3cret
        \\
        \\machine other.invalid login bob password hunter2
        \\
        \\default login anon password none
        \\
    ;
    const a = lookupNetrc(src, "example.invalid").?;
    try testing.expectEqualStrings("alice", a.user);
    try testing.expectEqualStrings("s3cret", a.password);

    // Newlines are not significant: a one-line entry parses the same.
    const b = lookupNetrc(src, "other.invalid").?;
    try testing.expectEqualStrings("bob", b.user);
    try testing.expectEqualStrings("hunter2", b.password);

    // Host matching is case-insensitive, as DNS is.
    const c = lookupNetrc(src, "EXAMPLE.INVALID").?;
    try testing.expectEqualStrings("alice", c.user);

    // `default` applies only when no machine matched.
    const d = lookupNetrc(src, "unlisted.invalid").?;
    try testing.expectEqualStrings("anon", d.user);

    try testing.expect(lookupNetrc("", "example.invalid") == null);
    try testing.expect(lookupNetrc("machine example.invalid\n", "example.invalid") == null);
}

test "netrc: a macdef body cannot leak a password" {
    // The one place newlines matter. A macro body running to the next blank
    // line may contain the literal words `password` and `machine`; a
    // tokeniser that does not skip the body reads them as fields and hands
    // back a credential nobody configured.
    const src =
        \\machine example.invalid login alice password real
        \\
        \\macdef upload
        \\put $1
        \\machine attacker.invalid login mallory password stolen
        \\
        \\machine second.invalid login bob password bobpass
        \\
    ;
    const a = lookupNetrc(src, "example.invalid").?;
    try testing.expectEqualStrings("real", a.password);

    // The macro body's `machine attacker.invalid` is text, not an entry.
    try testing.expect(lookupNetrc(src, "attacker.invalid") == null);

    // And parsing resumes correctly after the blank line that ends the macro.
    const b = lookupNetrc(src, "second.invalid").?;
    try testing.expectEqualStrings("bob", b.user);
    try testing.expectEqualStrings("bobpass", b.password);
}

test "netrc: account is consumed, unknown tokens are tolerated" {
    const src = "machine example.invalid login alice account acct password p port 443\n";
    const a = lookupNetrc(src, "example.invalid").?;
    try testing.expectEqualStrings("alice", a.user);
    // `account acct` must consume its value, or `acct` would be read as the
    // next keyword; and `port 443` is unknown but must not abandon the entry.
    try testing.expectEqualStrings("p", a.password);
}

test "the decided credential renders into a URL and back out redacted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = decide(.{ .host = "github.com", .kind = .https, .github_token = "ghp_x" });
    const authed = try url_mod.withCredentials(arena, "https://github.com/o/r.git", d.creds.?);
    try testing.expectEqualStrings("https://x-access-token:ghp_x@github.com/o/r.git", authed);
    // The invariant this module exists to keep: nothing loggable carries it.
    try testing.expectEqualStrings("https://***@github.com/o/r.git", try url_mod.redact(arena, authed));
}
