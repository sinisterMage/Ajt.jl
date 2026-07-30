//! `ajt registry add` / `ajt registry update`.
//!
//! The first end-to-end network operation in Ajt: fetch a registry from a Pkg
//! server and install it into a depot. Port of `download_registries`
//! (`Pkg/src/Registry/Registry.jl:181-302`) and the tarball branch of
//! `update` (`:418-500`, tarball branch `:451-475`), restricted to the Pkg-server protocol.
//!
//! ## The download authenticates itself
//!
//! There is no signature and no checksum file anywhere in this protocol, and
//! none is needed. `GET $server/registries` answers with lines of the form
//! `/registry/<uuid>/<tree-sha1>` (`:88`); the tarball then lives at
//! `$server/registry/$uuid/$hash` (`:105`), and the hash in that URL is the
//! git tree hash of the archive's contents. `pkg_server_url_hash` recovers it
//! by taking the last path segment (`:110`), and `verify_archive_tree_hash`
//! (`PlatformEngines.jl:692-699`) recomputes it with `Tar.tree_hash` over the
//! decompressed stream. So the only thing a mirror can serve is the bytes the
//! index named — everything else fails the check.
//!
//! Two details of that check are load-bearing and easy to get wrong:
//!
//!  * `Tar.tree_hash`'s `skip_empty` defaults to **false**, so empty
//!    directories are retained. `GitTools.tree_hash` prunes them, and Ajt's
//!    installer path defaults to pruning for exactly that reason
//!    (`install/extract.zig`). Registry verification must NOT prune, or a
//!    registry snapshot that happens to contain an empty directory is
//!    rejected as corrupt.
//!  * The hash is computed **before anything reaches the filesystem**. Julia
//!    downloads to `tempname()` first, so it does write unverified bytes to
//!    disk; Ajt holds the archive in memory and only publishes after the
//!    comparison. `treehash.hashTar` additionally refuses tar paths that would
//!    escape the tree (a `..` component, or a path nested under something
//!    already recorded as a symlink) — Julia refuses those in the hasher too
//!    (`Tar/src/extract.jl:361-368`) — and that refusal is treated here as a
//!    hard rejection of the download, exactly like a hash mismatch.
//!
//! Throughout this file a bare `:N` citation means
//! `Pkg/src/Registry/Registry.jl:N`; every other file is named explicitly.
//!
//! ## The three shapes a registry can have here
//!
//! The Pkg-server tarball is the default but not the only one, and the other
//! two are not second-class:
//!
//!  * `<Name>.tar.gz` + `<Name>.toml` — the compressed layout above.
//!  * `<Name>/` with a `.tree_info.toml` — the same content unpacked,
//!    `JULIA_PKG_UNPACK_REGISTRY` (`:242-251`).
//!  * `<Name>/` with a `.git` — a git CLONE, which is what Pkg installs when
//!    the server cannot serve (`:260-262`) and what most pre-server depots
//!    still hold. It has no `tree_info`, so `update` maintains it by fetching
//!    one branch and fast-forwarding (`:501-560`) and never asks the server
//!    about it at all.
//!
//! The three are told apart exactly the way `RegistryInstance` does it
//! (`registry_instance.jl:329-345`): a `<Name>.toml` stamp beside the
//! directory wins, then `.tree_info.toml`, then `.git`. Getting that order
//! wrong is not cosmetic — `readInstalled` decides which of the two `update`
//! implementations runs.
//!
//! ## What is deliberately NOT implemented
//!
//! The `path =`/`linked = true` local-source forms (`:255-259`, `:274-282`):
//! they are a developer convenience, not part of the wire protocol this unit
//! exists to speak.
//!
//! Julia's `update` also RE-RESOLVES its registry list from
//! `reachable_registries` when given none (`:421`); `ajt registry update` acts
//! on the registries it was named, one call per registry.
//!
//! `update` also has a **cooldown**: `update_cooldown = Second(1)` (`:418`),
//! checked against a `registry_updates.toml` log in Pkg's own scratchspace
//! (`:378-392`, `:429-436`, `:474`). Ajt does not implement it and does not
//! write that log. It exists to stop `Pkg.add` from re-fetching the index
//! several times inside one REPL command; an explicit `ajt registry update`
//! is a direct user request, and silently skipping it would be the surprising
//! behaviour. The consequence is that a script looping `ajt registry update`
//! hits the server every time, where Pkg would not.
//!
//! ## The `.aix` index needs no invalidation
//!
//! `registry/aix.zig` keys its cache file on `<uuid>-<tree-sha1>.aix`
//! (`aix.cachePath`). Installing a different snapshot writes a different
//! `<Name>.toml` stamp, which names a different cache file, so a stale index
//! is simply never opened. Nothing here has to delete anything.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const net_http = @import("../net/http.zig");
const jenv = @import("../julia/env.zig");
const treehash = @import("../julia/treehash.zig");
const slug = @import("../julia/slug.zig");
const extract = @import("../install/extract.zig");
const depot_mod = @import("../depot.zig");
const toml_parse = @import("../toml/parse.zig");
const toml_value = @import("../toml/value.zig");
const toml_emit = @import("../toml/emit.zig");
const git_mod = @import("../git/git.zig");

/// Domain failures, spelled out so a caller can react to each. I/O and
/// allocation failures ride along in the inferred error sets of the functions
/// that can raise them.
pub const Error = error{
    /// `JULIA_PKG_SERVER=""` and no git clone was possible either — no URL for
    /// this registry, or no git backend wired in. Julia clones here
    /// (`:260-262`), and so does Ajt when it has something to clone FROM;
    /// this error is what is left when it does not.
    ServerDisabled,
    /// `GET $server/registries` failed after the retry budget, or answered
    /// non-2xx, and no clone fallback was available. Julia `@warn`s and
    /// returns `nothing` (`:83-85`), which turns into "no registry URLs" and
    /// then a git clone, so a reachable clone URL takes that branch here too
    /// rather than failing.
    NoServerIndex,
    /// A line of the index matched the shape but not the content — Julia's
    /// `UUID(...)` / `Base.SHA1(...)` constructors throw on the same input
    /// (`:88-90`).
    MalformedServerIndex,
    /// No `--registry`/`--uuid` given and the name is not one Ajt knows.
    UnknownRegistry,
    /// The server's index does not list this registry's UUID.
    RegistryNotOnServer,
    /// `registry update` on a registry that is not installed in this depot.
    NotInstalled,
    /// The tarball GET failed or answered non-2xx.
    DownloadFailed,
    /// The archive is not the tree the URL named. Nothing was written.
    ///
    /// Distinct from `install/extract.zig`'s `ExtractFailed`, which this
    /// module deliberately passes through rather than folding in here:
    /// `ExtractFailed` means the content DID verify and the filesystem then
    /// refused it, so reporting it as a verification failure would accuse the
    /// server of serving corrupt bytes when the disk is merely full.
    VerificationFailed,
    /// The archive has no parseable `Registry.toml`, so its name is unknown.
    MalformedRegistry,
    /// `JULIA_PKG_UNPACK_REGISTRY` is set to something Julia's
    /// `Base.get_bool_env` does not recognise. Pkg raises a `MethodError` on
    /// that value (`!nothing`), i.e. it refuses to run at all; so does Ajt.
    InvalidUnpackSetting,
    /// The registry name is not usable as a single filename. See
    /// `checkRegistryName`.
    UnsafeRegistryName,
    /// Another process holds `registries/.pid` and did not release it within
    /// the timeout.
    RegistryLocked,
    /// `--offline` / `JULIA_PKG_OFFLINE`. Installing or refreshing a registry
    /// is a download and nothing else, so there is no reduced service to
    /// offer — see the note on the early return in `run`.
    Offline,
    /// A registry is already installed at `registries/<Name>` and it is a
    /// DIFFERENT registry — same name, other uuid (`:283-291`). Julia's
    /// message tells the user to clone it manually under another name; there
    /// is nothing safe to do automatically, because the name is the only
    /// handle either tool has on it.
    RegistryConflict,
    /// An operation that can only be done with git was asked for and no git
    /// backend was supplied — updating a cloned registry, or falling back to
    /// a clone. A caller-side wiring failure, not a user-facing state: the
    /// CLI always passes one, and a missing `git` binary surfaces as the
    /// backend's own `BackendUnavailable` instead.
    GitUnavailable,
};

// ---------------------------------------------------------------------------
// Known registries
// ---------------------------------------------------------------------------

pub const KnownRegistry = struct {
    name: []const u8,
    uuid: []const u8,
    /// The git URL, used only when the Pkg server cannot serve this registry
    /// (`:260-262`). It is `RegistrySpec.url`, filled in by
    /// `populate_known_registries_with_urls!` (`:141-158`) — which is why
    /// `Pkg.Registry.add("General")` still works with `JULIA_PKG_SERVER=""`.
    url: []const u8,
};

/// `DEFAULT_REGISTRIES` (`:61-68`), verbatim — including the URL, which is
/// load-bearing now that the clone fallback exists.
pub const default_registries = [_]KnownRegistry{
    .{
        .name = "General",
        .uuid = "23338594-aafe-5451-b93e-139f81909106",
        .url = "https://github.com/JuliaRegistries/General.git",
    },
};

pub fn knownByName(name: []const u8) ?KnownRegistry {
    for (default_registries) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The server index
// ---------------------------------------------------------------------------

/// One `/registry/<uuid>/<tree-sha1>` line of `$server/registries`.
pub const Pin = struct {
    uuid: []const u8,
    tree_sha1: []const u8,
};

/// `match(r"^/registry/([^/]+)/([^/]+)$", line)` (`:88`), applied to every
/// line of the body. Lines that do not match are silently ignored, which is
/// what lets the server add other record types later.
///
/// Arena-allocated: the returned slices borrow `arena`, and `body` may be
/// freed afterwards.
///
/// A duplicate UUID keeps the LAST occurrence, because Julia accumulates into
/// a `Dict` (`:91`).
///
/// **Both captures are lower-cased**, because Julia does not keep the text at
/// all: it stores `UUID(...)` and `Base.SHA1(...)` VALUES (`:89-90`) and
/// re-renders them into the download URL (`:105`) and the stamp (`:218`).
/// Both constructors accept upper-case hex and both print lower-case, so an
/// upper-case index line is legal and Julia silently canonicalises it. Keeping
/// the raw text instead would mean `findPin` missing a match against the
/// lower-case `default_registries` UUID, requesting a URL Julia would not
/// request, and writing a stamp that never compares equal to a Pkg-written one.
pub fn parseIndex(arena: Allocator, body: []const u8) (Allocator.Error || error{MalformedServerIndex})![]Pin {
    var pins: std.ArrayList(Pin) = .empty;

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        // `eachline` strips the line terminator, CRLF included.
        const line = std.mem.trimEnd(u8, raw, "\r");
        const rest = prefixOf(line, "/registry/") orelse continue;
        // `([^/]+)/([^/]+)$`: exactly one separator left, and neither half
        // may be empty.
        const sep = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const uuid = rest[0..sep];
        const hash = rest[sep + 1 ..];
        if (uuid.len == 0 or hash.len == 0) continue;
        if (std.mem.indexOfScalar(u8, hash, '/') != null) continue;

        // Julia's `UUID(...)`/`Base.SHA1(...)` THROW on a malformed capture,
        // and `pkg_server_registry_info` does not catch them — only the
        // download is wrapped in `try` (`:76-85`). So a bad pin aborts the
        // whole operation rather than being skipped, which is also the safe
        // reading: silently dropping a pin looks identical to "the registry
        // is not on the server".
        _ = slug.Uuid.parse(uuid) catch return error.MalformedServerIndex;
        _ = slug.Sha1.parse(hash) catch return error.MalformedServerIndex;

        // Both parsers above accept ONLY the canonical shape (36 chars with
        // dashes at fixed offsets; 40 hex digits), so ASCII-lower-casing the
        // validated text is exactly `string(UUID(...))` / `string(SHA1(...))`.
        const uuid_lc = try lowerDupe(arena, uuid);
        const hash_lc = try lowerDupe(arena, hash);

        for (pins.items) |*p| {
            if (std.mem.eql(u8, p.uuid, uuid_lc)) {
                p.tree_sha1 = hash_lc;
                break;
            }
        } else try pins.append(arena, .{ .uuid = uuid_lc, .tree_sha1 = hash_lc });
    }
    return pins.items;
}

fn lowerDupe(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, s.len);
    for (out, s) |*d, c| d.* = std.ascii.toLower(c);
    return out;
}

fn prefixOf(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    return s[prefix.len..];
}

pub fn findPin(pins: []const Pin, uuid: []const u8) ?Pin {
    for (pins) |p| {
        if (std.mem.eql(u8, p.uuid, uuid)) return p;
    }
    return null;
}

/// `"$server/registry/$uuid/$hash"` (`:105`). Arena-allocated.
pub fn tarballUrl(arena: Allocator, server: []const u8, uuid: []const u8, hash: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}/registry/{s}/{s}", .{ server, uuid, hash });
}

/// `pkg_server_url_hash(url) = Base.SHA1(split(url, '/')[end])` (`:110`).
///
/// Used rather than the pin it was built from, so the invariant "the hash
/// being verified is the one in the URL that was actually fetched" is visible
/// in the code and not merely true by construction.
pub fn urlHash(url: []const u8) error{VerificationFailed}!slug.Sha1 {
    const last = if (std.mem.lastIndexOfScalar(u8, url, '/')) |i| url[i + 1 ..] else url;
    return slug.Sha1.parse(last) catch error.VerificationFailed;
}

/// `GET $server/registries` with Pkg's own retry budget
/// (`retry(delays = fill(1.0, 3))`, `:77`).
///
/// Arena-allocated. The body of this endpoint is a few hundred bytes, so it is
/// buffered rather than streamed.
pub fn fetchIndex(
    arena: Allocator,
    client: *net_http.Client,
    server: []const u8,
) ![]Pin {
    const url = try std.fmt.allocPrint(arena, "{s}/registries", .{server});
    const res = client.get(arena, url, .{
        .retry = .pkg_server,
        // The index is tiny; a server streaming megabytes at this endpoint is
        // malfunctioning and should be cut off rather than buffered.
        .max_body_bytes = 4 * 1024 * 1024,
    }) catch |err| switch (err) {
        // "the server is unreachable" and "this machine is out of memory" call
        // for completely different reactions from a caller, so the transport
        // failure must not swallow the resource failure.
        error.OutOfMemory, error.Canceled => |e| return e,
        else => return error.NoServerIndex,
    };
    if (!res.ok()) return error.NoServerIndex;
    return parseIndex(arena, res.body);
}

// ---------------------------------------------------------------------------
// JULIA_PKG_UNPACK_REGISTRY
// ---------------------------------------------------------------------------

/// `Base.get_bool_env(name, default)` (`base/env.jl:142-151`; the
/// truthy and falsy tuples it matches against are at `:115-128`).
///
/// The recognised sets are exact strings — lowercase, Capitalized and
/// UPPERCASE only, so `tRue` is NOT truthy — and an empty value falls back to
/// the default. Anything else returns `nothing`, which `registry_read_from_tarball`
/// then applies `!` to and raises a `MethodError` on (`:164-165`); verified by
/// running Pkg with `JULIA_PKG_UNPACK_REGISTRY=garbage`. Ajt reports that as
/// `InvalidUnpackSetting` rather than inventing a fallback Pkg does not have.
///
/// The table itself moved to `julia/env.zig` when `JULIA_PKG_OFFLINE` became
/// the second variable read this way; this is now only the per-variable name
/// for "unrecognised", which is the part callers switch on.
pub fn getBoolEnv(raw: ?[]const u8, default: bool) error{InvalidUnpackSetting}!bool {
    return jenv.getBool(raw, default) catch error.InvalidUnpackSetting;
}

/// `registry_read_from_tarball()` (`:164-165`): keep the registry compressed
/// unless the user asked for it unpacked.
///
/// The `registry_use_pkg_server()` half of that expression is the caller's
/// `server != null`; this function only answers the env-var half.
pub fn readFromTarball(unpack_env: ?[]const u8) error{InvalidUnpackSetting}!bool {
    return !(try getBoolEnv(unpack_env, false));
}

// ---------------------------------------------------------------------------
// The pidfile lock
// ---------------------------------------------------------------------------

/// Julia's `mkpidlock(joinpath(regdir, ".pid"), stale_age = 10)` (`:188`,
/// `:425`), reimplemented so that a concurrent `julia` and a concurrent `ajt`
/// exclude each other rather than interleaving writes into `registries/`.
///
/// The protocol is entirely in the file (`FileWatching/src/pidfile.jl`):
///
///   * The lock IS `open(path, O_RDWR|O_CREAT|O_EXCL, 0o444)` (`pidfile.jl:216-223`).
///     Nothing else — no flock, no directory. So compatibility means creating
///     the same path with the same exclusivity, and nothing more.
///   * The body is `"$pid $(gethostname())"` (`pidfile.jl:141-143`), no newline. The
///     hostname is what lets a reader tell "this pid is on my machine and I
///     can check it" from "this lock belongs to another host" (`pidfile.jl:180-191`).
///   * Freshness is the file's **mtime**, refreshed by the holder every
///     `stale_age/2` seconds (`pidfile.jl:76`). A lock is stealable only when
///     `age > stale_age` AND (`age > 5*stale_age` OR the pid is not a live
///     process on this host) (`pidfile.jl:198-208`).
///
/// The refresh timer is the reason the background refresher exists below:
/// without it, our own lock goes stale after 50 s of a slow download and a
/// waiting `julia` deletes it out from under us.
///
/// Verified against the real thing, not just against the source: with Julia
/// holding `mkpidlock(regdir/".pid", stale_age = 10)`, `ajt registry add`
/// blocked, did NOT report a stale steal, and proceeded only once Julia
/// released — and Julia's pidfile (`"<pid> <hostname>"`, mode 0444) is
/// byte-identical in shape to the one written here.
pub const Lock = struct {
    /// Not owned; the caller keeps `regdir` open.
    dir: Io.Dir,
    file: Io.File,
    /// The pidfile's name within `dir`. `registries/` locks the whole
    /// directory as `.pid`; `logs/` locks PER FILE as `<log>.pid`
    /// (`Types.jl:684`), and using a different name there would mean no mutual
    /// exclusion against a concurrent `julia` at all. Borrowed from
    /// `LockOptions.name`, so it must outlive the `Lock`.
    name: []const u8 = file_name,
    /// Identity of the file we created, so `release` never deletes a lock
    /// that somebody else re-created at the same path — Julia's `samefile`
    /// guard (`pidfile.jl:366-369`). `Io.File.Stat` exposes the inode but no device id;
    /// both names live in one directory, hence on one filesystem, so the inode
    /// alone settles it.
    inode: Io.File.INode,
    refresher: ?Io.Future(void) = null,
    held: bool = true,

    pub const file_name = ".pid";

    /// Release, deleting the pidfile if it is still ours. Idempotent.
    pub fn release(self: *Lock, io: Io) void {
        if (!self.held) return;
        self.held = false;
        if (self.refresher) |*f| {
            // `cancel` makes the task's next `io.sleep` return `error.Canceled`
            // and does not return until the task has finished, so the file
            // handle below is not closed underneath a live refresher.
            _ = f.cancel(io);
            self.refresher = null;
        }
        if (self.dir.statFile(io, self.name, .{})) |st| {
            if (st.inode == self.inode) self.dir.deleteFile(io, self.name) catch {};
        } else |_| {}
        self.file.close(io);
        // Deliberately NOT `self.* = undefined`: `held` is what makes this
        // idempotent, and poisoning the struct would make the second call read
        // an undefined bool.
    }
};

pub const LockOptions = struct {
    /// The pidfile's name within the directory being locked. Defaults to
    /// `registries/.pid`; `ops/usage.zig` overrides it with `<log>.pid` to
    /// match `Types.jl:684`. Borrowed by the returned `Lock`, so it must
    /// outlive it.
    name: []const u8 = Lock.file_name,
    /// Names `dir` in the stale-lock warning only. `dir` is an open handle
    /// with no path to print, and "removing a stale lock at .pid" without one
    /// tells a user nothing about WHICH depot is stuck.
    dir_label: []const u8 = "registries",
    /// `stale_age` in seconds (`:188` passes 10).
    stale_age_s: f64 = 10,
    /// `refresh` — Julia defaults it to `stale_age/2` (`pidfile.jl:64`). Zero disables
    /// the background touch, which also changes the staleness arithmetic other
    /// implementations apply to us (`longer_factor` becomes 25, `pidfile.jl:201`).
    refresh_s: f64 = 5,
    /// Retry interval while waiting. Julia watches the file with
    /// `FileMonitor` and falls back to `poll_interval = 10s` (`pidfile.jl:240`, `:291`);
    /// polling is the same behaviour with a coarser wake-up.
    poll_ms: u64 = 100,
    /// How long to wait before giving up. **A divergence:** Julia's
    /// `wait = true` loops forever (`pidfile.jl:261-306`). A CLI that hangs indefinitely
    /// on a stuck peer is worse than one that says so, so Ajt bounds it.
    timeout_ms: u64 = 120_000,
};

/// `open_exclusive(path; wait = true, stale_age, refresh)` (`pidfile.jl:238-307`).
///
/// `dir` must be the already-created `registries/` directory; it stays owned
/// by the caller and must outlive the returned `Lock`.
pub fn acquireLock(io: Io, dir: Io.Dir, opts: LockOptions) !Lock {
    const deadline = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(@intCast(opts.timeout_ms)));
    // "set stale_age to zero so we won't attempt again, even if the attempt
    // fails" (`pidfile.jl:301-302`): the steal is tried at most once per acquisition.
    var may_steal = opts.stale_age_s > 0;

    while (true) {
        if (dir.createFile(io, opts.name, .{
            .read = true,
            .exclusive = true,
            // `mode = 0o444` (`pidfile.jl:239`). Read-only on purpose: the file exists
            // to be stat'ed and parsed, never appended to.
            .permissions = pidfile_permissions,
        })) |file| {
            var lock: Lock = .{
                .dir = dir,
                .file = file,
                .name = opts.name,
                .inode = (file.stat(io) catch |err| {
                    // The pidfile exists but we never recorded its identity,
                    // so `release` could not safely delete it later. Remove it
                    // now rather than leaving an orphan that blocks every
                    // other process until it ages out.
                    file.close(io);
                    dir.deleteFile(io, opts.name) catch {};
                    return err;
                }).inode,
            };
            errdefer lock.release(io);
            try writePidfile(io, file);
            lock.refresher = startRefresher(io, file, opts.refresh_s);
            return lock;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }

        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.RegistryLocked;
        try io.sleep(.fromMilliseconds(@intCast(opts.poll_ms)), .awake);

        if (may_steal and try stalePidfile(io, dir, opts)) {
            may_steal = false;
            // `@warn "attempting to remove probably stale pidfile"` (`pidfile.jl:303`).
            std.debug.print(
                "ajt: removing a probably stale lock at {s}/{s}\n",
                .{ opts.dir_label, opts.name },
            );
            dir.deleteFile(io, opts.name) catch {};
        }
    }
}

/// `0o444` where the platform has a mode at all (`pidfile.jl:239`).
const pidfile_permissions: Io.File.Permissions = switch (builtin.os.tag) {
    .windows, .wasi => .default_file,
    else => @enumFromInt(0o444),
};

/// `write_pidfile(io, pid)` = `print(io, "$pid $(gethostname())")` — no
/// trailing newline, and `parse_pidfile` splits on the FIRST space only, so a
/// hostname containing spaces round-trips (`pidfile.jl:141-158`).
fn writePidfile(io: Io, file: Io.File) !void {
    var host_buf: [max_hostname]u8 = undefined;
    const host = hostname(&host_buf);
    var line_buf: [max_hostname + 32]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d} {s}", .{ currentPid(), host }) catch
        return error.NameTooLong;
    try file.writeStreamingAll(io, line);
}

const max_hostname = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) 1 else std.posix.HOST_NAME_MAX;

fn hostname(buf: *[max_hostname]u8) []const u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return "";
    return std.posix.gethostname(buf) catch "";
}

fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
}

/// `stale_pidfile(path, stale_age, refresh)` (`pidfile.jl:198-208`).
fn stalePidfile(io: Io, dir: Io.Dir, opts: LockOptions) !bool {
    const st = dir.statFile(io, opts.name, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        // The holder released it between our create attempt and now. Not
        // stale — just gone; the next create will win.
        else => return false,
    };
    const now = Io.Timestamp.now(io, .real);
    const age = seconds(now) - seconds(st.mtime);

    // `longer_factor = refresh == 0 ? 25 : 5` (`pidfile.jl:201`).
    const longer_factor: f64 = if (opts.refresh_s == 0) 25 else 5;
    if (!(age > opts.stale_age_s)) return false;
    if (age > opts.stale_age_s * longer_factor) return true;

    var buf: [max_hostname + 64]u8 = undefined;
    const n = readPidfile(io, dir, opts.name, &buf);
    return !isValidPid(buf[0..n]);
}

fn seconds(t: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t.nanoseconds)) / std.time.ns_per_s;
}

fn readPidfile(io: Io, dir: Io.Dir, name: []const u8, buf: []u8) usize {
    const file = dir.openFile(io, name, .{}) catch return 0;
    defer file.close(io);
    var one = [_][]u8{buf};
    return file.readStreaming(io, &one) catch 0;
}

/// `isvalidpid(hostname, pid)` (`pidfile.jl:180-191`), fed the raw pidfile
/// body so the `"$pid $host"` split stays in one place.
///
/// Every uncertain answer is `true` — "assume the holder is alive" — because
/// the consequence of a wrong `false` is deleting a live process's lock.
fn isValidPid(body: []const u8) bool {
    // `split(..., ' ', limit = 2)`: pid is everything up to the first space.
    const sp = std.mem.indexOfScalar(u8, body, ' ');
    const pid_text = if (sp) |i| body[0..i] else body;
    const host = if (sp) |i| body[i + 1 ..] else "";

    // `tryparse(Cuint, ...)`; `nothing` becomes 0, which is then never valid.
    const pid = std.fmt.parseInt(u32, pid_text, 10) catch 0;

    // "can't inspect remote hosts" (`pidfile.jl:182`). An empty hostname is treated as
    // local, which is what `hostname == ""` does in Julia.
    if (host.len != 0) {
        var buf: [max_hostname]u8 = undefined;
        if (!std.mem.eql(u8, host, hostname(&buf))) return true;
    }
    if (pid == 0) return false;
    if (pid > std.math.maxInt(i32) and builtin.os.tag != .windows) return false;

    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return true;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| switch (err) {
        // ESRCH is the only answer that means "no such process"; EPERM means
        // it exists and belongs to someone else (`uv_kill(...) != UV_ESRCH`).
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

/// The background `touch` that keeps our own lock from going stale
/// (`pidfile.jl:74-77`).
///
/// `io.concurrent` rather than `io.async`, for two reasons and do not swap it:
///
///  1. The refresher must make progress while the main task is blocked in a
///     multi-second download, which is precisely the guarantee `concurrent`
///     adds over `async`.
///  2. The returned `Future` is stored in a `Lock` that `acquireLock` returns
///     BY VALUE, so it gets moved. That is safe only for `concurrent`, which
///     heap-allocates the shared state and hands back an opaque pointer
///     (`Io/Threaded.zig:2130-2174`). `async` passes `&future.result` to the
///     runtime at creation time (`Io.zig:2326-2350`), so moving one leaves the
///     runtime writing into a dead stack slot.
///
/// An `Io` implementation without concurrency answers `ConcurrencyUnavailable`,
/// and then there is simply no refresh — which still leaves a 50 s window
/// before any peer may steal the lock (`age > stale_age` AND
/// `age > 5*stale_age` for a live local pid), so the degradation is graceful
/// rather than a hard dependency.
fn startRefresher(io: Io, file: Io.File, refresh_s: f64) ?Io.Future(void) {
    if (refresh_s <= 0) return null;
    const ns: u64 = @intFromFloat(@max(refresh_s, 0.001) * std.time.ns_per_s);
    return io.concurrent(refreshLoop, .{ io, file, ns }) catch null;
}

fn refreshLoop(io: Io, file: Io.File, interval_ns: u64) void {
    while (true) {
        // The cancellation point. `Lock.release` cancels, this returns
        // `error.Canceled`, and the loop ends before the handle is closed.
        io.sleep(.{ .nanoseconds = interval_ns }, .awake) catch return;
        file.setTimestampsNow(io) catch return;
    }
}

// ---------------------------------------------------------------------------
// Installed state
// ---------------------------------------------------------------------------

/// A registry already present in `registries/`, in any of the three layouts
/// Pkg understands.
pub const Installed = struct {
    /// Empty for `.directory` and `.git_clone`: `.tree_info.toml` records only
    /// the hash, and Pkg reads the uuid from the tree's own `Registry.toml`.
    uuid: []const u8,
    /// Empty for `.git_clone`, which has no tree hash at all — that absence
    /// IS the layout's signature (`reg.tree_info === nothing`, `:501`) and is
    /// what routes `update` to git instead of to the server.
    tree_sha1: []const u8,
    /// The tarball's filename relative to `registries/`. Empty otherwise.
    path: []const u8,
    layout: Layout,

    pub const Layout = enum { tarball, directory, git_clone };
};

/// What `reachable_registries` would find for `name`
/// (`registry_instance.jl:437-455`).
///
/// Both layouts have to be recognised, and that is not academic: `update`
/// decides whether a registry is installed at all through this function, so
/// looking only at `<Name>.toml` made `ajt registry update` fail with
/// `NotInstalled` forever after an `--unpack` install — the one file that
/// install writes, `.tree_info.toml`, being the one nothing read.
///
///  * `<Name>.toml` — the compressed layout. The keys checked here are exactly
///    `verify_compressed_registry_toml`'s (`registry_instance.jl:416-421`),
///    INCLUDING its final requirement that the tarball named by `path` really
///    exists (`:422-426`). Without that last check, a stamp whose tarball has
///    been deleted reads as installed and `update` can answer `up_to_date` for
///    a registry Pkg refuses to load.
///  * `<Name>/.tree_info.toml` — the unpacked layout (`registry_instance.jl:337-342`).
///  * `<Name>/.git` — a git clone. `RegistryInstance` gives it
///    `tree_info === nothing` (`registry_instance.jl:338-342`, the `else`
///    arm), which is precisely the condition that sends `update` down the
///    `elseif isdir(joinpath(reg.path, ".git"))` branch (`:501`). Before this
///    layout was recognised, `ajt registry update General` on a cloned
///    registry answered `NotInstalled` forever.
///
/// The stamp wins when both are present, because `reachable_registries` drops
/// any directory whose basename matches a compressed registry (`:448-449`).
/// Arena-allocated.
pub fn readInstalled(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8) !?Installed {
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    if (std.fmt.bufPrint(&name_buf, "{s}.toml", .{name})) |stamp_name| {
        if (try readStampFile(arena, io, dir, stamp_name)) |found| return found;
    } else |_| {}

    const info_name = std.fmt.bufPrint(&name_buf, "{s}/.tree_info.toml", .{name}) catch return null;
    if (dir.readFileAlloc(io, info_name, arena, .limited(64 * 1024))) |src| {
        const doc = toml_parse.parse(arena, src, null) catch return null;
        return .{
            .uuid = "",
            .tree_sha1 = stringField(doc.root, "git-tree-sha1") orelse return null,
            .path = "",
            .layout = .directory,
        };
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    }

    return try readGitClone(io, dir, name);
}

/// `<Name>/` holding both a `Registry.toml` and a `.git` DIRECTORY.
///
/// Both halves are required and neither is redundant. `Registry.toml` is what
/// makes `reachable_registries` accept the directory as a registry at all
/// (`registry_instance.jl:439-441`) — a repository that merely lives in
/// `registries/` is not one. `.git` being a directory is `isdir(...".git")`
/// literally (`:501`); a `.git` FILE is a linked worktree or a submodule, and
/// Pkg's `isdir` says no to it, so this does too rather than sending `update`
/// somewhere Pkg would not go.
fn readGitClone(io: Io, dir: Io.Dir, name: []const u8) !?Installed {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;

    const reg_toml = std.fmt.bufPrint(&buf, "{s}/Registry.toml", .{name}) catch return null;
    const reg_st = dir.statFile(io, reg_toml, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return null,
    };
    if (reg_st.kind != .file) return null;

    const git_dir = std.fmt.bufPrint(&buf, "{s}/.git", .{name}) catch return null;
    const git_st = dir.statFile(io, git_dir, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return null,
    };
    if (git_st.kind != .directory) return null;

    return .{ .uuid = "", .tree_sha1 = "", .path = "", .layout = .git_clone };
}

/// The `<Name>.toml` half of `readInstalled`, split out so the happy path is
/// not five levels of nested `orelse return null`.
fn readStampFile(arena: Allocator, io: Io, dir: Io.Dir, stamp_name: []const u8) !?Installed {
    const src = dir.readFileAlloc(io, stamp_name, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return null,
    };
    const doc = toml_parse.parse(arena, src, null) catch return null;
    const uuid = stringField(doc.root, "uuid") orelse return null;
    const hash = stringField(doc.root, "git-tree-sha1") orelse return null;
    const path = stringField(doc.root, "path") orelse return null;

    // `isfile(compressed_file) || return false` (`registry_instance.jl:422-426`).
    // `path` comes from a file on disk, so it is also the one field here that
    // could name something outside `registries/`; `statFile` on a relative
    // path with `..` would follow it, which is why only the exact filename
    // this module writes is accepted.
    if (std.mem.indexOfAny(u8, path, "/\\") != null) return null;
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return null,
    };
    return .{ .uuid = uuid, .tree_sha1 = hash, .path = path, .layout = .tarball };
}

fn stringField(t: *const toml_value.Table, key: []const u8) ?[]const u8 {
    return switch (t.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The `<Name>.toml` body (`:218-221`).
///
/// **Key order diverges, on purpose.** Julia writes
/// `TOML.print(io, Dict("uuid" => …, "git-tree-sha1" => …, "path" => …))`,
/// i.e. `Dict` hash order — for these three keys Julia 1.12.6 emits
/// `git-tree-sha1`, `uuid`, `path`, which is not a property of the format but
/// of the hash table. Ajt emits sorted (`git-tree-sha1`, `path`, `uuid`):
/// deterministic, and TOML-identical to what Pkg reads back. Arena-allocated.
pub fn regInfoToml(
    arena: Allocator,
    gpa: Allocator,
    uuid: []const u8,
    tree_sha1: []const u8,
    path: []const u8,
) ![]u8 {
    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();
    const a = doc_arena.allocator();

    const root = try toml_value.Table.create(a);
    try root.put(a, "uuid", .{ .string = uuid });
    try root.put(a, "git-tree-sha1", .{ .string = tree_sha1 });
    try root.put(a, "path", .{ .string = path });

    const rendered = try toml_emit.emitAlloc(gpa, root, .{ .sorted = true });
    defer gpa.free(rendered);
    return arena.dupe(u8, rendered);
}

// ---------------------------------------------------------------------------
// The operation
// ---------------------------------------------------------------------------

pub const Mode = enum { add, update };

pub const Action = enum {
    /// Downloaded and published.
    added,
    updated,
    /// `update` found the server's hash equal to the recorded one (`:447`).
    up_to_date,
    /// The clone branch found a registry with the SAME uuid already installed
    /// at that path: "Registry `X` already exists in `…`" (`:277-281`), which
    /// is a successful no-op rather than an error.
    already_exists,
    would_add,
    would_update,
    would_be_up_to_date,
};

pub const Options = struct {
    mode: Mode,
    /// `depots1()` — the depot that owns `registries/`.
    depot: []const u8,
    /// Registry name. Null means "look it up": by `uuid` against
    /// `default_registries`, or from the downloaded `Registry.toml` (`:215`).
    name: ?[]const u8 = null,
    /// Registry UUID. Null means "derive it from `name`".
    uuid: ?[]const u8 = null,
    /// `RegistrySpec.url` — a git URL to clone from when the Pkg server cannot
    /// serve this registry. Null falls back to `default_registries`' own URL
    /// for a known name, exactly as `populate_known_registries_with_urls!`
    /// fills the field in (`:141-158`).
    ///
    /// Note the precedence, which is Pkg's: a url does NOT override the
    /// server. `Registry.add(RegistrySpec(name = "General", url = ...))`
    /// still installs the server's tarball, because the clone lives in the
    /// `else` of `if url !== nothing && registry_read_from_tarball()`
    /// (`:203`) where `url` is the SERVER's url for the uuid, not this one.
    url: ?[]const u8 = null,
    /// How to run git, for the clone fallback and for updating a cloned
    /// registry. Null means neither is possible; see `Error.GitUnavailable`.
    git: ?git_mod.Backend = null,
    /// Normalised `pkg_server()`. Null = the server is disabled.
    server: ?[]const u8,
    /// Raw `JULIA_PKG_UNPACK_REGISTRY`.
    unpack_env: ?[]const u8 = null,
    /// Resolve and report, write nothing.
    dry_run: bool = false,
    lock: LockOptions = .{},
    /// Zip-bomb guard for the registry archive. General is ~11 MB compressed
    /// and ~84 MB expanded.
    max_download_bytes: usize = 256 * 1024 * 1024,
    max_uncompressed_bytes: usize = 1 << 30,
};

pub const Report = struct {
    name: []const u8,
    uuid: []const u8,
    /// The tree hash now installed (or, on `up_to_date`, already installed).
    /// Empty for a git clone, which has no tree hash — see `Installed`.
    tree_sha1: []const u8,
    action: Action,
    /// Which of the three on-disk shapes the registry now has.
    layout: Installed.Layout = .tarball,
    compressed_bytes: usize = 0,
    /// Every pin the server advertised, in index order. Populated for
    /// `dry_run` so a caller can print the whole index.
    pins: []const Pin = &.{},
};

/// `registry add` / `registry update` for one registry.
///
/// Arena: every string in the `Report` borrows `arena`. The archive itself
/// does NOT — it lives in a scoped arena that is released before returning, so
/// installing several registries in one process does not accumulate 11 MB
/// bodies.
/// Why the Pkg server did not install this registry, i.e. every way Julia
/// reaches `url === nothing` at `:203` and falls through to the clone
/// (`:260-262`). Kept rather than turned into an error immediately, because
/// which error to raise is only known once the clone has also been ruled out.
const Unserved = enum {
    /// `JULIA_PKG_SERVER=""` — `registry_use_pkg_server()` is false.
    server_disabled,
    /// `pkg_server_registry_info()` returned `nothing` after its `@warn`.
    no_server_index,
    /// The index does not list this uuid.
    not_on_server,
    /// No uuid to look up: an unknown name and no `--uuid`. Julia's
    /// `RegistrySpec.uuid` is simply `nothing` here and `get(registry_urls,
    /// nothing, nothing)` misses.
    unknown_registry,

    fn toError(self: Unserved) Error {
        return switch (self) {
            .server_disabled => error.ServerDisabled,
            .no_server_index => error.NoServerIndex,
            .not_on_server => error.RegistryNotOnServer,
            .unknown_registry => error.UnknownRegistry,
        };
    }
};

pub fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *net_http.Client,
    opts: Options,
) !Report {
    // Before the `mkpath`, before the lock, before the index GET. Pkg's own
    // offline short-circuit is `update_registries`' `OFFLINE_MODE[] && return`
    // (`Operations.jl:1629`), which fires at the equivalent point: ahead of
    // `Registry.update` and therefore ahead of everything it would touch.
    //
    // The difference from Pkg is that this is an ERROR rather than a silent
    // return, and it is deliberate. `update_registries` is a step inside a
    // larger operation, so skipping it silently is the right answer there —
    // and `ops/instantiate.zig`'s `ensureRegistry` reproduces exactly that,
    // returning before it ever gets here. Reaching THIS function means someone
    // typed `ajt registry add`/`update`, where the download is the whole of the
    // command; completing "successfully" without doing it would be a lie.
    // (Note Pkg's own `Registry.add` is not offline-aware at all and would
    // download — see the `Config.offline` note in `net/http.zig`.)
    if (client.config.offline) return error.Offline;

    const compressed = try readFromTarball(opts.unpack_env);

    // `isdir(regdir) || mkpath(regdir)` (`:186`), before the lock — the lock
    // lives inside the directory it protects.
    const regdir_path = try std.fs.path.join(arena, &.{ opts.depot, "registries" });
    var regdir = try Io.Dir.cwd().createDirPathOpen(io, regdir_path, .{});
    defer regdir.close(io);

    var lock = try acquireLock(io, regdir, opts.lock);
    defer lock.release(io);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const net_arena = scratch.allocator();

    // Identify the registry BEFORE going to the network, which is also the
    // order Pkg uses: `populate_known_registries_with_urls!` (`:184`) runs
    // ahead of `pkg_server_registry_urls()` (`:189`).
    var name: ?[]const u8 = opts.name;
    if (name) |n| try checkRegistryName(n);
    const known: ?KnownRegistry = if (opts.uuid) |u|
        findKnownByUuid(u)
    else if (name) |n|
        knownByName(n)
    else
        null;
    const uuid: ?[]const u8 = opts.uuid orelse if (known) |k| k.uuid else null;
    if (name == null) {
        if (known) |k| name = k.name;
    }

    // What is already in `registries/` under this name, read once: three
    // different decisions below turn on it.
    const installed: ?Installed = if (name) |n| try readInstalled(net_arena, io, regdir, n) else null;

    // `update` on a git-cloned registry NEVER consults the Pkg server: it is
    // the `elseif isdir(joinpath(reg.path, ".git"))` branch (`:501`), reached
    // only because `reg.tree_info === nothing`, and the whole `registry_urls`
    // lookup above it belongs to the other arm. Asking the server first would
    // also silently replace somebody's clone with a tarball.
    if (opts.mode == .update) {
        if (installed) |inst| {
            if (inst.layout == .git_clone)
                return updateGitClone(gpa, arena, io, opts, regdir_path, name.?);
        }
    }

    const unserved: Unserved = unserved: {
        const server = opts.server orelse break :unserved .server_disabled;
        const u = uuid orelse break :unserved .unknown_registry;

        const pins = fetchIndex(net_arena, client, server) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            // Julia only `@warn`s and carries on with an empty url table
            // (`:83-85`), which lands it in the clone branch. Matching that
            // means a broken proxy degrades to a clone rather than to a
            // failure — and, when there is nothing to clone, this becomes
            // `NoServerIndex` again a few lines below.
            error.NoServerIndex => break :unserved .no_server_index,
            else => return err,
        };
        const pin = findPin(pins, u) orelse break :unserved .not_on_server;
        const url = try tarballUrl(net_arena, server, pin.uuid, pin.tree_sha1);
        // The hash under verification comes from the URL, never from the pin
        // struct: that is the property the whole protocol rests on.
        const expected = try urlHash(url);

        // `update` only touches registries that are already installed
        // (`find_installed_registries`, `:336-376`), and no-ops when the
        // server's hash equals the recorded one (`:447`).
        if (opts.mode == .update) {
            const n = name orelse return error.NotInstalled;
            const inst = installed orelse return error.NotInstalled;
            if (std.mem.eql(u8, inst.tree_sha1, pin.tree_sha1)) {
                return .{
                    .name = try arena.dupe(u8, n),
                    .uuid = try arena.dupe(u8, u),
                    .tree_sha1 = try arena.dupe(u8, pin.tree_sha1),
                    .action = if (opts.dry_run) .would_be_up_to_date else .up_to_date,
                    .layout = inst.layout,
                    .pins = try dupePins(arena, pins),
                };
            }
        }

        if (opts.dry_run) {
            return .{
                .name = try arena.dupe(u8, name orelse ""),
                .uuid = try arena.dupe(u8, u),
                .tree_sha1 = try arena.dupe(u8, pin.tree_sha1),
                .action = if (opts.mode == .add) .would_add else .would_update,
                .layout = if (compressed) .tarball else .directory,
                .pins = try dupePins(arena, pins),
            };
        }

        return try installFromServer(gpa, arena, io, client, opts, .{
            .regdir = regdir,
            .regdir_path = regdir_path,
            .net_arena = net_arena,
            .name = name,
            .uuid = u,
            .url = url,
            .expected = expected,
            .pin = pin,
            .pins = pins,
            .compressed = compressed,
        });
    };

    // `update` never CREATES a registry — `find_installed_registries` filters
    // to what is already on disk (`:336-376`) — so the clone below is an
    // `add`-only fallback. An `update` that gets here is either naming
    // something that is not installed, or is installed as a tarball the
    // server has stopped listing; Pkg silently skips the second (everything
    // under `:449` is guarded on `url !== nothing`), which is a no-op that
    // looks exactly like success, so Ajt reports why instead.
    if (opts.mode == .update) {
        if (installed == null) return error.NotInstalled;
        return unserved.toError();
    }

    // Julia's `else` (`:255-302`) ends in `LibGit2.clone` when a url is known.
    return cloneRegistry(gpa, arena, io, opts, regdir_path, .{
        .url = opts.url orelse if (known) |k| k.url else null,
        .unserved = unserved,
    });
}

/// The Pkg-server tarball install, split out only so `run`'s three-way routing
/// stays readable. Every line below was in `run`.
const ServerInstall = struct {
    regdir: Io.Dir,
    regdir_path: []const u8,
    net_arena: Allocator,
    name: ?[]const u8,
    uuid: []const u8,
    url: []const u8,
    expected: slug.Sha1,
    pin: Pin,
    pins: []const Pin,
    compressed: bool,
};

fn installFromServer(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    client: *net_http.Client,
    opts: Options,
    s: ServerInstall,
) !Report {
    const net_arena = s.net_arena;
    const regdir = s.regdir;
    const url = s.url;
    const expected = s.expected;
    const pin = s.pin;
    const compressed = s.compressed;
    const uuid = s.uuid;
    const name = s.name;

    // ---- download -------------------------------------------------------
    // No retry here, matching Pkg: `retry` wraps `/registries` (`:76`) but the
    // tarball goes through a bare `download_verify` (`:204`).
    const res = client.get(net_arena, url, .{
        .max_body_bytes = opts.max_download_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => return error.DownloadFailed,
    };
    if (!res.ok()) return error.DownloadFailed;
    const gz = res.body;

    // ---- verify ---------------------------------------------------------
    // gunzip once; both the hash and (for the unpacked layout) the extraction
    // read these very bytes, so they cannot describe different trees.
    const tar_bytes = extract.gunzip(gpa, gz, opts.max_uncompressed_bytes) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // Truncated, wrong CRC, or a zip bomb: all "this is not the archive
        // the server pinned".
        else => return error.VerificationFailed,
    };
    defer gpa.free(tar_bytes);

    // `skip_empty = false` is `Tar.tree_hash`'s default and therefore what
    // `verify_archive_tree_hash` uses. Do not "fix" this to match the package
    // installer's pruning default.
    const computed = treehash.hashTar(gpa, tar_bytes, false) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // A `..` component or a symlink-prefixed path. Julia's hasher refuses
        // the same archives outright, so this is a rejected download, not a
        // malformed-tar diagnostic.
        error.UnsafeTarPath, error.ReadFailed, error.NotADirectory => return error.VerificationFailed,
    };
    if (!std.mem.eql(u8, &computed, &expected.bytes)) return error.VerificationFailed;

    // Only now is the archive trustworthy enough to read a name out of -- and
    // "trustworthy" means "the bytes the server pinned", not "safe as a
    // filename", hence the check.
    const reg_name = name orelse blk: {
        const n = try registryNameFromTar(net_arena, tar_bytes);
        try checkRegistryName(n);
        break :blk n;
    };

    // ---- publish --------------------------------------------------------
    if (compressed) {
        try publishCompressed(gpa, io, regdir, reg_name, uuid, pin.tree_sha1, gz);
    } else {
        try publishUnpacked(gpa, arena, io, regdir, s.regdir_path, reg_name, tar_bytes, computed, pin.tree_sha1);
    }

    return .{
        .name = try arena.dupe(u8, reg_name),
        .uuid = try arena.dupe(u8, uuid),
        .tree_sha1 = try arena.dupe(u8, pin.tree_sha1),
        .action = if (opts.mode == .add) .added else .updated,
        .layout = if (compressed) .tarball else .directory,
        .compressed_bytes = gz.len,
        .pins = try dupePins(arena, s.pins),
    };
}

// ---------------------------------------------------------------------------
// The git-clone layout
// ---------------------------------------------------------------------------

/// `update` for a registry that is a git clone (`:501-560`).
///
/// Pkg's branch in order, and the order is the point — each refusal is
/// cheaper and more specific than the one after it, and the fetch happens only
/// once all three have passed:
///
/// ```julia
/// LibGit2.with(LibGit2.GitRepo(reg.path)) do repo
///     if LibGit2.isdirty(repo)                    -> "registry dirty"
///     if !LibGit2.isattached(repo)                -> "registry detached"
///     if !("origin" in LibGit2.remotes(repo))     -> "origin not in the list of remotes"
///     branch = LibGit2.headname(repo)
///     GitTools.fetch(io, repo; refspecs = ["+refs/heads/$branch:refs/remotes/origin/$branch"])
///     ff_succeeded = LibGit2.merge!(repo; branch = "refs/remotes/origin/$branch", fastforward = true)
///     if !ff_succeeded; LibGit2.rebase!(repo, "origin/$branch"); end
/// ```
///
/// Two things NOT ported. Pkg retries the merge up to three times on
/// `ELOCKED`, resetting hard in between (`:531-541`) — that is libgit2's own
/// index lock racing another libgit2 in the same process, which a `git`
/// subprocess handles itself. And `registry_update_log` (`:542`), the cooldown
/// this module already documents as unimplemented.
///
/// The reported `tree_sha1` is empty: a clone has no `tree_info`, and
/// inventing one from `HEAD^{tree}` would write a hash into a report that no
/// stamp on disk agrees with.
fn updateGitClone(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    regdir_path: []const u8,
    name: []const u8,
) !Report {
    const git = opts.git orelse return error.GitUnavailable;
    const path = try std.fs.path.join(arena, &.{ regdir_path, name });

    if (try git.isDirty(gpa, io, path)) return error.DirtyWorktree;
    const branch = (try git.headBranch(gpa, arena, io, path)) orelse return error.DetachedHead;
    const origin = (try git.remoteUrl(gpa, arena, io, path, "origin")) orelse return error.NoOriginRemote;

    const identity = try cloneIdentity(arena, io, path);

    // The three checks above are reads, so a dry run may report them; the
    // fetch is not, and `git fetch` writes objects and refs into `.git`.
    if (opts.dry_run) {
        return .{
            .name = try arena.dupe(u8, identity.name),
            .uuid = try arena.dupe(u8, identity.uuid),
            .tree_sha1 = "",
            .action = .would_update,
            .layout = .git_clone,
        };
    }

    try git.fetch(gpa, io, path, origin, try git_mod.registryRefspec(arena, branch));

    // `merge!(repo; branch = "refs/remotes/origin/$branch")` — the FULL ref,
    // not `origin/$branch`, and then `rebase!` uses the short form. Both
    // spellings are Pkg's own, one line apart (`:527`, `:553`).
    const merge_ref = try std.fmt.allocPrint(arena, "refs/remotes/origin/{s}", .{branch});
    if (!try git.fastForward(gpa, io, path, merge_ref)) {
        const upstream = try std.fmt.allocPrint(arena, "origin/{s}", .{branch});
        try git.rebase(gpa, io, path, upstream);
    }

    return .{
        .name = try arena.dupe(u8, identity.name),
        .uuid = try arena.dupe(u8, identity.uuid),
        .tree_sha1 = "",
        .action = .updated,
        .layout = .git_clone,
    };
}

const Identity = struct { name: []const u8, uuid: []const u8 };

/// A registry directory's own `name` and `uuid`
/// (`registry_instance.jl:357-360`).
///
/// The absence of the file is Pkg's "no `Registry.toml` file in cloned
/// registry" (`:277-279`) — the check that stops a clone of some unrelated
/// repository being installed as a registry.
fn cloneIdentity(arena: Allocator, io: Io, path: []const u8) !Identity {
    const file = try std.fs.path.join(arena, &.{ path, "Registry.toml" });
    const src = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.OutOfMemory => |e| return e,
        else => return error.MalformedRegistry,
    };
    const doc = toml_parse.parse(arena, src, null) catch return error.MalformedRegistry;
    const name = stringField(doc.root, "name") orelse return error.MalformedRegistry;
    try checkRegistryName(name);
    return .{ .name = name, .uuid = stringField(doc.root, "uuid") orelse "" };
}

const CloneRequest = struct {
    /// `RegistrySpec.url`, or null when nothing is known to clone from.
    url: ?[]const u8,
    /// Why the server did not serve this registry — the error to report if
    /// the clone cannot run either.
    unserved: Unserved,
};

/// `LibGit2.clone` into a temp directory, then `mv` it into `registries/`
/// (`:260-297`).
///
/// The staging is Pkg's `mktempdir() do tmp` and its closing `mv(tmp, regpath)`
/// (`:294`), with one difference: the staging directory is a sibling inside
/// `registries/` rather than in `/tmp`, so that publishing is a real
/// `renameat` and not a cross-filesystem copy. `depot.zig`'s installer already
/// owns that pattern, including the `.ajt-tmp-` naming that keeps a
/// half-finished clone from looking like a registry to a concurrent `julia`.
///
/// The name comes from the CLONE, never from `--registry`: Pkg reads
/// `RegistryInstance(tmp).name` and builds `regpath` from that (`:280-282`),
/// so cloning JuliaRegistries/General installs `General/` whatever the caller
/// called it.
fn cloneRegistry(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: Options,
    regdir_path: []const u8,
    req: CloneRequest,
) !Report {
    const url = req.url orelse return req.unserved.toError();
    const git = opts.git orelse return req.unserved.toError();

    if (opts.dry_run) {
        return .{
            .name = try arena.dupe(u8, opts.name orelse ""),
            .uuid = try arena.dupe(u8, opts.uuid orelse ""),
            .tree_sha1 = "",
            .action = .would_add,
            .layout = .git_clone,
        };
    }

    // `begin` creates the staging directory; `git clone` accepts an existing
    // EMPTY one, which is the same assertion Pkg makes (`GitTools.jl:94`).
    var inst = try depot_mod.begin(arena, io, try std.fs.path.join(arena, &.{ regdir_path, "placeholder" }));
    defer inst.deinit(io);
    const staging = try std.fs.path.join(arena, &.{ regdir_path, &inst.tmp_name });

    try git.cloneWorking(gpa, io, staging, url);

    // "verify that the clone looks like a registry" (`:275-279`).
    const identity = try cloneIdentity(arena, io, staging);

    // `if isfile(joinpath(regpath, "Registry.toml"))` (`:280`): a registry
    // already at that path is either the same one — a no-op with a message —
    // or a different one, which Pkg refuses because the name is the only
    // handle either tool has and two registries cannot share it.
    const dest = try std.fs.path.join(arena, &.{ regdir_path, identity.name });
    if (cloneIdentity(arena, io, dest)) |existing| {
        if (!std.mem.eql(u8, existing.uuid, identity.uuid)) return error.RegistryConflict;
        return .{
            .name = try arena.dupe(u8, identity.name),
            .uuid = try arena.dupe(u8, identity.uuid),
            .tree_sha1 = "",
            .action = .already_exists,
            .layout = .git_clone,
        };
    } else |_| {}

    // Publish under the registry's OWN name, which is not the name `begin`
    // was given. `set_readonly = false`: `registries/` stays writable — that
    // is what lets `update` fast-forward the clone in place.
    inst.dest_name = try arena.dupe(u8, identity.name);
    switch (try inst.commit(gpa, io, .{ .set_readonly = false })) {
        .installed => {},
        // A directory is already there. Either somebody published between the
        // check above and this rename, or it is a directory that is not a
        // registry at all — no `Registry.toml`, so `cloneIdentity` said no.
        //
        // **Pkg would replace it**: its `mv(tmp, regpath, force = true)`
        // (`:294`) removes the destination first, and it reaches that line
        // precisely because the `isfile(regpath/Registry.toml)` test failed.
        // Ajt keeps it. Deleting a directory whose contents are unknown is
        // exactly the class of bug that made this unit necessary — the
        // unconditional `deleteTree` in `publishCompressed` that took a git
        // clone's `.git` with it — and "your registry is at a path that
        // already holds something" is a state a human should look at.
        .already_present => return .{
            .name = try arena.dupe(u8, identity.name),
            .uuid = try arena.dupe(u8, identity.uuid),
            .tree_sha1 = "",
            .action = .already_exists,
            .layout = .git_clone,
        },
    }

    return .{
        .name = try arena.dupe(u8, identity.name),
        .uuid = try arena.dupe(u8, identity.uuid),
        .tree_sha1 = "",
        .action = .added,
        .layout = .git_clone,
    };
}

fn findKnownByUuid(uuid: []const u8) ?KnownRegistry {
    for (default_registries) |r| {
        if (std.mem.eql(u8, r.uuid, uuid)) return r;
    }
    return null;
}

fn dupePins(arena: Allocator, pins: []const Pin) Allocator.Error![]Pin {
    const out = try arena.alloc(Pin, pins.len);
    for (pins, out) |src, *dst| dst.* = .{
        .uuid = try arena.dupe(u8, src.uuid),
        .tree_sha1 = try arena.dupe(u8, src.tree_sha1),
    };
    return out;
}

/// Every path this module builds under `registries/` is `<name>` with at most
/// a suffix appended, so `name` has to be a single, ordinary filename.
///
/// **Pkg does not check this.** `joinpath(regdir, reg.name * ".tar.gz")`
/// (`:217`) takes the name straight from the downloaded archive's
/// `Registry.toml` (`:215`), so a registry whose own metadata declares
/// `name = "../../evil"` makes Pkg write outside `registries/` entirely. The
/// tree-hash check does not help: the hash pins the CONTENT, and the content
/// is exactly where the hostile name lives. Ajt refuses instead — the name is
/// attacker-influenced data being used as a path, which is the one shape that
/// always deserves a guard.
fn checkRegistryName(name: []const u8) error{UnsafeRegistryName}!void {
    if (name.len == 0) return error.UnsafeRegistryName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafeRegistryName;
    // A leading dot would also collide with the `.pid` lock and the staging
    // prefix, both of which live in this directory.
    if (name[0] == '.') return error.UnsafeRegistryName;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return error.UnsafeRegistryName;
    }
}

/// `TOML.parse(reg_unc["Registry.toml"])["name"]` (`:215`), without
/// materialising the other ~59,000 files the way `uncompress_registry` does.
fn registryNameFromTar(arena: Allocator, tar_bytes: []const u8) ![]const u8 {
    var reader = Io.Reader.fixed(tar_bytes);
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (it.next() catch return error.MalformedRegistry) |entry| {
        if (entry.kind != .file) continue;
        // A Pkg-server registry tarball has its contents at the top level, but
        // `tar -cf … .` writes the same tree with a `./` prefix; accept both.
        const path = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (!std.mem.eql(u8, path, "Registry.toml")) continue;

        const buf = try arena.alloc(u8, @intCast(entry.size));
        var w = Io.Writer.fixed(buf);
        it.streamRemaining(entry, &w) catch return error.MalformedRegistry;
        const doc = toml_parse.parse(arena, buf, null) catch return error.MalformedRegistry;
        return stringField(doc.root, "name") orelse error.MalformedRegistry;
    }
    return error.MalformedRegistry;
}

// ---------------------------------------------------------------------------
// Publishing
// ---------------------------------------------------------------------------

const tmp_prefix = ".ajt-tmp-";
const tmp_random_bytes = 12;
const tmp_name_len = tmp_prefix.len + std.base64.url_safe_no_pad.Encoder.calcSize(tmp_random_bytes);

/// A staging name inside `registries/`.
///
/// It must be a dotfile that does NOT end in `.toml`: `reachable_registries`
/// treats every `*.toml` in the directory as a registry stamp and every
/// subdirectory as a registry (`registry_instance.jl:436-450`), so a temp file
/// with either shape makes a concurrent `julia` warn about a half-written
/// registry.
fn tmpName(io: Io) [tmp_name_len]u8 {
    var out: [tmp_name_len]u8 = undefined;
    @memcpy(out[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [tmp_random_bytes]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out[tmp_prefix.len..], &random_bytes);
    return out;
}

/// Write `data` to `name` in `dir` through a same-directory staging file, so a
/// reader never observes a truncated or half-written file.
///
/// Julia stages in `tempname()` and `mv`s (`:217`), which crosses filesystems
/// and silently degrades to a non-atomic copy; staging as a sibling keeps the
/// rename a real `renameat`.
fn publishFile(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    const tmp = tmpName(io);
    // The errdefer is armed BEFORE the write, not after: `writeFile` creates
    // the file and then fills it, so a failure partway through an 11 MB
    // tarball (ENOSPC being the realistic one) leaves a partial staging file
    // that nothing would ever collect.
    errdefer dir.deleteFile(io, &tmp) catch {};
    try dir.writeFile(io, .{ .sub_path = &tmp, .data = data });
    try Io.Dir.rename(dir, &tmp, dir, name, io);
}

/// The default layout: `<Name>.tar.gz` plus the `<Name>.toml` stamp
/// (`:217-221`).
///
/// **Order matters.** The tarball is published first and the stamp second,
/// matching Pkg. Both orders have a crash window, but only this one is
/// self-healing: an interrupted run leaves the OLD stamp beside the NEW
/// tarball, so the next `update` sees a hash that differs from the server's
/// and redoes the work. Stamp-first would leave the new hash recorded against
/// old bytes, and `update` would then declare itself up to date forever — and
/// `registry/aix.zig` would key an index built from the old tarball on the new
/// hash.
fn publishCompressed(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    uuid: []const u8,
    tree_sha1: []const u8,
    gz: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tarball_name = try std.fmt.allocPrint(a, "{s}.tar.gz", .{name});
    const stamp_name = try std.fmt.allocPrint(a, "{s}.toml", .{name});
    const stamp = try regInfoToml(a, gpa, uuid, tree_sha1, tarball_name);

    try publishFile(io, dir, tarball_name, gz);
    try publishFile(io, dir, stamp_name, stamp);

    // "If we have an uncompressed Pkg server registry, remove it and get the
    // compressed version" (`:464-467`). `reachable_registries` already
    // prefers the stamp over a same-named directory, so this only reclaims
    // space — but leaving ~84 MB of shadowed files behind is its own bug.
    //
    // **Only an unpacked Pkg-server registry may be removed.** Pkg reaches
    // that `rm` from inside `if reg.tree_info !== nothing`, and `tree_info` is
    // set only by the `.tree_info.toml` layout (`registry_instance.jl:337-342`);
    // a registry that is a **git clone** has `tree_info === nothing` and takes
    // the `elseif isdir(joinpath(reg.path, ".git"))` branch (`:501`), which
    // removes nothing. Ajt deleted unconditionally, so `ajt registry add
    // General` against a depot whose `registries/General/` was a git clone
    // destroyed the clone — `.git`, local branches, remotes and any
    // `setprotocol!` configuration with it. Nothing would report it: the
    // tarball published above works, so the run reports success and the loss
    // surfaces only the next time somebody uses the clone.
    if (try isUnpackedRegistryDir(io, dir, name)) dir.deleteTree(io, name) catch {};
}

/// Is `dir/<name>/` an unpacked Pkg-server registry — the one shape
/// `publishCompressed` is allowed to delete?
///
/// The test is the presence of `.tree_info.toml`, which is what gives Pkg's
/// `RegistryInstance` a non-`nothing` `tree_info` (`registry_instance.jl:337-342`)
/// and therefore the only thing that puts a directory on the removable side of
/// `Registry.jl:463-465`. Anything else — a git clone, a symlink to a
/// hand-maintained registry, a directory that is not a registry at all — is
/// left alone. A missing directory answers false, which is the common case.
fn isUnpackedRegistryDir(io: Io, dir: Io.Dir, name: []const u8) !bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "{s}/.tree_info.toml", .{name}) catch return false;
    _ = dir.statFile(io, info, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return false,
    };
    return true;
}

/// `JULIA_PKG_UNPACK_REGISTRY`: `registries/<Name>/` as a real directory with
/// a `.tree_info.toml` inside (`:242-251`).
///
/// The extraction is staged and published by `renameat`, using `depot.zig`'s
/// installer with `set_readonly = false` — Pkg leaves `registries/` writable
/// (that is what lets `update` rewrite it in place), unlike `packages/` and
/// `artifacts/`.
fn publishUnpacked(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    dir_path: []const u8,
    name: []const u8,
    tar_bytes: []const u8,
    expected: treehash.Hash,
    tree_sha1: []const u8,
) !void {
    const dest = try std.fs.path.join(arena, &.{ dir_path, name });

    var inst = try depot_mod.begin(arena, io, dest);
    defer inst.deinit(io);

    // `skip_empty = false` again: the tree being reproduced is the one
    // `Tar.tree_hash` named in the URL.
    extract.verifyAndExtractTar(gpa, io, tar_bytes, expected, inst.dir, .{
        .shape = .top_level,
        .skip_empty = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // `ExtractFailed` is the one case where the content DID verify and the
        // filesystem refused it (`install/extract.zig`). Reporting that as
        // `VerificationFailed` would tell the user their registry mirror is
        // serving corrupt bytes when the real problem is a full disk.
        error.ExtractFailed => |e| return e,
        else => return error.VerificationFailed,
    };

    // `write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))`
    // (`:251`, and `:495` on the update path) — no trailing newline, which is
    // what `repr` of a String produces. Written into the STAGING directory so
    // it is published by the same rename as the content.
    const tree_info = try std.fmt.allocPrint(arena, "git-tree-sha1 = \"{s}\"", .{tree_sha1});
    try inst.dir.writeFile(io, .{ .sub_path = ".tree_info.toml", .data = tree_info });

    // Replacing an existing tree: POSIX `rename` refuses a non-empty
    // destination, so the old one is moved aside first and deleted only once
    // the new one is live.
    //
    // This REPLACES unconditionally, which matches `update` (`:496`) but not
    // `add`: `download_registries` only reaches its `mv` when the destination
    // has no `Registry.toml` (`:292-294`), and otherwise prints
    // "Registry `X` already exists" and leaves the old tree alone
    // (`:275-291`). Ajt replaces in both modes deliberately — a re-`add` that
    // silently keeps stale content is the more surprising behaviour, and the
    // content is hash-pinned either way.
    const aside = tmpName(io);
    const had_old = if (dir.statFile(io, name, .{})) |_| true else |_| false;
    if (had_old) try Io.Dir.rename(dir, name, dir, &aside, io);
    // Only reachable before `commit`'s own rename: `set_readonly = false`
    // leaves nothing after it that can fail except `error.Canceled`. Should
    // that happen the aside survives as a `.ajt-tmp-*` directory rather than
    // being lost.
    errdefer if (had_old) {
        Io.Dir.rename(dir, &aside, dir, name, io) catch {};
    };

    switch (try inst.commit(gpa, io, .{ .set_readonly = false })) {
        .installed => if (had_old) dir.deleteTree(io, &aside) catch {},
        // The destination was moved aside a moment ago, so this means another
        // process published there while holding no lock. Their tree stays;
        // ours is discarded by `commit`. Restore nothing — deleting the aside
        // would be correct only if ours had won.
        .already_present => if (had_old) dir.deleteTree(io, &aside) catch {},
    }

    // An unpacked registry and a stamp for the same name must not coexist:
    // `reachable_registries` drops the directory in favour of the stamp
    // (`registry_instance.jl:448-449`), which would point at a tarball this
    // run did not write. Remove BOTH the stamp and the tarball it names —
    // `registry/tarball.zig`'s `loadFromDepot` opens `<Name>.tar.gz` by name
    // with no reference to the stamp, so a leftover archive would keep being
    // served as the current registry by `ajt registry status|show|index`.
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}.toml", .{name})) |stamp_name| {
        dir.deleteFile(io, stamp_name) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}.tar.gz", .{name})) |tarball_name| {
        dir.deleteFile(io, tarball_name) catch {};
    } else |_| {}
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the /registries index parses exactly the lines Pkg matches" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const general = "23338594-aafe-5451-b93e-139f81909106";
    const h1 = "c75cb0b99296cb6306fa8e99184bb7495ca20adf";
    const h2 = "246a8bb2e6667f832eea063c3a56aef96429a3db";
    const other = "90137ffa-7385-5640-81b9-e52037218182";

    const body =
        "/registry/" ++ general ++ "/" ++ h1 ++ "\r\n" ++
        "/registry/" ++ other ++ "/" ++ h2 ++ "\n" ++
        // Not a match: extra segment, missing segment, wrong prefix, blank.
        "/registry/" ++ general ++ "/" ++ h1 ++ "/extra\n" ++
        "/registry/" ++ general ++ "\n" ++
        "/pkg/" ++ general ++ "/" ++ h1 ++ "\n" ++
        "\n";

    const pins = try parseIndex(arena, body);
    try testing.expectEqual(@as(usize, 2), pins.len);
    try testing.expectEqualStrings(general, pins[0].uuid);
    try testing.expectEqualStrings(h1, pins[0].tree_sha1);
    try testing.expectEqualStrings(other, pins[1].uuid);
    try testing.expect(findPin(pins, general) != null);
    try testing.expect(findPin(pins, "nope") == null);

    // `registry_info[uuid] = hash` into a Dict: the last line for a UUID wins.
    const dup = try parseIndex(
        arena,
        "/registry/" ++ general ++ "/" ++ h1 ++ "\n/registry/" ++ general ++ "/" ++ h2 ++ "\n",
    );
    try testing.expectEqual(@as(usize, 1), dup.len);
    try testing.expectEqualStrings(h2, dup[0].tree_sha1);

    // A line that MATCHES the regex but whose captures are not a UUID/SHA1 is
    // where Julia's constructors throw.
    try testing.expectError(
        error.MalformedServerIndex,
        parseIndex(arena, "/registry/not-a-uuid/" ++ h1 ++ "\n"),
    );
    try testing.expectError(
        error.MalformedServerIndex,
        parseIndex(arena, "/registry/" ++ general ++ "/nothex\n"),
    );
}

test "the verified hash comes from the URL's last segment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uuid = "23338594-aafe-5451-b93e-139f81909106";
    const hash = "c75cb0b99296cb6306fa8e99184bb7495ca20adf";
    const url = try tarballUrl(arena, "https://pkg.julialang.org", uuid, hash);
    try testing.expectEqualStrings(
        "https://pkg.julialang.org/registry/" ++
            "23338594-aafe-5451-b93e-139f81909106/c75cb0b99296cb6306fa8e99184bb7495ca20adf",
        url,
    );
    const parsed = try urlHash(url);
    try testing.expectEqualStrings(hash, &treehash.toHex(parsed.bytes));
    try testing.expectError(error.VerificationFailed, urlHash("https://x/registry/u/short"));
}

test "JULIA_PKG_UNPACK_REGISTRY follows Base.get_bool_env exactly" {
    // Oracle: `ENV["X"] = v; Base.get_bool_env("X", false)`.
    try testing.expect(try readFromTarball(null));
    try testing.expect(try readFromTarball("")); // empty -> the default (false)
    try testing.expect(try readFromTarball("false"));
    try testing.expect(try readFromTarball("0"));
    try testing.expect(!(try readFromTarball("true")));
    try testing.expect(!(try readFromTarball("TRUE")));
    try testing.expect(!(try readFromTarball("yes")));
    try testing.expect(!(try readFromTarball("1")));
    try testing.expect(!(try readFromTarball("t")));
    // Only lowercase / Capitalized / UPPERCASE spellings are recognised.
    try testing.expectError(error.InvalidUnpackSetting, readFromTarball("tRue"));
    // And `registry_read_from_tarball()` raises a MethodError on this input.
    try testing.expectError(error.InvalidUnpackSetting, readFromTarball("garbage"));
}

test "the registry stamp round-trips through Pkg's three required keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try regInfoToml(
        arena,
        testing.allocator,
        "23338594-aafe-5451-b93e-139f81909106",
        "c75cb0b99296cb6306fa8e99184bb7495ca20adf",
        "General.tar.gz",
    );
    // Sorted, unlike Julia's Dict order (git-tree-sha1, uuid, path). See
    // `regInfoToml`'s comment: the value is what Pkg reads, and the order is
    // an artefact of its hash table.
    try testing.expectEqualStrings(
        \\git-tree-sha1 = "c75cb0b99296cb6306fa8e99184bb7495ca20adf"
        \\path = "General.tar.gz"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
    , body);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "General.toml", .data = body });

    // The stamp ALONE is not an installed registry: `verify_compressed_registry_toml`
    // also requires the tarball it names to exist (`registry_instance.jl:422-426`).
    // Reporting "installed" here would let `update` answer `up_to_date` for a
    // registry Pkg refuses to load.
    try testing.expect((try readInstalled(arena, testing.io, tmp.dir, "General")) == null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "General.tar.gz", .data = "not really gzip" });
    const got = (try readInstalled(arena, testing.io, tmp.dir, "General")).?;
    try testing.expectEqual(Installed.Layout.tarball, got.layout);
    try testing.expectEqualStrings("23338594-aafe-5451-b93e-139f81909106", got.uuid);
    try testing.expectEqualStrings("c75cb0b99296cb6306fa8e99184bb7495ca20adf", got.tree_sha1);
    try testing.expectEqualStrings("General.tar.gz", got.path);

    // The unpacked layout is recognised too, via the `.tree_info.toml` that
    // `publishUnpacked` writes — the file that `update` needs to see and that
    // nothing read before (`registry_instance.jl:337-342`).
    try tmp.dir.createDirPath(testing.io, "Unpacked");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Unpacked/.tree_info.toml",
        .data = "git-tree-sha1 = \"c75cb0b99296cb6306fa8e99184bb7495ca20adf\"",
    });
    const dir_reg = (try readInstalled(arena, testing.io, tmp.dir, "Unpacked")).?;
    try testing.expectEqual(Installed.Layout.directory, dir_reg.layout);
    try testing.expectEqualStrings("c75cb0b99296cb6306fa8e99184bb7495ca20adf", dir_reg.tree_sha1);

    // A name Ajt refuses to turn into a path never reaches the filesystem.
    try testing.expectError(error.UnsafeRegistryName, checkRegistryName("../../evil"));
    try testing.expectError(error.UnsafeRegistryName, checkRegistryName(".pid"));
    try testing.expectError(error.UnsafeRegistryName, checkRegistryName(""));
    try testing.expectError(error.UnsafeRegistryName, checkRegistryName(".."));
    try checkRegistryName("General");

    try testing.expect((try readInstalled(arena, testing.io, tmp.dir, "Missing")) == null);
    // A stamp missing any of the three keys is not one Pkg would load.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Partial.toml", .data = "uuid = \"x\"\n" });
    try testing.expect((try readInstalled(arena, testing.io, tmp.dir, "Partial")) == null);
    // A `path` that escapes `registries/` is refused rather than stat'ed.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Escape.toml",
        .data =
        \\git-tree-sha1 = "c75cb0b99296cb6306fa8e99184bb7495ca20adf"
        \\path = "../../../etc/passwd"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        ,
    });
    try testing.expect((try readInstalled(arena, testing.io, tmp.dir, "Escape")) == null);
}

test "an upper-case index line is canonicalised the way Julia's UUID/SHA1 are" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Oracle: `println(Base.UUID("23338594-AAFE-…"))` and
    // `println(Base.SHA1("C75CB0…"))` both print lower-case, and Julia
    // interpolates those VALUES into the download URL (`:105`).
    const pins = try parseIndex(
        arena,
        "/registry/23338594-AAFE-5451-B93E-139F81909106/C75CB0B99296CB6306FA8E99184BB7495CA20ADF\n",
    );
    try testing.expectEqual(@as(usize, 1), pins.len);
    try testing.expectEqualStrings("23338594-aafe-5451-b93e-139f81909106", pins[0].uuid);
    try testing.expectEqualStrings("c75cb0b99296cb6306fa8e99184bb7495ca20adf", pins[0].tree_sha1);
    // ...so the built-in General entry still matches, and the URL is the one
    // Julia would have requested.
    try testing.expect(findPin(pins, default_registries[0].uuid) != null);
    try testing.expectEqualStrings(
        "https://s/registry/23338594-aafe-5451-b93e-139f81909106/" ++
            "c75cb0b99296cb6306fa8e99184bb7495ca20adf",
        try tarballUrl(arena, "https://s", pins[0].uuid, pins[0].tree_sha1),
    );
}

test "the pidfile is byte-compatible with mkpidlock and excludes a second holder" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var lock = try acquireLock(io, tmp.dir, .{ .poll_ms = 1, .timeout_ms = 50, .refresh_s = 0 });

    // `"$pid $(gethostname())"`, no newline.
    var buf: [512]u8 = undefined;
    const body = try tmp.dir.readFile(io, Lock.file_name, &buf);
    const sp = std.mem.indexOfScalar(u8, body, ' ').?;
    try testing.expectEqual(currentPid(), try std.fmt.parseInt(i64, body[0..sp], 10));
    var host_buf: [max_hostname]u8 = undefined;
    try testing.expectEqualStrings(hostname(&host_buf), body[sp + 1 ..]);
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);

    // A live local pid is never stolen, so a second acquisition must time out
    // rather than corrupt the directory.
    try testing.expectError(
        error.RegistryLocked,
        acquireLock(io, tmp.dir, .{ .poll_ms = 1, .timeout_ms = 30, .stale_age_s = 0 }),
    );

    lock.release(io);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, Lock.file_name, .{}));
    // Idempotent: the second release is a no-op, not a double close.
    lock.release(io);

    // Now it is free again.
    var again = try acquireLock(io, tmp.dir, .{ .poll_ms = 1, .timeout_ms = 50, .refresh_s = 0 });
    again.release(io);
}

test "a stale pidfile is stolen, a fresh one is not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // pid 0 is never valid (`pidfile.jl:187`), so this lock is stealable as
    // soon as `age > stale_age` -- no need to wait out the 5x window.
    try tmp.dir.writeFile(io, .{ .sub_path = Lock.file_name, .data = "0 nowhere.invalid" });
    // Backdate it well past `stale_age`.
    {
        const f = try tmp.dir.openFile(io, Lock.file_name, .{ .mode = .read_write });
        defer f.close(io);
        const now = Io.Timestamp.now(io, .real);
        try f.setTimestamps(io, .{
            .access_timestamp = .{ .new = now },
            .modify_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - 3600 * std.time.ns_per_s } },
        });
    }
    var lock = try acquireLock(io, tmp.dir, .{ .poll_ms = 1, .timeout_ms = 2000, .refresh_s = 0 });
    lock.release(io);

    // A pidfile naming a foreign host is "can't inspect remote hosts" -> valid
    // (`pidfile.jl:182`), so within the 5x window it must NOT be stolen.
    try tmp.dir.writeFile(io, .{ .sub_path = Lock.file_name, .data = "1 some-other-host.invalid" });
    {
        const f = try tmp.dir.openFile(io, Lock.file_name, .{ .mode = .read_write });
        defer f.close(io);
        const now = Io.Timestamp.now(io, .real);
        try f.setTimestamps(io, .{
            .access_timestamp = .{ .new = now },
            .modify_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - 20 * std.time.ns_per_s } },
        });
    }
    try testing.expectError(
        // age 20 > stale_age 10, but not > 50, and the pid is on another host.
        error.RegistryLocked,
        acquireLock(io, tmp.dir, .{ .poll_ms = 1, .timeout_ms = 30 }),
    );
    try tmp.dir.deleteFile(io, Lock.file_name);
}

// ---------------------------------------------------------------------------
// End-to-end against a loopback Pkg server.
//
// The install path is the one place where the index, the tarball URL, the
// tree-hash verification and the on-disk layout all have to agree, and none of
// that is observable from the individual pieces. A scripted local server makes
// the whole thing testable with no network and no real depot.
// ---------------------------------------------------------------------------

/// Builds a minimal ustar archive; same shape as the builders in
/// `registry/tarball.zig`'s tests.
fn buildTar(buf: []u8, entries: []const struct { name: []const u8, data: []const u8 }) []u8 {
    @memset(buf, 0);
    var off: usize = 0;
    for (entries) |e| {
        const h = buf[off..][0..512];
        @memcpy(h[0..e.name.len], e.name);
        _ = std.fmt.bufPrint(h[100..][0..8], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
        _ = std.fmt.bufPrint(h[108..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[116..][0..8], "{o:0>7}", .{@as(u32, 0)}) catch unreachable;
        _ = std.fmt.bufPrint(h[124..][0..12], "{o:0>11}", .{e.data.len}) catch unreachable;
        _ = std.fmt.bufPrint(h[136..][0..12], "{o:0>11}", .{@as(u32, 0)}) catch unreachable;
        h[156] = '0';
        @memcpy(h[257..][0..6], "ustar\x00");
        @memcpy(h[263..][0..2], "00");
        @memset(h[148..][0..8], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..][0..7], "{o:0>6}\x00", .{sum}) catch unreachable;
        off += 512;
        @memcpy(buf[off..][0..e.data.len], e.data);
        off += std.mem.alignForward(usize, e.data.len, 512);
    }
    off += 1024;
    return buf[0..off];
}

fn gzipOf(gpa: Allocator, raw: []const u8) ![]u8 {
    // `Compress.init` asserts the sink has a buffer of more than 8 bytes, and
    // a default `Allocating` starts with none -- hence `initCapacity`.
    var out: Io.Writer.Allocating = try .initCapacity(gpa, raw.len + 1024);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var comp = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    return out.toOwnedSlice();
}

/// Serves a fixed script of raw HTTP responses, one per connection. Every
/// response must close the connection, or the client keeps it pooled and both
/// sides block — see the longer note in `net/http.zig`'s test section.
const ScriptedServer = struct {
    server: Io.net.Server,
    port: u16,
    requests: usize = 0,

    const port_base = 40871;
    const port_span = 500;
    var next_offset: std.atomic.Value(u16) = .init(0);

    fn start(io: Io) !ScriptedServer {
        const first = next_offset.fetchAdd(1, .monotonic);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // An EXCLUSIVE bind: `reuse_address` would set SO_REUSEPORT, under
            // which a second `listen` on a live port succeeds and the kernel
            // load-balances connections between the two servers. See the long
            // note on `LoopbackServer.start` in `src/net/http.zig`.
            const srv = addr.listen(io, .{}) catch continue;
            return .{ .server = srv, .port = port };
        }
        return error.NoFreePort;
    }

    fn deinit(self: *ScriptedServer, io: Io) void {
        self.server.deinit(io);
    }

    fn serve(io: Io, self: *ScriptedServer, script: []const []const u8) void {
        for (script) |response| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            const r = &sr.interface;
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            self.requests += 1;

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            sw.interface.writeAll(response) catch {};
            sw.interface.flush() catch {};
        }
    }
};

fn okResponse(gpa: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
}

const Fixture = struct {
    tar: []u8,
    gz: []u8,
    hash_hex: [40]u8,
    index_body: []u8,

    const uuid = "23338594-aafe-5451-b93e-139f81909106";

    fn init(gpa: Allocator) !Fixture {
        const raw = try gpa.alloc(u8, 16384);
        defer gpa.free(raw);
        const tar_bytes = buildTar(raw, &.{
            .{ .name = "Registry.toml", .data =
            \\name = "General"
            \\uuid = "23338594-aafe-5451-b93e-139f81909106"
            \\
            \\[packages]
            \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
            \\
            },
            .{ .name = "D/Demo/Versions.toml", .data = "[\"1.0.0\"]\ngit-tree-sha1 = \"aaaa\"\n" },
        });
        const tar = try gpa.dupe(u8, tar_bytes);
        errdefer gpa.free(tar);

        // The pin is derived FROM the fixture, exactly as the server derives
        // it from the snapshot it is serving.
        const hash = try treehash.hashTar(gpa, tar, false);
        const hash_hex = treehash.toHex(hash);
        const gz = try gzipOf(gpa, tar);
        errdefer gpa.free(gz);
        const index_body = try std.fmt.allocPrint(gpa, "/registry/{s}/{s}\n", .{ uuid, &hash_hex });
        return .{ .tar = tar, .gz = gz, .hash_hex = hash_hex, .index_body = index_body };
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        gpa.free(self.tar);
        gpa.free(self.gz);
        gpa.free(self.index_body);
    }
};

test "add installs the compressed layout and update then no-ops" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    const index_res = try okResponse(arena, fixture.index_body);
    const tarball_res = try okResponse(arena, fixture.gz);
    // add: index + tarball. update: index only (the hash matches).
    const script = [_][]const u8{ index_res, tarball_res, index_res };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    const added = try run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    try testing.expectEqual(Action.added, added.action);
    try testing.expectEqualStrings("General", added.name);
    try testing.expectEqualStrings(&fixture.hash_hex, added.tree_sha1);

    // The tarball landed verbatim...
    const on_disk = try tmp.dir.readFileAlloc(io, "registries/General.tar.gz", arena, .limited(1 << 20));
    try testing.expectEqualSlices(u8, fixture.gz, on_disk);
    // ...and the stamp names it.
    var regdir = try tmp.dir.openDir(io, "registries", .{});
    defer regdir.close(io);
    const stamp = (try readInstalled(arena, io, regdir, "General")).?;
    try testing.expectEqualStrings(&fixture.hash_hex, stamp.tree_sha1);
    try testing.expectEqualStrings("General.tar.gz", stamp.path);
    try testing.expectEqualStrings(Fixture.uuid, stamp.uuid);
    // The lock was released, and no staging file was left behind.
    try expectNoLeftovers(io, tmp.dir);

    const updated = try run(gpa, arena, io, &client, .{
        .mode = .update,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    try testing.expectEqual(Action.up_to_date, updated.action);

    task.await(io);
    // Three requests, not four: the up-to-date check short-circuits before
    // the tarball GET.
    try testing.expectEqual(@as(usize, 3), srv.requests);
}

test "offline refuses before creating registries/ or taking the lock" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    // Exactly the two responses ONE successful `add` needs, and the offline
    // call must consume neither: if it made a request, the online call below
    // would come up a response short and the server task would never finish.
    const index_res = try okResponse(arena, fixture.index_body);
    const tarball_res = try okResponse(arena, fixture.gz);
    const script = [_][]const u8{ index_res, tarball_res };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{
        .server = server,
        .depot = depot,
        .offline = true,
    });
    defer client.deinit();

    const opts: Options = .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    };
    try testing.expectError(error.Offline, run(gpa, arena, io, &client, opts));
    try testing.expectEqual(@as(usize, 0), srv.requests);
    // Nothing was written — not even the directory. `mkpath` runs BEFORE the
    // lock and would otherwise leave an empty `registries/` in a depot the
    // user asked us not to touch.
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "registries", .{}));

    // The landmark: the identical call succeeds against the identical server
    // once the flag is cleared, so the refusal above is the flag's doing and
    // not a broken fixture.
    client.config.offline = false;
    const added = try run(gpa, arena, io, &client, opts);
    task.await(io);
    try testing.expectEqual(Action.added, added.action);
    try testing.expectEqual(@as(usize, 2), srv.requests);
}

fn expectNoLeftovers(io: Io, root: Io.Dir) !void {
    var dir = try root.openDir(io, "registries", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        try testing.expect(!std.mem.startsWith(u8, e.name, tmp_prefix));
        try testing.expect(!std.mem.eql(u8, e.name, Lock.file_name));
    }
}

test "a corrupted tarball is rejected and nothing is written" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    // Same archive, one byte of CONTENT flipped, recompressed: it still
    // decompresses and is still a valid tar, so only the tree hash can catch
    // it. (Corrupting the gzip bytes would be caught by the CRC instead,
    // which tests std, not this module.)
    const tampered_tar = try gpa.dupe(u8, fixture.tar);
    defer gpa.free(tampered_tar);
    const marker = std.mem.indexOf(u8, tampered_tar, "aaaa").?;
    tampered_tar[marker] = 'b';
    const tampered_gz = try gzipOf(gpa, tampered_tar);
    defer gpa.free(tampered_gz);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    const script = [_][]const u8{
        try okResponse(arena, fixture.index_body),
        try okResponse(arena, tampered_gz),
    };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    try testing.expectError(error.VerificationFailed, run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    }));
    task.await(io);

    // registries/ exists (it is created before the lock) but holds nothing:
    // no tarball, no stamp, no staging file, and the lock was released.
    var dir = try tmp.dir.openDir(io, "registries", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "the unpacked layout extracts, stamps .tree_info.toml and stays writable" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    const script = [_][]const u8{
        try okResponse(arena, fixture.index_body),
        try okResponse(arena, fixture.gz),
    };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    const rep = try run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .unpack_env = "true",
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    task.await(io);
    try testing.expectEqual(Installed.Layout.directory, rep.layout);

    const reg_toml = try tmp.dir.readFileAlloc(io, "registries/General/Registry.toml", arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, reg_toml, "name = \"General\"") != null);

    // `write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))`: no
    // trailing newline.
    const tree_info = try tmp.dir.readFileAlloc(io, "registries/General/.tree_info.toml", arena, .limited(4096));
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "git-tree-sha1 = \"{s}\"", .{&fixture.hash_hex}),
        tree_info,
    );

    // Pkg keeps registries/ WRITABLE -- that is what lets `update` rewrite it
    // in place -- unlike packages/ and artifacts/.
    try testing.expect(!(try tmp.dir.statFile(io, "registries/General/Registry.toml", .{})).permissions.readOnly());
    // No stamp file: a directory and a stamp for the same name must not
    // coexist.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "registries/General.toml", .{}));
}

test "switching layouts leaves exactly one registry, and update still works" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    const index_res = try okResponse(arena, fixture.index_body);
    const tarball_res = try okResponse(arena, fixture.gz);
    // compressed add, then unpacked add, then update.
    const script = [_][]const u8{ index_res, tarball_res, index_res, tarball_res, index_res };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    const base: Options = .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    };

    _ = try run(gpa, arena, io, &client, base);
    _ = try tmp.dir.statFile(io, "registries/General.tar.gz", .{});

    var unpacked = base;
    unpacked.unpack_env = "true";
    _ = try run(gpa, arena, io, &client, unpacked);

    // The tarball from the first install must be GONE. `tarball.zig`'s
    // `loadFromDepot` opens `<Name>.tar.gz` by name with no reference to the
    // stamp, so a leftover would keep being served as the current registry
    // even though the directory beside it is what is actually installed.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "registries/General.tar.gz", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "registries/General.toml", .{}));
    _ = try tmp.dir.statFile(io, "registries/General/.tree_info.toml", .{});

    // And `update` must still recognise the registry. Before `readInstalled`
    // learned the unpacked layout this returned `error.NotInstalled` forever:
    // `publishUnpacked` deletes `<Name>.toml`, and `.tree_info.toml` — the one
    // file it writes — was the one file nothing read.
    var upd = unpacked;
    upd.mode = .update;
    const rep = try run(gpa, arena, io, &client, upd);
    task.await(io);
    try testing.expectEqual(Action.up_to_date, rep.action);
    try testing.expectEqualStrings(&fixture.hash_hex, rep.tree_sha1);
}

test "a git-cloned registry survives an add that publishes the tarball beside it" {
    // The regression this exists for: `publishCompressed` ended in an
    // unconditional `deleteTree(name)`, so installing the compressed registry
    // into a depot whose `registries/General/` was a git clone deleted the
    // clone — `.git` included. Pkg cannot do this: its `rm` sits inside
    // `if reg.tree_info !== nothing`, and a git clone has no `tree_info`.
    //
    // Nothing about the run looked wrong. The tarball published, the stamp
    // published, `run` returned `.installed`, and the loss was only visible to
    // whoever next tried to use the clone.
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    const index_res = try okResponse(arena, fixture.index_body);
    const tarball_res = try okResponse(arena, fixture.gz);
    const script = [_][]const u8{ index_res, tarball_res };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // A registry in the git-clone shape: `Registry.toml` plus a `.git`, and
    // deliberately NO `.tree_info.toml` — that absence is the whole signal.
    try tmp.dir.createDirPath(io, "registries/General/.git/refs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "registries/General/Registry.toml",
        .data = "name = \"General\"\nuuid = \"23338594-aafe-5451-b93e-139f81909106\"\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "registries/General/.git/HEAD", .data = "ref: refs/heads/master\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "registries/General/.git/config", .data = "[remote \"origin\"]\n" });

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    _ = try run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    task.await(io);

    // The compressed registry is installed...
    _ = try tmp.dir.statFile(io, "registries/General.tar.gz", .{});
    _ = try tmp.dir.statFile(io, "registries/General.toml", .{});
    // ...and every byte of the clone is still there.
    _ = try tmp.dir.statFile(io, "registries/General/.git/HEAD", .{});
    _ = try tmp.dir.statFile(io, "registries/General/.git/config", .{});
    _ = try tmp.dir.statFile(io, "registries/General/Registry.toml", .{});
}

test "an unpacked Pkg-server registry IS still reclaimed" {
    // The other half of the guard: narrowing the delete must not turn it off.
    // `tarball.zig:loadFromDepot` opens `<Name>.tar.gz` by name, so a leftover
    // unpacked tree beside a new tarball is ~84 MB of shadowed files.
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var regdir = try tmp.dir.createDirPathOpen(io, "registries", .{});
    defer regdir.close(io);

    try tmp.dir.createDirPath(io, "registries/General");
    try tmp.dir.writeFile(io, .{
        .sub_path = "registries/General/.tree_info.toml",
        .data = "git-tree-sha1 = \"0000000000000000000000000000000000000000\"\n",
    });
    try testing.expect(try isUnpackedRegistryDir(io, regdir, "General"));

    try publishCompressed(gpa, io, regdir, "General", "23338594-aafe-5451-b93e-139f81909106", "0000000000000000000000000000000000000000", "gz-bytes");

    _ = try tmp.dir.statFile(io, "registries/General.tar.gz", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "registries/General/.tree_info.toml", .{}));

    // And the predicate says no for the two shapes that must be left alone:
    // a git clone, and a directory that is not there at all.
    try testing.expect(!try isUnpackedRegistryDir(io, regdir, "Missing"));
    try tmp.dir.createDirPath(io, "registries/Private/.git");
    try testing.expect(!try isUnpackedRegistryDir(io, regdir, "Private"));
}

test "a dry run resolves the pin and writes nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    const script = [_][]const u8{try okResponse(arena, fixture.index_body)};
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    const rep = try run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .dry_run = true,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    task.await(io);

    try testing.expectEqual(Action.would_add, rep.action);
    try testing.expectEqualStrings(&fixture.hash_hex, rep.tree_sha1);
    try testing.expectEqual(@as(usize, 1), rep.pins.len);
    try testing.expectEqualStrings(Fixture.uuid, rep.pins[0].uuid);
    // Exactly one request: the tarball was never fetched.
    try testing.expectEqual(@as(usize, 1), srv.requests);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "registries/General.tar.gz", .{}));
}

// ---------------------------------------------------------------------------
// The git-clone layout.
// ---------------------------------------------------------------------------

test "readInstalled tells a git clone from the other two layouts" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const reg_toml = "name = \"X\"\nuuid = \"23338594-aafe-5451-b93e-139f81909106\"\n";

    // The real shape: a Registry.toml and a `.git` DIRECTORY, and no
    // `.tree_info.toml` — `tree_info === nothing` is what routes `update` to
    // git rather than to the server (`Registry.jl:501`).
    try tmp.dir.createDirPath(io, "Cloned/.git/refs");
    try tmp.dir.writeFile(io, .{ .sub_path = "Cloned/Registry.toml", .data = reg_toml });
    const cloned = (try readInstalled(arena, io, tmp.dir, "Cloned")).?;
    try testing.expectEqual(Installed.Layout.git_clone, cloned.layout);
    // No tree hash exists for a clone, and inventing one would make `update`
    // compare it against the server's pin and answer `up_to_date`.
    try testing.expectEqualStrings("", cloned.tree_sha1);

    // A repository that is not a registry: `reachable_registries` requires the
    // `Registry.toml` (`registry_instance.jl:439-441`).
    try tmp.dir.createDirPath(io, "JustARepo/.git");
    try testing.expect((try readInstalled(arena, io, tmp.dir, "JustARepo")) == null);

    // `.git` as a FILE is a linked worktree or a submodule. Pkg's test is
    // `isdir`, so this is not a git registry for it either.
    try tmp.dir.createDirPath(io, "Linked");
    try tmp.dir.writeFile(io, .{ .sub_path = "Linked/Registry.toml", .data = reg_toml });
    try tmp.dir.writeFile(io, .{ .sub_path = "Linked/.git", .data = "gitdir: /elsewhere\n" });
    try testing.expect((try readInstalled(arena, io, tmp.dir, "Linked")) == null);

    // A stamp beside the clone wins, because `reachable_registries` drops any
    // directory whose basename matches a `*.toml` (`:436-439`). Reading the
    // clone instead would update over git a registry Pkg reads as a tarball.
    try tmp.dir.writeFile(io, .{ .sub_path = "Cloned.tar.gz", .data = "gz" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Cloned.toml", .data =
        \\git-tree-sha1 = "c75cb0b99296cb6306fa8e99184bb7495ca20adf"
        \\path = "Cloned.tar.gz"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
    });
    try testing.expectEqual(
        Installed.Layout.tarball,
        (try readInstalled(arena, io, tmp.dir, "Cloned")).?.layout,
    );
}

/// A `git` invocation for building a fixture repository. Mirrors the one in
/// `git/cli.zig`'s tests: a deterministic identity, no system config, and no
/// signing — a developer with global `commit.gpgsign` would otherwise have
/// every fixture commit block on a passphrase prompt.
fn fixtureGit(gpa: Allocator, io: Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

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

const git_cli = @import("../git/cli.zig");

test "a registry with no server is cloned, and update fetches the clone" {
    // The whole git branch end to end against a real `git` and a `file://`
    // remote: `add` with the Pkg server disabled clones (`Registry.jl:260-262`),
    // `update` fetches and fast-forwards (`:501-560`), and the two refusals
    // in between are refusals.
    const gpa = testing.allocator;
    const io = testing.io;
    if (!git_cli.available(gpa, io, "git")) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const depot = try std.fs.path.join(arena, &.{ root, "depot" });

    // --- the upstream registry ---------------------------------------------
    const upstream = try std.fs.path.join(arena, &.{ root, "upstream" });
    try tmp.dir.createDirPath(io, "upstream/D/Demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/Registry.toml", .data =
        \\name = "Mini"
        \\uuid = "23338594-aafe-5451-b93e-139f81909106"
        \\
        \\[packages]
        \\90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
        \\
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "upstream/D/Demo/Versions.toml",
        .data = "[\"1.0.0\"]\ngit-tree-sha1 = \"" ++ "a" ** 40 ++ "\"\n",
    });
    try fixtureGit(gpa, io, upstream, &.{ "init", "--quiet", "--initial-branch=master" });
    try fixtureGit(gpa, io, upstream, &.{ "add", "-A" });
    try fixtureGit(gpa, io, upstream, &.{ "commit", "--quiet", "-m", "initial" });

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("GIT_TERMINAL_PROMPT", "0");
    var cli: git_cli.Cli = .{ .environ = &environ };

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();

    const base: Options = .{
        .mode = .add,
        .depot = depot,
        .url = try std.fmt.allocPrint(arena, "file://{s}", .{upstream}),
        .git = cli.backend(),
        // The Pkg server disabled — `registry_use_pkg_server()` false — is one
        // of the two ways Julia reaches the clone.
        .server = null,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    };

    // --- add ----------------------------------------------------------------
    const added = try run(gpa, arena, io, &client, base);
    try testing.expectEqual(Action.added, added.action);
    try testing.expectEqual(Installed.Layout.git_clone, added.layout);
    // The name comes from the CLONE's own Registry.toml (`:280-282`), not from
    // anything the caller said — nothing here ever mentioned "Mini".
    try testing.expectEqualStrings("Mini", added.name);
    try testing.expectEqualStrings("23338594-aafe-5451-b93e-139f81909106", added.uuid);
    // A clone has no tree hash and must not pretend to.
    try testing.expectEqualStrings("", added.tree_sha1);

    var regdir = try Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ depot, "registries" }), .{ .iterate = true });
    defer regdir.close(io);
    _ = try regdir.statFile(io, "Mini/Registry.toml", .{});
    _ = try regdir.statFile(io, "Mini/.git", .{});
    try testing.expectEqual(
        Installed.Layout.git_clone,
        (try readInstalled(arena, io, regdir, "Mini")).?.layout,
    );
    // Published by rename: no staging directory left in `registries/`.
    var it = regdir.iterate();
    while (try it.next(io)) |e| try testing.expect(!std.mem.startsWith(u8, e.name, tmp_prefix));

    // --- add again: already there, and NOT re-cloned over ------------------
    const again = try run(gpa, arena, io, &client, base);
    try testing.expectEqual(Action.already_exists, again.action);

    // --- update -------------------------------------------------------------
    try tmp.dir.writeFile(io, .{ .sub_path = "upstream/Extra.toml", .data = "x = 1\n" });
    try fixtureGit(gpa, io, upstream, &.{ "add", "-A" });
    try fixtureGit(gpa, io, upstream, &.{ "commit", "--quiet", "-m", "second" });

    var upd = base;
    upd.mode = .update;
    upd.name = "Mini";
    upd.url = null; // the clone knows its own origin
    const updated = try run(gpa, arena, io, &client, upd);
    try testing.expectEqual(Action.updated, updated.action);
    try testing.expectEqual(Installed.Layout.git_clone, updated.layout);
    // The fast-forward really moved the working tree, which is the assertion
    // that a fetch into the wrong ref namespace would fail.
    _ = try regdir.statFile(io, "Mini/Extra.toml", .{});

    // --- the two refusals ---------------------------------------------------
    // `isdirty` (`:511`). An UNTRACKED file is not dirty — libgit2's
    // diff_tree_to_workdir does not include untracked entries — so this must
    // still update.
    try regdir.writeFile(io, .{ .sub_path = "Mini/untracked.txt", .data = "scratch\n" });
    _ = try run(gpa, arena, io, &client, upd);

    // A TRACKED file changed is dirty, and Pkg refuses rather than clobbering
    // whatever the user was doing.
    try regdir.writeFile(io, .{ .sub_path = "Mini/Registry.toml", .data = "name = \"Edited\"\n" });
    try testing.expectError(error.DirtyWorktree, run(gpa, arena, io, &client, upd));

    const clone_path = try std.fs.path.join(arena, &.{ depot, "registries", "Mini" });
    try fixtureGit(gpa, io, clone_path, &.{ "checkout", "--quiet", "--", "Registry.toml" });
    _ = try run(gpa, arena, io, &client, upd);

    // `!isattached` (`:515`): a detached HEAD has no branch to fetch into, and
    // fetching "HEAD" would be a refspec that means something else entirely.
    try fixtureGit(gpa, io, clone_path, &.{ "checkout", "--quiet", "--detach", "HEAD" });
    try testing.expectError(error.DetachedHead, run(gpa, arena, io, &client, upd));
    try fixtureGit(gpa, io, clone_path, &.{ "checkout", "--quiet", "master" });

    // `"origin" in remotes(repo)` (`:517`): without it there is nothing to
    // fetch from, since `GitTools.fetch` reads the URL off that remote.
    try fixtureGit(gpa, io, clone_path, &.{ "remote", "rename", "origin", "elsewhere" });
    try testing.expectError(error.NoOriginRemote, run(gpa, arena, io, &client, upd));
    try fixtureGit(gpa, io, clone_path, &.{ "remote", "rename", "elsewhere", "origin" });

    // --- and none of this happens without a git backend ---------------------
    var no_git = upd;
    no_git.git = null;
    try testing.expectError(error.GitUnavailable, run(gpa, arena, io, &client, no_git));

    // A dry run reports what it would do and fetches nothing.
    var dry = upd;
    dry.dry_run = true;
    const planned = try run(gpa, arena, io, &client, dry);
    try testing.expectEqual(Action.would_update, planned.action);
    try testing.expectEqualStrings("Mini", planned.name);
}

test "a git-cloned registry keeps its clone when a tarball is added beside it" {
    // The other direction of the same guard as the `publishCompressed` test:
    // `add`ing over the Pkg server into a depot that holds a clone must not
    // touch the clone. This one comes in through `run`, so it also proves the
    // routing above `publishCompressed` does not take the git branch for an
    // `add`.
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var srv = try ScriptedServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    const script = [_][]const u8{
        try okResponse(arena, fixture.index_body),
        try okResponse(arena, fixture.gz),
    };
    var task = try io.concurrent(ScriptedServer.serve, .{ io, &srv, script[0..] });

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    try tmp.dir.createDirPath(io, "registries/General/.git/refs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "registries/General/Registry.toml",
        .data = "name = \"General\"\nuuid = \"23338594-aafe-5451-b93e-139f81909106\"\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "registries/General/.git/HEAD", .data = "ref: refs/heads/master\n" });

    var client: net_http.Client = .init(gpa, io, .{ .server = server, .depot = depot });
    defer client.deinit();

    const rep = try run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = server,
        .lock = .{ .poll_ms = 1, .timeout_ms = 1000 },
    });
    task.await(io);
    try testing.expectEqual(Action.added, rep.action);
    try testing.expectEqual(Installed.Layout.tarball, rep.layout);

    _ = try tmp.dir.statFile(io, "registries/General.tar.gz", .{});
    _ = try tmp.dir.statFile(io, "registries/General/.git/HEAD", .{});
}

test "an unknown registry and a disabled server both fail loudly" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var client: net_http.Client = .init(gpa, io, .{});
    defer client.deinit();

    // `JULIA_PKG_SERVER=""` with NO git backend wired: Julia would clone here
    // and General's clone URL is known, but there is nothing to run git with,
    // so the server error stands rather than the operation appearing to
    // succeed. With a backend this same call clones — see the test above.
    try testing.expectError(error.ServerDisabled, run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "General",
        .server = null,
    }));

    // A name with no known UUID and no `--url` never reaches the network:
    // there is nothing to ask the server for and nothing to clone.
    try testing.expectError(error.UnknownRegistry, run(gpa, arena, io, &client, .{
        .mode = .add,
        .depot = depot,
        .name = "NoSuchRegistry",
        .server = "http://127.0.0.1:1",
        .lock = .{ .poll_ms = 1, .timeout_ms = 100 },
    }));

    // `update` never creates a registry (`find_installed_registries`,
    // `:336-376`), so a name with nothing on disk is `NotInstalled` even
    // though a clone URL for it is known.
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    var cli: git_cli.Cli = .{ .environ = &environ, .program = "/nonexistent/git" };
    try testing.expectError(error.NotInstalled, run(gpa, arena, io, &client, .{
        .mode = .update,
        .depot = depot,
        .name = "General",
        .git = cli.backend(),
        .server = null,
        .lock = .{ .poll_ms = 1, .timeout_ms = 100 },
    }));
}
