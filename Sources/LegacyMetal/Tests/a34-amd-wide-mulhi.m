// a34-amd-wide-mulhi (AMD adapter): the high 64 bits of a 64 x 64 bit unsigned product, mulhi(ulong, ulong).
// `uint(mulhi(ulong(x >> 16) << 32 | y, ulong(0x80000000u) << 32 | z) >> 32)` came out as if the first factor's high
// half were 0, with stock files too, when the other factor's high half is a large power of two and the first one's
// comes from a right shift (found by fuzzing with loop counters in expressions, seed 5225). libAMDIL902's 64-bit
// multiply is at fault (the same product built from 64-bit multiplies in the IR is as wrong), so the adapter builds
// every scalar unsigned 64-bit mul_hi from 32-bit mul and mul_hi of the halves.
// Checked: 2^31 and 2^30 against x >> 16, 2^31 against x >> 1, the factors swapped, and two general products (their
// high and low 32 bits), against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 6 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t] + t, b = in[4 * t + 1] * 3u + t, c = in[4 * t + 2] * 5u + t, d = in[4 * t + 3] * 7u + t;\n"
    "  out[6 * t] = uint(mulhi((ulong(a >> 16) << 32) | ulong(b), (ulong(0x80000000u) << 32) | ulong(c)) >> 32);\n"
    "  out[6 * t + 1] = uint(mulhi((ulong(a >> 16) << 32) | ulong(b), (ulong(0x40000000u) << 32) | ulong(c)) >> 32);\n"
    "  out[6 * t + 2] = uint(mulhi((ulong(a >> 1) << 32) | ulong(b), (ulong(0x80000000u) << 32) | ulong(c)) >> 32);\n"
    "  out[6 * t + 3] = uint(mulhi((ulong(0x80000000u) << 32) | ulong(c), (ulong(a >> 16) << 32) | ulong(b)) >> 32);\n"
    "  out[6 * t + 4] = uint(mulhi((ulong(a) << 32) | ulong(b), (ulong(c) << 32) | ulong(d)) >> 32);\n"
    "  out[6 * t + 5] = uint(mulhi((ulong(a) << 32) | ulong(b), (ulong(c) << 32) | ulong(d)));\n"
    "}\n";

static uint64_t mulhi64(uint64_t x, uint64_t y) { return (uint64_t)(((unsigned __int128)x * y) >> 64); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a34-amd-wide-mulhi";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x2545f491u;
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
            uint32_t a = input[4 * t] + t, b = input[4 * t + 1] * 3 + t, c = input[4 * t + 2] * 5 + t, d = input[4 * t + 3] * 7 + t;
            uint64_t x16 = ((uint64_t)(a >> 16) << 32) | b, x1 = ((uint64_t)(a >> 1) << 32) | b, c31 = (0x80000000ull << 32) | c;
            uint64_t x = ((uint64_t)a << 32) | b, y = ((uint64_t)c << 32) | d;
            uint32_t want[kOut] = {
                (uint32_t)(mulhi64(x16, c31) >> 32), (uint32_t)(mulhi64(x16, (0x40000000ull << 32) | c) >> 32),
                (uint32_t)(mulhi64(x1, c31) >> 32), (uint32_t)(mulhi64(c31, x16) >> 32),
                (uint32_t)(mulhi64(x, y) >> 32), (uint32_t)mulhi64(x, y),
            };
            for (int w = 0; w < kOut; w++)
                if (got[kOut * t + w] != want[w]) { if (first < 0) first = kOut * t + w; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, w = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %08x)", dev.name.UTF8String, wrong, kThreads * kOut, t, w, got[first]);
        }
        return PASS(bug, "%s: high halves of 64-bit products, with power-of-two high halves too", dev.name.UTF8String);
    }
}
