"""
    Ajt.REPLMode

The `]` half of the drop-in: `pkg> add Foo` goes through Ajt, and anything Ajt
does not implement goes through Pkg — in the same prompt, in the same session,
with no way for the user to tell which commands are which except that the fast
ones are faster.

# Why this reuses Pkg's parser

`REPLMode/command_declarations.jl` declares 71 commands, each with its own
option specs, argument parser and `should_splat` rule. Re-implementing that
would mean re-implementing 71 command grammars in order to route seven of them
somewhere else — and every one of the other 64 would drift.

So the parse is Pkg's, unmodified: `prepare_cmd` produces `Command` objects, and
the only thing this module changes is the last step, where `do_cmd` looks at
`command.spec.api` — the function the parsed command would have called. If that
function has an Ajt equivalent, the equivalent runs; if not, the command is
handed to `Pkg.REPLMode.do_cmd` untouched (`REPLMode.jl:408-419`). A command Ajt
has never heard of therefore behaves exactly as it does under Pkg, including its
help text, its option errors and its completions.

# Installing the mode

`Pkg`'s `]` mode is built by an extension (`Pkg/ext/REPLExt`) at REPL startup.
Rather than build a competing mode with its own keymap, [`activate!`](@ref)
takes the existing one and replaces its `on_done` — the function the prompt
calls with the typed line. That leaves history, completions, the `;` shell
transition and the backspace-to-exit behaviour exactly as they were.
"""
module REPLMode

import Pkg
import ..Ajt

using Pkg.REPLMode: Command, prepare_cmd

"""
    DISPATCH :: IdDict

`Pkg` API function → the Ajt function that replaces it. Keyed by the function
*object* the command spec carries, not by the command name, because names have
aliases (`st`, `up`, `rm`, `remove`, …) and the specs do not.
"""
const DISPATCH = IdDict{Any, Any}(
    Pkg.API.add => Ajt.add,
    Pkg.API.build => Ajt.build,
    Pkg.API.test => Ajt.test,
    Pkg.API.rm => Ajt.rm,
    Pkg.API.up => Ajt.update,
    Pkg.API.status => Ajt.status,
    Pkg.API.resolve => Ajt.resolve,
    Pkg.API.instantiate => Ajt.instantiate,
    Pkg.API.why => Ajt.why,
    Pkg.API.generate => Ajt.generate,
    Pkg.API.compat => Ajt.compat,
    Pkg.API.gc => Ajt.gc,
    Pkg.Apps.develop => Ajt.Apps.develop,
    Pkg.Apps.rm => Ajt.Apps.rm,
    Pkg.Apps.status => Ajt.Apps.status,
    Pkg.Registry.add => Ajt.Registry.add,
    Pkg.Registry.update => Ajt.Registry.update,
    Pkg.Registry.status => Ajt.Registry.status,
    Pkg.Registry.rm => Ajt.Registry.rm,
)

"""
    do_cmd(command, io)

Run one parsed command, through Ajt where there is an Ajt path and through Pkg
where there is not.

`Pkg.REPLMode.TEST_MODE[]` is honoured with the same contract Pkg's own `do_cmd`
has (`REPLMode.jl:408-419`): return the `(api, arguments, options)` triple
instead of executing. That is what makes routing testable without a REPL, a
network or an environment to damage.
"""
function do_cmd(command::Command, io::IO)
    handler = get(DISPATCH, command.spec.api, nothing)
    # Not ours: `help` included, which Pkg's own `do_cmd` special-cases before
    # it ever looks at `spec.api`.
    handler === nothing && return Pkg.REPLMode.do_cmd(command, io)
    return if command.spec.should_splat
        Pkg.REPLMode.TEST_MODE[] ? (handler, command.arguments..., command.options) :
            handler(command.arguments...; collect(command.options)...)
    else
        Pkg.REPLMode.TEST_MODE[] ? (handler, command.arguments, command.options) :
            handler(command.arguments; collect(command.options)...)
    end
end

do_cmds(input::AbstractString, io::IO = stdout) = do_cmds(prepare_cmd(String(input)), io)

function do_cmds(commands::Vector{Command}, io::IO = stdout)
    # Pkg warns here that the REPL mode is not for scripts
    # (`REPLMode.jl:396-400`). Ajt does not: `pkgstr` is how this package's own
    # tests drive the parser, and a warning that fires on every test run is a
    # warning everyone learns to ignore.
    results = []
    for command in commands
        push!(results, do_cmd(command, io))
    end
    return Pkg.REPLMode.TEST_MODE[] ? results : nothing
end

"""
    pkgstr("add Foo")

Run a `pkg>` command line from code. The implementation behind `Ajt.@pkg_str`
and `Ajt.@ajt_str`, and the entry point the REPL prompt calls.
"""
pkgstr(str::String) = do_cmds(str)

########################
#  REPL mode take-over #
########################

# What was replaced, per prompt object, so `deactivate!` can put it back and so
# `activate!` is idempotent.
const _PATCHED = IdDict{Any, NamedTuple{(:on_done, :prompt), Tuple{Function, Any}}}()

"""
    _replext(repl) -> Union{Module,Nothing}

Pkg's REPL machinery lives in a package extension (`Pkg/ext/REPLExt`, Julia ≥
1.11), and in a running session that extension is usually **not loaded yet**:
Julia's REPL binds `]` to a placeholder mode and only loads Pkg + REPLExt the
first time somebody presses it (`REPL/src/REPL.jl:1330-1355`, `1430-1450`).

So this does what that keypress does. `REPL.load_pkg()`
(`REPL/src/Pkg_beforeload.jl:6`) is the exact call, and the REPL module itself
is reachable without depending on it — the live REPL object is one of its types.
Waiting for the user to press `]` instead would mean Pkg's extension builds the
`pkg>` mode at a moment nothing is watching, and the take-over never happens.

# Why the return value, and not `Base.get_extension`

`get_extension` answers `nothing` for a REPLExt that is **loaded and running**,
whenever that extension was loaded through `load_pkg()` — which is exactly what
pressing `]` does, so it is the answer in every session where the user reached
for Pkg before reaching for Ajt.

`load_pkg()` is `Base.require_stdlib(Pkg_pkgid, "REPLExt", REPL)`, and
`require_stdlib`'s bundled-depot path loads the module through
`_require_search_from_serialized` without ever registering it as a root module
(`base/loading.jl`). `get_extension` is a `maybe_root_module` lookup
(`loading.jl:1681-1685`), so it misses it. Calling `load_pkg()` and then asking
`get_extension` a second time — which is what this function used to do — threw
away the one answer that is always correct and reported failure instead.
`activate!` then took its `ext === nothing` branch, `autoactivate!` had asked
for that quietly, and `]` stayed on `pkg>` with nothing said.
"""
function _replext(repl = nothing)
    ext = Base.get_extension(Pkg, :REPLExt)
    ext === nothing || return ext
    repl === nothing && return nothing
    replmod = parentmodule(typeof(repl))
    if isdefined(replmod, :load_pkg)
        try
            loaded = replmod.load_pkg()
            loaded isa Module && return loaded
        catch err
            @debug "Ajt: REPL.load_pkg() failed" exception = err
        end
    end
    # Older/odd loaders: importing REPL into this environment triggers the
    # extension the ordinary way.
    try
        Base.require(Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL"))
    catch err
        @debug "Ajt: loading REPL failed" exception = err
    end
    return Base.get_extension(Pkg, :REPLExt)
end

"""
Every `pkg>` prompt in this REPL's interface.

Identified by its completion provider, which is how the REPL itself finds that
mode (`REPL/src/REPL.jl:1345`) — and it has to be, because [`activate!`](@ref)
*changes* the prompt string and a second call has to find the same object again.
"""
function _pkg_modes(repl, ext)
    isdefined(repl, :interface) || return Any[]
    return Any[m for m in repl.interface.modes if m isa ext.LineEdit.Prompt && m.complete isa ext.PkgCompletionProvider]
end

_promptf(ext) = replace(ext.promptf(), "pkg> " => "ajt> ")

function _do_cmds(repl, input::String, ext)
    return try
        do_cmds(prepare_cmd(input), repl.t.out_stream)
    catch err
        # `REPLExt.jl:111-124`: a PkgError is a diagnosis, not a bug in the
        # tool, so it is shown without a stack trace.
        if err isa Pkg.Types.PkgError || err isa Pkg.Resolve.ResolverError
            Base.display_error(repl.t.err_stream, ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

# `REPLExt.jl:126-135`, with our `do_cmds`.
function _on_done(s, buf, ok, repl, ext)
    REPL = ext.REPL
    ok || return REPL.transition(s, :abort)
    input = String(take!(buf))
    REPL.reset(repl)
    _do_cmds(repl, input, ext)
    REPL.prepare_next(repl)
    REPL.reset_state(s)
    s.current_mode.sticky || REPL.transition(s, repl.interface.modes[1])
    return nothing
end

"""
    activate!([repl]) -> Bool

Route the `]` prompt through Ajt. Idempotent, and reversible with
[`deactivate!`](@ref).

Returns `false` (with a warning) when there is nothing to take over: no REPL, no
`REPL` module loaded, or a Julia old enough that `Pkg/ext/REPLExt` does not
exist. It is deliberately not an error — `using Ajt` in a startup file must not
break a `julia -e` run that has no REPL at all.
"""
function activate!(repl = nothing; quiet::Bool = false)
    repl === nothing && (repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing)
    if repl === nothing
        quiet || @warn "Ajt: no active REPL to take over."
        return false
    end
    ext = _replext(repl)
    if ext === nothing
        quiet || @warn "Ajt: no `pkg>` mode to take over — Pkg's REPLExt could not be loaded."
        return false
    end
    modes = _pkg_modes(repl, ext)
    if isempty(modes)
        # Pkg's own hook has not built the mode yet. Building it here is safe:
        # `repl_init` is what that hook would have called.
        #
        # `invokelatest` because this branch is reached precisely when
        # `_replext` has just *loaded* REPLExt in this task: its methods are
        # then newer than the task's world age, and a plain call raises rather
        # than running. The `try` below would swallow that, and `quiet` would
        # hide it — the same shape of silent failure this whole path had.
        try
            Base.invokelatest(ext.repl_init, repl)
        catch err
            quiet || @warn "Ajt: could not create the `pkg>` mode" exception = err
            return false
        end
        modes = _pkg_modes(repl, ext)
    end
    isempty(modes) && return false
    for mode in modes
        haskey(_PATCHED, mode) && continue
        _PATCHED[mode] = (on_done = mode.on_done, prompt = mode.prompt)
        mode.on_done = (s, buf, ok) -> Base.@invokelatest _on_done(s, buf, ok, repl, ext)
        # The prompt says which tool is answering. A silent take-over of `]`
        # would be indistinguishable from Pkg right up until the two disagreed.
        mode.prompt = () -> _promptf(ext)
    end
    return true
end

"""
    deactivate!() -> Bool

Give `]` back to Pkg, prompt and all.
"""
function deactivate!()
    isempty(_PATCHED) && return false
    for (mode, saved) in _PATCHED
        mode.on_done = saved.on_done
        mode.prompt = saved.prompt
    end
    empty!(_PATCHED)
    return true
end

"""
    _activate_soon(repl)

Take over `repl` from a task, retrying while the REPL finishes standing itself
up, and say so once if it never does.

The task is not an optimisation. `Base.atreplinit` *prepends*
(`base/client.jl:372`), so hooks registered later run earlier, and the REPL is
not finished standing up while they run. A task runs at the first yield — the
read on stdin — which is after everything and still long before a human can
type.

Both callers share the retry *and* the warning. The immediate path used to have
neither: it took its one shot with `quiet = true`, and every way
[`activate!`](@ref) can answer `false` was therefore invisible. That is what
kept a real defect in [`_replext`](@ref) in the tree — the feature did nothing
and said nothing.
"""
function _activate_soon(repl)
    return Base.errormonitor(
        @async begin
            for _ in 1:40
                activate!(repl; quiet = true) && return nothing
                sleep(0.05)
            end
            # A REPL with no `interface` is not one Pkg's own extension can
            # build a mode in either (`REPLExt.jl:337-341` says as much), so
            # there is no take-over to have missed: `julia -i` with piped
            # stdin gets a `BasicREPL`, which has no `]` at all.
            hasfield(typeof(repl), :interface) || return nothing
            @warn "Ajt: could not take over the `pkg>` prompt; run `Ajt.REPLMode.activate!()` for the reason."
            return nothing
        end
    )
end

"""
Best-effort take-over at REPL startup, called from `Ajt.__init__`. Set
`AJT_REPL=0` to keep `]` on Pkg.

Two orderings are handled here, and both are the difference between the feature
working and doing nothing at all:

* `isinteractive()` is checked **inside** the hook, not around it, exactly as
  Pkg's own extension does (`REPLExt.jl:333-349`). A `using Ajt` in `startup.jl`
  — the intended way to install this — runs while `exec_options` is still
  processing arguments, before the REPL exists and therefore before
  `isinteractive()` is true. Guarding the registration would skip the one case
  it is for.
* An already-running REPL never fires another hook, so `using Ajt` typed at the
  prompt takes over through the immediate path instead.

Both go through [`_activate_soon`](@ref), which is where the retry and the one
warning live.
"""
function autoactivate!()
    get(ENV, "AJT_REPL", "1") == "0" && return nothing
    # Already at a prompt: no hook will ever fire again, so do it now.
    if isdefined(Base, :active_repl)
        _activate_soon(Base.active_repl)
        return nothing
    end
    Base.atreplinit() do repl
        isinteractive() || return nothing
        _activate_soon(repl)
        return nothing
    end
    return nothing
end

end # module REPLMode
