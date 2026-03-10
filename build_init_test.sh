#!/bin/bash
# =============================================================================
# Build init_test for BCM7231B2 (BMIPS4380, MIPS32 R1)
# Diagnostic init — tests console output paths
#
# Static binary, musl libc, cross-compiled with Bootlin mips32el toolchain.
# Runs in Docker (linux/amd64).
#
# Produces: build_output/init_test (static, tiny)
#
# Usage: ./build_init_test.sh
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

echo "============================================"
echo "  FROG-HACK init_test Build"
echo "  Static musl MIPS32 R1 diagnostic init"
echo "============================================"
echo ""

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$BASEDIR/init_test.c:/src/init_test.c:ro" \
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

echo "[3/3] Compiling init_test.c..."
${CROSS}-gcc -static -Os -mips32 -o /tmp/init_test /src/init_test.c
${CROSS}-strip /tmp/init_test

echo ""
echo "Binary info:"
file /tmp/init_test
ls -la /tmp/init_test
echo ""

# Verify MIPS32 R1 (no R2 instructions)
${CROSS}-readelf -A /tmp/init_test | grep -i "isa\|mips"

cp /tmp/init_test /output/init_test
echo "[OK] init_test copied to build_output/"
'

echo ""
echo "============================================"
echo "  Build complete: build_output/init_test"
echo "============================================"
ls -la "$OUTDIR/init_test"
