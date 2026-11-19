// n18-kepler-threadgroup-cmpxchg (Kepler adapter, NVAIR_LOCAL_CMPXCHG): atomic_compare_exchange_weak_explicit on a
// threadgroup atomic. When the exchange failed, Kepler left *expected as it was instead of the value it found, so the
// old value came back as the comparand (WebGPU CTS atomicCompareExchangeWeak compare_exchange_weak_workgroup_basic: every
// exchange that fails; the device-memory form is right): the plugin's threadgroup body lacks the store its device body
// makes. Uncontended (each thread on its own atomic, every third exchange meant to succeed), int and uint; then a
// contended loop that adds 1 to one threadgroup counter from 256 threads with compare-exchange, which only terminates
// right when a failed exchange returns the value it found.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void single(device uint *old [[buffer(0)]], device uint *exchanged [[buffer(1)]], device uint *after [[buffer(2)]],\n"
    "                   uint lid [[thread_index_in_threadgroup]], uint3 group [[threadgroup_position_in_grid]]) {\n"
    "    threadgroup atomic_uint cells[64];\n"
    "    uint g = group.x * 64 + lid;\n"
    "    atomic_store_explicit(&cells[lid], g, memory_order_relaxed);\n"
    "    uint expected = (g % 3 == 0) ? g : g + 1;\n"
    "    bool ok = atomic_compare_exchange_weak_explicit(&cells[lid], &expected, g * 2, memory_order_relaxed, memory_order_relaxed);\n"
    "    old[g] = expected; exchanged[g] = ok ? 1 : 0; after[g] = atomic_load_explicit(&cells[lid], memory_order_relaxed); }\n"
    "kernel void signedSingle(device int *old [[buffer(0)]], uint lid [[thread_index_in_threadgroup]]) {\n"
    "    threadgroup atomic_int cells[64];\n"
    "    int v = -int(lid) - 5;\n"
    "    atomic_store_explicit(&cells[lid], v, memory_order_relaxed);\n"
    "    int expected = v + 1;  // never matches\n"
    "    atomic_compare_exchange_weak_explicit(&cells[lid], &expected, 7, memory_order_relaxed, memory_order_relaxed);\n"
    "    old[lid] = expected; }\n"
    "kernel void counter(device uint *total [[buffer(0)]], uint lid [[thread_index_in_threadgroup]]) {\n"
    "    threadgroup atomic_uint c;\n"
    "    if (lid == 0) atomic_store_explicit(&c, 0, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    uint expected = atomic_load_explicit(&c, memory_order_relaxed);\n"
    "    for (uint tries = 0; tries < 100000; tries++)\n"
    "        if (atomic_compare_exchange_weak_explicit(&c, &expected, expected + 1, memory_order_relaxed, memory_order_relaxed)) break;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (lid == 0) total[0] = atomic_load_explicit(&c, memory_order_relaxed); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n18-kepler-threadgroup-cmpxchg";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLComputePipelineState> single = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"single"] error:&err];
    id<MTLComputePipelineState> signedSingle = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"signedSingle"] error:&err];
    id<MTLComputePipelineState> counter = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"counter"] error:&err];
    if (!single || !signedSingle || !counter) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    const NSUInteger N = 256;
    id<MTLBuffer> old = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> exchanged = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> after = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> signedOld = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> total = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    memset(old.contents, 0xee, N * 4);
    memset(total.contents, 0, 4);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:single];
    [ce setBuffer:old offset:0 atIndex:0];
    [ce setBuffer:exchanged offset:0 atIndex:1];
    [ce setBuffer:after offset:0 atIndex:2];
    [ce dispatchThreadgroups:MTLSizeMake(N / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce setComputePipelineState:signedSingle];
    [ce setBuffer:signedOld offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce setComputePipelineState:counter];
    [ce setBuffer:total offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    for (NSUInteger g = 0; g < N; g++) {
        uint32_t o = ((uint32_t *)old.contents)[g], e = ((uint32_t *)exchanged.contents)[g], a = ((uint32_t *)after.contents)[g];
        BOOL want = g % 3 == 0;
        if (e != (uint32_t)want || a != (want ? g * 2 : g))
            return FAIL(bug, "%s: thread %lu: exchanged %u, value after %u, want %u and %lu", name, (unsigned long)g, e, a, (unsigned)want,
                        (unsigned long)(want ? g * 2 : g));
        if (o != g)
            return FAIL(bug, "%s: thread %lu: a %s threadgroup compare-exchange gave old value %u, want %lu (the value it found)", name,
                        (unsigned long)g, want ? "succeeding" : "failed", o, (unsigned long)g);
    }
    for (int i = 0; i < 64; i++)
        if (((int32_t *)signedOld.contents)[i] != -i - 5)
            return FAIL(bug, "%s: an int threadgroup compare-exchange that failed gave old value %d, want %d", name, ((int32_t *)signedOld.contents)[i], -i - 5);
    if (*(uint32_t *)total.contents != 256)
        return FAIL(bug, "%s: 256 threads adding 1 to a threadgroup counter with compare-exchange loops left %u", name, *(uint32_t *)total.contents);
    return PASS(bug, "%s: threadgroup compare-exchanges return the value they found (uint, int, and a contended counter of 256)", name);
}}
