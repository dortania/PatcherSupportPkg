// i87-intel-stale-reload: a load after a store through a pointer that may alias must see that store; the Intel back
// end gave it the value of an earlier load. Fix: IntelTextureAtomics INTEL_STALE_RELOAD_FIX.
// Checks: increment and swap through two pointers into one buffer, in device and threadgroup memory. Argument: GPU name.
#import "repro.h"

enum { kFirst = 10, kSecond = 100, kResults = 3 };

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device int *memory [[buffer(0)]], device const int *index [[buffer(1)]], device int *out [[buffer(2)]]) {\n"
    "    device int *p = memory + index[0];\n"
    "    device int *q = memory + index[1];\n"
    "    *p += 1;\n"
    "    *q += 1;\n"
    "    out[0] = *p;\n"
    "    int first = *p;\n"
    "    *p = *q;\n"
    "    *q = first;\n"
    "    out[1] = *p;\n"
    "    threadgroup int shared[2];\n"
    "    shared[0] = memory[2];\n"
    "    shared[1] = memory[3];\n"
    "    threadgroup int *s = shared + index[0];\n"
    "    threadgroup int *t = shared + index[1];\n"
    "    *s += 1;\n"
    "    *t += 1;\n"
    "    out[2] = *s;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i87-intel-stale-reload";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSString *why = nil;
        id<MTLComputePipelineState> ps = reproComputePipeline(dev, source, nil, &why);
        if (!ps) return FAIL(bug, "%s", why.UTF8String);
        const int32_t memoryStart[4] = {kFirst, kSecond, kFirst, kSecond}, indices[2] = {0, 1};
        id<MTLBuffer> memory = [dev newBufferWithBytes:memoryStart length:sizeof memoryStart options:MTLResourceStorageModeShared];
        id<MTLBuffer> index = [dev newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kResults * sizeof(int32_t) options:MTLResourceStorageModeShared];
        memset(out.contents, 0xee, out.length);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:memory offset:0 atIndex:0];
        [ce setBuffer:index offset:0 atIndex:1];
        [ce setBuffer:out offset:0 atIndex:2];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const int32_t *o = out.contents;
        const int32_t want[kResults] = {kFirst + 1, kSecond + 1, kFirst + 1};
        const char *what[kResults] = {"*p after incrementing *p and *q", "*p after swapping *p and *q", "threadgroup *s after incrementing *s and *t"};
        for (int i = 0; i < kResults; i++)
            if (o[i] != want[i]) return FAIL(bug, "%s: %s read %d, want %d", name, what[i], o[i], want[i]);
        return PASS(bug, "%s: loads after stores through pointers that may alias read the stored values", name);
    }
}
