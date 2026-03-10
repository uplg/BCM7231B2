#!/bin/bash
# =============================================================================
# Construire le rootfs minimal pour AirTies AIR 7310T (BCM7231)
#
# Strategie :
# - BusyBox 1.37.0 compile statiquement (musl, MIPS32 R1) via build_busybox.sh
# - ZERO bibliotheques partagees — tout est statique
# - Dropbear SSH compile statiquement
# - Init minimaliste en shell script
# =============================================================================
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
ORIGINAL="$BASEDIR/rootfs_extracted/squashfs-root"
NEWROOT="$BASEDIR/new_rootfs"
BUSYBOX="$BASEDIR/build_output/busybox"
DROPBEAR="$BASEDIR/build_output/dropbearmulti"
INIT_TEST="$BASEDIR/build_output/init_test"
INIT_RAW="$BASEDIR/build_output/init_raw"
OUTPUT="$BASEDIR/new_rootfs.squashfs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[!]${NC} $1"; exit 1; }

# Verifications
[ -d "$ORIGINAL" ] || err "Rootfs original non trouve: $ORIGINAL"
[ -f "$DROPBEAR" ] || err "Dropbear non trouve: $DROPBEAR"
[ -f "$BUSYBOX" ] || err "BusyBox non trouve: $BUSYBOX (run ./build_busybox.sh first)"

# init_test is optional — only included if built
if [ -f "$INIT_TEST" ]; then
    info "init_test found — will include diagnostic init"
fi

# Nettoyage
rm -rf "$NEWROOT"
info "Creation de la structure du rootfs..."

# =============================================================================
# 1. Structure de repertoires
# =============================================================================
mkdir -p "$NEWROOT"/{bin,sbin,usr/{bin,sbin,lib,share/www},lib,etc/{init.d,dropbear,params,network},dev,proc,sys,tmp,var/{run,log,tmp,lib},mnt,media,root,home}

# =============================================================================
# 2. BusyBox (static, musl, MIPS32 R1 — from build_busybox.sh)
# =============================================================================
info "Copie de BusyBox (statique)..."
cp "$BUSYBOX" "$NEWROOT/bin/busybox"
chmod 755 "$NEWROOT/bin/busybox"

# Creer les liens symboliques pour toutes les applets BusyBox
# Use busybox --list if available on host, otherwise hardcode the standard set
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
logger clear basename dirname realpath nice"

cd "$NEWROOT/bin"
for applet in $APPLETS; do
    ln -sf busybox "$applet" 2>/dev/null || true
done

# Liens dans /sbin
cd "$NEWROOT/sbin"
for applet in init halt getty ifconfig ifdown ifup ip klogd modprobe mount \
    pivot_root poweroff reboot route start-stop-daemon swapoff swapon \
    switch_root sysctl syslogd udhcpc umount; do
    ln -sf ../bin/busybox "$applet" 2>/dev/null || true
done

# Liens dans /usr/bin
cd "$NEWROOT/usr/bin"
for applet in awk crontab cut env expr free head hexdump id killall \
    nc nslookup passwd printf sort stat strings tail tee telnet \
    time top traceroute uniq uptime wc wget whoami xargs; do
    ln -sf ../../bin/busybox "$applet" 2>/dev/null || true
done

# Liens dans /usr/sbin
cd "$NEWROOT/usr/sbin"
for applet in crond httpd telnetd udhcpd; do
    ln -sf ../../bin/busybox "$applet" 2>/dev/null || true
done

cd "$BASEDIR"

# =============================================================================
# 3. NO shared libraries needed — everything is statically linked
# =============================================================================
info "Pas de bibliotheques partagees (tout est statique)"

# =============================================================================
# 4. NO kernel modules — kernel 6.18 has everything built-in (CONFIG_MODULES=n)
# =============================================================================
info "Pas de modules kernel (tout built-in dans le kernel 6.18)"

# =============================================================================
# 5. Dropbear SSH
# =============================================================================
info "Installation de Dropbear SSH..."
cp "$DROPBEAR" "$NEWROOT/usr/sbin/dropbearmulti"
chmod 755 "$NEWROOT/usr/sbin/dropbearmulti"

# Liens symboliques pour les sous-commandes
cd "$NEWROOT/usr/sbin"
ln -sf dropbearmulti dropbear
ln -sf dropbearmulti dropbearkey
cd "$NEWROOT/usr/bin"
ln -sf ../sbin/dropbearmulti dbclient
ln -sf ../sbin/dropbearmulti ssh
ln -sf ../sbin/dropbearmulti scp
cd "$BASEDIR"

# =============================================================================
# 5.5. Diagnostic inits — optional
# Prefer init_raw (no libc) over init_test (musl) if both exist.
# Installed as /sbin/init_test so existing kernel bootargs work.
# =============================================================================
if [ -f "$INIT_RAW" ]; then
    info "Installation de init_raw as /sbin/init_test (raw syscall diagnostic)..."
    cp "$INIT_RAW" "$NEWROOT/sbin/init_test"
    chmod 755 "$NEWROOT/sbin/init_test"
elif [ -f "$INIT_TEST" ]; then
    info "Installation de init_test (diagnostic)..."
    cp "$INIT_TEST" "$NEWROOT/sbin/init_test"
    chmod 755 "$NEWROOT/sbin/init_test"
fi

# =============================================================================
# 6. Fichiers de configuration
# =============================================================================
info "Creation des fichiers de configuration..."

# /etc/passwd
cat > "$NEWROOT/etc/passwd" << 'EOF'
root::0:0:root:/root:/bin/ash
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
EOF

# /etc/shadow (root sans password, login via SSH key ou telnet)
cat > "$NEWROOT/etc/shadow" << 'EOF'
root:::0:99999:7:::
daemon:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
sshd:*:0:0:99999:7:::
EOF
chmod 640 "$NEWROOT/etc/shadow"

# /etc/group
cat > "$NEWROOT/etc/group" << 'EOF'
root:x:0:root
daemon:x:1:
nogroup:x:65534:
sshd:x:22:
EOF

# /etc/hostname
echo "frog-hack" > "$NEWROOT/etc/hostname"

# /etc/hosts
cat > "$NEWROOT/etc/hosts" << 'EOF'
127.0.0.1	localhost frog-hack
::1		localhost
EOF

# /etc/resolv.conf
cat > "$NEWROOT/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# /etc/nsswitch.conf
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

# /etc/fstab
cat > "$NEWROOT/etc/fstab" << 'EOF'
# <device>       <mountpoint>  <type>    <options>          <dump> <pass>
proc              /proc         proc      defaults           0      0
sysfs             /sys          sysfs     defaults           0      0
devtmpfs          /dev          devtmpfs  defaults           0      0
tmpfs             /tmp          tmpfs     size=10M           0      0
tmpfs             /var          tmpfs     size=2M            0      0
EOF

# /etc/profile
cat > "$NEWROOT/etc/profile" << 'EOF'
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export TERM="vt102"
export PS1='\u@frog-hack:\w# '
export EDITOR=vi

alias ll='ls -la'
alias la='ls -A'

echo ""
echo "  === FROG-HACK ==="
echo "  AirTies 7310T - Custom Firmware"
echo "  $(uname -r) @ $(hostname)"
echo ""
EOF

# /etc/inittab (BusyBox init)
cat > "$NEWROOT/etc/inittab" << 'EOF'
# BusyBox inittab
#
# Format: <id>:<runlevels>:<action>:<process>

# System init
::sysinit:/etc/init.d/rcS

# Console sur port serie
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt102

# Ctrl-Alt-Del = reboot
::ctrlaltdel:/sbin/reboot

# Shutdown
::shutdown:/etc/init.d/rcK
EOF

# /etc/shells
cat > "$NEWROOT/etc/shells" << 'EOF'
/bin/ash
/bin/sh
EOF

# =============================================================================
# 7. Scripts d'init
# =============================================================================
info "Creation des scripts d'init..."

# Script de demarrage principal
cat > "$NEWROOT/etc/init.d/rcS" << 'INITSCRIPT'
#!/bin/sh
# =============================================================================
# FROG-HACK - Minimal diagnostic init script
# Just mount essential filesystems and get out of the way.
# Getty on ttyS0 (from inittab) provides the interactive shell.
# =============================================================================

echo "[init] Starting FROG-HACK (minimal)..."

# --- Mount essential virtual filesystems ---
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs -o size=10M tmpfs /tmp
mount -t tmpfs -o size=2M tmpfs /var
mkdir -p /var/run /var/log /var/tmp /var/lib

# --- Hostname ---
hostname frog-hack

# --- Loopback ---
ifconfig lo 127.0.0.1 netmask 255.0.0.0 up

echo "[init] Filesystems mounted. Handing off to getty on ttyS0."
echo ""
INITSCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcS"

# Script d'arret
cat > "$NEWROOT/etc/init.d/rcK" << 'STOPSCRIPT'
#!/bin/sh
echo "[shutdown] Stopping services..."
killall dropbear 2>/dev/null
killall telnetd 2>/dev/null
killall httpd 2>/dev/null
killall syslogd 2>/dev/null
killall klogd 2>/dev/null

echo "[shutdown] Unmounting filesystems..."
umount -a -r 2>/dev/null
sync

echo "[shutdown] System halted."
STOPSCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcK"

# Script DHCP pour udhcpc
mkdir -p "$NEWROOT/etc/network"
cat > "$NEWROOT/etc/network/udhcpc.script" << 'DHCPSCRIPT'
#!/bin/sh
# udhcpc script - configure l'interface reseau

case "$1" in
    deconfig)
        ifconfig "$interface" 0.0.0.0
        ;;
    renew|bound)
        ifconfig "$interface" "$ip" \
            ${subnet:+netmask "$subnet"} \
            ${broadcast:+broadcast "$broadcast"}

        # Gateway
        if [ -n "$router" ]; then
            while route del default gw 0.0.0.0 dev "$interface" 2>/dev/null; do
                :
            done
            for i in $router; do
                route add default gw "$i" dev "$interface"
            done
        fi

        # DNS
        if [ -n "$dns" ]; then
            echo -n > /etc/resolv.conf
            for i in $dns; do
                echo "nameserver $i" >> /etc/resolv.conf
            done
        fi

        # Hostname
        if [ -n "$hostname" ]; then
            hostname "$hostname"
        fi
        ;;
esac
DHCPSCRIPT
chmod 755 "$NEWROOT/etc/network/udhcpc.script"

# =============================================================================
# 8. Page web par defaut
# =============================================================================
info "Creation de la page web par defaut..."

cat > "$NEWROOT/usr/share/www/index.html" << 'WEBPAGE'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FROG-HACK</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Courier New', monospace;
            background: #0a0a0a;
            color: #00ff41;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            padding: 2rem;
        }
        h1 { font-size: 2.5rem; margin-bottom: 0.5rem; text-shadow: 0 0 10px #00ff41; }
        .subtitle { color: #888; margin-bottom: 2rem; }
        .card {
            background: #111;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 1.5rem;
            margin: 0.5rem;
            width: 100%;
            max-width: 600px;
        }
        .card h2 { color: #00ff41; margin-bottom: 1rem; font-size: 1.2rem; }
        .info-row { display: flex; justify-content: space-between; padding: 0.3rem 0; border-bottom: 1px solid #222; }
        .label { color: #888; }
        .value { color: #fff; }
        #uptime, #load { color: #00ff41; }
        .status-ok { color: #00ff41; }
        .status-off { color: #ff4141; }
        a { color: #4488ff; }
        .footer { margin-top: 2rem; color: #555; font-size: 0.8rem; }
    </style>
</head>
<body>
    <h1>FROG-HACK</h1>
    <p class="subtitle">AirTies AIR 7310T &bull; BCM7231 &bull; Custom Firmware</p>

    <div class="card">
        <h2>&gt; System Info</h2>
        <div class="info-row"><span class="label">Hostname</span><span class="value" id="hostname">frog-hack</span></div>
        <div class="info-row"><span class="label">Platform</span><span class="value">BCM7231B2 / BMIPS4380 @ 594 MHz</span></div>
        <div class="info-row"><span class="label">Kernel</span><span class="value">Linux 3.3.8-2.3-betty</span></div>
        <div class="info-row"><span class="label">Architecture</span><span class="value">mipsel (MIPS32 LE)</span></div>
    </div>

    <div class="card">
        <h2>&gt; Services</h2>
        <div class="info-row"><span class="label">SSH (22)</span><span class="value status-ok">ACTIVE</span></div>
        <div class="info-row"><span class="label">Telnet (23)</span><span class="value status-ok">ACTIVE</span></div>
        <div class="info-row"><span class="label">HTTP (80)</span><span class="value status-ok">ACTIVE</span></div>
    </div>

    <div class="card">
        <h2>&gt; Quick Access</h2>
        <p style="color: #ccc; line-height: 1.8;">
            SSH: <code>ssh root@<script>document.write(location.hostname)</script></code><br>
            Web: <code>http://<script>document.write(location.hostname)</script>/</code><br>
            Place your apps in: <code>/usr/share/www/</code><br>
            USB mount point: <code>/mnt/usb/</code>
        </p>
    </div>

    <p class="footer">FROG-HACK &bull; github.com/frog-hack &bull; AirTies 7310T reverse engineering project</p>
</body>
</html>
WEBPAGE

# =============================================================================
# 9. Verifications finales
# =============================================================================
info "Verification de la structure..."

echo ""
echo "=== Structure du nouveau rootfs ==="
du -sh "$NEWROOT"
echo ""
find "$NEWROOT" -maxdepth 2 -type d | sort | sed "s|$NEWROOT||" | head -40
echo ""
echo "=== Binaires ==="
ls -lh "$NEWROOT/bin/busybox"
ls -lh "$NEWROOT/usr/sbin/dropbearmulti"
file "$NEWROOT/bin/busybox"
echo ""
echo "=== Taille totale (non compresse) ==="
du -sh "$NEWROOT"

info "Rootfs pret dans $NEWROOT"
info ""
info "Pour creer le SquashFS :"
info "  mksquashfs $NEWROOT $OUTPUT -comp gzip -b 131072 -all-root -noappend"
info ""
info "ATTENTION: le SquashFS DOIT etre < 70 MB (taille partition mtd5)"
