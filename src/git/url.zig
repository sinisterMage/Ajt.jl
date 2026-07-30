//! Git URLs: what shape is this string, and what may be logged about it.
//!
//! No I/O and no allocation beyond a passed-in arena, so the whole of the
//! classification is unit-testable and differentially testable against Pkg.
//! That matters more than it looks: `isUrl` is what decides whether
//! `ajt dev <arg>` treats its argument as a path on disk or as something to
//! clone, and Pkg's own answer is a regex with quirks that a "sensible"
//! reimplementation gets wrong in both directions.
//!
//! ## Three questions, deliberately kept apart
//!
//!  * `isUrl` — **"is this a URL?" exactly as Pkg answers it**
//!    (`utils.jl:27-28`). Used wherever Pkg uses `isurl`, and bug-compatible on
//!    purpose; see its own doc comment.
//!  * `classify` — **"which transport?"**, which Pkg never asks as one question
//!    because LibGit2 answers it. Ajt needs it up front, because an `ssh://`
//!    URL has to be refused with a message rather than handed to a libgit2
//!    that was built without an SSH transport and reports "Unsupported URL
//!    protocol".
//!  * `normalize` — `GitTools.normalize_url` (`GitTools.jl:56-72`).
//!
//! **The order these are asked in is part of the contract.** A caller deciding
//! *path or repository?* must ask `isUrl`; only once that says yes may it ask
//! `classify` which transport to use. Asking `classify` first diverges from Pkg
//! on real input: `URL_regex` is **case-sensitive**, so `HTTPS://host/r.git` is
//! a *path* to Pkg (`isurl` false) while `classify` — and `git clone`, and RFC
//! 3986 §3.1 — call it https. Reversing the order would make `ajt dev` try to
//! clone a string Pkg would have developed from disk. The differential gate
//! `tools/diff_harness/git_url.sh` pins exactly this case.
//!
//! ## Credentials never appear in output
//!
//! `withCredentials` is how a token reaches libgit2 (through the URL, because
//! binding `git_remote_callbacks` is a far larger ABI surface than binding
//! `git_remote_create_anonymous`). That makes it this module's job to ensure
//! the token cannot come back out: **every path that renders a URL for a human
//! or a log goes through `redact`**, and `Attempt`-style records store the
//! redacted form, not the real one.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which transport a URL names. `local_path` is the "not a URL at all" case.
pub const Kind = enum {
    https,
    http,
    /// `git://` — the anonymous, unauthenticated, unencrypted git protocol.
    git_proto,
    /// `ssh://`, `git+ssh://`, or the scp-like `git@host:path`.
    ssh,
    file,
    /// git's remote-HELPER syntax, `<transport>::<address>`
    /// (gitremote-helpers(7)). `git` runs `git-remote-<transport>` as a child
    /// process, and the `ext::` helper's address IS a shell command line — so
    /// this is a code-execution primitive wearing a URL's clothes.
    ///
    /// It is a `Kind` of its own rather than folded into `local_path` because
    /// the two must be answered differently and the difference is not
    /// cosmetic; see `supported`.
    helper,
    local_path,

    /// Can `src/git/`'s backends fetch this?
    ///
    /// Two nos, for two different reasons:
    ///
    ///   * `.ssh` — the libgit2 build deliberately omits the SSH transport.
    ///     A configuration limit, and `ssh_unsupported_message` says how to
    ///     work around it.
    ///   * `.helper` — **refused on purpose, and it is a refusal Pkg's default
    ///     does not have to make.** libgit2 implements no remote helpers at
    ///     all, so `Pkg.add(url = "ext::…")` simply fails there; only Pkg's
    ///     `JULIA_PKG_USE_CLI_GIT=1` path reaches a `git` that can run one.
    ///     Ajt's CLI backend is the DEFAULT, so without this check Ajt would be
    ///     strictly more dangerous than the tool it replaces: `[sources]` in a
    ///     `Project.toml` is data that arrives with a repository somebody
    ///     merely CLONED, and `ajt resolve` would hand it to `git clone` before
    ///     the solve. Modern git blocks `ext::` itself (`protocol.ext.allow`
    ///     defaults to `never` since 2.12) — measured: "fatal: transport 'ext'
    ///     not allowed" on git 2.55 — but a user or system `gitconfig` can turn
    ///     it back on, and `GIT_CONFIG_NOSYSTEM` is deliberately NOT set by
    ///     `cli.zig`. Verified by measurement, both ways: with
    ///     `protocol.ext.allow=always` the helper's command DOES run, and `--`
    ///     before the operand does not stop it, because the helper is the
    ///     operand.
    pub fn supported(self: Kind) bool {
        return self != .ssh and self != .helper;
    }
};

/// `classify` is prefix matching on the scheme, plus the scp-like special
/// case. Schemes are ASCII-case-insensitive (RFC 3986 §3.1); the rest of the
/// URL is not touched.
///
/// The case-insensitivity is where this and `isUrl` part company — Pkg's regex
/// is case-sensitive, so `HTTPS://…` is `.https` here and not a URL there. See
/// the module header: ask `isUrl` first.
pub fn classify(url: []const u8) Kind {
    if (hasSchemePrefix(url, "https://")) return .https;
    if (hasSchemePrefix(url, "http://")) return .http;
    if (hasSchemePrefix(url, "git://")) return .git_proto;
    if (hasSchemePrefix(url, "file://")) return .file;
    // `git+ssh://` and `ssh+git://` are both in libgit2's transport table
    // (`transport.c`), all three behind `#ifdef GIT_SSH`.
    if (hasSchemePrefix(url, "ssh://")) return .ssh;
    if (hasSchemePrefix(url, "git+ssh://")) return .ssh;
    if (hasSchemePrefix(url, "ssh+git://")) return .ssh;
    // BEFORE `isScpLike`, and the order is load-bearing in both directions.
    // `ext::sh -c '…'` has a `:` before any `/` and no `://`, so `isScpLike`
    // calls it ssh — refused, but for the wrong reason and with a message
    // telling the user to set `JULIA_PKG_USE_CLI_GIT`, which is precisely the
    // configuration that would make it run. And `ext::sh -c '…' https://x`
    // DOES contain `://`, so `isScpLike` says no and the string used to fall
    // through to `.local_path`, i.e. straight into `git clone`.
    if (isTransportHelper(url)) return .helper;
    if (isScpLike(url)) return .ssh;
    return .local_path;
}

/// git's `<transport>::<address>` remote-helper syntax
/// (gitremote-helpers(7), "Invocation").
///
/// The transport name is a scheme-shaped word — git looks up
/// `git-remote-<transport>` on `PATH`, so it cannot contain a separator — and
/// `::` is what distinguishes it from every URL scheme, all of which are
/// followed by `//` or by a path character rather than a second colon.
///
/// Deliberately does NOT try to enumerate the dangerous helpers (`ext`, `fd`).
/// Any `git-remote-*` on `PATH` is reachable this way, including one a user
/// installed, so the shape is the thing to refuse.
fn isTransportHelper(url: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (at == 0) return false;
    if (at + 1 >= url.len or url[at + 1] != ':') return false;
    for (url[0..at]) |c| {
        // RFC 3986 §3.1's scheme class, which is also what a helper name can
        // be: a path separator here means this is a path with a `::` in it.
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

fn hasSchemePrefix(url: []const u8, prefix: []const u8) bool {
    if (url.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(url[0..prefix.len], prefix);
}

/// The scp-like syntax `[user@]host:path` that `git clone` accepts and that is
/// what people actually paste: `git@github.com:JuliaLang/Example.jl.git`.
///
/// The rule git itself uses (`connect.c:parse_connect_url`): there is a `:`
/// before the first `/`, and the URL has no `://`. Requiring a `user@` would
/// miss `github.com:o/r.git`, which git also treats as ssh — and a bare
/// Windows drive letter (`C:\src\pkg`) has to stay a path, which the
/// single-character-host exclusion below handles the way git's
/// `is_local_path`-adjacent checks do.
fn isScpLike(url: []const u8) bool {
    if (std.mem.indexOf(u8, url, "://") != null) return false;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    // A `:` after a `/` is part of a path, not a host separator.
    if (std.mem.indexOfScalar(u8, url, '/')) |slash| {
        if (slash < colon) return false;
    }
    const host = url[0..colon];
    if (host.len == 0) return false;
    // `C:\src` and `C:/src` — a one-character host is a drive letter.
    if (host.len == 1 and std.ascii.isAlphabetic(host[0])) return false;
    // Something has to follow the colon, or this is not a location.
    return colon + 1 < url.len;
}

// ---------------------------------------------------------------------------
// isUrl — the Pkg-parity predicate
// ---------------------------------------------------------------------------

/// `Pkg.isurl` (`utils.jl:27-28`):
///
/// ```julia
/// const URL_regex = r"((file|git|ssh|http(s)?)|([\w\-\.]+@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)?(/)?"x
/// isurl(r::String) = occursin(URL_regex, r)
/// ```
///
/// **Ported bug-for-bug, and the bugs are load-bearing.** `occursin` is a
/// SEARCH, not a match: the pattern is unanchored at both ends, so it answers
/// "does a URL-shaped thing appear anywhere in here?". Two consequences that a
/// tidier predicate would get wrong, in opposite directions:
///
///  * `/tmp/digit:x` is a **URL** to Pkg. `git` appears inside `digit`, a `:`
///    follows it, and a path character follows that. Refusing to reproduce
///    this would make `ajt dev /tmp/digit:x` clone where Pkg develops.
///  * `github.com:owner/repo.git` is **not** a URL to Pkg, even though `git`
///    would clone it over ssh. `github` starts with `git` but the next
///    character is `h`, not `:`, and there is no `user@`. So Pkg treats it as
///    a relative path. `classify` disagrees on purpose — the two functions
///    answer different questions and both answers are needed.
///
/// The trailing `(\.git)?(/)?` groups are both optional and follow a greedy
/// `+`, so they can never fail a match and are not modelled.
pub fn isUrl(s: []const u8) bool {
    // Alternative 1: a literal scheme word, then `:`.
    const schemes = [_][]const u8{ "file", "git", "ssh", "https", "http" };
    for (0..s.len) |i| {
        for (schemes) |scheme| {
            if (s.len - i < scheme.len) continue;
            if (!std.mem.eql(u8, s[i..][0..scheme.len], scheme)) continue;
            if (tailMatches(s, i + scheme.len)) return true;
        }
    }
    // Alternative 2: `[\w\-\.]+@[\w\-\.]+`, then `:`.
    for (0..s.len) |at| {
        if (s[at] != '@') continue;
        // Both sides need at least one character of the class. They are
        // greedy runs, but since the class excludes `@` and `:`, the maximal
        // run is the only run, so no backtracking is needed here.
        var lo = at;
        while (lo > 0 and isWordDashDot(s[lo - 1])) lo -= 1;
        if (lo == at) continue;
        var hi = at + 1;
        while (hi < s.len and isWordDashDot(s[hi])) hi += 1;
        if (hi == at + 1) continue;
        if (tailMatches(s, hi)) return true;
    }
    return false;
}

/// `(:(//)?)([\w\.@\:/\-~]+)` — a colon, optionally `//`, then at least one
/// character of the path class.
///
/// The `(//)?` is a subtlety: `/` is *also* in the path class, so the regex
/// engine can satisfy this either way and the group only matters for capture.
/// One path character after the colon is therefore the whole requirement.
fn tailMatches(s: []const u8, at: usize) bool {
    if (at >= s.len or s[at] != ':') return false;
    return at + 1 < s.len and isPathClass(s[at + 1]);
}

/// `\w` in Julia's PCRE without `(*UCP)` is ASCII `[A-Za-z0-9_]`.
fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWordDashDot(c: u8) bool {
    return isWord(c) or c == '-' or c == '.';
}

/// `[\w\.@\:/\-~]`.
fn isPathClass(c: u8) bool {
    return isWord(c) or switch (c) {
        '.', '@', ':', '/', '-', '~' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// normalize
// ---------------------------------------------------------------------------

/// `GitTools.normalize_url` (`GitTools.jl:56-72`).
///
/// In a stock session this is exactly `rstrip(url, '/')` — *"LibGit2 is fussy
/// about trailing slash"* — because the rewrite it can also do is driven by
/// `GIT_PROTOCOLS`/`GIT_USERS`, two dictionaries that are empty until somebody
/// calls `setprotocol!`. Ajt has no `setprotocol!` (it is one of the verbs the
/// Julia wrapper still delegates), so the rewrite branch has nothing to key on
/// and is not implemented. **This is the seam**: when `setprotocol!` lands, the
/// `GIT_REGEX` host/path split goes here and nowhere else.
///
/// Note what this deliberately does NOT do: it does not drop a trailing
/// `.git`, lowercase the host, or otherwise canonicalise. `clones/` is keyed
/// on `hash(url)` of the *original* string (`depot.zig:cloneUrlDir`), so any
/// normalisation beyond Pkg's would simply stop finding Pkg's clone.
pub fn normalize(url: []const u8) []const u8 {
    return std.mem.trimEnd(u8, url, "/");
}

// ---------------------------------------------------------------------------
// credentials in, credentials out
// ---------------------------------------------------------------------------

pub const Credentials = struct {
    user: []const u8,
    password: []const u8,
};

/// Split a URL into `scheme://`, `userinfo@` (may be empty), and the rest.
/// Returns null when there is no `://` — a scp-like or local path, neither of
/// which carries userinfo we may rewrite.
const Split = struct { scheme: []const u8, userinfo: []const u8, rest: []const u8 };

fn split(url: []const u8) ?Split {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const after = sep + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, after, "/?#") orelse url.len;
    // The LAST `@` in the authority: a password may legitimately contain one,
    // and RFC 3986 §3.2.1 puts the delimiter at the end of the userinfo.
    const at = std.mem.lastIndexOfScalar(u8, url[after..authority_end], '@');
    return .{
        .scheme = url[0..after],
        .userinfo = if (at) |i| url[after..][0..i] else "",
        .rest = if (at) |i| url[after + i + 1 ..] else url[after..],
    };
}

/// The host a URL names, lower-case-insensitively as written, with any
/// userinfo and any `:port` removed. Empty when the string is not a `scheme://`
/// URL at all.
///
/// Exists for one caller: `auth.decide` matches a credential against a host,
/// and sending a GitHub token to whatever host happens to be in the URL is the
/// mistake it is built to prevent. So the host it is given had better be the
/// host the request goes to — which means the *last* `@` in the authority
/// delimits userinfo (RFC 3986 §3.2.1, and `split` above already does this),
/// not the first. `https://github.com@evil.invalid/x` has host
/// `evil.invalid`, and reading it as `github.com` would hand the token over.
///
/// An IPv6 literal keeps its brackets, because that is the form
/// `.netrc` and every log would show, and stripping them would make
/// `[::1]` and `::1` two different hosts to the caller.
pub fn hostOf(u: []const u8) []const u8 {
    const s = split(u) orelse return "";
    const end = std.mem.indexOfAny(u8, s.rest, "/?#") orelse s.rest.len;
    const authority = s.rest[0..end];
    if (authority.len == 0) return "";

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

/// `https://host/path` + `{user, password}` → `https://user:password@host/path`.
///
/// Any userinfo already present is REPLACED, not appended to — a URL that
/// already carries a credential came from somewhere, and silently keeping it
/// while adding another is how the wrong token gets sent.
///
/// Returns the URL unchanged (duped into `arena`) when it has no `://`, since
/// there is nowhere to put userinfo in a scp-like or local path.
pub fn withCredentials(arena: Allocator, url: []const u8, creds: Credentials) Allocator.Error![]u8 {
    const s = split(url) orelse return arena.dupe(u8, url);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, s.scheme);
    try percentEncodeUserinfo(arena, &out, creds.user);
    try out.append(arena, ':');
    try percentEncodeUserinfo(arena, &out, creds.password);
    try out.append(arena, '@');
    try out.appendSlice(arena, s.rest);
    return out.items;
}

/// The unreserved set (RFC 3986 §2.3) plus nothing else. Sub-delims are legal
/// in userinfo but `:` is the user/password delimiter and a token containing
/// one would silently split, so the conservative set is the correct one here.
fn percentEncodeUserinfo(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
}

/// The form a URL may be printed, logged or recorded in: userinfo replaced
/// with a fixed placeholder.
///
/// A placeholder rather than deletion, because *"the credential was stripped"*
/// and *"there was no credential"* are different facts and a reader of a log
/// needs to be able to tell them apart while debugging a 401.
pub fn redact(arena: Allocator, url: []const u8) Allocator.Error![]u8 {
    const s = split(url) orelse return arena.dupe(u8, url);
    if (s.userinfo.len == 0) return arena.dupe(u8, url);
    return std.mem.concat(arena, u8, &.{ s.scheme, "***@", s.rest });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "classify routes each scheme, and scp-like is ssh" {
    try testing.expectEqual(Kind.https, classify("https://github.com/o/r.git"));
    try testing.expectEqual(Kind.https, classify("HTTPS://github.com/o/r.git"));
    try testing.expectEqual(Kind.http, classify("http://example.invalid/r"));
    try testing.expectEqual(Kind.git_proto, classify("git://example.invalid/r"));
    try testing.expectEqual(Kind.file, classify("file:///srv/r.git"));

    try testing.expectEqual(Kind.ssh, classify("ssh://git@github.com/o/r.git"));
    try testing.expectEqual(Kind.ssh, classify("git+ssh://git@github.com/o/r.git"));
    try testing.expectEqual(Kind.ssh, classify("ssh+git://git@github.com/o/r.git"));
    // The form people actually paste out of GitHub's UI.
    try testing.expectEqual(Kind.ssh, classify("git@github.com:JuliaLang/Example.jl.git"));
    // And the userless scp form, which `git` also treats as ssh.
    try testing.expectEqual(Kind.ssh, classify("github.com:JuliaLang/Example.jl.git"));

    try testing.expectEqual(Kind.local_path, classify("/home/u/pkg"));
    try testing.expectEqual(Kind.local_path, classify("../pkg"));
    try testing.expectEqual(Kind.local_path, classify("pkg"));
    // A `:` inside a path component is not a host separator.
    try testing.expectEqual(Kind.local_path, classify("/home/u/we:rd/pkg"));
    // A Windows drive letter stays a path.
    try testing.expectEqual(Kind.local_path, classify("C:\\src\\pkg"));
    try testing.expectEqual(Kind.local_path, classify("C:/src/pkg"));

    try testing.expect(!Kind.ssh.supported());
    try testing.expect(Kind.https.supported());
    try testing.expect(Kind.local_path.supported());
}

test "a remote-helper transport is refused, however it is dressed up" {
    // `<transport>::<address>` runs `git-remote-<transport>` as a child, and
    // `ext::`'s address is a shell command line. `[sources]` is data that
    // arrives with somebody else's repository and `ajt resolve` hands it to
    // `git clone` before the solve, so this is untrusted input reaching a
    // process spawn.
    try testing.expectEqual(Kind.helper, classify("ext::sh -c 'id > /tmp/pwned'"));
    try testing.expectEqual(Kind.helper, classify("fd::17/foo"));
    // THE ONE THAT MATTERS. With a `://` anywhere in the string `isScpLike`
    // says no, so before `isTransportHelper` existed this fell through to
    // `.local_path` — supported — and went straight to `git clone`. It also
    // satisfies `Pkg.isurl` (the regex is an unanchored SEARCH and finds the
    // embedded `https:`), so nothing upstream rejected it either.
    try testing.expectEqual(Kind.helper, classify("ext::sh -c 'id' https://example.invalid/r"));
    try testing.expect(isUrl("ext::sh -c 'id' https://example.invalid/r"));
    try testing.expect(!Kind.helper.supported());

    // ...and the shapes that merely LOOK similar must not be caught, or a
    // legitimate clone stops working:
    //   a real scheme is `://`, never `::`
    try testing.expectEqual(Kind.https, classify("https://github.com/o/r.git"));
    //   a path may contain `::` — but then the part before it has a separator
    //   in it, or is not scheme-shaped
    try testing.expectEqual(Kind.local_path, classify("/home/u/we::rd/pkg"));
    try testing.expectEqual(Kind.local_path, classify("./a::b"));
    //   an scp-like remote has ONE colon
    try testing.expectEqual(Kind.ssh, classify("git@github.com:o/r.git"));
    //   and a leading `::` names no transport at all
    try testing.expectEqual(Kind.local_path, classify("::nope"));
}

test "classify and isUrl disagree on an upper-case scheme, and must" {
    // RFC 3986 §3.1 makes schemes case-insensitive and `git clone` agrees, but
    // `Pkg.URL_regex` is a case-SENSITIVE literal alternation, so Pkg reads
    // this as a relative path. Both answers are right for their own question;
    // what would be wrong is a caller asking `classify` when it means `isUrl`.
    const upper = "HTTPS://github.com/o/r.git";
    try testing.expectEqual(Kind.https, classify(upper));
    try testing.expect(!isUrl(upper));

    // Lower case: the two agree, which is the case that covers real input.
    const lower = "https://github.com/o/r.git";
    try testing.expectEqual(Kind.https, classify(lower));
    try testing.expect(isUrl(lower));
}

test "isUrl reproduces Pkg's regex, quirks included" {
    // Straightforward URLs.
    for ([_][]const u8{
        "https://github.com/JuliaLang/Example.jl.git",
        "http://example.invalid/r",
        "git://example.invalid/r",
        "ssh://git@github.com/o/r.git",
        "file:///srv/r.git",
        "git@github.com:JuliaLang/Example.jl.git",
        "user.name-1@host.example:path",
    }) |u| {
        try testing.expect(isUrl(u));
    }

    // Straightforward paths.
    for ([_][]const u8{
        "/home/u/pkg",
        "../pkg",
        "pkg",
        "",
        "/tmp/a b/c",
        // No `user@`, and `github` is not `git` followed by `:`.
        "github.com:JuliaLang/Example.jl.git",
    }) |p| {
        try testing.expect(!isUrl(p));
    }

    // The quirk that matters: `occursin` is unanchored, so a scheme word
    // buried in a path counts. Reproduced deliberately.
    try testing.expect(isUrl("/tmp/digit:x"));
    try testing.expect(isUrl("/tmp/ssh:x"));
    // ...but only when a `:` and a path character really follow it.
    try testing.expect(!isUrl("/tmp/digit"));
    try testing.expect(!isUrl("/tmp/digit:"));
}

test "normalize strips trailing slashes and nothing else" {
    try testing.expectEqualStrings(
        "https://github.com/o/r.git",
        normalize("https://github.com/o/r.git/"),
    );
    try testing.expectEqualStrings(
        "https://github.com/o/r.git",
        normalize("https://github.com/o/r.git///"),
    );
    // `.git` is NOT dropped: `…/r` and `…/r.git` are two different clones to
    // Pkg, because `clones/` is keyed on hash(url) of the original string.
    try testing.expectEqualStrings(
        "https://github.com/o/r",
        normalize("https://github.com/o/r"),
    );
    try testing.expectEqualStrings("/home/u/pkg", normalize("/home/u/pkg/"));
}

test "credentials go in through the URL and never come back out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = "https://github.com/o/r.git";
    const with = try withCredentials(arena, url, .{ .user = "x-access-token", .password = "ghp_secret" });
    try testing.expectEqualStrings("https://x-access-token:ghp_secret@github.com/o/r.git", with);
    try testing.expectEqualStrings("https://***@github.com/o/r.git", try redact(arena, with));

    // A password with delimiters must not be able to restructure the URL.
    const tricky = try withCredentials(arena, url, .{ .user = "u", .password = "p@ss:w/rd" });
    try testing.expectEqualStrings("https://u:p%40ss%3Aw%2Frd@github.com/o/r.git", tricky);
    try testing.expectEqualStrings("https://***@github.com/o/r.git", try redact(arena, tricky));

    // Existing userinfo is replaced, not appended to.
    const pre = "https://olduser:oldpass@github.com/o/r.git";
    try testing.expectEqualStrings(
        "https://n:s@github.com/o/r.git",
        try withCredentials(arena, pre, .{ .user = "n", .password = "s" }),
    );
    try testing.expectEqualStrings("https://***@github.com/o/r.git", try redact(arena, pre));

    // Nothing to redact is not an error, and no `://` means nowhere to put a
    // credential — the URL comes back unchanged rather than mangled.
    try testing.expectEqualStrings(url, try redact(arena, url));
    const scp = "git@github.com:o/r.git";
    try testing.expectEqualStrings(scp, try withCredentials(arena, scp, .{ .user = "u", .password = "p" }));
    try testing.expectEqualStrings(scp, try redact(arena, scp));
}

test "redaction survives an @ inside the password" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The delimiter is the LAST `@` in the authority (RFC 3986 3.2.1). Taking
    // the first would leave `ss@host` as the host and leak the rest.
    const url = "https://u:p@ss@github.com/o/r.git";
    try testing.expectEqualStrings("https://***@github.com/o/r.git", try redact(arena, url));
    // And a later `@` in the PATH is not part of the authority at all.
    const path_at = "https://github.com/o/r.git?x=a@b";
    try testing.expectEqualStrings(path_at, try redact(arena, path_at));
}

test "hostOf names the host a credential would actually be sent to" {
    // `auth.decide` matches a GitHub token against this string, so a wrong
    // answer here is a token handed to the wrong server. The interesting cases
    // are all attempts to make a URL *look* like github.com to a careless
    // parser.
    try testing.expectEqualStrings("github.com", hostOf("https://github.com/o/r.git"));
    try testing.expectEqualStrings("github.com", hostOf("https://github.com"));
    try testing.expectEqualStrings("github.com", hostOf("https://github.com:443/o/r"));
    try testing.expectEqualStrings("github.com", hostOf("https://user:pw@github.com/o/r"));
    // A password containing `@`: the LAST one in the authority delimits
    // userinfo (RFC 3986 3.2.1).
    try testing.expectEqualStrings("github.com", hostOf("https://u:p@ss@github.com/o/r"));

    // THE attack: a host that merely begins with a trusted name.
    try testing.expectEqualStrings("evil.invalid", hostOf("https://github.com@evil.invalid/o/r"));
    try testing.expectEqualStrings("evil.invalid", hostOf("https://evil.invalid/@github.com/r"));
    try testing.expectEqualStrings("evil.invalid", hostOf("https://evil.invalid?x=@github.com"));
    try testing.expectEqualStrings("evil.invalid", hostOf("https://evil.invalid#@github.com"));
    // `github.com.evil.invalid` is a different host, and `auth.decide` compares
    // whole strings, so this only has to not be truncated to `github.com`.
    try testing.expectEqualStrings(
        "github.com.evil.invalid",
        hostOf("https://github.com.evil.invalid/o/r"),
    );

    // An IPv6 literal keeps its brackets: `[::1]` and `::1` must not become two
    // spellings of one host to the caller.
    try testing.expectEqualStrings("[::1]", hostOf("https://[::1]:8443/o/r"));
    try testing.expectEqualStrings("[fe80::1]", hostOf("https://u@[fe80::1]/o/r"));

    // Not a `scheme://` URL at all -- empty, which `auth.decide` matches
    // against nothing.
    try testing.expectEqualStrings("", hostOf("/srv/repos/r.git"));
    try testing.expectEqualStrings("", hostOf("git@github.com:o/r.git"));
    try testing.expectEqualStrings("", hostOf(""));
    try testing.expectEqualStrings("", hostOf("https://"));
}
