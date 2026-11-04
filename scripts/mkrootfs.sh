#!/bin/bash
# Assemble the rootfs tree in new_rootfs/ from the prebuilt binaries in build_output/ and the
# files under rootfs/ (rootfs/base always, rootfs/backup with the backup role). Host-side, no
# compiler needed. What is generated here depends on the build: accounts, sshd_config, keys.
# `make ubi` then packs the tree as UBIFS.
#
# Env (set by the Makefile, with sane defaults): BASEDIR repo root, OUTDIR build_output/,
# NEWROOT new_rootfs/
set -e

BASEDIR="${BASEDIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OUTDIR="${OUTDIR:-$BASEDIR/build_output}"
NEWROOT="${NEWROOT:-$BASEDIR/new_rootfs}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[!]${NC} $1"; exit 1; }

# install <src> <dest in rootfs> [mode]: a built binary, or a warning when it was not built
install_bin() {
    if [ -f "$1" ]; then
        cp "$1" "$NEWROOT/$2"; chmod "${3:-755}" "$NEWROOT/$2"; info "+ $2"
    else
        warn "$(basename "$1") not built, /$2 left out"
        return 1
    fi
}
# copy_tree <dir>: a tree of files under rootfs/, modes kept, macOS extended attributes left out
copy_tree() { (cd "$1" && tar --no-xattrs -cf - .) | (cd "$NEWROOT" && tar -xf -); }

[ -f "$OUTDIR/busybox" ] || err "BusyBox not built (run: make busybox)"
[ -f "$OUTDIR/sshd" ]    || err "OpenSSH not built (run: make openssh)"

rm -rf "$NEWROOT"
info "Building rootfs tree..."
mkdir -p "$NEWROOT"/{bin,sbin,usr/{bin,sbin,libexec},etc/ssh,dev,proc,sys,tmp,var,root/.ssh,config,srv/backup}
chmod 700 "$NEWROOT/root/.ssh"
copy_tree "$BASEDIR/rootfs/base"

# BusyBox: every applet in /bin, plus the paths the kernel and inittab call in /sbin
info "Installing BusyBox..."
install_bin "$OUTDIR/busybox" bin/busybox
APPLETS="[ ash sh awk basename blkid cat chgrp chmod chown clear cmp cp cut date dd df diff
dirname dmesg du echo env expr false find findfs free getty grep gunzip gzip halt head hexdump
hostname id ifconfig ip kill killall klogd less ln logger login logread ls md5sum mkdir mknod
mkswap mktemp more mount mountpoint mv nc netstat nice nslookup ntpd passwd pgrep pidof ping
poweroff printf ps pwd readlink realpath reboot renice reset resize rm rmdir route sed seq
sha256sum sleep sort split start-stop-daemon stat strings stty su swapoff swapon sync sysctl
syslogd tac tail tar tee test time top touch tr traceroute true tty udhcpc umount uname uniq
uptime usleep vi watch watchdog wc wget which who whoami xargs yes crond crontab"
for a in $APPLETS; do ln -sf busybox "$NEWROOT/bin/$a"; done
for a in init getty halt poweroff reboot; do ln -sf ../bin/busybox "$NEWROOT/sbin/$a"; done
ln -sf ../../bin/busybox "$NEWROOT/usr/sbin/crond"

# OpenSSH, built without OpenSSL: Ed25519 keys only. Root logs in with a key on port 22; the
# backup accounts (if any) use port 2222.
info "Installing OpenSSH..."
install_bin "$OUTDIR/sshd" usr/sbin/sshd
install_bin "$OUTDIR/sshd-session" usr/libexec/sshd-session
install_bin "$OUTDIR/sshd-auth" usr/libexec/sshd-auth
install_bin "$OUTDIR/ssh-keygen" usr/bin/ssh-keygen
# Key-only root: refuse to build an image nobody can log into
grep -E '^(ssh-ed25519|sk-ssh-ed25519@openssh.com) ' "$BASEDIR/device/authorized_keys" \
    > "$NEWROOT/root/.ssh/authorized_keys" 2>/dev/null \
    || err "device/authorized_keys has no ssh-ed25519 key (OpenSSH here takes no RSA/ECDSA)"
chmod 600 "$NEWROOT/root/.ssh/authorized_keys"
info "  root keys: $(wc -l < "$NEWROOT/root/.ssh/authorized_keys") ed25519"

# WiFi (Netgear A6150, rtw88): credentials from device/wpa_supplicant.conf (gitignored), baked
# into /etc; the /config overlay keeps on-box edits
for t in wpa_supplicant wpa_cli wpa_passphrase; do install_bin "$OUTDIR/$t" "usr/sbin/$t" || true; done
if [ -f "$BASEDIR/device/wpa_supplicant.conf" ]; then
    cp "$BASEDIR/device/wpa_supplicant.conf" "$NEWROOT/etc/wpa_supplicant.conf"
    chmod 600 "$NEWROOT/etc/wpa_supplicant.conf"
else
    warn "No device/wpa_supplicant.conf: WiFi stays down (see device/wpa_supplicant.conf.example)"
fi

# kird (Ruwido remote -> maison): installed, started only when /etc/kird.conf sets KIRD_ENABLE=1
install_bin "$OUTDIR/kird" usr/sbin/kird || true
if [ -f "$BASEDIR/device/kird.conf" ]; then
    cp "$BASEDIR/device/kird.conf" "$NEWROOT/etc/kird.conf"; chmod 600 "$NEWROOT/etc/kird.conf"
fi

# Flash tools: the box reflashes itself over SSH (make flash-rootfs); the UBI ones for /config
for t in flash_erase nandwrite ubiformat ubiattach ubimkvol ubiupdatevol ubirename ubirmvol; do
    install_bin "$OUTDIR/$t" "usr/sbin/$t" || warn "  on-device reflash (make flash-rootfs) won't work"
done

# Backup target: ext4 disk, chrooted SFTP accounts, SMART reports. A server <host> gets the
# account vykar-<host>, chrooted by OpenSSH into /srv/backup/vykar-<host> (SFTP only), when
# device/vykar/<host>.pub holds its public key. Without keys the image has no backup role.
for t in mke2fs tune2fs e2fsck; do install_bin "$OUTDIR/$t" "sbin/$t" || true; done
[ -f "$NEWROOT/sbin/mke2fs" ] && ln -sf mke2fs "$NEWROOT/sbin/mkfs.ext4"
[ -f "$NEWROOT/sbin/e2fsck" ] && ln -sf e2fsck "$NEWROOT/sbin/fsck.ext4"
install_bin "$OUTDIR/smartctl" usr/sbin/smartctl || true

BACKUP_HOSTS=""
if ls "$BASEDIR"/device/vykar/*.pub >/dev/null 2>&1; then
    info "Backup role"
    copy_tree "$BASEDIR/rootfs/backup"
    mkdir -p "$NEWROOT/etc/ssh/vykar_authorized_keys"
    for k in "$BASEDIR"/device/vykar/*.pub; do
        h=$(basename "$k" .pub)
        BACKUP_HOSTS="${BACKUP_HOSTS:+$BACKUP_HOSTS }$h"
        echo "restrict $(cat "$k")" > "$NEWROOT/etc/ssh/vykar_authorized_keys/vykar-$h"
        chmod 644 "$NEWROOT/etc/ssh/vykar_authorized_keys/vykar-$h"
        info "  account vykar-$h"
    done
    echo "$BACKUP_HOSTS" > "$NEWROOT/etc/ssh/backup_hosts"
fi

# sshd_config: root (port 22, key only) + the backup accounts (port 2222, SFTP only, chrooted),
# each confined to its port
{
    echo "# AirTies: OpenSSH. Port 22: root, key only. Port 2222: backup accounts,"
    echo "# key only, SFTP only, each locked in its chroot on the backup disk."
    echo "Port 22"
    [ -n "$BACKUP_HOSTS" ] && echo "Port 2222"
    cat << SSHDCONF
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /var/run/sshd.pid
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/vykar_authorized_keys/%u
StrictModes yes
Subsystem sftp internal-sftp
# Sessions a client dropped without closing are reaped within ~1 min, and a
# burst of new connections cannot pile up (2026-10-12: vykar reconnecting
# every ~8 s on timeouts, sessions never closed, the box froze).
ClientAliveInterval 15
ClientAliveCountMax 4
MaxStartups 4:50:10
SSHDCONF
    if [ -n "$BACKUP_HOSTS" ]; then
        ACCOUNTS=$(for h in $BACKUP_HOSTS; do printf 'vykar-%s,' "$h"; done)
        cat << SSHDCONF
AllowGroups root vykar
Match LocalPort 22
    AllowGroups root
Match LocalPort 2222
    AllowGroups vykar
Match User ${ACCOUNTS%,}
    ChrootDirectory /srv/backup/%u
    ForceCommand internal-sftp -d /repo
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
SSHDCONF
    else
        echo "AllowGroups root"
    fi
} > "$NEWROOT/etc/ssh/sshd_config"

# Accounts
cat > "$NEWROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/ash
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/empty:/bin/false
EOF
cat > "$NEWROOT/etc/group" << 'EOF'
root:x:0:root
daemon:x:1:
nogroup:x:65534:
sshd:x:22:
EOF

# root password: random, generated on the first build into device/root-password (gitignored,
# 0600) and reused after; only its SHA-512 crypt hash goes into the image. SSH is key-only: the
# password is for the UART console.
ROOTPW_FILE="$BASEDIR/device/root-password"
if [ ! -s "$ROOTPW_FILE" ]; then
    info "Generating the root password (device/root-password)..."
    (umask 077; openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-24 > "$ROOTPW_FILE")
fi
ROOTPW_HASH=$(openssl passwd -6 -stdin < "$ROOTPW_FILE" 2>/dev/null) \
    || ROOTPW_HASH=$(docker run --rm -i --platform linux/amd64 airties-builder openssl passwd -6 -stdin < "$ROOTPW_FILE")
# shellcheck disable=SC2016  # the literal SHA-512 crypt prefix
case "$ROOTPW_HASH" in '$6$'*) ;; *) err "could not hash device/root-password" ;; esac
cat > "$NEWROOT/etc/shadow" << SHADOW
root:${ROOTPW_HASH}:0:0:99999:7:::
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/empty:/bin/false
SHADOW
chmod 640 "$NEWROOT/etc/shadow"

# Backup accounts: no password ("*" = no password login, keys still work; "!" would lock the key
# out too), a shell that is never run
if [ -n "$BACKUP_HOSTS" ]; then
    echo "vykar:x:600:" >> "$NEWROOT/etc/group"
    uid=601
    for h in $BACKUP_HOSTS; do
        echo "vykar-$h:x:$uid:600:vykar backups of $h:/srv/backup/vykar-$h:/bin/false" >> "$NEWROOT/etc/passwd"
        echo "vykar-$h:*:0:0:99999:7:::" >> "$NEWROOT/etc/shadow"
        uid=$((uid + 1))
    done
fi

# Files rewritten at run time live in RAM (/var/run), never in flash: the status banner behind
# /etc/issue (serial login prompt) and /etc/motd (SSH logins), resolv.conf (DHCP)
ln -sf /var/run/issue "$NEWROOT/etc/issue"
ln -sf /var/run/issue "$NEWROOT/etc/motd"
ln -sf /var/run/resolv.conf "$NEWROOT/etc/resolv.conf"
FIRMWARE=$(git -C "$BASEDIR" describe --always --dirty 2>/dev/null || echo unknown)
printf 'FIRMWARE=%s\nBUILT=%s\n' "$FIRMWARE" "$(date -u +%Y-%m-%d)" > "$NEWROOT/etc/firmware-release"

echo ""
du -sh "$NEWROOT"
info "Rootfs ready in $NEWROOT (firmware $FIRMWARE)"
