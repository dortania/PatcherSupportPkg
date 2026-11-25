// i88-intel-narrow-vector-insert: an insert at a run-time index into a vector of bools, bytes or halfwords must compile;
// the Intel back end aborted on the vector select it made of it. Fix: IntelTextureAtomics INTEL_NARROW_VECTOR_INSERT_FIX.
// Checks: bool2, bool4, char2 and ushort4 lanes set at a run-time index read back right. Argument: GPU name.
#import "repro.h"

enum { kLane = 1, kValue = 7, kResults = 12 };

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "    uint lane = in[0];\n"
    "    bool2 b2 = bool2(false);\n"
    "    b2[lane] = in[1] != 0;\n"
    "    bool4 b4 = bool4(false);\n"
    "    b4[lane] = in[1] != 0;\n"
    "    char2 c2 = char2(0);\n"
    "    c2[lane] = char(in[1]);\n"
    "    ushort4 s4 = ushort4(0);\n"
    "    s4[lane] = ushort(in[1]);\n"
    "    out[0] = b2[0]; out[1] = b2[1];\n"
    "    for (int i = 0; i < 4; i++) out[2 + i] = b4[i];\n"
    "    out[6] = uint(c2[0]); out[7] = uint(c2[1]);\n"
    "    for (int i = 0; i < 4; i++) out[8 + i] = s4[i];\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i88-intel-narrow-vector-insert";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSString *why = nil;
        id<MTLComputePipelineState> ps = reproComputePipeline(dev, source, nil, &why);
        if (!ps) return FAIL(bug, "%s", why.UTF8String);
        const uint32_t inputs[2] = {kLane, kValue};
        id<MTLBuffer> in = [dev newBufferWithBytes:inputs length:sizeof inputs options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kResults * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(out.contents, 0xee, out.length);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        const uint32_t want[kResults] = {0, 1, 0, 1, 0, 0, 0, kValue, 0, kValue, 0, 0};
        const char *vector[kResults] = {"bool2", "bool2", "bool4", "bool4", "bool4", "bool4", "char2", "char2", "ushort4", "ushort4", "ushort4", "ushort4"};
        const int lane[kResults] = {0, 1, 0, 1, 2, 3, 0, 1, 0, 1, 2, 3};
        for (int i = 0; i < kResults; i++)
            if (o[i] != want[i]) return FAIL(bug, "%s: %s lane %d read %u, want %u", name, vector[i], lane[i], o[i], want[i]);
        return PASS(bug, "%s: lanes of bool, byte and halfword vectors set at a run-time index compile and read right", name);
    }
}
