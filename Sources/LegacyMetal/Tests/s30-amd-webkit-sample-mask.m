// s30-amd-webkit-sample-mask (AMDBronzeCompat item 7): WebKit's WebGPU sets GPUMultisampleState.mask with the render pipeline
// descriptor's sample mask. The 12.5 AMD driver takes 0 to mean no mask and draws every sample, where nothing should be drawn
// (WebGPU CTS occlusionQuery sample_mask, sampleMask=0); so does the 12.x Intel driver (MetalOldCompat item 29). The fixes
// only apply in WebKit's processes, so this calls itself one
// before Metal loads. It draws a full-screen triangle with mask 0 and checks no sample is counted or written, then checks that
// mask 1 still draws one sample per pixel.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"
#import <objc/message.h>

enum { kSize = 4, kSamples = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 vs(uint n [[vertex_id]]) { return float4(n == 1 ? 3 : -1, n == 2 ? 3 : -1, 0, 1); }\n"
    "fragment float4 fs() { return float4(1); }\n";

// Draws with the mask and returns the samples counted; *pixel gets the resolved color of one pixel.
static unsigned long long drawWithMask(id<MTLDevice> dev, id<MTLLibrary> lib, id<MTLCommandQueue> q, NSUInteger mask, uint32_t *pixel, NSError **err) {
    MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
    p.vertexFunction = [lib newFunctionWithName:@"vs"];
    p.fragmentFunction = [lib newFunctionWithName:@"fs"];
    p.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    p.rasterSampleCount = kSamples;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(p, NSSelectorFromString(@"setSampleMask:"), mask);
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:p error:err];
    if (!ps) return ~0ull;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSize height:kSize mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> resolved = [dev newTextureWithDescriptor:td];
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = kSamples;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> visibility = [dev newBufferWithLength:sizeof(uint64_t) options:MTLResourceStorageModeShared];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].resolveTexture = resolved;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    rp.visibilityResultBuffer = visibility;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    [e endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:resolved];
    [blit endEncoding];
    reproRun(cb);
    [resolved getBytes:pixel bytesPerRow:kSize * 4 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    return *(uint64_t *)visibility.contents;
}

int main(int argc, char **argv) {
    setprogname("com.apple.WebKit.s30");
    @autoreleasepool {
        const char *bug = "s30-amd-webkit-sample-mask";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        uint32_t pixel = 0;
        unsigned long long none = drawWithMask(dev, lib, q, 0, &pixel, &err);
        if (none == ~0ull) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        if (none || pixel != 0xff000000) return FAIL(bug, "%s: mask 0 counted %llu samples, pixel %08x", dev.name.UTF8String, none, pixel);
        unsigned long long one = drawWithMask(dev, lib, q, 1, &pixel, &err);
        if (one != kSize * kSize) return FAIL(bug, "%s: mask 1 counted %llu samples, want %d", dev.name.UTF8String, one, kSize * kSize);
        return PASS(bug, "%s: a sample mask of 0 draws nothing", dev.name.UTF8String);
    }
}
