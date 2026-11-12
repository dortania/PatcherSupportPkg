// s38-intel-coverage-without-writes (MetalOldCompat item 34): on the 12.x Intel driver, the coverage a fragment function
// computes (a [[sample_mask]] output, or alpha with alpha-to-coverage) is dropped in a pipeline with no depth or stencil
// attachment whose color attachments all have writeMask none: occlusion queries count every sample (WebGPU CTS
// occlusionQuery sample_mask and alpha_to_coverage with writeMask 0). 4x pipelines like that, one writing sample_mask 0
// and one with alpha-to-coverage and alpha 0, draw a full-target triangle in an occlusion query: no sample may count, and
// the color target must keep its clear color. With mask 0xF and alpha 1 every sample counts. Stock OCLP: FAIL.
// Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s38-intel-coverage-without-writes";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0.5, 1); }\n"
            "struct FO { float4 c [[color(0)]]; uint m [[sample_mask]]; };\n"
            "fragment FO fm(constant uint &mask [[buffer(0)]]) { FO o; o.c = float4(1); o.m = mask; return o; }\n"
            "fragment float4 fa(constant float &alpha [[buffer(0)]]) { return float4(1, 1, 1, alpha); }\n"
            "kernel void k(texture2d_ms<float> t [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
            "  out[p.y * 4 + p.x] = t.read(p, 2); }\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: no library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLComputePipelineState> readBack = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = 4;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> color = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> visibility = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> texels = [dev newBufferWithLength:16 * 16 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        for (int coverage = 0; coverage < 2; coverage++) {
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"v"];
            pd.fragmentFunction = [lib newFunctionWithName:coverage ? @"fa" : @"fm"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
            pd.rasterSampleCount = 4;
            pd.alphaToCoverageEnabled = coverage == 1;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!ps || !readBack) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
            for (int all = 0; all < 2; all++) {
                memset(visibility.contents, 0xff, 16);
                id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = color;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.visibilityResultBuffer = visibility;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:ps];
                uint32_t mask = all ? 0xF : 0;
                float alpha = all ? 1 : 0;
                if (coverage) [enc setFragmentBytes:&alpha length:4 atIndex:0];
                else [enc setFragmentBytes:&mask length:4 atIndex:0];
                [enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
                [enc endEncoding];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:readBack];
                [ce setTexture:color atIndex:0];
                [ce setBuffer:texels offset:0 atIndex:0];
                [ce dispatchThreads:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
                [ce endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
                unsigned long long counted = *(unsigned long long *)visibility.contents, want = all ? 64 : 0;
                const char *what = coverage ? (all ? "alpha-to-coverage, alpha 1" : "alpha-to-coverage, alpha 0") : (all ? "sample_mask 0xF" : "sample_mask 0");
                if (counted != want)
                    return FAIL(bug, "%s: %s, writeMask none, no depth attachment: occlusion query counted %llu samples, want %llu",
                                dev.name.UTF8String, what, counted, want);
                const float *t = (const float *)texels.contents;
                for (int i = 0; i < 16; i++)
                    if (fabsf(t[4 * i] - 0.25f) > 0.01f || fabsf(t[4 * i + 1] - 0.5f) > 0.01f || fabsf(t[4 * i + 2] - 0.75f) > 0.01f || t[4 * i + 3] != 1)
                        return FAIL(bug, "%s: %s, writeMask none: texel %d sample 2 changed to (%g, %g, %g, %g)", dev.name.UTF8String, what, i,
                                    t[4 * i], t[4 * i + 1], t[4 * i + 2], t[4 * i + 3]);
            }
        }
        return PASS(bug, "%s: sample_mask and alpha-to-coverage reach occlusion queries with writeMask none, and the target keeps its contents",
                    dev.name.UTF8String);
    }
}
