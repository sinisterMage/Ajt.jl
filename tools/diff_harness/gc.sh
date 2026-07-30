#!/usr/bin/env bash
# Differential gate for `ajt gc` (src/ops/gc.zig) against `Pkg.gc()`.
#
# This is the only command in Ajt that unlinks a user's files, and its failure
# mode is silent and delayed — a package deleted today surfaces as a broken
# environment next week. So the gate is TWO-SIDED everywhere: every claim about
# what survives is paired with a demonstration that the same machinery does
# delete when it should, and every claim about Ajt is measured against what
# `Pkg.gc()` did to a byte-identical depot rather than against this script's
# opinion.
#
# Six sections:
#
#   0. LANDMARKS. The three derived names the fixture is built out of — a
#      version slug and two `clones/` hashes — are taken from Julia, not
#      hardcoded here. If Julia ever disagreed with the constants below, every
#      later section would be comparing two tools over a fixture that means
#      nothing, and would pass.
#
#   1. THE SYNTHETIC DIFF. One fixture depot is built TWICE, identically, from
#      the same generator. `Pkg.gc(collect_delay = Second(0))` collects one and
#      `ajt gc --all` collects the other. Then: the surviving inventories must
#      be equal AND must be the expected set; `logs/orphaned.toml` must be
#      equal; and the three condensed usage logs must be equal.
#
#      The fixture deliberately contains, of each kind, one thing that must
#      live and one that must die — including the three `clones/` cases, which
#      have two different naming schemes and only one of them is collectable.
#
#   2. THE GATE BITES. The same fixture with its usage logs REMOVED. Both tools
#      must now empty the depot. Without this the section above is worthless: a
#      gc that never deletes anything would sail through it.
#
#   3/3b. THE DEFAULT DELAY, and the marking ORDER. `collect_delay = Day(7)` must
#      delete NOTHING on either side — on first orphaning `free_time ==
#      gc_time` — while still writing an identical `orphaned.toml`. And because
#      the preliminary `packages_to_delete` is empty at that delay, an
#      `Artifacts.toml` living inside a doomed package is ACTIVE here and not
#      at `Second(0)`. That count flipping from 2 to 1 is the observable
#      signature of "packages are marked before artifacts", which is the one
#      ordering constraint Pkg writes a comment about. 3b adds the two cases
#      Pkg's REPL has no spelling for and which are therefore easy to leave
#      untested: `force = true` reaching a second depot, and the
#      `suspend_cache_*` markers under Pkg's own scratchspace uuid, which are
#      the one non-directory `gc` deletes and age on their own 24-hour timer.
#      Both are measured against `Pkg.gc()` and not against this file's opinion.
#
#   4. A REAL INSTALL (needs the network). `ajt install` fills a scratch depot,
#      then `ajt gc --all` must leave every package and artifact alone, and
#      must say it saw the logs. Then the logs are deleted and the same command
#      must take all of it.
#
#   5. THE USER'S REAL DEPOT WAS NOT WRITTEN. Every path here lives under
#      $WORK; a leak shows up as a $WORK-prefixed key in ~/.julia's logs.
#
# ~/.julia is READ ONLY, and that is enforced rather than asserted: every
# `julia` invocation goes through `jl`, whose JULIA_DEPOT_PATH has a scratch
# depot FIRST so precompilation output lands there. The one exception is
# `gc_now`, which must pass the target depot ALONE because `Pkg.gc()` only
# collects `depots1()` without `force = true` — the same exception
# `usage.sh` documents.
#
# Exit codes: 0 all checks passed, 1 a check failed, 3 section 4 was SKIPPED
# (no network or no General registry).
#
# Usage: tools/diff_harness/gc.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT="$AJT_ROOT/zig-out/bin/ajt"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
HOST_DEPOT="${DEPOT_ENV%%:*}"
HOST_DEPOT="${HOST_DEPOT:-$HOME/.julia}"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT" ] || { echo "ERROR: $AJT missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-gc-XXXXXX)"
# Installs are published READ-ONLY (depot.zig's set_readonly), so a plain
# `rm -rf` on a depot that `ajt install` filled can fail. tools/diff_harness/
# depot.sh carries the same trap for the same reason.
cleanup() { [ $KEEP -eq 0 ] && { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; return 0; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

mkdir -p "$WORK/oracle"

# EVERY julia invocation that is not a `Pkg.gc()` goes through this: a scratch
# depot first so `compiled/*.ji` lands there, the host depot second so the warm
# caches are still READ. Calling bare `julia` would write into ~/.julia and make
# the "read only" claim in this header false.
jl() { JULIA_DEPOT_PATH="$WORK/oracle:$HOST_DEPOT" julia --startup-file=no "$@"; }

# `Pkg.gc()` only collects `depots1()` unless `force = true` (API.jl:600), so
# the target depot has to be entry 0 and ALONE. That does mean Julia
# precompiles into it; nothing this gate compares looks at `compiled/`.
gc_pkg() { # gc_pkg <depot> <collect_delay-expr>
  JULIA_DEPOT_PATH="$1" julia --startup-file=no -e \
    "using Pkg, Dates; Pkg.gc(collect_delay = $2)" 2>&1
}

# ---------------------------------------------------------------------------
# Fixture constants — every derived one is checked against Julia in section 0.
# ---------------------------------------------------------------------------
SA_UUID="90137ffa-7385-5640-81b9-e52037218182"
SA_TREE="246a8bb2e6667f832eea063c3a56aef96429a3db"
SA_SLUG="0cEwi"
EX_UUID="7876af07-990d-54b4-ab0e-23690620f79a"
EX_TREE="8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
LIVE_URL="https://github.com/JuliaLang/Example.jl.git"
GONE_URL="https://github.com/JuliaLang/Gone.jl.git"
LIVE_CLONE="4643033083726148914"
GONE_CLONE="8989652085775856133"
ART_PLAIN="1111111111111111111111111111111111111111"
ART_KEYED="2222222222222222222222222222222222222222"
ART_DEAD="3333333333333333333333333333333333333333"
ART_DOOMED="4444444444444444444444444444444444444444"
STAMP="2026-01-01T00:00:00.000Z"

ENVDIR="$WORK/env"
mkdir -p "$ENVDIR"
cat > "$ENVDIR/Project.toml" <<EOF
name = "AjtGcProbe"
uuid = "3f2b1a0c-4d5e-4f60-8a71-9b2c3d4e5f61"
version = "0.1.0"
EOF
cat > "$ENVDIR/Manifest.toml" <<EOF
julia_version = "1.12.6"
manifest_format = "2.0"

[[deps.StaticArrays]]
uuid = "$SA_UUID"
git-tree-sha1 = "$SA_TREE"
version = "1.9.0"

[[deps.Example]]
uuid = "$EX_UUID"
git-tree-sha1 = "$EX_TREE"
repo-rev = "master"
repo-url = "$LIVE_URL"
version = "0.5.5"
EOF

# Build one fixture depot. Called twice with different roots, rather than
# copied, so the paths INSIDE each depot's own logs are that depot's own.
make_fixture() { # make_fixture <depot-root> [--no-logs]
  local D="$1" NOLOGS="${2:-}"
  mkdir -p \
    "$D/packages/StaticArrays/$SA_SLUG" \
    "$D/packages/StaticArrays/zzzzz" \
    "$D/packages/Dead/aaaaa" \
    "$D/artifacts/$ART_PLAIN" "$D/artifacts/$ART_KEYED" \
    "$D/artifacts/$ART_DEAD" "$D/artifacts/$ART_DOOMED" \
    "$D/clones/$LIVE_CLONE" "$D/clones/$GONE_CLONE" "$D/clones/$SA_UUID" \
    "$D/scratchspaces/$SA_UUID/live" \
    "$D/scratchspaces/$EX_UUID/dead" \
    "$D/logs"
  : > "$D/packages/StaticArrays/$SA_SLUG/Project.toml"
  : > "$D/artifacts/$ART_PLAIN/f" ; : > "$D/artifacts/$ART_KEYED/f"
  : > "$D/artifacts/$ART_DEAD/f"  ; : > "$D/artifacts/$ART_DOOMED/f"

  # Both shapes `process_artifacts_toml` branches on: a single table, and an
  # array of platform-keyed tables (API.jl:815-820).
  cat > "$D/packages/StaticArrays/$SA_SLUG/Artifacts.toml" <<EOF
[plain]
git-tree-sha1 = "$ART_PLAIN"
lazy = true

[[keyed]]
arch = "x86_64"
os = "linux"
git-tree-sha1 = "$ART_KEYED"
EOF
  # The ordering probe: an Artifacts.toml inside a package that is itself about
  # to be collected. At Second(0) `process_artifacts_toml` returns nothing for
  # it and $ART_DOOMED goes with the package; at Day(7) nothing is doomed yet,
  # so it is ACTIVE and the artifact is kept.
  cat > "$D/packages/Dead/aaaaa/Artifacts.toml" <<EOF
[bound]
git-tree-sha1 = "$ART_DOOMED"
EOF

  [ "$NOLOGS" = "--no-logs" ] && return 0

  cat > "$D/logs/manifest_usage.toml" <<EOF
[["$ENVDIR/Manifest.toml"]]
time = $STAMP
EOF
  cat > "$D/logs/artifact_usage.toml" <<EOF
[["$D/packages/Dead/aaaaa/Artifacts.toml"]]
time = $STAMP

[["$D/packages/StaticArrays/$SA_SLUG/Artifacts.toml"]]
time = $STAMP
EOF
  cat > "$D/logs/scratch_usage.toml" <<EOF
[["$D/scratchspaces/$EX_UUID/dead"]]
time = $STAMP
parent_projects = ["/nowhere/at/all/Project.toml"]

[["$D/scratchspaces/$SA_UUID/live"]]
time = $STAMP
parent_projects = ["$ENVDIR/Project.toml", "/nowhere/at/all/Project.toml"]
EOF
}

# Everything a sweep can collect, relative to the depot root, sorted.
#
# `scratchspaces/44cfe95a-...` is EXCLUDED: that is Pkg's own uuid, and the
# `Pkg.gc()` side of every comparison runs a Julia whose depots1() is the
# fixture, so Julia itself may drop precompilation markers in there. Comparing
# them would fail for a reason that has nothing to do with this change.
inventory() { # inventory <depot>
  ( cd "$1" 2>/dev/null || return 0
    [ -d packages ] && find packages -mindepth 1 -maxdepth 2 -type d
    for d in clones artifacts; do
      [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -type d
    done
    # Files too: `suspend_cache_*` markers are the one non-directory gc
    # collects, and a scratchspace's own contents are what prove the delete was
    # recursive.
    [ -d scratchspaces ] && find scratchspaces -mindepth 1 -maxdepth 2 \( -type d -o -type f \)
    true ) 2>/dev/null |
    grep -v '^scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f' | LC_ALL=C sort
}

# A usage/orphanage TOML with the depot root replaced and every array sorted,
# read through Julia's own parser rather than by grepping the text — so an
# equality here is an equality of MEANING, and `parent_projects` ordering (a
# `Set` on Pkg's side, sorted on Ajt's) cannot make two identical logs differ.
normalise_toml() { # normalise_toml <file> <depot-root> [--no-time]
  [ -f "$1" ] || { echo "MISSING $1"; return 0; }
  jl -e '
using TOML
d = TOML.parsefile(ARGS[1])
root = ARGS[2]
keep_time = ARGS[3] != "--no-time"
sub(s) = replace(String(s), root => "<DEPOT>")
t(x) = keep_time ? string(x) : "<TIME>"
for k in sort(collect(keys(d)))
    v = d[k]
    if v isa Vector
        for e in v
            if e isa Dict
                println(sub(k), "\t", t(get(e, "time", "?")), "\t",
                        join(sort(String[sub(p) for p in get(e, "parent_projects", String[])]), ","))
            else
                println(sub(k), "\t", t(e))
            end
        end
    else
        println(sub(k), "\t", t(v))
    end
end' "$1" "$2" "${3:-}"
}
# `orphaned.toml`'s values are `gc_time`, so two runs can never agree on them --
# only on the SET of paths. The usage logs are different: their times come from
# the fixture and must survive verbatim.
normalise_orphanage() { normalise_toml "$1" "$2" --no-time; }

NETWORK=1
curl -sfI --max-time 15 -o /dev/null https://pkg.julialang.org/registries || NETWORK=0

# ===========================================================================
echo "==> 0. landmarks: the fixture's derived names come from Julia"
# ===========================================================================
# Without these the whole file is a comparison of two tools over a fixture that
# means nothing — and it would pass.
read -r GOT_SLUG GOT_LIVE GOT_GONE <<<"$(jl -e '
using Pkg
print(Base.version_slug(Base.UUID(ARGS[1]), Base.SHA1(ARGS[2])), " ",
      basename(Pkg.Types.add_repo_cache_path(ARGS[3])), " ",
      basename(Pkg.Types.add_repo_cache_path(ARGS[4])))' \
  "$SA_UUID" "$SA_TREE" "$LIVE_URL" "$GONE_URL")"
check "the version slug Pkg looks for is $SA_SLUG" "$SA_SLUG" "$GOT_SLUG"
check "add_repo_cache_path(<live url>) is clones/$LIVE_CLONE" "$LIVE_CLONE" "$GOT_LIVE"
check "add_repo_cache_path(<dead url>) is clones/$GONE_CLONE" "$GONE_CLONE" "$GOT_GONE"

# ===========================================================================
echo
echo "==> 1. the synthetic diff: Pkg and Ajt collect the same depot identically"
# ===========================================================================
A="$WORK/a"; B="$WORK/b"
make_fixture "$A"; make_fixture "$B"
BEFORE=$(inventory "$A")
check "the two fixtures start identical" "$BEFORE" "$(inventory "$B")"
if [ "$(echo "$BEFORE" | wc -l)" -ge 14 ]; then
  ok "the fixture has something of every kind to lose ($(echo "$BEFORE" | wc -l | tr -d ' ') entries)"
else
  bad "the fixture has something of every kind to lose" "$(echo "$BEFORE" | tr '\n' ' ')"
fi

if ! gc_pkg "$A" "Second(0)" > "$WORK/pkg1.log" 2>&1; then
  bad "Pkg.gc(collect_delay=Second(0)) ran" "$(tail -3 "$WORK/pkg1.log" | tr '\n' '|')"
else
  ok "Pkg.gc(collect_delay=Second(0)) ran"
fi
if ! "$AJT" gc --depot "$B" --all > "$WORK/ajt1.log" 2> "$WORK/ajt1.err"; then
  bad "ajt gc --all ran" "$(tail -3 "$WORK/ajt1.err" | tr '\n' '|')"
else
  ok "ajt gc --all ran"
fi

PKG_INV=$(inventory "$A")
AJT_INV=$(inventory "$B")
if [ "$PKG_INV" = "$AJT_INV" ]; then
  ok "the surviving inventories are identical"
else
  bad "the surviving inventories are identical" \
      "$(diff <(echo "$PKG_INV") <(echo "$AJT_INV") | head -12 | tr '\n' '|')"
fi

# ...and identical to the RIGHT thing. Two tools agreeing on a wrong answer is
# exactly what a pure diff cannot see, so the expected set is spelled out.
EXPECTED=$(printf '%s\n' \
  "artifacts/$ART_PLAIN" \
  "artifacts/$ART_KEYED" \
  "clones/$LIVE_CLONE" \
  "packages/StaticArrays" \
  "packages/StaticArrays/$SA_SLUG" \
  "scratchspaces/$SA_UUID" \
  "scratchspaces/$SA_UUID/live" | LC_ALL=C sort)
check "and they are the expected survivors" "$EXPECTED" "$AJT_INV"

# The three clones cases, called out because they are the subtlest thing here.
[ -d "$B/clones/$LIVE_CLONE" ] && ok "a clone whose url is still in a live manifest SURVIVES" \
  || bad "a clone whose url is still in a live manifest SURVIVES"
[ -d "$B/clones/$GONE_CLONE" ] && bad "a clone whose url is gone is COLLECTED" \
  || ok "a clone whose url is gone is COLLECTED"
# `install_git` names its clone `clones/<uuid>` (Operations.jl:842-844), a form
# `process_manifest_repos` can never reproduce — so Pkg ALWAYS collects it.
# Reproducing that is the point; it is Pkg's behaviour, not a bug to fix here.
[ -d "$B/clones/$SA_UUID" ] && bad "a clones/<uuid> directory is ALWAYS collected (Pkg's behaviour)" \
  || ok "a clones/<uuid> directory is ALWAYS collected (Pkg's behaviour)"
[ -d "$A/clones/$SA_UUID" ] && bad "...and Pkg agrees" || ok "...and Pkg agrees"

# Pruning: an emptied `packages/<Name>` and `scratchspaces/<uuid>` go too.
[ -e "$B/packages/Dead" ] && bad "an emptied packages/<Name> is pruned" || ok "an emptied packages/<Name> is pruned"
[ -e "$B/scratchspaces/$EX_UUID" ] && bad "an emptied scratchspaces/<uuid> is pruned" \
  || ok "an emptied scratchspaces/<uuid> is pruned"

# The bookkeeping, compared through Julia's parser.
P=$(normalise_orphanage "$A/logs/orphaned.toml" "$A")
J=$(normalise_orphanage "$B/logs/orphaned.toml" "$B")
if [ "$P" = "$J" ]; then
  ok "logs/orphaned.toml agrees with Pkg's (paths; the times are two clocks)"
else
  bad "logs/orphaned.toml agrees with Pkg's" "$(diff <(echo "$P") <(echo "$J") | head -8 | tr '\n' '|')"
fi
for f in manifest_usage.toml artifact_usage.toml scratch_usage.toml; do
  P=$(normalise_toml "$A/logs/$f" "$A")
  J=$(normalise_toml "$B/logs/$f" "$B")
  if [ "$P" = "$J" ]; then
    ok "logs/$f agrees with Pkg's, timestamps included"
  else
    bad "logs/$f agrees with Pkg's" "$(diff <(echo "$P") <(echo "$J") | head -8 | tr '\n' '|')"
  fi
done
# ...and `orphaned.toml` is not vacuously equal: all seven collected paths --
# two packages, two artifacts, two clones and a scratchspace -- passed through
# it on the way out.
check "orphaned.toml recorded the paths that were collected" "7" \
  "$(normalise_orphanage "$B/logs/orphaned.toml" "$B" | wc -l | tr -d ' ')"

# gc's own count of index files, on both sides. This is the strongest evidence
# available that either tool actually READ the logs, as opposed to finding a
# depot it believed was empty — which is the state in which it deletes
# everything.
check "Pkg says it found the manifest log" "1" "$(grep -cE 'Active manifest files: 1 found' "$WORK/pkg1.log")"
check "ajt says the same" "active	manifest	1" "$(grep -m1 '^active	manifest' "$WORK/ajt1.log")"
check "Pkg says it found 1 active artifact file" "1" "$(grep -cE 'Active artifact files: 1 found' "$WORK/pkg1.log")"
check "ajt says the same" "active	artifact	1" "$(grep -m1 '^active	artifact' "$WORK/ajt1.log")"
check "Pkg says it found 1 active scratchspace" "1" "$(grep -cE 'Active scratchspaces: 1 found' "$WORK/pkg1.log")"
check "ajt says the same" "active	scratchspace	1" "$(grep -m1 '^active	scratchspace' "$WORK/ajt1.log")"

# --dry-run must produce the same plan and touch nothing.
C="$WORK/c"; make_fixture "$C"
BEFORE_C=$(inventory "$C")
"$AJT" gc --depot "$C" --all --dry-run > "$WORK/dry.log" 2>&1
check "--dry-run leaves the depot untouched" "$BEFORE_C" "$(inventory "$C")"
[ -e "$C/logs/orphaned.toml" ] && bad "--dry-run writes no orphanage" || ok "--dry-run writes no orphanage"
check "--dry-run plans exactly what the real run deleted" \
  "$(grep -c '^deleted	' "$WORK/ajt1.log")" "$(grep -c '^planned	' "$WORK/dry.log")"

# ===========================================================================
echo
echo "==> 2. the gate bites: with the logs gone, both tools empty the depot"
# ===========================================================================
# Without this the section above is worthless — a gc that deletes nothing under
# any circumstances would pass all of it.
D1="$WORK/d1"; D2="$WORK/d2"
make_fixture "$D1" --no-logs; make_fixture "$D2" --no-logs
gc_pkg "$D1" "Second(0)" > "$WORK/pkg2.log" 2>&1
"$AJT" gc --depot "$D2" --all > "$WORK/ajt2.log" 2>&1

PKG_GONE=$(inventory "$D1"); AJT_GONE=$(inventory "$D2")
check "Pkg and Ajt agree on the empty depot" "$PKG_GONE" "$AJT_GONE"
if [ -z "$AJT_GONE" ]; then
  ok "ajt gc collected everything (the gate bites)"
else
  bad "ajt gc collected everything" "still present: $(echo "$AJT_GONE" | tr '\n' ' ')"
fi
# 3 packages + 4 artifacts + 3 clones + 2 scratchspaces.
check "and it says so, with a count" "12" "$(grep -c '^deleted	' "$WORK/ajt2.log")"
check "Pkg says so too, for packages" "1" "$(grep -cE 'Deleted [0-9]+ package installation' "$WORK/pkg2.log")"

# ===========================================================================
echo
echo "==> 3. the default delay, and the marking ORDER"
# ===========================================================================
E1="$WORK/e1"; E2="$WORK/e2"
make_fixture "$E1"; make_fixture "$E2"
BEFORE_E=$(inventory "$E1")
gc_pkg "$E1" "Day(7)" > "$WORK/pkg3.log" 2>&1
"$AJT" gc --depot "$E2" > "$WORK/ajt3.log" 2>&1

# On FIRST orphaning `free_time == gc_time`, so `gc_time - free_time` is zero
# and Day(7) cannot be satisfied. Both tools must record and delete nothing.
check "Pkg.gc(Day(7)) deleted nothing" "$BEFORE_E" "$(inventory "$E1")"
check "ajt gc (default) deleted nothing" "$BEFORE_E" "$(inventory "$E2")"
check "and both wrote the same orphanage" \
  "$(normalise_orphanage "$E1/logs/orphaned.toml" "$E1")" \
  "$(normalise_orphanage "$E2/logs/orphaned.toml" "$E2")"
if [ -s "$E2/logs/orphaned.toml" ]; then
  ok "...which is not empty — the run RECORDED what it declined to delete"
else
  bad "...which is not empty" "orphaned.toml is zero bytes; nothing would ever age out"
fi

# THE ORDERING. `packages_to_delete` is preliminary and, at Day(7), EMPTY — so
# the Artifacts.toml inside the doomed package is active here (2 found) and was
# not at Second(0) (1 found, asserted in section 1). Same fixture, opposite
# answer, decided entirely by packages being marked before artifacts
# (API.jl:794-802, :933-935).
check "Pkg finds 2 active artifact files at Day(7), not 1" "1" \
  "$(grep -cE 'Active artifact files: 2 found' "$WORK/pkg3.log")"
check "ajt agrees" "active	artifact	2" "$(grep -m1 '^active	artifact' "$WORK/ajt3.log")"

# A corrupt usage log must NOT widen the delete set: Pkg throws out of gc
# without deleting anything, and so must ajt.
E3="$WORK/e3"; make_fixture "$E3"
echo 'this is not = = toml' > "$E3/logs/manifest_usage.toml"
BEFORE_E3=$(inventory "$E3")
if "$AJT" gc --depot "$E3" --all > "$WORK/corrupt.log" 2> "$WORK/corrupt.err"; then
  bad "an unreadable usage log collects NOTHING" "ajt exited 0"
elif grep -q 'NOTHING was collected' "$WORK/corrupt.err"; then
  ok "an unreadable usage log collects NOTHING, and says so"
else
  bad "an unreadable usage log collects NOTHING, and says so" "$(tail -2 "$WORK/corrupt.err" | tr '\n' '|')"
fi
check "...and the depot is untouched" "$BEFORE_E3" "$(inventory "$E3")"

# The same rule for a depot whose bookkeeping cannot be WRITTEN. Julia's bare
# `open(orphanage_file, "w")` (API.jl:1047) throws in phase 5, before
# `delete_path` is ever reached — so `Pkg.gc()` deletes nothing, and neither may
# ajt. Both sides are run, because "Pkg also refuses" is the whole claim.
E4="$WORK/e4"; make_fixture "$E4"
BEFORE_E4=$(inventory "$E4")
chmod 555 "$E4/logs"
"$AJT" gc --depot "$E4" --all > "$WORK/ro.log" 2> "$WORK/ro.err" \
  && bad "a depot with an unwritable logs/ collects NOTHING" "ajt exited 0" \
  || check "a depot with an unwritable logs/ collects NOTHING" "$BEFORE_E4" "$(inventory "$E4")"
E5="$WORK/e5"; make_fixture "$E5"
chmod 555 "$E5/logs"
gc_pkg "$E5" "Second(0)" > "$WORK/ro_pkg.log" 2>&1
# Same fixture generator, so the relative inventories are directly comparable.
check "...and Pkg refuses too, for the same reason" "$BEFORE_E4" "$(inventory "$E5")"
chmod 755 "$E4/logs" "$E5/logs"

# ===========================================================================
echo
echo "==> 3b. --force, and Pkg's own suspend_cache markers"
# ===========================================================================
# `--force` sweeps every depot instead of just depots1() (API.jl:600). Pkg has
# no REPL spelling for it, so this is the only place it is exercised against the
# oracle. Two depots, and the SECOND one's orphan is the observable.
F1="$WORK/f1"; F2="$WORK/f2"
mkdir -p "$F1/packages/One/aaaaa" "$F2/packages/Two/bbbbb"
"$AJT" gc --depot "$F1" --depot "$F2" --all > /dev/null 2>&1
[ -d "$F1/packages/One/aaaaa" ] && bad "without --force the first depot is still swept" \
  || ok "without --force the first depot is still swept"
[ -d "$F2/packages/Two/bbbbb" ] && ok "...and the second is left completely alone" \
  || bad "...and the second is left completely alone"
mkdir -p "$F1/packages/One/aaaaa"
"$AJT" gc --depot "$F1" --depot "$F2" --all --force > /dev/null 2>&1
[ -e "$F2/packages/Two" ] && bad "--force reaches the second depot" || ok "--force reaches the second depot"
# The oracle, on a fresh pair.
G1="$WORK/g1"; G2="$WORK/g2"
mkdir -p "$G1/packages/One/aaaaa" "$G2/packages/Two/bbbbb"
JULIA_DEPOT_PATH="$G1:$G2" julia --startup-file=no -e \
  'using Pkg, Dates; Pkg.gc(collect_delay = Second(0), force = true)' > "$WORK/force_pkg.log" 2>&1
[ -e "$G2/packages/Two" ] && bad "...and Pkg agrees that force reaches it" \
  || ok "...and Pkg agrees that force reaches it"

# `suspend_cache_*` / `pending_cache_*` under Pkg's OWN scratchspace uuid are
# the one non-directory gc deletes, and they age on a 24h mtime timer rather
# than through the orphanage (API.jl:1018-1026). Checked by name rather than
# through `inventory`, which excludes that uuid because the Pkg side's own
# Julia writes there.
PKGUUID="44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
H1="$WORK/h1"; H2="$WORK/h2"
for D in "$H1" "$H2"; do
  mkdir -p "$D/scratchspaces/$PKGUUID" "$D/logs"
  : > "$D/scratchspaces/$PKGUUID/suspend_cache_old"
  : > "$D/scratchspaces/$PKGUUID/suspend_cache_new"
  : > "$D/scratchspaces/$PKGUUID/not_a_cache_marker"
  touch -d '3 days ago' "$D/scratchspaces/$PKGUUID/suspend_cache_old"
done
gc_pkg "$H1" "Second(0)" > "$WORK/suspend_pkg.log" 2>&1
"$AJT" gc --depot "$H2" --all > "$WORK/suspend_ajt.log" 2>&1
for D in "$H1:Pkg" "$H2:ajt"; do
  R="${D%%:*}"; W="${D##*:}"
  [ -e "$R/scratchspaces/$PKGUUID/suspend_cache_old" ] \
    && bad "$W collects a suspend_cache marker older than 24h" \
    || ok "$W collects a suspend_cache marker older than 24h"
  [ -e "$R/scratchspaces/$PKGUUID/suspend_cache_new" ] \
    && ok "$W leaves a fresh one alone" || bad "$W leaves a fresh one alone"
  [ -e "$R/scratchspaces/$PKGUUID/not_a_cache_marker" ] \
    && ok "$W leaves a file with another name alone" \
    || bad "$W leaves a file with another name alone"
done

# ===========================================================================
if [ $NETWORK -eq 0 ] || [ ! -d "$HOST_DEPOT/registries" ]; then
  echo
  echo "############################################################"
  echo "# SKIPPING section 4: it needs the network and a General"
  echo "# registry under $HOST_DEPOT."
  echo "############################################################"
else
echo
echo "==> 4. a real install survives its own gc, and dies without its logs"
# ===========================================================================
PROJ="$WORK/proj"
mkdir -p "$PROJ"
cat > "$PROJ/Project.toml" <<'EOF'
name = "AjtGcRealProbe"
uuid = "3f2b1a0c-4d5e-4f60-8a71-9b2c3d4e5f62"
version = "0.1.0"
EOF
# Zstd_jll: small, has an artifact, pulls two ordinary packages — one install
# exercises both logs.
if ! JULIA_DEPOT_PATH="$WORK/oracle:$HOST_DEPOT" julia --startup-file=no --project="$PROJ" \
      -e 'using Pkg; Pkg.add("Zstd_jll")' > "$WORK/seed.log" 2>&1; then
  bad "seeded a real Manifest.toml" "$(tail -3 "$WORK/seed.log")"
else
  ok "seeded a real Manifest.toml"
fi

JULIA_PREFIX=$(jl -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(jl -e 'print(VERSION)')
HOST_TAGS=$("$AJT" host-platform --julia-prefix "$JULIA_PREFIX" --julia-version "$JULIA_VERSION")

REAL="$WORK/real"
mkdir -p "$REAL"
if ! "$AJT" install --depot "$REAL" --registry-depot "$HOST_DEPOT" \
      "$PROJ/Manifest.toml" > "$WORK/install.out" 2> "$WORK/install.err"; then
  bad "ajt install into a scratch depot" "$(tail -3 "$WORK/install.err")"
else
  ok "ajt install into a scratch depot"
fi
ROOTS=()
while IFS=$'\t' read -r kind _outcome _name _uuid _hash path; do
  [ "$kind" = "install" ] || continue
  [ -n "$path" ] && ROOTS+=("$path")
done < "$WORK/install.out"
if [ "${#ROOTS[@]}" -gt 0 ]; then
  "$AJT" install-artifacts --depot "$REAL" --host "$HOST_TAGS" \
    --julia-version "$JULIA_VERSION" --julia-prefix "$JULIA_PREFIX" \
    "${ROOTS[@]}" > "$WORK/arts.out" 2> "$WORK/arts.err" \
    && ok "ajt install-artifacts into the same depot" \
    || bad "ajt install-artifacts into the same depot" "$(tail -3 "$WORK/arts.err")"
else
  bad "ajt install produced package roots" "none"
fi

REAL_BEFORE=$(inventory "$REAL")
N_PKG=$(echo "$REAL_BEFORE" | grep -c '^packages/.*/')
N_ART=$(echo "$REAL_BEFORE" | grep -c '^artifacts/')
if [ "$N_PKG" -gt 0 ] && [ "$N_ART" -gt 0 ]; then
  ok "the depot has both packages ($N_PKG) and artifacts ($N_ART) to lose"
else
  bad "the depot has both packages and artifacts to lose" "packages=$N_PKG artifacts=$N_ART"
fi

GC_OK=1
"$AJT" gc --depot "$REAL" --all > "$WORK/real1.log" 2> "$WORK/real1.err" \
  || { GC_OK=0; bad "ajt gc --all ran over a real depot" "$(tail -3 "$WORK/real1.err")"; }
if [ "$REAL_BEFORE" = "$(inventory "$REAL")" ]; then
  ok "ajt gc --all deleted NOTHING — the usage logs protected it"
else
  GC_OK=0
  bad "ajt gc --all deleted NOTHING" \
      "$(diff <(echo "$REAL_BEFORE") <(inventory "$REAL") | head -6 | tr '\n' '|')"
fi
check "and it saw the manifest log" "active	manifest	1" "$(grep -m1 '^active	manifest' "$WORK/real1.log")"
if [ "$(grep -m1 '^active	artifact' "$WORK/real1.log")" != "active	artifact	0" ]; then
  ok "and the artifact log ($(grep -m1 '^active	artifact' "$WORK/real1.log" | cut -f3) files)"
else
  bad "and the artifact log" "gc saw no artifact index files at all"
fi

# The same depot, now given to `Pkg.gc()`: it must also leave it alone. This is
# what makes "ajt install writes logs Pkg respects" a measurement rather than a
# claim — and it is checked here because section 1's fixtures were hand-written.
if gc_pkg "$REAL" "Second(0)" > "$WORK/real_pkg.log" 2>&1; then
  check "Pkg.gc over the same depot also deletes nothing" "$REAL_BEFORE" "$(inventory "$REAL")"
else
  bad "Pkg.gc over the same depot ran" "$(tail -3 "$WORK/real_pkg.log" | tr '\n' '|')"
fi

# ...and now prove it can bite on real content too.
if [ "$GC_OK" -eq 0 ]; then
  bad "with the logs DELETED the same gc takes all of it" \
      "not attempted — the protected run above did not hold, so this proves nothing"
else
  rm -f "$REAL/logs/manifest_usage.toml" "$REAL/logs/artifact_usage.toml"
  "$AJT" gc --depot "$REAL" --all > "$WORK/real2.log" 2>&1
  # `artifacts/<hash>` has no trailing component — `inventory` lists it at
  # depth 1 — so a single `(packages|artifacts)/.+/` alternation would silently
  # never match an artifact, and this check would pass with every one of them
  # still on disk. That is exactly what deleting artifact_usage.toml above is
  # meant to disprove.
  LEFT=$(inventory "$REAL" | grep -E '^(packages/.+/|artifacts/)')
  if [ -z "$LEFT" ]; then
    ok "with the logs DELETED the same gc takes all of it"
  else
    bad "with the logs DELETED the same gc takes all of it" "still present: $(echo "$LEFT" | tr '\n' ' ')"
  fi
fi
fi

# ===========================================================================
echo
echo "==> 5. the user's real depot was not written"
# ===========================================================================
# Everything this harness created lives under $WORK, so a leak into ~/.julia
# shows up as a $WORK-prefixed key in its logs. A $WORK key is unambiguous
# evidence of a leak; its absence is not proof of none — it does not cover
# packages/ or artifacts/. The `jl` wrapper is the mechanism; this is the
# backstop.
LEAKED=0
for f in "$HOST_DEPOT/logs/manifest_usage.toml" "$HOST_DEPOT/logs/artifact_usage.toml" \
         "$HOST_DEPOT/logs/scratch_usage.toml" "$HOST_DEPOT/logs/orphaned.toml"; do
  [ -f "$f" ] || continue
  grep -Fq "$WORK" "$f" && LEAKED=1
done
check "no key under $WORK appears in $HOST_DEPOT/logs" "0" "$LEAKED"
check "the oracle's depots1() is a scratch depot, not $HOST_DEPOT" \
  "$WORK/oracle" "$(jl -e 'print(DEPOT_PATH[1])')"

# ---------------------------------------------------------------------------
echo
if [ $FAIL -eq 0 ]; then
  if [ $NETWORK -eq 0 ] || [ ! -d "$HOST_DEPOT/registries" ]; then
    echo "SKIP — $PASS checks passed, but section 4 (a real install) was SKIPPED" >&2
    exit 3
  fi
  echo "PASS — $PASS checks: ajt gc collects exactly what Pkg.gc collects, writes"
  echo "       the same orphanage and the same condensed logs, spares a depot ajt"
  echo "       filled — and empties it the moment the logs are gone"
  exit 0
fi
echo "FAIL — $FAIL of $((PASS+FAIL)) checks" >&2
[ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect)" >&2
exit 1
