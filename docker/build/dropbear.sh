#!/bin/bash
# =============================================================================
# Container-side Dropbear SSH build (static, MIPS32 R1).
# Runs INSIDE AirTies-builder. Mounts: /output -> build_output/.
# Produces: /output/dropbearmulti
# =============================================================================
set -e

DROPBEAR_VERSION="${DROPBEAR_VERSION:-2020.81}"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2"
CROSS=$(cat /opt/cross-prefix)
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"

echo "[1/3] Downloading dropbear ${DROPBEAR_VERSION}..."
cd /tmp
wget -q "${DROPBEAR_URL}"
tar xjf "dropbear-${DROPBEAR_VERSION}.tar.bz2"
cd "dropbear-${DROPBEAR_VERSION}"

echo "[2/3] Configuring..."
./configure \
    --host="${CROSS}" \
    --disable-zlib \
    --disable-wtmp \
    --disable-lastlog \
    CC="${CC}" \
    LDFLAGS="-static" \
    CFLAGS="-Os" \
    2>&1 | tail -5

echo "[3/3] Building..."
make PROGRAMS="dropbear dropbearkey dbclient scp" STATIC=1 MULTI=1 SCPPROGRESS=0 -j"$(nproc)" 2>&1 | tail -10

if [ -f dropbearmulti ]; then
    cp dropbearmulti /output/dropbearmulti
    "${STRIP}" /output/dropbearmulti
    echo "[OK] dropbearmulti:"
    ls -lh /output/dropbearmulti
    file /output/dropbearmulti
else
    echo "[ERROR] multi build failed"
    exit 1
fi
