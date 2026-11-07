// s40-intel-msaa-stencil8-read (MetalOldCompat item 36): shaders must read a 4x multisampled Stencil8 texture's stencil.
// On the 12.x Intel driver render passes write it right, but the sampler addresses only part of the surface: past the
// largest power of two below the width, most rows read the left half again. ANGLE reads a GL_STENCIL_INDEX8
// multisampled renderbuffer that way to resolve or blit it (dEQP fbomultisample stencil_index8). Fills a 256x128 texture
// with 1 + column / 16 in 16-column bands (stencil replace, pipeline declaring Stencil8) and reads every texel of
// sample 2 through a Stencil8 view in a compute kernel.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 band(uint id [[vertex_id]], constant float2 &x [[buffer(0)]]) {\n"
    "    return float4(id & 1 ? x.y : x.x, id & 2 ? 1.0 : -1.0, 0.5, 1);\n"
    "}\n"
    "fragment void noColor() {}\n"
    "kernel void readStencil(texture2d_ms<uint> s [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width() && g.y < s.get_height()) o[g.y * s.get_width() + g.x] = s.read(g, 2).x;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s40-intel-msaa-stencil8-read";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        const int W = 256, H = 128;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"band"];
        pd.fragmentFunction = [lib newFunctionWithName:@"noColor"];
        pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
        pd.rasterSampleCount = 4;
        id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!draw) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readStencil"] error:&err];
        if (!read) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.frontFaceStencil.stencilCompareFunction = MTLCompareFunctionAlways;
        dd.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        dd.backFaceStencil = dd.frontFaceStencil;
        id<MTLDepthStencilState> replace = [dev newDepthStencilStateWithDescriptor:dd];

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W height:H mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = 4;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> stencil = [dev newTextureWithDescriptor:td];
        id<MTLTexture> view = [stencil newTextureViewWithPixelFormat:MTLPixelFormatStencil8];
        if (!stencil || !view) return FAIL(bug, "%s: no texture or view", name);

        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.stencilAttachment.texture = stencil;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.clearStencil = 0;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:draw];
        [re setDepthStencilState:replace];
        for (int b = 0; b < W / 16; b++) {
            float x[2] = {(float)(b * 16) / W * 2 - 1, (float)(b * 16 + 16) / W * 2 - 1};
            [re setVertexBytes:x length:sizeof x atIndex:0];
            [re setStencilReferenceValue:1 + b];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [re endEncoding];
        id<MTLBuffer> out = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:read];
        [ce setTexture:view atIndex:0];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);

        const uint32_t *o = out.contents;
        int wrong = 0, first = -1;
        for (int i = 0; i < W * H; i++)
            if (o[i] != (uint32_t)(1 + (i % W) / 16)) wrong += (first < 0 ? (first = i, 1) : 1);
        if (wrong)
            return FAIL(bug, "%s: %d of %d stencil texels read wrong (first at %d,%d: %u, want %d)", name, wrong, W * H,
                        first % W, first / W, o[first], 1 + (first % W) / 16);
        return PASS(bug, "%s: every texel of a 4x multisampled Stencil8 texture reads back through a stencil view", name);
    }
}
