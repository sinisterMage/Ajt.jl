#!/usr/bin/env bash
# Differential gate for the recursive derivation key (src/cache/key.zig).
#
# Why this gate exists. The key is what a shared precompile-cache object is
# NAMED by, and both ways of getting it wrong are silent:
#
#   * Key too volatile -> every machine misses, every CI job recompiles, and
#     nothing anywhere reports an error. The cache simply never has what anyone
#     asks for, and the only symptom is that the 10x never arrives.
#   * Key not volatile enough -> a store hit hands out a `.ji` built against a
#     different dependency. `stale_cachefile` rejects it at load
#     (base/loading.jl:4046-4079), so it cannot mis-load -- but it recompiles
#     the whole subtree after paying for the download, which is worse than
#     having no cache at all.
#
# The recursion is the part that has to be proved, not asserted. `key(P)` folds
# in `key(D)` for every non-sysimage direct dep, so a change to one package's
# content must move the keys of EXACTLY its transitive dependents. This gate
# computes that expected set independently -- a plain reachability walk over the
# manifest, in Julia, using Julia's own TOML parser and `Pkg.Types.stdlibs()` --
# rather than asking the implementation what its own answer should be.
#
# Six sections:
#
#   1. DETERMINISM. Two dumps over the real 214-entry Open-Reality manifest must
#      be byte-identical. A key that is not reproducible within one machine is
#      not a sharing key.
#   2. RECURSION. One package's `git-tree-sha1` is changed in a copy of the
#      manifest; the set of keys that move must equal the reverse-reachable set
#      computed by the Julia walk. Both directions matter: a missing dependent
#      is a stale hit, an extra one is a needless miss. The affected set is
#      printed. Run twice: once for the package with the largest dependent
#      closure, and once (2b) for an UPGRADABLE stdlib — `DelimitedFiles` /
#      `Statistics`, which live in the stdlib directory but are registry
#      packages (`Types.jl:501, 514-517`). The second target exists because
#      widening the key's dep-edge predicate from `isStdlib` to
#      `isOrWasStdlib` is invisible to the first: its closure contains no such
#      edge, and the mutation would otherwise pass the whole gate while
#      silently turning 21 moved keys into 1.
#   3. SYSIMAGE. A different sysimage digest must move EVERY key -- it is the
#      stdlib closure, and every package is built against it.
#   4. ORDER-INDEPENDENCE. The `deps` arrays in the manifest are reversed; every
#      key must be unchanged, because the dep keys are sorted before hashing.
#   5. FIELD ORDER. The preimage of one package is dumped and its documented
#      byte offsets are checked against values this script computed itself
#      (the domain tag, the sysimage digest it passed in, the package's uuid and
#      `git-tree-sha1` from the manifest, the cacheflags byte, the cpu_target
#      length prefix, the dep count and the sorted dep keys). This is the check
#      that fails if the fields are ever reordered.
#   6. LENGTH PREFIXES. Two runs chosen so that dropping the length prefixes
#      would make their preimages IDENTICAL: cacheflags = 98 = 'b', with
#      (path="a", cpu_target="bc") against (path="ab", cpu_target="c"), since
#      stripping the prefixes leaves `path ++ cacheflags ++ cpu_target` and
#      "a" ++ 'b' ++ "bc" == "ab" ++ 'b' ++ "c". Their keys must differ. A
#      preimage collision is a WRONG CACHE HIT, which is the one failure this
#      design otherwise cannot produce. The probe keys a synthetic package with
#      no dependencies (`--raw`): run it against a real manifest entry instead
#      and the change in `cpu_target` reaches the key through the entry's
#      DEPENDENCY keys, which makes the two differ for the wrong reason and
#      turns the probe into a tautology. That mistake was in this file first.
#   7. PREFERENCES. A `prefs_hash` on one package must move exactly the closure
#      a content change moves. Without this the field is untested by the gate —
#      section 5 only ever sees prefs_hash = 0 — so ignoring preferences
#      entirely passed every other check.
#
# Nothing here writes outside $WORK, and no depot is touched at all: the key is
# a pure function of a manifest plus five environment inputs.
#
# Usage: tools/diff_harness/cache_key.sh [--keep]
set -uo pipefail

# Julia sorts strings in byte order; GNU sort under a UTF-8 locale does not,
# which turns a clean pass into phantom diffs on names like `LLD_jll`.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

skip() {
  echo
  echo "########################################################################"
  printf '# SKIPPED: %-60s #\n' "$1"
  echo "# Every section needs a real 214-entry manifest, Julia's own TOML       #"
  echo "# parser and stdlib set as the independent oracle, and zig to build the #"
  echo "# dumper. There is no offline subset of this gate.                      #"
  echo "########################################################################"
  exit 0
}

command -v julia >/dev/null || skip "julia not on PATH"
command -v zig   >/dev/null || skip "zig not on PATH"
[ -f "$MANIFEST" ] || skip "no $MANIFEST"

WORK="$(mktemp -d -t ajt-cachekey-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# --- environment inputs, all from the one julia on PATH ---------------------
SYSIMAGE_FILE=$(julia -e 'print(unsafe_string(Base.JLOptions().image_file))')
[ -f "$SYSIMAGE_FILE" ] || skip "sysimage $SYSIMAGE_FILE not readable"
SYSIMAGE=$(sha256sum "$SYSIMAGE_FILE" | cut -d' ' -f1)
CACHEFLAGS=$(julia -e 'print(Base._cacheflag_to_uint8(Base.CacheFlags()))')
CPU_TARGET=$(julia -e 'print(get(ENV, "JULIA_CPU_TARGET", unsafe_string(Base.JLOptions().cpu_target)))')
PREFIX=$(julia -e 'print(dirname(Sys.BINDIR))')
JULIA_VERSION=$(julia -e 'print(VERSION)')

echo "manifest : $MANIFEST"
echo "sysimage : $SYSIMAGE  ($SYSIMAGE_FILE)"
echo "flags    : $CACHEFLAGS   cpu_target: $CPU_TARGET   julia: $JULIA_VERSION"

# The environment's own package is a `path = "."` entry: no git-tree-sha1, so
# `cache/key.zig` refuses to key it without an explicit Local. The tree hash
# below is a fixed stand-in -- what a real driver would pass is
# `julia/treehash.zig` over the working directory, which treehash.sh already
# gates. This gate is about the key ALGEBRA, not about tree hashing.
SELF_UUID="b08b1914-4d33-46de-8c63-ba029b7f1c5f"
SELF_TREE="0000000000000000000000000000000000000001"

# --- the dumper -------------------------------------------------------------
# One hermetic zig cache for the whole run: `zig run`'s manifest is keyed on the
# -M paths as given while recording inputs by absolute path, so two checkouts of
# this repo can collide in ~/.cache/zig. Every zig-invoking harness here does
# this the same way.
dump() { # dump <out> <manifest> <sysimage> <cacheflags> <cpu_target> [extra args...]
  local out="$1" manifest="$2" sysimage="$3" flags="$4" cpu="$5"; shift 5
  ( cd "$AJT_ROOT" && zig run \
      --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
      --dep ajt -Mroot=tools/diff_harness/cache_key_dump.zig -Majt=src/root.zig \
      -- "$manifest" \
         --sysimage "$sysimage" --cacheflags "$flags" --cpu-target "$cpu" \
         --julia-prefix "$PREFIX" --julia-version "$JULIA_VERSION" \
         --local "$SELF_UUID=$SELF_TREE:/engine" \
         "$@" ) > "$out" 2>"$out.err"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: dump failed ($manifest)" >&2
    tail -20 "$out.err" >&2
    exit 2
  fi
}

# --- the independent oracle -------------------------------------------------
# A plain reachability walk over the manifest, in Julia, with Julia's own TOML
# parser and Julia's own stdlib set. It never sees ajt's answer.
echo
echo "==> Julia oracle: manifest graph and the expected affected set"
julia -e '
using TOML, Pkg
m = TOML.parsefile(ARGS[1])
tbl = m["deps"]
stdlibs = Set(string(u) for u in keys(Pkg.Types.stdlibs()))

name2uuid = Dict{String,String}()
for (name, arr) in tbl, e in arr
    get!(name2uuid, name, e["uuid"])
end

edges  = Dict{String,Vector{String}}()   # uuid -> direct dep uuids
uname  = Dict{String,String}()
hastree = Dict{String,Bool}()
for (name, arr) in tbl, e in arr
    u = e["uuid"]; uname[u] = name; hastree[u] = haskey(e, "git-tree-sha1")
    d = get(e, "deps", String[])
    edges[u] = d isa AbstractVector ? [name2uuid[x] for x in d] :
               d isa AbstractDict   ? [string(v) for v in values(d)] : String[]
end

# Only non-sysimage packages get a key, and propagation runs through those
# nodes only, so the walk is restricted to them exactly as the key is.
keyed = sort([u for u in keys(edges) if !(u in stdlibs)], by = u -> uname[u])
rev = Dict{String,Vector{String}}()
for u in keyed, d in edges[u]
    d in stdlibs && continue
    push!(get!(rev, d, String[]), u)
end

function affected(root)
    seen = Set([root]); stack = [root]
    while !isempty(stack)
        for p in get(rev, pop!(stack), String[])
            p in seen && continue
            push!(seen, p); push!(stack, p)
        end
    end
    return seen
end

# The mutation target: the keyed package with the most transitive dependents,
# ties broken by name, and it must have a git-tree-sha1 to mutate.
cands = [u for u in keyed if hastree[u]]
best = maximum(u -> length(affected(u)), cands)
target = first(sort([u for u in cands if length(affected(u)) == best], by = u -> uname[u]))

# The preimage probe wants a package with several non-sysimage deps.
nd(u) = count(d -> !(d in stdlibs), edges[u])
probe = first(sort([u for u in cands if nd(u) == maximum(nd, cands)], by = u -> uname[u]))

# A SECOND target, specifically an UPGRADABLE stdlib. `DelimitedFiles` and
# `Statistics` live in the stdlib directory but `load_stdlib` skips them
# (Types.jl:501, 514-517), so they are registry packages with a git-tree-sha1
# and they MUST be keyed and MUST propagate. Widening the key`s dep-edge
# predicate from `isStdlib` to `isOrWasStdlib` silences exactly this and
# nothing else, which is why it needs its own target: the max-closure target
# above has no upgradable-stdlib edge anywhere in its closure.
# UPGRADABLE_STDLIBS_UUIDS is filled as a side effect of load_stdlib
# (Types.jl:502, 514-516), so stdlib_infos() must be forced first.
Pkg.Types.stdlib_infos()
upg = Set(string(u) for u in Pkg.Types.UPGRADABLE_STDLIBS_UUIDS)
upcands = [u for u in cands if u in upg && length(affected(u)) > 1]

println("entries ", sum(length(a) for a in values(tbl)))
println("keyed ", length(keyed))
println("target ", uname[target], " ", target)
println("probe ", uname[probe], " ", probe, " ", nd(probe))
for u in sort(collect(affected(target)), by = x -> uname[x])
    println("affected ", uname[u])
end
if !isempty(upcands)
    up = first(sort(upcands, by = u -> uname[u]))
    println("upgradable ", uname[up], " ", up)
    for u in sort(collect(affected(up)), by = x -> uname[x])
        println("upaffected ", uname[u])
    end
end
for (name, arr) in tbl, e in arr
    e["uuid"] in stdlibs && println("stdlib ", e["uuid"])
end
for d in sort([uname[d] for d in edges[probe] if !(d in stdlibs)])
    println("probedep ", d)
end
' "$MANIFEST" > "$WORK/oracle.txt" 2>"$WORK/oracle.err" || {
  echo "ERROR: oracle failed" >&2; tail -20 "$WORK/oracle.err" >&2; exit 2; }

ENTRIES=$(awk '$1=="entries"{print $2}' "$WORK/oracle.txt")
KEYED=$(awk '$1=="keyed"{print $2}' "$WORK/oracle.txt")
TARGET_NAME=$(awk '$1=="target"{print $2}' "$WORK/oracle.txt")
TARGET_UUID=$(awk '$1=="target"{print $3}' "$WORK/oracle.txt")
PROBE_NAME=$(awk '$1=="probe"{print $2}' "$WORK/oracle.txt")
PROBE_UUID=$(awk '$1=="probe"{print $3}' "$WORK/oracle.txt")
PROBE_NDEPS=$(awk '$1=="probe"{print $4}' "$WORK/oracle.txt")
UP_NAME=$(awk '$1=="upgradable"{print $2}' "$WORK/oracle.txt")
UP_UUID=$(awk '$1=="upgradable"{print $3}' "$WORK/oracle.txt")
awk '$1=="affected"{print $2}'   "$WORK/oracle.txt" | sort > "$WORK/expected_affected.txt"
awk '$1=="upaffected"{print $2}' "$WORK/oracle.txt" | sort > "$WORK/expected_upaffected.txt"
awk '$1=="stdlib"{print $2}'     "$WORK/oracle.txt" | sort > "$WORK/expected_skip.txt"
awk '$1=="probedep"{print $2}'   "$WORK/oracle.txt" | sort > "$WORK/probedeps.txt"

echo "  entries $ENTRIES, keyed $KEYED, sysimage $(wc -l < "$WORK/expected_skip.txt")"
echo "  mutation target: $TARGET_NAME ($(wc -l < "$WORK/expected_affected.txt") in its dependent closure)"
if [ -n "$UP_NAME" ]; then
  echo "  upgradable-stdlib target: $UP_NAME ($(wc -l < "$WORK/expected_upaffected.txt") in its closure)"
fi
echo "  preimage probe : $PROBE_NAME with $PROBE_NDEPS non-sysimage deps"

# --- 1: determinism ---------------------------------------------------------
echo
echo "==> 1. determinism over the real manifest"
dump "$WORK/base1.txt" "$MANIFEST" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET"
dump "$WORK/base2.txt" "$MANIFEST" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET"
if cmp -s "$WORK/base1.txt" "$WORK/base2.txt"; then
  ok "two runs are byte-identical"
else
  bad "two runs differ" "$(diff "$WORK/base1.txt" "$WORK/base2.txt" | head -5)"
fi

grep '^key ' "$WORK/base1.txt" | awk '{print $2, $4}' | sort > "$WORK/base.keys"
grep '^skip ' "$WORK/base1.txt" | awk '{print $2}'    | sort > "$WORK/base.skip"
check "keyed count matches the oracle" "$KEYED" "$(wc -l < "$WORK/base.keys")"
check "entries accounted for" "$ENTRIES" "$(( $(wc -l < "$WORK/base.keys") + $(wc -l < "$WORK/base.skip") ))"
if diff -q "$WORK/expected_skip.txt" "$WORK/base.skip" >/dev/null; then
  ok "the skipped set is exactly Pkg.Types.stdlibs() n manifest"
else
  bad "skipped set differs from Julia's stdlibs" "$(diff "$WORK/expected_skip.txt" "$WORK/base.skip" | head -5)"
fi
# 64 hex characters, every one of them.
BADKEY=$(awk '{ if ($2 !~ /^[0-9a-f]{64}$/) print $1 }' "$WORK/base.keys" | head -3)
check "every key is a 64-hex blake3 digest" "" "$BADKEY"
check "no two packages share a key" "$(wc -l < "$WORK/base.keys")" "$(cut -d' ' -f2 "$WORK/base.keys" | sort -u | wc -l)"

# --- 2: the recursion propagates, and no further -----------------------------
# Zeroes one package's git-tree-sha1 and reports which keys moved. `$1` is the
# package name, `$2` a tag for the work files, `$3` the expected-set file.
propagation_case() {
  local pkg="$1" tag="$2" expected="$3"
  mkdir -p "$WORK/$tag"
  awk -v pkg="$pkg" '
    /^\[\[deps\./ { inblk = ($0 == "[[deps." pkg "]]") }
    inblk && /^git-tree-sha1 = / {
      print "git-tree-sha1 = \"0000000000000000000000000000000000000000\""; inblk = 0; next
    }
    { print }
  ' "$MANIFEST" > "$WORK/$tag/Manifest.toml"
  check "[$pkg] exactly one manifest line changed" "1" \
        "$(diff "$MANIFEST" "$WORK/$tag/Manifest.toml" | grep -c '^<')"

  dump "$WORK/$tag.txt" "$WORK/$tag/Manifest.toml" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET"
  grep '^key ' "$WORK/$tag.txt" | awk '{print $2, $4}' | sort > "$WORK/$tag.keys"
  # A dump that silently lost entries would make the join vacuous, so the
  # package sets are compared before the keys are.
  check "[$pkg] same package set as the baseline" "$(wc -l < "$WORK/base.keys")" \
        "$(join "$WORK/base.keys" "$WORK/$tag.keys" | wc -l)"
  join "$WORK/base.keys" "$WORK/$tag.keys" | awk '$2 != $3 {print $1}' | sort > "$WORK/$tag.affected"

  echo "  affected ($(wc -l < "$WORK/$tag.affected")):"
  tr '\n' ' ' < "$WORK/$tag.affected" | fold -s -w 68 | sed 's/^/    /'
  echo
  if diff -q "$expected" "$WORK/$tag.affected" >/dev/null; then
    ok "[$pkg] the moved set is exactly its reverse-reachable closure"
  else
    bad "[$pkg] the moved set is not its transitive dependents"
    comm -23 "$expected" "$WORK/$tag.affected" | sed 's/^/       missing (stale hit): /'
    comm -13 "$expected" "$WORK/$tag.affected" | sed 's/^/       extra (needless miss): /'
  fi
  check "[$pkg] itself moved" "1" "$(grep -cx "$pkg" "$WORK/$tag.affected")"
  check "[$pkg] the closure is a strict subset (something was left alone)" "yes" \
        "$([ "$(wc -l < "$WORK/$tag.affected")" -lt "$KEYED" ] && echo yes || echo no)"
}

echo
echo "==> 2. one tree hash changes -> exactly its transitive dependents move"
propagation_case "$TARGET_NAME" "mut" "$WORK/expected_affected.txt"

# --- 2b: the dep-edge predicate, which target 1 cannot reach -----------------
# `isStdlib` vs `isOrWasStdlib` on the DEP edge (key.zig `Walk.resolve`). An
# upgradable stdlib is a registry package with a tree hash, so it must be keyed
# AND must propagate; widening the predicate silences only this case, and the
# max-closure target above has no such edge in its closure. Without this block
# the mutation is invisible and the gate passes 28/28 against a broken key.
echo
echo "==> 2b. an UPGRADABLE stdlib propagates like any registry package"
if [ -n "$UP_NAME" ]; then
  propagation_case "$UP_NAME" "upmut" "$WORK/expected_upaffected.txt"
else
  echo "  (no upgradable stdlib with dependents in this manifest — nothing to gate)"
fi

# --- 3: the sysimage is in every key ----------------------------------------
echo
echo "==> 3. a different sysimage digest moves every key"
OTHER_SYSIMAGE=$(printf 'a different sysimage' | sha256sum | cut -d' ' -f1)
dump "$WORK/sys.txt" "$MANIFEST" "$OTHER_SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET"
grep '^key ' "$WORK/sys.txt" | awk '{print $2, $4}' | sort > "$WORK/sys.keys"
check "unchanged keys under a new sysimage" "0" "$(join "$WORK/base.keys" "$WORK/sys.keys" | awk '$2 == $3' | wc -l)"
check "same package set" "$(wc -l < "$WORK/base.keys")" "$(join "$WORK/base.keys" "$WORK/sys.keys" | wc -l)"

# --- 4: dep order in the manifest must not matter ---------------------------
echo
echo "==> 4. reversing every deps array changes nothing"
mkdir -p "$WORK/rev"
awk '
  /^[ \t]*deps = \[.*\]$/ {
    open = index($0, "[")
    inner = substr($0, open + 1, length($0) - open - 1)
    n = split(inner, a, ", ")
    out = ""
    for (i = n; i >= 1; i--) out = out a[i] (i > 1 ? ", " : "")
    print substr($0, 1, open) out "]"
    next
  }
  { print }
' "$MANIFEST" > "$WORK/rev/Manifest.toml"
REVLINES=$(diff "$MANIFEST" "$WORK/rev/Manifest.toml" | grep -c '^<')
check "the rewrite actually reordered something" "yes" "$([ "$REVLINES" -gt 10 ] && echo yes || echo no)"

dump "$WORK/rev.txt" "$WORK/rev/Manifest.toml" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET"
grep '^key ' "$WORK/rev.txt" | awk '{print $2, $4}' | sort > "$WORK/rev.keys"
if diff -q "$WORK/base.keys" "$WORK/rev.keys" >/dev/null; then
  ok "$REVLINES reordered deps arrays, 0 keys moved"
else
  bad "dep order changed a key" "$(diff "$WORK/base.keys" "$WORK/rev.keys" | head -5)"
fi

# --- 5: the documented field order ------------------------------------------
echo
echo "==> 5. the preimage is laid out in the documented order"
dump "$WORK/pre.txt" "$MANIFEST" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET" --preimage "$PROBE_UUID"
HEX=$(awk '$1=="preimage"{print $3}' "$WORK/pre.txt")
[ -n "$HEX" ] || { echo "ERROR: no preimage in the dump" >&2; exit 2; }

# Everything compared here was computed by this script, from the manifest and
# the arguments it passed in -- never read back out of ajt's own output.
PROBE_TREE=$(awk -v pkg="$PROBE_NAME" '
  /^\[\[deps\./ { inblk = ($0 == "[[deps." pkg "]]") }
  inblk && /^git-tree-sha1 = / { gsub(/[^0-9a-f]/, "", $3); print $3; exit }
' "$MANIFEST")
PROBE_UUID_HEX=$(printf '%s' "$PROBE_UUID" | tr -d '-')
CPU_HEX=$(printf '%s' "$CPU_TARGET" | od -An -tx1 -v | tr -d ' \n')
# u32 little-endian, as hex.
le32() { printf '%02x%02x%02x%02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 )); }

check "offset  0  domain tag 'ajt-v1' + NUL" "616a742d763100" "${HEX:0:14}"
check "offset  7  sha256(sysimage)"          "$SYSIMAGE"      "${HEX:14:64}"
check "offset 39  uuid, canonical order"     "$PROBE_UUID_HEX" "${HEX:78:32}"
check "offset 55  content tag = registered"  "00"             "${HEX:110:2}"
check "offset 56  git-tree-sha1"             "$PROBE_TREE"    "${HEX:112:40}"
check "offset 76  cacheflags"                "$(printf '%02x' "$CACHEFLAGS")" "${HEX:152:2}"
check "offset 77  cpu_target length, u32 LE" "$(le32 ${#CPU_TARGET})" "${HEX:154:8}"
check "offset 81  cpu_target"                "$CPU_HEX"       "${HEX:162:${#CPU_HEX}}"
POS=$(( 162 + ${#CPU_HEX} ))
check "           prefs_hash (0), u64 LE"    "0000000000000000" "${HEX:$POS:16}"
POS=$(( POS + 16 ))
check "           dependency count, u32 LE"  "$(le32 "$PROBE_NDEPS")" "${HEX:$POS:8}"
POS=$(( POS + 8 ))

# The tail is the dep keys: they must be the keys of exactly this package's
# non-sysimage deps, and they must be in ascending order.
for i in $(seq 0 $(( PROBE_NDEPS - 1 ))); do
  echo "${HEX:$(( POS + i * 64 )):64}"
done > "$WORK/pre_deps.txt"
check "           preimage ends after the dep keys" "$(( POS + PROBE_NDEPS * 64 ))" "${#HEX}"
sort -c "$WORK/pre_deps.txt" 2>/dev/null && ok "           dep keys are in ascending order" \
  || bad "           dep keys are not sorted" "$(cat "$WORK/pre_deps.txt")"
join "$WORK/probedeps.txt" <(sort "$WORK/base.keys") | awk '{print $2}' | sort > "$WORK/pre_deps_expected.txt"
if diff -q <(sort "$WORK/pre_deps.txt") "$WORK/pre_deps_expected.txt" >/dev/null; then
  ok "           dep keys are exactly $PROBE_NAME's non-sysimage deps"
else
  bad "           dep keys are not the deps' own keys" \
      "$(diff <(sort "$WORK/pre_deps.txt") "$WORK/pre_deps_expected.txt" | head -5)"
fi

# --- 6: the length prefixes ---------------------------------------------------
echo
echo "==> 6. length prefixes: two inputs that would collide without them"
# cacheflags = 98 = 'b'. Without the prefixes the preimage between the tree
# hash and prefs_hash is
#   ... tree ++ path ++ 0x62 ++ cpu_target ++ ...
# so ("a", "bc") and ("ab", "c") produce the identical byte string. The only
# thing that separates them is the explicit lengths. `--raw` keys one synthetic
# dependency-free package, so nothing else can move the answer.
collide() { # collide <out> <path> <cpu_target>
  ( cd "$AJT_ROOT" && zig run \
      --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
      --dep ajt -Mroot=tools/diff_harness/cache_key_dump.zig -Majt=src/root.zig \
      -- --sysimage "$SYSIMAGE" --cacheflags 98 --cpu-target "$3" \
         --raw "$SELF_UUID=$SELF_TREE:$2" ) > "$1" 2>"$1.err" \
    || { echo "ERROR: collide dump failed" >&2; tail -5 "$1.err" >&2; exit 2; }
}
collide "$WORK/c1.txt" "a"  "bc"
collide "$WORK/c2.txt" "ab" "c"
K1=$(awk '$1=="raw"{print $2}' "$WORK/c1.txt")
K2=$(awk '$1=="raw"{print $2}' "$WORK/c2.txt")
[ -n "$K1" ] || { echo "ERROR: the raw probe produced no key" >&2; exit 2; }
if [ "$K1" != "$K2" ]; then
  ok "(path=a, cpu=bc) and (path=ab, cpu=c) key differently"
else
  bad "length prefixes are missing: two distinct inputs share a key" "$K1"
fi

# --- 7: prefs_hash is wired into the key and propagates ----------------------
# Without this the `prefs_hash` field is entirely unexercised by the gate:
# section 5 only ever asserts it is zero, so hard-wiring `Walk.prefsHash` to
# return 0 -- ignoring every package's preferences -- passes everything else.
# A preference change must move the same closure a content change moves,
# because Julia rejects a cache file whose prefs_hash differs
# (base/loading.jl:4146-4147) exactly as it rejects a stale dependency.
echo
echo "==> 7. a package's prefs_hash moves it and its dependents"
dump "$WORK/prefs.txt" "$MANIFEST" "$SYSIMAGE" "$CACHEFLAGS" "$CPU_TARGET" \
     --prefs "$TARGET_UUID=1311768467294899695"
grep '^key ' "$WORK/prefs.txt" | awk '{print $2, $4}' | sort > "$WORK/prefs.keys"
check "same package set" "$(wc -l < "$WORK/base.keys")" \
      "$(join "$WORK/base.keys" "$WORK/prefs.keys" | wc -l)"
join "$WORK/base.keys" "$WORK/prefs.keys" | awk '$2 != $3 {print $1}' | sort > "$WORK/prefs.affected"
if diff -q "$WORK/expected_affected.txt" "$WORK/prefs.affected" >/dev/null; then
  ok "a prefs_hash on $TARGET_NAME moves exactly its closure ($(wc -l < "$WORK/prefs.affected") keys)"
else
  bad "a prefs_hash change did not move the same closure a content change does"
  comm -23 "$WORK/expected_affected.txt" "$WORK/prefs.affected" | sed 's/^/       missing: /' | head -5
  comm -13 "$WORK/expected_affected.txt" "$WORK/prefs.affected" | sed 's/^/       extra: /'   | head -5
fi

# --- verdict -----------------------------------------------------------------
echo
echo "  $PASS ok, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  [ $KEEP -eq 0 ] && echo "  (re-run with --keep to inspect $WORK)"
  exit 1
fi
echo
echo "PASS — $KEYED derivation keys over the $ENTRIES-entry Open-Reality manifest:"
echo "       reproducible, unaffected by manifest dep order, moved by the sysimage,"
echo "       by a prefs_hash, and by exactly the $(wc -l < "$WORK/expected_affected.txt") transitive dependents of"
echo "       $TARGET_NAME${UP_NAME:+ (and the $(wc -l < "$WORK/expected_upaffected.txt") of the upgradable stdlib $UP_NAME)},"
echo "       laid out in the documented field order with length-prefixed strings."
