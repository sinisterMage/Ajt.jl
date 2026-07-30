#!/usr/bin/env bash
# Differential gate for `ajt test` (src/ops/test.zig, src/ops/sandbox.zig).
#
# The claim: **`ajt test` and `Pkg.test`, run over the same environment into
# two equally-prepared depots, run the same `test/runtests.jl` in the same
# kind of sandbox — same dev'd source, same working directory, same julia
# flags, same ARGS, same sandbox project and (shape-for-shape) the same
# sandbox manifest — and fail the same way, with Pkg's exact sentence.**
#
# The sandbox is where the silent failures live, so the markers each fixture
# suite writes record the things a wrong sandbox would get wrong: `pathof` the
# package under test (a COPY instead of the dev'd source is the classic bug —
# an edit stops being visible to the next test run), `pathof` a test-only dep,
# the working directory (`gen_test_code` cd's into `test/`), the JLOptions the
# child actually ran under (`--check-bounds=yes` is the flag Pkg forces; a
# julia_args override must undo it on BOTH sides), the active project, the
# `@:<tmp>` load path, and `ARGS`. Everything session-invariant is compared
# ACROSS sides; the per-side facts (tmp paths) are checked structurally.
#
# Six sections:
#
#   0. THE FIXTURES. Six path-tracked packages, no registry, no network:
#        * `TargetsPkg`  -- the legacy layout: `[extras]` + `[targets] test`
#                           naming a stdlib (`Test`) and a real package
#                           (`Extra`). The sandbox project is GENERATED
#                           (`gen_target_project`).
#        * `TestProjPkg` -- ships `test/Project.toml` naming `Test` and
#                           `TPDep`. That file IS the sandbox project, and the
#                           package under test must be force-added to its
#                           `[deps]` (`Operations.jl:2283`).
#        * `FailPkg`     -- a suite that fails (`@test 1 == 2`).
#        * `NoTests`     -- no `test/` directory at all.
#        * `Extra`, `TPDep` -- the test-only deps the two shapes pull in.
#   1. THE [targets] SHAPE, with `--coverage`, `--julia-args
#      --check-bounds=no` and `--test-args foo "bar baz"` on both sides — one
#      run that exercises the whole flag surface. Markers compared field by
#      field; sandbox manifests compared shape for shape (Pkg's captured from
#      inside the sandbox via `test_fn`, ajt's via `--keep-sandbox`).
#   2. THE test/Project.toml SHAPE. Same, plus the force-added `[deps]` entry
#      in the sandbox project on both sides, and ajt's report saying
#      `test/Project.toml` rather than `targets`.
#   3. A FAILING SUITE. Non-zero exit on both sides, and ajt's `failure`
#      record decodes to the SENTENCE Pkg raised.
#   4. SEVERAL PACKAGES, ONE FAILING. `test` collects failures where `build`
#      aborts: the suite AFTER the failing one must still run, on both sides,
#      and the run must still exit non-zero with the same message.
#   5. THE ERRORS BEFORE ANY SUITE RUNS. A package without
#      `test/runtests.jl`, and a name that resolves to nothing — both must
#      produce Pkg's message, and no marker.
#   6. THE USER'S REAL DEPOT WAS NOT WRITTEN.
#
# ~/.julia is READ ONLY here: every julia (and every ajt test child) runs
# under a JULIA_DEPOT_PATH whose FIRST entry is a scratch depot, so all writes
# (precompile caches, logs) land there; the host depot is second so warm
# stdlib caches are still READ and the children start fast.
#
# NO NETWORK. Every package is path-tracked and the test deps are either
# stdlibs or path-tracked fixtures, so neither side ever wants a registry --
# which is also the configuration where ajt's stdlib fill (see
# `ops/sandbox.zig`) carries the whole weight, exactly the code this gate is
# for.
#
# Usage: test.sh [--keep]
#   --keep   leave $WORK behind
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
    # Every line of the header block, and nothing past it.
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
[ -x "$AJT" ] || { echo "ERROR: $AJT missing — run 'zig build' first" >&2; exit 2; }

JULIA_PREFIX="$(dirname "$(dirname "$(command -v julia)")")"

WORK="$(mktemp -d -t ajt-test-XXXXXX)" || exit 2
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: could not create a work directory" >&2; exit 2; }
cleanup() { [ $KEEP -eq 0 ] && { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; return 0; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

mkdir -p "$WORK/oracle" "$WORK/tmp"

# Oracle julia: scratch depot first (all writes land there), host second (warm
# caches are read, so `using Pkg` is fast).
jl() { JULIA_DEPOT_PATH="$WORK/oracle:$HOST_DEPOT" julia --startup-file=no "$@"; }
# One field out of a marker file.
field() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

echo "=== 0. Fixtures ==========================================================="

mk_pkg() { # name uuid  (module with a tag() so the suite can prove it loaded)
  mkdir -p "$WORK/src/$1/src"
  printf 'name = "%s"\nuuid = "%s"\nversion = "0.1.0"\n' "$1" "$2" > "$WORK/src/$1/Project.toml"
  printf 'module %s\ntag() = "%s"\nend\n' "$1" "$(echo "$1" | tr '[:upper:]' '[:lower:]')" > "$WORK/src/$1/src/$1.jl"
}

TARGETS_UUID="11111111-1111-1111-1111-111111111111"
TESTPROJ_UUID="22222222-2222-2222-2222-222222222222"
FAIL_UUID="33333333-3333-3333-3333-333333333333"
NOTESTS_UUID="44444444-4444-4444-4444-444444444444"
EXTRA_UUID="55555555-5555-5555-5555-555555555555"
TPDEP_UUID="66666666-6666-6666-6666-666666666666"
TEST_STDLIB_UUID="8dfed614-e22c-5e08-85e1-65c5234f0b40"

mk_pkg TargetsPkg  "$TARGETS_UUID"
mk_pkg TestProjPkg "$TESTPROJ_UUID"
mk_pkg FailPkg     "$FAIL_UUID"
mk_pkg NoTests     "$NOTESTS_UUID"
mk_pkg Extra       "$EXTRA_UUID"
mk_pkg TPDep       "$TPDEP_UUID"

# --- TargetsPkg: the [extras]+[targets] shape --------------------------------
cat >> "$WORK/src/TargetsPkg/Project.toml" <<EOF

[extras]
Extra = "$EXTRA_UUID"
Test = "$TEST_STDLIB_UUID"

[targets]
test = ["Test", "Extra"]
EOF
mkdir -p "$WORK/src/TargetsPkg/test"
# The marker records everything a wrong sandbox would get wrong. The path is
# passed through the environment so one source serves both sides without
# either seeing the other's output.
cat > "$WORK/src/TargetsPkg/test/runtests.jl" <<'JL'
using Test, TargetsPkg, Extra
open(ENV["AJT_TEST_MARKER"], "w") do io
    println(io, "pkg=", pathof(TargetsPkg))
    println(io, "extra=", pathof(Extra), ":", Extra.tag())
    println(io, "cwd=", pwd())
    println(io, "active=", something(Base.active_project(), "NONE"))
    println(io, "loadpath=", get(ENV, "JULIA_LOAD_PATH", "UNSET"))
    println(io, "juliaproject=", haskey(ENV, "JULIA_PROJECT"))
    println(io, "depot1=", abspath(first(Base.DEPOT_PATH)))
    println(io, "checkbounds=", Base.JLOptions().check_bounds)
    println(io, "depwarn=", Base.JLOptions().depwarn)
    println(io, "coverage=", Base.JLOptions().code_coverage)
    println(io, "startupfile=", Base.JLOptions().startupfile)
    println(io, "nthreads=", Threads.nthreads())
    println(io, "args=", join(ARGS, ","))
end
@testset "TargetsPkg" begin
    @test TargetsPkg.tag() == "targetspkg"
    @test Extra.tag() == "extra"
end
JL

# --- TestProjPkg: the test/Project.toml shape --------------------------------
# NOTE: the package under test is deliberately NOT in these [deps]. Pkg
# force-adds it (`Operations.jl:2283`) and section 2 asserts both sides did.
mkdir -p "$WORK/src/TestProjPkg/test"
cat > "$WORK/src/TestProjPkg/test/Project.toml" <<EOF
[deps]
TPDep = "$TPDEP_UUID"
Test = "$TEST_STDLIB_UUID"
EOF
cat > "$WORK/src/TestProjPkg/test/runtests.jl" <<'JL'
using Test, TestProjPkg, TPDep
open(ENV["AJT_TEST_MARKER"], "w") do io
    println(io, "pkg=", pathof(TestProjPkg))
    println(io, "tpdep=", pathof(TPDep), ":", TPDep.tag())
    println(io, "cwd=", pwd())
    println(io, "active=", something(Base.active_project(), "NONE"))
end
@testset "TestProjPkg" begin
    @test TPDep.tag() == "tpdep"
end
JL

# --- FailPkg: a suite that fails ---------------------------------------------
# It declares `Test` properly, so the failure is the `@test`, not a load error
# — the sentinel BEFORE the testset is what distinguishes "the suite ran and
# failed" from "the sandbox was broken and the suite never started", and both
# produce the same exit code and the same sentence.
cat >> "$WORK/src/FailPkg/Project.toml" <<EOF

[extras]
Test = "$TEST_STDLIB_UUID"

[targets]
test = ["Test"]
EOF
mkdir -p "$WORK/src/FailPkg/test"
cat > "$WORK/src/FailPkg/test/runtests.jl" <<'JL'
using Test
println("SENTINEL_FAILPKG_RAN")
@testset "FailPkg" begin
    @test 1 == 2
end
JL

# NoTests gets no test/ directory at all.

# --- the environment ---------------------------------------------------------
# Written by hand so BOTH tools see one identical, byte-stable environment.
mkdir -p "$WORK/env"
cat > "$WORK/env/Project.toml" <<EOF
[deps]
Extra = "$EXTRA_UUID"
FailPkg = "$FAIL_UUID"
NoTests = "$NOTESTS_UUID"
TPDep = "$TPDEP_UUID"
TargetsPkg = "$TARGETS_UUID"
TestProjPkg = "$TESTPROJ_UUID"
EOF
cat > "$WORK/env/Manifest.toml" <<EOF
# This file is machine-generated - editing it directly is not advised

julia_version = "$(jl -e 'print(VERSION)')"
manifest_format = "2.0"
project_hash = "0000000000000000000000000000000000000000"

[[deps.Extra]]
path = "../src/Extra"
uuid = "$EXTRA_UUID"
version = "0.1.0"

[[deps.FailPkg]]
path = "../src/FailPkg"
uuid = "$FAIL_UUID"
version = "0.1.0"

[[deps.NoTests]]
path = "../src/NoTests"
uuid = "$NOTESTS_UUID"
version = "0.1.0"

[[deps.TPDep]]
path = "../src/TPDep"
uuid = "$TPDEP_UUID"
version = "0.1.0"

[[deps.TargetsPkg]]
path = "../src/TargetsPkg"
uuid = "$TARGETS_UUID"
version = "0.1.0"

[[deps.TestProjPkg]]
path = "../src/TestProjPkg"
uuid = "$TESTPROJ_UUID"
version = "0.1.0"
EOF

# The placeholder hash becomes the real one so `Pkg.test`'s opening
# instantiate does not consider the manifest stale.
jl -e '
using Pkg
env = Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))
Pkg.Operations.record_project_hash(env)
Pkg.Types.write_manifest(env)' "$WORK/env" >/dev/null 2>&1 || true

mkdir -p "$WORK/depotA" "$WORK/depotB"

# Landmark: nothing has run, so no marker exists and no sandbox has been kept.
NOTHING=1
for p in "$WORK"/marker-* "$WORK/tmp/ajt-sandbox-"*; do
  [ -e "$p" ] && NOTHING=0
done
check "the corpus starts clean (no markers, no sandboxes)" 1 "$NOTHING"

# The sandbox-manifest shape: every entry's name, its version, its `path`
# (normalized), and whether it is tree-hash-pinned — read through TOML the way
# Julia will, not grepped. `version` is compared for REGISTRY-LESS entries
# only, i.e. the stdlibs ajt's fill wrote and Pkg's resolve solved — for a
# `path` entry the two sides legitimately differ (Pkg's sandbox resolve stamps
# the root's version; ajt documents that it does not resolve the sandbox), and
# Julia's loader never reads a version off a path entry anyway.
manifest_shape() { # workdir manifest
  jl -e '
using TOML
d = TOML.parsefile(ARGS[2])
for name in sort(collect(keys(get(d, "deps", Dict{String, Any}()))))
    for e in d["deps"][name]
        has_path = haskey(e, "path")
        println(name, "\t",
                has_path ? "-" : string(get(e, "version", "-")), "\t",
                has_path ? replace(e["path"], ARGS[1] => "<W>") : "-", "\t",
                haskey(e, "git-tree-sha1") ? "tree" : "-")
    end
end' "$1" "$2" 2>&1
}

echo
echo "=== 1. The [extras]+[targets] shape ======================================="

# Pkg's side. depotB first so every write lands in scratch; the host depot
# second so the child reads warm stdlib caches. `test_fn` runs INSIDE the
# sandbox before the child starts and captures the temp environment that Pkg
# deletes on the way out — the only window it is observable through.
#
# `| cat` is NOT decoration. Redirected straight to a file, the parent julia
# and its test child clobber each other: both hold the same open file
# description, and libuv's positional writes on a seekable fd land at each
# process's own offset — the parent's error text after a failing suite
# overwrites the child's output byte for byte. A pipe is not seekable, so both
# fall back to sequential writes and the transcript survives. (ajt's side
# needs no such crutch — that it composes under a PLAIN redirection is part of
# what this gate checks; the binary streams exactly to avoid this trap.)
# `set -o pipefail` above is what keeps $? julia's, not cat's.
AJT_TEST_MARKER="$WORK/marker-b-targets" \
AJT_GATE_CAPTURE="$WORK/cap-b-targets" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" -e '
using Pkg
Pkg.test("TargetsPkg";
    coverage = true,
    julia_args = `--check-bounds=no`,
    test_args = ["foo", "bar baz"],
    test_fn = function ()
        cap = ENV["AJT_GATE_CAPTURE"]
        mkpath(cap)
        proj = Base.active_project()
        cp(proj, joinpath(cap, "Project.toml"); force = true)
        cp(joinpath(dirname(proj), "Manifest.toml"), joinpath(cap, "Manifest.toml"); force = true)
        return nothing
    end)' 2>&1 | cat > "$WORK/pkg-targets.out"
PKG_RC=$?
check "Pkg.test(\"TargetsPkg\") exited 0" 0 "$PKG_RC"

# ajt's side, into the OTHER depot, same flags — including both `--julia-args`
# and `--test-args`, whose hand-off grammar is itself under test here.
AJT_TEST_MARKER="$WORK/marker-a-targets" \
  "$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" \
    --tmp-dir "$WORK/tmp" --keep-sandbox \
    --coverage \
    TargetsPkg \
    --julia-args --check-bounds=no --test-args foo "bar baz" \
    > "$WORK/ajt-targets.out" 2>"$WORK/ajt-targets.err"
AJT_RC=$?
check "ajt test TargetsPkg exited 0" 0 "$AJT_RC"

# Landmark: both suites really ran — the marker is written by the suite, and
# the summary line is printed by Test itself.
[ -s "$WORK/marker-b-targets" ] && ok "Pkg's suite wrote its marker" || bad "Pkg's suite wrote its marker"
[ -s "$WORK/marker-a-targets" ] && ok "ajt's suite wrote its marker" || bad "ajt's suite wrote its marker"
grep -q "Test Summary:" "$WORK/pkg-targets.out" && ok "Pkg's transcript has a Test Summary" \
  || bad "Pkg's transcript has a Test Summary" "$(tail -5 "$WORK/pkg-targets.out")"
grep -q "Test Summary:" "$WORK/ajt-targets.out" && ok "ajt's transcript has a Test Summary" \
  || bad "ajt's transcript has a Test Summary" "$(tail -5 "$WORK/ajt-targets.out")"

# The session-invariant marker fields, ACROSS sides. `pkg`/`extra` are the
# dev'd-source claim; `cwd` is `gen_test_code`'s cd; the JLOptions rows are
# `gen_subprocess_flags` (and `checkbounds` proves the caller's
# `--check-bounds=no` overrode the fixed `yes` on BOTH sides, because
# julia_args comes last); `args` is `test_args` into `ARGS`.
for f in pkg extra cwd juliaproject checkbounds depwarn coverage startupfile nthreads args; do
  check "marker '$f' agrees across sides ($(field "$WORK/marker-b-targets" $f))" \
    "$(field "$WORK/marker-b-targets" $f)" "$(field "$WORK/marker-a-targets" $f)"
done
check "the dev'd source is the working tree, not a copy" \
  "$WORK/src/TargetsPkg/src/TargetsPkg.jl" "$(field "$WORK/marker-a-targets" pkg)"
check "the suite ran in test/, as gen_test_code cd's" \
  "$WORK/src/TargetsPkg/test" "$(field "$WORK/marker-a-targets" cwd)"
check "test_args crossed the argv boundary intact" "foo,bar baz" "$(field "$WORK/marker-a-targets" args)"

# The per-side structure: the active project is the SANDBOX (not the parent
# env), and the load path is exactly `@:<sandbox>` with JULIA_PROJECT unset
# (`Operations.jl:2311`).
for side in a b; do
  M="$WORK/marker-$side-targets"
  ACTIVE="$(field "$M" active)"
  [ -n "$ACTIVE" ] && [ "$ACTIVE" != "$WORK/env/Project.toml" ] \
    && ok "[$side] the active project is the sandbox, not the parent env" \
    || bad "[$side] the active project is the sandbox, not the parent env" "$ACTIVE"
  check "[$side] JULIA_LOAD_PATH is @:<sandbox>" "@:$(dirname "$ACTIVE")" "$(field "$M" loadpath)"
done
case "$(field "$WORK/marker-a-targets" depot1)" in
  "$WORK/depotA"*) ok "ajt's child precompiles into the scratch depot" ;;
  *) bad "ajt's child precompiles into the scratch depot" "$(field "$WORK/marker-a-targets" depot1)" ;;
esac

# Coverage reached the child: `--code-coverage=@<package root>` makes it write
# .cov files next to the sources it tracked.
ls "$WORK/src/TargetsPkg/src/"*.cov >/dev/null 2>&1 \
  && ok "coverage wrote .cov files next to the tracked sources" \
  || bad "coverage wrote .cov files next to the tracked sources"
rm -f "$WORK/src/TargetsPkg/src/"*.cov "$WORK/src/TargetsPkg/test/"*.cov

# The report knows which shape it built.
check "ajt's report says the sandbox came from [targets]" "targets" \
  "$(awk -F'\t' '$1=="sandbox"{print $3}' "$WORK/ajt-targets.out")"

# The sandbox manifests, shape for shape. Pkg's was RESOLVED (its sandbox
# always is) and ajt's was pruned + stdlib-filled — if the fill or the prune
# is wrong, the entry sets differ and this goes red.
AJT_SANDBOX="$(awk -F'\t' '$1=="test"{print $5}' "$WORK/ajt-targets.out")"
[ -d "$AJT_SANDBOX" ] && ok "ajt kept its sandbox for inspection ($AJT_SANDBOX)" \
  || bad "ajt kept its sandbox for inspection" "$AJT_SANDBOX"
PKG_SHAPE="$(manifest_shape "$WORK" "$WORK/cap-b-targets/Manifest.toml")"
AJT_SHAPE="$(manifest_shape "$WORK" "$AJT_SANDBOX/Manifest.toml")"
[ -n "$PKG_SHAPE" ] || bad "Pkg's sandbox manifest was captured"
if [ "$PKG_SHAPE" = "$AJT_SHAPE" ]; then
  ok "the sandbox manifests agree, entry for entry ($(printf '%s' "$AJT_SHAPE" | wc -l | tr -d ' ') entries)"
else
  bad "the sandbox manifests agree, entry for entry" \
      "$(diff <(printf '%s\n' "$PKG_SHAPE") <(printf '%s\n' "$AJT_SHAPE") | head -20)"
fi

echo
echo "=== 2. The test/Project.toml shape ========================================"

AJT_TEST_MARKER="$WORK/marker-b-tp" \
AJT_GATE_CAPTURE="$WORK/cap-b-tp" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" -e '
using Pkg
Pkg.test("TestProjPkg";
    test_fn = function ()
        cap = ENV["AJT_GATE_CAPTURE"]
        mkpath(cap)
        proj = Base.active_project()
        cp(proj, joinpath(cap, "Project.toml"); force = true)
        cp(joinpath(dirname(proj), "Manifest.toml"), joinpath(cap, "Manifest.toml"); force = true)
        return nothing
    end)' 2>&1 | cat > "$WORK/pkg-tp.out"
PKG_RC=$?
check "Pkg.test(\"TestProjPkg\") exited 0" 0 "$PKG_RC"

AJT_TEST_MARKER="$WORK/marker-a-tp" \
  "$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" \
    --tmp-dir "$WORK/tmp" --keep-sandbox \
    TestProjPkg \
    > "$WORK/ajt-tp.out" 2>"$WORK/ajt-tp.err"
AJT_RC=$?
check "ajt test TestProjPkg exited 0" 0 "$AJT_RC"

# `TPDep` is declared ONLY in test/Project.toml, so it loading at all is the
# proof that file became the sandbox project on both sides.
for f in pkg tpdep cwd; do
  check "marker '$f' agrees across sides ($(field "$WORK/marker-b-tp" $f))" \
    "$(field "$WORK/marker-b-tp" $f)" "$(field "$WORK/marker-a-tp" $f)"
done
check "ajt's report says the sandbox came from test/Project.toml" "test/Project.toml" \
  "$(awk -F'\t' '$1=="sandbox"{print $3}' "$WORK/ajt-tp.out")"

# The force-add (`Operations.jl:2283`): test/Project.toml does NOT name
# TestProjPkg, and the sandbox project on BOTH sides must.
grep -q "TestProjPkg = \"$TESTPROJ_UUID\"" "$WORK/cap-b-tp/Project.toml" \
  && ok "Pkg force-added the package under test to the sandbox [deps]" \
  || bad "Pkg force-added the package under test to the sandbox [deps]" "$(cat "$WORK/cap-b-tp/Project.toml")"
AJT_SANDBOX="$(awk -F'\t' '$1=="test"{print $5}' "$WORK/ajt-tp.out")"
grep -q "TestProjPkg = \"$TESTPROJ_UUID\"" "$AJT_SANDBOX/Project.toml" 2>/dev/null \
  && ok "and so did ajt" \
  || bad "and so did ajt" "$(cat "$AJT_SANDBOX/Project.toml" 2>/dev/null)"

PKG_SHAPE="$(manifest_shape "$WORK" "$WORK/cap-b-tp/Manifest.toml")"
AJT_SHAPE="$(manifest_shape "$WORK" "$AJT_SANDBOX/Manifest.toml")"
[ -n "$PKG_SHAPE" ] || bad "Pkg's sandbox manifest was captured"
if [ "$PKG_SHAPE" = "$AJT_SHAPE" ]; then
  ok "the sandbox manifests agree, entry for entry ($(printf '%s' "$AJT_SHAPE" | wc -l | tr -d ' ') entries)"
else
  bad "the sandbox manifests agree, entry for entry" \
      "$(diff <(printf '%s\n' "$PKG_SHAPE") <(printf '%s\n' "$AJT_SHAPE") | head -20)"
fi

echo
echo "=== 3. A failing suite ===================================================="

JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.test("FailPkg")' 2>&1 | cat > "$WORK/pkg-fail.out"
PKG_RC=$?
[ "$PKG_RC" -ne 0 ] && ok "Pkg.test exits non-zero on a failing suite" \
  || bad "Pkg.test exits non-zero on a failing suite"

"$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" --tmp-dir "$WORK/tmp" \
    FailPkg \
    > "$WORK/ajt-fail.out" 2>"$WORK/ajt-fail.err"
AJT_RC=$?
check "ajt test exits 1 on a failing suite" 1 "$AJT_RC"

# Landmark: the suites RAN and FAILED — neither side refused before the child.
grep -q "SENTINEL_FAILPKG_RAN" "$WORK/pkg-fail.out" && ok "Pkg's child really ran the suite" \
  || bad "Pkg's child really ran the suite"
grep -q "SENTINEL_FAILPKG_RAN" "$WORK/ajt-fail.out" && ok "ajt's child really ran the suite" \
  || bad "ajt's child really ran the suite"

# THE SENTENCE. Pkg raises `Package FailPkg errored during testing`
# (`Operations.jl:2536-2538`); ajt's `failure` record must decode to exactly
# that. The exit code is 1, so NO "(exit code: …)" suffix on either side
# (`reason`, `:2526-2534`).
PKG_MSG="$(grep -o "Package FailPkg errored during testing[^\"]*" "$WORK/pkg-fail.out" | head -1)"
AJT_MSG="$(awk -F'\t' '$1=="failure"{print $2}' "$WORK/ajt-fail.out" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\\\/\\/g')"
check "both raise Pkg's sentence, suffix-free" "Package FailPkg errored during testing" "$PKG_MSG"
check "  and ajt's failure record decodes to the same sentence" "$PKG_MSG" "$AJT_MSG"
grep -q "Package FailPkg errored during testing" "$WORK/ajt-fail.err" \
  && ok "  which ajt also printed for the human on stderr" \
  || bad "  which ajt also printed for the human on stderr" "$(tail -3 "$WORK/ajt-fail.err")"

echo
echo "=== 4. Several packages, one failing ======================================"

# `test` COLLECTS failures (`Operations.jl:2430`), it does not abort the way
# `build` does: TargetsPkg comes after FailPkg and must still run, on both
# sides. Plain flags this time, so the marker also pins the fixed
# `--check-bounds=yes` that section 1's override hid.
rm -f "$WORK/marker-a-targets" "$WORK/marker-b-targets"
AJT_TEST_MARKER="$WORK/marker-b-targets" \
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.test(["FailPkg", "TargetsPkg"])' 2>&1 | cat > "$WORK/pkg-multi.out"
PKG_RC=$?
[ "$PKG_RC" -ne 0 ] && ok "Pkg.test exits non-zero when one of two suites fails" \
  || bad "Pkg.test exits non-zero when one of two suites fails"
[ -s "$WORK/marker-b-targets" ] && ok "Pkg still ran the suite AFTER the failing one" \
  || bad "Pkg still ran the suite AFTER the failing one"

AJT_TEST_MARKER="$WORK/marker-a-targets" \
  "$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" --tmp-dir "$WORK/tmp" \
    FailPkg TargetsPkg \
    > "$WORK/ajt-multi.out" 2>"$WORK/ajt-multi.err"
AJT_RC=$?
check "ajt test exits 1 when one of two suites fails" 1 "$AJT_RC"
[ -s "$WORK/marker-a-targets" ] && ok "ajt still ran the suite AFTER the failing one" \
  || bad "ajt still ran the suite AFTER the failing one"
check "ajt's report: failed FailPkg, ok TargetsPkg, in call order" "failed:FailPkg ok:TargetsPkg" \
  "$(awk -F'\t' '$1=="test"{printf "%s:%s ", $2, $3}' "$WORK/ajt-multi.out" | sed 's/ $//')"

# The fixed flags Pkg forces on every test child, now visible with no
# override in the way: bounds checking ON (`--check-bounds=yes`).
check "checkbounds=1 on both sides (the forced --check-bounds=yes)" \
  "1" "$(field "$WORK/marker-b-targets" checkbounds)"
check "  ajt agrees" "$(field "$WORK/marker-b-targets" checkbounds)" "$(field "$WORK/marker-a-targets" checkbounds)"
for f in depwarn coverage nthreads args; do
  check "marker '$f' agrees across sides ($(field "$WORK/marker-b-targets" $f))" \
    "$(field "$WORK/marker-b-targets" $f)" "$(field "$WORK/marker-a-targets" $f)"
done

# One failure of two → the singular message, still naming only the failed one.
PKG_MSG="$(grep -o "Package FailPkg errored during testing" "$WORK/pkg-multi.out" | head -1)"
AJT_MSG="$(awk -F'\t' '$1=="failure"{print $2}' "$WORK/ajt-multi.out" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\\\/\\/g')"
check "the failure message names only the package that failed" "Package FailPkg errored during testing" "$AJT_MSG"
check "  and matches Pkg's" "$PKG_MSG" "$AJT_MSG"

echo
echo "=== 5. The errors before any suite runs ==================================="

# --- no test/runtests.jl -----------------------------------------------------
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.test("NoTests")' > "$WORK/pkg-notests.out" 2>&1
PKG_RC=$?
[ "$PKG_RC" -ne 0 ] && ok "Pkg.test exits non-zero on a package without runtests" \
  || bad "Pkg.test exits non-zero on a package without runtests"

"$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" --tmp-dir "$WORK/tmp" \
    NoTests \
    > "$WORK/ajt-notests.out" 2>"$WORK/ajt-notests.err"
AJT_RC=$?
check "ajt test exits 1 on a package without runtests" 1 "$AJT_RC"

WANT="Package NoTests did not provide a \`test/runtests.jl\` file"
grep -qF "$WANT" "$WORK/pkg-notests.out" && ok "Pkg's message is the runtests sentence" \
  || bad "Pkg's message is the runtests sentence" "$(tail -3 "$WORK/pkg-notests.out")"
check "ajt raises the same sentence" "$WANT" \
  "$(awk -F'\t' '$1=="failure"{print $2}' "$WORK/ajt-notests.out")"

# --- an unresolvable name ----------------------------------------------------
JULIA_DEPOT_PATH="$WORK/depotB:$HOST_DEPOT" \
  julia --startup-file=no --project="$WORK/env" \
    -e 'using Pkg; Pkg.test("Zzqx")' > "$WORK/pkg-unres.out" 2>&1
PKG_RC=$?
[ "$PKG_RC" -ne 0 ] && ok "Pkg.test exits non-zero on an unresolvable name" \
  || bad "Pkg.test exits non-zero on an unresolvable name"

"$AJT" test --project "$WORK/env" \
    --depot "$WORK/depotA" --depot "$HOST_DEPOT" \
    --julia-prefix "$JULIA_PREFIX" --tmp-dir "$WORK/tmp" \
    Zzqx \
    > "$WORK/ajt-unres.out" 2>"$WORK/ajt-unres.err"
AJT_RC=$?
check "ajt test exits 1 on an unresolvable name" 1 "$AJT_RC"

# The first two lines are the contract; Pkg may append fuzzy Suggestions,
# which ajt documents away (`Ajt.DIFFERENCES[:test]`).
WANT="The following package names could not be resolved:
 * Zzqx (not found in project or manifest)"
PKG_MSG="$(grep -A1 "could not be resolved" "$WORK/pkg-unres.out" | head -2 | sed 's/^ERROR: //')"
AJT_MSG="$(awk -F'\t' '$1=="failure"{print $2}' "$WORK/ajt-unres.out" | sed 's/\\n/\n/g' | head -2)"
check "Pkg's message is the ensure_resolved shape" "$WANT" "$PKG_MSG"
check "  and ajt's matches it" "$WANT" "$AJT_MSG"

echo
echo "=== 6. The user's real depot was not written =============================="
# A $WORK-prefixed key in the host depot's logs is unambiguous evidence of a
# leak. Its absence is not proof of none, but it is the observable half.
LEAK=0
for f in "$HOST_DEPOT/logs/manifest_usage.toml" "$HOST_DEPOT/logs/scratch_usage.toml"; do
  [ -f "$f" ] && grep -q "$WORK" "$f" && LEAK=1
done
check "no fixture path leaked into $HOST_DEPOT" 0 "$LEAK"

echo
echo "=========================================================================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
