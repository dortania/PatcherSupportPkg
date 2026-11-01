// s26-amd-depth-stencil-copy-pitch (AMDBronzeCompat item 5): copying one aspect of a combined depth/stencil texture to a
// buffer with destinationBytesPerRow 0, on the 12.5 AMD driver. wgpu passes 0 when WebGPU leaves bytesPerRow out, as it may
// for a single row. The driver writes nothing (WebGPU conformance render_pass,clear_value:stencil_clear_value in Firefox).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

// Clears to depth 1 and stencil 7, copies the aspect's first texel, and returns whether it arrived.
static BOOL copied(id<MTLDevice> d, MTLPixelFormat format, MTLBlitOption option, NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    if (!t) return YES;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.stencilAttachment.texture = t; rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.clearStencil = 7; rp.stencilAttachment.storeAction = MTLStoreActionStore;
    id<MTLBuffer> b = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(b.contents, 0xcc, 16);
    id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:b
     destinationOffset:0 destinationBytesPerRow:bytesPerRow destinationBytesPerImage:bytesPerImage options:option];
    [e endEncoding];
    reproRun(cb);
    if (option == MTLBlitOptionStencilFromDepthStencil) return ((uint8_t *)b.contents)[0] == 7;
    uint32_t v = *(uint32_t *)b.contents;
    return format == MTLPixelFormatDepth32Float_Stencil8 ? *(float *)b.contents == 1.0f : (v & 0xffffff) == 0xffffff;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s26-amd-depth-stencil-copy-pitch";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        struct { const char *what; MTLPixelFormat format; MTLBlitOption option; } cases[] = {
            {"Depth24Unorm_Stencil8 stencil", MTLPixelFormatDepth24Unorm_Stencil8, MTLBlitOptionStencilFromDepthStencil},
            {"Depth32Float_Stencil8 stencil", MTLPixelFormatDepth32Float_Stencil8, MTLBlitOptionStencilFromDepthStencil},
            {"Depth24Unorm_Stencil8 depth", MTLPixelFormatDepth24Unorm_Stencil8, MTLBlitOptionDepthFromDepthStencil},
            {"Depth32Float_Stencil8 depth", MTLPixelFormatDepth32Float_Stencil8, MTLBlitOptionDepthFromDepthStencil},
        };
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            if (cases[i].format == MTLPixelFormatDepth24Unorm_Stencil8 && !dev.depth24Stencil8PixelFormatSupported) continue;
            if (!copied(dev, cases[i].format, cases[i].option, 256, 256))
                return FAIL(bug, "%s: %s: wrong even with a row pitch (test problem?)", dev.name.UTF8String, cases[i].what);
            if (!copied(dev, cases[i].format, cases[i].option, 0, 0))
                return FAIL(bug, "%s: %s: copy with row pitch 0 wrote nothing", dev.name.UTF8String, cases[i].what);
        }
        return PASS(bug, "%s: depth and stencil copies with row pitch 0 arrive", dev.name.UTF8String);
    }
}
