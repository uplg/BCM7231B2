#!/bin/sh
# =============================================================================
# FROG-HACK - Flash the new rootfs to mtd5
#
# Run this script ON THE DEVICE.
#
# Usage:
#   sh /path/to/flash_rootfs.sh [USB_BASE]
#
# The script auto-detects the USB mount point under /media/ if not given.
# Because stock firmware mounts USB with noexec, the flash tools are copied
# to /dev/shm (tmpfs, executable) before running.
#
# Required files on USB under frog-hack/:
#   new_rootfs.squashfs
#   flash_erase
#   nandwrite
#
# IMPORTANT: This modifies mtd5 (RootFS partition).
# The device has a recovery partition (mtd6) that should remain untouched.
# If something goes wrong, you can restore mtd5 from the backup.
# =============================================================================

# Auto-detect USB mount point
if [ -n "$1" ]; then
    USB_BASE="$1"
else
    # Stock firmware mounts USB under /media/volume_*
    USB_BASE=$(ls -d /media/volume_* 2>/dev/null | head -1)
    if [ -z "$USB_BASE" ]; then
        # Try /mnt/usb as fallback (new firmware)
        USB_BASE="/mnt/usb"
    fi
fi

USB="$USB_BASE/frog-hack"
MTD_DEV="/dev/mtd5"
IMAGE="$USB/new_rootfs.squashfs"

# Copy flash tools to executable tmpfs (USB may be mounted noexec)
WORKDIR="/dev/shm/frog-hack"
mkdir -p "$WORKDIR"
cp "$USB/flash_erase" "$WORKDIR/"
cp "$USB/nandwrite" "$WORKDIR/"
chmod +x "$WORKDIR/flash_erase" "$WORKDIR/nandwrite"

FLASH_ERASE="$WORKDIR/flash_erase"
NANDWRITE="$WORKDIR/nandwrite"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "============================================"
echo "  FROG-HACK - Flash Custom RootFS"
echo "============================================"
echo ""

# --- Sanity checks ---
if [ "$(id -u)" != "0" ]; then
    echo "${RED}[!] Must be run as root${NC}"
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo "${RED}[!] SquashFS image not found: $IMAGE${NC}"
    echo "    Make sure USB is mounted and files are in place."
    exit 1
fi

if [ ! -f "$FLASH_ERASE" ]; then
    echo "${RED}[!] flash_erase not found: $FLASH_ERASE${NC}"
    exit 1
fi

if [ ! -f "$NANDWRITE" ]; then
    echo "${RED}[!] nandwrite not found: $NANDWRITE${NC}"
    exit 1
fi

if [ ! -c "$MTD_DEV" ]; then
    echo "${RED}[!] MTD device not found: $MTD_DEV${NC}"
    exit 1
fi

# Show image info
IMAGE_SIZE=$(ls -l "$IMAGE" | awk '{print $5}')
IMAGE_SIZE_MB=$((IMAGE_SIZE / 1024 / 1024))
echo "[*] Image: $IMAGE"
echo "[*] Image size: ${IMAGE_SIZE} bytes (~${IMAGE_SIZE_MB} MB)"
echo "[*] Target: $MTD_DEV (mtd5 = RootFS, 70 MB)"
echo ""

# Verify image size is sane (< 70 MB = 73400320 bytes)
if [ "$IMAGE_SIZE" -gt 73400320 ]; then
    echo "${RED}[!] Image too large! Must be < 70 MB${NC}"
    exit 1
fi

# --- Safety backup of current mtd5 ---
BACKUP="$USB/backup/mtd5_pre_flash.bin"
mkdir -p "$USB/backup"
if [ ! -f "$BACKUP" ]; then
    echo "${YELLOW}[!] Creating safety backup of current mtd5...${NC}"
    dd if=/dev/mtd5ro of="$BACKUP" bs=131072 2>/dev/null
    sync
    BACKUP_SIZE=$(ls -l "$BACKUP" | awk '{print $5}')
    echo "[*] Backup saved: $BACKUP (${BACKUP_SIZE} bytes)"
else
    echo "[*] Pre-flash backup already exists: $BACKUP"
fi

echo ""
echo "============================================"
echo "  WARNING: This will ERASE and REWRITE"
echo "  the rootfs partition (mtd5)!"
echo ""
echo "  If this fails, the device may not boot."
echo "  Recovery options:"
echo "    1. Restore from backup via this script"
echo "    2. Recovery partition (mtd6) may auto-boot"
echo "    3. Re-flash via CFE bootloader"
echo "============================================"
echo ""
echo "Press ENTER to proceed, or Ctrl+C to abort..."
read dummy

# --- Step 1: Erase mtd5 ---
echo "[1/3] Erasing mtd5 (RootFS)..."
"$FLASH_ERASE" "$MTD_DEV" 0 0
if [ $? -ne 0 ]; then
    echo "${RED}[!] flash_erase failed!${NC}"
    echo "    The partition may be partially erased."
    echo "    You can try to restore with:"
    echo "    $NANDWRITE -p $MTD_DEV $BACKUP"
    exit 1
fi
echo "${GREEN}[+] Erase complete${NC}"

# --- Step 2: Write the new image ---
echo "[2/3] Writing new rootfs image..."
"$NANDWRITE" -p "$MTD_DEV" "$IMAGE"
if [ $? -ne 0 ]; then
    echo "${RED}[!] nandwrite failed!${NC}"
    echo "    Attempting to restore backup..."
    "$NANDWRITE" -p "$MTD_DEV" "$BACKUP"
    if [ $? -eq 0 ]; then
        echo "${GREEN}[+] Backup restored successfully${NC}"
    else
        echo "${RED}[!] Restore also failed! Device may need CFE recovery.${NC}"
    fi
    exit 1
fi
echo "${GREEN}[+] Write complete${NC}"

# --- Step 3: Verify ---
echo "[3/3] Verifying write..."
dd if=/dev/mtd5ro of=/tmp/verify.bin bs=131072 count=$((IMAGE_SIZE / 131072 + 1)) 2>/dev/null
# Truncate to image size for comparison
dd if=/tmp/verify.bin of=/tmp/verify_trimmed.bin bs=1 count="$IMAGE_SIZE" 2>/dev/null

HASH_ORIG=$(md5sum "$IMAGE" | awk '{print $1}')
HASH_FLASH=$(md5sum /tmp/verify_trimmed.bin | awk '{print $1}')

echo "[*] Image MD5:   $HASH_ORIG"
echo "[*] Flash MD5:   $HASH_FLASH"

if [ "$HASH_ORIG" = "$HASH_FLASH" ]; then
    echo "${GREEN}[+] Verification PASSED - hashes match!${NC}"
else
    echo "${YELLOW}[!] Verification MISMATCH - this may or may not be a problem${NC}"
    echo "    (NAND OOB/ECC data can cause minor differences in raw reads)"
fi

rm -f /tmp/verify.bin /tmp/verify_trimmed.bin

echo ""
echo "============================================"
echo "  Flash complete!"
echo ""
echo "  Reboot to test the new firmware:"
echo "    reboot"
echo ""
echo "  If boot fails, restore the original:"
echo "    $FLASH_ERASE $MTD_DEV 0 0"
echo "    $NANDWRITE -p $MTD_DEV $BACKUP"
echo "============================================"
echo ""
