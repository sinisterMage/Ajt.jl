#!/usr/bin/env bash
# Gate for M4 critical-path ranking (`src/sched/rank.zig`).
#
# WHY THIS GATE EXISTS
#
# Ranking is the one part of the scheduler with no observable failure. A
# resolver that gets a version wrong installs the wrong package and somebody
# notices; a ranker that gets the order wrong still builds everything, still
# builds it correctly, and is merely slower than it should be -- by a margin
# (1.05-1.15x on a wide box, under 5% on the 2-CPU engine node) that is inside
# the run-to-run noise of a real build. Nobody will ever report this broken.
# So it has to be pinned by construction instead: DAGs whose optimal order is
# forced by their shape, checked against the exact printed order.
#
# There is no Julia oracle for a scheduling heuristic -- Pkg has no list
# scheduler to differ from. The hand-built DAGs below ARE the oracle, and each
# is built so its answer is forced rather than merely plausible.
#
# The four sections:
#
#   1. Hand-built DAGs -- a long thin chain, a wide shallow fan, the two in one
#      graph, a diamond, and a chain with a heavy leaf. Exact order asserted.
#   2. The REAL 214-entry Open-Reality/Manifest.toml. Prints the top 10 and the
#      critical path for eyeball review; asserts the structure that makes the
#      list believable (deep, JLL-heavy, ending at the environment's own root
#      package) rather than only that it ran.
#   3. `<depot>/ajt/costs.toml` round-trip: write measured times, read them
#      back, and assert the ranking MOVES in the direction the new costs imply.
#      A cost model that is written and never consulted would pass every other
#      check here.
#   4. Graceful degradation: missing file, unknown package, malformed TOML,
#      unknown schema. A scheduler that refuses to start because a cache of
#      timings is corrupt would be a worse tool than one that guesses.
#
# Sections 1, 3 and 4 need nothing but `zig`. Section 2 needs the engine
# manifest and SKIPS loudly (exit 0) without it.
#
# Usage: tools/diff_harness/sched_rank.sh [--keep] [--manifest FILE]
set -uo pipefail

export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"

KEEP=0
MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --manifest)
      [ $# -ge 2 ] || { echo "--manifest needs a path" >&2; exit 2; }
      MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v zig >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-schedrank-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

# The cache dirs are per-run and inside $WORK on purpose -- see the long note
# in stdlibs.sh. Two checkouts of this repo (the main one and any
# .claude/worktrees/ agent tree) invoke `zig run` with identical -M strings,
# and a hermetic cache removes any chance of one executing the other's binary.
dump() {
  ( cd "$AJT_ROOT" && zig run \
      --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
      --dep ajt -Mroot=tools/diff_harness/sched_rank_dump.zig -Majt=src/root.zig \
      -- "$@" ) 2>"$WORK/dump.err"
}

echo "==> building the fixture"
if ! dump dag /dev/null >/dev/null; then
  echo "ERROR: sched_rank_dump would not build/run" >&2
  tail -30 "$WORK/dump.err" >&2
  exit 2
fi

# --- helpers ---------------------------------------------------------------
# `expect_order <label> <dagfile> <expected>` -- runs the fixture and compares
# the whole `order` line. Extra args after the expected string are passed to
# the fixture (e.g. --depot).
expect_order() {
  local label="$1" dag="$2" want="$3"; shift 3
  local got
  got="$(dump dag "$dag" "$@" | sed -n 's/^order //p')"
  if [ "$got" = "$want" ]; then
    ok "$label"
  else
    bad "$label" "want: $want"
    printf '       got : %s\n' "$got"
    [ -s "$WORK/dump.err" ] && head -5 "$WORK/dump.err" | sed 's/^/       /'
  fi
}

expect_line() {
  local label="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then ok "$label"; else
    bad "$label" "no line matching /$pattern/"
    head -20 "$file" | sed 's/^/       /'
  fi
}

# ===========================================================================
echo
echo "==> 1. hand-built DAGs (the order is forced by construction)"

# A long thin chain. Only one topological order exists at all, so any ranking
# that produces a different order is not merely suboptimal, it is wrong.
cat > "$WORK/chain.dag" <<'EOF'
edge a b
edge b c
edge c d
edge d e
EOF
expect_order "long thin chain runs head to tail" "$WORK/chain.dag" "a b c d e"

# A wide shallow fan. The hub gates everything and must go first; the leaves
# are indistinguishable in rank, downstream weight and out-degree, so ONLY the
# index tie-break can separate them -- which is what pins determinism.
cat > "$WORK/fan.dag" <<'EOF'
edge hub l1
edge hub l2
edge hub l3
edge hub l4
edge hub l5
EOF
expect_order "wide shallow fan runs the hub then the leaves in order" \
  "$WORK/fan.dag" "hub l1 l2 l3 l4 l5"

# Both at once, disjoint. The fan carries four times the total work and still
# loses the first slot: starting it cannot shorten the chain, and the chain is
# what the makespan is made of. A most-work-first heuristic gets this exactly
# backwards, which is the failure this case exists to catch. The chain's own
# tail (c4, b-level 2) then ties the hub and yields to it on downstream
# weight -- the tie-break doing its job once the critical path is no longer at
# stake.
cat > "$WORK/both.dag" <<'EOF'
edge c1 c2
edge c2 c3
edge c3 c4
edge c4 c5
edge hub f1
edge hub f2
edge hub f3
edge hub f4
edge hub f5
edge hub f6
edge hub f7
edge hub f8
EOF
expect_order "a thin chain outranks a fan carrying 4x the work" \
  "$WORK/both.dag" "c1 c2 c3 hub c4 c5 f1 f2 f3 f4 f5 f6 f7 f8"

# A diamond with one heavy middle. The fork is the only source and the join the
# only sink, so only the middles are in question, and 50 vs 5 decides them.
cat > "$WORK/diamond.dag" <<'EOF'
cost fork 10
cost heavy 50
cost light 5
cost join 10
edge fork heavy
edge fork light
edge heavy join
edge light join
EOF
expect_order "a diamond runs fork, heavy middle, light middle, join" \
  "$WORK/diamond.dag" "fork heavy light join"

# Chain with a heavy leaf. Same graph, two cost models, opposite answers:
# uniform costs make the 3-node chain the critical path, the measured 100ms
# leaf makes the leaf the critical path. Anything that does not move here is
# ignoring its cost input.
#
# Read the uniform answer carefully -- `heavy` lands FOURTH, not last. Under
# uniform costs `heavy` and `k3` are both sinks costing the same, so they tie
# on rank, on downstream weight and on out-degree, and the index tie-break
# (declaration order, and `heavy` is named on the first line) separates them.
# They are genuinely interchangeable there; what the case pins is that the
# chain HEAD outranks the leaf, and that the whole thing inverts below.
cat > "$WORK/heavy.dag" <<'EOF'
edge root heavy
edge root k1
edge k1 k2
edge k2 k3
EOF
expect_order "uniform costs prefer the longer chain" \
  "$WORK/heavy.dag" "root k1 k2 heavy k3"
cat > "$WORK/heavy_cost.dag" <<'EOF'
cost root 1
cost heavy 100
cost k1 1
cost k2 1
cost k3 1
edge root heavy
edge root k1
edge k1 k2
edge k2 k3
EOF
expect_order "a heavy leaf takes the first slot once its cost is known" \
  "$WORK/heavy_cost.dag" "root heavy k1 k2 k3"

# The property every one of the above rests on. ONE assertion, not two:
# `topo_ok 1` already entails `head_indegree 0` (a predecessor of `order[0]`
# would need a position below 0), so checking them on separate lines would
# inflate the count without testing anything more.
dump dag "$WORK/both.dag" > "$WORK/both.out"
expect_line "the order is topological and its head is a source" \
  "$WORK/both.out" '^topo_ok 1 head_indegree 0$'

# ===========================================================================
echo
echo "==> 2. the real environment ($MANIFEST)"

SKIPPED_REAL=0
if [ ! -f "$MANIFEST" ]; then
  SKIPPED_REAL=1
  echo
  echo "########################################################################"
  echo "# SKIPPED section 2: no manifest at                                     "
  echo "#   $MANIFEST"
  echo "# Pass --manifest FILE to point at a real Julia Manifest.toml. The       #"
  echo "# hand-built DAGs above prove the algorithm; only a real dependency      #"
  echo "# graph shows whether the plan it produces is believable. Sections 3     #"
  echo "# and 4 need no manifest and still run below.                            #"
  echo "########################################################################"
elif ! dump manifest "$MANIFEST" --top 10 > "$WORK/manifest.out"; then
  bad "ranking the real manifest" "$(head -3 "$WORK/dump.err")"
else
  NODES=$(awk '$1=="nodes" {print $2}' "$WORK/manifest.out")
  EDGES=$(awk '$1=="nodes" {print $4}' "$WORK/manifest.out")
  DANGLING=$(awk '$1=="nodes" {print $6}' "$WORK/manifest.out")
  echo "  $NODES packages, $EDGES dependency edges, $DANGLING deps not in the manifest"
  echo
  echo "  top 10 by critical path (rank / downstream-ms / out-degree):"
  awk '$1=="top" {printf "    %2d. %-34s %7d %8d %4d\n", $2, $3, $4, $5, $6}' "$WORK/manifest.out"
  echo
  echo "  the critical path itself:"
  sed -n 's/^path //p' "$WORK/manifest.out" | tr ' ' '\n' | awk '{printf "    %2d. %s\n", NR, $0}'
  echo

  [ "$NODES" -ge 50 ] && ok "manifest has $NODES nodes" \
    || bad "manifest has only $NODES nodes" "too small to say anything about a real graph"
  # A dep whose UUID is not an entry in the same manifest means the graph is
  # incomplete and every rank below it is an underestimate.
  [ "$DANGLING" -eq 0 ] && ok "every dependency resolves to a manifest entry" \
    || bad "$DANGLING dependencies point outside the manifest"

  expect_line "the real graph's order is topological and its head is a source" \
    "$WORK/manifest.out" '^topo_ok 1 head_indegree 0$'

  # Does the answer LOOK like a dependency graph's critical path? A Julia
  # environment's longest chain runs up a tower of binary JLLs -- Xorg on top
  # of Cairo on top of Pango and so on -- and terminates at the environment's
  # own top-level package. If it ever stops looking like that, the most likely
  # cause is the edges being ranked backwards, which is otherwise invisible.
  PATH_LEN=$(sed -n 's/^path //p' "$WORK/manifest.out" | wc -w)
  JLLS=$(sed -n 's/^path //p' "$WORK/manifest.out" | tr ' ' '\n' | grep -c '_jll$')
  PATH_TAIL=$(sed -n 's/^path //p' "$WORK/manifest.out" | awk '{print $NF}')
  PATH_HEAD=$(sed -n 's/^path //p' "$WORK/manifest.out" | awk '{print $1}')

  [ "$PATH_LEN" -ge 8 ] && ok "the critical path is $PATH_LEN packages deep" \
    || bad "the critical path is only $PATH_LEN packages deep" \
           "a real environment's longest chain is not this short -- edges reversed?"
  [ "$JLLS" -ge 3 ] && ok "$JLLS of $PATH_LEN packages on the path are _jll binaries" \
    || bad "only $JLLS of $PATH_LEN packages on the path are _jll binaries" \
           "the deep chains in a Julia environment ARE the JLL towers; this does not look like one"

  # The head must be a leaf dependency and the tail the thing everything is
  # for. If those two swap, the adjacency was passed dependency-wards instead
  # of dependent-wards and every number in this file is backwards.
  case "$PATH_HEAD" in
    # An empty head means no `path` line was printed at all. Without this arm
    # it would fall through to `*)` and report a vacuous pass.
    "")    bad "no critical path was printed" "the fixture produced no 'path' line" ;;
    *_jll) bad "the path STARTS at $PATH_HEAD" "a JLL binary at the head suggests reversed edges" ;;
    *)     ok "the path starts at a leaf dependency ($PATH_HEAD)" ;;
  esac
  ROOT_NAME="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$(dirname "$MANIFEST")/Project.toml" 2>/dev/null | head -1)"
  if [ -n "$ROOT_NAME" ]; then
    [ "$PATH_TAIL" = "$ROOT_NAME" ] && ok "the path ends at the environment's own package ($ROOT_NAME)" \
      || bad "the path ends at $PATH_TAIL, not the environment's package ($ROOT_NAME)" \
             "the last thing to build should be the thing being built"
  else
    echo "  note no Project.toml beside the manifest; skipping the path-tail check"
  fi
fi

# ===========================================================================
echo
echo "==> 3. the cost model round-trips through <depot>/ajt/costs.toml"

DEPOT="$WORK/depot"
mkdir -p "$DEPOT"

# The heavy-leaf graph again, this time with costs coming from the depot rather
# than from the fixture file -- so what is under test is the FILE, not the
# arithmetic (section 1 already pinned that).
cat > "$WORK/model.dag" <<'EOF'
edge root heavy
edge root k1
edge k1 k2
edge k2 k3
EOF

expect_order "a cold depot ranks by graph depth alone" \
  "$WORK/model.dag" "root k1 k2 heavy k3" --depot "$DEPOT"

dump record "$DEPOT" root=1 heavy=100000 k1=500 k2=500 k3=500 > "$WORK/record.out" \
  || bad "recording measurements" "$(head -3 "$WORK/dump.err")"
expect_line "the run's measurements were written" "$WORK/record.out" '^written 1 entries 5$'

[ -f "$DEPOT/ajt/costs.toml" ] && ok "costs.toml landed at <depot>/ajt/costs.toml" \
  || bad "no file at $DEPOT/ajt/costs.toml"
echo "  --- $DEPOT/ajt/costs.toml ---"
sed 's/^/    /' "$DEPOT/ajt/costs.toml"

expect_order "the next plan reads them back and puts the heavy branch first" \
  "$WORK/model.dag" "root heavy k1 k2 k3" --depot "$DEPOT"

dump costs "$DEPOT" heavy k1 > "$WORK/costs.out"
expect_line "heavy is remembered as 100000ms" "$WORK/costs.out" '^estimate heavy 100000$'
expect_line "the model is reported healthy" "$WORK/costs.out" '^health present=1 parse_failed=0 schema_mismatch=0 shape_wrong=0 dropped=0 clamped=0 entries=5$'

# A second run blends rather than replacing: one anomalous measurement must not
# be able to pin the estimate for good.
dump record "$DEPOT" heavy=0 >/dev/null
dump costs "$DEPOT" heavy > "$WORK/costs2.out"
expect_line "a second measurement halves the error rather than replacing it" \
  "$WORK/costs2.out" '^estimate heavy 50000$'
expect_order "and the plan is still steered by it" \
  "$WORK/model.dag" "root heavy k1 k2 k3" --depot "$DEPOT"

# Keys are opaque to the model, so a caller is free to key on `Name@version`
# to let versions age separately -- and that needs TOML quoting. The unit
# tests pin the escaping itself; this pins that it survives a real file on
# disk, which is where a key that re-parses differently would silently grow a
# second entry on every run.
dump record "$DEPOT" "Weird Name@1.2=77" >/dev/null
dump costs "$DEPOT" "Weird Name@1.2" > "$WORK/quoted.out"
expect_line "a key needing TOML quoting round-trips through the real file" \
  "$WORK/quoted.out" '^estimate Weird Name@1\.2 77$'
if grep -q '^"Weird Name@1.2" = 77$' "$DEPOT/ajt/costs.toml"; then
  ok "and is quoted on disk rather than written as a bare key"
else
  bad "the key was not quoted on disk" "$(grep -c . "$DEPOT/ajt/costs.toml") lines in the file"
fi
# Recording it twice must not produce two differently-spelled entries.
dump record "$DEPOT" "Weird Name@1.2=77" >/dev/null
COUNT=$(grep -c 'Weird Name' "$DEPOT/ajt/costs.toml")
[ "$COUNT" -eq 1 ] && ok "a second write leaves exactly one entry for it" \
  || bad "the quoted key appears $COUNT times after a second write"

# ===========================================================================
echo
echo "==> 4. graceful degradation (a corrupt timing cache must never stop a build)"

# 4a. Missing file -- already covered by the cold-depot case above, but assert
#     the health flags say "first run" rather than "broken".
EMPTY="$WORK/empty-depot"
mkdir -p "$EMPTY"
dump costs "$EMPTY" Anything > "$WORK/missing.out"
expect_line "an absent costs.toml is 'first run', not an error" \
  "$WORK/missing.out" '^health present=0 parse_failed=0 schema_mismatch=0 shape_wrong=0 dropped=0 clamped=0 entries=0$'
expect_line "an absent model still answers with the default estimate" \
  "$WORK/missing.out" '^estimate Anything 1000$'

# 4b. Unknown package in an otherwise good file.
dump costs "$DEPOT" NeverBuiltHere > "$WORK/unknown.out"
expect_line "a package with no recorded time gets the default" \
  "$WORK/unknown.out" '^estimate NeverBuiltHere 1000$'
expect_line "and is reported as unknown rather than as a zero" \
  "$WORK/unknown.out" '^known NeverBuiltHere 0$'

# 4c. Malformed TOML.
BROKEN="$WORK/broken-depot"
mkdir -p "$BROKEN/ajt"
printf '[times\nheavy = \n' > "$BROKEN/ajt/costs.toml"
dump costs "$BROKEN" heavy > "$WORK/broken.out" \
  || bad "a malformed costs.toml made the fixture exit non-zero" "it must degrade, not fail"
expect_line "malformed TOML is reported, not thrown" "$WORK/broken.out" '^health present=1 parse_failed=1 '
expect_line "malformed TOML still yields a usable estimate" "$WORK/broken.out" '^estimate heavy 1000$'
expect_line "and says so in a line a human can read" \
  "$WORK/broken.out" '^note ajt: .*/ajt/costs\.toml is not valid TOML; ignoring it'
expect_order "a build still gets a plan out of a corrupt timing cache" \
  "$WORK/model.dag" "root k1 k2 heavy k3" --depot "$BROKEN"

# The next write must repair it rather than inherit the corruption.
dump record "$BROKEN" heavy=7 >/dev/null
dump costs "$BROKEN" heavy > "$WORK/repaired.out"
expect_line "the next run replaces the corrupt file" "$WORK/repaired.out" '^estimate heavy 7$'

# 4d. A schema this build does not know: inert, never reinterpreted.
FUTURE="$WORK/future-depot"
mkdir -p "$FUTURE/ajt"
printf 'schema = 99\n\n[times]\nheavy = 12345\n' > "$FUTURE/ajt/costs.toml"
dump costs "$FUTURE" heavy > "$WORK/future.out"
expect_line "an unknown schema makes the file inert" "$WORK/future.out" '^health present=1 parse_failed=0 schema_mismatch=1 '
expect_line "an unknown schema does not leak its numbers" "$WORK/future.out" '^estimate heavy 1000$'

# 4e. Individually unusable values are dropped; their neighbours survive.
MIXED="$WORK/mixed-depot"
mkdir -p "$MIXED/ajt"
printf 'schema = 1\n\n[times]\ngood = 10\nnegative = -5\nstringy = "slow"\n' > "$MIXED/ajt/costs.toml"
dump costs "$MIXED" good negative > "$WORK/mixed.out"
expect_line "a usable entry beside two broken ones survives" "$WORK/mixed.out" '^estimate good 10$'
expect_line "the broken ones are dropped, not guessed at" "$WORK/mixed.out" '^estimate negative 1000$'
expect_line "and the drop count is reported" "$WORK/mixed.out" '^health present=1 parse_failed=0 schema_mismatch=0 shape_wrong=0 dropped=2 clamped=0 entries=1$'

# ===========================================================================
echo
echo "  passed : $PASS"
echo "  failed : $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "FAIL — critical-path ranking does not do what it says" >&2
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect $WORK)" >&2
  exit 1
fi
if [ "$SKIPPED_REAL" -eq 1 ]; then
  echo
  echo "SKIP — $PASS checks passed, but section 2 (the real 214-package graph)"
  echo "was SKIPPED. The hand-built DAGs prove the arithmetic; only a real"
  echo "dependency graph shows the plan is believable."
  exit 0
fi
echo
echo "PASS — $PASS checks. Ranking is worth 1.05-1.15x on a wide box and under"
echo "5% on the 2-CPU engine node; phase fusion and the shared precompile cache"
echo "are the levers that matter. This gate only says the cheap part is correct."
