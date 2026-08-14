using Test
using Ajt
import Pkg
import REPL

# The suite is in three layers, cheapest first:
#
#   1. conformance — pure metadata, no binary, no environment. This is the one
#      that fails when Pkg grows a function.
#   2. routing     — argument and keyword gating, and `]`-mode dispatch, both
#      driven through `Pkg.REPLMode.TEST_MODE` so nothing executes.
#   3. behaviour   — the binary, against throwaway copies of a real environment.
#      Skipped with a message when the binary has not been built, because
#      `zig build` is not something a `Pkg.test` can do for you.

const BINARY = try
    Ajt.binary(refresh = true)
catch err
    @info "Ajt: binary not found, skipping the behavioural tests" exception = (err, Any[])
    nothing
end

"""
A throwaway copy of an environment. Every behavioural test writes, so nothing
here may ever point at a tree someone else owns.
"""
function envcopy(f, project::String, manifest::String)
    dir = mktempdir()
    return try
        cp(project, joinpath(dir, "Project.toml"))
        cp(manifest, joinpath(dir, "Manifest.toml"))
        f(dir)
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
Run `f` with `dir` as the active project, always putting the previous one back.
"""
function withenv_project(f, dir::String)
    previous = Base.active_project()
    return try
        Base.set_active_project(joinpath(dir, "Project.toml"))
        f()
    finally
        Base.set_active_project(previous)
    end
end

"""
Did calling `f` produce a delegation notice?

The notice is `@info` with `maxlog = 1` keyed per function name, so it fires once
per *logger*: a fresh `TestLogger` per call is what keeps these assertions from
depending on the order the tests run in. `f` is expected to go on and fail —
delegating to Pkg with an argument Pkg itself rejects is the normal shape of
these cases — so its exception is swallowed and only the routing is asserted.
"""
function delegates(f)
    logger = Test.TestLogger(min_level = Base.CoreLogging.Info)
    Base.CoreLogging.with_logger(logger) do
        try
            f()
        catch
        end
    end
    return any(r -> occursin("delegating to Pkg", r.message), logger.logs)
end

"""
A pty, as `(slave::RawFD, master::Base.TTY)`.

The `]` take-over only exists on a terminal, so testing it needs one. Julia
tests its own REPL exactly this way (`test/testhelpers/FakePTYs.jl`) and, like
that helper, this goes through `posix_openpt`/`grantpt`/`unlockpt` rather than
`openpty` so it needs libc alone and no libutil.

Throws rather than returning a sentinel; the caller decides whether a machine
with no pty is a skip or a failure.
"""
function open_fake_pty()
    flags = Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_NOCTTY
    fdm = ccall(:posix_openpt, Cint, (Cint,), flags)
    fdm == -1 && error("posix_openpt failed")
    ccall(:grantpt, Cint, (Cint,), fdm) == 0 || error("grantpt failed")
    ccall(:unlockpt, Cint, (Cint,), fdm) == 0 || error("unlockpt failed")
    name = ccall(:ptsname, Ptr{UInt8}, (Cint,), fdm)
    name == C_NULL && error("ptsname failed")
    fds = ccall(:open, Cint, (Ptr{UInt8}, Cint), name, flags)
    fds == -1 && error("opening the pty slave failed")
    return RawFD(fds), Base.TTY(RawFD(fdm))
end

"""
Did the child die inside Julia's own code loader, rather than failing at
anything Ajt did?

Matched on the frames the crash dump prints, because a segfault has no exception
to catch: the child is simply gone and the only evidence is on the terminal.
"""
crashed_in_julias_loader(transcript) =
    occursin("staticdata.c", transcript) && occursin("load_pkg", transcript)

"""
What to say when that happens. Stated once, here, because the alternative is a
maintainer re-deriving it from a stack trace every time this gate goes red.
"""
const UPSTREAM_CRASH = """
Julia crashed inside its own package-image loader. This is not an Ajt failure.

Pressing `]` makes the REPL load Pkg's extension from a task it spawns
(`REPL/src/REPL.jl:1439` -> `load_pkg`), and Julia segfaults restoring that
image: `ijl_restore_package_image_from_file`, `src/staticdata.c`. Measured on
one machine at roughly half of runs *with Ajt's take-over disabled entirely*
(`AJT_REPL=0`), so it needs neither Ajt nor this test to happen — it is what a
user gets for pressing `]`.

This gate reports it rather than routing around it. Warming the extension in a
child process before opening the pty makes it mostly go away, which is exactly
why that is not done here: it would hide a crash real users hit.
"""

# A real environment to test against. `AJT_TEST_ENV` names a directory holding a
# Project.toml and a Manifest.toml; without one, the active project is used when
# it has both — which under `Pkg.test` is the sandbox environment Pkg just
# generated, a real 30-entry environment that is safe to copy and resolve. The
# behavioural layer skipping itself by default is how every bug it would have
# caught stays caught by nothing.
function _default_test_env()
    project = Base.active_project()
    project === nothing && return ""
    dir = dirname(project)
    return (isfile(joinpath(dir, "Project.toml")) && isfile(joinpath(dir, "Manifest.toml"))) ? dir : ""
end

const TEST_ENV = get(ENV, "AJT_TEST_ENV") do
    _default_test_env()
end

@testset "Ajt" begin

    @testset "conformance" begin
        report = Ajt.conformance()

        # The ratchet. If this fails, `names(Pkg)` grew a name and this package
        # has to say what it intends to do about it — natively, or by
        # delegating, but never by leaving a hole in a drop-in replacement.
        @test isempty(report.unaccounted)
        # ... and every name a bucket claims has to actually exist here.
        @test isempty(report.undefined)

        # The failure has to *fire*. A conformance check that cannot fail is a
        # comment. This is the deliberate check that the check works.
        injected = Ajt.conformance(Symbol[:add, :definitely_not_a_pkg_function])
        @test injected.unaccounted == [:definitely_not_a_pkg_function]

        # Every public Pkg name is callable here, not merely classified.
        for name in names(Pkg)
            @test isdefined(Ajt, name)
        end

        # Every delegating function forwards to a `Pkg.<name>` that exists. The
        # forwarding body only resolves `Pkg.$name` when it is *called*, so a
        # name Pkg renames would otherwise sail through load, through
        # precompilation and through this whole testset, and fail at a user.
        for name in keys(Ajt.DELEGATED)
            @test isdefined(Pkg, name)
        end
        for name in keys(Ajt.Registry.DELEGATED)
            @test isdefined(Pkg.Registry, name)
        end

        # The three buckets are disjoint: a name that is both native and
        # delegating means one of the two is a lie.
        @test isempty(intersect(Set(Ajt.NATIVE), keys(Ajt.DELEGATED)))
        @test isempty(intersect(Set(Ajt.REEXPORTED), keys(Ajt.DELEGATED)))
        @test isempty(intersect(Set(Ajt.NATIVE), Set(Ajt.REEXPORTED)))

        # Re-exports must be Pkg's own objects. A wrapper with its own
        # `PackageSpec` type would break every caller that passes one in.
        for name in Ajt.REEXPORTED
            name === :Pkg && continue
            @test getfield(Ajt, name) === getfield(Pkg, name)
        end

        # Same ratchet, one level down.
        registry = Ajt.Registry.conformance()
        @test isempty(registry.unaccounted)
        @test isempty(registry.undefined)

        # `DIFFERENCES` may only describe functions that are actually native —
        # a difference recorded against a delegating function describes Pkg.
        @test issubset(keys(Ajt.DIFFERENCES), Set(Ajt.NATIVE))

        # And it renders — with the content that makes it worth printing.
        rendered = sprint(Ajt.parity; context = :color => false)
        @test occursin("native      resolve", rendered)
        @test occursin(Ajt.DELEGATED[:precompile], rendered)
        @test occursin(first(Ajt.DIFFERENCES[:instantiate]), rendered)
        @test occursin("every name in `names(Pkg)` is accounted for", rendered)
    end

    @testset "binary discovery" begin
        candidates = Ajt.binary_candidates()
        @test !isempty(candidates)

        # `AJT_BINARY` is consulted first, ahead of the source checkout and PATH.
        withenv("AJT_BINARY" => "/nonexistent/ajt-from-env") do
            @test first(Ajt.binary_candidates()) == "/nonexistent/ajt-from-env"
        end

        # "not found" has to say where it looked, or the next person has to go
        # read the source to find out. Checked with an explicit candidate list,
        # since on any machine running this the real binary is present.
        err = try
            Ajt.binary(candidates = ["/nonexistent/one", "/nonexistent/two"])
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("/nonexistent/one", err.msg)
        @test occursin("/nonexistent/two", err.msg)
        @test occursin("zig build", err.msg)
        # ... and probing with an explicit list must not disturb the cache.
        BINARY === nothing || @test Ajt.binary() == BINARY
    end

    @testset "spec translation" begin
        # What the binary can be handed directly...
        @test Ajt._spec_arg(Pkg.PackageSpec("Foo")) == "Foo"
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", version = "1.2")) == "Foo@1.2"
        # ... and what it cannot, each of which has to come back as `nothing`
        # so the caller delegates instead of silently dropping the constraint.
        @test Ajt._spec_arg(Pkg.PackageSpec(url = "https://example.com/Foo.jl")) === nothing
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", rev = "main")) === nothing
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", path = "/tmp/Foo")) === nothing
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", subdir = "sub")) === nothing
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", uuid = Base.UUID(0))) === nothing
        # A VersionNumber is `== 1.2.3`, while the string "1.2.3" is a semver
        # range: the two do not mean the same thing, so this delegates.
        @test Ajt._spec_arg(Pkg.PackageSpec(name = "Foo", version = v"1.2.3")) === nothing

        @test Ajt._spec_args(Pkg.PackageSpec[Pkg.PackageSpec("A"), Pkg.PackageSpec("B")]) == ["A", "B"]
        @test Ajt._spec_args(Pkg.PackageSpec[Pkg.PackageSpec("A"), Pkg.PackageSpec(url = "u")]) === nothing

        # A REGISTRY url is native — `ajt registry add --url` clones it, which
        # is what Pkg does when the server cannot serve (`Registry.jl:260-262`).
        # A registry given only by url has no name until it is cloned and its
        # own Registry.toml is read, so none is emitted.
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(url = "u")])) == ["--url", "u"]
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(name = "General", url = "u")])) ==
            ["--url", "u", "General"]
        # ...but `--url` is one option for the whole invocation, exactly like
        # `--uuid`, so more than one cannot be expressed and must delegate
        # rather than clone the same repository under two names.
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(url = "a"), Pkg.RegistrySpec(url = "b")])) === nothing
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(name = "A", url = "a"), Pkg.RegistrySpec("B")])) === nothing
        # A path or `linked` is a source kind the binary has no flag for.
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(path = "/tmp/r")])) === nothing

        # The repository form goes through the EXPLICIT flags, never
        # `<url>#<rev>`: the binary's inline grammar takes everything after the
        # first `#` as the rev, so a url or a branch containing one would be
        # cut in the wrong place.
        @test Ajt._repo_argv(Pkg.PackageSpec(url = "https://x/Foo.jl")) ==
            ["--url", "https://x/Foo.jl"]
        @test Ajt._repo_argv(Pkg.PackageSpec(url = "https://x/Foo.jl", rev = "main")) ==
            ["--url", "https://x/Foo.jl", "--rev", "main"]
        @test Ajt._repo_argv(Pkg.PackageSpec(url = "https://x/M.jl", subdir = "pkgs/Foo")) ==
            ["--url", "https://x/M.jl", "--subdir", "pkgs/Foo"]
        # `add Foo#main` — no url; the binary resolves the source from the
        # manifest and then the registry, as `handle_repo_add!` does.
        @test Ajt._repo_argv(Pkg.PackageSpec(name = "Foo", rev = "main")) ==
            ["--rev", "main", "Foo"]
        # Not a repository spec at all.
        @test Ajt._repo_argv(Pkg.PackageSpec("Foo")) === nothing
        # A version alongside a rev is an error either way (`API.jl:313-320`),
        # and Pkg's message is the one people have seen.
        @test Ajt._repo_argv(Pkg.PackageSpec(name = "Foo", rev = "main", version = "1.2")) === nothing
        # A path is a different arm; a uuid pins an identity the binary learns
        # from the checked-out project file instead.
        @test Ajt._repo_argv(Pkg.PackageSpec(name = "Foo", rev = "main", path = "/tmp/Foo")) === nothing
        @test Ajt._repo_argv(Pkg.PackageSpec(url = "u", uuid = Base.UUID(0))) === nothing

        # The flags describe ONE package.
        @test Ajt._one_repo(Pkg.PackageSpec[Pkg.PackageSpec(url = "u")]) == ["--url", "u"]
        @test Ajt._one_repo(Pkg.PackageSpec[Pkg.PackageSpec(url = "u"), Pkg.PackageSpec("B")]) === nothing

        # Unknown keywords are a delegation reason, never a silent no-op.
        @test Ajt._kwreason(pairs((;))) === nothing
        @test occursin("`target`", something(Ajt._kwreason(pairs((target = :weakdeps,))), ""))

        # Every preserve tier and every upgrade level the enums can hold has a
        # binary spelling — a missing one would be a KeyError at the call site.
        for level in instances(Pkg.Types.PreserveLevel)
            @test haskey(Ajt._PRESERVE, level)
        end
        for level in instances(Pkg.Types.UpgradeLevel)
            @test haskey(Ajt._LEVEL, level)
        end
    end

    @testset "report rendering" begin
        # These renderers are the one place that has to track `main.zig`'s print
        # statements, and they are pure functions over a string — so the field
        # order of every record kind is pinned here, exactly as the binary emits
        # it. A record kind that changes shape upstream fails here rather than
        # printing something subtly wrong to a user.
        render(out) = sprint(io -> Ajt._render_env(io, out); context = :color => false)

        # `{added|removed|already_present}<TAB>name<TAB>uuid` — a [deps] change.
        @test occursin("[7876af07] + Example", render("added\tExample\t7876af07-990d-54b4-ab0e-23690620f79a\n"))
        @test occursin("[7876af07] - Example", render("removed\tExample\t7876af07-990d-54b4-ab0e-23690620f79a\n"))
        # `added<TAB>name<TAB>version` — a solver selection. Same arity, and only
        # the shape of the third field tells them apart.
        @test occursin("+ Example v0.5.5", render("added\tExample\t0.5.5\n"))
        @test occursin("↑ Foo v1.0.0 ⇒ v1.2.0", render("changed\tFoo\t1.0.0\t1.2.0\n"))
        # `julia` is in every solution and in no manifest: reporting it as added
        # would say something changed on a run where nothing did.
        @test !occursin("julia", render("added\tjulia\t1.12.6\n"))
        # `held` is the common case and says nothing.
        @test isempty(render("held\tFoo\t1.0.0\n"))
        @test occursin("(205 entries)", render("manifest\t/tmp/e/Manifest.toml\t205\twritten\n"))
        @test occursin("214 packages, 0 moved, 1 added in 2284 ms (preserve all)", render("summary\t214\t0\t0\t1\t2284\tall\n"))
        @test occursin("not installed", render("no-source\tFoo\n"))

        # Truncated records must not take the process down: the guards are what
        # keep a renderer from turning a short line into a BoundsError.
        for record in ("summary\t1\t2\t3\t4\t5\n", "no-source\n", "manifest\t/tmp/x\n", "changed\tFoo\t1.0.0\n", "added\n")
            @test (render(record); true)
        end

        # instantiate's records: same names, different shapes. `manifest` has
        # its status and path the other way round from the resolve one.
        inst(out) = sprint(io -> Ajt._render_instantiate(io, out); context = :color => false)
        @test occursin("Updating", inst("manifest\twritten\t/tmp/e/Manifest.toml\n"))
        @test isempty(inst("manifest\tunchanged\t/tmp/e/Manifest.toml\n"))
        # The outcome vocabulary is the binary's, and getting it wrong is
        # invisible in the good case: filtering on a value the binary never
        # emits prints one line per package on a warm depot instead of none.
        @test occursin("Installed Example", inst("package\tinstalled\tExample\tuuid\thash\t/p\n"))
        @test isempty(inst("package\talready_present\tExample\tuuid\thash\t/p\n"))
        @test occursin("needs_git_clone", inst("package\tneeds_git_clone\tExample\tuuid\thash\t/p\n"))
        @test occursin("Installed artifact libfoo", inst("artifact\tinstalled\tlibfoo\thash\t/p\n"))
        @test isempty(inst("artifact\talready_present\tlibfoo\thash\t/p\n"))
        @test occursin("205 entries: 3 of 4 packages and 1 of 2 artifacts installed in 900 ms", inst("summary\t205\t9\t4\t3\t2\t1\t900\n"))
        @test occursin("2 problem(s)", inst("verify\tfailed\t2\n"))
        @test isempty(inst("verify\tok\t0\n"))
        # The usage log is what `Pkg.gc()` reads: a failure to record it looks
        # exactly like success until a gc empties the depot.
        @test occursin("could not record", inst("usage\tmanifest_usage.toml\t1\tAccessDenied\n"))
        @test isempty(inst("usage\tmanifest_usage.toml\t1\twritten\n"))
        for record in ("summary\t1\n", "verify\n", "blocked\n", "usage\tx\n")
            @test (inst(record); true)
        end

        # build's records: `build<TAB>ok|failed<TAB>name<TAB>uuid<TAB>log<TAB>ms`.
        # The log PATH is the payload -- it is the file a user opens when a
        # build fails, and the two places it can be (a scratchspace, or the
        # package's own deps/) are the thing this verb is most likely to get
        # wrong -- so it is what gets printed.
        bld(out) = sprint(io -> Ajt._render_build(io, out); context = :color => false)
        @test occursin("Building Zstd_jll", bld("build\tok\tZstd_jll\tuuid\t/d/scratchspaces/p/h/build.log\t120\n"))
        @test occursin("/d/scratchspaces/p/h/build.log", bld("build\tok\tZstd_jll\tuuid\t/d/scratchspaces/p/h/build.log\t120\n"))
        @test occursin("Building Foo", bld("build\tfailed\tFoo\tuuid\t/s/Foo/deps/build.log\t7\n"))
        # An environment where nothing has a deps/build.jl says so; silence
        # would be indistinguishable from a command that did not run.
        @test occursin("nothing to do", bld("project\t/e/Project.toml\nsummary\t4\t0\n"))
        @test !occursin("nothing to do", bld("build\tok\tFoo\tuuid\t/l\t1\nsummary\t4\t1\n"))
        for record in ("build\tok\n", "summary\n", "build\n")
            @test (bld(record); true)
        end

        # test's records: `test<TAB>ok|failed|planned<TAB>name<TAB>uuid<TAB>sandbox<TAB>ms`.
        # The verdict is the payload; a `planned` record is a --dry-run and
        # prints nothing, because no suite ran and "passed" would be a lie.
        tst(out) = sprint(io -> Ajt._render_test(io, out); context = :color => false)
        @test occursin("Testing Foo tests passed", tst("test\tok\tFoo\tuuid\t/tmp/sb\t120\n"))
        @test occursin("Testing Foo tests errored", tst("test\tfailed\tFoo\tuuid\t/tmp/sb\t120\n"))
        @test isempty(tst("test\tplanned\tFoo\tuuid\t/tmp/sb\t0\n"))
        @test isempty(tst("sandbox\tFoo\ttargets\t11\t10\nsummary\t1\t1\n"))
        for record in ("test\tok\n", "test\n", "failure\n")
            @test (tst(record); true)
        end

        # The failure record round-trip: the binary escapes Pkg's multi-line
        # pkgerror text into one record (`escapeMessage`, src/ops/test.zig) and
        # this is the inverse — get it wrong and the PkgError the wrapper
        # raises stops being Pkg's sentence.
        @test Ajt._unescape_record("Packages errored during testing:\\n• Foo") ==
            "Packages errored during testing:\n• Foo"
        @test Ajt._unescape_record("a\\tb\\nc") == "a\tb\nc"
        # An escaped backslash must not re-combine with a following `n`.
        @test Ajt._unescape_record("C:\\\\new") == "C:\\new"
    end

    @testset "keyword and spec gating" begin
        # Every one of these is a case where doing the native thing would be
        # WRONG rather than merely incomplete, so each has to reach Pkg. Without
        # this testset, `DIFFERENCES` is a list of promises nothing checks.
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            previous = Base.active_project()
            try
                Base.set_active_project(joinpath(dir, "Project.toml"))
                @test delegates(() -> Ajt.rm("Foo"; all_pkgs = true))
                @test delegates(() -> Ajt.rm("Foo"; mode = Pkg.PKGMODE_MANIFEST))
                # test's own gates: a sandbox closure, a version-forcing solve
                # and a non-Bool/String coverage are all things only Pkg's
                # in-process sandbox can honour.
                @test delegates(() -> Ajt.test("Foo"; test_fn = () -> nothing))
                @test delegates(() -> Ajt.test("Foo"; force_latest_compatible_version = true))
                @test delegates(() -> Ajt.test("Foo"; coverage = 3))
                # A [workspace] project can take Pkg's workspace fast path.
                write(joinpath(dir, "Project.toml"), "[workspace]\nprojects = [\"member\"]\n")
                @test delegates(() -> Ajt.test("Foo"))
                write(joinpath(dir, "Project.toml"), "")
                @test delegates(() -> Ajt.update("Foo"; preserve = Pkg.PRESERVE_ALL))
                @test delegates(() -> Ajt.instantiate(; workspace = true))
                @test delegates(() -> Ajt.why("Foo"; workspace = true))
                @test delegates(() -> Ajt.add("Foo"; target = :weakdeps))
                # A url on its own is NATIVE now (the binary clones it). What
                # still has to delegate is a url alongside another package:
                # `--url/--rev/--subdir` describe one package, and splitting
                # the call into two invocations would resolve twice.
                @test delegates(
                    () -> Ajt.add(
                        [
                            Pkg.PackageSpec(url = "https://example.invalid/Foo.jl"),
                            Pkg.PackageSpec(name = "Bar"),
                        ]
                    )
                )
                # A local git repository given as a PATH: Pkg's own arm for it
                # (`.git` probe, dirty warning, manifest-relative repo-url) is
                # not implemented, so this must reach Pkg rather than be
                # mistaken for a url.
                @test delegates(() -> Ajt.add(path = "/tmp/ajt-not-a-repo"))
                @test delegates(() -> Ajt.add(name = "Foo", version = v"1.2.3"))
                # `develop` has no rev grammar — Pkg raises "rev argument not
                # supported by `develop`" (`API.jl:260-262`) — so this has to
                # reach Pkg and say so, not clone the default branch.
                @test delegates(() -> Ajt.develop(url = "https://example.invalid/Foo.jl", rev = "main"))
                # `develop` by NAME is the manifest/registry lookup arm, which
                # the binary does not implement.
                @test delegates(() -> Ajt.develop(name = "Foo"))
                # A version on `rm`/`why` is a grammar the binary does not have;
                # forwarding it would produce the wrong error, not the wrong file.
                @test delegates(() -> Ajt.rm(name = "Foo", version = "1.2"))
                @test delegates(() -> Ajt.why(name = "Foo", version = "1.2"))
                # `status`'s refusals. Each changes WHICH packages the report is
                # about, so ignoring one would answer a different question in
                # the same format — and the last is a spec `status` does not
                # filter on at all.
                @test delegates(() -> Ajt.status(; diff = true, io = devnull))
                @test delegates(() -> Ajt.status(; workspace = true, io = devnull))
                @test delegates(() -> Ajt.status(; mode = Pkg.Types.PKGMODE_COMBINED, io = devnull))
                @test delegates(() -> Ajt.status(url = "https://example.invalid/Foo.jl", io = devnull))
                # Registry specs the binary cannot express. A url is NOT one of
                # them any more — `--url` clones it — so what is left is the
                # source kinds with no flag and the shapes a single option
                # cannot carry; `_args` pins those in "spec translation" above,
                # without a network round trip.
                @test delegates(() -> Ajt.Registry.add(path = "/tmp/registry"))
                @test delegates(() -> Ajt.Registry.add(RegistrySpec[Pkg.RegistrySpec(name = "A", uuid = Base.UUID(1)), Pkg.RegistrySpec(name = "B", uuid = Base.UUID(2))]))
            finally
                Base.set_active_project(previous)
            end
        end

        # A project with no manifest at all: "instantiate" then means resolve
        # first, which `--frozen` cannot do. This needs a directory nothing else
        # has touched — the delegating calls above go to Pkg, and Pkg writes a
        # Manifest.toml, which is exactly the file whose absence is under test.
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "")
            previous = Base.active_project()
            try
                Base.set_active_project(joinpath(dir, "Project.toml"))
                @test !isfile(joinpath(dir, "Manifest.toml"))
                @test delegates(() -> Ajt.instantiate(io = devnull))
            finally
                Base.set_active_project(previous)
            end
        end

        # Pkg's documented keyword forms (`Registry/Registry.jl:46-51`) have to
        # exist. Without them `Registry.add(name = "General")` lands in
        # `kwargs`, and the delegation target is the one Pkg entry point with no
        # `kwargs...` — a MethodError from a package advertising itself as a
        # drop-in. Checked by dispatch rather than by calling, because the
        # native path for a name is a network fetch.
        for f in (Ajt.Registry.add, Ajt.Registry.update),
                kw in (:name, :uuid, :url, :path, :linked)
            @test hasmethod(f, Tuple{}, (kw,))
        end

        # The source-kind scan: it decides whether a resolve can run natively at
        # all, so both answers have to be exercised. A false negative fails a
        # solvable environment; a false positive is a silent fallback to Pkg.
        mktempdir() do dir
            entry(extra) = """
            julia_version = "1.12.6"
            manifest_format = "2.0"
            project_hash = "0"^40

            [[deps.Foo]]
            uuid = "00000000-0000-0000-0000-0000000000aa"
            version = "1.0.0"
            $extra
            """
            write(joinpath(dir, "Project.toml"), "[deps]\nFoo = \"00000000-0000-0000-0000-0000000000aa\"\n")
            write(joinpath(dir, "Manifest.toml"), entry(""))
            @test Ajt._source_reason(dir) === nothing
            # A `develop`ed dependency: the one kind the solver cannot do.
            write(joinpath(dir, "Manifest.toml"), entry("path = \"/tmp/Foo\""))
            @test occursin("develop", something(Ajt._source_reason(dir), ""))
            # `path = "."` is the project's own entry — present in EVERY package
            # manifest, and handled. Catching it would send every package
            # environment in existence to Pkg.
            write(joinpath(dir, "Manifest.toml"), entry("path = \".\""))
            @test Ajt._source_reason(dir) === nothing
            # Pinned and repo-tracked entries resolve and survive `--write`
            # byte-intact, so they must NOT be gated: over-delegating here would
            # trade the whole speed win away for nothing.
            write(joinpath(dir, "Manifest.toml"), entry("pinned = true"))
            @test Ajt._source_reason(dir) === nothing
            write(joinpath(dir, "Manifest.toml"), entry("repo-url = \"https://example.invalid/Foo.jl\""))
            @test Ajt._source_reason(dir) === nothing
            write(joinpath(dir, "Manifest.toml"), entry(""))
            write(joinpath(dir, "Project.toml"), "[deps]\n\n[sources]\nFoo = {path = \"/tmp/Foo\"}\n")
            @test occursin("[sources]", something(Ajt._source_reason(dir), ""))
            # ...and the `[sources.Name]` spelling of the identical thing, which
            # `write_project` never emits but a human editing the file does.
            write(joinpath(dir, "Project.toml"), "[deps]\n\n[sources.Foo]\npath = \"/tmp/Foo\"\n")
            @test occursin("[sources]", something(Ajt._source_reason(dir), ""))
            # A `[sources]` URL is native — cloned, materialised and written
            # byte-identically to Pkg — so it must NOT be delegated. Both the
            # shapes below have to stay native, including the one where a
            # `subdir` sits next to the url and looks path-ish.
            write(joinpath(dir, "Project.toml"), "[deps]\n\n[sources]\nFoo = {url = \"https://example.invalid/Foo.jl\", rev = \"main\"}\n")
            @test Ajt._source_reason(dir) === nothing
            write(joinpath(dir, "Project.toml"), "[deps]\n\n[sources]\nFoo = {url = \"https://example.invalid/Foo.jl\", subdir = \"lib/Foo\"}\n")
            @test Ajt._source_reason(dir) === nothing
            # A `path` key OUTSIDE the section is not a [sources] path: the
            # section ends at the next header.
            write(joinpath(dir, "Project.toml"), "[sources]\nFoo = {url = \"https://example.invalid/Foo.jl\"}\n\n[extras]\npath = \"x\"\n")
            @test Ajt._source_reason(dir) === nothing
        end

        # `linked` is a fifth RegistrySpec field, and ignoring it would install a
        # copied registry where the caller asked for a symlinked one.
        args, reason = Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(name = "General", linked = true)])
        @test args === nothing
        @test occursin("linked", reason)
        # A single uuid is expressible; two are not, because `--uuid` is one
        # option the binary applies to every name it was given.
        args, _ = Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(name = "General", uuid = Base.UUID(1))])
        @test args == ["--uuid", string(Base.UUID(1)), "General"]
        @test first(Ajt.Registry._args(RegistrySpec[Pkg.RegistrySpec(name = "General")])) == ["General"]
    end

    @testset "REPL mode routing" begin
        Pkg.REPLMode.TEST_MODE[] = true
        try
            route(str) = only(Ajt.REPLMode.pkgstr(str))[1]

            # Covered commands land on Ajt...
            @test route("add Foo") === Ajt.add
            @test route("rm Foo") === Ajt.rm
            @test route("up") === Ajt.update
            @test route("st") === Ajt.status
            @test route("status") === Ajt.status
            @test route("resolve") === Ajt.resolve
            @test route("instantiate") === Ajt.instantiate
            @test route("why Foo") === Ajt.why
            @test route("gc") === Ajt.gc
            @test route("registry add General") === Ajt.Registry.add
            @test route("registry update") === Ajt.Registry.update
            @test route("registry st") === Ajt.Registry.status
            @test route("registry rm General") === Ajt.Registry.rm
            @test route("build") === Ajt.build
            @test route("test") === Ajt.test
            @test route("test Foo") === Ajt.test

            # ... and everything else falls through to Pkg rather than erroring.
            @test route("pin Foo") === Pkg.API.pin
            @test route("free Foo") === Pkg.API.free
            @test route("develop Foo") === Pkg.API.develop
            @test route("precompile") === Pkg.API.precompile
            @test route("undo") === Pkg.API.undo

            # Pkg's parser is doing the parsing, so the options arrive parsed.
            api, args, opts = only(Ajt.REPLMode.pkgstr("up --minor"))
            @test api === Ajt.update
            @test opts[:level] == Pkg.UPLEVEL_MINOR

            api, args, opts = only(Ajt.REPLMode.pkgstr("add Foo@1.2"))
            @test api === Ajt.add
            @test only(args).name == "Foo"
            @test only(args).version == "1.2"

            # Aliases, multiple commands on one line, and `?`-help all keep
            # working because none of that is reimplemented here.
            @test length(Ajt.REPLMode.pkgstr("add Foo; rm Bar")) == 2

            # The macros are the same entry point.
            @test only(Ajt.@pkg_str("add Foo"))[1] === Ajt.add
            @test only(Ajt.@ajt_str("add Foo"))[1] === Ajt.add
        finally
            Pkg.REPLMode.TEST_MODE[] = false
        end

        # Every command Pkg's REPL declares has to reach *something*: a handler
        # here, or Pkg's own. A spec whose api is neither would be a command
        # that parses and then does nothing.
        for (_, specs) in Pkg.REPLMode.SPECS, spec in values(specs)
            @test haskey(Ajt.REPLMode.DISPATCH, spec.api) || spec.api isa Function
        end

        # No REPL in a test process, and that must not be an error: `using Ajt`
        # from a script has to be a no-op, not a failure.
        @test !isdefined(Base, :active_repl)
        @test (@test_logs (:warn,) match_mode = :any Ajt.REPLMode.activate!()) === false
        @test Ajt.REPLMode.deactivate!() === false
    end

    @testset "REPL mode take-over" begin
        # The take-over itself — `]` becoming `ajt>` — used to be untested by
        # construction: the only thing reachable from a test process was
        # `activate!()` with no REPL, which is the path that returns `false`.
        # A `LineEditREPL` over in-memory streams is a real REPL object, and
        # `setup_interface` builds it the same modes a terminal session gets,
        # so every step from `_replext` to the prompt string can be asserted
        # without a terminal.
        term = REPL.Terminals.TTYTerminal("dumb", IOBuffer(), IOBuffer(), IOBuffer())
        repl = REPL.LineEditREPL(term, false)
        repl.history_file = false        # nothing here may touch ~/.julia/logs
        repl.interface = REPL.setup_interface(repl)

        ext = Ajt.REPLMode._replext(repl)
        @test ext isa Module

        # `setup_interface` builds REPL's placeholder `]` mode, not Pkg's, so
        # this also covers the branch that calls `repl_init` itself.
        @test Ajt.REPLMode.activate!(repl) === true
        modes = Ajt.REPLMode._pkg_modes(repl, ext)
        @test !isempty(modes)
        @test all(m -> endswith(m.prompt(), "ajt> "), modes)

        # Idempotent: a second call must not double-save the originals, or
        # `deactivate!` would restore a prompt that is already ours.
        @test Ajt.REPLMode.activate!(repl) === true
        @test length(Ajt.REPLMode._PATCHED) == length(modes)

        @test Ajt.REPLMode.deactivate!() === true
        @test all(m -> endswith(m.prompt(), "pkg> "), modes)
        @test Ajt.REPLMode.deactivate!() === false
    end

    @testset "REPL mode take-over over a pty" begin
        # The gate for the regression this feature actually had, driven the
        # way a person drives it: a real `julia -i` on a real terminal, `]`
        # pressed *before* `using Ajt`, then `]` again.
        #
        # That ordering is the one that broke, and nothing cheaper reproduces
        # it. `Base.get_extension(Pkg, :REPLExt)` answers `nothing` for a
        # REPLExt that is loaded and running whenever it was loaded through
        # `REPL.load_pkg()` — which is what the first `]` does — so
        # `_replext`, which used to ask only `get_extension`, reported that
        # there was no `pkg>` mode to take over. `autoactivate!` had asked for
        # that quietly, so `]` stayed on `pkg>` and nothing was printed.
        #
        # Every layer below this passes with that defect in place: the routing
        # tests never touch a prompt, and the in-process testset above builds
        # its REPL in a session where `get_extension` happens to work. A gate
        # that cannot fail is not worth having, and this one fails: against
        # the unfixed `_replext` it stops at `ajt> ` and reports `pkg> `.
        if !Sys.isunix()
            @info "Ajt: skipping the pty take-over gate (needs a Unix pty)"
        else
            pts, ptm = try
                open_fake_pty()
            catch err
                @info "Ajt: skipping the pty take-over gate" exception = (err, Any[])
                nothing, nothing
            end
            if ptm !== nothing
                # Two short lines rather than one long one. A REPL redraws the
                # whole line on every keystroke, so a 130-character command is
                # ~17 kB of terminal traffic where these are ~1 kB — and under
                # the load of a full test run that difference was the
                # difference between this gate passing and the child dying.
                #
                # `__init__` hands the take-over to a task that runs at the
                # first yield, so the sleep is not a guess about timing: it is
                # a yield, with two seconds of slack on top.
                ready = "AJT" * "-READY"     # split so the echoed input cannot match
                load = "using Ajt\n"
                settle = "sleep(2); println(\"AJT\" * \"-READY\")\n"
                # A plain `julia`, deliberately not `Base.julia_cmd()`.
                #
                # `julia_cmd()` reproduces *this* process's flags, and under
                # `Pkg.test` those include `--check-bounds=yes` — which the
                # sysimage was not built with, so the child re-infers REPL and
                # Pkg internals on the way to its first prompt. That turned a
                # 25-second gate into a two-minute one that failed about half
                # the time. It is also the wrong thing to model: what is being
                # tested is the REPL a person gets, and a person's REPL has
                # default flags.
                julia = joinpath(Sys.BINDIR, Base.julia_exename())
                project = Base.active_project()

                # Precompile in a child of our own first, with the same flags,
                # so the very first `using Ajt` inside the pty is not paying
                # for a cold cache while the clock below is running — which is
                # exactly how a gate becomes flaky on cold CI.
                #
                # Deliberately *only* Ajt. Warming `REPL.load_pkg()` here as
                # well makes this gate pass far more often, and that is exactly
                # why it is not done: see the note on `UPSTREAM_CRASH` below.
                run(pipeline(
                    `$julia --startup-file=no --history-file=no --project=$project -e "using Ajt"`,
                    stdout = devnull, stderr = devnull,
                ))

                cmd = `$julia --startup-file=no --history-file=no --banner=no --project=$project -i`
                proc = run(detach(cmd), pts, pts, pts; wait = false)
                Base.close_stdio(pts)

                seen, cursor = Ref(""), Ref(1)
                reader = @async try
                    while !eof(ptm)
                        seen[] *= String(readavailable(ptm))
                    end
                catch
                end

                # Search forward only, so a second `pkg> ` is not satisfied by
                # the first one still sitting in the transcript.
                #
                # Thirty seconds is generous by two orders of magnitude — every
                # step here takes milliseconds once the caches are warm, and
                # the whole gate runs in about ten seconds. It is a deadlock
                # detector, not a budget.
                function expect(pattern; timeout = 30)
                    deadline = time() + timeout
                    while time() < deadline
                        plain = replace(seen[], r"\e\[[0-9;?]*[a-zA-Z]" => "")
                        hit = findnext(pattern, plain, min(cursor[], lastindex(plain) + 1))
                        hit === nothing || (cursor[] = last(hit) + 1; return true)
                        sleep(0.05)
                        process_running(proc) || break   # the child died; stop waiting on it
                    end
                    # A pty test that fails without showing what the terminal
                    # actually said is a test nobody can act on.
                    @info "Ajt: pty gate gave up waiting for $(repr(pattern))" alive =
                        process_running(proc) transcript =
                        last(replace(seen[], r"\e\[[0-9;?]*[a-zA-Z]" => ""), 2000)
                    return false
                end

                try
                    # Stop at the first failure. Every later step waits on
                    # output the dead step was supposed to produce, so carrying
                    # on turns one timeout into five and buries the real one at
                    # the top of a very long log.
                    for (input, pattern, budget) in [
                            (nothing, "julia> ", 30),
                            ("]", "pkg> ", 30),   # Pkg's own: Ajt is not loaded yet
                            ("\x7f", "julia> ", 30),
                            # Both lines at once: the pty buffers the second
                            # until the REPL is ready for it. Waiting for a
                            # `julia> ` in between looks tidier and is not
                            # sound — the prompt is echoed back as the line is
                            # typed, so that wait matches before `using Ajt`
                            # has even started.
                            #
                            # This is the one step that can legitimately take
                            # real time: it contains a `using Ajt` in a fresh
                            # process. Hence the budget, which is still a
                            # deadlock detector rather than an expectation.
                            (load * settle, ready, 180),
                            ("]", "ajt> ", 30),   # the regression
                        ]
                        input === nothing || write(ptm, input)
                        ok = expect(pattern; timeout = budget)
                        # A crash in Julia's own loader is not an Ajt failure —
                        # and it is not this suite's business to hide one
                        # either, so it fails, loudly and by name.
                        if !ok && crashed_in_julias_loader(seen[])
                            @error UPSTREAM_CRASH
                        end
                        @test ok
                        ok || break
                    end
                finally
                    try
                        write(ptm, "\x7f")
                        write(ptm, "exit()\n")
                        wait(Timer(1))
                    catch
                    end
                    kill(proc)
                    close(ptm)
                end
            end
        end
    end

    @testset "delegation" begin
        # Delegating functions exist, forward, and say so exactly once.
        @test Ajt.DELEGATION_NOTICE[] === true
        Ajt.DELEGATION_NOTICE[] = false
        try
            mktempdir() do dir
                write(joinpath(dir, "Project.toml"), "name = \"Scratch\"\nuuid = \"8daf5b98-8bce-4cd0-9d16-e8a1f0e1ab77\"\n")
                previous = Base.active_project()
                try
                    # `activate` is delegated, and has to actually do the thing.
                    Ajt.activate(dir; io = devnull)
                    @test Base.active_project() == joinpath(dir, "Project.toml")
                    @test Ajt.project().name == "Scratch"
                    @test Ajt.dependencies() isa Dict
                finally
                    Base.set_active_project(previous)
                end
            end
        finally
            Ajt.DELEGATION_NOTICE[] = true
        end
    end

    @testset "offline" begin
        # One cell, not two. A mirrored `Ref` would pass every assertion below
        # except this one, and would then silently disagree with Pkg the first
        # time anybody called `Pkg.offline` directly.
        @test Ajt.OFFLINE_MODE === Pkg.OFFLINE_MODE

        # The sticky global moves, and goes back the way it was — the tests
        # below this one run for real.
        was = Ajt.OFFLINE_MODE[]
        try
            Ajt.offline(true)
            @test Ajt.OFFLINE_MODE[] === true
            Ajt.offline(false)
            @test Ajt.OFFLINE_MODE[] === false
            # The default argument is Pkg's: `offline()` means `offline(true)`.
            Ajt.offline()
            @test Ajt.OFFLINE_MODE[] === true
            # ...and the delegating verbs see it, because it is Pkg's own Ref.
            @test Pkg.OFFLINE_MODE[] === true
        finally
            Ajt.OFFLINE_MODE[] = was
        end

        # It is native now, so it must be out of DELEGATED and in NATIVE —
        # `conformance` above only checks that it is in exactly one bucket, not
        # which.
        @test :offline in Ajt.NATIVE
        @test !haskey(Ajt.DELEGATED, :offline)
        @test haskey(Ajt.DIFFERENCES, :offline)
    end

    if BINARY === nothing || isempty(TEST_ENV)
        @info "Ajt: skipping behavioural tests (binary: $(BINARY === nothing ? "missing" : "ok"), AJT_TEST_ENV: $(isempty(TEST_ENV) ? "unset" : TEST_ENV))"
    else
        project = joinpath(TEST_ENV, "Project.toml")
        manifest = joinpath(TEST_ENV, "Manifest.toml")

        @testset "why is byte-identical to Pkg's" begin
            # The one place a parity claim can be checked exactly: Pkg's `why`
            # writes plain bytes to a non-terminal sink (`API.jl:1600-1610`),
            # and so does the binary.
            name = first(sort!(collect(keys(Pkg.Types.read_project(project).deps))))
            ajt_out, pkg_out = envcopy(project, manifest) do dir
                a = withenv_project(dir) do
                    sprint(io -> Ajt.why(name; io))
                end
                b = envcopy(project, manifest) do dir2
                    withenv_project(dir2) do
                        sprint(io -> Pkg.why(name; io))
                    end
                end
                (a, b)
            end
            @test !isempty(ajt_out)
            @test ajt_out == pkg_out
        end

        # The headline parity claim, and the reason `AJT_TEST_ENV` exists: point
        # it at a registry-only environment and this compares the two manifests
        # byte for byte. It is skipped — loudly — on an environment the native
        # path would decline anyway, e.g. the sandbox `Pkg.test` builds, whose
        # `develop`ed entry sends `resolve` to Pkg and would make this compare
        # Pkg against Pkg.
        source_reason = Ajt._source_reason(TEST_ENV)
        if source_reason !== nothing
            @info "Ajt: skipping the resolve-parity gate — $source_reason. Set AJT_TEST_ENV to a registry-only environment to run it."
        else
            @testset "resolve writes Pkg's manifest" begin
                ajt_bytes = envcopy(project, manifest) do dir
                    withenv_project(dir) do
                        Ajt.resolve(io = devnull)
                    end
                    read(joinpath(dir, "Manifest.toml"))
                end
                pkg_bytes = envcopy(project, manifest) do dir
                    withenv_project(dir) do
                        Pkg.resolve(io = devnull)
                    end
                    read(joinpath(dir, "Manifest.toml"))
                end
                @test ajt_bytes == pkg_bytes
            end
        end

        @testset "unsupported source kinds delegate" begin
            # A `develop`ed dependency is a manifest entry with a path and no
            # registered version; the solver has no candidate for it and reports
            # the environment as unsatisfiable, which is false. Delegating is
            # the only answer that is not a lie.
            envcopy(project, manifest) do dir
                open(joinpath(dir, "Manifest.toml"), "a") do f
                    print(
                        f, """

                        [[deps.DevedXYZ]]
                        deps = []
                        path = "/tmp/DevedXYZ"
                        uuid = "00000000-0000-0000-0000-0000000000fe"
                        version = "1.0.0"
                        """
                    )
                end
                @test Ajt._source_reason(dir) !== nothing
                withenv_project(dir) do
                    @test delegates(() -> Ajt.resolve(io = devnull))
                end
            end
        end

        @testset "status and the read-only paths" begin
            envcopy(project, manifest) do dir
                withenv_project(dir) do
                    # Delegated, but it has to run and print something.
                    @test occursin("Project", sprint(io -> Ajt.status(io = io)))
                    # The hash Pkg wrote into this very manifest is the hash the
                    # binary computes — the strongest form this test can take.
                    recorded = Pkg.TOML.parsefile(joinpath(dir, "Manifest.toml"))["project_hash"]
                    @test Ajt.project_hash() == recorded
                    # An environment Pkg is running out of is installed, so the
                    # answer is a specific `true`, not "a Bool".
                    @test Ajt.verify(io = devnull)
                    # ... and a manifest naming something that was never
                    # installed is a specific `false`, not an exception and not
                    # a `true` from a run that fell over.
                    manifest = joinpath(dir, "Manifest.toml")
                    text = read(manifest, String)
                    write(
                        manifest, text * """

                        [[deps.NotInstalledXYZ]]
                        deps = []
                        git-tree-sha1 = "0000000000000000000000000000000000000000"
                        uuid = "00000000-0000-0000-0000-0000000000ff"
                        version = "1.0.0"
                        """
                    )
                    @test !Ajt.verify(io = devnull)
                    write(manifest, text)
                end
            end
        end

        @testset "tree_hash" begin
            mktempdir() do dir
                write(joinpath(dir, "a.txt"), "hello\n")
                mkpath(joinpath(dir, "sub"))
                write(joinpath(dir, "sub", "b.bin"), UInt8[0x00, 0xff, 0x10])
                # Julia is the oracle: `Pkg.GitTools.tree_hash` is the function
                # that produced every `git-tree-sha1` in every manifest on this
                # machine. Asserting shape instead ("40 hex chars") would pass
                # for an implementation that returned a constant.
                @test Ajt.tree_hash(dir) == bytes2hex(Pkg.GitTools.tree_hash(dir))
                # ... and a changed byte has to change the answer.
                before = Ajt.tree_hash(dir)
                write(joinpath(dir, "a.txt"), "hello!\n")
                @test Ajt.tree_hash(dir) != before
            end
        end
    end
end
