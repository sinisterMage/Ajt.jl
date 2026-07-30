//! Running a child `julia`: the one seam three operations share.
//!
//! `precompile` was the first module in Ajt to run another program, and its
//! header (`precompile.zig:134-157`) argued three choices. `build` and `test`
//! need all three and would otherwise re-argue them badly, so they live here
//! instead. Nothing in this module knows what a package is; it knows how to
//! start a process safely and how to hand back what it said.
//!
//!   * **`std.process.run`, not a long-lived `Child` with pipes.** Each
//!     invocation is one short-lived process whose entire output fits in
//!     memory, and `run` is the only form that reads stdout and stderr
//!     concurrently -- it drives an `Io.File.MultiReader` over both
//!     (`std/process.zig:511-518`). A `Child` with two pipes read in sequence
//!     deadlocks the moment the child writes more than a pipe buffer, which
//!     for a precompile is a screenful of `@warn`s and for a `deps/build.jl`
//!     is one `Downloading` progress bar.
//!   * **One process per unit of work.** A package that OOMs or segfaults the
//!     compiler takes down its own child; the rest still run. It is also the
//!     seam a scheduler needs -- a work queue of independent processes.
//!   * **The environment is BUILT, not inherited.** See `environ`.
//!
//! ### No timeout, deliberately
//!
//! `RunOptions.timeout` defaults to `.none` (`std/process.zig:527`) and every
//! caller here leaves it there. A child can legitimately block for a long
//! time: a big precompile is minutes, a contended depot sits in `mkpidlock`
//! waiting for whoever is already building the entry, and a `deps/build.jl`
//! may be downloading a tarball. `Pkg` blocks in exactly the same places and
//! bounds the wait with Julia's own pidfile staleness rules rather than with a
//! clock. A timeout could only make things worse: killing a child
//! mid-`compilecache` is how a half-written `.ji` gets left behind, and killing
//! one mid-`build.jl` leaves a half-unpacked `deps/` that the next run believes.
//!
//! ### Allocation
//!
//! `run` returns two `gpa`-owned slices and nothing else; `Output.deinit`
//! frees them. `environ` returns a `Map` owned by the allocator it was given.
//! Neither borrows from the other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The probe in `precompile` prints one short line per package; 214 entries is
/// ~40 KB. `compilecache` streams a package's own precompile output -- `@warn`s,
/// `Downloading artifact` chatter, occasionally a megabyte of method-overwrite
/// warnings -- into stderr. A `deps/build.jl` can print either way and there is
/// no protocol on its output at all. The caps exist so a wedged child cannot
/// make this process grow without bound, not as a prediction about any
/// particular package.
pub const default_stdout_limit = 1024 * 1024;
pub const default_stderr_limit = 8 * 1024 * 1024;

/// One environment variable to force on the child. A null `value` UNSETS it,
/// which is not the same as setting it empty: `JULIA_DEPOT_PATH=""` is a real
/// configuration Julia raises on, and `JULIA_PROJECT=""` is not the same as no
/// `JULIA_PROJECT` at all (`withenv(f, "JULIA_PROJECT" => nothing)`,
/// `Operations.jl:2311`).
pub const Var = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// The environment a child gets: the parent's, plus exactly the overrides
/// named.
///
/// **Built, not inherited wholesale, and not built from nothing either.** Both
/// extremes are wrong and each has a failure Ajt has already paid for:
///
///   * Inheriting unchanged means the caller's ambient `JULIA_DEPOT_PATH`
///     decides where a cache entry lands (`compilecache_dir`,
///     `loading.jl:3147-3150`) and where a `build.jl` writes -- so a child
///     started from a shell with a project active can scribble into a depot
///     the operation was never pointed at.
///   * Starting from an EMPTY map loses `PATH` and `HOME`, and critically
///     `JULIA_CPU_TARGET`, which is mixed into the cache filename
///     (`loading.jl:3164-3169`). A depot built at one CPU target and loaded by
///     a Julia that inherited a different default produces cache misses with
///     no error anywhere.
///
/// So: clone the parent, then overwrite (or remove) exactly the names the
/// caller lists. `parent` of null yields a map holding only the overrides,
/// which is almost never what a caller wants -- it is offered for tests.
///
/// `orderedRemove` rather than `swapRemove`: the map's iteration order becomes
/// the child's `environ` block, and a stable one makes a failing invocation
/// reproducible from a log.
pub fn environ(
    gpa: Allocator,
    parent: ?*const std.process.Environ.Map,
    vars: []const Var,
) Allocator.Error!std.process.Environ.Map {
    var map = if (parent) |p| try p.clone(gpa) else std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    for (vars) |v| {
        if (v.value) |value| {
            try map.put(v.name, value);
        } else {
            _ = map.orderedRemove(v.name);
        }
    }
    return map;
}

pub const Request = struct {
    /// `argv[0]` is resolved through the PARENT's environment whatever
    /// `environ_map` says (`std/process.zig:507-509`), so a caller that wants a
    /// specific Julia must pass an absolute path rather than relying on a
    /// `PATH` it put in the child map.
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    stdout_limit: usize = default_stdout_limit,
    stderr_limit: usize = default_stderr_limit,
};

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// Wall time of the child, in milliseconds.
    ms: f64,

    pub fn deinit(self: *Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }

    /// The exit status when the child exited normally, null when a signal
    /// ended it.
    ///
    /// A signal is not an exit status, and the distinction is worth keeping:
    /// a package big enough to be OOM-killed (or a compiler that segfaults on
    /// it) lands in the null case, where the stderr tail is usually empty and
    /// an exit code would be a lie.
    pub fn exitCode(self: Output) ?u8 {
        return switch (self.term) {
            .exited => |c| c,
            else => null,
        };
    }

    pub fn succeeded(self: Output) bool {
        return (self.exitCode() orelse 1) == 0;
    }
};

/// Spawn, wait, collect. See the module header for what is deliberately absent.
pub fn run(gpa: Allocator, io: Io, req: Request) !Output {
    const t0 = Io.Clock.awake.now(io);
    const res = try std.process.run(gpa, io, .{
        .argv = req.argv,
        .environ_map = req.environ,
        .stdout_limit = .limited(req.stdout_limit),
        .stderr_limit = .limited(req.stderr_limit),
    });
    const d = t0.durationTo(Io.Clock.awake.now(io));
    return .{
        .term = res.term,
        .stdout = res.stdout,
        .stderr = res.stderr,
        .ms = @as(f64, @floatFromInt(d.nanoseconds)) / 1e6,
    };
}

/// A child whose OUTPUT IS THE PRODUCT: both streams are inherited and nothing
/// is captured.
///
/// `Pkg.test` runs the test process as `run(pipeline(ignorestatus(cmd); stdout,
/// stderr), wait = false)` where `stdout` is `ctx.io` and `stderr` is the real
/// one (`subprocess_handler`, `Operations.jl:2547-2553`) — a test suite's
/// output goes to the terminal AS IT HAPPENS. Capturing it the way `run` does
/// would be wrong twice over: a suite that takes ten minutes would print
/// nothing until it finished, and a `@testset` that draws a progress line would
/// arrive as one dump at the end.
///
/// Capturing is also what forces the caps in `run`, and those exist because a
/// captured stream grows this process's memory. Nothing is captured here, so
/// there is nothing to cap.
///
/// The default `StdIo` for all three streams is `.inherit`
/// (`std/process.zig:380-382`), so the absence of a `stdout`/`stderr` field
/// below is the behaviour, not an omission.
pub const Streamed = struct {
    term: std.process.Child.Term,
    ms: f64,

    pub fn exitCode(self: Streamed) ?u8 {
        return switch (self.term) {
            .exited => |c| c,
            else => null,
        };
    }

    /// The signal that ended the child, if one did — `Base.process_signaled(p)`
    /// / `p.termsignal` (`Operations.jl:2527-2528`), which `test` turns into
    /// " (received signal: KILL)" in its failure message.
    pub fn signal(self: Streamed) ?std.posix.SIG {
        return switch (self.term) {
            .signal => |s| s,
            else => null,
        };
    }

    pub fn succeeded(self: Streamed) bool {
        return (self.exitCode() orelse 1) == 0;
    }
};

/// Spawn with both streams inherited, wait, report how it ended.
///
/// `ignorestatus(cmd)` in Pkg means a non-zero exit is a value, not a throw,
/// and the same is true here: the `Term` comes back and the caller decides.
pub fn runStreamed(
    io: Io,
    /// `argv[0]` is resolved through the PARENT's environment, exactly as in
    /// `Request` — see the note there.
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
) !Streamed {
    const t0 = Io.Clock.awake.now(io);
    var proc = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
    });
    const term = try proc.wait(io);
    const d = t0.durationTo(Io.Clock.awake.now(io));
    return .{ .term = term, .ms = @as(f64, @floatFromInt(d.nanoseconds)) / 1e6 };
}

/// The LAST `n` bytes, not the first. Julia prints the error and the
/// stacktrace last, so a head would keep the part nobody needs.
pub fn tail(bytes: []const u8, n: usize) []const u8 {
    if (bytes.len <= n) return bytes;
    return bytes[bytes.len - n ..];
}

/// The last `n` LINES, which is what `build_versions` shows on a failure
/// (`Operations.jl:1495-1497`).
///
/// Pkg's slice is `log_lines[max(1, length(log_lines) - n_lines):end]`, which
/// yields `n_lines + 1` lines, not `n_lines` -- an off-by-one in Pkg that this
/// reproduces rather than fixes, because the string it produces is the one the
/// error message is gated against.
pub fn tailLines(bytes: []const u8, n: usize) []const u8 {
    if (bytes.len == 0) return bytes;
    // `readlines` drops a single trailing newline; a text file that ends in
    // one has no empty final element. Trim it before counting or the last
    // "line" is the empty string after it.
    const body = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
    var total: usize = 1;
    for (body) |c| {
        if (c == '\n') total += 1;
    }
    // `max(1, total - n)` is a 1-BASED index; keeping from there means keeping
    // `total - (total - n) + 1 = n + 1` lines. Ported literally.
    if (total <= n) return body;
    const first_kept = total - n; // 1-based, and > 1 here
    var seen: usize = 0;
    for (body, 0..) |c, i| {
        if (c != '\n') continue;
        seen += 1;
        if (seen == first_kept - 1) return body[i + 1 ..];
    }
    return body;
}

/// How many lines `readlines` would return -- the number Pkg compares against
/// `n_lines` to decide whether to say "showing the last N of log".
pub fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const body = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
    var total: usize = 1;
    for (body) |c| {
        if (c == '\n') total += 1;
    }
    return total;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "environ overrides and unsets against a parent" {
    var parent = std.process.Environ.Map.init(testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("JULIA_PROJECT", "/somewhere");
    try parent.put("JULIA_CPU_TARGET", "generic");

    var child = try environ(testing.allocator, &parent, &.{
        .{ .name = "JULIA_DEPOT_PATH", .value = "/scratch" },
        .{ .name = "JULIA_PROJECT", .value = null },
    });
    defer child.deinit();

    // Inherited untouched -- the two that decide whether a cache entry is
    // even addressable.
    try testing.expectEqualStrings("/usr/bin", child.get("PATH").?);
    try testing.expectEqualStrings("generic", child.get("JULIA_CPU_TARGET").?);
    try testing.expectEqualStrings("/scratch", child.get("JULIA_DEPOT_PATH").?);
    // Unset, not emptied.
    try testing.expect(child.get("JULIA_PROJECT") == null);
    // And the parent is untouched: `clone`, not a mutation in place.
    try testing.expectEqualStrings("/somewhere", parent.get("JULIA_PROJECT").?);
}

test "environ with no parent holds only the overrides" {
    var child = try environ(testing.allocator, null, &.{
        .{ .name = "JULIA_LOAD_PATH", .value = "@:@stdlib" },
    });
    defer child.deinit();
    try testing.expectEqual(@as(usize, 1), child.count());
}

test "tail keeps the end" {
    try testing.expectEqualStrings("cde", tail("abcde", 3));
    try testing.expectEqualStrings("abc", tail("abc", 3));
    try testing.expectEqualStrings("abc", tail("abc", 99));
    try testing.expectEqualStrings("", tail("abc", 0));
}

test "tailLines reproduces Pkg's off-by-one" {
    // Five lines, asked for the last two: Pkg's `log_lines[max(1, 5-2):end]`
    // is `log_lines[3:end]`, i.e. THREE lines. Not a bug being fixed here.
    const log = "a\nb\nc\nd\ne\n";
    try testing.expectEqual(@as(usize, 5), countLines(log));
    try testing.expectEqualStrings("c\nd\ne", tailLines(log, 2));
    // Asking for at least as many as there are keeps everything, minus the
    // trailing newline `readlines` drops.
    try testing.expectEqualStrings("a\nb\nc\nd\ne", tailLines(log, 5));
    try testing.expectEqualStrings("a\nb\nc\nd\ne", tailLines(log, 99));
    try testing.expectEqualStrings("", tailLines("", 5));
    // No trailing newline: still five lines.
    try testing.expectEqual(@as(usize, 5), countLines("a\nb\nc\nd\ne"));
    try testing.expectEqualStrings("c\nd\ne", tailLines("a\nb\nc\nd\ne", 2));
}
