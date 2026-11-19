// n16-kepler-masked-draw-occlusion (MetalOldCompat item 66): an occlusion query over a draw whose color attachments all
// have writeMask none, with no depth or stencil attachment. Kepler's driver (GeForceMTLDriver) counted no samples for
// such a draw at all, so a visible draw read as hidden (WebGPU CTS occlusionQuery basic, reuse and scissor with
// writeMask 0); an R32Uint attachment, or any depth attachment, still counted. A full-target triangle into RGBA8Unorm
// (1 and 4 samples) and RGBA16Float, counting mode: 256 samples (x4 for MSAA); the attachment must keep its clear color.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vs(uint i [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[i], 0.5, 1); }\n"
    "fragment float4 fs() { return float4(0.9, 0.1, 0.8, 0.3); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n16-kepler-masked-draw-occlusion";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { MTLPixelFormat format; NSUInteger samples; const char *what; } kinds[] = {
        {MTLPixelFormatRGBA8Unorm, 1, "RGBA8Unorm"}, {MTLPixelFormatRGBA8Unorm, 4, "RGBA8Unorm 4x MSAA"}, {MTLPixelFormatRGBA16Float, 1, "RGBA16Float"}};
    for (int k = 0; k < 3; k++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = kinds[k].format;
        pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
        pd.rasterSampleCount = kinds[k].samples;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: %s: pipeline: %s", name, kinds[k].what, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kinds[k].format width:16 height:16 mipmapped:NO];
        td.textureType = kinds[k].samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
        td.sampleCount = kinds[k].samples;
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kinds[k].format width:16 height:16 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> resolved = kinds[k].samples > 1 ? [dev newTextureWithDescriptor:rd] : target;
        id<MTLBuffer> visibility = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
        memset(visibility.contents, 0xab, 8);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
        if (kinds[k].samples > 1) {
            rp.colorAttachments[0].resolveTexture = resolved;
            rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        } else {
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        rp.visibilityResultBuffer = visibility;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
        [re endEncoding];
        NSUInteger bpp = kinds[k].format == MTLPixelFormatRGBA16Float ? 8 : 4;
        id<MTLBuffer> pixels = [dev newBufferWithLength:16 * 16 * bpp options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:resolved sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1) toBuffer:pixels
          destinationOffset:0 destinationBytesPerRow:16 * bpp destinationBytesPerImage:16 * 16 * bpp];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, kinds[k].what);
        uint64_t samples = *(uint64_t *)visibility.contents, want = 256 * kinds[k].samples;
        if (samples != want)
            return FAIL(bug, "%s: %s: an occlusion query over a draw with writeMask none counted %llu samples, want %llu", name, kinds[k].what,
                        (unsigned long long)samples, (unsigned long long)want);
        for (int i = 0; i < 256; i++) {
            float c[4];
            if (bpp == 4) {
                const uint8_t *p = (const uint8_t *)pixels.contents + i * 4;
                for (int j = 0; j < 4; j++) c[j] = p[j] / 255.0f;
            } else {
                const __fp16 *p = (const __fp16 *)pixels.contents + i * 4;
                for (int j = 0; j < 4; j++) c[j] = p[j];
            }
            const float clear[4] = {0.25f, 0.5f, 0.75f, 1.0f};
            for (int j = 0; j < 4; j++)
                if (fabsf(c[j] - clear[j]) > 0.003f)
                    return FAIL(bug, "%s: %s: the draw with writeMask none changed pixel %d to (%.3f, %.3f, %.3f, %.3f), want the clear color", name,
                                kinds[k].what, i, c[0], c[1], c[2], c[3]);
        }
    }
    return PASS(bug, "%s: occlusion queries count draws with writeMask none (1 and 4 samples, RGBA8Unorm and RGBA16Float), and the target keeps its contents", name);
}}
