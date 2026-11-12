// i23-intel-buffer-pointer-select (Intel adapter, IntelTextureAtomics.dylib): `c ? in[i] : in[j]` inside one arm of a
// switch. The front end loads through select(c, &in[i], &in[j]); the 3802 back end can't tell both pointers name the
// same buffer and loads through a loop over the SIMD group's distinct surfaces, which takes flag register f0.1 without
// saving it. Here the switch's case 1 falls through into the default and the back end keeps the else-branch's test
// (selector != 0) in f0.1: in every SIMD8 group with a case-1 lane, the case-0 lanes ran the default's code too
// (differential fuzzing, mslfuzz2 seeds 5, 144 and 291). The adapter selects the index instead of the pointer. Runs the
// kernel on 256 seeded inputs and compares with the same arithmetic on the CPU.
// Stock OCLP: PASS (the bug is the back end's, but in this kernel the flags only collide once the adapter's private-array
// rewrite has kept the arrays in registers). The PR's adapter without this fix: FAIL. Fixed: PASS. Argument: GPU name
// substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    uint v0 = in[t * 4u] + t, v1 = in[t * 4u + 1u] * 3u + t, v2 = in[t * 4u + 2u] * 5u + t;\n"
    "    uint v3 = in[t * 4u + 3u] * 7u + t, v4 = in[t * 4u] * 9u + t, v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    pc[(((v5 ^ t) & 0xffffu) >> 1u) & 7u] = uchar((v4 & 0xffffu) * (v2 & 0xffffu));\n"
    "    for (uint i = 0; i < 5u; i++) atomic_fetch_add_explicit(&ta, (in[t * 4u + 2u] != 1u ? v3 : v5) & 255u, memory_order_relaxed);\n"
    "    switch ((v4 ^ t) & 3u) {\n"
    "    case 0u:\n"
    "        break;\n"
    "    case 1u:\n"
    "        v3 = extract_bits(((v3 ^ t) & 1u) != 0u ? in[t * 4u + 1u] : in[t * 4u + 2u], (((v1 ^ t) & 1u) != 0u ? in[t * 4u] : v0) & 15u, 5u);\n"
    "    default:\n"
    "        v3 ^= in[t * 4u + 2u] + 125u;\n"
    "        break;\n"
    "    }\n"
    "    out[t * 2u] = v3;\n"
    "    out[t * 2u + 1u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) |\n"
    "                       (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i23-intel-buffer-pointer-select";
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
        id<MTLBuffer> out = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
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
        const uint32_t *o = out.contents;
        for (uint32_t t = 0; t < T; t++) {
            const uint32_t *a = w + t * 4;
            uint32_t p[8];
            uint8_t pc[8];
            for (int j = 0; j < 8; j++) p[j] = a[j & 3] + j, pc[j] = (uint8_t)(a[j & 3] >> j);
            uint32_t v0 = a[0] + t, v1 = a[1] * 3u + t, v2 = a[2] * 5u + t, v3 = a[3] * 7u + t, v4 = a[0] * 9u + t, v5 = a[1] * 11u + t;
            pc[(((v5 ^ t) & 0xffffu) >> 1) & 7] = (uint8_t)((v4 & 0xffffu) * (v2 & 0xffffu));
            uint32_t selector = (v4 ^ t) & 3u;
            if (selector == 1) v3 = ((((v3 ^ t) & 1u) ? a[1] : a[2]) >> ((((v1 ^ t) & 1u) ? a[0] : v0) & 15u)) & 31u;
            if (selector != 0) v3 ^= a[2] + 125u;
            uint32_t mix = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^
                           (pc[0] | (uint32_t)pc[1] << 8 | (uint32_t)pc[2] << 16 | (uint32_t)pc[3] << 24) ^
                           (pc[4] * 3u + pc[5] * 5u + pc[6] * 7u + pc[7] * 11u);
            if (o[t * 2] != v3)
                return FAIL(bug, "%s: thread %u, switch case %u: %08x, want %08x (case 0 breaks out: the default's code ran)", name, t, selector, o[t * 2], v3);
            if (o[t * 2 + 1] != mix) return FAIL(bug, "%s: thread %u: private arrays %08x, want %08x", name, t, o[t * 2 + 1], mix);
        }
        return PASS(bug, "%s: a select of two pointers into one buffer inside a switch arm leaves the other cases' lanes alone (256 threads)", name);
    }
}
