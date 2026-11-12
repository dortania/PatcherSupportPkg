// a27-amd-loop-dividend (AMD adapter): a loop variable that starts as 32 bits cut from a 64-bit value and is divided
// as a signed int in the loop (`uint v = uint(min(x, y) >> 10); for (i < 3) { s += int(v) % 257; v ^= ...; }`) comes
// out as the unsigned division in the first iteration (found by fuzzing with 64-bit integers, seed 1663). The same
// bug as a22, but the division sees a phi in the AIR: libAMDIL902 unrolls the loop afterwards. The adapter builds
// the cuts coming into such phis from the 32-bit halves too.
// Checked: % 257 and / 1000 in a 3-trip loop, an index into a private array, and a nested 2 x 2 loop, against the CPU
// on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device int *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  ulong x = (ulong(in[4 * t]) << 32) | ulong(in[4 * t + 1]), y = (ulong(in[4 * t + 2]) << 32) | ulong(in[4 * t + 3]);\n"
    "  uint v = uint(min(x, y) >> 10), u = v, w = v;\n"
    "  int s = 0, q = 0, n = 0;\n"
    "  for (uint i = 0; i < 3; i++) { s += int(v) % 257; q += int(v) / 1000; v ^= in[4 * t + i]; }\n"
    "  uint p[8];\n"
    "  for (uint j = 0; j < 8; j++) p[j] = in[4 * t + (j & 3)] + j;\n"
    "  for (uint i = 0; i < 3; i++) u ^= p[uint(int(u) % 257) & 7];\n"
    "  for (uint i = 0; i < 2; i++) { for (uint j = 0; j < 2; j++) { n += int(w) % 7; w ^= in[4 * t + j]; } w += in[4 * t + 2]; }\n"
    "  out[4 * t] = s; out[4 * t + 1] = q; out[4 * t + 2] = int(u); out[4 * t + 3] = n;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a27-amd-loop-dividend";
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
        const int32_t *got = out.contents;
        int wrong = 0, first = -1;
        for (int t = 0; t < kThreads; t++) {
            const uint32_t *a = input + 4 * t;
            uint64_t x = ((uint64_t)a[0] << 32) | a[1], y = ((uint64_t)a[2] << 32) | a[3];
            uint32_t v = (uint32_t)((x < y ? x : y) >> 10), u = v, w = v, p[8];
            int32_t sum = 0, quot = 0, nest = 0;
            for (int i = 0; i < 3; i++) { sum += (int32_t)v % 257; quot += (int32_t)v / 1000; v ^= a[i]; }
            for (int j = 0; j < 8; j++) p[j] = a[j & 3] + (uint32_t)j;
            for (int i = 0; i < 3; i++) u ^= p[(uint32_t)((int32_t)u % 257) & 7];
            for (int i = 0; i < 2; i++) { for (int j = 0; j < 2; j++) { nest += (int32_t)w % 7; w ^= a[j]; } w += a[2]; }
            int32_t want[kOut] = {sum, quot, (int32_t)u, nest};
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %d)", dev.name.UTF8String, wrong, kThreads * kOut, t, k, got[first]);
        }
        return PASS(bug, "%s: signed divisions in loops of a value cut from 64 bits", dev.name.UTF8String);
    }
}
