#!/usr/bin/env bash
# Differential gate for `ajt manifest current` / `ajt manifest upgrade`
# (src/ops/manifest_ops.zig) against `Pkg.is_manifest_current` and
# `Pkg.upgrade_manifest`.
#
# Six sections:
#
#   1. THE TRI-STATE. `Pkg.is_manifest_current` returns `true`, `false` OR
#      `nothing`, and the third value is the entire reason the function exists:
#      `nothing` means no hash was ever recorded to disagree with, and Pkg's own
#      callers test `=== false` (`API.jl:1321`, `Operations.jl:3059`) precisely
#      so that it reads as "carry on" rather than as "stale". A gate that only
#      checked true/false would pass with the tri-state collapsed, so FIVE of
#      the eight cases here are `nothing`-shaped and each reaches it by a
#      different route: no `project_hash` key, no manifest file at all, a v1
#      manifest (whose root is entirely deps, so a top-level hash cannot
#      exist), an EMPTY manifest file (which `read_manifest` promotes to v2 for
#      convenience, `manifest.jl:257-261`), and a DIRECTORY named Manifest.toml
#      (because `read_manifest`'s predicate is `isfile`, not "the open returned
#      ENOENT"). Julia's answer is computed for every case and ajt's exit status
#      must match all eight.
#
#   2. THE REAL ENVIRONMENT. Open-Reality, where the answer is `true` and the
#      recorded hash is a real one — so the gate is not made only of fixtures.
#
#   3. UPGRADE, BYTE FOR BYTE. Every genuine v1 manifest in the depot (there
#      are three in a stock one: PackageCompiler, FreeType, ResultTypes) plus a
#      synthetic one, upgraded by BOTH tools from identical copies and diffed.
#      `Pkg.upgrade_manifest` is also required to have actually changed its
#      copy, so a no-op on both sides cannot pass as agreement.
#
#   4. ALREADY v2 IS UNTOUCHED. `upgrade_manifest` is not idempotent: Pkg
#      raises on a v2 manifest (`API.jl:1717-1719`) rather than rewriting it.
#      ajt must raise too, with Pkg's own sentence, and must leave the file's
#      bytes AND its mtime to the nanosecond exactly as they were.
#
#   5. WHICH FILE. Everything above is worthless if the two tools are looking at
#      different manifests, and they can: `Base.manifest_names` puts
#      `Manifest-v<major>.<minor>.toml` AHEAD of `Manifest.toml`
#      (`base/loading.jl:631-636`), and a project may redirect with
#      `manifest = "…"`. Every `manifest current` record's file is compared to
#      `EnvCache(...).manifest_file`, and section 5 upgrades an environment that
#      carries BOTH a v1 `Manifest-v<major>.<minor>.toml` and a decoy
#      `Manifest.toml`, requiring the decoy to survive byte-intact. Both verbs
#      are invoked with `--julia-prefix`/`--julia-version` exactly as
#      `julia/src/Ajt.jl` invokes them (`_julia_args`), because that is the only
#      way the version-specific name can be built at all.
#
#   6. THROUGH THE WRAPPER. Sections 1-5 drive the binary and pass
#      `--julia-prefix`/`--julia-version` by hand, so a `julia/src/Ajt.jl` that
#      forgets them sends a correct binary at the wrong file and every check
#      above stays green. This section drives both entry points through the
#      wrapper against an environment where the right file and a decoy are BOTH
#      v1, so a wrong-file upgrade succeeds silently and only the two
#      identity assertions can catch it.
#
# Every julia process writes to a scratch depot, because merely constructing an
# `EnvCache` writes `logs/manifest_usage.toml` into depots1 (`Types.jl:426`).
#
# Usage: manifest_ops.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
ENGINE="$REPO_ROOT/Open-Reality"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-manifest-ops-XXXXXX)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok()   { echo "  ok   $*"; }
expect_eq() { # got want label
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3
    want: $2
    got : $1"; fi
}

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

JDEPOT="$WORK/jdepot"
mkdir -p "$JDEPOT"
REAL_DEPOT="$(julia --startup-file=no -e 'print(first(Base.DEPOT_PATH))')"
[ -n "$REAL_DEPOT" ] || { echo "ERROR: could not determine the depot" >&2; exit 2; }
jl() { JULIA_DEPOT_PATH="$JDEPOT:$REAL_DEPOT" julia --startup-file=no "$@"; }

# `_julia_args()` from julia/src/Ajt.jl:207 — `dirname(Sys.BINDIR)` and
# `string(VERSION)`. The wrapper passes these on every call, so the gate must
# too: without them neither verb can build the version-specific manifest name,
# and section 5 would be testing an invocation nobody makes.
read -r JULIA_PREFIX JV <<EOF
$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR), " ", VERSION)')
EOF
[ -n "$JULIA_PREFIX" ] && [ -n "$JV" ] || { echo "ERROR: could not derive --julia-prefix/--julia-version" >&2; exit 2; }
ajt() { "$AJT" "$1" "$2" --julia-prefix "$JULIA_PREFIX" --julia-version "$JV" "${@:3}"; }

# Bytes + mtime to the nanosecond + size. This is what "wrote nothing" and
# "left byte-identical" both have to survive.
stamp() { find "$1" -printf '%p\t%T@\t%s\t%y\n' 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
# 1. The tri-state
# ---------------------------------------------------------------------------
echo "==> 1. is_manifest_current: the tri-state"

LINALG_UUID="37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
PROJ_UUID="99999999-8888-7777-6666-555555555555"

# The placeholder must be a well-formed SHA-1: Julia parses `project_hash`
# eagerly on read (`SHA1(raw["project_hash"])`, `manifest.jl:187`), so a literal
# "PLACEHOLDER" makes the oracle throw before it can compute anything.
ZERO="0000000000000000000000000000000000000000"

make_project() { # dir
  mkdir -p "$1"
  cat > "$1/Project.toml" <<EOF
name = "Fixture"
uuid = "$PROJ_UUID"
version = "0.1.0"

[deps]
LinearAlgebra = "$LINALG_UUID"
EOF
}

make_v2_manifest() { # dir [hash]
  cat > "$1/Manifest.toml" <<EOF
julia_version = "1.12.6"
manifest_format = "2.0"
project_hash = "${2:-$ZERO}"

[[deps.LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
}

# match:           the manifest records this project's own hash            -> true
make_project "$WORK/match";          make_v2_manifest "$WORK/match"
# mismatch:        it records a hash, but a different one                  -> false
make_project "$WORK/mismatch";       make_v2_manifest "$WORK/mismatch"
# no_hash:         a v2 manifest with the project_hash line deleted        -> nothing
make_project "$WORK/no_hash";        make_v2_manifest "$WORK/no_hash"
sed -i '/^project_hash = /d' "$WORK/no_hash/Manifest.toml"
# no_manifest:     a project with no manifest beside it at all             -> nothing
make_project "$WORK/no_manifest"
# v1:              the pre-1.6.2 layout, whose root IS the deps table, so a
#                  top-level `project_hash` cannot exist                   -> nothing
make_project "$WORK/v1"
cat > "$WORK/v1/Manifest.toml" <<EOF
[[LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
# empty_manifest:  a zero-byte file, which read_manifest promotes to v2
#                  (manifest.jl:257-261) -- still no hash                  -> nothing
make_project "$WORK/empty_manifest"
: > "$WORK/empty_manifest/Manifest.toml"
# manifest_is_dir: a DIRECTORY named Manifest.toml. `read_manifest`'s predicate
#                  is `isfile(f_or_io)` (manifest.jl:245-250), not "the open
#                  failed with ENOENT", so this is another "there is no
#                  manifest" -> nothing. Reachable through `--manifest`, a
#                  `manifest = "..."` redirect, or just a stray directory.
make_project "$WORK/manifest_is_dir"
mkdir -p "$WORK/manifest_is_dir/Manifest.toml"
# no_project:      nothing at all. `projectfile_path(strict=true)` returns
#                  nothing and Pkg raises; this is NOT one of the three answers.
mkdir -p "$WORK/no_project"

CASES=(match mismatch no_hash no_manifest v1 empty_manifest manifest_is_dir no_project)

# Fill in the true project_hash from JULIA -- the value under test is never
# computed by the tool being tested.
BASE_HASH="$(jl -e '
using Pkg
print(Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' "$WORK/match")"
[ ${#BASE_HASH} -eq 40 ] || { echo "ERROR: project_hash oracle returned '$BASE_HASH'" >&2; exit 2; }
sed -i "s/^project_hash = .*/project_hash = \"$BASE_HASH\"/" "$WORK/match/Manifest.toml"
# `mismatch` keeps the all-zero placeholder, which is a hash the project could
# not possibly have.

# Julia's verdict for every case, in ONE process. `nothing` prints as "nothing",
# and a raise prints as "error" -- three answers plus the not-an-answer.
jl -e '
using Pkg
for case in ARGS[2:end]
    d = joinpath(ARGS[1], case)
    answer = try
        string(Pkg.is_manifest_current(d))
    catch
        "error"
    end
    println(case, " ", answer)
end' "$WORK" "${CASES[@]}" > "$WORK/julia_cases.txt" 2>"$WORK/julia_cases.err" || {
  echo "ERROR: is_manifest_current oracle failed" >&2; tail -10 "$WORK/julia_cases.err" >&2; exit 2; }
sed 's/^/    julia: /' "$WORK/julia_cases.txt"

# LANDMARK: the corpus really ran, and it really covers all three answers plus
# the raise. Without this a gate over seven `false`s would look identical to a
# gate over seven correct answers.
expect_eq "$(wc -l < "$WORK/julia_cases.txt")" "${#CASES[@]}" "julia answered every one of the ${#CASES[@]} cases"
for want in true false nothing error; do
  n="$(awk -v w="$want" '$2 == w' "$WORK/julia_cases.txt" | wc -l)"
  [ "$n" -gt 0 ] \
    && ok "the corpus contains $n case(s) whose Pkg answer is \`$want\`" \
    || fail "no case in the corpus produces \`$want\` from Pkg.is_manifest_current — the gate cannot prove that answer"
done
# ...and specifically that `nothing` is reached by more than one route, since
# collapsing it into `false` is the exact bug this gate exists to catch.
NOTHINGS="$(awk '$2 == "nothing"' "$WORK/julia_cases.txt" | wc -l)"
[ "$NOTHINGS" -ge 5 ] \
  && ok "\`nothing\` is reached by $NOTHINGS different routes (no key / no file / v1 / empty / a directory)" \
  || fail "only $NOTHINGS case(s) reach \`nothing\`; the tri-state is barely exercised"

# 0 true, 1 false, 2 nothing, 3 no answer. See `manifest options` in `ajt help`.
# `:-` on every lookup: under `set -u` an unset key aborts the whole script
# mid-run, which drops every remaining assertion silently instead of failing
# one.
declare -A WANT_RC=( [true]=0 [false]=1 [nothing]=2 [error]=3 )

# The file Julia would read for each case. Compared against field 3 of ajt's
# record: every assertion in this section is meaningless if the two tools are
# answering about different files, and `manifestfile_path`'s probe order has a
# version-specific name ahead of `Manifest.toml`.
jl -e '
using Pkg
for case in ARGS[2:end]
    d = joinpath(ARGS[1], case)
    f = try
        Pkg.Types.EnvCache(joinpath(d, "Project.toml")).manifest_file
    catch
        "<error>"
    end
    println(case, "\t", f)
end' "$WORK" "${CASES[@]}" > "$WORK/manifest_files.txt" 2>/dev/null
declare -A PKG_MANIFEST=()
while IFS=$'\t' read -r case f; do PKG_MANIFEST[$case]="$f"; done < "$WORK/manifest_files.txt"

while read -r case answer; do
  d="$WORK/$case"
  stamp "$d" > "$WORK/out/$case.before"
  ajt manifest current "$d" > "$WORK/out/$case.txt" 2>&1
  rc=$?
  stamp "$d" > "$WORK/out/$case.after"

  expect_eq "$rc" "${WANT_RC[$answer]:-<unmapped>}" "$case: exit $rc agrees with Pkg.is_manifest_current === $answer"

  # ...and about the same file. `no_project` is excluded: Pkg raises before it
  # has a manifest_file to name.
  if [ "$answer" != "error" ]; then
    got_file="$(sed -n 's/^manifest_current\t[a-z]*\t\([^\t]*\)\t.*/\1/p' "$WORK/out/$case.txt")"
    expect_eq "${got_file:-<none>}" "${PKG_MANIFEST[$case]:-<unmapped>}" "$case: answered about the file EnvCache reads"
  fi

  # The printed word has to agree too: the Julia wrapper reads the record, not
  # the exit code, so a record that said `false` while exiting 2 would be a
  # silently split answer.
  got="$(sed -n 's/^manifest_current\t\([a-z]*\)\t.*/\1/p' "$WORK/out/$case.txt")"
  [ "$answer" = "error" ] && got="$(sed -n 's/^manifest_current\t\(error\)\t.*/\1/p' "$WORK/out/$case.txt")"
  expect_eq "${got:-<none>}" "$answer" "$case: the printed record says \`$answer\` too"

  if diff -q "$WORK/out/$case.before" "$WORK/out/$case.after" >/dev/null; then
    ok "$case: read-only — nothing under the environment changed"
  else
    fail "$case: \`manifest current\` wrote something:
$(diff "$WORK/out/$case.before" "$WORK/out/$case.after")"
  fi
done < "$WORK/julia_cases.txt"

# The two hashes are reported, and they are Julia's. `match` proves the recorded
# one is echoed verbatim; `mismatch` proves the computed one is the real
# workspace_resolve_hash rather than an echo of whatever was recorded.
grep -q "$BASE_HASH	$BASE_HASH" "$WORK/out/match.txt" \
  && ok "match: both reported hashes are Pkg.Types.workspace_resolve_hash's ($BASE_HASH)" \
  || fail "match did not report julia's hash twice:
$(sed 's/^/      /' "$WORK/out/match.txt")"
grep -q "$ZERO	$BASE_HASH" "$WORK/out/mismatch.txt" \
  && ok "mismatch: reports the recorded hash and the computed one, and they differ" \
  || fail "mismatch did not report both hashes:
$(sed 's/^/      /' "$WORK/out/mismatch.txt")"
# `nothing` must NOT carry a computed hash: Julia's `else` branch returns before
# calling workspace_resolve_hash at all, so reporting one would be reporting a
# digest Pkg never took.
grep -q "nothing	.*	-	-" "$WORK/out/no_hash.txt" \
  && ok "no_hash: no digest is reported, because Pkg's \`nothing\` branch never takes one" \
  || fail "no_hash reported a hash it should not have:
$(sed 's/^/      /' "$WORK/out/no_hash.txt")"

# ---------------------------------------------------------------------------
# 2. The real environment
# ---------------------------------------------------------------------------
echo "==> 2. the real environment: $ENGINE"

if [ -f "$ENGINE/Project.toml" ]; then
  J_REAL="$(jl -e 'using Pkg; print(Pkg.is_manifest_current(ARGS[1]))' "$ENGINE")"
  ajt manifest current "$ENGINE" > "$WORK/real.txt" 2>&1
  A_REAL=$?
  sed 's/^/    /' "$WORK/real.txt"
  expect_eq "$A_REAL" "${WANT_RC[$J_REAL]:-<unmapped>}" "the engine environment agrees with Pkg (=== $J_REAL)"
  # A landmark on the corpus itself: this environment records a REAL hash, so
  # section 1's fixtures are not the only thing being compared.
  REAL_HASH="$(jl -e '
using Pkg
print(Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml"))))' "$ENGINE")"
  grep -q "$REAL_HASH" "$WORK/real.txt" \
    && ok "and reports the engine's real project_hash ($REAL_HASH)" \
    || fail "the engine's project_hash ($REAL_HASH) is not in the report"
else
  echo "  NOTE: $ENGINE has no Project.toml; skipping the real-environment check"
fi

# ---------------------------------------------------------------------------
# 3. upgrade_manifest, byte for byte
# ---------------------------------------------------------------------------
echo "==> 3. upgrade_manifest"

# Every genuine v1 manifest in the depot. A stock depot carries a handful,
# shipped inside packages' docs/ and gen/ environments.
#
# The grep is only a CANDIDATE sweep: "no `manifest_format` key" is
# `Base.is_v1_format_manifest` (`base/loading.jl:970-981`) but NOT the whole of
# `read_manifest`, which promotes an empty parse to v2 for convenience
# (`manifest.jl:257-261`). A stock depot contains exactly that file —
# `PackageCompiler/*/examples/MyLib/Manifest.toml` is nothing but the
# machine-generated banner — and feeding it to `upgrade_manifest` gets "already
# up to date", not an upgrade. So the candidates are filtered by asking Pkg's
# own reader what format it thinks each one is.
CANDIDATES=()
while IFS= read -r f; do
  [ -n "$f" ] && CANDIDATES+=("$f")
done < <(grep -rLs '^manifest_format' --include=Manifest.toml "$REAL_DEPOT/packages" 2>/dev/null | head -8)
V1S=()
if [ ${#CANDIDATES[@]} -gt 0 ]; then
  jl -e '
using Pkg
for f in ARGS
    fmt = try
        string(Pkg.Types.read_manifest(f).manifest_format)
    catch
        "unreadable"
    end
    println(fmt, "\t", f)
end' "${CANDIDATES[@]}" > "$WORK/candidates.txt" 2>/dev/null
  while IFS=$'\t' read -r fmt f; do
    [ "$fmt" = "1.0.0" ] && V1S+=("$f")
  done < "$WORK/candidates.txt"
  sed 's/^/    candidate: /' "$WORK/candidates.txt"
fi
REAL_V1S=${#V1S[@]}
echo "  ${#CANDIDATES[@]} candidate(s) in $REAL_DEPOT/packages, $REAL_V1S of them v1 by Pkg's own reader"

# Plus a synthetic one, so the gate does not silently weaken on a depot that
# happens to carry none. It has the shape that matters: root arrays, an
# array-form `deps` that resolves against the file, and a bare stdlib entry.
mkdir -p "$WORK/synthetic"
cat > "$WORK/synthetic/Manifest.toml" <<'EOF'
# This file is machine-generated - editing it directly is not advised

[[Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[Printf]]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
EOF
V1S+=("$WORK/synthetic/Manifest.toml")

UPGRADED=0
n=0
for f in "${V1S[@]}"; do
  n=$((n + 1))
  A="$WORK/out/up$n.pkg.toml"   # Pkg.upgrade_manifest writes this one
  B="$WORK/out/up$n.ajt.toml"   # ajt manifest upgrade writes this one
  cp "$f" "$A"; cp "$f" "$B"; chmod u+w "$A" "$B"

  jl -e 'using Pkg; Pkg.upgrade_manifest(ARGS[1])' "$A" >"$WORK/out/up$n.pkg.log" 2>&1 || {
    fail "Pkg.upgrade_manifest failed on $f:
$(sed 's/^/      /' "$WORK/out/up$n.pkg.log")"; continue; }

  ajt manifest upgrade "$B" >"$WORK/out/up$n.ajt.log" 2>&1
  arc=$?
  if [ "$arc" -ne 0 ]; then
    fail "ajt manifest upgrade failed on $f (exit $arc):
$(sed 's/^/      /' "$WORK/out/up$n.ajt.log")"; continue
  fi

  # Pkg must actually have DONE something: two tools that both no-op agree
  # trivially, and that would be the easiest way for this section to be
  # worthless.
  if cmp -s "$f" "$A"; then
    fail "Pkg.upgrade_manifest left $f unchanged — this fixture is not a v1 manifest"
    continue
  fi

  if cmp -s "$A" "$B"; then
    ok "$(basename "$(dirname "$f")")/$(basename "$f"): byte-identical to Pkg.upgrade_manifest ($(wc -c < "$B") bytes)"
    UPGRADED=$((UPGRADED + 1))
  else
    fail "upgrade of $f diverges from Pkg (--- pkg, +++ ajt):
$(diff "$A" "$B" | head -20 | sed 's/^/      /')"
  fi

  # ...and the result must be a v2 manifest by Pkg's own reader, not merely by
  # ours.
  MF="$(jl -e 'using Pkg; print(Pkg.Types.read_manifest(ARGS[1]).manifest_format)' "$B" 2>/dev/null)"
  expect_eq "$MF" "2.0.0" "  ...and Pkg reads it back as manifest_format 2.0.0"
done

[ "$UPGRADED" -gt 0 ] \
  && ok "$UPGRADED v1 manifest(s) upgraded byte-identically ($REAL_V1S of them real)" \
  || fail "no manifest was upgraded at all — section 3 proved nothing"

# ---------------------------------------------------------------------------
# 4. An already-v2 manifest is refused, not rewritten
# ---------------------------------------------------------------------------
echo "==> 4. already v2"

V2="$WORK/out/already_v2.toml"
cp "$WORK/out/up1.ajt.toml" "$V2" 2>/dev/null || cp "$WORK/match/Manifest.toml" "$V2"
chmod u+w "$V2"
# A distinct mtime, so "unchanged" cannot be an artefact of a same-second write.
touch -d '2001-02-03 04:05:06.123456789' "$V2"
BEFORE="$(stat -c '%y %s %i' "$V2")"
cp "$V2" "$WORK/out/already_v2.orig"

ajt manifest upgrade "$V2" >"$WORK/v2.out" 2>&1
V2_RC=$?
AFTER="$(stat -c '%y %s %i' "$V2")"

expect_eq "$V2_RC" "1" "ajt refuses an already-v2 manifest (Pkg raises, API.jl:1717-1719)"
expect_eq "$AFTER" "$BEFORE" "the file's mtime, size and inode are untouched"
cmp -s "$WORK/out/already_v2.orig" "$V2" \
  && ok "and its bytes are identical" \
  || fail "the refused manifest was rewritten:
$(diff "$WORK/out/already_v2.orig" "$V2" | head -10 | sed 's/^/      /')"

# Pkg's sentence, word for word, so a caller matching on Pkg's message keeps
# working. Pkg's path-taking entry point copies into a tempdir first
# (`API.jl:1706-1713`), so its message names THAT path -- everything after the
# closing backtick is what has to agree.
cp "$WORK/out/already_v2.orig" "$WORK/out/already_v2.pkg.toml"
J_MSG="$(jl -e '
using Pkg
try
    Pkg.upgrade_manifest(ARGS[1])
    print("(no error)")
catch e
    print(sprint(showerror, e))
end' "$WORK/out/already_v2.pkg.toml" 2>/dev/null | sed 's/^.*` //')"
A_MSG="$(sed 's/^.*` //' "$WORK/v2.out")"
expect_eq "$A_MSG" "$J_MSG" "the refusal is Pkg's own sentence: '$J_MSG'"

# --dry-run on a v1 manifest must report the upgrade and write nothing.
cp "${V1S[-1]}" "$WORK/out/dry.toml"; chmod u+w "$WORK/out/dry.toml"
DRY_BEFORE="$(stat -c '%y %s' "$WORK/out/dry.toml")"
ajt manifest upgrade --dry-run "$WORK/out/dry.toml" >"$WORK/dry.out" 2>&1
expect_eq "$?" "0" "--dry-run on a v1 manifest succeeds"
expect_eq "$(stat -c '%y %s' "$WORK/out/dry.toml")" "$DRY_BEFORE" "--dry-run wrote nothing"
grep -q "would_upgrade" "$WORK/dry.out" \
  && ok "--dry-run says what it would have done" \
  || fail "--dry-run report: $(cat "$WORK/dry.out")"

# ---------------------------------------------------------------------------
# 5. Which file — the version-specific manifest, and the redirect
# ---------------------------------------------------------------------------
echo "==> 5. which file"

# `Base.manifest_names` probes `JuliaManifest-v<M>.<m>.toml`,
# `Manifest-v<M>.<m>.toml`, `JuliaManifest.toml`, `Manifest.toml`
# (`base/loading.jl:631-636`), in that order. An environment carrying a
# version-specific manifest AND a plain one is not exotic: it is how a project
# pins a manifest per Julia minor. Upgrading the wrong one is silent — the file
# the loader reads stays v1 and a file nobody reads gets rewritten.
MM="${JV%.*}"   # 1.12.6 -> 1.12
VS="$WORK/versioned"
make_project "$VS"
cat > "$VS/Manifest-v$MM.toml" <<EOF
[[LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
# The decoy: already v2, so if it were the one chosen the run would REFUSE, and
# if it were rewritten its bytes would move. Either way the assertions below
# catch it.
make_v2_manifest "$VS"
cp "$VS/Manifest.toml" "$WORK/out/decoy.orig"

PKG_VS="$(jl -e '
using Pkg
print(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml")).manifest_file)' "$VS")"
expect_eq "$PKG_VS" "$VS/Manifest-v$MM.toml" "Pkg reads the version-specific manifest, not Manifest.toml"

ajt manifest current "$VS" >"$WORK/vs.cur" 2>&1
VS_CUR_RC=$?
expect_eq "$VS_CUR_RC" "2" "manifest current answers \`nothing\` for the v1 versioned manifest"
expect_eq "$(sed -n 's/^manifest_current\t[a-z]*\t\([^\t]*\)\t.*/\1/p' "$WORK/vs.cur")" "$PKG_VS" \
  "...about the file EnvCache reads"

ajt manifest upgrade "$VS" >"$WORK/vs.up" 2>&1
VS_UP_RC=$?
sed 's/^/    /' "$WORK/vs.up"
expect_eq "$VS_UP_RC" "0" "manifest upgrade succeeds on the versioned manifest"
grep -q "Manifest-v$MM.toml" "$WORK/vs.up" \
  && ok "and says it upgraded THAT file" \
  || fail "upgrade named the wrong file: $(cat "$WORK/vs.up")"
cmp -s "$WORK/out/decoy.orig" "$VS/Manifest.toml" \
  && ok "the decoy Manifest.toml beside it is byte-identical" \
  || fail "the decoy Manifest.toml was rewritten:
$(diff "$WORK/out/decoy.orig" "$VS/Manifest.toml" | head -10 | sed 's/^/      /')"
VS_FMT="$(jl -e 'using Pkg; print(Pkg.Types.read_manifest(ARGS[1]).manifest_format)' "$VS/Manifest-v$MM.toml" 2>/dev/null)"
expect_eq "$VS_FMT" "2.0.0" "and Pkg reads the upgraded versioned manifest back as v2"

# Same question for the `manifest = "..."` redirect, which `EnvCache` applies
# ahead of the whole probe (`Types.jl:411`, `:423-425`).
RD="$WORK/redirect"
mkdir -p "$RD/nested"
cat > "$RD/Project.toml" <<EOF
name = "Fixture"
uuid = "$PROJ_UUID"
version = "0.1.0"
manifest = "nested/Elsewhere.toml"

[deps]
LinearAlgebra = "$LINALG_UUID"
EOF
cat > "$RD/nested/Elsewhere.toml" <<EOF
[[LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
make_v2_manifest "$RD"
cp "$RD/Manifest.toml" "$WORK/out/redirect_decoy.orig"

PKG_RD="$(jl -e '
using Pkg
print(Pkg.Types.EnvCache(joinpath(ARGS[1], "Project.toml")).manifest_file)' "$RD")"
ajt manifest upgrade "$RD" >"$WORK/rd.up" 2>&1
RD_RC=$?
expect_eq "$RD_RC" "0" "manifest upgrade follows the project's manifest = \"...\" redirect"
grep -q "Elsewhere.toml" "$WORK/rd.up" \
  && ok "and upgraded $PKG_RD" \
  || fail "redirect upgrade named: $(cat "$WORK/rd.up")"
cmp -s "$WORK/out/redirect_decoy.orig" "$RD/Manifest.toml" \
  && ok "the decoy Manifest.toml beside it is byte-identical" \
  || fail "the redirect's decoy Manifest.toml was rewritten"

# ---------------------------------------------------------------------------
# 6. Through the Julia wrapper
# ---------------------------------------------------------------------------
echo "==> 6. julia/src/Ajt.jl"

# Sections 1-5 drive the BINARY, and pass it `--julia-prefix`/`--julia-version`
# by hand. The wrapper is what real callers use, and it has its own way of
# building an argv -- so a wrapper that forgets `_julia_args()` sends the same
# correct binary at the wrong file, and every check above stays green. That is
# not hypothetical: it is the bug this section was written for. Both entry
# points are exercised against the version-specific environment, where the
# right file and the wrong file both exist.
WRAP="$WORK/wrapper"
make_project "$WRAP"
cat > "$WRAP/Manifest-v$MM.toml" <<EOF
[[LinearAlgebra]]
uuid = "$LINALG_UUID"
EOF
# The decoy is ALSO v1, deliberately. A v2 decoy would make a wrong-file upgrade
# fail loudly ("already up to date"), and then this section would be resting on
# an accident. With both files v1 the wrong file upgrades SILENTLY and only the
# two identity assertions below can catch it -- which is the shape of the real
# bug.
cat > "$WRAP/Manifest.toml" <<EOF
[[Printf]]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
EOF
cp "$WRAP/Manifest.toml" "$WORK/out/wrapper_decoy.orig"

AJT_BINARY="$AJT" jl --project="$AJT_ROOT/julia" -e '
using Ajt
import Pkg
dir = ARGS[1]
# The tri-state has to survive the round trip through the wrapper, which parses
# a record rather than reading the exit code.
println("current\t", repr(Ajt.is_manifest_current(dir)), "\t", repr(Pkg.is_manifest_current(dir)))
# The zero-argument form: the active environment, which is exactly where the
# version-specific manifest name has to be derived from the RUNNING julia.
Pkg.activate(dir; io = devnull)
report = sprint(io -> Ajt.upgrade_manifest(; io))
println("report\t", replace(strip(report), "\n" => " "))
println("envcache\t", Pkg.Types.EnvCache().manifest_file)
' "$WRAP" >"$WORK/wrap.out" 2>"$WORK/wrap.err"
WRAP_RC=$?
sed 's/^/    /' "$WORK/wrap.out"
if [ "$WRAP_RC" -ne 0 ]; then
  fail "the wrapper raised:
$(tail -12 "$WORK/wrap.err" | sed 's/^/      /')"
else
  W_CUR="$(awk -F'\t' '$1 == "current" { print $2 }' "$WORK/wrap.out")"
  P_CUR="$(awk -F'\t' '$1 == "current" { print $3 }' "$WORK/wrap.out")"
  expect_eq "$W_CUR" "$P_CUR" "Ajt.is_manifest_current returns the same value as Pkg's"
  expect_eq "$(awk -F'\t' '$1 == "envcache" { print $2 }' "$WORK/wrap.out")" "$WRAP/Manifest-v$MM.toml" \
    "Pkg's EnvCache reads the version-specific manifest in this environment"

  # The two that actually catch a wrong-file upgrade: what CHANGED on disk.
  W_VS="$(jl -e 'using Pkg; print(Pkg.Types.read_manifest(ARGS[1]).manifest_format)' "$WRAP/Manifest-v$MM.toml" 2>/dev/null)"
  expect_eq "$W_VS" "2.0.0" "Ajt.upgrade_manifest() upgraded the file EnvCache reads"
  cmp -s "$WORK/out/wrapper_decoy.orig" "$WRAP/Manifest.toml" \
    && ok "and left the v1 decoy Manifest.toml beside it byte-identical" \
    || fail "the wrapper upgraded the decoy Manifest.toml instead of the one julia loads"

  # ...and it said so, naming the same file, since that line is Pkg's own.
  grep -q "Manifest-v$MM.toml" <(awk -F'\t' '$1 == "report" { print $2 }' "$WORK/wrap.out") \
    && ok "and its Updated line names that file" \
    || fail "the wrapper's report named the wrong file: $(awk -F'\t' '$1 == "report" { print $2 }' "$WORK/wrap.out")"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS — is_manifest_current agrees with Pkg on ${#CASES[@]} cases including"
  echo "       $NOTHINGS distinct routes to \`nothing\`, always about the file EnvCache"
  echo "       reads, and upgrade_manifest reproduces Pkg byte for byte on $UPGRADED v1"
  echo "       manifest(s) while refusing a v2 one untouched."
  exit 0
fi
echo "FAILED"
exit 1
