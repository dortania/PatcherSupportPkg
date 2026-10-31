// s17-amd-depth-stencil-view (MetalOldCompat item 17): a depth/stencil attachment given as a 2D texture view of mip 1+
// of a 2D-array texture, with the 12.5 AMD driver. The render pass writes nothing (a stencil clear through the view is
// lost); attaching the parent texture with level/slice works. (wgpu zero_init depth/stencil tests, Dawn
// DepthStencilCopyTests, WebGPU CTS.) Clears stencil 0xab at level 1 / slice 1 through a view, for Stencil8 and
// Depth32Float_Stencil8, then copies that level/slice to a buffer.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static long firstWrong(id<MTLDevice> d, MTLPixelFormat format, NSUInteger level, NSUInteger slice) {
    NSUInteger w = 256 >> level, h = MAX(4 >> level, 1);
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.width = 256; td.height = 4; td.arrayLength = 3; td.mipmapLevelCount = 3;
    td.pixelFormat = format; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:format textureType:MTLTextureType2D levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    BOOL depth = format == MTLPixelFormatDepth32Float_Stencil8;
    id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.stencilAttachment.texture = view; rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.storeAction = MTLStoreActionStore; rp.stencilAttachment.clearStencil = 0xab;
    if (depth) { rp.depthAttachment.texture = view; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; }
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    id<MTLBuffer> out = [d newBufferWithLength:w * h options:MTLResourceStorageModeShared];
    memset(out.contents, 0x11, out.length);
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
     destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:w * h options:depth ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionNone];
    [b endEncoding];
    reproRun(cb);
    const uint8_t *p = out.contents;
    for (NSUInteger i = 0; i < w * h; i++) if (p[i] != 0xab) return (long)i;
    return -1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s17-amd-depth-stencil-view";
        id<MTLDevice> d = reproDevice(argc, argv, "AMD");
        if (!d) return SKIP(bug, "no such GPU");
        long s8 = firstWrong(d, MTLPixelFormatStencil8, 1, 1), d32s8 = firstWrong(d, MTLPixelFormatDepth32Float_Stencil8, 1, 1);
        if (s8 < 0 && d32s8 < 0) return PASS(bug, "%s: stencil clear through 2D views of level 1 / slice 1 stored (S8, D32S8)", d.name.UTF8String);
        return FAIL(bug, "%s: stencil clear through a 2D view of level 1 slice 1 lost: Stencil8 %s, Depth32Float_Stencil8 %s", d.name.UTF8String,
                    s8 < 0 ? "ok" : "wrong", d32s8 < 0 ? "ok" : "wrong");
    }
}
