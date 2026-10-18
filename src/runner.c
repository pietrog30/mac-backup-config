/*
 * mac-backup-runner — the one binary granted Full Disk Access (FDA).
 *
 * macOS checks FDA against the "responsible process". A launchd job is its own
 * responsible process, and children inherit it. So launchd starts this binary,
 * it execs one of the fixed job scripts, and the script plus restic inherit
 * this binary's FDA grant. restic upgrades therefore never lose access.
 *
 * Only the four job names below are accepted; nothing else can be run through it.
 * Rebuilding changes the binary's signature, so FDA must be re-granted afterwards.
 */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const jobs[] = {"backup", "prune", "check", "restore-test", NULL};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <backup|prune|check|restore-test>\n", argv[0]);
        return 64;
    }
    int known = 0;
    for (int i = 0; jobs[i] != NULL; i++)
        if (strcmp(argv[1], jobs[i]) == 0) known = 1;
    if (!known) {
        fprintf(stderr, "unknown job: %s\n", argv[1]);
        return 64;
    }
    const char *home = getenv("HOME");
    if (home == NULL || home[0] != '/') {
        fprintf(stderr, "HOME is not set\n");
        return 78;
    }
    char script[PATH_MAX];
    int n = snprintf(script, sizeof script, "%s/.config/mac-backup/bin/%s.sh", home, argv[1]);
    if (n < 0 || (size_t)n >= sizeof script) return 78;

    char *const args[] = {"/bin/bash", script, NULL};
    execv("/bin/bash", args);
    perror("execv /bin/bash");
    return 127;
}
