// i86-intel-threadgroup-atomic-two-values: a threadgroup atomic that only ever holds two constants must compile; the
// Intel back end shrank it to an i1 and aborted. Fix: IntelTextureAtomics INTEL_THREADGROUP_ATOMIC_FIX.
// Checks: thread 0 stores 0, thread 1 stores 300 (7 to a second atomic); every thread reads 300 and 7. Argument: GPU name.
#import "repro.h"

enum { kThreads = 32, kStored = 300, kStoredToSecond = 7 };

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static void put(threadgroup atomic_int *a, int v) { atomic_store_explicit(a, v, memory_order_relaxed); }\n"
    "kernel void k(device uint *out [[buffer(0)]], uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup atomic_int g;\n"
    "    threadgroup atomic_int h;\n"
    "    if (l == 0) { put(&g, 0); put(&h, 0); }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (l == 1) { put(&g, 300); put(&h, 7); }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 2] = (uint)atomic_load_explicit(&g, memory_order_relaxed);\n"
    "    out[t * 2 + 1] = (uint)atomic_load_explicit(&h, memory_order_relaxed);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i86-intel-threadgroup-atomic-two-values";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSString *why = nil;
        id<MTLComputePipelineState> ps = reproComputePipeline(dev, source, nil, &why);
        if (!ps) return FAIL(bug, "%s: %s", name, why.UTF8String);
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 2 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(out.contents, 0xee, out.length);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(kThreads, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        for (int t = 0; t < kThreads; t++)
            if (o[t * 2] != kStored || o[t * 2 + 1] != kStoredToSecond)
                return FAIL(bug, "%s: thread %d read %u and %u, want %d and %d", name, t, o[t * 2], o[t * 2 + 1], kStored, kStoredToSecond);
        return PASS(bug, "%s: threadgroup atomics that only ever hold two constants compile and read right", name);
    }
}
