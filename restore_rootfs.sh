#!/bin/sh
# =============================================================================
# FROG-HACK - Restore original rootfs from backup
#
# Run this ON THE DEVICE if the custom firmware doesn't work.
# Requires USB with backup and flash tools.
# Usage: sh /path/to/restore_rootfs.sh [USB_BASE]
# =============================================================================

# Auto-detect USB mount point
if [ -n "$1" ]; then
    USB_BASE="$1"
else
    USB_BASE=$(ls -d /media/volume_* 2>/dev/null | head -1)
    if [ -z "$USB_BASE" ]; then
        USB_BASE="/mnt/usb"
    fi
fi

USB="$USB_BASE/frog-hack"
MTD_DEV="/dev/mtd5"
BACKUP="$USB/backup/mtd5_pre_flash.bin"

# Copy flash tools to executable tmpfs (USB may be mounted noexec)
WORKDIR="/dev/shm/frog-hack"
mkdir -p "$WORKDIR"
cp "$USB/flash_erase" "$WORKDIR/"
cp "$USB/nandwrite" "$WORKDIR/"
chmod +x "$WORKDIR/flash_erase" "$WORKDIR/nandwrite"
FLASH_ERASE="$WORKDIR/flash_erase"
NANDWRITE="$WORKDIR/nandwrite"

echo ""
echo "============================================"
echo "  FROG-HACK - Restore Original RootFS"
echo "============================================"
echo ""

if [ ! -f "$BACKUP" ]; then
    # Try the original backup from the initial backup session
    BACKUP="$USB/backup/mtd5_backup.bin"
    if [ ! -f "$BACKUP" ]; then
        echo "[!] No backup found!"
        echo "    Looked for:"
        echo "      $USB/backup/mtd5_pre_flash.bin"
        echo "      $USB/backup/mtd5_backup.bin"
        exit 1
    fi
fi

echo "[*] Backup: $BACKUP"
echo "[*] Target: $MTD_DEV"
echo ""
echo "Press ENTER to restore, Ctrl+C to abort..."
read dummy

echo "[1/2] Erasing mtd5..."
"$FLASH_ERASE" "$MTD_DEV" 0 0
echo "[2/2] Writing original image..."
"$NANDWRITE" -p "$MTD_DEV" "$BACKUP"

echo ""
echo "[+] Restore complete. Reboot with: reboot"
echo ""
