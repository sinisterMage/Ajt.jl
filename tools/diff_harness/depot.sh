#!/usr/bin/env bash
# Differential gate for depot layout and atomic install.
#
# Four things, in order of how badly they fail when wrong:
#
#   1. PATHS. For every package pinned by a Manifest.toml reachable from here,
#      Ajt's computed `packages/<Name>/<version_slug>` must equal the directory
#      Julia derives from the same (uuid, tree-sha1) -- and for the ones that
#      are actually installed, the directory that exists on disk. Then
#      `Base.find_package` is asked directly, so the loader itself confirms it.
#      Getting this wrong produces no error anywhere: the package is simply
#      "not found" much later.
#   2. INSTALL. Stage, commit, and verify the result landed at that path with
#      Pkg's permission rules: files lose their write bits (`mode & ~0o222`),
#      directories keep theirs, symlinks are never chmod'ed. The symlink here
#      points OUTSIDE the install tree at a writable file, so a chmod that
#      followed the link is observable rather than merely suspected.
#   3. RACE. With the destination pre-created by a "competitor", the install
#      must report success and leave no `.ajt-tmp-*` behind. (This drives the
#      pre-rename `isdir` check; the post-rename re-check handles a competitor
#      that lands mid-rename, which no scripted test can schedule.)
#   4. DEPOT_PATH. Every shape of `JULIA_DEPOT_PATH` that `init_depot_path`
#      treats specially, compared against `Base.DEPOT_PATH` from a real julia:
#      unset, empty, the empty-ENTRY expansion, and the stacked production form.
#
# Nothing writes to the user's real depot; it is only read, under
# `$DEPOT/packages` and `$DEPOT/environments`.
#
# Usage: depot.sh [extra-Manifest.toml ...]
set -uo pipefail
# The expected modes below are stated absolutely (444 / 555), so pin the umask
# rather than deriving them from whatever the caller's shell had.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-depot-XXXXXX)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok()   { echo "  ok   $*"; }
# One expectation, one line, with the two sides named once each.
expect_eq() { # got want label
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3
    want: $2
    got : $1"; fi
}

# `src/depot.zig` is a library module; `src/main.zig` (the `ajt` binary) belongs
# to a different unit of work and this change is not allowed to add a
# subcommand to it. So the gate drives the library directly, through a
# throwaway program built against the same module `zig build test` compiles.
# When `ajt depot ...` exists, this heredoc should become a call to it.
cat > "$WORK/probe.zig" <<'PROBE_EOF'
const std = @import("std");
const ajt = @import("ajt");
const depot = ajt.depot;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var buf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "depot-path")) {
        // Env var NAMES come from depot.Env, not from this call site.
        const s = try depot.resolve(arena, .fromEnviron(
            init.environ_map.*,
            init.environ_map.get("AJT_JULIA_BINDIR"),
        ));
        for (s.entries, 0..) |e, i| try out.print("{s}{s}", .{ if (i == 0) "" else "|", e });
        try out.writeAll("\n");
        return;
    }

    // package-path <depot> [<Name> <uuid> <tree-sha1>]...
    // Batched: the corpus is a few hundred triples and a process per triple
    // would dominate the runtime.
    if (std.mem.eql(u8, cmd, "package-path")) {
        const d: depot.Depot = .{ .root = args[2] };
        var i: usize = 3;
        while (i + 2 < args.len) : (i += 3) {
            try out.print("{s}\n", .{try d.packageVersionDir(
                arena,
                args[i],
                try depot.Uuid.parse(args[i + 1]),
                try depot.Sha1.parse(args[i + 2]),
            )});
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "artifact-path")) {
        const d: depot.Depot = .{ .root = args[2] };
        try out.print("{s}\n", .{try d.artifactDir(arena, try depot.Sha1.parse(args[3]))});
        return;
    }

    if (std.mem.eql(u8, cmd, "compiled-path")) {
        const d: depot.Depot = .{ .root = args[2] };
        try out.print("{s}\n", .{try d.compiledDir(
            arena,
            try std.fmt.parseInt(u32, args[3], 10),
            try std.fmt.parseInt(u32, args[4], 10),
        )});
        return;
    }

    // install <dest-dir> <outside-symlink-target>
    if (std.mem.eql(u8, cmd, "install")) {
        var inst = try depot.begin(arena, io, args[2]);
        defer inst.deinit(io);

        try inst.dir.writeFile(io, .{ .sub_path = "Project.toml", .data = "name = \"Fixture\"\n" });
        try inst.dir.createDirPath(io, "src");
        try inst.dir.writeFile(io, .{ .sub_path = "src/Fixture.jl", .data = "module Fixture end\n" });
        try inst.dir.createDirPath(io, "bin");
        try inst.dir.writeFile(io, .{
            .sub_path = "bin/run.sh",
            .data = "#!/bin/sh\n",
            .flags = .{ .permissions = .executable_file },
        });
        // Deliberately points out of the tree: if set_readonly followed links,
        // the target's write bits would disappear and the harness would see it.
        inst.dir.symLink(io, args[3], "src/outside.link", .{}) catch {};

        try out.print("{t}\n", .{try inst.commit(gpa, io, .{ .retry = .immediate })});
        return;
    }

    return error.UnknownCommand;
}
PROBE_EOF

echo "==> building probe"
# Hermetic per-run cache, as in stdlibs.sh. This one pointed at `.zig-cache`
# relative to $AJT_ROOT, i.e. the package's OWN build cache -- so a gate run
# wrote into, and took zig's lock on, the same directory a concurrent
# `zig build` uses. That is the one concrete sharing this audit found.
( cd "$AJT_ROOT" && zig build-exe --dep ajt \
    -Mroot="$WORK/probe.zig" -Majt=src/root.zig \
    -femit-bin="$WORK/probe" \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: probe build failed" >&2; tail -20 "$WORK/build.log" >&2; exit 2; }
P="$WORK/probe"

# Julia startup is ~0.12 s, so every constant this script needs comes from one
# process. The compiled/ path is `Base.cache_file_entry`'s own answer, not a
# restatement of the format string.
read -r BINDIR JV JV_MAJOR JV_MINOR JULIA_COMPILED <<EOF
$(julia -e '
    e = first(Base.cache_file_entry(Base.PkgId(Base.UUID("00000000-0000-0000-0000-000000000000"), "X")))
    println(Sys.BINDIR, " ", VERSION, " ", VERSION.major, " ", VERSION.minor, " ",
            dirname(joinpath("/d", e)))')
EOF
export AJT_JULIA_BINDIR="$BINDIR"

# The depot to READ from is depots1(), which is exactly what `resolve` answers.
# Deriving it here with `${JULIA_DEPOT_PATH%%:*}` -- as the older harnesses do --
# would reimplement the parse that section 4 exists to prove wrong.
DEPOT="$("$P" depot-path | cut -d'|' -f1)"
[ -n "$DEPOT" ] || { echo "ERROR: no depot to read from" >&2; exit 2; }
echo "depot: $DEPOT"

# ---------------------------------------------------------------------------
# 1. Computed package paths vs julia's, and vs the loader
# ---------------------------------------------------------------------------
echo "==> 1. package paths vs Base.version_slug, the depot, and Base.find_package"

# Corpus: every Manifest.toml this checkout can reach. Manifest entries are the
# only place a (name, uuid, git-tree-sha1) triple exists, and the triple is the
# entire input to the slug.
{ find "$DEPOT/environments" -name 'Manifest.toml' 2>/dev/null
  find "$REPO_ROOT" -name 'Manifest.toml' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null
  for extra in "$@"; do echo "$extra"; done
} | sort -u > "$WORK/manifests.txt"

julia -e '
using TOML
function main(depot, listfile)
    seen = Set{Tuple{String,String,String}}()
    for f in eachline(listfile)
        isempty(f) && continue
        d = try TOML.parsefile(f) catch; continue end
        deps = get(d, "deps", d)          # manifest_format 2.0 nests under "deps"
        deps isa Dict || continue
        for (name, entries) in deps
            entries isa Vector || continue
            for e in entries
                e isa Dict || continue
                (haskey(e, "git-tree-sha1") && haskey(e, "uuid")) || continue
                push!(seen, (String(name), String(e["uuid"]), String(e["git-tree-sha1"])))
            end
        end
    end
    for (n, u, t) in sort(collect(seen))
        println(n, " ", u, " ", t, " ",
                joinpath(depot, "packages", n,
                         Base.version_slug(Base.UUID(u), Base.SHA1(t))))
    end
end
main(ARGS[1], ARGS[2])' "$DEPOT" "$WORK/manifests.txt" > "$WORK/corpus.txt" 2>"$WORK/corpus.err" || {
  echo "ERROR: corpus oracle failed" >&2; tail -5 "$WORK/corpus.err" >&2; exit 2; }

N=$(wc -l < "$WORK/corpus.txt")
[ "$N" -gt 0 ] || {
  echo "ERROR: no manifest-pinned packages found (looked in $(wc -l < "$WORK/manifests.txt") manifests)" >&2
  exit 2; }
echo "  corpus: $N manifest-pinned packages"

cut -d' ' -f4 "$WORK/corpus.txt" > "$WORK/julia_paths.txt"
# shellcheck disable=SC2046
"$P" package-path "$DEPOT" $(cut -d' ' -f1-3 "$WORK/corpus.txt" | tr '\n' ' ') > "$WORK/ajt_paths.txt"
if diff -q "$WORK/julia_paths.txt" "$WORK/ajt_paths.txt" >/dev/null; then
  ok "all $N computed paths equal Base.version_slug's"
else
  fail "computed path diverges from julia:
$(diff "$WORK/julia_paths.txt" "$WORK/ajt_paths.txt" | head -10)"
fi

# At least one of them must exist on disk, or the check above only proved that
# two functions agree — not that julia loads from there.
INSTALLED=0
ANCHOR=""
while read -r name uuid tree path; do
  [ -d "$path" ] || continue
  INSTALLED=$((INSTALLED + 1))
  [ -n "$ANCHOR" ] && continue
  [ -f "$path/src/$name.jl" ] && ANCHOR="$name $uuid $tree $path"
done < "$WORK/corpus.txt"

if [ "$INSTALLED" -eq 0 ]; then
  fail "none of the $N computed paths exists under $DEPOT — nothing anchors the layout to disk"
else
  ok "$INSTALLED of $N are installed at exactly that path"
fi

if [ -z "$ANCHOR" ]; then
  echo "  SKIP no installed package with a src/<Name>.jl to ask the loader about"
else
  read -r A_NAME A_UUID A_TREE A_PATH <<< "$ANCHOR"
  # A throwaway environment pinning exactly this triple, so `find_package`
  # resolves against the real depot with no network and independent of whatever
  # project happens to be active.
  mkdir -p "$WORK/env"
  printf '[deps]\n%s = "%s"\n' "$A_NAME" "$A_UUID" > "$WORK/env/Project.toml"
  cat > "$WORK/env/Manifest.toml" <<EOF
julia_version = "$JV"
manifest_format = "2.0"

[[deps.$A_NAME]]
git-tree-sha1 = "$A_TREE"
uuid = "$A_UUID"
version = "0.0.0"
EOF
  expect_eq \
    "$(julia --project="$WORK/env" -e "println(Base.find_package(\"$A_NAME\"))")" \
    "$A_PATH/src/$A_NAME.jl" \
    "Base.find_package loads $A_NAME from the computed path"
fi

# The other layout constants, each against julia's own answer.
TREE="246a8bb2e6667f832eea063c3a56aef96429a3db"
expect_eq \
  "$("$P" artifact-path /d "$TREE")" \
  "$(JULIA_DEPOT_PATH=/d julia -e "using Artifacts; println(first(Artifacts.artifacts_dirs(\"$TREE\")))")" \
  "artifacts/<hex tree-sha1> == Artifacts.artifacts_dirs"
expect_eq \
  "$("$P" compiled-path /d "$JV_MAJOR" "$JV_MINOR")" \
  "$JULIA_COMPILED" \
  "compiled/v$JV_MAJOR.$JV_MINOR == Base.cache_file_entry (read-only to ajt; julia writes it)"

# ---------------------------------------------------------------------------
# 2. Atomic install into a temp depot
# ---------------------------------------------------------------------------
echo "==> 2. atomic install, mode rules"

T="$WORK/depot"
mkdir -p "$T"
OUTSIDE="$WORK/outside.txt"
echo "writable" > "$OUTSIDE"
chmod 0644 "$OUTSIDE"

FIXTURE_UUID="90137ffa-7385-5640-81b9-e52037218182"
DEST="$("$P" package-path "$T" Fixture "$FIXTURE_UUID" "$TREE")"
expect_eq "$("$P" install "$DEST" "$OUTSIDE")" "installed" "install reported: installed"
[ -d "$DEST" ] && ok "landed at $DEST" || fail "$DEST missing after install"

# `stat` does not follow symlinks; `--` keeps a leading-dash name from being
# read as an option.
mode() { stat -c '%a' -- "$1"; }

expect_eq "$(mode "$DEST/Project.toml")"    "444" "0644 file -> 444 (mode & ~0o222)"
expect_eq "$(mode "$DEST/src/Fixture.jl")"  "444" "nested file -> 444"
expect_eq "$(mode "$DEST/bin/run.sh")"      "555" "0755 file -> 555 (execute bits survive)"
for d in "$DEST" "$DEST/src" "$DEST/bin"; do
  m="$(mode "$d")"
  [ "$(( 0$m & 0200 ))" -ne 0 ] \
    && ok "directory kept its write bit: $(basename "$d") ($m)" \
    || fail "directory $d was made read-only ($m) -- gc/rm would break"
done

if [ -L "$DEST/src/outside.link" ]; then
  expect_eq "$(mode "$DEST/src/outside.link")" "777" "symlink's own mode untouched"
  expect_eq "$(mode "$OUTSIDE")" "644" \
    "symlink target outside the tree still writable -- no chmod followed the link"
else
  echo "  SKIP filesystem refused the symlink"
fi

# ---------------------------------------------------------------------------
# 3. Losing the race is success
# ---------------------------------------------------------------------------
echo "==> 3. concurrent install race"

RACE_DEST="$("$P" package-path "$T" Raced "$FIXTURE_UUID" "$TREE")"
mkdir -p "$RACE_DEST"
echo "theirs" > "$RACE_DEST/theirs.txt"

expect_eq "$("$P" install "$RACE_DEST" "$OUTSIDE")" "already_present" \
  "a taken destination reports: already_present"
[ -f "$RACE_DEST/theirs.txt" ] \
  && ok "the winner's content was left alone" \
  || fail "the winner's content was clobbered"
[ ! -e "$RACE_DEST/Project.toml" ] \
  && ok "our staged content was discarded, not merged" \
  || fail "staged content leaked into a destination we did not win"
LEFTOVER="$(find "$T" -name '.ajt-tmp-*' -print 2>/dev/null)"
[ -z "$LEFTOVER" ] \
  && ok "no .ajt-tmp-* left anywhere under the depot" \
  || fail "staging directories left behind: $LEFTOVER"

# ---------------------------------------------------------------------------
# 4. DEPOT_PATH parsing vs Base.DEPOT_PATH
# ---------------------------------------------------------------------------
echo "==> 4. DEPOT_PATH parsing"

# One line per case: 'U' = unset, 'S' + the value. Kept in step with LABELS.
cat > "$WORK/cases.txt" <<'EOF'
U
S
S/julia-depot:/julia-depot-image
S:/foo
S/foo:
S:
S::/foo
S/a:/a:/b
S~/b:~
Srel/depot
EOF
LABELS=(
  "unset -> ~/.julia + the two bundled depots"
  "empty -> no depot at all"
  "stacked (the RealityForge engine image)"
  "leading empty entry expands bundled IN PLACE and keeps ~/.julia"
  "trailing empty entry appends bundled, no default"
  "':' alone still yields the default depot"
  "empty entries in the middle"
  "duplicates collapse"
  "~ expansion"
  "relative entries are kept verbatim"
)

# `Base.init_depot_path()` rebuilds DEPOT_PATH from ENV on every call, so all
# ten cases fit in one julia process instead of ten.
julia -e '
for line in eachline(ARGS[1])
    if line[1] == '"'"'U'"'"'
        delete!(ENV, "JULIA_DEPOT_PATH")
    else
        ENV["JULIA_DEPOT_PATH"] = line[2:end]
    end
    Base.init_depot_path()
    println(join(Base.DEPOT_PATH, "|"))
end' "$WORK/cases.txt" > "$WORK/julia_depots.txt" || {
  echo "ERROR: DEPOT_PATH oracle failed" >&2; exit 2; }

i=0
while IFS= read -r case_line; do
  want="$(sed -n "$((i + 1))p" "$WORK/julia_depots.txt")"
  if [ "${case_line:0:1}" = "U" ]; then
    got="$(env -u JULIA_DEPOT_PATH "$P" depot-path)"
  else
    got="$(JULIA_DEPOT_PATH="${case_line:1}" "$P" depot-path)"
  fi
  expect_eq "$got" "$want" "${LABELS[$i]}"
  i=$((i + 1))
done < "$WORK/cases.txt"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS — layout, install, race and DEPOT_PATH all agree with julia $JV"
  exit 0
fi
echo "FAILED"
exit 1
