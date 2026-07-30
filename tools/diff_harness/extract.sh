#!/usr/bin/env bash
# Differential gate for the verify-before-extract install pipeline.
#
# Two properties are on trial here, and they are not the same property:
#
#   1. AGREEMENT — the hash ajt computes from the tarball stream is the value
#      Julia computes. Oracles: `Tar.tree_hash` (the stream hasher ajt ports)
#      and `Pkg.GitTools.tree_hash` (the directory walker Pkg actually compares
#      against `git-tree-sha1` at Operations.jl:812). Both are run; the second
#      is run over the tree ajt EXTRACTED, which is the only way to prove that
#      what was verified is what was written.
#
#   2. ORDERING — on a hash mismatch, nothing is written. Pkg extracts first
#      and hashes the result afterwards (Operations.jl:800-818), so it has a
#      window where unverified network bytes exist as real files. Ajt must not.
#      The assertion for this is on the FILESYSTEM (destination still empty),
#      not on the return value: a function can return an error and still have
#      left a mess.
#
# Fixtures are built here rather than committed, so the oracle sees exactly the
# bytes ajt sees, including the executable bit and the symlink that a git
# checkout of a fixture would be free to mangle.
#
# Usage: tools/diff_harness/extract.sh [--no-general] [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

WITH_GENERAL=1
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-general) WITH_GENERAL=0; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
command -v tar   >/dev/null || { echo "ERROR: tar not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-extract-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# ---------------------------------------------------------------------------
# A probe binary over the library module. Written here instead of committed as
# a source file so this harness needs no build.zig step of its own; it links
# src/root.zig directly, the same module `zig build test` compiles.
# ---------------------------------------------------------------------------
cat > "$WORK/probe.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");
const ex = ajt.install.extract;

fn shapeOf(s: []const u8) ex.Shape {
    return if (std.mem.eql(u8, s, "gh")) .github_tarball else .top_level;
}

/// gzip magic. The harness feeds both .tar and .tar.gz; sniffing the two
/// bytes is more honest than trusting a file extension.
fn isGzip(b: []const u8) bool {
    return b.len >= 2 and b[0] == 0x1f and b[1] == 0x8b;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "dirhash")) {
        const h = try ajt.julia.treehash.hashPath(gpa, io, args[2]);
        try out.print("{s}\n", .{ajt.julia.treehash.toHex(h)});
        return;
    }

    // hash   <shape> <skip:1|0> <file>
    // verify <shape> <skip:1|0> <expected-hex> <file> <dest-dir>
    const opts: ex.Options = .{
        .shape = shapeOf(args[2]),
        .skip_empty = std.mem.eql(u8, args[3], "1"),
    };
    const file = if (std.mem.eql(u8, cmd, "hash")) args[4] else args[5];
    const bytes = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 30));
    defer gpa.free(bytes);

    if (std.mem.eql(u8, cmd, "hash")) {
        const h = if (isGzip(bytes))
            ex.treeHashOfGzip(gpa, bytes, opts)
        else
            ex.treeHashOfTar(gpa, bytes, opts);
        try out.print("{s}\n", .{ajt.julia.treehash.toHex(h catch |e| {
            try out.print("ERR {t}\n", .{e});
            return;
        })});
        return;
    }

    if (std.mem.eql(u8, cmd, "verify")) {
        const expected = ex.parseHash(args[4]) catch {
            try out.writeAll("ERR InvalidSha1\n");
            return;
        };
        var dest = try Io.Dir.cwd().openDir(io, args[6], .{});
        defer dest.close(io);
        const r = if (isGzip(bytes))
            ex.verifyAndExtractGzip(gpa, io, bytes, expected, dest, opts)
        else
            ex.verifyAndExtractTar(gpa, io, bytes, expected, dest, opts);
        r catch |e| {
            try out.print("ERR {t}\n", .{e});
            return;
        };
        try out.writeAll("OK\n");
        return;
    }

    try out.writeAll("ERR UnknownCommand\n");
}
ZIG

echo "==> building probe"
# Hermetic per-run cache, as in stdlibs.sh. The local cache was already
# contained here, but only as a side effect of `cd "$WORK"` -- hermeticity a
# gate depends on should be stated, not inherited from an unrelated `cd`.
( cd "$WORK" && zig build-exe \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt \
    -Mroot=probe.zig \
    -Majt="$AJT_ROOT/src/root.zig" \
    -femit-bin=probe >/dev/null ) || { echo "ERROR: probe build failed" >&2; exit 2; }
PROBE="$WORK/probe"

# ---------------------------------------------------------------------------
# Fixtures. A subdirectory, an executable file, and a symlink -- the three
# things a git tree hash treats differently from plain bytes.
# ---------------------------------------------------------------------------
echo "==> building fixtures"
mkdir -p "$WORK/tree/sub"
printf 'hello\n'            > "$WORK/tree/a.txt"
printf 'world\n'            > "$WORK/tree/sub/b.txt"
printf '#!/bin/sh\necho hi\n' > "$WORK/tree/run.sh"
chmod 755 "$WORK/tree/run.sh"
ln -sf a.txt "$WORK/tree/link"

TARFLAGS=(--format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner)

# 1. Pkg-server shape: contents at the top level.
tar "${TARFLAGS[@]}" -cf "$WORK/top.tar" -C "$WORK/tree" .
gzip -kfn "$WORK/top.tar"

# 2. GitHub /tarball shape: one generated wrapper directory, plus the spurious
#    pax_global_header that 7z materialises as a top-level file
#    (Operations.jl:803-805).
mkdir -p "$WORK/gh/JuliaLang-Example-1a2b3c4"
cp -a "$WORK/tree/." "$WORK/gh/JuliaLang-Example-1a2b3c4/"
printf '52 comment=1a2b3c4d5e6f\n' > "$WORK/gh/pax_global_header"
tar "${TARFLAGS[@]}" -cf "$WORK/gh.tar" -C "$WORK/gh" pax_global_header JuliaLang-Example-1a2b3c4
gzip -kfn "$WORK/gh.tar"

# 2b. Same wrapper, no pax entry -- isolates the strip from the filter.
tar "${TARFLAGS[@]}" -cf "$WORK/gh_nopax.tar" -C "$WORK/gh" JuliaLang-Example-1a2b3c4

# 3. Two roots: Pkg's `@assert length(dirs) == 1` (Operations.jl:806).
mkdir -p "$WORK/two/one" "$WORK/two/other"
printf 'x\n' > "$WORK/two/one/x.txt"
printf 'y\n' > "$WORK/two/other/y.txt"
tar "${TARFLAGS[@]}" -cf "$WORK/two.tar" -C "$WORK/two" .

# 4. An empty directory: the one case where Tar.tree_hash and
#    GitTools.tree_hash disagree.
mkdir -p "$WORK/hollow/sub" "$WORK/hollow/nothing"
printf 'hello\n' > "$WORK/hollow/a.txt"
printf 'world\n' > "$WORK/hollow/sub/b.txt"
tar "${TARFLAGS[@]}" -cf "$WORK/hollow.tar" -C "$WORK/hollow" .

# 5. A corrupted copy of the good tarball: one byte of file CONTENT flipped,
#    so the archive stays structurally valid and only the tree hash changes.
#    (Corrupting the gzip envelope would fail at the decompressor and prove
#    something weaker.)
python3 - "$WORK/top.tar" "$WORK/corrupt.tar" <<'PY'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
i = data.find(b'world\n')
assert i > 0, "fixture content not found"
data[i] = ord('W')
open(sys.argv[2], 'wb').write(bytes(data))
PY
gzip -kfn "$WORK/corrupt.tar"

# 6. Hostile archives. These cannot be produced by tarring a real directory --
#    the whole point is that they describe a tree the filesystem cannot hold --
#    so they are written entry by entry.
mkdir -p "$WORK/aim/src"
printf 'owned\n' > "$WORK/aim/src/pwned.txt"
python3 - "$WORK" <<'PY'
import io, os, sys, tarfile
w = sys.argv[1]

def tf(name):
    return tarfile.open(os.path.join(w, name), "w", format=tarfile.USTAR_FORMAT)

def add_file(t, name, data, mode=0o644):
    ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = mode; ti.mtime = 0
    t.addfile(ti, io.BytesIO(data))

def add_sym(t, name, target):
    ti = tarfile.TarInfo(name); ti.type = tarfile.SYMTYPE
    ti.linkname = target; ti.mode = 0o777; ti.mtime = 0
    t.addfile(ti)

# src is a symlink out of the destination; the next entry is written THROUGH
# it. The tree this hashes to is the innocent {src/{pwned.txt}}, because the
# stream hasher replaces the symlink node with a directory the moment
# something nests under it -- so no hash collision is required.
with tf("attack_symlink.tar") as t:
    add_sym(t, "src", os.path.join(w, "escaped"))
    add_file(t, "src/pwned.txt", b"owned\n")

# The same tree without the symlink: this is the hash the attacker aims at.
with tf("aim.tar") as t:
    add_file(t, "src/pwned.txt", b"owned\n")

# Two entries for one path: the stream hasher keeps the last, an exclusive
# create keeps the first.
with tf("attack_dup.tar") as t:
    add_file(t, "a.txt", b"first\n")
    add_file(t, "a.txt", b"second\n")

# A '..' component: std.tar resolves it, the stream hasher does not.
with tf("attack_dotdot.tar") as t:
    add_file(t, "a/x/../b.txt", b"x\n")
PY

# ---------------------------------------------------------------------------
echo
echo "==> 1. oracle agreement (Tar.tree_hash / GitTools.tree_hash)"

read -r TAR_TOP TAR_TOP_SKIP GIT_TOP TAR_HOLLOW TAR_HOLLOW_SKIP GIT_HOLLOW <<EOF
$(julia -e '
using Tar, Pkg
w = ARGS[1]
print(open(Tar.tree_hash, joinpath(w,"top.tar")), " ",
      open(io->Tar.tree_hash(io; skip_empty=true), joinpath(w,"top.tar")), " ",
      bytes2hex(Pkg.GitTools.tree_hash(joinpath(w,"tree"))), " ",
      open(Tar.tree_hash, joinpath(w,"hollow.tar")), " ",
      open(io->Tar.tree_hash(io; skip_empty=true), joinpath(w,"hollow.tar")), " ",
      bytes2hex(Pkg.GitTools.tree_hash(joinpath(w,"hollow"))))' "$WORK")
EOF

check "Tar.tree_hash == GitTools.tree_hash on a git-shaped tree" "$TAR_TOP" "$GIT_TOP"
check "ajt top_level  == Tar.tree_hash"  "$TAR_TOP"  "$("$PROBE" hash top 0 "$WORK/top.tar")"
check "ajt top_level  == GitTools (skip_empty default)" "$GIT_TOP" "$("$PROBE" hash top 1 "$WORK/top.tar")"
check "ajt gzip path  == plain tar path" "$TAR_TOP" "$("$PROBE" hash top 0 "$WORK/top.tar.gz")"

# The empty-directory case is what pins Options.skip_empty's default. Pkg
# compares GitTools.tree_hash (Operations.jl:812), which prunes; Tar.tree_hash
# does not. If these two oracles ever stop disagreeing the fixture is broken.
if [ "$TAR_HOLLOW" = "$TAR_HOLLOW_SKIP" ]; then
  bad "fixture has no empty directory to distinguish the hashers"
else
  ok "fixture exercises the empty-directory divergence"
fi
check "ajt skip_empty=1 == GitTools.tree_hash" "$GIT_HOLLOW" "$("$PROBE" hash top 1 "$WORK/hollow.tar")"
check "ajt skip_empty=0 == Tar.tree_hash"      "$TAR_HOLLOW" "$("$PROBE" hash top 0 "$WORK/hollow.tar")"

# ---------------------------------------------------------------------------
echo
echo "==> 2. verify-before-extract: a corrupt tarball writes NOTHING"

for variant in corrupt.tar corrupt.tar.gz; do
  DEST="$WORK/dest-$variant"
  mkdir -p "$DEST"
  RES="$("$PROBE" verify top 1 "$GIT_TOP" "$WORK/$variant" "$DEST")"
  check "$variant rejected" "ERR TreeHashMismatch" "$RES"
  # THE assertion: the destination must still be empty. A return value alone
  # would not catch an implementation that extracted and then cleaned up
  # badly, nor one that wrote a partial tree before hashing.
  LEFTOVER="$(find "$DEST" -mindepth 1 | wc -l)"
  check "$variant left the destination empty" "0" "$LEFTOVER"
done

# A truncated gzip fails earlier still, in the decompressor.
head -c $(( $(stat -c%s "$WORK/top.tar.gz") - 12 )) "$WORK/top.tar.gz" > "$WORK/trunc.tar.gz"
DEST="$WORK/dest-trunc"; mkdir -p "$DEST"
RES="$("$PROBE" verify top 1 "$GIT_TOP" "$WORK/trunc.tar.gz" "$DEST")"
check "truncated gzip rejected" "ERR DecompressFailed" "$RES"
check "truncated gzip left the destination empty" "0" "$(find "$DEST" -mindepth 1 | wc -l)"

# And the good tarball with the WRONG expected hash: same guarantee.
DEST="$WORK/dest-wronghash"; mkdir -p "$DEST"
RES="$("$PROBE" verify top 1 "0000000000000000000000000000000000000000" "$WORK/top.tar.gz" "$DEST")"
check "good tarball vs wrong expected hash rejected" "ERR TreeHashMismatch" "$RES"
check "wrong expected hash left the destination empty" "0" "$(find "$DEST" -mindepth 1 | wc -l)"

# ---------------------------------------------------------------------------
echo
echo "==> 3. a verified tarball extracts to the tree it promised"

DEST="$WORK/dest-good"; mkdir -p "$DEST"
check "top_level extract" "OK" "$("$PROBE" verify top 1 "$GIT_TOP" "$WORK/top.tar.gz" "$DEST")"
check "extracted tree re-hashes (ajt)" "$GIT_TOP" "$("$PROBE" dirhash "$DEST")"
check "extracted tree re-hashes (GitTools oracle)" "$GIT_TOP" \
  "$(julia -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$DEST")"
if [ -x "$DEST/run.sh" ]; then ok "executable bit survived"; else bad "executable bit survived"; fi
if [ -L "$DEST/link" ]; then ok "symlink survived as a symlink"; else bad "symlink survived as a symlink"; fi
check "file content" "world" "$(cat "$DEST/sub/b.txt")"

# ---------------------------------------------------------------------------
echo
echo "==> 4. the GitHub /tarball shape: strip one directory, drop pax_global_header"

check "gh hash (with pax entry) == top-level hash" "$GIT_TOP" "$("$PROBE" hash gh 1 "$WORK/gh.tar")"
check "gh hash (no pax entry)   == top-level hash" "$GIT_TOP" "$("$PROBE" hash gh 1 "$WORK/gh_nopax.tar")"
# Not stripping must give a DIFFERENT hash, or the test above proves nothing.
if [ "$("$PROBE" hash top 1 "$WORK/gh_nopax.tar")" = "$GIT_TOP" ]; then
  bad "wrapper directory does not affect the hash -- fixture is degenerate"
else
  ok "the wrapper directory does change the hash when not stripped"
fi

DEST="$WORK/dest-gh"; mkdir -p "$DEST"
check "gh extract" "OK" "$("$PROBE" verify gh 1 "$GIT_TOP" "$WORK/gh.tar.gz" "$DEST")"
if [ -e "$DEST/JuliaLang-Example-1a2b3c4" ]; then bad "wrapper directory was extracted"; else ok "wrapper directory is gone"; fi
if [ -e "$DEST/pax_global_header" ]; then bad "pax_global_header was extracted"; else ok "pax_global_header is gone"; fi
check "gh extracted tree re-hashes (GitTools oracle)" "$GIT_TOP" \
  "$(julia -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$DEST")"

# A `top = false` archive with two roots is what Pkg asserts against.
check "two roots rejected" "ERR NotSingleRooted" "$("$PROBE" hash gh 1 "$WORK/two.tar")"

# ---------------------------------------------------------------------------
echo
echo "==> 5. hostile archives are refused before the filesystem is touched"

# The archive hashes to the innocent tree, so it is fed the hash of THAT tree:
# a missing guard extracts happily and writes outside the destination.
AIM="$(julia -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$WORK/aim")"
check "the attack archive really does hash to the innocent tree" \
  "$AIM" "$("$PROBE" hash top 1 "$WORK/aim.tar")"

DEST="$WORK/dest-symlink"; mkdir -p "$DEST"
RES="$("$PROBE" verify top 1 "$AIM" "$WORK/attack_symlink.tar" "$DEST")"
check "symlink-prefix archive rejected" "ERR SymlinkPrefix" "$RES"
check "symlink-prefix left the destination empty" "0" "$(find "$DEST" -mindepth 1 | wc -l)"
# The escape target is outside the destination entirely -- a temp-dir-then-
# rename install model gives no protection against this one.
if [ -e "$WORK/escaped" ]; then bad "content escaped to $WORK/escaped"; else ok "nothing escaped the destination"; fi

# Julia refuses the same archive by name, which is where the rule comes from --
# and it refuses it in the HASHER, not only in the extractor. treehash.hashTar
# ports the hashing but not that check, so this is the oracle that says the
# guard belongs in extract.zig.
JHASH="$(julia -e '
using Tar
try
    print(open(Tar.tree_hash, ARGS[1]))
catch e
    print(occursin("symlink prefix", sprint(showerror, e)) ? "REFUSED" : "OTHER")
end' "$WORK/attack_symlink.tar")"
check "Julia's Tar.tree_hash refuses it too (extract.jl:361-368)" "REFUSED" "$JHASH"

JRES="$(julia -e '
using Tar
d = mktempdir()
try
    Tar.extract(ARGS[1], joinpath(d, "out"))
    print("EXTRACTED")
catch e
    print(occursin("symlink prefix", sprint(showerror, e)) ? "REFUSED" : "OTHER")
end' "$WORK/attack_symlink.tar")"
check "Julia's Tar.extract refuses it too (extract.jl:361-368)" "REFUSED" "$JRES"

DEST="$WORK/dest-dup"; mkdir -p "$DEST"
check "duplicate path rejected" "ERR ConflictingPaths" \
  "$("$PROBE" verify top 1 "$AIM" "$WORK/attack_dup.tar" "$DEST")"
check "duplicate path left the destination empty" "0" "$(find "$DEST" -mindepth 1 | wc -l)"

DEST="$WORK/dest-dotdot"; mkdir -p "$DEST"
check "'..' component rejected" "ERR UnsafePath" \
  "$("$PROBE" verify top 1 "$AIM" "$WORK/attack_dotdot.tar" "$DEST")"
check "'..' component left the destination empty" "0" "$(find "$DEST" -mindepth 1 | wc -l)"

# ---------------------------------------------------------------------------
if [ $WITH_GENERAL -eq 1 ] && [ -f "$DEPOT/registries/General.tar.gz" ]; then
  echo
  echo "==> 6. the real General registry (10.9 MB -> ~84 MB, ~59k files)"
  REG_GZ="$DEPOT/registries/General.tar.gz"
  RECORDED="$(sed -n 's/^git-tree-sha1 *= *"\(.*\)"/\1/p' "$DEPOT/registries/General.toml")"
  if [ -z "$RECORDED" ]; then
    bad "no git-tree-sha1 in General.toml"
  else
    check "ajt stream hash == the registry's recorded git-tree-sha1" \
      "$RECORDED" "$("$PROBE" hash top 0 "$REG_GZ")"
    DEST="$WORK/dest-general"; mkdir -p "$DEST"
    check "General verifies and extracts" "OK" \
      "$("$PROBE" verify top 0 "$RECORDED" "$REG_GZ" "$DEST")"
    check "extracted General re-hashes to the same value (GitTools oracle)" "$RECORDED" \
      "$(julia -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$DEST")"
  fi
else
  echo
  echo "==> 6. skipped (no $DEPOT/registries/General.tar.gz, or --no-general)"
fi

# ---------------------------------------------------------------------------
echo
if [ $FAIL -eq 0 ]; then
  echo "PASS — $PASS checks: ajt agrees with Tar.tree_hash and GitTools.tree_hash,"
  echo "       and rejects bad content without writing a byte"
  exit 0
fi
echo "FAIL — $FAIL of $((PASS+FAIL)) checks"
[ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect)"
exit 1
