// a10-threadgroup-bool (AMD adapter): a threadgroup bool must read back what was stored. LLVM shrinks the variable to an i1
// global and libAMDIL902 miscompiles zext of its load, `iand load, r` with r holding an unrelated 0, so it always reads as false.
// (WebGPU CTS builtin,workgroupUniformLoad:types, type="bool", in Safari; the shader here is the one WebKit generates.)
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
    "}\n";

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
        return PASS(bug, "%s: a threadgroup bool reads back what was stored", dev.name.UTF8String);
    }
}
