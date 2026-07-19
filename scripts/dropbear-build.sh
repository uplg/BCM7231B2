#!/bin/bash
# =============================================================================
# In-container Dropbear SSH build (static multi-binary, MIPS32 R1) —
# invoked by `make dropbear`. Output: /output/dropbearmulti
# =============================================================================
set -e

DROPBEAR_VERSION="${DROPBEAR_VERSION:?DROPBEAR_VERSION not set}"
TARBALL="dropbear-${DROPBEAR_VERSION}.tar.bz2"
URL="https://matt.ucc.asn.au/dropbear/releases/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"

echo "============================================"
echo "  Dropbear ${DROPBEAR_VERSION} — static MIPS32 R1"
echo "============================================"

if [ ! -f "/dl/$TARBALL" ]; then
    echo "[*] Downloading $URL ..."
    wget -q -O "/dl/$TARBALL.part" "$URL"
    mv "/dl/$TARBALL.part" "/dl/$TARBALL"
fi

BUILDDIR=/tmp/db
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xjf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/dropbear-${DROPBEAR_VERSION}"

echo "[*] Configuring..."
./configure \
    --host="${CROSS}" \
    --disable-zlib \
    --disable-wtmp \
    --disable-lastlog \
    CC="${CC}" \
    LDFLAGS="-static" \
    CFLAGS="-Os" \
    2>&1 | tail -3

echo "[*] Building dropbearmulti..."
make PROGRAMS="dropbear dropbearkey dbclient scp" STATIC=1 MULTI=1 SCPPROGRESS=0 \
    -j"$(nproc)" 2>&1 | tail -10

[ -f dropbearmulti ] || { echo "!!! BUILD FAILED !!!"; exit 1; }

cp dropbearmulti /output/dropbearmulti
"${STRIP}" /output/dropbearmulti
echo ""
echo "=== /output/dropbearmulti ==="
ls -lh /output/dropbearmulti
file /output/dropbearmulti
