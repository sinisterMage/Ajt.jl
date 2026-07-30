//! The libgit2 backend.
//!
//! Same six operations as `cli.zig`, without a subprocess. What it buys is not
//! speed — `git` is fast — but the fact that a static `ajt` needs nothing on the
//! host: no `git`, no OpenSSL, no CA-loading shared library. That is the whole
//! reason the libgit2 track exists.
//!
//! ## What is here and what is not
//!
//! `ensureClone`, `fetch`, `resolveRev`, `treeOf`, `hasObject` and
//! `materialise` are implemented. The six repository operations `registry
//! update` needs over a git clone — `cloneWorking`, `isDirty`, `headBranch`,
//! `remoteUrl`, `fastForward`, `rebase` — are not, and report
//! `BackendUnavailable`; `cli.zig` remains the default backend and has them.
//! This one is opt-in through `AJT_GIT_BACKEND=lib`.
//!
//! ## `materialise` is a tree walk, and NOT `git_checkout_tree`
//!
//! The postcondition (`git.zig`'s header) is that `treehash.hashPath` of the
//! destination equals the tree that was asked for. libgit2 has a checkout, and
//! every one of the knobs that would break that postcondition is reachable
//! from it — which is the reason not to use it, not a reason to configure it:
//!
//!   * **Filters.** `checkout.c:1556` and `:2130` load a filter list with
//!     `GIT_FILTER_TO_WORKTREE` for every blob, which is crlf conversion
//!     (`text`/`eol`, `core.autocrlf`, `core.eol`), `ident` expansion, and any
//!     `filter.<driver>.smudge` the user configured. There IS a switch —
//!     `git_checkout_options.disable_filters` (`checkout.h`), and
//!     `checkout.c:2458` notes it "is false by default" — but reaching it
//!     means binding `git_checkout_options`, the struct with two callback
//!     pairs, a `git_strarray`, a `git_tree` and a `git_index` in it, which
//!     `c.zig`'s header refuses for the same reason it refuses
//!     `git_fetch_options`.
//!   * **`core.symlinks`.** `checkout.c:2469` reads it, and when it is false a
//!     symlink is written as a REGULAR FILE containing the target text. Same
//!     bytes, different mode, different tree hash — from the user's config.
//!   * **`core.fileMode`.** `checkout.c:2473`. When false the executable bit
//!     is not honoured, and the executable bit is part of the tree hash.
//!   * **The index.** `checkout_data_init` opens `git_repository_index` and
//!     re-reads it (`checkout.c:2404`, `:2421`), so a checkout out of a bare
//!     cache clone WRITES `$GIT_DIR/index` into a directory several `ajt`
//!     processes may share. `clones/` is a cache of objects and refs; nothing
//!     else belongs in it.
//!
//! What has NO libgit2 equivalent is the other half of `cli.zig`'s problem:
//! `export-ignore` (which silently omits a file) and `export-subst` are
//! consulted only by `git archive`, and libgit2 has no archive — there is no
//! `git2/archive.h` and no `git_archive_*` symbol anywhere in the library. So
//! the `$GIT_DIR/info/attributes` file `cli.zig`'s `ensureClone` writes has no
//! counterpart here and needs none; this backend never reads a `.gitattributes`
//! at all, because nothing on the path from `git_blob_rawcontent` to
//! `writeFile` looks at one.
//!
//! The walk therefore reads `git_tree_entry_filemode` and writes what it says:
//! `0o100644`/`0o100755` blobs through `git_blob_rawcontent` (the UNfiltered
//! accessor — `git_blob_filter` is its filtering counterpart and is not bound),
//! `0o120000` as a symlink whose target is the blob's bytes, `0o040000` as a
//! directory, and `0o160000` — a submodule — as `error.SubmodulePresent`,
//! refused in a first pass so that nothing is written before the refusal, which
//! is exactly the contract `cli.zig` gets from its `ls-tree` pre-check.
//!
//! ## Three shapes worth stating
//!
//! **No `git_clone_options`, no `git_fetch_options`.** They are the two largest
//! and most version-fragile structs in libgit2's API and `c.zig` binds neither.
//! A clone is spelled `git_repository_init(bare)` + `git_remote_create_anonymous`
//! + `git_remote_fetch(remote, refspecs, NULL, NULL)`, the NULL-options path
//! that `remote.c:1378-1381` implements explicitly. That also removes any need
//! for `git_credential`, `git_cert` or `git_remote_callbacks`.
//!
//! **Credentials ride in the URL**, decided by `auth.decide` and injected by
//! `url.withCredentials`. That is the direct consequence of not binding
//! `git_fetch_options`: libgit2's credential hook lives on
//! `git_remote_callbacks`, which is only reachable through it. The rule this
//! creates — the authenticated URL must never touch disk — is kept by
//! `git_remote_create_anonymous`, whose remote is in-memory and never written
//! to `.git/config`, and by never logging anything but `url.redact`'s output.
//!
//! **`ensureClone` reproduces `git clone --bare`'s ref layout, deliberately.**
//! There is no `git_clone` here; a fresh bare repository is initialised and
//! then fetched with the two refspecs a bare clone produces:
//!
//! ```text
//! +refs/heads/*:refs/heads/*
//! +refs/tags/*:refs/tags/*
//! ```
//!
//! NOT Pkg's `refspecs_heads` (`Types.jl:746`), which is for the *later*
//! fetches and lands branches under `refs/remotes/cache/`. The difference is
//! not cosmetic, and it cost a red test to find: `resolveRev`'s fourth probe is
//! the bare rev, resolved through libgit2's revparse DWIM, and that DWIM looks
//! at `refs/tags/<rev>` but never at `refs/remotes/cache/tags/<rev>`. Cloning
//! into the cache namespace makes every TAG unresolvable — silently, and only
//! on this backend. Matching `git clone --bare` is what makes the two backends
//! answer the same thing, which the end-to-end test at the bottom asserts
//! directly rather than assuming.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const git = @import("git.zig");
const c = @import("c.zig");
const tls = @import("tls.zig");
const url_mod = @import("url.zig");
const auth_mod = @import("auth.zig");

const Error = git.Error;
const Sha1 = git.Sha1;

/// Whether this build has libgit2 in it (`-Dgit`). Everything below that
/// touches C is behind a comptime branch on this, so a build without it links
/// no libgit2 symbol at all and every entry point reports
/// `error.BackendUnavailable`.
pub const enabled: bool = c.enabled;

pub const InitError = Error || error{
    /// The linked libgit2 is not the pinned version. See `c.assertVersion`.
    LibgitVersionMismatch,
    StreamRegisterFailed,
    CertificateBundleLoadFailure,
};

pub const Options = struct {
    /// What `auth.decide` needs, per URL. The caller supplies the raw
    /// environment and `.netrc` contents; the decision itself is made here so
    /// that both `ensureClone` and `fetch` make it the same way.
    gh_token: ?[]const u8 = null,
    github_token: ?[]const u8 = null,
    /// The CONTENTS of `~/.netrc`, not a path (`auth.Options.netrc`).
    netrc: ?[]const u8 = null,

    /// Read/write timeout on a server socket, in milliseconds.
    ///
    /// Not a default of zero, which libgit2 documents as "block indefinitely".
    /// A package manager that can hang forever on one unresponsive server is a
    /// package manager that hangs `instantiate`, and the caller has no way to
    /// interrupt a blocking `git_remote_fetch`.
    server_timeout_ms: c_int = 120_000,
    /// Connect timeout, in milliseconds. libgit2 documents that this can be
    /// SHORTER than the system default (often 75 s) but never longer.
    connect_timeout_ms: c_int = 30_000,
};

pub const Lib = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,

    /// The last libgit2 message, copied. libgit2 keeps its own in thread-local
    /// storage and overwrites it on the next call, so a caller that wants to
    /// print it has to be handed a copy at the moment of failure.
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    pub fn init(gpa: Allocator, io: Io, opts: Options) InitError!Lib {
        return if (enabled) initImpl(gpa, io, opts) else error.BackendUnavailable;
    }

    pub fn deinit(self: *Lib) void {
        if (enabled) deinitImpl(self);
    }

    pub fn backend(self: *Lib) git.Backend {
        return .{ .ctx = self, .vtable = &vtable, .which = .lib };
    }

    /// Why the last operation failed, in libgit2's words. Empty when nothing
    /// has failed yet.
    pub fn message(self: *const Lib) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// `git ls-remote`: the refs a server advertises, without cloning anything.
    ///
    /// Not part of the `Backend` vtable — nothing in Pkg's flow needs it. It is
    /// here because it is the smallest thing that exercises the entire
    /// transport (TCP, TLS, HTTP, smart-protocol v2 negotiation, ref
    /// advertisement) and therefore the sharpest gate on the registered stream.
    ///
    /// Uses `git_remote_create_detached` rather than `..._anonymous`, so no
    /// repository is needed and no local configuration can influence the
    /// result.
    pub fn lsRemote(self: *Lib, arena: Allocator, remote: []const u8) Error![]const Ref {
        return if (enabled) lsRemoteImpl(self, arena, remote) else error.BackendUnavailable;
    }

    /// `git hash-object -t blob`, through libgit2's own SHA-1.
    ///
    /// The point is *whose* SHA-1: this build uses sha1dc
    /// (`GIT_SHA1_COLLISIONDETECT`), which is vendored with
    /// `SHA1DC_NO_STANDARD_INCLUDES` and takes its integer types and byte order
    /// from two macros named on the command line (`build.zig`). Get those wrong
    /// and it compiles cleanly to a function that is not SHA-1. Ajt's own tree
    /// hashing uses native Zig SHA-1 and would never notice, so this is the
    /// only path on which the mistake is visible — hence `ajt git hash-object`
    /// and the corpus diff in `tools/diff_harness/git_stream.sh`.
    pub fn hashObject(self: *Lib, data: []const u8) Error!Sha1 {
        return if (enabled) hashObjectImpl(self, data) else error.BackendUnavailable;
    }
};

/// What `git clone --bare` writes: the remote's branches and its tags, at their
/// own names. See the module header for why the tags row is load-bearing.
const clone_refspecs = [_][]const u8{
    "+refs/heads/*:refs/heads/*",
    "+refs/tags/*:refs/tags/*",
};

/// One advertised ref. `id` is the ref's own target; a peeled annotated tag is
/// not reported separately, which is what `git ls-remote`'s `^{}` lines are.
pub const Ref = struct {
    id: Sha1,
    name: []const u8,
};

const vtable: git.Backend.VTable = if (enabled) .{
    .ensureClone = ensureClone,
    .fetch = fetch,
    .resolveRev = resolveRev,
    .treeOf = treeOf,
    .hasObject = hasObject,
    .materialise = materialise,
    .cloneWorking = unavailable.cloneWorking,
    .isDirty = unavailable.isDirty,
    .headBranch = unavailable.headBranch,
    .remoteUrl = unavailable.remoteUrl,
    .fastForward = unavailable.fastForward,
    .rebase = unavailable.rebase,
    .defaultRev = unavailable.defaultRev,
} else .{
    // Every row, not only the six that were once the whole vtable: without
    // `-Dgit` this arm is what a `Backend` from here points at, and a missing
    // field is a compile error only once something actually builds one. Until
    // `main.zig` routed the production call sites through the selection,
    // nothing did — so an incomplete table here sat latent rather than red.
    .ensureClone = unavailable.ensureClone,
    .fetch = unavailable.fetch,
    .resolveRev = unavailable.resolveRev,
    .treeOf = unavailable.treeOf,
    .hasObject = unavailable.hasObject,
    .materialise = unavailable.materialise,
    .cloneWorking = unavailable.cloneWorking,
    .isDirty = unavailable.isDirty,
    .headBranch = unavailable.headBranch,
    .remoteUrl = unavailable.remoteUrl,
    .fastForward = unavailable.fastForward,
    .rebase = unavailable.rebase,
    .defaultRev = unavailable.defaultRev,
};

/// The vtable for a build without `-Dgit`. Six functions with the exact
/// signatures, none of which mentions a libgit2 symbol — which is the point:
/// selecting this vtable at comptime is what keeps `c.zig`'s externs out of the
/// binary entirely, rather than merely unreached.
const unavailable = struct {
    fn ensureClone(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: git.CloneOptions) Error!void {
        return error.BackendUnavailable;
    }
    fn fetch(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: []const u8) Error!void {
        return error.BackendUnavailable;
    }
    fn resolveRev(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) Error!?git.Rev {
        return error.BackendUnavailable;
    }
    fn treeOf(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8, _: ?[]const u8) Error!git.TreeId {
        return error.BackendUnavailable;
    }
    fn hasObject(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: Sha1) Error!bool {
        return error.BackendUnavailable;
    }
    fn materialise(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: git.TreeId, _: []const u8) Error!void {
        return error.BackendUnavailable;
    }
    // The six repository operations `registry update` over a git clone needs.
    // Not implemented on the libgit2 side yet — `cli.zig` is the default
    // backend and has them — so both arms answer `BackendUnavailable` rather
    // than half a second implementation.
    fn cloneWorking(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) Error!void {
        return error.BackendUnavailable;
    }
    fn isDirty(_: *anyopaque, _: Allocator, _: Io, _: []const u8) Error!bool {
        return error.BackendUnavailable;
    }
    fn headBranch(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8) Error!?[]const u8 {
        return error.BackendUnavailable;
    }
    fn remoteUrl(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8, _: []const u8) Error!?[]const u8 {
        return error.BackendUnavailable;
    }
    fn fastForward(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) Error!bool {
        return error.BackendUnavailable;
    }
    fn rebase(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: []const u8) Error!void {
        return error.BackendUnavailable;
    }
    fn defaultRev(_: *anyopaque, _: Allocator, _: Allocator, _: Io, _: []const u8) Error![]const u8 {
        return error.BackendUnavailable;
    }
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

fn initImpl(gpa: Allocator, io: Io, opts: Options) InitError!Lib {
    // Refcounted inside libgit2, so several `Lib`s in one process are fine.
    if (c.git_libgit2_init() < 0) return error.BackendUnavailable;
    errdefer _ = c.git_libgit2_shutdown();

    try c.assertVersion();

    // Verify every object's hash as it is read out of a pack, rather than
    // trusting the packfile's own framing. This is off by default in libgit2
    // and Ajt is a program whose entire job is putting other people's bytes on
    // disk under a name derived from their hash.
    if (c.git_libgit2_opts(c.GIT_OPT_ENABLE_STRICT_HASH_VERIFICATION, @as(c_int, 1)) < 0)
        return error.BackendUnavailable;

    // Without these two, an unresponsive server blocks `git_remote_fetch`
    // forever and there is no callback from which to cancel it.
    if (c.git_libgit2_opts(c.GIT_OPT_SET_SERVER_TIMEOUT, opts.server_timeout_ms) < 0)
        return error.BackendUnavailable;
    if (c.git_libgit2_opts(c.GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, opts.connect_timeout_ms) < 0)
        return error.BackendUnavailable;

    try tls.register(gpa, io);

    return .{ .gpa = gpa, .io = io, .opts = opts };
}

fn deinitImpl(self: *Lib) void {
    tls.deregister(self.io);
    _ = c.git_libgit2_shutdown();
    self.* = undefined;
}

/// Copy libgit2's message out of its thread-local storage, where the next call
/// would overwrite it — **with any embedded credential removed**.
///
/// This is not defensive tidiness. Credentials reach libgit2 inside the URL
/// (see the module header), and several of libgit2's own messages quote the URL
/// back verbatim — `git_net_url_parse` says `"malformed URL '%s'"` with the
/// whole string. That message goes straight to stderr from `ajt git`, which on
/// CI means straight into a build log. `url.zig`'s header states the rule this
/// keeps: *every path that renders a URL for a human or a log goes through
/// `redact`*.
fn record(self: *Lib) void {
    const msg = c.lastError();
    self.message_len = redactInto(&self.message_buf, msg);
}

/// Copy `msg` into `out`, replacing the userinfo of every `scheme://user:pw@host`
/// it contains with `***`. Returns the length written.
///
/// The same rule as `url.redact`, but scanning rather than parsing a whole
/// string, because the input here is prose with a URL somewhere inside it. A
/// placeholder rather than deletion, so "the credential was stripped" and "there
/// was no credential" stay distinguishable while debugging a 401.
fn redactInto(out: *[512]u8, msg: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < msg.len) {
        // `://` starts an authority. Everything up to it is copied as is.
        if (msg[i] == ':' and i + 2 < msg.len and msg[i + 1] == '/' and msg[i + 2] == '/') {
            n = append(out, n, msg[i .. i + 3]);
            i += 3;
            // The authority ends at the first delimiter, or at whitespace or a
            // quote -- the URL is embedded in a sentence, so it may simply stop.
            var end = i;
            while (end < msg.len and std.mem.indexOfScalar(u8, "/?#'\" \t", msg[end]) == null) end += 1;
            // The LAST `@` inside it delimits userinfo (RFC 3986 3.2.1): a
            // password may legitimately contain one.
            if (std.mem.lastIndexOfScalar(u8, msg[i..end], '@')) |at| {
                n = append(out, n, "***@");
                i += at + 1;
            }
            n = append(out, n, msg[i..end]);
            i = end;
            continue;
        }
        n = append(out, n, msg[i .. i + 1]);
        i += 1;
    }
    return n;
}

fn append(out: *[512]u8, n: usize, s: []const u8) usize {
    const room = @min(s.len, out.len - n);
    @memcpy(out[n..][0..room], s[0..room]);
    return n + room;
}

/// Record libgit2's message and return `e`. Every failure path goes through
/// here: libgit2 signals failure with a return code and leaves the explanation
/// in thread-local storage, so a code returned without reading it discards the
/// only thing that says what went wrong.
fn oops(self: *Lib, e: Error) Error {
    record(self);
    return e;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn ctxOf(ctx: *anyopaque) *Lib {
    return @ptrCast(@alignCast(ctx));
}

/// Does `path` exist as a directory with anything in it? False for a path that
/// does not exist, which is the ordinary case for a fresh clone.
fn nonEmptyDir(io: Io, path: []const u8) Error!bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        // Not a directory, or not there. Either way `git_repository_init` is
        // free to create it.
        else => return false,
    };
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return false,
    };
    return first != null;
}

/// Open an existing repository, or null when there is none at `path`.
///
/// Null rather than an error, and libgit2's message deliberately NOT recorded:
/// "there is no repository here yet" is the normal state on the first
/// `ensureClone`, and stashing "could not find repository" in `message` would
/// leave a misleading explanation behind a later, unrelated failure.
fn openRepo(gpa: Allocator, path: []const u8) Error!?*c.git_repository {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    var repo: *c.git_repository = undefined;
    if (c.git_repository_open(&repo, path_z) != 0) return null;
    return repo;
}

/// The URL as it goes to libgit2: `GitTools.normalize_url` (trailing slashes
/// off), plus a credential if `auth.decide` says one applies.
///
/// Allocated from `gpa` and freed by the caller. It must never be logged or
/// persisted — `url.redact` exists for that.
fn authenticatedUrl(self: *Lib, gpa: Allocator, remote: []const u8) Allocator.Error![:0]u8 {
    const normalized = url_mod.normalize(remote);
    const decision = auth_mod.decide(.{
        .host = url_mod.hostOf(normalized),
        .kind = url_mod.classify(normalized),
        .gh_token = self.opts.gh_token,
        .github_token = self.opts.github_token,
        .netrc = self.opts.netrc,
    });
    const creds = decision.creds orelse return gpa.dupeZ(u8, normalized);

    const with = try url_mod.withCredentials(gpa, normalized, creds);
    defer gpa.free(with);
    return gpa.dupeZ(u8, with);
}

/// `git_remote_fetch(remote, refspecs, NULL, NULL)` against an in-memory
/// remote. See the module header for why the options are NULL.
fn fetchInto(
    self: *Lib,
    gpa: Allocator,
    repo: *c.git_repository,
    remote: []const u8,
    refspecs: []const []const u8,
) Error!void {
    const url_z = try authenticatedUrl(self, gpa, remote);
    defer {
        // The buffer held a credential. Scrub before returning it to the
        // allocator: a freed page is not a private page.
        @memset(url_z, 0);
        gpa.free(url_z);
    }

    var rem: *c.git_remote = undefined;
    if (c.git_remote_create_anonymous(&rem, repo, url_z) != 0) return oops(self, error.FetchFailed);
    defer c.git_remote_free(rem);

    const specs = try gpa.alloc(?[*:0]const u8, refspecs.len);
    defer gpa.free(specs);
    // `owned` rather than freeing all of `specs`: on an OOM part-way through,
    // the tail is still uninitialised memory and freeing it would be a wild
    // pointer.
    var owned: usize = 0;
    defer for (specs[0..owned]) |p| gpa.free(std.mem.span(p.?));
    for (refspecs, 0..) |spec, i| {
        specs[i] = (try gpa.dupeZ(u8, spec)).ptr;
        owned = i + 1;
    }
    const arr: c.git_strarray = .{ .strings = specs.ptr, .count = specs.len };

    if (c.git_remote_fetch(rem, &arr, null, null) != 0) return oops(self, error.FetchFailed);
}

/// `git_revparse_single`, returning null when the spec simply does not resolve.
///
/// `^{}` is appended, exactly as `cli.zig`'s `revParse` does, so both backends
/// answer the same thing for an annotated tag: the commit it points at rather
/// than the tag object. Pkg does not peel here (`Types.jl:1095-1120` hands the
/// object straight to `peel(GitTree, …)`), so the difference is invisible to
/// the tree hash — but a `Rev.commit` that is a tag id on one backend and a
/// commit id on the other would not be.
fn revParse(gpa: Allocator, repo: *c.git_repository, spec: []const u8) Error!?Sha1 {
    const spec_z = try std.mem.concatWithSentinel(gpa, u8, &.{ spec, "^{}" }, 0);
    defer gpa.free(spec_z);

    var obj: *c.git_object = undefined;
    if (c.git_revparse_single(&obj, repo, spec_z) != 0) {
        // Not found, not a valid spec, ambiguous -- all of them mean "not here"
        // to the caller, whose next move is to fetch and try again
        // (`Types.jl:1000-1009`). `cli.zig` collapses them the same way, by
        // treating any non-zero exit from `rev-parse --verify --quiet` as null.
        //
        // libgit2's message is deliberately NOT recorded. `resolveRev` probes
        // four namespaces and the first three miss on every ordinary lookup, so
        // recording here would leave "revspec 'remotes/cache/heads/main' not
        // found" sitting in `message()` behind a later, unrelated failure.
        return null;
    }
    defer c.git_object_free(obj);
    return .{ .bytes = c.git_object_id(obj).id };
}

// ---------------------------------------------------------------------------
// The vtable
// ---------------------------------------------------------------------------

/// `GitTools.ensure_clone` (`GitTools.jl:74-80`): open it if it is already a
/// repository, otherwise create one. Idempotent — `clones/` is a cache
/// directory that usually already exists.
fn ensureClone(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, _: git.CloneOptions) Error!void {
    const self = ctxOf(ctx);
    if (try openRepo(gpa, path)) |repo| {
        c.git_repository_free(repo);
        return;
    }

    // `git clone` refuses a destination that exists and is not empty, and that
    // refusal is load-bearing: `git_repository_init` would happily scatter
    // `objects/`, `refs/` and `HEAD` into a directory full of somebody else's
    // files and then call it a repository. `cli.zig` gets this from `git`;
    // here it has to be checked.
    if (try nonEmptyDir(io, path)) return error.NotAGitRepo;

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    var repo: *c.git_repository = undefined;
    if (c.git_repository_init(&repo, path_z, 1) != 0) return oops(self, error.CloneFailed);

    // The repository handle is released before the directory is, so the two
    // cleanups cannot race and there is no `defer` left to double-free.
    const result = fetchInto(self, gpa, repo, remote, &clone_refspecs);
    c.git_repository_free(repo);

    // A half-populated repository is worse than none: `ensureClone` would open
    // it happily next time, and every `resolveRev` after that would miss for a
    // reason nothing reports. So a failed first fetch takes the directory with
    // it, and the next attempt is a clone again.
    result catch |err| {
        Io.Dir.cwd().deleteTree(io, path) catch {};
        return err;
    };
}

fn fetch(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, refspec: []const u8) Error!void {
    _ = io;
    const self = ctxOf(ctx);
    const repo = try openRepo(gpa, path) orelse return error.NotAGitRepo;
    defer c.git_repository_free(repo);
    try fetchInto(self, gpa, repo, remote, &.{refspec});
}

/// `get_object_or_branch` (`Types.jl:1095-1120`), in its exact order: three
/// branch namespaces, then the rev as a bare object.
///
/// The order is not cosmetic. A repository can hold both a branch `v1` and a
/// tag `v1`; Pkg resolves the branch and reports `is_branch = true`, which is
/// what makes `add Foo#v1` track the branch instead of pinning the tag.
fn resolveRev(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, rev: []const u8) Error!?git.Rev {
    _ = io;
    // Nothing here needs the `Lib`: a miss is a normal answer, so there is no
    // libgit2 message worth recording.
    _ = ctx;
    const repo = try openRepo(gpa, path) orelse return error.NotAGitRepo;
    defer c.git_repository_free(repo);

    for ([_][]const u8{ "remotes/cache/heads/", "remotes/origin/", "heads/" }) |prefix| {
        const spec = try std.mem.concat(gpa, u8, &.{ prefix, rev });
        defer gpa.free(spec);
        if (try revParse(gpa, repo, spec)) |id| return .{ .commit = id, .is_branch = true };
    }
    if (try revParse(gpa, repo, rev)) |id| return .{ .commit = id, .is_branch = false };
    return null;
}

fn treeOf(
    ctx: *anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    object: []const u8,
    subdir: ?[]const u8,
) Error!git.TreeId {
    _ = io;
    const self = ctxOf(ctx);
    const repo = try openRepo(gpa, path) orelse return error.NotAGitRepo;
    defer c.git_repository_free(repo);

    // `<object>:<subdir>` names the sub-tree directly, which is what
    // `tree_hash_object[pkg.repo.subdir]` does (`Types.jl:1025`);
    // `<object>^{tree}` peels a commit (or a tag, or a tree) to its tree.
    const spec = if (subdir) |d|
        try std.mem.concatWithSentinel(gpa, u8, &.{ object, ":", d }, 0)
    else
        try std.mem.concatWithSentinel(gpa, u8, &.{ object, "^{tree}" }, 0);
    defer gpa.free(spec);

    var obj: *c.git_object = undefined;
    if (c.git_revparse_single(&obj, repo, spec) != 0)
        return oops(self, if (subdir != null) error.SubdirNotFound else error.ObjectNotFound);
    defer c.git_object_free(obj);

    // `<x>:<subdir>` happily resolves to a BLOB when the subdir names a file,
    // and a blob id where a tree id belongs would be written into the manifest
    // as a `git-tree-sha1` that nothing can ever materialise.
    if (c.git_object_type(obj) != c.GIT_OBJECT_TREE) return error.NotATree;
    return .{ .bytes = c.git_object_id(obj).id };
}

fn hasObject(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, id: Sha1) Error!bool {
    _ = io;
    const self = ctxOf(ctx);
    const repo = try openRepo(gpa, path) orelse return error.NotAGitRepo;
    defer c.git_repository_free(repo);

    var odb: *c.git_odb = undefined;
    if (c.git_repository_odb(&odb, repo) != 0) return oops(self, error.NotAGitRepo);
    defer c.git_odb_free(odb);

    const oid: c.git_oid = .{ .id = id.bytes };
    return c.git_odb_exists(odb, &oid) == 1;
}

/// Write `tree` into `dest` as raw blob bytes. See the module header for why
/// this is a tree walk and not `git_checkout_tree`.
///
/// Two passes. The first refuses — a submodule anywhere, or an entry name that
/// could escape `dest` — and touches nothing; the second writes. That order is
/// the same contract `cli.zig` has, where `ls-tree -r -t` runs before
/// `git archive`, and it is what makes "a repository with a submodule is
/// refused, not mis-hashed" leave an empty destination behind.
fn materialise(
    ctx: *anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    tree: git.TreeId,
    dest: []const u8,
) Error!void {
    const self = ctxOf(ctx);
    const repo = try openRepo(gpa, path) orelse return error.NotAGitRepo;
    defer c.git_repository_free(repo);

    const oid: c.git_oid = .{ .id = tree.bytes };
    var root: *c.git_tree = undefined;
    // `git_tree_lookup` fails both for "not here" and for "here, but not a
    // tree" — `install_git`'s "git object could not be found" covers the first
    // and the caller has already been through `treeOf` for the second.
    if (c.git_tree_lookup(&root, repo, &oid) != 0) return oops(self, error.ObjectNotFound);
    defer c.git_tree_free(root);

    try scanTree(self, repo, root, 0);

    var dir = Io.Dir.cwd().openDir(io, dest, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CloneFailed,
    };
    defer dir.close(io);

    _ = try writeTree(self, io, repo, root, dir, 0);
}

/// How deep a tree may nest before this is treated as an attack rather than a
/// repository.
///
/// The recursion below is on the C stack, and the tree came off a remote. Git's
/// own limit is `MAX_TREE_DEPTH = 4096` in `fsck.c`; a quarter of that is far
/// past anything real (the deepest path in the General registry's packages is
/// well under twenty) and leaves the stack alone.
const max_tree_depth = 1024;

/// Pass one: refuse whatever must be refused, having written nothing.
fn scanTree(self: *Lib, repo: *c.git_repository, tree: *const c.git_tree, depth: usize) Error!void {
    if (depth >= max_tree_depth) return error.CloneFailed;
    const n = c.git_tree_entrycount(tree);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_tree_entry_byindex(tree, i) orelse return error.CloneFailed;
        const raw_name = c.git_tree_entry_name(entry) orelse return error.CloneFailed;
        if (!safeEntryName(std.mem.span(raw_name))) return error.CloneFailed;

        switch (c.git_tree_entry_filemode(entry)) {
            c.GIT_FILEMODE_TREE => {
                var sub: *c.git_tree = undefined;
                if (c.git_tree_lookup(&sub, repo, c.git_tree_entry_id(entry)) != 0)
                    return oops(self, error.ObjectNotFound);
                defer c.git_tree_free(sub);
                try scanTree(self, repo, sub, depth + 1);
            },
            // A gitlink is part of the tree hash and cannot be reproduced from
            // a working tree at all, so it is named rather than skipped — see
            // `git.zig`'s header.
            c.GIT_FILEMODE_COMMIT => return error.SubmodulePresent,
            c.GIT_FILEMODE_BLOB, c.GIT_FILEMODE_BLOB_EXECUTABLE, c.GIT_FILEMODE_LINK => {},
            // `normalize_filemode` (`tree.c:35-55`) maps every stored mode onto
            // one of the six, so this arm is unreachable through libgit2 today.
            // It is a refusal rather than an `unreachable` because the thing
            // being classified is a remote's bytes.
            else => return error.CloneFailed,
        }
    }
}

/// Pass two: write. Returns whether anything at all landed under `dir`.
///
/// The return value exists for empty directories. A git tree cannot represent
/// one, so this normally never fires — but a tree object CAN be built with an
/// empty sub-tree, and `cli.zig` extracts with `exclude_empty_directories`, so
/// leaving one behind here would make the two backends differ on disk while
/// still agreeing on the hash (`treehash.zig` prunes them too). Created and
/// then removed rather than pre-computed, because the predicate "does this
/// subtree contain a blob anywhere" is a second full walk to answer.
fn writeTree(
    self: *Lib,
    io: Io,
    repo: *c.git_repository,
    tree: *const c.git_tree,
    dir: Io.Dir,
    depth: usize,
) Error!bool {
    if (depth >= max_tree_depth) return error.CloneFailed;
    var wrote = false;
    const n = c.git_tree_entrycount(tree);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_tree_entry_byindex(tree, i) orelse return error.CloneFailed;
        const name = std.mem.span(c.git_tree_entry_name(entry) orelse return error.CloneFailed);
        const mode = c.git_tree_entry_filemode(entry);

        if (mode == c.GIT_FILEMODE_TREE) {
            var sub: *c.git_tree = undefined;
            if (c.git_tree_lookup(&sub, repo, c.git_tree_entry_id(entry)) != 0)
                return oops(self, error.ObjectNotFound);
            defer c.git_tree_free(sub);

            dir.createDir(io, name, .default_dir) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return error.CloneFailed,
            };
            var child = dir.openDir(io, name, .{}) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return error.CloneFailed,
            };
            const child_wrote = blk: {
                defer child.close(io);
                break :blk try writeTree(self, io, repo, sub, child, depth + 1);
            };
            if (child_wrote) {
                wrote = true;
            } else {
                dir.deleteDir(io, name) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => return error.CloneFailed,
                };
            }
            continue;
        }

        var blob: *c.git_blob = undefined;
        if (c.git_blob_lookup(&blob, repo, c.git_tree_entry_id(entry)) != 0)
            return oops(self, error.ObjectNotFound);
        defer c.git_blob_free(blob);
        const data = blobBytes(blob);

        if (mode == c.GIT_FILEMODE_LINK) {
            // A symlink's blob content IS its target, which is also how
            // `treehash.zig` hashes one back. The target may point outside the
            // tree — Julia packages do that — and that is fine: what must not
            // happen is anything being written THROUGH a symlink, which cannot
            // arise here because every directory on the path was created as a
            // directory by the loop above, and a tree cannot hold two entries
            // with the same name.
            dir.symLink(io, data, name, .{}) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return error.CloneFailed,
            };
        } else {
            // `.default_file`/`.executable_file` rather than an explicit
            // `0o644`/`0o755`: they are `0o666`/`0o777` before the process
            // umask, which is what `std.tar.extract` uses on `cli.zig`'s path
            // (`std/tar.zig:1162-1168`). Spelling the post-umask number here
            // would make the two backends produce different permissions under
            // any umask but 022.
            dir.writeFile(io, .{
                .sub_path = name,
                .data = data,
                .flags = .{
                    .exclusive = true,
                    .permissions = if (mode == c.GIT_FILEMODE_BLOB_EXECUTABLE)
                        .executable_file
                    else
                        .default_file,
                },
            }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => return error.CloneFailed,
            };
        }
        wrote = true;
    }
    return wrote;
}

/// A blob's raw, unfiltered bytes.
///
/// `git_blob_rawsize` is `git_object_size_t` (64-bit even on a 32-bit target),
/// so it is narrowed deliberately; a blob larger than `usize` cannot be written
/// through a `[]const u8` at all and is refused by the caller's write rather
/// than silently truncated. `rawcontent` may be null for a zero-length blob,
/// which is a legitimate file and not an error.
fn blobBytes(blob: *const c.git_blob) []const u8 {
    const size = c.git_blob_rawsize(blob);
    if (size == 0) return "";
    const ptr = c.git_blob_rawcontent(blob) orelse return "";
    const bytes: [*]const u8 = @ptrCast(ptr);
    return bytes[0..@intCast(size)];
}

/// May this tree entry name become a path component under `dest`?
///
/// The single-component form of `cli.zig`'s `safeRelPath`, which guards the
/// same destination against the same class of name arriving through a tar
/// stream instead of a tree object. Both are stricter than they need to be for
/// any repository anybody actually publishes, and deliberately: the bytes came
/// off a remote, and `git fsck` refusing a name is not the same as nothing ever
/// producing one.
///
/// A tree entry is one component by construction — git stores no separator in
/// a name — so `/` and `\` are rejected outright rather than split on, and `.`
/// is rejected as well as `..` because a tree can contain either and neither is
/// a file.
fn safeEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    // A Windows drive or stream qualifier, matching `safeRelPath`'s rule.
    if (name.len >= 2 and name[1] == ':') return false;
    return true;
}

// ---------------------------------------------------------------------------
// Beyond the vtable
// ---------------------------------------------------------------------------

fn lsRemoteImpl(self: *Lib, arena: Allocator, remote: []const u8) Error![]const Ref {
    const url_z = try authenticatedUrl(self, arena, remote);
    defer @memset(url_z, 0);

    var rem: *c.git_remote = undefined;
    if (c.git_remote_create_detached(&rem, url_z) != 0) return oops(self, error.FetchFailed);
    defer c.git_remote_free(rem);

    if (c.git_remote_connect(rem, c.GIT_DIRECTION_FETCH, null, null, null) != 0)
        return oops(self, error.FetchFailed);
    defer _ = c.git_remote_disconnect(rem);

    var heads: [*]const *const c.git_remote_head = undefined;
    var count: usize = 0;
    if (c.git_remote_ls(&heads, &count, rem) != 0) return oops(self, error.FetchFailed);

    const out = try arena.alloc(Ref, count);
    for (out, 0..) |*ref, i| {
        const head = heads[i];
        ref.* = .{
            .id = .{ .bytes = head.oid.id },
            .name = if (head.name) |n| try arena.dupe(u8, std.mem.span(n)) else "",
        };
    }
    return out;
}

fn hashObjectImpl(self: *Lib, data: []const u8) Error!Sha1 {
    var oid: c.git_oid = undefined;
    if (c.git_odb_hash(&oid, data.ptr, data.len, c.GIT_OBJECT_BLOB) != 0)
        return oops(self, error.ObjectNotFound);
    return .{ .bytes = oid.id };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a libgit2 message never carries the credential back out" {
    // The credential rides in the URL, and libgit2 quotes URLs back at you --
    // `git_net_url_parse` reports `malformed URL '%s'` with the whole string.
    // `ajt git` prints `lib.message()` to stderr on failure, so an unredacted
    // message is a token in a CI log.
    //
    // Runs without libgit2 too: it is pure string handling, and it is the one
    // piece of this file that must not be skipped on a machine that cannot
    // build the C.
    var buf: [512]u8 = undefined;

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{
            .in = "malformed URL 'https://x-access-token:ghp_SECRET@github.com/o/r.git'",
            .want = "malformed URL 'https://***@github.com/o/r.git'",
        },
        // The LAST `@`, because a password may contain one.
        .{
            .in = "failed: https://user:p@ss@github.com/o/r",
            .want = "failed: https://***@github.com/o/r",
        },
        // No userinfo: untouched, so "there was no credential" stays readable.
        .{
            .in = "unexpected http status code: 404 for https://github.com/o/r",
            .want = "unexpected http status code: 404 for https://github.com/o/r",
        },
        // No URL at all.
        .{ .in = "revspec 'heads/main' not found", .want = "revspec 'heads/main' not found" },
        // A `@` AFTER the authority is part of the path, not userinfo.
        .{
            .in = "cannot read https://github.com/o/r@v1",
            .want = "cannot read https://github.com/o/r@v1",
        },
        // The URL ends at whitespace rather than at a delimiter.
        .{ .in = "git://tok@host and then some", .want = "git://***@host and then some" },
        // Two of them.
        .{
            .in = "https://a:b@h1/x then https://c:d@h2/y",
            .want = "https://***@h1/x then https://***@h2/y",
        },
    };
    for (cases) |case| {
        const n = redactInto(&buf, case.in);
        try testing.expectEqualStrings(case.want, buf[0..n]);
    }

    // And it cannot run off the end of the fixed buffer.
    const long = "https://user:pw@host/" ++ ("a" ** 900);
    const n = redactInto(&buf, long);
    try testing.expectEqual(@as(usize, buf.len), n);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "pw") == null);
}

test "without -Dgit every entry point reports BackendUnavailable rather than crashing" {
    if (enabled) return error.SkipZigTest;
    try testing.expectError(error.BackendUnavailable, Lib.init(testing.allocator, testing.io, .{}));
}

test "an ssh URL is refused by the interface, before libgit2 is asked" {
    // The guard lives on `git.Backend`, not in either backend, so the message
    // is the same whichever one is selected -- and libgit2 without `GIT_SSH`
    // would otherwise say only "Unsupported URL protocol".
    if (!enabled) return error.SkipZigTest;
    var lib = try Lib.init(testing.allocator, testing.io, .{});
    defer lib.deinit();
    const b = lib.backend();
    try testing.expectError(
        error.SshUnsupported,
        b.ensureClone(testing.allocator, testing.io, "/tmp/ajt-nonexistent", "git@github.com:o/r.git", .{}),
    );
}

test "safeEntryName is the single-component form of cli.zig's safeRelPath" {
    // Runs without libgit2: pure string handling, and the one part of
    // `materialise` a machine that cannot build the C can still check.
    try testing.expect(safeEntryName("Project.toml"));
    try testing.expect(safeEntryName("a"));
    try testing.expect(safeEntryName(".gitignore"));
    try testing.expect(safeEntryName(".gitattributes"));
    // A name that merely CONTAINS dots is fine; only the two whole names are
    // not, exactly as in `safeRelPath`.
    try testing.expect(safeEntryName("a..b"));
    try testing.expect(safeEntryName("..a"));
    try testing.expect(safeEntryName("שלום.jl")); // names are bytes, not ASCII

    try testing.expect(!safeEntryName(""));
    try testing.expect(!safeEntryName("."));
    try testing.expect(!safeEntryName(".."));
    // A separator inside a single component: git stores none, so anything
    // carrying one is a tree built to escape the destination.
    try testing.expect(!safeEntryName("a/b"));
    try testing.expect(!safeEntryName("/etc"));
    try testing.expect(!safeEntryName("a\\b"));
    try testing.expect(!safeEntryName("C:"));
}

test "hash-object agrees with git's own SHA-1 on the empty blob and a known one" {
    // The two blob hashes every git user has seen. If sha1dc were mis-built by
    // the `SHA1DC_CUSTOM_INCLUDE_*` macros it would still compile and still
    // return twenty bytes -- just not these twenty. The corpus-wide version of
    // this check is `tools/diff_harness/git_stream.sh`.
    if (!enabled) return error.SkipZigTest;
    var lib = try Lib.init(testing.allocator, testing.io, .{});
    defer lib.deinit();

    const empty = try lib.hashObject("");
    try testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        &std.fmt.bytesToHex(empty.bytes, .lower),
    );
    const hello = try lib.hashObject("hello\n");
    try testing.expectEqualStrings(
        "ce013625030ba8dba906f756967f9e9ca394464a",
        &std.fmt.bytesToHex(hello.bytes, .lower),
    );
}

test "clone, resolve and tree against a real repository, over file://" {
    // The clone/resolve/tree half of the vtable, with no network: `file://`
    // goes through `git_transport_local` (`transport.c:35`), so this exercises
    // the repository, refspec, revparse and ODB paths on every machine, and the
    // network paths are gated separately by `git_stream.sh`. `materialise` has
    // its own test below.
    if (!enabled) return error.SkipZigTest;

    const gpa = testing.allocator;
    const io = testing.io;
    const cli = @import("cli.zig");
    if (!cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const src = try std.fs.path.join(arena, &.{ root, "src" });
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/README.md", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/inner.jl", .data = "module Inner end\n" });
    try cli.fixtureGit(gpa, io, src, &.{ "init", "--quiet", "--initial-branch=main" });
    try cli.fixtureGit(gpa, io, src, &.{ "add", "-A" });
    try cli.fixtureGit(gpa, io, src, &.{ "commit", "--quiet", "-m", "initial" });
    try cli.fixtureGit(gpa, io, src, &.{ "tag", "-a", "v1.0.0", "-m", "annotated" });

    const head_commit_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_commit_hex);
    const head_tree_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree_hex);
    const sub_tree_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD:sub" });
    defer gpa.free(sub_tree_hex);

    var lib = try Lib.init(gpa, io, .{});
    defer lib.deinit();
    const b = lib.backend();

    const clone = try std.fs.path.join(arena, &.{ root, "clones", "1" });
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{src});

    try b.ensureClone(gpa, io, clone, remote, .{});
    // Idempotent: a second call on an existing clone is a no-op, not a
    // "destination already exists" failure.
    try b.ensureClone(gpa, io, clone, remote, .{});

    // `ensureClone` reproduced a bare clone, so the branch is at `refs/heads/`
    // -- the THIRD namespace `resolveRev` probes, and the same one `cli.zig`'s
    // `git clone --bare` produces.
    const main_rev = (try b.resolveRev(gpa, io, clone, "main")).?;
    try testing.expect(main_rev.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(main_rev.commit.bytes, .lower));

    // An ANNOTATED tag is not a branch, and must peel through the tag object to
    // the commit -- that is what the `^{}` in `revParse` is for, and a tag id
    // here instead of a commit id is exactly the divergence from `cli.zig` that
    // would otherwise go unnoticed. This is also the assertion that caught the
    // refspec bug in the module header: resolving it at all requires the tag to
    // be at `refs/tags/`, where revparse's DWIM looks.
    const tag_rev = (try b.resolveRev(gpa, io, clone, "v1.0.0")).?;
    try testing.expect(!tag_rev.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(tag_rev.commit.bytes, .lower));

    try testing.expect(try b.resolveRev(gpa, io, clone, "no-such-rev") == null);

    // Pkg's own refspec, on an existing clone -- the later fetch, which lands
    // branches in `refs/remotes/cache/heads/`, the FIRST namespace probed.
    try b.fetch(gpa, io, clone, remote, git.refspecs_heads);
    const cached = (try b.resolveRev(gpa, io, clone, "main")).?;
    try testing.expect(cached.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(cached.commit.bytes, .lower));

    const tree = try b.treeOf(gpa, io, clone, head_commit_hex, null);
    try testing.expectEqualStrings(head_tree_hex, &std.fmt.bytesToHex(tree.bytes, .lower));
    const subtree = try b.treeOf(gpa, io, clone, head_commit_hex, "sub");
    try testing.expectEqualStrings(sub_tree_hex, &std.fmt.bytesToHex(subtree.bytes, .lower));

    try testing.expectError(error.SubdirNotFound, b.treeOf(gpa, io, clone, head_commit_hex, "nope"));
    try testing.expectError(error.NotATree, b.treeOf(gpa, io, clone, head_commit_hex, "README.md"));

    try testing.expect(try b.hasObject(gpa, io, clone, tree));
    try testing.expect(!try b.hasObject(gpa, io, clone, try git.Sha1.parse("0" ** 40)));

    // And the two backends agree, which is the property that makes the choice
    // between them a configuration rather than a behaviour change.
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli_backend: cli.Cli = .{ .environ = &environ };
    const cb = cli_backend.backend();
    const cli_clone = try std.fs.path.join(arena, &.{ root, "clones", "cli" });
    try cb.ensureClone(gpa, io, cli_clone, remote, .{});
    const cli_rev = (try cb.resolveRev(gpa, io, cli_clone, "v1.0.0")).?;
    try testing.expectEqual(tag_rev.is_branch, cli_rev.is_branch);
    try testing.expectEqualSlices(u8, &tag_rev.commit.bytes, &cli_rev.commit.bytes);
}

// ---------------------------------------------------------------------------
// materialise
// ---------------------------------------------------------------------------

const treehash = @import("../julia/treehash.zig");

/// Every entry under `path`, one sorted line each: kind, the permission bits,
/// the content hash, and a symlink's target.
///
/// Deliberately NOT `treehash.hashPath`, which is the weaker claim. Two
/// directories can hash identically and still differ on disk: the hasher prunes
/// empty directories, ignores every permission bit but `0o100`, and skips
/// `.git` entirely. What the two backends have to agree on is the DIRECTORY,
/// because that is what a caller gets, so the comparison is over the directory.
fn describeTree(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var lines: std.ArrayList([]const u8) = .empty;
    try describeInto(arena, io, dir, "", &lines);
    std.mem.sort([]const u8, lines.items, {}, lineLessThan);
    return std.mem.join(arena, "\n", lines.items);
}

fn lineLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn describeInto(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |raw| {
        const rel = if (prefix.len == 0)
            try arena.dupe(u8, raw.name)
        else
            try std.fs.path.join(arena, &.{ prefix, raw.name });
        switch (raw.kind) {
            .directory => {
                try out.append(arena, try std.fmt.allocPrint(arena, "d {s}", .{rel}));
                var sub = try dir.openDir(io, raw.name, .{ .iterate = true });
                defer sub.close(io);
                try describeInto(arena, io, sub, rel, out);
            },
            .sym_link => {
                var buf: [Io.Dir.max_path_bytes]u8 = undefined;
                const n = try dir.readLink(io, raw.name, &buf);
                try out.append(arena, try std.fmt.allocPrint(
                    arena,
                    "l {s} -> {s}",
                    .{ rel, buf[0..n] },
                ));
            },
            .file => {
                const data = try dir.readFileAlloc(io, raw.name, arena, .limited(1 << 28));
                const st = try dir.statFile(io, raw.name, .{});
                try out.append(arena, try std.fmt.allocPrint(arena, "f {o} {s} {s}", .{
                    st.permissions.toMode() & 0o7777,
                    &treehash.toHex(treehash.blobHash(data)),
                    rel,
                }));
            },
            // A socket or a fifo is not representable in a tree, so its
            // presence is itself the failure; recorded rather than skipped.
            else => try out.append(arena, try std.fmt.allocPrint(arena, "? {s}", .{rel})),
        }
    }
}

test "materialise writes raw blob bytes, and the two backends land the same directory" {
    if (!enabled) return error.SkipZigTest;

    const gpa = testing.allocator;
    const io = testing.io;
    const cli = @import("cli.zig");
    if (!cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // The same fixture `cli.zig`'s materialise test builds, because the point
    // is that both backends answer the same thing on it. Every file here is a
    // way a checkout -- or an unconfigured `git archive` -- writes something
    // other than the blob's own bytes:
    //
    //   eol=crlf      the blob holds `\n`; a filtered write puts `\r\n` on disk
    //   export-ignore `git archive` omits the file entirely
    //   export-subst  `$Format:%H$` is expanded to a commit sha
    //
    // libgit2 has no archive at all, so the last two are inert here by
    // construction; `eol=crlf` is the one a `git_checkout_tree` would apply,
    // and the tree walk is what makes it not.
    const src = try std.fs.path.join(arena, &.{ root, "src" });
    try tmp.dir.createDirPath(io, "src/sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/README.md", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/run.sh", .data = "#!/bin/sh\necho hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/inner.jl", .data = "module Inner end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/deeper/deep.txt", .data = "deep\n" });
    // An empty blob, which is a legitimate file and the one case where
    // `git_blob_rawcontent` may hand back a null pointer.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/empty", .data = "" });
    // Bytes that are already CRLF in the blob: they must survive UNCHANGED,
    // which is the opposite direction of the `eol` trap and catches a
    // "normalise line endings" that ran the other way.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/crlf.bin", .data = "a\r\nb\r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitattributes", .data =
        \\eol.txt text eol=crlf
        \\ignored.txt export-ignore
        \\subst.txt export-subst
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/eol.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ignored.txt", .data = "still here\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/subst.txt", .data = "v=$Format:%H$\n" });
    var src_dir = try tmp.dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    try src_dir.symLink(io, "README.md", "link.md", .{});
    // A symlink whose target points OUT of the tree. The tree hash records the
    // target text, not its destination, so this must be reproduced verbatim
    // rather than resolved or refused.
    try src_dir.symLink(io, "../outside/x", "escape.md", .{});
    {
        var f = try src_dir.openFile(io, "run.sh", .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, @enumFromInt(0o755));
    }

    try cli.fixtureGit(gpa, io, src, &.{ "init", "--quiet", "--initial-branch=main" });
    try cli.fixtureGit(gpa, io, src, &.{ "add", "-A" });
    try cli.fixtureGit(gpa, io, src, &.{ "commit", "--quiet", "-m", "initial" });

    const head_commit_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_commit_hex);
    const head_tree_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree_hex);
    const sub_tree_hex = try cli.fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD:sub" });
    defer gpa.free(sub_tree_hex);

    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{src});

    var lib = try Lib.init(gpa, io, .{});
    defer lib.deinit();
    const b = lib.backend();
    const lib_clone = try std.fs.path.join(arena, &.{ root, "clones", "lib" });
    try b.ensureClone(gpa, io, lib_clone, remote, .{});
    const tree = try b.treeOf(gpa, io, lib_clone, head_commit_hex, null);

    // --- THE assertion -------------------------------------------------------
    // What landed must hash, through Ajt's own independent tree hasher, to the
    // tree that was asked for. That is the postcondition in `git.zig`'s header
    // and the reason the depot slug names content that really has that hash.
    try tmp.dir.createDirPath(io, "dest_lib");
    const dest_lib = try std.fs.path.join(arena, &.{ root, "dest_lib" });
    try b.materialise(gpa, io, lib_clone, tree, dest_lib);
    try testing.expectEqualStrings(
        head_tree_hex,
        &std.fmt.bytesToHex(try treehash.hashPath(gpa, io, dest_lib), .lower),
    );

    // Spot-check each property the hash depends on, so a failure says which one
    // broke rather than only "hashes differ".
    var dest_dir = try tmp.dir.openDir(io, "dest_lib", .{ .iterate = true });
    defer dest_dir.close(io);
    try testing.expectEqualStrings(
        "one\ntwo\n", // no crlf filter: the blob's own bytes
        try dest_dir.readFileAlloc(io, "eol.txt", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "a\r\nb\r\n", // ...and nothing normalised them the other way either
        try dest_dir.readFileAlloc(io, "crlf.bin", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "still here\n", // no export-ignore: libgit2 has no archive to honour it
        try dest_dir.readFileAlloc(io, "ignored.txt", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "v=$Format:%H$\n", // literal, unexpanded
        try dest_dir.readFileAlloc(io, "subst.txt", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "",
        try dest_dir.readFileAlloc(io, "empty", arena, .limited(1024)),
    );
    const st = try dest_dir.statFile(io, "run.sh", .{});
    try testing.expect(@intFromEnum(st.permissions) & 0o100 != 0);
    const plain = try dest_dir.statFile(io, "README.md", .{});
    try testing.expect(@intFromEnum(plain.permissions) & 0o100 == 0);
    var link_buf: [256]u8 = undefined;
    const link_len = try dest_dir.readLink(io, "link.md", &link_buf);
    try testing.expectEqualStrings("README.md", link_buf[0..link_len]);
    const esc_len = try dest_dir.readLink(io, "escape.md", &link_buf);
    try testing.expectEqualStrings("../outside/x", link_buf[0..esc_len]);

    // A subtree materialises the same way, and it is the nested one, so the
    // recursion is exercised at both ends.
    try tmp.dir.createDirPath(io, "dest_lib_sub");
    const dest_lib_sub = try std.fs.path.join(arena, &.{ root, "dest_lib_sub" });
    try b.materialise(gpa, io, lib_clone, try b.treeOf(gpa, io, lib_clone, head_commit_hex, "sub"), dest_lib_sub);
    try testing.expectEqualStrings(
        sub_tree_hex,
        &std.fmt.bytesToHex(try treehash.hashPath(gpa, io, dest_lib_sub), .lower),
    );

    // --- and the two backends produce the SAME directory ---------------------
    // The claim that makes `AJT_GIT_BACKEND` a configuration rather than a
    // behaviour change. Each backend does its OWN `ensureClone` first, because
    // `cli.zig`'s materialise depends on the `$GIT_DIR/info/attributes` file
    // that only its own `ensureClone` writes -- materialising a cli checkout
    // out of a clone libgit2 created would honour `.gitattributes` and diverge.
    var environ = try cli.defaultEnviron(gpa, &.init(gpa));
    defer environ.deinit();
    var cli_backend: cli.Cli = .{ .environ = &environ };
    const cb = cli_backend.backend();
    const cli_clone = try std.fs.path.join(arena, &.{ root, "clones", "cli" });
    try cb.ensureClone(gpa, io, cli_clone, remote, .{});
    try tmp.dir.createDirPath(io, "dest_cli");
    const dest_cli = try std.fs.path.join(arena, &.{ root, "dest_cli" });
    try cb.materialise(gpa, io, cli_clone, tree, dest_cli);

    const want = try describeTree(arena, io, dest_cli);
    const got = try describeTree(arena, io, dest_lib);
    // Landmark: an empty-vs-empty comparison would pass. The fixture has
    // fourteen entries; assert the description is non-trivial and carries one
    // line of each kind before believing that they match.
    try testing.expect(std.mem.count(u8, want, "\n") >= 12);
    try testing.expect(std.mem.indexOf(u8, want, "\nd sub") != null);
    try testing.expect(std.mem.indexOf(u8, want, "l link.md -> README.md") != null);
    try testing.expect(std.mem.indexOf(u8, want, "f 755 ") != null);
    try testing.expectEqualStrings(want, got);
}

test "a tree with a submodule is refused, not mis-hashed" {
    if (!enabled) return error.SkipZigTest;

    const gpa = testing.allocator;
    const io = testing.io;
    const cli = @import("cli.zig");
    if (!cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const inner = try std.fs.path.join(arena, &.{ root, "inner" });
    try tmp.dir.createDirPath(io, "inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "inner/a.txt", .data = "a\n" });
    try cli.fixtureGit(gpa, io, inner, &.{ "init", "--quiet", "--initial-branch=main" });
    try cli.fixtureGit(gpa, io, inner, &.{ "add", "-A" });
    try cli.fixtureGit(gpa, io, inner, &.{ "commit", "--quiet", "-m", "inner" });

    const outer = try std.fs.path.join(arena, &.{ root, "outer" });
    try tmp.dir.createDirPath(io, "outer");
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/top.txt", .data = "top\n" });
    try cli.fixtureGit(gpa, io, outer, &.{ "init", "--quiet", "--initial-branch=main" });
    try cli.fixtureGit(gpa, io, outer, &.{ "add", "-A" });
    try cli.fixtureGit(gpa, io, outer, &.{ "commit", "--quiet", "-m", "outer" });
    cli.fixtureGit(gpa, io, outer, &.{
        "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", inner, "vendor",
    }) catch return error.SkipZigTest; // some git builds refuse local submodules outright
    try cli.fixtureGit(gpa, io, outer, &.{ "commit", "--quiet", "-m", "add submodule" });

    var lib = try Lib.init(gpa, io, .{});
    defer lib.deinit();
    const b = lib.backend();

    const clone = try std.fs.path.join(arena, &.{ root, "clone" });
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{outer});
    try b.ensureClone(gpa, io, clone, remote, .{});

    const rev = (try b.resolveRev(gpa, io, clone, "main")).?;
    const tree = try b.treeOf(gpa, io, clone, &std.fmt.bytesToHex(rev.commit.bytes, .lower), null);

    try tmp.dir.createDirPath(io, "dest");
    const dest = try std.fs.path.join(arena, &.{ root, "dest" });

    // A gitlink is part of the tree hash and cannot come from a working tree,
    // so it is named rather than skipped -- skipping it would surface several
    // steps later as an unexplained TreeHashMismatch.
    try testing.expectError(error.SubmodulePresent, b.materialise(gpa, io, clone, tree, dest));

    // And the refusal came from the first pass: nothing was written, not even
    // the `top.txt` that sorts before `vendor`.
    var dest_dir = try tmp.dir.openDir(io, "dest", .{ .iterate = true });
    defer dest_dir.close(io);
    var it = dest_dir.iterate();
    try testing.expect(try it.next(io) == null);
}
