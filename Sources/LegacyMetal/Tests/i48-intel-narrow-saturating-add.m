// i48-intel-narrow-saturating-add: a 32-bit addsat of two masked values must add this thread's values; iCBE read them
// from other SIMD lanes. Fix: IntelTextureAtomics INTEL_NARROW_SHIFT_FIX, INTEL_LATE_SAT_FIX.
// Checks: addsat(x & 1, y & 255), 256 threads on five inputs vs the CPU. Argument: GPU name.
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 4u] * 9u + t, b = in[t * 4u + 1u] * 11u + t;\n"
    "    for (uint i = 0; i < 5u; i++)\n"
    "        a += addsat((uint)all(char4(0) == char4((char)0, (char)0, (char)1, (char)extract_bits(a ^ t, 0u, 1u))), (uint)(uchar)(b ^ t));\n"
    "    out[t] = a;\n"
    "}\n";

static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint32_t a = in[t * 4] * 9u + t, b = in[t * 4 + 1] * 11u + t;
    for (int i = 0; i < 5; i++) a += (uint8_t)(b ^ t);  // the all() is false (lane 2 compares 0 with 1), addsat(0, x) = x
    return a;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i48-intel-narrow-saturating-add";
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
        if (!reproDispatch(queue, ps, @[input, output], MTLSizeMake(4, 1, 1), MTLSizeMake(64, 1, 1)))
            return FAIL(bug, "command buffer failed");
        int wrong = 0, first = -1;
        for (unsigned t = 0; t < T; t++)
            if (((uint32_t *)output.contents)[t] != reference(in, t) && !wrong++) first = (int)t;
        if (wrong)
            return FAIL(bug, "%d of 256 threads wrong on input %u (thread %d: %08x, want %08x)", wrong, seeds[s], first,
                        ((uint32_t *)output.contents)[first], reference(in, (uint32_t)first));
    }
    return PASS(bug, "a saturating add of two masked values: every thread matches the CPU (256 threads, 5 inputs)");
}}
