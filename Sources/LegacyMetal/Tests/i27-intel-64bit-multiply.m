// i27-intel-64bit-multiply: 64-bit multiplies with a constant low word in a factor must be right; the 32-bit split got
// the high word wrong. Fix: IntelTextureAtomics INTEL_MUL64_FIX (Kepler: NVAIR_INTRINSICS, NVAIR_I64_FIX).
// Checks: ulong and long mulhi, madhi and multiply, such and arbitrary factors, vs the CPU. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device ulong *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    ulong a = ((ulong)in[t * 4] << 32) | 139u, b = ((ulong)in[t * 4 + 1] << 32) | in[t * 4 + 2];\n"
    "    ulong c = ((ulong)in[t * 4 + 3] << 32) | in[t * 4];\n"
    "    out[t * 6 + 0] = mulhi(a, b);\n"
    "    out[t * 6 + 1] = a * b;\n"
    "    out[t * 6 + 2] = mulhi(b, c);\n"
    "    out[t * 6 + 3] = (ulong)mulhi((long)a, (long)c);\n"
    "    out[t * 6 + 4] = madhi(a, c, b);\n"
    "    out[t * 6 + 5] = b * c + (ulong)in[t * 4 + 1] * 3000000000ul;\n"
    "}\n";

static uint64_t mulhiU(uint64_t a, uint64_t b) { return (uint64_t)(((unsigned __int128)a * b) >> 64); }
static uint64_t mulhiS(int64_t a, int64_t b) { return (uint64_t)(int64_t)(((__int128)a * b) >> 64); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i27-intel-64bit-multiply";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 48 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *w = in.contents;
        for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = x; }
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint64_t *o = out.contents;
        static const char *const what[6] = {"mulhi(a, b), a's low word 139", "a * b", "mulhi(b, c)", "mulhi((long)a, (long)c)", "madhi(a, c, b)",
                                            "b * c + (ulong)x * 3000000000"};
        for (int t = 0; t < T; t++) {
            uint64_t a = ((uint64_t)w[t * 4] << 32) | 139u, b = ((uint64_t)w[t * 4 + 1] << 32) | w[t * 4 + 2], c = ((uint64_t)w[t * 4 + 3] << 32) | w[t * 4];
            uint64_t want[6] = {mulhiU(a, b), a * b, mulhiU(b, c), mulhiS((int64_t)a, (int64_t)c), mulhiU(a, c) + b, b * c + (uint64_t)w[t * 4 + 1] * 3000000000ull};
            for (int k = 0; k < 6; k++)
                if (o[t * 6 + k] != want[k])
                    return FAIL(bug, "%s: %s with a=%016llx b=%016llx c=%016llx: %016llx, want %016llx", name, what[k], a, b, c, o[t * 6 + k], want[k]);
        }
        return PASS(bug, "%s: 64-bit mulhi, madhi and multiplies (constant low words, signed, arbitrary factors) match the CPU", name);
    }
}
