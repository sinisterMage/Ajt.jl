#!/usr/bin/env bash
# Differential gate for the `.ji` precompile-cache header parser and the L1
# staleness verifier (`src/cache/jicache.zig`).
#
# WHY this gate exists, and why it takes the whole depot rather than a sample:
#
# The shared precompile cache imports `.ji` objects built on other machines.
# The `.ji` header has no specification -- the only definition is the C that
# writes it and the Julia that reads it -- and every field in it is a number
# that looks plausible when parsed wrongly. A UUID whose halves are swapped is
# still a UUID. A crc32c read from the wrong offset is still a crc32c. Nothing
# about a wrong parse announces itself; the symptom is that Julia silently
# recompiles a package that should have been reused, and that symptom is
# indistinguishable from a cold cache.
#
# So the only useful oracle is Julia's own reader, and the only useful sample
# size is "all of it": several hundred `.ji` files on a working host (767 when
# this gate was written), thousands of includes, covering stdlibs, jlls,
# extensions, dev-path packages, plain non-pkgimage caches and compile-time
# preferences. Anything less and the one file with a `requires` record or a
# non-`@depot` include is the one that is not checked.
#
# What is compared:
#   1. `jl_match_cache_flags` over ALL 65536 (requested, actual) pairs, ccall'd
#      from Julia against `matchCacheFlags`. That function is C with no Julia
#      mirror; the Zig version was derived from this table, so re-deriving it is
#      the only way to know it is still right.
#   2. Every `.ji` under the depot's `compiled/`, field by field, against
#      `Base._parse_cache_header` (raw) AND `Base.parse_cache_header`
#      (`@depot`-restored) -- preamble, flags, module list, includes with
#      fsize/crc/mtime bits/modpath/src-vs-dep, requires, preferences,
#      prefs_hash, srctextpos, required_modules with their 128-bit build ids,
#      clone targets, the source-text file set, `isrelocatable`, and
#      `isvalid_file_crc`.
#   3. One include's recorded crc32c flipped in a COPY, with the file's own
#      trailing crc32c re-sealed so that the include hash is the ONLY thing
#      wrong. Both `Base.stale_cachefile` and ajt must reject it, and must
#      reject it for the same reason -- agreeing that "something is broken" is
#      not agreement.
#   4. An unresolvable `@depot` tag, checked from both sides against a depot
#      that contains nothing. This is the property that makes optimistic
#      importing safe at all: the tag is rejected, never guessed at, so the
#      worst case is the recompile that would have happened anyway.
#   5. Reported, not asserted: how many of the depot's `.ji` files are
#      `isrelocatable` and how many carry mtime-tracked `include_dependency`
#      entries. Those two numbers say how much of a depot is publishable.
#
# Usage: tools/diff_harness/jicache.sh [--keep] [--limit N]
set -uo pipefail

# Julia sorts strings by byte; GNU sort under a UTF-8 locale does not, and the
# file list must be identical on both sides.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
LIMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)  KEEP=1; shift ;;
    --limit)
      # `shift 2` with only one positional left fails SILENTLY (`-e` is off on
      # purpose), $# never reaches 0, and the loop spins forever.
      [ $# -ge 2 ] || { echo "--limit needs a value" >&2; exit 2; }
      LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- prerequisites ----------------------------------------------------------
skip() {
  echo
  echo "############################################################"
  echo "# SKIP: $*"
  echo "# This gate needs a real julia and a populated precompile"
  echo "# cache; there is nothing to compare against without one."
  echo "############################################################"
  exit 0
}

command -v julia >/dev/null || skip "julia is not on PATH"
command -v zig   >/dev/null || skip "zig is not on PATH"

DEPOT1=$(julia --startup-file=no -e 'print(first(DEPOT_PATH))' 2>/dev/null) || \
  skip "could not ask julia for DEPOT_PATH"
DEPOTS=$(julia --startup-file=no -e 'print(join(DEPOT_PATH, ":"))')
JULIA_VERSION=$(julia --startup-file=no -e 'print(VERSION)')
# The five strings `jl_read_verify_header` compares byte for byte. ajt's
# `PreambleExpectation` has no default, so these must come from the same julia
# the .ji files were built by -- which is the whole point of comparing them.
read -r JL_UNAME JL_ARCH JL_VER JL_BRANCH JL_COMMIT <<<"$(julia --startup-file=no -e '
print(Sys.KERNEL, " ", Sys.ARCH, " ", Base.VERSION, " ",
      Base.GIT_VERSION_INFO.branch, " ", Base.GIT_VERSION_INFO.commit)')"
[ -n "${JL_COMMIT:-}" ] || skip "could not read this julia's identity strings"

COMPILED="$DEPOT1/compiled"
[ -d "$COMPILED" ] || skip "no compiled cache at $COMPILED"

WORK="$(mktemp -d -t ajt-jicache-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

find "$COMPILED" -name '*.ji' -type f | sort > "$WORK/all.txt"
NFILES=$(wc -l < "$WORK/all.txt")
[ "$NFILES" -gt 0 ] || skip "no .ji files under $COMPILED"

if [ "$LIMIT" -gt 0 ]; then
  head -n "$LIMIT" "$WORK/all.txt" > "$WORK/list.txt"
else
  cp "$WORK/all.txt" "$WORK/list.txt"
fi
N=$(wc -l < "$WORK/list.txt")

echo "julia   : $JULIA_VERSION"
echo "depots  : $DEPOTS"
echo "cache   : $COMPILED"
echo "files   : $N of $NFILES .ji"

status=0
ok=0
bad=0

# Hermetic zig caches, for the reason spelled out in stdlibs.sh: `zig run`'s
# manifest is keyed on the -M paths as given while recording its inputs by
# absolute path, so two checkouts of this repo can collide in ~/.cache/zig.
ZIGRUN=( zig run --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global"
         --dep ajt -Mroot=tools/diff_harness/jicache_dump.zig -Majt=src/root.zig -- )
IDENT=( "$JL_UNAME" "$JL_ARCH" "$JL_VER" "$JL_BRANCH" "$JL_COMMIT" )

# --- 1: jl_match_cache_flags, all 65536 pairs -------------------------------
echo
echo "==> jl_match_cache_flags truth table (65536 pairs)"
julia --startup-file=no "$HERE/jicache_oracle.jl" "$WORK/list.txt" flags \
  > "$WORK/flags_julia.txt" 2>"$WORK/flags.err" || {
  echo "FAIL: could not ccall jl_match_cache_flags" >&2
  tail -5 "$WORK/flags.err" >&2
  status=1
}
( cd "$AJT_ROOT" && "${ZIGRUN[@]}" "$WORK/list.txt" "$DEPOTS" flags ) \
  > "$WORK/flags_ajt.txt" 2>"$WORK/flags_ajt.err" || {
  echo "FAIL: ajt flag dump failed" >&2; tail -20 "$WORK/flags_ajt.err" >&2; status=1; }

if [ ! -s "$WORK/flags_julia.txt" ] || [ ! -s "$WORK/flags_ajt.txt" ]; then
  # An empty dump is a FAILURE, not a reason to skip. Without this the script
  # would go on to print "PASS -- 65536/65536 flag pairs" having compared none.
  bad=$((bad + 1)); status=1
  echo "FAIL: one side produced no flag table at all" >&2
elif diff -q "$WORK/flags_julia.txt" "$WORK/flags_ajt.txt" >/dev/null; then
  ok=$((ok + 1))
  echo "  ok: all 65536 pairs agree"
else
  bad=$((bad + 1)); status=1
  echo "FAIL: matchCacheFlags disagrees with jl_match_cache_flags" >&2
  diff "$WORK/flags_julia.txt" "$WORK/flags_ajt.txt" | head -20 >&2
fi

# --- 2: every .ji, field by field -------------------------------------------
echo
echo "==> parsing $N .ji files on both sides"
julia --startup-file=no "$HERE/jicache_oracle.jl" "$WORK/list.txt" dump \
  > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -20 "$WORK/julia.err" >&2; exit 2; }

( cd "$AJT_ROOT" && "${ZIGRUN[@]}" "$WORK/list.txt" "$DEPOTS" dump ) \
  > "$WORK/ajt.txt" 2>"$WORK/ajt.err" || {
  echo "ERROR: ajt dump failed" >&2; tail -20 "$WORK/ajt.err" >&2; exit 2; }

JLINES=$(wc -l < "$WORK/julia.txt")
ALINES=$(wc -l < "$WORK/ajt.txt")
echo "  julia: $JLINES record lines"
echo "  ajt  : $ALINES record lines"

# Any parse error on either side is a failure in its own right: a `.ji` that
# ajt refuses to read is a cache entry the shared cache can never serve.
JERR=$(grep -c $'^error\t' "$WORK/julia.txt" || true)
AERR=$(grep -c $'^error\t' "$WORK/ajt.txt" || true)
if [ "$AERR" -ne 0 ]; then
  bad=$((bad + 1)); status=1
  echo "FAIL: ajt failed to parse $AERR file(s)" >&2
  grep -B1 $'^error\t' "$WORK/ajt.txt" | head -20 >&2
fi
[ "$JERR" -ne 0 ] && echo "  (julia itself reported $JERR unreadable file(s))"

if diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  ok=$((ok + 1))
  echo "  ok: every field of every .ji is identical"
else
  bad=$((bad + 1)); status=1
  echo "FAIL: header dumps differ (< julia, > ajt)" >&2
  diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -60 >&2
  echo >&2
  echo "  files that disagreed:" >&2
  # Attribute each differing line to the `=== <path>` header above it.
  awk 'BEGIN{f=""} /^=== /{f=$2} {print f"\t"$0}' "$WORK/julia.txt" > "$WORK/julia_tagged.txt"
  awk 'BEGIN{f=""} /^=== /{f=$2} {print f"\t"$0}' "$WORK/ajt.txt"   > "$WORK/ajt_tagged.txt"
  diff "$WORK/julia_tagged.txt" "$WORK/ajt_tagged.txt" \
    | grep '^[<>]' | cut -f1 | sed 's/^[<>] //' | sort -u | head -20 >&2
fi

# --- 3: a flipped include crc32c, rejected by both --------------------------
echo
echo "==> corrupting one include's crc32c in a copy"
mkdir -p "$WORK/copy"
# Deliberately the FULL list, not the `--limit`ed one: the control has to be a
# `.ji` that julia considers FRESH, and most of a depot is stale for reasons
# that have nothing to do with this gate (its deps are not in the active
# project). `--limit` is a debugging aid and must not change what is proven.
julia --startup-file=no "$HERE/jicache_oracle.jl" "$WORK/copy" corrupt "$WORK/all.txt" \
  > "$WORK/corrupt.txt" 2>"$WORK/corrupt.err" || {
  echo "ERROR: corruption oracle failed" >&2; tail -20 "$WORK/corrupt.err" >&2; exit 2; }

if grep -q '^nocandidate' "$WORK/corrupt.txt"; then
  bad=$((bad + 1)); status=1
  echo "FAIL: no .ji in the depot is fresh enough to corrupt as a control" >&2
else
  SRC=$(awk -F'\t' '$1=="source"{print $2}' "$WORK/corrupt.txt")
  CLEAN=$(awk -F'\t' '$1=="clean"{print $2}' "$WORK/corrupt.txt")
  BADJI=$(awk -F'\t' '$1=="bad"{print $2}' "$WORK/corrupt.txt")
  JBAD=$(awk -F'\t' '$1=="julia_bad_stale"{print $2}' "$WORK/corrupt.txt")
  JBADR=$(awk -F'\t' '$1=="julia_bad_stale"{print $3}' "$WORK/corrupt.txt")
  echo "  subject: $SRC"
  echo "  julia   : clean=fresh  bad=stale($JBAD) reasons=[$JBADR]"

  printf '%s\n%s\n' "$CLEAN" "$BADJI" > "$WORK/pair.txt"
  ( cd "$AJT_ROOT" && "${ZIGRUN[@]}" "$WORK/pair.txt" "$DEPOTS" verify "${IDENT[@]}" ) \
    > "$WORK/pair_ajt.txt" 2>"$WORK/pair_ajt.err" || {
    echo "ERROR: ajt verify failed" >&2; tail -20 "$WORK/pair_ajt.err" >&2; exit 2; }

  AC=$(awk -F'\t' '/^=== /{f=$0} $1=="verdict"{print $2; exit}' "$WORK/pair_ajt.txt")
  AB=$(awk -F'\t' '$1=="verdict"{v[++n]=$2; r[n]=$3} END{print v[2]"\t"r[2]}' "$WORK/pair_ajt.txt")
  AB_VERDICT=$(printf '%s' "$AB" | cut -f1)
  AB_REASON=$(printf '%s' "$AB" | cut -f2)
  echo "  ajt     : clean=$AC  bad=$AB_VERDICT reason=[$AB_REASON]"

  # (a) both accept the pristine copy -- otherwise a rejection proves nothing.
  if [ "$AC" != "fresh" ]; then
    bad=$((bad + 1)); status=1
    echo "FAIL: ajt rejected the PRISTINE copy" >&2
    grep $'^verdict' "$WORK/pair_ajt.txt" | head -2 >&2
  else
    ok=$((ok + 1))
  fi
  # (b) julia rejects the corrupted copy, for the include hash.
  if [ "$JBAD" != "1" ]; then
    bad=$((bad + 1)); status=1
    echo "FAIL: Base.stale_cachefile accepted the corrupted copy" >&2
  elif ! printf '%s' "$JBADR" | grep -q 'include_dependency fhash change'; then
    bad=$((bad + 1)); status=1
    echo "FAIL: julia rejected the corrupted copy for [$JBADR], not the include hash" >&2
  else
    ok=$((ok + 1))
  fi
  # (c) ajt rejects it, with the SAME reason string.
  if [ "$AB_VERDICT" != "stale" ]; then
    bad=$((bad + 1)); status=1
    echo "FAIL: ajt accepted the corrupted copy" >&2
  elif [ "$AB_REASON" != "include_dependency fhash change" ]; then
    bad=$((bad + 1)); status=1
    echo "FAIL: ajt rejected for '$AB_REASON', julia for the include hash" >&2
  else
    ok=$((ok + 1))
    echo "  ok: both reject the corrupted copy as 'include_dependency fhash change'"
  fi
fi

# --- 4: an unresolvable @depot tag ------------------------------------------
echo
echo "==> an @depot tag that resolves nowhere"
mkdir -p "$WORK/emptydepot"
# One relocatable file is enough, and it must be relocatable or the tag would
# never have been written in the first place.
# `=== <path>` is space-separated while the records are tab-separated, so this
# must run with the DEFAULT FS and match the record line literally.
awk '/^=== /{f=$2} /^reloc\t1$/{print f; exit}' "$WORK/ajt.txt" > "$WORK/reloc_one.txt"

if [ ! -s "$WORK/reloc_one.txt" ]; then
  echo "  (no relocatable .ji in this depot; nothing to check)"
else
  RELOC=$(cat "$WORK/reloc_one.txt")
  echo "  subject: $RELOC"
  julia --startup-file=no "$HERE/jicache_oracle.jl" "$WORK/reloc_one.txt" depot "$WORK/emptydepot" \
    > "$WORK/depot_julia.txt" 2>"$WORK/depot.err" || {
    echo "ERROR: depot oracle failed" >&2; tail -20 "$WORK/depot.err" >&2; exit 2; }
  JSTALE=$(awk -F'\t' '$1=="depotcheck"{print $3}' "$WORK/depot_julia.txt")
  JREASON=$(awk -F'\t' '$1=="depotcheck"{print $4}' "$WORK/depot_julia.txt")

  ( cd "$AJT_ROOT" && "${ZIGRUN[@]}" "$WORK/reloc_one.txt" "$WORK/emptydepot" verify "${IDENT[@]}" ) \
    > "$WORK/depot_ajt.txt" 2>"$WORK/depot_ajt.err" || {
    echo "ERROR: ajt depot verify failed" >&2; tail -20 "$WORK/depot_ajt.err" >&2; exit 2; }
  AVERDICT=$(awk -F'\t' '$1=="verdict"{print $2; exit}' "$WORK/depot_ajt.txt")
  AREASON=$(awk -F'\t' '$1=="verdict"{print $3; exit}' "$WORK/depot_ajt.txt")

  echo "  julia   : stale=$JSTALE reasons=[$JREASON]"
  echo "  ajt     : $AVERDICT reason=[$AREASON]"
  if [ "$JSTALE" = "1" ] && [ "$JREASON" = "nonresolveable depot" ] \
     && [ "$AVERDICT" = "stale" ] && [ "$AREASON" = "nonresolveable depot" ]; then
    ok=$((ok + 1))
    echo "  ok: both reject it as 'nonresolveable depot' -- never a guess, so a"
    echo "      bad import can only ever cost a recompile"
  else
    bad=$((bad + 1)); status=1
    echo "FAIL: the two sides do not agree that an unplaceable @depot tag is fatal" >&2
  fi
fi

# --- 5: what this depot could publish ---------------------------------------
echo
echo "==> publishability of this depot"
NRELOC=$(grep -c $'^reloc\t1$' "$WORK/ajt.txt" || true)
NNOTRELOC=$(grep -c $'^reloc\t0$' "$WORK/ajt.txt" || true)
NMTIME=$(awk -F'\t' '$1=="mtimetracked" && $2>0' "$WORK/ajt.txt" | wc -l)
NMTIME_ENTRIES=$(awk -F'\t' '$1=="mtimetracked"{s+=$2} END{print s+0}' "$WORK/ajt.txt")
echo "  isrelocatable            : $NRELOC of $N"
echo "  NOT relocatable          : $NNOTRELOC  (absolute include paths -- a"
echo "                             package developed out of a working tree)"
echo "  with mtime-tracked deps  : $NMTIME file(s), $NMTIME_ENTRIES entr(y|ies)"
echo "  => publishable today     : $NRELOC of $N"

# Every check that was supposed to run must have reported. Counting them is
# what stops a silently skipped section from reading as a pass.
EXPECT_OK=6
if [ "$ok" -ne "$EXPECT_OK" ] && [ "$status" -eq 0 ]; then
  echo "FAIL: only $ok of $EXPECT_OK checks reported -- one was silently skipped" >&2
  status=1
fi

echo
if [ "$status" -ne 0 ]; then
  echo "FAILED: $bad check(s) failed, $ok of $EXPECT_OK passed"
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi
echo "PASS — $ok/$EXPECT_OK checks: 65536/65536 flag pairs, $N/$N .ji files identical to"
echo "       Base.parse_cache_header field by field, and both verifiers agree"
echo "       on rejecting a flipped include crc32c and an unresolvable @depot."
