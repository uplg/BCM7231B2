#!/bin/bash
# make outdated: every pinned version against the latest upstream release, asked of the same
# sources the build scripts download from. Host-side, read-only: prints a table, changes nothing.
# Exit 0 when everything is current, 1 when an update exists, 2 when a source could not be asked.
#
# Env (set by the Makefile): KERNEL_VERSION BUSYBOX_VERSION MTDUTILS_VERSION WPA_VERSION
# LIBNL_VERSION E2FSPROGS_VERSION OPENSSH_VERSION ZLIB_VERSION SMARTMONTOOLS_VERSION
set -u
cd "$(dirname "$0")/.." || exit 2

get() { curl -fsSL --max-time 30 -A "airties-upcycling make outdated" "$1"; }
# index <url> <regex, one group>: the highest version an index page lists
index() { get "$1" | grep -oE "$2" | sed -E "s#$2#\\1#" | sort -Vu | tail -1; }
# github <owner/repo> <tag prefix>: its latest release's tag, prefix dropped, "_" read as "."
github() {
    local tag
    tag=$(get "https://api.github.com/repos/$1/releases/latest" | sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p')
    tag=${tag#"$2"}
    echo "${tag//_/.}"
}

series="${KERNEL_VERSION%.*}"
tc=$(sed -nE 's/.*mips32el--musl--stable-([0-9.]+-[0-9]+)\.tar\.xz.*/\1/p' docker/Dockerfile.builder | head -1)
nightly=$(sed -nE 's/.*--default-toolchain (nightly-[0-9-]+).*/\1/p' docker/Dockerfile.builder)

# The components, in table order; latest <name> asks upstream for each
NAMES=(linux-series linux-stable busybox openssh zlib wpa_supplicant libnl mtd-utils e2fsprogs
    smartmontools toolchain)
pinned() {
    case "$1" in
        linux-*) echo "$KERNEL_VERSION" ;;           busybox) echo "$BUSYBOX_VERSION" ;;
        openssh) echo "$OPENSSH_VERSION" ;;          zlib) echo "$ZLIB_VERSION" ;;
        wpa_supplicant) echo "$WPA_VERSION" ;;       libnl) echo "$LIBNL_VERSION" ;;
        mtd-utils) echo "$MTDUTILS_VERSION" ;;       e2fsprogs) echo "$E2FSPROGS_VERSION" ;;
        smartmontools) echo "$SMARTMONTOOLS_VERSION" ;; toolchain) echo "$tc" ;;
    esac
}
latest() {
    case "$1" in
        linux-series) index "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/" \
                          "linux-(${series//./\\.}\\.[0-9]+)\\.tar\\.xz" ;;
        linux-stable) get https://www.kernel.org/releases.json | tr -d '\n ' \
                          | sed -nE 's/.*"latest_stable":\{"version":"([^"]+)".*/\1/p' ;;
        busybox)      index https://busybox.net/downloads/ 'busybox-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.bz2' ;;
        openssh)      index https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/ 'openssh-([0-9]+\.[0-9]+p[0-9]+)\.tar\.gz' ;;
        zlib)         index https://zlib.net/ 'zlib-([0-9]+\.[0-9]+(\.[0-9]+)?)\.tar\.xz' ;;
        wpa_supplicant) index https://w1.fi/releases/ 'wpa_supplicant-([0-9]+\.[0-9]+)\.tar\.gz' ;;
        libnl)        github thom311/libnl libnl ;;
        mtd-utils)    index https://infraroot.at/pub/mtd/ 'mtd-utils-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.bz2' ;;
        e2fsprogs)    index https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/ 'v([0-9]+\.[0-9]+\.[0-9]+)/' ;;
        smartmontools) github smartmontools/smartmontools RELEASE_ ;;
        toolchain)    index https://toolchains.bootlin.com/downloads/releases/toolchains/mips32el/tarballs/ \
                          'mips32el--musl--stable-([0-9.]+-[0-9]+)\.tar\.xz' ;;
    esac
}
label() {
    case "$1" in
        linux-series) echo "linux ($series series)" ;; linux-stable) echo "linux (latest stable)" ;;
        toolchain) echo "bootlin toolchain" ;;          *) echo "$1" ;;
    esac
}

# All at once: busybox.net alone takes ~10 s to answer
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
for n in "${NAMES[@]}"; do latest "$n" > "$tmp/$n" 2>/dev/null & done
wait

updates=0 unknown=0
line() { printf '  %-24s %-20s %-20s %s\n' "$@"; }
line COMPONENT PINNED LATEST STATUS
for n in "${NAMES[@]}"; do
    pinned=$(pinned "$n")
    latest=$(head -1 "$tmp/$n")
    if [ -z "$latest" ]; then
        status="? could not ask upstream"; unknown=$((unknown + 1))
    elif [ "$pinned" = "$latest" ]; then
        status="ok"
    elif [ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)" = "$latest" ]; then
        status="UPDATE"; updates=$((updates + 1))
    else
        status="ok (pinned is newer)"
    fi
    line "$(label "$n")" "$pinned" "${latest:--}" "$status"
done
line "rust nightly (kird)" "$nightly" "-" "dated nightly, moved by hand"

echo
[ "$updates" -gt 0 ] && echo "  $updates update(s): bump the version in the Makefile (or the Dockerfile), rebuild, test on the box."
[ "$unknown" -gt 0 ] && echo "  $unknown source(s) did not answer: run it again, or check the URL in this script."
[ "$updates" -eq 0 ] && [ "$unknown" -eq 0 ] && echo "  Everything pinned is the latest upstream release."
[ "$unknown" -gt 0 ] && exit 2
[ "$updates" -gt 0 ] && exit 1
exit 0
