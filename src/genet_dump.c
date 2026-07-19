#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define CLKGEN_BASE        0x10420000u
#define CLKGEN_MAP_SIZE    0x1000u
#define GENET_BASE         0x10430000u
#define GENET_MAP_SIZE     0x10000u
#define PERIPH_INTC_BASE      0x10411000u
#define PERIPH_INTC_MAP_SIZE  0x1000u
#define PERIPH_INTC_OFF       0x0400u
#define UPG_IRQ0_BASE         0x10406000u
#define UPG_IRQ0_MAP_SIZE     0x1000u
#define UPG_IRQ0_OFF          0x0600u

#define GENET_SYS_OFF      0x0000u
#define GENET_EXT_OFF      0x0080u
#define GENET_INTRL2_0_OFF 0x0200u
#define GENET_INTRL2_1_OFF 0x0240u
#define GENET_UMAC_OFF     0x0800u
#define GENET_MDIO_OFF     0x0e14u

#define GENET_RDMA_OFF     0x3800u
#define GENET_TDMA_OFF     0x4800u
#define DMA_RING_SIZE      0x0040u
#define DMA_RINGS_SIZE     0x0440u

#define SYS_REV_CTRL       0x0000u
#define SYS_PORT_CTRL      0x0004u
#define SYS_RBUF_FLUSH     0x0008u
#define SYS_TBUF_FLUSH     0x000cu

#define EXT_PWR_MGMT       0x0000u
#define EXT_REG_04         0x0004u
#define EXT_REG_08         0x0008u
#define EXT_REG_0C         0x000cu
#define EXT_REG_10         0x0010u
#define EXT_REG_14         0x0014u
#define EXT_REG_18         0x0018u

#define UMAC_CMD           0x0008u
#define UMAC_MAC0          0x000cu
#define UMAC_MAC1          0x0010u
#define UMAC_MAX_FRAME_LEN 0x0014u
#define UMAC_MODE          0x0044u
#define UMAC_MIB_CTRL      0x0580u

#define INTRL2_CPU_STAT        0x0000u
#define INTRL2_CPU_MASK_STATUS 0x000cu

#define CLKGEN_RST         0x0200u
#define CLKGEN_CLK         0x01ecu
#define CLKGEN_PWR         0x01f0u

#define MDIO_CMD           0x0000u
#define MDIO_START_BUSY    (1u << 29)
#define MDIO_READ_FAIL     (1u << 28)
#define MDIO_RD            (2u << 26)
#define MDIO_PMD_SHIFT     21
#define MDIO_REG_SHIFT     16

#define DMA_RING_CFG           0x0000u
#define DMA_CTRL               0x0004u
#define DMA_STATUS             0x0008u
#define DMA_SCB_BURST_SIZE     0x000cu
#define DMA_RING0_TIMEOUT      0x002cu
#define DMA_ARB_CTRL           0x0030u
#define DMA_PRIORITY_0         0x0034u
#define DMA_PRIORITY_1         0x0038u
#define DMA_PRIORITY_2         0x003cu

#define TDMA_READ_PTR          0x0000u
#define RDMA_WRITE_PTR         0x0000u
#define TDMA_CONS_INDEX        0x0004u
#define RDMA_PROD_INDEX        0x0004u
#define TDMA_PROD_INDEX        0x0008u
#define RDMA_CONS_INDEX        0x0008u
#define DMA_RING_BUF_SIZE      0x000cu
#define DMA_START_ADDR         0x0010u
#define DMA_END_ADDR           0x0014u
#define DMA_MBUF_DONE_THRESH   0x0018u
#define TDMA_FLOW_PERIOD       0x001cu
#define RDMA_XON_XOFF_THRESH   0x001cu
#define TDMA_WRITE_PTR         0x0020u
#define RDMA_READ_PTR          0x0020u

struct reg_desc {
	const char *name;
	uint32_t offset;
};

static volatile uint32_t *clkgen_map;
static volatile uint32_t *genet_map;
static volatile uint32_t *periph_intc_map;
static volatile uint32_t *upg_irq0_map;
static sigjmp_buf fault_env;
static volatile sig_atomic_t safe_access_active;

static void fault_handler(int sig)
{
	if (safe_access_active)
		siglongjmp(fault_env, sig);

	_exit(128 + sig);
}

static int safe_read32(volatile uint32_t *base, uint32_t offset, uint32_t *val)
{
	safe_access_active = 1;
	if (sigsetjmp(fault_env, 1) != 0) {
		safe_access_active = 0;
		return -1;
	}

	*val = base[offset / 4];
	safe_access_active = 0;
	return 0;
}

static int safe_write32(volatile uint32_t *base, uint32_t offset, uint32_t val)
{
	volatile uint32_t sink;

	safe_access_active = 1;
	if (sigsetjmp(fault_env, 1) != 0) {
		safe_access_active = 0;
		return -1;
	}

	base[offset / 4] = val;
	sink = base[offset / 4];
	(void)sink;
	safe_access_active = 0;
	return 0;
}

static void print_reg_block(const char *title, volatile uint32_t *base,
			    const struct reg_desc *regs, size_t count)
{
	size_t i;

	printf("\n[%s]\n", title);
	for (i = 0; i < count; i++) {
		uint32_t val;
		if (safe_read32(base, regs[i].offset, &val) == 0)
			printf("  %-18s @ +0x%04x = 0x%08x\n",
			       regs[i].name, regs[i].offset, val);
		else
			printf("  %-18s @ +0x%04x = <fault>\n",
			       regs[i].name, regs[i].offset);
	}
}

static void print_dma_ring(const char *title, uint32_t ring_base,
			   const struct reg_desc *regs, size_t count)
{
	size_t i;

	printf("\n[%s @ +0x%04x]\n", title, ring_base);
	for (i = 0; i < count; i++) {
		uint32_t val;
		uint32_t off = ring_base + regs[i].offset;

		if (safe_read32(genet_map, off, &val) == 0)
			printf("  %-18s @ +0x%04x = 0x%08x\n",
			       regs[i].name, off, val);
		else
			printf("  %-18s @ +0x%04x = <fault>\n",
			       regs[i].name, off);
	}
}

static int mdio_read(int phy, int reg, uint16_t *out)
{
	uint32_t cmd;
	int timeout = 1000;

	cmd = MDIO_START_BUSY | MDIO_RD |
	      ((phy & 0x1f) << MDIO_PMD_SHIFT) |
	      ((reg & 0x1f) << MDIO_REG_SHIFT);

	if (safe_write32(genet_map, GENET_MDIO_OFF + MDIO_CMD, cmd) != 0)
		return -1;

	do {
		usleep(10);
		if (safe_read32(genet_map, GENET_MDIO_OFF + MDIO_CMD, &cmd) != 0)
			return -1;
	} while ((cmd & MDIO_START_BUSY) && --timeout);

	if (timeout == 0 || (cmd & MDIO_READ_FAIL))
		return -1;

	*out = cmd & 0xffffu;
	return 0;
}

static void dump_phy_regs(int phy)
{
	static const char * const names[] = {
		"BMCR", "BMSR", "PHYID1", "PHYID2",
		"ANAR", "ANLPAR", "ANER", "ANNPTR"
	};
	int reg;

	printf("\n[PHY addr %d]\n", phy);
	for (reg = 0; reg < 8; reg++) {
		uint16_t val;
		if (mdio_read(phy, reg, &val) == 0)
			printf("  reg%-2d %-7s = 0x%04x\n", reg, names[reg], val);
		else
			printf("  reg%-2d %-7s = <fault>\n", reg, names[reg]);
	}
}

static void scan_mdio_bus(void)
{
	int addr;

	printf("\n[MDIO scan]\n");
	for (addr = 0; addr < 32; addr++) {
		uint16_t val;
		if (mdio_read(addr, 1, &val) == 0 && val != 0x0000 && val != 0xffff)
			printf("  phy@%d bmsr=0x%04x\n", addr, val);
	}
}

static void print_text_file_line(const char *label, const char *path)
{
	FILE *fp;
	char buf[256];

	fp = fopen(path, "r");
	if (!fp) {
		printf("  %-10s %s\n", label, "<missing>");
		return;
	}

	if (!fgets(buf, sizeof(buf), fp))
		buf[0] = '\0';
	fclose(fp);

	buf[strcspn(buf, "\r\n")] = '\0';
	printf("  %-10s %s\n", label, buf[0] ? buf : "<empty>");
}

static void print_proc_net_dev(void)
{
	FILE *fp;
	char line[512];

	fp = fopen("/proc/net/dev", "r");
	if (!fp) {
		printf("\n[/proc/net/dev]\n  <missing>\n");
		return;
	}

	printf("\n[/proc/net/dev]\n");
	while (fgets(line, sizeof(line), fp)) {
		char *p = strstr(line, "eth0:");
		if (p) {
			unsigned long long rx_bytes, rx_packets, rx_errs, rx_drop;
			unsigned long long tx_bytes, tx_packets, tx_errs, tx_drop, tx_colls, tx_carrier;

			if (sscanf(p,
				   "eth0: %llu %llu %llu %llu %*llu %*llu %*llu %*llu %llu %llu %llu %llu %*llu %llu %llu",
				   &rx_bytes, &rx_packets, &rx_errs, &rx_drop,
				   &tx_bytes, &tx_packets, &tx_errs, &tx_drop, &tx_colls, &tx_carrier) == 10) {
				printf("  rx bytes=%llu packets=%llu errs=%llu drop=%llu\n",
				       rx_bytes, rx_packets, rx_errs, rx_drop);
				printf("  tx bytes=%llu packets=%llu errs=%llu drop=%llu colls=%llu carrier=%llu\n",
				       tx_bytes, tx_packets, tx_errs, tx_drop, tx_colls, tx_carrier);
			} else {
				printf("  raw %s", p);
			}
			fclose(fp);
			return;
		}
	}

	fclose(fp);
	printf("  eth0 not present\n");
}

static void print_interrupt_lines(void)
{
	FILE *fp;
	char line[512];
	int found = 0;

	fp = fopen("/proc/interrupts", "r");
	if (!fp) {
		printf("\n[/proc/interrupts]\n  <missing>\n");
		return;
	}

	printf("\n[/proc/interrupts]\n");
	while (fgets(line, sizeof(line), fp)) {
		if (strstr(line, "genet") || strstr(line, "eth0") || strstr(line, "brcm")) {
			printf("  %s", line);
			found = 1;
		}
	}
	fclose(fp);

	if (!found)
		printf("  <no genet/eth0-labelled lines>\n");
}

static void print_linux_net_state(void)
{
	printf("\n[Linux net state]\n");
	print_text_file_line("carrier", "/sys/class/net/eth0/carrier");
	print_text_file_line("operstate", "/sys/class/net/eth0/operstate");
	print_text_file_line("speed", "/sys/class/net/eth0/speed");
	print_text_file_line("duplex", "/sys/class/net/eth0/duplex");
	print_proc_net_dev();
	print_interrupt_lines();
}

static void print_dma_state(void)
{
	static const struct reg_desc intrl2_0_regs[] = {
		{ "CPU_STAT", GENET_INTRL2_0_OFF + INTRL2_CPU_STAT },
		{ "MASK_STATUS", GENET_INTRL2_0_OFF + INTRL2_CPU_MASK_STATUS },
	};
	static const struct reg_desc intrl2_1_regs[] = {
		{ "CPU_STAT", GENET_INTRL2_1_OFF + INTRL2_CPU_STAT },
		{ "MASK_STATUS", GENET_INTRL2_1_OFF + INTRL2_CPU_MASK_STATUS },
	};
	static const struct reg_desc tdma_ring_regs[] = {
		{ "TDMA_READ_PTR", TDMA_READ_PTR },
		{ "TDMA_CONS_INDEX", TDMA_CONS_INDEX },
		{ "TDMA_PROD_INDEX", TDMA_PROD_INDEX },
		{ "DMA_RING_BUF_SIZE", DMA_RING_BUF_SIZE },
		{ "DMA_START_ADDR", DMA_START_ADDR },
		{ "DMA_END_ADDR", DMA_END_ADDR },
		{ "DMA_DONE_THRESH", DMA_MBUF_DONE_THRESH },
		{ "TDMA_FLOW_PERIOD", TDMA_FLOW_PERIOD },
		{ "TDMA_WRITE_PTR", TDMA_WRITE_PTR },
	};
	static const struct reg_desc rdma_ring_regs[] = {
		{ "RDMA_WRITE_PTR", RDMA_WRITE_PTR },
		{ "RDMA_PROD_INDEX", RDMA_PROD_INDEX },
		{ "RDMA_CONS_INDEX", RDMA_CONS_INDEX },
		{ "DMA_RING_BUF_SIZE", DMA_RING_BUF_SIZE },
		{ "DMA_START_ADDR", DMA_START_ADDR },
		{ "DMA_END_ADDR", DMA_END_ADDR },
		{ "DMA_DONE_THRESH", DMA_MBUF_DONE_THRESH },
		{ "RDMA_XON_XOFF", RDMA_XON_XOFF_THRESH },
		{ "RDMA_READ_PTR", RDMA_READ_PTR },
	};

	print_reg_block("INTRL2_0", genet_map, intrl2_0_regs,
			sizeof(intrl2_0_regs) / sizeof(intrl2_0_regs[0]));
	print_reg_block("INTRL2_1", genet_map, intrl2_1_regs,
			sizeof(intrl2_1_regs) / sizeof(intrl2_1_regs[0]));
	print_reg_block("TDMA GLOBAL", genet_map,
			(const struct reg_desc[]) {
				{ "DMA_RING_CFG", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_RING_CFG },
				{ "DMA_CTRL", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_CTRL },
				{ "DMA_STATUS", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_STATUS },
				{ "DMA_SCB_BURST", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_SCB_BURST_SIZE },
				{ "DMA_RING0_TO", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_RING0_TIMEOUT },
				{ "DMA_ARB_CTRL", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_ARB_CTRL },
				{ "DMA_PRIO_0", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_0 },
				{ "DMA_PRIO_1", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_1 },
				{ "DMA_PRIO_2", GENET_TDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_2 },
			}, 9);
	print_reg_block("RDMA GLOBAL", genet_map,
			(const struct reg_desc[]) {
				{ "DMA_RING_CFG", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_RING_CFG },
				{ "DMA_CTRL", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_CTRL },
				{ "DMA_STATUS", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_STATUS },
				{ "DMA_SCB_BURST", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_SCB_BURST_SIZE },
				{ "DMA_RING0_TO", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_RING0_TIMEOUT },
				{ "DMA_ARB_CTRL", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_ARB_CTRL },
				{ "DMA_PRIO_0", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_0 },
				{ "DMA_PRIO_1", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_1 },
				{ "DMA_PRIO_2", GENET_RDMA_OFF + DMA_RINGS_SIZE + DMA_PRIORITY_2 },
			}, 9);

	print_dma_ring("TDMA ring0", GENET_TDMA_OFF + (DMA_RING_SIZE * 0),
		       tdma_ring_regs, sizeof(tdma_ring_regs) / sizeof(tdma_ring_regs[0]));
	print_dma_ring("TDMA ring3", GENET_TDMA_OFF + (DMA_RING_SIZE * 3),
		       tdma_ring_regs, sizeof(tdma_ring_regs) / sizeof(tdma_ring_regs[0]));
	print_dma_ring("TDMA ring16", GENET_TDMA_OFF + (DMA_RING_SIZE * 16),
		       tdma_ring_regs, sizeof(tdma_ring_regs) / sizeof(tdma_ring_regs[0]));
	print_dma_ring("RDMA ring0", GENET_RDMA_OFF + (DMA_RING_SIZE * 0),
		       rdma_ring_regs, sizeof(rdma_ring_regs) / sizeof(rdma_ring_regs[0]));
	print_dma_ring("RDMA ring16", GENET_RDMA_OFF + (DMA_RING_SIZE * 16),
		       rdma_ring_regs, sizeof(rdma_ring_regs) / sizeof(rdma_ring_regs[0]));
}

static void print_irq_ctrl_state(void)
{
	static const struct reg_desc periph_regs[] = {
		{ "CPU0_STATUS", PERIPH_INTC_OFF + 0x0000u },
		{ "CPU0_SET", PERIPH_INTC_OFF + 0x0004u },
		{ "CPU0_CLEAR", PERIPH_INTC_OFF + 0x0008u },
		{ "CPU0_MASK_STATUS", PERIPH_INTC_OFF + 0x000cu },
		{ "CPU0_MASK_SET", PERIPH_INTC_OFF + 0x0010u },
		{ "CPU0_MASK_CLEAR", PERIPH_INTC_OFF + 0x0014u },
		{ "CPU1_STATUS", PERIPH_INTC_OFF + 0x0200u },
		{ "CPU1_SET", PERIPH_INTC_OFF + 0x0204u },
		{ "CPU1_CLEAR", PERIPH_INTC_OFF + 0x0208u },
		{ "CPU1_MASK_STATUS", PERIPH_INTC_OFF + 0x020cu },
		{ "CPU1_MASK_SET", PERIPH_INTC_OFF + 0x0210u },
		{ "CPU1_MASK_CLEAR", PERIPH_INTC_OFF + 0x0214u },
	};
	static const struct reg_desc upg_regs[] = {
		{ "STATUS", UPG_IRQ0_OFF + 0x0000u },
		{ "MASK_STATUS", UPG_IRQ0_OFF + 0x0004u },
		{ "MASK_SET", UPG_IRQ0_OFF + 0x0008u },
		{ "MASK_CLEAR", UPG_IRQ0_OFF + 0x000cu },
	};

	print_reg_block("PERIPH_INTC", periph_intc_map, periph_regs,
			sizeof(periph_regs) / sizeof(periph_regs[0]));
	print_reg_block("UPG_IRQ0_INTC", upg_irq0_map, upg_regs,
			sizeof(upg_regs) / sizeof(upg_regs[0]));
}

static void print_timestamp(const char *tag)
{
	time_t now;
	char buf[64];
	struct tm *tm;

	now = time(NULL);
	tm = localtime(&now);
	if (!tm || strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", tm) == 0)
		strcpy(buf, "unknown-time");

	printf("\n=== genet snapshot: %s @ %s ===\n", tag, buf);
}

static void take_snapshot(const char *tag)
{
	static const struct reg_desc clkgen_regs[] = {
		{ "CLKGEN_RST", CLKGEN_RST },
		{ "CLKGEN_CLK", CLKGEN_CLK },
		{ "CLKGEN_PWR", CLKGEN_PWR },
	};
	static const struct reg_desc sys_regs[] = {
		{ "SYS_REV_CTRL", GENET_SYS_OFF + SYS_REV_CTRL },
		{ "SYS_PORT_CTRL", GENET_SYS_OFF + SYS_PORT_CTRL },
		{ "SYS_RBUF_FLUSH", GENET_SYS_OFF + SYS_RBUF_FLUSH },
		{ "SYS_TBUF_FLUSH", GENET_SYS_OFF + SYS_TBUF_FLUSH },
	};
	static const struct reg_desc ext_regs[] = {
		{ "EXT_PWR_MGMT", GENET_EXT_OFF + EXT_PWR_MGMT },
		{ "EXT_04", GENET_EXT_OFF + EXT_REG_04 },
		{ "EXT_08", GENET_EXT_OFF + EXT_REG_08 },
		{ "EXT_0C", GENET_EXT_OFF + EXT_REG_0C },
		{ "EXT_10", GENET_EXT_OFF + EXT_REG_10 },
		{ "EXT_14", GENET_EXT_OFF + EXT_REG_14 },
		{ "EXT_18", GENET_EXT_OFF + EXT_REG_18 },
	};
	static const struct reg_desc umac_regs[] = {
		{ "UMAC_CMD", GENET_UMAC_OFF + UMAC_CMD },
		{ "UMAC_MAC0", GENET_UMAC_OFF + UMAC_MAC0 },
		{ "UMAC_MAC1", GENET_UMAC_OFF + UMAC_MAC1 },
		{ "UMAC_MAX_FRAME", GENET_UMAC_OFF + UMAC_MAX_FRAME_LEN },
		{ "UMAC_MODE", GENET_UMAC_OFF + UMAC_MODE },
		{ "UMAC_MIB_CTRL", GENET_UMAC_OFF + UMAC_MIB_CTRL },
	};
	static const struct reg_desc mdio_regs[] = {
		{ "MDIO_CMD", GENET_MDIO_OFF + MDIO_CMD },
	};

	print_timestamp(tag);
	print_reg_block("CLKGEN", clkgen_map, clkgen_regs, sizeof(clkgen_regs) / sizeof(clkgen_regs[0]));
	print_reg_block("GENET SYS", genet_map, sys_regs, sizeof(sys_regs) / sizeof(sys_regs[0]));
	print_reg_block("GENET EXT", genet_map, ext_regs, sizeof(ext_regs) / sizeof(ext_regs[0]));
	print_reg_block("GENET UMAC", genet_map, umac_regs, sizeof(umac_regs) / sizeof(umac_regs[0]));
	print_reg_block("GENET MDIO", genet_map, mdio_regs, sizeof(mdio_regs) / sizeof(mdio_regs[0]));
	print_dma_state();
	print_irq_ctrl_state();
	dump_phy_regs(1);
	dump_phy_regs(0);
	scan_mdio_bus();
	print_linux_net_state();
	printf("\n");
}

static int install_fault_handlers(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = fault_handler;
	sa.sa_flags = SA_RESTART;
	if (sigaction(SIGBUS, &sa, NULL) != 0)
		return -1;
	if (sigaction(SIGSEGV, &sa, NULL) != 0)
		return -1;
	return 0;
}

static int map_blocks(void)
{
	int fd;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return -1;
	}

	clkgen_map = mmap(NULL, CLKGEN_MAP_SIZE, PROT_READ | PROT_WRITE,
			  MAP_SHARED, fd, CLKGEN_BASE);
	if (clkgen_map == MAP_FAILED) {
		perror("mmap CLKGEN");
		close(fd);
		return -1;
	}

	genet_map = mmap(NULL, GENET_MAP_SIZE, PROT_READ | PROT_WRITE,
			 MAP_SHARED, fd, GENET_BASE);
	if (genet_map == MAP_FAILED) {
		perror("mmap GENET");
		munmap((void *)clkgen_map, CLKGEN_MAP_SIZE);
		close(fd);
		return -1;
	}

	periph_intc_map = mmap(NULL, PERIPH_INTC_MAP_SIZE, PROT_READ | PROT_WRITE,
			      MAP_SHARED, fd, PERIPH_INTC_BASE);
	if (periph_intc_map == MAP_FAILED) {
		perror("mmap PERIPH_INTC");
		munmap((void *)genet_map, GENET_MAP_SIZE);
		munmap((void *)clkgen_map, CLKGEN_MAP_SIZE);
		close(fd);
		return -1;
	}

	upg_irq0_map = mmap(NULL, UPG_IRQ0_MAP_SIZE, PROT_READ | PROT_WRITE,
			 MAP_SHARED, fd, UPG_IRQ0_BASE);
	if (upg_irq0_map == MAP_FAILED) {
		perror("mmap UPG_IRQ0");
		munmap((void *)periph_intc_map, PERIPH_INTC_MAP_SIZE);
		munmap((void *)genet_map, GENET_MAP_SIZE);
		munmap((void *)clkgen_map, CLKGEN_MAP_SIZE);
		close(fd);
		return -1;
	}

	close(fd);
	return 0;
}

static void usage(const char *prog)
{
	printf("Usage:\n");
	printf("  %s snapshot [tag]\n", prog);
	printf("  %s watch [interval_sec] [count]\n", prog);
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "snapshot";
	const char *tag = argc > 2 ? argv[2] : "manual";

	if (install_fault_handlers() != 0) {
		perror("sigaction");
		return 1;
	}

	if (map_blocks() != 0)
		return 1;

	if (strcmp(cmd, "snapshot") == 0) {
		take_snapshot(tag);
	} else if (strcmp(cmd, "watch") == 0) {
		unsigned interval = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 1;
		unsigned count = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 0) : 10;
		unsigned i;

		if (interval == 0)
			interval = 1;
		if (count == 0)
			count = 1;

		for (i = 0; i < count; i++) {
			char watch_tag[32];
			snprintf(watch_tag, sizeof(watch_tag), "watch-%u", i + 1);
			take_snapshot(watch_tag);
			if (i + 1 != count)
				sleep(interval);
		}
	} else {
		usage(argv[0]);
		munmap((void *)upg_irq0_map, UPG_IRQ0_MAP_SIZE);
		munmap((void *)periph_intc_map, PERIPH_INTC_MAP_SIZE);
		munmap((void *)genet_map, GENET_MAP_SIZE);
		munmap((void *)clkgen_map, CLKGEN_MAP_SIZE);
		return 1;
	}

	munmap((void *)upg_irq0_map, UPG_IRQ0_MAP_SIZE);
	munmap((void *)periph_intc_map, PERIPH_INTC_MAP_SIZE);
	munmap((void *)genet_map, GENET_MAP_SIZE);
	munmap((void *)clkgen_map, CLKGEN_MAP_SIZE);
	return 0;
}
