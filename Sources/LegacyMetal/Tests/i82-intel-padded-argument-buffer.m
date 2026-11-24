// i82-intel-padded-argument-buffer: WebKit's argument buffers (references, then lengths) must work on Ivy Bridge;
// stores went into the argument buffer itself. Fix: IntelTextureAtomics INTEL_IVB_PADDED_ARGUMENT_BUFFER_FIX.
// Checks: a kernel writes two buffers and adds to an atomic through such an argument buffer. Argument: GPU name.
#import "repro.h"

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Bindings {\n"
    "    device array<uint, 1> &out [[id(0)]];\n"
    "    device array<float, 1> &fout [[id(1)]];\n"
    "    device atomic_uint &total [[id(2)]];\n"
    "    uint outLength [[id(3)]];\n"
    "    uint foutLength [[id(4)]];\n"
    "    uint totalLength [[id(5)]];\n"
    "};\n"
    "kernel void k(uint i [[thread_position_in_grid]], uint li [[thread_index_in_threadgroup]], constant Bindings &b [[buffer(0)]]) {\n"
    "    threadgroup array<uint, 64> shared_;\n"
    "    uint acc = 0u;\n"
    "    for (uint k = 0u; k <= i % 13u; k++) acc += (i * 7u + k * k) ^ (k << 3u);\n"
    "    shared_[min(li, 63u)] = acc;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    b.out[min(i, b.outLength / 4u - 1u)] = acc + shared_[min(63u - li, 63u)] / 2u;\n"
    "    b.fout[min(i, b.foutLength / 4u - 1u)] = sqrt(float(i) + 1.0) * 0.5 + float(i % 5u) * 0.25;\n"
    "    atomic_fetch_add_explicit(&b.total, i, memory_order_relaxed);\n"
    "}\n";

static unsigned accOf(unsigned i) {
    unsigned a = 0;
    for (unsigned k = 0; k <= i % 13; k++) a += (i * 7 + k * k) ^ (k << 3);
    return a;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i82-intel-padded-argument-buffer";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: compile: %s", name, error.localizedDescription.UTF8String);
        id<MTLFunction> f = [lib newFunctionWithName:@"k"];
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&error];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, error.localizedDescription.UTF8String);
        enum { N = 256 };
        id<MTLBuffer> out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> fout = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> total = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        memset(out.contents, 0, N * 4);
        memset(fout.contents, 0, N * 4);
        memset(total.contents, 0, 4);
        id<MTLArgumentEncoder> encoder = [f newArgumentEncoderWithBufferIndex:0];
        if (!encoder) return FAIL(bug, "%s: no argument encoder", name);
        id<MTLBuffer> bindings = [dev newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
        [encoder setArgumentBuffer:bindings offset:0];
        [encoder setBuffer:out offset:0 atIndex:0];
        [encoder setBuffer:fout offset:0 atIndex:1];
        [encoder setBuffer:total offset:0 atIndex:2];
        *(uint32_t *)[encoder constantDataAtIndex:3] = N * 4;
        *(uint32_t *)[encoder constantDataAtIndex:4] = N * 4;
        *(uint32_t *)[encoder constantDataAtIndex:5] = 4;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:bindings offset:0 atIndex:0];
        [ce useResource:out usage:MTLResourceUsageWrite];
        [ce useResource:fout usage:MTLResourceUsageWrite];
        [ce useResource:total usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [ce dispatchThreadgroups:MTLSizeMake(N / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        const float *fo = fout.contents;
        for (unsigned i = 0; i < N; i++) {
            unsigned g = i / 64 * 64, want = accOf(i) + accOf(g + 63 - (i - g)) / 2;
            if (o[i] != want) return FAIL(bug, "%s: out[%u] = %u, want %u (stores through the argument buffer's references)", name, i, o[i], want);
            float fw = sqrtf(i + 1.0f) * 0.5f + (i % 5) * 0.25f;
            if (fabsf(fo[i] - fw) > 1e-5f * fmaxf(1.0f, fw)) return FAIL(bug, "%s: fout[%u] = %g, want %g", name, i, fo[i], fw);
        }
        uint32_t t = *(uint32_t *)total.contents;
        if (t != N * (N - 1) / 2) return FAIL(bug, "%s: atomic total %u, want %u", name, t, N * (N - 1) / 2);
        return PASS(bug, "%s: a kernel writes two buffers and an atomic through an argument buffer of references and lengths (WebKit's WebGPU bind groups)", name);
    }
}
