// n11-kepler-depth-channels (MetalOldCompat item 62 + Kepler adapter NVAIR_DEPTH_CHANNELS): Kepler's sampler returns a
// depth texture's depth in all four channels, (d, d, d, d), and a stencil view's value as (s, s, s, s), through
// texture2d<float> / <uint>, where OpenGL ES wants (d, 0, 0, 1) / (s, 0, 0, 1) and ANGLE (no swizzled views on this GPU)
// passes the driver's through: WebGL's depth texture tests failed (Khronos WebGL 2.0.1 depth texture formats,
// fboinvalidate unbind_read_*). A fragment function shaped like ANGLE's (an ANGLE_angleUniforms argument at buffer 17)
// samples a Depth32Float texture (cleared to 0.25), an RGBA8 texture and the X32_Stencil8 view of a Depth32Float_Stencil8
// texture (stencil 7) through texture2d, into three render targets.
// GPUs of family 2 have swizzled views, and ANGLE reads depth and stencil through one that gives (x, 0, 0, 1); what
// such a read gives without one is undefined in Metal (an R9 M370X gives (d, d, d, d), an M3 Pro (d, d, d, 1)), so the
// test SKIPs there.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct ANGLEUniformBlock { float2 depthRange; uint misc; };\n"
    "struct VO { float4 p [[position]]; };\n"
    "struct FO { float4 depth [[color(0)]]; float4 color [[color(1)]]; uint4 stencil [[color(2)]]; };\n"
    "vertex VO vs(uint vid [[vertex_id]], constant ANGLEUniformBlock &ANGLE_angleUniforms [[buffer(17)]]) {\n"
    "    float2 c[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VO o; o.p = float4(c[vid], 0, 1); return o; }\n"
    "fragment FO fs(VO in [[stage_in]], constant ANGLEUniformBlock &ANGLE_angleUniforms [[buffer(17)]],\n"
    "               texture2d<float> d [[texture(0)]], texture2d<float> c [[texture(1)]], texture2d<uint> s [[texture(2)]],\n"
    "               sampler smp [[sampler(0)]]) {\n"
    "    FO o; o.depth = d.sample(smp, float2(0.5)); o.color = c.sample(smp, float2(0.5)); o.stencil = s.read(uint2(1, 1));\n"
    "    return o; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n11-kepler-depth-channels";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    if ([dev supportsFamily:MTLGPUFamilyMac2])
        return SKIP(bug, "%s: family 2, where ANGLE reads depth and stencil through swizzled views (the other channels are undefined without one)", name);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA32Float;
    pd.colorAttachments[2].pixelFormat = MTLPixelFormatRGBA32Uint;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // the textures: depth 0.25, stencil 7 (through render passes), RGBA8 (64, 128, 191, 255)
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    td.usage |= MTLTextureUsagePixelFormatView;
    id<MTLTexture> depthStencil = [dev newTextureWithDescriptor:td];
    id<MTLTexture> stencil = [depthStencil newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    if (!stencil) return FAIL(bug, "%s: no X32_Stencil8 view", name);
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
    uint8_t texels[16 * 4];
    for (int i = 0; i < 16; i++) texels[i * 4] = 64, texels[i * 4 + 1] = 128, texels[i * 4 + 2] = 191, texels[i * 4 + 3] = 255;
    [color replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
    clear.depthAttachment.texture = depth;
    clear.depthAttachment.loadAction = MTLLoadActionClear;
    clear.depthAttachment.clearDepth = 0.25;
    clear.depthAttachment.storeAction = MTLStoreActionStore;
    [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
    clear.depthAttachment.texture = depthStencil;
    clear.stencilAttachment.texture = depthStencil;
    clear.stencilAttachment.loadAction = MTLLoadActionClear;
    clear.stencilAttachment.clearStencil = 7;
    clear.stencilAttachment.storeAction = MTLStoreActionStore;
    [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
    // the draw, into three 1x1 targets
    id<MTLTexture> targets[3];
    MTLPixelFormat formats[3] = {MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA32Uint};
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < 3; i++) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:1 height:1 mipmapped:NO];
        t.usage = MTLTextureUsageRenderTarget;
        t.storageMode = MTLStorageModeManaged;
        targets[i] = [dev newTextureWithDescriptor:t];
        rp.colorAttachments[i].texture = targets[i];
        rp.colorAttachments[i].loadAction = MTLLoadActionClear;
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    float uniforms[4] = {0, 1, 0, 0};
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re setVertexBytes:uniforms length:sizeof uniforms atIndex:17];
    [re setFragmentBytes:uniforms length:sizeof uniforms atIndex:17];
    [re setFragmentTexture:depth atIndex:0];
    [re setFragmentTexture:color atIndex:1];
    [re setFragmentTexture:stencil atIndex:2];
    [re setFragmentSamplerState:[dev newSamplerStateWithDescriptor:sd] atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int i = 0; i < 3; i++) [be synchronizeResource:targets[i]];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    float dv[4], cv[4];
    uint32_t sv[4];
    [targets[0] getBytes:dv bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    [targets[1] getBytes:cv bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    [targets[2] getBytes:sv bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    if (fabsf(cv[0] - 64 / 255.f) > 0.01f || fabsf(cv[1] - 128 / 255.f) > 0.01f || fabsf(cv[2] - 191 / 255.f) > 0.01f || cv[3] != 1)
        return FAIL(bug, "%s: the RGBA8 texture sampled (%g, %g, %g, %g)", name, cv[0], cv[1], cv[2], cv[3]);
    if (fabsf(dv[0] - 0.25f) > 1e-6f || dv[1] != 0 || dv[2] != 0 || dv[3] != 1)
        return FAIL(bug, "%s: the Depth32Float texture sampled (%g, %g, %g, %g), want (0.25, 0, 0, 1)", name, dv[0], dv[1], dv[2], dv[3]);
    if (sv[0] != 7 || sv[1] != 0 || sv[2] != 0 || sv[3] != 1)
        return FAIL(bug, "%s: the stencil view read (%u, %u, %u, %u), want (7, 0, 0, 1)", name, sv[0], sv[1], sv[2], sv[3]);
    return PASS(bug, "%s: depth and stencil sampled through texture2d in an ANGLE-style function give (x, 0, 0, 1)", name);
}}
