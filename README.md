# AirTies AIR 7310T — Custom Firmware

Modern custom Linux for the AirTies AIR 7310T set-top box (Broadcom BCM7231B2),
replacing the stock Wyplay firmware. Mainline kernel, fully static userland,
Makefile-driven build, SSH-based iteration.

## Current stack

| Component | Version |
|-----------|---------|
| Kernel | Linux 7.1.x mainline (built-in DTB, < 7 MB stripped ELF) |
| BusyBox | 1.38.x (static, ash) |
| SSH | Dropbear 2026.x (Ed25519, ChaCha20-Poly1305, post-quantum hybrid KEX) |
| Web | lighttpd 1.4.x (HTTP/2, TLS 1.3 via mbedTLS, static) |
| Extras | mtd-utils on-box (self-reflash), GENET/EPHY diagnostic tools |

All binaries are **statically linked** (musl, MIPS32 R1) — the rootfs has no
shared libraries. Versions are pinned in the `Makefile`.

## Hardware

| Component | Detail |
|-----------|--------|
| **SoC** | Broadcom BCM7231B2 — dual-core BMIPS4380 @ 594 MHz |
| **ISA** | MIPS32 Release 1 ONLY (R2 binaries crash with "Illegal instruction") |
| **RAM** | 2×256 MB (~212 MB usable) |
| **Flash** | 128 MB NAND (Toshiba TC58NVG0S3E), brcmnand-v5.0 controller |
| **Ethernet** | bcmgenet (GENET v2.9), internal 100 Mbps PHY |
| **SATA** | strict-ahci, 2 ports |
| **USB** | 2× EHCI + 2× OHCI |
| **UART** | 3× ns16550a, console on ttyS0 115200 8N1 |
| **Bootloader** | CFE v3.11 (boots raw ELF from NAND) |
| No PCIe, no SD/MMC slot. | |

## Flash map (128 MB NAND)

```
Partition   Offset       Size    MTD    Notes
CFE         0x00000000   2 MB    mtd0   Bootloader (read-only)
ENV         0x00200000   1 MB    mtd1   CFE environment
ConfigFS    0x00300000   6 MB    mtd2   User configuration
Reserve     0x00900000   10 MB   mtd3   Reserved
Kernel      0x01300000   7 MB    mtd4   Kernel ELF (max 7 MB!)
RootFS      0x01a00000   70 MB   mtd5   SquashFS root
Recovery    0x06000000   28 MB   mtd6   Recovery image
```

## Build

Everything runs through the top-level `Makefile` (`make help` for the list).
One Docker image (`airties-builder`) bakes the Bootlin `mips32el--musl`
toolchain; the kernel source tree persists in a Docker volume so rebuilds are
incremental (~1.5 min); source tarballs are cached in `build/dl/`.

```bash
make all            # kernel + squashfs — everything flashable
make kernel         # -> build_output/vmlinux        (incremental)
make squashfs       # -> new_rootfs.squashfs         (rootfs + services)
make busybox dropbear lighttpd mtdutils tools   # individual pieces

make kernel KERNEL_VERSION=6.18.39   # build another kernel version
make kernel GENET_DEBUG=1            # re-enable GENET printk instrumentation
make kernel-clean                    # drop persistent kernel trees
```

### SSH access

`root` / password `blabliblou`, or key auth: `device/authorized_keys`
(gitignored) is baked into `/root/.ssh/authorized_keys` at rootfs build.
Key-only mode: `make squashfs DROPBEAR_ARGS=-s` — only after confirming
key login works.

## Flash

### Iteration (box already running this firmware)

The box carries its own `flash_erase`/`nandwrite` — no CFE needed:

```bash
make squashfs flash-rootfs    # rebuild rootfs → flash mtd5 via SSH → reboot
make kernel flash-kernel      # rebuild kernel → flash mtd4 via SSH → reboot
```

### First flash / recovery (via CFE + TFTP)

```bash
make tftp       # stage artifacts in /private/tftpboot, start tftpd, print CFE cmds
make connect    # UART console (picocom, logged to logs/) — Ctrl+C during boot → CFE>
```

Direct Ethernet, Mac must be `192.168.2.2/24` (and macOS Internet Sharing OFF —
it steals 192.168.2.1; the macOS firewall must allow `/usr/libexec/tftpd`,
`make tftp` prints the commands):

```
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:new_rootfs.squashfs nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
```

Original firmware backups live in `backup/` (`mtd4_backup.bin`,
`mtd5_backup.bin`) — flash them the same way to restore stock.

## Device network

Static/fallback IP `192.168.2.1` (DHCP tried first). SSH port 22,
HTTP port 80, HTTPS port 443 (self-signed cert, cached in `build/tls/`).
The web root serves a live status page (uptime, load, RAM, link state,
throughput) backed by a JSON CGI at `/cgi-bin/status`.

## CFE reference

| Command | Description |
|---------|-------------|
| `show devices` | List flash devices |
| `printenv` / `setenv -p X Y` | CFE environment |
| `ifconfig eth0 -addr=X -mask=Y -gw=Z` | Configure network |
| `flash <tftp_url> <device> -noheader` | Flash from TFTP |
| `boot nandflash0.kernel:` | Boot kernel from NAND |

## Kernel notes

Config = `bmips_stb_defconfig` + `kernel/config/airties.config` (aggressively
minimal: no modules, no PCI, no debug — bcmgenet, brcmnand, AHCI, EHCI/OHCI,
squashfs, devtmpfs). DTS in `kernel/bcm7231.dtsi` + board file; edit → `make
kernel` (DTS is re-copied every build).

Board-specific patches applied by `scripts/kbuild.sh` (idempotent, fail loudly
if an anchor vanishes in a new kernel):

- **PHY ID 0x600d8690** added to `bcm7xxx` (BCM7231 internal 40nm EPHY,
  absent upstream)
- **PHY_POLL forced** — GENET v2 MAC delivers no link-change interrupts
- **EEE disabled on GENET v1/v2** — the EEE registers don't exist and reading
  them raises a fatal GISB bus error
- Optional (`GENET_DEBUG=1`): IRQ/DMA printk instrumentation in bcmgenet

Vendor IRQ numbering is L1-bit + 1: subtract 1 when porting IRQs from the
stock 3.3.8 kernel to the DTS (GENET 24/25, SATA 40, USB 68-71).

## Diagnostic tools (in /sbin on the box)

- `ephy_init` / `ephy_diag` — replay vendor EPHY power-on / dump PHY state
- `genet_dump` — snapshot CLKGEN/GENET/DMA/IRQ/net state (`snapshot`, `watch`)
- `irq_dump`, `init_test` — IRQ controller dump, minimal init for bring-up
