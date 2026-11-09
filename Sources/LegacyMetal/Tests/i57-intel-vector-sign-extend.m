// i57-intel-vector-sign-extend (Intel adapter, INTEL_SIGN_EXTEND_FIX): a vector STOI. In this generated kernel (mslfuzz2
// VEC=1 seed 4647, reduced: data/i57-vec-fuzz-4647.metal), max(short4(constants) & short4(0, 0, pc[i], b), ...) reached
// the back end as a whole-vector STOI of the AND, read lane by lane by the max, and one thread in 256 got its vf() hash
// of the vector wrong (the stock compiler is right here; any of i07, i22, i36 or i38 changing the code around it brings
// it out). i45's shift pairs now cover vector STOI / BTOI too. Runs the kernel as the fuzzer did, on three inputs, and
// compares the hash of the output with the same code run on the CPU. Fixed: PASS. Argument: GPU name substring
// (default: Intel).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i57-intel-vector-sign-extend";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i57-vec-fuzz-4647.metal"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!src) return SKIP(bug, "data/i57-vec-fuzz-4647.metal missing (run build.sh)");
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
    const uint32_t expected[] = {0x18b19144, 0xdf1c9435, 0x4d1a5b30};
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
    return PASS(bug, "a short4 max of masked lanes in the generated kernel: matches the CPU on 3 inputs");
}}
