// a30-amd-clamp-equal-bounds (AMD adapter): a clamp whose bounds are the same constant is that constant, also when its
// value isn't constant. `z + uint(bool(x & clamp(y | 1u, 1u, 1u)))` came out as z minus the bool: libAMDIL902's DAG
// folds the call to 1 through the known bits of y | 1, and the and with the now constant 1 is taken for a 0 / -1
// boolean (a23's bug; found probing the forms around a28). The adapter folds clamp(x, c, c) to c.
// Checked: uint with y | 1, w | 3 and y | 0x80000001, and ushort, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint x = in[4 * t], y = in[4 * t + 1], z = in[4 * t + 2], w = in[4 * t + 3];\n"
    "  out[4 * t] = z + uint(bool(x & clamp(y | 1u, 1u, 1u)));\n"
    "  out[4 * t + 1] = z + uint(bool(x & clamp(w | 3u, 1u, 1u)));\n"
    "  out[4 * t + 2] = z + uint(bool(x & clamp(y | 0x80000001u, 1u, 1u)));\n"
    "  out[4 * t + 3] = z + uint(bool(x & uint(clamp(ushort(ushort(y) | ushort(1)), ushort(1), ushort(1)))));\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a30-amd-clamp-equal-bounds";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x85ebca6bu;
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
            uint32_t x = input[4 * t], z = input[4 * t + 2], bit = (x & 1) != 0;  // every clamp here is 1
            uint32_t want[kOut] = {z + bit, z + bit, z + bit, z + bit};
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d results wrong (thread %d, form %d: got %u)", dev.name.UTF8String, wrong, kThreads * kOut, t, k, got[first]);
        }
        return PASS(bug, "%s: clamps with equal bounds tested as bools", dev.name.UTF8String);
    }
}
