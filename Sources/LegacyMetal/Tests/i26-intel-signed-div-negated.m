// i26-intel-signed-div-negated (Intel adapter, IntelTextureAtomics.dylib): signed division and remainder of a negated
// value. iCBE folds the negation (0 - v) into the integer divide as a source modifier, and the divide drops it: (-v) % d
// came out as v % d, (-v) / d and v / (-d) as v / d (mslfuzz2 seed 223, where such a remainder picked a vector lane).
// Unsigned division and remainders by a negated divisor (whose sign doesn't matter) were right. Runs the forms with
// variable and constant divisors, scalars and int2, INT_MIN among the inputs, on 256 seeded inputs and compares with
// the same arithmetic on the CPU.
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
        return PASS(bug, "%s: signed division and remainder of negated values (variable and constant divisors, int2, INT_MIN) match the CPU", name);
    }
}
