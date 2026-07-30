//! Depot usage logs -- `<depot>/logs/*_usage.toml`.
//!
//! ## Why this file exists
//!
//! `Pkg.gc()` decides what in a depot is garbage by reading these logs and
//! nothing else. It sweeps `packages/`, `artifacts/`, `clones/` and
//! `scratchspaces/` (`API.jl:969`, `:985`, `:996`, `:1008`), and it keeps only
//! what is reachable from an index file (`Manifest.toml`, `Artifacts.toml`)
//! that BOTH appears as a key in a usage log AND still exists on disk --
//! the keys are collected at `API.jl:674-675`, filtered by
//! `Pkg.isfile_nothrow` at `:684-685`, and turned into a keep-set by `mark`
//! at `:848-873`. Everything else is orphaned and, after `collect_delay`,
//! deleted.
//!
//! So a depot that Ajt filled and Julia never independently touched is, to
//! `Pkg.gc()`, entirely garbage. Measured on this machine: `ajt install` +
//! `ajt install-artifacts` into a scratch depot, then
//! `Pkg.gc(collect_delay = Second(0))` -> "Deleted 3 package installations,
//! 1 artifact installation". With the logs written, the same run deletes
//! nothing. That is the whole point of this module.
//!
//! And it does not take an explicit `Pkg.gc()`. `Pkg._auto_gc`
//! (`Pkg/src/Pkg.jl:863-889`) fires a full collection whenever
//! `logs/orphaned.toml` is older than `collect_delay`, on `up`, `pin`, `free`
//! and `rm` (`API.jl:171`, unless `JULIA_PKG_GC_AUTO` says otherwise). A plain
//! `Pkg.rm` in an Ajt-populated depot is enough.
//!
//! ## The three log files
//!
//! Established by reading `Pkg/src/` and confirmed by running Julia against a
//! throwaway depot (`tools/diff_harness/usage.sh` re-runs the confirmation):
//!
//!  * `manifest_usage.toml` -- written by the `EnvCache` constructor
//!    (`Types.jl:426`), so EVERY Pkg operation that loads an environment
//!    stamps it. Key: the environment's `Manifest.toml`, absolute
//!    (`Types.jl:422-425` runs it through `abspath`).
//!  * `artifact_usage.toml` -- written at the end of `download_artifacts`
//!    (`Operations.jl:1080`) and by `bind_artifact!` (`Artifacts.jl:278`).
//!    Key: each `(Julia)Artifacts.toml` that was consulted, absolute. Note
//!    `used_artifact_tomls` is `Set(map(first, all_collected_artifacts))`
//!    (`Operations.jl:951-952`) -- a file with no downloadable artifact for
//!    this host is still logged, so an all-lazy JLL keeps its entry.
//!  * `scratch_usage.toml` -- written by `build_versions` when it puts a
//!    package's `build.log` in a scratchspace (`Operations.jl:1463-1470`).
//!    Its entries carry a `parent_projects` array as well as `time`, and the
//!    PRODUCER appends (`open(..., "a")`) rather than rewriting -- only `gc`
//!    ever condenses it (`API.jl:733-755`). `record` refuses this file
//!    OUTRIGHT and always will: `write_env_usage`'s condensation would drop
//!    `parent_projects`, and `gc` reads that key UNCONDITIONALLY
//!    (`API.jl:664`) -- so the result would not be a subtly weaker log, it
//!    would be a `KeyError` out of every subsequent `Pkg.gc()`.
//!
//!    `ajt build` DOES create scratchspaces (that is where a tree-hash-pinned
//!    package's `build.log` goes), so this file has a writer now -- but a
//!    separate one. `appendScratch` is append-only, carries `parent_projects`,
//!    and shares none of `record`'s read-modify-rewrite. The two entry points
//!    stay distinct on purpose: relaxing `record` to accept the scratch log is
//!    exactly the change that reintroduces the `KeyError`.
//!
//! A fourth file lives in `logs/`, `orphaned.toml`, but it is `gc`'s own
//! bookkeeping (`API.jl:1032-1050`) -- written only by `gc`, never by a
//! producer -- so it is out of scope here too.
//!
//! ## What `write_env_usage` actually does (`Types.jl:669-726`)
//!
//! Not an append. A read-modify-rewrite, under a pidfile lock:
//!
//!   1. `source_files = filter(isfile, source_files)`; return if empty. A path
//!      that does not exist is never recorded ("don't record ghost usage",
//!      `:673`) -- which is why `Pkg.activate` on a project with no
//!      `Manifest.toml` yet leaves `logs/` absent entirely, even though the
//!      `EnvCache` it builds does reach `write_env_usage`. (`Registry.add`
//!      leaves no log for a different reason -- it never builds an `EnvCache`
//!      at all. See "Registry operations record nothing" below.)
//!   2. `mkpath(logdir())`, then `mkpidlock(usage_file * ".pid", stale_age = 3)`.
//!   3. Parse the existing file; a parse failure is warned about and treated as
//!      an empty table (`:686-692`).
//!   4. `usage[source_file] = [Dict("time" => now())]` -- REPLACING whatever
//!      was there for that key, not appending to it.
//!   5. Condense EVERY key, old ones included: `usage[k] = [maximum(times)]`
//!      (`:701-713`). A missing `time` counts as `now()` ("be conservative and
//!      mark it as being used now", `:707-710`).
//!   6. `TOML.print(io, usage, sorted = true)` to a temp file, re-parse it to
//!      prove it is valid, then `mv` over the real one (`:715-724`).
//!
//! The on-disk shape is therefore an array-of-tables per path:
//!
//! ```toml
//! [["/home/u/proj/Manifest.toml"]]
//! time = 2026-07-26T22:41:42.368Z
//! ```
//!
//! `time` is a `Dates.DateTime` rendered by `TOML.print` as
//! `YYYY-mm-dd\THH:MM:SS.sss\Z` (`TOML/src/print.jl:96`) -- always exactly
//! three fractional digits, and the `Z` is a LITERAL, not a timezone: `now()`
//! is local wall-clock time. `nowLocal` reproduces that, `/etc/localtime` and
//! all; see its doc comment for what happens when the zone cannot be read.
//!
//! ## Registry operations record nothing
//!
//! `ajt registry add`/`update` deliberately writes no log, because Pkg writes
//! none either. Verified three ways against Julia 1.12.6 in a scratch depot
//! with a manifest present: `Pkg.Registry.add("General")`,
//! `Pkg.Registry.update()` and `Pkg.Registry.status()` all left
//! `manifest_usage.toml`'s timestamp untouched -- those paths never construct
//! an `EnvCache`. It is also moot: `gc` sweeps `packages/`, `artifacts/`,
//! `clones/` and `scratchspaces/`, never `registries/`, so a registry is not
//! collectable in the first place. `usage.sh` gates the agreement rather than
//! leaving it as a claim.
//!
//! ## Allocation
//!
//! `merge` is pure and returns one caller-owned slice; everything it builds in
//! between lives in an arena it owns and frees. `record` likewise holds a
//! private arena for bundle-lifetime data -- the absolutised source paths, the
//! log path, the rendered bytes -- and frees all of it before returning, so
//! nothing outlives the call.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;

const toml_parse = @import("../toml/parse.zig");
const toml_emit = @import("../toml/emit.zig");
const toml_value = @import("../toml/value.zig");
const registry_ops = @import("registry_ops.zig");

const Value = toml_value.Value;
const Table = toml_value.Table;
const DateTime = toml_value.DateTime;

/// `Types.jl:426`. Keyed on the environment's `Manifest.toml`.
pub const manifest_log = "manifest_usage.toml";
/// `Operations.jl:1080`, `Artifacts.jl:278`. Keyed on an `(Julia)Artifacts.toml`.
pub const artifact_log = "artifact_usage.toml";
/// `Operations.jl:1468`. Append-only and carries `parent_projects`; `record`
/// refuses it. See the module header.
pub const scratch_log = "scratch_usage.toml";

/// `Pkg.logdir(depot) = joinpath(depot, "logs")` (`Pkg/src/Pkg.jl:41`).
/// Arena-allocated.
pub fn logsDir(arena: Allocator, depot_root: []const u8) Allocator.Error![]u8 {
    return fspath.join(arena, &.{ depot_root, "logs" });
}

// ---------------------------------------------------------------------------
// Timestamps
// ---------------------------------------------------------------------------

/// Chronological order of two `time` values. Only `.datetime` values ever
/// reach here from a usage log, but a hand-written `time = 2026-01-01` parses
/// as `.date` and must still compare, so the fields are compared in
/// significance order and the absent ones are zero (which `toml/value.zig`
/// guarantees by defaulting them).
pub fn orderTime(a: DateTime, b: DateTime) std.math.Order {
    const fields = [_][2]u32{
        .{ a.year, b.year },
        .{ a.month, b.month },
        .{ a.day, b.day },
        .{ a.hour, b.hour },
        .{ a.minute, b.minute },
        .{ a.second, b.second },
        .{ a.millisecond, b.millisecond },
    };
    for (fields) |f| {
        if (f[0] != f[1]) return if (f[0] < f[1]) .lt else .gt;
    }
    return .eq;
}

/// The last instant a four-digit year can express, `9999-12-31T23:59:59.999`
/// in epoch milliseconds. From the oracle:
///   julia -e 'using Dates; print(Int(round(datetime2unix(DateTime(9999,12,31,23,59,59,999))*1000)))'
pub const max_epoch_ms: i64 = 253402300799999;

/// Epoch milliseconds -> the broken-down civil time `TOML.print` formats.
///
/// `ms` is whatever the caller has already shifted by the UTC offset, so this
/// is a pure calendar conversion.
///
/// Both ends are CLAMPED, and that is load-bearing rather than tidiness: the
/// emitter renders the year with `{d:0>4}`, so a machine whose clock reads
/// year 12345 (or 1969) would produce a line Julia's TOML parser REJECTS --
/// and `gc` treats a log it cannot parse as an EMPTY log, which is precisely
/// what deletes the depot. A wrong-looking timestamp is survivable; an
/// unparseable file is not.
pub fn fromEpochMillis(ms: i64) DateTime {
    const clamped = std.math.clamp(ms, 0, max_epoch_ms);
    const total_ms: u64 = @intCast(clamped);
    const secs: u64 = total_ms / 1000;
    const millis: u16 = @intCast(total_ms % 1000);

    const day_secs: std.time.epoch.DaySeconds = .{ .secs = @intCast(secs % std.time.epoch.secs_per_day) };
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(secs / std.time.epoch.secs_per_day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .kind = .datetime,
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_secs.getHoursIntoDay(),
        .minute = day_secs.getMinutesIntoHour(),
        .second = day_secs.getSecondsIntoMinute(),
        .millisecond = millis,
    };
}

/// The inverse of `fromEpochMillis`, for the one place `gc` does arithmetic on
/// these values: `gc_time - free_time >= collect_delay` (`API.jl:895`).
///
/// Both operands there are `Dates.DateTime`s written by the same clock and
/// carrying no zone, so the epoch this maps onto is arbitrary -- only the
/// DIFFERENCE is meaningful, and it is exact for any pair `fromEpochMillis`
/// could have produced. `Dates` subtraction is likewise a plain civil-time
/// difference with no zone or leap-second handling.
///
/// Out-of-range fields (a hand-edited `orphaned.toml`) are clamped rather than
/// rejected: the caller's only use for the result is a comparison, and the
/// direction that matters is that a nonsense timestamp must not read as
/// "orphaned long ago".
pub fn toEpochMillis(dt: DateTime) i64 {
    const days = daysFromCivil(
        @intCast(dt.year),
        std.math.clamp(dt.month, 1, 12),
        std.math.clamp(dt.day, 1, 31),
    );
    const secs = days * std.time.epoch.secs_per_day +
        @as(i64, @min(dt.hour, 23)) * 3600 +
        @as(i64, @min(dt.minute, 59)) * 60 +
        @as(i64, @min(dt.second, 60));
    return secs * 1000 + @as(i64, @min(dt.millisecond, 999));
}

/// Howard Hinnant's `days_from_civil` -- days since 1970-01-01 for a proleptic
/// Gregorian date. The exact inverse of what `std.time.epoch.EpochDay`
/// computes in `fromEpochMillis`, which is pinned by a round-trip test rather
/// than asserted.
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const y = year - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// `Dates.now()` -- LOCAL wall-clock time, millisecond precision.
///
/// The `Z` that `TOML.print` appends is a literal suffix in a format string,
/// not a timezone marker (`TOML/src/print.jl:96`), and `Dates.DateTime` carries
/// no zone at all, so a log written by Pkg holds local time labelled `Z`.
/// Reproducing that is what keeps an Ajt-written log indistinguishable from a
/// Pkg-written one.
///
/// The offset comes from parsing `/etc/localtime` as TZif. If that file is
/// missing or unparseable -- a container with no tzdata, a non-POSIX host --
/// the fallback is UTC, and that is safe rather than merely tolerable: `gc`
/// never compares a usage timestamp against the clock. The values are used in
/// exactly two places -- a per-key `max` against `DateTime(0)` and against
/// other entries (`API.jl:638-652`), and being written straight back
/// (`:690-729`). Every DECISION is made on the keys (`:674-687`, then `mark`
/// at `:848-873`). The only wall-clock arithmetic in `gc` is
/// `merge_orphanages!` (`:875-900`), whose times come from `orphaned.toml`,
/// not from here. So a timestamp a few hours off changes nothing it decides.
pub fn nowLocal(gpa: Allocator, io: Io) DateTime {
    // `Io.Timestamp.nanoseconds` is an i96; saturate rather than `@intCast`,
    // which would TRAP on an absurd clock in a safe build. `fromEpochMillis`
    // clamps again on its own account.
    const raw = @divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms);
    const utc_ms: i64 = std.math.cast(i64, raw) orelse (if (raw > 0) max_epoch_ms else 0);
    const offset_s = localOffsetSeconds(gpa, io, @divFloor(utc_ms, 1000));
    return fromEpochMillis(utc_ms +| @as(i64, offset_s) * 1000);
}

/// UTC-offset in seconds at `utc_seconds`, from the host's TZif database.
/// Zero on any failure -- see `nowLocal` for why that is not a correctness
/// problem.
pub fn localOffsetSeconds(gpa: Allocator, io: Io, utc_seconds: i64) i32 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;

    // 1 MiB is ~50x the largest zone file in a full tzdata; a bigger file is
    // not a zone file.
    const bytes = Io.Dir.cwd().readFileAlloc(io, "/etc/localtime", gpa, .limited(1 << 20)) catch return 0;
    defer gpa.free(bytes);

    var reader = Io.Reader.fixed(bytes);
    var tz = std.tz.Tz.parse(gpa, &reader) catch return 0;
    defer tz.deinit();

    // Transitions are sorted ascending; the applicable one is the last whose
    // timestamp has already passed.
    var chosen: ?*const std.tz.Timetype = null;
    for (tz.transitions) |t| {
        if (t.ts > utc_seconds) break;
        chosen = t.timetype;
    }
    // Before the first transition (or a zone with none, e.g. UTC) POSIX says
    // to use the first non-DST type; `timetypes[0]` is that in every file the
    // zic compiler emits.
    if (chosen == null and tz.timetypes.len != 0) chosen = &tz.timetypes[0];
    return if (chosen) |c| c.offset else 0;
}

// ---------------------------------------------------------------------------
// The pure core
// ---------------------------------------------------------------------------

/// Steps 3-6 of `write_env_usage` as bytes in -> bytes out: parse `existing`,
/// stamp every path in `sources` with `now`, condense every key to its latest
/// time, and render with `TOML.print(..., sorted = true)`.
///
/// `existing` is null when the log does not exist yet. An `existing` that does
/// not parse is IGNORED, matching `:686-692` (Julia additionally `@warn`s).
///
/// Two shapes Julia would throw on are instead read as "used now", which is
/// the same conservative choice `:707-710` already makes for a missing `time`:
/// a key whose value is not an array of tables, and a key whose array is
/// empty (`maximum` of nothing is an `ArgumentError` in Julia). Erroring here
/// would mean one hand-corrupted line makes every later Ajt run refuse to
/// protect the depot; keeping the key is strictly safer than dropping it.
///
/// Caller owns the returned slice.
pub fn merge(
    gpa: Allocator,
    existing: ?[]const u8,
    sources: []const []const u8,
    now: DateTime,
) MergeError![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try Table.create(arena);

    if (existing) |text| {
        // A parse failure leaves `root` empty, exactly as Julia's catch does.
        if (toml_parse.parse(gpa, text, null)) |parsed| {
            var doc = parsed;
            defer doc.deinit();
            for (doc.root.entries.items) |e| {
                if (root.contains(e.key)) continue;
                // `e.key` lives in the DOCUMENT's arena, which the defer above
                // frees before `emitAlloc` runs. Copy, or the emitter reads
                // freed pages.
                try root.put(arena, try arena.dupe(u8, e.key), try stampValue(arena, latestTime(e.value, now)));
            }
        } else |_| {}
    }

    for (sources) |path| {
        // Julia REPLACES the whole entry (`:698`), and the condensation that
        // follows takes the max of the resulting one-element list -- so `now`
        // wins outright, even against a future-dated stamp already on disk.
        if (root.getPtr(path)) |slot| {
            slot.* = try stampValue(arena, now);
            continue;
        }
        // `sources` may borrow from the caller's stack (`record` passes arena
        // memory, tests pass literals); the document must own its keys.
        try root.put(arena, try arena.dupe(u8, path), try stampValue(arena, now));
    }

    // `Writer.Allocating` reports its own allocation failure as `WriteFailed`;
    // there is no other writer here and therefore no other cause.
    const out = toml_emit.emitAlloc(gpa, root, .{ .sorted = true }) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    errdefer gpa.free(out);

    // `TOML.parsefile(tempfile)` before the `mv` (`:720`): never publish a log
    // that cannot be read back, because an unreadable log is an EMPTY log to
    // `gc` and that is what deletes the depot.
    //
    // Not `unreachable`: the emitter is the parser's inverse and
    // `toml_roundtrip.sh` gates that, so this cannot fire today -- but
    // `unreachable` is undefined behaviour in a release build, and the one
    // outcome that must never happen here is publishing the bytes anyway. An
    // error means `record` keeps the OLD log, which still protects the depot.
    var check = toml_parse.parse(gpa, out, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.InvalidRender,
    };
    check.deinit();

    return out;
}

pub const MergeError = error{
    /// The rendered log did not parse back. Impossible unless the emitter and
    /// the parser have diverged; see `merge`.
    InvalidRender,
} || Allocator.Error;

/// `[Dict("time" => t)]` -- the one-element array of tables that `TOML.print`
/// renders as a `[["key"]]` header followed by a single `time = ...`.
fn stampValue(arena: Allocator, t: DateTime) Allocator.Error!Value {
    const entry = try Table.create(arena);
    try entry.put(arena, "time", .{ .datetime = t });
    const items = try arena.alloc(Value, 1);
    items[0] = .{ .table = entry };
    return .{ .array = items };
}

/// `maximum(map(d -> haskey(d, "time") ? DateTime(d["time"]) : now(), usage[k]))`
/// (`:702-712`).
fn latestTime(v: Value, now: DateTime) DateTime {
    const items = switch (v) {
        .array => |a| a,
        else => return now,
    };
    if (items.len == 0) return now;

    var best: ?DateTime = null;
    for (items) |item| {
        const t: DateTime = blk: {
            const tbl = switch (item) {
                .table => |x| x,
                else => break :blk now,
            };
            // A `time` that is present but is not a TOML datetime (a string, a
            // number) falls here too. Julia's `Dates.DateTime(x)` would parse
            // some of those; treating them as "used now" keeps the key, which
            // is the outcome that protects the depot.
            const raw = switch (tbl.get("time") orelse break :blk now) {
                .datetime => |dt| dt,
                else => break :blk now,
            };
            break :blk switch (raw.kind) {
                .datetime => raw,
                // `Dates.DateTime(::Date)` is midnight, and Julia's rewrite
                // normalises through it -- so a hand-written
                // `time = 2026-01-01` comes back out of Pkg as
                // `2026-01-01T00:00:00.000Z`. Re-emitting it as a bare date
                // would be a byte divergence from the same rewrite.
                .date => .{ .kind = .datetime, .year = raw.year, .month = raw.month, .day = raw.day },
                // A bare `HH:MM:SS` has no date at all. `Dates.DateTime(::Time)`
                // throws; forcing `.datetime` here would render month 00 and
                // day 00, which is not valid TOML -- and an unparseable log is
                // an EMPTY log to `gc`, i.e. the depot gets deleted.
                .time => now,
            };
        };
        if (best == null or orderTime(t, best.?) == .gt) best = t;
    }
    return best.?;
}

// ---------------------------------------------------------------------------
// Reading -- `gc`'s reduce_usage!
// ---------------------------------------------------------------------------

/// One condensed usage record: a path, the LATEST time recorded for it, and
/// (scratch logs only) the union of its `parent_projects`.
pub const Record = struct {
    path: []const u8,
    /// `max` over every entry for this key (`API.jl:640`, `:649`, `:660`).
    time: DateTime,
    /// `parent_projects`, unioned across every entry and sorted. Always empty
    /// for `manifest_usage.toml`/`artifact_usage.toml`, which do not carry the
    /// field.
    parents: []const []const u8 = &.{},
};

/// A whole usage log, one `Record` per distinct key, sorted by path.
pub const Usage = struct {
    records: []const Record = &.{},

    pub fn find(self: Usage, path: []const u8) ?*const Record {
        for (self.records) |*r| {
            if (std.mem.eql(u8, r.path, path)) return r;
        }
        return null;
    }
};

pub const ReadError = error{
    /// The file exists but is not a usage log: it does not parse, a key's
    /// value is not an array of tables, a `time` is not a TOML datetime, or
    /// (scratch only) `parent_projects` is missing or is not an array of
    /// strings.
    ///
    /// **This must never be softened into "read as empty".** `merge` above
    /// does exactly that on the WRITE side and it is right to -- an unwritable
    /// log leaves the depot unprotected and nothing else. On the READ side the
    /// same choice is catastrophic: `gc` decides liveness purely from these
    /// keys, so an empty log means "nothing in this depot is reachable" and the
    /// whole depot is collected. Julia has no `try` around `reduce_usage!`
    /// (`API.jl:621-630`) and throws out of `Pkg.gc()` for the same reason;
    /// `ops/gc.zig` turns this error into "collect nothing, say why".
    MalformedUsageLog,
} || Allocator.Error || Io.Cancelable;

pub const ReadOptions = struct {
    /// Collect (and REQUIRE) `parent_projects`. True only for
    /// `scratch_usage.toml`, whose producer is `build_versions`
    /// (`Operations.jl:1463-1470`); `gc` indexes the key unconditionally
    /// (`API.jl:664`), so a scratch entry without it is malformed rather than
    /// parentless.
    parents: bool = false,
};

/// `reduce_usage!` over one log file (`API.jl:621-670`), condensed to one
/// record per key.
///
/// A file that does not exist reads as EMPTY -- that is Julia's `!isfile(...)
/// && return` at `:622-624` and the normal state of a depot nothing has
/// recorded into. A file that exists and does not parse is an ERROR; see
/// `ReadError.MalformedUsageLog` for why the two cannot be conflated.
///
/// Arena: every string in the result is arena-owned, so the caller may free the
/// source bytes.
pub fn read(arena: Allocator, io: Io, path: []const u8, opts: ReadOptions) ReadError!Usage {
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{},
        // Present but unreadable -- a root-owned log, or one past the cap.
        // Treating that as absent would be exactly the "empty log" failure
        // this error exists to prevent.
        else => return error.MalformedUsageLog,
    };

    // The document builds its own arena on top of `arena` and is deliberately
    // NOT deinit'ed: every key and every `parent_projects` string returned
    // below points into it. Freeing it here is the use-after-free `merge` had
    // to dupe its way around, and it lives exactly as long as `arena` does.
    const doc = toml_parse.parse(arena, src, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.MalformedUsageLog,
    };

    var out: std.ArrayList(Record) = .empty;
    for (doc.root.entries.items) |e| {
        const infos = switch (e.value) {
            .array => |a| a,
            // `f.(Ref(filename), infos)` broadcasts; a scalar would either
            // broadcast as a 0-d value and then fail on `info["time"]`, or
            // throw outright. Either way Pkg does not carry on.
            else => return error.MalformedUsageLog,
        };

        var best: ?DateTime = null;
        var parents: std.ArrayList([]const u8) = .empty;
        for (infos) |info_v| {
            const info = switch (info_v) {
                .table => |t| t,
                else => return error.MalformedUsageLog,
            };
            // `DateTime(info["time"])::DateTime` (`:640`). A missing key is a
            // KeyError in Julia, and a value Julia's `DateTime` constructor
            // would accept but ours does not (a STRING, say) is refused here
            // rather than guessed at -- refusing collects nothing, guessing
            // could collect the wrong thing.
            const raw = switch (info.get("time") orelse return error.MalformedUsageLog) {
                .datetime => |dt| dt,
                else => return error.MalformedUsageLog,
            };
            const t: DateTime = switch (raw.kind) {
                .datetime => raw,
                // `DateTime(::Date)` is midnight; `DateTime(::Time)` throws.
                .date => .{ .kind = .datetime, .year = raw.year, .month = raw.month, .day = raw.day },
                .time => return error.MalformedUsageLog,
            };
            if (best == null or orderTime(t, best.?) == .gt) best = t;

            if (opts.parents) {
                const items = switch (info.get("parent_projects") orelse return error.MalformedUsageLog) {
                    .array => |a| a,
                    else => return error.MalformedUsageLog,
                };
                for (items) |p| {
                    const s = switch (p) {
                        .string => |x| x,
                        else => return error.MalformedUsageLog,
                    };
                    // `push!(parents[filename], parent)` into a `Set{String}`
                    // (`:665`) -- deduplicated, and the union across every
                    // entry for this key.
                    for (parents.items) |have| {
                        if (std.mem.eql(u8, have, s)) break;
                    } else try parents.append(arena, s);
                }
            }
        }

        // `infos` empty: `f.` over an empty collection records nothing at all,
        // so the key never enters `usage` and is simply not there.
        const time = best orelse continue;
        std.mem.sort([]const u8, parents.items, {}, lessThanStr);
        try out.append(arena, .{
            .path = e.key,
            .time = time,
            .parents = parents.items,
        });
    }

    const records = try out.toOwnedSlice(arena);
    std.mem.sort(Record, records, {}, struct {
        fn lt(_: void, a: Record, b: Record) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return .{ .records = records };
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// `mkpidlock(usage_file * ".pid", stale_age = 3)` (`Types.jl:684`);
    /// `refresh` defaults to `stale_age/2` in `pidfile.jl:64`. The `name` is
    /// filled in by `record` from the log being written -- Julia locks
    /// `<log>.pid`, not a directory-wide lock, and using a different name
    /// would mean no mutual exclusion against a concurrent `julia` at all.
    lock: registry_ops.LockOptions = .{ .stale_age_s = 3, .refresh_s = 1.5, .dir_label = "logs" },
    /// Overrides `nowLocal`. For tests and for a caller that wants one
    /// timestamp across several logs.
    now: ?DateTime = null,
    /// `filter(isfile, source_files)` (`:673`). Off only for tests that want
    /// to write a key deliberately pointing at nothing.
    filter_missing: bool = true,
};

pub const Error = error{
    /// `scratch_usage.toml` carries `parent_projects` and is append-only; this
    /// writer would drop them. See the module header.
    ScratchLogUnsupported,
    /// The process has no usable current directory, so a relative source path
    /// cannot be absolutised into the key Julia would use.
    NoCurrentDir,
} || Allocator.Error || Io.Cancelable;

/// `write_env_usage(sources, log_name)` against `depot_root` -- Pkg's
/// `depots1()`, i.e. `Stack.writeDepot()`.
///
/// Nothing is written when every source is missing, which is not an edge case:
/// it is why `Registry.add` on a fresh environment leaves no `logs/` directory
/// behind at all.
///
/// Failures to WRITE are swallowed by design. A read-only depot, a full disk
/// or a lock held by a wedged peer must not turn a successful install into a
/// failed command -- the packages are on disk either way, and the only
/// consequence is that a later `Pkg.gc()` may collect them. Julia takes the
/// same position (`:722-724` logs `@error` and returns). What is NOT swallowed
/// is cancellation, and neither is `ScratchLogUnsupported`, which is a
/// programming error rather than an environmental one.
pub fn record(
    gpa: Allocator,
    io: Io,
    depot_root: []const u8,
    log_name: []const u8,
    sources: []const []const u8,
    opts: Options,
) Error!Recorded {
    if (std.mem.eql(u8, log_name, scratch_log)) return error.ScratchLogUnsupported;
    if (sources.len == 0) return .{};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- step 1: absolutise, then drop what does not exist -----------------
    var keys: std.ArrayList([]const u8) = .empty;
    for (sources) |raw| {
        const abs = try absPath(arena, io, raw);
        if (opts.filter_missing and !try isFile(io, abs)) continue;
        // `Set{String}` on the artifact side (`Operations.jl:952`); the
        // manifest side passes a single path. Either way a duplicate would
        // just be written twice into the same key.
        for (keys.items) |k| {
            if (std.mem.eql(u8, k, abs)) break;
        } else try keys.append(arena, abs);
    }
    if (keys.items.len == 0) return .{};

    const now = opts.now orelse nowLocal(gpa, io);

    // --- steps 2-6, best effort --------------------------------------------
    writeLocked(gpa, arena, io, depot_root, log_name, keys.items, now, opts) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        // Said out loud, like Julia's `@error "Failed to write valid usage
        // file"` (`:723`). Silence here is the worst outcome: the depot is
        // then quietly GC-eligible and the first sign of it is a `Pkg.gc()`
        // deleting a working install weeks later.
        else => {
            std.debug.print(
                "ajt: could not update {s}/logs/{s} ({s}); Pkg.gc() may collect this depot\n",
                .{ depot_root, log_name, @errorName(err) },
            );
            // `keys` counts what WOULD have been stamped; `written` is what
            // makes the difference observable. A caller that reported the
            // count alone would claim a protected depot that is not.
            return .{ .keys = keys.items.len, .written = false };
        },
    };
    return .{ .keys = keys.items.len, .written = true };
}

/// What `record` actually stamped.
///
/// `keys` is the count AFTER absolutising, dropping non-existent sources
/// (`:674`) and deduplicating -- so it is generally smaller than `sources.len`,
/// and reporting the input length instead would overstate on exactly the case
/// that matters: a manifest path that is not there.
pub const Recorded = struct {
    keys: usize = 0,
    /// False when the write was attempted and failed. Julia swallows that too
    /// (`:722-724`), so it is not an error -- but it IS the difference between
    /// a depot `Pkg.gc()` will spare and one it will not, so it is returned
    /// rather than left for the caller to assume.
    written: bool = false,
};

fn writeLocked(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    depot_root: []const u8,
    log_name: []const u8,
    keys: []const []const u8,
    now: DateTime,
    opts: Options,
) !void {
    // `!ispath(logdir()) && mkpath(logdir())` (`:678`).
    const logs_path = try logsDir(arena, depot_root);
    var logs = try Io.Dir.cwd().createDirPathOpen(io, logs_path, .{});
    defer logs.close(io);

    var lock_opts = opts.lock;
    lock_opts.name = try std.fmt.allocPrint(arena, "{s}.pid", .{log_name});
    var lock = try registry_ops.acquireLock(io, logs, lock_opts);
    defer lock.release(io);

    // ABSENT and UNREADABLE are not the same thing, and Julia conflates them
    // (`isfile(usage_file)` at `:685` is false for a file it cannot open).
    // Absent is the normal first-run path. Unreadable -- root-owned, or past
    // the size cap -- must ABORT: the rename below needs no permission on the
    // file itself, so carrying on would replace a log full of other
    // environments' keys with a one-key file and make all of them
    // GC-eligible. Losing this one stamp is the cheaper failure by far.
    const existing: ?[]u8 = logs.readFileAlloc(io, log_name, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const rendered = try merge(gpa, existing, keys, now);
    defer gpa.free(rendered);

    // Julia writes to `tempname()` -- in `$TMPDIR` -- and finishes with `mv`,
    // which degrades to a non-atomic copy across filesystems. A SIBLING temp
    // file cannot: `renameat` within one directory is atomic by definition,
    // and a reader either sees the whole old file or the whole new one.
    var tmp_name: [tmp_prefix.len + 22]u8 = undefined;
    @memcpy(tmp_name[0..tmp_prefix.len], tmp_prefix);
    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(tmp_name[tmp_prefix.len..], &random_bytes);

    // Armed BEFORE the write, not after: a `writeFile` that fails partway
    // still leaves a file, and a stray `.ajt-usage-*` in `logs/` would sit
    // there forever (nothing ever sweeps that directory). Deleting a name that
    // was never created is a no-op here.
    errdefer logs.deleteFile(io, &tmp_name) catch {};
    try logs.writeFile(io, .{ .sub_path = &tmp_name, .data = rendered });
    try Io.Dir.rename(logs, &tmp_name, logs, log_name, io);
}

const tmp_prefix = ".ajt-usage-";

// ---------------------------------------------------------------------------
// scratch_usage.toml -- a second writer, deliberately
// ---------------------------------------------------------------------------

/// One `scratch_usage.toml` record: the scratchspace directory, and the
/// project files that put something in it.
///
/// `parent_projects` is what makes this file's shape different from the other
/// two, and why it cannot go through `record`. `gc` reads it without a
/// `haskey` guard (`API.jl:664`: `for parent in v["parent_projects"]`), so an
/// entry written without it is not a weaker log -- it is a `KeyError` out of
/// every subsequent `Pkg.gc()`, including the automatic one `Pkg._auto_gc`
/// fires on `up`/`pin`/`free`/`rm`.
pub const ScratchEntry = struct {
    /// The scratchspace directory. `build_versions` passes
    /// `joinpath(pkg_scratchpath(), key)` -- already absolute, because it is
    /// built from `depots1()` (`Operations.jl:1461`).
    dir: []const u8,
    /// `[projectfile_path(source_path)]` (`Operations.jl:1467`) -- the project
    /// file of the package whose build produced the log. NOT the environment
    /// being built; `gc` treats these as roots that keep the scratchspace
    /// alive, and a package's own `Project.toml` is what disappears when the
    /// package is uninstalled.
    parent_projects: []const []const u8,
};

pub const ScratchOptions = struct {
    /// Overrides `nowLocal`. For tests, and for a caller that wants one
    /// timestamp across several entries.
    now: ?DateTime = null,
};

/// Append entries to `<depot>/logs/scratch_usage.toml`, the way
/// `build_versions` does (`Operations.jl:1465-1470`).
///
/// **Append, not merge.** Julia opens the file `"a"` and `TOML.print`s one
/// fresh table onto the end; duplicate keys are normal and expected, and `gc`
/// is the only thing that ever condenses them (`API.jl:733-755`, which reduces
/// a key to its newest `time` and the UNION of every entry's
/// `parent_projects`). Reading, merging and rewriting here -- which is what
/// `record` does -- would be a different file format and would lose the union.
///
/// One divergence, stated because it is a race and not a design: Julia's `"a"`
/// is `O_APPEND`, where the kernel places a small write at the true end of
/// file atomically. `Io.File` exposes no append mode in Zig 0.16, so this takes
/// an ADVISORY exclusive lock on the file, reads its length under that lock and
/// writes at that offset. Against another `ajt` that is strictly stronger than
/// `O_APPEND`; against a concurrent `julia` -- which takes no lock here -- there
/// is a microsecond-wide window in which its append could be overwritten. That
/// needs a `Pkg.build` and an `ajt build` running against one depot at the same
/// instant, and the worst outcome is one lost `build.log` root.
///
/// Failures to write are swallowed for the same reason `record` swallows them:
/// the build ran and the log is on disk either way, and a read-only depot must
/// not turn a successful build into a failed command.
pub fn appendScratch(
    gpa: Allocator,
    io: Io,
    depot_root: []const u8,
    entries: []const ScratchEntry,
    opts: ScratchOptions,
) Error!Recorded {
    if (entries.len == 0) return .{};

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now = opts.now orelse nowLocal(gpa, io);
    const rendered = renderScratch(arena, entries, now) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The emitter and the parser disagreeing is impossible today
        // (`toml_roundtrip.sh` gates it), and if it ever happens the right
        // outcome is to leave the file untouched: appending bytes that do not
        // parse turns the whole log into an EMPTY one as far as `gc` is
        // concerned, which is what deletes live scratchspaces.
        error.InvalidRender => {
            std.debug.print(
                "ajt: refusing to append unparseable bytes to {s}/logs/{s}\n",
                .{ depot_root, scratch_log },
            );
            return .{ .keys = entries.len, .written = false };
        },
    };

    appendLocked(arena, io, depot_root, rendered) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print(
                "ajt: could not update {s}/logs/{s} ({s}); Pkg.gc() may collect this build log\n",
                .{ depot_root, scratch_log, @errorName(err) },
            );
            return .{ .keys = entries.len, .written = false };
        },
    };
    return .{ .keys = entries.len, .written = true };
}

/// The bytes one append adds. Public so a test can assert them without
/// touching a filesystem.
///
/// `TOML.print(io, dict)` with no `sorted` keyword (`Operations.jl:1469`), so
/// the order is Julia's `Dict` iteration order rather than a sort. For the two
/// keys this table ever holds, measured against Julia 1.12.6, that order is
/// `time` then `parent_projects` -- reproduced here by insertion order and by
/// emitting with `sorted = false`. Nothing depends on it (`gc` parses the
/// file), but a byte-identical append is what lets the differential gate diff
/// the two logs directly instead of through a normaliser.
pub fn renderScratch(
    arena: Allocator,
    entries: []const ScratchEntry,
    now: DateTime,
) MergeError![]u8 {
    const root = try Table.create(arena);
    for (entries) |e| {
        const rec = try Table.create(arena);
        try rec.put(arena, "time", .{ .datetime = now });
        const parents = try arena.alloc(Value, e.parent_projects.len);
        for (e.parent_projects, 0..) |p, i| parents[i] = .{ .string = p };
        try rec.put(arena, "parent_projects", .{ .array = parents });

        // A repeated key inside ONE append would be a second `[[dir]]` block,
        // which is exactly what a second `TOML.print` of the same key produces
        // -- so grow the existing array rather than replacing it.
        if (root.getPtr(e.dir)) |slot| {
            const old = switch (slot.*) {
                .array => |a| a,
                else => &[_]Value{},
            };
            const grown = try arena.alloc(Value, old.len + 1);
            @memcpy(grown[0..old.len], old);
            grown[old.len] = .{ .table = rec };
            slot.* = .{ .array = grown };
            continue;
        }
        const items = try arena.alloc(Value, 1);
        items[0] = .{ .table = rec };
        try root.put(arena, try arena.dupe(u8, e.dir), .{ .array = items });
    }

    const out = toml_emit.emitAlloc(arena, root, .{ .sorted = false }) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };

    // Same guard as `merge`: never publish bytes that will not parse back. An
    // unparseable log is an EMPTY log to `gc`, which is what deletes things.
    var check = toml_parse.parse(arena, out, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.InvalidRender,
    };
    check.deinit();
    return out;
}

fn appendLocked(arena: Allocator, io: Io, depot_root: []const u8, bytes: []const u8) !void {
    // `build_versions` does NOT mkpath here -- it relies on the `EnvCache` that
    // preceded it having created `logs/`. Ajt can reach a build without ever
    // constructing one, so create the directory rather than failing on a depot
    // that has only ever been written by `ajt`.
    const logs_path = try logsDir(arena, depot_root);
    var logs = try Io.Dir.cwd().createDirPathOpen(io, logs_path, .{});
    defer logs.close(io);

    var file = try logs.createFile(io, scratch_log, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(io);

    // Under the lock, so no other `ajt` can have moved the end between these
    // two calls.
    const end = try file.length(io);
    try file.writePositionalAll(io, bytes, end);
}

/// `Base.abspath` = `normpath(joinpath(pwd(), path))`: lexical, and
/// deliberately NOT `realpath`. Julia does not resolve symlinks here, and a
/// key that disagreed with the one `julia` writes for the same environment
/// would leave two entries in the log where Pkg keeps one.
fn absPath(arena: Allocator, io: Io, path: []const u8) Error![]u8 {
    if (fspath.isAbsolute(path)) return fspath.resolve(arena, &.{path});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.NoCurrentDir,
    };
    return fspath.resolve(arena, &.{ buf[0..n], path });
}

/// `isfile` -- follows symlinks and demands a regular file, which is what
/// Julia's `isfile` does and what `gc`'s own `Pkg.isfile_nothrow` re-checks
/// later (`API.jl:684-685`).
fn isFile(io: Io, path: []const u8) Io.Cancelable!bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return st.kind == .file;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn stamp(y: u16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ms: u16) DateTime {
    return .{
        .kind = .datetime,
        .year = y,
        .month = mo,
        .day = d,
        .hour = h,
        .minute = mi,
        .second = s,
        .millisecond = ms,
    };
}

test "a fresh log is one array-of-tables per path, sorted" {
    // Byte expectation taken from the oracle, not composed by hand:
    //   julia -e 'using TOML, Dates; TOML.print(stdout, Dict(
    //       "/z/Manifest.toml" => [Dict("time" => DateTime(2026,7,26,21,17,1,523))],
    //       "/a/Manifest.toml" => [Dict("time" => DateTime(2026,7,26,21,17,1,523))]),
    //       sorted = true)'
    const out = try merge(
        testing.allocator,
        null,
        &.{ "/z/Manifest.toml", "/a/Manifest.toml" },
        stamp(2026, 7, 26, 21, 17, 1, 523),
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[["/a/Manifest.toml"]]
        \\time = 2026-07-26T21:17:01.523Z
        \\
        \\[["/z/Manifest.toml"]]
        \\time = 2026-07-26T21:17:01.523Z
        \\
    , out);
}

test "milliseconds are always three digits" {
    const out = try merge(testing.allocator, null, &.{"/a"}, stamp(2026, 1, 2, 3, 4, 5, 7));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 2026-01-02T03:04:05.007Z\n", out);

    const zero = try merge(testing.allocator, null, &.{"/a"}, stamp(2026, 1, 2, 3, 4, 5, 0));
    defer testing.allocator.free(zero);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 2026-01-02T03:04:05.000Z\n", zero);
}

test "recording twice replaces the entry rather than appending" {
    const first = try merge(testing.allocator, null, &.{"/a/Manifest.toml"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(first);
    const second = try merge(testing.allocator, first, &.{"/a/Manifest.toml"}, stamp(2026, 2, 2, 0, 0, 0, 0));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("[[\"/a/Manifest.toml\"]]\ntime = 2026-02-02T00:00:00.000Z\n", second);

    // Idempotent in shape: a third pass must not grow the file either.
    const third = try merge(testing.allocator, second, &.{"/a/Manifest.toml"}, stamp(2026, 3, 3, 0, 0, 0, 0));
    defer testing.allocator.free(third);
    try testing.expectEqualStrings("[[\"/a/Manifest.toml\"]]\ntime = 2026-03-03T00:00:00.000Z\n", third);
}

test "an older stamp for the same key still wins -- the new one is not a max" {
    // `usage[source_file] = [Dict("time" => timestamp)]` at `:698` happens
    // BEFORE the condensation, so the pre-existing value is gone by the time
    // `maximum` runs and cannot outvote a backwards clock.
    const first = try merge(testing.allocator, null, &.{"/a"}, stamp(2026, 5, 5, 0, 0, 0, 0));
    defer testing.allocator.free(first);
    const second = try merge(testing.allocator, first, &.{"/a"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 2026-01-01T00:00:00.000Z\n", second);
}

test "other keys survive, and only the touched one moves" {
    const existing =
        \\[["/other/Manifest.toml"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
    ;
    const out = try merge(testing.allocator, existing, &.{"/mine/Manifest.toml"}, stamp(2026, 7, 26, 22, 0, 0, 1));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[["/mine/Manifest.toml"]]
        \\time = 2026-07-26T22:00:00.001Z
        \\
        \\[["/other/Manifest.toml"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
    , out);
}

test "a multi-entry key condenses to its maximum" {
    // What `Operations.jl:1468`'s appender produces, and what `:701-713` is
    // there to collapse.
    const existing =
        \\[["/a"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
        \\[["/a"]]
        \\time = 2024-06-01T12:00:00.500Z
        \\
        \\[["/a"]]
        \\time = 2022-01-01T00:00:00.000Z
        \\
    ;
    const out = try merge(testing.allocator, existing, &.{"/b"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[["/a"]]
        \\time = 2024-06-01T12:00:00.500Z
        \\
        \\[["/b"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\
    , out);
}

test "existing keys outlive the parsed document's arena" {
    // THE regression test for this module. Every key read out of `existing`
    // lives in the parse `Document`'s arena, which is freed before the emitter
    // runs; keeping the slice instead of copying it is a use-after-free that
    // reads as garbage and, at real sizes, segfaults inside `sortedKeys`.
    //
    // It needs SIZE to bite. Every other test here uses one or two short keys,
    // which fit in pages the merge arena happens to reuse intact -- the whole
    // suite passed with the bug in place. This uses 83 realistic paths, the
    // count in this machine's own ~/.julia/logs/artifact_usage.toml.
    const gpa = testing.allocator;
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    for (0..83) |n| {
        try src.writer.print(
            "[[\"/home/someone/.julia/packages/SomeLongPackageName_jll{d}/aB3xQ/Artifacts.toml\"]]\n" ++
                "time = 2020-01-01T00:00:00.000Z\n\n",
            .{n},
        );
    }

    const out = try merge(gpa, src.written(), &.{
        "/home/someone/.julia/packages/Fresh_jll/zZ9kL/Artifacts.toml",
        "/home/someone/.julia/packages/Another_jll/qW2eR/Artifacts.toml",
    }, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer gpa.free(out);

    try testing.expectEqual(@as(usize, 85), std.mem.count(u8, out, "[["));
    // The old timestamps must survive verbatim -- a corrupted key would still
    // count as a `[[` but would not carry its own time through.
    try testing.expectEqual(@as(usize, 83), std.mem.count(u8, out, "time = 2020-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "time = 2026-01-01T00:00:00.000Z"));
    for (0..83) |n| {
        var buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "SomeLongPackageName_jll{d}/aB3xQ", .{n});
        try testing.expect(std.mem.indexOf(u8, out, key) != null);
    }
}

test "a bare date is normalised to midnight, a bare time is not trusted" {
    // Julia's rewrite runs every value through `Dates.DateTime` (`:704`), so a
    // hand-written date comes back out as a full datetime. A bare TIME has no
    // date at all: forcing it would render month 00, which is not valid TOML,
    // and an unparseable log is an EMPTY log to `gc`.
    const existing =
        \\[["/a"]]
        \\time = 2026-01-01
        \\
        \\[["/b"]]
        \\time = 12:00:00.000
        \\
    ;
    const out = try merge(testing.allocator, existing, &.{}, stamp(2026, 9, 9, 9, 9, 9, 9));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[["/a"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\
        \\[["/b"]]
        \\time = 2026-09-09T09:09:09.009Z
        \\
    , out);
}

test "a corrupt log is replaced, not propagated" {
    // `:686-692` warns and carries on with an empty Dict. The alternative --
    // refusing to write -- leaves the depot unprotected forever.
    const out = try merge(testing.allocator, "this is not = = toml", &.{"/a"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 2026-01-01T00:00:00.000Z\n", out);
}

test "a key with no usable time is kept and marked used now" {
    // Three shapes Julia handles differently -- missing `time` is `:707-710`'s
    // documented "mark as used now"; the other two would throw. Keeping the
    // key is what protects the depot; dropping it is what deletes it.
    const existing =
        \\[["/missing-time"]]
        \\other = 1
        \\
        \\[["/not-an-array"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
    ;
    const now = stamp(2026, 9, 9, 9, 9, 9, 9);
    const out = try merge(testing.allocator, existing, &.{}, now);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\[["/missing-time"]]
        \\time = 2026-09-09T09:09:09.009Z
        \\
        \\[["/not-an-array"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
    , out);
}

test "paths needing TOML quoting survive a round trip" {
    const first = try merge(testing.allocator, null, &.{"/a b/with\"quote/Manifest.toml"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(first);
    // The point is the SECOND pass: the key has to parse back out of our own
    // escaping, or every run would append a new, differently-escaped entry.
    const second = try merge(testing.allocator, first, &.{"/a b/with\"quote/Manifest.toml"}, stamp(2026, 1, 1, 0, 0, 1, 0));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(
        "[[\"/a b/with\\\"quote/Manifest.toml\"]]\ntime = 2026-01-01T00:00:01.000Z\n",
        second,
    );
}

test "fromEpochMillis agrees with Julia's calendar" {
    // Every expectation below is Julia's answer, not arithmetic done here:
    //   julia -e 'using Dates; for ms in (0, 1769469421523, 1709208000000,
    //                                     253402300799999)
    //                 println(ms, " -> ", unix2datetime(ms/1000)) end'
    // The second one is why: 1769469421523 is 23:17 UTC, not the 21:17 that
    // reading the digits suggests.
    try testing.expectEqual(stamp(1970, 1, 1, 0, 0, 0, 0), fromEpochMillis(0));
    try testing.expectEqual(stamp(2026, 1, 26, 23, 17, 1, 523), fromEpochMillis(1769469421523));
    // Leap day; the 9999 bound `{d:0>4}` must still render; and the clamp for
    // a clock set before the epoch.
    try testing.expectEqual(stamp(2024, 2, 29, 12, 0, 0, 0), fromEpochMillis(1709208000000));
    try testing.expectEqual(stamp(9999, 12, 31, 23, 59, 59, 999), fromEpochMillis(max_epoch_ms));
    // Both clamps. A year the `{d:0>4}` emitter cannot render would produce a
    // log Julia refuses to parse, and gc reads an unparseable log as an empty
    // one -- i.e. as "collect the whole depot".
    try testing.expectEqual(stamp(1970, 1, 1, 0, 0, 0, 0), fromEpochMillis(-5));
    try testing.expectEqual(stamp(9999, 12, 31, 23, 59, 59, 999), fromEpochMillis(std.math.maxInt(i64)));
}

test "an absurd clock still renders a log Julia can parse" {
    const out = try merge(testing.allocator, null, &.{"/a"}, fromEpochMillis(std.math.maxInt(i64)));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 9999-12-31T23:59:59.999Z\n", out);
}

test "toEpochMillis is the exact inverse of fromEpochMillis" {
    // The pair is what `gc`'s `gc_time - free_time >= collect_delay` runs on
    // (`API.jl:895`), so a one-day drift here is a week's worth of packages
    // deleted early.
    for ([_]i64{ 0, 1, 1769469421523, 1709208000000, 946684800000, max_epoch_ms }) |ms| {
        try testing.expectEqual(ms, toEpochMillis(fromEpochMillis(ms)));
    }
    // A day is a day, across a leap day and a century boundary.
    const day: i64 = 24 * 60 * 60 * 1000;
    try testing.expectEqual(day, toEpochMillis(stamp(2024, 3, 1, 0, 0, 0, 0)) - toEpochMillis(stamp(2024, 2, 29, 0, 0, 0, 0)));
    try testing.expectEqual(day, toEpochMillis(stamp(1900, 3, 1, 0, 0, 0, 0)) - toEpochMillis(stamp(1900, 2, 28, 0, 0, 0, 0)));
    try testing.expectEqual(7 * day, toEpochMillis(stamp(2026, 1, 8, 0, 0, 0, 0)) - toEpochMillis(stamp(2026, 1, 1, 0, 0, 0, 0)));
}

test "read condenses a log the way reduce_usage! does" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Three entries for one key -- what `Operations.jl:1468`'s appender leaves
    // -- plus a second key. `usage[k] = max(...)` (`API.jl:640`).
    try tmp.dir.writeFile(io, .{ .sub_path = "manifest_usage.toml", .data =
        \\[["/z/Manifest.toml"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\
        \\[["/z/Manifest.toml"]]
        \\time = 2024-06-01T12:00:00.500Z
        \\
        \\[["/z/Manifest.toml"]]
        \\time = 2022-01-01T00:00:00.000Z
        \\
        \\[["/a/Manifest.toml"]]
        \\time = 2021-01-01T00:00:00.000Z
        \\
    });
    const path = try tmp.dir.realPathFileAlloc(io, "manifest_usage.toml", arena);

    const u = try read(arena, io, path, .{});
    try testing.expectEqual(@as(usize, 2), u.records.len);
    try testing.expectEqualStrings("/a/Manifest.toml", u.records[0].path);
    try testing.expectEqual(stamp(2024, 6, 1, 12, 0, 0, 500), u.records[1].time);
    try testing.expectEqual(@as(usize, 0), u.records[1].parents.len);

    // An absent log is EMPTY -- `!isfile(usage_filepath) && return` (`:622`).
    const missing = try read(arena, io, try fspath.join(arena, &.{ fspath.dirname(path).?, "nope.toml" }), .{});
    try testing.expectEqual(@as(usize, 0), missing.records.len);
}

test "a scratch log keeps parent_projects, unioned and deduplicated" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = scratch_log, .data =
        \\[["/d/scratchspaces/u/build"]]
        \\time = 2020-01-01T00:00:00.000Z
        \\parent_projects = ["/p/one/Project.toml", "/p/two/Project.toml"]
        \\
        \\[["/d/scratchspaces/u/build"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\parent_projects = ["/p/two/Project.toml", "/p/three/Project.toml"]
        \\
    });
    const path = try tmp.dir.realPathFileAlloc(io, scratch_log, arena);

    const u = try read(arena, io, path, .{ .parents = true });
    try testing.expectEqual(@as(usize, 1), u.records.len);
    try testing.expectEqual(stamp(2026, 1, 1, 0, 0, 0, 0), u.records[0].time);
    // `push!` into a `Set{String}` across every entry for the key (`:661-666`).
    try testing.expectEqual(@as(usize, 3), u.records[0].parents.len);
    try testing.expectEqualStrings("/p/one/Project.toml", u.records[0].parents[0]);
    try testing.expectEqualStrings("/p/three/Project.toml", u.records[0].parents[1]);
    try testing.expectEqualStrings("/p/two/Project.toml", u.records[0].parents[2]);

    // `info["parent_projects"]` is indexed UNCONDITIONALLY by `gc` (`:664`);
    // an entry without it is a KeyError there, not a parentless scratchspace.
    try tmp.dir.writeFile(io, .{ .sub_path = "no_parents.toml", .data =
        \\[["/d/scratchspaces/u/build"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\
    });
    const bad = try tmp.dir.realPathFileAlloc(io, "no_parents.toml", arena);
    try testing.expectError(error.MalformedUsageLog, read(arena, io, bad, .{ .parents = true }));
    // ...and the same file read as a MANIFEST log is perfectly fine.
    try testing.expectEqual(@as(usize, 1), (try read(arena, io, bad, .{})).records.len);
}

test "an unreadable usage log is an error on the read side, never an empty one" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // THE asymmetry of this module. `merge` (write side) reads a corrupt log
    // as empty and rewrites it; `read` (gc side) must not, because there
    // "empty" means "nothing in this depot is reachable" -- i.e. delete it all.
    for ([_][]const u8{
        "this is not = = toml",
        "[[\"/a\"]]\nother = 1\n", // no `time`
        "[[\"/a\"]]\ntime = 12:00:00.000\n", // a bare Time; DateTime(::Time) throws
        "[[\"/a\"]]\ntime = \"2026-01-01T00:00:00\"\n", // a string, not a datetime
        "[\"/a\"]\ntime = 2026-01-01T00:00:00.000Z\n", // a table, not an array of them
    }, 0..) |src, n| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bad{d}.toml", .{n});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = src });
        const path = try tmp.dir.realPathFileAlloc(io, name, arena);
        errdefer std.debug.print("case {d}: {s}\n", .{ n, src });
        try testing.expectError(error.MalformedUsageLog, read(arena, io, path, .{}));
    }

    // The same corrupt text on the WRITE side is absorbed, not refused.
    const rewritten = try merge(testing.allocator, "this is not = = toml", &.{"/a"}, stamp(2026, 1, 1, 0, 0, 0, 0));
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("[[\"/a\"]]\ntime = 2026-01-01T00:00:00.000Z\n", rewritten);
}

test "orderTime compares in significance order" {
    try testing.expectEqual(std.math.Order.lt, orderTime(stamp(2020, 1, 1, 0, 0, 0, 0), stamp(2021, 1, 1, 0, 0, 0, 0)));
    try testing.expectEqual(std.math.Order.gt, orderTime(stamp(2020, 2, 1, 0, 0, 0, 0), stamp(2020, 1, 31, 23, 59, 59, 999)));
    try testing.expectEqual(std.math.Order.eq, orderTime(stamp(2020, 1, 1, 0, 0, 0, 5), stamp(2020, 1, 1, 0, 0, 0, 5)));
    try testing.expectEqual(std.math.Order.lt, orderTime(stamp(2020, 1, 1, 0, 0, 0, 4), stamp(2020, 1, 1, 0, 0, 0, 5)));
}

test "record round-trips through a real depot" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);
    // A real file, because `filter(isfile, ...)` drops anything else.
    const manifest = try fspath.join(arena, &.{ depot, "Manifest.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "" });

    _ = try record(testing.allocator, io, depot, manifest_log, &.{manifest}, .{
        .now = stamp(2026, 7, 26, 22, 41, 42, 368),
    });

    const log_path = try fspath.join(arena, &.{ depot, "logs", manifest_log });
    const got = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(1 << 20));
    const want = try std.fmt.allocPrint(
        arena,
        "[[\"{s}\"]]\ntime = 2026-07-26T22:41:42.368Z\n",
        .{manifest},
    );
    try testing.expectEqualStrings(want, got);

    // A second call must leave exactly one entry, and must leave no temp file
    // or pidfile behind -- a stray `.pid` would make the NEXT writer wait out
    // the 3 s stale age.
    _ = try record(testing.allocator, io, depot, manifest_log, &.{manifest}, .{
        .now = stamp(2026, 7, 26, 22, 45, 0, 0),
    });
    const again = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(1 << 20));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, "[["));

    var logs = try tmp.dir.openDir(io, "logs", .{ .iterate = true });
    defer logs.close(io);
    var it = logs.iterate();
    var names: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expectEqualStrings(manifest_log, e.name);
        names += 1;
    }
    try testing.expectEqual(@as(usize, 1), names);
}

test "record writes nothing when no source exists" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // "Don't record ghost usage" (`Types.jl:673`). Julia leaves `logs/`
    // ABSENT, not empty -- `mkpath` happens after the filter.
    _ = try record(testing.allocator, io, depot, manifest_log, &.{
        try fspath.join(arena, &.{ depot, "nope", "Manifest.toml" }),
    }, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "logs", .{}));
}

test "record refuses scratch_usage.toml" {
    try testing.expectError(
        error.ScratchLogUnsupported,
        record(testing.allocator, testing.io, "/nonexistent", scratch_log, &.{"/x"}, .{}),
    );
}

test "renderScratch matches TOML.print of build_versions' dict" {
    // Byte expectation taken from the oracle, not composed by hand:
    //   julia -e 'using TOML, Dates; TOML.print(stdout, Dict{String,Any}(
    //       "/depot/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/abc123" =>
    //         [Dict{String,Any}("time" => DateTime(2026,7,29,11,22,33,444),
    //                           "parent_projects" => ["/src/Foo/Project.toml"])]))'
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try renderScratch(arena_state.allocator(), &.{.{
        .dir = "/depot/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/abc123",
        .parent_projects = &.{"/src/Foo/Project.toml"},
    }}, stamp(2026, 7, 29, 11, 22, 33, 444));
    try testing.expectEqualStrings(
        \\[["/depot/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/abc123"]]
        \\time = 2026-07-29T11:22:33.444Z
        \\parent_projects = ["/src/Foo/Project.toml"]
        \\
    , out);
}

test "appendScratch appends rather than replacing, and gc can still reduce it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const first = try appendScratch(testing.allocator, io, depot, &.{.{
        .dir = "/d/scratchspaces/u/aaa",
        .parent_projects = &.{"/src/A/Project.toml"},
    }}, .{ .now = stamp(2026, 1, 1, 0, 0, 0, 0) });
    try testing.expect(first.written);

    // A SECOND append for the same key. `write_env_usage` would replace;
    // `build_versions` does not, and neither does this -- `gc`'s reducer is
    // what unions the two `parent_projects` lists (`API.jl:733-755`).
    const second = try appendScratch(testing.allocator, io, depot, &.{.{
        .dir = "/d/scratchspaces/u/aaa",
        .parent_projects = &.{"/src/B/Project.toml"},
    }}, .{ .now = stamp(2026, 2, 2, 0, 0, 0, 0) });
    try testing.expect(second.written);

    // Byte-for-byte what two `open(f, "a") do io; TOML.print(io, dict) end`
    // calls produce, checked against Julia 1.12.6: NO blank line between the
    // blocks. `TOML.print` writes no leading newline, and the appender adds
    // none, so consecutive entries abut.
    const text = try tmp.dir.readFileAlloc(io, "logs/" ++ scratch_log, arena, .limited(1 << 20));
    try testing.expectEqualStrings(
        \\[["/d/scratchspaces/u/aaa"]]
        \\time = 2026-01-01T00:00:00.000Z
        \\parent_projects = ["/src/A/Project.toml"]
        \\[["/d/scratchspaces/u/aaa"]]
        \\time = 2026-02-02T00:00:00.000Z
        \\parent_projects = ["/src/B/Project.toml"]
        \\
    , text);

    // The whole point: it still parses, both blocks survive, and every entry
    // carries the key `gc` reads without a guard.
    var doc = try toml_parse.parse(testing.allocator, text, null);
    defer doc.deinit();
    const arr = doc.root.get("/d/scratchspaces/u/aaa").?.array;
    try testing.expectEqual(@as(usize, 2), arr.len);
    for (arr) |e| {
        try testing.expect(e.table.get("time") != null);
        try testing.expectEqual(@as(usize, 1), e.table.get("parent_projects").?.array.len);
    }
}

test "record absolutises a relative source into the key Julia would use" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // Written through an unnormalised path; the key must come out normalised
    // and absolute, or `gc` sees a second entry for an environment it already
    // tracks and `isfile` may not even resolve it.
    try Io.Dir.cwd().createDirPath(io, try fspath.join(arena, &.{ depot, "env" }));
    const messy = try fspath.join(arena, &.{ depot, ".", "env", "..", "env", "Manifest.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = messy, .data = "" });

    _ = try record(testing.allocator, io, depot, manifest_log, &.{messy}, .{
        .now = stamp(2026, 1, 1, 0, 0, 0, 0),
    });

    const log_path = try fspath.join(arena, &.{ depot, "logs", manifest_log });
    const got = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(1 << 20));
    const want = try std.fmt.allocPrint(
        arena,
        "[[\"{s}/env/Manifest.toml\"]]\ntime = 2026-01-01T00:00:00.000Z\n",
        .{depot},
    );
    try testing.expectEqualStrings(want, got);
}

test "record deduplicates its sources" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const depot = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const toml = try fspath.join(arena, &.{ depot, "Artifacts.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = toml, .data = "" });

    _ = try record(testing.allocator, io, depot, artifact_log, &.{ toml, toml, toml }, .{
        .now = stamp(2026, 1, 1, 0, 0, 0, 0),
    });
    const log_path = try fspath.join(arena, &.{ depot, "logs", artifact_log });
    const got = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(1 << 20));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "[["));
}
