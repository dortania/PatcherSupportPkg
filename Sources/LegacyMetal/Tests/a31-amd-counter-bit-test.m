// a31-amd-counter-bit-test (AMD adapter): an inner loop's exit on bits of a value and'ed with the outer loop's counter
// must be taken. `for (i < 3) { n = 0; while (n < 8) { n++; v ^= ...; if ((i & v & 3) == 0) break; } }` ran the inner loop
// 8 times for i = 1 instead of stopping at the first even v (found by fuzzing with loop counters in expressions, on Tahoe
// and Sequoia alike, stock files too): once libAMDIL902 unrolls the outer loop, the test is `(v & 1) == 0`, a15's bug,
// which the adapter's bit-test fix only sees with a constant mask. The adapter sends such ands through extract_bits.
// Checked: the and form, shifts of the counter by v & 1 and v & 31, and `(i <= z ? 0x80000000u : i % m) & 3` (seed 750:
// the front end makes that select branches, so the counter reaches the and through a phi), the inner trip counts of
// 256 threads against the CPU.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256, kOut = 11 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint v = in[4 * t + 1] * 11u + t, u = v, w = v;\n"
    "  for (uint i = 0; i < 3; i++) { uint n = 0; while (n < 8) { n++; v ^= in[4 * t + (n & 3)] + i; if ((i & v & 3) == 0) break; } out[11 * t + i] = n; }\n"
    "  for (uint i = 0; i < 3; i++) { uint n = 0; while (n < 8) { n++; u ^= in[4 * t + (n & 3)] + i; if (((i >> (u & 1)) & 3) == 0) break; } out[11 * t + 3 + i] = n; }\n"
    "  for (uint i = 0; i < 3; i++) { uint n = 0; while (n < 8) { n++; w ^= in[4 * t + (n & 3)] + i; if (((i >> (w & 31)) & 3) == 0) break; } out[11 * t + 6 + i] = n; }\n"
    "  uint z = in[4 * t + 2] * 5u + t, m = in[4 * t + 2] | 1u;\n"
    "  for (uint i = 0; i < 2; i++) { uint n = 0; while (n < 8) { n++; if (((i <= z ? 0x80000000u : i % m) & 3) == 0) break; } z += n; out[11 * t + 9 + i] = n; }\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a31-amd-counter-bit-test";
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
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * kOut * 4 options:MTLResourceStorageModeShared];
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
            const uint32_t *a = input + 4 * t;
            uint32_t want[kOut], v = a[1] * 11u + (uint32_t)t, u = v, w = v;
            for (uint32_t i = 0; i < 3; i++) {
                uint32_t n = 0;
                while (n < 8) { n++; v ^= a[n & 3] + i; if ((i & v & 3) == 0) break; }
                want[i] = n;
                n = 0;
                while (n < 8) { n++; u ^= a[n & 3] + i; if (((i >> (u & 1)) & 3) == 0) break; }
                want[3 + i] = n;
                n = 0;
                while (n < 8) { n++; w ^= a[n & 3] + i; if (((i >> (w & 31)) & 3) == 0) break; }
                want[6 + i] = n;
            }
            uint32_t z = a[2] * 5u + (uint32_t)t, m = a[2] | 1u;
            for (uint32_t i = 0; i < 2; i++) {
                uint32_t n = 0;
                while (n < 8) { n++; if (((i <= z ? 0x80000000u : i % m) & 3) == 0) break; }
                z += n;
                want[9 + i] = n;
            }
            for (int k = 0; k < kOut; k++)
                if (got[kOut * t + k] != want[k]) { if (first < 0) first = kOut * t + k; wrong++; }
        }
        if (wrong) {
            int t = first / kOut, k = first % kOut;
            return FAIL(bug, "%s: %d of %d trip counts wrong (thread %d, loop %d: got %u)", dev.name.UTF8String, wrong, kThreads * kOut, t, k, got[first]);
        }
        return PASS(bug, "%s: inner loop exits on bits of values and'ed with or shifting the outer counter", dev.name.UTF8String);
    }
}
