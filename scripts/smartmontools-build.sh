#!/bin/bash
# =============================================================================
# In-container smartmontools build (static C++, musl, MIPS32 R1) — invoked by
# `make smartctl`. The box drops `smartctl -j` reports of its backup disk
# where the servers' backup monitor reads them.
# Output: /output/smartctl
# =============================================================================
set -e

SMARTMONTOOLS_VERSION="${SMARTMONTOOLS_VERSION:?SMARTMONTOOLS_VERSION not set}"
TARBALL="smartmontools-${SMARTMONTOOLS_VERSION}.tar.gz"
URL="https://github.com/smartmontools/smartmontools/releases/download/RELEASE_${SMARTMONTOOLS_VERSION//./_}/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"

echo "============================================"
echo "  smartmontools ${SMARTMONTOOLS_VERSION} — static MIPS32 R1"
echo "============================================"

if [ ! -f "/dl/$TARBALL" ]; then
    echo "[*] Downloading $URL ..."
    wget -q -O "/dl/$TARBALL.part" "$URL"
    mv "/dl/$TARBALL.part" "/dl/$TARBALL"
fi

BUILDDIR=/tmp/smart
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/smartmontools-${SMARTMONTOOLS_VERSION}"

echo "[*] Configuring..."
./configure \
    --host="${CROSS}" \
    --without-libsystemd \
    --without-selinux \
    --without-libcap-ng \
    --without-nvme-devicescan \
    --without-update-smart-drivedb \
    --without-gnupg \
    CC="${CROSS}-gcc" \
    CXX="${CROSS}-g++" \
    LDFLAGS="-static" \
    CXXFLAGS="-Os" CFLAGS="-Os" \
    2>&1 | tail -3

echo "[*] Building smartctl..."
make -j"$(nproc)" smartctl 2>&1 | tail -3
[ -f smartctl ] || { echo "!!! BUILD FAILED !!!"; exit 1; }
file smartctl | grep -q 'statically linked' || { echo "!!! smartctl is not static !!!"; exit 1; }
cp smartctl /output/smartctl
"${CROSS}-strip" /output/smartctl

echo ""
echo "=== /output/smartctl ==="
ls -lh /output/smartctl
file /output/smartctl
