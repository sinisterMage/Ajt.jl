#!/usr/bin/env bash
# Differential gate for `prefs_hash`.
#
# Ajt's julia/preferences.zig must agree with
#   Base.get_preferences_hash(uuid::Union{Nothing,UUID}, prefs_list::Vector{String})
# (base/loading.jl:3819-3837) for every fixture below. That is the exact
# function Julia calls in two places: when naming a precompile cache file
# (loading.jl:3152-3172, the hash feeds a crc32c chain) and when deciding
# whether an existing `.ji` is still valid (loading.jl:4145-4152). A wrong
# prefs_hash is invisible -- no error, just every cache entry missing forever.
#
# A NOTE ON THE FILE NAMES. There is no `Preferences.toml` anywhere in Julia's
# loader. `grep -rn "Preferences.toml"` over share/julia/ finds only
#   const preferences_names = ("JuliaLocalPreferences.toml", "LocalPreferences.toml")
# (loading.jl:637). The two real sources are the `[preferences]` table INSIDE
# `Project.toml` (loading.jl:3736) and one of those two sidecars
# (loading.jl:3740-3750). The cases below are named accordingly.
#
# Usage: tools/diff_harness/preferences.sh [--keep] [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-prefs-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- 0. confirm the oracle exists, with the signature we are about to call ---
# A gate that quietly tests nothing is worse than no gate, so this aborts
# loudly rather than skipping if Base ever renames or re-signs the function.
echo "==> oracle entry point"
if ! julia --startup-file=no -e '
    ms = methods(Base.get_preferences_hash)
    want = "get_preferences_hash(uuid::Union{Nothing, Base.UUID}, prefs_list::Vector{String})"
    ok = any(m -> occursin(want, string(m)), ms)
    if !ok
        println(stderr, "Base.get_preferences_hash does not have the expected signature.")
        println(stderr, "Found:"); for m in ms; println(stderr, "  ", m); end
        exit(1)
    end
    println("  Base.", want, "  @ ", Base.PkgId(Base))
'; then
  echo "ERROR: no usable Julia entry point for prefs_hash — refusing to pretend this gate ran" >&2
  exit 2
fi

# --- 1. driver ---------------------------------------------------------------
# main.zig has no `prefs-hash` subcommand (and this unit may not add one), so
# the harness compiles its own thin driver against the library module.
cat > "$WORK/driver.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");
const prefs = ajt.julia.preferences;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var uuid_s: []const u8 = "nothing";
    var home: ?[]const u8 = null;
    var trace = false;
    var names: std.ArrayList([]const u8) = .empty;
    var load_path: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--uuid")) {
            i += 1;
            uuid_s = args[i];
        } else if (std.mem.eql(u8, a, "--pref")) {
            i += 1;
            try names.append(arena, args[i]);
        } else if (std.mem.eql(u8, a, "--home")) {
            i += 1;
            home = args[i];
        } else if (std.mem.eql(u8, a, "--trace")) {
            trace = true;
        } else {
            try load_path.append(arena, a);
        }
    }

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const uuid: ?ajt.julia.Uuid = if (std.mem.eql(u8, uuid_s, "nothing"))
        null
    else
        try ajt.julia.Uuid.parse(uuid_s);

    const opts: prefs.ResolveOptions = .{ .home_dir = home };
    const h = try prefs.hashForLoadPath(arena, io, load_path.items, uuid, names.items, opts);
    try out.print("0x{x:0>16}\n", .{h});

    if (trace) {
        const envs = try prefs.loadEnvs(arena, io, load_path.items, uuid, opts);
        const p: ?*const ajt.toml.Table = if (uuid) |u|
            try prefs.getPreferences(arena, envs, u)
        else
            null;
        const text = try prefs.hashInput(arena, p, names.items);
        try out.writeAll(text);
    }
    try out.flush();
}
ZIG

echo "==> building driver"
# Hermetic per-run cache, as in stdlibs.sh. The local cache was already
# contained; the global one was still shared with every other zig on the box.
zig build-exe -ODebug --name prefs_driver \
  --dep ajt -Mroot="$WORK/driver.zig" -Majt="$AJT_ROOT/src/root.zig" \
  --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
  -femit-bin="$WORK/prefs_driver" \
  || { echo "ERROR: driver failed to build" >&2; exit 2; }
DRIVER="$WORK/prefs_driver"

# --- 2. fixtures -------------------------------------------------------------
FOO_UUID="22222222-2222-2222-2222-222222222222"
APP_UUID="11111111-1111-1111-1111-111111111111"
BAR_UUID="33333333-3333-3333-3333-333333333333"
BAZ_UUID="44444444-4444-4444-4444-444444444444"
GHOST_UUID="99999999-9999-9999-9999-999999999999"

F="$WORK/fixtures"
mkdir -p "$F"

plain_project() {   # plain_project <dir>  -- deps, no preferences at all
  mkdir -p "$1"
  cat > "$1/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"
EOF
}

# (a) nothing at all: the common case, and the one that must be cheap.
plain_project "$F/a_none"

# (b) [preferences] inside Project.toml only.
mkdir -p "$F/b_project_only"
cat > "$F/b_project_only/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
a = 1
b = "from-project"
nest = { x = 1, y = 2 }
EOF

# (c) LocalPreferences.toml only.
plain_project "$F/c_local_only"
cat > "$F/c_local_only/LocalPreferences.toml" <<EOF
[Foo]
b = "from-local"
c = true
EOF

# (d) both, with overlapping keys -- exercises precedence and nested merge.
mkdir -p "$F/d_both"
cp "$F/b_project_only/Project.toml" "$F/d_both/Project.toml"
cat > "$F/d_both/LocalPreferences.toml" <<EOF
[Foo]
b = "from-local"
c = true
nest = { y = 99 }
EOF

# (e) JuliaLocalPreferences.toml wins outright; the sibling is never read.
mkdir -p "$F/e_julia_local_wins"
cp "$F/b_project_only/Project.toml" "$F/e_julia_local_wins/Project.toml"
cat > "$F/e_julia_local_wins/JuliaLocalPreferences.toml" <<EOF
[Foo]
b = "from-julia-local"
EOF
cat > "$F/e_julia_local_wins/LocalPreferences.toml" <<EOF
[Foo]
b = "SHOULD-NEVER-BE-READ"
c = "SHOULD-NEVER-BE-READ"
EOF

# (f) __clear__ removes keys the project set, before this override's own keys.
mkdir -p "$F/f_clear"
cp "$F/b_project_only/Project.toml" "$F/f_clear/Project.toml"
cat > "$F/f_clear/LocalPreferences.toml" <<EOF
[Foo]
__clear__ = ["a", "nest"]
b = "cleared-then-set"
EOF

# (g) __clear__ that is not a Vector{String} is ignored.
for variant in empty string mixed ints; do
  mkdir -p "$F/g_clear_$variant"
  cp "$F/b_project_only/Project.toml" "$F/g_clear_$variant/Project.toml"
done
echo '[Foo]'                 > "$F/g_clear_empty/LocalPreferences.toml"
echo '__clear__ = []'       >> "$F/g_clear_empty/LocalPreferences.toml"
echo '[Foo]'                 > "$F/g_clear_string/LocalPreferences.toml"
echo '__clear__ = "a"'      >> "$F/g_clear_string/LocalPreferences.toml"
echo '[Foo]'                 > "$F/g_clear_mixed/LocalPreferences.toml"
echo '__clear__ = ["a", 1]' >> "$F/g_clear_mixed/LocalPreferences.toml"
echo '[Foo]'                 > "$F/g_clear_ints/LocalPreferences.toml"
echo '__clear__ = [1, 2]'   >> "$F/g_clear_ints/LocalPreferences.toml"

# (h) every value type Base.parsed_toml can produce (minus dates, which the
#     port deliberately refuses) plus the float edge cases.
mkdir -p "$F/h_types"
cat > "$F/h_types/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
s = "hello"
s_empty = ""
s_unicode = "naïve ✓ 日本語"
s_long = "0123456789abcdef0123456789abcdef0123456789abcdefX"
i = 42
i_neg = -3
i_big = 9007199254740993
i_min = -9223372036854775808
f = 1.5
f_zero = 0.0
f_negzero = -0.0
f_int_valued = 3.0
f_big = 1e300
f_inf = inf
f_ninf = -inf
f_nan = nan
b_true = true
b_false = false
arr_str = ["a", "b", "c"]
arr_int = [1, 2, 3]
arr_empty = []
arr_mixed = ["a", 1, true, 2.5]
arr_nested = [[1, 2], ["x"]]
tbl = { k = 1, deep = { z = "q", l = [1] } }
EOF

# (i) a UUID that cannot be named from this project contributes nothing --
#     not even the sidecar (loading.jl:3729-3731).
mkdir -p "$F/i_unknown_uuid"
cp "$F/b_project_only/Project.toml" "$F/i_unknown_uuid/Project.toml"
cat > "$F/i_unknown_uuid/LocalPreferences.toml" <<EOF
[Ghost]
a = "unreachable"
EOF

# (j) preferences filed under the project's OWN name.
mkdir -p "$F/j_self"
cat > "$F/j_self/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.App]
mine = "yes"
EOF

# (k) extras / weakdeps also name a UUID for preferences purposes.
mkdir -p "$F/k_extras_weakdeps"
cat > "$F/k_extras_weakdeps/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[extras]
Bar = "$BAR_UUID"

[weakdeps]
Baz = "$BAZ_UUID"

[preferences.Bar]
via = "extras"

[preferences.Baz]
via = "weakdeps"
EOF

# (l) two load-path entries: the first wins, the second still contributes its
#     own keys (get_preferences walks the list in reverse).
mkdir -p "$F/l_env_first" "$F/l_env_second"
cat > "$F/l_env_first/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
k = "active"
shared_tbl = { from_first = 1 }
EOF
cat > "$F/l_env_second/Project.toml" <<EOF
[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
k = "shared"
only_shared = 7
shared_tbl = { from_second = 2 }
EOF

# (m) a workspace: the member's project is expanded to itself + the root
#     (get_projects_workspace_to_root, loading.jl:3786-3795).
mkdir -p "$F/m_workspace/sub"
cat > "$F/m_workspace/Project.toml" <<EOF
name = "Root"
uuid = "55555555-5555-5555-5555-555555555555"

[workspace]
projects = ["sub"]

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
from_root = "root"
k = "root-loses"
EOF
cat > "$F/m_workspace/sub/Project.toml" <<EOF
name = "Sub"
uuid = "66666666-6666-6666-6666-666666666666"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
k = "sub-wins"
EOF

# (n) JuliaProject.toml is preferred over Project.toml (project_names order).
mkdir -p "$F/n_julia_project"
cat > "$F/n_julia_project/JuliaProject.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
which = "JuliaProject"
EOF
cat > "$F/n_julia_project/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
which = "Project-SHOULD-NOT-WIN"
EOF

# (o) a workspace member whose Project.toml does not exist yet -- what
#     `julia --project=<new member>` produces. `base_project` only takes the
#     dirname of the first load-path entry (loading.jl:676), so Julia still
#     finds the workspace root; resolving the entry first and giving up when it
#     does not exist returns 0 instead.
mkdir -p "$F/o_ws_unresolved/member"
cat > "$F/o_ws_unresolved/Project.toml" <<EOF
name = "Root"
uuid = "77777777-7777-7777-7777-777777777777"

[workspace]
projects = ["member"]

[deps]
Foo = "$FOO_UUID"

[preferences.Foo]
from_root = "root"
EOF

# (p) an unparseable sidecar in an env whose project file cannot name the
#     requested UUID. collect_preferences returns before it ever looks at the
#     sidecar (loading.jl:3729-3731), so Julia returns a hash; reading it
#     eagerly turns that into a hard parse failure.
mkdir -p "$F/p_unreadable_sidecar"
cat > "$F/p_unreadable_sidecar/Project.toml" <<EOF
name = "App"
uuid = "$APP_UUID"

[deps]
Foo = "$FOO_UUID"
EOF
printf 'this is not = = valid toml [[[\n' > "$F/p_unreadable_sidecar/LocalPreferences.toml"

# --- 3. compare --------------------------------------------------------------
pass=0; fail=0
: > "$WORK/mismatches.txt"

check() {  # check <label> <load-path (colon separated)> <uuid|nothing> <pref>...
  local label="$1" lp="$2" uuid="$3"; shift 3
  local names=("$@")

  local jl_list="String[]"
  if [ ${#names[@]} -gt 0 ]; then
    local joined=""
    local n
    for n in "${names[@]}"; do joined="$joined\"$n\","; done
    jl_list="String[${joined%,}]"
  fi

  local jl
  jl=$(JULIA_LOAD_PATH="$lp" julia --startup-file=no -e "
    u = $( [ "$uuid" = "nothing" ] && echo "nothing" || echo "Base.UUID(\"$uuid\")" )
    println(repr(Base.get_preferences_hash(u, $jl_list)))
  " 2>"$WORK/jl.err")
  if [ -z "$jl" ]; then
    fail=$((fail + 1))
    printf '%s\tjulia-oracle-failed\n' "$label" >> "$WORK/mismatches.txt"
    echo "  FAIL $label — Julia oracle errored:"; sed 's/^/       /' "$WORK/jl.err" | head -5
    return
  fi

  local args=(--uuid "$uuid" --home "$HOME")
  local n
  for n in "${names[@]}"; do args+=(--pref "$n"); done
  local IFS_SAVE="$IFS"; IFS=':'; local lp_parts=($lp); IFS="$IFS_SAVE"
  local aj
  aj=$("$DRIVER" "${args[@]}" "${lp_parts[@]}" 2>"$WORK/aj.err" | head -1)

  if [ "$jl" = "$aj" ]; then
    pass=$((pass + 1))
    [ $VERBOSE -eq 1 ] && echo "  ok   $label = $jl"
  else
    fail=$((fail + 1))
    printf '%s\t%s\t%s\n' "$label" "$jl" "$aj" >> "$WORK/mismatches.txt"
    echo "  FAIL $label"
    echo "       julia : $jl"
    echo "       ajt   : ${aj:-<no output>}"
    [ -s "$WORK/aj.err" ] && sed 's/^/       /' "$WORK/aj.err" | head -5
    echo "       --- ajt's pre-hash input ---"
    "$DRIVER" "${args[@]}" --trace "${lp_parts[@]}" 2>&1 | tail -n +2 | sed 's/^/       /'
    echo "       --- julia's merged preferences ---"
    JULIA_LOAD_PATH="$lp" julia --startup-file=no -e "
      u = $( [ "$uuid" = "nothing" ] && echo "nothing" || echo "Base.UUID(\"$uuid\")" )
      u === nothing || println(Base.get_preferences(u))
    " 2>&1 | sed 's/^/       /'
  fi
}

echo "==> comparing"

check "a/none"                  "$F/a_none"          "$FOO_UUID" a b c
check "a/none-empty-list"       "$F/a_none"          "$FOO_UUID"
check "a/nothing-uuid"          "$F/a_none"          nothing     a b

check "b/project-only:a"        "$F/b_project_only"  "$FOO_UUID" a
check "b/project-only:b"        "$F/b_project_only"  "$FOO_UUID" b
check "b/project-only:nest"     "$F/b_project_only"  "$FOO_UUID" nest
check "b/project-only:all"      "$F/b_project_only"  "$FOO_UUID" a b nest
check "b/project-only:reorder"  "$F/b_project_only"  "$FOO_UUID" nest b a
check "b/project-only:absent"   "$F/b_project_only"  "$FOO_UUID" zzz
check "b/project-only:mixed"    "$F/b_project_only"  "$FOO_UUID" zzz a zzz b

check "c/local-only:b"          "$F/c_local_only"    "$FOO_UUID" b
check "c/local-only:all"        "$F/c_local_only"    "$FOO_UUID" a b c

check "d/both:b-wins"           "$F/d_both"          "$FOO_UUID" b
check "d/both:nest-merged"      "$F/d_both"          "$FOO_UUID" nest
check "d/both:all"              "$F/d_both"          "$FOO_UUID" a b c nest
check "d/both:reorder"          "$F/d_both"          "$FOO_UUID" nest c b a

check "e/julia-local-wins:b"    "$F/e_julia_local_wins" "$FOO_UUID" b
check "e/julia-local-wins:c"    "$F/e_julia_local_wins" "$FOO_UUID" c
check "e/julia-local-wins:all"  "$F/e_julia_local_wins" "$FOO_UUID" a b c nest

check "f/clear:a-gone"          "$F/f_clear"         "$FOO_UUID" a
check "f/clear:nest-gone"       "$F/f_clear"         "$FOO_UUID" nest
check "f/clear:b-set"           "$F/f_clear"         "$FOO_UUID" b
check "f/clear:marker-kept"     "$F/f_clear"         "$FOO_UUID" __clear__
check "f/clear:all"             "$F/f_clear"         "$FOO_UUID" a b nest __clear__

for variant in empty string mixed ints; do
  check "g/clear-$variant"      "$F/g_clear_$variant" "$FOO_UUID" a b nest __clear__
done

for key in s s_empty s_unicode s_long i i_neg i_big i_min f f_zero f_negzero \
           f_int_valued f_big f_inf f_ninf f_nan b_true b_false \
           arr_str arr_int arr_empty arr_mixed arr_nested tbl; do
  check "h/types:$key"          "$F/h_types"         "$FOO_UUID" "$key"
done
check "h/types:everything"      "$F/h_types"         "$FOO_UUID" \
  s s_empty s_unicode s_long i i_neg i_big i_min f f_zero f_negzero \
  f_int_valued f_big f_inf f_ninf f_nan b_true b_false \
  arr_str arr_int arr_empty arr_mixed arr_nested tbl

check "i/unknown-uuid"          "$F/i_unknown_uuid"  "$GHOST_UUID" a b nest
check "i/unknown-uuid:known"    "$F/i_unknown_uuid"  "$FOO_UUID"   a b nest

check "j/self-name"             "$F/j_self"          "$APP_UUID"   mine
check "k/extras"                "$F/k_extras_weakdeps" "$BAR_UUID" via
check "k/weakdeps"              "$F/k_extras_weakdeps" "$BAZ_UUID" via

check "l/two-envs:first-wins"   "$F/l_env_first:$F/l_env_second" "$FOO_UUID" k
check "l/two-envs:second-adds"  "$F/l_env_first:$F/l_env_second" "$FOO_UUID" only_shared
check "l/two-envs:tbl-merged"   "$F/l_env_first:$F/l_env_second" "$FOO_UUID" shared_tbl
check "l/two-envs:all"          "$F/l_env_first:$F/l_env_second" "$FOO_UUID" k only_shared shared_tbl
check "l/two-envs:reversed"     "$F/l_env_second:$F/l_env_first" "$FOO_UUID" k only_shared shared_tbl

check "m/workspace:sub-wins"    "$F/m_workspace/sub" "$FOO_UUID" k
check "m/workspace:root-adds"   "$F/m_workspace/sub" "$FOO_UUID" from_root
check "m/workspace:all"         "$F/m_workspace/sub" "$FOO_UUID" k from_root
check "m/workspace:root-env"    "$F/m_workspace"     "$FOO_UUID" k from_root

check "n/JuliaProject-wins"     "$F/n_julia_project" "$FOO_UUID" which

check "o/ws-missing-projfile"   "$F/o_ws_unresolved/member/Project.toml"  "$FOO_UUID" from_root
check "o/ws-nonproject-file"    "$F/o_ws_unresolved/member/Manifest.toml" "$FOO_UUID" from_root
check "o/ws-implicit-dir"       "$F/o_ws_unresolved/member"               "$FOO_UUID" from_root
check "o/ws-nonexistent-dir"    "$F/o_ws_unresolved/member/deeper"        "$FOO_UUID" from_root

check "p/unreadable-sidecar"    "$F/p_unreadable_sidecar" "$GHOST_UUID" a b

echo
echo "  agree    : $pass"
echo "  diverge  : $fail"

if [ "$fail" -gt 0 ]; then
  echo
  echo "Divergences:"
  cat "$WORK/mismatches.txt"
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the fixtures)"
  exit 1
fi

echo
echo "PASS — ajt's prefs_hash matches Base.get_preferences_hash across $pass queries"
