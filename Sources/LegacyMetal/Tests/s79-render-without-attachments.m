// s79-render-without-attachments (MetalOldCompat item 73): a render pipeline with no color, depth or stencil attachment,
// drawn in a pass that has only a render target size, as MoltenVK makes for Vulkan subpasses without attachments (Godot
// 4.7's editor at start). On the family-1 GPUs MetalOld's validation aborted the process when the pipeline was made
// ("No valid pixelFormats set"). Checked: the fragment function runs once per pixel (it counts itself with a device
// atomic), single-sampled and with 4 samples, and an occlusion query in counting mode sees every sample. Also a vertex-only
// pipeline (rasterization off, no attachments), which Safari's WebGPU makes to clamp indirect draws and draws inside the
// app's pass: MetalOld aborted the GPU process on it the same way (WebGPU CTS rendering,draw in WebKit).
// Stock: crash (abort). Fixed: PASS. Argument: GPU name substring (default: the system default GPU).
#import "repro.h"

static const char *source =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vs(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); return float4(q * 2.0 - 1.0, 0.0, 1.0); }\n"
    "fragment void fs(device atomic_uint *count [[buffer(0)]]) { atomic_fetch_add_explicit(count, 1u, memory_order_relaxed); }\n"
    "vertex void vsOnly(device uint *out [[buffer(1)]], uint vid [[vertex_id]]) { out[vid] = vid + 100u; }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s79-render-without-attachments";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(source) options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", name, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        enum { W = 16, H = 16 };
        for (NSUInteger samples = 1; samples <= 4; samples *= 4) {
            if (![dev supportsTextureSampleCount:samples]) continue;
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"vs"];
            pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
            pd.rasterSampleCount = samples;  // no attachments at all
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!ps) return FAIL(bug, "%s: pipeline without attachments (%lu samples): %s", name, (unsigned long)samples, error.localizedDescription.UTF8String);
            id<MTLBuffer> count = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> visibility = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
            memset(count.contents, 0, 4);
            memset(visibility.contents, 0, 8);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.renderTargetWidth = W;
            rp.renderTargetHeight = H;
            rp.defaultRasterSampleCount = samples;
            rp.visibilityResultBuffer = visibility;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            if (!re) return FAIL(bug, "%s: no encoder for a pass without attachments (%lu samples)", name, (unsigned long)samples);
            [re setRenderPipelineState:ps];
            [re setViewport:(MTLViewport){0, 0, W, H, 0, 1}];
            [re setFragmentBuffer:count offset:0 atIndex:0];
            [re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed (%lu samples)", name, (unsigned long)samples);
            uint32_t fragments = *(uint32_t *)count.contents;
            uint64_t visible = *(uint64_t *)visibility.contents;
            if (fragments != W * H)
                return FAIL(bug, "%s: %lu samples: the fragment function ran %u times, want %d", name, (unsigned long)samples, fragments, W * H);
            if (visible != (uint64_t)W * H * samples)
                return FAIL(bug, "%s: %lu samples: the occlusion query counted %llu, want %lu", name, (unsigned long)samples,
                            (unsigned long long)visible, (unsigned long)(W * H * samples));
        }
        // a vertex-only pipeline (rasterization off, no fragment function, no attachments), as Safari's WebGPU makes for its
        // indirect-draw clamp (WebKit's indirectBufferClampPipeline, at the pass's sample count) and draws inside the app's pass
        for (NSUInteger samples = 1; samples <= 4; samples *= 4) {
            if (![dev supportsTextureSampleCount:samples]) continue;
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"vsOnly"];
            pd.rasterizationEnabled = NO;
            pd.rasterSampleCount = samples;
            pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!ps) return FAIL(bug, "%s: vertex-only pipeline (%lu samples): %s", name, (unsigned long)samples, error.localizedDescription.UTF8String);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            td.sampleCount = samples;
            td.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
            id<MTLBuffer> out = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
            memset(out.contents, 0, 64);
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
            [re setRenderPipelineState:ps];
            [re setVertexBuffer:out offset:0 atIndex:1];
            [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:4];
            [re endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: vertex-only draw: command buffer failed (%lu samples)", name, (unsigned long)samples);
            const uint32_t *o = out.contents;
            for (int i = 0; i < 4; i++)
                if (o[i] != 100u + i) return FAIL(bug, "%s: vertex-only draw (%lu samples): out[%d] = %u, want %d", name, (unsigned long)samples, i, o[i], 100 + i);
        }
        return PASS(bug, "%s: pipelines and passes without attachments draw (1 and 4 samples: %d fragments each, every sample counted), and so does a vertex-only pipeline in a pass that has one", name, W * H);
    }
}
