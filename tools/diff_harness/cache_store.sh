#!/usr/bin/env bash
# Gate for the precompile-cache object store transport.
#
# There is no Julia oracle here and there never will be one: Pkg has no object
# store, and the hash is BLAKE3, which Julia does not ship. So this gate is
# built on the two oracles that DO exist, and it exists because both of the
# properties below are invisible to a unit test that only checks return values.
#
#   1. REFERENCE ZSTD. The unit tests round-trip a frame Ajt wrote through a
#      decompressor Ajt chose, which proves only that Ajt agrees with itself.
#      Here the object is produced by the real `zstd -19` — the shape the
#      deployment actually publishes, and the level the ~300 MB → 80-110 MB
#      figure comes from — and Ajt has to read it. The reverse direction is
#      checked too: a frame `rawFrame` wrote must decompress under `zstd -d`,
#      because "valid zstd" is a claim about the reference implementation, not
#      about std.
#
#   2. NOTHING WRITTEN. On a corrupt object the assertion is on the
#      FILESYSTEM — the destination tree is snapshotted before and after and
#      must be identical — not on the returned error. A function can return an
#      error and still have left a mess, and the mess is what a shared depot
#      inherits. This mirrors `extract.sh`, which makes the same distinction
#      for package tarballs and for the same reason.
#
# Plus the two things a transport is judged on and a unit test tends to fake:
# that a manifest survives the wire with its cost model intact (hashes, sizes
# AND measured build times — the scheduler needs all three from one GET), and
# that retry stops. Every probe invocation runs under `timeout`, so "gives up
# cleanly" is an assertion rather than a hope: a hang fails the gate instead of
# blocking the run forever.
#
# The loopback server lives in the probe, using `io.concurrent` exactly as the
# suites in src/net/http.zig and src/ops/install_artifacts.zig do.
#
# Usage: tools/diff_harness/cache_store.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisites. `zstd` is the ORACLE, not a convenience: without it this gate
# can only compare Ajt against Ajt, which is what the unit tests already do.
# Skipping loudly beats passing vacuously.
# ---------------------------------------------------------------------------
missing=""
command -v zstd    >/dev/null || missing="$missing zstd"
command -v tar     >/dev/null || missing="$missing tar"
command -v timeout >/dev/null || missing="$missing timeout"
if [ -n "$missing" ]; then
  echo "###########################################################"
  echo "# SKIP — cache_store gate not run"
  echo "#"
  echo "# missing prerequisite(s):$missing"
  echo "#"
  echo "# zstd is this gate's reference implementation: it produces the"
  echo "# object Ajt must read and it reads the frame Ajt writes. Without"
  echo "# it the only comparison left is Ajt against itself, which the unit"
  echo "# tests already cover, so the gate reports SKIP rather than a green"
  echo "# it did not earn."
  echo "###########################################################"
  exit 0
fi
command -v zig >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-cache-store-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# A probe times out rather than hanging the gate. 60 s is two orders of
# magnitude above anything here; reaching it means a deadlock, not slowness.
run() { timeout 60 "$@"; }

# ---------------------------------------------------------------------------
# A probe binary over the library module. Written here rather than committed so
# this harness needs no build.zig step of its own; it links src/root.zig
# directly, the same module `zig build test` compiles.
#
# The probe hosts the loopback server itself — same `io.concurrent` +
# `Io.net.Server` convention as the two existing loopback suites — and prints a
# `key=value` line protocol the shell asserts on.
# ---------------------------------------------------------------------------
cat > "$WORK/probe.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ajt = @import("ajt");
const store = ajt.cache.store;
const net_http = ajt.net.http;
const Blake3 = std.crypto.hash.Blake3;

/// Scripted loopback HTTP server: one request per connection, `Connection:
/// close` on every response, and a log of the request line, the Authorization
/// header, and the BLAKE3 of the body it received. Hashing the body rather
/// than storing a prefix is what lets the shell assert that a PUT sent the
/// WHOLE object.
const Srv = struct {
    server: Io.net.Server,
    port: u16,
    count: usize = 0,
    lines: [max][200]u8 = undefined,
    line_len: [max]usize = @splat(0),
    auths: [max][120]u8 = undefined,
    auth_len: [max]usize = @splat(0),
    body_hex: [max][64]u8 = undefined,
    body_len: [max]u64 = @splat(0),

    const max = 16;
    const port_base = 45871;
    const port_span = 500;

    fn start(io: Io) !Srv {
        var seed: [2]u8 = undefined;
        io.random(&seed);
        const first = std.mem.readInt(u16, &seed, .little);
        for (0..port_span) |i| {
            const port: u16 = port_base + (first +% @as(u16, @intCast(i))) % port_span;
            const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
            const srv = addr.listen(io, .{ .reuse_address = true }) catch continue;
            return .{ .server = srv, .port = port };
        }
        return error.NoFreePort;
    }

    fn baseUrl(self: *const Srv, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    fn line(self: *const Srv, i: usize) []const u8 {
        return self.lines[i][0..self.line_len[i]];
    }
    /// The Authorization value, or the sentinel `<none>`. A sentinel rather
    /// than "" so that a shell assertion of "no credential was sent" cannot
    /// also be satisfied by a probe that printed nothing at all.
    fn auth(self: *const Srv, i: usize) []const u8 {
        if (self.auth_len[i] == 0) return "<none>";
        return self.auths[i][0..self.auth_len[i]];
    }

    /// Serves exactly `script.len` requests, then returns. Every command must
    /// issue exactly that many, or the two sides deadlock instead of failing —
    /// which is what the shell's `timeout` is there to convert into a FAIL.
    fn serve(io: Io, self: *Srv, script: []const []const u8) void {
        for (script) |response| {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);

            var read_buf: [8192]u8 = undefined;
            var sr: Io.net.Stream.Reader = .init(stream, io, &read_buf);
            const r = &sr.interface;

            const i = self.count;
            if (i >= max) return;
            self.count += 1;

            const request_line = r.takeDelimiterInclusive('\n') catch return;
            const trimmed = std.mem.trimEnd(u8, request_line, "\r\n");
            const n = @min(trimmed.len, self.lines[i].len);
            @memcpy(self.lines[i][0..n], trimmed[0..n]);
            self.line_len[i] = n;

            var content_length: u64 = 0;
            while (true) {
                const h = r.takeDelimiterInclusive('\n') catch return;
                if (h.len <= 2) break;
                if (std.ascii.startsWithIgnoreCase(h, "authorization:")) {
                    const v = std.mem.trim(u8, h["authorization:".len..], " \t\r\n");
                    const m = @min(v.len, self.auths[i].len);
                    @memcpy(self.auths[i][0..m], v[0..m]);
                    self.auth_len[i] = m;
                }
                if (std.ascii.startsWithIgnoreCase(h, "content-length:")) {
                    const v = std.mem.trim(u8, h["content-length:".len..], " \t\r\n");
                    content_length = std.fmt.parseInt(u64, v, 10) catch 0;
                }
            }

            var hasher = Blake3.init(.{});
            var remaining = content_length;
            var chunk: [8192]u8 = undefined;
            while (remaining > 0) {
                const want: usize = @intCast(@min(@as(u64, chunk.len), remaining));
                r.readSliceAll(chunk[0..want]) catch return;
                hasher.update(chunk[0..want]);
                remaining -= want;
            }
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            self.body_hex[i] = std.fmt.bytesToHex(digest, .lower);
            self.body_len[i] = content_length;

            var write_buf: [8192]u8 = undefined;
            var sw: Io.net.Stream.Writer = .init(stream, io, &write_buf);
            sw.interface.writeAll(response) catch {};
            sw.interface.flush() catch {};
        }
    }
};

fn okBody(arena: Allocator, payload: []const u8) ![]const u8 {
    const head = try std.fmt.allocPrint(
        arena,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{payload.len},
    );
    const buf = try arena.alloc(u8, head.len + payload.len);
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..], payload);
    return buf;
}

const created = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const unavailable = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

fn readAll(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    const cmd = args[1];

    // blake3 <file>
    if (std.mem.eql(u8, cmd, "blake3")) {
        const bytes = try readAll(gpa, io, args[2]);
        defer gpa.free(bytes);
        try out.print("{s}\n", .{store.toHex(store.hashBytes(bytes))});
        return;
    }

    // frame <in> <out> -- rawFrame, for `zstd -d` to read back
    if (std.mem.eql(u8, cmd, "frame")) {
        const bytes = try readAll(gpa, io, args[2]);
        defer gpa.free(bytes);
        const framed = try store.rawFrame(gpa, bytes);
        defer gpa.free(framed);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = framed });
        try out.print("framed_bytes={d}\n", .{framed.len});
        return;
    }

    // roundtrip <object-file> <dest-dir> <token>
    if (std.mem.eql(u8, cmd, "roundtrip")) {
        const object = try readAll(gpa, io, args[2]);
        defer gpa.free(object);
        const hash = store.hashBytes(object);

        var srv = try Srv.start(io);
        const script = try arena.dupe([]const u8, &.{ created, try okBody(arena, object) });
        var task = try io.concurrent(Srv.serve, .{ io, &srv, script });

        var url_buf: [64]u8 = undefined;
        var client: net_http.Client = .init(gpa, io, .{});
        defer client.deinit();
        const s: store.Store = .{
            .client = &client,
            .base_url = try arena.dupe(u8, srv.baseUrl(&url_buf)),
            .write_token = args[4],
            .options = .{ .retry = .none },
        };

        const put = try s.putObject(arena, object);
        const got = try s.fetchObject(gpa, arena, io, hash, args[3]);
        task.await(io);

        try out.print("object_hash={s}\n", .{store.toHex(hash)});
        try out.print("put_hash={s}\n", .{store.toHex(put.hash)});
        try out.print("put_ok={}\n", .{put.ok()});
        try out.print("put_line={s}\n", .{srv.line(0)});
        try out.print("put_auth={s}\n", .{srv.auth(0)});
        try out.print("put_body_blake3={s}\n", .{srv.body_hex[0]});
        try out.print("put_body_bytes={d}\n", .{srv.body_len[0]});
        try out.print("get_line={s}\n", .{srv.line(1)});
        try out.print("get_auth={s}\n", .{srv.auth(1)});
        try out.print("fetch_ok={}\n", .{got.object.ok()});
        try out.print("outcome={s}\n", .{if (got.outcome) |o| @tagName(o) else "none"});
        try out.print("requests={d}\n", .{srv.count});
        return;
    }

    // corrupt <object-file> <dest-dir>
    if (std.mem.eql(u8, cmd, "corrupt")) {
        const object = try readAll(gpa, io, args[2]);
        defer gpa.free(object);
        const hash = store.hashBytes(object);
        // One byte of PAYLOAD flipped: the frame stays structurally valid and
        // would decompress and extract perfectly well. Only the name no longer
        // describes it, which is the case the check exists for.
        object[object.len - 4] +%= 1;
        const served = store.hashBytes(object);

        var srv = try Srv.start(io);
        const script = try arena.dupe([]const u8, &.{try okBody(arena, object)});
        var task = try io.concurrent(Srv.serve, .{ io, &srv, script });

        var url_buf: [64]u8 = undefined;
        var client: net_http.Client = .init(gpa, io, .{});
        defer client.deinit();
        const s: store.Store = .{
            .client = &client,
            .base_url = try arena.dupe(u8, srv.baseUrl(&url_buf)),
            .options = .{ .retry = .none },
        };

        const got = try s.fetchObject(gpa, arena, io, hash, args[3]);
        task.await(io);

        try out.print("fetch_ok={}\n", .{got.object.ok()});
        try out.print("failure={s}\n", .{if (got.object.failure) |f| @tagName(f) else "none"});
        try out.print("outcome={s}\n", .{if (got.outcome) |o| @tagName(o) else "none"});
        try out.print("want={s}\n", .{store.toHex(hash)});
        try out.print("got={s}\n", .{got.object.computed orelse "none"});
        try out.print("served={s}\n", .{store.toHex(served)});
        try out.print("attempts={d}\n", .{got.object.attempts});
        return;
    }

    // manifest <spec-tsv> <rendered-json-out>
    //   spec line: key \t name \t object-hex \t size \t build_ms
    if (std.mem.eql(u8, cmd, "manifest")) {
        const spec = try readAll(gpa, io, args[2]);
        defer gpa.free(spec);

        var entries: std.ArrayList(store.Entry) = .empty;
        var lines = std.mem.tokenizeScalar(u8, spec, '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \r\t");
            if (l.len == 0) continue;
            var f = std.mem.splitScalar(u8, l, '\t');
            const key = f.next() orelse return error.BadSpec;
            const name = f.next() orelse return error.BadSpec;
            const object = f.next() orelse return error.BadSpec;
            const size = f.next() orelse return error.BadSpec;
            const build_ms = f.next() orelse return error.BadSpec;
            try entries.append(arena, .{
                .key = try arena.dupe(u8, key),
                .name = try arena.dupe(u8, name),
                .object = try store.parseHash(object),
                .size = try std.fmt.parseInt(u64, size, 10),
                .build_ms = try std.fmt.parseInt(u64, build_ms, 10),
            });
        }

        const m: store.Manifest = .{ .entries = entries.items };
        const bytes = try m.render(arena);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = bytes });
        const hash = store.hashBytes(bytes);

        var srv = try Srv.start(io);
        const script = try arena.dupe([]const u8, &.{ created, try okBody(arena, bytes) });
        var task = try io.concurrent(Srv.serve, .{ io, &srv, script });

        var url_buf: [64]u8 = undefined;
        var client: net_http.Client = .init(gpa, io, .{});
        defer client.deinit();
        const s: store.Store = .{
            .client = &client,
            .base_url = try arena.dupe(u8, srv.baseUrl(&url_buf)),
            .options = .{ .retry = .none },
        };

        const put = try s.putManifest(arena, m);
        const got = try s.getManifest(gpa, arena, hash);
        task.await(io);

        try out.print("manifest_hash={s}\n", .{store.toHex(hash)});
        try out.print("put_hash={s}\n", .{store.toHex(put.hash)});
        try out.print("put_ok={}\n", .{put.ok()});
        try out.print("get_ok={}\n", .{got.ok()});
        try out.print("put_line={s}\n", .{srv.line(0)});
        try out.print("get_line={s}\n", .{srv.line(1)});
        // Re-rendering what came off the wire must reproduce the very bytes
        // that were hashed, or the manifest is not content-addressable.
        const again = try got.manifest.render(arena);
        try out.print("canonical={}\n", .{std.mem.eql(u8, bytes, again)});
        for (got.manifest.entries) |e| {
            try out.print("entry\t{s}\t{s}\t{s}\t{d}\t{d}\n", .{
                e.key, e.name, store.toHex(e.object), e.size, e.build_ms,
            });
        }
        return;
    }

    // retry <object-file> <failures-before-success> <attempts>
    if (std.mem.eql(u8, cmd, "retry")) {
        const object = try readAll(gpa, io, args[2]);
        defer gpa.free(object);
        const hash = store.hashBytes(object);
        const failures = try std.fmt.parseInt(usize, args[3], 10);
        const attempts = try std.fmt.parseInt(u32, args[4], 10);

        // Script EXACTLY as many responses as the client will consume, so the
        // server task ends on its own: `failures` 503s then the object when
        // the budget outlasts them, otherwise `attempts` 503s and no success
        // at all. Scripting a spare response instead would leave the server in
        // `accept` and force a drain loop -- which would have to poll
        // `srv.count` while the server task is still writing it, and would
        // spin forever against a store that had stopped accepting, since
        // `getObject` reports a dead host as a Failure value rather than as an
        // error a `catch` could see.
        const consumed = if (failures < attempts) failures + 1 else attempts;
        var script: std.ArrayList([]const u8) = .empty;
        for (0..consumed) |i| {
            try script.append(arena, if (i + 1 == consumed and failures < attempts)
                try okBody(arena, object)
            else
                unavailable);
        }

        var srv = try Srv.start(io);
        defer srv.server.deinit(io);
        var task = try io.concurrent(Srv.serve, .{ io, &srv, script.items });

        var url_buf: [64]u8 = undefined;
        var client: net_http.Client = .init(gpa, io, .{});
        defer client.deinit();
        const s: store.Store = .{
            .client = &client,
            .base_url = try arena.dupe(u8, srv.baseUrl(&url_buf)),
            .options = .{ .retry = .{
                .attempts = attempts,
                .delay = .{ .nanoseconds = std.time.ns_per_ms },
            } },
        };

        const got = try s.getObject(gpa, arena, hash);
        // Awaited BEFORE `srv.count` is read: the server task mutates it, and
        // every other command in this probe keeps the same discipline.
        task.await(io);

        try out.print("ok={}\n", .{got.ok()});
        try out.print("failure={s}\n", .{if (got.failure) |f| @tagName(f) else "none"});
        try out.print("attempts={d}\n", .{got.attempts});
        try out.print("requests={d}\n", .{srv.count});
        try out.print("scripted={d}\n", .{script.items.len});
        return;
    }

    try out.writeAll("ERR UnknownCommand\n");
}
ZIG

echo "==> building probe"
# Hermetic per-run cache, as in extract.sh: a gate must not depend on the
# state of a shared cache directory.
( cd "$WORK" && zig build-exe \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt \
    -Mroot=probe.zig \
    -Majt="$AJT_ROOT/src/root.zig" \
    -femit-bin=probe >/dev/null ) || { echo "ERROR: probe build failed" >&2; exit 2; }
PROBE="$WORK/probe"

# ---------------------------------------------------------------------------
# Fixtures. The object is built the way the deployment builds one: a tar of a
# `compiled/` tree, then `zstd -19`.
# ---------------------------------------------------------------------------
echo "==> building fixtures"
mkdir -p "$WORK/tree/Example"
printf '\xfe\xff not really a cache header\n' > "$WORK/tree/Example/abcde.ji"
printf '\x7fELF\n'                            > "$WORK/tree/Example/abcde.so"
chmod 755 "$WORK/tree/Example/abcde.so"
mkdir -p "$WORK/tree/Example/nested"
head -c 300000 /dev/urandom > "$WORK/tree/Example/nested/big.bin"

tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf "$WORK/object.tar" -C "$WORK/tree" Example
# -19 is the level the sizing in the plan (~300 MB -> 80-110 MB) was measured
# at, so it is the level the gate reads.
zstd -19 -q -f -o "$WORK/object.tar.zst" "$WORK/object.tar"

OBJ_HASH=$(run "$PROBE" blake3 "$WORK/object.tar.zst") || { echo "ERROR: probe blake3 failed" >&2; exit 2; }
echo "object: $(wc -c < "$WORK/object.tar") bytes tar -> $(wc -c < "$WORK/object.tar.zst") bytes zstd-19"

snapshot() { # snapshot <dir> -- names, kinds and content digests
  # `cd` guarded: without it a failed cd would silently snapshot the CURRENT
  # directory twice and the before/after comparison would pass vacuously.
  [ -d "$1" ] || { echo "MISSING $1"; return 0; }
  ( cd "$1" || exit 1
    find . -mindepth 1 | LC_ALL=C sort
    find . -type f -exec cksum {} \; | LC_ALL=C sort )
}

# ---------------------------------------------------------------------------
echo "==> 1/6 BLAKE3 is BLAKE3 (official reference vectors)"
# https://github.com/BLAKE3-team/BLAKE3/blob/master/test_vectors/test_vectors.json
# The name of every object in this store is this hash; if it were quietly some
# other 32-byte digest, every other check here would still pass.
: > "$WORK/kat0"
head -c 1 /dev/zero > "$WORK/kat1"
check "blake3(empty)" \
  "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262" \
  "$(run "$PROBE" blake3 "$WORK/kat0")"
check "blake3(0x00)" \
  "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213" \
  "$(run "$PROBE" blake3 "$WORK/kat1")"

# ---------------------------------------------------------------------------
echo "==> 2/6 zstd interop, both directions"
# Ajt reads what `zstd -19` writes: proven by the round-trip in step 3, which
# fetches the -19 object above. Here the OTHER direction, which nothing else
# covers: a frame `rawFrame` produced must be readable by the reference
# implementation, or "valid zstd" is a claim about std and nobody else.
run "$PROBE" frame "$WORK/object.tar" "$WORK/rawframe.zst" >/dev/null
if zstd -d -q -f -o "$WORK/rawframe.out" "$WORK/rawframe.zst" 2>"$WORK/zstd.err"; then
  if cmp -s "$WORK/object.tar" "$WORK/rawframe.out"; then
    ok "rawFrame output decompresses under the reference zstd, byte for byte"
  else
    bad "rawFrame round trip through zstd -d" "content differs"
  fi
else
  bad "rawFrame output is a valid zstd frame" "$(tail -1 "$WORK/zstd.err")"
fi
# An empty object is the edge the block layout gets wrong first.
: > "$WORK/empty"
run "$PROBE" frame "$WORK/empty" "$WORK/empty.zst" >/dev/null
if zstd -d -q -f -o "$WORK/empty.out" "$WORK/empty.zst" 2>/dev/null && \
   [ ! -s "$WORK/empty.out" ]; then
  ok "an empty object frames and unframes"
else
  bad "an empty object frames and unframes"
fi

# ---------------------------------------------------------------------------
echo "==> 3/6 object round trip over loopback HTTP"
mkdir -p "$WORK/depot/compiled"
run "$PROBE" roundtrip "$WORK/object.tar.zst" "$WORK/depot/compiled/v1.12" "s3cret" \
  > "$WORK/rt.out" 2>"$WORK/rt.err" || bad "roundtrip probe exited non-zero" "$(tail -3 "$WORK/rt.err")"
val() { sed -n "s/^$1=//p" "$2" | head -1; }

check "PUT names the object by its own hash" \
  "PUT /objects/$OBJ_HASH.tar.zst HTTP/1.1" "$(val put_line "$WORK/rt.out")"
check "PUT reports the hash it stored under" "$OBJ_HASH" "$(val put_hash "$WORK/rt.out")"
check "PUT succeeded" "true" "$(val put_ok "$WORK/rt.out")"
# The whole body, not a prefix: the server hashed what it received.
check "PUT sent the object byte for byte" "$OBJ_HASH" "$(val put_body_blake3 "$WORK/rt.out")"
check "PUT sent every byte" "$(wc -c < "$WORK/object.tar.zst")" "$(val put_body_bytes "$WORK/rt.out")"
# The write credential is a WRITE credential.
check "PUT carried the store token" "Bearer s3cret" "$(val put_auth "$WORK/rt.out")"
check "GET asked for the same immutable URL" \
  "GET /objects/$OBJ_HASH.tar.zst HTTP/1.1" "$(val get_line "$WORK/rt.out")"
# The probe prints the sentinel `<none>` rather than an empty string, because
# `check "…" "" "$(val …)"` would also pass against a probe that crashed before
# printing anything.
check "GET carried no credential" "<none>" "$(val get_auth "$WORK/rt.out")"
check "fetch succeeded" "true" "$(val fetch_ok "$WORK/rt.out")"
check "fetch published by rename" "installed" "$(val outcome "$WORK/rt.out")"

# The tree that landed must be the tree that went in. Content is compared with
# `diff -r`; uid/gid/mtime deliberately are NOT, because extraction does not
# restore them and nothing downstream depends on them (a git tree hash ignores
# all three, and a `.ji` is validated by its own header, never by its mtime).
if diff -r "$WORK/tree/Example" "$WORK/depot/compiled/v1.12/Example" > "$WORK/tree.diff" 2>&1; then
  ok "the extracted tree matches the archive, file for file"
else
  bad "the extracted tree matches the archive" "$(head -3 "$WORK/tree.diff")"
fi
# The executable bit IS part of it: it is the one mode bit a build product
# needs and the one a tar round trip can silently drop.
if [ -x "$WORK/depot/compiled/v1.12/Example/abcde.so" ]; then
  ok "the executable bit survived extraction"
else
  bad "the executable bit survived extraction"
fi
# `compiled/` is Julia's to rewrite; a read-only tree there breaks the next
# precompile.
if [ -w "$WORK/depot/compiled/v1.12/Example/abcde.ji" ]; then
  ok "the published tree stays writable (compiled/ is Julia's)"
else
  bad "the published tree stays writable"
fi
# No staging leftovers: exactly the one destination under compiled/.
check "no staging directory survived" "1" "$(find "$WORK/depot/compiled" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "==> 4/6 a corrupted object is rejected with NOTHING written"
mkdir -p "$WORK/depot2/compiled"
BEFORE="$(snapshot "$WORK/depot2")"
run "$PROBE" corrupt "$WORK/object.tar.zst" "$WORK/depot2/compiled/v1.12" \
  > "$WORK/bad.out" 2>"$WORK/bad.err" || bad "corrupt probe exited non-zero" "$(tail -3 "$WORK/bad.err")"
AFTER="$(snapshot "$WORK/depot2")"

check "the corrupt object was refused" "false" "$(val fetch_ok "$WORK/bad.out")"
check "...as a hash mismatch" "hash_mismatch" "$(val failure "$WORK/bad.out")"
check "...with no outcome at all" "none" "$(val outcome "$WORK/bad.out")"
# Both sides of the mismatch, or it cannot be diagnosed. `served` is what the
# probe actually put on the wire, recomputed independently here from the same
# one-byte edit, so this is not the probe agreeing with itself.
check "the expected hash is reported" "$OBJ_HASH" "$(val want "$WORK/bad.out")"
BAD_HASH="$(val served "$WORK/bad.out")"
check "the received hash is reported" "$BAD_HASH" "$(val got "$WORK/bad.out")"
# ...and the two are genuinely different, or the assertion above is vacuous.
if [ -n "$BAD_HASH" ] && [ "$BAD_HASH" != "$OBJ_HASH" ]; then
  ok "the reported hashes actually differ"
else
  bad "the reported hashes actually differ" "want=$OBJ_HASH got=$BAD_HASH"
fi
# A corrupt object is a stable answer; retrying one only burns time.
check "a hash mismatch is not retried" "1" "$(val attempts "$WORK/bad.out")"
# THE assertion, and it is about the filesystem rather than the return value.
if [ "$BEFORE" = "$AFTER" ]; then
  ok "the destination tree is byte-identical before and after"
else
  bad "the destination tree is unchanged" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -5)"
fi
# Stronger than "unchanged": the parent chain `depot.begin` would have created
# does not exist either, because the refusal happens before `begin` runs.
check "not even a staging directory" "0" "$(find "$WORK/depot2/compiled" -mindepth 1 | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "==> 5/6 the manifest carries the plan AND its cost model"
H1=$(run "$PROBE" blake3 "$WORK/object.tar")
H2=$(run "$PROBE" blake3 "$WORK/object.tar.zst")
H3=$(run "$PROBE" blake3 "$WORK/kat1")
{
  printf 'k-zlib\tZlib_jll\t%s\t4096\t12500\n'         "$H2"
  printf 'k-adapt\tAdapt\t%s\t1048576\t340\n'          "$H1"
  printf 'k-makie\tMakie\t%s\t0\t904113\n'             "$H3"
} > "$WORK/manifest.tsv"

run "$PROBE" manifest "$WORK/manifest.tsv" "$WORK/manifest.json" \
  > "$WORK/mf.out" 2>"$WORK/mf.err" || bad "manifest probe exited non-zero" "$(tail -3 "$WORK/mf.err")"

MF_HASH="$(val manifest_hash "$WORK/mf.out")"
check "PUT names the manifest by its own hash" \
  "PUT /manifests/$MF_HASH.json HTTP/1.1" "$(val put_line "$WORK/mf.out")"
check "PUT reports that hash back" "$MF_HASH" "$(val put_hash "$WORK/mf.out")"
check "GET asked for the same URL" \
  "GET /manifests/$MF_HASH.json HTTP/1.1" "$(val get_line "$WORK/mf.out")"
check "GET succeeded" "true" "$(val get_ok "$WORK/mf.out")"
# Re-rendering what came off the wire reproduces the hashed bytes, which is
# what makes a manifest content-addressable at all.
check "the rendering is canonical" "true" "$(val canonical "$WORK/mf.out")"

# Every field survives: hash, size AND build time. Sorted on both sides because
# the canonical form is sorted by key.
sed -n 's/^entry\t//p' "$WORK/mf.out" | LC_ALL=C sort > "$WORK/mf.got"
LC_ALL=C sort "$WORK/manifest.tsv" > "$WORK/mf.want"
if diff -u "$WORK/mf.want" "$WORK/mf.got" > "$WORK/mf.diff" 2>&1; then
  ok "hashes, sizes and build times all survive the wire"
else
  bad "manifest fields survive the wire" "$(head -8 "$WORK/mf.diff")"
fi
# The cost model has to be ON THE WIRE, not merely in the struct: a renderer
# that dropped build_ms would still round-trip through a reader that defaulted
# it, and the scheduler would silently get a flat cost model.
if grep -q '"build_ms":904113' "$WORK/manifest.json"; then
  ok "build times are serialised, not defaulted"
else
  bad "build times are serialised" "$(head -c 300 "$WORK/manifest.json")"
fi

# ---------------------------------------------------------------------------
echo "==> 6/6 retry: recovers, then gives up"
# Two 503s against a 3-attempt budget: the third request must succeed and the
# fourth must never happen.
run "$PROBE" retry "$WORK/object.tar.zst" 2 3 > "$WORK/r1.out" 2>"$WORK/r1.err"
RC=$?
if [ $RC -eq 124 ]; then bad "retry probe hung (timeout)"; fi
check "a flaky store is survived" "true"  "$(val ok "$WORK/r1.out")"
check "...after exactly 3 attempts" "3"   "$(val attempts "$WORK/r1.out")"
check "...and 3 requests"           "3"   "$(val requests "$WORK/r1.out")"

# Now more failures than the budget: it must stop at the budget, report the
# last status, and RETURN -- not hang, and not error out.
run "$PROBE" retry "$WORK/object.tar.zst" 5 3 > "$WORK/r2.out" 2>"$WORK/r2.err"
RC=$?
if [ $RC -eq 124 ]; then bad "retry probe hung (timeout)"; fi
check "the budget is respected" "3"      "$(val attempts "$WORK/r2.out")"
check "...and it gave up"       "false"  "$(val ok "$WORK/r2.out")"
check "...cleanly, as a status" "http_status" "$(val failure "$WORK/r2.out")"
# It stopped at the budget rather than draining every scripted failure.
check "...after exactly 3 requests" "3"  "$(val requests "$WORK/r2.out")"

# A single attempt is a single request: retry is opt-in, not implicit.
run "$PROBE" retry "$WORK/object.tar.zst" 1 1 > "$WORK/r3.out" 2>/dev/null
check "attempts=1 issues one request" "1" "$(val attempts "$WORK/r3.out")"
check "...and reports the failure"    "false" "$(val ok "$WORK/r3.out")"

# ---------------------------------------------------------------------------
echo
echo "cache_store: $PASS ok, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
