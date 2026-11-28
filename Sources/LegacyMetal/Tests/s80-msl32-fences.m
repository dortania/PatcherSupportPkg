// s80-msl32-fences: SPIRV-Cross's MSL 3.2 atomic_thread_fence must compile and order memory; the 3.1 front end lacks it
// (Godot). Fix: MetalOldCompat item 9.
// Checks: it compiles, and threads read what others wrote before the fence. Argument: GPU name.
#import "repro.h"

static const char *source =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device uint *out [[buffer(0)]], uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup uint tg[64];\n"
    "    tg[l] = t * 3u + 1u;\n"
    "    atomic_thread_fence(mem_flags::mem_threadgroup, memory_order_seq_cst, thread_scope_threadgroup);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    uint v = tg[63u - l];\n"
    "    atomic_thread_fence(mem_flags::mem_device | mem_flags::mem_threadgroup | mem_flags::mem_texture, memory_order_seq_cst, thread_scope_device);\n"
    "    atomic_thread_fence(mem_flags::mem_threadgroup, memory_order_relaxed, thread_scope_simdgroup);\n"
    "    out[t] = v;\n"
    "    atomic_thread_fence(mem_flags::mem_device, memory_order_relaxed);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s80-msl32-fences";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = (MTLLanguageVersion)0x30002;  // MTLLanguageVersion3_2, as MoltenVK sets it on macOS 15
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(source) options:options error:&error];
        if (!lib) return FAIL(bug, "%s: MSL 3.2 kernel with fences: %s", name,
                              [error.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, error.localizedDescription.UTF8String);
        enum { N = 256 };
        id<MTLBuffer> out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        if (!reproDispatch([dev newCommandQueue], ps, @[out], MTLSizeMake(N / 64, 1, 1), MTLSizeMake(64, 1, 1)))
            return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        for (uint32_t t = 0; t < N; t++) {
            uint32_t want = ((t & ~63u) + 63u - (t & 63u)) * 3u + 1u;
            if (o[t] != want) return FAIL(bug, "%s: thread %u read %u, want %u", name, t, o[t], want);
        }
        return PASS(bug, "%s: an MSL 3.2 kernel with atomic_thread_fence at threadgroup and device scope compiles and synchronizes", name);
    }
}
