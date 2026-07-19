#!/bin/bash
# =============================================================================
# Container-side builder for the standalone C diagnostic/init tools.
# Runs INSIDE AirTies-builder. One recipe for all of src/*.c — the old repo had
# a near-identical build_*.sh per tool.
#
# Mounts: /src -> src/ (ro), /output -> build_output/
# Args:   $1 = tool name (matches src/<name>.c and output binary name)
#
# Most tools are plain "-static -O2". Two need special flags:
#   init_raw  — freestanding, no libc/CRT (raw MIPS syscalls)
#   mount     — needs -D_GNU_SOURCE
# =============================================================================
set -e

TOOL="$1"
[ -n "$TOOL" ] || { echo "usage: ctool.sh <name>"; exit 1; }
SRC="/src/${TOOL}.c"
[ -f "$SRC" ] || { echo "[ERROR] source not found: $SRC"; exit 1; }

CROSS=$(cat /opt/cross-prefix)
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"

case "$TOOL" in
    init_raw)
        # No libc, no CRT — if this is silent, the problem is the kernel console.
        ${CC} -static -nostdlib -nostartfiles -mips32 -Os \
            -fno-stack-protector -fno-builtin -Wl,-e,_start \
            -o "/output/${TOOL}" "$SRC"
        ;;
    mount)
        ${CC} -static -Os -D_GNU_SOURCE -o "/output/${TOOL}" "$SRC"
        ;;
    *)
        ${CC} -static -O2 -o "/output/${TOOL}" "$SRC"
        ;;
esac

"${STRIP}" "/output/${TOOL}"
echo "[OK] ${TOOL}:"
ls -lh "/output/${TOOL}"
file "/output/${TOOL}"
