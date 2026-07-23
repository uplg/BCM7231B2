/*
 * tunerd.c — the AIR 7310T as a network tuner appliance for Iris.
 *
 * Tiny HTTP daemon over the standard Linux-DVB API (bcm7231-dvb driver):
 *
 *   GET /status                     adapters' lock/SNR/freq/clients as JSON
 *   GET /channels                   the box's channel grid (names, freqs,
 *                                   pids — the mux-survey JSON, served
 *                                   verbatim from CHANNELS_PATH so Iris
 *                                   discovers everything; re-survey =
 *                                   update one file here)
 *   GET /tune?a=0&f=506000000&pids=0x64,0x78,0x82[&w=8]
 *                                   stream raw MPEG-TS of that mux subset
 *                                   until the client hangs up
 *
 * v2 — SHARED tuners, MANY clients (the "deux personnes sur M6 + une sur
 * RMC" requirement):
 *   - The parent owns every frontend/demux/dvr fd and runs one poll()
 *     loop; no fork-per-client. A tuned adapter stays tuned (and its DVR
 *     drained) even with zero clients — zap-backs are instant.
 *   - N clients per adapter share ONE dvr stream (fan-out). PID filters
 *     are the UNION of what clients asked; consumers pick their service
 *     by PID (Iris maps ffmpeg by PID).
 *   - Adapter allocation ignores the `a` hint when it can do better:
 *     an adapter already tuned to the requested frequency is JOINED,
 *     otherwise a client-less adapter is (re)tuned, and only as a last
 *     resort are the clients of the least-loaded adapter evicted.
 *   - A slow client never stalls the mux: sends are non-blocking and a
 *     lagging socket just drops chunks (its decoder conceals).
 *
 * No TLS, no auth: this binds inside the home LAN / tailnet only —
 * transport security is the tunnel's job.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <linux/dvb/frontend.h>
#include <linux/dvb/dmx.h>

#define MAX_ADAPTERS 2
#define MAX_PIDS     32
#define MAX_CLIENTS  8      /* per adapter */
#define LOCK_WAIT_MS 6000
#define DVR_RING     (16 * 1024 * 1024)
/* Channel grid (JSON) served by /channels — lives in the persistent
 * /config overlay so it survives reboots and reflashes. */
#define CHANNELS_PATH "/config/tnt_channels.json"

struct adapter {
    uint32_t freq;                 /* 0 = never tuned */
    int fe;                        /* held open to keep the tune; -1 idle */
    int dvr;                       /* -1 until first tune */
    int filters[MAX_PIDS];
    uint16_t fpids[MAX_PIDS];
    int nfilters;
    int clients[MAX_CLIENTS];
    int nclients;
    unsigned long drops;           /* chunks dropped on slow clients */
    unsigned long overflows;       /* kernel DVR ring overflows */
};

static struct adapter adapters[MAX_ADAPTERS];

static long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int http_error(int c, int code, const char *msg)
{
    char b[256];
    int n = snprintf(b, sizeof b,
                     "HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\n"
                     "Connection: close\r\n\r\n%s\n", code, msg, msg);
    send(c, b, (size_t)n, MSG_NOSIGNAL);
    return -1;
}

/* ------------------------------- /status -------------------------------- */

static void do_status(int c)
{
    char body[768], out[1024];
    int len = 0;

    len += snprintf(body + len, sizeof body - (size_t)len, "{\"adapters\":[");
    for (int a = 0; a < MAX_ADAPTERS; a++) {
        char path[64];
        fe_status_t st = 0;
        uint16_t snr = 0;
        struct adapter *ad = &adapters[a];

        if (ad->fe >= 0) {
            ioctl(ad->fe, FE_READ_STATUS, &st);
            ioctl(ad->fe, FE_READ_SNR, &snr);
        } else {
            int fe;
            snprintf(path, sizeof path, "/dev/dvb/adapter%d/frontend0", a);
            fe = open(path, O_RDONLY | O_NONBLOCK);
            if (fe >= 0) {
                ioctl(fe, FE_READ_STATUS, &st);
                ioctl(fe, FE_READ_SNR, &snr);
                close(fe);
            }
        }
        len += snprintf(body + len, sizeof body - (size_t)len,
                        "%s{\"adapter\":%d,\"clients\":%d,\"freq\":%u,"
                        "\"lock\":%s,\"snr_db\":%u.%u,\"drops\":%lu}",
                        a ? "," : "", a, ad->nclients, ad->freq,
                        (st & FE_HAS_LOCK) ? "true" : "false",
                        snr / 10, snr % 10, ad->drops);
    }
    len += snprintf(body + len, sizeof body - (size_t)len, "]}");

    int n = snprintf(out, sizeof out,
                     "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                     "Connection: close\r\n\r\n%s\n", body);
    send(c, out, (size_t)n, MSG_NOSIGNAL);
}

/* ------------------------------ /channels ------------------------------- */

static void do_channels(int c)
{
    char hdr[128];
    static char body[65536];
    int f = open(CHANNELS_PATH, O_RDONLY);
    ssize_t n = f >= 0 ? read(f, body, sizeof body) : -1;

    if (f >= 0)
        close(f);
    if (n <= 0) {
        http_error(c, 404, "no channel grid (missing " CHANNELS_PATH ")");
        return;
    }
    int h = snprintf(hdr, sizeof hdr,
                     "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                     "Content-Length: %zd\r\nConnection: close\r\n\r\n", n);
    send(c, hdr, (size_t)h, MSG_NOSIGNAL);
    send(c, body, (size_t)n, MSG_NOSIGNAL);
}

/* ------------------------------ query utils ----------------------------- */

static int q_u32(const char *q, const char *key, uint32_t *out)
{
    const char *p = q;
    size_t kl = strlen(key);

    while ((p = strstr(p, key))) {
        if ((p == q || p[-1] == '&' || p[-1] == '?') && p[kl] == '=') {
            *out = strtoul(p + kl + 1, NULL, 0);
            return 0;
        }
        p += kl;
    }
    return -1;
}

static int q_pids(const char *q, uint16_t *pids)
{
    const char *p = strstr(q, "pids=");
    int n = 0;

    if (!p)
        return 0;
    p += 5;
    while (n < MAX_PIDS) {
        pids[n++] = (uint16_t)strtoul(p, (char **)&p, 0);
        if (*p != ',')
            break;
        p++;
    }
    return n;
}

/* ---------------------------- adapter control --------------------------- */

static void adapter_close_filters(struct adapter *ad)
{
    for (int i = 0; i < ad->nfilters; i++)
        close(ad->filters[i]);
    ad->nfilters = 0;
}

static int adapter_add_filter(int a, struct adapter *ad, uint16_t pid)
{
    char path[64];

    for (int i = 0; i < ad->nfilters; i++)
        if (ad->fpids[i] == pid)
            return 0;
    if (ad->nfilters >= MAX_PIDS)
        return -1;

    snprintf(path, sizeof path, "/dev/dvb/adapter%d/demux0", a);
    int d = open(path, O_RDWR);
    struct dmx_pes_filter_params f = {
        .pid = pid,
        .input = DMX_IN_FRONTEND,
        .output = DMX_OUT_TS_TAP,
        .pes_type = DMX_PES_OTHER,
        .flags = DMX_IMMEDIATE_START,
    };
    if (d < 0 || ioctl(d, DMX_SET_PES_FILTER, &f) < 0) {
        if (d >= 0)
            close(d);
        return -1;
    }
    ad->filters[ad->nfilters] = d;
    ad->fpids[ad->nfilters] = pid;
    ad->nfilters++;
    return 0;
}

/* Tune (or join) adapter `a` to `freq`. Returns 0 on lock. Blocks the
 * loop for up to LOCK_WAIT_MS on a real retune — the other adapter's
 * 16 MiB DVR ring absorbs several seconds, so concurrent viewers ride
 * it out. */
static int adapter_tune(int a, struct adapter *ad, uint32_t freq, uint32_t bw_mhz)
{
    char path[64];
    fe_status_t st = 0;
    long t0 = now_ms();

    if (ad->fe < 0) {
        snprintf(path, sizeof path, "/dev/dvb/adapter%d/frontend0", a);
        ad->fe = open(path, O_RDWR);
        if (ad->fe < 0)
            return -1;
    }
    if (ad->freq == freq && ioctl(ad->fe, FE_READ_STATUS, &st) == 0 &&
        (st & FE_HAS_LOCK)) {
        fprintf(stderr, "tunerd: a%d f=%u lock reused (no retune)\n", a, freq);
        return 0;
    }

    struct dtv_property props[] = {
        { .cmd = DTV_DELIVERY_SYSTEM, .u.data = SYS_DVBT },
        { .cmd = DTV_FREQUENCY,       .u.data = freq },
        { .cmd = DTV_BANDWIDTH_HZ,    .u.data = bw_mhz * 1000000 },
        { .cmd = DTV_TUNE },
    };
    struct dtv_properties cmds = { .num = 4, .props = props };

    /* New frequency: the old mux's filters are meaningless now. */
    adapter_close_filters(ad);
    st = 0;
    if (ioctl(ad->fe, FE_SET_PROPERTY, &cmds) < 0)
        return -1;
    for (int i = 0; i < LOCK_WAIT_MS / 100; i++) {
        usleep(100000);
        if (ioctl(ad->fe, FE_READ_STATUS, &st) == 0 && (st & FE_HAS_LOCK))
            break;
    }
    if (!(st & FE_HAS_LOCK))
        return -1;
    ad->freq = freq;
    fprintf(stderr, "tunerd: a%d f=%u locked in %ld ms\n", a, freq, now_ms() - t0);

    if (ad->dvr < 0) {
        snprintf(path, sizeof path, "/dev/dvb/adapter%d/dvr0", a);
        ad->dvr = open(path, O_RDONLY | O_NONBLOCK);
        if (ad->dvr < 0)
            return -1;
        /* Default DVR ring is ~190 KB (≈200 ms of a mux) — any hiccup
         * would DROP TS silently. 16 MiB rides out retunes of the other
         * adapter and slow moments. Best-effort. */
        if (ioctl(ad->dvr, DMX_SET_BUFFER_SIZE,
                  (unsigned long)DVR_RING) < 0)
            fprintf(stderr, "tunerd: a%d DMX_SET_BUFFER_SIZE failed (%d)\n",
                    a, errno);
    }
    return 0;
}

static void client_drop(struct adapter *ad, int idx)
{
    close(ad->clients[idx]);
    ad->clients[idx] = ad->clients[ad->nclients - 1];
    ad->nclients--;
}

static void adapter_evict_all(struct adapter *ad)
{
    while (ad->nclients > 0)
        client_drop(ad, 0);
}

/* -------------------------------- /tune --------------------------------- */

static void do_tune(int c, const char *query)
{
    uint32_t a_hint = 0, freq = 0, bw = 8;
    uint16_t pids[MAX_PIDS];
    int npids;

    q_u32(query, "a", &a_hint);
    q_u32(query, "w", &bw);
    if (q_u32(query, "f", &freq) || freq < 100000000 || freq > 900000000) {
        http_error(c, 400, "need f=<hz> pids=<p,p,...>");
        close(c);
        return;
    }
    npids = q_pids(query, pids);
    if (npids <= 0) {
        http_error(c, 400, "need pids=");
        close(c);
        return;
    }

    /* Adapter pick: (1) already on this frequency, (2) client-less,
     * (3) evict the least-loaded. The `a` hint only breaks ties. */
    int pick = -1;
    for (int a = 0; a < MAX_ADAPTERS; a++)
        if (adapters[a].freq == freq && adapters[a].fe >= 0) {
            pick = a;
            break;
        }
    if (pick < 0)
        for (int a = 0; a < MAX_ADAPTERS; a++)
            if (adapters[a].nclients == 0) {
                pick = a;
                break;
            }
    if (pick < 0) {
        pick = (int)(a_hint < MAX_ADAPTERS ? a_hint : 0);
        for (int a = 0; a < MAX_ADAPTERS; a++)
            if (adapters[a].nclients < adapters[pick].nclients)
                pick = a;
        fprintf(stderr, "tunerd: a%d evicting %d client(s) for f=%u\n",
                pick, adapters[pick].nclients, freq);
        adapter_evict_all(&adapters[pick]);
    }

    struct adapter *ad = &adapters[pick];
    if (ad->nclients >= MAX_CLIENTS) {
        http_error(c, 503, "adapter full");
        close(c);
        return;
    }
    if (adapter_tune(pick, ad, freq, bw) < 0) {
        http_error(c, 504, "no lock");
        close(c);
        return;
    }
    for (int i = 0; i < npids; i++)
        adapter_add_filter(pick, ad, pids[i]);

    static const char hdr[] =
        "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
        "Connection: close\r\n\r\n";
    if (send(c, hdr, sizeof hdr - 1, MSG_NOSIGNAL) < 0) {
        close(c);
        return;
    }
    fcntl(c, F_SETFL, O_NONBLOCK);
    ad->clients[ad->nclients++] = c;
    fprintf(stderr, "tunerd: a%d f=%u client joined (%d total, %d filters)\n",
            pick, freq, ad->nclients, ad->nfilters);
}

/* --------------------------------- main ---------------------------------- */

static void pump_adapter(struct adapter *ad)
{
    static uint8_t buf[65536];

    for (;;) {
        ssize_t r = read(ad->dvr, buf, sizeof buf);
        if (r < 0) {
            if (errno == EOVERFLOW) {
                ad->overflows++;
                fprintf(stderr, "tunerd: DVR overflow #%lu (TS loss)\n",
                        ad->overflows);
                continue;
            }
            return; /* EAGAIN or real error: back to poll() */
        }
        if (r == 0)
            return;
        for (int i = 0; i < ad->nclients; ) {
            ssize_t w = send(ad->clients[i], buf, (size_t)r, MSG_NOSIGNAL);
            if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                /* Slow client: drop this chunk for them only. */
                ad->drops++;
                i++;
            } else if (w < 0) {
                client_drop(ad, i); /* gone — do not advance i */
            } else {
                i++; /* short writes: rare on 64 KB; remainder dropped */
            }
        }
    }
}

int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 8554;
    struct sockaddr_in sa = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    int one = 1;

    signal(SIGPIPE, SIG_IGN);
    for (int a = 0; a < MAX_ADAPTERS; a++) {
        adapters[a].fe = -1;
        adapters[a].dvr = -1;
    }

    int s = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(s, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(s, 16) < 0) {
        perror("bind/listen");
        return 1;
    }
    fprintf(stderr, "tunerd: v2 (shared tuners) listening on :%d\n", port);

    for (;;) {
        struct pollfd pfd[1 + MAX_ADAPTERS + MAX_ADAPTERS * MAX_CLIENTS];
        int n = 0;

        pfd[n].fd = s;
        pfd[n].events = POLLIN;
        n++;
        for (int a = 0; a < MAX_ADAPTERS; a++) {
            if (adapters[a].dvr >= 0) {
                pfd[n].fd = adapters[a].dvr;
                pfd[n].events = POLLIN;
                n++;
            }
            /* Watch clients for hangup (they never send data). */
            for (int i = 0; i < adapters[a].nclients; i++) {
                pfd[n].fd = adapters[a].clients[i];
                pfd[n].events = POLLIN;
                n++;
            }
        }

        if (poll(pfd, (nfds_t)n, 1000) < 0)
            continue;

        int k = 0;
        if (pfd[k].revents & POLLIN) {
            int c = accept(s, NULL, NULL);
            if (c >= 0) {
                char req[2048];
                size_t got = 0;

                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                /* Read until the header terminator: clients like ffmpeg
                 * send request line and headers in SEPARATE packets. */
                struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
                while (got < sizeof req - 1) {
                    ssize_t r = recv(c, req + got, sizeof req - 1 - got, 0);
                    if (r <= 0)
                        break;
                    got += (size_t)r;
                    req[got] = 0;
                    if (strstr(req, "\r\n\r\n"))
                        break;
                }
                if (got == 0) {
                    close(c);
                } else {
                    req[got] = 0;
                    char *sp = strchr(req, ' ');
                    char *path = sp ? sp + 1 : NULL;
                    char *end = path ? strchr(path, ' ') : NULL;
                    if (end)
                        *end = 0;

                    if (path && !strncmp(path, "/status", 7)) {
                        do_status(c);
                        close(c);
                    } else if (path && !strncmp(path, "/channels", 9)) {
                        do_channels(c);
                        close(c);
                    } else if (path && !strncmp(path, "/tune?", 6)) {
                        do_tune(c, path + 5); /* keeps or closes c itself */
                    } else {
                        if (path)
                            http_error(c, 404,
                                       "try /status, /channels or /tune");
                        close(c);
                    }
                }
            }
        }
        k++;
        for (int a = 0; a < MAX_ADAPTERS; a++) {
            struct adapter *ad = &adapters[a];
            if (ad->dvr >= 0) {
                if (pfd[k].revents & POLLIN)
                    pump_adapter(ad);
                k++;
            }
            /* Hangup sweep — any readable/HUP client is done (HTTP GET
             * clients never legitimately send more data). */
            for (int i = 0; i < ad->nclients && k < n; k++) {
                if (pfd[k].revents & (POLLIN | POLLHUP | POLLERR)) {
                    client_drop(ad, i);
                    /* client list shuffled: stop matching pfd entries to
                     * indices this round; the next poll() rebuilds. */
                    break;
                }
                i++;
            }
        }
    }
}
