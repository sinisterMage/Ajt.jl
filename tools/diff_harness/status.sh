#!/usr/bin/env bash
# Differential gate for `ajt status` — against `Pkg.status(...; io)` itself.
#
# Every other verb writes a FILE and is gated by comparing bytes on disk. Here
# the bytes on stdout ARE the product: a `status` that got the gutter width, the
# sort key or the legend line wrong would still leave a perfect environment
# behind it, and nothing else in this repo would notice. So this harness does
# what the `why` section of resolve.sh does, at forty times the surface — runs
# both tools over the same environments and `cmp`s them byte for byte.
#
# `Pkg.status` writes to `io`, and `io` is the specification: every marker goes
# through `printstyled`, which consults `get(io, :color, false)`. A file gets no
# escapes and a TTY does, so the oracle writes to a file, ajt writes to a pipe,
# and the two are directly comparable. That is the same contract `Ajt.why`
# documents and the same reason it holds.
#
# ## The corpus
#
# Eight environments, each chosen for a branch of `print_status` that nothing
# else reaches:
#
#   base     two registered deps, one of which (JSON) declares an extension
#   old      Colors held at 0.11 with the registry at 0.13 — the `⌃` branch,
#            and in manifest mode the `⌅` branch alongside it
#   compat   the same, with `[compat] Colors = "0.11"` — `⌅ … [compat]`
#   pinned   the same, with `[compat] Colors = "0.11 - 0.12"` and a pin — the
#            `⚲` glyph AND the `[<v…],` prefix, which needs the resolved version
#            to be below the compat maximum which is below the registry maximum
#   dev      a `develop`ed path entry beside a pinned one
#   named    a project that is itself a package (the `Project X vN` header) with
#            a `[compat]` bound that no longer matches the manifest (the
#            trailing `Warning` line)
#   missing  `old`'s environment against a depot holding only the registry —
#            every package `→`, which is also the only way to reach the
#            three-wide gutter (`lpadding = 3`, Operations.jl:2874)
#   empty    a `[deps]`-only project — "(empty project)" / "(empty manifest)"
#
# and eleven option sets over each: the default, `-m`, `-o`, `-o -m`, `-e`,
# `-e -m`, `-c`, a positional filter that matches, one that does not, the same
# in manifest mode, and a UUID filter.
#
# ## Two comparisons are content-only, and why
#
# Pkg iterates a `Dict` to print `--compat` (project.deps, Operations.jl:3106)
# and the per-package extension lines (manifest_info.exts, :2739). `Dict` order
# is a function of `Base.hash(::String)`, the table size and the insertion
# sequence — deterministic, but not computable without porting `Base.Dict`. Ajt
# emits both in a stable order instead. Those two cases are therefore compared
# as SORTED line sets, which still fails on a missing line, an extra line, a
# wrong pad width or a wrong compat string; only the order is forgiven. Every
# other comparison, including `-c` on the single-dep environment where there is
# only one order, is byte for byte.
#
# Needs the network (Pkg downloads a registry and real packages) and a couple of
# minutes. Writes only into a mktemp depot — never `~/.julia`.
#
# Usage: tools/diff_harness/status.sh [--keep]
set -uo pipefail

# Julia sorts `Vector{String}` in plain byte order and so must every `sort` here.
export LC_ALL=C

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

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-status-XXXXXX)"
cleanup() { [ $KEEP -eq 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }; }
trap cleanup EXIT
[ $KEEP -eq 1 ] && echo "workdir: $WORK"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

if ! "$AJT" fetch --no-auth --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
  echo
  echo "########################################################################"
  echo "# SKIPPED: no network. Every environment here is built by stock Pkg    #"
  echo "# from the real registry; there is no offline subset.                  #"
  echo "########################################################################"
  exit 0
fi

DEPOT="$WORK/depot"
REGONLY="$WORK/regonly"
ENVS="$WORK/envs"
mkdir -p "$DEPOT" "$ENVS"

JULIA_PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"

echo "==> installing the registry into a scratch depot"
env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e \
  'using Pkg; Pkg.Registry.add("General")' >"$WORK/reg.log" 2>&1 || {
  echo "ERROR: could not install the registry" >&2; tail -10 "$WORK/reg.log" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------
# Built entirely by stock Pkg, so every Project/Manifest pair is one Pkg itself
# produced -- an environment ajt hand-wrote would be gating the report against
# a file only ajt can make.
echo "==> building the corpus with stock Pkg"
cat >"$WORK/mkcorpus.jl" <<'JL'
using Pkg
envs = ARGS[1]

mk(name) = (d = joinpath(envs, name); mkpath(d); d)

# base: two registered deps; JSON carries an extension + weakdep pair.
Pkg.activate(mk("base"); io = devnull)
Pkg.add(["Colors", "JSON"]; io = devnull)

# old: a version behind the registry, which is what produces ⌃ and ⌅.
Pkg.activate(mk("old"); io = devnull)
Pkg.add(name = "Colors", version = "0.11"; io = devnull)

# compat / pinned: same manifest, different [compat] bound. Written by hand
# because `Pkg.add` does not record compat, then re-resolved by Pkg so the
# project_hash is current and no Warning line appears.
for (name, bound, pin) in (("compat", "0.11", false), ("pinned", "0.11 - 0.12", true))
    d = mk(name)
    cp(joinpath(envs, "old", "Project.toml"), joinpath(d, "Project.toml"); force = true)
    cp(joinpath(envs, "old", "Manifest.toml"), joinpath(d, "Manifest.toml"); force = true)
    open(joinpath(d, "Project.toml"), "a") do io
        println(io, "\n[compat]\nColors = \"", bound, "\"")
    end
    Pkg.activate(d; io = devnull)
    pin && Pkg.pin("Colors"; io = devnull)
    Pkg.resolve(io = devnull)
end

# dev: a developed local path entry beside a pinned registry entry.
devpkg = joinpath(envs, "DevPkg")
mkpath(joinpath(devpkg, "src"))
write(joinpath(devpkg, "Project.toml"), """
name = "DevPkg"
uuid = "11111111-2222-3333-4444-555555555555"
version = "0.3.0"
""")
write(joinpath(devpkg, "src", "DevPkg.jl"), "module DevPkg end\n")
Pkg.activate(mk("dev"); io = devnull)
Pkg.add(["Colors"]; io = devnull)
Pkg.develop(path = devpkg; io = devnull)
Pkg.pin("Colors"; io = devnull)

# named: the project is itself a package (Project header) and its [compat] no
# longer matches the manifest (Warning line). Deliberately NOT re-resolved.
d = mk("named")
Pkg.activate(d; io = devnull)
Pkg.add(["Colors"]; io = devnull)
proj = read(joinpath(d, "Project.toml"), String)
write(
    joinpath(d, "Project.toml"), string(
        "name = \"Named\"\nuuid = \"22222222-3333-4444-5555-666666666666\"\nversion = \"1.2.3\"\n\n",
        proj, "\n[compat]\nColors = \"0.12\"\n"
    )
)

# empty: nothing at all, and no manifest beside it.
write(joinpath(mk("empty"), "Project.toml"), "[deps]\n")

# missing: `old`'s files, reported against a depot that has only the registry.
d = mk("missing")
cp(joinpath(envs, "old", "Project.toml"), joinpath(d, "Project.toml"); force = true)
cp(joinpath(envs, "old", "Manifest.toml"), joinpath(d, "Manifest.toml"); force = true)
JL

env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
  "$WORK/mkcorpus.jl" "$ENVS" >"$WORK/corpus.log" 2>&1 || {
  echo "ERROR: corpus build failed" >&2; tail -20 "$WORK/corpus.log" >&2; exit 2; }

# The depot the `missing` environment is reported against: the registry and
# nothing else, so `is_package_downloaded` is false for every entry.
mkdir -p "$REGONLY"
cp -r "$DEPOT/registries" "$REGONLY/"

for e in base old compat pinned dev named empty missing; do
  [ -f "$ENVS/$e/Project.toml" ] || { echo "ERROR: corpus env '$e' missing" >&2; exit 2; }
done
echo "  built: $(ls "$ENVS" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Variants: name | ajt flags | Pkg.status arguments
# ---------------------------------------------------------------------------
# Kept as one table so the two sides cannot drift: adding a case means adding
# one line, and a line that spells the two halves differently fails loudly
# rather than testing nothing.
VARIANTS=$(cat <<'EOF'
default|                |()
manifest|-m             |(mode = Pkg.PKGMODE_MANIFEST,)
outdated|-o             |(outdated = true,)
outdated-m|-o -m        |(outdated = true, mode = Pkg.PKGMODE_MANIFEST)
ext|-e                  |(extensions = true,)
ext-m|-e -m             |(extensions = true, mode = Pkg.PKGMODE_MANIFEST)
compat|-c               |(compat = true,)
filter-hit|Colors       |("Colors",)
filter-miss|Nope        |("Nope",)
filter-miss-m|-m Nope   |("Nope", mode = Pkg.PKGMODE_MANIFEST)
filter-uuid|5ae59095-9a9b-59fe-a467-6f913c188581|("5ae59095-9a9b-59fe-a467-6f913c188581",)
EOF
)

# The oracle: one Julia process per environment, every variant into its own
# file. `io` is a file, so `printstyled` emits no escapes.
cat >"$WORK/oracle.jl" <<'JL'
using Pkg
envdir, outdir = ARGS[1], ARGS[2]
mkpath(outdir)
Pkg.activate(envdir; io = devnull)
cases = [
    ("default", (), NamedTuple()),
    ("manifest", (), (mode = Pkg.PKGMODE_MANIFEST,)),
    ("outdated", (), (outdated = true,)),
    ("outdated-m", (), (outdated = true, mode = Pkg.PKGMODE_MANIFEST)),
    ("ext", (), (extensions = true,)),
    ("ext-m", (), (extensions = true, mode = Pkg.PKGMODE_MANIFEST)),
    ("compat", (), (compat = true,)),
    ("filter-hit", ("Colors",), NamedTuple()),
    ("filter-miss", ("Nope",), NamedTuple()),
    ("filter-miss-m", ("Nope",), (mode = Pkg.PKGMODE_MANIFEST,)),
    # A UUID positional, NOT a `Vector{String}` one. `ajt status <word>` is the
    # `pkg>` grammar, and `parse_package` classifies a uuid-shaped word as a
    # uuid (REPLMode/argument_parsers.jl:472). The API's `Vector{String}` form
    # does no such detection -- it would put the uuid in `filter_names` and
    # print "No Matches", which is a different question.
    ("filter-uuid", (Pkg.PackageSpec(uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"),), NamedTuple()),
]
for (name, args, kw) in cases
    open(joinpath(outdir, name), "w") do io
        if isempty(args)
            Pkg.status(; io = io, kw...)
        else
            Pkg.status(collect(args); io = io, kw...)
        end
    end
end
JL

# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------
LANDMARK_SEEN=0

for e in base old compat pinned dev named empty missing; do
  echo
  echo "==> $e"
  ENV_DIR="$ENVS/$e"
  USE_DEPOT="$DEPOT"
  [ "$e" = "missing" ] && USE_DEPOT="$REGONLY"

  if ! env JULIA_DEPOT_PATH="$USE_DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
       "$WORK/oracle.jl" "$ENV_DIR" "$WORK/oracle-$e" >"$WORK/oracle-$e.log" 2>&1; then
    bad "$e: Pkg.status oracle failed" "$(tail -3 "$WORK/oracle-$e.log" | tr '\n' '|')"
    continue
  fi

  while IFS='|' read -r vname vflags vkw; do
    [ -n "$vname" ] || continue
    # shellcheck disable=SC2086 # $vflags is a deliberate word list
    set -- $vflags
    ORACLE="$WORK/oracle-$e/$vname"
    MINE="$WORK/ajt-$e-$vname"
    if ! env JULIA_DEPOT_PATH="$USE_DEPOT" "$AJT" status \
         --env "$ENV_DIR" --julia-prefix "$JULIA_PREFIX" "$@" >"$MINE" 2>"$MINE.err"; then
      bad "$e/$vname: ajt status failed" "$(tail -3 "$MINE.err" | tr '\n' '|')"
      continue
    fi

    # Content-only for the two `Dict`-ordered reports; see the header. `base`
    # and `dev` have two deps, so their compat line order is Pkg's Dict order.
    ORDER_FREE=0
    case "$vname:$e" in
      compat:base|compat:dev) ORDER_FREE=1 ;;
      ext:*|ext-m:*)          ORDER_FREE=1 ;;
    esac

    if [ "$ORDER_FREE" -eq 1 ]; then
      # `└` marks the LAST extension of a package and `├` every other one
      # (Operations.jl:2942), so a different order changes two glyphs as well as
      # two positions. Both are folded to `|` before sorting; everything that is
      # not order -- the names, the trigger lists, the 14-space indent, the
      # brackets -- still has to match exactly.
      if diff -q <(sed 's/[└├]/|/g' "$ORACLE" | sort) <(sed 's/[└├]/|/g' "$MINE" | sort) >/dev/null; then
        ok "$e/$vname: same lines as Pkg.status ($(grep -c . "$ORACLE") line(s), order-free)"
      else
        bad "$e/$vname differs from Pkg.status (order-free)" \
            "$(diff <(sed 's/[└├]/|/g' "$ORACLE" | sort) <(sed 's/[└├]/|/g' "$MINE" | sort) | head -6 | tr '\n' '|')"
      fi
    elif cmp -s "$ORACLE" "$MINE"; then
      ok "$e/$vname: byte-identical to Pkg.status ($(grep -c . "$ORACLE") line(s))"
    else
      bad "$e/$vname differs from Pkg.status" \
          "$(diff "$ORACLE" "$MINE" | head -8 | tr '\n' '|')"
    fi
  done <<<"$VARIANTS"

  # --- landmarks, per environment ------------------------------------------
  # A gate comparing two empty strings passes. These assert the oracle really
  # ran and really produced the branch this environment exists for, so a corpus
  # that silently stopped containing Colors -- or a Pkg that stopped printing
  # markers -- fails here instead of passing everything.
  O="$WORK/oracle-$e"
  case "$e" in
    base)
      grep -q '^  \[5ae59095\] Colors v' "$O/default" \
        && { ok "$e: oracle carries the Colors line"; LANDMARK_SEEN=1; } \
        || bad "$e: oracle has no Colors line — the corpus is not what this gate assumes"
      grep -q 'JSONArrowExt' "$O/ext" \
        || bad "$e: oracle --extensions shows no extension — the ext branch is untested"
      ;;
    old)
      grep -q '⌃ \[5ae59095\] Colors v0\.11' "$O/default" \
        || bad "$e: oracle shows no ⌃ marker — the upgradable branch is untested"
      grep -q '⌅ ' "$O/outdated-m" \
        || bad "$e: oracle shows no ⌅ marker — the held-back branch is untested"
      ;;
    compat)
      grep -q '\[compat\]' "$O/outdated" \
        || bad "$e: oracle shows no [compat] reason — that branch is untested"
      ;;
    pinned)
      grep -q '⚲' "$O/default" \
        || bad "$e: oracle shows no ⚲ glyph — the pinned branch is untested"
      grep -q '\[<v' "$O/outdated" \
        || bad "$e: oracle shows no [<v…] bound — that branch is untested"
      ;;
    dev)
      grep -q 'DevPkg v0\.3\.0 `' "$O/default" \
        || bad "$e: oracle shows no developed path — that branch is untested"
      ;;
    named)
      grep -q '^Project Named v1\.2\.3$' "$O/default" \
        || bad "$e: oracle has no Project header — that branch is untested"
      grep -q '^Warning The project dependencies' "$O/default" \
        || bad "$e: oracle has no stale-manifest Warning — that branch is untested"
      ;;
    empty)
      # An empty environment returns BEFORE the filter is applied
      # (Operations.jl:2794-2801), so a filter that matches nothing still prints
      # "(empty project)" here -- the No Matches branch is asserted on `base`.
      grep -q '(empty project)' "$O/default" \
        || bad "$e: oracle does not report an empty project"
      grep -q '(empty manifest)' "$O/manifest" \
        || bad "$e: oracle does not report an empty manifest"
      grep -q '(empty project)' "$O/filter-miss" \
        || bad "$e: oracle applied a filter to an empty project — the early return moved"
      ;;
    missing)
      grep -q '^→' "$O/default" \
        || bad "$e: oracle shows no → marker — the not-downloaded branch is untested"
      grep -q '^   \[' "$O/manifest" \
        || bad "$e: oracle never widened the gutter to three — lpadding is untested"
      ;;
  esac
done

# Everything above passes `--env <absolute>`, which is the one shape that does
# NOT exercise `abspath`. `EnvCache` abspaths both files before anything prints
# them (Types.jl:392-420), so a relative environment -- `ajt status` typed
# inside the directory, the way a person actually runs it -- has to produce the
# identical header. It did not: the first version printed `` `./Project.toml` ``
# because `Dir.cwd()` is a sentinel that `realPath` will not resolve, and every
# case in the table above was blind to it.
echo
echo "==> relative environment"
( cd "$ENVS/base" && env JULIA_DEPOT_PATH="$DEPOT" "$AJT" status \
    --julia-prefix "$JULIA_PREFIX" ) >"$WORK/ajt-base-cwd" 2>"$WORK/ajt-base-cwd.err"
if cmp -s "$WORK/oracle-base/default" "$WORK/ajt-base-cwd"; then
  ok "base: run from inside the environment, byte-identical to Pkg.status"
else
  bad "base: a relative environment prints a different path than an absolute one" \
      "$(diff "$WORK/oracle-base/default" "$WORK/ajt-base-cwd" | head -4 | tr '\n' '|')"
fi

# `No Matches` must appear on a filter that matches nothing, in an environment
# that is NOT empty -- otherwise the case is indistinguishable from the empty
# report and the branch is never taken.
grep -q '^No Matches in ' "$WORK/oracle-base/filter-miss" \
  && ok "base: oracle takes the No Matches branch on a non-empty environment" \
  || bad "base: oracle did not print No Matches for an unmatched filter"

echo
if [ "$LANDMARK_SEEN" -ne 1 ]; then
  echo "FAIL: no landmark line was ever seen — the corpus did not build" >&2
  exit 1
fi
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect both sides)"
  exit 1
fi
echo "PASS — ajt status reproduces Pkg.status over 8 environments × 11 option sets,"
echo "       plus a relative environment and the No Matches branch"
