# Oracle for `jicache.sh`: dumps `Base._parse_cache_header` /
# `Base.parse_cache_header` for every `.ji` in a list, in the exact
# tab-separated shape `jicache_dump.zig` emits.
#
# Everything printed here comes out of Base itself. Nothing is re-derived, so a
# disagreement is always ajt's, never a transcription's. The one exception is
# `isrelocatable_path`, which is `Base.isrelocatable`'s body verbatim with the
# `compilecache_path` lookup replaced by a path argument -- `Base.isrelocatable`
# takes a `PkgId` that must resolve in the active project, which is not true of
# an arbitrary file in the depot.
#
# usage: julia jicache_oracle.jl <list-file> [dump|flags|verify]

idtext(u) = u === nothing ? "-" : string(u)
nametext(s) = isempty(s) ? "-" : s
modpathtext(v) = isempty(v) ? "-" : join(v, ",")

function dump_flags(out)
    for r in 0:255, a in 0:255
        v = ccall(:jl_match_cache_flags, UInt8, (UInt8, UInt8), UInt8(r), UInt8(a))
        println(out, r, " ", a, " ", v)
    end
end

# `Base.isrelocatable` (loading.jl:1923-1941), body unchanged.
function isrelocatable_path(path)
    io = open(path, "r")
    try
        iszero(Base.isvalid_cache_header(io)) && return false
        _, (includes, includes_srcfiles, _), _... = Base._parse_cache_header(io, path)
        for inc in includes
            !startswith(inc.filename, "@depot") && return false
            if inc ∉ includes_srcfiles
                track_content = inc.mtime == -1.0
                track_content || return false
            end
        end
    finally
        close(io)
    end
    return true
end

function dump_one(out, path, verify_mode)
    println(out, "=== ", path)
    io = try
        open(path, "r")
    catch e
        println(out, "error\tread\t", typeof(e))
        return
    end
    local modules, includes, srcfiles, requires, reqmods, srctextpos, prefs, prefs_hash, clone_targets, flags
    try
        pkgimage = Ref{UInt8}(0)
        ds = Ref{Int64}(0)
        de = Ref{Int64}(0)
        checksum = ccall(:jl_read_verify_header, UInt64,
                         (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Int64}, Ptr{Int64}),
                         io.ios, pkgimage, ds, de)
        if iszero(checksum) || pkgimage[] != 0
            println(out, "error\tparse\tBadHeader")
            return
        end
        hdrpos = position(io)
        # The five identity strings are consumed by the ccall, so re-read them
        # from the bytes -- that is what ajt parses and what must be compared.
        seekstart(io)
        raw = read(io, hdrpos)
        p = 8                                   # magic
        fmt = reinterpret(UInt16, raw[p+1:p+2])[1]; p += 2
        p += 2                                  # BOM
        psize = raw[p+1]; p += 1
        strs = String[]
        for _ in 1:5
            e = findnext(isequal(0x00), raw, p + 1)
            push!(strs, String(raw[p+1:e-1]))
            p = e
        end
        # The two trailing Int64s are printed in FILE order, taken from the
        # bytes. The ccall's 3rd and 4th out-parameters arrive SWAPPED relative
        # to the file: for ArgTools/aGHFV_HGYMs.ji the file holds 832 then
        # 1277628, and the ccall reports arg3=1277628 (== srctextpos, i.e. the
        # end) and arg4=832 (the start). `Base.isvalid_cache_header` throws both
        # away, so nothing in Base ever notices. Asserted below so the claim
        # cannot rot.
        # Derived from hdrpos, not from the byte offsets this build happens to
        # produce: the five identity strings are variable-length, so 89/97 are
        # only right for a julia whose version and commit are these lengths.
        pos1 = reinterpret(Int64, raw[hdrpos-15:hdrpos-8])[1]
        pos2 = reinterpret(Int64, raw[hdrpos-7:hdrpos])[1]
        @assert (ds[], de[]) == (pos2, pos1) "jl_read_verify_header out-parameter order changed"
        println(out, "pre\t", fmt, "\t", psize, "\t", join(strs, "\t"), "\t", pkgimage[],
                "\t", string(checksum, base=16, pad=16), "\t", pos1, "\t", pos2, "\t", hdrpos)

        seekstart(io)
        Base.isvalid_cache_header(io)
        modules, (includes, srcfiles, requires), reqmods, srctextpos, prefs, prefs_hash,
            clone_targets, flags = Base._parse_cache_header(io, path)

        println(out, "flags\t", flags)
        for (id, bid) in modules
            println(out, "mod\t", idtext(id.uuid), "\t", string(bid, base=16, pad=32), "\t", nametext(id.name))
        end
        if !isempty(modules)
            full = (UInt128(checksum) << 64) | (modules[1].second % UInt64)
            println(out, "buildid\t", string(full, base=16, pad=32))
        end
        for inc in includes
            println(out, "inc\t", idtext(inc.id.uuid), "\t", nametext(inc.id.name), "\t",
                    inc.fsize, "\t", inc.hash, "\t",
                    string(reinterpret(UInt64, inc.mtime), base=16, pad=16), "\t",
                    (inc.filename in srcfiles ? "src" : "dep"), "\t",
                    modpathtext(inc.modpath), "\t", inc.filename)
        end
        for (from, to) in requires
            println(out, "req\t", idtext(from.uuid), "\t", nametext(from.name), "\t",
                    idtext(to.uuid), "\t", nametext(to.name))
        end
        for pref in prefs
            println(out, "pref\t", pref)
        end
        println(out, "prefshash\t", string(prefs_hash, base=16, pad=16))
        println(out, "srctextpos\t", srctextpos)
        for (id, bid) in reqmods
            println(out, "rmod\t", idtext(id.uuid), "\t", string(bid, base=16, pad=32), "\t", nametext(id.name))
        end
        println(out, "clone\t", length(clone_targets), "\t",
                string(Base._crc32c(clone_targets), base=16, pad=8))
        # `parse_image_targets` reads an Int32 unconditionally, so an EMPTY blob
        # is an EOFError, not zero targets. Julia never hits that because every
        # caller is guarded by `pkgimage = !isempty(clone_targets)`
        # (loading.jl:4001); a plain .ji built with --pkgimages=no has none.
        if !isempty(clone_targets)
            for t in Base.parse_image_targets(clone_targets)
                println(out, "ctarget\t", t.flags, "\t", length(t.features_en), "\t",
                        length(t.features_dis), "\t", t.ext_features, "\t", t.name)
            end
        end
        for s in sort(collect(srcfiles))
            println(out, "srcfile\t", s)
        end
        println(out, "reloc\t", Int(isrelocatable_path(path)))
        println(out, "mtimetracked\t", count(i -> i.mtime != -1.0, includes))
        seekstart(io)
        println(out, "filecrc\t", Int(Base.isvalid_file_crc(io)))
    catch e
        println(out, "error\tparse\t", typeof(e))
        return
    finally
        close(io)
    end

    if verify_mode
        modpath = isempty(includes) ? "" : first(Base.parse_cache_header(path)[2][1]).filename
        reasons = Dict{String,Int}()
        r = try
            Base.stale_cachefile(modpath, path; reasons)
        catch e
            "error"
        end
        if r === true
            println(out, "verdict\tstale\t", join(sort(collect(keys(reasons))), ","), "\t-")
        elseif r == "error"
            println(out, "verdict\terror\t-\t-")
        else
            println(out, "verdict\tfresh\t-\t-")
        end
    else
        # The public parse_cache_header, i.e. after @depot restoration.
        rinc = Base.parse_cache_header(path)[2][1]
        for inc in rinc
            println(out, "rinc\t", inc.filename)
        end
    end
end

# ---------------------------------------------------------------------------
# `corrupt` mode: build a clean copy and a copy with ONE include's recorded
# crc32c flipped, so both verifiers can be held against the same two files.
#
# The corrupted copy's trailing file crc32c is RECOMPUTED, so `isvalid_file_crc`
# still passes and the include hash is the only thing wrong. Without that the
# two sides would agree that something is broken without agreeing on what.
#
# The byte offset of the hash field is found by searching for a needle built
# out of values Base itself reported -- `Int32(length(name)) | name |
# UInt64(fsize)` -- rather than by re-deriving the record layout here.
# ---------------------------------------------------------------------------

function find_hash_offset(raw::Vector{UInt8}, name::String, fsize::UInt64, srctextpos::Int64)
    needle = UInt8[]
    append!(needle, reinterpret(UInt8, [Int32(sizeof(name))]))
    append!(needle, codeunits(name))
    append!(needle, reinterpret(UInt8, [fsize]))
    # Only the HEADER region. The source-text section repeats the identical
    # byte sequence -- `Int32 namelen | name | UInt64 len` -- and for an
    # `include()` file the stored length IS the fsize, so a whole-file search
    # finds two matches and cannot tell which record it is about to patch.
    region = @view raw[1:min(srctextpos, length(raw))]
    idx = findfirst(needle, region)
    idx === nothing && return nothing
    rest = findnext(needle, region, first(idx) + 1)
    rest === nothing || return nothing
    return last(idx) + 1   # 1-based index of the first hash byte
end

function do_corrupt(out, workdir, listfile)
    for line in eachline(listfile)
        path = String(strip(line))
        isempty(path) && continue
        so = Base.ocachefile_from_cachefile(path)
        isfile(so) || continue

        local includes, restored, srctextpos, prefs
        try
            io = open(path, "r")
            try
                iszero(Base.isvalid_cache_header(io)) && continue
                _, (includes, _, _), _, srctextpos, prefs, _... = Base._parse_cache_header(io, path)
            finally
                close(io)
            end
            isempty(includes) && continue
            restored = Base.parse_cache_header(path)[2][1]
        catch
            continue
        end
        isrelocatable_path(path) || continue
        # Skip subjects with compile-time preferences. `stale_cachefile`
        # computes the real `get_preferences_hash(uuid, prefs)` against the
        # active project; ajt's verifier is handed no environment here and would
        # compute 0, so such a subject makes the gate fail on a preferences
        # mismatch that has nothing to do with what it is testing. With an empty
        # prefs list both sides are 0 by construction and the check stays live.
        isempty(prefs) || continue

        clean = joinpath(workdir, "clean.ji")
        cp(path, clean; force=true)
        cp(so, joinpath(workdir, "clean.so"); force=true)
        chmod(clean, 0o644)
        chmod(joinpath(workdir, "clean.so"), 0o644)

        modpath = restored[1].filename
        reasons = Dict{String,Int}()
        r = Base.stale_cachefile(modpath, clean; reasons)
        if r === true
            # Not a usable candidate: julia rejects the pristine copy for some
            # unrelated reason, so a rejection of the corrupted one would prove
            # nothing.
            continue
        end

        raw = read(clean)
        off = find_hash_offset(raw, includes[1].filename, includes[1].fsize, srctextpos)
        off === nothing && continue

        bad = joinpath(workdir, "bad.ji")
        cp(clean, bad; force=true)
        cp(so, joinpath(workdir, "bad.so"); force=true)
        chmod(bad, 0o644)
        chmod(joinpath(workdir, "bad.so"), 0o644)

        braw = read(bad)
        old = reinterpret(UInt32, braw[off:off+3])[1]
        new = old ⊻ 0x00000001
        braw[off:off+3] = reinterpret(UInt8, [new])
        # Re-seal the file so only the include hash is wrong.
        crc = Base._crc32c(IOBuffer(braw[1:end-4]), length(braw) - 4)
        braw[end-3:end] = reinterpret(UInt8, [crc])
        write(bad, braw)

        badreasons = Dict{String,Int}()
        badr = Base.stale_cachefile(modpath, bad; reasons=badreasons)

        println(out, "source\t", path)
        println(out, "modpath\t", modpath)
        println(out, "include\t", includes[1].filename)
        println(out, "hashoffset\t", off)
        println(out, "clean\t", clean)
        println(out, "bad\t", bad)
        println(out, "julia_clean_stale\t0\t", join(sort(collect(keys(reasons))), ","))
        println(out, "julia_bad_stale\t", Int(badr === true), "\t",
                join(sort(collect(keys(badreasons))), ","))
        return
    end
    println(out, "nocandidate")
end

# ---------------------------------------------------------------------------
# `depot` mode: point DEPOT_PATH at a directory that contains nothing, so every
# `@depot` tag fails to resolve, and confirm Base rejects on exactly that.
#
# This is the safety property the whole optimistic-import design rests on: an
# unplaceable path is rejected by `any_includes_stale` (loading.jl:3919-3923),
# never guessed at, so a bad import can only ever cost a recompile.
# ---------------------------------------------------------------------------

function do_depot(out, listfile, emptydir)
    saved = copy(Base.DEPOT_PATH)
    empty!(Base.DEPOT_PATH)
    push!(Base.DEPOT_PATH, emptydir)
    try
        for line in eachline(listfile)
            path = String(strip(line))
            isempty(path) && continue
            io = open(path, "r")
            try
                iszero(Base.isvalid_cache_header(io)) && continue
                # With no depot to resolve against, parse_cache_header leaves
                # the @depot tags in place.
                _, (includes, _, _), _... = Base.parse_cache_header(io, path)
                reasons = Dict{String,Int}()
                stale = Base.any_includes_stale(includes, path, reasons)
                println(out, "depotcheck\t", path, "\t", Int(stale), "\t",
                        join(sort(collect(keys(reasons))), ","))
            finally
                close(io)
            end
        end
    finally
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, saved)
    end
end

function main()
    mode = length(ARGS) > 1 ? ARGS[2] : "dump"
    out = stdout
    if mode == "flags"
        dump_flags(out)
        return
    elseif mode == "corrupt"
        do_corrupt(out, ARGS[1], ARGS[3])
        return
    elseif mode == "depot"
        do_depot(out, ARGS[1], ARGS[3])
        return
    end
    for line in eachline(ARGS[1])
        path = strip(line)
        isempty(path) && continue
        dump_one(out, String(path), mode == "verify")
    end
end

main()
