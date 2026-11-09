// i59-intel-zero-width-bit-field (Intel adapter, INTEL_CONSTANT_CALL_FIX): extract_bits / insert_bits of 0 bits. MSL
// gives 0 and the base, but the back end lowers them with a shift by the width, which LLVM treats as poison and folds
// away: w[(uint)((long)(1u | extract_bits(v0, 0u, 0u)) >> s) & 3u] = 1u stored to w[1] in every thread, whatever s was
// (mslfuzz2 LONG=1 seed 2575, reduced; the stock compiler too). Calls with a constant bit count of 0 are folded in the
// IR. 256 threads on five inputs, against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name
// substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v0 = in[t * 4u] + t, v1 = in[t * 4u + 1u] * 3u + t, v3 = in[t * 4u + 3u] * 7u + t;\n"
    "    uint4 w = uint4(0u);\n"
    "    w[(uint)((long)(1u | (ulong)extract_bits(v0, 0u, 0u)) >> ((v1 ^ t) & 63u)) & 3u] = 1u;\n"
    "    v3 += w.x ^ (w.y << 1u) ^ w.w;\n"
    "    v3 ^= insert_bits(v1, v0, 5u, 0u);\n"
    "    out[t] = v3;\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t v0 = in[t * 4] + t, v1 = in[t * 4 + 1] * 3u + t, v3 = in[t * 4 + 3] * 7u + t;
    (void)v0;
    uint32_t s = (v1 ^ t) & 63u, w[4] = {0, 0, 0, 0};
    w[(uint32_t)((int64_t)1 >> s) & 3u] = 1;  // extract_bits of 0 bits is 0
    v3 += w[0] ^ (w[1] << 1) ^ w[3];
    v3 ^= v1;  // insert_bits of 0 bits is the base
    return v3;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i59-intel-zero-width-bit-field";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const unsigned seeds[] = {1, 2, 3, 7, 42};
    for (unsigned s = 0; s < sizeof seeds / sizeof *seeds; s++) {
        uint32_t x = seeds[s] * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:input offset:0 atIndex:0];
        [ce setBuffer:output offset:0 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "command buffer failed");
        int wrong = 0, first = -1;
        for (unsigned t = 0; t < T; t++)
            if (((uint32_t *)output.contents)[t] != reference(in, t) && !wrong++) first = (int)t;
        if (wrong)
            return FAIL(bug, "%d of 256 threads wrong on input %u (thread %d: %08x, want %08x)", wrong, seeds[s], first,
                        ((uint32_t *)output.contents)[first], reference(in, (uint32_t)first));
    }
    return PASS(bug, "bit fields of 0 bits: every thread matches the CPU (256 threads, 5 inputs)");
}}
