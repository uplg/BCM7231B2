# =============================================================================
# AirTies AIR 7310T (BCM7231B2, BMIPS4380, MIPS32 R1) — build orchestration
#
# Replaces the old per-target build_*.sh scripts. One Docker builder image
# (toolchain baked in), persistent kernel tree in a named volume for
# incremental rebuilds, source tarballs cached in build/dl.
#
#   make help          — list targets
#   make all           — kernel + squashfs (everything needed to flash)
#   make kernel KERNEL_VERSION=7.1.4   — try another kernel
# =============================================================================

KERNEL_VERSION   ?= 7.1.4
# GENET_DEBUG=1 re-enables the bcmgenet printk instrumentation
# (kernel/patch_bcmgenet_debug.py). Off by default since the IRQ
# off-by-one root cause was fixed in the DTS.
GENET_DEBUG      ?= 0
BUSYBOX_VERSION  ?= 1.38.0
DROPBEAR_VERSION ?= 2026.92
MTDUTILS_VERSION ?= 2.1.2
LIGHTTPD_VERSION ?= 1.4.85
MBEDTLS_VERSION  ?= 3.6.7

BUILDER_IMAGE ?= airties-builder
KBUILD_VOLUME ?= airties-kbuild

OUT   := build_output
STAMP := build
DL    := build/dl

# Device / host network (direct Ethernet)
DEVICE_IP ?= 192.168.2.1
HOST_IP   ?= 192.168.2.2
TFTP_DIR  ?= /private/tftpboot

SSH := ssh root@$(DEVICE_IP)

DOCKER_RUN = docker run --rm --platform linux/amd64 \
	-v "$(CURDIR)":/work \
	-v "$(CURDIR)/$(OUT)":/output \
	-v "$(CURDIR)/$(DL)":/dl \
	-w /work \
	$(BUILDER_IMAGE)

# Kernel additionally gets a named volume so the source tree (and object
# files) persist across builds — incremental rebuilds instead of 30 minutes.
DOCKER_RUN_KERNEL = $(subst -w /work,-v $(KBUILD_VOLUME):/kbuild -e KERNEL_VERSION=$(KERNEL_VERSION) -e GENET_DEBUG=$(GENET_DEBUG) -w /work,$(DOCKER_RUN))

# Small static diagnostic tools, one .c each in src/
TOOLS     := ephy_init ephy_diag genet_dump irq_dump init_raw init_test mount
TOOL_BINS := $(addprefix $(OUT)/,$(TOOLS))

.PHONY: help all builder kernel busybox dropbear mtdutils tools rootfs squashfs \
        tftp cfe-help flash-rootfs flash-kernel connect \
        clean kernel-clean distclean

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: KERNEL_VERSION=$(KERNEL_VERSION)  BUSYBOX_VERSION=$(BUSYBOX_VERSION)"
	@echo "             DROPBEAR_VERSION=$(DROPBEAR_VERSION)  DEVICE_IP=$(DEVICE_IP)"

all: kernel squashfs ## Build everything flashable (kernel + rootfs squashfs)

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

# (stamp file: macOS make 3.81 has no grouped targets for the two binaries)
$(OUT)/.mtdutils.stamp: scripts/mtdutils-build.sh $(STAMP)/builder.stamp $(STAMP)/mtdutils-$(MTDUTILS_VERSION).version
	$(DOCKER_RUN) env MTDUTILS_VERSION=$(MTDUTILS_VERSION) bash scripts/mtdutils-build.sh
	@touch $@

$(OUT)/flash_erase $(OUT)/nandwrite: $(OUT)/.mtdutils.stamp ;

mtdutils: $(OUT)/flash_erase $(OUT)/nandwrite ## Build static flash_erase + nandwrite

# --- Small diagnostic tools (src/<name>.c -> build_output/<name>) ---
TOOL_CFLAGS = -static -O2
$(OUT)/genet_dump: TOOL_CFLAGS = -static -O2 -Wall -Wextra
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
rootfs: $(OUT)/busybox $(OUT)/dropbearmulti $(OUT)/lighttpd $(OUT)/flash_erase $(TOOL_BINS) ## Assemble rootfs tree in new_rootfs/
	BASEDIR="$(CURDIR)" OUTDIR="$(CURDIR)/$(OUT)" NEWROOT="$(CURDIR)/new_rootfs" \
		bash scripts/mkrootfs.sh

squashfs: rootfs ## Pack new_rootfs/ -> new_rootfs.squashfs (gzip, 128K blocks)
	$(DOCKER_RUN) mksquashfs new_rootfs new_rootfs.squashfs \
		-comp gzip -b 131072 -all-root -noappend
	@ls -lh new_rootfs.squashfs

# -----------------------------------------------------------------------------
# Deploy / flash
# -----------------------------------------------------------------------------
tftp: ## Copy vmlinux + squashfs to $(TFTP_DIR) and start macOS tftpd (sudo)
	@test -f $(OUT)/vmlinux || { echo "!! $(OUT)/vmlinux missing — run: make kernel"; exit 1; }
	@test -f new_rootfs.squashfs || { echo "!! new_rootfs.squashfs missing — run: make squashfs"; exit 1; }
	sudo mkdir -p $(TFTP_DIR)
	sudo cp $(OUT)/vmlinux $(TFTP_DIR)/vmlinux
	sudo cp new_rootfs.squashfs $(TFTP_DIR)/new_rootfs.squashfs
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
	@echo "  CFE> flash $(HOST_IP):new_rootfs.squashfs nandflash0.rootfs -noheader"
	@echo "  CFE> flash $(HOST_IP):vmlinux nandflash0.kernel -noheader"
	@echo "  CFE> boot nandflash0.kernel:"
	@echo ""

# On-device reflash over SSH — the running custom firmware ships flash_erase +
# nandwrite, so iteration doesn't need the CFE/TFTP dance. Kernel flash is
# riskier (mtd4); CFE recovery always remains available.
flash-rootfs: ## Flash new_rootfs.squashfs to mtd5 over SSH, then reboot
	@test -f new_rootfs.squashfs || { echo "!! new_rootfs.squashfs missing — run: make squashfs"; exit 1; }
	@echo ">>> Flashing rootfs (mtd5) on $(DEVICE_IP) in 3s — Ctrl+C to abort"; sleep 3
	scp -O new_rootfs.squashfs root@$(DEVICE_IP):/dev/shm/new_rootfs.squashfs
	scp -O $(OUT)/flash_erase $(OUT)/nandwrite root@$(DEVICE_IP):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase /dev/mtd5 0 0 && ./nandwrite -p /dev/mtd5 new_rootfs.squashfs && sync && reboot'

flash-kernel: ## Flash build_output/vmlinux to mtd4 over SSH, then reboot (CFE recovers if it fails)
	@test -f $(OUT)/vmlinux || { echo "!! $(OUT)/vmlinux missing — run: make kernel"; exit 1; }
	@echo ">>> Flashing KERNEL (mtd4) on $(DEVICE_IP) in 5s — Ctrl+C to abort"; sleep 5
	scp -O $(OUT)/vmlinux root@$(DEVICE_IP):/dev/shm/vmlinux
	scp -O $(OUT)/flash_erase $(OUT)/nandwrite root@$(DEVICE_IP):/dev/shm/
	$(SSH) 'cd /dev/shm && chmod +x flash_erase nandwrite && ./flash_erase /dev/mtd4 0 0 && ./nandwrite -p /dev/mtd4 vmlinux && sync && reboot'

connect: ## Open the UART console (picocom, logs to logs/)
	tools/airties.sh connect

# -----------------------------------------------------------------------------
# Cleaning
# -----------------------------------------------------------------------------
clean: ## Remove build artifacts (keeps builder image + kernel volume)
	rm -rf $(OUT) new_rootfs new_rootfs.squashfs

distclean: clean kernel-clean ## Also drop kernel volume, tarball cache and builder image
	rm -rf $(STAMP)
	docker rmi -f $(BUILDER_IMAGE) 2>/dev/null || true
