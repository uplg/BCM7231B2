/*
 * Minimal mount(2) wrapper for FROG-HACK
 * Targets: MIPS32 R1 (BMIPS4380), static musl build
 *
 * Usage:
 *   mount -t <type> [-o <opts>] <source> <target>
 *   mount -t <type> <source> <target>
 *   mount <source> <target>
 *
 * Supports -o ro flag (MS_RDONLY).
 * Does NOT support -a, /etc/fstab, remount, etc.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/mount.h>

static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s [-t type] [-o options] source target\n", prog);
    exit(1);
}

int main(int argc, char *argv[])
{
    const char *fstype = NULL;
    const char *options = NULL;
    const char *source = NULL;
    const char *target = NULL;
    unsigned long flags = 0;
    int i;

    if (argc < 3)
        usage(argv[0]);

    /* Parse options */
    i = 1;
    while (i < argc) {
        if (strcmp(argv[i], "-t") == 0) {
            if (i + 1 >= argc)
                usage(argv[0]);
            fstype = argv[i + 1];
            i += 2;
        } else if (strcmp(argv[i], "-o") == 0) {
            if (i + 1 >= argc)
                usage(argv[0]);
            options = argv[i + 1];
            i += 2;
        } else {
            /* First positional = source, second = target */
            break;
        }
    }

    /* After options, we need exactly 2 positional args: source and target */
    if (i + 2 != argc)
        usage(argv[0]);

    source = argv[i];
    target = argv[i + 1];

    /* Parse mount options */
    if (options) {
        /* Simple option parsing - check for common flags */
        char *opts_copy = strdup(options);
        char *tok = strtok(opts_copy, ",");
        while (tok) {
            if (strcmp(tok, "ro") == 0)
                flags |= MS_RDONLY;
            else if (strcmp(tok, "nosuid") == 0)
                flags |= MS_NOSUID;
            else if (strcmp(tok, "nodev") == 0)
                flags |= MS_NODEV;
            else if (strcmp(tok, "noexec") == 0)
                flags |= MS_NOEXEC;
            else if (strcmp(tok, "remount") == 0)
                flags |= MS_REMOUNT;
            /* Other options (like size=10M) are passed as data to mount() */
            tok = strtok(NULL, ",");
        }
        free(opts_copy);
    }

    if (mount(source, target, fstype, flags, options) != 0) {
        fprintf(stderr, "mount: mounting %s on %s failed: %s\n",
                source, target, strerror(errno));
        return 1;
    }

    return 0;
}
