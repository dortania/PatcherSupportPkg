// i49-intel-uniform-dependency (Intel adapter, INTEL_UNIFORM_DEPENDENCY_FIX): the Intel compiler's uniformity analysis
// reading past its map. IGILUniformAnalysis::getDependency returns the map entry of a value, and for an instruction the
// analysis hasn't reached yet reads past the end of the map's buckets; its match for sign extensions asks for an
// operand two levels below the instruction whose operands it checked. In this generated kernel (mslfuzz2 LONG=1 seed
// 741, data/i49-long-fuzz-741.metal) that is ashr (add %v3, %t), 31 before %t, a truncated 64-bit product, has an
// entry, and the map's buckets end at a page: the compiler crashed, the stock one too. Smaller kernels with the same
// read get garbage instead, so the kernel stays whole. Compiles and runs it as the fuzzer did, on three inputs, and
// compares the hash of the output with the same code run on the CPU. Stock OCLP: FAIL (crashed). Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i49-intel-uniform-dependency";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i49-long-fuzz-741.metal"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!src) return SKIP(bug, "data/i49-long-fuzz-741.metal missing (run build.sh)");
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
    const uint32_t expected[] = {0x68f6b81a, 0xcb1d0cad, 0x573992d6};
    for (unsigned s = 0; s < 3; s++) {
        uint32_t x = (s + 1) * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        memset(output.contents, 0xcd, T * 32);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:input offset:0 atIndex:0];
        [ce setBuffer:output offset:0 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "command buffer failed");
        uint32_t h = 2166136261u;
        const uint32_t *o = output.contents;
        for (unsigned i = 0; i < T * 8; i++)
            for (unsigned b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != expected[s]) return FAIL(bug, "input %u: output hash %08x, the CPU's %08x", s + 1, h, expected[s]);
    }
    return PASS(bug, "the generated 64-bit kernel compiles and matches the CPU on 3 inputs");
}}
