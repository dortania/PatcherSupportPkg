// c05-amdil-bfe-constant (libAMDIL902 patch 6; AMD GCN on the 12.5 stack): a bit-field extract combine that reads the
// operands of a folded constant. While combining the selection DAG, ILTargetLowering::AnalyzeBFECombine matches shift
// and mask patterns, and in one of them reads operand 0 of a node it expects to be an operation; when that node has been
// folded into a constant, which has no operands, it reads through a null operand list and the compiler service crashes
// ("Compiler encountered an internal error"). Here a byte shifted by a variable amount is taken modulo a value that
// becomes 1 only once the loop before it is unrolled and folded, and indexes a private byte array. Found by fuzzing.
// Patches 1-5 alone: FAIL (no pipeline; in-process, the compiler takes the test down). Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    uint a = in[t * 4u], b = in[t * 4u + 1u], c = in[t * 4u + 2u];\n"
    "    uint v = c;\n"
    "    for (uint i = 0; i < 4u; i++)\n"
    "        if (i == 0u) v = (uint)max((int)i, (int)i / (int)(a | 1u));\n"
    "    pc[((uchar)((uchar)b >> (c & 7u)) % (uchar)((v / ((v ^ t) | 1u)) | 1u)) & 7u] = (uchar)a;\n"
    "    out[t] = (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^\n"
    "             (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "}\n";

enum { N = 256 };

// The kernel in C: the loop leaves v = max(0, 0 / (a | 1)) = 0, so the index is (byte % 1) & 7 = 0.
static uint32_t reference(const uint32_t *in, uint32_t t) {
    uint8_t pc[8];
    for (uint32_t j = 0; j < 8; j++) pc[j] = (uint8_t)(in[t * 4 + (j & 3)] >> j);
    uint32_t a = in[t * 4], b = in[t * 4 + 1], c = in[t * 4 + 2], v = c;
    for (uint32_t i = 0; i < 4; i++)
        if (i == 0) v = (uint32_t)((int32_t)i > (int32_t)i / (int32_t)(a | 1) ? (int32_t)i : (int32_t)i / (int32_t)(a | 1));
    pc[((uint8_t)((uint8_t)b >> (c & 7)) % (uint8_t)((v / ((v ^ t) | 1)) | 1)) & 7] = (uint8_t)a;
    return ((uint32_t)pc[0] | ((uint32_t)pc[1] << 8) | ((uint32_t)pc[2] << 16) | ((uint32_t)pc[3] << 24)) ^
           (pc[4] * 3u + pc[5] * 5u + pc[6] * 7u + pc[7] * 11u);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "c05-amdil-bfe-constant";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "front end: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLBuffer> in = [dev newBufferWithLength:N * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        uint32_t *words = in.contents, x = 0x2545F491;
        for (int i = 0; i < N * 4; i++) words[i] = x = x * 1664525u + 1013904223u;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setBuffer:in offset:0 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const uint32_t *got = out.contents;
        int wrong = 0, first = -1;
        for (uint32_t t = 0; t < N; t++)
            if (got[t] != reference(words, t)) wrong++, first = first < 0 ? (int)t : first;
        if (wrong)
            return FAIL(bug, "%s: %d of %d results wrong (thread %d: %08x, want %08x)", dev.name.UTF8String, wrong, N, first,
                        got[first], reference(words, (uint32_t)first));
        return PASS(bug, "%s: the kernel compiles and its %d results are right", dev.name.UTF8String, N);
    }
}
