# =============================================================================
# AirTies AIR 7310T (BCM7231B2, BMIPS4380, MIPS32 R1) — build orchestration
#
# Replaces the old per-target build_*.sh scripts. One Docker builder image
# (toolchain baked in), persistent kernel tree in a named volume for
# incremental rebuilds, source tarballs cached in build/dl.
#
#   make help          — list targets
#   make all           — kernel + rootfs UBI image (everything needed to flash)
#   make kernel KERNEL_VERSION=7.1.4   — try another kernel
# =============================================================================

KERNEL_VERSION   ?= 7.3
# GENET_DEBUG=1 re-enables the bcmgenet printk instrumentation
# (kernel/patch_bcmgenet_debug.py). Off by default since the IRQ
# off-by-one root cause was fixed in the DTS.
GENET_DEBUG      ?= 0
# WIFI_DEBUG=1 adds debugfs and rtw88/mac80211 diagnostics (kernel/config/debug-wifi.config)
WIFI_DEBUG       ?= 0
BUSYBOX_VERSION  ?= 1.38.0
DROPBEAR_VERSION ?= 2026.94
MTDUTILS_VERSION ?= 2.3.1
LIGHTTPD_VERSION ?= 1.4.85
MBEDTLS_VERSION  ?= 3.6.7
WPA_VERSION      ?= 2.12
LIBNL_VERSION    ?= 3.12.0
# Backup target (backup-home): ext4 tools, chroot SFTP, SMART, tailnet
E2FSPROGS_VERSION     ?= 1.47.4
OPENSSH_VERSION       ?= 10.6p1
ZLIB_VERSION          ?= 1.3.2
SMARTMONTOOLS_VERSION ?= 7.5
# Official static mipsle build; sha256 from pkgs.tailscale.com (<tgz>.sha256)
TAILSCALE_VERSION     ?= 1.104.2
TAILSCALE_SHA256      ?= 5398e14b280711f1139e1c2ad84f405a08bcce58a512c155fb139aea3eeea3ee

BUILDER_IMAGE ?= airties-builder
KBUILD_VOLUME ?= airties-kbuild

OUT   := build_output
STAMP := build
DL    := build/dl

# Device / host network (direct Ethernet)
DEVICE_IP ?= 192.168.2.1
HOST_IP   ?= 192.168.2.2
TFTP_DIR  ?= /private/tftpboot

# keepalive: reboot -f drops the link without a FIN, give up within 15 s
SSH := ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@$(DEVICE_IP)

DOCKER_RUN = docker run --rm --platform linux/amd64 \
	-v "$(CURDIR)":/work \
	-v "$(CURDIR)/$(OUT)":/output \
	-v "$(CURDIR)/$(DL)":/dl \
	-w /work \
	$(BUILDER_IMAGE)

# Kernel additionally gets a named volume so the source tree (and object
# files) persist across builds — incremental rebuilds instead of 30 minutes.
DOCKER_RUN_KERNEL = $(subst -w /work,-v $(KBUILD_VOLUME):/kbuild -e KERNEL_VERSION=$(KERNEL_VERSION) -e GENET_DEBUG=$(GENET_DEBUG) -e WIFI_DEBUG=$(WIFI_DEBUG) -w /work,$(DOCKER_RUN))

# kird gets a named volume for the cargo registry so build-std's crate
# downloads survive between builds.
DOCKER_RUN_KIRD = $(subst -w /work,-v airties-cargo:/opt/cargo/registry -w /work,$(DOCKER_RUN))

# Small static diagnostic tools, one .c each in src/
TOOLS     := ephy_init ephy_diag genet_dump irq_dump init_raw init_test mount kir_probe memprobe mxl_probe xpt_cap dvbzap tunerd
TOOL_BINS := $(addprefix $(OUT)/,$(TOOLS))

.PHONY: help all builder kernel busybox dropbear mtdutils tools wpa kird rootfs squashfs ubi flash-all \
        e2fsprogs openssh smartctl tailscale \
        tftp cfe-help flash-rootfs flash-kernel install-tailscale connect \
        clean kernel-clean distclean

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: KERNEL_VERSION=$(KERNEL_VERSION)  BUSYBOX_VERSION=$(BUSYBOX_VERSION)"
	@echo "             DROPBEAR_VERSION=$(DROPBEAR_VERSION)  DEVICE_IP=$(DEVICE_IP)"

all: kernel ubi ## Build everything flashable (kernel + rootfs UBI image)

# -----------------------------------------------------------------------------
# Builder image — toolchain baked in, built once
# -----------------------------------------------------------------------------
$(STAMP)/builder.stamp: docker/Dockerfile.builder
	@mkdir -p $(STAMP) $(DL) $(OUT)
	docker build --platform linux/amd64 -t $(BUILDER_IMAGE) -f docker/Dockerfile.builder docker
	@touch $@

builder: $(STAMP)/builder.stamp ## Build the Docker cross-build image (toolchain baked in)

# -----------------------------------------------------------------------------
# Kernel
# -----------------------------------------------------------------------------
kernel: $(STAMP)/builder.stamp ## Build Linux $(KERNEL_VERSION) -> build_output/vmlinux (incremental)
	$(DOCKER_RUN_KERNEL) bash scripts/kbuild.sh

kernel-clean: ## Drop the persistent kernel build volume (forces full rebuild)
	docker volume rm -f $(KBUILD_VOLUME)

# -----------------------------------------------------------------------------
# Userland components
# -----------------------------------------------------------------------------
# Version stamps: bumping a *_VERSION variable invalidates the artifact.
$(STAMP)/busybox-$(BUSYBOX_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/busybox-*.version; touch $@
$(STAMP)/dropbear-$(DROPBEAR_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/dropbear-*.version; touch $@
$(STAMP)/mtdutils-$(MTDUTILS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/mtdutils-*.version; touch $@
$(STAMP)/lighttpd-$(LIGHTTPD_VERSION)-$(MBEDTLS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/lighttpd-*.version; touch $@
$(STAMP)/wpa-$(WPA_VERSION)-$(LIBNL_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/wpa-*.version; touch $@
$(STAMP)/e2fsprogs-$(E2FSPROGS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/e2fsprogs-*.version; touch $@
$(STAMP)/openssh-$(OPENSSH_VERSION)-$(ZLIB_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/openssh-*.version; touch $@
$(STAMP)/smartmontools-$(SMARTMONTOOLS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/smartmontools-*.version; touch $@
$(STAMP)/tailscale-$(TAILSCALE_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/tailscale-*.version; touch $@

$(OUT)/busybox: scripts/bb-build.sh $(STAMP)/builder.stamp $(STAMP)/busybox-$(BUSYBOX_VERSION).version
	$(DOCKER_RUN) env BUSYBOX_VERSION=$(BUSYBOX_VERSION) bash scripts/bb-build.sh

busybox: $(OUT)/busybox ## Build static BusyBox $(BUSYBOX_VERSION)

$(OUT)/dropbearmulti: scripts/dropbear-build.sh $(STAMP)/builder.stamp $(STAMP)/dropbear-$(DROPBEAR_VERSION).version
	$(DOCKER_RUN) env DROPBEAR_VERSION=$(DROPBEAR_VERSION) bash scripts/dropbear-build.sh

dropbear: $(OUT)/dropbearmulti ## Build static Dropbear SSH $(DROPBEAR_VERSION)

$(OUT)/lighttpd: scripts/lighttpd-build.sh $(STAMP)/builder.stamp $(STAMP)/lighttpd-$(LIGHTTPD_VERSION)-$(MBEDTLS_VERSION).version
	$(DOCKER_RUN) env LIGHTTPD_VERSION=$(LIGHTTPD_VERSION) MBEDTLS_VERSION=$(MBEDTLS_VERSION) \
		bash scripts/lighttpd-build.sh

lighttpd: $(OUT)/lighttpd ## Build static lighttpd $(LIGHTTPD_VERSION) (HTTP/2, TLS via mbedTLS)

$(OUT)/wpa_supplicant: scripts/wpa-build.sh $(STAMP)/builder.stamp $(STAMP)/wpa-$(WPA_VERSION)-$(LIBNL_VERSION).version
	$(DOCKER_RUN) env WPA_VERSION=$(WPA_VERSION) LIBNL_VERSION=$(LIBNL_VERSION) \
		bash scripts/wpa-build.sh

wpa: $(OUT)/wpa_supplicant ## Build static wpa_supplicant $(WPA_VERSION) (nl80211, internal TLS)

$(OUT)/kird: scripts/kird-build.sh kird/Cargo.toml kird/src/main.rs $(STAMP)/builder.stamp
	$(DOCKER_RUN_KIRD) bash scripts/kird-build.sh

kird: $(OUT)/kird ## Build the kird IR->maison daemon (static Rust, MIPS32 R1)

# --- Backup target (backup-home) ---
$(OUT)/mke2fs: scripts/e2fsprogs-build.sh $(STAMP)/builder.stamp $(STAMP)/e2fsprogs-$(E2FSPROGS_VERSION).version
	$(DOCKER_RUN) env E2FSPROGS_VERSION=$(E2FSPROGS_VERSION) bash scripts/e2fsprogs-build.sh

e2fsprogs: $(OUT)/mke2fs ## Build static mke2fs, e2fsck, tune2fs $(E2FSPROGS_VERSION) (ext4 backup disk)

$(OUT)/sshd: scripts/openssh-build.sh $(STAMP)/builder.stamp $(STAMP)/openssh-$(OPENSSH_VERSION)-$(ZLIB_VERSION).version
	$(DOCKER_RUN) env OPENSSH_VERSION=$(OPENSSH_VERSION) ZLIB_VERSION=$(ZLIB_VERSION) bash scripts/openssh-build.sh

openssh: $(OUT)/sshd ## Build static OpenSSH $(OPENSSH_VERSION) sshd (chroot SFTP backup accounts)

$(OUT)/smartctl: scripts/smartmontools-build.sh $(STAMP)/builder.stamp $(STAMP)/smartmontools-$(SMARTMONTOOLS_VERSION).version
	$(DOCKER_RUN) env SMARTMONTOOLS_VERSION=$(SMARTMONTOOLS_VERSION) bash scripts/smartmontools-build.sh

smartctl: $(OUT)/smartctl ## Build static smartctl $(SMARTMONTOOLS_VERSION)

# Tailscale is not built: the official static mipsle release, checksum pinned,
# stripped. It lives on the backup disk (make install-tailscale), not in flash.
$(OUT)/tailscaled: $(STAMP)/builder.stamp $(STAMP)/tailscale-$(TAILSCALE_VERSION).version
	@mkdir -p $(DL) $(OUT)
	@test -f $(DL)/tailscale_$(TAILSCALE_VERSION)_mipsle.tgz || \
		curl -fsSL -o $(DL)/tailscale_$(TAILSCALE_VERSION)_mipsle.tgz \
		https://pkgs.tailscale.com/stable/tailscale_$(TAILSCALE_VERSION)_mipsle.tgz
	echo "$(TAILSCALE_SHA256)  $(DL)/tailscale_$(TAILSCALE_VERSION)_mipsle.tgz" | shasum -a 256 -c -
	tar xzf $(DL)/tailscale_$(TAILSCALE_VERSION)_mipsle.tgz -C $(OUT) --strip-components=1 \
		tailscale_$(TAILSCALE_VERSION)_mipsle/tailscale tailscale_$(TAILSCALE_VERSION)_mipsle/tailscaled
	$(DOCKER_RUN) bash -c 'CROSS=$$(cat /opt/cross-prefix); $$CROSS-strip /output/tailscale /output/tailscaled'
	@ls -lh $(OUT)/tailscale $(OUT)/tailscaled

tailscale: $(OUT)/tailscaled ## Fetch Tailscale $(TAILSCALE_VERSION) (static mipsle, sha256-checked, stripped)

# (stamp file: macOS make 3.81 has no grouped targets for the two binaries)
$(OUT)/.mtdutils.stamp: scripts/mtdutils-build.sh $(STAMP)/builder.stamp $(STAMP)/mtdutils-$(MTDUTILS_VERSION).version
	$(DOCKER_RUN) env MTDUTILS_VERSION=$(MTDUTILS_VERSION) bash scripts/mtdutils-build.sh
	@touch $@

$(OUT)/flash_erase $(OUT)/nandwrite: $(OUT)/.mtdutils.stamp ;

mtdutils: $(OUT)/flash_erase $(OUT)/nandwrite ## Build static flash_erase + nandwrite

# --- Small diagnostic tools (src/<name>.c -> build_output/<name>) ---
TOOL_CFLAGS = -static -O2
$(OUT)/genet_dump: TOOL_CFLAGS = -static -O2 -Wall -Wextra
$(OUT)/xpt_cap:    TOOL_CFLAGS = -static -O2 -Wall -Wextra
$(OUT)/mount:      TOOL_CFLAGS = -static -Os -D_GNU_SOURCE
$(OUT)/init_test:  TOOL_CFLAGS = -static -Os -mips32
$(OUT)/init_raw:   TOOL_CFLAGS = -static -nostdlib -nostartfiles -mips32 -Os \
                                 -fno-stack-protector -fno-builtin -Wl,-e,_start

$(TOOL_BINS): $(OUT)/%: src/%.c $(STAMP)/builder.stamp
	$(DOCKER_RUN) bash -c 'set -e; CROSS=$$(cat /opt/cross-prefix); \
		$$CROSS-gcc $(TOOL_CFLAGS) -o /output/$* src/$*.c; \
		$$CROSS-strip /output/$*; file /output/$*'

tools: $(TOOL_BINS) ## Build the static diagnostic tools ($(TOOLS))

# -----------------------------------------------------------------------------
# RootFS
# -----------------------------------------------------------------------------
rootfs: $(OUT)/busybox $(OUT)/dropbearmulti $(OUT)/lighttpd $(OUT)/wpa_supplicant $(OUT)/kird $(OUT)/flash_erase $(TOOL_BINS) ## Assemble rootfs tree in new_rootfs/
	BASEDIR="$(CURDIR)" OUTDIR="$(CURDIR)/$(OUT)" NEWROOT="$(CURDIR)/new_rootfs" \
		bash scripts/mkrootfs.sh

squashfs: rootfs ## Pack new_rootfs/ -> new_rootfs.squashfs (gzip, 128K blocks)
	$(DOCKER_RUN) mksquashfs new_rootfs new_rootfs.squashfs \
		-comp gzip -b 131072 -all-root -noappend
	@ls -lh new_rootfs.squashfs

# -----------------------------------------------------------------------------
# Deploy / flash
# -----------------------------------------------------------------------------
# CFE writes only the image's length: the UBI image is padded with 0xFF (pages that read as erased)
# to the whole of mtd5 (70 MB), else the PEBs after it keep an older UBI whose image sequence
# number makes the kernel refuse to attach
RootFS_SIZE := 73400320
tftp: ## Copy vmlinuz + the padded rootfs UBI image to $(TFTP_DIR) and start macOS tftpd (sudo)
	@test -f $(OUT)/vmlinuz || { echo "!! $(OUT)/vmlinuz missing — run: make kernel"; exit 1; }
	@test -f rootfs.ubi || { echo "!! rootfs.ubi missing — run: make ubi"; exit 1; }
	{ cat rootfs.ubi; head -c $$(( $(RootFS_SIZE) - $$(stat -f %z rootfs.ubi) )) /dev/zero | tr '\000' '\377'; } > rootfs-cfe.ubi
	sudo mkdir -p $(TFTP_DIR)
	sudo cp $(OUT)/vmlinuz $(TFTP_DIR)/vmlinuz
	sudo cp rootfs-cfe.ubi $(TFTP_DIR)/rootfs-cfe.ubi
	sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist 2>/dev/null || true
	@if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q enabled; then \
		echo ""; \
		echo "!! macOS firewall is ON — it blocks the box's TFTP requests."; \
		echo "   Allow tftpd:  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/tftpd"; \
		echo "                 sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/tftpd"; \
		echo "   (or temporarily: sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off)"; \
	fi
	@$(MAKE) --no-print-directory cfe-help

cfe-help: ## Print the CFE flash commands (first flash / recovery)
	@echo ""
	@echo "In the CFE console (Ctrl+C during boot):"
	@echo "  CFE> ifconfig eth0 -addr=$(DEVICE_IP) -mask=255.255.255.0 -gw=$(HOST_IP)"
	@echo "  CFE> flash $(HOST_IP):rootfs-cfe.ubi nandflash0.rootfs -noheader"
	@echo "  CFE> flash $(HOST_IP):vmlinuz nandflash0.kernel -noheader"
	@echo "  CFE> boot nandflash0.kernel:"
	@echo ""
	@echo "To test a kernel WITHOUT flashing it (recommended for a new vmlinuz):"
	@echo "  CFE> boot -elf $(HOST_IP):vmlinuz"
	@echo ""

# On-device reflash over SSH — the running custom firmware ships flash_erase, nandwrite and the
# UBI tools, so iteration doesn't need the CFE/TFTP dance. scp runs in SFTP mode (OpenSSH on the
# box has no scp binary, internal-sftp serves it). Kernel flash is riskier (mtd4); CFE recovery
# always remains available.
#
# mtd5 is UBI: the rootfs is the static volume "rootfs". An update writes "rootfs_new", swaps the
# two names in one atomic UBI rename and reboots (a power cut at any point leaves a bootable
# "rootfs"); the boot after drops "rootfs_old". From a box still on the raw squashfs (mtdblock5),
# the first flash formats mtd5 with the whole UBI image instead, then reboots at once: its running
# root is gone (hence the static busybox in /dev/shm).
UBI_TOOLS = ubiformat ubimkvol ubiupdatevol ubirename ubirmvol

ubi: squashfs ## Wrap new_rootfs.squashfs in a UBI image for mtd5 -> rootfs.ubi
	$(DOCKER_RUN) $(OUT)/host/ubinize -o rootfs.ubi -p 128KiB -m 2048 -s 2048 scripts/ubinize-rootfs.cfg
	@ls -lh rootfs.ubi

ROOTFS_UPDATE = cd /dev/shm && chmod +x busybox $(UBI_TOOLS) && \
	if grep -q ubiblock /proc/cmdline; then \
	    { ! ./busybox grep -q "^rootfs_new$$" /sys/class/ubi/ubi0_*/name || ./ubirmvol /dev/ubi0 -N rootfs_new; } && \
	    size=$$(./busybox stat -c %s new_rootfs.squashfs) && \
	    ./ubimkvol /dev/ubi0 -N rootfs_new -t static -s $$size && \
	    ./ubiupdatevol /dev/ubi0_$$(./busybox grep -l "^rootfs_new$$" /sys/class/ubi/ubi0_*/name | ./busybox sed "s,.*/ubi0_,,;s,/name,,") new_rootfs.squashfs && \
	    ./ubirename /dev/ubi0 rootfs rootfs_old rootfs_new rootfs; \
	else \
	    ./ubiformat /dev/mtd5 -f rootfs.ubi -y -q; \
	fi && ./busybox sync

flash-rootfs: ## Flash the rootfs (UBI volume swap on mtd5) over SSH, then reboot
	@test -f rootfs.ubi || { echo "!! rootfs.ubi missing — run: make ubi"; exit 1; }
	@echo ">>> Flashing rootfs (mtd5) on $(DEVICE_IP) in 3s — Ctrl+C to abort"; sleep 3
	scp new_rootfs.squashfs rootfs.ubi $(OUT)/busybox $(addprefix $(OUT)/,$(UBI_TOOLS)) root@$(DEVICE_IP):/dev/shm/
	$(SSH) '$(ROOTFS_UPDATE) && ./busybox reboot -f'

flash-kernel: ## Flash build_output/vmlinuz to mtd4 over SSH, then reboot (CFE recovers if it fails)
	@test -f $(OUT)/vmlinuz || { echo "!! $(OUT)/vmlinuz missing — run: make kernel"; exit 1; }
	@echo ">>> Flashing KERNEL (mtd4) on $(DEVICE_IP) in 5s — Ctrl+C to abort"; sleep 5
	scp $(OUT)/vmlinuz root@$(DEVICE_IP):/dev/shm/vmlinuz
	scp $(OUT)/flash_erase $(OUT)/nandwrite root@$(DEVICE_IP):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase /dev/mtd4 0 0 && ./nandwrite -p /dev/mtd4 vmlinuz && sync && reboot'

flash-all: ## Flash kernel (mtd4) and rootfs (mtd5) over SSH, then reboot once
	@test -f $(OUT)/vmlinuz -a -f rootfs.ubi || { echo "!! run: make kernel ubi"; exit 1; }
	@echo ">>> Flashing KERNEL + rootfs on $(DEVICE_IP) in 5s — Ctrl+C to abort"; sleep 5
	scp $(OUT)/vmlinuz new_rootfs.squashfs rootfs.ubi $(OUT)/busybox $(OUT)/flash_erase $(OUT)/nandwrite \
	    $(addprefix $(OUT)/,$(UBI_TOOLS)) root@$(DEVICE_IP):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase -q /dev/mtd4 0 0 && \
	    ./nandwrite -q -p /dev/mtd4 vmlinuz && $(ROOTFS_UPDATE) && ./busybox reboot -f'

# Tailscale lives on the backup disk (/srv/backup/system/tailscale): an
# upgrade is a copy and a restart, no reflash. The supervisor loop in
# /etc/init.d/backup restarts tailscaled within 5 s.
install-tailscale: $(OUT)/tailscaled ## Copy Tailscale $(TAILSCALE_VERSION) to the backup disk and restart it
	scp $(OUT)/tailscale root@$(DEVICE_IP):/srv/backup/system/tailscale/.new-tailscale
	scp $(OUT)/tailscaled root@$(DEVICE_IP):/srv/backup/system/tailscale/.new-tailscaled
	$(SSH) 'cd /srv/backup/system/tailscale && for b in tailscale tailscaled; do mv -f .new-$$b $$b; done; killall tailscaled; sleep 8; ./tailscale --socket=/var/run/tailscale/tailscaled.sock version'

connect: ## Open the UART console (picocom, logs to logs/)
	tools/airties.sh connect

# -----------------------------------------------------------------------------
# Cleaning
# -----------------------------------------------------------------------------
clean: ## Remove build artifacts (keeps builder image + kernel volume)
	rm -rf $(OUT) new_rootfs new_rootfs.squashfs rootfs.ubi rootfs-cfe.ubi

distclean: clean kernel-clean ## Also drop kernel volume, tarball cache and builder image
	rm -rf $(STAMP)
	docker rmi -f $(BUILDER_IMAGE) 2>/dev/null || true
