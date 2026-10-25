# AirTies AIR 7310T — Custom Firmware

Modern custom Linux for the AirTies AIR 7310T set-top box (Broadcom BCM7231B2),
replacing the stock Wyplay firmware. Mainline kernel, fully static userland,
Makefile-driven build, SSH-based iteration. Optionally an off-site **backup
target**: a SATA disk, chrooted SFTP accounts and a Tailscale/Headscale node
(see [Backup target](#backup-target)).

## Current stack

| Component | Version |
|-----------|---------|
| Kernel | Linux 7.3 mainline, flashed as self-decompressing `vmlinuz` (ZBOOT, ~3.4 MB — raw vmlinux outgrew the 7 MB mtd4 when WiFi landed) |
| BusyBox | 1.38.x (static, ash; `ntpd` keeps the clock — the board has no RTC) |
| SSH | OpenSSH 10.x, built without OpenSSL (Ed25519 keys only; ChaCha20-Poly1305, post-quantum mlkem/sntrup KEX), seccomp pre-auth sandbox. Port 22: root, key only. Port 2222: the chrooted SFTP-only backup accounts. Dropbear 2026.x remains the fallback when OpenSSH is not built |
| Disk tools | e2fsprogs 1.47.x (`mke2fs`, `e2fsck`, `tune2fs`), smartmontools 7.x (`smartctl`) |
| Tailnet | Tailscale (official static mipsle release, checksum-pinned, stripped), run from the backup disk |
| Web | lighttpd 1.4.x (HTTP/2, TLS 1.3 via mbedTLS, static) |
| WiFi | wpa_supplicant (static, nl80211 + internal TLS — WPA2-PSK) |
| IR bridge | `kird` (static Rust, edition 2024): forwards Ruwido remote key events from the KIR driver to maison's `/api/ir/key` |
| Extras | mtd-utils on-box (self-reflash), GENET/EPHY diagnostic tools |

All binaries are **statically linked** (musl, MIPS32 R1) — the rootfs has no
shared libraries. Versions are pinned in the `Makefile`.

## Hardware

| Component | Detail |
|-----------|--------|
| **WiFi** | Netgear A6150 USB dongle (RTL8812BU) — mainline rtw88_8822bu, firmware baked into the kernel |
| **SoC** | Broadcom BCM7231B2 — dual-core BMIPS4380 @ 594 MHz |
| **ISA** | MIPS32 Release 1 ONLY (R2 binaries crash with "Illegal instruction") |
| **RAM** | 2×256 MB (~212 MB usable) |
| **Flash** | 128 MB NAND (Toshiba TC58NVG0S3E), brcmnand-v5.0 controller |
| **Ethernet** | bcmgenet (GENET v2.9), internal 100 Mbps PHY |
| **SATA** | strict-ahci, 2 ports on the controller, one drive bay (2.5" fits). The link fails 8b/10b decoding at 6 and 3 Gbps (BadCRC, Dispar): forced to 1.5 Gbps (`libata.force` in the DTS bootargs) |
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
make all            # kernel + rootfs UBI image — everything flashable
make kernel         # -> build_output/vmlinux        (incremental)
make squashfs       # -> new_rootfs.squashfs         (rootfs + services)
make ubi            # -> rootfs.ubi                  (the squashfs in UBI volume "rootfs")
make busybox dropbear lighttpd mtdutils tools   # individual pieces
make e2fsprogs openssh smartctl tailscale       # backup target pieces

make kernel KERNEL_VERSION=6.18.39   # build another kernel version
make kernel GENET_DEBUG=1            # re-enable GENET printk instrumentation
make kernel-clean                    # drop persistent kernel trees
```

### Device configuration baked into the rootfs

Personal files under `device/` (all gitignored, `.example` templates committed):

- `device/wpa_supplicant.conf` — WiFi credentials (`wlan0` comes up at boot
  when the A6150 dongle and this file are present; on-box edits persist via
  the `/config` overlay)
- `device/kird.conf` — maison URL + `IR_API_TOKEN` machine token for the
  IR bridge (`/etc/init.d/kird` supervises the daemon)
- `device/authorized_keys` — root's SSH keys (see below); `device/dropbear/` —
  Dropbear host keys, only when Dropbear is the SSH server
- `device/root-password` — root's password, generated on the first rootfs
  build (24 random characters, 0600); only its SHA-512 hash goes into the
  image. It is for the UART console: SSH takes keys only
- `device/vykar/<host>.pub` — one public key per server backing up to the box:
  each gets the account `vykar-<host>` (see [Backup target](#backup-target)).
  No key, no backup role: the image stays a plain STB.

### kird — remote control bridge

The KIR driver decodes the Ruwido remote in hardware and delivers keycodes on
`/dev/input/event0`; `kird` (kird/, static Rust built via nightly build-std
against a custom MIPS32 R1 target spec — see scripts/kird-build.sh) POSTs
every key event to maison, which maps keys to actions (frontend
configurator, `/remote`). Unmapped keys land in maison's log and its
`/api/ir/recent`, which is how new buttons are discovered.

### SSH access

Key only: `device/authorized_keys` (gitignored) is baked into
`/root/.ssh/authorized_keys`. With OpenSSH (built without OpenSSL) only its
`ssh-ed25519` lines are kept, and the build stops if there is none, so an
image never locks you out. The host key (`/etc/ssh/ssh_host_ed25519_key`) is
generated on first boot onto the persistent `/etc` overlay: same identity
across reflashes. Console login (UART): root with `device/root-password`.

## Flash

### Iteration (box already running this firmware)

The box carries its own `flash_erase`/`nandwrite` and UBI tools — no CFE needed:

```bash
make ubi flash-rootfs         # rebuild rootfs → new UBI volume, atomic swap → reboot
make kernel flash-kernel      # rebuild kernel → flash mtd4 via SSH → reboot
make kernel ubi flash-all     # both, one reboot
make flash-rootfs DEVICE_IP=<wlan0 address>   # same over WiFi
```

The NAND is reached through UBI only (bad blocks, wear levelling, power cuts):
mtd5 holds the squashfs in the static UBI volume `rootfs`, read through
`ubiblock` (`ubi.mtd=RootFS ubi.block=0,rootfs root=/dev/ubiblock0_0`); a
rootfs update writes `rootfs_new`, swaps the names in one atomic `ubirename`
and reboots, and the next boot drops `rootfs_old`. `/config` is UBIFS on mtd2
(UBI device 1). There is no `mtdblock`.

The images travel with `scp` in SFTP mode (OpenSSH's `internal-sftp`; the
box has no `scp` binary). From a box still on Dropbear, copy with `scp -O`.

`/config` (mtd2) is untouched by both: the `/etc` and `/root` overlays, and
the backup sshd's host key, survive reflashes.

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
CFE> flash 192.168.2.2:rootfs-cfe.ubi nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinux nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
```

Original firmware backups live in `backup/` (`mtd4_backup.bin`,
`mtd5_backup.bin`) — flash them the same way to restore stock.

## Device network

Static/fallback IP `192.168.2.1` (DHCP tried first) on Ethernet, DHCP on
`wlan0`. SSH port 22 (admin), backup SFTP port 2222 (backup role only),
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

For the backup target: `CONFIG_TUN` (Tailscale's `tailscale0`),
`CONFIG_IP_ADVANCED_ROUTER` + `CONFIG_IP_MULTIPLE_TABLES` (its routing table
and `ip rule`s; no netfilter, Tailscale runs with `--netfilter-mode=off`),
`CONFIG_SECCOMP_FILTER` (OpenSSH's pre-auth sandbox; without it the seccomp
build of `sshd-auth` drops every connection), `CONFIG_PREEMPT`, and zram
swap (`CONFIG_BLK_DEV` + `CONFIG_ZRAM`, LZ4).

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

## Backup target

The box can hold off-site copies of remote servers' backups (written with
[vykar](https://github.com/borgbase/vykar), encrypted client-side: the box
only ever sees ciphertext). Pieces, all started by `/etc/init.d/backup`
(backgrounded from `rcS`):

- **Disk**: ext4 labelled `backup`, mounted on `/srv/backup` (`e2fsck -p`
  first; exit code 4 or more leaves it unmounted for a human).
- **Accounts**: `vykar-<host>` per `device/vykar/<host>.pub`, locked in
  `/srv/backup/vykar-<host>` by OpenSSH (`ChrootDirectory`, `ForceCommand
  internal-sftp -d /repo`, no shell, no forwarding), keys in
  `/etc/ssh/vykar_authorized_keys/<account>` (`restrict`).
- **Clock**: `/etc/init.d/ntp` waits for a first NTP sync before Tailscale
  starts (TLS needs a real date).
- **Tailnet**: `tailscaled` and its state live on the disk,
  `/srv/backup/system/tailscale/` (kernel TUN when available, userspace
  networking otherwise), supervised by a restart loop.
- **SMART**: `/usr/sbin/disk-health` (cron, hourly) drops `smartctl -j` in
  every chroot as `disk-health`, for the servers' monitoring to read over SFTP.
- **Logs**: once the disk is up, syslog goes to
  `/srv/backup/system/log/messages` (5 × 2 MB, `tail` it: `logread` has no
  buffer then), so a hang no longer takes the evidence with it.
- **WiFi watch** (any box with WiFi): `/usr/sbin/wifi-watch` pings the
  gateway every minute; 3 minutes without an answer restart WiFi, 8 reboot
  cleanly. The hardware watchdog only catches a hung kernel, not a dead link.

### Setting it up

```bash
make e2fsprogs openssh smartctl tailscale kernel squashfs
make flash-kernel flash-rootfs DEVICE_IP=<box>
# once, on the box: format the disk (destroys it)
ssh root@<box> 'mke2fs -t ext4 -L backup -m 0 -T largefile /dev/sda && reboot'
# Tailscale onto the disk, then join the tailnet (on the box)
make install-tailscale DEVICE_IP=<box>     # also: upgrades, no reflash
/srv/backup/system/tailscale/tailscale --socket=/var/run/tailscale/tailscaled.sock \
    up --login-server=<control server> --auth-key=file:<key file> \
    --hostname=<name> --netfilter-mode=off --accept-dns=false
```

The servers then use `sftp://vykar-<host>@<tailnet address>:2222/repo`, with
the box's `/etc/ssh/ssh_host_ed25519_key.pub` in their `known_hosts`.

### Under sustained load

The first full copies froze the box twice (2026-10-12); what it takes now:

- SATA link forced to 1.5 Gbps (`libata.force`): 6 and 3 Gbps fail 8b/10b
  decoding on this board.
- `CONFIG_PREEMPT` + `rcutree.kthread_prio=10`: rtw88's USB TX work, network
  softirqs and the WireGuard/SSH crypto had starved the RCU kthread for 48 s.
- sshd reaps dropped sessions (`ClientAliveInterval 15`, `ClientAliveCountMax
  4`) and caps connection bursts (`MaxStartups 4:50:10`); clients should use
  one connection and long SFTP timeouts (vykar: `limits.connections: 1`,
  `sftp_timeout: 120`), or they reconnect every few seconds on a busy box.
- 64 MB of zram swap (LZ4) as a memory cushion; dirty data reaches the disk
  within 2 s so logs survive a power cut.

Ethernet instead of WiFi would remove the heaviest load (the USB dongle).

### Throughput

About **0.7–1 MB/s** end to end, and the CPU is the limit: raw TCP over WiFi
does ~15 MB/s, WireGuard alone ~1.15 MB/s (Tailscale's userspace
wireguard-go, pure-Go ChaCha20-Poly1305 on a 594 MHz MIPS32 without crypto
instructions, both cores busy), SSH on top roughly halves it. Plenty for
nightly deduplicated deltas; a first full copy of a few GB takes an hour or
two.

## Diagnostic tools (in /sbin on the box)

- `ephy_init` / `ephy_diag` — replay vendor EPHY power-on / dump PHY state
- `genet_dump` — snapshot CLKGEN/GENET/DMA/IRQ/net state (`snapshot`, `watch`)
- `irq_dump`, `init_test` — IRQ controller dump, minimal init for bring-up
