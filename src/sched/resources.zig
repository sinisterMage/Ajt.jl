//! Resource classes: how much of each *kind* of work may run at once.
//!
//! The frontier scheduler replaces `Pkg.instantiate`'s four sequential
//! `@sync` phases (`Pkg/src/API.jl:1392-1398`: `download_source`,
//! `download_artifacts`, `build_versions`, `_auto_precompile`) with one
//! dependency graph. The instant those phases fuse, "how many at once?" stops
//! being one number. A tarball fetch costs a socket; a `tar | gunzip` costs a
//! core and a disk queue slot; a precompile costs a *forked Julia* — a core
//! plus, measured below, up to 2.1 GB of RSS. Running eight of the last kind
//! because eight of the first kind is the right answer is how a 6 GB node dies.
//!
//! So this module answers two questions, and nothing else:
//!
//!  1. **How wide is this machine, really?** Not `nproc` — the *effective*
//!     width after the cgroup CPU quota the container was started with. On the
//!     engine node (`deploy/stack-app.yml:333-339`, `cpus: "2.0"`,
//!     `memory: 6144M`) that is 2 while `nproc` still says 20, because a CFS
//!     quota is invisible to `sched_getaffinity` and therefore invisible to
//!     `Sys.CPU_THREADS`. Julia gets this wrong: `precompilation.jl:569-570`
//!     sizes its limiter from `Sys.CPU_THREADS + 1` capped at 16, so a
//!     `--cpus 2` container runs sixteen forked Julias.
//!  2. **Four separate permits plus a memory bucket.** `Pool` below. A fetch
//!     and a precompile must never share a permit, or the network idles while
//!     the CPUs are busy and vice versa — which is exactly the loss the
//!     frontier exists to recover.
//!
//! ### Why not just reuse `--jobs`
//!
//! Ajt's only existing width knob is `--jobs`, wired to
//! `net/http.zig:default_concurrency` = `num_concurrent_downloads()`
//! (`Pkg/src/Types.jl:463-471`). That number is 8 because eight HTTP requests
//! keep a pipe full — it is an *I/O* number, chosen with no reference to the
//! core count and none to memory. Reusing it for compilation on a 2-CPU node
//! forks eight Julias. `net_pkgserver` below keeps that number, for exactly
//! that class, and no other class inherits it.
//!
//! ### What Base's scheduler does, and the two gaps
//!
//! `base/precompilation.jl:506-1123` is a genuinely good scheduler — one
//! `Event` per node, a pre-start SCC cycle scan, and (`:1277`) the limiter
//! released while a worker waits on *another process's* pidlock so the slot is
//! not wasted. Two things it does not have:
//!
//!  - **One semaphore for all work** (`:573`), so there is no way to say
//!    "8 downloads *and* 2 compiles".
//!  - **No memory accounting at all.** Nothing in `precompilation.jl` looks at
//!    RSS. Its only concession is the `min(…, 16)` at `:570`, commented "limit
//!    for better stability on shared resource systems" — a proxy for memory
//!    pressure that has no idea how much memory exists.
//!
//! `MemoryBucket` closes the second gap, and `CompileSlot` reproduces the
//! first one's good idea: `yieldCpu` mirrors `:1277` exactly, releasing the CPU
//! permit while a pidlock is contended **but keeping the memory reservation** —
//! the waiting process still holds a live Julia, so its RSS has not gone
//! anywhere.
//!
//! ### Measured, on julia 1.12.6, this host
//!
//! Peak `VmHWM` across the parent and every child of
//! `julia --startup-file=no -e 'Base.compilecache(Base.identify_package(P))'`
//! into a cold depot:
//!
//! | P | peak RSS |
//! |---|---|
//! | *(none — bare `julia -e 1`)* | 207 MiB |
//! | `Dates` (small stdlib) | 402 MiB |
//! | `Pkg` (large stdlib) | **2140 MiB** |
//!
//! That 10× spread is why `default_est_rss` is a *default* and why the plan
//! persists measured peaks to `<depot>/ajt/costs.toml`. It is also why the
//! default sits at the top of the range rather than the middle: an
//! underestimate is an OOM kill mid-precompile, an overestimate is an idle
//! core.
//!
//! ### Allocation and I/O
//!
//! `detect` allocates **nothing** — every cgroup and `/proc` file is read into
//! a stack buffer with `Io.Dir.readFile`, which is what makes it safe to call
//! from anywhere in the scheduler, including a worker. It takes an `Io`
//! because Zig 0.16 moved all of `std.fs` onto `std.Io`. `diskSpace` is the one
//! exception and says why at its definition.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http = @import("../net/http.zig");

const native_os = builtin.os.tag;

const KiB = 1024;
const MiB = 1024 * KiB;
const GiB = 1024 * MiB;

// ---------------------------------------------------------------------------
// Detection inputs
// ---------------------------------------------------------------------------

/// Everything `detect` is allowed to look at. The two roots are parameters
/// rather than constants for one reason: a fake cgroup tree in a temp
/// directory is the only way to unit-test quota handling on a host that has no
/// quota. `tools/diff_harness/resources.sh` uses a real container for the gate
/// and says out loud that the fake tree is the weaker check.
pub const Options = struct {
    /// Where the cgroup filesystem is mounted. Under a cgroup namespace — the
    /// default for Docker on cgroup v2 — this directory *is* the container's
    /// own cgroup, so the quota is right here rather than under a path.
    cgroup_root: []const u8 = "/sys/fs/cgroup",
    /// `procfs`. Only `<proc>/self/cgroup` and `<proc>/meminfo` are read.
    proc_root: []const u8 = "/proc",

    /// `JULIA_NUM_PRECOMPILE_TASKS` (`base/precompilation.jl:572`). An operator
    /// who set this made an explicit decision; it wins over detection, exactly
    /// as it does in Julia.
    cpu_override: ?u32 = null,
    /// `JULIA_PKG_CONCURRENT_DOWNLOADS` (`Pkg/src/Types.jl:463-471`).
    net_pkgserver_override: ?u32 = null,

    pub const EnvError = error{
        /// `JULIA_PKG_CONCURRENT_DOWNLOADS` was not a positive integer. Julia
        /// `error()`s here rather than falling back (`Types.jl:466-470`), so
        /// so does Ajt.
        InvalidConcurrency,
        /// `JULIA_NUM_PRECOMPILE_TASKS` was not a positive integer. Julia's
        /// bare `parse(Int, …)` (`precompilation.jl:572`) throws too.
        InvalidPrecompileTasks,
    };

    /// Read the variable NAMES from a process environment, so no caller has to
    /// spell them. Mirrors `depot.Env.fromEnviron`.
    ///
    /// Unlike `depot.Env.fromEnviron` this can fail, because both variables are
    /// numbers and Julia refuses a malformed one instead of ignoring it. A
    /// silent fallback here would be a scheduler running at a width the
    /// operator did not ask for and cannot see.
    pub fn fromEnviron(map: std.process.Environ.Map) EnvError!Options {
        var o: Options = .{};
        o.net_pkgserver_override = if (map.get("JULIA_PKG_CONCURRENT_DOWNLOADS")) |raw|
            try http.concurrency(raw)
        else
            null;
        if (map.get("JULIA_NUM_PRECOMPILE_TASKS")) |raw| {
            const n = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidPrecompileTasks;
            if (n < 1) return error.InvalidPrecompileTasks;
            o.cpu_override = @intCast(@min(n, std.math.maxInt(u32)));
        }
        return o;
    }
};

/// Where the effective CPU width came from. Reported rather than inferred
/// because "why is this box running 2 compiles?" is a question an operator
/// will ask, and `nproc` will not answer it.
pub const CpuSource = enum {
    /// `sched_getaffinity` alone; no quota found. The dev box.
    affinity,
    /// A cgroup v2 `cpu.max` capped the affinity count. The engine node.
    cgroup_v2,
    /// A cgroup v1 `cpu.cfs_quota_us`/`cpu.cfs_period_us` capped it.
    cgroup_v1,
    /// `JULIA_NUM_PRECOMPILE_TASKS`.
    env_override,
};

pub const MemorySource = enum {
    /// cgroup v2 `memory.max`.
    cgroup_v2,
    /// cgroup v1 `memory.limit_in_bytes`.
    cgroup_v1,
    /// `/proc/meminfo` `MemTotal`.
    meminfo,
    /// Nothing readable. `Machine.memory_bytes` is then a guess and
    /// `Widths.memory_bytes` degrades to one compile at a time.
    unknown,
};

/// What the machine actually is, after every restriction that applies to this
/// process. Scalars only — `detect` allocates nothing.
pub const Machine = struct {
    /// `sched_getaffinity` population count, via `std.Thread.getCpuCount`
    /// (`std/Thread.zig:1133-1136` on Linux). This is what `nproc` prints, and
    /// it already reflects a **cpuset** restriction (`--cpuset-cpus`,
    /// `taskset`) — just not a CFS **quota**.
    ///
    /// It is NOT what `Sys.CPU_THREADS` reports. Julia's is
    /// `_SC_NPROCESSORS_ONLN`-shaped and ignores the affinity mask entirely:
    /// measured under `taskset -c 0,1` on this host, `nproc` says 2 and
    /// `Sys.CPU_THREADS` still says 20. So `affinity <= Sys.CPU_THREADS`, and
    /// the gap is a second way Julia's precompile limiter oversubscribes a
    /// restricted machine — on top of the quota it also cannot see.
    affinity: u32,
    /// `min(affinity, quota)`. The width of the `cpu` class.
    cpu: u32,
    cpu_source: CpuSource,
    /// The raw quota, kept for reporting. `null` = unlimited.
    quota_us: ?u64,
    /// The enforcement period the quota is measured over. 100000 µs unless a
    /// cgroup says otherwise.
    period_us: u64,
    /// Total memory this process may use: the cgroup limit if there is one,
    /// otherwise `MemTotal`, whichever is smaller when both are known.
    memory_bytes: u64,
    memory_source: MemorySource,
};

/// Kernel default `CONFIG_CFS_BANDWIDTH` period, and what both cgroup versions
/// write when nothing set one: 100 ms.
pub const default_period_us: u64 = 100_000;

/// The fallback when even `/proc/meminfo` cannot be read. Deliberately small:
/// the consequence is a bucket that admits one compile at a time, which is
/// slow, whereas a large guess on an unknown machine is an OOM kill.
const unknown_memory_bytes: u64 = 1 * GiB;

/// The whole detection, in the order restrictions compose:
///
///   1. `sched_getaffinity` — the hard ceiling. A cpuset already lands here.
///   2. cgroup **v2** `cpu.max`, walked from this process's cgroup up to the
///      root, taking the tightest quota found. Walking matters: with
///      `--cgroupns=host` the container's limit is at
///      `/sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max`, not at the
///      root, and with a systemd slice the limit is often on an ancestor.
///   3. cgroup **v1** `cpu.cfs_quota_us` / `cpu.cfs_period_us`, same walk under
///      the `cpu` controller mount.
///   4. `JULIA_NUM_PRECOMPILE_TASKS`, which overrides all of it.
///
/// v2 is checked before v1 because a hybrid host mounts both and the v1 tree
/// on such a host is usually the empty legacy one.
///
/// Never fails. Every read that does not answer is simply "no restriction from
/// that source" — a package manager that refuses to run because `/proc` is not
/// mounted would be worse than one that runs at the affinity width.
pub fn detect(io: Io, opts: Options) Machine {
    const affinity: u32 = @intCast(@max(1, std.Thread.getCpuCount() catch 1));

    var cpu = affinity;
    var source: CpuSource = .affinity;
    var quota_us: ?u64 = null;
    var period_us: u64 = default_period_us;

    if (detectCpuQuota(io, opts)) |q| {
        quota_us = q.quota_us;
        period_us = q.period_us;
        if (q.cpus()) |from_quota| {
            if (from_quota < cpu) {
                cpu = from_quota;
                source = q.source;
            }
        }
    }

    if (opts.cpu_override) |n| {
        // `Options.fromEnviron` already rejects `< 1`, but `Options` is public
        // and a programmatic caller can set 0. `Machine.cpu >= 1` is an
        // invariant the doc comments and `widths` both rely on.
        cpu = @max(1, n);
        source = .env_override;
    }

    const mem = detectMemory(io, opts);

    return .{
        .affinity = affinity,
        .cpu = cpu,
        .cpu_source = source,
        .quota_us = quota_us,
        .period_us = period_us,
        .memory_bytes = mem.bytes,
        .memory_source = mem.source,
    };
}

// ---------------------------------------------------------------------------
// CPU quota
// ---------------------------------------------------------------------------

/// One `cpu.max` (or its v1 spelling), already attributed to a source.
pub const Quota = struct {
    /// `null` = `max` in v2, `-1` in v1: no bandwidth limit.
    quota_us: ?u64,
    period_us: u64,
    source: CpuSource,

    /// The quota expressed as whole CPUs, or `null` when unlimited.
    ///
    /// **Rounds down, floored at 1.** `--cpus 1.5` yields 1, not 2. Going over
    /// a CFS quota does not fail, it *throttles*: the cgroup is frozen for the
    /// remainder of each 100 ms period once the budget is spent. For a
    /// workload of forked Julias that trades a little idle CPU for a lot of
    /// resident memory — two throttled compiles hold two Julias' RSS to finish
    /// in the wall time of roughly one. The floor of 1 exists because
    /// `--cpus 0.5` must still make progress.
    pub fn cpus(q: Quota) ?u32 {
        const quota = q.quota_us orelse return null;
        if (q.period_us == 0) return null;
        const n = quota / q.period_us;
        return @intCast(@max(1, @min(n, std.math.maxInt(u32))));
    }
};

fn detectCpuQuota(io: Io, opts: Options) ?Quota {
    if (detectCpuQuotaV2(io, opts)) |q| return q;
    return detectCpuQuotaV1(io, opts);
}

/// cgroup v2: `<cgroup_root><rel>/cpu.max`, `rel` walked to the root.
///
/// The tightest quota on the chain wins, because that is what the kernel
/// enforces: a child cannot exceed its parent's bandwidth.
fn detectCpuQuotaV2(io: Io, opts: Options) ?Quota {
    var buf: [4 * KiB]u8 = undefined;
    var rel_buf: [4 * KiB]u8 = undefined;
    const rel = selfCgroupPathCopy(io, opts, &buf, &rel_buf, null);

    var best: ?Quota = null;
    var it: Ancestors = .{ .rest = rel };
    while (it.next()) |dir| {
        const text = readSmallFile(io, &buf, &.{ opts.cgroup_root, dir, "cpu.max" }) orelse continue;
        const q = parseCpuMax(text) orelse continue;
        best = tighter(best, .{ .quota_us = q.quota_us, .period_us = q.period_us, .source = .cgroup_v2 });
    }
    return best;
}

/// cgroup v1: two files under the `cpu` controller mount.
///
/// The controller directory is named after the *co-mounted set*, which on
/// nearly every distribution is `cpu,cpuacct`; `cpu` and `cpuacct` are then
/// symlinks to it. Both spellings are tried because the symlinks are a
/// convention, not a guarantee.
fn detectCpuQuotaV1(io: Io, opts: Options) ?Quota {
    var buf: [4 * KiB]u8 = undefined;
    var rel_buf: [4 * KiB]u8 = undefined;
    const rel = selfCgroupPathCopy(io, opts, &buf, &rel_buf, "cpu");

    var best: ?Quota = null;
    for ([_][]const u8{ "cpu,cpuacct", "cpu" }) |controller| {
        var it: Ancestors = .{ .rest = rel };
        while (it.next()) |dir| {
            const quota_text = readSmallFile(io, &buf, &.{
                opts.cgroup_root, controller, dir, "cpu.cfs_quota_us",
            }) orelse continue;
            const quota = std.fmt.parseInt(i64, std.mem.trim(u8, quota_text, " \t\r\n"), 10) catch continue;
            // `-1` is v1's "unlimited". Recorded, but it restricts nothing.
            if (quota <= 0) {
                best = tighter(best, .{ .quota_us = null, .period_us = default_period_us, .source = .cgroup_v1 });
                continue;
            }
            // An unreadable or malformed period falls back to the kernel
            // default rather than discarding the quota. Dropping it would turn
            // a 2-CPU container into a 20-wide one — the exact failure this
            // module exists to prevent — and the v2 path already defaults a
            // missing period (`parseCpuMax`), so this keeps the two consistent.
            const period = blk: {
                const text = readSmallFile(io, &buf, &.{
                    opts.cgroup_root, controller, dir, "cpu.cfs_period_us",
                }) orelse break :blk default_period_us;
                const p = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch
                    break :blk default_period_us;
                break :blk if (p == 0) default_period_us else p;
            };
            best = tighter(best, .{
                .quota_us = @intCast(quota),
                .period_us = period,
                .source = .cgroup_v1,
            });
        }
    }
    return best;
}

/// Keeps whichever of two quotas admits fewer CPUs; an unlimited quota loses to
/// any limited one but still records that the file was found.
fn tighter(a: ?Quota, b: Quota) Quota {
    const prev = a orelse return b;
    const pc = prev.cpus() orelse return b;
    const bc = b.cpus() orelse return prev;
    return if (bc < pc) b else prev;
}

/// `cpu.max` is `"$MAX $PERIOD\n"` where `$MAX` is `max` or a µs count
/// (`Documentation/admin-guide/cgroup-v2.rst`, "cpu.max"). A missing period
/// field means the kernel default.
pub fn parseCpuMax(text: []const u8) ?struct { quota_us: ?u64, period_us: u64 } {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const max_field = it.next() orelse return null;
    const period = if (it.next()) |p|
        std.fmt.parseInt(u64, p, 10) catch return null
    else
        default_period_us;
    if (period == 0) return null;
    if (std.mem.eql(u8, max_field, "max")) return .{ .quota_us = null, .period_us = period };
    const quota = std.fmt.parseInt(u64, max_field, 10) catch return null;
    return .{ .quota_us = quota, .period_us = period };
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

fn detectMemory(io: Io, opts: Options) struct { bytes: u64, source: MemorySource } {
    var limit: ?u64 = null;
    var source: MemorySource = .unknown;

    if (cgroupMemoryLimitV2(io, opts)) |v| {
        limit = v;
        source = .cgroup_v2;
    } else if (cgroupMemoryLimitV1(io, opts)) |v| {
        limit = v;
        source = .cgroup_v1;
    }

    if (memTotal(io, opts)) |total| {
        // Both known: the cgroup limit can legitimately exceed physical memory
        // (nothing stops `--memory 64g` on a 32 GB host), and in that case the
        // physical number is the one that gets you OOM-killed.
        if (limit) |l| {
            if (total < l) return .{ .bytes = total, .source = .meminfo };
            return .{ .bytes = l, .source = source };
        }
        return .{ .bytes = total, .source = .meminfo };
    }
    if (limit) |l| return .{ .bytes = l, .source = source };
    return .{ .bytes = unknown_memory_bytes, .source = .unknown };
}

fn cgroupMemoryLimitV2(io: Io, opts: Options) ?u64 {
    var buf: [4 * KiB]u8 = undefined;
    var rel_buf: [4 * KiB]u8 = undefined;
    const rel = selfCgroupPathCopy(io, opts, &buf, &rel_buf, null);

    var best: ?u64 = null;
    var it: Ancestors = .{ .rest = rel };
    while (it.next()) |dir| {
        const text = readSmallFile(io, &buf, &.{ opts.cgroup_root, dir, "memory.max" }) orelse continue;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "max")) continue;
        const v = std.fmt.parseInt(u64, trimmed, 10) catch continue;
        if (best == null or v < best.?) best = v;
    }
    return best;
}

fn cgroupMemoryLimitV1(io: Io, opts: Options) ?u64 {
    var buf: [4 * KiB]u8 = undefined;
    var rel_buf: [4 * KiB]u8 = undefined;
    const rel = selfCgroupPathCopy(io, opts, &buf, &rel_buf, "memory");

    var best: ?u64 = null;
    var it: Ancestors = .{ .rest = rel };
    while (it.next()) |dir| {
        const text = readSmallFile(io, &buf, &.{
            opts.cgroup_root, "memory", dir, "memory.limit_in_bytes",
        }) orelse continue;
        const v = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch continue;
        // v1 spells "unlimited" as a number near `PAGE_COUNTER_MAX`
        // (0x7ffffffffffff000 on 64-bit). Anything at or above an exbibyte is
        // that sentinel, not a limit anyone configured.
        if (v >= (1 << 60)) continue;
        if (best == null or v < best.?) best = v;
    }
    return best;
}

/// `MemTotal:       32561216 kB` — the first line of `/proc/meminfo`, always in
/// kB regardless of the trailing unit's case.
fn memTotal(io: Io, opts: Options) ?u64 {
    var buf: [8 * KiB]u8 = undefined;
    const text = readSmallFile(io, &buf, &.{ opts.proc_root, "meminfo" }) orelse return null;
    return parseMemTotalKb(text);
}

pub fn parseMemTotalKb(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var it = std.mem.tokenizeAny(u8, line["MemTotal:".len..], " \t\r");
        const num = it.next() orelse return null;
        const kb = std.fmt.parseInt(u64, num, 10) catch return null;
        // `parseInt` happily accepts up to `maxInt(u64)`, and the kB->byte
        // multiply then overflows and PANICS. `detect` promises never to fail
        // on unreadable or malformed input, and `proc_root` is caller-supplied,
        // so a nonsense `MemTotal` has to come back as "unknown", not a crash.
        return std.math.mul(u64, kb, KiB) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Reading `/proc` and `/sys`
// ---------------------------------------------------------------------------

/// Every file this module reads is a few hundred bytes of kernel-generated
/// text that `stat` reports as size 0, so `readFileAlloc`'s size-then-read is
/// useless here and an allocator is unnecessary. `Io.Dir.readFile`
/// (`std/Io/Dir.zig:753-766`) reads into a caller buffer with
/// `readSliceShort`, which is exactly right for a 0-length `stat`.
///
/// Returns `null` for every failure. A missing `cpu.max` is the normal case on
/// an unrestricted host, not an error.
fn readSmallFile(io: Io, buf: []u8, parts: []const []const u8) ?[]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = joinPath(&path_buf, parts) orelse return null;
    const n = Io.Dir.cwd().readFile(io, path, buf) catch return null;
    if (n.len == 0) return null;
    // `readFile` cannot distinguish "the file exactly filled the buffer" from
    // "the buffer was too small" (`std/Io/Dir.zig:745-747`). Truncating
    // `/proc/self/cgroup` mid-line would yield a plausible-looking but wrong
    // cgroup path, and therefore a silent "no quota". Refuse instead.
    if (n.len == buf.len) return null;
    return n;
}

/// Joins with single `/` separators, tolerating parts that are empty or that
/// already start or end with one — `Ancestors` yields `""` for the root and
/// `"/a/b"` otherwise, and `std.fs.path.join` needs an allocator.
///
/// **Absoluteness is preserved, not imposed.** An earlier version trimmed `/`
/// from every part and unconditionally prepended one, which silently turned a
/// relative `cgroup_root` into a path under `/` — and because every read
/// failure here means "no restriction", the result was a confidently wrong
/// width with no diagnostic. Relative roots now resolve against the cwd, which
/// is what `Io.Dir.cwd().readFile` does anyway.
fn joinPath(buf: []u8, parts: []const []const u8) ?[]const u8 {
    const absolute = parts.len > 0 and parts[0].len > 0 and parts[0][0] == '/';
    var len: usize = 0;
    for (parts) |raw| {
        const part = std.mem.trim(u8, raw, "/");
        if (part.len == 0) continue;
        const sep: usize = if (len == 0 and !absolute) 0 else 1;
        if (len + sep + part.len > buf.len) return null;
        if (sep == 1) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    if (len == 0) return if (absolute) "/" else null;
    return buf[0..len];
}

/// `selfCgroupPath` hands back a slice into the scratch buffer it read into,
/// and every caller then reuses that buffer for the cgroup-file reads. So the
/// path is copied into `out` first.
///
/// It is also right-trimmed of `/`, which is not cosmetic: `Ancestors` would
/// otherwise yield both `"/"` and `""` for a container's root cgroup, and
/// `joinPath` collapses those to the same path — so the common case would open
/// and parse every root-level file twice.
///
/// Returns `""` (the mount root) when there is nothing to read, which is the
/// correct assumption under a cgroup namespace.
fn selfCgroupPathCopy(io: Io, opts: Options, scratch: []u8, out: []u8, controller: ?[]const u8) []const u8 {
    const found = selfCgroupPath(io, opts, scratch, controller) orelse return "";
    const trimmed = std.mem.trimEnd(u8, found, "/");
    if (trimmed.len > out.len) return "";
    @memcpy(out[0..trimmed.len], trimmed);
    return out[0..trimmed.len];
}

/// `<path>`, then each ancestor, then `""` for the mount root.
///
/// The kernel enforces the *minimum* over this chain, so the detector has to
/// read all of it rather than stopping at the leaf.
const Ancestors = struct {
    rest: ?[]const u8,

    fn next(self: *Ancestors) ?[]const u8 {
        const cur = self.rest orelse return null;
        if (cur.len == 0) {
            self.rest = null;
            return "";
        }
        var i = cur.len;
        while (i > 0 and cur[i - 1] == '/') i -= 1; // trailing separators
        while (i > 0 and cur[i - 1] != '/') i -= 1; // last component
        while (i > 0 and cur[i - 1] == '/') i -= 1; // the separator itself
        self.rest = cur[0..i];
        return cur;
    }
};

/// This process's cgroup path from `<proc>/self/cgroup`.
///
/// Lines are `hierarchy-ID:controller-list:cgroup-path`. `controller` selects a
/// v1 hierarchy by name; `null` selects the v2 line, which is the one with
/// hierarchy id `0` and an empty controller list.
///
/// The returned slice points into `buf`, so a caller that needs it across
/// another read must copy it first.
fn selfCgroupPath(io: Io, opts: Options, buf: []u8, controller: ?[]const u8) ?[]const u8 {
    const text = readSmallFile(io, buf, &.{ opts.proc_root, "self", "cgroup" }) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const first = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const second = std.mem.indexOfScalarPos(u8, line, first + 1, ':') orelse continue;
        const controllers = line[first + 1 .. second];
        const path = line[second + 1 ..];
        if (controller) |want| {
            var names = std.mem.splitScalar(u8, controllers, ',');
            while (names.next()) |name| {
                if (std.mem.eql(u8, name, want)) return path;
            }
        } else if (controllers.len == 0 and std.mem.eql(u8, line[0..first], "0")) {
            return path;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Widths
// ---------------------------------------------------------------------------

/// `net.cachestore`, the shared precompile-cache store (B6 in the plan; MinIO
/// on the swarm). Four, and separate from `net_pkgserver` on purpose: these
/// requests are small and latency-bound rather than bandwidth-bound, and a
/// cache store that is down or slow must not consume the budget that fetches
/// packages — the store is an `after` edge in the graph, the package fetch is a
/// `requires` edge.
pub const default_net_cachestore: u32 = 4;

/// What a `Compile` node reserves when nothing has measured it yet.
///
/// 2 GiB, sitting at the top of the measured range in this file's header
/// (207 MiB bare / 402 MiB `Dates` / 2140 MiB `Pkg`) rather than the middle,
/// because the two errors are not symmetric: over-reserving idles a core,
/// under-reserving gets a half-written `.ji` and an OOM kill. `memoryHeadroom`
/// covers the ~92 MiB by which the largest measured case exceeds it.
pub const default_est_rss: u64 = 2 * GiB;

/// One permit count per class, plus the memory bucket's capacity.
pub const Widths = struct {
    /// `num_concurrent_downloads()` (`Pkg/src/Types.jl:463-471`), unchanged: 8.
    net_pkgserver: u32,
    net_cachestore: u32,
    /// Extraction and hashing. `max(2, min(4, cpu/4))`.
    disk: u32,
    /// Forked Julias.
    cpu: u32,
    /// `MemoryBucket` capacity in bytes.
    memory_bytes: u64,
};

/// How much of the memory budget is *not* handed to the bucket: the Ajt process
/// itself, the page cache that a 516 MB artifact download fills, and the gap
/// between an estimate and a peak.
///
/// `max(256 MiB, budget/8)`. The fraction carries the load on a big machine
/// (4 GiB withheld of 32); the floor carries it on a small one, where an eighth
/// of the budget would be too little to hold even a bare Julia (207 MiB
/// measured).
pub fn memoryHeadroom(budget: u64) u64 {
    return @max(256 * MiB, budget / 8);
}

/// The widths for a machine. Pure arithmetic on `detect`'s output, so a gate
/// can check a `(nproc, quota, memory)` triple without a container.
pub fn widths(m: Machine, opts: Options) Widths {
    const headroom = memoryHeadroom(m.memory_bytes);
    return .{
        .net_pkgserver = opts.net_pkgserver_override orelse http.default_concurrency,
        .net_cachestore = default_net_cachestore,
        .disk = diskWidth(m.cpu),
        .cpu = @max(1, m.cpu),
        // Saturating: a budget below the headroom leaves a 1-byte bucket, and
        // `MemoryBucket.reserve` clamps every request to the capacity, so the
        // degradation is "one compile at a time", never a deadlock.
        .memory_bytes = @max(1, m.memory_bytes -| headroom),
    };
}

/// `max(2, min(4, cpu/4))`.
///
/// `cpu` here is the **effective** width, not `nproc`. That distinction is the
/// whole point of the module: extraction is gzip decompression, so a `--cpus 2`
/// container must get 2 extractors and not the 4 that `nproc/4` would give it
/// on a 20-core host. The floor of 2 keeps one extraction overlapping one
/// download even on a single-CPU box, since extraction is not purely CPU-bound
/// — it also waits on writes.
pub fn diskWidth(cpu: u32) u32 {
    return @max(2, @min(4, cpu / 4));
}

// ---------------------------------------------------------------------------
// The memory token bucket
// ---------------------------------------------------------------------------

/// A counting semaphore that hands out *n* tokens at a time instead of one.
///
/// `Io.Semaphore` cannot express this: a compile needs its whole estimated RSS
/// atomically, and taking it as N single permits would let two compiles each
/// grab half of what they need and neither proceed.
///
/// **FIFO, no barging.** Waiters queue in an intrusive list on their own
/// stacks and only the head may consume. A bucket that let small requests
/// overtake would starve a large one indefinitely, and the large ones are
/// exactly the packages worth scheduling well. The cost — a small request
/// idling behind a large one that does not yet fit — is bounded, because every
/// holder releases when its compile ends.
///
/// **Requests are clamped to the capacity, and that clamp is load-bearing.**
/// Without it a package whose estimate exceeds the whole budget would wait
/// forever while holding nothing, and if every worker were in that state the
/// run would deadlock with an idle machine. With it, an over-large request
/// simply becomes "exclusive use of the bucket".
///
/// Statically initialisable except for the two sizes; no deinit.
pub const MemoryBucket = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    capacity: u64,
    available: u64,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,

    /// A queue node, always on the waiting task's stack. It carries no size:
    /// only the head may consume, and the head re-checks its own `need` under
    /// the mutex, so nothing else ever needs to know how much it wants.
    const Waiter = struct {
        next: ?*Waiter = null,
    };

    pub fn init(capacity: u64) MemoryBucket {
        const cap = @max(1, capacity);
        return .{ .capacity = cap, .available = cap };
    }

    /// Blocks until `want` bytes (clamped to the capacity) are free AND this
    /// caller is at the head of the queue. Returns the amount actually held,
    /// which is what must be handed back to `release`.
    pub fn reserve(b: *MemoryBucket, io: Io, want: u64) Io.Cancelable!u64 {
        const need = @max(1, @min(want, b.capacity));

        try b.mutex.lock(io);
        defer b.mutex.unlock(io);

        // Fast path: nobody queued and it fits. Skipping the queue here is not
        // barging — an empty queue has no one to barge past.
        if (b.head == null and b.available >= need) {
            b.available -= need;
            return need;
        }

        var self: Waiter = .{};
        b.push(&self);
        while (b.head != &self or b.available < need) {
            b.cond.wait(io, &b.mutex) catch |err| {
                b.remove(&self);
                // Removing the head unblocks whoever is behind it.
                b.cond.broadcast(io);
                return err;
            };
        }
        b.pop();
        b.available -= need;
        // The new head may now fit; only a broadcast can reach it, since
        // `signal` might wake a non-head waiter that immediately sleeps again.
        b.cond.broadcast(io);
        return need;
    }

    /// Non-blocking. Fails rather than queues, so it never affects fairness for
    /// the callers that do queue. Used by tests and by any future "can this
    /// node be admitted right now?" probe.
    pub fn tryReserve(b: *MemoryBucket, io: Io, want: u64) ?u64 {
        const need = @max(1, @min(want, b.capacity));
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        if (b.head != null or b.available < need) return null;
        b.available -= need;
        return need;
    }

    /// Hands back exactly what `reserve` returned. Uncancelable on purpose:
    /// this runs from `defer`/`errdefer` paths where failing to release would
    /// leak the whole reservation for the rest of the run.
    pub fn release(b: *MemoryBucket, io: Io, amount: u64) void {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        // Saturating: `release` is public and takes a `u64`, so a caller that
        // hands back a bogus amount must clamp, not panic on overflow before
        // the `@min` gets a chance to run.
        b.available = @min(b.capacity, b.available +| amount);
        b.cond.broadcast(io);
    }

    fn push(b: *MemoryBucket, w: *Waiter) void {
        w.next = null;
        if (b.tail) |t| t.next = w else b.head = w;
        b.tail = w;
    }

    fn pop(b: *MemoryBucket) void {
        const h = b.head orelse return;
        b.head = h.next;
        if (b.tail == h) b.tail = null;
        h.next = null;
    }

    fn remove(b: *MemoryBucket, w: *Waiter) void {
        var prev: ?*Waiter = null;
        var cur = b.head;
        while (cur) |c| : ({
            prev = c;
            cur = c.next;
        }) {
            if (c != w) continue;
            if (prev) |p| p.next = c.next else b.head = c.next;
            if (b.tail == c) b.tail = prev;
            c.next = null;
            return;
        }
    }
};

// ---------------------------------------------------------------------------
// The pool
// ---------------------------------------------------------------------------

/// The four classes. Named rather than numbered so a scheduler node declares
/// what it costs instead of an index into an array.
pub const Class = enum {
    /// Package tarballs and registry updates from the Pkg server / GitHub.
    net_pkgserver,
    /// The shared precompile-cache store.
    net_cachestore,
    /// Extraction, hashing, and the atomic rename into the depot.
    disk,
    /// Forked Julias. Never taken without a memory reservation — see
    /// `acquireCompile`.
    cpu,
};

/// One held permit. Deliberately not a bare integer: the scheduler releases
/// these from `defer` blocks several frames away from the acquire, and a
/// mismatched class there is silent (the run just gets slower or wider) rather
/// than a crash.
pub const Permit = struct {
    sem: *Io.Semaphore,

    pub fn release(p: Permit, io: Io) void {
        p.sem.post(io);
    }
};

/// A compile's two resources, held together and released independently.
///
/// The whole reason this is not two separate acquisitions at the call site is
/// `yieldCpu`: `precompilation.jl:1277` releases the limiter while waiting on
/// another process's pidlock, and doing the same with a memory reservation
/// would be a bug — the process being waited on is a live Julia, so nothing
/// about the memory situation improved.
pub const CompileSlot = struct {
    pool: *Pool,
    /// Bytes held in the bucket. May be less than the estimate that was asked
    /// for, if the estimate exceeded the whole capacity.
    reserved: u64,
    holds_cpu: bool,

    /// `Base.release(parallel_limiter)` at `precompilation.jl:1277`: another
    /// process holds this package's pidlock, so let the frontier do other work
    /// while we wait. The memory reservation stays.
    pub fn yieldCpu(s: *CompileSlot, io: Io) void {
        if (!s.holds_cpu) return;
        s.holds_cpu = false;
        s.pool.cpu.post(io);
    }

    /// `Base.acquire(parallel_limiter)` in the `finally` at
    /// `precompilation.jl:1291`. Uncancelable to match: that re-acquire has to
    /// happen on every path, including the failing one, or the outer release is
    /// unbalanced and the class permanently loses a permit.
    pub fn regainCpu(s: *CompileSlot, io: Io) void {
        if (s.holds_cpu) return;
        s.pool.cpu.waitUncancelable(io);
        s.holds_cpu = true;
    }

    pub fn release(s: *CompileSlot, io: Io) void {
        if (s.holds_cpu) {
            s.holds_cpu = false;
            s.pool.cpu.post(io);
        }
        if (s.reserved != 0) {
            s.pool.memory.release(io, s.reserved);
            s.reserved = 0;
        }
    }
};

/// Four independent semaphores plus the bucket. Owned by the scheduler for the
/// life of a run; contains no allocations and needs no deinit.
pub const Pool = struct {
    limits: Widths,
    net_pkgserver: Io.Semaphore,
    net_cachestore: Io.Semaphore,
    disk: Io.Semaphore,
    cpu: Io.Semaphore,
    memory: MemoryBucket,

    pub fn init(w: Widths) Pool {
        return .{
            .limits = w,
            .net_pkgserver = .{ .permits = w.net_pkgserver },
            .net_cachestore = .{ .permits = w.net_cachestore },
            .disk = .{ .permits = w.disk },
            .cpu = .{ .permits = w.cpu },
            .memory = .init(w.memory_bytes),
        };
    }

    /// The machine, detected, with the widths derived from it.
    pub fn detected(io: Io, opts: Options) Pool {
        return .init(widths(detect(io, opts), opts));
    }

    pub fn semaphore(p: *Pool, class: Class) *Io.Semaphore {
        return switch (class) {
            .net_pkgserver => &p.net_pkgserver,
            .net_cachestore => &p.net_cachestore,
            .disk => &p.disk,
            .cpu => &p.cpu,
        };
    }

    pub fn acquire(p: *Pool, io: Io, class: Class) Io.Cancelable!Permit {
        const sem = p.semaphore(class);
        try sem.wait(io);
        return .{ .sem = sem };
    }

    /// Memory first, then CPU — and the order is not arbitrary.
    ///
    /// Taking CPU first deadlocks against `yieldCpu`. Consider every CPU permit
    /// held by tasks queued for memory, while all the memory is held by tasks
    /// that yielded their CPU to wait on a pidlock: the memory holders want a
    /// CPU permit back, the CPU holders want memory, and neither set can move.
    ///
    /// Memory first cannot reach that state. A task holding a CPU permit always
    /// holds its memory too, so it is running and will release both; a task
    /// waiting for memory holds no CPU permit; and because `reserve` clamps to
    /// the capacity, a queue head is always eventually satisfiable. Progress is
    /// guaranteed from any state.
    pub fn acquireCompile(p: *Pool, io: Io, est_rss: u64) Io.Cancelable!CompileSlot {
        const reserved = try p.memory.reserve(io, est_rss);
        errdefer p.memory.release(io, reserved);
        try p.cpu.wait(io);
        return .{ .pool = p, .reserved = reserved, .holds_cpu = true };
    }
};

// ---------------------------------------------------------------------------
// Disk watermark
// ---------------------------------------------------------------------------

/// What a filesystem has left. Bytes, not blocks, because every caller is
/// comparing against a download size.
pub const Space = struct {
    total_bytes: u64,
    /// Free to an unprivileged process, i.e. `f_bavail` — not `f_bfree`, which
    /// includes the root-reserved blocks Ajt cannot touch.
    avail_bytes: u64,
};

pub const SpaceError = error{
    /// The path does not exist, is not reachable, or the platform has no
    /// `statfs`.
    Unsupported,
};

/// `struct statfs` for 64-bit Linux (`arch/*/include/uapi/asm/statfs.h`).
///
/// Declared here rather than taken from `std`: Zig 0.16 has no `statvfs` or
/// `statfs` binding at all (neither `std.posix` nor `std.c` nor
/// `std.os.linux`), and the `ajt` binary does not link libc, so the C
/// `statvfs(3)` is not available either. The layout is stable ABI — it has not
/// changed since the field set below was fixed — and only two fields are read.
/// The block counts are `__fsblkcnt_t`/`__fsfilcnt_t`, which are *unsigned* on
/// 64-bit Linux, while the words around them (`__statfs_word` =
/// `__kernel_long_t`) are signed. The mixed signedness below is the kernel's,
/// not a slip; 120 bytes either way.
const StatFs64 = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// Free space on the filesystem holding `path`.
///
/// Takes no `Io`. Zig 0.16's `std.Io` exposes no `statfs`, and there is nothing
/// to build one out of; wrapping the syscall behind a fake `Io` would be a
/// facade rather than a seam. `statfs(2)` does not block on a local filesystem,
/// and the alternative — not checking — is a run that ENOSPCs halfway through
/// 516 MB of artifacts, leaving a depot full of partial installs.
pub fn diskSpace(path: []const u8) SpaceError!Space {
    // A `switch` on a comptime-known value, not an `if`: the non-Linux prong
    // must not be *analysed* on a non-Linux target, where `std.os.linux`'s
    // syscall table does not exist for the arch.
    return switch (native_os) {
        .linux => diskSpaceLinux(path),
        else => error.Unsupported,
    };
}

fn diskSpaceLinux(path: []const u8) SpaceError!Space {
    // `StatFs64`'s layout is the 64-bit one. 32-bit Linux has a different
    // `struct statfs` and a `statfs64` syscall; nothing this project runs on
    // is 32-bit, so it declines rather than guessing.
    if (@sizeOf(usize) != 8) return error.Unsupported;
    const linux = std.os.linux;

    var path_z: [Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len + 1 > path_z.len) return error.Unsupported;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var st: StatFs64 = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_z), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return error.Unsupported;

    // `f_bsize` is the "optimal transfer block size", and it is what the block
    // counts are expressed in for statfs (unlike statvfs, where `f_frsize` is).
    const bs: u64 = if (st.f_bsize > 0) @intCast(st.f_bsize) else return error.Unsupported;
    return .{
        .total_bytes = st.f_blocks *| bs,
        .avail_bytes = st.f_bavail *| bs,
    };
}

/// The band left unused when deciding whether to start a download.
///
/// 512 MiB, sized against the thing being guarded: a cold Open-Reality
/// instantiate pulls ~516 MB of artifacts, and the depot also has to hold the
/// tarballs mid-extraction and the `.ji` caches the precompiles write. Leaving
/// less than one full artifact set of slack means the run can still fail after
/// the check passed.
pub const default_min_free_bytes: u64 = 512 * MiB;

/// Is there room for `need` more bytes without dipping into the watermark?
pub fn admits(space: Space, need: u64, min_free: u64) bool {
    return space.avail_bytes >= need +| min_free;
}

/// The whole watermark check, for a caller that has a path and a byte count.
/// An unreadable filesystem admits the work: refusing to install because
/// `statfs` failed would be a worse failure than the one being prevented.
pub fn admitsPath(path: []const u8, need: u64, min_free: u64) bool {
    const space = diskSpace(path) catch return true;
    return admits(space, need, min_free);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fspath = std.fs.path;

/// A fake cgroup + proc tree. Weaker than a real container — see
/// `tools/diff_harness/resources.sh`, which runs the real one — but it is the
/// only way to unit-test v1, hybrid, and ancestor-walk shapes at all.
const Tree = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    buf: [Io.Dir.max_path_bytes]u8 = undefined,

    fn init(buf: []u8) !Tree {
        var t: Tree = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .root = "" };
        const n = try t.tmp.dir.realPath(testing.io, buf);
        t.root = buf[0..n];
        return t;
    }

    fn deinit(self: *Tree) void {
        self.tmp.cleanup();
    }

    fn write(self: *Tree, sub_path: []const u8, data: []const u8) !void {
        if (fspath.dirname(sub_path)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// `Options` pointed at this tree. Both roots live inside it so a test can
    /// never accidentally read the host's real cgroup.
    fn opts(self: *Tree) !Options {
        return .{
            .cgroup_root = try std.fmt.bufPrint(&self.buf, "{s}/cgroup", .{self.root}),
            .proc_root = self.root,
        };
    }
};

test "cpu.max: unlimited, a quota, and a non-default period" {
    {
        const q = parseCpuMax("max 100000\n").?;
        try testing.expectEqual(@as(?u64, null), q.quota_us);
        try testing.expectEqual(@as(u64, 100_000), q.period_us);
    }
    {
        // What `docker run --cpus 2` writes.
        const q = parseCpuMax("200000 100000\n").?;
        try testing.expectEqual(@as(?u64, 200_000), q.quota_us);
        try testing.expectEqual(@as(u64, 100_000), q.period_us);
    }
    {
        // A period the operator changed; the ratio is what matters.
        const q = parseCpuMax("150000 50000\n").?;
        const quota: Quota = .{ .quota_us = q.quota_us, .period_us = q.period_us, .source = .cgroup_v2 };
        try testing.expectEqual(@as(?u32, 3), quota.cpus());
    }
    try testing.expect(parseCpuMax("") == null);
    try testing.expect(parseCpuMax("garbage 100000") == null);
    try testing.expect(parseCpuMax("200000 0") == null);
}

test "quota rounds down and floors at one" {
    const cases = [_]struct { q: u64, p: u64, want: u32 }{
        .{ .q = 200_000, .p = 100_000, .want = 2 }, // --cpus 2
        .{ .q = 150_000, .p = 100_000, .want = 1 }, // --cpus 1.5 -> 1, never 2
        .{ .q = 50_000, .p = 100_000, .want = 1 }, // --cpus 0.5 must still run
        .{ .q = 2_000_000, .p = 100_000, .want = 20 },
    };
    for (cases) |c| {
        const quota: Quota = .{ .quota_us = c.q, .period_us = c.p, .source = .cgroup_v2 };
        try testing.expectEqual(@as(?u32, c.want), quota.cpus());
    }
    const unlimited: Quota = .{ .quota_us = null, .period_us = 100_000, .source = .cgroup_v2 };
    try testing.expectEqual(@as(?u32, null), unlimited.cpus());
}

test "cgroup v2: the engine node's --cpus 2 caps a 20-core host" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    // Exactly what a container sees: its own cgroup namespace root.
    try t.write("self/cgroup", "0::/\n");
    try t.write("cgroup/cpu.max", "200000 100000\n");
    try t.write("cgroup/memory.max", "6442450944\n"); // 6144M
    // No `meminfo` in this tree, so the cgroup limit is the only budget --
    // which is also what a container's own `/proc/meminfo` would NOT tell us:
    // it reports the host's 31.8 GiB even under `--memory 6144m`.

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(@as(u32, 2), m.cpu);
    try testing.expectEqual(CpuSource.cgroup_v2, m.cpu_source);
    try testing.expectEqual(@as(u64, 6 * GiB), m.memory_bytes);
    try testing.expectEqual(MemorySource.cgroup_v2, m.memory_source);
    // The affinity count is the host's and is NOT what the scheduler uses.
    try testing.expect(m.affinity >= m.cpu);
}

test "cgroup v2: the limit on an ancestor is found, and the tightest wins" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    // `--cgroupns=host`: the container's own directory is deep in the tree.
    try t.write("self/cgroup", "0::/system.slice/docker-abc.scope\n");
    try t.write("cgroup/system.slice/cpu.max", "400000 100000\n");
    try t.write("cgroup/system.slice/docker-abc.scope/cpu.max", "200000 100000\n");
    try t.write("cgroup/cpu.max", "max 100000\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(@as(u32, 2), m.cpu);
    try testing.expectEqual(CpuSource.cgroup_v2, m.cpu_source);
}

test "cgroup v2: no quota anywhere leaves the affinity count alone" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup", "0::/user.slice/user-1000.slice/app.scope\n");
    try t.write("cgroup/user.slice/cpu.max", "max 100000\n");
    try t.write("cgroup/user.slice/user-1000.slice/app.scope/cpu.max", "max 100000\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(m.affinity, m.cpu);
    try testing.expectEqual(CpuSource.affinity, m.cpu_source);
}

test "cgroup v1: cfs quota and its unlimited sentinel" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup",
        \\11:memory:/docker/abc
        \\4:cpu,cpuacct:/docker/abc
        \\1:name=systemd:/docker/abc
        \\
    );
    try t.write("cgroup/cpu,cpuacct/docker/abc/cpu.cfs_quota_us", "200000\n");
    try t.write("cgroup/cpu,cpuacct/docker/abc/cpu.cfs_period_us", "100000\n");
    try t.write("cgroup/memory/docker/abc/memory.limit_in_bytes", "6442450944\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(@as(u32, 2), m.cpu);
    try testing.expectEqual(CpuSource.cgroup_v1, m.cpu_source);
    try testing.expectEqual(@as(u64, 6 * GiB), m.memory_bytes);
    try testing.expectEqual(MemorySource.cgroup_v1, m.memory_source);
}

test "cgroup v1: -1 quota and the page-counter sentinel are not limits" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup", "4:cpu,cpuacct:/\n11:memory:/\n");
    try t.write("cgroup/cpu,cpuacct/cpu.cfs_quota_us", "-1\n");
    try t.write("cgroup/cpu,cpuacct/cpu.cfs_period_us", "100000\n");
    // 0x7ffffffffffff000 -- v1's "unlimited", not a 8 EiB machine.
    try t.write("cgroup/memory/memory.limit_in_bytes", "9223372036854771712\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(m.affinity, m.cpu);
    try testing.expectEqual(MemorySource.unknown, m.memory_source);
    try testing.expectEqual(unknown_memory_bytes, m.memory_bytes);
}

test "MemTotal wins over a cgroup limit that exceeds physical memory" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup", "0::/\n");
    try t.write("cgroup/memory.max", "68719476736\n"); // --memory 64g
    try t.write("meminfo", "MemTotal:       32561216 kB\nMemFree: 1 kB\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(MemorySource.meminfo, m.memory_source);
    try testing.expectEqual(@as(u64, 32_561_216 * KiB), m.memory_bytes);
}

test "meminfo parsing" {
    try testing.expectEqual(
        @as(?u64, 32_561_216 * KiB),
        parseMemTotalKb("MemTotal:       32561216 kB\nMemFree:  100 kB\n"),
    );
    try testing.expect(parseMemTotalKb("MemFree: 100 kB\n") == null);
    try testing.expect(parseMemTotalKb("MemTotal: notanumber kB\n") == null);
}

test "JULIA_NUM_PRECOMPILE_TASKS overrides detection" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup", "0::/\n");
    try t.write("cgroup/cpu.max", "200000 100000\n");

    var o = try t.opts();
    o.cpu_override = 7;
    const m = detect(testing.io, o);
    try testing.expectEqual(@as(u32, 7), m.cpu);
    try testing.expectEqual(CpuSource.env_override, m.cpu_source);
    // The quota is still reported, so a surprising width can be explained.
    try testing.expectEqual(@as(?u64, 200_000), m.quota_us);
}

test "the two machines this targets get different widths from one code path" {
    // Dev box: 20 cores, no quota, 31.8 GiB.
    {
        const m: Machine = .{
            .affinity = 20,
            .cpu = 20,
            .cpu_source = .affinity,
            .quota_us = null,
            .period_us = default_period_us,
            .memory_bytes = 32_561_216 * KiB,
            .memory_source = .meminfo,
        };
        const w = widths(m, .{});
        try testing.expectEqual(@as(u32, 8), w.net_pkgserver);
        try testing.expectEqual(@as(u32, 4), w.net_cachestore);
        try testing.expectEqual(@as(u32, 4), w.disk); // min(4, 20/4)
        try testing.expectEqual(@as(u32, 20), w.cpu);
        // 31.05 GiB budget less an eighth of it.
        const budget: u64 = 32_561_216 * KiB;
        try testing.expectEqual(budget - budget / 8, w.memory_bytes);
        // Enough for 13 concurrent compiles at the default estimate, which is
        // what keeps 20 CPU permits from becoming 20 x 2140 MiB = 42 GiB.
        try testing.expectEqual(@as(u64, 13), w.memory_bytes / default_est_rss);
    }
    // Engine node: `cpus: "2.0", memory: 6144M` on the same 20-core host.
    {
        const m: Machine = .{
            .affinity = 20,
            .cpu = 2,
            .cpu_source = .cgroup_v2,
            .quota_us = 200_000,
            .period_us = default_period_us,
            .memory_bytes = 6 * GiB,
            .memory_source = .cgroup_v2,
        };
        const w = widths(m, .{});
        try testing.expectEqual(@as(u32, 8), w.net_pkgserver); // unchanged: I/O
        try testing.expectEqual(@as(u32, 2), w.disk); // floor, not 20/4
        try testing.expectEqual(@as(u32, 2), w.cpu); // NOT 20, NOT Julia's 16
        try testing.expectEqual(@as(u64, 6 * GiB - 768 * MiB), w.memory_bytes);
    }
}

test "a budget smaller than the headroom degrades to one compile, not a deadlock" {
    const m: Machine = .{
        .affinity = 1,
        .cpu = 1,
        .cpu_source = .affinity,
        .quota_us = null,
        .period_us = default_period_us,
        .memory_bytes = 128 * MiB,
        .memory_source = .meminfo,
    };
    const w = widths(m, .{});
    try testing.expect(w.memory_bytes >= 1);
    try testing.expectEqual(@as(u32, 2), w.disk);

    var bucket: MemoryBucket = .init(w.memory_bytes);
    // An estimate far over the capacity still gets served -- clamped.
    const got = try bucket.reserve(testing.io, default_est_rss);
    try testing.expectEqual(w.memory_bytes, got);
    try testing.expectEqual(@as(u64, 0), bucket.available);
    bucket.release(testing.io, got);
    try testing.expectEqual(w.memory_bytes, bucket.available);
}

test "memory bucket: reserve, release, and refusal to overcommit" {
    var b: MemoryBucket = .init(1000);
    const io = testing.io;

    const a = try b.reserve(io, 600);
    try testing.expectEqual(@as(u64, 600), a);
    try testing.expectEqual(@as(u64, 400), b.available);

    // 500 does not fit; tryReserve says so rather than blocking the test.
    try testing.expect(b.tryReserve(io, 500) == null);
    const c = b.tryReserve(io, 400).?;
    try testing.expectEqual(@as(u64, 400), c);
    try testing.expectEqual(@as(u64, 0), b.available);

    b.release(io, a);
    b.release(io, c);
    try testing.expectEqual(@as(u64, 1000), b.available);
}

test "memory bucket: a queued waiter blocks tryReserve (no barging)" {
    var b: MemoryBucket = .init(1000);
    const io = testing.io;

    // 800 taken, 200 free, and a waiter queued behind it -- exactly the state
    // `reserve` leaves the bucket in while a request for 900 waits.
    var queued: MemoryBucket.Waiter = .{};
    _ = try b.reserve(io, 800);
    b.push(&queued);
    try testing.expectEqual(@as(u64, 200), b.available);

    // 100 fits in what is free. It is still refused, because someone asked
    // first -- that refusal IS the no-barging rule, and without the queue
    // check this call would succeed.
    try testing.expect(b.tryReserve(io, 100) == null);

    // Same bucket, same request, only the queue removed: now it succeeds. That
    // is what pins the refusal above to the queue rather than to the space.
    b.remove(&queued);
    try testing.expectEqual(@as(?u64, 100), b.tryReserve(io, 100));
}

test "memory bucket: FIFO order survives a mid-queue removal" {
    var b: MemoryBucket = .init(1000);
    var w1: MemoryBucket.Waiter = .{};
    var w2: MemoryBucket.Waiter = .{};
    var w3: MemoryBucket.Waiter = .{};
    b.push(&w1);
    b.push(&w2);
    b.push(&w3);

    b.remove(&w2); // the cancellation path
    try testing.expectEqual(&w1, b.head.?);
    try testing.expectEqual(&w3, b.head.?.next.?);
    try testing.expectEqual(&w3, b.tail.?);

    b.remove(&w3); // removing the tail must move it back
    try testing.expectEqual(&w1, b.tail.?);
    b.remove(&w1);
    try testing.expect(b.head == null);
    try testing.expect(b.tail == null);
}

test "pool: the four classes are independent" {
    const w: Widths = .{
        .net_pkgserver = 8,
        .net_cachestore = 4,
        .disk = 2,
        .cpu = 2,
        .memory_bytes = 4 * GiB,
    };
    var pool: Pool = .init(w);
    const io = testing.io;

    // Drain the CPU class entirely.
    const c1 = try pool.acquire(io, .cpu);
    const c2 = try pool.acquire(io, .cpu);
    try testing.expectEqual(@as(usize, 0), pool.cpu.permits);
    // Fetches are unaffected -- this is the whole point of separate classes.
    try testing.expectEqual(@as(usize, 8), pool.net_pkgserver.permits);
    const n1 = try pool.acquire(io, .net_pkgserver);
    try testing.expectEqual(@as(usize, 7), pool.net_pkgserver.permits);

    n1.release(io);
    c1.release(io);
    c2.release(io);
    try testing.expectEqual(@as(usize, 2), pool.cpu.permits);
    try testing.expectEqual(@as(usize, 8), pool.net_pkgserver.permits);
}

test "compile slot: yielding the CPU keeps the memory reservation" {
    var pool: Pool = .init(.{
        .net_pkgserver = 8,
        .net_cachestore = 4,
        .disk = 2,
        .cpu = 2,
        .memory_bytes = 8 * GiB,
    });
    const io = testing.io;

    var slot = try pool.acquireCompile(io, default_est_rss);
    try testing.expectEqual(default_est_rss, slot.reserved);
    try testing.expectEqual(@as(usize, 1), pool.cpu.permits);
    try testing.expectEqual(@as(u64, 8 * GiB - default_est_rss), pool.memory.available);

    // `precompilation.jl:1277`: another process holds the pidlock.
    slot.yieldCpu(io);
    try testing.expectEqual(@as(usize, 2), pool.cpu.permits);
    try testing.expectEqual(@as(u64, 8 * GiB - default_est_rss), pool.memory.available);
    slot.yieldCpu(io); // idempotent; the outer release must stay balanced
    try testing.expectEqual(@as(usize, 2), pool.cpu.permits);

    // `:1291`, the `finally`.
    slot.regainCpu(io);
    try testing.expectEqual(@as(usize, 1), pool.cpu.permits);
    slot.regainCpu(io);
    try testing.expectEqual(@as(usize, 1), pool.cpu.permits);

    slot.release(io);
    try testing.expectEqual(@as(usize, 2), pool.cpu.permits);
    try testing.expectEqual(@as(u64, 8 * GiB), pool.memory.available);
    slot.release(io); // double release must not hand back permits twice
    try testing.expectEqual(@as(usize, 2), pool.cpu.permits);
    try testing.expectEqual(@as(u64, 8 * GiB), pool.memory.available);
}

test "ancestor walk yields the path, every parent, and the root" {
    var it: Ancestors = .{ .rest = "/a/b/c" };
    try testing.expectEqualStrings("/a/b/c", it.next().?);
    try testing.expectEqualStrings("/a/b", it.next().?);
    try testing.expectEqualStrings("/a", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expect(it.next() == null);

    var root: Ancestors = .{ .rest = "/" };
    try testing.expectEqualStrings("/", root.next().?);
    try testing.expectEqualStrings("", root.next().?);
    try testing.expect(root.next() == null);
}

test "path join tolerates the shapes the walk produces" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/sys/fs/cgroup/cpu.max", joinPath(&buf, &.{ "/sys/fs/cgroup", "", "cpu.max" }).?);
    try testing.expectEqualStrings("/sys/fs/cgroup/a/b/cpu.max", joinPath(&buf, &.{ "/sys/fs/cgroup", "/a/b", "cpu.max" }).?);
    try testing.expectEqualStrings("/proc/self/cgroup", joinPath(&buf, &.{ "/proc", "self", "cgroup" }).?);
    // A relative root stays relative. Absolutising it would have produced a
    // read failure, which this module reads as "no restriction" -- a
    // confidently wrong width with nothing to see in the output.
    try testing.expectEqualStrings("fake/cgroup/cpu.max", joinPath(&buf, &.{ "fake/cgroup", "", "cpu.max" }).?);
    try testing.expectEqualStrings("fake/cgroup/a/cpu.max", joinPath(&buf, &.{ "fake/cgroup", "/a", "cpu.max" }).?);
    try testing.expectEqualStrings("/", joinPath(&buf, &.{ "/", "" }).?);
    var tiny: [4]u8 = undefined;
    try testing.expect(joinPath(&tiny, &.{ "/sys/fs/cgroup", "cpu.max" }) == null);
}

test "a relative cgroup root is read, not silently absolutised" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();
    try t.write("self/cgroup", "0::/\n");
    // One CPU, not four. `detect` records a cgroup source only when the quota
    // is TIGHTER than the affinity count (`detect`, `from_quota < cpu`), so a
    // four-CPU quota proves nothing on a four-CPU machine -- it leaves
    // `cpu_source` at `.affinity` while `cpu` coincidentally still reads 4, and
    // both assertions below would be measuring the host instead of the code.
    // A GitHub runner has exactly four CPUs, which is how this passed on a
    // 32-core desktop and failed in CI.
    try t.write("cgroup/cpu.max", "100000 100000\n");

    // ... and with one CPU there is no quota tighter than the affinity count at
    // all, so no contents of that file could make this test mean anything.
    if ((std.Thread.getCpuCount() catch 1) < 2) return error.SkipZigTest;

    // The same tree named RELATIVE to the process cwd rather than absolutely.
    // The cwd is not changed -- a test that mutates process-global state is a
    // test that breaks its neighbours -- so the relative path is derived.
    // `Io.Dir.cwd()` is the AT_FDCWD sentinel, not an open handle, so it has no
    // real path of its own; opening "." gives one that does.
    var here = try Io.Dir.cwd().openDir(testing.io, ".", .{});
    defer here.close(testing.io);
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try here.realPath(testing.io, &cwd_buf)];
    const rel_root = try fspath.relative(testing.allocator, cwd, null, cwd, t.root);
    defer testing.allocator.free(rel_root);
    if (rel_root.len == 0 or fspath.isAbsolute(rel_root)) return error.SkipZigTest;

    var cg_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const m = detect(testing.io, .{
        .cgroup_root = try std.fmt.bufPrint(&cg_buf, "{s}/cgroup", .{rel_root}),
        .proc_root = rel_root,
    });
    // Absolutising `rel_root` would make every read fail, and this module
    // reads a failed read as "no restriction" -- so the bug's signature is
    // `cpu == affinity` with `cpu_source == .affinity`, silently.
    try testing.expectEqual(@as(u32, 1), m.cpu);
    try testing.expectEqual(CpuSource.cgroup_v2, m.cpu_source);
}

test "cgroup v1: a missing period file keeps the quota at the kernel default" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    try t.write("self/cgroup", "4:cpu,cpuacct:/docker/abc\n");
    // Quota present, period absent. Dropping the quota here -- which is what
    // an `orelse continue` did -- ran a 2-CPU container 20 wide.
    try t.write("cgroup/cpu,cpuacct/docker/abc/cpu.cfs_quota_us", "200000\n");

    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(@as(u32, 2), m.cpu);
    try testing.expectEqual(CpuSource.cgroup_v1, m.cpu_source);
    try testing.expectEqual(default_period_us, m.period_us);
}

test "a nonsense MemTotal is unknown, not a panic" {
    // `parseInt` accepts this; the kB->byte multiply used to overflow.
    try testing.expect(parseMemTotalKb("MemTotal: 9223372036854775808 kB\n") == null);
    try testing.expect(parseMemTotalKb("MemTotal: 18446744073709551615 kB\n") == null);

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();
    try t.write("self/cgroup", "0::/\n");
    try t.write("meminfo", "MemTotal: 9223372036854775808 kB\n");
    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(MemorySource.unknown, m.memory_source);
}

test "an over-long /proc/self/cgroup is refused rather than truncated" {
    // `Io.Dir.readFile` cannot report truncation, and half a line parses into a
    // plausible-but-wrong cgroup path.
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    try line.appendSlice(testing.allocator, "0::/");
    try line.appendNTimes(testing.allocator, 'x', 8 * KiB);
    try line.append(testing.allocator, '\n');
    try t.write("self/cgroup", line.items);
    try t.write("cgroup/cpu.max", "200000 100000\n");

    // The root `cpu.max` is still found by the ancestor walk, so this stays a
    // safe degradation rather than a wrong answer.
    const m = detect(testing.io, try t.opts());
    try testing.expectEqual(@as(u32, 2), m.cpu);
}

test "self cgroup path picks the right line per version" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();
    try t.write("self/cgroup",
        \\11:memory:/docker/abc
        \\4:cpu,cpuacct:/docker/abc
        \\0::/docker/abc/v2
        \\
    );
    const o = try t.opts();
    var buf: [4 * KiB]u8 = undefined;
    try testing.expectEqualStrings("/docker/abc/v2", selfCgroupPath(testing.io, o, &buf, null).?);
    try testing.expectEqualStrings("/docker/abc", selfCgroupPath(testing.io, o, &buf, "cpu").?);
    try testing.expectEqualStrings("/docker/abc", selfCgroupPath(testing.io, o, &buf, "memory").?);
    try testing.expect(selfCgroupPath(testing.io, o, &buf, "blkio") == null);
}

test "disk width is derived from the effective CPU count, not nproc" {
    try testing.expectEqual(@as(u32, 2), diskWidth(1));
    try testing.expectEqual(@as(u32, 2), diskWidth(2)); // the engine node
    try testing.expectEqual(@as(u32, 2), diskWidth(8));
    try testing.expectEqual(@as(u32, 3), diskWidth(12));
    try testing.expectEqual(@as(u32, 4), diskWidth(16));
    try testing.expectEqual(@as(u32, 4), diskWidth(20)); // the dev box
    try testing.expectEqual(@as(u32, 4), diskWidth(128)); // capped
}

test "disk space and the admission watermark" {
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t = try Tree.init(&root_buf);
    defer t.deinit();

    const space = try diskSpace(t.root);
    try testing.expect(space.total_bytes > 0);
    try testing.expect(space.avail_bytes <= space.total_bytes);

    // The artifact set this is sized against, against a synthetic filesystem.
    const fake: Space = .{ .total_bytes = 2 * GiB, .avail_bytes = 600 * MiB };
    try testing.expect(!admits(fake, 516 * MiB, default_min_free_bytes));
    try testing.expect(admits(fake, 50 * MiB, default_min_free_bytes));
    // Saturating add: an absurd request must refuse rather than wrap to true.
    try testing.expect(!admits(fake, std.math.maxInt(u64), default_min_free_bytes));

    try testing.expect(admitsPath(t.root, 0, 0));
    // An unreadable path admits rather than blocks the run.
    try testing.expect(admitsPath("/definitely/not/here", 1 * GiB, default_min_free_bytes));
}

test "options read the two Julia environment variables" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectEqual(@as(?u32, null), (try Options.fromEnviron(env)).cpu_override);

    try env.put("JULIA_NUM_PRECOMPILE_TASKS", "3");
    try env.put("JULIA_PKG_CONCURRENT_DOWNLOADS", "16");
    const o = try Options.fromEnviron(env);
    try testing.expectEqual(@as(?u32, 3), o.cpu_override);
    try testing.expectEqual(@as(?u32, 16), o.net_pkgserver_override);
    try testing.expectEqual(@as(u32, 16), widths(.{
        .affinity = 20,
        .cpu = 20,
        .cpu_source = .affinity,
        .quota_us = null,
        .period_us = default_period_us,
        .memory_bytes = 8 * GiB,
        .memory_source = .meminfo,
    }, o).net_pkgserver);

    // Julia `error()`s on these rather than falling back, so Ajt does too.
    try env.put("JULIA_NUM_PRECOMPILE_TASKS", "0");
    try testing.expectError(error.InvalidPrecompileTasks, Options.fromEnviron(env));
    try env.put("JULIA_NUM_PRECOMPILE_TASKS", "many");
    try testing.expectError(error.InvalidPrecompileTasks, Options.fromEnviron(env));
}

test "detection on the real host agrees with itself" {
    // No fake tree: this reads whatever this machine actually is. The value is
    // not asserted (CI runners differ); the invariants are.
    const m = detect(testing.io, .{});
    try testing.expect(m.affinity >= 1);
    try testing.expect(m.cpu >= 1);
    try testing.expect(m.cpu <= m.affinity);
    try testing.expect(m.memory_bytes > 0);

    const w = widths(m, .{});
    try testing.expectEqual(@as(u32, 8), w.net_pkgserver);
    try testing.expect(w.disk >= 2 and w.disk <= 4);
    try testing.expectEqual(m.cpu, w.cpu);
    try testing.expect(w.memory_bytes < m.memory_bytes);
}
