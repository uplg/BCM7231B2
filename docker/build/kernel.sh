#!/bin/bash
# =============================================================================
# Container-side kernel build for BCM7231 (BMIPS4380, MIPS32 R1).
# Runs INSIDE AirTies-builder (toolchain + deps already present).
#
# Mounts (set by the Makefile):
#   /dts        -> kernel/            (DTS, dtsi, patch_bcmgenet_debug.py)
#   /kconfig    -> kernel/config/     (AirTies.config fragment)
#   /output     -> build_output/
#
# Produces: /output/vmlinux (stripped ELF w/ built-in DTB), vmlinux.bin[.gz],
#           kernel_config.
# =============================================================================
set -e

KERNEL_VERSION="${KERNEL_VERSION:-6.18.16}"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
CROSS=$(cat /opt/cross-prefix)
export ARCH=mips
export CROSS_COMPILE="${CROSS}-"

echo "[1/6] Downloading Linux ${KERNEL_VERSION}..."
cd /tmp
wget -q "${KERNEL_URL}"
tar xf "linux-${KERNEL_VERSION}.tar.xz"
cd "linux-${KERNEL_VERSION}"

echo "[2/6] Installing BCM7231 device tree..."
cp /dts/bcm7231.dtsi arch/mips/boot/dts/brcm/
cp /dts/bcm7231-airties-7310t.dts arch/mips/boot/dts/brcm/

if ! grep -q 'bcm7231-airties-7310t' arch/mips/boot/dts/brcm/Makefile; then
    echo 'dtb-$(CONFIG_BMIPS_GENERIC) += bcm7231-airties-7310t.dtb' >> arch/mips/boot/dts/brcm/Makefile
fi

if ! grep -q 'DT_BCM7231_AIRTIES' arch/mips/bmips/Kconfig; then
    sed -i '/^endchoice/i \
config DT_BCM7231_AIRTIES\
\tbool "AirTies AIR 7310T (BCM7231)"\
\tselect BUILTIN_DTB\
' arch/mips/bmips/Kconfig
fi

echo "[3/6] Patching PHY + GENET drivers..."
# BCM7231 internal EPHY (masked ID 0x600d8690) is not in upstream Linux.
sed -i '/#define PHY_ID_BCM7362/a\
#define PHY_ID_BCM7231\t\t\t0x600d8690' include/linux/brcmphy.h
sed -i '/BCM7XXX_40NM_EPHY(PHY_ID_BCM7362/a\
\tBCM7XXX_40NM_EPHY(PHY_ID_BCM7231, "Broadcom BCM7231"),' drivers/net/phy/bcm7xxx.c
sed -i '/PHY_ID_BCM7362, 0xfffffff0/a\
\t{ PHY_ID_BCM7231, 0xfffffff0, },' drivers/net/phy/bcm7xxx.c

# GENET v2 MAC does not raise link-change interrupts — force PHY polling.
sed -i 's/dev->phydev->irq = PHY_MAC_INTERRUPT;/dev->phydev->irq = PHY_POLL; \/* AirTies: force polling, MAC IRQ broken on BCM7231 *\//' drivers/net/ethernet/broadcom/genet/bcmmii.c

# EEE energy-ctrl registers do not exist on GENET v1/v2 -> GISB bus error.
sed -i '/bcmgenet_eee_enable_set.*bool enable/,/u32 off = priv->hw_params->tbuf_offset/{
  s/u32 off = priv->hw_params->tbuf_offset/if (GENET_IS_V1(priv) || GENET_IS_V2(priv)) return; \/* AirTies: no EEE on v1\/v2 *\/\n\tu32 off = priv->hw_params->tbuf_offset/
}' drivers/net/ethernet/broadcom/genet/bcmgenet.c

# Optional IRQ/DMA debug instrumentation.
python3 /dts/patch_bcmgenet_debug.py

echo "    AirTies markers:"
grep -c 'AirTies' drivers/net/ethernet/broadcom/genet/bcmgenet.c drivers/net/ethernet/broadcom/genet/bcmmii.c || true

echo "[4/6] Configuring kernel..."
make bmips_stb_defconfig
./scripts/kconfig/merge_config.sh -m .config /kconfig/AirTies.config
make olddefconfig

echo "[5/6] Building kernel (10-30 min)..."
if ! make -j"$(nproc)" vmlinux 2>&1 | tee /tmp/kernel_build.log | tail -50; then
    echo ''; echo '!!! BUILD FAILED !!!'
    grep -i 'error:' /tmp/kernel_build.log | head -30
    tail -100 /tmp/kernel_build.log
    exit 1
fi

echo "[6/6] Preparing output..."
cp vmlinux /output/vmlinux
"${CROSS}-strip" --strip-all /output/vmlinux
"${CROSS}-objcopy" -O binary vmlinux /output/vmlinux.bin
gzip -9 -c /output/vmlinux.bin > /output/vmlinux.bin.gz
cp .config /output/kernel_config

echo ""
echo "=== Build results ==="
ls -lh /output/vmlinux /output/vmlinux.bin /output/vmlinux.bin.gz
file /output/vmlinux
strings /output/vmlinux | grep 'Linux version' | head -1

KSIZE=$(stat -c %s /output/vmlinux)
echo "Kernel ELF size: ${KSIZE} bytes ($((KSIZE/1024)) KB)"
if [ "${KSIZE}" -gt 7340032 ]; then
    echo "WARNING: vmlinux exceeds 7MB — will NOT fit in mtd4!"
fi
