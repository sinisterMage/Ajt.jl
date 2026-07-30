#!/usr/bin/env bash
# End-to-end gate for the artifact INSTALL pipeline (src/ops/install_artifacts.zig).
#
# `artifacts_model.sh` gates what gets selected; this gates what lands on disk.
# There is no Julia function to diff against here — `download_artifact` wants a
# real URL and a real depot — so the oracle is applied to the RESULT instead:
#
#   1. Real JLL artifacts from the Open-Reality environment are installed into a
#      throwaway depot, twice: once through the Pkg server (`$server/artifact/
#      <hash>`, which carries no sha256 and is verified by tree hash alone) and
#      once with the server disabled so the `[[download]]` mirrors and their
#      sha256 are exercised. Both must produce a directory that
#      `Pkg.GitTools.tree_hash` hashes back to its own name, and that
#      `Pkg.Artifacts.artifact_exists` accepts.
#
#   2. The two verifications are then forced to fail INDEPENDENTLY, against a
#      local tarball served over loopback. They cannot be provoked by one input:
#      a body that is corrupt but still matches its sha256 does not exist, so
#      case (a) corrupts the bytes and keeps the recorded sha256, while case (b)
#      serves a different, internally-consistent tarball (correct sha256 for the
#      bytes) under the ORIGINAL git-tree-sha1. Case (b) is the one that proves
#      the tree-hash check is not redundant.
#
#      Both cases assert on the FILESYSTEM: `artifacts/` must be left with
#      nothing in it — not the artifact, and not a staging directory either.
#
# The user's real depot is READ ONLY here (it is where the JLL package roots and
# their Artifacts.toml come from); everything written goes to a temp directory.
#
# Usage: tools/diff_harness/install_artifacts.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
REAL_DEPOT="${DEPOT_ENV%%:*}"
REAL_DEPOT="${REAL_DEPOT:-$HOME/.julia}"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia   >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 not on PATH" >&2; exit 2; }
command -v tar     >/dev/null || { echo "ERROR: tar not on PATH" >&2; exit 2; }
command -v curl    >/dev/null || { echo "ERROR: curl not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-install-artifacts-XXXXXX)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  # Installed artifacts are published read-only (set_readonly); directories stay
  # writable, so a plain rm -rf still works.
  [ $KEEP -eq 0 ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# ---------------------------------------------------------------------------
# Host. Ajt's own detection is used, cross-checked against Julia's so a
# detection regression fails here instead of silently installing the wrong
# variant (which only shows up at `dlopen` time).
# ---------------------------------------------------------------------------
JULIA_PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')
JULIA_HOST=$(julia -e '
using Base.BinaryPlatforms
p = HostPlatform()
println(join(["$k=$v" for (k, v) in sort(collect(tags(p)), by=first)], ","))')
HOST_TAGS=$("$AJT_BIN" host-platform --julia-prefix "$JULIA_PREFIX" --julia-version "$JULIA_VERSION")
check "host detection agrees with Julia's HostPlatform()" "$JULIA_HOST" "$HOST_TAGS"
[ "$JULIA_HOST" = "$HOST_TAGS" ] || exit 1

# Oracles, used everywhere below.
tree_hash_of() { julia -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$1"; }
# `with_artifacts_directory` (Artifacts/src/Artifacts.jl:49-56) points
# `artifacts_dirs()` at exactly one directory. Better than JULIA_DEPOT_PATH
# here: it cannot accidentally see the real depot (a false positive), and it
# does not force Julia to precompile into a cold temp depot.
artifact_exists_in() {
  julia -e '
using Artifacts
Artifacts.with_artifacts_directory(ARGS[1]) do
    print(artifact_exists(Base.SHA1(ARGS[2])))
end' "$1" "$2"
}
sha256_of() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# Counts entries under a directory that MUST exist (run_case creates it), so a
# zero here means "empty", never "absent".
count_entries() {
  [ -d "$1" ] || { echo "MISSING"; return; }
  find "$1" -mindepth 1 | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Package roots: small JLLs that the Open-Reality environment actually uses.
# BerkeleyDB_jll is in that manifest too and is 102 MB — deliberately not here.
# ---------------------------------------------------------------------------
CANDIDATES=(Ogg_jll XZ_jll Zstd_jll libpng_jll Bzip2_jll)
ROOTS=()
NAMES=()
for name in "${CANDIDATES[@]}"; do
  [ -f "$MANIFEST" ] && ! grep -q "^\[\[deps\.$name\]\]" "$MANIFEST" && continue
  root=$(ls -d "$REAL_DEPOT/packages/$name"/*/ 2>/dev/null | head -1)
  [ -n "$root" ] || continue
  [ -f "$root/Artifacts.toml" ] || continue
  ROOTS+=("${root%/}")
  NAMES+=("$name")
  [ "${#ROOTS[@]}" -ge 3 ] && break
done

# ---------------------------------------------------------------------------
# Sections 1 and 2 need the internet. Everything after them is loopback-only.
# ---------------------------------------------------------------------------
NETWORK=1
if ! curl -sfI --max-time 15 -o /dev/null https://pkg.julialang.org/registries; then
  NETWORK=0
fi

if [ "${#ROOTS[@]}" -eq 0 ]; then
  echo
  echo "############################################################"
  echo "# SKIPPING the real-JLL sections: none of ${CANDIDATES[*]}"
  echo "# is installed under $REAL_DEPOT/packages."
  echo "############################################################"
elif [ $NETWORK -eq 0 ]; then
  echo
  echo "############################################################"
  echo "# SKIPPING the real-JLL sections: NO NETWORK."
  echo "# (https://pkg.julialang.org is unreachable — the download"
  echo "#  pipeline cannot be exercised against real artifacts.)"
  echo "############################################################"
else
  echo
  echo "==> 1. install ${NAMES[*]} through the Pkg server (no sha256 available)"
  DEPOT_A="$WORK/depot-server"
  mkdir -p "$DEPOT_A"
  if ! "$AJT_BIN" install-artifacts --depot "$DEPOT_A" --host "$HOST_TAGS" \
        --julia-version "$JULIA_VERSION" --julia-prefix "$JULIA_PREFIX" \
        "${ROOTS[@]}" > "$WORK/a.out" 2> "$WORK/a.err"; then
    bad "install through the Pkg server" "$(tail -3 "$WORK/a.err")"
  else
    ok "install through the Pkg server"
  fi
  cat "$WORK/a.out"

  N=0
  while IFS=$'\t' read -r _toml name hash outcome path; do
    [ -n "$hash" ] || continue
    N=$((N + 1))
    check "$name installed" "installed" "$outcome"
    # THE assertion: the directory's git tree hash IS its own name. That is
    # what `git-tree-sha1` pins and what Pkg re-checks post-extraction
    # (Operations.jl:813, Pkg/src/Artifacts.jl:359).
    check "$name re-hashes to its own directory name (GitTools oracle)" "$hash" "$(tree_hash_of "$path")"
    check "$name is visible to Pkg.Artifacts.artifact_exists" "true" \
      "$(artifact_exists_in "$DEPOT_A/artifacts" "$hash")"
    # Content-addressed store: published read-only (Pkg/src/Artifacts.jl:88).
    f=$(find "$path" -type f | head -1)
    if [ -z "$f" ]; then
      # No file at all means the install is broken, not that it is read-only.
      bad "$name is read-only after install" "no files under $path"
    elif [ -w "$f" ]; then
      bad "$name is read-only after install" "$f is writable"
    else
      ok "$name is read-only after install"
    fi
  done < "$WORK/a.out"
  check "every requested JLL produced a record" "${#ROOTS[@]}" "$N"
  # Without this, §1 proves nothing §2 does not: the Pkg server is only the
  # FIRST source tried, so a 404 (or a wrongly built URL) silently falls
  # through to the very mirrors §2 uses and every check above still passes.
  # A failed source always prints "<name>: <url> failed: <reason>" on stderr,
  # so an empty stderr means the first source served every artifact.
  if grep -q ' failed: ' "$WORK/a.err"; then
    bad "the Pkg server served every artifact (no fallback to a mirror)" "$(grep ' failed: ' "$WORK/a.err" | head -2)"
  else
    ok "the Pkg server served every artifact (no fallback to a mirror)"
  fi

  echo
  echo "==> 2. install the same artifacts from their mirrors (sha256 path)"
  # `--server ""` disables the Pkg-server source the way JULIA_PKG_SERVER=""
  # does, so every byte here comes from a `[[X.download]]` URL and is checked
  # against the entry's sha256 before anything is decompressed.
  DEPOT_B="$WORK/depot-mirror"
  mkdir -p "$DEPOT_B"
  if ! "$AJT_BIN" install-artifacts --depot "$DEPOT_B" --host "$HOST_TAGS" --server "" \
        "${ROOTS[@]}" > "$WORK/b.out" 2> "$WORK/b.err"; then
    bad "install from mirrors" "$(tail -3 "$WORK/b.err")"
  else
    ok "install from mirrors"
  fi

  while IFS=$'\t' read -r _toml name hash outcome path; do
    [ -n "$hash" ] || continue
    check "$name installed from a mirror" "installed" "$outcome"
    check "$name (mirror) re-hashes to its own directory name" "$hash" "$(tree_hash_of "$path")"
  done < "$WORK/b.out"
  # Two entirely different transports, one content address: the strongest
  # statement this harness can make about the pipeline.
  if diff <(cut -f2,3 "$WORK/a.out" | sort) <(cut -f2,3 "$WORK/b.out" | sort) >/dev/null; then
    ok "the Pkg server and the mirrors installed the same hashes"
  else
    bad "the Pkg server and the mirrors installed the same hashes"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Negative cases, over loopback. No internet needed and no real artifact
#    involved: the point is to control the bytes exactly.
# ---------------------------------------------------------------------------
echo
echo "==> 3. both verifications reject, independently, and write nothing"

mkdir -p "$WORK/fixture/lib" "$WORK/serve"
printf 'artifact\n'            > "$WORK/fixture/README.md"
printf '\177ELF not really\n'  > "$WORK/fixture/lib/libfoo.so"
chmod 755 "$WORK/fixture/lib/libfoo.so"
ln -sf libfoo.so "$WORK/fixture/lib/libfoo.so.1"

TARFLAGS=(--format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner)
tar "${TARFLAGS[@]}" -czf "$WORK/serve/good.tar.gz" -C "$WORK/fixture" .

# A DIFFERENT tree, packed just as legitimately: this is the tarball whose
# sha256 will be recorded correctly while its content is not what was pinned.
cp -a "$WORK/fixture" "$WORK/other"
printf 'tampered\n' > "$WORK/other/README.md"
tar "${TARFLAGS[@]}" -czf "$WORK/serve/other.tar.gz" -C "$WORK/other" .

# Corrupt the compressed stream. sha256 is checked BEFORE decompression, so
# this must be rejected as a sha256 mismatch and never reach the decompressor.
python3 - "$WORK/serve/good.tar.gz" "$WORK/serve/corrupt.tar.gz" <<'PY'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
i = len(data) // 2
data[i] ^= 0xFF
open(sys.argv[2], 'wb').write(bytes(data))
PY

GOOD_TREE=$(tree_hash_of "$WORK/fixture")
GOOD_SHA=$(sha256_of "$WORK/serve/good.tar.gz")
OTHER_TREE=$(tree_hash_of "$WORK/other")
OTHER_SHA=$(sha256_of "$WORK/serve/other.tar.gz")
CORRUPT_SHA=$(sha256_of "$WORK/serve/corrupt.tar.gz")
[ "$GOOD_TREE" != "$OTHER_TREE" ] && ok "the two fixtures really are different trees" \
  || bad "the two fixtures really are different trees"
[ "$GOOD_SHA" != "$CORRUPT_SHA" ] && ok "corruption really did change the sha256" \
  || bad "corruption really did change the sha256"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/serve" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/good.tar.gz" && break
  sleep 0.1
done
if ! curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/good.tar.gz"; then
  bad "loopback fixture server came up"
  echo "FAIL — cannot serve fixtures" >&2
  exit 1
fi
ok "loopback fixture server came up"

# A bare table is a platform-independent artifact, so it is selected on every
# host and these cases do not depend on the machine running them.
write_case() { # write_case <dir> <tarball> <sha256> <git-tree-sha1>
  mkdir -p "$1"
  cat > "$1/Artifacts.toml" <<EOF
[LocalFixture]
git-tree-sha1 = "$4"

    [[LocalFixture.download]]
    url = "http://127.0.0.1:$PORT/$2"
    sha256 = "$3"
EOF
}

run_case() { # run_case <label> <case-dir> <depot> -> prints the outcome field
  # Create artifacts/ up front: the sha256 rejection happens BEFORE the staging
  # directory is created, so a missing artifacts/ would make the "wrote
  # nothing" check below pass no matter what the code did.
  mkdir -p "$3/artifacts"
  # --server "" so the only source is the loopback URL; --retry 1 so a
  # deliberate failure does not sit through Pkg's three attempts.
  "$AJT_BIN" install-artifacts --depot "$3" --host "$HOST_TAGS" --server "" --retry 1 \
    "$2" > "$WORK/$1.out" 2> "$WORK/$1.err"
  awk -F'\t' 'NR==1{print $4}' "$WORK/$1.out"
}

# (c) first: the fixture installs cleanly. Without this the two rejections
#     below would also pass against a fixture that never worked at all.
write_case "$WORK/case-good" good.tar.gz "$GOOD_SHA" "$GOOD_TREE"
OUT=$(run_case good "$WORK/case-good" "$WORK/depot-good")
check "the local fixture installs" "installed" "$OUT"
check "the local fixture re-hashes to its own name (GitTools oracle)" "$GOOD_TREE" \
  "$(tree_hash_of "$WORK/depot-good/artifacts/$GOOD_TREE")"
check "the local fixture is visible to artifact_exists" "true" \
  "$(artifact_exists_in "$WORK/depot-good/artifacts" "$GOOD_TREE")"

# (a) sha256 rejects: corrupted bytes, the recorded sha256 unchanged. The tree
#     hash never gets a chance — the bytes do not even decompress.
write_case "$WORK/case-sha" corrupt.tar.gz "$GOOD_SHA" "$GOOD_TREE"
OUT=$(run_case sha "$WORK/case-sha" "$WORK/depot-sha")
check "a corrupt tarball is rejected" "failed" "$OUT"
if grep -q 'sha256_mismatch' "$WORK/sha.err"; then
  ok "...by the sha256 check specifically (before any decompression)"
else
  bad "...by the sha256 check specifically" "$(tail -2 "$WORK/sha.err")"
fi
check "the sha256 rejection wrote nothing into artifacts/" "0" "$(count_entries "$WORK/depot-sha/artifacts")"

# (b) tree hash rejects: a valid tarball, its sha256 recorded CORRECTLY, and a
#     git-tree-sha1 that belongs to different content. sha256 passes; only the
#     second check can catch this, which is why both exist.
write_case "$WORK/case-tree" other.tar.gz "$OTHER_SHA" "$GOOD_TREE"
OUT=$(run_case tree "$WORK/case-tree" "$WORK/depot-tree")
check "a correctly-signed tarball of the wrong tree is rejected" "failed" "$OUT"
if grep -q 'tree_hash_mismatch' "$WORK/tree.err"; then
  ok "...by the tree-hash check specifically (sha256 passed)"
else
  bad "...by the tree-hash check specifically" "$(tail -2 "$WORK/tree.err")"
fi
if grep -q "got $OTHER_TREE" "$WORK/tree.err"; then
  ok "...and the mismatch is reported with both sides"
else
  bad "...and the mismatch is reported with both sides" "$(tail -2 "$WORK/tree.err")"
fi
check "the tree-hash rejection wrote nothing into artifacts/" "0" "$(count_entries "$WORK/depot-tree/artifacts")"

# ---------------------------------------------------------------------------
echo
if [ $FAIL -eq 0 ]; then
  if [ $NETWORK -eq 0 ] || [ "${#ROOTS[@]}" -eq 0 ]; then
    echo "PASS (PARTIAL) — $PASS checks; the real-JLL sections were SKIPPED, see above"
  else
    echo "PASS — $PASS checks: real JLL artifacts install and re-hash to their own"
    echo "       names through both transports, and both verifications reject"
    echo "       independently without writing a byte"
  fi
  exit 0
fi
echo "FAIL — $FAIL of $((PASS+FAIL)) checks" >&2
[ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect)" >&2
exit 1
