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

# Bootlin mips32el--musl--stable-2026.08-1 (gcc 15.3, binutils 2.45.1, musl 1.2.6) — targets MIPS32 Release 1 only,
# which is all the BMIPS4380 supports. Static musl, zero shared-lib deps.
RUN wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2026.08-1.tar.xz -O /tmp/tc.tar.xz \
    && echo "e8517d51ba86699d5efaac62fc50fd9267dbdbc8b2cd3eb5b658db3582286778  /tmp/tc.tar.xz" | sha256sum -c - \
    && mkdir -p /opt \
    && tar xf /tmp/tc.tar.xz -C /opt \
    && mv /opt/mips32el--musl--stable-2026.08-1 /opt/toolchain \
    && rm /tmp/tc.tar.xz

ENV PATH=/opt/toolchain/bin:$PATH

# Persist the cross prefix so build rules can read it without guessing.
# e.g. mipsel-buildroot-linux-musl-  ->  $CROSS-gcc, CROSS_COMPILE=$CROSS-
RUN CROSS=$(ls /opt/toolchain/bin/*-gcc | head -1 | sed 's/-gcc$//' | xargs basename) \
    && echo "$CROSS" > /opt/cross-prefix \
    && echo "Cross prefix: $CROSS"

# CMake for lighttpd (its release tarballs no longer ship autotools configure),
# pkg-config for libnl (3.12's configure requires it).
# Kept as a separate late layer so adding it doesn't invalidate the toolchain cache.
RUN apt-get update -qq && apt-get install -y -qq cmake pkg-config && rm -rf /var/lib/apt/lists/*

# Rust nightly + rust-src for the kird daemon: mipsel-unknown-linux-musl is
# Tier 3 (no prebuilt std) AND defaults to MIPS32 R2, so kird builds std from
# source against a custom R1 target spec (see scripts/kird-build.sh).
# Late layer: adding/refreshing Rust never invalidates the C toolchain cache.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN wget -qO /tmp/rustup-init https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain nightly-2026-10-23 \
        --component rust-src \
    && rm /tmp/rustup-init
ENV PATH=/opt/cargo/bin:$PATH

# mkfs.ubifs + ubinize: the rootfs is a UBIFS image in the UBI volume "rootfs" (make ubi)
RUN apt-get update -qq && apt-get install -y -qq mtd-utils && rm -rf /var/lib/apt/lists/*

WORKDIR /work
