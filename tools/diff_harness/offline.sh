#!/usr/bin/env bash
# Differential gate for offline mode — `--offline` / `JULIA_PKG_OFFLINE`.
#
# Offline is two behaviours that are easy to conflate, and only one of them is
# about the network:
#
#   1. No network I/O. `update_registries` opens with `OFFLINE_MODE[] && return`
#      (Operations.jl:1629) and never refreshes the registry.
#   2. The resolver only considers versions already unpacked in the depot —
#      `installed_only = installed_only || OFFLINE_MODE[]` (Operations.jl:500),
#      applied to the candidate list itself (:702-708). This is the substantive
#      half: an offline resolve that still proposed an uninstalled version would
#      write a manifest the machine cannot instantiate.
#
# The corpus is built so those two are separable. A scratch depot is given
# exactly ONE version of a package — an old one, deliberately not the newest the
# registry offers — and then both tools are asked to resolve an environment that
# needs it. Offline, both must choose the installed version; online, both must
# choose the newest. That difference is what makes every check below non-vacuous:
# if the resolver ignored the depot, the offline manifests would equal the online
# ones and the byte comparison against Pkg would still pass.
#
# What is checked:
#
#   * OFFLINE, installed version wins — Pkg's and Ajt's Project.toml AND
#     Manifest.toml byte-identical, and both naming the OLD version.
#   * `--preserve none` composes rather than overrides: a full re-resolve
#     offline still cannot leave the depot's version.
#   * OFFLINE, package not installed at all — both refuse, and Ajt's refusal is
#     the PubGrub derivation report naming the package, not a crash.
#   * OFFLINE, no network request is made. Proved, not asserted: JULIA_PKG_SERVER
#     points at a closed port and the run must succeed ANYWAY. Two landmarks
#     establish that the address really is dead and really is consulted, so
#     "succeeded" cannot mean "the address happened to work".
#   * `JULIA_PKG_OFFLINE` is read on Base.get_bool_env's exact truthy set,
#     including `TRUE` and `Yes` (the spellings a lowercase-only reader drops),
#     and an unparseable value is refused by both tools.
#   * UNSET, nothing changed: the same environments resolve to the NEWEST
#     version on both sides, byte-identical.
#
# Needs the network (the registry and one real package) and a few minutes.
# Writes only into a mktemp depot — never ~/.julia.
#
# Usage: offline.sh [--keep] [--package NAME] [--missing NAME]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
# Requirements on the package: registered, pure Julia (no artifacts — Pkg's
# `is_package_downloaded` also demands those and Ajt's installed-check does not,
# so a JLL would test a known divergence rather than this one), a small closure,
# and several published versions. Preferences depends only on the TOML stdlib.
PACKAGE="Preferences"
# A registered package that will NOT be installed in the scratch depot.
MISSING="Crayons"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --missing) MISSING="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-offline-XXXXXX)"
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

if ! "$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: no network. Building the corpus needs the real registry and  #"
  echo "# one real package; there is no offline subset of an offline gate.      #"
  echo "########################################################################"
  exit 0
fi

DEPOT="$WORK/depot"
mkdir -p "$DEPOT"
JULIA_PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"

# A port nothing can be listening on. Not a hostname: DNS failure and connection
# refusal take different paths through the client, and refusal is the fast one.
DEAD="http://127.0.0.1:1"

echo "==> installing the registry into a scratch depot"
env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e \
  'using Pkg; Pkg.Registry.add("General")' >"$WORK/reg.log" 2>&1 || {
  echo "ERROR: could not install the registry" >&2; tail -10 "$WORK/reg.log" >&2; exit 2; }

# --- the corpus --------------------------------------------------------------
#
# The registry's versions for the package, oldest first. Taking the
# second-newest rather than a hard-coded number keeps this working as the
# package publishes; taking anything but the newest is what makes "offline
# chose the installed one" distinguishable from "offline chose the latest".
"$AJT" registry show --depot "$DEPOT" "$PACKAGE" >"$WORK/versions.txt" 2>&1 || {
  echo "ERROR: ajt registry show $PACKAGE failed" >&2; tail -5 "$WORK/versions.txt" >&2; exit 2; }
VERSIONS="$(awk '/^[0-9]/ {print $1}' "$WORK/versions.txt")"
NCOUNT="$(printf '%s\n' "$VERSIONS" | grep -c .)"
[ "$NCOUNT" -ge 2 ] || { echo "ERROR: $PACKAGE has $NCOUNT versions; need at least 2" >&2; exit 2; }
OLD="$(printf '%s\n' "$VERSIONS" | tail -2 | head -1)"
NEW="$(printf '%s\n' "$VERSIONS" | tail -1)"

# LANDMARK: the whole gate rests on these two being different. If the registry
# ever offers only one usable version, every "offline picked the installed one"
# check below would pass without the offline path running at all.
if [ "$OLD" != "$NEW" ]; then
  ok "corpus: $PACKAGE has an older version $OLD and a newer $NEW to tell apart"
else
  bad "corpus: $PACKAGE's old and new versions are both $OLD — this gate proves nothing"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

echo "==> seeding the depot with $PACKAGE@$OLD and nothing newer"
SEED="$WORK/seed"; mkdir -p "$SEED"
if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
     --project="$SEED" -e \
     "using Pkg; Pkg.add(PackageSpec(name=\"$PACKAGE\", version=v\"$OLD\"))" \
     >"$WORK/seed.log" 2>&1; then
  echo "ERROR: could not install $PACKAGE@$OLD" >&2; tail -10 "$WORK/seed.log" >&2; exit 2
fi
grep -q "version = \"$OLD\"" "$SEED/Manifest.toml" \
  && ok "seed: the depot holds $PACKAGE@$OLD" \
  || bad "seed: expected $PACKAGE@$OLD in the seed manifest" "$(grep -A2 "\[\[deps.$PACKAGE\]\]" "$SEED/Manifest.toml" | tr '\n' '|')"

# A bare `[deps]`-less environment for each case, so every run is a fresh
# resolve with no manifest to preserve.
new_env() {
  local d="$1"
  mkdir -p "$d"
  printf '' > "$d/Project.toml"
}

# --- 1. offline resolves to the installed version, byte for byte -------------
echo
echo "==> offline: the installed version wins"
A="$WORK/off/pkg"; B="$WORK/off/ajt"
new_env "$A"; new_env "$B"

env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
  --project="$A" -e "using Pkg; Pkg.offline(true); Pkg.add(\"$PACKAGE\")" \
  >"$WORK/off.pkg.log" 2>&1
PKG_CODE=$?
env JULIA_DEPOT_PATH="$DEPOT" "$AJT" add --offline --depot "$DEPOT" \
  --julia-prefix "$JULIA_PREFIX" --project "$B" "$PACKAGE" \
  >"$WORK/off.ajt.log" 2>&1
AJT_CODE=$?

if [ $PKG_CODE -ne 0 ]; then
  bad "offline add: stock Pkg failed" "$(tail -3 "$WORK/off.pkg.log" | tr '\n' '|')"
elif [ $AJT_CODE -ne 0 ]; then
  bad "offline add: ajt failed" "$(tail -5 "$WORK/off.ajt.log" | tr '\n' '|')"
else
  # The substantive assertion, stated on Pkg's own output first: offline mode
  # must have held the resolve back to the depot's version.
  if grep -q "version = \"$OLD\"" "$A/Manifest.toml"; then
    ok "offline add: Pkg chose the installed $OLD, not the registry's $NEW"
  else
    bad "offline add: Pkg did not choose $OLD — the corpus is not what this gate assumes" \
        "$(grep -A3 "\[\[deps.$PACKAGE\]\]" "$A/Manifest.toml" | tr '\n' '|')"
  fi
  if cmp -s "$A/Project.toml" "$B/Project.toml" && cmp -s "$A/Manifest.toml" "$B/Manifest.toml"; then
    ok "offline add: Project and Manifest both byte-identical to Pkg's"
  else
    bad "offline add: differs from Pkg" \
        "$( { diff "$A/Project.toml" "$B/Project.toml"; diff "$A/Manifest.toml" "$B/Manifest.toml"; } | head -8 | tr '\n' '|')"
  fi
fi

# The environment variable is the other half of the surface, and it has to mean
# the same thing — including in the spellings a lowercase-only reader drops.
# `Base.get_bool_env`'s truthy set is t/true/y/yes/1 plus their Capitalized and
# UPPERCASE forms (base/env.jl:117-122).
for spelling in 1 true TRUE Yes; do
  C="$WORK/env-$spelling/ajt"; new_env "$C"
  if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_OFFLINE="$spelling" "$AJT" add --depot "$DEPOT" \
       --julia-prefix "$JULIA_PREFIX" --project "$C" "$PACKAGE" >"$WORK/env-$spelling.log" 2>&1 &&
     cmp -s "$A/Manifest.toml" "$C/Manifest.toml"; then
    ok "JULIA_PKG_OFFLINE=$spelling: same manifest as Pkg's offline run"
  else
    bad "JULIA_PKG_OFFLINE=$spelling did not take effect" \
        "$(diff "$A/Manifest.toml" "$C/Manifest.toml" 2>&1 | head -4 | tr '\n' '|')"
  fi
done

# An unrecognised value aborts `using Pkg` outright (OFFLINE_MODE is a
# Ref{Bool} and `get_bool_env` hands it `nothing`); verified by running it.
# Silently treating it as "online" is the failure mode worth gating.
env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_OFFLINE=garbage julia --startup-file=no \
  -e 'using Pkg' >"$WORK/garbage.pkg.log" 2>&1
PKG_GARBAGE=$?
env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_OFFLINE=garbage "$AJT" resolve --depot "$DEPOT" \
  --julia-prefix "$JULIA_PREFIX" "$A" >"$WORK/garbage.ajt.log" 2>&1
AJT_GARBAGE=$?
if [ $PKG_GARBAGE -ne 0 ] && [ $AJT_GARBAGE -ne 0 ]; then
  ok "JULIA_PKG_OFFLINE=garbage: both refuse to run (Pkg $PKG_GARBAGE, ajt $AJT_GARBAGE)"
else
  bad "JULIA_PKG_OFFLINE=garbage was accepted by one of them" \
      "Pkg exit $PKG_GARBAGE, ajt exit $AJT_GARBAGE"
fi

# --- 2. offline is a constraint, not a preserve tier -------------------------
#
# `--preserve none` throws the manifest away and re-resolves from [compat]
# alone. Offline still has to bind: `resolve_versions!` is called once per
# attempt and ORs OFFLINE_MODE in every time, so no tier the sequence reaches
# can name an uninstalled version.
echo
echo "==> offline composes with --preserve none"
P="$WORK/preserve/ajt"; mkdir -p "$P"
cp "$A/Project.toml" "$A/Manifest.toml" "$P/"
if env JULIA_DEPOT_PATH="$DEPOT" "$AJT" resolve --offline --depot "$DEPOT" \
     --julia-prefix "$JULIA_PREFIX" --preserve none --write --quiet "$P" \
     >"$WORK/preserve.log" 2>&1; then
  if cmp -s "$A/Manifest.toml" "$P/Manifest.toml"; then
    ok "offline --preserve none: still the installed $OLD (offline overrode a full re-resolve)"
  else
    bad "offline --preserve none: re-resolved past the depot" \
        "$(diff "$A/Manifest.toml" "$P/Manifest.toml" | head -6 | tr '\n' '|')"
  fi
else
  bad "offline --preserve none failed" "$(tail -5 "$WORK/preserve.log" | tr '\n' '|')"
fi

# ...and the same tier ONLINE must move to $NEW, or the check above is just
# "--preserve none does nothing".
Q="$WORK/preserve-online/ajt"; mkdir -p "$Q"
cp "$A/Project.toml" "$A/Manifest.toml" "$Q/"
if env JULIA_DEPOT_PATH="$DEPOT" "$AJT" resolve --depot "$DEPOT" \
     --julia-prefix "$JULIA_PREFIX" --preserve none --write --quiet "$Q" \
     >"$WORK/preserve-online.log" 2>&1 &&
   grep -q "version = \"$NEW\"" "$Q/Manifest.toml"; then
  ok "online --preserve none: moves to $NEW, so the check above is the offline flag's doing"
else
  bad "online --preserve none did not move to $NEW — the previous check proves nothing" \
      "$(tail -4 "$WORK/preserve-online.log" | tr '\n' '|')"
fi

# --- 3. a package that is not installed at all -------------------------------
echo
echo "==> offline: $MISSING is registered but not installed"
M="$WORK/missing/pkg"; N="$WORK/missing/ajt"
new_env "$M"; new_env "$N"

env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
  --project="$M" -e "using Pkg; Pkg.offline(true); Pkg.add(\"$MISSING\")" \
  >"$WORK/missing.pkg.log" 2>&1
PKG_MISS=$?
env JULIA_DEPOT_PATH="$DEPOT" "$AJT" add --offline --depot "$DEPOT" \
  --julia-prefix "$JULIA_PREFIX" --project "$N" "$MISSING" \
  >"$WORK/missing.ajt.log" 2>&1
AJT_MISS=$?

if [ $PKG_MISS -ne 0 ] && [ $AJT_MISS -ne 0 ]; then
  ok "not installed: both refuse (Pkg exit $PKG_MISS, ajt exit $AJT_MISS)"
else
  bad "not installed: one of them succeeded offline" "Pkg exit $PKG_MISS, ajt exit $AJT_MISS"
fi
# A refusal is only useful if it says what is wrong. Ajt's has to be the
# resolver's own report naming the package — not a Zig panic, and not a bare
# exit code. Guarded on the refusal having happened at all: run against a build
# that resolved $MISSING anyway, these would otherwise pass on a success log.
if [ $AJT_MISS -eq 0 ]; then
  bad "not installed: skipping the diagnosis checks — ajt did not refuse"
else
  if grep -q "$MISSING" "$WORK/missing.ajt.log" && grep -qi "failed\|no versions\|relaxing" "$WORK/missing.ajt.log"; then
    ok "not installed: ajt's refusal names $MISSING and explains itself"
  else
    bad "not installed: ajt's refusal is not a diagnosis" "$(tail -5 "$WORK/missing.ajt.log" | tr '\n' '|')"
  fi
  if grep -qi "panic\|Unable to dump stack trace\|segmentation fault" "$WORK/missing.ajt.log"; then
    bad "not installed: ajt crashed rather than reporting" "$(grep -i -m2 'panic' "$WORK/missing.ajt.log" | tr '\n' '|')"
  else
    ok "not installed: ajt did not crash"
  fi
  # Nothing may have been written: a refused add leaves the environment alone.
  if [ ! -s "$N/Project.toml" ] && [ ! -f "$N/Manifest.toml" ]; then
    ok "not installed: ajt wrote neither Project.toml nor Manifest.toml"
  else
    bad "not installed: ajt wrote to a refused environment" "$(ls -l "$N" | tr '\n' '|')"
  fi
fi

# --- 4. no network request is made -------------------------------------------
#
# The only check that distinguishes "offline" from "happened not to need the
# network". Two landmarks first, because "succeeded with a dead server" proves
# nothing unless the server really is dead and really would be consulted.
echo
echo "==> offline: no request leaves the process"
if "$AJT" fetch --server "$DEAD" --no-auth --status "$DEAD/registries" >"$WORK/dead.fetch.log" 2>&1; then
  bad "landmark: $DEAD answered a request — it is not a dead address, so nothing below holds"
else
  ok "landmark: $DEAD refuses connections"
fi
if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_SERVER="$DEAD" "$AJT" registry update \
     --depot "$DEPOT" >"$WORK/dead.regupdate.log" 2>&1; then
  bad "landmark: registry update succeeded against $DEAD — an online path is not consulting it"
else
  ok "landmark: an ONLINE registry update against $DEAD fails, so the address is really used"
fi

D="$WORK/deadserver/ajt"; new_env "$D"
if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_SERVER="$DEAD" "$AJT" add --offline \
     --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --project "$D" "$PACKAGE" \
     >"$WORK/dead.ajt.log" 2>&1 && cmp -s "$A/Manifest.toml" "$D/Manifest.toml"; then
  ok "ajt add --offline succeeds with JULIA_PKG_SERVER=$DEAD (no request was made)"
else
  bad "ajt add --offline went to the network" "$(tail -5 "$WORK/dead.ajt.log" | tr '\n' '|')"
fi

E="$WORK/deadserver/pkg"; new_env "$E"
if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_SERVER="$DEAD" JULIA_PKG_PRECOMPILE_AUTO=0 \
     julia --startup-file=no --project="$E" \
     -e "using Pkg; Pkg.offline(true); Pkg.add(\"$PACKAGE\")" >"$WORK/dead.pkg.log" 2>&1 &&
   cmp -s "$A/Manifest.toml" "$E/Manifest.toml"; then
  ok "stock Pkg offline also succeeds with JULIA_PKG_SERVER=$DEAD — same bar, both tools"
else
  bad "stock Pkg offline did not survive a dead server" "$(tail -5 "$WORK/dead.pkg.log" | tr '\n' '|')"
fi

# `registry add`/`update` is the one verb whose whole product IS a download, so
# offline refuses it rather than reporting success. It must refuse WITHOUT
# consulting the dead address — the run above already showed that address costs
# a real timeout when it is consulted.
if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_SERVER="$DEAD" "$AJT" registry update --offline \
     --depot "$DEPOT" >"$WORK/dead.regoffline.log" 2>&1; then
  bad "registry update --offline reported success without downloading anything"
else
  ok "registry update --offline refuses instead of pretending"
fi

# --- 5. with the flag unset, nothing changed ---------------------------------
#
# A second depot, because installing $NEW into the first one would make every
# check above pass for the wrong reason on a re-run.
echo
echo "==> flag unset: the existing behaviour, unchanged"
DEPOT2="$WORK/depot-online"
mkdir -p "$DEPOT2"
cp -a "$DEPOT/registries" "$DEPOT2/"
F="$WORK/on/pkg"; G="$WORK/on/ajt"
new_env "$F"; new_env "$G"

if ! env JULIA_DEPOT_PATH="$DEPOT2" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
     --project="$F" -e "using Pkg; Pkg.add(\"$PACKAGE\")" >"$WORK/on.pkg.log" 2>&1; then
  bad "online add: stock Pkg failed" "$(tail -3 "$WORK/on.pkg.log" | tr '\n' '|')"
elif ! env JULIA_DEPOT_PATH="$DEPOT2" "$AJT" add --depot "$DEPOT2" \
     --julia-prefix "$JULIA_PREFIX" --project "$G" "$PACKAGE" >"$WORK/on.ajt.log" 2>&1; then
  bad "online add: ajt failed" "$(tail -5 "$WORK/on.ajt.log" | tr '\n' '|')"
else
  if cmp -s "$F/Project.toml" "$G/Project.toml" && cmp -s "$F/Manifest.toml" "$G/Manifest.toml"; then
    ok "online add: Project and Manifest both byte-identical to Pkg's"
  else
    bad "online add: differs from Pkg" \
        "$( { diff "$F/Project.toml" "$G/Project.toml"; diff "$F/Manifest.toml" "$G/Manifest.toml"; } | head -8 | tr '\n' '|')"
  fi
  # ...and it must be a DIFFERENT answer from the offline one, or "offline
  # restricted the candidates" was never demonstrated.
  if grep -q "version = \"$NEW\"" "$G/Manifest.toml" && ! cmp -s "$A/Manifest.toml" "$G/Manifest.toml"; then
    ok "online add: chose $NEW where offline chose $OLD — the two paths really differ"
  else
    bad "online add did not choose $NEW; every offline check above is vacuous" \
        "$(grep -A3 "\[\[deps.$PACKAGE\]\]" "$G/Manifest.toml" | tr '\n' '|')"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
