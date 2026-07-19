#!/bin/bash
# =============================================================================
# Container-side mtd-utils build (flash_erase, nandwrite; static, MIPS32 R1).
# Runs INSIDE AirTies-builder. Mounts: /output -> build_output/.
# Produces: /output/flash_erase, /output/nandwrite
# =============================================================================
set -e

MTD_VERSION="${MTD_VERSION:-2.1.2}"
MTD_URL="https://infraroot.at/pub/mtd/mtd-utils-${MTD_VERSION}.tar.bz2"
CROSS=$(cat /opt/cross-prefix)
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"
CFLAGS_COMMON="-Os -D_GNU_SOURCE"

echo "[1/3] Downloading mtd-utils ${MTD_VERSION}..."
cd /tmp
wget -q "${MTD_URL}"
tar xjf "mtd-utils-${MTD_VERSION}.tar.bz2"
cd "mtd-utils-${MTD_VERSION}"

echo "[2/3] Compiling library objects..."
for obj in libmtd libmtd_legacy common libcrc32; do
    ${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"${MTD_VERSION}\" -c "lib/${obj}.c" -o "lib/${obj}.o"
done
LIB_OBJS="lib/libmtd.o lib/libmtd_legacy.o lib/common.o lib/libcrc32.o"

echo "[3/3] Building flash_erase + nandwrite..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"${MTD_VERSION}\" \
    misc-utils/flash_erase.c ${LIB_OBJS} -o flash_erase
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"${MTD_VERSION}\" \
    nand-utils/nandwrite.c ${LIB_OBJS} -o nandwrite

for tool in flash_erase nandwrite; do
    [ -f "$tool" ] || { echo "[ERROR] $tool build failed"; exit 1; }
    "${STRIP}" "$tool"
    cp "$tool" /output/
    echo "[OK] $tool:"; ls -lh "/output/$tool"; file "/output/$tool"
done
