# AirTies — AirTies AIR 7310T Custom Firmware

AirTies AIR 7310T set-top box (Broadcom BCM7231B2) to replace the stock Wyplay "AirTies" firmware with a minimal custom Linux system.

## Hardware

| Component | Detail |
|-----------|--------|
| **Model** | AirTies AIR 7310T (hybrid HD TV decoder) |
| **SoC** | Broadcom BCM7231B2 — dual-core BMIPS4380 v6.4 @ 594 MHz |
| **ISA** | MIPS32 Release 1 ONLY (R2 binaries crash with "Illegal instruction") |
| **RAM** | 256 MB @ 0x00000000 + 256 MB @ 0x20000000 (~212 MB usable) |
| **Flash** | 128 MB NAND (Toshiba TC58NVG0S3E), 128 KiB blocks, 2 KiB pages, Hamming ECC |
| **NAND controller** | brcmnand-v5.0 @ 0x10412800 |
| **Ethernet** | bcmgenet (GENET v2.9) @ 0x10430000, internal 100 Mbps PHY |
| **SATA** | strict-ahci @ 0x10181000, 2 ports |
| **USB** | 2x EHCI + 2x OHCI (4 buses total) |
| **UARTs** | 3x ns16550a (ttyS0/1/2) @ 0x10406900/940/980 |
| **Bootloader** | CFE v3.11 (Broadcom Common Firmware Environment) |
| **Interfaces** | HDMI, 2x USB 2.0, Ethernet 10/100, tuner DVB-T, UART, SATA |
| **No PCIe** | BCM7231 has no PCI/PCIe — `CONFIG_PCI` is pure bloat |
| **No SD/MMC** | No card slot on this board |

## Flash Map (128 MB NAND)

```
Partition   Offset       Size    MTD    Notes
CFE         0x00000000   2 MB    mtd0   Bootloader (read-only)
ENV         0x00200000   1 MB    mtd1   CFE environment variables
ConfigFS    0x00300000   6 MB    mtd2   User configuration
Reserve     0x00900000   10 MB   mtd3   Reserved
Kernel      0x01300000   7 MB    mtd4   Kernel ELF image (max 7 MB!)
RootFS      0x01a00000   70 MB   mtd5   SquashFS root filesystem
Recovery    0x06000000   28 MB   mtd6   Recovery image
```

## Toolchain

All binaries target **MIPS32 Release 1** (the BMIPS4380 only supports R1).

- **Toolchain**: Bootlin `mips32el--musl--stable-2024.05-1`
- **Libc**: musl (static linking — zero shared library dependencies)
- **Build environment**: Docker `--platform linux/amd64` with Ubuntu 22.04
- **All binaries are statically linked** — the rootfs has NO shared libraries

## Connections

### UART Console

```bash
make connect
```

Parameters: 115200 8N1. Interrupt CFE boot with Ctrl+C for `CFE>` prompt.

### Direct Ethernet

```
Device:  192.168.2.1
Mac:     192.168.2.2
Netmask: 255.255.255.0
```

You need to bring up your interface (direct connect using Ethernet for easy testing for now), like on macOS :
```sh
networksetup -listallnetworkservices
networksetup -setmanual "Ethernet" 192.168.2.2 255.255.255.0
```

## Build & Flash Procedure

Everything is driven by the top-level `Makefile` (run `make help` for the
full target list). The Docker builder image (`make builder`) bakes the
toolchain in once; the kernel source tree lives in a named Docker volume so
rebuilds are incremental; source tarballs are cached in `build/dl/`.

### Step 1: Build everything

```bash
make all            # = make kernel + make squashfs (builds everything below)

# Or piece by piece:
make kernel         # Linux $(KERNEL_VERSION) -> build_output/vmlinux (< 7 MB ELF)
make busybox        # static BusyBox        -> build_output/busybox
make dropbear       # static Dropbear SSH   -> build_output/dropbearmulti
make mtdutils       # flash_erase/nandwrite -> build_output/ (also shipped in rootfs)
make tools          # diagnostic tools (ephy_*, genet_dump, ...)
make squashfs       # rootfs tree + new_rootfs.squashfs

# Default is 7.1.4 (latest stable, 2026-07): boot-tested on the device,
# eth0/SSH functional. Fallback to the LTS branch if needed:
make kernel KERNEL_VERSION=6.18.39
make kernel-clean   # drop the persistent kernel trees (full rebuild)
```

### Step 2: Prepare TFTP

```bash
make tftp           # copies vmlinux + squashfs to /private/tftpboot, starts tftpd (sudo)
```

### Step 3: Flash via CFE (first flash / recovery)

Interrupt boot with Ctrl+C, then:

```
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:new_rootfs.squashfs nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
```

Flash rootfs first, then kernel. CFE boots ELF directly (built-in ELF loader).

### Iterating: reflash over SSH (no CFE needed)

Once the custom firmware runs, the box carries its own `flash_erase` +
`nandwrite`, so the loop is just:

```bash
make squashfs flash-rootfs    # rebuild rootfs, flash mtd5 via SSH, reboot
make kernel flash-kernel      # rebuild kernel, flash mtd4 via SSH, reboot
```

If a flash goes wrong, the CFE/TFTP path above always remains as recovery.

### Step 4: Boot

The kernel boots with built-in DTB, mounts squashfs from mtd5, runs `/sbin/init`.

Expected output:
```
[init] Starting AirTies- system...
[init] Configuring network...
[init] Starting SSH...

============================================
  AirTies- ready!
  IP: 192.168.2.1
  SSH:    port 22
  HTTP:   port 80
============================================
```

Connect: `ssh root@192.168.2.1` (password: `blabliblou`)

## Recovery

### From CFE (bootloader)

If the device doesn't boot, interrupt CFE with Ctrl+C and reflash the original backup:

```
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:mtd4_backup.bin nandflash0.kernel -noheader
CFE> flash 192.168.2.2:mtd5_backup.bin nandflash0.rootfs -noheader
CFE> boot nandflash0.kernel:
```

## Ethernet Notes

Linux 6.18 now brings up the BCM7231 internal GENET PHY and Ethernet path with the corrected DTS interrupt wiring.

The following optional static tools are still useful for low-level diagnosis :

- `ephy_init` — replay the vendor BCM7231 GENET/EPHY power-on sequence
- `ephy_diag` — dump PHY and EXT/UMAC state
- `genet_dump` — snapshot CLKGEN, GENET, DMA, IRQ, and Linux net state

Build them with:

```bash
make tools squashfs
```

Useful manual commands on the box:

```bash
/sbin/genet_dump snapshot manual
/sbin/genet_dump watch 1 5
/sbin/ephy_diag dump
ifconfig eth0
cat /proc/net/dev
cat /proc/interrupts
```

## CFE Bootloader Reference

| Command | Description |
|---------|-------------|
| `help` | List commands |
| `show devices` | List flash devices |
| `printenv` | Show environment variables |
| `setenv -p STARTUP ""` | Clear 10-second hardware watchdog |
| `ifconfig eth0 -addr=X -mask=Y -gw=Z` | Configure network |
| `flash <tftp_url> <device> -noheader` | Flash from TFTP |
| `boot nandflash0.kernel:` | Boot kernel from NAND |

Flash devices: `nandflash0.cfe`, `nandflash0.kernel`, `nandflash0.rootfs`, `nandflash0.recovery`

## Kernel Configuration Highlights

Linux 7.1.x (version pinned by `KERNEL_VERSION` in the Makefile; 6.18 LTS
remains the tested fallback) — aggressively minimal for < 7 MB ELF. The
config fragment lives in `kernel/config/airties.config`, merged onto
`bmips_stb_defconfig`:

- **Built-in DTB** (`CONFIG_BUILTIN_DTB`) — CFE does not pass DTB
- **No loadable modules** (`CONFIG_MODULES=n`) — everything built-in
- **Size-optimized** (`CONFIG_CC_OPTIMIZE_FOR_SIZE=y` + `CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y`)
- **SMP** — both cores active
- **Enabled**: bcmgenet, brcmnand, SATA AHCI, USB EHCI/OHCI, USB_STORAGE, squashfs+zlib, serial console, devtmpfs
- **Disabled**: PCI/PCIe, NETFILTER, IPV6, BRIDGE, CGROUPS, IO_URING, BPF, MODULES, CPU_FREQ, all debug, KALLSYMS, FTRACE, INPUT, VT, HID, DRM, FB, SOUND, MEDIA, WIRELESS, BT, EXT4, JFFS2, UBI, NFS, MMC, SPI, most CRYPTO

## Phase History

### Phase 1 — Custom RootFS on stock kernel 3.3.8: COMPLETE

1. Root access via UART (root, no password)
2. Full hardware reconnaissance
3. Backup of all MTD partitions
4. Custom rootfs with BusyBox + Dropbear SSH + httpd
5. Flashed and booted — SSH works
6. Hardened: root password `blabliblou`, telnet disabled
7. Static IP fallback 192.168.2.1

### Phase 3 — Mainline 7.1.4 + Makefile rework: COMPLETE (2026-07-20)

1. Repo re-architected around a top-level Makefile (Docker builder image,
   persistent kernel tree, cached tarballs, on-device SSH reflash)
2. Kernel bumped 6.18.16 → 7.1.4 (latest stable) — all BCM7231 patches
   apply unchanged, GENET debug printks now opt-in (`GENET_DEBUG=1`)
3. Fixed root shadow hash (old one matched no known password), fixed
   static fallback IP (192.168.1.10 → 192.168.2.1)
4. **Boot-tested on the device: 7.1.4 boots, eth0/SSH/HTTP all functional,
   login OK (root/blabliblou)**
5. **IRQ off-by-one fix validated on hardware**: USB on 68-71, SATA on 40,
   GENET on 24/25 — no spurious interrupt storms, no `nobody cared`, ERR: 0

### Phase 2 — Modern kernel 6.18 LTS: COMPLETE (USB/SATA IRQ off-by-one fixed in DTS)

1. Created BCM7231 device tree (bcm7231.dtsi + board DTS)
2. Created Docker-based kernel build script
3. Build 1: 13.7 MB ELF — too big for 7 MB partition
4. Build 2: 6.2 MB ELF — fits! Kernel boots, all hardware probes OK
5. Build 2 issue: `/sbin/init` produces no console output (hung)
6. Build 3: Added `BRCMNAND_BRCMSTB=y` — broke NAND entirely (reverted)
7. Built BusyBox 1.37.0 (static musl) to replace old glibc-linked BusyBox
8. Rebuilt rootfs: all-static, no shared libraries, no kernel modules

### Known Issues

- ~~"timing issue" on ethernet~~ **RESOLVED (root cause found 2026-07)**: the
  historical GENET flakiness was never a timing issue. The original DTS copied
  IRQ numbers from the vendor 3.3.8 kernel **without subtracting 1** (vendor
  Linux IRQ = L1 bit + 1). GENET was empirically fixed to 24/25, but USB
  (69-72, should be 68-71) and SATA (41, should be 40) kept the off-by-one.
  The wrong USB lines stormed at boot (`irq 69/70/71: nobody cared`, 100k
  spurious interrupts each before being auto-disabled), killing USB entirely
  and perturbing early boot. Fixed in bcm7231.dtsi; the vendor IRQ map was
  extracted from `backup/mtd4_backup.bin` (unstripped ELF: `brcm_add_usb_host`
  IRQ table {EHCI 69,70 / OHCI 71,72}, `bchip_early_setup` genet_pdata
  {25,26}, SATA static resource {0x10181000, 41}).
- The diagnostic printks (`AirTies- isr1 pre-clear`, probe/open/timeout
  dumps) from `kernel/patch_bcmgenet_debug.py` are **no longer applied by
  default** now that the IRQ root cause is fixed. Re-enable them with
  `make kernel GENET_DEBUG=1` (forces one full rebuild when toggling, since
  the persistent source tree is re-extracted).

### Common commands

```bash
make help             # list all targets
make all              # kernel + squashfs
make tftp             # stage artifacts for CFE flashing (prints CFE commands)
make flash-rootfs     # reflash mtd5 over SSH + reboot (iteration)
make flash-kernel     # reflash mtd4 over SSH + reboot (iteration)
make connect          # UART console (picocom, logged to logs/)
make cfe-help         # print the CFE flash commands
```
