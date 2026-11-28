// a06-fast-math-nan-compare: an ordered compare must be false for NaN, also with fast math; libAMDIL902 branched on the
// inverse (EEVEE dropped all volume lighting). Fix: AMDTextureAtomics AMD_NAN_FIX.
// Checks: EEVEE's safe_normalize(sum / weight) of 0/0 takes its fallback. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "float3 safe_normalize_and_get_length(float3 vector, thread float &out_length) {\n"  // Blender's gpu_shader_math
    "  out_length = dot(vector, vector);\n"
    "  constexpr float threshold = 1e-35f;\n"
    "  if (out_length > threshold) {\n"
    "    out_length = sqrt(out_length);\n"
    "    return vector / out_length;\n"
    "  }\n"
    "  out_length = 0.0f;\n"
    "  float3 result = float3(0.0f);\n"
    "  result[0] = 1.0f;\n"
    "  return result;\n"
    "}\n"
    "kernel void k(device float4 *out [[buffer(0)]], constant float4 *sums [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  float len;\n"
    "  float3 direction = safe_normalize_and_get_length(sums[i].xyz / sums[i].w, len);\n"
    "  out[i] = float4(direction, len);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a06-fast-math-nan-compare";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        // A weighted direction sum with weight 0 (no sun: 0/0 = NaN -> fallback (1, 0, 0), length 0) and a normal one.
        const float sums[2][4] = {{0, 0, 0, 0}, {6, 0, 8, 2}};
        const float want[2][4] = {{1, 0, 0, 0}, {0.6f, 0, 0.8f, 5}};
        id<MTLBuffer> in = [dev newBufferWithBytes:sums length:sizeof sums options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:sizeof sums options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:out offset:0 atIndex:0]; [e setBuffer:in offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const float (*o)[4] = out.contents;
        for (int i = 0; i < 2; i++)
            for (int c = 0; c < 4; c++)
                if (!(fabsf(o[i][c] - want[i][c]) < 1e-5f))
                    return FAIL(bug, "%s: safe_normalize(%g/%g, %g/%g, %g/%g) = (%g, %g, %g), length %g; want (%g, %g, %g), length %g",
                                dev.name.UTF8String, sums[i][0], sums[i][3], sums[i][1], sums[i][3], sums[i][2], sums[i][3],
                                o[i][0], o[i][1], o[i][2], o[i][3], want[i][0], want[i][1], want[i][2], want[i][3]);
        return PASS(bug, "%s: safe_normalize of 0/0 takes its fallback, a normal vector normalizes", dev.name.UTF8String);
    }
}
