#!/usr/bin/env bash
# Differential gate for `ajt build` (src/ops/build.zig, src/ops/sandbox.zig).
#
# The claim: **`ajt build` and `Pkg.build`, run over the same environment into
# two equally-prepared depots, run the same build scripts in the same order,
# put `build.log` at the same path with the same bytes, and leave a
# `scratch_usage.toml` that a real `Pkg.gc()` reads without throwing.**
#
# That last clause is the one that matters most and the reason this file is
# long. `scratch_usage.toml` is append-only and every entry carries a
# `parent_projects` array, which `gc` reads UNCONDITIONALLY (`API.jl:664`:
# `for parent in v["parent_projects"]`). A writer that condensed the file the
# way `write_env_usage` condenses the other two logs would drop that key, and
# the symptom would not be a weaker log -- it would be a `KeyError` out of
# every subsequent `Pkg.gc()`, including the automatic one `Pkg._auto_gc` fires
# on `up`/`pin`/`free`/`rm`. So section 3 runs a real
# `Pkg.gc(collect_delay = Second(0))` against the depot ajt wrote and asserts
# both halves: it does not error, and it does not delete the live scratchspace.
#
# Six sections:
#
#   0. THE FIXTURES. Five packages and a one-package local registry, all built
#      on the spot, no network:
#        * `PathPkg`   -- path-tracked (a `dev`ed dependency). Its log must land
#                         at `<source>/deps/build.log` and produce NO usage
#                         entry, because there is no scratchspace to keep alive.
#        * `TreePkg`   -- content-addressed: installed into each depot at
#                         `packages/TreePkg/<version_slug>` with a real tree
#                         hash, and pinned by `git-tree-sha1` in the manifest.
#                         Its log must land in Pkg's own scratchspace and DOES
#                         produce a usage entry.
#        * `Alpha`/`Beta` -- an ordering pair. `Beta`'s build.jl READS the file
#                         `Alpha`'s build.jl writes, so a wrong order is a hard
#                         failure rather than a cosmetic difference.
#      Landmark assertions: the fixtures exist, both binaries were found, and
#      the marker files do NOT exist before either side runs.
#   1. THE PATH-TRACKED PACKAGE. Both sides; marker, log path, log bytes, and
#      the absence of a usage entry.
#   2. THE TREE-HASH-PINNED PACKAGE. Same, plus the scratchspace path (which
#      neither side is told -- both derive it) and the presence of a usage
#      entry on ajt's side.
#   3. `Pkg.gc()` OVER AJT'S DEPOT. Does not throw; the live scratchspace
#      survives. Then the usage log is DELETED and the same gc is run again --
#      and now the scratchspace must be gone. A gate that cannot fail is worse
#      than none, so the falsification half is not optional.
#   4. A FAILING BUILD. Both sides must exit non-zero and both messages must
#      carry the log's own text.
#   5. BUILD ORDER. `Alpha` before `Beta`, proved by `Beta`'s script reading
#      `Alpha`'s output rather than by parsing an order out of the report.
#
# ~/.julia is READ ONLY here, and that is enforced rather than asserted: every
# `julia` invocation runs under a JULIA_DEPOT_PATH whose FIRST entry is a
# scratch depot, so anything written (precompile caches, logs, scratchspaces)
# lands there. Only reads reach ~/.julia -- the warm precompile cache, so the
# oracle helpers are fast. The one exception is section 3, which runs
# `Pkg.gc()` and therefore gets a JULIA_DEPOT_PATH holding NOTHING but the
# scratch depot: `gc` sweeps every entry of `depots()`, and a run that could
# see ~/.julia could delete out of it.
#
# NO NETWORK. Every package here is built on the spot and the registry is four
# hand-written TOML files; nothing is downloaded. That is deliberate -- the
# questions this file asks are about ordering, log placement and gc
# reachability, none of which need General, and a gate that needs the network
# is a gate that goes red on a train.
#
# Usage: build.sh [--keep]
#   --keep   leave $WORK behind
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT="$AJT_ROOT/zig-out/bin/ajt"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
HOST_DEPOT="${DEPOT_ENV%%:*}"
HOST_DEPOT="${HOST_DEPOT:-$HOME/.julia}"

# Pkg's own uuid -- `const PkgUUID` (`Operations.jl:1392`). The scratchspace a
# build.log goes in belongs to Pkg, not to the package being built.
PKG_UUID="44cfe95a-1eb2-52ea-b672-e2afdf69b78f"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    # Every line of the header block, and nothing past it: `set -uo pipefail`
    # printed as documentation is how you learn the range drifted.
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT" ] || { echo "ERROR: $AJT missing — run 'zig build' first" >&2; exit 2; }

JULIA_PREFIX="$(dirname "$(dirname "$(command -v julia)")")"

# `|| exit 2` is not decoration: there is no `set -e` here, so a failed mktemp
# would leave WORK empty and the whole harness would scribble at `/`.
WORK="$(mktemp -d -t ajt-build-XXXXXX)" || exit 2
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: could not create a work directory" >&2; exit 2; }
# Pkg makes installed packages read-only (`set_readonly`), so the cleanup has
# to restore write bits before it can delete them.
cleanup() { [ $KEEP -eq 0 ] && { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; return 0; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

mkdir -p "$WORK/oracle"

# Every ORACLE julia invocation goes through this. `$WORK/oracle` first means
# any `compiled/*.ji` lands in the scratch depot; `$HOST_DEPOT` second means
# the already-warm caches there are still READ, so these stay fast. Calling
# bare `julia` would precompile into the user's real depot -- a write, and one
# that makes the "read only" claim in the header false.
jl() { JULIA_DEPOT_PATH="$WORK/oracle:$HOST_DEPOT" julia --startup-file=no "$@"; }

echo "=== 0. Fixtures ==========================================================="

# --- the packages ----------------------------------------------------------
mk_pkg() { # name uuid
  mkdir -p "$WORK/src/$1/src" "$WORK/src/$1/deps"
  printf 'name = "%s"\nuuid = "%s"\nversion = "0.1.0"\n' "$1" "$2" > "$WORK/src/$1/Project.toml"
  printf 'module %s\nend\n' "$1" > "$WORK/src/$1/src/$1.jl"
}

PATH_UUID="11111111-1111-1111-1111-111111111111"
TREE_UUID="22222222-2222-2222-2222-222222222222"
ALPHA_UUID="33333333-3333-3333-3333-333333333333"
BETA_UUID="44444444-4444-4444-4444-444444444444"
FAIL_UUID="55555555-5555-5555-5555-555555555555"

mk_pkg PathPkg "$PATH_UUID"
mk_pkg TreePkg "$TREE_UUID"
mk_pkg Alpha   "$ALPHA_UUID"
mk_pkg Beta    "$BETA_UUID"
mk_pkg FailPkg "$FAIL_UUID"

# The marker path is passed in through the environment so ONE package source
# can serve two sides without either being able to see the other's output.
cat > "$WORK/src/PathPkg/deps/build.jl" <<'JL'
println("PathPkg build.jl running")
marker = ENV["AJT_GATE_MARKER"]
mkpath(dirname(marker))
write(marker, "PathPkg\n")
println("PathPkg wrote its marker")
JL
cat > "$WORK/src/TreePkg/deps/build.jl" <<'JL'
println("TreePkg build.jl running")
marker = ENV["AJT_GATE_MARKER"]
mkpath(dirname(marker))
write(marker, "TreePkg\n")
println("TreePkg wrote its marker")
JL
# Alpha writes a file; Beta REQUIRES it. Order is therefore load-bearing rather
# than merely observable -- a wrong order is a non-zero exit, not a diff.
cat > "$WORK/src/Alpha/deps/build.jl" <<'JL'
d = ENV["AJT_GATE_ORDER"]
mkpath(dirname(d))
write(d, "alpha\n")
println("Alpha built")
JL
cat > "$WORK/src/Beta/deps/build.jl" <<'JL'
d = ENV["AJT_GATE_ORDER"]
isfile(d) || error("Beta built before Alpha: $d does not exist")
write(d, read(d, String) * "beta\n")
println("Beta built after Alpha")
JL
cat > "$WORK/src/FailPkg/deps/build.jl" <<'JL'
println("about to fail on purpose")
println("SENTINEL_LINE_IN_LOG")
error("deliberate build failure")
JL

# --- the tree hash of TreePkg, and where it installs ------------------------
# `Pkg.GitTools.tree_hash` is the same git tree object hash a registry records;
# `Base.version_slug` is the directory name Julia looks in. Both are asked of
# Julia rather than reimplemented here -- this gate is about `ajt build`, not
# about `ajt tree-hash`, which `treehash.sh` already covers.
TREE_HASH="$(jl -e '
using Pkg
print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$WORK/src/TreePkg")"
TREE_SLUG="$(jl -e '
using Base: UUID, SHA1
print(Base.version_slug(UUID(ARGS[1]), SHA1(ARGS[2])))' "$TREE_UUID" "$TREE_HASH")"

# Cross-check the two implementations agree, because everything downstream is
# keyed on this hash and a silent disagreement would make both sides "pass"
# against two different, equally empty directories.
AJT_TREE_HASH="$("$AJT" tree-hash "$WORK/src/TreePkg" | awk '{print $1}')"
check "ajt and Pkg agree on TreePkg's tree hash" "$TREE_HASH" "$AJT_TREE_HASH"
[ -n "$TREE_SLUG" ] && ok "version_slug resolved ($TREE_SLUG)" || bad "version_slug resolved"

# --- the environment --------------------------------------------------------
# Written by hand rather than by `Pkg.develop`, because the point is to hand
# BOTH tools one identical, byte-stable environment. A `path` entry and a
# `git-tree-sha1` entry in one manifest is exactly the pair that exercises the
# two log destinations.
mkdir -p "$WORK/env"
cat > "$WORK/env/Project.toml" <<EOF
[deps]
Alpha = "$ALPHA_UUID"
Beta = "$BETA_UUID"
PathPkg = "$PATH_UUID"
TreePkg = "$TREE_UUID"
EOF
cat > "$WORK/env/Manifest.toml" <<EOF
# This file is machine-generated - editing it directly is not advised

julia_version = "$(jl -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "0000000000000000000000000000000000000000"

[[deps.Alpha]]
path = "../src/Alpha"
uuid = "$ALPHA_UUID"
version = "0.1.0"

[[deps.Beta]]
deps = ["Alpha"]
path = "../src/Beta"
uuid = "$BETA_UUID"
version = "0.1.0"

[[deps.PathPkg]]
path = "../src/PathPkg"
uuid = "$PATH_UUID"
version = "0.1.0"

[[deps.TreePkg]]
git-tree-sha1 = "$TREE_HASH"
uuid = "$TREE_UUID"
version = "0.1.0"
EOF

# `project_hash` above is a placeholder; make it the real one so nothing warns
# about a stale manifest and the two sides cannot diverge on that account.
jl -e '
using Pkg, TOML
env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
Pkg.Operations.record_project_hash(env)
Pkg.Types.write_manifest(env)' "$WORK/env" >/dev/null 2>&1 || true

# --- two depots, each with TreePkg installed at its content address ---------
#
# Plus a one-package LOCAL registry, in both, and it is not optional: Pkg's
# sandbox ALWAYS resolves (`Operations.jl:2296`), and resolving a manifest
# entry pinned by `git-tree-sha1` runs `check_registered`, which raises
# "expected package `TreePkg` to be registered" for a package no registry
# carries. So without this, `Pkg.build` cannot build ANY content-addressed
# fixture and there is nothing to diff against. Four small TOML files is much
# less machinery than a network fetch of a real registered package, and it
# keeps the gate offline.
#
# ajt does not need it -- its sandbox resolve is opt-in and this run does not
# pass `--registry-depot` -- but both depots get it anyway so the two sides
# stay comparable in everything except which tool ran.
for d in A B; do
  DEST="$WORK/depot$d/packages/TreePkg/$TREE_SLUG"
  mkdir -p "$(dirname "$DEST")"
  cp -a "$WORK/src/TreePkg" "$DEST"
  # `deps/build.log` must NOT be pre-created; assert the tree we copied is
  # clean, or section 2's "the log is not here" check is meaningless.
  [ -e "$DEST/deps/build.log" ] && bad "installed TreePkg came with a build.log"

  REG="$WORK/depot$d/registries/Local"
  mkdir -p "$REG/T/TreePkg"
  cat > "$REG/Registry.toml" <<EOF
name = "Local"
uuid = "99999999-9999-9999-9999-999999999999"
repo = ""
description = "build.sh fixture registry"

[packages]
$TREE_UUID = { name = "TreePkg", path = "T/TreePkg" }
EOF
  cat > "$REG/T/TreePkg/Package.toml" <<EOF
name = "TreePkg"
uuid = "$TREE_UUID"
repo = ""
EOF
  cat > "$REG/T/TreePkg/Versions.toml" <<EOF
["0.1.0"]
git-tree-sha1 = "$TREE_HASH"
EOF
done
ok "TreePkg installed into both depots at packages/TreePkg/$TREE_SLUG"

# Landmark: nothing has run yet, so no marker, no log, no scratchspace.
NOTHING=1
for p in "$WORK/marker-a" "$WORK/marker-b" \
         "$WORK/src/PathPkg/deps/build.log" \
         "$WORK/depotA/scratchspaces" "$WORK/depotB/scratchspaces" \
         "$WORK/depotA/logs/scratch_usage.toml"; do
  [ -e "$p" ] && NOTHING=0
done
check "the corpus starts clean (no markers, logs or scratchspaces)" 1 "$NOTHING"

echo
echo "=== 1. The path-tracked package ==========================================="

# Pkg's side. `JULIA_DEPOT_PATH` puts depotB first so depots1() -- and
# therefore every log and scratchspace -- is the scratch depot; $HOST_DEPOT is
# second only so Pkg itself loads from warm caches.
AJT_GATE_MARKER="$WORK/marker-b-path" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.build("PathPkg")' > "$WORK/pkg-path.out" 2>&1
PKG_PATH_RC=$?
check "Pkg.build(\"PathPkg\") exited 0" 0 "$PKG_PATH_RC"
check "Pkg.build wrote its marker" "PathPkg" "$(cat "$WORK/marker-b-path" 2>/dev/null)"

PKG_PATH_LOG="$(cat "$WORK/src/PathPkg/deps/build.log" 2>/dev/null)"
[ -n "$PKG_PATH_LOG" ] && ok "Pkg put the log at <source>/deps/build.log" \
  || bad "Pkg put the log at <source>/deps/build.log" "file missing or empty"
mv "$WORK/src/PathPkg/deps/build.log" "$WORK/pkg-path.log" 2>/dev/null

# ajt's side, into the OTHER depot.
AJT_GATE_MARKER="$WORK/marker-a-path" \
  "$AJT" build --project "$WORK/env" \
    --depot "$WORK/depotA" \
    --julia-prefix "$JULIA_PREFIX" \
    PathPkg > "$WORK/ajt-path.out" 2>"$WORK/ajt-path.err"
AJT_PATH_RC=$?
check "ajt build PathPkg exited 0" 0 "$AJT_PATH_RC"
check "ajt build wrote its marker" "PathPkg" "$(cat "$WORK/marker-a-path" 2>/dev/null)"

AJT_PATH_LOG_PATH="$(awk -F'\t' '$1=="build"{print $5}' "$WORK/ajt-path.out")"
check "ajt reported the log at <source>/deps/build.log" \
  "$WORK/src/PathPkg/deps/build.log" "$AJT_PATH_LOG_PATH"
check "and that is where it is" "yes" \
  "$([ -f "$WORK/src/PathPkg/deps/build.log" ] && echo yes || echo no)"

# The bytes. The script writes to stdout only, so `pipeline(stdout=log,
# stderr=log)` and ajt's stdout-then-stderr concatenation produce the same
# file; a divergence here means one side lost or reordered output.
if diff -u "$WORK/pkg-path.log" "$WORK/src/PathPkg/deps/build.log" > "$WORK/path-log.diff" 2>&1; then
  ok "build.log is byte-identical on both sides"
else
  bad "build.log is byte-identical on both sides" "$(head -20 "$WORK/path-log.diff")"
fi

# The negative half: a path-tracked package must leave NO usage entry, because
# it has no scratchspace to keep alive and the key would be a root `gc` can
# never resolve.
check "ajt wrote no scratch_usage.toml for a path-tracked package" "no" \
  "$([ -f "$WORK/depotA/logs/scratch_usage.toml" ] && echo yes || echo no)"
check "and neither did Pkg" "no" \
  "$([ -f "$WORK/depotB/logs/scratch_usage.toml" ] && echo yes || echo no)"

echo
echo "=== 2. The tree-hash-pinned package ======================================="

SCRATCH_REL="scratchspaces/$PKG_UUID/$TREE_HASH/build.log"

AJT_GATE_MARKER="$WORK/marker-b-tree" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.build("TreePkg")' > "$WORK/pkg-tree.out" 2>&1
PKG_TREE_RC=$?
check "Pkg.build(\"TreePkg\") exited 0" 0 "$PKG_TREE_RC"
check "Pkg.build wrote its marker" "TreePkg" "$(cat "$WORK/marker-b-tree" 2>/dev/null)"
check "Pkg put the log in Pkg's scratchspace" "yes" \
  "$([ -f "$WORK/depotB/$SCRATCH_REL" ] && echo yes || echo no)"

AJT_GATE_MARKER="$WORK/marker-a-tree" \
  "$AJT" build --project "$WORK/env" \
    --depot "$WORK/depotA" \
    --julia-prefix "$JULIA_PREFIX" \
    TreePkg > "$WORK/ajt-tree.out" 2>"$WORK/ajt-tree.err"
AJT_TREE_RC=$?
check "ajt build TreePkg exited 0" 0 "$AJT_TREE_RC"
check "ajt build wrote its marker" "TreePkg" "$(cat "$WORK/marker-a-tree" 2>/dev/null)"

AJT_TREE_LOG_PATH="$(awk -F'\t' '$1=="build"{print $5}' "$WORK/ajt-tree.out")"
check "ajt derived the same scratchspace path" "$WORK/depotA/$SCRATCH_REL" "$AJT_TREE_LOG_PATH"

if diff -u "$WORK/depotB/$SCRATCH_REL" "$WORK/depotA/$SCRATCH_REL" > "$WORK/tree-log.diff" 2>&1; then
  ok "build.log is byte-identical on both sides"
else
  bad "build.log is byte-identical on both sides" "$(head -20 "$WORK/tree-log.diff")"
fi

# And the log did NOT go into the read-only installed source tree.
check "nothing was written into packages/TreePkg/$TREE_SLUG/deps" "no" \
  "$([ -f "$WORK/depotA/packages/TreePkg/$TREE_SLUG/deps/build.log" ] && echo yes || echo no)"

# The usage entry. Compared through Julia's own parser rather than by grepping,
# because the question is what `gc` sees, not what the text looks like.
check "ajt wrote logs/scratch_usage.toml" "yes" \
  "$([ -f "$WORK/depotA/logs/scratch_usage.toml" ] && echo yes || echo no)"
# Read the way `gc`'s `reduce_usage!` reads it (`API.jl:655-670`), not by
# grepping the text: the question is what `gc` sees. The depot root is
# normalised away so the two sides can be compared directly, and `time` is
# reduced to "is it there", because two wall clocks never match.
usage_shape() {
  [ -f "$2" ] || { echo "MISSING"; return 0; }
  jl -e '
using TOML
d = TOML.parsefile(ARGS[2])
for k in sort(collect(keys(d)))
    for e in d[k]
        # `gc` reads BOTH of these without a haskey guard (`API.jl:660-668`);
        # an entry missing `parent_projects` is a KeyError, not a weaker log.
        println(replace(k, ARGS[1] => "<DEPOT>"), "\t", haskey(e, "time"), "\t",
                join([replace(p, ARGS[1] => "<DEPOT>") for p in e["parent_projects"]], ","))
    end
end' "$1" "$2" 2>&1
}
AJT_SHAPE="$(usage_shape "$WORK/depotA" "$WORK/depotA/logs/scratch_usage.toml")"
check "the entry is keyed on the scratchspace dir and carries both keys" \
  "<DEPOT>/scratchspaces/$PKG_UUID/$TREE_HASH	true	<DEPOT>/packages/TreePkg/$TREE_SLUG/Project.toml" \
  "$AJT_SHAPE"

# And the strong form: Pkg's own entry for the same build, normalised the same
# way, must be the same record. This is the check that would catch a
# `parent_projects` pointing at the ENVIRONMENT rather than at the package --
# a mistake that looks right, keeps nothing alive that `manifest_usage.toml`
# does not already keep, and would make the scratchspace collectable.
PKG_SHAPE="$(usage_shape "$WORK/depotB" "$WORK/depotB/logs/scratch_usage.toml")"
check "and it is the same record Pkg writes" "$PKG_SHAPE" "$AJT_SHAPE"

echo
echo "=== 3. Pkg.gc() over the depot ajt wrote =================================="
# THE CHECK THAT MATTERS. Note the depot stack: ONLY depotA. `Pkg.gc()` sweeps
# every entry of `depots()`, so a run that could see ~/.julia could delete out
# of it.

GC1="$(JULIA_DEPOT_PATH="$WORK/depotA" julia --startup-file=no --project="$WORK/env" -e '
using Pkg, Dates
try
    Pkg.gc(collect_delay = Second(0))
    println("GC_OK")
catch err
    println("GC_THREW ", sprint(showerror, err))
end' 2>&1)"
if printf '%s' "$GC1" | grep -q GC_OK; then
  ok "Pkg.gc(collect_delay = Second(0)) does not throw on ajt's scratch_usage.toml"
else
  bad "Pkg.gc(collect_delay = Second(0)) does not throw on ajt's scratch_usage.toml" \
      "$(printf '%s' "$GC1" | tail -5)"
fi
check "and the live scratchspace survived it" "yes" \
  "$([ -f "$WORK/depotA/$SCRATCH_REL" ] && echo yes || echo no)"

# The falsification. Remove the usage log -- the ONLY thing that makes the
# scratchspace reachable -- and gc must now collect it. Without this half the
# check above would pass against a gc that collects nothing at all.
rm -f "$WORK/depotA/logs/scratch_usage.toml" "$WORK/depotA/logs/orphaned.toml"
JULIA_DEPOT_PATH="$WORK/depotA" julia --startup-file=no --project="$WORK/env" -e '
using Pkg, Dates
Pkg.gc(collect_delay = Second(0))' > "$WORK/gc2.out" 2>&1
check "with the usage log deleted, gc DOES collect the scratchspace" "no" \
  "$([ -f "$WORK/depotA/$SCRATCH_REL" ] && echo yes || echo no)"

echo
echo "=== 4. A failing build ===================================================="

# A second environment, so section 5's ordering run is not poisoned by a
# package that always fails.
#
# It holds TWO packages, and that is the point: `Alpha` builds fine and
# `FailPkg` does not, so the run must stop after the failure with `Alpha`
# reported and `Beta` — which sorts after `FailPkg` here — reported not at all.
# A one-package environment would pass against an implementation that labels
# every planned-but-never-started package `failed`.
mkdir -p "$WORK/failenv"
cat > "$WORK/failenv/Project.toml" <<EOF
[deps]
Beta = "$BETA_UUID"
FailPkg = "$FAIL_UUID"
EOF
cat > "$WORK/failenv/Manifest.toml" <<EOF
# This file is machine-generated - editing it directly is not advised

julia_version = "$(jl -e 'print(VERSION)')"
manifest_format = "2.0"

[[deps.Alpha]]
path = "../src/Alpha"
uuid = "$ALPHA_UUID"
version = "0.1.0"

[[deps.Beta]]
deps = ["Alpha", "FailPkg"]
path = "../src/Beta"
uuid = "$BETA_UUID"
version = "0.1.0"

[[deps.FailPkg]]
deps = ["Alpha"]
path = "../src/FailPkg"
uuid = "$FAIL_UUID"
version = "0.1.0"
EOF

# No package argument on either side: the whole environment, so the order is
# `Alpha`, `FailPkg`, `Beta` and the abort happens with one build left.
rm -f "$WORK/order-fail" "$WORK/src/FailPkg/deps/build.log" "$WORK/src/Alpha/deps/build.log"
AJT_GATE_ORDER="$WORK/order-fail" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/failenv" \
    -e 'using Pkg; Pkg.build()' > "$WORK/pkg-fail.out" 2>&1
PKG_FAIL_RC=$?
mv "$WORK/src/FailPkg/deps/build.log" "$WORK/pkg-fail.log" 2>/dev/null

[ "$PKG_FAIL_RC" -ne 0 ] && ok "Pkg.build exits non-zero on a failing build.jl" \
  || bad "Pkg.build exits non-zero on a failing build.jl"
printf '%s' "$(cat "$WORK/pkg-fail.out")" | grep -q "Error building" \
  && ok "Pkg's message says \`Error building\`" \
  || bad "Pkg's message says \`Error building\`" "$(tail -5 "$WORK/pkg-fail.out")"
# Pkg's own progress lines are the oracle for "which packages did it start":
# `Alpha` and `FailPkg`, and NOT `Beta`, which sorts after the failure.
check "Pkg started Alpha and FailPkg and never reached Beta" "Alpha FailPkg" \
  "$(grep -oE 'Building (Alpha|Beta|FailPkg)' "$WORK/pkg-fail.out" | sed 's/Building //' | sort -u | tr '\n' ' ' | sed 's/ $//')"

rm -f "$WORK/order-fail" "$WORK/src/Alpha/deps/build.log"
AJT_GATE_ORDER="$WORK/order-fail" \
  "$AJT" build --project "$WORK/failenv" \
    --depot "$WORK/depotA" \
    --julia-prefix "$JULIA_PREFIX" \
    > "$WORK/ajt-fail.out" 2>"$WORK/ajt-fail.err"
AJT_FAIL_RC=$?
[ "$AJT_FAIL_RC" -ne 0 ] && ok "ajt build exits non-zero on a failing build.jl" \
  || bad "ajt build exits non-zero on a failing build.jl"

# THE ABORT. Two records, not three: `Beta` was planned and never started, and
# reporting it as `failed` would name a package no child ever ran for.
check "ajt reports only the packages that actually ran" "ok:Alpha failed:FailPkg" \
  "$(awk -F'\t' '$1=="build"{printf "%s:%s ", $2, $3}' "$WORK/ajt-fail.out" | sed 's/ $//')"

# Both must ABORT with the log's own text in the message -- not a bare exit
# code, which is what a user sees when a build fails and is the whole reason
# Pkg reads the log back before raising.
grep -q "Error building" "$WORK/ajt-fail.err" \
  && ok "ajt's message says \`Error building\`, as Pkg's does" \
  || bad "ajt's message says \`Error building\`" "$(tail -5 "$WORK/ajt-fail.err")"
grep -q "SENTINEL_LINE_IN_LOG" "$WORK/ajt-fail.err" \
  && ok "ajt's message carries the log tail" \
  || bad "ajt's message carries the log tail" "$(tail -10 "$WORK/ajt-fail.err")"
grep -q "SENTINEL_LINE_IN_LOG" "$WORK/pkg-fail.out" \
  && ok "and so does Pkg's, which is why this is the contract" \
  || bad "Pkg's message carries the log tail" "$(tail -10 "$WORK/pkg-fail.out")"

# The log itself is still written on failure, at the same place.
check "ajt wrote the failing build's log too" "yes" \
  "$([ -f "$WORK/src/FailPkg/deps/build.log" ] && echo yes || echo no)"
if [ ! -f "$WORK/pkg-fail.log" ] || [ ! -f "$WORK/src/FailPkg/deps/build.log" ]; then
  # Without this guard the `grep -c` fallback below compares "" with "" and
  # passes on two files that do not exist — the exact vacuous-green shape this
  # harness is written to avoid.
  bad "both sides wrote a failing build.log" \
      "pkg: $([ -f "$WORK/pkg-fail.log" ] && echo yes || echo no), ajt: $([ -f "$WORK/src/FailPkg/deps/build.log" ] && echo yes || echo no)"
elif diff -u "$WORK/pkg-fail.log" "$WORK/src/FailPkg/deps/build.log" > "$WORK/fail-log.diff" 2>&1; then
  ok "the failing build.log matches Pkg's byte for byte"
else
  # Julia's error text includes a stack trace with absolute paths that differ
  # between a `Pkg.build` child and an `ajt build` child (different --eval
  # code, hence different line numbers), so compare the part that is the
  # SCRIPT's own output. Asserted non-zero as well as equal: `0 == 0` would be
  # true of two logs that contain nothing at all.
  A="$(grep -c SENTINEL_LINE_IN_LOG "$WORK/pkg-fail.log")"
  B="$(grep -c SENTINEL_LINE_IN_LOG "$WORK/src/FailPkg/deps/build.log")"
  check "the failing build.log carries the script's output on both sides" "$A" "$B"
  [ "${A:-0}" -gt 0 ] && ok "  and it is actually there (${A}x)" \
    || bad "  and it is actually there" "the sentinel appears 0 times in both logs"
fi

echo
echo "=== 5. Build order ========================================================"

# `Beta`'s build.jl errors unless `Alpha`'s ran first, so this is a hard gate
# on `dependency_order_uuids`, not an inspection of the report. Both packages
# are built in one invocation, which is the only way the order is ajt's choice
# rather than the caller's.
#
# BOTH argument orders, and that is not belt-and-braces. `get_deps` walks its
# roots off a stack, so `Beta Alpha` comes out of the closure as `Alpha, Beta`
# ALREADY -- measured by deleting the sort and re-running, which stayed green.
# `Alpha Beta` is the order whose closure is wrong and where the toposort is
# the only thing that fixes it. A gate that tried one argument order would
# have been the gate that cannot fail.
for pair in "Beta Alpha" "Alpha Beta"; do
  rm -f "$WORK/order-a"
  # shellcheck disable=SC2086
  AJT_GATE_ORDER="$WORK/order-a" \
    "$AJT" build --project "$WORK/env" \
      --depot "$WORK/depotA" \
      --julia-prefix "$JULIA_PREFIX" \
      $pair > "$WORK/ajt-order.out" 2>"$WORK/ajt-order.err"
  AJT_ORDER_RC=$?
  check "ajt build $pair exited 0" 0 "$AJT_ORDER_RC"
  check "  Alpha ran before Beta" "alpha
beta" "$(cat "$WORK/order-a" 2>/dev/null)"
  # And the report agrees, which is what a caller reads.
  check "  the report lists them in that order too" "Alpha Beta" \
    "$(awk -F'\t' '$1=="build"{printf "%s ", $3}' "$WORK/ajt-order.out" | sed 's/ $//')"
done

for pair in '["Beta", "Alpha"]' '["Alpha", "Beta"]'; do
  rm -f "$WORK/order-b"
  AJT_GATE_ORDER="$WORK/order-b" \
  JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
    julia --startup-file=no --project="$WORK/env" \
      -e "using Pkg; Pkg.build($pair)" > "$WORK/pkg-order.out" 2>&1
  PKG_ORDER_RC=$?
  check "Pkg.build($pair) exited 0" 0 "$PKG_ORDER_RC"
  check "  Pkg ordered them the same way" "alpha
beta" "$(cat "$WORK/order-b" 2>/dev/null)"
done

echo
echo "=== 6. The user's real depot was not written =============================="
# A $WORK-prefixed key in ~/.julia's logs is unambiguous evidence of a leak.
# Its ABSENCE is not proof of none -- it does not cover packages/ or
# artifacts/ -- but checking mtimes instead would be worse: any other julia on
# this machine touches ~/.julia.
LEAK=0
for f in "$HOST_DEPOT/logs/scratch_usage.toml" "$HOST_DEPOT/logs/manifest_usage.toml"; do
  [ -f "$f" ] && grep -q "$WORK" "$f" && LEAK=1
done
[ -d "$HOST_DEPOT/scratchspaces/$PKG_UUID/$TREE_HASH" ] && LEAK=1
check "no fixture path leaked into $HOST_DEPOT" 0 "$LEAK"

echo
echo "=========================================================================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
