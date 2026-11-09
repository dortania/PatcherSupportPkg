// i45-intel-sign-extend-merge (Intel adapter, INTEL_SIGN_EXTEND_FIX): a sign-extended short merged with a 32-bit value.
// iCBE keeps the result of STOI (a short sign-extended to 32 bits) in a 16-bit register and extends it where it is read;
// here uint(short) is XORed into a vector lane, a store at a variable index merges that lane (MOV_CND) with a 32-bit
// value, and a read at another variable index got the lane zero-extended: 0x0000fe13 for 0xfffffe13, in 26 of 256
// threads. Found by differential fuzzing (mslfuzz2 VEC=1 seed 1865, reduced; it also fixed seeds 1040 and 1435). STOI and
// BTOI are written as shift pairs in the IGIL text. 256 threads on five inputs, against the same code on the CPU. Stock
// OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v2 = in[t * 4u + 2u] * 5u + t, v4 = in[t * 4u] * 9u + t;\n"
    "    uint a = vf(((short2((short)((in[t * 4u] >= in[t * 4u + 1u] ? 31u : 163u)), (short)((uint)((ushort)(v4)))) >>\n"
    "                 (short2((short)(-25688), (short)(4454)) & short2((short)15, (short)15)))).yx);\n"
    "    uint4 w = uint4(a, v2, 7u, v4);\n"
    "    w[in[t * 4u + 1u] & 3u] = in[t * 4u + 2u];\n"
    "    out[t] = w[(v2 ^ t) & 3u];\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t v2 = in[t * 4 + 2] * 5u + t, v4 = in[t * 4] * 9u + t;
    // the short2 shifted by (-25688 & 15, 4454 & 15) = (8, 6), then swizzled .yx: x is (short)(31 or 163) >> 8 = 0
    int16_t y = (int16_t)(uint16_t)v4 >> 6;
    uint32_t a = (uint32_t)(int32_t)y ^ (0u * 257u);
    uint32_t w[4] = {a, v2, 7u, v4};
    w[in[t * 4 + 1] & 3] = in[t * 4 + 2];
    return w[(v2 ^ t) & 3];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i45-intel-sign-extend-merge";
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
    return PASS(bug, "a sign-extended short merged with 32-bit lanes: every thread matches the CPU (256 threads, 5 inputs)");
}}
