#!/bin/bash
# =============================================================================
# Build Linux 6.18 LTS kernel for BCM7231B2 (BMIPS4380, MIPS32 R1)
# AirTies AIR 7310T — FROG-HACK project
#
# Runs in Docker (linux/amd64) with Bootlin mips32el toolchain.
# Produces: vmlinux (ELF, with built-in DTB) ready for CFE boot.
#
# Usage: ./build_kernel.sh
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$BASEDIR/build_output"
KERNELDIR="$BASEDIR/kernel"
mkdir -p "$OUTDIR"

KERNEL_VERSION="6.18.16"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"

echo "============================================"
echo "  FROG-HACK Kernel Build"
echo "  Linux ${KERNEL_VERSION} for BCM7231 (BMIPS4380)"
echo "============================================"
echo ""

# Verify our DTS files exist
for f in "$KERNELDIR/bcm7231.dtsi" "$KERNELDIR/bcm7231-airties-7310t.dts"; do
    [ -f "$f" ] || { echo "[ERROR] Missing: $f"; exit 1; }
done

echo "[*] Building kernel via Docker..."
echo "    This will take a while (downloading kernel + toolchain + compiling)..."
echo ""

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$KERNELDIR:/dts:ro" \
    -v "$KERNELDIR/patch_bcmgenet_debug.py:/patch_bcmgenet_debug.py:ro" \
    ubuntu:22.04 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

echo '[1/7] Installing build dependencies...'
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils file bc flex bison \
    libssl-dev libelf-dev python3 kmod cpio >/dev/null 2>&1

echo '[2/7] Downloading Bootlin mips32el toolchain (MIPS32 R1, musl)...'
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
echo '    Extracting toolchain...'
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1
export PATH=\"\${TOOLCHAIN}/bin:\${PATH}\"

# Find the cross-compile prefix
CROSS=\$(ls \${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed 's/-gcc\$//' | xargs basename)
echo \"    Cross prefix: \${CROSS}\"
echo \"    GCC version: \$(\${CROSS}-gcc --version | head -1)\"

echo '[3/7] Downloading Linux ${KERNEL_VERSION}...'
cd /tmp
wget -q ${KERNEL_URL}
echo '    Extracting kernel source...'
tar xf linux-${KERNEL_VERSION}.tar.xz
cd linux-${KERNEL_VERSION}

echo '[4/7] Installing BCM7231 device tree...'
# Copy our custom DTS files into the kernel source tree
cp /dts/bcm7231.dtsi arch/mips/boot/dts/brcm/
cp /dts/bcm7231-airties-7310t.dts arch/mips/boot/dts/brcm/

# Add our DTS to the Makefile so it gets compiled
if ! grep -q 'bcm7231-airties-7310t' arch/mips/boot/dts/brcm/Makefile; then
    echo 'dtb-\$(CONFIG_BMIPS_GENERIC) += bcm7231-airties-7310t.dtb' >> arch/mips/boot/dts/brcm/Makefile
fi

# Add BCM7231 to the BMIPS Kconfig for built-in DTB selection
if ! grep -q 'DT_BCM7231_AIRTIES' arch/mips/bmips/Kconfig; then
    # Insert our config option before the 'endchoice' line
    sed -i '/^endchoice/i \\
config DT_BCM7231_AIRTIES\\
\\tbool \"AirTies AIR 7310T (BCM7231)\"\\
\\tselect BUILTIN_DTB\\
' arch/mips/bmips/Kconfig
fi

# --- Patch: Add BCM7231 internal PHY (0x600d8690) to bcm7xxx driver ---
# The BCM7231's internal EPHY has PHY ID 0x600d8691 (masked: 0x600d8690)
# which is not in upstream Linux. It's a 40nm EPHY like BCM7346/7362/7425.
echo '    Patching bcm7xxx PHY driver for BCM7231...'

# Add PHY_ID define to brcmphy.h (after BCM7362)
sed -i '/#define PHY_ID_BCM7362/a\\
#define PHY_ID_BCM7231\t\t\t0x600d8690' include/linux/brcmphy.h

# Add driver entry in bcm7xxx.c (after BCM7362 in the driver array)
sed -i '/BCM7XXX_40NM_EPHY(PHY_ID_BCM7362/a\\
\tBCM7XXX_40NM_EPHY(PHY_ID_BCM7231, \"Broadcom BCM7231\"),' drivers/net/phy/bcm7xxx.c

# Add device table entry in bcm7xxx.c (after BCM7362 in mdio_device_id table)
sed -i '/PHY_ID_BCM7362, 0xfffffff0/a\\
\t{ PHY_ID_BCM7231, 0xfffffff0, },' drivers/net/phy/bcm7xxx.c

# Verify patches applied
echo '    Verifying patches...'
grep -n 'BCM7231' include/linux/brcmphy.h
grep -n 'BCM7231' drivers/net/phy/bcm7xxx.c

# --- Patch: Force PHY polling mode instead of MAC interrupt ---
# The upstream driver sets phydev->irq = PHY_MAC_INTERRUPT for internal PHYs
# on non-V5 GENET. This relies on the MAC delivering link interrupts via
# phy_mac_interrupt(). On BCM7231 (GENET v2), the MAC does not generate
# link-change interrupts — this is a known limitation of GENET v2 (not
# related to the L2 interrupt controller).  MDIO polling works perfectly
# (ephy_diag confirmed BMSR=0x782D = link up), so force PHY_POLL.
echo '    Patching bcmmii.c to force PHY polling mode...'
sed -i 's/dev->phydev->irq = PHY_MAC_INTERRUPT;/dev->phydev->irq = PHY_POLL; \/* FROG-HACK: force polling, MAC IRQ broken on BCM7231 *\//' drivers/net/ethernet/broadcom/genet/bcmmii.c
grep -n 'FROG-HACK' drivers/net/ethernet/broadcom/genet/bcmmii.c

# --- Patch: Skip EEE on GENET v1/v2 (registers don't exist, cause GISB bus error) ---
# bcmgenet_eee_enable_set() reads RBUF_ENERGY_CTRL (RBUF+0x9C) and
# TBUF_ENERGY_CTRL which don't exist on GENET v2. This causes a fatal
# GISB bus error at 0x1043039c when phylib detects link and calls
# bcmgenet_mac_config() -> bcmgenet_eee_enable_set().
# Also guard bcmgenet_get_eee/set_eee (already returns -EOPNOTSUPP for V1,
# but not for V2).
echo '    Patching bcmgenet.c to skip EEE on GENET v1/v2...'
sed -i '/bcmgenet_eee_enable_set.*bool enable/,/u32 off = priv->hw_params->tbuf_offset/{
  s/u32 off = priv->hw_params->tbuf_offset/if (GENET_IS_V1(priv) || GENET_IS_V2(priv)) return; \/* FROG-HACK: no EEE on v1\/v2 *\/\n\tu32 off = priv->hw_params->tbuf_offset/
}' drivers/net/ethernet/broadcom/genet/bcmgenet.c
grep -n 'FROG-HACK' drivers/net/ethernet/broadcom/genet/bcmgenet.c

# --- Patch: Add temporary GENET v2 IRQ/DMA debug instrumentation ---
# We now know link comes up, but TX queue 3 times out with zero eth0 IRQ counts.
# Add explicit logs around probe/open/ISR/timeout so we can tell whether the
# problem is bad IRQ routing or DMA descriptors not completing.
echo '    Patching bcmgenet.c for IRQ/DMA watchdog debug...'
python3 /patch_bcmgenet_debug.py

grep -n 'FROG-HACK' drivers/net/ethernet/broadcom/genet/bcmgenet.c

echo '[5/7] Configuring kernel...'
export ARCH=mips
export CROSS_COMPILE=\${CROSS}-

# Start from the STB defconfig (little-endian, BMIPS, SMP)
make bmips_stb_defconfig

# Apply our customizations — AGGRESSIVELY MINIMAL for < 7MB ELF
# Strategy: start from bmips_stb_defconfig, then disable everything we don't need.
# Keep: BMIPS core, BUILTIN_DTB, UART console, bcmgenet, brcmnand, SATA/AHCI,
#       USB EHCI/OHCI + USB_STORAGE, squashfs+zlib, basic networking, devtmpfs.
cat >> .config << 'KCONFIG'

# === FROG-HACK BCM7231 — Minimal config overrides ===

# ---- DTB selection ----
CONFIG_DT_NONE=n
CONFIG_DT_BCM7231_AIRTIES=y

# ---- Optimize for size ----
# CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE is not set
CONFIG_CC_OPTIMIZE_FOR_SIZE=y
CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y

# ---- Disable loadable modules (everything built-in) ----
# CONFIG_MODULES is not set

# ---- Disable CGROUPS ----
# CONFIG_CGROUPS is not set

# ---- Disable IO_URING ----
# CONFIG_IO_URING is not set

# ---- Disable initrd (we boot directly to rootfs) ----
# CONFIG_BLK_DEV_INITRD is not set

# ---- Slim down general setup ----
CONFIG_SYSVIPC=y
# CONFIG_CROSS_MEMORY_ATTACH is not set
# CONFIG_FHANDLE is not set
CONFIG_POSIX_TIMERS=y
CONFIG_SHMEM=y
# CONFIG_AIO is not set
# CONFIG_ADVISE_SYSCALLS is not set
# CONFIG_MEMBARRIER is not set
# CONFIG_RSEQ is not set
# CONFIG_KALLSYMS is not set
# CONFIG_RELAY is not set
CONFIG_EXPERT=y
# CONFIG_ELF_CORE is not set
# CONFIG_COREDUMP is not set
# CONFIG_SYSFS_SYSCALL is not set
# CONFIG_BPF is not set
# CONFIG_SCHED_MM_CID is not set

# ---- Disable PCI (BCM7231 has NO PCIe) ----
# CONFIG_PCI is not set
# CONFIG_PCIE_BRCMSTB is not set
# CONFIG_VGA_ARB is not set
# CONFIG_PCI_QUIRKS is not set

# ---- Disable power management bloat ----
# CONFIG_SUSPEND is not set
# CONFIG_PM is not set
# CONFIG_PM_SLEEP is not set
# CONFIG_PM_DEBUG is not set

# ---- Disable CPU frequency scaling ----
# CONFIG_CPU_FREQ is not set

# ---- Network: keep minimal, disable bloat ----
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
# CONFIG_IP_PNP_BOOTP is not set
# CONFIG_IP_PNP_RARP is not set
CONFIG_PACKET=y
CONFIG_UNIX=y
# CONFIG_IP_MULTICAST is not set
# CONFIG_IP_MROUTE is not set
# CONFIG_TCP_CONG_ADVANCED is not set
# CONFIG_IPV6 is not set
# CONFIG_NETFILTER is not set
# CONFIG_BRIDGE is not set
# CONFIG_NET_DSA is not set
# CONFIG_VLAN_8021Q is not set
# CONFIG_NET_SCHED is not set
# CONFIG_DNS_RESOLVER is not set
# CONFIG_NET_SWITCHDEV is not set
# CONFIG_ETHTOOL_NETLINK is not set
# CONFIG_NET_SELFTESTS is not set
# CONFIG_NET_DEVLINK is not set
# CONFIG_PACKET_DIAG is not set
# CONFIG_AF_UNIX_OOB is not set

# ---- Ethernet: keep ONLY bcmgenet, disable all PCI vendor drivers ----
CONFIG_NETDEVICES=y
CONFIG_ETHERNET=y
CONFIG_NET_VENDOR_BROADCOM=y
CONFIG_BCMGENET=y
# Disable ALL other ethernet vendors
# CONFIG_NET_VENDOR_3COM is not set
# CONFIG_NET_VENDOR_ADAPTEC is not set
# CONFIG_NET_VENDOR_AGERE is not set
# CONFIG_NET_VENDOR_ALACRITECH is not set
# CONFIG_NET_VENDOR_ALTEON is not set
# CONFIG_NET_VENDOR_AMAZON is not set
# CONFIG_NET_VENDOR_AMD is not set
# CONFIG_NET_VENDOR_AQUANTIA is not set
# CONFIG_NET_VENDOR_ARC is not set
# CONFIG_NET_VENDOR_ASIX is not set
# CONFIG_NET_VENDOR_ATHEROS is not set
# CONFIG_NET_VENDOR_CADENCE is not set
# CONFIG_NET_VENDOR_CAVIUM is not set
# CONFIG_NET_VENDOR_CHELSIO is not set
# CONFIG_NET_VENDOR_CISCO is not set
# CONFIG_NET_VENDOR_CORTINA is not set
# CONFIG_NET_VENDOR_DAVICOM is not set
# CONFIG_NET_VENDOR_DEC is not set
# CONFIG_NET_VENDOR_DLINK is not set
# CONFIG_NET_VENDOR_EMULEX is not set
# CONFIG_NET_VENDOR_ENGLEDER is not set
# CONFIG_NET_VENDOR_EZCHIP is not set
# CONFIG_NET_VENDOR_FUNGIBLE is not set
# CONFIG_NET_VENDOR_GOOGLE is not set
# CONFIG_NET_VENDOR_HISILICON is not set
# CONFIG_NET_VENDOR_HUAWEI is not set
# CONFIG_NET_VENDOR_I825XX is not set
# CONFIG_NET_VENDOR_INTEL is not set
# CONFIG_NET_VENDOR_ADI is not set
# CONFIG_NET_VENDOR_LITEX is not set
# CONFIG_NET_VENDOR_MARVELL is not set
# CONFIG_NET_VENDOR_MELLANOX is not set
# CONFIG_NET_VENDOR_META is not set
# CONFIG_NET_VENDOR_MICREL is not set
# CONFIG_NET_VENDOR_MICROCHIP is not set
# CONFIG_NET_VENDOR_MICROSEMI is not set
# CONFIG_NET_VENDOR_MICROSOFT is not set
# CONFIG_NET_VENDOR_MYRI is not set
# CONFIG_NET_VENDOR_NI is not set
# CONFIG_NET_VENDOR_NATSEMI is not set
# CONFIG_NET_VENDOR_NETERION is not set
# CONFIG_NET_VENDOR_NETRONOME is not set
# CONFIG_NET_VENDOR_8390 is not set
# CONFIG_NET_VENDOR_NVIDIA is not set
# CONFIG_NET_VENDOR_OKI is not set
# CONFIG_NET_VENDOR_PACKET_ENGINES is not set
# CONFIG_NET_VENDOR_PENSANDO is not set
# CONFIG_NET_VENDOR_QLOGIC is not set
# CONFIG_NET_VENDOR_BROCADE is not set
# CONFIG_NET_VENDOR_QUALCOMM is not set
# CONFIG_NET_VENDOR_RDC is not set
# CONFIG_NET_VENDOR_REALTEK is not set
# CONFIG_NET_VENDOR_RENESAS is not set
# CONFIG_NET_VENDOR_ROCKER is not set
# CONFIG_NET_VENDOR_SAMSUNG is not set
# CONFIG_NET_VENDOR_SEEQ is not set
# CONFIG_NET_VENDOR_SILAN is not set
# CONFIG_NET_VENDOR_SIS is not set
# CONFIG_NET_VENDOR_SOLARFLARE is not set
# CONFIG_NET_VENDOR_SMSC is not set
# CONFIG_NET_VENDOR_SOCIONEXT is not set
# CONFIG_NET_VENDOR_STMICRO is not set
# CONFIG_NET_VENDOR_SUN is not set
# CONFIG_NET_VENDOR_SYNOPSYS is not set
# CONFIG_NET_VENDOR_TEHUTI is not set
# CONFIG_NET_VENDOR_TI is not set
# CONFIG_NET_VENDOR_TOSHIBA is not set
# CONFIG_NET_VENDOR_VERTEXCOM is not set
# CONFIG_NET_VENDOR_VIA is not set
# CONFIG_NET_VENDOR_WANGXUN is not set
# CONFIG_NET_VENDOR_WIZNET is not set
# CONFIG_NET_VENDOR_XILINX is not set
# CONFIG_FDDI is not set
# CONFIG_HIPPI is not set

# Disable USB network drivers
# CONFIG_USB_NET_DRIVERS is not set

# Disable other net stuff
# CONFIG_MACVLAN is not set
# CONFIG_PPP is not set
# CONFIG_SLIP is not set
# CONFIG_BONDING is not set
# CONFIG_DUMMY is not set
# CONFIG_WIREGUARD is not set

# PHY: keep only BCM7XXX (internal PHY for genet)
CONFIG_PHYLIB=y
CONFIG_BCM7XXX_PHY=y
CONFIG_BCM_NET_PHYLIB=y
# CONFIG_AX88796B_PHY is not set
CONFIG_FIXED_PHY=y
CONFIG_MDIO_BUS=y
CONFIG_MDIO_BCM_UNIMAC=y
CONFIG_OF_MDIO=y
# CONFIG_MDIO_BUS_MUX_BCM6368 is not set

# ---- Serial console ----
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y
# CONFIG_SERIAL_8250_PCI is not set
# CONFIG_SERIAL_8250_EXAR is not set
# CONFIG_SERIAL_8250_PERICOM is not set
# CONFIG_SERIAL_BCM63XX is not set
CONFIG_SERIAL_8250_NR_UARTS=3
CONFIG_SERIAL_8250_RUNTIME_UARTS=3
# CONFIG_LEGACY_PTYS is not set

# ---- MTD/NAND: keep brcmnand, disable NOR/SPI/UBI/CFI bloat ----
CONFIG_MTD=y
CONFIG_MTD_CMDLINE_PARTS=y
CONFIG_MTD_OF_PARTS=y
CONFIG_MTD_BLOCK=y
CONFIG_MTD_RAW_NAND=y
CONFIG_MTD_NAND_BRCMNAND=y
CONFIG_MTD_NAND_BRCMNAND_BRCMSTB=y
CONFIG_MTD_NAND_ECC=y
CONFIG_MTD_NAND_ECC_SW_HAMMING=y
# CONFIG_MTD_CFI is not set
# CONFIG_MTD_JEDECPROBE is not set
# CONFIG_MTD_CFI_INTELEXT is not set
# CONFIG_MTD_CFI_AMDSTD is not set
# CONFIG_MTD_CFI_STAA is not set
# CONFIG_MTD_ROM is not set
# CONFIG_MTD_ABSENT is not set
# CONFIG_MTD_SPI_NOR is not set
# CONFIG_MTD_SPI_NAND is not set
# CONFIG_MTD_UBI is not set
# CONFIG_MTD_ONENAND is not set

# ---- SATA: keep AHCI + Broadcom SATA PHY ----
CONFIG_ATA=y
CONFIG_SATA_HOST=y
CONFIG_SATA_AHCI_PLATFORM=y
CONFIG_AHCI_BRCM=y
CONFIG_GENERIC_PHY=y
CONFIG_PHY_BRCM_SATA=y
# Disable SFF/BMDMA PCI SATA/PATA drivers
# CONFIG_ATA_SFF is not set
# CONFIG_SATA_AHCI is not set
# CONFIG_SATA_INIC162X is not set
# CONFIG_SATA_ACARD_AHCI is not set
# CONFIG_SATA_SIL24 is not set

# ---- SCSI (needed by SATA + USB_STORAGE) ----
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
# CONFIG_CHR_DEV_SG is not set
# CONFIG_SCSI_PROC_FS is not set
# CONFIG_SCSI_LOWLEVEL is not set

# ---- USB: keep EHCI/OHCI platform + storage ----
CONFIG_USB=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_EHCI_HCD_PLATFORM=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_OHCI_HCD_PLATFORM=y
CONFIG_USB_STORAGE=y
# Disable PCI USB
# CONFIG_USB_PCI is not set
# CONFIG_USB_EHCI_PCI is not set
# CONFIG_USB_OHCI_HCD_PCI is not set
# CONFIG_USB_XHCI_HCD is not set

# ---- Disable MMC/SDHCI (no SD slot on this board) ----
# CONFIG_MMC is not set

# ---- Disable SPI subsystem ----
# CONFIG_SPI is not set

# ---- Disable GPIO sysfs (keep gpiolib for brcmstb) ----
# CONFIG_GPIO_SYSFS is not set
# CONFIG_GPIO_CDEV is not set

# ---- Disable POWER_SUPPLY ----
# CONFIG_POWER_SUPPLY is not set

# ---- Disable EEPROM ----
# CONFIG_EEPROM_93CX6 is not set

# ---- Filesystem: keep ONLY squashfs+zlib, proc, sysfs, tmpfs, devtmpfs ----
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_ZLIB=y
# CONFIG_SQUASHFS_LZO is not set
# CONFIG_SQUASHFS_XZ is not set
# CONFIG_SQUASHFS_ZSTD is not set
# CONFIG_SQUASHFS_LZ4 is not set
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
# Disable all heavyweight filesystems
# CONFIG_EXT4_FS is not set
# CONFIG_EXT2_FS is not set
# CONFIG_JFFS2_FS is not set
# CONFIG_UBIFS_FS is not set
# CONFIG_FUSE_FS is not set
# CONFIG_ISO9660_FS is not set
# CONFIG_UDF_FS is not set
# CONFIG_FAT_FS is not set
# CONFIG_VFAT_FS is not set
# CONFIG_MSDOS_FS is not set
# CONFIG_NTFS_FS is not set
# CONFIG_NFS_FS is not set
# CONFIG_CIFS is not set
# CONFIG_NETWORK_FILESYSTEMS is not set
# CONFIG_NLS is not set

# ---- Block layer: slim down ----
# CONFIG_BLK_DEBUG_FS is not set
# CONFIG_BLK_ICQ is not set
# CONFIG_MQ_IOSCHED_DEADLINE is not set
# CONFIG_MQ_IOSCHED_KYBER is not set
# CONFIG_IOSCHED_BFQ is not set
# CONFIG_PARTITION_ADVANCED is not set

# ---- Disable crypto bloat (keep only what the kernel itself needs) ----
# CONFIG_CRYPTO_RSA is not set
# CONFIG_CRYPTO_AEAD is not set
# CONFIG_CRYPTO_GCM is not set
# CONFIG_CRYPTO_CCM is not set
# CONFIG_CRYPTO_CTR is not set
# CONFIG_CRYPTO_ECB is not set
# CONFIG_CRYPTO_CMAC is not set
# CONFIG_CRYPTO_GHASH is not set
# CONFIG_CRYPTO_DEFLATE is not set
# CONFIG_CRYPTO_LZO is not set
# CONFIG_CRYPTO_ZSTD is not set
# CONFIG_CRYPTO_SIG is not set
# CONFIG_CRYPTO_AKCIPHER is not set
# CONFIG_ASYMMETRIC_KEY_TYPE is not set
# CONFIG_SYSTEM_TRUSTED_KEYRING is not set
# CONFIG_X509_CERTIFICATE_PARSER is not set
# CONFIG_PKCS7_MESSAGE_PARSER is not set
# CONFIG_KEYS is not set

# ---- Disable debug/tracing ----
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_FS is not set
# CONFIG_DYNAMIC_DEBUG is not set
# CONFIG_MAGIC_SYSRQ is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_FTRACE is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_PROFILING is not set
# CONFIG_KPROBES is not set
# CONFIG_PRINTK_TIME is not set
# CONFIG_RCU_TRACE is not set
# CONFIG_RUNTIME_TESTING_MENU is not set
# CONFIG_FW_LOADER_DEBUG is not set
# CONFIG_PM_DEBUG is not set
# CONFIG_JBD2_DEBUG is not set

# ---- Disable multimedia/input/display/sound/HID ----
# CONFIG_INPUT is not set
# CONFIG_VT is not set
# CONFIG_DUMMY_CONSOLE is not set
# CONFIG_HID is not set
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_SOUND is not set
# CONFIG_MEDIA_SUPPORT is not set
# CONFIG_WIRELESS is not set
# CONFIG_WLAN is not set
# CONFIG_BT is not set
# CONFIG_RFKILL is not set

# ---- Disable misc unnecessary subsystems ----
# CONFIG_NEW_LEDS is not set
# CONFIG_IPACK_BUS is not set
# CONFIG_NTB is not set
# CONFIG_PWM is not set
# CONFIG_GNSS is not set
# CONFIG_GREYBUS is not set
# CONFIG_COMEDI is not set
# CONFIG_STAGING is not set
# CONFIG_NVMEM is not set
# CONFIG_W1 is not set
# CONFIG_POWER_RESET_BRCMSTB is not set
# CONFIG_CONNECTOR is not set
# CONFIG_HWMON is not set
# CONFIG_THERMAL is not set
CONFIG_WATCHDOG=y
CONFIG_WATCHDOG_CORE=y
CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y
CONFIG_BCM7038_WDT=y
# CONFIG_RTC_CLASS is not set
# CONFIG_DMADEVICES is not set
# CONFIG_ACCESSIBILITY is not set
# CONFIG_VIRTIO_MENU is not set
# CONFIG_VHOST_MENU is not set
# CONFIG_PTP_1588_CLOCK is not set
# CONFIG_PPS is not set
# CONFIG_IOMMU_SUPPORT is not set

# ---- Disable compression libs we don't need ----
# CONFIG_RD_XZ is not set
# CONFIG_RD_ZSTD is not set
# CONFIG_XZ_DEC is not set

# ---- Keep power reset via syscon (needed for reboot) ----
CONFIG_POWER_RESET=y
CONFIG_POWER_RESET_SYSCON=y
CONFIG_MFD_SYSCON=y

# ---- GISB arbiter (bus error reporting, small) ----
CONFIG_BRCMSTB_GISB_ARB=y

# ---- SOC support ----
CONFIG_SOC_BRCMSTB=y
# CONFIG_BRCMSTB_PM is not set

# ---- Clocks (needed for SoC init) ----
CONFIG_COMMON_CLK=y
CONFIG_CLK_BCM_63XX_GATE=y
CONFIG_CLK_BCM63268_TIMER=y

# ---- Reset controller (needed for peripheral init) ----
CONFIG_RESET_CONTROLLER=y
CONFIG_RESET_BCM6345=y

# ---- IRQ chips (required for BMIPS) ----
CONFIG_BCM6345_L1_IRQ=y
CONFIG_BCM7038_L1_IRQ=y
CONFIG_BCM7120_L2_IRQ=y
CONFIG_BRCMSTB_L2_IRQ=y

# ---- IRQ forced threading ----
# Previously disabled because UART IRQs were broken (L2 mask bug).
# Now that upg_irq0_intc has the correct int-map-mask, UART IRQs
# are delivered properly and threaded handlers work fine.
# Leave at kernel default (enabled via PREEMPT config).
KCONFIG

# Reconcile config (resolve dependencies, set defaults for new options)
make olddefconfig

echo '[6/7] Building kernel...'
echo '    This may take 10-30 minutes...'
make -j\$(nproc) vmlinux 2>&1 | tee /tmp/kernel_build.log | tail -50
if [ \${PIPESTATUS[0]} -ne 0 ]; then
    echo ''
    echo '!!! BUILD FAILED !!!'
    echo 'Actual errors:'
    grep -i 'error:' /tmp/kernel_build.log | head -30
    echo ''
    echo 'Last 100 lines of build log:'
    tail -100 /tmp/kernel_build.log
    exit 1
fi

echo ''
echo '[7/7] Preparing output...'

# The kernel ELF with built-in DTB — this is what CFE boots
# Strip everything — no modules, no kallsyms, CFE only needs ELF headers + loadable segments
cp vmlinux /output/vmlinux
\${CROSS}-strip --strip-all /output/vmlinux

# Also create a raw binary (as fallback — CFE prefers the ELF above)
\${CROSS}-objcopy -O binary vmlinux /output/vmlinux.bin

# Create a gzip-compressed version of the raw binary
gzip -9 -c /output/vmlinux.bin > /output/vmlinux.bin.gz

echo ''
echo '=== Build results ==='
ls -lh /output/vmlinux /output/vmlinux.bin /output/vmlinux.bin.gz
file /output/vmlinux
echo ''
echo 'Kernel version:'
strings /output/vmlinux | grep 'Linux version' | head -1
echo ''

# Check if ELF fits in 7MB kernel partition
KSIZE=\$(stat -c %s /output/vmlinux 2>/dev/null || stat -f %z /output/vmlinux)
echo \"Kernel ELF size: \${KSIZE} bytes (\$((\${KSIZE}/1024)) KB)\"
if [ \${KSIZE} -gt 7340032 ]; then
    echo 'WARNING: vmlinux exceeds 7MB! Will not fit in mtd4 kernel partition!'
    echo 'Consider disabling more features or using vmlinux.bin (raw) instead.'
fi

# Save the .config for reference
cp .config /output/kernel_config
"

echo ""
echo "[*] Done. Output in $OUTDIR/"
ls -lh "$OUTDIR/vmlinux" "$OUTDIR/vmlinux.bin" "$OUTDIR/vmlinux.bin.gz" 2>/dev/null
echo ""
echo "Next: flash vmlinux (ELF) to mtd4 (Kernel partition, 7MB max)"
echo "  CFE boots ELF directly — use vmlinux, NOT vmlinux.bin"
echo ""
echo "Via CFE TFTP:"
echo "  CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2"
echo "  CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader"
echo "  CFE> boot nandflash0.kernel:"
