// i75-intel-ivb-byte-halfwords: as_type<short2>(uchar4 & uchar4) must keep its bytes; Ivy Bridge's iCBE read a byte as
// 0 where the AND zeroed another. Fix: IntelTextureAtomics INTEL_BYTE_HALFWORDS_FIX.
// Checks: two generated kernels (a shifted uchar4 must stay as is), hash vs the CPU. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    uint v0 = in[t * 4u + 0u] + t;\n"
    "    uint v4 = in[t * 4u + 0u] * 9u + t;\n"
    "    short2 s = as_type<short2>(uchar4((uchar)(v0), (uchar)(in[t * 4u + 2u] >> 7u), (uchar)((v0 ^ t) / 877485583u), (uchar)(madhi(v0 ^ t, v4 ^ t, v0)))\n"
    "                               & uchar4((uchar)(min(172, (int)(in[t * 4u + 2u]))), (uchar)(0u), pc[(v4 ^ t) & 7u], (uchar)(28u)));\n"
    "    out[t * 8u + 0u] = ((uint)(s.x) ^ ((uint)(s.y) * 257u)) & 255u;\n"
    "}\n";

// Runs kernel k of a fuzzer kernel source on inputs 1-3 and compares each output hash with the CPU's; null if all match.
static NSString *check(id<MTLDevice> dev, id<MTLCommandQueue> queue, NSString *source, const uint32_t expected[3]) {
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:options error:&err];
    if (!lib) return [NSString stringWithFormat:@"compile: %@", err.localizedDescription];
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return [NSString stringWithFormat:@"pipeline: %@", err.localizedDescription];
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    for (unsigned s = 0; s < 3; s++) {
        uint32_t x = (s + 1) * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        memset(output.contents, 0xcd, T * 32);
        if (!reproDispatch(queue, ps, @[input, output], MTLSizeMake(4, 1, 1), MTLSizeMake(64, 1, 1)))
            return @"command buffer failed";
        uint32_t h = 2166136261u;
        const uint32_t *o = output.contents;
        for (unsigned i = 0; i < T * 8; i++)
            for (unsigned b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != expected[s]) return [NSString stringWithFormat:@"input %u: output hash %08x, the CPU's %08x", s + 1, h, expected[s]];
    }
    return nil;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i75-intel-ivb-byte-halfwords";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // FNV-1a of the 2048 output bytes' words, from the kernels run on the CPU (the fuzzer's cpuref.py) on inputs 1-3
    const uint32_t expected[] = {0xae5064dd, 0xa6514841, 0x947de405};
    NSString *wrong = check(dev, queue, src, expected);
    if (wrong) return FAIL(bug, "%s", wrong.UTF8String);
    NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
    NSString *fuzz = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i75-vec-fuzz-2598.metal"]
                                               encoding:NSUTF8StringEncoding error:nil];
    if (!fuzz) return SKIP(bug, "data/i75-vec-fuzz-2598.metal missing (run build.sh)");
    const uint32_t expected2598[] = {0x3660f1f4, 0x92b4fa0d, 0xcb2d0f4e};
    wrong = check(dev, queue, fuzz, expected2598);
    if (wrong) return FAIL(bug, "VEC seed 2598: %s", wrong.UTF8String);
    return PASS(bug, "a short2 viewed from a uchar4 AND with a zero byte, and VEC seed 2598: match the CPU on 3 inputs");
}}
