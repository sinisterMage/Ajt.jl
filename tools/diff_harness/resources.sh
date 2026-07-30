#!/usr/bin/env bash
# Gate for the scheduler's resource classes (src/sched/resources.zig).
#
# WHY THIS GATE EXISTS
#
# The frontier scheduler forks a Julia per `Compile` node. How many it may fork
# at once is `Widths.cpu`, and every other candidate answer to that question is
# wrong on the machine this project actually deploys to:
#
#   * `--jobs` / `num_concurrent_downloads()` is 8 (`Pkg/src/Types.jl:463-471`).
#     It is an I/O number. Eight forked Julias on the engine node is 8 x ~2 GB.
#   * `nproc` / `Sys.CPU_THREADS` is 20 on this host and *stays 20 inside a
#     `--cpus 2` container*, because a CFS bandwidth quota is not a CPU mask and
#     `sched_getaffinity` cannot see it.
#   * Julia's own precompile limiter is `min(Sys.CPU_THREADS + 1, 16)`
#     (`base/precompilation.jl:569-570`), so on the engine node
#     (`deploy/stack-app.yml:333-339`: `cpus: "2.0"`, `memory: 6144M`) Base
#     would run **sixteen** forked Julias against 2 CPUs and 6 GB.
#
# The failure that motivates the gate is silent and remote: nothing errors, the
# node just thrashes or the OOM killer takes a precompile worker mid-write. So
# the gate is not "does the detector parse cpu.max" -- that is a unit test. It
# is: **put the real code in a real 2-CPU container and make it say 2.**
#
# THREE SECTIONS
#
#   1. BARE HOST. The detected width against `nproc` and against
#      `Sys.CPU_THREADS` from a real julia. On an unconstrained host all three
#      must agree; if this host is itself under a quota (a systemd slice with
#      CPUQuota=, a CI runner) the gate says so and asserts the weaker
#      `detected <= nproc` instead of pretending.
#
#   2. THE ONE THAT MATTERS. `docker run --cpus 2` and friends. Detected CPU
#      must be 2, not `nproc`. Also `--cpuset-cpus` (which affinity alone must
#      catch) and `--memory` (which the token bucket is sized from).
#
#      If docker is unavailable the section falls back to a FAKE cgroup tree in
#      a temp directory, pointed at through the detector's root options. Say so
#      here rather than in a comment nobody reads: **the fake tree is a weaker
#      test.** It proves the parser and the ancestor walk; it cannot prove that
#      the files a real runtime writes are the files this code looks for, which
#      is the part that has historically been wrong in every language's
#      container-awareness patch. A run that took the fallback exits 3.
#
#   3. WIDTHS FOR A KNOWN TRIPLE. `(nproc, quota, memory)` in, four semaphore
#      widths and a bucket capacity out, checked against arithmetic done here
#      rather than in Zig. `net_pkgserver` is not hard-coded: it comes from
#      Julia's own `num_concurrent_downloads()`.
#
# Nothing here writes outside $WORK, and no container gets a bind mount that is
# not $WORK (read-only).
#
# Usage: resources.sh [--keep] [--no-docker]
#   --no-docker forces the fallback branch. It exists so that branch is not
#   dead code that only ever runs where nobody is watching.
# Exit codes: 0 all checks passed, 1 a check failed, 2 a prerequisite is
# missing, 3 passed but section 2 fell back to the fake cgroup tree.
#
# 3 is NOT a pass. A CI job that runs this without a usable docker daemon gets
# 3 every time, and must treat it as a warning it has to fix (give the runner
# docker) rather than as green — otherwise the one check this file exists for
# never runs anywhere.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"

KEEP=0
NO_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --no-docker) NO_DOCKER=1 ;;
    *) echo "usage: resources.sh [--keep] [--no-docker]" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }

# Checked, because this script runs without `set -e`: an empty $WORK would turn
# every `> "$WORK/..."` below into a write at the filesystem ROOT, which is
# exactly what the header promises cannot happen.
WORK="$(mktemp -d -t ajt-resources-XXXXXX)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: mktemp -d produced no directory" >&2; exit 2; }
cleanup() { [ $KEEP -eq 0 ] && rm -rf "$WORK"; [ $KEEP -eq 1 ] && echo "kept: $WORK"; }
trap cleanup EXIT

# Both of these change what the detector and Julia answer. The gate's baseline
# is the unset behaviour; the override path gets its own explicit check in
# section 1, with the variables set only for that one invocation.
unset JULIA_PKG_CONCURRENT_DOWNLOADS JULIA_NUM_PRECOMPILE_TASKS

PASS=0
FAIL=0
ok()  { echo "  ok   $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*" >&2; FAIL=$((FAIL+1)); }
check() { # label want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1
    want: $2
    got : $3"; fi
}

# ---------------------------------------------------------------------------
# The probe
#
# `src/sched/resources.zig` is a library module and this change is not allowed
# to add a CLI subcommand (that belongs to another unit), so the gate drives the
# library through a throwaway program built against the same module
# `zig build test` compiles. Same shape as depot.sh's probe.
#
# It is built for x86_64-linux-musl on purpose: section 2 runs it inside
# `alpine`, and a binary that needs the host's dynamic loader would turn a
# resource-detection failure into an exec failure.
# ---------------------------------------------------------------------------
cat > "$WORK/probe.zig" <<'PROBE_EOF'
const std = @import("std");
const ajt = @import("ajt");
const res = ajt.sched.resources;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var buf: [8 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const cmd = args[1];

    // detect [<cgroup-root> <proc-root>] -- default roots mean the real machine.
    // detect-env [...]              -- same, but with JULIA_* honoured, so the
    //                                  override path is actually exercised.
    if (std.mem.eql(u8, cmd, "detect") or std.mem.eql(u8, cmd, "detect-env")) {
        var opts: res.Options = if (std.mem.endsWith(u8, cmd, "-env"))
            try res.Options.fromEnviron(init.environ_map.*)
        else
            .{};
        if (args.len >= 4) {
            opts.cgroup_root = args[2];
            opts.proc_root = args[3];
        }
        const m = res.detect(io, opts);
        const w = res.widths(m, opts);
        try out.print(
            \\affinity={d}
            \\cpu={d}
            \\cpu_source={t}
            \\quota_us={?d}
            \\period_us={d}
            \\memory_bytes={d}
            \\memory_source={t}
            \\w_net_pkgserver={d}
            \\w_net_cachestore={d}
            \\w_disk={d}
            \\w_cpu={d}
            \\w_memory_bytes={d}
            \\
        , .{
            m.affinity,     m.cpu,             m.cpu_source,  m.quota_us,
            m.period_us,    m.memory_bytes,    m.memory_source,
            w.net_pkgserver, w.net_cachestore, w.disk,        w.cpu,
            w.memory_bytes,
        });
        return;
    }

    // widths-of <affinity> <cpu> <memory-bytes> -- the pure arithmetic, so a
    // triple can be checked without a machine that has it.
    if (std.mem.eql(u8, cmd, "widths-of")) {
        const m: res.Machine = .{
            .affinity = try std.fmt.parseInt(u32, args[2], 10),
            .cpu = try std.fmt.parseInt(u32, args[3], 10),
            .cpu_source = .affinity,
            .quota_us = null,
            .period_us = res.default_period_us,
            .memory_bytes = try std.fmt.parseInt(u64, args[4], 10),
            .memory_source = .meminfo,
        };
        const w = res.widths(m, .{});
        try out.print("{d} {d} {d} {d} {d}\n", .{
            w.net_pkgserver, w.net_cachestore, w.disk, w.cpu, w.memory_bytes,
        });
        return;
    }

    // est-rss -- the default per-compile memory reservation.
    if (std.mem.eql(u8, cmd, "est-rss")) {
        try out.print("{d}\n", .{res.default_est_rss});
        return;
    }

    // space <path> -- the statfs watermark input.
    if (std.mem.eql(u8, cmd, "space")) {
        const s = try res.diskSpace(args[2]);
        try out.print("{d} {d}\n", .{ s.total_bytes, s.avail_bytes });
        return;
    }

    return error.UnknownCommand;
}
PROBE_EOF

echo "==> building probe (x86_64-linux-musl, so it runs inside alpine too)"
( cd "$AJT_ROOT" && zig build-exe --dep ajt \
    -Mroot="$WORK/probe.zig" -Majt=src/root.zig \
    -target x86_64-linux-musl \
    -femit-bin="$WORK/probe" \
    --cache-dir "$WORK/zig-cache" --global-cache-dir "$WORK/zig-global" ) >"$WORK/build.log" 2>&1 || {
  echo "ERROR: probe build failed" >&2; tail -30 "$WORK/build.log" >&2; exit 2; }
P="$WORK/probe"

# One julia process for every constant this script takes from Julia.
read -r JULIA_CPU_THREADS JULIA_CONCURRENT_DOWNLOADS <<EOF
$(julia --startup-file=no -e '
    using Pkg
    print(Sys.CPU_THREADS, " ", Pkg.Types.num_concurrent_downloads())')
EOF
[ -n "$JULIA_CPU_THREADS" ] || { echo "ERROR: julia produced no CPU_THREADS" >&2; exit 2; }
# Checked separately: an empty value here would silently make every section-3
# expectation start with a blank field, turning one prerequisite failure into
# five baffling check failures.
[ -n "$JULIA_CONCURRENT_DOWNLOADS" ] || { echo "ERROR: julia produced no num_concurrent_downloads()" >&2; exit 2; }

field() { awk -F= -v k="$1" '$1==k{print $2}' "$2"; }

# ---------------------------------------------------------------------------
echo
echo "==> 1. bare host: detected width vs nproc vs Sys.CPU_THREADS"
# ---------------------------------------------------------------------------
NPROC="$(nproc)"
"$P" detect > "$WORK/host.txt" || { echo "ERROR: probe detect failed" >&2; exit 2; }
cat "$WORK/host.txt" | sed 's/^/     /'

HOST_AFFINITY="$(field affinity "$WORK/host.txt")"
HOST_CPU="$(field cpu "$WORK/host.txt")"
HOST_SOURCE="$(field cpu_source "$WORK/host.txt")"

check "affinity == nproc" "$NPROC" "$HOST_AFFINITY"

# NOT an equality. `nproc` uses sched_getaffinity, but `Sys.CPU_THREADS` is
# `_SC_NPROCESSORS_ONLN`-shaped and ignores the affinity mask -- measured on
# this host: under `taskset -c 0,1`, nproc says 2 and Sys.CPU_THREADS still
# says 20. An equality check here hard-fails on any CI runner under a cpuset,
# for a reason that has nothing to do with the detector. The containment is the
# true relation, and it is the more interesting one: the gap is a SECOND way
# Julia's precompile limiter oversubscribes a restricted machine, on top of the
# CFS quota it also cannot see.
if [ "$HOST_AFFINITY" -le "$JULIA_CPU_THREADS" ]; then
  ok "affinity ($HOST_AFFINITY) <= Sys.CPU_THREADS ($JULIA_CPU_THREADS)"
  [ "$HOST_AFFINITY" -lt "$JULIA_CPU_THREADS" ] && \
    echo "       (this host is under a cpuset; Sys.CPU_THREADS does not see it)"
else
  bad "affinity ($HOST_AFFINITY) exceeds Sys.CPU_THREADS ($JULIA_CPU_THREADS)"
fi

if [ "$HOST_SOURCE" = "affinity" ]; then
  check "unconstrained host: detected cpu == nproc" "$NPROC" "$HOST_CPU"
else
  echo "  NOTE this host is itself under a $HOST_SOURCE quota"
  echo "       (quota_us=$(field quota_us "$WORK/host.txt") period_us=$(field period_us "$WORK/host.txt"))"
  echo "       so the equality above cannot hold; asserting the containment instead."
  if [ "$HOST_CPU" -le "$NPROC" ] && [ "$HOST_CPU" -ge 1 ]; then
    ok "constrained host: 1 <= detected cpu ($HOST_CPU) <= nproc ($NPROC)"
  else
    bad "constrained host: detected cpu $HOST_CPU out of range 1..$NPROC"
  fi
fi

check "net.pkgserver == num_concurrent_downloads()" \
  "$JULIA_CONCURRENT_DOWNLOADS" "$(field w_net_pkgserver "$WORK/host.txt")"

# The two Julia environment variables. Set for this ONE invocation, so the
# override path is exercised rather than merely documented -- everything above
# and below runs with them unset.
JULIA_PKG_CONCURRENT_DOWNLOADS=16 JULIA_NUM_PRECOMPILE_TASKS=3 \
  "$P" detect-env > "$WORK/env.txt" 2>"$WORK/env.err" || {
    echo "ERROR: probe detect-env failed: $(tail -2 "$WORK/env.err")" >&2; exit 2; }
JULIA_16="$(JULIA_PKG_CONCURRENT_DOWNLOADS=16 julia --startup-file=no -e \
  'using Pkg; print(Pkg.Types.num_concurrent_downloads())')"
check "JULIA_PKG_CONCURRENT_DOWNLOADS=16 -> net.pkgserver (Julia says $JULIA_16)" \
  "$JULIA_16" "$(field w_net_pkgserver "$WORK/env.txt")"
check "JULIA_NUM_PRECOMPILE_TASKS=3 -> cpu width" "3" "$(field w_cpu "$WORK/env.txt")"
check "JULIA_NUM_PRECOMPILE_TASKS=3 -> source is reported as the override" \
  "env_override" "$(field cpu_source "$WORK/env.txt")"

# statfs, against df's own answer for the same filesystem. df reports 1K blocks.
#
# Compared with a tolerance, not for equality: `f_bsize` (what this code
# multiplies by) and `f_frsize` (what statvfs, and hence some df builds, use)
# are equal on ext4/btrfs/tmpfs but need not be in general. A 1% band catches a
# unit error -- the failure worth catching -- without flaking on a filesystem
# where the two differ slightly.
DF_TOTAL_KB="$(df -Pk "$WORK" | awk 'NR==2{print $2}')"
read -r SP_TOTAL SP_AVAIL <<EOF
$("$P" space "$WORK")
EOF
DF_TOTAL=$((DF_TOTAL_KB * 1024))
DELTA=$(( SP_TOTAL > DF_TOTAL ? SP_TOTAL - DF_TOTAL : DF_TOTAL - SP_TOTAL ))
if [ "$DF_TOTAL" -gt 0 ] && [ $((DELTA * 100)) -le "$DF_TOTAL" ]; then
  ok "statfs total ($((SP_TOTAL / 1024 / 1024)) MiB) is within 1% of df ($((DF_TOTAL / 1024 / 1024)) MiB)"
else
  bad "statfs total $SP_TOTAL vs df $DF_TOTAL (delta $DELTA, over the 1% band)"
fi
# `avail` is only bounded above: a 100%-full filesystem legitimately reports 0.
if [ "$SP_AVAIL" -le "$SP_TOTAL" ]; then
  ok "statfs available ($((SP_AVAIL / 1024 / 1024)) MiB) is within total"
else
  bad "statfs available $SP_AVAIL exceeds total $SP_TOTAL"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 2. THE GATE: a real 2-CPU container must be detected as 2, not $NPROC"
# ---------------------------------------------------------------------------
FELL_BACK=0

DOCKER_OK=0
if [ $NO_DOCKER -eq 1 ]; then
  echo "  NOTE --no-docker: taking the fallback branch on purpose."
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker image inspect alpine >/dev/null 2>&1 || docker pull alpine >/dev/null 2>&1; then
    DOCKER_OK=1
  fi
fi

if [ "$NPROC" -le 2 ]; then
  echo "  NOTE this host has only $NPROC CPUs, so '2, not nproc' cannot"
  echo "       distinguish a working detector from a broken one here."
fi

# The quota list is built from $NPROC, not hard-coded. Two reasons, both
# observed: docker REFUSES a quota above the host's core count outright
# ("range of CPUs is from 0.01 to 20.00"), and even where a larger quota is
# accepted the detector correctly returns the smaller affinity number -- so a
# hard-coded `--cpus 4` fails on a 2-core runner for a reason that has nothing
# to do with the code under test.
CPUS_LIST="1"
[ "$NPROC" -ge 2 ] && CPUS_LIST="$CPUS_LIST 2"
[ "$NPROC" -ge 4 ] && CPUS_LIST="$CPUS_LIST 4"

if [ $DOCKER_OK -eq 1 ]; then
  # $WORK read-only: the container needs to run the probe, never to write.
  drun() { docker run --rm -v "$WORK:/w:ro" "$@" alpine /w/probe detect; }

  for CPUS in $CPUS_LIST; do
    if ! drun --cpus "$CPUS" > "$WORK/c$CPUS.txt" 2>"$WORK/c$CPUS.err"; then
      bad "docker run --cpus $CPUS failed
    $(tail -3 "$WORK/c$CPUS.err")"
      continue
    fi
    C_CPU="$(field cpu "$WORK/c$CPUS.txt")"
    C_SRC="$(field cpu_source "$WORK/c$CPUS.txt")"
    C_AFF="$(field affinity "$WORK/c$CPUS.txt")"
    check "--cpus $CPUS -> detected cpu" "$CPUS" "$C_CPU"
    check "--cpus $CPUS -> source is a cgroup, not affinity" "cgroup_v2" "$C_SRC"
    # The point of the whole module: affinity inside the container is still the
    # host's core count, and using it would be the bug.
    check "--cpus $CPUS -> affinity is STILL the host's $NPROC (this is why nproc is wrong)" \
      "$NPROC" "$C_AFF"
    # What Base would have done with that same affinity count
    # (`base/precompilation.jl:569-570`). Informational; guarded so a missing
    # field cannot turn into a julia syntax error and a garbage line.
    if [ -n "$C_AFF" ]; then
      JULIA_WOULD="$(julia --startup-file=no -e "print(min($C_AFF + 1, 16))")"
      echo "       (Base's limiter here would be min($C_AFF+1,16) = $JULIA_WOULD forked Julias)"
    fi
  done

  # cpuset: no quota at all, so this must be caught by affinity alone.
  if drun --cpuset-cpus 0,1 > "$WORK/cpuset.txt" 2>"$WORK/cpuset.err"; then
    check "--cpuset-cpus 0,1 -> detected cpu" "2" "$(field cpu "$WORK/cpuset.txt")"
    check "--cpuset-cpus 0,1 -> source is affinity (a mask, not a quota)" \
      "affinity" "$(field cpu_source "$WORK/cpuset.txt")"
  else
    echo "  SKIP --cpuset-cpus (rejected by this docker/kernel)"
  fi

  # The engine node exactly: deploy/stack-app.yml:333-339.
  #
  # Skipped on a host with <= 6 GiB of RAM: `detectMemory` takes the MINIMUM of
  # the cgroup limit and MemTotal (a limit above physical memory is not a
  # budget, it is a way to get OOM-killed), so on such a host the answer is
  # correctly `meminfo` rather than `cgroup_v2` and these expectations would be
  # wrong rather than the code.
  HOST_MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$NPROC" -lt 2 ]; then
    echo "  SKIP the engine-node case: this host has $NPROC CPU(s), fewer than the 2 it pins"
  elif [ "${HOST_MEM_KB:-0}" -le $((6144 * 1024)) ]; then
    echo "  SKIP the engine-node case: this host has $((HOST_MEM_KB / 1024)) MiB, <= the 6144 MiB it pins"
  elif drun --cpus 2 --memory 6144m > "$WORK/engine.txt" 2>"$WORK/engine.err"; then
    echo "     engine node (--cpus 2 --memory 6144m):"
    sed 's/^/       /' "$WORK/engine.txt"
    check "engine node -> cpu width" "2" "$(field cpu "$WORK/engine.txt")"
    check "engine node -> disk width" "2" "$(field w_disk "$WORK/engine.txt")"
    check "engine node -> net.pkgserver is untouched by the CPU quota" \
      "$JULIA_CONCURRENT_DOWNLOADS" "$(field w_net_pkgserver "$WORK/engine.txt")"
    check "engine node -> memory budget is 6144M" "$((6144 * 1024 * 1024))" \
      "$(field memory_bytes "$WORK/engine.txt")"
    check "engine node -> memory source" "cgroup_v2" "$(field memory_source "$WORK/engine.txt")"
    # 6144M less max(256 MiB, 6144M/8 = 768 MiB) of headroom.
    check "engine node -> bucket capacity" "$(( (6144 - 768) * 1024 * 1024 ))" \
      "$(field w_memory_bytes "$WORK/engine.txt")"
    EST="$("$P" est-rss)"
    echo "       (bucket admits $(( $(field w_memory_bytes "$WORK/engine.txt") / EST )) concurrent compiles at the default $((EST / 1024 / 1024)) MiB estimate)"
  else
    bad "docker run --cpus 2 --memory 6144m failed
    $(tail -3 "$WORK/engine.err")"
  fi
else
  FELL_BACK=1
  if [ $NO_DOCKER -eq 1 ]; then WHY="--no-docker was passed"; else WHY="docker is unavailable"; fi
  # printf-padded rather than hand-aligned: $WHY varies in length, and a banner
  # whose box does not close reads as a broken script.
  say() { printf '# %-68s #\n' "$1"; }
  echo
  echo "########################################################################"
  say "FALLING BACK to a FAKE cgroup tree: $WHY."
  say ""
  say "This is a WEAKER test and the difference is not cosmetic. It proves"
  say "the parser and the ancestor walk. It does NOT prove that the files a"
  say "real container runtime writes are the files this code reads -- which"
  say "is exactly the part that goes wrong in practice. Re-run with a"
  say "usable docker before trusting a green result here."
  echo "########################################################################"

  # What `docker run --cpus 2` actually produces, transcribed from a real run:
  #   /proc/self/cgroup  -> "0::/"     (private cgroup namespace)
  #   /sys/fs/cgroup/cpu.max -> "200000 100000"
  FAKE="$WORK/fake"
  mkdir -p "$FAKE/cgroup" "$FAKE/proc/self"
  printf '0::/\n'            > "$FAKE/proc/self/cgroup"
  printf '200000 100000\n'   > "$FAKE/cgroup/cpu.max"
  printf '6442450944\n'      > "$FAKE/cgroup/memory.max"

  "$P" detect "$FAKE/cgroup" "$FAKE/proc" > "$WORK/fake.txt" || {
    echo "ERROR: probe detect on the fake tree failed" >&2; exit 2; }
  sed 's/^/     /' "$WORK/fake.txt"
  check "fake --cpus 2 tree -> detected cpu" "2" "$(field cpu "$WORK/fake.txt")"
  check "fake --cpus 2 tree -> source" "cgroup_v2" "$(field cpu_source "$WORK/fake.txt")"
  # No affinity check here: the fake tree cannot influence sched_getaffinity,
  # so asserting it is still $NPROC restates section 1 and can never fail.
  check "fake tree -> memory budget" "$((6144 * 1024 * 1024))" "$(field memory_bytes "$WORK/fake.txt")"
  # The ancestor walk, which the container case cannot exercise (a private
  # cgroup namespace puts the limit at the root).
  FAKED="$WORK/fake-deep"
  mkdir -p "$FAKED/cgroup/system.slice/docker-abc.scope" "$FAKED/proc/self"
  printf '0::/system.slice/docker-abc.scope\n' > "$FAKED/proc/self/cgroup"
  printf 'max 100000\n'    > "$FAKED/cgroup/cpu.max"
  printf '400000 100000\n' > "$FAKED/cgroup/system.slice/cpu.max"
  printf '200000 100000\n' > "$FAKED/cgroup/system.slice/docker-abc.scope/cpu.max"
  "$P" detect "$FAKED/cgroup" "$FAKED/proc" > "$WORK/faked.txt" || {
    echo "ERROR: probe detect on the deep tree failed" >&2; exit 2; }
  check "fake --cgroupns=host tree -> the tightest quota on the chain wins" \
    "2" "$(field cpu "$WORK/faked.txt")"

  # cgroup v1, which no container on this host can produce any more.
  FAKE1="$WORK/fake-v1"
  mkdir -p "$FAKE1/cgroup/cpu,cpuacct/docker/abc" "$FAKE1/cgroup/memory/docker/abc" "$FAKE1/proc/self"
  printf '11:memory:/docker/abc\n4:cpu,cpuacct:/docker/abc\n' > "$FAKE1/proc/self/cgroup"
  printf '200000\n' > "$FAKE1/cgroup/cpu,cpuacct/docker/abc/cpu.cfs_quota_us"
  printf '100000\n' > "$FAKE1/cgroup/cpu,cpuacct/docker/abc/cpu.cfs_period_us"
  printf '6442450944\n' > "$FAKE1/cgroup/memory/docker/abc/memory.limit_in_bytes"
  "$P" detect "$FAKE1/cgroup" "$FAKE1/proc" > "$WORK/fake1.txt" || {
    echo "ERROR: probe detect on the v1 tree failed" >&2; exit 2; }
  check "fake cgroup-v1 tree -> detected cpu" "2" "$(field cpu "$WORK/fake1.txt")"
  check "fake cgroup-v1 tree -> source" "cgroup_v1" "$(field cpu_source "$WORK/fake1.txt")"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 3. widths for known (nproc, quota, memory) triples"
# ---------------------------------------------------------------------------
# The arithmetic is restated here, in shell, rather than read back out of Zig:
#   net.pkgserver = num_concurrent_downloads()      (Julia, above)
#   net.cachestore = 4
#   disk          = max(2, min(4, cpu/4))
#   cpu           = min(nproc, quota)
#   memory        = budget - max(256 MiB, budget/8)
triple() { # label affinity cpu memory_bytes want_disk want_cpu
  local label="$1" aff="$2" cpu="$3" mem="$4" want_disk="$5" want_cpu="$6"
  local headroom=$(( mem / 8 ))
  [ "$headroom" -lt $((256 * 1024 * 1024)) ] && headroom=$((256 * 1024 * 1024))
  local want="$JULIA_CONCURRENT_DOWNLOADS 4 $want_disk $want_cpu $(( mem - headroom ))"
  check "$label" "$want" "$("$P" widths-of "$aff" "$cpu" "$mem")"
}

# The dev box: 20 cores, no quota, 31.8 GiB (MemTotal 32561216 kB).
triple "dev box   (nproc=20, no quota, 31.0 GiB)" 20 20 $((32561216 * 1024)) 4 20
# The engine node: the SAME 20-core host, quota 2.0, memory 6144M.
triple "engine    (nproc=20, --cpus 2, 6144M)"    20  2 $((6144 * 1024 * 1024)) 2 2
# A single-CPU box: the disk floor of 2 has to hold.
triple "1 CPU     (nproc=1,  no quota, 2 GiB)"     1  1 $((2 * 1024 * 1024 * 1024)) 2 1
# A tiny budget: headroom is the 256 MiB floor, not an eighth.
triple "tiny      (nproc=4,  no quota, 1 GiB)"     4  1 $((1024 * 1024 * 1024)) 2 1
# 16 CPUs: min(4, 16/4) is exactly at the cap.
triple "16 CPUs   (nproc=16, no quota, 16 GiB)"   16 16 $((16 * 1024 * 1024 * 1024)) 4 16

# A restatement of the two rows above, not an independent check -- so it is an
# echo. Counting it as a check would inflate $PASS with something that cannot
# fail unless "engine" or "dev box" already did.
echo "     (one code path, two answers: engine cpu=2 / dev box cpu=20)"

# ---------------------------------------------------------------------------
echo
if [ $FAIL -eq 0 ]; then
  if [ $FELL_BACK -eq 1 ]; then
    echo "PASS (PARTIAL) — $PASS checks; section 2 used the FAKE cgroup tree, see above"
    exit 3
  fi
  echo "PASS — $PASS checks: a real --cpus 2 container is detected as 2 while"
  echo "       nproc still says $NPROC, the four classes are sized independently,"
  echo "       and net.pkgserver still matches num_concurrent_downloads()"
  exit 0
fi
echo "FAIL — $FAIL of $((PASS+FAIL)) checks" >&2
[ $KEEP -eq 0 ] && echo "(re-run with --keep to inspect)" >&2
exit 1
