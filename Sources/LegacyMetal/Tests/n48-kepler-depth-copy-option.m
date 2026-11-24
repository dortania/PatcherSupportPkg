// n48-kepler-depth-copy-option: depth-only buffer / texture copies with DepthFromDepthStencil must copy depth as
// stored; Kepler moved 32-bit floats for Depth16Unorm. Fix: MetalOldCompat item 80. Checks: Depth16Unorm and
// Depth32Float uploaded and read back, and a render-pass clear read back. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static int check(const char *bug, const char *name, id<MTLDevice> dev, id<MTLCommandQueue> queue, MTLPixelFormat format,
                 const char *formatName, unsigned bytes) {
    enum { W = 4, H = 4, Row = 256 };
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> source = [dev newBufferWithLength:Row * H options:MTLResourceStorageModeShared];
    id<MTLBuffer> back = [dev newBufferWithLength:Row * H options:MTLResourceStorageModeShared];
    uint8_t want[Row * H];
    memset(want, 0, sizeof want);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            float depth = (float)(y * W + x + 1) / (W * H + 1);
            if (bytes == 2) {
                uint16_t v = (uint16_t)(depth * 65535.0f + 0.5f);
                memcpy(want + y * Row + x * 2, &v, 2);
            } else
                memcpy(want + y * Row + x * 4, &depth, 4);
        }
    memcpy(source.contents, want, sizeof want);
    memset(back.contents, 0xaa, Row * H);
    // (1) buffer -> texture -> buffer, both with the option
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:source sourceOffset:0 sourceBytesPerRow:Row sourceBytesPerImage:Row * H sourceSize:MTLSizeMake(W, H, 1)
             toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)
               options:MTLBlitOptionDepthFromDepthStencil];
    [be copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
               toBuffer:back destinationOffset:0 destinationBytesPerRow:Row destinationBytesPerImage:Row * H
                options:MTLBlitOptionDepthFromDepthStencil];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: %s copies: command buffer failed", name, formatName);
    const uint8_t *b = back.contents;
    for (int y = 0; y < H; y++)
        if (memcmp(b + y * Row, want + y * Row, W * bytes))
            return FAIL(bug, "%s: %s with DepthFromDepthStencil, buffer -> texture -> buffer: row %d starts %02x %02x %02x %02x, want %02x %02x %02x %02x",
                        name, formatName, y, b[y * Row], b[y * Row + 1], b[y * Row + 2], b[y * Row + 3],
                        want[y * Row], want[y * Row + 1], want[y * Row + 2], want[y * Row + 3]);
    // (2) cleared to 1.0 by a render pass, read back with the option
    memset(back.contents, 0xaa, Row * H);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = texture;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    cb = [queue commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
    be = [cb blitCommandEncoder];
    [be copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
               toBuffer:back destinationOffset:0 destinationBytesPerRow:Row destinationBytesPerImage:Row * H
                options:MTLBlitOptionDepthFromDepthStencil];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: %s clear and copy: command buffer failed", name, formatName);
    uint8_t one[4];
    if (bytes == 2) memset(one, 0xff, 2);
    else { float f = 1.0f; memcpy(one, &f, 4); }
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            if (memcmp(b + y * Row + x * bytes, one, bytes))
                return FAIL(bug, "%s: %s cleared to 1.0, read back with DepthFromDepthStencil: texel %d,%d bytes %02x %02x %02x %02x",
                            name, formatName, x, y, b[y * Row + x * bytes], b[y * Row + x * bytes + 1], b[y * Row + x * bytes + 2], b[y * Row + x * bytes + 3]);
    return -1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n48-kepler-depth-copy-option";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        int r = check(bug, name, dev, queue, MTLPixelFormatDepth16Unorm, "Depth16Unorm", 2);
        if (r >= 0) return r;
        r = check(bug, name, dev, queue, MTLPixelFormatDepth32Float, "Depth32Float", 4);
        if (r >= 0) return r;
        return PASS(bug, "%s: depth-only textures copy to and from buffers right with MTLBlitOptionDepthFromDepthStencil (Depth16Unorm, Depth32Float)", name);
    }
}
