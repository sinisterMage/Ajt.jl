#!/usr/bin/env bash
# Differential gate for registry reading.
#
# Compares `ajt registry show <pkg>` against Julia's own registry API, for the
# thing a resolver actually consumes: every version's UNCOMPRESSED dependency
# set and compat specs.
#
# This is the gate for the `first..last` span rule in `uncompress`
# (registry_instance.jl:70-102). The intuitive reading of that function --
# "apply the entry to every version satisfying the range" -- produces identical
# output for packages whose version lists are contiguous, and differs only for
# the ones where a non-satisfying version sits between two satisfying ones.
# Sampling broadly is therefore the point; a handful of packages proves little.
#
# Usage:
#   tools/diff_harness/registry_deps.sh [Package...]      # explicit packages
#   tools/diff_harness/registry_deps.sh --sample 200      # random-ish sample
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"

SAMPLE=0
PKGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PKGS+=("$1"); shift ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-reg-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [ "$SAMPLE" -gt 0 ]; then
  # Every Nth package by name, so the sample is deterministic and spread across
  # the alphabet rather than clustered.
  "$AJT_BIN" registry status >/dev/null || exit 2
  julia -e '
    using Pkg
    reg = first(filter(r -> r.name == "General", Pkg.Registry.reachable_registries()))
    names = sort([pe.name for (_, pe) in reg.pkgs])
    n = parse(Int, ARGS[1])
    step = max(1, div(length(names), n))
    for i in 1:step:length(names); println(names[i]); end
  ' "$SAMPLE" > "$WORK/pkgs.txt"
  mapfile -t PKGS < "$WORK/pkgs.txt"
fi

[ ${#PKGS[@]} -gt 0 ] || PKGS=(StaticArrays GeometryBasics ColorTypes FileIO Ark GLFW ImageIO)
echo "corpus: ${#PKGS[@]} packages"

echo "==> Julia oracle"
julia "$HERE/registry_deps.jl" "${PKGS[@]}" > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

echo "==> ajt"
# One invocation for the whole corpus: loading General costs ~1.6s, so a
# process per package would dominate the run.
"$AJT_BIN" registry show "${PKGS[@]}" 2>/dev/null \
  | sed -e 's/^\([0-9][^ ]*\)  .*/\1/' > "$WORK/ajt.txt"

echo "==> comparing"
if diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  vers=$(grep -cE '^[0-9]' "$WORK/julia.txt" || true)
  echo
  echo "PASS — deps + compat identical across ${#PKGS[@]} packages / $vers versions"
  exit 0
fi

echo
echo "  divergences:"
diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -40
exit 1
