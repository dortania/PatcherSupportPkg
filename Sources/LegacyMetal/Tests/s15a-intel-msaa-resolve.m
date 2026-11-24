// s15a-intel-msaa-resolve: MSAA resolves into level or slice 1+ of a 2D array must land; the 12.x Intel driver lost
// them (or crashed, through a view). Fix: MetalOldCompat item 15.
// Checks: resolveLevel/resolveSlice and a one-level view, each in a child. Argument: GPU name.
#import "repro.h"

static int child(int argc, char **argv, const char *mode) {
    id<MTLDevice> d = reproDevice(argc, argv, "Intel");
    BOOL view = !strcmp(mode, "view");
    NSUInteger level = 1, slice = 1, w = 64 >> level;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.pixelFormat = MTLPixelFormatR8Unorm; td.width = td.height = 64;
    td.arrayLength = 2; td.mipmapLevelCount = 2; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> out = [d newTextureWithDescriptor:td];
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:w height:w mipmapped:NO];
    md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [d newTextureWithDescriptor:md];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    if (view) {
        rp.colorAttachments[0].resolveTexture = [out newTextureViewWithPixelFormat:MTLPixelFormatR8Unorm textureType:MTLTextureType2D
                                                                            levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    } else {
        rp.colorAttachments[0].resolveTexture = out;
        rp.colorAttachments[0].resolveLevel = level;
        rp.colorAttachments[0].resolveSlice = slice;
    }
    id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:out];
    [b endEncoding];
    reproRun(cb);
    uint8_t px[32 * 32] = {0};
    [out getBytes:px bytesPerRow:w bytesPerImage:w * w fromRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:level slice:slice];
    for (NSUInteger i = 0; i < w * w; i++) if (px[i] != 255) return 10;
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s15a-intel-msaa-resolve", *mode = reproChildMode(argc, argv);
        if (mode) return child(argc, argv, mode);
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int direct = reproRunChild(argc, argv, "direct"), view = reproRunChild(argc, argv, "view");
        if (!direct && !view) return PASS(bug, "%s: MSAA resolves into level 1 / slice 1 (resolveLevel/Slice and a 2D view) correct", dev.name.UTF8String);
        return FAIL(bug, "%s: resolve into level 1 slice 1 via resolveLevel/resolveSlice: %s; via a 2D view: %s", dev.name.UTF8String,
                    direct == 10 ? "texels not written" : direct ? reproChildStatus(direct) : "ok",
                    view == 10 ? "texels not written" : view ? reproChildStatus(view) : "ok");
    }
}
