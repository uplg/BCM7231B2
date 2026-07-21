/*
 * mxl_probe.c — userspace bring-up of the MaxLinear MxL101SF DVB-T
 * tuner/demodulators of the AIR 7310T, over /dev/i2c-1 (chips at 0x60 and
 * 0x63, confirmed CHIP_ID 0x61 / V6 silicon).
 *
 * Register sequences are the STOCK ones, dumped verbatim from the vendor
 * libwydvb.so .data (MxL_* tables): soft reset, OverwriteDefault, device
 * mode (TunerDemodMode), top-master enable, per-channel PhyTuneRF (regs
 * 0x1d/0x1e/0x1f = filter BW + freq*64/MHz) + bandwidth spur coefficients
 * + IRQ clear.  Status regs are the V6 layout from the mainline mxl111sf
 * driver (same silicon core).  The vendor OverwriteDefault differs from
 * mainline's — using the stock one is what makes the synths lock here.
 *
 * I2C protocol: register read = write {0xFB, reg} then read 1 byte
 * (repeated start); register write = plain {reg, val}.  Reg 0x00 selects
 * the register page.
 *
 * Without an antenna this validates everything except the final DVB lock:
 * chip comms, init, and the tuner REF/RF synthesizer locks (PLLs lock on
 * their own, no RF input needed); RSSI reads the noise floor and the
 * demod cleanly reports "no lock".
 *
 * Usage: mxl_probe [-a 0x63] [-b <i2c-bus>] [-f <freq-hz>] [-w <bw-mhz>]
 *                  [-t <poll-seconds>]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int fd;
static int addr = 0x60;

static int rd(uint8_t reg, uint8_t *val)
{
    uint8_t wbuf[2] = { 0xfb, reg };
    struct i2c_msg msgs[2] = {
        { .addr = addr, .flags = 0,        .len = 2, .buf = wbuf },
        { .addr = addr, .flags = I2C_M_RD, .len = 1, .buf = val  },
    };
    struct i2c_rdwr_ioctl_data x = { .msgs = msgs, .nmsgs = 2 };
    if (ioctl(fd, I2C_RDWR, &x) < 0) {
        fprintf(stderr, "i2c read reg 0x%02x failed\n", reg);
        return -1;
    }
    return 0;
}

static int wr(uint8_t reg, uint8_t val)
{
    uint8_t wbuf[2] = { reg, val };
    struct i2c_msg msg = { .addr = addr, .flags = 0, .len = 2, .buf = wbuf };
    struct i2c_rdwr_ioctl_data x = { .msgs = &msg, .nmsgs = 1 };
    if (ioctl(fd, I2C_RDWR, &x) < 0) {
        fprintf(stderr, "i2c write reg 0x%02x=0x%02x failed\n", reg, val);
        return -1;
    }
    return 0;
}

struct reg_ctrl { uint8_t reg, mask, val; };

static int program(const struct reg_ctrl *t)
{
    for (; t->mask; t++) {
        uint8_t v = t->val;
        if (t->mask != 0xff) {
            uint8_t cur;
            if (rd(t->reg, &cur)) return -1;
            v = (cur & ~t->mask) | (t->val & t->mask);
        }
        if (wr(t->reg, v)) return -1;
    }
    return 0;
}

/* Stock tables, dumped from libwydvb.so .data — byte-exact. */
static const struct reg_ctrl mxl_overwrite_default[] = {
    {0x42, 0xff, 0x33}, {0x71, 0xff, 0x66}, {0x72, 0xff, 0x01},
    {0x73, 0xff, 0x00}, {0x74, 0xff, 0xc2}, {0x71, 0xff, 0xe6},
    {0x6f, 0xff, 0xb7}, {0x98, 0xff, 0x40}, {0x99, 0xff, 0x18},
    {0xe0, 0xff, 0x00}, {0xe1, 0xff, 0x10}, {0xe2, 0xff, 0x91},
    {0xe4, 0xff, 0x3f}, {0xb1, 0xff, 0x00}, {0xb2, 0xff, 0x09},
    {0xb3, 0xff, 0x1f}, {0xb4, 0xff, 0x1f},
    {0x00, 0xff, 0x01},                     /* page 1 */
    {0xe2, 0xff, 0x02}, {0x81, 0xff, 0x04}, {0xf4, 0xff, 0x07},
    {0xb8, 0xff, 0x42}, {0xbf, 0xff, 0x1c}, {0x82, 0xff, 0xc6},
    {0x87, 0xff, 0x01}, {0x81, 0x1c, 0x04}, {0x83, 0xff, 0xcf},
    {0x85, 0xff, 0x02},
    {0x00, 0xff, 0x02},                     /* page 2 */
    {0x27, 0xff, 0x20},
    {0x00, 0xff, 0x00},                     /* page 0 */
    {0, 0, 0}
};

static const struct reg_ctrl mxl_tuner_demod_mode[] = {   /* SOC mode */
    {0x03, 0xff, 0x01}, {0x7d, 0x40, 0x00}, {0x3b, 0x20, 0x20},
    {0, 0, 0}
};

/* Crystal settings — reversed from the stock MxL101SF_Init /
 * DevConfigXtalSettings path (NOT in the vendor OverwriteDefault table).
 * Init passes xtalSel=4, biasCurrent=4, capValue=10, clkOutGain=8:
 *   XtalSelect(4)   -> reg 0x07 = 4, reg 0x32 = 4|0xa0 = 0xa4
 *   ClkOutGain(8)   -> reg 0x31 = 8
 *   BiasControl(4)  -> reg 0x66 = 4|0x10 = 0x14
 *   CapControl(10)  -> reg 0x08 = 0x0a
 * ClkOutControl enables reg 0x06 bit5 on the master (done separately). */
static const struct reg_ctrl mxl_xtal_settings[] = {
    {0x07, 0xff, 0x04}, {0x32, 0xff, 0xa4}, {0x31, 0xff, 0x08},
    {0x66, 0xff, 0x14}, {0x08, 0xff, 0x0a},
    {0, 0, 0}
};

static const struct reg_ctrl mxl_spur_6mhz[] = {
    {0x00, 0xff, 0x01}, {0x84, 0xff, 0xa1}, {0x86, 0xff, 0x9b},
    {0x00, 0xff, 0x02}, {0xdd, 0xff, 0x14}, {0xde, 0xff, 0x0d},
    {0x00, 0xff, 0x00}, {0, 0, 0}
};
static const struct reg_ctrl mxl_spur_7mhz[] = {
    {0x00, 0xff, 0x01}, {0x84, 0xff, 0x96}, {0x86, 0xff, 0xa0},
    {0x00, 0xff, 0x02}, {0xdd, 0xff, 0x42}, {0xde, 0xff, 0x0f},
    {0x00, 0xff, 0x00}, {0, 0, 0}
};
static const struct reg_ctrl mxl_spur_8mhz[] = {
    {0x00, 0xff, 0x01}, {0x84, 0xff, 0x8c}, {0x86, 0xff, 0x6c},
    {0x00, 0xff, 0x02}, {0xdd, 0xff, 0x70}, {0xde, 0xff, 0x11},
    {0x00, 0xff, 0x00}, {0, 0, 0}
};

int main(int argc, char **argv)
{
    int bus = 1, secs = 8, clkout = 0, scan = 0, tson = 0, opt;
    uint32_t freq = 586000000, bw = 8;

    while ((opt = getopt(argc, argv, "a:b:f:w:t:msT")) != -1) {
        switch (opt) {
        case 'a': addr = strtoul(optarg, NULL, 0); break;
        case 'b': bus  = atoi(optarg); break;
        case 'f': freq = strtoul(optarg, NULL, 0); break;
        case 'w': bw   = atoi(optarg); break;
        case 't': secs = atoi(optarg); break;
        case 'm': clkout = 1; break;
        case 's': scan = 1; break;
        case 'T': tson = 1; break;
        default:
            fprintf(stderr, "usage: %s [-a addr] [-b bus] [-f freq-hz] "
                            "[-w bw-mhz] [-t poll-secs]\n", argv[0]);
            return 1;
        }
    }

    char dev[32];
    snprintf(dev, sizeof(dev), "/dev/i2c-%d", bus);
    fd = open(dev, O_RDWR);
    if (fd < 0) { perror(dev); return 1; }

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("MxL101SF @ %s addr 0x%02x — tune %u Hz, BW %u MHz\n",
           dev, addr, freq, bw);

    /* --- identify --- */
    uint8_t id = 0, rev = 0, v = 0;
    if (rd(0xfc, &id) || rd(0xfa, &rev) || rd(0xd9, &v)) return 1;
    printf("CHIP_ID=0x%02x TOP_REV=0x%02x VER=0x%02x %s\n", id, rev, v,
           (id == 0x61) ? "(MxL101SF OK)" : "(UNEXPECTED!)");
    if (id != 0x61) return 1;

    /* --- init, stock MxL101SF_Init order: soft reset (+defaults), xtal
     * settings, top master off, SOC mode, top master on --- */
    if (wr(0xff, 0x00) || wr(0x02, 0x01)) return 1;    /* MxL_PhySoftReset */
    usleep(50000);
    if (program(mxl_overwrite_default)) return 1;
    if (wr(0x09, clkout ? 0x01 : 0x00)) return 1;      /* RF loop-through */
    if (program(mxl_xtal_settings)) return 1;
    {   /* xtal clock output toward the second chip (master only) */
        const struct reg_ctrl c[] = {
            {0x06, 0x20, clkout ? 0x20 : 0x00}, {0, 0, 0}
        };
        if (program(c)) return 1;
    }
    if (wr(0x01, 0x00)) return 1;                      /* top master off */
    if (program(mxl_tuner_demod_mode)) return 1;
    if (wr(0x01, 0x01)) return 1;                      /* top master on */
    usleep(100000);

    /* --- tune --- */
    uint8_t mode = 0;
    if (wr(0x1c, 0x00)) return 1;                      /* stop tune */
    rd(0x03, &mode);
    if (program(bw == 6 ? mxl_spur_6mhz :
                bw == 7 ? mxl_spur_7mhz : mxl_spur_8mhz)) return 1;
    uint8_t filt_bw = (bw == 6) ? 21 : (bw == 7) ? 42 : 63;
    uint32_t f64 = (freq / 1000000) * 64;
    {
        const struct reg_ctrl t[] = {                  /* MxL_PhyTuneRF */
            {0x1d, 0x7f, filt_bw},
            {0x1e, 0xff, (uint8_t)(f64 & 0xff)},
            {0x1f, 0xff, (uint8_t)((f64 >> 8) & 0xff)},
            {0, 0, 0}
        };
        if (program(t)) return 1;
    }
    if (wr(0x1c, 0x01)) return 1;                      /* start tune */
    usleep(100000);
    wr(0x0e, 0xff);                                    /* MxL_IrqClear */
    printf("programmed: mode=0x%02x filt_bw=%u f64=0x%04x\n",
           mode, filt_bw, f64);

    if (tson) {   /* stock MxL_MpegTsON: reg 0x17 bits[7:6] = 11 (01 = off) */
        const struct reg_ctrl c[] = { {0x17, 0xc0, 0xc0}, {0, 0, 0} };
        if (program(c)) return 1;
        uint8_t r17 = 0;
        rd(0x17, &r17);
        printf("MPEG TS output ON (reg 0x17 = 0x%02x)\n", r17);
    }

    /* --- scan mode: sweep UHF channels 21..48, report energy + locks --- */
    if (scan) {
        printf("\nscanning UHF E21..E48 (474..690 MHz)...\n");
        int hits = 0;
        for (int ch = 21; ch <= 48; ch++) {
            uint32_t f = (474 + 8 * (ch - 21)) * 1000000u;
            uint32_t v64 = (f / 1000000) * 64;
            wr(0x1c, 0x00);
            const struct reg_ctrl t[] = {
                {0x1d, 0x7f, 63},
                {0x1e, 0xff, (uint8_t)(v64 & 0xff)},
                {0x1f, 0xff, (uint8_t)((v64 >> 8) & 0xff)},
                {0, 0, 0}
            };
            program(t);
            wr(0x1c, 0x01);
            wr(0x0e, 0xff);
            int sync = 0, tps = 0;
            uint32_t pwr = 0;
            for (int w = 0; w < 12; w++) {       /* up to 1.2 s per channel */
                usleep(100000);
                uint8_t r28 = 0, r2a = 0, pl = 0, pm = 0;
                rd(0x28, &r28); rd(0x2a, &r2a);
                wr(0x00, 0x02); rd(0x46, &pl); rd(0x47, &pm); wr(0x00, 0x00);
                pwr = pl | ((pm & 0x07) << 8);
                sync |= !!(r28 & 0x10);
                tps  |= !!(r2a & 0x40);
                if (sync && tps) break;
            }
            printf("  E%02d %3u MHz: rfpwr=%-4u %s%s\n", ch, f / 1000000,
                   pwr, tps ? "TPS " : "", sync ? "SYNC/LOCK!" : "");
            if (sync || tps) hits++;
        }
        printf("%d channel(s) with DVB-T activity.\n", hits);
        return hits ? 0 : 2;
    }

    /* --- poll status --- */
    for (int i = 0; i < secs; i++) {
        uint8_t rf = 0, r28 = 0, r2a = 0, r24 = 0, snr_l = 0, snr_m = 0;
        uint8_t pw_l = 0, pw_m = 0;
        rd(0x23, &rf);
        rd(0x28, &r28); rd(0x2a, &r2a); rd(0x24, &r24);
        rd(0x27, &snr_l); rd(0x28, &snr_m);
        wr(0x00, 0x02);                 /* page 2: RF power readback */
        rd(0x46, &pw_l); rd(0x47, &pw_m);
        wr(0x00, 0x00);
        printf("[%2d] synth:%s%s  demod: rs=%d sync=%d tps=%d fec=%d  "
               "snr=%u  rfpwr=%u\n", i,
               ((rf & 0x03) == 0x03) ? " REF" : "",
               ((rf & 0x0c) == 0x0c) ? " RF" : "",
               !!(r28 & 0x08), !!(r28 & 0x10),
               !!(r2a & 0x40), !!(r24 & 0x10),
               (unsigned)(snr_l | ((snr_m & 0x03) << 8)),
               (unsigned)(pw_l | ((pw_m & 0x07) << 8)));
        sleep(1);
    }
    return 0;
}
