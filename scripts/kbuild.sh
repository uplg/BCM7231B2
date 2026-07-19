#!/bin/bash
# =============================================================================
# In-container kernel build for BCM7231B2 (BMIPS4380, MIPS32 R1).
# Invoked by `make kernel` inside the airties-builder image.
#
# Mounts (set up by the Makefile):
#   /work    repo root (kernel/ has DTS, config fragment, debug patch)
#   /output  build_output/ (vmlinux, vmlinux.bin, vmlinux.bin.gz, kernel_config)
#   /dl      tarball cache (kept on host, survives everything)
#   /kbuild  named Docker volume — extracted source + objects persist here,
#            so rebuilds are incremental. `make kernel-clean` drops it.
#
# Env: KERNEL_VERSION (required, e.g. 6.18.39)
#
# All source patches are guarded so they apply exactly once even though the
# tree persists between runs. The DTS files are re-copied every run so DTS
# iteration only needs `make kernel`.
# =============================================================================
set -e

KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION not set}"
MAJOR="${KERNEL_VERSION%%.*}"
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
SRC="/kbuild/linux-${KERNEL_VERSION}"

CROSS="$(cat /opt/cross-prefix)"
export ARCH=mips
export CROSS_COMPILE="${CROSS}-"

echo "============================================"
echo "  Linux ${KERNEL_VERSION} for BCM7231 (${CROSS})"
echo "============================================"

GENET_DEBUG="${GENET_DEBUG:-0}"

# --- Debug instrumentation toggle vs persistent tree ---
# The printk instrumentation can't be cleanly reverted in place (it's a
# text-insertion patch), so if the persistent tree has it but this build
# doesn't want it, re-extract a pristine tree (one full rebuild).
if [ "$GENET_DEBUG" != "1" ] && [ -d "$SRC" ] && \
   grep -q 'AirTies- isr1 pre-clear' "$SRC/drivers/net/ethernet/broadcom/genet/bcmgenet.c" 2>/dev/null; then
    echo "[*] Debug instrumentation present but GENET_DEBUG=0 — re-extracting pristine tree..."
    rm -rf "$SRC"
fi

# --- Fetch + extract (once per version) ---
if [ ! -d "$SRC" ]; then
    if [ ! -f "/dl/$TARBALL" ]; then
        echo "[*] Downloading $URL ..."
        wget -q -O "/dl/$TARBALL.part" "$URL"
        mv "/dl/$TARBALL.part" "/dl/$TARBALL"
    fi
    echo "[*] Extracting to $SRC ..."
    tar xf "/dl/$TARBALL" -C /kbuild
fi
cd "$SRC"

# --- Device tree: always refresh (this is the main iteration surface) ---
echo "[*] Installing BCM7231 device tree..."
cp /work/kernel/bcm7231.dtsi /work/kernel/bcm7231-airties-7310t.dts \
   arch/mips/boot/dts/brcm/

grep -q 'bcm7231-airties-7310t' arch/mips/boot/dts/brcm/Makefile || \
    echo 'dtb-$(CONFIG_BMIPS_GENERIC) += bcm7231-airties-7310t.dtb' \
        >> arch/mips/boot/dts/brcm/Makefile

if ! grep -q 'DT_BCM7231_AIRTIES' arch/mips/bmips/Kconfig; then
    sed -i '/^endchoice/i \
config DT_BCM7231_AIRTIES\
\tbool "AirTies AIR 7310T (BCM7231)"\
\tselect BUILTIN_DTB\
' arch/mips/bmips/Kconfig
fi

# --- Patch: BCM7231 internal EPHY (PHY ID 0x600d8690, 40nm like 7346/7362) ---
if ! grep -q 'PHY_ID_BCM7231' include/linux/brcmphy.h; then
    echo "[*] Patching brcmphy.h (PHY_ID_BCM7231)..."
    sed -i '/#define PHY_ID_BCM7362/a\
#define PHY_ID_BCM7231\t\t\t0x600d8690' include/linux/brcmphy.h
fi
grep -q 'PHY_ID_BCM7231' include/linux/brcmphy.h || { echo "!! brcmphy.h patch failed"; exit 1; }

if ! grep -q 'PHY_ID_BCM7231' drivers/net/phy/bcm7xxx.c; then
    echo "[*] Patching bcm7xxx.c (driver + mdio table entries)..."
    sed -i '/BCM7XXX_40NM_EPHY(PHY_ID_BCM7362/a\
\tBCM7XXX_40NM_EPHY(PHY_ID_BCM7231, "Broadcom BCM7231"),' drivers/net/phy/bcm7xxx.c
    sed -i '/PHY_ID_BCM7362, 0xfffffff0/a\
\t{ PHY_ID_BCM7231, 0xfffffff0, },' drivers/net/phy/bcm7xxx.c
fi
[ "$(grep -c 'PHY_ID_BCM7231' drivers/net/phy/bcm7xxx.c)" -ge 2 ] || \
    { echo "!! bcm7xxx.c patch failed"; exit 1; }

# --- Patch: force PHY polling — GENET v2 MAC delivers no link-change IRQs ---
if ! grep -q 'AirTies-: force polling' drivers/net/ethernet/broadcom/genet/bcmmii.c; then
    echo "[*] Patching bcmmii.c (PHY_POLL)..."
    sed -i 's/dev->phydev->irq = PHY_MAC_INTERRUPT;/dev->phydev->irq = PHY_POLL; \/* AirTies-: force polling, MAC IRQ broken on BCM7231 *\//' \
        drivers/net/ethernet/broadcom/genet/bcmmii.c
fi
grep -q 'AirTies-: force polling' drivers/net/ethernet/broadcom/genet/bcmmii.c || \
    { echo "!! bcmmii.c patch failed (anchor changed in this kernel version?)"; exit 1; }

# --- Patch: skip EEE on GENET v1/v2 — RBUF/TBUF_ENERGY_CTRL don't exist,
#     reading them raises a fatal GISB bus error at link-up ---
if ! grep -q 'AirTies-: no EEE' drivers/net/ethernet/broadcom/genet/bcmgenet.c; then
    echo "[*] Patching bcmgenet.c (skip EEE on v1/v2)..."
    sed -i '/bcmgenet_eee_enable_set.*bool enable/,/u32 off = priv->hw_params->tbuf_offset/{
      s/u32 off = priv->hw_params->tbuf_offset/if (GENET_IS_V1(priv) || GENET_IS_V2(priv)) return; \/* AirTies-: no EEE on v1\/v2 *\/\n\tu32 off = priv->hw_params->tbuf_offset/
    }' drivers/net/ethernet/broadcom/genet/bcmgenet.c
fi
grep -q 'AirTies-: no EEE' drivers/net/ethernet/broadcom/genet/bcmgenet.c || \
    { echo "!! bcmgenet.c EEE patch failed (anchor changed in this kernel version?)"; exit 1; }

# --- Optional: IRQ/DMA debug instrumentation (probe/open/ISR/timeout) ---
# Historical GENET diagnosis aid — enable with `make kernel GENET_DEBUG=1`.
if [ "$GENET_DEBUG" = "1" ] && \
   ! grep -q 'AirTies- isr1 pre-clear' drivers/net/ethernet/broadcom/genet/bcmgenet.c; then
    echo "[*] Patching bcmgenet.c (debug instrumentation, GENET_DEBUG=1)..."
    python3 /work/kernel/patch_bcmgenet_debug.py
fi

echo "[*] AirTies- markers in bcmgenet.c: $(grep -c 'AirTies-' drivers/net/ethernet/broadcom/genet/bcmgenet.c)"

# --- Configure: bmips_stb_defconfig + our minimal fragment ---
echo "[*] Configuring (bmips_stb_defconfig + kernel/config/airties.config)..."
make bmips_stb_defconfig
scripts/kconfig/merge_config.sh -m .config /work/kernel/config/airties.config >/dev/null
make olddefconfig

# --- Build ---
echo "[*] Building vmlinux (-j$(nproc))..."
set +e
make -j"$(nproc)" vmlinux 2>&1 | tee /tmp/kernel_build.log | tail -30
RET=${PIPESTATUS[0]}
set -e
if [ "$RET" -ne 0 ]; then
    echo ""
    echo "!!! BUILD FAILED !!!"
    grep -i 'error:' /tmp/kernel_build.log | head -30
    tail -60 /tmp/kernel_build.log
    exit 1
fi

# --- Output: stripped ELF (what CFE boots) + raw/gz fallbacks ---
echo "[*] Preparing output..."
cp vmlinux /output/vmlinux
"${CROSS}-strip" --strip-all /output/vmlinux
"${CROSS}-objcopy" -O binary vmlinux /output/vmlinux.bin
gzip -9 -c /output/vmlinux.bin > /output/vmlinux.bin.gz
cp .config /output/kernel_config

echo ""
echo "=== Build results ==="
ls -lh /output/vmlinux /output/vmlinux.bin /output/vmlinux.bin.gz
strings /output/vmlinux | grep 'Linux version' | head -1

KSIZE=$(stat -c %s /output/vmlinux)
echo "Kernel ELF size: ${KSIZE} bytes ($((KSIZE / 1024)) KB) — mtd4 limit is 7340032 (7 MB)"
if [ "$KSIZE" -gt 7340032 ]; then
    echo "!!! WARNING: vmlinux exceeds the 7 MB kernel partition — do NOT flash this !!!"
    exit 2
fi
