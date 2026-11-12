// i56-intel-constant-saturation-chain (Intel adapter, INTEL_CONSTANT_CALL_FIX): a saturating add of constants that
// only become constant after another call is folded. extract_bits(65599u, 0u, addsat(~1u, hadd(65536u, 36u)) & 15u) is
// 63, but the back end folded the addsat as a plain add once hadd's value was known, so the bit count came out 0 and
// nothing was subtracted (mslfuzz2 VEC=1 seed 4630, reduced; the stock compiler too). hadd / rhadd and add_sat / sub_sat
// of scalar constants are folded in the IR along with i36's calls, until nothing changes. 256 threads on five inputs,
// against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v = in[t * 4u] * 9u + t;\n"
    "    v -= extract_bits(65599u, 0u, addsat(~1u, hadd(65536u, 36u)) & 15u);\n"
    "    v ^= (uint)rhadd(4294967295u, 5u) + subsat(3u, 7u) * 3u + (uint)addsat(2147483647, hadd(-8, 3));\n"
    "    out[t] = v;\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t v = in[t * 4] * 9u + t;
    v -= 65599u & 0x7fffu;  // addsat(0xfffffffe, 32786) = 0xffffffff, & 15 = 15 bits
    v ^= 2147483650u + 0u * 3u + 2147483644u;  // rhadd(0xffffffff, 5) = 0x80000002; subsat(3, 7) = 0; hadd(-8, 3) = -3, addsat(INT_MAX, -3)
    return v;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i56-intel-constant-saturation-chain";
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
    return PASS(bug, "saturating adds of folded constants saturate: every thread matches the CPU (256 threads, 5 inputs)");
}}
