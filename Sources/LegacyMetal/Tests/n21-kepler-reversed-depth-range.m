// n21-kepler-reversed-depth-range: reversed viewport depth ranges (znear > zfar) must be kept; Kepler put them in
// order. Fix: MetalOldCompat item 70. Checks: z = 0.25 through setViewport: at five ranges, and setViewports:count:.
// Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 v(uint i [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[i], 0.25, 1); }\n"
    "fragment float4 f() { return float4(0, 1, 0, 1); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n21-kepler-reversed-depth-range";
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
    rd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    double ranges[][2] = {{0, 1}, {1, 0}, {0.25, 0.75}, {0.75, 0.25}, {0.5, 0.5}, {1, 0}};
    for (int k = 0; k < 6; k++) {
        BOOL many = k == 5;  // setViewports:count: (viewport 0 reversed, viewport 1 in order)
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget;
        cd.storageMode = MTLStorageModePrivate;
        MTLTextureDescriptor *zd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];
        zd.usage = MTLTextureUsageRenderTarget;
        zd.storageMode = MTLStorageModePrivate;
        id<MTLBuffer> depth = [dev newBufferWithLength:8 * 8 * 4 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:cd];
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.depthAttachment.texture = [dev newTextureWithDescriptor:zd];
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 0.123;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        MTLViewport vp = {0, 0, 8, 8, ranges[k][0], ranges[k][1]};
        if (many) {
            MTLViewport vps[2] = {vp, {0, 0, 8, 8, 0, 1}};
            [re setViewports:vps count:2];
        } else {
            [re setViewport:vp];
        }
        [re setRenderPipelineState:ps];
        [re setDepthStencilState:ds];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:pass.depthAttachment.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                   toBuffer:depth destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        float want = (float)(ranges[k][0] + 0.25 * (ranges[k][1] - ranges[k][0]));
        for (int i = 0; i < 64; i++) {
            float got = ((const float *)depth.contents)[i];
            if (fabsf(got - want) > 1e-6f)
                return FAIL(bug, "%s: %s with depth range %.2f..%.2f stored z = 0.25 as %.4f, want %.4f", name,
                            many ? "setViewports:count:" : "setViewport:", ranges[k][0], ranges[k][1], got, want);
        }
    }
    return PASS(bug, "%s: reversed viewport depth ranges (1..0, 0.75..0.25) map z = 0.25 to znear + z * (zfar - znear), through both setters", name);
}}
