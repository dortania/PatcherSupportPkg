// s27-memoryless-texture (shim item 3): a texture with MTLStorageModeMemoryless on MetalOld. Only Apple GPUs have that storage, and
// MetalOld's descriptor validation aborts the process. Safari 27's WebGPU asks for it for transient attachments (WebGPU
// conformance render_pass,resolve, which crashes Safari's GPU process). Runs in a child, because the failure is an abort.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
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
