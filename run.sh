#!/usr/bin/env bash
#
# run.sh - start ONE of the ten NVIDIA tech demos this toolchain was built for.
#
#   ./run.sh <demo>
#
# with <demo> one of:  gas vulcan dusk dawn blobby truck toys cs timbury nalu luna mike
# Called without an argument (or with an unknown one) it prints that list and stops:
# there is deliberately no other command-line switch.
#
# What this script is:
#   1. a block of exports that are the SAME for every demo;
#   2. one if-block per demo, which sets that demo's own knobs and starts it.
# Everything else that used to live here (info mode, cmd.exe, shell, menu, the
# hand-made fallback layouts, the per-exe detection, the archived knobs, the
# leftovers of several hundred experiments) was removed on purpose: it made the
# launch path impossible to read, and reading it wrong is how we shipped bugs.
#
# Where the demos come from: the Wine prefix created by install_demos.sh
# (default: <this directory>/wineprefix).  Paths are spelled out per demo, so the
# choice of which copy to run is explicit and never decided by the order of a
# find(1) walk.  That mattered: Nalu ships two byte-identical mermaid.exe, one in
# Nalu/bin and one in Nalu/bin6600, and the old automatic search picked bin6600,
# i.e. the lighter GeForce 6600 variant whose demoparams.txt disables two consume
# lines (plants_slid.nmb, occlusionGeo.nmb).
#
# Two environment variables are honoured, because builds and prefixes are exactly
# what a developer needs to swap:
#   NV_BUILD        which build to use (default: ./build; use ./build-release for
#                   the features-only build without the diagnostics series)
#   NV_WINEPREFIX   which prefix to use (default: ./wineprefix, the one that
#                   install_demos.sh fills)
#
# Fullscreen presentation (the Wine "fullscreen hack", patches/wine/0001): active
# for EVERY demo, with WINE_NV_FSHACK_MODE set to the size that demo itself asks
# for in its args file.  Wine then emulates a modeset to that size and scales the
# result to the real screen, which is what makes a 1024x768 demo fill a 4K panel
# with symmetric bars instead of sitting in the top-left corner at native size.
# EmulateModeset is implied by WINE_NV_FSHACK, so it is NOT set here (see the
# precedence note in patches/wine/doc.md).
#
# Debug/diagnostic knobs (MESA_NV_TRACE_*, WINE_NV_TRACE_*, dumps) exist only in a
# debug build; in ./build-release they are not in the binaries at all.  They are
# still reachable: they are ordinary environment variables, so set them before
# calling this script, for example
#   MESA_NV_TRACE_FB_SIZE=1 ./run.sh nalu
#
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# Which build and which prefix
# ---------------------------------------------------------------------------
NV_BUILD=${NV_BUILD:-$DIR/build}
WINE=$NV_BUILD/wine/bin/wine
MESA_DIR=$NV_BUILD/mesa
export WINEPREFIX=${NV_WINEPREFIX:-$DIR/wineprefix}

# The prefix layout produced by install_demos.sh.  Both spellings seen in the
# wild are tried, and the search is case-insensitive because Windows paths are:
# guessing the case here once produced a lookup that always failed, and the
# fallback then decided the demo copy by find(1) order.
DEMO_ROOT=""
for cand in \
    "$WINEPREFIX/drive_c/Program Files (x86)/Nvidia Corporation/Nvidia Demos" \
    "$WINEPREFIX/drive_c/Program Files (x86)/NVIDIA Corporation/NVidia demos" \
    "$WINEPREFIX/drive_c/Program Files/NVIDIA Corporation/NVidia demos"
do
    if [ -d "$cand" ]; then DEMO_ROOT=$cand; break; fi
done
if [ -z "$DEMO_ROOT" ]; then
    DEMO_ROOT=$(find "$WINEPREFIX/drive_c/Program Files" -maxdepth 4 -type d \
                -ipath '*nvidia*/demos*' 2>/dev/null | head -1)
fi

# ---------------------------------------------------------------------------
# Exports that are identical for every demo
# ---------------------------------------------------------------------------
export LD_LIBRARY_PATH="$MESA_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$MESA_DIR/lib64/dri"
export MESA_LOADER_DRIVER_OVERRIDE=zink          # OpenGL over Vulkan
export mesa_glthread=false                       # glthread reorders NV paths
export WINE_USE_EGL=0                            # our Wine talks GLX, not EGL
export MESA_MAX_TEXTURE_IMAGE_UNITS=16           # 2002-era limit the demos expect
export MESA_NV_ADVERTISE_TEXSHADER=1             # NV extensions visible to WGL/GLX
export MESA_NV_ATTR_MAP=0                        # NV vertex-attribute convention
export MESA_NV_IMM_SWZ=1                         # immediate swizzle in the translator
export MESA_NV_ARRAY_ONCE=0                      # single upload per buffer
export MESA_SHADER_CACHE_DISABLE=true            # a stale cache hides shader fixes
export WINE_NV_FSHACK=${WINE_NV_FSHACK:-1}          # scaled+centered presentation
# WINE_NV_FSHACK=0 selects the native-surface presentation (the gamescope path, see
# tools/nv_gamescope.sh).  Measured: with FSHACK off, WINE_NV_EMULATE_MODESET is NOT
# implied any more, so the surface stays native and the demo shows it as-is.
export WINE_NV_FSHACK_NOGRAB=1                   # do not grab the pointer
# WINEDEBUG is deliberately NOT set here.  Wine already shows err and fixme by
# default, and our own patches report through those channels (framebuffer surfaces,
# GLX problems, the fullscreen-hack decisions).  Setting -all would hide the real
# errors along with the noise, which is worse than reading a busier terminal.
# Ask for more if you need it:  WINEDEBUG=+wgl ./run.sh nalu

# ---------------------------------------------------------------------------
# How a demo is started
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

start() {   # start <path-relative-to-DEMO_ROOT> [args for the executable...]
    local rel=$1; shift
    local exe="$DEMO_ROOT/$rel"
    [ -n "$DEMO_ROOT" ] || die "no NVIDIA demos directory inside $WINEPREFIX.
       Install the demos first:  ./install_demos.sh"
    [ -f "$exe" ] || die "demo executable not found: $exe
       Expected the prefix to contain it. Check: $WINEPREFIX
       (install or reinstall with: ./install_demos.sh)"
    # The demos resolve their models as ../models/..., so the working directory
    # has to be the one that contains the executable.
    cd "$(dirname "$exe")"
    echo "=== wine   : $WINE ($("$WINE" --version 2>/dev/null | head -1))"
    echo "=== mesa   : $MESA_DIR ($(ls "$MESA_DIR"/lib64/libgallium-*.so 2>/dev/null | head -1 | xargs -r basename))"
    echo "=== prefix : $WINEPREFIX"
    echo "=== demo   : $rel"
    echo "=== present: WINE_NV_FSHACK=$WINE_NV_FSHACK WINE_NV_FSHACK_MODE=${WINE_NV_FSHACK_MODE:-not set}"
    # $NV_WINEOPTS lets a tool inject a wrapper in front of the executable;
    # tools/nv_record_trace.sh uses it to run the Windows apitrace under our stack.
    # The rewritten run.sh had dropped this and silently broke that tool: the parity
    # gate compares environment variables, it cannot see an invocation contract.
    exec "$WINE" ${NV_WINEOPTS:-} "./$(basename "$exe")" "$@"
}

# ---------------------------------------------------------------------------
# Which demo
# ---------------------------------------------------------------------------
DEMO=${1:-}
if [ -z "$DEMO" ]; then
    cat <<'EOF'
Usage: ./run.sh <demo>

  gas      GeForce FX 5900 - Last Chance Gas Station
  vulcan   GeForce FX 5900 - Vulcan
  dusk     GeForce FX 5900 - Dusk          (Cg 1.1, NV programs, register combiners)
  dawn     GeForce FX 5800 - Dawn / Fairy
  blobby   GeForce FX 5200 - Blobby Dancer (opens its own configuration window)
  truck    GeForce FX 5800 - Time Machine
  toys     GeForce FX 5800 - Toys          (depth of field)
  cs       GeForce 6800  - Clear Sailing
  timbury  GeForce 6800  - Timbury         (glBitmap slider text)
  luna     GeForce 6/7   - Luna            (Cg fp40, float pbuffer chain)
  mike     GeForce 7800  - Mad Mod Mike    (fur; materials rewired by tools/nv_mike_materiali.py)
  nalu     GeForce 6800  - Nalu            (soft shadows, god rays)

Environment you may want to set before the call:
  NV_BUILD=./build-release   use the features-only build
  NV_WINEPREFIX=/path        use another prefix
  WINEDEBUG=+wgl             Wine trace instead of the default -all
EOF
    exit 2
fi

# The single argument is either one of the ten keys above, or the path of an
# executable.  The path form exists because old scripts and shortcuts call it that
# way; it gets the common environment (which is the part that matters) and none of
# the per-demo knobs, and it says so out loud instead of pretending.
if [ -f "$DEMO" ]; then
    echo "NOTE: starting an executable path directly: the common environment is set,"
    echo "NOTE: starting an executable path directly: the common environment is set,"
    echo "      the per-demo knobs of the blocks below are NOT applied."
    # WINE_NV_FSHACK without WINE_NV_FSHACK_MODE does nothing at all: measured, Wine says
    # "FSHACK: WINE_NV_FSHACK is set but WINE_NV_FSHACK_MODE missing: no effect".  The
    # demo blocks set a size per demo; here there is no demo key, so take the size most
    # demos ask for, and let the caller override it in the environment.
    export WINE_NV_FSHACK_MODE=${WINE_NV_FSHACK_MODE:-1024x768}
    # Same contract as start(): $NV_WINEOPTS must stay, nv_record_trace.sh depends on it.
    start_abs() { local e=$1; shift; [ -f "$e" ] || die "not found: $e"; cd "$(dirname "$e")"; exec "$WINE" ${NV_WINEOPTS:-} "./$(basename "$e")" "$@"; }
    # Le virgolette non erano decorazione: senza di esse un argomento con spazi
    # si spezzava, e due invocazioni consecutive lo hanno misurato (il probe Cg
    # riceveva "C:\Program" al posto del percorso completo della directory bin,
    # e LoadLibraryA falliva con err=126 su un percorso inesistente).
    # Extra words on the command line are forwarded to the executable. Mad Mod Mike
    # needs two tokens (an arguments file and its -gldebug switch): quoting them into a
    # single argument would hand the demo one argv entry containing a space, which its
    # option parser does not accept. With one or two words the behaviour is exactly the
    # old one: the second word, or an empty argument when there is no second word.
    # A measured lesson from 2026-11-09: a first version of this block passed an empty
    # extra word even when the second word existed, which replaced the arguments file with
    # an empty string; the demo then printed 'CBubba: Data file "" not valid' and stopped
    # before compiling any shader. Two measurements looked like findings about the demo and
    # were findings about this launcher, which is why the argument passing is stated here.
    if [ "$#" -ge 3 ]; then extra=("${@:3}"); else extra=("${2:-}"); fi
    start_abs "$DEMO" "${extra[@]}"
fi

# ---------------------------------------------------------------------------
# One block per demo: its own settings, then the launch.
# Every block sets WINE_NV_FSHACK_MODE to the size the demo itself asks for, and
# only the knobs that the current patch series actually reads.
# ---------------------------------------------------------------------------

# GasStation: 1024x768 fullscreen.  Its wireframe problem was fixed in Mesa
# (nv_to_arb swizzle), so it needs no special knob.
if [ "$DEMO" = gas ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    start GasStation/bin/GasStation.exe args.txt
fi

# Vulcan: 1024x768 fullscreen.  MESA_NV_ARRAY_ONCE makes each vertex buffer upload
# once per draw instead of once per attribute (docs/vulcan-perf.md); it costs memory
# in the shadow buffer, so it is enabled only where it was measured to help.
if [ "$DEMO" = vulcan ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    export MESA_NV_ARRAY_ONCE=1
    start Vulcan/bin/vulcan.exe args.txt
fi

# Dusk: 1024x768 fullscreen.  MESA_NV_ATTR_MAP stays at the global 0: Dusk feeds
# its attributes through the NV entry points and the generic mapping makes the
# bodice and hair flat khaki (docs/nv-vertex-attrs.md).  Dusk reads bin/args.txt by
# itself, so it gets no argument.
if [ "$DEMO" = dusk ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    start Dusk_w_help/bin/Dusk.exe
fi

# Dawn/Fairy: 1024x768 fullscreen.  args.txt selects the normal dataset;
# args_ultra.txt exists too, but with args.txt asking "ultra = true" without
# loading fairy_ultra.nmb the demo dereferences a null pointer (fault 0x46F4D4).
if [ "$DEMO" = dawn ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    start Dawn/bin/Fairy.exe args.txt
fi

# Blobby Dancer: opens its own window by design (it is a configuration/benchmark
# screen, not a fullscreen demo), so it is presented 1:1 through the same hack with
# the window size it uses.  It needs the generic attribute mapping (=1), the
# opposite of Dusk's convention.
if [ "$DEMO" = blobby ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    export MESA_NV_ATTR_MAP=1
    start BlobbyDancer64/BlobbyDancer64.exe
fi

# Truck / Time Machine: 1024x768 fullscreen, no demo-specific knob.
if [ "$DEMO" = truck ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    start "Time Machine/bin/Truck.exe" args.txt
fi

# Toys (DepthOfField): asks 1280x1024, which is the only 5:4 demo of the set; the
# presentation bars are therefore different from the 4:3 ones.
if [ "$DEMO" = toys ]; then
    export WINE_NV_FSHACK_MODE=1280x1024
    start Toys/bin/DepthOfField.exe args.txt
fi

# Clear Sailing (PirateShip): 1024x768 fullscreen.  WINE_NV_MAP_ONCE copies the
# Wow64 buffer map once instead of per call, which is what makes the sea run at a
# sane frame rate here.
if [ "$DEMO" = cs ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    export WINE_NV_MAP_ONCE=1
    start "Clear Sailing/bin/PirateShip.exe" args.txt
fi

# Timbury (BugLooker): 1024x768 fullscreen.  The pbuffer chain of this demo needs
# legacy buffers and the float fallback, otherwise the panel text (glBitmap slider
# labels) and the pick buffers come out wrong; MAP_ONCE as for Clear Sailing.
if [ "$DEMO" = timbury ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    export WINE_NV_MAP_ONCE=1
    export WINE_NV_PBUFFER_FLOAT_FALLBACK=1
    export MESA_NV_LEGACY_BUFFERS=1
    # MESA_NV_TEX_SHADOW: the legacy NV path put the depth comparison in the texture
    # unit, so a plain TEX from a depth map returned the comparison result, not the
    # raw depth.  The translator keeps the same behaviour here; otherwise the Timbury
    # shadows regress against the hardware reference.
    export MESA_NV_TEX_SHADOW=${MESA_NV_TEX_SHADOW:-1}
    # The Timbury race companion is installed by install_demos.sh as:
    # Timbury/bin/winmm.dll.  It does not touch BugLooker.exe; it patches
    # FUN_00421840 in the running process and inserts about 10 ms at the first
    # ten upstream steering calls, enough to close the startup race without
    # logging or visible output.  The DLL is found by normal Win32 DLL search
    # order because it sits beside BugLooker.exe, so no WINEDLLOVERRIDES entry
    # is needed here.
    start Timbury/bin/BugLooker.exe args.txt
fi

# Nalu (mermaid): 1024x768 fullscreen, and explicitly Nalu/bin - NOT Nalu/bin6600,
# which is the lighter GeForce 6600 variant.  WINE_NV_PBUFFER_RT_ALIAS routes the
# depth render-textures to the channel Nalu reads, and WINE_NV_RT_COLOR_TFP=0 forces
# a copy of the colour render-textures (aliasing them breaks the god rays).
# MESA_NV_RT_SNAP (flush-front snapshot) exists in Mesa but is off by default and
# nothing has measured it as needed: not set here.
if [ "$DEMO" = nalu ]; then
    export WINE_NV_FSHACK_MODE=1024x768
    export WINE_NV_MAP_ONCE=1
    export WINE_NV_PBUFFER_RT_ALIAS=1
    export WINE_NV_RT_COLOR_TFP=0
    start Nalu/bin/mermaid.exe args.txt
fi

# Luna: the Cg fp40 demo, unblocked by its float pbuffer chain (measured 2026-11-06).
# The demo asks WGL_PIXEL_TYPE_ARB = WGL_TYPE_RGBA_ARB together with
# WGL_FLOAT_COMPONENTS_NV = 1 and WGL_BIND_TO_TEXTURE_RGBA_ARB = TRUE, while our
# duplicated float formats declared WGL_TYPE_RGBA_FLOAT_ATI with texture binding
# cleared: the request could therefore only match ordinary 8-bit formats, the demo
# printed "NRPbuffer::Create: unable to find valid pixel format", stored a null shader
# member and dereferenced it at 0x4a1e4f. WINE_NV_WGL_FLOAT_TYPE_RGBA makes the copies
# declare RGBA + float + bindable, which is what the era driver did.
#
# Scoped to Luna on purpose, never exported globally: with these same knobs, Timbury
# (BugLooker) draws its UI over a black demo area - the "tonemap ends in the dark"
# failure mode its notes describe when the exposure scales get truncated at 1.0.
# Mad Mod Mike (techdemo 39, GeForce 7800 GTX). The demo died reading 0 at
# mike+0x4A03AF: applying the constant parameter const_bias dereferences a null
# shader holder. The EXC32 dump (which prints the strings the registers point at)
# named the object: the material block blur_2d_rounded_square_v, whose material line
# names the file blur_2d_rounded_square.vp30 under shaders. Four material blocks are involved: the
# rounded-square blur pair, composite_v/composite_heat_v and card1_f. The cause is
# inside the demo's own material system, not in our front ends: in one run our ARB
# parser rejected 0 programs and the driver received 201. Measured and refuted: (a)
# raising the profile line in the material, (b) inlining a helper that takes a
# sampler as an argument, (c) adding dummy global parameters to the broken blocks,
# (d) advertising GL_NV_gpu_program4/5 from Mesa - all four changed nothing, and (d)
# was removed again because a knob that changes nothing is not kept. What changed
# the outcome: moving a working source into a broken block moves the FAILURE with
# the block, so the techniques are rewired onto blocks that do compile, which
# tools/nv_mike_materiali.py generates as copies (the installed files keep their
# hashes, verified by that tool); the arguments file with the rewired scenes is the
# default in the demo table. Visually this is what the rewiring buys: the demo comes
# up, no fault, and renders its scene - the giant fur with the note 'Dear Mad Mod
# Mike! Help! My fur is Toxic!! Gabby', photos, hearts, the room with pictures,
# door, striped chair, table, the NVIDIA logo card, camera moving. Shader parameters
# that the shapes pass by name no longer all match, and the demo says so in its own
# warnings: this is a content adaptation, not a driver fix.
#
# The four knobs below are the float pbuffer chain Luna needs and that Mike needs
# too, measured here: without them the demo prints 'NRPbuffer::Create: unable to
# find valid pixel format' 4 times and 'NRPbuffer::Bind: failed to bind color' 4
# times; with them both go to zero and the EXT_framebuffer_object loader complaint
# drops from 4 to 2 (the last two are the NVX names, which stay null until the
# context publishes GL_NVX_conditional_render).
# WINE_NV_MAP_ONCE is the frame-rate fix, and it came out of a measured profile
# rather than a guess.  Run outside the sandbox on 2026-11-09 with
# tools/outside/nv-perf-outside.sh (Samples: 3K of 'cpu/cycles/P', call graph
# dwarf,32768): 93.89% of the sampled cycles sit in __wine_unix_call_dispatcher ->
# wow64_ext_glMapBufferARB -> wow64_map_buffer, and 92.84% of the whole process is
# self cost in one libc routine, which the disassembly at libc file offset 0x18f624
# shows to be the AVX-512 copy loop (four vmovdqu64 loads of 64 bytes into zmm17..20,
# four vmovdqa64 stores, jump back to 0x18f624).  Same run: 76.64G of 77.27G cycles in
# user space against 0.62G in the kernel, so this is not driver ioctl cost.  Mike is a
# GL 1.4 WoW64 guest: the host pointer the driver returns for a mapped buffer does not
# fit in 32 bits, so Wine allocates a low 32-bit buffer and memcpy's the whole thing
# down at map and back up at unmap, every frame.  Those buffers are neither vk_memory
# nor pinned (that path needs GL_AMD_pinned_memory, which Mike never asks for), so the
# copy branch is what it gets.  Measured here, 30 s each, WINE_NV_FSHACK=0 with
# WINE_QPC_STEP set: without MAP_ONCE 135 distinct swaps (4.50 fps), with MAP_ONCE 1838
# distinct swaps (61.27 fps), zero faults in both.  The old 4.5 fps was therefore never
# a fill-rate limit, which the geometry ablations had already hinted at.
if [ "$DEMO" = mike ]; then
    # NV_MIKE_ADVERTISE_OFF=float|all: maniglia di A/B per lasciare fuori dall'ambiente gli
    # interruttori della pubblicita dei formati a virgola mobile.  Sono letti con !!getenv,
    # quindi l'unico modo di spegnerli e non esportarli affatto: un valore vuoto o zero li
    # lascerebbe presenti.  Motivo per voler provare: sull'hardware dell'epoca i due
    # magazzini del bloom nascevano da un formato pixel a 16 bit NORMALIZZATI per canale
    # (tracciato d'epoca: due wglChoosePixelFormatARB con WGL_RED/GREEN/BLUE/ALPHA_BITS_ARB
    # = 16 e WGL_PIXEL_TYPE_ARB = WGL_TYPE_RGBA_ARB, risposta indice di formato 356, poi due
    # wglCreatePbufferARB(iPixelFormat = 356, 428x240, WGL_TEXTURE_FORMAT_RGBA)); la nostra
    # pila alla stessa richiesta pubblicizza formati float e duplica un fbconfig float
    # (testimone Wine "pbuffer float on duplicated format"), e quel magazzino float non
    # riceve i disegni della demo: con WINE_NV_FLOAT_PFB=1 le letture con contenuto sono
    # 0 su 803, quindi la leva spegne il bloom invece di correggerlo (verificato di nuovo il
    # 14 novembre 2026, giudizio visivo: rettangolo assente, bloom assente).  `float` lascia
    # fuori WINE_NV_ADVERTISE_NV_FLOAT; `all` lascia fuori anche la riserva e la copia del
    # tipo WGL.  Non impostato: comportamento identico a prima, perche le quattro impostazioni
    # di default restano e vengono esportate come prima.
    NV_MIKE_ADVERTISE_OFF=${NV_MIKE_ADVERTISE_OFF:-}
    : "${WINE_NV_ADVERTISE_NV_FLOAT:=1}"
    : "${WINE_NV_ADVERTISE_DEPTH_TEXTURE:=1}"
    : "${WINE_NV_PBUFFER_FLOAT_FALLBACK:=1}"
    : "${WINE_NV_WGL_FLOAT_TYPE_RGBA:=1}"
    case "$NV_MIKE_ADVERTISE_OFF" in
        "")    ;;
        float) unset WINE_NV_ADVERTISE_NV_FLOAT ;;
        all)   unset WINE_NV_ADVERTISE_NV_FLOAT WINE_NV_PBUFFER_FLOAT_FALLBACK WINE_NV_WGL_FLOAT_TYPE_RGBA ;;
        *)     printf 'run.sh: NV_MIKE_ADVERTISE_OFF sconosciuto: %s\n' "$NV_MIKE_ADVERTISE_OFF" >&2
               exit 2 ;;
    esac
    if [ -n "${WINE_NV_ADVERTISE_NV_FLOAT:-}" ]; then
        export WINE_NV_ADVERTISE_NV_FLOAT
    fi
    export WINE_NV_ADVERTISE_DEPTH_TEXTURE
    if [ -n "${WINE_NV_PBUFFER_FLOAT_FALLBACK:-}" ]; then
        export WINE_NV_PBUFFER_FLOAT_FALLBACK
    fi
    if [ -n "${WINE_NV_WGL_FLOAT_TYPE_RGBA:-}" ]; then
        export WINE_NV_WGL_FLOAT_TYPE_RGBA
    fi
    # Measured 2026-11-11, and switched off for Mike on purpose.  The Wine path that
    # substitutes a hand-built float framebuffer for pbuffers whose pixel format declares
    # float colour (win32u/opengl.c, nv_float_pbuffer_bound) does engage for Mike, and it
    # replaces exactly the two colour stores of the bloom chain, 428x268.  Mike's draws are
    # recorded as going into those substitutes (Mesa framebuffers named 1 and 2; the demo
    # itself never calls glGenFramebuffers: zero such calls in the apitrace dump) yet no
    # fragment ever arrives there - a forced magenta clear survives 238 of 239 reads when the
    # blur program is skipped - so the stores stay empty: 0 of 803 and 0 of 803 reads with
    # content across a whole deterministic run.  With WINE_NV_FLOAT_PFB=0 the same two stores
    # fill: 794 of 801 (99.1 percent, brightest 202) and 795 of 801 (99.3 percent, brightest
    # 233).  Nothing else changes: the 1280x800 composite, the 1920x1080 window, the
    # 80x80/96x96/912x576 stores and every depth attachment read the same in both settings
    # (3072x2048 atlas depth mean 0.9462 against 0.9454, 2048x2048 0.9261 against 0.9267,
    # 640x400 0.7077 against 0.7068), and 26 of 26 captured swaps become brighter, from 0.1823
    # to 0.2350 and from 0.2195 to 0.3085 in mean luminance; emissive objects gain the halo
    # they were missing.  The float pixel formats stay advertised, because the demo asks for
    # them, so only the substitution is refused and Mike's bloom intermediates become 8-bit
    # and clamp.  Timbury and Luna keep the substitution: their branches do not set this.
    # Note the three advertise knobs above are presence-gated (!!getenv), so only leaving them
    # out of the environment turns them off; this one reads a number (atoi), so 0 really works.
    # The real fix - making the float store actually receive Mike's draws while
    # WGL_NV_render_texture is bound on the same pbuffer - is still open.
    # Written as an inline default so that a person can set WINE_NV_FLOAT_PFB=1 in the
    # environment to bring the substitution back and A/B this decision, same pattern as
    # WINE_NV_MAP_ONCE above.
    export WINE_NV_FLOAT_PFB=${WINE_NV_FLOAT_PFB:-0}
    # Omni (point light) shadows: Mad Mod Mike fetches its shadow maps with PLAIN tex
    # lookups on depth render textures whose sampler has GL_TEXTURE_COMPARE_REF_TO_TEXTURE
    # set (census: the 3072x2048 atlas and the 2048x2048 planar map, cmp=#x884e). On 2004
    # NVIDIA hardware the comparison lived in the texture, so such a fetch returns the
    # 0/1 mask. In Mesa the comparison is only executed when the instruction itself asks
    # for a shadow read, so in the product path the fetch hands the program the raw
    # window depth (measured atlas depth_mean 0.9505): the light is multiplied by the
    # depth of the map and the frame shows the iso-depth contours of the walls, which is
    # what the user reported as the streaks and notches on the purple wall. Measured
    # 2026-11-11 with the constant-reference sweep of MESA_NV_ARB_SHADOW_REF: in the wall
    # region of the frame at exchange index 11 the dark pixels go from 61.38% to 69.21%
    # and 42.7% of the region changes when the constant reference crosses 0.90..0.99,
    # i.e. the comparison is live once the shadow read is requested. The reference must
    # come from the THIRD coordinate component: the demo's own Cg source
    # (shaders/ReceiveHardOmniShadow_inc.fp30, lines 63-68) builds the coordinate as
    # `0.5 + 0.5*cLightQ.y - zbias_const`, which is window-space depth, and the fourth
    # component is the usual 1.0 filler. Upstream Mesa picks the fourth component for a
    # shadow read with three or more coordinate components, which is why
    # MESA_NV_TEX_SHADOW=1 alone helped the indirect lighting but left the streaks: with
    # reference 1.0 the test is depth-independent and only reports geometry. The pair
    # below is Mike-only; the other demos keep the upstream default (the knob without a
    # value means w), so nothing else changes.
    export MESA_NV_TEX_SHADOW=${MESA_NV_TEX_SHADOW:-1}
    export MESA_NV_ARB_SHADOW_REF=${MESA_NV_ARB_SHADOW_REF:-z}
    # 2026-11-19: the hard omni shadow is an ARB program whose executable fetch is a plain
    # `TEX ... 2D`, but whose Cg debug declaration says `sampler2DSHADOW shadowTexCrisp` on
    # the atlas unit. The hardware of the period compared anyway; Mesa left the fetch as a
    # raw depth read. A shader experiment that replaced the four hardware compares with an
    # explicit `raw depth >= receiver depth` test was visually correct on the Omni Soft
    # Shadows title, and the live hardware screenshot of `ROOM_HARD_VISUAL` was black there.
    # This knob marks exactly the units named by those Cg shadow declarations, while the
    # existing st_program.c filter still removes the shadow from units not backed by a depth
    # texture. With it `MESA_NV_TRACE_TEXSHADOW_FP` reports shadowmask non-zero and the Mike
    # walls recover the dark hard term seen on the 9800. Mike-only, as the other two keys
    # above.
    export MESA_NV_ARB_TEX_SHADOW=${MESA_NV_ARB_TEX_SHADOW:-1}
    # Cube-face latch, kept on for Mike after the measurement and the visual acceptance of
    # 2026-11-12.  Mike renders six views per cube per frame (reference apitrace: 3840
    # wglSetPbufferAttribARB selections over 640 frames for each of the three colour cube
    # pbuffers, 6013 for the depth one) but binds the render texture once per frame, so the
    # old delivery chain stamped one surface onto the last selected face and left five of six
    # faces at the bytes the demo wrote during initialization: 10 of the 15 face pairs
    # byte-identical on all four cube objects, body md5 576610756b3a405bca391d617ebd8f07 on
    # the 80x80 and 4e4618095c1e7bdd5f983ad1427a714f on the 96x96.  A cube of six photographs
    # where one photograph is printed six times; the receivers sample by direction, so five
    # sixths of the room were reading a single shadow coefficient.  With the latch the three
    # colour cubes of the 2026-11-12 survey become distinct: 0 of 15 identical pairs, mean L1
    # 8.621, 11.973 and 8.624 (tex=7 still shows 10 identical pairs: open).  Seen on the
    # captured frames the scene is intact and the indirect lighting works; measured difference
    # on the same swap index 18.03 percent of pixels at #4 against 12.43 percent measured
    # between two identical control runs, 3.15 percent at #5, 0.00 percent at #2.  Cost none
    # measured: 1852 exchanges in 26 s with the latch, 1608 without, 0 exceptions both ways.
    # The latch takes over the DEPTH cube as well, through WINE_NV_CUBE_STORE_DEPTH=1.
    # That refusal, written before 2026-11-13, is withdrawn: it rested on a reading of the six
    # faces (mean 0.4921 over 158783 reads against 0.2773 with the cube levers left alone) that
    # was taken on a chain which delivered that cube badly, so the "symmetric distance field" it
    # protected was our own leftovers, not the demo's writing.  Measured now with the guard
    # opened, both arms with identical probes and the same face dump: the 96x96 depth cube faces
    # stop being empty, fraction of texels under 2 percent luminance 55.06 to 0.00 and 56.62 to
    # 0.00, distinct colours 152 to 482 and 292 to 1116, and 1396 to 2851 on the 80x80 face.
    # A phase-controlled pair (1280x720 window, every exchange captured, same probes both arms)
    # is byte identical at exchanges 0 and 2 and separates at exchange 4: 27.44 percent of the
    # sampled pixels change, 6.23 percent brighter and 5.93 percent darker; at exchange 6 the
    # split is 67.33 percent, 20.68 brighter and 21.39 darker.  Brighter where the indirect term
    # fills in, darker where the shadow lands.  Verdict from the person at the screen: the demo's
    # lighting system works, indirect lighting and the omni soft shadows are correct.  This does
    # not fix the hard omni shadows, the jetpack spikes or the composite tile.
    # The other cube lever,
    # WINE_NV_PBUFFER_CUBE_FACE_FBO, is NOT enabled here: on the same frames it moves 63.46
    # percent of the pixels and puts a giant dark rectangle where the room is, so it stays an
    # experiment.  Mike only: no other branch of this script sets the knob.
    # Mode 2 is the save-and-restore shape: it saves the leaving cube face and also restores the
    # entering face from the cube before Mike renders it again. Mike uses the 96x96 cube twice per
    # frame: first the RGB environment pass with alpha off, then the alpha-only occluder pass with
    # RGB off. Save-only carries the previous face surface into the next pass; mode 2 stops that
    # leak and makes the Omni Soft Shadows cube much closer to the 9800 reference frame. The direct
    # per-face store mode WINE_NV_PBUFFER_CUBE_FACE_FBO stays off because it still puts a giant dark
    # rectangle over the room.
    export WINE_NV_PBUFFER_CUBE_LATCH=${WINE_NV_PBUFFER_CUBE_LATCH:-2}
    # Inline default for the same reason as WINE_NV_MAP_ONCE below: setting
    # WINE_NV_CUBE_STORE_DEPTH=0 in the environment puts the old behaviour back for an A/B.
    export WINE_NV_CUBE_STORE_DEPTH=${WINE_NV_CUBE_STORE_DEPTH:-1}
    # Written as an inline default, not as := plus a bare export, because the parity
    # gate reads the value from the export line; ${...:-1} still lets a person set
    # WINE_NV_MAP_ONCE=0 in the environment to A/B the fix.
    export WINE_NV_MAP_ONCE=${WINE_NV_MAP_ONCE:-1}
    # Measured 2026-11-09, and NOT kept as a default: Mike reads its dynamic shadows through
    # projective lookups into the 2048x2048 and the 3072x2048 depth render textures (27525 and
    # 44850 sampled draws), Wine can produce a correct map for them (reading framebuffer 0 of
    # the context that drew gives min 0.438816, mean 0.906472 over 6291456 texels, no texel at
    # zero) and the upload lands on the very object the programs sample (object pointers match
    # in the MESA-DEPTH-UPLOAD probe and in the MESA_NV_TRACE_TEXBIND draw census) - yet an
    # injected known pattern over those two maps does not change a single presented frame, to
    # the fourth decimal, with or without re-specifying the storage as depth-only
    # GL_DEPTH_COMPONENT32 to remove the packed depth-plus-stencil store. The combination costs
    # twenty frames per second (55 to 34) for no measured visual effect, so it stays available
    # for experiments and is not enabled: WINE_NV_PBUFFER_DEPTH_COPY=2
    # WINE_NV_PBUFFER_RT_DEPTH_RESPEC=32 WINE_NV_PBUFFER_DEPTH_COPY_SIZES=2048x2048,3072x2048
    # WINE_NV_PBUFFER_DEPTH_COPY_MAXPX=all. What the frames do show is that the colour render
    # textures reach the sampler (flipping their delivery moves blocks of the picture by up to
    # 41 of 255) and that their delivered content varies from run to run, which is the shape of
    # the remaining bug: the era driver aliased pbuffer storage into the texture, so a bind
    # before the drawing still showed the drawing, while a copy taken at bind time captures
    # whatever the surface held at that moment.
    # NV_MIKE_ARGS chooses the arguments FILE, not the material set: with the
    # translator fix of 2026-11-13 (MESA_NV_NESTED_ARM_GATE) the demo loads its OWN
    # installed content again, so the product default is the shipped args.txt and the
    # rewire copies written by tools/nv_mike_materiali.py are kept only for
    # experiments. Measured on the demo's own materials, deterministic captures of the
    # swap surface, four frames: black area 1.5 1.5 4.1 2.4 percent with the fix,
    # 63.6 63.2 73.5 73.1 percent with MESA_NV_NESTED_ARM_GATE=0. The same switch,
    # measured on the isolated program with tools/nv_geom_probe.c and parameter sets
    # written by hand from shaders/composite.vp30, gives 25.00 percent coverage for a
    # corner quad against 0.00 percent with the switch off. The comparison variants
    # (args_a_b.txt, args_cv_*.txt, args_finestra*.txt, args_nativa_orig.txt) remain
    # selectable through this variable instead of starting the executable by path:
    # path mode does not apply this block.
    : "${NV_MIKE_ARGS:=args.txt}"
    start "Mad Mod Mike/bin/MadModMike.exe" "$NV_MIKE_ARGS"
fi

if [ "$DEMO" = luna ]; then
    # run.sh never touches bin/args.txt. That file carries the demo's own geometry choice, and
    # rewriting it from the launcher turned out to be a trap: measured on 2026-11-08, a plain
    # "./run.sh luna" (which until now defaulted to NV_LUNA_CONFIG=nativa) rewrote the installed
    # file from 2698 bytes with 52 CR bytes (sha256 prefix 129d82a06552d1cc) to 2639 bytes with 0
    # CR bytes (sha256 prefix c5791e454c3a0cc0): the helper flattens CRLF to LF and the preset it
    # wrote makes the demo come up in a window instead of fullscreen. Changing args.txt has to be a
    # deliberate act by a person, never a side effect of launching a demo; tools/nv_luna_config.sh
    # stays available and is run by hand when someone wants another preset.
    # The geometry the installer ships (line 32: auto-detect with max width 1024, fullscreen)
    # renders correctly on this stack: the venature chain (WINE_NV_RT_COLOR_ALIAS=2, signed HILO
    # fetch) and the shadow comparison (MESA_NV_ARB_TXP_SHADOW) were both accepted on the live
    # screen with that file untouched. An earlier note in this place claimed the thickness map
    # needed a 1024x576 drawable; that measurement predates the signed HILO fix and the colour
    # render-texture aliasing, and it no longer holds.
    # The presentation size stays overridable for this demo only, for A/B on the hack.
    : "${WINE_NV_FSHACK_MODE:=1024x768}"
    export WINE_NV_FSHACK_MODE
    : "${WINE_NV_ADVERTISE_NV_FLOAT:=1}"
    export WINE_NV_ADVERTISE_NV_FLOAT
    : "${WINE_NV_ADVERTISE_DEPTH_TEXTURE:=1}"
    export WINE_NV_ADVERTISE_DEPTH_TEXTURE
    : "${WINE_NV_PBUFFER_FLOAT_FALLBACK:=1}"
    export WINE_NV_PBUFFER_FLOAT_FALLBACK
    : "${WINE_NV_WGL_FLOAT_TYPE_RGBA:=1}"
    export WINE_NV_WGL_FLOAT_TYPE_RGBA
    # Colour render textures: the demo renders into WGL pbuffers and rebinds them as textures
    # later in the SAME frame. Our Mesa refuses the era driver's zero-copy bind for colour
    # pbuffers - measured: all 36251 colour wglBindTexImageARB binds report ret=-1 - so Wine
    # falls back to a pixel copy at bind time, which is too early for those passes: the
    # 512x512 thickness store the creature shader reads stays flat, the vein ramp ends up
    # indexed by a nearly constant coordinate, and the tissue renders as a pale veil with no
    # venature (docs/luna-geometria.md has the chain). Mode 2 instead makes the application's
    # own texture the COLOR_ATTACHMENT0 of the framebuffer that draws that pbuffer, which is
    # the semantics the era driver had: no copy, no delivery to time, the draws land inside
    # the texture the sampler reads. Measured with this knob alone, 22 s: 400 bind attempts
    # (the probe cap, so the real total is higher), 25 attachments landed, all of them on the
    # 512x512 thickness store, the rest fall back to the copy unchanged; zero faults, and the
    # verdict on the live screen was that the creature render is correct.
    # Two alternatives measured and rejected: WINE_NV_PBUFFER_RT_FBO=1 on its own darkens the
    # scene (sample luminance 0.0701 against 0.1141 base and 0.1375 in the reference video),
    # and mode 1, the Mesa delivery at sampling time, takes an access-violation exception in
    # Luna right after the pairings, so run.sh does not use it.
    : "${WINE_NV_RT_COLOR_ALIAS:=2}"
    export WINE_NV_RT_COLOR_ALIAS
    # The Perlin field that drives the screen distortion lives in a noise volume.
    # The auto policy decides the voxel order by continuity, and for a noise texture
    # that criterion prefers the wrong order: measured 169.8 for the native order
    # against 147.7 for the reordered one, and the reordered one is what the reference
    # hardware shows. Forced for this demo only; docs/luna-fp40.md has the chain.
    : "${MESA_NV_TEX3D_DEPTH_MAJOR:=all}"
    export MESA_NV_TEX3D_DEPTH_MAJOR
    # Projected shadow reads in the demo's own assembly. The programs that receive the shadow
    # (ids 19, 56, 59, 72: monsters, torso, arms, collar) read the shadow map with
    # "TXP H4.x, R2, texture[0], 2D", and unit 0 there is a 2048x2048 depth texture carrying
    # GL_TEXTURE_COMPARE_MODE = GL_COMPARE_REF_TO_TEXTURE with GL_LEQUAL (measured live:
    # u0=tex1 2048x2048 fmt=#x1902 cmp=#x884e). Mesa only compares when the assembly text names a
    # SHADOW target, so the projected read returned the raw depth texel instead of the comparison
    # result and the shadow term collapsed towards "fully lit": shadows far lighter than on the
    # era hardware. Measured without Wine by tools/nv_arbtxp.c on a depth texture with known texels
    # (0.4 and 0.8) with references 0.9 and 0.3: without the knob TXP returns 0.800 and 0.800 (raw
    # texel), with the knob it returns 0.000 and 1.000 (the comparison), and the already correct
    # TEX ... SHADOW2D form returns 0.000 and 1.000 either way. The program that builds the shadow
    # store (id 138) goes through nv_to_arb.c, which already emits SHADOW2D: that is why no work on
    # the map itself or on the render-texture delivery had changed the picture. The map those
    # programs read is full: tex=1 2048x2048 min=0.101961 max=1 mean=0.958835 nz=1.000
    # via=READ-DIRECT. Units not backed by a depth texture lose the shadow again through
    # nir_remove_tex_shadow, so colour reads stay untouched (measured in the same tool: the plain
    # TEX form still returns 0.800 with the knob on). Verdict on the live screen: the shadows match
    # the era hardware and the subsurface scattering of the creature is intact. Demo-scoped.
    : "${MESA_NV_ARB_TXP_SHADOW:=1}"
    export MESA_NV_ARB_TXP_SHADOW
    start Luna/bin/Luna.exe args.txt
fi

echo "ERROR: unknown demo '$DEMO'.  Known ones: gas vulcan dusk dawn blobby truck toys cs timbury nalu luna mike" >&2
echo "       Run ./run.sh with no argument for the full list." >&2
exit 2
