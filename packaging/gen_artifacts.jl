#!/usr/bin/env julia
#
# Build the release binaries, package them, and write (or check)
# `julia/Artifacts.toml` — which is how `pkg> add Ajt` gets a working tool.
#
#     julia packaging/gen_artifacts.jl                 # build, package, write the file
#     julia packaging/gen_artifacts.jl --check         # build, package, verify the file
#     julia packaging/gen_artifacts.jl --out DIR       # where the tarballs go
#
# # One script, so the bytes agree
#
# The release workflow runs this rather than packaging things itself. That is
# the point: `Artifacts.toml` records a SHA-256 of a specific tarball, so
# whatever produces the file that gets published must be the same code that
# produced the hash, or every release would be a coin toss on whether the two
# tar implementations agreed byte for byte.
#
# # Why the URLs can be written before the release exists
#
# An asset's URL is a function of the tag and the file name, both known from
# `build.zig.zon` alone. So the file is generated, committed, and *then* tagged
# — which is the order that matters, because the registered version of the
# package has to contain an `Artifacts.toml`, and the tag that publishes the
# binaries is the same tag TagBot creates for that version. The release workflow
# re-runs this with `--check`, so the two cannot drift apart quietly.
#
# # Why two tarballs per target
#
# They want opposite shapes. A person running `tar xzf` wants one versioned
# directory rather than `bin/` and `share/` splattered into their cwd; Pkg wants
# the artifact tree to *be* the prefix, so that `artifact"ajt"` is a directory
# with `bin/ajt` in it. The `.artifact.tar.gz` suffix says which is which.

import Pkg
using SHA: sha256

# `Pkg.PlatformEngines` rather than Tar plus a compressor: it is the same code
# path Pkg uses to pack and unpack artifacts, so a tarball this writes is one
# Pkg is definitionally able to read, and it costs no dependency beyond the Pkg
# this package already has.
const PE = Pkg.PlatformEngines

const ROOT = normpath(joinpath(@__DIR__, ".."))
const ARTIFACTS_TOML = joinpath(ROOT, "julia", "Artifacts.toml")
const REPO = "sinisterMage/Ajt.jl"

"""
The targets a release publishes, and the platforms each one answers for.

The Linux binaries are listed under **both** libcs on purpose. They are static
musl builds with no interpreter and no shared library at all, so they run
identically on a glibc system — but `HostPlatform()` on an ordinary Linux says
`libc = "glibc"`, and an artifact tagged only `musl` would simply never be
selected there. That would be a binary that works everywhere and is offered
nowhere.

Windows is absent because it does not build yet; see the README.
"""
const TARGETS = [
    (zig = "x86_64-linux-musl", git = true,
        platforms = [(os = "linux", arch = "x86_64", libc = "glibc"),
                     (os = "linux", arch = "x86_64", libc = "musl")]),
    (zig = "aarch64-linux-musl", git = true,
        platforms = [(os = "linux", arch = "aarch64", libc = "glibc"),
                     (os = "linux", arch = "aarch64", libc = "musl")]),
    (zig = "x86_64-macos", git = true,
        platforms = [(os = "macos", arch = "x86_64", libc = nothing)]),
    (zig = "aarch64-macos", git = true,
        platforms = [(os = "macos", arch = "aarch64", libc = nothing)]),
]

"The version in build.zig.zon, which is the only place it is written."
function manifest_version()
    for line in eachline(joinpath(ROOT, "build.zig.zon"))
        m = match(r"^\s*\.version\s*=\s*\"([^\"]+)\"", line)
        m === nothing || return String(m.captures[1])
    end
    return error("no .version in build.zig.zon")
end

release_name(version, target) = "ajt-$version-$target"
artifact_asset(version, target) = release_name(version, target) * ".artifact.tar.gz"
release_asset(version, target) = release_name(version, target) * ".tar.gz"
artifact_url(version, target) =
    "https://github.com/$REPO/releases/download/v$version/$(artifact_asset(version, target))"

"""
libgit2's own licence, found by its contents.

Not by path: the fetched dependency is named by hash, and it contains several
`COPYING` files — the first one a `find` returns is bundled PCRE's, which is not
the notice owed for statically linking libgit2.
"""
function libgit2_licence()
    for (dir, _, files) in walkdir(joinpath(ROOT, "zig-pkg"); onerror = _ -> nothing)
        "COPYING" in files || continue
        candidate = joinpath(dir, "COPYING")
        occursin("libgit2 is Copyright", read(candidate, String)) && return candidate
    end
    return nothing
end

"Build one target into an artifact-shaped prefix: `bin/ajt`, licences beside it."
function build_prefix(t, workdir)
    prefix = joinpath(workdir, "prefix-$(t.zig)")
    flags = ["-Dtarget=$(t.zig)", "-Doptimize=ReleaseFast"]
    t.git && push!(flags, "-Dgit")
    run(setenv(`zig build $flags --prefix $prefix`; dir = ROOT))

    licences = joinpath(prefix, "share", "licenses", "Ajt")
    mkpath(licences)
    cp(joinpath(ROOT, "LICENSE"), joinpath(licences, "LICENSE"); force = true)
    if t.git
        # GPL-2.0-with-linking-exception, statically linked in. The exception
        # permits the linking; it does not excuse shipping without the notice.
        copying = libgit2_licence()
        copying === nothing &&
            error("libgit2 was linked into $(t.zig) but its licence was not found to ship with it")
        cp(copying, joinpath(licences, "LICENSE.libgit2"); force = true)
    end
    return prefix
end

"""
Zero the MTIME field of a gzip stream, in place — what `gzip -n` does.

`Artifacts.toml` records a SHA-256 of a specific tarball, so packaging has to be
reproducible or `--check` would fail against a file it had itself produced a
minute earlier. It very nearly is already: two runs over the same tree differ in
exactly **four bytes**, the timestamp at offset 5..8 of the gzip header
(RFC 1952 §2.3.1), and in nothing else. Zero is the value that field is defined
to take when there is no meaningful modification time, which is the truth here.
"""
function normalize_gzip_mtime!(path)
    bytes = read(path)
    length(bytes) >= 8 || error("$path is not a gzip stream")
    bytes[1] == 0x1f && bytes[2] == 0x8b || error("$path is not a gzip stream")
    bytes[5:8] .= 0x00
    write(path, bytes)
    return path
end

"Both tarballs for one target, plus the two hashes `Artifacts.toml` needs."
function package(version, t, prefix, out)
    mkpath(out)
    artifact_tarball = joinpath(out, artifact_asset(version, t.zig))
    PE.package(prefix, artifact_tarball)
    normalize_gzip_mtime!(artifact_tarball)

    # The human-facing one: the same tree, one directory further down.
    staging = mktempdir()
    cp(prefix, joinpath(staging, release_name(version, t.zig)))
    release_tarball = joinpath(out, release_asset(version, t.zig))
    PE.package(staging, release_tarball)
    normalize_gzip_mtime!(release_tarball)

    return (
        tree = bytes2hex(Pkg.GitTools.tree_hash(prefix)),
        sha = bytes2hex(sha256(read(artifact_tarball))),
    )
end

"""
Render the whole file. Written out rather than `TOML.print`ed because this is a
file people read in review, and the grouping — one platform per entry, the
download block indented under it — is the shape Pkg's own documentation uses.
"""
function render(version, rows)
    io = IOBuffer()
    println(io, "# Generated by packaging/gen_artifacts.jl -- do not edit by hand.")
    println(io, "#")
    println(io, "# One entry per platform, all pointing at assets of the v$version release.")
    println(io, "# `lazy = true` means nothing is downloaded by `add Ajt`: the binary arrives")
    println(io, "# the first time something actually needs it, which is the first Ajt command")
    println(io, "# rather than the install.")
    for (t, built) in rows, p in t.platforms
        println(io)
        println(io, "[[ajt]]")
        println(io, "arch = \"", p.arch, "\"")
        println(io, "git-tree-sha1 = \"", built.tree, "\"")
        p.libc === nothing || println(io, "libc = \"", p.libc, "\"")
        println(io, "lazy = true")
        println(io, "os = \"", p.os, "\"")
        println(io)
        println(io, "    [[ajt.download]]")
        println(io, "    sha256 = \"", built.sha, "\"")
        println(io, "    url = \"", artifact_url(version, t.zig), "\"")
    end
    return String(take!(io))
end

function main(args)
    check = "--check" in args
    out_at = findfirst(==("--out"), args)
    out = out_at === nothing ? joinpath(ROOT, "dist") : args[out_at + 1]
    version = manifest_version()

    workdir = mktempdir()
    rows = [t => package(version, t, build_prefix(t, workdir), out) for t in TARGETS]

    # One checksum file for the whole release, in the format `sha256sum -c` reads.
    open(joinpath(out, "SHA256SUMS"), "w") do io
        for name in sort(filter(f -> endswith(f, ".tar.gz"), readdir(out)))
            println(io, bytes2hex(sha256(read(joinpath(out, name)))), "  ", name)
        end
    end

    rendered = render(version, rows)
    if check
        current = isfile(ARTIFACTS_TOML) ? read(ARTIFACTS_TOML, String) : ""
        if current == rendered
            println("julia/Artifacts.toml is up to date for v$version")
            return 0
        end
        println(stderr, "julia/Artifacts.toml does not describe the binaries just built for v$version.")
        println(stderr, "Run `julia packaging/gen_artifacts.jl` and commit the result.\n")
        println(stderr, rendered)
        return 1
    end
    write(ARTIFACTS_TOML, rendered)
    println("wrote $ARTIFACTS_TOML and $(length(TARGETS)) × 2 tarballs into $out for v$version")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
