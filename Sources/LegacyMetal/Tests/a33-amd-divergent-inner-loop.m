// a33-amd-divergent-inner-loop (AMD adapter): lanes that leave an inner loop early must keep their values while other
// lanes of the wave go on looping, also inside an outer loop the compiler unrolls. `for (i < 4) { n = 0; while (n < 8) {
// n++; v = (i & 1) ? extract_bits(a, (e * v) & 15, c & 15) : char(n) ^ a; if ((int(i) / d & 3) == 0) break; } }` gave a
// wrong v in every lane of a wave that held one lane with d = 1, which loops on (found by fuzzing with loop counters in
// expressions, seed 2398, stock files too): libAMDIL902 unrolls the outer loop fully, and the lanes that had left the
// inner loop still took its later passes. With the outer loop left rolled the code is right, so the adapter keeps outer
// loops around such inner loops rolled.
// Checked: lane 5 of each 64-thread group loops on, the others leave at once; v and the summed trip counts of 256 threads
// against the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 2 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]],\n"
    "              uint l [[thread_position_in_threadgroup]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], e = in[4 * t + 3];\n"
    "  uint v = b * 3u + t, s = a * 9u + t, d = l == 5 ? 1u : b | 1u;\n"
    "  for (uint i = 0; i < 4; i++) {\n"
    "    uint n = 0;\n"
    "    while (n < 8) { n++;\n"
    "      v = (i & 1) != 0 ? extract_bits(a, (uint(ushort(e)) * uint(ushort(v))) & 15u, c & 15u) : uint(int(char(n))) ^ a;\n"
    "      if ((uint(int(i) / int(d & 0x7fffffffu)) & 3u) == 0) break; }\n"
    "    s += n;\n"
    "  }\n"
    "  out[2 * t] = v; out[2 * t + 1] = s;\n"
    "}\n";

static uint32_t extractBits(uint32_t x, uint32_t offset, uint32_t bits) { return bits ? (x >> offset) & ((1u << bits) - 1) : 0; }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a33-amd-divergent-inner-loop";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], x = 0x1b873593u;
        for (int i = 0; i < kThreads * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; input[i] = x; }
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
            const uint32_t *in4 = input + 4 * t;
            uint32_t a = in4[0], b = in4[1], c = in4[2], ev = in4[3];
            uint32_t v = b * 3u + (uint32_t)t, s = a * 9u + (uint32_t)t, d = (t % 64) == 5 ? 1u : b | 1u;
            for (uint32_t i = 0; i < 4; i++) {
                uint32_t n = 0;
                while (n < 8) {
                    n++;
                    v = (i & 1) ? extractBits(a, ((uint32_t)(uint16_t)ev * (uint32_t)(uint16_t)v) & 15, c & 15) : (uint32_t)(int32_t)(int8_t)n ^ a;
                    if ((((uint32_t)((int32_t)i / (int32_t)(d & 0x7fffffffu))) & 3) == 0) break;
                }
                s += n;
            }
            uint32_t want[kOut] = {v, s};
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, %s: got %08x)", dev.name.UTF8String, wrong, kThreads * kOut, t, k ? "trip sum" : "v", got[first]);
        }
        return PASS(bug, "%s: lanes that leave an inner loop early keep their values inside an unrolled outer loop", dev.name.UTF8String);
    }
}
