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

    println("== ", name)
    for v in sort(collect(keys(info.version_info)))
        vi = info.version_info[v]
        println(v)
        rows = String[]
        for (u, spec) in vi.uncompressed_compat
            push!(rows, string("    ", get(uuid2name, u, string(u)), " ", sprint(print, spec)))
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
