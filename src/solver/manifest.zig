//! The package metadata the solver consumes.
//!
//! This is a deliberately minimal seam. Baker's own `manifest.zig` is 266
//! lines describing build recipes, artifacts and build systems, but the
//! solver reads exactly two fields from it — `depends` and `no_versioning` —
//! so vendoring the rest would drag in concepts Ajt has no use for.
//!
//! Ajt's registry layer will produce these from `registry/index.zig`'s
//! already-uncompressed dependency data.

const std = @import("std");
const ver = @import("julia_set.zig");

pub const Dependency = struct {
    name: []const u8,
    range: ver.Range,
    /// A WEAK edge (Julia's `[weakdeps]`): it does not require the package,
    /// it only constrains it if something else selects it.
    ///
    /// This changes the SHAPE of the incompatibility the solver emits, not
    /// just its contents — see `pubgrub.zig`'s dependency loop. Baker had no
    /// such concept; the field is an Ajt addition at the seam.
    weak: bool = false,

    pub fn format(self: Dependency, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {f}", .{ self.name, self.range });
    }
};

pub const Manifest = struct {
    name: []const u8,
    version: ver.Version,
    depends: []Dependency = &.{},
    /// Baker used this for packages installed side-by-side at many versions.
    /// The solver treats such a package as a singleton — at most one version
    /// may be selected — which is exactly what Ajt needs for a Julia package,
    /// since a Julia environment holds one version of each UUID.
    no_versioning: bool = false,
};
