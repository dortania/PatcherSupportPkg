// s91-kepler-swizzled-views: texture views with a component swizzle must read swizzled on Kepler; the driver has no
// such method and item 54 gave nil, so MoltenVK's swizzled image views (Godot's L8 / LA8 textures, its font glyphs
// among them) read as zero (Godot drew no text). Fix: MetalOldCompat item 88 (Intel: item 90). Checks: R8 as L8 (RRR1),
// RG8 as LA8 (RRRG), RGBA8 reversed (ABGR), RGBA8Uint with an integer one (RGB1) and a 2D-array slice as L8, sampled
// (read for the integer one) bound directly and through an argument buffer; -swizzle reports the swizzle; the R9 runs it
// too. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void direct(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *out [[buffer(0)]]) { out[0] = t.sample(s, float2(0.5), level(0)); }\n"
    "kernel void directu(texture2d<uint> t [[texture(0)]], device float4 *out [[buffer(0)]]) { out[0] = float4(t.read(uint2(0))); }\n"
    "kernel void directa(texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *out [[buffer(0)]]) { out[0] = t.sample(s, float2(0.5), 0, level(0)); }\n"
    "struct AB { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
    "kernel void viaab(constant AB &ab [[buffer(1)]], device float4 *out [[buffer(0)]]) { out[0] = ab.t.sample(ab.s, float2(0.5), level(0)); }\n"
    "struct ABU { texture2d<uint> t [[id(0)]]; };\n"
    "kernel void viaabu(constant ABU &ab [[buffer(1)]], device float4 *out [[buffer(0)]]) { out[0] = float4(ab.t.read(uint2(0))); }\n"
    "struct ABA { texture2d_array<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
    "kernel void viaaba(constant ABA &ab [[buffer(1)]], device float4 *out [[buffer(0)]]) { out[0] = ab.t.sample(ab.s, float2(0.5), 0, level(0)); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s91-kepler-swizzled-views";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    typedef MTLTextureSwizzle S;
    const S R = MTLTextureSwizzleRed, G = MTLTextureSwizzleGreen, B = MTLTextureSwizzleBlue, A = MTLTextureSwizzleAlpha, ONE = MTLTextureSwizzleOne;
    // texel (200, 100, 50, 25) in each format's channels; want: what the swizzled view reads (unorm / 255, or uint)
    const struct { const char *what; MTLPixelFormat fmt; int bpp; BOOL integer, array; MTLTextureSwizzleChannels sw; float want[4]; } cases[] = {
        {"R8 as L8 (RRR1)", MTLPixelFormatR8Unorm, 1, NO, NO, {R, R, R, ONE}, {200, 200, 200, 255}},
        {"RG8 as LA8 (RRRG)", MTLPixelFormatRG8Unorm, 2, NO, NO, {R, R, R, G}, {200, 200, 200, 100}},
        {"RGBA8 as ABGR", MTLPixelFormatRGBA8Unorm, 4, NO, NO, {A, B, G, R}, {25, 50, 100, 200}},
        {"RGBA8Uint as RGB1", MTLPixelFormatRGBA8Uint, 4, YES, NO, {R, G, B, ONE}, {200, 100, 50, 1}},
        {"R8 array slice 1 as L8", MTLPixelFormatR8Unorm, 1, NO, YES, {R, R, R, ONE}, {200, 200, 200, 255}},
    };
    const uint8_t texel[4] = {200, 100, 50, 25};
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].fmt width:4 height:4 mipmapped:NO];
        if (cases[c].array) { td.textureType = MTLTextureType2DArray; td.arrayLength = 3; }
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> base = [dev newTextureWithDescriptor:td];
        uint8_t data[64];
        for (NSUInteger slice = 0; slice < (cases[c].array ? 3 : 1); slice++) {  // an array's slice 1 holds the texel, the others zero
            memset(data, 0, sizeof data);
            if (!cases[c].array || slice == 1)
                for (int i = 0; i < 16; i++) memcpy(data + i * cases[c].bpp, texel, cases[c].bpp);
            [base replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:slice withBytes:data bytesPerRow:4 * cases[c].bpp bytesPerImage:0];
        }
        id<MTLTexture> view = [base newTextureViewWithPixelFormat:cases[c].fmt textureType:cases[c].array ? MTLTextureType2DArray : MTLTextureType2D
                                                          levels:NSMakeRange(0, 1) slices:NSMakeRange(cases[c].array ? 1 : 0, 1) swizzle:cases[c].sw];
        if (!view) return FAIL(bug, "%s: %s: the swizzled view is nil", name, cases[c].what);
        MTLTextureSwizzleChannels got = view.swizzle;
        if (memcmp(&got, &cases[c].sw, sizeof got))
            return FAIL(bug, "%s: %s: -swizzle reports %d%d%d%d", name, cases[c].what, got.red, got.green, got.blue, got.alpha);
        for (int way = 0; way < 2; way++) {
            NSString *fn = cases[c].integer ? (way ? @"viaabu" : @"directu") : cases[c].array ? (way ? @"viaaba" : @"directa") : (way ? @"viaab" : @"direct");
            id<MTLFunction> f = [lib newFunctionWithName:fn];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline %s: %s", name, fn.UTF8String, err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            id<MTLBuffer> ab = nil;
            if (way == 0) {
                [ce setTexture:view atIndex:0];
                if (!cases[c].integer) [ce setSamplerState:sampler atIndex:0];
            } else {
                id<MTLArgumentEncoder> enc = [f newArgumentEncoderWithBufferIndex:1];
                ab = [dev newBufferWithLength:enc.encodedLength options:MTLResourceStorageModeShared];
                [enc setArgumentBuffer:ab offset:0];
                [enc setTexture:view atIndex:0];
                if (!cases[c].integer) [enc setSamplerState:sampler atIndex:1];
                [ce setBuffer:ab offset:0 atIndex:1];
                [ce useResource:view usage:MTLResourceUsageRead];
            }
            [ce setBuffer:out offset:0 atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s %s: command buffer failed: %s", name, cases[c].what, way ? "through an argument buffer" : "bound directly",
                                           cb.error.localizedDescription.UTF8String ?: "");
            const float *o = out.contents;
            for (int k = 0; k < 4; k++) {
                float want = cases[c].integer ? cases[c].want[k] : cases[c].want[k] / 255.0f;
                if (fabsf(o[k] - want) > 0.01f)
                    return FAIL(bug, "%s: %s %s read (%.3f, %.3f, %.3f, %.3f), want (%.3f, %.3f, %.3f, %.3f)", name, cases[c].what,
                                way ? "through an argument buffer" : "bound directly", o[0], o[1], o[2], o[3],
                                cases[c].integer ? cases[c].want[0] : cases[c].want[0] / 255, cases[c].integer ? cases[c].want[1] : cases[c].want[1] / 255,
                                cases[c].integer ? cases[c].want[2] : cases[c].want[2] / 255, cases[c].integer ? cases[c].want[3] : cases[c].want[3] / 255);
            }
        }
    }
    return PASS(bug, "%s: swizzled views read swizzled (L8, LA8, ABGR, integer RGB1, an array slice), bound directly and in argument buffers", name);
}}
