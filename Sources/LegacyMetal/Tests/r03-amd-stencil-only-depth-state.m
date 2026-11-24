// r03-amd-stencil-only-depth-state: guards AMDBronzeCompat item 12; must keep working: a stencil-only
// Depth32Float_Stencil8 attachment ignores the depth state. Fix: AMDBronzeCompat AMD_BRONZE_STENCIL_DEPTH_STATE.
// Checks: stencil and depth after draws with depth compare Less and Always; SKIP on other drivers. Argument: GPU name.
#import "repro.h"
#import <objc/runtime.h>

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 leftHalf(uint id [[vertex_id]]) { return float4(id & 1 ? 0.0 : -1.0, id & 2 ? 1.0 : -1.0, 0.5, 1); }\n"
    "fragment void nothing() {}\n"
    "kernel void readStencil(texture2d<uint> s [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width() && g.y < s.get_height()) o[g.y * s.get_width() + g.x] = s.read(g).x;\n"
    "}\n";

enum { W = 32, H = 16 };

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "r03-amd-stencil-only-depth-state";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        if (strcmp(object_getClassName(dev), "BronzeMtlDevice"))
            return SKIP(bug, "%s: not the AMD Bronze driver (item 12 is AMDBronzeCompat's)", name);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", name, err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"leftHalf"];
        pd.fragmentFunction = [lib newFunctionWithName:@"nothing"];
        pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pipeline) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readStencil"] error:&err];
        if (!read) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        const MTLCompareFunction compares[2] = {MTLCompareFunctionLess, MTLCompareFunctionAlways};
        const char *names[2] = {"Less", "Always"};
        for (int c = 0; c < 2; c++) {
            MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
            dsd.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
            dsd.backFaceStencil = dsd.frontFaceStencil;
            dsd.depthCompareFunction = compares[c];
            dsd.depthWriteEnabled = YES;
            id<MTLDepthStencilState> state = [dev newDepthStencilStateWithDescriptor:dsd];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                          width:W height:H mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            id<MTLTexture> ds = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
            clear.depthAttachment.texture = ds;
            clear.depthAttachment.loadAction = MTLLoadActionClear;
            clear.depthAttachment.clearDepth = 0.25;
            clear.depthAttachment.storeAction = MTLStoreActionStore;
            clear.stencilAttachment.texture = ds;
            clear.stencilAttachment.loadAction = MTLLoadActionClear;
            clear.stencilAttachment.storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.stencilAttachment.texture = ds;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:pipeline];
            [re setDepthStencilState:state];
            [re setStencilReferenceValue:3];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [re endEncoding];
            id<MTLBuffer> stencilOut = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:read];
            [ce setTexture:[ds newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8] atIndex:0];
            [ce setBuffer:stencilOut offset:0 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding];
            id<MTLBuffer> depthOut = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:ds sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                       toBuffer:depthOut destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4
                        options:MTLBlitOptionDepthFromDepthStencil];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            const uint32_t *stencil = stencilOut.contents;
            const float *depth = depthOut.contents;
            int stencilWrong = 0, depthChanged = 0;
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    if (x != W / 2 && stencil[y * W + x] != (x < W / 2 ? 3u : 0u)) stencilWrong++;
                    if (depth[y * W + x] != 0.25f) depthChanged++;
                }
            if (stencilWrong || depthChanged)
                return FAIL(bug, "%s: stencil-only pass with depth compare %s and depth writes: stencil wrong in %d of %d texels "
                            "(left %u, want 3), depth changed in %d (left %g, want 0.25)",
                            name, names[c], stencilWrong, W * H, stencil[0], depthChanged, depth[0]);
        }
        return PASS(bug, "%s: a Depth32Float_Stencil8 texture attached as stencil only keeps its depth untested and unwritten", name);
    }
}
