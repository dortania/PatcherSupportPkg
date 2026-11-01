// s25-amd-srgb-resolve (AMDBronzeCompat item 4): an MSAA resolve of an sRGB attachment with the 12.5 AMD driver. The
// driver averages the encoded bytes instead of the linear values, so antialiased edges are too dark (WebGPU conformance:
// render_pass,resolve:render_pass_resolve). Half of 4 samples white over black: the correct result is linear 0.5 = sRGB
// byte 188; averaging the bytes gives 128. A linear format stays 128, and alpha is 128 either way.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

// Returns the resolved red byte, or -1 if a pass failed; alpha goes to *alpha.
static int resolved(id<MTLDevice> d, MTLPixelFormat format, MTLStoreAction store, NSUInteger level, NSUInteger slice, int *alpha) {
    NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
        "struct F { float4 color [[color(0)]]; uint mask [[sample_mask]]; };\n"
        "fragment F f() { return { float4(1), 3 }; }\n" stringByAppendingString:reproUniqueComment()];
    NSError *error = nil;
    id<MTLLibrary> library = [d newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"v"];
    pd.fragmentFunction = [library newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = format;
    pd.rasterSampleCount = 4;
    id<MTLRenderPipelineState> pipeline = library ? [d newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
    if (!pipeline) return -1;

    NSUInteger w = 16 >> level;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray; td.pixelFormat = format; td.width = td.height = 16;
    td.arrayLength = 2; td.mipmapLevelCount = 2; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [d newTextureWithDescriptor:td];
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:w mipmapped:NO];
    md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4;
    md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;  // as WebGPU attachments are created

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [d newTextureWithDescriptor:md];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = store;
    rp.colorAttachments[0].resolveTexture = target;
    rp.colorAttachments[0].resolveLevel = level;
    rp.colorAttachments[0].resolveSlice = slice;
    id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pipeline];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:target];
    [b endEncoding];
    if (!reproRun(cb)) return -1;
    uint8_t px[16 * 16 * 4];
    [target getBytes:px bytesPerRow:w * 4 bytesPerImage:w * w * 4 fromRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:level slice:slice];
    uint8_t *p = px + ((w / 2) * w + w / 2) * 4;
    *alpha = p[3];
    return p[0];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s25-amd-srgb-resolve";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        struct { const char *what; MTLPixelFormat format; MTLStoreAction store; NSUInteger level, slice; int want; } cases[] = {
            {"RGBA8Unorm_sRGB resolve", MTLPixelFormatRGBA8Unorm_sRGB, MTLStoreActionMultisampleResolve, 0, 0, 188},
            {"RGBA8Unorm_sRGB store and resolve", MTLPixelFormatRGBA8Unorm_sRGB, MTLStoreActionStoreAndMultisampleResolve, 0, 0, 188},
            {"BGRA8Unorm_sRGB resolve", MTLPixelFormatBGRA8Unorm_sRGB, MTLStoreActionMultisampleResolve, 0, 0, 188},
            {"RGBA8Unorm_sRGB resolve into level 1 slice 1", MTLPixelFormatRGBA8Unorm_sRGB, MTLStoreActionMultisampleResolve, 1, 1, 188},
            {"RGBA8Unorm resolve", MTLPixelFormatRGBA8Unorm, MTLStoreActionMultisampleResolve, 0, 0, 128},
        };
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            int alpha = 0, red = resolved(dev, cases[i].format, cases[i].store, cases[i].level, cases[i].slice, &alpha);
            if (red < 0) return FAIL(bug, "%s: %s: the pass failed", dev.name.UTF8String, cases[i].what);
            if (abs(red - cases[i].want) > 3 || abs(alpha - 128) > 3)
                return FAIL(bug, "%s: %s: half white over black = %d (alpha %d), want %d (alpha 128); 128 = encoded bytes averaged",
                            dev.name.UTF8String, cases[i].what, red, alpha, cases[i].want);
        }
        return PASS(bug, "%s: sRGB MSAA resolves average linear values, linear formats unchanged", dev.name.UTF8String);
    }
}
