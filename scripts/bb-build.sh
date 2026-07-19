#!/bin/bash
# =============================================================================
# In-container BusyBox build (static, musl, MIPS32 R1) — invoked by `make busybox`.
# Toolchain is baked into the airties-builder image; tarballs cached in /dl.
# Output: /output/busybox
# =============================================================================
set -e

BUSYBOX_VERSION="${BUSYBOX_VERSION:?BUSYBOX_VERSION not set}"
TARBALL="busybox-${BUSYBOX_VERSION}.tar.bz2"
URL="https://busybox.net/downloads/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"
export ARCH=mips
export CROSS_COMPILE="${CROSS}-"

echo "============================================"
echo "  BusyBox ${BUSYBOX_VERSION} — static musl MIPS32 R1"
echo "============================================"

if [ ! -f "/dl/$TARBALL" ]; then
    echo "[*] Downloading $URL ..."
    wget -q -O "/dl/$TARBALL.part" "$URL"
    mv "/dl/$TARBALL.part" "/dl/$TARBALL"
fi

BUILDDIR=/tmp/bb
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/busybox-${BUSYBOX_VERSION}"

echo "[*] Configuring..."
make defconfig >/dev/null

# Static binary, no HUSH (ash only), no SELinux, no x86-only hwaccel,
# drop applets we never use on the STB.
sed -i 's/.*CONFIG_STATIC[^_].*/CONFIG_STATIC=y/' .config
for opt in CONFIG_HUSH CONFIG_HUSH_BASH_COMPAT CONFIG_HUSH_BRACE_EXPANSION \
    CONFIG_HUSH_LINENO_VAR CONFIG_HUSH_BASH_SOURCE_CURDIR CONFIG_HUSH_INTERACTIVE \
    CONFIG_HUSH_SAVEHISTORY CONFIG_HUSH_JOB CONFIG_HUSH_TICK CONFIG_HUSH_IF \
    CONFIG_HUSH_LOOPS CONFIG_HUSH_CASE CONFIG_HUSH_FUNCTIONS CONFIG_HUSH_LOCAL \
    CONFIG_HUSH_RANDOM_SUPPORT CONFIG_HUSH_MODE_X CONFIG_HUSH_ECHO \
    CONFIG_HUSH_PRINTF CONFIG_HUSH_TEST CONFIG_HUSH_HELP CONFIG_HUSH_EXPORT \
    CONFIG_HUSH_EXPORT_N CONFIG_HUSH_READONLY CONFIG_HUSH_KILL CONFIG_HUSH_WAIT \
    CONFIG_HUSH_COMMAND CONFIG_HUSH_TRAP CONFIG_HUSH_TYPE CONFIG_HUSH_TIMES \
    CONFIG_HUSH_READ CONFIG_HUSH_SET CONFIG_HUSH_UNSET CONFIG_HUSH_ULIMIT \
    CONFIG_HUSH_UMASK CONFIG_HUSH_GETOPTS CONFIG_HUSH_MEMLEAK \
    CONFIG_SELINUX CONFIG_FEATURE_SELINUX \
    CONFIG_SHA1_HWACCEL CONFIG_SHA256_HWACCEL CONFIG_SHA3_SMALL \
    CONFIG_DPKG CONFIG_RPM CONFIG_FBSET CONFIG_LOADFONT CONFIG_SETFONT \
    CONFIG_LPD CONFIG_LPR CONFIG_SENDMAIL CONFIG_DEVMEM CONFIG_INSTALL; do
    sed -i "s/^${opt}=y/# ${opt} is not set/" .config
done

yes '' | make oldconfig >/dev/null 2>&1

echo "[*] Building..."
set +e
make -j"$(nproc)" 2>&1 | tee /output/bb_build.log | tail -20
RET=${PIPESTATUS[0]}
set -e
if [ "$RET" -ne 0 ] || [ ! -f busybox ]; then
    echo ""
    echo "!!! BUILD FAILED !!! (full log: build_output/bb_build.log)"
    grep -in 'error\|undefined\|fatal\|cannot find' /output/bb_build.log | tail -40
    exit 1
fi

file busybox | grep -q 'statically linked' || echo "WARNING: binary may not be static!"
readelf -A busybox 2>/dev/null | grep 'ISA:' | head -1 || true

"${CROSS}-strip" busybox
cp busybox /output/busybox
echo ""
echo "=== /output/busybox ==="
ls -lh /output/busybox
file /output/busybox
echo "Applets: $(./busybox --list 2>/dev/null | wc -l)"
