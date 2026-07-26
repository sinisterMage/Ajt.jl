#!/usr/bin/env bash
# M0 acceptance gate: `ajt fmt --sorted` must be byte-identical to
# `TOML.print(TOML.parsefile(f); sorted=true)` for every TOML file in the
# General registry and a real Julia depot.
#
# Byte identity is not required by anything at runtime -- Julia's loader only
# cares about semantics. It is used here because it is the sharpest signal
# available: any divergence in the parser's value model OR the emitter's
# layout rules shows up immediately, instead of hiding until some manifest
# round-trips wrong months later.
#
# Usage:
#   tools/diff_harness/toml_roundtrip.sh [corpus...] [--limit N] [--keep]
#
# Corpora (default: depot engine):
#   depot      ~/.julia/packages/**/*.toml          (~380 files)
#   engine     Open-Reality Project/Manifest + backend/priv
#   registry   every *.toml in General.tar.gz       (~59k files, minutes)
#
# Exit status is non-zero if any file diverges.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"
# Honour a stacked JULIA_DEPOT_PATH by taking its first entry, which is where
# Julia itself writes; fall back to the default depot.
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

LIMIT=0
KEEP=0
CORPORA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    depot|engine|registry) CORPORA+=("$1"); shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#CORPORA[@]} -gt 0 ] || CORPORA=(depot engine)

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-toml-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- collect the corpus -----------------------------------------------------
LIST="$WORK/files.txt"
: > "$LIST"

for c in "${CORPORA[@]}"; do
  case "$c" in
    depot)
      [ -d "$DEPOT/packages" ] && find "$DEPOT/packages" -name '*.toml' -type f >> "$LIST"
      ;;
    engine)
      find "$REPO_ROOT/Open-Reality" -maxdepth 2 -name '*.toml' -type f >> "$LIST"
      find "$REPO_ROOT/backend/priv" -name '*.toml' -type f 2>/dev/null >> "$LIST"
      ;;
    registry)
      # The registry ships as a compressed tarball and is normally never
      # unpacked (Pkg reads it in memory); unpack a scratch copy to get at the
      # 14k Versions/Deps/Compat files, which are the real corpus.
      REG="$DEPOT/registries/General.tar.gz"
      if [ -f "$REG" ]; then
        mkdir -p "$WORK/registry"
        tar -xzf "$REG" -C "$WORK/registry"
        find "$WORK/registry" -name '*.toml' -type f >> "$LIST"
      else
        echo "WARNING: $REG not found; skipping registry corpus" >&2
      fi
      ;;
  esac
done

sort -u "$LIST" -o "$LIST"
if [ "$LIMIT" -gt 0 ]; then head -n "$LIMIT" "$LIST" > "$LIST.tmp" && mv "$LIST.tmp" "$LIST"; fi
TOTAL=$(wc -l < "$LIST")
[ "$TOTAL" -gt 0 ] || { echo "ERROR: corpus is empty" >&2; exit 2; }
echo "corpus: $TOTAL files (${CORPORA[*]})"

# --- oracle -----------------------------------------------------------------
echo "==> Julia oracle"
julia "$HERE/oracle.jl" "$LIST" "$WORK/julia" || { echo "ERROR: oracle failed" >&2; exit 2; }

# --- ajt --------------------------------------------------------------------
echo "==> ajt fmt"
mkdir -p "$WORK/ajt"
i=0
ajt_failed=0
while IFS= read -r f; do
  i=$((i + 1))
  [ -f "$WORK/julia/$i.skip" ] && continue          # oracle couldn't parse it either
  if ! "$AJT_BIN" fmt --sorted "$f" > "$WORK/ajt/$i.out" 2> "$WORK/ajt/$i.err"; then
    ajt_failed=$((ajt_failed + 1))
    printf '%s\t%s\n' "$f" "$(head -1 "$WORK/ajt/$i.err")" >> "$WORK/parse_failures.txt"
  fi
done < "$LIST"

# --- compare ----------------------------------------------------------------
echo "==> comparing"
pass=0; fail=0; skipped=0
: > "$WORK/mismatches.txt"
i=0
while IFS= read -r f; do
  i=$((i + 1))
  if [ -f "$WORK/julia/$i.skip" ]; then skipped=$((skipped + 1)); continue; fi
  if [ ! -s "$WORK/ajt/$i.out" ] && [ -s "$WORK/ajt/$i.err" ]; then
    fail=$((fail + 1)); printf '%s\tajt-parse-error\n' "$f" >> "$WORK/mismatches.txt"; continue
  fi
  if cmp -s "$WORK/julia/$i.out" "$WORK/ajt/$i.out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf '%s\t%s\n' "$f" "$i" >> "$WORK/mismatches.txt"
  fi
done < "$LIST"

echo
echo "  identical : $pass"
echo "  divergent : $fail"
echo "  skipped   : $skipped (oracle could not parse)"
[ "$ajt_failed" -gt 0 ] && echo "  ajt parse failures: $ajt_failed"

if [ "$fail" -gt 0 ]; then
  echo
  echo "First divergences:"
  head -5 "$WORK/mismatches.txt" | while IFS=$'\t' read -r path idx; do
    echo "--- $path"
    [ "$idx" = "ajt-parse-error" ] && { cat "$WORK/ajt/$(grep -n "^$path" "$LIST" | cut -d: -f1).err" 2>/dev/null | head -3; continue; }
    diff <(cat "$WORK/julia/$idx.out") <(cat "$WORK/ajt/$idx.out") | head -12
  done
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — ajt fmt is byte-identical to Julia's TOML.print across $pass files"
