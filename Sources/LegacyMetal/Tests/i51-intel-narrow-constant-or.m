// i51-intel-narrow-constant-or (Intel adapter, INTEL_NARROW_CONSTANT_LANES_FIX): a narrow vector ORed with constant lanes
// in a min / max. With i22 widening max(uchar2, uchar2) to 32-bit lanes, uchar2(0, b) | uchar2(199, 32) reached the
// back end as an OR with MOV r, -57: the constant 199 sign-extended, as in i35, and the max came out 0xffffffc7, so it
// always picked 199 over bytes 200-255 (mslfuzz2 VEC=1 seed 2464, reduced; the stock compiler is wrong too). The
// extension to 32-bit lanes goes through AND / OR / XOR with a constant operand, the constant lanes zero-extended.
// 256 threads on five inputs, against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name
// substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u + 3u], b = in[t * 4u] + t;\n"
    "    uchar2 m = max(uchar2((uchar)a, (uchar)0) ^ uchar2((uchar)1, (uchar)0), uchar2((uchar)0, (uchar)(b & 6u)) | uchar2((uchar)199, (uchar)32));\n"
    "    out[t] = uint(m.x) | (uint(m.y) << 8u);\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t a = in[t * 4 + 3], b = in[t * 4] + t;
    uint8_t x0 = (uint8_t)a ^ 1, y0 = 0, x1 = 199, y1 = (uint8_t)(b & 6u) | 32;
    return (uint32_t)(x0 > x1 ? x0 : x1) | ((uint32_t)(y0 > y1 ? y0 : y1) << 8);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i51-intel-narrow-constant-or";
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
    return PASS(bug, "a uchar2 ORed with constant lanes in a max: every thread matches the CPU (256 threads, 5 inputs)");
}}
