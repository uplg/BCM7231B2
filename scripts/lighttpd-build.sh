#!/bin/bash
# =============================================================================
# In-container lighttpd build (static, HTTP/2 + TLS 1.3 via mbedTLS, MIPS32 R1)
# — invoked by `make lighttpd`. Replaces busybox httpd as the box's web server.
# Output: /output/lighttpd
# =============================================================================
set -e

LIGHTTPD_VERSION="${LIGHTTPD_VERSION:?LIGHTTPD_VERSION not set}"
MBEDTLS_VERSION="${MBEDTLS_VERSION:?MBEDTLS_VERSION not set}"

LIGHTTPD_TARBALL="lighttpd-${LIGHTTPD_VERSION}.tar.xz"
LIGHTTPD_URL="https://download.lighttpd.net/lighttpd/releases-1.4.x/${LIGHTTPD_TARBALL}"
MBEDTLS_TARBALL="mbedtls-${MBEDTLS_VERSION}.tar.bz2"
MBEDTLS_URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/${MBEDTLS_TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
SYSROOT=/tmp/sysroot

echo "============================================"
echo "  lighttpd ${LIGHTTPD_VERSION} + mbedTLS ${MBEDTLS_VERSION} — static MIPS32 R1"
echo "============================================"

fetch() { # url tarball
    if [ ! -f "/dl/$2" ]; then
        echo "[*] Downloading $1 ..."
        wget -q -O "/dl/$2.part" "$1"
        mv "/dl/$2.part" "/dl/$2"
    fi
}
fetch "$MBEDTLS_URL" "$MBEDTLS_TARBALL"
fetch "$LIGHTTPD_URL" "$LIGHTTPD_TARBALL"

# --- mbedTLS (static libs only) ---
echo "[*] Building mbedTLS..."
rm -rf /tmp/mbedtls "$SYSROOT"; mkdir -p /tmp/mbedtls "$SYSROOT"
tar xf "/dl/$MBEDTLS_TARBALL" -C /tmp/mbedtls
cd /tmp/mbedtls/mbedtls-${MBEDTLS_VERSION}
make -j"$(nproc)" lib CC="${CROSS}-gcc" AR="${CROSS}-ar" CFLAGS="-Os" >/dev/null
mkdir -p "$SYSROOT/lib" "$SYSROOT/include"
cp library/*.a "$SYSROOT/lib/"
cp -r include/mbedtls include/psa "$SYSROOT/include/"

# --- lighttpd (fully static, built-in modules; CMake — release tarballs no
#     longer ship a pre-generated autotools configure) ---
echo "[*] Building lighttpd..."
rm -rf /tmp/lighttpd; mkdir -p /tmp/lighttpd
tar xf "/dl/$LIGHTTPD_TARBALL" -C /tmp/lighttpd
cd /tmp/lighttpd/lighttpd-${LIGHTTPD_VERSION}

cat > /tmp/toolchain.cmake << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR mipsel)
set(CMAKE_C_COMPILER ${CROSS}-gcc)
set(CMAKE_FIND_ROOT_PATH ${SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

# Static plugin roster — all module code is compiled in; this selects which
# ones are initialized. Keep in sync with /etc/lighttpd/lighttpd.conf.
cat > src/plugin-static.h << 'EOF'
PLUGIN_INIT(mod_indexfile)
PLUGIN_INIT(mod_dirlisting)
PLUGIN_INIT(mod_staticfile)
PLUGIN_INIT(mod_access)
PLUGIN_INIT(mod_accesslog)
PLUGIN_INIT(mod_alias)
PLUGIN_INIT(mod_redirect)
PLUGIN_INIT(mod_setenv)
PLUGIN_INIT(mod_expire)
PLUGIN_INIT(mod_cgi)
PLUGIN_INIT(mod_mbedtls)
EOF

mkdir -p build-cross && cd build-cross
cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/toolchain.cmake \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_STATIC=ON \
    -DWITH_MBEDTLS=ON \
    -DWITH_PCRE2=OFF \
    -DWITH_ZLIB=OFF \
    -DCMAKE_REQUIRED_LIBRARIES="mbedx509;mbedcrypto" \
    -DCMAKE_C_FLAGS="-Os -I${SYSROOT}/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-static -L${SYSROOT}/lib" \
    2>&1 | tail -8

make -j"$(nproc)" lighttpd 2>&1 | tail -8
LIGHTTPD_BIN=$(find . -name lighttpd -type f | head -1)
[ -n "$LIGHTTPD_BIN" ] || { echo "!!! BUILD FAILED !!!"; exit 1; }
file "$LIGHTTPD_BIN" | grep -q 'statically linked' || { echo "!!! NOT STATIC !!!"; file "$LIGHTTPD_BIN"; exit 1; }

"${CROSS}-strip" "$LIGHTTPD_BIN"
cp "$LIGHTTPD_BIN" /output/lighttpd
echo ""
echo "=== /output/lighttpd ==="
ls -lh /output/lighttpd
file /output/lighttpd
