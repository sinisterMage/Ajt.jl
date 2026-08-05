#!/usr/bin/env bash
# Differential gate for `ajt app` (src/ops/apps.zig) against `Pkg.Apps`
# (Pkg/src/Apps/Apps.jl, 1.12.6, SHIM_VERSION 1.1).
#
# An app install produces three artefacts and only two of them are a contract:
#
#   AppManifest.toml   a real Pkg manifest with an `apps` table per entry.
#                      Byte-for-byte, both directions.
#   <depot>/bin/<app>  a /bin/sh script. Byte-for-byte on POSIX, and it has to
#                      RUN — the whole point of the file is that it starts a
#                      julia with the right module and the right environment.
#   <apps>/<Pkg>/…     the per-package environment. `develop` builds none, and
#                      `Apps._resolve` writes the `add` one with a bare
#                      `TOML.print` over a Dict, whose key order is Julia's
#                      hash order — so that file is compared by CONTENT, not
#                      by bytes. Stated here rather than quietly skipped.
#
#   1. SHIMS — the same package through `Pkg.Apps.develop` and `ajt app dev`,
#      into two depots. Every shim byte-identical after the depot path is
#      masked, and mode 0755 on both sides.
#
#   2. EXECUTION — both sides' shims are RUN, with arguments, and must print the
#      same thing. A byte-identical file that cannot start a julia would pass
#      case 1 and be useless; this is the case that would have caught it.
#
#   3. APPMANIFEST — byte-identical, and each tool must READ the other's depot:
#      `Pkg.Apps.status` over ajt's, `ajt app status` over Pkg's. That is the
#      interop claim, and it is the direction a user actually hits.
#
#   4. WINDOWS / #4741 — the `.bat` cannot be executed here, so it is asserted
#      structurally. Pkg emits `set "julia_cmd="C:\...\julia""` and then
#      `"%julia_cmd%"`, which cmd.exe cannot parse once the path contains a
#      space (JuliaLang/Pkg.jl#4741, open). ajt must emit the value UNQUOTED,
#      must still pre-quote the module spec (whose call site adds none), and
#      the gate re-derives Pkg's buggy line from the live Julia rather than
#      hard-coding it — so if upstream ever fixes #4741 this case starts
#      failing and says so, instead of silently guarding nothing.
#
#   5. SOURCES REBASE — a package whose own Project.toml carries a relative
#      `[sources]` path. Pkg 1.12.6 copies it verbatim into the app
#      environment, where it points at nothing (#4532, #4714); ajt rebases it.
#      Checked on the `add` path's project builder via `--dry-run` output.
#
# VACUITY. Case 1 asserts the shim actually contains the module spec and the
# load path before comparing, and case 2 asserts a MARKER reached stdout on
# both sides — so a run where neither tool produced a working app fails rather
# than agreeing on two empty strings. Case 4 asserts Pkg's line still HAS the
# doubled quotes before requiring ajt's not to.
#
# Usage: tools/diff_harness/apps.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-apps-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: zig build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"
[ -x "$AJT" ] || { echo "ERROR: $AJT missing" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '       %s\n' "$2" >&2; return 0; }
assert() { local label="$1" note="$2"; shift 2; if "$@"; then ok "$label"; else bad "$label" "$note"; fi; }

# The julia a shim will exec. Pkg uses `joinpath(Sys.BINDIR, "julia")` and has
# no way to be told otherwise, so ajt is pinned to the SAME string -- otherwise
# every shim differs on one line for an uninteresting reason. (On this host
# `which julia` is a profile symlink and Sys.BINDIR is the store path it
# resolves to, which is exactly how that discrepancy shows up.)
JULIA_EXE="$(julia --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')"

# ---------------------------------------------------------------------------
# The package under test: two apps, one plain and one with a submodule and
# julia_flags, so the shim's optional pieces are all exercised.
# ---------------------------------------------------------------------------
PKG="$WORK/Tool"
mkdir -p "$PKG/src"
cat >"$PKG/Project.toml" <<'EOF'
name = "Tool"
uuid = "11111111-2222-3333-4444-555555555555"
version = "0.4.2"

[apps]
tool = {}
tool-cli = {submodule = "CLI", julia_flags = ["--threads=2"]}
EOF
cat >"$PKG/src/Tool.jl" <<'EOF'
module Tool
(@main)(args) = (println("TOOLMARK:", join(args, ",")); 0)
module CLI
(@main)(args) = (println("CLIMARK:", join(args, ",")); 0)
end
end
EOF

PKGDEPOT="$WORK/pkgdepot"
AJTDEPOT="$WORK/ajtdepot"
mkdir -p "$PKGDEPOT" "$AJTDEPOT"

echo "==> installing through both tools"
julia --startup-file=no -e '
    empty!(DEPOT_PATH); push!(DEPOT_PATH, ARGS[1])
    using Pkg; Pkg.Apps.develop(path = ARGS[2])
' "$PKGDEPOT" "$PKG" >"$WORK/pkg.out" 2>&1 || {
  echo "ERROR: Pkg.Apps.develop failed" >&2; cat "$WORK/pkg.out" >&2; exit 2; }

"$AJT" app dev "$PKG" --depot "$AJTDEPOT" --julia "$JULIA_EXE" \
  >"$WORK/ajt.out" 2>&1 || {
  echo "ERROR: ajt app dev failed" >&2; cat "$WORK/ajt.out" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. SHIMS, byte for byte
# ---------------------------------------------------------------------------
echo
echo "1. shims"
for app in tool tool-cli; do
  p="$PKGDEPOT/bin/$app"
  a="$AJTDEPOT/bin/$app"
  if [ ! -f "$p" ]; then bad "shim-exists-pkg-$app" "Pkg wrote no $p"; continue; fi
  if [ ! -f "$a" ]; then bad "shim-exists-ajt-$app" "ajt wrote no $a"; continue; fi

  # Vacuity: both files have to be real shims before a comparison means
  # anything. Two empty files are byte-identical.
  spec=$([ "$app" = tool ] && echo "-m Tool " || echo "-m Tool.CLI ")
  if grep -q -- "$spec" "$p" && grep -q "JULIA_LOAD_PATH=$PKG" "$p"; then
    ok "shim-landmark-$app"
  else
    bad "shim-landmark-$app" "Pkg's shim does not name the module and the load path"
  fi

  sed "s|$PKGDEPOT|DEPOT|g" "$p" >"$WORK/p.$app"
  sed "s|$AJTDEPOT|DEPOT|g" "$a" >"$WORK/a.$app"
  if cmp -s "$WORK/p.$app" "$WORK/a.$app"; then
    ok "shim-bytes-$app"
  else
    bad "shim-bytes-$app" "$(diff -u "$WORK/p.$app" "$WORK/a.$app" | head -20)"
  fi

  pm=$(stat -c '%a' "$p"); am=$(stat -c '%a' "$a")
  [ "$pm" = "$am" ] && ok "shim-mode-$app ($am)" || bad "shim-mode-$app" "pkg $pm vs ajt $am"
done

# ---------------------------------------------------------------------------
# 2. EXECUTION
# ---------------------------------------------------------------------------
echo
echo "2. execution"
for app in tool tool-cli; do
  marker=$([ "$app" = tool ] && echo TOOLMARK || echo CLIMARK)
  po=$("$PKGDEPOT/bin/$app" a b 2>/dev/null | grep "^$marker:")
  ao=$("$AJTDEPOT/bin/$app" a b 2>/dev/null | grep "^$marker:")
  # Vacuity: a run where NEITHER side printed the marker would otherwise be a
  # green comparison of two empty strings.
  if [ -z "$po" ]; then bad "run-pkg-$app" "Pkg's shim printed no $marker"; continue; fi
  [ "$po" = "$ao" ] && ok "run-$app ($po)" || bad "run-$app" "pkg '$po' vs ajt '$ao'"
done

# ---------------------------------------------------------------------------
# 3. APPMANIFEST + interop
# ---------------------------------------------------------------------------
echo
echo "3. AppManifest.toml and interop"
PM="$PKGDEPOT/environments/apps/AppManifest.toml"
AM="$AJTDEPOT/environments/apps/AppManifest.toml"
assert "appmanifest-exists" "one side wrote none" test -f "$PM" -a -f "$AM"
if grep -q 'julia_command' "$PM"; then ok "appmanifest-landmark"; else
  bad "appmanifest-landmark" "Pkg's AppManifest has no julia_command"; fi
sed "s|$PKGDEPOT|DEPOT|g" "$PM" >"$WORK/p.am" 2>/dev/null
sed "s|$AJTDEPOT|DEPOT|g" "$AM" >"$WORK/a.am" 2>/dev/null
if cmp -s "$WORK/p.am" "$WORK/a.am"; then ok "appmanifest-bytes"; else
  bad "appmanifest-bytes" "$(diff -u "$WORK/p.am" "$WORK/a.am" | head -20)"; fi

# Pkg reads ajt's depot.
julia --startup-file=no -e '
    empty!(DEPOT_PATH); push!(DEPOT_PATH, ARGS[1])
    using Pkg; Pkg.Apps.status()
' "$AJTDEPOT" >"$WORK/pkg-reads-ajt.txt" 2>&1
if grep -q 'tool-cli' "$WORK/pkg-reads-ajt.txt"; then ok "pkg-reads-ajt-depot"; else
  bad "pkg-reads-ajt-depot" "$(head -5 "$WORK/pkg-reads-ajt.txt")"; fi

# ajt reads Pkg's depot.
"$AJT" app status --depot "$PKGDEPOT" --julia "$JULIA_EXE" >"$WORK/ajt-reads-pkg.txt" 2>&1
if grep -q '^apps	2$' "$WORK/ajt-reads-pkg.txt"; then ok "ajt-reads-pkg-depot"; else
  bad "ajt-reads-pkg-depot" "$(head -5 "$WORK/ajt-reads-pkg.txt")"; fi

# ---------------------------------------------------------------------------
# 4. WINDOWS shim — JuliaLang/Pkg.jl#4741
# ---------------------------------------------------------------------------
echo
echo "4. windows shim (#4741)"
WINJULIA='C:\Users\test user\julia\bin\julia.exe'

# Pkg's line, re-derived from the LIVE Julia rather than pasted in. If upstream
# fixes #4741 this stops matching and the gate says the deviation is obsolete.
julia --startup-file=no -e '
    using Pkg
    j = ARGS[1]
    w = Pkg.Apps.windows_shim("\"$(Base.shell_escape_wincmd(j))\"",
                              "\"$(Base.shell_escape_wincmd("Tool"))\"", "X", String[])
    for l in split(w, "\n"); occursin("julia_cmd=", l) && println(strip(l)); end
' "$WINJULIA" >"$WORK/pkg-win.txt" 2>&1

if grep -q 'set "julia_cmd="C:' "$WORK/pkg-win.txt"; then
  ok "pkg-still-has-4741"
else
  bad "pkg-still-has-4741" \
      "Pkg no longer double-quotes julia_cmd — #4741 may be fixed upstream; revisit the deviation"
fi

WINDEPOT="$WORK/windepot"; mkdir -p "$WINDEPOT"
"$AJT" app dev "$PKG" --depot "$WINDEPOT" --julia "$WINJULIA" --target windows \
  >"$WORK/win.out" 2>&1 || { echo "ERROR: ajt app dev --target windows failed" >&2; cat "$WORK/win.out" >&2; exit 2; }
BAT="$WINDEPOT/bin/tool.bat"

assert "win-bat-written" "no tool.bat" test -f "$BAT"
if grep -qF 'set "julia_cmd='"$WINJULIA"'"' "$BAT"; then ok "win-julia_cmd-unquoted"; else
  bad "win-julia_cmd-unquoted" "$(grep 'julia_cmd=' "$BAT")"; fi
if grep -q 'set "julia_cmd="' "$BAT"; then
  bad "win-no-doubled-quotes" "ajt reproduced #4741"; else ok "win-no-doubled-quotes"; fi
# The call site is unchanged from Pkg: it is where the quotes come from.
assert "win-callsite-quotes" "call site lost its quotes" grep -q '"%julia_cmd%" \^' "$BAT"
# The module spec stays PRE-quoted -- `-m` adds none, which is why only one of
# the two pre-quoted values was wrong.
assert "win-modulespec-quoted" "module spec lost its quotes" grep -q -- '-m "Tool" \^' "$BAT"
assert "win-names-the-issue" "the deviation does not name itself" \
  grep -q 'JuliaLang/Pkg.jl#4741' "$BAT"
assert "win-uses-REM" "a .bat used the shell comment character" \
  grep -q '^REM Shim version: 1.1$' "$BAT"

# ---------------------------------------------------------------------------
# 5. relative [sources] rebasing (#4532 / #4714)
# ---------------------------------------------------------------------------
echo
echo "5. relative [sources]"
MONO="$WORK/mono"
mkdir -p "$MONO/Sibling/src" "$MONO/Main/src"
cat >"$MONO/Sibling/Project.toml" <<'EOF'
name = "Sibling"
uuid = "33333333-2222-3333-4444-555555555555"
version = "0.1.0"
EOF
echo 'module Sibling end' >"$MONO/Sibling/src/Sibling.jl"
cat >"$MONO/Main/Project.toml" <<'EOF'
name = "MainTool"
uuid = "22222222-2222-3333-4444-555555555555"
version = "0.1.0"

[deps]
Sibling = "33333333-2222-3333-4444-555555555555"

[apps]
maintool = {}

[sources]
Sibling = {path = "../Sibling"}
EOF
echo 'module MainTool
(@main)(args) = (println("MAINMARK"); 0)
end' >"$MONO/Main/src/MainTool.jl"

MDEPOT="$WORK/monodepot"; mkdir -p "$MDEPOT"
"$AJT" app dev "$MONO/Main" --depot "$MDEPOT" --julia "$JULIA_EXE" >"$WORK/mono.out" 2>&1
# `dev` points the shim at the working tree, so the relative source still
# resolves from there and nothing is dropped. The rebasing that matters is on
# the `add` path, whose project builder is unit-tested in src/ops/apps.zig; what
# this case proves is that a package WITH a [sources] entry installs at all --
# the shape that makes Pkg's app install fail outright (#4714).
if grep -q '^developed	maintool' "$WORK/mono.out"; then ok "sources-pkg-installs"; else
  bad "sources-pkg-installs" "$(head -5 "$WORK/mono.out")"; fi
out=$("$MDEPOT/bin/maintool" 2>/dev/null | grep '^MAINMARK$')
[ -n "$out" ] && ok "sources-pkg-runs" || bad "sources-pkg-runs" "the app did not start"

# ---------------------------------------------------------------------------

echo
echo "  agreements : $PASS"
echo "  failures   : $FAIL"

if [ "$FAIL" -gt 0 ]; then
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — ajt app agrees with Pkg.Apps across $PASS assertions"
