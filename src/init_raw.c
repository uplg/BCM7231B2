/*
 * init_raw.c — Ultimate diagnostic init.
 * No libc, no CRT. Raw MIPS32 syscalls only.
 *
 * Strategy (layered, from most raw to most civilized):
 *
 * LAYER 0: Write directly to UART TX register via /dev/mem mmap
 *          (bypasses ALL kernel TTY/serial layers)
 * LAYER 1: Write to inherited fd 1 (kernel's /dev/console)
 * LAYER 2: Open /dev/ttyS0 and write
 * LAYER 3: Open /dev/console and write
 * SIGNAL:  Trigger a reboot after 30s delay — if we see the box
 *          reboot, we KNOW the binary executed even if all output failed
 *
 * Build: mipsel-linux-gcc -static -nostdlib -nostartfiles -mips32 -o init_raw init_raw.c
 */

/* MIPS o32 syscall numbers */
#define SYS_exit      4001
#define SYS_read      4003
#define SYS_write     4004
#define SYS_open      4005
#define SYS_close     4006
#define SYS_mmap      4090
#define SYS_munmap    4091
#define SYS_dup       4041
#define SYS_reboot    4088
#define SYS_getpid    4020
#define SYS_sync      4036

/* open flags */
#define O_RDWR        2
#define O_SYNC        0x101000  /* O_SYNC on MIPS */

/* mmap flags */
#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_SHARED    0x1
#define MAP_FAILED    ((void *)-1)

/* reboot magic */
#define LINUX_REBOOT_MAGIC1     0xfee1dead
#define LINUX_REBOOT_MAGIC2     0x28121969
#define LINUX_REBOOT_CMD_RESTART 0x01234567

/*
 * BCM7231 UART0 physical base: 0x10406900
 * Register layout (ns16550, reg-shift=2, reg-io-width=4):
 *   THR (TX) = base + 0*4 = base + 0x00
 *   LSR      = base + 5*4 = base + 0x14
 * LSR bit 5 (THRE) = TX holding register empty
 */
#define UART_PHYS_BASE  0x10406900
#define UART_THR_OFF    0x00    /* TX Holding Register */
#define UART_LSR_OFF    0x14    /* Line Status Register */
#define UART_LSR_THRE   0x20    /* TX Holding Register Empty bit */

/* Page size for mmap */
#define PAGE_SIZE       4096
#define PAGE_MASK       (~(PAGE_SIZE - 1))

/* ============================================================
 * Raw syscall wrappers
 * ============================================================ */

static long __attribute__((noinline)) my_syscall1(long num, long a0)
{
    register long r_v0 __asm__("v0") = num;
    register long r_a0 __asm__("a0") = a0;
    register long r_a3 __asm__("a3");
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "=r"(r_a3)
        : "r"(r_a0)
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    if (r_a3) return -r_v0;
    return r_v0;
}

static long __attribute__((noinline)) my_syscall2(long num, long a0, long a1)
{
    register long r_v0 __asm__("v0") = num;
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a3 __asm__("a3");
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "=r"(r_a3)
        : "r"(r_a0), "r"(r_a1)
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    if (r_a3) return -r_v0;
    return r_v0;
}

static long __attribute__((noinline)) my_syscall3(long num, long a0, long a1, long a2)
{
    register long r_v0 __asm__("v0") = num;
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a2 __asm__("a2") = a2;
    register long r_a3 __asm__("a3");
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "=r"(r_a3)
        : "r"(r_a0), "r"(r_a1), "r"(r_a2)
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    if (r_a3) return -r_v0;
    return r_v0;
}

static long __attribute__((noinline)) my_syscall4(long num, long a0, long a1, long a2, long a3_val)
{
    register long r_v0 __asm__("v0") = num;
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a2 __asm__("a2") = a2;
    register long r_a3 __asm__("a3") = a3_val;
    /* a3 is both input and error flag — need care */
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "+r"(r_a3)
        : "r"(r_a0), "r"(r_a1), "r"(r_a2)
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    if (r_a3) return -r_v0;
    return r_v0;
}

/*
 * MIPS o32 mmap — SYS_mmap (4090) is the old-style mmap.
 * On MIPS o32, SYS_mmap takes a pointer to a struct of 6 args.
 * We need to use mmap2 (SYS_mmap2 = 4210) which takes args directly,
 * with offset in pages.
 */
#define SYS_mmap2 4210

static long __attribute__((noinline)) my_syscall6(long num, long a0, long a1, long a2, long a3_val, long a4, long a5)
{
    register long r_v0 __asm__("v0") = num;
    register long r_a0 __asm__("a0") = a0;
    register long r_a1 __asm__("a1") = a1;
    register long r_a2 __asm__("a2") = a2;
    register long r_a3 __asm__("a3") = a3_val;
    /* a4 and a5 go on stack for MIPS o32 */
    /* We need to put them at sp+16 and sp+20 */
    __asm__ volatile(
        "subu $sp, $sp, 32\n\t"
        "sw %[a4], 16($sp)\n\t"
        "sw %[a5], 20($sp)\n\t"
        "syscall\n\t"
        "addu $sp, $sp, 32"
        : "+r"(r_v0), "+r"(r_a3)
        : "r"(r_a0), "r"(r_a1), "r"(r_a2), [a4] "r"(a4), [a5] "r"(a5)
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    if (r_a3) return -r_v0;
    return r_v0;
}

static long my_write(int fd, const void *buf, long len)
{
    return my_syscall3(SYS_write, fd, (long)buf, len);
}

static long my_open(const char *path, int flags)
{
    return my_syscall2(SYS_open, (long)path, flags);
}

static long my_close(int fd)
{
    return my_syscall1(SYS_close, fd);
}

static long my_dup(int fd)
{
    return my_syscall1(SYS_dup, fd);
}

static long my_getpid(void)
{
    register long r_v0 __asm__("v0") = SYS_getpid;
    register long r_a3 __asm__("a3");
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "=r"(r_a3)
        :
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    return r_v0;
}

static long my_sync(void)
{
    register long r_v0 __asm__("v0") = SYS_sync;
    register long r_a3 __asm__("a3");
    __asm__ volatile(
        "syscall"
        : "+r"(r_v0), "=r"(r_a3)
        :
        : "memory", "at", "v1", "t0", "t1", "t2", "t3",
          "t4", "t5", "t6", "t7", "t8", "t9"
    );
    return r_v0;
}

static void *my_mmap2(void *addr, long length, int prot, int flags, int fd, long pgoffset)
{
    return (void *)my_syscall6(SYS_mmap2, (long)addr, length, prot, flags, fd, pgoffset);
}

static long my_reboot(void)
{
    return my_syscall4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                       LINUX_REBOOT_CMD_RESTART, 0);
}

/* ============================================================
 * UART direct register access (bypasses entire kernel)
 * ============================================================ */

static volatile unsigned int *uart_base;

/* Write one character directly to UART TX register */
static void uart_direct_putc(char c)
{
    if (!uart_base) return;
    /* Wait for TX holding register to be empty */
    while (!(uart_base[UART_LSR_OFF / 4] & UART_LSR_THRE))
        ;
    uart_base[UART_THR_OFF / 4] = (unsigned int)c;
}

/* Write a string directly to UART */
static void uart_direct_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_direct_putc('\r');
        uart_direct_putc(*s++);
    }
}

/* Write a hex number directly to UART */
static void uart_direct_puthex(unsigned long val)
{
    static const char hex[] = "0123456789abcdef";
    char buf[11];
    buf[0] = '0';
    buf[1] = 'x';
    int i;
    for (i = 7; i >= 0; i--) {
        buf[2 + (7 - i)] = hex[(val >> (i * 4)) & 0xf];
    }
    buf[10] = 0;
    uart_direct_puts(buf);
}

/* ============================================================
 * String helpers (for write() based output)
 * ============================================================ */

static int __attribute__((noinline)) my_strlen(const char *s)
{
    int n = 0;
    while (s[n]) n++;
    return n;
}

static void my_puts(int fd, const char *s)
{
    my_write(fd, s, my_strlen(s));
}

static void my_putnum(int fd, long val)
{
    char buf[20];
    int i = 0;
    int neg = 0;
    if (val < 0) { neg = 1; val = -val; }
    if (val == 0) {
        buf[i++] = '0';
    } else {
        while (val > 0) {
            buf[i++] = '0' + (val % 10);
            val /= 10;
        }
    }
    if (neg) buf[i++] = '-';
    char out[20];
    int j;
    for (j = 0; j < i; j++)
        out[j] = buf[i - 1 - j];
    my_write(fd, out, i);
}

static void my_puthex(int fd, unsigned long val)
{
    static const char hex[] = "0123456789abcdef";
    char buf[11];
    buf[0] = '0'; buf[1] = 'x';
    int i;
    for (i = 7; i >= 0; i--)
        buf[2 + (7 - i)] = hex[(val >> (i * 4)) & 0xf];
    buf[10] = 0;
    my_puts(fd, buf);
}

/* ============================================================
 * ENTRY POINT
 * ============================================================ */
void __attribute__((noreturn, section(".text.startup"))) _start(void)
{
    long ret;
    long fd_mem;
    long ttyfd;
    long consfd;

    uart_base = 0;

    /* =====================================================
     * LAYER 0: Direct UART via /dev/mem mmap
     * This bypasses the ENTIRE kernel TTY/serial stack.
     * If even this doesn't produce output, the CPU isn't
     * executing our code at all.
     * ===================================================== */
    fd_mem = my_open("/dev/mem", O_RDWR | O_SYNC);

    if (fd_mem >= 0) {
        /*
         * mmap2 offset is in pages (4096 byte pages).
         * UART phys = 0x10406900. Page-aligned = 0x10406000.
         * pgoffset = 0x10406000 / 4096 = 0x10406.
         * UART offset within page = 0x900.
         */
        unsigned long page_base = UART_PHYS_BASE & PAGE_MASK;
        unsigned long page_off = UART_PHYS_BASE - page_base;
        long pgoffset = page_base / PAGE_SIZE;

        void *mapped = my_mmap2(0, PAGE_SIZE, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd_mem, pgoffset);

        if ((long)mapped > 0 && mapped != MAP_FAILED) {
            uart_base = (volatile unsigned int *)((char *)mapped + page_off);

            uart_direct_puts("\r\n\r\n");
            uart_direct_puts("############################################\r\n");
            uart_direct_puts("# init_raw: DIRECT UART WRITE WORKS!      #\r\n");
            uart_direct_puts("# Bypassing kernel TTY layer entirely     #\r\n");
            uart_direct_puts("############################################\r\n");
            uart_direct_puts("mmap returned: ");
            uart_direct_puthex((unsigned long)mapped);
            uart_direct_puts("\r\nuart_base: ");
            uart_direct_puthex((unsigned long)uart_base);
            uart_direct_puts("\r\nfd_mem: ");
            uart_direct_puthex((unsigned long)fd_mem);
            uart_direct_puts("\r\n");
        } else {
            /* mmap failed — we can't print via UART.
             * Fall through to try TTY methods. */
        }
        /* Don't close fd_mem — we need the mapping alive */
    }

    /* Report status so far via direct UART */
    if (uart_base) {
        uart_direct_puts("\r\n--- Testing kernel TTY paths ---\r\n");
        uart_direct_puts("fd_mem open: ");
        uart_direct_puthex((unsigned long)fd_mem);
        uart_direct_puts("\r\n");
    }

    /* =====================================================
     * LAYER 1: Test inherited fd 1 (kernel's /dev/console)
     * ===================================================== */
    ret = my_write(1, "L1: write to fd 1\n", 18);
    if (uart_base) {
        uart_direct_puts("write(1) returned: ");
        uart_direct_puthex((unsigned long)ret);
        uart_direct_puts("\r\n");
    }

    /* =====================================================
     * LAYER 2: Open /dev/ttyS0 directly
     * ===================================================== */
    ttyfd = my_open("/dev/ttyS0", O_RDWR);
    if (uart_base) {
        uart_direct_puts("open(/dev/ttyS0) returned: ");
        uart_direct_puthex((unsigned long)ttyfd);
        uart_direct_puts("\r\n");
    }
    if (ttyfd >= 0) {
        ret = my_write(ttyfd, "L2: write to /dev/ttyS0\n", 24);
        if (uart_base) {
            uart_direct_puts("write(ttyS0) returned: ");
            uart_direct_puthex((unsigned long)ret);
            uart_direct_puts("\r\n");
        }
        my_close(ttyfd);
    }

    /* =====================================================
     * LAYER 3: Open /dev/console
     * ===================================================== */
    consfd = my_open("/dev/console", O_RDWR);
    if (uart_base) {
        uart_direct_puts("open(/dev/console) returned: ");
        uart_direct_puthex((unsigned long)consfd);
        uart_direct_puts("\r\n");
    }
    if (consfd >= 0) {
        ret = my_write(consfd, "L3: write to /dev/console\n", 26);
        if (uart_base) {
            uart_direct_puts("write(/dev/console) returned: ");
            uart_direct_puthex((unsigned long)ret);
            uart_direct_puts("\r\n");
        }
        my_close(consfd);
    }

    /* =====================================================
     * Report PID
     * ===================================================== */
    if (uart_base) {
        long pid = my_getpid();
        uart_direct_puts("getpid() = ");
        uart_direct_puthex((unsigned long)pid);
        uart_direct_puts("\r\n");
    }

    /* =====================================================
     * Summary via direct UART
     * ===================================================== */
    if (uart_base) {
        uart_direct_puts("\r\n");
        uart_direct_puts("############################################\r\n");
        uart_direct_puts("# ALL TESTS COMPLETE                       #\r\n");
        uart_direct_puts("# If you see this, init_raw is running     #\r\n");
        uart_direct_puts("# Looping forever (PID 1)                  #\r\n");
        uart_direct_puts("############################################\r\n");
    }

    /* =====================================================
     * SIGNAL: Infinite loop. If no UART output at all,
     * we wait 60 seconds then reboot as proof of execution.
     * The watchdog is handled by bcm7038-wdt kernel driver,
     * so we should survive the 10s CFE watchdog.
     * ===================================================== */
    volatile long counter;
    for (counter = 0; ; counter++) {
        volatile long i;
        for (i = 0; i < 100000000L; i++);

        if (uart_base) {
            uart_direct_putc('.');
        }

        /* After ~60 seconds (30 iterations * ~2s each), reboot
         * as proof that this binary actually ran */
        if (counter == 30) {
            if (uart_base) {
                uart_direct_puts("\r\n[init_raw] REBOOTING as proof of execution\r\n");
            }
            my_sync();
            my_reboot();
        }
    }
}
