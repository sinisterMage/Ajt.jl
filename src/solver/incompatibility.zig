//! PubGrub incompatibilities + CDCL derivation-tree reporter.
//!
//! An `Incompatibility` is a conjunction of `Term`s that must not all hold
//! simultaneously. Every fact the solver ever learns — "the root exists",
//! "A@V depends on B in R", "no versions of X match R", a two-singleton
//! conflict, a learned clause from conflict resolution — is recorded as an
//! incompatibility with a tagged `Cause`.
//!
//! On failure the solver hands the unresolvable root incompatibility to
//! `writeReport`, which walks the `Cause` tree and emits a "because" chain
//! that traces back to the original manifest constraints.
const std = @import("std");
const term_mod = @import("term.zig");
const ver = @import("julia_set.zig");
const Allocator = std.mem.Allocator;
const Term = term_mod.Term;
const PackageRef = term_mod.PackageRef;

/// Why an incompatibility exists. The union payload is used by the failure
/// reporter to render human-readable derivation trees.
pub const Cause = union(enum) {
    /// The root of the resolution: `{not root = root.version}` — asserts
    /// that the root package must be in the solution.
    root,

    /// "Package A@V depends on B constraint" — encoded as two terms:
    /// `{A = V, not B in range}`.
    dependency: struct {
        depender_name: []const u8,
        depender_version: ver.Version,
        dependee_name: []const u8,
    },

    /// "Package X has no versions matching this constraint" — a single
    /// positive term says the set is required to be non-empty; the
    /// registry has no version in it.
    no_versions: []const u8,

    /// Conflict-resolution derived incompatibility: the resolvent of two
    /// prior incompatibilities on some package.
    conflict: struct {
        a: *Incompatibility,
        b: *Incompatibility,
        /// Package that was resolved away (i.e., the term was replaced by
        /// the union of the two parent terms and, if that union became
        /// universal, dropped).
        pkg: []const u8,
    },

    /// `no_versioning = true` package attempted to appear at two distinct
    /// versions. The two terms pin it to two incompatible singletons.
    singleton: []const u8,
};

/// A PubGrub incompatibility: a conjunction of terms that must NOT all
/// hold. Stored as a flat, caller-owned slice.
pub const Incompatibility = struct {
    terms: []Term,
    cause: Cause,

    pub fn format(self: Incompatibility, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.terms.len == 0) {
            try w.writeAll("{version solving failed}");
            return;
        }
        try w.writeAll("{");
        for (self.terms, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{f}", .{t});
        }
        try w.writeAll("}");
    }

    /// Find the term over package `pkg`, if any. Linear scan; |terms| is
    /// tiny in practice.
    pub fn termFor(self: Incompatibility, pkg: []const u8) ?Term {
        for (self.terms) |t| if (std.mem.eql(u8, t.pkg, pkg)) return t;
        return null;
    }

    /// Does any term in the incompat mention `pkg`?
    pub fn mentions(self: Incompatibility, pkg: []const u8) bool {
        return self.termFor(pkg) != null;
    }

    /// Format a friendly single-line explanation.
    pub fn describeCause(self: Incompatibility, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.describeCauseNamed(w, null);
    }

    /// As `describeCause`, but routing every package key through `names`.
    ///
    /// The solver keys packages by an opaque string and Ajt makes that key the
    /// UUID, because a name is not unique in the General registry. Correct for
    /// solving, unreadable in a report: the raw form of this message is
    /// `a93c6f00-e57d-5684-b7b6-d8193f3e46c0@1.8.2 depends on
    /// 842dd82b-1e85-43dc-bf29-5d0ee9dffc48`, and a person reading that
    /// learns nothing about which packages they are supposed to relax.
    pub fn describeCauseNamed(
        self: Incompatibility,
        w: *std.Io.Writer,
        names: ?Names,
    ) std.Io.Writer.Error!void {
        switch (self.cause) {
            .root => try w.writeAll("the root package is required"),
            .dependency => |d| try w.print(
                "{s}@{f} depends on {s}",
                .{ Names.get(names, d.depender_name), d.depender_version, Names.get(names, d.dependee_name) },
            ),
            .no_versions => |name| try w.print(
                "no versions of {s} match the constraint",
                .{Names.get(names, name)},
            ),
            .conflict => |c| try w.print(
                "combining the two facts above rules out {s}",
                .{Names.get(names, c.pkg)},
            ),
            .singleton => |name| try w.print(
                "{s} is a singleton (no_versioning) package and cannot coexist at two versions",
                .{Names.get(names, name)},
            ),
        }
    }
};

/// Maps a solver package key to something worth showing a person. Supplied by
/// whoever built the incompatibilities — only they know what the keys mean.
pub const Names = struct {
    ctx: *const anyopaque,
    lookup: *const fn (ctx: *const anyopaque, key: []const u8) []const u8,

    /// The display name for `key`, or `key` itself when there is no resolver.
    /// Static so every call site can pass an optional without unwrapping.
    pub fn get(self: ?Names, key: []const u8) []const u8 {
        const n = self orelse return key;
        return n.lookup(n.ctx, key);
    }
};

/// Walk the derivation tree rooted at `root` and append a human-readable
/// report to `w`. Leaf incompatibilities (root/dependency/no_versions/
/// singleton) print as a single "because" line; learned `.conflict`
/// incompatibilities recursively print their two parents first.
pub fn writeReport(root: *Incompatibility, w: *std.Io.Writer) !void {
    return writeReportNamed(root, w, null);
}

pub fn writeReportNamed(root: *Incompatibility, w: *std.Io.Writer, names: ?Names) !void {
    try w.writeAll("Because:\n");
    try writeNode(root, w, 0, names);
    try w.writeAll("version solving failed.\n");
}

fn writeNode(
    node: *Incompatibility,
    w: *std.Io.Writer,
    depth: usize,
    names: ?Names,
) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");

    switch (node.cause) {
        .conflict => |c| {
            try w.writeAll("- ");
            try node.describeCauseNamed(w, names);
            try w.writeAll(":\n");
            // Conflict resolution eliminates ONE version per learned clause,
            // so ruling out a package with seven candidates produces seven
            // nested nodes that all say "rules out InlineStrings" and differ
            // only in which version each leaf mentions. Printing that chain
            // verbatim buries the leaves — the actual constraints — under a
            // wall of identical text, indented past the edge of the screen.
            //
            // Collapsing a same-package chain into one heading loses no fact:
            // every leaf still appears, at one level, under the single claim
            // they jointly support. What is dropped is the intermediate
            // clauses, each of which concludes exactly what its parent does.
            try writeChildren(c.a, c.b, w, depth + 1, names, c.pkg);
        },
        else => {
            try w.writeAll("- ");
            try node.describeCauseNamed(w, names);
            try w.writeAll(" (");
            try writeTerms(node, w, names);
            try w.writeAll(")\n");
        },
    }
}

/// Print the two parents of a conflict, splicing any parent that is itself a
/// conflict over the SAME package into this level instead of nesting.
fn writeChildren(
    a: *Incompatibility,
    b: *Incompatibility,
    w: *std.Io.Writer,
    depth: usize,
    names: ?Names,
    pkg: []const u8,
) std.Io.Writer.Error!void {
    for ([_]*Incompatibility{ a, b }) |child| {
        switch (child.cause) {
            .conflict => |cc| if (std.mem.eql(u8, cc.pkg, pkg)) {
                try writeChildren(cc.a, cc.b, w, depth, names, pkg);
                continue;
            },
            else => {},
        }
        try writeNode(child, w, depth, names);
    }
}

/// The incompatibility's terms, with package keys resolved. `Incompatibility`
/// and `Term` both have a `format` method, but those are the raw debug forms
/// and they print the key — which is the whole problem this is here to solve.
fn writeTerms(node: *Incompatibility, w: *std.Io.Writer, names: ?Names) std.Io.Writer.Error!void {
    if (node.terms.len == 0) return w.writeAll("version solving failed");
    try w.writeAll("{");
    for (node.terms, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        if (!t.positive) try w.writeAll("not ");
        try w.print("{s} {f}", .{ Names.get(names, t.pkg), t.set });
    }
    try w.writeAll("}");
}

/// Every package a failed derivation actually blames, deduplicated, in the
/// order first seen. The tree above is a faithful proof and a poor summary: a
/// real conflict nests dozens of levels deep and repeats the same learned
/// clause, so the packages worth editing are the hardest thing to find in it.
/// This is what a "to fix, try" line is built from.
pub fn collectBlamed(
    root: *Incompatibility,
    out: *std.ArrayList([]const u8),
    gpa: Allocator,
) Allocator.Error!void {
    switch (root.cause) {
        .conflict => |c| {
            try collectBlamed(c.a, out, gpa);
            try collectBlamed(c.b, out, gpa);
        },
        .dependency => |d| {
            try addUnique(out, gpa, d.depender_name);
            try addUnique(out, gpa, d.dependee_name);
        },
        .no_versions => |n| try addUnique(out, gpa, n),
        .singleton => |n| try addUnique(out, gpa, n),
        .root => {},
    }
}

fn addUnique(out: *std.ArrayList([]const u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    try out.append(gpa, s);
}

/// Allocate a new incompatibility owning a copy of `terms`.
pub fn make(allocator: Allocator, terms: []const Term, cause: Cause) !*Incompatibility {
    const ic = try allocator.create(Incompatibility);
    ic.* = .{
        .terms = try allocator.dupe(Term, terms),
        .cause = cause,
    };
    return ic;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A `Names` over a fixed key->name table, which is all the reporter asks for.
const TestNames = struct {
    pairs: []const [2][]const u8,

    fn resolver(self: *const TestNames) Names {
        return .{ .ctx = @ptrCast(self), .lookup = lookup };
    }
    fn lookup(ctx: *const anyopaque, key: []const u8) []const u8 {
        const self: *const TestNames = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], key)) return p[1];
        }
        return key;
    }
};

/// Universe with one version, so a `.dependency` cause has something to carry.
/// Terms stay empty: the flattening and naming under test are properties of
/// the CAUSE tree, and empty terms keep the fixture to the thing being tested.
fn oneVersionUniverse(gpa: Allocator) !*ver.Universe {
    const vs = try gpa.alloc(@import("../julia/version.zig").Version, 1);
    vs[0] = .{ .major = 1, .minor = 0, .patch = 0 };
    const u = try gpa.create(ver.Universe);
    u.* = ver.Universe.init("U", vs, &.{});
    return u;
}

test "the report resolves package keys through Names" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try oneVersionUniverse(g);

    const dep = try make(g, &.{}, .{ .dependency = .{
        .depender_name = "aaaaaaaa-0000-0000-0000-000000000001",
        .depender_version = .{ .universe = u, .idx = 0 },
        .dependee_name = "aaaaaaaa-0000-0000-0000-000000000002",
    } });

    const table = TestNames{ .pairs = &.{
        .{ "aaaaaaaa-0000-0000-0000-000000000001", "DataFrames" },
        .{ "aaaaaaaa-0000-0000-0000-000000000002", "InlineStrings" },
    } };

    var buf: std.Io.Writer.Allocating = .init(g);
    try writeReportNamed(dep, &buf.writer, table.resolver());
    try testing.expect(std.mem.indexOf(u8, buf.written(), "DataFrames@1.0.0 depends on InlineStrings") != null);
    // And without a resolver the raw keys still come through, so the debug
    // form is not quietly lost.
    var raw: std.Io.Writer.Allocating = .init(g);
    try writeReport(dep, &raw.writer);
    try testing.expect(std.mem.indexOf(u8, raw.written(), "aaaaaaaa-0000-0000-0000-000000000001@1.0.0") != null);
}

test "a same-package conflict chain collapses to one heading, keeping every leaf" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try oneVersionUniverse(g);

    // Three learned clauses that all conclude something about "X", each
    // eliminating one version — the shape conflict resolution actually
    // produces, and the one that used to print three identical headings at
    // three indentation levels.
    var node = try make(g, &.{}, .{ .no_versions = "leaf0" });
    for (0..3) |i| {
        const leaf = try make(g, &.{}, .{ .dependency = .{
            .depender_name = "X",
            .depender_version = .{ .universe = u, .idx = 0 },
            .dependee_name = if (i == 0) "leafA" else if (i == 1) "leafB" else "leafC",
        } });
        node = try make(g, &.{}, .{ .conflict = .{ .a = node, .b = leaf, .pkg = "X" } });
    }

    var buf: std.Io.Writer.Allocating = .init(g);
    try writeReportNamed(node, &buf.writer, null);
    const text = buf.written();

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "rules out X"));
    // Nothing was summarised away: all four leaves are still there.
    for ([_][]const u8{ "leaf0", "leafA", "leafB", "leafC" }) |leaf| {
        try testing.expect(std.mem.indexOf(u8, text, leaf) != null);
    }
    // ...and at ONE indentation level, which is the readability claim.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\n  - X@1.0.0 depends on"));
}

test "collectBlamed dedupes and skips the root" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    const u = try oneVersionUniverse(g);

    const d1 = try make(g, &.{}, .{ .dependency = .{
        .depender_name = "A",
        .depender_version = .{ .universe = u, .idx = 0 },
        .dependee_name = "B",
    } });
    const d2 = try make(g, &.{}, .{ .dependency = .{
        .depender_name = "A",
        .depender_version = .{ .universe = u, .idx = 0 },
        .dependee_name = "C",
    } });
    const rt = try make(g, &.{}, .root);
    const inner = try make(g, &.{}, .{ .conflict = .{ .a = d1, .b = d2, .pkg = "A" } });
    const top = try make(g, &.{}, .{ .conflict = .{ .a = inner, .b = rt, .pkg = "root" } });

    var out: std.ArrayList([]const u8) = .empty;
    try collectBlamed(top, &out, g);
    // A once, not twice; `.root` contributes nothing to blame.
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("A", out.items[0]);
    try testing.expectEqualStrings("B", out.items[1]);
    try testing.expectEqualStrings("C", out.items[2]);
}
