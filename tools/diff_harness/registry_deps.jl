# Oracle side of the registry differential gate.
#
# For each package name on the command line, prints every version followed by
# its UNCOMPRESSED dependency set and compat specs -- i.e. exactly what a
# resolver consumes. `ajt registry show` is normalised to the same shape.
#
# Usage: julia registry_deps.jl <Package>...

using Pkg

const JULIA_UUID = Base.UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

function dump_package(reg, name::String)
    entry = nothing
    for (_, pe) in reg.pkgs
        if pe.name == name
            entry = pe
            break
        end
    end
    if entry === nothing
        println("MISSING ", name)
        return
    end

    info = Pkg.Registry.registry_info(entry)
    Pkg.Registry.initialize_uncompressed!(info)

    # uncompressed_compat is keyed by UUID; map back to names for comparison.
    uuid2name = Dict{Base.UUID,String}(JULIA_UUID => "julia")
    for (_, d) in info.deps, (n, u) in d
        uuid2name[u] = n
    end
    for (_, d) in info.weak_deps, (n, u) in d
        uuid2name[u] = n
    end

    # The weak bit is part of what a resolver consumes, not decoration: a weak
    # edge does not force the dependency into the solution. Emitting it is what
    # lets this gate catch a reader that gets the dependency SET right and the
    # KIND wrong -- which is exactly what happened, and went unseen for as long
    # as the oracle printed only names and specs.
    #
    # The weak SET is `WeakDeps.toml`, NOT `weak_uncompressed_compat`. The
    # latter is built from `WeakCompat.toml`, so it silently omits a weakdep
    # that declares no weak compat, and it is left UNDEFINED rather than empty
    # on a version with none. Reading the set from the deps table is also what
    # Ajt does, and what `Operations.jl:732` consults.
    versions = sort(collect(keys(info.version_info)))
    weak_by_version = Pkg.Registry.uncompress(info.weak_deps, versions)
    # WeakCompat.toml, uncompressed the same way. `weak_uncompressed_compat` is
    # not a substitute: it is keyed by UUID, absent for a weakdep that declares
    # no weak compat, and undefined entirely on versions with none.
    weak_compat_by_version = Pkg.Registry.uncompress(info.weak_compat, versions)

    println("== ", name)
    for v in versions
        vi = info.version_info[v]
        println(v)
        rows = String[]
        weak_names = keys(get(weak_by_version, v, Dict{String,Base.UUID}()))
        seen = Set{String}()
        for (u, spec) in vi.uncompressed_compat
            n = get(uuid2name, u, string(u))
            push!(seen, n)
            mark = n in weak_names ? "  (weak)" : ""
            push!(rows, string("    ", n, " ", sprint(print, spec), mark))
        end
        # A weak-only dependency has no entry in `uncompressed_compat` at all,
        # so it has to come from the weak table or the row goes missing.
        wc = get(weak_compat_by_version, v, nothing)
        for (n, _) in get(weak_by_version, v, Dict{String,Base.UUID}())
            n in seen && continue
            # No weak compat entry means no constraint, which renders as `*`.
            spec = (wc !== nothing && haskey(wc, n)) ? sprint(print, wc[n]) : "*"
            push!(rows, string("    ", n, " ", spec, "  (weak)"))
        end
        for r in sort(rows)
            println(r)
        end
    end
end

function main()
    reg = first(filter(r -> r.name == "General", Pkg.Registry.reachable_registries()))
    for name in ARGS
        dump_package(reg, name)
    end
end

main()
