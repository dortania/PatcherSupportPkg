// i26-intel-signed-div-negated (Intel adapter, IntelTextureAtomics.dylib): signed division and remainder of a negated
// value. iCBE folds the negation (0 - v) into the integer divide as a source modifier, and the divide drops it: (-v) % d
// came out as v % d, (-v) / d and v / (-d) as v / d (mslfuzz2 seed 223, where such a remainder picked a vector lane).
// Unsigned division and remainders by a negated divisor (whose sign doesn't matter) were right. Runs the forms with
// variable and constant divisors, scalars and int2, INT_MIN among the inputs, on 256 seeded inputs and compares with
// the same arithmetic on the CPU. The second kernel has the negation hidden from the IR: the front end writes
// (short)(-(int)v) % d as (v * -65536) >> 16, and the back end, knowing v is 0 or 1 after the loops, makes it a negation
// that iCBE folds into the divide the same way (mslfuzz2 VEC=1 seed 917, reduced); that one is fixed in the IGIL text.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device int *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    int x = (int)in[t * 2], d = (int)(in[t * 2 + 1] | 1u), n = -x;\n"
    "    out[t * 8 + 0] = n % d;\n"
    "    out[t * 8 + 1] = n / d;\n"
    "    out[t * 8 + 2] = x / -d;\n"
    "    out[t * 8 + 3] = n % 7;\n"
    "    out[t * 8 + 4] = n % 2147483393;\n"
    "    out[t * 8 + 5] = (-n) / d;\n"
    "    int2 v = -int2(x, d) % int2(d | 3, 1000);\n"
    "    out[t * 8 + 6] = v.x;\n"
    "    out[t * 8 + 7] = v.y;\n"
    "}\n";
static NSString *const src2 = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device int *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint v4 = in[t * 2] * 9u + t, v5 = in[t * 2 + 1] * 11u + t, d = ((in[t * 2] ^ t) & 32767u) | 1u;\n"
    "    for (uint i0 = 0; i0 < 3u; i0++) for (uint i1 = 0; i1 < 3u; i1++)\n"
    "        v5 = (uint)((ushort)((uint)(any(0u < (ushort3((ushort)0u, (ushort)0u, (ushort)(v5 ^ t)) * ushort3(3959, 51786, 37453)))) % (ushort)(((ushort)v4) | 1u)));\n"
    "    out[t] = (int)((short)((uint)(-(int)v5)) % (short)d);\n"
    "}\n";
static int32_t hidden(uint32_t a, uint32_t b, uint32_t t) {  // src2 on the CPU
    uint32_t v4 = a * 9u + t, v5 = b * 11u + t, d = ((a ^ t) & 32767u) | 1u;
    for (int i = 0; i < 9; i++) {
        uint32_t any = (uint16_t)((uint16_t)(v5 ^ t) * 37453u) != 0;
        v5 = (uint16_t)(any % (uint16_t)((uint16_t)v4 | 1u));
    }
    return (int16_t)(uint16_t)(0u - v5) % (int16_t)d;
}

static int32_t rem(int32_t a, int32_t b) { return (b == -1) ? 0 : a % b; }
static int32_t quot(int32_t a, int32_t b) { return (a == INT32_MIN && b == -1) ? INT32_MIN : a / b; }
static int32_t neg(int32_t a) { return (int32_t)(0u - (uint32_t)a); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i26-intel-signed-div-negated";
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
        id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *w = in.contents;
        for (int i = 0; i < T * 2; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = (i % 3 == 0) ? x % 100000 : x; }
        w[0] = 0x80000000u;  // INT_MIN: 0 - INT_MIN wraps to itself
        w[2] = 0x80000000u, w[3] = 7;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const int32_t *o = out.contents;
        static const char *const what[8] = {"(-x) % d", "(-x) / d", "x / (-d)", "(-x) % 7", "(-x) % 2147483393", "x / d through two negations",
                                            "-int2(x, d) % int2(d | 3, 1000) .x", ".y"};
        for (int t = 0; t < T; t++) {
            int32_t a = (int32_t)w[t * 2], d = (int32_t)(w[t * 2 + 1] | 1u), n = neg(a);
            int32_t want[8] = {rem(n, d), quot(n, d), quot(a, neg(d)), rem(n, 7), rem(n, 2147483393), quot(neg(n), d), rem(n, d | 3), rem(neg(d), 1000)};
            for (int k = 0; k < 8; k++)
                if (o[t * 8 + k] != want[k]) return FAIL(bug, "%s: %s with x=%d d=%d: %d, want %d", name, what[k], a, d, o[t * 8 + k], want[k]);
        }
        id<MTLLibrary> lib2 = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src2] options:nil error:&err];
        if (!lib2) return FAIL(bug, "compile (second kernel): %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps2 = [dev newComputePipelineStateWithFunction:[lib2 newFunctionWithName:@"k"] error:&err];
        if (!ps2) return FAIL(bug, "%s: pipeline (second kernel): %s", name, err.localizedDescription.UTF8String);
        id<MTLBuffer> out2 = [dev newBufferWithLength:T * 4 options:MTLResourceStorageModeShared];
        cb = [[dev newCommandQueue] commandBuffer];
        ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps2];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out2 offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed (second kernel)", name);
        const int32_t *o2 = out2.contents;
        for (int t = 0; t < T; t++) {
            int32_t want = hidden(w[t * 2], w[t * 2 + 1], (uint32_t)t);
            if (o2[t] != want) return FAIL(bug, "%s: (short)(-v) %% d after loops, thread %d: %d, want %d", name, t, o2[t], want);
        }
        return PASS(bug, "%s: signed division and remainder of negated values (variable and constant divisors, int2, INT_MIN) match the CPU", name);
    }
}
