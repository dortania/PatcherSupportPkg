// s65-intel-view-blits (shim item 49): on the Ivy Bridge driver a blit from or into a texture view ignores the view's
// offset into its parent and reaches the parent's slice 0 and level 0, while shaders reach the right subresource through
// the same view. ANGLE copies a cube's faces through single-face 2D views when generateMipmap gives the texture a mip
// chain, so in Chrome every face of a mipmapped cube map became +X's (WebGL CTS texture-size-cube-maps). Fills each face
// and level of a mipmapped cube with its own color, then for single-face, single-level 2D views: copies out of the view
// into a texture and into a buffer, and copies a new color into a view of another face and level, checking every result.
// The R9 M370X's driver drops one of these too: a buffer-to-texture copy into a view whose first slice is 1 or more,
// covering the whole slice, is written nowhere (AMDBronzeCompat item 14; s65@AMD).
// Stock OCLP on an HD 4000: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static void run(id<MTLCommandQueue> queue, void (^encode)(id<MTLBlitCommandEncoder>)) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    encode(blit);
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static uint32_t color(NSUInteger face, NSUInteger level) { return 0xff000000u | (uint32_t)(face * 40 + 10) << 8 | (uint32_t)(level * 50 + 5); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s65-intel-view-blits";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        enum { N = 16 };
        MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:N mipmapped:YES];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> cube = [dev newTextureWithDescriptor:td];
        for (NSUInteger f = 0; f < 6; f++)
            for (NSUInteger l = 0; l < 3; l++) {
                NSUInteger m = N >> l;
                NSMutableData *px = [NSMutableData dataWithLength:m * m * 4];
                for (NSUInteger i = 0; i < m * m; i++) ((uint32_t *)px.mutableBytes)[i] = color(f, l);
                id<MTLBuffer> b = [dev newBufferWithBytes:px.bytes length:px.length options:MTLResourceStorageModeShared];
                run(queue, ^(id<MTLBlitCommandEncoder> e) {
                    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:m * 4 sourceBytesPerImage:m * m * 4 sourceSize:MTLSizeMake(m, m, 1)
                            toTexture:cube destinationSlice:f destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
                });
            }
        for (NSUInteger f = 0; f < 6; f++)
            for (NSUInteger l = 0; l < 3; l++) {
                NSUInteger m = N >> l;
                id<MTLTexture> view = [cube newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                                   levels:NSMakeRange(l, 1) slices:NSMakeRange(f, 1)];
                MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:m height:m mipmapped:NO];
                dd.storageMode = MTLStorageModePrivate;
                id<MTLTexture> copy = [dev newTextureWithDescriptor:dd];
                id<MTLBuffer> direct = [dev newBufferWithLength:m * m * 4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> viaTexture = [dev newBufferWithLength:m * m * 4 options:MTLResourceStorageModeShared];
                run(queue, ^(id<MTLBlitCommandEncoder> e) {
                    [e copyFromTexture:view sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(m, m, 1)
                              toBuffer:direct destinationOffset:0 destinationBytesPerRow:m * 4 destinationBytesPerImage:m * m * 4];
                    [e copyFromTexture:view sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(m, m, 1)
                             toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [e copyFromTexture:copy sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(m, m, 1)
                              toBuffer:viaTexture destinationOffset:0 destinationBytesPerRow:m * 4 destinationBytesPerImage:m * m * 4];
                });
                uint32_t a = ((uint32_t *)direct.contents)[m * m - 1], b = ((uint32_t *)viaTexture.contents)[m * m - 1];
                if (a != color(f, l) || b != color(f, l))
                    return FAIL(bug, "%s: view of face %lu level %lu copied out as %08x (to a buffer) and %08x (to a texture), want %08x",
                                dev.name.UTF8String, (unsigned long)f, (unsigned long)l, a, b, color(f, l));
            }
        // into a view: face 4, level 1
        id<MTLTexture> target = [cube newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                             levels:NSMakeRange(1, 1) slices:NSMakeRange(4, 1)];
        NSUInteger m = N >> 1;
        NSMutableData *px = [NSMutableData dataWithLength:m * m * 4];
        for (NSUInteger i = 0; i < m * m; i++) ((uint32_t *)px.mutableBytes)[i] = 0xff123456u;
        id<MTLBuffer> src = [dev newBufferWithBytes:px.bytes length:px.length options:MTLResourceStorageModeShared];
        id<MTLBuffer> face4 = [dev newBufferWithLength:m * m * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> face0 = [dev newBufferWithLength:N * N * 4 options:MTLResourceStorageModeShared];
        run(queue, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:m * 4 sourceBytesPerImage:m * m * 4 sourceSize:MTLSizeMake(m, m, 1)
                    toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [e copyFromTexture:cube sourceSlice:4 sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(m, m, 1)
                      toBuffer:face4 destinationOffset:0 destinationBytesPerRow:m * 4 destinationBytesPerImage:m * m * 4];
            [e copyFromTexture:cube sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(N, N, 1)
                      toBuffer:face0 destinationOffset:0 destinationBytesPerRow:N * 4 destinationBytesPerImage:N * N * 4];
        });
        uint32_t got4 = ((uint32_t *)face4.contents)[0], got0 = ((uint32_t *)face0.contents)[0];
        if (got4 != 0xff123456u || got0 != color(0, 0))
            return FAIL(bug, "%s: copy into a view of face 4 level 1: that face reads %08x (want ff123456), face 0 level 0 reads %08x (want %08x)",
                        dev.name.UTF8String, got4, got0, color(0, 0));
        return PASS(bug, "%s: blits from and into single-face, single-level views of a mipmapped cube reach the view's subresource",
                    dev.name.UTF8String);
    }
}
