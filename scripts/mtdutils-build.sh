#!/bin/bash
# =============================================================================
# In-container mtd-utils build (flash_erase + nandwrite, static, MIPS32 R1) —
# invoked by `make mtdutils`. These also ship in the rootfs so the box can
# reflash itself over SSH (make flash-rootfs / flash-kernel).
# Output: /output/flash_erase, /output/nandwrite
# =============================================================================
set -e

MTDUTILS_VERSION="${MTDUTILS_VERSION:?MTDUTILS_VERSION not set}"
TARBALL="mtd-utils-${MTDUTILS_VERSION}.tar.bz2"
URL="https://infraroot.at/pub/mtd/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"
CFLAGS_COMMON="-Os -D_GNU_SOURCE"

echo "============================================"
echo "  mtd-utils ${MTDUTILS_VERSION} — static MIPS32 R1"
echo "============================================"

if [ ! -f "/dl/$TARBALL" ]; then
    echo "[*] Downloading $URL ..."
    wget -q -O "/dl/$TARBALL.part" "$URL"
    mv "/dl/$TARBALL.part" "/dl/$TARBALL"
fi

BUILDDIR=/tmp/mtd
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xjf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/mtd-utils-${MTDUTILS_VERSION}"

echo "[*] Compiling library objects..."
for f in libmtd libmtd_legacy common libcrc32; do
    ${CC} ${CFLAGS_COMMON} -I./include -DVERSION=\"${MTDUTILS_VERSION}\" \
        -c "lib/${f}.c" -o "lib/${f}.o"
done
LIB_OBJS="lib/libmtd.o lib/libmtd_legacy.o lib/common.o lib/libcrc32.o"

echo "[*] Building flash_erase..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"${MTDUTILS_VERSION}\" \
    misc-utils/flash_erase.c ${LIB_OBJS} -o flash_erase

echo "[*] Building nandwrite..."
${CC} ${CFLAGS_COMMON} -static -I./include -DVERSION=\"${MTDUTILS_VERSION}\" \
    nand-utils/nandwrite.c ${LIB_OBJS} -o nandwrite

for tool in flash_erase nandwrite; do
    "${STRIP}" "$tool"
    cp "$tool" /output/
    echo "[OK] $tool:"
    ls -lh "/output/$tool"
    file "/output/$tool"
done
