// a22-amd-shifted-dividend (AMD adapter): signed division of 32 bits cut from the middle of a 64-bit value.
// `(int)uint(x >> k) / c` with x a ulong (or long) and 0 < k < 32 comes out as the unsigned division, for constant
// divisors of either sign, and `%` likewise (found by fuzzing with 64-bit integers: (int)uint(min(a, b) >> 31) / 65535).
// The adapter builds such dividends from the 32-bit halves, which divide right.
// Checked: k = 31, 16 and 1, / 65535, / -3, % 7, a long shifted right, a select between two cuts, a long remainder
// a quotient of non-negative longs, and a cut that passes an unsigned division first (`(int)(uint(max(x, y) >> 14) / d)
// / 225`, seed 4769), against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 10 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device int *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  ulong x = (ulong(in[4 * t]) << 32) | ulong(in[4 * t + 1]), y = (ulong(in[4 * t + 2]) << 32) | ulong(in[4 * t + 3]);\n"
    "  out[10 * t] = (int)uint(min(x, y) >> 31) / 65535;\n"
    "  out[10 * t + 1] = (int)uint(x >> 16) / 65535;\n"
    "  out[10 * t + 2] = (int)uint(x >> 1) / -3;\n"
    "  out[10 * t + 3] = (int)uint(y >> 31) % 7;\n"
    "  out[10 * t + 4] = (int)uint(long(x) >> 20) / 1000;\n"
    "  out[10 * t + 5] = (int)uint(x * y >> 9) / 12345;\n"
    "  out[10 * t + 6] = (int)uint((long)x >= (long)y ? x >> 7 : y >> 11) / 111;\n"
    "  out[10 * t + 7] = (int)uint((long)x % (long)((y & 0x7ffffffffffffffful) | 1ul)) / 1234567;\n"
    "  out[10 * t + 8] = (int)uint((long)(x >> 8) / (long)((y >> 40) | 1ul)) % 777;\n"
    "  uint d = (((in[4 * t + 2] & in[4 * t + 3]) != 0u) ? 1u : 0u) % ((in[4 * t + 1] & 0x7ffffffeu) | 1u) | 1u;\n"
    "  out[10 * t + 9] = (int)(uint(max(x, y) >> 14) / d) / 225;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a22-amd-shifted-dividend";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x6d2b79f5u;
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
        const int32_t *got = out.contents;
        int wrong = 0, first = -1;
        for (int t = 0; t < kThreads; t++) {
            uint64_t x = ((uint64_t)input[4 * t] << 32) | input[4 * t + 1], y = ((uint64_t)input[4 * t + 2] << 32) | input[4 * t + 3];
            int32_t want[kOut] = {
                (int32_t)(uint32_t)((x < y ? x : y) >> 31) / 65535,
                (int32_t)(uint32_t)(x >> 16) / 65535,
                (int32_t)(uint32_t)(x >> 1) / -3,
                (int32_t)(uint32_t)(y >> 31) % 7,
                (int32_t)(uint32_t)((int64_t)x >> 20) / 1000,
                (int32_t)(uint32_t)((x * y) >> 9) / 12345,
                (int32_t)(uint32_t)((int64_t)x >= (int64_t)y ? x >> 7 : y >> 11) / 111,
                (int32_t)(uint32_t)((int64_t)x % (int64_t)((y & 0x7fffffffffffffffull) | 1)) / 1234567,
                (int32_t)(uint32_t)((int64_t)(x >> 8) / (int64_t)((y >> 40) | 1)) % 777,
                (int32_t)((uint32_t)((x > y ? x : y) >> 14) / (((input[4 * t + 2] & input[4 * t + 3]) != 0) % ((input[4 * t + 1] & 0x7ffffffeu) | 1) | 1)) / 225,
            };
            for (int w = 0; w < kOut; w++)
                if (got[kOut * t + w] != want[w]) { if (first < 0) first = kOut * t + w; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, w = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %d)", dev.name.UTF8String, wrong, kThreads * kOut, t, w, got[first]);
        }
        return PASS(bug, "%s: signed divisions and remainders of 32 bits cut from 64-bit values", dev.name.UTF8String);
    }
}
