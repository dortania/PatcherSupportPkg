// a04-si-threadgroup-pointer (AMD adapter, GCN1/SI): threadgroup memory reached through a pointer kept in thread memory.
// Blender's MSL keeps compute shared variables as `threadgroup float (&array)[N]` members of its shader class, and
// EEVEE's depth-of-field resolve computes a per-tile max through one (parallelMax). libAMDIL902 builds such a pointer
// as user data API slot 8 + the variable's LDS offset, while direct accesses use the bare offset; slot 8 isn't 0 on
// this stack, so reads through the pointer are out of range and return 0 (EEVEE: everything slightly out of focus
// rendered black; render tests camera_depth_of_field, camera_ortho_depth_of_field_near_clip). Each 256-thread group
// does Blender's reduction through the reference and compares with the known max.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "class Impl {\n"  // the shape of Blender's generated MSL (mtl_shader_generator.mm)
    "public:\n"
    "  threadgroup float (&array_of_values)[256];\n"
    "  threadgroup uint &shared_flag;\n"
    "  uint gl_LocalInvocationIndex;\n"
    "  float scratch_values[16];\n"
    "  Impl(threadgroup float (&a)[256], threadgroup uint &f) : array_of_values(a), shared_flag(f) {}\n"
    "  float parallelMax(const float value) {\n"
    "    uint thread_id = gl_LocalInvocationIndex;\n"
    "    array_of_values[thread_id] = value;\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device | mem_flags::mem_texture);\n"
    "    for (uint i = 256; i > 0; i >>= 1) {\n"
    "      uint half_width = i >> 1;\n"
    "      if (thread_id < half_width) array_of_values[thread_id] = max(array_of_values[thread_id], array_of_values[thread_id + half_width]);\n"
    "      threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device | mem_flags::mem_texture);\n"
    "    }\n"
    "    return array_of_values[0];\n"
    "  }\n"
    "  void main(device float *out, constant uint &sel, uint gid, uint group) {\n"
    "    for (int i = 0; i < 16; i++) scratch_values[i] = float(gid + i);\n"
    "    float v = float((gl_LocalInvocationIndex * 37u) % 256u) * 0.01f + float(group);\n"
    "    float m = parallelMax(v + scratch_values[sel & 15u] * 0.0f);\n"
    "    out[gid] = m;\n"
    "  }\n"
    "};\n"
    "kernel void k(device float *out [[buffer(0)]], constant uint &sel [[buffer(1)]],\n"
    "              uint tid [[thread_index_in_threadgroup]], uint gid [[thread_position_in_grid]],\n"
    "              uint group [[threadgroup_position_in_grid]]) {\n"
    "  threadgroup float array_of_values[256]; threadgroup uint shared_flag;\n"
    "  Impl impls[2] = {Impl(array_of_values, shared_flag), Impl(array_of_values, shared_flag)};\n"
    "  thread Impl &impl = impls[sel & 1u];\n"  // dynamically indexed: the instance stays in thread memory, as Blender's does
    "  impl.gl_LocalInvocationIndex = tid;\n"
    "  impl.main(out, sel, gid, group);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a04-si-threadgroup-pointer";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        if (ps.maxTotalThreadsPerThreadgroup < 256) return SKIP(bug, "pipeline allows only %lu threads", (unsigned long)ps.maxTotalThreadsPerThreadgroup);
        const uint32_t groups = 16, N = groups * 256, sel = 3;
        id<MTLBuffer> out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&sel length:4 atIndex:1];
        [e dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const float *o = out.contents;
        uint32_t bad = 0;
        float got = 0, want = 0;
        for (uint32_t i = 0; i < N; i++) {
            float w = 2.55f + (float)(i / 256);  // max over the group of ((tid * 37) % 256) * 0.01 + group
            if (fabsf(o[i] - w) > 1e-3f && !bad++) { got = o[i]; want = w; }
        }
        if (bad) return FAIL(bug, "%s: threadgroup max through a reference member wrong in %u of %u threads (e.g. %g, want %g)",
                             dev.name.UTF8String, bad, N, got, want);
        return PASS(bug, "%s: threadgroup max through a reference member correct in all %u threads", dev.name.UTF8String, N);
    }
}
