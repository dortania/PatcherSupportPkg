// i85-intel-argument-buffer-dynamic-offset: a dynamic-offset read of an argument buffer's first member must compile on
// Ivy Bridge. Fix: IntelTextureAtomics INTEL_IVB_ARGUMENT_BUFFER_FIX, MetalOldCompat MTLSHIM_IVB_ARGUMENT_BUFFERS.
// Checks: a depth-only quad whose depths come from that uniform must land where it should. Argument: GPU name.
#import "repro.h"

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Uniform { float field0; };\n"
    "struct Bindings {\n"
    "    const constant Uniform &global0 [[id(0)]];\n"
    "    uint global0Length [[id(1)]];\n"
    "};\n"
    "vertex float4 vs(uint vid [[vertex_id]], constant Bindings &ab [[buffer(29)]], const constant uint *dynamicOffsets [[buffer(30)]]) {\n"
    "    const constant Uniform &u = *(const constant Uniform *)(((constant uint8_t *)&ab.global0) + dynamicOffsets[0]);\n"
    "    float corner = u.field0;\n"
    "    const float3 p[6] = { float3(-1, 1, corner), float3(-1, -1, 0), float3(1, 1, 1), float3(-1, -1, 0), float3(1, 1, 1), float3(1, -1, corner) };\n"
    "    return float4(p[min(vid, 5u)], 1.0);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i85-intel-argument-buffer-dynamic-offset";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: compile: %s", name, error.localizedDescription.UTF8String);
        id<MTLFunction> vf = [lib newFunctionWithName:@"vs"];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, error.localizedDescription.UTF8String);

        enum { W = 4, Offset = 256 };
        const float corner = 0.7f;
        id<MTLBuffer> uniform = [dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
        memset(uniform.contents, 0, uniform.length);
        memcpy((uint8_t *)uniform.contents + Offset, &corner, sizeof corner);
        const uint32_t dynamicOffset = Offset;
        id<MTLArgumentEncoder> ae = [vf newArgumentEncoderWithBufferIndex:29];
        if (!ae) return FAIL(bug, "%s: no argument encoder", name);
        id<MTLBuffer> ab = [dev newBufferWithLength:MAX(ae.encodedLength, (NSUInteger)16) options:MTLResourceStorageModeShared];
        [ae setArgumentBuffer:ab offset:0];
        [ae setBuffer:uniform offset:0 atIndex:0];
        *(uint32_t *)[ae constantDataAtIndex:1] = 4;

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:W mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 0.25;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = MTLCompareFunctionAlways;
        dsd.depthWriteEnabled = YES;
        id<MTLBuffer> out = [dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:ps];
        [re setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dsd]];
        [re setVertexBuffer:ab offset:0 atIndex:29];
        [re setVertexBytes:&dynamicOffset length:sizeof dynamicOffset atIndex:30];
        [re useResource:uniform usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1)
                   toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);

        // two triangles: z = 0.15x + 0.35y + 0.5 above the diagonal, 0.35x + 0.15y + 0.5 below (corner depth 0.7)
        const float *d = out.contents;
        for (int j = 0; j < W; j++)
            for (int i = 0; i < W; i++) {
                float x = (i + 0.5f) * 2 / W - 1, y = 1 - (j + 0.5f) * 2 / W;
                float a = (corner - 0.4f) / 2, b = corner / 2;  // 0.15 and 0.35
                float want = y > x ? a * x + b * y + 0.5f : b * x + a * y + 0.5f;
                if (fabsf(d[j * W + i] - want) > 0.01f)
                    return FAIL(bug, "%s: depth at %d,%d = %.3f, want %.3f (the uniform read at the dynamic offset through the argument buffer)",
                                name, i, j, d[j * W + i], want);
            }
        return PASS(bug, "%s: a vertex function reads a uniform from an argument buffer's first member at a dynamic offset (WebKit's bind groups)", name);
    }
}
