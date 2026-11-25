#!/bin/bash
# Build of patched Mesa + Wine for running the NVIDIA 2002-2005 OpenGL demos and
# tech demos (case study: Dusk 2003 = WGL + GL_NV_vertex_program /
# GL_NV_fragment_program + Cg 1.1 + NV_register_combiners).
#
# Both sources are TAKEN FROM THE UPSTREAM REPOSITORIES (branch/tag pinned below),
# cloned, patched and built inside ./build.  Nothing here assumes where the repository
# lives: every default path is derived from the directory of this file, so the tree can
# be checked out anywhere.
#
#   wine : https://gitlab.winehq.org/wine/wine      ref wine-11.18  (tag)
#   mesa : https://gitlab.freedesktop.org/mesa/mesa ref mesa-26.2.3 (tag; branch 26.2)
#
# Usage:
#   ./build.sh                     clone + patch + build both
#   ./build.sh --mesa-only         Mesa only
#   ./build.sh --wine-only         Wine only
#   ./build.sh --fresh             re-clone the sources from scratch
#   ./build.sh --reconfigure       re-apply the build options (meson/configure)
#   ./build.sh --configure-only    setup without compiling (fast)
#   ./build.sh --no-patches        do not apply patches (tree already annotated)
#   ./build.sh --release           features only: the diagnostics series is left out for
#                                  BOTH Mesa and Wine, symbols stripped, meson
#                                  buildtype=release + b_ndebug
#   ./build.sh --debug             features + diagnostics, symbols kept,
#                                  meson buildtype=debug
#   ./build.sh --no-mesa-diag      exclude the Mesa diagnostics series (0002)
#   ./build.sh --wine-diag         include the Wine diagnostics series (the default)
#   ./build.sh --clean-wine        delete work-wine and the installed Wine before
#                                  building.  Needed when the work dir is stale and make
#                                  does not recompile the patched modules: real incident
#                                  on 2026-11-03, where modules WITHOUT our patch were
#                                  installed silently (rc=0), the demos refused to start
#                                  because the NV extension was missing, and the build
#                                  looked fine.  build.sh now notices on its own
#                                  (--pulisci-wine is kept as an alias).
#   ./build.sh --src DIR           source directory (default: this repository)
#   ./build.sh --out DIR           build/install directory (default: ./build)
#
# Environment variables (default in parentheses):
#   NV_SRC       (directory of this script) where the two repositories live
#   NV_BUILD     (<repo>/build)            where they are built and installed
#   NV_BUILD_MODE (debugoptimized)         release | debug | debugoptimized
#                        (the older names MESA_COMMIT_VISTO / WINE_COMMIT_VISTO are still read)
#   MESA_SEEN_COMMIT/WINE_SEEN_COMMIT  the commit the patches were proven against
#   MESA_REF/WINE_REF                      ref to clone
#   MESA_DRIVERS  (zink)                   gallium-drivers.  Default is zink ONLY:
#                                          OpenGL on top of Vulkan, so it runs on any
#                                          GPU with a Vulkan driver.
#                                          (MESA_DRIVERS=zink,radeonsi for the native
#                                          AMD path, about 20% faster)
#   MESA_VULKAN   ("")                     vulkan-drivers; empty means zink uses the
#                                          SYSTEM Vulkan driver (for example
#                                          /usr/share/vulkan/icd.d/radeon_icd.json,
#                                          nvidia_icd.json, lvp/swiftshader...).  Set
#                                          amd / intel / virtio to carry one inside
#                                          this build.
#   MESA_LLVM     (0)                      0 = no LLVM
#   MESA_BUILDTYPE (debugoptimized)        meson buildtype
#   MESA_EXTRA_OPTS ("")                   extra meson options
#   WINE_ARCHS    (i386,x86_64)            i386 is needed by 32-bit apps (Dusk)
#   WINE_EXTRA_CONFIGURE ("")              extra configure options
#   JOBS          (nproc)
#
# Output:
#   $NV_BUILD/mesa/lib64/...   installed Mesa (libgallium, libGL, lib64/dri/)
#   $NV_BUILD/wine/bin/wine    installed Wine
#   $NV_BUILD/wine.env         file with the variables to export in order to use them
#
# Why these patches exist at all: see README.md and docs/.

set -eu

DIR=$(cd "$(dirname "$0")" && pwd)

MESA_URL=https://gitlab.freedesktop.org/mesa/mesa
MESA_REF=${MESA_REF:-mesa-26.2.3}
MESA_SEEN_COMMIT=${MESA_SEEN_COMMIT:-${MESA_COMMIT_VISTO:-31e9a6b}}
WINE_URL=https://gitlab.winehq.org/wine/wine
WINE_REF=${WINE_REF:-wine-11.18}
WINE_SEEN_COMMIT=${WINE_SEEN_COMMIT:-${WINE_COMMIT_VISTO:-7b3fff7}}

# The Mesa patches are applied in fileName order:
#   0001-nv-legacy-features.patch    the NV features (what makes the demos work)
#   0002-nv-legacy-diagnostics.patch tracing/dumping/experimental switches
MESA_PATCH_DIR="$DIR/patches/mesa"
WINE_PATCH_DIR="$DIR/patches/wine"
# OPTIONAL series: probes and pure experiments, not needed to run the demos.
# It is applied only when asked for (--wine-diag or WINE_WITH_DIAG=1), so the
# default build stays minimal.  Note: the main series cannot be reduced further:
# measured (2026-10-28, cumulative application on a clean worktree) only 6 of the
# 66 patches can be dropped without breaking the contexts of later hunks; the other
# 60 are coupled to each other.  So real tidiness comes from squashing with markers
# the way Mesa does (see docs/wine-patch-series.md).
# The Wine series is now like the Mesa one: a features file and a diagnostics file
# (probes, dumps, experimental knobs), generated from the marked development tree:
#   0001-nv-legacy-features.patch      what makes the demos run
#   0002-nv-legacy-diagnostics.patch   tracing/dumping/experiments, knobs off
# Diagnostics is INCLUDED by default (as with Mesa), but it can be left out entirely
# with --no-wine-diag: 0001 alone must compile and the demos must stay green.
WINE_WITH_DIAG=${WINE_WITH_DIAG:-1}
WINE_DIAG_GLOB="*diagnostics*.patch"
# Extra patches to apply AFTER the series in WINE_PATCH_DIR (a list of paths;
# useful for local experiments on top of the series).
WINE_EXTRA_PATCHES=""

# Source trees: the product layout is ./mesa-src and ./wine-src, so a user gets one
# self-contained directory.  The old development layout ($SRC/mesa, $SRC/wine) is still
# honoured when it exists: silently cloning a second Mesa next to it would be worse.
SRC=${NV_SRC:-$DIR}
OUT=${NV_BUILD:-$DIR/build}
# Was the output directory stated on purpose (explicit --out, or NV_BUILD)?  Used below to
# decide whether release mode may relocate the output on its own.
OUT_EXPLICIT=0
if [ -n "${NV_BUILD:-}" ]; then OUT_EXPLICIT=1; fi

if [ -d "$SRC/mesa-src" ] || [ ! -d "$SRC/mesa" ]; then
    MESA_SRC=${MESA_SRC:-$SRC/mesa-src}
else
    MESA_SRC=${MESA_SRC:-$SRC/mesa}
fi
if [ -d "$SRC/wine-src" ] || [ ! -d "$SRC/wine" ]; then
    WINE_SRC=${WINE_SRC:-$SRC/wine-src}
else
    WINE_SRC=${WINE_SRC:-$SRC/wine}
fi
MESA_BUILD=${MESA_BUILD:-$OUT/work-mesa}
MESA_PREFIX=${MESA_PREFIX:-$OUT/mesa}
WINE_BUILD=${WINE_BUILD:-$OUT/work-wine}
WINE_PREFIX=${WINE_PREFIX:-$OUT/wine}

MESA_DRIVERS=${MESA_DRIVERS:-zink}
MESA_VULKAN=${MESA_VULKAN:-}
MESA_LLVM=${MESA_LLVM:-0}
# BUILD MODE (--release / --debug)
#   release: features only (diagnostics series left out for Mesa AND Wine), symbols
#            stripped, meson buildtype=release + b_ndebug
#   debug:   features + diagnostics, symbols kept, meson buildtype=debug
# The default stays what this project has always built (debugoptimized + diagnostics),
# so no existing measurement changes meaning.
BUILD_MODE=${NV_BUILD_MODE:-debugoptimized}
MESA_WITH_DIAG=${MESA_WITH_DIAG:-1}
MESA_DIAG_GLOB="*diagnostics*.patch"
MESA_BUILDTYPE=${MESA_BUILDTYPE:-debugoptimized}
MESA_EXTRA_OPTS=${MESA_EXTRA_OPTS:-}
WINE_ARCHS=${WINE_ARCHS:-i386,x86_64}
WINE_EXTRA_CONFIGURE=${WINE_EXTRA_CONFIGURE:-}
# JOBS: the default is every core (nproc), which is 32 on this machine.
#
# This used to be capped by the memory the host had available, and the reason was real, so
# it is recorded here instead of being silently deleted: a Mesa C++ translation unit with
# debug info peaks above 1 GiB of RSS, so 32 parallel compilations ask for tens of
# gigabytes; on 2026-11-05 the host reached 96% of RAM while we were working, and an
# out-of-memory build does not merely fail - the kernel picks victims, and one of them can
# be the user's desktop session. The cap budgeted about 1 GiB per job and left 2 GiB free.
#
# On 2026-11-09 the user lifted the restriction for this machine: the agent engine that runs
# these builds uses much less memory after a recent update, so builds may use every core.
# Two explicit ways to get the previous behaviour back:
#   NV_JOBS_DA_MEMORIA=1   cap the job count by MemAvailable, as before
#   JOBS=<n>               say the number directly; it always wins
_NV_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
[ -n "$_NV_AVAIL_KB" ] || _NV_AVAIL_KB=2097152
if [ -z "${JOBS:-}" ]; then
    _nv_n=$(nproc 2>/dev/null || echo 1)
    if [ -n "${NV_JOBS_DA_MEMORIA:-}" ]; then
        # Budget: about 1 GiB per compile job, and 2 GiB left over for everything else running.
        _nv_cap=$(( _NV_AVAIL_KB / 1048576 - 2 ))
        [ "$_nv_cap" -lt 1 ] && _nv_cap=1
        if [ "$_nv_cap" -lt "$_nv_n" ]; then
            JOBS=$_nv_cap
            JOBS_CAPPED=1
        else
            JOBS=$_nv_n
            JOBS_CAPPED=0
        fi
    else
        JOBS=$_nv_n
        JOBS_CAPPED=0
    fi
else
    JOBS_CAPPED=0
fi

DO_MESA=1
DO_WINE=1
CONFIGURE_ONLY=0
NO_PATCHES=0
RECONFIGURE=0
FRESH=0

say() { echo "=== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
if [ "$JOBS_CAPPED" = "1" ] || [ -n "${NV_JOBS_DA_MEMORIA:-}" ]; then
    say "  JOBS=$JOBS su nproc=$(nproc 2>/dev/null || echo ?): MemAvailable=$(( _NV_AVAIL_KB / 1024 ))MiB, tetto di circa 1GiB per lavoro piu 2GiB di margine, per non mandare il sistema in out of memory. Sovrascrivibile con JOBS=N"
fi

# Idempotence: if a previous run already applied the patches and then failed at a
# later stage, they are not applied a second time ("reversed or previously
# applied").  Both sources are clones managed by this toolchain, so before applying
# the series the pristine ref is restored: every build starts clean.
# HAZARD, measured on 2026-11-16 at 09:12: when the tree is NOT already annotated, a
# "--release" run restores the pristine ref and applies ONLY 0001 (features), so the nvdbg
# markers disappear from ./wine-src (grep -c nvdbg:begin fell from 196 to 0). Generating the
# series right after that would write an EMPTY 0002 and drop the whole diagnostics layer from
# the committed series. The shield held: tools/make_nv_patches.py stopped with "ERRORE: 0002
# senza hunks", and the series was already safe in HEAD. Rule: after a --release build check
# the marker count, and if it is zero run ./build.sh --wine-only before generating patches.
# True when the Wine tree already carries the toolchain patches: either as local
# commits (the series is sometimes committed by hand with "nv-legacy:" messages) or
# as uncommitted changes.  Applying them again would produce "Reversed (or
# previously applied)" and lose the diagnostics; also the numeric order depends on
# 0003 (GLX TFP) coming before 0004 (render texture).
wine_already_patched() {
    src=$1
    [ -d "$src/.git" ] || return 1
    (cd "$src" && git log --format='%s' 2>/dev/null | grep -qm1 '^nv-legacy:') && return 0
    [ -n "$(cd "$src" && git status --porcelain 2>/dev/null)" ] && return 0
    return 1
}

pristine_tree() {
    src=$1
    [ -d "$src/.git" ] || return 0
    if [ -n "$(cd "$src" && git status --porcelain 2>/dev/null)" ]; then
        say "source tree is dirty (patches already applied?): restoring the pristine ref in $src"
        # `git checkout -- .` restores from the INDEX, not from HEAD: if somebody ran
        # `git add` in the source tree (or the tooling did it for us), the content of
        # some patches stays in the index and gets written out again; later patches then
        # apply on top and get duplicated (measured: "error: redefinition of
        # nvlegacy_rt_alias" from 0058 applied twice, and the guard of 0045 duplicated
        # with a stale enum table, which broke Nalu shadows for days).  `git reset
        # --hard HEAD` plus clearing the index makes the patch series the single source
        # of truth.
        (cd "$src" && git reset -q --hard HEAD && git clean -qfd && git checkout -q -- .) || die "restore failed in $src"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mesa-only)      DO_WINE=0 ;;
        --wine-only)      DO_MESA=0 ;;
        --configure-only) CONFIGURE_ONLY=1 ;;
        --reconfigure)    RECONFIGURE=1 ;;
        --wine-diag)      WINE_WITH_DIAG=1 ;;
        --no-wine-diag)   WINE_WITH_DIAG=0 ;;
        --mesa-diag)      MESA_WITH_DIAG=1 ;;
        --no-mesa-diag)   MESA_WITH_DIAG=0 ;;
        --release)        BUILD_MODE=release; MESA_WITH_DIAG=0; WINE_WITH_DIAG=0
                          MESA_BUILDTYPE=release ;;
        --debug)          BUILD_MODE=debug; MESA_WITH_DIAG=1; WINE_WITH_DIAG=1
                          MESA_BUILDTYPE=debug ;;
        --no-patches)     NO_PATCHES=1 ;;
        --clean-wine|--pulisci-wine)   CLEAN_WINE=1 ;;
        --fresh)          FRESH=1 ;;
        --src)            [ $# -ge 2 ] || die "--src needs a directory"; SRC=$2; MESA_SRC=$SRC/mesa; WINE_SRC=$SRC/wine; shift ;;
        --out)            [ $# -ge 2 ] || die "--out needs a directory"; OUT=$2; MESA_BUILD=$OUT/work-mesa; WINE_BUILD=$OUT/work-wine; MESA_PREFIX=$OUT/mesa; WINE_PREFIX=$OUT/wine; OUT_EXPLICIT=1; shift ;;
        -h|--help)        sed -n '2,/^set -eu$/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Release mode writes into ./build-release unless a place was asked for.  Passing --release
# alone used to write features-only modules over ./build, which is the tree run.sh uses by
# default: measured on 2026-11-05 that removed the diagnostics from the debug tree without
# anyone touching the source, and the next demo run produced 113 log lines instead of 6650
# with no MESA-NV tracing at all - it read as a change in the demo's behaviour, and it was a
# build mistake.  The two modes also apply different series to the same source tree, so they
# must not run concurrently; keeping them in different output directories makes that harder
# to do by accident.  tools/nv_record_trace.sh tells the user to run "build.sh --release"
# and then looks for build-release/wine/bin/wine: with this default that advice works.
if [ "$BUILD_MODE" = release ] && [ "$OUT_EXPLICIT" != 1 ] && [ "$OUT" = "$DIR/build" ]; then
    OUT=$DIR/build-release
    MESA_BUILD=$OUT/work-mesa
    WINE_BUILD=$OUT/work-wine
    MESA_PREFIX=$OUT/mesa
    WINE_PREFIX=$OUT/wine
    say "release mode: writing to $OUT (pass --out or NV_BUILD to choose another place)"
fi


git_head() { (cd "$1" && git rev-parse --short HEAD 2>/dev/null) || echo "(not git)"; }

# Clone (or update) a repository to the requested ref.
fetch_src() {
    url=$1; ref=$2; dest=$3; expect=$4
    if [ "$FRESH" = "1" ] && [ -d "$dest" ]; then
        say "removing $dest (--fresh)"
        rm -rf "$dest"
    fi
    if [ -d "$dest/.git" ]; then
        have=$(git_head "$dest")
        # An interrupted clone leaves .git without HEAD: git_head() RETURNS the string
                # "(not git)", it does not return an empty string, so testing -z alone is not
                # enough.
        if [ -z "$have" ] || [ "$have" = "(not git)" ]; then
            say "  ERROR: $dest has .git but no valid HEAD (interrupted clone?)"
            die "delete $dest and try again, or use --fresh"
        fi
        say "source already present: $dest (HEAD $have)"
        if [ "$have" != "$expect" ] && [ -n "$expect" ]; then
            # Do not touch a tree that has local changes or local commits: the toolchain
                        # patches (and the diagnostics) live exactly there.  Checking out
                        # FETCH_HEAD would erase everything (it really happened: Wine patches lost
                        # and a build of pristine Wine).
            if [ -n "$(git -C "$dest" status --porcelain)" ]; then
                say "  notice: the tree has local changes: NOT resetting it (use --fresh for the pristine ref)"
            elif git -C "$dest" merge-base --is-ancestor "$expect" HEAD 2>/dev/null; then
                say "  notice: HEAD is a descendant of $expect (local commits): using the local tree"
            else
                say "  HEAD differs from the tested one ($expect): trying to move it to $ref"
                (cd "$dest" && git fetch --depth 1 origin "$ref" && git checkout -q FETCH_HEAD) ||
                    say "  notice: the update did not work, using the current tree"
            fi
        fi
    else
        # Real case: the directory exists but is NOT a git repository (unpacked from a
                # GitHub zip/tarball, or a clone interrupted before .git was created).  git
                # clone would complain with a generic message; here we say it plainly.
        if [ -d "$dest" ] && [ ! -d "$dest/.git" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            say "  ERROR: $dest exists, is not empty and is not a git repository"
            say "  (it looks like an unpacked GitHub archive, or an interrupted clone: git clone would stop there)"
            die "delete $dest (or use --fresh), or point at a tree you already have: WINE_SRC=/path/to/tree"
        fi
        mkdir -p "$(dirname "$dest")"
        say "clone $url (ref $ref) -> $dest"
        # No --quiet: a network failure on a large repository has to show the reason.
        git clone --depth 1 --branch "$ref" "$url" "$dest" ||
            die "clone failed: $url $ref -- typical causes: a network or proxy problem, or
  the ref does not exist (list the available refs with git ls-remote --heads $url).  If
  you already have a suitable tree, point at it instead of downloading: MESA_SRC=...
  or WINE_SRC=..."
    fi
    head=$(git_head "$dest")
    say "  HEAD: $head  $(cd "$dest" && git log -1 --format='%ad %s' --date=short 2>/dev/null)"
    if [ -n "$expect" ] && [ "$head" != "$expect" ]; then
        say "  WARNING: HEAD $head differs from $expect (the ref the patches were proven against)"
    fi
}

# The GENERATED series (patches/{mesa,wine}/000N-*.patch) need a pristine base and an
# all-or-nothing application.  The `patch -p1` fallback (which tolerates fuzz) on an
# already patched tree had produced a garbled tree: "1 out of 5 hunks FAILED",
# "Unreversed patch detected! Ignore -R? [n]", and the build then blew up with
# meaningless errors ("invalid storage class for function") that I read for hours as
# if they were a features/diagnostics split problem.  Here the series is the single
# source of truth: if a hunk does not apply cleanly, the build STOPS instead of
# continuing on a partial tree.
# touch_series_files <src> <patch...>: after applying, touch every file the series
# touches.  Why: ninja and make decide from file dates and sizes, and measured on
# 2026-11-04 at 13:50 the Mesa debug build had the new series in the tree (the renamed
# identifiers were already there) but did NOT recompile anything: the only progress
# lines were "Generating src/git_sha1.h" and "Installing files", and the md5 of the
# installed libgallium was identical to the previous build.  The 08:59 build was in
# the same state (0 compilation units).  This is the same class as the stale Wine
# build of 3 November, which for Wine we had only covered with the guard on the
# installed modules.  Touching the files removes the indeterminacy.
touch_series_files() {
    local src=$1 p n=0 f
    shift
    # This must NOT be `local`: the caller needs the list (verify_recompilation).
        # Measured: declared local, the guard checked zero files and reported success.
    TOUCHED_FILES=()
    for p in "$@"; do
        while read -r f; do
            [ -n "$f" ] || continue
            if [ -e "$src/$f" ]; then touch "$src/$f"; n=$((n+1)); TOUCHED_FILES+=("$f"); fi
        done < <(grep -a '^diff --git' "$p" 2>/dev/null | sed 's|^diff --git a/||; s| b/.*||')
    done
    say "  touched $n files of the series (so make/ninja cannot claim they are up to date)"
}

# compile_accounting <log> <label>: a build that applies a series and
# compiles nothing is leaving old modules installed: that has to be an error, not an
# rc=0.
compile_accounting() {
    local log=$1 name=$2 expected=$3 n
    n=$(grep -acE 'Compiling|\bCC\b|Linking target|Linking static target' "$log" 2>/dev/null)
    [ "$n" = "" ] && n=0
    if [ "$expected" -gt 0 ] && [ "$n" -lt 1 ]; then
        say "  ERROR $name: the series was applied but NO file was compiled: the installed modules stay old"
        return 1
    fi
    say "  $name: $n compile/link actions recorded"
    return 0
}

# verify_recompilation <name> <build-dir> <files-touched-by-the-series...>:
# for every source touched by the series there must be, in the build directory, an
# object with that base name NEWER than the .nv-build-start marker written at the
# start of the build.  If it is missing, the installed modules come from older
# sources: the same class as the two real incidents (Wine on 3 November: stale
# work-wine whose modules lacked our keys; Mesa on 4 November: series applied, zero
# compilation units, md5 unchanged).
verify_recompilation() {
    local name=$1 build=$2; shift 2
    local marker="$build/.nv-build-start" f missing=0 seen=0
    [ -f "$marker" ] || { say "  $name: no build-start marker: check skipped"; return 0; }
    for f in "$@"; do
        # only sources that produce an object: a header (or a script) has NO
        # matching .o, and including them forces a search for an artefact that does
        # not exist.  Measured: 25 "missing" entries were all .h/.py/.in/.def files
        # of our series.
        case "$f" in *.c|*.cc|*.cpp|*.S|*.s) ;; *) continue ;; esac
        seen=$((seen+1))
        local base=$(basename "$f") obj base_without_ext
        # The two projects name objects differently: meson prefixes them with the
        # directory (src/mesa/main/nv_extensions.c -> main_nv_extensions.c.o), Wine's
        # make calls them dlls/win32u/opengl.o (without the .c).  The search has to
        # cover both.  Measured during the night of 2026-11-04: the first version
        # looked for nv_extensions.o and claimed "154 of 154 files not recompiled"
        # while 300 units had just been compiled; the second one, because of a typo
        # (base_without_ext written as name_senza_est), claimed the same for Wine after
        # a 4-minute from-scratch build with --clean-wine.  A guard that shouts
        # because of its own bug makes correct builds fail: that is worse than no
        # guard at all, because people learn to ignore it.
        base_without_ext=${base%.*}
        for pattern in "*${base}.o" "${base_without_ext}.o" "*${base_without_ext}.o"; do
            obj=$(find "$build" -name "$pattern" -newer "$marker" -type f 2>/dev/null | head -1)
            [ -n "$obj" ] && break
        done
        if [ -z "$obj" ]; then
            missing=$((missing+1))
            [ $missing -le 4 ] && say "      $name: no artefact newer than the build marker for $f"
        fi
    done
    if [ $missing -gt 0 ]; then
        say "  ERROR $name: $missing of $seen series files were not recompiled: the installed modules are old"
        say "        (how to fix: rm -rf the work dir, or ./build.sh --clean-wine for Wine)"
        return 1
    fi
    say "$name: recompilation verified for $seen files of the series"
    return 0
}

# configured_source_root <work-dir>: reads from the meson/make metadata which
# tree the work dir is already compiling.
configured_source_root() {   # <work-dir> <expected-source>
    # Why this exists: if the work dir was configured on a different tree than the one we
    # are patching, the build does not fail - it recompiles the OTHER tree and installs
    # modules that do not come from the series we believe we applied.  The previous
    # version grepped for a hard-coded home directory, so on any other machine it found
    # nothing and the guard switched itself off in silence.
    #
    # The authoritative record, measured on a real meson build dir, is the regenerate
    # rule inside build.ninja: it carries the ABSOLUTE source directory.  Compiler flags
    # are NOT usable for this: a first version of this function returned "-I../../mesa-src",
    # which is a flag, not a root, and would have made correct builds fail.
    local w=$1 src=$2 hit
    if [ -f "$w/build.ninja" ]; then
        hit=$(grep -am1 -- '--internal regenerate' "$w/build.ninja" 2>/dev/null |
              awk '{ for (i = 1; i <= NF; i++) if ($i == "regenerate") { print $(i+1); exit } }')
        if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    fi
    if [ -f "$w/Makefile" ]; then
        hit=$(grep -am1 '^srcdir *=' "$w/Makefile" 2>/dev/null | sed 's/^srcdir *= *//')
        if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    fi
    printf ''
}

# verify_work_dir_source <name> <work-dir> <expected-source>: if the work dir was
# configured on a tree different from the one we are patching, the build does NOT
# fail: it simply recompiles the OTHER tree, i.e. it installs modules produced from
# sources that are not the series we believe we applied.  Measured 2026-11-04: two
# invocations with --src pointing at a scratch source directory patched that tree
# while ninja was compiling ../../mesa-src (object stuck at 3 November 13:16), and
# the log reported rc=0 with zero compilation units.
verify_work_dir_source() {
    local name=$1 work=$2 src=$3 cfg
    [ -d "$work" ] || return 0
    cfg=$(configured_source_root "$work" "$src")
    if [ -z "$cfg" ]; then
        say "  $name: cannot read the configured source root in $work (check skipped)"
        return 0
    fi
    if [ "$(realpath -q "$cfg")" != "$(realpath -q "$src")" ]; then
        say "  ERROR $name: the work dir $work compiles $cfg, but the source being patched is $src"
        say "        (a build like that installs modules produced by a tree other than the series applied)"
        say "        how to fix: do not pass --src, or delete the work dir, or re-run with NV_SRC=$cfg"
        return 1
    fi
    say "  $name: work dir and source agree ($src)"
    return 0
}

apply_series_strict() {
    src=$1
    shift
    for p in "$@"; do
        [ -e "$p" ] || die "series patch not found: $p"
        if (cd "$src" && git apply -R --check "$p") 2>/dev/null; then
            die "the series is already applied in $src: the tree is not pristine"
        fi
        if ! (cd "$src" && git apply --check "$p") 2>/dev/null; then
            say "  ERROR: $(basename "$p") does not apply cleanly on $src (HEAD $(git_head "$src"))"
            (cd "$src" && git apply --check -v "$p" 2>&1 | head -4) | sed 's/^/      /'
            die "series not applicable: restore the pristine base (git -C $src reset --hard HEAD; git -C $src clean -fd), or use --no-patches with an annotated tree"
        fi
        (cd "$src" && git apply "$p") || die "git apply failed on $(basename "$p")"
        say "  series applied: $(basename "$p")"
    done
    touch_series_files "$src" "$@"
}

apply_patch() {
    src=$1; patch=$2; soft=${3:-0}
    [ -d "$src" ] || die "source not found: $src"
    [ -f "$patch" ] || die "patch not found: $patch"
    # Mesa applies its series through apply_patch, not apply_series_strict: the list
    # of touched files has to be collected here as well, otherwise the recompilation
    # check has nothing to verify (a safety false positive).
    if [ -z "${TOUCHED_FILES[*]:-}" ]; then TOUCHED_FILES=(); fi
    while read -r f; do [ -n "$f" ] && TOUCHED_FILES+=("$f"); done \
        < <(grep -a '^diff --git' "$patch" 2>/dev/null | sed 's|^diff --git a/||; s| b/.*||')
    if (cd "$src" && git apply -R --check "$patch") 2>/dev/null; then
        say "patch already applied: $(basename "$patch")"
        return 0
    fi
    if (cd "$src" && git apply --check "$patch") 2>/dev/null; then
        (cd "$src" && git apply "$patch")
        { local f; for f in "${TOUCHED_FILES[@]:-}"; do [ -e "$src/$f" ] && touch "$src/$f"; done; } || true
        say "patch applied: $(basename "$patch")"
        return 0
    fi
    # Reverse check with `patch`: `git apply -R --check` does not recognise as
    # already applied those patches that touch REGENERATED files (for us
    # dlls/opengl32/unix_thunks.c and include/wine/opengl_driver.h, regenerated by
    # make_opengl), and reported "impossible to apply
    # 0001-nv-wgl-on-bleeding-edge.patch" even though the patch was already in.  If
    # the reverse applies cleanly, the patch is inside.
    if (cd "$src" && patch -p1 -R --dry-run --silent < "$patch") 2>/dev/null; then
        say "patch already applied (reverse check): $(basename "$patch")"
        return 0
    fi
    if (cd "$src" && patch -p1 --dry-run --silent < "$patch") 2>/dev/null; then
        (cd "$src" && patch -p1 --silent < "$patch")
        say "patch applied with patch -p1: $(basename "$patch")"
        return 0
    fi
    # Last chance: `patch -N --forward` ignores hunks that are already in and applies
    # only the others.  But first we look at the dry-run: if there are hunks that
    # really FAIL (files regenerated by make_opengl, or hand-made edits) we do not
    # even try to write half a patch here and there.
    # The `|| true` is indispensable: build.sh runs with set -e and patch returns 1
    # even for hunks that are merely already applied; without it the assignment kills
    # the script before the warning is printed (measured: RC=1 and no warning line).
    out=$(cd "$src" && patch -p1 -N --forward --dry-run < "$patch" 2>&1) || true
    if ! printf '%s\n' "$out" | grep -q "FAILED"; then
        (cd "$src" && patch -p1 -N --forward -s < "$patch" >/dev/null 2>&1) || true
        say "patch already partly present (hunks ignored, none failed): $(basename "$patch")"
        return 0
    fi
    if [ "$soft" = "1" ]; then
        say "WARNING: $(basename "$patch") has hunks that do not apply on a tree that already"
        say "  carries our changes (regenerated files or hand-made edits): SKIPPING IT."
        say "  NEW patches are applied anyway.  If a clean chain is needed:"
        say "(then build again)"
        printf '%s\n' "$out" | grep "FAILED" | head -4 | sed 's/^/    /'
        return 1
    fi
    die "cannot apply $(basename "$patch") on $src (different ref or dirty tree)"
}

# ---------------------------------------------------------------------------
# Mesa
# ---------------------------------------------------------------------------
build_mesa() {
    command -v meson >/dev/null || die "meson is not installed"
    command -v ninja >/dev/null || die "ninja is not installed"
    fetch_src "$MESA_URL" "$MESA_REF" "$MESA_SRC" "$MESA_SEEN_COMMIT"
    if [ "$NO_PATCHES" != "1" ]; then
        pristine_tree "$MESA_SRC"
        for p in "$MESA_PATCH_DIR"/*.patch; do
            [ -e "$p" ] || die "no patch in $MESA_PATCH_DIR"
            # The diagnostics series (knobs, traces, dumps) is optional: a release build
            # leaves it out, and doing so is also the test that 0001 stands on its own.
            case "$(basename "$p")" in
                $MESA_DIAG_GLOB)
                    if [ "$MESA_WITH_DIAG" = "1" ]; then
                        say "  Mesa diagnostics INCLUDED: $(basename "$p")"
                    else
                        say "  Mesa diagnostics EXCLUDED: $(basename "$p")"
                        continue
                    fi ;;
            esac
            apply_patch "$MESA_SRC" "$p"
        done
    fi

    if [ "$MESA_LLVM" = "0" ] || [ "$MESA_LLVM" = "disabled" ]; then
        llvm_opt=disabled; shared_llvm=disabled; draw_llvm=false
    else
        llvm_opt=enabled; shared_llvm=enabled; draw_llvm=true
    fi

    # zink is a Vulkan frontend: by default we do NOT build a Vulkan driver here,
    # zink uses the system one (for example
    # /usr/share/vulkan/icd.d/radeon_icd.json).  With MESA_DRIVERS=zink and an empty
    # MESA_VULKAN the build runs on any GPU that already has a Vulkan ICD installed.
    # MESA_VULKAN=amd carries radv inside this build instead.
    opts="--prefix=$MESA_PREFIX --libdir=lib64 --buildtype=$MESA_BUILDTYPE"
    opts="$opts -Dplatforms=x11 -Dglx=dri -Dglvnd=disabled -Dglx-direct=true"
    opts="$opts -Dopengl=true -Dgles1=disabled -Dgles2=enabled"
    opts="$opts -Dgallium-drivers=$MESA_DRIVERS -Dvulkan-drivers=$MESA_VULKAN"
    opts="$opts -Dllvm=$llvm_opt -Dshared-llvm=$shared_llvm -Ddraw-use-llvm=$draw_llvm"
    opts="$opts -Dtools=nir -Dvideo-codecs= -Dvalgrind=disabled -Dbuild-tests=false"
    opts="$opts -Dgallium-rusticl=false -Dxmlconfig=auto -Dshader-cache=auto"
    if [ "$BUILD_MODE" = release ]; then
        opts="$opts -Dstrip=true -Db_ndebug=true"
    elif [ "$BUILD_MODE" = debug ]; then
          opts="$opts -Ddebug=true -Dstrip=false -Db_ndebug=false"
    #  -Db_ndebug=false is needed because meson --reconfigure keeps the previous value:
    #    going from --release to --debug without this line left b_ndebug=true (measured in
    #    the summary: buildtype debug with b_ndebug true), so assertions stayed compiled
    #    out even in a build that claimed to be debug.
    fi
    [ -n "$MESA_EXTRA_OPTS" ] && opts="$opts $MESA_EXTRA_OPTS"

    # Guard on the build mode: an already configured work dir does not change its own
    # options.  Measured in the log of `./build.sh --release`: the line said "build dir
    # already configured", no reconfigure happened, so the installed Mesa stayed
    # configured as debugoptimized while wine.env declared NV_BUILD_MODE="release" -
    # neither release nor debug: a third thing nobody had asked for.  Now the requested
    # options are compared with the ones recorded in the work dir; if they differ, the
    # configuration is redone by itself.
    stamp="$MESA_BUILD/nv-build-opts.stamp"
    if [ -f "$MESA_BUILD/build.ninja" ] && [ "$RECONFIGURE" = "0" ] \
       && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$opts" ]; then
        say "Mesa: work dir already configured with the options of the requested mode: $MESA_BUILD"
    elif [ -f "$MESA_BUILD/build.ninja" ]; then
        if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$opts" ]; then
            say "Mesa: the requested mode has options different from the configured ones: reconfiguring"
        fi
        # shellcheck disable=SC2086
        meson setup --reconfigure $opts "$MESA_BUILD" "$MESA_SRC" || die "meson reconfigure failed"
        printf '%s' "$opts" > "$stamp"
    else
        mkdir -p "$MESA_BUILD"
        # shellcheck disable=SC2086
        meson setup $opts "$MESA_BUILD" "$MESA_SRC" || die "meson setup failed"
        printf '%s' "$opts" > "$stamp"
    fi

    if [ "$CONFIGURE_ONLY" = "1" ]; then
        say "Mesa: setup completed (--configure-only)"
        return 0
    fi

    say "Mesa: ninja -j $JOBS (drivers=$MESA_DRIVERS vulkan=$MESA_VULKAN llvm=$llvm_opt)"
    series_file_list="$MESA_BUILD/nv-series-files.txt"
    verify_work_dir_source Mesa "$MESA_BUILD" "$MESA_SRC" || die "Mesa source and work dir do not agree"
    touch "$MESA_BUILD/.nv-build-start" 2>/dev/null || true
    ninja -C "$MESA_BUILD" -j "$JOBS"
    ninja -C "$MESA_BUILD" install
    strip_installed "$MESA_PREFIX"
    verify_recompilation Mesa "$MESA_BUILD" "${TOUCHED_FILES[@]:-}"
    realign_annotated_tree Mesa "$MESA_SRC" "$DIR/patches/mesa/0002-nv-legacy-diagnostics.patch" "${MESA_WITH_DIAG:-1}"
    lib=$(ls "$MESA_PREFIX"/lib64/libgallium-*.so 2>/dev/null | head -1)
    [ -n "$lib" ] && say "installed: $lib  md5 $(md5sum "$lib" | cut -d' ' -f1)"
}

# ---------------------------------------------------------------------------
# Wine
# ---------------------------------------------------------------------------
build_wine() {
    if [ "${CLEAN_WINE:-0}" = "1" ]; then
        say "Wine: --clean-wine: removing $WINE_BUILD and $WINE_PREFIX"
        rm -rf "$WINE_BUILD" "$WINE_PREFIX"
    fi
    fetch_src "$WINE_URL" "$WINE_REF" "$WINE_SRC" "$WINE_SEEN_COMMIT"
    if [ "$NO_PATCHES" != "1" ]; then
        # State of the tree, decided by elimination and SPOKEN OUT LOUD:
        #   * dirty working tree -> it is leftovers from a previous run or from an
        #     experiment: the series is the single source of truth, so we RESTART from
        #     pristine.  This is the case that burned my evening: I had applied
        #     0001+0002 by hand, the script had "recognised" the changes as ours and had
        #     left half-applied patches with fuzz.
        #   * local commits of the series -> we cannot tell a build with diagnostics
        #     from one without them: that needs already-patched sources, so an explicit
        #     --no-patches is required instead of guessing.
        if [ -n "$(git -C "$WINE_SRC" status --porcelain 2>/dev/null)" ]; then
            say "Wine source is dirty: restoring the pristine tree because the series is the single source of truth"
            pristine_tree "$WINE_SRC"
        elif (cd "$WINE_SRC" && git log --format='%s' 2>/dev/null | grep -qm1 '^nv-legacy:'); then
            die "the Wine series is committed locally in $WINE_SRC: a committed series does not say whether it includes the diagnostics, so --release/--debug would be meaningless here.  Use ./build.sh --no-patches (annotated tree), or bring the tree back to the pristine ref."
        fi
        wine_series=()
        for p in "$WINE_PATCH_DIR"/*.patch; do
            [ -e "$p" ] || die "no patch in $WINE_PATCH_DIR"
            # The diagnostics series (0002-*-diagnostics) can be left out entirely:
            case "$(basename "$p")" in
                $WINE_DIAG_GLOB)
                    if [ "$WINE_WITH_DIAG" = "1" ]; then
                        say "  Wine diagnostics INCLUDED: $(basename "$p")"
                    else
                        say "  Wine diagnostics EXCLUDED: $(basename "$p")"
                        continue
                    fi ;;
            esac
            wine_series+=("$p")
        done
        # Note about what is NOT in the series: a preloader patch ('%s64-preloader')
        # is not needed here, because our Wine 11.18 has no wine64-preloader in the
        # x86_64-unix layout.  Said here because the question comes up every time
        # somebody looks at the patches/wine/ directory.
        apply_series_strict "$WINE_SRC" "${wine_series[@]}"
        for p in $WINE_EXTRA_PATCHES; do
            [ -e "$p" ] || die "extra patch missing: $p"
            apply_patch "$WINE_SRC" "$p" 0
        done
    fi

    # In the git sources the generated files are not in the repository; without them
    # configure/makedep fails ("open wine/vulkan.h", "ntsyscalls.h: No such...").
    if [ ! -f "$WINE_SRC/configure" ]; then
        say "configure missing: generated with autoreconf"
        (cd "$WINE_SRC" && autoreconf -fiv) >/dev/null
    fi
    if [ ! -f "$WINE_SRC/dlls/ntdll/ntsyscalls.h" ] && [ -f "$WINE_SRC/tools/make_specfiles" ]; then
        say "generating the missing files (tools/make_specfiles)"
        (cd "$WINE_SRC" && ./tools/make_specfiles) >/dev/null
    fi
    if [ ! -f "$WINE_SRC/include/wine/vulkan.h" ] &&
       [ -f "$WINE_SRC/dlls/winevulkan/make_vulkan" ] &&
       [ -f "$WINE_SRC/dlls/winevulkan/vk.xml" ]; then
        say "generating include/wine/vulkan.h (make_vulkan)"
        (cd "$WINE_SRC" && python3 dlls/winevulkan/make_vulkan \
            -x "$WINE_SRC/dlls/winevulkan/vk.xml" \
            -X "$WINE_SRC/dlls/winevulkan/video.xml") >/dev/null
    fi

    # In Wine 11 some GENERATED headers are committed to the repository, but the
    # committed version of the server protocol does NOT contain the fsync constants
    # (FSYNC_MUTEX, FSYNC_QUEUE, FSYNC_SHM_PAGE_SIZE...).  In an out-of-tree build the
    # Makefile uses them as a dependency with NO generation rule: compilation fails
    # with "fsync constants not defined".  tools/make_requests regenerates them inside
    # the source tree (idempotent).
    if [ -x "$WINE_SRC/tools/make_requests" ] &&
       ! grep -q "FSYNC_MUTEX" "$WINE_SRC/include/wine/server_protocol.h" 2>/dev/null; then
        say "regenerating the server protocol headers (tools/make_requests)"
        (cd "$WINE_SRC" && ./tools/make_requests) >/dev/null || die "tools/make_requests failed"
        grep -q "FSYNC_MUTEX" "$WINE_SRC/include/wine/server_protocol.h" 2>/dev/null ||
            say "  WARNING: after make_requests the fsync constants are still missing"
    fi

    mkdir -p "$WINE_BUILD"
    # Marker of the configure options: build.sh does NOT re-run configure when the
    # build dir already exists.  An old configure (for example with the system FFmpeg)
    # produces errors like "unknown type name 'AVBSFInternal'" that look like mysteries:
    # here we make them visible.
    want="archs=$WINE_ARCHS extra='$WINE_EXTRA_CONFIGURE'"
    marker="$WINE_BUILD/.nv-legacy-config"
    if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" != "$want" ]; then
        say "  options requested now : $want"
        say "  options configured in : $(cat "$marker" 2>/dev/null)"
        die "the build dir $WINE_BUILD is already configured with different options: delete it, or point WINE_BUILD to a new directory"
    fi
    if [ ! -f "$WINE_BUILD/Makefile" ]; then
        say "Wine: configure (prefix $WINE_PREFIX, archs $WINE_ARCHS)"
        # shellcheck disable=SC2086
        (cd "$WINE_BUILD" && "$WINE_SRC/configure" --prefix="$WINE_PREFIX" \
            --enable-archs="$WINE_ARCHS" --disable-tests --with-x $WINE_EXTRA_CONFIGURE) &&
            printf '%s\n' "$want" > "$marker"
        [ -f "$marker" ] || say "  WARNING: configure did not finish: marker not written"
    else
        say "Wine: build dir already configured: $WINE_BUILD"
        wstamp="$WINE_BUILD/nv-build-mode.stamp"
        wine_mode="$BUILD_MODE diag=$WINE_WITH_DIAG"
        if [ -f "$wstamp" ] && [ "$(cat "$wstamp")" != "$wine_mode" ]; then
            say "Wine: the previous mode was $(cat "$wstamp"); the requested one is $wine_mode"
            say "Wine: the patches are re-applied from scratch, BUT binaries that are not relinked stay"
            say "Wine: stripped as in the previous build (only the patch files are touched)."
            say "Wine: for a 100% clean debug build: rm -rf $WINE_BUILD && ./build.sh --debug"
        fi
        printf '%s' "$wine_mode" > "$wstamp"
    fi

    if [ "$CONFIGURE_ONLY" = "1" ]; then
        say "Wine: configure completed (--configure-only)"
        return 0
    fi

    if [ -f "$WINE_BUILD/Makefile" ]; then
        # The old parsing used grep -aomE "srcdir *= *[^ ]*": that grep FAILS ("invalid max
        # count"), cfgw came out empty, the comparison was skipped and the line below still
        # printed "work dir and source agree".  A guard that reports agreement without ever
        # measuring is worse than no guard.  Now: parse with sed, and speak of agreement only
        # when the comparison actually ran.
        cfgw=$(sed -n 's/^srcdir *= *//p' "$WINE_BUILD/Makefile" 2>/dev/null | head -1)
        if [ -z "$cfgw" ]; then
            say "  Wine: cannot read srcdir from $WINE_BUILD/Makefile: coherence NOT checked"
        elif [ "$(realpath -q "$cfgw")" != "$(realpath -q "$WINE_SRC")" ]; then
            if [ "$NO_PATCHES" = "1" ]; then
                say "  WARNING Wine: the work dir $WINE_BUILD compiles $cfgw, while WINE_SRC is $WINE_SRC."
                say "          With --no-patches nothing is patched here, so the binaries come from the"
                say "          first tree: that may be intended (annotated dev tree), but it is NOT this tree."
            else
                die "Wine: the work dir $WINE_BUILD is configured on $cfgw, but the source being patched is $WINE_SRC: delete the work dir or align --src (otherwise the series is applied to a tree that is never compiled)"
            fi
        else
            say "  Wine: work dir and source agree ($WINE_SRC)"
        fi
    fi
    touch "$WINE_BUILD/.nv-build-start" 2>/dev/null || true
    say "Wine: make -j $JOBS (this can take several minutes)"
    make -C "$WINE_BUILD" -j "$JOBS"
    make -C "$WINE_BUILD" install
    strip_installed "$WINE_PREFIX"
    say "installed: $($WINE_PREFIX/bin/wine --version 2>/dev/null || echo '?')"
    wine_installed_is_patched
    verify_recompilation Wine "$WINE_BUILD" "${TOUCHED_FILES[@]:-}"
    realign_annotated_tree Wine "$WINE_SRC" "$DIR/patches/wine/0002-nv-legacy-diagnostics.patch" "${WINE_WITH_DIAG:-1}"
}

# realign_annotated_tree: after a features-only build the annotated source tree is
# left as "pristine + 0001", i.e. partial.  That is a trap, because the series are
# generated FROM that tree: measured 2026-11-04 at 07:27, with the partial tree
# make_nv_patches wrote a zero-byte 0002 and replaced the committed one (the generator
# noticed and stopped, but the files had already been rewritten).  Here the diagnostics
# series is put back, so the tree returns to being the one state from which the series
# can be generated and compared.
realign_annotated_tree() {   # <name> <tree> <diagnostics-series> <with-diagnostics>
    local name=$1 src=$2 diag=$3 with_diag=$4
    [ "$with_diag" = "1" ] && return 0
    [ -d "$src" ] || { say "$name: source tree missing ($src)"; return 0; }
    if [ ! -f "$diag" ]; then
        say "Wine: no 0002 on disk: the annotated tree stays as it was at build time"
        return 0
    fi
    if (cd "$src" && git apply -R --check "$diag") 2>/dev/null; then
        return 0
    fi
    if (cd "$src" && git apply --check "$diag") 2>/dev/null; then
        (cd "$src" && git apply "$diag") &&
            say "$name: annotated tree restored to the complete state (0002 re-applied)"
    else
        say "NOTICE $name: 0002 cannot be re-applied to $src: do not generate series from this tree"
        (cd "$src" && git apply --check -v "$diag" 2>&1 | head -3) | sed 's/^/      /'
    fi
}

# wine_installed_is_patched: an anti-staleness guard, wanted by a real incident
# (2026-11-03).  A work dir (work-wine) that is already populated, holding binaries
# from a previous build made from the CLEAN tree, does not force make to recompile:
# the patches are re-applied to the sources but the installed modules stay unpatched.
# Observed symptom: winex11.so without our keys, Wine using EGL instead of GLX,
# WGL_NV_vertex_array_range and wglAllocateMemoryNV disappearing, and the demos
# refusing to start with a message about the missing extension - while the build said
# rc=0.  That is why TWO things are checked, both independent of the fullscreen hack:
#   1) the installed X11 module contains the string WINE_USE_EGL, which exists only
#      thanks to our series (upstream does not have it);
#   2) the win32u module contains WINE_NV_TRACE, a marker of the features.
#   (A check on source file dates was tried and REMOVED: the debug and release builds
#    share the same source tree, so building debug touches the sources and would make
#    the good release binaries look "stale".)
wine_installed_is_patched() {
    local dir="$WINE_PREFIX/lib/wine/x86_64-unix" drv so broken=0 f
    [ -f "$dir/winex11.so" ] || { say "Wine: marker check skipped (no winex11.so in $dir)"; return 0; }
    drv=$dir/winex11.so
    if [ "$(strings "$drv" 2>/dev/null | grep -ac WINE_USE_EGL)" -eq 0 ]; then
        say "WARNING: $drv does NOT contain WINE_USE_EGL: the installed module lacks our patches"
        broken=1
    fi
    # (2) the same check on the win32u module, with a marker that lives in the
    #     features (not in the diagnostics and not in the fullscreen hack).
    local w32="$WINE_PREFIX/lib/wine/x86_64-unix/win32u.so"
    if [ -f "$w32" ] && [ "$(strings "$w32" 2>/dev/null | grep -ac WINE_NV_TRACE)" -eq 0 ]; then
        say "WARNING: $w32 does NOT contain WINE_NV_TRACE: this module lacks our patches too"
        broken=1
    fi
    if [ "$broken" -ne 0 ]; then
        die "installed Wine modules are inconsistent with the patched sources: delete the work dir (--clean-wine, or rm -rf $WINE_BUILD $WINE_PREFIX) and run build.sh again."
    fi
    say "Wine: installed modules agree with the series (markers present)"
}

# strip_installed <dir>: in release mode drops debug symbols from the installed tree.
# ELF files go through binutils strip. The Wine guest binaries are PE (dlls and programs:
# .dll, .exe, .sys) and they carry DWARF too: measured on 2026-11-08, before this change
# build-release/wine/lib/wine/x86_64-windows/ntdll.dll was 4945734 bytes with 8 .debug_*
# sections and kernel32.dll 2496559 bytes with 8. The previous version skipped PE on
# purpose, because GNU binutils strip cannot write COFF and a corrupt PE would be an
# extremely confusing failure. It can be done safely, but the tool has to be picked:
# llvm-strip handles most of the tree (1550 files, Wine 1.8G -> 745M) yet refuses some
# modules with "invalid SymbolTableIndex" - measured on bcrypt.dll in both arches and on
# icu.dll - while x86_64-w64-mingw32-strip handles those too (i386 bcrypt 2454733 ->
# 572855 bytes, x86_64 bcrypt 2973870 -> 411329, 0 debug sections in both cases, and that
# mingw strip also accepts the i386 files). So the mingw binutils come first and llvm-strip
# is the fallback. The stripped modules were then run: window up, zero exceptions, zero
# page faults.
strip_installed() {
    [ "$BUILD_MODE" = release ] || return 0
    local root=$1 n_elf=0 n_pe=0 n_pe_falliti=0 f mt pe_tool size_prima
    local prima=0 dopo=0
    [ -d "$root" ] || return 0
    pe_tool=""
    for candidato in x86_64-w64-mingw32-strip i686-w64-mingw32-strip llvm-strip; do
        if command -v "$candidato" >/dev/null 2>&1; then pe_tool=$(command -v "$candidato"); break; fi
    done
    while IFS= read -r f; do
        mt=$(file -b --mime-type "$f" 2>/dev/null)
        case "$mt" in
            application/x-sharedlib|application/x-pie-executable|application/x-executable)
                strip --strip-unneeded "$f" 2>/dev/null && n_elf=$((n_elf+1)) ;;
            application/vnd.microsoft.portable-executable)
                if [ -z "$pe_tool" ]; then
                    n_pe_falliti=$((n_pe_falliti+1))
                    continue
                fi
                # Prefiltro a byte: cercare il testo ".debug_" costa molto meno che chiamare
                # objdump su 1601 file a ogni build. I candidati che hanno quel testo nei dati
                # (dbghelp.dll, che di debug info si occupa) costano solo una strip che non
                # trova niente da togliere.
                if ! LC_ALL=C grep -qa '\.debug_' "$f" 2>/dev/null; then continue; fi
                size_prima=$(stat -c %s "$f")
                if "$pe_tool" --strip-unneeded "$f" 2>/dev/null &&
                   ! objdump -h "$f" 2>/dev/null | awk '{print $2}' | grep -q '^\.debug_'; then
                    n_pe=$((n_pe+1))
                    prima=$((prima + size_prima))
                    dopo=$((dopo + $(stat -c %s "$f")))
                else
                    n_pe_falliti=$((n_pe_falliti+1))
                    if [ $n_pe_falliti -le 6 ]; then
                        say "release: strip PE NON riuscito su $f con $pe_tool"
                    fi
                fi ;;
        esac
    done < <(find "$root" -type f 2>/dev/null)
    say "release: symbols stripped from $n_elf ELF files under $root"
    if [ -n "$pe_tool" ]; then
        say "release: symbols stripped from $n_pe PE guest files under $root ($pe_tool), $prima -> $dopo byte, $n_pe_falliti falliti"
    else
        say "release: ATTENZIONE, nessun strip che scriva COFF: $n_pe_falliti PE lasciati con i simboli di debug"
    fi
}


write_env_file() {
    mkdir -p "$OUT"
    cat > "$OUT/wine.env" <<EOF
# generated by build.sh on $(date -Iseconds)
# sources: $SRC   build: $OUT
export LD_LIBRARY_PATH="$MESA_PREFIX/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$MESA_PREFIX/lib64/dri"
export MESA_LOADER_DRIVER_OVERRIDE=\${MESA_LOADER_DRIVER_OVERRIDE:-zink}
export mesa_glthread=false
export MESA_MAX_TEXTURE_IMAGE_UNITS=16
export WINE_USE_EGL=0
# Build mode of this installation.  A release build has NO diagnostics series at all,
# so every MESA_NV_TRACE_* / WINE_NV_TRACE_* knob documented in patches/*/doc.md is
# simply absent there: this line is how a reader finds that out.
export NV_BUILD_MODE="$BUILD_MODE"
export NV_MESA_WITH_DIAG="$MESA_WITH_DIAG"
export NV_WINE_WITH_DIAG="$WINE_WITH_DIAG"
export PATH="$WINE_PREFIX/bin:\$PATH"
export WINE="\$WINE_PREFIX/bin/wine"
EOF
    say "wrote $OUT/wine.env (export it to use the Wine+Mesa of this build)"
}

[ "$DO_MESA" = "1" ] && build_mesa
[ "$DO_WINE" = "1" ] && build_wine
write_env_file
say "mode: $BUILD_MODE (Mesa diagnostics=$MESA_WITH_DIAG, Wine diagnostics=$WINE_WITH_DIAG)"
say "Mesa: $MESA_PREFIX   Wine: $WINE_PREFIX"
say "to run a demo: $DIR/run.sh  (it picks the build tree of this repository on its own)"
say "done"
