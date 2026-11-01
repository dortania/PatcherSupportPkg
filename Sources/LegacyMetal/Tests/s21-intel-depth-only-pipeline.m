// s21-intel-depth-only-pipeline (shim item 21): depth-only render pipelines on the 12.x Intel driver. A pipeline
// without a fragment function leaves its depth attachment unusable: drawing the same triangles again with compare
// Equal passes nowhere. With an empty fragment function it works. Depth-only passes (shadow maps, depth pre-passes,
// WebGPU pipelines without a fragment stage) are common; this is how the WebGPU CTS's depth copy tests fill depth.
// Triangles with varying z are drawn into a Depth32Float target by a pipeline with no fragment function, then drawn
// again with compare Equal and depth writes off into a color target: every pixel must come out green.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "constant float3 pos[6] = {float3(-1, 1, 0.5), float3(-1, -1, 0), float3(1, 1, 1), float3(-1, -1, 0), float3(1, 1, 1), float3(1, -1, 0.5)};\n"
    "vertex float4 v(uint i [[vertex_id]]) { return float4(pos[i], 1.0f); }\n"
    "fragment float4 f() { return float4(0, 1, 0, 1); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s21-intel-depth-only-pipeline";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *depthOnly = [MTLRenderPipelineDescriptor new];
        depthOnly.vertexFunction = [lib newFunctionWithName:@"v"];  // no fragment function
        depthOnly.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        MTLRenderPipelineDescriptor *check = [depthOnly copy];
        check.fragmentFunction = [lib newFunctionWithName:@"f"];
        check.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> init = [dev newRenderPipelineStateWithDescriptor:depthOnly error:&err];
        id<MTLRenderPipelineState> verify = init ? [dev newRenderPipelineStateWithDescriptor:check error:&err] : nil;
        if (!verify) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *always = [MTLDepthStencilDescriptor new], *equal = [MTLDepthStencilDescriptor new];
        always.depthCompareFunction = MTLCompareFunctionAlways;
        always.depthWriteEnabled = YES;
        equal.depthCompareFunction = MTLCompareFunctionEqual;
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:16 mipmapped:NO];
        dd.usage = MTLTextureUsageRenderTarget;
        dd.storageMode = MTLStorageModePrivate;
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:16 mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget;
        cd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:dd], color = [dev newTextureWithDescriptor:cd];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *fill = [MTLRenderPassDescriptor renderPassDescriptor];
        fill.depthAttachment.texture = depth;
        fill.depthAttachment.loadAction = MTLLoadActionClear;
        fill.depthAttachment.clearDepth = 0.0;
        fill.depthAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:fill];
        [e setRenderPipelineState:init];
        [e setDepthStencilState:[dev newDepthStencilStateWithDescriptor:always]];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [e endEncoding];
        MTLRenderPassDescriptor *test = [MTLRenderPassDescriptor renderPassDescriptor];
        test.colorAttachments[0].texture = color;
        test.colorAttachments[0].loadAction = MTLLoadActionClear;
        test.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
        test.colorAttachments[0].storeAction = MTLStoreActionStore;
        test.depthAttachment.texture = depth;
        test.depthAttachment.loadAction = MTLLoadActionLoad;
        test.depthAttachment.storeAction = MTLStoreActionStore;
        e = [cb renderCommandEncoderWithDescriptor:test];
        [e setRenderPipelineState:verify];
        [e setDepthStencilState:[dev newDepthStencilStateWithDescriptor:equal]];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b synchronizeResource:color];
        [b endEncoding];
        reproRun(cb);
        uint32_t px[32 * 16];
        [color getBytes:px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 16) mipmapLevel:0];
        int green = 0;
        for (int i = 0; i < 32 * 16; i++) green += (px[i] & 0xffffff) == 0x00ff00;
        if (green != 32 * 16)
            return FAIL(bug, "%s: depth from a pipeline without fragment function matches in %d of %d pixels", dev.name.UTF8String, green, 32 * 16);
        return PASS(bug, "%s: depth from a pipeline without fragment function matches in all %d pixels", dev.name.UTF8String, 32 * 16);
    }
}
