# Vendored: baker's PubGrub resolver

- **Upstream:** https://github.com/sinisterMage/baker
- **Frozen at:** `479a7a91e77137ec6eae42657382ff2d676bf079`
- **License:** MIT (same as Ajt; same author)
- **Not tracked against upstream.** This is a one-way copy, deliberately. The
  two projects' version models diverge permanently (see below), so there is no
  meaningful "pull latest" — treat this as Ajt's code from here on.

## What was vendored

| File | Status |
|---|---|
| `pubgrub.zig` | verbatim — the solver loop: `unitPropagation`, `conflictResolution`, `decisionMaking` |
| `assignment.zig` | verbatim — `PartialSolution`: decisions, derivations, decision levels, `backtrack` |
| `incompatibility.zig` | verbatim — incompatibilities, `Cause` tree, `writeReport` |
| `term.zig` | verbatim — PubGrub `Term`, positive/negative over a `VersionSet` |
| `version.zig` | verbatim **but temporary** — see "The one seam that must be replaced" |
| `tests/*.zig` | 13 tests: linear, diamond, branching (incl. a failing case), backjump ×2, negative-term ×2, learned-clause ×2, singleton ×2 |

Baker's resolver was chosen because it is genuinely paper-faithful to
[PubGrub](https://github.com/dart-lang/pub/blob/master/doc/solver.md):
`findSatisfier` with `previousLevel`, the decision-or-higher-level termination
condition, the `priorCause` resolvent, real backjumping, and a derivation-tree
reporter. Its 13 tests cover precisely the parts where PubGrub implementations
go wrong.

## Local patches

Baker pins Zig 0.15.2; Ajt is on 0.16.0. **The solver core needed no changes at
all** — all four core files compile and pass unmodified. Every patch below is
outside it:

1. `version.zig`: `std.mem.trimLeft` → `std.mem.trimStart` (0.16 rename). One
   line, in baker's semver *range parser* — not in the set algebra.
2. `manifest.zig`: **replaced** with a minimal seam. Baker's is 266 lines of
   build recipes, artifacts and build systems; the solver reads exactly two
   fields (`depends`, `no_versioning`), so vendoring the rest would import
   concepts Ajt has no use for.
3. `log.zig`: **replaced** with a `std.debug.print` shim. Baker's uses
   `std.Thread.Mutex` and `std.fs.File.stderr()`, both moved in 0.16
   (`std.Io.Mutex`, `std.Io.File`). The solver only logs; behaviour is
   unaffected.
4. Import paths flattened: `../manifest.zig` → `manifest.zig`,
   `../util/log.zig` → `log.zig`.
5. Tests: `@import("baker")` → `@import("../solver.zig")`, and the
   `build_depends` / `artifact` initialisers dropped along with those fields.

## The one seam that must be replaced

`version.zig` is **SemVer 2.0.0**. Julia's version semantics are not semver:

- `VersionBound` carries `n`, the number of significant components, and
  comparison spans only those — `1.5.99` is inside the bound `1.5`.
- `≲` ignores prerelease and build metadata; `VersionNumber` ordering does not.
- Two mutually incompatible compat grammars (`Project.toml` vs the registry's
  `Compat.toml`).
- `VersionRange`'s constructor collapses `lo.t == hi.t`, and `isjoinable` merges
  adjacent bounds such as `1.5` with `1.6`.

This file was replaced with a Julia-semantics implementation of the **same
interface**, backed by a bitset over each package's candidate version list
rather than a range algebra.

That swap is cheap because of a property worth stating explicitly: **the solver
never reaches inside a `VersionSet`.** Verified by inspection — there is no
`.ranges` access anywhere in `pubgrub.zig`, `term.zig`, `incompatibility.zig`
or `assignment.zig`. The whole coupling is roughly a dozen methods
(`exact`, `fromRange`, `empty`, `contains`, `complement`, `intersect`,
`unionWith`, `difference`, `isEmpty`, `isAny`, `containsSet`, `eql`) plus
`Version.order` / `Version.eql`.

A bitset is in fact a *better* fit for that interface than a range algebra:
complement becomes `~`, trivially correct, whereas complement over a Julia
`VersionSpec` is a real correctness trap. Julia semantics then enter in exactly
one function — "is this version in this spec" — which can be
differential-tested against Julia in isolation over the whole registry.

## The swap, as landed

`version.zig` is **deleted**; `julia_set.zig` is the model. All 13 vendored
solver tests pass with their scenarios and assertions unchanged.

Porting them surfaced **three real defects**. Two are latent bugs in baker's
own model rather than artefacts of the port, which is worth recording because
it means the vendored solver was never exercised on these paths:

1. **`Term.relation` tested disjointness before subset.** An empty true set
   intersects nothing, so an *unsatisfiable* term was reported as
   `.contradicted` instead of being (vacuously) a subset of everything. This
   stalls propagation dead: the enclosing incompatibility never reads as
   satisfied, conflict resolution never runs, and `solve` returns a graph with
   undecided dependencies. Unreachable in baker, where an empty true set could
   not arise on an infinite version axis; routine over a finite candidate list
   (`bar ^9.0.0` where bar only ever published 1.0.0 is empty on construction).

2. **The version space had no "absent" element.** A dependency is encoded as
   `{P@v, ¬dep ∈ range}`, and "dep is absent" is one of the ways the second
   term holds. The infinite axis supplied that room implicitly. Over a finite
   list, a `range` covering every published version — the *common* case, since
   `^1` covers all of a package that only shipped 1.x — makes
   `complement(range)` empty, so the incompatibility is vacuous and the
   dependency is never derived. Each universe now reserves a bit at index `n`
   for it; constraints (`fromSpec`, `exact`) never set it, `complement` always
   can, and `count`/`highest`/`lowest` ignore it.

3. **`exactPinned` was widened** from "a literal `=x.y.z` range" to "the
   constraint admits exactly one candidate" (`popcount == 1`), which is
   directly expressible over a bitset. Safe *only* because its sole caller is
   a non-fatal pre-fetch that warms a manifest decision-making would fetch
   anyway.

Three seam patches were also needed, all mechanical:

- the solver's three `VersionSet.empty_set` sites now use `emptyLike`, because
  a universe-less empty set cannot be complemented and `negate()` + `trueSet()`
  reaches exactly that;
- `mkKey` and two log lines formatted versions as `{d}.{d}.{d}`, now `{f}`;
- `linear.zig`'s shared `TestRegistry` builds a `Universe` per package name.

One test STRING changed meaning and had to be translated: baker wrote a
constraint as `">=1.0.0, <2.0.0"`, where comma is conjunction. In Julia's
`semver_spec` comma is a **union** (`Versions.jl:303-325`), so that string
parses to `*` — every version, including 0.5.0. Verified against Julia, not
assumed. `negative_term.zig` now spells it `"^1.0.0"`, the interval its own
comment says it means. Every other string the vendored tests use was checked
against `Pkg.Versions.semver_spec` over their candidate sets and selects
identically in both grammars.
