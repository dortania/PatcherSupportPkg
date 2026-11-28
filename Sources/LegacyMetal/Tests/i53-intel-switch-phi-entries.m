// i53-intel-switch-phi-entries: i12's flattening must keep one phi entry per case when a switch's cases share a block;
// it kept one and the IR verifier aborted the compiler. Fix: IntelTextureAtomics INTEL_BRANCH_CHAIN_FIX.
// Checks: a generated kernel (data/i53-*.metal), hash vs the CPU; passes without i12 too. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i53-intel-switch-phi-entries";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i53-vec-fuzz-2642.metal"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!src) return SKIP(bug, "data/i53-vec-fuzz-2642.metal missing (run build.sh)");
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // FNV-1a of the 2048 output bytes' words, from the kernel run on the CPU (the fuzzer's cpuref.py) on inputs 1-3
    const uint32_t expected[] = {0x75cee9e3, 0x349c04e5, 0x1be88728};
    for (unsigned s = 0; s < 3; s++) {
        uint32_t x = (s + 1) * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        memset(output.contents, 0xcd, T * 32);
        if (!reproDispatch(queue, ps, @[input, output], MTLSizeMake(4, 1, 1), MTLSizeMake(64, 1, 1)))
            return FAIL(bug, "command buffer failed");
        uint32_t h = 2166136261u;
        const uint32_t *o = output.contents;
        for (unsigned i = 0; i < T * 8; i++)
            for (unsigned b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != expected[s]) return FAIL(bug, "input %u: output hash %08x, the CPU's %08x", s + 1, h, expected[s]);
    }
    return PASS(bug, "the generated kernel with a switch compiles and matches the CPU on 3 inputs");
}}
