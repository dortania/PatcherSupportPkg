// n49-kepler-stencil-clear-mask: a stencil clear value above 255 must clear to its low 8 bits; Kepler left the stencil
// unwritten or failed the command buffer. Fix: MetalOldCompat item 81. Checks: Stencil8 and Depth32Float_Stencil8
// cleared to 258 and to 65539. Argument: GPU name (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n49-kepler-stencil-clear-mask";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        const MTLPixelFormat formats[2] = {MTLPixelFormatStencil8, MTLPixelFormatDepth32Float_Stencil8};
        const char *const formatNames[2] = {"Stencil8", "Depth32Float_Stencil8"};
        const uint32_t values[2] = {258, 65539};
        for (int f = 0; f < 2; f++)
            for (int v = 0; v < 2; v++) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[f] width:4 height:4 mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget;
                td.storageMode = MTLStorageModePrivate;
                id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
                id<MTLBuffer> out = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
                memset(out.contents, 0xaa, 1024);
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.stencilAttachment.texture = texture;
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = values[v];
                pass.stencilAttachment.storeAction = MTLStoreActionStore;
                if (formats[f] != MTLPixelFormatStencil8) {
                    pass.depthAttachment.texture = texture;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                }
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1)
                           toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024
                            options:MTLBlitOptionStencilFromDepthStencil];
                [be endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: %s cleared to %u: command buffer failed", name, formatNames[f], values[v]);
                const uint8_t *o = out.contents;
                uint8_t want = (uint8_t)values[v];
                for (int y = 0; y < 4; y++)
                    for (int x = 0; x < 4; x++)
                        if (o[y * 256 + x] != want)
                            return FAIL(bug, "%s: %s cleared to %u: stencil %d,%d = %u, want %u", name, formatNames[f], values[v], x, y, o[y * 256 + x], want);
            }
        return PASS(bug, "%s: stencil clears above 255 keep their low 8 bits (258 -> 2, 65539 -> 3; Stencil8, Depth32Float_Stencil8)", name);
    }
}
