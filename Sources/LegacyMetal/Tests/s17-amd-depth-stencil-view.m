// s17-amd-depth-stencil-view (AMDBronzeCompat item 1): a depth/stencil attachment given as a 2D texture view of mip 1+
// of a 2D-array texture, with the 12.5 AMD driver. A stencil clear through the view is lost, and goes to level 0 / slice
// 0 instead, over what's there (wgpu zero_init depth/stencil tests, Dawn DepthStencilCopyTests, WebGPU CTS). Attaching the
// parent texture with level/slice works. For Stencil8, Depth32Float_Stencil8 and Depth32Float: fills level 0 / slice 0,
// clears level 1 / slice 1 through a view, then copies both to buffers: the view's clear must land, and only there.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

// Copies one level/slice's stencil (or depth) to a buffer; true if every texel holds `want`.
static BOOL holds(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t, NSUInteger level, NSUInteger slice, BOOL stencil, uint32_t want) {
    NSUInteger w = t.width >> level, h = MAX(t.height >> level, 1), bytes = stencil ? 1 : 4;
    id<MTLBuffer> out = [d newBufferWithLength:w * h * bytes options:MTLResourceStorageModeShared];
    memset(out.contents, 0x11, out.length);
    MTLBlitOption option = t.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionNone
                           : stencil ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
     destinationOffset:0 destinationBytesPerRow:w * bytes destinationBytesPerImage:w * h * bytes options:option];
    [b endEncoding];
    reproRun(cb);
    for (NSUInteger i = 0; i < w * h; i++) {
        uint32_t got = stencil ? ((const uint8_t *)out.contents)[i] : ((const uint32_t *)out.contents)[i];
        if (got != want) return NO;
    }
    return YES;
}

static void clearAttachment(id<MTLCommandQueue> q, id<MTLTexture> t, NSUInteger level, NSUInteger slice, BOOL stencil, BOOL depth, uint8_t s, float z) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (stencil) {
        rp.stencilAttachment.texture = t; rp.stencilAttachment.level = level; rp.stencilAttachment.slice = slice;
        rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionStore; rp.stencilAttachment.clearStencil = s;
    }
    if (depth) {
        rp.depthAttachment.texture = t; rp.depthAttachment.level = level; rp.depthAttachment.slice = slice;
        rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = z;
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    reproRun(cb);
}

// NULL if right, else what went wrong.
static const char *check(id<MTLDevice> d, MTLPixelFormat format) {
    BOOL stencil = format != MTLPixelFormatDepth32Float, depth = format != MTLPixelFormatStencil8;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.width = 256; td.height = 4; td.arrayLength = 3; td.mipmapLevelCount = 3;
    td.pixelFormat = format; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    id<MTLCommandQueue> q = [d newCommandQueue];
    const float zFill = 0.25f, zView = 0.75f;
    uint32_t zFillBits, zViewBits;
    memcpy(&zFillBits, &zFill, 4); memcpy(&zViewBits, &zView, 4);
    clearAttachment(q, t, 0, 0, stencil, depth, 0x55, zFill);
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:format textureType:MTLTextureType2D levels:NSMakeRange(1, 1) slices:NSMakeRange(1, 1)];
    clearAttachment(q, view, 0, 0, stencil, depth, 0xab, zView);
    if (stencil && !holds(d, q, t, 1, 1, YES, 0xab)) return "stencil clear lost";
    if (depth && !holds(d, q, t, 1, 1, NO, zViewBits)) return "depth clear lost";
    if (stencil && !holds(d, q, t, 0, 0, YES, 0x55)) return "stencil of level 0 / slice 0 overwritten";
    if (depth && !holds(d, q, t, 0, 0, NO, zFillBits)) return "depth of level 0 / slice 0 overwritten";
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s17-amd-depth-stencil-view";
        id<MTLDevice> d = reproDevice(argc, argv, "AMD");
        if (!d) return SKIP(bug, "no such GPU");
        const char *s8 = check(d, MTLPixelFormatStencil8), *d32s8 = check(d, MTLPixelFormatDepth32Float_Stencil8), *d32 = check(d, MTLPixelFormatDepth32Float);
        if (!s8 && !d32s8 && !d32) return PASS(bug, "%s: clears through 2D views of level 1 / slice 1 land there and only there (S8, D32S8, D32)", d.name.UTF8String);
        return FAIL(bug, "%s: clears through a 2D view of level 1 slice 1: Stencil8 %s; Depth32Float_Stencil8 %s; Depth32Float %s", d.name.UTF8String,
                    s8 ?: "ok", d32s8 ?: "ok", d32 ?: "ok");
    }
}
