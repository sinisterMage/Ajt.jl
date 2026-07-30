#!/usr/bin/env bash
# Gate for the M4 stage graph (`src/sched/graph.zig`).
#
# The scheduler's bugs do not look like bugs. A `requires` edge written as
# `after` does not crash -- it lets a package precompile against a dependency
# that failed to download, and the error surfaces inside a forked Julia,
# attributed to the wrong package. An `after` edge written as `requires` does
# not crash either -- it makes a cache probe against a store that happens to be
# down abort an install that would otherwise have succeeded. A missing
# cancellation leaks a running process. A cycle does not fail at all: it HANGS,
# with every node waiting on another node's `unmet` to reach zero and no worker
# to blame. None of that produces a stack trace, so it has to be asserted.
#
# Four things are checked, and they are the four claims the graph makes:
#
#   1. THE REAL ENVIRONMENT. Build the graph for Open-Reality's committed
#      214-entry Manifest.toml -- the same environment `instantiate` and
#      `resolve` are gated on -- assert it is acyclic, and re-derive its node
#      and edge totals from the package records by arithmetic. The re-derivation
#      is the check: it is a second, differently-shaped computation of the same
#      number, so a builder that emits one edge too many per package fails rather
#      than being ratified by a constant somebody copied out of a passing run.
#      Then drive the whole graph to completion and require that nothing is left
#      pending -- a 1,744-node graph is where a leaked `unmet` counter shows up
#      and a 10-node unit test is not.
#
#   2. THE REFUSAL. Close one real dependency pair back on itself and require
#      that `build` REFUSES -- no graph at all -- and prints the cycle path.
#      Deliberately stricter than Base, which warns and skips
#      (`base/precompilation.jl:770-784`, `:1148-1150`).
#
#   3. `requires` vs `after`, concretely. A failed `requires` predecessor
#      cascades BLOCKED transitively (two hops, not one); a failed `after`
#      predecessor blocks nothing at all.
#
#   4. THE `any` RULE. `Ready` settles when EITHER alternative succeeds, the
#      loser is cancelled, and `Ready` is only blocked once every alternative
#      is gone.
#
# 3 and 4 are asserted per node rather than on a summary, because "requires
# cascades and after does not" is a statement about individual nodes and a
# count can be right for the wrong reason.
#
# No network, no depot writes, no Julia process. `julia` is used only to locate
# a prefix so real artifacts can be enumerated from the local depot; without it
# the run still gates everything except the artifact node count, and says so.
#
# Usage: sched_graph.sh [--keep] [--manifest PATH]
set -uo pipefail

# Julia sorts strings by byte; so does every number this script compares. A
# UTF-8 locale changes neither, but every other harness here pins it and a
# divergence between them is one more thing to explain.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"

KEEP=0
MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v zig >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-schedgraph-XXXXXX)"
cleanup() { [ $KEEP -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

# Every zig-invoking harness here pins both cache directories into the workdir.
# See the audit note in stdlibs.sh: the collision it guards against was never
# reproduced deliberately, but it did produce one false PASS on a mutated
# source, and a hermetic cache costs seconds.
dump() {
  ( cd "$AJT_ROOT" && zig run \
      --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
      --dep ajt -Mroot=tools/diff_harness/sched_graph_dump.zig -Majt=src/root.zig \
      -- "$@" )
}

# `key` -> value, from a `key value` stream.
val() { awk -v k="$2" '$1==k {print $2; exit}' "$1"; }

want() { # want <file> <exact line> <label>
  if grep -qxF "$2" "$1"; then ok "$3"; else bad "$3" "expected line: $2"; fi
}

eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1" "expected $2, got $3"; fi
}

echo "==> compiling the harness fixture"
if ! dump scenarios > "$WORK/scen.txt" 2> "$WORK/scen.err"; then
  echo "ERROR: sched_graph_dump failed to build or run" >&2
  tail -30 "$WORK/scen.err" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 3. requires vs after
# ---------------------------------------------------------------------------
echo
echo "==> requires: failure cascades, transitively"
S="$WORK/scen.txt"
want "$S" "requires Fetch(Base) failed"        "the failure itself"
want "$S" "requires Verify(Base) skipped"      "1 edge downstream"
want "$S" "requires Install(Base) skipped"     "2 edges downstream"
want "$S" "requires Compile(Base) skipped"     "through Install"
want "$S" "requires VerifyCache(Base) skipped" "the other arm dies too"
want "$S" "requires Ready(Base) skipped"       "both alternatives gone"
want "$S" "requires Compile(Mid) skipped"      "across a dependency edge"
want "$S" "requires Ready(Mid) skipped"        "and on to its Ready"
want "$S" "requires Compile(Top) skipped"      "TRANSITIVE: two dependency hops"
want "$S" "requires Ready(Top) skipped"        "transitive, at the far end"
# ...and work with no failed predecessor is untouched. A cascade that took the
# whole graph with it would satisfy every assertion above.
want "$S" "requires Install(Mid) succeeded"    "unrelated download still ran"
want "$S" "requires Install(Top) succeeded"    "unrelated download still ran"

echo
echo "==> after: failure propagates to nothing"
want "$S" "after Probe(Foo) failed"      "a probe that could not reach the store"
want "$S" "after Import(Foo) succeeded"  "its after-successor ran anyway"
want "$S" "after Publish(Foo) failed"    "and the store stayed down"
want "$S" "after Ready(Foo) succeeded"   "which cost the package nothing"
if grep -q '^after .* skipped$' "$S"; then
  bad "no node is blocked by an after edge" "$(grep -m3 '^after .* skipped$' "$S")"
else
  ok "no node is blocked by an after edge"
fi

# The third `after` population. It gets its own fixture because the real depot
# enumerates ZERO lazy artifacts, so without this the lazy branch of both the
# builder and this gate's own arithmetic would be untested.
want "$S" "lazy-art InstallArt(09090909) failed" "a lazy artifact that did not install"
want "$S" "lazy-art Compile(Jll) succeeded"      "the JLL compiled anyway"
want "$S" "lazy-art Ready(Jll) succeeded"        "and is ready"
want "$S" "lazy-art InstallArt(08080808) succeeded" "while the eager one is a real prerequisite"

# ---------------------------------------------------------------------------
# 4. the any rule
# ---------------------------------------------------------------------------
echo
echo "==> any: either alternative satisfies Ready"
want "$S" "any-import VerifyCache(Foo) succeeded" "cache hit: the import arm wins"
want "$S" "any-import Ready(Foo) succeeded"       "Ready satisfied without compiling"
want "$S" "any-import Compile(Foo) cancelled"     "the loser is cancelled"
want "$S" "any-import Publish(Foo) cancelled"     "and so is the rest of its arm"

want "$S" "any-compile Import(Foo) failed"        "cache miss"
want "$S" "any-compile VerifyCache(Foo) skipped"  "the import arm dies"
want "$S" "any-compile Compile(Foo) succeeded"    "the compile arm carries it"
want "$S" "any-compile Ready(Foo) succeeded"      "Ready satisfied by the other one"

want "$S" "any-dead Import(Foo) failed"           "both alternatives fail:"
want "$S" "any-dead Compile(Foo) failed"          "  ...the second one too"
want "$S" "any-dead Ready(Foo) skipped"           "only NOW is Ready blocked"
want "$S" "any-dead Compile(User) skipped"        "and the dependent goes with it"
want "$S" "any-dead Ready(User) skipped"          "transitively"

# ---------------------------------------------------------------------------
# 1. the real environment
# ---------------------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: the manifest below is not there, so the real-environment     #"
  echo "# half of this gate cannot run. The edge-semantics assertions above use #"
  echo "# hand-built fixtures and DID run; what is missing is the 214-entry     #"
  echo "# node/edge count and the cycle refusal on a real graph. Point at       #"
  echo "# another environment with --manifest PATH.                            #"
  echo "########################################################################"
  echo "  $MANIFEST"
  echo
  echo "  passed: $PASS   failed: $FAIL   (partial run)"
  [ $FAIL -eq 0 ] || exit 1
  exit 0
fi

# `julia` only supplies a prefix so the local depot's artifacts can be read.
# Without it the graph is built with zero artifacts, which is a weaker run and
# not a failing one -- the header line says which happened.
PREFIX_ARG=()
if command -v julia >/dev/null; then
  PREFIX_ARG=(--julia-prefix "$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')")
fi

echo
echo "==> the real environment: $MANIFEST"
if ! dump manifest "$MANIFEST" "${PREFIX_ARG[@]}" > "$WORK/real.txt" 2> "$WORK/real.err"; then
  echo "ERROR: sched_graph_dump manifest failed" >&2
  tail -30 "$WORK/real.err" >&2
  exit 2
fi
R="$WORK/real.txt"
sed 's/^/  | /' "$R"

ART_SRC=$(val "$R" artifact_source)
[ "$ART_SRC" = "none" ] && echo "  NOTE: no depot artifacts were enumerated; artifact nodes are 0 in this run."

E=$(val "$R" entries)
F=$(val "$R" fetchable)
C=$(val "$R" cacheable)
A=$(val "$R" artifacts)
N=$(val "$R" nodes)
ED=$(val "$R" edges)
REQ=$(val "$R" requires)
AFT=$(val "$R" after)
DA=$(val "$R" dep_attachments)
AA=$(val "$R" art_attachments)
LA=$(val "$R" lazy_attachments)
CH=$(val "$R" compile_heads)
RH=$(val "$R" ready_heads)
RO=$(val "$R" resolve_out)

# The manifest's own numbers, read WITHOUT Ajt's TOML parser -- if the model
# and grep disagree about how many packages there are, the graph is being built
# over something other than this file.
GREP_E=$(grep -c '^\[\[deps\.' "$MANIFEST")
GREP_F=$(grep -c '^git-tree-sha1 = ' "$MANIFEST")
eq "manifest entries (vs grep)"  "$GREP_E" "$E"
eq "tree-hash entries (vs grep)" "$GREP_F" "$F"
echo "  ..the committed Open-Reality manifest is 214 entries / 170 tree hashes."

# P = cacheable-but-not-downloadable (the project's own `path = \".\"` entry).
# S = sysimage stdlibs: no tree hash, no path, nothing to build or cache.
P=$((C - F))
SL=$((E - C))
echo "  breakdown: $F downloadable, $P path, $SL sysimage stdlib, $A artifacts"

# --- node total, re-derived -------------------------------------------------
# Downloadable+cacheable: Fetch Verify Install Probe Import VerifyCache Publish
#                         Compile Ready                             = 9
# Path+cacheable:         (no fetch chain)                          = 6
# Sysimage stdlib:        Ready alone                               = 1
# Artifact:               FetchArt InstallArt                       = 2
# ...plus the single Resolve root.
EXP_N=$((1 + 9*F + 6*P + SL + 2*A))
eq "node total (re-derived)" "$EXP_N" "$N"

# --- Resolve's out-degree, re-derived ---------------------------------------
# Pass 3 hangs every node with no `requires` in-edge off Resolve. Those are
# exactly: every Fetch, every Probe, every Import (its only other in-edge is
# `after` from Probe), every Publish (likewise, from Compile), every FetchArt,
# plus whatever Compile/Ready nodes have no prerequisite of their own.
EXP_RO=$((F + 3*C + A + CH + RH))
eq "Resolve out-degree (re-derived)" "$EXP_RO" "$RO"

# --- edge total, re-derived -------------------------------------------------
# Per downloadable package: Fetch->Verify, Verify->Install,
#   Probe->Import, Import->VerifyCache, Compile->Publish,
#   Install->{Compile,VerifyCache}, {Compile,VerifyCache}->Ready       = 9
# Per path package: the same minus the two fetch-chain edges              = 5
# Per sysimage stdlib: none of its own.
# Then the dependency and artifact attachments (each prerequisite attaches to
# EVERY arm tip, which is why these are attachment counts and not edge counts),
# one FetchArt->InstallArt per artifact, and the Resolve fan-out.
EXP_ED=$((9*F + 5*P + DA + AA + A + RO))
eq "edge total (re-derived)" "$EXP_ED" "$ED"

# (`edges == requires + after` is deliberately NOT asserted: `EdgeKind` has two
# variants and `edgeCountByKind` walks every edge, so it holds unconditionally
# and could never fail. The two halves are pinned individually instead.)

# `after` is a small, fully enumerable population: one Probe->Import and one
# Compile->Publish per cacheable package, plus every lazy artifact attachment.
# Anything else classified `after` is a failure that would not propagate.
EXP_AFT=$((2*C + LA))
eq "after-edge total (re-derived)" "$EXP_AFT" "$AFT"

# --- stage populations ------------------------------------------------------
eq "Ready nodes = manifest entries" "$E" "$(awk '$1=="stage" && $2=="Ready" {print $3}' "$R")"
eq "Fetch nodes = tree-hash entries" "$F" "$(awk '$1=="stage" && $2=="Fetch" {print $3}' "$R")"
eq "FetchArt = artifacts"   "$A" "$(awk '$1=="stage" && $2=="FetchArt" {print $3}' "$R")"
eq "InstallArt = artifacts" "$A" "$(awk '$1=="stage" && $2=="InstallArt" {print $3}' "$R")"
eq "any-nodes = cacheable packages" "$C" "$(val "$R" any_nodes)"
want "$R" "acyclic yes" "the real environment is acyclic"
eq "no dangling dependency UUIDs" "0" "$(val "$R" dangling_deps)"

# --- the whole graph drives to completion -----------------------------------
eq "every node settles"            "$N" "$(val "$R" settled)"
eq "nothing is left pending/ready/running" "0" "$(val "$R" stuck)"
eq "nothing failed on an all-success run"  "0" "$(val "$R" failed)"
eq "nothing was skipped either"            "0" "$(val "$R" skipped)"
CANC=$(val "$R" cancelled)
if [ "$CANC" -ge "$C" ]; then
  ok "every any-node cancelled a losing arm ($CANC nodes)"
else
  bad "losing arms cancelled" "expected at least $C, got $CANC"
fi

echo
echo "  REPORTED: $N nodes / $ED edges ($REQ requires, $AFT after) over $E entries + $A artifacts."
echo "  The plan estimated ~1,570 nodes / ~4,000 edges. The node estimate matches"
echo "  this graph WITHOUT artifact nodes ($((N - 2*A))); the edge estimate matches it WITH"
echo "  them. Both are within 2%, and the difference is accounted for, not tuned:"
echo "  FetchArt/InstallArt are 2 nodes per DEDUPLICATED tree hash, and the plan's"
echo "  node figure did not carry them."

# ---------------------------------------------------------------------------
# 2. the refusal
# ---------------------------------------------------------------------------
echo
echo "==> a cycle is refused, on the same real graph"
if ! dump manifest "$MANIFEST" "${PREFIX_ARG[@]}" --inject-cycle > "$WORK/cyc.txt" 2> "$WORK/cyc.err"; then
  echo "ERROR: sched_graph_dump --inject-cycle failed" >&2
  tail -30 "$WORK/cyc.err" >&2
  exit 2
fi
sed 's/^/  | /' "$WORK/cyc.txt"

want "$WORK/cyc.txt" "acyclic no"       "the scan found it"
want "$WORK/cyc.txt" "refused Cyclic"   "build refused"
want "$WORK/cyc.txt" "cycle_closed yes" "the reported path closes on itself"
if grep -q '^injected ' "$WORK/cyc.txt"; then
  ok "the back-edge was injected into a real dependency pair"
else
  bad "the back-edge was injected into a real dependency pair"
fi
# The refusal is structural: no Graph value is produced at all, so none of the
# reporting that follows a successful build appears.
if grep -q '^nodes ' "$WORK/cyc.txt"; then
  bad "no graph is returned for a cyclic input" "a 'nodes' line was printed anyway"
else
  ok "no graph is returned for a cyclic input"
fi
CYC_LINE=$(grep -m1 '^cycle ' "$WORK/cyc.txt" || true)
if printf '%s' "$CYC_LINE" | grep -q ' -> '; then
  ok "the cycle PATH is printed, not just the fact of one"
else
  bad "the cycle path is printed" "got: $CYC_LINE"
fi
CYC_LEN=$(val "$WORK/cyc.txt" cycle_len)
if [ "${CYC_LEN:-0}" -ge 3 ]; then
  ok "the path names $CYC_LEN nodes"
else
  bad "the path names at least three nodes" "cycle_len=$CYC_LEN"
fi

echo
echo "  passed: $PASS   failed: $FAIL"
[ $FAIL -eq 0 ] || exit 1
exit 0
