// s41-intel-stencil-copy-rows (MetalOldCompat item 37): stencil copied between a buffer and mip level 2 must keep every
// texel. On the 12.x Intel driver, with a buffer offset or bytesPerRow that isn't a multiple of 256, a texel of each row
// comes from its left neighbour (mip 2 of 20x16: the 5th texel reads or writes as the 4th), for Stencil8 and the stencil
// of Depth32Float_Stencil8 (which backs WebGPU's stencil8). Dawn copies a tight buffer's last row on its own with
// bytesPerRow = its width (WebGPU CTS image_copy rowsPerImage_and_bytesPerRow_depth_stencil). Copies 5x4 texels at mip 2
// both ways with bytesPerRow 5, and the last row alone at a buffer offset of 16, for both formats.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static int check(id<MTLDevice> dev, id<MTLCommandQueue> q, MTLPixelFormat format, char *what, size_t whatSize) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:20 height:16 mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    MTLBlitOption o = format == MTLPixelFormatStencil8 ? MTLBlitOptionNone : MTLBlitOptionStencilFromDepthStencil;
    const char *name = format == MTLPixelFormatStencil8 ? "Stencil8" : "Depth32Float_Stencil8";
    uint8_t want[4][5];
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) want[y][x] = (uint8_t)(y * 16 + x * 3 + 7);
    id<MTLBuffer> aligned = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> packed = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> row = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    // 1. aligned in, packed out (bytesPerRow 5), last row alone out at offset 16
    for (int y = 0; y < 4; y++) memcpy((uint8_t *)aligned.contents + 256 * y, want[y], 5);
    memset(packed.contents, 0, 64);
    memset(row.contents, 0, 64);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:aligned sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(5, 4, 1)
            toTexture:t destinationSlice:0 destinationLevel:2 destinationOrigin:MTLOriginMake(0, 0, 0) options:o];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:2 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(5, 4, 1)
              toBuffer:packed destinationOffset:0 destinationBytesPerRow:5 destinationBytesPerImage:20 options:o];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:2 sourceOrigin:MTLOriginMake(0, 3, 0) sourceSize:MTLSizeMake(5, 1, 1)
              toBuffer:row destinationOffset:16 destinationBytesPerRow:5 destinationBytesPerImage:0 options:o];
    [b endEncoding];
    if (!reproRun(cb)) return snprintf(what, whatSize, "%s: command buffer failed", name), 0;
    const uint8_t *p = packed.contents, *r = row.contents;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++)
        if (p[y * 5 + x] != want[y][x])
            return snprintf(what, whatSize, "%s: read back with bytesPerRow 5, texel (%d,%d) of mip 2 is %02x, want %02x", name, x, y, p[y * 5 + x], want[y][x]), 0;
    for (int x = 0; x < 5; x++)
        if (r[16 + x] != want[3][x])
            return snprintf(what, whatSize, "%s: last row read back alone, texel %d is %02x, want %02x", name, x, r[16 + x], want[3][x]), 0;
    // 2. packed in (bytesPerRow 5), aligned out
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) ((uint8_t *)packed.contents)[y * 5 + x] = want[y][x] ^ 0x55;
    memset(aligned.contents, 0, 1024);
    cb = [q commandBuffer];
    b = [cb blitCommandEncoder];
    [b copyFromBuffer:packed sourceOffset:0 sourceBytesPerRow:5 sourceBytesPerImage:20 sourceSize:MTLSizeMake(5, 4, 1)
            toTexture:t destinationSlice:0 destinationLevel:2 destinationOrigin:MTLOriginMake(0, 0, 0) options:o];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:2 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(5, 4, 1)
              toBuffer:aligned destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024 options:o];
    [b endEncoding];
    if (!reproRun(cb)) return snprintf(what, whatSize, "%s: command buffer failed", name), 0;
    const uint8_t *a = aligned.contents;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++)
        if (a[256 * y + x] != (uint8_t)(want[y][x] ^ 0x55))
            return snprintf(what, whatSize, "%s: written with bytesPerRow 5, texel (%d,%d) of mip 2 is %02x, want %02x", name, x, y,
                            a[256 * y + x], want[y][x] ^ 0x55), 0;
    return 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s41-intel-stencil-copy-rows";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> q = [dev newCommandQueue];
        char what[256];
        for (int f = 0; f < 2; f++)
            if (!check(dev, q, f ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatStencil8, what, sizeof what))
                return FAIL(bug, "%s: %s", dev.name.UTF8String, what);
        return PASS(bug, "%s: stencil copies at mip 2 with bytesPerRow 5 and an unaligned offset keep every texel (Stencil8, Depth32Float_Stencil8)",
                    dev.name.UTF8String);
    }
}
