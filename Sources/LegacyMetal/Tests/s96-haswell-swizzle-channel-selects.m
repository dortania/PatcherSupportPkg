// s96-haswell-swizzle-channel-selects: swizzled texture views must read swizzled wherever a shader reads them, keep up
// with writes made after they were made, and leave render targets alone; Haswell's driver has no swizzled views and item
// 93 puts the swizzle in the view's surface state. Checks the views item 90's shadow can't make: RGBA8 that shaders also
// write as RGB1 (Godot's), RGBA16Float as ABGR, sRGB RGBA8 as ABGR (RGB decoded) and mip level 1 of RG8 as GRA0 (alpha one:
// the format has none); each read in a compute kernel, a fragment shader and through an argument buffer, and -swizzle
// reports the swizzle. RGB1 is read again after a kernel and a render pass wrote the texture, whose own texels stay
// unswizzled. Ivy Bridge's hardware has no channel selects (item 90 covers its views: s93). Argument: GPU name.
#import "repro.h"

enum { Side = 4 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "constexpr sampler nearest(filter::nearest);\n"
    "kernel void computeRead(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]]) { out[0] = t.sample(nearest, float2(0.5), level(0)); }\n"
    "struct AB { texture2d<float> t [[id(0)]]; };\n"
    "kernel void argumentRead(constant AB &ab [[buffer(1)]], device float4 *out [[buffer(0)]]) { out[0] = ab.t.sample(nearest, float2(0.5), level(0)); }\n"
    "kernel void fill(texture2d<float, access::write> t [[texture(0)]], uint2 at [[thread_position_in_grid]]) { t.write(float4(10, 20, 30, 40) / 255, at); }\n"
    "struct V { float4 position [[position]]; };\n"
    "vertex V fullScreen(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); return { float4(q * 2 - 1, 0, 1) }; }\n"
    "fragment float4 fragmentRead(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.sample(nearest, float2(0.5), level(0)); }\n";

typedef enum { kComputeRead, kArgumentRead, kFragmentRead, kReadWays } ReadWay;
static const char *const kWayNames[kReadWays] = {"in a kernel", "through an argument buffer", "in a fragment shader"};

typedef struct {
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
    id<MTLLibrary> lib;
    id<MTLComputePipelineState> computeRead, argumentRead, fill;
    id<MTLRenderPipelineState> fragmentRead;
} Pipelines;

// What the view reads at its centre, in the given way; NO when the command buffer failed.
static BOOL readView(const Pipelines *p, id<MTLTexture> view, ReadWay way, float got[4]) {
    id<MTLBuffer> out = [p->dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [p->queue commandBuffer];
    if (way == kFragmentRead) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:Side height:Side mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [p->dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:p->fragmentRead];
        [re setFragmentTexture:view atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(1, 1, 0) sourceSize:MTLSizeMake(1, 1, 1)
                   toBuffer:out destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [be endEncoding];
    } else {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:way == kComputeRead ? p->computeRead : p->argumentRead];
        [ce setBuffer:out offset:0 atIndex:0];
        if (way == kComputeRead) {
            [ce setTexture:view atIndex:0];
        } else {
            id<MTLArgumentEncoder> encoder = [[p->lib newFunctionWithName:@"argumentRead"] newArgumentEncoderWithBufferIndex:1];
            id<MTLBuffer> arguments = [p->dev newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
            [encoder setArgumentBuffer:arguments offset:0];
            [encoder setTexture:view atIndex:0];
            [ce setBuffer:arguments offset:0 atIndex:1];
            [ce useResource:view usage:MTLResourceUsageRead];
        }
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
    }
    if (!reproRun(cb)) return NO;
    memcpy(got, out.contents, 16);
    return YES;
}

static BOOL near4(const float got[4], const float want[4]) {
    for (int k = 0; k < 4; k++) if (fabsf(got[k] - want[k]) > 0.01f) return NO;
    return YES;
}

static float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s96-haswell-swizzle-channel-selects";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    if (strstr(name, "HD Graphics 4000") || strstr(name, "HD Graphics 2500")) return SKIP(bug, "%s: Ivy Bridge has no channel selects", name);
    NSError *err = nil;
    Pipelines p = {dev, [dev newCommandQueue], [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err]};
    if (!p.lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    p.computeRead = [dev newComputePipelineStateWithFunction:[p.lib newFunctionWithName:@"computeRead"] error:&err];
    p.argumentRead = [dev newComputePipelineStateWithFunction:[p.lib newFunctionWithName:@"argumentRead"] error:&err];
    p.fill = [dev newComputePipelineStateWithFunction:[p.lib newFunctionWithName:@"fill"] error:&err];
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [p.lib newFunctionWithName:@"fullScreen"];
    rpd.fragmentFunction = [p.lib newFunctionWithName:@"fragmentRead"];
    rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    p.fragmentRead = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!p.computeRead || !p.argumentRead || !p.fill || !p.fragmentRead) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);

    typedef MTLTextureSwizzle S;
    const S R = MTLTextureSwizzleRed, G = MTLTextureSwizzleGreen, B = MTLTextureSwizzleBlue, A = MTLTextureSwizzleAlpha;
    const S ZERO = MTLTextureSwizzleZero, ONE = MTLTextureSwizzleOne;
    const uint16_t halfTexel[4] = {0x3a00, 0x3800, 0x3400, 0x3000};  // 0.75, 0.5, 0.25, 0.125
    const uint8_t texel[4] = {200, 100, 50, 25};
    const struct {
        const char *what;
        MTLPixelFormat format;
        int bytesPerTexel, level;
        MTLTextureUsage usage;
        MTLTextureSwizzleChannels swizzle;
        float want[4];
    } cases[] = {
        {"RGBA8 that shaders write, as RGB1", MTLPixelFormatRGBA8Unorm, 4, 0,
         MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget, {R, G, B, ONE}, {200 / 255.f, 100 / 255.f, 50 / 255.f, 1}},
        {"RGBA16Float as ABGR", MTLPixelFormatRGBA16Float, 8, 0, MTLTextureUsageShaderRead, {A, B, G, R}, {0.125f, 0.25f, 0.5f, 0.75f}},
        {"sRGB RGBA8 as ABGR", MTLPixelFormatRGBA8Unorm_sRGB, 4, 0, MTLTextureUsageShaderRead, {A, B, G, R},
         {25 / 255.f, srgbToLinear(50 / 255.f), srgbToLinear(100 / 255.f), srgbToLinear(200 / 255.f)}},  // alpha is never encoded
        {"RG8 level 1 as GRA0", MTLPixelFormatRG8Unorm, 2, 1, MTLTextureUsageShaderRead, {G, R, A, ZERO}, {100 / 255.f, 200 / 255.f, 1, 0}},
    };
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        int side = Side << cases[c].level;  // the read level is Side wide
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].format width:side height:side mipmapped:cases[c].level > 0];
        td.usage = cases[c].usage;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> base = [dev newTextureWithDescriptor:td];
        uint8_t data[Side * Side * 8];
        for (int i = 0; i < Side * Side; i++)
            memcpy(data + i * cases[c].bytesPerTexel, cases[c].format == MTLPixelFormatRGBA16Float ? (const void *)halfTexel : texel, cases[c].bytesPerTexel);
        [base replaceRegion:MTLRegionMake2D(0, 0, Side, Side) mipmapLevel:cases[c].level withBytes:data bytesPerRow:Side * cases[c].bytesPerTexel];
        id<MTLTexture> view = [base newTextureViewWithPixelFormat:cases[c].format textureType:MTLTextureType2D
                                                          levels:NSMakeRange(cases[c].level, 1) slices:NSMakeRange(0, 1) swizzle:cases[c].swizzle];
        if (!view) return FAIL(bug, "%s: %s: the swizzled view is nil", name, cases[c].what);
        MTLTextureSwizzleChannels reported = view.swizzle;
        if (memcmp(&reported, &cases[c].swizzle, sizeof reported))
            return FAIL(bug, "%s: %s: -swizzle reports %d%d%d%d", name, cases[c].what, reported.red, reported.green, reported.blue, reported.alpha);
        for (ReadWay way = 0; way < kReadWays; way++) {
            float got[4];
            if (!readView(&p, view, way, got)) return FAIL(bug, "%s: %s read %s: the command buffer failed", name, cases[c].what, kWayNames[way]);
            if (!near4(got, cases[c].want))
                return FAIL(bug, "%s: %s read %s (%.3f, %.3f, %.3f, %.3f), want (%.3f, %.3f, %.3f, %.3f)", name, cases[c].what, kWayNames[way], got[0],
                            got[1], got[2], got[3], cases[c].want[0], cases[c].want[1], cases[c].want[2], cases[c].want[3]);
        }
        if (c > 0) continue;

        // RGB1 again after a kernel wrote (10, 20, 30, 40) into the texture, in the same command buffer as the read
        id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [p.queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:p.fill];
        [ce setTexture:base atIndex:0];
        [ce dispatchThreads:MTLSizeMake(Side, Side, 1) threadsPerThreadgroup:MTLSizeMake(Side, Side, 1)];
        [ce setComputePipelineState:p.computeRead];
        [ce setTexture:view atIndex:0];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s after a kernel wrote it: the command buffer failed", name, cases[c].what);
        const float afterKernel[4] = {10 / 255.f, 20 / 255.f, 30 / 255.f, 1};
        const float *got = out.contents;
        if (!near4(got, afterKernel))
            return FAIL(bug, "%s: %s after a kernel wrote (10, 20, 30, 40) read (%.3f, %.3f, %.3f, %.3f)", name, cases[c].what, got[0], got[1], got[2], got[3]);

        // and after a render pass cleared the texture itself to (51, 102, 153, 204), whose texels stay unswizzled
        cb = [p.queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = base;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 0.8);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:base];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: the render pass failed", name, cases[c].what);
        uint8_t stored[4];
        [base getBytes:stored bytesPerRow:Side * 4 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        if (stored[0] != 51 || stored[1] != 102 || stored[2] != 153 || stored[3] != 204)
            return FAIL(bug, "%s: %s: a render pass clearing it to (51, 102, 153, 204) stored (%d, %d, %d, %d)", name, cases[c].what, stored[0], stored[1],
                        stored[2], stored[3]);
        const float afterPass[4] = {0.2f, 0.4f, 0.6f, 1};
        float read[4];
        if (!readView(&p, view, kFragmentRead, read) || !near4(read, afterPass))
            return FAIL(bug, "%s: %s after a render pass cleared it to (0.2, 0.4, 0.6, 0.8) read (%.3f, %.3f, %.3f, %.3f)", name, cases[c].what, read[0],
                        read[1], read[2], read[3]);
    }
    return PASS(bug, "%s: swizzled views read swizzled in kernels, fragment shaders and argument buffers (shader-written RGB1, half-float ABGR, "
                     "sRGB ABGR, a level as GRA0), and follow later writes, which stay unswizzled", name);
}}
