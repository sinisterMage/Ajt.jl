#!/usr/bin/env bash
# Differential gate for the git half of the install pipeline
# (src/ops/install_packages.zig's `installGitPass`, src/ops/instantiate.zig).
#
# Two seams, both of which end with a package in `packages/<Name>/<slug>` that
# no archive could have produced:
#
#   1. install_git (Operations.jl:830-880) — every archive candidate failed, so
#      Pkg clones `clones/<uuid>` and checks the tree out. Forced here by
#      `--server ''` (no Pkg-server candidate) plus a registry `repo` field that
#      `get_archive_url_for_version` refuses: a `file://` URL locally, and — for
#      the network case — the real Example.jl repository spelled WITHOUT the
#      `.git` suffix, which that function answers `nothing` for
#      (Operations.jl:762-768) while `git clone` handles it fine. The oracle for
#      "there really is no archive URL" is Pkg's own function, called.
#
#   2. A `repo-url` manifest entry (API.jl:1358-1390) — never had an archive at
#      all, and was excluded from ajt's install job list entirely before this
#      unit. Cloned into `clones/<string(hash(url))>`, the name `Pkg.gc()`
#      recomputes (Types.jl:901); the gate asserts that directory exists by
#      recomputing the name with Pkg's own `hash`.
#
# And four properties on top:
#
#   3. THE INSTALLED TREE IS THE TREE THAT WAS PINNED — re-hashed on disk with
#      `Pkg.GitTools.tree_hash`, the function Pkg compares `git-tree-sha1`
#      against. This is the check Pkg's own git path does NOT make
#      (checkout_tree_to_path never re-verifies).
#   4. `ajt verify --frozen --check-hashes` exits 0 on the repo-url entry —
#      a repo-tracked entry still carries git-tree-sha1, so it takes verify's
#      tree-hash branch and re-derives it.
#   5. `ajt instantiate --dry-run` plans a job for the repo-url entry and does
#      not claim the environment converges, rather than reporting nothing to do
#      — then converges once it is installed.
#   6. A `repo-url` that is a manifest-relative PATH (what `Pkg.add(path = …)`
#      records, Types.jl:979) is resolved against the manifest and absolutised
#      before it is hashed into a clone directory name, run from a third cwd so
#      that taking it verbatim would clone the wrong thing. Oracle:
#      `hash(normpath(joinpath(dirname(manifest), path)))` in Julia.
#
# Landmark assertions: every step below asserts a non-vacuous count or an
# oracle-produced value first, so a julia that failed to start or a fixture that
# failed to build turns the gate RED rather than green-with-zero-cases.
#
# Usage: tools/diff_harness/install_git.sh [--offline] [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

OFFLINE=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
command -v git   >/dev/null || { echo "ERROR: git not on PATH (this gate is about git)" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-install-git-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) || { echo "ERROR: zig build failed" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# A deterministic identity for every fixture commit, and no signing: a
# developer with global commit.gpgsign would otherwise block on a passphrase.
git_fixture() { # git_fixture <dir> <args...>
  local d="$1"; shift
  env -i PATH="$PATH" HOME="$WORK" \
      GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
      GIT_AUTHOR_NAME=ajt GIT_AUTHOR_EMAIL=ajt@example.invalid \
      GIT_COMMITTER_NAME=ajt GIT_COMMITTER_EMAIL=ajt@example.invalid \
      GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000" \
      GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000" \
      git -C "$d" "$@"
}

# ---------------------------------------------------------------------------
echo
echo "==> 0. a package that exists ONLY as a git repository"

FIXTURE="$WORK/fixture"
FIX_UUID="90137ffa-7385-5640-81b9-e52037218182"
mkdir -p "$FIXTURE/src"
cat > "$FIXTURE/Project.toml" <<EOF
name = "AjtGitFixture"
uuid = "$FIX_UUID"
version = "1.0.0"
EOF
echo 'module AjtGitFixture' > "$FIXTURE/src/AjtGitFixture.jl"
echo 'greet() = "hello from git"' >> "$FIXTURE/src/AjtGitFixture.jl"
echo 'end' >> "$FIXTURE/src/AjtGitFixture.jl"
# A `.gitattributes` that rewrites line endings on checkout. Pkg's
# `checkout_tree_to_path` honours it and would produce a directory that does
# NOT hash to the tree it came from; the tree hash re-derived in step 3 is what
# proves ajt's materialise suppressed it (see src/git/cli.zig's header).
printf '*.txt text eol=crlf\n' > "$FIXTURE/.gitattributes"
printf 'one\ntwo\n' > "$FIXTURE/eol.txt"
git_fixture "$FIXTURE" init --quiet --initial-branch=main
git_fixture "$FIXTURE" add -A
git_fixture "$FIXTURE" commit --quiet -m "initial"

# The pin. `git rev-parse HEAD^{tree}` and Pkg's own `GitTools.tree_hash` must
# agree, or the fixture is not what either side thinks it is — and everything
# below is keyed on this number.
GIT_TREE="$(git_fixture "$FIXTURE" rev-parse 'HEAD^{tree}')"
PKG_TREE="$(julia --startup-file=no -e \
  'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$FIXTURE")"
if [ "${#GIT_TREE}" -ne 40 ]; then
  bad "the fixture repository produced no tree hash -- git failed?"
  echo; echo "install_git: 0 passed, 1 failed"; exit 1
fi
check "git and Pkg.GitTools.tree_hash agree on the fixture's tree" "$GIT_TREE" "$PKG_TREE"
FIX_URL="file://$FIXTURE"

# The depot slug the package MUST land at, from Pkg's own `version_slug`.
SLUG="$(julia --startup-file=no -e '
  using Pkg
  print(Base.version_slug(Base.UUID(ARGS[1]), Base.SHA1(ARGS[2])))' "$FIX_UUID" "$GIT_TREE")"
[ -n "$SLUG" ] || bad "Base.version_slug produced nothing"

# `project_hash` — `record_project_hash` (Operations.jl:1295-1297). Every
# manifest below needs one or `--frozen` refuses to proceed, and it is Pkg's
# own `workspace_resolve_hash` that produces it here rather than ajt's.
project_hash() { # project_hash <Project.toml>
  julia --startup-file=no -e '
    using Pkg
    print(Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(ARGS[1])))' "$1"
}

# ---------------------------------------------------------------------------
echo
echo "==> 1. a one-package registry whose repo yields NO archive URL"

# `find_urls` reads the registry's `repo` field, and that is the only way a
# tree-hash-tracked entry gets a URL at all. Two packages: the local fixture,
# and (for the network case) the real Example.jl spelled without `.git`.
EX_UUID="7876af07-990d-54b4-ab0e-23690620f79a"
EX_URL="https://github.com/JuliaLang/Example.jl"
EX_TREE="8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8" # Example v0.5.5
REG="$WORK/reg"
mkdir -p "$REG/A/AjtGitFixture" "$REG/E/Example"
cat > "$REG/Registry.toml" <<EOF
name = "AjtGate"
uuid = "11111111-2222-3333-4444-555555555555"
repo = "file://$WORK/nonexistent"

[packages]
$FIX_UUID = { name = "AjtGitFixture", path = "A/AjtGitFixture" }
$EX_UUID = { name = "Example", path = "E/Example" }
EOF
cat > "$REG/A/AjtGitFixture/Package.toml" <<EOF
name = "AjtGitFixture"
uuid = "$FIX_UUID"
repo = "$FIX_URL"
EOF
cat > "$REG/A/AjtGitFixture/Versions.toml" <<EOF
["1.0.0"]
git-tree-sha1 = "$GIT_TREE"
EOF
cat > "$REG/E/Example/Package.toml" <<EOF
name = "Example"
uuid = "$EX_UUID"
repo = "$EX_URL"
EOF
cat > "$REG/E/Example/Versions.toml" <<EOF
["0.5.5"]
git-tree-sha1 = "$EX_TREE"
EOF
mkdir -p "$WORK/regdepot/registries"
# Entries must be top-level (`Registry.toml`, `A/…`), the way General's own
# tarball is laid out — `-C "$REG" .` would prefix every name with `./` and the
# reader would find no `Registry.toml` at all.
tar -czf "$WORK/regdepot/registries/AjtGate.tar.gz" -C "$REG" Registry.toml A E
check "the fixture registry loads" "2" \
  "$("$AJT" registry status --depot "$WORK/regdepot" --registry AjtGate --source archive 2>/dev/null \
     | awk '$1=="packages" {print $2}')"

# THE assertion that makes this gate about the git path at all: Pkg's own
# `get_archive_url_for_version` must answer `nothing` for both repo fields.
# If it ever answered a URL, everything below would be gating the archive path.
NO_ARCHIVE="$(julia --startup-file=no -e '
  using Pkg
  print(count(u -> Pkg.Operations.get_archive_url_for_version(u, ARGS[1]) === nothing,
              ARGS[2:end]))' "$GIT_TREE" "$FIX_URL" "$EX_URL")"
check "Pkg.get_archive_url_for_version refuses both repo URLs" "2" "$NO_ARCHIVE"

# ---------------------------------------------------------------------------
echo
echo "==> 2. seam 1: install_git, keyed by uuid"

mkdir -p "$WORK/env1"
cat > "$WORK/env1/Project.toml" <<EOF
[deps]
AjtGitFixture = "$FIX_UUID"
EOF
PH1="$(project_hash "$WORK/env1/Project.toml")"
[ "${#PH1}" -eq 40 ] || bad "workspace_resolve_hash produced nothing for env1"
cat > "$WORK/env1/Manifest.toml" <<EOF
julia_version = "$(julia --startup-file=no -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "$PH1"

[[deps.AjtGitFixture]]
git-tree-sha1 = "$GIT_TREE"
uuid = "$FIX_UUID"
version = "1.0.0"
EOF

# `--server ''` drops candidate 1; the registry `repo` yields no candidate 2.
# So the candidate list is EMPTY and the only way this can succeed is a clone.
"$AJT" install --server "" --source archive \
    --depot "$WORK/depot1" --registry-depot "$WORK/regdepot" --registry AjtGate \
    --no-fixups "$WORK/env1/Manifest.toml" > "$WORK/i1.records" 2> "$WORK/i1.err"
RC1=$?
check "install exited cleanly" "0" "$RC1"
[ "$RC1" -eq 0 ] || sed 's/^/       /' "$WORK/i1.err" | head -10
check "the package reports installed_git" "installed_git" \
  "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/i1.records")"

# The dry run proves the archive list really was empty: columns 4+ are the
# candidate URLs, and there must be none.
"$AJT" install --dry-run --server "" --source archive \
    --depot "$WORK/depot1b" --registry-depot "$WORK/regdepot" --registry AjtGate \
    "$WORK/env1/Manifest.toml" > "$WORK/i1.dry" 2>/dev/null
check "no archive candidate was built for it" "3" \
  "$(awk -F'\t' '$1=="dry-run" {print NF}' "$WORK/i1.dry")"

check "it landed at Base.version_slug's directory" \
  "$WORK/depot1/packages/AjtGitFixture/$SLUG" \
  "$(awk -F'\t' '$1=="install" {print $6}' "$WORK/i1.records")"

# `install_git`'s clone cache is `clones/<uuid>` (Operations.jl:842-844).
if [ -d "$WORK/depot1/clones/$FIX_UUID" ]; then
  ok "the clone cache is clones/<uuid>, as install_git names it"
else
  bad "no clones/<uuid> directory" "$(ls "$WORK/depot1/clones" 2>/dev/null | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 3. the installed tree is the tree git-tree-sha1 pinned"

GOT="$(julia --startup-file=no -e \
  'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' \
  "$WORK/depot1/packages/AjtGitFixture/$SLUG")"
check "GitTools.tree_hash of the installed tree" "$GIT_TREE" "$GOT"
# The `eol=crlf` attribute is the specific way a checkout silently produces a
# different tree; assert the bytes directly so a failure names the cause.
if [ -f "$WORK/depot1/packages/AjtGitFixture/$SLUG/eol.txt" ]; then
  check "eol=crlf was suppressed (raw blob bytes on disk)" "0" \
    "$(grep -c $'\r' "$WORK/depot1/packages/AjtGitFixture/$SLUG/eol.txt" || true)"
else
  bad "the fixture's eol.txt is not in the installed tree"
fi
# Pkg's set_readonly, the same rule the archive path gets (Operations.jl:1235).
check "no installed file is writable" "0" \
  "$(find "$WORK/depot1/packages" -type f -perm -u+w | wc -l)"
check "no staging directory survived" "0" \
  "$(find "$WORK/depot1" -name '.ajt-tmp-*' | wc -l)"

# The strong gate: stock julia loads it, Pkg never entering the process.
OUT="$(JULIA_DEPOT_PATH="$WORK/depot1" JULIA_LOAD_PATH="$WORK/env1:@stdlib" \
  julia --startup-file=no -e '
    using AjtGitFixture
    print(AjtGitFixture.greet())' 2>"$WORK/using1.err")"
check "stock julia loads the cloned package" "hello from git" "$OUT"

# Idempotence: nothing is re-cloned, and the record says so.
"$AJT" install --server "" --source archive \
    --depot "$WORK/depot1" --registry-depot "$WORK/regdepot" --registry AjtGate \
    --no-fixups "$WORK/env1/Manifest.toml" > "$WORK/i1b.records" 2>/dev/null
check "a second install is a no-op" "already_present" \
  "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/i1b.records")"

# ...and with no backend, the pre-existing contract still holds.
"$AJT" install --server "" --source archive --no-git \
    --depot "$WORK/depot1c" --registry-depot "$WORK/regdepot" --registry AjtGate \
    --no-fixups "$WORK/env1/Manifest.toml" > "$WORK/i1c.records" 2>/dev/null
RC1C=$?
check "--no-git fails the install" "1" "$([ "$RC1C" -ne 0 ] && echo 1 || echo 0)"
check "and reports needs_git_clone" "needs_git_clone" \
  "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/i1c.records")"
check "having written no package" "0" \
  "$(find "$WORK/depot1c/packages" -mindepth 1 -type f 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
echo
echo "==> 4. seam 2: a repo-url manifest entry, keyed by hash(url)"

mkdir -p "$WORK/env2"
cat > "$WORK/env2/Project.toml" <<EOF
[deps]
AjtGitFixture = "$FIX_UUID"
EOF
cat > "$WORK/env2/Manifest.toml" <<EOF
julia_version = "$(julia --startup-file=no -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "$(project_hash "$WORK/env2/Project.toml")"

[[deps.AjtGitFixture]]
git-tree-sha1 = "$GIT_TREE"
repo-rev = "main"
repo-url = "$FIX_URL"
uuid = "$FIX_UUID"
version = "1.0.0"
EOF

# Pkg refuses to read a manifest it would not have written, so parse it with
# Pkg first: a repo-url entry has to come back as `pkg.repo.source`, or the
# file below is not the shape this seam is about.
REPO_SRC="$(julia --startup-file=no -e '
  using Pkg
  m = Pkg.Types.read_manifest(ARGS[1])
  e = first(values(m))
  print(e.repo.source === nothing ? "NONE" : e.repo.source)' "$WORK/env2/Manifest.toml")"
check "Pkg reads the entry as repo-tracked" "$FIX_URL" "$REPO_SRC"

# BEFORE: instantiate must PLAN work for the entry and must not claim the
# environment converges. Both were false before this unit: `jobsFromManifest`
# dropped every `repo-url` entry, so the plan was empty and the only sign of
# trouble was verify's own complaint. The registry is deliberately absent — a
# repo entry needs none, and Pkg's `check_registered` filters repo-tracked
# entries out before asking one anything (Operations.jl:1637).
"$AJT" instantiate --frozen --dry-run --server "" --no-artifacts \
    --registry-policy never --depot "$WORK/depot2" \
    "$WORK/env2" > "$WORK/inst.before" 2>"$WORK/inst.before.err"
check "instantiate plans a job for the repo-url entry" "1" \
  "$(awk -F'\t' '$1=="plan-package" && $2=="AjtGitFixture"' "$WORK/inst.before" | wc -l)"
check "with no archive candidate at all" "3" \
  "$(awk -F'\t' '$1=="plan-package" {print NF}' "$WORK/inst.before")"
check "and the plan is one package" "1" \
  "$(awk -F'\t' '$1=="summary" {print $4}' "$WORK/inst.before")"
check "and it does not claim the environment is complete" "failed" \
  "$(awk -F'\t' '$1=="verify" {print $2}' "$WORK/inst.before")"
# `package_missing`, rendered: "<name> v<version>: not installed — <path>".
if grep -q 'AjtGitFixture v1.0.0: not installed' "$WORK/inst.before.err"; then
  ok "the entry is named as not installed, not as some other kind of problem"
else
  bad "instantiate did not report the entry as missing" \
      "$(head -6 "$WORK/inst.before.err" | tr '\n' '|')"
fi

"$AJT" instantiate --frozen --server "" --no-artifacts --no-fixups \
    --registry-policy never --depot "$WORK/depot2" \
    "$WORK/env2" > "$WORK/inst.after" 2>"$WORK/inst.after.err"
RC2=$?
check "instantiate exited cleanly" "0" "$RC2"
[ "$RC2" -eq 0 ] || sed 's/^/       /' "$WORK/inst.after.err" | head -10
check "the entry reports installed_git" "1" \
  "$(grep -c 'installed_git' "$WORK/inst.after" || true)"

# `add_repo_cache_path(url)` = `clones/<string(hash(url))>` (Types.jl:901).
# Recomputed by Pkg, not by ajt: this is the name `Pkg.gc()` looks for, and a
# clone under any other name is deleted the next time anybody runs it.
CLONE_NAME="$(julia --startup-file=no -e 'print(string(hash(ARGS[1])))' "$FIX_URL")"
# An empty name would make the test `[ -d "…/clones/" ]`, which the clone pass
# just made true — the one check here whose oracle failing would go GREEN.
if [ -z "$CLONE_NAME" ]; then
  bad "the hash(url) oracle produced nothing -- julia failed to run?"
elif [ -d "$WORK/depot2/clones/$CLONE_NAME" ]; then
  ok "the clone cache is clones/$CLONE_NAME, the name Pkg.gc() recomputes"
else
  bad "no clones/<hash(url)> directory" \
      "wanted $CLONE_NAME, have: $(ls "$WORK/depot2/clones" 2>/dev/null | tr '\n' ' ')"
fi

check "the tree hash of the repo-url install" "$GIT_TREE" \
  "$(julia --startup-file=no -e \
     'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' \
     "$WORK/depot2/packages/AjtGitFixture/$SLUG")"

# AFTER: the same probe must now converge.
"$AJT" instantiate --frozen --dry-run --server "" --no-artifacts \
    --registry-policy never --depot "$WORK/depot2" \
    "$WORK/env2" > "$WORK/inst.again" 2>"$WORK/inst.again.err"
check "and the environment converges once it is installed" "ok" \
  "$(awk -F'\t' '$1=="verify" {print $2}' "$WORK/inst.again")"

# ---------------------------------------------------------------------------
echo
echo "==> 5. a repo-url that is a local PATH, resolved against the manifest"

# `Pkg.add(path = …)` records a MANIFEST-RELATIVE path when the user gave a
# relative one (Types.jl:979), and `instantiate` rewrites it with
# `manifest_rel_path` before hashing it into a clone directory name
# (API.jl:1362-1376). Run from a cwd that is neither, so a path taken verbatim
# would clone the wrong thing and key the cache under a name Pkg.gc() would
# delete.
mkdir -p "$WORK/env4"
cat > "$WORK/env4/Project.toml" <<EOF
[deps]
AjtGitFixture = "$FIX_UUID"
EOF
cat > "$WORK/env4/Manifest.toml" <<EOF
julia_version = "$(julia --startup-file=no -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "$(project_hash "$WORK/env4/Project.toml")"

[[deps.AjtGitFixture]]
git-tree-sha1 = "$GIT_TREE"
repo-url = "../fixture"
uuid = "$FIX_UUID"
version = "1.0.0"
EOF

# cwd = $WORK, manifest given RELATIVE: `dirname` is `env4`, so the path only
# resolves correctly if both the manifest-relative join and the abspath happen.
( cd "$WORK" && "$AJT" install --server "" --no-fixups \
    --depot "$WORK/depot4" env4/Manifest.toml ) > "$WORK/i4.records" 2> "$WORK/i4.err"
RC4=$?
check "a manifest-relative repo-url installs" "0" "$RC4"
[ "$RC4" -eq 0 ] || sed 's/^/       /' "$WORK/i4.err" | head -6
check "and reports installed_git" "installed_git" \
  "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/i4.records")"

# The name Pkg computes for it: hash of the ABSOLUTE, normalised path.
REL_CLONE="$(julia --startup-file=no -e '
  print(string(hash(normpath(joinpath(ARGS[1], ARGS[2])))))' "$WORK/env4" "../fixture")"
if [ -z "$REL_CLONE" ]; then
  bad "the hash(abspath) oracle produced nothing"
elif [ -d "$WORK/depot4/clones/$REL_CLONE" ]; then
  ok "the clone is keyed on the resolved absolute path, as Pkg keys it"
else
  bad "the relative repo-url was not resolved before hashing" \
      "wanted $REL_CLONE, have: $(ls "$WORK/depot4/clones" 2>/dev/null | tr '\n' ' ')"
fi
check "and the tree is the one that was pinned" "$GIT_TREE" \
  "$(julia --startup-file=no -e \
     'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' \
     "$WORK/depot4/packages/AjtGitFixture/$SLUG" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo
echo "==> 6. verify --frozen --check-hashes accepts the repo-url entry"

# A repo-tracked entry still carries git-tree-sha1, so verify takes its
# tree-hash branch and re-derives the hash from disk; nothing about verify
# needed changing for this unit, and this is what says so.
"$AJT" verify --frozen --check-hashes --depot "$WORK/depot2" \
    "$WORK/env2" > "$WORK/verify.out" 2> "$WORK/verify.err"
VRC=$?
check "verify exited 0" "0" "$VRC"
[ "$VRC" -eq 0 ] || sed 's/^/       /' "$WORK/verify.err" | head -10
# Non-vacuous: it must actually have re-hashed the entry, not skipped it.
# Without `--check-hashes` the same line reads `0 re-hashed`, and this check
# would then pass for a verify that only stat'd the directory.
if grep -qE '[1-9][0-9]* re-hashed' "$WORK/verify.out"; then
  ok "and re-derived the tree hash of the installed entry"
else
  bad "verify reported no re-hashed entry" "$(head -8 "$WORK/verify.out" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
if [ $OFFLINE -eq 0 ]; then
  if ! "$AJT" fetch --status https://github.com >/dev/null 2>&1; then
    echo
    echo "######################################################################"
    echo "# SKIPPED the network case: github.com unreachable. Everything above  #"
    echo "# ran; the real-remote clone did NOT.                                 #"
    echo "######################################################################"
    OFFLINE=1
  fi
fi

if [ $OFFLINE -eq 0 ]; then
  echo
  echo "==> 7. the network case: a real repository, no archive URL"

  # Example.jl at v0.5.5, whose registry `repo` here is spelled WITHOUT `.git`
  # — so `get_archive_url_for_version` yields nothing (asserted in step 1) and
  # the Pkg server is off. The only way this can succeed is a real clone of
  # https://github.com/JuliaLang/Example.jl.
  EX_SLUG="$(julia --startup-file=no -e '
    print(Base.version_slug(Base.UUID(ARGS[1]), Base.SHA1(ARGS[2])))' "$EX_UUID" "$EX_TREE")"
  mkdir -p "$WORK/env3"
  cat > "$WORK/env3/Project.toml" <<EOF
[deps]
Example = "$EX_UUID"
EOF
  cat > "$WORK/env3/Manifest.toml" <<EOF
julia_version = "$(julia --startup-file=no -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "$(project_hash "$WORK/env3/Project.toml")"

[[deps.Example]]
git-tree-sha1 = "$EX_TREE"
uuid = "$EX_UUID"
version = "0.5.5"
EOF

  "$AJT" install --server "" --source archive \
      --depot "$WORK/depot3" --registry-depot "$WORK/regdepot" --registry AjtGate \
      --no-fixups "$WORK/env3/Manifest.toml" > "$WORK/i3.records" 2> "$WORK/i3.err"
  RC3=$?
  check "Example installs from a real clone" "0" "$RC3"
  [ "$RC3" -eq 0 ] || sed 's/^/       /' "$WORK/i3.err" | head -10
  check "and reports installed_git" "installed_git" \
    "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/i3.records")"
  check "at the tree hash the manifest pinned" "$EX_TREE" \
    "$(julia --startup-file=no -e \
       'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' \
       "$WORK/depot3/packages/Example/$EX_SLUG" 2>/dev/null)"
  OUT3="$(JULIA_DEPOT_PATH="$WORK/depot3" JULIA_LOAD_PATH="$WORK/env3:@stdlib" \
    julia --startup-file=no -e 'using Example; print(Example.hello("git"))' 2>"$WORK/using3.err")"
  check "stock julia loads it" "Hello, git" "$OUT3"
fi

# ---------------------------------------------------------------------------
echo
echo "======================================================================"
printf 'install_git: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ $OFFLINE -eq 1 ]; then
  echo "(the network case was skipped -- run with network for the full set)"
fi
[ $FAIL -eq 0 ] || exit 1
exit 0
