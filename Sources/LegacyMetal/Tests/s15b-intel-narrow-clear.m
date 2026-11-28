// s15b-intel-narrow-clear: clears of color targets at most 2 texels wide must clear every row; the 12.x Intel driver's
// fast clear missed bands below row 16. Fix: MetalOldCompat item 15.
// Checks: 1x64 and 2x64 RGBA8 targets filled with 0x5a, cleared to black, read back. Argument: GPU name.
#import "repro.h"

static NSUInteger wrongTexels(id<MTLDevice> d, id<MTLCommandQueue> q, NSUInteger w, NSUInteger *firstRow) {
    NSUInteger h = 64;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    id<MTLBuffer> junk = [d newBufferWithLength:256 * h options:MTLResourceStorageModeShared];
    memset(junk.contents, 0x5a, junk.length);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> j = [cb blitCommandEncoder];
    [j copyFromBuffer:junk sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256 * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
     destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [j endEncoding];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    id<MTLBuffer> out = [d newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> r = [cb blitCommandEncoder];
    [r copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
     destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [r endEncoding];
    reproRun(cb);
    const uint32_t *p = out.contents;
    NSUInteger bad = 0;
    *firstRow = NSNotFound;
    for (NSUInteger i = 0; i < w * h; i++) if (p[i]) { if (*firstRow == NSNotFound) *firstRow = i / w; bad++; }
    return bad;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s15b-intel-narrow-clear";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSUInteger row1, row2, bad1 = wrongTexels(dev, q, 1, &row1), bad2 = wrongTexels(dev, q, 2, &row2);
        if (!bad1 && !bad2) return PASS(bug, "%s: 1x64 and 2x64 RGBA8 targets fully cleared", dev.name.UTF8String);
        return FAIL(bug, "%s: texels not cleared: 1x64 %lu (first row %ld), 2x64 %lu (first row %ld)", dev.name.UTF8String,
                    (unsigned long)bad1, bad1 ? (long)row1 : -1L, (unsigned long)bad2, bad2 ? (long)row2 : -1L);
    }
}
