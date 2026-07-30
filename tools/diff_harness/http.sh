#!/usr/bin/env bash
# Differential gate for the Pkg-server HTTP client.
#
# Two checks, cheapest first:
#
#   1. OFFLINE — the request headers Ajt would send must equal
#      `Pkg.PlatformEngines.get_metadata_headers(url)` byte for byte. This is
#      the whole `Julia-*` protocol surface (`PlatformEngines.jl:220-252`) and
#      it needs no network, so it runs on every invocation.
#   2. ONLINE — GET https://pkg.julialang.org/registries through Ajt, parse the
#      `^/registry/([^/]+)/([^/]+)$` lines exactly as `Registry.jl:85-92` does,
#      and compare the (uuid, tree-hash) pairs against
#      `Pkg.Registry.pkg_server_registry_info()`. This exercises TLS, two
#      cross-host redirects (pkg.julialang.org -> in.pkg.julialang.org ->
#      /registries.conservative) and body streaming in one shot.
#
# This is the only outbound network call in the project, against a public
# read-only endpoint. Step 2 SKIPS (exit 0) whenever Julia's own oracle cannot
# reach the server, so an offline box or a CI runner without egress reports
# "skipped", never a false failure. Step 1 still has to pass in that case.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

# Julia iterates ENV in hash order when it turns JULIA_PKG_SERVER_* variables
# into extra headers (:241-251), so with two of them set its header ORDER is
# unspecified while Ajt's is sorted. Clear them on both sides rather than
# encode a comparison that only holds for zero or one variable.
while IFS='=' read -r name _; do
  case "$name" in JULIA_PKG_SERVER_*) unset "$name" ;; esac
done < <(env)

DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"
JULIA_PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')

SERVER=$(julia -e 'using Pkg; s = Pkg.pkg_server(); print(s === nothing ? "" : s)')
if [ -z "$SERVER" ]; then
  echo "SKIP — the Pkg server is disabled (JULIA_PKG_SERVER is set to the empty string)"
  exit 0
fi
URL="$SERVER/registries"
echo "server: $SERVER"
echo "depot:  $DEPOT"

WORK="$(mktemp -d -t ajt-http-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
echo "==> 1/2 request headers (offline)"

julia -e '
using Pkg
for (k, v) in Pkg.PlatformEngines.get_metadata_headers(ARGS[1])
    println(k, ": ", v)
end' "$URL" > "$WORK/julia.headers" 2>"$WORK/julia.err" || {
  echo "ERROR: header oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

"$AJT_BIN" fetch --print-headers \
  --server "$SERVER" \
  --depot "$DEPOT" \
  --julia-version "$JULIA_VERSION" \
  --julia-prefix "$JULIA_PREFIX" \
  "$URL" > "$WORK/ajt.headers" || {
  echo "ERROR: ajt fetch --print-headers failed" >&2; exit 1; }

if ! diff -q "$WORK/julia.headers" "$WORK/ajt.headers" >/dev/null; then
  echo
  echo "FAIL: request headers diverge (julia | ajt):"
  diff "$WORK/julia.headers" "$WORK/ajt.headers"
  exit 1
fi
echo "    $(wc -l < "$WORK/julia.headers") headers identical"

# --------------------------------------------------------------------------
echo "==> 2/2 GET $URL (network)"

# The oracle swallows its own network failure and returns `nothing` (it only
# @warns), which is exactly the signal we want for "skip".
julia -e '
using Pkg
r = Pkg.Registry.pkg_server_registry_info()
r === nothing && exit(0)
_, info = r
for (u, h) in info
    println(u, " ", bytes2hex(h.bytes))
end' > "$WORK/julia.regs" 2>"$WORK/julia.regs.err"
sort -o "$WORK/julia.regs" "$WORK/julia.regs"

if [ ! -s "$WORK/julia.regs" ]; then
  echo
  echo "SKIP — Julia could not reach $URL either; treating this as no network."
  sed -n '1,3p' "$WORK/julia.regs.err" >&2
  exit 0
fi

# `--retry 4` is `retry(delays = fill(1.0, 3))` from Registry.jl:76 — the same
# budget Pkg gives this exact request.
if ! "$AJT_BIN" fetch --retry 4 \
      --server "$SERVER" \
      --depot "$DEPOT" \
      --julia-version "$JULIA_VERSION" \
      --julia-prefix "$JULIA_PREFIX" \
      "$URL" > "$WORK/ajt.body" 2>"$WORK/ajt.err"; then
  echo
  echo "FAIL: ajt could not fetch $URL, but Julia could:"
  tail -5 "$WORK/ajt.err" >&2
  exit 1
fi

# `match(r"^/registry/([^/]+)/([^/]+)$", line)` (Registry.jl:87). Lines that do
# not match are silently ignored by Pkg, so they are ignored here too.
sed -n 's|^/registry/\([^/]*\)/\([^/]*\)$|\1 \2|p' "$WORK/ajt.body" | sort > "$WORK/ajt.regs"

echo "==> comparing"
if diff -q "$WORK/julia.regs" "$WORK/ajt.regs" >/dev/null; then
  n=$(wc -l < "$WORK/julia.regs")
  echo
  echo "PASS — headers identical and the same $n registry pin(s) resolved as Julia"
  exit 0
fi

echo
echo "  divergences (julia | ajt):"
diff "$WORK/julia.regs" "$WORK/ajt.regs" | head -30
exit 1
