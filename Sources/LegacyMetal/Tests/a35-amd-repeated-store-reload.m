// a35-amd-repeated-store-reload: an increment through one device pointer between two equal stores through another that
// may point to the same word must not be lost; SC read the first pointer once for two increments, as if the second equal
// store left memory as the first had. Fix: AMDTextureAtomics AMD_REPEATED_STORE_FIX. Checks: `(*a)++; *b = 7; (*a)++;
// *b = 7; (*a)++;` and a loop of `*c += 3; *d = 11;` (which the compiler unrolls into equal stores), each with the two
// pointers equal in some threads and different in others. Argument: GPU name.
#import "repro.h"

enum { kThreads = 256, kOut = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  device uint *a = out + 4u * t + (in[2u * t] & 1u), *b = out + 4u * t + ((in[2u * t + 1u] >> 1u) & 1u);\n"
    "  out[4u * t] = in[2u * t]; out[4u * t + 1u] = in[2u * t + 1u];\n"
    "  (*a)++; *b = 7u; (*a)++; *b = 7u; (*a)++;\n"
    "  device uint *c = out + 4u * t + 2u + ((in[2u * t] >> 3u) & 1u), *d = out + 4u * t + 2u + ((in[2u * t + 1u] >> 4u) & 1u);\n"
    "  out[4u * t + 2u] = t; out[4u * t + 3u] = ~t;\n"
    "  for (uint i = 0; i < 5u; i++) { *c += 3u; *d = 11u; }\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a35-amd-repeated-store-reload";
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
            uint32_t x = input[2 * t], y = input[2 * t + 1], want[kOut] = {x, y, (uint32_t)t, ~(uint32_t)t};
            uint32_t *a = &want[x & 1], *b = &want[(y >> 1) & 1], *c = &want[2 + ((x >> 3) & 1)], *d = &want[2 + ((y >> 4) & 1)];
            (*a)++; *b = 7; (*a)++; *b = 7; (*a)++;
            for (int i = 0; i < 5; i++) { *c += 3; *d = 11; }
            for (int w = 0; w < kOut; w++)
                if (got[kOut * t + w] != want[w]) { if (first < 0) first = kOut * t + w; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, w = first % kOut;
            return FAIL(bug, "%s: %d of %d words wrong (thread %d, word %d: got %08x)", dev.name.UTF8String, wrong, kThreads * kOut, t, w, got[first]);
        }
        return PASS(bug, "%s: increments through a pointer between equal stores through one that may alias it", dev.name.UTF8String);
    }
}
