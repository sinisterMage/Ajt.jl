#!/usr/bin/env bash
# Differential gate for AUTO-precompilation — the pass `ajt add`, `ajt up`,
# `ajt pin`, `ajt free` and `ajt instantiate` run after they install, mirroring
# `Pkg._auto_precompile` (`Pkg.jl:896-900`).
#
# `precompile.sh` already proves that `ajt precompile` and `Pkg.precompile()`
# write the same files. This file proves something different and narrower: that
# the OTHER verbs actually invoke it, exactly when Pkg's do, and exactly once.
#
# The claim, in four parts:
#
#   1. `ajt add <pkg>` into a depot with no cache leaves `compiled/` POPULATED,
#      and a subsequent `Pkg.precompile()` over the same environment then has
#      nothing to do. The second half is what makes the first half mean
#      anything: a directory full of `.ji` files Julia would rebuild is worse
#      than no directory at all.
#   2. `JULIA_PKG_PRECOMPILE_AUTO=0` suppresses it ENTIRELY — not "compiles
#      less", but leaves `compiled/` byte-for-byte as it was.
#   3. The variable goes through `Base.get_bool_env`'s ACTUAL rules
#      (`base/env.jl:117-160`), which is where a hand-written port goes wrong:
#      the truthy and falsy tuples include the Capitalized and UPPERCASE
#      spellings, an EMPTY value means the default rather than false, and an
#      unrecognised value is neither (Julia returns `nothing`). Every one of
#      those is asserted against a real run.
#   4. `ajt add` precompiles ONCE. `edit` installs by calling `instantiate`, so
#      if both grew an auto-precompile the environment would be walked twice.
#      Section 5 measures it by COUNTING JULIA CHILD PROCESSES, differentially,
#      which is the only observation a second pass cannot hide from: a warm
#      second pass compiles nothing and writes nothing, but it still has to
#      start one `julia` to ask what needs compiling.
#
# ...plus section 6, the per-verb table: Pkg auto-precompiles after `add`, `up`,
# `pin` and `free` and NOT after `develop` (`API.jl:170` names four verbs and
# `Operations.develop` calls nothing), so `ajt dev` must not either.
#
# WHY THE BASE DEPOT IS PREPARED RATHER THAN EMPTY. Section 2 has to run stock
# `Pkg.precompile()`, and loading Pkg into a virgin depot precompiles Pkg and
# its stdlibs first — dozens of cache entries that have nothing to do with the
# environment under test, all of which would read as "Pkg still had work to do".
# So one BASE depot is built by a plain `Pkg.add` with precompilation switched
# off, and every case starts from `cp -a` of it. Section 0 asserts the base is
# non-vacuous in both directions: it must already carry Pkg's machinery, and it
# must NOT already carry the packages under test.
#
# ONE ENVIRONMENT DIRECTORY, reused and reset between cases, and that is not an
# accident: the active project path is mixed into every cache file's slug
# (`_crc32c(project)`, `loading.jl:3153-3163`), so a base depot warmed against
# one directory is worthless to a run activated on another.
#
# NOTHING here writes to the user's real ~/.julia: the fixture is generated into
# $WORK, every depot is under $WORK, and every julia and ajt invocation gets
# JULIA_DEPOT_PATH or --depot pointed there.
#
# Usage: autoprecompile.sh [--keep]
#   --keep   leave $WORK behind
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# This gate is ABOUT auto-precompilation, so it must not inherit a veto from a
# developer's shell -- every section below would then be trivially green.
unset JULIA_PKG_PRECOMPILE_AUTO

skip () {
  echo
  echo "########################################################################"
  echo "# SKIPPED: $1"
  printf '# %s\n' "${@:2}"
  echo "########################################################################"
  exit 0
}

command -v julia >/dev/null || skip "julia is not on PATH." \
  "Auto-precompilation is a claim about what julia writes; there is no" \
  "julia-less subset of it. The pure half -- Base.get_bool_env's truthy and" \
  "falsy sets -- is covered by the unit tests in src/ops/precompile.zig."
command -v zig >/dev/null || skip "zig is not on PATH, so ajt cannot be built."

WORK="$(mktemp -d -t ajt-autoprecompile-XXXXXX)"
# Pkg makes installed packages read-only (`set_readonly`), so the cleanup has to
# restore write bits before it can delete them.
cleanup () { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok ()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad ()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# `--no-auth`: the ONE ajt invocation with no --depot, so it resolves depots1()
# to the ambient ~/.julia -- and an authenticated GET against an expired token
# would REFRESH it, rewriting the user's real servers/*/auth.toml.
"$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1 \
  || skip "no network (https://pkg.julialang.org unreachable)." \
     "Section 0 downloads a registry and one small package before anything can" \
     "be precompiled."

JV="$(julia --startup-file=no -e 'print("v", VERSION.major, ".", VERSION.minor)')"
[ -n "$JV" ] || { echo "ERROR: could not ask julia for its version" >&2; exit 2; }

# The set of package directories under compiled/, which is the whole
# observation this file is built on.
names () { find "$1/compiled/$JV" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
echo
echo "==> 0. the fixture, the base depot, and a julia that can be counted"

# A BARE environment, not a package: this gate is about whether the pass runs at
# all, and precompile.sh already covers the "the project's own package is a
# root" rule. Bare keeps the closure to two compiles.
ENV_DIR="$WORK/env"
mkdir -p "$ENV_DIR"
: > "$ENV_DIR/Project.toml"

# PrecompileTools -> Preferences -> TOML. TOML is one of Pkg's own dependencies
# and is therefore already cached in the base by the time Pkg has loaded, which
# leaves exactly two packages for the runs below to compile. Small on purpose:
# every section here starts a cold `ajt add`.
PKG=PrecompileTools
UNDER_TEST="Preferences PrecompileTools"

BASE="$WORK/base"
mkdir -p "$BASE"
# JULIA_PKG_PRECOMPILE_AUTO=0 is what keeps this from precompiling the very
# packages the sections below have to compile themselves. Note that this is also
# the first end-to-end proof that stock Pkg honours the variable the same way,
# since the assertion right afterwards is that the packages are NOT cached.
env JULIA_DEPOT_PATH="$BASE" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$ENV_DIR" -e "using Pkg; Pkg.add(\"$PKG\")" \
  >"$WORK/base.log" 2>&1
BASE_RC=$?
if [ $BASE_RC -ne 0 ]; then
  echo "ERROR: could not build the base depot" >&2; tail -20 "$WORK/base.log" >&2; exit 2
fi

# Back to an empty project: every case below adds the package itself.
: > "$ENV_DIR/Project.toml"
rm -f "$ENV_DIR/Manifest.toml"

names "$BASE" > "$WORK/base.names"
BASE_N="$(wc -l < "$WORK/base.names")"
[ "$BASE_N" -gt 5 ] \
  && ok "the base depot carries Pkg's own machinery ($BASE_N cached packages), so section 2's Pkg run adds nothing of its own" \
  || bad "the base depot has only $BASE_N cached packages -- Pkg would precompile itself in section 2 and every check there would misread"

VACUOUS=0
for n in $UNDER_TEST; do
  grep -qx "$n" "$WORK/base.names" && { bad "$n is already cached in the base depot -- every section below would be vacuous"; VACUOUS=1; }
done
[ $VACUOUS -eq 0 ] && ok "neither package under test is cached in the base depot"

# --- a julia prefix whose `julia` counts its own invocations ----------------
#
# Section 5 needs the number of julia CHILD PROCESSES, and ajt runs
# `<prefix>/bin/julia`. So the prefix is mirrored symlink-for-symlink with one
# substitution. Everything else about it -- share/julia/stdlib, lib, the other
# binaries -- has to keep working, because instantiate reads the stdlib
# directory out of the same prefix.
REAL_JULIA="$(readlink -f "$(command -v julia)")"
REAL_PREFIX="$(dirname "$(dirname "$REAL_JULIA")")"
SHIM="$WORK/julia-prefix"
mkdir -p "$SHIM/bin"
for e in "$REAL_PREFIX"/*; do
  [ "$(basename "$e")" = bin ] || ln -s "$e" "$SHIM/"
done
for e in "$REAL_PREFIX"/bin/*; do
  ln -s "$e" "$SHIM/bin/"
done
rm -f "$SHIM/bin/julia"
# `:?` rather than a bare append: a child spawned WITHOUT the variable would
# otherwise go uncounted and the differential in section 5 would still be green
# -- an under-count is invisible in a subtraction. This turns it into a failure.
cat > "$SHIM/bin/julia" <<EOF
#!/usr/bin/env bash
: "\${AJT_JULIA_CALL_LOG:?the counting julia was invoked with no call log}"
echo x >> "\$AJT_JULIA_CALL_LOG"
exec "$REAL_JULIA" "\$@"
EOF
chmod +x "$SHIM/bin/julia"
export AJT_JULIA_CALL_LOG="$WORK/julia.calls"
: > "$AJT_JULIA_CALL_LOG"
env AJT_JULIA_CALL_LOG="$WORK/shim.probe" "$SHIM/bin/julia" --startup-file=no -e 'print(1)' >/dev/null 2>&1
check "the counting julia works and records one call" "1" "$(wc -l < "$WORK/shim.probe" 2>/dev/null | tr -d ' ')"

# One `ajt add` into a fresh copy of the base. Every section is a call to this.
#   run_add <depot-name> [extra ajt args...]
# stdout of ajt lands in $WORK/<name>.records, stderr in $WORK/<name>.err, and
# the depot is $WORK/depot-<name>. The environment is reset first, so the runs
# are independent.
#
# `AUTO_SET`/`AUTO_VAL` decide whether JULIA_PKG_PRECOMPILE_AUTO is exported to
# the child at all -- section 4 needs "unset" and "set to the empty string" to
# be different runs, which they are to `Base.get_bool_env` (`env.jl:144-149`)
# only in the sense that both take the default. Passing them as two variables
# rather than one keeps `unset` expressible.
AUTO_SET=0
AUTO_VAL=""
run_add () {
  local name="$1"; shift
  local depot="$WORK/depot-$name"
  : > "$ENV_DIR/Project.toml"
  rm -f "$ENV_DIR/Manifest.toml"
  rm -rf "$depot"
  cp -a "$BASE" "$depot"
  : > "$AJT_JULIA_CALL_LOG"
  local rc
  if [ "$AUTO_SET" = 1 ]; then
    env JULIA_PKG_PRECOMPILE_AUTO="$AUTO_VAL" \
      "$AJT" add --depot "$depot" --julia-prefix "$SHIM" --project "$ENV_DIR" "$@" "$PKG" \
      >"$WORK/$name.records" 2>"$WORK/$name.err"
    rc=$?
  else
    "$AJT" add --depot "$depot" --julia-prefix "$SHIM" --project "$ENV_DIR" "$@" "$PKG" \
      >"$WORK/$name.records" 2>"$WORK/$name.err"
    rc=$?
  fi
  cp "$AJT_JULIA_CALL_LOG" "$WORK/$name.calls"
  names "$depot" > "$WORK/$name.names"
  comm -13 "$WORK/base.names" "$WORK/$name.names" > "$WORK/$name.new"
  return $rc
}

# Fields of the one-line `precompile <considered> <compiled> <already> <failed>`
# record, or the literal `skipped` and its reason.
pre_field () { awk -F'\t' -v n="$2" '$1=="precompile" {print $n}' "$WORK/$1.records"; }

# ---------------------------------------------------------------------------
echo
echo "==> 1. \`ajt add\` precompiles what it installed"

run_add on
ON_RC=$?
check "ajt add exited cleanly" "0" "$ON_RC"
[ "$ON_RC" -eq 0 ] || head -20 "$WORK/on.err" | sed 's/^/       /'

# The verb did its own job first, or the precompile below is about nothing.
#
# `length($3)==36` picks the CHANGE record (`added <name> <uuid>`) rather than
# the resolve report's `added <name> <version>` line, which names the same
# package on the same run. Two different records with the same first two fields
# is exactly the kind of thing that makes a count assertion read `2`.
check "the package was added to [deps]" "1" \
  "$(awk -F'\t' '$1=="added" && $2=="'"$PKG"'" && length($3)==36' "$WORK/on.records" | wc -l | tr -d ' ')"

# Empty when the record is missing entirely, and bash arithmetic reads an empty
# string as 0 -- which would turn section 5's `ON_COMPILED + 1` into a weaker
# assertion that still passed. Defaulted to a value no run can produce so that
# a missing record fails loudly there instead.
ON_COMPILED="$(pre_field on 3)"
[ -n "$ON_COMPILED" ] || ON_COMPILED=-1
check "nothing failed to precompile" "0" "$(pre_field on 5)"
[ "$ON_COMPILED" -gt 0 ] \
  && ok "the auto-precompile pass compiled $ON_COMPILED packages" \
  || bad "ajt add compiled nothing -- the pass did not run" \
         "$(grep -c . "$WORK/on.records") records, precompile line: [$(grep '^precompile' "$WORK/on.records" | tr '\t' ' ')]"

NEW_N="$(wc -l < "$WORK/on.new")"
[ "$NEW_N" -gt 0 ] \
  && ok "compiled/$JV gained $NEW_N package directories: $(tr '\n' ' ' < "$WORK/on.new")" \
  || bad "compiled/$JV gained nothing -- ajt add left the cache exactly as it found it"
MISSING=0
for n in $UNDER_TEST; do
  grep -qx "$n" "$WORK/on.new" || { bad "$n has no cache directory after ajt add"; MISSING=1; }
done
[ $MISSING -eq 0 ] && ok "both packages under test have a cache directory"

# ---------------------------------------------------------------------------
echo
echo "==> 2. the strong external gate: stock Pkg has nothing left to do"
#
# A `compiled/` full of entries Julia would rebuild would pass section 1 and be
# worthless. This is the check that says the entries are the ones Julia wants.
#
# The claim is that a grep does NOT match, which is the shape of assertion that
# passes when the thing under test never ran at all -- a changed glyph, a
# redirected stream, a Pkg that died on its first line all read as success. So
# it gets a POSITIVE CONTROL first: the same command, same environment, against
# the base depot, where the packages are installed and deliberately not
# precompiled. That run MUST match. Only then does a non-match downstream mean
# anything.
did_work () { grep -Eq '✓|successfully precompiled' "$1"; }

CONTROL="$WORK/depot-control"
rm -rf "$CONTROL"; cp -a "$BASE" "$CONTROL"
env JULIA_DEPOT_PATH="$CONTROL" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
  >"$WORK/pkgcontrol.log" 2>&1
did_work "$WORK/pkgcontrol.log" \
  && ok "control: against the un-precompiled base depot, Pkg.precompile() reports work -- the detection below can fail" \
  || bad "control: Pkg.precompile() reported NO work against a depot with nothing precompiled" \
         "the detection is broken and the check below would pass vacuously: $(tail -3 "$WORK/pkgcontrol.log" | tr '\n' '|')"

env JULIA_DEPOT_PATH="$WORK/depot-on" \
  julia --startup-file=no --project="$ENV_DIR" -e 'using Pkg; Pkg.precompile()' \
  >"$WORK/pkgcheck.log" 2>&1
PKGCHECK_RC=$?
check "Pkg.precompile() succeeds against the depot ajt add built" "0" "$PKGCHECK_RC"
if did_work "$WORK/pkgcheck.log"; then
  bad "Pkg.precompile() still had work to do, so ajt add's pass was incomplete" \
      "$(grep -E '✓|successfully precompiled' "$WORK/pkgcheck.log" | head -5 | tr '\n' '|')"
else
  ok "Pkg.precompile() compiled NOTHING -- it agrees the environment is done"
fi

# ...and the environment LOADS out of that depot, which is what a cache is for.
LOAD_OUT="$(env JULIA_DEPOT_PATH="$WORK/depot-on" \
  julia --startup-file=no --project="$ENV_DIR" -e "using $PKG; print(42)" 2>"$WORK/using.err")"
check "the environment loads from the depot ajt add precompiled" "42" "${LOAD_OUT:-}"
[ "${LOAD_OUT:-}" = "42" ] || tail -8 "$WORK/using.err" | sed 's/^/       /'

# ---------------------------------------------------------------------------
echo
echo "==> 3. JULIA_PKG_PRECOMPILE_AUTO=0 suppresses it entirely"

AUTO_SET=1 AUTO_VAL=0
run_add off0
OFF_RC=$?
AUTO_SET=0 AUTO_VAL=""
check "ajt add still exited cleanly with the pass disabled" "0" "$OFF_RC"
check "the package was still added" "1" \
  "$(awk -F'\t' '$1=="added" && $2=="'"$PKG"'" && length($3)==36' "$WORK/off0.records" | wc -l | tr -d ' ')"
# The record says WHY, which is what separates "the variable was read" from
# "something else happened to skip it".
check "the skip reason names the environment variable" "env_disabled" "$(pre_field off0 3)"
check "compiled/ is untouched: no new package directory at all" "0" "$(wc -l < "$WORK/off0.new" | tr -d ' ')"
if diff -q "$WORK/base.names" "$WORK/off0.names" >/dev/null; then
  ok "compiled/$JV is byte-for-byte the set it started as"
else
  bad "the suppressed run still wrote to compiled/" "$(diff "$WORK/base.names" "$WORK/off0.names" | head -6 | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 4. the truthy set is Base.get_bool_env's, spelling for spelling"
#
# `Base.get_bool_env` (`base/env.jl:142-160`) is not "the string is 1". Its
# tuples carry the Capitalized and UPPERCASE forms; an EMPTY value falls through
# to the default rather than reading as false; and a value in NEITHER tuple
# returns `nothing`, which Ajt resolves to the default because it cannot
# honestly reproduce the TypeError Pkg raises there after the install has
# already happened. Each of these is one real `ajt add`.
#
#   spelling            expected     why it is in the list
#   0                   off          section 3, the documented spelling
#   no                  off          falsy tuple -- a lowercase-five port misses it
#   NO                  off          the UPPERCASE form, which is the one that bites
#   yes                 on           truthy tuple, likewise
#   (empty)             on           `!isempty(val)` guard, env.jl:145
#   off                 on           unrecognised -> default, NOT false
spell_case () {
  local label="$1" value="$2" expect="$3" name="$4"
  AUTO_SET=1
  AUTO_VAL="$value"
  run_add "$name"
  local rc=$?
  AUTO_SET=0
  AUTO_VAL=""
  if [ $rc -ne 0 ]; then
    bad "JULIA_PKG_PRECOMPILE_AUTO=$label: ajt add failed (exit $rc)" "$(tail -3 "$WORK/$name.err" | tr '\n' '|')"
    return 0
  fi
  local new; new="$(wc -l < "$WORK/$name.new" | tr -d ' ')"
  if [ "$expect" = on ]; then
    [ "$new" -gt 0 ] && ok "JULIA_PKG_PRECOMPILE_AUTO=$label precompiles ($new new cache directories)" \
      || bad "JULIA_PKG_PRECOMPILE_AUTO=$label did NOT precompile, and Base.get_bool_env says it should" \
             "record: [$(grep '^precompile' "$WORK/$name.records" | tr '\t' ' ')]"
  else
    [ "$new" -eq 0 ] && ok "JULIA_PKG_PRECOMPILE_AUTO=$label does not precompile" \
      || bad "JULIA_PKG_PRECOMPILE_AUTO=$label precompiled $new packages, and Base.get_bool_env says it should not"
  fi
}

spell_case "no"      "no"  off sp_no
spell_case "NO"      "NO"  off sp_NO
spell_case "yes"     "yes" on  sp_yes
spell_case "(empty)" ""    on  sp_empty
spell_case "off"     "off" on  sp_off

# ---------------------------------------------------------------------------
echo
echo "==> 5. exactly ONE pass: \`edit\` installs through \`instantiate\`, and only one of them may precompile"
#
# A second pass is invisible in the depot -- it finds everything fresh, compiles
# nothing and writes nothing. What it CANNOT hide is the julia it has to start
# to ask what needs compiling: `precompile.run` always spawns one probe child
# before it decides anything (`src/ops/precompile.zig`, "what is already
# precompiled is a question only Julia can answer").
#
# So the measurement is differential. `--no-precompile` is the same run with the
# pass removed, and everything else about it -- the resolve, the install, the
# artifact pass -- starts the same julia children. The difference must therefore
# be exactly `1 probe + <compiled> children`:
#
#     one pass : (N + 1 + C) - N = C + 1
#     two      : (N + 1 + C + 1) - N = C + 2      <- the bug this rules out
run_add nopre --no-precompile
NOPRE_RC=$?
check "ajt add --no-precompile exited cleanly" "0" "$NOPRE_RC"
check "--no-precompile reports the flag as the reason" "disabled" "$(pre_field nopre 3)"
check "--no-precompile wrote nothing to compiled/" "0" "$(wc -l < "$WORK/nopre.new" | tr -d ' ')"

CALLS_ON="$(wc -l < "$WORK/on.calls" | tr -d ' ')"
CALLS_OFF="$(wc -l < "$WORK/nopre.calls" | tr -d ' ')"
# Non-vacuity: if ajt never ran the counting julia at all, both numbers are 0
# and the subtraction below is trivially whatever we expect.
[ "$CALLS_ON" -gt 0 ] \
  && ok "the run under test started $CALLS_ON julia children (against $CALLS_OFF with the pass off)" \
  || bad "no julia child was counted -- the shim prefix was not used and this section proves nothing"
check "the pass costs exactly one probe plus one child per compiled package" \
  "$(( ON_COMPILED + 1 ))" "$(( CALLS_ON - CALLS_OFF ))"

# ---------------------------------------------------------------------------
echo
echo "==> 6. the per-verb table: dev does not precompile, instantiate does"
#
# `API.jl:170` auto-precompiles after exactly `up`, `pin`, `free` and `build`;
# `add` gets its own call inside `Operations.add` (`Operations.jl:1828`); and
# `Operations.develop` (`Operations.jl:1839-1857`) has none at all, nor is
# `develop` in the API.jl tuple. So `Pkg.develop(path=...)` leaves an
# environment uncompiled, and ajt matches that rather than improving on it.

DEVPKG="$WORK/DevOnly"
mkdir -p "$DEVPKG/src"
cat > "$DEVPKG/Project.toml" <<'EOF'
name = "DevOnly"
uuid = "3f1c8d52-9a4b-4e77-8c31-6b0d2e5a91c4"
version = "0.1.0"
EOF
cat > "$DEVPKG/src/DevOnly.jl" <<'EOF'
module DevOnly
answer() = 42
end # module
EOF

DEPOT_DEV="$WORK/depot-dev"
rm -rf "$DEPOT_DEV"; cp -a "$BASE" "$DEPOT_DEV"
: > "$ENV_DIR/Project.toml"
rm -f "$ENV_DIR/Manifest.toml"
"$AJT" dev --depot "$DEPOT_DEV" --julia-prefix "$SHIM" --project "$ENV_DIR" "$DEVPKG" \
  >"$WORK/dev.records" 2>"$WORK/dev.err"
DEV_RC=$?
check "ajt dev exited cleanly" "0" "$DEV_RC"
[ "$DEV_RC" -eq 0 ] || head -10 "$WORK/dev.err" | sed 's/^/       /'
check "ajt dev tracked the path" "1" \
  "$(awk -F'\t' '$1=="developed" && $2=="DevOnly"' "$WORK/dev.records" | wc -l | tr -d ' ')"
check "ajt dev names the verb as the reason it did not precompile" "not_this_verb" \
  "$(awk -F'\t' '$1=="precompile" {print $3}' "$WORK/dev.records")"
names "$DEPOT_DEV" > "$WORK/dev.names"
check "ajt dev wrote nothing to compiled/" "0" \
  "$(comm -13 "$WORK/base.names" "$WORK/dev.names" | wc -l | tr -d ' ')"

# ...and the same environment, handed to `ajt instantiate`, DOES precompile it.
# That is the pairing that makes the line above a table rather than a hole:
# `dev` skipping the pass must not mean the environment is unreachable.
"$AJT" instantiate --frozen --depot "$DEPOT_DEV" --julia-prefix "$SHIM" "$ENV_DIR" \
  >"$WORK/inst.records" 2>"$WORK/inst.err"
INST_RC=$?
check "ajt instantiate exited cleanly over the developed environment" "0" "$INST_RC"
[ "$INST_RC" -eq 0 ] || tail -10 "$WORK/inst.err" | sed 's/^/       /'
INST_COMPILED="$(awk -F'\t' '$1=="precompile" {print $3}' "$WORK/inst.records")"
[ "${INST_COMPILED:-0}" -gt 0 ] \
  && ok "ajt instantiate precompiled $INST_COMPILED packages (Pkg.instantiate's allow_autoprecomp, API.jl:1398)" \
  || bad "ajt instantiate precompiled nothing" \
         "record: [$(grep '^precompile' "$WORK/inst.records" | tr '\t' ' ')]"
names "$DEPOT_DEV" > "$WORK/inst.names"
grep -qx "DevOnly" <(comm -13 "$WORK/base.names" "$WORK/inst.names") \
  && ok "the developed package itself has a cache directory" \
  || bad "DevOnly has no cache directory after ajt instantiate"

# ---------------------------------------------------------------------------
echo
echo "=========================================================================="
echo "  $PASS passed, $FAIL failed"
echo "=========================================================================="
[ $FAIL -eq 0 ] || exit 1
