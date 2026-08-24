#!/bin/bash
# =============================================================================
# In-container kird build (static Rust, MIPS32 R1) — invoked by `make kird`.
#
# mipsel-unknown-linux-musl is Tier 3 (no prebuilt std -> nightly + build-std)
# AND its stock spec emits MIPS32 R2 code, which the BMIPS4380 rejects with
# "Illegal instruction". So: dump the stock target spec, downgrade cpu to
# mips32 (R1, keeping the fpxx hard-float ABI — matches the Bootlin userland),
# and link through the Bootlin musl gcc instead of rustc's self-contained crt.
# Output: /output/kird
# =============================================================================
set -e

CROSS="$(cat /opt/cross-prefix)"
SPEC=/tmp/mipsel-airties-linux-musl.json

echo "============================================"
echo "  kird — static Rust, MIPS32 R1 (${CROSS})"
echo "============================================"

# Use the nightly PINNED in the builder image — a bare `+nightly` would pull
# the floating channel at every run.
TOOLCHAIN="$(rustup toolchain list | awk '{print $1}' | grep '^nightly' | head -1)"
echo "[*] toolchain: $TOOLCHAIN"

rustc "+$TOOLCHAIN" -Z unstable-options --print target-spec-json \
    --target mipsel-unknown-linux-musl > "$SPEC.orig"

python3 - "$SPEC" "$CROSS" << 'PYEOF'
import json, sys
spec = json.load(open(sys.argv[1] + ".orig"))
spec["cpu"] = "mips32"
spec["features"] = "+mips32,+fpxx,+nooddspreg"
spec["linker"] = sys.argv[2] + "-gcc"
spec["linker-flavor"] = "gnu-cc"
spec["link-self-contained"] = {"components": []}
spec["crt-static-default"] = True  # rootfs has no shared libs at all
spec.pop("is-builtin", None)
json.dump(spec, open(sys.argv[1], "w"), indent=2)
print("[*] target spec: cpu=%s features=%s linker=%s"
      % (spec["cpu"], spec["features"], spec["linker"]))
PYEOF

cd /work/kird
# The musl spec hardcodes -lunwind; without rustc's self-contained libs the
# Bootlin toolchain has no libunwind.a. Its libgcc_eh.a exports the same
# _Unwind_* symbols (barely used anyway: panic=abort), so shim it.
SHIM=/tmp/unwind-shim
mkdir -p "$SHIM"
cp "$(dirname "$("${CROSS}-gcc" -print-libgcc-file-name)")/libgcc_eh.a" "$SHIM/libunwind.a"
export RUSTFLAGS="-C target-feature=+crt-static -L $SHIM"
cargo "+$TOOLCHAIN" build --release \
    -Z build-std=std,panic_abort \
    -Z json-target-spec \
    --target "$SPEC" \
    --target-dir /tmp/kird-target \
    2>&1 | tail -15

BIN=/tmp/kird-target/mipsel-airties-linux-musl/release/kird
[ -f "$BIN" ] || { echo "!!! BUILD FAILED !!!"; exit 1; }

file "$BIN" | grep -q 'statically linked' || \
    { echo "!!! kird is not static — the rootfs has no shared libs !!!"; file "$BIN"; exit 1; }

cp "$BIN" /output/kird
"${CROSS}-strip" /output/kird
echo ""
echo "=== /output/kird ==="
ls -lh /output/kird
file /output/kird
"${CROSS}-readelf" -A /output/kird | grep -E 'ISA|FP ABI'
