//! Ajt — Advanced Julia Tools.
//!
//! A drop-in replacement for Julia's Pkg.jl. This module is the library root;
//! the CLI in src/main.zig is a thin shell over it.
//!
//! Layering rule: `toml/`, and later `julia/` and `solver/`, perform no I/O and
//! allocate only through a passed-in allocator. That is what makes them
//! exhaustively unit-testable and fuzzable, and correctness lives there.

const std = @import("std");

/// Ports of Julia's own semantics. No I/O, allocator passed in -- these are
/// the modules where "agrees with Julia exactly" is the whole specification,
/// so they are differential-tested against Julia rather than reasoned about.
pub const julia = struct {
    pub const slug = @import("julia/slug.zig");
    pub const version = @import("julia/version.zig");
    pub const versions = @import("julia/versions.zig");
    pub const project_hash = @import("julia/project_hash.zig");
    pub const treehash = @import("julia/treehash.zig");
    pub const platform = @import("julia/platform.zig");

    pub const Uuid = slug.Uuid;
    pub const Sha1 = slug.Sha1;
    pub const packageSlug = slug.packageSlug;
    pub const versionSlug = slug.versionSlug;
    pub const Version = version.Version;
    pub const VersionSpec = versions.Spec;
    pub const semverSpec = versions.semverSpec;
    pub const projectHash = project_hash.compute;
};

pub const registry = struct {
    pub const tarball = @import("registry/tarball.zig");
    pub const index = @import("registry/index.zig");
    pub const Archive = tarball.Archive;
    pub const Registry = index.Registry;
    pub const open = index.open;
    pub const loadPackage = index.loadPackage;
};

pub const toml = struct {
    pub const value = @import("toml/value.zig");
    pub const parse_mod = @import("toml/parse.zig");
    pub const emit_mod = @import("toml/emit.zig");

    pub const Value = value.Value;
    pub const Table = value.Table;
    pub const Entry = value.Entry;
    pub const DateTime = value.DateTime;
    pub const Document = value.Document;

    pub const parse = parse_mod.parse;
    pub const Diagnostic = parse_mod.Diagnostic;
    pub const ParseError = parse_mod.Error;

    pub const emit = emit_mod.emit;
    pub const EmitOptions = emit_mod.Options;
};

test {
    // Pull every module's test blocks into the test binary. Zig 0.16 dropped
    // testing.refAllDeclsRecursive, and the non-recursive refAllDecls does not
    // reach through the nested `toml` namespace, so reference them directly.
    _ = @import("toml/value.zig");
    _ = @import("toml/parse.zig");
    _ = @import("toml/emit.zig");
    _ = @import("julia/slug.zig");
    _ = @import("julia/version.zig");
    _ = @import("julia/versions.zig");
    _ = @import("julia/project_hash.zig");
    _ = @import("julia/treehash.zig");
    _ = @import("julia/platform.zig");
    _ = @import("registry/tarball.zig");
    _ = @import("registry/index.zig");
}
