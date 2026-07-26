//! `project_hash` — the fingerprint Pkg records in `Manifest.toml` to decide
//! whether an environment still matches its Project.
//!
//! Port of `workspace_resolve_hash` (`Pkg/src/Types.jl:645-666`). Getting this
//! byte-exact is the single best proof that the version-spec port is correct,
//! because the digest covers the *canonical rendering* of every compat entry
//! rather than its source string. If `Range.init`'s significance collapse or
//! `union!`'s merging were even slightly off, the hash would differ.
//!
//! Digested layout:
//!
//!     <name>=<uuid>\n   for each direct dep, sorted by name
//!     \n
//!     <name>=<uuid>\n   for each weakdep, sorted by name
//!     \n
//!     <name>=<spec>\n   for each of (deps ∪ weakdeps), sorted by name
//!
//! Three traps, all of which produce a plausible wrong answer:
//!
//!  1. **The project itself is a direct dep.** `load_direct_deps` pushes a
//!     `PackageSpec` for the project when it has both `name` and `uuid`
//!     (`Operations.jl:112-120`), so `OpenReality=b08b1914-…` appears in the
//!     first block and `OpenReality=*` in the third.
//!  2. **`julia` is excluded from compats**, because the compat map is keyed
//!     off `deps ∪ weakdeps` and `julia` is in neither.
//!  3. **The compat value is the canonical `VersionSpec` rendering**, not the
//!     string from the file: `"0.4.0"` digests as `0.4`, `"0.11, 0.12"` as
//!     `0.11 - 0.12`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Table = @import("../toml/value.zig").Table;
const versions = @import("versions.zig");

pub const Error = error{InvalidProject} || versions.ParseError || Allocator.Error;

const Pair = struct {
    name: []const u8,
    value: []const u8,
    /// Owned when the value was rendered rather than borrowed from the TOML.
    owned: bool = false,
};

fn lessByName(_: void, a: Pair, b: Pair) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Builds the exact string that gets digested. Exposed separately from
/// `compute` because it is far easier to debug a byte diff than a hash diff.
pub fn digestString(gpa: Allocator, project: *const Table) Error![]u8 {
    const deps_tbl: ?*Table = if (project.get("deps")) |v| switch (v) {
        .table => |t| t,
        else => return error.InvalidProject,
    } else null;
    const weak_tbl: ?*Table = if (project.get("weakdeps")) |v| switch (v) {
        .table => |t| t,
        else => return error.InvalidProject,
    } else null;
    const compat_tbl: ?*Table = if (project.get("compat")) |v| switch (v) {
        .table => |t| t,
        else => return error.InvalidProject,
    } else null;

    var deps: std.ArrayList(Pair) = .empty;
    defer deps.deinit(gpa);
    var weak: std.ArrayList(Pair) = .empty;
    defer weak.deinit(gpa);

    if (weak_tbl) |t| {
        for (t.entries.items) |e| {
            const uuid = switch (e.value) {
                .string => |s| s,
                else => return error.InvalidProject,
            };
            try weak.append(gpa, .{ .name = e.key, .value = uuid });
        }
    }

    if (deps_tbl) |t| {
        for (t.entries.items) |e| {
            // A name in both tables is split out of `deps` at parse time
            // (project.jl:237-238), so it must not be counted twice.
            if (weak_tbl) |w| {
                if (w.contains(e.key)) continue;
            }
            const uuid = switch (e.value) {
                .string => |s| s,
                else => return error.InvalidProject,
            };
            try deps.append(gpa, .{ .name = e.key, .value = uuid });
        }
    }

    // Trap 1: the project is its own direct dep.
    const self_name: ?[]const u8 = if (project.get("name")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;
    const self_uuid: ?[]const u8 = if (project.get("uuid")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;
    if (self_name != null and self_uuid != null) {
        try deps.append(gpa, .{ .name = self_name.?, .value = self_uuid.? });
    }

    // compats are keyed on deps ∪ weakdeps -- note `julia` is in neither.
    var compats: std.ArrayList(Pair) = .empty;
    defer {
        for (compats.items) |c| if (c.owned) gpa.free(@constCast(c.value));
        compats.deinit(gpa);
    }
    for ([_][]const Pair{ deps.items, weak.items }) |group| {
        for (group) |d| {
            const raw: ?[]const u8 = if (compat_tbl) |c| blk: {
                const v = c.get(d.name) orelse break :blk null;
                break :blk switch (v) {
                    .string => |s| s,
                    else => return error.InvalidProject,
                };
            } else null;

            if (raw) |r| {
                const spec = try versions.semverSpec(gpa, r);
                defer spec.deinit(gpa);
                const rendered = try spec.toString(gpa);
                try compats.append(gpa, .{ .name = d.name, .value = rendered, .owned = true });
            } else {
                try compats.append(gpa, .{ .name = d.name, .value = "*" });
            }
        }
    }

    std.mem.sort(Pair, deps.items, {}, lessByName);
    std.mem.sort(Pair, weak.items, {}, lessByName);
    std.mem.sort(Pair, compats.items, {}, lessByName);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    for (deps.items) |d| w.print("{s}={s}\n", .{ d.name, d.value }) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    for (weak.items) |d| w.print("{s}={s}\n", .{ d.name, d.value }) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    for (compats.items) |c| w.print("{s}={s}\n", .{ c.name, c.value }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Lowercase hex SHA-1 of `digestString`.
pub fn compute(gpa: Allocator, project: *const Table) Error![40]u8 {
    const str = try digestString(gpa, project);
    defer gpa.free(str);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(str, &digest, .{});

    var out: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&digest}) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const parseToml = @import("../toml/parse.zig").parse;

/// The real Open-Reality Project.toml, inlined so the test is hermetic.
const open_reality_project =
    \\name = "OpenReality"
    \\uuid = "b08b1914-4d33-46de-8c63-ba029b7f1c5f"
    \\version = "0.1.0"
    \\authors = ["OpenReality Contributors"]
    \\
    \\[deps]
    \\Ark = "56664e29-41e4-4ea5-ab0e-825499acc647"
    \\Base64 = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
    \\ColorTypes = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
    \\CompositionsBase = "a33af91c-f02d-484b-be07-31d278c5ca2b"
    \\FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    \\FreeTypeAbstraction = "663a7486-cb36-511b-a19d-713bb74d65c9"
    \\GLFW = "f7f18e0c-5ee9-5ccd-a5bf-e8befd85ed98"
    \\GLTF = "aeeaf58c-ab4d-11e9-3a9f-9b6bf58b5bc3"
    \\GeometryBasics = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
    \\ImageIO = "82e4d734-157c-48bb-816b-45c225c6df19"
    \\Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
    \\LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
    \\MeshIO = "7269a6da-0436-5bbc-96c2-40638cbb6118"
    \\ModernGL = "66fc600b-dfda-50eb-8b99-91cfa97b1301"
    \\Observables = "510215fc-4207-5dde-b226-833fc4488ee2"
    \\OpenAL_jll = "c52b6589-6b5d-587d-9bb5-adf8a44d3946"
    \\Quaternions = "94ee1d12-ae83-5a48-8b1c-48b8ff168ae0"
    \\Serialization = "9e88b42a-f829-5b0c-bbe9-9e923198166b"
    \\StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    \\TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
    \\glslang_jll = "6fd5517d-459c-5c5a-9b1a-c968b4e37a81"
    \\
    \\[weakdeps]
    \\Vulkan = "9f14b124-c50e-4008-a7d4-969b3a6cd68a"
    \\
    \\[extensions]
    \\OpenRealityVulkanExt = "Vulkan"
    \\
    \\[compat]
    \\Ark = "0.4"
    \\Base64 = "1.11.0"
    \\ColorTypes = "0.11, 0.12"
    \\CompositionsBase = "0.1.2"
    \\FileIO = "1.18.0"
    \\GLFW = "3"
    \\GLTF = "0.4.0"
    \\GeometryBasics = "0.4"
    \\ImageIO = "0.6.9"
    \\MeshIO = "0.4.13"
    \\ModernGL = "1"
    \\Observables = "0.5"
    \\OpenAL_jll = "1.21 - 1.23"
    \\Quaternions = "0.7.7"
    \\StaticArrays = "1.5"
    \\TOML = "1.0.3"
    \\Vulkan = "0.6.29"
    \\julia = "1.9"
    \\
    \\[extras]
    \\Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
    \\Vulkan = "9f14b124-c50e-4008-a7d4-969b3a6cd68a"
    \\
    \\[targets]
    \\test = ["Test"]
    \\
;

test "reproduces Open-Reality's committed project_hash" {
    var doc = try parseToml(testing.allocator, open_reality_project, null);
    defer doc.deinit();

    const got = try compute(testing.allocator, doc.root);
    // The value committed in Open-Reality/Manifest.toml.
    try testing.expectEqualStrings("5e05dae87664a72319978725911531ada717de0f", &got);
}

test "digested string matches Julia's byte for byte" {
    var doc = try parseToml(testing.allocator, open_reality_project, null);
    defer doc.deinit();

    const str = try digestString(testing.allocator, doc.root);
    defer testing.allocator.free(str);

    // Spot-check the three traps rather than inlining 1479 bytes.
    try testing.expect(std.mem.indexOf(u8, str, "OpenReality=b08b1914-4d33-46de-8c63-ba029b7f1c5f\n") != null);
    try testing.expect(std.mem.indexOf(u8, str, "\nOpenReality=*\n") != null);
    try testing.expect(std.mem.indexOf(u8, str, "julia=") == null);
    // Canonical rendering, not the source string.
    try testing.expect(std.mem.indexOf(u8, str, "\nGLTF=0.4\n") != null);
    try testing.expect(std.mem.indexOf(u8, str, "\nColorTypes=0.11 - 0.12\n") != null);
    try testing.expect(std.mem.indexOf(u8, str, "\nFreeTypeAbstraction=*\n") != null);
    // Vulkan is a weakdep: present in block 2 and in compats, absent from block 1.
    try testing.expect(std.mem.indexOf(u8, str, "Vulkan=9f14b124-c50e-4008-a7d4-969b3a6cd68a\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, str, "\nVulkan=0.6.29 - 0.6\n") != null);
    try testing.expectEqual(@as(usize, 1479), str.len);
}

test "a project with neither name nor uuid omits the self entry" {
    var doc = try parseToml(testing.allocator,
        \\[deps]
        \\A = "00000000-0000-0000-0000-000000000001"
        \\
    , null);
    defer doc.deinit();

    const str = try digestString(testing.allocator, doc.root);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A=00000000-0000-0000-0000-000000000001\n\n\nA=*\n", str);
}
