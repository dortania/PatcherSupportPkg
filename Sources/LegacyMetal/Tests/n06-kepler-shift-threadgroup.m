// n06-kepler-shift-threadgroup: a 64-bit shift by a variable amount next to a threadgroup barrier must be right; the
// adapter's first, select-based shift rewrite gave 0 there. A guard for GeForceAIRCompat's 64-bit shifts (stock OCLP
// passes). Checks: 256 threads on five inputs against the CPU. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]],\n"
    "              uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup uint tg[64];\n"
    "    uint v0 = in[t * 4u] + t, v2 = in[t * 4u + 2u] * 5u + t, v3 = in[t * 4u + 3u] * 7u + t, v4 = in[t * 4u] * 9u + t;\n"
    // seed 1295, reduced: a bool and a 16-bit product in a ulong, shifted by a 0-or-1 amount, the high word as char
    "    uint v5 = (uint)((char)((uint)(((((ulong)((uint)(!(1u > v2))) << 32) | (ulong)(((uint)((ushort)(in[t * 4u + 3u])) *\n"
    "              (uint)((ushort)(35u))))) << ((uint)((bool)(2147483648u & v0)) & 63u)) >> 32)));\n"
    "    ulong x = (ulong(uint(v2 != 0u)) << 32) | ulong(in[t * 4u + 1u]);\n"
    "    uint wide = uint(x << ulong(v0 & 63u)) ^ uint(long(x ^ (ulong(v3) << 40)) >> long(v3 & 63u));\n"
    "    tg[l] = in[t * 4u + 2u];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    v4 += tg[(v3 ^ t) & 63u];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 3u] = v5;\n"
    "    out[t * 3u + 1u] = wide;\n"
    "    out[t * 3u + 2u] = v4;\n"
    "}\n";

static void reference(const uint32_t *in, uint32_t t, uint32_t out[3]) {
    uint32_t v0 = in[t * 4] + t, v2 = in[t * 4 + 2] * 5u + t, v3 = in[t * 4 + 3] * 7u + t, v4 = in[t * 4] * 9u + t;
    uint64_t h = ((uint64_t)(uint32_t)!(1u > v2) << 32) | (uint64_t)((uint32_t)(uint16_t)in[t * 4 + 3] * 35u);
    out[0] = (uint32_t)(int8_t)(uint32_t)((h << ((uint32_t)((0x80000000u & v0) != 0) & 63)) >> 32);
    uint64_t x = ((uint64_t)(v2 != 0) << 32) | (uint64_t)in[t * 4 + 1];
    out[1] = (uint32_t)(x << (v0 & 63)) ^ (uint32_t)((int64_t)(x ^ ((uint64_t)v3 << 40)) >> (v3 & 63));
    uint32_t base = t & ~63u, other = base + ((v3 ^ t) & 63u);
    out[2] = v4 + in[other * 4 + 2];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n06-kepler-shift-threadgroup";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 12 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    static const char *const kWhat[3] = {"char((bool, ushort * 35) << (a >> 31) >> 32) (seed 1295)", "shifts by v & 63, both kinds", "a threadgroup read after a barrier"};
    const unsigned seeds[] = {1, 2, 3, 7, 42};
    for (unsigned s = 0; s < sizeof seeds / sizeof *seeds; s++) {
        uint32_t x = seeds[s] * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = x; }
        if (!reproDispatch(queue, ps, @[input, output], MTLSizeMake(4, 1, 1), MTLSizeMake(64, 1, 1))) return FAIL(bug, "command buffer failed");
        const uint32_t *got = output.contents;
        for (unsigned t = 0; t < T; t++) {
            uint32_t want[3];
            reference(in, t, want);
            for (int w = 0; w < 3; w++)
                if (got[t * 3 + w] != want[w])
                    return FAIL(bug, "%s: %s wrong on input %u (thread %u: %08x, want %08x)", dev.name.UTF8String, kWhat[w], seeds[s], t,
                                got[t * 3 + w], want[w]);
        }
    }
    return PASS(bug, "%s: 64-bit shifts by variable amounts next to a threadgroup exchange are right (256 threads, 5 inputs)", dev.name.UTF8String);
}}
