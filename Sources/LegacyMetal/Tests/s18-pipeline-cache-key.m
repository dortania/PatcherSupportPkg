// s18-pipeline-cache-key (MetalOldCompat item 18; the Blender EEVEE GPU hang): MetalOld's pipeline cache keys compute
// pipelines on AMD/Intel by an AIRNT "function id" whose pipeline-script hashes are zero on this stack (they come from
// GPUCompiler 31001's libGPUCompilerUtils, weak-linked and absent on Sequoia). So every compute pipeline of a function
// shares one cache entry whatever its descriptor: Blender's recompile of eevee_shadow_tilemap_finalize with
// maxTotalThreadsPerThreadgroup = 1024 got the cached 768-thread pipeline back, dispatched 1024 threads, and hung the
// AMD GPU (repeated GPU channel resets, WindowServer killed). The fix lets MetalOld key by the driver's function key
// (MTL_USE_AIRNT_BA=0). This program builds a register-heavy kernel without and then with the descriptor limit and
// compares the pipelines' maxTotalThreadsPerThreadgroup (in both orders, against cold references). It never dispatches
// anything. On a GPU whose compiler doesn't raise the kernel to 1024 threads (the Intel GPU here) it SKIPs.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "float4x4 inv(float4x4 m) {\n"
    "  float4x4 r; float d = determinant(m);\n"
    "  for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {\n"
    "    float3x3 s; int a = 0;\n"
    "    for (int x = 0; x < 4; x++) { if (x == i) continue; int b = 0;\n"
    "      for (int y = 0; y < 4; y++) { if (y == j) continue; s[a][b] = m[x][y]; b++; } a++; }\n"
    "    r[j][i] = (((i + j) & 1) ? -1.0 : 1.0) * determinant(s) / d; }\n"
    "  return r; }\n"
    "kernel void k(device float4x4 *in [[buffer(0)]], device float4x4 *out [[buffer(1)]],\n"
    "              uint id [[thread_position_in_grid]], uint l [[thread_index_in_threadgroup]]) {\n"
    "  threadgroup atomic_int t; if (l == 0) atomic_store_explicit(&t, 0, memory_order_relaxed);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  float4x4 a = in[id], b = in[id + 1], c = in[id + 2], e = in[id + 3];\n"
    "  float4x4 ia = inv(a), ib = inv(b), ic = inv(c), ie = inv(e);\n"
    "  atomic_fetch_add_explicit(&t, 1, memory_order_relaxed);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  float4x4 r = ia * b + ib * c + ic * e + ie * a; r[3][3] += float(atomic_load_explicit(&t, memory_order_relaxed)) + SALT; out[id] = r;\n"
    "}\n";

static NSUInteger pipelineLimit(id<MTLDevice> dev, id<MTLLibrary> lib, NSUInteger limit, NSError **err) {
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
    d.computeFunction = [lib newFunctionWithName:@"k"];
    if (limit) d.maxTotalThreadsPerThreadgroup = limit;
    return [dev newComputePipelineStateWithDescriptor:d options:0 reflection:nil error:err].maxTotalThreadsPerThreadgroup;
}

// A library whose AIR is new to every cache (SALT differs per call).
static id<MTLLibrary> freshLibrary(id<MTLDevice> dev, NSError **err) {
    static int serial;
    NSString *salt = [NSString stringWithFormat:@"#define SALT %d.0e-30f\n", getpid() * 100 + serial++];
    return [dev newLibraryWithSource:[salt stringByAppendingString:src] options:nil error:err];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s18-pipeline-cache-key";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> a = freshLibrary(dev, &err), b = freshLibrary(dev, &err), c = freshLibrary(dev, &err);
        if (!a || !b || !c) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        // Cold references, each the first pipeline of its library.
        NSUInteger plainCold = pipelineLimit(dev, a, 0, &err), limitedCold = pipelineLimit(dev, b, 1024, &err);
        if (!plainCold || !limitedCold) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        if (plainCold >= 1024) return SKIP(bug, "%s: the kernel already allows %lu threads (no register pressure on this GPU)", dev.name.UTF8String, (unsigned long)plainCold);
        if (limitedCold < 1024)
            return SKIP(bug, "%s: this GPU's compiler gives the kernel %lu threads even with the descriptor limit 1024, so the cache mix-up can't show",
                        dev.name.UTF8String, (unsigned long)limitedCold);
        // Blender's order (plain, then limited) and the reverse, on libraries that have one pipeline already.
        NSUInteger limitedAfter = pipelineLimit(dev, c, 0, &err) ? pipelineLimit(dev, c, 1024, &err) : 0;
        NSUInteger plainAfter = pipelineLimit(dev, b, 0, &err);
        if (limitedAfter != limitedCold || plainAfter != plainCold)
            return FAIL(bug, "%s: maxTotalThreadsPerThreadgroup = 1024 after a plain pipeline: %lu (want %lu); plain after a limited one: %lu (want %lu)",
                        dev.name.UTF8String, (unsigned long)limitedAfter, (unsigned long)limitedCold, (unsigned long)plainAfter, (unsigned long)plainCold);
        return PASS(bug, "%s: plain %lu threads, descriptor limit 1024 -> 1024, in either order", dev.name.UTF8String, (unsigned long)plainCold);
    }
}
