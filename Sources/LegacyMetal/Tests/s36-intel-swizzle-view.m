// s36-intel-swizzle-view (MetalOldCompat item 32): the 12.x Intel driver returns nil from
// newTextureViewWithPixelFormat:textureType:levels:slices:swizzle: (family 1 has no texture swizzle). Dawn (Chrome's
// WebGPU), told the iGPU is family 2 (item 11), makes its depth/stencil views with the swizzle (R, 0, 0, 1), so every
// stencil8 render pass and every depth texture bound to a shader lost the device. Makes views with swizzles that change
// nothing a shader can see (R001 on Depth32Float_Stencil8 as X32_Stencil8 and on Depth32Float, R001 on R8Unorm, the
// identity on RGBA8Unorm) and reads the Depth32Float view in a compute function. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s36-intel-swizzle-view";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        MTLTextureSwizzleChannels r001 = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleOne);
        static const struct { MTLPixelFormat format, view; BOOL identity; const char *name; } kViews[] = {
            {MTLPixelFormatDepth32Float_Stencil8, MTLPixelFormatX32_Stencil8, NO, "X32_Stencil8 view of Depth32Float_Stencil8, R001"},
            {MTLPixelFormatDepth32Float, MTLPixelFormatDepth32Float, NO, "Depth32Float, R001"},
            {MTLPixelFormatR8Unorm, MTLPixelFormatR8Unorm, NO, "R8Unorm, R001"},
            {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm, YES, "RGBA8Unorm, identity"},
        };
        id<MTLTexture> depthView = nil, depth = nil;
        for (size_t i = 0; i < sizeof kViews / sizeof *kViews; i++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kViews[i].format width:4 height:4 mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView | (i < 2 ? MTLTextureUsageRenderTarget : 0);
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            MTLTextureSwizzleChannels s = kViews[i].identity ? MTLTextureSwizzleChannelsDefault : r001;
            id<MTLTexture> view = [t newTextureViewWithPixelFormat:kViews[i].view textureType:MTLTextureType2D levels:NSMakeRange(0, 1)
                                                            slices:NSMakeRange(0, 1) swizzle:s];
            if (!view) return FAIL(bug, "%s: %s: no view (nil)", dev.name.UTF8String, kViews[i].name);
            if (kViews[i].format == MTLPixelFormatDepth32Float) depth = t, depthView = view;
        }
        // the Depth32Float view reads what was copied in
        id<MTLLibrary> lib = [dev newLibraryWithSource:[@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(depth2d<float> t [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = t.read(uint2(2, 1)); }\n"
            stringByAppendingString:reproUniqueComment()] options:nil error:nil];
        id<MTLComputePipelineState> cs = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:nil];
        float depths[16];
        for (int i = 0; i < 16; i++) depths[i] = i / 16.0f;
        id<MTLBuffer> src = [dev newBufferWithBytes:depths length:sizeof depths options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:MTLSizeMake(4, 4, 1) toTexture:depth
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:cs];
        [enc setTexture:depthView atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float got = *(float *)out.contents;
        if (got != depths[6]) return FAIL(bug, "%s: the Depth32Float R001 view read %g at (2, 1), want %g", dev.name.UTF8String, got, depths[6]);
        return PASS(bug, "%s: swizzled views that change nothing a shader sees are made (depth, stencil, R8, identity)", dev.name.UTF8String);
    }
}
