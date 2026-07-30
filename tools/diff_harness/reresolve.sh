#!/usr/bin/env bash
# Differential gate for a FREE re-resolve — `ajt resolve --preserve none`
# against `Pkg.update()`.
#
# Every other resolve gate holds versions fixed. `PRESERVE_ALL` pins each
# manifest entry to the version already recorded, which collapses the solve to
# unit propagation: it proves the encoding is right and says almost nothing
# about how versions get CHOSEN. This gate removes the pins.
#
# That is where PubGrub and Pkg could legitimately disagree without either
# being wrong. PubGrub decides fewest-candidates-first and takes the highest
# version in the remaining set; Pkg's MaxSum optimises a global VersionWeight.
# Both produce valid solutions and they need not be the same solution. The plan
# budgeted a `--maximize` post-pass for exactly this. So the honest question is
# not "does it work" but "how far apart are they on a real environment", and
# the only way to find out is to run both.
#
#   1. Copy the environment twice.
#   2. `Pkg.update(; update_registry = false)` on one. The kwarg is not
#      optional: `Pkg.update()` refreshes the registry by default, and then the
#      two sides would be choosing from different universes and any difference
#      would be uninterpretable.
#   3. `ajt resolve --preserve none --write` on the other.
#   4. The two Manifest.toml files must be byte-identical, and stock
#      `Pkg.resolve()` must then leave Ajt's alone.
#
# VACUITY. If the environment is already at its newest compatible versions,
# both sides do nothing and the comparison proves nothing. The gate therefore
# counts how many versions the update actually moved and says so out loud; a
# run where nothing moved is reported as inconclusive rather than green.
#
# Needs the network and a depot that already holds a General registry. Writes
# only into a mktemp depot stacked in FRONT of the shared one, so nothing is
# ever installed into the shared depot.
#
# Usage: reresolve.sh [--keep] [--env DIR]
set -uo pipefail

# `ajt add`/`up`/`pin`/`free`/`instantiate` auto-precompile now, exactly as the
# Pkg verbs they mirror do (`Pkg.jl:65`, `Operations.jl:1828`, `API.jl:170`,
# `API.jl:1398`) -- and this gate is not about that. The Pkg invocations below
# already set this variable per call, for the same reason; setting it once here
# gives BOTH sides the same veto, so the comparison stays a comparison of what
# was installed rather than of how long julia took to compile it.
# `tools/diff_harness/autoprecompile.sh` is the gate that asserts the pass.
export JULIA_PKG_PRECOMPILE_AUTO=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"

KEEP=0
ENV_SRC="$REPO_ROOT/Open-Reality"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --env) ENV_SRC="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

if [ ! -f "$ENV_SRC/Project.toml" ] || [ ! -f "$ENV_SRC/Manifest.toml" ]; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: no environment at $ENV_SRC"
  echo "# Pass --env DIR to point at a Project.toml/Manifest.toml pair. This    #"
  echo "# gate needs a manifest that is BEHIND the registry, so a re-resolve    #"
  echo "# has something to move.                                               #"
  echo "########################################################################"
  exit 0
fi

# The shared depot supplies the registry and every already-installed package.
SHARED="${JULIA_DEPOT_PATH:-}"
SHARED="${SHARED%%:*}"
[ -n "$SHARED" ] || SHARED="$HOME/.julia"
if [ ! -f "$SHARED/registries/General.tar.gz" ] && [ ! -d "$SHARED/registries/General" ]; then
  echo "ERROR: no General registry in $SHARED — run 'ajt registry add' first" >&2
  exit 2
fi

WORK="$(mktemp -d -t ajt-reresolve-XXXXXX)"
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

if ! "$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: no network. A free re-resolve moves packages to versions     #"
  echo "# that are not installed yet, so Pkg has to download them.              #"
  echo "########################################################################"
  exit 0
fi

DEPOT="$WORK/depot"
mkdir -p "$DEPOT" "$WORK/pkg" "$WORK/ajt"
cp "$ENV_SRC/Project.toml" "$ENV_SRC/Manifest.toml" "$WORK/pkg/"
cp "$ENV_SRC/Project.toml" "$ENV_SRC/Manifest.toml" "$WORK/ajt/"
JULIA_PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"

echo "==> Pkg.update (registry pinned to the installed one)"
if ! env JULIA_DEPOT_PATH="$DEPOT:$SHARED" JULIA_PKG_PRECOMPILE_AUTO=0 ENVDIR="$WORK/pkg" \
     julia --startup-file=no -e \
     'using Pkg; Pkg.activate(ENV["ENVDIR"]); Pkg.update(; update_registry = false)' \
     >"$WORK/update.log" 2>&1; then
  bad "Pkg.update failed" "$(tail -3 "$WORK/update.log" | tr '\n' '|')"
  echo; printf 're-resolve: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

MOVED="$(diff <(grep '^version = ' "$ENV_SRC/Manifest.toml") \
              <(grep '^version = ' "$WORK/pkg/Manifest.toml") | grep -c '^<' || true)"
echo "==> Pkg moved $MOVED version(s)"

echo "==> ajt resolve --preserve none"
# The shared depot FIRST, because ajt reads the registry from the first entry
# of the stack; the temp depot is where Pkg just installed the upgraded
# sources, and the fixups pass has to be able to find them there.
if ! env JULIA_DEPOT_PATH="$SHARED:$DEPOT" "$AJT" resolve \
     --julia-prefix "$JULIA_PREFIX" --preserve none --write --quiet "$WORK/ajt" \
     >"$WORK/ajt.out" 2>"$WORK/ajt.err"; then
  bad "ajt resolve --preserve none failed" "$(tail -5 "$WORK/ajt.err" | tr '\n' '|')"
  echo; printf 're-resolve: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
grep -q '^no-source' "$WORK/ajt.out" && \
  bad "entries with no source on disk — their weakdeps/extensions are missing" \
      "$(grep '^no-source' "$WORK/ajt.out" | head -5 | cut -f2 | tr '\n' ' ')"

# GATE 1: the same manifest, byte for byte.
if cmp -s "$WORK/pkg/Manifest.toml" "$WORK/ajt/Manifest.toml"; then
  ok "free re-resolve is byte-identical to Pkg.update ($MOVED version(s) moved)"
else
  bad "free re-resolve differs from Pkg.update" \
      "$(diff "$WORK/pkg/Manifest.toml" "$WORK/ajt/Manifest.toml" | head -8 | tr '\n' '|')"
fi

# GATE 2: and Pkg has nothing to say about the result.
if env JULIA_DEPOT_PATH="$DEPOT:$SHARED" JULIA_PKG_PRECOMPILE_AUTO=0 ENVDIR="$WORK/ajt" \
   julia --startup-file=no -e 'using Pkg; Pkg.activate(ENV["ENVDIR"]); Pkg.resolve()' \
   >"$WORK/resolve.log" 2>&1; then
  if cmp -s "$WORK/pkg/Manifest.toml" "$WORK/ajt/Manifest.toml"; then
    ok "stock Pkg.resolve() left the re-resolved manifest untouched"
  else
    bad "Pkg.resolve() rewrote the manifest ajt wrote" \
        "$(diff "$WORK/pkg/Manifest.toml" "$WORK/ajt/Manifest.toml" | head -6 | tr '\n' '|')"
  fi
else
  bad "Pkg.resolve() failed on the re-resolved manifest" \
      "$(tail -3 "$WORK/resolve.log" | tr '\n' '|')"
fi

# GATE 3: `ajt up` is the actual counterpart of `Pkg.update()`, and it is a
# different code path from `--preserve none`: `up` puts a per-package range on
# every direct dep and resolves the REST at PRESERVE_DIRECT, where
# `--preserve none` simply drops every requirement. The two agreeing with each
# other proves nothing; each has to agree with Pkg.
#
# This is also the gate that pinned down the JLL fixup. Applied to every _jll
# whose triple was unchanged, it held one at its recorded build where Pkg moved
# it to a newer one — because `jll_fix` is built only from packages that
# entered the solve with an EXACT version (`Operations.jl:511-516`), and under
# `up` those are precisely the ones NOT being upgraded.
for level in major minor patch; do
  U="$WORK/up-$level"
  mkdir -p "$U"
  cp "$ENV_SRC/Project.toml" "$ENV_SRC/Manifest.toml" "$U/"
  if ! env JULIA_DEPOT_PATH="$SHARED:$DEPOT" "$AJT" up \
       --julia-prefix "$JULIA_PREFIX" --project "$U" "--$level" --quiet \
       >"$WORK/up-$level.ajt.out" 2>"$WORK/up-$level.ajt.err"; then
    bad "ajt up --$level failed" "$(tail -5 "$WORK/up-$level.ajt.err" | tr '\n' '|')"
    continue
  fi
  if [ "$level" = major ]; then
    # Only --major is comparable to `Pkg.update()`; the other two are run to
    # prove they differ from it, below.
    if cmp -s "$WORK/pkg/Manifest.toml" "$U/Manifest.toml"; then
      ok "ajt up --major is byte-identical to Pkg.update"
    else
      bad "ajt up --major differs from Pkg.update" \
          "$(diff "$WORK/pkg/Manifest.toml" "$U/Manifest.toml" | head -8 | tr '\n' '|')"
    fi
  fi
done
# An update moves versions, not requirements: `Pkg.update()` never edits
# Project.toml, and neither may `ajt up`.
if cmp -s "$ENV_SRC/Project.toml" "$WORK/up-major/Project.toml"; then
  ok "ajt up left Project.toml alone"
else
  bad "ajt up rewrote Project.toml, which an update must not do" \
      "$(diff "$ENV_SRC/Project.toml" "$WORK/up-major/Project.toml" | head -4 | tr '\n' '|')"
fi

# The levels must not all be the same run. If `--patch` moves as much as
# `--major`, the level is being ignored and the gate above would still pass.
if cmp -s "$WORK/up-major/Manifest.toml" "$WORK/up-patch/Manifest.toml"; then
  bad "up --patch produced exactly what up --major did" \
      "either the level is ignored, or nothing in this environment has a newer minor"
else
  ok "the upgrade levels produce different manifests"
fi

echo
echo "======================================================================"
if [ "$MOVED" = "0" ]; then
  echo "INCONCLUSIVE: the update moved nothing, so both sides did nothing and"
  echo "the comparison above proves nothing about version CHOICE. Point --env"
  echo "at an environment whose manifest is behind the registry."
fi
printf 're-resolve: %d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || exit 1
exit 0
