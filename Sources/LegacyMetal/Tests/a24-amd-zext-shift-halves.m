// a24-amd-zext-shift-halves (AMD adapter): a zero-extended 32-bit value shifted into both halves of a ulong keeps the
// bits that cross into the high half.
// `(ulong(min(c, a)) << 32 | rhadd(b, a)) * k >> 19`, which the front end turns into
// `(ulong(min) << 45 | ulong(rhadd) << 13) * ...`, came out with rhadd's top 19 bits missing from the high half (found by
// fuzzing with 64-bit integers; the same with hadd). The adapter builds `ulong(y) << k` (0 < k < 32) from the halves.
// Checked: the fuzzed form with rhadd and with hadd (two kernels), against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
// Two kernels (rhadd, hadd): with both forms in one function the compiler picks the other operand and gets it right.
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t] + t, b = in[4 * t + 1] * 3u + t;\n"
    "  out[t] = uint(((((ulong(min(3797502418u, a)) << 32 | ulong(rhadd(b, a))) * ((ulong(uint(uchar(in[4 * t]) + uchar(in[4 * t + 1]))) << 32) | 4180902230ul)) >> 19) << 32 | ulong(a)) * ulong(b) >> 38);\n"
    "}\n"
    "kernel void k2(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t] + t, b = in[4 * t + 1] * 3u + t;\n"
    "  out[t] = uint(((((ulong(min(3797502418u, a)) << 32 | ulong(hadd(b, a))) * ((ulong(uint(uchar(in[4 * t]) + uchar(in[4 * t + 1]))) << 32) | 4180902230ul)) >> 19) << 32 | ulong(a)) * ulong(b) >> 38);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a24-amd-zext-shift-halves";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps2 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k2"] error:&err];
        if (!ps2) return FAIL(bug, "%s: pipeline k2: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x85ebca6bu;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out2 = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps2]; [e setBuffer:out2 offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got[2] = {out.contents, out2.contents};
        int wrong = 0, first = -1;
        for (int t = 0; t < kThreads; t++) {
            uint32_t a = input[4 * t] + t, b = input[4 * t + 1] * 3 + t;
            uint64_t k = ((uint64_t)((uint32_t)(uint8_t)input[4 * t] + (uint8_t)input[4 * t + 1]) << 32) | 4180902230ull;
            uint32_t lo = a < 3797502418u ? a : 3797502418u;
            uint32_t r = (b >> 1) + (a >> 1) + ((a | b) & 1), h = (b >> 1) + (a >> 1) + (a & b & 1);
            uint32_t want[2];
            for (int f = 0; f < 2; f++) {
                uint64_t m = ((uint64_t)lo << 32) | (f ? h : r);
                want[f] = (uint32_t)((((((m * k) >> 19) << 32) | a) * b) >> 38);
            }
            for (int f = 0; f < 2; f++)
                if (got[f][t] != want[f]) { if (first < 0) first = 2 * t + f; wrong++; }
        }
        if (wrong) return FAIL(bug, "%s: %d of %d results wrong (thread %d, %s: got %08x)", dev.name.UTF8String, wrong, kThreads * 2, first / 2, first % 2 ? "hadd" : "rhadd", got[first % 2][first / 2]);
        return PASS(bug, "%s: zero-extended values shifted into both halves of a ulong", dev.name.UTF8String);
    }
}
