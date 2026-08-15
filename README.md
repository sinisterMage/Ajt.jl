# Ajt — Advanced Julia Tools

A standalone package manager for Julia environments, in one small static
binary. Ajt is to [`Pkg`](https://github.com/JuliaLang/Pkg.jl) what **pnpm is
to npm**: an alternative client for the same ecosystem, not a replacement of
it.

The comparison is meant precisely. pnpm never set out to displace npm — it
reads the same `package.json`, installs from the same registry, and earned its
users on what it does differently: speed, strictness, a content-addressed
store. Ajt has that relationship to Pkg, and goes one step further than the
analogy: where pnpm keeps its own lockfile, Ajt writes Pkg's own files, **byte
for byte** — the same `Project.toml`, `Manifest.toml` and depot layout — so a
stock `julia` loads the result unchanged and stock Pkg keeps working on the
same environment. Use one today and the other tomorrow, or both in the same
week; nothing about an environment records which tool touched it.

Pkg defines the contract and ships with every Julia. That is not in question —
it is what makes an alternative client possible at all. What Ajt brings is the
alternative client's virtues: a ~15 ms static binary where `using Pkg` costs a
Julia boot, a resolver that explains its refusals instead of shrugging, a
frontier scheduler that compiles each package the moment its dependencies are
ready, and a content-addressed precompile cache that turns one machine's
compile into every other machine's import.

```console
$ ajt add DataFrames
added	DataFrames	a93c6f00-e57d-5684-b7b6-d8193f3e46c0
installed	44
manifest	./Manifest.toml	44	written
project	./Project.toml	written

$ ajt why Missings
  DataFrames → Missings

$ ajt verify
ok  ./Manifest.toml
    44 entries: 36 installed, 0 developed, 8 stdlib, 0 pruned  [12.1 ms]
```

## What's different

Every claim below is measured, in both directions — the benchmark prints the
rows Ajt loses with the rows it wins (`scripts/bench/bench_vs_pkg.sh` in the
RealityForge repo runs the comparison, and *Performance* below reports what it
says).

**A resolver that shows its working.** Julia's resolver is a MaxSum
message-passing solver that can answer `:unsat` or `:timedout` without saying
much about why. Ajt uses [PubGrub](https://github.com/dart-lang/pub/blob/master/doc/solver.md),
which tracks *why* each version was ruled out, so a conflict comes back as
something you can act on:

```console
$ ajt resolve
resolve	failed
Because:
- combining the two facts above rules out project:
  - project@0.0.0 depends on DataFrames ({project 0.0.0, not DataFrames 1.7.0-1.8.2})
  - combining the two facts above rules out CSV:
    - CSV@0.8.5 depends on Parsers ({CSV 0.8.5, not Parsers 1.0.0-1.1.2})
    - InlineStrings@1.4.5 depends on Parsers ({InlineStrings 1.4.5, Parsers 0.1.0-1.1.2})
version solving failed.
to fix, try relaxing [compat] on: DataFrames InlineStrings Parsers CSV
```

**No runtime to boot.** Ajt is a static binary that starts in ~15 ms, where
`using Pkg` costs ~300 ms before any work begins. That is invisible inside a
Julia session and quite visible in a shell loop or a CI job that just wants to
ask whether an environment is ready.

**A frontier where a barrier costs something.** Pkg runs four `@sync` phases
back to back — download sources, download artifacts, build, precompile — and
the last of those is the expensive one: it starts only once the last tarball
has landed, and then compiles one package at a time in topological order. Ajt
models it as a dependency graph and runs a live frontier over it, with separate
permits for network, disk and CPU and a memory budget for the forked Julias, so
a package compiles the moment its own dependencies are ready rather than when
the walk reaches it. On the engine environment that is **321 s → 80 s**.

The two download phases are still two, and that is a measurement rather than an
omission. Fusing them was built and benchmarked, and at equal peak concurrency
the barrier is *faster* — 14.9 s against 16.6 s at eight connections, 10.2 s
against 12.3 s at sixteen. Both halves queue on the same resource (Pkg's
`num_concurrent_downloads`, which it enforces separately in each phase), and
the artifact half needs its connections in a block, so interleaving costs it
more than the overlap saves. A barrier is only worth deleting when the phases
either side of it wait on *different* things — which downloading and compiling
do, and downloading and downloading do not. The numbers, and the conditions
that would change the answer, are in `src/ops/instantiate.zig`.

**A content-addressed precompile cache** — the pnpm move, applied where Julia
hurts most. A package's cache entry is addressed by a derivation key computed
from its source tree, its dependencies' keys, and the three installation
inputs that decide whether a `.ji` is loadable at all (sysimage, cache flags,
CPU target) — so the address needs no announcement and no coordination: a
cold machine computes it and asks. Point `$AJT_CACHE_URL` at a store and
`ajt precompile` imports what any other machine already compiled and
publishes what it compiled itself (`--cache-token` gates the publish);
unset, there is no cache, no network, and exactly `Pkg.precompile()`'s
behaviour. The wire gate (`tools/diff_harness/cache_wire.sh`) proves the
piece that matters: after an import, stock `Pkg.precompile()` rebuilds
**nothing** and the package loads — Julia cannot tell the entry was not
compiled locally. Entries that are only meaningful where they were built
(non-relocatable paths) are detected and never published.

**A `[sources]` edit that actually re-resolves.** Pkg's `project_hash` digests
deps, weakdeps and compat — and not `[sources]`. So adding a source entry, or
moving a `rev` in one, changes the fingerprint by nothing: the manifest is
judged current, the repository is never re-cloned, and the edit silently does
nothing ([#4157](https://github.com/JuliaLang/Pkg.jl/issues/4157),
[#4351](https://github.com/JuliaLang/Pkg.jl/issues/4351)). Ajt keeps the hash
byte-exact — widening it would make every manifest it writes look stale to
stock Pkg, which is the interop the hash exists to provide — and puts the
stricter answer in `verify`, which compares `[sources]` against what the
manifest actually recorded:

```console
$ ajt verify
sources_not_applied  Foo   the manifest does not reflect this [sources] entry
    want v2.1  got main
    resolve to apply the new rev (JuliaLang/Pkg.jl#4157)
```

`tools/diff_harness/sources_staleness.sh` pins both halves of that: it requires
`Pkg.is_manifest_current` to still answer **true** on the same environment
(without which the gate would be guarding a bug that no longer exists), and
requires ajt's `project_hash` to equal Julia's byte for byte, so the divergence
is provably in the check and not in the digest.

**Where Pkg remains the only implementation.** `undo`/`redo` and `[workspace]`
are not implemented, nor is `app add`/`app update` — the two app verbs that
begin with a registry version solve and a download. The Julia wrapper forwards
all of them to Pkg, with `Ajt.parity()` printing the live list and the reasons.
Pkg is also the only one of the two that can *write* a precompile cache entry —
Ajt invokes Julia to do that and never forges a `.ji` header.

**Apps, minus a Windows bug.** `ajt app dev|rm|status` implements `Pkg.Apps`:
the `AppManifest.toml` and the POSIX shim it writes are byte-identical to
Pkg's, and an environment moves between the two tools in either direction
(`tools/diff_harness/apps.sh` installs the same package through both, diffs
every artefact, and *runs* both shims). One deliberate difference, and it is a
fix: Pkg's Windows `.bat` stores `julia_cmd` already quoted and then quotes it
again at the call site, so an app cannot start at all when the depot path
contains a space — [#4741](https://github.com/JuliaLang/Pkg.jl/issues/4741),
still open. Ajt stores it unquoted, and the generated file says so in its
header. The gate re-derives Pkg's buggy line from the live Julia rather than
hard-coding it, so if upstream fixes #4741 the deviation is reported as
obsolete instead of quietly guarding nothing.

`ajt build` runs `deps/build.jl` the way `Pkg.build` does — same order, same
`build.log` paths, same `scratch_usage.toml` entry, gated by
`tools/diff_harness/build.sh` — but it is a **separate command**, where Pkg
builds automatically at the end of `add`/`up`/`instantiate`. Same rule as
`resolve` not installing: the verbs here do the thing they are named after and
nothing that runs arbitrary code behind your back.

> **On the short git history.** Ajt was developed in-tree inside the
> RealityForge repository (a private project of mine) — as `packages/ajt/`,
> next to the engine that needed it — before being published here properly, so
> this repo's history starts at
> the publish rather than at the first line of code. The provenance that
> matters survived the move: every non-obvious port cites the Pkg source it
> reproduces by file and line, and the differential gates in
> `tools/diff_harness/` re-derive the expected behaviour from a live Julia on
> every run.

## Install

A prebuilt binary, from the [latest release](https://github.com/sinisterMage/Ajt.jl/releases/latest):

| | |
|---|---|
| Linux | `ajt-<version>-x86_64-linux-musl.tar.gz` · `…-aarch64-linux-musl.tar.gz` |
| macOS | `ajt-<version>-aarch64-macos.tar.gz`  |
| Windows | `ajt-<version>-x86_64-windows-gnu.tar.gz` |

Each holds `bin/ajt` and the licences it owes. The Linux builds are static musl
binaries with no shared-library dependency at all. Every asset is built on a
runner of its own platform and run there before release, and its SHA-256 is in
`SHA256SUMS`. Put `ajt` anywhere on `PATH`.

The Linux and macOS builds link libgit2 statically. The Windows build does not
— `buildLibgit2` compiles libgit2's `src/util/unix` and has no `src/util/win32`
yet — so on Windows the `AJT_GIT_BACKEND=lib` backend is unavailable. Nothing
else differs: the `git` CLI backend is the default everywhere.

### Building

Requires **Zig 0.16.0** exactly (pinned in `build.zig.zon`).

```sh
zig build              # -> zig-out/bin/ajt
zig build test         # unit tests
zig build -Dgit        # ... with the libgit2 backend (fetches ~30 MB of C)
ajt help               # every command and flag
```

Cross-compiling works — `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast`
— and `packaging/gen_artifacts.jl` will build every release target from one
machine. Releases themselves do not: each binary is built on a runner of its own
platform so that it can be *run* before it is published.

One Windows note for anyone reading `src/depot.zig`: `readonly.get`/`readonly.set`
exist because Zig 0.16.0's `std/Io/File.zig:349-360` still reads the integer
constant `windows.FILE_ATTRIBUTE_READONLY` that the migration to
`packed struct(ULONG)` deleted, so std's own `readOnly`/`setReadOnly` do not
compile for Windows. Ajt does the same bit through the struct that replaced it.
Delete both when upstream compiles.

## Commands

| | |
|---|---|
| `add` / `rm` / `up` | change what an environment depends on |
| `pin` / `free` | hold an entry where it is, or stop holding it |
| `dev` | track a package from a directory, or clone one into `<depot>/dev/` |
| `compat` | set or delete one `[compat]` bound, then re-resolve to check it |
| `generate` | scaffold a package: `Project.toml` + `src/<Pkg>.jl`, nothing else |
| `resolve` | choose versions; `--write` records them in `Manifest.toml` |
| `instantiate` | make the depot satisfy an existing manifest |
| `install` / `install-artifacts` | the two halves of `instantiate`, on their own |
| `precompile` | compile the environment; `--only P[,P…]` restricts to a closure, `--cache-url` reads/publishes the shared cache |
| `build` | run each package's `deps/build.jl`, in dependency order, in a sandbox |
| `test` | run a package's test suite in Pkg's sandbox — same flags, same transcript, same failure sentences |
| `app {dev,rm,status}` | install a package's `[apps]` as executables in `<depot>/bin` |
| `status` | Pkg's status report, byte for byte |
| `verify` | is this environment ready? |
| `manifest {current,upgrade}` | was this manifest resolved from this project? migrate v1 → v2 |
| `why` | the dependency paths that explain an entry |
| `gc` | delete what no live environment can reach |
| `registry {add,update,status,show,index}` | manage the registry |
| `usage {record,keys}` | the depot logs that decide what `gc` may collect |
| `fmt` · `tree-hash` · `project-hash` · `host-platform` · `select-artifact` · `artifact` | the primitives, exposed |
| `fetch` · `git {ls-remote,fetch,hash-object}` | transport debug aids the gates drive |

Output is tab-separated, one record per line, so the commands compose in a
shell script. `verify` answers through its exit status: **0** ready, **1** run
`instantiate`, **2** run `resolve`, **3** broken in a way no Pkg verb fixes.

### Preserve levels

`resolve` and `add` take `--preserve`, which decides how much of an existing
manifest may move — the same seven levels Pkg has:

| | |
|---|---|
| `all` | hold every recorded version (what `resolve` and `instantiate` do) |
| `installed` | as `all`, but only versions already unpacked — resolves offline |
| `direct` | hold direct dependencies, let the closure move |
| `semver` | let direct dependencies move compatibly |
| `none` | ignore the manifest; resolve from `[compat]` alone |
| `tiered` | try `all`, `direct`, `semver`, `none`; first that works (`add`'s default) |
| `tiered_installed` | `installed` first, then the above |

A `develop`ed, repo-tracked or pinned entry holds at every level.

## From Julia

`julia/` is a wrapper package exposing Pkg's API and a `]`-style REPL mode:

```julia
pkg> add https://github.com/sinisterMage/Ajt.jl.git:julia
julia> using Ajt        # `]` becomes `ajt>`; set AJT_REPL=0 to keep Pkg's
julia> Ajt.parity()     # what is native, what delegates, and why
```

Putting `using Ajt` in `~/.julia/config/startup.jl` is the intended way to
install it: `]` is then Ajt's from the first prompt of every session. Loading it
later works too, whether or not Pkg's own `]` mode has already been used.

Every function `Pkg` makes public exists in `Ajt` from day one — implemented
against the binary where Ajt has it, forwarded to `Pkg` with a one-line notice
where it does not. Parity is a ratchet, not a gate: `Ajt.conformance()`
enumerates `names(Pkg)` and reports anything in neither bucket, and the test
suite fails on a non-empty report, so a hole cannot open quietly.

The binary is found via `$AJT_BINARY`, then a sibling `../zig-out/bin/ajt`, then
the release binary for this version if it is already installed, then `PATH`. If
none of those exist it is downloaded once — the same asset as *Install* above,
verified against the tree hash in `julia/Artifacts.toml` — and only if that also
fails does it error, naming every path it tried. Listing the candidates never
touches the network; only the last resort does.

## Interoperability

The point of writing Pkg's formats exactly is that you never have to choose.
This is tested rather than asserted — on four environments, one hand-maintained
and three resolved by stock Pkg and never seen by Ajt:

- `resolve --write` produces the **same `Manifest.toml`, byte for byte**, as
  `Pkg.resolve()` — and `Pkg.resolve()` then finds nothing to change.
- A free re-resolve (`--preserve none`) matches `Pkg.update()` byte for byte on
  a run where 43 versions moved.
- `add`, `rm` and `up` produce the same `Project.toml` **and** `Manifest.toml`
  as `Pkg.add`, `Pkg.rm` and `Pkg.update(; level=…)`.
- `why` is byte-identical to `Pkg.why`.
- After `ajt instantiate` into an empty depot, `Pkg.instantiate()` installs,
  downloads and updates nothing, and `is_instantiated` returns true.

So an environment can move between the two tools freely, in either direction,
without either noticing.

## Performance

Measured head to head on one machine, interleaved, median of 3, against a warm
depot and a pinned registry snapshot (`scripts/bench/bench_vs_pkg.sh`). Ratios
above 1 mean Ajt took less wall clock:

| | ajt | Pkg | |
|---|---:|---:|---|
| start-up floor | 19 ms | 300 ms | 16× |
| `verify` — is this environment ready? | 31 ms | 729 ms | 24× |
| `resolve` — unchanged environment | 180 ms | 2.04 s | 11× |
| `add` one package | 72 ms | 3.11 s | 43× |
| re-resolve with every pin dropped | 824 ms | 2.21 s | 2.7× |

Two things set the shape. The quick operations are dominated by start-up, where
a static binary wins by an order of magnitude over `using Pkg`. The heavy ones
are dominated by how the registry gets read: Ajt keeps a binary index of the
General registry, content-addressed by the registry's git tree hash, which maps
in about 1 ms where parsing the 84 MB tarball costs ~1.5 s. It is rebuilt
automatically when the registry moves, so the tarball path is the fallback
rather than the norm.

These are warm-depot numbers on one machine; the script re-runs the whole
table anywhere in minutes. `instantiate` and `precompile` rows are excluded
because they are dominated by network and by Julia compilation respectively —
neither measures the tool (the frontier and the shared cache, which do move
those, are measured in *What's different* above).

## Testing

Correctness here means "agrees with Julia", so Julia is the oracle wherever one
exists: expected values are produced by *running* `julia`, never by reading it.
That is not a stylistic preference. Every single time a hand-written
expectation disagreed with the implementation in this project, the expectation
was the thing that was wrong.

Two layers — unit tests next to the code (`zig build test`), and differential
gates that run Ajt and Julia over the same inputs and compare bytes:

```sh
tools/diff_harness/toml_roundtrip.sh depot engine   # ~380 files, seconds
tools/diff_harness/toml_roundtrip.sh registry       # ~59k files, minutes
tools/diff_harness/treehash.sh --artifacts          # git tree hash vs GitTools
tools/diff_harness/registry_deps.sh --sample 400    # registry reading
tools/diff_harness/resolve.sh                       # the resolver vs Pkg (network)
tools/diff_harness/reresolve.sh                     # free re-resolve vs Pkg.update
tools/diff_harness/generate.sh                      # scaffolding vs Pkg.generate
tools/diff_harness/build.sh                         # deps/build.jl vs Pkg.build
tools/diff_harness/status.sh                        # the report vs Pkg.status (network)
tools/diff_harness/apps.sh                          # ajt app vs Pkg.Apps, shims run
tools/diff_harness/shell_escape.sh                  # Base.shell_escape{,_wincmd}
tools/diff_harness/sources_staleness.sh             # the [sources] divergence
tools/diff_harness/fallback_gates.sh                # Ajt <-> Pkg interop
```

The three that decide whether Ajt is trustworthy:

**`fallback_gates.sh`** — whether it is safe to put Ajt in front of Pkg. Every
other gate asks "does Ajt agree with Julia about some value?"; these ask whether
**stock Julia still agrees there is nothing left to do** after Ajt has touched
an environment or a depot, in both directions, with a depot built from empty. A
warm cache would let a broken installer pass on state it did not create.

**`resolve.sh`** — the anti-overfitting gate. Reproducing the one manifest a
resolver was developed against is the textbook shape of overfitting, so this
lets stock Pkg resolve packages nobody tuned for (Makie, DataFrames, Flux — all
heavy `[weakdeps]` users) and requires Ajt to agree on environments it has
never seen.

**`reresolve.sh`** — removes the pins. Every other gate holds versions fixed,
which collapses the solve to unit propagation and says almost nothing about how
a version is *chosen*. This runs `Pkg.update()` and `ajt resolve --preserve
none` over the same environment and requires the same manifest — and it reports
a run where nothing moved as **inconclusive**, because two no-ops always match.

A note on how these are written, because it kept mattering: a gate is only
worth having if it can fail. Where a check could pass vacuously the harness
perturbs its own input first — stripping every derived field from a manifest
and requiring the writer to rebuild it exactly, or deleting one `weakdeps` key
and requiring the fixups pass to notice. Several of those caught real defects
that an innocent-looking green run was hiding. Sampling is broad for the same
reason: the registry gate agreed with Julia across 411 packages and only
exposed a real divergence at 2,794.

## Layout

```
src/
  root.zig          library root — all logic, unit-testable without a process
  main.zig          CLI, a thin shell over the library
  toml/             TOML v1.0 parser + emitter matching Julia's TOML.print
  julia/            ports of Julia's own semantics — no I/O, allocator passed in:
                    depot slugs, versions, both compat grammars, git tree hash,
                    platform selection, project_hash, preferences, stdlibs
  registry/         General.tar.gz reader + a persistent binary index
  solver/           PubGrub (vendored from baker, MIT — see VENDOR.md), the
                    Julia version model, and the encoder that feeds it
  cache/            the shared precompile cache: derivation key, local cache
                    path, `.ji` header verification, object transport
  sched/            the frontier scheduler: stage graph, resource classes,
                    critical-path ranking
  net/              the Pkg-server transport — the only module that networks
  install/          verify-before-extract, Artifacts.toml
  model/            Project.toml and Manifest.toml read/write
  depot.zig         DEPOT_PATH, depot layout, atomic install
  ops/              one Pkg verb each: resolve, edit (add/rm/up), why,
                    instantiate, precompile, build, verify, install, registry,
                    usage, apps — plus sandbox (the temp environment build and
                    test share) and child (running a child `julia`)
julia/              the Ajt.jl wrapper package and its `]`-mode REPL
tools/diff_harness/ differential tests against Julia as oracle
```

The layering rule that matters: `julia/` and `solver/` do **no I/O** and
allocate only through a passed-in allocator. That is what makes them
exhaustively testable, and it is where correctness lives.
