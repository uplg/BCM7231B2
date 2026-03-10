#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Installing build dependencies..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils >/dev/null 2>&1

echo "[2/5] Downloading Bootlin mipsel toolchain (mips32 R1)..."
cd /tmp
# Use Bootlin's pre-built toolchain for mipsel with glibc, targeting mips32 (R1)
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mipsel-32/tarballs/mipsel-32--glibc--stable-2024.05-1.tar.xz
echo "    Download complete, extracting..."
tar xf mipsel-32--glibc--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mipsel-32--glibc--stable-2024.05-1

export PATH="${TOOLCHAIN}/bin:${PATH}"
CROSS=mipsel-linux
CC=${CROSS}-gcc
STRIP=${CROSS}-strip

echo "[3/5] Checking compiler..."
${CC} --version | head -1
# Verify it targets mips32 R1
echo "int main(){return 0;}" > /tmp/test.c
${CC} -static -o /tmp/test_bin /tmp/test.c
readelf -h /tmp/test_bin | grep -i "flags"
readelf -A /tmp/test_bin 2>/dev/null | head -5

echo "[4/5] Downloading mtd-utils 2.1.2..."
cd /tmp
wget -q https://infraroot.at/pub/mtd/mtd-utils-2.1.2.tar.bz2
tar xjf mtd-utils-2.1.2.tar.bz2
cd mtd-utils-2.1.2

echo "[5/5] Compiling flash_erase and nandwrite (static, mips32 R1)..."

CFLAGS_COMMON="-Os -march=mips32"

# Compile library objects
echo "  Compiling library objects..."
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libmtd.c -o lib/libmtd.o
echo "    libmtd.o OK"
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libmtd_legacy.c -o lib/libmtd_legacy.o
echo "    libmtd_legacy.o OK"
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/common.c -o lib/common.o
echo "    common.o OK"
${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"2.1.2\" -c lib/libcrc32.c -o lib/libcrc32.o
echo "    libcrc32.o OK"

LIB_OBJS="lib/libmtd.o lib/libmtd_legacy.o lib/common.o lib/libcrc32.o"

# Build flash_erase
echo "  Building flash_erase..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"2.1.2\" \
    misc-utils/flash_erase.c ${LIB_OBJS} \
    -o flash_erase
echo "    flash_erase compiled"

# Build nandwrite
echo "  Building nandwrite..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"2.1.2\" \
    nand-utils/nandwrite.c ${LIB_OBJS} \
    -o nandwrite
echo "    nandwrite compiled"

# Strip and copy
echo ""
for tool in flash_erase nandwrite; do
    if [ -f "$tool" ]; then
        ${STRIP} "$tool"
        cp "$tool" /output/
        echo "[OK] $tool:"
        ls -lh /output/$tool
        readelf -h /output/$tool | grep -i "flags"
    else
        echo "[ERROR] $tool build failed"
    fi
done
DOCKEREOF
