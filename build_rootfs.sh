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
IRQ_DUMP="$BASEDIR/build_output/irq_dump"
EPHY_INIT="$BASEDIR/build_output/ephy_init"
EPHY_DIAG="$BASEDIR/build_output/ephy_diag"
GENET_DUMP="$BASEDIR/build_output/genet_dump"
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
# 5.5. Optional diagnostic tools
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

# irq_dump — L1/L2 interrupt controller register dump tool
if [ -f "$IRQ_DUMP" ]; then
    info "Installation de irq_dump (IRQ diagnostic)..."
    cp "$IRQ_DUMP" "$NEWROOT/sbin/irq_dump"
    chmod 755 "$NEWROOT/sbin/irq_dump"
fi

# ephy/genet diagnostics — optional manual tools
if [ -f "$EPHY_INIT" ]; then
    info "Installation de ephy_init (GENET/EPHY power-up)..."
    cp "$EPHY_INIT" "$NEWROOT/sbin/ephy_init"
    chmod 755 "$NEWROOT/sbin/ephy_init"
fi

if [ -f "$EPHY_DIAG" ]; then
    info "Installation de ephy_diag (EPHY diagnostic)..."
    cp "$EPHY_DIAG" "$NEWROOT/sbin/ephy_diag"
    chmod 755 "$NEWROOT/sbin/ephy_diag"
fi

if [ -f "$GENET_DUMP" ]; then
    info "Installation de genet_dump (GENET snapshot)..."
    cp "$GENET_DUMP" "$NEWROOT/sbin/genet_dump"
    chmod 755 "$NEWROOT/sbin/genet_dump"
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
echo "  FROG-HACK"
echo "  AirTies AIR 7310T"
echo "  $(uname -r) on $(hostname)"
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
# FROG-HACK - Service init script
# Mount essential filesystems, bring up networking, start core services, then
# hand off to getty.
# Getty on ttyS0 (from inittab) provides the interactive shell.
# =============================================================================

echo "[init] Starting FROG-HACK..."

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

# --- Ethernet ---
ifconfig eth0 up 2>/dev/null || true
ifconfig eth0 192.168.2.1 netmask 255.255.255.0 up 2>/dev/null || true

# --- Logging ---
syslogd -C256
klogd

# --- Optional persistent storage ---
USB_MOUNT=
if [ -e /dev/sda1 ]; then
    mkdir -p /mnt/usb
    if mount /dev/sda1 /mnt/usb 2>/dev/null; then
        USB_MOUNT=/mnt/usb
    fi
fi

# --- SSH host keys ---
DBKEYDIR="/var/lib/dropbear"
mkdir -p /var/run "$DBKEYDIR"

if [ -n "$USB_MOUNT" ] && [ -d "$USB_MOUNT/frog-hack/dropbear" ]; then
    cp "$USB_MOUNT"/frog-hack/dropbear/dropbear_*_host_key "$DBKEYDIR"/ 2>/dev/null || true
fi

if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ] && [ -x /usr/sbin/dropbearkey ]; then
    echo "[init] Generating Dropbear RSA host key..."
    /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
fi

if [ ! -f "$DBKEYDIR/dropbear_ed25519_host_key" ] && [ -x /usr/sbin/dropbearkey ]; then
    echo "[init] Generating Dropbear Ed25519 host key..."
    /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
fi

if [ -n "$USB_MOUNT" ]; then
    mkdir -p "$USB_MOUNT/frog-hack/dropbear"
    cp "$DBKEYDIR"/dropbear_*_host_key "$USB_MOUNT"/frog-hack/dropbear/ 2>/dev/null || true
fi

if [ -x /usr/sbin/dropbear ]; then
    echo "[init] Starting SSH..."
    /usr/sbin/dropbear -r "$DBKEYDIR/dropbear_rsa_host_key" -r "$DBKEYDIR/dropbear_ed25519_host_key"
fi

if [ -x /usr/sbin/httpd ]; then
    echo "[init] Starting HTTP..."
    /usr/sbin/httpd -p 80 -h /usr/share/www
fi

IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')

echo ""
echo "============================================"
echo "  FROG-HACK ready"
echo "  IP: ${IP_ADDR:-192.168.2.1}"
echo "  SSH:  port 22"
echo "  HTTP: port 80"
echo "============================================"
echo ""
INITSCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcS"

# Script d'arret
cat > "$NEWROOT/etc/init.d/rcK" << 'STOPSCRIPT'
#!/bin/sh
echo "[shutdown] Stopping services..."
killall dropbear 2>/dev/null
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
            font-family: Georgia, "Times New Roman", serif;
            background:
                radial-gradient(circle at top, rgba(193, 154, 107, 0.18), transparent 35%),
                linear-gradient(180deg, #f4efe6 0%, #e6dccd 100%);
            color: #2f2419;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            padding: 2rem 1.25rem 3rem;
        }
        .hero {
            width: 100%;
            max-width: 860px;
            text-align: center;
            margin-bottom: 1.5rem;
        }
        h1 {
            font-size: clamp(2.5rem, 8vw, 4.5rem);
            letter-spacing: 0.08em;
            margin-bottom: 0.35rem;
        }
        .subtitle {
            color: #6b5642;
            font-size: 1rem;
            margin-bottom: 1.25rem;
        }
        .pillbar {
            display: flex;
            flex-wrap: wrap;
            gap: 0.75rem;
            justify-content: center;
        }
        .pill {
            border: 1px solid rgba(47, 36, 25, 0.15);
            background: rgba(255, 255, 255, 0.65);
            border-radius: 999px;
            padding: 0.5rem 0.9rem;
            font-size: 0.92rem;
        }
        .grid {
            width: 100%;
            max-width: 860px;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 1rem;
        }
        .card {
            background: rgba(255, 252, 247, 0.88);
            border: 1px solid rgba(47, 36, 25, 0.12);
            border-radius: 18px;
            padding: 1.25rem;
            box-shadow: 0 12px 30px rgba(70, 52, 31, 0.08);
            backdrop-filter: blur(6px);
        }
        .card h2 {
            margin-bottom: 0.9rem;
            font-size: 1.05rem;
            letter-spacing: 0.04em;
            text-transform: uppercase;
            color: #7a5a32;
        }
        .info-row {
            display: flex;
            justify-content: space-between;
            gap: 1rem;
            padding: 0.45rem 0;
            border-bottom: 1px solid rgba(47, 36, 25, 0.08);
        }
        .info-row:last-child { border-bottom: none; }
        .label { color: #7a6857; }
        .value { color: #20170f; text-align: right; }
        .status-ok { color: #2f6b3d; font-weight: 700; }
        code {
            font-family: "Courier New", monospace;
            background: rgba(47, 36, 25, 0.06);
            padding: 0.12rem 0.35rem;
            border-radius: 6px;
        }
        .footer {
            margin-top: 1.5rem;
            color: #7a6857;
            font-size: 0.85rem;
            text-align: center;
        }
    </style>
</head>
<body>
    <section class="hero">
        <h1>FROG-HACK</h1>
        <p class="subtitle">AirTies AIR 7310T &bull; BCM7231 &bull; Custom Linux bring-up</p>
        <div class="pillbar">
            <div class="pill">Ethernet 10/100 operational</div>
            <div class="pill">SSH enabled</div>
            <div class="pill">BusyBox + Dropbear</div>
        </div>
    </section>

    <section class="grid">
        <div class="card">
            <h2>System</h2>
            <div class="info-row"><span class="label">Hostname</span><span class="value">frog-hack</span></div>
            <div class="info-row"><span class="label">SoC</span><span class="value">BCM7231B2 / BMIPS4380</span></div>
            <div class="info-row"><span class="label">Kernel</span><span class="value">Linux 6.18.x custom</span></div>
            <div class="info-row"><span class="label">Architecture</span><span class="value">mipsel (MIPS32 R1)</span></div>
        </div>

        <div class="card">
            <h2>Services</h2>
            <div class="info-row"><span class="label">SSH</span><span class="value status-ok">port 22 active</span></div>
            <div class="info-row"><span class="label">HTTP</span><span class="value status-ok">port 80 active</span></div>
            <div class="info-row"><span class="label">Telnet</span><span class="value">disabled</span></div>
            <div class="info-row"><span class="label">Default IP</span><span class="value">192.168.2.1</span></div>
        </div>

        <div class="card">
            <h2>Quick Access</h2>
            <div class="info-row"><span class="label">SSH</span><span class="value"><code>ssh root@192.168.2.1</code></span></div>
            <div class="info-row"><span class="label">Web</span><span class="value"><code>http://192.168.2.1/</code></span></div>
            <div class="info-row"><span class="label">Web root</span><span class="value"><code>/usr/share/www</code></span></div>
            <div class="info-row"><span class="label">USB mount</span><span class="value"><code>/mnt/usb</code></span></div>
        </div>
    </section>

    <p class="footer">FROG-HACK &bull; AirTies AIR 7310T reverse engineering project</p>
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
