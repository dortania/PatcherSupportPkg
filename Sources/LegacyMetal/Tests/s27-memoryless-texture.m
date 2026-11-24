// s27-memoryless-texture: a memoryless texture (Safari's WebGPU) must be made; MetalOld's validation, and Tahoe's for
// AMD, aborted. Fix: MetalOldCompat item 3, AMDBronzeCompat item 8 AMD_BRONZE_MEMORYLESS.
// Checks: a 4x depth-stencil memoryless texture and a pass on it, in a child. Argument: GPU name.
#import "repro.h"

static int child(int argc, char **argv) {
    id<MTLDevice> d = reproDevice(argc, argv, "AMD");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:4 height:4 mipmapped:NO];
    td.textureType = MTLTextureType2DMultisample; td.sampleCount = 4;
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeMemoryless;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    if (!t) return 10;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    rp.stencilAttachment.texture = t; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    return reproRun(cb) ? 0 : 11;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s27-memoryless-texture";
        if (reproChildMode(argc, argv)) return child(argc, argv);
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        int status = reproRunChild(argc, argv, "run");
        if (status) return FAIL(bug, "%s: memoryless texture: %s", dev.name.UTF8String, status == 10 ? "not created" : status == 11 ? "render pass failed" : reproChildStatus(status));
        return PASS(bug, "%s: a memoryless texture request gets a private texture", dev.name.UTF8String);
    }
}
