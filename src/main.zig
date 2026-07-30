//! Ajt CLI.
//!
//! A thin shell over the library in src/root.zig -- all real logic lives
//! there, so it can be unit-tested without spawning a process.

const std = @import("std");
const Io = std.Io;
const fspath = std.fs.path;
const ajt = @import("ajt");

const usage =
    \\ajt — Advanced Julia Tools
    \\
    \\Usage:
    \\  ajt fmt [options] <file.toml>...   Normalise TOML the way Julia's TOML.print does
    \\  ajt tree-hash <dir>...             git tree hash of a directory (what
    \\                                     git-tree-sha1 in a registry pins)
    \\  ajt project-hash <Project.toml>    The hash Pkg records in a Manifest
    \\  ajt host-platform --julia-prefix P --julia-version V
    \\                                     The host tag set Julia would report
    \\  ajt select-artifact --host <tags> <Artifacts.toml>...
    \\                                     Which artifact variant a host selects
    \\  ajt artifact <sub> ...             Artifacts.toml model (see below)
    \\  ajt verify [options] [env]         Is this environment already fully
    \\                                     instantiated? (exit 0 = yes, and
    \\                                     nothing was written)
    \\  ajt install-artifacts [options] <package-root>...
    \\                                     Download and install every artifact the
    \\                                     given installed packages need
    \\  ajt registry status                Summarise the installed General registry
    \\  ajt registry show <package>        Versions + uncompressed deps of a package
    \\  ajt registry add [NAME...]         Download a registry from the Pkg server and
    \\                                     install it into the depot (default: General)
    \\  ajt registry update [NAME...]      Re-download it if the server has a newer
    \\                                     tree hash than the installed one; a
    \\                                     git-cloned registry is fetched instead
    \\  ajt fetch [options] <url>          GET a URL with the Pkg-server protocol
    \\                                     headers (debug aid for the http gate)
    \\  ajt git ls-remote <url>            Refs a server advertises, through the
    \\                                     registered TLS stream (debug aid for
    \\                                     the libgit2 gate; needs -Dgit)
    \\  ajt git fetch <url> <dir> [rev]    Bare-clone <url> into <dir> with Pkg's
    \\                                     refspec, then resolve [rev]
    \\  ajt git materialise <dir> <tree> <dest>
    \\                                     Write <tree> out of the clone at <dir>
    \\                                     into <dest>, then print the hash of
    \\                                     what landed (AJT_GIT_BACKEND applies)
    \\  ajt git hash-object <file>...      libgit2's own SHA-1 of each file as a
    \\                                     blob, one per line, as `git hash-object`
    \\  ajt registry index [--rebuild]     Build the persistent binary index (.aix)
    \\                                     that makes every later load an mmap
    \\  ajt install [options] <Manifest.toml>
    \\                                     Download and install every manifest entry
    \\                                     that is pinned by git-tree-sha1 and not
    \\                                     already in the depot, then run Pkg's
    \\                                     fixups_from_projectfile! pass
    \\  ajt instantiate --frozen [options] [env]
    \\                                     Make the depot satisfy an environment's
    \\                                     Manifest.toml: registry, packages,
    \\                                     artifacts, manifest fixups, then verify.
    \\                                     Never resolves (see below)
    \\  ajt resolve [options] [env]        Run PubGrub over an environment: print
    \\                                     the version selection, and with
    \\                                     --write compose and write the
    \\                                     resolved Manifest.toml
    \\  ajt add [options] <Name[@version]|Name#rev|<url>[#rev]>...
    \\                                     Add packages to [deps], resolve, and
    \\                                     write both files. A url or a rev
    \\                                     clones instead: the tree is recorded
    \\                                     as repo-url/repo-rev/git-tree-sha1
    \\  ajt dev [options] <path|url>...    Track a package from a directory, or
    \\                                     clone one into <depot>/dev/<Name>.
    \\                                     A rev is refused, as Pkg refuses it
    \\  ajt pin [options] <Name[@ver]>...  Hold a manifest entry where it is, so
    \\                                     no later resolve moves it. Names a
    \\                                     DIRECT dependency, as Pkg.pin does.
    \\                                     A version must be exact: `Foo@1.2` is
    \\                                     the range [1.2.0, 2) in the project
    \\                                     grammar and is refused, not rounded
    \\  ajt free [options] <Name>...       Undo a pin, or stop tracking a path or
    \\                                     a repository, and re-resolve from the
    \\                                     registry. Unlike pin this names ANY
    \\                                     manifest entry. `unpin` is an alias
    \\  ajt rm [options] <Name>...         Remove packages from [deps] and prune
    \\                                     the manifest. Never resolves
    \\  ajt up [options] [Name...]         Move packages within the upgrade level
    \\                                     (default --major). No names = every
    \\                                     direct dependency
    \\  ajt precompile [options] [env]     Fill Julia's precompilation cache for an
    \\                                     environment: one `julia` child per
    \\                                     package, in dependency order, under the
    \\                                     same pidlock Pkg.precompile() takes
    \\  ajt build [options] [Name...]      Run each package's deps/build.jl in
    \\                                     dependency order, inside a sandbox
    \\                                     environment. No names = the project's
    \\                                     own package, else every manifest entry
    \\  ajt test [options] [Name...]      Run each package's test/runtests.jl in a
    \\                                     child julia, inside a sandbox built from
    \\                                     its test/Project.toml or its
    \\                                     [extras]+[targets] test list. No names =
    \\                                     the project's own package; a name may be
    \\                                     ANY manifest entry, not only a direct
    \\                                     dependency. Exit 1 if any suite fails
    \\  ajt why [--project D] <Name>...    The dependency paths that explain why a
    \\                                     package is in the manifest
    \\  ajt generate <path>                Scaffold a package: Project.toml and
    \\                                     src/<Pkg>.jl, and nothing else
    \\  ajt compat [--project D] <Name> [spec]
    \\                                     Set one [compat] bound, then re-resolve
    \\                                     to check the environment still complies.
    \\                                     No spec deletes the entry
    \\  ajt status [options] [Name]...     Pkg's status report, byte for byte
    \\                                     (see below; the environment is --env,
    \\                                     because the positionals are packages
    \\                                     exactly as `Pkg.status(pkgs...)` takes
    \\                                     them)
    \\  ajt usage record --log L <path>... Stamp <depot>/logs/L_usage.toml the way
    \\                                     Pkg's write_env_usage does, so Pkg.gc()
    \\                                     treats those paths as live
    \\  ajt usage keys [--log L]           Print the paths a usage log records
    \\  ajt manifest current [options] [env]
    \\                                     Was this manifest resolved from this
    \\                                     project? Pkg.is_manifest_current, exit
    \\                                     status and all (see below)
    \\  ajt manifest upgrade [options] <env|Manifest.toml>
    \\                                     Migrate a v1 manifest to the v2 format
    \\                                     without re-resolving
    \\  ajt gc [options]                   Delete what no live environment can
    \\                                     reach: packages, clones, artifacts and
    \\                                     scratchspaces orphaned for longer than
    \\                                     --collect-delay. Only the FIRST depot
    \\                                     is swept, and nothing is deleted the
    \\                                     first time it is seen orphaned
    \\  ajt version                        Print the version
    \\  ajt help                           This message
    \\
    \\global options (accepted anywhere on the command line):
    \\  --offline           Pkg.offline(true) / JULIA_PKG_OFFLINE. Skips the
    \\                      registry step, restricts every resolve to versions
    \\                      already unpacked in the depot, and refuses to make a
    \\                      network request at all. `JULIA_PKG_OFFLINE` turns it
    \\                      on too, on the truthy set Base.get_bool_env accepts
    \\                      (t/true/y/yes/1 and their Capitalized/UPPERCASE
    \\                      spellings); anything else is refused, as in Pkg.
    \\
    \\gc options:
    \\  --depot PATH        Depot stack, in DEPOT_PATH order. Only the first is
    \\                      SWEPT (Pkg.depots1()); the rest are still read, since
    \\                      a package installed in any of them is reachable.
    \\                      Default: $JULIA_DEPOT_PATH, else ~/.julia
    \\  --all               collect_delay = 0: reap everything orphaned right now.
    \\                      Pkg's `gc --all`
    \\  --collect-delay S   collect_delay in SECONDS (default 604800 = 7 days).
    \\                      Nothing is deleted the first time it is seen orphaned
    \\                      -- that run only records it in logs/orphaned.toml
    \\  --force             Sweep every --depot, not just the first. Pkg's REPL
    \\                      does not expose this; a stacked DEPOT_PATH usually has
    \\                      a read-only image depot behind the writable one
    \\  --dry-run           Print the deletion set and touch nothing at all --
    \\                      no unlinks, no orphanage, no condensed logs
    \\  -v, --verbose       Also print every path as it is deleted
    \\
    \\usage options:
    \\  --depot PATH        Depot to write into / read from (default: the first
    \\                      $JULIA_DEPOT_PATH entry, else ~/.julia). Pkg only ever
    \\                      writes depots1(), so only the first is used.
    \\  --log L             manifest (default) or artifact. scratch_usage.toml is
    \\                      refused: it is append-only and carries parent_projects
    \\                      that this writer would drop.
    \\  --allow-missing     record: skip Pkg's filter(isfile, ...) guard
    \\
    \\install options:
    \\  --depot PATH        Depot to search and install into. Repeatable; order is
    \\                      DEPOT_PATH order and the FIRST entry is the only one
    \\                      written to (Pkg.depots1()). Default: $JULIA_DEPOT_PATH,
    \\                      else ~/.julia.
    \\  --registry-depot P  Depot to read the registry from (default: the first
    \\                      --depot). Lets an install target a scratch depot while
    \\                      the registry stays where it is.
    \\  --registry NAME     Registry name (default: General)
    \\  --source S          Registry backend: auto (default), aix, or archive
    \\  --server URL        Pkg server (default: $JULIA_PKG_SERVER, else
    \\                      https://pkg.julialang.org; empty disables it, leaving
    \\                      only the GitHub tarball fallback)
    \\  --jobs N            Concurrent downloads (default:
    \\                      $JULIA_PKG_CONCURRENT_DOWNLOADS, else 8)
    \\  --dry-run           Print the candidate URL list per package and download
    \\                      nothing
    \\  --no-download       Run only the fixups pass, writing nothing to the depot
    \\  --no-fixups         Skip fixups_from_projectfile!
    \\  --no-git            Never clone. A repo-url entry, and any package no
    \\                      archive can serve, then fails instead of falling back
    \\                      to git (Pkg's install_git, Operations.jl:830)
    \\  --stdlib DIR        Julia's stdlib directory, so stdlib manifest entries
    \\                      resolve during fixups (Types.stdlib_dir())
    \\  --julia-bindir D    Sys.BINDIR, used to expand the bundled depots when
    \\                      DEPOT_PATH is resolved (default: the directory of
    \\                      the first `julia` on PATH)
    \\  --output FILE       Write the fixed-up manifest to FILE (pass the input
    \\                      path to rewrite in place)
    \\
    \\fetch options:
    \\  --server URL        Pkg server (default: $JULIA_PKG_SERVER, else
    \\                      https://pkg.julialang.org; empty disables it)
    \\  --depot PATH        Depot holding servers/<host>/auth.toml
    \\  --julia-version V   Value of the Julia-Version header
    \\  --julia-system T    Value of the Julia-System header (host triplet)
    \\  --julia-prefix P    Derive --julia-system from this Julia install instead
    \\  --retry N           Total attempts (default 1; Pkg uses 4 for /registries)
    \\  --no-auth           Never attach a bearer token
    \\  --print-headers     Print the request headers instead of performing the GET
    \\  --status            Print "<code> <bytes> <final-url>" on stderr as well
    \\
    \\artifact subcommands:
    \\  info <Artifacts.toml>...        Per artifact name, the entry `artifact_meta`
    \\                                  selects: git-tree-sha1, lazy, download info
    \\  downloadable <Artifacts.toml>...
    \\                                  What `select_downloadable_artifacts` returns
    \\  resolve <Artifacts.toml>...     info + where each selected artifact lands on
    \\                                  disk, honouring Overrides.toml
    \\  path <sha1>...                  artifact_path/artifact_exists for raw hashes
    \\  find <package-root>...          Which of JuliaArtifacts.toml/Artifacts.toml
    \\                                  a package root exposes
    \\
    \\artifact options:
    \\  --host <k=v,...>    Host tag set to select for (same shape as
    \\                      select-artifact and the output of host-platform)
    \\  --depot PATH        Depot for artifact paths and Overrides.toml. Repeatable;
    \\                      order is DEPOT_PATH order, and the first entry wins an
    \\                      override conflict. Default: every entry of
    \\                      $JULIA_DEPOT_PATH, else ~/.julia.
    \\  --pkg-uuid UUID     Owning package, so UUID/name overrides resolve
    \\  --include-lazy      Include lazy artifacts in `downloadable`
    \\  --no-overrides      Ignore Overrides.toml (honor_overrides=false)
    \\
    \\instantiate options:
    \\  --frozen            The manifest is authoritative: no resolve, ever. This
    \\                      is the only behaviour instantiate has. It does NOT
    \\                      mean read-only — a frozen instantiate downloads,
    \\                      installs, and writes the fixups metadata back into
    \\                      Manifest.toml, exactly as Pkg.instantiate() does.
    \\  --depot PATH        Depot to search and install into. Repeatable;
    \\                      DEPOT_PATH order, first entry is written to.
    \\                      Default: the resolved $JULIA_DEPOT_PATH.
    \\  --registry-depot P  Depot that owns registries/ (default: the first depot)
    \\  --registry NAME     Registry name (default: General)
    \\  --registry-policy P if-missing (default), always, or never. The registry
    \\                      is only consulted for the GitHub tarball fallback
    \\                      URL, so `never` costs that fallback and nothing else.
    \\  --source S          Registry backend: auto (default), aix, or archive
    \\  --server URL        Pkg server (default: $JULIA_PKG_SERVER, else
    \\                      https://pkg.julialang.org; empty disables it)
    \\  --jobs N            Concurrent downloads, packages AND artifacts
    \\                      (default: $JULIA_PKG_CONCURRENT_DOWNLOADS, else 8)
    \\  --manifest FILE     Use this manifest instead of probing for one
    \\  --host <k=v,...>    Platform to select artifacts for (default: detected
    \\                      from --julia-prefix and the manifest's julia_version)
    \\  --julia-bindir D    Sys.BINDIR, used to expand the bundled depots when
    \\                      DEPOT_PATH is resolved (default: the directory of
    \\                      the first `julia` on PATH)
    \\  --julia-prefix P    Julia install (dirname of Sys.BINDIR). Default:
    \\                      derived from `julia` on $PATH. Without one, artifacts
    \\                      cannot be planned and the run FAILS rather than
    \\                      installing an environment with no JLLs in it.
    \\  --julia-version V   The Julia this environment targets (default: the
    \\                      manifest's own julia_version)
    \\  --stdlib DIR        Types.stdlib_dir() (default: derived from the prefix)
    \\  --include-lazy      Also install lazy artifacts
    \\  --no-overrides      Ignore Overrides.toml
    \\  --no-artifacts      Skip the artifact step
    \\  --no-fixups         Skip fixups_from_projectfile!
    \\  --no-git            Never clone (see `install options`)
    \\  --no-write-manifest Run fixups but never write Manifest.toml back
    \\  --no-precompile     Do not precompile afterwards. Pkg.instantiate()'s
    \\                      `allow_autoprecomp = false` (API.jl:1288); the
    \\                      pass is ON by default, as Pkg's is, and honours
    \\                      $JULIA_PKG_PRECOMPILE_AUTO either way.
    \\  --precompile        The default, spelled out
    \\  --dry-run           Print the plan; download nothing, write nothing
    \\  --quiet             Summary lines only, no per-item records
    \\
    \\resolve options:
    \\  --preserve TIER     Which recorded versions are held (PreserveLevel):
    \\                        all       (default) every manifest entry, which is
    \\                                  what Pkg's resolve/instantiate run
    \\                        installed as `all`, but only versions already
    \\                                  unpacked in the depot are candidates
    \\                        direct    direct deps held, the closure free
    \\                        semver    direct deps may move compatibly
    \\                        none      nothing held; resolve from [compat]
    \\                        tiered    all -> direct -> semver -> none, first
    \\                                  that resolves (Pkg's add default)
    \\                        tiered_installed   installed first, then tiered
    \\                      The manifest is READ at every tier — it is what the
    \\                      report diffs against. A path-tracked, repo-tracked
    \\                      or pinned entry holds at ALL of them.
    \\  --depot PATH        Depot holding registries/ (default: the first
    \\                      $JULIA_DEPOT_PATH entry, else ~/.julia)
    \\  --julia-prefix P    Julia install (dirname of Sys.BINDIR), for the
    \\                      stdlib set. Default: derived from `julia` on $PATH.
    \\  --julia-version V   The Julia this environment targets (default: the
    \\                      manifest's own julia_version)
    \\  --changed           Print only the entries whose version moved
    \\  --quiet             Summary line only
    \\  --write             Compose the resolved Manifest.toml and write it to
    \\                      the environment. Atomic (tmp + rename) and skipped
    \\                      entirely when the bytes are unchanged, so the
    \\                      mtime only moves when the content does.
    \\  --out FILE          Write it here instead. Implies --write.
    \\  --registry-source S auto (default), aix or archive. `auto` maps the
    \\                      binary index when one matches the installed
    \\                      registry and parses the tarball otherwise; the
    \\                      other two pin a side so a gate can compare them.
    \\  --no-fixups         Skip the fixups pass, which reads weakdeps,
    \\                      extensions and entryfile out of each INSTALLED
    \\                      package's own Project.toml — the only place that
    \\                      information exists (Operations.jl:250-252). Without
    \\                      it those three fields are absent from every entry,
    \\                      which is a manifest Julia loads and Pkg rewrites.
    \\
    \\  Output is one tab-separated line per selected package, and these four
    \\  kinds are NOT interchangeable:
    \\    held         <name> <version>        manifest recorded it, unmoved
    \\    changed      <name> <was> <now>      manifest recorded a different one
    \\    unversioned  <name> <version>        in the manifest with no `version`
    \\                                        key — an unversioned stdlib, which
    \\                                        Pkg writes bare (Types.jl:600-609).
    \\                                        Ajt still picks a version for it
    \\    added        <name> <version>        NOT in the manifest at all. Under
    \\                                        --preserve all the only legitimate
    \\                                        one is `julia`
    \\  then, with --write:
    \\    manifest     <path> <entries> written|unchanged
    \\    no-source    <name>                  survived the prune but is not
    \\                                         installed, so its weakdeps and
    \\                                         extensions could not be read
    \\  and always: summary <total> <changed> <unversioned> <added> <ms>
    \\
    \\  Note that <entries> is normally SMALLER than <total>: the selection is
    \\  what the solver chose, the manifest is what survives `prune_manifest`
    \\  (Operations.jl:1252) — everything reachable from the project's [deps]
    \\  through strong edges only. Open-Reality resolves 214 and writes 205.
    \\
    \\precompile options:
    \\  --depot PATH        Depot to write caches into and search. Repeatable;
    \\                      DEPOT_PATH order, and the FIRST entry is the only
    \\                      one written to -- Julia's compilecache_dir writes to
    \\                      DEPOT_PATH[1] (loading.jl:3147). Default: the
    \\                      resolved $JULIA_DEPOT_PATH.
    \\  --julia PATH        The julia to run (default: <prefix>/bin/julia when a
    \\                      prefix is known, else the first `julia` on $PATH).
    \\                      It matters which one: the julia binary and its
    \\                      sysimage are mixed into the cache filename.
    \\  --julia-prefix P    Julia install (dirname of Sys.BINDIR). Default:
    \\                      derived from `julia` on $PATH.
    \\  --julia-version V   The Julia this environment targets (default: the
    \\                      manifest's own julia_version)
    \\  --julia-bindir D    Sys.BINDIR, used to expand the bundled depots when
    \\                      DEPOT_PATH is resolved
    \\  --manifest FILE     Use this manifest instead of probing for one
    \\  --jobs N            Children compiling at once. Default: the machine's CPU
    \\                      width, capped by any cgroup quota. 1 walks serially.
    \\  --only P[,P...]     Precompile only these packages (or extensions) plus
    \\                      everything they depend on — Pkg.precompile(pkgs)'s
    \\                      filter. Repeatable, comma-splittable. Extensions of
    \\                      the kept set come along uninvited, as they do for
    \\                      Pkg; a name matching nothing contributes nothing,
    \\                      silently, also as Pkg. The case this exists for:
    \\                      an image build that has copied only the two
    \\                      manifests names the direct deps here, and the
    \\                      project itself — whose source is not there yet —
    \\                      stays out instead of counting as a failure.
    \\  --dry-run           Print the plan and compile nothing. Still starts ONE
    \\                      julia -- "what is already precompiled" is a question
    \\                      only Julia can answer -- and that child loads no
    \\                      package and writes nothing. Also prints the shared-
    \\                      cache address of each package: `key <name> <key>
    \\                      <local path>`.
    \\  --cache-url URL     Base URL of a shared precompile cache. Default:
    \\                      $AJT_CACHE_URL; unset means NO shared cache, no
    \\                      network, and exactly what Pkg.precompile() does.
    \\                      There is no public store to default to, so a
    \\                      built-in URL would 404 on every lookup.
    \\  --no-cache          Ignore $AJT_CACHE_URL for this run
    \\  --cache-token T     Bearer token sent on cache PUBLISHES (PUT). Default:
    \\                      $AJT_CACHE_TOKEN; unset means publishes go out with
    \\                      no Authorization header, which an open store may
    \\                      accept and a gated one will refuse. Lookups (GET)
    \\                      never send it. Only this command takes one: the
    \\                      auto-precompile after add/up/instantiate is
    \\                      read-only by design and has nothing to publish.
    \\  --quiet             Summary line only
    \\
    \\  The ORDER is the point: a package's dependencies must already have
    \\  caches before its child runs, which is what Pkg buys with an Event per
    \\  node. Independent packages run at once over the frontier scheduler,
    \\  bounded by --jobs and by a memory bucket, so a wide box is not held to
    \\  the shape of the manifest. --jobs 1 restores the plain serial walk,
    \\  which is also what a manifest with a dependency cycle falls back to.
    \\
    \\  Output is one tab-separated line per package in the walked order,
    \\  `package <outcome> <name> <uuid> <ms> <source>`, where <outcome> is:
    \\    compiled             this run built the cache entry
    \\    already_precompiled  Base.isprecompiled was true; no child was spawned
    \\    waited               another process held the pidlock and did it
    \\    stale                needs compiling -- the plan, under --dry-run
    \\    in_sysimage          Pkg never compiles these (precompilation.jl:624)
    \\    not_precompilable    __precompile__(false)
    \\    source_missing       not installed; instantiate first. Counts as a
    \\                         FAILURE, as it does for Pkg, which puts it
    \\                         straight into failed_deps (precompilation.jl:1017)
    \\    circular             in, or downstream of, a dependency cycle
    \\    failed               the child exited non-zero; see stderr
    \\  then:
    \\    summary <considered> <compiled> <already> <stale> <skipped> <failed> <ms>
    \\
    \\  Package EXTENSIONS are nodes too, as they are for Pkg
    \\  (precompilation.jl:626-668): a module under a parent's ext/ that Julia
    \\  loads once every trigger is loaded, with a cache entry of its own. They
    \\  get their own record kind rather than a decorated `package` row --
    \\  `extension <outcome> <parent> <name> <uuid> <ms> <source>` -- because two
    \\  parents may declare extensions with the SAME name, so the name alone does
    \\  not identify the row. A final line
    \\    extensions <nodes> <dormant>
    \\  counts them: <dormant> are declared extensions that are NOT nodes because
    \\  a trigger is absent from the closure, which Pkg does not compile either.
    \\  Leaving them out is what used to leave an environment 173 packages deep
    \\  looking complete and 17 entries short.
    \\
    \\add / rm / up / pin / free / dev options:
    \\  --project D         The environment (default: the current directory)
    \\  --depot PATH        Depot holding registries/ and installed packages
    \\                      (default: the first $JULIA_DEPOT_PATH entry)
    \\  --julia-prefix P    Julia install, for the stdlib set
    \\  --julia-version V   The Julia this environment targets
    \\  --preserve TIER     add: which versions may move (default tiered, as
    \\                      Pkg's default_preserve). up ignores it: its tier is
    \\                      decided by the level.
    \\  --major|--minor|--patch|--fixed
    \\                      up only. How far a package may move from what the
    \\                      manifest records: --patch keeps major.minor, --minor
    \\                      keeps major, --major is unconstrained, --fixed moves
    \\                      nothing. Default --major, as Pkg.update().
    \\  --level L           The same, spelled out: fixed|patch|minor|major
    \\  --no-fixups         Skip the fixups pass (see `resolve options`)
    \\  --no-precompile     Do not precompile afterwards
    \\  --precompile        Precompile even after a verb Pkg does not
    \\                      precompile after (dev). Never overrides
    \\                      $JULIA_PKG_PRECOMPILE_AUTO=0 -- that variable means
    \\                      "nothing here precompiles implicitly", and
    \\                      `ajt precompile` is the explicit command.
    \\  --dry-run           Resolve and report; write nothing
    \\  --quiet             Skip the per-package lines
    \\
    \\  add, up, pin and free PRECOMPILE the environment afterwards, and dev
    \\  and rm do not -- Pkg's own split, which comes out of two unrelated
    \\  places (API.jl:170 for up/pin/free, Operations.jl:1828 for add, and
    \\  nothing at all for develop). Set JULIA_PKG_PRECOMPILE_AUTO=0 to turn it
    \\  off everywhere, exactly as it turns Pkg's off (Pkg.jl:65). The pass is
    \\  `ajt precompile`, reads $AJT_CACHE_URL for the shared store (read-only:
    \\  it imports, it never publishes), and reports as one line:
    \\    precompile <considered> <compiled> <already> <failed> <imported>
    \\  or `precompile skipped <why>` when it did not run.
    \\
    \\  `rm` does not resolve. It drops the names from [deps], filters
    \\  [compat]/[sources]/[targets] down to what is left, prunes the manifest
    \\  to what is still reachable and rewrites project_hash — so every
    \\  surviving entry keeps the exact version it had. That is Pkg's behaviour
    \\  (Operations.jl:1522-1591) and it is the point: removing one package
    \\  should not silently move the others.
    \\
    \\  `add Foo@1.2` constrains the RESOLVE and writes no [compat] entry,
    \\  again as Pkg does. Use a [compat] edit if you want the bound recorded.
    \\
    \\add / dev repository options:
    \\  --url U             The repository to clone. Only a URL by Pkg.isurl's
    \\                      answer; a local git repository by path is not
    \\                      implemented.
    \\  --rev R             `add` only. Branch, tag or commit; without one,
    \\                      `add <url>` takes the clone's default branch if
    \\                      HEAD is attached and its current commit if not,
    \\                      exactly as handle_repo_add! does. `dev` REFUSES a
    \\                      rev, as Pkg.develop does ("rev argument not
    \\                      supported by `develop`").
    \\  --subdir D          The package's directory inside a monorepo. For
    \\                      `dev <path>` it is joined onto the path, so the
    \\                      recorded path is <path>/<subdir>.
    \\  --shared|--local    dev only. --shared (the default, as Pkg's) clones
    \\                      into Pkg.devdir() — $JULIA_PKG_DEVDIR, else
    \\                      <depot>/dev — and records an absolute path;
    \\                      --local uses <env>/dev and records a relative one.
    \\
    \\  The url and the rev can be written inline: `Name#rev`, `<url>`,
    \\  `<url>#rev`. The rev is everything after the FIRST `#` (Pkg's REPL
    \\  grammar), so the flags are what a name or URL containing a `#` needs.
    \\
    \\  `add <url>` clones to <depot>/clones/<hash(url)> — the same cache
    \\  directory Pkg uses and the one Pkg.gc() recomputes — and installs the
    \\  tree at packages/<Name>/<slug>, where Julia's loader looks for it. The
    \\  URL is the cache key VERBATIM, so `…/Example.jl` and `…/Example.jl.git`
    \\  are two different clones, to Pkg as well as here.
    \\
    \\  An ssh:// or git@host:path URL is refused: this build has no SSH
    \\  transport. Use the https form, or JULIA_PKG_USE_CLI_GIT=1 with `git`
    \\  installed.
    \\
    \\verify options:
    \\  --frozen            Never resolve, never download, never write. This is
    \\                      the only behaviour verify has; the flag states the
    \\                      contract at the call site.
    \\  --check-hashes      Also re-tree-hash every installed package and compare
    \\                      it to its git-tree-sha1. Reads every installed file,
    \\                      so it is seconds rather than milliseconds — off by
    \\                      default.
    \\  --depot PATH        Depot to search. Repeatable; order is DEPOT_PATH
    \\                      order. Default: the resolved $JULIA_DEPOT_PATH.
    \\  --julia-prefix P    Julia install (dirname of Sys.BINDIR), for the stdlib
    \\                      cross-check. Default: derived from `julia` on $PATH.
    \\  --julia-version V   The Julia this environment targets, e.g. 1.12.6.
    \\                      Default: the manifest's own julia_version.
    \\  --quiet             Print nothing; report through the exit status only.
    \\
    \\install-artifacts options:
    \\  --host <k=v,...>    Host tag set to select for (required; the output of
    \\                      `ajt host-platform`)
    \\  --depot PATH        Repeatable, DEPOT_PATH order. Every entry is searched
    \\                      for an already-installed artifact; the FIRST is the
    \\                      one written to. Default: $JULIA_DEPOT_PATH, else
    \\                      ~/.julia
    \\  --pkg-uuid UUID     Owning package of the roots that FOLLOW, so its
    \\                      UUID/name Overrides.toml entries resolve
    \\  --server URL        Pkg server, tried before every listed mirror
    \\                      (default: $JULIA_PKG_SERVER; empty disables it)
    \\  --julia-version V   Value of the Julia-Version header
    \\  --julia-system T    Value of the Julia-System header (host triplet)
    \\  --julia-prefix P    Derive --julia-system from this Julia install instead
    \\  --include-lazy      Also install lazy artifacts
    \\  --no-overrides      Ignore Overrides.toml
    \\  --retry N           Download attempts per source (default 3, as Pkg)
    \\  --dry-run           Print the plan; download nothing
    \\
    \\registry options:
    \\  --depot PATH        Depot to read from (default: $JULIA_DEPOT_PATH's first
    \\                      entry, else ~/.julia)
    \\  --registry NAME     Registry name (default: General)
    \\  --source S          Where to read the registry from: `auto` (default —
    \\                      the .aix index when one matches the installed
    \\                      registry, else the tarball), `aix`, or `archive`
    \\  --detail            `show`: also print package uuid/repo and each
    \\                      dependency's uuid
    \\  --uuid UUID         `add`/`update`: address the registry by UUID rather
    \\                      than by name (required for a registry Ajt has no
    \\                      built-in entry for)
    \\  --url URL           `add`: git repository to clone the registry from
    \\                      when the Pkg server cannot serve it. The registry's
    \\                      own Registry.toml decides the installed name.
    \\  --server URL        `add`/`update`: Pkg server (default:
    \\                      $JULIA_PKG_SERVER, else https://pkg.julialang.org).
    \\                      Empty disables it, and the registry is then cloned
    \\                      over git instead, as Pkg does.
    \\  --unpack            `add`/`update`: install as a directory rather than a
    \\                      tarball, i.e. force JULIA_PKG_UNPACK_REGISTRY
    \\  --dry-run           `add`/`update`: print every pin the server offers and
    \\                      what would happen, then exit without writing
    \\
    \\build options:
    \\  --project DIR       The environment (default: .)
    \\  --depot PATH        Repeatable, DEPOT_PATH order. The FIRST is depots1():
    \\                      where a scratchspace build.log and its
    \\                      logs/scratch_usage.toml entry land
    \\  --manifest FILE     Override manifest discovery
    \\  --julia PATH        The julia to run the build scripts with
    \\  --julia-prefix P    dirname(Sys.BINDIR) of that julia
    \\  --julia-version V   e.g. 1.12.6, for stdlib and manifest-name selection
    \\  --julia-bindir D    Expand an empty $JULIA_DEPOT_PATH entry against THIS
    \\                      julia's bundled depots rather than --julia-prefix's
    \\  --registry-depot D  Depot holding registries/<name>, enabling the sandbox
    \\                      resolve. Without it the sandbox uses the parent
    \\                      manifest's versions verbatim -- Pkg's success path,
    \\                      but with no re-resolve fallback
    \\  --registry NAME     Registry name (default: General)
    \\  --startup-file      Run the children with --startup-file=yes. Pkg mirrors
    \\                      the PARENT session's flag; ajt is not a julia, so the
    \\                      default is `no` and this states otherwise
    \\  --interactive       Show the last 100 log lines on a failure rather than
    \\                      5000, which is what Pkg does when isinteractive()
    \\  --verbose           Also copy each build's output to stderr
    \\  --dry-run           Print the plan and the log paths; run nothing
    \\
    \\  Output: one `build` record per package with a deps/build.jl, in the order
    \\  they ran:
    \\
    \\    build<TAB>ok|failed<TAB><name><TAB><uuid><TAB><log file><TAB><ms>
    \\
    \\  The FIRST failure stops the run and exits non-zero, as Pkg does -- a
    \\  later package's build script often consumes an earlier one's output, so
    \\  continuing would bury the real error under unrelated ones.
    \\
    \\status options:
    \\  --env DIR           The environment (default: .). Spelled `--env` rather
    \\                      than a positional because the positionals are the
    \\                      package filters Pkg's `status [pkgs...]` takes.
    \\  -p, --project       Report on the project (default)
    \\  -m, --manifest      Report on the manifest, i.e. recursive dependencies
    \\  -o, --outdated      Only packages that are not at their newest registered
    \\                      version, with the reason
    \\  -c, --compat        Print the project's [compat] entries instead
    \\  -e, --extensions    Only packages that declare extensions, with them
    \\  --manifest-file F   Override manifest discovery (`--manifest` is the mode
    \\                      flag here, as in Pkg)
    \\  --depot PATH        Repeatable, DEPOT_PATH order. Decides whether a
    \\                      package counts as downloaded. Default: the resolved
    \\                      $JULIA_DEPOT_PATH.
    \\  --registry-depot P  Pin the registry to one depot. Default: the first
    \\                      --depot entry that has one, which is Julia's own
    \\                      reachable_registries() search. The registry is what
    \\                      `⌃`/`⌅` and --outdated are computed from; with none
    \\                      anywhere the report carries no upgrade markers,
    \\                      exactly as Pkg's does with no registries installed.
    \\  --registry NAME     Registry name (default: General)
    \\  --julia-prefix P    Julia install (dirname of Sys.BINDIR). Required —
    \\                      the row order itself depends on Types.stdlibs().
    \\                      Default: derived from `julia` on $PATH.
    \\  --julia-version V   The Julia this environment targets, e.g. 1.12.6.
    \\                      Default: the manifest's own julia_version.
    \\  -d, --diff          REFUSED: reading Project/Manifest out of git HEAD
    \\  --workspace         REFUSED, as everywhere else in ajt
    \\
    \\fmt options:
    \\  --sorted            Sort keys (what Pkg uses when writing manifests)
    \\  --respect-inline    Keep `{k = v}` tables inline instead of expanding them
    \\                      to [headers]. Off by default so output matches
    \\                      TOML.print(TOML.parsefile(f)), which loses inlineness.
    \\  --filelist FILE     Read input paths from FILE, one per line
    \\  --outdir DIR        Write each input's output to DIR/<n>.out (1-based, in
    \\                      input order) instead of concatenating to stdout.
    \\                      Together these format a whole corpus in one process,
    \\                      which is the difference between the differential gate
    \\                      taking seconds and taking many minutes.
    \\
    \\manifest options:
    \\  --manifest F        current only: read F instead of probing for the
    \\                      manifest. Refused for upgrade, which rewrites the
    \\                      file it resolves and takes it as its argument.
    \\  --julia-prefix P    Julia install, and --julia-version V the version it
    \\  --julia-version V   targets. Used ONLY to choose between Manifest.toml and
    \\                      the version-specific Manifest-v<major>.<minor>.toml,
    \\                      which sorts AHEAD of it; no depot is read either way.
    \\                      Pass them whenever the environment might carry a
    \\                      version-specific manifest: without them both verbs
    \\                      fall through to plain Manifest.toml, which is a file
    \\                      the loader may never read.
    \\  --dry-run           upgrade only: report what would change, write nothing
    \\  --quiet             Print nothing; report through the exit status only
    \\
    \\  `manifest current` is Pkg.is_manifest_current, which returns THREE values,
    \\  so it needs three exit codes and a fourth for "no answer was produced":
    \\
    \\      0  true     — the manifest records this project's hash
    \\      1  false    — it records a DIFFERENT hash: resolve
    \\      2  nothing  — it records none, or there is no manifest at all. Pkg's
    \\                    own callers test `=== false`, i.e. they treat this as
    \\                    "carry on"; it is NOT a stale environment and must not
    \\                    be read as one
    \\      3  no answer: no project file, an unparseable file, a [workspace] —
    \\                    or a bad invocation, --help included. 0 means `true`,
    \\                    so nothing that is not an answer may exit 0 or 1.
    \\
    \\  0/1 that way round so `if ajt manifest current; then` reads as the
    \\  boolean, and "nothing" lands outside it rather than being silently
    \\  rounded to either answer.
    \\
    \\  `manifest upgrade` changes `manifest_format` from 1.0 to 2.0 and nothing
    \\  else — it does not re-resolve, prune, or record a project_hash or a
    \\  julia_version (run `ajt resolve` for those). An already-v2 manifest is
    \\  REFUSED rather than rewritten, exactly as Pkg refuses it, so the file
    \\  keeps its bytes and its mtime.
    \\
;

const version = "0.0.1";

/// `Pkg.OFFLINE_MODE[]` (`Pkg/src/Pkg.jl:45`), for this process.
///
/// Pkg's is a process-global `Ref{Bool}` and so is this, because `--offline`
/// is a statement about the run rather than about one verb: it has to reach
/// the resolver's candidate filter, the registry step and the transport, three
/// layers that otherwise share nothing. The library underneath takes it as an
/// ordinary field on every Options struct — this global exists only between
/// `main`'s argument scan and the `cmd*` that consumes it, which is what keeps
/// `src/` free of ambient state.
var offline_flag = false;

/// `ajt.net.Config.fromEnv` plus the global `--offline`.
///
/// `fromEnv` reads `JULIA_PKG_OFFLINE` on its own — a library caller gets that
/// for free — but it cannot see a command-line flag, and the flag is the half
/// that has to win. Every command that can make a request builds its transport
/// config through here so there is one place where those two spellings meet.
fn netConfig(
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    base: ajt.net.Config,
) !ajt.net.Config {
    var cfg = try ajt.net.Config.fromEnv(arena, environ, base);
    if (offline_flag) cfg.offline = true;
    return cfg;
}

/// Strip `--offline` from `args`, wherever it appears.
///
/// A per-verb `else if` in each of the ten `cmd*` argument loops would not
/// work: `ajt registry add` reads its subcommand positionally, so `--offline`
/// before it would be taken as the subcommand, and after it would have to be
/// handled twice. Stripping ahead of dispatch makes `ajt --offline add Foo`,
/// `ajt add --offline Foo` and `ajt registry --offline update` all mean the
/// same thing, which is what a global flag has to mean.
///
/// The cost is that `ajt fmt --offline x.toml` is accepted rather than
/// rejected as an unknown option. That is the correct trade for a flag whose
/// environment-variable spelling every command already honours.
fn stripGlobalFlags(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    // The overwhelmingly common case is that the flag is absent, and then the
    // argv every other command sees is the one it always saw — same slice, no
    // copy, nothing to get wrong.
    for (args) |a| {
        if (std.mem.eql(u8, a, "--offline")) break;
    } else return args;

    offline_flag = true;
    var kept: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--offline")) continue;
        try kept.append(arena, a);
    }
    return kept.items;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try stripGlobalFlags(arena, try init.minimal.args.toSlice(arena));

    // `OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)`
    // (`Pkg.jl:827`), which Pkg does in `__init__` — i.e. before any command
    // runs, and fatally when the value is neither truthy nor falsy. Same here:
    // a run configured by a variable nobody can parse must not proceed as if
    // the variable were absent.
    const offline_env = ajt.net.http.offlineFromEnv(init.environ_map) catch |err| {
        std.debug.print(
            "ajt: JULIA_PKG_OFFLINE is set to something that is neither true nor false\n" ++
                "     (Base.get_bool_env accepts t/true/y/yes/1 and f/false/n/no/0, plus\n" ++
                "     their Capitalized and UPPERCASE spellings, and nothing else).\n" ++
                "     `using Pkg` fails on the same value.\n",
            .{},
        );
        return err;
    };
    // OR: `JULIA_PKG_OFFLINE=false` must not undo a `--offline` the user typed.
    if (offline_env) offline_flag = true;

    var stdout_buf: [64 * 1024]u8 = undefined;
    // STREAMING, not `.init` (= positional). A positional writer pwrites from
    // its own offset — zero — which is fine right up until another process
    // shares the open file description: `ajt test`'s children inherit fd 1 and
    // write the suite's output at the SHARED offset, and the report's pwrite
    // at 0 then silently overwrites it whenever stdout is a redirected file
    // (`ajt test > log`). Streaming uses plain write(2), which advances the
    // shared offset and composes with children the way every other CLI does.
    var stdout_file: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 2) {
        try out.writeAll(usage);
        try out.flush();
        return error.MissingCommand;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try out.print("ajt {s}\n", .{version});
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "fmt")) {
        try cmdFmt(gpa, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "tree-hash")) {
        try cmdTreeHash(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "project-hash")) {
        try cmdProjectHash(gpa, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "host-platform")) {
        try cmdHostPlatform(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "select-artifact")) {
        try cmdSelectArtifact(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "artifact")) {
        try cmdArtifact(gpa, arena, io, init.environ_map, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        try cmdVerify(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "install-artifacts")) {
        try cmdInstallArtifacts(gpa, arena, io, init.environ_map, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "registry")) {
        try cmdRegistry(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "fetch")) {
        try cmdFetch(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "install")) {
        try cmdInstall(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "instantiate")) {
        try cmdInstantiate(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "resolve")) {
        try cmdResolve(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "add")) {
        try cmdEdit(arena, io, out, init.environ_map, .add, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "remove")) {
        try cmdEdit(arena, io, out, init.environ_map, .rm, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "up") or std.mem.eql(u8, cmd, "update")) {
        try cmdEdit(arena, io, out, init.environ_map, .up, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "pin")) {
        try cmdEdit(arena, io, out, init.environ_map, .pin, args[2..]);
        try out.flush();
        return;
    }
    // `unpin` is not a Pkg verb; `free` is what undoes a pin. Accepted as an
    // alias because it is what people reach for, and refusing a name that
    // obviously means this would be pedantry.
    if (std.mem.eql(u8, cmd, "free") or std.mem.eql(u8, cmd, "unpin")) {
        try cmdEdit(arena, io, out, init.environ_map, .free, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "dev") or std.mem.eql(u8, cmd, "develop")) {
        try cmdEdit(arena, io, out, init.environ_map, .dev, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "precompile")) {
        try cmdPrecompile(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "why")) {
        try cmdWhy(arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "usage")) {
        try cmdUsage(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "manifest")) {
        try cmdManifest(gpa, arena, io, out, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "generate")) {
        try cmdGenerate(arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "compat")) {
        try cmdCompat(arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "status") or std.mem.eql(u8, cmd, "st")) {
        try cmdStatus(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "gc")) {
        try cmdGc(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "git")) {
        try cmdGit(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "test")) {
        try cmdTest(gpa, arena, io, out, init.environ_map, args[2..]);
        try out.flush();
        return;
    }

    try out.writeAll(usage);
    try out.flush();
    return error.UnknownCommand;
}

fn cmdFmt(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const []const u8) !void {
    var opts: ajt.toml.EmitOptions = .{};
    var outdir: ?[]const u8 = null;
    var filelist: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--sorted")) {
            opts.sorted = true;
        } else if (std.mem.eql(u8, arg, "--respect-inline")) {
            opts.respect_inline = true;
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            i += 1;
            if (i >= args.len) return missingValue("--outdir");
            outdir = args[i];
        } else if (std.mem.eql(u8, arg, "--filelist")) {
            i += 1;
            if (i >= args.len) return missingValue("--filelist");
            filelist = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("ajt fmt: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        } else {
            try files.append(gpa, arg);
        }
    }

    // A file list is read wholesale and sliced in place; the backing buffer
    // must outlive the loop below, hence the deferred free rather than a
    // scoped one.
    var list_buf: ?[]u8 = null;
    defer if (list_buf) |b| gpa.free(b);
    if (filelist) |lf| {
        const buf = Io.Dir.cwd().readFileAlloc(io, lf, gpa, .limited(256 * 1024 * 1024)) catch |err| {
            std.debug.print("ajt fmt: cannot read file list '{s}': {s}\n", .{ lf, @errorName(err) });
            return err;
        };
        list_buf = buf;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) try files.append(gpa, trimmed);
        }
    }

    if (files.items.len == 0) {
        std.debug.print("ajt fmt: no input files\n", .{});
        return error.MissingArgument;
    }

    var failures: usize = 0;
    for (files.items, 1..) |path, n| {
        const src = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("ajt fmt: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
            if (outdir == null) return err;
            failures += 1;
            continue;
        };
        defer gpa.free(src);

        var diag: ajt.toml.Diagnostic = .{};
        var doc = ajt.toml.parse(gpa, src, &diag) catch |err| {
            std.debug.print("{s}: line {d}, column {d}: {s}\n", .{ path, diag.line, diag.column, diag.message });
            // In batch mode a single bad file must not abort the corpus; the
            // harness needs a result for every entry to report against.
            if (outdir == null) return err;
            failures += 1;
            continue;
        };
        defer doc.deinit();

        if (outdir) |dir| {
            const rendered = try ajt.toml.emit_mod.emitAlloc(gpa, doc.root, opts);
            defer gpa.free(rendered);
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{d}.out", .{n});
            var sub = try Io.Dir.cwd().openDir(io, dir, .{});
            defer sub.close(io);
            try sub.writeFile(io, .{ .sub_path = name, .data = rendered });
        } else {
            try ajt.toml.emit(gpa, out, doc.root, opts);
        }
    }

    if (failures > 0) {
        std.debug.print("ajt fmt: {d} of {d} file(s) failed\n", .{ failures, files.items.len });
        return error.SomeFilesFailed;
    }
}

/// `ajt tree-hash <dir>...` — prints `<sha1>  <dir>` per argument, so it can be
/// diffed directly against Julia's `Pkg.GitTools.tree_hash`.
fn cmdTreeHash(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--filelist")) {
            i += 1;
            if (i >= args.len) return missingValue("--filelist");
            // Read into the PROCESS arena, not gpa: the path slices below
            // borrow from this buffer for the rest of the run, and the arena
            // is exactly the allocator meant for process-lifetime data.
            const buf = try Io.Dir.cwd().readFileAlloc(io, args[i], arena, .limited(64 * 1024 * 1024));
            var it = std.mem.splitScalar(u8, buf, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len != 0) try paths.append(gpa, t);
            }
        } else {
            try paths.append(gpa, args[i]);
        }
    }
    if (paths.items.len == 0) {
        std.debug.print("ajt tree-hash: no directories given\n", .{});
        return error.MissingArgument;
    }

    for (paths.items) |p| {
        // A `.tar` argument is hashed from the STREAM (Tar.tree_hash), which is
        // how a downloaded archive gets verified before anything is written to
        // disk. A directory uses the filesystem walker (GitTools.tree_hash).
        // The two differ on empty-directory handling, so the distinction is
        // not cosmetic.
        if (std.mem.endsWith(u8, p, ".tar")) {
            const bytes = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 30)) catch |err| {
                std.debug.print("ajt tree-hash: {s}: {s}\n", .{ p, @errorName(err) });
                try out.print("ERROR  {s}\n", .{p});
                continue;
            };
            defer gpa.free(bytes);
            const th = try ajt.julia.treehash.hashTar(gpa, bytes, false);
            try out.print("{s}  {s}\n", .{ ajt.julia.treehash.toHex(th), p });
            continue;
        }
        const h = ajt.julia.treehash.hashPath(gpa, io, p) catch |err| {
            std.debug.print("ajt tree-hash: {s}: {s}\n", .{ p, @errorName(err) });
            try out.print("ERROR  {s}\n", .{p});
            continue;
        };
        try out.print("{s}  {s}\n", .{ ajt.julia.treehash.toHex(h), p });
    }
}

fn cmdProjectHash(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("ajt project-hash: no Project.toml given\n", .{});
        return error.MissingArgument;
    }
    for (args) |path| {
        const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(src);
        var diag: ajt.toml.Diagnostic = .{};
        var doc = ajt.toml.parse(gpa, src, &diag) catch |err| {
            std.debug.print("{s}: line {d}: {s}\n", .{ path, diag.line, diag.message });
            return err;
        };
        defer doc.deinit();
        const h = try ajt.julia.project_hash.compute(gpa, doc.root);
        try out.print("{s}  {s}\n", .{ h, path });
    }
}

const aix = ajt.registry.aix;

/// Milliseconds on the monotonic clock. Zig 0.16 moved wall/monotonic time
/// behind `Io`, so a timing helper needs the same `io` everything else takes.
fn msSince(io: Io, t0: Io.Timestamp) f64 {
    const d = t0.durationTo(Io.Clock.awake.now(io));
    return @as(f64, @floatFromInt(d.nanoseconds)) / 1e6;
}

/// Where a registry read comes from. `auto` is the point of the whole `.aix`
/// exercise: use the index when one matches the installed registry, otherwise
/// fall back to re-parsing the tarball, with no user action required either
/// way. The explicit values exist so the differential gate can pin a side.
const Source = enum { auto, aix, archive };

/// A registry opened through either backend. The two expose the same lookups
/// and the same `PackageInfo`, so everything downstream is backend-agnostic.
const Backend = union(enum) {
    archive: ajt.registry.Registry,
    aix: aix.Mapped,

    fn deinit(self: *Backend, io: Io) void {
        switch (self.*) {
            .archive => |*r| r.deinit(),
            .aix => |*m| m.deinit(io),
        }
    }

    /// Which shape answered. A directory-backed registry is still an
    /// `index.Registry`, so reporting it as "archive" would leave `ajt
    /// registry status` unable to say which of the two it read.
    fn label(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| switch (r.files) {
                .archive => "archive",
                .dir => "directory",
            },
            .aix => "aix",
        };
    }

    fn name(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| r.name,
            .aix => |m| m.index.name(),
        };
    }

    fn uuid(self: Backend) []const u8 {
        return switch (self) {
            .archive => |r| r.uuid,
            .aix => |m| m.index.uuid(),
        };
    }

    fn packageCount(self: Backend) usize {
        return switch (self) {
            .archive => |r| r.packages.len,
            .aix => |m| m.index.packageCount(),
        };
    }

    /// `find_urls`' registry half (`Operations.jl:1099-1104`): the `repo` field
    /// for a UUID, or null when the registry does not carry it at all. An
    /// EMPTY string is a third answer — registered, but with no `repo` recorded
    /// — and Julia skips it (`repo === nothing && continue`), so the caller
    /// must not conflate it with null.
    ///
    /// The `.aix` backend answers straight out of the mapped index; the archive
    /// backend has to parse the package's whole registry entry to reach
    /// `Package.toml`, which is why `--source auto` prefers the index for a
    /// whole-manifest install.
    fn repoForUuid(
        self: *Backend,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        uuid_text: []const u8,
    ) !?[]const u8 {
        switch (self.*) {
            .aix => |m| {
                const ref = m.index.findByUuid(uuid_text) orelse return null;
                return try arena.dupe(u8, ref.repo);
            },
            .archive => |*r| {
                const ref = r.findByUuid(uuid_text) orelse return null;
                var pkg = try ajt.registry.loadPackage(gpa, r, ref);
                defer pkg.deinit();
                return try arena.dupe(u8, pkg.repo);
            },
        }
    }

    /// Name first, then uuid — the order `ajt registry show` has always used.
    fn load(self: *Backend, gpa: std.mem.Allocator, target: []const u8) !?ajt.registry.index.PackageInfo {
        switch (self.*) {
            .archive => |*r| {
                const ref = r.findByName(target) orelse r.findByUuid(target) orelse return null;
                return try ajt.registry.loadPackage(gpa, r, ref);
            },
            .aix => |*m| {
                const ref = m.index.findByName(target) orelse m.index.findByUuid(target) orelse return null;
                return try m.index.loadPackage(gpa, ref);
            },
        }
    }
};

/// `Sys.BINDIR` for the `julia` this ajt is driving: the directory holding the
/// first `julia` on `PATH`, **with symlinks resolved**.
///
/// The resolution is not cosmetic. Julia reports `Sys.BINDIR` after resolving
/// the executable, and on a Nix host that is the difference between
/// `/run/current-system/sw/bin` and `/nix/store/<hash>-julia-1.12.6/bin` — and
/// therefore between the bundled depots Julia actually lists and two paths that
/// do not exist. Verified against
/// `julia -e 'println(Sys.BINDIR); println(DEPOT_PATH)'`.
///
/// Called only after `depot.resolve` has asked for it (see `resolveDepotStack`),
/// because it is ~20 `stat`s down `$PATH` for a value the common configuration
/// never reads. `null` when there is no `julia` to find.
fn juliaBindir(arena: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) ?[]const u8 {
    const path = environ.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fs.path.join(arena, &.{ dir, "julia" }) catch return null;
        const st = Io.Dir.cwd().statFile(io, cand, .{}) catch continue;
        if (st.kind != .file) continue;
        // `realPathFileAlloc` resolves EVERY component, not just the last one:
        // a Nix profile symlinks the directory (`/run/current-system/sw/bin`),
        // not the executable.
        const real = Io.Dir.cwd().realPathFileAlloc(io, cand, arena) catch continue;
        return std.fs.path.dirname(real) orelse continue;
    }
    return null;
}

/// `Base.DEPOT_PATH` for this process, via the one port of `init_depot_path()`
/// (`src/depot.zig`). Never re-split `JULIA_DEPOT_PATH` by hand: the rule is
/// not "split on `:`" -- an EMPTY entry expands to Julia's bundled depots in
/// place, and a leading empty entry still leaves `~/.julia` in front
/// (`base/initdefs.jl:105-139`). Two hand-rolled copies of that used to live in
/// this file and neither implemented it.
fn resolveDepotStack(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    what: []const u8,
) !ajt.depot.Stack {
    // Resolve WITHOUT a bindir first. `Sys.BINDIR` is only consulted to expand
    // an empty `JULIA_DEPOT_PATH` entry, and finding it costs a walk down
    // `$PATH` -- so let `resolve` tell us it is needed rather than guessing.
    // Asking up front instead would mean re-deriving `init_depot_path`'s
    // empty-entry rule here, which is the duplication this helper removes.
    return ajt.depot.resolve(arena, .fromEnviron(environ.*, null)) catch |err| switch (err) {
        error.JuliaBindirUnknown => {
            const bindir = juliaBindir(arena, io, environ) orelse {
                std.debug.print(
                    "ajt {s}: JULIA_DEPOT_PATH leaves an entry empty, which expands to Julia's " ++
                        "bundled depots, and no 'julia' was found on PATH to locate them — " ++
                        "pass --depot\n",
                    .{what},
                );
                return error.MissingArgument;
            };
            return ajt.depot.resolve(arena, .fromEnviron(environ.*, bindir)) catch |err2|
                reportResolveError(what, err2);
        },
        else => reportResolveError(what, err),
    };
}

/// Turns a `depot.ResolveError` into a diagnostic plus a CLI-shaped error.
/// Exhaustive on purpose: every variant names something different the user can
/// fix, and a variant added to `depot.zig` later must not be able to slip
/// through as a bare error return with no message.
fn reportResolveError(what: []const u8, err: ajt.depot.ResolveError) anyerror {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HomeUnknown => std.debug.print(
            "ajt {s}: $HOME is unset, so ~/.julia cannot be resolved — pass --depot\n",
            .{what},
        ),
        error.TildeUserUnsupported => std.debug.print(
            "ajt {s}: JULIA_DEPOT_PATH uses ~user, which Julia itself refuses — pass --depot\n",
            .{what},
        ),
        // Only reachable on the retry, where a bindir WAS supplied.
        error.JuliaBindirUnknown => std.debug.print(
            "ajt {s}: cannot locate Julia's bundled depots — pass --depot\n",
            .{what},
        ),
    }
    return error.MissingArgument;
}

/// A stacked JULIA_DEPOT_PATH writes to its FIRST entry, which is also where
/// registries live; that is `Pkg.depots1()`, i.e. `Stack.writeDepot`.
fn resolveDepot(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    explicit: ?[]const u8,
) ![]const u8 {
    if (explicit) |d| return d;
    const stack = try resolveDepotStack(arena, io, environ, "registry");
    // An empty stack is reachable (`JULIA_DEPOT_PATH=""` means "no depot at
    // all", initdefs.jl:110-111) and Pkg raises "no depots provided" there.
    const d = stack.writeDepot() orelse {
        std.debug.print("ajt registry: cannot locate a depot (set --depot)\n", .{});
        return error.MissingArgument;
    };
    return d.root;
}

fn openBackend(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    depot: []const u8,
    reg_name: []const u8,
    source: Source,
) !Backend {
    if (source != .archive) {
        if (try aix.openForRegistry(arena, io, depot, reg_name)) |mapped| return .{ .aix = mapped };
        if (source == .aix) {
            std.debug.print("ajt registry: no .aix index for {s} — run 'ajt registry index'\n", .{reg_name});
            return error.FileNotFound;
        }
    }
    var archive = ajt.registry.tarball.loadFromDepot(gpa, io, depot, reg_name) catch |err| switch (err) {
        // No `<Name>.tar.gz` — but `registries/<Name>/` may still be a
        // registry: a git clone, or a `JULIA_PKG_UNPACK_REGISTRY=true`
        // install. `registry/source.zig` documents the full probe order.
        error.FileNotFound => return openDirBackend(gpa, arena, io, depot, reg_name, err),
        else => {
            std.debug.print("ajt registry: cannot load {s} from {s}: {s}\n", .{ reg_name, depot, @errorName(err) });
            return err;
        },
    };
    // `registry.open` takes ownership only on SUCCESS; on a malformed
    // Registry.toml the ~84 MB arena is still ours to free.
    errdefer archive.deinit();
    return .{ .archive = try ajt.registry.open(archive) };
}

fn openDirBackend(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    depot: []const u8,
    reg_name: []const u8,
    fallback: anyerror,
) !Backend {
    const path = try std.fs.path.join(arena, &.{ depot, "registries", reg_name });
    return .{ .archive = ajt.registry.openDir(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            std.debug.print(
                "ajt registry: no {s}.tar.gz and no {s}/ in {s}/registries\n",
                .{ reg_name, reg_name, depot },
            );
            return fallback;
        },
        else => {
            std.debug.print("ajt registry: cannot load {s}/ from {s}: {s}\n", .{ reg_name, depot, @errorName(err) });
            return err;
        },
    } };
}

/// `ajt registry status|show <pkg>|index`.
fn cmdRegistry(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depot: ?[]const u8 = null;
    var reg_name: []const u8 = "General";
    var reg_name_given = false;
    var source: Source = .auto;
    var rebuild = false;
    var detail = false;
    var sub: ?[]const u8 = null;
    var reg_uuid: ?[]const u8 = null;
    var reg_url: ?[]const u8 = null;
    var server: ?[]const u8 = null;
    var server_given = false;
    var unpack = false;
    var dry_run = false;
    // Multiple targets per invocation: loading the General registry costs
    // ~1.6s, so a per-package process would make any broad gate impractical.
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            depot = args[i];
        } else if (std.mem.eql(u8, args[i], "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            reg_name = args[i];
            reg_name_given = true;
        } else if (std.mem.eql(u8, args[i], "--source")) {
            i += 1;
            if (i >= args.len) return missingValue("--source");
            source = std.meta.stringToEnum(Source, args[i]) orelse {
                std.debug.print("ajt registry: unknown --source '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, args[i], "--uuid")) {
            i += 1;
            if (i >= args.len) return missingValue("--uuid");
            reg_uuid = args[i];
        } else if (std.mem.eql(u8, args[i], "--url")) {
            i += 1;
            if (i >= args.len) return missingValue("--url");
            reg_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--server")) {
            i += 1;
            if (i >= args.len) return missingValue("--server");
            // An empty value is meaningful: it is how Julia disables the
            // Pkg-server protocol entirely.
            server = try ajt.net.pkgServer(arena, args[i]);
            server_given = true;
        } else if (std.mem.eql(u8, args[i], "--unpack")) {
            unpack = true;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--rebuild")) {
            rebuild = true;
        } else if (std.mem.eql(u8, args[i], "--detail")) {
            detail = true;
        } else if (sub == null) {
            sub = args[i];
        } else {
            try targets.append(gpa, args[i]);
        }
    }

    const resolved_depot = try resolveDepot(arena, io, environ, depot);
    const which = sub orelse "status";

    if (std.mem.eql(u8, which, "index"))
        return cmdRegistryIndex(gpa, arena, io, out, resolved_depot, reg_name, rebuild);

    const is_add = std.mem.eql(u8, which, "add");
    if (is_add or std.mem.eql(u8, which, "update")) {
        return cmdRegistryFetch(gpa, arena, io, out, environ, .{
            .mode = if (is_add) .add else .update,
            .depot = resolved_depot,
            // `--uuid` with no name at all means "whatever this registry calls
            // itself": the ops layer reads the name out of the downloaded
            // Registry.toml, exactly as Pkg does (`Registry.jl:207-210`).
            // Defaulting to "General" there would file someone else's registry
            // under General.tar.gz.
            // Same reasoning for `--url`: a registry given only by url has no
            // name until it is cloned and its own `Registry.toml` is read
            // (`Registry.jl:280-282`), so defaulting to "General" here would
            // install someone else's registry under that name.
            .default_name = if ((reg_uuid != null or reg_url != null) and !reg_name_given) null else reg_name,
            .names = targets.items,
            .uuid = reg_uuid,
            .url = reg_url,
            .server = server,
            .server_given = server_given,
            .unpack = unpack,
            .dry_run = dry_run,
        });
    }

    const t0 = Io.Clock.awake.now(io);
    var backend = try openBackend(gpa, arena, io, resolved_depot, reg_name, source);
    defer backend.deinit(io);
    const load_ms = msSince(io, t0);

    if (std.mem.eql(u8, which, "status")) {
        try out.print("registry  {s}\n", .{backend.name()});
        try out.print("uuid      {s}\n", .{backend.uuid()});
        try out.print("depot     {s}\n", .{resolved_depot});
        try out.print("packages  {d}\n", .{backend.packageCount()});
        // A directory-backed registry is read lazily and has counted nothing.
        if (backend == .archive) {
            if (backend.archive.fileCount()) |files| try out.print("files     {d}\n", .{files});
        }
        try out.print("source    {s}\n", .{backend.label()});
        try out.print("load      {d:.1} ms\n", .{load_ms});
        return;
    }

    if (std.mem.eql(u8, which, "show")) {
        if (targets.items.len == 0) {
            std.debug.print("ajt registry show: no package given\n", .{});
            return error.MissingArgument;
        }
        for (targets.items) |name| {
            var pkg = (try backend.load(gpa, name)) orelse {
                try out.print("== {s}\nMISSING {s}\n", .{ name, name });
                continue;
            };
            defer pkg.deinit();

            // The default shape is what registry_deps.jl prints, so the two
            // are directly diffable. `--detail` adds the fields that shape
            // hides — package uuid, repo, and each dependency's uuid — which
            // is what lets the .aix gate compare them across backends rather
            // than trusting them.
            if (detail) {
                try out.print("== {s} {s} {s}\n", .{ pkg.name, pkg.uuid, pkg.repo });
            } else {
                try out.print("== {s}\n", .{pkg.name});
            }
            for (pkg.versions, 0..) |vi, vidx| {
                try out.print("{f}", .{vi.version});
                if (vi.yanked) try out.writeAll("  (yanked)");
                try out.print("  {s}\n", .{vi.tree_hash});
                for (pkg.deps[vidx]) |d| {
                    const spec = try d.compat.toString(gpa);
                    defer gpa.free(spec);
                    if (detail) {
                        try out.print("    {s} {s} {s}\n", .{ d.name, d.uuid, spec });
                    } else {
                        try out.print("    {s} {s}{s}" ++ "\n", .{ d.name, spec, if (d.weak) "  (weak)" else "" });
                    }
                }
            }
        }
        return;
    }

    std.debug.print("ajt registry: unknown subcommand '{s}'\n", .{which});
    return error.UnknownCommand;
}

/// `ajt registry index [--rebuild]` — bake the tarball into an `.aix`.
///
/// The output path embeds the registry's git tree hash, so this is a no-op
/// once the current registry has been indexed; `--rebuild` forces the work
/// anyway, which is what the differential gate needs after a format change.
fn cmdRegistryIndex(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    depot: []const u8,
    reg_name: []const u8,
    rebuild: bool,
) !void {
    const stamp = aix.readStamp(arena, io, depot, reg_name) catch |err| {
        std.debug.print("ajt registry index: no {s}/registries/{s}.toml ({s})\n", .{ depot, reg_name, @errorName(err) });
        return err;
    };

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try aix.cachePath(&path_buf, depot, stamp);

    if (!rebuild) {
        if (aix.openFile(io, path)) |mapped| {
            var m = mapped;
            defer m.deinit(io);
            try out.print("up to date  {s}\n", .{path});
            try out.print("packages    {d}\n", .{m.index.packageCount()});
            return;
        } else |_| {}
    }

    const t0 = Io.Clock.awake.now(io);
    var reg = blk: {
        var archive = try ajt.registry.tarball.loadFromDepot(gpa, io, depot, reg_name);
        errdefer archive.deinit(); // open() only takes ownership on success
        break :blk try ajt.registry.open(archive);
    };
    defer reg.deinit();
    const parse_ms = msSince(io, t0);

    const t1 = Io.Clock.awake.now(io);
    const bytes = try aix.build(gpa, &reg, stamp.tree_sha1);
    defer gpa.free(bytes);
    const build_ms = msSince(io, t1);

    try aix.writeIndex(gpa, io, depot, stamp, bytes);

    // Reopen through the real path, so what is reported is what a later run
    // will actually get rather than what was just held in memory.
    const t2 = Io.Clock.awake.now(io);
    var mapped = try aix.openFile(io, path);
    defer mapped.deinit(io);
    const map_ms = msSince(io, t2);

    try out.print("wrote       {s}\n", .{path});
    try out.print("bytes       {d}\n", .{bytes.len});
    try out.print("packages    {d}\n", .{mapped.index.packageCount()});
    try out.print("versions    {d}\n", .{mapped.index.vers.len});
    try out.print("rows        {d}\n", .{mapped.index.rows.len});
    try out.print("parse       {d:.1} ms\n", .{parse_ms});
    try out.print("encode      {d:.1} ms\n", .{build_ms});
    try out.print("mmap        {d:.1} ms\n", .{map_ms});
}

/// `ajt verify [--frozen] [--check-hashes] [env]`
///
/// Replaces the `julia -e 'using Pkg; Pkg.instantiate()'` that container
/// entrypoints run on every start purely to conclude "nothing to do". Exit 0
/// means the environment is instantiated and nothing was written; any non-zero
/// exit names the specific cause on stdout, so the caller can decide between a
/// resolve and a download.
///
/// The exit status is set with `std.process.exit` rather than by returning an
/// error: a returned error would print `error: EnvironmentNotInstantiated` and
/// a stack trace over the message that actually explains the failure.
fn cmdVerify(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var opts: ajt.ops.verify.Options = .{ .env_path = ".", .stack = .{ .entries = &.{} } };
    var quiet = false;
    var env_given = false;
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--frozen")) {
            // Accepted and documented, deliberately not stored: see the module
            // header in src/ops/verify.zig -- there is no non-frozen path.
        } else if (std.mem.eql(u8, a, "--check-hashes")) {
            opts.check_hashes = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt verify: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (!env_given) {
            opts.env_path = a;
            env_given = true;
        } else {
            std.debug.print("ajt verify: one environment at a time\n", .{});
            return error.UnknownOption;
        }
    }

    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);

    if (depots.items.len != 0) {
        opts.stack = .{ .entries = depots.items };
    } else {
        // The WHOLE stack, not just depots1(): the engine image runs
        // `JULIA_DEPOT_PATH=/julia-depot:/julia-depot-image` and a package
        // baked into the image depot is installed as far as the loader is
        // concerned. `julia_bindir` is only consulted for an empty entry.
        const bindir: ?[]const u8 = if (opts.julia_prefix) |p|
            try fspath.join(arena, &.{ p, "bin" })
        else
            null;
        opts.stack = ajt.depot.resolve(arena, .fromEnviron(environ.*, bindir)) catch |err| {
            std.debug.print("ajt verify: cannot resolve JULIA_DEPOT_PATH: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    const t0 = Io.Clock.awake.now(io);
    const rep = ajt.ops.verify.run(arena, gpa, io, opts) catch |err| switch (err) {
        error.NoDepot => {
            if (!quiet) try out.writeAll("not verifiable: JULIA_DEPOT_PATH is empty — there is nowhere for a package to be installed\n");
            try out.flush();
            std.process.exit(2);
        },
        else => |e| return e,
    };
    const elapsed = msSince(io, t0);

    if (!quiet) {
        if (rep.ok()) {
            try out.print("ok  {s}\n", .{rep.manifest_file});
            // `.unavailable` cannot reach this branch: it raises a problem of
            // its own, so a run that could not check the stdlib entries is
            // never `ok`.
            try out.print(
                "    {d} entries: {d} installed, {d} developed, {d} stdlib, {d} pruned",
                .{ rep.entries, rep.installed, rep.developed, rep.stdlib, rep.pruned },
            );
            if (rep.rehashed != 0) try out.print(", {d} re-hashed", .{rep.rehashed});
            try out.print("  [{d:.1} ms]\n", .{elapsed});
        } else {
            try out.print("NOT INSTANTIATED  {s}\n", .{rep.manifest_file});
            // Cap the list: a cold depot means one line per package, and the
            // point of the output is the CAUSE, which the first few already
            // give.
            const cap = 20;
            for (rep.problems, 0..) |p, n| {
                if (n == cap) {
                    try out.print("    ... and {d} more\n", .{rep.problems.len - cap});
                    break;
                }
                try out.print("    {f}\n", .{p});
            }
            try out.print("    {d} problem(s)  [{d:.1} ms]\n", .{ rep.problems.len, elapsed });
        }
    }

    try out.flush();
    // Three answers, three codes. A single 1 for every kind of "no" forced
    // callers to scrape the report to find out whether the environment merely
    // needed installing -- which the Julia wrapper actually had to do.
    //   0  instantiated, nothing to do
    //   1  not instantiated: run `instantiate`
    //   2  the manifest no longer matches the project: run `resolve`
    //   3  the environment or the machine is broken; no Pkg verb fixes it
    if (rep.remedy()) |r| std.process.exit(switch (r) {
        .install => 1,
        .resolve => 2,
        .repair => 3,
    });
}

/// `dirname(Sys.BINDIR)` for the `julia` on `$PATH`, or null.
///
/// Only the stdlib cross-check needs this, and only to tell a stdlib entry from
/// a manifest entry that lost its `git-tree-sha1`; when it cannot be found the
/// report says the check did not run rather than guessing.
///
/// A candidate is accepted only if `share/julia/stdlib` is actually under it,
/// which is what makes the one symlink hop safe: on NixOS `julia` is
/// `/run/current-system/sw/bin/julia`, whose profile does carry the stdlib
/// tree, while a bare wrapper script elsewhere would not and falls through to
/// its link target.
fn findJuliaPrefix(arena: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) ?[]const u8 {
    const path = environ.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const exe = fspath.join(arena, &.{ dir, "julia" }) catch return null;
        Io.Dir.cwd().access(io, exe, .{}) catch continue;

        if (prefixOf(arena, io, exe)) |p| return p;

        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(io, exe, &buf) catch continue;
        // Into the ARENA, both branches. `prefixOf` returns a subslice of what
        // it is given, so handing it `buf` would hand back a pointer into this
        // stack frame -- and the absolute-link form is the common one
        // (`/usr/local/bin/julia -> /usr/local/julia/bin/julia` in the official
        // images, and every juliaup and Nix profile shim).
        const target = fspath.resolve(arena, &.{ dir, buf[0..n] }) catch continue;
        if (prefixOf(arena, io, target)) |p| return p;
    }
    return null;
}

fn prefixOf(arena: std.mem.Allocator, io: Io, exe: []const u8) ?[]const u8 {
    const bin = fspath.dirname(exe) orelse return null;
    const prefix = fspath.dirname(bin) orelse return null;
    const probe = fspath.join(arena, &.{ prefix, "share", "julia", "stdlib" }) catch return null;
    const st = Io.Dir.cwd().statFile(io, probe, .{}) catch return null;
    if (st.kind != .directory) return null;
    return prefix;
}

const registry_ops = ajt.ops.registry_ops;

const RegistryFetchArgs = struct {
    mode: registry_ops.Mode,
    depot: []const u8,
    /// `--registry`, used when no positional names were given. Null means the
    /// name is not known up front and comes from the downloaded registry.
    default_name: ?[]const u8,
    names: []const []const u8,
    uuid: ?[]const u8,
    /// `--url`: `RegistrySpec.url`, the git repository to clone when the Pkg
    /// server cannot serve this registry.
    url: ?[]const u8,
    server: ?[]const u8,
    server_given: bool,
    unpack: bool,
    dry_run: bool,
};

/// `ajt registry add|update [NAME...]` — the only command that both talks to
/// the network and writes into a depot.
///
/// One `Client` for the whole invocation, because it pools connections and
/// because the auth-token refresh it may perform should happen once, not once
/// per registry.
fn cmdRegistryFetch(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: RegistryFetchArgs,
) !void {
    var base: ajt.net.Config = .{ .depot = args.depot };
    if (args.server_given) base.server = args.server;
    // `fromEnv` only fills what is still unset, so the flag wins. `--server ""`
    // legitimately resolves to null, which fromEnv would re-fill from the
    // environment; hence the explicit re-apply.
    var config = try netConfig(arena, environ, base);
    if (args.server_given) config.server = args.server;

    // The Julia-System/Julia-Version headers identify the client to the Pkg
    // server. Ajt is not a Julia install and has no VERSION of its own, so
    // whatever the caller exported is what gets sent; `ajt fetch` is the
    // command for pinning those exactly.
    if (config.julia_version.len == 0) {
        if (environ.get("JULIA_VERSION")) |v| config.julia_version = v;
    }

    var client: ajt.net.Client = .init(gpa, io, config);
    defer client.deinit();

    // Git is wired unconditionally rather than probed: it is needed only for a
    // cloned registry and for the fallback when the server cannot serve, and
    // on a machine with no `git` the backend's own `BackendUnavailable` names
    // that precisely — where a probe here would cost a process on every
    // `registry add` to produce a vaguer message.
    var git_environ = try ajt.git.cli.defaultEnviron(gpa, environ);
    defer git_environ.deinit();
    var git_state: GitBackend = .{};
    defer git_state.deinit();
    const git_backend = try git_state.open(gpa, arena, io, environ, &git_environ);

    // `--unpack` forces the env var Pkg reads; without it the environment
    // decides, exactly as `registry_read_from_tarball()` does.
    const unpack_env: ?[]const u8 = if (args.unpack) "true" else environ.get("JULIA_PKG_UNPACK_REGISTRY");

    // With no positional names there is still ONE registry to act on -- the
    // one `--registry`/`--uuid` names -- and its name may legitimately be
    // unknown until the archive is parsed, hence the optional.
    const count = if (args.names.len != 0) args.names.len else 1;

    var n: usize = 0;
    while (n < count) : (n += 1) {
        const name: ?[]const u8 = if (args.names.len != 0) args.names[n] else args.default_name;
        if (n != 0) try out.writeAll("\n");
        const report = registry_ops.run(gpa, arena, io, &client, .{
            .mode = args.mode,
            .depot = args.depot,
            .name = name,
            .uuid = args.uuid,
            .url = args.url,
            .git = git_backend,
            .server = config.server,
            .unpack_env = unpack_env,
            .dry_run = args.dry_run,
        }) catch |err| {
            std.debug.print("ajt registry {s}: {s}: {s}\n", .{
                @tagName(args.mode), name orelse args.uuid orelse "?", @errorName(err),
            });
            return err;
        };

        // A dry run prints the whole server index first: `pin <uuid> <hash>`
        // is the shape the differential gate compares against
        // `Pkg.Registry.pkg_server_registry_info()`.
        if (args.dry_run) {
            for (report.pins) |p| try out.print("pin       {s} {s}\n", .{ p.uuid, p.tree_sha1 });
        }
        // A uuid-only dry run cannot know the name: it lives in the
        // Registry.toml inside an archive the run deliberately did not fetch.
        try out.print("registry  {s}\n", .{
            if (report.name.len != 0) report.name else "(unknown until downloaded)",
        });
        try out.print("uuid      {s}\n", .{report.uuid});
        try out.print("tree      {s}\n", .{report.tree_sha1});
        try out.print("depot     {s}\n", .{args.depot});
        // `tarball`, `directory` or `git_clone` — the three shapes
        // `reachable_registries` accepts, named rather than inferred, because
        // "not a tarball" stopped being one thing.
        try out.print("layout    {s}\n", .{@tagName(report.layout)});
        if (report.compressed_bytes != 0) try out.print("bytes     {d}\n", .{report.compressed_bytes});
        try out.print("action    {s}\n", .{@tagName(report.action)});
    }
}

/// `ajt select-artifact --host <k=v,...> <Artifacts.toml>...`
///
/// Prints `<artifact name>  <chosen git-tree-sha1>` per entry. The host tag set
/// is passed in rather than detected, so this exercises matching + selection in
/// isolation; host detection (BUILD_TRIPLET + the libstdcxx probe) is a
/// separate concern with its own failure modes.
fn cmdSelectArtifact(
    gpa: std.mem.Allocator,
    /// Process-lifetime; the per-document arenas below are separate and are
    /// dropped after each file.
    proc_arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var host_spec: []const u8 = "";
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host")) {
            i += 1;
            if (i >= args.len) return missingValue("--host");
            host_spec = args[i];
        } else try files.append(gpa, args[i]);
    }
    if (files.items.len == 0) {
        std.debug.print("ajt select-artifact: no Artifacts.toml given\n", .{});
        return error.MissingArgument;
    }

    const host = try parseHostPlatform(proc_arena, host_spec);

    for (files.items) |path| {
        const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(src);
        var doc = ajt.toml.parse(gpa, src, null) catch continue;
        defer doc.deinit();
        const arena = doc.allocator();

        for (doc.root.entries.items) |entry| {
            const items = switch (entry.value) {
                .array => |a| a,
                // A non-array entry is a platform-independent artifact.
                .table => {
                    try out.print("{s}  (unplatformed)\n", .{entry.key});
                    continue;
                },
                else => continue,
            };

            var cands: std.ArrayList(ajt.julia.platform.Platform) = .empty;
            defer cands.deinit(gpa);
            var hashes: std.ArrayList([]const u8) = .empty;
            defer hashes.deinit(gpa);

            for (items) |it| {
                const t = switch (it) {
                    .table => |t| t,
                    else => continue,
                };
                // `unpack_platform` composed with the `Platform` constructor --
                // the ONE implementation, in install/artifacts.zig. This used
                // to be open-coded here without the constructor's
                // normalisation, so this command silently compared
                // unnormalised platforms against a Julia oracle that
                // normalises. A malformed entry is skipped, as before.
                const p = ajt.install.artifacts.unpackPlatform(arena, t) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                const th = switch (t.get("git-tree-sha1") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                try cands.append(gpa, p);
                try hashes.append(gpa, th);
            }

            if (cands.items.len == 0) continue;
            const pick = try ajt.julia.platform.selectPlatform(gpa, cands.items, host);
            if (pick) |p| {
                try out.print("{s}  {s}\n", .{ entry.key, hashes.items[p] });
            } else {
                try out.print("{s}  NONE\n", .{entry.key});
            }
        }
    }
}

/// `ajt host-platform` — prints the detected host tags as sorted `k=v,k=v`,
/// the same shape `--host` accepts and the same shape the gate compares.
fn cmdHostPlatform(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    var prefix: []const u8 = "";
    var jversion: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            prefix = args[i];
        } else if (std.mem.eql(u8, args[i], "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            jversion = args[i];
        }
    }
    if (prefix.len == 0 or jversion.len == 0) {
        std.debug.print("ajt host-platform: --julia-prefix and --julia-version are required\n", .{});
        return error.MissingArgument;
    }

    // Arena: detectHost's allocations all share the Platform's lifetime.
    const host = ajt.julia.platform.detectHost(arena, io, .{
        .julia_prefix = prefix,
        .julia_version = jversion,
    }) catch |err| {
        std.debug.print("ajt host-platform: {s}\n", .{@errorName(err)});
        return err;
    };

    const sorted = try gpa.dupe(ajt.julia.platform.Tag, host.tags);
    defer gpa.free(sorted);
    std.mem.sort(ajt.julia.platform.Tag, sorted, {}, struct {
        fn lt(_: void, a: ajt.julia.platform.Tag, b: ajt.julia.platform.Tag) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    for (sorted, 0..) |t, n| {
        if (n != 0) try out.writeAll(",");
        try out.print("{s}={s}", .{ t.key, t.value });
    }
    try out.writeAll("\n");
}

/// `ajt fetch [options] <url>` — the debug window onto `src/net/`.
///
/// Exists for the differential gate: `--print-headers` renders exactly what
/// `Pkg.PlatformEngines.get_metadata_headers(url)` returns (an offline check),
/// and a plain fetch writes the body to stdout so it can be diffed against
/// what Pkg would have downloaded. A non-2xx status is an error exit, matching
/// `Downloads.download`, which throws rather than handing back a status.
fn cmdFetch(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var url: ?[]const u8 = null;
    var base: ajt.net.Config = .{};
    var julia_prefix: ?[]const u8 = null;
    var attempts: u32 = 1;
    var authenticate = true;
    var print_headers = false;
    var show_status = false;
    var server_given = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= args.len) return missingValue("--server");
            // An empty value is meaningful: it is how Julia turns the
            // Pkg-server protocol off.
            base.server = try ajt.net.pkgServer(arena, args[i]);
            server_given = true;
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            base.depot = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            base.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-system")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-system");
            base.julia_system = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--retry")) {
            i += 1;
            if (i >= args.len) return missingValue("--retry");
            attempts = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("ajt fetch: --retry wants an integer, got '{s}'\n", .{args[i]});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, a, "--no-auth")) {
            authenticate = false;
        } else if (std.mem.eql(u8, a, "--print-headers")) {
            print_headers = true;
        } else if (std.mem.eql(u8, a, "--status")) {
            show_status = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt fetch: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (url == null) {
            url = a;
        } else {
            std.debug.print("ajt fetch: one URL at a time\n", .{});
            return error.UnknownOption;
        }
    }

    const target = url orelse {
        std.debug.print("ajt fetch: no URL given\n", .{});
        return error.MissingArgument;
    };

    // `Config.fromEnv` only fills what is still unset, so explicit flags win.
    // `--server ""` legitimately resolves to null, which fromEnv would then
    // re-fill from the environment; hence the sentinel.
    var config = try netConfig(arena, environ, base);
    if (server_given) config.server = base.server;

    if (julia_prefix) |prefix| {
        // `HostPlatform()` carries a `julia_version` tag, which `triplet`
        // renders as a `-julia_version+X` suffix. Without a version the
        // suffix comes out empty and the Julia-System header silently stops
        // matching Julia's -- fail loudly instead.
        if (config.julia_version.len == 0) {
            std.debug.print("ajt fetch: --julia-prefix also needs --julia-version\n", .{});
            return error.MissingArgument;
        }
        const host = try ajt.julia.platform.detectHost(arena, io, .{
            .julia_prefix = prefix,
            .julia_version = config.julia_version,
        });
        config.julia_system = try ajt.julia.platform.triplet(arena, host);
    }

    if (print_headers) {
        for (try ajt.net.http.metadataHeaders(arena, config, target)) |h| {
            try out.print("{s}: {s}\n", .{ h.name, h.value });
        }
        return;
    }

    var client: ajt.net.Client = .init(gpa, io, config);
    defer client.deinit();

    const res = client.get(arena, target, .{
        .retry = .{ .attempts = attempts, .delay = .{ .nanoseconds = std.time.ns_per_s } },
        .authenticate = authenticate,
    }) catch |err| {
        std.debug.print("ajt fetch: {s}: {s}\n", .{ target, @errorName(err) });
        return err;
    };

    if (show_status) {
        std.debug.print("{d} {d} {s}\n", .{ @intFromEnum(res.status), res.body.len, res.url });
    }
    try out.writeAll(res.body);
    if (!res.ok()) {
        std.debug.print("ajt fetch: {s}: HTTP {d}\n", .{ target, @intFromEnum(res.status) });
        return error.HttpRequestFailed;
    }
}

/// Alias for the package-install verbs. Named explicitly because
/// `install-artifacts` binds its own local `ops` to a different module.
const pkg_ops = ajt.ops.install_packages;

/// Which git backend a command runs, and whatever state that one needs kept
/// alive: for `cli` a child environment, for `lib` a `git_libgit2_init`
/// refcount and the registered TLS stream. Both outlive the call, so this is a
/// value on the caller's stack rather than a function returning a `Backend`
/// that points at its own locals.
///
/// It is the git backend the install falls back to when no archive can serve a
/// package, and the only way a `repo-url` manifest entry is ever installed
/// (`install_git`, `Operations.jl:830-880`; `API.jl:1358-1390`) — and the same
/// selection for `resolve`, `add`/`dev` and `registry add`/`update`, which is
/// the point: one rule, read once, in one place.
///
/// **`cli` is the default and stays it.** It is Pkg's own
/// `JULIA_PKG_USE_CLI_GIT` path, the only backend with the six operations
/// `registry update` needs over a clone, and the only one that speaks ssh.
/// `AJT_GIT_BACKEND=lib` opts in; on a binary built without `-Dgit` that is
/// `error.BackendUnavailable` with a sentence saying how to get one, and never
/// a quiet fall back to `cli` — somebody who names a backend named it for a
/// reason.
const GitBackend = struct {
    which: ajt.git.Which = .cli,
    cli: ajt.git.cli.Cli = undefined,
    lib: ajt.git.lib.Lib = undefined,
    /// The child environment, when `openOwned` built it here.
    environ: std.process.Environ.Map = undefined,
    ready: bool = false,
    lib_ready: bool = false,

    /// The selected backend, with `cli` running its children under
    /// `child_environ` — which every caller builds its own way, because the
    /// narrowing a `git` child needs is not the same question as which backend
    /// to use.
    fn open(
        self: *GitBackend,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: Io,
        environ: *std.process.Environ.Map,
        child_environ: *const std.process.Environ.Map,
    ) ajt.git.lib.InitError!ajt.git.core.Backend {
        self.which = ajt.git.selectBackend(
            environ.get("AJT_GIT_BACKEND"),
            environ.get("JULIA_PKG_USE_CLI_GIT"),
            .cli,
        );
        switch (self.which) {
            .cli => {
                self.cli = .{ .environ = child_environ };
                return self.cli.backend();
            },
            .lib => {
                // Idempotent, because `cmdEdit` opens twice — once
                // unconditionally, once with a narrowed child environment for
                // the clone. `Lib.init` refcounts inside libgit2 and registers
                // the TLS stream, so a second one would want a second `deinit`
                // that nothing here would make.
                if (self.lib_ready) return self.lib.backend();
                // libgit2 takes a credential from the URL rather than from a
                // credential helper (`git/lib.zig`'s header), so the tokens and
                // `~/.netrc` are handed over here. The `cli` arm reaches the
                // same material through the child environment and git's own
                // configuration, which is why only this one needs them.
                self.lib = ajt.git.Lib.init(gpa, io, .{
                    .gh_token = environ.get("GH_TOKEN"),
                    .github_token = environ.get("GITHUB_TOKEN"),
                    .netrc = readNetrc(arena, io, environ),
                }) catch |err| {
                    if (err == error.BackendUnavailable) std.debug.print(
                        "ajt: AJT_GIT_BACKEND=lib, but this binary has no libgit2 in it;" ++
                            " rebuild with `zig build -Dgit`, or set AJT_GIT_BACKEND=cli\n",
                        .{},
                    ) else std.debug.print(
                        "ajt: cannot start libgit2: {s}\n",
                        .{@errorName(err)},
                    );
                    return err;
                };
                self.lib_ready = true;
                return self.lib.backend();
            },
        }
    }

    /// `open` with the child environment built here, and a backend that cannot
    /// run answered with null rather than an error.
    ///
    /// Reported rather than fatal: an environment whose packages all come from
    /// archives installs perfectly without any git at all, and refusing to
    /// start would be strictly worse than Pkg, which only reaches `install_git`
    /// when it must. The `available` probe is `cli`-only because it costs a
    /// child process, and because `Lib.init` has already answered the same
    /// question for the other arm.
    fn openOwned(
        self: *GitBackend,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        io: Io,
        environ: *std.process.Environ.Map,
        verb: []const u8,
    ) !?ajt.git.core.Backend {
        self.environ = try ajt.git.cli.childEnviron(gpa, environ);
        self.ready = true;
        const backend = self.open(gpa, arena, io, environ, &self.environ) catch |err| switch (err) {
            error.BackendUnavailable => {
                std.debug.print(
                    "ajt {s}: no usable git backend; packages no archive can serve cannot be installed\n",
                    .{verb},
                );
                return null;
            },
            else => return err,
        };
        if (self.which == .cli and !ajt.git.cli.available(gpa, io, self.cli.program)) {
            std.debug.print(
                "ajt {s}: no usable `git`; packages no archive can serve cannot be installed\n",
                .{verb},
            );
            return null;
        }
        return backend;
    }

    fn deinit(self: *GitBackend) void {
        if (self.lib_ready) self.lib.deinit();
        self.lib_ready = false;
        if (self.ready) self.environ.deinit();
        self.ready = false;
    }
};

/// Answers `find_urls` out of an opened registry backend, for
/// `install_packages.jobsFromManifest`.
const RegistryRepos = struct {
    backend: ?*Backend,
    gpa: std.mem.Allocator,

    fn find(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        uuid_text: []const u8,
    ) std.mem.Allocator.Error!?[]const []const u8 {
        const self: *RegistryRepos = @ptrCast(@alignCast(ctx));
        const backend = self.backend orelse return null;
        const maybe = backend.repoForUuid(self.gpa, arena, uuid_text) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            // The package IS registered — the lookup found it and then failed
            // to parse its entry — so this must NOT collapse to null. Null
            // means `!haskey(reg, uuid)`, which also suppresses the Pkg-SERVER
            // candidate, and the server serves by UUID and tree hash without
            // ever consulting `repo`. Losing only the GitHub fallback is the
            // faithful degradation.
            return &.{};
        };
        const repo = maybe orelse return null;
        // Registered, but the registry records no `repo`:
        // `repo === nothing && continue` (`Operations.jl:1103`).
        if (repo.len == 0) return &.{};
        const urls = try arena.alloc([]const u8, 1);
        urls[0] = repo;
        return urls;
    }

    fn lookup(self: *RegistryRepos) pkg_ops.RepoLookup {
        return .{ .ctx = @ptrCast(self), .find = find };
    }
};

/// `ajt install [options] <Manifest.toml>` — `Pkg.instantiate`'s download half.
///
/// Records go to stdout, TAB-separated, one per line, in manifest order:
///
///   `install <outcome> <name> <uuid> <tree-hash> <path>`
///   `fixup   <name> <project-file|-> <changed 0|1> <removed deps|->`
///
/// Failures are additionally spelled out on stderr, one line per URL tried,
/// because "which mirror failed and how" is exactly what Pkg's single
/// `@warn "tarball content does not match git-tree-sha1"` throws away.
fn cmdInstall(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var registry_depot: ?[]const u8 = null;
    var reg_name: []const u8 = "General";
    var source: Source = .auto;
    var stdlib_dir: ?[]const u8 = null;
    var julia_bindir: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var jobs_flag: ?u32 = null;
    var server: ?[]const u8 = null;
    var server_given = false;
    var dry_run = false;
    var download = true;
    var fixups = true;
    var use_git = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--registry-depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-depot");
            registry_depot = args[i];
        } else if (std.mem.eql(u8, a, "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            reg_name = args[i];
        } else if (std.mem.eql(u8, a, "--source")) {
            i += 1;
            if (i >= args.len) return missingValue("--source");
            source = std.meta.stringToEnum(Source, args[i]) orelse {
                std.debug.print("ajt install: unknown --source '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= args.len) return missingValue("--server");
            // An empty value is meaningful: it is how Julia turns the
            // Pkg-server protocol off, leaving only the GitHub fallback.
            server = try ajt.net.pkgServer(arena, args[i]);
            server_given = true;
        } else if (std.mem.eql(u8, a, "--jobs")) {
            i += 1;
            if (i >= args.len) return missingValue("--jobs");
            jobs_flag = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("ajt install: --jobs wants an integer, got '{s}'\n", .{args[i]});
                return error.MissingArgument;
            };
            if (jobs_flag.? < 1) {
                std.debug.print("ajt install: --jobs must be at least 1\n", .{});
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, a, "--stdlib")) {
            i += 1;
            if (i >= args.len) return missingValue("--stdlib");
            stdlib_dir = args[i];
        } else if (std.mem.eql(u8, a, "--julia-bindir")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-bindir");
            julia_bindir = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return missingValue("--output");
            output = args[i];
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--no-download")) {
            download = false;
        } else if (std.mem.eql(u8, a, "--no-fixups")) {
            fixups = false;
        } else if (std.mem.eql(u8, a, "--no-git")) {
            use_git = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt install: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (manifest_path == null) {
            manifest_path = a;
        } else {
            std.debug.print("ajt install: one manifest at a time\n", .{});
            return error.UnknownOption;
        }
    }

    const mpath = manifest_path orelse {
        std.debug.print("ajt install: no Manifest.toml given\n", .{});
        return error.MissingArgument;
    };

    // Records go to a 64 KiB buffer, so ANY error after the first print would
    // otherwise discard them — the fixups pass, `--output`, or `check`. They
    // are most valuable exactly then.
    defer out.flush() catch {};

    const stack = try resolveStack(arena, io, environ, depots.items, julia_bindir);
    if (stack.entries.len == 0) {
        std.debug.print("ajt install: DEPOT_PATH is empty, nowhere to install to\n", .{});
        return error.MissingArgument;
    }

    // --- the manifest ------------------------------------------------------
    const src = try Io.Dir.cwd().readFileAlloc(io, mpath, arena, .limited(64 * 1024 * 1024));
    var diag: ajt.toml.Diagnostic = .{};
    var m = ajt.model.manifest.parse(arena, src, &diag) catch |err| {
        std.debug.print("ajt install: {s}: line {d}: {s}\n", .{ mpath, diag.line, diag.message });
        return err;
    };

    // --- the registry, for the GitHub fallback URLs ------------------------
    var backend: ?Backend = openBackend(gpa, arena, io, registry_depot orelse stack.entries[0], reg_name, source) catch |err| blk: {
        // No registry is survivable: the Pkg server serves by UUID and tree
        // hash alone. It only costs the GitHub fallback, so say so and carry on
        // rather than refusing to install anything.
        std.debug.print("ajt install: no {s} registry ({s}); GitHub fallback URLs unavailable\n", .{
            reg_name, @errorName(err),
        });
        break :blk null;
    };
    defer if (backend) |*b| b.deinit(io);

    var repos: RegistryRepos = .{ .backend = if (backend) |*b| b else null, .gpa = gpa };
    // A `repo-url` that is a local path is manifest-relative, so the job list
    // needs the manifest's directory to resolve it (`API.jl:1362-1367`).
    const jobs = try pkg_ops.jobsFromManifest(
        arena,
        &m,
        repos.lookup(),
        std.fs.path.dirname(mpath) orelse ".",
    );

    var config = try netConfig(arena, environ, .{ .server = server });
    if (server_given) config.server = server;

    // Opened only for a run that will actually download: `--dry-run` and
    // `--no-download` install nothing, and probing for `git` would print a
    // warning about a fallback neither of them can reach.
    var git_state: GitBackend = .{};
    defer git_state.deinit();
    const git_backend = if (use_git and download and !dry_run)
        try git_state.openOwned(gpa, arena, io, environ, "install")
    else
        null;

    const opts: pkg_ops.Options = .{
        .server = config.server,
        // The whole config, not just the server: the `Julia-*` protocol
        // headers and the depot the bearer token comes from ride on it.
        .net = config,
        .concurrency = jobs_flag orelse config.concurrency,
        .git = git_backend,
    };

    if (dry_run) {
        for (jobs) |job| {
            var hash_buf: [40]u8 = undefined;
            try out.print("dry-run\t{s}\t{s}", .{
                job.name,
                ajt.model.manifest.formatSha1(job.tree_hash, &hash_buf),
            });
            for (try pkg_ops.candidates(arena, job, opts.server)) |c| {
                try out.print("\t{s}", .{c.url});
            }
            try out.writeAll("\n");
        }
        return;
    }

    // --- usage bookkeeping --------------------------------------------------
    // `EnvCache` stamps `logs/manifest_usage.toml` the moment it loads an
    // environment (`Types.jl:426`), BEFORE any work, and that stamp is the only
    // thing that stops `Pkg.gc()` from deleting everything installed below.
    //
    // Skipped for `--dry-run` and `--no-download`, which is a deliberate
    // divergence: both install nothing, `--dry-run` runs against the user's
    // REAL depot by default, and `--no-download` is documented by
    // `install_packages.sh` as read-only against it. A log entry protects
    // installed content; a command that installs none has nothing to protect.
    if (download and !dry_run) {
        if (stack.writeDepot()) |d| {
            // Never `try`: bookkeeping must not fail a command whose real work
            // succeeded. `record` already swallows write failures (and says so
            // on stderr); this covers the two it cannot — a depot path that
            // cannot be absolutised, and OOM.
            _ = ajt.ops.usage.record(gpa, io, d.root, ajt.ops.usage.manifest_log, &.{mpath}, .{}) catch |err| {
                std.debug.print("ajt install: could not record manifest usage: {s}\n", .{@errorName(err)});
            };
        }
    }

    // --- download + install ------------------------------------------------
    // `--no-download` runs the fixups pass alone. It exists so a differential
    // gate can check fixups against a depot it must not write to — the user's
    // real ~/.julia — which is exactly where a full manifest's packages already
    // are.
    const results = if (download)
        try pkg_ops.install(gpa, arena, io, stack, jobs, opts)
    else
        &[_]pkg_ops.Result{};
    // One `Result` per `Job`, in order — the index is what says whether the
    // job was repo-tracked, and therefore which diagnostic is true.
    for (results, 0..) |r, ji| {
        var uuid_buf: [36]u8 = undefined;
        var hash_buf: [40]u8 = undefined;
        try out.print("install\t{t}\t{s}\t{s}\t{s}\t{s}\n", .{
            r.outcome,
            r.name,
            ajt.model.manifest.formatUuid(r.uuid, &uuid_buf),
            ajt.model.manifest.formatSha1(r.tree_hash, &hash_buf),
            r.path,
        });
        if (r.ok()) continue;
        for (r.attempts) |at| {
            if (!at.tried) continue;
            // Two fetches of one remote differ only in their refspec
            // (`refspecs_heads` then `refspecs_all`), so without it the second
            // line reads as a duplicate of the first.
            if (at.refspec) |spec| {
                if (at.err) |e| {
                    std.debug.print("ajt install: {s}: git fetch {s} {s}: {s}\n", .{
                        r.name, at.url, spec, @errorName(e),
                    });
                }
                continue;
            }
            if (at.status) |st| {
                std.debug.print("ajt install: {s}: {s}: HTTP {d}\n", .{ r.name, at.url, @intFromEnum(st) });
            } else if (at.computed) |got| {
                std.debug.print("ajt install: {s}: {s}: tree hash is {s}, manifest pins {s}\n", .{
                    r.name, at.url, got, ajt.model.manifest.formatSha1(r.tree_hash, &hash_buf),
                });
            } else if (at.err) |e| {
                std.debug.print("ajt install: {s}: {s}: {s}\n", .{ r.name, at.url, @errorName(e) });
            }
        }
        if (r.outcome != .needs_git_clone) continue;
        // A `repo-url` job is BUILT with no candidates, so "not in the
        // registry?" is never its problem — that message would send the user
        // to a registry which could not serve a git-tracked entry anyway.
        if (ji < jobs.len and jobs[ji].repo != null) {
            std.debug.print(
                "ajt install: {s}: tracked by repo-url; a git clone is the only way to install it, and there is no backend ({s})\n",
                .{ r.name, if (use_git) "no usable `git`" else "--no-git" },
            );
            continue;
        }
        if (r.attempts.len == 0) {
            std.debug.print("ajt install: {s}: no archive URL (not in {s}?)\n", .{ r.name, reg_name });
        }
        if (git_backend == null) {
            std.debug.print(
                "ajt install: {s}: a git clone would install it; no backend ({s})\n",
                .{ r.name, if (use_git) "no usable `git`" else "--no-git" },
            );
        }
    }

    // --- fixups ------------------------------------------------------------
    if (fixups) {
        const manifest_dir = std.fs.path.dirname(mpath) orelse ".";
        const report = try pkg_ops.fixupsFromProjectFile(gpa, arena, io, stack, &m, .{
            .manifest_dir = manifest_dir,
            .stdlib_dir = stdlib_dir,
        });
        var stdlib_skipped: usize = 0;
        for (report) |f| {
            if (f.skipped == .stdlib_dir_unknown) stdlib_skipped += 1;
            try out.print("fixup\t{s}\t{s}\t{d}\t", .{
                f.name,
                f.project_file orelse "-",
                @intFromBool(f.changed),
            });
            if (f.removed_deps.len == 0) {
                try out.writeAll("-");
            } else {
                for (f.removed_deps, 0..) |d, n| {
                    if (n != 0) try out.writeAll(",");
                    try out.writeAll(d);
                }
            }
            try out.writeAll("\n");
        }
        // Julia never reaches this state — it always knows `Sys.STDLIB` — so a
        // silent skip here would be a divergence that leaves no trace in the
        // manifest. Say it out loud instead.
        if (stdlib_skipped != 0) {
            std.debug.print(
                "ajt install: {d} stdlib entries skipped by fixups; pass --stdlib <Types.stdlib_dir()> to include them\n",
                .{stdlib_skipped},
            );
        }
    }

    if (output) |path| {
        var buf: [64 * 1024]u8 = undefined;
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var fw = file.writer(io, &buf);
        try m.write(gpa, arena, &fw.interface);
        try fw.interface.flush();
    }

    // Reported last, after every record has been printed: a caller wants the
    // per-package detail even when the run as a whole failed. The flush has to
    // happen HERE and not at the call site, because returning an error skips
    // the caller's flush and the records would be lost with it — precisely
    // when they matter most.
    try out.flush();
    try pkg_ops.check(results);
}

const inst_ops = ajt.ops.instantiate;

/// The registry seam `ajt instantiate` hands to `ops/instantiate.zig`.
///
/// Lazy on purpose, and the laziness is the point: `instantiate` calls `open`
/// only AFTER it has decided whether the registry needs installing and, if so,
/// installed it. Opening a backend up front would hand back a lookup built from
/// the registry that was there BEFORE this run — on a cold depot, no registry at
/// all — so every package would lose its GitHub fallback URL on the one run that
/// most needs it.
const LazyRegistry = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    depot: []const u8,
    name: []const u8,
    source: Source,
    /// Kept here rather than on the stack because `RegistryRepos` borrows a
    /// pointer to it that outlives `open`.
    backend: ?Backend = null,
    repos: RegistryRepos = .{ .backend = null, .gpa = undefined },
    opened: bool = false,

    fn open(ctx: *anyopaque) pkg_ops.RepoLookup {
        const self: *LazyRegistry = @ptrCast(@alignCast(ctx));
        // `instantiate` calls this once, but "once" is a property of the
        // caller, not of this type: a second call would overwrite `backend`
        // and leak the ~84 MB arena the archive backend holds.
        if (self.opened) return self.repos.lookup();
        self.opened = true;
        self.backend = openBackend(self.gpa, self.arena, self.io, self.depot, self.name, self.source) catch |err| {
            // Survivable: the Pkg server serves by UUID and tree hash alone, so
            // this only costs the GitHub fallback. Saying so beats refusing to
            // install anything.
            std.debug.print("ajt instantiate: no {s} registry ({s}); GitHub fallback URLs unavailable\n", .{
                self.name, @errorName(err),
            });
            self.repos = .{ .backend = null, .gpa = self.gpa };
            return self.repos.lookup();
        };
        self.repos = .{ .backend = if (self.backend) |*b| b else null, .gpa = self.gpa };
        return self.repos.lookup();
    }

    fn seam(self: *LazyRegistry) inst_ops.Registry {
        return .{ .ctx = @ptrCast(self), .open = open };
    }

    fn deinit(self: *LazyRegistry, io: Io) void {
        if (self.backend) |*b| b.deinit(io);
    }
};

/// `ajt instantiate --frozen [options] [env]` — the whole of `Pkg.instantiate`
/// that does not resolve.
///
/// Records go to stdout, TAB-separated, one per line:
///
///   `registry <action> <name>`
///   `package  <outcome> <name> <uuid> <tree-hash> <path>`
///   `artifact <outcome> <name> <hash> <path>`
///   `fixup    <name> <project-file|-> <changed 0|1> <removed deps|->`
///   `manifest <written|unchanged> <path>`
///   `summary  <entries> <pruned> <pkg-jobs> <pkg-installed> <art-jobs> <art-installed> <ms>`
///   `verify   <ok|failed> <problems>`
///
/// `--dry-run` replaces the `package`/`artifact` records with `plan-package`
/// (name, tree hash, then every candidate URL in order) and `plan-artifact`.
///
/// Exit status is 0 only when every step succeeded AND the environment now
/// verifies. "Installed everything and still does not verify" is a real state —
/// a `[sources]` git checkout this unit does not implement will produce it — and
/// exiting 0 there would tell a container entrypoint the environment is ready
/// when it is not.
fn cmdInstantiate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var registry_depot: ?[]const u8 = null;
    var source: Source = .auto;
    var julia_bindir: ?[]const u8 = null;
    var host_spec: []const u8 = "";
    var env_path: ?[]const u8 = null;
    var jobs_flag: ?u32 = null;
    var server: ?[]const u8 = null;
    var server_given = false;
    var quiet = false;
    var use_git = true;
    // `allow_autoprecomp::Bool = true` (`API.jl:1288`) -- the user-facing
    // `Pkg.instantiate()` precompiles; the struct default is off because every
    // internal caller of `inst_ops.run` is one of Pkg's `allow_autoprecomp =
    // false` sites.
    var opts: inst_ops.Options = .{
        .env_path = ".",
        .stack = .{ .entries = &.{} },
        .precompile = true,
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--frozen")) {
            // Accepted and documented, deliberately not stored: there is no
            // non-frozen path. See the module header in ops/instantiate.zig for
            // why the flag exists anyway.
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--registry-depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-depot");
            registry_depot = args[i];
        } else if (std.mem.eql(u8, a, "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            opts.registry_name = args[i];
        } else if (std.mem.eql(u8, a, "--registry-policy")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-policy");
            opts.registry_policy = if (std.mem.eql(u8, args[i], "if-missing"))
                .if_missing
            else if (std.mem.eql(u8, args[i], "always"))
                .always
            else if (std.mem.eql(u8, args[i], "never"))
                .never
            else {
                std.debug.print("ajt instantiate: unknown --registry-policy '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--source")) {
            i += 1;
            if (i >= args.len) return missingValue("--source");
            source = std.meta.stringToEnum(Source, args[i]) orelse {
                std.debug.print("ajt instantiate: unknown --source '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= args.len) return missingValue("--server");
            // Empty is meaningful: it is how Julia turns the protocol off.
            server = try ajt.net.pkgServer(arena, args[i]);
            server_given = true;
        } else if (std.mem.eql(u8, a, "--jobs")) {
            i += 1;
            if (i >= args.len) return missingValue("--jobs");
            jobs_flag = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("ajt instantiate: --jobs wants an integer, got '{s}'\n", .{args[i]});
                return error.MissingArgument;
            };
            if (jobs_flag.? < 1) {
                std.debug.print("ajt instantiate: --jobs must be at least 1\n", .{});
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= args.len) return missingValue("--host");
            host_spec = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-bindir")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-bindir");
            julia_bindir = args[i];
        } else if (std.mem.eql(u8, a, "--stdlib")) {
            i += 1;
            if (i >= args.len) return missingValue("--stdlib");
            opts.stdlib_dir = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--include-lazy")) {
            opts.include_lazy = true;
        } else if (std.mem.eql(u8, a, "--no-overrides")) {
            opts.honor_overrides = false;
        } else if (std.mem.eql(u8, a, "--no-artifacts")) {
            opts.artifacts = false;
        } else if (std.mem.eql(u8, a, "--no-fixups")) {
            opts.fixups = false;
        } else if (std.mem.eql(u8, a, "--no-git")) {
            use_git = false;
        } else if (std.mem.eql(u8, a, "--no-write-manifest")) {
            opts.write_manifest = false;
        } else if (std.mem.eql(u8, a, "--no-precompile")) {
            // `allow_autoprecomp = false` (`API.jl:1288`). The struct default
            // is off and the CLI default is on -- see `Options.precompile`.
            opts.precompile = false;
        } else if (std.mem.eql(u8, a, "--precompile")) {
            opts.precompile = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt instantiate: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (env_path == null) {
            env_path = a;
        } else {
            std.debug.print("ajt instantiate: one environment at a time\n", .{});
            return error.UnknownOption;
        }
    }
    opts.env_path = env_path orelse ".";

    // Records go to a 64 KiB buffer, so an error anywhere after the first print
    // would otherwise discard them — and a run that failed halfway is exactly
    // when the per-item detail is worth most.
    defer out.flush() catch {};

    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);
    // `Sys.BINDIR` is consulted only to expand an EMPTY `JULIA_DEPOT_PATH`
    // entry into Julia's bundled depots — but when that happens it decides what
    // counts as installed, so it has to be the SAME Julia both commands answer
    // for. `cmdVerify` derives it from `--julia-prefix`; deriving it from `$PATH`
    // here would let `ajt instantiate --julia-prefix /opt/julia` and
    // `ajt verify --julia-prefix /opt/julia` disagree about the depot stack,
    // which is exactly the pairing this command's converge step asserts.
    const bindir = julia_bindir orelse if (opts.julia_prefix) |p|
        try fspath.join(arena, &.{ p, "bin" })
    else
        null;
    opts.stack = try resolveStack(arena, io, environ, depots.items, bindir);
    if (opts.stack.entries.len == 0) {
        std.debug.print("ajt instantiate: DEPOT_PATH is empty, nowhere to install to\n", .{});
        return error.MissingArgument;
    }

    // Through `parseHostPlatform`, never a hand-built tag list: the constructor
    // normalises (auto libc/call_abi, arch aliases, version rounding) and that
    // normalisation decides which artifact variant wins.
    if (host_spec.len != 0) opts.host = try parseHostPlatform(arena, host_spec);

    var config = try netConfig(arena, environ, .{ .server = server });
    if (server_given) config.server = server;
    // Auth tokens and the metadata headers belong to the depot being written.
    config.depot = opts.stack.entries[0];
    opts.net = config;
    opts.server = config.server;
    opts.jobs = jobs_flag orelse config.concurrency;

    // Julia decides tarball-vs-directory from the environment, not from a flag
    // (`registry_instance.jl` via `Registry.download_registries`), and a depot
    // whose registries are unpacked must stay unpacked or `readInstalled` finds
    // nothing and every run re-downloads.
    opts.unpack_registry = environ.get("JULIA_PKG_UNPACK_REGISTRY");

    // The precompile children inherit the parent's environment -- PATH, HOME,
    // JULIA_CPU_TARGET -- and this is where JULIA_PKG_PRECOMPILE_AUTO is read.
    //
    // `precompile_jobs` is deliberately left at null rather than fed from
    // `--jobs`: that flag is CONCURRENT DOWNLOADS, whose sensible value is 8
    // on any machine, while a compile child is a whole `julia`. Handing 8 to
    // both would fork eight of them on a two-core container.
    opts.environ = environ;
    opts.precompile_cache_url = cacheUrlFromEnv(environ);

    var registry: LazyRegistry = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .depot = registry_depot orelse opts.stack.entries[0],
        .name = opts.registry_name,
        .source = source,
    };
    defer registry.deinit(io);
    opts.registry_depot = registry_depot;

    // A `repo-url` manifest entry has no archive at all, so without this the
    // environment can never converge. Not opened for `--dry-run`, which
    // downloads nothing.
    var git_state: GitBackend = .{};
    defer git_state.deinit();
    if (use_git and !opts.dry_run) opts.git = try git_state.openOwned(gpa, arena, io, environ, "instantiate");

    const t0 = Io.Clock.awake.now(io);
    const rep = try inst_ops.run(gpa, arena, io, opts, registry.seam());
    const elapsed = msSince(io, t0);

    if (rep.blocked) |p| {
        try out.print("blocked\t{f}\n", .{p});
        std.debug.print("ajt instantiate: {f}\n", .{p});
        try out.flush();
        std.process.exit(1);
    }

    if (!quiet) {
        if (rep.registry.attempted) {
            try out.print("registry\t{s}\t{s}\n", .{
                if (rep.registry.err) |e| e else if (rep.registry.action) |a| @tagName(a) else "-",
                rep.registry.name,
            });
        }

        if (opts.dry_run) {
            for (rep.package_jobs) |job| {
                var hash_buf: [40]u8 = undefined;
                try out.print("plan-package\t{s}\t{s}", .{
                    job.name,
                    ajt.model.manifest.formatSha1(job.tree_hash, &hash_buf),
                });
                for (try pkg_ops.candidates(arena, job, opts.server)) |c| {
                    try out.print("\t{s}", .{c.url});
                }
                try out.writeAll("\n");
            }
            for (rep.artifact_jobs) |job| {
                try out.print("plan-artifact\t{s}\t{s}\t{s}\t{s}\n", .{
                    job.name,
                    job.hash_hex,
                    if (job.present) "present" else "missing",
                    job.path,
                });
            }
        } else {
            for (rep.packages) |r| {
                var uuid_buf: [36]u8 = undefined;
                var hash_buf: [40]u8 = undefined;
                try out.print("package\t{t}\t{s}\t{s}\t{s}\t{s}\n", .{
                    r.outcome,
                    r.name,
                    ajt.model.manifest.formatUuid(r.uuid, &uuid_buf),
                    ajt.model.manifest.formatSha1(r.tree_hash, &hash_buf),
                    r.path,
                });
            }
            for (rep.artifacts) |r| {
                try out.print("artifact\t{t}\t{s}\t{s}\t{s}\n", .{
                    r.outcome, r.job.name, r.job.hash_hex, r.path,
                });
            }
            for (rep.fixups) |f| {
                try out.print("fixup\t{s}\t{s}\t{d}\t", .{
                    f.name,
                    f.project_file orelse "-",
                    @intFromBool(f.changed),
                });
                if (f.removed_deps.len == 0) {
                    try out.writeAll("-");
                } else {
                    for (f.removed_deps, 0..) |d, n| {
                        if (n != 0) try out.writeAll(",");
                        try out.writeAll(d);
                    }
                }
                try out.writeAll("\n");
            }
            try out.print("manifest\t{s}\t{s}\n", .{
                if (!opts.fixups or !opts.write_manifest)
                    "skipped"
                else if (rep.manifest_written)
                    "written"
                else
                    "unchanged",
                rep.manifest_file,
            });
        }
    }

    try out.print("summary\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\n", .{
        rep.entries,
        rep.pruned,
        rep.package_jobs.len,
        rep.installedCount(),
        rep.artifact_jobs.len,
        rep.artifactsInstalledCount(),
        elapsed,
    });
    // What `Pkg.gc()` will read. Reported on stdout rather than left implicit,
    // because "installed everything and recorded nothing" looks identical to a
    // full success from the outside right up until a `gc` empties the depot.
    for ([_]struct { []const u8, ajt.ops.instantiate.UsageStep }{
        .{ ajt.ops.usage.manifest_log, rep.usage_manifest },
        .{ ajt.ops.usage.artifact_log, rep.usage_artifact },
    }) |pair| {
        const log, const step = pair;
        try out.print("usage\t{s}\t{d}\t{s}\n", .{
            log,
            step.keys,
            if (step.err) |e| e else if (step.written) "written" else "unchanged",
        });
    }

    try out.print("verify\t{s}\t{d}\n", .{
        if (rep.converged()) "ok" else "failed",
        rep.after.problems.len,
    });

    // Step 8, in one line. `ajt precompile` is the command whose product is the
    // per-package report; here the counts are enough to tell "it ran and there
    // was nothing to do" from "it never ran".
    if (rep.precompile) |p| {
        try printPrecompile(out, "instantiate", p);
    } else if (rep.precompile_skipped) |why| {
        try out.print("precompile\tskipped\t{t}\n", .{why});
    }

    // --- diagnostics, on stderr, for everything that went wrong ------------
    //
    // Pkg throws away the detail here: one `@warn "tarball content does not
    // match git-tree-sha1"` for a failure that could be any of six causes.
    // `install` returns one `Result` per `Job`, in order, so the index is the
    // job — which is the only way to tell "no archive URL" from "tracked by a
    // repo-url, which never had one".
    for (rep.packages, 0..) |r, ji| {
        if (r.ok()) continue;
        const repo_tracked = ji < rep.package_jobs.len and rep.package_jobs[ji].repo != null;
        var hash_buf: [40]u8 = undefined;
        for (r.attempts) |at| {
            if (!at.tried) continue;
            // Two fetches of one remote differ only in their refspec; without
            // it the second line reads as a duplicate of the first.
            if (at.refspec) |spec| {
                if (at.err) |e| {
                    std.debug.print("ajt instantiate: {s}: git fetch {s} {s}: {s}\n", .{
                        r.name, at.url, spec, @errorName(e),
                    });
                }
                continue;
            }
            if (at.status) |st| {
                std.debug.print("ajt instantiate: {s}: {s}: HTTP {d}\n", .{ r.name, at.url, @intFromEnum(st) });
            } else if (at.computed) |got| {
                std.debug.print("ajt instantiate: {s}: {s}: tree hash is {s}, manifest pins {s}\n", .{
                    r.name, at.url, got, ajt.model.manifest.formatSha1(r.tree_hash, &hash_buf),
                });
            } else if (at.err) |e| {
                std.debug.print("ajt instantiate: {s}: {s}: {s}\n", .{ r.name, at.url, @errorName(e) });
            }
        }
        if (r.outcome == .needs_git_clone and r.attempts.len == 0) {
            // A `repo-url` entry ALWAYS lands here with no attempts — it is
            // built with no candidates — so the registry is the wrong thing to
            // blame for it. Pointing at a registry that could never serve a
            // git-tracked entry is exactly the confusion `--no-git` creates.
            if (repo_tracked) {
                std.debug.print(
                    "ajt instantiate: {s}: tracked by repo-url; a git clone is the only way to install it, and there is no backend ({s})\n",
                    .{ r.name, if (use_git) "no usable `git`" else "--no-git" },
                );
            } else {
                std.debug.print("ajt instantiate: {s}: no archive URL (not in {s}?)\n", .{ r.name, opts.registry_name });
                if (opts.git == null) {
                    std.debug.print(
                        "ajt instantiate: {s}: a git clone would install it; no backend ({s})\n",
                        .{ r.name, if (use_git) "no usable `git`" else "--no-git" },
                    );
                }
            }
        }
    }
    for (rep.artifacts) |r| {
        for (r.attempts) |at| {
            const reason = at.failure orelse continue;
            std.debug.print("ajt instantiate: artifact {s}: {s} failed: {s}", .{ r.job.name, at.url, @tagName(reason) });
            if (at.status) |s| std.debug.print(" (HTTP {d})", .{@intFromEnum(s)});
            if (at.computed) |c| std.debug.print(" got {s}", .{c});
            std.debug.print("\n", .{});
        }
    }
    for (rep.artifact_problems) |fp| {
        std.debug.print("ajt instantiate: {s}: artifact '{s}' entry {d}: {s} (Pkg would refuse this file)\n", .{
            fp.artifacts_toml, fp.problem.artifact, fp.problem.index, @tagName(fp.problem.reason),
        });
    }
    if (rep.artifacts_skipped) |why| switch (why) {
        .no_host => std.debug.print(
            "ajt instantiate: no host platform (pass --host, or --julia-prefix so it can be detected); " ++
                "artifacts were NOT installed and this environment will fail at dlopen time\n",
            .{},
        ),
        .plan_failed => std.debug.print(
            "ajt instantiate: could not read an Artifacts.toml ({s}); artifacts were NOT installed\n",
            .{rep.artifacts_error orelse "unknown"},
        ),
        .disabled => {},
    };
    if (rep.stdlib_skipped != 0) {
        std.debug.print(
            "ajt instantiate: {d} stdlib entries skipped by fixups; pass --stdlib <Types.stdlib_dir()> to include them\n",
            .{rep.stdlib_skipped},
        );
    }
    if (!rep.converged()) {
        // `converged()` also folds in the artifact half, which `verify` does
        // not check — so an empty problem list here is not a contradiction, it
        // means the artifacts are what is missing. Say which.
        if (rep.after.ok()) {
            std.debug.print(
                "ajt instantiate: the packages verify but the artifacts do not — " ++
                    "Pkg.instantiate() would still have work to do\n",
                .{},
            );
        }
        const cap = 20;
        for (rep.after.problems, 0..) |p, n| {
            if (n == cap) {
                std.debug.print("ajt instantiate: ... and {d} more\n", .{rep.after.problems.len - cap});
                break;
            }
            std.debug.print("ajt instantiate: still not instantiated: {f}\n", .{p});
        }
    }

    try out.flush();
    // Under --dry-run `after` is `before`, which is "not instantiated" by
    // construction on any environment worth instantiating -- so only the
    // per-step verdict applies.
    if (opts.dry_run) {
        if (!rep.ok()) std.process.exit(1);
        return;
    }
    if (!rep.ok() or !rep.converged()) std.process.exit(1);
}

/// The `DEPOT_PATH` an install searches and writes to.
///
/// Explicit `--depot` flags replace the stack outright (that is what makes a
/// scratch-depot install possible); otherwise `init_depot_path()` runs for
/// real.
///
/// That needs a `Sys.BINDIR`, and it needs it on the COMMON path, not just an
/// exotic one: `init_depot_path()` calls `append_bundled_depot_path!`
/// unconditionally when `JULIA_DEPOT_PATH` is unset (`initdefs.jl:134-137`),
/// which is the default invocation. So the bindir is located the same way a
/// shell would — the first `julia` on `PATH`, resolved through symlinks, which
/// is exactly what `Sys.BINDIR` is — and `--julia-bindir` overrides it for a
/// caller targeting a different Julia.
fn resolveStack(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    explicit: []const []const u8,
    julia_bindir: ?[]const u8,
) !ajt.depot.Stack {
    if (explicit.len != 0) return .{ .entries = try arena.dupe([]const u8, explicit) };
    const bindir = julia_bindir orelse try findJuliaBindir(arena, io, environ);
    return ajt.depot.resolve(arena, .{
        .julia_depot_path = environ.get("JULIA_DEPOT_PATH"),
        .home = environ.get("HOME"),
        .julia_bindir = bindir,
    }) catch |err| {
        std.debug.print(
            "ajt install: cannot resolve DEPOT_PATH ({s}); pass --depot or --julia-bindir\n",
            .{@errorName(err)},
        );
        return err;
    };
}

/// `Sys.BINDIR`: the directory holding the `julia` that `PATH` would run, with
/// symlinks resolved (a distro or Nix wrapper is normally a symlink into the
/// real install, and the bundled depots hang off the real one). Null when
/// there is no `julia` on `PATH` at all — then only an explicit `--depot` or
/// `--julia-bindir` can produce a stack.
fn findJuliaBindir(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !?[]const u8 {
    const path = environ.get("PATH") orelse return null;
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrint(&name_buf, "{s}{c}julia", .{ dir, std.fs.path.sep }) catch continue;
        const n = Io.Dir.cwd().realPathFile(io, candidate, &real_buf) catch continue;
        const parent = std.fs.path.dirname(real_buf[0..n]) orelse continue;
        return try arena.dupe(u8, parent);
    }
    return null;
}

/// Fills `depots` from the environment when no `--depot` was given.
///
/// The whole DEPOT_PATH matters, not just its first entry: an artifact can be
/// installed in any depot and `artifact_exists` says yes if ANY of them has
/// it (only the first is ever WRITTEN to). NB this is the naive split; Julia
/// also expands an EMPTY entry to the default depot list. The differential
/// gates pass Julia's own resolved DEPOT_PATH explicitly, so they do not
/// exercise this fallback.
fn defaultDepots(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    depots: *std.ArrayList([]const u8),
) !void {
    if (depots.items.len != 0) return;
    if (environ.get("JULIA_DEPOT_PATH")) |v| {
        var it = std.mem.splitScalar(u8, v, ':');
        while (it.next()) |d| {
            if (d.len != 0) try depots.append(gpa, d);
        }
    }
    if (depots.items.len != 0) return;
    if (environ.get("HOME")) |home| {
        try depots.append(gpa, try std.fmt.allocPrint(arena, "{s}/.julia", .{home}));
    }
}

/// Parses the `k=v,k=v` host spec shared by `select-artifact` and `artifact`.
/// The tag slices borrow from `spec`; only the outer array is allocated.
/// Parses the `k=v,k=v` host spec shared by `select-artifact` and `artifact`
/// into the host `Platform` it names.
///
/// The spec goes through `platform.construct`, exactly as the differential
/// gate's Julia side does `HostPlatform(Platform(arch, os, tags))`. It used to
/// be taken verbatim, which made "write the spec ALREADY NORMALISED" a rule
/// enforced only by a comment in `artifacts_model.sh` -- spell one host
/// `os_version=10.12` instead of `10.12.0` and the two sides silently compare
/// different hosts. `construct` is idempotent on already-normalised input, so
/// specs that were correct stay correct.
///
/// `arena` owns the result; tag slices that need no rewriting borrow from
/// `spec`.
fn parseHostPlatform(arena: std.mem.Allocator, spec: []const u8) !ajt.julia.platform.Platform {
    var tags: std.ArrayList(ajt.julia.platform.Tag) = .empty;
    var arch: []const u8 = "";
    var os: []const u8 = "";
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |kv| {
        const t = std.mem.trim(u8, kv, " ");
        if (t.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = t[0..eq];
        const value = t[eq + 1 ..];
        // arch/os are the constructor's positional parameters, not tags.
        if (std.mem.eql(u8, key, "arch")) {
            arch = value;
        } else if (std.mem.eql(u8, key, "os")) {
            os = value;
        } else {
            try tags.append(arena, .{ .key = key, .value = value });
        }
    }
    return ajt.julia.platform.constructHost(arena, arch, os, tags.items);
}

/// `ajt artifact <info|downloadable|resolve|path|find> ...`
///
/// One process handles many files because the differential gate needs a result
/// for every one of the depot's Artifacts.toml, and a process per file would
/// make it too slow to run routinely.
///
/// Every subcommand prints TAB-separated fields, one record per line, in input
/// order — the gate sorts both sides, since Julia iterates the artifact dict in
/// hash order.
fn cmdArtifact(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    const artifacts = ajt.install.artifacts;

    if (args.len == 0) {
        std.debug.print("ajt artifact: no subcommand (info|downloadable|resolve|path|find)\n", .{});
        return error.MissingArgument;
    }
    const sub = args[0];

    var host_spec: []const u8 = "";
    var pkg_uuid: []const u8 = "";
    var include_lazy = false;
    var honor_overrides = true;
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return missingValue("--host");
            host_spec = args[i];
        } else if (std.mem.eql(u8, arg, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--pkg-uuid")) {
            i += 1;
            if (i >= args.len) return missingValue("--pkg-uuid");
            pkg_uuid = args[i];
        } else if (std.mem.eql(u8, arg, "--include-lazy")) {
            include_lazy = true;
        } else if (std.mem.eql(u8, arg, "--no-overrides")) {
            honor_overrides = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("ajt artifact: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        } else {
            try targets.append(gpa, arg);
        }
    }

    if (targets.items.len == 0) {
        std.debug.print("ajt artifact {s}: nothing to do\n", .{sub});
        return error.MissingArgument;
    }

    const host = try parseHostPlatform(arena, host_spec);

    // `find` reads no depot, so it returns before the resolution below.
    if (std.mem.eql(u8, sub, "find")) {
        for (targets.items) |root| {
            const found = try artifacts.findArtifactsToml(arena, io, root);
            try out.print("{s}\t{s}\n", .{ root, found orelse "NONE" });
        }
        return;
    }

    // With no --depot the whole DEPOT_PATH is what matters, not just its first
    // entry: an artifact can be installed in any depot and `artifact_exists`
    // says yes if ANY of them has it. `Stack.entries` IS that list, in Julia's
    // search order, empty-entry rule included. (The differential gate passes
    // Julia's own resolved DEPOT_PATH explicitly, so it pins `--depot`, not
    // this fallback.)
    if (depots.items.len == 0) {
        const stack = try resolveDepotStack(arena, io, environ, "artifact");
        try depots.appendSlice(gpa, stack.entries);
    }

    // Overrides are shared across every target, so load them once. Arena: they
    // outlive each per-file scratch arena below.
    var overrides = try artifacts.loadOverrides(arena, io, depots.items);

    if (std.mem.eql(u8, sub, "path")) {
        for (targets.items) |hash| {
            const p = try artifacts.artifactPath(arena, io, depots.items, hash, &overrides, honor_overrides);
            const exists = try artifacts.artifactExists(arena, io, depots.items, hash, &overrides, honor_overrides);
            try out.print("{s}\t{s}\t{d}\n", .{ hash, p, @intFromBool(exists) });
        }
        return;
    }

    const want_info = std.mem.eql(u8, sub, "info");
    const want_downloadable = std.mem.eql(u8, sub, "downloadable");
    const want_resolve = std.mem.eql(u8, sub, "resolve");
    if (!want_info and !want_downloadable and !want_resolve) {
        std.debug.print("ajt artifact: unknown subcommand '{s}'\n", .{sub});
        return error.UnknownCommand;
    }

    for (targets.items) |path| {
        // One arena per file: a corpus sweep is ~1300 entries and there is no
        // reason to hold them all at once.
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const file = artifacts.load(fa, io, path) catch |err| {
            std.debug.print("ajt artifact: {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };

        // A recorded problem means real Julia would have THROWN on this file
        // (see `Problem` in install/artifacts.zig) — Ajt still answers, so the
        // answer has to come with the warning attached. stderr, so the
        // record stream on stdout stays diffable.
        for (file.problems) |p| {
            std.debug.print("ajt artifact: {s}: artifact '{s}' entry {d}: {s} (Pkg would refuse this file)\n", .{
                path, p.artifact, p.index, @tagName(p.reason),
            });
        }

        if (want_downloadable) {
            const sel = try artifacts.selectDownloadable(fa, gpa, file, host, include_lazy);
            for (sel) |s| {
                try out.print("{s}\t{s}\t{s}\n", .{ path, s.name, s.variant.git_tree_sha1.? });
            }
            continue;
        }

        // `resolve` mints hash overrides from the owning package's UUID/name
        // overrides before resolving any path (`Artifacts.jl:341-372`).
        if (want_resolve and pkg_uuid.len != 0) {
            try artifacts.processOverrides(&overrides, file, pkg_uuid);
        }

        for (file.artifacts) |*art| {
            const v = (try artifacts.select(gpa, art, host)) orelse {
                try out.print("{s}\t{s}\tNONE\t-\t-\t-", .{ path, art.name });
                if (want_resolve) try out.writeAll("\t-\t-");
                try out.writeAll("\n");
                continue;
            };
            const sha1 = v.git_tree_sha1.?;
            try out.print("{s}\t{s}\t{s}\tlazy={d}\tdownload={d}\t", .{
                path, art.name, sha1, @intFromBool(v.lazy), @intFromBool(v.has_download),
            });
            if (v.downloads.len == 0) {
                try out.writeAll("-");
            } else {
                for (v.downloads, 0..) |d, n| {
                    if (n != 0) try out.writeAll(" ");
                    try out.print("{s}|{s}", .{ d.url, d.sha256 });
                }
            }
            if (want_resolve) {
                const p = try artifacts.artifactPath(arena, io, depots.items, sha1, &overrides, honor_overrides);
                const exists = try artifacts.artifactExists(arena, io, depots.items, sha1, &overrides, honor_overrides);
                try out.print("\t{s}\t{d}", .{ p, @intFromBool(exists) });
            }
            try out.writeAll("\n");
        }
    }
}

/// `ajt install-artifacts [options] <package-root>...`
///
/// The install half of `Pkg.Operations.download_artifacts`: collect what the
/// given packages need for a host, then download, verify and publish it.
///
/// One record per artifact on stdout, TAB-separated:
/// `<Artifacts.toml>  <name>  <hash>  <outcome>  <path>`. Every failed source
/// is reported on stderr with its URL and reason, because "artifact X failed"
/// without the list of what was tried and how it broke is undiagnosable.
fn cmdInstallArtifacts(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    const ops = ajt.ops.install_artifacts;

    var host_spec: []const u8 = "";
    var julia_prefix: ?[]const u8 = null;
    var base: ajt.net.Config = .{};
    var server_given = false;
    var plan_opts: ops.PlanOptions = .{};
    var install_opts: ops.InstallOptions = .{};
    var dry_run = false;
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var packages: std.ArrayList(ops.Package) = .empty;
    defer packages.deinit(gpa);
    // `--pkg-uuid` applies to the roots that FOLLOW it, so one invocation can
    // carry several packages with their own UUID/name overrides.
    var pending_uuid: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= args.len) return missingValue("--host");
            host_spec = args[i];
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--pkg-uuid")) {
            i += 1;
            if (i >= args.len) return missingValue("--pkg-uuid");
            pending_uuid = args[i];
        } else if (std.mem.eql(u8, a, "--server")) {
            i += 1;
            if (i >= args.len) return missingValue("--server");
            // An empty value is how Julia turns the Pkg-server protocol off.
            base.server = try ajt.net.pkgServer(arena, args[i]);
            server_given = true;
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            base.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-system")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-system");
            base.julia_system = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--retry")) {
            i += 1;
            if (i >= args.len) return missingValue("--retry");
            install_opts.retry.attempts = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("ajt install-artifacts: --retry wants an integer, got '{s}'\n", .{args[i]});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, a, "--include-lazy")) {
            plan_opts.include_lazy = true;
        } else if (std.mem.eql(u8, a, "--no-overrides")) {
            plan_opts.honor_overrides = false;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt install-artifacts: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try packages.append(gpa, .{ .root = a, .uuid = pending_uuid });
        }
    }

    if (packages.items.len == 0) {
        std.debug.print("ajt install-artifacts: no package roots given\n", .{});
        return error.MissingArgument;
    }
    if (host_spec.len == 0) {
        // Guessing the host here would install a working-looking set of
        // artifacts for the wrong platform, which fails at `dlopen` time.
        std.debug.print("ajt install-artifacts: --host is required (see `ajt host-platform`)\n", .{});
        return error.MissingArgument;
    }

    try defaultDepots(gpa, arena, environ, &depots);
    if (depots.items.len == 0) {
        std.debug.print("ajt install-artifacts: no depot (set --depot or JULIA_DEPOT_PATH)\n", .{});
        return error.MissingArgument;
    }

    // Through `parseHostPlatform`, not a hand-built tag list: the Platform
    // CONSTRUCTOR normalises (auto libc/call_abi, arch aliases, version
    // rounding) and that normalisation decides which artifact variant wins.
    // This call site was written against the pre-normalisation helper; leaving
    // it would install the wrong tarball on exactly the hosts the 7-host
    // artifacts_model.sh sweep exists to cover.
    const host = try parseHostPlatform(arena, host_spec);

    // `Config.fromEnv` only fills what is still unset, so explicit flags win;
    // `--server ""` legitimately resolves to null, which fromEnv would re-fill.
    var config = try netConfig(arena, environ, base);
    if (server_given) config.server = base.server;
    // The metadata headers go to the FIRST depot's servers/<host>/auth.toml,
    // which is also the depot being written to.
    config.depot = depots.items[0];
    if (julia_prefix) |prefix| {
        if (config.julia_version.len == 0) {
            std.debug.print("ajt install-artifacts: --julia-prefix also needs --julia-version\n", .{});
            return error.MissingArgument;
        }
        const detected = try ajt.julia.platform.detectHost(arena, io, .{
            .julia_prefix = prefix,
            .julia_version = config.julia_version,
        });
        config.julia_system = try ajt.julia.platform.triplet(arena, detected);
    }

    const p = ops.plan(arena, gpa, io, depots.items, packages.items, host, plan_opts) catch |err| {
        std.debug.print("ajt install-artifacts: planning failed: {s}\n", .{@errorName(err)});
        return err;
    };
    for (p.problems) |fp| {
        std.debug.print("ajt install-artifacts: {s}: artifact '{s}' entry {d}: {s} (Pkg would refuse this file)\n", .{
            fp.artifacts_toml, fp.problem.artifact, fp.problem.index, @tagName(fp.problem.reason),
        });
    }

    if (dry_run) {
        for (p.jobs) |job| {
            const state: []const u8 = if (job.present) "present" else "missing";
            try out.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                job.artifacts_toml, job.name, job.hash_hex, state, job.path,
            });
        }
        return;
    }

    var client: ajt.net.Client = .init(gpa, io, config);
    defer client.deinit();

    var failures: usize = 0;
    for (p.jobs) |job| {
        const r = try ops.installJob(gpa, arena, io, &client, depots.items, job, install_opts);
        for (r.attempts) |at| {
            const reason = at.failure orelse continue;
            std.debug.print("ajt install-artifacts: {s}: {s} failed: {s}", .{ job.name, at.url, @tagName(reason) });
            if (at.status) |s| std.debug.print(" (HTTP {d})", .{@intFromEnum(s)});
            if (at.computed) |c| std.debug.print(" got {s}", .{c});
            std.debug.print("\n", .{});
        }
        if (r.outcome == .failed) failures += 1;
        try out.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            job.artifacts_toml, job.name, job.hash_hex, @tagName(r.outcome), r.path,
        });
        // Flush per artifact: a 516 MB install is minutes long and a caller
        // watching the stream needs to see progress, not one burst at the end.
        try out.flush();
    }

    // `return write_env_usage(used_artifact_tomls, "artifact_usage.toml")` —
    // the last statement of `download_artifacts` (`Operations.jl:1080`).
    //
    // Run here even when some artifacts FAILED, which Julia does not:
    // `Operations.jl:1067-1075` `pkgerror`s on the first failure and never
    // reaches the write. That is a deliberate divergence, and it only ever
    // protects: the artifacts that DID land are on disk either way, and
    // skipping the log leaves them collectable by the next `Pkg.gc()` even
    // though the environment still needs them.
    //
    // `depots.items[0]` is `depots1()`; non-empty because the argument parse
    // above returns before this point when it is not.
    _ = ajt.ops.usage.record(
        gpa,
        io,
        depots.items[0],
        ajt.ops.usage.artifact_log,
        p.artifact_tomls,
        .{},
    ) catch |err| {
        std.debug.print("ajt install-artifacts: could not record artifact usage: {s}\n", .{@errorName(err)});
    };

    if (failures != 0) {
        std.debug.print("ajt install-artifacts: {d} of {d} artifact(s) failed\n", .{ failures, p.jobs.len });
        return error.InstallFailed;
    }
}

/// `ajt usage record|keys` — direct access to `<depot>/logs/*_usage.toml`.
///
/// `install` and `install-artifacts` already stamp these logs on their own;
/// this exists for the two jobs they cannot do. `record` lets the differential
/// harness exercise the writer — append semantics, key shape, byte-for-byte
/// agreement with `TOML.print` — without a network round trip, and lets a user
/// re-protect a depot that was filled before Ajt wrote logs at all. `keys` is
/// the read side, so a gate can assert on the KEYS without depending on
/// timestamps that are wall-clock by construction and can never match Julia's.
fn cmdUsage(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        std.debug.print("ajt usage: expected 'record' or 'keys'\n", .{});
        return error.MissingArgument;
    }
    const sub = args[0];

    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var log: []const u8 = ajt.ops.usage.manifest_log;
    var allow_missing = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--log")) {
            i += 1;
            if (i >= args.len) return missingValue("--log");
            // A CLOSED set, deliberately. Accepting an arbitrary name would
            // let `--log ../../x` write outside `logs/` entirely, and
            // `--log ../logs/scratch_usage.toml` would reach scratch_usage.toml
            // by a name `record`'s guard does not recognise — destroying the
            // `parent_projects` that guard exists to protect.
            log = if (std.mem.eql(u8, args[i], "manifest"))
                ajt.ops.usage.manifest_log
            else if (std.mem.eql(u8, args[i], "artifact"))
                ajt.ops.usage.artifact_log
            else if (std.mem.eql(u8, args[i], "scratch"))
                // Accepted here so `record` can refuse it with its own reason.
                ajt.ops.usage.scratch_log
            else {
                std.debug.print("ajt usage: --log wants manifest or artifact, got '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--allow-missing")) {
            allow_missing = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt usage: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try paths.append(gpa, a);
        }
    }

    try defaultDepots(gpa, arena, environ, &depots);
    if (depots.items.len == 0) {
        std.debug.print("ajt usage: no depot (set --depot or JULIA_DEPOT_PATH)\n", .{});
        return error.MissingArgument;
    }

    if (std.mem.eql(u8, sub, "record")) {
        if (paths.items.len == 0) {
            std.debug.print("ajt usage record: no paths given\n", .{});
            return error.MissingArgument;
        }
        const done = ajt.ops.usage.record(gpa, io, depots.items[0], log, paths.items, .{
            .filter_missing = !allow_missing,
        }) catch |err| switch (err) {
            error.ScratchLogUnsupported => {
                std.debug.print(
                    "ajt usage record: {s} is append-only and carries parent_projects; refusing\n",
                    .{log},
                );
                return err;
            },
            else => return err,
        };
        // `keys` is what survived the `isfile` filter, so `0` on a non-empty
        // argument list means every path was a ghost and the log was left
        // alone. Printed rather than inferred from the exit code, because both
        // outcomes exit 0 and only one of them protects anything from `gc`.
        try out.print("recorded\t{s}\t{d}\t{s}\n", .{
            log,
            done.keys,
            if (done.written) "written" else "unchanged",
        });
        return;
    }

    if (std.mem.eql(u8, sub, "keys")) {
        if (paths.items.len != 0) {
            std.debug.print("ajt usage keys: takes no paths (got '{s}')\n", .{paths.items[0]});
            return error.UnknownOption;
        }
        const path = try fspath.join(arena, &.{ try ajt.ops.usage.logsDir(arena, depots.items[0]), log });
        const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            // An absent log is the normal state of a depot nothing has
            // recorded into, not an error: it is exactly what Pkg leaves when
            // every source was filtered out as non-existent.
            error.FileNotFound => return,
            else => return err,
        };
        var diag: ajt.toml.Diagnostic = .{};
        var doc = ajt.toml.parse(gpa, src, &diag) catch |err| {
            std.debug.print("ajt usage keys: {s}: line {d}: {s}\n", .{ path, diag.line, diag.message });
            return err;
        };
        defer doc.deinit();
        for (doc.root.entries.items) |e| try out.print("{s}\n", .{e.key});
        return;
    }

    std.debug.print("ajt usage: unknown subcommand '{s}'\n", .{sub});
    return error.UnknownCommand;
}

/// Shared by every subcommand, so it must not name one: it used to say
/// "ajt fmt" and reported that for `registry --depot`, `artifact --host` and
/// the rest.
/// `$AJT_CACHE_URL`, in the shape `$JULIA_PKG_SERVER` already established: a
/// deployment that has a shared precompile store sets it once in the image and
/// nobody types a flag.
///
/// Empty is "off", not "": `--cache-url ""` and `AJT_CACHE_URL=` both mean the
/// protocol is disabled, which is the same convention `pkgServer` uses.
///
/// Only `ajt precompile` has flags for this (`--cache-url`, `--no-cache`); the
/// AUTOMATIC pass reads the environment and nothing else, so that `ajt add` and
/// `ajt instantiate` cannot end up pointed at a different store than the
/// `ajt precompile` that runs beside them.
fn cacheUrlFromEnv(environ: *std.process.Environ.Map) ?[]const u8 {
    const u = environ.get("AJT_CACHE_URL") orelse return null;
    return if (u.len == 0) null else u;
}

/// The one-line `precompile` record, and the per-package diagnostics behind it.
///
/// Shared by `cmdEdit` and `cmdInstantiate` because it is the same pass in both
/// -- and because the first version of this was two copies, and one of them
/// already had a different set of outcomes in its stderr loop.
///
/// The record is `precompile <considered> <compiled> <already> <failed>
/// <imported>`. `imported` is last so the first five fields never move;
/// `compiled` and `imported` are separate numbers because they cost wildly
/// different amounts, and a report that added them together would hide whether
/// the shared cache did anything at all.
fn printPrecompile(
    out: *Io.Writer,
    verb: []const u8,
    rep: precompile_ops.Report,
) !void {
    try out.print("precompile\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        rep.considered,
        rep.compiledCount(),
        rep.countOf(.already_precompiled),
        rep.failedCount(),
        rep.countOf(.imported),
    });
    // Everything `Report.ok()` counts against the run gets a line, or `ajt add`
    // can print a clean-looking record and exit 1 with nothing on stderr.
    if (rep.blocked) |p| {
        std.debug.print("ajt {s}: could not precompile: {f}\n", .{ verb, p });
    }
    if (rep.probe_error) |e| {
        std.debug.print(
            "ajt {s}: could not ask julia what needs compiling ({s}); nothing was precompiled\n",
            .{ verb, e },
        );
    }
    for (rep.packages) |r| switch (r.outcome) {
        .failed, .unknown => std.debug.print("ajt {s}: {s} failed to precompile: {s}\n", .{
            verb, r.name, r.detail,
        }),
        .source_missing => std.debug.print(
            "ajt {s}: {s} has no source on disk, so it could not be precompiled\n",
            .{ verb, r.name },
        ),
        // Never the final outcome of a real run: it means the compile pass was
        // handed a package and did not run it.
        .stale => std.debug.print(
            "ajt {s}: {s} was planned but never compiled -- this is a bug in ajt\n",
            .{ verb, r.name },
        ),
        else => {},
    };
}

fn missingValue(opt: []const u8) error{MissingArgument} {
    std.debug.print("ajt: '{s}' requires a value\n", .{opt});
    return error.MissingArgument;
}

/// `ajt resolve` — run PubGrub over an environment.
fn cmdResolve(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var env_arg: ?[]const u8 = null;
    var depot: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var jver_arg: ?[]const u8 = null;
    var tier: ajt.ops.resolve.Tier = .all;
    var quiet = false;
    var show_changed_only = false;
    var write = false;
    var out_path: ?[]const u8 = null;
    var fixups = true;
    var reg_source: ajt.registry.source.Preference = .auto;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            depot = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            jver_arg = args[i];
        } else if (std.mem.eql(u8, a, "--preserve")) {
            i += 1;
            if (i >= args.len) return missingValue("--preserve");
            tier = ajt.ops.resolve.Tier.parse(args[i]) orelse {
                try out.print("ajt resolve: unknown preserve level '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--changed")) {
            show_changed_only = true;
        } else if (std.mem.eql(u8, a, "--write")) {
            write = true;
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return missingValue("--out");
            out_path = args[i];
            write = true;
        } else if (std.mem.eql(u8, a, "--no-fixups")) {
            fixups = false;
        } else if (std.mem.eql(u8, a, "--registry-source")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-source");
            reg_source = std.meta.stringToEnum(ajt.registry.source.Preference, args[i]) orelse {
                try out.print("ajt resolve: unknown --registry-source '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (a.len > 0 and a[0] == '-') {
            try out.print("ajt resolve: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            env_arg = a;
        }
    }

    const env_dir = env_arg orelse ".";
    const proj = try std.fs.path.join(arena, &.{ env_dir, "Project.toml" });
    const man = try std.fs.path.join(arena, &.{ env_dir, "Manifest.toml" });

    const prefix_resolved = prefix orelse findJuliaPrefix(arena, io, environ);
    const depot_resolved = depot orelse blk: {
        const stack = try resolveDepotStack(arena, io, environ, "resolve");
        break :blk stack.entries[0];
    };

    // The depot search stack. The fixups pass reads each package's own
    // Project.toml out of it, and the *_INSTALLED tiers ask it what is
    // unpacked, so it is needed whether or not anything gets written. An
    // explicit --depot is the whole stack: it names the depot the caller
    // means, and silently searching $JULIA_DEPOT_PATH as well would read
    // sources from somewhere they did not ask for.
    const stack: ajt.depot.Stack = if (depot) |d|
        .{ .entries = try arena.dupe([]const u8, &.{d}) }
    else
        try resolveDepotStack(arena, io, environ, "resolve");

    // Constructed unconditionally and used only by a `[sources]` entry that
    // carries a `url` — building it costs nothing on the `cli` arm (no
    // subprocess runs until the first git call), and the alternative is parsing
    // Project.toml here just to decide whether to build it. A missing `git`
    // therefore surfaces as `BackendUnavailable` on the environment that
    // actually needs one, not as a startup refusal on the thousands that do
    // not. `AJT_GIT_BACKEND=lib` does pay here — `Lib.init` loads a CA bundle —
    // but only for somebody who asked for it.
    var git_state: GitBackend = .{};
    defer git_state.deinit();
    const git_backend = try git_state.open(gpa, arena, io, environ, environ);

    var diag: ajt.ops.resolve.Diagnostic = .{};
    const rep = ajt.ops.resolve.run(arena, io, .{
        .diagnostic = &diag,
        .project_file = proj,
        .manifest_file = man,
        .registry_depot = depot_resolved,
        .registry_source = reg_source,
        .julia_prefix = prefix_resolved,
        .julia_version = if (jver_arg) |t| try ajt.julia.version.parse(arena, t) else null,
        .tier = tier,
        .offline = offline_flag,
        .build_manifest = write,
        .write_to = if (write) out_path orelse man else null,
        .depots = stack,
        .fixups = fixups,
        .git = git_backend,
        .scratch = gpa,
    }) catch |e| {
        // Anything that left an explanation behind is reported as a failure
        // rather than rethrown: a `[sources]` url whose rev does not exist is a
        // fact about the user's project, and Zig's stack trace through the git
        // backend would bury Pkg's own sentence about it.
        if (e != error.NoSolution and e != error.SingletonConflict) {
            const r = diag.report orelse return e;
            try out.writeAll("resolve\tfailed\n");
            try out.writeAll(r);
            try out.flush();
            std.process.exit(1);
        }

        // An unsatisfiable environment is an ANSWER, not a crash: the whole
        // point of PubGrub over MaxSum is that it can say which constraints
        // are irreconcilable. Returning the error here would make Zig dump a
        // stack trace through the solver on top of that explanation, which
        // tells the user about Ajt's internals instead of their project.
        try out.writeAll("resolve\tfailed\n");
        if (diag.report) |r| try out.writeAll(r);
        if (diag.blamed.len != 0) {
            // The tree above is a proof and a bad summary — a real conflict
            // nests dozens of levels and repeats the same learned clause. This
            // is the line that says where to actually edit.
            try out.writeAll("to fix, try relaxing [compat] on:");
            for (diag.blamed) |name| try out.print(" {s}", .{name});
            try out.writeAll("\n");
        }
        try out.flush();
        std.process.exit(1);
    };

    if (!quiet) {
        for (rep.selections) |s| {
            const differs = if (s.was) |w| !ajt.julia.version.Version.eql(w, s.version) else false;
            if (show_changed_only and !differs) continue;
            if (s.was) |w| {
                if (differs) {
                    try out.print("changed\t{s}\t{f}\t{f}\n", .{ s.name, w, s.version });
                } else {
                    try out.print("held\t{s}\t{f}\n", .{ s.name, s.version });
                }
            } else if (s.in_manifest) {
                // In the manifest, but it records no version to hold against:
                // an unversioned stdlib. Ajt still has to choose one, so print
                // what it chose — but never as `added`, which means "Pkg did
                // not have this package" and would be a false accusation.
                try out.print("unversioned\t{s}\t{f}\n", .{ s.name, s.version });
            } else {
                try out.print("added\t{s}\t{f}\n", .{ s.name, s.version });
            }
        }
    }
    // Printed before the manifest line and only when there are any: a
    // `[sources]` url is the one input to a resolve that reaches the NETWORK
    // and writes to the depot, so "which rev did it land on, and did it install
    // anything" is not a detail. `{s}` for the tree hash rather than the 40-char
    // slug, because this line is what a differential gate greps.
    for (rep.repo_sources) |r| {
        var buf: [40]u8 = undefined;
        try out.print("repo\t{s}\t{s}\t{s}\t{s}\t{t}\n", .{
            r.name,
            r.url,
            r.rev,
            ajt.model.manifest.formatSha1(r.tree_hash, &buf),
            r.outcome,
        });
    }
    if (rep.manifest) |m| {
        try out.print("manifest\t{s}\t{d}\t{s}\n", .{
            out_path orelse man,
            m.entries.len,
            if (rep.manifest_written) "written" else "unchanged",
        });
        // Not a warning in passing: these entries have NO weakdeps or
        // extensions recorded, because the only place that information exists
        // is a Project.toml that is not on disk. The manifest is
        // resolve-accurate and fixup-incomplete, and naming them is the
        // difference between a known gap and a silent one.
        for (rep.fixups_missing_source) |name| {
            try out.print("no-source\t{s}\n", .{name});
        }
    }
    try out.print("summary\t{d}\t{d}\t{d}\t{d}\t{d:.0}\t{t}\n", .{
        rep.selections.len, rep.changed, rep.unversioned, rep.added, rep.elapsed_ms, rep.tier_used,
    });
}

/// `ajt add` / `ajt rm` / `ajt up` — one function, because the three differ in
/// about ten lines and duplicating the option parsing three times is how the
/// three drift apart.
fn cmdEdit(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    mode: enum { add, rm, up, pin, free, dev },
    args: []const []const u8,
) !void {
    var env_arg: ?[]const u8 = null;
    var depot_arg: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var jver_arg: ?[]const u8 = null;
    // `add` defaults to what Pkg's `default_preserve()` returns; `up` sets its
    // own tier from the level and ignores this unless asked.
    var tier: ?ajt.ops.resolve.Tier = null;
    var level: ajt.ops.edit.Level = .major;
    var fixups = true;
    var dry_run = false;
    var quiet = false;
    // Pkg's per-verb table, applied inside ops/edit.zig. `--no-precompile`
    // turns it off, `--precompile` widens it to the verbs Pkg leaves out.
    var precompile: ajt.ops.edit.AutoPrecompile = .auto;
    // The explicit repository form. Spelled as flags as well as inline
    // (`Name#rev`, `<url>#rev`) so that a name or a URL containing a `#` stays
    // expressible: the inline grammar takes everything after the first `#` as
    // the rev, exactly as Pkg's REPL does.
    var url_arg: ?[]const u8 = null;
    var rev_arg: ?[]const u8 = null;
    var subdir_arg: ?[]const u8 = null;
    // `Pkg.develop(shared = true)` is Pkg's default: the clone lands in
    // Pkg.devdir() rather than in the environment.
    var shared = true;
    var names: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            depot_arg = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            jver_arg = args[i];
        } else if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return missingValue("--project");
            env_arg = args[i];
        } else if (std.mem.eql(u8, a, "--preserve")) {
            i += 1;
            if (i >= args.len) return missingValue("--preserve");
            tier = ajt.ops.resolve.Tier.parse(args[i]) orelse {
                try out.print("ajt: unknown preserve level '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--level")) {
            i += 1;
            if (i >= args.len) return missingValue("--level");
            level = ajt.ops.edit.Level.parse(args[i]) orelse {
                try out.print("ajt up: unknown level '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--major")) {
            level = .major;
        } else if (std.mem.eql(u8, a, "--minor")) {
            level = .minor;
        } else if (std.mem.eql(u8, a, "--patch")) {
            level = .patch;
        } else if (std.mem.eql(u8, a, "--fixed")) {
            level = .fixed;
        } else if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= args.len) return missingValue("--url");
            url_arg = args[i];
        } else if (std.mem.eql(u8, a, "--rev")) {
            i += 1;
            if (i >= args.len) return missingValue("--rev");
            rev_arg = args[i];
        } else if (std.mem.eql(u8, a, "--subdir")) {
            i += 1;
            if (i >= args.len) return missingValue("--subdir");
            subdir_arg = args[i];
        } else if (std.mem.eql(u8, a, "--shared")) {
            shared = true;
        } else if (std.mem.eql(u8, a, "--local")) {
            shared = false;
        } else if (std.mem.eql(u8, a, "--no-fixups")) {
            fixups = false;
        } else if (std.mem.eql(u8, a, "--no-precompile")) {
            precompile = .off;
        } else if (std.mem.eql(u8, a, "--precompile")) {
            precompile = .force;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (a.len > 0 and a[0] == '-') {
            try out.print("ajt: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try names.append(arena, a);
        }
    }

    // `--url` alone is a whole spec: the name comes from the checked-out
    // project file, and nothing may guess it from the URL.
    if (mode != .up and names.items.len == 0 and url_arg == null) {
        try out.print("ajt {t}: needs at least one package name\n", .{mode});
        return error.MissingArgument;
    }

    // The specs for the three verbs that have a grammar beyond a bare name.
    // `dev` parses differently from `add`/`pin`: it has no version token at
    // all, because a directory may legitimately contain an `@`.
    var specs: []ajt.ops.edit.Spec = &.{};
    if (mode == .add or mode == .pin or mode == .dev) {
        specs = try arena.alloc(ajt.ops.edit.Spec, names.items.len);
        for (names.items, specs) |text, *s| {
            s.* = if (mode == .dev)
                ajt.ops.edit.Spec.parseSource(text)
            else
                try ajt.ops.edit.Spec.parse(arena, text);
        }
        if (url_arg != null or rev_arg != null or subdir_arg != null) {
            if (specs.len > 1) {
                try out.print("ajt {t}: --url/--rev/--subdir describe ONE package\n", .{mode});
                return error.UnknownOption;
            }
            if (specs.len == 0) {
                specs = try arena.dupe(ajt.ops.edit.Spec, &.{.{ .name = "" }});
            }
            if (url_arg) |u| specs[0].url = u;
            if (rev_arg) |r| specs[0].rev = r;
            if (subdir_arg) |d| specs[0].subdir = d;
        }
    }

    const env_dir = env_arg orelse ".";
    const proj_path = try std.fs.path.join(arena, &.{ env_dir, "Project.toml" });
    const man_path = try std.fs.path.join(arena, &.{ env_dir, "Manifest.toml" });

    const prefix_resolved = prefix orelse findJuliaPrefix(arena, io, environ);
    const stack: ajt.depot.Stack = if (depot_arg) |d|
        .{ .entries = try arena.dupe([]const u8, &.{d}) }
    else
        try resolveDepotStack(arena, io, environ, @tagName(mode));

    // `JULIA_DEPOT_PATH=""` is a real, reachable configuration and it resolves
    // to an EMPTY stack (`initdefs.jl:95-131`), so this cannot index blindly.
    if (stack.entries.len == 0) {
        try out.print("ajt {t}: no depot to read the registry from — pass --depot\n", .{mode});
        return error.MissingArgument;
    }

    // The SAME lazy registry `instantiate` uses. With `Registry.none` the
    // install pass keeps only the Pkg-server URL for each package and loses
    // the GitHub tarball fallback, which on a cold depot meant `add` reported
    // results and installed nothing at all.
    var edit_registry: LazyRegistry = .{
        .gpa = arena,
        .arena = arena,
        .io = io,
        .depot = depot_arg orelse stack.entries[0],
        .name = "General",
        .source = .auto,
    };
    defer edit_registry.deinit(io);

    // As in `cmdResolve`: constructed unconditionally, and no subprocess runs
    // until a `[sources]` url actually needs one.
    var git_state: GitBackend = .{};
    defer git_state.deinit();
    // `arena` where the other call sites pass a `gpa`: `cmdEdit` has none, and
    // the scratch libgit2's wrappers take is per-call and small, so it costs an
    // arena that already lives exactly as long as this command.
    const git_backend = try git_state.open(arena, arena, io, environ, environ);

    var diag: ajt.ops.resolve.Diagnostic = .{};
    var opts: ajt.ops.edit.Options = .{
        .project_file = proj_path,
        .manifest_file = man_path,
        .registry_depot = depot_arg orelse stack.entries[0],
        .julia_prefix = prefix_resolved,
        .julia_version = if (jver_arg) |t| try ajt.julia.version.parse(arena, t) else null,
        .depots = stack,
        .fixups = fixups,
        .dry_run = dry_run,
        .offline = offline_flag,
        .registry = edit_registry.seam(),
        .git = git_backend,
        .diagnostic = &diag,
        .precompile = precompile,
        // The children inherit everything the parent has -- PATH, HOME,
        // JULIA_CPU_TARGET -- and this is also where
        // JULIA_PKG_PRECOMPILE_AUTO is read from.
        .environ = environ,
        .precompile_cache_url = cacheUrlFromEnv(environ),
        // `Pkg.devdir()` (`Types.jl:762-766`). Null lets `edit.zig` derive
        // `<depots1>/dev` from the depot stack it already has.
        .devdir = environ.get("JULIA_PKG_DEVDIR"),
        .shared = shared,
    };
    if (tier) |t| opts.tier = t;

    // The git backend is built only when something asks for a clone: it costs
    // a `git --version` child, and every registry `add` would otherwise pay it.
    //
    // `pin` shares `add`'s grammar but has no repository arm — it refuses such
    // a spec — so demanding git for `pin Foo#main` would report the wrong
    // problem on a machine that has no git and never needed it.
    var any_repo = false;
    if (mode == .add or mode == .dev) {
        for (specs) |s| {
            if (s.isRepo()) any_repo = true;
        }
    }
    if (any_repo) {
        // Re-opened rather than reused: a clone runs `git` children, and those
        // want `gitEnviron`'s narrowing, which the unconditional one above
        // deliberately does not do. The selection is the same either way.
        opts.git = try git_state.open(arena, arena, io, environ, try gitEnviron(arena, environ));
        if (git_state.which == .cli and !ajt.git.cli.available(arena, io, git_state.cli.program)) {
            try out.writeAll("ajt: no usable `git` on PATH, and a repository was named\n");
            try out.flush();
            std.process.exit(1);
        }
    }

    const rep = switch (mode) {
        .add => ajt.ops.edit.add(arena, io, opts, specs),
        .rm => ajt.ops.edit.rm(arena, io, opts, names.items),
        .up => ajt.ops.edit.up(arena, io, opts, names.items, level),
        .pin => ajt.ops.edit.pin(arena, io, opts, specs),
        .free => ajt.ops.edit.free(arena, io, opts, names.items),
        .dev => ajt.ops.edit.dev(arena, io, opts, specs),
    } catch |e| {
        switch (e) {
            // A `[sources]` url that could not be resolved left its sentence
            // on the diagnostic. Same contract as `cmdResolve`: relay it
            // instead of dumping a stack trace through the git backend.
            //
            // Only the failures with no better message of their own are here.
            // `RevNotFound`, `SubdirNotFound`, `SshUnsupported`, `CloneFailed`
            // and `FetchFailed` have dedicated arms below that name the rev,
            // the subdirectory, or the two ways out of an ssh URL — strictly
            // more useful than the generic relay, so they win.
            error.TransportHelperUnsupported,
            error.TreeHashMismatch,
            error.SourceProjectMismatch,
            => {
                try out.print("{t}\tfailed\n", .{mode});
                if (diag.report) |r| try out.writeAll(r) else try out.print("{s}\n", .{@errorName(e)});
                try out.flush();
                std.process.exit(1);
            },
            // Same contract as `resolve`: an unsatisfiable environment is a
            // diagnosis, not a crash.
            error.NoSolution, error.SingletonConflict => {
                try out.print("{t}\tfailed\n", .{mode});
                if (diag.report) |r| try out.writeAll(r);
                if (diag.blamed.len != 0) {
                    try out.writeAll("to fix, try relaxing [compat] on:");
                    for (diag.blamed) |n| try out.print(" {s}", .{n});
                    try out.writeAll("\n");
                }
                try out.flush();
                std.process.exit(1);
            },
            error.NotRegistered => {
                try out.writeAll("ajt add: no registered package by that name\n");
                try out.flush();
                std.process.exit(1);
            },
            error.AmbiguousName => {
                try out.writeAll("ajt add: that name belongs to more than one registered package; pass a UUID\n");
                try out.flush();
                std.process.exit(1);
            },
            error.NotADependency => {
                try out.print("ajt {t}: not a direct dependency of this project\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            // `pin`/`free` name a MANIFEST entry, so "not a dependency" is the
            // wrong diagnosis for them: a transitive dependency is pinnable and
            // is not in `[deps]` at all.
            error.NotInManifest => {
                try out.print("ajt {t}: not in Manifest.toml — run `ajt resolve --write` and retry\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.NotFreeable => {
                try out.writeAll("ajt free: expected the package to be pinned, or to track a path or a repository\n");
                try out.flush();
                std.process.exit(1);
            },
            error.FreeUnregistered => {
                try out.writeAll("ajt free: no registry carries this package, so there is nothing to free it to\n");
                try out.flush();
                std.process.exit(1);
            },
            error.PinNeedsExactVersion => {
                // `Foo@1.2` is a RANGE in the project grammar, so this is the
                // likely mistake and worth spelling out rather than restating
                // the rule.
                try out.writeAll("ajt pin: a pin needs one exact version, e.g. Foo@1.2.3 — `Foo@1.2` is the range [1.2.0, 2)\n");
                try out.flush();
                std.process.exit(1);
            },
            error.DevPathMissing => {
                try out.writeAll("ajt dev: no such directory\n");
                try out.flush();
                std.process.exit(1);
            },
            error.DevPathNotAPackage => {
                try out.writeAll("ajt dev: that directory has no Project.toml naming a package (name + uuid)\n");
                try out.flush();
                std.process.exit(1);
            },
            // Refused before any backend saw it, so the message is the one
            // `git/git.zig` wrote for exactly this: it names both ways out
            // (the https form, or Pkg's own JULIA_PKG_USE_CLI_GIT), which
            // libgit2's "Unsupported URL protocol" does not.
            error.SshUnsupported => {
                try out.print("ajt {t}: {s}\n", .{ mode, ajt.git.core.ssh_unsupported_message });
                try out.flush();
                std.process.exit(1);
            },
            error.GitUnavailable => {
                try out.print("ajt {t}: a repository was named but no git backend is available\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.VersionWithRev => {
                // Pkg refuses the same combination up front (`API.jl:313-320`).
                try out.print("ajt {t}: a version cannot be given alongside a rev — the rev decides the version\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.RepoPathUnsupported => {
                try out.print("ajt {t}: --url takes a URL; adding a local git repository by path is not implemented\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.NoRepoSource => {
                try out.print("ajt {t}: no repository to clone — neither Manifest.toml nor the registry records one for that package\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            // "Did not find rev $rev in repository" (`Types.jl:1009`), after
            // fetching the branches and then everything. The rev is named only
            // when there is one to name: with several repo specs in one call
            // the error does not say which failed, and printing every rev
            // would accuse the ones that resolved.
            error.RevNotFound => {
                try out.print("ajt {t}: did not find rev{s} in the repository\n", .{
                    mode,
                    if (soleRev(specs)) |r|
                        (std.fmt.allocPrint(arena, " `{s}`", .{r}) catch "")
                    else
                        "",
                });
                try out.flush();
                std.process.exit(1);
            },
            error.SubdirNotFound => {
                try out.print("ajt {t}: did not find subdirectory{s} in the repository\n", .{
                    mode,
                    if (soleSubdir(specs)) |d|
                        (std.fmt.allocPrint(arena, " `{s}`", .{d}) catch "")
                    else
                        "",
                });
                try out.flush();
                std.process.exit(1);
            },
            error.DevRevUnsupported => {
                // Pkg's own words (`API.jl:260-262`).
                try out.writeAll("ajt dev: rev argument not supported by `develop`; consider using `add` instead\n");
                try out.flush();
                std.process.exit(1);
            },
            error.RepoSpecNotAllowed => {
                try out.print("ajt {t}: names a package, not a repository — `#rev`, --url and --subdir belong to `add`\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.RepoNotAPackage => {
                try out.print("ajt {t}: that tree has no Project.toml naming a package — maybe --subdir is needed\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            error.CloneFailed, error.FetchFailed => {
                try out.print("ajt {t}: git could not clone or fetch that repository\n", .{mode});
                try out.flush();
                std.process.exit(1);
            },
            else => return e,
        }
    };

    var uuid_buf: [36]u8 = undefined;
    for (rep.changes) |c| {
        try out.print("{t}\t{s}\t{s}\n", .{
            c.kind,
            c.name,
            ajt.model.manifest.formatUuid(c.uuid, &uuid_buf),
        });
    }
    if (rep.installed) |n| try out.print("installed\t{d}\n", .{n});
    if (rep.failed_installs != 0) {
        try out.print("install-failed\t{d}\n", .{rep.failed_installs});
    }
    if (rep.manifest_entries) |n| {
        try out.print("manifest\t{s}\t{d}\t{s}\n", .{
            man_path,
            n,
            if (rep.manifest_written) "written" else "unchanged",
        });
    }
    if (rep.resolve) |r| {
        if (!quiet) {
            for (r.selections) |s| {
                if (s.was) |w| {
                    if (!ajt.julia.version.Version.eql(w, s.version)) {
                        try out.print("changed\t{s}\t{f}\t{f}\n", .{ s.name, w, s.version });
                    }
                } else if (!s.in_manifest) {
                    try out.print("added\t{s}\t{f}\n", .{ s.name, s.version });
                }
            }
        }
        for (r.fixups_missing_source) |n| try out.print("no-source\t{s}\n", .{n});
        if (r.selections.len != 0) {
            try out.print("summary\t{d}\t{d}\t{d}\t{d}\t{d:.0}\t{t}\n", .{
                r.selections.len, r.changed, r.unversioned, r.added, r.elapsed_ms, r.tier_used,
            });
        }
    }
    try out.print("project\t{s}\t{s}\n", .{
        proj_path,
        if (rep.project_written) "written" else "unchanged",
    });

    // One line, not `ajt precompile`'s whole per-package report: `add` already
    // prints a resolve and an install, and 200 more rows would bury them. The
    // counts are the same ones `precompile`'s summary carries, so a script that
    // wants detail runs the command that is about this.
    if (rep.precompile) |p| {
        try printPrecompile(out, @tagName(mode), p);
    } else if (rep.precompile_skipped) |why| {
        try out.print("precompile\tskipped\t{t}\n", .{why});
    }
    try out.flush();
    // A package that will not compile is what `Pkg.add` raises on -- its
    // `_auto_precompile` is the last statement of `Operations.add`, and
    // `Pkg.precompile` throws on a non-empty `failed_deps`. The two files are
    // already written either way, which is also what Pkg leaves behind.
    if (!rep.precompileOk()) std.process.exit(1);
}

/// `ajt why` — the dependency paths that explain a manifest entry.
fn cmdWhy(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    var env_arg: ?[]const u8 = null;
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return missingValue("--project");
            env_arg = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            try out.print("ajt why: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try names.append(arena, a);
        }
    }
    if (names.items.len == 0) {
        try out.writeAll("ajt why: needs at least one package name\n");
        return error.MissingArgument;
    }

    const env_dir = env_arg orelse ".";
    const opts: ajt.ops.why.Options = .{
        .project_file = try std.fs.path.join(arena, &.{ env_dir, "Project.toml" }),
        .manifest_file = try std.fs.path.join(arena, &.{ env_dir, "Manifest.toml" }),
    };

    for (names.items, 0..) |name, n| {
        if (n != 0) try out.writeAll("\n");
        const paths = ajt.ops.why.run(arena, io, opts, name) catch |e| switch (e) {
            error.NotInManifest => {
                try out.print("ajt why: {s} is not in this manifest\n", .{name});
                try out.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        // Two-space indent and " → " between names — byte-for-byte what
        // `Pkg.why` writes to a non-terminal sink. Pkg wraps the same U+2192
        // in colour escapes when the sink is a TTY (`API.jl:1606`), so a piped
        // Pkg and a piped Ajt produce identical bytes and the gate can just
        // `cmp` them.
        for (paths) |p| {
            try out.writeAll("  ");
            for (p.names, 0..) |nm, j| {
                if (j != 0) try out.writeAll(" \u{2192} ");
                try out.writeAll(nm);
            }
            try out.writeAll("\n");
        }
    }
}

const precompile_ops = ajt.ops.precompile;

/// `ajt precompile` — the command a frontier scheduler will drive, and the one
/// the shared cache measures against.
///
/// It reports rather than raises: one package whose `__init__` throws is a
/// `failed` line and a non-zero exit, not a lost report for the other 213.
fn cmdPrecompile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var julia_bindir: ?[]const u8 = null;
    var env_path: ?[]const u8 = null;
    var quiet = false;
    var cache_url: ?[]const u8 = null;
    var cache_given = false;
    var cache_token: ?[]const u8 = null;
    var cache_token_given = false;
    var only_names: std.ArrayList([]const u8) = .empty;
    defer only_names.deinit(gpa);
    var opts: precompile_ops.Options = .{ .env_path = ".", .stack = .{ .entries = &.{} } };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--julia")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia");
            opts.julia_exe = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-bindir")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-bindir");
            julia_bindir = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--jobs")) {
            i += 1;
            if (i >= args.len) return missingValue("--jobs");
            opts.jobs = std.fmt.parseInt(u32, args[i], 10) catch {
                try out.print("ajt precompile: --jobs wants a number, got '{s}'\n", .{args[i]});
                return error.UnknownOption;
            };
        } else if (std.mem.eql(u8, a, "--cache-url")) {
            i += 1;
            if (i >= args.len) return missingValue("--cache-url");
            cache_url = args[i];
            cache_given = true;
        } else if (std.mem.eql(u8, a, "--no-cache")) {
            // Distinct from `--cache-url ""`, which is how you say "no store"
            // to something that reads the value: this says "ignore whatever the
            // environment set", which is what a developer wants when the shared
            // cache is suspected of serving something wrong.
            cache_url = null;
            cache_given = true;
        } else if (std.mem.eql(u8, a, "--cache-token")) {
            i += 1;
            if (i >= args.len) return missingValue("--cache-token");
            cache_token = args[i];
            cache_token_given = true;
        } else if (std.mem.eql(u8, a, "--only")) {
            i += 1;
            if (i >= args.len) return missingValue("--only");
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |name| {
                if (name.len != 0) try only_names.append(gpa, name);
            }
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt precompile: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (env_path == null) {
            env_path = a;
        } else {
            std.debug.print("ajt precompile: one environment at a time\n", .{});
            return error.UnknownOption;
        }
    }
    opts.env_path = env_path orelse ".";
    if (only_names.items.len != 0) opts.only = only_names.items;

    // The flag wins; otherwise the environment, in the shape `JULIA_PKG_SERVER`
    // already established. Unset means no shared cache and no network, which is
    // what `Pkg.precompile()` does and what anyone who has not deployed a store
    // should get without reading anything.
    if (!cache_given) cache_url = environ.get("AJT_CACHE_URL");
    if (cache_url) |u| {
        if (u.len != 0) opts.cache_url = u;
    }
    // The token is the write credential and nothing else: `Store.putTo`
    // attaches it as `Authorization: Bearer <token>` on PUT and lookups never
    // send it (cache/store.zig). It rides only on THIS command — the
    // auto-precompile paths (`instantiate`, `add`, `up`, …) stay read-only by
    // construction, so they take no token and cannot publish by accident.
    // Same empty-means-unset rule as the URL, so `AJT_CACHE_TOKEN=` in an
    // environment file is "no credential", not a credential of length zero.
    if (!cache_token_given) cache_token = environ.get("AJT_CACHE_TOKEN");
    if (cache_token) |t| {
        if (t.len != 0) opts.cache_token = t;
    }
    // The rule itself lives in `ops/precompile.zig`, not here: the store's
    // HTTP clients are built inside that module from a Config this layer never
    // sees, so nulling `cache_url` at the CLI would leave a library caller
    // online with `JULIA_PKG_OFFLINE=1` set.
    opts.offline = offline_flag;

    // A run that fails partway is exactly when the per-package detail is worth
    // most, and the records sit in a 64 KiB buffer until something flushes it.
    defer out.flush() catch {};

    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);
    // The SAME Julia decides the depot stack and runs the children: an empty
    // `JULIA_DEPOT_PATH` entry expands to that Julia's bundled depots, and a
    // stack expanded for one Julia while another compiles is a cache written
    // where nothing will look for it.
    const bindir = julia_bindir orelse if (opts.julia_prefix) |p|
        try fspath.join(arena, &.{ p, "bin" })
    else
        null;
    opts.stack = try resolveStack(arena, io, environ, depots.items, bindir);
    if (opts.stack.entries.len == 0) {
        std.debug.print("ajt precompile: DEPOT_PATH is empty, nowhere to write a cache\n", .{});
        return error.MissingArgument;
    }
    // The children inherit everything except the two variables the module
    // pins — PATH, HOME, and JULIA_CPU_TARGET, which is mixed into the cache
    // filename (`loading.jl:3164-3169`) and must match whatever else built
    // this depot.
    opts.environ = environ;

    const t0 = Io.Clock.awake.now(io);
    const rep = try precompile_ops.run(gpa, arena, io, opts);
    const elapsed = msSince(io, t0);

    if (rep.blocked) |p| {
        try out.print("blocked\t{f}\n", .{p});
        std.debug.print("ajt precompile: {f}\n", .{p});
        try out.flush();
        std.process.exit(1);
    }

    if (!quiet) {
        try out.print("julia\t{s}\t{s}\n", .{ rep.julia, rep.compiled_dir });
        if (rep.params) |p| {
            // The three that decide whether another machine's cache entries
            // mean anything here. `julia_bin` and the active project are read
            // too, but they only move the local filename and both are already
            // on the `julia` and `project` lines.
            try out.print("params\t{s}\t{d}\t{s}\n", .{ p.image_file, p.cacheflags, p.cpu_target });
        }
        for (rep.packages) |r| {
            var uuid_buf: [36]u8 = undefined;
            // Extensions get their own record kind rather than a `package` row
            // with a decorated name. Two reasons: a `package` row stays exactly
            // what it has always been, so nothing parsing this output breaks,
            // and the parent gets a field of its own — two parents can declare
            // extensions with the same name, so the name alone does not
            // identify the row.
            if (r.ext_parent.len != 0) {
                try out.print("extension\t{t}\t{s}\t{s}\t{s}\t{d:.0}\t{s}\n", .{
                    r.outcome,
                    r.ext_parent,
                    r.name,
                    ajt.model.manifest.formatUuid(r.uuid, &uuid_buf),
                    r.ms,
                    if (r.source.len == 0) "-" else r.source,
                });
                continue;
            }
            try out.print("package\t{t}\t{s}\t{s}\t{d:.0}\t{s}\n", .{
                r.outcome,
                r.name,
                ajt.model.manifest.formatUuid(r.uuid, &uuid_buf),
                r.ms,
                if (r.source.len == 0) "-" else r.source,
            });
        }
    }
    if (rep.extensions != 0 or rep.extensions_dormant != 0) {
        try out.print("extensions\t{d}\t{d}\n", .{ rep.extensions, rep.extensions_dormant });
    }
    if (rep.cache_stats) |c| {
        try out.print("cache\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            c.hits, c.misses, c.imported, c.published, c.errors,
        });
    }
    // The shared-cache address of each package, and where it would land here.
    // Printed under --dry-run only: it is what "what would this run do" means
    // once a cache exists, and 190 extra lines on every real run would drown
    // the outcomes.
    // `keys` is empty when none could be computed, so the lengths only line up
    // on the success path — a `for` over both would panic rather than print.
    if (opts.dry_run and !quiet and rep.keys.len == rep.packages.len) {
        for (rep.keys, rep.packages) |k, r| {
            if (k.hex.len == 0) continue;
            try out.print("key\t{s}\t{s}\t{s}\n", .{ r.name, k.hex, if (k.path.len == 0) "-" else k.path });
        }
    }
    if (rep.key_error) |e| {
        std.debug.print("ajt precompile: no cache keys ({s}); the shared cache is inactive for this run\n", .{e});
    }

    // `source_missing` is NOT here: Pkg puts it in `failed_deps`, so it counts
    // against the run rather than as a package that was legitimately skipped.
    const skipped = rep.countOf(.in_sysimage) + rep.countOf(.not_precompilable) +
        rep.countOf(.circular);
    try out.print("summary\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\n", .{
        rep.considered,
        rep.compiledCount(),
        rep.countOf(.already_precompiled),
        rep.countOf(.stale),
        skipped,
        rep.failedCount(),
        elapsed,
    });

    // --- diagnostics, on stderr ---------------------------------------------
    if (rep.probe_error) |e| {
        std.debug.print(
            "ajt precompile: could not ask julia what needs compiling ({s}); nothing was compiled\n",
            .{e},
        );
    }
    for (rep.packages) |r| {
        switch (r.outcome) {
            .failed, .unknown => std.debug.print("ajt precompile: {s} failed{s}: {s}\n", .{
                r.name,
                if (r.exit_code) |c|
                    (std.fmt.allocPrint(arena, " (exit {d})", .{c}) catch "")
                else
                    "",
                r.detail,
            }),
            .source_missing => std.debug.print(
                "ajt precompile: {s} has no source on disk; run `ajt instantiate --frozen` first\n",
                .{r.name},
            ),
            .circular => std.debug.print(
                "ajt precompile: {s} is in (or downstream of) a dependency cycle; Pkg skips these too\n",
                .{r.name},
            ),
            // Under --dry-run this IS the answer. Anywhere else it means the
            // compile pass was handed a package and did not run it.
            .stale => if (!opts.dry_run) std.debug.print(
                "ajt precompile: {s} was planned but never compiled -- this is a bug in ajt\n",
                .{r.name},
            ),
            else => {},
        }
    }

    try out.flush();
    if (!rep.ok()) std.process.exit(1);
}

/// `ajt manifest current [env]` / `ajt manifest upgrade <env|Manifest.toml>` —
/// the two Pkg verbs that are about the manifest FILE and never about the depot
/// (`Pkg.is_manifest_current`, `Pkg.upgrade_manifest`).
///
/// Grouped under one command because they share every option and read the same
/// two files, and because a top-level `current` would be a verb whose object
/// nobody could guess.
///
/// Like `cmdVerify`, the answer is delivered with `std.process.exit` rather
/// than by returning an error: a returned error prints `error: SomeName` and a
/// stack trace over the record that actually carries the answer.
///
/// That applies to BAD INVOCATIONS too, which is not obvious and is the reason
/// `manifestUsage` exists. Zig's start code turns any error returned from
/// `main` into exit status **1**, and for `manifest current` 1 is a load-bearing
/// answer — `false`, "your manifest is stale". A caller writing
/// `ajt manifest current "$env"; case $? in 1) resolve;; esac` would resolve an
/// environment because it mistyped a flag. Every path here that does not
/// produce an answer therefore exits `no_answer` (3) instead, `--help`
/// included: 0 means `true` and nothing else may claim it.
const manifest_no_answer = 3;

fn cmdManifest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    // `upgrade` has no answer-valued exit status, so its failures stay on the
    // ordinary 1. Decided before the subcommand is known so a bare
    // `ajt manifest` — which could have meant either — takes the safe one.
    var code: u8 = manifest_no_answer;

    if (args.len == 0) return manifestUsage(out, code, "expected `current` or `upgrade`");
    const sub = args[0];
    const is_current = std.mem.eql(u8, sub, "current");
    if (!is_current and !std.mem.eql(u8, sub, "upgrade")) {
        if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
            return manifestUsage(out, code, "");
        }
        return manifestUsage(out, code, try std.fmt.allocPrint(arena, "unknown subcommand '{s}'", .{sub}));
    }
    if (!is_current) code = 1;

    var path: ?[]const u8 = null;
    var manifest_file: ?[]const u8 = null;
    var julia_prefix: ?[]const u8 = null;
    var julia_version: ?[]const u8 = null;
    var dry_run = false;
    var quiet = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--manifest")) {
            // Deliberately `current`-only. `upgrade` REWRITES the file it
            // resolves, and silently ignoring an option that names which file
            // that is would be the worst way to be wrong here; Pkg's
            // `upgrade_manifest` has no such override either — its positional
            // argument already names the file.
            if (!is_current) return manifestUsage(out, code, "--manifest is a `current` option; `upgrade` takes the file as its argument");
            i += 1;
            if (i >= args.len) return manifestUsage(out, code, "--manifest needs a value");
            manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return manifestUsage(out, code, "--julia-prefix needs a value");
            julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return manifestUsage(out, code, "--julia-version needs a value");
            julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            if (is_current) return manifestUsage(out, code, "--dry-run is an `upgrade` option; `current` never writes");
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return manifestUsage(out, code, "");
        } else if (std.mem.startsWith(u8, a, "-")) {
            return manifestUsage(out, code, try std.fmt.allocPrint(arena, "unknown option '{s}'", .{a}));
        } else if (path == null) {
            path = a;
        } else {
            return manifestUsage(out, code, "one path at a time");
        }
    }

    const mops = ajt.ops.manifest_ops;
    var diag: mops.Diagnostic = .{};

    if (is_current) {
        const answer = mops.isCurrent(arena, gpa, io, .{
            .env_path = path orelse ".",
            .manifest_file = manifest_file,
            .julia_prefix = julia_prefix,
            .julia_version = julia_version,
        }, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                // Exit 3, never 2: "I could not read the project" and "the
                // manifest records no hash" are different answers, and Julia
                // raises for the first while returning `nothing` for the
                // second. Collapsing them would make a broken environment
                // indistinguishable from an old but healthy one.
                if (!quiet) try out.print("manifest_current\terror\t{s}\t{s}\n", .{ diag.file, diag.message });
                try out.flush();
                std.process.exit(3);
            },
        };
        if (!quiet) {
            try out.print("manifest_current\t{s}\t{s}\t{s}\t{s}\n", .{
                switch (answer.currency) {
                    .current => "true",
                    .stale => "false",
                    .unknown => "nothing",
                },
                answer.manifest_file,
                if (answer.recorded.len != 0) answer.recorded else "-",
                if (answer.computed.len != 0) answer.computed else "-",
            });
        }
        try out.flush();
        // See `manifest options` in the usage text for why these three values.
        std.process.exit(switch (answer.currency) {
            .current => 0,
            .stale => 1,
            .unknown => 2,
        });
    }

    const target = path orelse
        return manifestUsage(out, code, "expected an environment or a Manifest.toml");
    const up = mops.upgrade(gpa, arena, io, .{
        .path = target,
        .dry_run = dry_run,
        .julia_prefix = julia_prefix,
        .julia_version = julia_version,
    }, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            // Pkg's own sentence for the two refusals, verbatim, because a
            // caller matching on Pkg's message has to keep working. On stdout
            // with everything else this command says -- see `_failed` in
            // julia/src/Ajt.jl.
            //
            // Those two already name the file; the parse/IO diagnostics do not,
            // and a bare "line 1, column 6: expected '='" with no file is a
            // message nobody can act on.
            if (!quiet) {
                if (diag.file.len != 0 and std.mem.indexOf(u8, diag.message, diag.file) == null) {
                    try out.print("{s}: {s}\n", .{ diag.file, diag.message });
                } else {
                    try out.print("{s}\n", .{diag.message});
                }
            }
            try out.flush();
            std.process.exit(1);
        },
    };
    if (!quiet) {
        try out.print("manifest\t{s}\t{s}\t{f}\t{f}\t{d}\n", .{
            if (up.written) "upgraded" else if (dry_run) "would_upgrade" else "unchanged",
            up.manifest_file,
            up.from,
            up.to,
            up.entries,
        });
    }
    try out.flush();
}

/// A bad `ajt manifest` invocation: the usage text, the complaint, and an exit
/// status that is NOT one of the answers. See `manifest_no_answer`.
///
/// The complaint goes to stderr and the usage to stdout, so a caller that
/// captures stdout for the record still sees why it got nothing.
fn manifestUsage(out: *Io.Writer, code: u8, complaint: []const u8) error{WriteFailed}!void {
    if (complaint.len != 0) std.debug.print("ajt manifest: {s}\n", .{complaint});
    try out.writeAll(usage);
    try out.flush();
    std.process.exit(code);
}

/// `ajt generate <path>` — `Pkg.generate`, which writes exactly two files.
///
/// Reports in the same tab-separated shape every other subcommand uses, rather
/// than forging Pkg's `Generating project …:` block here: `Ajt.jl` renders it
/// back into Pkg's exact three lines through the same `_hdr`/`contractuser` it
/// already has, and a shell caller gets the uuid without parsing TOML.
fn cmdGenerate(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 0 and a[0] == '-') {
            try out.print("ajt generate: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (path == null) {
            path = a;
        } else {
            try out.writeAll("ajt generate: takes exactly one path\n");
            return error.UnknownOption;
        }
    }
    const target = path orelse {
        try out.writeAll("ajt generate: needs a path\n");
        return error.MissingArgument;
    };

    const rep = ajt.ops.generate.run(arena, io, .{
        .path = target,
        .identity = .{ .probe = environ },
    }) catch |e| {
        const base = ajt.ops.generate.juliaBasename(target);
        const detail = switch (e) {
            error.InvalidPackageName => try std.fmt.allocPrint(
                arena,
                "\"{s}\" is not a valid package name",
                .{base},
            ),
            error.NonAsciiPackageName => try std.fmt.allocPrint(
                arena,
                "\"{s}\" is not ASCII; whether it is a valid package name needs Julia's " ++
                    "Unicode identifier tables, so this case is left to Pkg",
                .{base},
            ),
            error.AlreadyExists => try std.fmt.allocPrint(
                arena,
                "{s} already exists",
                .{try absPath(arena, io, target)},
            ),
            else => return e,
        };
        try out.print("ajt generate: {s}\n", .{detail});
        try out.flush();
        std.process.exit(1);
    };

    var uuid_buf: [36]u8 = undefined;
    try out.print("generated\t{s}\t{s}\n", .{ rep.pkg, formatUuid(&uuid_buf, rep.uuid) });
    // In the order `genfile` writes them, which is the order Pkg prints them.
    try out.print("file\t{s}\n", .{rep.project_file});
    try out.print("file\t{s}\n", .{rep.entry_file});
}

/// `Base.abspath` = `normpath(joinpath(pwd(), path))` — lexical, and
/// deliberately NOT `realpath`, so a symlinked directory is reported by the
/// name the user typed. Same primitive as `ops/usage.zig`'s private `absPath`;
/// when a third caller appears the two should be hoisted together.
fn absPath(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (fspath.isAbsolute(path)) return fspath.resolve(arena, &.{path});
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return path;
    return fspath.resolve(arena, &.{ buf[0..n], path });
}

/// `string(::UUID)` — canonical 8-4-4-4-12, lowercase.
fn formatUuid(buf: *[36]u8, u: ajt.julia.Uuid) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (u.bytes, 0..) |b, bi| {
        if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex[b >> 4];
        buf[i + 1] = hex[b & 0xf];
        i += 2;
    }
    return buf[0..36];
}

/// `ajt compat <Name> [spec]` — `Pkg.compat(name, spec)`.
///
/// The compliance resolve is the interesting half: a resolver error is REPORTED
/// and the exit status stays 0, because the bound has already been written and
/// `update` is the command that acts on it (`API.jl:1532-1543`). Any other
/// failure propagates.
fn cmdCompat(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var env_arg: ?[]const u8 = null;
    var depot_arg: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var jver_arg: ?[]const u8 = null;
    var name_arg: ?[]const u8 = null;
    var spec_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return missingValue("--project");
            env_arg = args[i];
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            depot_arg = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            jver_arg = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            try out.print("ajt compat: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else if (name_arg == null) {
            name_arg = a;
        } else if (spec_arg == null) {
            spec_arg = a;
        } else {
            try out.writeAll("ajt compat: takes a package name and an optional version spec\n");
            return error.UnknownOption;
        }
    }

    const name = name_arg orelse {
        // Pkg's zero-argument form is the interactive editor, which is Pkg's
        // and stays Pkg's — see ops/compat.zig's header.
        try out.writeAll("ajt compat: takes a package name and an optional version spec\n");
        return error.MissingArgument;
    };

    const env_dir = env_arg orelse ".";
    const proj_path = try std.fs.path.join(arena, &.{ env_dir, "Project.toml" });
    const man_path = try std.fs.path.join(arena, &.{ env_dir, "Manifest.toml" });

    const stack: ajt.depot.Stack = if (depot_arg) |d|
        .{ .entries = try arena.dupe([]const u8, &.{d}) }
    else
        try resolveDepotStack(arena, io, environ, "compat");

    var diag: ajt.ops.resolve.Diagnostic = .{};
    var refusal: ?[]const u8 = null;
    const rep = ajt.ops.compat.run(arena, io, .{
        .project_file = proj_path,
        .manifest_file = man_path,
        // `JULIA_DEPOT_PATH=""` resolves to an EMPTY stack, which is a real
        // configuration: there is then no registry to check compliance
        // against, and `writeDepot` is the one place that rule lives.
        .resolve = if (stack.writeDepot()) |d| .{ .compliance = d.root } else .skip,
        .julia_prefix = prefix orelse findJuliaPrefix(arena, io, environ),
        .julia_version = if (jver_arg) |t| try ajt.julia.version.parse(arena, t) else null,
        .depots = stack,
        .diagnostic = &diag,
        .refusal = &refusal,
    }, name, spec_arg) catch |e| switch (e) {
        // Pkg's own wording, filled in by ops/compat.zig so that the gate and
        // the user read the same string.
        error.NoProject, error.NotADependency, error.InvalidSpec => {
            try out.print("ajt compat: {s}\n", .{refusal orelse "refused"});
            try out.flush();
            std.process.exit(1);
        },
        else => return e,
    };

    if (rep.spec) |s| {
        try out.print("compat\tset\t{s}\t{s}\n", .{ rep.name, s });
    } else {
        try out.print("compat\tremoved\t{s}\t{s}\n", .{ rep.name, rep.existing orelse "-" });
    }
    try out.print("project\t{s}\t{s}\n", .{
        proj_path,
        if (rep.project_written) "written" else "unchanged",
    });
    if (rep.resolve_failed) {
        // Reported, and the exit status stays 0: the bound is recorded and
        // `update` is what acts on it (`API.jl:1537-1539`).
        try out.writeAll("resolve\tfailed\n");
        if (diag.report) |r| try out.writeAll(r);
        if (diag.blamed.len != 0) {
            try out.writeAll("to fix, try relaxing [compat] on:");
            for (diag.blamed) |blame| try out.print(" {s}", .{blame});
            try out.writeAll("\n");
        }
        try out.writeAll("suggestion\tCall `update` to attempt to meet the compatibility requirements.\n");
    } else if (rep.resolve) |r| {
        try out.print("manifest\t{s}\t{d}\t{s}\n", .{
            man_path,
            if (r.manifest) |m| m.entries.len else 0,
            if (r.manifest_written) "written" else "unchanged",
        });
    } else {
        // No depot, so no compliance check ran. Saying so in the report is the
        // difference between "the environment complies" and "nobody looked".
        try out.writeAll("resolve\tskipped\tno depot to read a registry from\n");
    }
}

/// The one rev in a batch, or null when there are none or several. Used only
/// to decide whether an error message can name the rev it means.
fn soleRev(specs: []const ajt.ops.edit.Spec) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (specs) |s| {
        const r = s.rev orelse continue;
        if (found != null) return null;
        found = r;
    }
    return found;
}

fn soleSubdir(specs: []const ajt.ops.edit.Spec) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (specs) |s| {
        const d = s.subdir orelse continue;
        if (found != null) return null;
        found = d;
    }
    return found;
}

/// The environment `git` children run with.
///
/// **Inherited, then narrowed** — the opposite of a hermetic environment, and
/// deliberately so. `git/cli.zig`'s header says why: this backend exists
/// because somebody's libgit2 does not work for them, and the reasons
/// (`insteadOf` rules, credential helpers, a corporate CA bundle) all live in
/// the environment and in `~/.gitconfig`. `GIT_CONFIG_NOSYSTEM` is likewise
/// NOT set.
///
/// What is narrowed is the one failure mode a package manager may not have: a
/// child blocking on a TTY read in the middle of an `add`.
/// `GIT_TERMINAL_PROMPT=0` turns the username/password prompt into an error,
/// and the two askpass hooks are removed so nothing pops a dialog either.
fn gitEnviron(
    arena: std.mem.Allocator,
    parent: *std.process.Environ.Map,
) !*std.process.Environ.Map {
    const map = try arena.create(std.process.Environ.Map);
    map.* = .init(arena);
    for (parent.keys(), parent.values()) |k, v| try map.put(k, v);
    try map.put("GIT_TERMINAL_PROMPT", "0");
    _ = map.orderedRemove("GIT_ASKPASS");
    _ = map.orderedRemove("SSH_ASKPASS");
    return map;
}

const build_ops = ajt.ops.build;

/// `ajt build` — `deps/build.jl` for every package that has one, in dependency
/// order, each inside its own sandbox environment.
///
/// The first failure ABORTS and exits non-zero, which is what `Pkg.build` does
/// (`Operations.jl:1490-1504`) and is not the shape `ajt precompile` has: a
/// build script frequently produces a file the next package's build script
/// consumes, so continuing would print a cascade of consequences instead of the
/// cause.
fn cmdBuild(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var julia_bindir: ?[]const u8 = null;
    var opts: build_ops.Options = .{ .env_path = ".", .stack = .{ .entries = &.{} } };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return missingValue("--project");
            opts.env_path = args[i];
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--julia")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia");
            opts.julia_exe = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-bindir")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-bindir");
            julia_bindir = args[i];
        } else if (std.mem.eql(u8, a, "--registry-depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-depot");
            opts.registry_depot = args[i];
        } else if (std.mem.eql(u8, a, "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            opts.registry_name = args[i];
        } else if (std.mem.eql(u8, a, "--startup-file")) {
            opts.startup_file = true;
        } else if (std.mem.eql(u8, a, "--interactive")) {
            opts.interactive = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt build: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try names.append(gpa, a);
        }
    }
    opts.packages = names.items;

    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);
    // The SAME Julia decides the depot stack and runs the build scripts: an
    // empty `JULIA_DEPOT_PATH` entry expands to that Julia's bundled depots,
    // and a script that writes into a depot nothing else searches is a build
    // that silently did not happen.
    const bindir = julia_bindir orelse if (opts.julia_prefix) |p|
        try fspath.join(arena, &.{ p, "bin" })
    else
        null;
    opts.stack = try resolveStack(arena, io, environ, depots.items, bindir);
    if (opts.stack.entries.len == 0) {
        std.debug.print("ajt build: DEPOT_PATH is empty, nowhere to put a build.log\n", .{});
        return error.MissingArgument;
    }
    // Everything except the three the sandbox pins — see ops/child.zig. A
    // `build.jl` legitimately needs `PATH`, `HOME`, `CC`, proxy settings and
    // whatever else the user's shell exports.
    opts.environ = environ;

    // A run that fails partway is exactly when the per-package records matter,
    // and they sit in a 64 KiB buffer until something flushes.
    defer out.flush() catch {};

    const rep = build_ops.run(gpa, arena, io, opts) catch |err| switch (err) {
        error.NoProject => {
            std.debug.print("ajt build: no project at '{s}'\n", .{opts.env_path});
            return error.MissingArgument;
        },
        error.NotInstalled => {
            std.debug.print(
                "ajt build: the environment is not fully installed; run `ajt instantiate --frozen` first\n",
                .{},
            );
            return error.MissingArgument;
        },
        // Pkg says "`X` declared as a `build` dependency, but no such entry in
        // `extras` or `weakdeps`" (`Operations.jl:2373`). A malformed
        // `[targets]` is the user's file, not a bug, so it gets a sentence
        // rather than a Zig error trace.
        error.TargetDepUnknown => {
            std.debug.print(
                "ajt build: a package's [targets] build list names something in neither [extras] nor [weakdeps]\n",
                .{},
            );
            return error.MissingArgument;
        },
        else => return err,
    };

    try out.print("project\t{s}\n", .{rep.project_file});
    try out.print("manifest\t{s}\n", .{rep.manifest_file});
    try out.print("julia\t{s}\n", .{rep.julia});
    for (rep.builds) |b| {
        var uuid_buf: [36]u8 = undefined;
        try out.print("build\t{s}\t{s}\t{s}\t{s}\t{d:.0}\n", .{
            if (opts.dry_run) "planned" else if (b.ok) "ok" else "failed",
            b.name,
            ajt.model.manifest.formatUuid(b.uuid, &uuid_buf),
            b.log_file,
            b.ms,
        });
        if (b.reresolved) std.debug.print(
            "ajt build: {s} could not use the manifest's exact versions; its sandbox was re-resolved\n",
            .{b.name},
        );
    }
    try out.print("summary\t{d}\t{d}\n", .{ rep.considered, rep.builds.len });

    if (rep.failure) |msg| {
        try out.flush();
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    }
}

/// `ajt status` — the report `Pkg.status` prints, byte for byte.
///
/// The whole product of this command is what lands on stdout, so the CLI's job
/// is only to build `ops/status.zig`'s `Options` and get out of the way. Two
/// argument shapes are worth explaining:
///
///   * The environment is `--env DIR`, not a positional. Every other verb here
///     takes `[env]` positionally, but `status`'s positionals are the package
///     filters `Pkg.status("Foo", "Bar")` takes, and the report has to agree
///     with Pkg's on those. A positional environment would make `ajt status
///     Colors` ambiguous in exactly the case people type most.
///   * `--manifest` is the MODE flag, as in `pkg> status -m`, so the manifest
///     FILE override is `--manifest-file`. `ajt verify` spells the file
///     override `--manifest`; the two commands differ because only this one has
///     to reproduce Pkg's own flag grammar.
///
/// `--diff` and `--workspace` are refused with a message rather than ignored.
/// Both change WHICH packages the report is about, so silently dropping them
/// would answer a different question in the same format — see
/// `Ajt.DIFFERENCES[:status]`.
///
/// Every refusal exits **2** with one line and no stack trace: it is an answer,
/// not a programming error, and a caller piping the report needs to tell "this
/// environment has no upgrades" (0, empty-ish) from "ajt will not report on
/// this" (2).
fn cmdStatus(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var opts: ajt.ops.status.Options = .{ .stack = .{ .entries = &.{} } };
    var env_dir: []const u8 = ".";
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var registry_depot: ?[]const u8 = null;
    var filters: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--env")) {
            i += 1;
            if (i >= args.len) return missingValue("--env");
            env_dir = args[i];
        } else if (std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "-p")) {
            opts.mode = .project;
        } else if (std.mem.eql(u8, a, "--manifest") or std.mem.eql(u8, a, "-m")) {
            opts.mode = .manifest;
        } else if (std.mem.eql(u8, a, "--outdated") or std.mem.eql(u8, a, "-o")) {
            opts.outdated = true;
        } else if (std.mem.eql(u8, a, "--compat") or std.mem.eql(u8, a, "-c")) {
            opts.compat = true;
        } else if (std.mem.eql(u8, a, "--extensions") or std.mem.eql(u8, a, "-e")) {
            opts.extensions = true;
        } else if (std.mem.eql(u8, a, "--manifest-file")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest-file");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--registry-depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-depot");
            registry_depot = args[i];
        } else if (std.mem.eql(u8, a, "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            opts.registry_name = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--diff") or std.mem.eql(u8, a, "-d")) {
            try out.writeAll(
                \\ajt status: --diff is not implemented — it reads Project.toml and
                \\Manifest.toml out of git HEAD, and ajt's git backend has no
                \\`show`/`cat-file` operation. Run `Pkg.status(diff=true)`.
                \\
            );
            try out.flush();
            std.process.exit(2);
        } else if (std.mem.eql(u8, a, "--workspace")) {
            try out.writeAll("ajt status: --workspace is not supported (as everywhere else in ajt)\n");
            try out.flush();
            std.process.exit(2);
        } else if (a.len > 0 and a[0] == '-') {
            try out.print("ajt status: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try filters.append(arena, a);
        }
    }

    // `API.status`'s own refusals (`API.jl:1406-1410`), kept because they are
    // the difference between an empty report and a wrong one.
    if (opts.compat and (opts.outdated or opts.extensions)) {
        try out.writeAll("ajt status: --compat has no --outdated or --extensions mode\n");
        try out.flush();
        std.process.exit(2);
    }

    opts.env_path = env_dir;
    opts.filters = filters.items;
    opts.home = environ.get("HOME");
    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);

    if (depots.items.len != 0) {
        opts.stack = .{ .entries = depots.items };
    } else {
        const bindir: ?[]const u8 = if (opts.julia_prefix) |p|
            try fspath.join(arena, &.{ p, "bin" })
        else
            null;
        opts.stack = ajt.depot.resolve(arena, .fromEnviron(environ.*, bindir)) catch |err| {
            std.debug.print("ajt status: cannot resolve JULIA_DEPOT_PATH: {s}\n", .{@errorName(err)});
            return err;
        };
    }
    // Left null unless asked for: `ops/status.zig` then scans the whole depot
    // stack the way `Registry.reachable_registries()` does. Pinning it to
    // depots1() would find nothing on the scratch-depot-in-front-of-~/.julia
    // layout every harness uses.
    opts.registry_depot = registry_depot;

    // The artifact half of `is_package_downloaded` needs a host platform, and
    // `detectHost` needs both a prefix and a version. Without either, that half
    // is skipped and only the source directory decides -- see
    // `ops/status.zig`'s `isPackageDownloaded`.
    if (opts.julia_prefix) |prefix| {
        const jv: ?[]const u8 = opts.julia_version orelse
            ajt.ops.verify.juliaVersionFromPrefix(arena, io, prefix);
        if (jv) |v| {
            opts.host = ajt.julia.platform.detectHost(arena, io, .{
                .julia_prefix = prefix,
                .julia_version = v,
            }) catch null;
        }
    }

    ajt.ops.status.run(arena, gpa, io, opts, out) catch |err| switch (err) {
        error.WorkspaceUnsupported => {
            try out.writeAll("ajt status: this project defines a [workspace]; run Pkg.status()\n");
            try out.flush();
            std.process.exit(2);
        },
        error.StdlibsUnavailable => {
            try out.writeAll(
                \\ajt status: no Julia installation found — pass --julia-prefix (or put
                \\julia on PATH). The report's row ORDER depends on Types.stdlibs(),
                \\so guessing would produce a plausible wrong answer.
                \\
            );
            try out.flush();
            std.process.exit(2);
        },
        else => |e| return e,
    };
}

/// `ajt gc` — `Pkg.gc()`.
///
/// The one command here that unlinks a user's files, so its output is written
/// to be auditable rather than tidy: every deletion is one tab-separated record
/// with its size, and `--dry-run` produces exactly the same records without
/// touching anything. A user (or a gate) can therefore diff the plan against
/// the outcome.
///
/// `active` is printed FIRST and always, even when it is zero. It is Pkg's
/// `Active manifest files: N found` (`API.jl:864`) and it is the only evidence
/// that gc actually read the logs, as opposed to finding a depot it believed
/// was empty — which is precisely the state in which it deletes everything.
fn cmdGc(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var opts: ajt.ops.gc.Options = .{};
    var verbose = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--all")) {
            opts.collect_delay_ms = ajt.ops.gc.all_collect_delay_ms;
        } else if (std.mem.eql(u8, a, "--collect-delay")) {
            i += 1;
            if (i >= args.len) return missingValue("--collect-delay");
            const secs = std.fmt.parseInt(i64, args[i], 10) catch {
                std.debug.print("ajt gc: --collect-delay wants a whole number of seconds, got '{s}'\n", .{args[i]});
                return error.InvalidArgument;
            };
            if (secs < 0) {
                // A negative delay would satisfy `gc_time - free_time >= delay`
                // for a path orphaned in the FUTURE, i.e. it would delete more
                // than `--all` does. There is no Pkg spelling for that.
                std.debug.print("ajt gc: --collect-delay cannot be negative\n", .{});
                return error.InvalidArgument;
            }
            opts.collect_delay_ms = secs *| 1000;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try out.writeAll(usage);
            return;
        } else {
            std.debug.print("ajt gc: unexpected argument '{s}'\n", .{a});
            return error.UnknownOption;
        }
    }

    try defaultDepots(gpa, arena, environ, &depots);
    if (depots.items.len == 0) {
        std.debug.print("ajt gc: no depot (set --depot or JULIA_DEPOT_PATH)\n", .{});
        return error.MissingArgument;
    }

    var diag: ajt.ops.gc.Diagnostic = .{};
    const rep = ajt.ops.gc.run(gpa, arena, io, .{ .entries = depots.items }, opts, &diag) catch |err| switch (err) {
        // Both of these mean "nothing was collected", and saying so out loud
        // matters more than the exit code: a user who sees an error out of a
        // command whose job is deletion needs to know whether it deleted
        // anything first. It did not.
        error.MalformedUsageLog => {
            std.debug.print(
                "ajt gc: {s} is not a readable usage log; NOTHING was collected.\n" ++
                    "        Fix or delete it -- but understand that deleting it makes every\n" ++
                    "        environment it tracked collectable on the next run.\n",
                .{diag.path},
            );
            return err;
        },
        error.MalformedArtifactsToml => {
            std.debug.print(
                "ajt gc: {s} has an artifact entry with no usable git-tree-sha1;\n" ++
                    "        NOTHING was collected. `Pkg.gc()` fails here too.\n",
                .{diag.path},
            );
            return err;
        },
        error.DepotNotWritable => {
            std.debug.print(
                "ajt gc: the depot's logs/ could not be written, so NOTHING was collected.\n" ++
                    "        gc records what it condemns before it unlinks anything; without\n" ++
                    "        that record a deletion leaves no trace and cannot be retried.\n",
                .{},
            );
            return err;
        },
        else => return err,
    };

    try out.print("active\tmanifest\t{d}\n", .{rep.active_manifests});
    try out.print("active\tartifact\t{d}\n", .{rep.active_artifacts});
    try out.print("active\tscratchspace\t{d}\n", .{rep.active_scratchspaces});

    for (rep.deletions) |d| {
        // `deleted` vs `planned` is the whole difference between a dry run and
        // a real one, and between a real one and a failed unlink.
        try out.print("{s}\t{s}\t{d}\t{s}\n", .{
            if (d.deleted) "deleted" else if (rep.dry_run) "planned" else "failed",
            d.kind.label(),
            d.bytes,
            d.path,
        });
    }

    for ([_]ajt.ops.gc.Kind{ .package, .repo, .artifact, .scratchspace }) |kind| {
        try out.print("total\t{s}\t{d}\t{d}\n", .{ kind.label(), rep.count(kind), rep.bytes(kind) });
    }

    if (verbose and rep.deletions.len == 0) {
        std.debug.print(
            "ajt gc: nothing was collected. With the default 7-day delay that is expected\n" ++
                "        on the first run over a depot -- this run only RECORDED what is\n" ++
                "        orphaned, in <depot>/logs/orphaned.toml. Use --all to collect now.\n",
            .{},
        );
    }
}

// ---------------------------------------------------------------------------
// `ajt git <sub>` — the debug window onto src/git/
//
// Hidden in the same sense `ajt fetch` is: not part of Pkg's vocabulary, and
// present because `tools/diff_harness/git_stream.sh` needs a way to drive a
// backend from a shell and diff it against `git`. Each subcommand is the
// smallest thing that exercises one layer:
//
//   ls-remote    TCP + TLS + HTTP + smart-protocol v2, through the registered
//                `git_stream`. Also the negative gate: the badssl.com hosts
//                must FAIL here, or `encrypted = 1` means "no verification at
//                all" and the whole design is insecure while looking fine.
//   fetch        packfile receive, delta resolution, pack index construction.
//   materialise  a tree written out to a directory, which is the one operation
//                the two backends implement completely differently — `git
//                archive` plus a tar reader on one side, a libgit2 tree walk on
//                the other — and therefore the one worth diffing.
//   hash-object  sha1dc, which the `SHA1DC_CUSTOM_INCLUDE_*` defines can break
//                silently and which nothing else in Ajt would notice.
//
// `fetch` and `materialise` go through `git.Backend`, so they answer to
// `AJT_GIT_BACKEND` exactly as `install`, `add` and `registry update` do —
// `cli` unless it says `lib`. That is what lets one gate run one corpus twice
// and require the same answer. `ls-remote` and `hash-object` are `git.Lib`
// methods rather than vtable rows (nothing in Pkg's flow needs either), so they
// are libgit2-only whatever the variable says.
// ---------------------------------------------------------------------------

fn cmdGit(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        std.debug.print(
            "ajt git: expected a subcommand (ls-remote, fetch, materialise, hash-object)\n",
            .{},
        );
        return error.MissingArgument;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "ls-remote") or std.mem.eql(u8, sub, "hash-object")) {
        if (!ajt.git.haveLibgit2) {
            std.debug.print(
                "ajt git {s}: this binary was built without libgit2;" ++
                    " rebuild with `zig build -Dgit`\n",
                .{sub},
            );
            return error.BackendUnavailable;
        }
        var lib = ajt.git.Lib.init(gpa, io, .{
            .gh_token = environ.get("GH_TOKEN"),
            .github_token = environ.get("GITHUB_TOKEN"),
            .netrc = readNetrc(arena, io, environ),
        }) catch |err| {
            std.debug.print("ajt git: cannot start libgit2: {s}\n", .{@errorName(err)});
            return err;
        };
        defer lib.deinit();
        if (std.mem.eql(u8, sub, "ls-remote")) return cmdGitLsRemote(&lib, arena, out, rest);
        return cmdGitHashObject(&lib, arena, io, out, rest);
    }

    if (std.mem.eql(u8, sub, "fetch") or std.mem.eql(u8, sub, "materialise")) {
        var git_state: GitBackend = .{};
        defer git_state.deinit();
        const b = try git_state.open(gpa, arena, io, environ, try gitEnviron(arena, environ));
        if (std.mem.eql(u8, sub, "fetch")) return cmdGitFetch(&git_state, b, gpa, io, out, rest);
        return cmdGitMaterialise(&git_state, b, gpa, io, out, rest);
    }

    std.debug.print("ajt git: unknown subcommand '{s}'\n", .{sub});
    return error.UnknownCommand;
}

/// Whatever the selected backend has to say about its last failure: libgit2's
/// thread-local message, or nothing at all for `cli`, whose `git` child already
/// wrote its own explanation to this process's stderr.
fn gitMessage(state: *GitBackend) []const u8 {
    return switch (state.which) {
        .lib => if (state.lib_ready) state.lib.message() else "",
        .cli => "",
    };
}

/// `~/.netrc`'s CONTENTS, or null. `auth.decide` takes the text rather than a
/// path so that the whole credential table is reachable from a unit test with
/// no HOME; reading the file is the caller's job, which is here.
fn readNetrc(arena: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const path = fspath.join(arena, &.{ home, ".netrc" }) catch return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

/// One `<sha><TAB><ref>` per line, sorted by ref name so the output is
/// comparable with `git ls-remote | sort` without either side depending on the
/// order the server happened to advertise.
fn cmdGitLsRemote(
    lib: *ajt.git.Lib,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len != 1) {
        std.debug.print("ajt git ls-remote: expected exactly one <url>\n", .{});
        return error.MissingArgument;
    }
    const refs = lib.lsRemote(arena, args[0]) catch |err| {
        std.debug.print("ajt git ls-remote: {s}: {s}\n", .{ @errorName(err), lib.message() });
        return err;
    };
    const sorted = try arena.dupe(ajt.git.lib.Ref, refs);
    std.mem.sort(ajt.git.lib.Ref, sorted, {}, refLessThan);
    for (sorted) |ref| {
        try out.print("{s}\t{s}\n", .{ std.fmt.bytesToHex(ref.id.bytes, .lower), ref.name });
    }
}

fn refLessThan(_: void, a: ajt.git.lib.Ref, b: ajt.git.lib.Ref) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// `ensureClone` into `<dir>`, then optionally resolve a rev and print it.
///
/// A rev rather than `HEAD`, because a repository Ajt creates has no resolvable
/// HEAD to print: `ensureClone` initialises it bare and fetches with Pkg's
/// `refspecs_heads`, so every branch lands under `refs/remotes/cache/heads/`
/// and the unborn `refs/heads/…` that HEAD points at stays unborn. That is
/// Pkg's namespace, not an accident — see `git/lib.zig`'s header.
fn cmdGitFetch(
    state: *GitBackend,
    b: ajt.git.core.Backend,
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 2 or args.len > 3) {
        std.debug.print("ajt git fetch: expected <url> <dir> [rev]\n", .{});
        return error.MissingArgument;
    }
    b.ensureClone(gpa, io, args[1], args[0], .{ .bare = true }) catch |err| {
        std.debug.print("ajt git fetch: {s}: {s}\n", .{ @errorName(err), gitMessage(state) });
        return err;
    };
    if (args.len == 3) {
        const rev = (b.resolveRev(gpa, io, args[1], args[2]) catch |err| {
            std.debug.print("ajt git fetch: {s}: {s}\n", .{ @errorName(err), gitMessage(state) });
            return err;
        }) orelse {
            std.debug.print("ajt git fetch: did not find rev {s} in repository\n", .{args[2]});
            return error.RevNotFound;
        };
        try out.print("{s}\t{s}\n", .{ std.fmt.bytesToHex(rev.commit.bytes, .lower), args[2] });
    }
}

/// `ajt git materialise <repo-dir> <tree-sha1> <dest>` — write a tree out, then
/// print the hash of what actually landed.
///
/// The printed hash is `julia/treehash.zig`'s, recomputed by walking `<dest>`,
/// not the argument echoed back. That is deliberate and it is the whole value
/// of this subcommand: it is the postcondition `git.zig`'s header states, and it
/// is computed by code that shares nothing with either backend, so a backend
/// that writes the wrong bytes cannot also make the check agree.
fn cmdGitMaterialise(
    state: *GitBackend,
    b: ajt.git.core.Backend,
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len != 3) {
        std.debug.print("ajt git materialise: expected <repo-dir> <tree-sha1> <dest>\n", .{});
        return error.MissingArgument;
    }
    const tree = ajt.git.core.Sha1.parse(args[1]) catch {
        std.debug.print("ajt git materialise: '{s}' is not a 40-character sha1\n", .{args[1]});
        return error.MissingArgument;
    };

    // Created here rather than demanded of the caller: `materialise`'s contract
    // is an existing, empty directory, and a shell that has to `mkdir -p` first
    // is a shell that will one day forget.
    Io.Dir.cwd().createDirPath(io, args[2]) catch |err| {
        std.debug.print("ajt git materialise: cannot create '{s}': {s}\n", .{ args[2], @errorName(err) });
        return err;
    };
    b.materialise(gpa, io, args[0], tree, args[2]) catch |err| {
        std.debug.print("ajt git materialise: {s}: {s}\n", .{ @errorName(err), gitMessage(state) });
        return err;
    };

    const got = try ajt.julia.treehash.hashPath(gpa, io, args[2]);
    try out.print("{s}\t{s}\n", .{ std.fmt.bytesToHex(got, .lower), args[2] });
    if (!std.mem.eql(u8, &got, &tree.bytes)) {
        std.debug.print(
            "ajt git materialise: what landed hashes to {s}, not the {s} that was asked for\n",
            .{ std.fmt.bytesToHex(got, .lower), args[1] },
        );
        return error.TreeHashMismatch;
    }
}

/// `git hash-object [--stdin-paths] <file>...`: one SHA-1 per line, in input
/// order.
///
/// `--stdin-paths` is not a convenience. The corpus this is gated against is
/// thousands of files, which does not fit in one argv — and splitting it across
/// several `ajt` invocations appending to one file does NOT work: `Io.File.Writer`
/// writes positionally from offset zero, so the second process overwrites the
/// first's output instead of following it. That produced a silently half-length
/// result the first time `git_stream.sh` ran. One process, one stream.
fn cmdGitHashObject(
    lib: *ajt.git.Lib,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--stdin-paths")) {
        // Read the whole list and split it, the way `ajt fmt --filelist` does.
        // Not `takeDelimiterExclusive`: that tosses the line but NOT the
        // delimiter (`std/Io/Reader.zig:872-876`), so the obvious loop spins
        // forever on the newline it left behind. It did, for ten minutes.
        var in_buf: [64 * 1024]u8 = undefined;
        var stdin: Io.File.Reader = .init(.stdin(), io, &in_buf);
        const all = try stdin.interface.allocRemaining(arena, .limited(64 * 1024 * 1024));
        defer arena.free(all);
        var it = std.mem.splitScalar(u8, all, '\n');
        while (it.next()) |raw| {
            const path = std.mem.trim(u8, raw, " \t\r");
            if (path.len == 0) continue;
            try hashOneObject(lib, arena, io, out, path);
        }
        return;
    }
    if (args.len == 0) {
        std.debug.print("ajt git hash-object: expected at least one <file>, or --stdin-paths\n", .{});
        return error.MissingArgument;
    }
    for (args) |path| try hashOneObject(lib, arena, io, out, path);
}

fn hashOneObject(
    lib: *ajt.git.Lib,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
) !void {
    // The cap is generous rather than absent: this reads a whole file into
    // memory to hash it, and an unbounded read driven by a path argument is an
    // out-of-memory waiting to happen.
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(512 * 1024 * 1024)) catch |err| {
        std.debug.print("ajt git hash-object: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer arena.free(data);
    const id = try lib.hashObject(data);
    try out.print("{s}\n", .{std.fmt.bytesToHex(id.bytes, .lower)});
}

const test_ops = ajt.ops.test_op;

/// `ajt test` — `Pkg.test`, whose product is a child process's exit status.
///
/// Three argument shapes are worth explaining:
///
///   * `--julia-args` and `--test-args` each swallow **everything after them**
///     (up to the other marker), because that is the only spelling that
///     survives a shell. Pkg takes two `Cmd`s and the REPL spells them `test
///     Foo -- --check-bounds=no`; a repeated `--julia-args X` option would
///     force a user to quote each flag separately and would break the moment
///     one of them contained a space. So the first of the two seen ends the
///     option grammar; everything after it belongs to that list until the
///     other marker appears, whereafter the rest belongs to the other. The
///     one thing this grammar cannot express — a literal `--test-args` INSIDE
///     the julia args, or vice versa — is not a flag either julia or a test
///     suite plausibly takes.
///   * `--coverage` is a flag AND takes an optional value, because Pkg's
///     `coverage` is `Bool | String`: bare means `@<package root>`,
///     `--coverage=user` or `--coverage=@/dir` passes the string through.
///   * the positionals are PACKAGES, so the environment is `--project D`, as it
///     is for `build`.
///
/// The flags that describe the calling julia — `--color`, `--depwarn`,
/// `--inline`, `--startup-file`, `--track-allocation`, `--threads` — exist
/// because `gen_subprocess_flags` reads them off `Base.JLOptions()` and `ajt`
/// has none. The `Ajt.jl` wrapper passes the running session's values; the bare
/// CLI's defaults are what a non-interactive session reports.
fn cmdTest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    var depots: std.ArrayList([]const u8) = .empty;
    defer depots.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var julia_bindir: ?[]const u8 = null;
    var opts: test_ops.Options = .{ .env_path = ".", .stack = .{ .entries = &.{} } };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project")) {
            i += 1;
            if (i >= args.len) return missingValue("--project");
            opts.env_path = args[i];
        } else if (std.mem.eql(u8, a, "--depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--depot");
            try depots.append(gpa, args[i]);
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return missingValue("--manifest");
            opts.manifest_file = args[i];
        } else if (std.mem.eql(u8, a, "--julia")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia");
            opts.julia_exe = args[i];
        } else if (std.mem.eql(u8, a, "--julia-prefix")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-prefix");
            opts.julia_prefix = args[i];
        } else if (std.mem.eql(u8, a, "--julia-version")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-version");
            opts.julia_version = args[i];
        } else if (std.mem.eql(u8, a, "--julia-bindir")) {
            i += 1;
            if (i >= args.len) return missingValue("--julia-bindir");
            julia_bindir = args[i];
        } else if (std.mem.eql(u8, a, "--registry-depot")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry-depot");
            opts.registry_depot = args[i];
        } else if (std.mem.eql(u8, a, "--registry")) {
            i += 1;
            if (i >= args.len) return missingValue("--registry");
            opts.registry_name = args[i];
        } else if (std.mem.eql(u8, a, "--coverage")) {
            opts.coverage = .on;
        } else if (std.mem.startsWith(u8, a, "--coverage=")) {
            opts.coverage = .{ .arg = a["--coverage=".len..] };
        } else if (std.mem.eql(u8, a, "--color")) {
            i += 1;
            if (i >= args.len) return missingValue("--color");
            opts.color = args[i];
        } else if (std.mem.eql(u8, a, "--depwarn")) {
            i += 1;
            if (i >= args.len) return missingValue("--depwarn");
            opts.depwarn = args[i];
        } else if (std.mem.eql(u8, a, "--inline")) {
            i += 1;
            if (i >= args.len) return missingValue("--inline");
            opts.inlining = args[i];
        } else if (std.mem.eql(u8, a, "--track-allocation")) {
            i += 1;
            if (i >= args.len) return missingValue("--track-allocation");
            opts.track_allocation = args[i];
        } else if (std.mem.eql(u8, a, "--threads")) {
            i += 1;
            if (i >= args.len) return missingValue("--threads");
            opts.threads = args[i];
        } else if (std.mem.eql(u8, a, "--startup-file")) {
            opts.startup_file = true;
        } else if (std.mem.eql(u8, a, "--tmp-dir")) {
            i += 1;
            if (i >= args.len) return missingValue("--tmp-dir");
            opts.tmp_dir = args[i];
        } else if (std.mem.eql(u8, a, "--keep-sandbox")) {
            opts.keep_sandbox = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--julia-args")) {
            const rest = args[i + 1 ..];
            if (indexOfArg(rest, "--test-args")) |j| {
                opts.julia_args = rest[0..j];
                opts.test_args = rest[j + 1 ..];
            } else opts.julia_args = rest;
            break;
        } else if (std.mem.eql(u8, a, "--test-args")) {
            const rest = args[i + 1 ..];
            if (indexOfArg(rest, "--julia-args")) |j| {
                opts.test_args = rest[0..j];
                opts.julia_args = rest[j + 1 ..];
            } else opts.test_args = rest;
            break;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("ajt test: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        } else {
            try names.append(gpa, a);
        }
    }
    opts.packages = names.items;

    if (opts.julia_prefix == null) opts.julia_prefix = findJuliaPrefix(arena, io, environ);
    // The SAME julia decides the depot stack and runs the tests: an empty
    // `JULIA_DEPOT_PATH` entry expands to that julia's bundled depots, and a
    // suite precompiling into a depot nothing else searches is a test run that
    // silently rebuilt the world.
    const bindir = julia_bindir orelse if (opts.julia_prefix) |p|
        try fspath.join(arena, &.{ p, "bin" })
    else
        null;
    opts.stack = try resolveStack(arena, io, environ, depots.items, bindir);
    if (opts.stack.entries.len == 0) {
        std.debug.print("ajt test: DEPOT_PATH is empty, nowhere for the test child to precompile\n", .{});
        return error.MissingArgument;
    }
    // Everything except the three the sandbox pins — see ops/child.zig. A test
    // suite legitimately reads `PATH`, `HOME`, `CI`, `JULIA_NUM_THREADS` and
    // whatever else the user's shell exports.
    opts.environ = environ;

    // The per-package records are exactly what matters on a run that fails
    // partway, and they sit in a 64 KiB buffer until something flushes. The
    // child writes straight to the terminal, so the buffer is also the only
    // thing that could interleave wrongly with it.
    defer out.flush() catch {};

    const rep = test_ops.run(gpa, arena, io, opts) catch |err| switch (err) {
        error.NoProject => {
            std.debug.print("ajt test: no project at '{s}'\n", .{opts.env_path});
            return error.MissingArgument;
        },
        // `gen_target_project` (`Operations.jl:2373`). A malformed `[targets]`
        // is the user's file, not a bug, so it gets a sentence.
        error.TargetDepUnknown => {
            std.debug.print(
                "ajt test: a package's [targets] test list names something in neither [extras] nor [weakdeps]\n",
                .{},
            );
            return error.MissingArgument;
        },
        else => return err,
    };

    try out.print("project\t{s}\n", .{rep.project_file});
    try out.print("manifest\t{s}\n", .{rep.manifest_file});
    try out.print("julia\t{s}\n", .{rep.julia});
    var passed: usize = 0;
    for (rep.runs) |r| {
        if (r.ok) passed += 1;
        var uuid_buf: [36]u8 = undefined;
        try out.print("test\t{s}\t{s}\t{s}\t{s}\t{d:.0}\n", .{
            if (opts.dry_run) "planned" else if (r.ok) "ok" else "failed",
            r.name,
            ajt.model.manifest.formatUuid(r.uuid, &uuid_buf),
            r.sandbox_dir,
            r.ms,
        });
        try out.print("sandbox\t{s}\t{s}\t{d}\t{d}\n", .{
            r.name,
            if (r.has_test_project) "test/Project.toml" else "targets",
            r.entries,
            r.filled,
        });
        // Said BEFORE the child's failure scrolls past, because "Package Foo
        // not found in current path" out of a test suite reads as the suite's
        // bug until you know the sandbox never had it.
        for (r.missing) |m| std.debug.print(
            "ajt test: {s}'s test environment has no entry for `{s}` and it is not a stdlib; " ++
                "Pkg would resolve it from a registry, and the suite is about to fail to load it\n",
            .{ r.name, m },
        );
        if (r.reresolved) std.debug.print(
            "ajt test: {s} could not use the manifest's exact versions; its sandbox was re-resolved\n",
            .{r.name},
        );
    }
    try out.print("summary\t{d}\t{d}\n", .{ rep.runs.len, passed });

    if (rep.failure) |msg| {
        // Twice, deliberately. The stderr line is for a human at a shell; the
        // `failure` record is for the Julia wrapper, which re-raises the exact
        // message as a `PkgError` the way `Pkg.test` does — reconstructing it
        // from the per-run records would lose the shapes that never ran a
        // child ("did not provide a `test/runtests.jl` file", an unresolved
        // name). The message spans lines, so it is escaped into one record;
        // `test_ops.escapeMessage` is the encoding's home.
        try out.print("failure\t{s}\n", .{try test_ops.escapeMessage(arena, msg)});
        try out.flush();
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    }
}

/// The index of an argv element that IS `needle` (not merely starts with it),
/// for the `--julia-args`/`--test-args` hand-off above.
fn indexOfArg(args: []const []const u8, needle: []const u8) ?usize {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, needle)) return i;
    }
    return null;
}
