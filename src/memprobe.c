/*
 * memprobe.c — dump a physical register range via /dev/mem, robust to the
 * BCM7231's imprecise GISB bus errors: every word is read in a forked child
 * (sync + settle delay so the pending exception lands in the child), so
 * unbacked registers print as "BUSERR.." instead of killing the tool.
 * Same technique as kir_probe; see that file for the full story.
 *
 * Usage: memprobe <phys-addr> [len-bytes]     (defaults: len 0x100)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define PAGE      0x1000u
#define PAGEMASK  (~(PAGE - 1))

static int fd;

static void mmio_sync(void)
{
#ifdef __mips__
    __asm__ __volatile__("sync" ::: "memory");
#endif
}

static int probe_word(volatile uint32_t *p, uint32_t *out)
{
    int pfd[2], status;
    uint32_t v;
    pid_t pid;

    if (pipe(pfd)) { perror("pipe"); exit(1); }
    pid = fork();
    if (pid < 0) { perror("fork"); exit(1); }
    if (pid == 0) {
        signal(SIGBUS, SIG_DFL);
        signal(SIGSEGV, SIG_DFL);
        v = *p;
        mmio_sync();
        usleep(2000);
        write(pfd[1], &v, 4);
        _exit(0);
    }
    close(pfd[1]);
    if (waitpid(pid, &status, 0) < 0 ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        read(pfd[0], &v, 4) != 4) {
        close(pfd[0]);
        return -1;
    }
    close(pfd[0]);
    *out = v;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <phys-addr> [len-bytes]\n", argv[0]);
        return 1;
    }
    uint32_t base = strtoul(argv[1], NULL, 0);
    uint32_t len  = argc > 2 ? strtoul(argv[2], NULL, 0) : 0x100;
    base &= ~3u;

    setvbuf(stdout, NULL, _IONBF, 0);
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }

    for (uint32_t a = base & ~0xfu; a < base + len; a += 0x10) {
        char row[4][12];
        for (int w = 0; w < 4; w++) {
            uint32_t phys = a + 4 * w, v;
            void *m = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED,
                           fd, phys & PAGEMASK);
            if (m == MAP_FAILED) { perror("mmap"); return 1; }
            volatile uint32_t *p =
                (volatile uint32_t *)((char *)m + (phys & (PAGE - 1)));
            if (probe_word(p, &v))
                snprintf(row[w], sizeof(row[w]), "BUSERR..");
            else
                snprintf(row[w], sizeof(row[w]), "%08x", v);
            munmap(m, PAGE);
        }
        printf("%08x: %s %s %s %s\n", a, row[0], row[1], row[2], row[3]);
    }
    return 0;
}
