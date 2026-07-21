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
#define XPT_MSG_PID2BUF(c)      (0x10a1c000u + 4u * (c))

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
 * THE actual TS->DRAM streaming recorder (what NEXUS_Recpump uses); the MSG
 * block above is section/PES-oriented and never streams a whole TS.  The
 * RAVE is dead silicon until its 16 KB microcode is loaded into the code
 * RAM at 0xa30800 and the engine released via 0xa30004=0 (vendor
 * BXPT_P_RaveRamInit) — that missing load is why no write engine ever
 * moved.  Per-context regs: base 0xa2b200 + N*0x100 (8 contexts); CDB ring
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
#define RAVE_CTX_CDB_WRITE      0x00u
#define RAVE_CTX_CDB_READ       0x04u
#define RAVE_CTX_CDB_BASE       0x08u
#define RAVE_CTX_CDB_END        0x0cu
#define RAVE_CTX_MISC_CONFIG1   0x68u        /* bit20 = CONTEXT_ENABLE */
#define RAVE_CTX_ENABLE_BIT     (1u << 20)
#define RAVE_QUEUE_TBL(q)       (0x10a29100u + 0x40u * (q))

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
"  capture [-b buf] [-a phys] [-s size]          (TS -> stdout)\n"
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
        default:  usage();
        }
    }
    if (c->ib > 6 || c->parser > 3 || c->chan > 255 || c->buf > 127) {
        fprintf(stderr, "range: ib 0..6, parser 0..3, chan 0..255, "
                        "buf 0..127\n");
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
    printf("  SPID=%08x (dest byte=0x%02x)  PID2BUF=%08x\n",
           rreg(XPT_SPID(c->chan)), rreg(XPT_SPID(c->chan)) >> 24,
           rreg(XPT_MSG_PID2BUF(c->chan)));
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
    for (i = 0; i < 256; i++)
        wreg(XPT_MSG_PID2BUF(i), 0);
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
    wrv("BUF_CTRL1", XPT_MSG_BUF_CTRL1(c->buf), 0x1);

    /* 4. Route the PID channel to this buffer. */
    wrv("PID2BUF", XPT_MSG_PID2BUF(c->chan), c->buf);

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
    fprintf(stderr, "capture: buf=%u ring=0x%08x size=%u — TS on stdout, "
            "Ctrl+C to stop\n", c->buf, base, size);

    void *m = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { perror("mmap ring buffer"); exit(1); }
    const uint8_t *ring = m;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGPIPE, SIG_IGN);

    uint64_t total = 0;
    time_t last = time(NULL);

    while (!g_stop) {
        uint32_t vp = rreg(XPT_MSG_DMA_VP(c->buf)) & (size - 1);
        uint32_t rp = rreg(XPT_MSG_DMA_RP(c->buf)) & (size - 1);

        if (vp != rp) {
            if (vp > rp) {
                if (xwrite(ring + rp, vp - rp))
                    break;
            } else {                            /* wrap */
                if (xwrite(ring + rp, size - rp) || xwrite(ring, vp))
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
    else if (!strcmp(cmd, "capture"))
        do_capture(&c);
    else if (!strcmp(cmd, "stop"))
        do_stop(&c);
    else
        usage();
    return 0;
}
