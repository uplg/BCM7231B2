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
[ -f "$DROPBEAR" ] || err "Dropbear not found: $DROPBEAR (run: make dropbear)"

# --- Clean tree ---
rm -rf "$NEWROOT"
info "Building rootfs tree..."
mkdir -p "$NEWROOT"/{bin,sbin,usr/{bin,sbin,lib,share/www},lib,etc/{init.d,dropbear,params,network},dev,proc,sys,tmp,var/{run,log,tmp,lib},mnt/usb,media,root,home}

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
logger clear basename dirname realpath"

cd "$NEWROOT/bin"
for a in $APPLETS; do ln -sf busybox "$a" 2>/dev/null || true; done

cd "$NEWROOT/sbin"
for a in init halt getty ifconfig ifdown ifup ip klogd modprobe mount \
    pivot_root poweroff reboot route start-stop-daemon swapoff swapon \
    switch_root sysctl syslogd udhcpc umount; do
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

# --- Dropbear ---
info "Installing Dropbear SSH..."
cp "$DROPBEAR" "$NEWROOT/usr/sbin/dropbearmulti"
chmod 755 "$NEWROOT/usr/sbin/dropbearmulti"
cd "$NEWROOT/usr/sbin"; ln -sf dropbearmulti dropbear; ln -sf dropbearmulti dropbearkey
cd "$NEWROOT/usr/bin"; ln -sf ../sbin/dropbearmulti dbclient; ln -sf ../sbin/dropbearmulti ssh; ln -sf ../sbin/dropbearmulti scp
cd "$BASEDIR"

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
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
EOF

cat > "$NEWROOT/etc/shadow" << 'EOF'
root:$6$AirTies$h0z5DNs9Bz698W.NvMHAtEP/FFoVxkd9vNriq9NatHS5XpYV.0LhxhnsdbD2Krl5Qqo8R7nZAsK5BiSktpfbi0:0:0:99999:7:::
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
EOF
chmod 640 "$NEWROOT/etc/shadow"

cat > "$NEWROOT/etc/group" << 'EOF'
root:x:0:root
daemon:x:1:
nogroup:x:65534:
sshd:x:22:
EOF

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
echo "  AirTies"
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

hostname AirTies
ifconfig lo 127.0.0.1 netmask 255.0.0.0 up

ifconfig eth0 up 2>/dev/null || true
if command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i eth0 -s /etc/network/udhcpc.script -n -q >/dev/null 2>&1 || true
fi

IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
    ifconfig eth0 192.168.1.10 netmask 255.255.255.0 up 2>/dev/null || true
    IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
fi

syslogd -C256
klogd

USB_MOUNT=
if [ -e /dev/sda1 ]; then
    mkdir -p /mnt/usb
    mount /dev/sda1 /mnt/usb 2>/dev/null && USB_MOUNT=/mnt/usb
fi

DBKEYDIR="/var/lib/dropbear"
mkdir -p /var/run "$DBKEYDIR"

if [ -n "$USB_MOUNT" ] && [ -d "$USB_MOUNT/AirTies/dropbear" ]; then
    cp "$USB_MOUNT"/AirTies/dropbear/dropbear_*_host_key "$DBKEYDIR"/ 2>/dev/null || true
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
    mkdir -p "$USB_MOUNT/AirTies/dropbear"
    cp "$DBKEYDIR"/dropbear_*_host_key "$USB_MOUNT"/AirTies/dropbear/ 2>/dev/null || true
fi

if [ -x /usr/sbin/dropbear ]; then
    echo "[init] Starting SSH..."
    /usr/sbin/dropbear -r "$DBKEYDIR/dropbear_rsa_host_key" -r "$DBKEYDIR/dropbear_ed25519_host_key"
fi
if [ -x /usr/sbin/httpd ]; then
    echo "[init] Starting HTTP..."
    /usr/sbin/httpd -p 80 -h /usr/share/www
fi

echo ""
echo "============================================"
echo "  AirTies ready"
echo "  IP: ${IP_ADDR:-192.168.1.10}"
echo "  SSH:  port 22"
echo "  HTTP: port 80"
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

DBKEYDIR="/var/lib/dropbear"
mkdir -p "$DBKEYDIR"

if [ -n "$USB_MOUNT" ] && [ -d "$USB_MOUNT/AirTies/dropbear" ]; then
    cp "$USB_MOUNT"/AirTies/dropbear/dropbear_*_host_key "$DBKEYDIR"/ 2>/dev/null || true
fi
if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ] && [ -x /usr/sbin/dropbearkey ]; then
    /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
fi
if [ ! -f "$DBKEYDIR/dropbear_ed25519_host_key" ] && [ -x /usr/sbin/dropbearkey ]; then
    /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
fi
if [ -n "$USB_MOUNT" ]; then
    mkdir -p "$USB_MOUNT/AirTies/dropbear"
    cp "$DBKEYDIR"/dropbear_*_host_key "$USB_MOUNT"/AirTies/dropbear/ 2>/dev/null || true
fi
if [ -x /usr/sbin/dropbear ]; then
    /usr/sbin/dropbear -r "$DBKEYDIR/dropbear_rsa_host_key" -r "$DBKEYDIR/dropbear_ed25519_host_key"
fi
if [ -x /usr/sbin/httpd ]; then
    /usr/sbin/httpd -p 80 -h /usr/share/www
fi
SERVICESCRIPT
chmod 755 "$NEWROOT/etc/init.d/rcServices"

cat > "$NEWROOT/etc/init.d/rcK" << 'STOPSCRIPT'
#!/bin/sh
echo "[shutdown] Stopping services..."
killall dropbear httpd syslogd klogd 2>/dev/null
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

# --- Default web page ---
info "Writing default web page..."
cat > "$NEWROOT/usr/share/www/index.html" << 'WEBPAGE'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AirTies</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Georgia, "Times New Roman", serif;
            background: radial-gradient(circle at top, rgba(193,154,107,0.18), transparent 35%),
                        linear-gradient(180deg, #f4efe6 0%, #e6dccd 100%);
            color: #2f2419; min-height: 100vh; display: flex; flex-direction: column;
            align-items: center; padding: 2rem 1.25rem 3rem; }
        .hero { width: 100%; max-width: 860px; text-align: center; margin-bottom: 1.5rem; }
        h1 { font-size: clamp(2.5rem, 8vw, 4.5rem); letter-spacing: 0.08em; margin-bottom: 0.35rem; }
        .subtitle { color: #6b5642; font-size: 1rem; margin-bottom: 1.25rem; }
        .pillbar { display: flex; flex-wrap: wrap; gap: 0.75rem; justify-content: center; }
        .pill { border: 1px solid rgba(47,36,25,0.15); background: rgba(255,255,255,0.65);
            border-radius: 999px; padding: 0.5rem 0.9rem; font-size: 0.92rem; }
        .grid { width: 100%; max-width: 860px; display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 1rem; }
        .card { background: rgba(255,252,247,0.88); border: 1px solid rgba(47,36,25,0.12);
            border-radius: 18px; padding: 1.25rem; box-shadow: 0 12px 30px rgba(70,52,31,0.08);
            backdrop-filter: blur(6px); }
        .card h2 { margin-bottom: 0.9rem; font-size: 1.05rem; letter-spacing: 0.04em;
            text-transform: uppercase; color: #7a5a32; }
        .info-row { display: flex; justify-content: space-between; gap: 1rem;
            padding: 0.45rem 0; border-bottom: 1px solid rgba(47,36,25,0.08); }
        .info-row:last-child { border-bottom: none; }
        .label { color: #7a6857; }
        .value { color: #20170f; text-align: right; }
        .status-ok { color: #2f6b3d; font-weight: 700; }
        code { font-family: "Courier New", monospace; background: rgba(47,36,25,0.06);
            padding: 0.12rem 0.35rem; border-radius: 6px; }
        .footer { margin-top: 1.5rem; color: #7a6857; font-size: 0.85rem; text-align: center; }
    </style>
</head>
<body>
    <section class="hero">
        <h1>AirTies</h1>
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
            <div class="info-row"><span class="label">Hostname</span><span class="value">AirTies</span></div>
            <div class="info-row"><span class="label">SoC</span><span class="value">BCM7231B2 / BMIPS4380</span></div>
            <div class="info-row"><span class="label">Kernel</span><span class="value">Linux 6.18.x custom</span></div>
            <div class="info-row"><span class="label">Architecture</span><span class="value">mipsel (MIPS32 R1)</span></div>
        </div>
        <div class="card">
            <h2>Services</h2>
            <div class="info-row"><span class="label">SSH</span><span class="value status-ok">port 22 active</span></div>
            <div class="info-row"><span class="label">HTTP</span><span class="value status-ok">port 80 active</span></div>
            <div class="info-row"><span class="label">Telnet</span><span class="value">disabled</span></div>
            <div class="info-row"><span class="label">IP</span><span class="value" id="device-ip">DHCP (fallback 192.168.1.10)</span></div>
        </div>
        <div class="card">
            <h2>Quick Access</h2>
            <div class="info-row"><span class="label">SSH</span><span class="value"><code id="ssh-target">ssh root@device-ip</code></span></div>
            <div class="info-row"><span class="label">Web</span><span class="value"><code id="web-target">http://device-ip/</code></span></div>
            <div class="info-row"><span class="label">Fallback</span><span class="value"><code>192.168.1.10</code></span></div>
            <div class="info-row"><span class="label">Web root</span><span class="value"><code>/usr/share/www</code></span></div>
            <div class="info-row"><span class="label">USB mount</span><span class="value"><code>/mnt/usb</code></span></div>
        </div>
    </section>
    <p class="footer">AirTies &bull; AirTies AIR 7310T</p>
    <script>
        (function() {
            var host = window.location.hostname || "device-ip";
            var origin = window.location.origin || ("http://" + host + "/");
            document.getElementById("device-ip").textContent = host + " (DHCP, fallback 192.168.1.10)";
            document.getElementById("ssh-target").textContent = "ssh root@" + host;
            document.getElementById("web-target").textContent = origin.replace(/\/$/, "") + "/";
        })();
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
