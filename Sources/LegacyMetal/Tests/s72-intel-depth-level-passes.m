// s72-intel-depth-level-passes (MetalOldCompat item 68): render passes at levels 1+ of mipmapped depth arrays and cubes on
// Ivy Bridge. After a pass with a depth attachment at level 1 or higher of such a texture (even an empty one that loads and
// stores), fragment functions sampling level 0 read parts of some slices wrong, while compute read() sees the right texels.
// Four textures, each filled and then sampled at every level and slice by a fragment function (one 64x64 R32Float target
// per subresource, nearest mip filter, explicit level): a 57x13 Depth32Float 2D array with 7 slices and 6 levels, a 32x32
// Depth16Unorm cube and a 2-cube Depth32Float cube array with 6 levels each, filled by one render pass per level and slice
// (a draw writing 0.1 + 0.1 level + 0.01 slice); and the same 2D array filled the way WebKit's ANGLE does, one blit encoder
// per level and slice, level by level, all in one command buffer (dEQP texstorage3d.format.depth_component32f_2d_array).
// Then one more 2D array whose level 0 is filled by blits gets a single empty pass at level 1. Without the fix: level 0
// slice 3 of the arrays and face 1 of the cubes read wrong in places.
// Stock OCLP on an HD 4000: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <math.h>

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V full(uint v [[vertex_id]]) { V o; o.p = float4(v == 1 ? 3.0 : -1.0, v == 2 ? 3.0 : -1.0, 0.5, 1); return o; }\n"
    "struct D { float d [[depth(any)]]; };\n"
    "fragment D put(V in [[stage_in]], constant float &v [[buffer(0)]]) { D o; o.d = v; return o; }\n"
    "static float3 dir(float2 xy, uint f) {\n"
    "    float2 q = xy / 32.0 - 1.0;\n"
    "    return f == 0 ? float3(1, -q.y, -q.x) : f == 1 ? float3(-1, -q.y, q.x) : f == 2 ? float3(q.x, 1, q.y) :\n"
    "           f == 3 ? float3(q.x, -1, -q.y) : f == 4 ? float3(q.x, -q.y, 1) : float3(-q.x, -q.y, -1);\n"
    "}\n"
    "fragment float sampleArray(V in [[stage_in]], depth2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint2 &p [[buffer(0)]]) {\n"
    "    return t.sample(s, in.p.xy / 64.0, p.x, level(float(p.y)));\n"
    "}\n"
    "fragment float sampleCube(V in [[stage_in]], depthcube<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint2 &p [[buffer(0)]]) {\n"
    "    return t.sample(s, dir(in.p.xy, p.x), level(float(p.y)));\n"
    "}\n"
    "fragment float sampleCubeArray(V in [[stage_in]], depthcube_array<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint2 &p [[buffer(0)]]) {\n"
    "    return t.sample(s, dir(in.p.xy, p.x % 6u), p.x / 6u, level(float(p.y)));\n"
    "}\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;
static id<MTLDepthStencilState> writeAlways;

static float value(NSUInteger level, NSUInteger slice) { return 0.1f + 0.1f * level + 0.01f * slice; }
static NSUInteger slicesOf(id<MTLTexture> t) { return t.textureType == MTLTextureTypeCube ? 6 : t.textureType == MTLTextureTypeCubeArray ? 6 * t.arrayLength : t.arrayLength; }

static id<MTLTexture> depthTexture(MTLTextureType type, MTLPixelFormat format, NSUInteger width, NSUInteger height, NSUInteger layers) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = format;
    td.width = width;
    td.height = height;
    td.arrayLength = layers;
    td.mipmapLevelCount = 6;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    return [dev newTextureWithDescriptor:td];
}

static void depthPass(id<MTLCommandBuffer> cb, id<MTLTexture> t, NSUInteger level, NSUInteger slice, BOOL draw) {
    static NSMutableDictionary *pipelines;
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    id<MTLRenderPipelineState> pipeline = pipelines[@(t.pixelFormat)];
    if (!pipeline) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"full"];
        d.fragmentFunction = [lib newFunctionWithName:@"put"];
        d.depthAttachmentPixelFormat = t.pixelFormat;
        pipelines[@(t.pixelFormat)] = pipeline = [dev newRenderPipelineStateWithDescriptor:d error:nil];
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t;
    rp.depthAttachment.level = level;
    rp.depthAttachment.slice = slice;
    rp.depthAttachment.loadAction = MTLLoadActionLoad;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    if (draw) {
        float v = value(level, slice);
        [re setRenderPipelineState:pipeline];
        [re setDepthStencilState:writeAlways];
        [re setFragmentBytes:&v length:sizeof v atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [re endEncoding];
}

static void fillByPasses(id<MTLTexture> t) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    for (NSUInteger level = 0; level < t.mipmapLevelCount; level++)
        for (NSUInteger slice = 0; slice < slicesOf(t); slice++) depthPass(cb, t, level, slice, YES);
    reproRun(cb);
}

static void fillByBlits(id<MTLTexture> t, NSUInteger levels) {  // ANGLE's upload: one blit encoder per level and slice
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    NSUInteger bpp = t.pixelFormat == MTLPixelFormatDepth16Unorm ? 2 : 4;
    for (NSUInteger level = 0; level < levels; level++) {
        NSUInteger w = MAX(t.width >> level, 1), h = MAX(t.height >> level, 1);
        for (NSUInteger slice = 0; slice < slicesOf(t); slice++) {
            id<MTLBuffer> b = [dev newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
            for (NSUInteger i = 0; i < w * h; i++) ((float *)b.contents)[i] = value(level, slice);
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp sourceSize:MTLSizeMake(w, h, 1)
                     toTexture:t destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];
        }
    }
    reproRun(cb);
}

// Samples every slice of levels 0..levels-1 in a fragment function; returns a description of the first wrong one, or nil
static NSString *check(id<MTLTexture> t, NSUInteger levels) {
    NSString *fn = t.textureType == MTLTextureTypeCube ? @"sampleCube" : t.textureType == MTLTextureTypeCubeArray ? @"sampleCubeArray" : @"sampleArray";
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"full"];
    d.fragmentFunction = [lib newFunctionWithName:fn];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:d error:nil];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.mipFilter = MTLSamplerMipFilterNearest;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:64 height:64 mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget;
    od.storageMode = MTLStorageModeManaged;
    for (NSUInteger level = 0; level < levels; level++)
        for (NSUInteger slice = 0; slice < slicesOf(t); slice++) {
            id<MTLTexture> target = [dev newTextureWithDescriptor:od];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            uint32_t p[2] = {(uint32_t)slice, (uint32_t)level};
            [re setRenderPipelineState:pipeline];
            [re setFragmentTexture:t atIndex:0];
            [re setFragmentSamplerState:sampler atIndex:0];
            [re setFragmentBytes:p length:sizeof p atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:target];
            [be endEncoding];
            if (!reproRun(cb)) return @"a command buffer failed";
            static float out[64 * 64];
            [target getBytes:out bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            float want = value(level, slice);
            if (t.pixelFormat == MTLPixelFormatDepth16Unorm) want = roundf(want * 65535) / 65535;
            int wrong = 0, first = -1;
            for (int i = 0; i < 64 * 64; i++)
                if (fabsf(out[i] - want) > 2e-5f) wrong++, first = first < 0 ? i : first;
            if (wrong)
                return [NSString stringWithFormat:@"level %lu %@ %lu: %d of 4096 samples wrong (%g, want %g)", (unsigned long)level,
                        t.textureType == MTLTextureType2DArray ? @"slice" : @"face", (unsigned long)slice, wrong, out[first], want];
        }
    return nil;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s72-intel-depth-level-passes";
    dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    queue = [dev newCommandQueue];
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionAlways;
    dsd.depthWriteEnabled = YES;
    writeAlways = [dev newDepthStencilStateWithDescriptor:dsd];

    struct { const char *what; id<MTLTexture> t; BOOL blits; } cases[] = {
        {"Depth32Float 2D array filled by render passes", depthTexture(MTLTextureType2DArray, MTLPixelFormatDepth32Float, 57, 13, 7), NO},
        {"Depth16Unorm cube filled by render passes", depthTexture(MTLTextureTypeCube, MTLPixelFormatDepth16Unorm, 32, 32, 1), NO},
        {"Depth32Float cube array filled by render passes", depthTexture(MTLTextureTypeCubeArray, MTLPixelFormatDepth32Float, 32, 32, 2), NO},
        {"Depth32Float 2D array filled by blits (as ANGLE)", depthTexture(MTLTextureType2DArray, MTLPixelFormatDepth32Float, 57, 13, 7), YES},
    };
    for (int c = 0; c < 4; c++) {
        if (!cases[c].t) return FAIL(bug, "%s: no %s", name, cases[c].what);
        if (cases[c].blits) fillByBlits(cases[c].t, 6); else fillByPasses(cases[c].t);
        NSString *problem = check(cases[c].t, 6);
        if (problem) return FAIL(bug, "%s: %s: %s", name, cases[c].what, problem.UTF8String);
    }
    // level 0 by blits, then one empty pass at level 1: level 0 must still sample right
    id<MTLTexture> t = depthTexture(MTLTextureType2DArray, MTLPixelFormatDepth32Float, 57, 13, 7);
    fillByBlits(t, 1);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    depthPass(cb, t, 1, 0, NO);
    reproRun(cb);
    NSString *problem = check(t, 1);
    if (problem) return FAIL(bug, "%s: after an empty pass at level 1 of a Depth32Float 2D array: %s", name, problem.UTF8String);
    return PASS(bug, "%s: depth 2D arrays, cubes and cube arrays sample right at every level and slice after passes at levels 1-5", name);
}}
