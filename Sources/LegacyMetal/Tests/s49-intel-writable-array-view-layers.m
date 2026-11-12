// s49-intel-writable-array-view-layers (MetalOldCompat item 39): get_array_size() on a writable 2D-array view whose first
// layer isn't 0, in a fragment function. The view's render-target surface state keeps the whole texture's Depth (the
// sampler's has the view's), and the driver binds the render-target state for writable views in fragment functions, so
// the query returned the texture's layer count (WebGPU CTS textureNumLayers storage, write, partial views: 40 cases).
// A fragment function writes layers 0-5 of a view of layers 11-16 of a 17-layer texture and returns get_array_size():
// 6, with the writes at layers 11-16.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], texture2d_array<uint, access::write> t [[texture(0)]]) {\n"
    "    uint2 c = uint2(pos.xy);\n"
    "    for (uint i = 0; i < 6; i++) t.write(uint4(10 + i), c, i);\n"
    "    return uint4(t.get_array_size());\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s49-intel-writable-array-view-layers";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = 17;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
        uint32_t zero[16] = {0};
        for (int s = 0; s < 17; s++) [texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:s withBytes:zero bytesPerRow:16 bytesPerImage:0];
        id<MTLTexture> view = [texture newTextureViewWithPixelFormat:td.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0, 1) slices:NSMakeRange(11, 6)];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentTexture:view atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit synchronizeResource:texture];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        uint32_t size[16];
        [target getBytes:size bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        if (size[5] != 6) return FAIL(bug, "%s: get_array_size() of a writable view of layers 11-16 in a fragment function: %u, want 6", name, size[5]);
        for (int s = 0; s < 17; s++) {
            uint32_t texel[16];
            [texture getBytes:texel bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0 slice:s];
            uint32_t want = s < 11 ? 0 : 10 + (s - 11);
            if (texel[0] != want) return FAIL(bug, "%s: layer %d holds %u after writes through the view, want %u", name, s, texel[0], want);
        }
        return PASS(bug, "%s: a writable 2D-array view of layers 11-16 reports 6 layers in a fragment function, writes land at 11-16", name);
    }
}
