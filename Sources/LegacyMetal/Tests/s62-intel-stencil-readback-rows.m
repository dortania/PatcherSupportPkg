// s62-intel-stencil-readback-rows: stencil read back with bytesPerRow above the width must keep every row; the HD 4000
// driver wrote only the first. Fix: MetalOldCompat item 37.
// Checks: Stencil8 (levels 0 and 1, slice 1) and Depth32Float_Stencil8, bytesPerRow 256. Argument: GPU name.
#import "repro.h"

static id<MTLTexture> make(id<MTLDevice> dev, MTLPixelFormat format, NSUInteger slices) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:16 height:12 mipmapped:YES];
    if (slices > 1) td.textureType = MTLTextureType2DArray, td.arrayLength = slices;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s62-intel-stencil-readback-rows";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        const struct { MTLPixelFormat format; NSUInteger slices, slice, level; const char *name; } cases[] = {
            {MTLPixelFormatStencil8, 1, 0, 0, "Stencil8 level 0"},
            {MTLPixelFormatStencil8, 1, 0, 1, "Stencil8 level 1"},
            {MTLPixelFormatStencil8, 2, 1, 0, "Stencil8 slice 1"},
            {MTLPixelFormatDepth32Float_Stencil8, 1, 0, 0, "Depth32Float_Stencil8 stencil, level 0"},
        };
        for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
            id<MTLTexture> t = make(dev, cases[c].format, cases[c].slices);
            if (!t) return FAIL(bug, "%s: no texture", cases[c].name);
            NSUInteger w = 16 >> cases[c].level, h = 12 >> cases[c].level, row = 256, offset = 256;
            MTLBlitOption options = cases[c].format == MTLPixelFormatStencil8 ? MTLBlitOptionNone : MTLBlitOptionStencilFromDepthStencil;
            id<MTLBuffer> in = [dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
            uint8_t *values = in.contents;
            for (NSUInteger i = 0; i < w * h; i++) values[i] = (uint8_t)(i * 7 + 3 + c * 40);
            id<MTLBuffer> out = [dev newBufferWithLength:offset + row * h options:MTLResourceStorageModeShared];
            memset(out.contents, 0xee, out.length);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
                destinationSlice:cases[c].slice destinationLevel:cases[c].level destinationOrigin:MTLOriginMake(0, 0, 0) options:options];
            [blit copyFromTexture:t sourceSlice:cases[c].slice sourceLevel:cases[c].level sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1) toBuffer:out destinationOffset:offset destinationBytesPerRow:row
                 destinationBytesPerImage:row * h options:options];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", cases[c].name);
            const uint8_t *got = (const uint8_t *)out.contents + offset;
            NSUInteger wrong = 0, first = 0;
            for (NSUInteger y = 0; y < h; y++)
                for (NSUInteger x = 0; x < w; x++)
                    if (got[y * row + x] != values[y * w + x] && !wrong++) first = y * w + x;
            if (wrong)
                return FAIL(bug, "%s: %s read back with bytesPerRow 256: %lu of %lu texels wrong (first (%lu,%lu) reads %02x, want %02x)",
                            dev.name.UTF8String, cases[c].name, (unsigned long)wrong, (unsigned long)(w * h), (unsigned long)(first % w),
                            (unsigned long)(first / w), got[(first / w) * row + first % w], values[first]);
        }
        return PASS(bug, "%s: stencil read back with bytesPerRow 256 at levels 0 and 1, slice 1 and from Depth32Float_Stencil8", dev.name.UTF8String);
    }
}
