# Kernel patches

The kernel changes, as a series in `git format-patch` form, applied in order onto the kernel.org
tarball by `scripts/kbuild.sh` (`patch -p1 --fuzz=0`: a patch that no longer applies exactly
stops the build). The tree in the build volume records the series it was patched with and is
extracted again whenever the series changes.

- `upstream/`: meant for the mainline kernel, written to its rules (subsystem prefix, `Fixes:`
  tags checked against upstream history, `checkpatch.pl --strict` clean).
- `local/`: this board only, or not in a shape upstream would take.

The device tree (`kernel/bcm7231.dtsi`, `kernel/bcm7231-airties-7310t.dts`) and the two board
drivers (`kernel/bcm7231-kir.c`, `kernel/bcm7231-dvb.c`) stay files of their own, copied into
the tree on every build; the local patches hook them into Kconfig and the Makefiles.

Nothing here has been sent anywhere. **No patch goes upstream without Léonard's go.**

## Changing a patch

Regenerate it rather than editing the diff by hand: apply the series on a git tree of the same
kernel version, amend the commit, then `git format-patch --zero-commit --no-signature` into
the right directory, keeping its number. On a kernel bump, a patch that fails is rebased the
same way.

## Status

| Patch | Target tree | State |
|-------|-------------|-------|
| 0001 bus: brcmstb_gisb: optional breakpoint IRQ | drivers/bus (Florian Fainelli) | ready |
| 0002 ata: libahci: warn only when ports are masked | libata (Damien Le Moal, Niklas Cassel) | ready |
| 0003 net: phy: bcm7xxx: BCM7231 EPHY | net-next | ready |
| 0004 net: bcmgenet: no EEE registers on v1/v2 | net (a fix, `Fixes:` + stable) | to verify, see below |
| 0005 wifi: rtw88: usb: resubmit RX URBs | wireless (Ping-Ke Shih) | to verify, see below |
| 0006 MIPS: BMIPS: SYS_SUPPORTS_ZBOOT | mips (Thomas Bogendoerfer) | ready |
| 0101 net: bcmgenet: poll the PHY on v2 | (local) | workaround, root cause unknown |
| 0102 MIPS: BMIPS: AIR 7310T board | (local) | goes up with the DTS and its bindings |
| 0103 Input: BCM7231 KIR | (local) | upstream wants an rc-core driver |
| 0104 misc: AIR 7310T DVB-T | (local) | upstream wants drivers/media drivers |

## Before sending

For every patch:

1. Search lore.kernel.org for the same fix, already posted or merged.
2. Rebase onto the target tree of the day (a partial clone is enough:
   `git clone --filter=blob:none`), not onto the release tarball.
3. `scripts/checkpatch.pl --strict`, a `W=1 C=1` build, and a test on the box.
4. Add `Signed-off-by:` (the DCO: it certifies the right to submit, under a real name and an
   address that becomes public). The patches here carry none on purpose.
5. Recipients from `scripts/get_maintainer.pl`; send with `b4 send` (or `git send-email`),
   plain text, `[PATCH net]` / `[PATCH net-next]` as the tree requires.

Open questions, per patch:

- **0004**: which access faults on GENET v2: UMAC_EEE_CTRL, TBUF_ENERGY_CTRL or
  RBUF_ENERGY_CTRL? It only shows on a link change, so it takes a cable on eth0, a kernel
  without the patch, and the exact bus error from the console. The answer decides the fix:
  if GENET v2 has no EEE at all, it should also stop advertising it (`phy_support_eee()` is
  called for every version but v1) and the ethtool EEE operations should refuse v2 as they
  refuse v1. Ask Florian Fainelli whether v2 has EEE.
- **0005**: the URB is resubmitted right from its completion handler (GFP_ATOMIC). If an
  error persists, that loops as fast as the bus answers; deferring to `rx_urb_work` would
  bound it. What runs on the box today is the immediate resubmission (no WiFi restart since,
  under the backups' load): decide, and test whichever is sent.
- **0101**: check whether the link interrupt works now that the device tree has the right
  IRQ numbers; if it does, drop the patch.
