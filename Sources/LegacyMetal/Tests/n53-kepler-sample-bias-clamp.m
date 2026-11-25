// n53-kepler-sample-bias-clamp: sample()'s bias must be clamped to [-16, 15.99], as WGSL and Metal specify; Kepler's
// sampler applied a bias of 20 or 25 in full. Fix: GeForceAIRCompat NVAIR_BIAS_CLAMP. Checks: 2D and 2D-array samples at
// implicit LOD -17 with bias 15.99, 20, 25 and a constant 25, and at LOD +19 with bias -25. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "struct Case { float scale; float bias; };\n"
    "vertex V v(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 f(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d_array<float> a [[texture(1)]],\n"
    "                  sampler s [[sampler(0)]], constant Case &c [[buffer(0)]]) {\n"
    "  float2 uv = float2(0.25) + in.p.xy * c.scale;\n"
    "  return float4(t.sample(s, uv, bias(c.bias)).r, a.sample(s, uv, 1, bias(c.bias)).r, t.sample(s, uv, bias(25.0)).r, 1); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n53-kepler-sample-bias-clamp";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"v"];
    rd.fragmentFunction = [lib newFunctionWithName:@"f"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);

    // 8x8, four levels holding 0.1 / 0.3 / 0.6 / 0.9; the array's layer 1 the same
    const uint8_t levelValue[4] = {26, 77, 153, 230};
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:8 height:8 mipmapped:YES];
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> plain = [dev newTextureWithDescriptor:td];
    td.textureType = MTLTextureType2DArray;
    td.arrayLength = 2;
    id<MTLTexture> array = [dev newTextureWithDescriptor:td];
    for (NSUInteger level = 0; level < 4; level++) {
        NSUInteger n = 8 >> level;
        uint8_t texels[64];
        memset(texels, levelValue[level], sizeof texels);
        [plain replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:level withBytes:texels bytesPerRow:n];
        for (NSUInteger slice = 0; slice < 2; slice++)
            [array replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:level slice:slice withBytes:texels bytesPerRow:n bytesPerImage:0];
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterNearest;
    sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *rt = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    rt.usage = MTLTextureUsageRenderTarget;
    rt.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [dev newTextureWithDescriptor:rt];
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    // uv changes by `scale` per pixel: 1e-6 is an implicit LOD of about -17, 1e5 about +19 (8 texels)
    const struct { float scale, bias; int wantLevel; } cases[] = {{1e-6f, 15.99f, 0}, {1e-6f, 20.0f, 0}, {1e-6f, 25.0f, 0}, {1e5f, -25.0f, 3}};
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:ps];
        [re setFragmentTexture:plain atIndex:0];
        [re setFragmentTexture:array atIndex:1];
        [re setFragmentSamplerState:sampler atIndex:0];
        float c[2] = {cases[i].scale, cases[i].bias};
        [re setFragmentBytes:c length:sizeof c atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:target];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        uint8_t px[4];
        [target getBytes:px bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(8, 8, 1, 1) mipmapLevel:0];
        const char *what[3] = {"2D sample", "2D-array sample", "2D sample with constant bias 25"};
        for (int k = 0; k < 3; k++) {
            int want = k == 2 ? (cases[i].scale < 1 ? 0 : 3) : cases[i].wantLevel;
            int got = px[k] < 50 ? 0 : px[k] < 115 ? 1 : px[k] < 190 ? 2 : 3;
            if (got != want)
                return FAIL(bug, "%s: %s with bias %.2f at implicit LOD %s read level %d, want %d", name, what[k], k == 2 ? 25.0 : cases[i].bias,
                            cases[i].scale < 1 ? "-17" : "+19", got, want);
        }
    }
    return PASS(bug, "%s: sample() biases are clamped to [-16, 15.99] (2D, 2D array, constant bias)", name);
}}
