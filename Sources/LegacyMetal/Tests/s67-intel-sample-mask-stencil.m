// s67-intel-sample-mask-stencil (shim item 51): on the Ivy Bridge driver, a fragment function that writes
// [[sample_mask]] writes no stencil when the render pass has no depth attachment. ANGLE's fragment functions write the
// sample mask whenever they render multisampled, and a multisampled GL_STENCIL_INDEX8 renderbuffer is a stencil-only
// attachment, so dEQP fbomultisample stencil_index8 resolved stencil 0 everywhere (Chrome, Safari, Firefox). Draws the
// left half at depth 0.5 with stencil replace 3 and a sample-mask fragment function into (1) a 4x Stencil8 texture with
// a 4x color target, and (2) a single-sample Depth32Float_Stencil8 texture attached as stencil only, its depth plane at
// 0.25; reads the stencil back in a compute kernel and the depth plane with a blit, which must stay 0.25. (3), on Ivy
// Bridge only, repeats (2) with a Less depth compare and depth writes on: the fix attaches the texture as depth too, and
// must keep the depth state from applying to it (an M3 Pro passes those fragments and leaves the depth plane alone;
// Haswell's stock driver rejects most of them, so (3) doesn't run there).
// Stock OCLP on an HD 4000: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 leftHalf(uint id [[vertex_id]]) { return float4(id & 1 ? 0.0 : -1.0, id & 2 ? 1.0 : -1.0, 0.5, 1); }\n"
    "struct Out { float4 c [[color(0)]]; uint mask [[sample_mask]]; };\n"
    "fragment Out masked() { Out o; o.c = float4(1, 0, 0, 1); o.mask = 0xffffffffu; return o; }\n"
    "struct MaskOnly { uint mask [[sample_mask]]; };\n"
    "fragment MaskOnly maskOnly() { MaskOnly o; o.mask = 0xffffffffu; return o; }\n"
    "kernel void readMS(texture2d_ms<uint> s [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width() && g.y < s.get_height()) o[g.y * s.get_width() + g.x] = s.read(g, 0).x;\n"
    "}\n"
    "kernel void read1(texture2d<uint> s [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width() && g.y < s.get_height()) o[g.y * s.get_width() + g.x] = s.read(g).x;\n"
    "}\n";

enum { W = 119, H = 131 };

// Texels whose stencil isn't 3 on the left half and 0 on the right (the middle column is skipped).
static int wrongTexels(const uint32_t *v, uint32_t *left, uint32_t *right) {
    int wrong = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            if (x != W / 2 && v[y * W + x] != (x < W / 2 ? 3u : 0u)) wrong++;
    *left = v[0];
    *right = v[W - 1];
    return wrong;
}

typedef struct { int wrong, depthWrong; uint32_t left, right; float depth0; } Result;

// Cases 2 and 3: a Depth32Float_Stencil8 texture attached as stencil only, depth plane cleared to 0.25.
static BOOL stencilOnly(id<MTLDevice> dev, id<MTLCommandQueue> queue, id<MTLLibrary> lib, id<MTLRenderPipelineState> pipeline,
                        id<MTLDepthStencilState> state, Result *r) {
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:W height:H mipmapped:NO];
    dd.storageMode = MTLStorageModePrivate;
    dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> ds = [dev newTextureWithDescriptor:dd];
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
    NSError *err = nil;
    id<MTLBuffer> out = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read1"] error:&err]];
    [ce setTexture:[ds newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8] atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce endEncoding];
    id<MTLBuffer> depth = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:ds sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
               toBuffer:depth destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4
                options:MTLBlitOptionDepthFromDepthStencil];
    [be endEncoding];
    if (!reproRun(cb)) return NO;
    r->wrong = wrongTexels(out.contents, &r->left, &r->right);
    const float *d = depth.contents;
    r->depthWrong = 0;
    for (int i = 0; i < W * H; i++) if (d[i] != 0.25f) r->depthWrong++;
    r->depth0 = d[0];
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s67-intel-sample-mask-stencil";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", name, err.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        dsd.backFaceStencil = dsd.frontFaceStencil;
        id<MTLDepthStencilState> replace = [dev newDepthStencilStateWithDescriptor:dsd];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> replaceDepthLess = [dev newDepthStencilStateWithDescriptor:dsd];

        // 1. 4x Stencil8 with a 4x color target
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W height:H mipmapped:NO];
        sd.textureType = MTLTextureType2DMultisample;
        sd.sampleCount = 4;
        sd.storageMode = MTLStorageModePrivate;
        sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> stencil = [dev newTextureWithDescriptor:sd];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        cd.textureType = MTLTextureType2DMultisample;
        cd.sampleCount = 4;
        cd.storageMode = MTLStorageModePrivate;
        cd.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"leftHalf"];
        pd.fragmentFunction = [lib newFunctionWithName:@"masked"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        pd.stencilAttachmentPixelFormat = stencil.pixelFormat;
        pd.rasterSampleCount = 4;
        id<MTLRenderPipelineState> msPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!msPipeline) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = color;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.stencilAttachment.texture = stencil;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:msPipeline];
        [re setDepthStencilState:replace];
        [re setStencilReferenceValue:3];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding];
        id<MTLTexture> msView = [stencil newTextureViewWithPixelFormat:stencil.pixelFormat == MTLPixelFormatStencil8 ? MTLPixelFormatStencil8
                                                                                                                  : MTLPixelFormatX32_Stencil8];
        id<MTLBuffer> msOut = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readMS"] error:&err]];
        [ce setTexture:msView atIndex:0];
        [ce setBuffer:msOut offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        uint32_t l1, r1;
        int wrong1 = wrongTexels(msOut.contents, &l1, &r1);

        // 2. Depth32Float_Stencil8 as stencil only, plain replace state; 3. the same with Less and depth writes (Ivy Bridge)
        pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"leftHalf"];
        pd.fragmentFunction = [lib newFunctionWithName:@"maskOnly"];
        pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        id<MTLRenderPipelineState> dsPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!dsPipeline) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        Result r2 = {0}, r3 = {0};
        if (!stencilOnly(dev, queue, lib, dsPipeline, replace, &r2)) return FAIL(bug, "%s: command buffer failed", name);
        BOOL ivyBridge = [dev.name containsString:@"HD Graphics 4000"];
        if (ivyBridge && !stencilOnly(dev, queue, lib, dsPipeline, replaceDepthLess, &r3)) return FAIL(bug, "%s: command buffer failed", name);
        if (wrong1 || r2.wrong || r2.depthWrong || r3.wrong || r3.depthWrong)
            return FAIL(bug, "%s: stencil drawn with a sample mask and no depth attachment: 4x Stencil8 %d of %d texels wrong (left %u right %u, "
                        "want 3 0); Depth32Float_Stencil8 %d wrong (left %u right %u), depth changed in %d (first %g, want 0.25); "
                        "with a Less depth state and depth writes %d wrong, depth changed in %d (first %g)%s",
                        name, wrong1, W * H, l1, r1, r2.wrong, r2.left, r2.right, r2.depthWrong, r2.depth0, r3.wrong, r3.depthWrong,
                        r3.depth0, ivyBridge ? "" : " (not run: Ivy Bridge only)");
        return PASS(bug, "%s: stencil drawn with a sample mask lands without a depth attachment, and the depth plane is left alone%s", name,
                    ivyBridge ? ", also with a Less depth state and depth writes" : "");
    }
}
