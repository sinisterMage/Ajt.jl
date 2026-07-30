#!/usr/bin/env bash
# Differential gate for the Artifacts.toml MODEL.
#
# `select_artifact.sh` already gates the platform SELECTION over the same
# corpus: given a host, which variant wins. This gate is the deeper one — it
# checks everything the installer actually consumes once a variant has won:
#
#   * the selected entry's `git-tree-sha1` AND every `[[X.download]]`'s
#     url/sha256, in file order (Julia tries download sources in order);
#   * `lazy` and the presence of a `download` stanza, i.e. exactly what
#     `select_downloadable_artifacts` filters on;
#   * platform-independent (bare table) artifacts, which never go through
#     platform selection at all;
#   * `Platform`-constructor normalisation (auto `call_abi`/`libc`, arch
#     aliases, case, VersionNumber rounding), which changes `match_loss` and
#     therefore changes WHICH variant wins;
#   * `Overrides.toml` — hash->path, hash->hash, un-override, depot precedence
#     and UUID/name overrides — against Julia's own `artifact_path` /
#     `artifact_exists`;
#   * `find_artifacts_toml`'s JuliaArtifacts.toml-beats-Artifacts.toml order.
#
# The 83-file depot corpus is homogeneous (no lazy artifact, no artifact
# without a download stanza, no override anywhere), so it alone cannot gate any
# of that. The synthetic fixtures below exist to cover what the depot does not
# — and they are still checked against Julia, never against hand-written
# expectations.
#
# The oracle is `Artifacts` (the Base stdlib); `Pkg.Artifacts` re-exports the
# same `artifact_meta`/`select_downloadable_artifacts`/`artifact_path`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-artifacts-model-XXXXXX)"
# KEEP_WORK=1 leaves the fixtures, the fake depots and both sides' output
# behind; that is the only practical way to look at a divergence.
if [ "${KEEP_WORK:-0}" = "1" ]; then
  echo "work dir: $WORK"
else
  trap 'rm -rf "$WORK"' EXIT
fi

FAILURES=0
report() { # name julia_file ajt_file
  if diff -q "$2" "$3" >/dev/null; then
    echo "  PASS  $1 ($(wc -l < "$2") records)"
  else
    echo "  FAIL  $1" >&2
    echo "  divergences (< julia | > ajt):" >&2
    diff "$2" "$3" | head -30 >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# Host. Ajt's OWN detection is used for every comparison below, so a detection
# regression fails this gate instead of being masked by borrowing Julia's.
# ---------------------------------------------------------------------------
JULIA_HOST=$(julia -e '
using Base.BinaryPlatforms
p = HostPlatform()
println(join(["$k=$v" for (k, v) in sort(collect(tags(p)), by=first)], ","))')
JULIA_PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')
HOST_TAGS=$("$AJT_BIN" host-platform --julia-prefix "$JULIA_PREFIX" --julia-version "$JULIA_VERSION")
if [ "$HOST_TAGS" != "$JULIA_HOST" ]; then
  echo "FAIL: host detection diverges" >&2
  echo "  julia: $JULIA_HOST" >&2
  echo "  ajt  : $HOST_TAGS" >&2
  exit 1
fi
echo "host: $HOST_TAGS"

# ---------------------------------------------------------------------------
# Corpus + fixtures
# ---------------------------------------------------------------------------
find "$DEPOT/packages" -name 'Artifacts.toml' -o -name 'JuliaArtifacts.toml' \
  | sort > "$WORK/corpus.txt"
TOTAL=$(wc -l < "$WORK/corpus.txt")
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no Artifacts.toml under $DEPOT/packages" >&2; exit 2; }
echo "corpus: $TOTAL Artifacts.toml files"

FIX="$WORK/fixtures"
mkdir -p "$FIX"

# Lazy / download-less / eager. `lazy` is a Bool, so `unpack_platform` skips it
# as a non-String value while `select_downloadable_artifacts` still sees it.
cat > "$FIX/lazy.toml" <<'EOF'
[[Eager]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "1111111111111111111111111111111111111111"

    [[Eager.download]]
    url = "https://example.invalid/eager.tar.gz"
    sha256 = "aa11"

[[LazyOne]]
arch = "x86_64"
os = "linux"
libc = "glibc"
lazy = true
git-tree-sha1 = "2222222222222222222222222222222222222222"

    [[LazyOne.download]]
    url = "https://example.invalid/lazy.tar.gz"
    sha256 = "bb22"

[[LocalOnly]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "3333333333333333333333333333333333333333"
EOF

# An unknown String key flows through `unpack_platform` into matching, and
# enlarges the entry's key set for `match_loss`.
cat > "$FIX/extra_tags.toml" <<'EOF'
[[Cuda]]
arch = "x86_64"
os = "linux"
libc = "glibc"
cuda = "10.1"
git-tree-sha1 = "4444444444444444444444444444444444444444"

    [[Cuda.download]]
    url = "https://example.invalid/cuda.tar.gz"
    sha256 = "cc44"

[[Cuda]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "5555555555555555555555555555555555555555"

    [[Cuda.download]]
    url = "https://example.invalid/plain.tar.gz"
    sha256 = "dd55"
EOF

# Normalisation performed by the `Platform` constructor, not by the file:
# armv7l/linux gains call_abi=eabihf, a linux entry with no libc gains glibc,
# arch aliases and case are folded, and os_version is rounded to M.m.p.
cat > "$FIX/normalize.toml" <<'EOF'
[[Norm]]
arch = "armv7l"
os = "linux"
libc = "glibc"
git-tree-sha1 = "6666666666666666666666666666666666666666"

    [[Norm.download]]
    url = "https://example.invalid/arm.tar.gz"
    sha256 = "ee66"

[[Norm]]
arch = "AMD64"
os = "Linux"
libc = "GLIBC"
git-tree-sha1 = "7777777777777777777777777777777777777777"

    [[Norm.download]]
    url = "https://example.invalid/upper.tar.gz"
    sha256 = "ff77"

[[NoLibc]]
arch = "x86_64"
os = "linux"
git-tree-sha1 = "8888888888888888888888888888888888888888"

    [[NoLibc.download]]
    url = "https://example.invalid/nolibc.tar.gz"
    sha256 = "1188"

[[MacOnly]]
arch = "x86_64"
os = "macos"
os_version = "10.11"
git-tree-sha1 = "9999999999999999999999999999999999999999"

    [[MacOnly.download]]
    url = "https://example.invalid/mac.tar.gz"
    sha256 = "2299"
EOF

# The winner has no git-tree-sha1: the WHOLE artifact must resolve to nothing,
# not fall through to the aarch64 runner-up.
cat > "$FIX/no_sha1.toml" <<'EOF'
[[Broken]]
arch = "x86_64"
os = "linux"
libc = "glibc"

    [[Broken.download]]
    url = "https://example.invalid/broken.tar.gz"
    sha256 = "3300"

[[Broken]]
arch = "aarch64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EOF

# Bare tables: platform-independent artifacts, multiple mirrors, no download
# stanza at all, and a present-but-empty one.
cat > "$FIX/independent.toml" <<'EOF'
[Data]
git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    [[Data.download]]
    url = "https://mirror1.invalid/data.tar.gz"
    sha256 = "4401"

    [[Data.download]]
    url = "https://mirror2.invalid/data.tar.gz"
    sha256 = "4402"

[NoDownload]
git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"

[EmptyDownload]
git-tree-sha1 = "dddddddddddddddddddddddddddddddddddddddd"
download = []
EOF

# The auto-inserted `libc = glibc` is what makes these two entries differ. With
# it the first entry has three tags and ties the second on match_loss, then
# wins the triplet tiebreak ("...-gnu" > "...-cxx11"); without it the first has
# two tags, loses on match_loss, and the WRONG tarball is installed. This is
# the fixture that makes the constructor's normalisation observable on an
# x86_64 host.
cat > "$FIX/auto_libc.toml" <<'EOF'
[[AutoLibc]]
arch = "x86_64"
os = "linux"
git-tree-sha1 = "1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a"

    [[AutoLibc.download]]
    url = "https://example.invalid/autolibc.tar.gz"
    sha256 = "7701"

[[AutoLibc]]
arch = "x86_64"
os = "linux"
cxxstring_abi = "cxx11"
git-tree-sha1 = "2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b"

    [[AutoLibc.download]]
    url = "https://example.invalid/cxxonly.tar.gz"
    sha256 = "7702"
EOF

# The same story for the 32-bit-ARM `call_abi = eabihf` default, which only an
# ARM host can see: the explicit entry comes FIRST and the implicit one second,
# so normalising makes them duplicate Platforms and the SECOND wins. Skip the
# normalisation and the first wins instead.
cat > "$FIX/auto_call_abi.toml" <<'EOF'
[[ArmDup]]
arch = "armv7l"
os = "linux"
libc = "glibc"
call_abi = "eabihf"
git-tree-sha1 = "3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c"

    [[ArmDup.download]]
    url = "https://example.invalid/arm-explicit.tar.gz"
    sha256 = "8801"

[[ArmDup]]
arch = "armv7l"
os = "linux"
libc = "glibc"
git-tree-sha1 = "4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d"

    [[ArmDup.download]]
    url = "https://example.invalid/arm-implicit.tar.gz"
    sha256 = "8802"
EOF

# `libgfortran_version` is compared for EQUALITY (it is not one of the two
# capped keys), so the constructor's VersionNumber rounding is what makes the
# abbreviated "5" equal a host's "5.0.0". Without the rounding this artifact
# resolves to nothing on every host.
cat > "$FIX/version_tags.toml" <<'EOF'
[[Fortran]]
arch = "x86_64"
os = "linux"
libc = "glibc"
libgfortran_version = "5"
git-tree-sha1 = "5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e"

    [[Fortran.download]]
    url = "https://example.invalid/gfortran5.tar.gz"
    sha256 = "9901"

[[Fortran]]
arch = "x86_64"
os = "linux"
libc = "glibc"
libgfortran_version = "4"
git-tree-sha1 = "6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f"

    [[Fortran.download]]
    url = "https://example.invalid/gfortran4.tar.gz"
    sha256 = "9902"
EOF

# `julia_version` is the one tag the CONSTRUCTOR gives a compare strategy to
# (`binaryplatforms.jl:101-105`): major and minor only, on any platform carrying
# the tag rather than only on a host. The detected host always has the tag (it
# comes from `host_triplet()`), so a `1.12.0` entry must match a `1.12.6` host
# while a `1.11.0` one must not — compare the strings exactly and BOTH entries
# drop out and the artifact resolves to nothing.
cat > "$FIX/julia_version.toml" <<'EOF'
[[JV]]
arch = "x86_64"
os = "linux"
libc = "glibc"
julia_version = "1.11.0"
git-tree-sha1 = "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

    [[JV.download]]
    url = "https://example.invalid/jv-old.tar.gz"
    sha256 = "aa01"

[[JV]]
arch = "x86_64"
os = "linux"
libc = "glibc"
julia_version = "1.12.0"
git-tree-sha1 = "8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b"

    [[JV.download]]
    url = "https://example.invalid/jv-cur.tar.gz"
    sha256 = "aa02"
EOF

# Two entries that unpack to the SAME Platform: Julia keys them in a Dict, so
# the LAST one wins.
cat > "$FIX/dup_platform.toml" <<'EOF'
[[Dup]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1"

    [[Dup.download]]
    url = "https://example.invalid/first.tar.gz"
    sha256 = "5501"

[[Dup]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee2"

    [[Dup.download]]
    url = "https://example.invalid/second.tar.gz"
    sha256 = "5502"
EOF

# A name whose value is neither an array nor a table. Julia keeps the name and
# resolves it to nothing; an implementation that dropped the name instead would
# print one fewer record here.
cat > "$FIX/malformed.toml" <<'EOF'
Junk = "not a table or an array"

[[Good]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

    [[Good.download]]
    url = "https://example.invalid/good.tar.gz"
    sha256 = "aa01"
EOF

# NOTE: three shapes are deliberately absent from this corpus because Julia
# THROWS on them rather than returning a value to compare (verified by running
# julia, not by reading it):
#   * an entry missing `os`/`arch`  -> TypeError, `unpack_platform(...)::Platform` (:413)
#   * a non-table array element     -> TypeError, `x = x::Dict{String,Any}` (:412)
#   * a forbidden character in a tag -> ArgumentError from add_tag!
#     (binaryplatforms.jl:126-142)
# And because `select_downloadable_artifacts` calls `artifact_meta` for every
# name (:461-463), ONE bad entry aborts the whole file in Julia. Ajt records a
# Problem, warns on stderr, and keeps going. That divergence is intentional
# (this is the front half of an installer that has to say WHICH entry is wrong)
# and is covered by unit tests in src/install/artifacts.zig -- a differential
# gate cannot express "the oracle raises".

ls "$FIX"/*.toml | sort > "$WORK/fixtures.txt"
cat "$WORK/corpus.txt" "$WORK/fixtures.txt" > "$WORK/files.txt"

# ---------------------------------------------------------------------------
# 1. artifact_meta: selected git-tree-sha1 + lazy + download url/sha256
# ---------------------------------------------------------------------------
echo "==> artifact_meta (sha1 + download info)"
julia -e '
using Artifacts, TOML
function main()
    for f in eachline(ARGS[1])
        isempty(f) && continue
        d = try TOML.parsefile(f) catch; continue end
        for name in sort(collect(keys(d)))
            meta = artifact_meta(name, f)
            if meta === nothing
                println(f, "\t", name, "\tNONE\t-\t-\t-")
                continue
            end
            dl = get(meta, "download", nothing)
            dlstr = (dl === nothing || isempty(dl)) ? "-" :
                join(["$(e["url"])|$(e["sha256"])" for e in dl], " ")
            println(f, "\t", name, "\t", meta["git-tree-sha1"],
                    "\tlazy=", get(meta, "lazy", false) ? 1 : 0,
                    "\tdownload=", dl === nothing ? 0 : 1,
                    "\t", dlstr)
        end
    end
end
main()' "$WORK/files.txt" 2>"$WORK/meta.err" | sort > "$WORK/meta.julia" || {
  echo "ERROR: artifact_meta oracle failed" >&2; tail -5 "$WORK/meta.err" >&2; exit 2; }

# shellcheck disable=SC2046
"$AJT_BIN" artifact info --host "$HOST_TAGS" $(cat "$WORK/files.txt") | sort > "$WORK/meta.ajt" || {
  echo "ERROR: ajt artifact info failed" >&2; exit 2; }
report "artifact_meta (detected host)" "$WORK/meta.julia" "$WORK/meta.ajt"

# ---------------------------------------------------------------------------
# 1b. artifact_meta for hosts this machine is not.
#
# Every one of the 83 depot files is a fat JLL carrying arm/musl/macos/windows
# variants that an x86_64-linux host can never select, so a single-host gate
# leaves most of the corpus untested — and two of the constructor's normalisation
# rules (the 32-bit-ARM `call_abi` default, macOS `os_version` capping) are
# unreachable from here by construction.
#
# Both sides now normalise the spec: Julia's `build_host` below calls
# `HostPlatform(Platform(arch, os, tags))`, and `--host` goes through ajt's
# `platform.construct`. The specs happen to be written already-normalised, but
# that is no longer load-bearing — it used to be the only thing keeping the two
# sides comparing the same host.
# ---------------------------------------------------------------------------
for SPEC in \
  "arch=armv7l,call_abi=eabihf,libc=glibc,os=linux" \
  "arch=aarch64,os=macos" \
  "arch=x86_64,os=macos,os_version=10.12.0" \
  "arch=x86_64,libc=musl,os=linux" \
  "arch=x86_64,os=windows" \
  "arch=x86_64,libc=glibc,libstdcxx_version=3.4.26,os=linux" \
; do
  echo "==> artifact_meta (host $SPEC)"
  julia -e '
using Artifacts, TOML
using Base.BinaryPlatforms
function build_host(spec)
    t = Dict{String,String}()
    for kv in split(spec, ",")
        isempty(kv) && continue
        k, v = split(kv, "=", limit = 2)
        t[k] = v
    end
    arch = pop!(t, "arch")
    os = pop!(t, "os")
    return HostPlatform(Platform(arch, os, t))
end
function main()
    host = build_host(ARGS[2])
    for f in eachline(ARGS[1])
        isempty(f) && continue
        d = try TOML.parsefile(f) catch; continue end
        for name in sort(collect(keys(d)))
            meta = artifact_meta(name, f; platform = host)
            if meta === nothing
                println(f, "\t", name, "\tNONE\t-\t-\t-")
                continue
            end
            dl = get(meta, "download", nothing)
            dlstr = (dl === nothing || isempty(dl)) ? "-" :
                join(["$(e["url"])|$(e["sha256"])" for e in dl], " ")
            println(f, "\t", name, "\t", meta["git-tree-sha1"],
                    "\tlazy=", get(meta, "lazy", false) ? 1 : 0,
                    "\tdownload=", dl === nothing ? 0 : 1,
                    "\t", dlstr)
        end
    end
end
main()' "$WORK/files.txt" "$SPEC" 2>"$WORK/meta.err" | sort > "$WORK/metah.julia" || {
    echo "ERROR: artifact_meta oracle failed for $SPEC" >&2; tail -5 "$WORK/meta.err" >&2; exit 2; }
  # shellcheck disable=SC2046
  "$AJT_BIN" artifact info --host "$SPEC" $(cat "$WORK/files.txt") | sort > "$WORK/metah.ajt" || {
    echo "ERROR: ajt artifact info failed for $SPEC" >&2; exit 2; }
  report "artifact_meta host=$SPEC" "$WORK/metah.julia" "$WORK/metah.ajt"
done

# ---------------------------------------------------------------------------
# 2. select_downloadable_artifacts, both include_lazy settings
# ---------------------------------------------------------------------------
for LAZY in false true; do
  echo "==> select_downloadable_artifacts (include_lazy=$LAZY)"
  julia -e '
using Artifacts
function main()
    include_lazy = ARGS[2] == "true"
    for f in eachline(ARGS[1])
        isempty(f) && continue
        arts = try
            select_downloadable_artifacts(f; include_lazy)
        catch
            continue
        end
        for name in sort(collect(keys(arts)))
            println(f, "\t", name, "\t", arts[name]["git-tree-sha1"])
        end
    end
end
main()' "$WORK/files.txt" "$LAZY" 2>"$WORK/dl.err" | sort > "$WORK/dl.julia" || {
    echo "ERROR: downloadable oracle failed" >&2; tail -5 "$WORK/dl.err" >&2; exit 2; }

  LAZY_FLAG=()
  [ "$LAZY" = "true" ] && LAZY_FLAG=(--include-lazy)
  # shellcheck disable=SC2046
  "$AJT_BIN" artifact downloadable --host "$HOST_TAGS" "${LAZY_FLAG[@]}" \
    $(cat "$WORK/files.txt") | sort > "$WORK/dl.ajt" || {
    echo "ERROR: ajt artifact downloadable failed" >&2; exit 2; }
  report "select_downloadable_artifacts include_lazy=$LAZY" "$WORK/dl.julia" "$WORK/dl.ajt"
done

# ---------------------------------------------------------------------------
# 3. Overrides.toml -> artifact_path / artifact_exists
#
# Two synthetic depots stacked ahead of the real one. Depot 1 and depot 2 both
# override HASH_B; depot 1 must win, which is what `reverse(artifacts_dirs())`
# at Artifacts.jl:127 buys. The depot list is read back OUT of Julia so both
# sides are guaranteed to be looking at the same DEPOT_PATH.
# ---------------------------------------------------------------------------
echo "==> Overrides.toml (artifact_path / artifact_exists)"
D1="$WORK/depot1"; D2="$WORK/depot2"
HASH_A="a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"   # installed in depot 1
HASH_B="b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"   # overridden to a path
HASH_C="c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"   # overridden to HASH_A
HASH_D="d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"   # un-overridden by ""
HASH_E="e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"   # never mentioned
HASH_F="f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"   # installed in depot 2 only
HASH_G="0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"   # override to a MISSING path
PKG_UUID="d57dbccd-ca19-4d82-b9b8-9d660942965b"

mkdir -p "$D1/artifacts/$HASH_A" "$D2/artifacts/$HASH_F" "$D1/replacement" "$D1/libfoo-src"
cat > "$D1/artifacts/Overrides.toml" <<EOF
$HASH_B = "$D1/replacement"
$HASH_C = "$HASH_A"
$HASH_D = ""
$HASH_G = "$D1/definitely-not-here"

[$PKG_UUID]
libfoo = "$D1/libfoo-src"
EOF
# Depot 2 loses on HASH_B (depot 1 is earlier) but still owns HASH_D, which
# depot 1 then un-overrides with the empty string.
cat > "$D2/artifacts/Overrides.toml" <<EOF
$HASH_B = "$D2/loser"
$HASH_D = "$D2/also-loser"
EOF

# The aarch64 variant is deliberately FIRST so the selected (x86_64) one is not
# variant 0: `process_overrides` mints a hash override for EVERY variant, and
# an implementation that only overrode the selected one would still look right
# if the selected one happened to come first.
cat > "$FIX/overridden.toml" <<EOF
[[libfoo]]
arch = "aarch64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "$HASH_F"

    [[libfoo.download]]
    url = "https://example.invalid/libfoo-arm.tar.gz"
    sha256 = "6602"

[[libfoo]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "$HASH_E"

    [[libfoo.download]]
    url = "https://example.invalid/libfoo.tar.gz"
    sha256 = "6601"

[[other]]
arch = "x86_64"
os = "linux"
libc = "glibc"
git-tree-sha1 = "$HASH_A"

    [[other.download]]
    url = "https://example.invalid/other.tar.gz"
    sha256 = "6603"
EOF

export JULIA_DEPOT_PATH="$D1:$D2:$DEPOT"
DEPOT_LIST=$(julia -e 'print(join(Base.DEPOT_PATH, "\n"))')
DEPOT_ARGS=()
while IFS= read -r d; do [ -n "$d" ] && DEPOT_ARGS+=(--depot "$d"); done <<< "$DEPOT_LIST"

HASHES=("$HASH_A" "$HASH_B" "$HASH_C" "$HASH_D" "$HASH_E" "$HASH_F" "$HASH_G")
julia -e '
using Artifacts
for h in ARGS
    s = Base.SHA1(h)
    println(h, "\t", artifact_path(s), "\t", artifact_exists(s) ? 1 : 0)
end' "${HASHES[@]}" 2>"$WORK/ov.err" | sort > "$WORK/ov.julia" || {
  echo "ERROR: overrides oracle failed" >&2; tail -5 "$WORK/ov.err" >&2; exit 2; }

"$AJT_BIN" artifact path "${DEPOT_ARGS[@]}" "${HASHES[@]}" | sort > "$WORK/ov.ajt" || {
  echo "ERROR: ajt artifact path failed" >&2; exit 2; }
report "artifact_path / artifact_exists (overrides honoured)" "$WORK/ov.julia" "$WORK/ov.ajt"

# The same hashes with honor_overrides=false must fall back to depot candidates.
julia -e '
using Artifacts
for h in ARGS
    s = Base.SHA1(h)
    println(h, "\t", artifact_path(s; honor_overrides=false), "\t",
            artifact_exists(s; honor_overrides=false) ? 1 : 0)
end' "${HASHES[@]}" 2>>"$WORK/ov.err" | sort > "$WORK/ovno.julia" || {
  echo "ERROR: no-override oracle failed" >&2; tail -5 "$WORK/ov.err" >&2; exit 2; }
"$AJT_BIN" artifact path --no-overrides "${DEPOT_ARGS[@]}" "${HASHES[@]}" | sort > "$WORK/ovno.ajt"
report "artifact_path (honor_overrides=false)" "$WORK/ovno.julia" "$WORK/ovno.ajt"

# ---------------------------------------------------------------------------
# 4. UUID/name overrides: process_overrides mints hash overrides at load time
# ---------------------------------------------------------------------------
echo "==> UUID/name overrides (process_overrides)"
julia -e '
using Artifacts
function main()
    toml = ARGS[1]
    uuid = Base.UUID(ARGS[2])
    d = Artifacts.load_artifacts_toml(toml; pkg_uuid = uuid)
    for name in sort(collect(keys(d)))
        meta = artifact_meta(name, d, toml)
        meta === nothing && continue
        h = Base.SHA1(meta["git-tree-sha1"])
        println(toml, "\t", name, "\t", meta["git-tree-sha1"], "\t",
                artifact_path(h), "\t", artifact_exists(h) ? 1 : 0)
    end
end
main()' "$FIX/overridden.toml" "$PKG_UUID" 2>"$WORK/uuid.err" | sort > "$WORK/uuid.julia" || {
  echo "ERROR: uuid-override oracle failed" >&2; tail -5 "$WORK/uuid.err" >&2; exit 2; }

# `resolve` emits path/name/sha1/lazy/download/urls/resolved-path/exists; the
# oracle skips names that resolve to nothing, so drop those here too.
"$AJT_BIN" artifact resolve --host "$HOST_TAGS" --pkg-uuid "$PKG_UUID" "${DEPOT_ARGS[@]}" \
  "$FIX/overridden.toml" | grep -v $'\tNONE\t' | cut -f1,2,3,7,8 | sort > "$WORK/uuid.ajt" || {
  echo "ERROR: ajt artifact resolve failed" >&2; exit 2; }
report "process_overrides + artifact_path" "$WORK/uuid.julia" "$WORK/uuid.ajt"

unset JULIA_DEPOT_PATH

# ---------------------------------------------------------------------------
# 5. find_artifacts_toml: JuliaArtifacts.toml beats Artifacts.toml
# ---------------------------------------------------------------------------
echo "==> artifact_names discovery order"
mkdir -p "$WORK/roots/both" "$WORK/roots/plain" "$WORK/roots/none"
: > "$WORK/roots/both/Artifacts.toml"
: > "$WORK/roots/both/JuliaArtifacts.toml"
: > "$WORK/roots/plain/Artifacts.toml"
# A Project.toml stops Julia's walk-up, so "none" means none for both sides.
: > "$WORK/roots/none/Project.toml"

julia -e '
using Artifacts
for d in ARGS
    r = find_artifacts_toml(d)
    println(d, "\t", r === nothing ? "NONE" : r)
end' "$WORK/roots/both" "$WORK/roots/plain" "$WORK/roots/none" \
  2>"$WORK/find.err" | sort > "$WORK/find.julia" || {
  echo "ERROR: find oracle failed" >&2; tail -5 "$WORK/find.err" >&2; exit 2; }
"$AJT_BIN" artifact find "$WORK/roots/both" "$WORK/roots/plain" "$WORK/roots/none" \
  | sort > "$WORK/find.ajt"
report "find_artifacts_toml" "$WORK/find.julia" "$WORK/find.ajt"

# ---------------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS — Artifacts.toml model agrees with Julia across $TOTAL depot files + $(wc -l < "$WORK/fixtures.txt") fixtures"
  exit 0
fi
echo "FAIL — $FAILURES check(s) diverged" >&2
exit 1
