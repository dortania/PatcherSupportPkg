// n24-kepler-viewport-scissor (MetalOldCompat item 69, its scissor half): nothing may be drawn outside the viewport. Kepler's
// driver limits drawing to the viewport only by clipping with a guard band the size of the viewport; its pixel clip is the
// render target. With item 69's wider guard band, a triangle reaching past a viewport smaller than the target drew
// outside it, until the scissor became the app's scissor intersected with the viewport (n23 has the wide-point case). On
// a 16x16 target: a full-screen triangle through viewport (4, 4, 8, 8) (64 pixels, none outside); the triangle with an
// app scissor (6, 2, 8, 8) too (its 6x6 overlap with the viewport); viewports (0, 0, 8, 16) and (8, 0, 8, 16) with [[viewport_array_index]] from the instance, each instance's
// full-screen triangle colored by its index (each half its own color); and a viewport at (2.25, 2.25) size 9 (pixels 2-10,
// whose centers are inside).
// "Without" here is item 69's guard bands without the scissor half (MTLSHIM_NV_VIEWPORT_SCISSOR=0). Argument: GPU name
// substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 p [[position]]; uint vp [[viewport_array_index]]; float4 c; };\n"
    "vertex VO vt(uint i [[vertex_id]], uint inst [[instance_id]]) {\n"
    "    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};\n"
    "    VO o; o.p = float4(p[i], 0, 1); o.vp = inst; o.c = float4(inst, 1 - inst, 0, 1); return o; }\n"
    "fragment float4 ft(VO in [[stage_in]]) { return in.c; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n24-kepler-viewport-scissor";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    rd.vertexFunction = [lib newFunctionWithName:@"vt"];
    rd.fragmentFunction = [lib newFunctionWithName:@"ft"];
    rd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    id<MTLRenderPipelineState> triangles = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!triangles) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    enum { kTriangle, kScissored, kArray, kFractional };
    const char *what[] = {"a full-screen triangle through viewport (4, 4, 8, 8)",
                          "the triangle through viewport (4, 4, 8, 8) with scissor (6, 2, 8, 8)",
                          "full-screen triangles through viewports (0, 0, 8, 16) and (8, 0, 8, 16)", "the triangle through viewport (2.25, 2.25, 9, 9)"};
    for (int k = kTriangle; k <= kFractional; k++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> pixels = [dev newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        if (k == kArray) {
            MTLViewport vps[2] = {{0, 0, 8, 16, 0, 1}, {8, 0, 8, 16, 0, 1}};
            [re setViewports:vps count:2];
        } else if (k == kFractional) {
            [re setViewport:(MTLViewport){2.25, 2.25, 9, 9, 0, 1}];
        } else {
            [re setViewport:(MTLViewport){4, 4, 8, 8, 0, 1}];
        }
        if (k == kScissored) [re setScissorRect:(MTLScissorRect){6, 2, 8, 8}];
        [re setRenderPipelineState:triangles];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:k == kArray ? 2 : 1];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *px = pixels.contents;
        for (int y = 0; y < 16; y++)
            for (int x = 0; x < 16; x++) {
                uint32_t want = 0, green = 0xff00ff00, red = 0xff0000ff;
                switch (k) {
                case kTriangle: want = x >= 4 && x < 12 && y >= 4 && y < 12 ? green : 0; break;
                case kScissored: want = x >= 6 && x < 12 && y >= 4 && y < 10 ? green : 0; break;
                case kArray: want = x < 8 ? green : red; break;
                case kFractional: want = x >= 2 && x < 11 && y >= 2 && y < 11 ? green : 0; break;
                }
                if (px[y * 16 + x] != want)
                    return FAIL(bug, "%s: %s: pixel (%d, %d) is %08x, want %08x%s", name, what[k], x, y, px[y * 16 + x], want,
                                want ? "" : " (outside the viewport)");
            }
    }
    return PASS(bug, "%s: nothing is drawn outside the viewport (triangles, app scissors, viewport arrays, fractional viewports)", name);
}}
