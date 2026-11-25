#!/usr/bin/env bash
# install_demos.sh - install the NVIDIA tech demos into this toolchain's Wine prefix.
#
# What it does, in order:
#   1. creates the prefix with OUR wine (if missing) via wineboot --init
#   2. launches each installer found in ./techdemo_installers
#   3. after installing, looks for the demo executable inside the prefix and prints
#      where it is, because that table is what run.sh uses for its menu
#
# Design decision, taken at the user's explicit request: THIS SCRIPT DOES NOT SIMULATE
# USER INPUT. No xdotool, no synthetic Enter keys sent to dialogs - an installer that
# clicks for you is not something we ship. So:
#   - with no response file, the installer runs normally and the user clicks
#     Next/Install/Finish, leaving the default directory
#     (measured default: C:\Program Files (x86)\NVIDIA Corporation\NVidia demos\<name>
#      - "NVidia demos", not "NVIDIA Demos"; read from a prefix where Blobby is installed)
#   - if the user records a response file themselves (setup.exe /r"C:\...\name.iss"),
#     this script uses it and the install becomes silent:
#     setup.exe /s /f1"C:\...\name.iss"
#   - silent mode is then VERIFIED: if the expected executable does not appear, the
#     script says so instead of claiming success (exit code 0 proves nothing)
#
# Why plain "/s" is not enough - measured, not guessed. These installers are
# InstallShield InstallScript setups, not MSI wrappers:
#   - the temp directory ends up with "Disk1/setup.log" containing
#     "[InstallShield Silent] / Version=v7.00 / File=Log File / [ResponseResult] /
#      ResultCode=-5"
#   - the binaries contain the dialog names (SdWelcome, SdAskDestPath2, SdFinish) and a
#     GUID such as {A3EA21C8-01BB-4531-A694-4807B6414B4C}
#   - "/s /v/qn", which is the right thing for an MSI-wrapping setup, exited with RC=0
#     and installed NOTHING (tested with Nalu in a clean prefix: no demo files appeared)
#
# Watch out when calling wine from a shell by hand: build/wine.env exports PATH and
# WINE but NOT WINE_PREFIX, so "$WINE_PREFIX/bin/wine" after sourcing it resolves to
# /bin/wine, i.e. the distribution's wine (measured: it reports wine-11.21 while our
# pinned ref is wine-11.18, and it segfaults creating a prefix).
#
# Usage:
#   ./install_demos.sh                 install everything it finds
#   ./install_demos.sh --list          list installers and install state, install nothing
#   ./install_demos.sh --only nalu     one demo (table key, or a substring of the filename)
#   ./install_demos.sh --verify        only scan the prefix
  #   ./install_demos.sh --dry-run       recognise installers, show what WOULD run
#   ./install_demos.sh --prefix DIR    different prefix (default ./wineprefix)
#   ./install_demos.sh --installers D  installer directory (default ./techdemo_installers)
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX=${NV_WINEPREFIX:-$DIR/wineprefix}
WINE=${NV_WINE:-$DIR/build/wine/bin/wine}
# Where the installers are looked for, in order. The repo directory is what we tell
# users about; the two others are what this development machine actually has, and a
# tool that only works in one hand-made layout is a tool that will be blamed.
if [ -n "${NV_DEMO_INSTALLERS:-}" ]; then
    INSTALLERS="$NV_DEMO_INSTALLERS"
else
    INSTALLERS=""
    for cand in "$DIR/techdemo_installers" "$DIR/../techdemo_installers" "$HOME/techdemo_installers"; do
        if [ -d "$cand" ]; then INSTALLERS=$(cd "$cand" && pwd); break; fi
    done
    [ -n "$INSTALLERS" ] || INSTALLERS="$DIR/techdemo_installers"
fi
ACTION=install
ONLY=""

say() { echo "=== $*"; }

# --- prefix witness --------------------------------------------------------
# Why: "installer exited RC=0" proves nothing. Measured on 2026-11-05 with Luna: Wine
# printed "ShellExecuteEx failed: File not found." and STILL returned RC=0, and because
# Luna was not in the DEMOS table the expected-executable check was skipped, so a run that
# wrote no files at all was reported as clean. A cheap before/after fingerprint of
# drive_c catches that class for every installer, including ones whose expected executable
# we do not know.
prefix_witness() {   # prints "<file count> <byte count>" for $PREFIX/drive_c
    local n=0 b=0
    if [ -d "$PREFIX/drive_c" ]; then
        # Apparent bytes, not disk blocks: measured, `du -sx --block-size=1` reports blocks
        # and stays at 8192 when a file is rewritten shorter, which made the byte column
        # decorative and my own selftest correctly refused it. One find pass gives both the
        # count and the real sum of file sizes.
        read -r n b < <(find "$PREFIX/drive_c" -type f -printf '%s\n' 2>/dev/null |
                        awk '{s+=$1; c++} END {printf "%d %d\n", c+0, s+0}')
    fi
    printf '%s %s\n' "${n:-0}" "${b:-0}"
}

witness_changed() {  # $1 = before, $2 = after; echoes the verdict; 0 = something changed
    if [ "${1:-}" = "${2:-}" ]; then echo uguale; return 1
    else echo cambiato; return 0; fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

# The ten demos this project has fixed: key|expected executable|description.
# We search by EXECUTABLE NAME anywhere under the NVIDIA Corporation directories,
# because the install subdirectories differ per installer and are documented nowhere.
DEMOS=(
  "gas|GasStation.exe|GeForce FX 5900 - Last Chance Gas Station (wireframe, NV_vertex_program2)"
  "vulcan|vulcan.exe|GeForce FX 5900 - Vulcan (volcanic fire)"
  "dusk|Dusk.exe|GeForce FX 5900 - Dusk (Cg 1.1, NV_vertex_program + register combiners)"
  "dawn|Fairy.exe|GeForce FX 5800 - Dawn / Fairy"
  "blobby|BlobbyDancer64.exe|GeForce FX 5200 - Blobby Dancer (configuration menu)"
  "truck|Truck.exe|GeForce FX 5800 - Time Machine / Truck"
  "toys|DepthOfField.exe|GeForce FX 5800 - Toys (depth of field)"
  "cs|PirateShip.exe|GeForce 6800 - Clear Sailing"
  "timbury|BugLooker.exe|GeForce 6800 - Timbury (bugs, glBitmap slider text)"
  "nalu|mermaid.exe|GeForce 6800 - Nalu (submarine, soft shadows, god rays)"
  # Luna was recognized by hash and installed but never listed here, so the post-install
  # check was silently skipped for it (measured 2026-11-05: the log reported
  # "installazioni fallite: 0" for a run in which the installer never even started, because
  # Wine printed "ShellExecuteEx failed: File not found." and still returned RC=0).
  # Being listed here verifies the INSTALL only: Luna still crashes at launch, and it is
  # deliberately NOT in the presentation baseline and not in run.sh's demo table.
  "luna|Luna.exe|GeForce 6/7 era - Luna (hair, Cg 1.x; installs, does not run yet)"
  # Mad Mod Mike (techdemo 39): installata l'8 novembre 2026. Non si avvia: muore su
  # un puntatore nullo a mike+0xa03af, e la sua stessa OutputDebugString dice
  # "Failed to initialize extension EXT_framebuffer_object". La misura dei nomi che
  # chiede (tools/nv_proc_wgl.exe, 156 nomi dal PE) da' 7 soli nomi di estensione non
  # risolvibili, tutti della bozza NV del 2004-2005: docs/mad-mod-mike.md. Essere qui
  # dentro serve a verificare l'INSTALL, non a dire che rende: non e' nella tabella
  # condivisa tools/nv_demo_table.sh ne' negli sweep, per non rendere verde una demo
  # che crasha.
  "mike|MadModMike.exe|GeForce 7800 GTX - Mad Mod Mike (fur, Cg 1.4 source shaders; starts and renders after tools/nv_mike_materiali.py rewires the materials)"
)

# Installers we know how to install, identified by CONTENT (sha256 + size), not by
# filename.  Why hash instead of name: the CD names differ per revision (Dusk_Ultra_1_1,
# BlobbyDancer_AMD), users rename files, and launching an arbitrary .exe found in a
# directory is not something an installer script should do.  An unrecognised .exe is
# skipped and its hash printed, so adding it is a deliberate act.
# Measured on this machine (sha256sum of ./techdemo_installers, 11 files).
SUPPORTED_INSTALLERS=(
  "c805acabf0cdb667abc539dd3800ae6060be0c71ee197cbd341cfae9dca8e109|74014720|dawn|Dawn / Fairy (GeForce FX 5800)"
  "cddd1f58b3b639841074987769df854ec1a40504c534b22e4311a9be651d2e93|89491325|gas|Last Chance Gas Station (GeForce FX 5900)"
  "1842dd6536dd5384e96cc2ed5feff4cc0492d6be3e5570d13bbae3c9d926ee2a|62943009|vulcan|Vulcan (GeForce FX 5900)"
  "fe18550c12ba3a1fabf546c1431539dc2f901477388db75d603c4dd1ff92bf31|87389789|dusk|Dusk Ultra 1.1 (GeForce FX 5900)"
  "823f066b327f27224f6ccb48b4fe3614638e311aa27705abca2e06e761b41bae|65755625|toys|Toys / DepthOfField (GeForce FX 5800)"
  "c362f08e88c478a683edf69de67911a6616ed58cee7d81003a7919b768c30768|70269992|truck|Time Machine / Truck (GeForce FX 5800)"
  "ae764c3907e596e3334ee480d7c788bd097d7a113eda2b565b1aa44708107cad|125215244|cs|Clear Sailing / PirateShip (GeForce 6800)"
  "d135395500f2c9c61eff174bb8c7643df79481824110f1c04e8eb40d76eedf03|125051857|timbury|Timbury / BugLooker (GeForce 6800)"
  "a360412386312462983084e64deb957d71f78cd722b80e8b963e9062526c50fb|138577963|nalu|Nalu / mermaid (GeForce 6800)"
  "43b4ce68fbe563e71f59e6ee2f806a09860bc4f6fb9d2afffcaca7f6989345fd|19440910|blobby|Blobby Dancer AMD (GeForce FX 5200)"
  # Luna: tech demo 26 (GeForce FX5200). L'installer non segue la convenzione
  # "Nvidia-Techdemo-NN-Geforce-XXX.exe" ma si chiama "LunaSetup_v2.exe", quindi il
  # nome non aiuterebbe: riconoscimento solo per contenuto (hash + dimensione).
  # L'eseguibile della demo si scoprira' dopo l'installazione: non lo inventiamo qui.
  "a6bab2887aac275d395cc43608127b3b44be485a96753b4087d32ff59e3904e4|138622843|luna|Nvidia techdemo 26 Luna (GeForce FX5200)"
  # Mad Mod Mike: techdemo numero 39, era GeForce 7800 GTX. Hash e dimensione misurati
  # su questa macchina l'8 novembre 2026 (sha256sum + stat -c %s). L'installer e' dello
  # stesso tipo InstallShield degli altri undici, quindi non c'e' niente di nuovo da
  # temere nel formato; il nome del file invece non dice niente di verificabile, quindi
  # il riconoscimento resta solo di contenuto.
  # L'eseguibile della demo NON e' ancora nella tabella DEMOS: lo si scoprira' dopo
  # l'installazione, come promettono le note di Luna, senza inventarselo.
  "9d99e32451ccd93ac8cf784f95eb50df8dc6b239ff1f3530b82864357905eb2d|160203454|mike|Nvidia techdemo 39 Mad Mod Mike (GeForce 7800 GTX)"
)

sha256_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

recognize() {  # $1 = installer path; prints "key|label" when the content is known
    local f=$1 h sz e
    [ -f "$f" ] || return 1
    h=$(sha256_of "$f"); sz=$(stat -c %s "$f" 2>/dev/null)
    for e in "${SUPPORTED_INSTALLERS[@]}"; do
        IFS='|' read -r eh esz ekey elabel <<<"$e"
        if [ "$h" = "$eh" ] && [ "$sz" = "$esz" ]; then printf '%s|%s\n' "$ekey" "$elabel"; return 0; fi
    done
    return 1
}

# Roots of the installed demos inside the prefix.  The old code searched
# "NVIDIA Corporation" while the prefix actually contains "Nvidia Corporation": on Linux
# that is a different path, so every lookup silently failed and --verify claimed
# "0 of 10" with exit code 0.  Searching is now case-insensitive and the errors are not
# hidden any more: a missing directory must be visible, not swallowed by 2>/dev/null.
prefix_roots() {
    local r
    for r in "$PREFIX/drive_c/Program Files (x86)" "$PREFIX/drive_c/Program Files"; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 1 -type d -iname '*nvidia*' 2>/dev/null
    done
}

find_exe() {  # $1 = executable name; prints every path found, canonical copy FIRST
    local name=$1 r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        find "$r" -maxdepth 6 -iname "$name" -type f 2>/dev/null
    done < <(prefix_roots) | sort -u | awk '
        # prefer the canonical bin/ over the variant directories (Nalu/bin6600 was being
        # picked by find order, and it is the lighter GeForce 6600 build with two
        # "consume" lines commented out in demoparams.txt)
        { p=$0; pen=0; if (p ~ /\/bin(\/|$)/) pen=0; else pen=1; print pen "\t" p }
    ' | sort -k1,1 -k2 | cut -f2-
}

report() {   # prints the table; leaves REPORT_FOUND set to how many demos are present
    local found n=0 copie=0
    REPORT_FOUND=0
    printf "%-9s %-21s %-11s %s\n" "DEMO" "EXECUTABLE" "STATE" "WHERE"
    for entry in "${DEMOS[@]}"; do
        IFS='|' read -r key exe desc <<<"$entry"
        found=$(find_exe "$exe")
        if [ -n "$found" ]; then
            n=$((n+1))
            printf "%-9s %-21s %-11s %s\n" "$key" "$exe" "INSTALLED" \
                "$(printf '%s' "$found" | head -1 | sed "s#^$PREFIX##")"
            if [ "$(printf '%s\n' "$found" | sed '/^$/d' | wc -l)" -gt 1 ]; then
                copie=$((copie+1))
                printf '          %s (%s copie nel prefisso; le altre: %s)\n' "-- attenzione" \
                    "$(printf '%s\n' "$found" | sed '/^$/d' | wc -l)" \
                    "$(printf '%s\n' "$found" | sed -n '2,$p' | sed "s#^$PREFIX##" | tr '\n' ' ')"
            fi
        else
            printf "%-9s %-21s %-11s\n" "$key" "$exe" "not found"
        fi
    done
    REPORT_FOUND=$n
    say "installed demos found in this prefix: $n of ${#DEMOS[@]}   (demo con copie multiple: $copie)"
}

matches() {  # $1 installer filename, $2 --only filter; true when this installer is selected
    [ -z "$2" ] && return 0
    local f=$(printf '%s' "$1" | tr 'A-Z' 'a-z') u=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    case "$f" in *"$u"*) return 0 ;; esac
    # --also accepts the table key (nalu, cs, ...): the mapping to the installer file
    # is done by name, not by luck
    for entry in "${DEMOS[@]}"; do
        IFS='|' read -r key _ _ <<<"$entry"
        [ "$key" = "$u" ] || continue
        case "$key" in
            gas)     [[ $f == *gas* ]] ;;
            vulcan)  [[ $f == *vulcan* ]] ;;
            dusk)    [[ $f == *dusk* ]] ;;
            dawn)    [[ $f == *dawn* ]] ;;
            blobby)  [[ $f == *blobby* ]] ;;
            truck)   [[ $f == *truck* || $f == *time*machine* ]] ;;
            toys)    [[ $f == *toys* ]] ;;
            cs)      [[ $f == *sailing* || $f == *pirateship* ]] ;;
            timbury) [[ $f == *timbury* ]] ;;
            nalu)    [[ $f == *nalu* ]] ;;
            *)       return 1 ;;
        esac
        return $?
    done
    return 1
}

matches_key() {   # $1 = chiave riconosciuta dalla tabella, $2 = valore di --only
    [ -z "$2" ] && return 0
    local k u
    k=$(printf '%s' "$1" | tr 'A-Z' 'a-z'); u=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    [ "$k" = "$u" ]
}

demo_for_installer() {
    local f=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    local key
    for key in gas vulcan dusk dawn blobby truck toys cs timbury nalu; do
        case "$key" in
            gas)     [[ $f == *gas* ]] && { echo gas; return; } ;;
            vulcan)  [[ $f == *vulcan* ]] && { echo vulcan; return; } ;;
            dusk)    [[ $f == *dusk* ]] && { echo dusk; return; } ;;
            dawn)    [[ $f == *dawn* ]] && { echo dawn; return; } ;;
            blobby)  [[ $f == *blobby* ]] && { echo blobby; return; } ;;
            truck)   [[ $f == *truck* || $f == *time*machine* ]] && { echo truck; return; } ;;
            toys)    [[ $f == *toys* ]] && { echo toys; return; } ;;
            cs)      [[ $f == *sailing* || $f == *pirateship* ]] && { echo cs; return; } ;;
            timbury) [[ $f == *timbury* ]] && { echo timbury; return; } ;;
            nalu)    [[ $f == *nalu* ]] && { echo nalu; return; } ;;
        esac
    done
    echo "?"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)       ACTION=list ;;
        --verify)     ACTION=verify ;;
        --dry-run)    ACTION=dry_run ;;
        --install)    ACTION=install ;;
        --selftest)   ACTION=selftest ;;
        --only)       [ $# -ge 2 ] || die "--only needs a name"; ONLY=$2; shift ;;
        --prefix)     [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift ;;
        --installers) [ $# -ge 2 ] || die "--installers needs a directory"; INSTALLERS=$2; shift ;;
        -h|--help)    sed -n '2,44p' "$0"; exit 0 ;;
        *)            die "unknown option: $1" ;;
    esac
    shift
done

if [ "$ACTION" = selftest ]; then
    # The witness has to tell "nothing happened" from "something happened", including the
    # subtle case where the FILE COUNT is the same but the BYTES are not (an installer that
    # rewrites or truncates without adding a file). Tested against a scratch tree, with no
    # wine and no real prefix, so it costs a second and can be run anywhere.
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/nv_witness.XXXXXX") || die "mktemp failed"
    ok=0; ko=0
    export PREFIX=$tmp
    mkdir -p "$PREFIX/drive_c/Program Files/x"
    printf 'aaa\n' > "$PREFIX/drive_c/Program Files/x/one.txt"
    printf 'bbbb\n' > "$PREFIX/drive_c/Program Files/x/two.txt"
    w1=$(prefix_witness); w2=$(prefix_witness)
    if [ "$(witness_changed "$w1" "$w2")" = uguale ]; then
        echo "  ok   stesso stato -> uguale ($w1)"; ok=$((ok+1))
    else echo "  FAIL stesso stato dovrebbe dare uguale"; ko=$((ko+1)); fi
    printf 'ccc\n' > "$PREFIX/drive_c/Program Files/x/three.txt"
    w3=$(prefix_witness)
    if [ "$(witness_changed "$w2" "$w3")" = cambiato ]; then
        echo "  ok   file aggiunto -> cambiato ($w2 -> $w3)"; ok=$((ok+1))
    else echo "  FAIL file aggiunto non rilevato"; ko=$((ko+1)); fi
    printf 'x\n' > "$PREFIX/drive_c/Program Files/x/three.txt"
    w4=$(prefix_witness)
    if [ "$(witness_changed "$w3" "$w4")" = cambiato ]; then
        echo "  ok   stesso numero di file, byte diversi -> cambiato ($w3 -> $w4)"; ok=$((ok+1))
    else echo "  FAIL sola variazione di byte non rilevata"; ko=$((ko+1)); fi
    # The witness does NOT claim to detect every modification: rewriting a file with the
    # same number of bytes is invisible to it by design (count and byte sum unchanged).
    # That is why the expected-executable check stays in place as well. Asserting the
    # limitation here keeps it written down instead of hidden.
    # "bbbb\n" is 5 bytes; "cccc\n" is 5 bytes too, so file count AND byte sum are both
    # unchanged while the content differs. That is the blind spot, asserted as such.
    printf 'cccc\n' > "$PREFIX/drive_c/Program Files/x/two.txt"
    w6=$(prefix_witness)
    if [ "$(witness_changed "$w4" "$w6")" = uguale ]; then
        echo "  ok   LIMITE NOTO: stesso conteggio e stessi byte, contenuto diverso -> il testimone non lo vede"; ok=$((ok+1))
    else echo "  FAIL il limite documentato non corrisponde al comportamento"; ko=$((ko+1)); fi
    rm -f "$PREFIX/drive_c/Program Files/x/one.txt"
    w5=$(prefix_witness)
    if [ "$(witness_changed "$w4" "$w5")" = cambiato ]; then
        echo "  ok   file rimosso -> cambiato"; ok=$((ok+1))
    else echo "  FAIL rimozione non rilevata"; ko=$((ko+1)); fi
    rm -rf "$tmp"
    echo "SELFTEST_TESTIMONE=$([ $ko -eq 0 ] && echo PASSO || echo FALLITO) ($ok ok, $ko falliti)"
    [ $ko -eq 0 ] || exit 1
    exit 0
fi

# A scan/verify should not require an installer directory that the user may have
# deliberately cleaned away, and should not require Wine just to read the prefix.
# Those dependencies apply only when ACTION=install actually runs setup payloads.
if [ "$ACTION" = install ]; then
    [ -x "$WINE" ] || die "wine not found: $WINE (run ./build.sh first, or set NV_WINE=/path/to/wine)"
    [ -d "$INSTALLERS" ] || die "installer directory not found: $INSTALLERS
  put the installer .exe files there (also searched: $DIR/../techdemo_installers and
  \$HOME/techdemo_installers), or pass --installers DIR"
fi

if [ "$ACTION" = list ] || [ "$ACTION" = verify ] || [ "$ACTION" = dry_run ]; then
    if [ "$ACTION" != verify ] && [ -d "$INSTALLERS" ]; then
        say "installers in $INSTALLERS (riconoscimento per contenuto, non per nome file)"
        shopt -s nullglob
        for f in "$INSTALLERS"/*.exe; do
            rec=$(recognize "$f")
            if [ -n "$rec" ]; then
                IFS='|' read -r k lbl <<<"$rec"
                printf '  SCELTO   %-58s -> %-8s %s\n' "$(basename "$f")" "$k" \
                    "$([ -f "${f%.exe}.iss" ] && echo '(file di risposta: installazione silenziosa)' || echo '(nessun .iss: installazione interattiva)')"
            else
                printf '  SCARTATO %-58s   contenuto non nella tabella dei supportati; sha256=%s\n' \
                    "$(basename "$f")" "$(sha256_of "$f")"
            fi
        done
        echo
    fi
    if [ "$ACTION" = dry_run ]; then
        say "dry run: nessun eseguibile verra' lanciato; questi lo sarebbero"
        shopt -s nullglob
        for f in "$INSTALLERS"/*.exe; do
            rec=$(recognize "$f") || continue
            IFS='|' read -r k lbl <<<"$rec"
            matches "$(basename "$f")" "$ONLY" || continue
            matches_key "$k" "$ONLY" || continue
            printf '  %-8s %s %s\n' "$k" "$f" \
                "$([ -f "${f%.exe}.iss" ] && echo "[con /s /f1...]" || echo "[interattivo]")"
        done
        echo
    fi
    report
    # Una verifica che non trova nulla non deve uscire 0: cosi' la ricerca con le
    # maiuscole sbagliate e' rimasta nascosta (stampava "0 of 10" e ritorno' successo).
    if [ "${REPORT_FOUND:-0}" = "0" ]; then
        echo "VERIFICA: nessuna demo trovata nel prefisso: $PREFIX" >&2
        exit 1
    fi
    exit 0
fi

# --- prefix ----------------------------------------------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
    say "creating the prefix: $PREFIX"
    export WINEPREFIX="$PREFIX" WINEDEBUG=-all WINE_USE_EGL=0
    "$WINE" wineboot --init || die "wineboot --init failed (RC=$?)"
    say "prefix ready"
else
    say "prefix already present: $PREFIX"
fi
export WINEPREFIX="$PREFIX" WINE_USE_EGL=0
# Without this Wine asks to install Mono with a GUI dialog, which blocks the run
# (same note as in run.sh).
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=,mshtml=}"

# --- install ---------------------------------------------------------------
shopt -s nullglob
scelti=0
scartati=0
falliti=0
for file in "$INSTALLERS"/*.exe; do
    name=$(basename "$file")
    rec=$(recognize "$file")
    if [ -z "$rec" ]; then
        say "installer: $name  -> NON SUPPORTATO: contenuto non riconosciuto, non viene eseguito"
        say "  sha256=$(sha256_of "$file")  size=$(stat -c %s "$file" 2>/dev/null)"
        say "  per supportarlo aggiungi questa coppia alla tabella SUPPORTED_INSTALLERS"
        say "  (dopo aver verificato cosa installa): non lanciamo exe sconosciuti nel prefisso."
        scartati=$((scartati+1))
        continue
    fi
    IFS='|' read -r dkey dlabel <<<"$rec"
    matches "$name" "$ONLY" || continue
    matches_key "$dkey" "$ONLY" || continue
    scelti=$((scelti+1))
    say "installer: $name"
    prima=$(prefix_witness)     # fingerprint of drive_c before this installer runs
    iss="${file%.exe}.iss"
    if [ -f "$iss" ]; then
        win_iss=$("$WINE" winepath -w "$iss" 2>/dev/null)
        [ -n "$win_iss" ] || die "winepath could not map $iss to a Windows path"
        say "  silent mode, using response file $(basename "$iss")"
        WINEDEBUG=-all "$WINE" "$file" /s "/f1$win_iss"
        rc=$?
        "$WINE" wineserver -w 2>/dev/null
        say "  installer exited RC=$rc - which proves nothing, so the files are checked below"
    else
        say "  no .iss response file: starting the installer in normal mode."
        say "  Click Next / Install / Finish, and LEAVE the default directory"
        say "  (C:\\Program Files (x86)\\NVIDIA Corporation\\NVidia demos\\<name>)."
        say "  If you want silent installs later, record the response file YOURSELF once:"
        say "    $WINE '$file' '/rC:\\temp\\$(basename "${file%.exe}").iss'"
        say "  then keep that .iss next to the installer, with the same base name."
        "$WINE" "$file"
        rc=$?
        "$WINE" wineserver -w 2>/dev/null
        say "  installer exited RC=$rc"
    fi
    dopo=$(prefix_witness)
    if [ "$(witness_changed "$prima" "$dopo")" = uguale ]; then
        # Nothing at all was written: whatever the exit code said, this installer did not
        # install. Counted as a failure so the summary cannot claim a clean run.
        say "  FALLITO: il prefisso non e' cambiato per niente (witness $dopo identica a prima): l'installer non ha scritto file"
        falliti=$((falliti+1))
    else
        say "  witness prefisso: $prima -> $dopo (file scritti dall'installer)"
    fi
    # L header prometteva questo controllo e il codice non lo faceva: un installer puo'
    # uscire con RC=0 senza installare niente (misurato con il solo "/s").
    exp=""
    for entry in "${DEMOS[@]}"; do
        IFS='|' read -r k e _ <<<"$entry"; [ "$k" = "$dkey" ] && exp=$e
    done
    if [ -n "$exp" ]; then
        if [ -n "$(find_exe "$exp")" ]; then
            say "  verificato: $exp presente nel prefisso"
        else
            say "  FALLITO: $name e' uscito con RC=$rc ma $exp NON risulta nel prefisso"
            falliti=$((falliti+1))
        fi
    fi
done
[ "$scelti" -gt 0 ] || say "no installer matched (check --only, and the contents of $INSTALLERS)"
say "scelti: $scelti   non riconosciuti e saltati: $scartati   installazioni fallite: $falliti"

# Timbury needs companion files, not a modified installer payload.  The tools
# refuse to touch anything except the known BugLooker.exe hash and write their
# files next to it.  The current default is the race companion winmm.dll: it
# leaves BugLooker.exe original and patches the startup steering loop in memory
# without writing logs.  The DLL is now built from the repo sources by
# nv_timbury_race_winmm_build.py (NASM cave + generated C + MinGW), not copied
# from a stale binary.  The old BugLooker_offset_swarm.exe remains available
# for diagnosis only.
if [ -x "$DIR/tools/nv_timbury_race_winmm_patch.py" ] && command -v python3 >/dev/null 2>&1; then
    first_timbury=$(find_exe BugLooker.exe | head -1)
    if [ -n "$first_timbury" ]; then
        if python3 "$DIR/tools/nv_timbury_race_winmm_patch.py" "$first_timbury"; then
            say "  Timbury race companion built and installed (nv_timbury_race_winmm_patch.py)"
        else
            say "  FALLITO: Timbury race companion non creato (nv_timbury_race_winmm_patch.py); run.sh timbury non avra' la winmm.dll di race"
            falliti=$((falliti+1))
        fi
    fi
fi
for nv_timbury_tool in nv_timbury_offset_patch.py nv_timbury_swarm_patch.py; do
    if [ -x "$DIR/tools/$nv_timbury_tool" ] && command -v python3 >/dev/null 2>&1; then
        first_timbury=$(find_exe BugLooker.exe | head -1)
        if [ -n "$first_timbury" ]; then
            if python3 "$DIR/tools/$nv_timbury_tool" "$first_timbury"; then
                say "  Timbury companion checked/created ($nv_timbury_tool)"
            else
                say "  FALLITO: Timbury companion non creato ($nv_timbury_tool); run.sh timbury potrebbe non funzionare"
                falliti=$((falliti+1))
            fi
        fi
    fi
done

echo
say "where each demo lives now"
report
say "to run one: ./run.sh          (menu)     or     ./run.sh nalu"
