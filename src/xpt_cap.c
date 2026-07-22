/*
 * xpt_cap.c — program the BCM7231 XPT (transport processor) to capture the
 * raw DVB-T transport stream coming from the MxL101SF tuners into a RAM
 * ring buffer, and drain that ring to stdout (pure TS on stdout — pipe it
 * to a file or netcat/VLC; all diagnostics go to stderr).
 *
 * Path: MxL TS pins -> XPT input band -> parser (all-pass) -> PID channel
 * -> XPT_MSG record buffer -> DMA ring in reserved RAM (see /memreserve/
 * in kernel/bcm7231-airties-7310t.dts) -> /dev/mem mmap -> stdout.
 *
 * Register layout reversed from the vendor's unstripped nexus.ko (BXPT_*)
 * and cross-checked against the public BCM7340 RDB headers — see
 * docs/xpt_capture_notes.md.  Every register touched here is known to be
 * backed (validated live), so accesses are direct MMIO: no fork-per-word
 * probing like memprobe.c (only peek/poke can hit unbacked words — they
 * are for interactive iteration, a GISB bus error there just kills us).
 *
 * Confirmed by full disasm of BXPT_P_SetPidChannelDestination: the SPID
 * top byte is one bit per destination, bit (24 + destNum); "record" is
 * destination 7 => bit 31, i.e. destBits 0x80 (the default here; --dest
 * still overrides for experiments).  Also confirmed live: the master MxL
 * (i2c 0x60) feeds IB0 in SERIAL mode and the power-on IB config already
 * syncs — so the IB write keeps defaults (PKT_LENGTH=188 + SYNC_DETECT_EN)
 * unless polarity/parallel options are given.
 *
 * One knowingly-uncertain spot, made tunable for live iteration: the PID
 * channel index used in parser all-pass mode — probably equals the parser
 * band number (chan defaults to 0 with parser 0), -c <chan> switches it
 * easily (watch BUF_DAT_AVAIL / DMA_VP move).  Because all-pass is the
 * uncertain path, `setup --pid 0x1fff` programs a NORMAL PID-matching
 * channel instead (no parser all-pass): an unlocked MxL emits a constant
 * stream of PID 0x1FFF null packets, which validates the whole XPT->RAM
 * chain without an antenna or a lock.  That is the first live test.
 *
 * Subcommands:
 *   xpt_cap status  [-i ib] [-p parser] [-c chan] [-b buf]
 *   xpt_cap setup   [-i ib] [-p parser] [-c chan] [-b buf] [-a phys]
 *                   [-s size] [--pid <pid>] [--parallel] [--clkpol]
 *                   [--syncpol] [--datapol] [--forcevalid]
 *                   [--syncasvalid] [--dest <destbits>]
 *   xpt_cap capture [-b buf] [-a phys] [-s size]   > out.ts
 *   xpt_cap stop    [-p parser] [-c chan] [-b buf]
 *   xpt_cap peek <addr> [len]
 *   xpt_cap poke <addr> <val>
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <getopt.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PAGE      0x1000u
#define PAGEMASK  (~(PAGE - 1))

/* ---- XPT register map (physical addresses, BCHP offset + 0x10000000) ---- */
#define XPT_MAP_BASE            0x10a04000u  /* XPT_FE start */
#define XPT_MAP_LEN             0x00031000u  /* ..0x10a35000 (incl. RAVE + code RAM) */

#define XPT_FE_IB_CTRL(n)       (0x10a04100u + 8u * (n))
#define XPT_FE_IB_SYNC_CNT(n)   (0x10a04104u + 8u * (n))
#define XPT_FE_PARSER_CTRL1(n)  (0x10a04180u + 0x10u * (n))
#define XPT_PID_TABLE(c)        (0x10a04800u + 4u * (c))
#define XPT_SPID(c)             (0x10a05000u + 4u * (c))

#define XPT_MSG_CTRL1           0x10a18000u
#define XPT_MSG_BUF_RESET       0x10a1800cu  /* write buffer #: reset RP/VP */
#define XPT_MSG_DAT_AVAIL(i)    (0x10a18080u + 4u * (i))   /* i = 0..3 */
#define XPT_MSG_BUF_CTRL1(i)    (0x10a18200u + 4u * (i))
#define XPT_MSG_BUF_CTRL2(i)    (0x10a18400u + 4u * (i))
#define XPT_MSG_DMA_BP(i)       (0x10a18600u + 4u * (i))
#define XPT_MSG_DMA_RP(i)       (0x10a18800u + 4u * (i))
#define XPT_MSG_DMA_VP(i)       (0x10a18a00u + 4u * (i))
#define XPT_MSG_GEN_FILT_EN(i)  (0x10a19000u + 4u * (i))
/* PID2BUF is a 128-bit PER-CHANNEL BUFFER BITMASK, not a buffer number:
 * 4 words per channel, bit (buf&31) of word (buf>>5) routes the channel to
 * message buffer `buf` (vendor ConfigPid2BufferMap disasm).  Writing the
 * buffer NUMBER here (old code) left the mask empty = route to NO buffer =
 * the engine consumed and dropped everything. */
#define XPT_MSG_PID2BUF_W(c, w) (0x10a1c000u + 0x10u * (c) + 4u * (w))
#define XPT_MSG_PID2BUF_BIT(b)  (1u << ((b) & 31u))

/* ---- RSBUFF / XCBUFF / pacing (reversed from nexus.ko BXPT_P_*Buf_Init,
 *      cross-checked vs BCM7340 RDB; see docs/xpt_capture_notes.md) --------
 *
 * The parser output does NOT reach the MSG record engine directly: every
 * packet is staged through per-band DRAM buffers that the vendor programs
 * in BXPT_Open and we must reproduce, or the MSG buffer never fills:
 *   parser band -> RS rate-smoothing buffers (RDBUFF + PMEM, group1/group3)
 *              -> per-client XC cross-connect buffer (MSG client, per band)
 *              -> MSG record DMA -> our ring.
 * Each band owns 6 pointer regs (BASE/END/WRITE/VALID/READ/WATERMARK, stride
 * 0x18) plus a 24-bit "BO" bandwidth word (stride 4) and one enable bit.
 * There is no clean pass-through/bypass bit (PR_FALLBACK/NO_RD_HANG only tune
 * hang behaviour), so the buffers must be backed by real RAM. */

/* RSBUFF block @ phys 0x10a15000 (BREG offset 0xa15000). */
#define RS_G1_PTR(b)            (0x10a15000u + 0x18u * (b))  /* RDBUFF ptrs   */
#define RS_G2_PTR(b)            (0x10a15300u + 0x18u * (b))  /* PBP  (unused) */
#define RS_G3_PTR(b)            (0x10a15600u + 0x18u * (b))  /* PMEM ptrs     */
#define RS_G1_BO(b)             (0x10a15900u + 4u * (b))     /* RDBUFF bw word*/
#define RS_G2_BO(b)             (0x10a15980u + 4u * (b))     /* PBP    bw word*/
#define RS_G3_BO(b)             (0x10a15a00u + 4u * (b))     /* PMEM   bw word*/
#define RS_EN_G1                0x10a15b08u                  /* RDBUFF enable */
#define RS_EN_G2                0x10a15b0cu                  /* PBP    enable */
#define RS_EN_G3                0x10a15b1cu                  /* PMEM   enable */
#define RS_CTRL_BASE            0x10a15b00u                  /* control window*/

/* XCBUFF block @ phys 0x10a16000.  Clients: RAVE, MSG, RMX0, RMX1; each has
 * an IBP set (16 bands) and a PBP set (6).  We only need MSG / IBP. */
#define XC_GLOBAL_CTRL          0x10a17840u                  /* low nibble=0xc*/
#define XC_MSG_IBP_PTR(b)       (0x10a16600u + 0x18u * (b))  /* MSG IBP ptrs  */
#define XC_MSG_IBP_BO(b)        (0x10a179b0u + 4u * (b))     /* MSG IBP bw    */
#define XC_MSG_IBP_EN           0x10a17814u                  /* MSG IBP enable*/
#define XC_RAVE_IBP_EN          0x10a17804u
#define XC_RAVE_PBP_EN          0x10a17800u
#define XC_MSG_PBP_EN           0x10a17810u
#define XC_RMX0_IBP_EN          0x10a17824u
#define XC_RMX0_PBP_EN          0x10a17820u
#define XC_RMX1_IBP_EN          0x10a17834u
#define XC_RMX1_PBP_EN          0x10a17830u

/* Pacing / bandwidth (40nm) — BXPT_Open, default settings (byte=0, mode=0). */
#define XPT_PACE0_CTRL          0x10a04680u
#define XPT_PACE0_VAL           0x10a0468cu
#define XPT_PACE1_CTRL          0x10a046a0u
#define XPT_PACE1_VAL           0x10a046acu
#define XPT_PACE_MAGIC          0x829eecdeu

/* Full XC client map (BXPT_P_XcBuf_Init disasm): per client an IBP pointer
 * table (16 bands x 0x18), a PBP pointer table (6 x 0x18), a per-band IBP
 * BO word table, and one enable reg per set.  PBP BO addresses are unclear
 * in the disasm, so they are left untouched (no PBP traffic anyway). */
struct xc_client {
    const char *name;
    uint32_t ibp_ptr, pbp_ptr, ibp_bo, en_ibp, en_pbp;
};
static const struct xc_client xc_clients[] = {
    { "RAVE", 0x10a16000u, 0x10a16300u, 0x10a178b0u, 0x10a17804u, 0x10a17800u },
    { "MSG",  0x10a16600u, 0x10a16900u, 0x10a179b0u, 0x10a17814u, 0x10a17810u },
    { "RMX0", 0x10a16c00u, 0x10a16f00u, 0x10a17ab0u, 0x10a17824u, 0x10a17820u },
    { "RMX1", 0x10a17200u, 0x10a17500u, 0x10a17bb0u, 0x10a17834u, 0x10a17830u },
};

/* SAM/filter word tables zeroed by BXPT_Open (0x200 words each). */
#define XPT_SAM_TBL0            0x10a1a000u
#define XPT_SAM_TBL1            0x10a1a800u
#define XPT_SAM_TBL2            0x10a1b000u

/* ---- XPT_RAVE (record engine, reversed from BXPT_Rave_* in nexus.ko) ----
 *
 * HISTORICAL NOTE, 2026-07-22: the RAVE path is NOT needed for whole-TS
 * capture.  The "no write engine ever moves" wall was the PID2BUF mapping
 * bug (see XPT_MSG_PID2BUF_W above): with the mask correct, the MSG engine
 * streams the full raw 188-byte TS to DRAM flawlessly (mode 1 BUF_CTRL1,
 * ~25 Mbps validated, zero resyncs) — `setup` + `capture` is the working
 * chain.  The RAVE code below is kept for experiments: with ucode loaded,
 * context/ITB/spots/flush all programmed per vendor disasm, the engine
 * still consumes exactly one XC burst and produces nothing; its engine
 * windows (0xa30000, ctx CDB block) read-fault post-arm and the release
 * reg reads back 0x440.  Unresolved, parked.
 *
 * Per-context regs: base 0xa2b200 + N*0x100 (8 contexts); CDB ring
 * pointers at +0x00 WRITE / +0x04 READ / +0x08 BASE / +0x0c END (24-bit
 * device-offset field, top byte preserved), record config at +0x68
 * (AV_MISC_CONFIG1, bit20 = CONTEXT_ENABLE = the arm) and friends.
 * Global init also clears three SRAM table regions and programs the CDB
 * size modeword at 0xa25858 (BXPT_Rave_OpenChannel first-open path). */
#define RAVE_UCODE_ADDR         0x10a30800u  /* 4096 words */
#define RAVE_UCODE_WORDS        4096u
#define RAVE_RELEASE_REG        0x10a30004u  /* write 0: engine runs */
#define RAVE_MODEWORD_REG       0x10a25858u  /* (old & 0x0c000005) | mode */
#define RAVE_MODEWORD_KEEP      0x0c000005u
#define RAVE_CLR1_LO            0x10a25974u  /* clear tables, inclusive */
#define RAVE_CLR1_HI            0x10a25d70u
#define RAVE_CLR2_LO            0x10a26174u
#define RAVE_CLR2_HI            0x10a26570u
#define RAVE_CLR3_LO            0x10a27200u
#define RAVE_CLR3_HI            0x10a2b1fcu
#define RAVE_CTX_BASE(n)        (0x10a2b200u + 0x100u * (n))
#define RAVE_CTX_CDB_WRITE      0x00u        /* CDB write ptr  (24-bit offset) */
#define RAVE_CTX_CDB_READ       0x04u        /* CDB read ptr                   */
#define RAVE_CTX_CDB_BASE       0x08u        /* CDB ring base                  */
#define RAVE_CTX_CDB_END        0x0cu        /* CDB ring end (base+size-1)     */
#define RAVE_CTX_CDB_VALID      0x10u        /* CDB valid ptr (hw-produced)    */
#define RAVE_CTX_CDB_WRAP       0x14u        /* CDB wrap ptr                   */
#define RAVE_CTX_WATERMARK      0x18u        /* (wm<<16)|wm, data-ready level   */
/* ITB ring (vendor ResetContext disasm): a record context ALWAYS owns an
 * index ring next to the CDB; with these left as uninitialised SRAM garbage
 * the engine consumes one XC burst and wedges before the first CDB write —
 * that was the never-resolved "no engine writes DRAM" wall. */
#define RAVE_CTX_ITB_CFG        0x20u        /* ResetContext writes 0x03000100 */
#define RAVE_CTX_ITB_WRITE      0x24u
#define RAVE_CTX_ITB_READ       0x28u
#define RAVE_CTX_ITB_BASE       0x2cu
#define RAVE_CTX_ITB_END        0x30u        /* mirror CDB_END: assume rd-fault */
#define RAVE_CTX_ITB_VALID      0x34u
#define RAVE_CTX_ITB_WRAP       0x38u
#define RAVE_ITB_CFG_VAL        0x03000100u
#define RAVE_CTX_CFG_3C         0x3cu
#define RAVE_CTX_MISC_CONFIG1   0x68u        /* AV_MISC_CONFIG1; bit20=ENABLE   */
#define RAVE_CTX_CFG_70         0x70u
#define RAVE_CTX_PIDQ_ENABLE    0xa4u        /* bit24 = PID/queue active        */
#define RAVE_CTX_REC_A8         0xa8u        /* SetRecordConfig: mode=1 raw TS  */
#define RAVE_CTX_REC_AC         0xacu
#define RAVE_CTX_REC_B0         0xb0u        /* (old & ~0x3d) | 0x38            */
#define RAVE_CTX_REC_B4         0xb4u
#define RAVE_CTX_ENABLE_BIT     (1u << 20)   /* CONTEXT_ENABLE (the final arm) */
#define RAVE_CTX_PIDQ_BIT       (1u << 24)   /* ctx+0xa4 PID/queue enable      */
#define RAVE_QUEUE_TBL(q)       (0x10a29100u + 0x40u * (q))
#define RAVE_QUEUE_HEAD         0x00u        /* ring read index  (mod 8)       */
#define RAVE_QUEUE_TAIL         0x04u        /* ring write index (mod 8)       */
#define RAVE_QUEUE_PRIMARY      0x08u        /* primary pid channel            */
#define RAVE_QUEUE_SLOT(i)      (0x0cu + 4u * (i))  /* pushed pid channels     */
/* Queue-allocation register, per input band: ((band+0x40)<<5 + 0x289c97)<<2.
 * band 0 -> phys 0x10a2925c, stride 0x80 (from BXPT_Rave_PushPidChannel). */
#define RAVE_QALLOC(band)       ((((((band) + 0x40u) << 5) + 0x289c97u) << 2) \
                                 + 0x10000000u)
/* AV_MISC_CONFIG1 record value (pre-arm): OUTPUT_FORMAT=0 + INPUT_ES=0 =
 * passthrough TS, PES_SYNC=3, SHIFT bit29.  Keep-mask preserves reserved. */
#define RAVE_MISC_KEEP          0x539f0000u
#define RAVE_MISC_TS_PASSTHRU   0x2c000000u
/* SPID destination bit for RAVE = bit 5 of the top byte (dest 5). */
#define SPID_DEST_RAVE          0x20000000u

/* CDB-size modeword values, keyed by size in KB (vendor switch table). */
static uint32_t rave_modeword(uint32_t size_kb)
{
    switch (size_kb) {
    case 0x20:   return 0x01822008u;
    case 0x40:   return 0x11822008u;
    case 0x80:   return 0x21822008u;
    case 0x100:  return 0x31822008u;
    case 0x200:  return 0x51822008u;
    case 0x400:  return 0x41822008u;
    case 0x800:  return 0x61822008u;
    case 0x1000: return 0x71822008u;
    default:     return 0;
    }
}

/* PID_CHANNEL_TABLE word written by the BXPT_Open clear loop. */
#define PID_TABLE_OPEN_DEFAULT  0x10000000u

/* Per-band DRAM buffer size for the active band (RDBUFF/PMEM/XC each).  The
 * vendor uses 0x32000 (200K) per band; 3 of those (600K) overflow the 512K
 * spare, so we shrink to 128K each (384K total) — ample for one ~27 Mbps mux
 * drained continuously.  The BO bandwidth word is buffer-size independent. */
#define RS_BUFSZ                0x20000u
#define RS_BO_27MBPS            0x1780u   /* vendor value for the 27 Mbps default */
#define RS_NUM_IBP_BANDS        16u       /* 7231 has 16 IBP bands */

/* IB_CTRL bits */
#define IB_CLOCK_POL            (1u << 0)
#define IB_SYNC_POL             (1u << 1)
#define IB_DATA_POL             (1u << 2)
#define IB_SYNC_DETECT_EN       (1u << 6)
#define IB_USE_SYNC_AS_VALID    (1u << 7)
#define IB_FORCE_VALID          (1u << 8)
#define IB_PARALLEL_SEL         (1u << 10)
/* fields we own on writes: bits[10:0] + PKT_LENGTH bits[23:16] */
#define IB_WR_FIELDS            0x00ff07ffu

/* PARSER_CTRL1 bits */
#define PARSER_ENABLE           (1u << 0)
#define PARSER_ALL_PASS         (1u << 1)
#define PARSER_CC_IGNORE        (1u << 3)
#define PARSER_ACCEPT_NULL      (1u << 4)
/* fields we own: en/allpass/cc/null bits[4:0]-ish + PACKET_TYPE[7:5] +
 * INPUT_SEL[11:8] + PKT_LENGTH[19:12]; TIMEBASE_SEL[24:21] etc. preserved */
#define PARSER_WR_FIELDS        0x000ffffbu

/* PID_CHANNEL_TABLE: vendor RMW preserves 0xf7c0f000 in all-pass config
 * and 0xf7c0e000 in PID-matching mode (bit12 is PID bit 12); we also own
 * the enable bit14 in both. */
#define PID_KEEP_MASK           0xf7c0f000u
#define PID_KEEP_MASK_PIDMATCH  0xf7c0e000u
#define PID_ENABLE              (1u << 14)

static int fd = -1;                    /* /dev/mem */
static volatile uint8_t *xpt;          /* mapping of XPT_MAP_BASE..+LEN */

static void mmio_sync(void)
{
#ifdef __mips__
    __asm__ __volatile__("sync" ::: "memory");
#endif
}

static uint32_t rreg(uint32_t phys)
{
    return *(volatile uint32_t *)(xpt + (phys - XPT_MAP_BASE));
}

static void wreg(uint32_t phys, uint32_t v)
{
    *(volatile uint32_t *)(xpt + (phys - XPT_MAP_BASE)) = v;
    mmio_sync();
}

/* Write WITHOUT reading back — for write-only registers whose read faults
 * the GISB bus (some RAVE CDB pointer regs: END/DEPTH read-fault). */
static void wr_only(const char *name, uint32_t phys, uint32_t v)
{
    wreg(phys, v);
    fprintf(stderr, "  %-18s [%08x] <= %08x  (write-only)\n", name, phys, v);
}

/* Write + read back + log to stderr (RP/VP may legitimately differ). */
static uint32_t wrv(const char *name, uint32_t phys, uint32_t v)
{
    uint32_t rb;
    wreg(phys, v);
    rb = rreg(phys);
    fprintf(stderr, "  %-18s [%08x] <= %08x  rb=%08x%s\n",
            name, phys, v, rb, rb == v ? "" : "  (DIFFERS)");
    return rb;
}

static void map_xpt(void)
{
    void *m = mmap(NULL, XPT_MAP_LEN, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, XPT_MAP_BASE);
    if (m == MAP_FAILED) { perror("mmap XPT block"); exit(1); }
    xpt = m;
}

/* ------------------------- raw peek/poke helpers ------------------------- */

static volatile uint32_t *map_word(uint32_t phys, void **page)
{
    void *m = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   fd, phys & PAGEMASK);
    if (m == MAP_FAILED) { perror("mmap"); exit(1); }
    *page = m;
    return (volatile uint32_t *)((char *)m + (phys & (PAGE - 1)));
}

/* --------------------------------- config -------------------------------- */

struct cfg {
    uint32_t ib, parser, chan, buf;
    uint32_t phys, size;
    uint32_t dest;                     /* SPID top-byte destination bits */
    uint32_t pid;                      /* --pid: PID-matching mode */
    int have_pid;                      /* 0 = all-pass (default) */
    int parallel, clkpol, syncpol, datapol, forcevalid, syncasvalid;
    int have_phys, have_size;
    int no_rsbuf, no_xc;               /* skip RS / XC init (experiments) */
    uint32_t ctx, queue;               /* RAVE context / queue number     */
    uint32_t itba, itbs;               /* RAVE ITB ring phys / size       */
    uint32_t a8, misc;                 /* RAVE REC_A8 / MISC_CONFIG1 vals */
    uint32_t bufmode;                  /* MSG BUF_CTRL1 output mode       */
    uint32_t level;                    /* rave bring-up bisect level 0..4 */
    int rave_wm, no_parser;            /* RAVE watermark / skip front end */
    int pbmode;                        /* PID channel in playback-band mode */
    const char *udp;                   /* --udp host:port (rave_drain)    */
};

static int size_code(uint32_t size)
{
    for (int code = 0; code <= 15; code++)
        if ((0x400u << code) == size)
            return code;
    return -1;
}

static uint32_t parse_size(const char *s)
{
    char *end;
    uint32_t v = strtoul(s, &end, 0);
    if (*end == 'k' || *end == 'K') { v <<= 10; end++; }
    else if (*end == 'm' || *end == 'M') { v <<= 20; end++; }
    if (*end || size_code(v) < 0) {
        fprintf(stderr, "bad size '%s' (power of two, 1K..32M, e.g. 512K)\n",
                s);
        exit(1);
    }
    if (size_code(v) > 9)
        fprintf(stderr, "warning: size code %d > 9 (512K) — only codes "
                "0..9 are validated\n", size_code(v));
    return v;
}

static void usage(void)
{
    fprintf(stderr,
"usage: xpt_cap <cmd> [options]\n"
"  status  [-i ib] [-p parser] [-c chan] [-b buf]\n"
"  setup   [-i ib] [-p parser] [-c chan] [-b buf] [-a phys] [-s size]\n"
"          [--pid <pid>] [--parallel] [--clkpol] [--syncpol] [--datapol]\n"
"          [--forcevalid] [--syncasvalid] [--dest <destbits>]\n"
"          [--no-rsbuf] [--no-xc]\n"
"          (--pid: PID-matching mode instead of all-pass; --pid 0x1fff\n"
"           captures the null packets of an unlocked MxL = chain test)\n"
"          (--no-rsbuf/--no-xc: skip the RS / XC staging-buffer init that\n"
"           feeds the MSG engine — for A/B testing only; both on by default)\n"
"  openinit [-p parser] [-a phys] [-s size]\n"
"          (vendor BXPT_Open replica: clear all PID/SPID/MSG/SAM tables,\n"
"           back+enable every RS/XC band of every client with valid rings\n"
"           in reserved RAM; run AFTER xptreset, THEN setup --no-rsbuf\n"
"           --no-xc)\n"
"  addpid  -c <chan> --pid <pid> [-b buf] [-p parser]\n"
"          (route one extra PID-matching channel into an already-set-up\n"
"           buffer: PAT+PMT+AV multi-PID service filter — the all-pass\n"
"           full mux drops ~6%% at the record path, PID filtering doesn't)\n"
"  capture [-b buf] [-a phys] [-s size] [--udp host:port]\n"
"          (MSG ring -> stdout, or 1316-byte UDP/TS datagrams for VLC\n"
"           udp://@:port — THE working record path: setup + capture)\n"
"  rave    [-p band] [-c chan] [-a phys] [-s size] [--ctx n] [--queue n]\n"
"          [--itba <phys>] [--itbs <size>] [--pid <pid>] [--no-parser]\n"
"          [--wm] [-i ib] [polarity opts]\n"
"          (open+arm a RAVE record context; phys MUST be in low 16 MB —\n"
"           the CDB pointer is a 24-bit device offset with no high window.\n"
"           ITB ring defaults to 128K @0x00d80000: a record context always\n"
"           owns an index ring; garbage ITB/VALID/WRAP pointers wedge the\n"
"           engine before its first CDB write)\n"
"  rave_drain [-a phys] [--ctx n] [--udp host:port]\n"
"          (RAVE CDB ring -> stdout, or 1316-byte UDP/TS datagrams for\n"
"           VLC udp://@:port)\n"
"  raveinit <ucode.bin> [-s cdbsize]\n"
"          (global RAVE bring-up: clear tables, load 16K microcode into\n"
"           code RAM @0xa30800, release engine, CDB-size modeword; run\n"
"           once before any RAVE context setup — THE step the vendor\n"
"           does in BXPT_Rave_OpenChannel that we were missing)\n"
"  stop    [-p parser] [-c chan] [-b buf]\n"
"  xptreset    (pulse SUN_TOP_CTRL sw-init bit 18 = whole-XPT reset, like\n"
"               vendor BXPT_P_ResetTransport; run BEFORE setup)\n"
"  peek <addr> [len]\n"
"  poke <addr> <val>\n"
"defaults: ib=0 parser=0 chan=0 buf=0 phys=0x0ff00000 size=512K dest=0x80\n");
    exit(1);
}

static void parse_opts(int argc, char **argv, struct cfg *c)
{
    static const struct option lo[] = {
        { "parallel",    0, 0, 1 },
        { "clkpol",      0, 0, 2 },
        { "syncpol",     0, 0, 3 },
        { "datapol",     0, 0, 4 },
        { "forcevalid",  0, 0, 5 },
        { "syncasvalid", 0, 0, 6 },
        { "dest",        1, 0, 7 },
        { "pid",         1, 0, 8 },
        { "no-rsbuf",    0, 0, 9 },
        { "no-xc",       0, 0, 10 },
        { "ctx",         1, 0, 11 },
        { "queue",       1, 0, 12 },
        { "wm",          0, 0, 13 },
        { "no-parser",   0, 0, 14 },
        { "pbmode",      0, 0, 15 },
        { "udp",         1, 0, 16 },
        { "itba",        1, 0, 17 },
        { "itbs",        1, 0, 18 },
        { "a8",          1, 0, 19 },
        { "misc",        1, 0, 20 },
        { "level",       1, 0, 21 },
        { "bufmode",     1, 0, 22 },
        { 0, 0, 0, 0 }
    };
    int opt;

    c->ib = 0; c->parser = 0; c->chan = 0; c->buf = 0;
    c->phys = 0x0ff00000u; c->size = 512u * 1024u; c->dest = 0x80;
    c->pid = 0; c->have_pid = 0;
    c->parallel = c->clkpol = c->syncpol = c->datapol = 0;
    c->forcevalid = c->syncasvalid = 0;
    c->have_phys = c->have_size = 0;
    c->no_rsbuf = c->no_xc = 0;
    c->ctx = 0; c->queue = 0; c->rave_wm = 0; c->no_parser = 0;
    c->pbmode = 0; c->udp = NULL;
    c->itba = 0x00d80000u; c->itbs = 0x20000u;   /* in the low /memreserve/ */
    /* REC_A8 bit0 is a config bool (vendor RMWs only bit0; NEXUS default =
     * timestamps OFF).  MISC_CONFIG1 record default: bit29 | bits27:26=01
     * (what vendor ResetContext forces for record) | bit22 (format eTS). */
    c->a8 = 0; c->misc = 0x24400000u;
    c->level = 4;   /* --level: 0=orig 1=+VALID/WRAP 2=+ITB 3=+spots 4=all */
    c->bufmode = 1; /* MSG output mode: 1 works; vendor record uses 3|0x100 */

    while ((opt = getopt_long(argc, argv, "i:p:c:b:a:s:", lo, NULL)) != -1) {
        switch (opt) {
        case 'i': c->ib     = strtoul(optarg, NULL, 0); break;
        case 'p': c->parser = strtoul(optarg, NULL, 0); break;
        case 'c': c->chan   = strtoul(optarg, NULL, 0); break;
        case 'b': c->buf    = strtoul(optarg, NULL, 0); break;
        case 'a': c->phys   = strtoul(optarg, NULL, 0); c->have_phys = 1; break;
        case 's': c->size   = parse_size(optarg);       c->have_size = 1; break;
        case 1:   c->parallel = 1;    break;
        case 2:   c->clkpol = 1;      break;
        case 3:   c->syncpol = 1;     break;
        case 4:   c->datapol = 1;     break;
        case 5:   c->forcevalid = 1;  break;
        case 6:   c->syncasvalid = 1; break;
        case 7:   c->dest = strtoul(optarg, NULL, 0) & 0xff; break;
        case 8:   c->pid  = strtoul(optarg, NULL, 0) & 0x1fff;
                  c->have_pid = 1; break;
        case 9:   c->no_rsbuf = 1; break;
        case 10:  c->no_xc = 1;    break;
        case 11:  c->ctx   = strtoul(optarg, NULL, 0); break;
        case 12:  c->queue = strtoul(optarg, NULL, 0); break;
        case 13:  c->rave_wm = 1;   break;
        case 14:  c->no_parser = 1; break;
        case 15:  c->pbmode = 1;    break;
        case 16:  c->udp = optarg;  break;
        case 17:  c->itba = strtoul(optarg, NULL, 0); break;
        case 18:  c->itbs = strtoul(optarg, NULL, 0); break;
        case 19:  c->a8   = strtoul(optarg, NULL, 0); break;
        case 20:  c->misc = strtoul(optarg, NULL, 0); break;
        case 21:  c->level = strtoul(optarg, NULL, 0); break;
        case 22:  c->bufmode = strtoul(optarg, NULL, 0); break;
        default:  usage();
        }
    }
    if (c->ib > 6 || c->parser > 3 || c->chan > 255 || c->buf > 127 ||
        c->ctx > 7) {
        fprintf(stderr, "range: ib 0..6, parser 0..3, chan 0..255, "
                        "buf 0..127, ctx 0..7\n");
        exit(1);
    }
    if (c->phys & 0x3ffu) {
        fprintf(stderr, "phys addr must be 1K-aligned (DMA_BP is in 1K "
                        "units)\n");
        exit(1);
    }
}

/* --------------------------------- status -------------------------------- */

static void do_status(const struct cfg *c)
{
    printf("=== XPT_FE input bands ===\n");
    for (uint32_t n = 0; n <= 6; n++) {
        uint32_t v = rreg(XPT_FE_IB_CTRL(n));
        uint32_t s = rreg(XPT_FE_IB_SYNC_CNT(n));
        printf("  IB%u  CTRL=%08x  pktlen=%-3u%s%s%s%s%s%s  SYNC_COUNT=%08x\n",
               n, v, (v >> 16) & 0xff,
               (v & IB_PARALLEL_SEL)     ? " PAR"   : " SER",
               (v & IB_SYNC_DETECT_EN)   ? " SYNCDET" : "",
               (v & IB_FORCE_VALID)      ? " FVALID"  : "",
               (v & IB_USE_SYNC_AS_VALID)? " S=V"     : "",
               (v & IB_CLOCK_POL)        ? " CLK-"    : "",
               (v & (IB_SYNC_POL|IB_DATA_POL)) ? " POL!" : "",
               s);
    }

    printf("=== parsers ===\n");
    for (uint32_t n = 0; n <= 3; n++) {
        uint32_t v = rreg(XPT_FE_PARSER_CTRL1(n));
        printf("  PARSER%u  CTRL1=%08x  %s%s in=IB%u pktlen=%u type=%u "
               "tb=%u\n",
               n, v,
               (v & PARSER_ENABLE)   ? "EN "      : "off ",
               (v & PARSER_ALL_PASS) ? "ALLPASS " : "",
               (v >> 8) & 0xf, (v >> 12) & 0xff, (v >> 5) & 0x7,
               (v >> 21) & 0xf);
    }

    printf("=== XPT_MSG ===\n");
    printf("  MSG_CTRL1=%08x\n", rreg(XPT_MSG_CTRL1));
    printf("  BUF_DAT_AVAIL: %08x %08x %08x %08x  (buffers 0-31 .. 96-127)\n",
           rreg(XPT_MSG_DAT_AVAIL(0)), rreg(XPT_MSG_DAT_AVAIL(1)),
           rreg(XPT_MSG_DAT_AVAIL(2)), rreg(XPT_MSG_DAT_AVAIL(3)));

    uint32_t bp = rreg(XPT_MSG_DMA_BP(c->buf));
    uint32_t rp = rreg(XPT_MSG_DMA_RP(c->buf));
    uint32_t vp = rreg(XPT_MSG_DMA_VP(c->buf));
    uint32_t sz = 0x400u << (bp >> 28);
    printf("  buf %u: CTRL1=%08x CTRL2=%08x GEN_FILT_EN=%08x\n",
           c->buf, rreg(XPT_MSG_BUF_CTRL1(c->buf)),
           rreg(XPT_MSG_BUF_CTRL2(c->buf)),
           rreg(XPT_MSG_GEN_FILT_EN(c->buf)));
    printf("         BP=%08x (base=0x%08x size=%u) RP=%08x VP=%08x "
           "depth=%u\n",
           bp, (bp & 0x3fffffu) << 10, sz, rp, vp,
           (vp - rp) & (sz - 1));

    uint32_t band = c->parser;
    printf("=== RS staging (band %u) ===\n", band);
    printf("  EN: RDBUF(g1)=%08x PBP(g2)=%08x PMEM(g3)=%08x\n",
           rreg(RS_EN_G1), rreg(RS_EN_G2), rreg(RS_EN_G3));
    printf("  ctrl[b00..b44]:");
    for (uint32_t a = RS_CTRL_BASE; a <= RS_CTRL_BASE + 0x44u; a += 4)
        printf(" %08x", rreg(a));
    printf("\n");
    for (int g = 0; g < 2; g++) {
        uint32_t t = g ? RS_G3_PTR(band) : RS_G1_PTR(band);
        uint32_t bo = g ? rreg(RS_G3_BO(band)) : rreg(RS_G1_BO(band));
        printf("  %s BASE=%08x END=%08x WR=%08x VLD=%08x RD=%08x WM=%08x "
               "BO=%06x\n", g ? "PMEM " : "RDBUF",
               rreg(t + 0x00), rreg(t + 0x04), rreg(t + 0x08),
               rreg(t + 0x0c), rreg(t + 0x10), rreg(t + 0x14),
               bo & 0xffffffu);
    }
    printf("=== XC MSG (band %u) ===\n", band);
    printf("  MSG_IBP_EN=%08x  global=%08x\n",
           rreg(XC_MSG_IBP_EN), rreg(XC_GLOBAL_CTRL));
    printf("  MSG   BASE=%08x END=%08x WR=%08x VLD=%08x RD=%08x WM=%08x "
           "BO=%06x\n",
           rreg(XC_MSG_IBP_PTR(band) + 0x00), rreg(XC_MSG_IBP_PTR(band) + 0x04),
           rreg(XC_MSG_IBP_PTR(band) + 0x08), rreg(XC_MSG_IBP_PTR(band) + 0x0c),
           rreg(XC_MSG_IBP_PTR(band) + 0x10), rreg(XC_MSG_IBP_PTR(band) + 0x14),
           rreg(XC_MSG_IBP_BO(band)) & 0xffffffu);

    uint32_t pid = rreg(XPT_PID_TABLE(c->chan));
    printf("=== PID channel %u ===\n", c->chan);
    printf("  PID_TABLE=%08x  pid=0x%04x band=%u %s\n",
           pid, pid & 0x1fff, (pid >> 16) & 0x3f,
           (pid & PID_ENABLE) ? "EN" : "off");
    printf("  SPID=%08x (dest byte=0x%02x)  PID2BUF mask=%08x %08x %08x "
           "%08x\n",
           rreg(XPT_SPID(c->chan)), rreg(XPT_SPID(c->chan)) >> 24,
           rreg(XPT_MSG_PID2BUF_W(c->chan, 0)),
           rreg(XPT_MSG_PID2BUF_W(c->chan, 1)),
           rreg(XPT_MSG_PID2BUF_W(c->chan, 2)),
           rreg(XPT_MSG_PID2BUF_W(c->chan, 3)));
}

/* ----------------------- RS / XC staging buffers ------------------------- */

/* Program one band's ring pointers exactly like the vendor helper
 * (BXPT_P_RsBuf_Init -> 0x33a7a8): BASE=off, END=off+size-1, and the
 * WRITE/VALID/READ "last-consumed" pointers = off-1 (empty ring), WM=0. */
static void band_ptrs(const char *tag, uint32_t tbl_band, uint32_t off,
                      uint32_t size, int verbose)
{
    if (verbose) {
        char n[24];
        snprintf(n, sizeof n, "%s BASE", tag);  wrv(n, tbl_band + 0x00, off);
        snprintf(n, sizeof n, "%s END",  tag);  wrv(n, tbl_band + 0x04,
                                                    off + size - 1);
        snprintf(n, sizeof n, "%s WR",   tag);  wrv(n, tbl_band + 0x08,
                                                    off - 1);
        snprintf(n, sizeof n, "%s VLD",  tag);  wrv(n, tbl_band + 0x0c,
                                                    off - 1);
        snprintf(n, sizeof n, "%s RD",   tag);  wrv(n, tbl_band + 0x10,
                                                    off - 1);
        snprintf(n, sizeof n, "%s WM",   tag);  wrv(n, tbl_band + 0x14, 0);
    } else {
        wreg(tbl_band + 0x00, off);
        wreg(tbl_band + 0x04, off + size - 1);
        wreg(tbl_band + 0x08, off - 1);
        wreg(tbl_band + 0x0c, off - 1);
        wreg(tbl_band + 0x10, off - 1);
        wreg(tbl_band + 0x14, 0);
    }
}

static void pacing_init(void)
{
    wrv("PACE0_CTRL", XPT_PACE0_CTRL,
        (rreg(XPT_PACE0_CTRL) & ~0x33u) | 0x30u | 0x02u);
    wrv("PACE0_VAL",  XPT_PACE0_VAL,  XPT_PACE_MAGIC);
    wrv("PACE1_CTRL", XPT_PACE1_CTRL,
        (rreg(XPT_PACE1_CTRL) & ~0x33u) | 0x30u | 0x02u);
    wrv("PACE1_VAL",  XPT_PACE1_VAL,  XPT_PACE_MAGIC);
}

/* Reproduce the vendor's per-band staging setup for the single band we use
 * (band = parser number, matching the PID_TABLE band field).  All other IBP
 * bands get a shared 256-byte dummy ring (like the vendor does for inactive
 * bands via BXPT_P_AllocSharedXcRsBuffer) and stay disabled, so an unbacked
 * band can never hang the block.  Buffers live in the reserved RAM right
 * after the MSG ring. */
static void do_init_buffers(const struct cfg *c)
{
    uint32_t rsmem = c->phys + c->size;        /* spare reserved region  */
    uint32_t rdbuf = rsmem;                     /* RS RDBUFF (group1)     */
    uint32_t pmem  = rsmem + 1u * RS_BUFSZ;     /* RS PMEM   (group3)     */
    uint32_t xcbuf = rsmem + 2u * RS_BUFSZ;     /* XC MSG buffer          */
    uint32_t dummy = rsmem + 3u * RS_BUFSZ;     /* shared 256B dummy      */
    uint32_t band  = c->parser;                 /* IBP band = parser band */
    uint32_t b;

    fprintf(stderr, "  buffers: RDBUF=0x%08x PMEM=0x%08x XC=0x%08x "
            "dummy=0x%08x (each %uK, band %u)\n",
            rdbuf, pmem, xcbuf, dummy, RS_BUFSZ >> 10, band);

    /* Pacing / bandwidth arbiter (40nm), vendor default formula. */
    pacing_init();

    if (!c->no_rsbuf) {
        /* Inactive IBP bands -> shared dummy, both RDBUFF and PMEM groups. */
        for (b = 0; b < RS_NUM_IBP_BANDS; b++) {
            if (b == band)
                continue;
            band_ptrs("dmy", RS_G1_PTR(b), dummy, 0x100u, 0);
            band_ptrs("dmy", RS_G3_PTR(b), dummy, 0x100u, 0);
        }
        /* Active band -> real RDBUFF + PMEM, with the 27 Mbps BO word. */
        band_ptrs("RS/RDBUF", RS_G1_PTR(band), rdbuf, RS_BUFSZ, 1);
        band_ptrs("RS/PMEM",  RS_G3_PTR(band), pmem,  RS_BUFSZ, 1);
        wrv("RS/RDBUF BO", RS_G1_BO(band),
            (rreg(RS_G1_BO(band)) & 0xff000000u) | RS_BO_27MBPS);
        wrv("RS/PMEM BO",  RS_G3_BO(band),
            (rreg(RS_G3_BO(band)) & 0xff000000u) | RS_BO_27MBPS);
        /* Enable only our band; PBP off. */
        wrv("RS_EN_G1", RS_EN_G1, 1u << band);
        wrv("RS_EN_G3", RS_EN_G3, 1u << band);
        wrv("RS_EN_G2", RS_EN_G2, 0);
    } else {
        fprintf(stderr, "  RS init skipped (--no-rsbuf)\n");
    }

    if (!c->no_xc) {
        /* Global XC control low nibble = 0xc (vendor RMW). */
        wrv("XC_GLOBAL", XC_GLOBAL_CTRL,
            (rreg(XC_GLOBAL_CTRL) & ~0xfu) | 0xcu);
        /* Silence every other client so an unbacked band can't stall XC. */
        wrv("XC_RAVE_IBP_EN", XC_RAVE_IBP_EN, 0);
        wrv("XC_RAVE_PBP_EN", XC_RAVE_PBP_EN, 0);
        wrv("XC_MSG_PBP_EN",  XC_MSG_PBP_EN,  0);
        wrv("XC_RMX0_IBP_EN", XC_RMX0_IBP_EN, 0);
        wrv("XC_RMX0_PBP_EN", XC_RMX0_PBP_EN, 0);
        wrv("XC_RMX1_IBP_EN", XC_RMX1_IBP_EN, 0);
        wrv("XC_RMX1_PBP_EN", XC_RMX1_PBP_EN, 0);
        /* MSG client, IBP: dummy for inactive bands, real for our band. */
        for (b = 0; b < RS_NUM_IBP_BANDS; b++)
            if (b != band)
                band_ptrs("dmy", XC_MSG_IBP_PTR(b), dummy, 0x100u, 0);
        band_ptrs("XC/MSG", XC_MSG_IBP_PTR(band), xcbuf, RS_BUFSZ, 1);
        wrv("XC/MSG BO", XC_MSG_IBP_BO(band),
            (rreg(XC_MSG_IBP_BO(band)) & 0xff000000u) | RS_BO_27MBPS);
        wrv("XC_MSG_IBP_EN", XC_MSG_IBP_EN, 1u << band);
    } else {
        fprintf(stderr, "  XC init skipped (--no-xc)\n");
    }
}

/* -------------------------------- openinit ------------------------------- */

/* Bump allocator over the spare reserved RAM after the MSG ring. */
static uint32_t ring_cursor, ring_limit;

static uint32_t ring_alloc(uint32_t size)
{
    uint32_t a = ring_cursor;
    ring_cursor += size;
    if (ring_cursor > ring_limit) {
        fprintf(stderr, "openinit: out of reserved RAM (cursor 0x%08x > "
                "limit 0x%08x)\n", ring_cursor, ring_limit);
        exit(1);
    }
    return a;
}

#define RING_SMALL  0x800u             /* idle band: valid 2K ring  */
#define RING_BIG    0x8000u            /* active band: 32K ring     */

/* Faithful replica of the register state the vendor's BXPT_Open leaves
 * behind (disasm of BXPT_Open + BXPT_P_RsBuf_Init + BXPT_P_XcBuf_Init):
 * every routing table cleared, every RS/XC band of every client backed by
 * a valid ring in reserved RAM and enabled, pacing armed.  Meant to run
 * right after `xptreset` (the vendor always pairs them), with `setup
 * --no-rsbuf --no-xc` afterwards for the capture chain itself.  This is
 * the "reinit everything" step we were missing: stale SRAM garbage in
 * those tables (they survive both sw-init and warm reboot) can route
 * packets at disabled XC clients and wedge the whole front end.  */
static void do_openinit(const struct cfg *c)
{
    uint32_t band = c->parser;
    uint32_t i, b;

    ring_cursor = c->phys + c->size;
    ring_limit  = c->phys + 0x100000u;  /* 1 MB /memreserve/ total */

    fprintf(stderr, "openinit: BXPT_Open replica, active band %u, rings at "
            "0x%08x..0x%08x\n", band, ring_cursor, ring_limit);

    /* 1. Bandwidth pacing (vendor: right after ResetTransport). */
    pacing_init();

    /* 2. PID channel + SPID destination tables, all 256 channels. */
    for (i = 0; i < 256; i++) {
        wreg(XPT_PID_TABLE(i), PID_TABLE_OPEN_DEFAULT);
        wreg(XPT_SPID(i), 0);
    }
    fprintf(stderr, "  PID_TABLE[0..255] <= %08x, SPID[0..255] <= 0\n",
            PID_TABLE_OPEN_DEFAULT);

    /* 3. MSG buffer config + PID2BUF map, all 128 buffers / 256 chans. */
    for (i = 0; i < 128; i++) {
        wreg(XPT_MSG_BUF_CTRL1(i), 0);
        wreg(XPT_MSG_BUF_CTRL2(i), 0);
        wreg(XPT_MSG_DMA_BP(i), 0);
        wreg(XPT_MSG_GEN_FILT_EN(i), 0);
    }
    for (i = 0; i < 256; i++) {
        wreg(XPT_MSG_PID2BUF_W(i, 0), 0);
        wreg(XPT_MSG_PID2BUF_W(i, 1), 0);
        wreg(XPT_MSG_PID2BUF_W(i, 2), 0);
        wreg(XPT_MSG_PID2BUF_W(i, 3), 0);
    }
    fprintf(stderr, "  MSG BUF_CTRL1/2, DMA_BP, GEN_FILT_EN[0..127] <= 0; "
            "PID2BUF[0..255] <= 0\n");

    /* 4. SAM/filter tables (BXPT_Open zeroes 0x200 words in each). */
    for (i = 0; i < 0x800; i += 4) {
        wreg(XPT_SAM_TBL0 + i, 0);
        wreg(XPT_SAM_TBL1 + i, 0);
        wreg(XPT_SAM_TBL2 + i, 0);
    }
    fprintf(stderr, "  SAM tables 0xa1a000/0xa1a800/0xa1b000 <= 0\n");

    /* 5. RS rate-smoothing: disable, back every band with a valid ring,
     * program the 27 Mbps BO word, re-enable all (hw default is
     * all-enabled; vendor default settings do the same). */
    wreg(RS_EN_G1, 0);
    wreg(RS_EN_G2, 0);
    wreg(RS_EN_G3, 0);
    for (b = 0; b < RS_NUM_IBP_BANDS; b++) {
        uint32_t sz = (b == band) ? RING_BIG : RING_SMALL;
        band_ptrs("RS/G1", RS_G1_PTR(b), ring_alloc(sz), sz, b == band);
        wreg(RS_G1_BO(b), (rreg(RS_G1_BO(b)) & 0xff000000u) | RS_BO_27MBPS);
    }
    for (b = 0; b < 6; b++) {
        band_ptrs("RS/G2", RS_G2_PTR(b), ring_alloc(RING_SMALL),
                  RING_SMALL, 0);
        wreg(RS_G2_BO(b), (rreg(RS_G2_BO(b)) & 0xff000000u) | RS_BO_27MBPS);
    }
    for (b = 0; b < RS_NUM_IBP_BANDS; b++) {
        uint32_t sz = (b == band) ? RING_BIG : RING_SMALL;
        band_ptrs("RS/G3", RS_G3_PTR(b), ring_alloc(sz), sz, b == band);
        wreg(RS_G3_BO(b), (rreg(RS_G3_BO(b)) & 0xff000000u) | RS_BO_27MBPS);
    }
    wrv("RS_EN_G1", RS_EN_G1, 0xffff);
    wrv("RS_EN_G2", RS_EN_G2, 0x3f);
    wrv("RS_EN_G3", RS_EN_G3, 0xffff);

    /* 6. XC cross-connect, all 4 clients: same discipline. */
    wrv("XC_GLOBAL", XC_GLOBAL_CTRL, (rreg(XC_GLOBAL_CTRL) & ~0xfu) | 0xcu);
    for (i = 0; i < 4; i++) {
        const struct xc_client *cl = &xc_clients[i];

        wreg(cl->en_ibp, 0);
        wreg(cl->en_pbp, 0);
        for (b = 0; b < RS_NUM_IBP_BANDS; b++) {
            int active = (i == 1 && b == band);   /* MSG client, our band */
            uint32_t sz = active ? RING_BIG : RING_SMALL;
            char tag[16];
            snprintf(tag, sizeof tag, "XC/%s", cl->name);
            band_ptrs(tag, cl->ibp_ptr + 0x18u * b, ring_alloc(sz), sz,
                      active);
            wreg(cl->ibp_bo + 4u * b,
                 (rreg(cl->ibp_bo + 4u * b) & 0xff000000u) | RS_BO_27MBPS);
        }
        for (b = 0; b < 6; b++) {
            /* PBP BO table sits 0x80 above the IBP BO table. */
            uint32_t bo = cl->ibp_bo + 0x80u + 4u * b;
            band_ptrs("XC/pbp", cl->pbp_ptr + 0x18u * b,
                      ring_alloc(RING_SMALL), RING_SMALL, 0);
            wreg(bo, (rreg(bo) & 0xff000000u) | RS_BO_27MBPS);
        }
        wreg(cl->en_ibp, 0xffff);
        wreg(cl->en_pbp, 0x3f);
        fprintf(stderr, "  XC %s: 16 IBP + 6 PBP rings, EN=ffff/3f\n",
                cl->name);
    }

    /* 7. Sync detect on every input band — cheap wiring diagnostic. */
    for (b = 0; b < 7; b++)
        wreg(XPT_FE_IB_CTRL(b),
             (rreg(XPT_FE_IB_CTRL(b)) & ~IB_WR_FIELDS) | (0xbcu << 16) |
             IB_SYNC_DETECT_EN);

    fprintf(stderr, "openinit done: %u bytes of reserved RAM used; now run "
            "setup --no-rsbuf --no-xc\n", ring_cursor - (c->phys + c->size));
}

/* -------------------------------- raveinit ------------------------------- */

/* Global RAVE bring-up (vendor BXPT_Rave_OpenChannel first-open path):
 * clear the three SRAM table regions, load the 16 KB microcode into the
 * code RAM, release the engine, program the CDB-size modeword.  Run once
 * after power-on/xptreset, before any per-context setup.  The microcode
 * blob is extracted verbatim from nexus.ko .rodata (BxptRaveInitData). */
static void do_raveinit(const struct cfg *c, const char *ucode_path)
{
    uint32_t a, i, mode;
    FILE *f;
    static uint32_t ucode[RAVE_UCODE_WORDS];

    f = fopen(ucode_path, "rb");
    if (!f) { perror(ucode_path); exit(1); }
    if (fread(ucode, 4, RAVE_UCODE_WORDS, f) != RAVE_UCODE_WORDS) {
        fprintf(stderr, "%s: want %u bytes of microcode\n",
                ucode_path, RAVE_UCODE_WORDS * 4);
        exit(1);
    }
    fclose(f);

    mode = rave_modeword(c->size >> 10);
    if (!mode) {
        fprintf(stderr, "no RAVE modeword for CDB size %u (use 32K..4M "
                "power of two)\n", c->size);
        exit(1);
    }

    fprintf(stderr, "raveinit: ucode %s, CDB size %uK (modeword %08x)\n",
            ucode_path, c->size >> 10, mode);

    for (a = RAVE_CLR1_LO; a <= RAVE_CLR1_HI; a += 4) wreg(a, 0);
    for (a = RAVE_CLR2_LO; a <= RAVE_CLR2_HI; a += 4) wreg(a, 0);
    for (a = RAVE_CLR3_LO; a <= RAVE_CLR3_HI; a += 4) wreg(a, 0);
    fprintf(stderr, "  tables cleared (0x25974/0x26174/0x27200 regions)\n");

    for (i = 0; i < RAVE_UCODE_WORDS; i++)
        wreg(RAVE_UCODE_ADDR + 4 * i, ucode[i]);
    /* spot-verify the load */
    for (i = 0; i < RAVE_UCODE_WORDS; i += RAVE_UCODE_WORDS / 8) {
        uint32_t rb = rreg(RAVE_UCODE_ADDR + 4 * i);
        if (rb != ucode[i])
            fprintf(stderr, "  ucode VERIFY FAIL word %u: %08x != %08x\n",
                    i, rb, ucode[i]);
    }
    fprintf(stderr, "  microcode loaded @%08x (%u words)\n",
            RAVE_UCODE_ADDR, RAVE_UCODE_WORDS);

    wrv("RAVE release", RAVE_RELEASE_REG, 0);
    wrv("RAVE modeword", RAVE_MODEWORD_REG,
        (rreg(RAVE_MODEWORD_REG) & RAVE_MODEWORD_KEEP) | mode);

    fprintf(stderr, "raveinit done — context regs at 0x%08x should now be "
            "live (probe with memprobe)\n", RAVE_CTX_BASE(0));
}

/* ---------------------------------- rave --------------------------------- */

/* Defined in the capture section below; the drain loop reuses them. */
static volatile sig_atomic_t g_stop;
static void on_sig(int sig);
static int xwrite(const uint8_t *p, size_t n);

/* ------------------------------ UDP output -------------------------------
 * --udp host:port makes rave_drain emit 1316-byte datagrams (7 x 188-byte
 * TS packets, the MPEG-over-UDP framing VLC expects on udp://@:port)
 * instead of writing stdout.  Partial tail is buffered across drains. */
#define UDP_CHUNK  1316u
static int udp_fd = -1;
static uint8_t udp_acc[UDP_CHUNK];
static size_t udp_len;

static void udp_open(const char *hostport)
{
    char host[64];
    const char *colon = strrchr(hostport, ':');
    struct sockaddr_in sa;

    if (!colon || (size_t)(colon - hostport) >= sizeof host) {
        fprintf(stderr, "--udp wants host:port, got '%s'\n", hostport);
        exit(1);
    }
    memcpy(host, hostport, (size_t)(colon - hostport));
    host[colon - hostport] = 0;

    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)strtoul(colon + 1, NULL, 10));
    if (!inet_aton(host, &sa.sin_addr)) {
        fprintf(stderr, "--udp: bad IPv4 address '%s'\n", host);
        exit(1);
    }
    udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_fd < 0) { perror("socket"); exit(1); }
    if (connect(udp_fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        perror("connect");
        exit(1);
    }
    fprintf(stderr, "streaming UDP/TS to %s (%u-byte datagrams) — on the "
            "receiver open udp://@:%u in VLC\n",
            hostport, UDP_CHUNK, ntohs(sa.sin_port));
}

/* stdout or UDP, depending on --udp.  A lost datagram is dropped silently
 * (send errors other than ENOBUFS/EAGAIN are fatal only once reported). */
static int out_write(const uint8_t *p, size_t n)
{
    if (udp_fd < 0)
        return xwrite(p, n);
    while (n) {
        size_t take = UDP_CHUNK - udp_len;
        if (take > n)
            take = n;
        memcpy(udp_acc + udp_len, p, take);
        udp_len += take;
        p += take;
        n -= take;
        if (udp_len == UDP_CHUNK) {
            /* ECONNREFUSED = nobody listening yet (VLC not started) — keep
             * streaming into the void until a receiver shows up. */
            if (send(udp_fd, udp_acc, UDP_CHUNK, 0) < 0 &&
                errno != ENOBUFS && errno != EAGAIN && errno != EINTR &&
                errno != ECONNREFUSED) {
                fprintf(stderr, "udp send: %s\n", strerror(errno));
                return -1;
            }
            udp_len = 0;
        }
    }
    return 0;
}

/* Open ONE RAVE context, route a PID channel to it (SPID dest 5), configure
 * a raw-TS record, bind the PID->queue->context, and arm CONTEXT_ENABLE.
 * Run AFTER `raveinit`.  Front end (IB / parser / PID table) is programmed
 * here too so the whole chain is one command; source the TS from the MxL
 * (IB) or from the PB0 playback bench (set -p to the playback parser).
 *
 * THE addressing constraint (reversed + live-confirmed): the CDB ring
 * pointers are a 24-bit *byte offset* into MEMC device space with NO high
 * window register (BXPT_Rave threshold path writes BMEM_ConvertAddressToOffset
 * raw, masked to 24 bits; live poke proves bits[31:24] read 0).  Device
 * offset == physical address on this single-MEMC part, so the buffer MUST
 * live in the low 16 MB of DRAM — use a low /memreserve/ (see the DTS). */
static void do_rave(const struct cfg *c)
{
    uint32_t ctx = c->ctx;
    uint32_t ctxb = RAVE_CTX_BASE(ctx);
    uint32_t band = c->parser;             /* RAVE queue keyed by input band */
    uint32_t chan = c->chan;               /* the pid channel we route       */
    uint32_t cdb  = c->phys;
    uint32_t cdbsz = c->size;
    uint32_t cdb_off = cdb & 0xffffffu;
    uint32_t cdb_end = (cdb + cdbsz - 1u) & 0xffffffu;
    uint32_t qreg = RAVE_QALLOC(band);
    uint32_t queue = c->queue;
    uint32_t qblk = RAVE_QUEUE_TBL(queue);
    uint32_t wm, old, v, i;

    uint32_t itb_off = c->itba & 0xffffffu;
    uint32_t itb_end = (c->itba + c->itbs - 1u) & 0xffffffu;

    if (cdb + cdbsz > 0x01000000u) {
        fprintf(stderr, "rave: CDB [0x%08x..0x%08x) is outside the low 16 MB "
                "the 24-bit CDB pointer can reach — use a low -a phys\n",
                cdb, cdb + cdbsz);
        exit(1);
    }
    if (c->itba + c->itbs > 0x01000000u) {
        fprintf(stderr, "rave: ITB [0x%08x..0x%08x) must be in the low 16 MB "
                "too — use --itba/--itbs\n", c->itba, c->itba + c->itbs);
        exit(1);
    }

    fprintf(stderr, "rave: ctx=%u band=%u chan=%u queue=%u CDB=0x%08x size=%u "
            "(off=0x%06x end=0x%06x) ITB=0x%08x size=%u\n", ctx, band, chan,
            queue, cdb, cdbsz, cdb_off, cdb_end, c->itba, c->itbs);

    /* 0. Disarm + FlushContext replica (vendor record path, disasm of
     * BXPT_Rave_FlushContext 0x351740): zero the per-context record state
     * regs +0xc4..+0xdc, the per-pid-channel spot scoreboard at
     * 0xa21b04+chan*0x88 (33 words) and the per-channel queue block at
     * 0xa29200+chan*0x80 (+0x00..+0x54 = 0, +0x58 = 0xfe), then PULSE ctx
     * +0xe0 bit17 — the engine-executed context-reset command (the only
     * thing that clears the engine's internal context state; sw-init does
     * NOT touch these SRAMs) — and clear ctx+0xe8 bit13. */
    old = rreg(ctxb + RAVE_CTX_MISC_CONFIG1);
    wrv("DISARM", ctxb + RAVE_CTX_MISC_CONFIG1, old & ~RAVE_CTX_ENABLE_BIT);
    if (c->level >= 4) {
    for (i = 0xc4; i <= 0xdc; i += 4)
        wreg(ctxb + i, 0);
    fprintf(stderr, "  ctx +0xc4..+0xdc zeroed (record state)\n");
    for (i = 0; i < 0x84; i += 4)
        wreg(0x10a21b04u + chan * 0x88u + i, 0);
    fprintf(stderr, "  spot scoreboard 0x%08x+0x84 zeroed\n",
            0x10a21b04u + chan * 0x88u);
    for (i = 0; i <= 0x54; i += 4)
        wreg(0x10a29200u + chan * 0x80u + i, 0);
    wreg(0x10a29200u + chan * 0x80u + 0x58u, 0xfe);
    fprintf(stderr, "  chan queue block 0x%08x cleared (+0x58=0xfe)\n",
            0x10a29200u + chan * 0x80u);
    old = rreg(ctxb + 0xe0u) & 0xfffcffffu;
    wrv("CTX_RESET set", ctxb + 0xe0u, old | 0x20000u);
    wrv("CTX_RESET clr", ctxb + 0xe0u, old);
    wrv("CTX_E8", ctxb + 0xe8u, rreg(ctxb + 0xe8u) & ~0x2000u);
    /* Defined state for config regs ResetContext RMWs over garbage SRAM:
     * +0x44 (record: bits[1:0]=0, ipcfg[13:8]=0), +0x6c, +0x74. */
    wrv("CFG_44", ctxb + 0x44u, 0);
    wrv("CFG_6C", ctxb + 0x6cu, 0);
    wrv("CFG_74", ctxb + 0x74u, 0);
    }   /* level >= 4 */

    /* 1. CDB + ITB ring pointers, the full set vendor ResetContext programs
     * (empty rings: WRITE=READ=VALID=BASE, WRAP=0, END=base+size-1).  VALID,
     * WRAP and the whole ITB block are context SRAM: left unwritten they are
     * garbage, and the engine wedges on them before its first CDB write. */
    wrv("CDB_BASE",  ctxb + RAVE_CTX_CDB_BASE,  cdb_off);
    wrv("CDB_READ",  ctxb + RAVE_CTX_CDB_READ,  cdb_off);
    wrv("CDB_WRITE", ctxb + RAVE_CTX_CDB_WRITE, cdb_off);
    wr_only("CDB_END", ctxb + RAVE_CTX_CDB_END, cdb_end);   /* read-faults */
    if (c->level >= 1) {
        wrv("CDB_VALID", ctxb + RAVE_CTX_CDB_VALID, cdb_off);
        wrv("CDB_WRAP",  ctxb + RAVE_CTX_CDB_WRAP,  0);
    }
    if (c->level >= 2) {
        wrv("ITB_CFG",   ctxb + RAVE_CTX_ITB_CFG,   RAVE_ITB_CFG_VAL);
        wrv("ITB_WRITE", ctxb + RAVE_CTX_ITB_WRITE, itb_off);
        wrv("ITB_READ",  ctxb + RAVE_CTX_ITB_READ,  itb_off);
        wrv("ITB_BASE",  ctxb + RAVE_CTX_ITB_BASE,  itb_off);
        wr_only("ITB_END", ctxb + RAVE_CTX_ITB_END, itb_end);
        wrv("ITB_VALID", ctxb + RAVE_CTX_ITB_VALID, itb_off);
        wrv("ITB_WRAP",  ctxb + RAVE_CTX_ITB_WRAP,  0);
    }

    /* 2. SetRecordConfig — raw all-pass TS (concrete values, ctx-relative). */
    /* Full writes (not RMW): after raveinit the context config SRAM is
     * uninitialised garbage, so preserving "old" bits would keep garbage.
     * The vendor ResetContext zeroes it first, making its RMW == full write. */
    wrv("REC_A8", ctxb + RAVE_CTX_REC_A8, c->a8);
    wrv("REC_AC", ctxb + RAVE_CTX_REC_AC, 0x0);
    if (c->level >= 4)
        wrv("REC_F8", ctxb + 0xf8u, 0x0);  /* band-hold cfg, vendor writes */
    wrv("REC_B0", ctxb + RAVE_CTX_REC_B0, 0x38u);
    wm = c->rave_wm ? ((cdbsz >> 8) / 2u) : 0u;   /* 0 = frequent data-ready */
    wrv("WATERMARK", ctxb + RAVE_CTX_WATERMARK, (wm << 16) | wm);
    wrv("CFG_3C", ctxb + RAVE_CTX_CFG_3C, 0x0);
    wrv("CFG_70", ctxb + RAVE_CTX_CFG_70, 0x8d);
    wrv("REC_B4", ctxb + RAVE_CTX_REC_B4, 0x0);
    wrv("MISC_CONFIG1", ctxb + RAVE_CTX_MISC_CONFIG1, c->misc);
    fprintf(stderr, "  (a8=%#x misc=%#010x — override with --a8/--misc)\n",
            c->a8, c->misc);
    wr_only("CDB_END", ctxb + RAVE_CTX_CDB_END, cdb_end);  /* recompute */

    /* 2b. PID spots (vendor BXPT_Rave_AddPidChannel — the RECORD-path
     * binding, distinct from the band queue below): 8 per-context slots at
     * +0x60,+0x64,+0x48..+0x5c the engine matches incoming pid channels
     * against.  Format: bit15 = valid, [12:0] = pid channel, [29:24] a
     * preserved 6-bit field (zeroed here — context SRAM is garbage).
     * Left unprogrammed, no packet ever matches: RAVE consumes its XC
     * input and drops everything, writing neither CDB nor ITB. */
    if (c->level >= 3) {
        static const uint32_t spot_off[8] =
            { 0x60, 0x64, 0x48, 0x4c, 0x50, 0x54, 0x58, 0x5c };
        wrv("PIDSPOT0", ctxb + spot_off[0], 0x8000u | (chan & 0x1fffu));
        for (i = 1; i < 8; i++)
            wrv("PIDSPOT", ctxb + spot_off[i], 0);
    }

    /* 3. Bind PID channel -> queue -> context (BXPT_Rave_PushPidChannel). */
    wrv("Q_ALLOC", qreg, 0x7c0u + queue * 0x10u);
    /* ClearQueue: drop the PID/queue-active bit, then zero the queue block.
     * Full writes — the reg is context SRAM, RMW would keep garbage. */
    wrv("PIDQ dis", ctxb + RAVE_CTX_PIDQ_ENABLE, 0);
    for (i = 0; i < 0x40u; i += 4)
        wreg(qblk + i, 0);
    fprintf(stderr, "  queue block 0x%08x zeroed\n", qblk);
    wrv("Q_PRIMARY", qblk + RAVE_QUEUE_PRIMARY, chan);    /* primary channel */
    wrv("Q_SLOT0",   qblk + RAVE_QUEUE_SLOT(0), chan);    /* first pushed    */
    wrv("Q_TAIL",    qblk + RAVE_QUEUE_TAIL, 1);          /* depth 1         */
    wrv("PIDQ en", ctxb + RAVE_CTX_PIDQ_ENABLE, RAVE_CTX_PIDQ_BIT);

    /* 4. SPID destination = RAVE (dest 5 = bit5 of top byte). */
    old = rreg(XPT_SPID(chan));
    wrv("SPID dest5", XPT_SPID(chan), (old & 0x00ffffffu) | SPID_DEST_RAVE);

    /* 5. PID channel table: band + enable.  All-pass by default; --pid for a
     * PID-matching channel (e.g. 0x1fff nulls from an unlocked/idle MxL). */
    old = rreg(XPT_PID_TABLE(chan));
    if (c->have_pid)
        v = (old & PID_KEEP_MASK_PIDMATCH & ~PID_ENABLE) |
            (band << 16) | c->pid;
    else
        v = (old & PID_KEEP_MASK & ~PID_ENABLE) | (band << 16);
    if (c->pbmode)
        v |= 0x8000u;                  /* playback-band mode (GetPbBandId) */
    wrv("PID_TABLE cfg", XPT_PID_TABLE(chan), v);
    wrv("PID_TABLE en",  XPT_PID_TABLE(chan), v | PID_ENABLE);

    /* 6. Parser: MPEG 188, input band select, accept nulls, ignore CC, EN;
     * all-pass unless --pid.  Skip if --no-parser (PB0 owns its parser). */
    if (!c->no_parser) {
        old = rreg(XPT_FE_PARSER_CTRL1(c->parser));
        v = (old & ~PARSER_WR_FIELDS) | (188u << 12) | (c->ib << 8) |
            PARSER_ACCEPT_NULL | PARSER_CC_IGNORE | PARSER_ENABLE;
        if (!c->have_pid)
            v |= PARSER_ALL_PASS;
        wrv("PARSER_CTRL1", XPT_FE_PARSER_CTRL1(c->parser), v);

        /* 7. Input band: pktlen 188, sync detect on, serial + polarities. */
        old = rreg(XPT_FE_IB_CTRL(c->ib));
        v = (old & ~IB_WR_FIELDS) | (0xbcu << 16) | IB_SYNC_DETECT_EN;
        if (c->parallel)    v |= IB_PARALLEL_SEL;
        if (c->clkpol)      v |= IB_CLOCK_POL;
        if (c->syncpol)     v |= IB_SYNC_POL;
        if (c->datapol)     v |= IB_DATA_POL;
        if (c->forcevalid)  v |= IB_FORCE_VALID;
        if (c->syncasvalid) v |= IB_USE_SYNC_AS_VALID;
        wrv("IB_CTRL", XPT_FE_IB_CTRL(c->ib), v);
    } else {
        fprintf(stderr, "  parser/IB skipped (--no-parser; PB0 feeds it)\n");
    }

    /* 8. ARM: CONTEXT_ENABLE = bit20 of AV_MISC_CONFIG1 (the last step). */
    old = rreg(ctxb + RAVE_CTX_MISC_CONFIG1);
    wrv("ARM CONTEXT_ENABLE", ctxb + RAVE_CTX_MISC_CONFIG1,
        old | RAVE_CTX_ENABLE_BIT);

    fprintf(stderr, "rave armed — watch CDB_WRITE (0x%08x) advance past "
            "0x%06x, then `rave_drain`\n", ctxb + RAVE_CTX_CDB_WRITE, cdb_off);
}

/* Drain the RAVE CDB ring to stdout: VALID/WRITE ptr - READ ptr = bytes
 * available (raw byte subtract, no shift — proven), copy [READ..WRITE),
 * advance READ (wrap END->BASE).  Pointers are 24-bit device offsets; the
 * buffer offset = ptr - (BASE & 0xffffff). */
static void do_rave_drain(const struct cfg *c)
{
    uint32_t ctx = c->ctx;
    uint32_t ctxb = RAVE_CTX_BASE(ctx);
    uint32_t base = rreg(ctxb + RAVE_CTX_CDB_BASE) & 0xffffffu;  /* readable */
    uint32_t size = c->size;                 /* END read-faults; use -s */
    uint32_t phys = c->phys;

    if (size == 0 || size > 0x01000000u) {
        fprintf(stderr, "rave_drain: bad CDB size %u — pass -s\n", size);
        exit(1);
    }
    fprintf(stderr, "rave_drain: ctx=%u CDB phys=0x%08x base=0x%06x size=%u — "
            "TS on %s, Ctrl+C to stop\n", ctx, phys, base, size,
            c->udp ? c->udp : "stdout");
    if (c->udp)
        udp_open(c->udp);

    void *m = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, phys);
    if (m == MAP_FAILED) { perror("mmap CDB"); exit(1); }
    const uint8_t *ring = m;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGPIPE, SIG_IGN);

    uint64_t total = 0;
    time_t last = time(NULL);
    uint32_t rd = rreg(ctxb + RAVE_CTX_CDB_READ) & 0xffffffu;

    while (!g_stop) {
        uint32_t wr = rreg(ctxb + RAVE_CTX_CDB_VALID) & 0xffffffu;
        /* VALID stays 0 (below BASE) until the hardware produces its first
         * bytes — comparing it against READ then would "drain" garbage. */
        if (wr >= base && wr != rd) {
            uint32_t ro = rd - base, wo = wr - base;
            if (wo > ro) {
                if (out_write(ring + ro, wo - ro)) break;
            } else {
                if (out_write(ring + ro, size - ro) || out_write(ring, wo))
                    break;
            }
            total += (wo - ro) & (size - 1u);
            rd = wr;
            wreg(ctxb + RAVE_CTX_CDB_READ, rd);
        }
        /* Keep the ITB ring from filling (we don't parse the index):
         * discard everything the engine produced, READ = VALID. */
        uint32_t iv = rreg(ctxb + RAVE_CTX_ITB_VALID) & 0xffffffu;
        if (iv != (rreg(ctxb + RAVE_CTX_ITB_READ) & 0xffffffu))
            wreg(ctxb + RAVE_CTX_ITB_READ, iv);

        time_t now = time(NULL);
        if (now - last >= 5) {
            fprintf(stderr, "  drained %llu bytes (WRITE=0x%06x READ=0x%06x "
                    "ITB_VALID=0x%06x)\n",
                    (unsigned long long)total, wr, rd, iv);
            last = now;
        }
        usleep(5000);
    }
    fprintf(stderr, "rave_drain stopped: %llu bytes total\n",
            (unsigned long long)total);
}

/* --------------------------------- setup --------------------------------- */

static void do_setup(const struct cfg *c)
{
    uint32_t code = (uint32_t)size_code(c->size);
    uint32_t old, v;

    fprintf(stderr, "xpt_cap setup: ib=%u parser=%u chan=%u buf=%u "
            "ring=0x%08x size=%u (code %u) dest=0x%02x ",
            c->ib, c->parser, c->chan, c->buf, c->phys, c->size, code,
            c->dest);
    if (c->have_pid)
        fprintf(stderr, "mode=pid-match pid=0x%04x\n", c->pid);
    else
        fprintf(stderr, "mode=all-pass\n");

    /* 0. Staging buffers (RS rate-smoothing + XC MSG cross-connect) and the
     * bandwidth pacing — the vendor sets these up in BXPT_Open, before any
     * channel.  Without them the parser output never reaches the MSG engine
     * (BUF_DAT_AVAIL stays 0, DMA_VP frozen), which is exactly our symptom. */
    do_init_buffers(c);

    /* 1+2. MSG ring buffer: reset, program base/size, reset again so
     * RP = VP = 0 against the new base. */
    wreg(XPT_MSG_BUF_RESET, c->buf);
    wrv("DMA_BP", XPT_MSG_DMA_BP(c->buf), (c->phys >> 10) | (code << 28));
    wreg(XPT_MSG_BUF_RESET, c->buf);
    fprintf(stderr, "  after reset: RP=%08x VP=%08x\n",
            rreg(XPT_MSG_DMA_RP(c->buf)), rreg(XPT_MSG_DMA_VP(c->buf)));
    wrv("GEN_FILT_EN", XPT_MSG_GEN_FILT_EN(c->buf), 0);
    wrv("BUF_CTRL2", XPT_MSG_BUF_CTRL2(c->buf), 0);

    /* 3. Output mode MPEG_TS (raw 188-byte packets), no error checking
     * tweaks, align mode 0 — deterministic full write. */
    wrv("BUF_CTRL1", XPT_MSG_BUF_CTRL1(c->buf), c->bufmode);

    /* 4. Route the PID channel to this buffer. */
    for (v = 0; v < 4; v++)
        wrv("PID2BUF mask", XPT_MSG_PID2BUF_W(c->chan, v),
            (v == (c->buf >> 5)) ? XPT_MSG_PID2BUF_BIT(c->buf) : 0);

    /* 5. SPID destination = record.  Confirmed: top byte is one bit per
     * destination, bit (24 + dest); record = dest 7 = bit 31, so the
     * default dest bits are 0x80.  RMW keeps bits[23:0]. */
    old = rreg(XPT_SPID(c->chan));
    wrv("SPID", XPT_SPID(c->chan), (old & 0x00ffffffu) | (c->dest << 24));

    /* 6. PID channel.  band id = parser band number.  Program first, then
     * set the enable bit, like the vendor helper does.
     * Default: all-pass companion entry, PID value irrelevant (0).
     * --pid: normal PID-matching entry (e.g. 0x1fff null packets from an
     * unlocked MxL — validates the chain without all-pass). */
    old = rreg(XPT_PID_TABLE(c->chan));
    if (c->have_pid)
        v = (old & PID_KEEP_MASK_PIDMATCH & ~PID_ENABLE) |
            (c->parser << 16) | c->pid;
    else
        v = (old & PID_KEEP_MASK & ~PID_ENABLE) | (c->parser << 16);
    wrv("PID_TABLE cfg", XPT_PID_TABLE(c->chan), v);
    wrv("PID_TABLE en", XPT_PID_TABLE(c->chan), v | PID_ENABLE);

    /* 7. Parser: MPEG packet type, 188-byte packets, input band select,
     * accept nulls, ignore continuity counter, enable.  ALL_PASS only in
     * the default mode — with --pid the channel matches normally. */
    old = rreg(XPT_FE_PARSER_CTRL1(c->parser));
    v = (old & ~PARSER_WR_FIELDS) | (188u << 12) | (c->ib << 8) |
        PARSER_ACCEPT_NULL | PARSER_CC_IGNORE | PARSER_ENABLE;
    if (!c->have_pid)
        v |= PARSER_ALL_PASS;
    wrv("PARSER_CTRL1", XPT_FE_PARSER_CTRL1(c->parser), v);

    /* 8. Input band: packet length 188, sync detector on (SYNC_COUNT is
     * the wiring detector), serial by default, polarities per options. */
    old = rreg(XPT_FE_IB_CTRL(c->ib));
    v = (old & ~IB_WR_FIELDS) | (0xbcu << 16) | IB_SYNC_DETECT_EN;
    if (c->parallel)    v |= IB_PARALLEL_SEL;
    if (c->clkpol)      v |= IB_CLOCK_POL;
    if (c->syncpol)     v |= IB_SYNC_POL;
    if (c->datapol)     v |= IB_DATA_POL;
    if (c->forcevalid)  v |= IB_FORCE_VALID;
    if (c->syncasvalid) v |= IB_USE_SYNC_AS_VALID;
    wrv("IB_CTRL", XPT_FE_IB_CTRL(c->ib), v);

    fprintf(stderr, "setup done — check `xpt_cap status` (IB%u SYNC_COUNT "
            "must tick, then VP of buf %u), then `xpt_cap capture`.\n",
            c->ib, c->buf);
}

/* --------------------------------- addpid -------------------------------- */

/* Route ONE extra PID-matching channel into an already-set-up MSG buffer:
 * PID2BUF mask, SPID record destination, PID_TABLE entry + enable — exactly
 * setup steps 4..6, nothing else.  Run after `setup --pid <first>` to build
 * a multi-PID service filter (PAT + PMT + video + audios all landing in the
 * same ring).  The full-mux all-pass path drops ~6% of packets (record-path
 * per-packet cap); per-PID filtering stays well under it and captures
 * loss-free — this is THE clean-stream path for VLC. */
static void do_addpid(const struct cfg *c)
{
    uint32_t old, v;

    if (!c->have_pid) {
        fprintf(stderr, "addpid needs --pid <pid>\n");
        exit(1);
    }
    fprintf(stderr, "addpid: chan=%u pid=0x%04x -> buf %u (parser %u)\n",
            c->chan, c->pid, c->buf, c->parser);

    for (v = 0; v < 4; v++)
        wrv("PID2BUF mask", XPT_MSG_PID2BUF_W(c->chan, v),
            (v == (c->buf >> 5)) ? XPT_MSG_PID2BUF_BIT(c->buf) : 0);

    old = rreg(XPT_SPID(c->chan));
    wrv("SPID", XPT_SPID(c->chan), (old & 0x00ffffffu) | (c->dest << 24));

    old = rreg(XPT_PID_TABLE(c->chan));
    v = (old & PID_KEEP_MASK_PIDMATCH & ~PID_ENABLE) |
        (c->parser << 16) | c->pid;
    wrv("PID_TABLE cfg", XPT_PID_TABLE(c->chan), v);
    wrv("PID_TABLE en", XPT_PID_TABLE(c->chan), v | PID_ENABLE);
}

/* --------------------------------- addbuf -------------------------------- */

/* Program ONE extra MSG ring buffer (steps 1..3 of setup, nothing else):
 * lets several services run on separate buffers — the MSG engine's
 * throughput collapses as the number of channels feeding one buffer grows
 * (34 chans -> ~3 Mbps total), so "all services in parallel" = one buffer
 * per service, drained together. */
static void do_addbuf(const struct cfg *c)
{
    uint32_t code = (uint32_t)size_code(c->size);

    fprintf(stderr, "addbuf: buf=%u ring=0x%08x size=%u (code %u) mode=%u\n",
            c->buf, c->phys, c->size, code, c->bufmode);
    wreg(XPT_MSG_BUF_RESET, c->buf);
    wrv("DMA_BP", XPT_MSG_DMA_BP(c->buf), (c->phys >> 10) | (code << 28));
    wreg(XPT_MSG_BUF_RESET, c->buf);
    wrv("GEN_FILT_EN", XPT_MSG_GEN_FILT_EN(c->buf), 0);
    wrv("BUF_CTRL2", XPT_MSG_BUF_CTRL2(c->buf), 0);
    wrv("BUF_CTRL1", XPT_MSG_BUF_CTRL1(c->buf), c->bufmode);
}

/* --------------------------------- stop ---------------------------------- */

static void do_stop(const struct cfg *c)
{
    uint32_t old;

    fprintf(stderr, "xpt_cap stop: parser=%u chan=%u buf=%u\n",
            c->parser, c->chan, c->buf);
    old = rreg(XPT_FE_PARSER_CTRL1(c->parser));
    wrv("PARSER_CTRL1", XPT_FE_PARSER_CTRL1(c->parser),
        old & ~PARSER_ENABLE);
    old = rreg(XPT_PID_TABLE(c->chan));
    wrv("PID_TABLE", XPT_PID_TABLE(c->chan), old & ~PID_ENABLE);
    old = rreg(XPT_SPID(c->chan));
    wrv("SPID", XPT_SPID(c->chan), old & 0x00ffffffu);
    wrv("BUF_CTRL1", XPT_MSG_BUF_CTRL1(c->buf), 0);

    /* Disable the staging buffers for our band (leave the rest untouched). */
    wrv("XC_MSG_IBP_EN", XC_MSG_IBP_EN,
        rreg(XC_MSG_IBP_EN) & ~(1u << c->parser));
    wrv("RS_EN_G1", RS_EN_G1, rreg(RS_EN_G1) & ~(1u << c->parser));
    wrv("RS_EN_G3", RS_EN_G3, rreg(RS_EN_G3) & ~(1u << c->parser));
}

/* -------------------------------- capture -------------------------------- */

static volatile sig_atomic_t g_stop;

static void on_sig(int sig)
{
    (void)sig;
    g_stop = 1;
}

static int xwrite(const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t w = write(STDOUT_FILENO, p, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "stdout write: %s\n", strerror(errno));
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static void do_capture(const struct cfg *c)
{
    uint32_t base = c->phys, size = c->size;
    uint32_t bp = rreg(XPT_MSG_DMA_BP(c->buf));

    /* The BP register is authoritative — that is where the hardware DMAs. */
    if (bp != 0) {
        uint32_t rbase = (bp & 0x3fffffu) << 10;
        uint32_t rsize = 0x400u << (bp >> 28);
        if ((c->have_phys && rbase != base) ||
            (c->have_size && rsize != size))
            fprintf(stderr, "warning: -a/-s differ from DMA_BP[%u]=%08x — "
                    "using register values\n", c->buf, bp);
        base = rbase;
        size = rsize;
    } else {
        fprintf(stderr, "warning: DMA_BP[%u] is 0 (no setup?) — falling "
                "back to -a/-s\n", c->buf);
    }
    fprintf(stderr, "capture: buf=%u ring=0x%08x size=%u — TS on %s, "
            "Ctrl+C to stop\n", c->buf, base, size,
            c->udp ? c->udp : "stdout");
    if (c->udp)
        udp_open(c->udp);

    void *m = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { perror("mmap ring buffer"); exit(1); }
    const uint8_t *ring = m;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGPIPE, SIG_IGN);

    uint64_t total = 0;
    time_t last = time(NULL);

    /* Start from a CLEAN ring: BUF_RESET zeroes RP/VP and, crucially,
     * clears the engine's overflow-pause state.  If the ring filled up
     * before we started draining (easy: 512K fills in <1 s while addpid
     * runs), VP latches bit31 = overflow flag and the engine pauses; a
     * masked RP=VP sync then reads as "still full" and the engine never
     * resumes — the ring is deadlocked at 0 bytes forever.  Reset is the
     * only exit, so do it at start and again whenever bit31 shows up. */
    uint32_t ctrl1 = rreg(XPT_MSG_BUF_CTRL1(c->buf));
    wreg(XPT_MSG_BUF_CTRL1(c->buf), 0);        /* disable while resetting  */
    wreg(XPT_MSG_BUF_RESET, c->buf);
    wreg(XPT_MSG_BUF_CTRL1(c->buf), ctrl1);    /* re-arm                   */
    fprintf(stderr, "  ring reset (CTRL1=%08x RP=%08x VP=%08x)\n", ctrl1,
            rreg(XPT_MSG_DMA_RP(c->buf)), rreg(XPT_MSG_DMA_VP(c->buf)));
    uint32_t overflows = 0;

    while (!g_stop) {
        uint32_t vp_raw = rreg(XPT_MSG_DMA_VP(c->buf));
        uint32_t vp = vp_raw & (size - 1);
        uint32_t rp = rreg(XPT_MSG_DMA_RP(c->buf)) & (size - 1);

        if (vp_raw & 0x80000000u) {     /* overflow: drain stalled behind */
            wreg(XPT_MSG_BUF_CTRL1(c->buf), 0);
            wreg(XPT_MSG_BUF_RESET, c->buf);
            wreg(XPT_MSG_BUF_CTRL1(c->buf), ctrl1);
            overflows++;
            fprintf(stderr, "  OVERFLOW #%u — ring reset (data lost)\n",
                    overflows);
            continue;
        }
        if (vp != rp) {
            if (vp > rp) {
                if (out_write(ring + rp, vp - rp))
                    break;
            } else {                            /* wrap */
                if (out_write(ring + rp, size - rp) || out_write(ring, vp))
                    break;
            }
            total += (vp - rp) & (size - 1);
            wreg(XPT_MSG_DMA_RP(c->buf), vp);
        }

        time_t now = time(NULL);
        if (now - last >= 5) {
            fprintf(stderr, "  captured %llu bytes (VP=%08x)\n",
                    (unsigned long long)total, vp);
            last = now;
        }
        usleep(5000);
    }
    fprintf(stderr, "capture stopped: %llu bytes total\n",
            (unsigned long long)total);
}

/* ------------------------------- peek/poke ------------------------------- */

static void do_peek(int argc, char **argv)
{
    if (argc < 1) usage();
    uint32_t base = strtoul(argv[0], NULL, 0) & ~3u;
    uint32_t len = argc > 1 ? strtoul(argv[1], NULL, 0) : 4;

    for (uint32_t a = base & ~0xfu; a < base + len; a += 0x10) {
        printf("%08x:", a);
        for (int w = 0; w < 4; w++) {
            void *page;
            volatile uint32_t *p = map_word(a + 4u * w, &page);
            printf(" %08x", *p);
            munmap(page, PAGE);
        }
        printf("\n");
    }
}

static void do_poke(int argc, char **argv)
{
    if (argc < 2) usage();
    uint32_t addr = strtoul(argv[0], NULL, 0) & ~3u;
    uint32_t val = strtoul(argv[1], NULL, 0);
    void *page;
    volatile uint32_t *p = map_word(addr, &page);

    *p = val;
    mmio_sync();
    printf("%08x <= %08x  rb=%08x\n", addr, val, *p);
    munmap(page, PAGE);
}

/* ---------------------------------- load --------------------------------- */

/* load <addr>: copy stdin into physical RAM through mmap (write() on
 * /dev/mem fails with EFAULT for the /memreserve/ region — no linear
 * mapping — but mmap works). */
static void do_load(int argc, char **argv)
{
    if (argc < 1) usage();
    uint32_t addr = strtoul(argv[0], NULL, 0);
    uint32_t off = addr & (PAGE - 1);
    size_t cap = 4u << 20;
    void *m = mmap(NULL, cap + PAGE, PROT_WRITE, MAP_SHARED, fd,
                   addr & PAGEMASK);
    if (m == MAP_FAILED) { perror("mmap"); exit(1); }

    uint8_t *dst = (uint8_t *)m + off;
    size_t total = 0;
    ssize_t r;
    while (total < cap &&
           (r = read(STDIN_FILENO, dst + total, cap - total)) > 0)
        total += (size_t)r;
    msync(m, cap + PAGE, MS_SYNC);
    fprintf(stderr, "loaded %zu bytes at 0x%08x\n", total, addr);
}

/* ---------------------------------- main --------------------------------- */

int main(int argc, char **argv)
{
    struct cfg c;

    if (argc < 2)
        usage();

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }

    const char *cmd = argv[1];

    if (!strcmp(cmd, "peek")) { do_peek(argc - 2, argv + 2); return 0; }
    if (!strcmp(cmd, "poke")) { do_poke(argc - 2, argv + 2); return 0; }
    if (!strcmp(cmd, "load")) { do_load(argc - 2, argv + 2); return 0; }

    /* Whole-XPT soft reset, byte-for-byte what vendor BXPT_P_ResetTransport
     * does before any XPT programming: pulse SUN_TOP_CTRL_SW_INIT_0
     * SET/CLEAR bit 18 (0x10404318 / 0x1040431c), then check the status
     * word at 0x1040432c.  Clears every stuck state machine and the junk
     * MSG RP/VP left over from power-on.  All XPT config is lost: run
     * setup again afterwards. */
    if (!strcmp(cmd, "xptreset")) {
        void *pg;
        volatile uint32_t *set = map_word(0x10404318u, &pg);
        set[0] = 1u << 18;                  /* SW_INIT_0_SET: XPT in reset */
        (void)set[0];
        usleep(10000);
        set[1] = 1u << 18;                  /* +4 = SW_INIT_0_CLEAR */
        (void)set[1];
        usleep(10000);
        fprintf(stderr, "XPT sw-init pulsed; status(0x1040432c) bit18=%lu "
                "(0 = out of reset)\n",
                (unsigned long)((set[5] >> 18) & 1));  /* +0x14 = 0x432c */
        munmap(pg, PAGE);
        return 0;
    }

    if (!strcmp(cmd, "raveinit")) {
        if (argc < 3 || argv[2][0] == '-')
            usage();
        parse_opts(argc - 2, argv + 2, &c);
        map_xpt();
        do_raveinit(&c, argv[2]);
        return 0;
    }

    parse_opts(argc - 1, argv + 1, &c);
    map_xpt();

    if (!strcmp(cmd, "status"))
        do_status(&c);
    else if (!strcmp(cmd, "openinit"))
        do_openinit(&c);
    else if (!strcmp(cmd, "setup"))
        do_setup(&c);
    else if (!strcmp(cmd, "addpid"))
        do_addpid(&c);
    else if (!strcmp(cmd, "addbuf"))
        do_addbuf(&c);
    else if (!strcmp(cmd, "capture"))
        do_capture(&c);
    else if (!strcmp(cmd, "rave"))
        do_rave(&c);
    else if (!strcmp(cmd, "rave_drain"))
        do_rave_drain(&c);
    else if (!strcmp(cmd, "stop"))
        do_stop(&c);
    else
        usage();
    return 0;
}
