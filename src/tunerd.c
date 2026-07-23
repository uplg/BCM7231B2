/*
 * tunerd.c — the AIR 7310T as a network tuner appliance for Iris.
 *
 * Tiny HTTP daemon over the standard Linux-DVB API (bcm7231-dvb driver):
 *
 *   GET /status                     adapters' lock/SNR/freq as JSON
 *   GET /channels                   the box's channel grid (names, freqs,
 *                                   pids — the mux-survey JSON, served
 *                                   verbatim from CHANNELS_PATH so Iris
 *                                   discovers everything; re-survey =
 *                                   update one file here)
 *   GET /tune?a=0&f=506000000&pids=0x64,0x78,0x82[&w=8]
 *                                   tune adapter a, hw-filter the pids,
 *                                   stream raw MPEG-TS (chunked-less,
 *                                   Connection: close) until the client
 *                                   hangs up
 *
 * One streaming client per adapter; a new /tune on a busy adapter evicts
 * the previous client (Iris is the only consumer and manages itself).
 * Streaming runs in a fork()ed child so the parent stays responsive for
 * /status and the second adapter.  No TLS, no auth: this binds inside the
 * home LAN / tailnet only — transport security is the tunnel's job.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <linux/dvb/frontend.h>
#include <linux/dvb/dmx.h>

#define MAX_ADAPTERS 2
#define MAX_PIDS     32
#define LOCK_WAIT_MS 6000
/* Channel grid (JSON) served by /channels — lives in the persistent
 * /config overlay so it survives reboots and reflashes. */
#define CHANNELS_PATH "/config/tnt_channels.json"

static pid_t stream_child[MAX_ADAPTERS];
static uint32_t last_freq[MAX_ADAPTERS];

static void reap(int sig)
{
    (void)sig;
    pid_t p;
    while ((p = waitpid(-1, NULL, WNOHANG)) > 0) {
        for (int i = 0; i < MAX_ADAPTERS; i++)
            if (stream_child[i] == p)
                stream_child[i] = 0;
    }
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
    char body[512], out[768];
    int len = 0;

    len += snprintf(body + len, sizeof body - (size_t)len, "{\"adapters\":[");
    for (int a = 0; a < MAX_ADAPTERS; a++) {
        char path[64];
        fe_status_t st = 0;
        uint16_t snr = 0;
        int fe;

        snprintf(path, sizeof path, "/dev/dvb/adapter%d/frontend0", a);
        fe = open(path, O_RDONLY | O_NONBLOCK);
        if (fe >= 0) {
            ioctl(fe, FE_READ_STATUS, &st);
            ioctl(fe, FE_READ_SNR, &snr);
            close(fe);
        }
        len += snprintf(body + len, sizeof body - (size_t)len,
                        "%s{\"adapter\":%d,\"streaming\":%s,\"freq\":%u,"
                        "\"lock\":%s,\"snr_db\":%u.%u}",
                        a ? "," : "", a, stream_child[a] ? "true" : "false",
                        last_freq[a],
                        (st & FE_HAS_LOCK) ? "true" : "false",
                        snr / 10, snr % 10);
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

/* -------------------------------- /tune --------------------------------- */

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

/* Child: owns the frontend + filters + dvr for one adapter and pumps TS
 * into the socket until the peer closes (send fails). */
static void stream_child_run(int c, uint32_t adapter, uint32_t freq,
                             uint32_t bw_mhz, const uint16_t *pids, int npids)
{
    char path[64];
    struct dtv_property props[] = {
        { .cmd = DTV_DELIVERY_SYSTEM, .u.data = SYS_DVBT },
        { .cmd = DTV_FREQUENCY,       .u.data = freq },
        { .cmd = DTV_BANDWIDTH_HZ,    .u.data = bw_mhz * 1000000 },
        { .cmd = DTV_TUNE },
    };
    struct dtv_properties cmds = { .num = 4, .props = props };
    fe_status_t st = 0;

    snprintf(path, sizeof path, "/dev/dvb/adapter%u/frontend0", adapter);
    int fe = open(path, O_RDWR);
    if (fe < 0)
        _exit(1);
    if (ioctl(fe, FE_SET_PROPERTY, &cmds) < 0)
        _exit(1);
    for (int i = 0; i < LOCK_WAIT_MS / 100; i++) {
        usleep(100000);
        if (ioctl(fe, FE_READ_STATUS, &st) == 0 && (st & FE_HAS_LOCK))
            break;
    }
    if (!(st & FE_HAS_LOCK)) {
        http_error(c, 504, "no lock");
        _exit(2);
    }

    snprintf(path, sizeof path, "/dev/dvb/adapter%u/demux0", adapter);
    for (int i = 0; i < npids; i++) {
        int d = open(path, O_RDWR);
        struct dmx_pes_filter_params f = {
            .pid = pids[i],
            .input = DMX_IN_FRONTEND,
            .output = DMX_OUT_TS_TAP,
            .pes_type = DMX_PES_OTHER,
            .flags = DMX_IMMEDIATE_START,
        };
        if (d < 0 || ioctl(d, DMX_SET_PES_FILTER, &f) < 0) {
            http_error(c, 500, "demux");
            _exit(3);
        }
        /* fds intentionally kept open until _exit */
    }

    snprintf(path, sizeof path, "/dev/dvb/adapter%u/dvr0", adapter);
    int dvr = open(path, O_RDONLY);
    if (dvr < 0)
        _exit(4);

    {
        static const char hdr[] =
            "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
            "Connection: close\r\n\r\n";
        if (send(c, hdr, sizeof hdr - 1, MSG_NOSIGNAL) < 0)
            _exit(5);
    }

    static uint8_t buf[65536];
    for (;;) {
        ssize_t r = read(dvr, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR || errno == EOVERFLOW)
                continue;
            break;
        }
        if (r == 0) {
            usleep(2000);
            continue;
        }
        const uint8_t *p = buf;
        while (r > 0) {
            ssize_t w = send(c, p, (size_t)r, MSG_NOSIGNAL);
            if (w < 0) {
                if (errno == EINTR)
                    continue;
                _exit(0);       /* client gone: normal end of stream */
            }
            p += w;
            r -= w;
        }
    }
    _exit(0);
}

static void do_tune(int c, const char *query)
{
    uint32_t adapter = 0, freq = 0, bw = 8;
    uint16_t pids[MAX_PIDS];
    int npids;

    q_u32(query, "a", &adapter);
    q_u32(query, "w", &bw);
    if (q_u32(query, "f", &freq) || adapter >= MAX_ADAPTERS ||
        freq < 100000000 || freq > 900000000) {
        http_error(c, 400, "need a=<0|1> f=<hz> pids=<p,p,...>");
        return;
    }
    npids = q_pids(query, pids);
    if (npids <= 0) {
        http_error(c, 400, "need pids=");
        return;
    }

    if (stream_child[adapter]) {            /* evict the previous client */
        kill(stream_child[adapter], SIGKILL);
        waitpid(stream_child[adapter], NULL, 0);
        stream_child[adapter] = 0;
    }

    pid_t p = fork();
    if (p < 0) {
        http_error(c, 500, "fork");
        return;
    }
    if (p == 0)
        stream_child_run(c, adapter, freq, bw, pids, npids);
    stream_child[adapter] = p;
    last_freq[adapter] = freq;
}

/* --------------------------------- main ---------------------------------- */

int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 8554;
    struct sockaddr_in sa = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    int one = 1;

    struct sigaction sc = { .sa_handler = reap, .sa_flags = SA_RESTART };
    sigaction(SIGCHLD, &sc, NULL);
    signal(SIGPIPE, SIG_IGN);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(s, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(s, 8) < 0) {
        perror("bind/listen");
        return 1;
    }
    fprintf(stderr, "tunerd: listening on :%d\n", port);

    for (;;) {
        int c = accept(s, NULL, NULL);
        char req[2048];
        size_t got = 0;

        if (c < 0)
            continue;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        /* Read until the header terminator: clients like ffmpeg send the
         * request line and headers in SEPARATE packets — a single recv()
         * truncates the path and turns every stream open into a 404. */
        {
            struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        }
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
            continue;
        }
        req[got] = 0;

        char *sp = strchr(req, ' ');
        char *path = sp ? sp + 1 : NULL;
        char *end = path ? strchr(path, ' ') : NULL;
        if (end)
            *end = 0;

        if (path && !strncmp(path, "/status", 7))
            do_status(c);
        else if (path && !strncmp(path, "/channels", 9))
            do_channels(c);
        else if (path && !strncmp(path, "/tune?", 6))
            do_tune(c, path + 5);
        else if (path)
            http_error(c, 404, "try /status, /channels or /tune");
        close(c);        /* parent copy; the child owns its own dup */
    }
}
