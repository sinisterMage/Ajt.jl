#!/usr/bin/env bash
# Differential gate for stdlib enumeration.
#
# The resolver decides a stdlib at level 0 as a single fixed version and never
# consults a registry for it, so this list is not "mostly right" territory: a
# missing entry gets resolved from a registry that mostly does not carry it,
# and an extra entry gets pinned to a version that does not exist. Both fail
# far from here. So any symmetric difference against Julia is a hard failure.
#
# Everything is compared against the ONE `julia` on PATH -- prefix, version and
# stdlib directory all come from it, so the two sides can never be reading
# different installations.
#
# What is compared:
#   1. The stdlib directory ajt read vs `Pkg.Types.stdlib_dir()`.
#   2. The compiled-in UPGRADABLE_STDLIBS list vs `Pkg.Types.UPGRADABLE_STDLIBS`.
#   3. The fixed set (name, uuid, version) vs `Pkg.Types.stdlibs()`, counts
#      included. `-` stands for an unversioned stdlib such as SuiteSparse,
#      which Julia reports as `nothing`.
#   4. deps/weakdeps counts vs `Pkg.Types.stdlib_infos()[uuid]`, because
#      `deps_graph` turns those into the stdlib node's edges
#      (Operations.jl:681-693).
#   5. Classification: every name in UPGRADABLE_STDLIBS must be reported as
#      upgradable, must be absent from the fixed set, and Julia must agree
#      `is_stdlib` is false for it. Conversely a core stdlib -- LinearAlgebra --
#      must be fixed and not upgradable.
#
# `Pkg.Types.stdlibs()` returns `Dict(uuid => (name, version))`
# (Types.jl:525-530), so the oracle destructures `(u, (n, v))` -- iterating it
# as `(u, n)` would bind the whole tuple to `n`.
#
# Usage: tools/diff_harness/stdlibs.sh [--keep]
set -uo pipefail

# Julia's `sort(::Vector{String})` is plain byte order. GNU sort under a UTF-8
# locale is not -- it folds case and ignores punctuation, which reorders
# `LLD_jll` against `LibCURL` and `dSFMT_jll` against `Zlib_jll` and turns a
# clean pass into 30 lines of phantom diff.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

# `dirname(Sys.BINDIR)` is exactly what Pkg's own stdlib_dir() uses
# (utils.jl:30, spelled joinpath(Sys.BINDIR, "..")).
PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')
STDLIB_DIR=$(julia -e 'using Pkg; print(Pkg.Types.stdlib_dir())')
DIR_ENTRIES=$(find "$STDLIB_DIR" -mindepth 1 -maxdepth 1 | wc -l)
echo "prefix : $PREFIX"
echo "version: $JULIA_VERSION"
echo "stdlibs: $STDLIB_DIR ($DIR_ENTRIES directory entries)"

WORK="$(mktemp -d -t ajt-stdlibs-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- oracle -----------------------------------------------------------------
echo "==> Julia oracle"
julia -e '
using Pkg
infos = Pkg.Types.stdlib_infos()
rows = String[]
for (u, (n, v)) in Pkg.Types.stdlibs()
    i = infos[u]
    push!(rows, string("stdlib ", n, " ", u, " ", v === nothing ? "-" : v,
                       " ", length(i.deps), " ", length(i.weakdeps)))
end
foreach(println, sort(rows))
' > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

# UPGRADABLE_STDLIBS_UUIDS is populated as a side effect of load_stdlib
# (Types.jl:502, 514-516), so stdlib_infos() must be forced first.
julia -e '
using Pkg
Pkg.Types.stdlib_infos()
println("names ", join(sort(Pkg.Types.UPGRADABLE_STDLIBS), ","))
for u in sort(collect(Pkg.Types.UPGRADABLE_STDLIBS_UUIDS), by=string)
    println("uuid ", u, " is_stdlib=", Pkg.Types.is_stdlib(u))
end
' > "$WORK/julia_upgradable.txt" 2>>"$WORK/julia.err" || {
  echo "ERROR: upgradable oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

# --- ajt --------------------------------------------------------------------
echo "==> ajt"
# The cache dirs are per-run and inside $WORK on purpose. `zig run`'s manifest
# is keyed on the -M root paths as given (relative to cwd) while recording its
# transitive inputs by ABSOLUTE path, so two checkouts of this repo -- the main
# one and any .claude/worktrees/ agent tree -- collide in ~/.cache/zig and one
# silently executes the other's binary. That produced both a false PASS on a
# mutated source and a false FAIL on a clean one. A hermetic cache costs a few
# seconds of compile and removes the entire failure mode.
#
# Audit note (zig 0.16.0, this host): a later attempt to reproduce the collision
# deliberately -- two trees, identical -M strings, differing dependency module,
# with the local cache shared, the global cache shared, and both sequential and
# concurrent -- did NOT reproduce it in any configuration. Treat the hermetic
# cache as the cheap invariant it is rather than as a fix whose trigger is
# understood; every zig-invoking harness here now sets both dirs the same way.
( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/stdlibs_dump.zig -Majt=src/root.zig \
    -- "$PREFIX" "$JULIA_VERSION" ) > "$WORK/ajt_all.txt" 2>"$WORK/ajt.err" || {
  echo "ERROR: ajt dump failed" >&2; tail -20 "$WORK/ajt.err" >&2; exit 2; }

grep '^stdlib '     "$WORK/ajt_all.txt" | sort > "$WORK/ajt.txt"
grep '^upgradable ' "$WORK/ajt_all.txt" | sort > "$WORK/ajt_upgradable.txt"

status=0

# --- 1: same installation ---------------------------------------------------
AJT_DIR=$(awk '$1=="dir" {print $2}' "$WORK/ajt_all.txt")
if [ "$AJT_DIR" != "$STDLIB_DIR" ]; then
  echo "FAIL: ajt read a different directory than Pkg.Types.stdlib_dir()" >&2
  echo "  julia: $STDLIB_DIR" >&2
  echo "  ajt  : $AJT_DIR" >&2
  status=1
fi

# --- 2: the UPGRADABLE_STDLIBS list itself ----------------------------------
JULIA_UPG_NAMES=$(awk '$1=="names" {print $2}' "$WORK/julia_upgradable.txt")
AJT_UPG_NAMES=$(awk '$1=="names" {print $2}' "$WORK/ajt_all.txt")
if [ "$AJT_UPG_NAMES" != "$JULIA_UPG_NAMES" ]; then
  echo "FAIL: UPGRADABLE_STDLIBS list differs" >&2
  echo "  julia: $JULIA_UPG_NAMES" >&2
  echo "  ajt  : $AJT_UPG_NAMES" >&2
  status=1
fi

# --- 3/4: the fixed set -----------------------------------------------------
echo "==> comparing the fixed set"
JN=$(wc -l < "$WORK/julia.txt")
AN=$(wc -l < "$WORK/ajt.txt")
echo "  julia: $JN entries"
echo "  ajt  : $AN entries"

if [ "$JN" -ne "$AN" ]; then
  echo "FAIL: count mismatch ($JN vs $AN)" >&2
  status=1
fi

if ! diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  status=1
  echo >&2
  echo "FAIL: symmetric difference (< julia, > ajt):" >&2
  diff "$WORK/julia.txt" "$WORK/ajt.txt" >&2
  # Name/uuid-only view, so a pure version or dep-count drift is not confused
  # with a genuinely missing or extra stdlib.
  cut -d' ' -f2,3 "$WORK/julia.txt" | sort > "$WORK/julia_ids.txt"
  cut -d' ' -f2,3 "$WORK/ajt.txt"   | sort > "$WORK/ajt_ids.txt"
  if ! diff -q "$WORK/julia_ids.txt" "$WORK/ajt_ids.txt" >/dev/null; then
    echo >&2
    echo "  (name, uuid) set differs:" >&2
    comm -23 "$WORK/julia_ids.txt" "$WORK/ajt_ids.txt" | sed 's/^/    missing from ajt: /' >&2
    comm -13 "$WORK/julia_ids.txt" "$WORK/ajt_ids.txt" | sed 's/^/    extra in ajt   : /' >&2
  else
    echo "  ((name, uuid) sets agree; the divergence is in version/deps)" >&2
  fi
fi

# --- 5: classification ------------------------------------------------------
echo "==> checking UPGRADABLE_STDLIBS"
# Driven by Julia's list, plus DelimitedFiles and Statistics named explicitly
# so the gate still fails if BOTH sides were to drop one.
UPG_NAMES=$(printf '%s\n' "$JULIA_UPG_NAMES" | tr ',' '\n' | grep -v '^$')
for name in $UPG_NAMES DelimitedFiles Statistics; do
  if ! grep -q "^upgradable $name " "$WORK/ajt_upgradable.txt"; then
    echo "FAIL: $name is not reported as upgradable" >&2
    status=1
    continue
  fi
  if grep -q "^stdlib $name " "$WORK/ajt.txt"; then
    echo "FAIL: $name leaked into the fixed stdlib set" >&2
    status=1
  fi
  # And Julia agrees it is not a stdlib.
  uuid=$(awk -v n="$name" '$1=="upgradable" && $2==n {print $3}' "$WORK/ajt_upgradable.txt")
  if ! grep -q "^uuid $uuid is_stdlib=false" "$WORK/julia_upgradable.txt"; then
    echo "FAIL: julia does not report $name ($uuid) as an upgradable non-stdlib" >&2
    cat "$WORK/julia_upgradable.txt" >&2
    status=1
  fi
done

# A core stdlib must be on the other side of the line.
if ! grep -q '^stdlib LinearAlgebra ' "$WORK/ajt.txt"; then
  echo "FAIL: LinearAlgebra is missing from the fixed stdlib set" >&2
  status=1
fi
if grep -q '^upgradable LinearAlgebra ' "$WORK/ajt_upgradable.txt"; then
  echo "FAIL: LinearAlgebra is reported as upgradable" >&2
  status=1
fi

EXPECT_UPG=$(printf '%s\n' "$UPG_NAMES" | wc -l)
UN=$(wc -l < "$WORK/ajt_upgradable.txt")
if [ "$UN" -ne "$EXPECT_UPG" ]; then
  echo "FAIL: expected $EXPECT_UPG upgradable stdlibs, got $UN" >&2
  cat "$WORK/ajt_upgradable.txt" >&2
  status=1
fi

echo
if [ "$status" -ne 0 ]; then
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi
echo "PASS — $AN stdlibs identical to Pkg.Types.stdlibs() (name, uuid, version,"
echo "       deps/weakdeps counts) out of $DIR_ENTRIES directory entries, plus"
echo "       $UN correctly excluded UPGRADABLE_STDLIBS ($JULIA_UPG_NAMES)"
