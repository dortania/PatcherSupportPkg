// s66-intel-msaa-depth-clear-read: cleared 4x MSAA depth must read back in full in a later pass; Ivy Bridge saw only
// the first quarter. Fix: MetalOldCompat item 50.
// Checks: a 16x16 4x Depth32Float cleared to 0.75; sample 0 of every texel read in the next pass. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s66-intel-msaa-depth-clear-read";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
            "vertex V vs(uint vid [[vertex_id]]) { float2 q[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)}; V o; o.p = float4(q[vid], 0, 1); return o; }\n"
            "fragment float4 rd(V in [[stage_in]], depth2d_ms<float> t [[texture(0)]]) { return float4(t.read(uint2(in.p.xy), 0), 0, 0, 1); }\n"
            options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { N = 16 };
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:N height:N mipmapped:NO];
        dd.textureType = MTLTextureType2DMultisample;
        dd.sampleCount = 4;
        dd.storageMode = MTLStorageModePrivate;
        dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:N height:N mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget;
        od.storageMode = MTLStorageModeManaged;
        id<MTLTexture> out = [dev newTextureWithDescriptor:od];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"rd"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!rp) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.depthAttachment.texture = depth;
        clear.depthAttachment.loadAction = MTLLoadActionClear;
        clear.depthAttachment.clearDepth = 0.75;
        clear.depthAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
        MTLRenderPassDescriptor *read = [MTLRenderPassDescriptor renderPassDescriptor];
        read.colorAttachments[0].texture = out;
        read.colorAttachments[0].loadAction = MTLLoadActionClear;
        read.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:read];
        [re setRenderPipelineState:rp];
        [re setFragmentTexture:depth atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:out];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float px[N * N];
        [out getBytes:px bytesPerRow:N * 4 fromRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0];
        int wrong = 0, first = -1;
        for (int i = 0; i < N * N; i++)
            if (fabsf(px[i] - 0.75f) > 1e-4f && !wrong++) first = i;
        if (wrong)
            return FAIL(bug, "%s: cleared 4x depth read in the next pass: %d of %d texels wrong (first (%d,%d) reads %g, want 0.75)",
                        dev.name.UTF8String, wrong, N * N, first % N, first / N, px[first]);
        return PASS(bug, "%s: depth cleared into a 4x texture reads back as cleared in every texel of the next pass", dev.name.UTF8String);
    }
}
