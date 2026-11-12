// i46-intel-narrow-max-operand (Intel adapter, INTEL_NARROW_SHIFT_FIX): a byte-masked value in a 16-bit max. With i22
// widening max(short3, short3) to 32-bit lanes, the lane (short)(d & 255) reached the back end as IMAX r, 0, (d AND 255),
// and iCBE took the AND's narrow result as a signed byte: max(0, 200) came out 0, in 219 of 256 threads (mslfuzz2
// VEC=1 seed 1889, reduced; the stock compiler is right). An AND with a mask below 65536 that a min / max or a signed
// operation reads is done on 32 bits, as i40 does for merges. 256 threads on five inputs, against the same code on the
// CPU. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(short3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], c = in[t * 4u + 2u], d = in[t * 4u + 3u];\n"
    "    out[t] = vf(max(short3((short)(a & 1u), (short)0, (short)(b & 1u)),\n"
    "                    short3((short)(~c), (short)(d & 255u), (short)(a % 97u))));\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t a = in[t * 4], b = in[t * 4 + 1], c = in[t * 4 + 2], d = in[t * 4 + 3];
    int16_t x0 = (int16_t)(a & 1), y0 = 0, z0 = (int16_t)(b & 1);
    int16_t x1 = (int16_t)~c, y1 = (int16_t)(d & 255), z1 = (int16_t)(a % 97);
    int16_t x = x0 > x1 ? x0 : x1, y = y0 > y1 ? y0 : y1, z = z0 > z1 ? z0 : z1;
    return ((uint32_t)(int32_t)x * 1u) ^ ((uint32_t)(int32_t)y * 257u) ^ ((uint32_t)(int32_t)z * 65599u);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i46-intel-narrow-max-operand";
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
    return PASS(bug, "a byte-masked lane in a short3 max: every thread matches the CPU (256 threads, 5 inputs)");
}}
