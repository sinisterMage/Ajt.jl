//! `Base`'s environment-variable predicates.
//!
//! One function, and it earns a module because three call sites in Ajt need it
//! and the two that predate this one spelled it two different ways:
//! `ops/registry_ops.zig`'s `getBoolEnv` had the full table, while
//! `git/git.zig`'s private `boolEnv` accepts only the lowercase spellings.
//! That difference is invisible until someone writes `JULIA_PKG_OFFLINE=TRUE`
//! — Base says true, a lowercase-only reader says false, and Ajt is silently
//! online where Pkg is offline. A single table is the only way that class of
//! bug stays fixed.

const std = @import("std");

/// The recognised truthy spellings, verbatim (`base/env.jl:117-122`). Note the
/// set is CLOSED and exact: lowercase, Capitalized and UPPERCASE only, so
/// `tRue` is in neither list and `on`/`off` are in neither either.
pub const truthy = [_][]const u8{
    "t",    "T",
    "true", "True",
    "TRUE", "y",
    "Y",    "yes",
    "Yes",  "YES",
    "1",
};

/// (`base/env.jl:123-128`).
pub const falsy = [_][]const u8{
    "f",     "F",
    "false", "False",
    "FALSE", "n",
    "N",     "no",
    "No",    "NO",
    "0",
};

/// A value in neither table. `parse_bool_env` returns `nothing` for it
/// (`base/env.jl:150-159`, `throw` defaults to false), and every caller in
/// Julia then does something abrupt with that `nothing` — see the two users
/// of this function for what each one is.
pub const Error = error{UnrecognisedBoolEnv};

/// `Base.get_bool_env(name, default)` (`base/env.jl:142-151`).
///
/// Three states, not two, and the third is the one that gets forgotten: an
/// UNSET variable and an EMPTY one both fall back to `default` (`:144-147`
/// tests `haskey` and then `!isempty`), while an unrecognised value is neither
/// true nor false.
pub fn getBool(raw: ?[]const u8, default: bool) Error!bool {
    const v = raw orelse return default;
    if (v.len == 0) return default;
    for (truthy) |t| if (std.mem.eql(u8, v, t)) return true;
    for (falsy) |f| if (std.mem.eql(u8, v, f)) return false;
    return error.UnrecognisedBoolEnv;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the truthy and falsy tables are Base's, exactly" {
    // Oracle, run against Julia 1.12.6:
    //   for v in ("1","true","t","T","True","TRUE","yes","Yes","YES","y","Y")
    //       ENV["X"] = v; @assert Base.get_bool_env("X", false) === true
    //   end
    // and the same with the falsy list against `=== false`. The pairs are what
    // `JULIA_PKG_OFFLINE` was measured on: `on`, `off` and `garbage` all abort
    // `using Pkg` with a MethodError from `OFFLINE_MODE[] = nothing`.
    for (truthy) |v| try testing.expect(try getBool(v, false));
    for (falsy) |v| try testing.expect(!try getBool(v, true));

    try testing.expectError(error.UnrecognisedBoolEnv, getBool("on", false));
    try testing.expectError(error.UnrecognisedBoolEnv, getBool("off", false));
    try testing.expectError(error.UnrecognisedBoolEnv, getBool("tRue", false));
    try testing.expectError(error.UnrecognisedBoolEnv, getBool("2", false));
}

test "unset and empty both fall back to the default" {
    try testing.expect(try getBool(null, true));
    try testing.expect(!try getBool(null, false));
    // `!isempty(val)` (`base/env.jl:146`) — an empty value is NOT a parse
    // failure, it is an unset one.
    try testing.expect(try getBool("", true));
    try testing.expect(!try getBool("", false));
}
