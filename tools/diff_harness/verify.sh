#!/usr/bin/env bash
# Differential gate for `ajt verify --frozen`.
#
# The claim under test is narrow and load-bearing: `ajt verify` answers the same
# question `julia -e 'using Pkg; Pkg.instantiate()'` answers on a warm
# environment -- the call `backend/docker-entrypoint.sh:29-30` makes on every
# container start -- in under 100 ms, and without writing anything.
#
# Four sections:
#
#   1. THE REAL ENVIRONMENT. Against `Open-Reality/` and the user's real
#      `~/.julia`, `ajt verify --frozen` must exit 0, must have actually checked
#      every class of entry (a verdict that skipped 43 stdlib entries is not a
#      verdict), and must agree with Julia's own predicates
#      (`Operations.is_instantiated`, `Operations.is_manifest_current`) with a
#      real `Pkg.instantiate()` doing no work as the end-to-end oracle.
#   2. LATENCY. Wall time of the whole process, median of N, asserted under
#      100 ms, against the julia call it replaces measured the same way.
#   3. CASES. Seven hermetic environments in temp depots, each covering one
#      decision the module makes, with julia's verdict computed for every one of
#      them and ajt's exit status required to match. Two of them (`complete`'s
#      unreachable entry, `no_transitive`) pin the loadable closure from BOTH
#      sides -- over-pruning and under-pruning each break exactly one.
#      Every ajt run is bracketed by a full snapshot (path, mtime, size, type)
#      of the whole case directory -- depot AND environment -- so a `--frozen`
#      run that wrote anything, including to `Manifest.toml`, fails.
#   4. --check-hashes. The opt-in deep mode must catch a mutated install that
#      the default existence check accepts, and its hash must be
#      `Pkg.GitTools.tree_hash`'s.
#
# NOTHING here writes into the user's real depot: section 1 only reads it, and
# every julia process is pointed at a scratch depot FIRST in JULIA_DEPOT_PATH.
# That is not paranoia -- merely constructing Julia's `EnvCache` writes
# `logs/manifest_usage.toml` into depots1 (`Types.jl:426`), which is the
# asymmetry this gate exists to demonstrate: Julia's cheapest question is a
# write, ajt's is not.
#
# Usage: verify.sh [--runs N]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
ENGINE="$REPO_ROOT/Open-Reality"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

RUNS=7
[ "${1:-}" = "--runs" ] && RUNS="${2:-7}"

WORK="$(mktemp -d -t ajt-verify-XXXXXX)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok()   { echo "  ok   $*"; }
expect_eq() { # got want label
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3
    want: $2
    got : $1"; fi
}

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# Scratch depot for every julia invocation's own writes.
JDEPOT="$WORK/jdepot"
mkdir -p "$JDEPOT"
# The depot ajt will actually read in section 1 -- `Base.DEPOT_PATH[1]` under
# the AMBIENT environment, so a relocated JULIA_DEPOT_PATH is honoured and both
# sides look at the same place. (No EnvCache here, so nothing is written.)
REAL_DEPOT="$(julia -e 'print(first(Base.DEPOT_PATH))')"
[ -n "$REAL_DEPOT" ] || { echo "ERROR: could not determine the depot" >&2; exit 2; }
# Every julia invocation goes through this: it READS the real depot but WRITES
# to the scratch one, because `EnvCache` writes `logs/manifest_usage.toml` into
# depots1 just by being constructed (`Types.jl:426`).
jl() { JULIA_DEPOT_PATH="$JDEPOT:$REAL_DEPOT" julia "$@"; }

# A directory's complete state: every path, its mtime to the nanosecond, its
# size and its type. This is what "wrote nothing" has to survive.
snapshot() { find "$1" -printf '%p\t%T@\t%s\t%y\n' 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
# 1. The real Open-Reality environment
# ---------------------------------------------------------------------------
echo "==> 1. the real environment: $ENGINE"

[ -f "$ENGINE/Manifest.toml" ] || { echo "ERROR: no $ENGINE/Manifest.toml" >&2; exit 2; }

# Top-level only: a full snapshot of ~/.julia is hundreds of thousands of files.
# Every write Pkg makes to a depot lands in one of its top-level directories
# (logs/, packages/, compiled/, artifacts/), so their mtimes are the tripwire.
find "$REAL_DEPOT" -maxdepth 1 -printf '%p\t%T@\n' 2>/dev/null | sort > "$WORK/real.before"
"$AJT" verify --frozen "$ENGINE" > "$WORK/real.out" 2>&1
AJT_REAL=$?
find "$REAL_DEPOT" -maxdepth 1 -printf '%p\t%T@\n' 2>/dev/null | sort > "$WORK/real.after"

sed 's/^/    /' "$WORK/real.out"
expect_eq "$AJT_REAL" "0" "ajt verify --frozen exits 0 on the real environment"

if diff -q "$WORK/real.before" "$WORK/real.after" >/dev/null; then
  ok "the real depot's top level is untouched (no writes into $REAL_DEPOT)"
else
  fail "ajt verify modified the real depot:
$(diff "$WORK/real.before" "$WORK/real.after")"
fi

# Exit 0 is not enough: a verdict reached by skipping a class of entry is a
# false pass, and the manifest's 44 tree-hash-less entries are the class most
# easily skipped. Require the counts to add up to every entry in the file.
read -r R_ENTRIES R_INST R_DEV R_STD R_PRUNED <<EOF
$(sed -n 's/^ *\([0-9]*\) entries: \([0-9]*\) installed, \([0-9]*\) developed, \([0-9]*\) stdlib, \([0-9]*\) pruned.*/\1 \2 \3 \4 \5/p' "$WORK/real.out")
EOF
M_ENTRIES="$(jl -e '
using Pkg
println(length(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml")).manifest))' "$ENGINE")"
expect_eq "${R_ENTRIES:-0}" "$M_ENTRIES" "every entry Pkg reads is accounted for in the report"
if [ "$(( ${R_INST:-0} + ${R_DEV:-0} + ${R_STD:-0} + ${R_PRUNED:-0} ))" = "${R_ENTRIES:-0}" ]; then
  ok "the per-class counts sum to the total (${R_INST}+${R_DEV}+${R_STD}+${R_PRUNED})"
else
  fail "counts do not sum to $R_ENTRIES: $R_INST installed + $R_DEV developed + $R_STD stdlib + $R_PRUNED pruned"
fi
[ "${R_STD:-0}" -gt 0 ] \
  && ok "the stdlib cross-check actually ran ($R_STD entries)" \
  || fail "no entry was checked as a stdlib — the check silently did not run"

# Julia's own predicates, in one process.
read -r J_INST J_CURRENT <<EOF
$(jl -e '
using Pkg
env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
print(Pkg.Operations.is_instantiated(env), " ", Pkg.Operations.is_manifest_current(env))' \
  "$ENGINE" 2>"$WORK/oracle.err")
EOF
[ -n "$J_INST" ] || { echo "ERROR: julia oracle failed" >&2; tail -5 "$WORK/oracle.err" >&2; exit 2; }
expect_eq "$J_INST" "true" "Pkg.Operations.is_instantiated agrees the environment is complete"
expect_eq "$J_CURRENT" "true" "Pkg.Operations.is_manifest_current agrees the manifest matches the project"

# The end-to-end oracle: the exact command the entrypoint runs, doing no work.
# Any install/download/update verb in its output means it DID work, and then
# "already instantiated" was the wrong answer.
jl --project="$ENGINE" -e 'using Pkg; Pkg.instantiate()' >"$WORK/inst.out" 2>&1
expect_eq "$?" "0" "Pkg.instantiate() itself succeeds"
if grep -Eq '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/inst.out"; then
  fail "Pkg.instantiate() did work, so the environment was NOT already instantiated:
$(grep -E '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/inst.out" | head -5)"
else
  ok "Pkg.instantiate() installed/downloaded nothing — 'already instantiated' is the truth"
fi

# ---------------------------------------------------------------------------
# 2. Latency
# ---------------------------------------------------------------------------
echo "==> 2. latency (target: < 100 ms wall, including process start)"

TIMES=()
for _ in $(seq "$RUNS"); do
  T0=$(date +%s%N)
  "$AJT" verify --frozen --quiet "$ENGINE"
  T1=$(date +%s%N)
  TIMES+=( $(( (T1 - T0) / 1000000 )) )
done
readarray -t SORTED < <(printf '%s\n' "${TIMES[@]}" | sort -n)
MEDIAN="${SORTED[$(( ${#SORTED[@]} / 2 ))]}"
echo "  wall ms over $RUNS runs: best=${SORTED[0]} median=$MEDIAN worst=${SORTED[-1]}  (all: ${TIMES[*]})"

if [ "$MEDIAN" -lt 100 ]; then
  ok "median wall time ${MEDIAN} ms < 100 ms"
else
  fail "median wall time ${MEDIAN} ms is over the 100 ms budget"
fi

# For scale: the call this replaces, on the same warm environment.
T0=$(date +%s%N)
jl --project="$ENGINE" -e 'using Pkg; Pkg.instantiate()' >/dev/null 2>&1
T1=$(date +%s%N)
PKG_MS=$(( (T1 - T0) / 1000000 ))
echo "  for scale: julia -e 'using Pkg; Pkg.instantiate()' = ${PKG_MS} ms on the same environment"

# ---------------------------------------------------------------------------
# 3. Cases
# ---------------------------------------------------------------------------
echo "==> 3. cases"

FOO_UUID="a1b2c3d4-0000-1111-2222-333344445555"
BAR_UUID="b2c3d4e5-0000-1111-2222-333344445555"
GHOST_UUID="c3d4e5f6-0000-1111-2222-333344445555"
PHANTOM_UUID="d4e5f6a7-0000-1111-2222-333344445555"
PROJ_UUID="99999999-8888-7777-6666-555555555555"
# A REAL stdlib, so the tree-hash-less branch resolves the way it does in
# production: by uuid, against the running Julia's stdlib directory.
LINALG_UUID="37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

# One package source, three identities. Its REAL tree hash is what the manifests
# pin, so these are genuine installs rather than plausible-looking ones -- and
# section 4 can hash them for real.
SRC="$WORK/src/Pkgsrc"
mkdir -p "$SRC/src"
printf 'module Pkgsrc\ngreet() = "hi"\nend\n' > "$SRC/src/Pkgsrc.jl"
printf 'name = "Pkgsrc"\nversion = "1.2.3"\n' > "$SRC/Project.toml"

read -r TREE SLUG_FOO SLUG_BAR SLUG_GHOST JV <<EOF
$(jl -e '
using Pkg
tree = bytes2hex(Pkg.GitTools.tree_hash(ARGS[1]))
slug(u) = Base.version_slug(Base.UUID(u), Base.SHA1(tree))
print(tree, " ", slug(ARGS[2]), " ", slug(ARGS[3]), " ", slug(ARGS[4]), " ", VERSION)' \
  "$SRC" "$FOO_UUID" "$BAR_UUID" "$GHOST_UUID")
EOF
[ -n "$TREE" ] && [ -n "$SLUG_FOO" ] || { echo "ERROR: could not derive tree hash / slugs" >&2; exit 2; }
echo "  fixture: tree=$TREE  Foo=$SLUG_FOO Bar=$SLUG_BAR Ghost=$SLUG_GHOST  julia=$JV"

# A BYTE-IDENTICAL copy of $SRC, so the installed tree really does hash to
# $TREE and section 4 is a hash check rather than a formality. Nothing loads
# these packages -- neither `is_instantiated` nor `verify` reads inside a
# package directory -- so all three identities sharing one content tree costs
# nothing and buys a fixture whose git-tree-sha1 is genuine.
install_pkg() { # depot name slug
  mkdir -p "$1/packages/$2/$3"
  cp -r "$SRC/." "$1/packages/$2/$3/"
}

# The baseline every case starts from:
#   project deps: Foo, LinearAlgebra          (LinearAlgebra has no tree hash)
#   manifest:     Foo -> Bar, Bar, Ghost (unreachable), LinearAlgebra (stdlib)
#   depot:        Foo, Bar        -- Ghost is deliberately NOT installed
make_case() { # name
  local d="$WORK/$1"
  mkdir -p "$d/env" "$d/depot"
  install_pkg "$d/depot" Foo "$SLUG_FOO"
  install_pkg "$d/depot" Bar "$SLUG_BAR"
  cat > "$d/env/Project.toml" <<EOF
name = "Fixture"
uuid = "$PROJ_UUID"
version = "0.1.0"

[deps]
Foo = "$FOO_UUID"
LinearAlgebra = "$LINALG_UUID"
EOF
  cat > "$d/env/Manifest.toml" <<EOF
julia_version = "$JV"
manifest_format = "2.0"
project_hash = "0000000000000000000000000000000000000000"

[[deps.Foo]]
deps = ["Bar"]
git-tree-sha1 = "$TREE"
uuid = "$FOO_UUID"
version = "1.2.3"

[[deps.Bar]]
git-tree-sha1 = "$TREE"
uuid = "$BAR_UUID"
version = "1.2.3"

[[deps.Ghost]]
git-tree-sha1 = "$TREE"
uuid = "$GHOST_UUID"
version = "1.2.3"

[[deps.LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
}

CASES=(complete no_package no_slug no_transitive stale_project fake_stdlib no_hash)
for c in "${CASES[@]}"; do make_case "$c"; done

# complete:      untouched. Ghost is pinned, unreachable and NOT installed --
#                julia must still say instantiated, and so must ajt. This is the
#                real Open-Reality shape (9 uninstalled Vulkan-family entries)
#                and it fails the moment the closure is dropped.
# no_package:    Foo's package directory is gone entirely.
rm -rf "$WORK/no_package/depot/packages/Foo"
# no_slug:       Foo's directory survives with a DECOY sibling slug -- a stale
#                version of the same package. Anything that checks for
#                `packages/Foo/` rather than the exact slug passes this.
rm -rf "$WORK/no_slug/depot/packages/Foo/$SLUG_FOO"
mkdir -p "$WORK/no_slug/depot/packages/Foo/AAAAA/src"
printf 'module Foo end\n' > "$WORK/no_slug/depot/packages/Foo/AAAAA/src/Foo.jl"
# no_transitive: Bar -- a dep OF a dep, never named by the project -- is not
#                installed. Over-pruning the closure would call this clean.
rm -rf "$WORK/no_transitive/depot/packages/Bar"
# stale_project: a dependency added after the manifest was resolved.
printf 'Baz = "11111111-2222-3333-4444-555555555555"\n' >> "$WORK/stale_project/env/Project.toml"
# fake_stdlib:   a direct dep whose entry has no git-tree-sha1 and no path, and
#                whose uuid is NOT a stdlib -- `source_path` returns nothing.
printf 'Phantom = "%s"\n' "$PHANTOM_UUID" >> "$WORK/fake_stdlib/env/Project.toml"
cat >> "$WORK/fake_stdlib/env/Manifest.toml" <<EOF

[[deps.Phantom]]
uuid = "$PHANTOM_UUID"
EOF
# no_hash:       a manifest with no project_hash at all. Julia's
#                is_manifest_current returns `nothing` ("cannot tell") and
#                instantiate carries on; ajt refuses, which is the one place it
#                is deliberately stricter.
sed -i '/^project_hash = /d' "$WORK/no_hash/env/Manifest.toml"

# Fill in each project_hash from JULIA -- the value under test is never computed
# by the tool being tested. One process for all of them.
jl -e '
using Pkg
for case in ARGS[2:end]
    f = joinpath(ARGS[1], case, "env", "Project.toml")
    println(case, " ", Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(f)))
end' "$WORK" "${CASES[@]}" > "$WORK/hashes.txt" 2>"$WORK/hashes.err" || {
  echo "ERROR: project_hash oracle failed" >&2; tail -10 "$WORK/hashes.err" >&2; exit 2; }
# NB the placeholder has to be a well-formed SHA-1: Julia parses project_hash
# eagerly on read (`SHA1(raw["project_hash"])`, `manifest.jl:187`), so a literal
# "PLACEHOLDER" makes the oracle throw before it can compute anything.
while read -r case hash; do
  sed -i "s/^project_hash = .*/project_hash = \"$hash\"/" "$WORK/$case/env/Manifest.toml"
done < "$WORK/hashes.txt"
# stale_project's hash was computed from the EDITED project, which would make it
# current again -- put the pre-edit hash back.
BASE_HASH="$(awk '$1 == "complete" { print $2 }' "$WORK/hashes.txt")"
sed -i "s/^project_hash = .*/project_hash = \"$BASE_HASH\"/" "$WORK/stale_project/env/Manifest.toml"

# Julia's verdict for every case, in ONE process: `init_depot_path()` rebuilds
# DEPOT_PATH from ENV on each call, so the depot can be swapped per case. The
# scratch depot stays FIRST, so EnvCache's manifest_usage.toml write lands there
# and not in the depot under test -- which is what lets the snapshots below mean
# something.
jl -e '
using Pkg
scratch = first(split(ENV["JULIA_DEPOT_PATH"], ":"))
for case in ARGS[2:end]
    d = joinpath(ARGS[1], case)
    ENV["JULIA_DEPOT_PATH"] = string(scratch, ":", joinpath(d, "depot"))
    Base.init_depot_path()
    env = Pkg.Types.EnvCache(joinpath(d, "env", "Project.toml"))
    println(case, " ", Pkg.Operations.is_instantiated(env), " ",
            Pkg.Operations.is_manifest_current(env))
end' "$WORK" "${CASES[@]}" > "$WORK/julia_cases.txt" 2>"$WORK/julia_cases.err" || {
  echo "ERROR: per-case oracle failed" >&2; tail -10 "$WORK/julia_cases.err" >&2; exit 2; }
sed 's/^/    julia: /' "$WORK/julia_cases.txt"

# What each case must SAY, not merely that it failed. `complete` says nothing
# because it must not fail at all.
declare -A CAUSE=(
  [no_package]="not installed"
  [no_slug]="not installed"
  [no_transitive]="not installed"
  [stale_project]="changed since the manifest was resolved"
  [fake_stdlib]="manifest entry has no source"
  [no_hash]="records no project_hash"
)
# `nothing` from is_manifest_current means "cannot tell", and ajt treats that as
# a no. Everything else must match julia exactly.
declare -A STRICTER=( [no_hash]=1 )

# Julia's predicates only say yes or no. ajt's exit status also says WHICH slow
# path fixes it -- 0 ready, 1 instantiate, 2 resolve, 3 broken beyond any Pkg
# verb (`Kind.remedy`, and `ajt help`). Both halves are asserted below: the
# BOOLEAN must agree with julia, and the CODE must name the right remedy, which
# is the half julia has no opinion about. A single expected `1` for every kind
# of "no" is what the Julia wrapper had to scrape the report text to work
# around, and is exactly what these codes exist to replace.
declare -A WANT_RC=(
  [complete]=0
  [no_package]=1
  [no_slug]=1
  [no_transitive]=1
  [fake_stdlib]=1
  [stale_project]=2
  [no_hash]=2
)

while read -r case j_inst j_current; do
  d="$WORK/$case"
  snapshot "$d" > "$WORK/out/$case.before"
  JULIA_DEPOT_PATH="$d/depot" "$AJT" verify --frozen "$d/env" > "$WORK/out/$case.txt" 2>&1
  rc=$?
  snapshot "$d" > "$WORK/out/$case.after"

  if diff -q "$WORK/out/$case.before" "$WORK/out/$case.after" >/dev/null; then
    ok "$case: --frozen wrote nothing anywhere under the case (depot AND environment)"
  else
    fail "$case: something changed under a --frozen run:
$(diff "$WORK/out/$case.before" "$WORK/out/$case.after")"
  fi

  # `is_manifest_current` returns a TRI-STATE, so this is `!= false` rather
  # than `== true`: `nothing` is "no hash recorded", which Pkg's own callers
  # (`API.jl:1321`) treat as "carry on". `no_hash` is where ajt is deliberately
  # stricter -- see the module header.
  if [ "$j_inst" = "true" ] && [ "$j_current" != "false" ] && [ -z "${STRICTER[$case]:-}" ]; then
    want_ok=0
  else
    want_ok=1
  fi
  if [ "$rc" -eq 0 ]; then got_ok=0; else got_ok=1; fi
  expect_eq "$got_ok" "$want_ok" "$case: instantiated-or-not agrees with julia (is_instantiated=$j_inst, is_manifest_current=$j_current)${STRICTER[$case]:+ [deliberately stricter]}"
  expect_eq "$rc" "${WANT_RC[$case]}" "$case: exit $rc names the remedy (0 ready, 1 instantiate, 2 resolve, 3 broken)"

  if [ -n "${CAUSE[$case]:-}" ]; then
    if grep -q "${CAUSE[$case]}" "$WORK/out/$case.txt"; then
      ok "$case: message names the cause — '${CAUSE[$case]}'"
    else
      fail "$case: message does not name '${CAUSE[$case]}':
$(sed 's/^/      /' "$WORK/out/$case.txt")"
    fi
  fi
done < "$WORK/julia_cases.txt"

# The `complete` case is only worth anything if it exercised the branches it was
# built to exercise; a verdict of "ok" reached by skipping them proves nothing.
grep -q "1 stdlib" "$WORK/out/complete.txt" \
  && ok "complete: the stdlib entry was resolved as a stdlib (not skipped)" \
  || fail "complete: no stdlib entry was checked:
$(sed 's/^/      /' "$WORK/out/complete.txt")"
grep -q "1 pruned" "$WORK/out/complete.txt" \
  && ok "complete: the unreachable, uninstalled entry was pruned, exactly as instantiate prunes it" \
  || fail "complete: the unreachable entry was not pruned:
$(sed 's/^/      /' "$WORK/out/complete.txt")"

# A stale project must be distinguishable from a missing package: the whole
# point of reporting it specifically is that it needs a RESOLVE, not a download.
grep -q "not installed" "$WORK/out/stale_project.txt" \
  && fail "a stale Project.toml was reported as a missing package" \
  || ok "stale_project: reported as a resolve problem, not a download problem"

# ...and a broken manifest must not masquerade as either.
C="$WORK/complete"
cp "$C/env/Manifest.toml" "$WORK/manifest.good"
printf 'this is not toml\n' > "$C/env/Manifest.toml"
JULIA_DEPOT_PATH="$C/depot" "$AJT" verify --frozen "$C/env" >"$WORK/broken.out" 2>&1
BROKEN_RC=$?
cp "$WORK/manifest.good" "$C/env/Manifest.toml"
# 3, not 1: a manifest that will not parse is not fixed by installing anything
# (`Kind.repair`).
expect_eq "$BROKEN_RC" "3" "an unparseable manifest exits 3 — no Pkg verb fixes it"
grep -q "not a valid Manifest.toml" "$WORK/broken.out" \
  && ok "an unparseable manifest says so" \
  || fail "unparseable manifest reported as: $(cat "$WORK/broken.out")"

# ---------------------------------------------------------------------------
# 4. --check-hashes: the opt-in deep mode
# ---------------------------------------------------------------------------
echo "==> 4. --check-hashes"

JULIA_DEPOT_PATH="$C/depot" "$AJT" verify --frozen --check-hashes "$C/env" >"$WORK/deep.out" 2>&1
expect_eq "$?" "0" "a genuine install passes --check-hashes (its tree hash is Pkg.GitTools.tree_hash's)"
grep -q "re-hashed" "$WORK/deep.out" \
  && ok "the report says the trees were actually re-hashed" \
  || fail "--check-hashes did not report re-hashing: $(cat "$WORK/deep.out")"

# One byte inside an installed package: the directory still exists, so the
# default mode cannot see it. This is exactly the class of corruption
# --check-hashes exists for.
chmod u+w "$C/depot/packages/Foo/$SLUG_FOO/src/Pkgsrc.jl"
printf 'const SNEAKY = 1\n' >> "$C/depot/packages/Foo/$SLUG_FOO/src/Pkgsrc.jl"

JULIA_DEPOT_PATH="$C/depot" "$AJT" verify --frozen "$C/env" >/dev/null 2>&1
expect_eq "$?" "0" "the default mode still passes a mutated install (existence only, by design)"

JULIA_DEPOT_PATH="$C/depot" "$AJT" verify --frozen --check-hashes "$C/env" >"$WORK/deep2.out" 2>&1
# Also 3: a tree that no longer matches its git-tree-sha1 is corruption, and
# re-running `instantiate` would find the directory present and do nothing.
expect_eq "$?" "3" "--check-hashes catches the mutated install"
grep -q "does not match its git-tree-sha1" "$WORK/deep2.out" \
  && ok "and names the cause" \
  || fail "--check-hashes message: $(cat "$WORK/deep2.out")"

MUTATED="$(jl -e '
using Pkg
println(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$C/depot/packages/Foo/$SLUG_FOO")"
grep -q "$MUTATED" "$WORK/deep2.out" \
  && ok "the reported tree hash equals Pkg.GitTools.tree_hash of the mutated tree" \
  || fail "reported hash is not julia's ($MUTATED):
$(sed 's/^/      /' "$WORK/deep2.out")"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS — verify agrees with julia $JV on ${#CASES[@]} cases + the real environment,"
  echo "       wrote nothing, and answered in ${MEDIAN} ms where Pkg.instantiate() took ${PKG_MS} ms"
  exit 0
fi
echo "FAILED"
exit 1
