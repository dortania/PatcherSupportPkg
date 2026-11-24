// n15-kepler-volume-copy-stride: buffer / 3D-texture copies with bytesPerImage above bytesPerRow x height must use that
// stride; Kepler put slice n in the padding. Fix: MetalOldCompat item 65. Checks: RGBA8 and R32Uint 3D textures both
// ways at several strides, and a copy at a z origin. Argument: GPU name (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n15-kepler-volume-copy-stride";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { MTLPixelFormat format; const char *what; NSUInteger w, h, d; } kinds[] = {
        {MTLPixelFormatRGBA8Unorm, "RGBA8Unorm 4x4x3", 4, 4, 3}, {MTLPixelFormatR32Uint, "R32Uint 8x8x4", 8, 8, 4}};
    struct { NSUInteger rowPad, extraRows; NSUInteger z0, depth; } layouts[] = {
        {0, 0, 0, 0}, {240, 0, 0, 0}, {0, 2, 0, 0}, {240, 2, 0, 0}, {496, 5, 0, 0}, {0, 3, 1, 2}};  // depth 0: all slices
    for (int k = 0; k < 2; k++) {
        NSUInteger W = kinds[k].w, H = kinds[k].h, D = kinds[k].d;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType3D;
        td.pixelFormat = kinds[k].format;
        td.width = W, td.height = H, td.depth = D;
        td.storageMode = MTLStorageModePrivate;
        for (int L = 0; L < 6; L++) {
            NSUInteger row = W * 4 + layouts[L].rowPad, rows = H + layouts[L].extraRows, image = row * rows;
            NSUInteger z0 = layouts[L].z0, depth = layouts[L].depth ? layouts[L].depth : D;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            id<MTLBuffer> padded = [dev newBufferWithLength:image * depth options:MTLResourceStorageModeShared];
            id<MTLBuffer> tight = [dev newBufferWithLength:W * H * 4 * D options:MTLResourceStorageModeShared];
            id<MTLBuffer> back = [dev newBufferWithLength:image * depth options:MTLResourceStorageModeShared];
            memset(padded.contents, 0xee, padded.length);
            memset(tight.contents, 0, tight.length);
            memset(back.contents, 0xcd, back.length);
            for (NSUInteger z = 0; z < depth; z++)
                for (NSUInteger y = 0; y < H; y++)
                    for (NSUInteger x = 0; x < W; x++)
                        ((uint32_t *)((char *)padded.contents + z * image + y * row))[x] = (uint32_t)(((z0 + z + 1) << 24) | ((y + 1) << 12) | (x + 1) | 0x800);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:padded sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:MTLSizeMake(W, H, depth)
                     toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, z0)];
            [be copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, z0) sourceSize:MTLSizeMake(W, H, depth)
                       toBuffer:tight destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
            [be copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, z0) sourceSize:MTLSizeMake(W, H, depth)
                       toBuffer:back destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:image];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, kinds[k].what);
            for (NSUInteger z = 0; z < depth; z++)
                for (NSUInteger y = 0; y < H; y++)
                    for (NSUInteger x = 0; x < W; x++) {
                        uint32_t want = ((uint32_t *)((char *)padded.contents + z * image + y * row))[x];
                        uint32_t up = ((uint32_t *)tight.contents)[(z * H + y) * W + x];
                        uint32_t down = ((uint32_t *)((char *)back.contents + z * image + y * row))[x];
                        if (up != want)
                            return FAIL(bug, "%s: %s: a copy from a buffer at bytesPerRow %lu, bytesPerImage %lu into slices %lu-%lu put %#x at (%lu, %lu, %lu), want %#x",
                                        name, kinds[k].what, (unsigned long)row, (unsigned long)image, (unsigned long)z0, (unsigned long)(z0 + depth - 1),
                                        up, (unsigned long)x, (unsigned long)y, (unsigned long)(z0 + z), want);
                        if (down != want)
                            return FAIL(bug, "%s: %s: a copy into a buffer at bytesPerRow %lu, bytesPerImage %lu wrote %#x for (%lu, %lu, %lu), want %#x",
                                        name, kinds[k].what, (unsigned long)row, (unsigned long)image, down, (unsigned long)x, (unsigned long)y,
                                        (unsigned long)(z0 + z), want);
                    }
        }
    }
    return PASS(bug, "%s: 3D copies both ways with padded rows and images (and into slices 1-2) put every texel where it belongs", name);
}}
