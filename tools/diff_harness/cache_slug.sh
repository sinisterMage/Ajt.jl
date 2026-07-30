#!/usr/bin/env bash
# Differential gate for the precompile cache path.
#
# Ajt's src/cache/slug.zig must reproduce
#   Base.compilecache_path(pkg::PkgId, prefs_hash::UInt64; flags, project)
# (base/loading.jl:3152-3172) exactly. That path is where a shared cache entry
# has to LAND for stock `julia` to find it: the loader globs
# `<depot>/compiled/v1.12/<Name>/<package_slug>_*.ji` and then re-derives this
# slug to pick one (find_all_in_cache_path, loading.jl:1212-1240). Write the
# entry one character off and nothing errors -- Julia silently recompiles the
# package, forever, which is precisely the cost the shared cache exists to
# remove.
#
# WHY THIS GATE IS UNUSUALLY STRONG. A populated depot is its own answer key.
# Every `.ji` on disk was named by Julia from inputs we can read back
# (JLOptions, the cache flags byte, JULIA_CPU_TARGET, the project path), so
# gate 1 does not compare against a re-derivation -- it asserts that a file
# EXISTS at the path Ajt computes, for every package in a real ~213-entry
# environment. Nothing in the harness can accidentally agree with a bug.
#
# The three gates, and what each one would catch:
#
#   1. filesystem  -- every manifest package's computed path exists on disk.
#                     Catches any error in the chain, the base-62 rendering,
#                     the `<Name>` directory or the `<pkgslug>_` prefix.
#   2. oracle      -- Base.compilecache_path (and, for the two inputs it cannot
#                     vary from inside a running julia, the raw Base._crc32c
#                     chain) returns the same string for the same inputs.
#   3. sensitivity -- JULIA_CPU_TARGET, the project path, the julia binary, the
#                     sysimage, the flags byte and prefs_hash each move the
#                     slug, and changing nothing keeps it. A slug that ignored
#                     one of its inputs would collide across machines, and the
#                     collision is silent: the runtime would load a cache built
#                     for a different sysimage.
#
# Gate 3's JULIA_CPU_TARGET case is the one to care about in production. The
# variable is crc32c'd into the slug, so build time and run time disagreeing on
# it is a total, silent cache miss; backend/Dockerfile:137 pins it as an image
# ENV for exactly that reason.
#
# Usage: tools/diff_harness/cache_slug.sh [--keep] [--verbose] [<env-dir>]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
VERBOSE=0
ENV_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) ENV_DIR="$1"; shift ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-cacheslug-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- 0. confirm the oracle exists, with the signature we are about to call ---
# A gate that quietly tests nothing is worse than no gate.
echo "==> oracle entry point"
if ! julia --startup-file=no -e '
    ms = methods(Base.compilecache_path)
    want = "compilecache_path(pkg::Base.PkgId, prefs_hash::UInt64;"
    any(m -> occursin(want, string(m)), ms) || begin
        println(stderr, "Base.compilecache_path does not have the expected signature.")
        for m in ms; println(stderr, "  ", m); end
        exit(1)
    end
    isdefined(Base, :_crc32c) && isdefined(Base, :slug) && isdefined(Base, :package_slug) ||
        (println(stderr, "Base._crc32c / Base.slug / Base.package_slug missing"); exit(1))
    println("  Base.", want, " …)")
'; then
  echo "ERROR: no usable Julia entry point — refusing to pretend this gate ran" >&2
  exit 2
fi

# --- 1. this machine's JLOptions, which ARE the inputs -----------------------
julia --startup-file=no -e '
  using Base: JLOptions, CacheFlags, _cacheflag_to_uint8
  println("IMAGE=",   unsafe_string(JLOptions().image_file))
  println("BIN=",     unsafe_string(JLOptions().julia_bin))
  println("JLCPU=",   unsafe_string(JLOptions().cpu_target))
  println("FLAGS=",   Int(_cacheflag_to_uint8(CacheFlags())))
  println("DEPOT=",   Base.DEPOT_PATH[1])
  println("MAJOR=",   VERSION.major)
  println("MINOR=",   VERSION.minor)
  println("ACTIVE=",  something(Base.active_project(), ""))
' > "$WORK/opts" || { echo "ERROR: could not read JLOptions" >&2; exit 2; }
# shellcheck disable=SC1090
. "$WORK/opts" 2>/dev/null || {
  # Values contain characters `.` would choke on only if they held quotes; read
  # them field-by-field instead of sourcing, to be safe.
  :
}
get_opt() { sed -n "s/^$1=//p" "$WORK/opts"; }
IMAGE="$(get_opt IMAGE)"
BIN="$(get_opt BIN)"
JLCPU="$(get_opt JLCPU)"
FLAGS="$(get_opt FLAGS)"
DEPOT="$(get_opt DEPOT)"
MAJOR="$(get_opt MAJOR)"
MINOR="$(get_opt MINOR)"
ACTIVE="$(get_opt ACTIVE)"
CPU="${JULIA_CPU_TARGET-$JLCPU}"
COMPILED="$DEPOT/compiled/v$MAJOR.$MINOR"

echo "  depot      : $DEPOT"
echo "  image_file : $IMAGE"
echo "  julia_bin  : $BIN"
echo "  cpu_target : $CPU"
echo "  flags byte : $FLAGS"

# --- 2. driver ---------------------------------------------------------------
# main.zig gets no cache subcommand this round, so the harness compiles its own
# thin driver against the library module (same shape as preferences.sh).
cat > "$WORK/driver.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");
const cslug = ajt.cache.slug;

/// Prints one TSV line per (package, project) pair:
///   <name>\t<project>\t<path>
/// Everything else is fixed by flags. `--pkg Name` (no colon) models a
/// PkgId with no UUID.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var depot_root: []const u8 = "";
    var major: u32 = 1;
    var minor: u32 = 12;
    var image: []const u8 = "";
    var bin: []const u8 = "";
    var cpu: []const u8 = "";
    var flag_byte: u8 = 0xa3;
    var prefs: u64 = 0;
    var trace = false;
    var projects: std.ArrayList([]const u8) = .empty;
    var pkgs: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            depot_root = args[i];
        } else if (std.mem.eql(u8, a, "--major")) {
            i += 1;
            major = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--minor")) {
            i += 1;
            minor = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--image")) {
            i += 1;
            image = args[i];
        } else if (std.mem.eql(u8, a, "--bin")) {
            i += 1;
            bin = args[i];
        } else if (std.mem.eql(u8, a, "--cpu")) {
            i += 1;
            cpu = args[i];
        } else if (std.mem.eql(u8, a, "--flags")) {
            i += 1;
            flag_byte = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, a, "--prefs")) {
            i += 1;
            prefs = try std.fmt.parseInt(u64, args[i], 0);
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            try projects.append(arena, args[i]);
        } else if (std.mem.eql(u8, a, "--pkg")) {
            i += 1;
            try pkgs.append(arena, args[i]);
        } else if (std.mem.eql(u8, a, "--trace")) {
            trace = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.BadUsage;
        }
    }

    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    const dep: ajt.depot.Depot = .{ .root = depot_root };
    for (pkgs.items) |spec| {
        const sep = std.mem.indexOfScalar(u8, spec, ':');
        const name = if (sep) |s| spec[0..s] else spec;
        const pkg: cslug.PkgId = .{
            .name = name,
            .uuid = if (sep) |s| try cslug.Uuid.parse(spec[s + 1 ..]) else null,
        };
        for (projects.items) |project| {
            const in: cslug.Inputs = .{
                .project = project,
                .image_file = image,
                .julia_bin = bin,
                .flags = cslug.Flags.fromByte(flag_byte),
                .cpu_target = cpu,
                .prefs_hash = prefs,
            };
            const path = try cslug.cachePath(arena, dep, major, minor, pkg, in);
            try out.print("{s}\t{s}\t{s}\n", .{ name, project, path });
            if (trace) {
                const text = try cslug.crcTrace(arena, in);
                try out.writeAll(text);
            }
        }
    }
    try out.flush();
}
ZIG

echo "==> building driver"
# Hermetic per-run cache, as in preferences.sh / stdlibs.sh.
zig build-exe -ODebug --name cache_slug_driver \
  --dep ajt -Mroot="$WORK/driver.zig" -Majt="$AJT_ROOT/src/root.zig" \
  --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
  -femit-bin="$WORK/cache_slug_driver" \
  || { echo "ERROR: driver failed to build" >&2; exit 2; }
DRIVER="$WORK/cache_slug_driver"

ok=0
bad=0
note() { printf '  FAIL %s\n' "$1"; bad=$((bad + 1)); }
pass() { ok=$((ok + 1)); [ $VERBOSE -eq 1 ] && printf '  ok   %s\n' "$1"; return 0; }

# =============================================================================
# Gate 1 — a populated depot is its own answer key
# =============================================================================
echo
echo "==> gate 1: real depot, every package, every candidate project"

# Pick the environment to enumerate. Order matters only for the default; an
# explicit argument always wins.
if [ -z "$ENV_DIR" ]; then
  # A git worktree shares a depot with its main checkout, and the main checkout
  # is the path Julia saw when it precompiled -- the project path is hashed, so
  # the worktree copy of the same tree has a DIFFERENT slug and explains
  # nothing. Prefer the common checkout, fall back to this one.
  MAIN_CHECKOUT=""
  if COMMON="$(git -C "$AJT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    MAIN_CHECKOUT="$(dirname "$COMMON")"
  fi
  for cand in "$MAIN_CHECKOUT/Open-Reality" "$AJT_ROOT/../../Open-Reality"; do
    if [ -f "$cand/Manifest.toml" ]; then ENV_DIR="$(cd "$cand" && pwd)"; break; fi
  done
fi

SKIP_REASON=""
[ -d "$COMPILED" ] || SKIP_REASON="no precompile cache at $COMPILED"
if [ -z "$SKIP_REASON" ] && [ -z "$(find "$COMPILED" -name '*.ji' -print -quit 2>/dev/null)" ]; then
  SKIP_REASON="no .ji files under $COMPILED (empty depot)"
fi
[ -z "$SKIP_REASON" ] && [ -z "$ENV_DIR" ] && SKIP_REASON="no environment with a Manifest.toml found"

if [ -n "$SKIP_REASON" ]; then
  echo
  echo "###########################################################################"
  echo "#  SKIP — $SKIP_REASON"
  echo "#"
  echo "#  Gate 1 needs a POPULATED depot: it asserts that a file exists at the"
  echo "#  path Ajt computes, which is only an oracle if Julia has actually"
  echo "#  precompiled something there. Populate one with, from an environment:"
  echo "#      julia --project=<env> -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'"
  echo "#  then re-run. Gates 2 and 3 do not need it and still ran below."
  echo "###########################################################################"
  echo
  GATE1=skipped
else
  GATE1=ran
  echo "  environment: $ENV_DIR"

  # The candidate projects a .ji in this depot could have been named from.
  # Julia hashes the project path STRING, so each distinct path is a distinct
  # slug -- listing them is the only way to explain a shared depot that several
  # environments have precompiled into.
  CANDS=("$ENV_DIR/Project.toml")
  [ -n "$ACTIVE" ] && CANDS+=("$ACTIVE")
  CANDS+=("")
  if [ -n "${AJT_CACHE_PROJECTS:-}" ]; then
    while IFS= read -r extra; do [ -n "$extra" ] && CANDS+=("$extra"); done \
      <<< "$(printf '%s' "$AJT_CACHE_PROJECTS" | tr ':' '\n')"
  fi

  # name<TAB>uuid for every manifest entry that already has a compiled/
  # directory. The filter is not laziness: Base.compilecache_path MKPATHS its
  # parent (loading.jl:3155), so asking it about a package this machine never
  # precompiled would leave empty directories behind in the user's ~/.julia.
  # Restricted to directories that already exist, the oracle is a pure read.
  julia --startup-file=no --compiled-modules=no -e '
    using TOML
    d = TOML.parsefile(ARGS[1])
    compiled = ARGS[2]
    haskey(d, "deps") || exit(0)
    for (name, entries) in d["deps"], e in entries
        haskey(e, "uuid") || continue
        println(name, "\t", e["uuid"], "\t", isdir(joinpath(compiled, name)) ? "y" : "n")
    end
  ' "$ENV_DIR/Manifest.toml" "$COMPILED" | LC_ALL=C sort > "$WORK/pkgs.tsv" \
    || { echo "ERROR: could not read $ENV_DIR/Manifest.toml" >&2; exit 2; }

  awk -F'\t' '$3 == "y" { print $1 "\t" $2 }' "$WORK/pkgs.tsv" > "$WORK/pkgs.cached.tsv"
  total=$(wc -l < "$WORK/pkgs.tsv" | tr -d ' ')
  cached=$(wc -l < "$WORK/pkgs.cached.tsv" | tr -d ' ')

  PKG_ARGS=()
  while IFS=$'\t' read -r name uuid; do PKG_ARGS+=(--pkg "$name:$uuid"); done < "$WORK/pkgs.cached.tsv"
  PROJ_ARGS=()
  for c in "${CANDS[@]}"; do PROJ_ARGS+=(--project "$c"); done

  if [ "$cached" -eq 0 ]; then
    note "gate 1: no manifest package has a compiled/ directory — nothing to check"
  else
    # Ajt's answer for every (package, candidate project) pair, in one process.
    "$DRIVER" --depot "$DEPOT" --major "$MAJOR" --minor "$MINOR" \
      --image "$IMAGE" --bin "$BIN" --cpu "$CPU" --flags "$FLAGS" --prefs 0 \
      "${PROJ_ARGS[@]}" "${PKG_ARGS[@]}" | LC_ALL=C sort > "$WORK/ajt.paths.tsv" \
      || { echo "ERROR: driver failed on gate 1" >&2; exit 2; }

    # Julia's answer for the same pairs, also in one process. This is the
    # oracle; `isfile` below is the independent confirmation that the oracle
    # itself describes reality.
    {
      printf '%s\n' "${CANDS[@]}" > "$WORK/cands.txt"
      cut -f1,2 "$WORK/pkgs.cached.tsv" > "$WORK/pairs.tsv"
    }
    julia --startup-file=no --compiled-modules=no -e '
      pairs = ARGS[1]; cands = ARGS[2]
      projects = readlines(cands)
      for line in eachline(pairs)
          name, uuid = split(line, "\t")
          pkg = Base.PkgId(Base.UUID(uuid), name)
          for p in projects
              println(name, "\t", p, "\t", Base.compilecache_path(pkg, UInt64(0); project = p))
          end
      end
    ' "$WORK/pairs.tsv" "$WORK/cands.txt" | LC_ALL=C sort > "$WORK/jl.paths.tsv" \
      || { echo "ERROR: Julia oracle failed on gate 1" >&2; exit 2; }

    pairs=$(wc -l < "$WORK/ajt.paths.tsv" | tr -d ' ')
    if diff -u "$WORK/jl.paths.tsv" "$WORK/ajt.paths.tsv" > "$WORK/gate1.diff"; then
      pass "gate 1: $pairs (package, project) pairs agree with Base.compilecache_path"
    else
      note "gate 1: Ajt and Base.compilecache_path disagree ($(grep -c '^-[^-]' "$WORK/gate1.diff") lines)"
      echo "       --- julia (-) vs ajt (+) ---"
      head -40 "$WORK/gate1.diff" | sed 's/^/       /'
    fi

    # ...and now the part no re-derivation can fake: the file is there.
    hit=0; unexplained=0
    : > "$WORK/gate1.byproject"
    : > "$WORK/gate1.unexplained"
    while IFS=$'\t' read -r name uuid; do
      found=""
      while IFS=$'\t' read -r n proj path; do
        [ "$n" = "$name" ] || continue
        if [ -f "$path" ]; then found="${proj:-<empty project>}"; break; fi
      done < <(awk -F'\t' -v n="$name" '$1 == n' "$WORK/ajt.paths.tsv")
      if [ -n "$found" ]; then
        hit=$((hit + 1))
        printf '%s\n' "$found" >> "$WORK/gate1.byproject"
      else
        unexplained=$((unexplained + 1))
        printf '%s\thave: %s\n' "$name" \
          "$(ls "$COMPILED/$name" 2>/dev/null | grep '\.ji$' | tr '\n' ' ')" \
          >> "$WORK/gate1.unexplained"
      fi
    done < "$WORK/pkgs.cached.tsv"

    echo "  manifest entries          : $total"
    echo "  with a compiled/ dir      : $cached"
    echo "  computed path EXISTS      : $hit"
    echo "  precompiled by some other environment : $unexplained"
    if [ -s "$WORK/gate1.byproject" ]; then
      echo "  confirmed by project:"
      LC_ALL=C sort "$WORK/gate1.byproject" | uniq -c | sed 's/^/    /'
    fi
    if [ "$unexplained" -gt 0 ] && [ $VERBOSE -eq 1 ]; then
      # NOT a failure. A depot is shared and mutable: any other environment on
      # this machine (a different project path, JULIA_CPU_TARGET or
      # --pkgimages setting) writes entries under slugs this harness was never
      # told about. Listing them is informative; failing on them would make the
      # gate flap for reasons that have nothing to do with Ajt.
      echo "  (entries from environments not in the candidate list:)"
      sed 's/^/    /' "$WORK/gate1.unexplained"
    fi

    if [ "$hit" -eq 0 ]; then
      note "gate 1: NOT ONE computed path exists — the crc chain is producing slugs no julia ever wrote"
      sed 's/^/    /' "$WORK/gate1.unexplained" | head -10
    else
      pass "gate 1: $hit precompiled packages land on a real .ji, at exactly the computed path"
    fi
  fi
fi

# =============================================================================
# Gate 2 — Base.compilecache_path, and the raw _crc32c chain
# =============================================================================
echo
echo "==> gate 2a: Base.compilecache_path agreement"

# Run Julia's side against a THROWAWAY depot: compilecache_path mkpath's its
# parent (loading.jl:3155), and a gate must not mutate the user's ~/.julia.
TMPDEPOT="$WORK/depot"
mkdir -p "$TMPDEPOT"

# project|prefs_hash|flags|cpu_target|name|uuid
#
# The delimiter is `|`, not a tab, and that is not cosmetic: `read` strips
# leading and trailing IFS *whitespace*, so `IFS=$'\t'` silently drops an empty
# first or last field and shifts every case that tests the empty project or the
# UUID-less PkgId. `|` is not whitespace, so empty fields survive.
ARK_UUID=56664e29-41e4-4ea5-ab0e-825499acc647
SA_UUID=90137ffa-7385-5640-81b9-e52037218182
cat > "$WORK/cases2.psv" <<EOF
${ENV_DIR:-/p}/Project.toml|0|$FLAGS|$CPU|StaticArrays|$SA_UUID
$ACTIVE|0|$FLAGS|$CPU|StaticArrays|$SA_UUID
|0|$FLAGS|$CPU|StaticArrays|$SA_UUID
/p/Project.toml|0|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|1|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|18446744073709551615|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|15817167442847469773|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|72623859790382856|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|163|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|162|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|0|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|255|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|129|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|$FLAGS|generic;haswell,clone_all|Ark|$ARK_UUID
/p/Project.toml|0|$FLAGS|native|Ark|$ARK_UUID
/p/Project.toml|0|$FLAGS|generic|Ark|$ARK_UUID
/p/Project.toml|0|$FLAGS||Ark|$ARK_UUID
/a path/with spaces/Project.toml|0|$FLAGS|$CPU|Ark|$ARK_UUID
/unicode/naïve✓/Project.toml|0|$FLAGS|$CPU|Ark|$ARK_UUID
/p/Project.toml|0|$FLAGS|$CPU|MyScript|
EOF

while IFS='|' read -r project prefs flags cpu name uuid; do
  label="project=${project:-<empty>} prefs=$prefs flags=$flags cpu=${cpu:-<empty>} pkg=$name"

  jl=$(JULIA_DEPOT_PATH="$TMPDEPOT" JULIA_CPU_TARGET="$cpu" julia --startup-file=no -e '
    project, prefs, flags, name, uuid = ARGS
    pkg = isempty(uuid) ? Base.PkgId(name) : Base.PkgId(Base.UUID(uuid), name)
    println(Base.compilecache_path(pkg, parse(UInt64, prefs);
                                   flags = Base.CacheFlags(parse(UInt8, flags)),
                                   project = project))
  ' "$project" "$prefs" "$flags" "$name" "$uuid" 2>"$WORK/jl.err")
  if [ -z "$jl" ]; then
    note "$label — Julia oracle errored"
    sed 's/^/       /' "$WORK/jl.err" | head -5
    continue
  fi

  spec="$name"; [ -n "$uuid" ] && spec="$name:$uuid"
  aj=$("$DRIVER" --depot "$TMPDEPOT" --major "$MAJOR" --minor "$MINOR" \
        --image "$IMAGE" --bin "$BIN" --cpu "$cpu" --flags "$flags" --prefs "$prefs" \
        --project "$project" --pkg "$spec" 2>"$WORK/aj.err" | cut -f3)

  if [ "$jl" = "$aj" ]; then
    pass "$label"
  else
    note "$label"
    echo "       julia : $jl"
    echo "       ajt   : ${aj:-<no output>}"
    [ -s "$WORK/aj.err" ] && sed 's/^/       /' "$WORK/aj.err" | head -5
    "$DRIVER" --depot "$TMPDEPOT" --major "$MAJOR" --minor "$MINOR" \
      --image "$IMAGE" --bin "$BIN" --cpu "$cpu" --flags "$flags" --prefs "$prefs" \
      --project "$project" --pkg "$spec" --trace 2>&1 | tail -n +2 | sed 's/^/       /'
  fi
done < "$WORK/cases2.psv"

echo
echo "==> gate 2b: raw Base._crc32c chain (varies image_file and julia_bin,"
echo "             which compilecache_path cannot change from inside a julia)"

# project|image|bin|flags|cpu|prefs   (`|` for the reason given above)
cat > "$WORK/cases2b.psv" <<'EOF'
/p/Project.toml|/i/sys.so|/b/julia|163|native|0
/p/Project.toml|/i2/sys.so|/b/julia|163|native|0
/p/Project.toml|/i/sys.so|/b2/julia|163|native|0
/home/runner/work/rf/rf/Open-Reality/Project.toml|/opt/hostedtoolcache/julia/1.12.6/x64/lib/julia/sys.so|/opt/hostedtoolcache/julia/1.12.6/x64/bin/julia|163|generic;haswell,clone_all|0
/engine/Project.toml|/usr/local/julia/lib/julia/sys.so|/usr/local/julia/bin/julia|163|generic;haswell,clone_all|0
/engine/Project.toml|/usr/local/julia/lib/julia/sys.so|/usr/local/julia/bin/julia|163|generic;haswell,clone_all|72623859790382856
|||0||0
/p/Project.toml|/i/sys.so|/b/julia|163|native|18446744073709551615
/p/Project.toml|/i/sys.so|/b/julia|255|native|1
EOF

while IFS='|' read -r project image bin flags cpu prefs; do
  label="chain project=${project:-<empty>} bin=${bin:-<empty>} cpu=${cpu:-<empty>} prefs=$prefs flags=$flags"
  jl=$(julia --startup-file=no -e '
    using Base: _crc32c, slug
    project, image, bin, flags, cpu, prefs = ARGS
    crc = _crc32c(project)
    crc = _crc32c(image, crc)
    crc = _crc32c(bin, crc)
    crc = _crc32c(parse(UInt8, flags), crc)
    crc = _crc32c(cpu, crc)
    crc = _crc32c(parse(UInt64, prefs), crc)
    println(slug(crc, 5))
  ' "$project" "$image" "$bin" "$flags" "$cpu" "$prefs" 2>"$WORK/jl.err")
  if [ -z "$jl" ]; then
    note "$label — Julia oracle errored"
    sed 's/^/       /' "$WORK/jl.err" | head -5
    continue
  fi

  # The driver only prints whole paths; the slug is the part after the '_'.
  aj=$("$DRIVER" --depot /d --major "$MAJOR" --minor "$MINOR" \
        --image "$image" --bin "$bin" --cpu "$cpu" --flags "$flags" --prefs "$prefs" \
        --project "$project" --pkg "Ark:56664e29-41e4-4ea5-ab0e-825499acc647" 2>"$WORK/aj.err" \
        | cut -f3 | sed 's|.*_||; s|\.ji$||')

  if [ "$jl" = "$aj" ]; then
    pass "$label = $jl"
  else
    note "$label"
    echo "       julia : $jl"
    echo "       ajt   : ${aj:-<no output>}"
    [ -s "$WORK/aj.err" ] && sed 's/^/       /' "$WORK/aj.err" | head -5
  fi
done < "$WORK/cases2b.psv"

# =============================================================================
# Gate 3 — sensitivity
# =============================================================================
echo
echo "==> gate 3: every input moves the slug (and nothing else does)"

ARK="Ark:56664e29-41e4-4ea5-ab0e-825499acc647"
slug_of() {  # slug_of <project> <image> <bin> <flags> <cpu> <prefs>
  "$DRIVER" --depot /d --major "$MAJOR" --minor "$MINOR" \
    --image "$2" --bin "$3" --cpu "$5" --flags "$4" --prefs "$6" \
    --project "$1" --pkg "$ARK" | cut -f3 | sed 's|.*_||; s|\.ji$||'
}

BASE_SLUG="$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 163 "native" 0)"
[ -n "$BASE_SLUG" ] || { echo "ERROR: driver produced no slug" >&2; exit 2; }

differs() {  # differs <label> <slug>
  if [ "$2" = "$BASE_SLUG" ]; then
    note "gate 3: changing $1 did NOT change the slug ($2) — that input is ignored"
  else
    pass "gate 3: $1 changes the slug ($BASE_SLUG -> $2)"
  fi
}

differs "JULIA_CPU_TARGET (native -> generic;haswell,clone_all)" \
  "$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 163 "generic;haswell,clone_all" 0)"
differs "JULIA_CPU_TARGET (native -> generic)" \
  "$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 163 "generic" 0)"
differs "the project path" \
  "$(slug_of "/other/Project.toml" "/i/sys.so" "/b/julia" 163 "native" 0)"
differs "a trailing slash on the project path" \
  "$(slug_of "/p/Project.toml/" "/i/sys.so" "/b/julia" 163 "native" 0)"
differs "the julia binary path" \
  "$(slug_of "/p/Project.toml" "/i/sys.so" "/b2/julia" 163 "native" 0)"
differs "the sysimage path" \
  "$(slug_of "/p/Project.toml" "/i2/sys.so" "/b/julia" 163 "native" 0)"
differs "the cache-flags byte" \
  "$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 162 "native" 0)"
differs "prefs_hash" \
  "$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 163 "native" 1)"

SAME="$(slug_of "/p/Project.toml" "/i/sys.so" "/b/julia" 163 "native" 0)"
if [ "$SAME" = "$BASE_SLUG" ]; then
  pass "gate 3: identical inputs give an identical slug ($SAME)"
else
  note "gate 3: the slug is not a function of its inputs ($BASE_SLUG vs $SAME)"
fi

# The real-world statement of the same fact: two machines, same project name,
# different install prefixes -> different slugs. That is EXPECTED, and it is
# why a shared cache must be written at the LOCAL slug rather than shipped
# with a slug baked in.
CI_SLUG="$(slug_of "/home/runner/work/rf/rf/Open-Reality/Project.toml" \
  "/opt/hostedtoolcache/julia/1.12.6/x64/lib/julia/sys.so" \
  "/opt/hostedtoolcache/julia/1.12.6/x64/bin/julia" 163 "generic;haswell,clone_all" 0)"
IMG_SLUG="$(slug_of "/engine/Project.toml" \
  "/usr/local/julia/lib/julia/sys.so" "/usr/local/julia/bin/julia" \
  163 "generic;haswell,clone_all" 0)"
if [ "$CI_SLUG" != "$IMG_SLUG" ]; then
  pass "gate 3: CI ($CI_SLUG) and the engine image ($IMG_SLUG) disagree, as they must"
else
  note "gate 3: CI and the engine image produced the SAME slug — the install prefix is not being hashed"
fi

# =============================================================================
echo
echo "  agree   : $ok"
echo "  diverge : $bad"
[ "$GATE1" = "skipped" ] && echo "  (gate 1 skipped — see the banner above)"

if [ "$bad" -gt 0 ]; then
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the driver and fixtures)"
  exit 1
fi

echo
echo "PASS — ajt's compilecache path matches Julia across $ok checks"
