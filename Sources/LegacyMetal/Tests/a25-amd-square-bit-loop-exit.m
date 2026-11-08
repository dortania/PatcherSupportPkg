// a25-amd-square-bit-loop-exit (AMD adapter): a loop exit on the low bits of a square must be taken right.
// The front end turns `((x * x) << s) & 3 == 0` (the low two bits of a square are x & 1 and 0) into
// `((x & 1) & (3 >> s)) == 0`; libAMDIL902 takes x & 1 for a 0 / 1 boolean, drops the `& 1` and tests the whole register,
// so for x = 2 mod 4 and s = 0 the loop runs on (found by fuzzing with narrow vectors: a while loop with a threadgroup
// atomic). The adapter's bit-test fix sends that x & 1 through extract_bits too.
// Checked: the loop count of 256 threads against the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]],\n"
    "              uint l [[thread_position_in_threadgroup]]) {\n"
    "  threadgroup atomic_uint ta;\n"
    "  if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  uint n = 0u;\n"
    "  while (n < 8u) { n++; atomic_fetch_add_explicit(&ta, 1u, memory_order_relaxed);\n"
    "    if (((((uint)(ushort)in[4u * t + 1u] * (uint)(ushort)in[4u * t + 1u]) << (in[4u * t] % 3u)) & 3u) == 0u) break; }\n"
    "  out[t] = n;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a25-amd-square-bit-loop-exit";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0xc2b2ae35u;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents;
        int wrong = 0, first = -1;
        for (int t = 0; t < kThreads; t++) {
            uint32_t x = (uint16_t)input[4 * t + 1], sh = input[4 * t] % 3;
            uint32_t want = (((x * x) << sh) & 3) == 0 ? 1 : 8;
            if (got[t] != want) { if (first < 0) first = t; wrong++; }
        }
        if (wrong) return FAIL(bug, "%s: %d of %d loop counts wrong (thread %d: %u, want %u)", dev.name.UTF8String, wrong, kThreads, first, got[first],
                               (((uint32_t)(uint16_t)input[4 * first + 1] * (uint16_t)input[4 * first + 1]) << (input[4 * first] % 3) & 3) == 0 ? 1u : 8u);
        return PASS(bug, "%s: loop exits on the low bits of a square", dev.name.UTF8String);
    }
}
