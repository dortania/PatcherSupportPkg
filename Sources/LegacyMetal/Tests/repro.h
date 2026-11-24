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
// The first GPU whose name contains the argument (or `fallback`), preferring one with no display attached: on a Mac Pro
// both GPUs match "AMD", and a test that resets the display GPU freezes the screen (dyorgio).
__attribute__((unused)) static id<MTLDevice> reproDevice(int argc, char **argv, const char *fallback) {
    const char *want = argc > 1 && strcmp(argv[1], "--child") ? argv[1] : fallback;
    id<MTLDevice> first = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name rangeOfString:@(want) options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if (d.isHeadless) return d;
            if (!first) first = d;
        }
    return first;
}

// OCLP's legacy Metal (MetalOld behind the Metal.framework wrapper), the only place MetalOldCompat loads. Tests of the
// shim's fixes that don't apply to the OS's own Metal (GCN-only Macs) skip without it, as verify.sh does.
__attribute__((unused)) static bool reproOnMetalOld(void) {
    return access("/System/Library/Frameworks/Metal.framework/Versions/A/MetalOld.dylib", F_OK) == 0;
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
// Kernel k of `source` (a unique comment first, so no cached binary is reused), or nil with the result text in *why.
__attribute__((unused)) static id<MTLComputePipelineState> reproComputePipeline(id<MTLDevice> dev, NSString *source,
                                                                                MTLCompileOptions *options, NSString **why) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:options error:&err];
    if (!lib) { *why = [NSString stringWithFormat:@"compile: %@", err.localizedDescription]; return nil; }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) *why = [NSString stringWithFormat:@"%@: pipeline: %@", dev.name, err.localizedDescription];
    return ps;
}
// Dispatches ps on `queue` with `buffers` bound at indices 0, 1, ... and waits; NO if the command buffer failed.
__attribute__((unused)) static BOOL reproDispatch(id<MTLCommandQueue> queue, id<MTLComputePipelineState> ps, NSArray<id<MTLBuffer>> *buffers,
                                                  MTLSize groups, MTLSize perGroup) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    for (NSUInteger i = 0; i < buffers.count; i++) [ce setBuffer:buffers[i] offset:0 atIndex:i];
    [ce dispatchThreadgroups:groups threadsPerThreadgroup:perGroup];
    [ce endEncoding];
    return reproRun(cb);
}
// Runs a fuzz kernel k(in [[buffer(0)]], out [[buffer(1)]]) as mslfuzz2.py does (fast math off, the inputs of seed 1,
// 256 threads in groups of 64) and checks each thread's 8 words, as FNV-1a, against the CPU reference's `want`.
__attribute__((unused)) static int reproFuzzKernel(const char *bug, id<MTLDevice> dev, NSString *src, const uint32_t want[256],
                                                   const char *passText) {
    const char *name = dev.name.UTF8String;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    NSString *why = nil;
    id<MTLComputePipelineState> ps = reproComputePipeline(dev, src, options, &why);
    if (!ps) return FAIL(bug, "%s", why.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t x = 1u * 2654435761u + 12345u;  // the fuzzer's inputs, seed 1
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
    if (!reproDispatch([dev newCommandQueue], ps, @[in, out], MTLSizeMake(T / 64, 1, 1), MTLSizeMake(64, 1, 1)))
        return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *o = out.contents;
    int wrong = 0, first = -1;
    for (int t = 0; t < T; t++) {
        uint32_t h = 2166136261u;
        for (int w = 0; w < 8; w++)
            for (int b = 0; b < 4; b++) { h ^= (o[t * 8 + w] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != want[t]) { wrong++; if (first < 0) first = t; }
    }
    if (wrong) return FAIL(bug, "%s: %d of %d threads differ from the CPU reference (first: thread %d)", name, wrong, T, first);
    return PASS(bug, "%s: %s", name, passText);
}
