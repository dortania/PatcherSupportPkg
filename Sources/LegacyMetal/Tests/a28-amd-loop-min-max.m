// a28-amd-loop-min-max (AMD adapter): integer min, max or clamp of a loop counter and constants, and'ed with x, tested
// as a bool and added (`for (i < 3) a += uint(bool(x & min(i, 145u)))`) comes out as a minus the bools. a23's bug:
// once libAMDIL902 unrolls the loop the calls have constant arguments, which fold only in its DAG. The adapter makes
// such calls a compare and a select, which fold right after unrolling.
// Checked: unsigned min, max and clamp, signed min and clamp, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 5 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint x = in[2 * t], z = in[2 * t + 1], a = z, b = z, c = z, d = z, e = z;\n"
    "  for (uint i = 0; i < 3; i++) a += uint(bool(x & min(i, 145u)));\n"
    "  for (uint i = 0; i < 3; i++) b += uint(bool(x & max(i, 1u)));\n"
    "  for (uint i = 0; i < 3; i++) c += uint(bool(x & clamp(i, 1u, 1u)));\n"
    "  for (int i = 0; i < 3; i++) d += uint(bool(x & uint(min(i, 1))));\n"
    "  for (int i = 0; i < 3; i++) e += uint(bool(x & uint(clamp(i, 0, 1))));\n"
    "  out[5 * t] = a; out[5 * t + 1] = b; out[5 * t + 2] = c; out[5 * t + 3] = d; out[5 * t + 4] = e;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a28-amd-loop-min-max";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 2], s = 0x9e3779b9u;
        for (int i = 0; i < kThreads * 2; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
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
            uint32_t x = input[2 * t], z = input[2 * t + 1], want[kOut] = {z, z, z, z, z};
            for (uint32_t i = 0; i < 3; i++) {
                want[0] += (x & (i < 145 ? i : 145)) != 0;
                want[1] += (x & (i > 1 ? i : 1)) != 0;
                want[2] += (x & 1) != 0;  // clamp(i, 1, 1)
                want[3] += (x & (uint32_t)((int32_t)i < 1 ? (int32_t)i : 1)) != 0;
                want[4] += (x & (uint32_t)((int32_t)i < 0 ? 0 : (int32_t)i > 1 ? 1 : (int32_t)i)) != 0;
            }
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %u)", dev.name.UTF8String, wrong, kThreads * kOut, t, k, got[first]);
        }
        return PASS(bug, "%s: min, max and clamp of loop counters tested as bools", dev.name.UTF8String);
    }
}
