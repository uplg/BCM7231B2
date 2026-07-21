# BCM7231 XPT — capture TS vers RAM (reversé de nexus.ko + headers RDB 7340)

Objectif : MxL101SF (TS série/parallèle) → XPT input band → parser all-pass →
PID channel → bloc XPT_MSG (mode record TS) → ring buffer DMA en RAM →
lecture userspace via /dev/mem → stdout → VLC.

Toutes les adresses ci-dessous sont **physiques** (BCHP offset + 0x10000000).
Sources : reversing BXPT_* de `rootfs_extracted/.../extra/nexus.ko` (unstripped),
validé par les headers RDB publics du BCM7340 (même layout intra-bloc, rebasé
sur la carte 7231 de `bchp_common.h` 7231b0) — voir scratchpad
`7340_bchp_xpt_msg.h`, `7340_bchp_xpt_fe.h`.

## Carte des blocs XPT (7231b0, bchp_common.h)

| Bloc | Début (phys) |
|---|---|
| XPT_BUS_IF | 0x10a00000 |
| XPT_FE | 0x10a04000 – 0x10a053fc |
| XPT_PB_TOP / PB0-4 | 0x10a08000 / 0x10a08100 + 0x80*N |
| XPT_FULL_PID_PARSER | 0x10a10000 – 0x10a12050 |
| XPT_MSG | 0x10a18000 – 0x10a1e014 |
| XPT_RAVE | 0x10a20000 |

## XPT_FE

- **IBn_CTRL = 0x10a04100 + 8*n** (n = 0..6 sur 7340; sonder la borne sur 7231).
  Défaut lu live : 0x00bc0000 (= PKT_LENGTH 188, tout le reste à 0).
  Champs : bit0 CLOCK_POL, bit1 SYNC_POL, bit2 DATA_POL, bit3 VALID_POL,
  bit4 ERROR_POL, bit5 ERROR_INPUT_EN, **bit6 SYNC_DETECT_EN**,
  bit7 USE_SYNC_AS_VALID, bit8 FORCE_VALID, bit9 LSB_FIRST,
  **bit10 IB_PARALLEL_INPUT_SEL** (1=parallèle), bits[23:16] IB_PKT_LENGTH (188).
- **IBn_SYNC_COUNT = 0x10a04104 + 8*n** : compteur de syncs détectés →
  **détecteur de câblage** : activer le TS du MxL, mettre SYNC_DETECT_EN, lire.
- **PARSERn_CTRL1 = 0x10a04180 + 0x10*n** :
  bit0 PARSER_ENABLE, **bit1 PARSER_ALL_PASS_CTRL**, bit3 CONT_COUNT_IGNORE,
  bit4 ACCEPT_NULL_PKT, bits[7:5] PACKET_TYPE (0=MPEG), **bits[11:8]
  PARSER_INPUT_SEL** (numéro d'input band), bits[19:12] PARSER_PKT_LENGTH (188),
  bits[24:21] TIMEBASE_SEL. (BXPT_SetParserDataSource : RMW mask 0xffdff0ff,
  écrit INPUT_SEL; bit21 sert de flag playback dans le RMW vendeur.)
- Mapping parser→banda (identité par défaut, ne pas toucher) : 0x10a04580/84/88.

## Table PID (XPT_FULL_PID_PARSER sur 7231)

- **PID_CHANNEL_TABLE : 0x10a04800 + 4*chan** (word (0x281200+chan)<<2 dans le
  code vendeur — reste dans la plage FE/FULL_PID_PARSER du 7231).
  Valeur = PID bits[11:0] (attention : le code vendeur masque 0xfff pour la
  partie basse et gère le bit 12 via 0x1fff ailleurs — vérifier avec un PID
  > 0xfff; pour all-pass on s'en fiche), bits[21:16] = band id,
  bit14 = enable (helper 0x33e6dc toggle 0x4000 après vérif des destinations).
  RMW vendeur préserve 0xf7c0f000 (mode PID: masque 0xf7c0e000).
- **SPID / destinations : 0x10a05000 + 4*chan** : top byte = bitfield de
  destinations, **1 bit par destination : bit (24+destNum)**. Destination
  record = 7 → **bit 31 (0x80000000)**. RMW : préserver bits[23:0].
  (Confirmé par le disasm complet de BXPT_P_SetPidChannelDestination :
  enable → topbyte |= 1<<dest; disable → topbyte &= ~(1<<dest).)
- **En all-pass, le PID channel utilisé = index all-pass du parser** — d'après
  BXPT_ParserAllPassMode, l'état soft utilise l'entrée [band] et NEXUS lit
  handle->allPassIndex (offset 0x3c du ctx). Hypothèse la plus probable
  (à valider live) : **PID channel n° = numéro du parser band** en all-pass,
  sinon essayer les entrées hautes de la table. Valider en écrivant la config
  et en regardant quel VP bouge.

## XPT_MSG (base 0x10a18000, layout = 7340 délta identique)

- MSG_CTRL1 = 0x10a18000 : bit3 SOFT_RESET, bits[2:1] ARB_MODE, bit0 ENDIAN.
- **DMA_BUFFER_RESET = 0x10a1800c** : écrire le n° de buffer → reset du buffer.
- **BUF_CTRL1_TABLE[i] = 0x10a18200 + 4*i** (i = 0..127) :
  bits[3:0] **DATA_OUTPUT_MODE : 1 = MPEG_TS** (capture TS brut), 11 = RAW,
  bit8 ALIGN_MODE, bits[7:6] ERR_CK_MODE, bit5 ERR_CK_DIS.
- BUF_CTRL2_TABLE[i] = 0x10a18400 + 4*i : enables SAM/filtres (laisser 0).
- **DMA_BP_TABLE[i] = 0x10a18600 + 4*i** : bits[21:0] = **adresse base en
  unités de 1 Ko** (phys >> 10), bits[31:28] = taille : code 0=1K … 9=512K
  (0x400 << code).
- **DMA_RP_TABLE[i] = 0x10a18800 + 4*i** : read pointer, offset 19 bits.
- **DMA_VP_TABLE[i] = 0x10a18a00 + 4*i** : valid/write pointer, 19 bits.
  depth = (VP - RP) mod size. Drain : copier [RP..VP), avancer RP.
- GEN_FILT_EN[i] = 0x10a19000 + 4*i : **écrire 0** (pas de filtre générique) —
  c'est ce que fait StartPidChannelRecord.
- **PID2BUF_MAP[chan] = 0x10a1c000 + 4*chan** : n° de buffer pour ce PID chan.
  (Vendeur : ConfigPid2BufferMap(handle, chan, buf, 1).)
- BUF_DAT_AVAIL_xx = 0x10a18080+ : bitmaps data-available (lecture debug).

## Séquence de programmation xpt_cap (proposée)

1. MSG : SOFT_RESET pulse éventuel; DMA_BUFFER_RESET ← buf.
2. DMA_BP[buf] = (phys_buf >> 10) | (size_code << 28) ; RP=VP=0 via
   BUFFER_RESET; GEN_FILT_EN[buf] = 0; BUF_CTRL2[buf] = 0.
3. BUF_CTRL1[buf] = DATA_OUTPUT_MODE=1 (MPEG_TS).
4. PID2BUF_MAP[chan] = buf.
5. SPID[chan] : destination record (valeur exacte : bit correspondant à dest 7
   dans le top byte — sur le RMW vendeur : nouveau = (old & 0xffffff) |
   (destBits << 24); observer ce que ça donne, essayer 0x80 << 24 ou 7 << 24 —
   à valider live, le disasm montre `sll a2, s3, 0x18` avec s3 = valeur
   calculée par un helper table 0x33cdb8/0x33e6dc selon dest).
6. PID_CHANNEL_TABLE[chan] = band<<16 (all-pass : PID quelconque) + enable
   bit14.
7. Parser : PARSERn_CTRL1 = PKT_LENGTH 188<<12 | INPUT_SEL ib<<8 | ALL_PASS
   bit1 | ACCEPT_NULL bit4 | CONT_COUNT_IGNORE bit3 | ENABLE bit0.
8. IB : IBn_CTRL = 0xbc<<16 | SYNC_DETECT_EN bit6 | (parallèle? bit10) |
   polarités à déterminer.
9. Poll VP; dès que ça bouge, drain ring → stdout, RP ← VP.

## Environnement / contraintes

- `/dev/mem` : accès total (pas de STRICT_DEVMEM dans la config kernel).
- GISB : lecture d'un registre non-backé = bus error **imprécis** → pour les
  sondes exploratoires utiliser le pattern fork-per-word de src/memprobe.c;
  pour les registres connus ci-dessus, accès direct OK.
- Buffer DMA : réserver la RAM haut de bank0 dans le DTS
  (kernel/bcm7231-airties-7310t.dts) — la box n'a que 256 Mo utiles
  (le range 0x20000000 du DTS est ignoré au boot, iomem s'arrête à
  0x0fffffff). Ex : `/memreserve/ 0x0ff00000 0x00100000;` puis buffer 512 Ko
  à 0x0ff00000 (code taille 9).
- MxL101SF : `mxl_probe -T` active la sortie TS (reg 0x17 bits[7:6]=11).
  **CONFIRMÉ live : tuner maître 0x60 → IB0, en série, config IB par défaut
  déjà fonctionnelle** (IB0_SYNC_COUNT tourne dès TS ON, sans aucun write
  XPT). Le tuner esclave 0x63 n'allume pas IB1 (à creuser plus tard).
- **Validation de chaîne sans all-pass ni lock RF** : le MxL non-verrouillé
  émet des paquets null (PID 0x1FFF). Config PID channel 0 en mode normal :
  PID_CHANNEL_TABLE[0] = enable | band0<<16 | 0x1fff → tout arrive dans le
  buffer même sans antenne. Ensuite seulement, basculer en all-pass et
  vérifier l'hypothèse canal all-pass (= n° parser band ?).
- Flash kernel : `make kernel && make flash-kernel` (CFE récupère en cas
  d'échec). Tools : `make tools` (src/<n>.c statiques via docker).
