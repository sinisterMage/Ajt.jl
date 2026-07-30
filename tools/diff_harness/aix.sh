#!/usr/bin/env bash
# Differential gate for the persistent binary registry index (.aix).
#
# The index exists to make repeat registry loads an mmap instead of a 1.6 s
# decompress-and-reparse. That is only worth anything if the two paths are
# indistinguishable, so this gate builds the index from the real
# ~/.julia/registries/General.tar.gz and then compares, package by package,
# what `ajt registry show` reports from the index against what it reports from
# the tarball: every version, its git-tree-sha1, its yanked flag, and its
# UNCOMPRESSED dependency set with compat specs.
#
# Anything less than byte identity is a failure. The direct path is itself
# gated against Julia by registry_deps.sh, so byte identity here chains through
# to "agrees with Julia"; pass --julia to also run that leg directly on this
# sample.
#
# Sample broadly. In this project the registry gate passed at 411 packages and
# only exposed a real divergence at 2,794, so the default here is 400 spread
# evenly across the alphabet, and --full (all 13,969) is the real answer.
#
# Usage:
#   tools/diff_harness/aix.sh                 # 400-package sample
#   tools/diff_harness/aix.sh --sample 2000
#   tools/diff_harness/aix.sh --full          # every package in the registry
#   tools/diff_harness/aix.sh --julia         # + compare against Julia itself
#   tools/diff_harness/aix.sh --keep-index    # do not rebuild an existing index
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"

SAMPLE=400
FULL=0
WITH_JULIA=0
REBUILD="--rebuild"
DEPOT="${JULIA_DEPOT_PATH:-}"; DEPOT="${DEPOT%%:*}"
[ -n "$DEPOT" ] || DEPOT="$HOME/.julia"

while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --julia) WITH_JULIA=1; shift ;;
    --keep-index) REBUILD=""; shift ;;
    --depot) DEPOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }
TARBALL="$DEPOT/registries/General.tar.gz"
[ -f "$TARBALL" ] || { echo "ERROR: $TARBALL missing — this gate needs a real depot" >&2; exit 2; }
[ -f "$DEPOT/registries/General.toml" ] || {
  echo "ERROR: $DEPOT/registries/General.toml missing — the index keys off its git-tree-sha1" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-aix-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Build the index from the real registry.
# ---------------------------------------------------------------------------
echo "==> building index from $TARBALL"
"$AJT_BIN" registry index --depot "$DEPOT" $REBUILD | tee "$WORK/index.txt" || exit 2
AIX_PATH=$(sed -n 's/^wrote  *//p;s/^up to date  *//p' "$WORK/index.txt" | head -1)
[ -n "$AIX_PATH" ] && [ -f "$AIX_PATH" ] || { echo "ERROR: no index written" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 2. Pick the corpus.
#
# Names come straight out of the tarball's Registry.toml rather than from Julia,
# so the identity half of this gate needs no julia at all. (`grep -oP` is
# deliberately NOT used here: on this 1.4 MB file it silently drops four
# entries, sed does not.)
# ---------------------------------------------------------------------------
tar -xzOf "$TARBALL" Registry.toml \
  | sed -n 's/^[^ ]* = {.*name = "\([^"]*\)".*/\1/p' \
  | LC_ALL=C sort > "$WORK/allnames.txt"
TOTAL=$(wc -l < "$WORK/allnames.txt")
[ "$TOTAL" -gt 0 ] || { echo "ERROR: could not list packages from Registry.toml" >&2; exit 2; }

if [ "$FULL" -eq 1 ]; then
  cp "$WORK/allnames.txt" "$WORK/pkgs.txt"
else
  # Every Nth name, so the sample is deterministic and spread across the whole
  # alphabet instead of clustered at one letter.
  awk -v n="$SAMPLE" -v total="$TOTAL" \
    'BEGIN { step = int(total / n); if (step < 1) step = 1 } (NR - 1) % step == 0' \
    "$WORK/allnames.txt" > "$WORK/pkgs.txt"
fi
mapfile -t PKGS < "$WORK/pkgs.txt"
echo "corpus: ${#PKGS[@]} of $TOTAL packages"
[ "${#PKGS[@]}" -ge 200 ] || { echo "ERROR: corpus below the 200-package floor" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 3. Same corpus through both backends, in one process each.
# ---------------------------------------------------------------------------
#
# `--detail` because the default output prints neither the package uuid/repo
# nor a dependency's uuid, so an encoder that resolved a dependency to the
# wrong UUID would sail through a comparison of the default shape.
echo "==> reading through the tarball (cold parse)"
"$AJT_BIN" registry show --detail --depot "$DEPOT" --source archive "${PKGS[@]}" > "$WORK/archive.txt" || exit 2
echo "==> reading through the index (mmap)"
"$AJT_BIN" registry show --detail --depot "$DEPOT" --source aix "${PKGS[@]}" > "$WORK/aix.txt" || exit 2

echo "==> comparing"
if ! diff -q "$WORK/archive.txt" "$WORK/aix.txt" >/dev/null; then
  echo
  echo "  divergences (archive < , aix >):"
  diff "$WORK/archive.txt" "$WORK/aix.txt" | head -40
  exit 1
fi

# A package the index cannot find would compare "MISSING == MISSING" and pass;
# assert the corpus actually produced data.
MISSING=$(grep -c '^MISSING ' "$WORK/aix.txt" || true)
[ "$MISSING" -eq 0 ] || { echo "ERROR: $MISSING package(s) not found in the index" >&2; exit 1; }
VERSIONS=$(grep -cE '^[0-9]' "$WORK/aix.txt" || true)

# ---------------------------------------------------------------------------
# 4. Optional: the same sample against Julia itself.
# ---------------------------------------------------------------------------
if [ "$WITH_JULIA" -eq 1 ]; then
  command -v julia >/dev/null || { echo "ERROR: --julia given but julia not on PATH" >&2; exit 2; }
  echo "==> Julia oracle"
  julia "$HERE/registry_deps.jl" "${PKGS[@]}" > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
    echo "ERROR: oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }
  # registry_deps.jl prints name+spec per dep and no tree hash, so re-read the
  # corpus in the default shape rather than trying to unpick --detail.
  "$AJT_BIN" registry show --depot "$DEPOT" --source aix "${PKGS[@]}" \
    | sed -e 's/^\([0-9][^ ]*\)  .*/\1/' > "$WORK/aix.norm.txt" || exit 2
  if ! diff -q "$WORK/julia.txt" "$WORK/aix.norm.txt" >/dev/null; then
    echo
    echo "  divergences from Julia (julia < , aix >):"
    diff "$WORK/julia.txt" "$WORK/aix.norm.txt" | head -40
    exit 1
  fi
  echo "    index matches Julia across ${#PKGS[@]} packages"
fi

# ---------------------------------------------------------------------------
# 5. Report the win. Measured, not asserted: `registry status` times its own
#    load and prints it, so the two numbers come from the same code path a real
#    command takes.
# ---------------------------------------------------------------------------
# `set -e` is deliberately off (the script reports its own diffs), so these
# captures are checked by hand: an empty one would otherwise print a PASS with
# a blank timing, which is exactly the shape of a silently-broken benchmark.
COLD=$("$AJT_BIN" registry status --depot "$DEPOT" --source archive | sed -n 's/^load  *//p')
WARM=$("$AJT_BIN" registry status --depot "$DEPOT" --source aix | sed -n 's/^load  *//p')
SIZE=$(wc -c < "$AIX_PATH")
[ -n "$COLD" ] && [ -n "$WARM" ] && [ -n "$SIZE" ] || {
  echo "ERROR: could not measure load times (index removed under us?)" >&2; exit 2; }

echo
echo "PASS — versions, tree hashes, yanked flags, deps and compat identical"
echo "       across ${#PKGS[@]} packages / $VERSIONS versions"
echo
echo "  index      $AIX_PATH"
echo "  size       $SIZE bytes"
echo "  load before $COLD   (decompress + tar index + TOML parse)"
echo "  load after  $WARM   (mmap)"
exit 0
