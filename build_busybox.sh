#!/bin/bash
# =============================================================================
# Build BusyBox 1.37.0 for BCM7231B2 (BMIPS4380, MIPS32 R1)
# AirTies AIR 7310T — FROG-HACK project
#
# Static binary, musl libc, cross-compiled with Bootlin mips32el toolchain.
# Runs in Docker (linux/amd64).
#
# Produces: build_output/busybox (static, ~1-2 MB)
#
# Usage: ./build_busybox.sh
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
mkdir -p "$OUTDIR"

BUSYBOX_VERSION="1.37.0"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

echo "============================================"
echo "  FROG-HACK BusyBox Build"
echo "  BusyBox ${BUSYBOX_VERSION} — static musl MIPS32 R1"
echo "============================================"
echo ""

echo "[*] Building BusyBox via Docker..."
echo ""

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    ubuntu:22.04 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

echo '[1/5] Installing build dependencies...'
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils bzip2 file >/dev/null 2>&1

echo '[2/5] Downloading Bootlin mips32el toolchain (MIPS32 R1, musl)...'
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
echo '    Extracting toolchain...'
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1
export PATH=\"\${TOOLCHAIN}/bin:\${PATH}\"

CROSS=\$(ls \${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed 's/-gcc\$//' | xargs basename)
echo \"    Cross prefix: \${CROSS}\"

echo '[3/5] Downloading BusyBox ${BUSYBOX_VERSION}...'
cd /tmp
wget -q ${BUSYBOX_URL}
echo '    Extracting...'
tar xf busybox-${BUSYBOX_VERSION}.tar.bz2
cd busybox-${BUSYBOX_VERSION}

echo '[4/5] Configuring BusyBox...'
make defconfig ARCH=mips CROSS_COMPILE=\${CROSS}-

# Enable static linking
sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config

# Disable CONFIG_HUSH (we only need ash)
sed -i 's/CONFIG_HUSH=y/# CONFIG_HUSH is not set/' .config
sed -i 's/CONFIG_HUSH_BASH_COMPAT=y/# CONFIG_HUSH_BASH_COMPAT is not set/' .config
sed -i 's/CONFIG_HUSH_BRACE_EXPANSION=y/# CONFIG_HUSH_BRACE_EXPANSION is not set/' .config
sed -i 's/CONFIG_HUSH_LINENO_VAR=y/# CONFIG_HUSH_LINENO_VAR is not set/' .config
sed -i 's/CONFIG_HUSH_BASH_SOURCE_CURDIR=y/# CONFIG_HUSH_BASH_SOURCE_CURDIR is not set/' .config
sed -i 's/CONFIG_HUSH_INTERACTIVE=y/# CONFIG_HUSH_INTERACTIVE is not set/' .config
sed -i 's/CONFIG_HUSH_SAVEHISTORY=y/# CONFIG_HUSH_SAVEHISTORY is not set/' .config
sed -i 's/CONFIG_HUSH_JOB=y/# CONFIG_HUSH_JOB is not set/' .config
sed -i 's/CONFIG_HUSH_TICK=y/# CONFIG_HUSH_TICK is not set/' .config
sed -i 's/CONFIG_HUSH_IF=y/# CONFIG_HUSH_IF is not set/' .config
sed -i 's/CONFIG_HUSH_LOOPS=y/# CONFIG_HUSH_LOOPS is not set/' .config
sed -i 's/CONFIG_HUSH_CASE=y/# CONFIG_HUSH_CASE is not set/' .config
sed -i 's/CONFIG_HUSH_FUNCTIONS=y/# CONFIG_HUSH_FUNCTIONS is not set/' .config
sed -i 's/CONFIG_HUSH_LOCAL=y/# CONFIG_HUSH_LOCAL is not set/' .config
sed -i 's/CONFIG_HUSH_RANDOM_SUPPORT=y/# CONFIG_HUSH_RANDOM_SUPPORT is not set/' .config
sed -i 's/CONFIG_HUSH_MODE_X=y/# CONFIG_HUSH_MODE_X is not set/' .config
sed -i 's/CONFIG_HUSH_ECHO=y/# CONFIG_HUSH_ECHO is not set/' .config
sed -i 's/CONFIG_HUSH_PRINTF=y/# CONFIG_HUSH_PRINTF is not set/' .config
sed -i 's/CONFIG_HUSH_TEST=y/# CONFIG_HUSH_TEST is not set/' .config
sed -i 's/CONFIG_HUSH_HELP=y/# CONFIG_HUSH_HELP is not set/' .config
sed -i 's/CONFIG_HUSH_EXPORT=y/# CONFIG_HUSH_EXPORT is not set/' .config
sed -i 's/CONFIG_HUSH_EXPORT_N=y/# CONFIG_HUSH_EXPORT_N is not set/' .config
sed -i 's/CONFIG_HUSH_READONLY=y/# CONFIG_HUSH_READONLY is not set/' .config
sed -i 's/CONFIG_HUSH_KILL=y/# CONFIG_HUSH_KILL is not set/' .config
sed -i 's/CONFIG_HUSH_WAIT=y/# CONFIG_HUSH_WAIT is not set/' .config
sed -i 's/CONFIG_HUSH_COMMAND=y/# CONFIG_HUSH_COMMAND is not set/' .config
sed -i 's/CONFIG_HUSH_TRAP=y/# CONFIG_HUSH_TRAP is not set/' .config
sed -i 's/CONFIG_HUSH_TYPE=y/# CONFIG_HUSH_TYPE is not set/' .config
sed -i 's/CONFIG_HUSH_TIMES=y/# CONFIG_HUSH_TIMES is not set/' .config
sed -i 's/CONFIG_HUSH_READ=y/# CONFIG_HUSH_READ is not set/' .config
sed -i 's/CONFIG_HUSH_SET=y/# CONFIG_HUSH_SET is not set/' .config
sed -i 's/CONFIG_HUSH_UNSET=y/# CONFIG_HUSH_UNSET is not set/' .config
sed -i 's/CONFIG_HUSH_ULIMIT=y/# CONFIG_HUSH_ULIMIT is not set/' .config
sed -i 's/CONFIG_HUSH_UMASK=y/# CONFIG_HUSH_UMASK is not set/' .config
sed -i 's/CONFIG_HUSH_GETOPTS=y/# CONFIG_HUSH_GETOPTS is not set/' .config
sed -i 's/CONFIG_HUSH_MEMLEAK=y/# CONFIG_HUSH_MEMLEAK is not set/' .config

# Disable SELinux
sed -i 's/CONFIG_SELINUX=y/# CONFIG_SELINUX is not set/' .config
sed -i 's/CONFIG_FEATURE_SELINUX=y/# CONFIG_FEATURE_SELINUX is not set/' .config

# Disable SHA hardware acceleration (x86-only, breaks MIPS build)
sed -i 's/CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' .config
sed -i 's/CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' .config
sed -i 's/CONFIG_SHA3_SMALL=y/# CONFIG_SHA3_SMALL is not set/' .config

# Disable stuff we don't need
for opt in CONFIG_DPKG CONFIG_RPM CONFIG_FBSET CONFIG_LOADFONT CONFIG_SETFONT \
    CONFIG_LPD CONFIG_LPR CONFIG_SENDMAIL CONFIG_DEVMEM CONFIG_INSTALL; do
    sed -i \"s/\${opt}=y/# \${opt} is not set/\" .config
done

# Resolve config dependencies (non-interactive)
yes '' | make oldconfig ARCH=mips CROSS_COMPILE=\${CROSS}- >/dev/null 2>&1

echo '[5/5] Building BusyBox...'
make -j\$(nproc) ARCH=mips CROSS_COMPILE=\${CROSS}- 2>&1 | tee /output/bb_build.log | tail -30
BRET=\${PIPESTATUS[0]}
if [ \$BRET -ne 0 ] || [ ! -f busybox ]; then
    echo ''
    echo '!!! BUILD FAILED !!!'
    echo ''
    echo 'Full log saved to /output/bb_build.log'
    echo ''
    echo '--- Lines containing error/warning/undefined ---'
    grep -in 'error\|undefined\|fatal\|failed\|cannot find' /output/bb_build.log | tail -40
    echo ''
    echo '--- Last 30 lines ---'
    tail -30 /output/bb_build.log
    exit 1
fi

echo ''
echo '=== Build results ==='
ls -lh busybox
file busybox
echo ''

# Verify it's static
if file busybox | grep -q 'statically linked'; then
    echo 'OK: Binary is statically linked'
else
    echo 'WARNING: Binary may not be statically linked!'
fi

# Verify MIPS32 R1 (ISA level 5 = MIPS32 R1, level 6 = MIPS32 R2)
ISALEVEL=\$(readelf -A busybox 2>/dev/null | grep 'ISA:' | head -1 || true)
echo \"ISA check: \${ISALEVEL}\"

# Strip and copy to output
\${CROSS}-strip busybox
cp busybox /output/busybox

echo ''
echo '=== Final binary ==='
ls -lh /output/busybox
file /output/busybox

# List enabled applets
echo ''
echo '=== Enabled applets ==='
./busybox --list 2>/dev/null || true
echo ''
TOTAL=\$(./busybox --list 2>/dev/null | wc -l)
echo \"Total applets: \${TOTAL}\"
"

echo ""
echo "[*] Done. Output: $OUTDIR/busybox"
ls -lh "$OUTDIR/busybox" 2>/dev/null
echo ""
echo "Next steps:"
echo "  1. Copy to rootfs:  cp $OUTDIR/busybox new_rootfs/bin/busybox"
echo "  2. Remove glibc libs from new_rootfs/lib/ (no longer needed)"
echo "  3. Rebuild squashfs: mksquashfs new_rootfs new_rootfs.squashfs -comp gzip -b 131072 -all-root -noappend"
