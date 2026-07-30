#!/usr/bin/env bash
# THE WHOLE PIPELINE, ON PACKAGES AJT WAS NEVER TUNED FOR.
#
# `resolve.sh` already proves the RESOLVER against foreign corpora: stock Pkg
# resolves Makie, DataFrames and Flux, and Ajt has to agree on manifests it has
# never seen. Nothing did the same for the other two verbs. `instantiate` and
# `precompile` had only ever been run end to end on Open-Reality, and
# Open-Reality flatters them in specific ways — it is fully pinned, it is
# conflict-free, its manifest was written by one Pkg version, and it is a
# PACKAGE (name + uuid + src/) rather than the bare `[deps]` environment that
# `Pkg.add` actually produces. This harness closes that half.
#
# For each target: let **stock Pkg** create and resolve the environment, so
# nothing Ajt does can have influenced the manifest. Then, into a **fresh,
# empty depot** — no registry, no packages, no caches — run
#
#     ajt instantiate --frozen        (sources + artifacts + manifest fixups)
#     ajt precompile                  (packages AND package extensions)
#
# and then require stock Julia to agree that there is nothing left to do:
#
#   A. `Pkg.instantiate()` installs, downloads and updates NOTHING, and
#      `Pkg.Operations.is_instantiated` returns true (which also covers
#      artifacts, via `check_artifacts_downloaded`).
#   B. `Pkg.precompile()` writes ZERO new files under `compiled/`.
#   C. `using <Target>` succeeds, no new cache file appears, and Pkg is not
#      loaded unless the environment's own manifest declares it (Makie's does;
#      see gate C for why that distinction is the honest one).
#
# B and C are the M5 acceptance criterion. `fallback_gates.sh --precompile`
# asserts exactly this — for Open-Reality only. Applying it to a repo Ajt has
# never seen is the entire point of this file.
#
# ---------------------------------------------------------------------------
# WHY THERE IS NO PREPARED BASE DEPOT HERE
# ---------------------------------------------------------------------------
# `precompile.sh` copies one prepared base depot to both sides because it
# compares two `compiled/` trees, and `Pkg.precompile()` has to load Pkg —
# which precompiles Pkg and ~23 stdlibs into `compiled/` first, 48 files that
# have nothing to do with the environment under test. Ajt never loads Pkg, so
# that comparison would show 48 spurious differences.
#
# This harness does NOT compare two trees. It compares one tree against itself
# across a `Pkg.precompile()`, so the only question is what is already in it
# when the snapshot is taken — and by then gate A has already run
# `Pkg.instantiate()` in that depot, which loaded Pkg and warmed exactly the
# machinery `Pkg.precompile()` will want. The ordering does the base depot's
# job. Copying one in would be dead weight, and (worse) would mean the depot
# under test was not built from empty, which is the property being asserted.
#
# ---------------------------------------------------------------------------
# TARGETS, AND WHAT EACH ONE IS FOR
# ---------------------------------------------------------------------------
#   DataFrames     44 entries,  1 loadable extension. A wide data ecosystem,
#                  and the FAST one: it is the primary because a gate nobody
#                  runs protects nothing.
#   Interpolations 33 entries,  6 loadable extensions from FIVE different
#                  parents. The different shape. Extensions became precompile
#                  nodes only recently and are the part of `precompile` with
#                  the least mileage on it; here they arrive from packages
#                  nobody added on purpose (`Adapt` gains two because
#                  `StaticArrays` and `SparseArrays` are both in the closure),
#                  which is exactly the case that is easy to miss.
#   Makie         237 entries. The one the repo owner named, and the reason
#                  --heavy exists: hundreds of megabytes of JLL artifacts and
#                  many minutes of compilation. It is also where the default
#                  tier's blind spot is covered — neither DataFrames nor
#                  Interpolations installs a single artifact, so the artifact
#                  half of gate A (`check_artifacts_downloaded`) is vacuous
#                  for them. The run says so out loud when that happens.
#
# One more worth knowing about, reachable with --targets:
#   Distributions  51 entries, ELEVEN extensions and two artifacts — the best
#                  single target here, and the one that exposed the host
#                  problem below.
#
# ---------------------------------------------------------------------------
# ON THIS HOST, `--heavy` NEEDS LD_LIBRARY_PATH — AND WHY THAT IS NOT CHEATING
# ---------------------------------------------------------------------------
# Makie and Distributions both reach `SpecialFunctions`, whose
# `OpenSpecFun_jll` cannot dlopen here:
#
#   InitError: could not load library ".../artifacts/09b351e8…/lib/libopenspecfun.so"
#   libquadmath.so.0: cannot open shared object file: No such file or directory
#
# Julia SHIPS that library, in `<prefix>/lib/julia`, and julia itself resolves
# it fine — the loader resolves an artifact's `DT_NEEDED` through the
# ARTIFACT's rpath, not through julia's, and on NixOS there is no system copy
# to fall back to. Stock `Pkg.precompile()` fails on exactly the same nodes, in
# a depot stock Pkg built itself, which is what the control below reports.
#
# So it is a loader-path property of the machine, identical for both tools, and
# putting julia's own libdir on the search path is not tilting the comparison:
#
#   LD_LIBRARY_PATH="$(julia -e 'print(joinpath(Sys.BINDIR,"..","lib","julia"))')" \
#     tools/diff_harness/foreign_e2e.sh --heavy
#
# It is NOT applied automatically. A harness that silently rewrites the dynamic
# loader's environment is a harness that can hide a real defect, and the
# probe that would decide when to do it (can *an artifact* find libquadmath?)
# needs an installed artifact to ask about. The run prints the remedy, spelled
# out for this machine, whenever a dlopen is what failed. One cosmetic side
# effect to expect when you do use it: every process inherits it, so system
# tools pick up julia's libpcre2 and print "no version information available"
# on stderr. Nothing here reads a tool's stderr, so it is noise and nothing more.
#
# WALL CLOCK, from an empty $WORK, measured on this host (20 cores, fast link
# to pkg.julialang.org). Both tiers are dominated by DOWNLOADS, so a slower
# link moves these a lot and nothing else does:
#   default  (DataFrames + Interpolations)     4 min 31 s   52 checks
#   --heavy  (+ Makie, with LD_LIBRARY_PATH)   9 min 48 s   78 checks
# Makie's own share of the second figure is 190 packages and 57 artifacts
# fetched twice over (stock Pkg's corpus copy, then ajt's from-empty depot);
# `ajt instantiate` is 28 s of it and `ajt precompile` 140 s.
# Both figures include stock Pkg building the corpus, which is roughly a third
# of the default tier. The per-target breakdown is printed at the end of every
# run.
#
# ---------------------------------------------------------------------------
# THIS GATE IS EXPECTED TO BE ABLE TO FAIL
# ---------------------------------------------------------------------------
# Two habits from the other harnesses, because both earned their place:
#
# NON-VACUITY. Every assertion here has a way of passing while testing
# nothing — an empty environment installs nothing and Pkg then finds nothing
# to do; a depot where ajt compiled zero packages has zero files for
# `Pkg.precompile()` to duplicate. So a target that installed nothing, or
# compiled nothing, is reported as INCONCLUSIVE and counted separately from
# both passes and failures, and the run exits 4 rather than 0.
#
# THE CONTROL. A precompile failure is not automatically an Ajt defect: a JLL
# whose shared library will not dlopen on this host fails identically under
# `Pkg.precompile()`. So on any failure, stock Pkg is asked to precompile the
# same environment in the depot it built itself, and the two failure sets are
# compared. Only what Ajt fails on and Pkg does not is a finding. This is the
# same rule the rest of the directory follows — Julia is the oracle, including
# about what "broken" means.
#
# BITE CHECKS. Non-vacuity is not the same as falsifiability: the detectors
# themselves could be wrong. So after the gates pass, each target's depot is
# deliberately broken and the same detectors are re-run:
#   * one package extension's cache directory is deleted, and
#     `Pkg.precompile()` must then write new files under `compiled/` — proving
#     the "zero new files" counter can go red, and that extensions are inside
#     what it counts;
#   * one installed package is deleted, and `is_instantiated` must go false
#     and `Pkg.instantiate()` must print a work line — proving the "did no
#     work" grep matches this Julia's actual output.
# Both run last, on a depot that is about to be thrown away.
#
# QUARANTINE. `--known-failing "A B"` (or the built-in list below) still RUNS
# the target and still prints every failure, but tallies them as `quar` rather
# than as failures, so a real, diagnosed, architectural defect can be landed
# visibly instead of being deleted from the corpus. A quarantined target that
# passes everything is itself reported as a finding: take it off the list.
#
# ---------------------------------------------------------------------------
# NOTHING HERE WRITES TO THE USER'S REAL DEPOT OR TO THE REPO
# ---------------------------------------------------------------------------
# Every environment and every depot is under $WORK, and every `julia` gets
# JULIA_DEPOT_PATH pointed there. The one ambient-depot read is the network
# probe, which is `--no-auth` precisely so it cannot refresh a token into the
# real depot's servers/*/auth.toml — and the baseline for that assertion is
# taken BEFORE the probe runs, or the check would be comparing two snapshots
# both taken after the only write it exists to catch. `servers/*/auth.toml` is
# snapshotted by name as well as by the depot's top level, because overwriting
# a file three levels down moves no ancestor's mtime.
#
# `ajt precompile` is given --no-cache. The shared precompile cache is a real
# feature and `$AJT_CACHE_URL` is read from the ambient environment, but a warm
# store turns compiles into `imported` and would let this whole harness pass
# having built nothing locally. The question here is what Pkg.precompile() does,
# and that is what --no-cache pins it to.
#
# Usage: foreign_e2e.sh [--heavy] [--targets "A B"] [--known-failing "A B"]
#                       [--jobs N] [--keep]
#   --heavy          add Makie (many minutes, hundreds of MB of artifacts)
#   --targets "A B"  replace the target set entirely
#   --known-failing  quarantine these targets: run and report, do not fail
#   --jobs N         ajt precompile concurrency (default: ajt's own default)
#   --keep           leave $WORK behind
#
# Exit: 0 all gates green · 1 a non-quarantined failure · 2 bad usage or a
#       broken prerequisite · 3 no target was gated · 4 green but INCONCLUSIVE
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"

FAST_TARGETS="DataFrames Interpolations"
HEAVY_TARGETS="Makie"
# Targets with a diagnosed defect that is too large to fix in place. Empty
# means "everything is expected to be green"; see the QUARANTINE note above.
KNOWN_FAILING=""

TARGETS=""
KEEP=0
HEAVY=0
JOBS=""
need() { [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --heavy) HEAVY=1; shift ;;
    --targets) need "$@"; TARGETS="$2"; shift 2 ;;
    --known-failing) need "$@"; KNOWN_FAILING="$2"; shift 2 ;;
    --jobs) need "$@"; JOBS="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$TARGETS" ]; then
  TARGETS="$FAST_TARGETS"
  [ $HEAVY -eq 1 ] && TARGETS="$TARGETS $HEAVY_TARGETS"
fi

# ---------------------------------------------------------------------------
# Prerequisites. A LOUD skip, never a red run: none of these says anything
# about src/ops/.
# ---------------------------------------------------------------------------
skip() {
  echo
  echo "########################################################################"
  echo "# SKIPPED: $1"
  printf '# %s\n' "${@:2}"
  echo "########################################################################"
  exit 0
}

command -v julia >/dev/null || skip "julia is not on PATH." \
  "Every gate here asks stock Julia whether it agrees there is nothing left" \
  "to do. There is no julia-less subset of that question."
command -v zig >/dev/null || skip "zig is not on PATH, so ajt cannot be built."

WORK="$(mktemp -d -t ajt-foreign-XXXXXX)"
# Pkg (and ajt, matching it) makes installed packages and artifacts read-only
# via `set_readonly`, so cleanup has to restore write bits first.
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
QUAR=0
INCONCLUSIVE=0
# How many targets got all the way through gate C. `PASS > 0` cannot stand in
# for "something was gated": the closing invariant checks always add two, so a
# run in which every target died in the corpus loop would still exit 0.
GATED=0
# Set per target, so `bad` knows whether this target's failures count.
QUARANTINED=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  {
  if [ $QUARANTINED -eq 1 ]; then
    QUAR=$((QUAR+1)); printf '  quar %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"
  fi
  [ $# -gt 1 ] && printf '       %s\n' "$2"
  return 0
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
note()  { printf '       %s\n' "$1"; }
incon() { INCONCLUSIVE=$((INCONCLUSIVE+1)); printf '  ??   INCONCLUSIVE: %s\n' "$1"; }

isQuarantined() { for k in $KNOWN_FAILING; do [ "$k" = "$1" ] && return 0; done; return 1; }

# A quarantine that has stopped being true is a lie the next reader inherits, so
# it is a hard failure — the same shape as resolve.sh's "FIXTURE IS STALE".
# Deferred rather than checked inline because a target can `continue` out of the
# loop from six places; this is flushed at the top of the next one and after the
# last.
PENDING_QUAR=""
PENDING_QUAR_AT=0
PENDING_INC_AT=0
flushQuarantine() {
  [ -n "$PENDING_QUAR" ] || return 0
  if [ "$QUAR" -eq "$PENDING_QUAR_AT" ] && [ "$INCONCLUSIVE" -eq "$PENDING_INC_AT" ]; then
    QUARANTINED=0
    bad "$PENDING_QUAR is on --known-failing but every gate passed" \
        "the quarantine is stale — take it off the list"
  fi
  PENDING_QUAR=""
}

# Every file under compiled/, sorted. The unit the M5 criterion is stated in.
cache_files() { find "$1/compiled" -type f 2>/dev/null | sort; }
# ...and the CONTENT of a FIXED list of them. `compilecache_path` mixes the
# active project, the julia binary, the sysimage, the cache flags, the CPU
# target and the preferences hash into one slug and nothing else
# (loading.jl:3152-3172), so a cache entry Julia decides to rebuild lands on the
# SAME path it was already on. Counting new paths therefore cannot see an
# in-place rebuild — which is precisely what "ajt wrote something Julia does not
# accept" looks like. Checksums can.
#
# The list is fixed rather than re-globbed on purpose: sums over "whatever is
# there now" also differ when files were merely ADDED, which would make the
# in-place signal indistinguishable from the new-file signal it exists to
# complement, and would report every gate-B failure twice under the wrong name.
# A path in the list that has since been deleted shows up as a missing line,
# which is also a change and is also worth failing on.
cache_sums_of() { xargs -r -d '\n' -a "$1" md5sum 2>/dev/null | sort -k2; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# The two things this harness must not disturb. Captured HERE, before the
# network probe, because the probe is the only thing in the file that touches
# the ambient depot at all — baselining after it would make the assertion
# structurally incapable of catching the one write it is aimed at.
git -C "$REPO_ROOT" status --porcelain > "$WORK/git.before" 2>/dev/null
AMBIENT="$(julia --startup-file=no -e 'print(first(Base.DEPOT_PATH))' 2>/dev/null)"
ambient_snapshot() {
  [ -n "$AMBIENT" ] || return 0
  find "$AMBIENT" -maxdepth 1 -printf '%p\t%T@\n' 2>/dev/null | sort
  # ...and the auth tokens by name. A refresh rewrites servers/<host>/auth.toml
  # three levels down, which moves no ancestor mtime and so is invisible above.
  find "$AMBIENT/servers" -name auth.toml -printf '%p\t%T@\t%s\n' 2>/dev/null | sort
}
ambient_snapshot > "$WORK/ambient.before"

# `--no-auth`: the ONE ajt call with no --depot, so it resolves to the ambient
# ~/.julia, and an authenticated GET against an expired token would REFRESH it.
"$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1 \
  || skip "no network (https://pkg.julialang.org unreachable)." \
     "Stock Pkg has to resolve and download real packages before there is" \
     "anything for ajt to instantiate. There is no offline subset."

JV="$(julia --startup-file=no -e 'print("v", VERSION.major, ".", VERSION.minor)')"
[ -n "$JV" ] || { echo "ERROR: could not ask julia for its version" >&2; exit 2; }
# Julia's private libdir — libgfortran/libquadmath/libgcc_s, the ones every
# Fortran JLL is built against. Only ever printed, as the remedy in the note a
# dlopen failure produces; see the LD_LIBRARY_PATH paragraph in the header.
JULIA_LIBDIR="$(julia --startup-file=no -e 'print(abspath(joinpath(Sys.BINDIR, "..", "lib", "julia")))')"

# The extension oracle. Ajt decides WHICH extensions are loadable nodes, but it
# cannot decide what each one is called: the uuid is `Base.uuid5(parent, name)`,
# a bespoke hash over Julia internals that is not RFC 4122. So the answer has to
# come from Julia, and this is `_precompilepkgs`' own model — `ExplicitEnv` plus
# `_collect_reachable!` — asked the same question ajt answers.
cat > "$WORK/ext_oracle.jl" <<'JL'
env = Base.Precompilation.ExplicitEnv(joinpath(ARGS[1], "Project.toml"))
pkgs = Set{Base.UUID}()
for (_, uuid) in env.project_deps
    Base.Precompilation._collect_reachable!(pkgs, env.deps, uuid)
end
out = String[]
for dep in pkgs
    haskey(env.deps, dep) || continue
    parent = Base.PkgId(dep, env.names[dep])
    Base.in_sysimage(parent) && continue
    for (ext, triggers) in get(Dict{String,Vector{Base.UUID}}, env.extensions, dep)
        all(t -> t in pkgs, triggers) || continue
        push!(out, string(parent.name, "\t", ext, "\t", Base.uuid5(parent.uuid, ext)))
    end
end
print(join(sort(out), "\n"))
JL

# ---------------------------------------------------------------------------
# The corpus. ONE depot, stock Pkg's, shared by every target so a dependency
# two of them have in common is downloaded once. Ajt never touches it: it is
# only ever the thing that WROTE the Project/Manifest pair.
# ---------------------------------------------------------------------------
echo
echo "==> the corpus: stock Pkg resolves every target, into its own depot"
PKG_DEPOT="$WORK/depot-corpus"
mkdir -p "$PKG_DEPOT"
env JULIA_DEPOT_PATH="$PKG_DEPOT" julia --startup-file=no \
  -e 'using Pkg; Pkg.Registry.add("General")' >"$WORK/registry.log" 2>&1 || {
  echo "ERROR: could not install the General registry" >&2
  tail -10 "$WORK/registry.log" >&2; exit 2; }
echo "  registry installed"

RUN_TARGETS=""
for t in $TARGETS; do
  E="$WORK/env-$t"
  mkdir -p "$E"
  QUARANTINED=0
  isQuarantined "$t" && QUARANTINED=1
  T0=$(date +%s%N)
  if ! env JULIA_DEPOT_PATH="$PKG_DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
       julia --startup-file=no --project="$E" -e "using Pkg; Pkg.add(\"$t\")" \
       >"$WORK/$t.corpus.log" 2>&1; then
    bad "$t: stock Pkg could not resolve it, so there is nothing to gate" \
        "$(tail -3 "$WORK/$t.corpus.log" | tr '\n' '|')"
    continue
  fi
  T1=$(date +%s%N)
  N="$(grep -c '^\[\[deps\.' "$E/Manifest.toml" 2>/dev/null)"
  echo "  $t: $N entries  ($(( (T1 - T0) / 1000000000 ))s)"
  RUN_TARGETS="$RUN_TARGETS $t"
done

SUMMARY_LINES=""
# Whether ANY target in this run installed an artifact. `is_instantiated` also
# runs `check_artifacts_downloaded` (Operations.jl:1083-1094), and on a target
# with no artifacts that half of gate A passes without testing anything.
TOTAL_ARTS=0

# ===========================================================================
for TARGET in $RUN_TARGETS; do
# ===========================================================================
flushQuarantine
QUARANTINED=0
if isQuarantined "$TARGET"; then
  QUARANTINED=1
  PENDING_QUAR="$TARGET"; PENDING_QUAR_AT=$QUAR; PENDING_INC_AT=$INCONCLUSIVE
fi

echo
echo "======================================================================"
if [ $QUARANTINED -eq 1 ]; then
  echo "==> $TARGET   [QUARANTINED — failures are reported, not counted]"
else
  echo "==> $TARGET"
fi
echo "======================================================================"

ENV_DIR="$WORK/env-$TARGET"
DEPOT="$WORK/depot-$TARGET"
mkdir -p "$DEPOT"
T_INST=0; T_PRE=0

# The environment must be big enough to mean something. A three-entry manifest
# would pass every gate below and prove nothing about a real dependency graph.
ENTRIES="$(grep -c '^\[\[deps\.' "$ENV_DIR/Manifest.toml" 2>/dev/null)"
if [ "${ENTRIES:-0}" -lt 20 ]; then
  incon "$TARGET: only ${ENTRIES:-0} manifest entries — too small to gate anything"
  SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: INCONCLUSIVE — ${ENTRIES:-0} manifest entries is too small"
  continue
fi
# And it must be the shape `Pkg.add` produces, not a package: that is the shape
# `instantiate`/`precompile` had never been run on before this file existed.
if grep -q '^name *=' "$ENV_DIR/Project.toml"; then
  note "note: this environment is a PACKAGE, not a bare [deps] environment"
else
  ok "$TARGET: a bare [deps] environment, as \`Pkg.add\` writes them ($ENTRIES entries)"
fi

# -------------------------------------------------------------------------
echo
echo "  --- ajt instantiate --frozen, into an EMPTY depot ---"
# Empty means empty: no registry either, so the run has to fetch one. The
# assertion is about a depot ajt built from nothing, and a borrowed registry
# would be state it did not create.
check "the depot starts empty" "0" "$(find "$DEPOT" -mindepth 1 2>/dev/null | wc -l)"

# Pkg's bytes, before ajt is allowed near them. `--frozen` is not read-only:
# it writes the fixups (weakdeps/extensions/entryfile, read out of each
# INSTALLED package's own Project.toml) back into the manifest.
mkdir -p "$WORK/$TARGET.orig"
cp "$ENV_DIR/Project.toml" "$ENV_DIR/Manifest.toml" "$WORK/$TARGET.orig/"

# --no-precompile is load-bearing, not an optimisation: instantiate grew
# Pkg's auto-precompile pass (the autoprecompile unit), and left on it would
# compile the whole environment HERE — the later "ajt precompile" phase then
# finds zero stale nodes and gate B (Pkg.precompile writes nothing) goes
# green over a run that proved nothing. This file's claim structure is the
# two phases separately; the auto-pass has its own gate
# (autoprecompile.sh).
T0=$(date +%s%N)
"$AJT" instantiate --frozen --no-precompile --depot "$DEPOT" "$ENV_DIR" \
  >"$WORK/$TARGET.inst.out" 2>"$WORK/$TARGET.inst.err"
RC=$?
T1=$(date +%s%N)
T_INST=$(( (T1 - T0) / 1000000000 ))
check "ajt instantiate --frozen succeeds" "0" "$RC"
if [ $RC -ne 0 ]; then
  tail -20 "$WORK/$TARGET.inst.err" | sed 's/^/       /'
  SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: instantiate FAILED"
  continue
fi
note "ajt instantiate: ${T_INST}s"

# summary <entries> <pruned> <pkg-jobs> <pkg-installed> <art-jobs> <art-installed> <ms>
read -r _ _ _ _ S_PKGS _ S_ARTS _ <<EOF
$(grep '^summary' "$WORK/$TARGET.inst.out")
EOF
# NON-VACUITY. A run that installed nothing makes every gate below trivially
# true, and that is exactly what a broken installer looks like from outside.
if [ "${S_PKGS:-0}" -lt 1 ]; then
  incon "$TARGET: ajt installed 0 packages — every gate below would be vacuous"
  tail -10 "$WORK/$TARGET.inst.err" | sed 's/^/       /'
  SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: INCONCLUSIVE — ajt installed nothing"
  continue
fi
ok "$TARGET: ajt installed $S_PKGS packages and $S_ARTS artifacts from empty"
TOTAL_ARTS=$((TOTAL_ARTS + ${S_ARTS:-0}))

# A gate-1-equivalent, on a manifest Ajt did not write. `fallback_gates.sh`
# asserts this byte-stability for Open-Reality, whose manifest is hand-carried;
# here the manifest is one stock Pkg produced seconds ago, so there is by
# definition nothing for the fixups pass to change, and any diff is Ajt's
# writer disagreeing with Pkg's on an environment nobody tuned for.
for f in Project.toml Manifest.toml; do
  if cmp -s "$WORK/$TARGET.orig/$f" "$ENV_DIR/$f"; then
    ok "$TARGET: $f is byte-identical to what stock Pkg wrote"
  else
    bad "$TARGET: $f CHANGED — ajt's writer diverges from Pkg's on a foreign env" \
        "$(diff "$WORK/$TARGET.orig/$f" "$ENV_DIR/$f" | head -8 | tr '\n' '|')"
  fi
done
# ...and "unchanged" rather than "written", so the bytes above are the result
# of a fixups pass that RAN and found nothing, not of one that never looked.
check "$TARGET: the fixups pass ran and found nothing to change" "unchanged" \
  "$(grep -E '^manifest' "$WORK/$TARGET.inst.out" | head -1 | cut -f2)"

# -------------------------------------------------------------------------
echo
echo "  --- GATE A: stock Pkg must find nothing to install ---"
# PRECOMPILE_AUTO=0: a cold Pkg.instantiate() would also precompile the whole
# environment, which is minutes of work and says nothing about whether Pkg
# wants to INSTALL anything, which is the question.
env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
  >"$WORK/$TARGET.pkginst.out" 2>&1
PKG_RC=$?
check "Pkg.instantiate() succeeds on the depot ajt built" "0" "$PKG_RC"
[ $PKG_RC -eq 0 ] || tail -20 "$WORK/$TARGET.pkginst.out" | sed 's/^/       /'

WORK_RE='^ *(Installed|Downloaded|Updating|Added|Cloning|Building) '
if grep -Eq "$WORK_RE" "$WORK/$TARGET.pkginst.out"; then
  bad "$TARGET: Pkg.instantiate() did work — ajt's depot was incomplete" \
      "$(grep -E "$WORK_RE" "$WORK/$TARGET.pkginst.out" | head -5 | tr '\n' '|')"
else
  ok "$TARGET: Pkg.instantiate() installed, downloaded and updated NOTHING"
fi

# The predicate itself, which also covers artifacts (`check_artifacts_downloaded`,
# Operations.jl:1083-1094) that `ajt verify` deliberately does not check.
J_INST="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e '
  using Pkg
  print(Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' \
  "$ENV_DIR" 2>"$WORK/$TARGET.isinst.err")"
check "$TARGET: Pkg.Operations.is_instantiated agrees (artifacts included)" "true" "${J_INST:-}"
[ -n "${J_INST:-}" ] || tail -5 "$WORK/$TARGET.isinst.err" | sed 's/^/       /'

# Self-sufficiency: nothing above can have been borrowed from ~/.julia.
check "$TARGET: DEPOT_PATH is the temp depot alone" "[\"$DEPOT\"]" \
  "$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e 'print(DEPOT_PATH)')"

# -------------------------------------------------------------------------
echo
echo "  --- ajt precompile ---"
# The extension set, against Julia's own answer, BEFORE anything is compiled:
# if ajt's node set is wrong, gate B's number is the symptom and this is the
# diagnosis.
env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no "$WORK/ext_oracle.jl" "$ENV_DIR" \
  2>"$WORK/$TARGET.ext.err" | sed '/^$/d' | LC_ALL=C sort > "$WORK/$TARGET.ext.oracle"
EXT_ORACLE_N="$(grep -c . "$WORK/$TARGET.ext.oracle" || true)"
# `ExplicitEnv` and `_collect_reachable!` are private Base.Precompilation API.
# If either moves, the oracle comes back EMPTY, and an empty oracle compared
# against an ajt that also found nothing is a green tick over a dead check.
# So the probe erroring is itself a failure, stated separately.
if [ -s "$WORK/$TARGET.ext.err" ]; then
  bad "$TARGET: the extension oracle errored — Base.Precompilation's private API moved" \
      "$(head -3 "$WORK/$TARGET.ext.err" | tr '\n' '|')"
fi

T0=$(date +%s%N)
# --no-cache: see the header. $AJT_CACHE_URL is ambient, and a warm shared store
# would turn every compile into an `imported` and leave this harness asserting
# nothing about a depot ajt actually built.
env JULIA_DEPOT_PATH="$DEPOT" \
  "$AJT" precompile --depot "$DEPOT" --no-cache ${JOBS:+--jobs "$JOBS"} "$ENV_DIR" \
  >"$WORK/$TARGET.pre.out" 2>"$WORK/$TARGET.pre.err"
PRE_RC=$?
T1=$(date +%s%N)
T_PRE=$(( (T1 - T0) / 1000000000 ))
note "ajt precompile: ${T_PRE}s"

read -r _ P_CONSIDERED P_COMPILED _ P_STALE _ P_FAILED _ <<EOF
$(awk -F'\t' '$1=="summary"' "$WORK/$TARGET.pre.out")
EOF

# --- THE CONTROL -----------------------------------------------------------
# Before any of this is called an Ajt defect, ask the oracle. A package that
# will not precompile on THIS HOST — a JLL whose shared library cannot be
# dlopen'd, say — fails identically under `Pkg.precompile()`, and reporting
# that as a red gate would be blaming Ajt for the machine. So on any failure,
# stock Pkg precompiles the same environment in the depot IT built, and the
# two failure sets are compared. Only what Ajt fails on and Pkg does not is a
# finding; a match is INCONCLUSIVE, which is what it honestly is.
#
# This costs nothing on a green run: it is on the failure path only.
if [ $PRE_RC -ne 0 ] || [ "${P_FAILED:-0}" != "0" ] || [ "${P_STALE:-0}" != "0" ]; then
  echo "  ...something did not compile. Asking stock Pkg whether it can, on this host."
  # Everything that is NOT an outcome meaning "this node has a usable cache" or
  # "Pkg would never compile it either". Stated as the complement on purpose:
  # enumerating the bad outcomes instead left `unknown`, and an extension's
  # `source_missing`, out of the set, so a run made of those would trigger the
  # control, collect nothing, and then be called red WITHOUT the control's
  # answer being consulted — the exact outcome this block exists to prevent.
  awk -F'\t' '
    $1 != "package" && $1 != "extension" { next }
    $2 == "compiled" || $2 == "already_precompiled" || $2 == "waited" ||
    $2 == "imported" || $2 == "in_sysimage" || $2 == "not_precompilable" { next }
    { print ($1 == "extension") ? $4 : $3 }
  ' "$WORK/$TARGET.pre.out" | LC_ALL=C sort -u > "$WORK/$TARGET.ajt.bad"

  env JULIA_DEPOT_PATH="$PKG_DEPOT" julia --startup-file=no --project="$ENV_DIR" \
    -e 'using Pkg; Pkg.precompile()' >"$WORK/$TARGET.control.out" 2>&1
  # `✗ Foo` and `✗ Foo → FooBarExt`; the leaf name is what both sides call it.
  grep '✗' "$WORK/$TARGET.control.out" | sed 's/.*✗ //; s/.* → //; s/[[:space:]]*$//' \
    | LC_ALL=C sort -u > "$WORK/$TARGET.pkg.bad"

  AJT_BAD_N="$(grep -c . "$WORK/$TARGET.ajt.bad" || true)"
  PKG_BAD_N="$(grep -c . "$WORK/$TARGET.pkg.bad" || true)"
  ONLY_AJT="$(comm -23 "$WORK/$TARGET.ajt.bad" "$WORK/$TARGET.pkg.bad")"

  if [ "$AJT_BAD_N" -gt 0 ] && [ "$PKG_BAD_N" -gt 0 ] && [ -z "$ONLY_AJT" ]; then
    incon "$TARGET: stock Pkg cannot precompile this environment on this host either"
    note "ajt could not compile: $(tr '\n' ' ' < "$WORK/$TARGET.ajt.bad")"
    note "Pkg could not compile: $(tr '\n' ' ' < "$WORK/$TARGET.pkg.bad")"
    note "$(grep -m1 -E 'InitError|could not load|ERROR: LoadError' "$WORK/$TARGET.control.out" | cut -c1-160)"
    note "this target is not a usable gate on this machine; it says nothing about ajt"
    if grep -q 'could not load library' "$WORK/$TARGET.control.out"; then
      note "a JLL could not dlopen. If the missing name is one julia ships"
      note "($(ls "$JULIA_LIBDIR" 2>/dev/null | tr '\n' ' ' | cut -c1-90)...),"
      note "the loader is resolving the artifact's DT_NEEDED through the ARTIFACT's"
      note "rpath, not julia's, and this run fixes it:"
      note "  LD_LIBRARY_PATH=$JULIA_LIBDIR $0 --targets $TARGET"
    fi
    SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: INCONCLUSIVE — stock Pkg fails here too ($(tr '\n' ' ' < "$WORK/$TARGET.pkg.bad"))"
    continue
  fi

  # NOT a `bad`: the three checks immediately below already count this target's
  # failure, and reporting it here too made one broken target worth four.
  note "the control does NOT exonerate this one. Only ajt failed on:"
  note "  $(printf '%s' "${ONLY_AJT:-<nothing — ajt exited $PRE_RC with no per-node record>}" | tr '\n' ' ')"
  note "Pkg's own failures were: $(tr '\n' ' ' < "$WORK/$TARGET.pkg.bad")"
  tail -25 "$WORK/$TARGET.pre.err" | sed 's/^/       /'
fi

check "ajt precompile succeeds" "0" "$PRE_RC"
check "$TARGET: nothing failed to compile" "0" "${P_FAILED:-}"
[ "${P_FAILED:-0}" = "0" ] || \
  awk -F'\t' '$2=="failed" || $2=="source_missing"' "$WORK/$TARGET.pre.out" | head -8 | sed 's/^/       /'
check "$TARGET: nothing was left planned-but-uncompiled" "0" "${P_STALE:-}"

# NON-VACUITY, again: gate B counts new files, and zero of them is trivial on a
# depot where nothing was compiled in the first place.
if [ "${P_COMPILED:-0}" -lt 1 ]; then
  incon "$TARGET: ajt compiled 0 of $P_CONSIDERED nodes — gate B would be vacuous"
  SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: INCONCLUSIVE — nothing was compiled"
  continue
fi
ok "$TARGET: ajt compiled $P_COMPILED of $P_CONSIDERED nodes"

# The extension comparison. The oracle is Julia's; this is the whole triple,
# parent + name + uuid, not a count.
awk -F'\t' '$1=="extension" {print $3 "\t" $4 "\t" $5}' "$WORK/$TARGET.pre.out" \
  | LC_ALL=C sort > "$WORK/$TARGET.ext.ajt"
if diff -u "$WORK/$TARGET.ext.oracle" "$WORK/$TARGET.ext.ajt" > "$WORK/$TARGET.ext.diff" 2>&1; then
  ok "$TARGET: the extension set matches Julia's exactly ($EXT_ORACLE_N: parent, name, uuid)"
else
  bad "$TARGET: ajt's extension node set differs from Julia's" \
      "$(sed -n '4,12p' "$WORK/$TARGET.ext.diff" | tr '\n' '|')"
fi
# `waited` (another process held the pidlock and produced the entry) and
# `imported` (a shared-cache hit) are cache-bearing outcomes too. --no-cache
# rules the second out here, but a whitelist that calls a correct outcome a
# failure is a trap for whoever runs this without it.
check "$TARGET: every extension node reached a cache" "0" \
  "$(awk -F'\t' '$1=="extension" && $2!="compiled" && $2!="already_precompiled" &&
                 $2!="waited" && $2!="imported"' "$WORK/$TARGET.pre.out" | wc -l)"

# -------------------------------------------------------------------------
echo
echo "  --- GATE B: Pkg.precompile() must write ZERO new files ---"
cache_files "$DEPOT" > "$WORK/$TARGET.cc.before"
cache_sums_of "$WORK/$TARGET.cc.before" > "$WORK/$TARGET.sum.before"
CC_BEFORE="$(grep -c . "$WORK/$TARGET.cc.before" || true)"
if [ "$CC_BEFORE" -lt 1 ]; then
  incon "$TARGET: compiled/ is empty after ajt precompile — gate B is vacuous"
  SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: INCONCLUSIVE — compiled/ was empty"
  continue
fi

env JULIA_DEPOT_PATH="$DEPOT" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
  >"$WORK/$TARGET.pkgpre.out" 2>&1
PC_RC=$?
cache_files "$DEPOT" > "$WORK/$TARGET.cc.after"
# Sums over the SAME path list both times, so "added" and "rewritten" stay two
# separate answers.
cache_sums_of "$WORK/$TARGET.cc.before" > "$WORK/$TARGET.sum.after"
check "Pkg.precompile() succeeds on the depot ajt built" "0" "$PC_RC"
[ $PC_RC -eq 0 ] || tail -25 "$WORK/$TARGET.pkgpre.out" | sed 's/^/       /'

# THE M5 ACCEPTANCE CRITERION. Not "roughly the same size": zero new files.
NEW_N="$(comm -13 "$WORK/$TARGET.cc.before" "$WORK/$TARGET.cc.after" | grep -c . || true)"
check "$TARGET: Pkg.precompile() wrote NO new file under compiled/" "0" "$NEW_N"
[ "$NEW_N" -eq 0 ] || comm -13 "$WORK/$TARGET.cc.before" "$WORK/$TARGET.cc.after" |
  sed "s|$DEPOT/compiled/||" | head -20 | sed 's/^/       /'

# ...and none IN PLACE either, which counting paths cannot see (see cache_sums_of).
if diff -q "$WORK/$TARGET.sum.before" "$WORK/$TARGET.sum.after" >/dev/null; then
  ok "$TARGET: ...and rewrote none of the $CC_BEFORE existing ones"
else
  bad "$TARGET: Pkg.precompile() REWROTE or REMOVED a cache entry ajt had written" \
      "$(diff "$WORK/$TARGET.sum.before" "$WORK/$TARGET.sum.after" | grep '^[<>]' |
         sed "s|.*$DEPOT/compiled/||" | sort -u | head -8 | tr '\n' '|')"
fi
EXT_AJT_N="$(awk -F'\t' '$1=="extension"' "$WORK/$TARGET.pre.out" | wc -l)"
note "compiled/ holds $CC_BEFORE files; $EXT_AJT_N of the nodes ajt walked were extensions"

# -------------------------------------------------------------------------
echo
echo "  --- GATE C: \`using $TARGET\` loads out of it, Pkg never invoked ---"
# No `using Pkg` anywhere in the command, and then the question of whether it
# arrived some other way.
LOADED="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no --project="$ENV_DIR" \
  -e "using $TARGET; print(any(m -> m.name == \"Pkg\", keys(Base.loaded_modules)) ? \"pkg-was-loaded\" : \"ok\")" \
  2>"$WORK/$TARGET.load.err")"
case "${LOADED:-}" in
  ok)
    ok "$TARGET: \`using $TARGET\` succeeds and Pkg was never loaded" ;;
  pkg-was-loaded)
    # NOT automatically a finding, and this gate said it was until Makie
    # disagreed. Julia's loader never reaches for Pkg on its own in a
    # non-interactive session — `Base.require` has no such path — so `Pkg` in
    # `loaded_modules` can only mean something in the closure DECLARES it and
    # `using`s it, which is an ordinary library dependency. What WOULD be a
    # finding is Pkg turning up with no manifest entry behind it.
    if grep -q '^\[\[deps\.Pkg\]\]' "$ENV_DIR/Manifest.toml"; then
      ok "$TARGET: \`using $TARGET\` succeeds; Pkg loads as a declared dependency, not as a repair"
      note "why Pkg: $("$AJT" why --project "$ENV_DIR" Pkg 2>/dev/null | head -2 | sed 's/^ *//' | tr '\n' '|')"
    else
      bad "$TARGET: Pkg was loaded and the manifest has no Pkg entry" \
          "nothing declares it, so the loader reached for it — which is the failure this asks about"
    fi ;;
  *)
    bad "$TARGET: \`using $TARGET\` failed against the depot ajt built" \
        "$(tail -3 "$WORK/$TARGET.load.err" | tr '\n' '|')"
    tail -12 "$WORK/$TARGET.load.err" | sed 's/^/       /' ;;
esac
cache_files "$DEPOT" > "$WORK/$TARGET.cc.load"
cache_sums_of "$WORK/$TARGET.cc.before" > "$WORK/$TARGET.sum.load"
if diff -q "$WORK/$TARGET.cc.after" "$WORK/$TARGET.cc.load" >/dev/null \
   && diff -q "$WORK/$TARGET.sum.after" "$WORK/$TARGET.sum.load" >/dev/null; then
  ok "$TARGET: ...and loading it wrote no cache file either"
else
  bad "$TARGET: loading it compiled something — the cache ajt built is not what \`using\` wants" \
      "$(diff "$WORK/$TARGET.cc.after" "$WORK/$TARGET.cc.load" | head -6 | tr '\n' '|')"
fi
GATED=$((GATED+1))

# -------------------------------------------------------------------------
echo
echo "  --- the bite checks: break the depot, the detectors must go red ---"
# From here the depot is deliberately damaged. Nothing may run after this.

# (1) The "zero new files" counter. Delete one extension's cache directory —
# extensions are leaves, so nothing else is invalidated — and Pkg.precompile()
# must now have something to write. If it does not, the count above was not
# measuring what it claims to.
EXT_DIR=""
if [ "$EXT_ORACLE_N" -gt 0 ]; then
  EXT_NAME="$(head -1 "$WORK/$TARGET.ext.oracle" | cut -f2)"
  EXT_DIR="$DEPOT/compiled/$JV/$EXT_NAME"
fi
if [ -n "$EXT_DIR" ] && [ -d "$EXT_DIR" ]; then
  chmod -R u+w "$EXT_DIR" 2>/dev/null
  rm -rf "$EXT_DIR"
  # The baseline is the DAMAGED depot, not the healthy one. Julia rebuilds a
  # cache entry onto the same path it was on, so measuring the rebuild against
  # the pre-deletion listing would count zero new files and call a working
  # detector broken — which is exactly what the first draft of this check did.
  cache_files "$DEPOT" > "$WORK/$TARGET.cc.damaged"
  env JULIA_DEPOT_PATH="$DEPOT" \
    julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
    >"$WORK/$TARGET.bite1.out" 2>&1
  BITE_N="$(cache_files "$DEPOT" | comm -13 "$WORK/$TARGET.cc.damaged" - | grep -c . || true)"
  if [ "$BITE_N" -gt 0 ]; then
    ok "$TARGET: deleting $EXT_NAME's cache makes Pkg.precompile() write $BITE_N file(s) — the counter bites"
  else
    bad "$TARGET: Pkg.precompile() wrote nothing even with $EXT_NAME's cache deleted" \
        "gate B cannot go red, so its zero means nothing"
    tail -10 "$WORK/$TARGET.bite1.out" | sed 's/^/       /'
  fi
elif [ "$EXT_ORACLE_N" -gt 0 ]; then
  bad "$TARGET: no cache directory for $EXT_NAME — ajt reported it but never wrote it"
else
  # Counted, not merely noted. Without this bite, gate B's zero is a number
  # nobody has ever seen go up, and a silent `note` would let that disappear
  # from the tally entirely.
  incon "$TARGET: no loadable extension here, so gate B's counter was never shown to bite"
fi

# (2) The "did no work" grep and `is_instantiated`. Delete the smallest
# installed package and require BOTH detectors to notice.
VICTIM="$(find "$DEPOT/packages" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
  | while read -r d; do printf '%s\t%s\n' "$(du -s "$d" 2>/dev/null | cut -f1)" "$d"; done \
  | sort -n | head -1 | cut -f2)"
if [ -n "$VICTIM" ]; then
  chmod -R u+w "$VICTIM" 2>/dev/null
  rm -rf "$VICTIM"
  J_INST2="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e '
    using Pkg
    print(Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' \
    "$ENV_DIR" 2>/dev/null)"
  check "$TARGET: removing $(basename "$(dirname "$VICTIM")") makes is_instantiated false" "false" "${J_INST2:-}"
  env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
    julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.instantiate()' \
    >"$WORK/$TARGET.bite2.out" 2>&1
  if grep -Eq "$WORK_RE" "$WORK/$TARGET.bite2.out"; then
    ok "$TARGET: ...and Pkg.instantiate() prints a work line — the gate-A grep bites"
  else
    bad "$TARGET: Pkg.instantiate() printed no work line for a package it had to reinstall" \
        "the gate-A grep matches nothing on this Julia, so its silence proves nothing"
    tail -10 "$WORK/$TARGET.bite2.out" | sed 's/^/       /'
  fi
else
  bad "$TARGET: no installed package found to remove — the gate-A bite could not run"
fi

SUMMARY_LINES="$SUMMARY_LINES
  $TARGET: $ENTRIES entries, $S_PKGS packages + $S_ARTS artifacts installed, $P_COMPILED compiled ($EXT_AJT_N ext) — instantiate ${T_INST}s, precompile ${T_PRE}s"

done
# ===========================================================================
flushQuarantine
QUARANTINED=0

echo
echo "==> coverage this run did NOT have"
if [ "$TOTAL_ARTS" -gt 0 ]; then
  ok "$TOTAL_ARTS artifacts were installed, so gate A's check_artifacts_downloaded half was live"
else
  note "no target installed an artifact, so the artifact half of gate A"
  note "(check_artifacts_downloaded) passed without testing anything. Run --heavy,"
  note "or --targets Distributions on a host whose OpenSpecFun_jll loads."
fi

echo
echo "==> the harness itself touched nothing it should not have"
git -C "$REPO_ROOT" status --porcelain > "$WORK/git.after" 2>/dev/null
if diff -q "$WORK/git.before" "$WORK/git.after" >/dev/null; then
  ok "the repo is exactly as it was"
else
  bad "the harness modified the repo" \
      "$(diff "$WORK/git.before" "$WORK/git.after" | head -5 | tr '\n' '|')"
fi
if [ -n "$AMBIENT" ]; then
  ambient_snapshot > "$WORK/ambient.after"
  if diff -q "$WORK/ambient.before" "$WORK/ambient.after" >/dev/null; then
    ok "the real depot is untouched, auth tokens included ($AMBIENT)"
  else
    bad "the harness wrote into the real depot" \
        "$(diff "$WORK/ambient.before" "$WORK/ambient.after" | head -5 | tr '\n' '|')"
  fi
fi

echo
echo "======================================================================"
printf 'per target:%s\n' "$SUMMARY_LINES"
echo "======================================================================"
printf 'foreign e2e: %d passed, %d failed, %d quarantined, %d inconclusive  (%d of %d targets fully gated)\n' \
  "$PASS" "$FAIL" "$QUAR" "$INCONCLUSIVE" "$GATED" "$(printf '%s\n' $TARGETS | grep -c .)"
[ $QUAR -eq 0 ] || echo "  (quarantined targets: $KNOWN_FAILING — see the PR body for the diagnosis)"
[ $FAIL -eq 0 ] || exit 1
# NOT `PASS > 0`: the two closing invariant checks always pass, so a run in
# which every target fell out before gate C would otherwise look green.
[ $GATED -gt 0 ] || { echo "NO TARGET WAS GATED — this run asserted nothing about the pipeline"; exit 3; }
[ $INCONCLUSIVE -eq 0 ] || exit 4
exit 0
