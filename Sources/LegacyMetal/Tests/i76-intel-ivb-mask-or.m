// i76-intel-ivb-mask-or: a byte mask reaching a 16-bit one through an OR iCBE folds itself must keep only the byte;
// iCBE dropped the 255, as in i29. Fix: IntelTextureAtomics INTEL_MASK_OR_FIX.
// Checks: any(a > b), b's halves built from bytes with min3 and a shift, hash vs the CPU. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    uint v0 = in[t * 4u + 0u] + t;\n"
    "    uint v1 = in[t * 4u + 1u] * 3u + t;\n"
    "    uint v3 = in[t * 4u + 3u] * 7u + t;\n"
    "    uint v4 = in[t * 4u + 0u] * 9u + t;\n"
    "    uint v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    ushort2 a = ushort2((ushort)(extract_bits(65535u, 10u, in[t * 4u + 2u] & 15u)), (ushort)(((v5 ^ t) & 1u) != 0u ? 60u : in[t * 4u + 2u]))\n"
    "              & ushort2((ushort)(pc[(v3 ^ t) & 7u]), (ushort)(min(v4, in[t * 4u + 0u])));\n"
    "    ushort2 b = ushort2((ushort)((uint)(uchar)(madsat(v0, v4, in[t * 4u + 1u])) | ((uint)(uchar)(mulhi(65536u, 210u)) << 8u)),\n"
    "                        (ushort)((uint)(uchar)((v3 ^ t) % (v1 | 1u)) | ((uint)(uchar)(min3(v5 ^ t, 0u, 145u)) << 8u)));\n"
    "    out[t * 8u + 0u] = (uint)(any(a > b));\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i76-intel-ivb-mask-or";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // FNV-1a of the 2048 output bytes' words, from the kernel run on the CPU (the fuzzer's cpuref.py) on inputs 1-3
    const uint32_t expected[] = {0x83786184, 0xc5dd8544, 0x77fce7e5};
    for (unsigned s = 0; s < 3; s++) {
        uint32_t x = (s + 1) * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        memset(output.contents, 0xcd, T * 32);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:input offset:0 atIndex:0];
        [ce setBuffer:output offset:0 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "command buffer failed");
        uint32_t h = 2166136261u;
        const uint32_t *o = output.contents;
        for (unsigned i = 0; i < T * 8; i++)
            for (unsigned b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != expected[s]) return FAIL(bug, "input %u: output hash %08x, the CPU's %08x", s + 1, h, expected[s]);
    }
    return PASS(bug, "a ushort2 compare with a byte lane masked through a folded OR: matches the CPU on 3 inputs");
}}
