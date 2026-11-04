# Shared by the in-container build scripts (sourced, not run).

# fetch <tarball> <url>: download into the /dl cache once; a partial download never passes for a
# complete one (.part, renamed at the end)
fetch() {
    [ -f "/dl/$1" ] && return
    echo "[*] Downloading $2 ..."
    wget -q -O "/dl/$1.part" "$2"
    mv "/dl/$1.part" "/dl/$1"
}
