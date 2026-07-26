# Oracle side of the TOML round-trip gate.
#
# Reads a newline-separated file list and, for each entry, writes
# `TOML.print(TOML.parsefile(f); sorted=true)` to <outdir>/<index>.out.
#
# One process for the whole corpus on purpose: Julia's ~0.4s startup would
# otherwise dominate a 59,000-file run.
#
# Usage: julia oracle.jl <filelist> <outdir>

using TOML

function main()
    filelist, outdir = ARGS[1], ARGS[2]
    mkpath(outdir)
    files = readlines(filelist)
    failed = 0
    for (i, f) in enumerate(files)
        isempty(f) && continue
        try
            data = TOML.parsefile(f)
            open(joinpath(outdir, string(i, ".out")), "w") do io
                TOML.print(io, data; sorted = true)
            end
        catch e
            # A file the oracle itself cannot parse is not a fair comparison;
            # record it so the harness can exclude rather than fail on it.
            failed += 1
            open(joinpath(outdir, string(i, ".skip")), "w") do io
                println(io, sprint(showerror, e))
            end
        end
    end
    println("oracle: wrote ", length(files) - failed, " outputs, skipped ", failed)
end

main()
