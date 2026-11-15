// i75-intel-ivb-byte-halfwords (Intel adapter, INTEL_BYTE_HALFWORDS_FIX): bytes viewed as halfwords on Ivy Bridge.
// as_type<short2>(uchar4 & uchar4) reaches the back end as a vector AND, BPACK of the four bytes into a word and SUNPACK
// of its halves, and Ivy Bridge's iCBE read the low byte of .y as 0 when the AND makes byte 1 a known 0: in
// (uint(s.x) ^ uint(s.y) * 257) & 255, byte 2 (a quotient of at most 4, ANDed with a private array byte) was lost in
// about a third of the threads (reduced from mslfuzz2 VEC seed 23 on an HD 4000; the stock compiler too, Haswell's is
// right). The IR and the IGIL text are right. The adapter puts such halfwords together from the bytes with shifts. Runs
// the kernel as the fuzzer did, on three inputs, and compares the hash of the output with the same code run on the CPU.
// Stock OCLP on an HD 4000: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    uint v0 = in[t * 4u + 0u] + t;\n"
    "    uint v4 = in[t * 4u + 0u] * 9u + t;\n"
    "    short2 s = as_type<short2>(uchar4((uchar)(v0), (uchar)(in[t * 4u + 2u] >> 7u), (uchar)((v0 ^ t) / 877485583u), (uchar)(madhi(v0 ^ t, v4 ^ t, v0)))\n"
    "                               & uchar4((uchar)(min(172, (int)(in[t * 4u + 2u]))), (uchar)(0u), pc[(v4 ^ t) & 7u], (uchar)(28u)));\n"
    "    out[t * 8u + 0u] = ((uint)(s.x) ^ ((uint)(s.y) * 257u)) & 255u;\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i75-intel-ivb-byte-halfwords";
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
    const uint32_t expected[] = {0xae5064dd, 0xa6514841, 0x947de405};
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
    return PASS(bug, "a short2 viewed from a uchar4 AND with a zero byte: matches the CPU on 3 inputs");
}}
