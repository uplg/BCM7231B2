/*
 * dvbzap.c — minimal Linux-DVB API client for the AIR 7310T bring-up:
 * tune a DVB-T mux on /dev/dvb/adapterN/frontend0, open one hardware PID
 * filter per requested PID on demux0 (DMX_OUT_TS_TAP), then pump dvr0 to
 * stdout or to 1316-byte UDP/TS datagrams (VLC udp://@:port).
 *
 * This is the standard-API mirror of the xpt_cap/mxl_probe raw chain —
 * if this works, any DVB software (dvblast, tvheadend, w_scan) will.
 *
 *   dvbzap -a 0 -f 618000000 -p 0x00,0x11,0x6e,0x78,0x82 --udp 192.168.2.2:1234
 *   dvbzap -a 0 -f 618000000 -p all > mux.ts      (all-pass, ~6% loss ok)
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
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/dvb/frontend.h>
#include <linux/dvb/dmx.h>

#define MAX_PIDS 32
#define UDP_CHUNK 1316

static volatile sig_atomic_t g_stop;
static void on_sig(int sig) { (void)sig; g_stop = 1; }

static int udp_fd = -1;
static uint8_t udp_acc[UDP_CHUNK];
static size_t udp_len;

static void udp_open(const char *hostport)
{
    char host[64];
    const char *colon = strrchr(hostport, ':');
    struct sockaddr_in sa;

    if (!colon || (size_t)(colon - hostport) >= sizeof host) {
        fprintf(stderr, "--udp wants host:port\n");
        exit(1);
    }
    memcpy(host, hostport, (size_t)(colon - hostport));
    host[colon - hostport] = 0;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)strtoul(colon + 1, NULL, 10));
    if (!inet_aton(host, &sa.sin_addr)) {
        fprintf(stderr, "bad IPv4 '%s'\n", host);
        exit(1);
    }
    udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_fd < 0 || connect(udp_fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        perror("udp");
        exit(1);
    }
    fprintf(stderr, "UDP/TS -> %s (VLC: udp://@:%u)\n", hostport,
            ntohs(sa.sin_port));
}

static int out_write(const uint8_t *p, size_t n)
{
    if (udp_fd < 0) {
        while (n) {
            ssize_t w = write(STDOUT_FILENO, p, n);
            if (w < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            p += w; n -= (size_t)w;
        }
        return 0;
    }
    while (n) {
        size_t take = UDP_CHUNK - udp_len;
        if (take > n) take = n;
        memcpy(udp_acc + udp_len, p, take);
        udp_len += take; p += take; n -= take;
        if (udp_len == UDP_CHUNK) {
            if (send(udp_fd, udp_acc, UDP_CHUNK, 0) < 0 &&
                errno != ECONNREFUSED && errno != ENOBUFS &&
                errno != EAGAIN && errno != EINTR)
                return -1;
            udp_len = 0;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    int adapter = 0, opt, npids = 0, allpass = 0;
    uint32_t freq = 618000000, bw = 8000000;
    uint16_t pids[MAX_PIDS];
    const char *udp = NULL;
    char path[64];
    static const struct option lo[] = {
        { "udp", 1, 0, 'u' }, { 0, 0, 0, 0 }
    };

    int snrwatch = 0;

    while ((opt = getopt_long(argc, argv, "a:f:w:p:u:S", lo, NULL)) != -1) {
        switch (opt) {
        case 'S': snrwatch = 1; break;
        case 'a': adapter = atoi(optarg); break;
        case 'f': freq = strtoul(optarg, NULL, 0); break;
        case 'w': bw = strtoul(optarg, NULL, 0) * 1000000; break;
        case 'u': udp = optarg; break;
        case 'p': {
            char *s = optarg, *tok;
            if (!strcmp(s, "all")) { allpass = 1; break; }
            while ((tok = strsep(&s, ",")) && npids < MAX_PIDS)
                pids[npids++] = (uint16_t)strtoul(tok, NULL, 0);
            break;
        }
        default:
            fprintf(stderr, "usage: %s [-a N] [-f hz] [-w mhz] "
                    "-p pid,pid,...|all [--udp ip:port]\n", argv[0]);
            return 1;
        }
    }

    /* --- -S: read-only SNR/status watch alongside a running stream ---
     * (read_snr touches only page-0 regs in the driver, so polling here
     * does not disturb the RW owner; do NOT poll signal strength — it
     * page-switches and can corrupt a concurrent tune) */
    if (snrwatch) {
        snprintf(path, sizeof path, "/dev/dvb/adapter%d/frontend0", adapter);
        int fs = open(path, O_RDONLY | O_NONBLOCK);
        if (fs < 0) { perror(path); return 1; }
        setvbuf(stdout, NULL, _IOLBF, 0);
        for (;;) {
            fe_status_t st = 0;
            uint16_t snr = 0;
            ioctl(fs, FE_READ_STATUS, &st);
            ioctl(fs, FE_READ_SNR, &snr);
            printf("status=0x%02x%s snr=%u.%u dB\n", st,
                   (st & FE_HAS_LOCK) ? " LOCK" : " ----",
                   snr / 10, snr % 10);
            sleep(1);
        }
    }

    /* --- frontend: tune --- */
    snprintf(path, sizeof path, "/dev/dvb/adapter%d/frontend0", adapter);
    int fe = open(path, O_RDWR);
    if (fe < 0) { perror(path); return 1; }

    struct dtv_property props[] = {
        { .cmd = DTV_DELIVERY_SYSTEM, .u.data = SYS_DVBT },
        { .cmd = DTV_FREQUENCY,       .u.data = freq },
        { .cmd = DTV_BANDWIDTH_HZ,    .u.data = bw },
        { .cmd = DTV_TUNE },
    };
    struct dtv_properties cmds = { .num = 4, .props = props };
    if (ioctl(fe, FE_SET_PROPERTY, &cmds) < 0) {
        perror("FE_SET_PROPERTY");
        return 1;
    }
    fprintf(stderr, "tuning adapter%d to %u Hz (bw %u)...\n",
            adapter, freq, bw);

    fe_status_t st = 0;
    for (int i = 0; i < 50; i++) {          /* up to 5 s */
        usleep(100000);
        if (ioctl(fe, FE_READ_STATUS, &st) < 0) { perror("FE_READ_STATUS"); return 1; }
        if (st & FE_HAS_LOCK) break;
    }
    fprintf(stderr, "status: 0x%02x %s\n", st,
            (st & FE_HAS_LOCK) ? "LOCK" : "NO LOCK");
    if (!(st & FE_HAS_LOCK))
        return 2;

    /* --- demux: one TS_TAP filter per PID --- */
    int dmx[MAX_PIDS + 1], ndmx = 0;
    snprintf(path, sizeof path, "/dev/dvb/adapter%d/demux0", adapter);
    if (allpass) { pids[0] = 0x2000; npids = 1; }
    for (int i = 0; i < npids; i++) {
        int d = open(path, O_RDWR);
        if (d < 0) { perror(path); return 1; }
        struct dmx_pes_filter_params f = {
            .pid = pids[i],
            .input = DMX_IN_FRONTEND,
            .output = DMX_OUT_TS_TAP,
            .pes_type = DMX_PES_OTHER,
            .flags = DMX_IMMEDIATE_START,
        };
        if (ioctl(d, DMX_SET_PES_FILTER, &f) < 0) {
            perror("DMX_SET_PES_FILTER");
            return 1;
        }
        dmx[ndmx++] = d;
        fprintf(stderr, "  filter pid 0x%04x\n", pids[i]);
    }

    /* --- dvr: pump --- */
    snprintf(path, sizeof path, "/dev/dvb/adapter%d/dvr0", adapter);
    int dvr = open(path, O_RDONLY);
    if (dvr < 0) { perror(path); return 1; }
    if (udp)
        udp_open(udp);
    /* sigaction WITHOUT SA_RESTART: musl's signal() sets SA_RESTART and
     * the blocking dvr read then never returns EINTR — TERM would never
     * break the loop and the zombie keeps the frontend busy. */
    {
        struct sigaction sa = { .sa_handler = on_sig };
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
        signal(SIGPIPE, SIG_IGN);
    }

    uint64_t total = 0;
    time_t last = time(NULL);
    static uint8_t buf[65536];
    while (!g_stop) {
        ssize_t r = read(dvr, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR) continue;   /* g_stop re-checked above */
            if (errno == EOVERFLOW) {
                fprintf(stderr, "dvr overflow (slow reader)\n");
                continue;
            }
            perror("read dvr");
            break;
        }
        if (r == 0) { usleep(2000); continue; }
        total += (uint64_t)r;
        if (out_write(buf, (size_t)r))
            break;
        time_t now = time(NULL);
        if (now - last >= 5) {
            fprintf(stderr, "  %llu bytes\n", (unsigned long long)total);
            last = now;
        }
    }
    fprintf(stderr, "done: %llu bytes\n", (unsigned long long)total);
    return 0;
}
