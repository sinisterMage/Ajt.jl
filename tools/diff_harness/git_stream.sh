#!/usr/bin/env bash
# Differential gate for the libgit2 backend and its registered TLS stream.
#
# This is the go/no-go for the whole libgit2 track. libgit2 is built with
# GIT_HTTPS unset and no TLS backend at all (build.zig); HTTPS is supplied from
# the Zig side through a `git_stream` registered at init (src/git/tls.zig). That
# design has one catastrophic failure mode and it is not a crash: the stream
# advertises `encrypted = 1`, which is what tells libgit2 it may send
# credentials over it, and a stream that says so while verifying nothing works
# perfectly against every honest server. So a positive test alone would pass on
# a completely insecure build.
#
# What is compared:
#   1. `ajt git ls-remote <url>` vs `git ls-remote <url>`, sorted, on a real
#      public repository. Every ref and every oid must match. This exercises
#      DNS, TCP, TLS 1.2/1.3, HTTP/1.1, and smart-protocol v2 ref advertisement
#      through the registered stream -- if any of it were broken there would be
#      no output at all.
#   2. THE SECURITY GATE. The three badssl.com hosts (expired, wrong-host,
#      self-signed) must FAIL, and fail with a TLS/certificate error rather
#      than a timeout or a 404. This is the check that distinguishes "we verify
#      certificates" from "we claim to".
#   3. `ajt git fetch <url> <dir>` then `git -C <dir> fsck` clean, and the
#      commit ajt resolves equal to the one `git ls-remote` advertises. Proves
#      packfile receive, delta resolution and pack index construction -- fsck
#      walks every object it wrote.
#   4. `ajt git hash-object` vs `git hash-object --no-filters` over a real
#      corpus. This is the ONLY check that catches a mis-built sha1dc: the
#      vendored SHA-1 takes its integer types and byte order from two
#      `SHA1DC_CUSTOM_INCLUDE_*` macros set on the command line, and getting
#      them wrong still compiles, still returns twenty bytes, and is not
#      SHA-1. Ajt's own tree hashing uses native Zig SHA-1 and would never
#      notice; a package manager that fabricates `git-tree-sha1` values is the
#      worst failure mode available.
#   5. THE BACKEND-PARITY GATE. One corpus, materialised twice — once with
#      AJT_GIT_BACKEND=cli, once with AJT_GIT_BACKEND=lib — and required to
#      produce the same tree hash, the same set of paths, the same permission
#      bits, the same symlink targets and the same bytes. `materialise` is the
#      one operation the two backends implement completely differently (`git
#      archive` plus a tar reader against a libgit2 tree walk), and it is the
#      one whose output a depot is then NAMED by, so "the choice of backend is
#      a configuration" has to be a measured claim rather than an intention.
#
#      The corpus is built to contain every way the two could have diverged:
#      `.gitattributes` carrying `eol=crlf`, `export-ignore` and
#      `export-subst`, a file whose blob is already CRLF, an executable, an
#      empty blob, a symlink inside the tree and one pointing out of it, and
#      two levels of nesting. Then the same comparison over a real repository.
#
# Needs the network. Checks 1-5 need a `-Dgit` build:
#   zig build -Dgit
# Without one, they are SKIPPED with a stated reason (loudly, and noted in the
# summary) rather than passing or aborting.
#
# Usage: tools/diff_harness/git_stream.sh [--limit N] [--keep] [--static]
set -uo pipefail

export LC_ALL=C
# No terminal prompts from either side: a gate that blocks on a credential
# prompt is a gate that hangs CI.
export GIT_TERMINAL_PROMPT=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
AJT_BIN="$AJT_ROOT/zig-out/bin/ajt"

# A small, stable, genuinely public repository: the one Pkg's own test suite
# uses. Small enough that the fetch in check 3 is seconds, old enough that its
# history is packed with deltas rather than loose objects.
REMOTE="${AJT_GIT_STREAM_REMOTE:-https://github.com/JuliaLang/Example.jl}"

DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT_ENV%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"

LIMIT=2000
KEEP=0
STATIC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit)  LIMIT="$2"; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    --static) STATIC=1; shift ;;
    -h|--help) sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null || { echo "ERROR: git not on PATH" >&2; exit 2; }
[ -x "$AJT_BIN" ] || { echo "ERROR: $AJT_BIN missing -- run 'zig build -Dgit' first" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-gitstream-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

echo "git    : $(git --version)"
echo "remote : $REMOTE"

# ---------------------------------------------------------------------------
# Check 5, hoisted so the no-libgit2 path below can run its `cli` half and then
# stop. Everything it needs is defined here.
# ---------------------------------------------------------------------------

# A deterministic identity for every fixture commit, and no signing: a developer
# with global commit.gpgsign would otherwise block on a passphrase prompt.
git_fixture() { # git_fixture <dir> <args...>
  local d="$1"; shift
  env -i PATH="$PATH" HOME="$WORK" \
      GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
      GIT_AUTHOR_NAME=ajt GIT_AUTHOR_EMAIL=ajt@example.invalid \
      GIT_COMMITTER_NAME=ajt GIT_COMMITTER_EMAIL=ajt@example.invalid \
      GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000" \
      GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000" \
      git -C "$d" "$@"
}

# Every path under a directory with the three things a tree hash is made of:
# kind, the permission bits, and a symlink's target. Sorted, so it is a file two
# backends can be diffed on.
#
# Not `ajt`'s tree hash, and not `diff -r`: the hash prunes empty directories
# and ignores every permission bit but `0o100`, and `diff -r` follows symlinks
# on the diffutils versions that lack `--no-dereference`. What has to match is
# the DIRECTORY, because that is what a caller is handed.
tree_manifest() { # tree_manifest <dir>
  ( cd "$1" && find . -mindepth 1 \
      \( -type d -printf 'd %m %p\n' \
      -o -type l -printf 'l %l %p\n' \
      -o -type f -printf 'f %m %s %p\n' \) | sort )
}
tree_contents() { # tree_contents <dir>
  ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha1sum )
}

# One corpus, materialised by one backend. Each backend does its OWN clone
# first, deliberately: `cli.zig`'s materialise depends on the
# `$GIT_DIR/info/attributes` file that only its own `ensureClone` writes, so
# materialising with `cli` out of a clone libgit2 created would honour
# `.gitattributes` and diverge for a reason that has nothing to do with the
# tree walk. Production always pairs them; so does this.
materialise_with() { # materialise_with <backend> <label> <url> <rev>
  local be="$1" label="$2" url="$3" rev="$4"
  local dir="$WORK/mat/$label/$be"
  mkdir -p "$dir"
  if ! AJT_GIT_BACKEND="$be" "$AJT_BIN" git fetch "$url" "$dir/clone" "$rev" \
        >"$dir/fetch.out" 2>"$dir/fetch.err"; then
    echo "FAIL: [$label/$be] ajt git fetch failed:" >&2
    sed 's/^/    /' "$dir/fetch.err" | head -5 >&2
    return 1
  fi
  local commit tree
  commit="$(awk '{print $1}' "$dir/fetch.out")"
  # The tree id comes from `git`, not from either backend: a differential gate
  # may not take the number it is checking from the thing it is checking.
  tree="$(git -C "$dir/clone" rev-parse "$commit^{tree}" 2>/dev/null)"
  if [ "${#tree}" -ne 40 ]; then
    echo "FAIL: [$label/$be] git could not name the tree of $commit" >&2
    return 1
  fi
  if ! AJT_GIT_BACKEND="$be" "$AJT_BIN" git materialise "$dir/clone" "$tree" "$dir/out" \
        >"$dir/mat.out" 2>"$dir/mat.err"; then
    echo "FAIL: [$label/$be] ajt git materialise failed:" >&2
    sed 's/^/    /' "$dir/mat.err" | head -5 >&2
    return 1
  fi
  # `materialise` prints the hash of what LANDED, recomputed by walking the
  # destination. Equal to the tree git named, or the postcondition in
  # src/git/git.zig's header is broken on this backend.
  local got
  got="$(awk '{print $1}' "$dir/mat.out")"
  if [ "$got" != "$tree" ]; then
    echo "FAIL: [$label/$be] materialised tree hashes to $got, not $tree" >&2
    return 1
  fi
  echo "$tree" > "$dir/tree"
  tree_manifest "$dir/out" > "$dir/manifest"
  tree_contents "$dir/out" > "$dir/contents"
  return 0
}

# The comparison: same tree, same paths and modes, same bytes.
compare_backends() { # compare_backends <label>
  local label="$1"
  local a="$WORK/mat/$label/cli" b="$WORK/mat/$label/lib"
  local n
  n="$(wc -l < "$a/manifest")"
  # Landmark: an empty-vs-empty diff passes. Nothing below is believed until
  # the corpus is known to be a corpus.
  if [ "$n" -lt 5 ]; then
    echo "FAIL: [$label] the materialised tree has only $n entries -- not a corpus" >&2
    return 1
  fi
  if [ "$(cat "$a/tree")" != "$(cat "$b/tree")" ]; then
    echo "FAIL: [$label] the two backends cloned different trees:" \
         "$(cat "$a/tree") vs $(cat "$b/tree")" >&2
    return 1
  fi
  if ! diff -q "$a/manifest" "$b/manifest" >/dev/null; then
    echo "FAIL: [$label] the two backends wrote different paths or modes (< cli, > lib):" >&2
    diff "$a/manifest" "$b/manifest" | head -20 >&2
    return 1
  fi
  if ! diff -q "$a/contents" "$b/contents" >/dev/null; then
    echo "FAIL: [$label] the two backends wrote different bytes (< cli, > lib):" >&2
    diff "$a/contents" "$b/contents" | head -20 >&2
    return 1
  fi
  echo "  ok — [$label] $n entries identical: paths, modes, symlink targets, bytes"
  return 0
}

materialise_gate() {
  echo
  echo "==> 5. materialise: the cli and libgit2 backends land the same tree"

  # GNU `find -printf`. Stated rather than assumed: without it the manifest
  # would be empty on both sides and the comparison would pass vacuously.
  if ! find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
    echo "  SKIPPED — this \`find\` has no -printf, so the mode/symlink manifest"
    echo "            cannot be built. GNU findutils is needed for this check."
    skipped=1
    return
  fi

  # --- the crafted corpus: every way the two backends could have diverged ---
  local FIX="$WORK/matfix"
  mkdir -p "$FIX/sub/deeper"
  printf 'hello\n'              > "$FIX/README.md"
  printf '#!/bin/sh\necho hi\n' > "$FIX/run.sh"; chmod +x "$FIX/run.sh"
  printf 'module Inner end\n'   > "$FIX/sub/inner.jl"
  printf 'deep\n'               > "$FIX/sub/deeper/deep.txt"
  : > "$FIX/empty"                       # the zero-length blob
  printf 'a\r\nb\r\n'           > "$FIX/crlf.bin"   # already CRLF; must not be "fixed"
  printf 'eol.txt text eol=crlf\nignored.txt export-ignore\nsubst.txt export-subst\n' \
                                > "$FIX/.gitattributes"
  printf 'one\ntwo\n'           > "$FIX/eol.txt"
  printf 'still here\n'         > "$FIX/ignored.txt"
  printf 'v=$Format:%%H$\n'     > "$FIX/subst.txt"
  ln -s README.md    "$FIX/link.md"
  ln -s ../outside/x "$FIX/escape.md"    # a target that leaves the tree
  git_fixture "$FIX" init --quiet --initial-branch=main >/dev/null 2>&1
  git_fixture "$FIX" add -A >/dev/null 2>&1
  git_fixture "$FIX" commit --quiet -m initial >/dev/null 2>&1

  local ran_cli=1
  materialise_with cli fixture "file://$FIX" main || { status=1; ran_cli=0; }

  # The corpus is only a corpus if it really carries the awkward cases; assert
  # that against the `cli` side before either backend is believed.
  if [ $ran_cli -eq 1 ]; then
    local m="$WORK/mat/fixture/cli/manifest"
    local missing=""
    grep -q '^f 755 .* \./run\.sh$'          "$m" || missing="$missing executable"
    grep -q '^l README\.md \./link\.md$'      "$m" || missing="$missing symlink"
    grep -q '^l \.\./outside/x \./escape\.md$' "$m" || missing="$missing escaping-symlink"
    grep -q '^d .* \./sub/deeper$'            "$m" || missing="$missing nested-dir"
    grep -q '^f 644 0 \./empty$'              "$m" || missing="$missing empty-blob"
    grep -q ' \./ignored\.txt$'               "$m" || missing="$missing export-ignore-file"
    if [ -n "$missing" ]; then
      echo "FAIL: the fixture lost:$missing -- the corpus is not what this check assumes" >&2
      status=1
    else
      echo "  ok — the fixture carries the executable, both symlinks, the nesting,"
      echo "       the empty blob and the export-ignore'd file"
    fi
    # The three attribute traps, by their bytes, so a failure names the cause
    # instead of only saying "the trees differ".
    local out="$WORK/mat/fixture/cli/out"
    [ "$(cat "$out/eol.txt")" = "$(printf 'one\ntwo\n')" ] || {
      echo "FAIL: eol=crlf was applied -- eol.txt is not the blob's own bytes" >&2; status=1; }
    [ "$(cat "$out/subst.txt")" = 'v=$Format:%H$' ] || {
      echo "FAIL: export-subst was applied -- subst.txt was expanded" >&2; status=1; }
    [ "$(cat "$out/ignored.txt")" = "still here" ] || {
      echo "FAIL: ignored.txt is not the blob's own bytes" >&2; status=1; }
  fi

  if [ $have_libgit2 -eq 0 ]; then
    echo "  SKIPPED the comparison — no libgit2 in this binary, so only the cli"
    echo "          side ran. Rebuild with \`zig build -Dgit\` to compare."
    skipped=1
    return
  fi

  local ran_lib=1
  materialise_with lib fixture "file://$FIX" main || { status=1; ran_lib=0; }
  if [ $ran_cli -eq 1 ] && [ $ran_lib -eq 1 ]; then
    compare_backends fixture || status=1
  fi

  # --- and the same over a real repository ---------------------------------
  # Real package sources, several hundred files, deltas and all: the crafted
  # fixture proves the awkward cases, this proves the ordinary ones at scale.
  # `BRANCH` is check 3's, when it ran; derived here otherwise so this function
  # stands on its own.
  local branch="${BRANCH:-}"
  if [ -z "$branch" ]; then
    branch="$(git ls-remote --symref "$REMOTE" HEAD 2>/dev/null \
              | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
    branch="${branch:-master}"
  fi
  local ok_both=1
  materialise_with cli remote "$REMOTE" "$branch" || { status=1; ok_both=0; }
  materialise_with lib remote "$REMOTE" "$branch" || { status=1; ok_both=0; }
  [ $ok_both -eq 1 ] && { compare_backends remote || status=1; }
  return 0
}

status=0
# Set to 1 by anything that was not run. A skip is reported loudly, noted in the
# summary, and never mistaken for a pass.
skipped=0

# --- 0: is this even a -Dgit build? -----------------------------------------
# The landmark for every check below. `e69de29b…` is the SHA-1 of the empty
# blob, a value every git user has seen; producing it proves the binary has
# libgit2 in it AND that sha1dc computes SHA-1 rather than something else.
#
# A binary without libgit2 is not a failure of the code this gates, so it is a
# SKIP rather than an error — but a stated one. Check 5 still runs its `cli`
# half, because the corpus and the comparison it builds are worth exercising on
# any build; what it cannot do is compare.
echo "==> 0. the binary has libgit2, and its SHA-1 is SHA-1"
have_libgit2=1
: > "$WORK/empty"
if ! empty_hash="$("$AJT_BIN" git hash-object "$WORK/empty" 2>"$WORK/probe.err")"; then
  have_libgit2=0
  skipped=1
  echo "######################################################################"
  echo "# SKIPPED checks 1-4 and half of 5: this binary has NO libgit2 in it. #"
  echo "# \`ajt git hash-object\` could not run, which is what a build without  #"
  echo "# -Dgit does. Rebuild with \`zig build -Dgit\` for the full gate.       #"
  echo "######################################################################"
  sed 's/^/    /' "$WORK/probe.err"
elif [ "$empty_hash" != "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" ]; then
  echo "FAIL: empty blob hashed to $empty_hash, not e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" >&2
  exit 1
else
  echo "  ok — libgit2 present, empty blob hashes correctly"
fi

if [ $have_libgit2 -eq 0 ]; then
  materialise_gate
  echo
  echo "INCOMPLETE — the libgit2 half of this gate did not run; see the banner above"
  # Exit 2, the code this script has always used for "the environment is not
  # what this gate needs". A skip is stated and clean, and it is still not a
  # pass: a CI job that treats 0 as green must not go green on a build with no
  # libgit2 in it.
  [ $status -eq 0 ] && exit 2
  exit $status
fi

# --- 1: ls-remote -----------------------------------------------------------
# Peeled `refs/tags/x^{}` lines are dropped from both sides: `git ls-remote`
# prints them as separate rows, libgit2 folds them into `git_remote_head.loid`.
# Every real ref and its oid still has to match exactly.
echo "==> 1. ls-remote through the registered TLS stream"
if ! "$AJT_BIN" git ls-remote "$REMOTE" >"$WORK/ajt.ls" 2>"$WORK/ajt.ls.err"; then
  echo "FAIL: ajt git ls-remote failed:" >&2
  sed 's/^/    /' "$WORK/ajt.ls.err" >&2
  status=1
elif ! git ls-remote "$REMOTE" >"$WORK/git.ls" 2>"$WORK/git.ls.err"; then
  echo "ERROR: \`git ls-remote\` itself failed -- no network?" >&2
  sed 's/^/    /' "$WORK/git.ls.err" >&2
  exit 2
else
  grep -v '\^{}$' "$WORK/git.ls" | sort > "$WORK/git.ls.sorted"
  grep -v '\^{}$' "$WORK/ajt.ls" | sort > "$WORK/ajt.ls.sorted"
  n_refs=$(wc -l < "$WORK/git.ls.sorted")
  # Landmark: a repository with no refs would make an empty-vs-empty diff pass.
  if [ "$n_refs" -lt 3 ]; then
    echo "FAIL: only $n_refs refs advertised -- the corpus is not what this gate assumes" >&2
    status=1
  elif ! diff -q "$WORK/git.ls.sorted" "$WORK/ajt.ls.sorted" >/dev/null; then
    echo "FAIL: refs disagree (< git, > ajt):" >&2
    diff "$WORK/git.ls.sorted" "$WORK/ajt.ls.sorted" | head -20 >&2
    status=1
  else
    echo "  ok — $n_refs refs identical to \`git ls-remote\`"
  fi
fi

# --- 2: the security gate ---------------------------------------------------
# Without this, `encrypted = 1` could mean "no verification at all" and every
# check above would still be green.
#
# "The command failed" is NOT the assertion, and a loose grep for
# certificate|tls|ssl is not either -- both of those passed against a build with
# `.ca = .no_verification` wired in on purpose, because none of those hosts
# serves a git repository, so the run failed at the 404 instead and Zig's error
# trace mentions `src/git/tls.zig` in every frame. What is asserted is the exact
# marker `src/git/tls.zig:fail` emits, with an error name in the
# Certificate*/Tls* family: that string exists only on a path where OUR
# handshake refused the peer, and a successful handshake followed by any HTTP
# outcome cannot produce it.
#
# The expected error is pinned per host too, because "some TLS error" would
# still pass if host verification silently replaced chain verification.
echo "==> 2. certificate verification actually happens"
check_refused() {  # host, expected error name
  local host="$1" want="$2"
  if "$AJT_BIN" git ls-remote "https://$host/" >"$WORK/bad.out" 2>"$WORK/bad.err"; then
    echo "FAIL: https://$host/ was ACCEPTED -- TLS verification is not happening" >&2
    return 1
  fi
  local got
  got="$(grep -oE "ajt tls \($host:443\): (Certificate|Tls)[A-Za-z]*" "$WORK/bad.err" | head -1)"
  if [ -z "$got" ]; then
    echo "FAIL: $host failed, but NOT in the TLS handshake -- no 'ajt tls (...): Certificate*/Tls*'" >&2
    echo "      (a build that skips verification fails here at the HTTP layer instead)" >&2
    sed 's/^/    /' "$WORK/bad.err" | head -5 >&2
    return 1
  fi
  if [ "${got##*: }" != "$want" ]; then
    echo "FAIL: $host refused as ${got##*: }, expected $want" >&2
    return 1
  fi
  echo "  ok — $host refused: $want"
  return 0
}
check_refused expired.badssl.com      CertificateExpired      || status=1
check_refused wrong.host.badssl.com   CertificateHostMismatch || status=1
check_refused self-signed.badssl.com  TlsCertificateNotVerified || status=1

# --- 3: fetch, index, resolve -----------------------------------------------
# `AJT_GIT_BACKEND=lib` is EXPLICIT and load-bearing. `ajt git fetch` goes
# through `git.Backend`, and the default there is `cli` — the same default the
# Pkg verbs have. Without the variable this check would run `git clone --bare`
# in a subprocess, `git fsck` would be clean because `git` wrote the pack, and
# the libgit2 packfile path this check exists for would not run at all.
echo "==> 3. fetch: packfile receive, delta resolution, index construction"
CLONE="$WORK/clone"
BRANCH="$(git ls-remote --symref "$REMOTE" HEAD 2>/dev/null \
          | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')"
BRANCH="${BRANCH:-master}"
want="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')"
if [ -z "$want" ]; then
  echo "FAIL: could not learn the head of $BRANCH from \`git ls-remote\`" >&2
  status=1
elif ! got="$(AJT_GIT_BACKEND=lib "$AJT_BIN" git fetch "$REMOTE" "$CLONE" "$BRANCH" 2>"$WORK/fetch.err")"; then
  echo "FAIL: ajt git fetch failed:" >&2
  sed 's/^/    /' "$WORK/fetch.err" >&2
  status=1
else
  got_sha="$(printf '%s' "$got" | awk '{print $1}')"
  if [ "$got_sha" != "$want" ]; then
    echo "FAIL: $BRANCH resolved to $got_sha, but the server advertises $want" >&2
    status=1
  elif ! git -C "$CLONE" fsck --strict >"$WORK/fsck.out" 2>&1; then
    echo "FAIL: \`git fsck\` on the fetched repository is not clean:" >&2
    sed 's/^/    /' "$WORK/fsck.out" | head -20 >&2
    status=1
  else
    # Landmark: fsck on an EMPTY repository is also clean, so count the objects
    # it actually walked.
    n_obj="$(git -C "$CLONE" rev-list --objects --all 2>/dev/null | wc -l)"
    if [ "$n_obj" -lt 100 ]; then
      echo "FAIL: only $n_obj objects in the fetched repository -- nothing was really transferred" >&2
      status=1
    else
      echo "  ok — $BRANCH at ${want:0:12}, $n_obj objects, fsck clean"
    fi
  fi
fi

# --- 4: sha1dc, over a real corpus ------------------------------------------
echo "==> 4. hash-object vs git, over a file corpus"
LIST="$WORK/files.txt"
: > "$LIST"
if [ -d "$DEPOT/packages" ]; then
  # The same corpus treehash.sh walks: real package sources, every size and
  # encoding a registry can contain.
  find "$DEPOT/packages" -type f -size -8M 2>/dev/null | head -n "$LIMIT" > "$LIST"
fi
if [ "$(wc -l < "$LIST")" -lt 50 ]; then
  # No depot on this machine: fall back to Ajt's own tree, which is committed
  # and therefore always present.
  find "$AJT_ROOT/src" "$AJT_ROOT/tools" -type f 2>/dev/null | head -n "$LIMIT" > "$LIST"
fi
# Both sides read the path list from stdin and emit one hash per line, so the
# comparison is positional. A path containing whitespace would desynchronise the
# two streams and the diff would then fail for the wrong reason.
if grep -q '[[:space:]]' "$LIST"; then
  grep -v '[[:space:]]' "$LIST" > "$LIST.t" && mv "$LIST.t" "$LIST"
fi
n_files=$(wc -l < "$LIST")
if [ "$n_files" -lt 20 ]; then
  echo "FAIL: corpus is only $n_files files -- nothing meaningful was compared" >&2
  status=1
else
  # `--no-filters` on git's side: `git hash-object` otherwise consults
  # .gitattributes for the path and can rewrite line endings, while
  # `git_odb_hash` always hashes the bytes it is given.
  git hash-object --no-filters --stdin-paths < "$LIST" > "$WORK/git.hashes" 2>"$WORK/git.hash.err" || {
    echo "FAIL: \`git hash-object --stdin-paths\` failed:" >&2
    sed 's/^/    /' "$WORK/git.hash.err" >&2
    status=1
  }
  "$AJT_BIN" git hash-object --stdin-paths < "$LIST" > "$WORK/ajt.hashes" 2>"$WORK/ajt.hash.err" || {
    echo "FAIL: \`ajt git hash-object\` failed:" >&2
    sed 's/^/    /' "$WORK/ajt.hash.err" >&2
    status=1
  }
  gn=$(wc -l < "$WORK/git.hashes")
  an=$(wc -l < "$WORK/ajt.hashes")
  if [ "$gn" -ne "$an" ] || [ "$gn" -ne "$n_files" ]; then
    echo "FAIL: hash count mismatch (files=$n_files git=$gn ajt=$an)" >&2
    status=1
  elif ! diff -q "$WORK/git.hashes" "$WORK/ajt.hashes" >/dev/null; then
    echo "FAIL: sha1dc disagrees with git (< git, > ajt); first 10:" >&2
    diff "$WORK/git.hashes" "$WORK/ajt.hashes" | head -10 >&2
    # Name the files, because "two hex strings differ" is not a lead.
    paste "$LIST" "$WORK/git.hashes" "$WORK/ajt.hashes" \
      | awk '$2 != $3 {print "    " $1}' | head -5 >&2
    status=1
  else
    echo "  ok — $n_files files, every SHA-1 identical to \`git hash-object\`"
  fi
fi

materialise_gate

# --- 6: the static musl link (opt-in; it is a full rebuild) -----------------
echo
if [ $STATIC -eq 1 ]; then
  echo "==> 6. static x86_64-linux-musl build"
  command -v zig >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
  ( cd "$AJT_ROOT" && zig build -Dgit -Doptimize=ReleaseFast \
      -Dtarget=x86_64-linux-musl -p "$WORK/static" ) >"$WORK/static.log" 2>&1 || {
    echo "FAIL: static build failed:" >&2; tail -20 "$WORK/static.log" >&2; status=1; }
  if [ -x "$WORK/static/bin/ajt" ]; then
    desc="$(file -b "$WORK/static/bin/ajt")"
    size="$(wc -c < "$WORK/static/bin/ajt")"
    case "$desc" in
      *"statically linked"*) echo "  ok — statically linked, $size bytes" ;;
      *) echo "FAIL: not statically linked: $desc" >&2; status=1 ;;
    esac
  fi
else
  echo "==> 6. static musl build: skipped (pass --static)"
fi

echo
if [ $status -eq 0 ]; then
  echo "PASS — the registered git_stream carries the git protocol, verifies"
  echo "       certificates, indexes packfiles, hashes like git, and writes the"
  echo "       same tree to disk as the \`git\` subprocess backend does"
  [ $skipped -eq 1 ] && echo "(something was SKIPPED -- see the banner above)"
else
  echo "FAIL — see above"
  [ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect)"
fi
exit $status
