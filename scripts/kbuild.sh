#!/bin/bash
# In-container kernel build for BCM7231B2 (BMIPS4380, MIPS32 R1).
# Invoked by `make kernel` inside the airties-builder image.
#
# Mounts (set up by the Makefile):
#   /work    repo root (kernel/: patches, DTS, drivers, config fragments)
#   /output  build_output/ (vmlinuz, vmlinux, kernel_config)
#   /dl      tarball cache (kept on host, survives everything)
#   /kbuild  named Docker volume: extracted source + objects persist here,
#            so rebuilds are incremental. `make kernel-clean` drops it.
#
# Env: KERNEL_VERSION (required, e.g. 7.3.1), DVB (1: DVB-T adapter), WIFI_DEBUG
#
# The kernel changes are a patch series, kernel/patches/upstream/ (meant for upstream) then
# kernel/patches/local/ (this board only), applied in order onto the kernel.org tarball. The DTS
# and the two board drivers are files of their own, copied in on every build, so iterating on
# them only needs `make kernel`.
set -e
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
MAJOR="${KERNEL_VERSION%%.*}"
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
SRC="/kbuild/linux-${KERNEL_VERSION}"

CROSS="$(cat /opt/cross-prefix)"
export ARCH=mips
export CROSS_COMPILE="${CROSS}-"

echo "Linux ${KERNEL_VERSION} for BCM7231 (${CROSS})"

# The patch series. The tree persists between builds, so it records the series it was patched
# with: a tree patched with another one (or not at all, or halfway) is extracted again, and a
# patch is never applied twice nor left out. --fuzz=0: a patch that does not apply exactly
# stops the build rather than landing in the wrong place.
PATCHES=(/work/kernel/patches/upstream/*.patch /work/kernel/patches/local/*.patch)
SERIES=$(cat "${PATCHES[@]}" | sha256sum | cut -d' ' -f1)
if [ -d "$SRC" ] && [ "$(cat "$SRC/.airties-series" 2>/dev/null)" != "$SERIES" ]; then
    echo "[*] Patch series changed: extracting a fresh tree (full rebuild)..."
    rm -rf "$SRC"
fi
if [ ! -d "$SRC" ]; then
    fetch "$TARBALL" "$URL"
    echo "[*] Extracting to $SRC ..."
    tar xf "/dl/$TARBALL" -C /kbuild
    for p in "${PATCHES[@]}"; do
        echo "[*] Applying ${p#/work/kernel/patches/}"
        patch -d "$SRC" -p1 --forward --fuzz=0 --no-backup-if-mismatch -s < "$p" \
            || { echo "!! ${p#/work/kernel/patches/} does not apply to Linux ${KERNEL_VERSION}"; exit 1; }
    done
    echo "$SERIES" > "$SRC/.airties-series"
fi
cd "$SRC"

# The files of their own (the patches hook them into Kconfig and the Makefiles)
echo "[*] Installing the BCM7231 device tree and the KIR and DVB drivers..."
cp /work/kernel/bcm7231.dtsi /work/kernel/bcm7231-airties-7310t.dts arch/mips/boot/dts/brcm/
cp /work/kernel/bcm7231-kir.c drivers/input/keyboard/
cp /work/kernel/bcm7231-dvb.c drivers/misc/

# Firmware baked in via CONFIG_EXTRA_FIRMWARE (repo fw/, mounted at /work/fw)
for f in rtw88/rtw8822b_fw.bin regulatory.db regulatory.db.p7s; do
    [ -f "/work/fw/$f" ] || { echo "!! /work/fw/$f missing: CONFIG_EXTRA_FIRMWARE build will fail"; exit 1; }
done

# Configure: bmips_stb_defconfig + our minimal fragment
echo "[*] Configuring (bmips_stb_defconfig + kernel/config/airties.config)..."
make bmips_stb_defconfig
scripts/kconfig/merge_config.sh -m .config /work/kernel/config/airties.config >/dev/null
if [ "${DVB:-0}" != "1" ]; then
    echo "[*] DVB=0: no DVB core, no AIR 7310T adapter (kernel/config/no-dvb.config)"
    scripts/kconfig/merge_config.sh -m .config /work/kernel/config/no-dvb.config >/dev/null
fi
if [ "${WIFI_DEBUG:-0}" = "1" ]; then
    echo "[*] WIFI_DEBUG=1: adding kernel/config/debug-wifi.config"
    scripts/kconfig/merge_config.sh -m .config /work/kernel/config/debug-wifi.config >/dev/null
fi
make olddefconfig

# Build
# vmlinuz = self-decompressing ELF (builds vmlinux as a prerequisite); it is
# what gets flashed to mtd4; CFE boots it exactly like a raw kernel ELF.
echo "[*] Building vmlinuz (-j$(nproc))..."
set +e
make -j"$(nproc)" vmlinuz 2>&1 | tee /tmp/kernel_build.log | tail -30
RET=${PIPESTATUS[0]}
set -e
if [ "$RET" -ne 0 ]; then
    echo ""
    echo "!!! BUILD FAILED !!!"
    grep -i 'error:' /tmp/kernel_build.log | head -30
    tail -60 /tmp/kernel_build.log
    exit 1
fi

# Output: vmlinuz (what CFE boots / gets flashed) + raw vmlinux for debug
echo "[*] Preparing output..."
[ -f vmlinuz ] || { echo "!!! vmlinuz missing after build !!!"; exit 1; }
cp vmlinuz /output/vmlinuz
cp vmlinux /output/vmlinux
"${CROSS}-strip" --strip-all /output/vmlinux
cp .config /output/kernel_config

echo ""
echo "=== Build results ==="
ls -lh /output/vmlinuz /output/vmlinux
strings /output/vmlinux | grep 'Linux version' | head -1

KSIZE=$(stat -c %s /output/vmlinux)
ZSIZE=$(stat -c %s /output/vmlinuz)
echo "vmlinux (raw): ${KSIZE} bytes ($((KSIZE / 1024)) KB)"
echo "vmlinuz (flashed): ${ZSIZE} bytes ($((ZSIZE / 1024)) KB), mtd4 limit is 7340032 (7 MB)"
if [ "$ZSIZE" -gt 7340032 ]; then
    echo "!!! WARNING: vmlinuz exceeds the 7 MB kernel partition: do NOT flash this !!!"
    exit 2
fi
