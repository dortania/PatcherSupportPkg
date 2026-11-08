// i40-intel-narrow-shift-merge (Intel adapter, INTEL_NARROW_SHIFT_FIX): a right shift of a narrow value merged with a
// 32-bit value of the same variable. iCBE gives SHR / SAR of a constant below 65536, or of x & 255 / x & 65535, a result
// register only as wide as that value, and can then merge it with the variable's other copies: v0 = (uint)(x / y),
// replaced in a loop by (uchar)1 >> s, came out as the quotient's low byte in every thread, also where the loop never
// replaced it, so the wrong private array slot was cleared. The same with (uchar)v4 (a byte) and with (ushort)v4 or
// 300 (16 bits). The adapter does such shifts on the value with bit 31 set and XORs the shifted bit 31 away. Found by
// differential fuzzing (mslfuzz2 LONG=1 seed 6, reduced; VEC=1 seed 526 is the same bug). 256 threads on five inputs,
// against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]]) {\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    uint v0 = in[(0u)] * 1u + t;\n"
    "    uint v1 = in[(0u)] * 3u + t;\n"
    "    uint v3 = in[(0u)] * 7u + t;\n"
    "    uint v4 = in[(0u)] * 9u + t;\n"
    "    uint v5 = in[(0u)] * 11u + t;\n"
    "    v0 = (uint)(((((ulong)(((1u) != 0u ? (in[(1u)] << (0u)) : (0u))) << 32) | (ulong)(0u))) / (((((ulong)((v3 ^ t)) << 32) | (ulong)(0u))) | 1ul));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        switch (((uint)((long)(1u) >> ((v1 ^ t) & 63u))) & 3u) {\n"
    "        case 1u: {\n"
    "            v0 = (uint)(%@ >> (insert_bits((uint)((bool)((v3 ^ t) & 29u)), (uint)(0u), (uint)(0u), (uint)(0u)) & 7u));\n"
    "            break; }\n"
    "        }\n"
    "        if (0u) break; } v1 += n0; }\n"
    "    p[((uint)((int)((~v0)) >> (int)((~v5) & 31u))) & 7u] = (uint)(0u);\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];\n"
    "}\n";

// the value shifted in the loop, as MSL and on the CPU
static NSString *const kShifted[] = {@"(uchar)(1u)", @"(uchar)(v4)", @"(ushort)(v4)", @"(uint)(300u)"};
static uint32_t shifted(int which, uint32_t v4) {
    switch (which) {
    case 0: return 1;
    case 1: return v4 & 255;
    case 2: return v4 & 65535;
    default: return 300;
    }
}

static uint32_t reference(int which, const uint32_t *in, uint32_t t) {
    uint32_t p[8];
    for (uint32_t j = 0; j < 8; j++) p[j] = in[t * 4 + (j & 3)] + j;
    uint32_t v1 = in[0] * 3u + t, v3 = in[0] * 7u + t, v4 = in[0] * 9u + t, v5 = in[0] * 11u + t;
    uint32_t v0 = (uint32_t)(((uint64_t)in[1] << 32) / (((uint64_t)(v3 ^ t) << 32) | 1ull));
    for (unsigned n = 0; n < 8; n++)
        if ((((uint32_t)(1ll >> ((v1 ^ t) & 63))) & 3) == 1) v0 = shifted(which, v4) >> (((v3 ^ t) & 29) != 0);
    p[((int32_t)~v0 >> (~v5 & 31)) & 7] = 0;
    return p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i40-intel-narrow-shift-merge";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    for (int which = 0; which < 4; which++) {
        const char *name = kShifted[which].UTF8String;
        NSError *err = nil;
        NSString *text = [reproUniqueComment() stringByAppendingString:[NSString stringWithFormat:src, kShifted[which]]];
        id<MTLLibrary> lib = [dev newLibraryWithSource:text options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        const unsigned seeds[] = {1, 2, 3, 7, 42};
        for (unsigned s = 0; s < sizeof seeds / sizeof *seeds; s++) {
            uint32_t x = seeds[s] * 2654435761u + 12345u, *in = input.contents;
            for (unsigned i = 0; i < T * 4; i++) {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                in[i] = i % 7 == 0 ? x & 255u : x;
            }
            memset(output.contents, 0xcd, T * 32);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:input offset:0 atIndex:0];
            [ce setBuffer:output offset:0 atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            int wrong = 0, first = -1;
            uint32_t got = 0, want = 0;
            for (unsigned t = 0; t < T; t++) {
                uint32_t expected = reference(which, in, t), result = ((uint32_t *)output.contents)[t * 8 + 6];
                if (result != expected && !wrong++) first = t, got = result, want = expected;
            }
            if (wrong)
                return FAIL(bug, "%s: %d of 256 threads wrong on input %u (thread %d: %08x, want %08x)", name, wrong, seeds[s],
                            first, got, want);
        }
    }
    return PASS(bug, "all four shifted values: every thread matches the CPU (256 threads, 5 inputs)");
}}
