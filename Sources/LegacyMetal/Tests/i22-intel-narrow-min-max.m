// i22-intel-narrow-min-max (Intel adapter, IntelTextureAtomics.dylib): min, max and clamp on 8- and 16-bit integers
// against constants with the top bit set. The 3802 back end compares the variable zero-extended (AND 0xFF) with the
// constant sign-extended (130 becomes -126), so min(uchar2 a, uchar2(130, 183)) returned a and max returned the constant
// (found by the MacBookPro11,5 session's narrow-vector fuzzing; clamp((uchar)y, 100, 200) returned y too). The adapter
// does them on 32-bit lanes. Runs uchar, uchar2 and char min / max / clamp, plus the 16-bit forms (right on the stock
// back end, rewritten all the same), with constant and variable operands on 256 seeded inputs and compares with the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint x = in[t * 2], y = in[t * 2 + 1];\n"
    "    uchar2 a = uchar2(x, x >> 8);\n"
    "    uchar2 m = min(a, uchar2(130, 183)), n = max(a, uchar2(130, 183));\n"
    "    out[t * 6 + 0] = m.x | m.y << 8 | n.x << 16 | n.y << 24;\n"
    "    ushort2 q = min(ushort2(x, x >> 16), ushort2(40000, 50000)), r = max(ushort2(x, x >> 16), ushort2(40000, 50000));\n"
    "    out[t * 6 + 1] = q.x | q.y << 16;\n"
    "    out[t * 6 + 2] = r.x | r.y << 16;\n"
    "    uchar c = clamp((uchar)y, (uchar)100, (uchar)200);\n"
    "    uchar d = min((uchar)y, (uchar)(y >> 8));\n"
    "    char e = clamp((char)(y >> 16), (char)-100, (char)90);\n"
    "    char f = max((char)(y >> 24), (char)-3);\n"
    "    out[t * 6 + 3] = c | d << 8 | (uchar)e << 16 | (uchar)f << 24;\n"
    "    ushort s = clamp((ushort)y, (ushort)1000, (ushort)60000);\n"
    "    short u = min((short)(y >> 16), (short)-20000);\n"
    "    out[t * 6 + 4] = s | (ushort)u << 16;\n"
    "    out[t * 6 + 5] = max((uchar)x, (uchar)255);\n"
    "}\n";

static unsigned umin(unsigned a, unsigned b) { return a < b ? a : b; }
static unsigned umax(unsigned a, unsigned b) { return a > b ? a : b; }
static int smin(int a, int b) { return a < b ? a : b; }
static int smax(int a, int b) { return a > b ? a : b; }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i22-intel-narrow-min-max";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 24 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *w = in.contents;
        for (int i = 0; i < T * 2; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = x; }
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        static const char *const what[6] = {"min / max(uchar2, uchar2(130, 183))", "min(ushort2, ushort2(40000, 50000))",
                                            "max(ushort2, ushort2(40000, 50000))", "uchar clamp / min, char clamp / max",
                                            "ushort clamp, short min", "max(uchar, 255)"};
        for (int t = 0; t < T; t++) {
            uint32_t a = w[t * 2], b = w[t * 2 + 1];
            uint8_t a0 = a, a1 = a >> 8;
            uint16_t h0 = a, h1 = a >> 16;
            uint32_t want[6] = {
                umin(a0, 130) | umin(a1, 183) << 8 | umax(a0, 130) << 16 | umax(a1, 183) << 24,
                umin(h0, 40000) | umin(h1, 50000) << 16,
                umax(h0, 40000) | umax(h1, 50000) << 16,
                umin(umax((uint8_t)b, 100), 200) | umin((uint8_t)b, (uint8_t)(b >> 8)) << 8 |
                    (uint32_t)(uint8_t)smin(smax((int8_t)(b >> 16), -100), 90) << 16 | (uint32_t)(uint8_t)smax((int8_t)(b >> 24), -3) << 24,
                umin(umax((uint16_t)b, 1000), 60000) | (uint32_t)(uint16_t)smin((int16_t)(b >> 16), -20000) << 16,
                255};
            for (int k = 0; k < 6; k++)
                if (o[t * 6 + k] != want[k])
                    return FAIL(bug, "%s: %s with x=%08x y=%08x: %08x, want %08x", name, what[k], a, b, o[t * 6 + k], want[k]);
        }
        return PASS(bug, "%s: 8- and 16-bit min, max and clamp (unsigned, signed, vectors, constants >= 128) match the CPU on 256 inputs", name);
    }
}
