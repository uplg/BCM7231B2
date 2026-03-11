#!/bin/bash
# Build genet_dump for BCM7231 (MIPS32 R1, static musl)
# Requires Docker (linux/amd64)
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

echo "[*] Building genet_dump via Docker..."

docker run --rm --platform linux/amd64 \
    -v "$BASEDIR/genet_dump.c:/src/genet_dump.c:ro" \
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
${CROSS}-gcc -static -O2 -Wall -Wextra -o /output/genet_dump /src/genet_dump.c
${CROSS}-strip /output/genet_dump
ls -lh /output/genet_dump
file /output/genet_dump
echo "  Done."
'

echo "[*] Output: $OUTDIR/genet_dump"
ls -lh "$OUTDIR/genet_dump"
