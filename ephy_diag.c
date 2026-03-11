/*
 * ephy_diag.c — BCM7231 GENET/EPHY diagnostic and initialization tool
 *
 * Dumps CLKGEN, GENET EXT, GENET UMAC, and PHY MDIO registers to understand
 * why the internal EPHY link never comes up. Also performs the vendor kernel's
 * bcm7231_pm_genet_enable(0) sequence and bcmgenet_ephy_workaround.
 *
 * Usage:
 *   /sbin/ephy_diag dump     — read and print all relevant registers
 *   /sbin/ephy_diag init     — perform CLKGEN + EPHY init + dump
 *   /sbin/ephy_diag reset    — toggle EXT_PHY_RESET + EPHY workaround + dump
 *   /sbin/ephy_diag full     — init + reset + dump (do everything)
 *
 * Requires /dev/mem (CONFIG_DEVMEM=y, no CONFIG_STRICT_DEVMEM).
 * Build: mipsel-linux-musl-gcc -static -O2 -o ephy_diag ephy_diag.c
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

/*
 * Physical address map (from vendor kernel + DTS):
 *   CLKGEN:     0x10420000  (clock/power management)
 *   GENET base: 0x10430000  (ethernet MAC)
 *   GENET EXT:  base + 0x0080  (external PHY power mgmt — used for internal too)
 *   GENET UMAC: base + 0x0800  (UniMAC registers)
 *   GENET MDIO: base + 0x0E14  (MDIO bus registers)
 *   SYS block:  base + 0x0000  (system/port control)
 */

#define CLKGEN_BASE   0x10420000
#define GENET_BASE    0x10430000
#define MAP_SIZE      0x10000       /* map enough to cover GENET + MDIO */

/* CLKGEN offsets (from bcm7231_pm_genet_enable RE) */
#define CLKGEN_RST    0x200
#define CLKGEN_CLK    0x1EC
#define CLKGEN_PWR    0x1F0

/* GENET register block offsets (GENET v2) */
#define GENET_SYS_OFF     0x0000
#define GENET_EXT_OFF     0x0080    /* EXT block for GENET v2 */
#define GENET_UMAC_OFF    0x0800
#define GENET_MDIO_OFF    0x0E14

/* EXT_EXT_PWR_MGMT bits */
#define EXT_PWR_DOWN_BIAS    (1 << 0)
#define EXT_PWR_DOWN_DLL     (1 << 1)
#define EXT_PWR_DOWN_PHY     (1 << 2)
#define EXT_PWR_DN_EN_LD     (1 << 3)
#define EXT_ENERGY_DET       (1 << 4)
#define EXT_IDDQ_FROM_PHY    (1 << 5)
#define EXT_IDDQ_GLBL_PWR    (1 << 7)
#define EXT_PHY_RESET        (1 << 8)
#define EXT_ENERGY_DET_MASK  (1 << 12)

/* MDIO registers (within GENET MDIO block) */
#define MDIO_CMD      0x00
#define MDIO_CFG      0x04   /* might not exist on v2, but let's try */

/* MDIO_CMD bits */
#define MDIO_START_BUSY  (1 << 29)
#define MDIO_READ_FAIL   (1 << 28)
#define MDIO_RD          (2 << 26)
#define MDIO_WR          (1 << 26)
#define MDIO_PMD_SHIFT   21
#define MDIO_REG_SHIFT   16

/* SYS_PORT_CTRL */
#define SYS_PORT_CTRL    0x04
#define SYS_RBUF_FLUSH   0x08
#define SYS_TBUF_FLUSH   0x0C
#define SYS_REV_CTRL     0x00  /* GENET version register */

/* UMAC registers */
#define UMAC_CMD         0x008
#define UMAC_MAC0        0x00C
#define UMAC_MAC1        0x010
#define UMAC_MODE        0x044
#define UMAC_MIB_CTRL    0x580

static volatile uint32_t *clkgen_map;
static volatile uint32_t *genet_map;

static uint32_t clkgen_read(unsigned off)   { return clkgen_map[off / 4]; }
static void clkgen_write(unsigned off, uint32_t v) { clkgen_map[off / 4] = v; (void)clkgen_map[off / 4]; }

static uint32_t genet_read(unsigned off)    { return genet_map[off / 4]; }
static void genet_write(unsigned off, uint32_t v)  { genet_map[off / 4] = v; (void)genet_map[off / 4]; }

/* MDIO read — bit-bang through GENET MDIO_CMD register */
static int mdio_read(int phy, int reg)
{
	uint32_t cmd;
	int timeout = 1000;

	cmd = MDIO_START_BUSY | MDIO_RD |
	      ((phy & 0x1f) << MDIO_PMD_SHIFT) |
	      ((reg & 0x1f) << MDIO_REG_SHIFT);
	genet_write(GENET_MDIO_OFF + MDIO_CMD, cmd);

	do {
		usleep(10);
		cmd = genet_read(GENET_MDIO_OFF + MDIO_CMD);
	} while ((cmd & MDIO_START_BUSY) && --timeout);

	if (timeout == 0) {
		printf("  MDIO read timeout (phy=%d reg=%d)\n", phy, reg);
		return -1;
	}
	if (cmd & MDIO_READ_FAIL) {
		printf("  MDIO read fail (phy=%d reg=%d)\n", phy, reg);
		return -1;
	}
	return cmd & 0xFFFF;
}

/* MDIO write */
static int mdio_write(int phy, int reg, uint16_t val)
{
	uint32_t cmd;
	int timeout = 1000;

	cmd = MDIO_START_BUSY | MDIO_WR |
	      ((phy & 0x1f) << MDIO_PMD_SHIFT) |
	      ((reg & 0x1f) << MDIO_REG_SHIFT) |
	      val;
	genet_write(GENET_MDIO_OFF + MDIO_CMD, cmd);

	do {
		usleep(10);
		cmd = genet_read(GENET_MDIO_OFF + MDIO_CMD);
	} while ((cmd & MDIO_START_BUSY) && --timeout);

	if (timeout == 0) {
		printf("  MDIO write timeout (phy=%d reg=%d val=0x%04X)\n", phy, reg, val);
		return -1;
	}
	return 0;
}

static void dump_registers(void)
{
	uint32_t reg;
	int val;

	printf("\n=== CLKGEN registers ===\n");
	printf("  CLKGEN+0x200 (reset):  0x%08X\n", clkgen_read(CLKGEN_RST));
	printf("  CLKGEN+0x1EC (clock):  0x%08X\n", clkgen_read(CLKGEN_CLK));
	printf("  CLKGEN+0x1F0 (power):  0x%08X\n", clkgen_read(CLKGEN_PWR));

	printf("\n=== GENET SYS registers ===\n");
	reg = genet_read(GENET_SYS_OFF + SYS_REV_CTRL);
	printf("  SYS_REV_CTRL:    0x%08X  (GENET version)\n", reg);
	printf("  SYS_PORT_CTRL:   0x%08X\n", genet_read(GENET_SYS_OFF + SYS_PORT_CTRL));

	printf("\n=== GENET EXT registers (base+0x%X) ===\n", GENET_EXT_OFF);
	reg = genet_read(GENET_EXT_OFF + 0x00);
	printf("  EXT_EXT_PWR_MGMT: 0x%08X\n", reg);
	printf("    PWR_DOWN_BIAS=%d  PWR_DOWN_DLL=%d  PWR_DOWN_PHY=%d\n",
	       !!(reg & EXT_PWR_DOWN_BIAS), !!(reg & EXT_PWR_DOWN_DLL), !!(reg & EXT_PWR_DOWN_PHY));
	printf("    PWR_DN_EN_LD=%d   ENERGY_DET=%d    IDDQ_FROM_PHY=%d\n",
	       !!(reg & EXT_PWR_DN_EN_LD), !!(reg & EXT_ENERGY_DET), !!(reg & EXT_IDDQ_FROM_PHY));
	printf("    IDDQ_GLBL_PWR=%d  PHY_RESET=%d     ENERGY_DET_MASK=%d\n",
	       !!(reg & EXT_IDDQ_GLBL_PWR), !!(reg & EXT_PHY_RESET), !!(reg & EXT_ENERGY_DET_MASK));
	/* Dump a few more EXT registers */
	printf("  EXT+0x04:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x04));
	printf("  EXT+0x08:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x08));
	printf("  EXT+0x0C:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x0C));
	printf("  EXT+0x10:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x10));
	printf("  EXT+0x14:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x14));
	printf("  EXT+0x18:          0x%08X\n", genet_read(GENET_EXT_OFF + 0x18));
	/* EXT+0x1C (EXT_GPHY_CTRL) does NOT exist on GENET v2 — causes GISB bus error! */

	printf("\n=== GENET UMAC registers (base+0x%X) ===\n", GENET_UMAC_OFF);
	printf("  UMAC_CMD:    0x%08X\n", genet_read(GENET_UMAC_OFF + UMAC_CMD));
	printf("  UMAC_MAC0:   0x%08X\n", genet_read(GENET_UMAC_OFF + UMAC_MAC0));
	printf("  UMAC_MAC1:   0x%08X\n", genet_read(GENET_UMAC_OFF + UMAC_MAC1));
	printf("  UMAC_MODE:   0x%08X\n", genet_read(GENET_UMAC_OFF + UMAC_MODE));

	printf("\n=== MDIO registers ===\n");
	printf("  MDIO_CMD raw:  0x%08X\n", genet_read(GENET_MDIO_OFF + MDIO_CMD));

	printf("\n=== PHY registers (MDIO addr 1) ===\n");
	/* Standard MII registers */
	const char *mii_names[] = {
		"BMCR", "BMSR", "PHYID1", "PHYID2",
		"ANAR", "ANLPAR", "ANER", "ANNPTR",
	};
	for (int i = 0; i < 8; i++) {
		val = mdio_read(1, i);
		if (val >= 0)
			printf("  MII reg %2d (%-7s): 0x%04X\n", i, mii_names[i], val);
	}
	/* Also try address 0 in case PHY is at 0 */
	printf("\n=== PHY registers (MDIO addr 0) ===\n");
	for (int i = 0; i < 4; i++) {
		val = mdio_read(0, i);
		if (val >= 0)
			printf("  MII reg %2d (%-7s): 0x%04X\n", i, mii_names[i], val);
	}

	/* Scan all MDIO addresses for PHYs */
	printf("\n=== MDIO bus scan ===\n");
	for (int addr = 0; addr < 32; addr++) {
		val = mdio_read(addr, 1); /* BMSR */
		if (val > 0 && val != 0xFFFF)
			printf("  PHY found at addr %d: BMSR=0x%04X\n", addr, val);
	}
}

static void do_clkgen_init(void)
{
	uint32_t reg;

	printf("\n--- CLKGEN init (bcm7231_pm_genet_enable) ---\n");

	/* Step 1: soft reset — toggle bit 1 */
	reg = clkgen_read(CLKGEN_RST);
	clkgen_write(CLKGEN_RST, (reg & ~0x3u) | 0x2u);
	usleep(10);
	reg = clkgen_read(CLKGEN_RST);
	clkgen_write(CLKGEN_RST, reg & ~0x3u);
	printf("  Reset toggled at CLKGEN+0x200\n");

	/* Step 2: enable clocks — clear bits 0-2 */
	reg = clkgen_read(CLKGEN_CLK);
	clkgen_write(CLKGEN_CLK, reg & ~0x7u);
	printf("  Clocks enabled at CLKGEN+0x1EC\n");

	/* Step 3: power enable — set bits 0-6 */
	reg = clkgen_read(CLKGEN_PWR);
	clkgen_write(CLKGEN_PWR, reg | 0x7Fu);
	printf("  Power enabled at CLKGEN+0x1F0\n");
}

static void do_ext_power_up(void)
{
	uint32_t reg;

	printf("\n--- EXT power-up (bcmgenet_power_up PASSIVE) ---\n");

	reg = genet_read(GENET_EXT_OFF + 0x00);
	printf("  EXT_PWR_MGMT before: 0x%08X\n", reg);

	/* Clear power-down bits, set PWR_DN_EN_LD */
	reg &= ~(EXT_PWR_DOWN_DLL | EXT_PWR_DOWN_BIAS | EXT_ENERGY_DET_MASK);
	reg &= ~EXT_PWR_DOWN_PHY;
	reg |= EXT_PWR_DN_EN_LD;
	/* Also clear IDDQ bits — these might be the missing piece */
	reg &= ~(EXT_IDDQ_FROM_PHY | EXT_IDDQ_GLBL_PWR);
	genet_write(GENET_EXT_OFF + 0x00, reg);
	printf("  EXT_PWR_MGMT after clear IDDQ/power-down: 0x%08X\n",
	       genet_read(GENET_EXT_OFF + 0x00));
}

static void do_phy_reset(void)
{
	uint32_t reg;

	printf("\n--- PHY hardware reset (EXT_PHY_RESET toggle) ---\n");

	/* Assert PHY reset */
	reg = genet_read(GENET_EXT_OFF + 0x00);
	reg |= EXT_PHY_RESET;
	genet_write(GENET_EXT_OFF + 0x00, reg);
	printf("  PHY_RESET asserted: 0x%08X\n", genet_read(GENET_EXT_OFF + 0x00));
	usleep(50000); /* 50ms */

	/* Deassert PHY reset */
	reg = genet_read(GENET_EXT_OFF + 0x00);
	reg &= ~EXT_PHY_RESET;
	genet_write(GENET_EXT_OFF + 0x00, reg);
	printf("  PHY_RESET deasserted: 0x%08X\n", genet_read(GENET_EXT_OFF + 0x00));
	usleep(50000); /* 50ms for PHY to come out of reset */
}

static void do_ephy_workaround(void)
{
	int val;

	printf("\n--- EPHY workaround (from vendor bcmgenet_ephy_workaround) ---\n");

	/* Enable shadow register access: write reg 31, set bit 2 */
	val = mdio_read(1, 31);
	if (val < 0) return;
	printf("  MII reg 31 before: 0x%04X\n", val);
	mdio_write(1, 31, (val & ~0x4) | 0x4);  /* set bit 2 */

	/* Write shadow reg 20 = 0x0F00, delay, then 0x0C00 */
	mdio_write(1, 20, 0x0F00);
	usleep(10);
	mdio_write(1, 20, 0x0C00);

	/* Write shadow reg 19 = 0x7555 */
	mdio_write(1, 19, 0x7555);

	/* Disable shadow register access: clear bit 2 of reg 31 */
	val = mdio_read(1, 31);
	if (val >= 0)
		mdio_write(1, 31, val & ~0x4);

	printf("  EPHY workaround applied\n");
}

static void do_mii_reset(void)
{
	printf("\n--- MII software reset (BMCR bit 15) ---\n");

	/* Write BMCR = 0x8000 (software reset) */
	mdio_write(1, 0, 0x8000);
	usleep(1000); /* 1ms */

	/* Write shadow reg 29 = 0x1000 */
	mdio_write(1, 29, 0x1000);
	/* Readback */
	int val = mdio_read(1, 29);
	printf("  MII reg 29 after write 0x1000: 0x%04X\n", val >= 0 ? val : 0);

	/* Then apply EPHY workaround */
	do_ephy_workaround();
}

int main(int argc, char **argv)
{
	int fd;
	int do_init = 0, do_reset = 0, do_dump = 0;

	if (argc < 2) {
		printf("Usage: %s [dump|init|reset|full]\n", argv[0]);
		printf("  dump  — read and display all registers\n");
		printf("  init  — CLKGEN power-on + EXT power-up + dump\n");
		printf("  reset — PHY hardware reset + MII reset + EPHY workaround + dump\n");
		printf("  full  — do everything (init + reset + dump)\n");
		return 1;
	}

	if (strcmp(argv[1], "dump") == 0)  { do_dump = 1; }
	else if (strcmp(argv[1], "init") == 0)  { do_init = 1; do_dump = 1; }
	else if (strcmp(argv[1], "reset") == 0) { do_reset = 1; do_dump = 1; }
	else if (strcmp(argv[1], "full") == 0)  { do_init = 1; do_reset = 1; do_dump = 1; }
	else { printf("Unknown command: %s\n", argv[1]); return 1; }

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("open /dev/mem"); return 1; }

	clkgen_map = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
			  MAP_SHARED, fd, CLKGEN_BASE);
	if (clkgen_map == MAP_FAILED) { perror("mmap CLKGEN"); close(fd); return 1; }

	genet_map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
			 MAP_SHARED, fd, GENET_BASE);
	if (genet_map == MAP_FAILED) { perror("mmap GENET"); close(fd); return 1; }

	printf("ephy_diag: BCM7231 GENET/EPHY diagnostic tool\n");

	if (do_init) {
		do_clkgen_init();
		usleep(1000);
		do_ext_power_up();
	}

	if (do_reset) {
		do_phy_reset();
		do_mii_reset();
	}

	if (do_dump) {
		dump_registers();
	}

	munmap((void *)clkgen_map, 0x1000);
	munmap((void *)genet_map, MAP_SIZE);
	close(fd);
	return 0;
}
