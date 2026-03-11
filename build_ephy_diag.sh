#!/bin/bash
# Build ephy_diag for BCM7231 (MIPS32 R1, static musl)
# Requires Docker (linux/amd64)
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

echo "[*] Building ephy_diag via Docker..."

docker run --rm --platform linux/amd64 \
    -v "$BASEDIR/ephy_diag.c:/src/ephy_diag.c:ro" \
    -v "$OUTDIR:/output" \
    ubuntu:22.04 bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq wget xz-utils >/dev/null 2>&1

cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1
export PATH="${TOOLCHAIN}/bin:${PATH}"
CROSS=$(ls ${TOOLCHAIN}/bin/*-gcc | head -1 | sed "s/-gcc$//" | xargs basename)

echo "  Compiling with ${CROSS}-gcc..."
${CROSS}-gcc -static -O2 -o /output/ephy_diag /src/ephy_diag.c
${CROSS}-strip /output/ephy_diag
ls -lh /output/ephy_diag
file /output/ephy_diag
echo "  Done."
'

echo "[*] Output: $OUTDIR/ephy_diag"
ls -lh "$OUTDIR/ephy_diag"
