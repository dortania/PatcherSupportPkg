// a10-threadgroup-bool (AMD adapter): a threadgroup bool must read back what was stored. LLVM shrinks the variable to an i1
// global and libAMDIL902 miscompiles zext of its load, `iand load, r` with r holding an unrelated 0, so it always reads as false.
// (WebGPU CTS builtin,workgroupUniformLoad:types, type="bool", in Safari; the shader here is the one WebKit generates.)
// When the front end leaves the variable a byte, libAMDIL902's own optimizer shrinks it after the adapter has run, and the
// same zext comes back (`shrunk`: found by differential fuzzing; there it reads as false in the first threadgroup, which
// sets it): the adapter loads such variables as volatile, which keeps the optimizer from shrinking them.
// The 3802 Intel compiler can't select the i1 loads and stores at all and aborts; the Intel adapter widens the global to i8.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "template<typename T> static T loadBetweenBarriers(threadgroup T* const ptr) {\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    auto result = *ptr;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    return result;\n"
    "}\n"
    "template<typename T> static void zero(threadgroup T& v) {\n"
    "    threadgroup char* p = (threadgroup char*)(&v);\n"
    "    for (uint i = 0u; i < sizeof(T); i++) p[i] = 0;\n"
    "}\n"
    "kernel void stored(uint index [[thread_index_in_threadgroup]], device uint *o [[buffer(0)]]) {\n"
    "    threadgroup bool v { };\n"
    "    if (index == 0u) zero(v);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (index == 0u) v = true;\n"
    "    o[0] = uint(loadBetweenBarriers(&v));\n"
    "}\n"
    "kernel void notStored(uint index [[thread_index_in_threadgroup]], device uint *o [[buffer(0)]]) {\n"
    "    threadgroup bool v { };\n"
    "    if (index == 0u) zero(v);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (index == 1000u) v = true;\n"
    "    o[0] = uint(loadBetweenBarriers(&v));\n"
    "}\n"
    "kernel void shrunk(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "                   uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup bool tb;\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    uint v0 = in[t * 4u] + t, v1 = in[t * 4u + 1u] * 3u + t, v3 = in[t * 4u + 3u] * 7u + t, v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    if (l == 0) tb = false;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (t == 0u) tb = true;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    v1 += tb ? 1u : 2u;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    if (l == 0) tb = false;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    v5 += tb ? 1u : 2u;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    thread uint *q = ((in[1] == 0u ? 0u : v1) & 1u) ? &p[0] : &p[3];\n"
    "    *q += v3;\n"
    "    v0 += *q;\n"
    "    out[t * 4u] = v0;\n"
    "    out[t * 4u + 1u] = ((v0 + 1u) <= v0 ? 1u : (2568631996u / (v0 | 1u))) & 1u;\n"
    "    out[t * 4u + 2u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];\n"
    "    out[t * 4u + 3u] = v5;\n"
    "}\n";

// `shrunk` on the CPU: 256 threads, 64 per threadgroup; only the first threadgroup sets tb.
static void shrunkReference(const uint32_t *in, uint32_t t, uint32_t out[4]) {
    uint32_t p[8];
    for (uint32_t j = 0; j < 8; j++) p[j] = in[t * 4 + (j & 3)] + j;
    uint32_t v0 = in[t * 4] + t, v1 = in[t * 4 + 1] * 3 + t, v3 = in[t * 4 + 3] * 7 + t, v5 = in[t * 4 + 1] * 11 + t;
    v1 += t < 64 ? 1 : 2;
    v5 += 2;
    uint32_t *q = ((in[1] == 0 ? 0 : v1) & 1) ? &p[0] : &p[3];
    *q += v3;
    v0 += *q;
    out[0] = v0;
    out[1] = (v0 + 1 <= v0 ? 1 : 2568631996u / (v0 | 1)) & 1;
    out[2] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];
    out[3] = v5;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a10-threadgroup-bool";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { const char *kernel; uint32_t want; } cases[] = {{"stored", 1}, {"notStored", 0}};
        for (int c = 0; c < 2; c++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(cases[c].kernel)] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline %s: %s", dev.name.UTF8String, cases[c].kernel, err.localizedDescription.UTF8String);
            id<MTLBuffer> o = [dev newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
            *(uint32_t *)o.contents = 0xdeadbeef;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:ps];
            [e setBuffer:o offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [e endEncoding];
            reproRun(cb);
            uint32_t got = *(uint32_t *)o.contents;
            if (got != cases[c].want) return FAIL(bug, "%s: %s read %u, want %u", dev.name.UTF8String, cases[c].kernel, got, cases[c].want);
        }
        // shrunk, with the input the fuzzer gave it (xorshift; every 7th word small)
        enum { T = 256 };
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"shrunk"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline shrunk: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        uint32_t x = 2654435761u + 12345u, *words = in.contents;
        for (int i = 0; i < T * 4; i++) {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            words[i] = i % 7 == 0 ? (x & 0xff) : x;
        }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps];
        [e setBuffer:in offset:0 atIndex:0];
        [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: shrunk: command buffer failed", dev.name.UTF8String);
        int wrong = 0, first = -1;
        for (uint32_t t = 0; t < T; t++) {
            uint32_t want[4];
            shrunkReference(words, t, want);
            if (memcmp(want, (uint32_t *)out.contents + t * 4, sizeof want) && wrong++ == 0) first = (int)t;
        }
        if (wrong) return FAIL(bug, "%s: shrunk: %d of %d threads wrong (first %d)", dev.name.UTF8String, wrong, T, first);
        return PASS(bug, "%s: a threadgroup bool reads back what was stored", dev.name.UTF8String);
    }
}
