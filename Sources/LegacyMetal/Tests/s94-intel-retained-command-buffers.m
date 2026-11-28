// s94-intel-retained-command-buffers: command buffers that don't retain their references (MoltenVK's) must run what the
// shim encodes into them; on Intel item 27's temporaries were freed first (Invalid Resource: Godot lost the device).
// Fix: MetalOldCompat item 91 MTLSHIM_RETAIN_REFERENCES. Checks: a blit into a 4x4 Depth32Float render target (item 27
// writes it again) in commandBufferWithUnretainedReferences and in a descriptor's buffer without retained references.
#import "repro.h"

enum { Side = 4 };

// NULL when a blit of `depth` into a fresh render target in `cb` completes and reads back, else what went wrong
static const char *blitDepthIn(id<MTLDevice> dev, id<MTLCommandQueue> queue, id<MTLCommandBuffer> cb, float depth) {
    static char text[160];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:Side height:Side mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> values = [dev newBufferWithLength:Side * Side * 4 options:MTLResourceStorageModeShared];
    for (int i = 0; i < Side * Side; i++) ((float *)values.contents)[i] = depth;
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:values sourceOffset:0 sourceBytesPerRow:Side * 4 sourceBytesPerImage:Side * Side * 4 sourceSize:MTLSizeMake(Side, Side, 1)
             toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
    if (!reproRun(cb)) {
        snprintf(text, sizeof text, "failed: %s", cb.error.localizedDescription.UTF8String ?: "?");
        return text;
    }
    id<MTLBuffer> readBack = [dev newBufferWithLength:Side * Side * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> check = [queue commandBuffer];
    be = [check blitCommandEncoder];
    [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(Side, Side, 1)
               toBuffer:readBack destinationOffset:0 destinationBytesPerRow:Side * 4 destinationBytesPerImage:Side * Side * 4];
    [be endEncoding];
    if (!reproRun(check)) return "completed, but reading it back failed";
    const float got = ((const float *)readBack.contents)[Side + 1];
    if (fabsf(got - depth) > 1e-6f) {
        snprintf(text, sizeof text, "completed, depth read back %.4f, want %.4f", got, depth);
        return text;
    }
    return NULL;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s94-intel-retained-command-buffers";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const char *problem = blitDepthIn(dev, queue, [queue commandBufferWithUnretainedReferences], 0.25f);
    if (problem) return FAIL(bug, "%s: depth blit in commandBufferWithUnretainedReferences %s", name, problem);
    MTLCommandBufferDescriptor *descriptor = [MTLCommandBufferDescriptor new];
    descriptor.retainedReferences = NO;
    problem = blitDepthIn(dev, queue, [queue commandBufferWithDescriptor:descriptor], 0.75f);
    if (problem) return FAIL(bug, "%s: depth blit in a command buffer without retained references %s", name, problem);
    return PASS(bug, "%s: depth blits in command buffers without retained references complete and read back", name);
}}
