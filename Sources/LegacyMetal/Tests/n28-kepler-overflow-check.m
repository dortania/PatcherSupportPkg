// n28-kepler-overflow-check (Kepler adapter, NVAIR_OVERFLOW_FIX): the usual checks for a 32-bit multiply overflowing,
// (0xffffffffu / a) < b, ulong(a) * ulong(b) > 0xffffffffull and (ulong(a) * ulong(b)) >> 32 != 0, become LLVM's
// llvm.umul.with.overflow.i32 in Metal's front end (or in the plugin's own optimizer), which the plugin's back end can't
// select: the pipeline failed with "Unhandled atom in intrinsic: llvm.umul.with.overflow.i32" (mslfuzz2.py VEC=1 seed
// 2478). The three checks and the product's low word for 256 pairs: every pair of 11 edge values (0, 1, 2, 3, 0xffff,
// 0x10000, 0x10001, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff) and 135 random ones.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint2 *in [[buffer(0)]], device uint2 *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t].x, b = in[t].y;\n"
    "    uint f = ((0xffffffffu / (a | 1u)) < b ? 1u : 0u) | (ulong(a) * ulong(b) > 0xffffffffull ? 2u : 0u) |\n"
    "             ((ulong(a) * ulong(b)) >> 32 != 0ul ? 4u : 0u);\n"
    "    out[t] = uint2(f, a * b);\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n28-kepler-overflow-check";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    static const uint32_t edge[11] = {0, 1, 2, 3, 0xffff, 0x10000, 0x10001, 0x7fffffff, 0x80000000u, 0xfffffffeu, 0xffffffffu};
    id<MTLBuffer> in = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
    uint32_t *pairs = in.contents, x = 2478u * 2654435761u + 12345u;
    for (int i = 0; i < T; i++) {
        if (i < 121) {
            pairs[i * 2] = edge[i / 11], pairs[i * 2 + 1] = edge[i % 11];
        } else {
            for (int k = 0; k < 2; k++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; pairs[i * 2 + k] = (i & 1) ? (x >> (x & 15)) : x; }
        }
    }
    memset(out.contents, 0xcd, out.length);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:in offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *got = out.contents;
    for (int i = 0; i < T; i++) {
        uint32_t a = pairs[i * 2], b = pairs[i * 2 + 1];
        uint64_t p = (uint64_t)a * b;
        uint32_t want = ((0xffffffffu / (a | 1u)) < b ? 1u : 0u) | (p > 0xffffffffull ? 2u : 0u) | ((p >> 32) != 0 ? 4u : 0u);
        if (got[i * 2] != want || got[i * 2 + 1] != (uint32_t)p)
            return FAIL(bug, "%s: a = %#x, b = %#x: checks %#x and product %#x, want %#x and %#x", name, a, b, got[i * 2], got[i * 2 + 1], want,
                        (uint32_t)p);
    }
    return PASS(bug, "%s: 32-bit multiply overflow checks compile and give the right answer", name);
}}
