// s22-intel-depth-hiz-levels (shim item 22): HiZ on the 12.x Intel driver for depth textures with several mip levels or
// slices. Depth written by a blit into a level or slice other than 0 is right in memory, but the hierarchical depth
// buffer isn't updated, so a later render pass that loads that level/slice fails every depth test against it (WebGPU
// CTS copy_depth_stencil, texture_zero with depth formats). Depth is drawn into level/slice 0 of one Depth32Float
// array texture (3 levels, 4 slices), blit-copied into level 2 / slice 0 and level 0 / slice 1 of another, and the
// same quad is drawn again against each with compare Equal into a color target: every pixel must come out green.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint i [[vertex_id]]) { return float4((i & 1) ? 1.0f : -1.0f, (i & 2) ? 1.0f : -1.0f, 0.25f, 1.0f); }\n"
    "fragment float4 f() { return float4(0, 1, 0, 1); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s22-intel-depth-hiz-levels";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> depthPS = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> colorPS = depthPS ? [dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
        if (!colorPS) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *write = [MTLDepthStencilDescriptor new], *equal = [MTLDepthStencilDescriptor new];
        write.depthCompareFunction = MTLCompareFunctionAlways;
        write.depthWriteEnabled = YES;
        equal.depthCompareFunction = MTLCompareFunctionEqual;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:16 mipmapped:YES];
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = 4;
        td.mipmapLevelCount = 3;
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        const int cases[2][2] = {{2, 0}, {0, 1}};  // level, slice
        char report[128] = "";
        int bad = 0;
        for (int c = 0; c < 2; c++) {
            int level = cases[c][0], slice = cases[c][1], w = 32 >> level, h = 16 >> level;
            id<MTLTexture> drawn = [dev newTextureWithDescriptor:td], copied = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            MTLRenderPassDescriptor *fill = [MTLRenderPassDescriptor renderPassDescriptor];
            fill.depthAttachment.texture = drawn;
            fill.depthAttachment.level = level;
            fill.depthAttachment.slice = slice;
            fill.depthAttachment.loadAction = MTLLoadActionClear;
            fill.depthAttachment.clearDepth = 0.75;
            fill.depthAttachment.storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:fill];
            [e setRenderPipelineState:depthPS];
            [e setDepthStencilState:[dev newDepthStencilStateWithDescriptor:write]];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [e endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawn sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                     toTexture:copied destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
            [b endEncoding];
            MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
            cd.usage = MTLTextureUsageRenderTarget;
            cd.storageMode = MTLStorageModeManaged;
            id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
            MTLRenderPassDescriptor *test = [MTLRenderPassDescriptor renderPassDescriptor];
            test.colorAttachments[0].texture = color;
            test.colorAttachments[0].loadAction = MTLLoadActionClear;
            test.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
            test.colorAttachments[0].storeAction = MTLStoreActionStore;
            test.depthAttachment.texture = copied;
            test.depthAttachment.level = level;
            test.depthAttachment.slice = slice;
            test.depthAttachment.loadAction = MTLLoadActionLoad;
            test.depthAttachment.storeAction = MTLStoreActionStore;
            e = [cb renderCommandEncoderWithDescriptor:test];
            [e setRenderPipelineState:colorPS];
            [e setDepthStencilState:[dev newDepthStencilStateWithDescriptor:equal]];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [e endEncoding];
            b = [cb blitCommandEncoder];
            [b synchronizeResource:color];
            [b endEncoding];
            reproRun(cb);
            uint32_t px[32 * 16];
            [color getBytes:px bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
            int green = 0;
            for (int i = 0; i < w * h; i++) green += (px[i] & 0xffffff) == 0x00ff00;
            size_t used = strlen(report);
            snprintf(report + used, sizeof report - used, "%slevel %d slice %d: %d/%d", c ? ", " : "", level, slice, green, w * h);
            bad += green != w * h;
        }
        if (bad) return FAIL(bug, "%s: depth blit-copied into a level/slice other than 0 fails depth tests (%s)", dev.name.UTF8String, report);
        return PASS(bug, "%s: depth blit-copied into other levels/slices passes depth tests (%s)", dev.name.UTF8String, report);
    }
}
