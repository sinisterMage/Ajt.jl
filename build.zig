const std = @import("std");
const Io = std.Io;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dgit: compile libgit2 from source and link it in, which is what turns
    // `src/git/lib.zig` from a stub into a backend.
    //
    // The default is OFF, and that is forced rather than preferred.
    // `b.lazyDependency` is a CONFIGURE-time act: a miss records the package in
    // `graph.needed_lazy_dependencies` and the parent process fetches it before
    // the make phase starts at all (`std/Build.zig:2018-2053`). There is no way
    // to ask "is the exe in the requested step graph?" from `build()`, so an
    // option defaulting to true would pull ~30 MB of C down for `zig build
    // test` too -- exactly what `.lazy = true` in build.zig.zon exists to
    // prevent. `zig build -Dgit` and `zig build test-git -Dgit` opt in.
    const want_git = b.option(
        bool,
        "git",
        "Build the libgit2 git backend (fetches ~30 MB of C on first use)",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "have_libgit2", want_git);
    // The version lives in the manifest and nowhere else. `ajt version` reads
    // this through `ajt.version`, so a release tag has exactly one string to
    // agree with rather than two that can drift apart -- which they had.
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // Null when `-Dgit` was passed but the tarball is not in the cache yet: the
    // configure phase then exists only to name the lazy dependency, and the
    // whole build script is re-run once it has been fetched.
    const upstream: ?*std.Build.Dependency =
        if (want_git) b.lazyDependency("libgit2", .{}) else null;
    const libgit2: ?*std.Build.Step.Compile =
        if (upstream) |u| buildLibgit2(b, u, target, optimize) else null;

    // Everything with real logic lives in the library module so it can be
    // unit-tested without going through the CLI. src/julia/ and src/solver/
    // additionally take no I/O at all, which is what makes them exhaustively
    // testable and fuzzable -- that is where correctness lives.
    const mod = b.addModule("ajt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    if (libgit2) |lg| mod.linkLibrary(lg);

    const exe = b.addExecutable(.{
        .name = "ajt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ajt", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the ajt CLI");
    run_step.dependOn(&run_cmd.step);

    // A module of its own rather than `mod`, for one reason: `abi_probe.c` is
    // the only C Ajt owns, it exists solely so a Zig test can compare Zig's
    // `@sizeOf`/`@offsetOf` against the C compiler's, and it has no business in
    // the shipped binary.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", build_options);
    if (libgit2) |lg| {
        test_mod.linkLibrary(lg);
        test_mod.addCSourceFile(.{
            .file = b.path("src/git/abi_probe.c"),
            .flags = &.{"-D_GNU_SOURCE"},
        });
    }

    // `-Dtest-filter=<substring>`, repeatable. The suite has grown past the
    // point where "run everything to see one test" is a reasonable loop, and it
    // contains a handful of tests that stand up local servers -- which contend
    // for ports when several checkouts build at once. Being able to name the
    // tests you care about is the difference between a five-second edit cycle
    // and a flaky one.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this (repeatable)",
    ) orelse &.{};

    const mod_tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // `test-git` is the same test binary, and exists to be the command a reader
    // reaches for. It cannot turn `-Dgit` on by itself -- build options are
    // resolved once, for the whole configure phase, before any step name is
    // looked at -- so without it the step says so, instead of quietly passing a
    // suite in which every libgit2 test was compiled out.
    const test_git_step = b.step("test-git", "Run unit tests including the libgit2 backend (requires -Dgit)");
    if (want_git) {
        test_git_step.dependOn(&run_mod_tests.step);
    } else {
        const fail = b.addFail(
            "the libgit2 tests are compiled out of this build; run `zig build test-git -Dgit`",
        );
        test_git_step.dependOn(&fail.step);
    }
}

// ---------------------------------------------------------------------------
// libgit2
//
// Built from a pinned tarball with `zig cc`, as a static library with no
// external dependency at all: no OpenSSL, no mbedTLS, no libssh2, no system
// zlib, no PCRE. HTTPS is supplied from the Zig side instead, through a
// `git_stream` registered at init (`src/git/tls.zig`), which is why `GIT_HTTPS`
// and every TLS backend below are left unset while `https://` still works --
// `streams/tls.c:28` consults the stream registry BEFORE its own `#ifdef`
// ladder, and `transport.c:31-44` registers the `https://` row unconditionally.
//
// The file lists are globbed, not enumerated. A version bump that adds a source
// file must not silently drop it, and every backend we do not want compiles to
// an empty translation unit under the feature header anyway --
// `streams/openssl.c`, `streams/mbedtls.c`, `streams/schannel.c`,
// `streams/stransport.c` and `transports/ssh*.c` are all `#ifdef`-ed in their
// entirety. The one directory that is NOT globbed is `src/util/hash/`, because
// `hash/openssl.h:11-18` includes `<openssl/sha.h>` unconditionally: that file
// does not compile to an empty TU, it fails to compile at all.
// ---------------------------------------------------------------------------

fn buildLibgit2(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;

    // Upstream's own template, rendered by `std.Build.Step.ConfigHeader` rather
    // than hand-written. That is deliberate: an unlisted `#cmakedefine` renders
    // as `/* #undef FOO */` (`ConfigHeader.zig:461-463`, `:566`), so a feature
    // added by a future libgit2 arrives explicitly off instead of as a macro
    // that quietly does not exist.
    const features = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("src/util/git2_features.h.in") },
        .include_path = "git2_features.h",
    }, .{
        .GIT_THREADS = true,
        // From the target, not hard-coded.
        .GIT_ARCH_64 = t.ptrBitWidth() == 64,
        .GIT_ARCH_32 = t.ptrBitWidth() == 32,

        // stat(2) nanoseconds. `GIT_USE_NSEC` is left OFF on purpose: it makes
        // the index record sub-second times, and an index whose racily-clean
        // detection differs from the system `git`'s is a difference nobody
        // asked Ajt for.
        .GIT_USE_STAT_MTIM = true,
        .GIT_USE_FUTIMENS = true,

        // Bundled PCRE, bundled llhttp, bundled zlib, sha1dc, rfc6234 SHA-256.
        // Every one of these is "no system library", which is what makes the
        // static musl link a single self-contained binary.
        .GIT_REGEX_BUILTIN = true,
        .GIT_HTTPPARSER_BUILTIN = true,
        .GIT_COMPRESSION_BUILTIN = true,
        .GIT_SHA1_COLLISIONDETECT = true,
        .GIT_SHA256_BUILTIN = true,

        // Off on Darwin, and that is upstream's own answer rather than a
        // workaround: libgit2 probes this with
        // `check_symbol_exists(getentropy "unistd.h")`, and Apple declares
        // `getentropy` in `<sys/random.h>` instead. `rand.c` includes neither
        // -- it takes the declaration from `git2_util.h`'s `<unistd.h>` -- so
        // claiming the feature on macOS is a call to an undeclared function,
        // which C99 makes a hard error. The `#else` branch reads
        // `/dev/urandom`, which is what a macOS libgit2 uses anyway.
        .GIT_RAND_GETENTROPY = !t.os.tag.isDarwin(),
        .GIT_IO_POLL = true,

        // musl 1.2.5 HAS the GNU-signature `qsort_r`, but declares it only
        // under `_GNU_SOURCE`. Without the declaration, C99 implicit-declaration
        // rules give a two-argument comparator while libgit2 passes three plus a
        // payload; the argument registers do not line up and the result is a
        // SILENTLY WRONG SORT rather than a link error. `-D_GNU_SOURCE` is on
        // every file below for exactly this, and `git_vector_sort` is covered by
        // a 10k-element test in `src/git/c.zig`.
        .GIT_QSORT_GNU = true,
    });

    // Bundled PCRE 8.x. Note the `@NEWLINE@`-style substitutions alongside the
    // `#cmakedefine`s -- so this is `.cmake` style too, and a missing value is a
    // hard error rather than an empty expansion (`ConfigHeader.zig:611-614`).
    // The values are the ones `deps/pcre/CMakeLists.txt:29-38` sets.
    const pcre_config = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("deps/pcre/config.h.in") },
        .include_path = "config.h",
    }, .{
        .HAVE_DIRENT_H = true,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_UNISTD_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_INTTYPES_H = true,
        .HAVE_MEMMOVE = true,
        .HAVE_STRERROR = true,
        .HAVE_STRTOLL = true,
        .HAVE_LONG_LONG = true,
        .HAVE_UNSIGNED_LONG_LONG = true,
        .SUPPORT_PCRE8 = true,
        // No JIT: it would be a second code generator inside a package manager,
        // and `git_regexp` only ever runs attribute and refspec patterns.
        // `NO_RECURSE` keeps the matcher off the C stack, which matters because
        // the patterns come from a repository rather than from us.
        .NO_RECURSE = true,
        .NEWLINE = 10, // PCRE_NEWLINE=LF
        .PCRE_POSIX_MALLOC_THRESHOLD = 10,
        .PCRE_LINK_SIZE = 2,
        .PCRE_PARENS_NEST_LIMIT = 250,
        .PCRE_MATCH_LIMIT = 10000000,
        .PCRE_MATCH_LIMIT_RECURSION = .MATCH_LIMIT,
        .PCREGREP_BUFSIZE = 20480,
    });

    // `sanitize_c = .off` across the board. sha1dc does unaligned 32-bit loads
    // and signed left shifts, and PCRE indexes past the declared end of a
    // trailing array; all of it is deliberate and all of it traps under Zig's
    // default `-fsanitize=undefined` for C. This is upstream C we do not own, so
    // the sanitizer here would report facts about libgit2 rather than about Ajt.
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });

    const lib = b.addLibrary(.{
        .name = "git2",
        .linkage = .static,
        .root_module = lib_mod,
    });

    lib_mod.addConfigHeader(features);
    lib_mod.addIncludePath(upstream.path("include"));
    lib_mod.addIncludePath(upstream.path("src/libgit2"));
    lib_mod.addIncludePath(upstream.path("src/util"));
    lib_mod.addIncludePath(upstream.path("deps/llhttp"));
    lib_mod.addIncludePath(upstream.path("deps/xdiff"));
    lib_mod.addIncludePath(upstream.path("deps/zlib"));
    lib_mod.addIncludePath(upstream.path("deps/pcre"));

    const base_flags: []const []const u8 = &.{"-D_GNU_SOURCE"};

    addCDir(b, lib_mod, upstream, "src/libgit2", base_flags);
    addCDir(b, lib_mod, upstream, "src/libgit2/streams", base_flags);
    addCDir(b, lib_mod, upstream, "src/libgit2/transports", base_flags);
    addCDir(b, lib_mod, upstream, "src/util", base_flags);
    addCDir(b, lib_mod, upstream, "src/util/allocators", base_flags);
    addCDir(b, lib_mod, upstream, "src/util/unix", base_flags);
    addCDir(b, lib_mod, upstream, "deps/llhttp", base_flags);
    addCDir(b, lib_mod, upstream, "deps/xdiff", base_flags);
    addCDir(b, lib_mod, upstream, "deps/zlib", base_flags);

    // SHA-1 with collision detection, and SHA-256 from RFC 6234. Named one by
    // one because `src/util/hash/` also holds the openssl/mbedTLS/CommonCrypto
    // backends, whose HEADERS include the system library unconditionally.
    lib_mod.addCSourceFile(.{
        .file = upstream.path("src/util/hash/collisiondetect.c"),
        .flags = base_flags,
    });
    lib_mod.addCSourceFile(.{
        .file = upstream.path("src/util/hash/builtin.c"),
        .flags = base_flags,
    });
    addCDir(b, lib_mod, upstream, "src/util/hash/rfc6234", base_flags);

    // sha1dc is vendored to be dropped into a host project's own headers: under
    // `SHA1DC_NO_STANDARD_INCLUDES` it includes NOTHING by itself and takes
    // `stdint.h`, byte order and `memcpy` from whatever the two
    // `SHA1DC_CUSTOM_INCLUDE_*` macros name (`src/util/CMakeLists.txt:34-36`).
    // Get them wrong and it still compiles -- to a hash that is not SHA-1.
    // `ajt git hash-object` is differential-gated against `git hash-object` for
    // exactly this reason (`tools/diff_harness/git_stream.sh`), because Ajt's
    // own tree hashing uses native Zig SHA-1 and would never notice.
    addCDir(b, lib_mod, upstream, "src/util/hash/sha1dc", &.{
        "-D_GNU_SOURCE",
        "-DSHA1DC_NO_STANDARD_INCLUDES=1",
        "-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\"",
        "-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\"",
    });

    // PCRE is a separate compilation-unit set with its OWN include path, not
    // just its own `-DHAVE_CONFIG_H`. Both `deps/pcre/*.c` and
    // `src/libgit2/config.c` include `"config.h"`, and they mean different
    // files: a quoted include resolves in the including file's own directory
    // first, so libgit2's own sources are safe, but anything under
    // `src/libgit2/transports/` that includes `"config.h"` falls through to the
    // -I list and would find PCRE's. Today only `transports/ssh_exec.c:14` does,
    // behind `#ifdef GIT_SSH_EXEC`; keeping the two apart makes the collision
    // impossible rather than merely absent in this version.
    const pcre_obj = b.addObject(.{
        .name = "git2_pcre",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    pcre_obj.root_module.addConfigHeader(pcre_config);
    pcre_obj.root_module.addIncludePath(upstream.path("deps/pcre"));
    addCFiles(b, pcre_obj.root_module, upstream, "deps/pcre", &.{ "-D_GNU_SOURCE", "-DHAVE_CONFIG_H" }, &pcre_sources);
    lib_mod.addObject(pcre_obj);

    lib.installHeadersDirectory(upstream.path("include"), "", .{});
    return lib;
}

/// `deps/pcre/CMakeLists.txt:120-146`, verbatim and in its order.
///
/// The one directory in this build that is enumerated rather than globbed, and
/// the reason is `pcre_printint.c`: it is not a translation unit at all, it is
/// `#include`d into `pcre_compile.c` under `PCRE_DEBUG`, so compiling it on its
/// own is an error rather than a no-op.
const pcre_sources = [_][]const u8{
    "pcre_byte_order.c",
    "pcre_chartables.c",
    "pcre_compile.c",
    "pcre_config.c",
    "pcre_dfa_exec.c",
    "pcre_exec.c",
    "pcre_fullinfo.c",
    "pcre_get.c",
    "pcre_globals.c",
    "pcre_jit_compile.c",
    "pcre_maketables.c",
    "pcre_newline.c",
    "pcre_ord2utf8.c",
    "pcre_refcount.c",
    "pcre_string_utils.c",
    "pcre_study.c",
    "pcre_tables.c",
    "pcre_ucd.c",
    "pcre_valid_utf8.c",
    "pcre_version.c",
    "pcre_xclass.c",
    "pcreposix.c",
};

/// Every `*.c` directly in `sub_path`, sorted.
///
/// Sorted because `Dir.iterate` yields filesystem order, which differs between
/// two unpackings of the same tarball and would otherwise make the build cache
/// key depend on inode layout.
fn addCDir(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    sub_path: []const u8,
    flags: []const []const u8,
) void {
    const io = b.graph.io;
    var dir = upstream.builder.build_root.handle.openDir(io, sub_path, .{ .iterate = true }) catch |err|
        std.debug.panic("libgit2: cannot open '{s}': {t}", .{ sub_path, err });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err|
        std.debug.panic("libgit2: cannot read '{s}': {t}", .{ sub_path, err })) |entry|
    {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    // A glob that silently matched nothing is how a renamed upstream directory
    // turns into a link error a hundred symbols later.
    if (names.items.len == 0)
        std.debug.panic("libgit2: no .c files in '{s}' -- upstream layout changed", .{sub_path});
    std.mem.sort([]const u8, names.items, {}, lessThanAsc);

    addCFiles(b, mod, upstream, sub_path, flags, names.items);
}

fn addCFiles(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    sub_path: []const u8,
    flags: []const []const u8,
    names: []const []const u8,
) void {
    for (names) |name| {
        mod.addCSourceFile(.{
            .file = upstream.path(b.pathJoin(&.{ sub_path, name })),
            .flags = flags,
        });
    }
}

fn lessThanAsc(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
