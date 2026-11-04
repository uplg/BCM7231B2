# AirTies AIR 7310T (BCM7231B2, BMIPS4380, MIPS32 R1): build orchestration.
#
# One Docker builder image (toolchain baked in), persistent kernel tree in a named volume for
# incremental rebuilds, source tarballs cached in build/dl.
#
#   make help                          list targets
#   make all                           kernel + rootfs UBI image (everything needed to flash)
#   make kernel KERNEL_VERSION=7.2.15  try another kernel

KERNEL_VERSION   ?= 7.3.1
# DVB=1 builds the DVB-T adapter (XPT + 2x MxL101SF, kernel/bcm7231-dvb.c) into the kernel. Off
# by default: the box serves as a backup target, not a TV tuner.
DVB              ?= 0
# WIFI_DEBUG=1 adds debugfs and rtw88/mac80211 diagnostics (kernel/config/debug-wifi.config)
WIFI_DEBUG       ?= 0
BUSYBOX_VERSION  ?= 1.38.0
MTDUTILS_VERSION ?= 2.3.1
WPA_VERSION      ?= 2.12
LIBNL_VERSION    ?= 3.12.0
# Backup target: ext4 tools, chroot SFTP, SMART
E2FSPROGS_VERSION     ?= 1.47.4
OPENSSH_VERSION       ?= 10.6p1
ZLIB_VERSION          ?= 1.3.2
SMARTMONTOOLS_VERSION ?= 7.5

BUILDER_IMAGE ?= airties-builder
KBUILD_VOLUME ?= airties-kbuild

OUT   := build_output
STAMP := build
DL    := build/dl

# The box for SSH and flashing: an SSH host (an alias in ~/.ssh/config, which holds its real
# address) or an address. DEVICE=192.168.2.1 reaches it over the recovery cable.
DEVICE    ?= airties
# Recovery over a direct Ethernet cable: the box's fallback address (and CFE's), this Mac's
CFE_IP    ?= 192.168.2.1
HOST_IP   ?= 192.168.2.2
TFTP_DIR  ?= /private/tftpboot

# keepalive: reboot -f drops the link without a FIN, give up within 15 s
SSH := ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=3 root@$(DEVICE)

DOCKER_RUN = docker run --rm --platform linux/amd64 \
	-v "$(CURDIR)":/work \
	-v "$(CURDIR)/$(OUT)":/output \
	-v "$(CURDIR)/$(DL)":/dl \
	-w /work \
	$(BUILDER_IMAGE)

# Kernel additionally gets a named volume so the source tree (and object
# files) persist across builds: incremental rebuilds instead of 30 minutes.
DOCKER_RUN_KERNEL = $(subst -w /work,-v $(KBUILD_VOLUME):/kbuild -e KERNEL_VERSION=$(KERNEL_VERSION) -e DVB=$(DVB) -e WIFI_DEBUG=$(WIFI_DEBUG) -w /work,$(DOCKER_RUN))

# kird gets a named volume for the cargo registry so build-std's crate
# downloads survive between builds.
DOCKER_RUN_KIRD = $(subst -w /work,-v airties-cargo:/opt/cargo/registry -w /work,$(DOCKER_RUN))

# DVB userland (a kernel built with DVB=1), one .c each in src/; copied to /dev/shm by hand,
# not part of the image
TOOLS     := dvbzap tunerd
TOOL_BINS := $(addprefix $(OUT)/,$(TOOLS))

.PHONY: help all builder kernel busybox mtdutils tools wpa kird rootfs ubi flash-all \
        e2fsprogs openssh smartctl \
        tftp cfe-help flash-rootfs flash-kernel check-overlay outdated connect \
        clean kernel-clean distclean

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: KERNEL_VERSION=$(KERNEL_VERSION)  DVB=$(DVB)  BUSYBOX_VERSION=$(BUSYBOX_VERSION)"
	@echo "             OPENSSH_VERSION=$(OPENSSH_VERSION)  DEVICE=$(DEVICE)"

all: kernel ubi ## Build everything flashable (kernel + rootfs UBI image)

# Builder image: toolchain baked in, built once
$(STAMP)/builder.stamp: docker/Dockerfile.builder
	@mkdir -p $(STAMP) $(DL) $(OUT)
	docker build --platform linux/amd64 -t $(BUILDER_IMAGE) -f docker/Dockerfile.builder docker
	@touch $@

builder: $(STAMP)/builder.stamp ## Build the Docker cross-build image (toolchain baked in)

# Kernel
kernel: $(STAMP)/builder.stamp ## Build Linux $(KERNEL_VERSION) -> build_output/vmlinuz (incremental)
	$(DOCKER_RUN_KERNEL) bash scripts/kbuild.sh

kernel-clean: ## Drop the persistent kernel build volume (forces full rebuild)
	docker volume rm -f $(KBUILD_VOLUME)

# Userland components. Version stamps: bumping a *_VERSION variable invalidates the artifact.
$(STAMP)/busybox-$(BUSYBOX_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/busybox-*.version; touch $@
$(STAMP)/mtdutils-$(MTDUTILS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/mtdutils-*.version; touch $@
$(STAMP)/wpa-$(WPA_VERSION)-$(LIBNL_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/wpa-*.version; touch $@
$(STAMP)/e2fsprogs-$(E2FSPROGS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/e2fsprogs-*.version; touch $@
$(STAMP)/openssh-$(OPENSSH_VERSION)-$(ZLIB_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/openssh-*.version; touch $@
$(STAMP)/smartmontools-$(SMARTMONTOOLS_VERSION).version:
	@mkdir -p $(STAMP); rm -f $(STAMP)/smartmontools-*.version; touch $@

$(OUT)/busybox: scripts/bb-build.sh $(STAMP)/builder.stamp $(STAMP)/busybox-$(BUSYBOX_VERSION).version
	$(DOCKER_RUN) env BUSYBOX_VERSION=$(BUSYBOX_VERSION) bash scripts/bb-build.sh

busybox: $(OUT)/busybox ## Build static BusyBox $(BUSYBOX_VERSION)

$(OUT)/wpa_supplicant: scripts/wpa-build.sh $(STAMP)/builder.stamp $(STAMP)/wpa-$(WPA_VERSION)-$(LIBNL_VERSION).version
	$(DOCKER_RUN) env WPA_VERSION=$(WPA_VERSION) LIBNL_VERSION=$(LIBNL_VERSION) \
		bash scripts/wpa-build.sh

wpa: $(OUT)/wpa_supplicant ## Build static wpa_supplicant $(WPA_VERSION) (nl80211, internal TLS)

$(OUT)/kird: scripts/kird-build.sh kird/Cargo.toml kird/src/main.rs $(STAMP)/builder.stamp
	$(DOCKER_RUN_KIRD) bash scripts/kird-build.sh

kird: $(OUT)/kird ## Build the kird IR->maison daemon (static Rust, MIPS32 R1)

$(OUT)/mke2fs: scripts/e2fsprogs-build.sh $(STAMP)/builder.stamp $(STAMP)/e2fsprogs-$(E2FSPROGS_VERSION).version
	$(DOCKER_RUN) env E2FSPROGS_VERSION=$(E2FSPROGS_VERSION) bash scripts/e2fsprogs-build.sh

e2fsprogs: $(OUT)/mke2fs ## Build static mke2fs, e2fsck, tune2fs $(E2FSPROGS_VERSION) (ext4 backup disk)

$(OUT)/sshd: scripts/openssh-build.sh $(STAMP)/builder.stamp $(STAMP)/openssh-$(OPENSSH_VERSION)-$(ZLIB_VERSION).version
	$(DOCKER_RUN) env OPENSSH_VERSION=$(OPENSSH_VERSION) ZLIB_VERSION=$(ZLIB_VERSION) bash scripts/openssh-build.sh

openssh: $(OUT)/sshd ## Build static OpenSSH $(OPENSSH_VERSION) sshd (chroot SFTP backup accounts)

$(OUT)/smartctl: scripts/smartmontools-build.sh $(STAMP)/builder.stamp $(STAMP)/smartmontools-$(SMARTMONTOOLS_VERSION).version
	$(DOCKER_RUN) env SMARTMONTOOLS_VERSION=$(SMARTMONTOOLS_VERSION) bash scripts/smartmontools-build.sh

smartctl: $(OUT)/smartctl ## Build static smartctl $(SMARTMONTOOLS_VERSION)

# (stamp file: macOS make 3.81 has no grouped targets for the two binaries)
$(OUT)/.mtdutils.stamp: scripts/mtdutils-build.sh $(STAMP)/builder.stamp $(STAMP)/mtdutils-$(MTDUTILS_VERSION).version
	$(DOCKER_RUN) env MTDUTILS_VERSION=$(MTDUTILS_VERSION) bash scripts/mtdutils-build.sh
	@touch $@

$(OUT)/flash_erase $(OUT)/nandwrite: $(OUT)/.mtdutils.stamp ;

mtdutils: $(OUT)/flash_erase $(OUT)/nandwrite ## Build static flash_erase, nandwrite and the UBI tools

$(TOOL_BINS): $(OUT)/%: src/%.c $(STAMP)/builder.stamp
	$(DOCKER_RUN) bash -c 'set -e; CROSS=$$(cat /opt/cross-prefix); \
		$$CROSS-gcc -static -O2 -Wall -Wextra -o /output/$* src/$*.c; \
		$$CROSS-strip /output/$*; file /output/$*'

tools: $(TOOL_BINS) ## Build the DVB userland tools ($(TOOLS)), copied to /dev/shm by hand

# RootFS
rootfs: $(OUT)/busybox $(OUT)/sshd $(OUT)/wpa_supplicant $(OUT)/kird $(OUT)/flash_erase ## Assemble rootfs/ + binaries into new_rootfs/
	BASEDIR="$(CURDIR)" OUTDIR="$(CURDIR)/$(OUT)" NEWROOT="$(CURDIR)/new_rootfs" \
		bash scripts/mkrootfs.sh

# Deploy / flash
#
# CFE writes only the image's length: the UBI image is padded with 0xFF (pages that read as erased)
# to the whole of mtd5 (70 MB), else the PEBs after it keep an older UBI whose image sequence
# number makes the kernel refuse to attach
RootFS_SIZE := 73400320
tftp: ## Copy vmlinuz + the padded rootfs UBI image to $(TFTP_DIR) and start macOS tftpd (sudo)
	@test -f $(OUT)/vmlinuz || { echo "!! $(OUT)/vmlinuz missing, run: make kernel"; exit 1; }
	@test -f rootfs.ubi || { echo "!! rootfs.ubi missing, run: make ubi"; exit 1; }
	{ cat rootfs.ubi; head -c $$(( $(RootFS_SIZE) - $$(stat -f %z rootfs.ubi) )) /dev/zero | tr '\000' '\377'; } > rootfs-cfe.ubi
	sudo mkdir -p $(TFTP_DIR)
	sudo cp $(OUT)/vmlinuz $(TFTP_DIR)/vmlinuz
	sudo cp rootfs-cfe.ubi $(TFTP_DIR)/rootfs-cfe.ubi
	sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist 2>/dev/null || true
	@if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q enabled; then \
		echo ""; \
		echo "!! macOS firewall is ON: it blocks the box's TFTP requests."; \
		echo "   Allow tftpd:  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/tftpd"; \
		echo "                 sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/tftpd"; \
		echo "   (or temporarily: sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off)"; \
	fi
	@$(MAKE) --no-print-directory cfe-help

cfe-help: ## Print the CFE flash commands (first flash / recovery)
	@echo ""
	@echo "In the CFE console (Ctrl+C during boot):"
	@echo "  CFE> ifconfig eth0 -addr=$(CFE_IP) -mask=255.255.255.0 -gw=$(HOST_IP)"
	@echo "  CFE> flash $(HOST_IP):rootfs-cfe.ubi nandflash0.rootfs -noheader"
	@echo "  CFE> flash $(HOST_IP):vmlinuz nandflash0.kernel -noheader"
	@echo "  CFE> boot nandflash0.kernel:"
	@echo ""
	@echo "To test a kernel WITHOUT flashing it (recommended for a new vmlinuz):"
	@echo "  CFE> boot -elf $(HOST_IP):vmlinuz"
	@echo ""

# On-device reflash over SSH: the running custom firmware ships flash_erase, nandwrite and the
# UBI tools, so iteration doesn't need the CFE/TFTP dance. scp runs in SFTP mode (OpenSSH on the
# box has no scp binary, internal-sftp serves it). Kernel flash is riskier (mtd4); CFE recovery
# always remains available.
#
# mtd5 is UBI: the rootfs is UBIFS in the volume named "rootfs", mounted read-only by that name
# (root=ubi0:rootfs). An update writes the volume "rootfs_new", swaps the two names in one atomic
# UBI rename and reboots: a power cut at any point leaves a "rootfs" that boots; the next boot
# drops "rootfs_old". By name, never by volume id: a root found by id lost it in such a swap
# (panic loop, 2026-10-25). The tools run from /dev/shm, with their own busybox.
UBI_TOOLS = ubiformat ubimkvol ubiupdatevol ubirename ubirmvol
# UBIFS geometry: 2 KiB pages, 124 KiB LEBs (128 KiB PEBs less the EC and VID headers); at most
# 190 LEBs (23.5 MiB) in a 24 MiB volume, two of which fit mtd5 during an update
UBIFS_OPTS = -m 2048 -e 126976 -c 190 -x lzo -F -U

ubi: rootfs ## Pack new_rootfs/ as UBIFS -> rootfs.ubifs, and as a whole mtd5 UBI image -> rootfs.ubi (CFE)
	@# Guard: on 2026-11-04 a rootfs.ubifs came out 1.6 MB for a 13 MB tree (8.7 MB when rebuilt),
	@# most likely a container of a cancelled build still writing. LZO keeps ~2/3 of these static
	@# binaries: under 30 %, refuse.
	$(DOCKER_RUN) sh -c 'mkfs.ubifs $(UBIFS_OPTS) -r new_rootfs -o rootfs.ubifs && sync && \
	    t=$$(du -sk new_rootfs | cut -f1) && u=$$(( $$(stat -c %s rootfs.ubifs) / 1024 )) && \
	    { [ $$(( u * 100 / t )) -ge 30 ] || { echo "!! rootfs.ubifs is $$u KB for a $$t KB tree: truncated?"; rm -f rootfs.ubifs; exit 1; }; } && \
	    ubinize -o rootfs.ubi -p 128KiB -m 2048 -s 2048 scripts/ubinize-rootfs.cfg'
	@ls -lh rootfs.ubifs rootfs.ubi

ROOTFS_UPDATE = cd /dev/shm && chmod +x busybox $(UBI_TOOLS) && \
	vol() { ./busybox grep -l "^$$1$$" /sys/class/ubi/ubi0_*/name | ./busybox sed "s,.*/ubi0_,,;s,/name,,"; } && \
	{ [ -z "$$(vol rootfs_new)" ] || ./ubirmvol /dev/ubi0 -N rootfs_new; } && \
	./ubimkvol /dev/ubi0 -N rootfs_new -s 24MiB && \
	./ubiupdatevol /dev/ubi0_$$(vol rootfs_new) rootfs.ubifs && \
	./ubirename /dev/ubi0 rootfs rootfs_old rootfs_new rootfs && ./busybox sync

flash-rootfs: ## Flash the rootfs (UBI volume swap on mtd5) over SSH, then reboot
	@test -f rootfs.ubifs || { echo "!! rootfs.ubifs missing, run: make ubi"; exit 1; }
	@echo ">>> Flashing rootfs (mtd5) on $(DEVICE) in 3s, Ctrl+C to abort"; sleep 3
	scp rootfs.ubifs $(OUT)/busybox $(addprefix $(OUT)/,$(UBI_TOOLS)) root@$(DEVICE):/dev/shm/
	@# reboot -f drops the link: ssh then exits 255, a failure before it exits 1
	$(SSH) '$(ROOTFS_UPDATE) && ./busybox reboot -f' || [ $$? -eq 255 ]

flash-kernel: ## Flash build_output/vmlinuz to mtd4 over SSH, then reboot (CFE recovers if it fails)
	@test -f $(OUT)/vmlinuz || { echo "!! $(OUT)/vmlinuz missing, run: make kernel"; exit 1; }
	@echo ">>> Flashing KERNEL (mtd4) on $(DEVICE) in 5s, Ctrl+C to abort"; sleep 5
	scp $(OUT)/vmlinuz $(OUT)/flash_erase $(OUT)/nandwrite root@$(DEVICE):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase -q /dev/mtd4 0 0 && \
	    ./nandwrite -q -p /dev/mtd4 vmlinuz && sync && reboot' || [ $$? -eq 255 ]

flash-all: ## Flash kernel (mtd4) and rootfs (mtd5) over SSH, then reboot once
	@test -f $(OUT)/vmlinuz -a -f rootfs.ubifs || { echo "!! run: make kernel ubi"; exit 1; }
	@echo ">>> Flashing KERNEL + rootfs on $(DEVICE) in 5s, Ctrl+C to abort"; sleep 5
	scp $(OUT)/vmlinuz rootfs.ubifs $(OUT)/busybox $(OUT)/flash_erase $(OUT)/nandwrite \
	    $(addprefix $(OUT)/,$(UBI_TOOLS)) root@$(DEVICE):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase -q /dev/mtd4 0 0 && \
	    ./nandwrite -q -p /dev/mtd4 vmlinuz && $(ROOTFS_UPDATE) && ./busybox reboot -f' || [ $$? -eq 255 ]

# The /etc and /root overlays (/config, persistent) win over the image for good: a file edited
# once on the box hides every later version flashed. Lists them against new_rootfs/.
check-overlay: ## List the files the box's /config overlays hold, flagging those that hide the image's
	@test -d new_rootfs || { echo "!! new_rootfs/ missing, run: make rootfs"; exit 1; }
	@$(SSH) 'cd /config/overlay && find etc root ! -type d' | while read -r f; do \
	    if [ -e "new_rootfs/$$f" ] || [ -L "new_rootfs/$$f" ]; then echo "  HIDES IMAGE  /$$f"; \
	    else echo "  box only     /$$f"; fi; done

outdated: ## Compare every pinned version with the latest upstream release (network, read-only)
	@KERNEL_VERSION=$(KERNEL_VERSION) BUSYBOX_VERSION=$(BUSYBOX_VERSION) MTDUTILS_VERSION=$(MTDUTILS_VERSION) \
	 WPA_VERSION=$(WPA_VERSION) LIBNL_VERSION=$(LIBNL_VERSION) E2FSPROGS_VERSION=$(E2FSPROGS_VERSION) \
	 OPENSSH_VERSION=$(OPENSSH_VERSION) ZLIB_VERSION=$(ZLIB_VERSION) SMARTMONTOOLS_VERSION=$(SMARTMONTOOLS_VERSION) \
	 bash scripts/outdated.sh

connect: ## Open the UART console (picocom, logs to logs/)
	tools/airties.sh connect

# Cleaning
clean: ## Remove build artifacts (keeps builder image + kernel volume)
	rm -rf $(OUT) new_rootfs rootfs.ubifs rootfs.ubi rootfs-cfe.ubi

distclean: clean kernel-clean ## Also drop kernel volume, tarball cache and builder image
	rm -rf $(STAMP)
	docker rmi -f $(BUILDER_IMAGE) 2>/dev/null || true
