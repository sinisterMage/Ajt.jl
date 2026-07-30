#!/usr/bin/env bash
# Differential gate for `ajt instantiate --frozen` (src/ops/instantiate.zig).
#
# The headline claim, and the reason this file exists: **a full instantiate of a
# real Julia environment into an empty depot, with Pkg never invoked** —
# registry, every package tarball, every artifact, the fixups pass — after which
# stock Julia agrees there is nothing left to do and can load the package. The
# counts are oracled from the fixture at run time rather than written down here:
# `dd06430` took 32 packages out of Open-Reality and every number in this
# comment block went stale the same afternoon.
#
# Eight sections, in an order that is itself load-bearing:
#
#   1. THE FULL INSTANTIATE. `ajt instantiate --frozen` into a fresh temp
#      depot, against a COPY of Open-Reality. The plan it reports (entries,
#      pruned, download jobs) is checked against `Pkg.Operations.prune_manifest`
#      run on the same files — including any pruned entries, which is the trap:
#      they carry `git-tree-sha1`, they are NOT installed, and installing them
#      would be wrong. See the NOTE this prints when the fixture has none.
#   2. CONVERGENCE ON OUR OWN CHECKER. `ajt verify --frozen` against that depot
#      must exit 0. The pipeline has to satisfy the module that decides whether
#      the container entrypoint may skip Pkg.
#   3. IDEMPOTENCE. A second `ajt instantiate --frozen` must install nothing and
#      change no file: every path, mtime, size and type under the depot AND the
#      environment is snapshotted either side of it. This runs BEFORE any julia
#      process touches the depot, because merely constructing Pkg's `EnvCache`
#      writes `logs/manifest_usage.toml` into depots1 (`Types.jl:426`).
#   4. THE STRONG EXTERNAL GATE. `JULIA_DEPOT_PATH=<tmp> julia --project=<env>
#      -e 'using Pkg; Pkg.instantiate()'` must do no work — no Installed, no
#      Downloaded, no Updating — and `Pkg.Operations.is_instantiated` must say
#      true. An installer that produced a plausible-looking depot that Julia
#      still wants to fix up would pass sections 1-3 and be useless.
#   5. `using OpenReality` in that depot, from a cold start. This is the one
#      that costs minutes (213 packages precompile), and the one nothing else
#      can substitute for.
#   6. WALL CLOCK, both sides: ajt's instantiate against
#      `julia -e 'using Pkg; Pkg.instantiate()'` into an equally empty depot.
#   7. `[sources]` WITH A `url`. A different corpus — Example.jl, and a local
#      repository with a package in a subdirectory — because Open-Reality has no
#      `[sources]` section and a gate needs one that does. Pkg and ajt each
#      resolve the same Project.toml into their own empty depot and the written
#      `Manifest.toml` must be byte-identical, `repo-url`/`repo-rev`/
#      `repo-subdir`/`git-tree-sha1` included, across a branch rev, a tag, a
#      full sha, no rev at all, and a subdir. Plus the two refusals (a rev that
#      does not exist, a subdir that does not exist), the clone cache key
#      `Pkg.gc()` recomputes, and the `[sources]` PATH case, which must keep
#      behaving exactly as it did before urls existed.
#   8. THE PREMISE BEHIND A DESIGN DECISION. `src/ops/instantiate.zig` keeps
#      download_source and download_artifacts as two phases, and says so with
#      numbers: fusing them into one frontier is SLOWER at equal peak
#      concurrency, because both halves queue on the same resource. That is
#      only true while the run is connection-bound, so this re-instantiates at
#      twice the width and reports when it stops being.
#
# NOTHING here WRITES to the user's real `~/.julia` or to the repo's
# `Open-Reality/`: the environment is copied into $WORK (section 1 writes
# `Manifest.toml` back if the fixups pass changes anything), every depot is
# under $WORK, and every julia invocation gets `JULIA_DEPOT_PATH` pointed there.
# Two things do READ the ambient depot, both deliberate and both confined to
# setup: the network probe (`ajt fetch --no-auth`, so it cannot refresh a token
# into `servers/*/auth.toml`) and the two Julia ORACLES, which put the ambient
# depot SECOND on DEPOT_PATH so Pkg loads from its existing precompile cache
# while every write still lands in $JDEPOT. Sections 4 onwards, whose whole
# claim is that the temp depot is self-sufficient, never see it.
#
# Usage: instantiate.sh [--keep] [--no-load] [--no-baseline] [--no-scaling]
#   --keep         leave $WORK behind
#   --no-load      skip section 5 (the cold `using`, which precompiles 213 pkgs)
#   --no-baseline  skip section 6's second full download
#   --no-scaling   skip section 8 (which downloads the environment twice more)
set -uo pipefail

# `ajt add`/`up`/`pin`/`free`/`instantiate` auto-precompile now, exactly as the
# Pkg verbs they mirror do (`Pkg.jl:65`, `Operations.jl:1828`, `API.jl:170`,
# `API.jl:1398`) -- and this gate is not about that. The Pkg invocations below
# already set this variable per call, for the same reason; setting it once here
# gives BOTH sides the same veto, so the comparison stays a comparison of what
# was installed rather than of how long julia took to compile it.
# `tools/diff_harness/autoprecompile.sh` is the gate that asserts the pass.
export JULIA_PKG_PRECOMPILE_AUTO=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
ENGINE="$REPO_ROOT/Open-Reality"

KEEP=0
DO_LOAD=1
DO_BASELINE=1
DO_SCALING=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --no-load) DO_LOAD=0; shift ;;
    --no-baseline) DO_BASELINE=0; shift ;;
    --no-scaling) DO_SCALING=0; shift ;;
    # Every line of the header block, and nothing past it: `set -uo pipefail`
    # printed as documentation is how you learn the range drifted.
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
[ -f "$ENGINE/Manifest.toml" ] || { echo "ERROR: no $ENGINE/Manifest.toml" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-instantiate-XXXXXX)"
# Installed packages and artifacts are made read-only by `set_readonly`, exactly
# as Pkg makes them, so the cleanup has to restore write bits first.
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# A directory's complete state: every path, its mtime to the nanosecond, its
# size and its type. This is what "changed no file" has to survive.
snapshot() { find "$1" -printf '%p\t%T@\t%s\t%y\n' 2>/dev/null | sort; }

# The same, minus `logs/`, for the depot.
#
# `logs/manifest_usage.toml` and `logs/artifact_usage.toml` are RE-STAMPED on
# every run, deliberately and in both implementations: Julia writes the first
# from the `EnvCache` constructor (`Types.jl:426`) every time an environment is
# loaded at all, and the second from the last statement of `download_artifacts`
# (`Operations.jl:1080`). Their entire purpose is to record "this environment
# was still in use at time T" so that `Pkg.gc()` spares what it references, and
# a stamp that stopped moving would be the bug -- `gc` would eventually collect
# a depot that is in daily use.
#
# So the idempotence claim is about everything the run INSTALLS, and the two
# usage logs are checked separately just below for the property they do have:
# the same keys, and a stamp that moved forward.
snapshot_installed() { find "$1" -path "$1/logs" -prune -o -printf '%p\t%T@\t%s\t%y\n' 2>/dev/null | sort; }

# The paths a usage log names, without the timestamps that are supposed to move.
usage_keys() { grep -h '^\[' "$1"/logs/*_usage.toml 2>/dev/null | sort; }

# The newest stamp in either log, as an ISO-8601 string that sorts
# lexicographically -- which is the whole reason `usage.zig` renders UTC with a
# fixed width. Read off DISK, not out of ajt's own report: `usage.record`
# answers `written` whenever the write succeeded, so believing it would be
# asking the implementation to grade itself.
usage_newest() { grep -h '^time = ' "$1"/logs/*_usage.toml 2>/dev/null | sort | tail -1; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# ---------------------------------------------------------------------------
# Network probe. Everything below downloads; without a network there is nothing
# to test and a red run would say nothing about the code.
# ---------------------------------------------------------------------------
# `--no-auth`: this is the ONE ajt invocation with no `--depot`, so `Config.fromEnv`
# resolves `depots1()` to the ambient `~/.julia` — and an authenticated GET
# against an expired token would REFRESH it, rewriting the user's real
# `servers/<host>/auth.toml`. A reachability probe has no business doing that.
if ! "$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: no network (https://pkg.julialang.org unreachable).          #"
  echo "#                                                                      #"
  echo "# Every gate in this harness downloads a real registry, 161 real        #"
  echo "# package tarballs and 82 real artifacts. There is no offline subset    #"
  echo "# worth running: the offline half of instantiate is already covered by  #"
  echo "# the unit tests in src/ops/instantiate.zig and by verify.sh.           #"
  echo "########################################################################"
  exit 0
fi

# Scratch depot for the oracle processes' own writes, so an EnvCache built to
# ANSWER a question never writes into the depot under test.
JDEPOT="$WORK/jdepot"
mkdir -p "$JDEPOT"
# The two ORACLE processes below (and only those) also READ the ambient depot,
# so Pkg loads from its existing precompile cache instead of spending 40 s
# rebuilding one in $JDEPOT. The scratch depot stays FIRST, which is what makes
# this safe: merely constructing `Pkg.Types.EnvCache` writes
# `logs/manifest_usage.toml` into depots1 (`Types.jl:426`), and that write must
# land in $JDEPOT. Neither oracle looks at a depot to answer its question —
# `prune_manifest` reads Project.toml and Manifest.toml and nothing else.
#
# Sections 4, 5 and 6 deliberately do NOT go through this: their whole claim is
# that the temp depot is self-sufficient, and a pass borrowed from ~/.julia
# would be worthless.
REAL_DEPOT="$(julia --startup-file=no -e 'print(first(Base.DEPOT_PATH))' 2>/dev/null)"
oracle() { env JULIA_DEPOT_PATH="$JDEPOT${REAL_DEPOT:+:$REAL_DEPOT}" julia --startup-file=no "$@"; }

# ---------------------------------------------------------------------------
# The environment, copied. Section 1 may write Manifest.toml back, and this
# harness must never modify the repo.
# ---------------------------------------------------------------------------
ENV_DIR="$WORK/env"
mkdir -p "$ENV_DIR"
cp -a "$ENGINE/." "$ENV_DIR/" || { echo "ERROR: could not copy $ENGINE" >&2; exit 2; }
cmp -s "$ENGINE/Manifest.toml" "$ENV_DIR/Manifest.toml" || { echo "ERROR: copy is not identical" >&2; exit 2; }
# The BASELINE for "the repo is untouched": comparing against empty would fail
# for anyone with an unrelated edit under Open-Reality/ already in flight.
git -C "$REPO_ROOT" status --porcelain -- Open-Reality > "$WORK/git.before" 2>/dev/null

# ---------------------------------------------------------------------------
# The oracle, from the PRISTINE files, before ajt has touched anything.
# `prune_manifest` mutates env.manifest in place (Operations.jl:1268), which is
# exactly what makes the pruned entries invisible to download_source.
# ---------------------------------------------------------------------------
read -r O_ENTRIES O_PRUNED O_JOBS O_TREE_ALL JV <<EOF
$(oracle -e '
using Pkg
env  = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
n    = length(env.manifest)
all_tree = count(p -> p.tree_hash !== nothing, collect(values(env.manifest)))
Pkg.Operations.prune_manifest(env)
kept = collect(values(env.manifest))
print(n, " ", n - length(kept), " ",
      count(p -> p.tree_hash !== nothing, kept), " ", all_tree, " ", VERSION)' "$ENGINE" 2>"$WORK/oracle.err")
EOF
[ -n "${O_ENTRIES:-}" ] || { echo "ERROR: the prune oracle failed" >&2; tail -10 "$WORK/oracle.err" >&2; exit 2; }
echo "  oracle: $O_ENTRIES entries, $O_PRUNED pruned, $O_JOBS of $O_TREE_ALL tree-hash entries to install (julia $JV)"

# Does this fixture still exercise the pruning trap at all?
#
# It used to, and the harness used to `exit 2` when it did not, on the sound
# principle that a check which cannot fail is not a check. But the fixture
# moved out from under it: `dd06430` ("OpenAL_jll becomes a weak dep") took 32
# packages out of the engine, and with them every entry that was pinned by
# tree hash yet unreachable through strong deps -- so `prune_manifest` now
# drops nothing and the two closure checks below have nothing to catch.
#
# Refusing to run is the wrong answer to that. It does not restore the trap, it
# just takes the other two dozen checks down with it -- including the ones that
# decide whether a depot Ajt built is one stock Pkg will accept. So the two
# checks that need the trap are SKIPPED, loudly, and everything else runs.
PRUNE_FIXTURE=1
if [ "$O_PRUNED" -eq 0 ] || [ "$O_JOBS" -ge "$O_TREE_ALL" ]; then
  PRUNE_FIXTURE=0
  echo
  echo "  NOTE: this fixture no longer has any pinned-but-unreachable entry, so ALL of the"
  echo "        pruning coverage is gone, not just the check that is skipped below:"
  echo "          - \"pruned entries were NOT installed\" is skipped (it has nothing to find)"
  echo "          - \"prune_manifest drops the same entries as Pkg\" now compares 0 to 0"
  echo "          - \"the download set is Pkg's pruned tree-hash set\" no longer separates a"
  echo "            correct closure from one that installs the whole manifest"
  echo "        Those three still print ok. Point ENGINE at an environment with entries"
  echo "        reachable only through a [weakdeps] trigger to get the coverage back."
fi

# ---------------------------------------------------------------------------
echo
echo "==> 1. a full instantiate of a real environment into an empty depot"
DEPOT="$WORK/depot"

T0=$(date +%s%N)
"$AJT" instantiate --frozen --depot "$DEPOT" "$ENV_DIR" >"$WORK/inst1.records" 2>"$WORK/inst1.err"
INST_RC=$?
T1=$(date +%s%N)
AJT_MS=$(( (T1 - T0) / 1000000 ))

check "instantiate exited cleanly" "0" "$INST_RC"
[ "$INST_RC" -eq 0 ] || head -20 "$WORK/inst1.err" | sed 's/^/       /'

read -r S_ENTRIES S_PRUNED S_JOBS S_INSTALLED S_ARTJOBS S_ARTINST <<EOF
$(awk -F'\t' '$1=="summary" {print $2, $3, $4, $5, $6, $7}' "$WORK/inst1.records")
EOF
check "manifest entries agree with Pkg"                 "$O_ENTRIES" "${S_ENTRIES:-}"
check "prune_manifest drops the same entries as Pkg"    "$O_PRUNED"  "${S_PRUNED:-}"
check "the download set is Pkg's pruned tree-hash set"  "$O_JOBS"    "${S_JOBS:-}"
check "every job actually downloaded"                   "$O_JOBS"    "${S_INSTALLED:-}"

# The registry step: a cold depot has none, so it must have been fetched.
check "the registry was installed into the empty depot" "added" \
  "$(awk -F'\t' '$1=="registry" {print $2}' "$WORK/inst1.records")"
[ -d "$DEPOT/registries" ] && ok "registries/ exists in the temp depot" \
  || bad "no registries/ in the temp depot"

# Artifacts. The count is oracled separately below; here only that the step ran
# and that nothing failed -- an environment of 98 JLLs with 0 artifacts is a
# silently broken install that verify cannot see.
[ "${S_ARTJOBS:-0}" -gt 50 ] && ok "$S_ARTJOBS artifacts planned" \
  || bad "only ${S_ARTJOBS:-0} artifacts planned -- the JLL half did not run"
check "every planned artifact was installed" "${S_ARTJOBS:-0}" "${S_ARTINST:-}"

N_BAD_PKG="$(awk -F'\t' '$1=="package" && $2!="installed" && $2!="already_present"' "$WORK/inst1.records" | wc -l)"
check "no package failed" "0" "$N_BAD_PKG"
N_BAD_ART="$(awk -F'\t' '$1=="artifact" && $2=="failed"' "$WORK/inst1.records" | wc -l)"
check "no artifact failed" "0" "$N_BAD_ART"

# Both halves download through a worker pool over a shared atomic cursor, which
# is the one part of this pipeline with no Julia oracle.
#
# The RECORDS cannot detect a dropped or double-claimed job: both drivers
# pre-allocate one result slot per job and index into it, so the record count is
# `jobs.len` by construction and `arts.plan` has already deduped by hash. What a
# dropped job DOES change is the DEPOT — the slot keeps its pre-filled `.failed`
# / `.needs_git_clone` sentinel (already asserted above) and the directory never
# appears. So count directories, not lines.
check "the depot holds one directory per planned artifact" "${S_ARTJOBS:-0}" \
  "$(find "$DEPOT/artifacts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
check "the depot holds one version-slug directory per package job" "$O_JOBS" \
  "$(find "$DEPOT/packages" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)"
check "no staging directory survived the concurrent run" "0" \
  "$(find "$DEPOT" -name '.ajt-tmp-*' 2>/dev/null | wc -l)"
check "no half-written manifest survived" "0" \
  "$(find "$ENV_DIR" -name '.ajt-manifest-*' 2>/dev/null | wc -l)"

# `--jobs 1` takes a different function for the artifacts
# (`install_artifacts.installAll` rather than the pool), and a warm depot
# exercises its already-present branch for free. Be honest about the limit: with
# every artifact already in place this does NOT reach the download, extract or
# commit code, so it gates agreement and clean exit, not the serial download
# path. The cold serial-vs-parallel comparison costs a third full download of
# the environment; install_packages.sh step 9 already runs it for the package
# half, where the pool is shared code.
"$AJT" instantiate --frozen --jobs 1 --depot "$DEPOT" "$ENV_DIR" >"$WORK/serial.records" 2>"$WORK/serial.err"
SERIAL_RC=$?
check "--jobs 1 exits cleanly against the warm depot" "0" "$SERIAL_RC"
[ "$SERIAL_RC" -eq 0 ] || head -10 "$WORK/serial.err" | sed 's/^/       /'
read -r SER_INST SER_ARTINST <<EOF
$(awk -F'\t' '$1=="summary" {print $5, $7}' "$WORK/serial.records")
EOF
check "--jobs 1 re-downloaded no package"  "0" "${SER_INST:-}"
check "--jobs 1 re-downloaded no artifact" "0" "${SER_ARTINST:-}"
# Name, hash AND outcome, so "the serial driver returned a different verdict"
# is caught rather than just "the plan was the same".
check "--jobs 1 and --jobs 8 agree on every artifact's identity and outcome" \
  "$(awk -F'\t' '$1=="artifact" {print $2"\t"$3"\t"$4}' "$WORK/inst1.records" | sed 's/^installed/already_present/' | sort | md5sum)" \
  "$(awk -F'\t' '$1=="artifact" {print $2"\t"$3"\t"$4}' "$WORK/serial.records" | sort | md5sum)"

# The pruned entries must be ABSENT from the depot. This is the assertion the
# whole closure argument rests on: they carry a git-tree-sha1, so anything that
# iterates the manifest instead of the pruned view installs them.
if [ $PRUNE_FIXTURE -eq 0 ]; then
  echo "  skip the closure check: this fixture prunes nothing (see the NOTE above)"
else
PRUNED_NAMES="$(oracle -e '
using Pkg
env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
before = Set(uuid for (uuid, _) in env.manifest)
Pkg.Operations.prune_manifest(env)
after = Set(uuid for (uuid, _) in env.manifest)
env2 = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
for u in setdiff(before, after)
    e = env2.manifest[u]
    e.tree_hash === nothing || println(e.name)
end' "$ENGINE" 2>/dev/null)"
N_PRUNED_TREE="$(printf '%s' "$PRUNED_NAMES" | grep -c . || true)"
if [ "$N_PRUNED_TREE" -eq 0 ]; then
  bad "no pruned entry carries a tree hash -- this check would be vacuous"
else
  LEAKED=0
  for n in $PRUNED_NAMES; do
    [ -d "$DEPOT/packages/$n" ] && { bad "$n is outside the loadable closure but was installed anyway"; LEAKED=1; }
  done
  [ $LEAKED -eq 0 ] && ok "$N_PRUNED_TREE pinned-but-unreachable entries ($(echo $PRUNED_NAMES | tr '\n' ' ')) were correctly NOT installed"
fi
fi

# The fixups pass ran and did not damage the file Pkg wrote.
check "fixups ran over every entry" "$O_ENTRIES" \
  "$(awk -F'\t' '$1=="fixup"' "$WORK/inst1.records" | wc -l)"
check "the manifest Pkg wrote round-trips unchanged through fixups" "unchanged" \
  "$(awk -F'\t' '$1=="manifest" {print $2}' "$WORK/inst1.records")"
if cmp -s "$ENGINE/Manifest.toml" "$ENV_DIR/Manifest.toml"; then
  ok "the environment's Manifest.toml is byte-identical to the committed one"
else
  bad "instantiate changed Manifest.toml" "$(diff "$ENGINE/Manifest.toml" "$ENV_DIR/Manifest.toml" | head -8 | tr '\n' '|')"
fi

# Nothing may have leaked out of the temp depot.
git -C "$REPO_ROOT" status --porcelain -- Open-Reality > "$WORK/git.after" 2>/dev/null
if diff -q "$WORK/git.before" "$WORK/git.after" >/dev/null; then
  ok "the repo's Open-Reality/ is untouched"
else
  bad "the repo's Open-Reality/ was modified" \
      "$(diff "$WORK/git.before" "$WORK/git.after" | head -5 | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 2. the pipeline converges on its own checker"

"$AJT" verify --frozen --depot "$DEPOT" "$ENV_DIR" >"$WORK/verify.out" 2>&1
check "ajt verify --frozen exits 0 against the depot instantiate built" "0" "$?"
sed 's/^/    /' "$WORK/verify.out"
# ...and it did so having examined every class of entry, not by skipping some.
# The COUNT, not the word: verify's success line always contains "stdlib"
# whether the number is 43 or 0, so grepping for the word is a tautology.
V_STDLIB="$(sed -n 's/.*, \([0-9]\{1,\}\) stdlib,.*/\1/p' "$WORK/verify.out")"
if [ "${V_STDLIB:-0}" -gt 0 ]; then
  ok "verify's stdlib cross-check actually ran ($V_STDLIB entries)"
else
  bad "verify resolved no entry as a stdlib — the check silently did not run" \
      "$(tr '\n' '|' < "$WORK/verify.out")"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 3. idempotence: a second run installs nothing and changes no file"

snapshot_installed "$DEPOT" > "$WORK/depot.before"
snapshot "$ENV_DIR" > "$WORK/env.before"
usage_keys "$DEPOT" > "$WORK/usage.before"
USAGE_STAMP_BEFORE="$(usage_newest "$DEPOT")"
# `snapshot` swallows find's errors, so an unreadable or absent directory would
# produce empty files and a green "nothing changed" — the exact vacuous pass
# this section exists to rule out.
[ -s "$WORK/depot.before" ] || bad "the depot snapshot is empty — the comparison below would be vacuous"
[ -s "$WORK/env.before" ]   || bad "the environment snapshot is empty — the comparison below would be vacuous"
[ -s "$WORK/usage.before" ] || bad "the usage logs name nothing — the gc-protection check below would be vacuous"

T0=$(date +%s%N)
"$AJT" instantiate --frozen --depot "$DEPOT" "$ENV_DIR" >"$WORK/inst2.records" 2>"$WORK/inst2.err"
INST2_RC=$?
T1=$(date +%s%N)
AJT2_MS=$(( (T1 - T0) / 1000000 ))

snapshot_installed "$DEPOT" > "$WORK/depot.after"
snapshot "$ENV_DIR" > "$WORK/env.after"
usage_keys "$DEPOT" > "$WORK/usage.after"
USAGE_STAMP_AFTER="$(usage_newest "$DEPOT")"

check "the second run exited cleanly" "0" "$INST2_RC"
read -r S2_JOBS S2_INSTALLED S2_ARTINST <<EOF
$(awk -F'\t' '$1=="summary" {print $4, $5, $7}' "$WORK/inst2.records")
EOF
check "the second run re-listed the same jobs" "$O_JOBS" "${S2_JOBS:-}"
check "...and downloaded none of them"          "0"       "${S2_INSTALLED:-}"
check "...and downloaded no artifact"           "0"       "${S2_ARTINST:-}"
check "...and did not re-fetch the registry"    "0" \
  "$(awk -F'\t' '$1=="registry"' "$WORK/inst2.records" | wc -l)"
check "...and left the manifest alone"          "unchanged" \
  "$(awk -F'\t' '$1=="manifest" {print $2}' "$WORK/inst2.records")"

if diff -q "$WORK/depot.before" "$WORK/depot.after" >/dev/null; then
  ok "not one path, mtime, size or type changed under the depot (logs/ excluded, see below)"
else
  bad "the second run modified the depot" "$(diff "$WORK/depot.before" "$WORK/depot.after" | head -8 | tr '\n' '|')"
fi
if diff -q "$WORK/env.before" "$WORK/env.after" >/dev/null; then
  ok "not one path, mtime, size or type changed under the environment"
else
  bad "the second run modified the environment" "$(diff "$WORK/env.before" "$WORK/env.after" | head -8 | tr '\n' '|')"
fi

# The two files the snapshot deliberately excludes, checked for what they
# SHOULD do. Both halves matter and they pull in opposite directions: the stamp
# has to move forward (or `Pkg.gc()` eventually eats a depot in daily use), and
# the key set must not (a run that dropped a key would unprotect whatever it
# named). `usage.sh` proves the gc consequence against a real `Pkg.gc`; this is
# the cheap invariant on the way through.
#
# Guarded on non-empty, because two absent logs produce two empty files and
# `diff` calls that agreement. The `bad` at the snapshot above already fails the
# run in that case; without this guard it would ALSO print a green line
# asserting an invariant nothing checked.
if [ -s "$WORK/usage.before" ] && [ -s "$WORK/usage.after" ]; then
  if diff -q "$WORK/usage.before" "$WORK/usage.after" >/dev/null; then
    ok "the usage logs still name exactly the same paths ($(wc -l < "$WORK/usage.after") keys)"
  else
    bad "the second run changed which paths the usage logs protect" \
        "$(diff "$WORK/usage.before" "$WORK/usage.after" | head -6 | tr '\n' '|')"
  fi
  # String comparison, not equality: `usage.zig` renders UTC at a fixed width,
  # so `>` on the text is `>` on the instant.
  if [ -n "$USAGE_STAMP_AFTER" ] && [[ "$USAGE_STAMP_AFTER" > "$USAGE_STAMP_BEFORE" ]]; then
    ok "...and the stamp moved forward, as Pkg's does on every load"
  else
    bad "the usage stamp did not advance — Pkg.gc() will eventually collect this depot" \
        "before [$USAGE_STAMP_BEFORE] after [$USAGE_STAMP_AFTER]"
  fi
fi
echo "  second run: ${AJT2_MS} ms"

# ---------------------------------------------------------------------------
echo
echo "==> 4. the strong external gate: stock Pkg has nothing left to do"
#
# From here on julia writes into $DEPOT (logs/, compiled/), which is why this
# runs after section 3 and not before it.

# `Pkg.instantiate()` on a cold depot would also precompile 213 packages, which
# is minutes of work that says nothing about downloading; the question here is
# strictly whether Pkg wants to install anything.
env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
  >"$WORK/pkginst.out" 2>&1
PKGINST_RC=$?
check "Pkg.instantiate() succeeds against the depot ajt built" "0" "$PKGINST_RC"
[ "$PKGINST_RC" -eq 0 ] || tail -20 "$WORK/pkginst.out" | sed 's/^/       /'
if grep -Eq '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/pkginst.out"; then
  bad "Pkg.instantiate() did work, so ajt's instantiate was incomplete" \
      "$(grep -E '^ *(Installed|Downloaded|Updating|Added|Cloning|Building) ' "$WORK/pkginst.out" | head -5 | tr '\n' '|')"
else
  ok "Pkg.instantiate() installed, downloaded and updated NOTHING"
fi

# The predicate itself, which also covers the artifacts verify deliberately
# does not check (`check_artifacts_downloaded`, Operations.jl:1083-1094).
J_INST="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e '
using Pkg
print(Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' "$ENV_DIR" 2>"$WORK/isinst.err")"
check "Pkg.Operations.is_instantiated agrees (artifacts included)" "true" "${J_INST:-}"
[ -n "${J_INST:-}" ] || tail -5 "$WORK/isinst.err" | sed 's/^/       /'

# The depot must be self-sufficient: DEPOT_PATH is exactly [$DEPOT], so a pass
# here cannot have been borrowed from ~/.julia.
check "DEPOT_PATH is the temp depot alone" "[\"$DEPOT\"]" \
  "$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e 'print(DEPOT_PATH)')"

# ---------------------------------------------------------------------------
echo
if [ $DO_LOAD -eq 1 ]; then
  echo "==> 5. using OpenReality, from a cold depot (precompiles ~213 packages)"
  #
  # The sibling harnesses assert "Pkg never entered the process" here. That
  # check is MEANINGLESS on this environment and would fail for the wrong
  # reason: `Pkg` is a genuine transitive dependency of the Open-Reality
  # manifest (FileIO, PkgVersion and nine JLL wrappers depend on it), so it is
  # loaded because the environment asked for it. What that check was standing in
  # for is self-sufficiency, and that is asserted directly instead: every module
  # that ends up loaded must have come out of the temp depot, the environment
  # itself, or the Julia installation's own stdlib — never `~/.julia`.
  T0=$(date +%s%N)
  LOAD_OUT="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no --project="$ENV_DIR" -e '
    using OpenReality
    roots = (ARGS[1], ARGS[2], Sys.STDLIB, dirname(Sys.BINDIR))
    strays = String[]
    for m in Base.loaded_modules_array()
        p = pathof(m)
        p === nothing && continue
        any(r -> startswith(realpath(p), realpath(r)), roots) || push!(strays, p)
    end
    print(isempty(strays) ? "OK" : string("STRAY ", join(strays, " ")))' \
    "$DEPOT" "$ENV_DIR" 2>"$WORK/using.err")"
  T1=$(date +%s%N)
  LOAD_MS=$(( (T1 - T0) / 1000000 ))
  if [ "$LOAD_OUT" = "OK" ]; then
    ok "using OpenReality loaded in $((LOAD_MS/1000))s, every module from the temp depot / env / stdlib"
  else
    bad "using OpenReality failed or loaded something from outside the temp depot" \
        "$(printf '%s' "$LOAD_OUT"; tail -8 "$WORK/using.err" | tr '\n' '|')"
  fi
else
  echo "==> 5. SKIPPED (--no-load)"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 6. wall clock, against the command it replaces"
if [ $DO_BASELINE -eq 1 ]; then
  # An equally empty depot, the same environment, the same precompilation
  # setting -- so the two numbers measure the same work.
  PKG_DEPOT="$WORK/depot-pkg"
  mkdir -p "$PKG_DEPOT"
  T0=$(date +%s%N)
  env JULIA_DEPOT_PATH="$PKG_DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
    julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
    >"$WORK/pkgbase.out" 2>&1
  PKG_RC=$?
  T1=$(date +%s%N)
  PKG_MS=$(( (T1 - T0) / 1000000 ))
  check "the baseline Pkg.instantiate() succeeded" "0" "$PKG_RC"
  [ "$PKG_RC" -eq 0 ] || tail -10 "$WORK/pkgbase.out" | sed 's/^/       /'
  # Equal work, or the comparison is meaningless.
  BASE_PKGS="$(find "$PKG_DEPOT/packages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  AJT_PKGS="$(find "$DEPOT/packages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  check "both depots hold the same number of packages" "$BASE_PKGS" "$AJT_PKGS"
  BASE_ARTS="$(find "$PKG_DEPOT/artifacts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  AJT_ARTS="$(find "$DEPOT/artifacts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  check "both depots hold the same number of artifacts" "$BASE_ARTS" "$AJT_ARTS"
  echo
  echo "  ajt instantiate --frozen (cold depot) : ${AJT_MS} ms"
  echo "  julia -e 'using Pkg; Pkg.instantiate()' (cold depot) : ${PKG_MS} ms"
  echo "  ajt instantiate --frozen (warm depot) : ${AJT2_MS} ms"
else
  echo "  SKIPPED the baseline (--no-baseline)"
  echo "  ajt instantiate --frozen (cold depot) : ${AJT_MS} ms"
  echo "  ajt instantiate --frozen (warm depot) : ${AJT2_MS} ms"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 7. [sources] carrying a url"
#
# A DIFFERENT corpus, and it has to be: Open-Reality has no `[sources]` section,
# so every assertion above is silent about this path. `Example.jl` is the
# smallest real registered package there is, which keeps the clone under a
# second, and the subdir case is a repository built here so the harness owns
# both the tree and the failure.
#
# Both sides start from an EMPTY depot except for a copy of the registry section
# 1 already installed — Pkg will not resolve without one, and downloading a
# second 84 MB registry to prove a point about git is not a good trade. The copy
# is read-only from $DEPOT's point of view and section 3 (which asserts $DEPOT
# is untouched) has long since run. The fallback exists so this section keeps
# working if the sections above are ever reordered or their corpus changes:
# nothing here depends on Open-Reality.
SRC_URL="https://github.com/JuliaLang/Example.jl"
EX_UUID="7876af07-990d-54b4-ab0e-23690620f79a"
# Sections 1-6 never need this: their manifest already records `julia_version`.
# A resolve from a project with NO manifest has nothing to read it from, so it
# is passed explicitly here, exactly as `resolve.sh` does.
JULIA_PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"
S7="$WORK/sources"
ADEPOT="$S7/ajt-depot"
PDEPOT="$S7/pkg-depot"
mkdir -p "$ADEPOT" "$PDEPOT"
if [ -d "$DEPOT/registries" ]; then
  cp -a "$DEPOT/registries" "$ADEPOT/"
else
  "$AJT" registry add --depot "$ADEPOT" General >"$S7-registry.log" 2>&1 \
    || bad "could not install a registry for section 7"
fi
cp -a "$ADEPOT/registries" "$PDEPOT/" 2>/dev/null

# Write a Project.toml whose [sources] entry is $2 (the inline table body) for
# the package named $3 with uuid $4, into the pair of directories $1{-a,-b}.
mk_source_env() {
  local base="$1" body="$2" name="$3" uuid="$4" d
  for d in "$base-a" "$base-b"; do
    mkdir -p "$d"
    printf '[deps]\n%s = "%s"\n\n[sources]\n%s = {%s}\n' "$name" "$uuid" "$name" "$body" > "$d/Project.toml"
  done
}

# One case: ajt resolves + instantiates into $ADEPOT, Pkg instantiates into
# $PDEPOT, and the two manifests must be identical byte for byte.
#
# `Pkg.instantiate()` on an environment with NO manifest is a full resolve
# (`API.jl:1281-1285` falls through to `up`), which is what makes it the right
# oracle here: it is the same entry point a user runs, and it exercises
# `collect_fixed!` → `handle_repo_add!` exactly as ajt's resolve does.
source_case() {
  local label="$1" base="$2"
  local a="$base-a" b="$base-b"

  "$AJT" resolve --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" --write "$a" >"$base.ajt" 2>&1
  local arc=$?
  "$AJT" instantiate --frozen --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" "$a" >"$base.inst" 2>&1
  local irc=$?
  env JULIA_DEPOT_PATH="$PDEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
    julia --startup-file=no --project="$b" -e 'using Pkg; Pkg.instantiate()' >"$base.pkg" 2>&1
  local prc=$?

  check "$label: ajt resolve exited cleanly" "0" "$arc"
  [ "$arc" -eq 0 ] || head -6 "$base.ajt" | sed 's/^/       /'
  check "$label: ajt instantiate exited cleanly" "0" "$irc"
  check "$label: Pkg.instantiate() exited cleanly" "0" "$prc"
  [ "$prc" -eq 0 ] || head -6 "$base.pkg" | sed 's/^/       /'

  # LANDMARK. Without these three, an ajt that quietly ignored `[sources]` and a
  # Pkg that was never invoked would both "agree" on a manifest with no repo
  # keys at all -- which is precisely the bug this section exists to catch, and
  # precisely what shipped before it.
  [ -s "$b/Manifest.toml" ] && grep -q '^repo-url = ' "$b/Manifest.toml" \
    && ok "$label: Pkg really wrote a repo-tracked entry" \
    || bad "$label: Pkg's manifest has no repo-url -- the oracle did not run the git path"
  grep -q '^git-tree-sha1 = ' "$b/Manifest.toml" \
    && ok "$label: Pkg's entry is pinned by tree hash" \
    || bad "$label: Pkg's manifest has no git-tree-sha1"
  awk -F'\t' '$1=="repo"' "$base.ajt" | grep -q . \
    && ok "$label: ajt reported the repo source it materialised" \
    || bad "$label: ajt printed no repo record -- it did not take the [sources] url path"

  if diff -u "$b/Manifest.toml" "$a/Manifest.toml" >"$base.diff" 2>&1; then
    ok "$label: Manifest.toml is byte-identical to Pkg's"
  else
    bad "$label: Manifest.toml differs from Pkg's" "$(head -12 "$base.diff" | tr '\n' '|')"
  fi
  # Project.toml must come through untouched: `[sources]` is INPUT, and a
  # resolve that rewrote a resolved rev back into it would change the project
  # hash on every run.
  cmp -s "$a/Project.toml" "$b/Project.toml" && ok "$label: Project.toml untouched on both sides" \
    || bad "$label: Project.toml diverged"

  "$AJT" verify --frozen "$a" --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" >"$base.verify" 2>&1
  check "$label: ajt verify --frozen is clean" "0" "$?"
  [ "$(awk 'END{print NR}' "$base.verify")" -gt 0 ] || bad "$label: verify printed nothing"
  # The strong form: re-derive every tree hash from the bytes on disk. For a
  # repo source this is the only check that the materialisation is right rather
  # than merely present -- `git archive` applies export filters, and a
  # `.gitattributes` doing `eol` or `export-ignore` would land a directory that
  # does not hash to the tree the manifest names.
  "$AJT" verify --frozen --check-hashes "$a" --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" >"$base.rehash" 2>&1
  check "$label: the materialised tree re-hashes to its git-tree-sha1" "0" "$?"
}

mk_source_env "$S7/branch" "url = \"$SRC_URL\", rev = \"master\"" Example "$EX_UUID"
source_case "branch rev" "$S7/branch"

# A TAG and a full SHA resolve as objects rather than branches, and that
# difference is not cosmetic: `is_branch` is what decides whether the clone is
# re-fetched before the tree is taken (`Types.jl:1016-1020`). Both must land on
# the same bytes as Pkg, and a tag must land on the TAG's tree even though a
# branch of the same repository has moved past it.
mk_source_env "$S7/tag" "url = \"$SRC_URL\", rev = \"v0.5.4\"" Example "$EX_UUID"
source_case "tag rev" "$S7/tag"
mk_source_env "$S7/sha" "url = \"$SRC_URL\", rev = \"bee52d9dfab01f73584b924e3908b0c1b6ce2d40\"" Example "$EX_UUID"
source_case "full sha rev" "$S7/sha"

# NO rev: the clone's default branch, discovered from its HEAD
# (`Types.jl:996-999`) and written into the manifest as `repo-rev`. The
# Project.toml never names it, so a manifest that agrees with Pkg here is
# evidence the branch was read off the repository and not guessed.
mk_source_env "$S7/norev" "url = \"$SRC_URL\"" Example "$EX_UUID"
source_case "no rev" "$S7/norev"
check "no rev: the default branch was discovered, not invented" "master" \
  "$(awk -F' = ' '$1=="repo-rev" {gsub(/"/,"",$2); print $2}' "$S7/norev-a/Manifest.toml")"

# The clone cache key. `Pkg.gc()` recomputes `add_repo_cache_path` for every
# live manifest entry and DELETES every `clones/` directory matching none of
# them (`API.jl:772-791`), so a clone under a different name is not untidy --
# it is garbage-collected and re-cloned forever.
PKG_CLONE="$(oracle -e 'using Pkg; print(basename(Pkg.Types.add_repo_cache_path(ARGS[1])))' "$SRC_URL" 2>/dev/null)"
# An empty answer must NOT fall through into a `-d "$ADEPOT/clones/"` that
# passes for the wrong reason: `clones/` exists by then, so the check below
# would be green with no oracle at all.
if [ -z "$PKG_CLONE" ]; then
  bad "the add_repo_cache_path oracle failed -- the clone-key check cannot run"
elif [ -d "$ADEPOT/clones/$PKG_CLONE" ]; then
  ok "the clone cache key is Pkg's add_repo_cache_path ($PKG_CLONE)"
else
  bad "no clones/$PKG_CLONE in the ajt depot" "$(ls "$ADEPOT/clones" 2>/dev/null | tr '\n' ' ')"
fi
check "all four revs of one url share ONE clone" "1" \
  "$(find "$ADEPOT/clones" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"

# --- subdir, against a repository this harness owns ------------------------
#
# No registered package ships a `subdir` source, and inventing one against a
# third-party repository would make the gate depend on somebody else's history.
SUB_UUID="11111111-2222-3333-4444-555555555555"
REPO="$S7/repo"
mkdir -p "$REPO/sub/src"
printf 'name = "SubEx"\nuuid = "%s"\nversion = "1.2.3"\n\n[deps]\nExample = "%s"\n' "$SUB_UUID" "$EX_UUID" > "$REPO/sub/Project.toml"
printf 'module SubEx\nusing Example\nend\n' > "$REPO/sub/src/SubEx.jl"
printf 'not a package\n' > "$REPO/README.md"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" -c user.email=gate@ajt -c user.name=gate add -A >/dev/null 2>&1
git -C "$REPO" -c user.email=gate@ajt -c user.name=gate commit -q -m gate >/dev/null 2>&1
REPO_REAL="$(cd "$REPO" && pwd -P)"

mk_source_env "$S7/subdir" "url = \"$REPO_REAL\", rev = \"main\", subdir = \"sub\"" SubEx "$SUB_UUID"
source_case "subdir" "$S7/subdir"
check "subdir: the manifest records repo-subdir" "sub" \
  "$(awk -F' = ' '$1=="repo-subdir" {gsub(/"/,"",$2); print $2}' "$S7/subdir-a/Manifest.toml")"
# The subdir's OWN Project.toml is where the dependency list of an unregistered
# repo package comes from (`collect_fixed!` → `collect_project`,
# `Operations.jl:445-451`). If that read were skipped the entry would have no
# `deps`, `prune_manifest` would drop Example, and the manifest would be one
# entry short -- which the byte-diff catches, but not legibly.
grep -q '^deps = \["Example"\]' "$S7/subdir-a/Manifest.toml" \
  && ok "subdir: deps came from the subdirectory's own Project.toml" \
  || bad "subdir: the entry has no deps -- the source project was not read"

# --- the two refusals ------------------------------------------------------
#
# Both must be Pkg's own sentence and a non-zero exit, not a Zig stack trace
# through the git backend and not a manifest written from a guess.
mk_source_env "$S7/badsub" "url = \"$REPO_REAL\", rev = \"main\", subdir = \"nope\"" SubEx "$SUB_UUID"
"$AJT" resolve --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" --write "$S7/badsub-a" >"$S7/badsub.ajt" 2>&1
check "bad subdir: ajt exits non-zero" "1" "$?"
grep -q 'Did not find subdirectory `nope`' "$S7/badsub.ajt" \
  && ok "bad subdir: ajt prints Pkg's sentence" \
  || bad "bad subdir: wrong message" "$(head -4 "$S7/badsub.ajt" | tr '\n' '|')"
[ -f "$S7/badsub-a/Manifest.toml" ] && bad "bad subdir: a manifest was written anyway" \
  || ok "bad subdir: no manifest was written"
env JULIA_DEPOT_PATH="$PDEPOT" julia --startup-file=no --project="$S7/badsub-b" \
  -e 'using Pkg; Pkg.instantiate()' >"$S7/badsub.pkg" 2>&1
grep -q 'Did not find subdirectory `nope`' "$S7/badsub.pkg" \
  && ok "bad subdir: Pkg refuses with the same sentence" \
  || bad "bad subdir: Pkg's message changed" "$(grep -i error "$S7/badsub.pkg" | head -2 | tr '\n' '|')"

mk_source_env "$S7/badrev" "url = \"$SRC_URL\", rev = \"no-such-rev-42\"" Example "$EX_UUID"
"$AJT" resolve --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" --write "$S7/badrev-a" >"$S7/badrev.ajt" 2>&1
check "bad rev: ajt exits non-zero" "1" "$?"
grep -q 'Did not find rev no-such-rev-42 in repository' "$S7/badrev.ajt" \
  && ok "bad rev: ajt prints Pkg's sentence" \
  || bad "bad rev: wrong message" "$(head -4 "$S7/badrev.ajt" | tr '\n' '|')"

# --- a hostile url must not become a process ------------------------------
#
# `[sources]` is DATA that arrives with somebody else's repository, and
# `ajt resolve` hands it to `git clone` before the solve. git's remote-HELPER
# syntax, `<transport>::<address>`, makes git exec `git-remote-<transport>` —
# and `ext::` takes a command line. This gate is the only place that fact is
# written down executably.
#
# The trailing `https://` is load-bearing in the ATTACK, not in the fix: it is
# what stops `isScpLike` from calling the string ssh, so that before
# `url.isTransportHelper` existed it fell through to `local_path` (supported)
# and reached `git clone`. It also satisfies `Pkg.isurl`, whose regex is an
# unanchored search, so nothing upstream rejected it either.
#
# The CONTROL runs the same payload straight at `git`. Without it this section
# proves nothing: if the payload were inert on this host — modern git defaults
# `protocol.ext.allow` to `never` — a refusal by ajt would be indistinguishable
# from a payload that never worked. `GIT_CONFIG_*` turns the protocol back on
# for the control only, which is exactly what a user's `~/.gitconfig` can do,
# and `cli.zig` deliberately does not set `GIT_CONFIG_NOSYSTEM`.
EVIL="$S7/EXECUTED"
rm -f "$EVIL"
PAYLOAD="ext::touch $EVIL https://example.invalid/r"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.ext.allow GIT_CONFIG_VALUE_0=always \
  git clone --quiet --bare -- "$PAYLOAD" "$S7/evil-control" >/dev/null 2>&1
if [ -e "$EVIL" ]; then
  ok "hostile url: the control payload executes, so the check below is real"
  rm -f "$EVIL"
  mk_source_env "$S7/evil" "url = \"$PAYLOAD\"" Example "$EX_UUID"
  env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.ext.allow GIT_CONFIG_VALUE_0=always \
    "$AJT" resolve --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" --write "$S7/evil-a" >"$S7/evil.ajt" 2>&1
  check "hostile url: ajt exits non-zero" "1" "$?"
  [ -e "$EVIL" ] && bad "hostile url: ajt EXECUTED the payload" \
    || ok "hostile url: ajt refused before spawning git"
  grep -q 'remote-HELPER syntax' "$S7/evil.ajt" \
    && ok "hostile url: the refusal says why" \
    || bad "hostile url: the message does not name the cause" "$(head -3 "$S7/evil.ajt" | tr '\n' '|')"
else
  # Not a pass and not a failure: the host cannot demonstrate the primitive, so
  # the assertion would be vacuous. Say so rather than printing a green line.
  echo "  --   hostile url: SKIPPED (ext:: is inert on this git; the check would be vacuous)"
fi

# --- the regression this could break ---------------------------------------
#
# A `[sources]` PATH is the 1.11+ spelling of `Pkg.develop`, it has nothing to
# do with git, and the url work must not have moved it. The oracle is Pkg on the
# same files; the environment needs a manifest first because a path source with
# no manifest entry has no candidate versions in ANY registry, which is a
# pre-existing gap `Ajt.jl` still delegates for (`_source_reason`).
PS="$S7/pathsrc"
mkdir -p "$PS/Local/src" "$PS-a" "$PS-b"
printf 'name = "Local"\nuuid = "99999999-8888-7777-6666-555555555555"\nversion = "0.4.0"\n\n[deps]\nExample = "%s"\n' "$EX_UUID" > "$PS/Local/Project.toml"
printf 'module Local\nusing Example\nend\n' > "$PS/Local/src/Local.jl"
for d in "$PS-a" "$PS-b"; do
  printf '[deps]\nLocal = "99999999-8888-7777-6666-555555555555"\n\n[sources]\nLocal = {path = "../pathsrc/Local"}\n' > "$d/Project.toml"
done
env JULIA_DEPOT_PATH="$PDEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$PS-b" -e 'using Pkg; Pkg.instantiate()' >"$PS.pkg" 2>&1
cp "$PS-b/Manifest.toml" "$PS-a/Manifest.toml" 2>/dev/null
"$AJT" resolve --depot "$ADEPOT" --julia-prefix "$JULIA_PREFIX" --write "$PS-a" >"$PS.ajt" 2>&1
check "[sources] path: ajt resolve exited cleanly" "0" "$?"
if diff -u "$PS-b/Manifest.toml" "$PS-a/Manifest.toml" >"$PS.diff" 2>&1; then
  ok "[sources] path still round-trips byte-identically to Pkg"
else
  bad "[sources] path regressed" "$(head -12 "$PS.diff" | tr '\n' '|')"
fi
grep -q '^path = ' "$PS-a/Manifest.toml" \
  && ok "[sources] path: the entry really is path-tracked (corpus check)" \
  || bad "[sources] path: no path entry -- the regression corpus is wrong"

# ---------------------------------------------------------------------------
echo
echo "==> 8. is the download phase still connection-bound?"
#
# This section exists to keep ONE claim honest, and it is a claim about code
# that is deliberately NOT here: `src/ops/instantiate.zig` says steps 4 and 5
# are two phases rather than one frontier because both halves queue on the same
# resource -- the number of concurrent requests to the Pkg server -- so deleting
# the barrier between them cannot help and, measured, hurts.
#
# That argument rests entirely on the run being CONNECTION-bound rather than
# LINK-bound. If the link ever saturates below `--jobs` connections, the premise
# is gone and the fusion is worth rebuilding. So: the same environment, two
# empty depots, two widths. If doubling the width does not buy a large fraction
# of the run, this prints RECONSIDER rather than a pass -- it is a statement
# about the network, not about the code, and failing the suite over someone
# else's congested morning would be worse than useless.
#
# THE PAIR IS MEASURED HERE, BACK TO BACK, and does not reuse section 1's number
# even though that is another full download. Two reasons, both of which would
# have made the verdict a fiction:
#
#   * section 1 passes no `--jobs`, so it runs at whatever
#     `JULIA_PKG_CONCURRENT_DOWNLOADS` says (`net/http.zig`'s `Config.fromEnv`,
#     reached through `main.zig`'s `jobs_flag orelse config.concurrency`). With
#     that variable exported to 16 -- the exact knob this section reasons about
#     -- the "8" arm would not be 8 and the comparison would be against itself.
#     Both arms below pass `--jobs` explicitly, which overrides it.
#   * section 1 runs first and section 8 runs last, with a `Pkg.instantiate()`,
#     a 213-package precompile and another full download in between. By then the
#     CDN edge has served every tarball twice, and all of that pushes the LATER
#     arm down -- i.e. straight toward a pass. Adjacent runs, narrow first, is
#     the only ordering where the difference is the width.
#
# The threshold is deliberately loose. Doubling the width took ~30% off when
# this was written (14.9 s -> 10.2 s, medians of 3), so 15% is half the signal
# and well above the spread of a single pair.
if [ $DO_SCALING -eq 1 ]; then
  scaling_run() { # <jobs> <tag> -> prints elapsed ms, leaves $WORK/<tag>.records
    local jobs="$1" tag="$2"
    local d="$WORK/depot-$tag"
    rm -rf "$d"; mkdir -p "$d"
    local t0=$(date +%s%N)
    "$AJT" instantiate --frozen --jobs "$jobs" --depot "$d" "$ENV_DIR" \
      >"$WORK/$tag.records" 2>"$WORK/$tag.err"
    local rc=$?
    local t1=$(date +%s%N)
    # Dropped as soon as it is measured: three full depots at once is ~1.5 GB,
    # and a CI runner with a tmpfs /tmp would ENOSPC rather than fail a check.
    chmod -R u+w "$d" 2>/dev/null; rm -rf "$d"
    echo "$rc $(( (t1 - t0) / 1000000 ))"
  }

  read -r NARROW_RC NARROW_MS <<<"$(scaling_run 8 narrow)"
  read -r WIDE_RC WIDE_MS <<<"$(scaling_run 16 wide)"
  check "the 8-wide run exited cleanly"  "0" "$NARROW_RC"
  [ "$NARROW_RC" -eq 0 ] || head -10 "$WORK/narrow.err" | sed 's/^/       /'
  check "the 16-wide run exited cleanly" "0" "$WIDE_RC"
  [ "$WIDE_RC" -eq 0 ] || head -10 "$WORK/wide.err" | sed 's/^/       /'

  # Same work, or the ratio means nothing -- and "work" is what was INSTALLED
  # ($5/$7 of the summary record), not what was planned ($4/$6). A run that
  # planned everything and downloaded nothing would finish in a second, plan the
  # identical set, and hand this section an enormous and entirely fake gain.
  read -r N_JOBS N_INST N_ARTJOBS N_ARTINST <<EOF
$(awk -F'\t' '$1=="summary" {print $4, $5, $6, $7}' "$WORK/narrow.records")
EOF
  read -r W_JOBS W_INST W_ARTJOBS W_ARTINST <<EOF
$(awk -F'\t' '$1=="summary" {print $4, $5, $6, $7}' "$WORK/wide.records")
EOF
  check "both widths planned the same package set"    "${N_JOBS:-x}"    "${W_JOBS:-}"
  check "both widths DOWNLOADED the same packages"    "${N_INST:-x}"    "${W_INST:-}"
  check "both widths planned the same artifact set"   "${N_ARTJOBS:-x}" "${W_ARTJOBS:-}"
  check "both widths DOWNLOADED the same artifacts"   "${N_ARTINST:-x}" "${W_ARTINST:-}"
  # ...and that it was a cold depot both times, or "downloaded the same" is two
  # zeroes agreeing with each other.
  if [ "${N_INST:-0}" -gt 0 ] && [ "${N_ARTINST:-0}" -gt 0 ]; then
    ok "both arms started cold ($N_INST packages, $N_ARTINST artifacts downloaded)"
  else
    bad "an arm downloaded nothing — the width comparison would be vacuous" \
        "packages=${N_INST:-?} artifacts=${N_ARTINST:-?}"
  fi

  if [ "${NARROW_MS:-0}" -gt 0 ] && [ "${WIDE_MS:-0}" -gt 0 ]; then
    # Integer percent, so the comparison needs no bc/awk. A negative value is a
    # well-formed operand for `test -ge` and simply fails it.
    GAIN=$(( (NARROW_MS - WIDE_MS) * 100 / NARROW_MS ))
    echo "  --jobs 8: ${NARROW_MS} ms    --jobs 16: ${WIDE_MS} ms    ${GAIN}% off"
    if [ "$GAIN" -ge 15 ]; then
      ok "doubling --jobs still buys ${GAIN}% — the run is connection-bound, so the phase barrier is not the constraint"
    else
      echo "  RECONSIDER: doubling --jobs bought only ${GAIN}%."
      echo "              The download phase is no longer connection-bound on this link, which is"
      echo "              the premise instantiate.zig's 'steps 4 and 5 are two phases' rests on."
      echo "              Re-measure the fused frontier before trusting that comment."
    fi
  fi
else
  echo "  SKIPPED (--no-scaling)"
fi

# ---------------------------------------------------------------------------
echo
echo "======================================================================"
printf 'instantiate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || exit 1
exit 0
