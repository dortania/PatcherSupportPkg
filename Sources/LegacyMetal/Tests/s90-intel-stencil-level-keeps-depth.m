// s90-intel-stencil-level-keeps-depth (MetalOldCompat item 86, MTLSHIM_STENCIL_KEEPS_DEPTH): stencil copied into mip level
// 1 of a mipmapped Depth32Float_Stencil8 texture on the Ivy Bridge driver. The stencil lands, but at 63x63 the copy also
// zeroed the depth of levels 2-4; WebKit's lazy zero-fill does such copies, so a depth a render pass had put in a deeper
// level read back as 0 (WebGPU CTS texture_zero, depth32float-stencil8 with 5 levels). Checked: levels 0 and 2-4 of a
// 63x63 5-level texture hold depth 0.8 (render passes); stencil goes into level 1 by a blit from a buffer (bytesPerRow
// 256, the driver's own copy; and 31, item 37's way through a temporary) and by a copy from a 31x31 texture (depth 0.5,
// stencil 7); afterwards levels 0 and 2-4 must still hold 0.8, and level 1 what was copied in.
// Stock: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

enum { TextureSize = 63, Levels = 5 };

static NSUInteger extent(int level) { return MAX(1u, (NSUInteger)TextureSize >> level); }

static id<MTLTexture> prepared(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:TextureSize height:TextureSize
                                                                              mipmapped:NO];
    td.mipmapLevelCount = Levels;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    for (int l = 0; l < Levels; l++) {
        if (l == 1) continue;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = t;
        rp.depthAttachment.level = l;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 0.8;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.stencilAttachment.texture = t;
        rp.stencilAttachment.level = l;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.clearStencil = 42;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
    reproRun(cb);
    return t;
}

// NULL when right, or what was wrong
static const char *check(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> t, const char *how, float level1Depth, uint8_t level1Stencil,
                         char *what, size_t whatSize) {
    for (int l = 0; l < Levels; l++) {
        NSUInteger w = extent(l), h = extent(l);
        id<MTLBuffer> out = [dev newBufferWithLength:256 * h options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:t sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
            destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * h options:MTLBlitOptionDepthFromDepthStencil];
        [be endEncoding];
        if (!reproRun(cb)) return snprintf(what, whatSize, "%s: command buffer failed", how), what;
        float want = l == 1 ? level1Depth : 0.8f;
        if (l == 1 && level1Depth < 0) continue;  // level 1's depth wasn't set
        for (NSUInteger y = 0; y < h; y++)
            for (NSUInteger x = 0; x < w; x++) {
                float d = ((const float *)((const uint8_t *)out.contents + 256 * y))[x];
                if (d != want)
                    return snprintf(what, whatSize, "%s: level %d (%lux%lu) depth at %lu,%lu is %g, want %g", how, l, (unsigned long)w,
                                    (unsigned long)h, (unsigned long)x, (unsigned long)y, d, want), what;
            }
    }
    NSUInteger w = extent(1), h = extent(1);
    id<MTLBuffer> out = [dev newBufferWithLength:256 * h options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
        destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * h options:MTLBlitOptionStencilFromDepthStencil];
    [be endEncoding];
    if (!reproRun(cb)) return snprintf(what, whatSize, "%s: command buffer failed", how), what;
    for (NSUInteger y = 0; y < h; y++)
        for (NSUInteger x = 0; x < w; x++) {
            uint8_t s = ((const uint8_t *)out.contents)[256 * y + x];
            if (s != level1Stencil)
                return snprintf(what, whatSize, "%s: level 1 stencil at %lu,%lu is %u, want %u", how, (unsigned long)x, (unsigned long)y, s,
                                level1Stencil), what;
        }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s90-intel-stencil-level-keeps-depth";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        char what[256];
        const char *wrong = NULL;
        // stencil from a buffer, bytesPerRow 256 and 31
        for (int i = 0; i < 2 && !wrong; i++) {
            NSUInteger row = i ? extent(1) : 256;
            id<MTLTexture> t = prepared(dev, q);
            id<MTLBuffer> data = [dev newBufferWithLength:256 * extent(1) options:MTLResourceStorageModeShared];
            memset(data.contents, 7, data.length);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:data sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * extent(1) sourceSize:MTLSizeMake(extent(1), extent(1), 1)
                     toTexture:t destinationSlice:0 destinationLevel:1 destinationOrigin:MTLOriginMake(0, 0, 0) options:MTLBlitOptionStencilFromDepthStencil];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            wrong = check(dev, q, t, i ? "stencil blit into level 1 (bytesPerRow 31)" : "stencil blit into level 1 (bytesPerRow 256)", -1, 7, what,
                          sizeof what);
        }
        // a texture copy into level 1
        if (!wrong) {
            id<MTLTexture> t = prepared(dev, q);
            MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:extent(1)
                                                                                         height:extent(1) mipmapped:NO];
            sd.storageMode = MTLStorageModePrivate;
            sd.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> source = [dev newTextureWithDescriptor:sd];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = source;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 0.5;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.stencilAttachment.texture = source;
            rp.stencilAttachment.loadAction = MTLLoadActionClear;
            rp.stencilAttachment.clearStencil = 7;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(extent(1), extent(1), 1)
                      toTexture:t destinationSlice:0 destinationLevel:1 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            wrong = check(dev, q, t, "texture copy into level 1", 0.5f, 7, what, sizeof what);
        }
        if (wrong) return FAIL(bug, "%s: %s", name, wrong);
        return PASS(bug, "%s: stencil copied into level 1 of a 63x63 Depth32Float_Stencil8 (blits and a texture copy) leaves the deeper levels' depth alone",
                    name);
    }
}
