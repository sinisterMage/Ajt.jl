//! What Ajt needs from a git repository, and nothing more.
//!
//! ## Why there is a vtable here at all
//!
//! Two backends, and the split is a sequencing device rather than a taste for
//! abstraction. `cli.zig` shells out to `git` — which is exactly Pkg's own
//! `JULIA_PKG_USE_CLI_GIT=1` path (`GitTools.jl:13`, `:106-113`, `:172-183`),
//! i.e. a configuration Julia already supports rather than a workaround — and
//! it needs no C at all. So every call site, every manifest shape and every
//! differential gate below can be written and kept green against `cli` while
//! the libgit2 build is still being debugged, and `cli` stays afterwards as
//! the escape hatch and as the only answer for SSH.
//!
//! ## The surface is deliberately small
//!
//! Seven operations, chosen to be exactly what `handle_repo_add!`
//! (`Types.jl:928-1050`) and `install_git` (`Operations.jl:830-880`) do, in
//! their order:
//!
//!   ensureClone → defaultRev → fetch → resolveRev → treeOf → materialise
//!
//! For a PACKAGE that is the whole surface: no commit graph, no working tree,
//! no index, no diff and no branch, because Pkg never needs one there.
//!
//! ## …except for a registry, where Pkg does need a working tree
//!
//! A registry may be a git CLONE — `~/.julia/registries/General/` with a
//! `.git` in it — and `Registry.update` maintains it as a checked-out branch,
//! not as an object store (`Registry.jl:501-560`). That branch refuses to run
//! on a dirty worktree or a detached HEAD, insists on an `origin` remote,
//! fetches one branch by name, and then fast-forwards or rebases. Six more
//! operations, each of them one line of Pkg:
//!
//!   isDirty · headBranch · remoteUrl · cloneWorking · fastForward · rebase
//!
//! They are here rather than open-coded in `ops/` for the same reason as the
//! first six: `cli.zig` and the coming libgit2 backend have to answer them
//! identically, and a question asked in two places is a question two backends
//! can answer two ways.
//!
//! ## What materialise must guarantee, whichever backend runs
//!
//! The caller hands over an EMPTY staging directory and gets back a tree whose
//! `julia/treehash.zig:hashPath` equals the requested `TreeId`. That is a hard
//! postcondition, not a hope, and it is why `materialise` is specified as
//! "write the raw blob bytes" rather than "check out":
//!
//!   * A `.gitattributes` carrying `* text=auto` makes `git checkout` (and
//!     `git_checkout_tree`) rewrite line endings, so the resulting directory
//!     does **not** hash to the tree it came from. Pkg has this latent —
//!     `checkout_tree_to_path` passes only `CHECKOUT_FORCE`
//!     (`GitTools.jl:83-91`) and never re-verifies — and gets away with it
//!     because `core.autocrlf` is false on Linux. The depot slug is
//!     `versionSlug(uuid, tree_hash)`, so inheriting it would name a directory
//!     by a hash its contents do not have.
//!   * A submodule (`gitlink`, mode `0o160000`) is part of the tree hash but
//!     cannot be reproduced from a working tree at all. It is reported as
//!     `error.SubmodulePresent`, never silently skipped into a wrong hash.
//!
//! `cli.zig` gets this from `git archive`, which applies export filters but
//! not checkout filters; the libgit2 backend will get it from walking the tree
//! and writing blobs. Both are verified by the caller re-hashing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const slug = @import("../julia/slug.zig");
const jenv = @import("../julia/env.zig");

pub const url = @import("url.zig");
pub const auth = @import("auth.zig");

/// A git object id. Reuses the depot's SHA-1 type rather than defining a
/// second one, because a `TreeId` from here is compared directly against a
/// manifest's `git-tree-sha1`.
pub const Sha1 = slug.Sha1;
pub const TreeId = Sha1;
pub const Commit = Sha1;

pub const Error = error{
    /// `ssh://`, `git+ssh://` or `git@host:path`. Refused before any backend
    /// sees it; see `url.classify`.
    SshUnsupported,
    /// `<transport>::<address>` — git's remote-helper syntax, which runs
    /// `git-remote-<transport>` as a child process. Refused before any backend
    /// sees it; see `url.Kind.supported` for why this is a security boundary
    /// and not a capability gap.
    TransportHelperUnsupported,
    /// The path exists but is not a repository.
    NotAGitRepo,
    CloneFailed,
    FetchFailed,
    /// "Did not find rev $rev in repository" (`Types.jl:1009`).
    RevNotFound,
    /// "Did not find subdirectory `$subdir`" (`Types.jl:1029`).
    SubdirNotFound,
    /// `install_git`'s "git object could not be found" — the tree hash a
    /// manifest names is not in the repository, even after a full fetch.
    ObjectNotFound,
    /// The object resolved, but is not a tree ("should be a tree, not …",
    /// `Operations.jl:866`).
    NotATree,
    /// The materialised bytes do not hash to the tree that was asked for.
    /// Ajt's own check; Pkg does not make it.
    TreeHashMismatch,
    /// The tree contains a submodule. See the module header.
    SubmodulePresent,
    /// `registry update` on a git-cloned registry refuses these three
    /// (`Registry.jl:511-520`). Pkg collects them into an `errors` vector and
    /// `@error`s the lot at the end — "registry dirty", "registry detached",
    /// "origin not in the list of remotes" — rather than raising, because it
    /// is updating every registry in the depot and one bad one must not stop
    /// the rest. Ajt updates one registry per call, so they are errors.
    DirtyWorktree,
    DetachedHead,
    NoOriginRemote,
    /// The fetched branch could neither be fast-forwarded onto nor rebased
    /// against (`Registry.jl:552-558`). The worktree is left as git left it.
    MergeFailed,
    /// The selected backend cannot run: no `git` on PATH for `cli`, or a
    /// binary built without `-Dgit` for `lib`.
    BackendUnavailable,
    /// The backend does not implement this operation.
    Unsupported,
} || Allocator.Error || Io.Cancelable;

/// `Pkg.Types.refspecs` (`Types.jl:746`) — branches only, into a `cache/`
/// namespace of Pkg's own invention so a fetched head cannot be confused with
/// a local one.
pub const refspecs_heads = "+refs/heads/*:refs/remotes/cache/heads/*";

/// `Pkg.Types.refspecs_fallback` (`Types.jl:747`) — everything, used only when
/// the branch-only fetch failed to produce the rev (`Types.jl:1004-1006`). It
/// is the second attempt rather than the first because it also drags every tag
/// and every pull-request ref on a large repository.
pub const refspecs_all = "+refs/*:refs/remotes/cache/*";

/// What `get_object_or_branch` returns (`Types.jl:1095-1120`).
pub const Rev = struct {
    commit: Commit,
    /// True when the rev resolved through a BRANCH ref rather than as an
    /// object. Load-bearing: an unpinned branch is re-fetched before its tree
    /// is taken, so that `add` on a branch tracks the branch (`Types.jl:1016-1020`).
    is_branch: bool,
};

/// `GitTools.ensure_clone`'s keyword arguments, as far as Ajt uses them.
pub const CloneOptions = struct {
    /// `isbare = true` is `handle_repo_add!`'s cache clone (`Types.jl:988`):
    /// `clones/<hash(url)>` holds objects and refs and nothing else.
    ///
    /// `handle_repo_develop!` clones with the DEFAULT (`Types.jl:838`, no
    /// `isbare`), because its clone becomes `<depot>/dev/<Name>` — a directory
    /// a human is expected to `cd` into, edit and commit from. A bare one has
    /// no working tree at all, so `resolve_projectfile!` would not even find a
    /// `Project.toml` in it.
    bare: bool = true,
};

pub const Which = enum { cli, lib };

/// The operations, as a vtable. `ctx` is the backend's own state.
///
/// Every method takes `gpa` for scratch it frees itself and `arena` for
/// anything it returns, matching the convention in `ops/`.
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    which: Which,

    pub const VTable = struct {
        /// `GitTools.ensure_clone` (`GitTools.jl:74-80`): open `path` if it is
        /// already a repository, otherwise clone `url` into it. Idempotent —
        /// this is normally a cache directory that may already exist.
        ensureClone: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, options: CloneOptions) Error!void,

        /// The rev to use when the caller named none:
        /// `LibGit2.isattached(repo) ? LibGit2.branch(repo) :
        /// string(LibGit2.GitHash(LibGit2.head(repo)))` (`Types.jl:996-999`).
        ///
        /// Two different KINDS of answer come back through one string, and
        /// that is Pkg's design, not a shortcut: a branch NAME when the clone's
        /// HEAD is a symbolic ref (the normal case — `add`ing a repo with no
        /// `#rev` tracks its default branch), and a bare commit sha when it is
        /// detached. Whichever it is, it becomes `pkg.repo.rev` and is written
        /// to the manifest as `repo-rev`, so the distinction is visible in the
        /// file and is exactly what a later `resolveRev` is handed back.
        ///
        /// Arena for the result, `gpa` for scratch — the one method here that
        /// returns memory.
        defaultRev: *const fn (ctx: *anyopaque, gpa: Allocator, arena: Allocator, io: Io, path: []const u8) Error![]const u8,

        /// `GitTools.fetch` (`GitTools.jl:147-186`) with one refspec.
        fetch: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, refspec: []const u8) Error!void,

        /// `get_object_or_branch` (`Types.jl:1095-1120`), probing in its exact
        /// order. Null — not an error — when the rev is simply not present
        /// yet, because the caller's next move is to fetch and retry.
        resolveRev: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, rev: []const u8) Error!?Rev,

        /// Peel a commit to its tree, then descend into `subdir` if given
        /// (`Types.jl:1023-1030`).
        treeOf: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, object: []const u8, subdir: ?[]const u8) Error!TreeId,

        /// Is this object id present locally? `install_git` uses it to decide
        /// whether a fetch is needed at all (`Operations.jl:850-860`).
        hasObject: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, id: Sha1) Error!bool,

        /// Write `tree` into `dest`, which the caller has created and which
        /// must be empty. See the module header for the postcondition.
        materialise: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, tree: TreeId, dest: []const u8) Error!void,

        /// `GitTools.clone(io, url, path)` with its default `isbare = false`
        /// (`GitTools.jl:92-140`): a clone WITH a working tree, which is what
        /// a registry is (`Registry.jl:260-262`). Distinct from `ensureClone`,
        /// which is bare and idempotent because `clones/` is a cache; this one
        /// is neither — `git clone` refuses a non-empty destination, and Pkg
        /// asserts the same (`GitTools.jl:94`).
        cloneWorking: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8) Error!void,

        /// `LibGit2.isdirty(repo)` (`Registry.jl:511`), which is
        /// `isdiff(repo, "HEAD"; cached = false)` — the HEAD tree against the
        /// working directory. UNTRACKED files are not dirty: libgit2's
        /// `diff_tree_to_workdir` does not set `INCLUDE_UNTRACKED`, so a
        /// stray file somebody dropped in `registries/General/` does not block
        /// an update, and neither backend may make it do so.
        isDirty: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8) Error!bool,

        /// `LibGit2.headname(repo)` (`Registry.jl:521`), or null when HEAD is
        /// detached — which is `!LibGit2.isattached(repo)` (`:515`), the check
        /// immediately before it. One call answers both because they are the
        /// same question: an attached HEAD is a symbolic ref to a branch.
        headBranch: *const fn (ctx: *anyopaque, gpa: Allocator, arena: Allocator, io: Io, path: []const u8) Error!?[]const u8,

        /// The URL of a named remote, or null when there is no such remote —
        /// `"origin" in LibGit2.remotes(repo)` (`:517`) and the
        /// `LibGit2.url(remote)` that `GitTools.fetch` reads when it is given
        /// no explicit `remoteurl` (`GitTools.jl:148-152`), in one call.
        remoteUrl: *const fn (ctx: *anyopaque, gpa: Allocator, arena: Allocator, io: Io, path: []const u8, remote: []const u8) Error!?[]const u8,

        /// `LibGit2.merge!(repo; branch, fastforward = true)`
        /// (`Registry.jl:526-528`). False — not an error — when the merge
        /// would not be a fast-forward, because Pkg's next move is to rebase
        /// (`:551-558`).
        fastForward: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, branch: []const u8) Error!bool,

        /// `LibGit2.rebase!(repo, upstream)` (`Registry.jl:553`), the fallback
        /// when the fast-forward did not apply. `error.MergeFailed` where Pkg
        /// records "registry failed to rebase on origin/$branch".
        rebase: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, upstream: []const u8) Error!void,
    };

    pub fn ensureClone(
        self: Backend,
        gpa: Allocator,
        io: Io,
        path: []const u8,
        remote: []const u8,
        options: CloneOptions,
    ) Error!void {
        try checkRemote(remote);
        return self.vtable.ensureClone(self.ctx, gpa, io, path, remote, options);
    }

    pub fn defaultRev(self: Backend, gpa: Allocator, arena: Allocator, io: Io, path: []const u8) Error![]const u8 {
        return self.vtable.defaultRev(self.ctx, gpa, arena, io, path);
    }

    pub fn fetch(self: Backend, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, refspec: []const u8) Error!void {
        try checkRemote(remote);
        return self.vtable.fetch(self.ctx, gpa, io, path, remote, refspec);
    }

    pub fn resolveRev(self: Backend, gpa: Allocator, io: Io, path: []const u8, rev: []const u8) Error!?Rev {
        return self.vtable.resolveRev(self.ctx, gpa, io, path, rev);
    }

    pub fn treeOf(self: Backend, gpa: Allocator, io: Io, path: []const u8, object: []const u8, subdir: ?[]const u8) Error!TreeId {
        return self.vtable.treeOf(self.ctx, gpa, io, path, object, subdir);
    }

    pub fn hasObject(self: Backend, gpa: Allocator, io: Io, path: []const u8, id: Sha1) Error!bool {
        return self.vtable.hasObject(self.ctx, gpa, io, path, id);
    }

    pub fn materialise(self: Backend, gpa: Allocator, io: Io, path: []const u8, tree: TreeId, dest: []const u8) Error!void {
        return self.vtable.materialise(self.ctx, gpa, io, path, tree, dest);
    }

    pub fn cloneWorking(self: Backend, gpa: Allocator, io: Io, path: []const u8, remote: []const u8) Error!void {
        try checkRemote(remote);
        return self.vtable.cloneWorking(self.ctx, gpa, io, path, remote);
    }

    pub fn isDirty(self: Backend, gpa: Allocator, io: Io, path: []const u8) Error!bool {
        return self.vtable.isDirty(self.ctx, gpa, io, path);
    }

    pub fn headBranch(self: Backend, gpa: Allocator, arena: Allocator, io: Io, path: []const u8) Error!?[]const u8 {
        return self.vtable.headBranch(self.ctx, gpa, arena, io, path);
    }

    pub fn remoteUrl(self: Backend, gpa: Allocator, arena: Allocator, io: Io, path: []const u8, remote: []const u8) Error!?[]const u8 {
        return self.vtable.remoteUrl(self.ctx, gpa, arena, io, path, remote);
    }

    pub fn fastForward(self: Backend, gpa: Allocator, io: Io, path: []const u8, branch: []const u8) Error!bool {
        return self.vtable.fastForward(self.ctx, gpa, io, path, branch);
    }

    pub fn rebase(self: Backend, gpa: Allocator, io: Io, path: []const u8, upstream: []const u8) Error!void {
        return self.vtable.rebase(self.ctx, gpa, io, path, upstream);
    }

    /// The one gate every remote passes through before a backend sees it.
    ///
    /// It lives on the wrapper rather than in each backend because a remote is
    /// **untrusted input**: it comes out of a `[sources]` table in a
    /// `Project.toml` that arrived with a repository somebody cloned, and
    /// `ops/resolve.zig` hands it to `git clone` before the solve runs. A check
    /// duplicated per backend is a check one backend will be missing.
    fn checkRemote(remote: []const u8) Error!void {
        return switch (url.classify(remote)) {
            .ssh => error.SshUnsupported,
            .helper => error.TransportHelperUnsupported,
            else => {},
        };
    }
};

/// `"+refs/heads/$branch:refs/remotes/origin/$branch"` — the refspec
/// `Registry.update` fetches a git-cloned registry with (`Registry.jl:522`).
///
/// **Not `refspecs_heads`.** Two differences, both load-bearing. It names ONE
/// branch, so a registry with a thousand tags and branches costs one ref; and
/// it lands in `refs/remotes/origin/`, which is where the `merge!`/`rebase!`
/// on the next lines look — Pkg's private `refs/remotes/cache/` namespace is
/// for package clones, and fetching into it here would leave
/// `origin/$branch` untouched and every update a silent no-op.
pub fn registryRefspec(arena: Allocator, branch: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "+refs/heads/{s}:refs/remotes/origin/{s}", .{ branch, branch });
}

/// The message a user sees when they hand Ajt an SSH URL.
///
/// Written out rather than left to libgit2, which without `GIT_SSH` says only
/// *"Unsupported URL protocol"* — true, unactionable, and indistinguishable
/// from a typo in the scheme. Both alternatives named here are real: the https
/// form of the same repository, and Pkg's own `JULIA_PKG_USE_CLI_GIT`, which
/// this binary honours (`cli.zig`) and which does support ssh because the
/// system `git` does.
pub const ssh_unsupported_message =
    \\this build of ajt has no SSH transport.
    \\  Use the https:// form of the same repository, or set AJT_GIT_BACKEND=cli
    \\  (or JULIA_PKG_USE_CLI_GIT=1) with `git` installed, which supports ssh.
;

/// The message for a `<transport>::<address>` remote.
///
/// Deliberately says WHY rather than "unsupported": this one is a refusal, not
/// a capability gap, and a user who reaches it with a hand-written url deserves
/// to know that the string they pasted is a command line. Note the absence of
/// any "set X to allow it" escape hatch — there is no configuration under which
/// running a helper on behalf of a `Project.toml` is the right behaviour, and
/// offering one would be offering the vulnerability back.
pub const transport_helper_message =
    \\`<transport>::…` is git's remote-HELPER syntax, which runs
    \\  git-remote-<transport> as a program — `ext::` in particular takes a shell
    \\  command line. ajt refuses it: a [sources] url arrives with somebody
    \\  else's repository, and resolving one must not run their code. Use a
    \\  plain https://, git:// or file:// url, or a path to a local clone.
;

/// Which backend to use: `AJT_GIT_BACKEND=cli|lib`, else Pkg's own
/// `JULIA_PKG_USE_CLI_GIT` (`GitTools.jl:13`, read through
/// `Base.get_bool_env`), else the default.
///
/// Honouring `JULIA_PKG_USE_CLI_GIT` matters beyond politeness: somebody who
/// set it did so because libgit2 does not work on their machine — a corporate
/// TLS-inspecting proxy, an ssh-agent setup, a credential helper — and every
/// one of those reasons applies to Ajt's libgit2 just as much as to Pkg's.
pub fn selectFromEnv(ajt_backend: ?[]const u8, julia_use_cli_git: ?[]const u8, default: Which) Which {
    if (ajt_backend) |v| {
        if (std.ascii.eqlIgnoreCase(v, "cli")) return .cli;
        if (std.ascii.eqlIgnoreCase(v, "lib")) return .lib;
    }
    if (boolEnv(julia_use_cli_git)) return .cli;
    return default;
}

/// `Base.get_bool_env(name, false)` through the one table
/// (`julia/env.zig`), collapsing its two non-true answers into one.
///
/// This used to carry a five-string list of its own, missing every
/// Capitalized and UPPERCASE spelling Base accepts (`base/env.jl:117-122`), so
/// `JULIA_PKG_USE_CLI_GIT=TRUE` selected libgit2 where Pkg selects the CLI —
/// on exactly the machines where somebody set that variable because libgit2
/// does not work.
///
/// Unlike the other two readers of this table, an unrecognised value is
/// `false` rather than an error: `selectFromEnv` returns a `Which` and has no
/// error channel, and a typo here should degrade to the default backend, not
/// break `instantiate`. `GitTools.jl:13` reads it as
/// `Base.get_bool_env(..., false) === true`, which is the same collapse.
fn boolEnv(v: ?[]const u8) bool {
    return jenv.getBool(v, false) catch false;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a registry fetches ONE branch, into origin/ rather than cache/" {
    // `refspecs = ["+refs/heads/$branch:refs/remotes/origin/$branch"]`
    // (`Registry.jl:522`). The destination is the half that breaks silently:
    // the `merge!` on the next line names `refs/remotes/origin/$branch`, so
    // fetching into Pkg's `cache/` namespace instead would update nothing and
    // report success.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "+refs/heads/master:refs/remotes/origin/master",
        try registryRefspec(arena_state.allocator(), "master"),
    );
    try testing.expect(std.mem.indexOf(u8, refspecs_heads, "origin") == null);
}

test "the two refspecs are Pkg's, verbatim" {
    // These strings are the wire protocol between Ajt and every git server it
    // will ever talk to, and `remotes/cache/heads/<rev>` is the FIRST thing
    // `resolveRev` probes. Getting a character wrong here makes every branch
    // rev resolve as a non-branch, which silently disables the re-fetch of an
    // unpinned branch.
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/cache/heads/*", refspecs_heads);
    try testing.expectEqualStrings("+refs/*:refs/remotes/cache/*", refspecs_all);
}

test "backend selection prefers AJT_GIT_BACKEND, then Pkg's own variable" {
    try testing.expectEqual(Which.lib, selectFromEnv(null, null, .lib));
    try testing.expectEqual(Which.cli, selectFromEnv(null, null, .cli));

    try testing.expectEqual(Which.cli, selectFromEnv("cli", null, .lib));
    try testing.expectEqual(Which.lib, selectFromEnv("lib", null, .cli));
    try testing.expectEqual(Which.cli, selectFromEnv("CLI", null, .lib));

    // Pkg's variable, honoured because whoever set it had a reason that
    // applies to Ajt's libgit2 too.
    try testing.expectEqual(Which.cli, selectFromEnv(null, "true", .lib));
    try testing.expectEqual(Which.cli, selectFromEnv(null, "1", .lib));
    try testing.expectEqual(Which.lib, selectFromEnv(null, "false", .lib));
    // `Base.get_bool_env` accepts no other spellings; "on" is not one of them.
    try testing.expectEqual(Which.lib, selectFromEnv(null, "on", .lib));
    try testing.expectEqual(Which.lib, selectFromEnv(null, "", .lib));

    // An explicit AJT_GIT_BACKEND wins over it, including in the direction
    // that turns the CLI back off.
    try testing.expectEqual(Which.lib, selectFromEnv("lib", "true", .cli));
    // ...and an unrecognised value falls through rather than erroring, so a
    // typo degrades to the default instead of breaking `instantiate`.
    try testing.expectEqual(Which.cli, selectFromEnv("libgit2", "true", .lib));
}
