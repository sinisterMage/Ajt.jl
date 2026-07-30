#!/usr/bin/env bash
# Differential gate for `git/url.zig` vs `Pkg.isurl` (utils.jl:27-28).
#
# Why this needs a gate. `isurl` is what decides whether an argument names a
# directory on disk or something to clone -- `handle_repo_develop!`
# (Types.jl:778) and `manifest.jl:328` both branch on it. Getting it wrong is
# silent in both directions: too eager and `ajt dev ./local/pkg` tries to clone
# a path, too shy and `ajt dev https://…` writes a `[sources] path` pointing at
# a directory that does not exist. And Pkg's answer is an UNANCHORED regex, so
# the correct behaviour is not the behaviour a careful reimplementation would
# choose -- `/tmp/digit:x` is a URL to Pkg, `github.com:o/r.git` is not.
#
# What is compared:
#   1. isurl, over the whole corpus. Hard failure on any disagreement.
#   2. Invariants that need no oracle, because Pkg has no single function that
#      answers them:
#        - every https/http/git/ssh/file-scheme URL classifies as that scheme;
#        - anything classified as a real scheme is also `isurl` -- EXCEPT when
#          the scheme is not lower-case. `URL_regex` is a case-sensitive
#          literal alternation, so `HTTPS://host/r` is a path to Pkg while
#          `classify`, `git clone` and RFC 3986 3.1 all call it https. That
#          divergence is real and is why a caller deciding "path or repo?" must
#          ask `isurl` and only then ask `classify`; the gate asserts the
#          exception set is EXACTLY the non-lower-case schemes;
#        - `normalize` is idempotent, never lengthens, and only ever removes
#          trailing '/' (GitTools.jl:57 -- "LibGit2 is fussy about trailing
#          slash", and nothing more than that in a stock session);
#        - classify is total and never crashes on the corpus.
#
# The corpus: every `repo` URL in the General registry (~14k real inputs of
# exactly the shape handle_repo_add! is handed), each also in its trailing
# slash, `.git`-stripped and scp-rewritten forms, plus paths and adversarial
# strings that live on the boundary.
#
# Usage: tools/diff_harness/git_url.sh [--keep] [--no-registry]
set -uo pipefail

export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
USE_REGISTRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)        KEEP=1; shift ;;
    --no-registry) USE_REGISTRY=0; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

echo "julia  : $(julia --startup-file=no -e 'print(VERSION)')"

WORK="$(mktemp -d -t ajt-giturl-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- corpus -----------------------------------------------------------------
echo "==> building corpus"
cat > "$WORK/corpus.jl" <<'JL'
using Pkg

# Everything inside a function: at a script's top level `n += 1` inside a `for`
# creates a new local rather than assigning the global, and the resulting
# UndefVarError gets swallowed by the surrounding try. That silently emptied
# the registry section of string_hash.sh before it was caught.
function build(use_registry::Bool, path::String)
    out = open(path, "w")
    emit(s) = println(out, isempty(s) ? "-" : bytes2hex(codeunits(s)))

    # Paths, and the strings that sit on the boundary between path and URL.
    for s in [
        "", ".", "..", "/", "/home/u/pkg", "../pkg", "pkg", "./dev/Foo",
        "/tmp/a b/c", "/tmp/we:rd/pkg", "C:\\src\\pkg", "C:/src/pkg",
        "/tmp/digit:x", "/tmp/digit", "/tmp/digit:", "/tmp/ssh:x", "/tmp/file:x",
        "git", "ssh", "file", "https", "git:", "git:x", "@", "a@b", "a@b:",
        "a@b:c", "-@-:~", "_@_:_", "..@..:..",
        "github.com:JuliaLang/Example.jl.git",
        "git@github.com:JuliaLang/Example.jl.git",
        "ssh://git@github.com/o/r.git",
        "git+ssh://git@github.com/o/r.git",
        "ssh+git://git@github.com/o/r.git",
        "file:///srv/r.git", "git://example.invalid/r",
        "http://example.invalid/r", "https://example.invalid/r",
        "HTTPS://EXAMPLE.INVALID/R",
        "https://u:p@github.com/o/r.git",
        "https://github.com/o/r.git?x=a@b",
    ]
        emit(s)
    end

    # Every repo URL in the registry, in four forms each. `Pkg.isurl` must
    # agree on all of them; the scp rewrite is the one most likely to diverge.
    if use_registry
        try
            for reg in Pkg.Registry.reachable_registries()
                for (_, pkg) in reg.pkgs
                    r = Pkg.Registry.registry_info(pkg).repo
                    r === nothing && continue
                    emit(r)
                    emit(r * "/")
                    emit(endswith(r, ".git") ? r[1:(end - 4)] : r * ".git")
                    emit(replace(r, "https://" => "git@", count = 1))
                end
            end
        catch e
            println(stderr, "note: registry corpus unavailable ($e)")
        end
    end
    close(out)
end

build(ARGS[1] == "1", ARGS[2])
JL

julia --startup-file=no "$WORK/corpus.jl" "$USE_REGISTRY" "$WORK/corpus.hex" \
      2>"$WORK/corpus.err" || {
  echo "ERROR: corpus generation failed" >&2; tail -20 "$WORK/corpus.err" >&2; exit 2; }
# Counted from the file, never from a counter maintained beside the emit calls:
# the hand-kept one said 40 for a 42-entry list and nothing noticed.
N=$(wc -l < "$WORK/corpus.hex")
[ -s "$WORK/corpus.err" ] && sed 's/^/  /' "$WORK/corpus.err"
echo "corpus : $N entries"
[ "$N" -ge 40 ] || { echo "ERROR: corpus too small to be meaningful" >&2; exit 2; }

# --- oracle -----------------------------------------------------------------
echo "==> Julia oracle"
cat > "$WORK/oracle.jl" <<'JL'
using Pkg
for line in eachline(ARGS[1])
    isempty(line) && continue
    s = line == "-" ? "" : String(hex2bytes(line))
    println(line, " ", Pkg.isurl(s) ? 1 : 0)
end
JL
julia --startup-file=no "$WORK/oracle.jl" "$WORK/corpus.hex" \
  > "$WORK/julia.txt" 2>"$WORK/julia.err" || {
  echo "ERROR: oracle failed" >&2; tail -20 "$WORK/julia.err" >&2; exit 2; }

# --- ajt --------------------------------------------------------------------
# Per-run cache dirs: see the audit note in stdlibs.sh.
echo "==> ajt"
( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/git_url_dump.zig -Majt=src/root.zig \
    -- "$WORK/corpus.hex" ) > "$WORK/ajt_all.txt" 2>"$WORK/ajt.err" || {
  echo "ERROR: ajt dump failed" >&2; tail -20 "$WORK/ajt.err" >&2; exit 2; }

awk '{print $1, $2}' "$WORK/ajt_all.txt" > "$WORK/ajt.txt"

status=0

# --- 1: isurl ---------------------------------------------------------------
echo "==> comparing isurl"
JN=$(wc -l < "$WORK/julia.txt")
AN=$(wc -l < "$WORK/ajt.txt")
[ "$JN" -eq "$AN" ] || { echo "FAIL: record count mismatch ($JN vs $AN)" >&2; status=1; }

if ! diff -q "$WORK/julia.txt" "$WORK/ajt.txt" >/dev/null; then
  status=1
  echo >&2
  echo "FAIL: isurl disagrees (< julia, > ajt); first 20 lines of diff:" >&2
  diff "$WORK/julia.txt" "$WORK/ajt.txt" | head -20 >&2
  echo >&2
  echo "  decoded, first 10 disagreements:" >&2
  join "$WORK/julia.txt" "$WORK/ajt.txt" 2>/dev/null \
    | awk '$2 != $3 {print $1, "julia=" $2, "ajt=" $3}' | head -10 \
    | while read -r hex rest; do
        if [ "$hex" = "-" ]; then dec='""'; else dec=$(printf '%s' "$hex" | sed 's/../\\x&/g' | xargs -0 printf '%b'); fi
        echo "    $rest  <- $dec" >&2
      done
else
  echo "  $JN verdicts identical to Pkg.isurl"
fi

# --- 2: invariants with no oracle -------------------------------------------
echo "==> checking classify/normalize invariants"

# Every scheme prefix must classify as its scheme, and must be a URL.
awk '
function decode(h,   i, s, c) {
  if (h == "-") return ""
  s = ""
  for (i = 1; i <= length(h); i += 2) {
    c = strtonum("0x" substr(h, i, 2))
    s = s sprintf("%c", c)
  }
  return s
}
{
  raw = decode($1); isurl = $2; kind = $3
  lower = tolower(raw)
  want = ""
  if (index(lower, "https://") == 1)          want = "https"
  else if (index(lower, "http://") == 1)      want = "http"
  else if (index(lower, "git://") == 1)       want = "git_proto"
  else if (index(lower, "file://") == 1)      want = "file"
  else if (index(lower, "ssh://") == 1)       want = "ssh"
  else if (index(lower, "git+ssh://") == 1)   want = "ssh"
  else if (index(lower, "ssh+git://") == 1)   want = "ssh"
  if (want != "" && kind != want) {
    printf "FAIL: %s classified %s, expected %s\n", raw, kind, want
    bad++
  }
  # A real scheme URL must also satisfy Pkg.isurl -- unless the scheme is not
  # lower-case, because URL_regex is case-sensitive. The converse is NOT
  # asserted at all: Pkg matches scheme words buried in paths, which classify
  # correctly reports as local_path.
  if (want != "" && isurl != 1) {
    scheme_end = index(raw, "://") + 2
    if (substr(raw, 1, scheme_end) == substr(lower, 1, scheme_end)) {
      printf "FAIL: %s classified %s (lower-case scheme) but Pkg.isurl says no\n", raw, kind
      bad++
    } else {
      casediff++
    }
  }
}
END {
  printf "  %d case-only divergences from Pkg.isurl (expected: upper-case schemes)\n", casediff
  if (bad) exit 1
}
' "$WORK/ajt_all.txt" >&2 || status=1

# normalize: idempotent, never longer, differs only by trailing '/'.
awk '
{
  src = $1; norm = $4
  if (src == "-") src = ""
  if (norm == "-") norm = ""
  if (length(norm) > length(src)) { printf "FAIL: normalize lengthened %s\n", src; bad++; next }
  if (substr(src, 1, length(norm)) != norm) { printf "FAIL: normalize is not a prefix trim of %s\n", src; bad++; next }
  # Everything trimmed must have been an ASCII "/" (hex 2f).
  tail = substr(src, length(norm) + 1)
  if (tail != "" && tail !~ /^(2f)+$/) { printf "FAIL: normalize trimmed non-slash from %s\n", src; bad++ }
}
END { if (bad) exit 1 }
' "$WORK/ajt_all.txt" >&2 || status=1

# Idempotence, checked by feeding the normalized column back through.
awk '{print ($4 == "-" ? "-" : $4)}' "$WORK/ajt_all.txt" | sort -u > "$WORK/norm.hex"
( cd "$AJT_ROOT" && zig run \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
    --dep ajt -Mroot=tools/diff_harness/git_url_dump.zig -Majt=src/root.zig \
    -- "$WORK/norm.hex" ) 2>>"$WORK/ajt.err" \
  | awk '$1 != $4 {print "FAIL: normalize is not idempotent for " $1; bad++} END {if (bad) exit 1}' >&2 \
  || status=1
echo "  invariants hold over $AN entries"

# --- 3: the gate must be capable of failing ---------------------------------
# Two landmarks that encode the quirks. If either is missing, the corpus is
# broken and a pass would mean nothing.
# `xxd` is not installed on every host this runs on (it is not in NixOS's
# coreutils/vim-less base), and its absence made every landmark report
# "<absent>" -- i.e. the failure-capability check itself failed open-ish, in
# that it reported a failure for the wrong reason. `od` is POSIX.
hexof() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }

check_landmark() {  # <string> <expected isurl>
  local hex; hex=$(hexof "$1")
  local got; got=$(awk -v h="$hex" '$1 == h {print $2; exit}' "$WORK/julia.txt")
  if [ "$got" != "$2" ]; then
    echo "FAIL: landmark '$1' expected Pkg.isurl=$2, oracle said '${got:-<absent>}'" >&2
    echo "      the corpus or the oracle is broken, and a pass would mean nothing" >&2
    status=1
  fi
}
check_landmark '/tmp/digit:x' 1                          # unanchored: `git` inside `digit`
check_landmark 'github.com:JuliaLang/Example.jl.git' 0   # scp-like, but no user@ and no scheme
check_landmark '/home/u/pkg' 0
check_landmark 'https://github.com/JuliaLang/Example.jl.git' 1

echo
if [ "$status" -ne 0 ]; then
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi
echo "PASS — $JN strings classified identically to Pkg.isurl, and classify/"
echo "       normalize hold their invariants over the same corpus"
