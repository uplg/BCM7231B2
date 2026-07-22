// SPDX-License-Identifier: GPL-2.0
/*
 * DVB adapter driver for the AirTies AIR 7310T: 2x MaxLinear MxL101SF
 * DVB-T frontends on the BSC_B i2c bus feeding the BCM7231 XPT transport
 * processor, whose MSG record engine DMA-writes hardware-PID-filtered TS
 * into reserved DRAM rings (see /memreserve/ in bcm7231-airties-7310t.dts).
 *
 * Everything here is reverse-engineered — none of this hardware has
 * mainline support:
 *  - MxL101SF register sequences: dumped from the stock libwydvb.so
 *    (OverwriteDefault/TunerDemodMode/spur tables, xtal cfg from
 *    DevConfigXtalSettings disasm, MPEG-out cfg from DevConfigMpegOut
 *    disasm).  The serial TS clock selector (reg 0x17 bits[4:2]) MUST be
 *    0 (~27 MHz): the chip default (4) caps the line at ~9 Mbps and the
 *    demod silently drops whole packets.  The parallel TS bus is not
 *    wired on this board.  Never write reg 0x1B (pin-mux): it wedges the
 *    master chip's register interface.
 *  - XPT programming: reversed from the vendor's unstripped nexus.ko
 *    (BXPT_*), cross-checked against BCM7340 RDB headers, validated live
 *    (userspace prototype: src/xpt_cap.c).  Key trap: PID2BUF (0xa1c000)
 *    is a 128-bit per-channel buffer BITMASK (4 words/channel), not a
 *    buffer number.
 *
 * Per adapter: input band N -> parser N (PID-match mode) -> PID channels
 * (64/adapter, hw PID filter) -> MSG buffer N -> DRAM ring -> kthread ->
 * dvb_dmx_swfilter_packets().  The all-pass path (pid 0x2000) works but
 * drops ~6% above ~23 Mbps (MSG engine per-packet ceiling) — per-PID
 * filtering is loss-free, which is what the demux API does naturally.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/kthread.h>
#include <linux/mutex.h>
#include <linux/slab.h>

#include <media/dvbdev.h>
#include <media/dvb_demux.h>
#include <media/dmxdev.h>
#include <media/dvb_frontend.h>

DVB_DEFINE_MOD_OPT_ADAPTER_NR(adapter_nr);

#define DRVNAME "bcm7231-dvb"

/* ------------------------- board configuration -------------------------- */

#define AIR_NUM_ADAPTERS   2
#define AIR_I2C_BUS        1            /* BSC_B */
#define AIR_RING_SIZE      0x80000u     /* 512K, size code 9 */
#define AIR_STAGE_SIZE     0x20000u     /* 128K RS/XC staging rings */
#define AIR_CHANS_PER_ADAP 64u          /* hw PID channels per adapter */
/* In parser all-pass mode every packet is tagged with the parser's
 * COMPANION channel = the band number itself — so channels 0..3 belong
 * to the parsers and normal slots must start above them.  (Learned live:
 * a stray all-pass on parser1 tags 25 Mbps as "chan 1" and floods
 * whatever buffer chan 1 routes to.) */
#define AIR_CHAN_BASE      8u

static const struct {
	u8  i2c_addr;
	u32 ring_phys;                  /* in the low /memreserve/ region  */
} air_board[AIR_NUM_ADAPTERS] = {
	{ 0x60, 0x00d00000 },           /* master, IB0/parser0/buf0        */
	{ 0x63, 0x00c00000 },           /* slave,  IB1/parser1/buf1        */
};

/* ----------------------------- XPT registers ----------------------------- */

#define XPT_MAP_BASE            0x10a04000u
#define XPT_MAP_LEN             0x00031000u

#define XPT_FE_IB_CTRL(n)       (0x10a04100u + 8u * (n))
#define XPT_FE_IB_SYNC_CNT(n)   (0x10a04104u + 8u * (n))
#define XPT_FE_PARSER_CTRL1(n)  (0x10a04180u + 0x10u * (n))
#define XPT_PID_TABLE(c)        (0x10a04800u + 4u * (c))
#define XPT_SPID(c)             (0x10a05000u + 4u * (c))

#define XPT_MSG_BUF_RESET       0x10a1800cu
#define XPT_MSG_BUF_CTRL1(i)    (0x10a18200u + 4u * (i))
#define XPT_MSG_BUF_CTRL2(i)    (0x10a18400u + 4u * (i))
#define XPT_MSG_DMA_BP(i)       (0x10a18600u + 4u * (i))
#define XPT_MSG_DMA_RP(i)       (0x10a18800u + 4u * (i))
#define XPT_MSG_DMA_VP(i)       (0x10a18a00u + 4u * (i))
#define XPT_MSG_GEN_FILT_EN(i)  (0x10a19000u + 4u * (i))
#define XPT_MSG_PID2BUF_W(c, w) (0x10a1c000u + 0x10u * (c) + 4u * (w))

#define RS_G1_PTR(b)            (0x10a15000u + 0x18u * (b))
#define RS_G3_PTR(b)            (0x10a15600u + 0x18u * (b))
#define RS_G1_BO(b)             (0x10a15900u + 4u * (b))
#define RS_G3_BO(b)             (0x10a15a00u + 4u * (b))
#define RS_EN_G1                0x10a15b08u
#define RS_EN_G2                0x10a15b0cu
#define RS_EN_G3                0x10a15b1cu

#define XC_GLOBAL_CTRL          0x10a17840u
#define XC_MSG_IBP_PTR(b)       (0x10a16600u + 0x18u * (b))
#define XC_MSG_IBP_BO(b)        (0x10a179b0u + 4u * (b))
#define XC_MSG_IBP_EN           0x10a17814u
#define XC_RAVE_IBP_EN          0x10a17804u
#define XC_RAVE_PBP_EN          0x10a17800u
#define XC_MSG_PBP_EN           0x10a17810u
#define XC_RMX0_IBP_EN          0x10a17824u
#define XC_RMX0_PBP_EN          0x10a17820u
#define XC_RMX1_IBP_EN          0x10a17834u
#define XC_RMX1_PBP_EN          0x10a17830u

#define XPT_PACE0_CTRL          0x10a04680u
#define XPT_PACE0_VAL           0x10a0468cu
#define XPT_PACE1_CTRL          0x10a046a0u
#define XPT_PACE1_VAL           0x10a046acu
#define XPT_PACE_MAGIC          0x829eecdeu

#define RS_BO_27MBPS            0x1780u
#define RS_NUM_IBP_BANDS        16u

#define IB_SYNC_DETECT_EN       BIT(6)
#define PARSER_ENABLE           BIT(0)
#define PARSER_ALL_PASS         BIT(1)
#define PARSER_CC_IGNORE        BIT(3)
#define PARSER_ACCEPT_NULL      BIT(4)
#define PARSER_WR_FIELDS        0x000ffffbu
#define IB_WR_FIELDS            0x00ff07ffu

#define PID_KEEP_MASK           0xf7c0f000u
#define PID_KEEP_MASK_PIDMATCH  0xf7c0e000u
#define PID_ENABLE              BIT(14)
#define SPID_DEST_RECORD        0x80000000u

/* SUN_TOP_CTRL sw-init bit 18 = whole-XPT reset */
#define SUN_TOP_SW_INIT_SET     0x10404318u
#define SUN_TOP_SW_INIT_CLR     0x1040431cu

static void __iomem *xpt_base;          /* XPT_MAP_BASE..+LEN */

static u32 xpt_rd(u32 phys)
{
	return readl(xpt_base + (phys - XPT_MAP_BASE));
}

static void xpt_wr(u32 phys, u32 v)
{
	writel(v, xpt_base + (phys - XPT_MAP_BASE));
}

/* ------------------------------ MxL101SF -------------------------------- */

struct mxl_reg { u8 reg, mask, val; };

/* Stock tables, dumped byte-exact from libwydvb.so .data. */
static const struct mxl_reg mxl_overwrite_default[] = {
	{0x42, 0xff, 0x33}, {0x71, 0xff, 0x66}, {0x72, 0xff, 0x01},
	{0x73, 0xff, 0x00}, {0x74, 0xff, 0xc2}, {0x71, 0xff, 0xe6},
	{0x6f, 0xff, 0xb7}, {0x98, 0xff, 0x40}, {0x99, 0xff, 0x18},
	{0xe0, 0xff, 0x00}, {0xe1, 0xff, 0x10}, {0xe2, 0xff, 0x91},
	{0xe4, 0xff, 0x3f}, {0xb1, 0xff, 0x00}, {0xb2, 0xff, 0x09},
	{0xb3, 0xff, 0x1f}, {0xb4, 0xff, 0x1f},
	{0x00, 0xff, 0x01},
	{0xe2, 0xff, 0x02}, {0x81, 0xff, 0x04}, {0xf4, 0xff, 0x07},
	{0xb8, 0xff, 0x42}, {0xbf, 0xff, 0x1c}, {0x82, 0xff, 0xc6},
	{0x87, 0xff, 0x01}, {0x81, 0x1c, 0x04}, {0x83, 0xff, 0xcf},
	{0x85, 0xff, 0x02},
	{0x00, 0xff, 0x02},
	{0x27, 0xff, 0x20},
	{0x00, 0xff, 0x00},
	{0, 0, 0}
};

static const struct mxl_reg mxl_tuner_demod_mode[] = {
	{0x03, 0xff, 0x01}, {0x7d, 0x40, 0x00}, {0x3b, 0x20, 0x20},
	{0, 0, 0}
};

/* NOT in the vendor tables — reversed from DevConfigXtalSettings. */
static const struct mxl_reg mxl_xtal_settings[] = {
	{0x07, 0xff, 0x04}, {0x32, 0xff, 0xa4}, {0x31, 0xff, 0x08},
	{0x66, 0xff, 0x14}, {0x08, 0xff, 0x0a},
	{0, 0, 0}
};

static const struct mxl_reg mxl_spur_6mhz[] = {
	{0x00, 0xff, 0x01}, {0x84, 0xff, 0xa1}, {0x86, 0xff, 0x9b},
	{0x00, 0xff, 0x02}, {0xdd, 0xff, 0x14}, {0xde, 0xff, 0x0d},
	{0x00, 0xff, 0x00}, {0, 0, 0}
};
static const struct mxl_reg mxl_spur_7mhz[] = {
	{0x00, 0xff, 0x01}, {0x84, 0xff, 0x96}, {0x86, 0xff, 0xa0},
	{0x00, 0xff, 0x02}, {0xdd, 0xff, 0x42}, {0xde, 0xff, 0x0f},
	{0x00, 0xff, 0x00}, {0, 0, 0}
};
static const struct mxl_reg mxl_spur_8mhz[] = {
	{0x00, 0xff, 0x01}, {0x84, 0xff, 0x8c}, {0x86, 0xff, 0x6c},
	{0x00, 0xff, 0x02}, {0xdd, 0xff, 0x70}, {0xde, 0xff, 0x11},
	{0x00, 0xff, 0x00}, {0, 0, 0}
};

/* --------------------------- adapter context ----------------------------- */

struct air_adapter {
	int idx;                        /* 0 = master, 1 = slave           */
	u32 buf;                        /* MSG buffer index (4 + idx: bufs
					 * 0/1 were zombified by an old
					 * driver's reset-hammering and a
					 * context wedge survives BUF_RESET
					 * and warm reboots)               */
	u8  i2c_addr;
	struct i2c_adapter *i2c;

	struct dvb_adapter  dvb;
	struct dvb_frontend fe;
	struct dvb_demux    demux;
	struct dmxdev       dmxdev;
	struct dmx_frontend hw_fe, mem_fe;

	u32 ring_phys, ring_size;
	void __iomem *ring;             /* uncached: XPT DMA-writes it     */
	struct task_struct *thread;
	u8 *bounce;

	struct mutex lock;              /* hw pid channel table            */
	u16 chan_pid[AIR_CHANS_PER_ADAP];
	u8  chan_ref[AIR_CHANS_PER_ADAP];
	int nfeeds;                     /* active feeds (ring armed if >0) */
};

static struct air_adapter *air_adapters[AIR_NUM_ADAPTERS];

/* --------------------------- MxL i2c helpers ----------------------------- */

static int mxl_wr(struct air_adapter *a, u8 reg, u8 val)
{
	u8 buf[2] = { reg, val };
	struct i2c_msg msg = {
		.addr = a->i2c_addr, .flags = 0, .len = 2, .buf = buf
	};

	return i2c_transfer(a->i2c, &msg, 1) == 1 ? 0 : -EIO;
}

static int mxl_rd(struct air_adapter *a, u8 reg, u8 *val)
{
	u8 wbuf[2] = { 0xfb, reg };
	struct i2c_msg msgs[2] = {
		{ .addr = a->i2c_addr, .flags = 0,        .len = 2, .buf = wbuf },
		{ .addr = a->i2c_addr, .flags = I2C_M_RD, .len = 1, .buf = val  },
	};

	return i2c_transfer(a->i2c, msgs, 2) == 2 ? 0 : -EIO;
}

static int mxl_program(struct air_adapter *a, const struct mxl_reg *t)
{
	int ret;

	for (; t->mask; t++) {
		u8 v = t->val;

		if (t->mask != 0xff) {
			u8 cur;

			ret = mxl_rd(a, t->reg, &cur);
			if (ret)
				return ret;
			v = (cur & ~t->mask) | (t->val & t->mask);
		}
		ret = mxl_wr(a, t->reg, v);
		if (ret)
			return ret;
	}
	return 0;
}

/* Full chip init: stock MxL101SF_Init order, then MPEG serial TS out at
 * clock selector 0.  Master also drives RF loop-through + xtal clock out
 * for the slave. */
static int mxl_chip_init(struct air_adapter *a)
{
	int master = (a->idx == 0);
	u8 id = 0;
	int ret;

	ret = mxl_rd(a, 0xfc, &id);
	if (ret || id != 0x61) {
		pr_err(DRVNAME ": adapter %d: MxL101SF not found at 0x%02x (id 0x%02x)\n",
		       a->idx, a->i2c_addr, id);
		return ret ? ret : -ENODEV;
	}

	ret = mxl_wr(a, 0xff, 0x00) ?:          /* page 0                  */
	      mxl_wr(a, 0x02, 0x01);            /* MxL_PhySoftReset        */
	if (ret)
		return ret;
	msleep(50);
	ret = mxl_program(a, mxl_overwrite_default) ?:
	      mxl_wr(a, 0x09, master ? 0x01 : 0x00) ?:  /* RF loop-through */
	      mxl_program(a, mxl_xtal_settings);
	if (ret)
		return ret;
	if (master) {                           /* xtal clock to the slave */
		static const struct mxl_reg clkout[] = {
			{0x06, 0x20, 0x20}, {0, 0, 0}
		};
		ret = mxl_program(a, clkout);
		if (ret)
			return ret;
	}
	ret = mxl_wr(a, 0x01, 0x00) ?:          /* top master off          */
	      mxl_program(a, mxl_tuner_demod_mode) ?:
	      mxl_wr(a, 0x01, 0x01);            /* top master on           */
	if (ret)
		return ret;
	msleep(100);

	/* MPEG TS out: serial, MSB first, clock sel 0 (bits[4:2] of 0x17;
	 * chip default 4 is ~9 Mbps = 2/3 of every mux silently dropped). */
	{
		static const struct mxl_reg tson[] = {
			{0x17, 0x20, 0x00},     /* clock phase normal      */
			{0x17, 0xc0, 0xc0},     /* vendor TS-on bits       */
			{0x17, 0x1c, 0x00},     /* clock selector 0        */
			{0x18, 0x03, 0x02},     /* serial                  */
			{0x19, 0x80, 0x80},     /* MSB first               */
			{0x18, 0x04, 0x00},     /* sync pol normal         */
			{0x18, 0x08, 0x00},     /* valid pol normal        */
			{0, 0, 0}
		};
		ret = mxl_program(a, tson);
	}
	return ret;
}

/* ---------------------------- frontend ops ------------------------------- */

static int mxl_fe_init(struct dvb_frontend *fe)
{
	return 0;       /* chips are brought up once at probe */
}

static int mxl_fe_set_frontend(struct dvb_frontend *fe)
{
	struct air_adapter *a = fe->demodulator_priv;
	struct dtv_frontend_properties *p = &fe->dtv_property_cache;
	u32 bw = p->bandwidth_hz ? p->bandwidth_hz / 1000000 : 8;
	u32 f64 = (p->frequency / 1000000) * 64;
	u8 filt_bw = (bw == 6) ? 21 : (bw == 7) ? 42 : 63;
	int ret;

	ret = mxl_wr(a, 0x1c, 0x00);            /* stop tune               */
	if (ret)
		return ret;
	ret = mxl_program(a, bw == 6 ? mxl_spur_6mhz :
			     bw == 7 ? mxl_spur_7mhz : mxl_spur_8mhz);
	if (ret)
		return ret;
	ret = mxl_wr(a, 0x1d, filt_bw) ?:       /* MxL_PhyTuneRF           */
	      mxl_wr(a, 0x1e, f64 & 0xff) ?:
	      mxl_wr(a, 0x1f, (f64 >> 8) & 0xff) ?:
	      mxl_wr(a, 0x1c, 0x01);            /* start tune              */
	if (ret)
		return ret;
	msleep(100);
	return mxl_wr(a, 0x0e, 0xff);           /* MxL_IrqClear            */
}

static int mxl_fe_read_status(struct dvb_frontend *fe, enum fe_status *status)
{
	struct air_adapter *a = fe->demodulator_priv;
	u8 r28 = 0, r2a = 0, r24 = 0;

	if (mxl_rd(a, 0x28, &r28) || mxl_rd(a, 0x2a, &r2a) ||
	    mxl_rd(a, 0x24, &r24))
		return -EIO;

	*status = 0;
	if (r2a & 0x40)                         /* TPS lock                */
		*status |= FE_HAS_SIGNAL | FE_HAS_CARRIER;
	if (r28 & 0x08)                         /* RS lock                 */
		*status |= FE_HAS_VITERBI;
	if (r28 & 0x10)                         /* MPEG sync               */
		*status |= FE_HAS_SYNC;
	if ((r24 & 0x10) && (*status & FE_HAS_SYNC))
		*status |= FE_HAS_LOCK;
	return 0;
}

static int mxl_fe_read_snr(struct dvb_frontend *fe, u16 *snr)
{
	struct air_adapter *a = fe->demodulator_priv;
	u8 lo = 0, hi = 0;

	if (mxl_rd(a, 0x27, &lo) || mxl_rd(a, 0x28, &hi))
		return -EIO;
	*snr = lo | ((hi & 0x03) << 8);         /* 0.1 dB units            */
	return 0;
}

static int mxl_fe_read_signal_strength(struct dvb_frontend *fe, u16 *strength)
{
	struct air_adapter *a = fe->demodulator_priv;
	u8 lo = 0, hi = 0;
	int ret;

	ret = mxl_wr(a, 0x00, 0x02);            /* page 2                  */
	if (ret)
		return ret;
	if (mxl_rd(a, 0x46, &lo) || mxl_rd(a, 0x47, &hi)) {
		mxl_wr(a, 0x00, 0x00);
		return -EIO;
	}
	ret = mxl_wr(a, 0x00, 0x00);            /* page 0                  */
	*strength = lo | ((hi & 0x07) << 8);
	return ret;
}

static int mxl_fe_get_tune_settings(struct dvb_frontend *fe,
				    struct dvb_frontend_tune_settings *s)
{
	s->min_delay_ms = 500;
	return 0;
}

static const struct dvb_frontend_ops mxl_fe_ops = {
	.delsys = { SYS_DVBT },
	.info = {
		.name = "MaxLinear MxL101SF (AIR 7310T)",
		.frequency_min_hz  = 174 * MHz,
		.frequency_max_hz  = 862 * MHz,
		.frequency_stepsize_hz = 1 * MHz,
		.caps = FE_CAN_FEC_1_2 | FE_CAN_FEC_2_3 | FE_CAN_FEC_3_4 |
			FE_CAN_FEC_5_6 | FE_CAN_FEC_7_8 | FE_CAN_FEC_AUTO |
			FE_CAN_QPSK | FE_CAN_QAM_16 | FE_CAN_QAM_64 |
			FE_CAN_QAM_AUTO | FE_CAN_TRANSMISSION_MODE_AUTO |
			FE_CAN_GUARD_INTERVAL_AUTO | FE_CAN_HIERARCHY_AUTO,
	},
	.init                 = mxl_fe_init,
	.set_frontend         = mxl_fe_set_frontend,
	.read_status          = mxl_fe_read_status,
	.read_snr             = mxl_fe_read_snr,
	.read_signal_strength = mxl_fe_read_signal_strength,
	.get_tune_settings    = mxl_fe_get_tune_settings,
};

/* ------------------------- XPT global bring-up --------------------------- */

/* Vendor BXPT_P_RsBuf_Init pointer discipline: BASE=off, END=off+size-1,
 * WRITE/VALID/READ = off-1 (empty), WM=0. */
static void band_ptrs(u32 tbl, u32 off, u32 size)
{
	xpt_wr(tbl + 0x00, off);
	xpt_wr(tbl + 0x04, off + size - 1);
	xpt_wr(tbl + 0x08, off - 1);
	xpt_wr(tbl + 0x0c, off - 1);
	xpt_wr(tbl + 0x10, off - 1);
	xpt_wr(tbl + 0x14, 0);
}

/* Whole-XPT sw-init pulse + staging buffers for both bands + table clears.
 * Runs once at probe, before anything streams. */
static int xpt_global_init(void)
{
	void __iomem *sun;
	u32 b, i;

	sun = ioremap(SUN_TOP_SW_INIT_SET, 8);
	if (!sun)
		return -ENOMEM;
	writel(BIT(18), sun);                   /* XPT into reset          */
	readl(sun);
	usleep_range(10000, 12000);
	writel(BIT(18), sun + 4);               /* out of reset            */
	readl(sun + 4);
	usleep_range(10000, 12000);
	iounmap(sun);

	/* Bandwidth pacing (40nm), vendor default formula. */
	xpt_wr(XPT_PACE0_CTRL, (xpt_rd(XPT_PACE0_CTRL) & ~0x33u) | 0x32u);
	xpt_wr(XPT_PACE0_VAL, XPT_PACE_MAGIC);
	xpt_wr(XPT_PACE1_CTRL, (xpt_rd(XPT_PACE1_CTRL) & ~0x33u) | 0x32u);
	xpt_wr(XPT_PACE1_VAL, XPT_PACE_MAGIC);

	/* Clear PID routing + MSG config + PID2BUF for all channels. */
	for (i = 0; i < 256; i++) {
		xpt_wr(XPT_PID_TABLE(i), 0x10000000);
		xpt_wr(XPT_SPID(i), 0);
		xpt_wr(XPT_MSG_PID2BUF_W(i, 0), 0);
		xpt_wr(XPT_MSG_PID2BUF_W(i, 1), 0);
		xpt_wr(XPT_MSG_PID2BUF_W(i, 2), 0);
		xpt_wr(XPT_MSG_PID2BUF_W(i, 3), 0);
	}
	for (i = 0; i < 128; i++) {
		xpt_wr(XPT_MSG_BUF_CTRL1(i), 0);
		xpt_wr(XPT_MSG_BUF_CTRL2(i), 0);
		xpt_wr(XPT_MSG_DMA_BP(i), 0);
		xpt_wr(XPT_MSG_GEN_FILT_EN(i), 0);
		xpt_wr(XPT_MSG_BUF_RESET, i);
	}

	/* RS + XC staging: real rings for band 0/1, shared dummy elsewhere.
	 * Staging RAM sits right after each adapter's MSG ring. */
	for (b = 0; b < RS_NUM_IBP_BANDS; b++) {
		u32 stage, dummy = air_board[0].ring_phys + AIR_RING_SIZE +
				   3u * AIR_STAGE_SIZE;

		if (b < AIR_NUM_ADAPTERS) {
			stage = air_board[b].ring_phys + AIR_RING_SIZE;
			band_ptrs(RS_G1_PTR(b), stage, AIR_STAGE_SIZE);
			band_ptrs(RS_G3_PTR(b), stage + AIR_STAGE_SIZE,
				  AIR_STAGE_SIZE);
			band_ptrs(XC_MSG_IBP_PTR(b), stage + 2u * AIR_STAGE_SIZE,
				  AIR_STAGE_SIZE);
		} else {
			band_ptrs(RS_G1_PTR(b), dummy, 0x100);
			band_ptrs(RS_G3_PTR(b), dummy, 0x100);
			band_ptrs(XC_MSG_IBP_PTR(b), dummy, 0x100);
		}
		xpt_wr(RS_G1_BO(b), (xpt_rd(RS_G1_BO(b)) & 0xff000000u) |
				    RS_BO_27MBPS);
		xpt_wr(RS_G3_BO(b), (xpt_rd(RS_G3_BO(b)) & 0xff000000u) |
				    RS_BO_27MBPS);
		xpt_wr(XC_MSG_IBP_BO(b), (xpt_rd(XC_MSG_IBP_BO(b)) &
					  0xff000000u) | RS_BO_27MBPS);
	}
	xpt_wr(RS_EN_G1, BIT(0) | BIT(1));
	xpt_wr(RS_EN_G3, BIT(0) | BIT(1));
	xpt_wr(RS_EN_G2, 0);
	xpt_wr(XC_GLOBAL_CTRL, (xpt_rd(XC_GLOBAL_CTRL) & ~0xfu) | 0xcu);
	xpt_wr(XC_MSG_IBP_EN, BIT(0) | BIT(1));
	xpt_wr(XC_RAVE_IBP_EN, 0);
	xpt_wr(XC_RAVE_PBP_EN, 0);
	xpt_wr(XC_MSG_PBP_EN, 0);
	xpt_wr(XC_RMX0_IBP_EN, 0);
	xpt_wr(XC_RMX0_PBP_EN, 0);
	xpt_wr(XC_RMX1_IBP_EN, 0);
	xpt_wr(XC_RMX1_PBP_EN, 0);
	return 0;
}

/* Per-adapter XPT paths: MSG ring buffer, parser, input band. */
static void xpt_adapter_init(struct air_adapter *a)
{
	u32 n = a->buf, v;

	/* MSG ring: program but leave DISARMED (CTRL1=0).  Arming happens on
	 * the first feed, right before draining starts — arming an idle
	 * buffer at probe lets any stale XC backlog flood it and freeze its
	 * engine context (the userspace-validated flow always does setup
	 * immediately before capture for the same reason). */
	xpt_wr(XPT_MSG_BUF_CTRL1(n), 0);
	xpt_wr(XPT_MSG_BUF_RESET, n);
	xpt_wr(XPT_MSG_DMA_BP(n), (a->ring_phys >> 10) | (9u << 28));
	xpt_wr(XPT_MSG_BUF_RESET, n);
	xpt_wr(XPT_MSG_GEN_FILT_EN(n), 0);
	xpt_wr(XPT_MSG_BUF_CTRL2(n), 0);

	/* Parser idx <- input band idx, MPEG 188, PID-match mode. */
	v = xpt_rd(XPT_FE_PARSER_CTRL1(a->idx));
	v = (v & ~PARSER_WR_FIELDS) | (188u << 12) | ((u32)a->idx << 8) |
	    PARSER_ACCEPT_NULL | PARSER_CC_IGNORE | PARSER_ENABLE;
	xpt_wr(XPT_FE_PARSER_CTRL1(a->idx), v);

	/* Input band idx: 188-byte packets, serial, sync detect. */
	v = xpt_rd(XPT_FE_IB_CTRL(a->idx));
	v = (v & ~IB_WR_FIELDS) | (0xbcu << 16) | IB_SYNC_DETECT_EN;
	xpt_wr(XPT_FE_IB_CTRL(a->idx), v);
}

/* --------------------------- hw PID channels ----------------------------- */

static void air_ring_reprogram(struct air_adapter *a);

static void air_chan_program(struct air_adapter *a, u32 slot, u16 pid)
{
	u32 chan = (pid == 0x2000) ? (u32)a->idx
		 : AIR_CHAN_BASE + a->idx * AIR_CHANS_PER_ADAP + slot;
	u32 buf = a->buf, w, v;

	for (w = 0; w < 4; w++)
		xpt_wr(XPT_MSG_PID2BUF_W(chan, w),
		       (w == (buf >> 5)) ? BIT(buf & 31) : 0);
	xpt_wr(XPT_SPID(chan),
	       (xpt_rd(XPT_SPID(chan)) & 0x00ffffffu) | SPID_DEST_RECORD);

	v = xpt_rd(XPT_PID_TABLE(chan));
	if (pid == 0x2000) {            /* whole mux: parser all-pass      */
		v = (v & PID_KEEP_MASK & ~PID_ENABLE) | (a->idx << 16);
		xpt_wr(XPT_FE_PARSER_CTRL1(a->idx),
		       xpt_rd(XPT_FE_PARSER_CTRL1(a->idx)) | PARSER_ALL_PASS);
	} else {
		v = (v & PID_KEEP_MASK_PIDMATCH & ~PID_ENABLE) |
		    (a->idx << 16) | pid;
	}
	xpt_wr(XPT_PID_TABLE(chan), v);
	xpt_wr(XPT_PID_TABLE(chan), v | PID_ENABLE);
}

static void air_chan_disable(struct air_adapter *a, u32 slot, u16 pid)
{
	u32 chan = (pid == 0x2000) ? (u32)a->idx
		 : AIR_CHAN_BASE + a->idx * AIR_CHANS_PER_ADAP + slot;
	u32 w;

	xpt_wr(XPT_PID_TABLE(chan),
	       xpt_rd(XPT_PID_TABLE(chan)) & ~PID_ENABLE);
	xpt_wr(XPT_SPID(chan), xpt_rd(XPT_SPID(chan)) & 0x00ffffffu);
	for (w = 0; w < 4; w++)
		xpt_wr(XPT_MSG_PID2BUF_W(chan, w), 0);
	if (pid == 0x2000)
		xpt_wr(XPT_FE_PARSER_CTRL1(a->idx),
		       xpt_rd(XPT_FE_PARSER_CTRL1(a->idx)) & ~PARSER_ALL_PASS);
}

static int air_start_feed(struct dvb_demux_feed *feed)
{
	struct air_adapter *a = feed->demux->priv;
	int slot, free = -1;

	mutex_lock(&a->lock);
	for (slot = 0; slot < AIR_CHANS_PER_ADAP; slot++) {
		if (a->chan_ref[slot] && a->chan_pid[slot] == feed->pid) {
			a->chan_ref[slot]++;
			mutex_unlock(&a->lock);
			return 0;
		}
		if (!a->chan_ref[slot] && free < 0)
			free = slot;
	}
	if (free < 0) {
		mutex_unlock(&a->lock);
		return -EBUSY;
	}
	a->chan_pid[free] = feed->pid;
	a->chan_ref[free] = 1;
	if (a->nfeeds++ == 0 && !(xpt_rd(XPT_MSG_BUF_CTRL1(a->buf)) & 1))
		air_ring_reprogram(a);  /* first-ever feed: arm the ring   */
	air_chan_program(a, free, feed->pid);
	mutex_unlock(&a->lock);
	pr_info(DRVNAME ": adapter%d: start pid 0x%04x -> chan %d (type %d ts_type %x)\n",
		a->idx, feed->pid, AIR_CHAN_BASE + a->idx * AIR_CHANS_PER_ADAP + free,
		feed->type, feed->ts_type);
	return 0;
}

static int air_stop_feed(struct dvb_demux_feed *feed)
{
	struct air_adapter *a = feed->demux->priv;
	int slot;

	mutex_lock(&a->lock);
	for (slot = 0; slot < AIR_CHANS_PER_ADAP; slot++) {
		if (a->chan_ref[slot] && a->chan_pid[slot] == feed->pid) {
			if (!--a->chan_ref[slot]) {
				air_chan_disable(a, slot, feed->pid);
				/* NEVER disarm CTRL1 here: dropping CTRL1 while
				 * the engine may be mid-write wedges the buffer
				 * context beyond recovery (only a buffer
				 * migration or a power cycle clears it) */
				a->nfeeds--;
				pr_info(DRVNAME ": adapter%d: stop pid 0x%04x (chan %d)\n",
					a->idx, feed->pid,
					AIR_CHAN_BASE + a->idx * AIR_CHANS_PER_ADAP + slot);
			}
			break;
		}
	}
	mutex_unlock(&a->lock);
	return 0;
}

/* ------------------------------ ring drain ------------------------------- */

/* Full ring reprogram, mirroring the validated `setup` sequence.  Used at
 * thread start and as the recovery path when the engine wedges paused-full.
 * NOTE: VP bit31 is NOT an overflow latch — it is a "ring non-empty" flag
 * that is perfectly normal while data is in flight.  Treating it as an
 * error and resetting on sight puts the drain in an infinite reset loop
 * (the engine refills instantly) and eventually wedges the whole MSG
 * state machine until a POWER CYCLE (SRAM survives warm reboot). */
static void air_ring_reprogram(struct air_adapter *a)
{
	u32 n = a->buf;

	xpt_wr(XPT_MSG_BUF_CTRL1(n), 0);
	xpt_wr(XPT_MSG_BUF_RESET, n);
	xpt_wr(XPT_MSG_DMA_BP(n), (a->ring_phys >> 10) | (9u << 28));
	xpt_wr(XPT_MSG_BUF_RESET, n);
	xpt_wr(XPT_MSG_GEN_FILT_EN(n), 0);
	xpt_wr(XPT_MSG_BUF_CTRL2(n), 0);
	xpt_wr(XPT_MSG_BUF_CTRL1(n), 1);
}

/* A wedged buffer context silently consumes and writes nothing; no reset
 * or reprogram revives it (SRAM state, survives warm reboot — only a real
 * power-off clears it).  There are 128 contexts though, so the recovery
 * that WORKS is migration: hop to a fresh buffer and re-route the active
 * channels' PID2BUF masks. */
static void air_ring_migrate(struct air_adapter *a)
{
	int slot;
	u32 w;

	mutex_lock(&a->lock);
	xpt_wr(XPT_MSG_BUF_CTRL1(a->buf), 0);   /* silence the dead buf    */
	a->buf += 2;
	if (a->buf > 62)
		a->buf = 16 + a->idx;           /* wrap into a fresh range */
	air_ring_reprogram(a);
	for (slot = 0; slot < AIR_CHANS_PER_ADAP; slot++) {
		u32 chan = (a->chan_pid[slot] == 0x2000) ? (u32)a->idx :
			   AIR_CHAN_BASE + a->idx * AIR_CHANS_PER_ADAP + slot;

		if (!a->chan_ref[slot])
			continue;
		for (w = 0; w < 4; w++)
			xpt_wr(XPT_MSG_PID2BUF_W(chan, w),
			       (w == (a->buf >> 5)) ? BIT(a->buf & 31) : 0);
	}
	mutex_unlock(&a->lock);
	pr_warn(DRVNAME ": adapter%d: buffer wedged — migrated to buf %u\n",
		a->idx, a->buf);
}

static int air_drain_thread(void *data)
{
	struct air_adapter *a = data;
	u32 size = a->ring_size;
	u64 total = 0;
	unsigned int stuck = 0;
	u32 last_vp = 0xffffffff;
	unsigned long last_change = jiffies;
	unsigned long last_log = jiffies;

	while (!kthread_should_stop()) {
		u32 n = a->buf;
		if (time_after(jiffies, last_log + 10 * HZ)) {
			pr_info(DRVNAME ": adapter%d: %llu TS bytes drained (VP=%08x)\n",
				a->idx, total, xpt_rd(XPT_MSG_DMA_VP(n)));
			last_log = jiffies;
		}
		if (!(xpt_rd(XPT_MSG_BUF_CTRL1(n)) & 1)) {
			usleep_range(10000, 20000);     /* ring disarmed   */
			continue;
		}
		u32 vp_raw = xpt_rd(XPT_MSG_DMA_VP(n));
		u32 vp = vp_raw & (size - 1);
		u32 rp = xpt_rd(XPT_MSG_DMA_RP(n)) & (size - 1);
		u32 count;

		if (vp_raw != last_vp) {
			last_vp = vp_raw;
			last_change = jiffies;
		} else if (a->nfeeds > 0 &&
			   time_after(jiffies, last_change + 3 * HZ)) {
			/* Feeds active yet VP frozen 3 s: assume a wedged
			 * buffer context and hop.  (SYNC_COUNT can't gate
			 * this — it's an acquisition counter that latches,
			 * not a flow meter.)  A hop with no TS flowing is
			 * wasted but harmless; the 15 s cadence keeps an
			 * unlocked tuner from burning through the pool. */
			air_ring_migrate(a);
			last_vp = 0xffffffff;
			last_change = jiffies + 12 * HZ;
			continue;
		}
		if (vp == rp && (vp_raw & BIT(31))) {
			/* we think empty, engine thinks non-empty: only a
			 * sustained disagreement is a real paused-full wedge */
			if (++stuck > 250) {    /* ~1 s of 2-4 ms sleeps    */
				pr_warn(DRVNAME ": adapter%d: ring wedged, reprogramming\n",
					a->idx);
				air_ring_reprogram(a);
				stuck = 0;
			}
			usleep_range(2000, 4000);
			continue;
		}
		stuck = 0;
		count = (vp - rp) & (size - 1);
		if (count >= 2 * 188) {
			/* Copy across the wrap in two spans; drain must never
			 * round a span to zero or RP stops advancing and the
			 * engine parks paused-full forever. */
			u32 first = min(count, size - rp);
			u32 sync = 0, usable;

			memcpy_fromio(a->bounce, a->ring + rp, first);
			if (count > first)
				memcpy_fromio(a->bounce + first, a->ring,
					      count - first);
			/* The hw pointers advance in burst quanta, not in
			 * packets, and a pause/resume can shift the packet
			 * phase inside the ring — trust the sync bytes, not
			 * the pointers: lock onto 0x47 every 188. */
			while (sync < 188 && sync + 188 < count &&
			       !(a->bounce[sync] == 0x47 &&
				 a->bounce[sync + 188] == 0x47))
				sync++;
			usable = (count - sync) / 188 * 188;
			/* keep the trailing partial packet for next round */
			if (usable >= 188 && a->bounce[sync] == 0x47) {
				dvb_dmx_swfilter_packets(&a->demux,
							 a->bounce + sync,
							 usable / 188);
				total += usable;
			} else {
				usable = count - sync;  /* junk: discard   */
			}
			rp = (rp + sync + usable) & (size - 1);
			xpt_wr(XPT_MSG_DMA_RP(n), rp);
			continue;
		}
		usleep_range(2000, 4000);
	}
	return 0;
}

/* ------------------------------ registration ----------------------------- */

static void air_adapter_destroy(struct air_adapter *a);

static int air_adapter_create(struct device *dev, int idx)
{
	struct air_adapter *a;
	struct dvb_demux *d;
	int ret;

	a = kzalloc(sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;
	a->idx = idx;
	a->i2c_addr = air_board[idx].i2c_addr;
	a->buf = 4 + idx;
	a->ring_phys = air_board[idx].ring_phys;
	a->ring_size = AIR_RING_SIZE;
	mutex_init(&a->lock);

	a->i2c = i2c_get_adapter(AIR_I2C_BUS);
	if (!a->i2c) {
		ret = -EPROBE_DEFER;
		goto err_free;
	}

	a->ring = ioremap(a->ring_phys, a->ring_size);
	a->bounce = kmalloc(a->ring_size, GFP_KERNEL);
	if (!a->ring || !a->bounce) {
		ret = -ENOMEM;
		goto err_i2c;
	}

	ret = mxl_chip_init(a);
	if (ret)
		goto err_i2c;
	xpt_adapter_init(a);

	ret = dvb_register_adapter(&a->dvb, "BCM7231 XPT", THIS_MODULE,
				   dev, adapter_nr);
	if (ret < 0)
		goto err_i2c;

	a->fe.ops = mxl_fe_ops;
	a->fe.demodulator_priv = a;
	ret = dvb_register_frontend(&a->dvb, &a->fe);
	if (ret)
		goto err_adap;

	d = &a->demux;
	d->priv = a;
	d->dmx.capabilities = DMX_TS_FILTERING | DMX_SECTION_FILTERING |
			      DMX_MEMORY_BASED_FILTERING;
	d->feednum = AIR_CHANS_PER_ADAP;
	d->filternum = AIR_CHANS_PER_ADAP;
	d->start_feed = air_start_feed;
	d->stop_feed = air_stop_feed;
	ret = dvb_dmx_init(d);
	if (ret)
		goto err_fe;

	a->dmxdev.filternum = AIR_CHANS_PER_ADAP;
	a->dmxdev.demux = &d->dmx;
	a->dmxdev.capabilities = 0;
	ret = dvb_dmxdev_init(&a->dmxdev, &a->dvb);
	if (ret)
		goto err_dmx;

	a->hw_fe.source = DMX_FRONTEND_0;
	d->dmx.add_frontend(&d->dmx, &a->hw_fe);
	a->mem_fe.source = DMX_MEMORY_FE;
	d->dmx.add_frontend(&d->dmx, &a->mem_fe);
	d->dmx.connect_frontend(&d->dmx, &a->hw_fe);

	a->thread = kthread_run(air_drain_thread, a, "airdvb%d", idx);
	if (IS_ERR(a->thread)) {
		ret = PTR_ERR(a->thread);
		a->thread = NULL;
		goto err_dmxdev;
	}

	air_adapters[idx] = a;
	pr_info(DRVNAME ": adapter%d: MxL101SF @0x%02x, IB%d, ring 0x%08x\n",
		idx, a->i2c_addr, idx, a->ring_phys);
	return 0;

err_dmxdev:
	dvb_dmxdev_release(&a->dmxdev);
err_dmx:
	dvb_dmx_release(&a->demux);
err_fe:
	dvb_unregister_frontend(&a->fe);
err_adap:
	dvb_unregister_adapter(&a->dvb);
err_i2c:
	if (a->ring)
		iounmap(a->ring);
	kfree(a->bounce);
	i2c_put_adapter(a->i2c);
err_free:
	kfree(a);
	return ret;
}

static void air_adapter_destroy(struct air_adapter *a)
{
	if (!a)
		return;
	if (a->thread)
		kthread_stop(a->thread);
	a->demux.dmx.disconnect_frontend(&a->demux.dmx);
	a->demux.dmx.remove_frontend(&a->demux.dmx, &a->mem_fe);
	a->demux.dmx.remove_frontend(&a->demux.dmx, &a->hw_fe);
	dvb_dmxdev_release(&a->dmxdev);
	dvb_dmx_release(&a->demux);
	dvb_unregister_frontend(&a->fe);
	dvb_unregister_adapter(&a->dvb);
	iounmap(a->ring);
	kfree(a->bounce);
	i2c_put_adapter(a->i2c);
	kfree(a);
}

static int air_probe(struct platform_device *pdev)
{
	int i, ret;

	xpt_base = ioremap(XPT_MAP_BASE, XPT_MAP_LEN);
	if (!xpt_base)
		return -ENOMEM;

	ret = xpt_global_init();
	if (ret)
		goto err_unmap;

	for (i = 0; i < AIR_NUM_ADAPTERS; i++) {
		ret = air_adapter_create(&pdev->dev, i);
		if (ret) {
			/* the slave tuner is optional — keep adapter0 */
			if (i == 0)
				goto err_unmap;
			pr_warn(DRVNAME ": adapter%d skipped (%d)\n", i, ret);
		}
	}
	return 0;

err_unmap:
	iounmap(xpt_base);
	xpt_base = NULL;
	return ret;
}

static void air_remove(struct platform_device *pdev)
{
	int i;

	for (i = AIR_NUM_ADAPTERS - 1; i >= 0; i--) {
		air_adapter_destroy(air_adapters[i]);
		air_adapters[i] = NULL;
	}
	if (xpt_base) {
		iounmap(xpt_base);
		xpt_base = NULL;
	}
}

static struct platform_driver air_driver = {
	.probe  = air_probe,
	.remove = air_remove,
	.driver = { .name = DRVNAME },
};

static struct platform_device *air_pdev;

static int __init air_init(void)
{
	int ret;

	ret = platform_driver_register(&air_driver);
	if (ret)
		return ret;
	air_pdev = platform_device_register_simple(DRVNAME, -1, NULL, 0);
	if (IS_ERR(air_pdev)) {
		platform_driver_unregister(&air_driver);
		return PTR_ERR(air_pdev);
	}
	return 0;
}

static void __exit air_exit(void)
{
	platform_device_unregister(air_pdev);
	platform_driver_unregister(&air_driver);
}

module_init(air_init);
module_exit(air_exit);

MODULE_DESCRIPTION("AirTies AIR 7310T DVB (BCM7231 XPT + 2x MxL101SF)");
MODULE_AUTHOR("Leonard");
MODULE_LICENSE("GPL");
