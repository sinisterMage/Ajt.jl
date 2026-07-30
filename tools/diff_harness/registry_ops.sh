#!/usr/bin/env bash
# Differential gate for `ajt registry add` / `ajt registry update`.
#
# This is the first gate that exercises a WRITE driven by the network, so it
# checks both halves: that Ajt resolves the same registry snapshot Pkg would,
# and that what it then writes is a registry stock Pkg can load.
#
#   1. GIT        — a registry that is a git CLONE, which is a first-class Pkg
#                   layout (`Registry.jl:260-262`, `:501-560`) and the one
#                   shape with no tarball anywhere in it. Hermetic: the remote
#                   is a `file://` fixture repository and the Pkg server is a
#                   loopback. `ajt registry add --url` must produce a clone
#                   `reachable_registries` accepts, `status`/`show`/`resolve`
#                   must read it, `update` must fetch and fast-forward it, a
#                   dirty worktree and a detached HEAD must be refused, and an
#                   `add` over the Pkg server beside it must leave `.git`
#                   untouched.
#   2. INDEX      — `ajt registry add --dry-run` must report exactly the
#                   (uuid, tree-hash) pairs `Pkg.Registry.pkg_server_registry_info()`
#                   returns (`Registry.jl:74-95`).
#   3. HASH       — the decompressed tarball's `Tar.tree_hash` must equal both
#                   the hash embedded in the download URL and Julia's own
#                   `Tar.tree_hash` of the same bytes. This is the check
#                   `verify_archive_tree_hash` performs
#                   (`PlatformEngines.jl:692-699`), and the reason the download
#                   needs no separate signature.
#   4. INSTALL    — after `ajt registry add`, stock Pkg must load the result:
#                   `reachable_registries()` has to agree on the name, the
#                   uuid, the recorded `git-tree-sha1` and the package count.
#   5. UPDATE     — a second run must either no-op or re-fetch, and the stamp
#                   must describe whatever ends up on disk (`Registry.jl:447`).
#   6. REJECTION  — against a loopback server, whose content cannot move: a
#                   tampered tarball is refused with NOTHING written into
#                   `registries/`; the intact one installs; `update` on an
#                   unchanged registry is a no-op; and the `--unpack` layout
#                   installs, replaces the tarball layout, updates through its
#                   `.tree_info.toml`, and is loadable by stock Pkg.
#
# EVERY install goes into a `mktemp -d` depot. The user's real ~/.julia is only
# ever read, and only for Julia's own precompilation cache — this script never
# writes a registry there.
#
# Step 1 is hermetic and ALWAYS runs. Steps 2-5 need the network and SKIP
# (exit 0, loudly) whenever Julia's own oracle cannot reach the Pkg server, so
# an offline box reports "skipped" rather than a false failure; step 6 is
# served from 127.0.0.1. Step 1 runs first for exactly that reason: the one
# section that can never legitimately skip must not sit behind the ones that
# can.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 not on PATH (needed for steps 1 and 6)" >&2; exit 2; }
command -v git >/dev/null || { echo "ERROR: git not on PATH (needed for step 1)" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing — run 'zig build' first" >&2; exit 2; }

# A stray JULIA_PKG_UNPACK_REGISTRY would make Julia read registries as
# directories and Ajt write them as directories, so the comparison would still
# hold — but the paths asserted below are the tarball ones. Pin the default.
unset JULIA_PKG_UNPACK_REGISTRY

WORK="$(mktemp -d -t ajt-regops-XXXXXX)"
DEPOT="$WORK/depot"
mkdir -p "$DEPOT"
SRV_PID=""
GIT_SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "$GIT_SRV_PID" ] && kill "$GIT_SRV_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# `DEFAULT_REGISTRIES` (`Registry.jl:61-68`). The Pkg-server protocol addresses
# registries by UUID, so this is the identity the whole script keys on.
GENERAL_UUID=23338594-aafe-5451-b93e-139f81909106

# Julia reads from the REAL depot so `using Pkg` stays precompiled; the temp
# depot is passed explicitly wherever a registry is involved. `Pkg` is a
# stdlib, so this reads ~/.julia and never adds anything to it.
REAL_DEPOT="${JULIA_DEPOT_PATH:-$HOME/.julia}"

# A loopback Pkg server, used by step 1 and again by step 6. Written once here
# because step 1 runs before the network check and step 6 after it.
cat > "$WORK/serve.py" <<'PY'
import http.server, os, socketserver, sys
os.chdir(sys.argv[1])
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY

# Starts serve.py on $1, waits for its port, and echoes it.
start_server() {
  local docroot="$1" portfile="$2" errfile="$3"
  python3 "$WORK/serve.py" "$docroot" > "$portfile" 2>"$errfile" &
  echo $! > "$portfile.pid"
  for _ in $(seq 1 100); do
    [ -s "$portfile" ] && break
    sleep 0.05
  done
  cat "$portfile"
}

# ==========================================================================
echo "==> 1/6 a registry that is a git clone (hermetic)"
# ==========================================================================
#
# The layout with no tarball in it anywhere: `registries/General/` holding a
# `Registry.toml` and a `.git`. Pkg installs it whenever the Pkg server cannot
# serve (`Registry.jl:260-262`) and maintains it by fetching one branch and
# fast-forwarding (`:501-560`). Nothing here touches the network: the remote is
# a `file://` repository built below, and the Pkg-server half of the last check
# is a loopback serving a tarball of that same content.

FIXTURE="$WORK/fixture"
GIT_DEPOT="$WORK/depot-git"
mkdir -p "$FIXTURE/D/Demo" "$FIXTURE/A/Alpha" "$GIT_DEPOT"

# A real registry in miniature: two packages, a compressed Deps/Compat pair,
# and a version range that spans them. Named General with General's own uuid
# because `ajt resolve` reads the registry called General, and because the
# regression guard at the end needs `ajt registry add General` to address this
# very directory.
cat > "$FIXTURE/Registry.toml" <<EOF
name = "General"
uuid = "$GENERAL_UUID"

[packages]
90137ffa-7385-5640-81b9-e52037218182 = { name = "Demo", path = "D/Demo" }
00000000-0000-0000-0000-0000000000a1 = { name = "Alpha", path = "A/Alpha" }
EOF
cat > "$FIXTURE/D/Demo/Package.toml" <<'EOF'
name = "Demo"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
repo = "https://example.invalid/Demo.jl.git"
EOF
cat > "$FIXTURE/D/Demo/Versions.toml" <<'EOF'
["1.0.0"]
git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

["1.1.0"]
git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EOF
cat > "$FIXTURE/D/Demo/Deps.toml" <<'EOF'
["1"]
Alpha = "00000000-0000-0000-0000-0000000000a1"
EOF
cat > "$FIXTURE/D/Demo/Compat.toml" <<'EOF'
["1"]
Alpha = "0.5"
julia = "1.6 - 1"
EOF
cat > "$FIXTURE/A/Alpha/Package.toml" <<'EOF'
name = "Alpha"
uuid = "00000000-0000-0000-0000-0000000000a1"
repo = "https://example.invalid/Alpha.jl.git"
EOF
cat > "$FIXTURE/A/Alpha/Versions.toml" <<'EOF'
["0.5.0"]
git-tree-sha1 = "cccccccccccccccccccccccccccccccccccccccc"
EOF
cat > "$FIXTURE/A/Alpha/Compat.toml" <<'EOF'
["0.5"]
julia = "1.6 - 1"
EOF

# A deterministic identity, and no system config: a developer with global
# `commit.gpgsign` would otherwise have every fixture commit block on a prompt.
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=ajt GIT_AUTHOR_EMAIL=ajt@example.invalid
export GIT_COMMITTER_NAME=ajt GIT_COMMITTER_EMAIL=ajt@example.invalid
export GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000"
export GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000"

git -C "$FIXTURE" init --quiet --initial-branch=master ||
  { echo "FAIL: could not init the fixture repository" >&2; exit 1; }
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit --quiet -m "initial" ||
  { echo "FAIL: could not commit the fixture registry" >&2; exit 1; }
echo "    fixture registry at file://$FIXTURE (2 packages, branch master)"

# --- add by clone ---------------------------------------------------------
# `--server ""` is `registry_use_pkg_server()` false, which is one of the two
# ways Julia reaches `LibGit2.clone` (`Registry.jl:203` -> `:260-262`).
if ! "$AJT_BIN" registry add --depot "$GIT_DEPOT" --server "" --url "file://$FIXTURE" \
      > "$WORK/git.add" 2>"$WORK/git.add.err"; then
  echo "FAIL: 'ajt registry add --url' could not clone the fixture:" >&2
  tail -10 "$WORK/git.add.err" >&2
  exit 1
fi
sed 's/^/    /' "$WORK/git.add"

grep -q '^action    added$' "$WORK/git.add" ||
  { echo "FAIL: add did not report 'added'" >&2; exit 1; }
grep -q '^layout    git_clone$' "$WORK/git.add" ||
  { echo "FAIL: add did not report the git_clone layout" >&2; exit 1; }
# The name comes from the CLONE's own Registry.toml (`:280-282`) — nothing on
# that command line said "General".
grep -q '^registry  General$' "$WORK/git.add" ||
  { echo "FAIL: the installed name did not come from the clone's Registry.toml" >&2; exit 1; }
[ -d "$GIT_DEPOT/registries/General/.git" ] ||
  { echo "FAIL: no .git in the installed registry — that is not a clone" >&2; exit 1; }
[ -f "$GIT_DEPOT/registries/General/Registry.toml" ] ||
  { echo "FAIL: no Registry.toml in the installed registry" >&2; exit 1; }
# Published by rename, so no staging directory survives.
LEFT=$(ls -A "$GIT_DEPOT/registries" | grep -v '^General$' || true)
[ -z "$LEFT" ] || { echo "FAIL: unexpected entries in registries/: $LEFT" >&2; exit 1; }

# --- stock Pkg accepts the clone ------------------------------------------
# THE landmark for this half: `reachable_registries` has to find it, read its
# name and uuid, count its packages, and report `tree_info === nothing` —
# which is what tells Pkg to maintain it over git rather than over the server.
JULIA_DEPOT_PATH="$REAL_DEPOT" julia -e '
using Pkg
for r in Pkg.Registry.reachable_registries(depots = ARGS[1])
    println(r.name, " ", r.uuid, " ", r.tree_info, " ", length(r.pkgs))
end' "$GIT_DEPOT" > "$WORK/julia.clone" 2>"$WORK/julia.clone.err"

if [ ! -s "$WORK/julia.clone" ]; then
  echo "FAIL: Pkg found no registry in the clone Ajt just made:" >&2
  tail -10 "$WORK/julia.clone.err" >&2
  exit 1
fi
read -r C_NAME C_UUID C_TREE C_PKGS < "$WORK/julia.clone"
echo "    julia: $C_NAME $C_UUID tree_info=$C_TREE $C_PKGS packages"
[ "$C_NAME" = "General" ]       || { echo "FAIL: Pkg read the name as '$C_NAME'" >&2; exit 1; }
[ "$C_UUID" = "$GENERAL_UUID" ] || { echo "FAIL: Pkg read the uuid as '$C_UUID'" >&2; exit 1; }
[ "$C_PKGS" = "2" ]             || { echo "FAIL: Pkg counted $C_PKGS packages, not 2" >&2; exit 1; }
# `tree_info === nothing` IS the git layout (`registry_instance.jl:338-342`).
[ "$C_TREE" = "nothing" ] ||
  { echo "FAIL: Pkg reports tree_info=$C_TREE, so it is not reading this as a clone" >&2; exit 1; }

# --- ajt reads the same directory -----------------------------------------
if ! "$AJT_BIN" registry status --depot "$GIT_DEPOT" > "$WORK/git.status" 2>"$WORK/git.status.err"; then
  echo "FAIL: 'ajt registry status' cannot read a git-cloned registry:" >&2
  tail -10 "$WORK/git.status.err" >&2
  exit 1
fi
S_NAME=$(awk '$1 == "registry" { print $2 }' "$WORK/git.status")
S_UUID=$(awk '$1 == "uuid" { print $2 }' "$WORK/git.status")
S_PKGS=$(awk '$1 == "packages" { print $2 }' "$WORK/git.status")
S_SRC=$(awk '$1 == "source" { print $2 }' "$WORK/git.status")
echo "    ajt:   $S_NAME $S_UUID source=$S_SRC $S_PKGS packages"
[ "$S_NAME" = "$C_NAME" ] || { echo "FAIL: name $S_NAME != $C_NAME" >&2; exit 1; }
[ "$S_UUID" = "$C_UUID" ] || { echo "FAIL: uuid $S_UUID != $C_UUID" >&2; exit 1; }
[ "$S_PKGS" = "$C_PKGS" ] || { echo "FAIL: package count $S_PKGS != $C_PKGS" >&2; exit 1; }
# Which reader answered, not just that one did: a directory reported as
# "archive" would make this whole step unfalsifiable.
[ "$S_SRC" = "directory" ] ||
  { echo "FAIL: ajt read the clone through the '$S_SRC' backend, not 'directory'" >&2; exit 1; }

# --- the uncompressed deps agree, out of the same clone -------------------
# The part most likely to be quietly wrong: a directory reader that finds the
# files but uncompresses the Deps/Compat ranges differently. Both sides read
# THIS clone, so any difference is the reader.
"$AJT_BIN" registry show --depot "$GIT_DEPOT" Demo Alpha > "$WORK/ajt.show" 2>"$WORK/ajt.show.err" ||
  { echo "FAIL: 'ajt registry show' failed against the clone" >&2; tail -5 "$WORK/ajt.show.err" >&2; exit 1; }

JULIA_DEPOT_PATH="$REAL_DEPOT" julia -e '
using Pkg
const JULIA_UUID = Base.UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
reg = first(Pkg.Registry.reachable_registries(depots = ARGS[1]))
for name in ARGS[2:end]
    entry = first(pe for (_, pe) in reg.pkgs if pe.name == name)
    info = Pkg.Registry.registry_info(entry)
    Pkg.Registry.initialize_uncompressed!(info)
    uuid2name = Dict{Base.UUID,String}(JULIA_UUID => "julia")
    for (_, d) in info.deps, (n, u) in d
        uuid2name[u] = n
    end
    println("== ", name)
    for v in sort(collect(keys(info.version_info)))
        vi = info.version_info[v]
        println(v, "  ", bytes2hex(vi.git_tree_sha1.bytes))
        rows = String[]
        for (u, spec) in vi.uncompressed_compat
            push!(rows, string("    ", get(uuid2name, u, string(u)), " ", sprint(print, spec)))
        end
        for r in sort(rows)
            println(r)
        end
    end
end' "$GIT_DEPOT" Demo Alpha > "$WORK/julia.show" 2>"$WORK/julia.show.err"

if [ ! -s "$WORK/julia.show" ]; then
  echo "FAIL: the Julia oracle produced nothing for the cloned registry:" >&2
  tail -10 "$WORK/julia.show.err" >&2
  exit 1
fi
# The corpus really is there: two packages, three versions, and a dep row.
grep -q '^== Demo$' "$WORK/julia.show" && grep -q '^== Alpha$' "$WORK/julia.show" ||
  { echo "FAIL: the oracle output does not contain both packages" >&2; cat "$WORK/julia.show" >&2; exit 1; }
grep -q '^    Alpha 0.5$' "$WORK/julia.show" ||
  { echo "FAIL: the oracle found no uncompressed Alpha dep; the fixture proves nothing" >&2
    cat "$WORK/julia.show" >&2; exit 1; }
if ! diff -q "$WORK/julia.show" "$WORK/ajt.show" >/dev/null; then
  echo "FAIL: reading the SAME clone, ajt and Pkg disagree (julia | ajt):" >&2
  diff "$WORK/julia.show" "$WORK/ajt.show" >&2
  exit 1
fi
echo "    $(grep -c '^==' "$WORK/ajt.show") packages, $(grep -cE '^[0-9]' "$WORK/ajt.show") versions: uncompressed deps identical to Pkg's"

# --- and the resolver reads it too ----------------------------------------
# `ajt registry status` goes through `main.zig`'s own backend opener;
# `ajt resolve` goes through `registry/source.zig`. They are two doors onto
# the same arm and only one of them was wired at first.
ENVDIR="$WORK/env"
mkdir -p "$ENVDIR"
cat > "$ENVDIR/Project.toml" <<'EOF'
name = "Consumer"
uuid = "22222222-3333-4444-5555-666666666666"

[deps]
Demo = "90137ffa-7385-5640-81b9-e52037218182"

[compat]
Demo = "1"
EOF
# The environment has no manifest yet, so the Julia version it targets has to
# be stated: `resolve` reads it from `manifest.julia_version` otherwise.
JULIA_VERSION=$(julia -e 'print(VERSION)')
if ! "$AJT_BIN" resolve --depot "$GIT_DEPOT" --julia-version "$JULIA_VERSION" "$ENVDIR" \
      > "$WORK/ajt.resolve" 2>"$WORK/ajt.resolve.err"; then
  echo "FAIL: 'ajt resolve' cannot use a git-cloned registry:" >&2
  tail -10 "$WORK/ajt.resolve.err" >&2
  exit 1
fi
grep -q 'Demo' "$WORK/ajt.resolve" && grep -q 'Alpha' "$WORK/ajt.resolve" ||
  { echo "FAIL: resolve did not select Demo and its dep Alpha out of the clone:" >&2
    cat "$WORK/ajt.resolve" >&2; exit 1; }
echo "    resolve selects $(grep -c . "$WORK/ajt.resolve") lines including Demo + Alpha"

# --- update: fetch and fast-forward ---------------------------------------
cat > "$FIXTURE/D/Demo/Versions.toml" <<'EOF'
["1.0.0"]
git-tree-sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

["1.1.0"]
git-tree-sha1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

["2.0.0"]
git-tree-sha1 = "dddddddddddddddddddddddddddddddddddddddd"
EOF
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit --quiet -m "Demo 2.0.0"

if ! "$AJT_BIN" registry update --depot "$GIT_DEPOT" --server "" > "$WORK/git.upd" 2>"$WORK/git.upd.err"; then
  echo "FAIL: 'ajt registry update' on a git clone failed:" >&2
  tail -10 "$WORK/git.upd.err" >&2
  exit 1
fi
grep -q '^action    updated$' "$WORK/git.upd" ||
  { echo "FAIL: update on a clone did not report 'updated':" >&2; cat "$WORK/git.upd" >&2; exit 1; }
grep -q '^layout    git_clone$' "$WORK/git.upd" ||
  { echo "FAIL: update on a clone did not report the git_clone layout" >&2; exit 1; }
# The fetch landed in `refs/remotes/origin/<branch>` and the fast-forward moved
# the working tree. Fetching into any other namespace would report success and
# change nothing, which is the whole reason this assertion reads the FILE.
grep -q '2.0.0' "$GIT_DEPOT/registries/General/D/Demo/Versions.toml" ||
  { echo "FAIL: update reported success but the working tree did not move" >&2; exit 1; }
"$AJT_BIN" registry show --depot "$GIT_DEPOT" Demo | grep -q '^2\.0\.0' ||
  { echo "FAIL: ajt does not see the new version after update" >&2; exit 1; }
echo "    update fetched one branch and fast-forwarded; Demo 2.0.0 is now readable"

# Stock Pkg must be able to maintain the same clone — the other direction of
# "this is a real Pkg layout, not something only Ajt understands".
if ! JULIA_DEPOT_PATH="$REAL_DEPOT" JULIA_PKG_SERVER="" julia -e '
using Pkg
Pkg.Registry.update(depots = [ARGS[1]])' "$GIT_DEPOT" > "$WORK/julia.upd" 2>&1; then
  echo "FAIL: stock Pkg could not update the clone Ajt produced:" >&2
  tail -10 "$WORK/julia.upd" >&2
  exit 1
fi
grep -q 'Updating registry at' "$WORK/julia.upd" ||
  { echo "FAIL: Pkg did not recognise the clone as a registry to update:" >&2
    cat "$WORK/julia.upd" >&2; exit 1; }
echo "    stock Pkg updates the very same clone"

# --- the two refusals ------------------------------------------------------
BEFORE=$(git -C "$GIT_DEPOT/registries/General" rev-parse HEAD)

# `isdirty` (`Registry.jl:511`). An UNTRACKED file is NOT dirty — libgit2's
# diff_tree_to_workdir does not include untracked entries — so an editor
# backup lying in registries/General must not block anything.
echo "scratch" > "$GIT_DEPOT/registries/General/untracked.txt"
"$AJT_BIN" registry update --depot "$GIT_DEPOT" --server "" > "$WORK/git.untracked" 2>&1 ||
  { echo "FAIL: an UNTRACKED file made update refuse; that is not what isdirty means" >&2
    cat "$WORK/git.untracked" >&2; exit 1; }
rm -f "$GIT_DEPOT/registries/General/untracked.txt"

# A TRACKED file changed IS dirty.
echo '# local edit' >> "$GIT_DEPOT/registries/General/Registry.toml"
if "$AJT_BIN" registry update --depot "$GIT_DEPOT" --server "" > "$WORK/git.dirty" 2>&1; then
  echo "FAIL: update ran on a DIRTY registry; Pkg refuses (Registry.jl:511-513)" >&2
  cat "$WORK/git.dirty" >&2
  exit 1
fi
grep -q 'DirtyWorktree' "$WORK/git.dirty" ||
  { echo "FAIL: a dirty registry was refused, but not as DirtyWorktree:" >&2
    tail -5 "$WORK/git.dirty" >&2; exit 1; }
git -C "$GIT_DEPOT/registries/General" checkout --quiet -- Registry.toml

# `!isattached` (`:515-517`): a detached HEAD has no branch, and the refspec
# `+refs/heads/$branch:...` has nothing to name.
git -C "$GIT_DEPOT/registries/General" checkout --quiet --detach HEAD
if "$AJT_BIN" registry update --depot "$GIT_DEPOT" --server "" > "$WORK/git.detached" 2>&1; then
  echo "FAIL: update ran on a DETACHED registry; Pkg refuses (Registry.jl:515-517)" >&2
  cat "$WORK/git.detached" >&2
  exit 1
fi
grep -q 'DetachedHead' "$WORK/git.detached" ||
  { echo "FAIL: a detached registry was refused, but not as DetachedHead:" >&2
    tail -5 "$WORK/git.detached" >&2; exit 1; }
git -C "$GIT_DEPOT/registries/General" checkout --quiet master

AFTER=$(git -C "$GIT_DEPOT/registries/General" rev-parse HEAD)
[ "$BEFORE" = "$AFTER" ] ||
  { echo "FAIL: a refused update still moved HEAD ($BEFORE -> $AFTER)" >&2; exit 1; }
echo "    dirty and detached are refused, and neither moved HEAD"

# --- THE regression guard --------------------------------------------------
# `ajt registry add General` over the Pkg server, into the depot that holds
# the clone. `publishCompressed` used to end in an unconditional
# `deleteTree(<Name>)`, which took `.git` with it; Pkg cannot, because its
# `rm` sits inside `if reg.tree_info !== nothing` and a clone has no
# `tree_info` (`Registry.jl:463-467`). Nothing about the run looks wrong when
# it happens — the tarball installs and the loss surfaces days later.
GIT_DOCROOT="$WORK/docroot-git"
mkdir -p "$GIT_DOCROOT/registry/$GENERAL_UUID"
# A tarball of the fixture content — WITHOUT `.git`, which a Pkg-server
# snapshot never contains. Members named explicitly so there is no `./` prefix
# and no repository metadata.
tar -cf "$WORK/fixture.tar" -C "$FIXTURE" Registry.toml D A ||
  { echo "FAIL: could not build the fixture tarball" >&2; exit 1; }
FIX_HASH=$("$AJT_BIN" tree-hash "$WORK/fixture.tar" | awk '{print $1}')
[ ${#FIX_HASH} -eq 40 ] ||
  { echo "FAIL: no tree hash for the fixture tarball" >&2; exit 1; }
gzip -c "$WORK/fixture.tar" > "$GIT_DOCROOT/registry/$GENERAL_UUID/$FIX_HASH"
printf '/registry/%s/%s\n' "$GENERAL_UUID" "$FIX_HASH" > "$GIT_DOCROOT/registries"

GIT_PORT=$(start_server "$GIT_DOCROOT" "$WORK/git.port" "$WORK/git.serve.err")
GIT_SRV_PID=$(cat "$WORK/git.port.pid")
[ -n "$GIT_PORT" ] ||
  { echo "FAIL: the loopback server for step 1 did not start" >&2; cat "$WORK/git.serve.err" >&2; exit 1; }

if ! "$AJT_BIN" registry add --depot "$GIT_DEPOT" --server "http://127.0.0.1:$GIT_PORT" \
      > "$WORK/git.overlay" 2>"$WORK/git.overlay.err"; then
  echo "FAIL: adding the compressed registry beside the clone failed:" >&2
  tail -10 "$WORK/git.overlay.err" >&2
  exit 1
fi
grep -q '^layout    tarball$' "$WORK/git.overlay" ||
  { echo "FAIL: the Pkg-server add did not install the tarball layout" >&2; exit 1; }
[ -f "$GIT_DEPOT/registries/General.tar.gz" ] ||
  { echo "FAIL: the tarball was not written" >&2; exit 1; }
[ -f "$GIT_DEPOT/registries/General.toml" ] ||
  { echo "FAIL: the stamp was not written" >&2; exit 1; }
# ...and the clone is still a clone, byte for byte.
[ -d "$GIT_DEPOT/registries/General/.git" ] ||
  { echo "FAIL: 'registry add' over the Pkg server DESTROYED the git clone beside it" >&2; exit 1; }
STILL=$(git -C "$GIT_DEPOT/registries/General" rev-parse HEAD)
[ "$STILL" = "$AFTER" ] ||
  { echo "FAIL: the clone survived but its HEAD moved ($AFTER -> $STILL)" >&2; exit 1; }
git -C "$GIT_DEPOT/registries/General" remote get-url origin >/dev/null ||
  { echo "FAIL: the clone survived but lost its origin remote" >&2; exit 1; }
echo "    a Pkg-server add beside the clone leaves .git, HEAD and origin intact"

kill "$GIT_SRV_PID" 2>/dev/null
GIT_SRV_PID=""

# ==========================================================================
SERVER=$(julia -e 'using Pkg; s = Pkg.pkg_server(); print(s === nothing ? "" : s)')
if [ -z "$SERVER" ]; then
  echo
  echo "SKIP (steps 2-6) — the Pkg server is disabled (JULIA_PKG_SERVER=\"\")."
  echo "       Step 1 above covers the clone path Pkg falls back to in that case."
  exit 0
fi
echo
echo "server: $SERVER"
echo "depot:  $DEPOT (temporary)"

# --------------------------------------------------------------------------
echo "==> 2/6 the server index (network)"

# The oracle swallows its own network failure and returns `nothing` (it only
# @warns), which is exactly the signal we want for "skip".
julia -e '
using Pkg
r = Pkg.Registry.pkg_server_registry_info()
r === nothing && exit(0)
_, info = r
for (u, h) in info
    println(u, " ", bytes2hex(h.bytes))
end' > "$WORK/julia.pins" 2>"$WORK/julia.pins.err"
sort -o "$WORK/julia.pins" "$WORK/julia.pins"

if [ ! -s "$WORK/julia.pins" ]; then
  echo
  echo "SKIP — Julia could not reach $SERVER/registries either; treating this as no network."
  sed -n '1,3p' "$WORK/julia.pins.err" >&2
  exit 0
fi

if ! "$AJT_BIN" registry add --dry-run --depot "$DEPOT" > "$WORK/ajt.dry" 2>"$WORK/ajt.dry.err"; then
  echo
  echo "FAIL: 'ajt registry add --dry-run' failed, but Julia reached the server:"
  tail -5 "$WORK/ajt.dry.err" >&2
  exit 1
fi
sed -n 's/^pin  *\([^ ]*\) \([^ ]*\)$/\1 \2/p' "$WORK/ajt.dry" | sort > "$WORK/ajt.pins"

if ! diff -q "$WORK/julia.pins" "$WORK/ajt.pins" >/dev/null; then
  echo
  echo "FAIL: the resolved registry pins diverge (julia | ajt):"
  diff "$WORK/julia.pins" "$WORK/ajt.pins" | head -20
  exit 1
fi
echo "    $(wc -l < "$WORK/julia.pins") pin(s) identical"

# A dry run must not have created anything.
if [ -e "$DEPOT/registries/General.tar.gz" ] || [ -e "$DEPOT/registries/General.toml" ]; then
  echo "FAIL: --dry-run wrote into $DEPOT/registries" >&2
  exit 1
fi

PIN_HASH=$(awk -v u="$GENERAL_UUID" '$1 == u { print $2 }' "$WORK/julia.pins")
if [ -z "$PIN_HASH" ]; then
  echo "SKIP — the server does not advertise the General registry; nothing to install."
  exit 0
fi
echo "    General pins at $PIN_HASH"

# --------------------------------------------------------------------------
echo "==> 3/6 install into the temp depot (network)"

if ! "$AJT_BIN" registry add --depot "$DEPOT" > "$WORK/ajt.add" 2>"$WORK/ajt.add.err"; then
  echo
  echo "FAIL: 'ajt registry add' failed:"
  tail -10 "$WORK/ajt.add.err" >&2
  exit 1
fi
cat "$WORK/ajt.add" | sed 's/^/    /'

for f in General.tar.gz General.toml; do
  [ -f "$DEPOT/registries/$f" ] || { echo "FAIL: $DEPOT/registries/$f was not written" >&2; exit 1; }
done
# Pkg's `verify_compressed_registry_toml` (`registry_instance.jl:410-428`)
# insists on exactly these three keys.
for key in git-tree-sha1 uuid path; do
  grep -q "^$key = " "$DEPOT/registries/General.toml" ||
    { echo "FAIL: General.toml has no '$key' key" >&2; cat "$DEPOT/registries/General.toml" >&2; exit 1; }
done
# Nothing left behind: no staging file, no lock.
LEFTOVERS=$(ls -A "$DEPOT/registries" | grep -v -e '^General\.tar\.gz$' -e '^General\.toml$' || true)
if [ -n "$LEFTOVERS" ]; then
  echo "FAIL: unexpected entries left in registries/:" >&2
  echo "$LEFTOVERS" >&2
  exit 1
fi

STAMP_HASH=$(sed -n 's/^git-tree-sha1 = "\(.*\)"$/\1/p' "$DEPOT/registries/General.toml")
if [ "$STAMP_HASH" != "$PIN_HASH" ]; then
  echo "FAIL: General.toml records $STAMP_HASH but the server pinned $PIN_HASH" >&2
  exit 1
fi
echo "    General.toml git-tree-sha1 == the server's pin"

# --------------------------------------------------------------------------
echo "==> 4/6 the tree hash is the one Julia computes"

gzip -dc "$DEPOT/registries/General.tar.gz" > "$WORK/General.tar" ||
  { echo "FAIL: the installed tarball does not decompress" >&2; exit 1; }

# `ajt tree-hash <file>.tar` uses the tar-stream hasher with skip_empty=false,
# i.e. the exact function `verify_archive_tree_hash` calls.
AJT_TREE=$("$AJT_BIN" tree-hash "$WORK/General.tar" | awk '{print $1}')
JULIA_TREE=$(julia -e 'using Tar; print(open(Tar.tree_hash, ARGS[1]))' "$WORK/General.tar")

if [ "$AJT_TREE" != "$JULIA_TREE" ]; then
  echo "FAIL: Tar.tree_hash disagrees — julia $JULIA_TREE, ajt $AJT_TREE" >&2
  exit 1
fi
if [ "$AJT_TREE" != "$PIN_HASH" ]; then
  echo "FAIL: the installed content hashes to $AJT_TREE but the URL named $PIN_HASH" >&2
  exit 1
fi
echo "    ajt == julia == the URL's hash ($AJT_TREE)"

# --------------------------------------------------------------------------
echo "==> 5/6 stock Pkg loads what Ajt wrote"

JULIA_DEPOT_PATH="$REAL_DEPOT" julia -e '
using Pkg
regs = Pkg.Registry.reachable_registries(depots = ARGS[1])
for r in regs
    println(r.name, " ", r.uuid, " ", r.tree_info, " ", length(r.pkgs))
end' "$DEPOT" > "$WORK/julia.installed" 2>"$WORK/julia.installed.err"

if [ ! -s "$WORK/julia.installed" ]; then
  echo "FAIL: Pkg found no registry in the depot Ajt just wrote:" >&2
  tail -10 "$WORK/julia.installed.err" >&2
  exit 1
fi
read -r J_NAME J_UUID J_TREE J_PKGS < "$WORK/julia.installed"
echo "    julia: $J_NAME $J_UUID $J_TREE $J_PKGS packages"

"$AJT_BIN" registry status --depot "$DEPOT" --source archive > "$WORK/ajt.status" || {
  echo "FAIL: 'ajt registry status' could not read the registry it installed" >&2; exit 1; }
A_NAME=$(awk '$1 == "registry" { print $2 }' "$WORK/ajt.status")
A_UUID=$(awk '$1 == "uuid" { print $2 }' "$WORK/ajt.status")
A_PKGS=$(awk '$1 == "packages" { print $2 }' "$WORK/ajt.status")
echo "    ajt:   $A_NAME $A_UUID $STAMP_HASH $A_PKGS packages"

# The package count is NOT hard-coded: General grows every day, so the only
# durable assertion is that both readers see the same snapshot the same way.
[ "$J_NAME" = "$A_NAME" ] || { echo "FAIL: name $J_NAME != $A_NAME" >&2; exit 1; }
[ "$J_UUID" = "$A_UUID" ] || { echo "FAIL: uuid $J_UUID != $A_UUID" >&2; exit 1; }
[ "$J_TREE" = "$STAMP_HASH" ] || { echo "FAIL: tree $J_TREE != $STAMP_HASH" >&2; exit 1; }
[ "$J_PKGS" = "$A_PKGS" ] || { echo "FAIL: package count $J_PKGS != $A_PKGS" >&2; exit 1; }
echo "    name, uuid, git-tree-sha1 and package count all agree"

# `update` against the LIVE server has two legitimate outcomes, and asserting
# only the first is a flake: General is re-tagged many times a day, and this
# gate has already observed the pin move between its own `add` and `update`
# (`09a84290…` → `8f894b5f…` inside one run). So accept either, and check the
# stamp still describes whatever is on disk afterwards. The DETERMINISTIC
# no-op assertion lives in step 5, against a server whose content cannot move.
"$AJT_BIN" registry update --depot "$DEPOT" > "$WORK/ajt.update" 2>&1 ||
  { echo "FAIL: 'ajt registry update' errored" >&2; cat "$WORK/ajt.update" >&2; exit 1; }
UPD_ACTION=$(awk '$1 == "action" { print $2 }' "$WORK/ajt.update")
UPD_TREE=$(awk '$1 == "tree" { print $2 }' "$WORK/ajt.update")
case "$UPD_ACTION" in
  up_to_date)
    echo "    update is a no-op (the server still pins $UPD_TREE)" ;;
  updated)
    echo "    the server moved on mid-run; update re-fetched $UPD_TREE" ;;
  *)
    echo "FAIL: unexpected update action '$UPD_ACTION':" >&2
    cat "$WORK/ajt.update" >&2
    exit 1 ;;
esac
NOW_HASH=$(sed -n 's/^git-tree-sha1 = "\(.*\)"$/\1/p' "$DEPOT/registries/General.toml")
if [ "$NOW_HASH" != "$UPD_TREE" ]; then
  echo "FAIL: after update the stamp says $NOW_HASH but ajt reported $UPD_TREE" >&2
  exit 1
fi

# --------------------------------------------------------------------------
echo "==> 6/6 a tampered tarball is rejected (loopback)"

# Serve the SAME index the real server did, but a tarball whose content has
# been altered. Only the tree hash can catch this: the archive still
# decompresses, and is still a well-formed tar.
DOCROOT="$WORK/docroot"
mkdir -p "$DOCROOT/registry/$GENERAL_UUID"
printf '/registry/%s/%s\n' "$GENERAL_UUID" "$PIN_HASH" > "$DOCROOT/registries"

# Flip a byte inside a file's BODY, located through `tarfile.offset_data` --
# NOT at a guessed offset. Landing in a 512-byte header instead would corrupt
# the checksum, and then the archive would be refused for being malformed,
# which is a different code path and would make this step prove nothing about
# the tree-hash comparison.
cat > "$WORK/tamper.py" <<'PY'
import sys, tarfile
src, dst = sys.argv[1], sys.argv[2]
with tarfile.open(src) as t:
    off = next(m.offset_data for m in t if m.isfile() and m.size > 16)
data = bytearray(open(src, "rb").read())
data[off] ^= 0xFF
open(dst, "wb").write(data)
print(off)
PY
TAMPER_OFFSET=$(python3 "$WORK/tamper.py" "$WORK/General.tar" "$WORK/tampered.tar") ||
  { echo "FAIL: could not build the tampered archive" >&2; exit 1; }
gzip -c "$WORK/tampered.tar" > "$DOCROOT/registry/$GENERAL_UUID/$PIN_HASH"

# The tampered archive must still be a WELL-FORMED tar whose hash merely
# differs, or the rejection below would not be the hash check firing.
if ! TAMPERED_TREE=$("$AJT_BIN" tree-hash "$WORK/tampered.tar" 2>"$WORK/tamper.err" | awk '{print $1}'); then
  echo "FAIL: the tampered archive no longer parses as a tar:" >&2
  tail -5 "$WORK/tamper.err" >&2
  exit 1
fi
if [ ${#TAMPERED_TREE} -ne 40 ]; then
  echo "FAIL: 'ajt tree-hash' did not produce a hash for the tampered archive:" >&2
  tail -5 "$WORK/tamper.err" >&2
  exit 1
fi
if [ "$TAMPERED_TREE" = "$PIN_HASH" ]; then
  echo "FAIL: the tamper did not change the tree hash; the test proves nothing" >&2
  exit 1
fi
echo "    one content byte flipped at offset $TAMPER_OFFSET"
echo "    still a valid tar, but hashes to $TAMPERED_TREE, not $PIN_HASH"

PORT=$(start_server "$DOCROOT" "$WORK/port" "$WORK/serve.err")
SRV_PID=$(cat "$WORK/port.pid")
if [ -z "$PORT" ]; then
  echo "FAIL: the loopback server did not start" >&2
  cat "$WORK/serve.err" >&2
  exit 1
fi

# `is_secure_url` counts 127.0.0.1 as secure (`PlatformEngines.jl:43`), so a
# plain http:// loopback is a legitimate stand-in for a Pkg server.
BAD_DEPOT="$WORK/depot-bad"
mkdir -p "$BAD_DEPOT"
if "$AJT_BIN" registry add --depot "$BAD_DEPOT" --server "http://127.0.0.1:$PORT" \
     > "$WORK/ajt.bad" 2>"$WORK/ajt.bad.err"; then
  echo "FAIL: ajt ACCEPTED a tarball that does not match its pinned tree hash" >&2
  cat "$WORK/ajt.bad" >&2
  exit 1
fi
if ! grep -q 'VerificationFailed' "$WORK/ajt.bad.err"; then
  echo "FAIL: the install failed, but not with VerificationFailed:" >&2
  tail -10 "$WORK/ajt.bad.err" >&2
  exit 1
fi

# The crucial half: nothing reached the depot. `registries/` itself is created
# before the lock is taken, so it may exist — but it must be empty.
if [ -d "$BAD_DEPOT/registries" ]; then
  RESIDUE=$(ls -A "$BAD_DEPOT/registries" || true)
  if [ -n "$RESIDUE" ]; then
    echo "FAIL: a rejected download left files behind in registries/:" >&2
    echo "$RESIDUE" >&2
    exit 1
  fi
fi
echo "    rejected with VerificationFailed, registries/ untouched"

# The same server with the INTACT tarball must succeed, so step 5 is the hash
# check firing and not the loopback setup being broken.
cp "$DEPOT/registries/General.tar.gz" "$DOCROOT/registry/$GENERAL_UUID/$PIN_HASH"
GOOD_DEPOT="$WORK/depot-good"
mkdir -p "$GOOD_DEPOT"
if ! "$AJT_BIN" registry add --depot "$GOOD_DEPOT" --server "http://127.0.0.1:$PORT" \
      > "$WORK/ajt.good" 2>"$WORK/ajt.good.err"; then
  echo "FAIL: the loopback server rejected the INTACT tarball too, so step 5 proves nothing:" >&2
  tail -10 "$WORK/ajt.good.err" >&2
  exit 1
fi
echo "    the intact tarball over the same server installs fine"

# The no-op assertion belongs here rather than in step 4: this server's pin
# cannot change underneath us, so `up_to_date` is the only correct answer.
"$AJT_BIN" registry update --depot "$GOOD_DEPOT" --server "http://127.0.0.1:$PORT" \
  > "$WORK/ajt.noop" 2>&1 ||
  { echo "FAIL: update against the loopback errored" >&2; cat "$WORK/ajt.noop" >&2; exit 1; }
if ! grep -q '^action    up_to_date$' "$WORK/ajt.noop"; then
  echo "FAIL: update on an unchanged registry did not report up_to_date:" >&2
  cat "$WORK/ajt.noop" >&2
  exit 1
fi
echo "    update on an unchanged registry is a no-op"

# The unpacked layout end to end, including the layout switch: after
# --unpack the tarball and stamp must be gone, `.tree_info.toml` present, and
# `update` must still recognise the registry through it.
if ! "$AJT_BIN" registry add --unpack --depot "$GOOD_DEPOT" --server "http://127.0.0.1:$PORT" \
      > "$WORK/ajt.unpack" 2>&1; then
  echo "FAIL: --unpack install failed" >&2; cat "$WORK/ajt.unpack" >&2; exit 1
fi
for gone in General.tar.gz General.toml; do
  [ -e "$GOOD_DEPOT/registries/$gone" ] &&
    { echo "FAIL: --unpack left $gone behind; ajt readers open it by name" >&2; exit 1; }
done
[ -f "$GOOD_DEPOT/registries/General/.tree_info.toml" ] ||
  { echo "FAIL: --unpack wrote no .tree_info.toml" >&2; exit 1; }
# `write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))` -- no newline.
printf 'git-tree-sha1 = "%s"' "$PIN_HASH" > "$WORK/expect.tree_info"
if ! cmp -s "$WORK/expect.tree_info" "$GOOD_DEPOT/registries/General/.tree_info.toml"; then
  echo "FAIL: .tree_info.toml is not byte-identical to what Pkg writes" >&2
  diff <(cat "$WORK/expect.tree_info") "$GOOD_DEPOT/registries/General/.tree_info.toml" >&2
  exit 1
fi
"$AJT_BIN" registry update --depot "$GOOD_DEPOT" --server "http://127.0.0.1:$PORT" \
  > "$WORK/ajt.unpack.upd" 2>&1 ||
  { echo "FAIL: update after an --unpack install errored" >&2; cat "$WORK/ajt.unpack.upd" >&2; exit 1; }
if ! grep -q '^action    up_to_date$' "$WORK/ajt.unpack.upd"; then
  echo "FAIL: update did not recognise the unpacked registry:" >&2
  cat "$WORK/ajt.unpack.upd" >&2
  exit 1
fi
echo "    the unpacked layout installs, replaces the tarball one, and updates"

# Stock Pkg must load the unpacked layout too.
JULIA_DEPOT_PATH="$REAL_DEPOT" julia -e '
using Pkg
for r in Pkg.Registry.reachable_registries(depots = ARGS[1])
    println(r.name, " ", r.uuid, " ", r.tree_info, " ", length(r.pkgs))
end' "$GOOD_DEPOT" > "$WORK/julia.unpacked" 2>&1
read -r U_NAME U_UUID U_TREE U_PKGS < "$WORK/julia.unpacked"
if [ "$U_TREE" != "$PIN_HASH" ] || [ "$U_UUID" != "$GENERAL_UUID" ]; then
  echo "FAIL: Pkg read the unpacked registry as '$U_NAME $U_UUID $U_TREE'" >&2
  cat "$WORK/julia.unpacked" >&2
  exit 1
fi
echo "    stock Pkg loads the unpacked layout too ($U_PKGS packages)"

echo
echo "PASS — a git clone is installed, read, resolved against and updated the way"
echo "       Pkg does; pins match Pkg, the install verifies against Tar.tree_hash,"
echo "       stock Pkg loads all three layouts ($A_PKGS packages), update behaves,"
echo "       and a tampered tarball is refused with nothing written."
exit 0
