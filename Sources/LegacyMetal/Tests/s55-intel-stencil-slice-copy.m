// s55-intel-stencil-slice-copy: stencil copied between a buffer and slice 1 of a Stencil8 array must keep every texel;
// at unaligned offsets the 12.x Intel driver read 0 or wrote nothing. Fix: MetalOldCompat item 37.
// Checks: 3x2 texels into slice 1 at offset 16, bytesPerRow 4 and 256, read back. Argument: GPU name.
#import "repro.h"

enum { W = 3, H = 2 };

static int check(id<MTLDevice> dev, id<MTLCommandQueue> q, NSUInteger bytesPerRow, char *what, size_t whatSize) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray, td.pixelFormat = MTLPixelFormatStencil8, td.width = W, td.height = H, td.arrayLength = 2;
    td.storageMode = MTLStorageModePrivate, td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    const NSUInteger offset = 16, length = offset + bytesPerRow * H + 64;
    id<MTLBuffer> in = [dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> aligned = [dev newBufferWithLength:256 * H options:MTLResourceStorageModeShared];
    uint8_t *u = in.contents;
    memset(u, 0, length);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) u[offset + y * bytesPerRow + x] = (uint8_t)(0x41 + y * 16 + x);
    memset(out.contents, 0xEE, length);
    memset(aligned.contents, 0xEE, 256 * H);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:in sourceOffset:offset sourceBytesPerRow:bytesPerRow sourceBytesPerImage:bytesPerRow * H sourceSize:MTLSizeMake(W, H, 1)
            toTexture:t destinationSlice:1 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b copyFromTexture:t sourceSlice:1 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
              toBuffer:aligned destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * H];
    [b copyFromTexture:t sourceSlice:1 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
              toBuffer:out destinationOffset:offset destinationBytesPerRow:bytesPerRow destinationBytesPerImage:bytesPerRow * H];
    [b endEncoding];
    if (!reproRun(cb)) return snprintf(what, whatSize, "command buffer failed"), 0;
    const uint8_t *a = aligned.contents, *o = out.contents;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        uint8_t want = (uint8_t)(0x41 + y * 16 + x);
        if (a[y * 256 + x] != want)
            return snprintf(what, whatSize, "written into slice 1 with bytesPerRow %lu at offset 16, texel (%d,%d) reads back %02x, want %02x",
                            (unsigned long)bytesPerRow, x, y, a[y * 256 + x], want), 0;
        if (o[offset + y * bytesPerRow + x] != want)
            return snprintf(what, whatSize, "read out of slice 1 with bytesPerRow %lu at offset 16, texel (%d,%d) is %02x, want %02x",
                            (unsigned long)bytesPerRow, x, y, o[offset + y * bytesPerRow + x], want), 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s55-intel-stencil-slice-copy";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> q = [dev newCommandQueue];
        char what[256];
        static const NSUInteger kBytesPerRow[2] = {4, 256};
        for (int k = 0; k < 2; k++)
            if (!check(dev, q, kBytesPerRow[k], what, sizeof what)) return FAIL(bug, "%s: Stencil8: %s", dev.name.UTF8String, what);
        return PASS(bug, "%s: Stencil8 copies to and from slice 1 at buffer offset 16 keep every texel (bytesPerRow 4 and 256)",
                    dev.name.UTF8String);
    }
}
