#!/usr/bin/env bash
# Differential gate for `ajt precompile` (src/ops/precompile.zig).
#
# The claim: **`ajt precompile` and `Pkg.precompile()`, run over the same
# environment into two equally-prepared depots, leave byte-for-byte the same set
# of files under `compiled/`** -- the same package directories, the same slug
# filenames, the same count. `compiled/` is the one directory Ajt deliberately
# never writes itself (depot.zig:27-33); it invokes Julia and Julia writes. So
# the only honest way to test this module is to compare the directory two real
# Julias produced, and that is what this file does.
#
# Why the two depots have to be PREPARED rather than empty. `Pkg.precompile()`
# has to load Pkg, and loading Pkg into a virgin depot precompiles Pkg and ~23
# stdlibs into `compiled/` first -- 48 files that have nothing to do with the
# environment under test. `ajt precompile` never loads Pkg, so a naive
# comparison would show 48 spurious differences and prove nothing. The fix is to
# build ONE base depot (a plain `Pkg.instantiate()`, which installs the packages
# and warms exactly that Pkg machinery) and `cp -a` it to both sides, so the
# only thing either side can add is the environment's own packages. Section 0
# asserts the base is non-vacuous: the packages under test must NOT already be
# cached in it, or every comparison below is trivially true.
#
# Eight sections:
#
#   0. THE FIXTURE AND THE BASE DEPOT. A tiny package environment (Parsers, so
#      the graph is Preferences -> PrecompileTools -> Parsers and the project
#      itself, plus CompositionsBase + InverseFunctions so that package
#      extensions are loadable), instantiated once. Deliberately NOT the
#      173-entry engine: that precompiles for minutes and says nothing this
#      does not.
#
#      TWO extensions fall out of that fixture, not one, and the second is the
#      more interesting: `CompositionsBaseInverseFunctionsExt` is the one the
#      deps were chosen for, and `InverseFunctionsDatesExt` appears because
#      Parsers drags `Dates` into the closure. An extension arriving from a
#      package nobody added on purpose is exactly the shape this feature has to
#      get right, so the count is asserted rather than derived.
#   1. ajt precompile into depot A, timed. Includes the extension check: the
#      set of extension nodes, with the uuid Julia minted for each, against
#      Julia's own answer.
#   2. Pkg.precompile() into depot B, timed.
#   3. THE COMPARISON. Package names, slug filenames, and count.
#   4. IDEMPOTENCE. A second `ajt precompile` must compile nothing, create and
#      remove no file, and leave every cache file byte-identical. NOT "move no
#      mtime": Julia touches a cache file whenever it validates one, and a warm
#      `Pkg.precompile()` moves strictly more of them than ajt does. See the
#      section for the measurement.
#   5. THE STRONG EXTERNAL GATE. `Pkg.precompile()` against the depot ajt built
#      must report that everything is already precompiled. A cache that looked
#      right but that Julia wanted to rebuild would pass section 3 and be
#      useless.
#   6. THE PIDLOCK. A second process takes the same pidfile Julia would take
#      (`Base.compilecache_pidfile_path`), holds it, compiles the entry itself
#      and releases. `ajt precompile` must WAIT for it and report `waited` --
#      not compile the same entry concurrently, which is how a `.ji` gets
#      corrupted and stays corrupted until someone deletes the depot. A
#      no-holder control run makes "it waited" falsifiable.
#   7. --only. `Pkg.precompile(pkgs)`'s filter, differentially (the same
#      subset of compiled/ out of both sides), and the src-less-project shape
#      it exists for: a bare run over an environment whose project has no
#      source yet FAILS on both sides, and the direct-dep subset -- which is
#      how backend-image depot layers precompile -- succeeds on both and
#      leaves the same files.
#
# WALL CLOCK. Sections 1 and 2 print both sides for this SMALL fixture, which is
# the number to quote when reasoning about per-package overhead (ajt pays one
# julia startup per package; Pkg pays one for the whole run and compiles
# N-wide). It is NOT the M5 milestone number: the engine-scale timer already
# exists as `scripts/bench/bench.sh b0` (a cold `Pkg.precompile()` of
# Open-Reality into a scratch depot, across a JULIA_NUM_PRECOMPILE_TASKS sweep),
# and `bench.sh b0 --variant ajt` is how the two get diffed on one host. Do not
# add a second engine-scale timer here.
#
# NOTHING here writes to the user's real ~/.julia or to the repo: the fixture is
# generated into $WORK, every depot is under $WORK, and every julia invocation
# gets JULIA_DEPOT_PATH pointed there. The one exception is the network probe
# (`ajt fetch --no-auth`, so it cannot refresh a token into the real depot's
# servers/*/auth.toml).
#
# Usage: precompile.sh [--keep]
#   --keep   leave $WORK behind
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    # Every line of the header block, and nothing past it: `set -uo pipefail`
    # printed as documentation is how you learn the range drifted.
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Prerequisites. Each one is a LOUD skip rather than a red run: a failure here
# says nothing about src/ops/precompile.zig.
# ---------------------------------------------------------------------------
skip () {
  echo
  echo "########################################################################"
  echo "# SKIPPED: $1"
  printf '# %s\n' "${@:2}"
  echo "########################################################################"
  exit 0
}

command -v julia >/dev/null || skip "julia is not on PATH." \
  "This gate compares what ajt makes julia write against what Pkg makes" \
  "julia write. There is no offline or julia-less subset of that question;" \
  "the pure half (the graph and the ordering) is covered by the unit tests" \
  "in src/ops/precompile.zig, which run under \`zig build test\`."
command -v zig >/dev/null || skip "zig is not on PATH, so ajt cannot be built."

WORK="$(mktemp -d -t ajt-precompile-XXXXXX)"
# Pkg makes installed packages and artifacts read-only (`set_readonly`), so the
# cleanup has to restore write bits before it can delete them.
cleanup () { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok ()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad ()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# A directory's SHAPE: every path, its size and its type. Deliberately NOT the
# mtime -- see section 4 for why that would be a gate on Julia's behaviour
# rather than on ajt's.
snapshot () { find "$1" -printf '%p\t%s\t%y\n' 2>/dev/null | sort; }

# The CONTENT of every cache file, which is the thing a second run must not
# rewrite. Paths are made relative so two different depots can be compared.
cache_sums () { ( cd "$1" && find . -type f \( -name '*.ji' -o -name '*.so' \) -exec md5sum {} + 2>/dev/null | sort -k2 ); }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# `--no-auth`: this is the ONE ajt invocation with no --depot, so Config.fromEnv
# resolves depots1() to the ambient ~/.julia -- and an authenticated GET against
# an expired token would REFRESH it, rewriting the user's real auth.toml. A
# reachability probe has no business doing that.
"$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1 \
  || skip "no network (https://pkg.julialang.org unreachable)." \
     "Section 0 downloads a registry and three small packages before anything" \
     "can be precompiled. There is no cached subset worth running."

# ---------------------------------------------------------------------------
echo
echo "==> 0. the fixture, and one base depot both sides start from"

ENV_DIR="$WORK/env"
mkdir -p "$ENV_DIR/src"
# A PACKAGE, not a bare environment: `ExplicitEnv` inserts the project's own
# name/uuid into project_deps when it has both (precompilation.jl:80-91), so a
# package fixture is the only kind that exercises "the project is a root". A
# bare [deps] fixture would let that whole branch rot untested.
cat > "$ENV_DIR/Project.toml" <<'EOF'
name = "AjtPrecompileFixture"
uuid = "0d2b8f34-6a1e-4c9d-9f2b-3a5c7e1d4b60"
version = "0.1.0"

[deps]
Parsers = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
CompositionsBase = "a33af91c-f02d-484b-be07-31d278c5ca2b"
InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"
EOF
cat > "$ENV_DIR/src/AjtPrecompileFixture.jl" <<'EOF'
module AjtPrecompileFixture

using Parsers

parse_int(s::AbstractString) = Parsers.parse(Int, s)

end # module
EOF

JV="$(julia --startup-file=no -e 'print("v", VERSION.major, ".", VERSION.minor)')"
[ -n "$JV" ] || { echo "ERROR: could not ask julia for its version" >&2; exit 2; }

BASE="$WORK/base"
mkdir -p "$BASE"
# JULIA_PKG_PRECOMPILE_AUTO=0 is what keeps the base depot from precompiling the
# environment as a side effect of installing it -- which would leave sections
# 1-3 with nothing to do and every check trivially green.
env JULIA_DEPOT_PATH="$BASE" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
  >"$WORK/base.log" 2>&1
BASE_RC=$?
if [ $BASE_RC -ne 0 ]; then
  echo "ERROR: could not instantiate the fixture" >&2; tail -20 "$WORK/base.log" >&2; exit 2
fi

# The packages the comparison is ABOUT. If any of them is already cached in the
# base, both sides will find it fresh and section 3 proves nothing.
UNDER_TEST="Unicode Preferences PrecompileTools Parsers AjtPrecompileFixture CompositionsBase InverseFunctions CompositionsBaseInverseFunctionsExt InverseFunctionsDatesExt"
VACUOUS=0
for n in $UNDER_TEST; do
  [ -d "$BASE/compiled/$JV/$n" ] && { bad "$n is already cached in the base depot -- section 3 would be vacuous"; VACUOUS=1; }
done
[ $VACUOUS -eq 0 ] && ok "none of the $(echo $UNDER_TEST | wc -w) packages under test is cached in the base depot"
# ...and the base is not empty either, or the "prepare both sides equally" trick
# is not actually doing anything and the Pkg side will diverge by ~48 files.
BASE_N="$(find "$BASE/compiled/$JV" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
[ "$BASE_N" -gt 5 ] && ok "the base depot carries Pkg's own machinery ($BASE_N cached packages), so neither side has to build it" \
  || bad "the base depot has only $BASE_N cached packages -- loading Pkg in section 2 will add entries ajt never sees"

# The fixture MUST contain a loadable extension, and this is the check that says
# so. `CompositionsBase` declares `CompositionsBaseInverseFunctionsExt`,
# triggered by `InverseFunctions`, and both are in `[deps]` -- so the extension
# is a node for Pkg and must be one for ajt too. Section 3 then compares what
# the two of them actually wrote.
#
# The assertion is here rather than implicit in section 3 because section 3
# compares two SETS: drop the extension from the fixture and both sides produce
# the same smaller set, the gate stays green, and the feature it is guarding
# stops being tested. This is the non-vacuity check for that.
#
# `ExplicitEnv` lives in Base.Precompilation, not Base -- it is the private
# model `_precompilepkgs` itself builds (precompilation.jl:1-10).
# A comprehension, not a `for` loop with an accumulator: at top level in `julia
# -e` the loop body is a soft scope, so `n += ...` binds a NEW local and the
# print reads an undefined global.
EXT_ORACLE="$(env JULIA_DEPOT_PATH="$BASE" julia --startup-file=no -e '
env = Base.Precompilation.ExplicitEnv(joinpath(ARGS[1], "Project.toml"))
pkgs = Set{Base.UUID}()
for (_, uuid) in env.project_deps
    Base.Precompilation._collect_reachable!(pkgs, env.deps, uuid)
end
out = String[]
for dep in pkgs
    haskey(env.deps, dep) || continue
    parent = Base.PkgId(dep, env.names[dep])
    Base.in_sysimage(parent) && continue
    for (ext, triggers) in get(Dict{String,Vector{Base.UUID}}, env.extensions, dep)
        all(t -> t in pkgs, triggers) || continue
        push!(out, string(parent.name, "\t", ext, "\t", Base.uuid5(parent.uuid, ext)))
    end
end
print(join(sort(out), "\n"))' "$ENV_DIR" 2>"$WORK/exts.err")"
EXT_N="$(printf '%s' "$EXT_ORACLE" | grep -c . || true)"
check "the fixture declares exactly two loadable extensions" "2" "${EXT_N:-unknown}"
[ "${EXT_N:-0}" -ge 1 ] || sed -n '1,5p' "$WORK/exts.err" | sed 's/^/       /'

# ---------------------------------------------------------------------------
echo
echo "==> 1. ajt precompile, into a copy of the base depot"
DEPOT_A="$WORK/depot-ajt"
cp -a "$BASE" "$DEPOT_A"

T0=$(date +%s%N)
"$AJT" precompile --depot "$DEPOT_A" "$ENV_DIR" >"$WORK/ajt1.records" 2>"$WORK/ajt1.err"
AJT_RC=$?
T1=$(date +%s%N)
AJT_MS=$(( (T1 - T0) / 1000000 ))

check "ajt precompile exited cleanly" "0" "$AJT_RC"
[ "$AJT_RC" -eq 0 ] || head -20 "$WORK/ajt1.err" | sed 's/^/       /'

read -r A_CONSIDERED A_COMPILED A_ALREADY A_STALE A_SKIPPED A_FAILED <<EOF
$(awk -F'\t' '$1=="summary" {print $2, $3, $4, $5, $6, $7}' "$WORK/ajt1.records")
EOF
check "nothing failed" "0" "${A_FAILED:-}"
check "nothing was left planned-but-uncompiled" "0" "${A_STALE:-}"
[ "${A_COMPILED:-0}" -gt 0 ] && ok "$A_COMPILED packages compiled (of $A_CONSIDERED considered)" \
  || bad "ajt compiled nothing -- the run was a no-op"

# The project's own package must be one of them. This is the rule that is
# easiest to get wrong and least likely to be noticed: walk only [deps] and
# every dependency gets a cache while the package the user actually wrote does
# not.
check "the project's own package was precompiled" "compiled" \
  "$(awk -F'\t' '$1=="package" && $3=="AjtPrecompileFixture" {print $2}' "$WORK/ajt1.records")"
# ...and sysimage packages were NOT, or ajt writes cache directories Pkg never
# creates and section 3 fails.
[ "$(awk -F'\t' '$1=="package" && $2=="in_sysimage"' "$WORK/ajt1.records" | wc -l)" -gt 0 ] \
  && ok "sysimage packages were recognised and skipped (Base.in_sysimage, precompilation.jl:624)" \
  || bad "no package was recognised as being in the sysimage -- that filter did not run"

# --- the extension nodes, against Julia's own answer ------------------------
#
# Ajt decides WHICH extensions are nodes (the closure and the trigger rules,
# ported into src/ops/precompile.zig) but cannot decide what each one is
# CALLED: the uuid is `Base.uuid5(parent, name)`, which is a bespoke hash over
# Julia internals rather than RFC 4122. So the uuid it prints came back from the
# probe, and this compares the whole triple -- parent, name, uuid -- with what
# Julia computes independently. A port of uuid5 would agree with itself; this
# has to agree with the thing that reads the cache.
printf '%s\n' "$EXT_ORACLE" | sed '/^$/d' | sort > "$WORK/ext.oracle"
awk -F'\t' '$1=="extension" {print $3 "\t" $4 "\t" $5}' "$WORK/ajt1.records" | sort > "$WORK/ext.ajt"
if diff -u "$WORK/ext.oracle" "$WORK/ext.ajt" > "$WORK/ext.diff" 2>&1; then
  ok "the extension set matches Julia's exactly ($EXT_N: parent, name and uuid)"
else
  bad "ajt's extension set differs from Julia's"
  sed -n '1,20p' "$WORK/ext.diff" | sed 's/^/       /'
fi
check "every extension was compiled" "0" \
  "$(awk -F'\t' '$1=="extension" && $2!="compiled" && $2!="already_precompiled"' "$WORK/ajt1.records" | wc -l)"

# ---------------------------------------------------------------------------
echo
echo "==> 2. Pkg.precompile(), into an equally-prepared copy"
DEPOT_B="$WORK/depot-pkg"
cp -a "$BASE" "$DEPOT_B"

T0=$(date +%s%N)
env JULIA_DEPOT_PATH="$DEPOT_B" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
  >"$WORK/pkg.log" 2>&1
PKG_RC=$?
T1=$(date +%s%N)
PKG_MS=$(( (T1 - T0) / 1000000 ))
check "Pkg.precompile() succeeded" "0" "$PKG_RC"
[ "$PKG_RC" -eq 0 ] || tail -20 "$WORK/pkg.log" | sed 's/^/       /'
sed -n 's/^/    /p' "$WORK/pkg.log" | tail -8

# ---------------------------------------------------------------------------
echo
echo "==> 3. the comparison: the same files under compiled/"

names ()  { find "$1/compiled/$JV" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }
files ()  { find "$1/compiled/$JV" -mindepth 2 -type f -printf '%P\n' 2>/dev/null | sort; }

names "$DEPOT_B" > "$WORK/pkg.names"; names "$DEPOT_A" > "$WORK/ajt.names"
files "$DEPOT_B" > "$WORK/pkg.files"; files "$DEPOT_A" > "$WORK/ajt.files"

# Non-vacuity, again and for the last time: two empty lists compare equal.
[ -s "$WORK/pkg.files" ] || bad "Pkg produced no cache files at all -- every comparison below is vacuous"

if diff -q "$WORK/pkg.names" "$WORK/ajt.names" >/dev/null; then
  ok "the same $(wc -l < "$WORK/ajt.names") package directories exist under compiled/$JV"
else
  bad "the two depots hold different package directories" \
      "$(diff "$WORK/pkg.names" "$WORK/ajt.names" | head -10 | tr '\n' '|')"
fi

# The SLUG names, not just the package names. The slug is a crc32c over the
# active project, the julia binary, the sysimage, the cache flags, the CPU
# target and the preferences hash (loading.jl:3152-3172) -- so a matching set of
# directory names with mismatched slugs means ajt invoked a julia that Julia
# itself would not load the result of.
if diff -q "$WORK/pkg.files" "$WORK/ajt.files" >/dev/null; then
  ok "the same $(wc -l < "$WORK/ajt.files") cache files exist, slug for slug"
else
  bad "the cache files differ" \
      "$(diff "$WORK/pkg.files" "$WORK/ajt.files" | head -12 | tr '\n' '|')"
fi
check "the same number of cache files" "$(wc -l < "$WORK/pkg.files")" "$(wc -l < "$WORK/ajt.files")"

# And the packages under test are actually in there, so a pair of
# base-depot-only trees cannot pass by being equal to each other.
MISSING=0
for n in $UNDER_TEST; do
  grep -qx "$n" "$WORK/ajt.names" || { bad "$n has no cache directory in the ajt depot"; MISSING=1; }
done
[ $MISSING -eq 0 ] && ok "every package under test ($(echo $UNDER_TEST | wc -w)) has a cache directory"

# ---------------------------------------------------------------------------
echo
echo "==> 4. idempotence: a second run compiles nothing and rewrites nothing"
#
# Note what is NOT asserted: that no mtime moved. Julia deliberately `touch`es a
# cache file whenever it validates one -- "update timestamp of precompilation
# file so that it is the first to be tried by code loading" (loading.jl:1877,
# and again at :2092). So a warm run legitimately moves mtimes, and measuring it
# confirms ajt does strictly LESS of it than the thing it replaces: on this
# fixture a warm `ajt precompile` moves 9 cache-file mtimes and a warm
# `Pkg.precompile()` moves 12 paths (the same 9, plus Pkg's own cache, plus a
# rewritten logs/manifest_usage.toml). An mtime gate here would fail ajt for
# behaviour Julia owns and Pkg shares.
#
# What idempotence actually has to mean, then: no cache file is created,
# removed, resized, or has its CONTENT rewritten.

snapshot "$DEPOT_A" > "$WORK/depot.before"
cache_sums "$DEPOT_A" > "$WORK/sums.before"
[ -s "$WORK/depot.before" ] || bad "the depot snapshot is empty -- the comparison below would be vacuous"
[ -s "$WORK/sums.before" ]  || bad "no cache files to checksum -- the comparison below would be vacuous"

T0=$(date +%s%N)
"$AJT" precompile --depot "$DEPOT_A" "$ENV_DIR" >"$WORK/ajt2.records" 2>"$WORK/ajt2.err"
AJT2_RC=$?
T1=$(date +%s%N)
AJT2_MS=$(( (T1 - T0) / 1000000 ))
snapshot "$DEPOT_A" > "$WORK/depot.after"
cache_sums "$DEPOT_A" > "$WORK/sums.after"

check "the second run exited cleanly" "0" "$AJT2_RC"
read -r B_CONSIDERED B_COMPILED B_ALREADY <<EOF
$(awk -F'\t' '$1=="summary" {print $2, $3, $4}' "$WORK/ajt2.records")
EOF
check "the second run considered the same packages" "${A_CONSIDERED:-}" "${B_CONSIDERED:-}"
check "...and compiled none of them" "0" "${B_COMPILED:-}"
[ "${B_ALREADY:-0}" -ge "${A_COMPILED:-1}" ] \
  && ok "...and found $B_ALREADY already precompiled" \
  || bad "the second run found only ${B_ALREADY:-0} already precompiled, expected at least ${A_COMPILED:-1}"

if diff -q "$WORK/depot.before" "$WORK/depot.after" >/dev/null; then
  ok "no path was created, removed, resized or retyped under the depot"
else
  bad "the second run changed the shape of the depot" \
      "$(diff "$WORK/depot.before" "$WORK/depot.after" | head -8 | tr '\n' '|')"
fi
if diff -q "$WORK/sums.before" "$WORK/sums.after" >/dev/null; then
  ok "all $(wc -l < "$WORK/sums.after") cache files are byte-identical afterwards"
else
  bad "the second run rewrote a cache file" \
      "$(diff "$WORK/sums.before" "$WORK/sums.after" | head -8 | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 5. the strong external gate: stock Pkg has nothing left to do"
#
# From here julia writes into $DEPOT_A (logs/), which is why this runs after
# section 4 and not before it.
env JULIA_DEPOT_PATH="$DEPOT_A" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
  >"$WORK/pkgcheck.log" 2>&1
PKGCHECK_RC=$?
check "Pkg.precompile() succeeds against the depot ajt built" "0" "$PKGCHECK_RC"
if grep -Eq '✓|successfully precompiled' "$WORK/pkgcheck.log"; then
  bad "Pkg.precompile() still had work to do, so ajt's run was incomplete" \
      "$(grep -E '✓|successfully precompiled' "$WORK/pkgcheck.log" | head -5 | tr '\n' '|')"
else
  ok "Pkg.precompile() compiled NOTHING -- it agrees the environment is done"
fi

# The environment must also actually LOAD out of that depot, which is the thing
# a cache is for. Nothing else in this harness proves the .ji files are usable.
LOAD_OUT="$(env JULIA_DEPOT_PATH="$DEPOT_A" \
  julia --startup-file=no --project="$ENV_DIR" -e '
  using AjtPrecompileFixture
  print(AjtPrecompileFixture.parse_int("41") + 1)' 2>"$WORK/using.err")"
check "the fixture loads from the depot ajt precompiled" "42" "${LOAD_OUT:-}"
[ "${LOAD_OUT:-}" = "42" ] || tail -8 "$WORK/using.err" | sed 's/^/       /'

# ---------------------------------------------------------------------------
echo
echo "==> 6. the pidlock is honoured"
#
# The failure this rules out is not slowness. Two processes running
# Base.compilecache on one entry write one .ji between them, and the loser's
# half-written output is what the next `using` reads: "Invalid header in cache
# file", permanently, until the depot is deleted. Julia's answer is a pidfile
# next to the entry (Base.compilecache_pidfile_path, loading.jl:3871) and
# ajt must take it -- see precompile_pkgs_maybe_cachefile_lock,
# precompilation.jl:1253-1293.

PARSERS_UUID=69de0a69-1ddd-5017-9359-2bf0b02dc9f0
HOLD_SECONDS=6

# A depot where exactly ONE package is stale, so the contended entry is the only
# work either process has to do.
DEPOT_C="$WORK/depot-lock"
cp -a "$DEPOT_A" "$DEPOT_C"
rm -rf "$DEPOT_C/compiled/$JV/Parsers"
rm -rf "$DEPOT_C/compiled/$JV/AjtPrecompileFixture"

# The control. Same depot state, no holder: this is how long the compile takes
# when nothing is in the way, and it is what makes "ajt waited" falsifiable
# rather than a tautology about a slow machine.
DEPOT_CTL="$WORK/depot-control"
cp -a "$DEPOT_C" "$DEPOT_CTL"
T0=$(date +%s%N)
"$AJT" precompile --depot "$DEPOT_CTL" "$ENV_DIR" >"$WORK/ctl.records" 2>&1
T1=$(date +%s%N)
CTL_MS=$(( (T1 - T0) / 1000000 ))
check "the uncontended control run succeeded" "compiled" \
  "$(awk -F'\t' '$1=="package" && $3=="Parsers" {print $2}' "$WORK/ctl.records")"

# The holder: takes the very pidfile ajt will want, tells us once it HAS it,
# holds it while ajt is starting, then does the compile itself and releases.
# Compiling inside the lock is what makes the assertion strong -- ajt must come
# back reporting `waited`, i.e. it noticed someone else had produced the entry
# and did not redo the work.
cat > "$WORK/holder.jl" <<'EOF'
using FileWatching
pkg = Base.PkgId(Base.UUID(ARGS[1]), ARGS[2])
pidfile = Base.compilecache_pidfile_path(pkg; flags = Base.CacheFlags())
mkpath(dirname(pidfile))
lock = mkpidlock(pidfile; stale_age = Base.compilecache_pidlock_stale_age)
write(ARGS[4], "held\n")   # only now may the harness start ajt
sleep(parse(Float64, ARGS[5]))
Base.compilecache(pkg, ARGS[3], stderr, stderr, false; cacheflags = Base.CacheFlags())
close(lock)
EOF
SRC="$(env JULIA_DEPOT_PATH="$DEPOT_C" julia --startup-file=no --project="$ENV_DIR" \
  -e 'print(something(Base.locate_package(Base.PkgId(Base.UUID(ARGS[1]), ARGS[2])), ""))' \
  -- "$PARSERS_UUID" Parsers 2>/dev/null)"
[ -n "$SRC" ] || bad "could not locate Parsers' source, so the pidlock section cannot run"

if [ -n "$SRC" ]; then
  READY="$WORK/holder.ready"
  rm -f "$READY"
  env JULIA_DEPOT_PATH="$DEPOT_C" julia --startup-file=no --project="$ENV_DIR" \
    "$WORK/holder.jl" "$PARSERS_UUID" Parsers "$SRC" "$READY" "$HOLD_SECONDS" \
    >"$WORK/holder.log" 2>&1 &
  HOLDER=$!

  # Wait for the lock to actually be held. Racing ajt against a holder that has
  # not acquired yet would test nothing and pass anyway.
  WAITED=0
  while [ ! -f "$READY" ] && [ $WAITED -lt 120 ]; do sleep 0.25; WAITED=$((WAITED+1)); done
  if [ ! -f "$READY" ]; then
    bad "the holder never acquired the pidlock" "$(tail -5 "$WORK/holder.log" | tr '\n' '|')"
    kill $HOLDER 2>/dev/null
  else
    ok "a second process holds Parsers' pidfile"
    T0=$(date +%s%N)
    "$AJT" precompile --depot "$DEPOT_C" "$ENV_DIR" >"$WORK/lock.records" 2>"$WORK/lock.err"
    LOCK_RC=$?
    T1=$(date +%s%N)
    LOCK_MS=$(( (T1 - T0) / 1000000 ))
    wait $HOLDER

    check "ajt precompile exited cleanly while contended" "0" "$LOCK_RC"
    [ "$LOCK_RC" -eq 0 ] || head -10 "$WORK/lock.err" | sed 's/^/       /'

    # The verdict. `waited` is the only correct answer: the holder produced the
    # entry, so ajt must have blocked on the lock and then found it fresh.
    # `compiled` here would mean ajt built it too -- concurrently, over the top
    # of the holder.
    check "ajt reports that it waited for the other process" "waited" \
      "$(awk -F'\t' '$1=="package" && $3=="Parsers" {print $2}' "$WORK/lock.records")"

    # ...and it really did block, rather than reporting `waited` off a lucky
    # re-check. The holder sits on the lock for HOLD_SECONDS before it even
    # starts compiling, so a run that did not block cannot have taken that long.
    if [ "$LOCK_MS" -ge $((HOLD_SECONDS * 1000)) ]; then
      ok "it blocked for ${LOCK_MS} ms (holder held for ${HOLD_SECONDS}s; uncontended control was ${CTL_MS} ms)"
    else
      bad "ajt returned after only ${LOCK_MS} ms, less than the ${HOLD_SECONDS}s the lock was held" \
          "it cannot have waited for the lock"
    fi
    # A stale .pidfile left behind means the lock was not released cleanly and
    # the next run pays stale_age seconds for nothing.
    check "no pidfile was left behind" "0" \
      "$(find "$DEPOT_C/compiled/$JV" -name '*.pidfile' 2>/dev/null | wc -l)"
    # One entry, not two. This is the corruption the whole protocol prevents.
    check "Parsers has exactly one .ji cache file" "1" \
      "$(find "$DEPOT_C/compiled/$JV/Parsers" -name '*.ji' 2>/dev/null | wc -l)"
    # ...and it is loadable, which a torn write would not be.
    LOCK_LOAD="$(env JULIA_DEPOT_PATH="$DEPOT_C" \
      julia --startup-file=no --project="$ENV_DIR" \
      -e 'using Parsers; print(Parsers.parse(Int, "7"))' 2>"$WORK/lockload.err")"
    check "the contended cache entry loads" "7" "${LOCK_LOAD:-}"
    [ "${LOCK_LOAD:-}" = "7" ] || tail -6 "$WORK/lockload.err" | sed 's/^/       /'
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "==> 7. --only: Pkg.precompile(pkgs)'s filter, and the missing-src case it exists for"

# 7a. The filter, differentially. `--only Parsers` against
# `Pkg.precompile(["Parsers"])` over equally-prepared depots: the same subset
# must come out -- Parsers and its dep closure cached, CompositionsBase (a
# direct dep OUTSIDE that closure) not, extensions dropped on both sides
# because their triggers are not all kept.
DEPOT_OA="$WORK/depot-only-ajt"
DEPOT_OB="$WORK/depot-only-pkg"
cp -a "$BASE" "$DEPOT_OA"
cp -a "$BASE" "$DEPOT_OB"

"$AJT" precompile --depot "$DEPOT_OA" --only Parsers "$ENV_DIR" \
  >"$WORK/only.records" 2>"$WORK/only.err"
check "ajt precompile --only exited cleanly" "0" "$?"
env JULIA_DEPOT_PATH="$DEPOT_OB" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile(["Parsers"])' \
  >"$WORK/only-pkg.log" 2>&1
check "Pkg.precompile([\"Parsers\"]) succeeded" "0" "$?"

names "$DEPOT_OB" > "$WORK/only-pkg.names"; names "$DEPOT_OA" > "$WORK/only-ajt.names"
files "$DEPOT_OB" > "$WORK/only-pkg.files"; files "$DEPOT_OA" > "$WORK/only-ajt.files"
if diff -q "$WORK/only-pkg.names" "$WORK/only-ajt.names" >/dev/null; then
  ok "the same $(wc -l < "$WORK/only-ajt.names") package directories exist under the subset"
else
  bad "the subset depots hold different package directories" \
      "$(diff "$WORK/only-pkg.names" "$WORK/only-ajt.names" | head -10 | tr '\n' '|')"
fi
if diff -q "$WORK/only-pkg.files" "$WORK/only-ajt.files" >/dev/null; then
  ok "the same $(wc -l < "$WORK/only-ajt.files") cache files, slug for slug"
else
  bad "the subset cache files differ" \
      "$(diff "$WORK/only-pkg.files" "$WORK/only-ajt.files" | head -12 | tr '\n' '|')"
fi
# Non-vacuity for the FILTER, both directions: the named package's closure is
# in, and a direct dep outside it is out. Two unfiltered runs would pass the
# diffs above; this pair is what a broken (never-applied) filter fails.
grep -qx "Parsers" "$WORK/only-ajt.names" \
  && ok "Parsers is cached in the subset depot" \
  || bad "Parsers is NOT cached -- the subset run did nothing"
grep -qx "CompositionsBase" "$WORK/only-ajt.names" \
  && bad "CompositionsBase is cached -- the filter kept a package outside the requested closure" \
  || ok "CompositionsBase stayed out, as Pkg's filter! drops it (precompilation.jl:811)"
check "no extension survived a subset none of whose triggers sets are whole" "0" \
  "$(awk -F'\t' '$1=="extension"' "$WORK/only.records" | wc -l)"

# 7b. The case the flag exists for: an environment whose PROJECT has no source
# yet -- an image build that copied only Project.toml + Manifest.toml. A bare
# run counts the project source_missing, a FAILURE (as Pkg would: its bare
# `Pkg.precompile()` raises "Missing source file"); the direct-dep subset is
# how backend/Dockerfile's layer 1 precompiles the closure, on both managers.
ENV2="$WORK/env-nosrc"
mkdir -p "$ENV2"
cp "$ENV_DIR/Project.toml" "$ENV_DIR/Manifest.toml" "$ENV2/"
DEPOT_NA="$WORK/depot-nosrc-ajt"
DEPOT_NB="$WORK/depot-nosrc-pkg"
DEPOT_NBARE="$WORK/depot-nosrc-bare"
cp -a "$BASE" "$DEPOT_NA"
cp -a "$BASE" "$DEPOT_NB"
# Its own depot, or its (failing) run would pre-warm DEPOT_NA and the subset
# comparison below would be between depots the SUBSET runs did not build.
cp -a "$BASE" "$DEPOT_NBARE"

"$AJT" precompile --depot "$DEPOT_NBARE" "$ENV2" >"$WORK/nosrc-bare.records" 2>/dev/null
BARE_RC=$?
[ "$BARE_RC" -ne 0 ] \
  && ok "a bare run over the src-less project fails (exit $BARE_RC), as Pkg's bare precompile does" \
  || bad "a bare run over the src-less project SUCCEEDED -- source_missing stopped counting as a failure"
check "...and the project is the thing that failed" "source_missing" \
  "$(awk -F'\t' '$1=="package" && $3=="AjtPrecompileFixture" {print $2}' "$WORK/nosrc-bare.records")"

"$AJT" precompile --depot "$DEPOT_NA" --only Parsers,CompositionsBase,InverseFunctions "$ENV2" \
  >"$WORK/nosrc-only.records" 2>"$WORK/nosrc-only.err"
check "the direct-dep subset over the same src-less project exits cleanly" "0" "$?"
check "nothing failed in it" "0" \
  "$(awk -F'\t' '$1=="summary" {print $7}' "$WORK/nosrc-only.records")"
check "and the project node is GONE from the run, not failed inside it" "" \
  "$(awk -F'\t' '$1=="package" && $3=="AjtPrecompileFixture" {print $2}' "$WORK/nosrc-only.records")"

# The oracle for that exact shape, verbatim from backend/Dockerfile layer 1.
env JULIA_DEPOT_PATH="$DEPOT_NB" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV2" -e \
  'using Pkg, TOML; Pkg.precompile(collect(keys(TOML.parsefile(joinpath(dirname(Base.active_project()), "Project.toml"))["deps"])))' \
  >"$WORK/nosrc-pkg.log" 2>&1
check "Pkg's direct-dep-list precompile succeeds over the same src-less project" "0" "$?"

names "$DEPOT_NB" > "$WORK/nosrc-pkg.names"; names "$DEPOT_NA" > "$WORK/nosrc-ajt.names"
files "$DEPOT_NB" > "$WORK/nosrc-pkg.files"; files "$DEPOT_NA" > "$WORK/nosrc-ajt.files"
if diff -q "$WORK/nosrc-pkg.names" "$WORK/nosrc-ajt.names" >/dev/null \
   && diff -q "$WORK/nosrc-pkg.files" "$WORK/nosrc-ajt.files" >/dev/null; then
  ok "the two src-less depots agree, name for name and slug for slug ($(wc -l < "$WORK/nosrc-ajt.files") files)"
else
  bad "the src-less depots differ" \
      "$(diff "$WORK/nosrc-pkg.files" "$WORK/nosrc-ajt.files" | head -12 | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> wall clock, on this fixture"
echo "  ajt precompile   (cold) : ${AJT_MS} ms   ($A_COMPILED compiled, serial, one julia per package)"
echo "  Pkg.precompile() (cold) : ${PKG_MS} ms   (parallel, one julia for the run)"
echo "  ajt precompile   (warm) : ${AJT2_MS} ms  (one probe process, no compiles)"
echo
echo "  The engine-scale number M5 is measured against is scripts/bench/bench.sh b0;"
echo "  this fixture only sizes the per-package process overhead."

# ---------------------------------------------------------------------------
echo
echo "======================================================================"
printf 'precompile: %d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || exit 1
exit 0
