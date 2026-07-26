# Ajt — Advanced Julia Tools

A drop-in replacement for Julia's [`Pkg.jl`](https://github.com/JuliaLang/Pkg.jl),
built as one small static binary.

- **A paper-faithful [PubGrub](https://github.com/dart-lang/pub/blob/master/doc/solver.md) solver** — incompatibilities, unit propagation, conflict-driven backjumping, and derivation-tree error reporting. Julia's current resolver is a MaxSum message-passing solver that can return `:unsat` or `:timedout` with little explanation; PubGrub can tell you *which* two constraints are irreconcilable and what to relax.
- **Full compatibility with the General registry** and with everything Julia's *loader* reads. Ajt invents no formats: it writes exactly the `Project.toml`, `Manifest.toml` and depot layout Pkg does, so a stock `julia` loads the result with zero changes and stock Pkg keeps working on the same environment.
- **A dynamic frontier scheduler.** Instead of Pkg's four sequential phases (download sources → download artifacts → build → precompile), Ajt models resolve/fetch/verify/install/precompile as one dependency graph and runs a live frontier over it, so a package can start compiling while other tarballs are still downloading.

## Status

Early. Working today, each verified against Julia rather than against my
reading of Julia:

| | | Verified by |
|---|---|---|
| `toml/` | TOML v1.0 parser + emitter byte-compatible with `TOML.print` | 58,941/58,941 registry files byte-identical |
| `julia/slug` | depot directory names (`packages/<Name>/<slug>`) | reproduces `0cEwi`, `oUj6u` from a real depot |
| `julia/version` | `VersionNumber` parsing + `ident_cmp`/`isless` | unit tests incl. the supbuild rule |
| `julia/versions` | `VersionBound`/`Range`/`Spec`, both compat grammars, canonical printing | canonical renderings match `Pkg.Versions` |
| `julia/project_hash` | the fingerprint Pkg records in a Manifest | reproduces a real committed `project_hash` |
| `julia/treehash` | git tree hash, both variants (directory + tar stream) | matches `GitTools.tree_hash` over 243 real directories; `Tar.tree_hash` of the 84 MB General tarball in 0.86 s |
| `julia/platform` | host detection, platform matching, artifact variant selection | detects the same host tags as `HostPlatform()`, and picks the same artifact for all 83 `Artifacts.toml` in a depot |
| `registry/` | reads `General.tar.gz`; versions, deps and compat *uncompressed* | deps+compat identical to Julia across 2,794 packages / 31,478 versions |
| `ajt fmt` / `tree-hash` / `project-hash` / `host-platform` / `select-artifact` / `registry` | CLI | — |

Not written yet: `registry add`/`update` (the first network code — the
verification half is done, only the HTTP fetch is missing), the PubGrub solver,
the installer, and the frontier scheduler. The registry is also re-read on every invocation
(~1.6 s for General); the persistent binary index that makes repeat loads free
is a later optimisation.

## Build

Requires **Zig 0.16.0** exactly (pinned in `build.zig.zon`). Zig 0.16 removed
`std.Thread.Pool` and moved `Dir`/`File`/`cwd` out of `std.fs` into `std.Io`;
Ajt lives on those surfaces, so toolchain bumps are scheduled work rather than
something to drift into.

```sh
zig build              # -> zig-out/bin/ajt
zig build test         # unit tests
zig build run -- help
```

## Testing philosophy

Correctness here means "agrees with Julia", so Julia is the oracle wherever one
exists. Two layers:

- **Unit tests** next to the code, for behaviour with a known-correct answer.
- **Differential tests** in `tools/diff_harness/`, which run Ajt and Julia over
  the same inputs and compare bytes:

  ```sh
  zig build
  tools/diff_harness/toml_roundtrip.sh depot engine     # ~380 files, seconds
  tools/diff_harness/toml_roundtrip.sh registry         # ~59k files, minutes
  tools/diff_harness/treehash.sh                        # installed packages
  tools/diff_harness/treehash.sh --artifacts            # + artifact dirs
  tools/diff_harness/registry_deps.sh --sample 400      # registry reading
  tools/diff_harness/select_artifact.sh                 # artifact selection
  ```

  `toml_roundtrip.sh` compares `ajt fmt --sorted <f>` against
  `TOML.print(TOML.parsefile(f); sorted=true)`. Byte identity is not required
  by anything at runtime — Julia's loader only cares about semantics — but it
  is the sharpest available signal, so it is treated as a testable invariant
  rather than a goal in itself.

  `treehash.sh` compares `ajt tree-hash <dir>` against
  `Pkg.GitTools.tree_hash(dir)`. This one gates the installer: the registry
  pins a `git-tree-sha1` per version, so an install is only verifiable if Ajt
  computes that value exactly as Julia does — including empty-directory
  pruning, the owner-execute-bit rule, and sorting directory names as if they
  ended in `/`. It needs a populated depot, so it is a local gate rather than
  a CI one.

  `registry_deps.sh` compares every version's *uncompressed* dependency set
  and compat specs against Julia's own registry API. It gates the `first..last`
  span rule in `uncompress`: the intuitive reading ("apply the entry to every
  version satisfying the range") gives identical output for packages whose
  version lists are contiguous, and differs only where a non-satisfying version
  sits between two satisfying ones. Sample broadly — a handful of packages
  proves nothing here.

  `select_artifact.sh` checks host detection against `HostPlatform()` and then
  artifact selection against `select_platform`. It uses Ajt's *own* detected
  host for the second step, so a detection regression fails the gate instead of
  being masked by borrowing Julia's answer.

  **A methodological note, because it kept mattering.** Every single time a
  hand-written expectation disagreed with the implementation, the *expectation*
  was wrong — leading blank lines in `TOML.print`, no blank line between
  same-key `[[...]]`, sorting on the raw rather than the quoted key, the `Range`
  significance collapse that makes `"0.4.0"` render as `0.4`, `~1` collapsing to
  `1`, and `["0.7", "1-1.11"]` staying two ranges because they are not joinable.
  Not once was the code wrong and the guess right. Generate expectations from
  Julia; do not reason them out.

  The corollary is about *scale*, not just source: the registry gate passed on
  411 packages and only exposed a real divergence at 2,794. Broad sampling is
  the point, not a nicety.

`src/toml/` (and, as they land, `src/julia/` and `src/solver/`) do no I/O and
allocate only through a passed-in allocator. That is what makes them
exhaustively testable and fuzzable, and it is where correctness lives.

## Layout

```
src/
  root.zig          library root — all logic, unit-testable without a process
  main.zig          CLI, a thin shell over the library
  toml/
    value.zig       order-preserving, arena-allocated value model
    parse.zig       TOML v1.0 parser with line/column diagnostics
    emit.zig        emitter matching Julia's TOML/src/print.jl
  julia/            ports of Julia's own semantics — no I/O, allocator passed in
    slug.zig        depot directory names (crc32c over the UUID's NATIVE bytes)
    version.zig     VersionNumber parsing and ordering
    versions.zig    VersionBound/Range/Spec + both compat grammars
    project_hash.zig  the Manifest fingerprint
    treehash.zig    git tree hash: directory walker + tar-stream verifier
    platform.zig    host detection, matching, artifact variant selection
  registry/
    tarball.zig     loads General.tar.gz into memory (arena-owned)
    index.zig       Registry.toml + per-package versions/deps/compat
tools/
  diff_harness/     differential tests against Julia as oracle
```
