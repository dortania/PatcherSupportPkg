// a34-amd-wide-mulhi: mulhi(ulong, ulong) must give the high 64 bits; with a large power of two in one high half, the
// other's high half was taken as 0. Fix: AMDTextureAtomics AMD_WIDE_MULHI_FIX, GeForceAIRCompat NVAIR_INTRINSICS,
// NVAIR_I64_FIX. Checks: 2^31 and 2^30 against shifted factors, swapped, two general products. Argument: GPU name.
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
