#!/usr/bin/env bash
# Differential gate for `julia/string_hash.zig` vs `Base.hash(::String, ::UInt)`.
#
# Why this needs a gate at all. `Pkg.Types.add_repo_cache_path(url)` names a git
# clone `<depot>/clones/string(hash(url))` (Types.jl:901), and `Pkg.gc()`
# recomputes that name for every live manifest `repo.source` and **orphans every
# other directory under clones/** (API.jl:772-791, :985-994). So a wrong hash
# does not fail: it makes Ajt write clones Pkg will silently delete, and makes
# Ajt re-clone what Pkg already has. Neither shows up as an error anywhere.
#
# What is compared, over one corpus:
#   1. hash(s, 0), hash(s, 1) and hash(s, typemax(UInt)) for every entry.
#      Three seeds because the seed is used twice -- added into `h`, and
#      truncated to UInt32 as Murmur's own seed -- and only `h = 0` is ever
#      exercised in production, so a truncation bug would hide behind it.
#   2. `string(hash(url))` vs the basename of `Pkg.Types.add_repo_cache_path`,
#      for the URL-shaped part of the corpus. This is the claim that actually
#      matters, asserted rather than inferred from (1).
#
# The corpus, in order:
#   * every length 0..300 of a deterministic byte filler -- this walks the whole
#     16-way `switch` fallthrough in the Murmur tail and both block boundaries;
#   * bytes a text format cannot carry: NUL, newline, and invalid UTF-8
#     (0x80, 0xff, a truncated multi-byte sequence). Julia's String holds
#     arbitrary bytes and hash runs over sizeof(s), so these are in scope;
#   * every `repo` URL in the General registry, if one is installed -- ~14k real
#     inputs of exactly the shape add_repo_cache_path is handed;
#   * every package name in the General registry.
#
# Both sides read the SAME hex-encoded corpus file, so the comparison cannot be
# fooled by two different notions of what the input was.
#
# Usage: tools/diff_harness/string_hash.sh [--keep] [--no-registry]
set -uo pipefail

export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
USE_REGISTRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)         KEEP=1; shift ;;
    --no-registry)  USE_REGISTRY=0; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

JULIA_VERSION=$(julia --startup-file=no -e 'print(VERSION)')
echo "julia  : $JULIA_VERSION"

WORK="$(mktemp -d -t ajt-strhash-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- corpus -----------------------------------------------------------------
# Written by Julia so that the "URLs from the registry" section can be produced
# at all; the synthetic section is deterministic and independent of Julia.
echo "==> building corpus"
cat > "$WORK/corpus.jl" <<'JL'
using Pkg

# Everything runs inside a function: at a script's top level, `n += 1` inside a
# `for` creates a NEW LOCAL rather than assigning the global (Julia's soft-scope
# rule), which silently zeroed the counters and made the registry section throw
# an UndefVarError that the surrounding `try` swallowed as "registry corpus
# unavailable". The gate reported 0 URLs and still passed its other checks.
function build(use_registry::Bool, corpus_path::String, urls_path::String)
    out = open(corpus_path, "w")
    urls = open(urls_path, "w")
    # Hex cannot encode the empty string -- an empty line is a blank line, and
    # both sides skip blanks. `-` is the sentinel for it; see string_hash_dump.zig.
    emit(bytes) = println(out, isempty(bytes) ? "-" : bytes2hex(bytes))

    # 1. every length 0..300 of a deterministic filler. This walks the whole
    #    16-way Murmur tail switch and both block boundaries.
    for n in 0:300
        emit(UInt8[UInt8(32 + (i * 7) % 95) for i in 1:n])
    end

    # 2. bytes no text format survives.
    emit(UInt8[0x00])
    emit(UInt8[0x61, 0x00, 0x62])
    emit(UInt8[0x0a])
    emit(UInt8[0x61, 0x0a, 0x62, 0x0d, 0x0a])
    emit(UInt8[0x80])
    emit(UInt8[0xff, 0xfe])
    emit(UInt8[0xc3])            # truncated 2-byte sequence
    emit(UInt8[0xe4, 0xbd])      # truncated 3-byte sequence
    emit(UInt8[0xf0, 0x9f, 0x92, 0xa9])

    # 3/4. the General registry: every repo URL and every package name.
    nurl = 0
    nname = 0
    if use_registry
        try
            for reg in Pkg.Registry.reachable_registries()
                for (_, pkg) in reg.pkgs
                    emit(codeunits(pkg.name))
                    nname += 1
                    r = Pkg.Registry.registry_info(pkg).repo
                    if r !== nothing
                        emit(codeunits(r))
                        println(urls, bytes2hex(codeunits(r)))
                        nurl += 1
                    end
                end
            end
        catch e
            println(stderr, "note: registry corpus unavailable ($e)")
        end
    end
    close(out)
    close(urls)
    println("synthetic 310 names $nname urls $nurl")
end

build(ARGS[1] == "1", ARGS[2], ARGS[3])
JL

CORPUS_SUMMARY=$(julia --startup-file=no "$WORK/corpus.jl" "$USE_REGISTRY" \
  "$WORK/corpus.hex" "$WORK/urls.hex" 2>"$WORK/corpus.err") || {
  echo "ERROR: corpus generation failed" >&2; tail -20 "$WORK/corpus.err" >&2; exit 2; }
[ -s "$WORK/corpus.err" ] && sed 's/^/  /' "$WORK/corpus.err"

N=$(wc -l < "$WORK/corpus.hex")
echo "corpus : $N entries ($CORPUS_SUMMARY)"
[ "$N" -ge 310 ] || { echo "ERROR: corpus is too small to be meaningful" >&2; exit 2; }

# --- oracle -----------------------------------------------------------------
echo "==> Julia oracle"
cat > "$WORK/oracle.jl" <<'JL'
for line in eachline(ARGS[1])
    isempty(line) && continue
    s = line == "-" ? "" : String(hex2bytes(line))
    println(line, " ", hash(s), " ", hash(s, UInt(1)), " ",
            hash(s, typemax(UInt)), " ", string(hash(s)))
end
JL
julia --startup-file=no "$WORK/oracle.jl" "$WORK/corpus.hex" \
  > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -20 "$WORK/julia.err" >&2; exit 2; }

# --- ajt --------------------------------------------------------------------
# Per-run cache dirs: see the audit note in stdlibs.sh. Every zig-invoking
# harness here is hermetic for the same reason.
echo "==> ajt"
( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/string_hash_dump.zig -Majt=src/root.zig \
    -- "$WORK/corpus.hex" ) > "$WORK/ajt.txt" 2>"$WORK/ajt.err" || {
  echo "ERROR: ajt dump failed" >&2; tail -20 "$WORK/ajt.err" >&2; exit 2; }

status=0

# --- 1: the hashes themselves ------------------------------------------------
echo "==> comparing hashes"
JN=$(wc -l < "$WORK/julia.txt")
AN=$(wc -l < "$WORK/ajt.txt")
if [ "$JN" -ne "$AN" ]; then
  echo "FAIL: record count mismatch (julia $JN, ajt $AN)" >&2
  status=1
fi

if ! diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  status=1
  DIFFS=$(diff "$WORK/julia.txt" "$WORK/ajt.txt" | grep -c '^<')
  echo >&2
  echo "FAIL: $DIFFS records differ (< julia, > ajt); first 10:" >&2
  diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -20 >&2
  # Which seed broke narrows a hand port down immediately: a wrong Murmur word
  # or a wrong tail breaks all three columns, whereas a wrong `h % UInt32`
  # truncation leaves column 2 (seed 0) intact and breaks 3 and 4.
  for col in 2 3 4; do
    cut -d' ' -f1,$col "$WORK/julia.txt" > "$WORK/j.col"
    cut -d' ' -f1,$col "$WORK/ajt.txt"   > "$WORK/a.col"
    c=$(diff "$WORK/j.col" "$WORK/a.col" | grep -c '^<')
    case $col in
      2) label="seed 0" ;;
      3) label="seed 1" ;;
      4) label="seed typemax(UInt)" ;;
    esac
    echo "  column $col ($label): $c mismatches" >&2
  done
else
  echo "  $JN records identical across all three seeds"
fi

# --- 2: the clone directory name Pkg will actually look for ------------------
echo "==> comparing against Pkg.Types.add_repo_cache_path"
# Always includes a handful of fixed URLs so this section is meaningful even
# with --no-registry or on a machine with no registry installed.
cat >> "$WORK/urls.hex" <<'EOF'
68747470733a2f2f6769746875622e636f6d2f4a756c69614c616e672f4578616d706c652e6a6c2e676974
68747470733a2f2f6769746875622e636f6d2f4a756c69614c616e672f4578616d706c652e6a6c
68747470733a2f2f6769746875622e636f6d2f4d616b69654f72672f4d616b69652e6a6c2e676974
676974406769746875622e636f6d3a4a756c69614c616e672f4578616d706c652e6a6c2e676974
EOF

cat > "$WORK/clones.jl" <<'JL'
using Pkg
for line in eachline(ARGS[1])
    isempty(line) && continue
    url = line == "-" ? "" : String(hex2bytes(line))
    println(line, " ", basename(Pkg.Types.add_repo_cache_path(url)))
end
JL
julia --startup-file=no "$WORK/clones.jl" "$WORK/urls.hex" \
  > "$WORK/julia_clones.txt" 2>"$WORK/clones.err" || {
  echo "ERROR: add_repo_cache_path oracle failed" >&2; tail -20 "$WORK/clones.err" >&2; exit 2; }

( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/string_hash_dump.zig -Majt=src/root.zig \
    -- "$WORK/urls.hex" ) 2>>"$WORK/ajt.err" \
  | awk '{print $1, $5}' > "$WORK/ajt_clones.txt" || {
  echo "ERROR: ajt clone-name dump failed" >&2; tail -20 "$WORK/ajt.err" >&2; exit 2; }

UN=$(wc -l < "$WORK/julia_clones.txt")
if ! diff -q "$WORK/julia_clones.txt" "$WORK/ajt_clones.txt" >/dev/null; then
  status=1
  echo "FAIL: clone directory names differ; first 10:" >&2
  diff "$WORK/julia_clones.txt" "$WORK/ajt_clones.txt" | head -20 >&2
else
  echo "  $UN clone directory names identical to add_repo_cache_path"
fi

# --- 3: the gate must be capable of failing ---------------------------------
# A diff of two empty files passes, and so does one where both sides silently
# produced nothing for an input the corpus never carried. That is not
# hypothetical: the empty string WAS missing here until this check caught it,
# because hex encodes it as a blank line and both sides skip blanks.
for landmark in \
  '^- 13633231208144796923 14947065367464324388 9376320745370213716 ' \
  '^68747470733a2f2f6769746875622e636f6d2f4a756c69614c616e672f4578616d706c652e6a6c2e676974 4643033083726148914 '
do
  for side in julia ajt; do
    if ! grep -q "$landmark" "$WORK/$side.txt"; then
      echo "FAIL: landmark absent from $side output: $landmark" >&2
      echo "      the corpus or that side is broken, and a pass would mean nothing" >&2
      status=1
    fi
  done
done

echo
if [ "$status" -ne 0 ]; then
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi
echo "PASS — $JN strings hash identically to Base.hash(::String, ::UInt) under"
echo "       three seeds, and $UN URLs name the same <depot>/clones/ directory"
echo "       Pkg.Types.add_repo_cache_path does"
