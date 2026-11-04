#!/bin/bash
# In-container mtd-utils build (flash_erase + nandwrite, static, MIPS32 R1),
# invoked by `make mtdutils`. These also ship in the rootfs so the box can
# reflash itself over SSH (make flash-rootfs / flash-kernel). The UBI tools
# too: ubiformat writes the rootfs UBI image, ubiattach/ubimkvol bring up the
# /config UBIFS (mkfs.ubifs and ubinize, for the host, come with the builder image).
# Output: /output/{flash_erase,nandwrite,ubiformat,ubiattach,ubimkvol,ubiupdatevol,ubirename,ubirmvol}
set -e
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

MTDUTILS_VERSION="${MTDUTILS_VERSION:?MTDUTILS_VERSION not set}"
TARBALL="mtd-utils-${MTDUTILS_VERSION}.tar.bz2"
URL="https://infraroot.at/pub/mtd/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"
CFLAGS=(-Os -D_GNU_SOURCE -I./include "-DVERSION=\"${MTDUTILS_VERSION}\"")

echo "mtd-utils ${MTDUTILS_VERSION}: static, MIPS32 R1"

fetch "$TARBALL" "$URL"

BUILDDIR=/tmp/mtd
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xjf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/mtd-utils-${MTDUTILS_VERSION}"

echo "[*] Compiling library objects..."
for f in libmtd libmtd_legacy common libcrc32 libubi libscan libubigen; do
    "$CC" "${CFLAGS[@]}" -c "lib/${f}.c" -o "lib/${f}.o"
done
LIB_OBJS=(lib/libmtd.o lib/libmtd_legacy.o lib/common.o lib/libcrc32.o)

echo "[*] Building flash_erase..."
"$CC" "${CFLAGS[@]}" -static misc-utils/flash_erase.c "${LIB_OBJS[@]}" -o flash_erase

echo "[*] Building nandwrite..."
"$CC" "${CFLAGS[@]}" -static nand-utils/nandwrite.c "${LIB_OBJS[@]}" -o nandwrite

for tool in ubiformat ubiattach ubimkvol ubiupdatevol ubirename ubirmvol; do
    echo "[*] Building $tool..."
    "$CC" "${CFLAGS[@]}" -static "ubi-utils/$tool.c" "${LIB_OBJS[@]}" \
        lib/libubi.o lib/libscan.o lib/libubigen.o -o "$tool"
done

for tool in flash_erase nandwrite ubiformat ubiattach ubimkvol ubiupdatevol ubirename ubirmvol; do
    "${STRIP}" "$tool"
    cp "$tool" /output/
    echo "[OK] $tool:"
    ls -lh "/output/$tool"
    file "/output/$tool"
done
