#!/usr/bin/env bash
# Differential gate for the Manifest.toml v2 model (src/model/manifest.zig).
#
# Manifest.toml is the file stock `julia` reads to locate every package it
# loads, so "Ajt can rewrite one without changing it" is the single most
# load-bearing property in the project. This gate proves it four ways against
# the real Open-Reality manifest (214 entries):
#
#   1. Byte identity. Parse into the MODEL, `destructure` back to a raw table,
#      emit sorted -- and diff against
#      `TOML.print(stdout, TOML.parsefile(f); sorted=true)`.
#      Comparing against the raw TOML round-trip rather than against Pkg's own
#      `destructure` is deliberate: it catches data Pkg itself drops (it loses
#      `entryfile`, see the header of manifest.zig), and Pkg's destructure was
#      separately confirmed to agree with the raw round-trip on this file.
#
#   2. Counters. Ajt's view of the file (entries, tree hashes, JLLs, extension
#      blocks, dep encodings) must equal an independent Julia count taken
#      straight off `TOML.parsefile`.
#
#   3. Both dep encodings are exercised. `deps`/`weakdeps` may be an array of
#      names or a name->UUID table (`Pkg/src/manifest.jl:338-345`), and this
#      file contains both -- ColorTypes writes `weakdeps = ["StyledStrings"]`
#      while ColorVectorSpace writes a `[deps.ColorVectorSpace.weakdeps]`
#      table for SpecialFunctions, which is not in the manifest. A gate that
#      only ever saw one form would not notice the other regressing.
#      Likewise both `extensions` value shapes (String and Vector{String}).
#
#   4. The `!(git-tree-sha1 && path)` invariant Pkg asserts (`:314`) holds for
#      every entry. `OpenReality` itself is the `path = "."` case.
#
# Usage:
#   tools/diff_harness/manifest_model.sh [manifest.toml...]
#
# The engine manifest is ALWAYS checked and is always what steps 2-4 run
# against; extra paths are added to step 1 only. That split is deliberate on
# both counts:
#
#   * the step-4 reference counts are specific to this manifest, and
#   * step 2 compares a count taken off the RAW file against one taken off
#     Ajt's DESTRUCTURED table, which only have to agree for a file Pkg itself
#     wrote. `destructure` legitimately re-encodes a hand-edited file — a
#     strong dep spelled as a table whose name is unique in the manifest comes
#     back as an array — and step 1 has the matching caveat (`deps = []` and
#     `julia_flags = []` are dropped by Pkg AND by Ajt, but preserved by a raw
#     TOML round-trip).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
ENGINE_MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"

# Recorded state of the engine manifest. A drift here is a NOTE, not a
# failure: `Pkg.update` legitimately moves these, and the Julia-vs-Ajt
# comparison above is what actually gates.
REF_ENTRIES=214
REF_TREE_HASH=170
REF_JLL=98
REF_EXT_BLOCKS=19
REF_JULIA_VERSION="1.12.6"
REF_PROJECT_HASH="5e05dae87664a72319978725911531ada717de0f"

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

[ -f "$ENGINE_MANIFEST" ] || { echo "ERROR: $ENGINE_MANIFEST missing" >&2; exit 2; }
FILES=("$ENGINE_MANIFEST")
if [ $# -gt 0 ]; then
  for f in "$@"; do
    [ "$f" = "$ENGINE_MANIFEST" ] || FILES+=("$f")
  done
fi

WORK="$(mktemp -d -t ajt-manifest-XXXXXX)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# --- driver -----------------------------------------------------------------
# `ajt` the CLI has no manifest subcommand yet, so the harness compiles a
# throwaway front-end against the library module. Same code path a real
# subcommand would take.
cat > "$WORK/driver.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");
const manifest = ajt.model.manifest;
const Value = ajt.toml.Value;
const Table = ajt.toml.Table;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 3) {
        std.debug.print("usage: driver <fmt|stats> <Manifest.toml>\n", .{});
        return error.MissingArgument;
    }
    const mode = args[1];
    const path = args[2];

    const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(src);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: ajt.toml.Diagnostic = .{};
    const m = manifest.parse(arena, src, &diag) catch |err| {
        std.debug.print("{s}: {s} ({f})\n", .{ path, @errorName(err), diag });
        return err;
    };

    // `destructure` itself enforces `!(git-tree-sha1 && path)` (manifest.jl:314),
    // so reaching this line already proves the invariant for every entry. It is
    // still counted below so the harness can assert a number rather than infer
    // one from the absence of an error.
    const raw = try m.destructure(arena);

    if (std.mem.eql(u8, mode, "fmt")) {
        try ajt.toml.emit(gpa, out, raw, .{ .sorted = true });
        try out.flush();
        return;
    }
    if (!std.mem.eql(u8, mode, "stats")) {
        std.debug.print("unknown mode '{s}'\n", .{mode});
        return error.UnknownCommand;
    }

    var s: struct {
        entries: usize = 0,
        unique_names: usize = 0,
        tree_hash: usize = 0,
        path: usize = 0,
        tree_hash_and_path: usize = 0,
        jll: usize = 0,
        ext_blocks: usize = 0,
        ext_string_values: usize = 0,
        ext_vector_values: usize = 0,
        deps_array_form: usize = 0,
        deps_table_form: usize = 0,
        weakdeps_array_form: usize = 0,
        weakdeps_table_form: usize = 0,
    } = .{};

    // Model-side facts.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (m.entries) |e| {
        s.entries += 1;
        if (e.tree_hash != null) s.tree_hash += 1;
        if (e.path != null) s.path += 1;
        if (e.tree_hash != null and e.path != null) s.tree_hash_and_path += 1;
        if (std.mem.endsWith(u8, e.name, "_jll")) s.jll += 1;
        try seen.put(arena, e.name, {});
    }
    s.unique_names = seen.count();

    // Encoding facts, read back off the DESTRUCTURED table so they describe
    // what would actually be written, not what the model happens to hold.
    // A format-1 manifest has no `deps` wrapper -- the root IS the deps table
    // (Pkg/src/manifest.jl:295-296, :368-369). Three of those live in a stock
    // depot, so `stats` has to cope.
    const deps_tbl: *const Table = if (m.format.major == 1) raw else switch (raw.get("deps") orelse Value{ .integer = 0 }) {
        .table => |t| t,
        else => return error.MalformedManifest,
    };
    for (deps_tbl.entries.items) |named| {
        const arr = switch (named.value) {
            .array => |a| a,
            else => continue,
        };
        for (arr) |ev| {
            const et = switch (ev) {
                .table => |t| t,
                else => continue,
            };
            if (et.get("deps")) |dv| switch (dv) {
                .array => s.deps_array_form += 1,
                .table => s.deps_table_form += 1,
                else => {},
            };
            if (et.get("weakdeps")) |wv| switch (wv) {
                .array => s.weakdeps_array_form += 1,
                .table => s.weakdeps_table_form += 1,
                else => {},
            };
            if (et.get("extensions")) |xv| switch (xv) {
                .table => |xt| {
                    s.ext_blocks += 1;
                    for (xt.entries.items) |x| switch (x.value) {
                        .string => s.ext_string_values += 1,
                        .array => s.ext_vector_values += 1,
                        else => {},
                    };
                },
                else => {},
            };
        }
    }

    // Sorted key=value, so the harness can plain-diff it against Julia's.
    try out.print("deps_array_form={d}\n", .{s.deps_array_form});
    try out.print("deps_table_form={d}\n", .{s.deps_table_form});
    try out.print("entries={d}\n", .{s.entries});
    try out.print("ext_blocks={d}\n", .{s.ext_blocks});
    try out.print("ext_string_values={d}\n", .{s.ext_string_values});
    try out.print("ext_vector_values={d}\n", .{s.ext_vector_values});
    try out.print("jll={d}\n", .{s.jll});
    if (m.julia_version) |v| {
        try out.print("julia_version={f}\n", .{v});
    } else {
        try out.print("julia_version=<none>\n", .{});
    }
    try out.print("manifest_format={d}.{d}\n", .{ m.format.major, m.format.minor });
    try out.print("path={d}\n", .{s.path});
    if (m.project_hash) |h| {
        var buf: [40]u8 = undefined;
        try out.print("project_hash={s}\n", .{manifest.formatSha1(h, &buf)});
    } else {
        try out.print("project_hash=<none>\n", .{});
    }
    try out.print("tree_hash={d}\n", .{s.tree_hash});
    try out.print("tree_hash_and_path={d}\n", .{s.tree_hash_and_path});
    try out.print("unique_names={d}\n", .{s.unique_names});
    try out.print("weakdeps_array_form={d}\n", .{s.weakdeps_array_form});
    try out.print("weakdeps_table_form={d}\n", .{s.weakdeps_table_form});
    try out.flush();
}
ZIG

echo "==> building driver"
# Hermetic per-run cache, as in stdlibs.sh. The local cache was already
# contained; the global one was still shared with every other zig on the box.
zig build-exe \
  --dep ajt \
  -Mroot="$WORK/driver.zig" \
  -Majt="$AJT_ROOT/src/root.zig" \
  -femit-bin="$WORK/driver" \
  --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" >"$WORK/build.log" 2>&1 || {
    echo "ERROR: driver failed to build" >&2; cat "$WORK/build.log" >&2; exit 2; }
DRIVER="$WORK/driver"

# --- 1. byte identity -------------------------------------------------------
fail=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "ERROR: no such file: $f" >&2; exit 2; }
  echo "==> $f"

  julia -e '
      using TOML
      TOML.print(stdout, TOML.parsefile(ARGS[1]); sorted = true)
  ' "$f" > "$WORK/julia.out" 2>"$WORK/julia.err" || {
      echo "ERROR: julia oracle failed" >&2; tail -5 "$WORK/julia.err" >&2; exit 2; }

  if ! "$DRIVER" fmt "$f" > "$WORK/ajt.out" 2>"$WORK/ajt.err"; then
    echo "  FAIL: ajt could not round-trip it"; sed 's/^/    /' "$WORK/ajt.err"; fail=1; continue
  fi

  if cmp -s "$WORK/julia.out" "$WORK/ajt.out"; then
    echo "  byte-identical to TOML.print ($(wc -c < "$WORK/ajt.out") bytes)"
  else
    echo "  FAIL: model round-trip diverges from Julia"
    diff "$WORK/julia.out" "$WORK/ajt.out" | head -20 | sed 's/^/    /'
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo; echo "FAIL — byte identity"; exit 1; }

# --- 2. counters vs an independent Julia count ------------------------------
# Always the engine manifest -- see the header for why extra paths get step 1
# only.
F="$ENGINE_MANIFEST"
echo "==> counters ($F)"

julia -e '
    using TOML
    # Wrapped in a function on purpose: at top level `julia -e` runs in soft
    # scope, where assigning to a name inside a `for` creates a fresh local and
    # every counter reads back undefined.
    function main(file)
        d = TOML.parsefile(file)
        # A v1 manifest has no `manifest_format` and IS the deps table
        # (base/loading.jl:970-981). Three such files sit in a stock depot, so
        # the oracle must not KeyError on them.
        v1 = !haskey(d, "manifest_format")
        deps = v1 ? d : get(d, "deps", Dict{String, Any}())
        entries = tree_hash = path = both = jll = 0
        extb = exts_str = exts_vec = 0
        da = dt = wa = wt = 0
        for (name, arr) in deps
            endswith(name, "_jll") && (jll += length(arr))
            for e in arr
                entries += 1
                haskey(e, "git-tree-sha1") && (tree_hash += 1)
                haskey(e, "path") && (path += 1)
                (haskey(e, "git-tree-sha1") && haskey(e, "path")) && (both += 1)
                if haskey(e, "extensions")
                    extb += 1
                    for (_, v) in e["extensions"]
                        v isa String ? (exts_str += 1) : (exts_vec += 1)
                    end
                end
                haskey(e, "deps") && (e["deps"] isa Vector ? (da += 1) : (dt += 1))
                haskey(e, "weakdeps") && (e["weakdeps"] isa Vector ? (wa += 1) : (wt += 1))
            end
        end
        # `read_manifest` treats an EMPTY file as v2 for convenience
        # (Pkg/src/manifest.jl:257-261), so mirror that before defaulting to v1.
        mf = v1 ? (isempty(d) ? v"2.0.0" : v"1.0.0") : VersionNumber(d["manifest_format"])
        println("deps_array_form=", da)
        println("deps_table_form=", dt)
        println("entries=", entries)
        println("ext_blocks=", extb)
        println("ext_string_values=", exts_str)
        println("ext_vector_values=", exts_vec)
        println("jll=", jll)
        println("julia_version=", haskey(d, "julia_version") ? string(VersionNumber(d["julia_version"])) : "<none>")
        println("manifest_format=", mf.major, ".", mf.minor)
        println("path=", path)
        println("project_hash=", haskey(d, "project_hash") ? string(Base.SHA1(d["project_hash"])) : "<none>")
        println("tree_hash=", tree_hash)
        println("tree_hash_and_path=", both)
        println("unique_names=", length(deps))
        println("weakdeps_array_form=", wa)
        println("weakdeps_table_form=", wt)
    end
    main(ARGS[1])
' "$F" > "$WORK/julia.stats" || { echo "ERROR: stats oracle failed" >&2; exit 2; }

"$DRIVER" stats "$F" > "$WORK/ajt.stats" || { echo "ERROR: ajt stats failed" >&2; exit 2; }

if ! diff -u "$WORK/julia.stats" "$WORK/ajt.stats" > "$WORK/stats.diff"; then
  echo "  FAIL: Ajt's view of the manifest disagrees with Julia's (--- julia, +++ ajt)"
  sed 's/^/    /' "$WORK/stats.diff"
  exit 1
fi
sed 's/^/    /' "$WORK/ajt.stats"

get() { sed -n "s/^$1=//p" "$WORK/ajt.stats"; }

# --- 3. both dep encodings and both extension value shapes ------------------
echo "==> encodings"
errs=0
need_positive() {
  local k v
  k="$1"; v="$(get "$k")"
  if [ "${v:-0}" -gt 0 ]; then
    echo "    $k = $v"
  else
    echo "    FAIL: $k = ${v:-<missing>} — this corpus does not exercise that encoding"
    errs=1
  fi
}
# The array form: every name is in the manifest and unique (manifest.jl:338).
need_positive deps_array_form
need_positive weakdeps_array_form
# The table form: at least one name is absent or duplicated, e.g.
# ColorVectorSpace's weak dep on SpecialFunctions.
need_positive weakdeps_table_form
# extensions values, String and Vector{String} (base/loading.jl:1043-1045).
need_positive ext_string_values
need_positive ext_vector_values
# `deps_table_form` is intentionally NOT required: a healthy manifest has no
# duplicate package names, so every strong dep resolves and takes the array
# form. The unit tests cover the table form for strong deps.
[ "$errs" -eq 0 ] || { echo; echo "FAIL — dual encoding not covered"; exit 1; }

# --- 4. the !(tree_hash && path) invariant ----------------------------------
echo "==> invariants"
both="$(get tree_hash_and_path)"
if [ "$both" != "0" ]; then
  echo "    FAIL: $both entries carry both git-tree-sha1 and path (Pkg asserts against this, manifest.jl:314)"
  exit 1
fi
echo "    no entry carries both git-tree-sha1 and path ($(get tree_hash) hashed, $(get path) path'd)"

# --- reference values (informational) ---------------------------------------
note() { echo "    NOTE: $1 is $2, recorded value was $3 (the manifest moved; gate still green)"; }
[ "$(get entries)"      = "$REF_ENTRIES"        ] || note entries      "$(get entries)"      "$REF_ENTRIES"
[ "$(get tree_hash)"    = "$REF_TREE_HASH"      ] || note tree_hash    "$(get tree_hash)"    "$REF_TREE_HASH"
[ "$(get jll)"          = "$REF_JLL"            ] || note jll          "$(get jll)"          "$REF_JLL"
[ "$(get ext_blocks)"   = "$REF_EXT_BLOCKS"     ] || note ext_blocks   "$(get ext_blocks)"   "$REF_EXT_BLOCKS"
[ "$(get julia_version)" = "$REF_JULIA_VERSION" ] || note julia_version "$(get julia_version)" "$REF_JULIA_VERSION"
[ "$(get project_hash)" = "$REF_PROJECT_HASH"   ] || note project_hash "$(get project_hash)" "$REF_PROJECT_HASH"

echo
echo "PASS — the manifest model round-trips $F byte-for-byte, agrees with Julia on"
echo "       every counter, exercises both dep encodings and both extension value"
echo "       shapes, and upholds the git-tree-sha1/path invariant."
