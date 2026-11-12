// s45-intel-writable-view-size (MetalOldCompat item 39): get_width / get_height of a writable 2D-array texture view that
// starts at mip level 1 must give that level's size in a fragment function. On the 12.x Intel driver such a binding
// uses the view's render-target surface state, whose min LOD is 0 (its LOD field holds the level, which only writes
// read), so the sampler's resinfo returned level 0's size (WebGPU CTS textureDimensions storage, write, 2d-array, base
// level 1-2: 40 cases). Views of levels 1 and 2 of a 32x24 texture should report 16x12 and 8x6.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 fullScreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment uint4 size(texture2d_array<float, access::write> t [[texture(0)]]) { return uint4(t.get_width(), t.get_height(), t.get_array_size(), 1); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s45-intel-writable-view-size";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"fullScreen"];
        pd.fragmentFunction = [lib newFunctionWithName:@"size"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:24 mipmapped:NO];
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = 2;
        td.mipmapLevelCount = 3;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1 height:1 mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget;
        od.storageMode = MTLStorageModeManaged;
        for (NSUInteger level = 1; level <= 2; level++) {
            id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2DArray
                                                            levels:NSMakeRange(level, 1) slices:NSMakeRange(0, 2)];
            id<MTLTexture> out = [dev newTextureWithDescriptor:od];
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = out;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:ps];
            [enc setFragmentTexture:view atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:out];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            uint32_t px[4];
            [out getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
            uint32_t w = 32 >> level, h = 24 >> level;
            if (px[0] != w || px[1] != h)
                return FAIL(bug, "%s: writable 2D-array view of level %lu reports %ux%u, want %ux%u", name, (unsigned long)level, px[0], px[1], w, h);
        }
        return PASS(bug, "%s: writable 2D-array views of levels 1 and 2 report their level's size in a fragment function", name);
    }
}
