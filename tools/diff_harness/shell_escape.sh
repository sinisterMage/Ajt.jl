#!/usr/bin/env bash
# Differential gate for src/julia/shell.zig against `Base.shell_escape` and
# `Base.shell_escape_wincmd` (base/shell.jl).
#
# These two decide how an app shim quotes the julia path, the module spec and
# every `julia_flags` entry, so a divergence is a shim that runs the wrong
# program — and `Base.shell_escape` is much less obvious than it looks. It has
# FOUR branches, not one:
#
#   ""            -> ''
#   no specials   -> the word verbatim, UNQUOTED   <- the one a naive port misses
#   no apostrophe -> 'word'
#   otherwise     -> "word", with only " and $ backslashed (NOT the backslash)
#
# "Special" is `isspace(c) || c in ('\\', '\'', '"', '$')`, and `isspace` is
# Unicode-aware — 23 code points, including U+00A0 and U+3000, which a
# `c <= ' '` approximation misses and which appear in real directory names.
#
# Both sides are driven with HEX-encoded inputs and compared as HEX output, so
# nothing in this harness quotes, splits or normalises the corpus on the way
# through. The corpus is built to hit every branch, both tools' metacharacters,
# and the wincmd refusals (NUL/CR/LF).
#
# VACUITY: the corpus is asserted to produce at least one result of each of the
# four posix branch shapes before any comparison counts, so a run where the
# dump program emitted nothing useful fails rather than agreeing on nothing.
#
# Usage: tools/diff_harness/shell_escape.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-shellesc-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# ---------------------------------------------------------------------------
# The corpus, as hex. Written by Julia so the non-ASCII entries are exactly the
# code points intended rather than whatever this file's encoding survives.
# ---------------------------------------------------------------------------
cat >"$WORK/corpus.jl" <<'JLEOF'
cases = String[
    "",                                  # branch 1
    "/usr/bin/julia", "Foo", "Foo.CLI",  # branch 2 (verbatim)
    "--threads=4", "--optimize=2", "a&b", "a#b", "a|b", "a;b", "a*b", "a~b",
    "/path with space/julia",            # branch 3
    "a\$b", "a\"b", "a\\b", "a b",
    "it's", "it's \$HOME", "it's \"q\"", "it's a\\b",   # branch 4
    "'", "''", "'\$'",
    # Unicode whitespace: every one Base.isspace accepts, plus a near-miss.
    "a\u00a0b", "a\u1680b", "a\u2000b", "a\u200ab", "a\u202fb", "a\u205fb",
    "a\u3000b", "a\u0085b", "a\u000bb", "a\u000cb",
    "a\u180eb",                          # Cf, NOT a space -> stays unquoted
    "café", "日本語",
    # cmd.exe metacharacters, and the pairing rule for quotes.
    "C:\\jl\\bin\\julia.exe", "C:\\Users\\test user\\julia.exe",
    "(x)", "a!b", "a^b", "a<b>c", "%USERPROFILE%", "%a%b%",
    "@echo", "a@b", "@", "\"paired\"", "\"unpaired", "\"a\"b\"c\"",
    "^!%\"<>&|()",
    # wincmd refusals.
    "a\nb", "a\rb", "a\0b",
]
# The EMPTY string hexes to the empty string, which would be an empty line that
# every reader here skips -- silently dropping branch 1 and shifting the join
# by one. `.` is its explicit spelling on the wire; all three readers decode it.
open(ARGS[1], "w") do io
    for c in cases
        h = bytes2hex(codeunits(c))
        println(io, isempty(h) ? "." : h)
    end
end
JLEOF
julia --startup-file=no "$WORK/corpus.jl" "$WORK/corpus.hex" || {
  echo "ERROR: could not build the corpus" >&2; exit 2; }
N=$(wc -l <"$WORK/corpus.hex")
echo "==> $N cases"

# ---------------------------------------------------------------------------
# Julia's answers.
# ---------------------------------------------------------------------------
cat >"$WORK/oracle.jl" <<'JLEOF'
open(ARGS[2], "w") do out
    for line in eachline(ARGS[1])
        h = strip(line)
        isempty(h) && continue
        s = h == "." ? "" : String(hex2bytes(h))
        p = bytes2hex(codeunits(Base.shell_escape(s)))
        w = try
            bytes2hex(codeunits(Base.shell_escape_wincmd(s)))
        catch
            "-"
        end
        println(out, p, '\t', w)
    end
end
JLEOF
julia --startup-file=no "$WORK/oracle.jl" "$WORK/corpus.hex" "$WORK/julia.out" || {
  echo "ERROR: oracle failed" >&2; exit 2; }

# ---------------------------------------------------------------------------
# ajt's answers.
# ---------------------------------------------------------------------------
# Hermetic zig caches, as every zig-invoking harness here does.
echo "==> running the dump program"
( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/shell_escape_dump.zig -Majt=src/root.zig \
    -- "$WORK/corpus.hex" ) >"$WORK/ajt.out" 2>"$WORK/ajt.err" || {
  echo "ERROR: ajt dump failed" >&2; tail -30 "$WORK/ajt.err" >&2; exit 2; }

# ---------------------------------------------------------------------------
PASS=0
FAIL=0

# Vacuity: the corpus has to have exercised all four posix branches, or a
# comparison of two agreeing-but-empty answers would read as success.
# Classified on the HEX, not on decoded text: the corpus contains a NUL, which
# no shell variable can hold, and `xxd` is not on every host this runs on.
# 2727 is `''`, 27 is a leading apostrophe, 22 a leading double quote.
b1=0; b2=0; b3=0; b4=0
while IFS=$'\t' read -r want_p _; do
  case "$want_p" in
    2727)  b1=1 ;;
    22*)   b4=1 ;;
    27*)   b3=1 ;;
    *)     b2=1 ;;
  esac
done <"$WORK/julia.out"
if [ "$b1$b2$b3$b4" = "1111" ]; then
  echo "  ok   corpus exercises all four shell_escape branches"
  PASS=$((PASS+1))
else
  echo "  FAIL corpus missed a branch (empty=$b1 verbatim=$b2 single=$b3 double=$b4)" >&2
  FAIL=$((FAIL+1))
fi

# And that the wincmd refusal path was reached.
if grep -q $'\t-$' "$WORK/julia.out"; then
  echo "  ok   corpus reaches the wincmd refusal (NUL/CR/LF)"
  PASS=$((PASS+1))
else
  echo "  FAIL corpus never triggered shell_escape_wincmd's ArgumentError" >&2
  FAIL=$((FAIL+1))
fi

# The comparison itself.
#
# Whole-file `cmp`, not a field-by-field `read` loop: `IFS=$'\t'` does NOT give
# strict tab splitting in bash -- a tab is IFS *whitespace*, so runs collapse and
# trailing empty fields vanish. An empty `shell_escape_wincmd` result (which the
# empty input produces) then looks like a missing field on one side only, and the
# loop reports a mismatch that is not there. (It did.)
jl_lines=$(wc -l <"$WORK/julia.out")
aj_lines=$(wc -l <"$WORK/ajt.out")
if [ "$jl_lines" = "$N" ] && [ "$aj_lines" = "$N" ]; then
  echo "  ok   both sides answered all $N cases"
  PASS=$((PASS+1))
else
  echo "  FAIL line counts differ: corpus $N, julia $jl_lines, ajt $aj_lines" >&2
  FAIL=$((FAIL+1))
fi

if cmp -s "$WORK/julia.out" "$WORK/ajt.out"; then
  echo "  ok   every case agrees with Base, both functions"
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL some case disagrees with Base" >&2
  # Reported as hex, which is what was compared, and located by line -- hex is
  # unambiguous about the trailing space and the NUL that decoded text hides.
  paste -d' ' "$WORK/corpus.hex" \
    <(cut -f1 "$WORK/julia.out") <(cut -f2 "$WORK/julia.out") \
    <(cut -f1 "$WORK/ajt.out")   <(cut -f2 "$WORK/ajt.out") \
    | awk '{ if ($2 != $4 || $3 != $5)
               printf("       line %d input=%s  posix julia=%s ajt=%s  wincmd julia=%s ajt=%s\n",
                      NR, $1, $2, $4, $3, $5) }' >&2
fi

echo
echo "  agreements : $PASS"
echo "  failures   : $FAIL"

if [ "$FAIL" -gt 0 ]; then
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — julia/shell.zig agrees with Base across $N inputs"
