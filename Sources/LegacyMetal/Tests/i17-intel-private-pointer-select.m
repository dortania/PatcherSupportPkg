// i17-intel-private-pointer-select (Intel adapter, IntelTextureAtomics.dylib): a private array that is also reached
// through a select of pointers into it (`thread uint *q = c ? &p[6] : &p[5]; *q += 5u;`) stays in private memory, and
// there the 3802 back end forwards a load of an element past a store to that same element: after
// `p[5] = p[5] + a; p[5] = p[5] * 3u;` the multiplication reads the first load's value (stock compiler too). The
// adapter's variable-index rewrite (i07) turns every variable-index store into loads and stores of each element, so with
// a pointer select in the function random integer kernels came out wrong 43% of the time (differential fuzzing on
// both 2015 MacBook Pros). Runs both shapes, constant-index updates and variable-index stores followed by the pointer
// select, on 64 threads, and checks every thread against the same code run on the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void constantUpdates(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    p[5] = p[5] + in[t * 4u];\n"
    "    p[6] = p[6] ^ in[t * 4u + 1u];\n"
    "    p[5] = p[5] * 3u;\n"
    "    thread uint *q = (in[t * 4u + 3u] & 1u) ? &p[6] : &p[5];\n"
    "    *q += 5u;\n"
    "    out[t * 4u] = *q; out[t * 4u + 1u] = p[5]; out[t * 4u + 2u] = p[6];\n"
    "    out[t * 4u + 3u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];\n"
    "}\n"
    "kernel void variableStores(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    p[in[t * 4u] & 7u] = in[t * 4u + 1u] * 3u;\n"
    "    p[in[t * 4u + 2u] & 7u] = in[t * 4u + 1u] ^ t;\n"
    "    thread uint *q = (in[t * 4u + 3u] & 1u) ? &p[6] : &p[5];\n"
    "    *q += 5u;\n"
    "    out[t * 4u] = *q; out[t * 4u + 1u] = p[5]; out[t * 4u + 2u] = p[6];\n"
    "    out[t * 4u + 3u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];\n"
    "}\n";

static void reference(int shape, const uint32_t *in, uint32_t t, uint32_t *out) {
    uint32_t p[8];
    for (uint32_t j = 0; j < 8; j++) p[j] = in[t * 4 + (j & 3)] + j;
    if (shape == 0) {
        p[5] = p[5] + in[t * 4];
        p[6] = p[6] ^ in[t * 4 + 1];
        p[5] = p[5] * 3u;
    } else {
        p[in[t * 4] & 7] = in[t * 4 + 1] * 3u;
        p[in[t * 4 + 2] & 7] = in[t * 4 + 1] ^ t;
    }
    uint32_t *q = (in[t * 4 + 3] & 1) ? &p[6] : &p[5];
    *q += 5u;
    out[0] = *q; out[1] = p[5]; out[2] = p[6];
    out[3] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i17-intel-private-pointer-select";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        enum { T = 64 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u, *words = in.contents;
        for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; words[i] = x; }
        const char *shapes[] = {"constantUpdates", "variableStores"};
        const char *what[] = {"constant-index updates", "variable-index stores"};
        for (int shape = 0; shape < 2; shape++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(shapes[shape])] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(T, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            const uint32_t *got = out.contents;
            for (uint32_t t = 0; t < T; t++) {
                uint32_t want[4];
                reference(shape, words, t, want);
                for (int w = 0; w < 4; w++)
                    if (got[t * 4 + w] != want[w])
                        return FAIL(bug, "%s: %s then *q += 5 through a pointer select, thread %u: %s %08x, want %08x", name, what[shape], t,
                                    (const char *[]){"*q", "p[5]", "p[6]", "xor of p"}[w], got[t * 4 + w], want[w]);
            }
        }
        return PASS(bug, "%s: private array updates around a pointer select into it match the CPU (64 threads, both shapes)", name);
    }
}
