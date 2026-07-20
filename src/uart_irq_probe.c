/*
 * uart_irq_probe.c — find/verify the real IRQ routing of the BCM7231 UARTs.
 *
 * Findings from the vendor 3.3.8 kernel binary (backup/mtd4_backup.bin,
 * unstripped — see arch_init_irq and brcm_intc_enable):
 *   - IRQ0_IRQEN lives at 0x10406780 (7425-style UPG layout), NOT 0x406600
 *     (7362 layout) as previously assumed.  arch_init_irq writes 0x70000
 *     there: bits 16/17/18 = uarta/b/c_irqen, gating each UART's INTR
 *     toward its dedicated L1 line.
 *   - brcm_16550_ports registers the UARTs as vendor IRQ 65/66/67 and
 *     brcm_intc_enable maps those to L1 W2 mask bits 0/1/2 => L1 hwirq
 *     64/65/66.
 * So the expected chain is: UART INTR -> IRQ0_IRQEN gate bit (16+n) ->
 * L1 hwirq 64+n.  This tool validates that chain from userspace.
 *
 * v2 fixes over the first version:
 *   - the "after" snapshot is taken BEFORE reading IIR: on a 16550,
 *     reading IIR while THRE is the pending source ACKNOWLEDGES it and
 *     drops INTR, which is why v1 saw no bit move anywhere.
 *   - L2 registers read at the real base 0x406780 (0x406600 kept for
 *     comparison).
 *   - optional -gate flag: temporarily sets uartN_irqen (bit 16+n) in
 *     IRQ0_IRQEN during the stimulus, restoring it afterwards.  Safe on
 *     the polling kernel: L1 lines 64-66 are masked and unclaimed.
 *
 * Usage: uart_irq_probe [0|1|2] [-gate]      (default: uart 2, no gate)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGE      0x1000u
#define PAGEMASK  (~(PAGE - 1))

/* bcm7038-l1: three 32-bit STATUS banks (raw, pre-mask), CPU0 and CPU1 */
#define L1_CPU0   0x10411400u
#define L1_CPU1   0x10411600u
/* UPG IRQ0 (bcm7120-l2): IRQEN=+0x00, IRQSTAT=+0x04 — vendor-verified base */
#define IRQ0_BASE 0x10406780u
/* old (wrong, 7362-layout) base the DTS used to point at — read for info */
#define OLD_L2    0x10406600u
/* UARTs, reg-shift=2 so 16550 reg N is at byte N*4 */
static const uint32_t UART[3] = { 0x10406900u, 0x10406940u, 0x10406980u };
#define IER_OFF   0x04u    /* reg 1 */
#define IIR_OFF   0x08u    /* reg 2 (read) — interrupt identification */
#define MCR_OFF   0x10u    /* reg 4 */
#define LSR_OFF   0x14u    /* reg 5 */
#define IER_THRI  0x02u
#define MCR_OUT2  0x08u    /* gates the 16550 INTR pin — must be set */
#define LSR_THRE  0x20u
#define IIR_NOPEND 0x01u   /* bit0=1 -> no interrupt pending */

static int fd;

static volatile uint32_t *mp(uint32_t phys, uint32_t *off)
{
    uint32_t base = phys & PAGEMASK;
    *off = (phys - base) / 4;
    void *m = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    if (m == MAP_FAILED) { perror("mmap"); exit(1); }
    return (volatile uint32_t *)m;
}

int main(int argc, char **argv)
{
    int u = 2, gate = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-gate")) gate = 1;
        else u = atoi(argv[i]);
    }
    if (u < 0 || u > 2) { fprintf(stderr, "uart index 0..2\n"); return 1; }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }

    uint32_t o0, o1, gio, olo, uo;
    volatile uint32_t *c0  = mp(L1_CPU0, &o0);
    volatile uint32_t *c1  = mp(L1_CPU1, &o1);
    volatile uint32_t *irq0 = mp(IRQ0_BASE, &gio);
    volatile uint32_t *oldl2 = mp(OLD_L2, &olo);
    volatile uint32_t *ur  = mp(UART[u], &uo);

    printf("Probing ttyS%d @ 0x%08x  (gate=%s)\n", u, UART[u], gate ? "on" : "off");
    printf("IRQ0_IRQEN(0x10406780)=%08x  IRQ0_STAT(0x10406784)=%08x\n",
           irq0[gio + 0], irq0[gio + 1]);
    printf("old-l2(0x10406600)=%08x  old-l2(0x10406604)=%08x\n",
           oldl2[olo + 0], oldl2[olo + 1]);
    printf("LSR=0x%02x (THRE=%s)  IER=0x%02x  MCR=0x%02x\n",
           ur[uo + LSR_OFF/4] & 0xff,
           (ur[uo + LSR_OFF/4] & LSR_THRE) ? "empty" : "busy",
           ur[uo + IER_OFF/4] & 0xff, ur[uo + MCR_OFF/4] & 0xff);

    uint32_t B[7] = { c0[o0+0], c0[o0+1], c0[o0+2],
                      c1[o1+0], c1[o1+1], c1[o1+2], irq0[gio+1] };
    printf("before  L1cpu0[%08x %08x %08x] L1cpu1[%08x %08x %08x] IRQ0.STAT=%08x\n",
           B[0],B[1],B[2],B[3],B[4],B[5],B[6]);

    uint32_t sen = irq0[gio + 0];
    if (gate)
        irq0[gio + 0] = sen | (1u << (16 + u));   /* uartN_irqen */

    uint32_t smcr = ur[uo + MCR_OFF/4], sier = ur[uo + IER_OFF/4];
    ur[uo + MCR_OFF/4] = smcr | MCR_OUT2;   /* connect INTR pin */
    ur[uo + IER_OFF/4] = IER_THRI;          /* THR empty -> asserts */
    for (volatile int i = 0; i < 500000; i++) ;

    /* snapshot FIRST — reading IIR acks the THRE interrupt (v1's bug) */
    uint32_t A[7] = { c0[o0+0], c0[o0+1], c0[o0+2],
                      c1[o1+0], c1[o1+1], c1[o1+2], irq0[gio+1] };
    printf("after   L1cpu0[%08x %08x %08x] L1cpu1[%08x %08x %08x] IRQ0.STAT=%08x\n",
           A[0],A[1],A[2],A[3],A[4],A[5],A[6]);

    uint32_t iir = ur[uo + IIR_OFF/4] & 0xff;   /* also acks THRE */
    printf("UART IIR=0x%02x -> %s\n",
           iir, (iir & IIR_NOPEND) ? "NO interrupt pending" : "interrupt PENDING");

    ur[uo + IER_OFF/4] = sier;              /* restore */
    ur[uo + MCR_OFF/4] = smcr;
    if (gate)
        irq0[gio + 0] = sen;

    printf("\n--- bits that turned 0->1 ---\n");
    const char *nm[7] = {
        "L1 cpu0 W0 (hwirq 0-31)",  "L1 cpu0 W1 (hwirq 32-63)", "L1 cpu0 W2 (hwirq 64-95)",
        "L1 cpu1 W0 (hwirq 0-31)",  "L1 cpu1 W1 (hwirq 32-63)", "L1 cpu1 W2 (hwirq 64-95)",
        "IRQ0_IRQSTAT (0x406784)" };
    int base[7] = { 0, 32, 64, 0, 32, 64, -1 };
    int found = 0;
    for (int k = 0; k < 7; k++) {
        uint32_t d = A[k] & ~B[k];
        for (int b = 0; b < 32; b++) {
            if (d & (1u << b)) {
                found = 1;
                if (base[k] >= 0)
                    printf("  %-26s bit %-2d => periph_intc hwirq %d%s\n",
                           nm[k], b, base[k] + b,
                           (base[k] + b == 64 + u) ? "   <== expected line!" : "");
                else
                    printf("  %-26s bit %-2d\n", nm[k], b);
            }
        }
    }
    if (!found)
        printf("  (nothing%s)\n", gate ? "" : " — retry with -gate to open IRQ0_IRQEN");
    return 0;
}
