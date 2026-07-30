//! HTTPS for libgit2, supplied by Zig.
//!
//! ## The idea
//!
//! libgit2 is built here with `GIT_HTTPS` unset and no TLS backend at all — no
//! OpenSSL, no mbedTLS, no Schannel, no Secure Transport (`build.zig`). That
//! sounds like it should mean "no `https://`". It does not, and the reason is
//! three specific lines of upstream:
//!
//!  * `streams/tls.c:28` — `git_tls_stream_new` consults
//!    `git_stream_registry_lookup(GIT_STREAM_TLS)` **first**, and only falls
//!    through to its `#ifdef` ladder when the registry says `GIT_ENOTFOUND`.
//!    There is no `GIT_HTTPS` conditional anywhere in that file.
//!  * `transport.c:31-44` — the `https://` row of the transport table is
//!    unconditional. Only the three `ssh` rows are `#ifdef GIT_SSH`.
//!  * `transports/httpclient.c` — contains no `GIT_HTTPS` at all, and picks
//!    the stream by comparing the URL scheme at runtime (`:956-963`).
//!
//! So registering a stream is not a workaround around a missing feature; it is
//! the extension point libgit2 documents, and the `#ifdef` backends are merely
//! its default implementations.
//!
//! ## What that buys, and what it costs
//!
//! libgit2 keeps: HTTP/1.1 framing, chunked transfer, redirects,
//! `WWW-Authenticate` and the auth ladder, keep-alive, smart-protocol v0 **and**
//! v2 negotiation, ref advertisement, want/have, packfile receive, delta
//! resolution, pack index construction, and the ODB. This file supplies six
//! callbacks over a byte pipe. That ratio is the whole argument for the design.
//!
//! The cost is that `git_stream_registration` has **no user-data pointer**
//! (`include/git2/sys/stream.h:65-94`): `init` receives a host and a port and
//! nothing else. So the allocator, the `Io` and the CA bundle have to live in
//! process globals, which is what the `register`/`deregister` pair below
//! manages. The bundle and its lock are shared exactly the way
//! `std.http.Client` shares `ca_bundle`/`ca_bundle_lock`
//! (`std/http/Client.zig:32-33`, `:1705-1723`).
//!
//! ## Two settings that are not defaults
//!
//! **`allow_truncation_attacks = false`.** `std.http.Client` sets it *true*
//! (`Client.zig:358-360`) and says why: HTTP has a Content-Length to
//! cross-check, so a truncated stream is caught one layer up. The git smart
//! protocol has no such thing — a packfile response is chunked and ends when it
//! ends — so a stream cut short by an attacker would look to libgit2 like a
//! short, well-formed answer. Truncation must therefore be a TLS-layer error.
//!
//! **`wrap` left null.** That is documented as "HTTP CONNECT proxies will not
//! be supported", i.e. a refusal, which is what we want. A proxy is also why
//! `proxy_support` stays 0 — `git_stream_set_proxy` checks that flag and errors
//! before ever reaching us (`stream.h:38-46`), so there is no path on which a
//! proxy is silently ignored.
//!
//! ## `certificate` is never called
//!
//! Verification is `std.crypto.Certificate.Bundle`'s, done inside the
//! handshake. libgit2's own `certificate` hook only runs when a
//! `certificate_check` callback was passed through `git_fetch_options`
//! (`httpclient.c:837-840`), and `lib.zig` passes NULL options on purpose. The
//! callback below therefore returns `-1` with an error set: unreachable, and
//! loud if that ever stops being true.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const c = @import("c.zig");

pub const Error = error{
    /// `git_stream_register` refused the registration.
    StreamRegisterFailed,
    /// The system CA bundle could not be read. Fatal on purpose: continuing
    /// without it would mean an unverified TLS connection.
    CertificateBundleLoadFailure,
} || Io.Cancelable;

// ---------------------------------------------------------------------------
// Process globals
// ---------------------------------------------------------------------------

const Global = struct {
    gpa: Allocator,
    io: Io,
};

/// Guards `refs`, the write side of `global`, and the *lifecycle* of
/// `ca_bundle` (its contents are guarded by `ca_bundle_lock`, which is what
/// `std.crypto.tls.Client` locks during a handshake).
///
/// Taken only by `register`/`deregister`, never by a stream callback -- which
/// matters, because `Io.Mutex.lock` needs an `Io` and `streamInit` has none
/// until it has read the global. Hence the separate publication flag below:
/// `global` is written first and `global_ready` released after, so a reader
/// that acquires a `true` sees a fully written `global`. That is the standard
/// publication pattern, and it is why the read side needs no lock at all.
var mutex: Io.Mutex = .init;
var refs: usize = 0;

var global: Global = undefined;
var global_ready: std.atomic.Value(bool) = .init(false);

var ca_bundle: std.crypto.Certificate.Bundle = .empty;
var ca_bundle_lock: Io.RwLock = .init;

/// Static, because libgit2 keeps the pointer we hand it
/// (`streams/registry.c` stores the struct, but a stale pointer here would
/// still be a footgun and the struct is two words).
var registration: c.git_stream_registration = .{
    .version = c.stream_version,
    .init = streamInit,
    .wrap = null,
};

/// Install the stream. Idempotent and reference-counted, so several `Lib`
/// instances in one process share one registration and one CA bundle.
///
/// The bundle is loaded here rather than lazily at connect time so that "this
/// machine has no CA store" is an error at startup, where it can be reported,
/// rather than an error inside a fetch callback where it becomes a libgit2
/// string.
pub fn register(gpa: Allocator, io: Io) Error!void {
    try mutex.lock(io);
    defer mutex.unlock(io);

    if (refs == 0) {
        global = .{ .gpa = gpa, .io = io };

        ca_bundle.rescan(gpa, io, Io.Clock.real.now(io)) catch {
            ca_bundle.deinit(gpa);
            ca_bundle = .empty;
            return error.CertificateBundleLoadFailure;
        };
        errdefer {
            ca_bundle.deinit(gpa);
            ca_bundle = .empty;
        }

        if (c.git_stream_register(c.GIT_STREAM_TLS, &registration) != 0)
            return error.StreamRegisterFailed;
        // Last, and with release ordering: everything a callback will read has
        // been written by now.
        global_ready.store(true, .release);
    }
    refs += 1;
}

/// Undo one `register`. On the last one, hands TLS back to libgit2's own
/// (absent) backends and frees the bundle — which is what makes the test
/// allocator's leak check meaningful.
pub fn deregister(io: Io) void {
    // Uncancelable: this runs from `Lib.deinit`, and a cancelled unregister
    // would leave libgit2 holding function pointers into a freed CA bundle.
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (refs == 0) return;
    refs -= 1;
    if (refs != 0) return;

    // Unregister BEFORE the bundle goes, so no in-flight handshake can find a
    // stream whose CA store has been freed underneath it.
    _ = c.git_stream_register(c.GIT_STREAM_TLS, null);
    global_ready.store(false, .release);
    ca_bundle.deinit(global.gpa);
    ca_bundle = .empty;
}

// ---------------------------------------------------------------------------
// The stream
// ---------------------------------------------------------------------------

/// The buffer sizes `std.http.Client` uses, and for the same reasons
/// (`Client.zig:35`, `:53`, `:55`, `:319-323`).
const net_buf_len = std.crypto.tls.Client.min_buffer_len;
const plain_read_extra = 8192;
const plain_write_len = 4096;

const Stream = struct {
    /// What libgit2 sees. NOT required to be the first field: `streamInit`
    /// hands out `&self.base`, never `@ptrCast(self)`, and every callback
    /// recovers the parent with `@fieldParentPtr`. Requiring offset zero would
    /// be a layout assumption Zig does not make and does not need to.
    base: c.git_stream,

    gpa: Allocator,
    io: Io,
    /// Owned, NUL-terminated, and kept for the lifetime of the stream: it is
    /// the name the certificate is verified against on every reconnect.
    host: [:0]u8,
    port: u16,

    tcp: ?Io.net.Stream = null,
    tls: ?std.crypto.tls.Client = null,
    /// Initialised in place inside this heap allocation and never moved
    /// afterwards: `tls` holds `&stream_reader.interface` and
    /// `&stream_writer.interface`.
    stream_reader: Io.net.Stream.Reader = undefined,
    stream_writer: Io.net.Stream.Writer = undefined,

    net_read: []u8,
    net_write: []u8,
    plain_read: []u8,
    plain_write: []u8,

    /// The Zig error behind the last `-1`. libgit2 flattens everything into one
    /// string, and `error.CertificateHostMismatch` losing its identity on the
    /// way to `lib.zig` is exactly how a TLS failure becomes "fetch failed".
    err: ?anyerror = null,
};

/// `git_stream_registration.init`: allocate, describe, do NOT connect.
///
/// libgit2 calls `connect` as a separate step (`httpclient.c:832`), and
/// conflating the two would make a `git_stream_free` of an unconnected stream —
/// which happens on every failed `setup_hosts` — try to tear down a session
/// that was never established.
fn streamInit(out: **c.git_stream, host: [*:0]const u8, port: [*:0]const u8) callconv(.c) c_int {
    if (!global_ready.load(.acquire)) {
        _ = c.git_error_set_str(c.GIT_ERROR_SSL, "ajt: TLS stream used before registration");
        return -1;
    }
    const state = global;

    const port_str = std.mem.span(port);
    const port_num = parsePort(port_str) orelse {
        _ = c.git_error_set_str(c.GIT_ERROR_NET, "ajt: unrecognised port");
        return -1;
    };

    const self = create(state.gpa, state.io, std.mem.span(host), port_num) catch {
        _ = c.git_error_set_str(c.GIT_ERROR_NOMEMORY, "ajt: out of memory creating a TLS stream");
        return -1;
    };
    out.* = &self.base;
    return 0;
}

/// libgit2 normalises the port to a numeric string for every scheme it knows
/// (`git_net_url_parse` fills in the scheme's default), so the named forms
/// below are a courtesy rather than a code path anything currently takes. They
/// are here so an unexpected value is a named refusal instead of a `0` port.
fn parsePort(s: []const u8) ?u16 {
    if (std.fmt.parseInt(u16, s, 10)) |n| {
        if (n != 0) return n;
    } else |_| {}
    if (std.mem.eql(u8, s, "https")) return 443;
    if (std.mem.eql(u8, s, "http")) return 80;
    return null;
}

fn create(gpa: Allocator, io: Io, host: []const u8, port: u16) Allocator.Error!*Stream {
    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);

    const host_owned = try gpa.allocSentinel(u8, host.len, 0);
    errdefer gpa.free(host_owned);
    @memcpy(host_owned, host);

    const net_read = try gpa.alloc(u8, net_buf_len);
    errdefer gpa.free(net_read);
    const net_write = try gpa.alloc(u8, net_buf_len);
    errdefer gpa.free(net_write);
    const plain_read = try gpa.alloc(u8, net_buf_len + plain_read_extra);
    errdefer gpa.free(plain_read);
    const plain_write = try gpa.alloc(u8, plain_write_len);
    errdefer gpa.free(plain_write);

    self.* = .{
        .base = .{
            .version = c.stream_version,
            // `encrypted = 1` is what tells libgit2 this stream carries TLS,
            // and therefore that it may send credentials over it
            // (`http.c` refuses Basic auth on an unencrypted stream). Claiming
            // it while not verifying anything is the failure mode
            // `git_stream.sh` gate 2 exists to catch.
            .flags = .{ .encrypted = true, .proxy_support = false },
            .timeout = 0,
            .connect_timeout = 0,
            .connect = streamConnect,
            .certificate = streamCertificate,
            .set_proxy = streamSetProxy,
            .read = streamRead,
            .write = streamWrite,
            .close = streamClose,
            .free = streamFree,
        },
        .gpa = gpa,
        .io = io,
        .host = host_owned,
        .port = port,
        .net_read = net_read,
        .net_write = net_write,
        .plain_read = plain_read,
        .plain_write = plain_write,
    };
    return self;
}

fn fromBase(base: *c.git_stream) *Stream {
    return @fieldParentPtr("base", base);
}

/// Every `-1` goes through here, because libgit2 reports failure as "-1, now go
/// read `git_error_last`" — a `-1` without a preceding `git_error_set_str`
/// surfaces as whatever unrelated error happened last.
fn fail(self: *Stream, err: anyerror, klass: c_int) c_int {
    self.err = err;
    var buf: [192]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, "ajt tls ({s}:{d}): {s}", .{
        self.host, self.port, @errorName(err),
    }) catch "ajt tls: error";
    _ = c.git_error_set_str(klass, msg.ptr);
    return -1;
}

fn streamConnect(base: *c.git_stream) callconv(.c) c_int {
    const self = fromBase(base);
    connectImpl(self) catch |err| return fail(self, err, tlsErrorClass(err));
    return 0;
}

/// Certificate and handshake failures are `GIT_ERROR_SSL`; everything else is a
/// network error. The distinction is not cosmetic — it is what a reader of the
/// message uses to tell "this host is not who it says" from "this host is
/// down".
fn tlsErrorClass(err: anyerror) c_int {
    const name = @errorName(err);
    if (std.mem.startsWith(u8, name, "Tls") or std.mem.startsWith(u8, name, "Certificate"))
        return c.GIT_ERROR_SSL;
    return c.GIT_ERROR_NET;
}

fn connectImpl(self: *Stream) !void {
    // libgit2 closes and re-creates streams rather than reconnecting them
    // (`httpclient.c:1079-1086`), but a second `connect` on a live stream must
    // not silently open a second socket.
    if (self.tls != null) return;

    const host_name = try Io.net.HostName.init(self.host);
    const tcp = try host_name.connect(self.io, self.port, .{ .mode = .stream });
    self.tcp = tcp;
    // Closing AND forgetting, in one place. The socket is already published in
    // `self.tcp` by the time the handshake can fail, and libgit2 calls `close`
    // on a stream whose `connect` returned -1 (`httpclient.c:1119` ->
    // `close_stream`) -- so a bare `errdefer tcp.close(io)` closes the same fd
    // twice, which on Zig's debug `Io` is an EBADF panic rather than a quiet
    // bug. Found by `git_stream.sh` gate 2, on the very first expired
    // certificate.
    errdefer {
        tcp.close(self.io);
        self.tcp = null;
    }

    self.stream_reader = tcp.reader(self.io, self.net_read);
    self.stream_writer = tcp.writer(self.io, self.net_write);

    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    self.io.random(&entropy);

    self.tls = std.crypto.tls.Client.init(
        &self.stream_reader.interface,
        &self.stream_writer.interface,
        .{
            .host = .{ .explicit = self.host },
            .ca = .{ .bundle = .{
                .gpa = self.gpa,
                .io = self.io,
                .lock = &ca_bundle_lock,
                .bundle = &ca_bundle,
            } },
            .read_buffer = self.plain_read,
            .write_buffer = self.plain_write,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(self.io),
            // See the module header: the git smart protocol has no length to
            // cross-check, so truncation has to be caught here or nowhere.
            .allow_truncation_attacks = false,
        },
    ) catch |err| switch (err) {
        // Surface the underlying I/O error rather than "ReadFailed", the way
        // `std.http.Client` does (`Client.zig:365-368`).
        error.WriteFailed => return self.stream_writer.err orelse error.WriteFailed,
        error.ReadFailed => return self.stream_reader.err orelse error.ReadFailed,
        else => |e| return e,
    };
}

fn streamCertificate(out: **c.git_cert, base: *c.git_stream) callconv(.c) c_int {
    _ = out;
    const self = fromBase(base);
    // Unreachable while `lib.zig` passes NULL fetch options: libgit2 only asks
    // for the certificate when a `certificate_check` callback was supplied
    // (`httpclient.c:837-840`). If that ever changes, this says so rather than
    // handing back an uninitialised `git_cert`.
    return fail(self, error.CertificateInspectionUnsupported, c.GIT_ERROR_SSL);
}

fn streamSetProxy(base: *c.git_stream, opts: ?*const c.git_proxy_options) callconv(.c) c_int {
    _ = opts;
    const self = fromBase(base);
    // `proxy_support = 0`, and `git_stream_set_proxy` (`stream.h:38-46`) checks
    // that flag before dispatching, so this is unreachable too.
    return fail(self, error.ProxyUnsupported, c.GIT_ERROR_NET);
}

/// `recv` semantics: >0 bytes, 0 at end of stream, <0 on error. Crucially NOT
/// "fill the buffer" — libgit2 sends a request and then reads the response, so
/// a read that blocked until `len` bytes had arrived would deadlock against a
/// server waiting for the next request. `peekGreedy(1)` is exactly "at least
/// one byte, and whatever else already arrived".
fn streamRead(base: *c.git_stream, data: ?*anyopaque, len: usize) callconv(.c) isize {
    const self = fromBase(base);
    if (len == 0) return 0;
    const client = &(self.tls orelse return fail(self, error.NotConnected, c.GIT_ERROR_NET));

    const available = client.reader.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => {
            const cause = readError(self, err);
            return fail(self, cause, tlsErrorClass(cause));
        },
    };
    const n = @min(available.len, len);
    const dest: [*]u8 = @ptrCast(data.?);
    @memcpy(dest[0..n], available[0..n]);
    client.reader.toss(n);
    return @intCast(n);
}

/// Dig the real cause out from under `error.ReadFailed`.
fn readError(self: *Stream, err: anyerror) anyerror {
    if (err != error.ReadFailed) return err;
    if (self.tls) |*client| if (client.read_err) |e| return e;
    if (self.stream_reader.err) |e| return e;
    return err;
}

/// libgit2 loops on short writes (`git_stream__write_full`, `stream.h:58-70`),
/// but it also writes a whole request and then *reads*, so the bytes must be on
/// the wire before this returns. Both TLS and socket buffers are therefore
/// flushed on every call rather than at some later point we never get told
/// about.
fn streamWrite(base: *c.git_stream, data: [*]const u8, len: usize, flags: c_int) callconv(.c) isize {
    _ = flags;
    const self = fromBase(base);
    if (len == 0) return 0;
    const client = &(self.tls orelse return fail(self, error.NotConnected, c.GIT_ERROR_NET));

    client.writer.writeAll(data[0..len]) catch |err| return fail(self, writeError(self, err), c.GIT_ERROR_NET);
    client.writer.flush() catch |err| return fail(self, writeError(self, err), c.GIT_ERROR_NET);
    self.stream_writer.interface.flush() catch |err| return fail(self, writeError(self, err), c.GIT_ERROR_NET);
    return @intCast(len);
}

fn writeError(self: *Stream, err: anyerror) anyerror {
    if (err != error.WriteFailed) return err;
    if (self.stream_writer.err) |e| return e;
    return err;
}

/// Tear the session down but leave the object usable, so a later `connect`
/// works. libgit2 1.9 actually frees and re-creates the stream on a 401 or a
/// cross-host redirect (`httpclient.c:1079-1086`), so this is defensive rather
/// than load-bearing — but "close then connect" is the contract the interface
/// implies, and an implementation that quietly could not do it would be a trap
/// for the next libgit2.
fn streamClose(base: *c.git_stream) callconv(.c) c_int {
    const self = fromBase(base);
    if (self.tls) |*client| {
        // close_notify, best effort: the peer may already be gone, and failing
        // to say goodbye is not a reason to report a failed close.
        client.end() catch {};
        self.stream_writer.interface.flush() catch {};
    }
    self.tls = null;
    if (self.tcp) |s| s.close(self.io);
    self.tcp = null;
    return 0;
}

fn streamFree(base: *c.git_stream) callconv(.c) void {
    const self = fromBase(base);
    _ = streamClose(base);
    const gpa = self.gpa;
    gpa.free(self.plain_write);
    gpa.free(self.plain_read);
    gpa.free(self.net_write);
    gpa.free(self.net_read);
    gpa.free(self.host);
    gpa.destroy(self);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parsePort takes a number, names the two schemes, and refuses the rest" {
    // Nothing below exists without `-Dgit`. The condition is comptime-known, so
    // the rest of this body is not even analysed -- which is what keeps
    // `git_error_set_str` and friends out of a build with no libgit2 to link.
    if (!c.enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(?u16, 443), parsePort("443"));
    try testing.expectEqual(@as(?u16, 9418), parsePort("9418"));
    try testing.expectEqual(@as(?u16, 443), parsePort("https"));
    try testing.expectEqual(@as(?u16, 80), parsePort("http"));
    // Port 0 is not a port; accepting it would connect somewhere unpredictable.
    try testing.expectEqual(@as(?u16, null), parsePort("0"));
    try testing.expectEqual(@as(?u16, null), parsePort(""));
    try testing.expectEqual(@as(?u16, null), parsePort("70000"));
    try testing.expectEqual(@as(?u16, null), parsePort("ssh"));
}

test "the two error classes are told apart by name" {
    if (!c.enabled) return error.SkipZigTest;
    // libgit2 shows the class to nobody, but Ajt's own message says "TLS" or
    // "network" based on it, and the two are different problems.
    try testing.expectEqual(c.GIT_ERROR_SSL, tlsErrorClass(error.CertificateHostMismatch));
    try testing.expectEqual(c.GIT_ERROR_SSL, tlsErrorClass(error.CertificateExpired));
    try testing.expectEqual(c.GIT_ERROR_SSL, tlsErrorClass(error.TlsAlert));
    try testing.expectEqual(c.GIT_ERROR_SSL, tlsErrorClass(error.TlsConnectionTruncated));
    try testing.expectEqual(c.GIT_ERROR_NET, tlsErrorClass(error.ConnectionRefused));
    try testing.expectEqual(c.GIT_ERROR_NET, tlsErrorClass(error.UnknownHostName));
}

test "the vtable is fully populated before libgit2 ever sees it" {
    if (!c.enabled) return error.SkipZigTest;
    // A null slot here is a null function pointer call inside libgit2. Building
    // one and checking every field costs nothing and is the only place the
    // omission would be caught before a segfault.
    const gpa = testing.allocator;
    const self = try create(gpa, testing.io, "example.invalid", 443);
    defer streamFree(&self.base);

    try testing.expectEqual(c.stream_version, self.base.version);
    try testing.expect(self.base.flags.encrypted);
    try testing.expect(!self.base.flags.proxy_support);
    try testing.expect(self.base.connect != null);
    try testing.expect(self.base.certificate != null);
    try testing.expect(self.base.set_proxy != null);
    try testing.expect(self.base.read != null);
    try testing.expect(self.base.write != null);
    try testing.expect(self.base.close != null);
    try testing.expect(self.base.free != null);

    // And `@fieldParentPtr` really does recover the object from the pointer
    // libgit2 is handed -- the substitute for making `base` field zero.
    try testing.expectEqual(self, fromBase(&self.base));
    try testing.expectEqualStrings("example.invalid", self.host);
}

test "close on a stream that never connected is a no-op, and free after it is safe" {
    if (!c.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    const self = try create(gpa, testing.io, "example.invalid", 443);
    try testing.expectEqual(@as(c_int, 0), streamClose(&self.base));
    try testing.expectEqual(@as(c_int, 0), streamClose(&self.base));
    streamFree(&self.base);
}

test "reading or writing before connect fails loudly instead of dereferencing null" {
    if (!c.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    const self = try create(gpa, testing.io, "example.invalid", 443);
    defer streamFree(&self.base);

    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), streamRead(&self.base, &buf, buf.len));
    try testing.expectEqual(@as(?anyerror, error.NotConnected), self.err);

    try testing.expectEqual(@as(isize, -1), streamWrite(&self.base, "hi", 2, 0));
    try testing.expectEqual(@as(?anyerror, error.NotConnected), self.err);

    // A zero-length request is answered without touching the session at all,
    // which is what libgit2's `git_stream__write_full` loop relies on.
    try testing.expectEqual(@as(isize, 0), streamRead(&self.base, &buf, 0));
    try testing.expectEqual(@as(isize, 0), streamWrite(&self.base, "", 0, 0));
}

test "certificate and set_proxy refuse, and record why" {
    if (!c.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    const self = try create(gpa, testing.io, "example.invalid", 443);
    defer streamFree(&self.base);

    var cert: *c.git_cert = undefined;
    try testing.expectEqual(@as(c_int, -1), streamCertificate(&cert, &self.base));
    try testing.expectEqual(@as(?anyerror, error.CertificateInspectionUnsupported), self.err);

    try testing.expectEqual(@as(c_int, -1), streamSetProxy(&self.base, null));
    try testing.expectEqual(@as(?anyerror, error.ProxyUnsupported), self.err);
}

test "register is reference-counted, so two Libs share one bundle" {
    if (!c.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    try register(gpa, testing.io);
    try register(gpa, testing.io);
    try testing.expectEqual(@as(usize, 2), refs);
    deregister(testing.io);
    try testing.expectEqual(@as(usize, 1), refs);
    // Still installed after the first release: a second Lib may still be
    // fetching, and pulling the registration out from under it would turn a
    // live handshake into a use-after-free.
    try testing.expect(global_ready.load(.acquire));
    deregister(testing.io);
    try testing.expectEqual(@as(usize, 0), refs);
    try testing.expect(!global_ready.load(.acquire));
    // And an extra release does not underflow the count.
    deregister(testing.io);
    try testing.expectEqual(@as(usize, 0), refs);
}
