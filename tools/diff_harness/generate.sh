#!/usr/bin/env bash
# Differential gate for `ajt generate` (src/ops/generate.zig) against
# `Pkg.generate` (Pkg/src/generate.jl).
#
# `generate` writes exactly two files, and the interesting part is not that it
# writes them but WHAT goes in them: a `version`, a random v4 uuid, and an
# `authors` entry produced by a six-deep fallback chain whose corners are all
# invisible until you diff two tools byte for byte.
#
#   1. IDENTITY — five environments (git name+email, git name only, ENV only,
#      nothing at all, and an ENV var set to the EMPTY STRING) are each driven
#      through both tools with the SAME `HOME`, `XDG_CONFIG_HOME` and author
#      env vars, under `env -i` so nothing leaks in from this shell. The
#      produced `Project.toml` must be byte-identical apart from the uuid line,
#      and `src/<Pkg>.jl` byte-identical outright.
#
#      The corner that pays for the whole gate is case B: with a git `user.name`
#      and no email anywhere, Pkg writes `authors = ["Gate Tester "]` — a
#      TRAILING SPACE, because `"$name " * (email === nothing ? "" : ...)`
#      puts the space outside the conditional (`generate.jl:47`). Case E is the
#      other one: `USER=` (empty) beats the `"Unknown"` default, because the
#      ENV loop breaks on `!== nothing` rather than on non-emptiness.
#
#   2. UUID — the line the comparison masks is then checked on its own: it must
#      be a well-formed v4, i.e. `4` in the version nibble and one of `8 9 a b`
#      in the variant nibble, on BOTH sides.
#
#   3. SHAPE — exactly two files and one directory. No .gitignore, no test/,
#      no LICENSE. A generator that helpfully adds them produces a package
#      `Pkg.generate` never would.
#
#   4. REFUSALS — an existing directory, a name that is not an identifier, a
#      trailing slash (`Foo/` has an EMPTY basename in Julia, where every
#      platform basename says `Foo`), and `Foo.jl` producing package `Foo`.
#      Both tools must refuse the first three with the same message and accept
#      the fourth.
#
# VACUITY. Every case asserts a landmark before it compares: the authors line
# has to contain the identity the case configured, so a run where neither side
# read the git config — or where both silently produced `Unknown ` — is a
# failure rather than a green two-way agreement on nothing.
#
# Usage: tools/diff_harness/generate.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-generate-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"
[ -x "$AJT" ] || { echo "ERROR: $AJT missing" >&2; exit 2; }

# Julia reads Pkg out of the sysimage, but it still wants a depot to write its
# undo journal into; point it somewhere disposable rather than at the user's.
DEPOT="$WORK/depot"
mkdir -p "$DEPOT"

# The idiom every other gate here uses.
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
# `assert <label> <note> <command...>` — the command's exit status is the test.
assert() { local label="$1" note="$2"; shift 2; if "$@"; then ok "$label"; else bad "$label" "$note"; fi; }

# EVERY invocation of either tool goes through one of these, so the environment
# both sides see is built in exactly one place. `env -i` is not a nicety: this
# shell has USER, NAME and a real ~/.gitconfig, all of which are inputs to the
# very chain under test. `$CASE_HOME` and `$CASE_ENV` are what a case varies.
CASE_HOME="$WORK/nohome"
CASE_ENV=()
in_env() { ( cd "$1" && shift && env -i \
  "PATH=$PATH" "HOME=$CASE_HOME" "XDG_CONFIG_HOME=$CASE_HOME/.config" \
  "JULIA_DEPOT_PATH=$DEPOT" "JULIA_PKG_OFFLINE=true" "${CASE_ENV[@]}" "$@" ); }
jl()  { in_env "$1" julia --startup-file=no "${@:2}"; }
ajt_() { in_env "$1" "$AJT" "${@:2}"; }

# ---------------------------------------------------------------------------
# 1. IDENTITY  (+ 2. UUID and 3. SHAPE, which every identity case also checks)
# ---------------------------------------------------------------------------

run_case() { # label gitname gitmail expected-authors-line [ENV=VAL...]
  local label="$1" gitname="$2" gitmail="$3" want="$4"; shift 4
  local dir="$WORK/case-$label"
  CASE_HOME="$dir/home"
  CASE_ENV=("$@")
  mkdir -p "$CASE_HOME/.config/git" "$dir/pkg" "$dir/ajt"

  # A global git config, or none. `--global` is the scope libgit2's default
  # config and `git config --global` agree on, which is the whole reason
  # git/cli.zig probes that scope rather than a bare `git config --get`.
  if [ -n "$gitname" ] || [ -n "$gitmail" ]; then
    {
      echo "[user]"
      [ -n "$gitname" ] && echo "  name = $gitname"
      [ -n "$gitmail" ] && echo "  email = $gitmail"
    } > "$CASE_HOME/.gitconfig"
  fi

  jl   "$dir/pkg" -e 'using Pkg; Pkg.generate("Widget")' >"$dir/pkg.out" 2>&1
  ajt_ "$dir/ajt" generate Widget                        >"$dir/ajt.out" 2>&1

  local pj="$dir/pkg/Widget/Project.toml"
  local aj="$dir/ajt/Widget/Project.toml"
  if [ ! -f "$pj" ]; then
    bad "identity-$label" "Pkg.generate produced no Project.toml: $(head -3 "$dir/pkg.out" | tr '\n' ' ')"
    return
  fi
  if [ ! -f "$aj" ]; then
    bad "identity-$label" "ajt generate produced no Project.toml: $(head -3 "$dir/ajt.out" | tr '\n' ' ')"
    return
  fi

  # LANDMARK. Without this the whole case passes when both sides fall all the
  # way through to `Unknown ` for reasons that have nothing to do with the
  # configuration under test.
  if ! grep -qxF "$want" "$pj"; then
    bad "identity-$label" "Pkg wrote $(grep '^authors' "$pj" || echo '<no authors line>'), expected $want"
    return
  fi
  ok "landmark-$label"

  # The uuid is random by construction, so it is the one line masked.
  sed 's/^uuid = ".*"$/uuid = <MASKED>/' "$pj" > "$dir/pkg.masked"
  sed 's/^uuid = ".*"$/uuid = <MASKED>/' "$aj" > "$dir/ajt.masked"
  assert "project-$label" \
    "$(diff "$dir/pkg.masked" "$dir/ajt.masked" | tr '\n' ' ' | head -c 200)" \
    cmp -s "$dir/pkg.masked" "$dir/ajt.masked"
  assert "entrypoint-$label" "src/Widget.jl differs" \
    cmp -s "$dir/pkg/Widget/src/Widget.jl" "$dir/ajt/Widget/src/Widget.jl"

  local side uuid listing
  for side in pkg ajt; do
    # 2. UUID: a well-formed v4 — `4` in the version nibble, `8 9 a b` in the
    #    variant one. This is the line the comparison above masked out.
    uuid="$(sed -n 's/^uuid = "\(.*\)"$/\1/p' "$dir/$side/Widget/Project.toml")"
    if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
      ok "uuid-$label-$side"
    else
      bad "uuid-$label-$side" "not a well-formed v4: '$uuid'"
    fi
    # 3. SHAPE: exactly Project.toml + src/<Pkg>.jl. No .gitignore, no test/,
    #    no LICENSE.
    listing="$( cd "$dir/$side/Widget" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ' )"
    if [ "$listing" = "./Project.toml ./src ./src/Widget.jl " ]; then
      ok "shape-$label-$side"
    else
      bad "shape-$label-$side" "unexpected tree: $listing"
    fi
  done
}

echo "==> identity fallback chain"
# A: git name AND git email.
run_case A "Gate Tester" "gate@example.com" 'authors = ["Gate Tester <gate@example.com>"]'
# B: git name, NO email anywhere -> the trailing space (generate.jl:47).
run_case B "Gate Tester" "" 'authors = ["Gate Tester "]'
# C: no git config at all; the ENV chain supplies both, independently.
run_case C "" "" 'authors = ["ci-user <ci@example.com>"]' USER=ci-user EMAIL=ci@example.com
# D: nothing anywhere -> the "Unknown" default, also with the trailing space.
run_case D "" "" 'authors = ["Unknown "]'
# E: USER set to the EMPTY STRING wins the loop, so "Unknown" never fires
#    (`name !== nothing && break`, generate.jl:33).
run_case E "" "" 'authors = [" <ci@example.com>"]' USER= EMAIL=ci@example.com
# F: git name beats the ENV chain, and GIT_AUTHOR_EMAIL beats EMAIL.
run_case F "Gate Tester" "" 'authors = ["Gate Tester <first@example.com>"]' \
  USER=ignored GIT_AUTHOR_EMAIL=first@example.com EMAIL=second@example.com

# ---------------------------------------------------------------------------
# 4. REFUSALS, and the `.jl` chop
# ---------------------------------------------------------------------------

echo "==> refusals"
REF="$WORK/refusals"
CASE_HOME="$WORK/nohome"
CASE_ENV=()
mkdir -p "$REF/pkg/Taken" "$REF/ajt/Taken"

refuse_case() { # label argument expected-substring
  local label="$1" arg="$2" want="$3"
  jl "$REF/pkg" -e 'using Pkg; try; Pkg.generate(ARGS[1]); println("ACCEPTED"); catch e; println(sprint(showerror, e)); end' \
    "$arg" >"$REF/pkg-$label.out" 2>&1
  ajt_ "$REF/ajt" generate "$arg" >"$REF/ajt-$label.out" 2>&1
  local code=$?

  # VACUITY: a "refusal" fixture Pkg happily accepts would have both sides
  # printing nothing and agreeing about it.
  if grep -q "ACCEPTED" "$REF/pkg-$label.out"; then
    bad "refuse-$label" "Pkg ACCEPTED it — the fixture does not test a refusal"
    return
  fi
  if ! grep -qF "$want" "$REF/pkg-$label.out"; then
    bad "refuse-$label" "Pkg said: $(head -1 "$REF/pkg-$label.out")"
    return
  fi
  ok "refuse-$label-pkg"
  if [ "$code" -eq 0 ]; then
    bad "refuse-$label" "ajt exited 0"
    return
  fi
  assert "refuse-$label-ajt" \
    "ajt said: $(head -1 "$REF/ajt-$label.out"), expected to contain: $want" \
    grep -qF "$want" "$REF/ajt-$label.out"
}

refuse_case existing   "Taken"     "already exists"
refuse_case identifier "Bad-Name"  '"Bad-Name" is not a valid package name'
# Julia's basename does NOT strip a trailing separator, so this is the EMPTY
# name. std.fs.path.basename would have said "Foo" and generated a package.
refuse_case trailing   "Bar/"      '"" is not a valid package name'
refuse_case reserved   "true"      '"true" is not a valid package name'
refuse_case numeric    "9Lives"    '"9Lives" is not a valid package name'

echo "==> the .jl chop"
CHOP="$WORK/chop"
mkdir -p "$CHOP/pkg" "$CHOP/ajt"
jl   "$CHOP/pkg" -e 'using Pkg; Pkg.generate("Widget.jl")' >/dev/null 2>&1
ajt_ "$CHOP/ajt" generate Widget.jl                        >/dev/null 2>&1
# The DIRECTORY keeps the .jl, the package and the entry file do not — three
# different strings a naive port collapses into one.
for side in pkg ajt; do
  if [ -f "$CHOP/$side/Widget.jl/src/Widget.jl" ] && \
     grep -qx 'name = "Widget"' "$CHOP/$side/Widget.jl/Project.toml" 2>/dev/null; then
    ok "chop-$side"
  else
    bad "chop-$side" "Widget.jl/ did not produce package Widget with src/Widget.jl"
  fi
done
assert "chop-entrypoint" "entry files differ" \
  cmp -s "$CHOP/pkg/Widget.jl/src/Widget.jl" "$CHOP/ajt/Widget.jl/src/Widget.jl"

# ---------------------------------------------------------------------------

echo
echo "  agreements : $PASS"
echo "  failures   : $FAIL"

if [ "$FAIL" -gt 0 ]; then
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — ajt generate agrees with Pkg.generate across $PASS assertions"
