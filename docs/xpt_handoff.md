# XPT TS-capture — plan de reprise (handoff)

État au 2026-07-21. Lis d'abord `docs/xpt_capture_notes.md` (carte des
registres, séquence de prog). Ce fichier-ci = où on en est, ce qui est
prouvé/éliminé, et quoi faire ensuite dans l'ordre.

## Objectif

MxL101SF (TS) → XPT input band → parser → PID channel → XPT_MSG (mode
record) → ring DMA en RAM réservée → userspace → Mac. Le frontend et le
lock RF sont acquis depuis longtemps (voir memory `air7310t-dvb-tuner`).
Le seul étage manquant : faire écrire un moteur XPT en DRAM.

## LE DIAGNOSTIC (ne pas re-litiger)

**Un seul étage est mort : parser → match/capture PID.** Prouvé :

1. **La lecture DRAM du XPT marche.** J'ai fait tourner le moteur
   **playback PB0** de bout en bout (voir "Playback" plus bas) : il lit
   un buffer TS depuis la RAM réservée, FINISHED propre, 6016 octets
   consommés exactement, `PARSER_CTRL1` playback passe **in-sync**. Donc
   bus GISB, DRAM-read, pacing, parser : tous fonctionnels.

2. **Aucun moteur d'écriture ne bouge jamais.** RS (rate-smoothing), XC
   (cross-connect), MSG (record) : leurs write-pointers restent **figés
   à `base-1`** (ring vide) quel que soit le stimulus. Le ring MSG en RAM
   (`0x0ff00000`) reste plein de zéros. `BUF_DAT_AVAIL` reste 0.

3. **Les paquets sont droppés, pas bloqués.** Le playback FINIT sans
   backpressure → rien en aval ne consomme, donc le parser jette les
   paquets avant de remplir quoi que ce soit.

4. **Ça n'a JAMAIS marché**, dès le premier cold boot (kernel #16). Ce
   n'est donc pas un état corrompu récupérable par reboot/power-cycle.
   Le xptreset n'était PAS le coupable (fausse piste de la session
   précédente) : le "compteur sync qui s'arrête" est un compteur 8-bit
   d'*acquisition* qui se cale une fois synchronisé, pas un débitmètre.

### Hypothèse de tête : init plateforme kernel manquante

Vendeur : CFE → **kernel stock 3.3.8 Broadcom** (fait `brcm_pm_init`,
`bcm7231_pm_initialize`, `bchip_early_setup`, framework clk) → nexus.ko.
Nous : CFE → **mainline kernel.org 7.1.4 nu**, zéro init Broadcom. Tout
ce que leur kernel programme au boot (CLKGEN, MEMC arb, sundry) nous
manque. C'est le suspect n°1 du drop parser→PID.

## ⇒ AVANCÉE 2026-07-21 (suite) : microcode RAVE = la vraie pièce manquante

**LA cause racine trouvée : le RAVE a besoin d'un microcode 16 Ko jamais
chargé.** `BXPT_P_RaveRamInit` (@nexus.ko .text+0x35191c) écrit 4096 mots
(blob `BxptRaveInitData`, .rodata+0x9b9a0) dans le code RAM à
**phys 0x10a30800..0x10a347fc**, puis **release l'engine via
0x10a30004=0**. Sans ça, la machine d'état RAVE ne tourne pas → le
write-pointer CDB ne bouge JAMAIS même avec PID/dest-5/routing corrects.
C'est exactement le symptôme historique. Blob extrait : `fw/rave_microcode.bin`
(16384 o, md5 ba5e8183cea09ad0d31484c9cd17bd7f).

**Implémenté + testé live : `xpt_cap raveinit <ucode.bin> [-s cdbsize]`**
(clear 3 régions SRAM, load microcode, release, modeword CDB-size @0x10a25858).
Tourne proprement : ucode vérifié par échantillonnage (0 FAIL), release
readback 0x440 (statut, OK), modeword posé. **Champ pointeur CDB confirmé
24 bits** (poke 0xffffffff → rb 0x00ffffff, top byte masqué) : notre buffer
phys 0x0ff00000 ne rentre PAS en bytes bruts → device-offset requis
(hyp. >>4 : 0x0ff00000>>4=0xff0000 rentre pile en 24 bits ; à confirmer
via le read-back transform du driver, reversing en cours).

Séquence RAVE complète reversée (recette dans nexus.ko) :
- Global (1×) : clear regs 0x25974..0x25d70, 0x26174..0x26570,
  0x27200..0x2b1fc ; load ucode 0xa30800 ; release 0xa30004=0 ; modeword
  0xa25858 = (old&0x0c000005)|mode (mode 512K=0x51822008, 1M=0x41822008…).
- Contexte N (base 0xa2b200+N*0x100, stride 0x100, 8 ctx ; ITB base
  0xa2ba60+N*0x48) : CDB +0x00 WRITE / +0x04 READ / +0x08 BASE / +0x0c END
  (=BASE+size-1) ; SetRecordConfig écrit +0xa8,+0xac,+0xb0,**+0x68
  (AV_MISC_CONFIG1)**,+0x18,+0x3c,+0x70,+0xb4 ; ITB skip si settings.0x2f=0.
- Bind PID : queue-alloc reg ((band+0x40)<<5+0x289c97)<<2 → queueNum ;
  table PID queue 0xa29100+queueNum*0x40 (+0x0c+depth*4 = pidChan, +0x04 =
  depth) ; ctx+0xa4 |= 0x01000000 ; SPID dest **5** (0x20<<24) @0xa05000+chan*4.
- ARM (dernier) : ctx+0x68 |= 0x00100000 (CONTEXT_ENABLE).
- Drain : lire ctx+0x00 (WRITE) - ctx+0x04 (READ), copier le ring, avancer READ.

RESTE À FAIRE (agent reverse) : (i) bytes exacts du settings-struct pour
un record TS brut (settings.0/4/8/0x10.../0x2f) → valeurs concrètes des
regs SetRecordConfig ; (ii) transformée device-offset des pointeurs CDB
(unité + base implicite). Puis : coder le sous-commande `rave` (open ctx +
config + bind + arm + drain), build, test avec le TS du MxL sur IB0.

## ⇒ REDIRECTION MAJEURE 2026-07-21 : MAUVAIS MOTEUR (MSG au lieu de RAVE)

**xpt_cap cible le mauvais bloc.** Il y a DEUX moteurs record dans nexus.ko :
- **XPT_MSG (destination 7 = top-byte SPID 0x80)** = ce que fait xpt_cap.
  Orienté **sections PSI / PES**, petits buffers (BP_BUFFER_SIZE max
  quelques Ko). Ce n'est PAS le moteur de streaming TS continu. → explique
  pourquoi le write-pointer MSG ne bouge jamais pour un flux TS.
- **XPT_RAVE (destination 5 = top-byte SPID 0x20)** = LE moteur de capture
  **TS contigu → ring DRAM** (recpump). Ring CDB (Contiguous Data Buffer)
  + ITB (Index Table Buffer) dans la RAM, avec un **arm dédié jamais
  posé : `CONTEXT_ENABLE` = bit 20 de `context_base+0x68` (AV_MISC_CONFIG1)**.

Le symptôme historique (« aucun write-engine ne bouge, paquets droppés »)
colle : le handoff ne surveillait que RS/XC/MSG — **jamais le write-pointer
CDB de RAVE**, qui n'a jamais été configuré ni armé. RAVE context 0
(~phys 0x10a2b200 CDB, ~0x10a25858 ITB) lu live = SRAM non-init (bus
errors + valeurs aléatoires) → confirmé jamais monté.

**Plan : implémenter un sous-commande `rave` dans xpt_cap.c** : ouvrir un
contexte RAVE (CDB base/end/rd/wr, ITB), SetRecordConfig mode all-pass-TS,
router la PID channel vers RAVE (SPID dest **5**, + éventuelle table
PID→context analogue à PID2BUF), poser CONTEXT_ENABLE bit20. Draîner le
ring CDB (write_ptr - read_ptr) vers stdout. Séquence registre exacte en
cours de reversing (BXPT_Rave_OpenChannel @0x353588, SetRecordConfig
@0x34e00c, PushPidChannel @0x350f08, EnableContext @0x34bdc8,
AddPidChannel @0x350298). Le staging RS/XC de xpt_cap est probablement
inutile pour ce chemin.

## MAJ 2026-07-21 — hypothèse plateforme AFFAIBLIE, deux pistes tuées

Reversing du kernel stock (`mtd4_backup.bin`, ELF non strippé) + nexus.ko :

1. **Hypothèse « horloge manquante » : MORTE.** `brcm_clk_table`
   (@0x80530ba4, 9 entrées de 0x38 o) ne gère QUE sata/enet/moca/usb/
   network — **aucune horloge xpt/hif/transport**, et `brcm_dyn_clk_list`
   est vide. `mmio_scan` du kernel entier (235 writes MMIO) : tous les
   writes CLKGEN(0x9042)/MEMC(0x903b) sont du PM périphérique (usb/genet/
   sata/ddr-timeout/s3), zéro XPT. Le clock XPT (0x4201dc=0x07) est déjà
   ON chez nous. **On boote via le MÊME CFE que le vendeur** → toute
   l'init niveau CFE (MEMC arb, PLLs, straps, memsys) est IDENTIQUE. La
   différence ne peut être que kernel-mainline+xpt_cap vs kernel-stock+
   nexus.ko. Donc le suspect n'est PLUS la plateforme : c'est la
   réplication de nexus.ko.

2. **Hypothèse « mauvais bit enable » : MORTE.** Le helper vendeur
   `0x33e6dc` (appelé par `BXPT_P_EnablePidChannel`) fait le RMW sur
   `(0x281200+chan)<<2` = **phys 0x10a04800+chan*4** (PID_CHANNEL_TABLE)
   et bascule le **bit 14 (0x4000)** pour l'enable. Donc xpt_cap a RAISON
   (le layout 7340 RDB met l'enable au bit 20, mais c'est un registre
   *différent* — le 7231 utilise bit14). NB : `BXPT_P_EnablePidChannel`
   n'active QUE si le top-byte destinations de SPID[chan] (0x10a05000)
   est != 0.

### Chemin record AUTORITAIRE (reversé de BXPT_Mesg_StartPidChannelRecord
   @0x334b5c) — xpt_cap le réplique correctement :
   a. `GEN_FILT_EN[buf]` (0x10a19000+buf*4) = 0
   b. `BUF_CTRL1[buf]` (0x10a18200+buf*4) = mode selon settings[8] :
      settings[8]==1 → **1 (MPEG_TS)** ; ==0 → 3 (MPEG_PES) ; ==2 → 5.
      Pour un record TS = **1** → xpt_cap `0x1` est CORRECT.
   c. `BXPT_P_SetPidChannelDestination(chan, dest=**7**, en=1)` → top-byte
      SPID = bit31 = **0x80** → xpt_cap dest=0x80 CORRECT.
   d. `BXPT_ConfigurePidChannel(chan)` (pid/band/enable bit14)
   e. `ConfigPid2BufferMap(chan, buf, 1)` → PID2BUF[chan]=buf (0x10a1c000)
   **Le record-start ne touche NI RS NI XC.** Le staging RS/XC de xpt_cap
   (`do_init_buffers`) n'appartient PAS au chemin record — au mieux monté
   globalement par BXPT_Open (XCBUFF = buffer inter-parseur↔clients-MSG),
   au pire fausse piste nuisible. À trancher : voir si le path record
   passe réellement par XCBUFF (client MSG) ou lit direct la sortie
   parseur (analyse MCPB / DMA-context en cours).

   Aucun registre « RUN/enable global » dans le bloc MSG (0x10a18000=
   MSG_CTRL1, +4=PSI_CTRL1, +8=PES_CTRL1=0xff00 défaut). Le DMA MSG écrit
   dès qu'un paquet est routé vers un buffer au BP valide.

Conséquence pour la suite : les sémantiques-registres de xpt_cap sont
bonnes. Le bug est soit (i) le XCBUFF/MCPB global mal monté, soit (ii) un
arm/contexte DMA manquant → **la piste fiable reste l'Étape 2 (golden
dump via reflash stock)** si le reversing du path MCPB n'aboutit pas.
Outils : `c1c7b250-…/scratchpad/mmio_scan.py` (scan MMIO kernel),
`kdis.py` (disasm kernel stock symtab).

## Ce qui a été tenté et ÉLIMINÉ (ne pas refaire)

- Horloges XPT via reversing `BCHP_PWR_P_HW_XPT_*` : `0x104201dc=0x07`
  (108M+XMEMIF ; écrire 0 tue tout l'espace XPT → prouve que c'est ON),
  SRAM `0x4201e8`, RMX `0x4201d8`, WAKEUP `0x4202b0/b4`. Tous déjà bons.
- `0x104201ec |= 0xc0` (ce que fait `bcm7231_pm_initialize`) — **aucun
  effet** sur le flux.
- Séquence SW_INIT complète du vendeur (`BCHP_Open7231` : SET/CLEAR bits
  8/9/12/16/18 sur `0x404318/1c`, `SW_INIT_1` `0x404330/34`) : IB resync
  proprement, mais rien en aval.
- `xpt_cap openinit` (réplique fidèle de `BXPT_Open`, voir plus bas) :
  clear de toutes les tables + rings valides pour TOUTES les bandes
  RS(G1/G2/G3) et les 4 clients XC(IBP+PBP) + BO 27 Mbps + pacing.
  Aucun write-pointer ne bouge quand même.
- Sweep destinations SPID (les 8 bits), band id (0..15), bit28
  TIMESTAMP_MODE, all-pass vs pid-match null (0x1fff), PB_TOP pause maps
  (`0xa08008/48`), PCR offset (`0xa0c020`). Rien.

## OUTIL xpt_cap (src/xpt_cap.c) — compilé & déployé (`/dev/shm/xpt_cap`)

Sous-commandes : `status`, `openinit`, `setup`, `capture`, `stop`,
`xptreset`, `peek <addr> [len]`, `poke <addr> <val>`, `load <addr>`
(copie stdin → RAM phys via mmap ; write() sur /dev/mem échoue EFAULT
sur la zone /memreserve/, mmap marche).

- `openinit` : à lancer APRÈS `xptreset`, PUIS `setup --no-rsbuf --no-xc`.
  Réplique `BXPT_Open` : bump-allocator sur la RAM après le ring MSG,
  rings valides + BO pour toutes bandes RS et 4 clients XC.
- Défauts : ib=0 parser=0 chan=0 buf=0 phys=0x0ff00000 size=512K dest=0x80.
- Build : `make tools` (docker, statique MIPS), deploy : `scp -O
  build_output/xpt_cap root@192.168.2.1:/dev/shm/`.

Modifs de cette session dans xpt_cap.c : ajout `openinit`, `load`, table
`xc_clients[4]`, BO word pour RS G2 + XC PBP (offset IBP_BO+0x80).

## PLAYBACK PB0 — RÉUSSI, réutilisable comme banc de test

Le moteur playback lit un TS depuis la RAM et l'injecte dans le parser
sans antenne. Format descripteur (**little-endian**, 16 o, reversé de
`BXPT_Playback_CreateDesc/AddDescriptors`) :
`{ w0=buf_phys, w1=len, w2=flags, w3=next }` — `w3==1` = fin de chaîne ;
flag bit30 (`0x40000000`) posé par le hw pendant le parcours.

Séquence live qui donne FINISHED + parser in-sync :
```
xpt_cap load 0x0ffd6000 < desc.bin     # desc: struct.pack('<IIII',0x0ffd6100,6016,0,1)
xpt_cap load 0x0ffd6100 < ts_test.bin  # 32 paquets null PID 0x1fff, 6016 o
xpt_cap poke 0x10a0812c 0xbc019        # PB0 PARSER_CTRL1: pktlen188|allpass|null|cc|en
xpt_cap poke 0x10a08110 0x0ffd6000     # PB0 FIRST_DESC_ADDR
xpt_cap poke 0x10a08100 2              # PB0 CTRL1 RUN
# -> 0x10a08100 lit 0x0a (FINISHED|WAKE), 0x10a08114 avance de 6016
```
PB0 regs (base `0x10a08100`, +`0x80`/canal) : CTRL1 `+0` (bit1 RUN,
bit3 FINISHED, bit2 BUSY), FIRST_DESC `+0x10`, CURR_DESC `+0x14`,
CURR_BUFF `+0x18`, PARSER_CTRL1 `+0x2c`, BAND_ID `+0x60` (lu=0x40).
Le générateur TS + descripteurs : régénérer avec le snippet python
ci-dessous (les .bin de /dev/shm sont perdus après reboot).

## OUTILLAGE (chemins absolus, réutilisables)

- **Disasm nexus.ko** (reloc-aware, résout CALL R_MIPS_26 + suit les
  const loads BCHP) :
  `d3b1326a-…/scratchpad/ko_disasm.py` et `range_disasm.py`, venv à
  `d3b1326a-…/scratchpad/venv`. nexus.ko unstripped :
  `rootfs_extracted/squashfs-root/lib/modules/3.3.8-2.3-betty/extra/nexus.ko`.
- **Disasm kernel stock** (ELF statique symtab, suit lui/addiu/ori) :
  `c1c7b250-…/scratchpad/kdis.py`. Cible :
  `backup/mtd4_backup.bin` (**ELF NON strippé, tous symboles** —
  `bcm7231_pm_initialize` @0x80277284, `bchip_early_setup` @0x8056b9d8,
  `brcm_pm_init` @0x8056d088, `bchip_set_features`, `memc_settings_valid`).
- **Headers RDB 7340/7231** : `d3b1326a-…/scratchpad/7340_bchp_xpt_*.h`,
  `7340_rsbuff.h`, `7340_pb0.h`, `7231_common.h`. Rebase : offset BCHP
  7340 `0x38xxxx` ↔ 7231 `0xa1xxxx` (même layout intra-bloc).
- Le chemin `d3b1326a-…` est un scratchpad de session précédente ; s'il
  disparaît, tout est régénérable depuis nexus.ko + les headers publics.

## PLAN DE REPRISE (ordre recommandé)

### Étape 1 — finir le reversing de l'init kernel stock (en cours)
`bcm7231_pm_initialize` ne fait que `0x4201ec|=0xc0` (testé, nul). Il
faut regarder plus large :
- `bchip_early_setup` (@0x8056b9d8) : touche `0x90408e80/84/8c` (bloc
  sundry/GISB). Rejouer live via `poke` (attention : phys vendeur =
  `0x9000_0000+off`, chez nous = `0x1000_0000+off` → `0x90408e80` →
  `0x10408e80`).
- `bchip_set_features`, `memc_settings_valid`, et surtout la table
  **`brcm_clk_table`** (@0x80530ba4 dans mtd4) + `brcm_dyn_clk_list` :
  y a-t-il un clock "xpt"/"hif" que le mainline ne gate pas ?
- Chercher dans le kernel stock tout write vers le bloc **MEMC arb**
  (`0x103b1xxx`) : le client XPT a peut-être un slot arbitre non
  configuré chez nous (dump live déjà pris, voir historique). Comparer.

### Étape 2 — le coup de grâce si étape 1 insuffisant (fiable)
Reflasher **temporairement** le kernel stock (mtd4_backup) en gardant
notre rootfs (dropbear devrait monter), `insmod nexus.ko` (versions
matchent : 3.3.8-2.3-betty), puis **dumper l'état golden** de tout XPT +
CLKGEN + MEMC via /dev/mem. Diff avec notre état → réponse garantie.
CFE récupère si ça ne boote pas. `make flash-kernel` flashe mtd4 ;
garder une copie de notre vmlinux pour re-flasher après.

### Étape 3 — quand un write-pointer bougera enfin
Dérouler `setup` (ou la séquence de `docs/xpt_capture_notes.md` §prog),
puis `capture > /dev/stdout | nc mac 1234`. Côté Mac : `nc -l 1234 >
out.ts` puis VLC. Le `capture` draine déjà le ring (VP-RP) vers stdout.

## Régénérer le banc TS (les .bin de /dev/shm sont volatils)
```python
import struct
pkts=b''.join(bytes([0x47,0x1f,0xff,0x10|(i&0xf)])+bytes([(i+j)&0xff for j in range(184)]) for i in range(32))
open('ts_test.bin','wb').write(pkts)                       # 6016 o
open('desc.bin','wb').write(struct.pack('<IIII',0x0ffd6100,len(pkts),0,1))
```

## État box / gotchas
- IP `192.168.2.1`, `ssh root@`. Kernel #17, 256 Mo utiles (bank0),
  `/memreserve/ 0x0ff00000 0x00100000` (1 Mo) dans le DTS.
- `/dev/mem` complet (pas de STRICT_DEVMEM). Lecture d'un registre GISB
  non-backé = **bus error imprécis** → sondes exploratoires avec
  `memprobe` (fork-per-word), pas `peek`. **memprobe a disparu de
  /dev/shm au dernier reboot — le re-scp** depuis build_output.
- La box a rebooté pendant la session : re-déployer memprobe + régénérer
  les .bin avant de reprendre. Tuner E39 (618 MHz) accroche bien.
