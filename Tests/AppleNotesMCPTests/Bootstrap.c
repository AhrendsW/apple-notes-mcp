#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glob.h>
#include <sys/wait.h>
#include <unistd.h>

static int debug_directory(char *out, size_t out_size) {
    char raw_path[PATH_MAX];
    uint32_t raw_size = sizeof(raw_path);
    if (_NSGetExecutablePath(raw_path, &raw_size) != 0) {
        fprintf(stderr, "AppleNotesMCPTests: test runner path exceeds PATH_MAX\n");
        return -1;
    }

    char resolved[PATH_MAX];
    if (realpath(raw_path, resolved) == NULL) {
        strncpy(resolved, raw_path, sizeof(resolved) - 1);
        resolved[sizeof(resolved) - 1] = '\0';
    }

    char *bundle_marker = strstr(resolved, ".xctest/Contents/MacOS/");
    if (bundle_marker != NULL) {
        *bundle_marker = '\0';
        char *last_slash = strrchr(resolved, '/');
        if (last_slash == NULL) {
            return -1;
        }
        *last_slash = '\0';
    } else {
        char *last_slash = strrchr(resolved, '/');
        if (last_slash == NULL) {
            return -1;
        }
        *last_slash = '\0';
    }

    if (snprintf(out, out_size, "%s", resolved) >= (int)out_size) {
        return -1;
    }
    return 0;
}

static int find_harness_from_build_dir(char *out, size_t out_size) {
    const char *patterns[] = {
        ".build/*/debug/AppleNotesMCPTestHarness",
        ".build/debug/AppleNotesMCPTestHarness"
    };

    for (size_t i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++) {
        glob_t matches;
        memset(&matches, 0, sizeof(matches));
        int rc = glob(patterns[i], 0, NULL, &matches);
        if (rc == 0 && matches.gl_pathc > 0) {
            char resolved[PATH_MAX];
            const char *path = matches.gl_pathv[0];
            const char *selected = realpath(path, resolved) == NULL ? path : resolved;
            int written = snprintf(out, out_size, "%s", selected);
            globfree(&matches);
            return written >= (int)out_size ? -1 : 0;
        }
        globfree(&matches);
    }
    return -1;
}

__attribute__((constructor))
static void run_apple_notes_mcp_test_harness(void) {
    char debug_dir[PATH_MAX];
    if (debug_directory(debug_dir, sizeof(debug_dir)) != 0) {
        fprintf(stderr, "AppleNotesMCPTests: failed to locate SwiftPM debug directory\n");
        exit(127);
    }

    char harness[PATH_MAX];
    if (snprintf(harness, sizeof(harness), "%s/AppleNotesMCPTestHarness", debug_dir) >= (int)sizeof(harness)) {
        fprintf(stderr, "AppleNotesMCPTests: harness path exceeds PATH_MAX\n");
        exit(127);
    }
    if (access(harness, X_OK) != 0 && find_harness_from_build_dir(harness, sizeof(harness)) != 0) {
        fprintf(stderr, "AppleNotesMCPTests: failed to locate AppleNotesMCPTestHarness\n");
        exit(127);
    }

    pid_t pid = fork();
    if (pid == 0) {
        execl(harness, harness, (char *)NULL);
        fprintf(stderr, "AppleNotesMCPTests: failed to exec %s\n", harness);
        _exit(127);
    }
    if (pid < 0) {
        perror("AppleNotesMCPTests: fork");
        exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("AppleNotesMCPTests: waitpid");
        exit(127);
    }

    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        if (code != 0) {
            exit(code);
        }
        return;
    }

    if (WIFSIGNALED(status)) {
        fprintf(stderr, "AppleNotesMCPTests: harness terminated by signal %d\n", WTERMSIG(status));
    }
    exit(1);
}
