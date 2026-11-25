#!/usr/bin/env python3
"""
nv_timbury_race_winmm_build.py - build the Timbury BugLooker winmm companion.

The companion is a small 32-bit WINMM.dll replacement loaded from Timbury/bin.
It forwards the four winmm entry points that BugLooker imports, and installs one
narrow in-memory hook at 0x0042185c inside FUN_00421840.  The hook applies
Sleep(1) for the first 10 upstream steering calls, which avoids the startup race
seen on the Wine path.

The native hook code lives in nv_timbury_race_winmm_cave.nasm.  This script
assembles that cave, embeds the exact bytes in a generated C file, compiles the
PE32 DLL with MinGW, and verifies that the resulting DLL contains the cave.
"""

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

CAVE_NASM = "nv_timbury_race_winmm_cave.nasm"
CAVE_BASE = 0x0a000000


def parse_labels(lst_path):
    labels = {}
    pending = []
    addr_re = re.compile(r"^\s*\d+\s+([0-9A-Fa-f]{8})\s+(.+)$")
    label_re = re.compile(r"^\s*\d+\s+([A-Za-z_][A-Za-z0-9_]*):\s*$")
    data_label_re = re.compile(
        r"^\s*\d+\s+([0-9A-Fa-f]{8})\s+.*?\b([A-Za-z_][A-Za-z0-9_]*):\s+(dd|db|times|align)\b"
    )

    with open(lst_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = data_label_re.match(line)
            if m:
                labels[m.group(2)] = int(m.group(1), 16)
                continue

            m = addr_re.match(line)
            if m and pending:
                off = int(m.group(1), 16)
                for lbl in pending:
                    labels[lbl] = off
                pending = []

            m = label_re.match(line)
            if m:
                pending.append(m.group(1))

    return labels


def c_bytes(data):
    out = []
    for i in range(0, len(data), 16):
        out.append("    " + ",".join("%d" % b for b in data[i:i + 16]) + ",")
    return "\n".join(out)


def run(cmd, **kwargs):
    subprocess.run(cmd, check=True, **kwargs)


def generated_c(defs, cave):
    return r'''#include <windows.h>
#include <mmsystem.h>
#include <joystickapi.h>

''' + "\n".join(defs) + r'''

static const unsigned char CAVE_BYTES[] = {
''' + c_bytes(cave) + r'''};

static unsigned char *cave_mem;
static HMODULE real_winmm;

typedef MMRESULT (WINAPI *joySetCapture_t)(HWND, UINT, UINT, WINBOOL);
typedef MMRESULT (WINAPI *joySetThreshold_t)(UINT, UINT);
typedef MMRESULT (WINAPI *joyReleaseCapture_t)(UINT);
typedef MMRESULT (WINAPI *joyGetPosEx_t)(UINT, LPJOYINFOEX);

static joySetCapture_t real_joySetCapture;
static joySetThreshold_t real_joySetThreshold;
static joyReleaseCapture_t real_joyReleaseCapture;
static joyGetPosEx_t real_joyGetPosEx;

static void ensure_real(void)
{
    WCHAR path[MAX_PATH];

    GetSystemDirectoryW(path, MAX_PATH);
    lstrcatW(path, L"\\winmm.dll");
    real_winmm = LoadLibraryW(path);
    if (!real_winmm)
        return;

    real_joySetCapture = (joySetCapture_t)GetProcAddress(real_winmm, "joySetCapture");
    real_joySetThreshold = (joySetThreshold_t)GetProcAddress(real_winmm, "joySetThreshold");
    real_joyReleaseCapture = (joyReleaseCapture_t)GetProcAddress(real_winmm, "joyReleaseCapture");
    real_joyGetPosEx = (joyGetPosEx_t)GetProcAddress(real_winmm, "joyGetPosEx");
}

static void patch_jmp(unsigned int addr, unsigned int target, int nops_after)
{
    DWORD old;
    int disp = (int)(target - (addr + 5));

    if (!VirtualProtect((void *)addr, 0x40, PAGE_EXECUTE_READWRITE, &old))
        return;

    ((unsigned char *)addr)[0] = 0xe9;
    *(int *)(void *)(addr + 1) = disp;
    for (int i = 0; i < nops_after; ++i)
        ((unsigned char *)addr)[5 + i] = 0x90;

    VirtualProtect((void *)addr, 0x40, old, &old);
}

static void install_hooks(void)
{
    HMODULE base;
    HMODULE k32;

    if (cave_mem)
        return;

    base = GetModuleHandleA(NULL);
    if ((unsigned)base != 0x400000u)
        return;

    cave_mem = (unsigned char *)VirtualAlloc((void *)CAVE_BASE, CAVE_LEN,
                                             MEM_COMMIT | MEM_RESERVE,
                                             PAGE_EXECUTE_READWRITE);
    if (cave_mem != (void *)CAVE_BASE)
        return;

    CopyMemory(cave_mem, CAVE_BYTES, CAVE_LEN);

    k32 = GetModuleHandleA("kernel32.dll");
    if (!k32)
        return;

    *(unsigned int *)(cave_mem + OFF_CREATEFILE) =
        (unsigned int)GetProcAddress(k32, "CreateFileA");
    *(unsigned int *)(cave_mem + OFF_WRITEFILE) =
        (unsigned int)GetProcAddress(k32, "WriteFile");
    *(unsigned int *)(cave_mem + OFF_SLEEP_ADDR) =
        (unsigned int)GetProcAddress(k32, "Sleep");
    *(unsigned int *)(cave_mem + OFF_TICK_ADDR) =
        (unsigned int)GetProcAddress(k32, "GetTickCount");

    *(unsigned int *)(cave_mem + OFF_SLEEP_ENABLE) = 1;
    *(unsigned int *)(cave_mem + OFF_SLEEP_MS) = 1;
    *(unsigned int *)(cave_mem + OFF_SLEEP_CALLS) = 10;
    *(unsigned int *)(cave_mem + OFF_SLEEP_COUNT) = 0;

    *(unsigned int *)(cave_mem + OFF_CREATION_COUNT) = 0x7fffffffu;
    *(unsigned int *)(cave_mem + OFF_DIST_COUNT) = 0x7fffffffu;
    *(unsigned int *)(cave_mem + OFF_TRANSFORM_COUNT) = 0x7fffffffu;
    *(unsigned int *)(cave_mem + OFF_UPSTREAM_COUNT) = 0x7fffffffu;

    patch_jmp(UPSTREAM_PATCH_ADDR, CAVE_BASE + OFF_UPSTREAM_HOOK, UPSTREAM_NOP_TAIL);
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)hinst;
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinst);
        install_hooks();
    }

    return TRUE;
}

MMRESULT WINAPI joySetCapture(HWND hwnd, UINT id, UINT period, WINBOOL delayed)
{
    install_hooks();
    if (!real_winmm)
        ensure_real();
    if (real_joySetCapture)
        return real_joySetCapture(hwnd, id, period, delayed);
    return 0;
}

MMRESULT WINAPI joySetThreshold(UINT id, UINT threshold)
{
    install_hooks();
    if (!real_winmm)
        ensure_real();
    if (real_joySetThreshold)
        return real_joySetThreshold(id, threshold);
    return 0;
}

MMRESULT WINAPI joyReleaseCapture(UINT id)
{
    install_hooks();
    if (!real_winmm)
        ensure_real();
    if (real_joyReleaseCapture)
        return real_joyReleaseCapture(id);
    return 0;
}

MMRESULT WINAPI joyGetPosEx(UINT id, LPJOYINFOEX info)
{
    install_hooks();
    if (!real_winmm)
        ensure_real();
    if (real_joyGetPosEx)
        return real_joyGetPosEx(id, info);
    return 0;
}
'''


def generated_def():
    return (
        "LIBRARY winmm.dll\n"
        "EXPORTS\n"
        "joySetCapture\n"
        "joySetThreshold\n"
        "joyReleaseCapture\n"
        "joyGetPosEx\n"
    )


def check_pe32_dll(path):
    data = open(path, "rb").read()
    if len(data) < 0x1000 or data[:2] != b"MZ":
        raise RuntimeError("built file is not a PE image")

    lfanew = struct.unpack_from("<I", data, 0x3c)[0]
    if data[lfanew:lfanew + 4] != b"PE\0\0":
        raise RuntimeError("built file has no PE signature")

    magic = struct.unpack_from("<H", data, lfanew + 24)[0]
    if magic != 0x10b:
        raise RuntimeError("built file is not PE32")

    characteristics = struct.unpack_from("<H", data, lfanew + 22)[0]
    if not (characteristics & 0x2000):
        raise RuntimeError("built file is not marked as a DLL")


def check_cave(path, cave):
    data = open(path, "rb").read()
    if data.find(cave) < 0:
        raise RuntimeError("built DLL does not contain the expected code cave")


def build_dll(out_path):
    tools_dir = os.path.dirname(os.path.abspath(__file__))
    nasm_source = os.path.join(tools_dir, CAVE_NASM)
    if not os.path.isfile(nasm_source):
        raise RuntimeError("missing cave source: %s" % nasm_source)

    if shutil.which("nasm") is None:
        raise RuntimeError("nasm is required to build the Timbury winmm companion")
    if shutil.which("i686-w64-mingw32-gcc") is None:
        raise RuntimeError("i686-w64-mingw32-gcc is required to build the Timbury winmm companion")

    out_path = os.path.abspath(out_path)
    tmpdir = tempfile.mkdtemp(prefix="nv_timbury_winmm_")
    try:
        shutil.copy2(nasm_source, os.path.join(tmpdir, CAVE_NASM))

        cave_bin = os.path.join(tmpdir, "cave.bin")
        cave_lst = os.path.join(tmpdir, "cave.lst")
        run(["nasm", "-f", "bin", "-o", cave_bin, CAVE_NASM, "-l", cave_lst], cwd=tmpdir)

        labels = parse_labels(cave_lst)
        required = [
            "upstream_hook",
            "createfile_addr",
            "writefile_addr",
            "sleep_addr",
            "sleep_enable",
            "sleep_ms",
            "tick_addr",
            "sleep_calls",
            "sleep_count",
            "creation_count",
            "dist_count",
            "transform_count",
            "upstream_count",
        ]
        for label in required:
            if label not in labels:
                raise RuntimeError("missing cave label: %s" % label)

        cave = open(cave_bin, "rb").read()
        if len(cave) != 1904:
            raise RuntimeError("unexpected cave length: %d bytes, expected 1904" % len(cave))

        defs = []
        for name, val in [
            ("CAVE_BASE", CAVE_BASE),
            ("CAVE_LEN", len(cave)),
            ("UPSTREAM_PATCH_ADDR", 0x0042185c),
            ("UPSTREAM_NOP_TAIL", 3),
            ("OFF_UPSTREAM_HOOK", labels["upstream_hook"]),
            ("OFF_CREATEFILE", labels["createfile_addr"]),
            ("OFF_WRITEFILE", labels["writefile_addr"]),
            ("OFF_SLEEP_ADDR", labels["sleep_addr"]),
            ("OFF_SLEEP_ENABLE", labels["sleep_enable"]),
            ("OFF_SLEEP_MS", labels["sleep_ms"]),
            ("OFF_TICK_ADDR", labels["tick_addr"]),
            ("OFF_SLEEP_CALLS", labels["sleep_calls"]),
            ("OFF_SLEEP_COUNT", labels["sleep_count"]),
            ("OFF_CREATION_COUNT", labels["creation_count"]),
            ("OFF_DIST_COUNT", labels["dist_count"]),
            ("OFF_TRANSFORM_COUNT", labels["transform_count"]),
            ("OFF_UPSTREAM_COUNT", labels["upstream_count"]),
        ]:
            defs.append("#define %s 0x%x" % (name, val))

        c_path = os.path.join(tmpdir, "winmm_race.c")
        def_path = os.path.join(tmpdir, "winmm_race.def")
        dll_path = os.path.join(tmpdir, "winmm_race.dll")

        with open(c_path, "w", encoding="utf-8") as f:
            f.write(generated_c(defs, cave))
        with open(def_path, "w", encoding="utf-8") as f:
            f.write(generated_def())

        run([
            "i686-w64-mingw32-gcc",
            "-m32",
            "-O2",
            "-Wall",
            "-shared",
            "winmm_race.c",
            "-o", "winmm_race.dll",
            "winmm_race.def",
            "-lkernel32",
            "-Wl,--kill-at",
        ], cwd=tmpdir)

        check_pe32_dll(dll_path)
        check_cave(dll_path, cave)

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        shutil.copy2(dll_path, out_path)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    return out_path


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="winmm_race.dll", help="output DLL path")
    ap.add_argument("--print-cave-length", action="store_true",
                    help="assemble the cave and print its length")
    args = ap.parse_args(argv[1:])

    if args.print_cave_length:
        tools_dir = os.path.dirname(os.path.abspath(__file__))
        tmpdir = tempfile.mkdtemp(prefix="nv_timbury_cave_")
        try:
            shutil.copy2(os.path.join(tools_dir, CAVE_NASM), os.path.join(tmpdir, CAVE_NASM))
            run(["nasm", "-f", "bin", "-o", "cave.bin", CAVE_NASM], cwd=tmpdir)
            print(len(open(os.path.join(tmpdir, "cave.bin"), "rb").read()))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
        return 0

    build_dll(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
