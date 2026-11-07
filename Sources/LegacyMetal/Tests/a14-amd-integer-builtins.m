// a14-amd-integer-builtins (AMD adapter, AMDTextureAtomics.dylib): Metal integer builtins that SC (the 12.5 AMD shader
// compiler's back end) folds wrong once it knows an operand. Both found by differential fuzzing against a CPU reference:
//   subsat(x, 0) / addsat(x, 0), unsigned, with the 0 known (a constant, or mulhi(b, 1u)): SC makes `usub_sat x, 0` a float
//   clamp to [0, 1] (v_max_f32 x, x clamp): 0 for x >= 0x80000000, 0x3f800000 for other large x
//   rotate(x, n) with both known and n a multiple of 8: rotate(37u, 24u) gives 0x2500, rotate(37u, 8u) 0x25000000
// Scalar and vector forms, 256 threads, checked against the same code on the CPU; the general forms (operands at run
// time) are in there too and are right either way.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint a = in[t * 2u], b = in[t * 2u + 1u];\n"
    "    uint zero = mulhi(b, 1u);\n"
    "    out[t * 8u + 0u] = subsat(a, zero);\n"
    "    out[t * 8u + 1u] = addsat(a, 0u);\n"
    "    out[t * 8u + 2u] = rotate(37u, 24u) + a;\n"
    "    out[t * 8u + 3u] = rotate(0x12345678u, 8u) ^ a;\n"
    "    uint4 r = rotate(uint4(0x11223344u, 37u, 0x80000001u, 0xdeadbeefu), uint4(8u, 16u, 24u, 4u)) + uint4(a);\n"
    "    out[t * 8u + 4u] = r.x ^ (r.y << 1u) ^ (r.z << 2u) ^ (r.w << 3u);\n"
    "    ushort2 s = addsat(ushort2(ushort(a), ushort(a >> 16u)), ushort2(ushort(zero)));\n"
    "    out[t * 8u + 5u] = uint(s.x) | (uint(s.y) << 16u);\n"
    "    out[t * 8u + 6u] = subsat(b, 0u) ^ rotate(a, b);\n"
    "    out[t * 8u + 7u] = subsat(a, b) + addsat(a, b);\n"
    "}\n";

static uint32_t rotl(uint32_t x, uint32_t n) { n &= 31; return n ? (x << n) | (x >> (32 - n)) : x; }
static uint32_t subsat(uint32_t a, uint32_t b) { return a > b ? a - b : 0; }
static uint32_t addsat(uint32_t a, uint32_t b) { return a + b < a ? 0xffffffffu : a + b; }

static void reference(uint32_t a, uint32_t b, uint32_t out[8]) {
    out[0] = a;
    out[1] = a;
    out[2] = rotl(37, 24) + a;
    out[3] = rotl(0x12345678u, 8) ^ a;
    uint32_t r[4] = {rotl(0x11223344u, 8) + a, rotl(37, 16) + a, rotl(0x80000001u, 24) + a, rotl(0xdeadbeefu, 4) + a};
    out[4] = r[0] ^ (r[1] << 1) ^ (r[2] << 2) ^ (r[3] << 3);
    out[5] = a;
    out[6] = b ^ rotl(a, b);
    out[7] = subsat(a, b) + addsat(a, b);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a14-amd-integer-builtins";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *words = in.contents;
        for (int i = 0; i < T * 2; i++) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            words[i] = x;
        }
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        static const char *const names[8] = {"subsat(a, mulhi(b, 1u))", "addsat(a, 0u)", "rotate(37u, 24u)", "rotate(0x12345678u, 8u)",
                                             "rotate(uint4 constants)", "addsat(ushort2, 0)", "subsat(b, 0u) ^ rotate(a, b)", "subsat(a, b) + addsat(a, b)"};
        int wrong[8] = {0}, first[8];
        uint32_t got[8], want[8];
        for (uint32_t t = 0; t < T; t++) {
            uint32_t w[8];
            reference(words[t * 2], words[t * 2 + 1], w);
            for (int i = 0; i < 8; i++)
                if (((uint32_t *)out.contents)[t * 8 + i] != w[i] && wrong[i]++ == 0) {
                    first[i] = (int)t;
                    got[i] = ((uint32_t *)out.contents)[t * 8 + i];
                    want[i] = w[i];
                }
        }
        char report[600] = "";
        for (int i = 0; i < 8; i++)
            if (wrong[i]) {
                char line[160];
                snprintf(line, sizeof line, "%s%s: %d of %d wrong (thread %d: 0x%08x, want 0x%08x)", report[0] ? "; " : "", names[i], wrong[i], T,
                         first[i], got[i], want[i]);
                strlcat(report, line, sizeof report);
            }
        if (report[0]) return FAIL(bug, "%s: %s", dev.name.UTF8String, report);
        return PASS(bug, "%s: saturating adds with a known 0 and constant rotates by whole bytes compute right", dev.name.UTF8String);
    }
}
