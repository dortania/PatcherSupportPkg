// s50-intel-compute-compare-sampler (MetalOldCompat item 40): sample_compare and gather_compare in a compute kernel
// through a sampler argument with a compare function. The driver's compute path (CHAL_INTEL::ChalContext::
// PatchSamplerObject) builds the hardware sampler state without the sampler's compare function, so every comparison
// compared with "never" and returned 0 (WebGPU CTS textureGatherCompare in compute: 300 cases). An 8x8 Depth32Float
// texture holds (x + 10y) / 100; a compute kernel compares texels against references with compare function less.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device const float *ref [[buffer(0)]],\n"
    "              device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "    out[i * 2] = t.gather_compare(s, float2(1.75 / 8, 3.75 / 8), ref[i]);\n"
    "    out[i * 2 + 1] = float4(t.sample_compare(s, float2(1.5 / 8, 3.5 / 8), ref[i], level(0)),\n"
    "                            t.sample_compare(s, float2(2.5 / 8, 4.5 / 8), ref[i], level(0)), 0, 0);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s50-intel-compute-compare-sampler";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
        float texels[64];
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) texels[y * 8 + x] = (x + 10 * y) / 100.0f;
        id<MTLBuffer> upload = [dev newBufferWithBytes:texels length:sizeof texels options:MTLResourceStorageModeShared];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.compareFunction = MTLCompareFunctionLess;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        float refs[3] = {0.0f, 0.315f, 0.415f};
        id<MTLBuffer> refBuffer = [dev newBufferWithBytes:refs length:sizeof refs options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:3 * 32 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:32 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8, 8, 1) toTexture:texture
              destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setTexture:texture atIndex:0];
        [ce setSamplerState:sampler atIndex:0];
        [ce setBuffer:refBuffer offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(3, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const float *o = out.contents;
        // the gather's quad (x 1-2, y 3-4) in Metal's order: (1,4) (2,4) (2,3) (1,3); the samples: texels (1,3) and (2,4)
        const float quad[4] = {0.41f, 0.42f, 0.32f, 0.31f}, samples[2] = {0.31f, 0.42f};
        for (int i = 0; i < 3; i++) {
            for (int k = 0; k < 4; k++)
                if (o[i * 8 + k] != (refs[i] < quad[k]))
                    return FAIL(bug, "%s: gather_compare (less) with reference %.3f in a kernel: texel %d gave %g, want %d", name, refs[i], k, o[i * 8 + k],
                                refs[i] < quad[k]);
            for (int k = 0; k < 2; k++)
                if (o[i * 8 + 4 + k] != (refs[i] < samples[k]))
                    return FAIL(bug, "%s: sample_compare (less) with reference %.3f in a kernel: %g, want %d", name, refs[i], o[i * 8 + 4 + k], refs[i] < samples[k]);
        }
        return PASS(bug, "%s: sample_compare and gather_compare in a compute kernel use the sampler's compare function", name);
    }
}
