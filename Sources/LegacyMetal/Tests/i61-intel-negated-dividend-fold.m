// i61-intel-negated-dividend-fold (Intel adapter, INTEL_SIGNED_DIV_NEG_FIX): a negated value that reaches a signed divide
// through a subtraction iCBE folds away. v0 = -(int)(x & 0x7fffffff); v0 -= min(mulhi(..., 0u), 0u) leaves v0 as it was,
// and reaches the back end as IADD r80, r78, -r79 with r79 = UMIN of two zeros; iCBE folds that into a copy of the
// negation and the negation into the IDIV as a source modifier, which it drops as in i26: (int)v0 / d came out as
// (x & 0x7fffffff) / d, so the divisor built from it lost its sign and x % it was wrong in about half the threads (reduced
// from mslfuzz2 plain seed 7727; the stock compiler is wrong too). Every negation in a shader with an IDIV is now done as
// XOR and add. Runs the kernel as the fuzzer did, on three inputs, and compares the hash of the output with the same code
// run on the CPU. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v1 = in[t * 4u + 1u];\n"
    "    uint v2 = in[t * 4u + 2u] * 5u + t;\n"
    "    uint v3 = in[t * 4u + 3u] * 7u + t;\n"
    "    uint v0 = (uint)(-(int)(((uint)((int)((char)(in[t * 4u + 2u]))) - v2) & 0x7fffffffu));\n"
    "    uint v5 = mulhi(0u, insert_bits(v1, in[t * 4u + 3u], v0 & 15u, 0u));\n"
    "    v0 -= min(mulhi((uint)((ushort)(v5) >> ((v3 ^ t) & 7u)), (uint)((uchar)(v2))), 0u);\n"
    "    uint d = ((uint)((int)(v0) / (int)((in[t * 4u + 1u] | 1u) & 0x7fffffffu)) | 1u) & 0x7fffffffu;\n"
    "    out[t * 8u + 0u] = (uint)((int)(in[t * 4u + 0u] & 0xffffu) % (int)(d));\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i61-intel-negated-dividend-fold";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
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
    const uint32_t expected[] = {0xdbf12dbb, 0xf35436b2, 0x33387724};
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
    return PASS(bug, "a negation divided after a subtraction of zero: matches the CPU on 3 inputs");
}}
