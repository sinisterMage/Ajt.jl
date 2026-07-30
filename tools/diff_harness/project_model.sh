#!/usr/bin/env bash
# Differential gate for the Project.toml model (src/model/project.zig).
#
# `Pkg.Types.read_project` + `destructure` + `write_project` is the reference
# implementation, and this compares Ajt against it three ways:
#
#   1. FIELDS   — every parsed field of the real Open-Reality Project.toml
#                 (21 deps, 1 weakdep + 1 extension, 18 compat entries,
#                 [extras], [targets]) must equal what Julia reports for the
#                 same file.
#   2. RENDER   — Ajt's write must be byte-identical to Julia's for a corpus of
#                 fixtures covering every normalisation and ordering rule, AND
#                 a no-op write of the real file must be byte-identical to the
#                 file itself (Ajt must not touch a file nobody changed).
#   3. REJECT   — every validation rule is driven with a failing fixture and
#                 must be rejected with the same message Pkg produces. A
#                 handful of read-side checks land on a raw Julia TypeError or
#                 MethodError rather than a `pkgerror`; those live in bad_any/
#                 and only have to be refused by BOTH sides, since there is no
#                 Pkg wording to copy.
#   4. COMPAT   — the one MUTATION this file gates: `Pkg.compat(name, spec)`
#                 against `ops/compat.zig`, over the spec grammar, the quote
#                 strip, deletion, the three refusals, and the cases where Pkg
#                 records a new string and writes no file at all. See the
#                 section header further down.
#
# Byte identity is the point. Pkg users diff their Project.toml in git; a model
# that is merely semantically right would still churn the file, and a model
# that is semantically WRONG in a way byte comparison happens to hide (the
# deps/weakdeps split is the one that bites) would sail through a field-by-field
# check that used the same wrong intersection rule on both sides. Julia is asked
# for every expected value; nothing here is hand-written.
#
# Usage: tools/diff_harness/project_model.sh [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
ENGINE_PROJECT="$REPO_ROOT/Open-Reality/Project.toml"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
[ -f "$ENGINE_PROJECT" ] || { echo "ERROR: $ENGINE_PROJECT missing" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-project-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

# --- fixtures ---------------------------------------------------------------
# Each fixture is one Project.toml. `ok/` must parse; `bad/` must be rejected.
# They are written from here rather than committed so that the file the oracle
# reads and the file Ajt reads are provably the same bytes.
mkdir -p "$WORK/ok" "$WORK/bad" "$WORK/bad_any"

cp "$ENGINE_PROJECT" "$WORK/ok/00-open-reality.toml"

cat > "$WORK/ok/01-normalisation.toml" <<'EOF'
name = "Foo"
uuid = "B08B1914-4D33-46DE-8C63-BA029B7F1C5F"
version = "1.0"

[deps]
EOF

cat > "$WORK/ok/02-passthrough.toml" <<'EOF'
name = "Foo"
desc = "a package"
license = "MIT"
keywords = ["a", "b"]
authors = ["me"]

[extensions]
E = "A"

[weakdeps]
A = "00000000-0000-0000-0000-000000000001"

[wat]
x = 1
EOF

cat > "$WORK/ok/03-weak-split.toml" <<'EOF'
name = "Foo"

[deps]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000002"

[weakdeps]
B = "00000000-0000-0000-0000-000000000002"

[extensions]
FooBExt = "B"
EOF

cat > "$WORK/ok/04-weak-split-different-uuid.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[weakdeps]
A = "00000000-0000-0000-0000-000000000002"
EOF

cat > "$WORK/ok/05-sources-header-to-inline.toml" <<'EOF'
name = "Foo"

[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources.A]
url = "https://example.com/A.git"
rev = "main"
EOF

cat > "$WORK/ok/06-sources-inline.toml" <<'EOF'
name = "Foo"

[deps]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000002"

[sources]
A = {path = "../A"}
B = {url = "u", rev = "r", subdir = "sub"}
EOF

# `by` is threaded through every nesting level of the printer: `version` sorts
# ahead of `julia` INSIDE [compat], which a plain sort would never do.
cat > "$WORK/ok/07-nested-key-order.toml" <<'EOF'
[extras]
version = "00000000-0000-0000-0000-000000000001"

[compat]
julia = "1.9"
version = "1"
EOF

cat > "$WORK/ok/08-path-and-entryfile.toml" <<'EOF'
name = "Foo"
path = "src/Other.jl"
EOF

cat > "$WORK/ok/09-workspace.toml" <<'EOF'
name = "Foo"
manifest = "Manifest-v1.11.toml"

[workspace]
projects = ["sub/a", "sub/b"]
EOF

cat > "$WORK/ok/10-integer-uuid.toml" <<'EOF'
[deps]
A = 1
EOF

cat > "$WORK/ok/11-apps-and-array-of-tables.toml" <<'EOF'
name = "Foo"

[apps.myapp]
submodule = "Sub"
julia_flags = ["-O3"]

[[people]]
n = "a"

[[people]]
n = "b"
EOF

cat > "$WORK/ok/12-empty.toml" <<'EOF'
EOF

# read_project_deps calls UUID(v) with no type guard, so Julia accepts any
# UInt128-convertible value here and writes it back as a real UUID. F and G are
# the reason the conversion has to be u128 rather than u64.
cat > "$WORK/ok/13-numeric-uuids.toml" <<'EOF'
[deps]
A = 2
B = true
C = 3.0
D = 9223372036854775807
E = false
F = 1e20
G = 1e30
EOF

# --- rejection fixtures -----------------------------------------------------
# One per validation rule the unit is responsible for, plus the read-side
# checks. `.file` alongside a fixture means "pass this path to read_project",
# which is what makes Julia append its ` at "..."` location suffix.

cat > "$WORK/bad/01-dup-dep-uuid.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000001"
EOF

cat > "$WORK/bad/02-dup-weakdep-uuid.toml" <<'EOF'
[weakdeps]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000001"
EOF

cat > "$WORK/bad/03-dup-extra-uuid.toml" <<'EOF'
[extras]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000001"
EOF

cat > "$WORK/bad/04-target-not-listed.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[targets]
test = ["Nope"]
EOF

cat > "$WORK/bad/05-target-named-twice.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[targets]
test = ["A", "A"]
EOF

cat > "$WORK/bad/06-compat-not-listed.toml" <<'EOF'
[compat]
Nope = "1"
EOF

# Same fixture, but read with a file path -> Julia appends the location suffix.
cp "$WORK/bad/06-compat-not-listed.toml" "$WORK/bad/07-compat-not-listed-located.toml"
echo "$WORK/bad/07-compat-not-listed-located.toml" > "$WORK/bad/07-compat-not-listed-located.file"

cat > "$WORK/bad/08-source-not-listed.toml" <<'EOF'
[weakdeps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {path = "../A"}
EOF

# The nasty one: A is in [deps] AND [weakdeps] with the same uuid, so the weak
# split empties it out of `deps` and listed_deps(include_weak=false) no longer
# sees it -- [sources] is rejected even though [deps] plainly lists it.
cat > "$WORK/bad/09-source-for-split-weakdep.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[weakdeps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {path = "../A"}
EOF

cat > "$WORK/bad/10-bad-project-uuid.toml" <<'EOF'
uuid = "zzz"
EOF

cat > "$WORK/bad/11-project-uuid-not-string.toml" <<'EOF'
uuid = 1
EOF

cat > "$WORK/bad/12-bad-project-version.toml" <<'EOF'
version = "not.a.version"
EOF

cat > "$WORK/bad/13-project-version-not-string.toml" <<'EOF'
version = 1
EOF

cat > "$WORK/bad/14-deps-not-a-table.toml" <<'EOF'
deps = 1
EOF

cat > "$WORK/bad/15-bad-dep-uuid.toml" <<'EOF'
[deps]
A = "not-a-uuid"
EOF

cat > "$WORK/bad/16-targets-not-a-table.toml" <<'EOF'
targets = 1
EOF

cat > "$WORK/bad/17-target-not-a-list.toml" <<'EOF'
[targets]
test = "A"
EOF

cat > "$WORK/bad/18-compat-not-a-table.toml" <<'EOF'
compat = 1
EOF

# "1-2" is the REGISTRY grammar; [compat] uses semver_spec, where it is invalid.
cat > "$WORK/bad/19-compat-registry-grammar.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[compat]
A = "1-2"
EOF

cat > "$WORK/bad/20-source-not-a-table.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = "../A"
EOF

cat > "$WORK/bad/21-source-invalid-key.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {branch = "main"}
EOF

cat > "$WORK/bad/22-source-path-and-rev.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {path = "../A", rev = "r"}
EOF

cat > "$WORK/bad/23-workspace-invalid-key.toml" <<'EOF'
[workspace]
nope = 1
EOF

cat > "$WORK/bad/24-workspace-entry-not-a-string.toml" <<'EOF'
[workspace]
projects = [1]
EOF

cat > "$WORK/bad/25-workspace-not-a-table.toml" <<'EOF'
workspace = 1
EOF

cat > "$WORK/bad/26-app-not-a-table.toml" <<'EOF'
[apps]
myapp = 1
EOF

cat > "$WORK/bad/27-app-julia-flags.toml" <<'EOF'
[apps.myapp]
julia_flags = 1
EOF

# TWO-FAULT fixtures. Every check above trips exactly one rule, which is why an
# earlier revision could reorder the checks inside a section and still pass: with
# one fault there is only one message to produce. These have two, so they pin
# WHICH rule Julia reports first. All three regressed once already.
cat > "$WORK/bad/29-source-invalid-key-beats-type.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {branch = 1}
EOF

cat > "$WORK/bad/30-source-conflict-beats-type.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {path = 1, url = "u"}
EOF

cat > "$WORK/bad/31-source-conflict-beats-rev-type.toml" <<'EOF'
[deps]
A = "00000000-0000-0000-0000-000000000001"

[sources]
A = {path = "p", rev = 1}
EOF

# read_project_apps pkgerrors on julia_flags but only converts submodule when
# it builds the AppInfo, so julia_flags wins.
cat > "$WORK/bad/32-app-julia-flags-beats-submodule.toml" <<'EOF'
[apps.myapp]
submodule = 1
julia_flags = 1
EOF

# An EMPTY target list: Julia's TOML parser narrows ["a"] to Vector{String} but
# leaves [] as Vector{Any}, so `deps isa Vector{String}` fails.
cat > "$WORK/bad/28-target-empty-list.toml" <<'EOF'
[targets]
test = []
EOF

# Rejected by both, but Julia's text is a raw TypeError/MethodError with no
# pkgerror to mirror, so only the refusal itself is asserted. Accepting any of
# these would be worse than a wording mismatch: `destructure` would delete the
# key from the passthrough copy and the write would drop data.
printf 'name = 1\n'       > "$WORK/bad_any/01-name-not-a-string.toml"
printf 'manifest = 1\n'   > "$WORK/bad_any/02-manifest-not-a-string.toml"
printf 'path = 1\n'       > "$WORK/bad_any/03-path-not-a-string.toml"
printf 'entryfile = 1\n'  > "$WORK/bad_any/04-entryfile-not-a-string.toml"
printf 'extensions = 1\n' > "$WORK/bad_any/05-extensions-not-a-table.toml"
printf 'sources = 1\n'    > "$WORK/bad_any/06-sources-not-a-table.toml"
printf 'apps = 1\n'       > "$WORK/bad_any/07-apps-not-a-table.toml"
printf '[extensions]\nE = [1]\n' > "$WORK/bad_any/08-extension-trigger-not-a-string.toml"
printf '[deps]\nA = "00000000-0000-0000-0000-000000000001"\n\n[compat]\nA = 1\n' \
  > "$WORK/bad_any/09-compat-not-a-string.toml"
# Project.sources::Dict{String,Dict{String,String}} -- accepting this and
# nulling the field would make the write emit `A = {}`.
printf '[deps]\nA = "00000000-0000-0000-0000-000000000001"\n\n[sources]\nA = {path = 1}\n' \
  > "$WORK/bad_any/10-source-field-not-a-string.toml"
printf '[extensions]\nE = []\n'      > "$WORK/bad_any/11-extension-empty-list.toml"
printf '[apps.myapp]\nsubmodule = 1\n' > "$WORK/bad_any/12-app-submodule-not-a-string.toml"
printf '[deps]\nA = -1\n'            > "$WORK/bad_any/13-negative-uuid.toml"
printf '[deps]\nA = 1.5\n'           > "$WORK/bad_any/14-fractional-uuid.toml"
# InexactError(UInt128, ...) -- the far side of the u128 range and the non-finite
# floats, which is what `!(f >= 0)` rather than `f < 0` is there to catch.
printf '[deps]\nA = 1e40\n'          > "$WORK/bad_any/15-oversized-uuid.toml"
printf '[deps]\nA = nan\n'           > "$WORK/bad_any/16-nan-uuid.toml"
printf '[deps]\nA = inf\n'           > "$WORK/bad_any/17-inf-uuid.toml"

# --- the Ajt probe ----------------------------------------------------------
# main.zig has no `project` subcommand yet (a sibling unit owns the CLI), so the
# harness compiles a throwaway driver against the library module. Cheap: the
# whole thing builds in well under a second.
cat > "$WORK/probe.zig" <<'EOF'
const std = @import("std");
const ajt = @import("ajt");
const model = ajt.model.project;

// Reports one field per line as `key\tvalue`, which diffs far more legibly than
// JSON when a single field goes wrong.
fn dumpFields(w: *std.Io.Writer, p: *model.Project, gpa: std.mem.Allocator) !void {
    try w.print("name\t{s}\n", .{p.name orelse "-"});
    if (p.uuid) |u| {
        var buf: [36]u8 = undefined;
        const hex = "0123456789abcdef";
        var i: usize = 0;
        for (u.bytes, 0..) |b, bi| {
            if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
                buf[i] = '-';
                i += 1;
            }
            buf[i] = hex[b >> 4];
            buf[i + 1] = hex[b & 0xf];
            i += 2;
        }
        try w.print("uuid\t{s}\n", .{&buf});
    } else try w.print("uuid\t-\n", .{});
    if (p.version) |v| {
        try w.print("version\t", .{});
        try v.format(w);
        try w.print("\n", .{});
    } else try w.print("version\t-\n", .{});
    try w.print("manifest\t{s}\n", .{p.manifest orelse "-"});
    try w.print("entryfile\t{s}\n", .{p.entryfile orelse "-"});

    for ([_][]const u8{ "deps", "_deps_weak", "weakdeps", "extras" }, 0..) |label, k| {
        const m = switch (k) {
            0 => &p.deps,
            1 => &p.deps_weak,
            2 => &p.weakdeps,
            else => &p.extras,
        };
        var names = try gpa.alloc([]const u8, m.entries.items.len);
        defer gpa.free(names);
        for (m.entries.items, 0..) |d, i| names[i] = d.name;
        std.mem.sort([]const u8, names, {}, lessThan);
        for (names) |n| {
            const u = m.get(n).?;
            var buf: [36]u8 = undefined;
            const hex = "0123456789abcdef";
            var i: usize = 0;
            for (u.bytes, 0..) |b, bi| {
                if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
                    buf[i] = '-';
                    i += 1;
                }
                buf[i] = hex[b >> 4];
                buf[i + 1] = hex[b & 0xf];
                i += 2;
            }
            try w.print("{s}.{s}\t{s}\n", .{ label, n, &buf });
        }
    }

    {
        var idx = try gpa.alloc(usize, p.compat.items.len);
        defer gpa.free(idx);
        for (0..idx.len) |i| idx[i] = i;
        std.mem.sort(usize, idx, p.compat.items, lessCompat);
        for (idx) |i| {
            const c = p.compat.items[i];
            const rendered = try c.spec.toString(gpa);
            defer gpa.free(rendered);
            try w.print("compat.{s}\t{s}\t{s}\n", .{ c.name, c.str, rendered });
        }
    }
    {
        var idx = try gpa.alloc(usize, p.targets.items.len);
        defer gpa.free(idx);
        for (0..idx.len) |i| idx[i] = i;
        std.mem.sort(usize, idx, p.targets.items, lessTarget);
        for (idx) |i| {
            const t = p.targets.items[i];
            try w.print("targets.{s}\t", .{t.name});
            for (t.deps, 0..) |d, j| {
                if (j != 0) try w.print(",", .{});
                try w.print("{s}", .{d});
            }
            try w.print("\n", .{});
        }
    }
    {
        var idx = try gpa.alloc(usize, p.sources.items.len);
        defer gpa.free(idx);
        for (0..idx.len) |i| idx[i] = i;
        std.mem.sort(usize, idx, p.sources.items, lessSource);
        for (idx) |i| {
            const s = p.sources.items[i];
            try w.print("sources.{s}\tpath={s} url={s} rev={s} subdir={s}\n", .{
                s.name,
                s.path orelse "-",
                s.url orelse "-",
                s.rev orelse "-",
                s.subdir orelse "-",
            });
        }
    }
    {
        var idx = try gpa.alloc(usize, p.exts.len);
        defer gpa.free(idx);
        for (0..idx.len) |i| idx[i] = i;
        std.mem.sort(usize, idx, p.exts, lessExt);
        for (idx) |i| {
            const e = p.exts[i];
            try w.print("extensions.{s}\t", .{e.name});
            for (e.triggers, 0..) |t, j| {
                if (j != 0) try w.print(",", .{});
                try w.print("{s}", .{t});
            }
            try w.print("\n", .{});
        }
    }
    if (p.workspace_projects) |ws| {
        try w.print("workspace.projects\t", .{});
        for (ws, 0..) |x, j| {
            if (j != 0) try w.print(",", .{});
            try w.print("{s}", .{x});
        }
        try w.print("\n", .{});
    } else try w.print("workspace.projects\t-\n", .{});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
fn lessCompat(items: []const model.Compat, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, items[a].name, items[b].name);
}
fn lessTarget(items: []const model.Target, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, items[a].name, items[b].name);
}
fn lessSource(items: []const model.Source, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, items[a].name, items[b].name);
}
fn lessExt(items: []const model.Extension, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, items[a].name, items[b].name);
}

pub fn main(init: std.process.Init) !void {
    // init.gpa has leak checking wired up in Debug, so a leak in the model
    // fails the harness rather than hiding behind a passing byte comparison.
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // probe <fields|render|nowrite|reject> <file.toml> [location]
    // probe compat <file.toml> <name> [spec]
    const mode = args[1];
    const path = args[2];

    const location: ?[]const u8 = if (args.len > 3 and args[3].len > 0) args[3] else null;

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (std.mem.eql(u8, mode, "compat")) {
        // `ops.compat.run` reads and rewrites the file in place, so the harness
        // hands each case its own copy. `.resolve = .skip` because the fixtures
        // name unregistered packages and the resolve is not what this section
        // compares.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var refusal: ?[]const u8 = null;
        if (ajt.ops.compat.run(arena, io, .{
            .project_file = path,
            .manifest_file = "/nonexistent-manifest",
            .resolve = .skip,
            .refusal = &refusal,
        }, args[3], if (args.len > 4) args[4] else null)) |_| {
            try w.writeAll("OK\n");
        } else |err| switch (err) {
            error.NotADependency, error.InvalidSpec, error.NoProject =>
            // Pkg's own wording, filled in by ops/compat.zig — the same string
            // the CLI prints, which is the point of comparing it here.
            try w.print("ERROR {s}\n", .{refusal.?}),
            else => try w.print("UNEXPECTED ERROR {t}\n", .{err}),
        }
        // The file as it stands afterwards, so a refusal that wrote anyway is
        // caught by the same comparison.
        try w.writeAll(try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)));
        return;
    }

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
    defer gpa.free(src);

    var diag: model.Diagnostic = .{};
    var p = model.parse(gpa, src, .{ .file = location }, &diag) catch |err| {
        if (std.mem.eql(u8, mode, "reject")) {
            try w.print("{s}", .{diag.message()});
            return;
        }
        if (std.mem.eql(u8, mode, "reject-any")) {
            // Julia's message here is a raw TypeError; only the refusal is
            // comparable, so report a canonical marker on both sides.
            try w.print("REJECTED\n", .{});
            return;
        }
        try w.print("UNEXPECTED ERROR {t}: {s}\n", .{ err, diag.message() });
        std.process.exit(1);
    };
    defer p.deinit();

    if (std.mem.eql(u8, mode, "reject") or std.mem.eql(u8, mode, "reject-any")) {
        try w.print("ACCEPTED (expected a rejection)\n", .{});
        std.process.exit(1);
    } else if (std.mem.eql(u8, mode, "fields")) {
        try dumpFields(w, &p, gpa);
    } else if (std.mem.eql(u8, mode, "render")) {
        const bytes = try p.render(gpa);
        defer gpa.free(bytes);
        try w.writeAll(bytes);
    } else if (std.mem.eql(u8, mode, "nowrite")) {
        // Nothing was mutated, so the model must decline to write at all.
        if (try p.pendingWrite(gpa)) |bytes| {
            gpa.free(bytes);
            try w.print("WOULD REWRITE AN UNCHANGED FILE\n", .{});
            std.process.exit(1);
        }
        try w.writeAll(src);
    } else {
        try w.print("unknown mode {s}\n", .{mode});
        std.process.exit(1);
    }
}
EOF

echo "==> building the ajt probe"
# Hermetic per-run cache, as in stdlibs.sh: this build shares no mutable state
# with the package's own `.zig-cache`, with a concurrent `zig build`, or with
# another checkout. It had no cache flags at all before.
zig build-exe \
  --dep ajt -Mroot="$WORK/probe.zig" -Majt="$AJT_ROOT/src/root.zig" \
  --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" \
  -femit-bin="$WORK/probe" >"$WORK/probe.buildlog" 2>&1 || {
    echo "ERROR: probe failed to build" >&2
    cat "$WORK/probe.buildlog" >&2
    exit 2
  }

# --- the Julia oracle -------------------------------------------------------
# One Julia process for all fixtures: startup dominates otherwise.
cat > "$WORK/oracle_batch.jl" <<'EOF'
include(joinpath(@__DIR__, "oracle_lib.jl"))
for line in eachline(ARGS[1])
    isempty(line) && continue
    # String(...) matters: split yields SubStrings and read_project's signature
    # is Union{IO, String}, so a SubString is a MethodError, not a location.
    parts = String.(split(line, '\t'))
    mode, path, out = parts[1], parts[2], parts[3]
    location = length(parts) > 3 && !isempty(parts[4]) ? parts[4] : nothing
    open(out, "w") do io
        run_one(io, mode, path, location)
    end
end
EOF

cat > "$WORK/oracle_lib.jl" <<'EOF'
using Pkg
const T = Pkg.Types

function dump_fields(io, p)
    println(io, "name\t", something(p.name, "-"))
    println(io, "uuid\t", p.uuid === nothing ? "-" : string(p.uuid))
    println(io, "version\t", p.version === nothing ? "-" : string(p.version))
    println(io, "manifest\t", something(p.manifest, "-"))
    println(io, "entryfile\t", something(p.entryfile, "-"))
    for (label, m) in (("deps", p.deps), ("_deps_weak", p._deps_weak),
                       ("weakdeps", p.weakdeps), ("extras", p.extras))
        for n in sort(collect(keys(m)))
            println(io, label, ".", n, "\t", string(m[n]))
        end
    end
    for n in sort(collect(keys(p.compat)))
        c = p.compat[n]
        println(io, "compat.", n, "\t", c.str, "\t", string(c.val))
    end
    for n in sort(collect(keys(p.targets)))
        println(io, "targets.", n, "\t", join(p.targets[n], ","))
    end
    for n in sort(collect(keys(p.sources)))
        s = p.sources[n]
        println(io, "sources.", n, "\tpath=", get(s, "path", "-"),
                " url=", get(s, "url", "-"), " rev=", get(s, "rev", "-"),
                " subdir=", get(s, "subdir", "-"))
    end
    for n in sort(collect(keys(p.exts)))
        v = p.exts[n]
        println(io, "extensions.", n, "\t", v isa String ? v : join(v, ","))
    end
    ws = get(p.workspace, "projects", nothing)
    println(io, "workspace.projects\t", ws === nothing ? "-" : join(ws, ","))
end

function run_one(io, mode, path, location)
    try
        # read_project(::String) is what attaches the ` at "..."` location
        # suffix; the IO method deliberately does not.
        p = location === nothing ? T.read_project(IOBuffer(read(path, String))) :
                                   T.read_project(location)
        if mode == "reject" || mode == "reject-any"
            print(io, "ACCEPTED (expected a rejection)")
        elseif mode == "fields"
            dump_fields(io, p)
        else
            buf = IOBuffer(); T.write_project(buf, T.destructure(p))
            print(io, String(take!(buf)))
        end
    catch e
        if mode == "reject"
            print(io, sprint(showerror, e))
        elseif mode == "reject-any"
            # Julia's message here is a raw TypeError/MethodError with no
            # pkgerror to mirror; only the refusal is comparable.
            println(io, "REJECTED")
        else
            print(io, "UNEXPECTED ERROR: ", sprint(showerror, e))
        end
    end
end
EOF

# --- run --------------------------------------------------------------------
JOBS="$WORK/jobs.tsv"
: > "$JOBS"
mkdir -p "$WORK/julia" "$WORK/ajt"

LABELS=(); MODES=(); PATHS=(); LOCS=()
# Queues one case for both sides at once: a line in the oracle's batch job file
# and a parallel entry in the arrays the ajt loop and the comparison walk, so
# the two sides can never drift out of step.
register() { # mode file label [location]
  MODES+=("$1"); PATHS+=("$2"); LABELS+=("$3"); LOCS+=("${4:-}")
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$WORK/julia/$3" "${4:-}" >> "$JOBS"
}

for f in "$WORK"/ok/*.toml; do
  b="$(basename "$f" .toml)"
  register fields "$f" "fields-$b"
  register render "$f" "render-$b"
done
# The byte-preservation claim only means anything on the real engine file.
register nowrite "$WORK/ok/00-open-reality.toml" "nowrite-00-open-reality"

for f in "$WORK"/bad/*.toml; do
  b="$(basename "$f" .toml)"
  loc=""
  [ -f "${f%.toml}.file" ] && loc="$(cat "${f%.toml}.file")"
  register reject "$f" "reject-$b" "$loc"
done

for f in "$WORK"/bad_any/*.toml; do
  register reject-any "$f" "rejectany-$(basename "$f" .toml)"
done

echo "==> Julia oracle (${#LABELS[@]} cases)"
julia "$WORK/oracle_batch.jl" "$JOBS" || { echo "ERROR: oracle failed" >&2; exit 2; }

echo "==> ajt"
for i in "${!LABELS[@]}"; do
  "$WORK/probe" "${MODES[$i]}" "${PATHS[$i]}" "${LOCS[$i]}" \
    > "$WORK/ajt/${LABELS[$i]}" 2> "$WORK/ajt/${LABELS[$i]}.err" || true
done

echo "==> comparing"
pass=0; fail=0
: > "$WORK/mismatches.txt"
for i in "${!LABELS[@]}"; do
  label="${LABELS[$i]}"
  jf="$WORK/julia/$label"
  af="$WORK/ajt/$label"
  # A "rejection" the oracle actually ACCEPTED would silently pass, because
  # both sides would then print the same ACCEPTED line. Check the marker.
  case "${MODES[$i]}" in
    reject|reject-any)
      if grep -q '^ACCEPTED' "$jf" 2>/dev/null; then
        fail=$((fail + 1)); printf '%s\tfixture is NOT rejected by Julia\n' "$label" >> "$WORK/mismatches.txt"; continue
      fi
      ;;
  esac
  if [ "${MODES[$i]}" = fields ] || [ "${MODES[$i]}" = render ] || [ "${MODES[$i]}" = nowrite ]; then
    if grep -q '^UNEXPECTED ERROR' "$jf" 2>/dev/null; then
      fail=$((fail + 1)); printf '%s\toracle errored: %s\n' "$label" "$(head -1 "$jf")" >> "$WORK/mismatches.txt"; continue
    fi
  fi
  if cmp -s "$jf" "$af"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf '%s\t\n' "$label" >> "$WORK/mismatches.txt"
  fi
done

# --- COMPAT -----------------------------------------------------------------
# `ajt compat NAME [spec]` (src/ops/compat.zig) against `Pkg.compat(name, spec)`
# (API.jl:1509-1547). Same shape as the sections above: one fixture per case,
# copied to both sides, and the resulting Project.toml must be byte-identical.
#
# Three things make this more than "does it set a key":
#
#  * `Base.:(==)(::Compat, ::Compat)` compares only the parsed VersionSpec and
#    ignores the source string (Types.jl:244), so `write_env`'s
#    `project != original_project` test is FALSE for a bound that changed
#    spelling but not meaning — `^1.2` over `1.2` does not rewrite the file at
#    all. The `respell` and `spaces` cases pin that, against a fixture in
#    deliberately non-canonical form so a rewrite would be visible.
#  * `strip(compat_str, '"')` strips quotes and NOT whitespace, so `" 1.2 "` is
#    stored and written verbatim.
#  * `haskey(project.deps, pkg)` is taken after read_project's deps∩weakdeps
#    split, so a name in both tables is refused.
#
# The compliance resolve is out of scope here and is skipped on the Ajt side:
# these fixtures name unregistered packages, so Pkg's resolve throws a PkgError
# that is NOT a compat refusal — and by then Pkg has already written the
# project, which is exactly the ordering being compared. The oracle classifies
# on the message and the count of classified refusals is asserted below, so a
# classifier that silently stopped firing fails the gate.

mkdir -p "$WORK/compat"

cat > "$WORK/compat/base.toml" <<'EOF'
name = "Env"
uuid = "b08b1914-4d33-46de-8c63-ba029b7f1c5f"

[deps]
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000002"
W = "00000000-0000-0000-0000-00000000000f"

[weakdeps]
W = "00000000-0000-0000-0000-00000000000f"

[extensions]
EnvWExt = "W"

[compat]
A = "1.2"
julia = "1.9"
EOF

# Non-canonical on purpose: a comment, padded alignment and an upper-case uuid.
# Any write at all normalises all three away, so the "did not write" cases below
# are checkable rather than a matter of trust.
cat > "$WORK/compat/messy.toml" <<'EOF'
# hand-written, and a no-op compat call must leave it that way
name    = "Env"
uuid    = "B08B1914-4D33-46DE-8C63-BA029B7F1C5F"

[deps]
A = "00000000-0000-0000-0000-000000000001"

[compat]
A   = "1.2"
EOF

# label <TAB> fixture <TAB> name <TAB> spec, where the sentinel NONE means "no
# spec argument at all" — which Pkg collapses with the empty string (`:1524`),
# but only after the two have travelled different paths to get there.
CASES="$WORK/compat/cases.tsv"
: > "$CASES"
c() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CASES"; }

c set-bare       base  A     "1"
c set-minor      base  A     "1.2"
c set-caret      base  A     "^1.2.3"
c set-tilde      base  A     "~1.2"
c set-union      base  A     ">= 1.2, < 2"
c set-quoted     base  A     '"1.2"'
c set-new        base  B     "2"
# `strip(s, '"')` removes quotes and NOT whitespace, and `destructure` writes the
# source string verbatim — so this lands in the file WITH its spaces. B has no
# bound yet, which is what makes the difference visible: on a package that
# already has an equivalent one, neither tool writes anything (see noop-spaces)
# and a spec normaliser that over-trimmed would go unnoticed.
c set-spaces     base  B     " 1.2 "
c julia-alias    base  Julia "1.10"
c delete         base  A     NONE
c delete-empty   base  A     ""
c delete-missing base  B     NONE
c invalid        base  A     "1-2"
c not-a-dep      base  Nope  "1"
c not-a-dep-case base  JULIA "1"
c weak-split     base  W     "1"
# The three that must NOT rewrite: same string, same VersionSpec spelled
# differently, and the whitespace `strip` does not remove.
c noop-same      messy A     "1.2"
c noop-respell   messy A     "^1.2"
c noop-spaces    messy A     " 1.2 "

COMPAT_TOTAL="$(wc -l < "$CASES")"

cat > "$WORK/compat_oracle.jl" <<'EOF'
using Pkg

# Pkg.compat's own refusals, as opposed to anything the compliance resolve
# throws afterwards. Both are PkgErrors and only these two mean "the edit was
# rejected"; everything else happens AFTER write_env has already run.
is_refusal(msg) = startswith(msg, "No package named") ||
                  startswith(msg, "invalid compat version specifier")

# ARGS: cases.tsv, log, workdir. The per-case directory is DERIVED here rather
# than passed, so the case table has one shape on both sides.
open(ARGS[2], "w") do log
    for line in eachline(ARGS[1])
        isempty(line) && continue
        label, _, name, spec = String.(split(line, '\t'; limit = 4))
        dir = joinpath(ARGS[3], label, "julia")
        open(joinpath(dir, "out"), "w") do io
            try
                Pkg.activate(dir; io = devnull)
                Pkg.compat(name, spec == "NONE" ? nothing : spec; io = devnull)
                println(io, "OK")
            catch e
                msg = sprint(showerror, e)
                if is_refusal(msg)
                    println(io, "ERROR ", msg)
                    println(log, label, "\trefused")
                else
                    println(io, "OK")
                    println(log, label, "\tresolve-failed-after-write")
                end
            end
            print(io, read(joinpath(dir, "Project.toml"), String))
        end
    end
end
EOF

echo "==> compat ($COMPAT_TOTAL cases)"
while IFS=$'\t' read -r label fixture name spec; do
  for side in julia ajt; do
    mkdir -p "$WORK/compat/$label/$side"
    cp "$WORK/compat/$fixture.toml" "$WORK/compat/$label/$side/Project.toml"
  done
done < "$CASES"

# Its own Julia process: `Pkg.activate` mutates the global active project, and
# leaving that behind would change what the fixtures above are read against.
JULIA_DEPOT_PATH="$WORK/compat/depot" julia --startup-file=no \
  "$WORK/compat_oracle.jl" "$CASES" "$WORK/compat/oracle.log" "$WORK/compat" \
  >"$WORK/compat/oracle.out" 2>&1 || {
    echo "ERROR: compat oracle failed" >&2; tail -20 "$WORK/compat/oracle.out" >&2; exit 2; }

while IFS=$'\t' read -r label fixture name spec; do
  d="$WORK/compat/$label/ajt"
  # NONE is "no spec argument"; anything else — the empty string included — is
  # an argument, and the two must reach `run` as different things.
  argv=(compat "$d/Project.toml" "$name")
  [ "$spec" = NONE ] || argv+=("$spec")
  "$WORK/probe" "${argv[@]}" > "$d/out" 2>"$d/err" || true

  jf="$WORK/compat/$label/julia/out"
  af="$d/out"
  if [ ! -s "$jf" ]; then
    fail=$((fail + 1)); printf 'compat-%s\toracle produced nothing\n' "$label" >> "$WORK/mismatches.txt"; continue
  fi
  if grep -q '^UNEXPECTED ERROR' "$af"; then
    fail=$((fail + 1)); printf 'compat-%s\tajt: %s\n' "$label" "$(head -1 "$af")" >> "$WORK/mismatches.txt"; continue
  fi
  if cmp -s "$jf" "$af"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'compat-%s\t%s\n' "$label" "$(diff "$jf" "$af" | tr '\n' ' ' | head -c 200)" >> "$WORK/mismatches.txt"
  fi
done < "$CASES"

# LANDMARK 1: the four refusal fixtures must actually have been refused BY PKG.
# Without this, a corpus whose fixtures all quietly succeed compares two
# identical "OK" outputs and proves nothing about the refusal paths.
refused="$(grep -c $'\trefused$' "$WORK/compat/oracle.log" 2>/dev/null || true)"
if [ "$refused" -ne 4 ]; then
  fail=$((fail + 1))
  printf 'compat-refusals\tPkg refused %s of the 4 refusal fixtures\n' "$refused" >> "$WORK/mismatches.txt"
else
  pass=$((pass + 1))
fi

# LANDMARK 2: the three no-op cases must leave the messy fixture BYTE-INTACT on
# both sides — comment, alignment and upper-case uuid included. Comparing the
# two sides to each other cannot see a shared rewrite.
for label in noop-same noop-respell noop-spaces; do
  for side in julia ajt; do
    if cmp -s "$WORK/compat/messy.toml" "$WORK/compat/$label/$side/Project.toml"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf 'compat-%s-%s\trewrote a file whose compat bound did not change meaning\n' \
        "$label" "$side" >> "$WORK/mismatches.txt"
    fi
  done
done

# LANDMARK 3: and a case that DOES change meaning must rewrite, or the two
# checks above would pass on a compat that writes nothing at all.
if grep -qx 'A = "1"' "$WORK/compat/set-bare/ajt/Project.toml"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'compat-set-bare\tajt did not record the new bound\n' >> "$WORK/mismatches.txt"
fi

# The no-op write must reproduce the ORIGINAL bytes, not merely agree with
# Julia's rewrite of them. (Both are true for the engine file, but only because
# it is already in canonical form; the assertion below is the one that would
# catch a model that quietly reformats.)
if ! cmp -s "$WORK/ok/00-open-reality.toml" "$WORK/ajt/nowrite-00-open-reality"; then
  fail=$((fail + 1))
  printf 'nowrite-00-open-reality\tno-op write is not byte-identical to the input\n' >> "$WORK/mismatches.txt"
fi
if [ -s "$WORK/ajt/nowrite-00-open-reality.err" ]; then
  fail=$((fail + 1))
  printf 'nowrite-00-open-reality\tprobe stderr: %s\n' "$(head -1 "$WORK/ajt/nowrite-00-open-reality.err")" >> "$WORK/mismatches.txt"
fi

echo
echo "  identical : $pass"
echo "  divergent : $fail"

if [ "$fail" -gt 0 ]; then
  echo
  echo "Divergences:"
  while IFS=$'\t' read -r label note; do
    echo "--- $label ${note:+($note)}"
    [ -n "$note" ] && continue
    diff "$WORK/julia/$label" "$WORK/ajt/$label" | head -20
    [ -s "$WORK/ajt/$label.err" ] && head -3 "$WORK/ajt/$label.err"
  done < "$WORK/mismatches.txt"
  [ $KEEP -eq 0 ] && echo && echo "(re-run with --keep to inspect the full output)"
  exit 1
fi

echo
echo "PASS — the Project.toml model agrees with Pkg across $pass cases"
