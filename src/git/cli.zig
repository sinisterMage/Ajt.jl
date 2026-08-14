//! The `git` subprocess backend.
//!
//! This is Pkg's own `JULIA_PKG_USE_CLI_GIT=1` path (`GitTools.jl:13`,
//! `:106-113`, `:172-183`) — a configuration Julia supports and documents, not
//! a workaround — so a user who ends up here is in a state Pkg understands.
//! It exists for three reasons, in order of importance:
//!
//!  1. **It makes everything downstream landable before any C exists.** The
//!     call sites, the manifest shapes and the differential gates can all be
//!     written and kept green against this backend while libgit2 is built.
//!  2. **It is the escape hatch.** Corporate TLS interception, credential
//!     helpers, ssh-agent — every reason somebody sets `JULIA_PKG_USE_CLI_GIT`
//!     for Pkg applies to Ajt's libgit2 identically.
//!  3. **It is the only answer for SSH**, which the libgit2 build deliberately
//!     omits (`GIT_SSH` unset, no libssh2).
//!
//! ## Three decisions worth stating
//!
//! **`std.process.run`, not a long-lived `Child` with pipes.** Same reasoning
//! as `ops/precompile.zig:138-142`: `run` is the only form that reads stdout
//! and stderr concurrently, and a `Child` with two pipes read in sequence
//! deadlocks the moment `git` writes more than a pipe buffer of progress. Git
//! is quite capable of that.
//!
//! **`materialise` goes through `git archive` with attributes disabled.**
//! `git checkout` is out because `.gitattributes` can rewrite the bytes it
//! writes, producing a directory that does not hash to the tree it came from
//! (see `git.zig`'s header). But `git archive` **is not filter-free either** —
//! that was measured, after assuming otherwise:
//!
//! | `.gitattributes`      | blob in git | `git archive` output |
//! |-----------------------|-------------|----------------------|
//! | `* text eol=crlf`     | `one\n`     | `one\r\n`            |
//! | `f export-ignore`     | present     | **file omitted**     |
//! | `f export-subst`      | `$Format:%H$` | expanded to a sha  |
//!
//! `--attr-source=<empty-tree>` does not help and neither does
//! `core.attributesFile`, which sits at a LOWER precedence than an in-tree
//! `.gitattributes`. What does work is `$GIT_DIR/info/attributes`, which
//! gitattributes(5) gives the **highest** precedence of all: writing
//! `* -text -eol -diff -filter -export-ignore -export-subst` into the cache
//! clone turns every one of those off, and `archive` then emits raw blob
//! bytes. `ensureClone` writes it; `materialise` depends on it.
//!
//! The caller re-hashes regardless, so the failure mode without this was loud
//! (`TreeHashMismatch`) rather than silent — but it would have made any
//! package with an `eol` or `export-ignore` attribute uninstallable.
//!
//! **The environment is built, not inherited.** `GIT_TERMINAL_PROMPT=0` and
//! `GIT_ASKPASS`/`SSH_ASKPASS` cleared, because the one failure mode a package
//! manager may not have is a child process blocking on a TTY read inside
//! `instantiate`. `GIT_CONFIG_NOSYSTEM` is deliberately NOT set: a user's
//! `insteadOf` rules and credential helpers are exactly what they chose this
//! backend for.
//!
//! ## What it does not do
//!
//! No progress reporting. Pkg draws a `MiniProgressBar` from libgit2's
//! transfer callback; the CLI path in Pkg does not either (`GitTools.jl:108`
//! pipes stdout to `devnull`), so this matches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const git = @import("git.zig");
const Error = git.Error;
const Sha1 = git.Sha1;

/// Output caps. A `git` that produces more than this is malfunctioning, and
/// the alternative to a cap is an unbounded allocation driven by a remote.
const max_stdout = 16 * 1024 * 1024;
const max_stderr = 1 * 1024 * 1024;

pub const Cli = struct {
    /// What `git` is called when nobody says otherwise. Named so the free
    /// functions here (`available`, `configGet`) and the struct agree.
    pub const default_program = "git";

    /// The program to run. Overridable so a test can point at a wrapper, and
    /// so `GIT` can be set on a host where `git` is not the name.
    program: []const u8 = default_program,
    /// Built once at init and handed to every child. See the module header.
    environ: *const std.process.Environ.Map,

    pub fn backend(self: *Cli) git.Backend {
        return .{ .ctx = self, .vtable = &vtable, .which = .cli };
    }
};

const vtable: git.Backend.VTable = .{
    .ensureClone = ensureClone,
    .defaultRev = defaultRev,
    .fetch = fetch,
    .resolveRev = resolveRev,
    .treeOf = treeOf,
    .hasObject = hasObject,
    .materialise = materialise,
    .cloneWorking = cloneWorking,
    .isDirty = isDirty,
    .headBranch = headBranch,
    .remoteUrl = remoteUrl,
    .fastForward = fastForward,
    .rebase = rebase,
};

/// The environment every `git` child should get: the caller's, minus the two
/// variables that can make a child block on a prompt.
///
/// Built rather than inherited wholesale, and inherited rather than emptied —
/// see the module header. `GIT_TERMINAL_PROMPT=0` is Pkg's own defence
/// (`Types.jl` sets it around `git` invocations); clearing `GIT_ASKPASS` and
/// `SSH_ASKPASS` closes the graphical version of the same hole, where git
/// would pop up a dialog instead of reading a TTY.
///
/// `GIT_CONFIG_NOSYSTEM` is deliberately left alone: `insteadOf` rules and
/// credential helpers are exactly what somebody choosing this backend wants.
///
/// The caller owns the result and must `deinit` it.
pub fn defaultEnviron(gpa: Allocator, parent: *const std.process.Environ.Map) Allocator.Error!std.process.Environ.Map {
    var out: std.process.Environ.Map = .init(gpa);
    errdefer out.deinit();
    var it = parent.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "GIT_ASKPASS")) continue;
        if (std.mem.eql(u8, kv.key_ptr.*, "SSH_ASKPASS")) continue;
        try out.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    try out.put("GIT_TERMINAL_PROMPT", "0");
    return out;
}

/// Is a usable `git` on PATH? Answered by running it, because "on PATH" and
/// "executable by this process" are different questions and only the second
/// one matters.
pub fn available(gpa: Allocator, io: Io, program: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ program, "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// One git config value from the levels libgit2's `git_config_open_default`
/// reads, or null when nothing sets it.
///
/// This is `LibGit2.getconfig(name, "")` — the form `Pkg.generate` uses to find
/// the package author (`Pkg/src/generate.jl:25-28`). No repository is opened
/// there, so the level set is programdata/system/XDG/global and **not** the
/// local `.git/config`; a bare `git config --get` would add the local level and
/// answer with an identity Pkg cannot see when run inside a repository that
/// overrides `user.name`.
///
/// `--global` is git's name for `$XDG_CONFIG_HOME/git/config` + `~/.gitconfig`
/// (git-config(1), "FILES"), i.e. libgit2's two upper levels with the same
/// precedence between them; `--system` is `/etc/gitconfig` underneath. Trying
/// them in that order reproduces the whole chain. Windows' programdata level is
/// unreachable from the CLI and is not modelled.
///
/// Deliberately NOT on `git.Backend`: the vtable is repository operations, and
/// forcing a future libgit2 backend to implement a call that opens no
/// repository would be modelling the wrong thing. This is a free function for
/// the same reason `available` is.
///
/// The returned slice is owned by `gpa` (pass an arena and there is nothing to
/// free). `git` being absent, or failing, is not an error — libgit2 finding no
/// key and no git existing are the same empty answer as far as `generate`'s
/// fallback chain is concerned.
pub fn configGet(
    gpa: Allocator,
    io: Io,
    program: []const u8,
    environ: ?*const std.process.Environ.Map,
    name: []const u8,
) ?[]const u8 {
    for ([_][]const u8{ "--global", "--system" }) |scope| {
        const res = std.process.run(gpa, io, .{
            .argv = &.{ program, "config", scope, "--get", name },
            .environ_map = environ,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            // A failure to SPAWN means there is no `git` at all, which is not
            // scope-specific: retrying `--system` would fork-and-fail a second
            // time to learn the same thing.
        }) catch return null;
        defer gpa.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) {
            gpa.free(res.stdout);
            continue;
        }
        // `git config --get` terminates the value with a newline that is not
        // part of it; libgit2 hands back the raw value. Nothing else is
        // trimmed — leading or trailing spaces inside a config value are real,
        // and `authors` would print them.
        const value = std.mem.trimEnd(u8, res.stdout, "\n");
        if (value.len == res.stdout.len) return res.stdout;
        const owned = gpa.dupe(u8, value) catch {
            gpa.free(res.stdout);
            return null;
        };
        gpa.free(res.stdout);
        return owned;
    }
    return null;
}

/// The environment every child gets: the caller's, plus the three variables
/// that decide whether `git` can block on a human. See the module header for
/// why `GIT_CONFIG_NOSYSTEM` is deliberately NOT among them.
///
/// `GIT_ASKPASS=""` rather than removed, because git's own ladder is
/// `GIT_ASKPASS` → `core.askpass` → `SSH_ASKPASS` → terminal, and it stops at
/// the first variable that is *set* (`prompt.c`: `askpass = getenv(...); if
/// (!askpass) askpass = askpass_program; … if (askpass && *askpass)`). An empty
/// value therefore disables the whole ladder, where removing the variable would
/// merely fall through to the next rung. `GIT_TERMINAL_PROMPT=0` then closes
/// the last one, and git exits with "terminal prompts disabled" instead of
/// waiting for a password inside `instantiate`.
///
/// **ssh's own passphrase prompt is out of reach here** and left alone on
/// purpose: the lever would be `GIT_SSH_COMMAND=ssh -oBatchMode=yes`, and
/// overriding a user's ssh invocation would break the agent and config setups
/// that are the reason this backend exists at all (module header, reason 3).
///
/// Caller owns the returned map.
pub fn childEnviron(gpa: Allocator, parent: *const std.process.Environ.Map) Allocator.Error!std.process.Environ.Map {
    var map = try parent.clone(gpa);
    errdefer map.deinit();
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_ASKPASS", "");
    try map.put("SSH_ASKPASS", "");
    return map;
}

const Output = struct {
    stdout: []u8,
    stderr: []u8,
    ok: bool,

    fn deinit(self: Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn run(self: *Cli, gpa: Allocator, io: Io, argv: []const []const u8) Error!Output {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = self.environ,
        .stdout_limit = .limited(max_stdout),
        .stderr_limit = .limited(max_stderr),
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.OutOfMemory => |e| return e,
        // FileNotFound is `git` missing; every other spawn failure is equally
        // "this backend cannot run" from the caller's point of view.
        else => return error.BackendUnavailable,
    };
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        },
    };
}

/// `git -C <path> …`. Every command is spelled with `-C` rather than by
/// changing the process's own directory: `ops/` runs work concurrently and a
/// process-global cwd is not a thing that can be shared.
fn argvIn(gpa: Allocator, self: *Cli, path: []const u8, rest: []const []const u8) Allocator.Error![][]const u8 {
    var out = try gpa.alloc([]const u8, rest.len + 3);
    out[0] = self.program;
    out[1] = "-C";
    out[2] = path;
    @memcpy(out[3..], rest);
    return out;
}

// ---------------------------------------------------------------------------

fn ensureClone(
    ctx: *anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    remote: []const u8,
    options: git.CloneOptions,
) Error!void {
    const self: *Cli = @ptrCast(@alignCast(ctx));

    // `ensure_clone` (`GitTools.jl:74-80`): if the path is already a
    // repository, that is the whole operation. `rev-parse --git-dir` is the
    // cheap, canonical test and also rejects a directory that exists but is
    // not a repo.
    if (!try isRepo(self, gpa, io, path)) {
        // `git clone --quiet [--bare] <url> <path>` (`GitTools.jl:106-113`).
        // `git clone` creates the destination itself and refuses a non-empty
        // one, which is the behaviour we want: it makes a half-finished
        // previous clone an error rather than something to fetch into. An
        // EMPTY destination it accepts, which is what lets `dev <url>` clone
        // straight into a staging directory it created itself.
        var argv: [7][]const u8 = .{ self.program, "clone", "--quiet", "--bare", "--", git.url.normalize(remote), path };
        const used: []const []const u8 = if (options.bare) argv[0..7] else blk: {
            // Drop `--bare`, keeping `--` immediately before the operands.
            argv[3] = argv[4];
            argv[4] = argv[5];
            argv[5] = argv[6];
            break :blk argv[0..6];
        };
        const out = try run(self, gpa, io, used);
        defer out.deinit(gpa);
        if (!out.ok) return error.CloneFailed;
    }
    // Unconditionally, not only after a fresh clone: an existing cache clone
    // may predate this rule, or have been created by Pkg itself.
    try ensureArchiveAttributes(self, gpa, io, path);
}

/// What makes `git archive` emit raw blob bytes. See the module header for the
/// measurements; the short version is that `.gitattributes` can rewrite line
/// endings, expand `$Format:…$`, and drop files entirely, and `archive`
/// honours all three.
const archive_attributes = "* -text -eol -diff -filter -export-ignore -export-subst\n";

/// Write `archive_attributes` into `$GIT_DIR/info/attributes`, the highest-
/// precedence attributes source there is (gitattributes(5)).
///
/// Writing into a directory Pkg may also use is safe in both directions: Pkg
/// never runs `git archive`, so the file is inert for it — and `clones/` is a
/// cache whose only contents are objects and refs, both untouched here.
///
/// The path is asked for rather than assumed. `clones/` entries are bare, so
/// it is `<path>/info/attributes`, but `rev-parse --git-path` is correct for a
/// non-bare repository too and costs one process on a path that already runs
/// several.
fn ensureArchiveAttributes(self: *Cli, gpa: Allocator, io: Io, path: []const u8) Error!void {
    const argv = try argvIn(gpa, self, path, &.{ "rev-parse", "--git-path", "info/attributes" });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return error.NotAGitRepo;

    const rel = std.mem.trim(u8, out.stdout, " \t\r\n");
    if (rel.len == 0) return error.NotAGitRepo;
    // `--git-path` answers relative to the repository, so it has to be joined
    // back onto `path` unless git already made it absolute.
    const file = if (std.fs.path.isAbsolute(rel))
        try gpa.dupe(u8, rel)
    else
        try std.fs.path.join(gpa, &.{ path, rel });
    defer gpa.free(file);

    // Already correct? Then do not write at all. Several `ajt` processes can
    // share a depot, and the cheapest way not to race is not to write.
    if (Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(4096))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, archive_attributes)) return;
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    }

    if (std.fs.path.dirname(file)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {},
        };
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = archive_attributes }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CloneFailed,
    };
}

fn isRepo(self: *Cli, gpa: Allocator, io: Io, path: []const u8) Error!bool {
    const argv = try argvIn(gpa, self, path, &.{ "rev-parse", "--git-dir" });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    return out.ok;
}

/// `LibGit2.isattached(repo) ? LibGit2.branch(repo) :
/// string(LibGit2.GitHash(LibGit2.head(repo)))` (`Types.jl:996-999`).
///
/// `symbolic-ref --short HEAD` IS `isattached` + `branch` in one command: it
/// succeeds exactly when HEAD is a symbolic ref, and prints the shorthand Pkg
/// would print. A `git clone --bare` of a remote copies the remote's HEAD, so
/// this is where the manifest's `repo-rev = "master"` comes from on a
/// `[sources]` entry that named no `rev` — the string is the BRANCH, and the
/// next `resolveRev` must therefore find it under `heads/`, not as an object.
///
/// The fallback is a detached HEAD, where Pkg records the commit itself. An
/// empty repository has neither and Pkg raises "invalid git HEAD" from
/// `check_valid_HEAD` (`GitTools.jl:345-351`); `RevNotFound` is the closest
/// thing this error set has and the caller's message names the repository.
fn defaultRev(ctx: *anyopaque, gpa: Allocator, arena: Allocator, io: Io, path: []const u8) Error![]const u8 {
    const self: *Cli = @ptrCast(@alignCast(ctx));

    {
        const argv = try argvIn(gpa, self, path, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" });
        defer gpa.free(argv);
        const out = try run(self, gpa, io, argv);
        defer out.deinit(gpa);
        if (out.ok) {
            const text = std.mem.trim(u8, out.stdout, " \t\r\n");
            if (text.len != 0) return arena.dupe(u8, text);
        }
    }

    const argv = try argvIn(gpa, self, path, &.{ "rev-parse", "--verify", "--quiet", "HEAD" });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return error.RevNotFound;
    const text = std.mem.trim(u8, out.stdout, " \t\r\n");
    if (text.len == 0) return error.RevNotFound;
    return arena.dupe(u8, text);
}

fn fetch(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8, refspec: []const u8) Error!void {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    // `git fetch -q <url> <refspec>` (`GitTools.jl:172-183`) — the URL is
    // given positionally rather than through a named remote, exactly as Pkg
    // does, so nothing is written to `.git/config` and a credential embedded
    // in the URL never reaches disk. `--` for the reason in `ensureClone`.
    const argv = try argvIn(gpa, self, path, &.{ "fetch", "-q", "--force", "--", git.url.normalize(remote), refspec });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return error.FetchFailed;
}

/// `get_object_or_branch` (`Types.jl:1095-1120`), probing in its exact order:
/// three branch namespaces, then the rev as a bare object.
///
/// The order is not cosmetic. A repository can hold both a branch `v1` and a
/// tag `v1`; Pkg resolves the branch and reports `is_branch = true`, which is
/// what makes `add Foo#v1` track the branch rather than pin the tag.
fn resolveRev(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, rev: []const u8) Error!?git.Rev {
    const self: *Cli = @ptrCast(@alignCast(ctx));

    const branch_prefixes = [_][]const u8{ "remotes/cache/heads/", "remotes/origin/", "heads/" };
    for (branch_prefixes) |prefix| {
        const spec = try std.mem.concat(gpa, u8, &.{ prefix, rev });
        defer gpa.free(spec);
        if (try revParse(self, gpa, io, path, spec)) |id| {
            return .{ .commit = id, .is_branch = true };
        }
    }
    if (try revParse(self, gpa, io, path, rev)) |id| {
        return .{ .commit = id, .is_branch = false };
    }
    return null;
}

/// `git rev-parse --verify --quiet <spec>^{}`, i.e. resolve and peel any
/// annotated-tag wrapper. Null when the spec does not resolve — that is a
/// normal answer here, not an error, because the caller's next move is to
/// fetch and try again.
fn revParse(self: *Cli, gpa: Allocator, io: Io, path: []const u8, spec: []const u8) Error!?Sha1 {
    const peeled = try std.mem.concat(gpa, u8, &.{ spec, "^{}" });
    defer gpa.free(peeled);
    const argv = try argvIn(gpa, self, path, &.{ "rev-parse", "--verify", "--quiet", peeled });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return null;
    return parseSha1(out.stdout);
}

fn parseSha1(raw: []const u8) ?Sha1 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return Sha1.parse(text) catch null;
}

fn treeOf(
    ctx: *anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    object: []const u8,
    subdir: ?[]const u8,
) Error!git.TreeId {
    const self: *Cli = @ptrCast(@alignCast(ctx));

    // `<object>^{tree}` peels a commit (or a tag, or a tree) to its tree.
    const spec = if (subdir) |d|
        // `<object>:<subdir>` names the sub-tree directly, which is what
        // `tree_hash_object[pkg.repo.subdir]` does (`Types.jl:1025`).
        try std.mem.concat(gpa, u8, &.{ object, ":", d })
    else
        try std.mem.concat(gpa, u8, &.{ object, "^{tree}" });
    defer gpa.free(spec);

    const argv = try argvIn(gpa, self, path, &.{ "rev-parse", "--verify", "--quiet", spec });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return if (subdir != null) error.SubdirNotFound else error.ObjectNotFound;

    const id = parseSha1(out.stdout) orelse return error.NotATree;
    // `<x>:<subdir>` happily resolves to a BLOB when the subdir names a file,
    // and a blob id where a tree id belongs would be written into the manifest
    // as a `git-tree-sha1` that nothing can ever materialise.
    if (subdir != null and !try isTree(self, gpa, io, path, id)) return error.NotATree;
    return id;
}

fn isTree(self: *Cli, gpa: Allocator, io: Io, path: []const u8, id: Sha1) Error!bool {
    const hex = std.fmt.bytesToHex(id.bytes, .lower);
    const argv = try argvIn(gpa, self, path, &.{ "cat-file", "-t", &hex });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return false;
    return std.mem.eql(u8, std.mem.trim(u8, out.stdout, " \t\r\n"), "tree");
}

fn hasObject(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, id: Sha1) Error!bool {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const hex = std.fmt.bytesToHex(id.bytes, .lower);
    const argv = try argvIn(gpa, self, path, &.{ "cat-file", "-e", &hex });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    return out.ok;
}

/// `git archive <tree> | tar -x -C <dest>`, run as one command through
/// `git archive --format=tar -o …`? No — as a pipe would need a second
/// process. Instead `git -C <path> archive --format=tar <tree>` writes the tar
/// to stdout and it is extracted in-process by `install/extract.zig`'s reader.
///
/// See the module header for why `archive` and not `checkout`.
fn materialise(
    ctx: *anyopaque,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    tree: git.TreeId,
    dest: []const u8,
) Error!void {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const hex = std.fmt.bytesToHex(tree.bytes, .lower);

    // Submodules must be caught BEFORE anything is written: `git archive`
    // silently omits a gitlink entry, so the extracted tree would hash to
    // something other than `tree` and the failure would surface as a
    // `TreeHashMismatch` with no explanation. `ls-tree` names the real cause.
    if (try hasSubmodule(self, gpa, io, path, &hex)) return error.SubmodulePresent;

    const argv = try argvIn(gpa, self, path, &.{ "archive", "--format=tar", &hex });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return error.ObjectNotFound;

    try extractTar(gpa, io, out.stdout, dest);
}

/// Any `160000` (gitlink) entry anywhere in the tree.
fn hasSubmodule(self: *Cli, gpa: Allocator, io: Io, path: []const u8, tree_hex: []const u8) Error!bool {
    const argv = try argvIn(gpa, self, path, &.{ "ls-tree", "-r", "-t", tree_hex });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return false;
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "160000 ")) return true;
    }
    return false;
}

/// Extract a tar stream into `dest`, in two passes.
///
/// Deliberately NOT `install/extract.zig`: that module's whole contract is
/// "verify the tree hash *from the stream*, then write", and it computes the
/// hash itself. Here the hash is already known and the caller re-verifies the
/// directory afterwards with `treehash.hashPath` — a strictly stronger check,
/// because it hashes what actually landed on disk rather than what went past
/// in the stream.
///
/// The writing itself is `std.tar.extract`, which gets two things right that
/// are easy to get wrong by hand: `mode_mode = .executable_bit_only` (the
/// executable bit is the only mode bit git records, and it IS part of the tree
/// hash), and `sanitizePath`, which refuses an absolute path and any `..` that
/// would climb above the root.
///
/// The pre-pass exists because `sanitizePath` **normalises** an interior `..`
/// rather than refusing it (`a/../b` is written as `b`), and because it does
/// not know about the symlink-prefix attack: a tar declaring `link -> ..`
/// followed by `link/x` writes outside `dest` through a path every individual
/// component of which looks fine. `install/extract.zig`'s `PathGuard` exists
/// for exactly this and states the rule; this restates it rather than sharing
/// it, because that module's guard is wired into its own hashing walk.
///
/// `git archive` produces none of these. That is not a reason to skip the
/// check — the bytes came from a remote repository, and "the tool that wrote
/// this tar was well behaved" is not a property an extractor may assume.
fn extractTar(gpa: Allocator, io: Io, tar_bytes: []const u8, dest: []const u8) Error!void {
    try scanTarPaths(gpa, tar_bytes);

    var dir = Io.Dir.cwd().openDir(io, dest, .{}) catch return error.CloneFailed;
    defer dir.close(io);

    var reader: Io.Reader = .fixed(tar_bytes);
    std.tar.extract(io, dir, &reader, .{
        .mode_mode = .executable_bit_only,
        // Empty directories are not representable in a git tree, so a tar
        // from `git archive` never contains one. Keeping them would be
        // harmless; excluding them keeps the on-disk tree exactly what
        // `treehash.hashPath` will walk.
        .exclude_empty_directories = true,
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.OutOfMemory => |e| return e,
        else => return error.CloneFailed,
    };
}

/// Reject unsafe names before a single byte is written.
fn scanTarPaths(gpa: Allocator, tar_bytes: []const u8) Error!void {
    var reader: Io.Reader = .fixed(tar_bytes);
    var file_name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    // Every symlink seen so far, so a later entry cannot be nested under one.
    var links: std.ArrayList([]const u8) = .empty;
    defer {
        for (links.items) |l| gpa.free(l);
        links.deinit(gpa);
    }

    while (it.next() catch return error.CloneFailed) |entry| {
        if (!safeRelPath(entry.name)) return error.CloneFailed;
        for (links.items) |l| {
            if (isUnder(entry.name, l)) return error.CloneFailed;
        }
        if (entry.kind == .sym_link) {
            // A symlink may legitimately point outside the tree — Julia
            // packages do it, and the tree hash records the target text, not
            // its destination. What must not happen is anything being written
            // THROUGH it, which the prefix check above prevents.
            try links.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
}

/// Is `name` inside the directory `prefix`? Component-wise, so `abc` is not
/// treated as being under `ab`.
fn isUnder(name: []const u8, prefix: []const u8) bool {
    if (name.len <= prefix.len) return false;
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    return name[prefix.len] == '/';
}

/// Reject anything that could escape `dest` on its own: an empty name, an
/// absolute path, any `..` component, or a Windows drive/UNC prefix.
///
/// Stricter than `sanitizePath`, deliberately. It normalises `a/../b` to `b`;
/// here that is refused outright, because a normalised path produces a
/// directory whose contents no longer hash to the tree they came from — a
/// confusing `TreeHashMismatch` several steps downstream instead of a clear
/// refusal here.
fn safeRelPath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    if (name.len >= 2 and name[1] == ':') return false;
    var it = std.mem.splitAny(u8, name, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// The registry half: a clone with a working tree, maintained as a branch.
// ---------------------------------------------------------------------------

/// `git clone --quiet <url> <path>` — the CLI branch of `GitTools.clone`
/// (`GitTools.jl:106-113`) with `isbare` false, i.e. without the `--bare` that
/// `ensureClone` passes.
///
/// Not idempotent, deliberately: `git clone` refuses a destination that exists
/// and is non-empty, and Pkg asserts the same before calling it
/// (`GitTools.jl:94`). A registry is published by renaming a freshly cloned
/// staging directory into place, so "clone into something already there" is
/// always a bug rather than a cache hit.
fn cloneWorking(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, remote: []const u8) Error!void {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const out = try run(self, gpa, io, &.{
        self.program, "clone", "--quiet", git.url.normalize(remote), path,
    });
    defer out.deinit(gpa);
    if (!out.ok) return error.CloneFailed;
}

/// `LibGit2.isdirty(repo)` (`Registry.jl:511`).
///
/// `--untracked-files=no` is the whole point: `isdirty` is
/// `isdiff(repo, "HEAD"; cached = false)`, which is libgit2's
/// `diff_tree_to_workdir` WITHOUT `GIT_DIFF_INCLUDE_UNTRACKED`. Leaving the
/// flag off would make an unrelated file somebody dropped into
/// `registries/General/` — an editor backup, a `.DS_Store` — refuse every
/// future update, where Pkg updates happily.
///
/// A non-zero exit is a broken repository, not a dirty one, and must not be
/// reported as "registry dirty": that message tells a user to go clean up
/// changes they never made.
fn isDirty(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8) Error!bool {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const argv = try argvIn(gpa, self, path, &.{ "status", "--porcelain", "--untracked-files=no" });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return error.NotAGitRepo;
    return std.mem.trim(u8, out.stdout, " \t\r\n").len != 0;
}

/// `LibGit2.headname(repo)`, or null for a detached HEAD — `isattached`
/// (`Registry.jl:515`) and `headname` (`:521`) in one call.
///
/// `symbolic-ref` answers both because that IS the distinction: an attached
/// HEAD is a symbolic ref into `refs/heads/`, a detached one holds an object
/// id and `symbolic-ref` exits non-zero. `git rev-parse --abbrev-ref HEAD`
/// would be the tempting spelling and is wrong — it prints the literal string
/// `HEAD` for a detached head, which is also a legal branch name.
fn headBranch(
    ctx: *anyopaque,
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    path: []const u8,
) Error!?[]const u8 {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const argv = try argvIn(gpa, self, path, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return null;
    const name = std.mem.trim(u8, out.stdout, " \t\r\n");
    if (name.len == 0) return null;
    return try arena.dupe(u8, name);
}

/// `"origin" in LibGit2.remotes(repo)` plus the `LibGit2.url(remote)` that
/// `GitTools.fetch` reads from it (`Registry.jl:517`, `GitTools.jl:148-152`).
///
/// Null means "no such remote", which is the refusal at `Registry.jl:518`; it
/// is not an error here because the caller turns it into a specific one.
fn remoteUrl(
    ctx: *anyopaque,
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    path: []const u8,
    remote: []const u8,
) Error!?[]const u8 {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const argv = try argvIn(gpa, self, path, &.{ "remote", "get-url", remote });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (!out.ok) return null;
    const url_text = std.mem.trim(u8, out.stdout, " \t\r\n");
    if (url_text.len == 0) return null;
    return try arena.dupe(u8, url_text);
}

/// `LibGit2.merge!(repo; branch, fastforward = true)` (`Registry.jl:526-528`).
///
/// `--ff-only` is that keyword exactly: merge iff it is a fast-forward, never
/// write a merge commit. Already-up-to-date exits 0 (true), which matches
/// libgit2's `GIT_MERGE_ANALYSIS_UP_TO_DATE` path.
fn fastForward(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, branch: []const u8) Error!bool {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const argv = try argvIn(gpa, self, path, &.{ "merge", "--ff-only", "--quiet", branch });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    return out.ok;
}

/// `LibGit2.rebase!(repo, upstream)` (`Registry.jl:553`), abort included.
///
/// The abort is not defensive programming, it is the port: `rebase!` wraps its
/// loop in `catch; abort(rbs); rethrow()` (`LibGit2.jl:878-880`), so a
/// conflict leaves the worktree where it started. `git rebase` alone would
/// leave the registry sitting in an interrupted rebase, and the next
/// `ajt registry update` would fail on that instead of on the real cause.
fn rebase(ctx: *anyopaque, gpa: Allocator, io: Io, path: []const u8, upstream: []const u8) Error!void {
    const self: *Cli = @ptrCast(@alignCast(ctx));
    const argv = try argvIn(gpa, self, path, &.{ "rebase", "--quiet", upstream });
    defer gpa.free(argv);
    const out = try run(self, gpa, io, argv);
    defer out.deinit(gpa);
    if (out.ok) return;

    const abort_argv = try argvIn(gpa, self, path, &.{ "rebase", "--abort" });
    defer gpa.free(abort_argv);
    const aborted = try run(self, gpa, io, abort_argv);
    aborted.deinit(gpa);
    return error.MergeFailed;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the argv builder puts -C before the subcommand" {
    // `git -C <path> <cmd>` and `git <cmd> -C <path>` are not the same thing:
    // the second passes `-C` to the subcommand, where it means something else
    // entirely for `archive` and nothing at all for `rev-parse`.
    const gpa = testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli: Cli = .{ .environ = &environ };

    const argv = try argvIn(gpa, &cli, "/d/clones/1", &.{ "rev-parse", "--git-dir" });
    defer gpa.free(argv);
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings("git", argv[0]);
    try testing.expectEqualStrings("-C", argv[1]);
    try testing.expectEqualStrings("/d/clones/1", argv[2]);
    try testing.expectEqualStrings("rev-parse", argv[3]);
}

test "safeRelPath rejects every way out of the destination" {
    try testing.expect(safeRelPath("src/Foo.jl"));
    try testing.expect(safeRelPath("a"));
    try testing.expect(safeRelPath("a/b/c.txt"));
    // A file legitimately named with a leading dot, or containing "..".
    try testing.expect(safeRelPath(".gitignore"));
    try testing.expect(safeRelPath("a..b/c"));

    try testing.expect(!safeRelPath(""));
    try testing.expect(!safeRelPath("/etc/passwd"));
    try testing.expect(!safeRelPath("\\windows\\system32"));
    try testing.expect(!safeRelPath("../escape"));
    try testing.expect(!safeRelPath("a/../../escape"));
    try testing.expect(!safeRelPath("a/../b")); // conservative: any `..` at all
    try testing.expect(!safeRelPath("a\\..\\b"));
    try testing.expect(!safeRelPath("C:/windows"));
}

test "isUnder is component-wise, so a name prefix is not a directory prefix" {
    try testing.expect(isUnder("link/x", "link"));
    try testing.expect(isUnder("a/b/c", "a/b"));
    try testing.expect(!isUnder("linkage/x", "link"));
    try testing.expect(!isUnder("link", "link"));
    try testing.expect(!isUnder("li", "link"));
    try testing.expect(!isUnder("other/x", "link"));
}

// ---------------------------------------------------------------------------
// End-to-end, against a real `git`.
//
// Skipped rather than failed when `git` is absent: this is the one module in
// Ajt whose subject is another program, and a machine without it can still run
// every other test meaningfully.
// ---------------------------------------------------------------------------

const treehash = @import("../julia/treehash.zig");

/// A `git` invocation for building the fixture. Fails the test on a non-zero
/// exit, with the child's stderr, because a fixture that half-built produces
/// assertion failures several steps away from the cause.
/// `pub` so `lib.zig`'s end-to-end test can build the same fixture repository
/// and compare the two backends' answers on it, which is the only way "the
/// backends agree" is a checked claim rather than an intention.
pub fn fixtureGit(gpa: Allocator, io: Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    // A deterministic, side-effect-free identity. `-c` rather than `git config`
    // so nothing is written, and `commit.gpgsign=false` because a developer
    // with global signing on would otherwise have every fixture commit block
    // on a passphrase prompt.
    // No PATH: `std.process.run` documents that argv[0] is resolved through the
    // PARENT environment regardless of `environ_map`, and git finds its own
    // helpers relative to its exec path rather than through PATH.
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HOME", cwd);
    try environ.put("GIT_CONFIG_NOSYSTEM", "1");
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    try environ.put("GIT_AUTHOR_NAME", "ajt");
    try environ.put("GIT_AUTHOR_EMAIL", "ajt@example.invalid");
    try environ.put("GIT_COMMITTER_NAME", "ajt");
    try environ.put("GIT_COMMITTER_EMAIL", "ajt@example.invalid");
    try environ.put("GIT_AUTHOR_DATE", "2000-01-01T00:00:00+0000");
    try environ.put("GIT_COMMITTER_DATE", "2000-01-01T00:00:00+0000");

    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("fixture `git {s}` failed ({d}): {s}\n", .{ args[0], c, res.stderr });
            return error.FixtureFailed;
        },
        else => return error.FixtureFailed,
    }
}

pub fn fixtureGitOut(gpa: Allocator, io: Io, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(res.stderr);
    errdefer gpa.free(res.stdout);
    switch (res.term) {
        .exited => |c| if (c != 0) return error.FixtureFailed,
        else => return error.FixtureFailed,
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    const owned = try gpa.dupe(u8, trimmed);
    gpa.free(res.stdout);
    return owned;
}

test "clone, resolve, tree and materialise against a real repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (!available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // --- a source repository with everything that can go wrong in a tree ----
    const src = try std.fs.path.join(arena, &.{ root, "src" });
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/README.md", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/run.sh", .data = "#!/bin/sh\necho hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/inner.jl", .data = "module Inner end\n" });
    // The three cases that decide `materialise`'s implementation. Each one is
    // an attribute that rewrites what a checkout — AND an unconfigured
    // `git archive` — puts on disk, so that the result no longer hashes to the
    // tree it came from. `$GIT_DIR/info/attributes` is what turns them off;
    // see the module header.
    //
    //   eol=crlf      blob holds `\n`, checkout/archive write `\r\n`
    //   export-ignore the file is omitted from an archive entirely
    //   export-subst  `$Format:%H$` is expanded to a commit sha
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
    // The executable bit is part of the git tree hash, so it must survive the
    // whole round trip. `Dir.setPermissions` applies to the directory itself,
    // so the file has to be opened for its own.
    {
        var f = try src_dir.openFile(io, "run.sh", .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, @enumFromInt(0o755));
    }

    try fixtureGit(gpa, io, src, &.{ "init", "--quiet", "--initial-branch=main" });
    try fixtureGit(gpa, io, src, &.{ "add", "-A" });
    try fixtureGit(gpa, io, src, &.{ "commit", "--quiet", "-m", "initial" });
    try fixtureGit(gpa, io, src, &.{ "tag", "v1.0.0" });

    const head_tree_hex = try fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(head_tree_hex);
    const sub_tree_hex = try fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD:sub" });
    defer gpa.free(sub_tree_hex);
    const head_commit_hex = try fixtureGitOut(gpa, io, src, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_commit_hex);

    // --- the backend --------------------------------------------------------
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    var cli: Cli = .{ .environ = &environ };
    const b = cli.backend();

    const clone = try std.fs.path.join(arena, &.{ root, "clones", "1" });
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{src});

    try b.ensureClone(gpa, io, clone, remote, .{});
    // Idempotent: a second call on an existing clone is a no-op, not a
    // "destination already exists" failure. `clones/` is a cache directory.
    try b.ensureClone(gpa, io, clone, remote, .{});

    // The rev `handle_repo_add!` assumes when none was given: the branch NAME,
    // because HEAD in the clone is attached (`Types.jl:996-999`). A 40-hex
    // answer here would pin the commit and stop `add Foo` tracking the branch.
    try testing.expectEqualStrings("main", try b.defaultRev(gpa, arena, io, clone));

    // --- resolveRev ---------------------------------------------------------
    // Nothing has been fetched into the `cache/` namespace yet, but `git
    // clone` set up `origin`, so the branch resolves through
    // `remotes/origin/<rev>` — the second probe in Pkg's order.
    const main_rev = (try b.resolveRev(gpa, io, clone, "main")).?;
    try testing.expect(main_rev.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(main_rev.commit.bytes, .lower));

    // A tag is NOT a branch, and must peel through the tag object to the
    // commit. `v1.0.0` here is lightweight, but the `^{}` in revParse is what
    // makes an annotated one work too.
    const tag_rev = (try b.resolveRev(gpa, io, clone, "v1.0.0")).?;
    try testing.expect(!tag_rev.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(tag_rev.commit.bytes, .lower));

    // A full sha resolves as an object.
    const sha_rev = (try b.resolveRev(gpa, io, clone, head_commit_hex)).?;
    try testing.expect(!sha_rev.is_branch);

    // A rev that is simply not here is `null`, not an error: the caller's next
    // move is to fetch and retry (`Types.jl:1000-1009`).
    try testing.expect(try b.resolveRev(gpa, io, clone, "no-such-rev") == null);

    // --- fetch --------------------------------------------------------------
    // Pkg's own refspec, into its own `remotes/cache/heads/` namespace, which
    // is then the FIRST thing resolveRev probes.
    try b.fetch(gpa, io, clone, remote, git.refspecs_heads);
    const cached = (try b.resolveRev(gpa, io, clone, "main")).?;
    try testing.expect(cached.is_branch);
    try testing.expectEqualStrings(head_commit_hex, &std.fmt.bytesToHex(cached.commit.bytes, .lower));

    // --- treeOf -------------------------------------------------------------
    const tree = try b.treeOf(gpa, io, clone, head_commit_hex, null);
    try testing.expectEqualStrings(head_tree_hex, &std.fmt.bytesToHex(tree.bytes, .lower));

    const subtree = try b.treeOf(gpa, io, clone, head_commit_hex, "sub");
    try testing.expectEqualStrings(sub_tree_hex, &std.fmt.bytesToHex(subtree.bytes, .lower));

    try testing.expectError(
        error.SubdirNotFound,
        b.treeOf(gpa, io, clone, head_commit_hex, "nope"),
    );
    // A subdir naming a FILE resolves to a blob; accepting it would write a
    // blob id into the manifest as a `git-tree-sha1`.
    try testing.expectError(
        error.NotATree,
        b.treeOf(gpa, io, clone, head_commit_hex, "README.md"),
    );

    try testing.expect(try b.hasObject(gpa, io, clone, tree));
    try testing.expect(!try b.hasObject(gpa, io, clone, try git.Sha1.parse("0" ** 40)));

    // --- materialise, and THE assertion -------------------------------------
    // What lands on disk must hash, through Ajt's own independent tree hasher,
    // to the tree that was asked for. This is what makes the depot slug
    // (`versionSlug(uuid, tree_hash)`) name content that really has that hash,
    // and it is the check Pkg does not make.
    try tmp.dir.createDirPath(io, "dest");
    const dest = try std.fs.path.join(arena, &.{ root, "dest" });
    try b.materialise(gpa, io, clone, tree, dest);

    const got = try treehash.hashPath(gpa, io, dest);
    try testing.expectEqualStrings(head_tree_hex, &std.fmt.bytesToHex(got, .lower));

    // And spot-check each property the hash depends on, so a failure above
    // says which one broke rather than just "hashes differ". Every one of
    // these is a byte that a default `git archive` would have changed.
    var dest_dir = try tmp.dir.openDir(io, "dest", .{});
    defer dest_dir.close(io);
    try testing.expectEqualStrings(
        "one\ntwo\n", // `eol=crlf` suppressed: the blob's own bytes
        try dest_dir.readFileAlloc(io, "eol.txt", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "still here\n", // `export-ignore` suppressed: the file is present
        try dest_dir.readFileAlloc(io, "ignored.txt", arena, .limited(1024)),
    );
    try testing.expectEqualStrings(
        "v=$Format:%H$\n", // `export-subst` suppressed: literal, unexpanded
        try dest_dir.readFileAlloc(io, "subst.txt", arena, .limited(1024)),
    );
    const st = try dest_dir.statFile(io, "run.sh", .{});
    try testing.expect(@intFromEnum(st.permissions) & 0o100 != 0); // still executable
    var link_buf: [256]u8 = undefined;
    const link_len = try dest_dir.readLink(io, "link.md", &link_buf);
    try testing.expectEqualStrings("README.md", link_buf[0..link_len]);

    // A subtree materialises the same way.
    try tmp.dir.createDirPath(io, "dest_sub");
    const dest_sub = try std.fs.path.join(arena, &.{ root, "dest_sub" });
    try b.materialise(gpa, io, clone, subtree, dest_sub);
    const got_sub = try treehash.hashPath(gpa, io, dest_sub);
    try testing.expectEqualStrings(sub_tree_hex, &std.fmt.bytesToHex(got_sub, .lower));
}

test "a repository with a submodule is refused, not mis-hashed" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (!available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // The inner repository that becomes the submodule.
    const inner = try std.fs.path.join(arena, &.{ root, "inner" });
    try tmp.dir.createDirPath(io, "inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "inner/a.txt", .data = "a\n" });
    try fixtureGit(gpa, io, inner, &.{ "init", "--quiet", "--initial-branch=main" });
    try fixtureGit(gpa, io, inner, &.{ "add", "-A" });
    try fixtureGit(gpa, io, inner, &.{ "commit", "--quiet", "-m", "inner" });

    const outer = try std.fs.path.join(arena, &.{ root, "outer" });
    try tmp.dir.createDirPath(io, "outer");
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/top.txt", .data = "top\n" });
    try fixtureGit(gpa, io, outer, &.{ "init", "--quiet", "--initial-branch=main" });
    try fixtureGit(gpa, io, outer, &.{ "add", "-A" });
    try fixtureGit(gpa, io, outer, &.{ "commit", "--quiet", "-m", "outer" });
    fixtureGit(gpa, io, outer, &.{
        "-c", "protocol.file.allow=always", "submodule", "--quiet", "add", inner, "vendor",
    }) catch return error.SkipZigTest; // some git builds refuse local submodules outright
    try fixtureGit(gpa, io, outer, &.{ "commit", "--quiet", "-m", "add submodule" });

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli: Cli = .{ .environ = &environ };
    const b = cli.backend();

    const clone = try std.fs.path.join(arena, &.{ root, "clone" });
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{outer});
    try b.ensureClone(gpa, io, clone, remote, .{});

    const rev = (try b.resolveRev(gpa, io, clone, "main")).?;
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{rev.commit.bytes}) catch unreachable;
    const tree = try b.treeOf(gpa, io, clone, &hex, null);

    try tmp.dir.createDirPath(io, "dest");
    const dest = try std.fs.path.join(arena, &.{ root, "dest" });

    // `git archive` silently OMITS the gitlink, so the extracted tree would
    // hash to something else and the failure would surface downstream as an
    // unexplained TreeHashMismatch. Refusing here names the real cause.
    try testing.expectError(error.SubmodulePresent, b.materialise(gpa, io, clone, tree, dest));

    // And nothing was written before the refusal.
    var dest_dir = try tmp.dir.openDir(io, "dest", .{ .iterate = true });
    defer dest_dir.close(io);
    var it = dest_dir.iterate();
    try testing.expect(try it.next(io) == null);
}

test "childEnviron disables every way git can ask a human for a password" {
    const gpa = testing.allocator;
    var parent: std.process.Environ.Map = .init(gpa);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    // A user who set these did so for an interactive session; the child must
    // not inherit either.
    try parent.put("GIT_ASKPASS", "/usr/bin/x11-ssh-askpass");
    try parent.put("SSH_ASKPASS", "/usr/bin/x11-ssh-askpass");

    var child = try childEnviron(gpa, &parent);
    defer child.deinit();

    // Inherited, because `insteadOf` rules, credential helpers and proxy
    // settings are exactly what somebody chose this backend for.
    try testing.expectEqualStrings("/usr/bin", child.get("PATH").?);
    try testing.expectEqualStrings("0", child.get("GIT_TERMINAL_PROMPT").?);
    // Empty, not absent: git stops its askpass ladder at the first variable
    // that is SET, so an empty value disables it and an absent one would fall
    // through to `core.askpass` and then to `SSH_ASKPASS`.
    try testing.expectEqualStrings("", child.get("GIT_ASKPASS").?);
    try testing.expectEqualStrings("", child.get("SSH_ASKPASS").?);
    // The parent is untouched: it is the process's own map.
    try testing.expectEqualStrings("/usr/bin/x11-ssh-askpass", parent.get("GIT_ASKPASS").?);
}

test "an ssh URL is refused by the interface, before any child runs" {
    // The check lives on `Backend`, not in the backend implementation, so it
    // holds for libgit2 too — and so the message is the same either way.
    const gpa = testing.allocator;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli: Cli = .{ .environ = &environ, .program = "/nonexistent/git" };
    const b = cli.backend();

    // `/nonexistent/git` would give BackendUnavailable if anything ran; the
    // ssh error proves nothing did.
    try testing.expectError(
        error.SshUnsupported,
        b.ensureClone(gpa, testing.io, "/tmp/x", "git@github.com:o/r.git", .{}),
    );
    try testing.expectError(
        error.SshUnsupported,
        b.fetch(gpa, testing.io, "/tmp/x", "ssh://git@github.com/o/r.git", git.refspecs_heads),
    );
    try testing.expectError(
        error.SshUnsupported,
        b.cloneWorking(gpa, testing.io, "/tmp/x", "ssh://git@github.com/o/r.git"),
    );
}

test "a working clone, its branch, its remote, and a fast-forward" {
    // Everything `Registry.update`'s git branch does to a cloned registry
    // (`Registry.jl:501-560`), against a real `git`. The assertions that
    // matter are the ones a plausible-looking wrong spelling would still pass:
    // that an UNTRACKED file is not dirty, and that a detached HEAD is
    // reported as detached rather than as a branch called "HEAD".
    const gpa = testing.allocator;
    const io = testing.io;
    if (!available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const upstream = try std.fs.path.join(arena, &.{ root, "upstream" });
    try tmp.dir.createDirPath(io, "upstream");
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/Registry.toml", .data = "name = \"Mini\"\n" });
    try fixtureGit(gpa, io, upstream, &.{ "init", "--quiet", "--initial-branch=trunk" });
    try fixtureGit(gpa, io, upstream, &.{ "add", "-A" });
    try fixtureGit(gpa, io, upstream, &.{ "commit", "--quiet", "-m", "initial" });

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    var cli: Cli = .{ .environ = &environ };
    const b = cli.backend();

    const clone = try std.fs.path.join(arena, &.{ root, "clone" });
    const remote = try std.fmt.allocPrint(arena, "file://{s}", .{upstream});
    try b.cloneWorking(gpa, io, clone, remote);

    // A working tree, not a bare object store: this is what a registry is.
    _ = try tmp.dir.statFile(io, "clone/Registry.toml", .{});

    try testing.expectEqualStrings("trunk", (try b.headBranch(gpa, arena, io, clone)).?);
    try testing.expect(!try b.isDirty(gpa, io, clone));
    const origin = (try b.remoteUrl(gpa, arena, io, clone, "origin")).?;
    try testing.expectEqualStrings(remote, origin);
    try testing.expect((try b.remoteUrl(gpa, arena, io, clone, "upstream")) == null);

    // `isdirty` is diff(HEAD -> workdir) with no INCLUDE_UNTRACKED, so a file
    // git has never seen is NOT dirty. Getting this wrong would make every
    // update refuse on any depot with an editor backup file in it.
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/scratch.txt", .data = "not tracked\n" });
    try testing.expect(!try b.isDirty(gpa, io, clone));
    // A tracked file changed IS dirty.
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/Registry.toml", .data = "name = \"Edited\"\n" });
    try testing.expect(try b.isDirty(gpa, io, clone));
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/Registry.toml", .data = "name = \"Mini\"\n" });
    try testing.expect(!try b.isDirty(gpa, io, clone));

    // --- the update itself --------------------------------------------------
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/Extra.toml", .data = "x = 1\n" });
    try fixtureGit(gpa, io, upstream, &.{ "add", "-A" });
    try fixtureGit(gpa, io, upstream, &.{ "commit", "--quiet", "-m", "second" });

    const refspec = try git.registryRefspec(arena, "trunk");
    try b.fetch(gpa, io, clone, origin, refspec);
    try testing.expect(try b.fastForward(gpa, io, clone, "refs/remotes/origin/trunk"));
    _ = try tmp.dir.statFile(io, "clone/Extra.toml", .{});
    // Idempotent: already up to date is still a successful fast-forward.
    try testing.expect(try b.fastForward(gpa, io, clone, "refs/remotes/origin/trunk"));

    // --- detached HEAD ------------------------------------------------------
    // `rev-parse --abbrev-ref HEAD` prints the literal "HEAD" here, which is
    // why `symbolic-ref` is the spelling used.
    const head = try fixtureGitOut(gpa, io, clone, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try fixtureGit(gpa, io, clone, &.{ "checkout", "--quiet", "--detach", head });
    try testing.expect((try b.headBranch(gpa, arena, io, clone)) == null);
}
