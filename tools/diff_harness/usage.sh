#!/usr/bin/env bash
# End-to-end gate for the depot usage logs (src/ops/usage.zig).
#
# `Pkg.gc()` reads `<depot>/logs/{manifest,artifact}_usage.toml` and nothing
# else to decide what in a depot is reachable. Everything not reachable from an
# index file that is BOTH logged AND still on disk is orphaned and, after
# `collect_delay`, deleted (`Pkg/src/API.jl:638-707`, `:900-910`). So a depot
# Ajt filled and Julia never independently touched is, to `Pkg.gc()`, garbage.
#
# Five sections, in increasing order of how much they prove:
#
#   1. SHAPE. Julia installs a package with artifacts into a seed depot; Ajt
#      installs the same manifest into its own. Both logs are normalised (depot
#      root -> <DEPOT>, the whole `time` value -> <TIME>) and diffed. The
#      timestamps are DELIBERATELY not compared for equality -- they are wall
#      clock and can never match -- so they are checked separately, for FORMAT
#      (`YYYY-mm-ddTHH:MM:SS.sssZ`, exactly three fractional digits) and for
#      being within a few minutes of `Dates.now()`, which is what catches a
#      UTC-for-local slip that a shape diff would sail straight past.
#
#   2. INTEROP. Ajt's log is fed to Julia's own `write_env_usage`, and Julia's
#      log is fed back to Ajt. Each must extend the other's file without
#      duplicating, dropping or corrupting a key, and `Pkg.gc()`'s own reducer
#      must read every key back out.
#
#   3. THE GATE THAT MATTERS. Ajt installs into a scratch depot, then
#      `Pkg.gc(collect_delay = Second(0))` runs against it. The packages and
#      artifacts must still be there. Then the usage logs are DELETED and the
#      same gc is run again -- and now they must be gone. A gate that cannot
#      fail is worse than none, so the second half is not optional.
#
#   4. REGISTRY OPERATIONS RECORD NOTHING. Pkg's registry paths never build an
#      `EnvCache`, so `Registry.add`/`update`/`status` leave the logs untouched
#      even when a Manifest exists. Ajt matches. Asserted on both sides rather
#      than asserted of Ajt alone.
#
#   5. THE USER'S REAL DEPOT WAS NOT WRITTEN. Every path this harness creates
#      lives under $WORK, so if any of it leaked into ~/.julia it would show up
#      as a $WORK-prefixed key there.
#
#      What that check can and cannot see, stated plainly: a $WORK key is
#      unambiguous evidence of a leak, but its ABSENCE is not proof of none --
#      it does not cover `packages/`, `artifacts/` or `registries/`. Checking
#      mtimes instead would be worse, not better: any other `julia` running on
#      the machine touches ~/.julia, so it would fail for reasons that have
#      nothing to do with this change.
#
# ~/.julia is READ ONLY here, and that is enforced rather than asserted: every
# `julia` invocation below runs under a JULIA_DEPOT_PATH whose FIRST entry is a
# scratch depot, so precompilation output (`compiled/*.ji`) lands there. Only
# reads reach ~/.julia -- the General registry, so a scratch depot does not
# have to download one, and the warm precompile cache, so the oracle helpers
# are fast.
#
# Exit codes: 0 all checks passed, 1 a check failed, 3 the network-dependent
# sections (2-4) were SKIPPED. 3 rather than 0 on purpose -- sections 2-4 are
# where every claim about `Pkg.gc()` lives, and a run that silently reports
# success without them would be the "gate that cannot fail" this file exists
# to avoid.
#
# Usage: tools/diff_harness/usage.sh [--keep]
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
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT" ] || { echo "ERROR: $AJT missing — run 'zig build' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-usage-XXXXXX)"
cleanup() { [ $KEEP -eq 0 ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

mkdir -p "$WORK/oracle"

# ---------------------------------------------------------------------------
# Oracles
# ---------------------------------------------------------------------------
# EVERY julia invocation goes through this. `$WORK/oracle` first means any
# `compiled/*.ji` Julia decides to write lands in the scratch depot;
# `$HOST_DEPOT` second means the already-warm caches there are still READ, so
# these stay fast. Calling bare `julia` here would precompile TOML and Pkg
# into the user's real depot -- a write, and one that makes the "read only"
# claim in the header false.
jl() { JULIA_DEPOT_PATH="$WORK/oracle:$HOST_DEPOT" julia --startup-file=no "$@"; }

# Every key in a usage log, one per line, read the way `gc`'s `reduce_usage!`
# reads it (`API.jl:621-652`) rather than by grepping the text.
usage_keys() {
  [ -f "$1" ] || return 0
  jl -e '
using TOML
d = TOML.parsefile(ARGS[1])
for k in sort(collect(keys(d)))
    println(k)
end' "$1"
}
# How many entries each key holds. `write_env_usage` condenses every key to
# exactly one (`Types.jl:701-713`); anything else means the file grew.
usage_entry_counts() {
  [ -f "$1" ] || return 0
  jl -e '
using TOML
d = TOML.parsefile(ARGS[1])
for k in sort(collect(keys(d)))
    v = d[k]
    println(k, "\t", v isa Vector ? length(v) : -1)
end' "$1"
}
# The `time` value of one key, as Julia parses it -- proving it is a DateTime
# and not a string that happens to look like one.
usage_time() {
  jl -e '
using TOML, Dates
d = TOML.parsefile(ARGS[1])
print(DateTime(d[ARGS[2]][1]["time"]))' "$1" "$2"
}
inventory() { # inventory <depot> -> sorted "packages/<Name>/<slug>" + "artifacts/<hash>"
  { [ -d "$1/packages" ] && (cd "$1" && find packages -mindepth 2 -maxdepth 2 -type d)
    [ -d "$1/artifacts" ] && (cd "$1" && find artifacts -mindepth 1 -maxdepth 1 -type d)
  } 2>/dev/null | sort
}
# `collect_delay = Second(0)` is load-bearing, not belt-and-braces. On the
# FIRST orphaning `merge_orphanages!` sets `free_time = gc_time` (`API.jl:876-890`,
# reading `orphaned.toml`, never a usage timestamp), so `gc_time - free_time`
# is 0 and the default `Day(7)` deletes nothing at all — one `Pkg.gc()` would
# "prove" the logs work no matter how broken they were.
#
# The depot is passed ALONE: gc only collects `depots1()` unless `force=true`
# (`API.jl:600`), so the scratch depot has to be entry 0. That does mean Pkg
# precompiles into it, which is why this is the one helper that cannot go
# through `jl`.
gc_now() { # gc_now <depot>
  JULIA_DEPOT_PATH="$1" julia --startup-file=no -e \
    'using Pkg, Dates; Pkg.gc(collect_delay = Second(0))' 2>&1
}

NETWORK=1
curl -sfI --max-time 15 -o /dev/null https://pkg.julialang.org/registries || NETWORK=0

# ===========================================================================
echo "==> 0. the writer, standalone (no network)"
# ===========================================================================
D0="$WORK/d0"
mkdir -p "$D0/env-a" "$D0/env-b"
: > "$D0/env-a/Manifest.toml"
: > "$D0/env-b/Manifest.toml"

"$AJT" usage record --depot "$D0" --log manifest "$D0/env-a/Manifest.toml"
check "a fresh log has exactly one key" "$D0/env-a/Manifest.toml" "$(usage_keys "$D0/logs/manifest_usage.toml")"

# The `time` must be a real TOML datetime with Julia's exact rendering.
LINE=$(grep '^time = ' "$D0/logs/manifest_usage.toml" | head -1)
if printf '%s' "$LINE" | grep -Eq '^time = [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'; then
  ok "the timestamp is rendered as TOML.print does (YYYY-mm-ddTHH:MM:SS.sssZ)"
else
  bad "the timestamp is rendered as TOML.print does" "got [$LINE]"
fi

# LOCAL time, not UTC: `Dates.now()` is local wall clock and TOML.print's `Z`
# is a literal (TOML/src/print.jl:96). A UTC stamp would pass the format check
# above and be hours wrong.
#
# Compared against BOTH clocks, and the local one has to win. Asserting only
# "within N seconds of Dates.now()" would be satisfied by a UTC stamp on any
# UTC host -- i.e. on almost every CI container, which is precisely where
# `nowLocal`'s /etc/localtime read is most likely to have fallen back to UTC.
# When the two clocks are the same the check cannot discriminate, and says so
# rather than claiming a pass it did not earn.
read -r SKEW_LOCAL SKEW_UTC <<<"$(jl -e '
using TOML, Dates
d = TOML.parsefile(ARGS[1])
t = DateTime(first(values(d))[1]["time"])
print(abs(Dates.value(Dates.now()      - t)) ÷ 1000, " ",
      abs(Dates.value(Dates.now(Dates.UTC) - t)) ÷ 1000)' "$D0/logs/manifest_usage.toml")"
if [ "$SKEW_LOCAL" -ge 300 ]; then
  bad "the timestamp is LOCAL wall clock" "off by ${SKEW_LOCAL}s from Dates.now() — looks like UTC where Pkg writes local"
elif [ "$SKEW_UTC" -lt 300 ]; then
  # Local == UTC on this host, so nothing here can tell them apart.
  ok "the timestamp is within ${SKEW_LOCAL}s of Dates.now() (host is on UTC — local/UTC INDISTINGUISHABLE here)"
else
  ok "the timestamp is LOCAL wall clock: ${SKEW_LOCAL}s from Dates.now(), ${SKEW_UTC}s from Dates.now(UTC)"
fi

# Appending twice must not duplicate or corrupt. Three writes, two keys.
"$AJT" usage record --depot "$D0" --log manifest "$D0/env-a/Manifest.toml"
"$AJT" usage record --depot "$D0" --log manifest "$D0/env-b/Manifest.toml"
"$AJT" usage record --depot "$D0" --log manifest "$D0/env-a/Manifest.toml"
check "three writes over two paths leave two keys" \
  "$(printf '%s\n%s' "$D0/env-a/Manifest.toml" "$D0/env-b/Manifest.toml")" \
  "$(usage_keys "$D0/logs/manifest_usage.toml")"
check "and one entry per key (nothing appended)" \
  "$(printf '%s\t1\n%s\t1' "$D0/env-a/Manifest.toml" "$D0/env-b/Manifest.toml")" \
  "$(usage_entry_counts "$D0/logs/manifest_usage.toml")"

# SIZE. Every check above uses two keys, which is not enough to notice a log
# whose pre-existing keys were kept by reference into a freed parse arena --
# small arenas get reused intact and the corruption does not show. A real
# artifact_usage.toml has ~80. `--allow-missing` skips the isfile filter so
# this needs no fixture files.
D0C="$WORK/d0c"
mkdir -p "$D0C"
SYNTH=()
for n in $(seq 1 100); do
  SYNTH+=("/home/someone/.julia/packages/SomeLongPackageName_jll$n/aB3xQ/Artifacts.toml")
done
"$AJT" usage record --depot "$D0C" --log artifact --allow-missing "${SYNTH[@]}"
"$AJT" usage record --depot "$D0C" --log artifact --allow-missing "/home/someone/.julia/packages/One_More_jll/zZ9kL/Artifacts.toml"
check "100 pre-existing keys survive a 101st being added" "101" \
  "$(usage_keys "$D0C/logs/artifact_usage.toml" | wc -l | tr -d ' ')"
# ...and every one of them is still the string it was written as. A key kept by
# reference into freed memory would still be A key; it would not be THIS key.
check "and every key is intact after the rewrite" "100" \
  "$(usage_keys "$D0C/logs/artifact_usage.toml" | grep -c '^/home/someone/.julia/packages/SomeLongPackageName_jll[0-9]*/aB3xQ/Artifacts.toml$')"

# "Don't record ghost usage" (Types.jl:673): a path that does not exist leaves
# `logs/` ABSENT, because mkpath happens after the filter.
#
# The POSITIVE CONTROL first. Without it, "no logs/ directory" would be
# satisfied by ajt dying for any unrelated reason — a renamed flag, a crash —
# and the check would pass while testing nothing.
D0B="$WORK/d0b"
mkdir -p "$D0B/real"
: > "$D0B/real/Manifest.toml"
"$AJT" usage record --depot "$D0B" --log manifest "$D0B/real/Manifest.toml"
if [ -f "$D0B/logs/manifest_usage.toml" ]; then
  ok "control: an EXISTING source does create logs/"
else
  bad "control: an EXISTING source does create logs/"
fi
rm -rf "$D0B/logs"
if ! "$AJT" usage record --depot "$D0B" --log manifest "$D0B/nope/Manifest.toml" 2>"$WORK/ghost.err"; then
  bad "a non-existent source leaves no logs/ directory" "ajt exited nonzero: $(tail -1 "$WORK/ghost.err")"
elif [ -e "$D0B/logs" ]; then
  bad "a non-existent source leaves no logs/ directory" "$(ls -a "$D0B/logs")"
else
  ok "a non-existent source leaves no logs/ directory"
fi

# scratch_usage.toml is append-only and carries parent_projects; this writer
# would drop them, and `gc` reads `parent_projects` unconditionally
# (API.jl:664), so a rewrite makes every later Pkg.gc() throw a KeyError.
# The REASON is asserted, not just the exit status — "ajt exited nonzero" is
# satisfied by any error at all, including a typo in this script.
if "$AJT" usage record --depot "$D0" --log scratch "$D0/env-a/Manifest.toml" 2>"$WORK/scratch.err"; then
  bad "scratch_usage.toml is refused" "ajt exited 0"
elif grep -q 'append-only' "$WORK/scratch.err"; then
  ok "scratch_usage.toml is refused, for the stated reason"
else
  bad "scratch_usage.toml is refused, for the stated reason" "$(tail -2 "$WORK/scratch.err" | tr '\n' '|')"
fi

# Concurrent writers. `usage.zig` takes the same `<log>.pid` lock Julia's
# `mkpidlock` takes (Types.jl:684), and the whole operation is a
# read-modify-rewrite — so without it two writers race and one's key vanishes.
# Pkg gates the same property in its own suite (Pkg/test/pkg.jl:415).
D0D="$WORK/d0d"
mkdir -p "$D0D"
for n in $(seq 1 12); do
  mkdir -p "$D0D/e$n"
  : > "$D0D/e$n/Manifest.toml"
done
for n in $(seq 1 12); do
  "$AJT" usage record --depot "$D0D" --log manifest "$D0D/e$n/Manifest.toml" &
done
wait
check "12 concurrent writers all land (the pidfile lock holds)" "12" \
  "$(usage_keys "$D0D/logs/manifest_usage.toml" | wc -l | tr -d ' ')"
if [ -z "$(find "$D0D/logs" -name '.ajt-usage-*' -o -name '*.pid' 2>/dev/null)" ]; then
  ok "and left no temp file or pidfile behind"
else
  bad "and left no temp file or pidfile behind" "$(ls -a "$D0D/logs" | tr '\n' ' ')"
fi

# ===========================================================================
echo
echo "==> 1. interop: Julia and Ajt extend each other's file"
# ===========================================================================
D1="$WORK/d1"
mkdir -p "$D1/a" "$D1/b"
: > "$D1/a/Manifest.toml"
: > "$D1/b/Manifest.toml"

"$AJT" usage record --depot "$D1" --log manifest "$D1/a/Manifest.toml"
# Julia's own writer, pointed at Ajt's file.
JULIA_DEPOT_PATH="$D1" julia --startup-file=no -e \
  'using Pkg; Pkg.Types.write_env_usage(ARGS[1], "manifest_usage.toml")' "$D1/b/Manifest.toml" >/dev/null 2>&1
check "Julia extends Ajt's log without losing Ajt's key" \
  "$(printf '%s\n%s' "$D1/a/Manifest.toml" "$D1/b/Manifest.toml")" \
  "$(usage_keys "$D1/logs/manifest_usage.toml")"

BEFORE=$(usage_time "$D1/logs/manifest_usage.toml" "$D1/a/Manifest.toml")
sleep 1.1
"$AJT" usage record --depot "$D1" --log manifest "$D1/a/Manifest.toml"
AFTER=$(usage_time "$D1/logs/manifest_usage.toml" "$D1/a/Manifest.toml")
check "Ajt extends Julia's log without losing Julia's key" \
  "$(printf '%s\n%s' "$D1/a/Manifest.toml" "$D1/b/Manifest.toml")" \
  "$(usage_keys "$D1/logs/manifest_usage.toml")"
check "and still one entry per key" \
  "$(printf '%s\t1\n%s\t1' "$D1/a/Manifest.toml" "$D1/b/Manifest.toml")" \
  "$(usage_entry_counts "$D1/logs/manifest_usage.toml")"
if [ "$AFTER" != "$BEFORE" ]; then
  ok "re-recording moves the timestamp forward ($BEFORE -> $AFTER)"
else
  bad "re-recording moves the timestamp forward" "still $BEFORE"
fi

# ===========================================================================
if [ $NETWORK -eq 0 ] || [ ! -d "$HOST_DEPOT/registries" ]; then
  echo
  echo "############################################################"
  echo "# SKIPPING sections 2-4: they need the network and a General"
  echo "# registry under $HOST_DEPOT."
  echo "############################################################"
else
echo
echo "==> 2. Julia and Ajt produce the same log for the same install"
# ===========================================================================
SEED="$WORK/seed"        # depot Julia fills — also the oracle for shape
PROJ="$WORK/proj"        # the environment both sides install
mkdir -p "$SEED" "$PROJ"
cat > "$PROJ/Project.toml" <<'EOF'
name = "AjtUsageProbe"
uuid = "3f2b1a0c-4d5e-4f60-8a71-9b2c3d4e5f60"
version = "0.1.0"
EOF

# Zstd_jll: small, has an artifact, and pulls two ordinary packages with it —
# so one install exercises BOTH logs.
if ! JULIA_DEPOT_PATH="$SEED" julia --startup-file=no --project="$PROJ" \
      -e 'using Pkg; Pkg.add("Zstd_jll")' > "$WORK/seed.log" 2>&1; then
  bad "Julia seeded the reference environment" "$(tail -3 "$WORK/seed.log")"
else
  ok "Julia seeded the reference environment"
fi

for f in manifest_usage.toml artifact_usage.toml; do
  if [ -f "$SEED/logs/$f" ]; then ok "Julia wrote logs/$f"; else bad "Julia wrote logs/$f"; fi
done

JULIA_PREFIX=$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia --startup-file=no -e 'print(VERSION)')
HOST_TAGS=$("$AJT" host-platform --julia-prefix "$JULIA_PREFIX" --julia-version "$JULIA_VERSION")

AJT_DEPOT="$WORK/ajt-depot"
mkdir -p "$AJT_DEPOT"
if ! "$AJT" install --depot "$AJT_DEPOT" --registry-depot "$HOST_DEPOT" \
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
if [ "${#ROOTS[@]}" -gt 0 ]; then ok "ajt install produced ${#ROOTS[@]} package roots"; else bad "ajt install produced package roots"; fi

if [ "${#ROOTS[@]}" -eq 0 ]; then
  # Nothing to hand it, and `"${ROOTS[@]}"` under `set -u` is a portability
  # trap on older bash. Reported, not skipped silently.
  bad "ajt install-artifacts into the same depot" "no package roots to pass"
elif ! "$AJT" install-artifacts --depot "$AJT_DEPOT" --host "$HOST_TAGS" \
      --julia-version "$JULIA_VERSION" --julia-prefix "$JULIA_PREFIX" \
      "${ROOTS[@]}" > "$WORK/arts.out" 2> "$WORK/arts.err"; then
  bad "ajt install-artifacts into the same depot" "$(tail -3 "$WORK/arts.err")"
else
  ok "ajt install-artifacts into the same depot"
fi

# --- the diff ---------------------------------------------------------------
# Normalise the two things that cannot be equal by construction, and say so:
#   * the depot root, which differs because they ARE different depots;
#   * the whole `time` value, which is wall clock. Format and freshness are
#     asserted separately above and below; only the STRUCTURE is diffed here.
normalise() { # normalise <file> <depot-root> <project-dir>
  [ -f "$1" ] || { echo "MISSING"; return; }
  sed -e "s#$2#<DEPOT>#g" -e "s#$3#<PROJ>#g" \
      -e 's#^time = .*$#time = <TIME>#' "$1"
}
for f in manifest_usage.toml artifact_usage.toml; do
  # Asserted separately so the diff below cannot pass by comparing two
  # "MISSING" markers to each other.
  if [ -f "$AJT_DEPOT/logs/$f" ]; then ok "ajt wrote logs/$f"; else bad "ajt wrote logs/$f"; fi
  A=$(normalise "$SEED/logs/$f" "$SEED" "$PROJ")
  B=$(normalise "$AJT_DEPOT/logs/$f" "$AJT_DEPOT" "$PROJ")
  if [ "$A" = "$B" ]; then
    ok "$f is structurally identical to Julia's (paths and TIME normalised)"
  else
    bad "$f is structurally identical to Julia's" "$(diff <(echo "$A") <(echo "$B") | head -8 | tr '\n' '|')"
  fi
done

# An Artifacts.toml that yields NO downloadable artifact for this host is
# STILL logged: `collect_artifacts` pushes the pair unconditionally once the
# file exists (Operations.jl:902) and `used_artifact_tomls` is the set of all
# their firsts (:952). Zstd_jll has a downloadable artifact, so nothing above
# exercises this — and dropping such a file would make `Pkg.gc()` collect
# every artifact an all-lazy JLL pins. No network: nothing is downloadable.
LAZY="$WORK/lazy-pkg"
mkdir -p "$LAZY"
cat > "$LAZY/Artifacts.toml" <<'EOF'
[NeverDownloaded]
git-tree-sha1 = "0000000000000000000000000000000000000000"
lazy = true

    [[NeverDownloaded.download]]
    url = "http://127.0.0.1:1/nope.tar.gz"
    sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
EOF
LAZY_DEPOT="$WORK/lazy-depot"
mkdir -p "$LAZY_DEPOT"
if "$AJT" install-artifacts --depot "$LAZY_DEPOT" --host "$HOST_TAGS" \
      "$LAZY" > "$WORK/lazy.out" 2> "$WORK/lazy.err"; then
  check "an Artifacts.toml with nothing downloadable is still logged" \
    "$LAZY/Artifacts.toml" "$(usage_keys "$LAZY_DEPOT/logs/artifact_usage.toml")"
  check "...and it installed nothing" "0" "$(wc -l < "$WORK/lazy.out" | tr -d ' ')"
else
  bad "an Artifacts.toml with nothing downloadable is still logged" "$(tail -2 "$WORK/lazy.err")"
fi

# The manifest key is the ENVIRONMENT's Manifest.toml, absolute — the same
# string on both sides, so this one is compared without any normalisation.
check "the manifest key is the environment's absolute Manifest.toml" \
  "$PROJ/Manifest.toml" "$(usage_keys "$AJT_DEPOT/logs/manifest_usage.toml")"

# The artifact keys are Artifacts.toml paths inside each depot; equal after
# stripping the depot root, which is the whole content-addressed claim.
check "the artifact keys are the same Artifacts.toml, depot root aside" \
  "$(usage_keys "$SEED/logs/artifact_usage.toml" | sed "s#$SEED#<DEPOT>#")" \
  "$(usage_keys "$AJT_DEPOT/logs/artifact_usage.toml" | sed "s#$AJT_DEPOT#<DEPOT>#")"

# ===========================================================================
echo
echo "==> 3. THE GATE: Pkg.gc() must not collect what Ajt installed"
# ===========================================================================
BEFORE_INV=$(inventory "$AJT_DEPOT")
# BOTH kinds, not merely "something": an install that silently produced no
# artifact would still satisfy a non-empty check, and half this section is
# about artifacts.
N_PKG=$(echo "$BEFORE_INV" | grep -c '^packages/')
N_ART=$(echo "$BEFORE_INV" | grep -c '^artifacts/')
if [ "$N_PKG" -gt 0 ] && [ "$N_ART" -gt 0 ]; then
  ok "the scratch depot has both packages ($N_PKG) and artifacts ($N_ART) to lose"
else
  bad "the scratch depot has both packages and artifacts to lose" "packages=$N_PKG artifacts=$N_ART"
fi
echo "$BEFORE_INV" | sed 's/^/       /'

GC1_OK=1
if ! gc_now "$AJT_DEPOT" > "$WORK/gc1.log" 2>&1; then
  GC1_OK=0
  bad "Pkg.gc(collect_delay=0) ran" "$(tail -3 "$WORK/gc1.log" | tr '\n' '|')"
else
  ok "Pkg.gc(collect_delay=0) ran"
fi
AFTER_INV=$(inventory "$AJT_DEPOT")
if [ "$BEFORE_INV" = "$AFTER_INV" ]; then
  ok "Pkg.gc(collect_delay=0) deleted NOTHING — the usage logs protected it"
else
  GC1_OK=0
  bad "Pkg.gc(collect_delay=0) deleted NOTHING" \
      "$(diff <(echo "$BEFORE_INV") <(echo "$AFTER_INV") | head -6 | tr '\n' '|')"
fi
# gc's own count, asserted rather than merely printed: it is the strongest
# evidence available that gc SAW the logs, as opposed to finding nothing to do.
check "gc found the manifest log" "1" \
  "$(grep -cE 'Active manifest files: 1 found' "$WORK/gc1.log")"
check "gc found the artifact log" "1" \
  "$(grep -cE 'Active artifact files: 1 found' "$WORK/gc1.log")"

# --- and now prove the gate can fail ---------------------------------------
# Without this half the section above is worthless: a gc that collects nothing
# under any circumstances would pass it.
#
# Gated on the first half having held. If gc1 had already emptied the depot,
# "everything is gone" would be true for the wrong reason and printing `ok`
# here would report a demonstration that never happened.
if [ "$GC1_OK" -eq 0 ]; then
  bad "with the logs DELETED the same gc collects everything (the gate bites)" \
      "not attempted — the protected-run above did not hold, so this proves nothing"
else
  rm -f "$AJT_DEPOT/logs/manifest_usage.toml" "$AJT_DEPOT/logs/artifact_usage.toml"
  if ! gc_now "$AJT_DEPOT" > "$WORK/gc2.log" 2>&1; then
    bad "the second Pkg.gc(collect_delay=0) ran" "$(tail -3 "$WORK/gc2.log" | tr '\n' '|')"
  fi
  GONE_INV=$(inventory "$AJT_DEPOT")
  if [ -z "$GONE_INV" ]; then
    ok "with the logs DELETED the same gc collects everything (the gate bites)"
  else
    bad "with the logs DELETED the same gc collects everything" \
        "still present: $(echo "$GONE_INV" | tr '\n' ' ')"
  fi
  check "and gc says so, for packages" "1" "$(grep -cE 'Deleted [0-9]+ package installation' "$WORK/gc2.log")"
  check "and gc says so, for artifacts" "1" "$(grep -cE 'Deleted [0-9]+ artifact installation' "$WORK/gc2.log")"
fi

# ===========================================================================
echo
echo "==> 4. registry add/update record nothing — on BOTH sides"
# ===========================================================================
# Pkg's registry paths never construct an EnvCache, so they never stamp
# manifest_usage.toml even with a Manifest present. Verified rather than
# assumed, because "Ajt writes nothing" is only interesting if Pkg agrees.
D4="$WORK/d4"
mkdir -p "$D4/registries" "$D4/env"
if cp -a "$HOST_DEPOT/registries/." "$D4/registries/"; then
  ok "seeded a scratch depot with the host's General registry"
else
  bad "seeded a scratch depot with the host's General registry"
fi
: > "$D4/env/Manifest.toml"
"$AJT" usage record --depot "$D4" --log manifest "$D4/env/Manifest.toml"
SNAP=$(cat "$D4/logs/manifest_usage.toml")

# Each command's EXIT STATUS is checked before its no-write claim. Without
# that, "the log did not change" is satisfied by the command failing outright
# — a network blip, a proxy, a renamed subcommand — and the check would pass
# while exercising nothing at all.
registry_writes_nothing() { # registry_writes_nothing <label> <cmd...>
  local label="$1"; shift
  if ! "$@" > "$WORK/reg.log" 2>&1; then
    bad "$label left the log byte-identical" "the command itself failed: $(tail -2 "$WORK/reg.log" | tr '\n' '|')"
    return 0
  fi
  check "$label ran, and left the log byte-identical" "$SNAP" "$(cat "$D4/logs/manifest_usage.toml")"
}

registry_writes_nothing "Pkg.Registry.update()" \
  env JULIA_DEPOT_PATH="$D4" julia --startup-file=no --project="$D4/env" -e 'using Pkg; Pkg.Registry.update()'
registry_writes_nothing "Pkg.Registry.add()" \
  env JULIA_DEPOT_PATH="$D4" julia --startup-file=no --project="$D4/env" -e 'using Pkg; Pkg.Registry.add("General")'
registry_writes_nothing "Pkg.Registry.status()" \
  env JULIA_DEPOT_PATH="$D4" julia --startup-file=no --project="$D4/env" -e 'using Pkg; Pkg.Registry.status()'
registry_writes_nothing "ajt registry update" "$AJT" registry update --depot "$D4"
registry_writes_nothing "ajt registry add"    "$AJT" registry add    --depot "$D4"
fi

# ===========================================================================
echo
echo "==> 5. the user's real depot was not written"
# ===========================================================================
# Every depot this harness wrote to lives under $WORK, so a leak into ~/.julia
# shows up as a $WORK-prefixed key in its logs.
#
# What this does NOT cover, said out loud rather than implied: it looks only at
# logs/, not at packages/, artifacts/ or registries/, and it cannot see a leak
# whose key is not $WORK-prefixed. An mtime sweep would cover more and be
# useless in practice — any other `julia` running on this machine touches
# ~/.julia, so it would fail for reasons unrelated to this change. The `jl`
# wrapper at the top is what actually keeps the real depot read-only; this is
# the backstop, not the mechanism.
LEAKED=0
for f in "$HOST_DEPOT/logs/manifest_usage.toml" "$HOST_DEPOT/logs/artifact_usage.toml"; do
  [ -f "$f" ] || continue
  grep -Fq "$WORK" "$f" && LEAKED=1
done
check "no key under $WORK appears in $HOST_DEPOT/logs" "0" "$LEAKED"
# The mechanism itself, asserted from INSIDE Julia: `depots1()` — the one
# entry Julia writes `compiled/*.ji` to — must be the scratch depot. Counting
# what landed there would prove nothing, since a fully warm host cache means
# nothing needs writing at all.
check "the oracle's depots1() is a scratch depot, not $HOST_DEPOT" \
  "$WORK/oracle" "$(jl -e 'print(DEPOT_PATH[1])')"

# ---------------------------------------------------------------------------
echo
if [ $FAIL -eq 0 ]; then
  if [ $NETWORK -eq 0 ] || [ ! -d "$HOST_DEPOT/registries" ]; then
    # Exit 3, not 0. Sections 2-4 are where every claim about Pkg.gc() lives;
    # reporting plain success without them would be exactly the gate-that-
    # cannot-fail this file exists to rule out.
    echo "SKIP — $PASS checks passed, but sections 2-4 (Pkg.gc) were SKIPPED, see above" >&2
    exit 3
  fi
  echo "PASS — $PASS checks: Ajt's usage logs are structurally identical to"
  echo "       Pkg's, the two writers extend each other's files, and Pkg.gc()"
  echo "       leaves an Ajt-filled depot alone — while deleting all of it the"
  echo "       moment the logs are removed"
  exit 0
fi
echo "FAIL — $FAIL of $((PASS+FAIL)) checks" >&2
[ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect)" >&2
exit 1
