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

# --- SSH: authorized_keys (key auth) + runtime args for dropbear ---
mkdir -p "$NEWROOT/root/.ssh"; chmod 700 "$NEWROOT/root/.ssh"
if [ -f "$BASEDIR/device/authorized_keys" ]; then
    info "Installing SSH authorized_keys..."
    cp "$BASEDIR/device/authorized_keys" "$NEWROOT/root/.ssh/authorized_keys"
    chmod 600 "$NEWROOT/root/.ssh/authorized_keys"
fi
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

# --- Flash tools: let the box reflash itself over SSH (make flash-rootfs) ---
for t in flash_erase nandwrite; do
    if [ -f "$OUTDIR/$t" ]; then
        info "+ $t"
        cp "$OUTDIR/$t" "$NEWROOT/usr/sbin/$t"; chmod 755 "$NEWROOT/usr/sbin/$t"
    else
        warn "$t not built — on-device reflash (make flash-rootfs) won't work"
    fi
done

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

# root password: blabliblou — hash verified against python crypt.crypt()
# (the previous hash matched no known password and locked the box out)
cat > "$NEWROOT/etc/shadow" << 'EOF'
root:$6$AirTies$6WDkfDDo9bSei7k78mjFRZ/qi1HkKcgxfPr26wFzVBx/lt5pSJ4wbqxhpXyoGSBoHv1JvI9jBdC5ZHuuZ55EA1:0:0:99999:7:::
daemon:x:1:1:daemon:/usr/sbin:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
sshd:x:22:22:sshd:/var/run/sshd:/bin/false
EOF
chmod 640 "$NEWROOT/etc/shadow"

cat > "$NEWROOT/etc/group" << 'EOF'
root:x:0:root
daemon:x:1:
www:x:33:
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
    ifconfig eth0 192.168.2.1 netmask 255.255.255.0 up 2>/dev/null || true
    IP_ADDR=$(ifconfig eth0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
fi

syslogd -C256
klogd

USB_MOUNT=
if [ -e /dev/sda1 ]; then
    mkdir -p /mnt/usb
    mount /dev/sda1 /mnt/usb 2>/dev/null && USB_MOUNT=/mnt/usb
fi

# Host keys: baked into /etc/dropbear at image build; volatile fallback only.
DBKEYDIR="/etc/dropbear"
mkdir -p /var/run
if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ]; then
    DBKEYDIR="/var/lib/dropbear"
    mkdir -p "$DBKEYDIR"
    echo "[init] No baked host keys — generating volatile ones..."
    /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
    /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
fi

if [ -x /usr/sbin/dropbear ]; then
    echo "[init] Starting SSH..."
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

DBKEYDIR="/etc/dropbear"
if [ ! -f "$DBKEYDIR/dropbear_rsa_host_key" ]; then
    DBKEYDIR="/var/lib/dropbear"
    mkdir -p "$DBKEYDIR"
    /usr/sbin/dropbearkey -t rsa -f "$DBKEYDIR/dropbear_rsa_host_key" >/dev/null 2>&1
    /usr/sbin/dropbearkey -t ed25519 -f "$DBKEYDIR/dropbear_ed25519_host_key" >/dev/null 2>&1
fi
if [ -x /usr/sbin/dropbear ]; then
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
ssh=false; [ -n "$(ps | grep '[d]ropbear')" ] && ssh=true
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
