#!/bin/bash
# =============================================================================
# In-container OpenSSH build (static, musl, MIPS32 R1, no OpenSSL) — invoked
# by `make openssh`. Serves the chrooted SFTP-only backup accounts (Dropbear,
# the admin SSH, has no ChrootDirectory / internal-sftp).
# Without OpenSSL: Ed25519 keys, chacha20-poly1305 / aes-ctr, curve25519 and
# the post-quantum mlkem/sntrup key exchanges — all built in.
# Output: /output/sshd, /output/sshd-session, /output/sshd-auth, /output/ssh-keygen
# =============================================================================
set -e

OPENSSH_VERSION="${OPENSSH_VERSION:?OPENSSH_VERSION not set}"
ZLIB_VERSION="${ZLIB_VERSION:?ZLIB_VERSION not set}"
TARBALL="openssh-${OPENSSH_VERSION}.tar.gz"
URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${TARBALL}"
ZTARBALL="zlib-${ZLIB_VERSION}.tar.xz"
ZURL="https://zlib.net/${ZTARBALL}"

CROSS="$(cat /opt/cross-prefix)"
PREFIX=/tmp/ossh/sysroot

echo "============================================"
echo "  OpenSSH ${OPENSSH_VERSION} — static MIPS32 R1"
echo "============================================"

for pair in "$TARBALL $URL" "$ZTARBALL $ZURL"; do
    set -- $pair
    if [ ! -f "/dl/$1" ]; then
        echo "[*] Downloading $2 ..."
        wget -q -O "/dl/$1.part" "$2"
        mv "/dl/$1.part" "/dl/$1"
    fi
done

BUILDDIR=/tmp/ossh
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR" "$PREFIX"
tar xf "/dl/$ZTARBALL" -C "$BUILDDIR"
tar xf "/dl/$TARBALL" -C "$BUILDDIR"

echo "[*] zlib ${ZLIB_VERSION} (static)..."
cd "$BUILDDIR/zlib-${ZLIB_VERSION}"
CC="${CROSS}-gcc" CFLAGS="-Os" ./configure --static --prefix="$PREFIX" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null

echo "[*] Configuring OpenSSH..."
cd "$BUILDDIR/openssh-${OPENSSH_VERSION}"
./configure \
    --host="${CROSS}" \
    --prefix=/usr \
    --sysconfdir=/etc/ssh \
    --libexecdir=/usr/libexec \
    --with-pid-dir=/var/run \
    --with-privsep-path=/var/empty \
    --with-privsep-user=sshd \
    --with-zlib="$PREFIX" \
    --without-openssl \
    --without-pam \
    --without-selinux \
    --without-kerberos5 \
    --without-libedit \
    --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-lastlog \
    --disable-strip \
    --with-ldflags="-static" \
    CC="${CROSS}-gcc" \
    CFLAGS="-Os" \
    2>&1 | tail -25 | grep -E 'Host:|sandbox|Compiler flags|Linker flags|Libraries|crypto|error' || true

echo "[*] Building..."
set +e
make -j"$(nproc)" sshd sshd-session sshd-auth ssh-keygen 2>&1 | tee /output/openssh_build.log | tail -5
RET=${PIPESTATUS[0]}
set -e
[ "$RET" -eq 0 ] || { echo "!!! BUILD FAILED (build_output/openssh_build.log) !!!"; grep -i -E 'error|undefined' /output/openssh_build.log | tail -20; exit 1; }

for b in sshd sshd-session sshd-auth ssh-keygen; do
    file "$b" | grep -q 'statically linked' || { echo "!!! $b is not static !!!"; exit 1; }
    cp "$b" "/output/$b"
    "${CROSS}-strip" "/output/$b"
done

echo ""
echo "=== /output ==="
ls -lh /output/sshd /output/sshd-session /output/sshd-auth /output/ssh-keygen
file /output/sshd
