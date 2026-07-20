// SPDX-License-Identifier: GPL-2.0
/*
 * BCM7231 KIR (keyboard / IR receiver) input driver — AirTies AIR 7310T.
 *
 * The stock Wyplay firmware drives this block through the proprietary
 * nexus.ko blob (magnum "BKIR" driver + NEXUS_IrInput glue).  nexus.ko is
 * not stripped, so every register access was traced by disassembly and the
 * programming below is reproduced verbatim:
 *
 *  - 3 identical 0x40-byte channel windows at BCHP 0x4088c0/0x408900/0x408940
 *    (physical 0x104088c0...).  The stock stack uses channel 0.
 *  - window +0x00 STATUS: bit0 = data-ready/IRQ (ack: write back value & ~1),
 *    bit1 = "repeated", bits[4:2] = byte count, bit5/6 = preamble B/A.
 *  - window +0x08 FILTER1: protocol filter, 0 for the Ruwido remote.
 *  - window +0x0c DATA_LO: frame bits 32..39 (low byte).
 *  - window +0x10 DATA_HI: frame bits 0..31 (little-endian, register value
 *    is the 32-bit code exactly as the nexus glue assembles it).
 *  - window +0x14 CTRL: 7 at open, |0x10 for Ruwido, |0x20 = IRQ enable.
 *  - window +0x18/+0x1c: CIR parameter register file (index then 12-bit
 *    value); the Ruwido timing set (nexus protocol 0x17) is dumped from
 *    nexus.ko .rodata and replayed as-is (KIR_RUWIDO_CIR below).
 *  - 0x408b80 KIR_TOP: bit0 routes channel 0 (bits 5/8 = ch1/ch2).
 *  - IRQ: dedicated L1 hwirq 60 (measured on hardware with kir_probe;
 *    level, deasserts on STATUS ack).
 *
 * Frame decode (from nexus_input.ko, stock userspace glue):
 *   (code & 0x7fff) in [0x7e00, 0x7f00)  =>  key index = code & 0x7f,
 * mapped through the 128-entry table dumped from the same module
 * (KIR_KEYMAP below) — this yields the exact keycodes the stock firmware
 * delivers on /dev/input/event0.
 */

#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/timer.h>

#define KIR_WIN0	0x0c0	/* channel 0 window offset within the block */
#define KIR_TOP		0x380	/* top-level routing register */

#define KIR_STATUS	0x00
#define KIR_FILTER1	0x08
#define KIR_DATA_LO	0x0c
#define KIR_DATA_HI	0x10
#define KIR_CTRL	0x14
#define KIR_CIR_IDX	0x18
#define KIR_CIR_VAL	0x1c

#define KIR_STATUS_READY	BIT(0)
#define KIR_STATUS_REPEAT	BIT(1)

#define KIR_CTRL_BASE		0x07
#define KIR_CTRL_PROTO		0x10	/* Ruwido (protocol 0x17) */
#define KIR_CTRL_IRQEN		0x20

#define KIR_RELEASE_MS	150	/* stock glue uses 125; frames repeat ~120 ms */

/* CIR parameter file for nexus protocol 0x17 (Ruwido), packed exactly as
 * BKIR_P_ConfigCir does from its .rodata struct.  Index 24 is never written. */
static const struct { u8 idx; u16 val; } kir_ruwido_cir[] = {
	{  0, 0x019 }, {  1, 0x000 }, {  2, 0x001 }, {  3, 0xca5 },
	{  4, 0x000 }, {  5, 0x000 }, {  6, 0x000 }, {  7, 0x000 },
	{  8, 0x000 }, {  9, 0x000 }, { 10, 0x000 }, { 11, 0x210 },
	{ 12, 0x000 }, { 13, 0xc43 }, { 14, 0x145 }, { 15, 0x000 },
	{ 16, 0x035 }, { 17, 0x043 }, { 18, 0x180 }, { 19, 0x0f9 },
	{ 20, 0x004 }, { 21, 0x003 }, { 22, 0x000 }, { 23, 0x000 },
	{ 25, 0x000 }, { 26, 0x400 }, { 27, 0x000 },
};

/* key index -> keycode, dumped from nexus_input.ko (.rodata, 128 x u16).
 * A full-remote sweep on hardware (2026-07-20) hit all 36 entries and no
 * others.  Physical layout, top to bottom: power / 1..9 / 0x3e 0 0x2e /
 * back home / d-pad (up, left, ok, right, down) / menu / info text epg /
 * media search / vol+- rec stop ch+- / rew play pause ffwd. */
static const unsigned short kir_keymap[128] = {
	[0x16] = KEY_9,  [0x17] = KEY_8,  [0x18] = KEY_7,  [0x19] = KEY_6,
	[0x1a] = KEY_5,  [0x1b] = KEY_4,  [0x1c] = KEY_3,  [0x1d] = KEY_2,
	[0x1e] = KEY_1,  [0x1f] = KEY_0,
	[0x25] = KEY_MEDIA,  [0x28] = KEY_MENU,  [0x2a] = KEY_VOLUMEUP,
	[0x2c] = KEY_SEARCH, [0x2d] = KEY_REWIND, [0x2e] = KEY_F2,
	[0x2f] = KEY_PLAY,   [0x30] = KEY_PAUSE,  [0x31] = KEY_RECORD,
	[0x33] = KEY_TEXT,   [0x34] = KEY_POWER,  [0x35] = KEY_VOLUMEDOWN,
	[0x36] = KEY_INFO,   [0x37] = KEY_HOME,   [0x39] = KEY_FORWARD,
	[0x3a] = KEY_EPG,    [0x3d] = KEY_STOP,   [0x3e] = KEY_F1,
	[0x57] = KEY_DOWN,   [0x58] = KEY_RIGHT,  [0x59] = KEY_UP,
	[0x5a] = KEY_LEFT,   [0x5d] = KEY_CHANNELDOWN, [0x5e] = KEY_CHANNELUP,
	[0x64] = KEY_BACKSPACE, [0x72] = KEY_SELECT,
};

struct kir_dev {
	void __iomem *base;
	struct input_dev *input;
	struct timer_list release_timer;
	unsigned int last_key;
};

static void kir_release(struct timer_list *t)
{
	struct kir_dev *kir = timer_container_of(kir, t, release_timer);

	if (kir->last_key) {
		input_report_key(kir->input, kir->last_key, 0);
		input_sync(kir->input);
		kir->last_key = 0;
	}
}

static irqreturn_t kir_irq(int irq, void *dev_id)
{
	struct kir_dev *kir = dev_id;
	void __iomem *win = kir->base + KIR_WIN0;
	u32 status, code, idx, key;

	status = readl(win + KIR_STATUS);
	if (!(status & KIR_STATUS_READY))
		return IRQ_NONE;

	code = readl(win + KIR_DATA_HI);
	/* frame bits 32..39 live in the low byte of DATA_LO (count in
	 * STATUS[4:2]); the Ruwido codes we decode fit in the low 32 bits */
	readl(win + KIR_DATA_LO);
	writel(status & ~KIR_STATUS_READY, win + KIR_STATUS);

	if ((code & 0x7fff) - 0x7e00 >= 0x100)
		return IRQ_HANDLED;	/* not a Ruwido key frame */

	idx = code & 0x7f;
	key = kir_keymap[idx];
	if (!key)
		return IRQ_HANDLED;

	if (status & KIR_STATUS_REPEAT) {
		if (kir->last_key == key) {
			input_event(kir->input, EV_KEY, key, 2);
			input_sync(kir->input);
		}
	} else {
		if (kir->last_key && kir->last_key != key) {
			input_report_key(kir->input, kir->last_key, 0);
			input_sync(kir->input);
		}
		input_report_key(kir->input, key, 1);
		input_sync(kir->input);
		kir->last_key = key;
	}
	mod_timer(&kir->release_timer, jiffies + msecs_to_jiffies(KIR_RELEASE_MS));
	return IRQ_HANDLED;
}

static void kir_hw_init(struct kir_dev *kir)
{
	void __iomem *win = kir->base + KIR_WIN0;
	int i;

	writel(KIR_CTRL_BASE, win + KIR_CTRL);		/* BKIR_OpenChannel */
	writel(readl(kir->base + KIR_TOP) | 1, kir->base + KIR_TOP);
	for (i = 0; i < ARRAY_SIZE(kir_ruwido_cir); i++) {
		writel(kir_ruwido_cir[i].idx, win + KIR_CIR_IDX);
		writel(kir_ruwido_cir[i].val & 0xfff, win + KIR_CIR_VAL);
	}
	writel(0, win + KIR_FILTER1);			/* BKIR_EnableIrDevice(0x17) */
	writel(KIR_CTRL_BASE | KIR_CTRL_PROTO | KIR_CTRL_IRQEN, win + KIR_CTRL);
	writel(readl(win + KIR_STATUS) & ~KIR_STATUS_READY, win + KIR_STATUS);
}

static int kir_probe(struct platform_device *pdev)
{
	struct kir_dev *kir;
	struct input_dev *input;
	int irq, i, err;

	kir = devm_kzalloc(&pdev->dev, sizeof(*kir), GFP_KERNEL);
	if (!kir)
		return -ENOMEM;

	kir->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(kir->base))
		return PTR_ERR(kir->base);

	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;

	input = devm_input_allocate_device(&pdev->dev);
	if (!input)
		return -ENOMEM;

	input->name = "AirTies Ruwido remote (BCM7231 KIR)";
	input->phys = "kir/input0";
	input->id.bustype = BUS_HOST;
	input->dev.parent = &pdev->dev;
	__set_bit(EV_KEY, input->evbit);
	__set_bit(EV_REP, input->evbit);
	for (i = 0; i < ARRAY_SIZE(kir_keymap); i++)
		if (kir_keymap[i])
			__set_bit(kir_keymap[i], input->keybit);

	kir->input = input;
	timer_setup(&kir->release_timer, kir_release, 0);
	kir_hw_init(kir);

	err = devm_request_irq(&pdev->dev, irq, kir_irq, 0, "bcm7231-kir", kir);
	if (err)
		return err;

	return input_register_device(input);
}

static const struct of_device_id kir_of_match[] = {
	{ .compatible = "brcm,bcm7231-kir" },
	{ }
};

static struct platform_driver kir_driver = {
	.probe = kir_probe,
	.driver = {
		.name = "bcm7231-kir",
		.of_match_table = kir_of_match,
	},
};
builtin_platform_driver(kir_driver);
