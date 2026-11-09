// a23-amd-constant-min-max (AMD adapter): a bool from `x & min(1u, 145u)` added to a value must be added.
// air.min / air.max / air.clamp with constant arguments stay calls through libAMDIL902's IR optimizer and fold only in
// its DAG, where the and with the now constant 1 is taken for a 0 / -1 boolean and `z + bool` becomes `z - bool`
// (found by fuzzing: z + uint(bool(x & min(1u, 145u)))). The adapter folds such calls to constants first.
// Also `y % (min(x, 1u) | 1u)`, a power-of-two divisor the DAG finds late, which crashed its bit-field-extract combine.
// Checked: unsigned and signed min, max, clamp, a mask of 2, the min(x, 1u) divisor, and min(1u, x) under a select in a
// loop exit (form 6: made x != 0, min(x, 1u) gave a 0 / 1 value that a15's bug misread: seed 518; the stock compiler
// and the call are right there), and forms 7 and 8: `(1u >> ((x << 1) & 6u))` modulo `(min(uint(bool(z & 86u)), mulhi(z,
// x)) | 1u) & 0x7fffffffu`, which the front end makes `(min & 0x7ffffffe) | 1` (crashed the same combine: seed 4629), and
// the same with min(1u, ..), against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 9 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint x = in[4 * t], z = in[4 * t + 1] * 11u + t;\n"
    "  out[9 * t] = z + uint(bool(x & min(1u, 145u)));\n"
    "  out[9 * t + 1] = z + uint(bool(x & max(1u, 0u)));\n"
    "  out[9 * t + 2] = z + uint(bool(x & uint(min(1, 145))));\n"
    "  out[9 * t + 3] = z + uint(bool(x & clamp(1u, 0u, 5u)));\n"
    "  out[9 * t + 4] = z + uint(bool(x & min(2u, 145u)));\n"
    "  out[9 * t + 5] = z + (z >> (z & 31u)) % (min(x, 1u) | 1u);\n"
    "  uint v3 = in[4 * t + 3] * 7u + t, v4 = in[4 * t] * 9u + t, n = 0;\n"
    "  while (n < 8) { n++; if ((((uchar)(in[4 * t]) == (uchar)(((uint)((int)((char)(v3 ^ t)))) ^ 164u) ? min(1u, z ^ t) : 32u) & 3u) == 0u) break; }\n"
    "  out[9 * t + 6] = v4 + n;\n"
    "  out[9 * t + 7] = (1u >> ((x << 1) & 6u)) % ((min(uint(bool(z & 86u)), mulhi(z, x)) | 1u) & 0x7fffffffu);\n"
    "  out[9 * t + 8] = (1u >> ((z << 1) & 6u)) % ((min(1u, mulhi(z, x)) | 1u) & 0x7fffffffu);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a23-amd-constant-min-max";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x1b873593u;
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
            uint32_t x = input[4 * t], z = input[4 * t + 1] * 11 + t;
            uint32_t v3 = input[4 * t + 3] * 7 + t, v4 = input[4 * t] * 9 + t, zt = z ^ (uint32_t)t;
            uint32_t m = (uint8_t)x == (uint8_t)((v3 ^ (uint32_t)t) ^ 164) ? (zt < 1 ? zt : 1) : 32;  // the loop's exit doesn't change
            uint32_t want[kOut] = {z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 2) != 0), z,
                                   v4 + ((m & 3) == 0 ? 1 : 8), 0, 0};
            for (int w = 0; w < kOut; w++)
                if (got[kOut * t + w] != want[w]) { if (first < 0) first = kOut * t + w; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, w = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %08x)", dev.name.UTF8String, wrong, kThreads * kOut, t, w, got[first]);
        }
        return PASS(bug, "%s: bools from masks of constant min, max and clamp added", dev.name.UTF8String);
    }
}
