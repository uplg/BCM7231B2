#!/bin/bash
# =============================================================================
# Build mtd-utils (flash_erase, nandwrite) for mipsel MIPS32 R1
# Uses Bootlin toolchain (targets mips32 R1, not R2)
# BMIPS4380 on BCM7231 only supports MIPS32 Release 1
# =============================================================================
set -e

OUTDIR="$(pwd)/build_output"
mkdir -p "$OUTDIR"

echo "[*] Building static mtd-utils for mipsel (MIPS32 R1) via Docker..."

BUILDSCRIPT=$(mktemp)
cat > "$BUILDSCRIPT" << 'DOCKEREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Installing build dependencies..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils file >/dev/null 2>&1

echo "[2/5] Downloading Bootlin mips32el toolchain (MIPS32 R1, musl)..."
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
echo "    Download complete, extracting..."
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1

export PATH="${TOOLCHAIN}/bin:${PATH}"
# Bootlin uses mipsel-buildroot-linux-gnu- prefix
CROSS=$(ls ${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed 's/-gcc$//' | xargs basename)
echo "    Cross prefix: ${CROSS}"
CC=${CROSS}-gcc
STRIP=${CROSS}-strip

echo "[3/5] Checking compiler targets MIPS32 R1..."
${CC} --version | head -1
echo "int main(){return 0;}" > /tmp/test.c
${CC} -static -o /tmp/test_bin /tmp/test.c
file /tmp/test_bin
readelf -h /tmp/test_bin | grep -i "flags"

echo "[4/5] Downloading mtd-utils 2.1.2..."
cd /tmp
wget -q https://infraroot.at/pub/mtd/mtd-utils-2.1.2.tar.bz2
tar xjf mtd-utils-2.1.2.tar.bz2
cd mtd-utils-2.1.2

echo "[5/5] Compiling flash_erase and nandwrite..."

CFLAGS_COMMON="-Os -D_GNU_SOURCE"

echo "  Compiling library objects..."
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libmtd.c -o lib/libmtd.o
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libmtd_legacy.c -o lib/libmtd_legacy.o
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/common.c -o lib/common.o
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libcrc32.c -o lib/libcrc32.o
echo "    All library objects OK"

LIB_OBJS="lib/libmtd.o lib/libmtd_legacy.o lib/common.o lib/libcrc32.o"

echo "  Building flash_erase..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"2.1.2\" \
    misc-utils/flash_erase.c ${LIB_OBJS} -o flash_erase

echo "  Building nandwrite..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"2.1.2\" \
    nand-utils/nandwrite.c ${LIB_OBJS} -o nandwrite

echo ""
for tool in flash_erase nandwrite; do
    if [ -f "$tool" ]; then
        ${STRIP} "$tool"
        cp "$tool" /output/
        echo "[OK] $tool:"
        ls -lh /output/$tool
        file /output/$tool
    else
        echo "[ERROR] $tool build failed"
    fi
done
DOCKEREOF

chmod +x "$BUILDSCRIPT"

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$BUILDSCRIPT:/build.sh:ro" \
    ubuntu:20.04 bash /build.sh

rm -f "$BUILDSCRIPT"

echo ""
echo "[*] Done. Output:"
ls -lh "$OUTDIR/" | grep -E "flash_erase|nandwrite"
