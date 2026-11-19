// n23-kepler-wide-point-clipping (MetalOldCompat item 69, its point part): wide points whose center is outside the
// viewport. Kepler's driver set the line and point cull guard band to the viewport itself, so a point centered outside
// it was culled whole, with the part of it that's inside (Khronos WebGL clipping-wide-points). 8-pixel points on a 16x16
// target: centered 0.4 px left of the left edge (its 4 inside columns, 32 pixels), 0.4 px above the top (32), on the
// bottom-right corner just outside it (16), inside (64), and 10 px out (0: nothing of it is inside); then centered 0.4 px
// left of viewport (4, 4, 8, 8) in the target (32 pixels, none outside the viewport: item 69's scissor half).
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 p [[position]]; float size [[point_size]]; };\n"
    "vertex VO v(uint i [[vertex_id]], constant float2 *p [[buffer(0)]]) { VO o; o.p = float4(p[i], 0, 1); o.size = 8; return o; }\n"
    "fragment float4 f() { return float4(0, 1, 0, 1); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n23-kepler-wide-point-clipping";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"v"];
    rd.fragmentFunction = [lib newFunctionWithName:@"f"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    rd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // window position (x, y) -> clip (x / 8 - 1, 1 - y / 8) on the 16x16 target
    struct { const char *what; float x, y; int want; } points[] = {
        {"centered 0.4 px left of the left edge", -0.4f, 8, 32}, {"centered 0.4 px above the top", 8, -0.4f, 32},
        {"centered just outside the bottom-right corner", 16.4f, 16.4f, 16}, {"inside", 8, 8, 64}, {"10 px left of the edge", -10, 8, 0},
        {"centered 0.4 px left of viewport (4, 4, 8, 8)", 3.6f, 8, 32}};
    for (int k = 0; k < 6; k++) {
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
        BOOL small = k == 5;  // a viewport smaller than the target: nothing may land outside it
        [re setViewport:small ? (MTLViewport){4, 4, 8, 8, 0, 1} : (MTLViewport){0, 0, 16, 16, 0, 1}];
        [re setRenderPipelineState:ps];
        float p[2] = {small ? (points[k].x - 4) / 4 - 1 : points[k].x / 8 - 1, small ? 1 - (points[k].y - 4) / 4 : 1 - points[k].y / 8};
        [re setVertexBytes:p length:sizeof p atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        int drawn = 0, outside = 0;
        for (int i = 0; i < 256; i++)
            if (((const uint32_t *)pixels.contents)[i]) {
                drawn++;
                outside += k == 5 && !(i % 16 >= 4 && i % 16 < 12 && i / 16 >= 4 && i / 16 < 12);
            }
        if (outside) return FAIL(bug, "%s: an 8-pixel point %s drew %d pixels outside the viewport", name, points[k].what, outside);
        if (drawn != points[k].want)
            return FAIL(bug, "%s: an 8-pixel point %s drew %d pixels, want %d", name, points[k].what, drawn, points[k].want);
    }
    return PASS(bug, "%s: wide points centered outside the viewport draw the part that's inside", name);
}}
