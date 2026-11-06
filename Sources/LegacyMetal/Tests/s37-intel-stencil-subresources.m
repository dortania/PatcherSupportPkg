// s37-intel-stencil-subresources (MetalOldCompat items 33 and 27): on the 12.x Intel driver, render passes on a stencil
// texture with several mip levels or slices and blits into it don't agree: a pass at another level or slice doesn't load
// what's there, and a pass that loads and stores level 0 / slice 0 makes every subresource read back by a shader as what
// that pass saw. Blits a value per (level, slice) into a 3-level, 2-slice Stencil8 texture, runs an empty pass that loads
// and stores level 0 / slice 0, then checks every subresource with a stencil test (EQUAL, a level-0 color target of its
// size) and a shader read. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s37-intel-stencil-subresources";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        enum { W = 32, H = 16, L = 3, S = 2 };
        id<MTLLibrary> lib = [dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { float2 t = float2((id << 1) & 2, id & 2); return float4(t * 2 - 1, 0, 1); }\n"
            "fragment float4 f() { return float4(1); }\n"
            "kernel void k(texture2d_array<uint> t [[texture(0)]], device uint *out [[buffer(0)]], constant uint4 &ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {\n"
            "  if (p.x < ls.x && p.y < ls.y && t.read(p, ls.w, ls.z).x == (0x40 + 8 * ls.z + ls.w)) atomic_fetch_add_explicit((device atomic_uint *)out, 1, memory_order_relaxed); }\n"
            stringByAppendingString:reproUniqueComment()] options:nil error:nil];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
        NSError *error = nil;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        id<MTLComputePipelineState> cs = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        if (!ps || !cs) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.frontFaceStencil.stencilCompareFunction = MTLCompareFunctionEqual;
        dsd.backFaceStencil = dsd.frontFaceStencil;
        id<MTLDepthStencilState> equal = [dev newDepthStencilStateWithDescriptor:dsd];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W height:H mipmapped:YES];
        td.mipmapLevelCount = L;
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = S;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++) {
                int w = W >> l, h = H >> l;
                id<MTLBuffer> src = [dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
                memset(src.contents, 0x40 + 8 * l + s, w * h);
                [blit copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
                    destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
        [blit endEncoding];
        MTLRenderPassDescriptor *touch = [MTLRenderPassDescriptor renderPassDescriptor];
        touch.stencilAttachment.texture = t;
        touch.stencilAttachment.loadAction = MTLLoadActionLoad;
        touch.stencilAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:touch] endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++) {
                int w = W >> l, h = H >> l;
                MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:w height:h mipmapped:NO];
                cd.usage = MTLTextureUsageRenderTarget;
                cd.storageMode = MTLStorageModePrivate;
                id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
                id<MTLBuffer> drawn = [dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
                id<MTLBuffer> matched = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
                cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = color;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.stencilAttachment.texture = t;
                rp.stencilAttachment.level = l;
                rp.stencilAttachment.slice = s;
                rp.stencilAttachment.loadAction = MTLLoadActionLoad;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:ps];
                [enc setDepthStencilState:equal];
                [enc setStencilReferenceValue:0x40 + 8 * l + s];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
                blit = [cb blitCommandEncoder];
                [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:drawn
                    destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:w * h];
                [blit endEncoding];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                uint32_t ls[4] = {(uint32_t)w, (uint32_t)h, (uint32_t)l, (uint32_t)s};
                [ce setComputePipelineState:cs];
                [ce setTexture:t atIndex:0];
                [ce setBuffer:matched offset:0 atIndex:0];
                [ce setBytes:ls length:sizeof ls atIndex:1];
                [ce dispatchThreadgroups:MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [ce endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
                int passed = 0;
                for (int i = 0; i < w * h; i++) passed += ((uint8_t *)drawn.contents)[i] == 255;
                uint32_t read = *(uint32_t *)matched.contents;
                if (passed != w * h || read != (uint32_t)(w * h))
                    return FAIL(bug, "%s: level %d slice %d (%dx%d): stencil test passed %d, shader read the value at %u (after a pass that loaded and "
                                "stored level 0 slice 0)", dev.name.UTF8String, l, s, w, h, passed, read);
            }
        return PASS(bug, "%s: blitted stencil on every level and slice of a 3-level 2-slice texture survives a pass on level 0 and tests and reads right",
                    dev.name.UTF8String);
    }
}
