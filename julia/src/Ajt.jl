"""
    Ajt

A drop-in replacement for `Pkg`, backed by the `ajt` binary.

Every function `Pkg` makes public exists here from day one. Each one is either

* **native** — it shells out to the `ajt` binary, which does the work in Zig, or
* **delegating** — it forwards to `Pkg` and says so, once, on stderr.

That is the whole design. Parity is a *ratchet*, not a gate: a name that is not
implemented yet is still callable and still correct, it is merely slower and
carries a notice. [`conformance`](@ref) enumerates `names(Pkg)` and reports
anything that falls in neither bucket, so the gap is always visible, always
enumerable, and only ever shrinks. A test asserts the report is empty, which
means adding a function to `Pkg` breaks this package's test suite rather than
silently leaving a hole in it.

The split is decided by one rule, and it is worth stating because it is not
"whatever the binary happens to implement":

> A function is native when the thing it *produces* is the same as Pkg's. For
> `add`/`rm`/`up`/`resolve`/`instantiate` the product is the state on disk —
> `Project.toml`, `Manifest.toml`, the depot — and Ajt writes those byte for
> byte the way Pkg does. For `status` and `why` the product IS the printed
> report, so the binary reproduces the bytes Pkg writes to a non-terminal `io`,
> and a differential gate `cmp`s the two. `precompile` delegates by the same
> rule read the other way: its product is the loader's cache, and only a
> running Julia can write one.

Known behavioural differences of the *native* paths are listed in
[`DIFFERENCES`](@ref) and printed by [`parity`](@ref). They are differences, not
bugs to be discovered at a call site.

# Finding the binary

In order: `ENV["AJT_BINARY"]`, a sibling `../zig-out/bin/ajt` (a source
checkout), then `ajt` on `PATH`. If none exists the error names every path that
was tried.
"""
module Ajt

# `gc(; collect_delay::Period = Day(7))` is Pkg's signature, and reproducing it
# means being able to spell the default.
import Dates
import Pkg

# The types and enums are Pkg's own objects, deliberately: a `PackageSpec` built
# by Pkg code must be usable here and vice versa, and re-exporting the identical
# binding is the only way `using Pkg, Ajt` does not produce an ambiguity (Julia
# only complains when two exported names resolve to *different* bindings).
using Pkg: PackageSpec, PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT,
    UpgradeLevel, UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH,
    PreserveLevel, PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED,
    PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER,
    PRESERVE_NONE, RegistrySpec

# `Pkg.jl:13-18`, name for name. `Registry` and `@pkg_str` are ours (a submodule
# and a macro that routes through this package), so `using Pkg, Ajt` will report
# those two as ambiguous — which is correct, they are genuinely two different
# things. `using Ajt` alone, the intended use, is unambiguous.
export @pkg_str, @ajt_str
export PackageSpec
export PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT
export UpgradeLevel, UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH
export PreserveLevel, PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED,
    PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER,
    PRESERVE_NONE
export Registry, RegistrySpec, Apps

# `public` is 1.11 syntax, and on anything older the same line is a *parse*
# error, which no `@static if` can help with — the file is parsed before any of
# it runs. The `[compat]` floor is 1.12 (below it `Pkg.Apps` does not exist), so
# this guard is belt and braces for a direct `include` on an older Julia, where
# a missing `public` declaration is a far better failure than a syntax error.
if VERSION >= v"1.11"
    Core.eval(
        @__MODULE__, Meta.parse(
            """
            public activate, add, build, compat, develop, free, gc, generate, instantiate,
                pin, precompile, redo, rm, resolve, status, test, undo, update, why
            """
        )
    )
end

# `Apps` is defined at the bottom of this file, next to `Registry` — both are
# submodules that route through the binary, and both need `_run` to exist first.

#############
#  Offline  #
#############

"""
    OFFLINE_MODE :: Ref{Bool}

`Pkg.OFFLINE_MODE` (`Pkg/src/Pkg.jl:45`) — the identical `Ref`, not a copy of
its value.

Two readers, one cell. Pkg reads it in the code paths Ajt *delegates*;
[`_run`](@ref) reads it to decide whether the binary gets `--offline`. Aliasing
rather than mirroring is what makes those two answers unable to disagree —
`Pkg.offline(true)` before `using Ajt`, or after it, or `Ajt.offline(true)`,
all leave the whole surface in one state. A shadow `Ref` seeded in `__init__`
would in particular have *reverted* a `Pkg.offline(true)` issued before this
module loaded.

Pkg's own `__init__` already seeds it from `JULIA_PKG_OFFLINE` (`Pkg.jl:827`),
so there is nothing to read here either.
"""
const OFFLINE_MODE = Pkg.OFFLINE_MODE

"""
    Ajt.offline(b::Bool = true)

Enable (`b = true`) or disable (`b = false`) offline mode, for this package and
for `Pkg`.

Two things change, and they are not the same kind of thing:

* **The resolver only considers versions already unpacked in the depot.** This
  is the substantive half — `installed_only = installed_only || OFFLINE_MODE[]`
  (`Operations.jl:500`), applied to the candidate list itself (`:702-708`).
  Without it an offline resolve would write a manifest naming versions the
  machine has no copy of and no way to fetch. It applies at *every* preserve
  tier, so it composes with `preserve = PRESERVE_ALL_INSTALLED` rather than
  duplicating it: the tier is a preference about what to hold, this is a
  constraint about what exists.
* **No registry update.** `update_registries` opens with
  `OFFLINE_MODE[] && return` (`Operations.jl:1629`), so the installed registry
  is read but never refreshed, and a missing one is still not an error.

To work in offline mode across Julia sessions set `JULIA_PKG_OFFLINE` to
`"true"` before starting Julia, exactly as with `Pkg`.
"""
function offline(b::Bool = true)
    # `Pkg.offline` IS `OFFLINE_MODE[] = b` (`Pkg.jl:654`), and that `Ref` is
    # the one this module reads, so this single call covers both the native
    # verbs and the delegating ones (`status`, `precompile`, `gc`, ...). Being
    # offline for some verbs and not others is the single most confusing state
    # this switch could be in, and aliasing makes it unreachable.
    Pkg.offline(b)
    return nothing
end

#############
#  Binary   #
#############

const _BINARY = Ref{Union{Nothing, String}}(nothing)

_exename() = Sys.iswindows() ? "ajt.exe" : "ajt"

"""
Where this package's own `Artifacts.toml` lives, if it has one.

It is generated by the release workflow rather than written by hand — one entry
per platform, each naming the tarball that release published and the tree hash
Pkg verifies it against — so it is absent from a source checkout that has never
been released from, and [`_bundled_binary`](@ref) treats that as "no bundled
binary" rather than as an error.
"""
const _ARTIFACTS_TOML = normpath(joinpath(dirname(@__DIR__), "Artifacts.toml"))

const _BUNDLED = Ref{Union{Nothing, String}}(nothing)
const _BUNDLED_TRIED = Ref(false)

"""
    _bundled_binary(; download = false) -> Union{String,Nothing}

The binary that came with this installation, or `nothing` if this installation
did not come with one.

This is what makes `pkg> add Ajt` produce a working tool. Without it the package
is inert until somebody clones the repository and runs `zig build`, which is a
reasonable thing to ask of a contributor and an unreasonable thing to ask of
somebody who typed one command.

`download` is the difference between asking and fetching, and it is the reason
this takes an argument at all. [`binary_candidates`](@ref) is a question — where
*would* you look — and answering a question must not open a socket, or listing
the candidates for an error message would hang a machine that is merely offline.
Only [`binary`](@ref), having found nothing anywhere else, downloads.

Everything degrades to `nothing`: no `Artifacts.toml` (a source checkout), no
entry for this platform, or a failed download. The caller goes on to the next
candidate and, if there is none, produces the message naming every path it
tried — a far better failure than an exception thrown from inside a lookup.

Swapping this for a JLL is a change to this one function: `Ajt_jll.ajt_path`
returns the same thing, and everything downstream stays as it is.
"""
function _bundled_binary(; download::Bool = false)
    # Cached once it has actually resolved, and once a download has been tried
    # and failed: a machine that is offline, or on a platform no release covers,
    # must not retry — and print Pkg's two lines about it — on every lookup.
    _BUNDLED[] === nothing || return _BUNDLED[]
    _BUNDLED_TRIED[] && !download && return nothing
    isfile(_ARTIFACTS_TOML) || return nothing
    return _BUNDLED[] = try
        hash = Pkg.Artifacts.artifact_hash("ajt", _ARTIFACTS_TOML)
        hash === nothing && return nothing
        if !Pkg.Artifacts.artifact_exists(hash)
            download || return nothing
            _BUNDLED_TRIED[] = true
            Pkg.Artifacts.ensure_artifact_installed("ajt", _ARTIFACTS_TOML)
        end
        joinpath(Pkg.Artifacts.artifact_path(hash), "bin", _exename())
    catch err
        @debug "Ajt: no usable bundled binary" exception = (err, catch_backtrace())
        nothing
    end
end

"""
    binary_candidates() -> Vector{String}

Every path [`binary`](@ref) will try, in order. Exposed because "not found" is
only actionable when it says where it looked.

The order encodes who should win an argument. `\$AJT_BINARY` is an explicit
instruction and beats everything. A sibling `zig-out/` is somebody working on
Ajt itself, and their build must beat the one they installed. The bundled
artifact comes next because it is the only candidate guaranteed to be the
version this package was written against — a stray `ajt` on `PATH` may be any
version at all, and this package parses that binary's output.

Listing costs nothing: the artifact appears here only if it is already
installed. Downloading one is [`binary`](@ref)'s last resort, not a side effect
of asking where it would look.
"""
function binary_candidates()
    exe = _exename()
    out = String[]
    fromenv = get(ENV, "AJT_BINARY", "")
    isempty(fromenv) || push!(out, fromenv)
    # `dirname(@__DIR__)` is this package's root; the Zig build tree is its
    # sibling, so a source checkout works with no configuration at all.
    push!(out, normpath(joinpath(dirname(@__DIR__), "..", "zig-out", "bin", exe)))
    bundled = _bundled_binary()
    bundled === nothing || push!(out, bundled)
    onpath = Sys.which(exe)
    onpath === nothing || push!(out, onpath)
    return out
end

"""
    binary(; refresh = false, candidates = binary_candidates()) -> String

Absolute path to the `ajt` executable. Cached after the first successful lookup;
pass `refresh = true` after building or moving it.

Throws with the full candidate list when nothing is found. It does **not** fall
back to `Pkg`: a missing binary is a broken installation, and silently becoming
a slow Pkg shim would hide it for as long as nobody profiled anything.

`candidates` exists so that the not-found message can be tested on a machine
where the binary *is* installed — which is every machine that would be running
the tests, and is why the message would otherwise never be exercised. An
explicit list neither reads nor writes the cache.
"""
function binary(; refresh::Bool = false, candidates::Union{Nothing, Vector{String}} = nothing)
    if refresh
        # A refresh is "look again", and the bundled artifact is one of the
        # places to look: a release published, or a depot restored, since the
        # first attempt would otherwise stay invisible for the session.
        _BUNDLED_TRIED[] = false
        _BUNDLED[] = nothing
    elseif candidates === nothing
        cached = _BINARY[]
        cached === nothing || return cached
    end
    tried = String[]
    for candidate in something(candidates, binary_candidates())
        if isfile(candidate)
            path = abspath(candidate)
            candidates === nothing && (_BINARY[] = path)
            return path
        end
        push!(tried, candidate)
    end
    # Nothing installed anywhere. *Now* it is worth going to the network for the
    # release binary — after every local answer has been ruled out, and never
    # while merely listing candidates. This is the path a fresh `add Ajt` takes.
    if candidates === nothing
        fetched = _bundled_binary(download = true)
        if fetched !== nothing && isfile(fetched)
            return _BINARY[] = abspath(fetched)
        end
        fetched === nothing || push!(tried, fetched)
    end
    exe = _exename()
    msg = IOBuffer()
    println(msg, "Ajt: the `$exe` binary was not found. Tried, in order:")
    if isempty(tried)
        println(msg, "  (nothing — even \$PATH had no entries to search)")
    else
        for path in tried
            println(msg, "  ", path)
        end
    end
    haskey(ENV, "AJT_BINARY") ||
        println(msg, "  \$AJT_BINARY (unset)")
    Sys.which(exe) === nothing &&
        println(msg, "  \$PATH (no `$exe` on it)")
    print(
        msg, """
        Build it with `zig build` from the ajt repository root, or point
        \$AJT_BINARY at an existing one.
        """
    )
    error(String(take!(msg)))
end

"""
    _run(args) -> (stdout::String, exitcode::Int)

Run the binary. stdout is captured (it is a tab-separated report this package
parses); stderr is passed through untouched.

Note that a *failure* is reported on **stdout**, not stderr: the PubGrub
derivation tree, the closing `to fix, try relaxing [compat] on: …` line, and
`ajt add: no registered package by that name` are all written to the same stream
as the records (`main.zig:3147-3157`, `3330-3356`). None of them match a record
kind, so anything that renders and discards the rest would throw away exactly
the output a failed command exists to produce — see [`_failed`](@ref).

The child's `JULIA_DEPOT_PATH` is pinned to this session's `DEPOT_PATH`. Without
that the binary re-derives the depot stack from the environment and would miss a
`pushfirst!(DEPOT_PATH, ...)` done at runtime — the exact configuration a test
harness uses, and the exact one where being wrong is silent.

[`OFFLINE_MODE`](@ref) is passed the same way and for the same reason. It is
process state on THIS side of the fork — `Ajt.offline(true)` sets a `Ref`, not
an environment variable — so a child that only read `JULIA_PKG_OFFLINE` would
be online. `--offline` is a global flag the binary strips before dispatch, so
it is correct here for every subcommand, including the two-word `registry add`.
"""
function _run(args::Vector{String})
    argv = String[binary()]
    OFFLINE_MODE[] && push!(argv, "--offline")
    append!(argv, args)
    cmd = addenv(Cmd(argv), "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'))
    buf = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout = buf, stderr = stderr))
    return String(take!(buf)), proc.exitcode
end

"""
    _run_streamed(args) -> (records::String, exitcode::Int)

Like [`_run`](@ref), but for a verb whose CHILDREN own the terminal: `ajt test`
hands each suite this process's stdout and stderr (`subprocess_handler`,
`Operations.jl:2547-2553`), so capturing the way `_run` does would hold a
ten-minute suite's output until it exited. The binary's report is still needed,
so its stdout is read line by line as it arrives: report records — tab
separated, known first field — are kept, everything else is echoed straight
through. A suite line that happens to look like a record would be swallowed
from the echo, never turned into a wrong verdict; none of the record tags is a
word a suite prints followed by a tab by accident.
"""
function _run_streamed(args::Vector{String})
    argv = String[binary()]
    OFFLINE_MODE[] && push!(argv, "--offline")
    append!(argv, args)
    cmd = addenv(Cmd(argv), "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'))
    proc = open(pipeline(ignorestatus(cmd); stderr = stderr))
    records = IOBuffer()
    for line in eachline(proc)
        f = split(line, '\t'; limit = 2)
        if length(f) == 2 && f[1] in ("project", "manifest", "julia", "test", "sandbox", "summary", "failure")
            println(records, line)
        else
            println(stdout, line)
        end
    end
    wait(proc)
    return String(take!(records)), proc.exitcode
end

"""
Split the binary's report into fields. Every subcommand's stdout is one
tab-separated record per line, which is the contract `ajt help` documents.
"""
_records(out::AbstractString) = [split(line, '\t') for line in eachsplit(chomp(out), '\n') if !isempty(line)]

"""
The inverse of the binary's `escapeMessage` (`src/ops/test.zig`): `\\\\\\\\` →
`\\\\`, `\\\\t` → tab, `\\\\n` → newline. One left-to-right pass with the
backslash pair tried first, so an escaped backslash never re-combines with a
following `n` into a newline that was never there.
"""
_unescape_record(s::AbstractString) = replace(s, "\\\\" => "\\", "\\t" => "\t", "\\n" => "\n")

"""
`--julia-prefix` / `--julia-version` for the *running* Julia.

Both are always passed. The binary's fallback is `julia` on `PATH`, which is a
different Julia than this one often enough to matter (juliaup shims, an absolute
`/nix/store/...` invocation, a `--project` script run by a daemon), and resolving
against the wrong stdlib set produces a manifest that is wrong in a way nothing
downstream can see.
"""
_julia_args() = String["--julia-prefix", dirname(Sys.BINDIR), "--julia-version", string(VERSION)]

#################
#  Environment  #
#################

"""
    _env() -> (dir::Union{Nothing,String}, reason::Union{Nothing,String})

The active environment as a *directory*, which is how every `ajt` subcommand
addresses one (`--project DIR`, or a positional `[env]`, both of which mean
`DIR/Project.toml`).

A `JuliaProject.toml`, or a project file under any other name, therefore cannot
be expressed — so it comes back as a delegation reason rather than as a path
that would quietly send the write to the wrong file.
"""
function _env()
    project = Base.active_project()
    project === nothing && return (nothing, "there is no active project")
    base = basename(project)
    base == "Project.toml" && return (dirname(project), nothing)
    return (
        nothing,
        "the active project file is `$base`, and `ajt` addresses an environment by " *
            "directory, which always means <dir>/Project.toml",
    )
end

"""
    _source_reason(dir) -> Union{Nothing,String}

Does this environment contain a source kind the solver cannot handle?

Exactly one does: a `Pkg.develop`ed dependency, recorded as a manifest entry with
a `path` pointing outside the environment. `ajt resolve` over the environment
`Pkg.test` builds for this very package reports "version solving failed" — the
deved package is not registered, so the encoder has no candidate versions to
offer for a dependency the project requires — and even a deved entry that *is*
registered takes `--write` down. `Pkg.resolve` handles both.

`path = "."` is excluded because it is not a deved dependency: it is the
project's own entry, present in every package manifest, and the binary resolves
and rewrites it correctly.

The other two source kinds are **not** here, and that is a measurement rather
than an oversight — `pinned = true` and `repo-url`/`repo-rev` entries both
resolve and survive `--write` byte-intact, so gating them would trade the whole
speed win for nothing.

A `[sources]` section is gated only when some entry in it carries a `path`, which
is the 1.11+ spelling of the same `develop` above and has the same missing
candidates. A `[sources]` entry carrying a **url** is native: the binary clones
it, materialises it under its depot slug and writes `repo-url`/`repo-rev`/
`repo-subdir`/`git-tree-sha1` byte-identically to Pkg, so delegating it would be
pure loss. Note the `path` test is deliberately naive — it scans the section's
text for a `path` key rather than parsing TOML — because the two spellings
(`Foo = {path = …}` under `[sources]`, and `[sources.Foo]` with `path = …`) are
both legal and both need catching, and over-delegating is the safe direction.

So the resolving commands look before they leap. The alternative — running the
binary and relaying its perfectly accurate derivation tree — tells the user their
environment is unsatisfiable, which is false.
"""
function _source_reason(dir::AbstractString)
    manifest = joinpath(dir, "Manifest.toml")
    if isfile(manifest)
        for m in eachmatch(r"^path = \"(.*)\"[ \t]*$"m, read(manifest, String))
            m.captures[1] == "." && continue
            return "the manifest has a `develop`ed entry (path $(m.captures[1])), which the solver has no candidates for"
        end
    end
    # The 1.11+ project-side spelling of the same thing, and the one case where
    # the manifest may not have been written yet.
    project = joinpath(dir, "Project.toml")
    if isfile(project) && _sources_has_path(read(project, String))
        return "the project has a [sources] entry with a `path`"
    end
    return nothing
end

"""
    _is_workspace(dir) -> Bool

Does this environment's project declare a `[workspace]`? `Pkg.test` on such an
environment can take the workspace fast path — activate a member's `test/`
directory in place instead of building a sandbox (`Operations.jl:2434-2464`) —
and ajt has no workspace support anywhere, so `test` delegates the whole
environment rather than testing a member two different ways. The probe is the
header's text, like `_sources_has_path`: over-delegating is the safe direction.
"""
function _is_workspace(dir::AbstractString)
    project = joinpath(dir, "Project.toml")
    isfile(project) || return false
    for line in eachsplit(read(project, String), '\n')
        s = strip(line)
        (startswith(s, "[workspace]") || startswith(s, "[workspace.")) && return true
    end
    return false
end

"""
    _sources_has_path(project_text) -> Bool

Does the `[sources]` section of this `Project.toml` mention a `path`?

The section runs from `[sources]` (or the first `[sources.Name]`) to the next
table header that is neither, and a `path` may appear either as a key of an
inline table on one of its lines or as a plain key under a `[sources.Name]`
header. Both are scanned for; a url-only section returns `false` and stays
native.
"""
function _sources_has_path(text::AbstractString)
    in_sources = false
    for line in eachsplit(text, '\n')
        s = strip(line)
        if startswith(s, '[')
            in_sources = startswith(s, "[sources]") || startswith(s, "[sources.")
            continue
        end
        in_sources || continue
        occursin(r"(^|[{,\s])path\s*=", s) && return true
    end
    return false
end

################
#  Delegation  #
################

"""
    DELEGATION_NOTICE

Set to `false` to silence the one-line "delegating to Pkg" notices. They are on
by default: a wrapper that silently forwards is a wrapper nobody ever finishes,
because the gap stops being visible.
"""
const DELEGATION_NOTICE = Ref(true)

function _delegating(name::Symbol, reason::AbstractString)
    DELEGATION_NOTICE[] || return nothing
    # `maxlog` keyed per function name: once per session per call site is a
    # notice, once per call is a nag.
    @info "Ajt: `$name` is not native yet ($reason) — delegating to Pkg." maxlog = 1 _id = Symbol("ajt_delegate_", name)
    return nothing
end

"""
    DELEGATED :: Dict{Symbol,String}

Public `Pkg` names that forward to `Pkg`, and why. The reason is printed with the
delegation notice, so it has to read as an explanation rather than an apology.
"""
const DELEGATED = Dict{Symbol, String}(
    :activate => "switching environments is `Base.set_active_project` bookkeeping, not solver work",
    :dependencies => "it returns live `PackageInfo` objects, not a report",
    :depots => "trivial accessor over Base.DEPOT_PATH",
    :depots1 => "trivial accessor over Base.DEPOT_PATH",
    :devdir => "trivial accessor over the depot layout",
    :envdir => "trivial accessor over the depot layout",
    # The binary DOES precompile: `ajt precompile` drives a real julia child
    # per package over a dependency frontier, and `add`/`up`/`pin`/`free`/
    # `instantiate` all run it afterwards the way Pkg does. What is still Pkg's
    # is this entry point's signature and its product: `pkgs` narrows the run to
    # a subset, `strict` turns a per-package failure into a raise, `configs`
    # compiles under several cache-flag sets, and the live terminal display —
    # one progress bar per package, redrawn — IS what `Pkg.precompile()` gives a
    # human. `Ajt.instantiate()` is the native way to fill the cache.
    :precompile => "`ajt precompile` fills the cache, but `pkgs`, `strict`, `timing`, `configs` and the live display are Pkg's",
    :project => "it returns a live `ProjectInfo`, not a report",
    :redo => "the undo/redo stack is Pkg's own snapshot journal in the depot",
    :setprotocol! => "registry protocol state lives inside Pkg's git tooling",
    :undo => "the undo/redo stack is Pkg's own snapshot journal in the depot",
)

for name in sort!(collect(keys(DELEGATED)))
    @eval function $name(args...; kwargs...)
        _delegating($(QuoteNode(name)), DELEGATED[$(QuoteNode(name))])
        return Pkg.$name(args...; kwargs...)
    end
end

"""
    NATIVE :: Vector{Symbol}

Public `Pkg` names the `ajt` binary implements. Everything here is expected to
produce the same on-disk state Pkg produces; where the *printed* output differs,
or where a behaviour is deliberately not reproduced, [`DIFFERENCES`](@ref) says
so.
"""
const NATIVE = Symbol[
   Symbol("@pkg_str"), :Apps, :Registry, :add, :build, :compat, :develop, :free,
    :gc, :generate, :instantiate, :is_manifest_current, :offline, :pin, :resolve,
    :rm, :status, :test, :tree_hash, :up, :update, :upgrade_manifest, :verify,
    :why,
]

"""
    REEXPORTED :: Vector{Symbol}

Names taken from `Pkg` unchanged. These are types and enum values: a wrapper
that defined its own `PackageSpec` would be a fork, not a drop-in — code that
hands Ajt a spec built by Pkg has to keep working.
"""
const REEXPORTED = Symbol[
    :PKGMODE_MANIFEST, :PKGMODE_PROJECT, :PRESERVE_ALL,
    :PRESERVE_ALL_INSTALLED, :PRESERVE_DIRECT, :PRESERVE_NONE, :PRESERVE_SEMVER,
    :PRESERVE_TIERED, :PRESERVE_TIERED_INSTALLED, :PackageMode, :PackageSpec,
    :Pkg, :PreserveLevel, :RegistrySpec, :UPLEVEL_MAJOR, :UPLEVEL_MINOR,
    :UPLEVEL_PATCH, :UpgradeLevel,
]

# The one difference every auto-precompiling verb shares, written once so five
# entries cannot drift apart. Deliberately ABOVE the `DIFFERENCES` docstring: a
# `"""…"""` block binds to the next expression, comments and all, so putting a
# const between the two would silently document this string instead.
#
# `Pkg.should_autoprecompile()` is
#
#     Base.JLOptions().use_compiled_modules == 1 &&
#         Base.get_bool_env("JULIA_PKG_PRECOMPILE_AUTO", true)      # Pkg.jl:65
#
# and only the second half survives the trip to a separate process. `JLOptions`
# describes the RUNNING julia, and the `ajt` binary is not one — asking the
# precompile child would answer for a julia `ajt` itself started with no such
# flag, which is not the question. So it is stated rather than approximated.
const _AUTOPRECOMP_DIFFERENCE = "auto-precompilation honours JULIA_PKG_PRECOMPILE_AUTO but NOT `julia --compiled-modules=no`: " *
    "the second half of `Pkg.should_autoprecompile()` is `Base.JLOptions().use_compiled_modules`, which describes the running " *
    "julia and has no meaning in a separate binary (Pkg.jl:65)"

"""
    DIFFERENCES :: Dict{Symbol,Vector{String}}

Where a *native* function does not behave exactly like `Pkg`'s. Every entry is a
thing a caller could otherwise only find out by being surprised.
"""
const DIFFERENCES = Dict{Symbol, Vector{String}}(
    :add => [
        "registered packages by name (`add Foo`, `add Foo@1.2`) and repositories by url or rev (`add(url=…)`, `add(name=\"Foo\", rev=\"main\")`, with an optional `subdir`); a path, uuid, tree_hash or non-string version delegates",
        "ONE repository spec per call — the binary's `--url/--rev/--subdir` describe a single package, so a batch mixing a repository with other packages delegates",
        "a local git repository given as a path rather than a url delegates: Pkg's `.git` probe, dirty-tree warning and manifest-relative `repo-url` (`Types.jl:947-980`) are not implemented",
        "an `ssh://` or `git@host:path` url is refused rather than delegated — this build has no SSH transport, and `JULIA_PKG_USE_CLI_GIT=1` is the answer Pkg itself documents",
        "an environment holding a `develop`ed dependency delegates — the solver has no candidates for one (pinned and repo-tracked entries are fine)",
        "does not download or update the registry first — run `Ajt.Registry.update()`",
        "installs what it resolved and precompiles it afterwards, but never runs deps/build.jl",
        _AUTOPRECOMP_DIFFERENCE,
    ],
    :Apps => [
        "`develop` from a LOCAL PATH, plus `rm` and `status`, are native; `add` and `update` delegate — both start with a registry version solve and a download, and the binary's `app` verb starts after that",
        "`develop(name=…)`, a url, a rev or a subdir delegates: that is `handle_repo_develop!`, which clones into the depot before any app work begins",
        "the WINDOWS `.bat` shim deliberately differs from Pkg's by one token, and it is a fix. Pkg stores `julia_cmd` pre-quoted (`generate_shim`, Apps.jl:501) and quotes it AGAIN at the call site, producing `\"\"C:\\…\\julia\"\"` — which cmd.exe cannot parse once the path contains a space, so the app does not start at all. JuliaLang/Pkg.jl#4741, still open. Ajt stores it unquoted, so the call site's quotes are the only ones. The generated file names the issue in its header",
        "relative `[sources]` paths in a package's own Project.toml are REBASED when the project is copied into the app environment, rather than copied verbatim: Pkg 1.12.6 leaves them pointing at `<depot>/environments/apps/…`, where they do not exist, and the install dies (JuliaLang/Pkg.jl#4532, #4714 — fixed upstream after 1.12.6 by ff55f14f7, ported here). One that resolves nowhere is dropped with a warning so the dependency falls back to a registry",
        "the app environment's own Project.toml is written in Pkg's `_project_key_order`, where `Apps._resolve` uses a bare `TOML.print` over a Dict — so the KEYS come out in a different order. Julia only ever reads that file, and `AppManifest.toml` and the POSIX shim, which are the files both tools write, are byte-identical",
        "`status` prints an ajt report rather than Pkg's, for the same reason the environment verbs do",
    ],
    :offline => [
        "refuses network requests outright. Pkg's offline mode is advisory at the transport: only `resolve_versions!` and `update_registries` consult OFFLINE_MODE, so `Pkg.instantiate()` with JULIA_PKG_OFFLINE=1 still downloads a missing package's source and still downloads artifacts. Ajt errors instead of going to the internet",
        "`ajt registry add`/`update` refuse offline; `Pkg.Registry.add`/`update` have no offline check and would download",
        "\"already installed\" means the source directory exists; Pkg's `is_package_downloaded` also requires the package's artifacts, so a half-installed JLL is a candidate here and not there",
        "installs what it resolved, but does not auto-build or precompile afterwards — run `Ajt.build()`",
    ],
    :build => [
        "does not instantiate first: an environment with a package missing from the depot stops with `not installed` rather than downloading it silently (`Pkg.build` calls `Pkg.instantiate`)",
        "the sandbox does not re-resolve. Pkg resolves the temp environment and falls back to a full update on a ResolverError; ajt uses the parent manifest's versions verbatim, which is Pkg's success path. A `deps/Project.toml` demanding a version the manifest does not hold therefore surfaces as a load error from the build script rather than as a re-resolve",
        "builds serially, as `build_versions` does; the ordering is the same",
        "prints an ajt report rather than Pkg's progress bar. The build.log paths, their contents, the build order and the scratch_usage.toml entry are identical (`tools/diff_harness/build.sh`)",
    ],
    :test => [
        "does not instantiate first: a package missing from the depot reaches the `test/runtests.jl` probe and is reported as not providing one, rather than being downloaded silently (`Pkg.test` opens with `Pkg.instantiate`)",
        "does not precompile the sandbox before the run — the child Julia precompiles on demand, so the work happens either way, but as compiler output in the suite's stream rather than as Pkg's progress bar",
        "the sandbox is not re-resolved: the parent manifest's versions are used verbatim, stdlib test deps (`Test`, above all) are filled in from the installation, and a test dependency that genuinely needs a registry is named in a warning before the suite fails to load it",
        "does not print Pkg's `Status` block of the sandbox before running, and the per-suite `Testing Foo` header appears after the suite rather than before it (the report arrives when the children are done)",
        "the suite's stdout reaches this process through a pipe, so `isatty(stdout)` is false in the child where Pkg hands it the real terminal; `--color` is forwarded from this session to compensate",
        "a `[workspace]` project delegates: Pkg tests a workspace member by activating its test directory in place, and ajt has no workspace support",
        "`test_fn` delegates — it runs a closure inside the sandbox, which only Pkg's in-process sandbox can do; `force_latest_compatible_version` and friends delegate as unknown keywords",
        "an unresolvable name's error lists the names without Pkg's fuzzy-matched suggestions (`ensure_resolved`'s `available_names` scan reads the registries)",
        "`ajt test <uuid>` (the bare CLI) accepts a uuid positional, which is `pkg> test`'s grammar; `Pkg.test([\"<uuid>\"])` builds a name-only spec and fails to resolve it, so the wrapper delegates a uuid spec and Pkg's behaviour is preserved",
    ],
    :instantiate => [
        "never runs a package's deps/build.jl",
        "does not run deps/build.jl afterwards — `Pkg.instantiate` builds what it installed, and `Ajt.build()` is that step as a separate command",
        "does not precompile afterwards",
        "`manifest = false`, or no Manifest.toml at all, delegates — both ask for a resolve",
        _AUTOPRECOMP_DIFFERENCE,
    ],
    :resolve => [
        "prints an ajt report rather than Pkg's `Updating`/`No Changes` lines; the manifest it writes is byte-identical",
        "does not install what it selected (Pkg's does): pass `install = true`, or run `Ajt.instantiate()`",
        "an environment holding a `develop`ed dependency delegates",
    ],
    :rm => [
        "`mode = PKGMODE_MANIFEST`, `all_pkgs = true` and a version on a package all delegate",
    ],
    :up => [
        "does not download or update the registry first, whatever `update_registry` says",
        "`mode = PKGMODE_MANIFEST`, `preserve`, `skip_writing_project` and workspaces delegate",
        "an environment holding a `develop`ed dependency delegates",
        "installs what moved and precompiles it afterwards, but never runs deps/build.jl",
        _AUTOPRECOMP_DIFFERENCE,
        "installs what moved, but does not auto-build or precompile afterwards — run `Ajt.build()`",
    ],
    :develop => [
        "a LOCAL PATH (`develop(path=…)`) or a bare URL (`develop(url=…)`), either with an optional `subdir`; `develop(name=…)`, which looks the source up in the manifest or the registry, delegates",
        "a `rev` delegates so that Pkg raises its own error — `develop` has no rev grammar (`API.jl:260-262`), and the binary refuses one too",
        "`shared` is honoured for the url arm (`Pkg.devdir()` vs `<env>/dev`) and ignored for the path arm — which is Pkg's own asymmetry, not a shortcut: `handle_repo_develop!`'s `is_local_path` branch returns before `shared` is consulted",
        "writes no `[sources]` — and neither does Pkg: `Pkg.develop(path=...)` records the path in the MANIFEST only. Verified by running it; nothing in Pkg ever adds to `project.sources`",
    ],
    :free => [
        "`all_pkgs = true` and workspaces delegate",
        "untracking a package no registry carries fails here with one line; Pkg says the same thing (`unable to free unregistered package`)",
        _AUTOPRECOMP_DIFFERENCE,
    ],
    :pin => [
        "a version must be EXACT. `pin(\"Foo\")` holds it where it is; `Foo@1.2` is the range [1.2.0, 2) in the project grammar and is refused rather than resolved to 1.2.0",
        "`all_pkgs = true` and workspaces delegate",
        "like Pkg's, it names a DIRECT dependency — a transitive one is refused (`project_deps_resolve!`), which is NOT true of `free`",
        _AUTOPRECOMP_DIFFERENCE,
    ],
    :why => [
        "byte-identical to `Pkg.why(...; io)` for a non-terminal `io`; a terminal gets no colour on the arrow",
        "a version on a package delegates",
    ],
    :is_manifest_current => [
        "a `[workspace]` project raises: `workspace_resolve_hash` digests every project in the workspace, and the binary hashes one",
        "a project that is a workspace MEMBER is answered against its own manifest, not the workspace root's — Pkg's `EnvCache` redirects, this does not",
        "accepts a path naming the PROJECT FILE and answers for it; Pkg's `projectfile_path(path, strict=true)` only ever joins `path` with `Base.project_names`, so `Pkg.is_manifest_current(\".../Project.toml\")` raises",
        "`is_manifest_current(::Pkg.Types.Context)` delegates",
    ],
    :upgrade_manifest => [
        "accepts a DIRECTORY as well as a file, and upgrades that environment's manifest. `Pkg.upgrade_manifest(man_path)` `cp`s the path into a tempdir as `Manifest.toml`, so a directory there ends up as \"already up to date\" — but the directory form is what makes the `manifest = \"…\"` redirect and the version-specific `Manifest-v<major>.<minor>.toml` resolve, and it is what the no-argument method uses",
        "`upgrade_manifest(::Pkg.Types.Context)` delegates",
        "takes an `io` keyword for the `Updated` line; Pkg's path-taking method prints through `ctx.io` and has no such keyword",
        "the write is atomic (temp sibling + rename) where Pkg's `write_manifest` truncates in place; the bytes are the same",
    ],
    :compat => [
        "the ZERO-ARGUMENT interactive form delegates: it is a raw-mode terminal menu over the project's dependencies, and Pkg's own refuses to run outside a fancy terminal anyway",
        "a `Context` first argument delegates — a caller who built one means that one",
        "prints an ajt report rather than Pkg's `Compat entry set` block; the Project.toml it writes is byte-identical, including the cases where Pkg writes nothing because the new bound parses to the same VersionSpec",
        "the compliance resolve's failure text is ajt's derivation tree, not Pkg's resolver message — the exit status and the `Call `update`` suggestion are the same",
        "a dependency no registry carries makes that resolve UNSATISFIABLE here, so it is reported and caught; Pkg raises `expected package … to be registered` instead. Either way the bound is already written",
    ],
    :generate => [
        "a non-ASCII package name delegates: deciding `Base.isidentifier` for one needs Julia's Unicode identifier tables, and guessing would either scaffold a package the parser cannot name or refuse one Pkg generates happily",
    ],
    :status => [
        "byte-identical to `Pkg.status(...; io)` for a non-terminal `io`; a terminal gets no colour on the markers",
        "`diff = true` delegates: it reads Project.toml and Manifest.toml out of git HEAD, and the binary's git backend has no `show`/`cat-file`",
        "`workspace = true` and `mode = PKGMODE_COMBINED` delegate",
        "does NOT print Pkg's `[loaded: v…]` annotation, which compares each package against `Base.loaded_modules` of the running session — a separate process has none",
        "`[sysimage]` never appears as an --outdated reason for the same reason: it needs `Base.in_sysimage` of the running image",
        "with several registries installed it reads ONE (`--registry`, default General) where Pkg takes the maximum over all of them",
        "`--compat` line order and the per-package extension lines are Julia `Dict` order in Pkg and a stable order here; the same lines, possibly permuted",
        "a positional matches by name OR uuid, which is `pkg> st`'s grammar (`parse_package`); `Pkg.status([\"<uuid>\"])` — the API's Vector{String} form — filters by name only and prints No Matches",
    ],
    :gc => [
        "`collect_delay` reaches the binary in whole SECONDS, rounded UP — a sub-second `Period` keeps things one second longer than Pkg would, which is the safe direction",
        "prints an ajt summary rather than Pkg's `Active …` / `Deleted …` lines; the set it deletes is the same",
        "an unreadable usage log, or an `Artifacts.toml` with no usable `git-tree-sha1`, stops the run with one line instead of a stack trace — either way NOTHING is collected",
        "an explicit `Context` positional argument delegates",
        "does not run Pkg's `delayed_delete_ref` sweep of `\$TMPDIR/julia_delayed_deletes` — that is Windows bookkeeping for files a running process still holds open, and `ajt` never writes it",
    ],
    :Registry => [
        "`add`/`update` are native by name, uuid or url — including a registry that is a git clone on disk, which `update` fetches and fast-forwards; a path, `linked`, or several uuids/urls at once delegate",
        "`update` on a git clone does not retry a locked merge (`Registry.jl:531-541`), which is libgit2's own index lock and not a thing the `git` subprocess backend can hit",
        "`status` and `rm` delegate; `Ajt.Registry.summary()` is the binary's own single-registry report",
    ],
)

"""
    parity([io])

Print the whole surface: what is native, what delegates and why, and every known
behavioural difference. The ratchet, rendered.
"""
function parity(io::IO = stdout)
    report = conformance()
    _hdr(io, :Ajt, "$(length(NATIVE)) native, $(length(DELEGATED)) delegating, $(length(REEXPORTED)) re-exported from Pkg")
    for name in sort(NATIVE)
        println(io, "  native      ", name)
        for difference in get(DIFFERENCES, name, String[])
            println(io, "                ! ", difference)
        end
    end
    for name in sort!(collect(keys(DELEGATED)))
        println(io, "  delegating  ", rpad(name, 20), DELEGATED[name])
    end
    if isempty(report.unaccounted)
        _hdr(io, :Conformance, "every name in `names(Pkg)` is accounted for")
    else
        _hdr(io, :Conformance, "UNACCOUNTED: " * join(report.unaccounted, ", "); color = :red)
    end
    return nothing
end

"""
    conformance(surface = names(Pkg))

Check this module against `Pkg`'s public surface. Returns
`(; unaccounted, undefined, native, delegated, reexported)` where

* `unaccounted` — a public `Pkg` name in none of the three buckets. Anything
  here is a hole: a caller who reaches for it gets an `UndefVarError` from a
  package that advertises itself as a drop-in replacement.
* `undefined` — a name a bucket claims but this module does not actually define,
  i.e. a typo in the bucket.

`Pkg`'s public surface is `export` + `public` (`Pkg.jl:13-21`), which is exactly
what `names(Pkg)` returns.
"""
function conformance(surface::Vector{Symbol} = names(Pkg))
    accounted = Set{Symbol}(NATIVE)
    union!(accounted, keys(DELEGATED))
    union!(accounted, REEXPORTED)
    unaccounted = Symbol[n for n in surface if !(n in accounted)]
    claimed = sort!(collect(accounted))
    undefined = Symbol[n for n in claimed if !isdefined(@__MODULE__, n)]
    return (;
        unaccounted, undefined,
        native = sort(NATIVE), delegated = sort!(collect(keys(DELEGATED))),
        reexported = sort(REEXPORTED),
    )
end

#############
#  Output   #
#############

# `Pkg/src/utils.jl:4-10`, copied rather than called: `printpkgstyle` is
# internal, and this is four lines.
const _INDENT = 12

function _hdr(io::IO, cmd::Symbol, text::AbstractString; color::Symbol = :green)
    printstyled(io, lpad(string(cmd), _INDENT); color, bold = true)
    println(io, " ", text)
    return nothing
end

# `Pkg/src/utils.jl:33-39`.
_pathrepr(path::AbstractString) = "`" * Base.contractuser(String(path)) * "`"

# A change record's third field is a uuid; a selection record's is a version.
# The two are otherwise the same shape (`kind<TAB>name<TAB>x`), and this is what
# tells them apart.
_isuuid(s::AbstractString) = length(s) == 36 && count(==('-'), s) == 4

"""
    _failed(io, verb, out, code)

Raise, after printing what the binary said.

A failed run's *whole* explanation is on stdout — the derivation tree, the
"to fix, try relaxing [compat] on: …" line, `no registered package by that name`
— and none of it is a record. Rendering the output and then throwing would print
a header with nothing under it and lose the one thing worth reading, which is
the difference between "it failed" and a person knowing what to edit.
"""
function _failed(io::IO, verb::AbstractString, out::AbstractString, code::Integer)
    isempty(out) || print(io, out)
    return Pkg.Types.pkgerror("`ajt $verb` failed (exit $code)")
end

"""
Render the report `resolve`/`add`/`rm`/`up` write on stdout.

Deliberately Ajt's own voice rather than a forgery of Pkg's `Updating` block:
the manifest these commands produce is byte-identical to Pkg's, the *narration*
is not, and printing lines that look exactly like Pkg's would invite the reader
to assume a parity that was never claimed.
"""
function _render_env(io::IO, out::AbstractString)
    for fields in _records(out)
        kind = fields[1]
        if kind in ("added", "removed", "already_present") && length(fields) >= 3 && _isuuid(fields[3])
            mark = kind == "added" ? "+" : kind == "removed" ? "-" : "="
            println(io, "   [", first(fields[3], 8), "] ", mark, " ", fields[2])
        elseif kind == "added" && length(fields) >= 3
            # `julia` is the solver's pseudo-package: it is in every solution
            # and in no manifest, so a clean resolve reports it as `added` every
            # single time (`ajt help`, resolve options). Printing it would say
            # "a package was added" about a run that changed nothing. The
            # summary count still includes it, which is the binary's number and
            # not this renderer's to edit.
            fields[2] == "julia" || println(io, "   + ", fields[2], " v", fields[3])
        elseif kind == "changed" && length(fields) >= 4
            println(io, "   ↑ ", fields[2], " v", fields[3], " ⇒ v", fields[4])
        elseif kind == "unversioned" && length(fields) >= 3
            println(io, "   ? ", fields[2], " v", fields[3], " (manifest records no version)")
        elseif kind == "project" && length(fields) >= 3
            fields[3] == "written" && _hdr(io, :Updating, _pathrepr(fields[2]))
        elseif kind == "manifest" && length(fields) >= 4
            verb = fields[4] == "written" ? :Updating : :Unchanged
            _hdr(io, verb, string(_pathrepr(fields[2]), " (", fields[3], " entries)"))
        elseif kind == "compat" && length(fields) >= 4
            # compat<TAB>set|removed<TAB>name<TAB>value ("-" when there was none)
            msg = if fields[2] == "set"
                "$(fields[3]) = $(repr(fields[4]))"
            else
                "$(fields[3]) entry removed" * (fields[4] == "-" ? "" : " (was $(repr(fields[4])))")
            end
            _hdr(io, :Compat, msg)
        elseif kind == "suggestion" && length(fields) >= 2
            # The line that says what to do about a failed compliance resolve;
            # Pkg prints the same sentence (`API.jl:1538`).
            _hdr(io, :Suggestion, fields[2]; color = :blue)
        elseif kind == "resolve" && length(fields) >= 3 && fields[2] == "skipped"
            _hdr(io, :Warning, "compliance not checked — $(fields[3])"; color = :yellow)
        elseif kind == "no-source" && length(fields) >= 2
            _hdr(io, :Warning, "$(fields[2]) is not installed, so its weakdeps and extensions could not be read"; color = :yellow)
        elseif kind == "summary" && length(fields) >= 7
            # summary<TAB>total<TAB>changed<TAB>unversioned<TAB>added<TAB>ms<TAB>tier
            _hdr(
                io, :Resolved,
                "$(fields[2]) packages, $(fields[3]) moved, $(fields[5]) added in $(fields[6]) ms (preserve $(fields[7]))"
            )
        elseif kind in ("resolve", "add", "rm", "up") && length(fields) >= 2 && fields[2] == "failed"
            _hdr(io, :Failed, "the environment is unsatisfiable — see the report above"; color = :red)
        elseif kind == "precompile" && length(fields) >= 3
            # `precompile<TAB>considered<TAB>compiled<TAB>already<TAB>failed`,
            # or `precompile<TAB>skipped<TAB>why`.
            _render_precompile(io, fields)
        end
        # `held` is the common case and says nothing; it is dropped on purpose.
    end
    return nothing
end

"""
Render the `precompile` record `add`/`up`/`pin`/`free`/`instantiate` end with:
`precompile <considered> <compiled> <already> <failed> <imported>`, or
`precompile skipped <why>`.

Shared by both renderers because the record is the same on both — it is emitted
by the one auto-precompile pass, wherever that pass lives.

Nothing is printed when the pass compiled and imported nothing, which is the
steady state: an environment that was already precompiled produces the same
silence under Pkg.

There is deliberately **no failure branch**. A non-zero `<failed>` makes the
binary exit non-zero (`main.zig`, `Report.precompileOk`), so the caller raises
through [`_failed`](@ref) — which prints the whole report, per-package stderr
included — before any renderer runs. A red line here would be unreachable code
that looked like a safety net.
"""
function _render_precompile(io::IO, fields::Vector{<:AbstractString})
    # `precompile skipped <why>` is a three-field record and says nothing a
    # user asked to hear: every reason for it is something they configured.
    (fields[2] == "skipped" || length(fields) < 5) && return nothing
    compiled = fields[3]
    # The sixth field is the shared cache's contribution. Reported separately
    # because a compile and an import cost wildly different amounts, and older
    # records that predate the field simply do not have one.
    imported = length(fields) >= 6 ? fields[6] : "0"
    if imported != "0"
        _hdr(io, :Precompiled, "$compiled of $(fields[2]) packages ($imported imported from the cache)")
    elseif compiled != "0"
        _hdr(io, :Precompiled, "$compiled of $(fields[2]) packages")
    end
    return nothing
end

"""
Render `ajt instantiate`'s report. Only the outcomes worth a line get one: a
warm depot answers `already_present` for every entry, and printing those is noise
Pkg does not print either.
"""
function _render_instantiate(io::IO, out::AbstractString)
    for fields in _records(out)
        kind = fields[1]
        if kind in ("package", "artifact") && length(fields) >= 3
            # The outcomes are `installed`, `already_present`, `needs_git_clone`
            # and `failed` (`install_packages.zig:366-379`,
            # `install_artifacts.zig:416-424`). `already_present` is the warm
            # depot's answer for every entry and Pkg prints nothing for it
            # either; the two bad ones are worth a line each.
            what = kind == "package" ? fields[3] : "artifact $(fields[3])"
            if fields[2] == "installed"
                _hdr(io, :Installed, what)
            elseif fields[2] != "already_present"
                _hdr(io, :Failed, "$what: $(fields[2])"; color = :red)
            end
        elseif kind == "registry" && length(fields) >= 3
            _hdr(io, :Registry, "$(fields[3]): $(fields[2])")
        elseif kind == "manifest" && length(fields) >= 3
            fields[2] == "written" && _hdr(io, :Updating, _pathrepr(fields[3]))
        elseif kind == "usage" && length(fields) >= 4 && !(fields[4] in ("written", "unchanged"))
            # `usage<TAB>log<TAB>keys<TAB>status`: the log `Pkg.gc()` reads.
            # "installed everything and recorded nothing" looks exactly like a
            # full success until a gc empties the depot (`main.zig:2301-2312`),
            # which is why the binary reports it and why this must not drop it.
            _hdr(io, :Warning, "could not record $(fields[2]): $(fields[4])"; color = :yellow)
        elseif kind == "blocked" && length(fields) >= 2
            _hdr(io, :Blocked, join(fields[2:end], " "); color = :red)
        elseif kind == "summary" && length(fields) >= 8
            _hdr(
                io, :Instantiated,
                "$(fields[2]) entries: $(fields[5]) of $(fields[4]) packages and " *
                    "$(fields[7]) of $(fields[6]) artifacts installed in $(fields[8]) ms"
            )
        elseif kind == "verify" && length(fields) >= 3 && fields[2] != "ok"
            _hdr(io, :Failed, "still not instantiated: $(fields[3]) problem(s)"; color = :red)
        elseif kind == "precompile" && length(fields) >= 3
            _render_precompile(io, fields)
        end
    end
    return nothing
end

"""
Render `ajt build`'s report.

`Pkg.build` prints `Building Foo ──→ \\`<log>\\`` per package; the shape here is
the same information in Ajt's own voice. A run with nothing to build says so
rather than printing nothing at all, because "no package in this environment has
a `deps/build.jl`" and "the command silently did nothing" look identical
otherwise, and only one of them is fine.
"""
function _render_build(io::IO, out::AbstractString)
    built = 0
    for fields in _records(out)
        kind = fields[1]
        if kind == "build" && length(fields) >= 6
            built += 1
            _hdr(
                io, :Building, string(fields[3], " → ", _pathrepr(fields[5]));
                color = fields[2] == "failed" ? :red : :green
            )
        elseif kind == "summary" && length(fields) >= 3 && built == 0
            _hdr(io, :Building, "nothing to do — no package in the closure has a deps/build.jl")
        end
    end
    return nothing
end

"""
Render `ajt test`'s report.

`Pkg.test` prints `Testing Foo` before a suite and `Testing Foo tests passed`
after it. The before-half cannot be reproduced — the records arrive when the
children are done — so the after-half carries the verdict, per package, in
Pkg's colours. The failure itself is not printed here: it is re-raised as a
`PkgError` by the caller, which is where Pkg's message belongs.
"""
function _render_test(io::IO, out::AbstractString)
    for fields in _records(out)
        fields[1] == "test" && length(fields) >= 6 || continue
        status = fields[2]
        status == "planned" && continue
        ok = status == "ok"
        _hdr(io, :Testing, string(fields[3], ok ? " tests passed" : " tests errored"); color = ok ? :green : :red)
    end
    return nothing
end

#####################
#  Argument gating  #
#####################

"""
Any keyword this package has not explicitly accounted for is a delegation
reason, never a silent no-op. Ignoring `mode = PKGMODE_MANIFEST` would not throw,
it would edit the wrong file.
"""
function _kwreason(kwargs)
    names = collect(keys(kwargs))
    isempty(names) && return nothing
    return string("keyword", length(names) == 1 ? " " : "s ", join(("`$n`" for n in names), ", "), " not supported natively")
end

const _STAR = Pkg.Versions.VersionSpec()

"""
    _spec_arg(pkg) -> Union{String,Nothing}

The `Name` / `Name@version` argument the binary takes, or `nothing` when this
spec says something the binary cannot express.

`Foo@1.2` from the REPL arrives as `PackageSpec(name="Foo", version="1.2")` — a
*String* version (`REPLMode/argument_parsers.jl:418`), which is the same grammar
`ajt add` parses (`semver_spec`, so `1.2` means `[1.2, 2)`). A `VersionNumber`
or a `VersionSpec` does not survive that round trip unchanged, so it delegates
rather than guess.
"""
function _spec_arg(pkg::PackageSpec)
    pkg.name === nothing && return nothing
    pkg.uuid === nothing || return nothing
    pkg.url === nothing || return nothing
    pkg.path === nothing || return nothing
    pkg.rev === nothing || return nothing
    pkg.subdir === nothing || return nothing
    pkg.tree_hash === nothing || return nothing
    pkg.pinned && return nothing
    version = pkg.version
    if version === nothing || version == _STAR
        return String(pkg.name)
    elseif version isa AbstractString
        return string(pkg.name, "@", version)
    end
    return nothing
end

function _spec_args(pkgs::Vector{PackageSpec})
    args = String[]
    for pkg in pkgs
        arg = _spec_arg(pkg)
        arg === nothing && return nothing
        push!(args, arg)
    end
    return args
end

"""
    _repo_argv(pkg) -> Union{Vector{String},Nothing}

The `--url U --rev R --subdir D [Name]` argument list for a spec that names a
repository, or `nothing` when the spec says something else as well.

The **explicit flag form**, never `<url>#<rev>`: the binary's inline grammar
takes everything after the first `#` as the rev (Pkg's own REPL rule), so a URL
or a branch containing a `#` would be cut in the wrong place. A programmatic
caller has the parts separately and there is no reason to re-flatten them.

A `version` alongside a repository is left to Pkg to refuse: it is an error
either way (`API.jl:313-320`) and Pkg's message is the one people have seen.
"""
function _repo_argv(pkg::PackageSpec)
    (pkg.url === nothing && pkg.rev === nothing) && return nothing
    pkg.path === nothing || return nothing
    pkg.tree_hash === nothing || return nothing
    pkg.pinned && return nothing
    (pkg.version === nothing || pkg.version == _STAR) || return nothing
    # A UUID pins identity, and the binary learns it from the checked-out
    # project file instead; a mismatch is Pkg's error to raise, not ours to
    # skip past.
    pkg.uuid === nothing || return nothing
    argv = String[]
    pkg.url === nothing || append!(argv, ["--url", String(pkg.url)])
    pkg.rev === nothing || append!(argv, ["--rev", String(pkg.rev)])
    pkg.subdir === nothing || append!(argv, ["--subdir", String(pkg.subdir)])
    # `add Name#rev` with no url: the binary resolves the source from the
    # manifest and then the registry, exactly as `handle_repo_add!` does.
    pkg.name === nothing || push!(argv, String(pkg.name))
    return argv
end

"""
    _one_repo(pkgs) -> Union{Vector{String},Nothing}

`_repo_argv` for a call that is exactly ONE repository spec. The flags describe
a single package, so a batch containing one is handed to Pkg whole rather than
split into several binary invocations that would each resolve on their own.
"""
function _one_repo(pkgs::Vector{PackageSpec})
    length(pkgs) == 1 || return nothing
    return _repo_argv(pkgs[1])
end

"""
`rm` and `why` name a package; they have no version grammar, and `ajt rm Foo@1.2`
would go looking for a dependency spelled `Foo@1.2` and report the wrong error.
Pkg refuses the same input up front ("packages may only be specified by name or
UUID when calling rm", `API.jl:368-375`), so this hands it to Pkg to say so.
"""
_versionless(pkgs::Vector{PackageSpec}) =
    all(p -> p.version === nothing || p.version == _STAR, pkgs)

const _PRESERVE = Dict{PreserveLevel, String}(
    PRESERVE_ALL => "all",
    PRESERVE_ALL_INSTALLED => "installed",
    PRESERVE_DIRECT => "direct",
    PRESERVE_SEMVER => "semver",
    PRESERVE_NONE => "none",
    PRESERVE_TIERED => "tiered",
    PRESERVE_TIERED_INSTALLED => "tiered_installed",
)

const _LEVEL = Dict{UpgradeLevel, String}(
    Pkg.Types.UPLEVEL_FIXED => "fixed",
    UPLEVEL_PATCH => "patch",
    UPLEVEL_MINOR => "minor",
    UPLEVEL_MAJOR => "major",
)

# `Operations.jl:23-29` — through the same `get_bool_env`, because its truthy set
# is wider than `("true", "1")` (`t`, `T`, `True`, …) and a narrower one here
# would silently resolve at a different tier than Pkg for the same environment.
_default_preserve() = Base.get_bool_env("JULIA_PKG_PRESERVE_TIERED_INSTALLED", false) ?
    PRESERVE_TIERED_INSTALLED : PRESERVE_TIERED

##################
#  Native paths  #
##################

"""
    add(pkg...; preserve = PRESERVE_TIERED, install = true, io = stderr)

Add packages to `[deps]`, resolve, write `Project.toml` and `Manifest.toml`,
install what the solution needs and precompile it — `ajt add` followed by
`ajt instantiate`.

`install = false` stops after the two files are written. It is *not* the default,
because `Pkg.add` leaves an environment you can immediately load from and an
`add` that resolved but installed nothing looks identical right up until
`using Foo` fails. The precompile pass is Pkg's own
(`Operations.jl:1828`) and is skipped by `JULIA_PKG_PRECOMPILE_AUTO=0`.

A **url** or a **rev** is native too — `add(url = "https://…")`,
`add(name = "Foo", rev = "main")`, with an optional `subdir` — and goes through
the binary's clone: `clones/<hash(url)>` for the cache, `packages/<Name>/<slug>`
for the tree, and `repo-url`/`repo-rev`/`repo-subdir`/`git-tree-sha1` in the
manifest, all byte-identical to Pkg's. One repository spec at a time, because
the flags describe one package.

Accepts everything `Pkg.add` accepts and delegates the shapes the binary cannot
express yet (see `Ajt.DIFFERENCES[:add]`). Note that `add Foo@1.2` constrains the
resolve and writes no `[compat]` entry, exactly as Pkg's does.
"""
function add(
        pkgs::Vector{PackageSpec}; io::IO = stderr,
        preserve::PreserveLevel = _default_preserve(), install::Bool = true, kwargs...
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    reason === nothing && (reason = _source_reason(dir::String))
    args = reason === nothing ? something(_one_repo(pkgs), _spec_args(pkgs), Some(nothing)) : nothing
    if args === nothing
        reason = something(reason, "a package was given by path, uuid, tree_hash or a non-string version, or a repository was named alongside other packages")
        _delegating(:add, reason)
        return Pkg.add(pkgs; io, preserve, kwargs...)
    end
    # "Activate a fresh directory, then add something" is the first thing
    # anyone does with a new environment, and Pkg handles it by *writing* the
    # project file it did not find (`Operations.jl` write_env). The binary needs
    # the file to exist and errors out without one, so the wrapper creates the
    # empty file Pkg would have created. Only `add` does this: `rm`, `why` and
    # `resolve` on a nonexistent environment are questions with no answer, not
    # environments waiting to be created.
    envdir = dir::String
    projfile = joinpath(envdir, "Project.toml")
    if !isfile(projfile)
        mkpath(envdir)
        touch(projfile)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["add", "--project", envdir, "--preserve", _PRESERVE[preserve]]
    append!(argv, _julia_args())
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "add", out, code)
    _render_env(io, out)
    # `Pkg.add` leaves an environment you can load from; the binary's `add`
    # stops at the two files. Installing here is what makes `Ajt.add("Foo")`
    # followed by `using Foo` behave the way every caller already assumes.
    install && _install(io, envdir)
    return nothing
end

"""
    rm(pkg...; io = stderr)

Remove packages from `[deps]` and prune the manifest — `ajt rm`.

Like Pkg's, this never resolves: every surviving entry keeps the version it had
(`Operations.jl:1522-1591`). Removing one package must not silently move the
others.
"""
function rm(pkgs::Vector{PackageSpec}; io::IO = stderr, mode::PackageMode = PKGMODE_PROJECT, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && mode != PKGMODE_PROJECT && (reason = "`mode = PKGMODE_MANIFEST`")
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    reason === nothing && !_versionless(pkgs) && (reason = "a version was given, which `rm` has no grammar for")
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:rm, reason)
        return Pkg.rm(pkgs; io, mode, kwargs...)
    end
    argv = String["rm", "--project", dir::String]
    append!(argv, _julia_args())
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "rm", out, code)
    _render_env(io, out)
    return nothing
end


"""
    pin(pkg...; io = stderr)

Hold a manifest entry where it is — `ajt pin`.

A version, if given, must be **exact**. That is not a limitation Ajt invented:
Pkg refuses a range too (`API.jl:487-489`), and the trap is that the project
grammar this argument uses turns almost anything a person types into one —
`Foo@1.2` is `[1.2.0, 2)`, not `1.2.0`. `pin("Foo")` with no version is the
usual form, and holds it at whatever the manifest already records.

Names a **direct** dependency, as `Pkg.pin` does (`project_deps_resolve!`); a
transitive one is refused. `free` differs — see its docstring.
"""
function pin(pkgs::Vector{PackageSpec}; io::IO = stderr, all_pkgs::Bool = false, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && all_pkgs && (reason = "`all_pkgs = true` enumerates the manifest, which is Pkg's own walk")
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    reason === nothing && (reason = _source_reason(dir::String))
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:pin, reason)
        return Pkg.pin(pkgs; io, all_pkgs, kwargs...)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["pin", "--project", dir::String]
    append!(argv, _julia_args())
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "pin", out, code)
    _render_env(io, out)
    return nothing
end

"""
    free(pkg...; io = stderr)

Stop holding a package — `ajt free`.

Two operations behind one name, and Pkg says so itself (`# TODO: this is two
technically different operations with the same name`, `Operations.jl:2083`): a
**pinned** entry is un-pinned, and an entry tracking a **path** or a
**repository** goes back to tracking the registry. Anything else is an error.

Unlike `pin`, this names any **manifest** entry — a transitive dependency is
freeable (`manifest_resolve!`, `API.jl:521`).
"""
function free(pkgs::Vector{PackageSpec}; io::IO = stderr, all_pkgs::Bool = false, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && all_pkgs && (reason = "`all_pkgs = true` enumerates the manifest, which is Pkg's own walk")
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    reason === nothing && !_versionless(pkgs) && (reason = "a version was given; Pkg refuses one here too")
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:free, reason)
        return Pkg.free(pkgs; io, all_pkgs, kwargs...)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["free", "--project", dir::String]
    append!(argv, _julia_args())
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "free", out, code)
    _render_env(io, out)
    return nothing
end

"""
    develop(pkg...; io = stderr)

Track a package from a directory on disk — `ajt dev`.

Two arms, both native. A **local path** records it in the manifest as given. A
**url** (optionally with a `subdir`) clones — into `Pkg.devdir()` when `shared`,
into `<env>/dev` when not — and records the resulting directory, which is a
working tree with a `.git` in it because that is the point of a develop.

A **`rev` is not accepted**, here or in Pkg: *"rev argument not supported by
`develop`; consider using `add` instead"* (`API.jl:260-262`).

`shared` is honoured for the clone arm and irrelevant to the path arm, which is
`handle_repo_develop!`'s own asymmetry: the `is_local_path` branch returns
before `shared` is ever consulted (`Types.jl:776-811`).

Writes `[deps]` plus a manifest entry carrying the path, and no `[sources]` —
which is what Pkg writes too. That is worth stating because `[sources]` looks
like where a develop belongs and `free` deletes from it; running
`Pkg.develop(path=...)` on 1.12.6 settles it, and it produces a `Project.toml`
with `[deps]` and nothing else.
"""
function develop(pkgs::Vector{PackageSpec}; io::IO = stderr, shared::Bool = true, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    # "rev argument not supported by `develop`; consider using `add` instead"
    # (`API.jl:260-262`). Pkg raises before it looks at anything else, so this
    # hands the call over and lets Pkg say exactly that — the binary refuses it
    # too, but Pkg's wording is the one people have seen.
    reason === nothing && any(p -> p.rev !== nothing, pkgs) &&
        (reason = "a rev, which `develop` does not support (Pkg raises on it)")
    sources = String[]
    if reason === nothing
        repo = _one_repo(pkgs)
        if repo !== nothing && pkgs[1].name === nothing
            # A url, alone. `develop` by NAME is a different arm of
            # `handle_repo_develop!` — it looks the source up in the manifest
            # or the registry (`Types.jl:812-828`) — and the binary does not
            # implement it, so a named spec falls through and delegates.
            append!(sources, repo)
            push!(sources, shared ? "--shared" : "--local")
        else
            for pkg in pkgs
                if pkg.path === nothing || pkg.url !== nothing || pkg.rev !== nothing ||
                        pkg.subdir !== nothing || pkg.tree_hash !== nothing
                    reason = "only a local path or a bare url is native; `develop` by NAME needs the registry lookup arm"
                    break
                end
                push!(sources, String(pkg.path))
            end
        end
    end
    if reason !== nothing
        _delegating(:develop, reason)
        return Pkg.develop(pkgs; io, shared, kwargs...)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["dev", "--project", dir::String]
    append!(argv, _julia_args())
    append!(argv, sources)
    out, code = _run(argv)
    code == 0 || _failed(io, "dev", out, code)
    _render_env(io, out)
    return nothing
end

"""
    update(pkg...; level = UPLEVEL_MAJOR, install = true, io = stderr)

Move packages within an upgrade level — `ajt up`. With no arguments, every direct
dependency. Installs what moved and precompiles afterwards, as `Pkg.up` does
(`API.jl:170`).

Ajt does **not** update the registry first. `Pkg.up` defaults to
`update_registry = true` and silently downloads the world before it resolves;
that is a network operation hidden inside an upgrade, and here it is a separate
command (`Ajt.Registry.update()`).
"""
function update(
        pkgs::Vector{PackageSpec}; io::IO = stderr, level::UpgradeLevel = UPLEVEL_MAJOR,
        mode::PackageMode = PKGMODE_PROJECT, update_registry::Bool = true,
        install::Bool = true, kwargs...
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && mode != PKGMODE_PROJECT && (reason = "`mode = PKGMODE_MANIFEST`")
    reason === nothing && (reason = _source_reason(dir::String))
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:up, reason)
        return Pkg.update(pkgs; io, level, mode, update_registry, kwargs...)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["up", "--project", dir::String, "--level", _LEVEL[level]]
    append!(argv, _julia_args())
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "up", out, code)
    _render_env(io, out)
    install && _install(io, dir::String)
    return nothing
end

const up = update

"""
    build(pkg...; verbose = false, io = stderr)

Run each package's `deps/build.jl`, in dependency order, inside a throwaway
sandbox environment — `ajt build`.

With no arguments: the project's own package if it has one, otherwise every
manifest entry, which is exactly how `Pkg.build` chooses (`API.jl:1206-1214`).

The **first** failure aborts the run and raises with the tail of that package's
`build.log`, as `Pkg.build` does — a later package's script frequently consumes
an earlier one's output, so continuing would bury the cause. Where the log lands
is Pkg's rule too: a tree-hash-pinned package's goes in Pkg's own scratchspace
and gets a `logs/scratch_usage.toml` entry so `Pkg.gc()` keeps it alive; a
path-tracked one's goes in `<source>/deps/build.log` and gets no entry.

See `Ajt.DIFFERENCES[:build]` for the two things this does not do.
"""
function build(pkgs::Vector{PackageSpec}; io::IO = stderr, verbose::Bool = false, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:build, reason)
        return Pkg.build(pkgs; io, verbose, kwargs...)
    end
    argv = String["build", "--project", dir::String]
    append!(argv, _julia_args())
    # Two properties of THIS session that the binary cannot see and must not
    # guess: `gen_build_code` mirrors the parent's `--startup-file` flag
    # (`Operations.jl:1372-1373`) and the failure message shows 100 log lines
    # instead of 5000 when `isinteractive()` (`:1493`).
    Base.JLOptions().startupfile == 1 && push!(argv, "--startup-file")
    isinteractive() && push!(argv, "--interactive")
    verbose && push!(argv, "--verbose")
    append!(argv, args)
    out, code = _run(argv)
    code == 0 || _failed(io, "build", out, code)
    _render_build(io, out)
    return nothing
end

"""
    test(pkg...; coverage = false, julia_args = ``, test_args = ``, io = stderr)

Run each package's `test/runtests.jl` in a child Julia, inside a sandbox
environment built from its `test/Project.toml` — or, for the legacy layout,
from its `[extras]` + `[targets]` test list — with the package under test
`dev`'d in as a `path` entry pointing at its source. `ajt test`.

With no arguments: the project's own package (`API.jl:544-546`). A name may be
ANY manifest entry, not only a direct dependency — an asymmetry with `pin` that
is Pkg's own (`manifest_resolve!` searches the whole manifest).

A failing suite does not stop the run: every named package is tested, and one
`PkgError` is raised at the end carrying Pkg's exact message, exit codes and
signal names included (`Operations.jl:2506-2543`). The suites' output streams
as it runs, and each child gets the flags `Pkg.test` would pass: the fixed
`--check-bounds=yes`/`--warn-overwrite=yes` pair, this session's `--color`,
`--depwarn`, `--inline`, `--startup-file` and `--track-allocation`
(`gen_subprocess_flags`, `Operations.jl:2136-2156`), this session's threads
spec (`get_threads_spec`, `:2124-2134`), `julia_args` last so a caller's
`--check-bounds=no` really overrides, and `test_args` into the suite's `ARGS`.

See `Ajt.DIFFERENCES[:test]` for what is deliberately different.
"""
function test(
        pkgs::Vector{PackageSpec}; io::IO = stderr, coverage = false,
        julia_args::Union{Cmd, AbstractVector{<:AbstractString}} = ``,
        test_args::Union{Cmd, AbstractVector{<:AbstractString}} = ``,
        test_fn = nothing, kwargs...
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && test_fn !== nothing &&
        (reason = "`test_fn` runs a closure inside the sandbox, which only Pkg's in-process sandbox can do")
    # Pkg owns the ArgumentError for a coverage that is neither
    # (`gen_subprocess_flags`, `Operations.jl:2143`).
    reason === nothing && !(coverage isa Bool || coverage isa AbstractString) &&
        (reason = "`coverage` is neither a Bool nor a String")
    reason === nothing && _is_workspace(dir::String) &&
        (reason = "a [workspace] project takes Pkg's workspace fast path (`Operations.jl:2434-2464`), which ajt does not have")
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:test, reason)
        return Pkg.test(pkgs; io, coverage, julia_args, test_args, test_fn, kwargs...)
    end
    argv = String["test", "--project", dir::String]
    append!(argv, _julia_args())
    # `gen_subprocess_flags` reads the CALLING julia's `JLOptions`
    # (`Operations.jl:2136-2156`). This session is that julia, so each flag is
    # read here and stated to the binary, which has no JLOptions of its own.
    coverage === true && push!(argv, "--coverage")
    coverage isa AbstractString && push!(argv, "--coverage=$(coverage)")
    push!(argv, "--color", Base.have_color === nothing ? "auto" : Base.have_color ? "yes" : "no")
    push!(argv, "--depwarn", Base.JLOptions().depwarn == 2 ? "error" : "yes")
    push!(argv, "--inline", Bool(Base.JLOptions().can_inline) ? "yes" : "no")
    Base.JLOptions().startupfile == 1 && push!(argv, "--startup-file")
    push!(argv, "--track-allocation", ("none", "user", "all")[Base.JLOptions().malloc_log + 1])
    # `get_threads_spec()` (`Operations.jl:2124-2134`), inlined because it is
    # Pkg's private helper: `JULIA_NUM_THREADS` verbatim when set (it is what
    # decided this session's count and `--threads` takes precedence in the
    # child), else this session's live counts — which DOES see a parent
    # started with `-t N`, the one thing the bare CLI cannot.
    threads = if haskey(ENV, "JULIA_NUM_THREADS")
        ENV["JULIA_NUM_THREADS"]
    elseif Threads.nthreads(:interactive) > 0
        "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
    else
        "$(Threads.nthreads(:default))"
    end
    push!(argv, "--threads", threads)
    append!(argv, args)
    # After the positionals, because each swallows the rest of the argv up to
    # the other's marker — the only spelling of two `Cmd`s that survives argv.
    jargs = collect(String, Cmd(julia_args).exec)
    targs = collect(String, Cmd(test_args).exec)
    isempty(jargs) || append!(push!(argv, "--julia-args"), jargs)
    isempty(targs) || append!(push!(argv, "--test-args"), targs)
    out, code = _run_streamed(argv)
    _render_test(io, out)
    # The `failure` record is Pkg's own pkgerror text, escaped into one line —
    # re-raised VERBATIM so `julia -e 'Pkg.test()'` and this exit the same way
    # with the same sentence, whichever failure shape it was (a failing suite,
    # a missing `test/runtests.jl`, an unresolvable name).
    for fields in _records(out)
        fields[1] == "failure" && length(fields) >= 2 &&
            Pkg.Types.pkgerror(_unescape_record(String(fields[2])))
    end
    code == 0 || _failed(io, "test", out, code)
    return nothing
end

"""
    why(pkg; io = stdout)

Every dependency path that explains why a package is in the manifest — `ajt why`.

Byte-for-byte what `Pkg.why(pkg; io)` writes when `io` is not a terminal: the
same two-space indent and the same U+2192 arrow (`API.jl:1556-1612`). Pkg wraps
the arrow in colour escapes on a TTY; the binary does not, so a terminal loses
the green arrow and nothing else.
"""
function why(pkgs::Vector{PackageSpec}; io::IO = stdout, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && isempty(pkgs) && (reason = "no packages given")
    reason === nothing && !_versionless(pkgs) && (reason = "a version was given, which `why` has no grammar for")
    args = reason === nothing ? _spec_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir, uuid or a non-string version")
        _delegating(:why, reason)
        return Pkg.why(pkgs; io, kwargs...)
    end
    argv = String["why", "--project", dir::String]
    append!(argv, args)
    out, code = _run(argv)
    # `why`'s whole output is the answer, and its failure text ("X is not in this
    # manifest") is on the same stream, so both are printed the same way.
    print(io, out)
    code == 0 || Pkg.Types.pkgerror("`ajt why` failed (exit $code)")
    return nothing
end

"""
    _status_args(pkgs) -> Union{Vector{String},Nothing}

The positional filters `ajt status` takes, or `nothing` when a spec says
something the report has no grammar for.

`print_status` filters on `id in uuids || something(new, old).name in names`
(`Operations.jl:2811`) — an OR over two independent lists — so a spec carrying
BOTH a name and a uuid becomes two positionals, not one. The binary matches each
positional against the name and the uuid, which is exactly `pkg> st`'s grammar
(`parse_package`, `REPLMode/argument_parsers.jl:472`).

Everything else about a `PackageSpec` — a url, a path, a rev, a subdir, a
version — is not a filter `status` understands; Pkg would build `filter_names`
out of the name and ignore the rest, so passing it here would silently answer a
narrower question.
"""
function _status_args(pkgs::Vector{PackageSpec})
    args = String[]
    for pkg in pkgs
        pkg.url === nothing || return nothing
        pkg.path === nothing || return nothing
        pkg.rev === nothing || return nothing
        pkg.subdir === nothing || return nothing
        pkg.tree_hash === nothing || return nothing
        (pkg.version === nothing || pkg.version == _STAR) || return nothing
        pkg.name === nothing && pkg.uuid === nothing && return nothing
        pkg.name === nothing || push!(args, String(pkg.name))
        pkg.uuid === nothing || push!(args, string(pkg.uuid))
    end
    return args
end

"""
    status([pkgs...]; outdated = false, mode = PKGMODE_PROJECT, compat = false,
           extensions = false, io = stdout)

The environment's status report — `ajt status`.

Byte-for-byte what `Pkg.status(...; io)` writes when `io` is not a terminal, and
that is the whole specification: `status` produces no file, so the bytes are the
product. `tools/diff_harness/status.sh` `cmp`s the two over eight environments
and eleven option sets.

Pkg emits every marker through `printstyled`, which colours only when
`get(io, :color, false)` — so a redirected stdout, a file or an `IOBuffer` gets
identical bytes from both, and a terminal loses the colour on `→`, `⌃`, `⌅` and
nothing else.

Three parts of Pkg's report are absent by construction rather than by omission,
because each is a property of the Julia SESSION and the binary is a separate
process: the `[loaded: v…]` annotation, `[sysimage]` as an `--outdated` reason,
and the green/grey colouring of extension names. See [`DIFFERENCES`](@ref); the
first two are visible on a colourless `io`, the third is not.

`diff = true` delegates rather than being ignored — it reports on the difference
against git `HEAD`, which is a different set of packages, and a silently dropped
flag would answer the wrong question in the right format.
"""
function status(
        pkgs::Vector{PackageSpec};
        io::IO = stdout,
        mode::PackageMode = PKGMODE_PROJECT,
        outdated::Bool = false,
        compat::Bool = false,
        extensions::Bool = false,
        diff::Bool = false,
        workspace::Bool = false,
        kwargs...,
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && diff &&
        (reason = "`diff = true` reads Project.toml and Manifest.toml out of git HEAD, which the binary's git backend cannot do")
    reason === nothing && workspace && (reason = "`workspace = true`")
    reason === nothing && mode == Pkg.Types.PKGMODE_COMBINED && (reason = "`mode = PKGMODE_COMBINED`")
    args = reason === nothing ? _status_args(pkgs) : nothing
    if args === nothing
        reason = something(reason, "a package was given by url, path, rev, subdir or version, none of which `status` filters on")
        _delegating(:status, reason)
        return Pkg.status(pkgs; io, mode, outdated, compat, extensions, diff, workspace, kwargs...)
    end
    argv = String["status", "--env", dir::String]
    append!(argv, _julia_args())
    mode == PKGMODE_MANIFEST && push!(argv, "--manifest")
    outdated && push!(argv, "--outdated")
    compat && push!(argv, "--compat")
    extensions && push!(argv, "--extensions")
    append!(argv, args)
    out, code = _run(argv)
    # The whole output is the answer, and a refusal ("--diff is not
    # implemented", "no Julia installation found") is on the same stream — so
    # both are printed the same way, exactly as `why` does.
    print(io, out)
    code == 0 || Pkg.Types.pkgerror("`ajt status` failed (exit $code)")
    return nothing
end

"""
    resolve(; install = false, io = stderr)

Resolve the environment and write `Manifest.toml` — `ajt resolve --write`.

`Pkg.resolve` is `up(level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST,
update_registry = false)` (`API.jl:454-457`), i.e. hold every recorded version
and fill in what is missing. That is `--preserve all`, and the manifest it writes
is byte-identical to the one Pkg writes for the same environment.

Pkg's version also installs the sources it selected; this one does not unless
asked. The manifest is the product here — `Ajt.instantiate()` is the command
that makes the depot match it, and it is one call away.
"""
function resolve(; io::IO = stderr, install::Bool = false, kwargs...)
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && (reason = _source_reason(dir::String))
    if reason !== nothing
        _delegating(:resolve, reason)
        return Pkg.resolve(; io, kwargs...)
    end
    _hdr(io, :Resolving, "package versions...")
    argv = String["resolve", "--write", "--preserve", "all"]
    append!(argv, _julia_args())
    push!(argv, dir::String)
    out, code = _run(argv)
    code == 0 || _failed(io, "resolve", out, code)
    _render_env(io, out)
    install && _install(io, dir::String)
    return nothing
end

"""
    _instantiate(io, dir; update_registry = true, verbose = false, precompile = true)
    generate(path; io = stderr)

Scaffold a package at `path` — `ajt generate`.

**Two files, and nothing else**: `path/Project.toml` and `path/src/<Pkg>.jl`.
That is all `Pkg.generate` writes too (`generate.jl`), and it is worth saying out
loud because every other Julia scaffolder writes six more. `PkgTemplates.jl` is
the tool for that, as Pkg's own help says.

The package name is `basename(path)` with a trailing `.jl` chopped, and it must
satisfy `Base.isidentifier`. Returns `Dict(pkg => uuid)`, as Pkg's does.
"""
function generate(path::AbstractString; io::IO = stderr, kwargs...)
    reason = _kwreason(kwargs)
    # `Base.isidentifier` above ASCII is Julia's Unicode identifier tables, which
    # the binary does not carry — see `ops/generate.zig:isIdentifier`. Delegating
    # is the honest answer: Pkg has the tables and this is not a hot path.
    if reason === nothing && !all(isascii, basename(String(path)))
        reason = "the package name is not ASCII, and `Base.isidentifier` for one needs Julia's own Unicode tables"
    end
    if reason !== nothing
        _delegating(:generate, reason)
        return Pkg.generate(String(path); io, kwargs...)
    end
    out, code = _run(String["generate", String(path)])
    code == 0 || _failed(io, "generate", out, code)
    return _render_generate(io, out)
end

"""
Render `ajt generate`'s report as `Pkg.generate` prints it, and return what
`Pkg.generate` returns.

`printpkgstyle(io, :Generating, " project \$pkg:")` (`generate.jl:9`) pads the
command to `_INDENT` and then prints a text that begins with a space of its own
— which is why Pkg's output has two spaces before `project`, and why passing
`" project …"` to `_hdr` rather than `"project …"` is not a typo. The file lines
are `genfile`'s (`:17`): four spaces and `Base.contractuser`.
"""
function _render_generate(io::IO, out::AbstractString)
    result = Dict{String, Base.UUID}()
    for fields in _records(out)
        if fields[1] == "generated" && length(fields) >= 3
            _hdr(io, :Generating, " project $(fields[2]):")
            result[String(fields[2])] = Base.UUID(fields[3])
        elseif fields[1] == "file" && length(fields) >= 2
            println(io, "    ", Base.contractuser(String(fields[2])))
        end
    end
    return result
end

"""
    compat(pkg, [spec]; io = stderr)

Set one `[compat]` bound and re-resolve to check the environment still complies
— `ajt compat`. With no `spec`, the entry is **deleted**.

`"Julia"` is normalised to `"julia"`; the package must otherwise be in `[deps]`.
A resolve that fails afterwards is reported and the bound is kept — that is
Pkg's behaviour (`API.jl:1532-1543`) and the point of the command: tightening a
bound the manifest is above is exactly how you find out you need `update`.

`Ajt.compat()` with no arguments delegates. Pkg's zero-argument form is a
hand-rolled raw-mode line editor over a menu of the project's dependencies, and
it refuses to run outside a fancy terminal in any case.
"""
function compat(
        pkg::AbstractString, spec::Union{AbstractString, Nothing} = nothing;
        io::IO = stderr, kwargs...
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && (reason = _source_reason(dir::String))
    if reason !== nothing
        _delegating(:compat, reason)
        return spec === nothing ? Pkg.compat(String(pkg); io, kwargs...) :
            Pkg.compat(String(pkg), String(spec); io, kwargs...)
    end
    argv = String["compat", "--project", dir::String]
    append!(argv, _julia_args())
    push!(argv, String(pkg))
    # An EMPTY spec is not the same argument as no spec at the shell, even
    # though Pkg collapses the two (`API.jl:1524`) — push it so the binary's
    # own `strip`/`isempty` handling is the one that decides.
    spec === nothing || push!(argv, String(spec))
    out, code = _run(argv)
    code == 0 || _failed(io, "compat", out, code)
    _render_env(io, out)
    return nothing
end

"""
The interactive editor, which is Pkg's and stays Pkg's. Also the arm a
`Context` first argument lands on: a caller who built one means that one.
"""
function compat(args...; kwargs...)
    _delegating(:compat, "the interactive [compat] editor is a terminal menu")
    return Pkg.compat(args...; kwargs...)
end

"""
    _instantiate(io, dir; update_registry = true, verbose = false)

`ajt instantiate --frozen` over a known-good environment directory: the shared
body of [`instantiate`](@ref) and of the install step `add`/`up` run afterwards.

`precompile = false` is what the install step passes. `Pkg.instantiate` takes
the same argument under the name `allow_autoprecomp` and every one of Pkg's own
internal callers passes `false` for it (`API.jl:1249`, `Operations.jl:1335`,
`:2395`, `:2438`) — a nested instantiate never precompiles, because the verb
that nested it is about to.
"""
function _instantiate(
        io::IO, dir::AbstractString;
        update_registry::Bool = true, verbose::Bool = false, precompile::Bool = true
    )
    argv = String["instantiate", "--frozen"]
    # `if-missing` is the binary's default and matches `update_registry = true`
    # closely enough to be the same thing: the registry is only consulted for a
    # fallback download URL, never to change the solution.
    update_registry || append!(argv, String["--registry-policy", "never"])
    precompile || push!(argv, "--no-precompile")
    append!(argv, _julia_args())
    push!(argv, String(dir))
    out, code = _run(argv)
    code == 0 || _failed(io, "instantiate", out, code)
    # `verbose` means the binary's own report, unfiltered — a warm depot is one
    # `present` line per package, which the renderer drops and a debugging
    # session wants.
    verbose ? print(io, out) : _render_instantiate(io, out)
    return nothing
end

# The install step of `add`/`up`/`resolve`. Separate from `_instantiate` only so
# the intent reads at the call site — and now for a second reason: it is the one
# nested instantiate in this file, so it is the one that must NOT precompile.
# `ajt add` and `ajt up` already did, and `Ajt.resolve` matches `Pkg.resolve`,
# which reaches `API.up(ctx; ...)` directly (`API.jl:455-457`) and so misses the
# `_auto_precompile` in the generated wrapper entirely.
_install(io::IO, dir::AbstractString) = _instantiate(io, dir; precompile = false)

"""
    instantiate(; io = stderr)

Make the depot satisfy the manifest — `ajt instantiate --frozen`: registry,
packages, artifacts, manifest fixups, a verify pass, then precompilation.

The manifest is authoritative and is never re-resolved. One thing Pkg does that
this does not: run `deps/build.jl`.

The precompile pass is `Pkg._auto_precompile` (`API.jl:1398`) and obeys
`JULIA_PKG_PRECOMPILE_AUTO` the same way — see `Ajt.DIFFERENCES[:instantiate]`
for the half of `should_autoprecompile()` that does not survive being in a
separate process.
"""
function instantiate(;
        io::IO = stderr, manifest::Union{Bool, Nothing} = nothing,
        update_registry::Bool = true, verbose::Bool = false, kwargs...
    )
    dir, reason = _env()
    reason === nothing && (reason = _kwreason(kwargs))
    reason === nothing && manifest === false && (reason = "`manifest = false` asks for a resolve, not an instantiate")
    # No manifest at all means the same thing as `manifest = false` — Pkg treats
    # the two identically (`API.jl:1309`) and resolves first. `--frozen` cannot:
    # its whole contract is that the manifest is authoritative, and with no file
    # to be authoritative about it stops with `blocked`.
    if reason === nothing && manifest !== true && dir !== nothing && !isfile(joinpath(dir, "Manifest.toml"))
        reason = "there is no Manifest.toml, so this asks for a resolve first"
    end
    if reason !== nothing
        _delegating(:instantiate, reason)
        return Pkg.instantiate(; io, manifest, update_registry, verbose, kwargs...)
    end
    return _instantiate(io, dir::String; update_registry, verbose)
end

"""
    verify(; io = stdout, check_hashes = false) -> Bool

Is this environment already fully instantiated? — `ajt verify --frozen`. Reads
only: it never resolves, downloads or writes.

Ajt's own; `Pkg`'s nearest equivalent is the internal `is_manifest_current`,
which answers a narrower question (does the manifest match the project's hash)
and does not look at the depot at all.
"""
function verify(; io::IO = stdout, check_hashes::Bool = false)
    dir, reason = _env()
    reason === nothing || Pkg.Types.pkgerror("Ajt.verify: $reason")
    args = String["verify", "--frozen"]
    check_hashes && push!(args, "--check-hashes")
    append!(args, _julia_args())
    push!(args, dir::String)
    out, code = _run(args)
    print(io, out)
    # The exit code cannot carry the answer: `main` returns `!void`, so every
    # internal error also exits 1 (`main.zig:340`) and only `NoDepot` gets its
    # own code. "not instantiated" and "the run broke" would be the same value,
    # and a broken run must never read as a confident `false`.
    startswith(out, "ok ") && return true
    startswith(out, "NOT INSTANTIATED") && return false
    return Pkg.Types.pkgerror("`ajt verify` did not answer (exit $code)")
end

"""
    is_manifest_current(path::AbstractString) -> Union{Bool,Nothing}

Was the manifest for the project at `path` resolved from the current project
file? — `ajt manifest current`.

**Three** answers, and the third is the whole point:

* `true` — the manifest records this project's `project_hash`.
* `false` — it records a *different* one. A `[deps]` or `[compat]` edit landed
  and nothing re-resolved.
* `nothing` — it records none, or there is no manifest file at all. Pkg's own
  callers test `=== false` (`API.jl:1321`, `Operations.jl:3059`), i.e. they read
  `nothing` as "carry on", and so must yours: it is not a stale environment, it
  is one that never wrote a hash to compare against.

Same signature as `Pkg.is_manifest_current`, which has **no** zero-argument
method (`API.jl:566-574`) — pass `pwd()` for the current project.
"""
function is_manifest_current(path::AbstractString)
    argv = String["manifest", "current"]
    append!(argv, _julia_args())
    push!(argv, String(path))
    out, code = _run(argv)
    for fields in _records(out)
        (fields[1] == "manifest_current" && length(fields) >= 2) || continue
        fields[2] == "true" && return true
        fields[2] == "false" && return false
        fields[2] == "nothing" && return nothing
    end
    # Exit 3 (no project file, unparseable file, a [workspace]) lands here, as
    # does anything that broke. Pkg raises for the first of those too
    # ("could not find project file at `$path`"), and a broken run must never
    # read as a confident `false` OR as a `nothing` — both are answers.
    return _failed(stderr, "manifest current", out, code)
end

# No `kwargs...`: `Pkg.is_manifest_current(ctx::Context)` takes none
# (`API.jl:566`), and advertising a signature Pkg does not have is how a
# drop-in accepts a call that would have been a MethodError and then does
# something else with it.
function is_manifest_current(ctx::Pkg.Types.Context)
    _delegating(:is_manifest_current, "called with an explicit `Pkg.Types.Context`")
    return Pkg.is_manifest_current(ctx)
end

"""
    upgrade_manifest()
    upgrade_manifest(manifest_path::AbstractString)

Migrate a v1 manifest to the v2 format without re-resolving — `ajt manifest
upgrade`. With no argument, the active environment's.

It changes `manifest_format` and nothing else. In particular it does **not**
record a `project_hash` or a `julia_version` — a v1 manifest has neither and the
upgraded one still has neither, which is why Pkg's own advice is to follow this
with `Pkg.resolve()` (`manifest.jl:383-386`). It does not prune or re-resolve
either.

Not idempotent, and that is Pkg's behaviour rather than a limitation: an
already-v2 manifest raises (`API.jl:1717-1719`) instead of being rewritten, so
the file keeps its bytes and its mtime.
"""
function upgrade_manifest(man_path::AbstractString; io::IO = stderr)
    argv = String["manifest", "upgrade"]
    # NOT optional, and the reason is a file this would otherwise rewrite by
    # mistake. `Base.manifest_names` puts `Manifest-v<major>.<minor>.toml` AHEAD
    # of `Manifest.toml` (`base/loading.jl:631-636`), and the binary can only
    # build that name from `--julia-version` or a `--julia-prefix` stdlib
    # directory. Without them an environment carrying both files resolves to the
    # plain `Manifest.toml` — the one the loader never reads — and a v1 file
    # there would be silently upgraded while the real manifest stayed v1.
    append!(argv, _julia_args())
    push!(argv, String(man_path))
    out, code = _run(argv)
    code == 0 || _failed(io, "manifest upgrade", out, code)
    for fields in _records(out)
        if fields[1] == "manifest" && length(fields) >= 5 && fields[2] == "upgraded"
            _hdr(
                io, :Updated,
                "Format of manifest file at `$(fields[3])` updated from " *
                    "v$(VersionNumber(fields[4]).major).$(VersionNumber(fields[4]).minor) to v2.0"
            )
        end
    end
    return nothing
end

function upgrade_manifest(; io::IO = stderr)
    dir, reason = _env()
    if reason !== nothing
        _delegating(:upgrade_manifest, reason)
        return Pkg.upgrade_manifest()
    end
    # A DIRECTORY, not a file: `ajt manifest upgrade` takes either, and handing
    # it the directory is what makes the `manifest = "…"` redirect in
    # Project.toml resolve — the same file `Pkg.upgrade_manifest(ctx)` would
    # have picked through `ctx.env.manifest_file`.
    return upgrade_manifest(dir::String; io)
end

# Likewise: `Pkg.upgrade_manifest(ctx::Context = Context())` takes no keywords
# (`API.jl:1715`).
function upgrade_manifest(ctx::Pkg.Types.Context)
    _delegating(:upgrade_manifest, "called with an explicit `Pkg.Types.Context`")
    return Pkg.upgrade_manifest(ctx)
end

"""
    gc(; collect_delay = Dates.Day(7), verbose = false, force = false, io = stderr)

Delete depot content that no live environment can reach — `ajt gc`.

The reachability roots are the usage logs under `<depot>/logs/`, which is where
`Ajt.instantiate` and `Pkg` alike record every `Manifest.toml` and
`Artifacts.toml` they touch. A key that is no longer on disk is dead, and
anything under `packages/`, `clones/`, `artifacts/` or `scratchspaces/` that no
live key reaches is orphaned.

**Nothing is deleted the first time it is seen orphaned.** That run records it
in `<depot>/logs/orphaned.toml` with the current time, and only a later run —
once it has been orphaned for `collect_delay` — removes it. So a first
`Ajt.gc()` over a depot that has never been collected reports nothing deleted,
and that is correct rather than a failure. `collect_delay = Dates.Hour(0)` is
what `pkg> gc --all` passes, and it collects immediately.

Only `Pkg.depots1()` — the first entry of `DEPOT_PATH` — is swept, unless
`force = true`. Pkg's REPL does not expose `force` at all, and the reason is
worth keeping in mind: a stacked `JULIA_DEPOT_PATH` usually has a read-only
image depot behind the writable one.
"""
function gc(;
        collect_delay::Dates.Period = Dates.Day(7), verbose::Bool = false,
        force::Bool = false, io::IO = stderr, kwargs...,
    )
    reason = _kwreason(kwargs)
    if reason !== nothing
        _delegating(:gc, reason)
        return Pkg.gc(; collect_delay, verbose, force, kwargs...)
    end
    # Rounded UP, so a `Millisecond(1)` delay becomes one second rather than
    # zero. Erring the other way would turn "keep it a moment longer" into
    # "collect it now", which is not a rounding error anyone can undo.
    secs = cld(Dates.value(Dates.Millisecond(collect_delay)), 1000)
    argv = String["gc", "--collect-delay", string(secs)]
    force && push!(argv, "--force")
    verbose && push!(argv, "--verbose")
    out, code = _run(argv)
    code == 0 || _failed(io, "gc", out, code)
    _render_gc(io, out, verbose)
    return nothing
end

# `Pkg.gc(ctx::Context)` exists, and a `Context` carries a resolved environment
# the binary has no way to be handed. Delegating is the honest answer; silently
# ignoring it would collect against a DIFFERENT depot than the caller asked for.
function gc(ctx::Pkg.Types.Context; kwargs...)
    _delegating(:gc, "an explicit `Context` names an environment the binary cannot be given")
    return Pkg.gc(ctx; kwargs...)
end

"""
Render `ajt gc`'s report. Shaped after Pkg's `print_deleted` (`API.jl:1153-1163`)
including its "nothing at all" line, because the *absence* of deletions is the
single most common outcome and a command that printed nothing would read as a
command that failed.
"""
function _render_gc(io::IO, out::AbstractString, verbose::Bool)
    deleted_any = false
    for fields in _records(out)
        kind = fields[1]
        if verbose && kind in ("deleted", "planned", "failed") && length(fields) >= 4
            mark = kind == "failed" ? "!" : "-"
            println(io, "   ", mark, " ", _pathrepr(fields[4]),
                " (", Base.format_bytes(parse(Int, fields[3])), ")")
        elseif kind == "total" && length(fields) >= 4
            n = parse(Int, fields[3])
            n == 0 && continue
            deleted_any = true
            _hdr(io, :Deleted, "$n $(fields[2])$(n == 1 ? "" : "s") " *
                "($(Base.format_bytes(parse(Int, fields[4]))))")
        end
    end
    deleted_any || _hdr(io, :Deleted, "no artifacts, repos, packages or scratchspaces")
    return nothing
end

"""
    tree_hash(dir) -> String

The git tree hash of a directory: what a registry's `git-tree-sha1` pins and what
a manifest entry records — `ajt tree-hash`.

Ajt's own. Pkg's equivalent is the internal `Pkg.GitTools.tree_hash`, which
returns bytes; this returns the 40-character hex string that appears in the
files.
"""
function tree_hash(dir::AbstractString)
    out, code = _run(String["tree-hash", String(dir)])
    code == 0 || Pkg.Types.pkgerror("`ajt tree-hash` failed (exit $code)")
    fields = split(chomp(out))
    isempty(fields) && Pkg.Types.pkgerror("`ajt tree-hash` printed nothing for $dir")
    fields[1] == "ERROR" && Pkg.Types.pkgerror("`ajt tree-hash` could not read $dir")
    return String(fields[1])
end

"""
    project_hash([project_file]) -> String

The hash Pkg records as `project_hash` in a manifest — `ajt project-hash`.
Defaults to the active project. Ajt's own; Pkg's equivalent is internal.
"""
function project_hash(project_file::AbstractString = something(Base.active_project(), ""))
    isempty(project_file) && Pkg.Types.pkgerror("Ajt.project_hash: there is no active project")
    out, code = _run(String["project-hash", String(project_file)])
    code == 0 || Pkg.Types.pkgerror("`ajt project-hash` failed (exit $code)")
    fields = split(chomp(out))
    isempty(fields) && Pkg.Types.pkgerror("`ajt project-hash` printed nothing for $project_file")
    return String(fields[1])
end

#############################
#  Pkg's argument families  #
#############################

# `API.jl:154-196` generates the same family for every package-taking entry
# point, and code in the wild uses all of it: `add("Foo")`, `add(["A","B"])`,
# `add(name = "Foo", version = "1.2")`, `add([(name = "A",)])`. A drop-in that
# only accepted `Vector{PackageSpec}` would fail at the first call site.
for f in (:add, :build, :rm, :test, :update, :why, :pin, :free, :develop, :status)
    @eval begin
        # Note for `develop`: `develop("Foo")` builds `PackageSpec(name="Foo")`
        # with no `path`, which means "clone the registered package Foo into
        # devdir()" — so it delegates, correctly. Reading a bare name as a
        # directory here would develop the wrong thing without saying so.
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...) = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        $f(pkgs::Vector{<:NamedTuple}; kwargs...) = $f([PackageSpec(; pkg...) for pkg in pkgs]; kwargs...)
        function $f(;
                name::Union{Nothing, AbstractString} = nothing,
                uuid::Union{Nothing, String, Base.UUID} = nothing,
                version::Union{VersionNumber, String, Pkg.Versions.VersionSpec, Nothing} = nothing,
                url = nothing, rev = nothing, path = nothing, mode = PKGMODE_PROJECT,
                subdir = nothing, kwargs...
            )
            # `API.jl:184` — only these three take `mode`, and dropping it
            # would make `status(name = "Foo", mode = PKGMODE_MANIFEST)` report
            # on the project.
            if $f === rm || $f === update || $f === status
                kwargs = merge((; kwargs...), (:mode => mode,))
            end
            if all(isnothing, (name, uuid, version, url, rev, path, subdir))
                return $f(PackageSpec[]; kwargs...)
            end
            return $f(PackageSpec(; name, uuid, version, url, rev, path, subdir); kwargs...)
        end
        # A `Context` positional is Pkg's internal entry point; nothing here can
        # honour one, so it goes straight back to Pkg rather than being dropped.
        function $f(ctx::Pkg.Types.Context, args...; kwargs...)
            _delegating($(QuoteNode(f)), "called with an explicit `Pkg.Types.Context`")
            return Pkg.$f(ctx, args...; kwargs...)
        end
    end
end

for f in (:resolve, :instantiate)
    @eval function $f(ctx::Pkg.Types.Context; kwargs...)
        _delegating($(QuoteNode(f)), "called with an explicit `Pkg.Types.Context`")
        return Pkg.$f(ctx; kwargs...)
    end
end

##############
#  Registry  #
##############

"""
    Ajt.Registry

`Pkg.Registry`'s public surface: `add`, `rm`, `status`, `update`.

`add` and `update` are native — installing a registry is a download and an
atomic swap on disk, and the binary does both. `status` and `rm` delegate:
`status`'s product is its printed table (and `ajt registry status` prints a
different, single-registry summary — reachable as `Ajt.Registry.summary()`), and
`rm` is depot surgery the binary does not do yet.
"""
module Registry

import Pkg
import ..Ajt
using Pkg: RegistrySpec

const DELEGATED = Dict{Symbol, String}(
    :rm => "removing a registry is depot surgery `ajt` does not do yet",
    :status => "the printed table IS the product; `ajt registry status` prints a different one",
)

for name in sort!(collect(keys(DELEGATED)))
    @eval function $name(args...; kwargs...)
        Ajt._delegating(Symbol("Registry.", $(QuoteNode(name))), DELEGATED[$(QuoteNode(name))])
        return Pkg.Registry.$name(args...; kwargs...)
    end
end

const NATIVE = Symbol[:Registry, :add, :update]

"""
    _args(regs) -> (args, reason)

A `RegistrySpec` the binary can act on carries a name, and optionally a uuid
(`--uuid`) or a url (`--url`). A `path` or `linked` is a source kind
`ajt registry add` has no flag for, so it delegates.

`--uuid` is a *single* option that the binary applies to every name it was given
(`main.zig:918-921` is last-wins, `1332-1339` uses that one uuid per name), so
more than one uuid in a call cannot be expressed — and emitting it anyway would
fetch one registry under another's identity. That is the kind of wrong that only
shows up much later, in someone else's depot.
"""
function _args(regs::Vector{RegistrySpec})
    names = String[]
    uuid = nothing
    url = nothing
    for reg in regs
        reg.path === nothing || return (nothing, "a registry was given by path")
        reg.linked === nothing || return (nothing, "a registry was given as `linked`")
        if reg.uuid !== nothing
            uuid === nothing || return (nothing, "more than one registry uuid in a single call")
            length(regs) == 1 || return (nothing, "a uuid together with more than one registry")
            uuid = reg.uuid
        end
        # `--url` is one option applied to the whole invocation, exactly like
        # `--uuid`, so the same single-value rule holds. Emitting one url for
        # several registries would clone the same repository under each name.
        if reg.url !== nothing
            url === nothing || return (nothing, "more than one registry url in a single call")
            length(regs) == 1 || return (nothing, "a url together with more than one registry")
            url = reg.url
        end
        reg.name === nothing ?
            ((uuid === nothing && url === nothing) &&
             return (nothing, "a registry was given with neither a name, a uuid nor a url")) :
            push!(names, String(reg.name))
    end
    args = String[]
    uuid === nothing || append!(args, String["--uuid", string(uuid)])
    url === nothing || append!(args, String["--url", string(url)])
    return (append!(args, names), nothing)
end

for (f, sub) in ((:add, "add"), (:update, "update"))
    @eval begin
        function $f(regs::Vector{RegistrySpec}; io::IO = stderr, kwargs...)
            reason = Ajt._kwreason(kwargs)
            args, argreason = reason === nothing ? _args(regs) : (nothing, reason)
            if args === nothing
                Ajt._delegating(Symbol("Registry.", $(QuoteNode(f))), something(argreason, "unsupported registry spec"))
                # `io` is a named keyword here, so it is not in `kwargs` and has
                # to be forwarded explicitly — Pkg's own takes one, and dropping
                # it would print to stderr for a caller who asked for devnull.
                return Pkg.Registry.$f(regs; io, kwargs...)
            end
            argv = String["registry", $sub]
            append!(argv, args)
            out, code = Ajt._run(argv)
            # `registry add`/`update` print an aligned key/value block, not the
            # tab-separated records the environment commands emit, so it is
            # passed through as-is rather than re-rendered into something less
            # readable.
            print(io, out)
            code == 0 || Pkg.Types.pkgerror("`ajt registry $($sub)` failed (exit $code)")
            return nothing
        end
        $f(reg::Union{AbstractString, RegistrySpec}; kwargs...) = $f([reg]; kwargs...)
        $f(regs::Vector{<:AbstractString}; kwargs...) = $f([RegistrySpec(r) for r in regs]; kwargs...)
        # The keyword family Pkg has (`Registry/Registry.jl:46-51`). Without it
        # `Registry.add(name = "General")` — one of Pkg's own documented forms —
        # lands in `kwargs` and then hits `Pkg.Registry.add(::Vector{RegistrySpec};
        # io, depots)`, the one entry point with no `kwargs...`, as a MethodError.
        # With no arguments at all it means "the default registries", which for
        # the binary is General.
        function $f(;
                name::Union{Nothing, AbstractString} = nothing,
                uuid::Union{Nothing, AbstractString, Base.UUID} = nothing,
                url = nothing, path = nothing, linked = nothing, kwargs...
            )
            if all(isnothing, (name, uuid, url, path, linked))
                return $f(RegistrySpec[RegistrySpec("General")]; kwargs...)
            end
            return $f([RegistrySpec(; name, uuid, url, path, linked)]; kwargs...)
        end
    end
end

"""
    summary(; io = stdout, registry = "General")

`ajt registry status`: the installed registry's uuid, depot, package count and
which backend answered (the `.aix` index or the tarball). Ajt's own — it is not
what `Pkg.Registry.status()` prints.
"""
function summary(; io::IO = stdout, registry::AbstractString = "General")
    out, code = Ajt._run(String["registry", "status", "--registry", String(registry)])
    print(io, out)
    code == 0 || Pkg.Types.pkgerror("`ajt registry status` failed (exit $code)")
    return nothing
end

"""
    conformance(surface = names(Pkg.Registry))

The same ratchet check as `Ajt.conformance`, for the `Registry` submodule.
"""
function conformance(surface::Vector{Symbol} = names(Pkg.Registry))
    accounted = Set{Symbol}(NATIVE)
    union!(accounted, keys(DELEGATED))
    unaccounted = Symbol[n for n in surface if !(n in accounted)]
    undefined = Symbol[n for n in sort!(collect(accounted)) if !isdefined(@__MODULE__, n)]
    return (; unaccounted, undefined)
end

end # module Registry

##########
#  Apps  #
##########

"""
Apps installed as executables in `<depot>/bin`, from a package's `[apps]`
section — `Pkg.Apps`.

`develop`, `rm` and `status` are native. `add` and `update` delegate: both begin
with a registry lookup and a download, and the binary's `app` verb starts after
that (see `Ajt.DIFFERENCES[:Apps]`).

One deliberate difference from `Pkg.Apps`, and it is a *fix*: the Windows `.bat`
shim Pkg writes stores `julia_cmd` already quoted and then quotes it again at
the call site, so the app cannot start at all when the depot path contains a
space (JuliaLang/Pkg.jl#4741). Ajt stores it unquoted. The POSIX shim and
`AppManifest.toml` are byte-identical to Pkg's.
"""
module Apps

import Pkg
import ..Ajt
using Pkg.Types: PackageSpec

public add, develop, rm, status, update

const DELEGATED = Dict{Symbol, String}(
    :add => "installing from a registry needs a version solve and a download before any app work begins; `ajt app` starts after that",
    :update => "same as `add`: it re-resolves each app environment against the registry",
)

for name in sort!(collect(keys(DELEGATED)))
    @eval function $name(args...; kwargs...)
        Ajt._delegating(Symbol("Apps.", $(QuoteNode(name))), DELEGATED[$(QuoteNode(name))])
        return Pkg.Apps.$name(args...; kwargs...)
    end
end

# `:Apps` is the module's own name, which `names(Pkg.Apps)` returns alongside
# its public functions — same as `:Registry` in the sibling submodule.
const NATIVE = Symbol[:Apps, :develop, :rm, :status]

"""
    _path(pkg) -> (path, reason)

The binary's `app dev` takes a local PATH. Anything else — a url, a rev, a
registered name — is `handle_repo_develop!`'s job and delegates.
"""
function _path(pkg::PackageSpec)
    pkg.path === nothing && return (nothing, "`develop` without a local path looks the source up in a registry or clones it")
    pkg.repo.source === nothing || return (nothing, "a repository source together with a path")
    pkg.repo.rev === nothing || return (nothing, "`develop` with a rev")
    pkg.repo.subdir === nothing || return (nothing, "`develop` with a subdir")
    return (String(pkg.path), nothing)
end

develop(pkg::AbstractString; kwargs...) = develop(PackageSpec(; path = String(pkg)); kwargs...)
develop(pkgs::Vector; kwargs...) = (foreach(p -> develop(p; kwargs...), pkgs); nothing)

# The keyword form `Pkg.Apps` generates at `Apps.jl:451-471`. Reproduced rather
# than inherited: it is the spelling the docs use (`Pkg.Apps.develop(path=".")`)
# and a wrapper that only took positionals would break every call written
# against Pkg.
function develop(;
        name::Union{Nothing, AbstractString} = nothing,
        uuid::Union{Nothing, AbstractString, Base.UUID} = nothing,
        version = nothing, url = nothing, rev = nothing,
        path = nothing, subdir = nothing, kwargs...,
    )
    return develop(PackageSpec(; name, uuid, version, url, rev, path, subdir); kwargs...)
end
develop(pkgs::Vector{<:NamedTuple}; kwargs...) =
    develop([PackageSpec(; pkg...) for pkg in pkgs]; kwargs...)

function develop(pkg::PackageSpec; io::IO = stdout)
    path, reason = _path(pkg)
    if path === nothing
        Ajt._delegating(:var"Apps.develop", reason)
        return Pkg.Apps.develop(pkg)
    end
    out, code = Ajt._run(String["app", "dev", path, "--julia", _julia()])
    code == 0 || return Ajt._failed(io, "app dev", out, code)
    return _render(io, out)
end

rm(name::AbstractString; kwargs...) = rm([name]; kwargs...)
rm(pkg::PackageSpec; kwargs...) = rm([something(pkg.name, "")]; kwargs...)
function rm(names::Vector; io::IO = stdout)
    args = String["app", "rm"]
    for n in names
        push!(args, n isa PackageSpec ? String(something(n.name, "")) : String(n))
    end
    push!(args, "--julia")
    push!(args, _julia())
    out, code = Ajt._run(args)
    code == 0 || return Ajt._failed(io, "app rm", out, code)
    return _render(io, out)
end

status(pkg_or_app::AbstractString; kwargs...) = status([pkg_or_app]; kwargs...)
status(pkg::PackageSpec; kwargs...) = status([something(pkg.name, "")]; kwargs...)
function status(pkgs_or_apps::Vector = String[]; io::IO = stdout)
    args = String["app", "status"]
    isempty(pkgs_or_apps) || push!(args, String(first(pkgs_or_apps)))
    push!(args, "--julia")
    push!(args, _julia())
    out, code = Ajt._run(args)
    code == 0 || return Ajt._failed(io, "app status", out, code)
    for line in eachline(IOBuffer(out))
        f = split(line, '\t')
        f[1] == "app" || continue
        printstyled(io, "[", f[4][1:8], "] "; color = :light_black)
        printstyled(io, f[2]; color = :green)
        printstyled(io, " ", Base.contractuser(f[5]), "\n"; color = :light_black)
    end
    return nothing
end

"""
`joinpath(Sys.BINDIR, "julia")` (`Apps.jl:184`) — the julia a shim will exec,
passed explicitly rather than left to the binary's `PATH` probe.

The two answers differ on a system where `PATH` reaches julia through a
symlink: the probe resolves it, `Sys.BINDIR` is already resolved, and the string
ends up baked into every shim and recorded in `AppManifest.toml`. Sending
Julia's own answer is what keeps the two tools' shims byte-identical.
"""
_julia() = joinpath(Sys.BINDIR, "julia" * (Sys.iswindows() ? ".exe" : ""))

function _render(io::IO, out::AbstractString)
    for line in eachline(IOBuffer(out))
        f = split(line, '\t')
        kind = f[1]
        if kind in ("installed", "developed", "removed", "unchanged") && length(f) >= 4
            mark = kind == "removed" ? "-" : kind == "unchanged" ? "=" : "+"
            Ajt._hdr(io, :Apps, "$mark $(f[2]) ($(f[3]))")
        elseif kind == "dropped_source" && length(f) >= 3
            @warn "Ignoring [sources] entry for $(f[2]): `$(f[3])` does not exist relative to the package"
        elseif kind == "warning" && length(f) >= 2 && f[2] == "bin_not_on_path"
            @warn """
            Apps were installed but `$(joinpath(first(DEPOT_PATH), "bin"))` is not on your PATH.
            Add it to run them by name.""" maxlog = 1
        end
    end
    return nothing
end

"""
    conformance(surface = names(Pkg.Apps))

The same ratchet check as `Ajt.conformance`, for the `Apps` submodule.
"""
function conformance(surface::Vector{Symbol} = names(Pkg.Apps))
    accounted = Set{Symbol}(NATIVE)
    union!(accounted, keys(DELEGATED))
    unaccounted = Symbol[n for n in surface if !(n in accounted)]
    undefined = Symbol[n for n in sort!(collect(accounted)) if !isdefined(@__MODULE__, n)]
    return (; unaccounted, undefined)
end

end # module Apps

##########
#  REPL  #
##########

include("REPLMode.jl")

"""
    pkg"add Foo"

Run a `pkg>`-mode command from Julia code, routed through Ajt. Same spelling as
`Pkg`'s `@pkg_str` (`REPLMode/REPLMode.jl:457-463`) so a script that uses it
keeps working; commands Ajt does not implement fall through to Pkg's own
handlers.
"""
macro pkg_str(str::String)
    return :($(REPLMode).pkgstr($str))
end

"""
    ajt"add Foo"

[`@pkg_str`](@ref) under a name that cannot collide with Pkg's, for code that
has both packages loaded.
"""
macro ajt_str(str::String)
    return :($(REPLMode).pkgstr($str))
end

function __init__()
    REPLMode.autoactivate!()
    # `JULIA_PKG_OFFLINE` is deliberately NOT read here: `OFFLINE_MODE` is
    # Pkg's own `Ref`, and `Pkg.__init__` (`Pkg.jl:827`) has already seeded it.
    # Re-reading would overwrite a `Pkg.offline(true)` made between the two
    # `__init__`s with the environment's answer.
    return nothing
end

end # module Ajt
