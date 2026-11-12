// a32-amd-wide-average-product (AMD adapter): the high half of a 64-bit product whose operand has an unsigned average in
// its low half must keep the average's carries. `mulhi((ulong(a + b) << 32) | rhadd(a, b), (ulong(popcount(86u)) << 32)
// | k)` came out 2 too low for most inputs (found by fuzzing with 64-bit integers, seed 1488, stock files too; a literal
// 4 for popcount(86u) hides it, so the factor has to fold late). The adapter builds widened hadd / rhadd from plain
// bitwise arithmetic.
// Checked: rhadd and hadd, the high halves of 256 products against exact 128-bit CPU multiplication.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1];\n"
    "  ulong y = (ulong(popcount(86u)) << 32) | 1004142622u;\n"
    "  ulong x = (ulong(a + b) << 32) | rhadd(a, b), z = mulhi(x, y);\n"
    "  out[4 * t] = uint(z); out[4 * t + 1] = uint(z >> 32);\n"
    "  x = (ulong(a + b) << 32) | hadd(a, b); z = mulhi(x, y);\n"
    "  out[4 * t + 2] = uint(z); out[4 * t + 3] = uint(z >> 32);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a32-amd-wide-average-product";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0xc2b2ae35u;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * kOut * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents;
        int wrong = 0, first = -1;
        for (int t = 0; t < kThreads; t++) {
            const uint32_t *a = input + 4 * t;
            uint32_t want[kOut];
            for (unsigned rounded = 0; rounded < 2; rounded++) {
                uint32_t avg = (uint32_t)(((uint64_t)a[0] + a[1] + rounded) >> 1);
                uint64_t x = ((uint64_t)(uint32_t)(a[0] + a[1]) << 32) | avg;
                uint64_t y = (4ull << 32) | 1004142622u;
                uint64_t hi = (uint64_t)(((unsigned __int128)x * y) >> 64);
                unsigned slot = rounded ? 0 : 2;
                want[slot] = (uint32_t)hi; want[slot + 1] = (uint32_t)(hi >> 32);
            }
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d product words wrong (thread %d, word %d: got %u)", dev.name.UTF8String, wrong, kThreads * kOut, t, k, got[first]);
        }
        return PASS(bug, "%s: widened hadd/rhadd products match exact 128-bit CPU multiplication", dev.name.UTF8String);
    }
}
