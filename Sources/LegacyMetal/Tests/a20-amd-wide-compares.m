// a20-amd-wide-compares (AMD adapter): 64-bit comparisons whose result is sign-extended or branched on must compile.
// libAMDIL902's setcc on i64 operands has an i64 result, which no select or brcond pattern takes, so the compile stops
// with "LLVM ERROR: Cannot select" (found by fuzzing with 64-bit integers; v -= uint(bool(w & m)) with w a ulong, or an
// if on a ulong comparison). The adapter does every i64 comparison on the 32-bit halves.
// Checked: the fuzzed form, branches on ulong and long ==, !=, <, >=, compare-selects, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  ulong w = (ulong(a) << 32) | ulong(b), x = (ulong(c) << 32) | ulong(d);\n"
    "  uint v = d;\n"
    "  v -= uint(bool(3399554140u & uint((w << (c & 63u)) >> 32)));\n"
    "  if ((w & 0xc0a0000000000000ul) != 0ul) v ^= 0x100u; else v ^= 0x200u;\n"
    "  if (w < x) v += 7u;\n"
    "  if (long(w) >= long(x)) v += 0x10000u;\n"
    "  if (w == (x ^ 0x5ul)) v += 3u;\n"
    "  out[2 * t] = v;\n"
    "  out[2 * t + 1] = (long(w) < long(x) ? a : b) ^ (w > x ? c : d) ^ uint(w != x) << 31;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a20-amd-wide-compares";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x2545f491u;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        for (int t = 0; t < kThreads; t += 16) { input[4 * t + 2] = input[4 * t]; input[4 * t + 3] = input[4 * t + 1] ^ 5; }  // some w == x ^ 5
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents;
        for (int t = 0; t < kThreads; t++) {
            uint32_t a = input[4 * t], b = input[4 * t + 1], c = input[4 * t + 2], d = input[4 * t + 3];
            uint64_t w = ((uint64_t)a << 32) | b, x = ((uint64_t)c << 32) | d;
            uint32_t v = d;
            v -= (3399554140u & (uint32_t)((w << (c & 63)) >> 32)) != 0;
            v ^= (w & 0xc0a0000000000000ull) ? 0x100u : 0x200u;
            if (w < x) v += 7;
            if ((int64_t)w >= (int64_t)x) v += 0x10000;
            if (w == (x ^ 5)) v += 3;
            uint32_t want1 = ((int64_t)w < (int64_t)x ? a : b) ^ (w > x ? c : d) ^ (uint32_t)(w != x) << 31;
            if (got[2 * t] != v || got[2 * t + 1] != want1)
                return FAIL(bug, "%s: thread %d: %08x %08x, want %08x %08x", dev.name.UTF8String, t, got[2 * t], got[2 * t + 1], v, want1);
        }
        return PASS(bug, "%s: 64-bit comparisons in branches, selects and sign-extended bools", dev.name.UTF8String);
    }
}
