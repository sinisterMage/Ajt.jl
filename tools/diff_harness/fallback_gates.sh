#!/usr/bin/env bash
# THE THREE FALLBACK GATES — the checks that make shipping Ajt safe.
#
# Every other harness in this directory asks "does Ajt agree with Julia about
# some value?". These three ask the only question that matters for deployment:
# **after Ajt has touched an environment or a depot, does stock Julia still
# agree there is nothing left to do?** If stock Pkg finds no work, the artifact
# Ajt produced is compatible by definition — and if it ever stops finding no
# work, the fallback is to run Pkg, which is exactly what these gates protect.
#
#   GATE 1  MANIFEST BYTE-STABILITY.  `ajt instantiate --frozen` must leave
#           Project.toml and Manifest.toml byte-identical to the committed
#           files. This is the gate against silent churn: an emitter that
#           reorders a key or drops a field would still load fine and would
#           still pass gates 2 and 3, while rewriting the manifest on every
#           CI run and diffing against itself forever.
#
#   GATE 2  AJT -> PKG INTEROP (the strong one).  Into a fresh depot,
#           `ajt instantiate --frozen`; then stock `Pkg.instantiate()` must do
#           NO work and `Pkg.Operations.is_instantiated` must say true.
#
#   GATE 3  PKG -> AJT INTEROP.  The inverse. A depot built by stock Pkg must
#           make `ajt verify --frozen` exit 0, having actually checked the
#           entries rather than trivially passing, and having written nothing.
#
# ---------------------------------------------------------------------------
# TWO PLACES THIS DELIBERATELY DIVERGES FROM THE PLAN, BOTH FOR HONESTY
# ---------------------------------------------------------------------------
#
# 1. The plan spells gate 1 `git diff --exit-code Open-Reality/Manifest.toml`.
#    Taken literally that means instantiating INTO the repo working tree, so
#    the harness could not be run on a dirty branch and a failure would leave
#    the tree modified. This runs against a COPY and `cmp`s the result against
#    the committed bytes — the same assertion without the side effect — and
#    then separately asserts `git status -- Open-Reality` is unchanged, which
#    is the part `git diff` was really standing in for.
#
# 2. The plan's gate 2 says "zero work and zero new files under `compiled/`".
#    The second half is now ASSERTED, under --precompile, and it took two
#    things to get there.
#
#    It could not hold while `ajt instantiate` was the only step: Ajt installs
#    SOURCES, and `compiled/` is written by Julia and never by Ajt — that is
#    the compatibility contract, not a gap. So the gate runs `ajt precompile`
#    first, and the claim is about the pair.
#
#    What made the remaining delta stubborn was EXTENSIONS. An environment can
#    have every package compiled and still be unfinished: a package extension
#    is a module under its parent's `ext/` with a cache entry of its own, and
#    ~17 of them on the engine were left for `Pkg.precompile()` to build. Once
#    they became nodes the delta went to zero, which is why this gate now
#    checks that at least one extension was compiled before it believes the
#    zero — a run that skipped them all would report the same clean number for
#    the wrong reason.
#
# ---------------------------------------------------------------------------
# NOTHING HERE WRITES TO THE USER'S REAL DEPOT OR TO THE REPO.
# ---------------------------------------------------------------------------
# Every environment is a copy under $WORK; every depot written to is under
# $WORK; every julia process gets JULIA_DEPOT_PATH pointed there. The ambient
# depot is READ in exactly one place — gate 1's fast path stacks it SECOND
# behind a scratch depot, so lookups hit it and every write lands in scratch —
# and the harness asserts its top level is unchanged either side of the run.
#
# Usage: fallback_gates.sh [--quick] [--precompile] [--keep]
#   --quick       gate 1 only (no network, seconds)
#   --precompile  add gate 2's M5 acceptance criterion (MINUTES)
#   --keep        leave $WORK behind
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
ENGINE="$REPO_ROOT/Open-Reality"

KEEP=0
QUICK=0
DO_PRECOMPILE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --quick) QUICK=1; shift ;;
    --precompile) DO_PRECOMPILE=1; shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 not on PATH (gate 1 perturbation)" >&2; exit 2; }
[ -f "$ENGINE/Manifest.toml" ] || { echo "ERROR: no $ENGINE/Manifest.toml" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-fallback-XXXXXX)"
# Installed packages are made read-only by `set_readonly`, exactly as Pkg makes
# them, so cleanup has to restore write bits first.
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
note() { printf '       %s\n' "$1"; }

snapshot() { find "$1" -printf '%p\t%T@\t%s\t%y\n' 2>/dev/null | sort; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# The baseline for "the repo is untouched". Comparing against empty would fail
# for anyone with an unrelated edit under Open-Reality/ already in flight.
git -C "$REPO_ROOT" status --porcelain -- Open-Reality > "$WORK/git.before" 2>/dev/null

AMBIENT="$(julia --startup-file=no -e 'print(first(Base.DEPOT_PATH))' 2>/dev/null)"
[ -n "$AMBIENT" ] && find "$AMBIENT" -maxdepth 1 -printf '%p\t%T@\n' 2>/dev/null | sort > "$WORK/ambient.before"

# A fresh copy of the environment. Never the repo's own.
mkenv() {
  local d="$WORK/$1"
  mkdir -p "$d"
  cp -a "$ENGINE/." "$d/" || { echo "ERROR: could not copy $ENGINE" >&2; exit 2; }
  cmp -s "$ENGINE/Manifest.toml" "$d/Manifest.toml" || { echo "ERROR: copy is not identical" >&2; exit 2; }
  printf '%s' "$d"
}

# ===========================================================================
# GATE 1 — manifest byte-stability
# ===========================================================================
# Takes the depot spec to instantiate against as $@ (repeated --depot flags),
# because it runs against the ambient depot when that already satisfies the
# environment (fast, offline) and against gate 2's freshly built depot when it
# does not (CI, where there is no ambient depot to borrow).
gate1() {
  local label="$1"; shift
  echo
  echo "==> GATE 1: manifest byte-stability  ($label)"
  local env_dir; env_dir="$(mkenv env-g1)"

  "$AJT" instantiate --frozen "$@" --registry-policy never "$env_dir" \
    >"$WORK/g1.out" 2>"$WORK/g1.err"
  local rc=$?
  check "ajt instantiate --frozen succeeds" "0" "$rc"
  [ $rc -eq 0 ] || { tail -15 "$WORK/g1.err" | sed 's/^/       /'; return; }

  # THE GATE.
  local f
  for f in Project.toml Manifest.toml; do
    if cmp -s "$ENGINE/$f" "$env_dir/$f"; then
      ok "$f is byte-identical to the committed file"
    else
      bad "$f CHANGED — ajt's writer diverges from the committed bytes" \
          "$(diff "$ENGINE/$f" "$env_dir/$f" | head -6 | tr '\n' '|')"
    fi
  done

  # NON-VACUITY, part 1. "Unchanged" is only meaningful if the fixups pass
  # actually ran and considered the manifest -- a pass that skipped it entirely
  # would leave the bytes alone too, and would be worthless.
  local mline; mline="$(grep -E '^manifest' "$WORK/g1.out" | head -1 | cut -f2)"
  check "the fixups pass ran and found nothing to change" "unchanged" "${mline:-<no manifest line>}"

  # NON-VACUITY, part 2 -- proving the gate can go red. Remove one
  # fixup-managed key, re-run, and require BOTH that ajt notices (writes the
  # manifest) AND that what it writes converges back on the committed bytes.
  # This is the check that would catch an emitter bug: a writer that round-trips
  # its own output but does not match Pkg's passes everything above and fails
  # here.
  cp "$env_dir/Manifest.toml" "$WORK/g1.pristine"
  python3 - "$env_dir/Manifest.toml" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
hits = [n for n, l in enumerate(lines) if l.startswith('weakdeps = [')]
if not hits:
    sys.exit("FIXTURE DRIFT: no top-level `weakdeps = [` line in the manifest")
del lines[max(hits)]
open(p, 'w').write('\n'.join(lines))
PY
  [ $? -eq 0 ] || { bad "could not perturb the manifest (fixture drift)"; return; }
  cmp -s "$WORK/g1.pristine" "$env_dir/Manifest.toml" && {
    bad "the perturbation did not change the file — the bite check is vacuous"; return; }

  "$AJT" instantiate --frozen "$@" --registry-policy never "$env_dir" \
    >"$WORK/g1b.out" 2>"$WORK/g1b.err"
  local mline2; mline2="$(grep -E '^manifest' "$WORK/g1b.out" | head -1 | cut -f2)"
  check "a removed weakdeps key makes the fixups pass write" "written" "${mline2:-<no manifest line>}"
  if cmp -s "$ENGINE/Manifest.toml" "$env_dir/Manifest.toml"; then
    ok "and it converges back to the committed bytes exactly"
  else
    bad "fixups repaired the manifest but not back to Pkg's bytes" \
        "$(diff "$ENGINE/Manifest.toml" "$env_dir/Manifest.toml" | head -6 | tr '\n' '|')"
  fi
}

# Can gate 1 use the fast path? Only if the ambient depot already satisfies the
# environment; otherwise there is nothing to read out of it and the run would
# turn into a full download.
GATE1_FAST=0
if [ -n "$AMBIENT" ] && "$AJT" verify --frozen --depot "$AMBIENT" "$ENGINE" >/dev/null 2>&1; then
  GATE1_FAST=1
fi

if [ $GATE1_FAST -eq 1 ]; then
  # Scratch depot FIRST so every write (usage logs above all) lands there; the
  # ambient depot second, read-only, supplying the installed packages.
  mkdir -p "$WORK/g1scratch"
  gate1 "reading the ambient depot, writing to scratch" \
        --depot "$WORK/g1scratch" --depot "$AMBIENT"
else
  echo
  echo "==> GATE 1: deferred — the ambient depot does not satisfy $ENGINE,"
  echo "    so it runs after gate 2 against the depot gate 2 builds."
fi

if [ $QUICK -eq 1 ]; then
  [ $GATE1_FAST -eq 1 ] || { echo; echo "ERROR: --quick needs a populated ambient depot for gate 1" >&2; FAIL=$((FAIL+1)); }
  echo
  echo "==> gates 2 and 3 SKIPPED (--quick)"
else

# ---------------------------------------------------------------------------
# Network probe. Gates 2 and 3 both download a registry, 161 package tarballs
# and 82 artifacts; without a network there is nothing to test.
# ---------------------------------------------------------------------------
if ! "$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
  echo
  echo "########################################################################"
  echo "# SKIPPED gates 2 and 3: no network (pkg.julialang.org unreachable).    #"
  echo "# Both build a real depot from scratch; there is no offline subset.     #"
  echo "########################################################################"
  [ $GATE1_FAST -eq 1 ] || { echo "# ...and gate 1 was deferred to gate 2, so NOTHING ran." >&2; FAIL=$((FAIL+1)); }
else

# ===========================================================================
# GATE 2 — Ajt -> Pkg interop (the strong one)
# ===========================================================================
echo
echo "==> GATE 2: Ajt -> Pkg — stock Pkg must find nothing to do"
ENV2="$(mkenv env-g2)"
DEPOT_AJT="$WORK/depot-ajt"
mkdir -p "$DEPOT_AJT"

T0=$(date +%s%N)
"$AJT" instantiate --frozen --depot "$DEPOT_AJT" --quiet "$ENV2" \
  >"$WORK/g2.inst.out" 2>"$WORK/g2.inst.err"
G2_RC=$?
T1=$(date +%s%N)
AJT_MS=$(( (T1 - T0) / 1000000 ))
check "ajt instantiate --frozen built the depot" "0" "$G2_RC"
[ $G2_RC -eq 0 ] || tail -15 "$WORK/g2.inst.err" | sed 's/^/       /'
note "ajt instantiate into an empty depot: $((AJT_MS/1000))s"

if [ $G2_RC -eq 0 ]; then
  # Gate 1 against this depot, if it could not use the ambient one.
  [ $GATE1_FAST -eq 1 ] || gate1 "against the depot gate 2 just built" --depot "$DEPOT_AJT"

  echo
  echo "  --- stock Pkg, against the depot ajt built ---"
  # PRECOMPILE_AUTO=0: a cold Pkg.instantiate() would also precompile 213
  # packages, which is minutes of work that says nothing about whether Pkg
  # wants to INSTALL anything, which is the question.
  env JULIA_DEPOT_PATH="$DEPOT_AJT" JULIA_PKG_PRECOMPILE_AUTO=0 \
    julia --startup-file=no --project="$ENV2" -e 'using Pkg; Pkg.instantiate()' \
    >"$WORK/g2.pkg.out" 2>&1
  PKG_RC=$?
  check "Pkg.instantiate() succeeds" "0" "$PKG_RC"
  [ $PKG_RC -eq 0 ] || tail -20 "$WORK/g2.pkg.out" | sed 's/^/       /'

  if grep -Eq '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/g2.pkg.out"; then
    bad "Pkg.instantiate() did work — ajt's depot was incomplete" \
        "$(grep -E '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/g2.pkg.out" | head -5 | tr '\n' '|')"
  else
    ok "Pkg.instantiate() installed, downloaded and updated NOTHING"
  fi

  # The predicate itself, which also covers artifacts (`check_artifacts_downloaded`,
  # Operations.jl:1083-1094) that `ajt verify` deliberately does not check.
  J_INST="$(env JULIA_DEPOT_PATH="$DEPOT_AJT" julia --startup-file=no -e '
    using Pkg
    print(Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' \
    "$ENV2" 2>"$WORK/g2.isinst.err")"
  check "Pkg.Operations.is_instantiated agrees (artifacts included)" "true" "${J_INST:-}"
  [ -n "${J_INST:-}" ] || tail -5 "$WORK/g2.isinst.err" | sed 's/^/       /'

  # Self-sufficiency: a pass above cannot have been borrowed from ~/.julia.
  check "DEPOT_PATH is the temp depot alone" "[\"$DEPOT_AJT\"]" \
    "$(env JULIA_DEPOT_PATH="$DEPOT_AJT" julia --startup-file=no -e 'print(DEPOT_PATH)')"

  # --- the precompile half: now an ASSERTION. See the header. ---
  echo
  if [ $DO_PRECOMPILE -eq 1 ]; then
    echo "  --- ajt precompile, then Pkg.precompile() must find NOTHING (minutes) ---"
    T0=$(date +%s%N)
    env JULIA_DEPOT_PATH="$DEPOT_AJT" \
      "$AJT" precompile --depot "$DEPOT_AJT" "$ENV2" \
      >"$WORK/g2.ajtprecomp.out" 2>"$WORK/g2.ajtprecomp.err"
    APC_RC=$?
    T1=$(date +%s%N)
    check "ajt precompile succeeds" "0" "$APC_RC"
    [ $APC_RC -eq 0 ] || tail -20 "$WORK/g2.ajtprecomp.err" | sed 's/^/       /'
    note "ajt precompile: $(( (T1 - T0) / 1000000000 ))s"
    # Non-vacuity: a run that compiled nothing would make every check below
    # trivially true, and that is precisely what a broken graph looks like.
    APC_COMPILED="$(awk -F'\t' '$1=="summary" {print $3}' "$WORK/g2.ajtprecomp.out")"
    [ "${APC_COMPILED:-0}" -gt 0 ] \
      && ok "it compiled $APC_COMPILED entries (so the comparison is not vacuous)" \
      || bad "ajt precompile compiled nothing"
    check "nothing failed" "0" "$(awk -F'\t' '$1=="summary" {print $7}' "$WORK/g2.ajtprecomp.out")"
    # Extensions are the reason this gate can be an assertion at all: without
    # them Pkg finds ~17 entries to build on an otherwise complete depot.
    APC_EXT="$(awk -F'\t' '$1=="extensions" {print $2}' "$WORK/g2.ajtprecomp.out")"
    [ "${APC_EXT:-0}" -gt 0 ] \
      && ok "$APC_EXT package extensions were among them" \
      || bad "no extension was compiled — Pkg.precompile() below will have work to do"

    CC_BEFORE=$(find "$DEPOT_AJT/compiled" -type f 2>/dev/null | wc -l)
    find "$DEPOT_AJT/compiled" -type f 2>/dev/null | sort > "$WORK/g2.cc.before"
    env JULIA_DEPOT_PATH="$DEPOT_AJT" \
      julia --startup-file=no --project="$ENV2" -e 'using Pkg; Pkg.precompile()' \
      >"$WORK/g2.precomp.out" 2>&1
    PC_RC=$?
    CC_AFTER=$(find "$DEPOT_AJT/compiled" -type f 2>/dev/null | wc -l)
    find "$DEPOT_AJT/compiled" -type f 2>/dev/null | sort > "$WORK/g2.cc.after"
    check "Pkg.precompile() succeeds on the depot ajt built" "0" "$PC_RC"
    [ $PC_RC -eq 0 ] || tail -20 "$WORK/g2.precomp.out" | sed 's/^/       /'

    # THE M5 ACCEPTANCE CRITERION. Not "roughly the same size": zero new files.
    NEW_N="$(comm -13 "$WORK/g2.cc.before" "$WORK/g2.cc.after" | wc -l)"
    check "Pkg.precompile() wrote NO new file under compiled/" "0" "$NEW_N"
    [ "$NEW_N" -eq 0 ] || comm -13 "$WORK/g2.cc.before" "$WORK/g2.cc.after" |
      sed "s|$DEPOT_AJT/compiled/||" | head -20 | sed 's/^/       /'
    note "compiled/ files: $CC_BEFORE -> $CC_AFTER"

    # And the whole point of a precompiled depot: the project loads out of it,
    # with Pkg never invoked. `--project` alone, no `using Pkg` anywhere.
    LOAD_NAME="$(awk -F'"' '/^name *=/ {print $2; exit}' "$ENV2/Project.toml")"
    if [ -n "$LOAD_NAME" ]; then
      LOADED="$(env JULIA_DEPOT_PATH="$DEPOT_AJT" \
        julia --startup-file=no --project="$ENV2" \
        -e "using $LOAD_NAME; print(\"ok\")" 2>"$WORK/g2.load.err")"
      check "\`using $LOAD_NAME\` succeeds against the depot ajt built" "ok" "${LOADED:-}"
      [ "${LOADED:-}" = "ok" ] || tail -10 "$WORK/g2.load.err" | sed 's/^/       /'
      check "...and loading it wrote no cache file either" "$CC_AFTER" \
        "$(find "$DEPOT_AJT/compiled" -type f 2>/dev/null | wc -l)"
    fi
  else
    echo "  --- precompile SKIPPED (--precompile to run the M5 acceptance gate) ---"
    note "that gate runs ajt precompile and then requires Pkg.precompile() to write"
    note "ZERO new files under compiled/. It takes minutes, which is why it is opt-in."
  fi
fi

# ===========================================================================
# GATE 3 — Pkg -> Ajt interop
# ===========================================================================
echo
echo "==> GATE 3: Pkg -> Ajt — ajt must accept a depot stock Pkg built"
ENV3="$(mkenv env-g3)"
DEPOT_PKG="$WORK/depot-pkg"
mkdir -p "$DEPOT_PKG"

# Hermetic: a depot built here and now by stock Pkg, NOT the ambient ~/.julia.
# The ambient depot has been accreting for months and would let this gate pass
# on state no CI machine has.
T0=$(date +%s%N)
env JULIA_DEPOT_PATH="$DEPOT_PKG" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV3" -e 'using Pkg; Pkg.instantiate()' \
  >"$WORK/g3.pkg.out" 2>&1
PKG3_RC=$?
T1=$(date +%s%N)
PKG_MS=$(( (T1 - T0) / 1000000 ))
check "stock Pkg.instantiate() built the depot" "0" "$PKG3_RC"
[ $PKG3_RC -eq 0 ] || tail -20 "$WORK/g3.pkg.out" | sed 's/^/       /'
note "Pkg.instantiate() into an empty depot: $((PKG_MS/1000))s"

if [ $PKG3_RC -eq 0 ]; then
  snapshot "$DEPOT_PKG" > "$WORK/g3.depot.before"
  "$AJT" verify --frozen --depot "$DEPOT_PKG" "$ENV3" >"$WORK/g3.verify.out" 2>&1
  V_RC=$?
  snapshot "$DEPOT_PKG" > "$WORK/g3.depot.after"

  check "ajt verify --frozen exits 0 on a Pkg-built depot" "0" "$V_RC"
  [ $V_RC -eq 0 ] || head -20 "$WORK/g3.verify.out" | sed 's/^/       /'

  # NON-VACUITY: verify must have actually resolved and checked the entries.
  # "0 installed" would exit 0 too, and would mean nothing.
  V_INST="$(grep -oE '[0-9]+ installed' "$WORK/g3.verify.out" | head -1 | cut -d' ' -f1)"
  if [ -n "${V_INST:-}" ] && [ "$V_INST" -gt 0 ]; then
    ok "and it checked $V_INST installed entries (not a vacuous pass)"
  else
    bad "verify exited 0 without checking anything" "installed count: ${V_INST:-<unparsed>}"
  fi

  # verify's whole contract is that it writes nothing -- it is what the
  # container entrypoint runs to decide whether Pkg may be skipped.
  if diff -q "$WORK/g3.depot.before" "$WORK/g3.depot.after" >/dev/null; then
    ok "verify wrote nothing to the depot"
  else
    bad "verify WROTE to the depot" "$(diff "$WORK/g3.depot.before" "$WORK/g3.depot.after" | head -5 | tr '\n' '|')"
  fi

  # Both installers must have produced the same thing, or gates 2 and 3 are
  # measuring different environments and neither number means much.
  A_PKGS="$(find "$DEPOT_AJT/packages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  P_PKGS="$(find "$DEPOT_PKG/packages"  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  check "ajt and Pkg installed the same number of packages" "$P_PKGS" "$A_PKGS"
  A_ARTS="$(find "$DEPOT_AJT/artifacts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  P_ARTS="$(find "$DEPOT_PKG/artifacts"  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  check "ajt and Pkg installed the same number of artifacts" "$P_ARTS" "$A_ARTS"
fi

fi  # network
fi  # --quick

# ===========================================================================
echo
echo "==> the harness itself touched nothing it should not have"
git -C "$REPO_ROOT" status --porcelain -- Open-Reality > "$WORK/git.after" 2>/dev/null
if diff -q "$WORK/git.before" "$WORK/git.after" >/dev/null; then
  ok "the repo's Open-Reality/ is exactly as it was"
else
  bad "the harness modified the repo" "$(diff "$WORK/git.before" "$WORK/git.after" | head -5 | tr '\n' '|')"
fi
if [ -n "$AMBIENT" ]; then
  find "$AMBIENT" -maxdepth 1 -printf '%p\t%T@\n' 2>/dev/null | sort > "$WORK/ambient.after"
  if diff -q "$WORK/ambient.before" "$WORK/ambient.after" >/dev/null; then
    ok "the real depot's top level is untouched ($AMBIENT)"
  else
    bad "the harness wrote into the real depot" \
        "$(diff "$WORK/ambient.before" "$WORK/ambient.after" | head -5 | tr '\n' '|')"
  fi
fi

echo
echo "======================================================================"
printf 'fallback gates: %d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || exit 1
[ $PASS -gt 0 ] || { echo "nothing ran"; exit 3; }
exit 0
