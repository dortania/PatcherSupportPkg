// a13-amd-private-array-stores (AMD adapter, AMDTextureAtomics.dylib): private arrays written at variable indexes with
// the 12.5 AMD compiler. SC keeps small private arrays in VGPRs and writes variable indexes with M0-relative moves
// (v_movreld), and loses updates around them (found by differential fuzzing against a CPU reference):
//   branch:  if (c) p[2] += 1; else p[i] += 1; p[j] = 1;   SC drops the first branch (p[2] keeps its old value)
//   select:  if (c) { q = c2 ? &p[6] : &p[2]; *q += 1; } else p[2] += 1; p[j] = 1;   the same through a pointer select
//   loop:    for (5 times) { p[i] += 1; s += p[i]; p[j] = 1; }   loses the first write from the second iteration on
// The fix makes every access to such an array a constant-index one, loads too: with the stores done per element and the
// loads left indexed, SC merges indexed loads across the stores between them once a loop is unrolled:
//   unrolled: k = constant; for (5 times) { k += n * 7; p[k & 7] = a; s ^= p[i]; }   four of the five loads read one value
// Each kernel runs on 256 threads with different indexes and is checked against the same code on the CPU.
// Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "#define INIT uint p[8]; for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j; uint v = in[t * 4u] + t;\n"
    "#define DONE for (uint j = 0; j < 8u; j++) out[t * 9u + j] = p[j];\n"
    "kernel void branch(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    INIT if (v < t) p[(in[t * 4u + 1u]) & 7u] += 1u; else p[2] += 1u; p[v & 7u] = 1u; DONE out[t * 9u + 8u] = 0u;\n"
    "}\n"
    "kernel void select(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    INIT if (v < t) { thread uint *q = v ? &p[6] : &p[2]; *q += 1u; } else p[2] += 1u; p[v & 7u] = 1u; DONE out[t * 9u + 8u] = 0u;\n"
    "}\n"
    "kernel void loop(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    INIT uint s = 0; uint i = in[t * 4u + 1u] & 7u;\n"
    "    for (uint n = 0; n < 5u; n++) { p[i] += 1u; s += p[i]; p[v & 7u] = 1u; }\n"
    "    DONE out[t * 9u + 8u] = s;\n"
    "}\n"
    "kernel void unrolled(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    INIT uint s = in[t * 4u + 3u] * 7u + t; uint k = 1597821222u; uint a = min(in[t * 4u + 2u] * 5u + t, v);\n"
    "    for (uint n = 0; n < 5u; n++) { k += n * 7u; p[k & 7u] = a; s ^= p[in[t * 4u] & 7u]; }\n"
    "    DONE out[t * 9u + 8u] = s;\n"
    "}\n";

// The same kernels on the CPU.
static void reference(const char *kernel, const uint32_t *in, uint32_t *out, uint32_t t) {
    uint32_t p[8], s = 0;
    for (uint32_t j = 0; j < 8; j++) p[j] = in[t * 4 + (j & 3)] + j;
    uint32_t v = in[t * 4] + t;
    if (!strcmp(kernel, "branch")) {
        if (v < t) p[in[t * 4 + 1] & 7] += 1; else p[2] += 1;
        p[v & 7] = 1;
    } else if (!strcmp(kernel, "select")) {
        if (v < t) { uint32_t *q = v ? &p[6] : &p[2]; *q += 1; } else p[2] += 1;
        p[v & 7] = 1;
    } else if (!strcmp(kernel, "loop")) {
        uint32_t i = in[t * 4 + 1] & 7;
        for (int n = 0; n < 5; n++) { p[i] += 1; s += p[i]; p[v & 7] = 1; }
    } else {
        uint32_t k = 1597821222u, a = in[t * 4 + 2] * 5 + t;
        s = in[t * 4 + 3] * 7 + t;
        if (v < a) a = v;
        for (uint32_t n = 0; n < 5; n++) { k += n * 7; p[k & 7] = a; s ^= p[in[t * 4] & 7]; }
    }
    for (int j = 0; j < 8; j++) out[j] = p[j];
    out[8] = s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a13-amd-private-array-stores";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        uint32_t x = 2463534242u;
        for (int i = 0; i < T * 4; i++) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            // Some threads overflow v = in + t, so both sides of each branch run.
            ((uint32_t *)in.contents)[i] = (i % 4 == 0 && (i / 4) % 3 == 0) ? 0xffffffffu - (x & 0x3f) : x;
        }
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        char report[500] = "";
        const char *const kernels[] = {"branch", "select", "loop", "unrolled"};
        for (size_t k = 0; k < 4; k++) {
            const char *kernel = kernels[k];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kernel)] error:&err];
            if (!ps) return FAIL(bug, "%s: %s: %s", dev.name.UTF8String, kernel, err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:T * 9 * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", dev.name.UTF8String, kernel);
            int wrong = 0, first = -1;
            for (uint32_t t = 0; t < T; t++) {
                uint32_t want[9];
                reference(kernel, in.contents, want, t);
                if (memcmp(want, (uint32_t *)out.contents + t * 9, sizeof want) && wrong++ == 0) first = (int)t;
            }
            if (wrong) {
                char line[120];
                snprintf(line, sizeof line, "%s%s: %d of %d threads wrong (first %d)", report[0] ? "; " : "", kernel, wrong, T, first);
                strlcat(report, line, sizeof report);
            }
        }
        if (report[0]) return FAIL(bug, "%s: %s", dev.name.UTF8String, report);
        return PASS(bug, "%s: private arrays written at variable indexes in branches and loops keep every write and read", dev.name.UTF8String);
    }
}
