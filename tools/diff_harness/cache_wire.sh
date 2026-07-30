#!/usr/bin/env bash
# End-to-end gate for the shared precompile cache (src/ops/precompile.zig's
# Probe/Import/VerifyCache/Publish stages over src/cache/store.zig).
#
# The claim: **a package compiled on one machine can be IMPORTED on another
# instead of compiled, and stock Julia cannot tell the difference.** Every word
# of that is checked here against a real store, a real `julia`, and two depots
# that share nothing.
#
# Why a real HTTP store rather than a mock. The unit tests already drive the
# store against a scripted socket; what they cannot answer is whether the bytes
# that come back are a cache entry Julia will LOAD. That question needs a `.ji`
# that a real compile produced, moved to a slug computed on the far side, and
# then handed to a real Julia. So this runs a tiny GET/PUT server over a
# directory and does the whole round trip.
#
# Six sections:
#
#   0. FIXTURE. A small package environment (Parsers, so the graph has depth)
#      and two depots, each instantiated separately. Depot A publishes, depot B
#      imports; nothing is shared between them but the store.
#   1. PUBLISH. `ajt precompile --cache-url` into depot A. Every package it
#      compiled AND could address must appear in the store as an object plus a
#      key pointing at it.
#   2. IMPORT. The same command into depot B, whose `compiled/` is empty. The
#      packages that were published must come back as `imported`, NOT
#      `compiled` -- the distinction is the entire point, and a run that
#      imported them and compiled them anyway would look identical in every
#      other respect.
#   3. THE EXTERNAL GATE. Julia loads the package out of depot B, and
#      `Pkg.precompile()` finds nothing to do. A cache entry that looked right
#      but that Julia rejected would pass sections 1-2 and be worthless.
#   4. FALLBACKS. A store that 404s everything, and a store that is not
#      listening at all. Both must leave a correct depot -- the cache is an
#      optimisation, and an optimisation that can break a build is a bug.
#   5. THE TOKEN. A store that gates PUT behind `Authorization: Bearer` (the
#      shape a fronting proxy would enforce; the store server plays the
#      proxy's part). Without a credential the publish is refused, COUNTED,
#      and harmless; with $AJT_CACHE_TOKEN it lands; and a GET that carries
#      the token is answered 403, which is how this file proves lookups
#      never send it -- a token on the read path would leak the write
#      credential to any cache, CDN or log between here and the store.
#
# NOTHING here touches the user's real depot: every depot is under $WORK and
# every julia invocation gets JULIA_DEPOT_PATH pointed there.
#
# Usage: cache_wire.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

skip () {
  echo; echo "########################################################################"
  echo "# SKIPPED: $1"; printf '# %s\n' "${@:2}"
  echo "########################################################################"; exit 0
}

command -v julia  >/dev/null || skip "julia is not on PATH."
command -v zig    >/dev/null || skip "zig is not on PATH, so ajt cannot be built."
command -v python3>/dev/null || skip "python3 is not on PATH; it is the store server."

WORK="$(mktemp -d -t ajt-cachewire-XXXXXX)"
SRV_PID=""
cleanup () {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
}
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0; FAIL=0
ok ()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad ()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# ---------------------------------------------------------------------------
echo
echo "==> 0. the fixture, two depots, and a store"

ENV_DIR="$WORK/env"
mkdir -p "$ENV_DIR/src" "$WORK/store"
cat > "$ENV_DIR/Project.toml" <<'EOF'
name = "AjtCacheFixture"
uuid = "0d2b8f34-6a1e-4c9d-9f2b-3a5c7e1d4b61"
version = "0.1.0"

[deps]
Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
EOF
cat > "$ENV_DIR/src/AjtCacheFixture.jl" <<'EOF'
module AjtCacheFixture
using Parsers
f(s) = Parsers.parse(Int, s)
end
EOF

cat > "$WORK/store_server.py" <<'PYEOF'
import os, sys
from http.server import HTTPServer, BaseHTTPRequestHandler
ROOT, PORT, MODE = sys.argv[1], int(sys.argv[2]), sys.argv[3]
TOKEN = sys.argv[4] if len(sys.argv) > 4 else None
class H(BaseHTTPRequestHandler):
    def _p(self):
        p = self.path.split("?")[0].lstrip("/")
        return None if ".." in p else os.path.join(ROOT, p)
    def _deny(self, code):
        self.send_response(code); self.send_header("Content-Length","0"); self.end_headers()
    def do_GET(self):
        # In gated mode ANY Authorization on a read is a hard 403: the read
        # path must never carry the write credential, and a 403 here turns
        # that leak into a visible import failure instead of a silent pass.
        if MODE == "gated" and self.headers.get("Authorization"):
            self._deny(403); return
        p = self._p()
        if MODE == "empty" or not p or not os.path.isfile(p):
            self._deny(404); return
        b = open(p,"rb").read()
        self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_PUT(self):
        p = self._p()
        n = int(self.headers.get("Content-Length","0")); body = self.rfile.read(n)
        if MODE == "gated" and self.headers.get("Authorization") != "Bearer " + (TOKEN or ""):
            self._deny(403); return
        if MODE == "empty":
            self._deny(201); return
        os.makedirs(os.path.dirname(p), exist_ok=True); open(p,"wb").write(body)
        self.send_response(201); self.send_header("Content-Length","0"); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

# A port nobody else is on. 0 would be cleaner but the child has to tell us.
PORT=8${RANDOM:0:3}
[ "$PORT" -lt 8100 ] && PORT=8177
python3 "$WORK/store_server.py" "$WORK/store" "$PORT" real >"$WORK/store.log" 2>&1 &
SRV_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do
  curl -s -o /dev/null "$BASE/keys/probe.json" && break
  sleep 0.1
done
curl -s -o /dev/null -w '%{http_code}' "$BASE/keys/probe.json" | grep -q 404 \
  && ok "the store answers (404 on an unknown key, which is a MISS not an error)" \
  || bad "the store did not come up on $BASE"

for d in a b; do
  mkdir -p "$WORK/depot-$d"
  env JULIA_DEPOT_PATH="$WORK/depot-$d" JULIA_PKG_PRECOMPILE_AUTO=0 \
    julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
    >"$WORK/inst-$d.log" 2>&1 || { echo "ERROR: could not instantiate depot-$d" >&2; exit 2; }
done
ok "two depots instantiated, sharing nothing"
# Non-vacuity: depot B must have NOTHING compiled, or section 2 proves nothing.
check "depot B starts with no cache entries for the fixture" "0" \
  "$(find "$WORK/depot-b/compiled" -path '*Parsers*' -name '*.ji' 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
echo
echo "==> 1. publish, from depot A"
"$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-a" "$ENV_DIR" \
  >"$WORK/pub.records" 2>"$WORK/pub.err"
check "ajt precompile exited cleanly" "0" "$?"

read -r P_HIT P_MISS P_IMP P_PUB P_ERR <<EOF
$(awk -F'\t' '$1=="cache" {print $2, $3, $4, $5, $6}' "$WORK/pub.records")
EOF
check "nothing was imported (the store was empty)" "0" "${P_IMP:-x}"
check "no store errors" "0" "${P_ERR:-x}"
[ "${P_PUB:-0}" -gt 0 ] && ok "$P_PUB entries published" || bad "nothing was published"
check "every miss was a package it then published" "${P_MISS:-x}" "${P_PUB:-y}"

OBJ_N="$(find "$WORK/store/objects" -name '*.tar.zst' 2>/dev/null | wc -l)"
KEY_N="$(find "$WORK/store/keys" -name '*.json' 2>/dev/null | wc -l)"
check "the store holds one object per published entry" "${P_PUB:-x}" "$OBJ_N"
check "...and one key pointing at each" "${P_PUB:-x}" "$KEY_N"
# The pointer must name an object that is actually there, or every import is a
# fetch of nothing. This is the ordering putObject-before-putPointer exists for.
DANGLING=0
for k in "$WORK"/store/keys/*.json; do
  [ -e "$k" ] || continue
  o="$(sed -n 's/.*"object":"\([0-9a-f]*\)".*/\1/p' "$k")"
  [ -f "$WORK/store/objects/$o.tar.zst" ] || DANGLING=$((DANGLING+1))
done
check "no key points at an object the store does not have" "0" "$DANGLING"

# ---------------------------------------------------------------------------
echo
echo "==> 2. import, into depot B"
"$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-b" "$ENV_DIR" \
  >"$WORK/imp.records" 2>"$WORK/imp.err"
check "ajt precompile exited cleanly" "0" "$?"

read -r I_HIT I_MISS I_IMP I_PUB I_ERR <<EOF
$(awk -F'\t' '$1=="cache" {print $2, $3, $4, $5, $6}' "$WORK/imp.records")
EOF
check "every published entry was a hit" "${P_PUB:-x}" "${I_HIT:-y}"
check "...and every hit was imported" "${I_HIT:-x}" "${I_IMP:-y}"
check "no store errors" "0" "${I_ERR:-x}"

# THE distinction. `imported` and `compiled` leave the same depot behind, so a
# run that fetched the entry and then compiled it anyway would satisfy every
# other check in this file.
IMPORTED="$(awk -F'\t' '$1=="package" && $2=="imported" {print $3}' "$WORK/imp.records" | sort | tr '\n' ' ')"
IMP_N="$(awk -F'\t' '$1=="package" && $2=="imported"' "$WORK/imp.records" | wc -l)"
check "the same packages are reported imported, not compiled" "${I_IMP:-x}" "$IMP_N"
[ "$IMP_N" -gt 0 ] && ok "imported: $IMPORTED"
for p in $IMPORTED; do
  if awk -F'\t' -v n="$p" '$1=="package" && $3==n && $2=="compiled"' "$WORK/imp.records" | grep -q .; then
    bad "$p is reported both imported and compiled"
  fi
done
ok "no package was both imported and compiled"

# ---------------------------------------------------------------------------
echo
echo "==> 3. the external gate: stock Julia against the imported depot"
LOADED="$(env JULIA_DEPOT_PATH="$WORK/depot-b" julia --startup-file=no --project="$ENV_DIR" \
  -e 'using AjtCacheFixture; print(AjtCacheFixture.f("41"))' 2>"$WORK/load.err")"
check "the package loads, and its code runs" "41" "${LOADED:-}"
[ "${LOADED:-}" = "41" ] || tail -10 "$WORK/load.err" | sed 's/^/       /'

BEFORE="$(find "$WORK/depot-b/compiled" -name '*.ji' 2>/dev/null | wc -l)"
env JULIA_DEPOT_PATH="$WORK/depot-b" julia --startup-file=no --project="$ENV_DIR" \
  -e 'using Pkg; Pkg.precompile()' >"$WORK/pkgpre.log" 2>&1
check "Pkg.precompile() succeeds against it" "0" "$?"
AFTER="$(find "$WORK/depot-b/compiled" -name '*.ji' 2>/dev/null | wc -l)"
check "...and rebuilt NOTHING (an entry Julia rejected would be rebuilt here)" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
echo
echo "==> 4. the cache is an optimisation, so neither failure may break a build"

# A store that answers 404 to everything: every package must simply compile.
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
python3 "$WORK/store_server.py" "$WORK/store" "$PORT" empty >>"$WORK/store.log" 2>&1 &
SRV_PID=$!
sleep 0.5
mkdir -p "$WORK/depot-c"
env JULIA_DEPOT_PATH="$WORK/depot-c" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
"$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-c" "$ENV_DIR" \
  >"$WORK/miss.records" 2>"$WORK/miss.err"
check "a store that has nothing still leaves a working run" "0" "$?"
check "nothing was imported" "0" \
  "$(awk -F'\t' '$1=="cache" {print $4}' "$WORK/miss.records")"
check "and nothing failed" "0" \
  "$(awk -F'\t' '$1=="summary" {print $7}' "$WORK/miss.records")"
MISSLOAD="$(env JULIA_DEPOT_PATH="$WORK/depot-c" julia --startup-file=no --project="$ENV_DIR" \
  -e 'using AjtCacheFixture; print("ok")' 2>/dev/null)"
check "the depot it left loads" "ok" "${MISSLOAD:-}"

# A store that is not listening at all.
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
mkdir -p "$WORK/depot-d"
env JULIA_DEPOT_PATH="$WORK/depot-d" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
"$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-d" "$ENV_DIR" \
  >"$WORK/down.records" 2>"$WORK/down.err"
check "an unreachable store still leaves a working run" "0" "$?"
check "and nothing failed" "0" \
  "$(awk -F'\t' '$1=="summary" {print $7}' "$WORK/down.records")"
DOWNERR="$(awk -F'\t' '$1=="cache" {print $6}' "$WORK/down.records")"
[ "${DOWNERR:-0}" -gt 0 ] \
  && ok "the outage is COUNTED ($DOWNERR errors), not silently swallowed" \
  || bad "an unreachable store produced no error count -- a broken cache and a cold one look the same"
DOWNLOAD="$(env JULIA_DEPOT_PATH="$WORK/depot-d" julia --startup-file=no --project="$ENV_DIR" \
  -e 'using AjtCacheFixture; print("ok")' 2>/dev/null)"
check "the depot it left loads" "ok" "${DOWNLOAD:-}"

# ---------------------------------------------------------------------------
echo
echo "==> 5. the token: a store whose write path is gated"

mkdir -p "$WORK/store2"
python3 "$WORK/store_server.py" "$WORK/store2" "$PORT" gated s3cret >>"$WORK/store.log" 2>&1 &
SRV_PID=$!
sleep 0.5

# 5a. No credential: the publish is refused by the store, and that refusal
# must be an ERROR COUNT on a run that still exits 0 with nothing failed --
# the same "the cache may not break a build" rule section 4 established,
# now for the write half.
mkdir -p "$WORK/depot-e"
env JULIA_DEPOT_PATH="$WORK/depot-e" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
"$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-e" "$ENV_DIR" \
  >"$WORK/notok.records" 2>"$WORK/notok.err"
check "publishing without a token still leaves a working run" "0" "$?"
check "and nothing failed" "0" \
  "$(awk -F'\t' '$1=="summary" {print $7}' "$WORK/notok.records")"
NOTOK_ERR="$(awk -F'\t' '$1=="cache" {print $6}' "$WORK/notok.records")"
[ "${NOTOK_ERR:-0}" -gt 0 ] \
  && ok "the refusals are COUNTED ($NOTOK_ERR errors), not silently swallowed" \
  || bad "a 403 on publish produced no error count -- a gated store and a cold one look the same"
check "the gated store took nothing" "0" \
  "$(find "$WORK/store2/objects" -name '*.tar.zst' 2>/dev/null | wc -l)"

# 5b. $AJT_CACHE_TOKEN: the same publish lands. The env-var spelling is the
# one a CI job or image build would use, so it is the one exercised here.
mkdir -p "$WORK/depot-f"
env JULIA_DEPOT_PATH="$WORK/depot-f" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
env AJT_CACHE_TOKEN=s3cret \
  "$AJT" precompile --cache-url "$BASE" --depot "$WORK/depot-f" "$ENV_DIR" \
  >"$WORK/tok.records" 2>"$WORK/tok.err"
check "publishing with \$AJT_CACHE_TOKEN exits cleanly" "0" "$?"
read -r T_HIT T_MISS T_IMP T_PUB T_ERR <<EOF
$(awk -F'\t' '$1=="cache" {print $2, $3, $4, $5, $6}' "$WORK/tok.records")
EOF
[ "${T_PUB:-0}" -gt 0 ] && ok "$T_PUB entries published through the gate" \
  || bad "nothing was published with the token set"
check "no store errors with the token" "0" "${T_ERR:-x}"
check "the store holds one object per published entry" "${T_PUB:-x}" \
  "$(find "$WORK/store2/objects" -name '*.tar.zst' 2>/dev/null | wc -l)"

# 5c. The read path must NOT carry the credential. The gated server answers
# 403 to any GET with an Authorization header, so if `--cache-token` leaked
# onto lookups this import would come back with errors instead of hits.
mkdir -p "$WORK/depot-g"
env JULIA_DEPOT_PATH="$WORK/depot-g" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
"$AJT" precompile --cache-url "$BASE" --cache-token s3cret --depot "$WORK/depot-g" "$ENV_DIR" \
  >"$WORK/tokimp.records" 2>"$WORK/tokimp.err"
check "importing with --cache-token exits cleanly" "0" "$?"
read -r G_HIT G_MISS G_IMP G_PUB G_ERR <<EOF
$(awk -F'\t' '$1=="cache" {print $2, $3, $4, $5, $6}' "$WORK/tokimp.records")
EOF
check "every published entry was a hit (a token on GET would have 403'd)" \
  "${T_PUB:-x}" "${G_HIT:-y}"
check "...and every hit was imported" "${G_HIT:-x}" "${G_IMP:-y}"
check "no store errors on the tokened import" "0" "${G_ERR:-x}"

kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

echo
echo "======================================================================"
echo "cache wiring: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
