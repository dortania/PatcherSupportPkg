// s73-intel-srgb-pair-copies: copies between a format and its sRGB variant must copy the bytes; Ivy Bridge converted
// RGBA8/BGRA8 and garbled BC blocks. Fix: MetalOldCompat item 72 MTLSHIM_SRGB_COPY.
// Checks: RGBA8, BGRA8, BC1, BC3 pairs both ways at levels 0, 1 and slice 1, and through views. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s73-intel-srgb-pair-copies";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { const char *what; MTLPixelFormat a, b; int block, bytes; } pairs[] = {
        {"RGBA8Unorm / RGBA8Unorm_sRGB", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB, 1, 4},
        {"BGRA8Unorm / BGRA8Unorm_sRGB", MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB, 1, 4},
        {"BC1_RGBA / BC1_RGBA_sRGB", MTLPixelFormatBC1_RGBA, MTLPixelFormatBC1_RGBA_sRGB, 4, 8},
        {"BC3_RGBA / BC3_RGBA_sRGB", MTLPixelFormatBC3_RGBA, MTLPixelFormatBC3_RGBA_sRGB, 4, 16},
        {"RGBA8Unorm / RGBA8Unorm", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm, 1, 4},
    };
    for (int p = 0; p < 5; p++)
        for (int dir = 0; dir < 2; dir++)
            for (int where = 0; where < 3; where++) {  // level 0, level 1, array slice 1
                MTLPixelFormat from = dir ? pairs[p].b : pairs[p].a, to = dir ? pairs[p].a : pairs[p].b;
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:from width:32 height:32 mipmapped:YES];
                td.mipmapLevelCount = 2;
                if (where == 2) td.textureType = MTLTextureType2DArray, td.arrayLength = 2;
                td.usage = MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                id<MTLTexture> source = [dev newTextureWithDescriptor:td];
                td.pixelFormat = to;
                id<MTLTexture> destination = [dev newTextureWithDescriptor:td];
                if (!source || !destination) return FAIL(bug, "%s: no %s textures", name, pairs[p].what);
                NSUInteger level = where == 1, slice = where == 2, w = 32 >> level;
                NSUInteger row = w / pairs[p].block * pairs[p].bytes, n = row * (w / pairs[p].block);
                id<MTLBuffer> in = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
                id<MTLBuffer> out = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
                for (NSUInteger i = 0; i < n; i++) ((uint8_t *)in.contents)[i] = (uint8_t)(i * 7 + 3);
                memset(out.contents, 0xee, n);
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(w, w, 1) toTexture:source
                  destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
                [be copyFromTexture:source sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1)
                          toTexture:destination destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
                [be copyFromTexture:destination sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1)
                           toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
                [be endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
                const uint8_t *got = out.contents, *want = in.contents;
                for (NSUInteger i = 0; i < n; i++)
                    if (got[i] != want[i])
                        return FAIL(bug, "%s: %s copied %s at %s: byte %lu is %02x, want %02x", name, pairs[p].what, dir ? "backwards" : "forwards",
                                    where == 0 ? "level 0" : where == 1 ? "level 1" : "array slice 1", (unsigned long)i, got[i], want[i]);
            }
    for (int mode = 0; mode < 2; mode++)
        for (int where = 0; where < 3; where++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:YES];
            td.mipmapLevelCount = 2;
            if (where == 2) td.textureType = MTLTextureType2DArray, td.arrayLength = 2;
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> source = [dev newTextureWithDescriptor:td];
            td.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
            id<MTLTexture> destination = [dev newTextureWithDescriptor:td];
            id<MTLTexture> from = mode == 0 ? [source newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB] : source;
            id<MTLTexture> to = mode == 1 ? [destination newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm] : destination;
            NSUInteger level = where == 1, slice = where == 2, w = 32 >> level, row = w * 4, n = row * w;
            id<MTLBuffer> in = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
            id<MTLBuffer> out = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
            for (NSUInteger i = 0; i < n; i++) ((uint8_t *)in.contents)[i] = (uint8_t)(i * 7 + 3);
            memset(out.contents, 0xee, n);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(w, w, 1) toTexture:source
              destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be copyFromTexture:from sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1) toTexture:to
               destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be copyFromTexture:destination sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1)
                       toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            const uint8_t *got = out.contents, *want = in.contents;
            for (NSUInteger i = 0; i < n; i++)
                if (got[i] != want[i])
                    return FAIL(bug, "%s: RGBA8Unorm to RGBA8Unorm_sRGB through %s at %s: byte %lu is %02x, want %02x", name,
                                mode ? "a unorm view of the destination" : "a sRGB view of the source", where == 0 ? "level 0" : where == 1 ? "level 1" : "array slice 1",
                                (unsigned long)i, got[i], want[i]);
        }
    return PASS(bug, "%s: copies between RGBA8, BGRA8, BC1 and BC3 and their sRGB variants keep every byte (levels 0-1, array slice 1, both ways, and through format views)", name);
}}
