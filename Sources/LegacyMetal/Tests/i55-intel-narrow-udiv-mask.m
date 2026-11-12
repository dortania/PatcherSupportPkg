// i55-intel-narrow-udiv-mask (Intel adapter, INTEL_NARROW_SHIFT_FIX): a byte-masked lane divided as a ushort.
// ushort4(..., (ushort)(uchar)x) / (ushort4(...) | 1) reached the back end as AND x, 255 divided (UDIV) by 1 and masked with
// 0xFFFF in a vector, and iCBE dropped the 255 as in i29: the lane kept bits 8-15 of x (mslfuzz2 VEC=1 seed 4614,
// reduced; the stock compiler is wrong too). i46's 32-bit AND now also covers UDIV operands. 256 threads on five inputs,
// against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], c = in[t * 4u + 2u] * 5u + t, d = in[t * 4u] * 9u + t;\n"
    "    ushort4 n = ushort4((ushort)0, (ushort)(b >> 3), (ushort)(38u | c), (ushort)(uint)(uchar)(d ^ t));\n"
    "    ushort4 q = n / (ushort4((ushort)(a / (b | 1u)), (ushort)0, (ushort)0, (ushort)0) | ushort4((ushort)1));\n"
    "    ushort4 m = max(ushort4((ushort)0, (ushort)(b & ~a), (ushort)0, (ushort)1), q);\n"
    "    out[t] = (uint(m.x) * 1u) ^ (uint(m.y) * 257u) ^ (uint(m.z) * 65599u) ^ (uint(m.w) * 16777619u);\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t a = in[t * 4], b = in[t * 4 + 1], c = in[t * 4 + 2] * 5u + t, d = in[t * 4] * 9u + t;
    uint16_t n[4] = {0, (uint16_t)(b >> 3), (uint16_t)(38u | c), (uint16_t)(uint8_t)(d ^ t)};
    uint16_t dv[4] = {(uint16_t)((uint16_t)(a / (b | 1u)) | 1), 1, 1, 1}, o[4] = {0, (uint16_t)(b & ~a), 0, 1}, m[4];
    for (int i = 0; i < 4; i++) { uint16_t q = n[i] / dv[i]; m[i] = o[i] > q ? o[i] : q; }
    return (uint32_t)m[0] ^ ((uint32_t)m[1] * 257u) ^ ((uint32_t)m[2] * 65599u) ^ ((uint32_t)m[3] * 16777619u);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i55-intel-narrow-udiv-mask";
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
    return PASS(bug, "a byte-masked ushort lane divided by 1 keeps its mask: every thread matches the CPU (256 threads, 5 inputs)");
}}
