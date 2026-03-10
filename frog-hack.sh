#!/bin/bash
# =============================================================================
# AirTies AIR 7310T - Script d'assistance au reverse engineering
# =============================================================================

set -e

SERIAL_PORT="/dev/cu.usbserial-A6038OZX"
BAUD_RATE="115200"
BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
TFTP_DIR="./tftp_root"
FIRMWARE_DIR="./firmware_analysis"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }

# =============================================================================
# Verification des prerequis
# =============================================================================
check_deps() {
    info "Verification des outils necessaires..."
    local missing=()

    for tool in picocom binwalk strings python3 nc nmap; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Outils manquants : ${missing[*]}"
        echo ""
        echo "Installation recommandee :"
        echo "  brew install picocom binwalk nmap"
        echo "  pip install ubi_reader"
        echo ""
    else
        ok "Tous les outils de base sont installes"
    fi
}

# =============================================================================
# Connexion serie avec log
# =============================================================================
serial_connect() {
    local logfile="./logs/uart_$(date +%Y%m%d_%H%M%S).log"
    mkdir -p ./logs

    if [ ! -e "$SERIAL_PORT" ]; then
        err "Port serie $SERIAL_PORT non trouve !"
        echo "Ports disponibles :"
        ls /dev/cu.usb* 2>/dev/null || echo "  Aucun port USB-serial detecte"
        exit 1
    fi

    info "Connexion a $SERIAL_PORT @ ${BAUD_RATE} baud"
    info "Log sauvegarde dans : $logfile"
    echo "---"
    echo "Conseils :"
    echo "  - Debrancher/rebrancher l'alimentation du boitier pour voir le boot"
    echo "  - Spammer Espace/Entree/Ctrl+C pendant le boot pour interrompre"
    echo "  - Ctrl+A Ctrl+X pour quitter picocom"
    echo "---"

    picocom -b "$BAUD_RATE" --logfile "$logfile" "$SERIAL_PORT"
}

# =============================================================================
# Brute force des passwords par defaut
# =============================================================================
bruteforce_passwords() {
    info "Tentative des passwords par defaut via port serie..."
    info "Assurez-vous que le boitier affiche un prompt de login"

    local users=("root" "admin")
    local passwords=("root" "airties" "air7310" "broadcom" "" "admin" "1234" "default" "password" "AirTies" "7310")

    mkdir -p ./logs
    local logfile="./logs/bruteforce_$(date +%Y%m%d_%H%M%S).log"

    if [ ! -e "$SERIAL_PORT" ]; then
        err "Port serie $SERIAL_PORT non trouve !"
        exit 1
    fi

    # On utilise un fichier expect-like avec shell pur
    for user in "${users[@]}"; do
        for pass in "${passwords[@]}"; do
            echo "Essai: $user / '$pass'" | tee -a "$logfile"

            # Envoyer login + password via le port serie
            {
                sleep 1
                echo ""          # Reveil
                sleep 0.5
                echo "$user"     # Login
                sleep 1
                echo "$pass"     # Password
                sleep 2
            } > "$SERIAL_PORT" < "$SERIAL_PORT" 2>/dev/null &

            local pid=$!
            sleep 4
            kill $pid 2>/dev/null || true

            # Lire la reponse
            timeout 1 cat "$SERIAL_PORT" 2>/dev/null | tee -a "$logfile" || true
            echo "---" >> "$logfile"
        done
    done

    info "Resultats sauvegardes dans $logfile"
    warn "Verifiez manuellement les resultats - le brute force serie est peu fiable"
    warn "Methode recommandee : essayer manuellement via picocom"
}

# =============================================================================
# Analyse d'un dump firmware
# =============================================================================
analyze_firmware() {
    local firmware_file="$1"

    if [ -z "$firmware_file" ]; then
        echo "Usage: $0 analyze <fichier_firmware>"
        exit 1
    fi

    if [ ! -f "$firmware_file" ]; then
        err "Fichier non trouve : $firmware_file"
        exit 1
    fi

    mkdir -p "$FIRMWARE_DIR"
    info "Analyse du firmware : $firmware_file"

    # Infos de base
    echo ""
    echo "=== Informations generales ==="
    ls -lh "$firmware_file"
    md5sum "$firmware_file" 2>/dev/null || md5 "$firmware_file"
    file "$firmware_file"

    # Binwalk scan
    echo ""
    echo "=== Scan binwalk ==="
    binwalk "$firmware_file" | tee "$FIRMWARE_DIR/binwalk_scan.txt"

    # Entropie
    echo ""
    echo "=== Analyse d'entropie ==="
    binwalk -E "$firmware_file" 2>/dev/null && ok "Graphe d'entropie genere" || warn "Entropie non disponible"

    # Strings interessantes
    echo ""
    echo "=== Strings interessantes ==="
    echo "--- Passwords potentiels ---"
    strings "$firmware_file" | grep -iE "passw|login|root|admin|secret|key|token" | sort -u | head -50 | tee "$FIRMWARE_DIR/strings_passwords.txt"

    echo ""
    echo "--- URLs ---"
    strings "$firmware_file" | grep -iE "https?://" | sort -u | head -30 | tee "$FIRMWARE_DIR/strings_urls.txt"

    echo ""
    echo "--- Boot commands ---"
    strings "$firmware_file" | grep -iE "bootargs|cmdline|console=|root=|init=" | sort -u | tee "$FIRMWARE_DIR/strings_boot.txt"

    # Extraction
    echo ""
    info "Extraction des composants..."
    mkdir -p "$FIRMWARE_DIR/extracted"
    binwalk -e -C "$FIRMWARE_DIR/extracted" "$firmware_file" || warn "Extraction partielle"

    ok "Analyse terminee. Resultats dans $FIRMWARE_DIR/"
}

# =============================================================================
# Extraire et modifier un rootfs SquashFS
# =============================================================================
modify_squashfs() {
    local squashfs_file="$1"

    if [ -z "$squashfs_file" ]; then
        echo "Usage: $0 modify-rootfs <fichier_squashfs>"
        exit 1
    fi

    info "Extraction du SquashFS : $squashfs_file"

    local extract_dir="$FIRMWARE_DIR/rootfs_extracted"
    mkdir -p "$extract_dir"

    # Tenter unsquashfs standard puis sasquatch pour les variants Broadcom
    if command -v unsquashfs &>/dev/null; then
        unsquashfs -d "$extract_dir" "$squashfs_file" 2>/dev/null && ok "Extraction unsquashfs reussie" || {
            warn "unsquashfs standard a echoue, essai avec sasquatch..."
            if command -v sasquatch &>/dev/null; then
                sasquatch -p 1 -le "$squashfs_file" -d "$extract_dir" || err "Echec sasquatch aussi"
            else
                err "Installer sasquatch pour les SquashFS Broadcom non-standard"
                echo "  brew install sasquatch (ou compiler depuis https://github.com/devttys0/sasquatch)"
            fi
        }
    fi

    if [ -d "$extract_dir/squashfs-root" ]; then
        extract_dir="$extract_dir/squashfs-root"
    fi

    if [ ! -d "$extract_dir" ] || [ -z "$(ls -A "$extract_dir" 2>/dev/null)" ]; then
        err "Extraction echouee ou repertoire vide"
        exit 1
    fi

    ok "Rootfs extrait dans : $extract_dir"
    echo ""
    echo "=== Structure du rootfs ==="
    ls -la "$extract_dir/"
    echo ""

    # Afficher les infos de login
    echo "=== /etc/passwd ==="
    cat "$extract_dir/etc/passwd" 2>/dev/null || warn "pas de /etc/passwd"
    echo ""

    echo "=== /etc/shadow ==="
    cat "$extract_dir/etc/shadow" 2>/dev/null || warn "pas de /etc/shadow"
    echo ""

    echo "=== /etc/inittab ==="
    cat "$extract_dir/etc/inittab" 2>/dev/null || warn "pas de /etc/inittab"
    echo ""

    info "Pour modifier le rootfs :"
    echo "  1. Modifier les fichiers dans $extract_dir"
    echo "  2. Vider le password root :"
    echo "     sed -i '' 's|^root:[^:]*:|root::|' $extract_dir/etc/shadow"
    echo "  3. Re-creer le SquashFS :"
    echo "     mksquashfs $extract_dir rootfs_modified.squashfs -comp xz -b 131072"
    echo "  4. Flasher le nouveau rootfs via le bootloader"
}

# =============================================================================
# Preparer un serveur TFTP pour le transfert de fichiers
# =============================================================================
setup_tftp() {
    mkdir -p "$TFTP_DIR"
    info "Demarrage du serveur TFTP dans $TFTP_DIR"
    echo "Placez vos fichiers dans $TFTP_DIR pour les rendre disponibles"
    echo ""

    # Detecter l'IP locale
    local_ip=$(ipconfig getifaddr en0 2>/dev/null || ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    info "Votre IP locale : $local_ip"
    echo ""

    if command -v python3 &>/dev/null; then
        info "Demarrage du serveur TFTP via Python..."
        echo "Le boitier pourra telecharger depuis : tftp $local_ip"
        python3 -c "
import socket, struct, os, sys

TFTP_DIR = '$TFTP_DIR'
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('0.0.0.0', 69))
print(f'Serveur TFTP actif sur le port 69 (repertoire: {TFTP_DIR})')
print('En attente de connexions... (Ctrl+C pour arreter)')

while True:
    data, addr = sock.recvfrom(516)
    opcode = struct.unpack('!H', data[:2])[0]
    if opcode == 1:  # RRQ
        filename = data[2:].split(b'\x00')[0].decode()
        filepath = os.path.join(TFTP_DIR, filename)
        print(f'RRQ: {filename} depuis {addr}')
        if os.path.exists(filepath):
            with open(filepath, 'rb') as f:
                block = 1
                while True:
                    chunk = f.read(512)
                    packet = struct.pack('!HH', 3, block) + chunk
                    sock.sendto(packet, addr)
                    block += 1
                    if len(chunk) < 512:
                        break
            print(f'  -> Envoye: {filename}')
        else:
            error = struct.pack('!HH', 5, 1) + b'File not found\x00'
            sock.sendto(error, addr)
            print(f'  -> ERREUR: fichier non trouve')
    elif opcode == 2:  # WRQ
        filename = data[2:].split(b'\x00')[0].decode()
        filepath = os.path.join(TFTP_DIR, filename)
        print(f'WRQ: {filename} depuis {addr}')
        ack = struct.pack('!HH', 4, 0)
        sock.sendto(ack, addr)
        with open(filepath, 'wb') as f:
            while True:
                data, addr = sock.recvfrom(516)
                block = struct.unpack('!HH', data[:4])
                f.write(data[4:])
                ack = struct.pack('!HH', 4, block[1])
                sock.sendto(ack, addr)
                if len(data[4:]) < 512:
                    break
        print(f'  -> Recu: {filename}')
" 2>/dev/null || {
            warn "Le serveur TFTP necessite les droits root pour le port 69"
            echo "Relancer avec : sudo $0 tftp"
            echo ""
            echo "Alternative : utiliser un port non-privilegie"
            echo "  python3 -m http.server 8080 --directory $TFTP_DIR"
        }
    else
        err "Python3 non trouve"
        echo "Alternatives :"
        echo "  brew install tftp-hpa"
        echo "  sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist"
    fi
}

# =============================================================================
# Scan reseau du boitier
# =============================================================================
scan_network() {
    local target_ip="$1"

    if [ -z "$target_ip" ]; then
        info "Scan du reseau local pour trouver le boitier..."
        # Detecter le subnet
        local_ip=$(ipconfig getifaddr en0 2>/dev/null)
        if [ -z "$local_ip" ]; then
            err "Impossible de detecter l'IP locale"
            exit 1
        fi
        subnet=$(echo "$local_ip" | sed 's/\.[0-9]*$/.0\/24/')
        info "Scan du subnet : $subnet"

        if command -v nmap &>/dev/null; then
            nmap -sn "$subnet" | grep -B2 -iE "airties\|broadcom\|unknown"
        else
            # Fallback : ping sweep
            info "nmap non disponible, utilisation de ping sweep..."
            prefix=$(echo "$local_ip" | sed 's/\.[0-9]*$//')
            for i in $(seq 1 254); do
                ping -c 1 -W 1 "${prefix}.${i}" &>/dev/null && echo "Actif: ${prefix}.${i}" &
            done
            wait
        fi
    else
        info "Scan des ports de $target_ip..."
        if command -v nmap &>/dev/null; then
            nmap -sV -p- "$target_ip"
        else
            # Fallback : scan basique
            for port in 22 23 80 443 8080 8443 8888 9090 5000 554 1935; do
                (echo >/dev/tcp/"$target_ip"/"$port") 2>/dev/null && echo "Port $port : OUVERT"
            done
        fi
    fi
}

# =============================================================================
# Generer un script de collecte d'infos a executer sur le boitier
# =============================================================================
generate_recon_script() {
    local script_file="./recon_on_target.sh"

    cat > "$script_file" << 'RECON'
#!/bin/sh
# =============================================================================
# Script de reconnaissance - a executer sur le boitier AirTies
# Copier sur USB et executer : sh /mnt/usb/recon_on_target.sh
# =============================================================================

OUTDIR="/tmp/recon_$(date +%s)"
mkdir -p "$OUTDIR"

echo "=== Collecte d'informations systeme ==="
echo "Resultats dans : $OUTDIR"

# Systeme
echo "--- uname ---" > "$OUTDIR/system.txt"
uname -a >> "$OUTDIR/system.txt" 2>&1
echo "--- /proc/cpuinfo ---" >> "$OUTDIR/system.txt"
cat /proc/cpuinfo >> "$OUTDIR/system.txt" 2>&1
echo "--- /proc/meminfo ---" >> "$OUTDIR/system.txt"
cat /proc/meminfo >> "$OUTDIR/system.txt" 2>&1
echo "--- /proc/version ---" >> "$OUTDIR/system.txt"
cat /proc/version >> "$OUTDIR/system.txt" 2>&1
echo "--- /proc/cmdline ---" >> "$OUTDIR/system.txt"
cat /proc/cmdline >> "$OUTDIR/system.txt" 2>&1
echo "--- uptime ---" >> "$OUTDIR/system.txt"
uptime >> "$OUTDIR/system.txt" 2>&1

# Stockage
echo "--- /proc/mtd ---" > "$OUTDIR/storage.txt"
cat /proc/mtd >> "$OUTDIR/storage.txt" 2>&1
echo "--- df ---" >> "$OUTDIR/storage.txt"
df -h >> "$OUTDIR/storage.txt" 2>&1
echo "--- mount ---" >> "$OUTDIR/storage.txt"
mount >> "$OUTDIR/storage.txt" 2>&1
echo "--- /proc/partitions ---" >> "$OUTDIR/storage.txt"
cat /proc/partitions >> "$OUTDIR/storage.txt" 2>&1

# Reseau
echo "--- ifconfig ---" > "$OUTDIR/network.txt"
ifconfig -a >> "$OUTDIR/network.txt" 2>&1
echo "--- route ---" >> "$OUTDIR/network.txt"
route -n >> "$OUTDIR/network.txt" 2>&1
echo "--- netstat ---" >> "$OUTDIR/network.txt"
netstat -tlnp >> "$OUTDIR/network.txt" 2>&1
echo "--- resolv.conf ---" >> "$OUTDIR/network.txt"
cat /etc/resolv.conf >> "$OUTDIR/network.txt" 2>&1

# Processus
echo "--- ps ---" > "$OUTDIR/processes.txt"
ps aux >> "$OUTDIR/processes.txt" 2>&1 || ps w >> "$OUTDIR/processes.txt" 2>&1

# Config
cp /etc/passwd "$OUTDIR/" 2>/dev/null
cp /etc/shadow "$OUTDIR/" 2>/dev/null
cp /etc/inittab "$OUTDIR/" 2>/dev/null
cp /etc/fstab "$OUTDIR/" 2>/dev/null

# Init scripts
echo "--- /etc/init.d/ ---" > "$OUTDIR/init_scripts.txt"
ls -la /etc/init.d/ >> "$OUTDIR/init_scripts.txt" 2>&1
for f in /etc/init.d/*; do
    echo "=== $f ===" >> "$OUTDIR/init_scripts_content.txt"
    cat "$f" >> "$OUTDIR/init_scripts_content.txt" 2>&1
    echo "" >> "$OUTDIR/init_scripts_content.txt"
done

# Binaires disponibles
echo "--- Binaires ---" > "$OUTDIR/binaries.txt"
ls /bin/ /sbin/ /usr/bin/ /usr/sbin/ >> "$OUTDIR/binaries.txt" 2>&1
echo "--- busybox ---" >> "$OUTDIR/binaries.txt"
busybox 2>&1 | head -5 >> "$OUTDIR/binaries.txt"
busybox --list >> "$OUTDIR/binaries.txt" 2>&1

# Kernel modules
echo "--- lsmod ---" > "$OUTDIR/modules.txt"
lsmod >> "$OUTDIR/modules.txt" 2>&1
echo "--- /proc/modules ---" >> "$OUTDIR/modules.txt"
cat /proc/modules >> "$OUTDIR/modules.txt" 2>&1

# Hardware
echo "--- /proc/bus ---" > "$OUTDIR/hardware.txt"
ls -laR /proc/bus/ >> "$OUTDIR/hardware.txt" 2>&1
echo "--- /sys/class ---" >> "$OUTDIR/hardware.txt"
ls /sys/class/ >> "$OUTDIR/hardware.txt" 2>&1

# Dump des partitions MTD (vers USB si disponible)
if [ -d "/mnt/usb" ] || mount /dev/sda1 /mnt/usb 2>/dev/null; then
    echo "USB detecte, dump des partitions MTD..."
    mkdir -p /mnt/usb/mtd_backup
    for mtd in /dev/mtd*ro; do
        if [ -e "$mtd" ]; then
            name=$(basename "$mtd" | sed 's/ro//')
            echo "  Dumping $name..."
            dd if="$mtd" of="/mnt/usb/mtd_backup/backup_${name}.bin" bs=131072 2>/dev/null
        fi
    done
    # Copier aussi les resultats recon
    cp -r "$OUTDIR" /mnt/usb/recon_results/
    sync
    echo "Backup MTD et resultats copies sur USB"
else
    echo "Pas d'USB monte. Pour dumper les MTD manuellement :"
    cat /proc/mtd
    echo "Utiliser : dd if=/dev/mtdXro of=/tmp/mtdX.bin bs=131072"
    echo "Puis transferer via netcat : nc <IP_PC> 9999 < /tmp/mtdX.bin"
fi

echo ""
echo "=== Collecte terminee ==="
echo "Resultats dans : $OUTDIR"
ls -la "$OUTDIR/"
RECON

    chmod +x "$script_file"
    ok "Script de reconnaissance genere : $script_file"
    echo "Copier ce script sur une cle USB FAT32 et l'executer sur le boitier"
}

# =============================================================================
# Menu principal
# =============================================================================
usage() {
    echo ""
    echo "AirTies AIR 7310T - Outil de reverse engineering"
    echo "================================================"
    echo ""
    echo "Usage: $0 <commande> [options]"
    echo ""
    echo "Commandes :"
    echo "  check          Verifier les outils necessaires"
    echo "  connect        Connexion serie (UART) avec log"
    echo "  bruteforce     Tenter les passwords par defaut"
    echo "  analyze <file> Analyser un dump firmware"
    echo "  modify  <file> Extraire et modifier un rootfs SquashFS"
    echo "  tftp           Demarrer un serveur TFTP"
    echo "  scan [ip]      Scanner le reseau (ou un IP specifique)"
    echo "  recon          Generer le script de collecte pour le boitier"
    echo ""
    echo "Workflow recommande :"
    echo "  1. $0 check            # Verifier les prerequis"
    echo "  2. $0 connect          # Se connecter et capturer le boot log"
    echo "  3. Interrompre le boot pour acceder au bootloader"
    echo "  4. $0 recon            # Generer le script de reconnaissance"
    echo "  5. $0 analyze dump.bin # Analyser le firmware dumpe"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
case "${1:-}" in
    check)      check_deps ;;
    connect)    serial_connect ;;
    bruteforce) bruteforce_passwords ;;
    analyze)    analyze_firmware "$2" ;;
    modify|modify-rootfs) modify_squashfs "$2" ;;
    tftp)       setup_tftp ;;
    scan)       scan_network "$2" ;;
    recon)      generate_recon_script ;;
    *)          usage ;;
esac
