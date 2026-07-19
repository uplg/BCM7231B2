# =============================================================================
# AirTies — cross-build environment for BCM7231B2 (BMIPS4380, MIPS32 R1)
#
# One image, built once, reused by every compile target in the Makefile.
# The Bootlin mips32el/musl toolchain is baked into a layer so it is
# downloaded a single time instead of once per tool (the old scripts each
# re-fetched it, ~100 MB every build).
#
# Build:  make builder   (docker build -t airties-builder -f docker/Dockerfile.builder docker)
# =============================================================================
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Superset of build deps across all targets (kernel needs bc/flex/bison/libssl/
# libelf/cpio/kmod; busybox/dropbear/mtd-utils need the rest; squashfs-tools
# packs the rootfs image so the host needs no mksquashfs).
RUN apt-get update -qq \
    && apt-get install -y -qq \
        build-essential wget xz-utils bzip2 file \
        bc flex bison libssl-dev libelf-dev python3 kmod cpio \
        squashfs-tools \
    && rm -rf /var/lib/apt/lists/*

# Bootlin mips32el--musl--stable-2024.05-1 — targets MIPS32 Release 1 only,
# which is all the BMIPS4380 supports. Static musl, zero shared-lib deps.
RUN wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz -O /tmp/tc.tar.xz \
    && mkdir -p /opt \
    && tar xf /tmp/tc.tar.xz -C /opt \
    && mv /opt/mips32el--musl--stable-2024.05-1 /opt/toolchain \
    && rm /tmp/tc.tar.xz

ENV PATH=/opt/toolchain/bin:$PATH

# Persist the cross prefix so build rules can read it without guessing.
# e.g. mipsel-buildroot-linux-musl-  ->  $CROSS-gcc, CROSS_COMPILE=$CROSS-
RUN CROSS=$(ls /opt/toolchain/bin/*-gcc | head -1 | sed 's/-gcc$//' | xargs basename) \
    && echo "$CROSS" > /opt/cross-prefix \
    && echo "Cross prefix: $CROSS"

WORKDIR /work
