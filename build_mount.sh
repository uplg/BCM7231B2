#!/bin/bash
# =============================================================================
# Build minimal static mount binary for mipsel MIPS32 R1
# Uses Bootlin mips32el--musl toolchain in Docker
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

echo "[*] Building static mount for mipsel (MIPS32 R1) via Docker..."

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$BASEDIR/mount.c:/src/mount.c:ro" \
    ubuntu:20.04 bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/4] Installing build dependencies..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils file >/dev/null 2>&1

echo "[2/4] Downloading Bootlin mips32el toolchain..."
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1

export PATH="${TOOLCHAIN}/bin:${PATH}"
CROSS=$(ls ${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed "s/-gcc$//" | xargs basename)
CC=${CROSS}-gcc
STRIP=${CROSS}-strip

echo "[3/4] Verifying compiler..."
${CC} --version | head -1

echo "[4/4] Compiling mount..."
${CC} -static -Os -D_GNU_SOURCE -o /tmp/mount /src/mount.c
${STRIP} /tmp/mount

cp /tmp/mount /output/mount
echo ""
echo "[OK] mount binary:"
ls -lh /output/mount
file /output/mount
'

echo ""
echo "[*] Done. Result:"
ls -lh "$OUTDIR/mount"
file "$OUTDIR/mount"
