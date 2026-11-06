// s32-intel-depth-stencil-blit (MetalOldCompat item 27): blits into depth and stencil on the 12.x Intel driver. A render
// pass after the blit doesn't see what it wrote: stencil copied in (from a buffer with StencilFromDepthStencil, or from
// another texture) still tests as the old stencil, though a blit reads it back right, and depth copied into a small
// texture that a render pass cleared (one that keeps HiZ; 4x4 here, 8x8 and larger were right) still tests as the cleared
// depth. ANGLE copies stencil this way on
// Intel GPUs, so WebGL's blitFramebuffer lost stencil. Each case: a 4x4 Depth32Float_Stencil8 render target cleared to depth
// 1, stencil 0 in a render pass; depth 0.25 and stencil 0x5A copied in by a blit; then a render pass that loads it draws
// at depth 0.5 with depth test Greater and stencil test Equal 0x5A, which only passes where both were copied.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

enum Case { kStencilFromBuffer, kDepthFromBuffer, kTextureToTexture };
static const char *const kCaseNames[] = {"stencil from a buffer", "depth from a buffer", "depth and stencil from another texture"};

// 1 if the draw passed the depth and stencil tests, 0 if not, -1 if something failed
static int run(id<MTLDevice> dev, enum Case c) {
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0.5, 1); }\n"
        "fragment float4 f() { return float4(0, 1, 0, 1); }\n" stringByAppendingString:reproUniqueComment()] options:nil error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.depthAttachmentPixelFormat = pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    id<MTLRenderPipelineState> pipeline = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
    if (!pipeline) return -1;
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = c == kStencilFromBuffer ? MTLCompareFunctionAlways : MTLCompareFunctionGreater;
    if (c != kDepthFromBuffer) {
        MTLStencilDescriptor *stencil = [MTLStencilDescriptor new];
        stencil.stencilCompareFunction = MTLCompareFunctionEqual;
        dsd.frontFaceStencil = dsd.backFaceStencil = stencil;
    }
    id<MTLDepthStencilState> state = [dev newDepthStencilStateWithDescriptor:dsd];

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td], source = [dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    cd.usage = MTLTextureUsageRenderTarget;
    cd.storageMode = MTLStorageModeManaged;
    id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
    float depths[16];
    uint8_t stencils[16];
    for (int i = 0; i < 16; i++) depths[i] = 0.25f, stencils[i] = 0x5A;
    id<MTLBuffer> depthData = [dev newBufferWithBytes:depths length:sizeof depths options:MTLResourceStorageModeShared];
    id<MTLBuffer> stencilData = [dev newBufferWithBytes:stencils length:sizeof stencils options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    for (int which = 0; which < 2; which++) {  // the target cleared to depth 1, stencil 0; the source to what is copied
        if (which && c != kTextureToTexture) break;
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.depthAttachment.texture = clear.stencilAttachment.texture = which ? source : target;
        clear.depthAttachment.loadAction = clear.stencilAttachment.loadAction = MTLLoadActionClear;
        clear.depthAttachment.storeAction = clear.stencilAttachment.storeAction = MTLStoreActionStore;
        clear.depthAttachment.clearDepth = which ? 0.25 : 1.0;
        clear.stencilAttachment.clearStencil = which ? 0x5A : 0;
        [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
    }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (c == kStencilFromBuffer)
        [blit copyFromBuffer:stencilData sourceOffset:0 sourceBytesPerRow:4 sourceBytesPerImage:16 sourceSize:MTLSizeMake(4, 4, 1)
                   toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)
                     options:MTLBlitOptionStencilFromDepthStencil];
    else if (c == kDepthFromBuffer)
        [blit copyFromBuffer:depthData sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:MTLSizeMake(4, 4, 1)
                   toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)
                     options:MTLBlitOptionDepthFromDepthStencil];
    else
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1)
                    toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = color;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = rp.stencilAttachment.texture = target;
    rp.depthAttachment.loadAction = rp.stencilAttachment.loadAction = MTLLoadActionLoad;
    rp.depthAttachment.storeAction = rp.stencilAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pipeline];
    [enc setDepthStencilState:state];
    [enc setStencilReferenceValue:0x5A];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    id<MTLBlitCommandEncoder> sync = [cb blitCommandEncoder];
    [sync synchronizeResource:color];
    [sync endEncoding];
    if (!reproRun(cb)) return -1;
    uint8_t px[4];
    [color getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 2, 1, 1) mipmapLevel:0];
    return px[1] == 255 && px[0] == 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s32-intel-depth-stencil-blit";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSMutableArray<NSString *> *lost = [NSMutableArray array];
        for (int c = 0; c < 3; c++) {
            int result = run(dev, (enum Case)c);
            if (result < 0) return FAIL(bug, "%s: %s: a pipeline or the command buffer failed", dev.name.UTF8String, kCaseNames[c]);
            if (!result) [lost addObject:@(kCaseNames[c])];
        }
        if (lost.count)
            return FAIL(bug, "%s: copied in by a blit, a later render pass tests against the value from before it: %s", dev.name.UTF8String,
                        [lost componentsJoinedByString:@"; "].UTF8String);
        return PASS(bug, "%s: depth and stencil copied in by blits are what later render passes test against", dev.name.UTF8String);
    }
}
