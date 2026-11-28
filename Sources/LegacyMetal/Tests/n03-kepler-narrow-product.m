// n03-kepler-narrow-product: a 32-bit product of two 16-bit factors can have its top bit set; the back end assumed it
// clear (and took an or with a product for an add). Fix: GeForceAIRCompat NVAIR_NARROW_MULTIPLY_FIX. Checks: both
// shapes, 256 threads on five inputs against the CPU. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u] | 0x8000u, b = in[t * 4u + 1u] | 0x8000u, c = in[t * 4u + 2u];\n"  // large 16-bit factors
    "    out[t * 4u] = (uint)(-(int)((~((uint)((ushort)(a)) * (uint)((ushort)(b)))) & 0x7fffffffu));\n"  // seed 111, reduced
    "    out[t * 4u + 1u] = (uint)(-(int)((~((a & 0xffffu) * (b & 0xffffu))) & 0x7fffffffu)) ^ c;\n"
    "    out[t * 4u + 2u] = ((uint(ushort(a)) * uint(ushort(c))) | 0x80000000u) + 1u;\n"
    "    out[t * 4u + 3u] = c % (((a | 1u) * b) | 1u);\n"  // seed 645, reduced
    "}\n";

static void reference(const uint32_t *in, uint32_t t, uint32_t out[4]) {
    uint32_t a = in[t * 4] | 0x8000u, b = in[t * 4 + 1] | 0x8000u, c = in[t * 4 + 2];
    uint32_t p = (uint32_t)(uint16_t)a * (uint32_t)(uint16_t)b;
    out[0] = (uint32_t)(-(int64_t)(~p & 0x7fffffffu));
    out[1] = (uint32_t)(-(int64_t)(~p & 0x7fffffffu)) ^ c;
    out[2] = (((uint32_t)(uint16_t)a * (uint32_t)(uint16_t)c) | 0x80000000u) + 1u;
    out[3] = c % (((a | 1u) * b) | 1u);
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n03-kepler-narrow-product";
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
    static const char *const kWhat[4] = {"-(int)(~(ushort * ushort) & 0x7fffffff)", "the same with 0xffff masks",
                                         "(ushort * ushort | 0x80000000) + 1", "c % (((a | 1) * b) | 1)"};
    const unsigned seeds[] = {1, 2, 3, 7, 42};
    for (unsigned s = 0; s < sizeof seeds / sizeof *seeds; s++) {
        uint32_t x = seeds[s] * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = x; }
        if (!reproDispatch(queue, ps, @[input, output], MTLSizeMake(4, 1, 1), MTLSizeMake(64, 1, 1))) return FAIL(bug, "command buffer failed");
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
    return PASS(bug, "%s: 32-bit products of 16-bit factors keep their top bit, and divisions by a product or 1 are right (256 threads, 5 inputs)", dev.name.UTF8String);
}}
