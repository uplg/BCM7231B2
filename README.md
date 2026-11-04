# AirTies AIR 7310T: custom firmware

Modern custom Linux for the AirTies AIR 7310T set-top box (Broadcom BCM7231B2),
replacing the stock Wyplay firmware. Mainline kernel, fully static userland,
Makefile-driven build, SSH-based iteration. Its job today: an off-site **backup
target**, a SATA disk and chrooted SFTP accounts reached through a subnet route
on a tailnet node of the LAN (see [Backup target](#backup-target)).

## Current stack

No distribution: the kernel, BusyBox and a handful of static daemons, built from source.

| Component | Version |
|-----------|---------|
| Kernel | Linux 7.3.x mainline, flashed as self-decompressing `vmlinuz` (ZBOOT, ~4 MB; the raw vmlinux outgrew the 7 MB mtd4 when WiFi landed) |
| Init, shell, tools | BusyBox 1.38.x (static, ash; `init` supervises sshd, crond and ntpd) |
| SSH | OpenSSH 10.x, built without OpenSSL (Ed25519 keys only; ChaCha20-Poly1305, post-quantum mlkem/sntrup KEX), seccomp pre-auth sandbox. Port 22: root, key only. Port 2222: the chrooted SFTP-only backup accounts |
| Disk tools | e2fsprogs 1.47.x (`mke2fs`, `e2fsck`, `tune2fs`), smartmontools 7.x (`smartctl`) |
| WiFi | wpa_supplicant (static, nl80211 + internal TLS: WPA2-PSK) |
| IR bridge | `kird` (static Rust, edition 2024): forwards Ruwido remote key events to maison's `/api/ir/key`. Installed, off by default |
| Flash tools | mtd-utils on the box (it reflashes itself) |

All binaries are **statically linked** (musl, MIPS32 R1): the rootfs has no
shared libraries. Versions are pinned in the `Makefile`.

## Hardware

| Component | Detail |
|-----------|--------|
| **WiFi** | Netgear A6150 USB dongle (RTL8812BU), mainline rtw88_8822bu, firmware baked into the kernel |
| **SoC** | Broadcom BCM7231B2, dual-core BMIPS4380 @ 594 MHz |
| **ISA** | MIPS32 Release 1 ONLY (R2 binaries crash with "Illegal instruction") |
| **RAM** | 2×256 MB (~500 MB usable) |
| **Flash** | 128 MB NAND (Toshiba TC58NVG0S3E), brcmnand-v5.0 controller |
| **Ethernet** | bcmgenet (GENET v2.9), internal 100 Mbps PHY |
| **SATA** | strict-ahci, 2 ports on the controller, one drive bay (2.5" fits). The link fails 8b/10b decoding at 6 and 3 Gbps (BadCRC, Dispar): forced to 1.5 Gbps (`libata.force` in the DTS bootargs) |
| **USB** | 2× EHCI + 2× OHCI |
| **UART** | 3× ns16550a, console on ttyS0 115200 8N1 |
| **Bootloader** | CFE v3.11 (boots raw ELF from NAND) |
| **Tuners** | 2× MxL101SF DVB-T into the XPT transport processor (driver: `make kernel DVB=1`) |
| No PCIe, no SD/MMC slot. | |

## Flash map (128 MB NAND)

```
Partition   Offset       Size    MTD    Notes
CFE         0x00000000   2 MB    mtd0   Bootloader (read-only)
ENV         0x00200000   1 MB    mtd1   CFE environment
ConfigFS    0x00300000   6 MB    mtd2   UBI: UBIFS /config (persistent overlays)
Reserve     0x00900000   10 MB   mtd3   Vendor data, left as is
Kernel      0x01300000   7 MB    mtd4   vmlinuz (self-decompressing ELF, max 7 MB)
RootFS      0x01a00000   70 MB   mtd5   UBI: UBIFS rootfs (volume "rootfs")
Recovery    0x06000000   28 MB   mtd6   Erased (held the vendor's recovery image)
```

## Build

Everything runs through the top-level `Makefile` (`make help` for the list).
One Docker image (`airties-builder`) bakes the Bootlin `mips32el--musl`
toolchain; the kernel source tree persists in a Docker volume so rebuilds are
incremental (~1.5 min); source tarballs are cached in `build/dl/`.

```bash
make all            # kernel + rootfs UBI image: everything flashable
make kernel         # -> build_output/vmlinuz        (incremental)
make rootfs         # -> new_rootfs/                 (rootfs/ tree + binaries)
make ubi            # -> rootfs.ubifs, rootfs.ubi    (UBIFS rootfs; whole-mtd5 UBI image for CFE)
make busybox openssh wpa kird mtdutils   # individual pieces
make e2fsprogs smartctl                  # backup target pieces
make tools                               # DVB userland (dvbzap, tunerd; DVB=1 kernel), not in the image

make kernel KERNEL_VERSION=7.2.15   # build another kernel version
make kernel DVB=1                   # with the DVB-T adapter driver
make kernel WIFI_DEBUG=1            # with debugfs and rtw88/mac80211 diagnostics
make kernel-clean                   # drop persistent kernel trees
```

### The rootfs

`rootfs/base/` holds the image's own files as they land on the box: init
scripts (`etc/init.d/rcS`, `rcK`, `wifi`, `kird`), `inittab`, the WiFi
watcher, the status banner, the NTP hooks, the DHCP script. `rootfs/backup/`
is added with the backup role (`etc/init.d/backup`, `usr/sbin/disk-health`).
`scripts/mkrootfs.sh` copies both, then adds what depends on the build:
binaries, BusyBox links, accounts, `sshd_config`, keys, firmware version.

Boot: `rcS` mounts, brings up `/config` and its overlays, the network,
syslog, WiFi and the backup disk; `init` then starts sshd, ntpd and crond
from `inittab` and restarts them if they exit. syslogd and klogd are needed
before `rcS` ends, when `init` starts nothing yet: `/usr/sbin/supervise`
keeps them up instead. Files rewritten at run time
(`resolv.conf`, the banner behind `/etc/issue` and `/etc/motd`) live in RAM,
never in flash.

### Device configuration baked into the rootfs

Personal files under `device/` (all gitignored, `.example` templates committed):

- `device/wpa_supplicant.conf`: WiFi credentials (`wlan0` comes up at boot
  when the A6150 dongle and this file are present; on-box edits persist via
  the `/config` overlay)
- `device/kird.conf`: maison URL + `IR_API_TOKEN` machine token for the IR
  bridge, and `KIRD_ENABLE` (off unless `1`)
- `device/authorized_keys`: root's SSH keys (see below)
- `device/root-password`: root's password, generated on the first rootfs
  build (24 random characters, 0600); only its SHA-512 hash goes into the
  image. It is for the UART console: SSH takes keys only
- `device/vykar/<host>.pub`: one public key per server backing up to the box;
  each gets the account `vykar-<host>` (see [Backup target](#backup-target)).
  No key, no backup role: the image stays a plain STB.

### kird: remote control bridge

The KIR driver decodes the Ruwido remote in hardware and delivers keycodes on
`/dev/input/event0`; `kird` (kird/, static Rust built via nightly build-std
against a custom MIPS32 R1 target spec, see scripts/kird-build.sh) POSTs
every key event to maison, which maps keys to actions (frontend
configurator, `/remote`). Unmapped keys land in maison's log and its
`/api/ir/recent`, which is how new buttons are discovered. The key codes:
[docs/remote-keys.md](docs/remote-keys.md).

Off by default. To turn it on: set `KIRD_ENABLE=1` in `/etc/kird.conf` on
the box (or in `device/kird.conf` before a build), then run
`/etc/init.d/kird`; it starts at every boot from then on.

### SSH access

Key only: `device/authorized_keys` (gitignored) is baked into
`/root/.ssh/authorized_keys`. OpenSSH here is built without OpenSSL, so only
its `ssh-ed25519` lines are kept, and the build stops if there is none: an
image never locks you out. The host key (`/etc/ssh/ssh_host_ed25519_key`) is
generated on first boot onto the persistent `/etc` overlay: same identity
across reflashes. Console login (UART): root with `device/root-password`.

## Flash

### Iteration (box already running this firmware)

The box carries its own `flash_erase`/`nandwrite` and UBI tools, no CFE needed.
The targets reach it as `DEVICE` (default `airties`): an SSH host alias, so its
address stays in your `~/.ssh/config`:

```
Host airties
    HostName <the box's LAN address>
    User root
    IdentityFile ~/.ssh/id_ed25519
```

```bash
make ubi flash-rootfs         # rebuild rootfs -> new UBI volume, atomic swap -> reboot
make kernel flash-kernel      # rebuild kernel -> flash mtd4 via SSH -> reboot
make all flash-all            # both, one reboot
make check-overlay            # what the /config overlays hide of the image
make outdated                 # every pinned version against the latest upstream release
make flash-all DEVICE=192.168.2.1          # over the recovery cable instead of WiFi
```

The NAND is reached through UBI only (bad blocks, wear levelling, power cuts):
mtd5 holds the rootfs as UBIFS in the UBI volume named `rootfs`, mounted
read-only **by that name** (`ubi.mtd=RootFS root=ubi0:rootfs rootfstype=ubifs`).
A rootfs update writes `rootfs_new`, swaps the names in one atomic `ubirename`
and reboots (a power cut at any point leaves a `rootfs` that boots), and the
next boot drops `rootfs_old`. Never by volume id: a root found by id lost it
in such a swap (panic loop, 2026-10-25). `/config` is UBIFS on mtd2 (UBI
device 1). There is no `mtdblock`.

The images travel with `scp` in SFTP mode (OpenSSH's `internal-sftp`; the
box has no `scp` binary).

`/config` (mtd2) is untouched by both: the `/etc` and `/root` overlays, and
sshd's host key, survive reflashes. The flip side: a file edited once on
the box hides every later version of it flashed with the image.
`make check-overlay` lists the overlays' files, flagging those (`HIDES
IMAGE`); delete one under `/config/overlay/` and reboot to get the image's
back.

### First flash / recovery (via CFE + TFTP)

```bash
make tftp       # stage artifacts in /private/tftpboot, start tftpd, print CFE cmds
make connect    # UART console (picocom, logged to logs/); Ctrl+C during boot -> CFE>
```

Direct Ethernet, Mac must be `192.168.2.2/24` (and macOS Internet Sharing OFF:
it steals 192.168.2.1; the macOS firewall must allow `/usr/libexec/tftpd`,
`make tftp` prints the commands):

```
CFE> ifconfig eth0 -addr=192.168.2.1 -mask=255.255.255.0 -gw=192.168.2.2
CFE> flash 192.168.2.2:rootfs-cfe.ubi nandflash0.rootfs -noheader
CFE> flash 192.168.2.2:vmlinuz nandflash0.kernel -noheader
CFE> boot nandflash0.kernel:
```

Original firmware backups live in `backup/` (`mtd4_backup.bin`,
`mtd5_backup.bin`); flash them the same way to restore stock.

## Device network

`wlan0` takes DHCP. `eth0` is the recovery path: DHCP when a cable is in at
boot, else the fixed `192.168.2.1`. SSH on port 22 (admin), backup SFTP on
port 2222 (backup role only). Nothing else listens.

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
minimal: no modules, no PCI, no debug; bcmgenet, brcmnand + UBI/UBIFS, AHCI,
EHCI/OHCI, ext4, devtmpfs), and `kernel/config/no-dvb.config` unless `DVB=1`.
DTS in `kernel/bcm7231.dtsi` + board file; edit then `make kernel` (the DTS is
re-copied every build).

For the backup target: `CONFIG_SECCOMP_FILTER` (OpenSSH's pre-auth sandbox;
without it the seccomp build of `sshd-auth` drops every connection),
`CONFIG_PREEMPT`, and zram swap (`CONFIG_BLK_DEV` + `CONFIG_ZRAM`, LZ4).

The kernel changes are a patch series in `kernel/patches/` (`git format-patch`
form), applied onto the kernel.org tarball by `scripts/kbuild.sh`; a patch that no
longer applies exactly stops the build. `upstream/` holds the ones written for
mainline, `local/` the board-only ones; `kernel/patches/README.md` has the
status of each and what is left to check before sending any (none is sent):

- **bcm7xxx**: the BCM7231 internal 40nm EPHY (PHY ID 0x600d8690)
- **bcmgenet**: no EEE register access on GENET v1/v2 (a fatal GISB bus error
  at link-up); the PHY polled on v2 (local: no link interrupt reached the MAC)
- **rtw88 USB**: RX URBs resubmitted after a transient bus error (each one was
  lost for good until a reset)
- **BMIPS**: ZBOOT (self-decompressing `vmlinuz`); the AIR 7310T board
- **brcmstb_gisb**, **libahci**: two spurious boot messages
- the KIR and DVB drivers hooked into the build (local)

Vendor IRQ numbering is L1-bit + 1: subtract 1 when porting IRQs from the
stock 3.3.8 kernel to the DTS (GENET 24/25, SATA 40, USB 68-71).

## Backup target

The box can hold off-site copies of remote servers' backups (written with
[vykar](https://github.com/borgbase/vykar), encrypted client-side: the box
only ever sees ciphertext). Pieces, mostly started by `/etc/init.d/backup`
(backgrounded from `rcS`):

- **Disk**: ext4 labelled `backup`, mounted on `/srv/backup` (`e2fsck -p`
  first; exit code 4 or more leaves it unmounted for a human). `rcK`
  unmounts it before a reboot.
- **Accounts**: `vykar-<host>` per `device/vykar/<host>.pub`, locked in
  `/srv/backup/vykar-<host>` by OpenSSH (`ChrootDirectory`, `ForceCommand
  internal-sftp -d /repo`, no shell, no forwarding), keys in
  `/etc/ssh/vykar_authorized_keys/<account>` (`restrict`).
- **Clock**: no RTC. `ntpd` runs under `init`; its first sync marks the
  clock set (`/usr/sbin/ntp-event`), which the SMART report waits for (it
  carries its time).
- **Network path**: no tailnet node on the box. A tailnet node of the LAN
  advertises the box's address as a subnet route (`<box LAN address>/32`);
  the servers accept it and reach port 2222 through it.
  WireGuard ends on that node, SFTP stays end to end.
- **SMART**: `/usr/sbin/disk-health` (crond, hourly) drops `smartctl -j` in
  every chroot as `disk-health`, for the servers' monitoring to read over SFTP.
- **Logs**: once the disk is up, syslog goes to
  `/srv/backup/system/log/messages` (5 × 2 MB, `tail` it: `logread` has no
  buffer then), so a hang no longer takes the evidence with it. The backup
  script flags it and stops syslogd; `supervise` starts it again on the disk.
- **WiFi watch** (any box with WiFi): `/usr/sbin/wifi-watch` pings the
  gateway every minute; 3 minutes without an answer restart WiFi, 8 reboot
  cleanly. The hardware watchdog only catches a hung kernel, not a dead link.

### Setting it up

```bash
make e2fsprogs smartctl all
make flash-all
# once, on the box: format the disk (destroys it)
ssh root@<box> 'mke2fs -t ext4 -L backup -m 0 -T largefile /dev/sda && reboot'
# on a tailnet node of the LAN: route the box's address (approve it in the
# control server, or auto-approve it in its policy)
tailscale set --advertise-routes=<box LAN address>/32
# on each server: take the route
tailscale set --accept-routes
```

The servers then use `sftp://vykar-<host>@<box LAN address>:2222/repo`, with
the box's `/etc/ssh/ssh_host_ed25519_key.pub` in their `known_hosts`.

### Under sustained load

The first full copies froze the box twice (2026-10-12); what it takes now:

- SATA link forced to 1.5 Gbps (`libata.force`): 6 and 3 Gbps fail 8b/10b
  decoding on this board.
- `CONFIG_PREEMPT` + `rcutree.kthread_prio=10`: rtw88's USB TX work, network
  softirqs and the WireGuard/SSH crypto had starved the RCU kthread for 48 s.
- An RCU stall panics, and a panic reboots: on 2026-10-25 a CPU stuck for
  hours while the watchdog daemon, on the other one, kept petting.
- The WiFi's receive path split across the CPUs: its USB interrupt on CPU1,
  its IP/TCP half (RPS) on CPU0, which keeps SATA and the timers. At 20 MB/s
  of raw TCP, CPU0 went from 57 % to 27 % busy, same throughput (2026-11-04).
- sshd reaps dropped sessions (`ClientAliveInterval 15`, `ClientAliveCountMax
  4`) and caps connection bursts (`MaxStartups 4:50:10`); clients should use
  one connection and long SFTP timeouts (vykar: `limits.connections: 1`,
  `sftp_timeout: 120`), or they reconnect every few seconds on a busy box.
- 64 MB of zram swap (LZ4) as a memory cushion; dirty data reaches the disk
  within 2 s so logs survive a power cut.

Ethernet instead of WiFi would remove the heaviest load (the USB dongle).

### Throughput

About **6 MB/s** end to end from a remote server (measured 2026-10-25),
the box's CPU still the limit: raw TCP over WiFi does ~15 to 20 MB/s, SFTP
(OpenSSH ChaCha20-Poly1305 on a 594 MHz MIPS32) ~10 MB/s on the LAN. When the
box ran its own tailnet node it did 0.7 to 1 MB/s: Tailscale's userspace
wireguard-go (pure-Go ChaCha20-Poly1305, no crypto instructions) took 1.5 of
its 2 cores for 1.1 MB/s, before SSH. WireGuard now ends on the LAN node that
routes the box's address.
