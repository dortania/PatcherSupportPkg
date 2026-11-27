// s93-intel-swizzle-shadow-refresh: a swizzled view must read the texels written after it was made; Intel's driver has
// no swizzled views and item 90's shadow copies stand in. Fix: MetalOldCompat item 90 MTLSHIM_SWIZZLE_SHADOW.
// Checks: R8 as L8 (RRR1) after a CPU upload, after a blit and after a render-pass clear (both read in the same command
// buffer), and RGBA8 sRGB as L8 (decoded). Argument: GPU name.
#import "repro.h"

enum { Side = 4 };
static const MTLTextureSwizzleChannels kL8 = {MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne};
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 1)); }\n";

static id<MTLTexture> newTexture(id<MTLDevice> dev, MTLPixelFormat format, MTLTextureUsage usage, MTLStorageMode storage) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:Side height:Side mipmapped:NO];
    td.usage = usage;
    td.storageMode = storage;
    return [dev newTextureWithDescriptor:td];
}
static void fill(id<MTLTexture> t, uint8_t value, NSUInteger bytesPerPixel) {
    uint8_t texels[Side * Side * 4];
    memset(texels, value, sizeof texels);
    [t replaceRegion:MTLRegionMake2D(0, 0, Side, Side) mipmapLevel:0 withBytes:texels bytesPerRow:Side * bytesPerPixel];
}
static id<MTLTexture> l8View(id<MTLTexture> t) {
    return [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1) swizzle:kL8];
}
static void encodeRead(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> ps, id<MTLTexture> view, id<MTLBuffer> out) {
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:view atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
}
// NULL when the view read (want, want, want, 1), else what it read
static const char *misread(id<MTLBuffer> out, float want) {
    static char text[96];
    const float *o = out.contents;
    if (fabsf(o[0] - want) < 0.01f && fabsf(o[1] - want) < 0.01f && fabsf(o[2] - want) < 0.01f && fabsf(o[3] - 1) < 0.01f) return NULL;
    snprintf(text, sizeof text, "read (%.3f, %.3f, %.3f, %.3f), want (%.3f, %.3f, %.3f, 1)", o[0], o[1], o[2], o[3], want, want, want);
    return text;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s93-intel-swizzle-shadow-refresh";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSString *why = nil;
    id<MTLComputePipelineState> ps = reproComputePipeline(dev, src, nil, &why);
    if (!ps) return FAIL(bug, "%s", why.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];

    id<MTLTexture> uploaded = newTexture(dev, MTLPixelFormatR8Unorm, MTLTextureUsageShaderRead, MTLStorageModeManaged);
    fill(uploaded, 0x10, 1);
    id<MTLTexture> view = l8View(uploaded);
    if (!view) return FAIL(bug, "%s: the swizzled view is nil", name);
    fill(uploaded, 0x80, 1);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    encodeRead(cb, ps, view, out);
    if (!reproRun(cb)) return FAIL(bug, "%s: CPU upload: command buffer failed", name);
    if (misread(out, 0x80 / 255.0f)) return FAIL(bug, "%s: R8 as L8 after a CPU upload %s", name, misread(out, 0x80 / 255.0f));

    id<MTLTexture> blitted = newTexture(dev, MTLPixelFormatR8Unorm, MTLTextureUsageShaderRead, MTLStorageModePrivate);
    view = l8View(blitted);
    id<MTLBuffer> texels = [dev newBufferWithLength:Side * Side options:MTLResourceStorageModeShared];
    memset(texels.contents, 0xC0, Side * Side);
    cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:texels sourceOffset:0 sourceBytesPerRow:Side sourceBytesPerImage:Side * Side sourceSize:MTLSizeMake(Side, Side, 1)
             toTexture:blitted destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
    encodeRead(cb, ps, view, out);
    if (!reproRun(cb)) return FAIL(bug, "%s: blit: command buffer failed", name);
    if (misread(out, 0xC0 / 255.0f)) return FAIL(bug, "%s: R8 as L8 after a blit %s", name, misread(out, 0xC0 / 255.0f));

    id<MTLTexture> cleared = newTexture(dev, MTLPixelFormatR8Unorm, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, MTLStorageModePrivate);
    view = l8View(cleared);
    cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = cleared;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0, 0, 1);
    [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
    encodeRead(cb, ps, view, out);
    if (!reproRun(cb)) return FAIL(bug, "%s: render pass: command buffer failed", name);
    if (misread(out, 0.25f)) return FAIL(bug, "%s: R8 as L8 after a render-pass clear %s", name, misread(out, 0.25f));

    id<MTLTexture> srgb = newTexture(dev, MTLPixelFormatRGBA8Unorm_sRGB, MTLTextureUsageShaderRead, MTLStorageModeManaged);
    fill(srgb, 0x80, 4);
    view = l8View(srgb);
    cb = [queue commandBuffer];
    encodeRead(cb, ps, view, out);
    if (!reproRun(cb)) return FAIL(bug, "%s: sRGB: command buffer failed", name);
    const float decoded = 0.2158f;  // sRGB 128/255, linear
    if (misread(out, decoded)) return FAIL(bug, "%s: RGBA8 sRGB as L8 %s", name, misread(out, decoded));
    return PASS(bug, "%s: swizzled views read what a CPU upload, a blit and a render pass wrote later, and sRGB decoded", name);
}}
