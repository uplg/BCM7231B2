# FROG-HACK — AirTies AIR 7310T Custom Firmware

Reverse engineering an AirTies AIR 7310T set-top box (Broadcom BCM7231B2) to replace the stock Wyplay "Frog" firmware with a minimal custom Linux system.

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

## Project Structure

```
frog-hack/
  README.md                          # This file
  build_busybox.sh                   # Docker: BusyBox 1.37.0 static musl MIPS32 R1
  build_kernel.sh                    # Docker: Linux 6.18.16 LTS for BCM7231
  build_rootfs.sh                    # Assemble minimal rootfs (all-static, no glibc)
  build_dropbear.sh                  # Docker: Dropbear SSH static musl
  build_mtdutils.sh                  # Docker: flash_erase + nandwrite static
  flash_rootfs.sh                    # Run ON DEVICE: flash rootfs to mtd5
  restore_rootfs.sh                  # Run ON DEVICE: restore original rootfs
  kernel/
    bcm7231.dtsi                     # SoC device tree (adapted from BCM7362)
    bcm7231-airties-7310t.dts        # Board device tree
  build_output/
    vmlinux                          # Kernel ELF (~6.2 MB) — flash to mtd4
    busybox                          # BusyBox 1.37.0 static (~1.6 MB)
    dropbearmulti                    # Dropbear SSH static (~554 KB)
    flash_erase                      # MTD erase tool static (~137 KB)
    nandwrite                        # MTD write tool static (~137 KB)
    kernel_config                    # Saved kernel .config
    bb_build.log                     # BusyBox build log
  new_rootfs/                        # Assembled rootfs directory
    sbin/init                        # PID 1 shell script (#!/bin/ash)
    bin/busybox                      # BusyBox 1.37.0 (static, musl)
    usr/sbin/dropbearmulti           # Dropbear SSH (static, musl)
    etc/                             # Config files (passwd, shadow, network, etc.)
    usr/share/www/                   # Web server root
  new_rootfs.squashfs                # Final SquashFS image — flash to mtd5
  backup/                            # Full device backup (mtd0-mtd6)
  rootfs_extracted/squashfs-root/    # Original Wyplay rootfs extracted
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
./frog-hack.sh connect
```

Parameters: 115200 8N1. Interrupt CFE boot with Ctrl+C for `CFE>` prompt.

### Direct Ethernet

```
Device:  192.168.2.1
Mac:     192.168.2.2
Netmask: 255.255.255.0
```

## Build & Flash Procedure

### Step 1: Build everything

```bash
# Build BusyBox (static, musl, MIPS32 R1)
./build_busybox.sh          # -> build_output/busybox (1.6 MB)

# Build rootfs (assembles everything, no glibc)
./build_rootfs.sh           # -> new_rootfs/

# Create squashfs image
mksquashfs new_rootfs new_rootfs.squashfs -comp gzip -b 131072 -all-root -noappend

# Build kernel (Linux 6.18.16, built-in DTB, ~6.2 MB ELF)
./build_kernel.sh           # -> build_output/vmlinux
```

### Step 2: Prepare TFTP

```bash
sudo cp build_output/vmlinux /private/tftpboot/vmlinux
sudo cp new_rootfs.squashfs /private/tftpboot/new_rootfs.squashfs
sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist
```

### Step 3: Flash via CFE

Interrupt boot with Ctrl+C, then:

```
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:new_rootfs.squashfs nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
```

Flash rootfs first, then kernel. CFE boots ELF directly (built-in ELF loader).

### Step 4: Boot

The kernel boots with built-in DTB, mounts squashfs from mtd5, runs `/sbin/init`.

Expected output:
```
[init] Starting FROG-HACK system...
[init] Configuring network...
[init] Starting SSH...

============================================
  FROG-HACK ready!
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

The following optional static tools are still useful for low-level diagnosis, but they are no longer run automatically at boot:

- `ephy_init` — replay the vendor BCM7231 GENET/EPHY power-on sequence
- `ephy_diag` — dump PHY and EXT/UMAC state
- `genet_dump` — snapshot CLKGEN, GENET, DMA, IRQ, and Linux net state

Build them with:

```bash
./build_ephy_init.sh
./build_ephy_diag.sh
./build_genet_dump.sh
./build_rootfs.sh
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

Linux 6.18.16 LTS — aggressively minimal for < 7 MB ELF:

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

### Phase 2 — Modern kernel 6.18.16 LTS: PARTIAL (clunky ethernet that may not start properly)

1. Created BCM7231 device tree (bcm7231.dtsi + board DTS)
2. Created Docker-based kernel build script
3. Build 1: 13.7 MB ELF — too big for 7 MB partition
4. Build 2: 6.2 MB ELF — fits! Kernel boots, all hardware probes OK
5. Build 2 issue: `/sbin/init` produces no console output (hung)
6. Build 3: Added `BRCMNAND_BRCMSTB=y` — broke NAND entirely (reverted)
7. Built BusyBox 1.37.0 (static musl) to replace old glibc-linked BusyBox
8. Rebuilt rootfs: all-static, no shared libraries, no kernel modules

### Known Issues

- **IRQ 71 spurious interrupt** from OHCI — non-blocking, IRQ auto-disabled
- **`brcm-gisb-arb: error -ENXIO: IRQ index 2 not found`** — cosmetic, driver works with 2/3 IRQs
- **10-second hardware watchdog** set by CFE — clear with `setenv -p STARTUP ""`
- **if these logs don't appear** bcmgenet 10430000.ethernet eth0: FROG-HACK isr1 pre-clear: irq=25 status=0x10000 mask=0xfffeffe0 ethernet isn't working (timing issue.)

# Rebuild rootfs + squashfs (Docker)
./build_rootfs.sh
# Then mksquashfs
# Rebuild kernel (Docker)
./build_kernel.sh
# Copy artifacts to TFTP server
sudo cp build_output/vmlinux /private/tftpboot/vmlinux
sudo cp new_rootfs.squashfs /private/tftpboot/new_rootfs.squashfs
# Ensure TFTP server running
sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist
# CFE connect + flash
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:new_rootfs.squashfs nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
