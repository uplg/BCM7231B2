#!/bin/bash
# =============================================================================
# In-container wpa_supplicant build (static, MIPS32 R1) — invoked by
# `make wpa`. Builds a static libnl first (nl80211 driver needs it), then
# wpa_supplicant with the internal TLS/crypto (no OpenSSL): WPA2-PSK + SAE.
# Output: /output/wpa_supplicant, /output/wpa_cli, /output/wpa_passphrase
# =============================================================================
set -e

WPA_VERSION="${WPA_VERSION:?WPA_VERSION not set}"
LIBNL_VERSION="${LIBNL_VERSION:?LIBNL_VERSION not set}"

WPA_TARBALL="wpa_supplicant-${WPA_VERSION}.tar.gz"
WPA_URL="https://w1.fi/releases/${WPA_TARBALL}"
LIBNL_TAG="libnl${LIBNL_VERSION//./_}"
LIBNL_TARBALL="libnl-${LIBNL_VERSION}.tar.gz"
LIBNL_URL="https://github.com/thom311/libnl/releases/download/${LIBNL_TAG}/${LIBNL_TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"

echo "============================================"
echo "  wpa_supplicant ${WPA_VERSION} + libnl ${LIBNL_VERSION} — static MIPS32 R1"
echo "============================================"

for pair in "$WPA_TARBALL $WPA_URL" "$LIBNL_TARBALL $LIBNL_URL"; do
    set -- $pair
    if [ ! -f "/dl/$1" ]; then
        echo "[*] Downloading $2 ..."
        wget -q -O "/dl/$1.part" "$2"
        mv "/dl/$1.part" "/dl/$1"
    fi
done

BUILDDIR=/tmp/wpa
STAGE="$BUILDDIR/stage"
rm -rf "$BUILDDIR"; mkdir -p "$STAGE"
tar xzf "/dl/$LIBNL_TARBALL" -C "$BUILDDIR"
tar xzf "/dl/$WPA_TARBALL" -C "$BUILDDIR"

# --- libnl: static only, no CLI tools ---
echo "[*] Building libnl (static)..."
cd "$BUILDDIR/libnl-${LIBNL_VERSION}"
./configure \
    --host="${CROSS}" \
    --prefix="$STAGE" \
    --enable-static --disable-shared --disable-cli \
    CC="${CC}" CFLAGS="-Os" \
    2>&1 | tail -3
make -j"$(nproc)" 2>&1 | tail -3
make install 2>&1 | tail -2

# --- wpa_supplicant: nl80211 + internal TLS, no EAP/WPS/P2P bloat ---
echo "[*] Configuring wpa_supplicant..."
cd "$BUILDDIR/wpa_supplicant-${WPA_VERSION}/wpa_supplicant"
cat > .config << 'WPACONFIG'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_NO_CONFIG_WRITE=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
# No CONFIG_SAE: dragonfly needs the full crypto_bignum/EC API, which the
# internal TLS doesn't provide (link error). WPA2-PSK works on WPA2/WPA3
# mixed-mode networks; switch to CONFIG_TLS=mbedtls if WPA3-only is needed.
CONFIG_DEBUG_SYSLOG=y
WPACONFIG
# libnl paths passed explicitly — the builder image has no pkg-config
echo "CFLAGS += -I$STAGE/include/libnl3" >> .config
echo "LIBS += -L$STAGE/lib" >> .config

echo "[*] Building wpa_supplicant..."
make -j"$(nproc)" \
    CC="${CC}" \
    LDFLAGS="-static" \
    EXTRA_CFLAGS="-Os" \
    BINALL="wpa_supplicant wpa_cli" \
    wpa_supplicant wpa_cli wpa_passphrase \
    2>&1 | tail -10

for b in wpa_supplicant wpa_cli wpa_passphrase; do
    [ -f "$b" ] || { echo "!!! BUILD FAILED ($b missing) !!!"; exit 1; }
    cp "$b" "/output/$b"
    "${STRIP}" "/output/$b"
done

echo ""
echo "=== /output/wpa_supplicant ==="
ls -lh /output/wpa_supplicant /output/wpa_cli /output/wpa_passphrase
file /output/wpa_supplicant
