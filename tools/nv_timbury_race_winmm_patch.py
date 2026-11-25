#!/usr/bin/env python3
"""
nv_timbury_race_winmm_patch.py - build and install the Timbury winmm companion.

BugLooker's CPU bugswarm physics starts before the program has settled its
timer and worker-thread state.  On the Wine path this can produce a startup
race: the steering loop sees inconsistent neighbour data, a zero distance is
divided by, and the bug direction/position become NaN.

This companion is a replacement WINMM.dll loaded by Win32 redirection from
Timbury/bin.  It does not modify BugLooker.exe.  It performs one narrow
in-memory patch:

    hook 0x0042185c inside FUN_00421840 for about 10 ms at the very beginning
    of the first upstream steering calls.

The production DLL has no logging path enabled.  It exposes the four winmm
entry points used by BugLooker and forwards them to the real system winmm.dll.

Source of truth:

    tools/nv_timbury_race_winmm_cave.nasm
    tools/nv_timbury_race_winmm_build.py

The installer builds the DLL with NASM and i686-w64-mingw32-gcc, checks that
the generated PE32 DLL contains the exact assembled cave, and writes it as:

    Timbury/bin/winmm.dll

The installed executable:

    Timbury/bin/BugLooker.exe

is left untouched.
"""

import hashlib
import os
import shutil
import subprocess
import sys

TARGET_NAME = "winmm.dll"
BUILD_SCRIPT = "nv_timbury_race_winmm_build.py"
EXE_SHA = "14dfe6e6c90f5a93d2e624448ef0f8e987bf29c9915915db7b3a0ee6f0b0b9d7"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def build_companion(builder, target_dir):
    tmp = os.path.join(target_dir, ".%s.tmp.%d" % (TARGET_NAME, os.getpid()))
    try:
        subprocess.run([sys.executable, builder, "--out", tmp], check=True)
        if not os.path.isfile(tmp):
            raise RuntimeError("builder did not create %s" % tmp)
        if os.path.getsize(tmp) == 0:
            raise RuntimeError("builder created an empty winmm.dll")
        return tmp
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv):
    if len(argv) != 2:
        print("usage: nv_timbury_race_winmm_patch.py PATH_TO_BUGLOOKER_EXE", file=sys.stderr)
        return 2

    exe = os.path.abspath(argv[1])
    if not os.path.isfile(exe):
        print("missing installed BugLooker.exe: %s" % exe, file=sys.stderr)
        return 2

    tools_dir = os.path.dirname(os.path.abspath(__file__))
    builder = os.path.join(tools_dir, BUILD_SCRIPT)
    if not os.path.isfile(builder):
        print("missing Timbury winmm builder: %s" % builder, file=sys.stderr)
        return 2

    exe_hash = sha256_file(exe)
    if exe_hash != EXE_SHA:
        print("warning: BugLooker.exe hash is not the known installed hash", file=sys.stderr)
        print("  expected %s" % EXE_SHA, file=sys.stderr)
        print("  found    %s" % exe_hash, file=sys.stderr)
        print("continuing without modifying the executable", file=sys.stderr)

    target = os.path.join(os.path.dirname(exe), TARGET_NAME)
    tmp = build_companion(builder, os.path.dirname(target))
    try:
        os.chmod(tmp, 0o755)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    print("Timbury race companion built and installed: %s" % target)
    print("  sha256: %s" % sha256_file(target))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
