/*
 * kir_probe.c — validate the BCM7231 KIR (keyboard/IR receiver) block from
 * userspace, the same way uart_irq_probe validated the UART chain.
 *
 * Everything below was taken from the stock firmware's
 * nexus.ko (BKIR_* magnum driver + NEXUS_IrInput glue), which is NOT
 * stripped, so all register accesses were traced exactly:
 *
 *   - 3 identical channel windows of 0x40 bytes at BCHP 0x4088c0/900/940
 *     (phys 0x104088c0...).  Channel 0 is the one the stock stack uses.
 *   - window +0x00 STATUS:  bit0 = data-ready/IRQ-pending (ack by writing
 *     back status & ~1), bit1 = "repeated", bits[4:2] = byte count,
 *     bit5/6 = preamble B/A flags.
 *   - window +0x08 FILTER1: protocol-specific filter, 0 for Ruwido.
 *   - window +0x0c DATA_LO: frame bits 32..39 (low byte).
 *   - window +0x10 DATA_HI: frame bits 0..31.
 *   - window +0x14 CTRL:    7 at open, |0x10 for Ruwido, |0x20 = IRQ enable
 *                           => 0x37 when running.
 *   - window +0x18/+0x1c:   CIR parameter register file (write index to
 *                           +0x18, then 12-bit value to +0x1c).  The engine
 *                           is fully programmable; the Ruwido timing set is
 *                           protocol 0x17 in nexus.ko and is replayed
 *                           VERBATIM below (dumped from .rodata).
 *   - 0x408b80 KIR_TOP:     bit0 routes channel 0 (bits 5/8 = ch1/ch2).
 *   - IRQ: dedicated L1 hwirq 60 (word 1 bit 28) — measured here on
 *     2026-07-20: asserts on every frame, deasserts on STATUS ack, UPG
 *     IRQ0 uninvolved.  (The "BINT id 0x73 = L1 bit 115" reading of
 *     nexus.ko was wrong; the L1 only has 96 lines.)
 *   - Ruwido frame decode (from nexus_input.ko ir_callback):
 *     (frame & 0x7fff) in [0x7e00, 0x7f00) => key index = frame & 0x7f,
 *     mapped through the 128-entry table also dumped from nexus_input.ko.
 *
 * Reads of unbacked/clock-gated registers on BCM7xxx end in a GISB timeout
 * => CPU bus error => SIGBUS (this killed the first version of this tool on
 * the 0x408840+ area, which has no registers behind it).  On BMIPS the bus
 * error is IMPRECISE: the SIGBUS lands a few instructions after the faulting
 * load, so a sigsetjmp window around the access is not reliable.  The dump
 * therefore reads each word in a forked child (child dies => "BUSERR..",
 * parent carries on), with a sync + settle delay so the pending exception
 * lands inside the child.  The programming/poll phase only touches the
 * documented window registers, canary-tested via a child first; the
 * sigsetjmp guard is kept there as a best-effort backstop.
 *
 * Usage: kir_probe [seconds] [-noirq] [-dump]
 *   default: program the block, poll ~20 s, print every frame + L1 changes
 *   -noirq: don't set CTRL bit5 (skip IRQ routing check)
 *   -dump:  just hex-dump the KIR region and exit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define PAGE      0x1000u
#define PAGEMASK  (~(PAGE - 1))

#define KIR_PAGE  0x10408000u
#define KIR_WIN0  (0x104088c0u - KIR_PAGE)   /* channel 0 window */
#define KIR_TOP   (0x10408b80u - KIR_PAGE)   /* top-level routing */

/* L1 intc: 3 words of 32 (96 hwirqs — reg size 0x30 in the dtsi, matching
 * the bcm7038-l1 layout: status w0-2 @+0x00, mask_status w0-2 @+0x0c,
 * mask_set @+0x18, mask_clr @+0x24).  hwirq "115" cannot exist here — the
 * old 4-word assumption read mask_status w0 and called it status w3. */
#define L1_PAGE   0x10411000u
#define L1_CPU0   (0x10411400u - L1_PAGE)
#define L1_CPU1   (0x10411600u - L1_PAGE)
#define L1_WORDS  3

/* UPG IRQ0 L2 (0x406780, 7425-style layout, see bcm7231.dtsi): the likely
 * home of the KIR interrupt.  Bits 16-18 are the UART fwd gates — never
 * touch them. */
#define UPG_PAGE  0x10406000u
#define UPG_EN    (0x10406780u - UPG_PAGE)
#define UPG_STAT  (0x10406784u - UPG_PAGE)
#define UART_FWD  0x70000u

/* window register offsets (in words) */
#define W_STATUS  0x00
#define W_FILTER1 0x02
#define W_DATA_LO 0x03
#define W_DATA_HI 0x04
#define W_CTRL    0x05
#define W_CIR_IDX 0x06
#define W_CIR_VAL 0x07

/* Ruwido CIR parameter file, protocol 0x17, dumped from nexus.ko .rodata
 * (struct @ 0x30b10) and packed exactly like BKIR_P_ConfigCir does.
 * Index 24 is never written. */
static const struct { uint8_t idx; uint16_t val; } CIR[] = {
    {  0, 0x019 }, {  1, 0x000 }, {  2, 0x001 }, {  3, 0xca5 },
    {  4, 0x000 }, {  5, 0x000 }, {  6, 0x000 }, {  7, 0x000 },
    {  8, 0x000 }, {  9, 0x000 }, { 10, 0x000 }, { 11, 0x210 },
    { 12, 0x000 }, { 13, 0xc43 }, { 14, 0x145 }, { 15, 0x000 },
    { 16, 0x035 }, { 17, 0x043 }, { 18, 0x180 }, { 19, 0x0f9 },
    { 20, 0x004 }, { 21, 0x003 }, { 22, 0x000 }, { 23, 0x000 },
    { 25, 0x000 }, { 26, 0x400 }, { 27, 0x000 },
};

/* key index -> Linux keycode, dumped from nexus_input.ko .rodata */
static const uint16_t KEYMAP[128] = {
    [0x16] = 10, [0x17] = 9, [0x18] = 8, [0x19] = 7, [0x1a] = 6,
    [0x1b] = 5, [0x1c] = 4, [0x1d] = 3, [0x1e] = 2, [0x1f] = 11,
    [0x25] = 226, [0x28] = 139, [0x2a] = 115, [0x2c] = 217,
    [0x2d] = 168, [0x2e] = 60, [0x2f] = 207, [0x30] = 119,
    [0x31] = 167, [0x33] = 388, [0x34] = 116, [0x35] = 114,
    [0x36] = 358, [0x37] = 102, [0x39] = 159, [0x3a] = 365,
    [0x3d] = 128, [0x3e] = 59, [0x57] = 108, [0x58] = 106,
    [0x59] = 103, [0x5a] = 105, [0x5d] = 403, [0x5e] = 402,
    [0x64] = 14, [0x72] = 353,
};

static int fd;

/* ---- SIGBUS-guarded MMIO -------------------------------------------- */

static sigjmp_buf mmio_jb;
static volatile sig_atomic_t mmio_armed;

static void mmio_fault(int sig)
{
    (void)sig;
    if (mmio_armed) {
        mmio_armed = 0;
        siglongjmp(mmio_jb, 1);
    }
    /* imprecise bus error landed outside a guard */
    static const char msg[] = "\n!! imprecise SIGBUS outside guard\n";
    write(2, msg, sizeof(msg) - 1);
    _exit(128 + SIGBUS);
}

static void mmio_sync(void)
{
#ifdef __mips__
    __asm__ __volatile__("sync" ::: "memory");
#endif
}

/* returns 0 on success, -1 if the access bus-errored */
static int rd32(volatile uint32_t *p, uint32_t *out)
{
    if (sigsetjmp(mmio_jb, 1))
        return -1;
    mmio_armed = 1;
    *out = *p;
    mmio_sync();
    mmio_armed = 0;
    return 0;
}

static int wr32(volatile uint32_t *p, uint32_t v)
{
    if (sigsetjmp(mmio_jb, 1))
        return -1;
    mmio_armed = 1;
    *p = v;
    mmio_sync();
    mmio_armed = 0;
    return 0;
}

/* Robust probe for possibly-unbacked registers: read in a forked child so
 * an imprecise bus error only kills the child.  Returns 0 + value, or -1. */
static int probe_word(volatile uint32_t *p, uint32_t *out)
{
    int pfd[2], status;
    uint32_t v;
    pid_t pid;

    if (pipe(pfd)) { perror("pipe"); exit(1); }
    pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        signal(SIGBUS, SIG_DFL);
        signal(SIGSEGV, SIG_DFL);
        v = *p;
        mmio_sync();
        usleep(2000);          /* let a pending imprecise bus error land */
        write(pfd[1], &v, 4);
        _exit(0);
    }
    close(pfd[1]);
    if (waitpid(pid, &status, 0) < 0 ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        read(pfd[0], &v, 4) != 4) {
        close(pfd[0]);
        return -1;
    }
    close(pfd[0]);
    *out = v;
    return 0;
}

/* read for printf contexts: faulting words show up as 0xbadacce5 */
static uint32_t rdv(volatile uint32_t *p)
{
    uint32_t v;
    return rd32(p, &v) ? 0xbadacce5 : v;
}

static volatile uint32_t *mp(uint32_t phys)
{
    void *m = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   phys & PAGEMASK);
    if (m == MAP_FAILED) { perror("mmap"); exit(1); }
    return (volatile uint32_t *)m;
}

int main(int argc, char **argv)
{
    int secs = 20, noirq = 0, dump = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-noirq")) noirq = 1;
        else if (!strcmp(argv[i], "-dump")) dump = 1;
        else secs = atoi(argv[i]);
    }

    setvbuf(stdout, NULL, _IONBF, 0);   /* keep output if we still die */

    struct sigaction sa = { .sa_handler = mmio_fault };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }

    volatile uint32_t *kir = mp(KIR_PAGE);
    volatile uint32_t *l1  = mp(L1_PAGE);
    volatile uint32_t *upg = mp(UPG_PAGE);
    volatile uint32_t *win = kir + KIR_WIN0 / 4;
    volatile uint32_t *top = kir + KIR_TOP / 4;

    printf("KIR region before (phys 0x10408800+., BUSERR = GISB abort):\n");
    for (int a = 0x800; a < 0x9c0; a += 0x10) {
        char row[4][12];
        for (int w = 0; w < 4; w++) {
            uint32_t v;
            if (probe_word(&kir[a/4 + w], &v))
                snprintf(row[w], sizeof(row[w]), "BUSERR..");
            else
                snprintf(row[w], sizeof(row[w]), "%08x", v);
        }
        printf("  +0x%03x: %s %s %s %s\n", a, row[0], row[1], row[2], row[3]);
    }
    uint32_t topv;
    if (probe_word(&top[0], &topv))
        printf("  KIR_TOP(0x408b80)=BUSERR\n");
    else
        printf("  KIR_TOP(0x408b80)=%08x\n", topv);
    printf("  L1 CPU0 status: %08x %08x %08x  mask: %08x %08x %08x\n",
           rdv(&l1[L1_CPU0/4+0]), rdv(&l1[L1_CPU0/4+1]), rdv(&l1[L1_CPU0/4+2]),
           rdv(&l1[L1_CPU0/4+3]), rdv(&l1[L1_CPU0/4+4]), rdv(&l1[L1_CPU0/4+5]));
    printf("  UPG_IRQ0: EN=%08x STAT=%08x\n",
           rdv(&upg[UPG_EN/4]), rdv(&upg[UPG_STAT/4]));
    if (dump) return 0;

    /* --- program channel 0 for Ruwido (protocol 0x17) --- */
    uint32_t sctrl, stop_;
    if (probe_word(&win[W_CTRL], &sctrl) || probe_word(&top[0], &stop_)) {
        printf("\nchannel-0 window / KIR_TOP bus-error on read: the block "
               "itself is\nunreachable (clock-gated or wrong address) — "
               "nothing to program.\n");
        return 3;
    }
    wr32(&win[W_CTRL], 7);               /* BKIR_OpenChannel */
    wr32(&top[0], stop_ | 1);            /* route channel 0 */
    for (unsigned i = 0; i < sizeof(CIR)/sizeof(CIR[0]); i++) {
        wr32(&win[W_CIR_IDX], CIR[i].idx); /* BKIR_P_WriteCirParam */
        wr32(&win[W_CIR_VAL], CIR[i].val & 0xfff);
    }
    wr32(&win[W_FILTER1], 0);            /* BKIR_EnableIrDevice(0x17) */
    wr32(&win[W_CTRL], 7 | 0x10 | (noirq ? 0 : 0x20));
    wr32(&win[W_STATUS], rdv(&win[W_STATUS]) & ~1u);  /* ack stale frame */

    printf("\nprogrammed: CTRL=%08x TOP=%08x FILTER1=%08x STATUS=%08x\n",
           rdv(&win[W_CTRL]), rdv(&top[0]),
           rdv(&win[W_FILTER1]), rdv(&win[W_STATUS]));
    printf("CIR param readback:");
    for (int i = 0; i < 28; i++) {
        wr32(&win[W_CIR_IDX], i);
        printf("%s%03x", (i % 7 == 0) ? "\n  " : " ", rdv(&win[W_CIR_VAL]) & 0xfff);
    }
    printf("\n");

    printf("\npolling %ds — press the remote...\n", secs);
    uint32_t l1b[2 * L1_WORDS];
    for (int k = 0; k < 2 * L1_WORDS; k++)
        l1b[k] = rdv(&l1[(k < L1_WORDS ? L1_CPU0 : L1_CPU1)/4 + k % L1_WORDS]);
    uint32_t upg_base = rdv(&upg[UPG_STAT/4]);
    int frames = 0;
    for (long t = 0; t < (long)secs * 100; t++) {
        uint32_t st;
        if (rd32(&win[W_STATUS], &st)) {
            printf("STATUS bus-errored mid-poll — block died, stopping.\n");
            break;
        }
        if (st & 1) {
            uint32_t hi = rdv(&win[W_DATA_HI]), lo = rdv(&win[W_DATA_LO]);
            unsigned cnt = (st >> 2) & 7;
            uint32_t code = hi;     /* nexus assembles LE bytes = reg value */
            uint32_t ust = rdv(&upg[UPG_STAT/4]);
            uint32_t l1p[L1_WORDS];
            for (int w = 0; w < L1_WORDS; w++)
                l1p[w] = rdv(&l1[L1_CPU0/4 + w]);
            frames++;
            printf("frame: STATUS=%08x count=%u DATA_HI=%08x DATA_LO=%08x",
                   st, cnt, hi, lo);
            if ((code & 0x7fff) - 0x7e00 < 0x100) {
                unsigned idx = code & 0x7f;
                printf("  => RUWIDO key 0x%02x keycode=%u%s", idx,
                       KEYMAP[idx], (st & 2) ? " (repeat)" : "");
            } else if (code) {
                printf("  (unrecognized)");
            }
            printf("\n  pending: UPG STAT=%08x (new %08x)  L1 %08x %08x %08x\n",
                   ust, ust & ~upg_base & ~UART_FWD, l1p[0], l1p[1], l1p[2]);

            /* cascade experiment: enable the new UPG bit(s) in IRQEN just
             * long enough to see which L1 line asserts, then restore */
            uint32_t cand = ust & ~upg_base & ~UART_FWD;
            if (cand && !noirq) {
                uint32_t en0 = rdv(&upg[UPG_EN/4]);
                wr32(&upg[UPG_EN/4], en0 | cand);
                usleep(2000);
                for (int w = 0; w < L1_WORDS; w++) {
                    uint32_t nw = rdv(&l1[L1_CPU0/4 + w]) & ~l1p[w];
                    for (int b = 0; b < 32; b++)
                        if (nw & (1u << b))
                            printf("  cascade: UPG bits %08x => L1 hwirq %d  <== upg_main!\n",
                                   cand, w * 32 + b);
                }
                wr32(&upg[UPG_EN/4], en0);
            }

            wr32(&win[W_STATUS], st & ~1u);   /* ack */
            usleep(2000);
            uint32_t ust2 = rdv(&upg[UPG_STAT/4]);
            printf("  after ack: UPG STAT=%08x (cleared %08x)",
                   ust2, ust & ~ust2);
            for (int w = 0; w < L1_WORDS; w++) {
                uint32_t cl = l1p[w] & ~rdv(&l1[L1_CPU0/4 + w]);
                for (int b = 0; b < 32; b++)
                    if (cl & (1u << b))
                        printf("  L1 hwirq %d cleared", w * 32 + b);
            }
            printf("\n");
        }
        for (int k = 0; k < 2 * L1_WORDS; k++) {
            uint32_t now;
            if (rd32(&l1[(k < L1_WORDS ? L1_CPU0 : L1_CPU1)/4 + k % L1_WORDS],
                     &now))
                continue;
            uint32_t d = now & ~l1b[k];
            if (d) {
                for (int b = 0; b < 32; b++)
                    if (d & (1u << b))
                        printf("L1 cpu%d W%d bit %d => hwirq %d\n",
                               k < L1_WORDS ? 0 : 1, k % L1_WORDS, b,
                               (k % L1_WORDS) * 32 + b);
                l1b[k] = now;
            }
        }
        usleep(10000);
    }

    printf("\n%d frame(s) received.\n", frames);
    wr32(&win[W_CTRL], sctrl);           /* restore */
    wr32(&top[0], stop_);
    return frames ? 0 : 2;
}
