// a23-amd-constant-min-max (AMD adapter): a bool from `x & min(1u, 145u)` added to a value must be added.
// air.min / air.max / air.clamp with constant arguments stay calls through libAMDIL902's IR optimizer and fold only in
// its DAG, where the and with the now constant 1 is taken for a 0 / -1 boolean and `z + bool` becomes `z - bool`
// (found by fuzzing: z + uint(bool(x & min(1u, 145u)))). The adapter folds such calls to constants first.
// Checked: unsigned and signed min, max, clamp, and a mask of 2, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 5 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint x = in[4 * t], z = in[4 * t + 1] * 11u + t;\n"
    "  out[5 * t] = z + uint(bool(x & min(1u, 145u)));\n"
    "  out[5 * t + 1] = z + uint(bool(x & max(1u, 0u)));\n"
    "  out[5 * t + 2] = z + uint(bool(x & uint(min(1, 145))));\n"
    "  out[5 * t + 3] = z + uint(bool(x & clamp(1u, 0u, 5u)));\n"
    "  out[5 * t + 4] = z + uint(bool(x & min(2u, 145u)));\n"
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
            uint32_t want[kOut] = {z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 1) != 0), z + ((x & 2) != 0)};
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
