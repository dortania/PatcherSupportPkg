// n01-kepler-count-of-zero (Kepler adapter, NVAIR_COUNT_ZERO_FIX): clz and ctz of a constant 0 on OCLP's Kepler compiler
// (GeForceAIRPlugin). MSL gives the width (clz(0u) == 32), and the GPU does too at run time, but the plugin's built-in
// library writes air.clz.i32 as llvm.ctlz.i32(x, true), "undefined for 0", so where the optimizer sees a constant 0 it
// folds the count to undef: madhi(v, clz(0u), 0u) came out as garbage (mslfuzz2 seed 758, plain kernels, reduced; all 14
// kernels of seeds 1-1000 that the GTX 770 got wrong were this). Checks clz and ctz of constant 0 in uint, ushort, uchar,
// ulong and a vector, used as operands, in 256 threads on five inputs against the same code on the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v4 = in[t * 4u] * 9u + t, v1 = in[t * 4u + 1u] * 3u + t;\n"
    "    out[t * 4u] = madhi(v4, clz(0u), 0u);\n"  // seed 758, reduced
    "    out[t * 4u + 1u] = mulhi(v1, ctz(0u)) ^ (uint(clz(ushort(0))) << 8u) ^ (uint(clz(uchar(0))) << 16u) ^ (uint(ctz(ushort(0))) << 24u);\n"
    "    ulong c = ulong(v1) * clz(0ul);\n"
    "    out[t * 4u + 2u] = uint(c) ^ uint(c >> 32u);\n"
    "    uint2 d = clz(uint2(0u, v4 | 1u));\n"
    "    out[t * 4u + 3u] = d.x * 1000u + d.y;\n"
    "}\n";

static void reference(const uint32_t *in, uint32_t t, uint32_t out[4]) {
    uint32_t v4 = in[t * 4] * 9u + t, v1 = in[t * 4 + 1] * 3u + t;
    out[0] = (uint32_t)(((uint64_t)v4 * 32u) >> 32);
    out[1] = (uint32_t)(((uint64_t)v1 * 32u) >> 32) ^ (16u << 8) ^ (8u << 16) ^ (16u << 24);
    uint64_t c = (uint64_t)v1 * 64u;
    out[2] = (uint32_t)c ^ (uint32_t)(c >> 32);
    out[3] = 32u * 1000u + (uint32_t)__builtin_clz(v4 | 1u);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n01-kepler-count-of-zero";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    static const char *const kWhat[4] = {"madhi(v, clz(0u), 0u)", "mulhi with ctz(0u), clz/ctz of 0 in ushort and uchar",
                                         "a product with clz(0ul)", "clz(uint2(0u, x))"};
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
        const uint32_t *got = output.contents;
        for (unsigned t = 0; t < T; t++) {
            uint32_t want[4];
            reference(in, t, want);
            for (int w = 0; w < 4; w++)
                if (got[t * 4 + w] != want[w])
                    return FAIL(bug, "%s: %s wrong on input %u (thread %u: %08x, want %08x)", dev.name.UTF8String, kWhat[w], seeds[s], t,
                                got[t * 4 + w], want[w]);
        }
    }
    return PASS(bug, "%s: clz and ctz of a constant 0 give the width (uint, ushort, uchar, ulong, uint2; 256 threads, 5 inputs)",
                dev.name.UTF8String);
}}
