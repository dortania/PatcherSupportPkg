// a19-amd-float-atomics (AMD adapter): MSL 3.0 float atomics in device memory (atomic_fetch_add / _sub, exchange,
// compare-exchange on atomic_float) must compile and be atomic. The GPU claims the Mac2 family, which has them, but the
// AMD compiler has no float forms and stops with an internal error (wgpu float32_atomic). The adapter does exchange and
// compare-exchange on the integer bits and fetch_add / fetch_sub as a compare-exchange loop.
// Checked: 4096 threads on the same addresses: fetch_add of 1 returns each of 0..4095 once and ends at 4096; fetch_add
// of t & 7 and fetch_sub of 0.5 end at the exact sums; exchange returns every value once; one compare-exchange from 0
// succeeds.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 4096 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device atomic_float *acc [[buffer(0)]], device float *old [[buffer(1)]], device uint *won [[buffer(2)]], uint t [[thread_position_in_grid]]) {\n"
    "  old[t] = atomic_fetch_add_explicit(&acc[0], 1.0f, memory_order_relaxed);\n"
    "  atomic_fetch_add_explicit(&acc[1], float(t & 7u), memory_order_relaxed);\n"
    "  atomic_fetch_sub_explicit(&acc[2], 0.5f, memory_order_relaxed);\n"
    "  old[kThreads + t] = atomic_exchange_explicit(&acc[3], float(t + 1u), memory_order_relaxed);\n"
    "  float expected = 0.0f;\n"
    "  won[t] = uint(atomic_compare_exchange_weak_explicit(&acc[4], &expected, float(t + 1u), memory_order_relaxed, memory_order_relaxed));\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a19-amd-float-atomics";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        if (![dev supportsFamily:MTLGPUFamilyMac2] && ![dev supportsFamily:MTLGPUFamilyApple7])
            return SKIP(bug, "%s: float atomics need the Mac2 or Apple7 family", dev.name.UTF8String);
        NSError *err = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        NSString *source = [[reproUniqueComment() stringByAppendingString:@"constant uint kThreads = 4096;\n"] stringByAppendingString:src];
        id<MTLLibrary> lib = [dev newLibraryWithSource:source options:options error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLBuffer> acc = [dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> old = [dev newBufferWithLength:2 * kThreads * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> won = [dev newBufferWithLength:kThreads * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(acc.contents, 0, acc.length);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:acc offset:0 atIndex:0]; [e setBuffer:old offset:0 atIndex:1]; [e setBuffer:won offset:0 atIndex:2];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const float *a = acc.contents, *o = old.contents;
        const uint32_t *w = won.contents;
        static uint8_t seen[kThreads + 1];
        memset(seen, 0, sizeof seen);
        for (int t = 0; t < kThreads; t++) {
            float v = o[t];
            if (v < 0 || v >= kThreads || v != (float)(int)v || seen[(int)v]++)
                return FAIL(bug, "%s: fetch_add of 1: thread %d got %g (a value twice or out of range: not atomic)", dev.name.UTF8String, t, v);
        }
        float sum7 = 0;
        for (int t = 0; t < kThreads; t++) sum7 += (float)(t & 7);
        if (a[0] != kThreads || a[1] != sum7 || a[2] != -0.5f * kThreads)
            return FAIL(bug, "%s: sums %g %g %g, want %d %g %g", dev.name.UTF8String, a[0], a[1], a[2], kThreads, sum7, -0.5f * kThreads);
        memset(seen, 0, sizeof seen);
        seen[(int)a[3]]++;
        for (int t = 0; t < kThreads; t++) {
            float v = o[kThreads + t];
            if (v < 0 || v > kThreads || v != (float)(int)v || seen[(int)v]++)
                return FAIL(bug, "%s: exchange: thread %d got %g (a value twice or out of range)", dev.name.UTF8String, t, v);
        }
        int winners = 0, winner = -1;
        for (int t = 0; t < kThreads; t++) if (w[t]) { winners++; winner = t; }
        if (winners != 1 || a[4] != (float)(winner + 1))
            return FAIL(bug, "%s: compare-exchange from 0: %d winners, value %g", dev.name.UTF8String, winners, a[4]);
        return PASS(bug, "%s: atomic_float fetch_add, fetch_sub, exchange and compare-exchange from %d threads on the same addresses",
                    dev.name.UTF8String, kThreads);
    }
}
