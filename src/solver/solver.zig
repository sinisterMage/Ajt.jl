//! PubGrub dependency resolution.
//!
//! **Vendored from baker** — see VENDOR.md. The solver core (`pubgrub.zig`,
//! `term.zig`, `incompatibility.zig`, `assignment.zig`) is a paper-faithful
//! implementation of Natalie Weizenbaum's PubGrub algorithm: unit
//! propagation, CDCL-style conflict resolution with `findSatisfier` /
//! `previousLevel` / `priorCause`, real backjumping, and a derivation-tree
//! failure reporter.
//!
//! ## Why this composes with Ajt at all
//!
//! The solver is **pure**: it never touches the filesystem or the network,
//! and every registry query flows through the `Registry` vtable below. More
//! importantly it never reaches inside a `VersionSet` — it uses only the set
//! algebra (`complement`, `intersect`, `unionWith`, `difference`,
//! `containsSet`, `isEmpty`, `contains`) plus `Version.order`/`eql`. That is
//! roughly a dozen methods, and it is the entire coupling.
//!
//! ## The seam that was replaced
//!
//! Baker shipped a **SemVer 2.0.0** `version.zig`, and Julia's version
//! semantics are not semver:
//!
//!   * `VersionBound` carries `n`, the count of significant components, and
//!     comparison only spans those — so `1.5.99` is inside the bound `1.5`.
//!   * `≲` ignores prerelease and build metadata, while `VersionNumber`
//!     ordering does not.
//!   * There are two mutually incompatible compat grammars (Project.toml vs
//!     the registry's Compat.toml).
//!   * `VersionRange`'s constructor collapses `lo.t == hi.t`, and `isjoinable`
//!     has an adjacency rule that merges `1.5` with `1.6`.
//!
//! So that file is gone, replaced by `julia_set.zig`: the same interface
//! backed by a **bitset over each package's candidate version list** rather
//! than a range algebra. Not a workaround — the better fit. Complement
//! becomes `~`, trivially correct, whereas complement over a Julia
//! `VersionSpec` is a genuine correctness trap. The only place Julia
//! semantics enter is one function, "is this version in this spec", which is
//! differential-tested against Julia in isolation.
//!
//! All 13 vendored solver tests pass unchanged in substance on the new model.
//! Porting them surfaced three real defects, documented in VENDOR.md — two of
//! them latent bugs in baker's own model, not artefacts of the port.

const std = @import("std");

pub const version = @import("julia_set.zig");
pub const term = @import("term.zig");
pub const incompatibility = @import("incompatibility.zig");
pub const assignment = @import("assignment.zig");
pub const pubgrub = @import("pubgrub.zig");
pub const manifest = @import("manifest.zig");
pub const log = @import("log.zig");

pub const Universe = version.Universe;
pub const Version = version.Version;
pub const Range = version.Range;
pub const VersionSet = version.VersionSet;
pub const Term = term.Term;
pub const PackageRef = term.PackageRef;
pub const Incompatibility = incompatibility.Incompatibility;
pub const PartialSolution = assignment.PartialSolution;
pub const DependencyGraph = pubgrub.DependencyGraph;
pub const Registry = pubgrub.Registry;
pub const SolveError = pubgrub.SolveError;

/// Resolve the dependency closure rooted at `root`. Returns a fully-pinned
/// `DependencyGraph` on success; on failure `writeLastReport` renders the
/// derivation tree that explains why.
pub fn solve(
    root: PackageRef,
    registry: *Registry,
    allocator: std.mem.Allocator,
) pubgrub.SolveError!DependencyGraph {
    return pubgrub.solve(root, registry, allocator);
}

pub const writeLastReport = pubgrub.writeLastReport;
pub const writeLastReportNamed = pubgrub.writeLastReportNamed;
pub const lastBlamed = pubgrub.lastBlamed;
pub const Names = @import("incompatibility.zig").Names;

test {
    _ = @import("julia_set.zig");
    _ = @import("term.zig");
    _ = @import("incompatibility.zig");
    _ = @import("assignment.zig");
    _ = @import("pubgrub.zig");
    _ = @import("manifest.zig");
    _ = @import("log.zig");

    // The 13 vendored solver tests: linear, diamond, branching (incl. a
    // failing case), backjump x2, negative-term x2, learned-clause x2 and
    // singleton x2. These cover exactly the parts of PubGrub where bugs live.
    _ = @import("tests/linear.zig");
    _ = @import("tests/diamond.zig");
    _ = @import("tests/branching.zig");
    _ = @import("tests/backjump.zig");
    _ = @import("tests/negative_term.zig");
    _ = @import("tests/learned_clause.zig");
    _ = @import("tests/singleton.zig");
}
