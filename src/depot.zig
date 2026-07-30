//! Depot layout and atomic install.
//!
//! Two jobs, and both of them are about being invisible to stock `julia`:
//!
//!  1. **Where things live.** Julia's loader and Pkg agree on a fixed directory
//!     layout under each depot root. Ajt has to reproduce it byte for byte or
//!     the packages it installs simply will not be found -- there is no error
//!     message for "installed to the wrong slug", only a `Package X not found`
//!     from `using`.
//!  2. **How things get there.** Every install lands by `renameat(2)` of a
//!     sibling staging directory. A depot is routinely shared by concurrent
//!     processes (CI matrices, a container image plus a writable overlay, two
//!     `julia` sessions), so a half-written package directory is a corrupt
//!     depot that outlives the process that made it. Rename is the only
//!     primitive that is atomic across those observers.
//!
//! ### Read from all depots, write to the first
//!
//! `DEPOT_PATH` is a stack (`base/initdefs.jl:95-139`). Julia searches every
//! entry; Pkg installs into `depots1()` = entry 0 (`Pkg/src/Pkg.jl:24-32`).
//! RealityForge's engine image relies on exactly this: it runs
//! `JULIA_DEPOT_PATH=/julia-depot:/julia-depot-image`, where the image depot is
//! a read-only baked layer and the writable one shadows it. So every path
//! builder here is per-`Depot`, lookups iterate `Stack.entries`, and the only
//! thing that picks a depot to WRITE to is `Stack.writeDepot`.
//!
//! ### The `compiled/` exception
//!
//! `compiled/v<major>.<minor>/` (`base/loading.jl:1203-1210`) is written by
//! Julia itself, by the precompiler, keyed on a Julia version Ajt does not
//! control. This module exposes the path so it can be reported and
//! garbage-collected against, and never writes there.
//!
//! The line has since moved, and it is worth being exact about where. Ajt
//! still never FORGES a `.ji` header — that was the reason for the rule and it
//! stands. But `cache/` now reads and verifies headers (`cache/jicache.zig`
//! re-runs what `stale_cachefile` will check), and the shared-cache import
//! step writes whole objects built elsewhere into `compiled/`, at a slug
//! computed for THIS machine (`cache/slug.zig`). Bytes are transported and
//! verified; none are invented. `ops/precompile.zig` likewise only invokes
//! Julia, which does the writing.
//!
//! This is the first module in the package that performs writes; `julia/`,
//! `toml/` and `registry/` are pure or read-only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

// The slug is the single most trap-laden value in the layout (crc32c over the
// UUID's NATIVE little-endian bytes, base62 least-significant-digit-first).
// It has its own differentially tested module; never inline a second copy.
const slug = @import("julia/slug.zig");

// `clones/<name>` is spelled with Julia's own `hash(::String)`, and `Pkg.gc()`
// orphans every directory under `clones/` whose name it cannot reproduce.
const string_hash = @import("julia/string_hash.zig");

pub const Uuid = slug.Uuid;
pub const Sha1 = slug.Sha1;

// ---------------------------------------------------------------------------
// DEPOT_PATH resolution
// ---------------------------------------------------------------------------

/// The environment `init_depot_path()` reads. Passed in rather than read from
/// the process so this stays testable and so the caller decides which env map
/// is authoritative (Zig 0.16 removed `std.posix.getenv` anyway).
pub const Env = struct {
    /// Raw `JULIA_DEPOT_PATH`. `null` = unset, which is NOT the same as `""`:
    /// unset means "use the defaults", `""` means "use no depot at all"
    /// (`initdefs.jl:110-111`).
    julia_depot_path: ?[]const u8 = null,
    /// `homedir()`. Needed for `~/.julia` and for `expanduser` on entries.
    home: ?[]const u8 = null,
    /// `Sys.BINDIR`. Only needed to expand an EMPTY entry into the two bundled
    /// depots (`initdefs.jl:97-103`); resolution fails loudly rather than
    /// silently dropping them if an empty entry shows up without it.
    julia_bindir: ?[]const u8 = null,

    /// Read the variable NAMES from a process environment, so no caller has to
    /// spell `"JULIA_DEPOT_PATH"` itself. `julia_bindir` stays a parameter --
    /// it is `Sys.BINDIR`, not an environment variable, and only the caller
    /// knows which `julia` it is targeting.
    pub fn fromEnviron(map: std.process.Environ.Map, julia_bindir: ?[]const u8) Env {
        return .{
            .julia_depot_path = map.get("JULIA_DEPOT_PATH"),
            .home = map.get("HOME"),
            .julia_bindir = julia_bindir,
        };
    }
};

pub const ResolveError = error{
    /// A depot had to be derived from `$HOME` but `Env.home` was null.
    HomeUnknown,
    /// An empty `JULIA_DEPOT_PATH` entry asked for the bundled depots but
    /// `Env.julia_bindir` was null.
    JuliaBindirUnknown,
    /// `expanduser` hit `~someuser`, which Julia itself refuses
    /// (`base/path.jl`: "~user tilde expansion not yet implemented").
    TildeUserUnsupported,
} || Allocator.Error;

/// A resolved `Base.DEPOT_PATH`, in search order.
pub const Stack = struct {
    entries: []const []const u8,

    /// `Pkg.depots1()` -- the depot Ajt WRITES to (`Pkg/src/Pkg.jl:24-32`).
    /// `null` where Pkg raises "no depots provided"; an empty stack is a real,
    /// reachable configuration (`JULIA_DEPOT_PATH=""`), so callers must decide
    /// what to do about it rather than defaulting to somewhere arbitrary.
    pub fn writeDepot(self: Stack) ?Depot {
        if (self.entries.len == 0) return null;
        return .{ .root = self.entries[0] };
    }
};

/// Port of `init_depot_path()` (`base/initdefs.jl:105-139`).
///
/// Arena: every returned string has the `Stack`'s lifetime and is owned by
/// `arena`; nothing here needs individual freeing.
///
/// The rule that is easy to get wrong, and that no other package manager has:
/// an **empty entry expands to the bundled depots in place**, and a leading
/// empty entry additionally leaves `~/.julia` prepended. So `":/foo"` is
/// `[~/.julia, <bundled...>, /foo]`, not `[/foo]` and not `[~/.julia, /foo]`.
/// `pushfirst_default` is only cleared by a NON-empty entry at position 1
/// (`:115`, `:122-125`, `:129-133`), which is what makes `":"` still yield the
/// default depot.
pub fn resolve(arena: Allocator, env: Env) ResolveError!Stack {
    var entries: std.ArrayList([]const u8) = .empty;

    const raw = env.julia_depot_path orelse {
        // Unset: default depot, then bundled (`:134-137`).
        try pushUnique(arena, &entries, try defaultDepot(arena, env));
        try appendBundled(arena, &entries, env);
        return .{ .entries = entries.items };
    };

    // Explicitly empty means no depot at all (`:110-111`).
    if (raw.len == 0) return .{ .entries = entries.items };

    var pushfirst_default = true;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, raw, fspath.delimiter);
    while (it.next()) |entry| : (i += 1) {
        if (entry.len == 0) {
            try appendBundled(arena, &entries, env);
            continue;
        }
        try pushUnique(arena, &entries, try expandUser(arena, entry, env));
        // Only a non-empty FIRST entry suppresses the default depot (`:122-125`).
        if (i == 0) pushfirst_default = false;
    }

    // `JULIA_DEPOT_PATH=":"` still gets the default depot (`:129-133`).
    if (pushfirst_default) {
        const dflt = try defaultDepot(arena, env);
        // `pushfirst!` is unconditional in Julia -- no dedup on this path.
        try entries.insert(arena, 0, dflt);
    }

    return .{ .entries = entries.items };
}

fn defaultDepot(arena: Allocator, env: Env) ResolveError![]const u8 {
    const home = env.home orelse return error.HomeUnknown;
    return fspath.join(arena, &.{ home, ".julia" });
}

/// `append_bundled_depot_path!` (`initdefs.jl:97-103`): `<BINDIR>/../local/share/julia`
/// then `<BINDIR>/../share/julia`, each deduped. `Base.DATAROOTDIR` is `"../share"`.
fn appendBundled(arena: Allocator, entries: *std.ArrayList([]const u8), env: Env) ResolveError!void {
    const bindir = env.julia_bindir orelse return error.JuliaBindirUnknown;
    // These are the only two layout paths with a literal `..` in them, and
    // Julia's `abspath` collapses it. `resolve` is the collapsing join.
    try pushUnique(arena, entries, try fspath.resolve(arena, &.{ bindir, "..", "local", "share", "julia" }));
    try pushUnique(arena, entries, try fspath.resolve(arena, &.{ bindir, "..", "share", "julia" }));
}

/// `path in DEPOT_PATH || push!(DEPOT_PATH, path)` -- exact string equality,
/// no path normalisation (`initdefs.jl:99`, `:101`, `:121`).
///
/// Linear, deliberately: the list is `count(':') + 3` long, and Julia's `in`
/// is order-preserving exact equality, so a set would need a parallel order
/// array and would observe nothing different.
fn pushUnique(arena: Allocator, entries: *std.ArrayList([]const u8), p: []const u8) Allocator.Error!void {
    for (entries.items) |e| if (std.mem.eql(u8, e, p)) return;
    try entries.append(arena, p);
}

/// `Base.expanduser` on POSIX: bare `~` is `homedir()`, `~/...` prefixes it,
/// anything else after the tilde is an error in Julia too.
///
/// Always copies into `arena` even when nothing expands, so no entry in a
/// returned `Stack` borrows from `Env` -- the caller's environment block is
/// usually shorter-lived than the depot list built from it.
fn expandUser(arena: Allocator, p: []const u8, env: Env) ResolveError![]const u8 {
    if (p.len == 0 or p[0] != '~') return arena.dupe(u8, p);
    const home = env.home orelse return error.HomeUnknown;
    if (p.len == 1) return arena.dupe(u8, home);
    if (p[1] != '/') return error.TildeUserUnsupported;
    // Julia does `homedir() * path[2:end]`, i.e. plain concatenation -- the
    // separator comes from the string itself.
    return std.mem.concat(arena, u8, &.{ home, p[1..] });
}

// ---------------------------------------------------------------------------
// Path construction
// ---------------------------------------------------------------------------

/// One depot root. Every builder is a pure string join with the `arena`'s
/// lifetime; nothing here touches the filesystem, so a `Depot` is safe to
/// construct for a root that does not exist.
///
/// Julia `abspath`s several of these (`Operations.jl:36`, and `artifacts_dirs`
/// at `Artifacts/src/Artifacts.jl:67`). These builders only join. For the
/// absolute roots `resolve` produces that is the same string; for a relative
/// `JULIA_DEPOT_PATH` entry Julia would absolutise against the process cwd and
/// these do not, because a path builder that silently depends on cwd is worse
/// than one that hands back exactly what it was given.
pub const Depot = struct {
    root: []const u8,

    /// `<depot>/packages` -- what a GC sweep enumerates.
    pub fn packagesDir(self: Depot, arena: Allocator) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "packages" });
    }

    /// `<depot>/packages/<Name>` -- all installed versions of one package.
    pub fn packageDir(self: Depot, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "packages", name });
    }

    /// `<depot>/packages/<Name>/<slug>` for a slug the caller already has.
    /// The single place the `packages/` layout is spelled; `packageVersionDir`
    /// and `findInstalled` (which also probes the legacy 4-character slug)
    /// both go through it.
    pub fn packageSlugDir(
        self: Depot,
        arena: Allocator,
        name: []const u8,
        version_slug: []const u8,
    ) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "packages", name, version_slug });
    }

    /// `<depot>/packages/<Name>/<version_slug>` -- THE path stock `julia`
    /// looks in (`Pkg/src/Operations.jl:31-41`). The slug comes from
    /// `julia/slug.zig`; see its header for the little-endian UUID trap.
    pub fn packageVersionDir(
        self: Depot,
        arena: Allocator,
        name: []const u8,
        uuid: Uuid,
        tree_hash: Sha1,
    ) Allocator.Error![]u8 {
        var buf: [8]u8 = undefined;
        return self.packageSlugDir(arena, name, slug.versionSlug(uuid, tree_hash, &buf));
    }

    /// `<depot>/artifacts/<hex tree-sha1>` (`Artifacts/src/Artifacts.jl:65-72`,
    /// `:233`). Content-addressed, so the name is the hash and nothing else --
    /// there is no slug here.
    pub fn artifactDir(self: Depot, arena: Allocator, tree_hash: Sha1) Allocator.Error![]u8 {
        const hex = std.fmt.bytesToHex(tree_hash.bytes, .lower);
        return fspath.join(arena, &.{ self.root, "artifacts", &hex });
    }

    /// `<depot>/clones` — the bare git repositories a git-sourced package is
    /// fetched into before it is materialised into `packages/`.
    ///
    /// **Two different naming schemes live in here, and both are Pkg's.** This
    /// is not a design Ajt gets to simplify: `Pkg.gc()` recomputes a name for
    /// every live manifest entry and deletes every directory that matches none
    /// of them (`API.jl:772-791`, `:985-994`), so a clone under a third
    /// convention is not merely untidy — it is deleted the next time anybody
    /// runs `Pkg.gc()`, and re-cloned the time after that.
    ///
    ///   * `cloneUrlDir` — `clones/<string(hash(url))>`, from
    ///     `add_repo_cache_path` (`Types.jl:901`). Used by `handle_repo_add!`
    ///     and `handle_repo_develop!`, i.e. by anything the *user* named a URL
    ///     for. This is the one `Pkg.gc()` reproduces.
    ///   * `cloneUuidDir` — `clones/<uuid>`, from `install_git`
    ///     (`Operations.jl:842-844`). Used when a manifest entry is being
    ///     installed and the archive paths have all failed.
    pub fn clonesDir(self: Depot, arena: Allocator) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "clones" });
    }

    /// `<depot>/clones/<name>` for a name the caller already has. The single
    /// place the `clones/` layout is spelled; both keyings go through it.
    pub fn cloneDir(self: Depot, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "clones", name });
    }

    /// `Pkg.Types.add_repo_cache_path(url)` (`Types.jl:901`) —
    /// `clones/<string(hash(url))>`, where `hash` is `Base.hash(::String)`.
    ///
    /// The URL is used verbatim, exactly as Pkg does: it does NOT normalise,
    /// strip a trailing `.git`, or lowercase the host first, so
    /// `…/Example.jl` and `…/Example.jl.git` are two different clones. Matching
    /// that is the whole point — a "better" key would simply not be the
    /// directory Pkg looks in.
    pub fn cloneUrlDir(self: Depot, arena: Allocator, url: []const u8) Allocator.Error![]u8 {
        var buf: [20]u8 = undefined;
        return self.cloneDir(arena, string_hash.decimal(string_hash.hashString(url), &buf));
    }

    /// `install_git`'s cache path (`Operations.jl:842-844`) —
    /// `clones/<uuid>`, canonical UUID text, no slug.
    pub fn cloneUuidDir(self: Depot, arena: Allocator, uuid: Uuid) Allocator.Error![]u8 {
        const text = uuidText(uuid);
        return self.cloneDir(arena, &text);
    }

    /// `<depot>/dev` — where `Pkg.develop` puts a package it checked out for
    /// you, as opposed to one you pointed it at (`Types.jl:770-775`,
    /// `Pkg.devdir()`). Overridden wholesale by `JULIA_PKG_DEVDIR`, which is
    /// the caller's business: this builder answers only for a depot root.
    pub fn devDir(self: Depot, arena: Allocator) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "dev" });
    }

    /// `<depot>/dev/<Name>`. Named by the package NAME, not a uuid or a slug —
    /// this is a directory a human is expected to `cd` into and edit, and its
    /// path is what lands in `[sources]`.
    pub fn devPackageDir(self: Depot, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "dev", name });
    }

    /// `<depot>/registries` (`Pkg/src/Registry/Registry.jl:185`, `:422`).
    pub fn registriesDir(self: Depot, arena: Allocator) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "registries" });
    }

    /// `<depot>/registries/<Name>` -- a directory or, on a squashed depot, a
    /// `<Name>.tar.gz` sibling; the caller decides which it found.
    pub fn registryDir(self: Depot, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "registries", name });
    }

    /// `<depot>/scratchspaces/<uuid>` (`Pkg/src/Operations.jl:1394`,
    /// `Pkg/src/API.jl:1008`). Owned by the package identified by `uuid`, which
    /// is why the directory name is the canonical UUID text and not a slug.
    pub fn scratchspaceDir(self: Depot, arena: Allocator, uuid: Uuid) Allocator.Error![]u8 {
        const text = uuidText(uuid);
        return fspath.join(arena, &.{ self.root, "scratchspaces", &text });
    }

    /// `<depot>/scratchspaces/<uuid>/<key>`.
    pub fn scratchspaceKeyDir(
        self: Depot,
        arena: Allocator,
        uuid: Uuid,
        key: []const u8,
    ) Allocator.Error![]u8 {
        const text = uuidText(uuid);
        return fspath.join(arena, &.{ self.root, "scratchspaces", &text, key });
    }

    /// `<depot>/environments/<name>` (`base/initdefs.jl:300-310`,
    /// `Pkg/src/Pkg.jl:43`). `name` is `v1.12` for the default shared env --
    /// see `defaultEnvironmentName`.
    pub fn environmentDir(self: Depot, arena: Allocator, name: []const u8) Allocator.Error![]u8 {
        return fspath.join(arena, &.{ self.root, "environments", name });
    }

    /// `<depot>/servers/<host>` (`Pkg/src/PlatformEngines.jl:46-61`).
    pub fn serverDir(self: Depot, arena: Allocator, server: []const u8) ServerHostError![]u8 {
        var buf: [max_host_len]u8 = undefined;
        return fspath.join(arena, &.{ self.root, "servers", try serverHostInto(&buf, server) });
    }

    /// `<depot>/servers/<host>/auth.toml` (`PlatformEngines.jl:113`).
    pub fn serverAuthFile(self: Depot, arena: Allocator, server: []const u8) ServerHostError![]u8 {
        var buf: [max_host_len]u8 = undefined;
        return fspath.join(arena, &.{ self.root, "servers", try serverHostInto(&buf, server), "auth.toml" });
    }

    /// `<depot>/compiled/v<major>.<minor>` (`base/loading.jl:1203-1210`).
    ///
    /// **Ajt never writes here.** This is Julia's precompilation cache; the
    /// path is exposed for reporting and for GC accounting only.
    ///
    /// Keyed on the same `v<major>.<minor>` string as the default shared
    /// environment, through the same function, because the two must agree.
    pub fn compiledDir(self: Depot, arena: Allocator, major: u32, minor: u32) Allocator.Error![]u8 {
        var buf: [max_version_dir_len]u8 = undefined;
        return fspath.join(arena, &.{ self.root, "compiled", versionDirName(&buf, major, minor) });
    }

    // --- enumeration: the four stores a GC sweep walks ---------------------
    //
    // `Pkg.gc()` is the only thing that reads the depot BACKWARDS -- it walks
    // these directories and asks of each entry "is anything still pointing at
    // you" (`API.jl:969-1027`). Every builder above answers the forward
    // question; these four answer the backward one, and they live here so that
    // the layout is spelled in exactly one file in both directions. All four
    // are built on `listDir`; see it for the sorting and the kind resolution.

    /// Every `packages/<Name>/<slug>` directory in this depot
    /// (`API.jl:912-928`).
    ///
    /// Both levels are filtered to directories, exactly as Pkg does: a stray
    /// FILE under `packages/` is not an install and must not be reported as
    /// one -- Pkg leaves it alone forever, and so must this.
    pub fn listPackages(self: Depot, arena: Allocator, io: Io) ListError![]const Installed {
        const root = try self.packagesDir(arena);
        var out: std.ArrayList(Installed) = .empty;
        for (try listDir(arena, io, root)) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const name_dir = try fspath.join(arena, &.{ root, name_entry.name });
            for (try listDir(arena, io, name_dir)) |slug_entry| {
                if (slug_entry.kind != .directory) continue;
                try out.append(arena, .{
                    .name = name_entry.name,
                    .version_slug = slug_entry.name,
                    .path = try fspath.join(arena, &.{ name_dir, slug_entry.name }),
                });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Every `clones/<name>` directory, as full paths (`API.jl:985-994`).
    ///
    /// See `clonesDir` for why the names in here follow two different
    /// conventions and only one of them is ever reproduced by the collector.
    pub fn listClones(self: Depot, arena: Allocator, io: Io) ListError![]const []const u8 {
        return listChildDirs(arena, io, try self.clonesDir(arena));
    }

    /// Every `artifacts/<hex>` directory, as full paths (`API.jl:996-1006`).
    ///
    /// `Overrides.toml` lives in this directory too and is a FILE, so the
    /// directories-only filter is what keeps it from being collected.
    pub fn listArtifacts(self: Depot, arena: Allocator, io: Io) ListError![]const []const u8 {
        return listChildDirs(arena, io, try fspath.join(arena, &.{ self.root, "artifacts" }));
    }

    /// Every `scratchspaces/<uuid>/<key>` entry, directories AND files
    /// (`API.jl:1008-1027`).
    ///
    /// Files are included on purpose: Pkg keeps `suspend_cache_*` and
    /// `pending_cache_*` marker FILES directly under its own scratchspace
    /// uuid and collects them on a 24-hour timer, which is the one place `gc`
    /// deletes something that is not a directory.
    pub fn listScratchspaces(self: Depot, arena: Allocator, io: Io) ListError![]const Scratch {
        const root = try fspath.join(arena, &.{ self.root, "scratchspaces" });
        var out: std.ArrayList(Scratch) = .empty;
        for (try listDir(arena, io, root)) |uuid_entry| {
            if (uuid_entry.kind != .directory) continue;
            const uuid_dir = try fspath.join(arena, &.{ root, uuid_entry.name });
            for (try listDir(arena, io, uuid_dir)) |e| {
                try out.append(arena, .{
                    .uuid = uuid_entry.name,
                    .key = e.name,
                    .path = try fspath.join(arena, &.{ uuid_dir, e.name }),
                    .kind = e.kind,
                });
            }
        }
        return out.toOwnedSlice(arena);
    }
};

const max_version_dir_len = 1 + 10 + 1 + 10; // "v" + u32 + "." + u32

fn versionDirName(buf: *[max_version_dir_len]u8, major: u32, minor: u32) []const u8 {
    return std.fmt.bufPrint(buf, "v{d}.{d}", .{ major, minor }) catch unreachable;
}

/// `v<major>.<minor>` -- the name of the default shared environment, and the
/// same string `compiled/` is keyed on.
pub fn defaultEnvironmentName(arena: Allocator, major: u32, minor: u32) Allocator.Error![]u8 {
    var buf: [max_version_dir_len]u8 = undefined;
    return arena.dupe(u8, versionDirName(&buf, major, minor));
}

pub const ServerHostError = error{
    MalformedServerUrl,
    /// The host is longer than any filesystem will accept as a directory name.
    ServerHostTooLong,
} || Allocator.Error;

/// The `servers/<host>` directory name for a Pkg server URL
/// (`Pkg/src/PlatformEngines.jl:52-60`).
///
/// Public because the downloader needs the host string itself for the auth
/// lookup, and a second implementation of Julia's fiddly host rule is exactly
/// the kind of near-copy that drifts. Arena: the result is arena-owned.
pub fn serverHost(arena: Allocator, server: []const u8) ServerHostError![]u8 {
    var buf: [max_host_len]u8 = undefined;
    return arena.dupe(u8, try serverHostInto(&buf, server));
}

const max_host_len = 253; // longest legal DNS name; ports push past it only absurdly

/// `^\w+://([^\\/]+)(?:$|/)`, then every character illegal in a Windows
/// filename replaced with `_` (`PlatformEngines.jl:52`, `:58-59`). The
/// substitution runs on Linux too, because the depot has to be portable
/// between hosts -- and `:` is the one that actually fires, for `host:port`.
fn serverHostInto(buf: *[max_host_len]u8, server: []const u8) ServerHostError![]const u8 {
    // Anchored: a `://` appearing later in the string is not a scheme.
    const scheme_end = std.mem.indexOf(u8, server, "://") orelse return error.MalformedServerUrl;
    if (scheme_end == 0) return error.MalformedServerUrl;
    for (server[0..scheme_end]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.MalformedServerUrl;
    }

    const rest = server[scheme_end + 3 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len];
    if (host.len == 0) return error.MalformedServerUrl;
    if (host.len > buf.len) return error.ServerHostTooLong;

    const out = buf[0..host.len];
    for (out, host) |*dst, c| {
        dst.* = switch (c) {
            ':', '/', '<', '>', '"', '\\', '|', '?', '*' => '_',
            else => c,
        };
    }
    return out;
}

/// Canonical `8-4-4-4-12` lowercase text, i.e. `string(::UUID)`.
fn uuidText(u: Uuid) [36]u8 {
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{
        u.bytes[0..4], u.bytes[4..6], u.bytes[6..8], u.bytes[8..10], u.bytes[10..16],
    }) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------
// Lookup across the stack
// ---------------------------------------------------------------------------

pub const FindError = error{
    /// Nothing is installed and there is nowhere to install to, i.e. an empty
    /// `DEPOT_PATH`. Julia raises "no depots provided" here
    /// (`Pkg/src/Pkg.jl:29`); guessing a directory would mean creating
    /// `./packages/` under whatever the user's cwd happened to be.
    NoDepot,
} || Allocator.Error || Io.Cancelable;

pub const Found = struct {
    path: []const u8,
    /// `false` means nothing exists yet and `path` is where an install would
    /// land -- Julia's `find_installed` returns that same "would-be" path
    /// rather than nothing, and callers rely on it.
    exists: bool,
};

/// `Pkg.Operations.find_installed` (`Pkg/src/Operations.jl:31-41`).
///
/// Arena: exactly one arena allocation, for the returned path. Candidates are
/// built in a stack buffer, since all but one are thrown away and an arena
/// cannot reclaim them.
///
/// The loop order is slug-major, depot-minor: BOTH depots are probed at the
/// 5-character slug before either is probed at the 4-character one. Julia
/// still accepts `p=4` because that was the default before 1.5, and a depot
/// built by an old Julia keeps working. Inverting the loops would prefer a
/// stale 4-char directory in the writable depot over a current 5-char one in
/// the image depot.
pub fn findInstalled(
    arena: Allocator,
    io: Io,
    stack: Stack,
    name: []const u8,
    uuid: Uuid,
    tree_hash: Sha1,
) FindError!Found {
    var slug_buf: [8]u8 = undefined;
    const slug5 = slug.versionSlug(uuid, tree_hash, &slug_buf);
    // `version_slug(uuid, sha1, 4)` is a PREFIX of the 5-character one: the
    // base-62 digits are emitted least-significant first, so digit i is
    // `(crc / 62^i) % 62` regardless of the requested width. Pinned by
    // slug.zig's "slug width is configurable" test.
    const slugs = [_][]const u8{ slug5, slug5[0..4] };

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (slugs) |s| {
        for (stack.entries) |root| {
            const p = candidatePath(&path_buf, root, name, s) orelse continue;
            // `ispath`, not `isdir`: Julia accepts anything at that name.
            if (Io.Dir.cwd().statFile(io, p, .{})) |_| {
                return .{ .path = try arena.dupe(u8, p), .exists = true };
            } else |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            }
        }
    }

    const write = stack.writeDepot() orelse return error.NoDepot;
    return .{
        .path = try write.packageSlugDir(arena, name, slugs[0]),
        .exists = false,
    };
}

/// `findInstalled`'s question without its answer: is this (package, tree hash)
/// unpacked anywhere on the stack?
///
/// Same probe order, same `ispath` rule, but no allocator and no would-be
/// path — so a caller that only wants the boolean is not charged an arena
/// allocation per probe. That caller is the resolver's `installed_only`
/// filter, which asks once per candidate VERSION of every package: on a
/// 200-entry environment that is thousands of misses, and `findInstalled`
/// builds and duplicates a path string for each one before throwing it away.
///
/// A depot stack with no writable entry is not an error here either: "nothing
/// is installed" is a perfectly good answer to a yes/no question, whereas
/// `findInstalled` has to name a directory and so cannot avoid failing.
pub fn installedExists(io: Io, stack: Stack, name: []const u8, uuid: Uuid, tree_hash: Sha1) bool {
    var slug_buf: [8]u8 = undefined;
    const slug5 = slug.versionSlug(uuid, tree_hash, &slug_buf);
    const slugs = [_][]const u8{ slug5, slug5[0..4] };

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (slugs) |s| {
        for (stack.entries) |root| {
            const p = candidatePath(&path_buf, root, name, s) orelse continue;
            if (Io.Dir.cwd().statFile(io, p, .{})) |_| return true else |_| {}
        }
    }
    return false;
}

/// `<root>/packages/<name>/<slug>` into a caller buffer; `null` when it does
/// not fit, which is a miss rather than an error (nothing can be installed at
/// a path the OS would reject anyway).
fn candidatePath(buf: []u8, root: []const u8, name: []const u8, s: []const u8) ?[]const u8 {
    const sep = fspath.sep_str;
    return std.fmt.bufPrint(buf, "{s}" ++ sep ++ "packages" ++ sep ++ "{s}" ++ sep ++ "{s}", .{
        root, name, s,
    }) catch null;
}

// ---------------------------------------------------------------------------
// Atomic install
// ---------------------------------------------------------------------------

/// `.ajt-tmp-` + 16 base64url characters of entropy.
///
/// The leading dot matters: `packages/<Name>/` is scanned by Pkg's GC and by
/// anything that enumerates installed versions, and a dotfile is conventionally
/// skipped. The prefix identifies the owner so a crashed run leaves an
/// obviously-collectable turd rather than something that looks like a slug.
const tmp_prefix = ".ajt-tmp-";
const tmp_random_bytes = 12;
const tmp_name_len = tmp_prefix.len + std.base64.url_safe_no_pad.Encoder.calcSize(tmp_random_bytes);

/// Mirrors `_mv_temp_artifact_dir`'s retry loop (`Pkg/src/Artifacts.jl:73-77`):
/// 20 retries, 10 ms doubling to a 5 s ceiling, ~60 s total.
///
/// The retry is there for Windows: antivirus software holds a handle on
/// freshly written files and makes the rename fail with a sharing violation
/// that clears on its own. It is kept on every platform because the same shape
/// occurs on network filesystems, and because a policy that differs per OS is a
/// policy that only gets tested on one OS.
pub const Retry = struct {
    max_retries: u32 = 20,
    initial_ms: u64 = 10,
    max_ms: u64 = 5_000,

    /// Same control flow and the same retry count as the default; no
    /// wall-clock cost. For tests, and for a caller that would rather fail
    /// fast than block a UI for a minute.
    pub const immediate: Retry = .{ .initial_ms = 0 };
};

pub const CommitOptions = struct {
    retry: Retry = .{},
    /// Apply Pkg's `set_readonly` to the published tree.
    ///
    /// True for the two content-addressed stores -- `packages/` and
    /// `artifacts/` -- where the bytes are pinned by a hash and editing them
    /// in place would silently invalidate it (`Operations.jl:1180`, `:1235`,
    /// `Artifacts.jl:88`). False for `registries/`, `dev/` and
    /// `scratchspaces/`, which Julia keeps writable and which are the other
    /// consumers of this same staging mechanism.
    set_readonly: bool = true,
};

pub const Outcome = enum {
    /// This process's staged content is now at the destination.
    installed,
    /// The destination already existed. Someone else won the race (or did the
    /// work earlier); the staged copy was discarded. This is SUCCESS -- the
    /// destination is content-addressed, so their bytes and ours are the same.
    already_present,
};

pub const BeginError = error{
    /// `dest_path` has no basename (empty, or a bare `/`).
    InvalidDestination,
} || Allocator.Error ||
    Io.Dir.CreateDirPathOpenError || Io.Dir.CreateDirError || Io.Dir.OpenError;

/// Note what is NOT in here: `DeleteTreeError`. Cleaning up the staging
/// directory is best-effort -- once the outcome is decided, failing to remove
/// a leftover must not turn a successful install into an error.
pub const CommitError = Allocator.Error || Io.Dir.RenameError ||
    Io.Dir.StatFileError || Io.Dir.StatError || SetReadonlyError;

/// A staging directory that becomes `dest_path` in one `renameat`.
///
/// Lifecycle: `begin` -> write into `.dir` -> `commit`. `deinit` discards
/// whatever has not been published and is safe after `commit`, so it is always
/// the right `defer`.
pub const Install = struct {
    /// Extract/write here. Opened with `iterate` so the caller can tree-hash
    /// the staged content before committing -- verify-then-publish is the whole
    /// point of staging.
    dir: Io.Dir,
    /// `dirname(dest_path)`, held open so the rename is a single `renameat`
    /// with the same fd on both sides.
    parent_dir: Io.Dir,
    tmp_name: [tmp_name_len]u8,
    /// `basename(dest_path)`, arena-owned.
    dest_name: []const u8,
    /// `dir` is open and `tmp_name` still exists on disk. `commit` consumes
    /// both, and `deinit` must not touch them again -- closing a stale fd is a
    /// use-after-free that `Io` traps as an OS bug.
    staged: bool,

    /// Discards the staging directory unless `commit` already consumed it.
    pub fn deinit(self: *Install, io: Io) void {
        self.releaseStaging(io);
        self.parent_dir.close(io);
        self.* = undefined;
    }

    fn releaseStaging(self: *Install, io: Io) void {
        if (!self.staged) return;
        self.staged = false;
        self.dir.close(io);
        self.parent_dir.deleteTree(io, &self.tmp_name) catch {};
    }

    /// Publish the staged directory. Port of `_mv_temp_artifact_dir`
    /// (`Pkg/src/Artifacts.jl:67-103`).
    ///
    /// On `error` after a successful rename the content IS published; only the
    /// permission pass failed. `deinit` will not undo it, which is correct --
    /// another process may already be reading it.
    ///
    /// `gpa` backs the `set_readonly` walk only and is released before return.
    pub fn commit(self: *Install, gpa: Allocator, io: Io, options: CommitOptions) CommitError!Outcome {
        std.debug.assert(self.staged);

        var attempt: u32 = 0;
        var sleep_ms = options.retry.initial_ms;
        while (true) {
            // `isdir(new_path) && return` BEFORE trying (`:79`). This is the
            // common case in a shared depot and it costs one stat; on a later
            // iteration it is also the re-poll after the backoff.
            if (try self.destExists(io)) {
                self.releaseStaging(io);
                return .already_present;
            }

            // `mv` in Julia falls back to `cp` when rename fails; `cp` is not
            // atomic, so Pkg deliberately calls the raw rename (`:80-84`).
            // Same reason Ajt never copies: a copy is observable half-done.
            //
            // POSIX `rename` will replace an EMPTY destination directory
            // rather than failing, so a competitor who has created the
            // directory but not populated it loses it. Pkg has the identical
            // window and it costs nothing: an empty directory holds no bytes.
            if (Io.Dir.rename(self.parent_dir, &self.tmp_name, self.parent_dir, self.dest_name, io)) |_| {
                // `tmp_name` no longer exists -- the rename consumed it -- so
                // clear `staged` BEFORE anything that can fail, or `deinit`
                // would try to delete the freshly installed directory.
                const dest = self.dir;
                self.staged = false;
                defer dest.close(io);
                try self.finishInstalled(gpa, io, dest, options);
                return .installed;
            } else |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    // Lost the race: the rename failed because the destination
                    // is a non-empty directory now (`:91-92`).
                    if (try self.destExists(io)) {
                        self.releaseStaging(io);
                        return .already_present;
                    }

                    const recoverable = switch (err) {
                        // UV_EACCES / UV_EPERM / UV_EBUSY (`:93`).
                        error.AccessDenied, error.PermissionDenied, error.FileBusy => true,
                        else => false,
                    };
                    if (!recoverable or attempt >= options.retry.max_retries) return err;

                    if (sleep_ms != 0) try io.sleep(.fromMilliseconds(@intCast(sleep_ms)), .awake);
                    sleep_ms = @min(sleep_ms * 2, options.retry.max_ms);
                    attempt += 1;
                },
            }
        }
    }

    fn destExists(self: *Install, io: Io) Io.Cancelable!bool {
        // `isdir` follows symlinks, so the default `statFile` options match.
        if (self.parent_dir.statFile(io, self.dest_name, .{})) |st| {
            return st.kind == .directory;
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        }
    }

    /// `chmod(new_path, filemode(dirname(new_path))); set_readonly(new_path)`
    /// (`Pkg/src/Artifacts.jl:87-88`).
    ///
    /// `dest` is the staging handle: `renameat` moves the directory ENTRY, not
    /// the inode, so the fd opened at `begin` now refers to the published
    /// directory. Reusing it saves a close/reopen and, more usefully, removes
    /// an `openDir` that could fail after the content is already live.
    fn finishInstalled(
        self: *Install,
        gpa: Allocator,
        io: Io,
        dest: Io.Dir,
        options: CommitOptions,
    ) CommitError!void {
        // The installed directory inherits the depot's own mode rather than
        // whatever umask the staging mkdir happened to get, so a depot with
        // group-shared permissions stays group-shared. Julia passes the full
        // `filemode` including the S_IFDIR bits; so do we.
        if (self.parent_dir.stat(io)) |st| {
            self.parent_dir.setFilePermissions(io, self.dest_name, st.permissions, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        }

        if (options.set_readonly) try setReadonly(gpa, io, dest);
    }
};

/// Stage an install destined for `dest_path`.
///
/// Arena: `dest_path`'s basename is copied into `arena` so the `Install` does
/// not outlive a caller-owned buffer.
///
/// The staging directory is a SIBLING of the destination
/// (`<parent>/.ajt-tmp-<random>`), never `$TMPDIR`. `renameat` cannot cross
/// filesystems (`EXDEV`), and a depot on its own volume -- a container mount, a
/// tmpfs, RealityForge's `/julia-depot` -- is the normal case, not the exotic
/// one. Staging elsewhere is exactly how Pkg's package installer ends up
/// silently falling back to a non-atomic copy (`Pkg/src/Operations.jl:779-821`
/// stages under `tempdir()` and finishes with `mv`, which is `cp` on EXDEV).
///
/// Creating the parent chain is a side effect that survives an abandoned
/// install, leaving an empty `packages/<Name>/`. Pkg does the same
/// (`Operations.jl:820`); removing it on abort would race a concurrent
/// installer that is holding that very directory open for its own rename.
pub fn begin(arena: Allocator, io: Io, dest_path: []const u8) BeginError!Install {
    const dest_name_raw = fspath.basename(dest_path);
    if (dest_name_raw.len == 0) return error.InvalidDestination;
    const parent = fspath.dirname(dest_path) orelse ".";

    var parent_dir = try Io.Dir.cwd().createDirPathOpen(io, parent, .{});
    errdefer parent_dir.close(io);

    var tmp_name: [tmp_name_len]u8 = undefined;
    @memcpy(tmp_name[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [tmp_random_bytes]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(tmp_name[tmp_prefix.len..], &random_bytes);

    try parent_dir.createDir(io, &tmp_name, .default_dir);
    errdefer parent_dir.deleteTree(io, &tmp_name) catch {};

    const dir = try parent_dir.openDir(io, &tmp_name, .{ .iterate = true });

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .tmp_name = tmp_name,
        .dest_name = try arena.dupe(u8, dest_name_raw),
        .staged = true,
    };
}

// ---------------------------------------------------------------------------
// set_readonly
// ---------------------------------------------------------------------------

/// Walk failures propagate, matching `walkdir`'s default `onerror = throw`.
/// (`Io.Dir.Walker` has no error set of its own; it wraps `SelectiveWalker`
/// and adds `openDir` from entering subdirectories.)
pub const SetReadonlyError = Allocator.Error || Io.Dir.SelectiveWalker.Error || Io.Dir.OpenError;

/// `Pkg.set_readonly` (`Pkg/src/utils.jl:55-78`).
///
/// For every non-symlink FILE beneath `dir`, clear the write bits:
/// `mode & ~0o222`. Directories are deliberately left alone -- a read-only
/// directory cannot be removed, so `Pkg.gc()` and `Pkg.rm` would break. That is
/// stated outright at `:59-63`.
///
/// Symlinks are skipped because `chmod` on a link changes the TARGET's
/// permissions (there is no portable `lchmod`), and the target may be outside
/// the tree entirely (`:59-64`).
///
/// Two things are swallowed rather than propagated, and both are deliberate:
/// the per-file `chmod`, matching Julia's bare `try/catch` (`:71-74`), because
/// read-only media and exotic filesystems must not fail an install over a
/// cosmetic permission bit; and the per-file `lstat`, which Julia has no
/// equivalent of -- an entry whose metadata cannot be read simply keeps its
/// write bits. Cancellation is NOT swallowed.
///
/// `gpa` backs the walker only and is released before returning.
pub fn setReadonly(gpa: Allocator, io: Io, dir: Io.Dir) SetReadonlyError!void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .sym_link => continue,
            // Some filesystems do not fill in d_type; fall through and let the
            // lstat below decide.
            else => {},
        }

        // lstat, not stat: a `.unknown` dirent that is really a symlink must
        // still be skipped.
        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        if (st.kind == .sym_link or st.kind == .directory) continue;

        // Already read-only: skip the chmod. Re-running set_readonly over a
        // warm tree is then free instead of one inode write per file.
        if (st.permissions.readOnly()) continue;

        entry.dir.setFilePermissions(io, entry.basename, st.permissions.setReadOnly(true), .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
}

/// `setReadonly` on a path. Opens and closes the directory itself.
pub fn setReadonlyPath(gpa: Allocator, io: Io, dir_path: []const u8) SetReadonlyError!void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    return setReadonly(gpa, io, dir);
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------
//
// The shared machinery behind `Depot.listPackages`/`listClones`/
// `listArtifacts`/`listScratchspaces` above.

pub const ListError = error{
    /// A path that IS a directory could not be enumerated -- a permission
    /// problem, an fd limit, a dead network mount.
    ///
    /// Deliberately not folded into "empty". An empty listing means "nothing
    /// here is orphaned"; for a sweep that is the harmless direction, but it
    /// is also indistinguishable from a depot half of which the caller cannot
    /// see, and a caller deciding what to DELETE has to be able to tell those
    /// apart. Julia's `readdir` throws here and takes `Pkg.gc()` with it.
    DirUnreadable,
} || Allocator.Error || Io.Cancelable;

/// One `readdir` entry, with its kind resolved the way Julia's `isdir`/`isfile`
/// resolve it.
pub const DirEntry = struct {
    name: []const u8,
    /// From `stat`, i.e. FOLLOWING symlinks -- `isdir(link_to_dir)` is `true`
    /// in Julia, and `Pkg.gc()` would therefore orphan (and delete) a symlinked
    /// clone that this reported as `.sym_link`. `.unknown` where the entry
    /// could not be stat'ed at all; callers skip those, which is what
    /// `isdir_nothrow` does (`utils.jl:98-105`).
    kind: Io.File.Kind,
};

/// `sort(readdir(dir_path))`, each name's kind resolved by `stat`.
///
/// A `dir_path` that does not exist or is not a directory yields an EMPTY
/// list, which is the `isdir(packagedir) || continue` guard every caller in
/// `Pkg.gc` writes by hand (`API.jl:913`, `:986`, `:997`, `:1009`). Folding it
/// in here means a missing `clones/` cannot be mistaken for "everything under
/// clones/ is garbage".
///
/// SORTED because Julia's `readdir` is (`base/file.jl`, `sort = true` by
/// default). Nothing in `gc` depends on the order -- every consumer builds a
/// set -- but the ORDER OF DELETION is user-visible in `--verbose` output and
/// in a crash halfway through, and "whatever the filesystem said" is not a
/// reproducible bug report.
///
/// Arena: names and the slice are arena-owned.
pub fn listDir(arena: Allocator, io: Io, dir_path: []const u8) ListError![]const DirEntry {
    // The `isdir(...) || continue` guard, made explicit: absent or not a
    // directory is EMPTY, and only a directory that exists but resists being
    // opened is an error.
    const st = Io.Dir.cwd().statFile(io, dir_path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return &.{},
    };
    if (st.kind != .directory) return &.{};

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DirUnreadable,
    };
    defer dir.close(io);

    var out: std.ArrayList(DirEntry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.DirUnreadable,
    }) |e| {
        // The dirent's own `kind` is not enough: many filesystems report
        // `.unknown`, and a symlink must be followed before it can be
        // classified. One `stat` per entry, at the same rate Julia pays it.
        const kind: Io.File.Kind = if (dir.statFile(io, e.name, .{})) |child|
            child.kind
        else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => .unknown,
        };
        try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .kind = kind });
    }

    const items = try out.toOwnedSlice(arena);
    std.mem.sort(DirEntry, items, {}, struct {
        fn lt(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return items;
}

/// A `packages/<Name>/<slug>` install.
pub const Installed = struct {
    name: []const u8,
    version_slug: []const u8,
    /// `joinpath(packagedir, name, slug)` -- the string `find_installed`
    /// produces for the same install, so the two can be compared directly.
    path: []const u8,
};

/// One entry under `scratchspaces/<uuid>/`.
pub const Scratch = struct {
    /// The directory name under `scratchspaces/`. A UUID string as written on
    /// disk, NOT parsed -- `gc` compares it to `Operations.PkgUUID` as a string
    /// (`API.jl:1019`), and a name that is not a UUID at all still has to be
    /// enumerated so it can be orphaned.
    uuid: []const u8,
    key: []const u8,
    path: []const u8,
    /// `.directory` is a scratchspace; a `.file` matters only under Pkg's own
    /// UUID, where the `suspend_cache_*`/`pending_cache_*` files live.
    kind: Io.File.Kind,
};

fn listChildDirs(arena: Allocator, io: Io, root: []const u8) ListError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try listDir(arena, io, root)) |e| {
        if (e.kind != .directory) continue;
        try out.append(arena, try fspath.join(arena, &.{ root, e.name }));
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Recursive delete
// ---------------------------------------------------------------------------

/// `Base.Filesystem.prepare_for_deletion` (`base/file.jl:600-621`).
///
/// The exact INVERSE of `setReadonly`, and the reason it has to exist: an
/// install is published read-only, and while POSIX only needs write permission
/// on the *containing directory* to unlink a child, a depot that has been
/// copied, restored from a backup, or written by a tarball carrying its own
/// modes can easily contain a directory with no write bit -- and then the
/// delete fails halfway, leaving a package directory that is present but
/// incomplete. That is strictly worse than either deleting it or keeping it.
///
/// So: `mode | 0o333` on every DIRECTORY beneath `path` that can be reached,
/// root included. Files are deliberately untouched (Julia does not touch them
/// either) and symlinks are skipped, because `chmod` on a link changes the
/// TARGET, which may be outside the tree -- the same rule, for the same reason,
/// as `setReadonly`. A directory that cannot be OPENED is skipped along with
/// its subtree, matching `walkdir(...; onerror = x -> ())`; since `| 0o333`
/// never adds a read bit, Julia cannot descend into it either.
///
/// Every failure is swallowed, matching Julia's `catch ex; ex isa IOError ||
/// ex isa SystemError || rethrow()`: a permission bit we could not set is not
/// a reason to abandon the delete, only a reason it may fail next. Only
/// cancellation propagates.
pub fn prepareForDeletion(gpa: Allocator, io: Io, path: []const u8) Io.Cancelable!void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // "Nothing to do for non-directories" (`:601-604`).
        else => return,
    };
    defer dir.close(io);

    makeDirWritable(io, Io.Dir.cwd(), path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };

    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();
    while (true) {
        // `walkdir(path; onerror = x -> ())` (`:611`) -- a subtree that cannot
        // be read is skipped, not fatal. `Walker.next` has already popped the
        // failing directory off its own stack, so continuing resumes one level
        // up rather than spinning on the same error.
        const maybe = walker.next(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        const entry = maybe orelse break;
        if (entry.kind != .directory) continue;
        makeDirWritable(io, entry.dir, entry.basename) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
}

/// `chmod(p, filemode(p) | 0o333)`.
///
/// The POSIX branch reproduces the mask exactly; `0o111` matters as much as
/// `0o222`, because a directory with no execute bit cannot be traversed and so
/// cannot have its children unlinked either. Windows has no mode bits at all,
/// so there the nearest thing is clearing the read-only attribute.
fn makeDirWritable(io: Io, parent: Io.Dir, sub_path: []const u8) !void {
    const st = try parent.statFile(io, sub_path, .{ .follow_symlinks = false });
    if (st.kind == .sym_link) return;
    const Perms = Io.File.Permissions;
    const wanted: Perms = if (@hasDecl(Perms, "toMode"))
        .fromMode(st.permissions.toMode() | 0o333)
    else
        st.permissions.setReadOnly(false);
    if (wanted == st.permissions) return;
    try parent.setFilePermissions(io, sub_path, wanted, .{});
}

/// `Base.Filesystem.prepare_for_deletion(path); Base.rm(path; recursive = true,
/// force = true)` (`API.jl:1080-1081`) -- the two calls are never separated,
/// so they are one function here.
///
/// `force = true` means a path that is already gone is success, which
/// `deleteTree` also gives us.
pub fn removeTree(gpa: Allocator, io: Io, path: []const u8) Io.Dir.DeleteTreeError!void {
    prepareForDeletion(gpa, io, path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
    return Io.Dir.cwd().deleteTree(io, path);
}

/// `recursive_dir_size(path)` (`API.jl:1051-1066`) for a directory, `lstat`
/// size for anything else (`:1069-1076`).
///
/// Reported, never acted on -- so every error is swallowed and contributes
/// zero, exactly as Julia's per-file `try` does. A wrong byte count must not
/// be able to change what gets deleted.
pub fn treeSize(gpa: Allocator, io: Io, path: []const u8) u64 {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
    if (st.kind != .directory) return st.size;

    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next(io) catch return total) |entry| {
        // `walkdir` yields directories in `dirs` and everything else in
        // `files`; only the latter is summed (`:1055-1057`).
        if (entry.kind == .directory) continue;
        const s = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        total +|= s.size;
    }
    return total;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const sa_uuid = "90137ffa-7385-5640-81b9-e52037218182";
const sa_tree = "246a8bb2e6667f832eea063c3a56aef96429a3db";

/// The bundled depots for a `Sys.BINDIR` of `/opt/julia/bin`.
const bundled_local = "/opt/julia/local/share/julia";
const bundled_share = "/opt/julia/share/julia";

test "DEPOT_PATH resolution matches init_depot_path for every special shape" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        why: []const u8,
        raw: ?[]const u8,
        want: []const []const u8,
    }{
        .{
            .why = "unset -> default depot, then bundled (:134-137)",
            .raw = null,
            .want = &.{ "/home/u/.julia", bundled_local, bundled_share },
        },
        .{
            // Distinct from unset, and the reason `writeDepot` is optional
            // rather than a plain index (:110-111).
            .why = "the empty STRING means no depot at all",
            .raw = "",
            .want = &.{},
        },
        .{
            .why = "the stacked production form (RealityForge's engine image)",
            .raw = "/julia-depot:/julia-depot-image",
            .want = &.{ "/julia-depot", "/julia-depot-image" },
        },
        .{
            // Bundled expands in place, AND ~/.julia is still prepended
            // because no non-empty entry occupied position 1.
            .why = "a leading empty ENTRY expands bundled in place and keeps the default",
            .raw = ":/foo",
            .want = &.{ "/home/u/.julia", bundled_local, bundled_share, "/foo" },
        },
        .{
            .why = "a trailing empty entry appends bundled, with no default prepended",
            .raw = "/foo:",
            .want = &.{ "/foo", bundled_local, bundled_share },
        },
        .{
            .why = "':' alone still yields the default depot (:129-133)",
            .raw = ":",
            .want = &.{ "/home/u/.julia", bundled_local, bundled_share },
        },
        .{
            .why = "duplicates collapse, ~ expands",
            .raw = "/a:/a:~/b:~",
            .want = &.{ "/a", "/home/u/b", "/home/u" },
        },
    };

    for (cases) |c| {
        const s = try resolve(arena, .{
            .julia_depot_path = c.raw,
            .home = "/home/u",
            .julia_bindir = "/opt/julia/bin",
        });
        errdefer std.debug.print("case: {s}\n", .{c.why});
        try testing.expectEqual(c.want.len, s.entries.len);
        for (c.want, s.entries) |want, got| try testing.expectEqualStrings(want, got);
        if (c.want.len == 0) {
            try testing.expect(s.writeDepot() == null);
        } else {
            try testing.expectEqualStrings(c.want[0], s.writeDepot().?.root);
        }
    }
}

test "DEPOT_PATH resolution fails loudly rather than dropping entries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.TildeUserUnsupported, resolve(arena, .{
        .julia_depot_path = "~someone/x",
        .home = "/home/u",
    }));
    // An empty entry with no BINDIR would silently lose the bundled depots.
    try testing.expectError(error.JuliaBindirUnknown, resolve(arena, .{
        .julia_depot_path = "/a:",
        .home = "/home/u",
    }));
    try testing.expectError(error.HomeUnknown, resolve(arena, .{}));
}

test "layout paths" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uuid = try Uuid.parse(sa_uuid);
    const tree = try Sha1.parse(sa_tree);

    // Ground truth: ~/.julia/packages/StaticArrays/0cEwi on this machine.
    const home_depot: Depot = .{ .root = "/home/u/.julia" };
    try testing.expectEqualStrings(
        "/home/u/.julia/packages/StaticArrays/0cEwi",
        try home_depot.packageVersionDir(arena, "StaticArrays", uuid, tree),
    );

    const d: Depot = .{ .root = "/d" };
    try testing.expectEqualStrings("/d/packages", try d.packagesDir(arena));
    try testing.expectEqualStrings("/d/packages/Foo", try d.packageDir(arena, "Foo"));
    try testing.expectEqualStrings("/d/packages/Foo/0cEw", try d.packageSlugDir(arena, "Foo", "0cEw"));
    try testing.expectEqualStrings(
        "/d/artifacts/" ++ sa_tree,
        try d.artifactDir(arena, tree),
    );
    try testing.expectEqualStrings("/d/registries", try d.registriesDir(arena));
    try testing.expectEqualStrings("/d/registries/General", try d.registryDir(arena, "General"));
    try testing.expectEqualStrings(
        "/d/scratchspaces/" ++ sa_uuid,
        try d.scratchspaceDir(arena, uuid),
    );
    try testing.expectEqualStrings(
        "/d/scratchspaces/" ++ sa_uuid ++ "/build",
        try d.scratchspaceKeyDir(arena, uuid, "build"),
    );
    try testing.expectEqualStrings("/d/environments/v1.12", try d.environmentDir(arena, "v1.12"));
    // Same string for the environment name and the compiled cache key.
    try testing.expectEqualStrings("v1.12", try defaultEnvironmentName(arena, 1, 12));
    try testing.expectEqualStrings("/d/compiled/v1.12", try d.compiledDir(arena, 1, 12));

    try testing.expectEqualStrings("/d/clones", try d.clonesDir(arena));
    try testing.expectEqualStrings("/d/clones/x", try d.cloneDir(arena, "x"));
    try testing.expectEqualStrings("/d/clones/" ++ sa_uuid, try d.cloneUuidDir(arena, uuid));
    try testing.expectEqualStrings("/d/dev", try d.devDir(arena));
    try testing.expectEqualStrings("/d/dev/StaticArrays", try d.devPackageDir(arena, "StaticArrays"));
}

test "cloneUrlDir is the directory Pkg.gc will look for" {
    // Ground truth from `julia -e 'using Pkg;
    //   print(Pkg.Types.add_repo_cache_path("https://github.com/JuliaLang/Example.jl.git"))'`
    // on 1.12.6. This is a landmark, not a round-trip: `Pkg.gc()` recomputes
    // this exact name and deletes every clone directory that does not match
    // one it recomputed (`API.jl:772-791`, `:985-994`), so a divergence here
    // makes Ajt's clones garbage-collected rather than reused, silently.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d: Depot = .{ .root = "/home/u/.julia" };
    try testing.expectEqualStrings(
        "/home/u/.julia/clones/4643033083726148914",
        try d.cloneUrlDir(arena, "https://github.com/JuliaLang/Example.jl.git"),
    );
    // The URL is the key verbatim: dropping `.git` is a DIFFERENT clone to Pkg,
    // so a helpful normalisation here would silently stop finding Pkg's.
    try testing.expectEqualStrings(
        "/home/u/.julia/clones/15037770950778237535",
        try d.cloneUrlDir(arena, "https://github.com/JuliaLang/Example.jl"),
    );
}

test "server host follows PlatformEngines' scheme and filename rules" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d: Depot = .{ .root = "/d" };
    try testing.expectEqualStrings(
        "/d/servers/pkg.julialang.org/auth.toml",
        try d.serverAuthFile(arena, "https://pkg.julialang.org"),
    );
    // A port makes the host illegal as a filename on Windows; ':' -> '_'.
    try testing.expectEqualStrings(
        "/d/servers/localhost_8000",
        try d.serverDir(arena, "http://localhost:8000/some/path"),
    );
    try testing.expectEqualStrings("localhost_8000", try serverHost(arena, "http://localhost:8000/x"));
    try testing.expectError(error.MalformedServerUrl, d.serverDir(arena, "pkg.julialang.org"));
    // `^\w+://` is anchored: a `://` further along is not a scheme.
    try testing.expectError(error.MalformedServerUrl, d.serverDir(arena, "not a scheme://host"));
    try testing.expectError(error.MalformedServerUrl, d.serverDir(arena, "https:///path"));
}

// --- filesystem tests: temp dirs only, never the user's real depot ---

/// Absolute path of a `testing.tmpDir`, so paths handed to `begin` (which
/// resolves against cwd) are unambiguous.
fn tmpRoot(io: Io, dir: Io.Dir, buf: *[Io.Dir.max_path_bytes]u8) ![]const u8 {
    return buf[0..try dir.realPath(io, buf)];
}

/// Asserts `sub` holds exactly one entry and that it is not a staging leftover.
fn expectSoleEntry(io: Io, parent: Io.Dir, sub: []const u8) !void {
    var dir = try parent.openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(!std.mem.startsWith(u8, e.name, tmp_prefix));
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "atomic install lands at the destination and applies the mode rule" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const d: Depot = .{ .root = try tmpRoot(io, tmp.dir, &root_buf) };

    const dest = try d.packageVersionDir(
        arena,
        "StaticArrays",
        try Uuid.parse(sa_uuid),
        try Sha1.parse(sa_tree),
    );

    var inst = try begin(arena, io, dest);
    defer inst.deinit(io);

    try inst.dir.writeFile(io, .{ .sub_path = "Project.toml", .data = "name = \"StaticArrays\"\n" });
    try inst.dir.createDirPath(io, "src");
    try inst.dir.writeFile(io, .{ .sub_path = "src/StaticArrays.jl", .data = "module StaticArrays end\n" });

    try testing.expectEqual(
        Outcome.installed,
        try inst.commit(testing.allocator, io, .{ .retry = .immediate }),
    );

    // (a) it landed where stock julia looks
    const landed = try tmp.dir.statFile(io, "packages/StaticArrays/0cEwi", .{});
    try testing.expectEqual(Io.File.Kind.directory, landed.kind);

    // (b) files lost their write bits, directories did not
    for ([_][]const u8{
        "packages/StaticArrays/0cEwi/Project.toml",
        "packages/StaticArrays/0cEwi/src/StaticArrays.jl",
    }) |f| {
        try testing.expect((try tmp.dir.statFile(io, f, .{})).permissions.readOnly());
    }
    for ([_][]const u8{
        "packages/StaticArrays/0cEwi",
        "packages/StaticArrays/0cEwi/src",
    }) |sub| {
        try testing.expect(!(try tmp.dir.statFile(io, sub, .{})).permissions.readOnly());
    }

    try expectSoleEntry(io, tmp.dir, "packages/StaticArrays");
}

test "commit can publish without making the tree read-only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const d: Depot = .{ .root = try tmpRoot(io, tmp.dir, &root_buf) };

    // `registries/` is the case: Pkg keeps it writable so it can be updated
    // in place.
    const dest = try d.registryDir(arena, "General");
    var inst = try begin(arena, io, dest);
    defer inst.deinit(io);
    try inst.dir.writeFile(io, .{ .sub_path = "Registry.toml", .data = "name = \"General\"\n" });

    try testing.expectEqual(Outcome.installed, try inst.commit(testing.allocator, io, .{
        .retry = .immediate,
        .set_readonly = false,
    }));

    const f = try tmp.dir.statFile(io, "registries/General/Registry.toml", .{});
    try testing.expect(!f.permissions.readOnly());
}

test "losing the install race reports success and cleans up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dest = try fspath.join(arena, &.{ try tmpRoot(io, tmp.dir, &root_buf), "artifacts", "deadbeef" });

    var inst = try begin(arena, io, dest);
    defer inst.deinit(io);
    try inst.dir.writeFile(io, .{ .sub_path = "mine.txt", .data = "mine\n" });

    // Another process finished first. This drives the pre-rename `isdir` check
    // (`Artifacts.jl:79`); the post-rename re-check at `:92` covers the same
    // outcome for a competitor that lands DURING our rename, which no
    // single-threaded test can schedule.
    try tmp.dir.createDirPath(io, "artifacts/deadbeef");
    try tmp.dir.writeFile(io, .{ .sub_path = "artifacts/deadbeef/theirs.txt", .data = "theirs\n" });

    try testing.expectEqual(
        Outcome.already_present,
        try inst.commit(testing.allocator, io, .{ .retry = .immediate }),
    );

    // Their content survived, ours is gone, no `.ajt-tmp-*` remains.
    _ = try tmp.dir.statFile(io, "artifacts/deadbeef/theirs.txt", .{});
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "artifacts/deadbeef/mine.txt", .{}),
    );
    try expectSoleEntry(io, tmp.dir, "artifacts");
}

test "abandoning an install leaves nothing published" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dest = try fspath.join(arena, &.{ try tmpRoot(io, tmp.dir, &root_buf), "artifacts", "cafe" });

    {
        var inst = try begin(arena, io, dest);
        defer inst.deinit(io);
        try inst.dir.writeFile(io, .{ .sub_path = "x", .data = "x" });
        // ... verification fails, so no commit.
    }

    // The staging directory is gone. The parent `artifacts/` stays -- see
    // `begin`'s note on why removing it would race a concurrent installer.
    var dir = try tmp.dir.openDir(io, "artifacts", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try testing.expect((try it.next(io)) == null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "artifacts/cafe", .{}));
}

test "set_readonly leaves symlinks and directories alone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/target.txt", .data = "t\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/deep.txt", .data = "d\n" });
    const can_symlink = if (tmp.dir.symLink(io, "target.txt", "tree/link.txt", .{})) |_| true else |_| false;

    var tree_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tree_len = try tmp.dir.realPathFile(io, "tree", &tree_buf);
    try setReadonlyPath(testing.allocator, io, tree_buf[0..tree_len]);

    try testing.expect((try tmp.dir.statFile(io, "tree/target.txt", .{})).permissions.readOnly());
    try testing.expect((try tmp.dir.statFile(io, "tree/sub/deep.txt", .{})).permissions.readOnly());
    try testing.expect(!(try tmp.dir.statFile(io, "tree/sub", .{})).permissions.readOnly());

    if (can_symlink) {
        // The link itself was not chmod'ed: its own (lstat) mode still has the
        // write bits, which is how a symlink is always created.
        const l = try tmp.dir.statFile(io, "tree/link.txt", .{ .follow_symlinks = false });
        try testing.expectEqual(Io.File.Kind.sym_link, l.kind);
        try testing.expect(!l.permissions.readOnly());
    }
}

test "enumeration reports what a sweep would consider, and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const d: Depot = .{ .root = try tmpRoot(io, tmp.dir, &root_buf) };

    // `packages/<Name>/<slug>`, plus two things a sweep must NOT report: a
    // stray file where a package name would go, and one where a slug would.
    try tmp.dir.createDirPath(io, "packages/StaticArrays/0cEwi");
    try tmp.dir.createDirPath(io, "packages/Example/aBcDe");
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/stray.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/Example/README", .data = "" });

    const pkgs = try d.listPackages(arena, io);
    try testing.expectEqual(@as(usize, 2), pkgs.len);
    // Sorted, so the order is reproducible rather than the filesystem's.
    try testing.expectEqualStrings("Example", pkgs[0].name);
    try testing.expectEqualStrings("aBcDe", pkgs[0].version_slug);
    try testing.expectEqualStrings("StaticArrays", pkgs[1].name);
    // The path is byte-identical to what `findInstalled` produces, which is
    // the whole basis of the keep/orphan comparison in `ops/gc.zig`.
    try testing.expectEqualStrings(
        try d.packageSlugDir(arena, "StaticArrays", "0cEwi"),
        pkgs[1].path,
    );

    // `artifacts/Overrides.toml` is a FILE and must survive a sweep.
    try tmp.dir.createDirPath(io, "artifacts/deadbeef");
    try tmp.dir.writeFile(io, .{ .sub_path = "artifacts/Overrides.toml", .data = "" });
    const arts = try d.listArtifacts(arena, io);
    try testing.expectEqual(@as(usize, 1), arts.len);
    try testing.expectEqualStrings("deadbeef", fspath.basename(arts[0]));

    try tmp.dir.createDirPath(io, "clones/4643033083726148914");
    const clones = try d.listClones(arena, io);
    try testing.expectEqual(@as(usize, 1), clones.len);

    // Scratchspaces report FILES too -- Pkg's `suspend_cache_*` markers live
    // directly under its own uuid and are the one non-directory `gc` deletes.
    try tmp.dir.createDirPath(io, "scratchspaces/" ++ sa_uuid ++ "/build");
    try tmp.dir.writeFile(io, .{ .sub_path = "scratchspaces/" ++ sa_uuid ++ "/marker", .data = "" });
    const spaces = try d.listScratchspaces(arena, io);
    try testing.expectEqual(@as(usize, 2), spaces.len);
    try testing.expectEqualStrings("build", spaces[0].key);
    try testing.expectEqual(Io.File.Kind.directory, spaces[0].kind);
    try testing.expectEqualStrings("marker", spaces[1].key);
    try testing.expectEqual(Io.File.Kind.file, spaces[1].kind);

    // An absent store is EMPTY, not an error: a depot with no `clones/` must
    // not read as "everything under clones/ is garbage".
    const empty: Depot = .{ .root = try fspath.join(arena, &.{ d.root, "nope" }) };
    try testing.expectEqual(@as(usize, 0), (try empty.listPackages(arena, io)).len);
    try testing.expectEqual(@as(usize, 0), (try empty.listClones(arena, io)).len);
}

test "removeTree undoes set_readonly, which nothing else can" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &root_buf);
    const tree = try fspath.join(arena, &.{ root, "tree" });

    try tmp.dir.createDirPath(io, "tree/sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/deeper/b.txt", .data = "b" });
    try setReadonlyPath(testing.allocator, io, tree);
    // ...and a directory with no write bit at all, which is what a restored
    // backup or a mode-carrying tarball can leave behind. Without
    // `prepare_for_deletion` its children cannot be unlinked.
    const sub = try fspath.join(arena, &.{ tree, "sub" });
    try Io.Dir.cwd().setFilePermissions(io, sub, .fromMode(0o555), .{});

    const size = treeSize(testing.allocator, io, tree);
    try testing.expectEqual(@as(u64, 2), size);

    try removeTree(testing.allocator, io, tree);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "tree", .{}));

    // `force = true`: a path that is already gone is success.
    try removeTree(testing.allocator, io, tree);
}

test "findInstalled probes every depot at p=5 before any at p=4" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &root_buf);

    const write_root = try fspath.join(arena, &.{ root, "w" });
    const image_root = try fspath.join(arena, &.{ root, "i" });
    const stack: Stack = .{ .entries = &.{ write_root, image_root } };

    const uuid = try Uuid.parse(sa_uuid);
    const tree = try Sha1.parse(sa_tree);

    // Nothing installed: the would-be path in the WRITE depot, at p=5.
    const missing = try findInstalled(arena, io, stack, "StaticArrays", uuid, tree);
    try testing.expect(!missing.exists);
    try testing.expectEqualStrings(
        try fspath.join(arena, &.{ write_root, "packages/StaticArrays/0cEwi" }),
        missing.path,
    );

    // A legacy p=4 directory in the writable depot must NOT beat a current
    // p=5 directory in the image depot.
    try tmp.dir.createDirPath(io, "w/packages/StaticArrays/0cEw");
    try tmp.dir.createDirPath(io, "i/packages/StaticArrays/0cEwi");
    const found = try findInstalled(arena, io, stack, "StaticArrays", uuid, tree);
    try testing.expect(found.exists);
    try testing.expectEqualStrings(
        try fspath.join(arena, &.{ image_root, "packages/StaticArrays/0cEwi" }),
        found.path,
    );

    // An empty DEPOT_PATH has nowhere to install to and must say so rather
    // than inventing a path under the process cwd.
    try testing.expectError(
        error.NoDepot,
        findInstalled(arena, io, .{ .entries = &.{} }, "StaticArrays", uuid, tree),
    );
}

test "installedExists answers exactly what findInstalled's `exists` does" {
    // The two share a probe order and a slug rule and must never drift: the
    // resolver's `installed_only` filter reads one and every install path
    // reads the other, so a disagreement would let a resolve choose a version
    // the installer then re-downloads (or worse, cannot find).
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &root_buf);

    const write_root = try fspath.join(arena, &.{ root, "w" });
    const image_root = try fspath.join(arena, &.{ root, "i" });
    const stack: Stack = .{ .entries = &.{ write_root, image_root } };

    const uuid = try Uuid.parse(sa_uuid);
    const tree = try Sha1.parse(sa_tree);

    try testing.expect(!installedExists(io, stack, "StaticArrays", uuid, tree));

    // p=5 in the non-writable depot: a hit, and the same hit `findInstalled`
    // reports.
    try tmp.dir.createDirPath(io, "i/packages/StaticArrays/0cEwi");
    try testing.expect(installedExists(io, stack, "StaticArrays", uuid, tree));
    try testing.expect((try findInstalled(arena, io, stack, "StaticArrays", uuid, tree)).exists);

    // The legacy p=4 spelling counts too, on its own.
    var tmp4 = testing.tmpDir(.{ .iterate = true });
    defer tmp4.cleanup();
    var root4_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root4 = try tmpRoot(io, tmp4.dir, &root4_buf);
    const stack4: Stack = .{ .entries = &.{root4} };
    try testing.expect(!installedExists(io, stack4, "StaticArrays", uuid, tree));
    try tmp4.dir.createDirPath(io, "packages/StaticArrays/0cEw");
    try testing.expect(installedExists(io, stack4, "StaticArrays", uuid, tree));

    // An empty stack is "nothing is installed", NOT `error.NoDepot`: a yes/no
    // question has an answer where "where would it go" does not.
    try testing.expect(!installedExists(io, .{ .entries = &.{} }, "StaticArrays", uuid, tree));
}
