/*
 * irq_dump.c — BCM7231 L1 interrupt controller register dump
 *
 * Reads the bcm7038-l1-intc registers at 0x10411400 (CPU0) and
 * 0x10411600 (CPU1) to show which IRQ bits are pending/masked.
 *
 * Also reads L2 upg_irq0_intc at 0x10406600 (status + mask).
 *
 * Usage:
 *   /sbin/irq_dump              — single snapshot
 *   /sbin/irq_dump watch        — loop every ~500ms (Ctrl-C to stop)
 *   /sbin/irq_dump <hex_addr>   — read single 32-bit register
 *   /sbin/irq_dump scan <start> <end> [<step>]
 *       — scan address range, print non-zero/non-FF registers
 *         step defaults to 4. Safely skips GISB-faulting addresses.
 *
 * Requires /dev/mem.
 * Build: mipsel-linux-musl-gcc -static -O2 -o irq_dump irq_dump.c
 *
 * FROG-HACK project — AirTies AIR 7310T (BCM7231B2)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>

/*
 * BCM7038-L1 register layout (per CPU, 96 IRQs = 3x32-bit banks):
 *   +0x00  W0_STATUS        (bank 0, IRQs 0-31)
 *   +0x04  W1_STATUS        (bank 1, IRQs 32-63)
 *   +0x08  W2_STATUS        (bank 2, IRQs 64-95)
 *   +0x0C  W0_MASK_STATUS
 *   +0x10  W1_MASK_STATUS
 *   +0x14  W2_MASK_STATUS
 *   +0x18  W0_MASK_SET
 *   +0x1C  W1_MASK_SET
 *   +0x20  W2_MASK_SET
 *   +0x24  W0_MASK_CLEAR
 *   +0x28  W1_MASK_CLEAR
 *   +0x2C  W2_MASK_CLEAR
 */

#define L1_CPU0_BASE   0x10411400
#define L1_CPU1_BASE   0x10411600
#define L1_BANK_SIZE   0x30

/* BCM7120-L2 (upg_irq0_intc) at 0x10406600 */
#define UPG_L2_BASE    0x10406600
#define UPG_L2_SIZE    0x08
/* +0x00 = status, +0x04 = mask/enable (varies by implementation) */

#define PAGE_SIZE_     4096
#define PAGE_MASK_     (~(PAGE_SIZE_ - 1))

static int mem_fd = -1;

/* --- Bus error recovery for scan mode --- */
static sigjmp_buf bus_jmp;
static volatile int bus_fault;

static void bus_handler(int sig)
{
	(void)sig;
	bus_fault = 1;
	siglongjmp(bus_jmp, 1);
}

static volatile uint32_t *map_phys(uint32_t phys_addr, uint32_t size)
{
	uint32_t page_base = phys_addr & PAGE_MASK_;
	uint32_t offset = phys_addr - page_base;
	uint32_t map_len = offset + size;

	void *m = mmap(NULL, map_len, PROT_READ, MAP_SHARED, mem_fd, page_base);
	if (m == MAP_FAILED) {
		perror("mmap");
		return NULL;
	}
	return (volatile uint32_t *)((char *)m + offset);
}

static uint32_t read_phys32(uint32_t phys_addr)
{
	volatile uint32_t *p = map_phys(phys_addr, 4);
	if (!p) return 0xDEADDEAD;
	uint32_t v = *p;
	munmap((void *)((uintptr_t)p & PAGE_MASK_), PAGE_SIZE_);
	return v;
}

/* Safe read: returns 1 on success, 0 on bus error */
static int read_phys32_safe(uint32_t phys_addr, uint32_t *out)
{
	volatile uint32_t *p = map_phys(phys_addr, 4);
	if (!p) return 0;

	bus_fault = 0;
	if (sigsetjmp(bus_jmp, 1) != 0) {
		/* Returned from bus error */
		munmap((void *)((uintptr_t)p & PAGE_MASK_), PAGE_SIZE_);
		return 0;
	}

	struct sigaction sa, old_bus, old_segv;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = bus_handler;
	sa.sa_flags = 0;
	sigaction(SIGBUS, &sa, &old_bus);
	sigaction(SIGSEGV, &sa, &old_segv);

	*out = *p;

	sigaction(SIGBUS, &old_bus, NULL);
	sigaction(SIGSEGV, &old_segv, NULL);
	munmap((void *)((uintptr_t)p & PAGE_MASK_), PAGE_SIZE_);
	return 1;
}

static void print_bits(uint32_t val, int base_irq)
{
	int i;
	for (i = 0; i < 32; i++) {
		if (val & (1u << i))
			printf("  %d", base_irq + i);
	}
}

static void dump_l1(const char *label, uint32_t base)
{
	volatile uint32_t *regs = map_phys(base, L1_BANK_SIZE);
	if (!regs) {
		printf("%s: mmap failed\n", label);
		return;
	}

	uint32_t st0  = regs[0x00/4];
	uint32_t st1  = regs[0x04/4];
	uint32_t st2  = regs[0x08/4];
	uint32_t ms0  = regs[0x0C/4];
	uint32_t ms1  = regs[0x10/4];
	uint32_t ms2  = regs[0x14/4];

	printf("=== %s (0x%08X) ===\n", label, base);
	printf("STATUS:      [0-31]=0x%08X  [32-63]=0x%08X  [64-95]=0x%08X\n", st0, st1, st2);
	printf("MASK_STATUS: [0-31]=0x%08X  [32-63]=0x%08X  [64-95]=0x%08X\n", ms0, ms1, ms2);

	/* Pending = status & ~mask (mask=1 means disabled on bcm7038) */
	uint32_t p0 = st0 & ~ms0;
	uint32_t p1 = st1 & ~ms1;
	uint32_t p2 = st2 & ~ms2;
	printf("PENDING (status & ~mask):");
	if (p0 || p1 || p2) {
		print_bits(p0, 0);
		print_bits(p1, 32);
		print_bits(p2, 64);
	} else {
		printf(" (none)");
	}
	printf("\n");

	/* Enabled = ~mask */
	printf("ENABLED (~mask):");
	print_bits(~ms0, 0);
	print_bits(~ms1, 32);
	print_bits(~ms2, 64);
	printf("\n");

	/* Raw status bits set */
	printf("RAW STATUS bits set:");
	if (st0 || st1 || st2) {
		print_bits(st0, 0);
		print_bits(st1, 32);
		print_bits(st2, 64);
	} else {
		printf(" (none)");
	}
	printf("\n\n");
}

static void dump_upg_l2(void)
{
	volatile uint32_t *regs = map_phys(UPG_L2_BASE, UPG_L2_SIZE);
	if (!regs) {
		printf("UPG L2: mmap failed\n");
		return;
	}

	uint32_t r0 = regs[0x00/4];
	uint32_t r1 = regs[0x04/4];

	printf("=== UPG L2 (upg_irq0_intc @ 0x%08X) ===\n", UPG_L2_BASE);
	printf("REG+0x00 = 0x%08X\n", r0);
	printf("REG+0x04 = 0x%08X\n", r1);
	printf("Bits set in +0x00:");
	if (r0) print_bits(r0, 0); else printf(" (none)");
	printf("\nBits set in +0x04:");
	if (r1) print_bits(r1, 0); else printf(" (none)");
	printf("\n\n");
}

static void dump_all(void)
{
	dump_l1("L1 CPU0", L1_CPU0_BASE);
	dump_l1("L1 CPU1", L1_CPU1_BASE);
	dump_upg_l2();
}

/* --- Scan mode: sweep a physical address range --- */
static void scan_range(uint32_t start, uint32_t end, uint32_t step)
{
	uint32_t addr;
	int found = 0;

	printf("Scanning 0x%08X — 0x%08X (step %u)\n", start, end, step);
	printf("Showing non-zero, non-0xFFFFFFFF values:\n\n");

	for (addr = start; addr <= end; addr += step) {
		uint32_t val;
		if (!read_phys32_safe(addr, &val)) {
			/* Bus error — skip silently */
			continue;
		}
		if (val != 0x00000000 && val != 0xFFFFFFFF) {
			printf("[0x%08X] = 0x%08X", addr, val);
			/* Annotate known registers */
			if (addr == L1_CPU0_BASE)        printf("  <- L1 CPU0 W0_STATUS");
			else if (addr == L1_CPU0_BASE+4) printf("  <- L1 CPU0 W1_STATUS");
			else if (addr == L1_CPU0_BASE+8) printf("  <- L1 CPU0 W2_STATUS");
			else if (addr == L1_CPU1_BASE)   printf("  <- L1 CPU1 W0_STATUS");
			else if (addr == UPG_L2_BASE)    printf("  <- UPG L2 status");
			else if (addr == UPG_L2_BASE+4)  printf("  <- UPG L2 mask");
			else if (addr == 0x10404000)     printf("  <- SUN_TOP PRODUCT_ID_0");
			else if (addr == 0x10404004)     printf("  <- SUN_TOP PRODUCT_ID_1");
			printf("\n");
			found++;
		}
	}
	printf("\n%d non-trivial registers found.\n", found);
}

int main(int argc, char *argv[])
{
	mem_fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (mem_fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	/* Single register read mode: irq_dump 0xADDR */
	if (argc == 2 && argv[1][0] == '0' && argv[1][1] == 'x') {
		uint32_t addr = strtoul(argv[1], NULL, 16);
		uint32_t val = read_phys32(addr);
		printf("[0x%08X] = 0x%08X\n", addr, val);
		close(mem_fd);
		return 0;
	}

	/* Watch mode: irq_dump watch */
	if (argc == 2 && strcmp(argv[1], "watch") == 0) {
		printf("Watching L1/L2 IRQ registers (Ctrl-C to stop)...\n\n");
		while (1) {
			dump_all();
			printf("---\n\n");
			usleep(500000);
		}
	}

	/* Scan mode: irq_dump scan <start> <end> [step] */
	if (argc >= 4 && strcmp(argv[1], "scan") == 0) {
		uint32_t start = strtoul(argv[2], NULL, 16);
		uint32_t end   = strtoul(argv[3], NULL, 16);
		uint32_t step  = (argc >= 5) ? strtoul(argv[4], NULL, 0) : 4;
		if (step < 4) step = 4;
		if (end < start) {
			printf("Error: end < start\n");
			close(mem_fd);
			return 1;
		}
		scan_range(start, end, step);
		close(mem_fd);
		return 0;
	}

	/* Default: single dump */
	dump_all();

	close(mem_fd);
	return 0;
}
