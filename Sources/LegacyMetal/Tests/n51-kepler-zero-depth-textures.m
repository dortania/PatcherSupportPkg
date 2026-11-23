// n51-kepler-zero-depth-textures (MetalOldCompat item 84): new depth and stencil textures must read zero. Kepler's driver
// hands a new depth or stencil texture the memory a freed one of the same size left, as it was, and Safari's WebGPU
// relies on new textures being zero (as Apple's GPUs make them) for a depth/stencil attachment that a pass loads and
// stores: WebGPU CTS resource_init,texture_zero:uninitialized_texture_is_zero (2d, DepthTest and StencilTest after
// "Creation") read the old values, which a page could use to read another resource's freed data. (Item 84 is on in
// WebKit's GPU process, elsewhere with MTLSHIM_NV_ZERO_DEPTH=1, which the test sets for itself.) Checked, for
// Depth32Float (5 levels, 3 slices), Depth16Unorm, Stencil8 and Depth32Float_Stencil8 (both aspects), 64x64 render
// targets: textures of the same kind are cleared to depth 0.7 / stencil 0x5a and freed, then every level and slice of a
// new one is copied to a buffer and must be all zero. Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name
// substring (default: NVIDIA).
#import "repro.h"

static int check(const char *bug, const char *name, id<MTLDevice> dev, id<MTLCommandQueue> queue, MTLPixelFormat format,
                 const char *formatName, NSUInteger levels, NSUInteger slices) {
    BOOL depth = format != MTLPixelFormatStencil8, stencil = format == MTLPixelFormatStencil8 || format == MTLPixelFormatDepth32Float_Stencil8;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = slices > 1 ? MTLTextureType2DArray : MTLTextureType2D;
    td.pixelFormat = format;
    td.width = 64;
    td.height = 64;
    td.mipmapLevelCount = levels;
    td.arrayLength = slices;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    for (int round = 0; round < 4; round++) {
        @autoreleasepool {  // the canary: textures of the same kind, written and freed
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            for (int k = 0; k < 4; k++) {
                id<MTLTexture> old = [dev newTextureWithDescriptor:td];
                for (NSUInteger level = 0; level < levels; level++)
                    for (NSUInteger slice = 0; slice < slices; slice++) {
                        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                        if (depth) {
                            pass.depthAttachment.texture = old;
                            pass.depthAttachment.level = level;
                            pass.depthAttachment.slice = slice;
                            pass.depthAttachment.loadAction = MTLLoadActionClear;
                            pass.depthAttachment.clearDepth = 0.7;
                            pass.depthAttachment.storeAction = MTLStoreActionStore;
                        }
                        if (stencil) {
                            pass.stencilAttachment.texture = old;
                            pass.stencilAttachment.level = level;
                            pass.stencilAttachment.slice = slice;
                            pass.stencilAttachment.loadAction = MTLLoadActionClear;
                            pass.stencilAttachment.clearStencil = 0x5a;
                            pass.stencilAttachment.storeAction = MTLStoreActionStore;
                        }
                        [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
                    }
            }
            if (!reproRun(cb)) return FAIL(bug, "%s: %s canary passes: command buffer failed", name, formatName);
        }
        id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
        for (NSUInteger level = 0; level < levels; level++)
            for (NSUInteger slice = 0; slice < slices; slice++)
                for (int aspect = 0; aspect < 2; aspect++) {
                    if ((aspect == 0 && !depth) || (aspect == 1 && !stencil)) continue;
                    NSUInteger side = MAX((NSUInteger)64 >> level, (NSUInteger)1);
                    NSUInteger bytes = aspect ? 1 : format == MTLPixelFormatDepth16Unorm ? 2 : 4;
                    id<MTLBuffer> out = [dev newBufferWithLength:256 * side options:MTLResourceStorageModeShared];
                    memset(out.contents, 0xee, out.length);
                    MTLBlitOption option = format == MTLPixelFormatDepth32Float_Stencil8
                                               ? (aspect ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil)
                                               : MTLBlitOptionNone;
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit copyFromTexture:texture sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(side, side, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256
                  destinationBytesPerImage:256 * side options:option];
                    [blit endEncoding];
                    if (!reproRun(cb)) return FAIL(bug, "%s: %s read back: command buffer failed", name, formatName);
                    const uint8_t *o = out.contents;
                    for (NSUInteger y = 0; y < side; y++)
                        for (NSUInteger x = 0; x < side * bytes; x++)
                            if (o[y * 256 + x])
                                return FAIL(bug, "%s: a new %s texture's %s at level %lu slice %lu, byte %lu of row %lu, is 0x%02x (try %d)",
                                            name, formatName, aspect ? "stencil" : "depth", (unsigned long)level, (unsigned long)slice,
                                            (unsigned long)x, (unsigned long)y, o[y * 256 + x], round + 1);
                }
    }
    return -1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n51-kepler-zero-depth-textures";
        setenv("MTLSHIM_NV_ZERO_DEPTH", "1", 0);  // item 84 is on by itself only in WebKit's GPU process (=0, the fix's switch, stays)
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        int r;
        if ((r = check(bug, name, dev, queue, MTLPixelFormatDepth32Float, "Depth32Float (5 levels, 3 slices)", 5, 3)) >= 0) return r;
        if ((r = check(bug, name, dev, queue, MTLPixelFormatDepth16Unorm, "Depth16Unorm", 1, 1)) >= 0) return r;
        if ((r = check(bug, name, dev, queue, MTLPixelFormatStencil8, "Stencil8", 1, 1)) >= 0) return r;
        if ((r = check(bug, name, dev, queue, MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8", 1, 1)) >= 0) return r;
        return PASS(bug, "%s: new depth and stencil textures read zero on every level and slice (Depth32Float with 5 levels and 3 slices, "
                         "Depth16Unorm, Stencil8, Depth32Float_Stencil8)", name);
    }
}
