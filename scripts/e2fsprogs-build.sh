#!/bin/bash
# =============================================================================
# In-container e2fsprogs build (static, musl, MIPS32 R1) — invoked by
# `make e2fsprogs`. The box formats and checks its backup disk (ext4) with
# these; BusyBox only knows ext2.
# Output: /output/mke2fs, /output/e2fsck, /output/tune2fs
# =============================================================================
set -e

E2FSPROGS_VERSION="${E2FSPROGS_VERSION:?E2FSPROGS_VERSION not set}"
TARBALL="e2fsprogs-${E2FSPROGS_VERSION}.tar.xz"
URL="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v${E2FSPROGS_VERSION}/${TARBALL}"

CROSS="$(cat /opt/cross-prefix)"

echo "============================================"
echo "  e2fsprogs ${E2FSPROGS_VERSION} — static MIPS32 R1"
echo "============================================"

if [ ! -f "/dl/$TARBALL" ]; then
    echo "[*] Downloading $URL ..."
    wget -q -O "/dl/$TARBALL.part" "$URL"
    mv "/dl/$TARBALL.part" "/dl/$TARBALL"
fi

BUILDDIR=/tmp/e2fs
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"
tar xf "/dl/$TARBALL" -C "$BUILDDIR"
cd "$BUILDDIR/e2fsprogs-${E2FSPROGS_VERSION}"

# musl >= 1.2.4 keeps lseek64 for dynamic linking only: configure's link
# test fails statically, and lib/blkid/llseek.c falls back to a _syscall5
# macro musl lacks. musl's off_t is always 64-bit: plain lseek is the answer.
sed -i 's/^#if defined(HAVE_LSEEK64) && defined(HAVE_LSEEK64_PROTOTYPE)$/#if 1 \/* musl: 64-bit off_t *\//; s/^#define my_llseek lseek64$/#define my_llseek lseek/' lib/blkid/llseek.c
grep -q 'musl: 64-bit off_t' lib/blkid/llseek.c || { echo "!! llseek.c patch failed"; exit 1; }

echo "[*] Configuring..."
# Internal libuuid/libblkid (the toolchain has neither), no NLS, none of
# the optional tools we do not ship.
./configure \
    --host="${CROSS}" \
    --disable-nls \
    --disable-fuse2fs \
    --disable-defrag \
    --disable-imager \
    --disable-uuidd \
    --disable-debugfs \
    --disable-e2initrd-helper \
    --disable-tdb \
    --without-libarchive \
    CC="${CROSS}-gcc" \
    LDFLAGS="-static" \
    CFLAGS="-Os" \
    2>&1 | tail -3

echo "[*] Building mke2fs, tune2fs, e2fsck..."
make -j"$(nproc)" libs >/dev/null
make -j"$(nproc)" -C misc mke2fs tune2fs 2>&1 | tail -3
make -j"$(nproc)" -C e2fsck e2fsck 2>&1 | tail -3

for b in misc/mke2fs misc/tune2fs e2fsck/e2fsck; do
    [ -f "$b" ] || { echo "!!! BUILD FAILED: $b missing !!!"; exit 1; }
    file "$b" | grep -q 'statically linked' || { echo "!!! $b is not static !!!"; exit 1; }
    cp "$b" /output/
    "${CROSS}-strip" "/output/$(basename "$b")"
done
# No /etc/mke2fs.conf needed: mke2fs compiles in the stock profile (ext4).

echo ""
echo "=== /output ==="
ls -lh /output/mke2fs /output/tune2fs /output/e2fsck
file /output/mke2fs
