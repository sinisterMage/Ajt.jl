//! The Pkg-server HTTP client.
//!
//! A thin, deliberately un-clever wrapper over `std.http.Client` that speaks
//! the protocol Pkg speaks: the `Julia-*` metadata headers
//! (`Pkg/src/PlatformEngines.jl:220-252`), bearer tokens from the depot
//! (`net/auth.zig`), curl's redirect behaviour as Julia configures it
//! (`Downloads/src/Curl/Easy.jl:77-78`), and call-site retry
//! (`Pkg/src/Registry/Registry.jl:76`).
//!
//! ## Why the redirects are hand-rolled
//!
//! `std.http.Client` follows redirects for you, but it decides whether to keep
//! `privileged_headers` (i.e. `Authorization`) with `sameParentDomain`
//! (`std/http/Client.zig:1242-1244`) -- `pkg.julialang.org` and
//! `in.pkg.julialang.org` count as the same domain, so the token would travel
//! to the mirror. libcurl strips a caller-supplied `Authorization` on ANY
//! cross-host redirect, and `pkg.julialang.org/registries` really does 301 to
//! a regional mirror, so that difference is reached on the very first request
//! Ajt makes. Driving the loop here keeps the stricter rule *and* lets us use
//! curl's `CURLOPT_MAXREDIRS` of 50 rather than std's default of 3.
//!
//! There is a second, blunter reason: in Zig 0.16.0 `privileged_headers` are
//! never written to the wire at all. `sendHead` emits `extra_headers` and
//! stops (`std/http/Client.zig:1066-1073`); the privileged list exists only so
//! `redirect` can clear it. Handing the bearer token to that field authenticates
//! nothing, and fails as a 401 rather than as a compile error.
//!
//! ## Concurrency
//!
//! `default_concurrency` mirrors `num_concurrent_downloads()`
//! (`Pkg/src/Types.jl:463-471`), but this module deliberately ships no
//! scheduler: it is the transport, and whoever installs packages decides how
//! many of these to run at once.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

pub const auth = @import("auth.zig");

const jenv = @import("../julia/env.zig");

/// `num_concurrent_downloads()` default (`Types.jl:463-467`).
pub const default_concurrency: u32 = 8;

/// `JULIA_PKG_OFFLINE` was set to something `Base.get_bool_env` does not
/// recognise. Pkg does not survive that either: `__init__` assigns the
/// resulting `nothing` into `OFFLINE_MODE`, which is a `Ref{Bool}`
/// (`Pkg.jl:45`, `:827`), so `using Pkg` aborts with a MethodError "during
/// initialization of module Pkg". Verified by running it with
/// `JULIA_PKG_OFFLINE` set to `on`, `off` and `garbage`. Refusing here is the
/// same answer with a better sentence.
pub const OfflineError = error{InvalidOfflineSetting};

/// `OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)`
/// (`Pkg/src/Pkg.jl:827`).
pub fn offlineFromEnv(environ: *const std.process.Environ.Map) OfflineError!bool {
    return jenv.getBool(environ.get("JULIA_PKG_OFFLINE"), false) catch
        error.InvalidOfflineSetting;
}

/// `JULIA_PKG_CONCURRENT_DOWNLOADS` (`Types.jl:463-471`). Julia hard-errors on
/// a non-integer or a value below 1 rather than silently falling back.
pub fn concurrency(raw: ?[]const u8) error{InvalidConcurrency}!u32 {
    const val = raw orelse return default_concurrency;
    const n = std.fmt.parseInt(i64, val, 10) catch return error.InvalidConcurrency;
    if (n < 1) return error.InvalidConcurrency;
    return @intCast(@min(n, std.math.maxInt(u32)));
}

/// `CI_VARIABLES` (`PlatformEngines.jl:205-219`), in order. The ORDER is part
/// of the wire format: the header is a `;`-joined list of `NAME=state` in
/// exactly this sequence, so a server can index it positionally.
pub const ci_variables = [_][]const u8{
    "APPVEYOR",
    "CI",
    "CI_SERVER",
    "CIRCLECI",
    "CONTINUOUS_INTEGRATION",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "JULIA_CI",
    "JULIA_PKGEVAL",
    "JULIA_REGISTRYCI_AUTOMERGE",
    "TF_BUILD",
    "TRAVIS",
};

/// The four states a CI variable reports (`PlatformEngines.jl:231-236`):
/// `n` unset, `t` truthy, `f` falsy, `o` set to something else entirely.
/// Note that the empty string is `o`, not `n` -- Julia only checks `ENV`
/// membership, never emptiness.
pub fn ciState(val: ?[]const u8) u8 {
    const v = val orelse return 'n';
    if (eqlLower(v, "true") or eqlLower(v, "t") or eqlLower(v, "1") or
        eqlLower(v, "yes") or eqlLower(v, "y")) return 't';
    if (eqlLower(v, "false") or eqlLower(v, "f") or eqlLower(v, "0") or
        eqlLower(v, "no") or eqlLower(v, "n")) return 'f';
    return 'o';
}

fn eqlLower(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Renders the `Julia-CI-Variables` value. Arena-allocated.
pub fn ciVariablesValue(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (ci_variables, 0..) |name, i| {
        if (i != 0) aw.writer.writeByte(';') catch return error.OutOfMemory;
        aw.writer.print("{s}={c}", .{ name, ciState(environ.get(name)) }) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// Everything the metadata headers need, snapshotted once.
///
/// Julia rebuilds these from `ENV` on every single download; snapshotting is
/// the one intentional difference, and it is what makes `metadataHeaders`
/// pure and testable.
pub const Config = struct {
    /// Normalised `pkg_server()`. Null disables the protocol entirely.
    server: ?[]const u8 = null,
    /// `depots1()`. Null models an empty `DEPOT_PATH`, which per
    /// `get_server_dir` (:57) also suppresses the metadata headers.
    depot: ?[]const u8 = null,
    /// `string(VERSION)`.
    julia_version: []const u8 = "",
    /// `triplet(HostPlatform())` -- see `julia/platform.zig` `detectHost`.
    julia_system: []const u8 = "",
    /// `string(isinteractive())`. A CLI is never interactive.
    interactive: bool = false,
    /// Pre-rendered `Julia-CI-Variables` value.
    ci_variables: []const u8 = "",
    /// `Julia-<Titlecased-Words>` headers derived from `JULIA_PKG_SERVER_*`
    /// (:241-251).
    server_env_headers: []const http.Header = &.{},
    /// `num_concurrent_downloads()`. Carried here so callers that DO schedule
    /// downloads read one number from one place.
    concurrency: u32 = default_concurrency,

    /// `Pkg.OFFLINE_MODE[]` (`Pkg/src/Pkg.jl:45`), the transport half of it.
    ///
    /// Pkg models this as a process-global `Ref{Bool}`; here it rides on the
    /// transport config because that is the object every module that can make
    /// a request already holds, so setting it once at the CLI boundary reaches
    /// the registry download, the package downloads, the artifact downloads
    /// and the shared-cache store without a second switch to keep in sync.
    ///
    /// **This is deliberately STRONGER than Pkg's**, and the difference is
    /// worth knowing. `OFFLINE_MODE` is consulted in exactly two places
    /// (`Operations.jl:500` and `:1629`); `download_source` (`:1000-1020`),
    /// `download_artifacts` (`:1023-1050`) and `Registry.add` have no offline
    /// check at all, so a `Pkg.instantiate()` whose manifest names an
    /// uninstalled version happily downloads it with `JULIA_PKG_OFFLINE=1`
    /// set. Ajt refuses at the socket instead. That cannot change the output
    /// of a run Pkg completes without the network, and it turns the one shape
    /// Pkg gets wrong — "offline mode still went to the internet" — into an
    /// error naming the reason. Recorded in `Ajt.DIFFERENCES[:offline]`.
    offline: bool = false,

    /// Reads everything derivable from the environment. Arena-allocated:
    /// every string in the result has the Config's lifetime.
    ///
    /// Fields already set in `base` win, which means a caller that genuinely
    /// wants the server DISABLED (`server = null`) cannot express it here --
    /// null is indistinguishable from "not supplied". Callers with an explicit
    /// `--server ""` have to re-apply it afterwards; `ajt fetch` does.
    pub fn fromEnv(
        arena: Allocator,
        environ: *const std.process.Environ.Map,
        base: Config,
    ) (Allocator.Error || error{InvalidConcurrency} || OfflineError)!Config {
        var cfg = base;
        if (cfg.server == null) cfg.server = try auth.pkgServer(arena, environ.get("JULIA_PKG_SERVER"));
        if (cfg.depot == null) cfg.depot = try depots1(arena, environ);
        if (cfg.ci_variables.len == 0) cfg.ci_variables = try ciVariablesValue(arena, environ);
        if (cfg.server_env_headers.len == 0) cfg.server_env_headers = try serverEnvHeaders(arena, environ);
        cfg.concurrency = try concurrency(environ.get("JULIA_PKG_CONCURRENT_DOWNLOADS"));
        // OR, not "fill if unset": `base.offline` is how `--offline` reaches
        // here, and a flag the user typed must not be undone by an unset
        // environment variable. The variable can only ever turn it ON.
        cfg.offline = cfg.offline or try offlineFromEnv(environ);
        return cfg;
    }
};

/// `depots1()`: the FIRST entry of `JULIA_DEPOT_PATH`, else `~/.julia`. A
/// stacked depot path reads from all of them but writes -- including the
/// `servers/` auth files -- only to the first.
pub fn depots1(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (environ.get("JULIA_DEPOT_PATH")) |v| {
        if (v.len != 0) {
            const first = std.mem.sliceTo(v, ':');
            if (first.len != 0) return first;
        }
    }
    const home = environ.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ home, ".julia" });
}

/// `JULIA_PKG_SERVER_<NAME>` -> `Julia-<Name>` (:241-251).
///
/// Julia title-cases each `_`-separated word (`titlecase` is strict, so
/// `REGISTRY_PREFERENCE` becomes `Registry-Preference`), skips empty values
/// after stripping, and skips any header name already emitted.
///
/// One deliberate difference: Julia iterates `ENV` in hash order, so with two
/// such variables its header order is unspecified. We sort by name, because a
/// client that emits different bytes run to run cannot be differentially
/// tested.
pub fn serverEnvHeaders(
    arena: Allocator,
    environ: *const std.process.Environ.Map,
) Allocator.Error![]const http.Header {
    var out: std.ArrayList(http.Header) = .empty;
    const prefix = "JULIA_PKG_SERVER_";

    for (environ.keys(), environ.values()) |key, val| {
        if (!std.ascii.startsWithIgnoreCase(key, prefix)) continue;
        const suffix = key[prefix.len..];
        if (suffix.len == 0) continue;
        // `[A-Z0-9_]+` under `i`: anything else is not a match at all.
        for (suffix) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        } else {
            const value = std.mem.trim(u8, val, " \t\r\n\x0b\x0c");
            if (value.len == 0) continue;
            const name = try titlecaseWords(arena, suffix) orelse continue;
            for (out.items) |h| {
                if (std.mem.eql(u8, h.name, name)) break;
            } else try out.append(arena, .{ .name = name, .value = value });
        }
    }

    std.mem.sort(http.Header, out.items, {}, struct {
        fn lt(_: void, a: http.Header, b: http.Header) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items;
}

/// `"Julia-" * join(map(titlecase, split(s, '_', keepempty=false)), '-')`.
/// Null when the split yields no words (`isempty(words) && continue`).
fn titlecaseWords(arena: Allocator, s: []const u8) Allocator.Error!?[]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("Julia") catch return error.OutOfMemory;
    var it = std.mem.splitScalar(u8, s, '_');
    var any = false;
    while (it.next()) |word| {
        if (word.len == 0) continue; // keepempty = false
        any = true;
        aw.writer.writeByte('-') catch return error.OutOfMemory;
        aw.writer.writeByte(std.ascii.toUpper(word[0])) catch return error.OutOfMemory;
        // `titlecase` defaults to strict, so the tail is lower-cased:
        // JULIA_PKG_SERVER_REGISTRY -> Julia-Registry, not Julia-REGISTRY.
        for (word[1..]) |c| aw.writer.writeByte(std.ascii.toLower(c)) catch return error.OutOfMemory;
    }
    if (!any) return null;
    return try aw.toOwnedSlice();
}

/// `get_metadata_headers(url)` (:220-252). Empty when the URL does not target
/// the Pkg server -- these headers are never sent to arbitrary hosts.
/// Arena-allocated.
pub fn metadataHeaders(arena: Allocator, cfg: Config, url: []const u8) Allocator.Error![]const http.Header {
    if (!auth.targetsServer(.{ .depot = cfg.depot, .server = cfg.server, .url = url })) return &.{};

    var out: std.ArrayList(http.Header) = .empty;
    try out.append(arena, .{ .name = "Julia-Pkg-Protocol", .value = "1.0" });
    try out.append(arena, .{ .name = "Julia-Pkg-Server", .value = cfg.server.? });
    try out.append(arena, .{ .name = "Julia-Version", .value = cfg.julia_version });
    try out.append(arena, .{ .name = "Julia-System", .value = cfg.julia_system });
    try out.append(arena, .{ .name = "Julia-CI-Variables", .value = cfg.ci_variables });
    try out.append(arena, .{
        .name = "Julia-Interactive",
        .value = if (cfg.interactive) "true" else "false",
    });
    for (cfg.server_env_headers) |h| {
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen.name, h.name)) break;
        } else try out.append(arena, h);
    }
    return out.items;
}

/// `retry(delays = ...)` at a call site. Julia's `download` itself never
/// retries; `pkg_server_registry_info` wraps it (`Registry.jl:76`).
pub const Retry = struct {
    /// Total attempts, i.e. `length(delays) + 1`. Zero is treated as one.
    attempts: u32 = 1,
    delay: Io.Duration = .{ .nanoseconds = std.time.ns_per_s },

    pub const none: Retry = .{ .attempts = 1 };
    /// `retry(delays = fill(1.0, 3))` (`Registry.jl:76`): four attempts, one
    /// second apart.
    pub const pkg_server: Retry = .{ .attempts = 4, .delay = .{ .nanoseconds = std.time.ns_per_s } };
};

pub const GetOptions = struct {
    retry: Retry = .none,
    /// `CURLOPT_MAXREDIRS` (`Downloads/src/Curl/Easy.jl:78`).
    max_redirects: u16 = 50,
    /// Backing store for redirect targets; each hop consumes part of it.
    /// RFC 9110 recommends at least 8000 bytes for a single location.
    redirect_buffer_size: usize = 16 * 1024,
    /// Cap on a buffered body. Ignored when `sink` is set.
    max_body_bytes: usize = 1 << 30,
    /// Attach the depot's bearer token when the URL targets the Pkg server.
    authenticate: bool = true,
    /// Stream the body here instead of buffering it into the arena.
    sink: ?*Io.Writer = null,
    /// Extra request headers, sent on every hop like curl's
    /// `CURLOPT_HTTPHEADER`.
    extra_headers: []const http.Header = &.{},
};

/// A write. Deliberately NOT a superset of `GetOptions`: there is no `sink`
/// (a PUT response is small by construction) and no `max_redirects` (see
/// `Client.put`).
pub const PutOptions = struct {
    /// Defaults to `.none`. Safe to raise ONLY when the target URL is
    /// content-addressed — see `Client.put`.
    retry: Retry = .none,
    /// Attach the depot's bearer token when the URL targets the Pkg server.
    /// A store hosted somewhere else supplies its own credential through
    /// `extra_headers`, so that `net/auth.zig`'s targeting rule stays the only
    /// thing that decides where a DEPOT token may travel.
    authenticate: bool = true,
    /// `Content-Type` for the body. Null omits the header, which is what std
    /// and curl both do — `application/octet-stream` is the default anyway.
    content_type: ?[]const u8 = null,
    extra_headers: []const http.Header = &.{},
    /// Cap on the RESPONSE body, not the request.
    max_body_bytes: usize = 1 << 20,
};

/// The full failure surface of a GET. Spelled out rather than inferred
/// because `getOnce` -> `authorization` -> `refresh` -> `getOnce` is a cycle,
/// and Zig cannot infer around one.
pub const GetError = Allocator.Error ||
    Io.Cancelable ||
    Io.Writer.Error ||
    http.Client.RequestError ||
    http.Client.Request.ReceiveHeadError ||
    http.Reader.BodyError ||
    error{ InvalidUrl, ResponseTooLarge, Offline };

pub const Response = struct {
    status: http.Status,
    /// Arena-allocated. Empty when `GetOptions.sink` was supplied.
    body: []const u8,
    /// The URL that actually served the response, after redirects.
    url: []const u8,
    redirects: u16,

    pub fn ok(r: Response) bool {
        return r.status.class() == .success;
    }
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: http.Client,
    config: Config,

    pub fn init(gpa: Allocator, io: Io, config: Config) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .http = .{ .allocator = gpa, .io = io },
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// GET `url`, following redirects and retrying per `opts.retry`.
    ///
    /// Every byte of the result is allocated in `arena` and shares its
    /// lifetime; the response body of a registry tarball is tens of megabytes,
    /// so handing this a general-purpose allocator is a leak, not a slowdown.
    ///
    /// A non-2xx status is returned as a `Response`, not an error -- callers
    /// need the code (a 404 for a package version is information, not a
    /// failure) -- but it DOES count as a failed attempt for retry purposes,
    /// which is what Julia's `retry(download(...))` does: `Downloads.download`
    /// throws on any non-success status.
    /// Note that a retried attempt leaves its predecessor's allocations --
    /// headers, redirect buffer, a discarded body -- behind in `arena`. With
    /// Julia's four-attempt budget that is bounded and cheap; it is another
    /// reason the arena is not optional.
    pub fn get(self: *Client, arena: Allocator, url: []const u8, opts: GetOptions) GetError!Response {
        const total = @max(opts.retry.attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const last = attempt >= total;
            if (self.getOnce(arena, url, opts)) |res| {
                if (res.ok() or last) return res;
            } else |err| {
                switch (err) {
                    // Nothing a second attempt could change: retrying these
                    // only burns the caller's time on a fixed outcome.
                    // `Offline` in particular would otherwise cost the
                    // `pkg_server` budget's three one-second sleeps to reach
                    // the same refusal.
                    error.Canceled, error.OutOfMemory, error.InvalidUrl, error.Offline => return err,
                    else => if (last) return err,
                }
            }
            // `.awake` is the monotonic clock that does not tick while suspended,
            // which is the right one for a backoff.
            try self.io.sleep(opts.retry.delay, .awake);
        }
    }

    fn getOnce(self: *Client, arena: Allocator, url: []const u8, opts: GetOptions) GetError!Response {
        // The gate is HERE, not in `get`, because `getOnce` is the single
        // place a GET reaches the wire: `get`'s retry loop and `refresh`'s
        // token exchange both come through it, and `refresh` bypasses `get`
        // entirely. One check, no reachable path around it.
        if (self.config.offline) return error.Offline;

        const metadata = try metadataHeaders(arena, self.config, url);
        var bearer: ?[]const u8 = if (opts.authenticate)
            try self.authorization(arena, url)
        else
            null;

        // Header lists are externally owned and must outlive the Request, so
        // they are built once, out here, rather than per hop. Slot 0 is
        // reserved for `Authorization`; dropping the token is then just a
        // matter of starting the slice one element later.
        //
        // The token goes in `extra_headers`, NOT `privileged_headers`, even
        // though the latter is exactly what it is: Zig 0.16.0's `sendHead`
        // (`std/http/Client.zig:1066-1073`) writes `extra_headers` and never
        // writes `privileged_headers` at all -- it only tracks them so it can
        // strip them across a redirect. Putting the token there sends no
        // credentials whatsoever, silently. The stripping this module needs is
        // hand-rolled below anyway.
        var all: std.ArrayList(http.Header) = .empty;
        try all.append(arena, .{ .name = "Authorization", .value = "" });
        try all.appendSlice(arena, opts.extra_headers);
        try all.appendSlice(arena, metadata);

        var aux: []u8 = try arena.alloc(u8, opts.redirect_buffer_size);
        var uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const origin = uri;
        var redirects: u16 = 0;

        while (true) {
            const headers: []const http.Header = if (bearer) |v| h: {
                all.items[0].value = v;
                break :h all.items;
            } else all.items[1..];

            var req = try self.http.request(.GET, uri, .{
                // We drive redirects ourselves; see the module comment.
                .redirect_behavior = .unhandled,
                .extra_headers = headers,
                .headers = .{
                    // curl sends no Accept-Encoding unless asked
                    // (`CURLOPT_ACCEPT_ENCODING` is never set by Downloads),
                    // so servers answer identity. Registry tarballs are
                    // already gzip *content*; advertising gzip here would add
                    // a transport layer Julia never sees.
                    .accept_encoding = .omit,
                },
            });
            defer req.deinit();
            try req.sendBodiless();

            var response = try req.receiveHead(&.{});
            const status = response.head.status;

            // 304 carries no body and is not a redirect despite its class.
            // 305 is deprecated and libcurl refuses to follow it, so it is
            // handed back to the caller rather than acted on.
            const is_redirect = status.class() == .redirect and
                status != .not_modified and
                status != .use_proxy;
            if (is_redirect) {
                if (redirects >= opts.max_redirects) return error.TooManyHttpRedirects;
                const location = response.head.location orelse return error.HttpRedirectLocationMissing;
                if (location.len > aux.len) return error.HttpRedirectLocationOversize;
                // `head` points into the connection's read buffer, which the
                // body reader (and `req.deinit`) invalidates. Copy first.
                @memcpy(aux[0..location.len], location);
                const next = uri.resolveInPlace(location.len, &aux) catch
                    return error.HttpRedirectLocationInvalid;

                // libcurl drops a caller-supplied `Authorization` as soon as
                // scheme, host or port change; only then is it a different
                // security origin.
                if (!sameOrigin(origin, next)) bearer = null;

                uri = next;
                redirects += 1;
                continue;
            }

            const final_url = try std.fmt.allocPrint(arena, "{f}", .{&uri});

            if (!req.method.responseHasBody() or status == .not_modified) {
                return .{ .status = status, .body = "", .url = final_url, .redirects = redirects };
            }

            // Unsolicited compression still has to be decoded: we asked for
            // none, but a proxy may gzip anyway.
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.HttpContentEncodingUnsupported,
            };
            var transfer_buffer: [4096]u8 = undefined;
            var decompress: http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

            if (opts.sink) |w| {
                _ = reader.streamRemaining(w) catch |err| switch (err) {
                    error.ReadFailed => return response.bodyErr().?,
                    else => |e| return e,
                };
                return .{ .status = status, .body = "", .url = final_url, .redirects = redirects };
            }

            // The cap is enforced DURING the read, not after: a server that
            // answers a registry request with an endless stream must not be
            // able to exhaust memory first and be rejected second.
            //
            // `Limit.limited(n)` is off by one for this purpose:
            // `appendRemainingAligned` only succeeds if EndOfStream arrives
            // BEFORE the limit is consumed (`std/Io/Reader.zig:376-386`), so a
            // body of exactly n bytes fails. Asking for n+1 makes the cap
            // inclusive, which is what "max" reads as.
            const cap: Io.Limit = if (opts.max_body_bytes == std.math.maxInt(usize))
                .unlimited
            else
                .limited(opts.max_body_bytes + 1);
            const body = reader.allocRemaining(arena, cap) catch |err| switch (err) {
                error.StreamTooLong => return error.ResponseTooLarge,
                error.ReadFailed => return response.bodyErr().?,
                else => |e| return e,
            };
            return .{
                .status = status,
                .body = body,
                .url = final_url,
                .redirects = redirects,
            };
        }
    }

    /// PUT `body` to `url`, retrying per `opts.retry`.
    ///
    /// This is the ONE write verb the client has, and it exists for the
    /// content-addressed object store (`cache/store.zig`), not for anything
    /// Pkg does — Pkg only ever reads. Two rules are different from `get`, and
    /// both are about not handing a body or a credential to a host the caller
    /// did not name:
    ///
    ///   * **Redirects are not followed.** `get` follows up to 50 hops because
    ///     `pkg.julialang.org/registries` really does 301 to a regional mirror.
    ///     A write has no such requirement, and following one means re-sending
    ///     the body (and deciding whether the token goes with it) to a
    ///     Location the server chose. A 3xx therefore comes back as an ordinary
    ///     non-success `Response`, which `ok()` reports as false.
    ///   * **Retry is safe here for a specific reason, not by default.** PUT is
    ///     idempotent (RFC 9110 §9.2.2) and the store addresses every object by
    ///     the hash of its own body, so a re-sent request is byte-identical to
    ///     the one before it and lands in the same place. `opts.retry` still
    ///     defaults to `.none`: it is the caller who knows the URL is
    ///     content-addressed.
    ///
    /// Arena-lifetime, and the same warning as `get`: every attempt's
    /// allocations stay in `arena` until the caller drops it.
    pub fn put(
        self: *Client,
        arena: Allocator,
        url: []const u8,
        body: []const u8,
        opts: PutOptions,
    ) GetError!Response {
        const total = @max(opts.retry.attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const last = attempt >= total;
            if (self.putOnce(arena, url, body, opts)) |res| {
                if (res.ok() or last) return res;
            } else |err| {
                switch (err) {
                    error.Canceled, error.OutOfMemory, error.InvalidUrl, error.Offline => return err,
                    else => if (last) return err,
                }
            }
            try self.io.sleep(opts.retry.delay, .awake);
        }
    }

    fn putOnce(
        self: *Client,
        arena: Allocator,
        url: []const u8,
        body: []const u8,
        opts: PutOptions,
    ) GetError!Response {
        if (self.config.offline) return error.Offline;

        const metadata = try metadataHeaders(arena, self.config, url);
        const bearer: ?[]const u8 = if (opts.authenticate)
            try self.authorization(arena, url)
        else
            null;

        // Same reasoning as `getOnce`: the token rides in `extra_headers`
        // because Zig 0.16.0's `sendHead` never writes `privileged_headers` to
        // the wire at all. There is no slot-0 dance here because there is no
        // redirect loop to strip it in — the header list is built once and used
        // once.
        var all: std.ArrayList(http.Header) = .empty;
        if (bearer) |v| try all.append(arena, .{ .name = "Authorization", .value = v });
        try all.appendSlice(arena, opts.extra_headers);
        try all.appendSlice(arena, metadata);

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        var req = try self.http.request(.PUT, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = all.items,
            .headers = .{
                .accept_encoding = .omit,
                .content_type = if (opts.content_type) |ct|
                    .{ .override = ct }
                else
                    .default, // std omits it, which is what curl does too
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        // An empty writer buffer streams straight through to the connection:
        // an object is up to hundreds of megabytes and must not be copied
        // again on its way out.
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        const final_url = try std.fmt.allocPrint(arena, "{f}", .{&uri});

        if (status == .no_content or status == .not_modified) {
            return .{ .status = status, .body = "", .url = final_url, .redirects = 0 };
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.HttpContentEncodingUnsupported,
        };
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        // A PUT response body is an error document or a receipt, never bulk
        // data, so it is always buffered and always capped. See `get` for why
        // the limit is `n + 1`.
        const cap: Io.Limit = if (opts.max_body_bytes == std.math.maxInt(usize))
            .unlimited
        else
            .limited(opts.max_body_bytes + 1);
        const buf = reader.allocRemaining(arena, cap) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{ .status = status, .body = buf, .url = final_url, .redirects = 0 };
    }

    /// The `Authorization` value for `url`, refreshing the token first when
    /// Julia would (`net/auth.zig`).
    pub fn authorization(self: *Client, arena: Allocator, url: []const u8) GetError!?[]const u8 {
        const now = Io.Timestamp.now(self.io, .real);
        const decision = try auth.decide(arena, self.gpa, self.io, .{
            .depot = self.config.depot,
            .server = self.config.server,
            .url = url,
            .now_seconds = @as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_s,
        });
        return switch (decision) {
            .none => null,
            .send => |h| h,
            .refresh => |r| try self.refresh(arena, r),
        };
    }

    /// `get_auth_header`'s refresh branch (`PlatformEngines.jl:160-193`).
    fn refresh(self: *Client, arena: Allocator, r: auth.RefreshRequest) GetError!?[]const u8 {
        const res = self.getOnce(arena, r.url, .{
            // The refresh request authenticates with the REFRESH token, so
            // the normal lookup must not run (and would recurse).
            .authenticate = false,
            .extra_headers = &.{.{ .name = "Authorization", .value = r.authorization }},
        }) catch return null;
        // "token refresh failure" returns `nothing`, NOT the stale header --
        // a failed refresh means Ajt sends no credentials at all. See the
        // decision table in auth.zig.
        if (!res.ok()) return null;

        const applied = try auth.applyRefreshed(arena, self.gpa, res.body, blk: {
            const now = Io.Timestamp.now(self.io, .real);
            break :blk @as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_s;
        }) orelse return r.stale;

        // `mv(tmp, auth_file, force = true)` -- write beside the target so the
        // rename is same-filesystem and therefore atomic. A depot half-way
        // through losing its token is worse than not refreshing.
        const tmp_path = try std.fmt.allocPrint(arena, "{s}.ajt-tmp", .{r.auth_file});
        const cwd = Io.Dir.cwd();
        cwd.writeFile(self.io, .{
            .sub_path = tmp_path,
            .data = applied.file,
            // Julia writes the refreshed file through `tempname()` at the
            // default mode and leaves a TODO about "insecure auth file
            // permissions" (:114). Since this rename REPLACES the user's
            // auth.toml, inheriting that default would silently widen a file
            // they may well have chmodded to 0600. Diverging here only ever
            // removes access.
            .flags = .{ .permissions = owner_only },
        }) catch return r.stale;
        cwd.rename(tmp_path, cwd, r.auth_file, self.io) catch {
            cwd.deleteFile(self.io, tmp_path) catch {};
            return r.stale;
        };
        return applied.header;
    }
};

/// `0o600` where the platform has a mode at all. A bearer token is the one
/// thing Ajt writes that must not be world-readable.
const owner_only: Io.File.Permissions = switch (@import("builtin").os.tag) {
    .windows, .wasi => .default_file,
    else => @enumFromInt(0o600),
};

/// Same security origin in libcurl's sense: scheme, host and port all equal.
fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    const ah = a.host orelse return false;
    const bh = b.host orelse return false;
    if (!std.ascii.eqlIgnoreCase(ah.percent_encoded, bh.percent_encoded)) return false;
    return defaultPort(a) == defaultPort(b);
}

fn defaultPort(u: std.Uri) u16 {
    if (u.port) |p| return p;
    if (std.ascii.eqlIgnoreCase(u.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(u.scheme, "http")) return 80;
    return 0;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn testEnv(map: *std.process.Environ.Map, pairs: []const [2][]const u8) !void {
    for (pairs) |kv| try map.put(kv[0], kv[1]);
}

test "CI variable states match Julia's four-way classification" {
    try testing.expectEqual(@as(u8, 'n'), ciState(null));
    try testing.expectEqual(@as(u8, 't'), ciState("true"));
    try testing.expectEqual(@as(u8, 't'), ciState("TRUE"));
    try testing.expectEqual(@as(u8, 't'), ciState("1"));
    try testing.expectEqual(@as(u8, 't'), ciState("y"));
    try testing.expectEqual(@as(u8, 'f'), ciState("false"));
    try testing.expectEqual(@as(u8, 'f'), ciState("0"));
    try testing.expectEqual(@as(u8, 'f'), ciState("N"));
    try testing.expectEqual(@as(u8, 'o'), ciState("maybe"));
    // Set-but-empty is `o`: Julia's `get(ENV, var, nothing)` only
    // distinguishes presence.
    try testing.expectEqual(@as(u8, 'o'), ciState(""));
}

test "Julia-CI-Variables value matches Julia byte for byte" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    // Oracle, with nothing set:
    // `Pkg.PlatformEngines.get_metadata_headers("https://pkg.julialang.org/registries")`
    try testing.expectEqualStrings(
        "APPVEYOR=n;CI=n;CI_SERVER=n;CIRCLECI=n;CONTINUOUS_INTEGRATION=n;GITHUB_ACTIONS=n;" ++
            "GITLAB_CI=n;JULIA_CI=n;JULIA_PKGEVAL=n;JULIA_REGISTRYCI_AUTOMERGE=n;TF_BUILD=n;TRAVIS=n",
        try ciVariablesValue(arena, &env),
    );

    try testEnv(&env, &.{ .{ "CI", "true" }, .{ "TRAVIS", "0" }, .{ "GITHUB_ACTIONS", "sometimes" } });
    try testing.expectEqualStrings(
        "APPVEYOR=n;CI=t;CI_SERVER=n;CIRCLECI=n;CONTINUOUS_INTEGRATION=n;GITHUB_ACTIONS=o;" ++
            "GITLAB_CI=n;JULIA_CI=n;JULIA_PKGEVAL=n;JULIA_REGISTRYCI_AUTOMERGE=n;TF_BUILD=n;TRAVIS=f",
        try ciVariablesValue(arena, &env),
    );
}

test "metadata headers are sent only to the Pkg server" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg: Config = .{
        .server = "https://pkg.julialang.org",
        .depot = "/depot",
        .julia_version = "1.12.6",
        .julia_system = "x86_64-linux-gnu-libgfortran5-cxx11-libstdcxx30-julia_version+1.12.6",
        .ci_variables = "CI=n",
    };

    const on_server = try metadataHeaders(arena, cfg, "https://pkg.julialang.org/registries");
    try testing.expectEqual(@as(usize, 6), on_server.len);
    try testing.expectEqualStrings("Julia-Pkg-Protocol", on_server[0].name);
    try testing.expectEqualStrings("1.0", on_server[0].value);
    try testing.expectEqualStrings("Julia-Pkg-Server", on_server[1].name);
    try testing.expectEqualStrings("Julia-Version", on_server[2].name);
    try testing.expectEqualStrings("1.12.6", on_server[2].value);
    try testing.expectEqualStrings("Julia-System", on_server[3].name);
    try testing.expectEqualStrings("Julia-CI-Variables", on_server[4].name);
    try testing.expectEqualStrings("Julia-Interactive", on_server[5].name);
    try testing.expectEqualStrings("false", on_server[5].value);

    // Somewhere else entirely: no protocol headers, no version fingerprint.
    try testing.expectEqual(@as(usize, 0), (try metadataHeaders(arena, cfg, "https://github.com/x")).len);
    // A lookalike host must not collect them either.
    try testing.expectEqual(
        @as(usize, 0),
        (try metadataHeaders(arena, cfg, "https://pkg.julialang.org.evil.test/registries")).len,
    );

    // Server disabled via JULIA_PKG_SERVER="".
    var off = cfg;
    off.server = null;
    try testing.expectEqual(@as(usize, 0), (try metadataHeaders(arena, off, "https://pkg.julialang.org/registries")).len);
}

test "JULIA_PKG_SERVER_* becomes a titlecased Julia-* header" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testEnv(&env, &.{
        // Oracle: `titlecase("REGISTRY") == "Registry"` (strict by default).
        .{ "JULIA_PKG_SERVER_REGISTRY_PREFERENCE", "eager" },
        .{ "JULIA_PKG_SERVER_FOO", "  bar  " },
        .{ "JULIA_PKG_SERVER_EMPTY", "   " },
        .{ "JULIA_PKG_SERVER_", "x" },
        .{ "JULIA_PKG_SERVERX", "x" },
        .{ "UNRELATED", "x" },
    });

    const hs = try serverEnvHeaders(arena, &env);
    try testing.expectEqual(@as(usize, 2), hs.len);
    try testing.expectEqualStrings("Julia-Foo", hs[0].name);
    try testing.expectEqualStrings("bar", hs[0].value); // `strip(val)`
    try testing.expectEqualStrings("Julia-Registry-Preference", hs[1].name);
    try testing.expectEqualStrings("eager", hs[1].value);

    // They ride along with the metadata headers, but never displace one.
    const cfg: Config = .{
        .server = "https://pkg.julialang.org",
        .depot = "/depot",
        .server_env_headers = hs,
    };
    const all = try metadataHeaders(arena, cfg, "https://pkg.julialang.org/registries");
    try testing.expectEqual(@as(usize, 8), all.len);
    try testing.expectEqualStrings("Julia-Foo", all[6].name);

    // `any(hdr == k for (k, v) in headers) && continue`: a collision with a
    // protocol header loses.
    var clash = cfg;
    clash.server_env_headers = &.{.{ .name = "Julia-Version", .value = "999" }};
    clash.julia_version = "1.12.6";
    const dedup = try metadataHeaders(arena, clash, "https://pkg.julialang.org/registries");
    try testing.expectEqual(@as(usize, 6), dedup.len);
    try testing.expectEqualStrings("1.12.6", dedup[2].value);
}

test "concurrency mirrors num_concurrent_downloads" {
    try testing.expectEqual(default_concurrency, try concurrency(null));
    try testing.expectEqual(@as(u32, 16), try concurrency("16"));
    try testing.expectError(error.InvalidConcurrency, concurrency("0"));
    try testing.expectError(error.InvalidConcurrency, concurrency("-1"));
    try testing.expectError(error.InvalidConcurrency, concurrency("lots"));
}

test "same-origin test drops the token on any scheme, host or port change" {
    const base = try std.Uri.parse("https://pkg.julialang.org/registries");
    try testing.expect(sameOrigin(base, try std.Uri.parse("https://pkg.julialang.org/other")));
    // Default port spelled out explicitly is still the same origin.
    try testing.expect(sameOrigin(base, try std.Uri.parse("https://pkg.julialang.org:443/x")));
    // The real /registries redirect: a regional mirror is a DIFFERENT origin,
    // even though std.http.Client would call it the same parent domain.
    try testing.expect(!sameOrigin(base, try std.Uri.parse("https://in.pkg.julialang.org/registries")));
    try testing.expect(!sameOrigin(base, try std.Uri.parse("http://pkg.julialang.org/registries")));
    try testing.expect(!sameOrigin(base, try std.Uri.parse("https://pkg.julialang.org:8443/x")));
}

test "Config.fromEnv follows depots1 and the disable switch" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testEnv(&env, &.{.{ "HOME", "/home/u" }});
    var cfg = try Config.fromEnv(arena, &env, .{});
    try testing.expectEqualStrings(auth.default_server, cfg.server.?);
    try testing.expectEqualStrings("/home/u/.julia", cfg.depot.?);
    try testing.expectEqual(default_concurrency, cfg.concurrency);

    // A stacked depot path writes to -- and authenticates from -- its first
    // entry only.
    try testEnv(&env, &.{
        .{ "JULIA_DEPOT_PATH", "/a:/b:/c" },
        .{ "JULIA_PKG_CONCURRENT_DOWNLOADS", "3" },
    });
    cfg = try Config.fromEnv(arena, &env, .{});
    try testing.expectEqualStrings("/a", cfg.depot.?);
    try testing.expectEqual(@as(u32, 3), cfg.concurrency);

    try testEnv(&env, &.{.{ "JULIA_PKG_SERVER", "" }});
    cfg = try Config.fromEnv(arena, &env, .{});
    try testing.expect(cfg.server == null);
}

// ---------------------------------------------------------------------------
// Loopback tests.
//
// The redirect and retry loops are the one part of this module with no Julia
// oracle to diff against -- Pkg delegates both to libcurl. So they get a real
// server on 127.0.0.1 instead: scripted raw responses, one request per
// connection, and a log of what each hop actually received. That log is the
// only way to observe the assertion that matters most here -- that the token
// was NOT sent on hop two.
// ---------------------------------------------------------------------------

const LoopbackServer = struct {
    server: Io.net.Server,
    port: u16,
    log: Log = .{},

    const max_requests = 8;

    const Log = struct {
        count: usize = 0,
        targets: [max_requests][128]u8 = undefined,
        target_len: [max_requests]usize = @splat(0),
        auths: [max_requests][128]u8 = undefined,
        auth_len: [max_requests]usize = @splat(0),
        had_protocol: [max_requests]bool = @splat(false),

        fn target(l: *const Log, i: usize) []const u8 {
            return l.targets[i][0..l.target_len[i]];
        }
        /// The `Authorization` value, or "" when the hop carried none. Storing
        /// the value rather than a flag is what lets the refresh test prove
        /// the SECOND request used the NEW token.
        fn authorization(l: *const Log, i: usize) []const u8 {
            return l.auths[i][0..l.auth_len[i]];
        }
        fn hadAuth(l: *const Log, i: usize) bool {
            return l.auth_len[i] != 0;
        }
    };

    const port_base = 39871;
    const port_span = 1000;
    /// Handed out round-robin so two servers alive in the same process never
    /// land on the same port.
    ///
    /// Note what this does NOT protect against, because it used to be relied
    /// on for it: `next_offset` is a per-PROCESS static, so every concurrent
    /// `zig build test` starts from the same place. That was harmless only as
    /// long as a colliding `listen` failed. See below.
    var next_offset: std.atomic.Value(u16) = .init(0);

    /// `Io.net` exposes no way to read an ephemeral port back off a listening
    /// socket, so a fixed range is scanned rather than binding port 0.
    fn start(io: Io) !LoopbackServer {
        const first = next_offset.fetchAdd(1, .monotonic);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            // **An EXCLUSIVE bind. Do not pass `reuse_address` here.**
            //
            // Zig's `.reuse_address = true` sets SO_REUSEPORT as well as
            // SO_REUSEADDR (`std/Io/Threaded.zig:11686-11689`), and under
            // SO_REUSEPORT a second `listen` on a live port SUCCEEDS. The
            // `catch continue` below then never fires, every process piles
            // onto the same port, and the kernel load-balances incoming
            // connections across all of them -- so one test's client is served
            // by another test's server. Measured while twelve worktrees ran
            // their suites at once: 21 processes listening on 127.0.0.1:40872,
            // and the runs hung.
            //
            // Exclusive binding restores the property the scan was written for:
            // a taken port -- whether live or in TIME_WAIT -- fails, and the
            // loop moves on. The cost is that a port this suite used is
            // unusable for 60 s, but a run takes ~37 ports out of `port_span`,
            // so exhaustion needs a dozen back-to-back runs inside a minute and
            // fails LOUDLY as `NoFreePort` rather than hanging.
            const srv = addr.listen(io, .{}) catch continue;
            return .{ .server = srv, .port = port };
        }
        return error.NoFreePort;
    }

    fn deinit(self: *LoopbackServer, io: Io) void {
        self.server.deinit(io);
    }

    fn url(self: *const LoopbackServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    /// Serves exactly `script.len` requests, one per connection, then returns.
    ///
    /// Every scripted response must say `Connection: close`: otherwise the
    /// client keeps the connection pooled and this loop blocks in `accept`
    /// while the client blocks waiting for a body, which is a deadlock rather
    /// than a test failure. For the same reason each test must issue exactly
    /// as many requests as it scripts.
    fn serve(io: Io, self: *LoopbackServer, script: []const []const u8) void {
        for (script) |response| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            const r = &sr.interface;

            const i = self.log.count;
            if (i >= max_requests) return;
            self.log.count += 1;

            const request_line = r.takeDelimiterInclusive('\n') catch return;
            // `GET <target> HTTP/1.1`. The slice is invalidated by the next
            // take, so copy the target out now.
            if (std.mem.indexOfScalar(u8, request_line, ' ')) |sp| {
                const rest = request_line[sp + 1 ..];
                const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                const t = rest[0..@min(end, self.log.targets[i].len)];
                @memcpy(self.log.targets[i][0..t.len], t);
                self.log.target_len[i] = t.len;
            }
            while (true) {
                const line = r.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break; // the blank line ending the head
                if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
                    const v = std.mem.trim(u8, line["authorization:".len..], " \t\r\n");
                    const n = @min(v.len, self.log.auths[i].len);
                    @memcpy(self.log.auths[i][0..n], v[0..n]);
                    self.log.auth_len[i] = n;
                }
                if (std.ascii.startsWithIgnoreCase(line, "julia-pkg-protocol:")) self.log.had_protocol[i] = true;
            }

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            sw.interface.writeAll(response) catch {};
            sw.interface.flush() catch {};
        }
    }
};

fn redirectTo(comptime location: []const u8) []const u8 {
    return "HTTP/1.1 302 Found\r\nLocation: " ++ location ++
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
}

fn okBody(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
}

const server_error = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Writes `<depot>/servers/<host>/auth.toml` for a loopback server, returning
/// the path it wrote.
fn seedAuthFile(
    arena: Allocator,
    io: Io,
    depot: []const u8,
    server: []const u8,
    contents: []const u8,
) ![]const u8 {
    const dir = (try auth.serverDir(arena, .{ .depot = depot, .server = server, .url = server })).?;
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(arena, &.{ dir, "auth.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    return path;
}

test "redirects are followed and the protocol headers ride along" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);

    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/registries");
    const cfg: Config = .{
        .server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port}),
        .depot = "/nonexistent-depot",
        .julia_version = "1.12.6",
        .ci_variables = "CI=n",
    };

    const script = [_][]const u8{
        redirectTo("/hop1"),
        // A RELATIVE Location must resolve against the current URL. Spelling
        // it `/hop2` would hide an absolute-only bug.
        redirectTo("hop2"),
        okBody("/registry/uuid/hash\n"),
    };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, cfg);
    defer client.deinit();
    const res = try client.get(arena, start_url, .{});
    task.await(io);

    try testing.expectEqual(http.Status.ok, res.status);
    try testing.expectEqualStrings("/registry/uuid/hash\n", res.body);
    try testing.expectEqual(@as(u16, 2), res.redirects);

    try testing.expectEqual(@as(usize, 3), srv.log.count);
    try testing.expectEqualStrings("/registries", srv.log.target(0));
    try testing.expectEqualStrings("/hop1", srv.log.target(1));
    try testing.expectEqualStrings("/hop2", srv.log.target(2));
    // curl resends `CURLOPT_HTTPHEADER` on every hop, so the Julia-* headers
    // have to survive a redirect.
    for (0..3) |i| try testing.expect(srv.log.had_protocol[i]);
    // The reported URL is the one that actually answered.
    try testing.expect(std.mem.endsWith(u8, res.url, "/hop2"));
}

test "max_redirects is enforced" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/a");

    const script = [_][]const u8{ redirectTo("/b"), redirectTo("/c") };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{});
    defer client.deinit();
    const err = client.get(arena, start_url, .{ .max_redirects = 1 });
    task.await(io);
    try testing.expectError(error.TooManyHttpRedirects, err);
    try testing.expectEqual(@as(usize, 2), srv.log.count);
}

test "retry re-issues the request and stops at the first success" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/registries");

    const script = [_][]const u8{
        server_error,
        server_error,
        okBody("third time\n"),
        // Only reached by the extra request below: a success has to end the
        // retry loop, so the fourth attempt must never happen on its own.
        okBody("fourth\n"),
    };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{});
    defer client.deinit();
    const res = try client.get(arena, start_url, .{
        .retry = .{ .attempts = 4, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    });
    try testing.expectEqual(http.Status.ok, res.status);
    try testing.expectEqualStrings("third time\n", res.body);
    try testing.expectEqual(@as(usize, 3), srv.log.count);

    // Drain the unused scripted response so the server task can finish.
    const extra = try client.get(arena, start_url, .{});
    task.await(io);
    try testing.expectEqualStrings("fourth\n", extra.body);
}

test "retry gives up and hands back the last failing status" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/x");

    const script = [_][]const u8{ server_error, server_error };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{});
    defer client.deinit();
    // A non-2xx comes back as a Response, not an error: a 404 for a package
    // version is information the resolver needs, not a transport failure.
    const res = try client.get(arena, start_url, .{
        .retry = .{ .attempts = 2, .delay = .{ .nanoseconds = std.time.ns_per_ms } },
    });
    task.await(io);
    try testing.expectEqual(http.Status.service_unavailable, res.status);
    try testing.expect(!res.ok());
    try testing.expectEqual(@as(usize, 2), srv.log.count);
}

test "a sink streams the body instead of buffering it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/tarball");

    const script = [_][]const u8{okBody("payload bytes")};
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var client: Client = .init(testing.allocator, io, .{});
    defer client.deinit();
    // This is the path a registry install needs: a tarball goes straight to disk
    // without ever existing as one contiguous allocation.
    const res = try client.get(arena, start_url, .{ .sink = &out.writer });
    task.await(io);
    try testing.expectEqualStrings("payload bytes", out.written());
    try testing.expectEqualStrings("", res.body);
    try testing.expectEqual(http.Status.ok, res.status);
}

test "max_body_bytes rejects an oversized body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/big");

    const script = [_][]const u8{ okBody("0123456789"), okBody("0123456789") };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{});
    defer client.deinit();
    try testing.expectError(
        error.ResponseTooLarge,
        client.get(arena, start_url, .{ .max_body_bytes = 4 }),
    );
    // The same body under the cap is fine, so this is the cap firing and not
    // the request failing for some other reason.
    const ok_res = try client.get(arena, start_url, .{ .max_body_bytes = 10 });
    task.await(io);
    try testing.expectEqualStrings("0123456789", ok_res.body);
}

test "the bearer token reaches the server and is dropped on a cross-origin redirect" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var origin = try LoopbackServer.start(io);
    defer origin.deinit(io);
    var elsewhere = try LoopbackServer.start(io);
    defer elsewhere.deinit(io);

    // `is_secure_url` counts 127.0.0.1 as secure (PlatformEngines.jl:43), which
    // is what lets a plain http:// loopback stand in for a real Pkg server.
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{origin.port});
    _ = try seedAuthFile(arena, io, depot, server, "access_token = \"s3cret\"\n");

    var url_buf: [64]u8 = undefined;
    const start_url = origin.url(&url_buf, "/registries");
    var away_buf: [64]u8 = undefined;
    const away_url = elsewhere.url(&away_buf, "/moved");

    // A different PORT is a different origin, so no DNS is involved -- this
    // stays deterministic on hosts where `localhost` resolves to ::1.
    const moved = try std.fmt.allocPrint(
        arena,
        "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{away_url},
    );
    const origin_script = try arena.dupe([]const u8, &.{moved});
    const away_script = [_][]const u8{okBody("landed\n")};

    var origin_task = try io.concurrent(LoopbackServer.serve, .{ io, &origin, origin_script });
    var away_task = try io.concurrent(LoopbackServer.serve, .{ io, &elsewhere, away_script[0..] });

    var client: Client = .init(testing.allocator, io, .{
        .server = server,
        .depot = depot,
        .julia_version = "1.12.6",
        .ci_variables = "CI=n",
    });
    defer client.deinit();
    const res = try client.get(arena, start_url, .{});
    origin_task.await(io);
    away_task.await(io);

    try testing.expectEqualStrings("landed\n", res.body);
    // Hop 1 is the Pkg server: token and protocol headers both go.
    try testing.expectEqualStrings("Bearer s3cret", origin.log.authorization(0));
    try testing.expect(origin.log.had_protocol[0]);
    // Hop 2 is a different origin: libcurl drops the Authorization header
    // there, and so do we. std.http.Client's own redirect handling would have
    // kept it whenever the parent domain matched.
    try testing.expect(!elsewhere.log.hadAuth(0));
}

test "an expiring token is refreshed before use and written back" {
    // Asserts the 0o600 the token file is written with, which is a POSIX mode.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    var refresh_buf: [64]u8 = undefined;
    const refresh_url = srv.url(&refresh_buf, "/auth/refresh");
    const auth_file = try seedAuthFile(arena, io, depot, server, try std.fmt.allocPrint(arena,
        \\access_token = "old"
        \\expires_at = 1
        \\refresh_url = "{s}"
        \\refresh_token = "rt"
        \\
    , .{refresh_url}));

    // Hop 1 is the refresh; hop 2 is the real request, which must carry the
    // NEW token. `expires_in` makes the write-back rewrite `expires_at`.
    const script = [_][]const u8{
        okBody("access_token = \"fresh\"\nexpires_in = 3600\n"),
        okBody("registries\n"),
    };
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/registries");
    var client: Client = .init(testing.allocator, io, .{ .server = server, .depot = depot });
    defer client.deinit();
    const res = try client.get(arena, start_url, .{});
    task.await(io);

    try testing.expectEqualStrings("registries\n", res.body);
    try testing.expectEqual(@as(usize, 2), srv.log.count);
    // The refresh authenticates with the REFRESH token, not the access token.
    try testing.expectEqualStrings("/auth/refresh", srv.log.target(0));
    try testing.expectEqualStrings("Bearer rt", srv.log.authorization(0));
    // ...and the request that prompted it then uses the refreshed one.
    try testing.expectEqualStrings("/registries", srv.log.target(1));
    try testing.expectEqualStrings("Bearer fresh", srv.log.authorization(1));

    // The file on disk is the re-serialised table, sorted, with `expires_at`
    // overwritten from the local clock (`PlatformEngines.jl:183-190`).
    const written = try Io.Dir.cwd().readFileAlloc(io, auth_file, arena, .limited(64 * 1024));
    try testing.expect(std.mem.startsWith(u8, written, "access_token = \"fresh\"\nexpires_at = "));
    try testing.expect(std.mem.endsWith(u8, written, "\nexpires_in = 3600\n"));
    // A bearer token must not be world-readable, whatever mode Julia leaves.
    const st = try Io.Dir.cwd().statFile(io, auth_file, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "a refresh that cannot be downloaded sends no credentials at all" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    // Port 1 is reserved and never listening, so the refresh GET fails at
    // connect. `is_secure_url` still accepts it -- it is 127.0.0.1.
    _ = try seedAuthFile(arena, io, depot, server,
        \\access_token = "old"
        \\expires_at = 1
        \\refresh_url = "http://127.0.0.1:1/refresh"
        \\refresh_token = "rt"
        \\
    );

    const script = [_][]const u8{okBody("body\n")};
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/registries");
    var client: Client = .init(testing.allocator, io, .{ .server = server, .depot = depot });
    defer client.deinit();
    _ = try client.get(arena, start_url, .{});
    task.await(io);

    // The stale token is NOT a fallback here: Julia returns `nothing` from the
    // "token-refresh-failed" branch without the `something(..., auth_header)`
    // wrapper its neighbours use (`PlatformEngines.jl:161-166`).
    try testing.expect(!srv.log.hadAuth(0));
}

test "authenticate = false keeps the token in the depot" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    const server = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    _ = try seedAuthFile(arena, io, depot, server, "access_token = \"s3cret\"\n");

    var url_buf: [64]u8 = undefined;
    const start_url = srv.url(&url_buf, "/registries");
    const script = [_][]const u8{okBody("ok\n")};
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{ .server = server, .depot = depot });
    defer client.deinit();
    _ = try client.get(arena, start_url, .{ .authenticate = false });
    task.await(io);
    try testing.expect(!srv.log.hadAuth(0));
}

test "offline refuses the request instead of making it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var srv = try LoopbackServer.start(io);
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const target = srv.url(&url_buf, "/registries");

    // ONE scripted response for TWO calls. The offline call must not consume
    // it, which is the whole assertion: an "offline" client that still opened
    // a connection would take this response and the server would then block in
    // `accept` forever rather than fail a comparison.
    const script = [_][]const u8{okBody("served\n")};
    var task = try io.concurrent(LoopbackServer.serve, .{ io, &srv, script[0..] });

    var client: Client = .init(testing.allocator, io, .{ .offline = true });
    defer client.deinit();
    try testing.expectError(error.Offline, client.get(arena, target, .{
        // A retry budget the guard has to short-circuit: four attempts a
        // second apart would make this test take four seconds.
        .retry = .pkg_server,
    }));
    try testing.expectError(error.Offline, client.put(arena, target, "body", .{}));
    try testing.expectEqual(@as(usize, 0), srv.log.count);

    // The landmark: the SAME request against the SAME address succeeds with
    // the flag cleared. Without this the test above would pass just as well if
    // the port were dead, which would make it a test of nothing.
    client.config.offline = false;
    const res = try client.get(arena, target, .{});
    task.await(io);
    try testing.expectEqualStrings("served\n", res.body);
    try testing.expectEqual(@as(usize, 1), srv.log.count);
}

test "JULIA_PKG_OFFLINE reaches Config, and an unparseable value is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(arena);
    defer env.deinit();

    try testing.expect(!(try Config.fromEnv(arena, &env, .{})).offline);

    // The Capitalized/UPPERCASE spellings are the ones a narrower reader
    // silently gets wrong, so they are what this asserts.
    for ([_][]const u8{ "1", "true", "t", "T", "TRUE", "Yes", "Y" }) |v| {
        try testEnv(&env, &.{.{ "JULIA_PKG_OFFLINE", v }});
        try testing.expect((try Config.fromEnv(arena, &env, .{})).offline);
    }
    for ([_][]const u8{ "0", "false", "NO", "n", "" }) |v| {
        try testEnv(&env, &.{.{ "JULIA_PKG_OFFLINE", v }});
        try testing.expect(!(try Config.fromEnv(arena, &env, .{})).offline);
    }
    // ...but a falsy variable must not switch OFF an explicit `--offline`,
    // which is why `fromEnv` ORs rather than filling an unset field.
    try testEnv(&env, &.{.{ "JULIA_PKG_OFFLINE", "false" }});
    try testing.expect((try Config.fromEnv(arena, &env, .{ .offline = true })).offline);

    try testEnv(&env, &.{.{ "JULIA_PKG_OFFLINE", "garbage" }});
    try testing.expectError(error.InvalidOfflineSetting, Config.fromEnv(arena, &env, .{}));
}
