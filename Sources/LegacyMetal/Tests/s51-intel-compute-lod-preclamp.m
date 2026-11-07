// s51-intel-compute-lod-preclamp (MetalOldCompat item 40): an explicit level at or below 0 in a compute kernel, through a
// sampler with a fractional lodMinClamp. The kernel's sampler-state template that CHAL_INTEL::ChalContext::
// PatchSamplerObject fills has LOD PreClamp Enable clear, so the hardware chose between the min and mag filters on the
// unclamped LOD: level 0 or below magnified and read the base level alone, where the clamp to 0.25 should have blended
// a quarter of level 1 in (WebGPU CTS textureSampleLevel lodClamp in compute, linear filter: 90 cases; vertex and
// fragment functions were right). A 4x4 R32Float texture whose levels 0-2 hold 0, 1 and 2 is sampled with a linear
// sampler clamped to [0.25, 1.75] at levels -0.24, 0, 0.5 and 2.5.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <math.h>

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float *level [[buffer(0)]],\n"
    "              device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "    out[i] = t.sample(s, float2(0.5), metal::level(level[i])).x;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s51-intel-compute-lod-preclamp";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:YES];
        id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
        for (int l = 0; l < 3; l++) {
            float texels[16];
            for (int i = 0; i < 16; i++) texels[i] = l;
            [texture replaceRegion:MTLRegionMake2D(0, 0, 4 >> l, 4 >> l) mipmapLevel:l withBytes:texels bytesPerRow:(4 >> l) * 4];
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterLinear;
        sd.lodMinClamp = 0.25f;
        sd.lodMaxClamp = 1.75f;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        float levels[4] = {-0.24f, 0.0f, 0.5f, 2.5f}, want[4] = {0.25f, 0.25f, 0.5f, 1.75f};
        id<MTLBuffer> levelBuffer = [dev newBufferWithBytes:levels length:sizeof levels options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:sizeof levels options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setTexture:texture atIndex:0];
        [ce setSamplerState:sampler atIndex:0];
        [ce setBuffer:levelBuffer offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const float *o = out.contents;
        for (int i = 0; i < 4; i++)
            if (fabsf(o[i] - want[i]) > 1.0f / 32)
                return FAIL(bug, "%s: compute sample at level %.2f, lodMinClamp 0.25, lodMaxClamp 1.75: %g (levels hold 0, 1, 2), want %g", name, levels[i],
                            o[i], want[i]);
        return PASS(bug, "%s: compute samples at levels -0.24 and 0 with lodMinClamp 0.25 blend a quarter of level 1 in", name);
    }
}
