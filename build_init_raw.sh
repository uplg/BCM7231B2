#!/bin/bash
# =============================================================================
# Build init_raw — absolute minimal init with NO libc, NO CRT
# Just raw MIPS syscalls. If this produces no output, the problem is
# 100% in the kernel console layer, not in userspace.
#
# Produces: build_output/init_raw (static, ~2-3 KB)
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

echo "============================================"
echo "  FROG-HACK init_raw Build"
echo "  NO libc, NO CRT — raw MIPS32 syscalls"
echo "============================================"
echo ""

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$BASEDIR/init_raw.c:/src/init_raw.c:ro" \
    ubuntu:22.04 bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/3] Installing build dependencies..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils file >/dev/null 2>&1

echo "[2/3] Downloading Bootlin mips32el toolchain..."
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1
export PATH="${TOOLCHAIN}/bin:${PATH}"

CROSS=$(ls ${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed "s/-gcc$//" | xargs basename)
echo "    Cross prefix: ${CROSS}"

echo "[3/3] Compiling init_raw.c (no libc, no CRT)..."
${CROSS}-gcc -static -nostdlib -nostartfiles -mips32 -Os \
    -fno-stack-protector -fno-builtin \
    -Wl,-e,_start \
    -o /tmp/init_raw /src/init_raw.c
${CROSS}-strip /tmp/init_raw

echo ""
echo "Binary info:"
file /tmp/init_raw
ls -la /tmp/init_raw

echo ""
echo "Disassembly of _start (first 40 instructions):"
${CROSS}-objdump -d /tmp/init_raw | head -60

echo ""
echo "ELF header:"
${CROSS}-readelf -h /tmp/init_raw

echo ""
echo "Program headers:"
${CROSS}-readelf -l /tmp/init_raw

cp /tmp/init_raw /output/init_raw
echo ""
echo "[OK] init_raw copied to build_output/"
'

echo ""
echo "============================================"
echo "  Build complete: build_output/init_raw"
echo "============================================"
ls -la "$OUTDIR/init_raw"
