#!/usr/bin/env bash
# Differential gate for the package install pipeline (src/ops/install_packages.zig).
#
# Five properties, none of which the unit tests can reach:
#
#   1. AGREEMENT ON THE CANDIDATE LIST — the archive URLs ajt would try, for
#      every package of a real 214-entry manifest, are the URLs
#      `download_source` would build (Operations.jl:1160-1177). Oracle:
#      Pkg's own `find_urls` + `get_archive_url_for_version`, called, not
#      re-derived. Offline.
#
#   2. THE INSTALL IS THE TREE THE REGISTRY PINNED — real packages are
#      downloaded into a TEMP depot and re-hashed on disk with
#      `Pkg.GitTools.tree_hash`, the function Pkg itself compares against
#      `git-tree-sha1` (Operations.jl:812).
#
#   3. THE LAYOUT IS THE ONE JULIA LOOKS IN — the install path is exactly what
#      `Base.find_package` resolves given that depot, and the file modes are
#      Pkg's (`set_readonly`: files lose write bits, directories keep them).
#
#   4. FIXUPS REPRODUCE WHAT PKG RECORDS — `fixups_from_projectfile!`
#      (Operations.jl:252-291) run over the whole committed
#      Open-Reality/Manifest.toml must come back BYTE-IDENTICAL, including
#      every one of its `extensions` blocks. That file was written by Pkg, so
#      byte identity is the oracle. The count is read off the fixture rather
#      than written down here — it has already changed once (dd06430) and a
#      number in a comment does not survive that.
#      Read-only: `--no-download` never writes to the depot.
#
#   5. THE STRONG GATE — `JULIA_DEPOT_PATH=<tmp> julia -e 'using <Pkg>'` loads
#      what ajt installed, with Pkg never entering the process. An installer
#      that produced a plausible-looking tree that Julia cannot load would pass
#      everything above and still be useless.
#
# The user's real ~/.julia is READ in steps 1 and 4 and never written: every
# install targets $WORK/depot.
#
# Usage: tools/diff_harness/install_packages.sh [--offline] [--keep]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AJT_ROOT="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$AJT_ROOT/../.." && pwd)"
DEPOT_ENV="${JULIA_DEPOT_PATH:-}"
HOST_DEPOT="${DEPOT_ENV%%:*}"
HOST_DEPOT="${HOST_DEPOT:-$HOME/.julia}"
MANIFEST="$REPO_ROOT/Open-Reality/Manifest.toml"

OFFLINE=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v julia >/dev/null || { echo "ERROR: julia not on PATH" >&2; exit 2; }
command -v zig   >/dev/null || { echo "ERROR: zig not on PATH" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "ERROR: no $MANIFEST" >&2; exit 2; }

WORK="$(mktemp -d -t ajt-install-XXXXXX)"
if [ $KEEP -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "workdir: $WORK"; fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

STDLIB_DIR="$(julia --startup-file=no -e 'using Pkg; print(Pkg.Types.stdlib_dir())')"
ORACLE="$HERE/install_packages.jl"

echo "==> building ajt"
( cd "$AJT_ROOT" && zig build ) || { echo "ERROR: zig build failed" >&2; exit 2; }
AJT="$AJT_ROOT/zig-out/bin/ajt"

# A probe over the library module, for the one entry point that has no CLI
# surface. Same pattern as extract.sh: linked against src/root.zig directly, so
# the harness needs no build.zig step of its own.
cat > "$WORK/probe.zig" <<'ZIG'
const std = @import("std");
const Io = std.Io;
const ajt = @import("ajt");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    // archive-url <ref> <repo-url>...
    for (args[3..]) |url| {
        const got = try ajt.ops.install_packages.githubArchiveUrl(arena, url, args[2]);
        try out.print("{s}\t{s}\n", .{ url, got orelse "NONE" });
    }
}
ZIG
echo "==> building probe"
( cd "$WORK" && zig build-exe \
    --dep ajt \
    -Mroot=probe.zig \
    -Majt="$AJT_ROOT/src/root.zig" \
    -femit-bin=probe >/dev/null ) || { echo "ERROR: probe build failed" >&2; exit 2; }
PROBE="$WORK/probe"

# ---------------------------------------------------------------------------
echo
echo "==> 1. get_archive_url_for_version, against the real function"

julia --startup-file=no "$ORACLE" archive-urls > "$WORK/urls.julia"
# Feed the probe exactly the URLs the oracle used, in the oracle's order.
cut -f1 "$WORK/urls.julia" > "$WORK/urls.in"
mapfile -t URL_CASES < "$WORK/urls.in"
"$PROBE" archive-url abc123 "${URL_CASES[@]}" > "$WORK/urls.ajt"

N_URLS="$(wc -l < "$WORK/urls.julia")"
# Without this, a julia that failed to start leaves both files empty and
# `diff` succeeds: the gate would report "ok 0 repo URLs agree".
if [ "$N_URLS" -lt 10 ]; then
  bad "the URL oracle produced only $N_URLS records -- julia/Pkg failed to run?"
elif diff -u "$WORK/urls.julia" "$WORK/urls.ajt" > "$WORK/urls.diff"; then
  ok "$N_URLS repo URLs agree with Pkg.Operations.get_archive_url_for_version"
else
  bad "get_archive_url_for_version disagrees" "$(head -12 "$WORK/urls.diff" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 2. the candidate list for every package of a real manifest"

julia --startup-file=no "$ORACLE" candidates "$MANIFEST" > "$WORK/cands.raw"
# Line 1 is `#server <url>|NONE` from the real `pkg_server_registry_info()`.
SERVER_TRACKED="$(head -1 "$WORK/cands.raw" | cut -d' ' -f2)"
tail -n +2 "$WORK/cands.raw" | sort > "$WORK/cands.julia"

"$AJT" install --dry-run \
    --depot "$WORK/depot" \
    --registry-depot "$HOST_DEPOT" \
    "$MANIFEST" | sort > "$WORK/cands.ajt"

# Ajt does not make the live `GET $server/registries` request that decides
# whether candidate 1 exists (see `Job.in_registry`), so when the oracle says
# the server is NOT tracking these registries the two sides legitimately
# disagree about that ONE column. Compare the rest rather than pretending the
# column was oracled -- and say so, so a green run is not read as more than it is.
if [ "$SERVER_TRACKED" = "NONE" ]; then
  cut -f1-3 "$WORK/cands.julia" > "$WORK/cands.julia.cmp"
  # Drop only the pkg-server URL (always column 4 when present).
  awk -F'\t' 'BEGIN{OFS="\t"} {print $1,$2,$3}' "$WORK/cands.ajt" > "$WORK/cands.ajt.cmp"
  echo "  NOTE pkg_server_registry_info() returned nothing; the server candidate is NOT oracled"
else
  cp "$WORK/cands.julia" "$WORK/cands.julia.cmp"
  cp "$WORK/cands.ajt" "$WORK/cands.ajt.cmp"
fi

N_CANDS="$(wc -l < "$WORK/cands.julia")"
if [ "$N_CANDS" -lt 100 ]; then
  bad "the candidate oracle produced only $N_CANDS records -- registry missing?"
elif diff -u "$WORK/cands.julia.cmp" "$WORK/cands.ajt.cmp" > "$WORK/cands.diff"; then
  ok "$N_CANDS packages: candidate URLs and their ORDER match download_source"
else
  bad "candidate lists differ" "$(head -12 "$WORK/cands.diff" | tr '\n' '|')"
fi

# The job SET is Pkg's `tracking_registered_version`, called (not re-derived)
# by the oracle. Equal counts is the assertion that ajt's filter -- which
# leaves out the version-parameterised `is_stdlib` term -- selects the same
# packages on real data.
check "the same packages are selected for download" \
  "$N_CANDS" "$(wc -l < "$WORK/cands.ajt")"

# The default invocation resolves DEPOT_PATH itself; every other gate here
# passes --depot, so without this the `init_depot_path()` path is never run.
if "$AJT" install --dry-run "$MANIFEST" > "$WORK/cands.default" 2>"$WORK/cands.default.err"; then
  check "install with no --depot resolves DEPOT_PATH on its own" \
    "$N_CANDS" "$(wc -l < "$WORK/cands.default")"
else
  bad "install with no --depot failed" "$(head -2 "$WORK/cands.default.err" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 3. fixups_from_projectfile! over the whole committed manifest"

# Read-only against the host depot: --no-download installs nothing. The
# committed manifest was written by Pkg AFTER its own fixups pass, so anything
# but byte identity is a divergence.
"$AJT" install --no-download \
    --depot "$HOST_DEPOT" \
    --stdlib "$STDLIB_DIR" \
    --output "$WORK/fixed.toml" \
    "$MANIFEST" > "$WORK/fixups.records" 2> "$WORK/fixups.err"
FIXUP_RC=$?

# Entries whose Project.toml was actually READ. Without this the byte-identity
# check below would pass for a pass that resolved nothing and touched nothing.
RESOLVED="$(awk -F'\t' '$1=="fixup" && $3!="-"' "$WORK/fixups.records" | wc -l)"
if [ "$FIXUP_RC" -ne 0 ]; then
  bad "fixups pass exited $FIXUP_RC" "$(head -3 "$WORK/fixups.err" | tr '\n' '|')"
elif [ "$RESOLVED" -lt 100 ]; then
  # Every entry reporting "-" would make the byte-identity check vacuous.
  bad "only $RESOLVED manifest entries resolved to a Project.toml -- depot not populated?"
elif diff -u "$MANIFEST" "$WORK/fixed.toml" > "$WORK/fixed.diff"; then
  ok "$RESOLVED entries read; the manifest round-trips BYTE-IDENTICAL through fixups"
else
  bad "fixups changed the committed manifest" "$(head -20 "$WORK/fixed.diff" | tr '\n' '|')"
fi

# The extensions blocks are the whole reason this pass exists; assert they
# survived rather than trusting that an empty output happened to match.
#
# The floor is deliberately NOT the fixture's exact count. It used to be `-lt
# 19`, which went stale the moment the engine manifest changed shape — dd06430
# made OpenAL_jll a weak dep and took the file to 17 blocks, so this line
# failed for reasons that had nothing to do with the code under test. The
# assertion that matters is the `check` above (every block survived the round
# trip); this one only has to establish that the fixture is non-trivial, so it
# is a loose floor and reports the number it saw.
EXT_SRC="$(grep -c 'extensions\]' "$MANIFEST")"
EXT_OUT="$(grep -c 'extensions\]' "$WORK/fixed.toml" || true)"
check "extensions blocks preserved" "$EXT_SRC" "$EXT_OUT"
if [ "$EXT_SRC" -lt 5 ]; then
  bad "the manifest fixture has too few extensions blocks to gate anything" \
      "found $EXT_SRC in $MANIFEST"
fi

# And that the pass is not a no-op by construction: dropping the metadata from
# an entry must be REPAIRED by fixups, not left alone.
python3 - "$MANIFEST" "$WORK/stripped.toml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, skip = [], False
for line in open(src):
    s = line.strip()
    # Drop ConstructionBase's weakdeps line and its whole extensions block.
    if s.startswith('[deps.ConstructionBase.extensions]'):
        skip = True
        continue
    if skip:
        if s == '' or s.startswith('['):
            skip = False
        else:
            continue
    if s.startswith('weakdeps = ["IntervalSets"'):
        continue
    out.append(line)
open(dst, 'w').writelines(out)
PY
# Both halves of the strip must have bitten, or the repair test silently
# narrows to whichever field survived.
STRIPPED_EXT="$(grep -c 'deps.ConstructionBase.extensions\]' "$WORK/stripped.toml" || true)"
STRIPPED_WEAK="$(grep -c 'weakdeps = \["IntervalSets"' "$WORK/stripped.toml" || true)"
if [ "$STRIPPED_EXT" != "0" ] || [ "$STRIPPED_WEAK" != "0" ]; then
  bad "the strip step left ConstructionBase's metadata in place (ext=$STRIPPED_EXT weak=$STRIPPED_WEAK)"
elif diff -q "$MANIFEST" "$WORK/stripped.toml" >/dev/null; then
  bad "the strip step changed nothing -- this check would be vacuous"
else
  "$AJT" install --no-download --depot "$HOST_DEPOT" --stdlib "$STDLIB_DIR" \
      --output "$WORK/repaired.toml" "$WORK/stripped.toml" > "$WORK/repair.records" 2>/dev/null
  if diff -q "$MANIFEST" "$WORK/repaired.toml" >/dev/null; then
    ok "stripped weakdeps/extensions are restored from the installed Project.toml"
  else
    bad "fixups did not restore stripped metadata" \
        "$(diff "$MANIFEST" "$WORK/repaired.toml" | head -8 | tr '\n' '|')"
  fi
  check "the repaired entry is reported as changed" "1" \
    "$(awk -F'\t' '$1=="fixup" && $2=="ConstructionBase" {print $4}' "$WORK/repair.records")"
fi

# ---------------------------------------------------------------------------
if [ $OFFLINE -eq 1 ]; then
  echo
  echo "==> SKIPPING the download gates (--offline)"
else
  echo
  echo "==> 4. downloading real packages into a temp depot"

  if ! "$AJT" fetch --status https://pkg.julialang.org/registries >/dev/null 2>&1; then
    echo
    echo "########################################################################"
    echo "# SKIPPED: no network (https://pkg.julialang.org unreachable).          #"
    echo "# The offline gates above ran; the download, layout, mode and           #"
    echo "# 'using' gates did NOT. Re-run with network to exercise them.          #"
    echo "########################################################################"
    OFFLINE=1
  fi
fi

if [ $OFFLINE -eq 0 ]; then
  # Five real packages from the Open-Reality manifest. All have no manifest
  # deps, so `using` needs nothing else installed, and all carry `extensions`,
  # so the fixups pass has something to do.
  PKGS=(CompositionsBase ConstructionBase InverseFunctions IntervalSets OffsetArrays)

  mkdir -p "$WORK/env" "$WORK/depot"
  # The subset manifest is stripped of exactly the three fields fixups exists
  # to produce, so step 8 is a repair test rather than a copy test. Stripping
  # is also REQUIRED: the full manifest spells weakdeps in the bare-name array
  # form, which is only legal when every name is an entry of the same manifest
  # (manifest.jl:136-141) -- carrying it into a five-package subset would be a
  # file Pkg itself refuses to read.
  julia --startup-file=no -e '
  using TOML
  full = TOML.parsefile(ARGS[1])
  want = ARGS[3:end]
  deps = Dict{String,Any}()
  proj = Dict{String,Any}()
  for n in want
      haskey(full["deps"], n) || error("$n is not in the manifest")
      e = copy(full["deps"][n][1])
      isempty(get(e, "deps", [])) || error("$n has manifest deps; pick a leaf package")
      haskey(e, "extensions") || error("$n records no extensions; pick one that does")
      for k in ("weakdeps", "extensions", "entryfile")
          delete!(e, k)
      end
      deps[n] = [e]
      proj[n] = e["uuid"]
  end
  open(ARGS[2] * "/Manifest.toml", "w") do io
      TOML.print(io, Dict("julia_version" => full["julia_version"],
                          "manifest_format" => "2.0",
                          "deps" => deps); sorted = true)
  end
  open(ARGS[2] * "/Project.toml", "w") do io
      TOML.print(io, Dict("deps" => proj); sorted = true)
  end' "$MANIFEST" "$WORK/env" "${PKGS[@]}"

  "$AJT" install \
      --depot "$WORK/depot" \
      --registry-depot "$HOST_DEPOT" \
      --stdlib "$STDLIB_DIR" \
      --output "$WORK/env/Manifest.toml" \
      "$WORK/env/Manifest.toml" > "$WORK/install.records" 2> "$WORK/install.err"
  INSTALL_RC=$?
  check "install exited cleanly" "0" "$INSTALL_RC"
  [ "$INSTALL_RC" -eq 0 ] || sed 's/^/       /' "$WORK/install.err" | head -10

  check "every package reports installed" "${#PKGS[@]}" \
    "$(awk -F'\t' '$1=="install" && $2=="installed"' "$WORK/install.records" | wc -l)"

  # --- the tree hash, from the oracle Pkg itself compares against -----------
  echo
  echo "==> 5. the installed tree is the tree git-tree-sha1 pinned"

  # A `while read` over an empty file runs zero times and would contribute
  # neither a pass nor a failure, so the count is asserted first.
  N_REC="$(awk -F'\t' '$1=="install"' "$WORK/install.records" | wc -l)"
  check "one install record per package to hash" "${#PKGS[@]}" "$N_REC"
  while IFS=$'\t' read -r _ _ name _ want path; do
    got="$(julia --startup-file=no -e 'using Pkg; print(bytes2hex(Pkg.GitTools.tree_hash(ARGS[1])))' "$path")"
    check "$name tree hash (GitTools.tree_hash oracle)" "$want" "$got"
  done < <(awk -F'\t' '$1=="install"' "$WORK/install.records")

  # --- the layout Base.find_package resolves -------------------------------
  echo
  echo "==> 6. the install path is what Base.find_package resolves"

  for p in "${PKGS[@]}"; do
    want="$(awk -F'\t' -v n="$p" '$1=="install" && $3==n {print $6}' "$WORK/install.records")"
    got="$(JULIA_DEPOT_PATH="$WORK/depot" JULIA_LOAD_PATH="$WORK/env:@stdlib" \
      julia --startup-file=no -e '
        p = Base.find_package(ARGS[1])
        print(p === nothing ? "NONE" : dirname(dirname(p)))' "$p")"
    check "$p resolves to the install path" "$want" "$got"
  done

  # --- file modes ----------------------------------------------------------
  echo
  echo "==> 7. file modes match Pkg's set_readonly"

  # `set_readonly` clears the write bits on FILES and deliberately leaves
  # directories writable, or Pkg.gc()/Pkg.rm could not remove them
  # (utils.jl:59-63). Symlinks are skipped (chmod would follow the link).
  if [ ! -d "$WORK/depot/packages" ]; then
    bad "nothing was installed, so there are no modes to check"
  else
    WRITABLE_FILES="$(find "$WORK/depot/packages" -type f -perm -u+w | wc -l)"
    check "no installed file is writable" "0" "$WRITABLE_FILES"
    NDIRS="$(find "$WORK/depot/packages" -type d | wc -l)"
    RWDIRS="$(find "$WORK/depot/packages" -type d -perm -u+w | wc -l)"
    check "every installed directory stays writable" "$NDIRS" "$RWDIRS"
    NFILES="$(find "$WORK/depot/packages" -type f | wc -l)"
    if [ "$NFILES" -lt 50 ]; then
      bad "only $NFILES files installed -- fixture too thin"
    else
      ok "$NFILES files across $NDIRS directories carry Pkg's modes"
    fi
  fi

  # --- fixups against what Pkg recorded in the real manifest ---------------
  echo
  echo "==> 8. fixups reproduce the committed manifest's metadata"

  # Compared semantically, not byte-wise: the subset manifest lacks the entries
  # (IntervalSets, LinearAlgebra, ...) that let `destructure` use the bare-name
  # ARRAY encoding for weakdeps, so it legitimately emits the table form
  # instead (manifest.jl:334-347). The CONTENT has to be identical.
  julia --startup-file=no -e '
  using TOML
  full = TOML.parsefile(ARGS[1])["deps"]
  ours = TOML.parsefile(ARGS[2])["deps"]
  # `weakdeps` has two legal encodings and which one Pkg writes depends on the
  # rest of the manifest (manifest.jl:334-347), so compare NAMES: the committed
  # file uses the bare-name array, the five-package subset must use the table.
  # `extensions` values are String OR Vector{String} and that distinction IS
  # semantic, but a lone string and a one-element vector name the same trigger,
  # so widen both before comparing -- byte identity for that is what step 3
  # already gates over the full file.
  names(w) = w === nothing ? String[] : sort(w isa AbstractVector ? collect(w) : collect(keys(w)))
  norm(e) = (
      names(get(e, "weakdeps", nothing)),
      Dict(k => (v isa String ? [v] : v) for (k, v) in get(e, "extensions", Dict())),
      get(e, "entryfile", nothing),
  )
  bad = 0
  for n in ARGS[3:end]
      a, b = norm(full[n][1]), norm(ours[n][1])
      if a == b
          println("  ok   ", n, " weakdeps/extensions/entryfile match Pkg")
      else
          println("  FAIL ", n, "\n       want ", a, "\n       got  ", b)
          global bad += 1
      end
      isempty(a[2]) && (println("  FAIL ", n, " has no extensions -- fixture too weak"); global bad += 1)
  end
  exit(bad == 0 ? 0 : 1)' "$MANIFEST" "$WORK/env/Manifest.toml" "${PKGS[@]}"
  # One exit code, one result: the julia block above already printed its own
  # per-package ok/FAIL lines.
  if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

  # --- idempotence ---------------------------------------------------------
  echo
  echo "==> 9. a second install is a no-op, and --jobs 1 agrees with --jobs 8"

  "$AJT" install --depot "$WORK/depot" --registry-depot "$HOST_DEPOT" \
      --server "" \
      "$WORK/env/Manifest.toml" > "$WORK/install2.records" 2>/dev/null
  # `--server ""` removes the Pkg-server candidate entirely, so if anything
  # were re-downloaded it would have to come from api.github.com; every record
  # saying `already_present` proves nothing was fetched at all.
  check "second run reports already_present for all" "${#PKGS[@]}" \
    "$(awk -F'\t' '$1=="install" && $2=="already_present"' "$WORK/install2.records" | wc -l)"

  # The worker pool is the one part with no Julia oracle. `--jobs 1` runs
  # everything inline on the calling thread, `--jobs 8` spawns Io.concurrent
  # workers over a shared cursor; they must install the identical set. A
  # dropped or double-claimed job shows up here and nowhere else.
  "$AJT" install --jobs 1 --depot "$WORK/depot-serial" --registry-depot "$HOST_DEPOT" \
      --no-fixups "$WORK/env/Manifest.toml" > "$WORK/serial.records" 2>/dev/null
  awk -F'\t' '$1=="install"{print $3"\t"$5}' "$WORK/serial.records" | sort > "$WORK/serial.set"
  awk -F'\t' '$1=="install"{print $3"\t"$5}' "$WORK/install.records" | sort > "$WORK/par.set"
  check "serial run installed every package" "${#PKGS[@]}" "$(wc -l < "$WORK/serial.set")"
  if diff -q "$WORK/serial.set" "$WORK/par.set" >/dev/null; then
    ok "--jobs 1 and the concurrent run install the identical package/hash set"
  else
    bad "serial and concurrent installs differ" \
        "$(diff "$WORK/serial.set" "$WORK/par.set" | head -6 | tr '\n' '|')"
  fi
  check "no staging directory survived the concurrent run" "0" \
    "$(find "$WORK/depot" -name '.ajt-tmp-*' | wc -l)"

  # --- an unservable pin exhausts the chain and writes nothing --------------
  echo
  echo "==> 10. a pin no mirror can serve exhausts the fallback chain"

  # Both real sources key on the tree hash, so an unknown one 404s at BOTH
  # rather than serving a wrong tree: this gates the exhaustion path (every
  # candidate tried in order, then `needs_git_clone`), not the hash check.
  # A mirror that serves the WRONG tree needs a server that lies, which is what
  # the loopback test in src/ops/install_packages.zig is for.
  julia --startup-file=no -e '
  using TOML
  e = copy(TOML.parsefile(ARGS[1])["deps"]["ConstructionBase"][1])
  e["git-tree-sha1"] = "0" ^ 40
  for k in ("extensions", "weakdeps", "entryfile"); delete!(e, k); end
  open(ARGS[2], "w") do io; TOML.print(io, Dict("manifest_format" => "2.0",
       "deps" => Dict("ConstructionBase" => [e])); sorted = true); end' \
    "$WORK/env/Manifest.toml" "$WORK/badpin.toml"

  # `--no-git` keeps this step about the ARCHIVE chain, which is what it is
  # titled for. With the git fallback live the same pin also clones
  # ConstructionBase from GitHub and reports `failed` when the object turns out
  # not to be there — correct, but a different property (and a 5 MB clone).
  # `tools/diff_harness/install_git.sh` gates that half.
  "$AJT" install --depot "$WORK/depot2" --registry-depot "$HOST_DEPOT" --no-fixups \
      --no-git "$WORK/badpin.toml" > "$WORK/badpin.records" 2> "$WORK/badpin.err"
  BADPIN_RC=$?
  check "an unservable pin fails the install" "1" "$([ $BADPIN_RC -ne 0 ] && echo 1 || echo 0)"
  check "and is reported as needing a git clone" "needs_git_clone" \
    "$(awk -F'\t' '$1=="install" {print $2}' "$WORK/badpin.records")"
  # Both candidates must have been tried, in order, and both reported.
  check "both candidate URLs were tried and reported" "2" \
    "$(grep -c 'HTTP 404' "$WORK/badpin.err" || true)"
  if grep -q 'api.github.com' "$WORK/badpin.err"; then
    ok "the GitHub fallback was reached after the Pkg server declined"
  else
    bad "no GitHub fallback attempt" "$(head -3 "$WORK/badpin.err" | tr '\n' '|')"
  fi
  # NB this cannot distinguish "cleaned up" from "never staged": with both
  # candidates 404ing, `depot.begin` is never reached, so `$WORK/depot2/packages`
  # may not exist at all. It gates the weaker property that a failed install
  # publishes nothing. The case that actually STAGES and then has to unwind --
  # a mirror serving a tarball that does not match the pin -- needs a server
  # that lies, and is gated by the loopback unit test
  # "a tarball that does not match its pin writes nothing and falls through".
  #
  # Scoped to `packages/`, which is what the check is about. The depot root is
  # NOT empty after a failed install and must not be: `install` stamps
  # `logs/manifest_usage.toml` when it loads the environment, exactly as
  # Julia's `EnvCache` does (Types.jl:426) and equally regardless of whether
  # the download that follows succeeds. Without that stamp a later `Pkg.gc()`
  # would collect everything in the depot.
  check "no package tree under the failed depot" "0" \
    "$(find "$WORK/depot2/packages" -mindepth 1 -type f 2>/dev/null | wc -l)"
  check "no staging leftover under the failed depot" "0" \
    "$(find "$WORK/depot2" -name '.ajt-tmp-*' 2>/dev/null | wc -l)"

  # --- THE STRONG GATE -----------------------------------------------------
  echo
  echo "==> 11. stock julia loads what ajt installed, with Pkg never invoked"

  USING="$(printf 'using %s\n' "$(IFS=,; echo "${PKGS[*]}")")"
  OUT="$(JULIA_DEPOT_PATH="$WORK/depot" JULIA_LOAD_PATH="$WORK/env:@stdlib" \
    julia --startup-file=no -e "
      $USING
      pkg_in = any(m -> string(nameof(m)) == \"Pkg\", Base.loaded_modules_array())
      print(pkg_in ? \"PKG_WAS_LOADED\" : \"OK\")
    " 2>"$WORK/using.err")"
  if [ "$OUT" = "OK" ]; then
    ok "using ${PKGS[*]} — loaded from the temp depot, Pkg never entered the process"
  else
    bad "using failed" "$(printf '%s' "$OUT"; tail -5 "$WORK/using.err" | tr '\n' '|')"
  fi

  # The depot must be self-sufficient: nothing may have leaked in from the
  # host depot, which would make the gate above pass for the wrong reason.
  for p in "${PKGS[@]}"; do
    [ -d "$WORK/depot/packages/$p" ] || bad "$p is not in the temp depot at all"
  done
fi

# ---------------------------------------------------------------------------
echo
echo "======================================================================"
printf 'install_packages: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ $OFFLINE -eq 1 ]; then
  echo "(download gates skipped -- run with network for the full set)"
fi
[ $FAIL -eq 0 ] || exit 1
exit 0
