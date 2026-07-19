#!/bin/bash
# =============================================================================
# Container-side BusyBox build (static, musl, MIPS32 R1).
# Runs INSIDE AirTies-builder. Mounts: /output -> build_output/.
# Produces: /output/busybox
# =============================================================================
set -e

BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.37.0}"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
CROSS=$(cat /opt/cross-prefix)

echo "[1/4] Downloading BusyBox ${BUSYBOX_VERSION}..."
cd /tmp
wget -q "${BUSYBOX_URL}"
tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
cd "busybox-${BUSYBOX_VERSION}"

echo "[2/4] Configuring BusyBox..."
make defconfig ARCH=mips CROSS_COMPILE="${CROSS}-"

# Static link.
sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config

# We only need ash — drop the entire hush shell.
sed -i 's/^\(CONFIG_HUSH[A-Z_]*\)=y/# \1 is not set/' .config

# Disable SELinux, x86-only SHA accel, and packaging/font/devmem cruft.
for opt in CONFIG_SELINUX CONFIG_FEATURE_SELINUX \
    CONFIG_SHA1_HWACCEL CONFIG_SHA256_HWACCEL CONFIG_SHA3_SMALL \
    CONFIG_DPKG CONFIG_RPM CONFIG_FBSET CONFIG_LOADFONT CONFIG_SETFONT \
    CONFIG_LPD CONFIG_LPR CONFIG_SENDMAIL CONFIG_DEVMEM CONFIG_INSTALL; do
    sed -i "s/^${opt}=y/# ${opt} is not set/" .config
done

yes '' | make oldconfig ARCH=mips CROSS_COMPILE="${CROSS}-" >/dev/null 2>&1

echo "[3/4] Building BusyBox..."
if ! make -j"$(nproc)" ARCH=mips CROSS_COMPILE="${CROSS}-" 2>&1 | tee /output/bb_build.log | tail -30; then
    echo ''; echo '!!! BUILD FAILED !!! (full log: build_output/bb_build.log)'
    grep -in 'error\|undefined\|fatal\|failed\|cannot find' /output/bb_build.log | tail -40
    exit 1
fi
[ -f busybox ] || { echo '!!! busybox binary missing'; exit 1; }

echo "[4/4] Verifying + installing..."
file busybox
file busybox | grep -q 'statically linked' && echo 'OK: static' || echo 'WARNING: not static!'
"${CROSS}-strip" busybox
cp busybox /output/busybox

echo ""
ls -lh /output/busybox
echo "Total applets: $(./busybox --list 2>/dev/null | wc -l)"
