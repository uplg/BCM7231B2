/*
 * init_test.c — Diagnostic init for BCM7231 console debugging
 *
 * This replaces /sbin/init temporarily to determine WHERE output goes.
 * It tests 3 output paths:
 *   1. fd 1 (stdout inherited from kernel)
 *   2. /dev/console (what BusyBox init normally opens)
 *   3. /dev/ttyS0 (direct UART, bypasses console layer)
 *
 * Build: static MIPS32 R1, musl
 * Usage: bootargs "init=/sbin/init_test"
 *
 * After diagnostics, it exec's /sbin/init so the system can continue
 * (or loops forever if exec fails).
 */

#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <string.h>

/* We can't use printf (no stdio buffering guarantees as PID 1).
 * Use raw write() syscalls only. */

static void w(int fd, const char *s)
{
    write(fd, s, strlen(s));
}

int main(void)
{
    int fd;

    /* === TEST 1: Write to inherited stdout (fd 1) === */
    w(1, "\n[init_test] TEST1: writing to fd 1 (inherited stdout)\n");

    /* === TEST 2: Write to inherited stderr (fd 2) === */
    w(2, "[init_test] TEST2: writing to fd 2 (inherited stderr)\n");

    /* Mount devtmpfs so we have device nodes.
     * The kernel may have already auto-mounted it (DEVTMPFS_MOUNT=y),
     * but mount() will just return EBUSY if so — harmless. */
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    /* === TEST 3: Open and write to /dev/console === */
    fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd >= 0) {
        w(fd, "[init_test] TEST3: writing to /dev/console (fd=");
        /* Quick int-to-char for fd number */
        char c = '0' + (fd % 10);
        write(fd, &c, 1);
        w(fd, ")\n");
        close(fd);
    } else {
        w(2, "[init_test] TEST3: FAILED to open /dev/console\n");
    }

    /* === TEST 4: Open and write to /dev/ttyS0 directly === */
    fd = open("/dev/ttyS0", O_WRONLY | O_NOCTTY);
    if (fd >= 0) {
        w(fd, "[init_test] TEST4: writing to /dev/ttyS0 (fd=");
        char c = '0' + (fd % 10);
        write(fd, &c, 1);
        w(fd, ")\n");
        close(fd);
    } else {
        w(2, "[init_test] TEST4: FAILED to open /dev/ttyS0\n");
    }

    /* === TEST 5: Try /dev/ttyS0 with O_RDWR, set as controlling tty === */
    fd = open("/dev/ttyS0", O_RDWR);
    if (fd >= 0) {
        w(fd, "[init_test] TEST5: /dev/ttyS0 O_RDWR works (fd=");
        char c = '0' + (fd % 10);
        write(fd, &c, 1);
        w(fd, ")\n");

        /* Try to make it our controlling terminal */
        ioctl(fd, 0x540E /* TIOCSCTTY */, 1);

        /* Redirect stdin/stdout/stderr to this fd */
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2)
            close(fd);

        w(1, "[init_test] TEST6: stdout now redirected to /dev/ttyS0\n");
    } else {
        w(2, "[init_test] TEST5: FAILED to open /dev/ttyS0 O_RDWR\n");
    }

    /* === Mount proc so we can inspect === */
    mkdir("/proc", 0755);
    mount("proc", "/proc", "proc", 0, NULL);

    /* === Dump /proc/consoles to serial === */
    fd = open("/proc/consoles", O_RDONLY);
    if (fd >= 0) {
        char buf[512];
        int n;
        w(1, "[init_test] /proc/consoles:\n");
        while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
            buf[n] = 0;
            w(1, buf);
        }
        close(fd);
    } else {
        w(1, "[init_test] could not read /proc/consoles\n");
    }

    /* === Dump /proc/cmdline === */
    fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) {
        char buf[256];
        int n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            w(1, "[init_test] /proc/cmdline: ");
            w(1, buf);
        }
        close(fd);
    }

    /* === List /dev/console and /dev/ttyS0 === */
    struct stat st;
    w(1, "[init_test] checking /dev/console: ");
    if (stat("/dev/console", &st) == 0) {
        w(1, "exists, major=");
        char m = '0' + ((st.st_rdev >> 8) & 0xff);
        write(1, &m, 1);
        w(1, " minor=");
        /* minor can be >9, print tens+units */
        char tens = '0' + ((st.st_rdev & 0xff) / 10);
        char units = '0' + ((st.st_rdev & 0xff) % 10);
        write(1, &tens, 1);
        write(1, &units, 1);
        w(1, "\n");
    } else {
        w(1, "DOES NOT EXIST\n");
    }

    w(1, "[init_test] checking /dev/ttyS0: ");
    if (stat("/dev/ttyS0", &st) == 0) {
        w(1, "exists, major=");
        char m = '0' + ((st.st_rdev >> 8) & 0xff);
        write(1, &m, 1);
        w(1, " minor=");
        char tens = '0' + ((st.st_rdev & 0xff) / 10);
        char units = '0' + ((st.st_rdev & 0xff) % 10);
        write(1, &tens, 1);
        write(1, &units, 1);
        w(1, "\n");
    } else {
        w(1, "DOES NOT EXIST\n");
    }

    w(1, "\n[init_test] === DIAGNOSTICS COMPLETE ===\n");
    w(1, "[init_test] Now exec'ing /sbin/init...\n\n");

    /* Try to hand off to real init */
    char *argv[] = { "/sbin/init", NULL };
    char *envp[] = { "HOME=/", "TERM=linux", "PATH=/sbin:/bin:/usr/sbin:/usr/bin", NULL };
    execve("/sbin/init", argv, envp);

    /* If exec failed, say so and loop forever (PID 1 must not exit) */
    w(1, "[init_test] FAILED to exec /sbin/init!\n");

    /* Infinite loop — PID 1 cannot exit */
    for (;;)
        sleep(60);

    return 0;
}
