#!/usr/bin/env julia
# Oracle side of tools/diff_harness/install_packages.sh.
#
# Everything printed here comes from CALLING Pkg's own functions, never from
# re-deriving what they do — including the manifest read (`read_manifest`, so
# the entries are real `PackageEntry`s) and the "should this be downloaded?"
# predicate (`tracking_registered_version`), both of which an earlier version
# of this file re-implemented and could therefore not have caught a divergence
# in.
#
#   candidates <Manifest.toml>
#       The archive URL list `download_source` would build for every entry of
#       the manifest (Operations.jl:1160-1177), one TAB-separated record per
#       package, sorted. Diffed against `ajt install --dry-run`.
#
#       The first line is a header, `#server <url>` or `#server NONE`, from the
#       REAL `Registry.pkg_server_registry_info()` — the live
#       `GET $server/registries` that decides whether candidate 1 exists at all
#       (Operations.jl:1133-1139, Registry.jl:70-97). The shell harness reads it
#       and refuses to compare a column the oracle could not produce.
#
#   archive-urls
#       `get_archive_url_for_version` over a fixed set of repo URLs chosen to
#       pin the surprising properties of its regex.

using Pkg
using TOML

const Ops = Pkg.Operations

function candidates(manifest_file)
    regs = Pkg.Registry.reachable_registries()
    manifest = Pkg.Types.read_manifest(manifest_file)

    # The real thing: `nothing` when the server is unreachable or tracks none
    # of these registries, which is exactly when Pkg emits no server candidate.
    info = Pkg.Registry.pkg_server_registry_info()
    server = info === nothing ? nothing : info[1]
    tracked_uuids = info === nothing ? Set{Base.UUID}() : Set(keys(info[2]))
    println("#server ", server === nothing ? "NONE" : server)

    out = String[]
    for (uuid, entry) in manifest
        # `download_source`'s own filter (Operations.jl:1115), called rather
        # than re-derived: it is `!is_stdlib(uuid) && path === nothing &&
        # repo.source === nothing`, and `is_stdlib` is version-parameterised.
        Ops.tracking_registered_version(entry) || continue
        entry.tree_hash === nothing && continue
        th = string(entry.tree_hash)

        fields = ["dry-run", entry.name, th]
        if server !== nothing
            for reg in regs
                if reg.uuid in tracked_uuids && haskey(reg, uuid)
                    push!(fields, "$server/package/$uuid/$th")
                    break
                end
            end
        end
        # `find_urls` returns a Set, so with two registries its order is
        # unspecified; sort so the record is reproducible. With the single
        # General registry this is a no-op.
        for u in sort(collect(Ops.find_urls(regs, uuid)))
            a = Ops.get_archive_url_for_version(u, th)
            a === nothing || push!(fields, a)
        end
        push!(out, join(fields, "\t"))
    end
    foreach(println, sort(out))
    return
end

const ARCHIVE_URL_CASES = [
    "https://github.com/JuliaArrays/StaticArrays.jl.git",
    "https://github.com/JuliaLang/Example.jl.git",
    # No `.git` suffix at all.
    "https://github.com/JuliaArrays/StaticArrays.jl",
    # SSH remote: the pattern demands the https prefix verbatim.
    "git@github.com:JuliaArrays/StaticArrays.jl.git",
    "https://gitlab.com/foo/bar.jl.git",
    # `.git` is `<any char>git`, and both captures are lazy: first match wins.
    "https://github.com/a/b.git/extra",
    "https://github.com/O/R.git.git",
    # `.` matches `/` too, so capture 2 spans the slash.
    "https://github.com/Org/Sub.Group/Repo.jl.git",
    # `match` is unanchored.
    "prefix https://github.com/O/R.jl.git suffix",
    # Empty capture 2: `agit` is `<any>git` with nothing before it.
    "https://github.com/x/agit",
]

function archive_urls()
    for u in ARCHIVE_URL_CASES
        r = Ops.get_archive_url_for_version(u, "abc123")
        println(u, "\t", r === nothing ? "NONE" : r)
    end
    return
end

cmd = ARGS[1]
if cmd == "candidates"
    candidates(ARGS[2])
elseif cmd == "archive-urls"
    archive_urls()
else
    error("unknown command $cmd")
end
