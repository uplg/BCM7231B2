/*
 * ephy_init.c — BCM7231 internal EPHY power-on sequence
 *
 * Replicates bcm7231_pm_genet_enable(0) from the vendor kernel 3.3.8.
 * The upstream Linux 6.18 bcmgenet driver does NOT perform the SoC-specific
 * CLKGEN register writes needed to bring the internal EPHY out of power-down.
 *
 * Reverse-engineered from mtd4_backup.bin (vendor kernel ELF, not stripped):
 *   bcm7231_pm_genet_enable @ 0x80277810, 0xe8 bytes
 *
 * Physical register addresses (CLKGEN block at 0x10420000):
 *   0x10420200 — GENET soft reset (toggle bit 1)
 *   0x104201EC — GENET clock gate (clear bits 0-2 to enable)
 *   0x104201F0 — GENET power enable (set bits 0-6)
 *
 * Usage: /sbin/ephy_init
 * Must run BEFORE ifconfig eth0 up.
 * Requires /dev/mem (CONFIG_DEVMEM=y, no CONFIG_STRICT_DEVMEM).
 *
 * Build: mipsel-linux-musl-gcc -static -O2 -o ephy_init ephy_init.c
 *
 * FROG-HACK project — AirTies AIR 7310T (BCM7231B2)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

/* CLKGEN block physical base */
#define CLKGEN_BASE     0x10420000
#define CLKGEN_SIZE     0x1000

/* Offsets within CLKGEN */
#define GENET_RST_OFF   0x200   /* Soft reset register */
#define GENET_CLK_OFF   0x1EC   /* Clock gate register */
#define GENET_PWR_OFF   0x1F0   /* Power enable register */

static volatile uint32_t *clkgen;

static inline uint32_t reg_read(unsigned off)
{
	return clkgen[off / 4];
}

static inline void reg_write(unsigned off, uint32_t val)
{
	clkgen[off / 4] = val;
	/* readback to flush write buffer */
	(void)clkgen[off / 4];
}

int main(void)
{
	int fd;
	uint32_t reg;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("ephy_init: open /dev/mem");
		return 1;
	}

	clkgen = mmap(NULL, CLKGEN_SIZE, PROT_READ | PROT_WRITE,
		      MAP_SHARED, fd, CLKGEN_BASE);
	if (clkgen == MAP_FAILED) {
		perror("ephy_init: mmap CLKGEN");
		close(fd);
		return 1;
	}

	printf("ephy_init: powering on GENET/EPHY (BCM7231 instance 0)\n");

	/*
	 * Step 1: GENET soft reset — toggle bit 1 at 0x10420200
	 * Vendor code: (reg & ~0x3) | 0x2, delay 10us, then reg & ~0x3
	 */
	reg = reg_read(GENET_RST_OFF);
	printf("  CLKGEN+0x200 before: 0x%08X\n", reg);
	reg_write(GENET_RST_OFF, (reg & ~0x3u) | 0x2u);
	usleep(10);
	reg = reg_read(GENET_RST_OFF);
	reg_write(GENET_RST_OFF, reg & ~0x3u);
	printf("  CLKGEN+0x200 after:  0x%08X\n", reg_read(GENET_RST_OFF));

	/*
	 * Step 2: Enable GENET clocks — clear bits 0-2 at 0x104201EC
	 */
	reg = reg_read(GENET_CLK_OFF);
	printf("  CLKGEN+0x1EC before: 0x%08X\n", reg);
	reg_write(GENET_CLK_OFF, reg & ~0x7u);
	printf("  CLKGEN+0x1EC after:  0x%08X\n", reg_read(GENET_CLK_OFF));

	/*
	 * Step 3: Power enable — set bits 0-6 at 0x104201F0
	 */
	reg = reg_read(GENET_PWR_OFF);
	printf("  CLKGEN+0x1F0 before: 0x%08X\n", reg);
	reg_write(GENET_PWR_OFF, reg | 0x7Fu);
	printf("  CLKGEN+0x1F0 after:  0x%08X\n", reg_read(GENET_PWR_OFF));

	printf("ephy_init: done. EPHY should be powered on.\n");

	munmap((void *)clkgen, CLKGEN_SIZE);
	close(fd);
	return 0;
}
