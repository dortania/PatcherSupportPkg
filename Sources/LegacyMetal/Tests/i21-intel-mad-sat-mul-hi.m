// i21-intel-mad-sat-mul-hi (Intel adapter, IntelTextureAtomics.dylib): madsat, mulhi and madhi on 32-bit integers. The
// 3802 back end lowers madsat without the carry out of its addition (madsat(a, 3u, b) returned the wrapped a * 3 + b
// instead of 0xffffffff for most inputs), and mulhi with a constant operand returned 0 (mulhi(a, 3u)); found by
// differential fuzzing (mslfuzz2: 162 of 195 disagreements). Runs unsigned and signed madsat, mulhi and madhi, with
// constant and variable operands, on 256 seeded inputs and compares with the same arithmetic on the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 3], b = in[t * 3 + 1], c = in[t * 3 + 2];\n"
    "    out[t * 8 + 0] = madsat(a, 3u, b);\n"
    "    out[t * 8 + 1] = madsat(a, b, c);\n"
    "    out[t * 8 + 2] = mulhi(a, 3u);\n"
    "    out[t * 8 + 3] = mulhi(a, b);\n"
    "    out[t * 8 + 4] = madhi(a, 7u, c);\n"
    "    out[t * 8 + 5] = (uint)madsat((int)a, (int)b, (int)c);\n"
    "    out[t * 8 + 6] = (uint)mulhi((int)a, -3);\n"
    "    uint2 v = madsat(uint2(a, b), uint2(5u, c), uint2(c, a));\n"
    "    out[t * 8 + 7] = v.x ^ v.y;\n"
    "}\n";

static uint32_t madsatU(uint32_t a, uint32_t b, uint32_t c) { uint64_t r = (uint64_t)a * b + c; return r > 0xffffffffull ? 0xffffffffu : (uint32_t)r; }
static int32_t madsatS(int32_t a, int32_t b, int32_t c) {
    int64_t r = (int64_t)a * b + c;
    return r > INT32_MAX ? INT32_MAX : r < INT32_MIN ? INT32_MIN : (int32_t)r;
}
static uint32_t mulhiU(uint32_t a, uint32_t b) { return (uint32_t)(((uint64_t)a * b) >> 32); }
static int32_t mulhiS(int32_t a, int32_t b) { return (int32_t)(((int64_t)a * b) >> 32); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i21-intel-mad-sat-mul-hi";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 12 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *w = in.contents;
        for (int i = 0; i < T * 3; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = (i % 5 == 0) ? (x & 0xffff) : x; }
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        static const char *const what[8] = {"madsat(a, 3u, b)", "madsat(a, b, c)", "mulhi(a, 3u)", "mulhi(a, b)", "madhi(a, 7u, c)",
                                            "madsat(int a, int b, int c)", "mulhi(int a, -3)", "madsat(uint2)"};
        for (int t = 0; t < T; t++) {
            uint32_t a = w[t * 3], b = w[t * 3 + 1], c = w[t * 3 + 2];
            uint32_t want[8] = {madsatU(a, 3, b), madsatU(a, b, c), mulhiU(a, 3), mulhiU(a, b), mulhiU(a, 7) + c,
                                (uint32_t)madsatS((int32_t)a, (int32_t)b, (int32_t)c), (uint32_t)mulhiS((int32_t)a, -3),
                                madsatU(a, 5, c) ^ madsatU(b, c, a)};
            for (int k = 0; k < 8; k++)
                if (o[t * 8 + k] != want[k])
                    return FAIL(bug, "%s: %s with a=%08x b=%08x c=%08x: %08x, want %08x", name, what[k], a, b, c, o[t * 8 + k], want[k]);
        }
        return PASS(bug, "%s: madsat, mulhi and madhi (unsigned, signed, constant operands, vectors) match the CPU on 256 inputs", name);
    }
}
