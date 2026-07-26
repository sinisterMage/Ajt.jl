#!/usr/bin/env bash
# Differential gate for the git tree hash.
#
# `ajt tree-hash <dir>` must equal `Pkg.GitTools.tree_hash(dir)` for every
# installed package and artifact in a real depot. This is the check that makes
# the installer trustworthy: the registry pins a `git-tree-sha1` per version,
# and an install is only verifiable if Ajt computes that value the same way
# Julia does -- including the empty-directory pruning, the exec-bit rule, and
# the sort-directories-as-if-suffixed-with-slash rule.
#
# Usage: tools/diff_harness/treehash.sh [--limit N] [--artifacts] [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

LIMIT=0
WITH_ARTIFACTS=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --artifacts) WITH_ARTIFACTS=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }
[ -d "$DEPOT/packages" ] || { echo "ERROR: no packages under $DEPOT" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-tree-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

LIST="$WORK/dirs.txt"
find "$DEPOT/packages" -mindepth 2 -maxdepth 2 -type d > "$LIST"
if [ $WITH_ARTIFACTS -eq 1 ] && [ -d "$DEPOT/artifacts" ]; then
  find "$DEPOT/artifacts" -mindepth 1 -maxdepth 1 -type d >> "$LIST"
fi
sort -u "$LIST" -o "$LIST"
[ "$LIMIT" -gt 0 ] && { head -n "$LIMIT" "$LIST" > "$LIST.t" && mv "$LIST.t" "$LIST"; }
TOTAL=$(wc -l < "$LIST")
[ "$TOTAL" -gt 0 ] || { echo "ERROR: nothing to hash" >&2; exit 2; }
echo "corpus: $TOTAL directories"

echo "==> ajt"
"$AJT_BIN" tree-hash --filelist "$LIST" | sort -k2 > "$WORK/ajt.txt"

echo "==> Julia oracle"
julia -e '
using Pkg
for line in eachline(ARGS[1])
    isempty(line) && continue
    try
        println(bytes2hex(Pkg.GitTools.tree_hash(line)), "  ", line)
    catch e
        println("ERROR  ", line)
    end
end' "$LIST" | sort -k2 > "$WORK/julia.txt"

echo "==> comparing"
if diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  echo
  echo "PASS — ajt tree-hash matches Pkg.GitTools.tree_hash across $TOTAL directories"
  exit 0
fi

mismatch=$(diff "$WORK/julia.txt" "$WORK/ajt.txt" | grep -c '^<' || true)
echo
echo "  divergent : $mismatch of $TOTAL"
echo
echo "First divergences (julia | ajt):"
diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -20
[ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect)"
exit 1
