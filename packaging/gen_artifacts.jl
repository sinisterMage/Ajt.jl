#!/usr/bin/env julia
#
# Build, package, and describe the release binaries.
#
#     julia packaging/gen_artifacts.jl --target x86_64-linux-musl --out dist
#     julia packaging/gen_artifacts.jl --assemble --out dist
#     julia packaging/gen_artifacts.jl --out dist            # every target, locally
#
# # Why it works one target at a time
#
# Each release binary is built on a runner of its own platform, so `--target`
# does exactly one and writes a small `<target>.hashes` fragment beside its
# tarballs. `--assemble` then collects the fragments into
# `julia/Artifacts.toml`. Nothing cross-compiles in CI: a macOS binary is built
# on macOS and, more to the point, *run* there before it is published.
#
# The all-targets mode is still there for local use — it is the quickest way to
# prove the whole pipeline works from one machine — but treat the
# `Artifacts.toml` it leaves behind as a draft. See below.
#
# # CI writes the file that ships; a local run cannot
#
# `Artifacts.toml` records a SHA-256 per platform, and Ajt's binaries are **not
# reproducible across build directories** — the same commit built in two
# different paths differs byte for byte, because the compiler embeds the path it
# built from. A hash produced on a maintainer's laptop can therefore never match
# one produced on a runner, and an early version of the release workflow that
# asserted it did failed on its first tag.
#
# # The ordering that cannot be collapsed
#
# The registered version of the package must *contain* an `Artifacts.toml`, and
# that file can only be written once the binaries exist. So: tag, let the
# release build and publish, commit the `Artifacts.toml` it produced, and
# register from that commit. URLs are known in advance — they are a function of
# the tag and the file name — so only the hashes have to wait.
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
Every target a release publishes: what to build, where to build it, and which
platforms the result answers for.

The Linux binaries are listed under **both** libcs on purpose. They are static
musl builds with no interpreter and no shared library at all, so they run
identically on a glibc system — but `HostPlatform()` on an ordinary Linux says
`libc = "glibc"`, and an artifact tagged only `musl` would simply never be
selected there. That would be a binary that works everywhere and is offered
nowhere.

`git = false` on Windows is not an oversight: `buildLibgit2` compiles
libgit2's `src/util/unix` and there is no `src/util/win32` in that list, so the
libgit2 backend cannot link there yet. Ajt's default git backend is the `git`
CLI on every platform, so a Windows build is fully functional — it just cannot
be switched to `AJT_GIT_BACKEND=lib`.

Intel macOS is absent. GitHub's `macos-13` is the last x86_64 image and is on
its way out — a release queued behind it simply never got a runner — and Apple
is ending Intel support regardless. Rosetta 2 runs the aarch64 binary on the
few Intel machines left.
"""
const TARGETS = [
    (zig = "x86_64-linux-musl", runner = "ubuntu-latest", git = true, exe = "ajt",
        platforms = [(os = "linux", arch = "x86_64", libc = "glibc"),
                     (os = "linux", arch = "x86_64", libc = "musl")]),
    (zig = "aarch64-linux-musl", runner = "ubuntu-24.04-arm", git = true, exe = "ajt",
        platforms = [(os = "linux", arch = "aarch64", libc = "glibc"),
                     (os = "linux", arch = "aarch64", libc = "musl")]),
    (zig = "aarch64-macos", runner = "macos-14", git = true, exe = "ajt",
        platforms = [(os = "macos", arch = "aarch64", libc = nothing)]),
    (zig = "x86_64-windows-gnu", runner = "windows-latest", git = false, exe = "ajt.exe",
        platforms = [(os = "windows", arch = "x86_64", libc = nothing)]),
]

target_named(name) =
    something(findfirst(t -> t.zig == name, TARGETS), 0) == 0 ?
    error("unknown target $name; known: $(join((t.zig for t in TARGETS), ", "))") :
    TARGETS[findfirst(t -> t.zig == name, TARGETS)]

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
fragment_name(target) = "$target.hashes"
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

    # Debug symbols are a third of the download and of no use to anyone
    # installing the tool.
    for (dir, _, files) in walkdir(prefix), f in files
        endswith(f, ".pdb") && rm(joinpath(dir, f))
    end

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

Two runs over the same tree otherwise differ in exactly **four bytes**, the
timestamp at offset 5..8 of the gzip header (RFC 1952 §2.3.1), and in nothing
else. Zero is the value that field is defined to take when there is no
meaningful modification time, which is the truth for a build artifact.
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
What one runner hands to the job that assembles `Artifacts.toml`.

Deliberately three lines of `key = value` rather than JSON: Julia ships no JSON
parser in its standard library, and a format this small does not justify a
dependency in a packaging script.
"""
function write_fragment(out, t, built)
    open(joinpath(out, fragment_name(t.zig)), "w") do io
        println(io, "target = ", t.zig)
        println(io, "tree = ", built.tree)
        println(io, "sha256 = ", built.sha)
    end
end

function read_fragments(out)
    rows = []
    for t in TARGETS
        path = joinpath(out, fragment_name(t.zig))
        isfile(path) || error("no fragment for $(t.zig) in $out — did its build job run?")
        fields = Dict{String, String}()
        for line in eachline(path)
            k, _, v = partition(line)
            isempty(k) || (fields[k] = v)
        end
        push!(rows, t => (tree = fields["tree"], sha = fields["sha256"]))
    end
    return rows
end

function partition(line)
    i = findfirst('=', line)
    i === nothing && return ("", "", "")
    return (strip(line[1:(i - 1)]), "=", strip(line[(i + 1):end]))
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

"One checksum file for the whole release, in the format `sha256sum -c` reads."
function write_sums(out)
    names = sort(filter(f -> endswith(f, ".tar.gz"), readdir(out)))
    open(joinpath(out, "SHA256SUMS"), "w") do io
        for name in names
            println(io, bytes2hex(sha256(read(joinpath(out, name)))), "  ", name)
        end
    end
end

function main(args)
    out_at = findfirst(==("--out"), args)
    out = out_at === nothing ? joinpath(ROOT, "dist") : args[out_at + 1]
    target_at = findfirst(==("--target"), args)
    version = manifest_version()
    mkpath(out)

    if target_at !== nothing
        t = target_named(args[target_at + 1])
        built = package(version, t, build_prefix(t, mktempdir()), out)
        write_fragment(out, t, built)
        println("built $(t.zig) for v$version into $out")
        return 0
    end

    if "--assemble" in args
        write(ARTIFACTS_TOML, render(version, read_fragments(out)))
        write_sums(out)
        println("wrote $ARTIFACTS_TOML from $(length(TARGETS)) fragments in $out")
        return 0
    end

    # Everything, here. Useful locally; not what CI does.
    workdir = mktempdir()
    rows = map(TARGETS) do t
        built = package(version, t, build_prefix(t, workdir), out)
        write_fragment(out, t, built)
        t => built
    end
    write(ARTIFACTS_TOML, render(version, rows))
    write_sums(out)
    println("wrote $ARTIFACTS_TOML and $(length(TARGETS)) × 2 tarballs into $out for v$version")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
