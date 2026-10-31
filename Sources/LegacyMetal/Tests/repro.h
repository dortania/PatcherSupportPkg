// repro.h: shared by the test programs (see ../README.md). Each program checks one bug and prints one result line:
//   PASS <id>: ...   exit 0   the bug does not reproduce (fixed stack)
//   FAIL <id>: ...   exit 1   the bug reproduced
//   SKIP <id>: ...   exit 77  not applicable on this Mac (no such GPU, missing input file)
// Optional first argument: a substring of the GPU name to test (default: the GPU the bug is about; "all" where noted).
// Checks that crash the process on an unfixed stack (unrecognized selector, Metal validation abort) run in a child
// copy of the program (argv: ... --child <mode>), so the parent can still print FAIL with the signal.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <spawn.h>
#include <stdarg.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

__attribute__((unused)) static int reproLine(int code, const char *word, const char *bugId, const char *format, va_list args) {
    printf("%s %s: ", word, bugId);
    vprintf(format, args);
    printf("\n");
    fflush(stdout);
    return code;
}
static int PASS(const char *bugId, const char *format, ...) __attribute__((format(printf, 2, 3)));
__attribute__((unused)) static int PASS(const char *bugId, const char *format, ...) {
    va_list a; va_start(a, format); int r = reproLine(0, "PASS", bugId, format, a); va_end(a); return r;
}
static int FAIL(const char *bugId, const char *format, ...) __attribute__((format(printf, 2, 3)));
__attribute__((unused)) static int FAIL(const char *bugId, const char *format, ...) {
    va_list a; va_start(a, format); int r = reproLine(1, "FAIL", bugId, format, a); va_end(a); return r;
}
static int SKIP(const char *bugId, const char *format, ...) __attribute__((format(printf, 2, 3)));
__attribute__((unused)) static int SKIP(const char *bugId, const char *format, ...) {
    va_list a; va_start(a, format); int r = reproLine(77, "SKIP", bugId, format, a); va_end(a); return r;
}

// The GPU named by argv[1] (substring, case-insensitive), else the first whose name contains `fallback`.
__attribute__((unused)) static id<MTLDevice> reproDevice(int argc, char **argv, const char *fallback) {
    const char *want = argc > 1 && strcmp(argv[1], "--child") ? argv[1] : fallback;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name rangeOfString:@(want) options:NSCaseInsensitiveSearch].location != NSNotFound) return d;
    return nil;
}

// "--child <mode>" in argv: the mode this copy runs, else NULL.
__attribute__((unused)) static const char *reproChildMode(int argc, char **argv) {
    for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "--child")) return argv[i + 1];
    return NULL;
}

// Runs this program again with "--child <mode>" (keeping a GPU argument); returns its exit status, or 128 + the
// signal that killed it.
__attribute__((unused)) static int reproRunChild(int argc, char **argv, const char *mode) {
    char *args[5] = {argv[0], NULL, NULL, NULL, NULL};
    int n = 1;
    if (argc > 1 && strcmp(argv[1], "--child")) args[n++] = argv[1];
    args[n++] = (char *)"--child";
    args[n++] = (char *)mode;
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, args, environ)) return 127;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}

__attribute__((unused)) static const char *reproChildStatus(int status) {
    static char text[64];
    if (status > 128) snprintf(text, sizeof text, "crashed (signal %d: %s)", status - 128, strsignal(status - 128));
    else snprintf(text, sizeof text, "exit status %d", status);
    return text;
}

// A comment unique to this run: makes every compile miss Metal's shader caches.
__attribute__((unused)) static NSString *reproUniqueComment(void) {
    return [NSString stringWithFormat:@"// run %d %f\n", getpid(), [NSDate timeIntervalSinceReferenceDate]];
}

__attribute__((unused)) static BOOL reproRun(id<MTLCommandBuffer> cb) {
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
