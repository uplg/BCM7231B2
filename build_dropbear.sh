#!/bin/bash
# =============================================================================
# Build dropbear SSH for mipsel MIPS32 R1 (BCM7231 / BMIPS4380)
# Uses Bootlin toolchain (targets mips32 R1, not R2)
# =============================================================================
set -e

OUTDIR="$(pwd)/build_output"
mkdir -p "$OUTDIR"

echo "[*] Building static dropbear for mipsel (MIPS32 R1) via Docker..."

BUILDSCRIPT=$(mktemp)
cat > "$BUILDSCRIPT" << 'DOCKEREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Installing build dependencies..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential wget xz-utils file bzip2 >/dev/null 2>&1

echo "[2/5] Downloading Bootlin mips32el toolchain (MIPS32 R1, musl)..."
cd /tmp
wget -q https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/mips32el--musl--stable-2024.05-1.tar.xz
echo "    Download complete, extracting..."
tar xf mips32el--musl--stable-2024.05-1.tar.xz
TOOLCHAIN=/tmp/mips32el--musl--stable-2024.05-1

export PATH="${TOOLCHAIN}/bin:${PATH}"
CROSS=$(ls ${TOOLCHAIN}/bin/*-gcc 2>/dev/null | head -1 | sed 's/-gcc$//' | xargs basename)
echo "    Cross prefix: ${CROSS}"
CC=${CROSS}-gcc
STRIP=${CROSS}-strip

echo "[3/5] Checking compiler..."
${CC} --version | head -1

echo "[4/5] Downloading dropbear 2020.81..."
cd /tmp
wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-2020.81.tar.bz2
tar xjf dropbear-2020.81.tar.bz2
cd dropbear-2020.81

echo "[5/5] Configuring and compiling..."
./configure \
    --host=${CROSS} \
    --disable-zlib \
    --disable-wtmp \
    --disable-lastlog \
    CC="${CC}" \
    LDFLAGS="-static" \
    CFLAGS="-Os" \
    2>&1 | tail -5

make PROGRAMS="dropbear dropbearkey dbclient scp" STATIC=1 MULTI=1 SCPPROGRESS=0 -j$(nproc) 2>&1 | tail -10

if [ -f dropbearmulti ]; then
    cp dropbearmulti /output/dropbearmulti
    ${STRIP} /output/dropbearmulti
    echo ""
    echo "[OK] dropbearmulti:"
    ls -lh /output/dropbearmulti
    file /output/dropbearmulti
else
    echo "[WARN] Multi failed, trying dropbear+dropbearkey only..."
    make clean >/dev/null 2>&1
    make PROGRAMS="dropbear dropbearkey" STATIC=1 -j$(nproc) 2>&1 | tail -5
    if [ -f dropbear ]; then
        cp dropbear dropbearkey /output/
        ${STRIP} /output/dropbear /output/dropbearkey
        echo "[OK] Individual binaries built"
        ls -lh /output/dropbear*
    else
        echo "[ERROR] Build failed"
        exit 1
    fi
fi
DOCKEREOF

chmod +x "$BUILDSCRIPT"

docker run --rm --platform linux/amd64 \
    -v "$OUTDIR:/output" \
    -v "$BUILDSCRIPT:/build.sh:ro" \
    ubuntu:20.04 bash /build.sh

rm -f "$BUILDSCRIPT"

echo ""
echo "[*] Done. Output:"
ls -lh "$OUTDIR/dropbearmulti"
