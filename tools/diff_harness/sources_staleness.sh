#!/usr/bin/env bash
# Differential gate for `ajt verify`'s [sources] currency check
# (src/ops/verify.zig step 3b) against `Pkg.is_manifest_current`.
#
# This gate is unusual: it exists to prove a DISAGREEMENT, and to bound it.
#
# `workspace_resolve_hash` (Types.jl:645-666) digests direct deps, weakdeps and
# compat. It does not digest `[sources]`. So editing `[sources]` — adding an
# entry, moving a `rev` — leaves `project_hash` byte-identical, Pkg goes on
# reporting the manifest current, and the source is never applied to anything.
# That is JuliaLang/Pkg.jl#4157, with #4351 as its monorepo-scale consequence.
#
# Ajt inherits the hash verbatim, on purpose: widening it would make every
# manifest ajt writes look stale to stock Pkg (fallback_gates.sh gate 2
# forbids exactly that) and every manifest already on disk look stale to ajt.
# The stricter answer lives in `verify` instead. This gate pins both halves:
#
#   1. THE PKG BUG IS REAL. With a `[sources]` url added and nothing else
#      changed, `Pkg.Operations.is_manifest_current` must still answer TRUE.
#      Without this case the rest proves nothing — a gate that only checked
#      ajt's answer would pass just as happily if Pkg had never had the bug,
#      and would then be guarding a divergence that no longer exists.
#
#   2. AJT NOTICES. `ajt verify` must exit 2 (run resolve) on that same
#      environment, and name the entry.
#
#   3. THE HASH DID NOT MOVE. The `project_hash` ajt computes over the edited
#      project must be byte-identical to the one Pkg computes — proving the
#      divergence is in the CHECK and not in the digest, which is the whole
#      design. Compared against the hash already recorded in the manifest,
#      which Pkg itself wrote.
#
#   4. AGREEMENT WHEN APPLIED. With the manifest's repo-url/repo-rev matching
#      the source, ajt verify must go back to exit 0. A check that fired
#      unconditionally would pass cases 1-3 and be useless.
#
#   5. NO FALSE POSITIVE ON A PATH SOURCE. `load_all_deps` overlays a
#      `[sources]` PATH onto the entry at load time, so a manifest that records
#      only a tree hash beside a project that pins a path is a correct, working
#      Pkg environment. ajt must NOT call it stale. This is the case that
#      bounds the divergence, and it is the one an over-eager implementation
#      gets wrong.
#
# Usage: tools/diff_harness/sources_staleness.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-sources-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
assert() { local label="$1" note="$2"; shift 2; if "$@"; then ok "$label"; else bad "$label" "$note"; fi; }

DEPOT="$WORK/depot"
PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"
mkdir -p "$DEPOT"

# An environment with ONE stdlib dependency. A stdlib needs no depot content, so
# `verify` can reach a verdict without installing anything -- which keeps this
# gate about the manifest and not about the network.
UUID_LA="37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

make_env() { # <dir> <sources-block> <repo-lines>
  local dir="$1" sources="$2" repo="$3"
  mkdir -p "$dir"
  {
    echo 'name = "Fixture"'
    echo 'uuid = "11111111-2222-3333-4444-555555555555"'
    echo 'version = "0.1.0"'
    echo
    echo '[deps]'
    echo "LinearAlgebra = \"$UUID_LA\""
    if [ -n "$sources" ]; then echo; echo '[sources]'; echo "$sources"; fi
  } >"$dir/Project.toml"

  # `project_hash` computed by JULIA, not by ajt -- the oracle has to be the
  # thing being agreed with, or case 3 is circular.
  local hash
  hash="$(julia --startup-file=no -e '
      using Pkg
      env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
      print(Pkg.Types.workspace_resolve_hash(env))
  ' "$dir")"

  {
    echo 'julia_version = "1.12.6"'
    echo 'manifest_format = "2.0"'
    echo "project_hash = \"$hash\""
    echo
    echo '[[deps.LinearAlgebra]]'
    echo "uuid = \"$UUID_LA\""
    [ -n "$repo" ] && echo "$repo"
  } >"$dir/Manifest.toml"
  echo "$hash"
}

pkg_current() { # <dir> -> "true"/"false"/"nothing"
  julia --startup-file=no -e '
      using Pkg
      env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
      print(something(Pkg.Operations.is_manifest_current(env), "nothing"))
  ' "$1" 2>/dev/null
}

verify_code() { # <dir> -> exit status
  "$AJT" verify "$1" --depot "$DEPOT" --julia-prefix "$PREFIX" >"$WORK/verify.out" 2>&1
  echo $?
}

URL="https://github.com/JuliaLinearAlgebra/LinearAlgebra.jl"

# ---------------------------------------------------------------------------
# Baseline: no [sources] at all. Both tools must be happy, or nothing below
# distinguishes "the source is stale" from "this fixture never verified".
# ---------------------------------------------------------------------------
echo
echo "0. baseline (no [sources])"
BASE="$WORK/base"
make_env "$BASE" "" "" >/dev/null
assert "baseline-pkg-current" "Pkg does not consider the fixture current" \
  test "$(pkg_current "$BASE")" = "true"
code=$(verify_code "$BASE")
[ "$code" = 0 ] && ok "baseline-ajt-ok" || bad "baseline-ajt-ok" "exit $code: $(head -3 "$WORK/verify.out")"

# ---------------------------------------------------------------------------
# 1-3. A [sources] url the manifest never applied
# ---------------------------------------------------------------------------
echo
echo "1-3. an unapplied [sources] url"
STALE="$WORK/stale"
HASH_STALE=$(make_env "$STALE" "LinearAlgebra = {url = \"$URL\", rev = \"master\"}" "")

# 1. The Pkg bug is real: adding [sources] did not move the hash.
cur=$(pkg_current "$STALE")
[ "$cur" = "true" ] && ok "pkg-still-says-current (#4157)" || \
  bad "pkg-still-says-current (#4157)" "is_manifest_current said '$cur' — the bug may be fixed upstream; revisit verify.zig step 3b"

# 3. And ajt's digest agrees with Julia's, byte for byte.
HASH_BASE=$(julia --startup-file=no -e '
    using Pkg
    env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
    print(Pkg.Types.workspace_resolve_hash(env))
' "$BASE")
[ "$HASH_STALE" = "$HASH_BASE" ] && ok "hash-unmoved-by-sources" || \
  bad "hash-unmoved-by-sources" "adding [sources] changed project_hash: $HASH_BASE -> $HASH_STALE"

AJT_HASH=$("$AJT" project-hash "$STALE/Project.toml" 2>/dev/null | awk '{print $1}')
[ "$AJT_HASH" = "$HASH_STALE" ] && ok "ajt-hash-matches-julia" || \
  bad "ajt-hash-matches-julia" "julia $HASH_STALE vs ajt $AJT_HASH"

# 2. ajt notices anyway.
code=$(verify_code "$STALE")
[ "$code" = 2 ] && ok "ajt-exit-2-run-resolve" || \
  bad "ajt-exit-2-run-resolve" "exit $code: $(head -5 "$WORK/verify.out")"
if grep -q 'LinearAlgebra' "$WORK/verify.out"; then ok "ajt-names-the-entry"; else
  bad "ajt-names-the-entry" "$(head -5 "$WORK/verify.out")"; fi
if grep -qi '4157' "$WORK/verify.out"; then ok "ajt-cites-the-issue"; else
  bad "ajt-cites-the-issue" "$(head -5 "$WORK/verify.out")"; fi

# ---------------------------------------------------------------------------
# 4. Applied and in agreement
# ---------------------------------------------------------------------------
echo
echo "4. the same source, applied"
APPLIED="$WORK/applied"
make_env "$APPLIED" "LinearAlgebra = {url = \"$URL\", rev = \"master\"}" \
  "$(printf 'repo-url = "%s"\nrepo-rev = "master"' "$URL")" >/dev/null
code=$(verify_code "$APPLIED")
[ "$code" = 0 ] && ok "applied-ajt-ok" || \
  bad "applied-ajt-ok" "exit $code: $(head -5 "$WORK/verify.out")"

# And a moved rev is stale again -- #4351 in one environment.
MOVED="$WORK/moved"
make_env "$MOVED" "LinearAlgebra = {url = \"$URL\", rev = \"v1.2.3\"}" \
  "$(printf 'repo-url = "%s"\nrepo-rev = "master"' "$URL")" >/dev/null
code=$(verify_code "$MOVED")
[ "$code" = 2 ] && ok "moved-rev-is-stale" || \
  bad "moved-rev-is-stale" "exit $code: $(head -5 "$WORK/verify.out")"

# ---------------------------------------------------------------------------
# 5. A path source must NOT be flagged
# ---------------------------------------------------------------------------
echo
echo "5. a [sources] path is not a staleness"
PATHENV="$WORK/pathenv"
mkdir -p "$PATHENV/dev/LinearAlgebra/src"
echo 'module LinearAlgebra end' >"$PATHENV/dev/LinearAlgebra/src/LinearAlgebra.jl"
make_env "$PATHENV" 'LinearAlgebra = {path = "dev/LinearAlgebra"}' "" >/dev/null
# Pkg is happy: `load_all_deps` overlays the path every time it loads the env.
assert "path-pkg-current" "Pkg does not consider a path-source env current" \
  test "$(pkg_current "$PATHENV")" = "true"
code=$(verify_code "$PATHENV")
[ "$code" = 0 ] && ok "path-ajt-ok (no false positive)" || \
  bad "path-ajt-ok (no false positive)" "exit $code: $(head -5 "$WORK/verify.out")"

# ---------------------------------------------------------------------------

echo
echo "  agreements : $PASS"
echo "  failures   : $FAIL"

if [ "$FAIL" -gt 0 ]; then
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — the [sources] divergence is exactly where it was designed to be ($PASS assertions)"
