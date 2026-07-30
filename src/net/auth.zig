//! Pkg-server identity and bearer-token authentication.
//!
//! Port of `Pkg/src/PlatformEngines.jl`'s `is_secure_url` (:43),
//! `get_server_dir` (:46-60) and `get_auth_header` (:107-193), plus
//! `Pkg.pkg_server` (`Pkg.jl:34-39`).
//!
//! Only the *decision* lives here. Performing a token refresh needs an HTTP
//! client, and `net/http.zig` owns that, so this module stops at
//! "here is what Julia would do next". The split is what makes the whole
//! decision table testable with no network and no wall clock: `decide` takes
//! `now_seconds`, so every expiry branch is reachable from a unit test.
//!
//! ## The decision table (verified against Julia 1.12.6, not reasoned about)
//!
//! `get_auth_header` funnels every failure through `handle_auth_error`, which
//! with no handlers registered returns `nothing`. Whether that `nothing` ends
//! up as "send no header" or "send the stale header anyway" depends on whether
//! the call site wraps it in `something(..., auth_header)` -- and the two are
//! interleaved, which is the trap:
//!
//! | situation                          | Julia line | result        |
//! |------------------------------------|------------|---------------|
//! | no `auth.toml`                     | :113       | no header     |
//! | insecure URL                       | :116-119   | no header     |
//! | unparseable `auth.toml`            | :121-127   | no header     |
//! | no `access_token`                  | :129-133   | no header     |
//! | token still good for >= 10 min     | :143-146   | send token    |
//! | expired, no refresh keys           | :147-153   | send token    |
//! | expired, insecure `refresh_url`    | :155-159   | send token    |
//! | expired, refresh download FAILED   | :161-166   | **no header** |
//! | expired, refreshed file unusable   | :167-182   | send old token|
//!
//! The eighth row is the asymmetry: a refresh that *fails to download* drops
//! the header entirely (`return handle_auth_error(...)`, no `something`),
//! while a refresh that downloads garbage falls back to the stale token. That
//! is not obviously intentional in Julia, but it is what Julia does, and
//! diverging would make Ajt send credentials in a case where Pkg does not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const toml_parse = @import("../toml/parse.zig");
const toml_value = @import("../toml/value.zig");

/// `Pkg.pkg_server()` (`Pkg.jl:34-39`).
///
/// Returns null when the server is DISABLED, which Julia spells as
/// `JULIA_PKG_SERVER=""` -- an empty value is not "use the default", it turns
/// the whole Pkg-server protocol off. A missing variable is the default.
///
/// Allocates into `arena` only when a scheme has to be prepended.
pub fn pkgServer(arena: Allocator, raw: ?[]const u8) Allocator.Error!?[]const u8 {
    const server = raw orelse default_server;
    if (server.len == 0) return null;
    // `startswith(server, r"\w+://")` -- note this is NOT case-folded, but
    // `\w` already covers upper case, so `HTTP://x` is left alone.
    const with_scheme = if (hasScheme(server))
        server
    else
        try std.fmt.allocPrint(arena, "https://{s}", .{server});
    // `rstrip(server, '/')` strips EVERY trailing slash, not just one.
    return std.mem.trimEnd(u8, with_scheme, "/");
}

pub const default_server = "https://pkg.julialang.org";

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn hasScheme(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and isWordChar(s[i])) i += 1;
    return i != 0 and std.mem.startsWith(u8, s[i..], "://");
}

/// `is_secure_url` (:43):
/// `^(https://|\w+://(127\.0\.0\.1|localhost)(:\d+)?($|/))`i
///
/// Two things surprise people here, both confirmed against Julia: ANY scheme
/// is accepted in front of localhost (`ftp://localhost/` is "secure"), and a
/// bare `http://localhost` with no trailing slash matches via the `$` branch.
pub fn isSecureUrl(url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return true;

    var i: usize = 0;
    while (i < url.len and isWordChar(url[i])) i += 1;
    if (i == 0) return false;
    if (!std.mem.startsWith(u8, url[i..], "://")) return false;
    var rest = url[i + 3 ..];

    if (std.ascii.startsWithIgnoreCase(rest, "127.0.0.1")) {
        rest = rest["127.0.0.1".len..];
    } else if (std.ascii.startsWithIgnoreCase(rest, "localhost")) {
        rest = rest["localhost".len..];
    } else return false;

    if (rest.len != 0 and rest[0] == ':') {
        var j: usize = 1;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        // `(:\d+)?` is optional, so a colon followed by no digits simply does
        // not consume the group; the `($|/)` check then fails on ':'.
        if (j > 1) rest = rest[j..];
    }
    return rest.len == 0 or rest[0] == '/';
}

/// The host component of a Pkg server URL: `^\w+://([^\\/]+)(?:$|/)` (:56).
///
/// Null means Julia's "malformed Pkg server value" warning path (:57), which
/// disables the server rather than guessing.
pub fn serverHost(server: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < server.len and isWordChar(server[i])) i += 1;
    if (i == 0) return null;
    if (!std.mem.startsWith(u8, server[i..], "://")) return null;
    const rest = server[i + 3 ..];

    var j: usize = 0;
    while (j < rest.len and rest[j] != '/' and rest[j] != '\\') j += 1;
    if (j == 0) return null; // `[^\\/]+` needs at least one character
    // `(?:$|/)`: a backslash right after the host makes the whole match fail.
    if (j != rest.len and rest[j] != '/') return null;
    return rest[0..j];
}

/// Every character Julia refuses in a depot directory name, replaced by `_`
/// (:58-59). The list literally contains `/` twice; the duplicate is
/// harmless and reproduced here only as a note that this is a faithful copy.
const invalid_filename_chars = ":/<>\"/\\|?*";

/// `<host>` sanitised into the `servers/<dir>` name (:58-59). Arena-allocated.
pub fn serverDirName(arena: Allocator, host: []const u8) Allocator.Error![]u8 {
    const out = try arena.alloc(u8, host.len);
    for (host, 0..) |c, idx| {
        out[idx] = if (std.mem.indexOfScalar(u8, invalid_filename_chars, c) != null) '_' else c;
    }
    return out;
}

pub const ServerDirOptions = struct {
    /// `depots1()` -- the depot that owns `servers/`. Null models Julia's
    /// `isempty(Base.DEPOT_PATH) && return` (:57), which disables the whole
    /// Pkg-server protocol including its metadata headers.
    depot: ?[]const u8,
    /// The normalised `pkg_server()` value. Null = server disabled.
    server: ?[]const u8,
    /// The URL about to be fetched.
    url: []const u8,
};

/// Whether `get_server_dir` would return a directory at all (:46-57), without
/// building the path. This is the gate on the whole Pkg-server protocol: the
/// metadata headers are attached exactly when this is true (:223-224).
///
/// The URL test is `url == server || startswith(url, "$server/")` -- a prefix
/// match alone would let `https://pkg.julialang.org.evil.test/x` collect the
/// token, so the separator is load-bearing.
pub fn targetsServer(opts: ServerDirOptions) bool {
    const server = opts.server orelse return false;
    if (opts.depot == null) return false;
    if (!std.mem.eql(u8, opts.url, server)) {
        if (!std.mem.startsWith(u8, opts.url, server)) return false;
        if (opts.url.len == server.len or opts.url[server.len] != '/') return false;
    }
    return serverHost(server) != null;
}

/// `get_server_dir` (:46-60): `<depot>/servers/<sanitised host>`, but only
/// when `url` actually targets the server. Arena-allocated.
pub fn serverDir(arena: Allocator, opts: ServerDirOptions) Allocator.Error!?[]const u8 {
    if (!targetsServer(opts)) return null;
    const dir = try serverDirName(arena, serverHost(opts.server.?).?);
    return try std.fs.path.join(arena, &.{ opts.depot.?, "servers", dir });
}

/// What `get_auth_header` decided to do. See the table at the top of the file.
pub const Decision = union(enum) {
    /// Send no `Authorization` header.
    none,
    /// Send this value verbatim: `Bearer <access_token>`.
    send: []const u8,
    /// The token is within ten minutes of expiry and a usable refresh URL is
    /// on file, so Julia refreshes BEFORE using it (:160-193).
    refresh: RefreshRequest,
};

pub const RefreshRequest = struct {
    /// `refresh_url`, already checked with `isSecureUrl`.
    url: []const u8,
    /// `Bearer <refresh_token>` -- what the refresh GET itself authenticates
    /// with. Note this is the REFRESH token, not the access token.
    authorization: []const u8,
    /// `Bearer <access_token>`: the stale value to fall back on when the
    /// refreshed file is unusable. NOT used when the download itself fails.
    stale: []const u8,
    /// Where the refreshed table is written back (:192).
    auth_file: []const u8,
};

pub const DecideOptions = struct {
    depot: ?[]const u8,
    server: ?[]const u8,
    url: []const u8,
    /// `time()` in seconds since the epoch. Passed in so expiry branches are
    /// reachable from tests without waiting.
    now_seconds: f64,
};

pub const Error = Allocator.Error || Io.Cancelable;

/// `get_auth_header` (:107-159) up to the point where I/O beyond reading
/// `auth.toml` would be needed.
///
/// Every returned slice is allocated in `arena` and shares the decision's
/// lifetime; pass a general-purpose allocator here and you leak. (The parsed
/// TOML document is freed before returning -- only the extracted fields are
/// copied out.)
pub fn decide(arena: Allocator, gpa: Allocator, io: Io, opts: DecideOptions) Error!Decision {
    const dir = try serverDir(arena, .{
        .depot = opts.depot,
        .server = opts.server,
        .url = opts.url,
    }) orelse return .none;
    const auth_file = try std.fs.path.join(arena, &.{ dir, "auth.toml" });

    // `isfile(auth_file) || return` (:113). Reading is the same syscall
    // budget as stat+read and gives the same answer for a directory
    // (error.IsDir) or a dangling symlink.
    const src = Io.Dir.cwd().readFileAlloc(io, auth_file, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return .none, // "no-auth-file"
    };
    defer gpa.free(src);

    // The secure-URL check happens AFTER the file exists (:116), so a plain
    // http:// URL with an auth file on disk is a hard no-header, not a
    // fall-through.
    if (!isSecureUrl(opts.url)) return .none; // "insecure-connection"

    var doc = toml_parse.parse(gpa, src, null) catch return .none; // "malformed-file"
    defer doc.deinit();

    const access_token = stringField(doc.root, "access_token") orelse return .none; // "no-access-token"
    const header = try std.fmt.allocPrint(arena, "Bearer {s}", .{access_token});

    // `expires_at = Inf`, then `min` with each source that is present
    // (:135-141). Absent everywhere means "never expires".
    var expires_at: f64 = std.math.inf(f64);
    if (numberField(doc.root, "expires_at")) |v| expires_at = @min(expires_at, v);
    if (numberField(doc.root, "expires_in")) |v| {
        // `mtime(auth_file) + expires_in` -- relative to when the file was
        // last written, not to when it was issued.
        //
        // The file was readable a moment ago, so a failing stat here means it
        // was removed underneath us. Julia's `mtime` answers 0.0 rather than
        // throwing, which makes the token look long expired; with no refresh
        // keys that still ends at "send it anyway", so short-circuiting to
        // `send` matches the reachable outcome without inventing a timestamp.
        const st = Io.Dir.cwd().statFile(io, auth_file, .{}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return .{ .send = header },
        };
        const mtime: f64 = @as(f64, @floatFromInt(st.mtime.nanoseconds)) / std.time.ns_per_s;
        expires_at = @min(expires_at, mtime + v);
    }

    // "if token is good until ten minutes from now, use it" (:142-146).
    if (expires_at >= opts.now_seconds + 10 * 60) return .{ .send = header };

    const refresh_url = stringField(doc.root, "refresh_url") orelse return .{ .send = header };
    const refresh_token = stringField(doc.root, "refresh_token") orelse return .{ .send = header };
    if (!isSecureUrl(refresh_url)) return .{ .send = header }; // "insecure-refresh-url"

    return .{ .refresh = .{
        .url = try arena.dupe(u8, refresh_url),
        .authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{refresh_token}),
        .stale = header,
        .auth_file = auth_file,
    } };
}

/// The outcome of consuming a refreshed `auth.toml` body (:167-193).
pub const Refreshed = struct {
    /// `Bearer <new access_token>`.
    header: []const u8,
    /// Exactly the bytes to write back over `auth.toml`. Julia re-serialises
    /// the parsed table with `TOML.print(io, auth_info, sorted = true)`
    /// (:188-190), so the file is normalised, not copied.
    file: []const u8,
};

/// Applies a downloaded refresh response. Returns null for every case where
/// Julia falls back to the stale token (:174-182).
///
/// Arena-allocated. Separated from the download so the whole rewrite -- the
/// `expires_at` overwrite included -- is unit-testable offline.
pub fn applyRefreshed(
    arena: Allocator,
    gpa: Allocator,
    body: []const u8,
    now_seconds: f64,
) Allocator.Error!?Refreshed {
    var doc = toml_parse.parse(gpa, body, null) catch return null; // "malformed-file"
    defer doc.deinit();

    const access_token = stringField(doc.root, "access_token") orelse return null; // "no-access-token"

    // "overwrite expires_at (avoids clock skew issues)" (:183-187). `floor`
    // on a Float64 stays a Float64, so this lands in the file as `1.234e9`,
    // not as an integer -- which our emitter reproduces byte for byte.
    if (numberField(doc.root, "expires_in")) |expires_in| {
        try doc.root.put(doc.allocator(), "expires_at", .{ .float = @floor(now_seconds + expires_in) });
    }

    const emit = @import("../toml/emit.zig");
    // `emitAlloc` writes into an `Allocating` writer, whose only failure mode
    // is allocation; `WriteFailed` is unreachable but is in the declared set.
    const rendered = emit.emitAlloc(gpa, doc.root, .{ .sorted = true }) catch return error.OutOfMemory;
    defer gpa.free(rendered);

    return .{
        .header = try std.fmt.allocPrint(arena, "Bearer {s}", .{access_token}),
        .file = try arena.dupe(u8, rendered),
    };
}

fn stringField(t: *const toml_value.Table, key: []const u8) ?[]const u8 {
    return switch (t.get(key) orelse return null) {
        .string => |s| s,
        // Julia asserts `::String` here and would throw. Ajt treats a
        // wrong-typed token as absent: refusing to send credentials is the
        // safe side of that divergence.
        else => null,
    };
}

fn numberField(t: *const toml_value.Table, key: []const u8) ?f64 {
    return switch (t.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0, // Float64(true) == 1.0
        else => null,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "pkg_server normalisation matches Julia" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Oracle: `ENV["JULIA_PKG_SERVER"] = v; Pkg.pkg_server()`.
    try testing.expectEqualStrings(default_server, (try pkgServer(arena, null)).?);
    try testing.expect((try pkgServer(arena, "")) == null);
    try testing.expectEqualStrings("https://pkg.julialang.org", (try pkgServer(arena, "pkg.julialang.org")).?);
    try testing.expectEqualStrings("https://x.org", (try pkgServer(arena, "https://x.org/")).?);
    try testing.expectEqualStrings("https://x.org", (try pkgServer(arena, "https://x.org///")).?);
    // Already-schemed values are left alone, upper case included.
    try testing.expectEqualStrings("HTTP://X.org", (try pkgServer(arena, "HTTP://X.org")).?);
}

test "is_secure_url matches Julia" {
    // Oracle: `Pkg.PlatformEngines.is_secure_url(u)`.
    try testing.expect(isSecureUrl("https://a"));
    try testing.expect(!isSecureUrl("http://a"));
    try testing.expect(isSecureUrl("http://localhost/x"));
    try testing.expect(isSecureUrl("http://localhost"));
    try testing.expect(isSecureUrl("http://127.0.0.1:8000/"));
    // Any scheme in front of localhost passes -- the regex only requires \w+.
    try testing.expect(isSecureUrl("ftp://localhost/"));
    try testing.expect(isSecureUrl("HTTPS://A"));
    try testing.expect(isSecureUrl("http://localhost:80"));
    // Not localhost, not https.
    try testing.expect(!isSecureUrl("http://localhost.evil.test/"));
    try testing.expect(!isSecureUrl("http://127.0.0.2/"));
    try testing.expect(!isSecureUrl("localhost"));
}

test "server dir name sanitisation matches Julia" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Oracle: `basename(Pkg.PlatformEngines.get_server_dir(s, s))`.
    try testing.expectEqualStrings("pkg.julialang.org", serverHost("https://pkg.julialang.org").?);
    try testing.expectEqualStrings("my_host", try serverDirName(arena, serverHost("https://my:host/x").?));
    try testing.expectEqualStrings("localhost_8000", try serverDirName(arena, serverHost("http://localhost:8000").?));
    try testing.expectEqualStrings("a_b_c_d_e_f_g", try serverDirName(arena, serverHost("https://a<b>c\"d|e?f*g").?));
    // Malformed: a backslash right after the authority fails `(?:$|/)`.
    try testing.expect(serverHost("https://a\\b") == null);
    try testing.expect(serverHost("nonsense") == null);
    try testing.expect(serverHost("https://") == null);
}

test "serverDir only fires for URLs actually under the server" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server = "https://pkg.julialang.org";
    const base: ServerDirOptions = .{ .depot = "/d", .server = server, .url = server };

    try testing.expectEqualStrings("/d/servers/pkg.julialang.org", (try serverDir(arena, base)).?);
    var o = base;
    o.url = server ++ "/registries";
    try testing.expectEqualStrings("/d/servers/pkg.julialang.org", (try serverDir(arena, o)).?);
    // The `/` separator is what stops a lookalike host from collecting the
    // token via a bare prefix match.
    o.url = server ++ ".evil.test/registries";
    try testing.expect((try serverDir(arena, o)) == null);
    o.url = "https://example.test/x";
    try testing.expect((try serverDir(arena, o)) == null);
    // Server disabled, or no depot -> no server dir, hence no headers at all.
    o = base;
    o.server = null;
    try testing.expect((try serverDir(arena, o)) == null);
    o = base;
    o.depot = null;
    try testing.expect((try serverDir(arena, o)) == null);
}

/// Builds `<tmp>/servers/pkg.julialang.org/auth.toml` and runs `decide`.
fn probeAuth(arena: Allocator, dir: Io.Dir, depot: []const u8, content: ?[]const u8, now: f64) !Decision {
    const sub = "servers/pkg.julialang.org";
    try dir.createDirPath(testing.io, sub);
    const path = try std.fs.path.join(arena, &.{ sub, "auth.toml" });
    if (content) |c| {
        try dir.writeFile(testing.io, .{ .sub_path = path, .data = c });
    } else {
        dir.deleteFile(testing.io, path) catch {};
    }
    return decide(arena, testing.allocator, testing.io, .{
        .depot = depot,
        .server = default_server,
        .url = default_server ++ "/registries",
        .now_seconds = now,
    });
}

test "get_auth_header decision table matches Julia" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const depot = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const now: f64 = 1_785_000_000;

    // Every expectation below is what Julia 1.12.6 printed for the same
    // auth.toml under JULIA_DEPOT_PATH, not what the source reads like.
    try testing.expect(try probeAuth(arena, tmp.dir, depot, null, now) == .none);
    try testing.expect(try probeAuth(arena, tmp.dir, depot, "expires_at = 99999999999\n", now) == .none);
    try testing.expect(try probeAuth(arena, tmp.dir, depot, "this is not toml =\n", now) == .none);

    const plain = try probeAuth(arena, tmp.dir, depot, "access_token = \"tok1\"\n", now);
    try testing.expectEqualStrings("Bearer tok1", plain.send);

    // Expired with no refresh keys: Julia sends it anyway.
    const expired = try probeAuth(arena, tmp.dir, depot, "access_token = \"tok2\"\nexpires_at = 1\n", now);
    try testing.expectEqualStrings("Bearer tok2", expired.send);

    // Inside the ten-minute window counts as expiring.
    const soon = try probeAuth(arena, tmp.dir, depot,
        \\access_token = "tok3"
        \\expires_at = 1785000060
        \\
    , now);
    try testing.expectEqualStrings("Bearer tok3", soon.send);

    // An insecure refresh URL is ignored, not followed.
    const insecure = try probeAuth(arena, tmp.dir, depot,
        \\access_token = "tok7"
        \\expires_at = 1
        \\refresh_url = "http://evil.example"
        \\refresh_token = "r"
        \\
    , now);
    try testing.expectEqualStrings("Bearer tok7", insecure.send);

    // A secure refresh URL on an expired token is the one case that triggers
    // a network round trip before the token may be used.
    const refresh = try probeAuth(arena, tmp.dir, depot,
        \\access_token = "tok8"
        \\expires_at = 1
        \\refresh_url = "https://auth.example/refresh"
        \\refresh_token = "rt"
        \\
    , now);
    try testing.expectEqualStrings("https://auth.example/refresh", refresh.refresh.url);
    try testing.expectEqualStrings("Bearer rt", refresh.refresh.authorization);
    try testing.expectEqualStrings("Bearer tok8", refresh.refresh.stale);
}

test "expires_in is measured from the auth file's mtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const depot = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const st = Io.Timestamp.now(testing.io, .real);
    const now: f64 = @as(f64, @floatFromInt(st.nanoseconds)) / std.time.ns_per_s;

    // Written just now, so mtime+3600 is comfortably past the ten-minute
    // window: usable without a refresh.
    const fresh = try probeAuth(arena, tmp.dir, depot, "access_token = \"tok5\"\nexpires_in = 3600\n", now);
    try testing.expectEqualStrings("Bearer tok5", fresh.send);

    // mtime+1 is already in the past. With no refresh keys Julia still sends
    // it, so `send` (not `none`) is the correct answer here.
    const stale = try probeAuth(arena, tmp.dir, depot, "access_token = \"tok6\"\nexpires_in = 1\n", now);
    try testing.expectEqualStrings("Bearer tok6", stale.send);
}

test "applyRefreshed rewrites expires_at and normalises the file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now: f64 = 1_785_084_792;
    const got = (try applyRefreshed(arena, testing.allocator,
        \\refresh_token = "rt"
        \\access_token = "new"
        \\expires_in = 3600
        \\
    , now)).?;
    try testing.expectEqualStrings("Bearer new", got.header);
    // Oracle: `TOML.print(stdout, d, sorted=true)` with
    // `expires_at = floor(1785084792.0 + 3600)` -- Float64, hence `1.785088392e9`.
    try testing.expectEqualStrings(
        \\access_token = "new"
        \\expires_at = 1.785088392e9
        \\expires_in = 3600
        \\refresh_token = "rt"
        \\
    , got.file);

    // No expires_in: the table is written back untouched apart from sorting.
    const no_exp = (try applyRefreshed(arena, testing.allocator, "access_token = \"n2\"\n", now)).?;
    try testing.expectEqualStrings("access_token = \"n2\"\n", no_exp.file);

    // Unusable refreshes fall back to the stale token, which the caller
    // signals by getting null back.
    try testing.expect((try applyRefreshed(arena, testing.allocator, "not toml =", now)) == null);
    try testing.expect((try applyRefreshed(arena, testing.allocator, "refresh_token = \"x\"\n", now)) == null);
}
