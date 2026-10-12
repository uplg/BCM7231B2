#!/bin/bash
# =============================================================================
# Assemble the rootfs tree from prebuilt binaries in build_output/.
# Host-side (no compiler needed): copies binaries, symlinks BusyBox applets,
# writes config + init scripts + default web page.
#
# The Makefile runs this, then packs the tree with mksquashfs.
#
# Env (set by Makefile, with sane defaults):
#   BASEDIR   repo root
#   OUTDIR    build_output/
#   NEWROOT   new_rootfs/
# =============================================================================
set -e

BASEDIR="${BASEDIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OUTDIR="${OUTDIR:-$BASEDIR/build_output}"
NEWROOT="${NEWROOT:-$BASEDIR/new_rootfs}"
ORIGINAL="$BASEDIR/rootfs_extracted/squashfs-root"

BUSYBOX="$OUTDIR/busybox"
DROPBEAR="$OUTDIR/dropbearmulti"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[!]${NC} $1"; exit 1; }

# --- Required inputs ---
[ -f "$BUSYBOX" ]  || err "BusyBox not found: $BUSYBOX (run: make busybox)"
# SSH server: OpenSSH when built (make openssh), else Dropbear
SSHD="$OUTDIR/sshd"
if [ -f "$SSHD" ]; then
    SSH_IMPL=openssh
else
    SSH_IMPL=dropbear
    [ -f "$DROPBEAR" ] || err "No SSH server: run make openssh (or make dropbear)"
fi

# --- Clean tree ---
rm -rf "$NEWROOT"
info "Building rootfs tree..."
mkdir -p "$NEWROOT"/{bin,sbin,usr/{bin,sbin,lib,share/www},lib,etc/{init.d,dropbear,params,network},dev,proc,sys,tmp,var/{run,log,tmp,lib},mnt/usb,media,root,home,config,srv/backup}

# --- BusyBox ---
info "Installing BusyBox..."
cp "$BUSYBOX" "$NEWROOT/bin/busybox"
chmod 755 "$NEWROOT/bin/busybox"

APPLETS="[ ash sh cat chmod chown chgrp cp cut date dd df
dmesg du echo env expr false find free grep gunzip gzip halt head
hexdump hostname id ifconfig ip
kill killall klogd ln login ls mkdir mknod mkswap mktemp
modprobe more mount mountpoint mv nc netstat nice nslookup passwd
ping pivot_root poweroff printf ps pwd readlink reboot renice
reset resize rm rmdir route sed seq sleep sort split
start-stop-daemon stat strings stty su swapoff swapon switch_root
sync sysctl syslogd tac tail tar tee telnetd test time
top touch tr traceroute true tty udhcpc udhcpd umount uname
uniq uptime usleep vi watch wc wget which
who whoami xargs yes httpd crond crontab awk insmod rmmod lsmod
logger logread clear basename dirname realpath pidof
findfs blkid ntpd pgrep"

cd "$NEWROOT/bin"
for a in $APPLETS; do ln -sf busybox "$a" 2>/dev/null || true; done

cd "$NEWROOT/sbin"
for a in init halt getty ifconfig ifdown ifup ip klogd modprobe mount \
    pivot_root poweroff reboot route start-stop-daemon swapoff swapon \
    switch_root sysctl syslogd udhcpc umount watchdog; do
    ln -sf ../bin/busybox "$a" 2>/dev/null || true
done

cd "$NEWROOT/usr/bin"
for a in awk crontab cut env expr free head hexdump id killall \
    nc nslookup passwd printf sort stat strings tail tee telnet \
    time top traceroute uniq uptime wc wget whoami xargs; do
    ln -sf ../../bin/busybox "$a" 2>/dev/null || true
done

cd "$NEWROOT/usr/sbin"
for a in crond httpd telnetd udhcpd; do ln -sf ../../bin/busybox "$a" 2>/dev/null || true; done
cd "$BASEDIR"

# --- SSH server ---
mkdir -p "$NEWROOT/root/.ssh"; chmod 700 "$NEWROOT/root/.ssh"
if [ "$SSH_IMPL" = openssh ]; then
    # OpenSSH, built without OpenSSL: Ed25519 keys only. Root logs in with a
    # key on port 22; the backup accounts (if any) use port 2222.
    info "Installing OpenSSH..."
    mkdir -p "$NEWROOT/usr/libexec" "$NEWROOT/etc/ssh"
    cp "$SSHD" "$NEWROOT/usr/sbin/sshd"
    cp "$OUTDIR/sshd-session" "$OUTDIR/sshd-auth" "$NEWROOT/usr/libexec/"
    cp "$OUTDIR/ssh-keygen" "$NEWROOT/usr/bin/ssh-keygen"
    chmod 755 "$NEWROOT/usr/sbin/sshd" "$NEWROOT"/usr/libexec/sshd-* "$NEWROOT/usr/bin/ssh-keygen"
    # Key-only root: refuse to build an image nobody can log into
    grep -E '^(ssh-ed25519|sk-ssh-ed25519@openssh.com) ' "$BASEDIR/device/authorized_keys" \
        > "$NEWROOT/root/.ssh/authorized_keys" 2>/dev/null \
        || err "device/authorized_keys has no ssh-ed25519 key (OpenSSH here takes no RSA/ECDSA)"
    chmod 600 "$NEWROOT/root/.ssh/authorized_keys"
    info "  root keys: $(wc -l < "$NEWROOT/root/.ssh/authorized_keys") ed25519"
else
    info "Installing Dropbear SSH..."
    cp "$DROPBEAR" "$NEWROOT/usr/sbin/dropbearmulti"
    chmod 755 "$NEWROOT/usr/sbin/dropbearmulti"
    cd "$NEWROOT/usr/sbin"; ln -sf dropbearmulti dropbear; ln -sf dropbearmulti dropbearkey
    cd "$NEWROOT/usr/bin"; ln -sf ../sbin/dropbearmulti dbclient; ln -sf ../sbin/dropbearmulti ssh; ln -sf ../sbin/dropbearmulti scp
    cd "$BASEDIR"
    if [ -f "$BASEDIR/device/authorized_keys" ]; then
        info "Installing SSH authorized_keys..."
        cp "$BASEDIR/device/authorized_keys" "$NEWROOT/root/.ssh/authorized_keys"
        chmod 600 "$NEWROOT/root/.ssh/authorized_keys"
    fi
fi
if [ "$SSH_IMPL" = dropbear ]; then
# Extra dropbear args, read by rcS at startup.
# e.g. `make rootfs DROPBEAR_ARGS=-s` disables password auth (key-only) —
# only do that once key login is confirmed working!
echo "${DROPBEAR_ARGS:-}" > "$NEWROOT/etc/dropbear/args"

# Persistent host keys (device/dropbear/, gitignored) — baked into the image
# so the host identity survives reboots (/var is tmpfs) and reflashes.
if [ -f "$BASEDIR/device/dropbear/dropbear_rsa_host_key" ]; then
    info "Installing persistent Dropbear host keys..."
    cp "$BASEDIR"/device/dropbear/dropbear_*_host_key "$NEWROOT/etc/dropbear/"
    chmod 600 "$NEWROOT"/etc/dropbear/dropbear_*_host_key
else
    warn "No device/dropbear/ host keys — the box will regenerate them each boot"
fi
fi

# --- lighttpd: modern web server (HTTP/2, TLS 1.3 via mbedTLS) ---
if [ -f "$OUTDIR/lighttpd" ]; then
    info "+ lighttpd (with TLS cert)"
    cp "$OUTDIR/lighttpd" "$NEWROOT/usr/sbin/lighttpd"; chmod 755 "$NEWROOT/usr/sbin/lighttpd"
    mkdir -p "$NEWROOT/etc/lighttpd"

    # Self-signed cert: generated once on the host, cached in build/tls/
    TLSDIR="$BASEDIR/build/tls"
    if [ ! -f "$TLSDIR/server.pem" ]; then
        info "Generating self-signed TLS certificate (10y, CN=airties.local)..."
        mkdir -p "$TLSDIR"
        openssl req -x509 -newkey rsa:2048 -keyout "$TLSDIR/key.pem" \
            -out "$TLSDIR/cert.pem" -days 3650 -nodes -subj "/CN=airties.local" \
            -addext "subjectAltName=IP:192.168.2.1,DNS:airties.local" 2>/dev/null \
        || openssl req -x509 -newkey rsa:2048 -keyout "$TLSDIR/key.pem" \
            -out "$TLSDIR/cert.pem" -days 3650 -nodes -subj "/CN=airties.local" 2>/dev/null
        cat "$TLSDIR/key.pem" "$TLSDIR/cert.pem" > "$TLSDIR/server.pem"
    fi
    cp "$TLSDIR/server.pem" "$NEWROOT/etc/lighttpd/server.pem"
    chmod 600 "$NEWROOT/etc/lighttpd/server.pem"

    cat > "$NEWROOT/etc/lighttpd/lighttpd.conf" << 'LIGHTTPDCONF'
# AirTies — lighttpd (static build: all modules compiled in)
server.modules        = ( "mod_mbedtls", "mod_cgi" )
server.document-root  = "/usr/share/www"
server.port           = 80
server.username       = "www"
server.groupname      = "www"
server.pid-file       = "/var/run/lighttpd.pid"
server.errorlog-use-syslog = "enable"
server.upload-dirs    = ( "/tmp" )
index-file.names      = ( "index.html" )
mimetype.assign = (
    ".html" => "text/html", ".css" => "text/css",
    ".js" => "text/javascript", ".json" => "application/json",
    ".png" => "image/png", ".jpg" => "image/jpeg",
    ".svg" => "image/svg+xml", ".txt" => "text/plain"
)
$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( "" => "" )
}
$SERVER["socket"] == ":443" {
    ssl.engine  = "enable"
    ssl.pemfile = "/etc/lighttpd/server.pem"
}
LIGHTTPDCONF
fi

# --- WiFi userland: wpa_supplicant for the Netgear A6150 dongle (rtw88) ---
for t in wpa_supplicant wpa_cli wpa_passphrase; do
    if [ -f "$OUTDIR/$t" ]; then
        info "+ $t"
        cp "$OUTDIR/$t" "$NEWROOT/usr/sbin/$t"; chmod 755 "$NEWROOT/usr/sbin/$t"
    else
        warn "$t not built — WiFi won't come up (run: make wpa)"
    fi
done

# WiFi credentials: device/wpa_supplicant.conf (gitignored) baked into /etc.
# The /config overlay makes later on-box edits persistent.
if [ -f "$BASEDIR/device/wpa_supplicant.conf" ]; then
    info "Installing wpa_supplicant.conf..."
    cp "$BASEDIR/device/wpa_supplicant.conf" "$NEWROOT/etc/wpa_supplicant.conf"
    chmod 600 "$NEWROOT/etc/wpa_supplicant.conf"
else
    warn "No device/wpa_supplicant.conf — WiFi stays down (see device/wpa_supplicant.conf.example)"
fi

# --- kird: Ruwido remote -> maison HTTP bridge ---
if [ -f "$OUTDIR/kird" ]; then
    info "+ kird"
    cp "$OUTDIR/kird" "$NEWROOT/usr/sbin/kird"; chmod 755 "$NEWROOT/usr/sbin/kird"
else
    warn "kird not built — remote won't reach maison (run: make kird)"
fi
if [ -f "$BASEDIR/device/kird.conf" ]; then
    info "Installing kird.conf..."
    cp "$BASEDIR/device/kird.conf" "$NEWROOT/etc/kird.conf"
    chmod 600 "$NEWROOT/etc/kird.conf"
else
    warn "No device/kird.conf — kird stays down (see device/kird.conf.example)"
fi

# --- Flash tools: let the box reflash itself over SSH (make flash-rootfs) ---
for t in flash_erase nandwrite; do
    if [ -f "$OUTDIR/$t" ]; then
        info "+ $t"
        cp "$OUTDIR/$t" "$NEWROOT/usr/sbin/$t"; chmod 755 "$NEWROOT/usr/sbin/$t"
    else
        warn "$t not built — on-device reflash (make flash-rootfs) won't work"
    fi
done

# --- Backup target: ext4 disk, chrooted SFTP accounts, SMART reports ---
# A server <host> gets the account vykar-<host>, chrooted by OpenSSH into
# /srv/backup/vykar-<host> (SFTP only), when device/vykar/<host>.pub holds
# its public key. Without OpenSSH or keys the image has no backup role.
for t in mke2fs tune2fs e2fsck; do
    if [ -f "$OUTDIR/$t" ]; then info "+ $t"; cp "$OUTDIR/$t" "$NEWROOT/sbin/$t"; chmod 755 "$NEWROOT/sbin/$t"; fi
done
[ -f "$NEWROOT/sbin/mke2fs" ] && ln -sf mke2fs "$NEWROOT/sbin/mkfs.ext4"
[ -f "$NEWROOT/sbin/e2fsck" ] && ln -sf e2fsck "$NEWROOT/sbin/fsck.ext4"
if [ -f "$OUTDIR/smartctl" ]; then
    info "+ smartctl"
    cp "$OUTDIR/smartctl" "$NEWROOT/usr/sbin/smartctl"; chmod 755 "$NEWROOT/usr/sbin/smartctl"
fi

BACKUP_HOSTS=""
if [ "$SSH_IMPL" = openssh ] && ls "$BASEDIR"/device/vykar/*.pub >/dev/null 2>&1; then
    info "+ backup accounts"
    mkdir -p "$NEWROOT/etc/ssh/vykar_authorized_keys"
    for k in "$BASEDIR"/device/vykar/*.pub; do
        h=$(basename "$k" .pub)
        BACKUP_HOSTS="$BACKUP_HOSTS $h"
        echo "restrict $(cat "$k")" > "$NEWROOT/etc/ssh/vykar_authorized_keys/vykar-$h"
        chmod 644 "$NEWROOT/etc/ssh/vykar_authorized_keys/vykar-$h"
        info "  account vykar-$h"
    done
    BACKUP_HOSTS="${BACKUP_HOSTS# }"
    echo "$BACKUP_HOSTS" > "$NEWROOT/etc/ssh/backup_hosts"
    ACCOUNTS=$(for h in $BACKUP_HOSTS; do printf 'vykar-%s,' "$h"; done)

fi

# sshd_config: root (port 22, key only) + the backup accounts (port 2222,
# SFTP only, chrooted), each confined to its port.
if [ "$SSH_IMPL" = openssh ]; then
    {
        echo "# AirTies — OpenSSH. Port 22: root, key only. Port 2222: backup accounts,"
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
fi

# --- Optional diagnostic tools (included only if built) ---
# init_raw wins over init_test for the /sbin/init_test slot (raw-syscall diag).
if   [ -f "$OUTDIR/init_raw" ];  then info "+ init_raw (as /sbin/init_test)";  cp "$OUTDIR/init_raw"  "$NEWROOT/sbin/init_test"; chmod 755 "$NEWROOT/sbin/init_test"
elif [ -f "$OUTDIR/init_test" ]; then info "+ init_test";                      cp "$OUTDIR/init_test" "$NEWROOT/sbin/init_test"; chmod 755 "$NEWROOT/sbin/init_test"; fi

for t in irq_dump ephy_init ephy_diag genet_dump; do
    if [ -f "$OUTDIR/$t" ]; then info "+ $t"; cp "$OUTDIR/$t" "$NEWROOT/sbin/$t"; chmod 755 "$NEWROOT/sbin/$t"; fi
done

# --- Config files ---
info "Writing config files..."

cat > "$NEWROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/ash
daemon:x:1:1:daemon:/usr/sbin:/bin/false
www:x:33:33:www:/usr/share/www:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
EOF

# root password: random, generated on the first build into device/root-password
# (gitignored, 0600) and reused after; only its SHA-512 crypt hash goes into
# the image. SSH is key-only: the password is for the UART console.
ROOTPW_FILE="$BASEDIR/device/root-password"
if [ ! -s "$ROOTPW_FILE" ]; then
    info "Generating the root password (device/root-password)..."
    (umask 077; openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-24 > "$ROOTPW_FILE")
fi
ROOTPW_HASH=$(openssl passwd -6 -stdin < "$ROOTPW_FILE" 2>/dev/null) \
    || ROOTPW_HASH=$(docker run --rm -i --platform linux/amd64 airties-builder openssl passwd -6 -stdin < "$ROOTPW_FILE")
case "$ROOTPW_HASH" in '$6$'*) ;; *) err "could not hash device/root-password" ;; esac
cat > "$NEWROOT/etc/shadow" << SHADOW
root:${ROOTPW_HASH}:0:0:99999:7:::
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
SHADOW
chmod 640 "$NEWROOT/etc/shadow"

cat > "$NEWROOT/etc/group" << 'EOF'
root:x:0:root
daemon:x:1:
www:x:33:
nogroup:x:65534:
sshd:x:22:
EOF

# Backup accounts: no password ("*" = no password login, keys still work;
# "!" would lock the key out too), a shell that is never run.
if [ -n "$BACKUP_HOSTS" ]; then
    echo "vykar:x:600:" >> "$NEWROOT/etc/group"
    uid=601
    for h in $BACKUP_HOSTS; do
        echo "vykar-$h:x:$uid:600:vykar backups of $h:/srv/backup/vykar-$h:/bin/false" >> "$NEWROOT/etc/passwd"
        echo "vykar-$h:*:0:0:99999:7:::" >> "$NEWROOT/etc/shadow"
        uid=$((uid + 1))
    done
fi

echo "AirTies" > "$NEWROOT/etc/hostname"

cat > "$NEWROOT/etc/hosts" << 'EOF'
127.0.0.1	localhost AirTies
::1		localhost
EOF

cat > "$NEWROOT/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

cat > "$NEWROOT/etc/nsswitch.conf" << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

cat > "$NEWROOT/etc/fstab" << 'EOF'
# <device>       <mountpoint>  <type>    <options>          <dump> <pass>
proc              /proc         proc      defaults           0      0
sysfs             /sys          sysfs     defaults           0      0
devtmpfs          /dev          devtmpfs  defaults           0      0
tmpfs             /tmp          tmpfs     size=10M           0      0
tmpfs             /var          tmpfs     size=2M            0      0
EOF

cat > "$NEWROOT/etc/profile" << 'EOF'
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export TERM="vt102"
export PS1='\u@AirTies:\w# '
export EDITOR=vi

alias ll='ls -la'
alias la='ls -A'

if [ -x /etc/init.d/rcServices ] && [ ! -f /var/run/rcServices.started ]; then
    /etc/init.d/rcServices >/dev/null 2>&1 &
fi

echo ""
echo "  AirTies AIR 7310T"
echo "  $(uname -r) on $(hostname)"
echo ""
EOF

cat > "$NEWROOT/etc/inittab" << 'EOF'
# BusyBox inittab — <id>:<runlevels>:<action>:<process>
::sysinit:/etc/init.d/rcS
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt102
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/init.d/rcK
EOF

cat > "$NEWROOT/etc/shells" << 'EOF'
/bin/ash
/bin/sh
EOF

# --- Init scripts ---
info "Writing init scripts..."

cat > "$NEWROOT/etc/init.d/rcS" << 'INITSCRIPT'
#!/bin/sh
# AirTies — system init: mount fs, bring up net, start services, hand off to getty.
echo "[init] Starting AirTies..."

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs -o size=10M tmpfs /tmp
mount -t tmpfs -o size=2M tmpfs /var
mkdir -p /var/run /var/log /var/tmp /var/lib

# Persistent storage: JFFS2 on mtd2 (ConfigFS, 6 MB), then overlay /etc
# and /root so changes (resolv.conf, dropbear keys, shell history) survive
# reboots and reflashes.  First boot: mtd2 still holds the vendor ConfigFS
# (backed up in backup/mtd2_backup.bin) — erase with cleanmarkers, remount.
mkdir -p /config
if ! mount -t jffs2 /dev/mtdblock2 /config 2>/dev/null; then
    echo "[init] /config: formatting mtd2 (first boot)..."
    flash_erase -j -q /dev/mtd2 0 0 2>/dev/null
    mount -t jffs2 /dev/mtdblock2 /config 2>/dev/null \
        || echo "[init] WARNING: /config unavailable, running volatile"
fi
if grep -q ' /config ' /proc/mounts; then
    for d in etc root; do
        mkdir -p "/config/overlay/$d" "/config/overlay/.$d-work"
        mount -t overlay \
            -o "lowerdir=/$d,upperdir=/config/overlay/$d,workdir=/config/overlay/.$d-work" \
            overlay "/$d" \
            || echo "[init] WARNING: overlay /$d failed"
    done
fi

hostname AirTies
ifconfig lo 127.0.0.1 netmask 255.0.0.0 up

ifconfig eth0 up 2>/dev/null || true
if command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i eth0 -s /etc/network/udhcpc.script -n -q >/dev/null 2>&1 || true
fi

IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
    ifconfig eth0 192.168.2.1 netmask 255.255.255.0 up 2>/dev/null || true
    IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
fi

syslogd -C256
klogd

# WiFi + kird, after syslogd (they log through it). Backgrounded with fds
# detached from the console: getty's vhangup() on ttyS0 would otherwise kill
# them once rcS ends (wifi waits up to 10s for USB enumeration).
[ -x /etc/init.d/wifi ] && /etc/init.d/wifi </dev/null >/dev/null 2>&1 &
# kird: Ruwido remote -> maison bridge (no-op without /etc/kird.conf)
[ -x /etc/init.d/kird ] && /etc/init.d/kird </dev/null >/dev/null 2>&1
# Backup target (disk, clock, tailnet, SFTP); without it, just the clock
if [ -x /etc/init.d/backup ]; then
    /etc/init.d/backup </dev/null >/dev/null 2>&1 &
else
    /etc/init.d/ntp </dev/null >/dev/null 2>&1 &
fi

# Hardware watchdog (bcm7038-wdt): 60 s timeout, petted every 10 s.
# A hard hang (kernel or PID-storm) stops the petting -> hardware reset
# -> CFE STARTUP chain boots the kernel (or recovery if it's corrupt).
if [ -c /dev/watchdog ]; then
    watchdog -T 60 -t 10 /dev/watchdog
    echo "[init] Watchdog armed (60s timeout)"
fi

USB_MOUNT=
if [ -e /dev/sda1 ]; then
    mkdir -p /mnt/usb
    mount /dev/sda1 /mnt/usb 2>/dev/null && USB_MOUNT=/mnt/usb
fi

# SSH: OpenSSH (/etc/init.d/sshd) when the image has it, else Dropbear
if [ -x /etc/init.d/sshd ]; then
    echo "[init] Starting SSH (OpenSSH)..."
    /etc/init.d/sshd
elif [ -x /usr/sbin/dropbear ]; then
    # Host keys: baked at image build, else generated into /etc/dropbear —
    # persistent when the /config overlay is up, volatile fallback otherwise.
    DBKEYDIR="/etc/dropbear"
    mkdir -p /var/run "$DBKEYDIR" 2>/dev/null
    if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ]; then
        if touch "$DBKEYDIR/.rw-test" 2>/dev/null; then
            rm -f "$DBKEYDIR/.rw-test"
        else
            DBKEYDIR="/var/lib/dropbear"; mkdir -p "$DBKEYDIR"
        fi
        /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
        /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
    fi
    echo "[init] Starting SSH (Dropbear)..."
    /usr/sbin/dropbear -r "$DBKEYDIR/dropbear_rsa_host_key" -r "$DBKEYDIR/dropbear_ed25519_host_key" \
        $(cat /etc/dropbear/args 2>/dev/null)
fi
if [ -x /usr/sbin/lighttpd ]; then
    echo "[init] Starting HTTP (lighttpd)..."
    /usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf
elif [ -x /usr/sbin/httpd ]; then
    echo "[init] Starting HTTP..."
    /usr/sbin/httpd -p 80 -h /usr/share/www
fi

echo ""
echo "============================================"
echo "  AirTies ready"
echo "  IP: ${IP_ADDR:-192.168.2.1}"
echo "  SSH:   port 22"
echo "  HTTP:  port 80 / HTTPS: port 443"
echo "============================================"
echo ""
INITSCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcS"

cat > "$NEWROOT/etc/init.d/rcServices" << 'SERVICESCRIPT'
#!/bin/sh
[ -f /var/run/rcServices.started ] && exit 0
touch /var/run/rcServices.started

syslogd -C256
klogd

USB_MOUNT=
if [ -e /dev/sda1 ]; then
    mkdir -p /mnt/usb
    mount /dev/sda1 /mnt/usb 2>/dev/null && USB_MOUNT=/mnt/usb
fi

if [ -x /etc/init.d/sshd ]; then
    /etc/init.d/sshd
elif [ -x /usr/sbin/dropbear ]; then
    DBKEYDIR="/etc/dropbear"
    if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ]; then
        DBKEYDIR="/var/lib/dropbear"
        mkdir -p "$DBKEYDIR"
        /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
        /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
    fi
    /usr/sbin/dropbear -r "$DBKEYDIR/dropbear_rsa_host_key" -r "$DBKEYDIR/dropbear_ed25519_host_key" \
        $(cat /etc/dropbear/args 2>/dev/null)
fi
if [ -x /usr/sbin/lighttpd ]; then
    /usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf
elif [ -x /usr/sbin/httpd ]; then
    /usr/sbin/httpd -p 80 -h /usr/share/www
fi
SERVICESCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcServices"

cat > "$NEWROOT/etc/init.d/wifi" << 'WIFISCRIPT'
#!/bin/sh
# Bring up wlan0 (Netgear A6150 / rtw88_8822bu) — idempotent, safe to re-run.
# Credentials: /etc/wpa_supplicant.conf (persistent via the /config overlay).
[ -x /usr/sbin/wpa_supplicant ] || exit 0
[ -f /etc/wpa_supplicant.conf ] || exit 0

# USB enumeration + firmware load can land a few seconds after rcS runs
n=0
while [ ! -d /sys/class/net/wlan0 ] && [ "$n" -lt 20 ]; do usleep 500000; n=$((n+1)); done
[ -d /sys/class/net/wlan0 ] || { logger -t wifi "no wlan0 (dongle absent?)"; exit 1; }

ifconfig wlan0 up 2>/dev/null || true
if ! pidof wpa_supplicant >/dev/null 2>&1; then
    /usr/sbin/wpa_supplicant -B -s -i wlan0 -c /etc/wpa_supplicant.conf
fi
PIDFILE=/var/run/udhcpc.wlan0.pid
if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    udhcpc -i wlan0 -s /etc/network/udhcpc.script -b -p "$PIDFILE" >/dev/null 2>&1
fi
# Keep it up (one watcher, started here)
W=/var/run/wifi-watch.pid
if [ ! -f "$W" ] || ! kill -0 "$(cat "$W" 2>/dev/null)" 2>/dev/null; then
    start-stop-daemon -S -b -m -p "$W" -x /usr/sbin/wifi-watch
fi
WIFISCRIPT
chmod 755 "$NEWROOT/etc/init.d/wifi"

cat > "$NEWROOT/usr/sbin/wifi-watch" << 'WATCHSCRIPT'
#!/bin/sh
# wlan0 is the only way in: when the gateway stops answering, restart WiFi
# (3 min), then reboot cleanly (8 min: the dongle or its driver is gone).
# The hardware watchdog only catches a hung kernel, not a dead link.
fails=0
while :; do
    sleep 60
    gw=$(ip route | awk '/^default/ && /wlan0/ {print $3; exit}')
    if [ -n "$gw" ] && ping -c 2 -W 3 "$gw" >/dev/null 2>&1; then
        [ "$fails" -gt 0 ] && logger -t wifi-watch "gateway $gw back after $fails min"
        fails=0; continue
    fi
    fails=$((fails + 1))
    logger -t wifi-watch "gateway ${gw:-none} unreachable ($fails min)"
    case "$fails" in
        3) logger -t wifi-watch "restarting WiFi"
           killall wpa_supplicant udhcpc 2>/dev/null; rm -f /var/run/udhcpc.wlan0.pid
           ifconfig wlan0 down 2>/dev/null; sleep 2
           /etc/init.d/wifi ;;
        8) logger -t wifi-watch "WiFi still down: rebooting"
           sync; reboot ;;
    esac
done
WATCHSCRIPT
chmod 755 "$NEWROOT/usr/sbin/wifi-watch"

cat > "$NEWROOT/etc/init.d/kird" << 'KIRDSCRIPT'
#!/bin/sh
# kird supervisor — Ruwido remote -> maison HTTP bridge. Idempotent.
# Config: /etc/kird.conf (persistent via the /config overlay).
#
# The binary is preferred from /config (jffs2, writable) so it can be swapped
# without reflashing the read-only squashfs rootfs; /usr/sbin is the copy
# baked into the image.
KIRD_BIN=/usr/sbin/kird
[ -x /config/kird ] && KIRD_BIN=/config/kird
[ -x "$KIRD_BIN" ] || exit 0
[ -f /etc/kird.conf ] || exit 0
# Idempotence: look for the real daemon binary. A bare `pidof kird` would
# match THIS script (comm is also "kird" when rcS execs it directly).
for pid in $(pidof kird); do
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$KIRD_BIN" ] && exit 0
done
. /etc/kird.conf
export KIRD_URL KIRD_TOKEN KIRD_DEVICE
(
    while :; do
        "$KIRD_BIN" 2>&1 | logger -t kird
        sleep 5
    done
) </dev/null >/dev/null 2>&1 &
KIRDSCRIPT
chmod 755 "$NEWROOT/etc/init.d/kird"

if [ "$SSH_IMPL" = openssh ]; then
cat > "$NEWROOT/etc/init.d/sshd" << 'SSHDSCRIPT'
#!/bin/sh
# OpenSSH: root on 22 (key only), backup accounts on 2222. Idempotent. The
# host key lives on the persistent /etc overlay: same identity across
# reboots and reflashes.
[ -f /var/run/sshd.pid ] && kill -0 "$(cat /var/run/sshd.pid)" 2>/dev/null && exit 0
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
mkdir -p /var/empty; chmod 755 /var/empty
/usr/sbin/sshd -f /etc/ssh/sshd_config
SSHDSCRIPT
chmod 755 "$NEWROOT/etc/init.d/sshd"
fi

cat > "$NEWROOT/etc/init.d/ntp" << 'NTPSCRIPT'
#!/bin/sh
# Clock: no RTC on this board, it boots in 1970 (TLS certificates then look
# "not yet valid"). Waits for a first sync, then keeps ntpd running.
pidof ntpd >/dev/null 2>&1 && exit 0
PEERS="-p 0.pool.ntp.org -p 1.pool.ntp.org -p 2.pool.ntp.org"
n=0
until ntpd -n -q $PEERS >/dev/null 2>&1; do
    n=$((n + 1)); [ "$n" -ge 60 ] && break
    sleep 5
done
logger -t ntp "clock: $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
ntpd $PEERS
NTPSCRIPT
chmod 755 "$NEWROOT/etc/init.d/ntp"

if [ -n "$BACKUP_HOSTS" ]; then
cat > "$NEWROOT/etc/init.d/backup" << 'BACKUPSCRIPT'
#!/bin/sh
# Backup target: mounts the backup disk (ext4, label "backup") on
# /srv/backup, then starts tailscaled (from the disk: upgraded without a
# reflash) and the hourly SMART report. sshd (rcS) serves the chroots.
# Idempotent. Runs in the background from rcS (waits for disk and clock).
D=/srv/backup   # mount point baked into the read-only rootfs
if ! mountpoint -q "$D"; then
    n=0
    while ! DEV=$(findfs LABEL=backup 2>/dev/null) && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
    [ -n "$DEV" ] || { logger -t backup "no disk labelled 'backup'"; exit 1; }
    # -p repairs what is safe to repair; 4 and up means a person must look
    e2fsck -p "$DEV" > /tmp/fsck.log 2>&1; rc=$?
    logger -t backup < /tmp/fsck.log
    [ "$rc" -ge 4 ] && { logger -t backup "e2fsck $DEV exit $rc: not mounting"; exit 1; }
    mount -t ext4 -o noatime "$DEV" "$D" || { logger -t backup "mount $DEV failed"; exit 1; }
fi

# Dirty data reaches the disk within ~2 s (default: up to 30 s): after a
# freeze and a power cut, the log file kept its size but its last 174 lines
# were zeros (2026-10-12).
sysctl -w vm.dirty_writeback_centisecs=100 vm.dirty_expire_centisecs=200 >/dev/null

# Logs onto the disk from here on: a hang no longer takes them along (the
# RAM buffer so far is kept, then syslogd writes the file; read it with
# tail, logread has no buffer any more).
L="$D/system/log"
mkdir -p "$L"; chmod 700 "$D/system" "$L"
if ! pgrep -f "syslogd -O $L" >/dev/null 2>&1; then
    { echo "--- boot $(date -u '+%F %T') (RAM buffer before the disk) ---"; logread; } >> "$L/messages" 2>/dev/null
    killall syslogd 2>/dev/null; sleep 1
    syslogd -O "$L/messages" -s 2048 -b 5
fi

# Chroots: every component root-owned and not group/world-writable
chown root:root "$D"; chmod 755 "$D"
for h in $(cat /etc/ssh/backup_hosts); do
    mkdir -p "$D/vykar-$h/repo"
    chown root:root "$D/vykar-$h"; chmod 755 "$D/vykar-$h"
    chown "vykar-$h:vykar" "$D/vykar-$h/repo"; chmod 700 "$D/vykar-$h/repo"
done

# Clock first: Headscale's TLS needs it
/etc/init.d/ntp

# tailscaled: kernel TUN when built in, else userspace networking
TS="$D/system/tailscale"
if [ -x "$TS/tailscaled" ] && ! pidof tailscaled >/dev/null 2>&1; then
    mkdir -p /var/run/tailscale
    TUN="--tun=userspace-networking"
    [ -c /dev/net/tun ] && TUN="--tun=tailscale0"
    (
        while :; do
            "$TS/tailscaled" $TUN --state="$TS/tailscaled.state" --statedir="$TS" \
                --socket=/var/run/tailscale/tailscaled.sock --port=41641 2>&1 \
                | logger -t tailscaled
            sleep 5
        done
    ) </dev/null >/dev/null 2>&1 &
fi

# Hourly SMART report into every chroot (read over SFTP by the servers)
mkdir -p /var/spool/cron/crontabs
echo "7 * * * * /usr/sbin/disk-health" > /var/spool/cron/crontabs/root
pidof crond >/dev/null 2>&1 || crond -c /var/spool/cron/crontabs
/usr/sbin/disk-health
BACKUPSCRIPT
chmod 755 "$NEWROOT/etc/init.d/backup"

cat > "$NEWROOT/usr/sbin/disk-health" << 'HEALTHSCRIPT'
#!/bin/sh
# SMART report (smartctl -j) of the backup disk, dropped as disk-health in
# every backup chroot: the servers read /disk-health over SFTP.
D=/srv/backup
mountpoint -q "$D" || exit 0
DEV=$(findfs LABEL=backup 2>/dev/null) || exit 1
tmp=$(mktemp) || exit 1
# Non-zero exit bits flag warnings: the JSON says what they are
smartctl -j -i -H -A "$DEV" > "$tmp"
[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }
for h in $(cat /etc/ssh/backup_hosts); do
    c="$D/vykar-$h"
    cp "$tmp" "$c/.disk-health.tmp" && chmod 644 "$c/.disk-health.tmp" && mv -f "$c/.disk-health.tmp" "$c/disk-health"
done
rm -f "$tmp"
HEALTHSCRIPT
chmod 755 "$NEWROOT/usr/sbin/disk-health"
fi

cat > "$NEWROOT/etc/init.d/rcK" << 'STOPSCRIPT'
#!/bin/sh
echo "[shutdown] Stopping services..."
killall wifi-watch sshd tailscaled crond ntpd 2>/dev/null
killall dropbear httpd syslogd klogd wpa_supplicant udhcpc kird 2>/dev/null
echo "[shutdown] Unmounting filesystems..."
umount -a -r 2>/dev/null
sync
echo "[shutdown] System halted."
STOPSCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcK"

cat > "$NEWROOT/etc/network/udhcpc.script" << 'DHCPSCRIPT'
#!/bin/sh
case "$1" in
    deconfig)
        ifconfig "$interface" 0.0.0.0
        ;;
    renew|bound)
        ifconfig "$interface" "$ip" ${subnet:+netmask "$subnet"} ${broadcast:+broadcast "$broadcast"}
        if [ -n "$router" ]; then
            while route del default gw 0.0.0.0 dev "$interface" 2>/dev/null; do :; done
            for i in $router; do route add default gw "$i" dev "$interface"; done
        fi
        if [ -n "$dns" ]; then
            echo -n > /etc/resolv.conf
            for i in $dns; do echo "nameserver $i" >> /etc/resolv.conf; done
        fi
        [ -n "$hostname" ] && hostname "$hostname"
        ;;
esac
DHCPSCRIPT
chmod 755 "$NEWROOT/etc/network/udhcpc.script"

# --- Web UI: live status page + JSON CGI backend ---
info "Writing web UI..."
mkdir -p "$NEWROOT/usr/share/www/cgi-bin"

cat > "$NEWROOT/usr/share/www/cgi-bin/status" << 'STATUSCGI'
#!/bin/ash
# JSON system status for the web UI. Runs as user www via lighttpd mod_cgi.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

up=$(cut -d' ' -f1 /proc/uptime)
load=$(cut -d' ' -f1-3 /proc/loadavg)
mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
ip=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
state=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
speed=$(cat /sys/class/net/eth0/speed 2>/dev/null)
rx=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)
tx=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)
ssh=false; [ -n "$(ps | grep -E '[d]ropbear|[s]shd: ')" ] && ssh=true
procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
disk=null
if mountpoint -q /mnt/usb 2>/dev/null; then
    disk=$(df -k /mnt/usb 2>/dev/null | awk 'NR==2{printf "{\"total\":%s,\"used\":%s}",$2,$3}')
fi

cat << JSON
{"hostname":"$(hostname)","kernel":"$(uname -r)","machine":"$(uname -m)",
"uptime":${up%.*},"load":"${load}","mem_total":${mem_total:-0},"mem_avail":${mem_avail:-0},
"eth0":{"ip":"${ip}","state":"${state:-unknown}","speed":${speed:-0},"rx":${rx:-0},"tx":${tx:-0}},
"ssh":${ssh},"procs":${procs:-0},"disk":${disk:-null}}
JSON
STATUSCGI
chmod 755 "$NEWROOT/usr/share/www/cgi-bin/status"

cat > "$NEWROOT/usr/share/www/index.html" << 'WEBPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AirTies</title>
<style>
:root {
  --bg: #f6f7f9; --surface: #ffffff; --border: #e3e6ea;
  --ink: #1a1f26; --ink-2: #5c6570; --ink-3: #8a939e;
  --accent: #3667d6; --good: #2e7d43; --bad: #b3372e;
  --meter-track: #e9ecef;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14171b; --surface: #1d2126; --border: #2c323a;
    --ink: #e8eaed; --ink-2: #9aa3ad; --ink-3: #6c757f;
    --accent: #7da2f0; --good: #63b578; --bad: #e07a70;
    --meter-track: #2c323a;
  }
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: system-ui, -apple-system, sans-serif;
  background: var(--bg); color: var(--ink);
  min-height: 100vh; padding: 2rem 1.25rem;
  display: flex; flex-direction: column; align-items: center; gap: 1.25rem;
}
header { width: 100%; max-width: 780px; display: flex; align-items: baseline; gap: 0.75rem; flex-wrap: wrap; }
h1 { font-size: 1.5rem; font-weight: 650; letter-spacing: 0.01em; }
#kernel { color: var(--ink-2); font-size: 0.9rem; }
#live { margin-left: auto; font-size: 0.85rem; color: var(--ink-2); display: flex; align-items: center; gap: 0.4rem; }
#live::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--ink-3); }
#live.ok::before { background: var(--good); }
#live.err::before { background: var(--bad); }
.grid {
  width: 100%; max-width: 780px; display: grid; gap: 0.75rem;
  grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
}
.tile {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 10px; padding: 0.9rem 1rem;
  display: flex; flex-direction: column; gap: 0.3rem;
}
.tile h2 {
  font-size: 0.72rem; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--ink-3);
}
.tile .v { font-size: 1.35rem; font-weight: 650; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.tile .v.sm { font-size: 1.05rem; line-height: 1.6; }
.tile .s { font-size: 0.8rem; color: var(--ink-2); font-variant-numeric: tabular-nums; }
.meter { height: 6px; background: var(--meter-track); border-radius: 3px; overflow: hidden; margin-top: 0.35rem; }
.meter > div { height: 100%; width: 0; background: var(--accent); border-radius: 3px; transition: width 0.5s; }
.state-up { color: var(--good); } .state-down { color: var(--bad); }
footer { color: var(--ink-3); font-size: 0.78rem; }
</style>
</head>
<body>
<header>
  <h1 id="host">AirTies</h1>
  <span id="kernel">—</span>
  <span id="live">connecting</span>
</header>
<div class="grid">
  <div class="tile"><h2>Uptime</h2><div class="v" id="uptime">—</div><div class="s" id="procs">—</div></div>
  <div class="tile"><h2>Load 1/5/15</h2><div class="v" id="load1">—</div><div class="s" id="load">—</div></div>
  <div class="tile"><h2>Memory</h2><div class="v" id="mem">—</div><div class="s" id="memd">—</div><div class="meter"><div id="memb"></div></div></div>
  <div class="tile"><h2>Network</h2><div class="v" id="ip">—</div><div class="s" id="link">—</div></div>
  <div class="tile"><h2>Down / Up</h2><div class="v sm" id="rate">—</div><div class="s" id="total">—</div></div>
  <div class="tile"><h2>SSH</h2><div class="v" id="ssh">—</div><div class="s">port 22</div></div>
  <div class="tile" id="disktile" hidden><h2>USB storage</h2><div class="v" id="disk">—</div><div class="s" id="diskd">—</div><div class="meter"><div id="diskb"></div></div></div>
</div>
<footer id="foot"></footer>
<script>
"use strict";
const $ = id => document.getElementById(id);
const kb = v => fmtB(v * 1024);
function fmtB(b) {
  b = Math.max(0, b);
  if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB";
  if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
  if (b >= 1024) return (b / 1024).toFixed(0) + " KB";
  return Math.round(b) + " B";
}
function fmtUp(s) {
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return d > 0 ? d + "d " + h + "h" : h > 0 ? h + "h " + m + "m" : m + "m " + Math.floor(s % 60) + "s";
}
let prev = null, prevT = 0;
async function poll() {
  try {
    const r = await fetch("/cgi-bin/status");
    const j = await r.json();
    const now = Date.now();
    $("host").textContent = j.hostname;
    $("kernel").textContent = "Linux " + j.kernel + " · " + j.machine;
    $("live").textContent = "live"; $("live").className = "ok";
    $("uptime").textContent = fmtUp(j.uptime);
    $("procs").textContent = j.procs + " processes";
    const l = j.load.split(" ");
    $("load1").textContent = l[0];
    $("load").textContent = l.join(" · ");
    const used = j.mem_total - j.mem_avail, pct = j.mem_total ? used / j.mem_total * 100 : 0;
    $("mem").textContent = pct.toFixed(0) + "%";
    $("memd").textContent = kb(used) + " of " + kb(j.mem_total);
    $("memb").style.width = pct + "%";
    $("ip").textContent = j.eth0.ip || "no IP";
    $("link").innerHTML = j.eth0.state === "up"
      ? '<span class="state-up">link up</span> · ' + j.eth0.speed + " Mbps"
      : '<span class="state-down">link ' + j.eth0.state + "</span>";
    if (prev) {
      const dt = (now - prevT) / 1000;
      $("rate").textContent = fmtB((j.eth0.rx - prev.eth0.rx) / dt) + "/s · " + fmtB((j.eth0.tx - prev.eth0.tx) / dt) + "/s";
    }
    $("total").textContent = "total " + fmtB(j.eth0.rx) + " · " + fmtB(j.eth0.tx);
    $("ssh").innerHTML = j.ssh ? '<span class="state-up">running</span>' : '<span class="state-down">stopped</span>';
    if (j.disk) {
      $("disktile").hidden = false;
      const dpct = j.disk.total ? j.disk.used / j.disk.total * 100 : 0;
      $("disk").textContent = dpct.toFixed(0) + "%";
      $("diskd").textContent = kb(j.disk.used) + " of " + kb(j.disk.total);
      $("diskb").style.width = dpct + "%";
    } else { $("disktile").hidden = true; }
    $("foot").textContent = "AirTies AIR 7310T · BCM7231B2 · " + location.protocol.replace(":", "").toUpperCase();
    prev = j; prevT = now;
  } catch (e) {
    $("live").textContent = "offline"; $("live").className = "err";
  }
}
poll(); setInterval(poll, 2000);
</script>
</body>
</html>
WEBPAGE

# --- Summary ---
echo ""
echo "=== rootfs tree ==="
du -sh "$NEWROOT"
file "$NEWROOT/bin/busybox"
info "Rootfs ready in $NEWROOT"
