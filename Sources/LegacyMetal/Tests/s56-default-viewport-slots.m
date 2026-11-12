// s56-default-viewport-slots (AMDBronzeCompat item 13, MetalOldCompat item 42): before the app sets a viewport, every one
// of the 16 viewport slots must cover the render target, as on Apple GPUs. The 12.5 AMD and 12.x Intel drivers set up
// only slot 0, so primitives sent to slot 1-15 with [[viewport_array_index]] drew nothing, and so did vertex amplification
// views mapped to viewportArrayIndexOffset 1+: wgpu maps view i to slot i and sets no viewport unless the app does, and its
// multiview::draw_multiview left layer 1 of a 2-layer target at the clear color. Draws a triangle into each slot of a
// 64x64 target without setting a viewport, then (GPUs with vertex amplification) wgpu's multiview pass: 2 views into a
// 2-layer target, view 1 mapped to slot 1, the fragment function coloring by [[amplification_id]].
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; uint slot [[viewport_array_index]]; };\n"
    "vertex V toSlot(uint id [[vertex_id]], constant uint &slot [[buffer(0)]]) {\n"
    "  V o; o.p = float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); o.slot = slot; return o; }\n"
    "fragment float4 slotColor(V i [[stage_in]]) { return float4(96.0 / 255.0); }\n"
    "struct P { float4 p [[position]]; };\n"
    "vertex P plain(uint id [[vertex_id]]) { P o; o.p = float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); return o; }\n"
    "fragment float4 viewColor(uint view [[amplification_id]]) { return float4((32.0 + 64.0 * float(view)) / 255.0); }\n";

enum { N = 64 };

// Draws into a cleared N x N (x layers) R8Unorm target and returns how many texels of each layer hold want[layer].
static void draw(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLRenderPipelineState> ps, NSUInteger layers, uint32_t slot, BOOL amplify,
                 const uint8_t *want, int *right) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:N height:N mipmapped:NO];
    if (layers > 1) td.textureType = MTLTextureType2DArray, td.arrayLength = layers;
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> out = [dev newBufferWithLength:N * N * layers options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (layers > 1) rp.renderTargetArrayLength = layers;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (amplify) {
        MTLVertexAmplificationViewMapping maps[2] = {{.viewportArrayIndexOffset = 0, .renderTargetArrayIndexOffset = 0},
                                                     {.viewportArrayIndexOffset = 1, .renderTargetArrayIndexOffset = 1}};
        [enc setVertexAmplificationCount:2 viewMappings:maps];
    }
    [enc setRenderPipelineState:ps];
    if (!amplify) [enc setVertexBytes:&slot length:4 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (NSUInteger s = 0; s < layers; s++)
        [blit copyFromTexture:target sourceSlice:s sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(N, N, 1)
                     toBuffer:out destinationOffset:N * N * s destinationBytesPerRow:N destinationBytesPerImage:N * N];
    [blit endEncoding];
    if (!reproRun(cb)) {
        for (NSUInteger s = 0; s < layers; s++) right[s] = -1;
        return;
    }
    const uint8_t *p = out.contents;
    for (NSUInteger s = 0; s < layers; s++) {
        right[s] = 0;
        for (int i = 0; i < N * N; i++) right[s] += abs((int)p[N * N * s + i] - want[s]) <= 1;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s56-default-viewport-slots";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"toSlot"];
        pd.fragmentFunction = [lib newFunctionWithName:@"slotColor"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        id<MTLRenderPipelineState> slots = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!slots) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const uint8_t kSlotColor[1] = {96};
        for (uint32_t slot = 0; slot < 16; slot++) {
            int right[1];
            draw(dev, q, slots, 1, slot, NO, kSlotColor, right);
            if (right[0] < 0) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            if (right[0] != N * N)
                return FAIL(bug, "%s: with no viewport set, a triangle sent to viewport slot %u covers %d of %d texels", dev.name.UTF8String, slot,
                            right[0], N * N);
        }
        if (![dev supportsVertexAmplificationCount:2])
            return PASS(bug, "%s: with no viewport set, all 16 viewport slots cover the render target (no vertex amplification)", dev.name.UTF8String);
        pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"plain"];
        pd.fragmentFunction = [lib newFunctionWithName:@"viewColor"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        pd.maxVertexAmplificationCount = 2;
        id<MTLRenderPipelineState> views = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!views) return FAIL(bug, "%s: no amplification pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        static const uint8_t kViewColor[2] = {32, 96};
        int right[2];
        draw(dev, q, views, 2, 0, YES, kViewColor, right);
        if (right[0] < 0) return FAIL(bug, "%s: command buffer failed (amplification)", dev.name.UTF8String);
        for (int s = 0; s < 2; s++)
            if (right[s] != N * N)
                return FAIL(bug, "%s: 2 amplified views, view 1 in viewport slot 1, no viewport set: layer %d has %d of %d texels drawn",
                            dev.name.UTF8String, s, right[s], N * N);
        return PASS(bug, "%s: with no viewport set, all 16 viewport slots cover the render target, and 2 amplified views fill both layers",
                    dev.name.UTF8String);
    }
}
