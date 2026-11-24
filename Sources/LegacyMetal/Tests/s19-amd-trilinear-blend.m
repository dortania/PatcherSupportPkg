// s19-amd-trilinear-blend: linear mip filtering must blend linearly; the AMD driver, and Haswell in kernels, blended
// only mid-interval (EEVEE lost light). Fix: AMDBronzeCompat item 3 AMD_BRONZE_COMPAT, IntelTextureAtomics
// INTEL_COMPUTE_TRILINEAR_FIX. Checks: levels 0 and 1 holding 0 and 1, sampled at 0.25, 0.5, 0.75. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *out [[buffer(0)]],\n"
    "              uint i [[thread_position_in_grid]]) {\n"
    "  out[i] = t.sample(s, float2(0.5f), level(0.25f * float(i + 1))).x;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s19-amd-trilinear-blend";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:YES];
        td.mipmapLevelCount = 2;
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        const float level0[16] = {0}, level1[4] = {1, 1, 1, 1};
        [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:level0 bytesPerRow:16];
        [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1 withBytes:level1 bytesPerRow:8];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterLinear;  // Blender's HiZ sampler: nearest texels, linear between levels
        id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [dev newBufferWithLength:12 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setTexture:t atIndex:0]; [e setSamplerState:s atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
        [e dispatchThreads:MTLSizeMake(3, 1, 1) threadsPerThreadgroup:MTLSizeMake(3, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const float *o = out.contents;
        for (int i = 0; i < 3; i++)
            if (!(fabsf(o[i] - 0.25f * (i + 1)) < 0.02f))
                return FAIL(bug, "%s: levels 0.25/0.5/0.75 return %.3f/%.3f/%.3f of the way to the next level (want 0.25/0.5/0.75)",
                            dev.name.UTF8String, o[0], o[1], o[2]);
        return PASS(bug, "%s: levels 0.25/0.5/0.75 blend linearly (%.3f/%.3f/%.3f)", dev.name.UTF8String, o[0], o[1], o[2]);
    }
}
