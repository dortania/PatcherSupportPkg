// i52-intel-narrow-divide-copy (Intel adapter, INTEL_NARROW_SHIFT_FIX): a byte-masked value that reaches a signed divide
// through vector copies. short3(..., (short)(uint)pc[0], ...) / short3(..., 1, ...) put the AND 255 of pc[0] into a vector
// lane (MOV_SWZ), and the back end's IDIV read the lane, moved back out, as a signed byte: bytes 128-255 came out
// negative, and any(q < 0) picked the wrong lane of a store (mslfuzz2 VEC=1 seed 2387, reduced; the stock compiler is
// wrong too). i46's 32-bit AND now also covers registers that reach a min / max or signed operation through MOV and
// MOV_SWZ copies. 256 threads on five inputs, against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u] * 11u + t, c = in[t * 4u + 2u] * 5u + t;\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    short3 n = short3((short)b, (short)(uint)pc[0], (short)b);\n"
    "    short3 d = (short3((short)0, (short)0, (short)(uint)(uchar)c) & short3((short)32767)) | short3((short)1);\n"
    "    uint4 w = uint4(0u, a, 0u, c);\n"
    "    w[(uint)any(n / d < (short)0) & 3u] = 0u;\n"
    "    out[t] = w.x ^ (w.y << 1u) ^ w.w;\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t a = in[t * 4], b = in[t * 4 + 1] * 11u + t, c = in[t * 4 + 2] * 5u + t;
    int16_t n[3] = {(int16_t)b, (int16_t)(uint8_t)in[t * 4], (int16_t)b}, d[3] = {1, 1, (int16_t)(((uint8_t)c & 32767) | 1)};
    int negative = 0;
    for (int i = 0; i < 3; i++) negative |= (int16_t)(n[i] / d[i]) < 0;
    uint32_t w[4] = {0, a, 0, c};
    w[negative & 3] = 0;
    return w[0] ^ (w[1] << 1) ^ w[3];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i52-intel-narrow-divide-copy";
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
    return PASS(bug, "a byte divided in a short3 picks the right lane: every thread matches the CPU (256 threads, 5 inputs)");
}}
