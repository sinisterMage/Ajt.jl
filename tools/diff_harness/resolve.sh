#!/usr/bin/env bash
# Differential gate for `ajt resolve` — against environments Ajt did not choose.
#
# Open-Reality resolving to exactly its committed manifest is a good result and
# a WEAK one: it is a single environment, it was the environment every part of
# the resolver was developed against, and "reproduces the one manifest I tuned
# on" is the textbook shape of overfitting. This harness exists to answer the
# only question that matters after that — does it hold on environments nobody
# tuned for?
#
# For each package below: let stock Pkg resolve it from scratch in a throwaway
# depot, then hand Ajt the Project/Manifest pair Pkg produced and require both
# that Ajt's SELECTION agrees and that the Manifest.toml it WRITES from that
# selection is byte-identical to the one Pkg wrote. Specifically:
#
#   * every manifest entry resolves to the version Pkg recorded (0 changed),
#   * the ONLY package Ajt selects that is NOT a manifest entry is `julia`,
#     which is Ajt's synthetic single-version package and is supposed to be
#     there, and
#   * the entries Ajt reports as `unversioned` are exactly the manifest entries
#     that carry no `version` key,
#   * `ajt resolve --write` reproduces Pkg's Manifest.toml byte for byte, and
#     still does after every derived field in it has been deleted, and
#   * stock `Pkg.resolve()` then leaves that file untouched.
#
# The second check is the one that catches weak-dependency and closure bugs:
# a resolver that pulls in extra packages still reports "0 changed", because
# every entry it was asked about is fine. Open-Reality's own Adapt bug looked
# exactly like that.
#
# The third check exists because the second one used to be written against the
# wrong predicate. It asked whether Ajt had a version to compare, not whether
# Pkg had the package — and those differ for exactly one package on Julia
# 1.12: `SuiteSparse`, the only stdlib shipping no `version` key, which
# `stdlib_version` (Types.jl:600-609) hands to the manifest bare. Pkg's Makie
# and Flux manifests DO contain it; the gate said they did not, and called a
# correct resolve a stdlib defect. Comparing the two sets directly is what
# keeps that class of mistake from coming back silently.
#
# The corpus is deliberately not RealityForge-shaped: Makie is a large graphics
# stack with heavy weakdep/extension use, DataFrames pulls a wide data
# ecosystem, and Flux drags in GPU packages with conditional loading. All three
# exercise `[weakdeps]`, which is where the resolver's remaining risk lives.
#
# Needs the network (Pkg downloads real packages) and several minutes.
# Writes only into a mktemp depot — never `~/.julia`.
#
# Usage: resolve.sh [--keep] [--packages "A B C"]
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

KEEP=0
PACKAGES="Makie DataFrames Flux"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --packages) PACKAGES="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-resolve-XXXXXX)"
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
  echo "# SKIPPED: no network. Every case here has stock Pkg resolve a real     #"
  echo "# package from the real registry; there is no offline subset.           #"
  echo "########################################################################"
  exit 0
fi

DEPOT="$WORK/depot"
mkdir -p "$DEPOT"

# One registry for both sides, installed once.
echo "==> installing the registry into a scratch depot"
env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no -e \
  'using Pkg; Pkg.Registry.add("General")' >"$WORK/reg.log" 2>&1 || {
  echo "ERROR: could not install the registry" >&2; tail -10 "$WORK/reg.log" >&2; exit 2; }

JULIA_PREFIX="$(julia --startup-file=no -e 'print(dirname(Sys.BINDIR))')"

for pkg in $PACKAGES; do
  echo
  echo "==> $pkg"
  ENV_DIR="$WORK/env-$pkg"
  mkdir -p "$ENV_DIR"

  # Stock Pkg resolves it. PRECOMPILE_AUTO=0 keeps this to download+resolve;
  # precompiling a stack the size of Makie would dominate the runtime and
  # tests nothing here.
  if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
       julia --startup-file=no --project="$ENV_DIR" -e \
       "using Pkg; Pkg.add(\"$pkg\")" >"$WORK/$pkg.add.log" 2>&1; then
    bad "$pkg: stock Pkg could not resolve it" "$(tail -3 "$WORK/$pkg.add.log" | tr '\n' '|')"
    continue
  fi
  ENTRIES="$(grep -c '^\[\[deps\.' "$ENV_DIR/Manifest.toml" 2>/dev/null || echo 0)"
  ok "$pkg: stock Pkg produced a $ENTRIES-entry manifest"
  [ "$ENTRIES" -gt 20 ] || bad "$pkg: only $ENTRIES entries — too small to gate anything"

  # Ajt resolves the SAME environment at PRESERVE_ALL.
  if ! "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" \
       "$ENV_DIR" >"$WORK/$pkg.ajt.out" 2>"$WORK/$pkg.ajt.err"; then
    bad "$pkg: ajt resolve failed" "$(tail -5 "$WORK/$pkg.ajt.err" | tr '\n' '|')"
    continue
  fi

  read -r _ TOTAL CHANGED UNVERSIONED ADDED _ <<EOF
$(grep '^summary' "$WORK/$pkg.ajt.out")
EOF

  # GATE 1: every entry Pkg recorded is held at that exact version.
  if [ "${CHANGED:-x}" = "0" ]; then
    ok "$pkg: all held at Pkg's versions (0 changed of $TOTAL)"
  else
    bad "$pkg: $CHANGED entries resolved to a different version" \
        "$(grep '^changed' "$WORK/$pkg.ajt.out" | head -5 | tr '\n' '|')"
  fi

  # GATE 2: nothing extra. This is the one that catches weakdep and closure
  # bugs — they leave `changed` at 0 while widening the set. `added` means
  # "Pkg's manifest has no such entry", which is the question being asked;
  # having no version to compare is a different thing and is gate 3's.
  EXTRA="$(grep '^added' "$WORK/$pkg.ajt.out" | awk '$2 != "julia"' || true)"
  if [ -z "$EXTRA" ]; then
    ok "$pkg: selected nothing beyond the manifest except julia"
  else
    # `wc -l` counts newlines, and a captured list has none on its last line,
    # so it reports one too few — and reported 0 for a single finding, which
    # read as a passing gate that had in fact failed. `grep -c .` counts lines.
    bad "$pkg: selected $(printf '%s\n' "$EXTRA" | grep -c .) package(s) Pkg did not" \
        "$(printf '%s' "$EXTRA" | head -5 | awk '{print $2"@"$3}' | tr '\n' ' ')"
  fi

  # GATE 3: the unversioned set is exactly Pkg's versionless entries.
  # Computed from the manifest itself rather than from a list of known stdlib
  # names, so a stdlib that loses its `version` key in some future Julia is
  # covered without anyone remembering to add it here.
  awk '
    /^\[\[deps\./ { if (name != "" && !seen) print name; sub(/^\[\[deps\./, "", $0);
                    sub(/\]\]$/, "", $0); gsub(/^"|"$/, "", $0);
                    name = $0; seen = 0; next }
    /^version *=/ { seen = 1 }
    END { if (name != "" && !seen) print name }
  ' "$ENV_DIR/Manifest.toml" | LC_ALL=C sort > "$WORK/$pkg.pkg-unversioned"
  grep '^unversioned' "$WORK/$pkg.ajt.out" | cut -f2 | LC_ALL=C sort > "$WORK/$pkg.ajt-unversioned"
  if diff -q "$WORK/$pkg.pkg-unversioned" "$WORK/$pkg.ajt-unversioned" >/dev/null; then
    N="$(grep -c . "$WORK/$pkg.pkg-unversioned" || true)"
    ok "$pkg: unversioned set matches Pkg's versionless entries ($N)"
  else
    bad "$pkg: unversioned set differs from Pkg's versionless entries" \
        "$(diff "$WORK/$pkg.pkg-unversioned" "$WORK/$pkg.ajt-unversioned" | head -6 | tr '\n' '|')"
  fi

  # And an unversioned STDLIB is not free to be any version: `deps_graph` uses
  # `something(stdlib_info.version, VERSION)` (Operations.jl:678), so it must
  # be the Julia version exactly. Nothing else in the manifest states this, so
  # a wrong choice here would be invisible to every other check.
  JV="$(awk -F'"' '/^julia_version/ {print $2; exit}' "$ENV_DIR/Manifest.toml")"
  BADV="$(grep '^unversioned' "$WORK/$pkg.ajt.out" | awk -v jv="$JV" '$3 != jv {print $2"@"$3}' || true)"
  if [ -z "$BADV" ]; then
    ok "$pkg: every unversioned entry resolved to the julia version ($JV)"
  else
    bad "$pkg: unversioned entries not at the julia version $JV" "$(printf '%s' "$BADV" | tr '\n' ' ')"
  fi

  # `julia` must be there — its absence would mean the implicit julia
  # dependency stopped being encoded, which is how compat bounds are enforced.
  grep -q '^added	julia' "$WORK/$pkg.ajt.out" \
    && ok "$pkg: julia is present as a resolved package" \
    || bad "$pkg: julia was NOT selected — the implicit julia dep is not being encoded"

  # GATE 4: the WRITER. A selection that agrees with Pkg is worth little if the
  # manifest built from it does not, and every field below the version —
  # tree hashes, dependency lists, the array-vs-table encoding, the prune — is
  # only exercised by writing one out.
  WDIR="$WORK/write-$pkg"
  mkdir -p "$WDIR"
  cp "$ENV_DIR/Project.toml" "$ENV_DIR/Manifest.toml" "$WDIR/"
  if ! "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --write --quiet \
       "$WDIR" >"$WORK/$pkg.write.out" 2>"$WORK/$pkg.write.err"; then
    bad "$pkg: ajt resolve --write failed" "$(tail -3 "$WORK/$pkg.write.err" | tr '\n' '|')"
    continue
  fi
  if cmp -s "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml"; then
    ok "$pkg: the written manifest is byte-identical to Pkg's"
  else
    bad "$pkg: written manifest differs from Pkg's" \
        "$(diff "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml" | head -6 | tr '\n' '|')"
  fi

  # GATE 5: non-vacuity. The check above passes trivially for a writer that
  # copies its input, which is the failure mode a byte-identity gate invites.
  # So delete every field the writer is supposed to DERIVE — the tree hashes
  # come from the registry, the dependency lists from each version's Deps.toml,
  # the project_hash from the Project.toml — and require it to put all of them
  # back, exactly.
  sed -i '/^git-tree-sha1 = /d; /^deps = \[/d; /^project_hash = /d' "$WDIR/Manifest.toml"
  STRIPPED="$(cmp -s "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml" && echo no || echo yes)"
  if [ "$STRIPPED" != yes ]; then
    bad "$pkg: the perturbation removed nothing — this gate proves nothing"
  else
    if ! "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --write --quiet \
         "$WDIR" >>"$WORK/$pkg.write.out" 2>>"$WORK/$pkg.write.err"; then
      bad "$pkg: ajt resolve --write failed on the stripped manifest" \
          "$(tail -3 "$WORK/$pkg.write.err" | tr '\n' '|')"
    elif cmp -s "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml"; then
      ok "$pkg: rebuilt tree hashes, deps and project_hash from scratch, byte-exact"
    else
      bad "$pkg: could not rebuild the stripped fields" \
          "$(diff "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml" | head -6 | tr '\n' '|')"
    fi
  fi

  # GATE 6: and stock Pkg agrees there is nothing left to do. This is the
  # interop half — the manifest is not just equal to bytes Pkg once wrote, it
  # is one Pkg reads back and leaves alone.
  if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
     --project="$WDIR" -e 'using Pkg; Pkg.resolve()' >"$WORK/$pkg.pkgresolve.log" 2>&1; then
    if cmp -s "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml"; then
      ok "$pkg: stock Pkg.resolve() left the written manifest untouched"
    else
      bad "$pkg: Pkg.resolve() rewrote the manifest ajt wrote" \
          "$(diff "$ENV_DIR/Manifest.toml" "$WDIR/Manifest.toml" | head -6 | tr '\n' '|')"
    fi
  else
    bad "$pkg: Pkg.resolve() failed on the written manifest" \
        "$(tail -3 "$WORK/$pkg.pkgresolve.log" | tr '\n' '|')"
  fi
done


# --- add / rm / why, against Pkg doing the same thing ------------------------
#
# One environment, one package, both tools: `add` it, `why` it, `rm` it, and
# require Pkg's and Ajt's Project.toml AND Manifest.toml to agree byte for byte
# at every step.
#
# `add` is also the only way to exercise a preserve tier end to end. A tier is
# a statement about which packages are allowed to move while something new is
# introduced, so an environment with nothing to introduce cannot distinguish
# `PRESERVE_ALL` from `PRESERVE_NONE` — which is why the tier loop below adds a
# package rather than re-resolving in place.
echo
echo "==> add / why / rm"
ADD_ENV="$WORK/env-DataFrames"
if [ ! -f "$ADD_ENV/Manifest.toml" ]; then
  echo "  (skipped: DataFrames was not part of this run)"
else
  for tier in tiered all direct semver none; do
    A="$WORK/addpkg-$tier/pkg"; B="$WORK/addpkg-$tier/ajt"
    mkdir -p "$A" "$B"
    cp "$ADD_ENV/Project.toml" "$ADD_ENV/Manifest.toml" "$A/"
    cp "$ADD_ENV/Project.toml" "$ADD_ENV/Manifest.toml" "$B/"

    # Pkg's own name for the tier. `tiered` is `default_preserve()`, so it is
    # spelled by omitting the keyword entirely — passing PRESERVE_TIERED
    # explicitly would test a different code path than the default does.
    case "$tier" in
      tiered) PRESERVE_ARG="" ;;
      *)      PRESERVE_ARG="; preserve = Pkg.PRESERVE_$(echo "$tier" | tr a-z A-Z)" ;;
    esac
    if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
         --project="$A" -e "using Pkg; Pkg.add(\"JSON\"$PRESERVE_ARG)" \
         >"$WORK/add-$tier.pkg.log" 2>&1; then
      bad "add --preserve $tier: stock Pkg failed" "$(tail -3 "$WORK/add-$tier.pkg.log" | tr '\n' '|')"
      continue
    fi
    if ! "$AJT" add --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --project "$B" \
         --preserve "$tier" JSON >"$WORK/add-$tier.ajt.log" 2>&1; then
      bad "add --preserve $tier: ajt failed" "$(tail -3 "$WORK/add-$tier.ajt.log" | tr '\n' '|')"
      continue
    fi
    if cmp -s "$A/Project.toml" "$B/Project.toml" && cmp -s "$A/Manifest.toml" "$B/Manifest.toml"; then
      ok "add JSON --preserve $tier: Project and Manifest both identical to Pkg's"
    else
      bad "add JSON --preserve $tier differs from Pkg" \
          "$( { diff "$A/Project.toml" "$B/Project.toml"; diff "$A/Manifest.toml" "$B/Manifest.toml"; } | head -6 | tr '\n' '|')"
    fi
  done

  # `why`, byte for byte. Pkg colours the arrow only for a terminal, so a piped
  # Pkg and a piped Ajt are directly comparable.
  WHY_ENV="$WORK/addpkg-tiered/pkg"
  for pkg in JSON Parsers; do
    env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no --project="$WHY_ENV" \
      -e "using Pkg; Pkg.why(\"$pkg\"; io = stdout)" >"$WORK/why-$pkg.pkg" 2>/dev/null
    "$AJT" why --project "$WHY_ENV" "$pkg" >"$WORK/why-$pkg.ajt" 2>&1
    if [ ! -s "$WORK/why-$pkg.pkg" ]; then
      bad "why $pkg: Pkg printed nothing — the fixture no longer contains it"
    elif cmp -s "$WORK/why-$pkg.pkg" "$WORK/why-$pkg.ajt"; then
      ok "why $pkg: byte-identical to Pkg.why ($(grep -c . "$WORK/why-$pkg.ajt") path(s))"
    else
      bad "why $pkg differs from Pkg.why" \
          "$(diff "$WORK/why-$pkg.pkg" "$WORK/why-$pkg.ajt" | head -6 | tr '\n' '|')"
    fi
  done

  # `rm`, which does NOT resolve — every surviving entry keeps its version and
  # only the unreachable ones go.
  R="$WORK/addpkg-tiered/pkg"; S="$WORK/addpkg-tiered/ajt"
  env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
    --project="$R" -e 'using Pkg; Pkg.rm("JSON")' >"$WORK/rm.pkg.log" 2>&1
  "$AJT" rm --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --project "$S" JSON >"$WORK/rm.ajt.log" 2>&1
  if cmp -s "$R/Project.toml" "$S/Project.toml" && cmp -s "$R/Manifest.toml" "$S/Manifest.toml"; then
    ok "rm JSON: Project and Manifest both identical to Pkg's"
  else
    bad "rm JSON differs from Pkg" \
        "$( { diff "$R/Project.toml" "$S/Project.toml"; diff "$R/Manifest.toml" "$S/Manifest.toml"; } | head -6 | tr '\n' '|')"
  fi
  # And the round trip lands back where it started, which is the property that
  # catches an `rm` that prunes too much or a `project_hash` computed from the
  # pre-edit table.
  if cmp -s "$ADD_ENV/Manifest.toml" "$S/Manifest.toml"; then
    ok "add then rm returns the manifest to its original bytes"
  else
    bad "add+rm did not round-trip" \
        "$(diff "$ADD_ENV/Manifest.toml" "$S/Manifest.toml" | head -6 | tr '\n' '|')"
  fi
fi

# --- a `develop`ed dependency ------------------------------------------------
#
# A path-tracked entry is in NO registry, so it cannot be resolved — it has to
# be injected as a fixed package, decided rather than chosen (`collect_fixed!`,
# Operations.jl:418-475). Miss that and `universeFor` hands back an empty
# universe, every requirement on the package is unsatisfiable, and the whole
# resolve fails — with the error naming a bare UUID, because an unregistered
# package has no name to print either.
#
# This gate exists because the corpus above could not have caught it. Every
# environment in it comes from `Pkg.add`, so not one contains a dev'd entry —
# four gates and 42 checks passed over the hole. It was found from outside, by
# the Julia wrapper driving the CLI as a real consumer, and the environment
# `Pkg.test` builds has exactly this shape.
echo
echo "==> a develop'd dependency"
DEV="$WORK/devdep"
mkdir -p "$DEV/env" "$DEV/MyDep/src"
cat > "$DEV/MyDep/Project.toml" <<'PROJ'
name = "MyDep"
uuid = "11111111-2222-3333-4444-555555555555"
version = "0.1.0"

[deps]
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

[compat]
JSON = "1"
PROJ
echo 'module MyDep end' > "$DEV/MyDep/src/MyDep.jl"

if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 DEVPATH="$DEV/MyDep" \
     julia --startup-file=no --project="$DEV/env" \
     -e 'using Pkg; Pkg.develop(path=ENV["DEVPATH"])' \
     >"$WORK/devdep.pkg.log" 2>&1; then
  bad "develop: stock Pkg could not develop the fixture" \
      "$(tail -3 "$WORK/devdep.pkg.log" | tr '\n' '|')"
else
  cp "$DEV/env/Manifest.toml" "$DEV/pkg.toml"
  ENTRIES="$(grep -c '^\[\[deps\.' "$DEV/env/Manifest.toml")"
  ok "develop: stock Pkg produced a $ENTRIES-entry manifest with a path entry"

  # The resolve must SUCCEED (the regression was a hard failure), and the
  # manifest must match Pkg's byte for byte.
  if ! "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --write --quiet \
       "$DEV/env" >"$WORK/devdep.ajt.log" 2>&1; then
    bad "develop: ajt resolve --write FAILED on a path-tracked entry" \
        "$(tail -4 "$WORK/devdep.ajt.log" | tr '\n' '|')"
  elif cmp -s "$DEV/pkg.toml" "$DEV/env/Manifest.toml"; then
    ok "develop: the written manifest is byte-identical to Pkg's"
  else
    bad "develop: written manifest differs from Pkg's" \
        "$(diff "$DEV/pkg.toml" "$DEV/env/Manifest.toml" | head -6 | tr '\n' '|')"
  fi

  # The dev'd package must be HELD, not "added" — it is a manifest entry, and
  # reporting it as new would mean the injection lost its identity.
  "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" "$DEV/env" \
    >"$WORK/devdep.sel" 2>&1 || true
  grep -q '^held	MyDep' "$WORK/devdep.sel" \
    && ok "develop: MyDep is held at its path-declared version" \
    || bad "develop: MyDep was not held" "$(grep MyDep "$WORK/devdep.sel" | head -2 | tr '\n' '|')"

  # And the package's own [deps] must have been honoured: JSON comes only from
  # MyDep's Project.toml, so its presence proves the injected deps were read
  # from disk rather than guessed.
  grep -q 'JSON' "$DEV/env/Manifest.toml" \
    && ok "develop: the path package's own [deps] pulled JSON into the closure" \
    || bad "develop: JSON absent — the dev'd package's Project.toml was not read"
fi


# --- dev / pin / free, against Pkg's own ------------------------------------
#
# These three edit a MANIFEST entry rather than [deps], which is a different
# code path from add/rm/up, and each has a Pkg equivalent to compare against
# byte for byte. Two of the checks below exist because the first attempt got
# them wrong in ways nothing else would have caught:
#
#   * `ajt dev` into a FRESH environment produced a one-entry manifest where
#     Pkg produces fifteen. composeManifest took a fixed entry's deps from the
#     prior manifest entry, and on a first dev there is no prior — so the whole
#     closure was pruned as unreachable. An environment that already had the
#     entry looked perfectly correct.
#   * `pin` accepts only a DIRECT dependency (project_deps_resolve!) while
#     `free` accepts any manifest entry (manifest_resolve!). That asymmetry is
#     Pkg's and is not visible from either signature.
echo "==> dev / pin / free"
EDIT="$WORK/edit"
mkdir -p "$EDIT/MyDep2/src"
cat > "$EDIT/MyDep2/Project.toml" <<'PROJ'
name = "MyDep2"
uuid = "22222222-3333-4444-5555-666666666666"
version = "0.2.0"

[deps]
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
PROJ
echo 'module MyDep2 end' > "$EDIT/MyDep2/src/MyDep2.jl"

# `dev` into a FRESH environment, both sides, in BOTH argument forms.
#
# The two forms are not interchangeable, and that is the point: Pkg records an
# absolute path when it was given one and a relative path when it was not
# (`original_source_was_absolute`, Types.jl:780/805/878). A gate that tested
# only one form would let the other silently diverge — and the first version of
# this gate did exactly that, handing Pkg an absolute path and ajt a relative
# one, so it reported a difference that was its own fault.
dev_case() {  # <label> <pkg-dir> <ajt-dir> <arg-for-pkg> <arg-for-ajt> <run-from>
  local label=$1 pkgdir=$2 ajtdir=$3 pkgarg=$4 ajtarg=$5 from=$6
  mkdir -p "$pkgdir" "$ajtdir"
  if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 DEVPATH="$pkgarg" \
       julia --startup-file=no --project="$pkgdir" \
       -e 'using Pkg; cd(ENV["RUNFROM"]) do; Pkg.develop(path=ENV["DEVPATH"]); end' \
       >"$WORK/edit.devpkg.$label.log" 2>&1; then
    bad "dev ($label): stock Pkg.develop failed" \
        "$(tail -3 "$WORK/edit.devpkg.$label.log" | tr '\n' '|')"
    return
  fi
  if ! ( cd "$from" && "$AJT" dev --project "$ajtdir" --depot "$DEPOT" \
         --julia-prefix "$JULIA_PREFIX" "$ajtarg" ) \
       >"$WORK/edit.devajt.$label.log" 2>&1; then
    bad "dev ($label): ajt dev failed" \
        "$(tail -4 "$WORK/edit.devajt.$label.log" | tr '\n' '|')"
    return
  fi
  cmp -s "$pkgdir/Project.toml" "$ajtdir/Project.toml" \
    && ok "dev ($label): Project.toml byte-identical to Pkg.develop's" \
    || bad "dev ($label): Project.toml differs" \
           "$(diff "$pkgdir/Project.toml" "$ajtdir/Project.toml" | head -6 | tr '\n' '|')"
  cmp -s "$pkgdir/Manifest.toml" "$ajtdir/Manifest.toml" \
    && ok "dev ($label): Manifest.toml byte-identical to Pkg.develop's" \
    || bad "dev ($label): Manifest.toml differs" \
           "$(diff "$pkgdir/Manifest.toml" "$ajtdir/Manifest.toml" | head -8 | tr '\n' '|')"
}

export RUNFROM="$EDIT"
dev_case abs "$EDIT/dev_pkg_a" "$EDIT/dev_ajt_a" "$EDIT/MyDep2" "$EDIT/MyDep2" "$EDIT"
RUNFROM="$EDIT/dev_pkg_r" dev_case rel "$EDIT/dev_pkg_r" "$EDIT/dev_ajt_r" "../MyDep2" "../MyDep2" "$EDIT/dev_ajt_r"

# The absolute form must really have recorded an absolute path, or "identical"
# above would be two tools agreeing on the wrong thing.
grep -q '^path = "/' "$EDIT/dev_ajt_a/Manifest.toml" \
  && ok "dev (abs): an absolute argument is recorded absolute, as Pkg does" \
  || bad "dev (abs): the path was relativised" \
         "$(grep '^path' "$EDIT/dev_ajt_a/Manifest.toml" | head -2 | tr '\n' '|')"
grep -q '^path = "\.\./MyDep2"' "$EDIT/dev_ajt_r/Manifest.toml" \
  && ok "dev (rel): a relative argument stays relative" \
  || bad "dev (rel): the path was absolutised" \
         "$(grep '^path' "$EDIT/dev_ajt_r/Manifest.toml" | head -2 | tr '\n' '|')"

# The regression guard: a one-entry manifest is what the composeManifest bug
# produced, and everything above would still have passed if BOTH sides had it.
DEVN="$(grep -c '^\[\[deps\.' "$EDIT/dev_ajt_r/Manifest.toml")"
[ "$DEVN" -ge 10 ] \
  && ok "dev: the dev'd package's whole closure is in the manifest ($DEVN entries)" \
  || bad "dev: only $DEVN manifest entries — the closure was pruned away"

# Pkg records the path in the MANIFEST and writes no [sources]; matching that
# is why `ajt dev` does not write one either.
grep -q '^\[sources\]' "$EDIT/dev_ajt_r/Project.toml" \
  && bad "dev: wrote a [sources] section that Pkg.develop does not write" \
  || ok "dev: no [sources] written, matching Pkg.develop"

# `pin` and `free`, on an environment with a registered direct dependency.
mkdir -p "$EDIT/pf_pkg" "$EDIT/pf_ajt"
if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
     julia --startup-file=no --project="$EDIT/pf_pkg" \
     -e 'using Pkg; Pkg.add(name="JSON", version="1.5.0")' \
     >"$WORK/edit.base.log" 2>&1; then
  bad "pin/free: could not build the base environment" \
      "$(tail -3 "$WORK/edit.base.log" | tr '\n' '|')"
else
  cp "$EDIT/pf_pkg/Project.toml" "$EDIT/pf_pkg/Manifest.toml" "$EDIT/pf_ajt/"

  for verb in pin free; do
    env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 V="$verb" \
      julia --startup-file=no --project="$EDIT/pf_pkg" \
      -e 'using Pkg; getfield(Pkg, Symbol(ENV["V"]))("JSON")' \
      >"$WORK/edit.$verb.pkg.log" 2>&1 \
      || { bad "$verb: stock Pkg.$verb failed" "$(tail -3 "$WORK/edit.$verb.pkg.log" | tr '\n' '|')"; break; }

    ( cd "$EDIT/pf_ajt" && "$AJT" "$verb" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" JSON ) \
      >"$WORK/edit.$verb.ajt.log" 2>&1 \
      || { bad "$verb: ajt $verb failed" "$(tail -4 "$WORK/edit.$verb.ajt.log" | tr '\n' '|')"; break; }

    cmp -s "$EDIT/pf_pkg/Manifest.toml" "$EDIT/pf_ajt/Manifest.toml" \
      && ok "$verb: Manifest.toml byte-identical to Pkg.$verb's" \
      || bad "$verb: Manifest.toml differs" \
             "$(diff "$EDIT/pf_pkg/Manifest.toml" "$EDIT/pf_ajt/Manifest.toml" | head -6 | tr '\n' '|')"
  done

  # The asymmetry, asserted rather than described. `Parsers` is a transitive
  # dependency of JSON: Pkg refuses to pin it and accepts freeing it, and so
  # must ajt. A gate that only tested the direct case would pass with pin and
  # free implemented identically.
  ( cd "$EDIT/pf_ajt" && "$AJT" pin --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" Parsers ) \
    >"$WORK/edit.pin_trans.log" 2>&1 \
    && bad "pin: accepted a transitive dependency, which Pkg refuses" \
    || ok "pin: a transitive dependency is refused, as Pkg's project_deps_resolve! does"

  env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no --project="$EDIT/pf_pkg" \
    -e 'using Pkg; Pkg.pin("Parsers")' >"$WORK/edit.pin_trans.pkg.log" 2>&1 \
    && bad "pin: stock Pkg ACCEPTED a transitive pin — the premise of this gate is wrong" \
    || ok "pin: stock Pkg refuses it too, so the refusal is parity and not a limitation"
fi

# --- add <url> / dev <url>, against Pkg's own --------------------------------
#
# The repository arms produce four manifest fields nothing else does —
# `repo-url`, `repo-rev`, `repo-subdir` and a `git-tree-sha1` that came from
# peeling a rev rather than from a registry — and agreeing on all four is the
# whole claim. So every case here is a byte-for-byte `cmp` of both TOMLs
# against what stock Pkg writes for the same request.
#
# Four things are checked that a single `add <url>` case would not reach:
#
#   * a BRANCH, a TAG and a full SHA, because `is_branch` is load-bearing:
#     `get_object_or_branch` reports it, and an unpinned branch is re-fetched
#     before its tree is taken (Types.jl:1016-1020). Get that wrong and
#     `add Foo#master` silently pins whatever the cache already held — which
#     looks perfectly correct until the branch moves.
#   * a SUBDIR, against a local monorepo, because the tree is peeled twice
#     there (commit → tree → subtree) and a blob where a tree belongs would be
#     written into the manifest as a `git-tree-sha1` nothing can materialise.
#   * the CLONE CACHE NAME, `clones/<string(hash(url))>` — computed by Julia
#     itself, not by this script — followed by a real `Pkg.gc()` that has to
#     leave it alone. That is the compatibility claim (`Pkg.gc` deletes every
#     `clones/` directory it cannot recompute, `API.jl:772-791`) asserted
#     rather than believed.
#   * an ssh URL, which must be REFUSED with the message `git/git.zig` wrote
#     for it rather than handed to a backend that has no SSH transport.
#
# Example.jl is used because it is tiny and real; the subdir case needs a
# repository shaped like a monorepo, so it builds one locally and adds it
# through a `file://` URL, which both tools clone identically.
echo
echo "==> add <url> / dev <url>"
REPO="$WORK/repo"
mkdir -p "$REPO"
EXAMPLE_URL="https://github.com/JuliaLang/Example.jl"

if ! command -v git >/dev/null; then
  echo "  SKIP: no \`git\` on PATH — every case here clones a repository"
else

# Both sides, same depot, same request, byte for byte. The argument forms
# differ by necessity (Pkg takes keywords, ajt takes a string) and that is the
# point of passing them side by side: `<url>#<rev>` has to mean exactly what
# `url=..., rev=...` means.
repo_case() {  # <label> <julia-kwargs> <ajt-arg>...
  local label=$1 kwargs=$2
  shift 2
  local pdir="$REPO/pkg_$label" adir="$REPO/ajt_$label"
  mkdir -p "$pdir" "$adir"
  if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 KW="$kwargs" \
       julia --startup-file=no --project="$pdir" \
       -e 'using Pkg; eval(Meta.parse("Pkg.add(" * ENV["KW"] * ")"))' \
       >"$WORK/repo.$label.pkg.log" 2>&1; then
    bad "add ($label): stock Pkg.add failed" \
        "$(tail -3 "$WORK/repo.$label.pkg.log" | tr '\n' '|')"
    return
  fi
  if ! "$AJT" add --project "$adir" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" "$@" \
       >"$WORK/repo.$label.ajt.log" 2>&1; then
    bad "add ($label): ajt add failed" \
        "$(tail -4 "$WORK/repo.$label.ajt.log" | tr '\n' '|')"
    return
  fi
  # The landmark: this really went through the repository arm. A registry add
  # writes neither field, so a gate that only compared the two files would go
  # green if BOTH tools had quietly resolved Example from General.
  grep -q '^repo-url = ' "$adir/Manifest.toml" && grep -q '^git-tree-sha1 = ' "$adir/Manifest.toml" \
    && ok "add ($label): the entry carries repo-url and a git-tree-sha1" \
    || bad "add ($label): no repo-url/git-tree-sha1 — this was not a repository add" \
           "$(head -20 "$adir/Manifest.toml" | tr '\n' '|')"
  cmp -s "$pdir/Project.toml" "$adir/Project.toml" \
    && ok "add ($label): Project.toml byte-identical to Pkg.add's" \
    || bad "add ($label): Project.toml differs" \
           "$(diff "$pdir/Project.toml" "$adir/Project.toml" | head -6 | tr '\n' '|')"
  cmp -s "$pdir/Manifest.toml" "$adir/Manifest.toml" \
    && ok "add ($label): Manifest.toml byte-identical to Pkg.add's" \
    || bad "add ($label): Manifest.toml differs" \
           "$(diff "$pdir/Manifest.toml" "$adir/Manifest.toml" | head -8 | tr '\n' '|')"
}

# No rev at all: both sides must land on the DEFAULT BRANCH — `isattached(repo)
# ? branch(repo) : head` (Types.jl:996-999) — and record its name, not a
# commit. A `repo-rev = "<40 hex>"` here would compare equal to nothing.
repo_case url "url=\"$EXAMPLE_URL\"" "$EXAMPLE_URL"
grep -q '^repo-rev = "master"$' "$REPO/ajt_url/Manifest.toml" \
  && ok "add (url): no rev given resolves to the default BRANCH, as handle_repo_add! does" \
  || bad "add (url): repo-rev is not the default branch" \
         "$(grep '^repo-rev' "$REPO/ajt_url/Manifest.toml" | tr '\n' '|')"

# A branch, explicitly. `is_branch` true, so ajt re-fetches before taking the
# tree; Pkg does the same, and the tree hashes have to agree afterwards.
repo_case branch "url=\"$EXAMPLE_URL\", rev=\"master\"" "$EXAMPLE_URL#master"

# A tag. `get_object_or_branch` resolves it through the fourth probe, NOT a
# branch namespace, so `is_branch` is false and nothing is re-fetched.
repo_case tag "url=\"$EXAMPLE_URL\", rev=\"v0.5.4\"" "$EXAMPLE_URL#v0.5.4"

# A full commit sha, read out of the clone both sides now share. `hash(url)` is
# computed by Julia rather than reimplemented here, which is also the first
# half of the cache-name check below.
URL_HASH="$(env JULIA_DEPOT_PATH="$DEPOT" julia --startup-file=no \
  -e "print(hash(\"$EXAMPLE_URL\"))")"
CLONE_DIR="$DEPOT/clones/$URL_HASH"
if [ ! -d "$CLONE_DIR" ]; then
  bad "add: no clone at clones/$URL_HASH" \
      "clones/ holds: $(ls "$DEPOT/clones" 2>/dev/null | tr '\n' ' ')"
else
  ok "add: the clone landed at clones/<string(hash(url))>, the name Pkg.gc recomputes"
  SHA="$(git -C "$CLONE_DIR" rev-parse "remotes/cache/heads/master^{}" 2>/dev/null ||
         git -C "$CLONE_DIR" rev-parse "master^{}" 2>/dev/null)"
  # An empty SHA would make the ajt argument `<url>#`, which `splitRev`
  # deliberately reads as NO rev — the case would then compare a default-branch
  # add against Pkg's `rev=""` and fail for the wrong reason.
  if [ -z "$SHA" ]; then
    bad "add (sha): could not read a commit out of the clone" \
        "refs: $(git -C "$CLONE_DIR" for-each-ref --format='%(refname)' 2>/dev/null | head -3 | tr '\n' ' ')"
  else
    repo_case sha "url=\"$EXAMPLE_URL\", rev=\"$SHA\"" "$EXAMPLE_URL#$SHA"
  fi
fi

# Exactly one clone for the two tools. A different cache key would be invisible
# in every comparison above and would show up here as a second directory —
# and, on a real depot, as a clone Pkg.gc deletes out from under ajt.
CLONES="$(ls "$DEPOT/clones" 2>/dev/null | wc -l)"
[ "$CLONES" -eq 1 ] \
  && ok "add: Pkg and ajt shared ONE clone directory, so the cache key agrees" \
  || bad "add: $CLONES clone directories for one URL — the cache key diverges" \
         "$(ls "$DEPOT/clones" | tr '\n' ' ')"

# --- a subdir, against a monorepo built for it ------------------------------
MONO="$REPO/mono"
mkdir -p "$MONO/pkgs/SubPkg/src"
cat > "$MONO/pkgs/SubPkg/Project.toml" <<'PROJ'
name = "SubPkg"
uuid = "44444444-5555-6666-7777-888888888888"
version = "0.3.0"
PROJ
echo 'module SubPkg end' > "$MONO/pkgs/SubPkg/src/SubPkg.jl"
echo 'a monorepo root that is NOT the package' > "$MONO/README.md"
(
  cd "$MONO" && git init --quiet --initial-branch=main . && git add -A &&
  env GIT_AUTHOR_NAME=ajt GIT_AUTHOR_EMAIL=ajt@example.invalid \
      GIT_COMMITTER_NAME=ajt GIT_COMMITTER_EMAIL=ajt@example.invalid \
      git commit --quiet -m "monorepo"
) >"$WORK/repo.mono.log" 2>&1 || bad "subdir: could not build the monorepo fixture"

repo_case subdir "url=\"file://$MONO\", subdir=\"pkgs/SubPkg\"" \
  --url "file://$MONO" --subdir "pkgs/SubPkg"
grep -q '^repo-subdir = "pkgs/SubPkg"$' "$REPO/ajt_subdir/Manifest.toml" \
  && ok "add (subdir): repo-subdir is recorded" \
  || bad "add (subdir): no repo-subdir in the manifest"
# The root of that repository has no Project.toml at all, so descending is not
# optional: naming SubPkg at all proves the second peel happened.
grep -q '^\[\[deps\.SubPkg\]\]' "$REPO/ajt_subdir/Manifest.toml" \
  && ok "add (subdir): the entry is the package inside the subdirectory" \
  || bad "add (subdir): SubPkg is not in the manifest" \
         "$(cat "$REPO/ajt_subdir/Manifest.toml" 2>/dev/null | tr '\n' '|')"

mkdir -p "$REPO/ajt_nosub"
"$AJT" add --project "$REPO/ajt_nosub" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" \
  --url "file://$MONO" --subdir "pkgs/Nope" >"$WORK/repo.nosub.log" 2>&1 \
  && bad "subdir: a subdirectory that does not exist was accepted" \
  || ok "subdir: a missing subdirectory is refused"
# ...for the RIGHT reason. A non-zero exit alone would also be satisfied by an
# argument-parse error or by "no usable git", which is how a refusal check
# quietly stops testing the thing it names.
grep -q 'did not find subdirectory `pkgs/Nope`' "$WORK/repo.nosub.log" \
  && ok "subdir: the refusal names the subdirectory, as Types.jl:1029 does" \
  || bad "subdir: refused for some other reason" \
         "$(head -3 "$WORK/repo.nosub.log" | tr '\n' '|')"

# --- ssh, refused rather than attempted -------------------------------------
mkdir -p "$REPO/ajt_ssh"
"$AJT" add --project "$REPO/ajt_ssh" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" \
  "git@github.com:JuliaLang/Example.jl.git" >"$WORK/repo.ssh.log" 2>&1 \
  && bad "ssh: an ssh URL was accepted by a build with no SSH transport" \
  || ok "ssh: refused"
grep -q 'no SSH transport' "$WORK/repo.ssh.log" \
  && ok "ssh: the refusal is git.core.ssh_unsupported_message, naming both ways out" \
  || bad "ssh: the message is not the one written for this" \
         "$(head -3 "$WORK/repo.ssh.log" | tr '\n' '|')"
grep -qE 'edit\.zig:[0-9]+|in main \(main\.zig\)' "$WORK/repo.ssh.log" \
  && bad "ssh: a Zig stack trace was printed for a refusal" \
  || ok "ssh: no stack trace — it fails as a refusal, not as a crash"
[ -f "$REPO/ajt_ssh/Project.toml" ] \
  && bad "ssh: Project.toml was written before the refusal" \
  || ok "ssh: nothing was written"

# --- dev <url> --------------------------------------------------------------
#
# The clone is the PRODUCT here, not a cache: it lands in Pkg.devdir() and the
# manifest records that absolute path. Both sides share $DEPOT, so they name
# the same directory — and whichever runs second must REUSE it rather than
# re-clone ("Path `…` exists and looks like the correct repo", Types.jl:852).
mkdir -p "$REPO/pkg_dev" "$REPO/ajt_dev"
if ! env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
     julia --startup-file=no --project="$REPO/pkg_dev" \
     -e "using Pkg; Pkg.develop(url=\"$EXAMPLE_URL\")" \
     >"$WORK/repo.dev.pkg.log" 2>&1; then
  bad "dev (url): stock Pkg.develop failed" "$(tail -3 "$WORK/repo.dev.pkg.log" | tr '\n' '|')"
elif ! "$AJT" dev --project "$REPO/ajt_dev" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" \
       "$EXAMPLE_URL" >"$WORK/repo.dev.ajt.log" 2>&1; then
  bad "dev (url): ajt dev failed" "$(tail -4 "$WORK/repo.dev.ajt.log" | tr '\n' '|')"
else
  cmp -s "$REPO/pkg_dev/Project.toml" "$REPO/ajt_dev/Project.toml" \
    && ok "dev (url): Project.toml byte-identical to Pkg.develop's" \
    || bad "dev (url): Project.toml differs" \
           "$(diff "$REPO/pkg_dev/Project.toml" "$REPO/ajt_dev/Project.toml" | head -6 | tr '\n' '|')"
  cmp -s "$REPO/pkg_dev/Manifest.toml" "$REPO/ajt_dev/Manifest.toml" \
    && ok "dev (url): Manifest.toml byte-identical to Pkg.develop's" \
    || bad "dev (url): Manifest.toml differs" \
           "$(diff "$REPO/pkg_dev/Manifest.toml" "$REPO/ajt_dev/Manifest.toml" | head -8 | tr '\n' '|')"
  # A working tree, not a bare clone: this is a directory somebody edits.
  [ -e "$DEPOT/dev/Example/.git" ] && [ -f "$DEPOT/dev/Example/Project.toml" ] \
    && ok "dev (url): <depot>/dev/Example is a working clone with a .git" \
    || bad "dev (url): the dev directory is not a working clone" \
           "$(ls -a "$DEPOT/dev/Example" 2>/dev/null | tr '\n' ' ')"
  # The manifest records a path, never repo-url: a develop is not a repo-add.
  grep -q '^repo-url' "$REPO/ajt_dev/Manifest.toml" \
    && bad "dev (url): wrote repo-url, which Pkg.develop does not" \
    || ok "dev (url): the entry is path-tracked, as a develop is"
  grep -q '^\[sources\]' "$REPO/ajt_dev/Project.toml" \
    && bad "dev (url): wrote a [sources] section that Pkg.develop does not write" \
    || ok "dev (url): no [sources] written, matching Pkg.develop"
fi

# A rev on a `develop` is an ERROR, not a checkout: "rev argument not supported
# by `develop`; consider using `add` instead" (API.jl:260-262). Accepting it and
# silently cloning the default branch is the failure this pins — and Pkg has to
# be shown refusing it too, or the refusal is a limitation rather than parity.
mkdir -p "$REPO/ajt_devrev"
"$AJT" dev --project "$REPO/ajt_devrev" --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" \
  "$EXAMPLE_URL#master" >"$WORK/repo.devrev.log" 2>&1 \
  && bad "dev: a rev was accepted, which Pkg refuses outright" \
  || ok "dev: a rev is refused"
grep -q 'rev argument not supported by `develop`' "$WORK/repo.devrev.log" \
  && ok "dev: the refusal is Pkg's own wording" \
  || bad "dev: refused for some other reason" \
         "$(head -3 "$WORK/repo.devrev.log" | tr '\n' '|')"
env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 \
  julia --startup-file=no --project="$REPO/pkg_devrev" \
  -e "using Pkg; Pkg.develop(url=\"$EXAMPLE_URL\", rev=\"master\")" \
  >"$WORK/repo.devrev.pkg.log" 2>&1 \
  && bad "dev: stock Pkg ACCEPTED a rev — the premise of this check is wrong" \
  || ok "dev: stock Pkg refuses it too, so the refusal is parity"

# --- Pkg.gc() must leave the clone alone ------------------------------------
#
# In its own depot, because gc reaps everything no TRACKED environment refers
# to and the environments above are only half-tracked (Pkg records its own,
# ajt records nothing unless asked). Here ajt does the add AND the usage
# stamp, and stock Pkg then decides whether any of it survives.
GCD="$REPO/gcdepot"
mkdir -p "$GCD/registries" "$REPO/gc_env"
# Whatever shape the registry is in — a `General.tar.gz` pair or an unpacked
# `General/` — copied wholesale rather than guessed at.
cp -r "$DEPOT/registries/." "$GCD/registries/" 2>/dev/null
if ! "$AJT" add --project "$REPO/gc_env" --depot "$GCD" --julia-prefix "$JULIA_PREFIX" \
     "$EXAMPLE_URL" >"$WORK/repo.gc.add.log" 2>&1; then
  bad "gc: ajt add into a fresh depot failed" "$(tail -4 "$WORK/repo.gc.add.log" | tr '\n' '|')"
else
  GC_CLONES="$(ls "$GCD/clones" 2>/dev/null | tr '\n' ' ')"
  [ "$GC_CLONES" = "$URL_HASH " ] \
    && ok "gc: clones/ holds exactly string(hash(url)) as Julia computes it" \
    || bad "gc: clones/ is '$GC_CLONES', not '$URL_HASH'"

  "$AJT" usage record --depot "$GCD" --log manifest "$REPO/gc_env/Manifest.toml" \
    >"$WORK/repo.gc.usage.log" 2>&1 \
    || bad "gc: ajt usage record failed" "$(tail -3 "$WORK/repo.gc.usage.log" | tr '\n' '|')"

  if ! env JULIA_DEPOT_PATH="$GCD" julia --startup-file=no \
       -e 'using Pkg, Dates; Pkg.gc(collect_delay=Second(0))' \
       >"$WORK/repo.gc.log" 2>&1; then
    bad "gc: stock Pkg.gc() failed" "$(tail -3 "$WORK/repo.gc.log" | tr '\n' '|')"
  else
    [ -d "$GCD/clones/$URL_HASH" ] \
      && ok "gc: Pkg.gc(collect_delay=0) kept ajt's clone — the cache key really is Pkg's" \
      || bad "gc: Pkg.gc DELETED ajt's clone; add_repo_cache_path disagrees" \
             "clones/ now holds: $(ls "$GCD/clones" 2>/dev/null | tr '\n' ' ')"
    # And the installed tree survives too, which is `find_installed`'s slug
    # agreeing — the same claim one directory over.
    [ -d "$GCD/packages/Example" ] && [ -n "$(ls "$GCD/packages/Example" 2>/dev/null)" ] \
      && ok "gc: the installed tree survived, so the version slug agrees too" \
      || bad "gc: Pkg.gc deleted the installed package"
  fi
fi

fi  # git available

# --- an environment that cannot be resolved ---------------------------------
#
# Everything above tests agreement on environments that HAVE a solution. The
# reason for choosing PubGrub over MaxSum was the other case: Pkg's resolver
# can report `:unsat` with little more than a list, while a derivation tree can
# say which two requirements are irreconcilable. That claim needs a gate, and
# the gate needs Julia to agree the environment really is unsatisfiable —
# otherwise it tests Ajt's ability to reject things Pkg accepts.
#
# The conflict: CSV 0.8 needs Parsers 1.x, while DataFrames 1.7+ needs
# InlineStrings, which needs Parsers 2.x.
echo
echo "==> an unsatisfiable environment"
UNSAT="$WORK/unsat"
mkdir -p "$UNSAT"
cat > "$UNSAT/Project.toml" <<'PROJ'
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"

[compat]
CSV = "0.8"
DataFrames = "1.7"
julia = "1.12"
PROJ

if env JULIA_DEPOT_PATH="$DEPOT" JULIA_PKG_PRECOMPILE_AUTO=0 julia --startup-file=no \
   --project="$UNSAT" -e 'using Pkg; Pkg.resolve()' >"$WORK/unsat.pkg.log" 2>&1; then
  bad "FIXTURE IS STALE: stock Pkg now resolves this environment" \
      "pick another conflict — this gate is testing nothing as written"
else
  ok "stock Pkg also refuses it"

  if "$AJT" resolve --depot "$DEPOT" --julia-prefix "$JULIA_PREFIX" --julia-version 1.12.6 \
     "$UNSAT" >"$WORK/unsat.ajt.out" 2>"$WORK/unsat.ajt.err"; then
    bad "ajt RESOLVED an environment Pkg calls unsatisfiable" \
        "$(grep -c '^held' "$WORK/unsat.ajt.out" || true) packages selected"
  else
    ok "ajt refuses it too"

    # It must EXPLAIN, in Julia's terms. A derivation tree keyed by UUID is
    # the failure mode this checks for: correct, complete and unreadable.
    grep -q 'to fix, try relaxing' "$WORK/unsat.ajt.out" \
      && ok "the failure ends in an actionable line" \
      || bad "no 'to fix' line — the report is a proof with no conclusion"

    for name in CSV DataFrames Parsers; do
      grep -q "$name" "$WORK/unsat.ajt.out" \
        || bad "the report never mentions $name, which is part of the conflict"
    done
    grep -q 'CSV' "$WORK/unsat.ajt.out" && grep -q 'DataFrames' "$WORK/unsat.ajt.out" \
      && ok "it names the packages in conflict"

    # No bare UUIDs anywhere in the rendered report.
    if grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$WORK/unsat.ajt.out"; then
      bad "the report still prints raw UUIDs" \
          "$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}[^ ]*' "$WORK/unsat.ajt.out" | head -2 | tr '\n' ' ')"
    else
      ok "no raw UUIDs in the report — every package key was resolved to a name"
    fi

    # And no Zig stack trace: an unsatisfiable environment is an answer, not a
    # crash, and a trace through the solver tells the user about Ajt instead.
    grep -qE 'pubgrub\.zig:[0-9]+|in main \(main\.zig\)' "$WORK/unsat.ajt.err" \
      && bad "a stack trace was printed for an ordinary resolution failure" \
      || ok "no stack trace — it fails as a diagnosis, not as a crash"
  fi
fi

echo
echo "======================================================================"
printf 'resolve: %d passed, %d failed\n' "$PASS" "$FAIL"
[ $FAIL -eq 0 ] || exit 1
[ $PASS -gt 0 ] || { echo "nothing ran"; exit 3; }
exit 0
