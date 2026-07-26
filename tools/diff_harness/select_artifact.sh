#!/usr/bin/env bash
# Differential gate for artifact platform selection.
#
# For every Artifacts.toml in the depot, compares which variant Ajt picks
# against Julia's `select_platform(download_info, HostPlatform())`. This is the
# code path that decides which binary a JLL actually installs, so picking the
# wrong one is the difference between a working engine and a dlopen failure.
#
# Two things are checked, in order:
#   1. Ajt's OWN host detection equals Julia's HostPlatform() tag set.
#   2. Given that host, Ajt picks the same artifact variant as Julia.
# Ajt's detection is used for step 2, so a detection regression fails the gate
# rather than being masked by borrowing Julia's answer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-artifact-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

find "$DEPOT/packages" -name 'Artifacts.toml' -o -name 'JuliaArtifacts.toml' \
  | sort > "$WORK/files.txt"
TOTAL=$(wc -l < "$WORK/files.txt")
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no Artifacts.toml under $DEPOT/packages" >&2; exit 2; }
echo "corpus: $TOTAL Artifacts.toml files"

# Step 1: Ajt's detection must agree with Julia's HostPlatform().
JULIA_HOST=$(julia -e '
using Base.BinaryPlatforms
p = HostPlatform()
println(join(["$k=$v" for (k, v) in sort(collect(tags(p)), by=first)], ","))')
JULIA_PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')
AJT_HOST=$("$AJT_BIN" host-platform --julia-prefix "$JULIA_PREFIX" --julia-version "$JULIA_VERSION")
if [ "$AJT_HOST" != "$JULIA_HOST" ]; then
  echo "FAIL: host detection diverges" >&2
  echo "  julia: $JULIA_HOST" >&2
  echo "  ajt  : $AJT_HOST" >&2
  exit 1
fi
echo "host (detected by ajt, matches julia): $AJT_HOST"
HOST_TAGS="$AJT_HOST"

echo "==> Julia oracle"
julia -e '
using Base.BinaryPlatforms, TOML
function main()
    host = HostPlatform()
    for f in eachline(ARGS[1])
        isempty(f) && continue
        d = try TOML.parsefile(f) catch; continue end
        for (name, entry) in sort(collect(d), by=first)
            if entry isa Vector
                cands = Dict{Platform,String}()
                for e in entry
                    e isa Dict || continue
                    (haskey(e, "os") && haskey(e, "arch") && haskey(e, "git-tree-sha1")) || continue
                    t = Dict{String,String}(k => v for (k, v) in e if v isa String)
                    delete!(t, "os"); delete!(t, "arch"); delete!(t, "git-tree-sha1")
                    cands[Platform(e["arch"], e["os"], t)] = e["git-tree-sha1"]
                end
                isempty(cands) && continue
                sel = select_platform(cands, host)
                println(name, "  ", sel === nothing ? "NONE" : sel)
            elseif entry isa Dict
                println(name, "  (unplatformed)")
            end
        end
    end
end
main()' "$WORK/files.txt" > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

echo "==> ajt"
# shellcheck disable=SC2046
"$AJT_BIN" select-artifact --host "$HOST_TAGS" $(cat "$WORK/files.txt") 2>/dev/null \
  | sort > "$WORK/ajt.txt"
sort "$WORK/julia.txt" -o "$WORK/julia.txt"

echo "==> comparing"
if diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  n=$(wc -l < "$WORK/julia.txt")
  echo
  echo "PASS — same artifact chosen for all $n entries across $TOTAL files"
  exit 0
fi

echo
echo "  divergences (julia | ajt):"
diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -30
exit 1
