// n25-kepler-atomic-join-operand (Kepler adapter, NVAIR_ATOMIC_JOIN_FIX): atomic read-modify-writes whose operand is a
// phi at the join of a branch on a per-lane condition. The back end merges an atomic whose operand it takes to be the
// same in every lane of a warp into one atomic (the value times the number of lanes), and takes such a phi to be uniform
// when its incoming values are: atomic_fetch_add(p, c ? 1u : (max(in[0], 4u) & 255u)), where the front end branches around
// the load, added one lane's choice for all 32 (mslfuzz.py seed 1744 on the GTX 770: a threadgroup counter off by
// multiples of the two values' difference). Threadgroup and device counters, the add of that select and of c ? 1u : 97u
// at the same join, 256 threads in groups of 64, c from the input; compiled without fast math, as the fuzzer does.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], device atomic_uint *dev [[buffer(2)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]], uint g [[threadgroup_position_in_grid]]) {\n"
    "    threadgroup atomic_uint ta[2];\n"
    "    if (l < 2u) atomic_store_explicit(&ta[l], 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    bool c = (in[t * 4u + 3u] & 1u) == 0u;\n"
    "    atomic_fetch_add_explicit(&ta[0], c ? 1u : (max(in[0], 4u) & 255u), memory_order_relaxed);\n"
    "    atomic_fetch_add_explicit(&ta[1], c ? 1u : 97u, memory_order_relaxed);\n"
    "    atomic_fetch_add_explicit(&dev[0], c ? 1u : (max(in[0], 4u) & 255u), memory_order_relaxed);\n"
    "    atomic_fetch_add_explicit(&dev[1], c ? 1u : 97u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (l == 0u) { out[g * 2u] = atomic_load_explicit(&ta[0], memory_order_relaxed); out[g * 2u + 1u] = atomic_load_explicit(&ta[1], memory_order_relaxed); }\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n25-kepler-atomic-join-operand";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:8 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> counters = [dev newBufferWithLength:2 * 4 options:MTLResourceStorageModeShared];
    uint32_t *input = in.contents, x = 1744 * 2654435761u + 12345u;  // the fuzzer's inputs for seed 1744
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; input[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
    memset(counters.contents, 0, counters.length);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:in offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce setBuffer:counters offset:0 atIndex:2];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    uint32_t arm = (input[0] < 4 ? 4 : input[0]) & 255, wantDevice[2] = {0, 0};
    for (int group = 0; group < T / 64; group++) {
        uint32_t want[2] = {0, 0};
        for (int t = group * 64; t < group * 64 + 64; t++) {
            BOOL c = (input[t * 4 + 3] & 1) == 0;
            want[0] += c ? 1 : arm, want[1] += c ? 1 : 97;
        }
        wantDevice[0] += want[0], wantDevice[1] += want[1];
        const uint32_t *got = (const uint32_t *)out.contents + group * 2;
        if (got[0] != want[0] || got[1] != want[1])
            return FAIL(bug, "%s: threadgroup %d: counters %u and %u, want %u and %u (c ? 1 : max(in[0], 4) & 255, c ? 1 : 97)", name, group,
                        got[0], got[1], want[0], want[1]);
    }
    const uint32_t *gotDevice = counters.contents;
    if (gotDevice[0] != wantDevice[0] || gotDevice[1] != wantDevice[1])
        return FAIL(bug, "%s: device counters %u and %u, want %u and %u", name, gotDevice[0], gotDevice[1], wantDevice[0], wantDevice[1]);
    return PASS(bug, "%s: atomic adds of values chosen by a per-lane branch count every lane (threadgroup and device)", name);
}}
