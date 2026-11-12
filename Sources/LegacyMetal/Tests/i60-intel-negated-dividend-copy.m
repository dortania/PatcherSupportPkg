// i60-intel-negated-dividend-copy (Intel adapter, INTEL_SIGNED_DIV_NEG_FIX): a negated value that reaches a signed divide
// through copies. In this generated kernel (mslfuzz2 LONG=1 seed 2592, reduced: data/i60-long-fuzz-2592.metal), case 0 of
// a switch sets v2 = -(int)x and falls through into a loop that the back end made a subroutine; the loop's (int)v2 % 65535
// read a copy of a copy of the negation, and iCBE got the remainder wrong as in i26: 0 instead of -1, so the bit count of
// an insert_bits was 0 and the result 0 (the stock compiler is wrong too). i26's rewrite of the negation now follows MOV
// copies, merges included, from the IDIV operands. Runs the kernel as the fuzzer did, on three inputs, and compares the
// hash of the output with the same code run on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring
// (default: Intel).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i60-intel-negated-dividend-copy";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSString *dir = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"data"];
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"i60-long-fuzz-2592.metal"]
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!src) return SKIP(bug, "data/i60-long-fuzz-2592.metal missing (run build.sh)");
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
    const uint32_t expected[] = {0x1cb0168e, 0x6759c4b6, 0x68c87a3c};
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
    return PASS(bug, "a negated value divided in a loop after a switch: matches the CPU on 3 inputs");
}}
