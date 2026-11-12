// i58-intel-constant-min3 (Intel adapter, INTEL_CONSTANT_CALL_FIX): min3 / max3 / median3 of constants read as bytes.
// The back end folds these calls itself and then, as for i36's min / max, read every byte of the folded value as byte 0
// when it was reinterpreted (as_type<uchar4>(as_type<ushort2>(min3(240u, 239u, 177u)))): the hash of the bytes came out
// 0xb1b08c2c instead of 0xb1 (mslfuzz2 VEC=1 seed 5854, reduced; the stock compiler too). They're folded in the IR with
// i36's calls. 256 threads on five inputs, against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument:
// GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(uchar4 v) { return uint(v.x) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v = in[t * 4u] * 9u + t;\n"
    "    v ^= vf(as_type<uchar4>(as_type<ushort2>(min3(240u, 239u, 177u))));\n"
    "    v += vf(as_type<uchar4>(max3(0x01020304u, 0x0a0b0c0du, 0x05060708u))) * 3u;\n"
    "    v -= vf(as_type<uchar4>((uint)median3(-5, 0x11223344, 0x00ff00ff)));\n"
    "    out[t] = v;\n"
    "}\n";

static uint32_t vfb(uint32_t x) { return (x & 255) ^ (((x >> 8) & 255) * 257u) ^ (((x >> 16) & 255) * 65599u) ^ ((x >> 24) * 16777619u); }
static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t v = in[t * 4] * 9u + t;
    v ^= vfb(177u);
    v += vfb(0x0a0b0c0du) * 3u;
    v -= vfb(0x00ff00ffu);  // median of -5, 0x11223344, 0x00ff00ff (signed)
    return v;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i58-intel-constant-min3";
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
    return PASS(bug, "min3 / max3 / median3 of constants read as bytes: every thread matches the CPU (256 threads, 5 inputs)");
}}
