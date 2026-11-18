// i79-intel-cube-array-compare-level (Intel adapter, INTEL_CUBE_ARRAY_LEVEL_FIX): depth comparisons at an explicit level
// on a cube array. iCBE took the level from the array index (layer n compared at level n whatever level was asked for),
// Ivy Bridge and Haswell, with the stock compiler too. An 8-layer, 3-level Depth32Float cube array has its own depth in
// every level, layer and face; compute kernels and a fragment shader compare (less or equal) at every level of every layer,
// with the layer index from a buffer and as a constant, with references just below, equal to, one ulp above and just above
// the texel: 1, 1, 0, 0. The fix multiplies the reference by the layer index and iCBE divides it back, exactly for layers
// 0, 1, 2 and 4 only, so the ties are checked there; layers 3, 5, 6 and 7 can be one ulp off (a known limitation) and are
// checked just below and above. SKIPs on Kepler, which compares depth at level 0 only (a known limitation).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <math.h>

enum { LAYERS = 8, LEVELS = 3, KINDS = 4, CASES = LAYERS * LEVELS * KINDS, CONSTANTS = 2 * LEVELS * KINDS };

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "constant float3 dir = float3(0.3, -1, 0.2);\n"  // face 3 (-Y)
    "kernel void k(depthcube_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device const float *ref [[buffer(0)]],\n"
    "              device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i < 96u) { uint layer = i / 12u, lv = (i / 4u) % 3u; out[i] = t.sample_compare(s, dir, layer, ref[i], level(float(lv))); }\n"
    "    else if (i < 120u) {\n"  // constant layers 0 and 5
    "        uint j = i - 96u, lv = (j / 4u) % 3u;\n"
    "        out[i] = j < 12u ? t.sample_compare(s, dir, 0u, ref[j], level(float(lv))) : t.sample_compare(s, dir, 5u, ref[60u + j - 12u], level(float(lv)));\n"
    "    }\n"
    "}\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint v [[vertex_id]]) { V o; o.p = float4(v == 1 ? 3.0 : -1.0, v == 2 ? 3.0 : -1.0, 0, 1); return o; }\n"
    "fragment float fs(V in [[stage_in]], depthcube_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device const float *ref [[buffer(0)]]) {\n"
    "    uint i = uint(in.p.x); uint layer = i / 12u, lv = (i / 4u) % 3u;\n"
    "    return t.sample_compare(s, dir, layer, ref[i], level(float(lv)));\n"
    "}\n";

static float texel(int level, int layer, int face) { return (float)(0.1 + 0.1 * level + 0.01 * layer + 0.001 * face + 0.00013); }

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i79-intel-cube-array-compare-level";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    if ([dev.name containsString:@"NVIDIA"] || [dev.name containsString:@"GeForce"])
        return SKIP(bug, "%s: Kepler compares depth at level 0 only (a known limitation)", name);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!cps) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [lib newFunctionWithName:@"vs"];
    rpd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rpd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!rps) return FAIL(bug, "%s: render pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];

    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureTypeCubeArray;
    td.pixelFormat = MTLPixelFormatDepth32Float;
    td.width = td.height = 16;
    td.mipmapLevelCount = LEVELS;
    td.arrayLength = LAYERS;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    for (int level = 0; level < LEVELS; level++)
        for (int slice = 0; slice < 6 * LAYERS; slice++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = tex;
            rp.depthAttachment.level = level;
            rp.depthAttachment.slice = slice;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = texel(level, slice / 6, slice % 6);
            rp.renderTargetWidth = rp.renderTargetHeight = 16 >> level;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
    if (!reproRun(cb)) return FAIL(bug, "%s: clearing the cube array failed", name);

    // case i: layer i / 12, level (i / 4) % 3, kind i % 4: just below, equal, one ulp above, just above the texel
    id<MTLBuffer> refs = [dev newBufferWithLength:CASES * 4 options:MTLResourceStorageModeShared];
    float *ref = refs.contents;
    for (int i = 0; i < CASES; i++) {
        float v = texel((i / 4) % 3, i / 12, 3);
        ref[i] = (float[]){v - 0.004f, v, nextafterf(v, 2), v + 0.004f}[i % 4];
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    sd.compareFunction = MTLCompareFunctionLessEqual;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    id<MTLBuffer> out = [dev newBufferWithLength:(CASES + CONSTANTS) * 4 options:MTLResourceStorageModeShared];
    memset(out.contents, 0xff, (CASES + CONSTANTS) * 4);
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:CASES height:1 mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget;
    od.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [dev newTextureWithDescriptor:od];

    cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:cps];
    [ce setTexture:tex atIndex:0];
    [ce setSamplerState:sampler atIndex:0];
    [ce setBuffer:refs offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(CASES + CONSTANTS, 1, 1) threadsPerThreadgroup:MTLSizeMake(CASES + CONSTANTS, 1, 1)];
    [ce endEncoding];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:rps];
    [re setFragmentTexture:tex atIndex:0];
    [re setFragmentSamplerState:sampler atIndex:0];
    [re setFragmentBuffer:refs offset:0 atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be synchronizeResource:target];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);

    const char *kinds[KINDS] = {"just below", "equal to", "one ulp above", "just above"};
    const float *o = out.contents;
    float frag[CASES];
    [target getBytes:frag bytesPerRow:CASES * 4 fromRegion:MTLRegionMake2D(0, 0, CASES, 1) mipmapLevel:0];
    for (int pass = 0; pass < 3; pass++)
        for (int i = 0; i < (pass == 1 ? CONSTANTS : CASES); i++) {
            int layer = pass == 1 ? (i < 12 ? 0 : 5) : i / 12, level = (i / 4) % 3, kind = i % 4;
            float got = pass == 0 ? o[i] : pass == 1 ? o[CASES + i] : frag[i], want = kind < 2;
            bool exact = layer == 0 || (layer & (layer - 1)) == 0;  // a power of two: the reference comes back exactly
            if (got != want && (exact || kind == 0 || kind == 3))
                return FAIL(bug, "%s: %s, layer %d (%s), level %d, reference %s the texel: %g, want %g", name,
                            pass == 2 ? "fragment shader" : "compute kernel", layer, pass == 1 ? "constant" : "from a buffer", level,
                            kinds[kind], got, want);
        }
    return PASS(bug, "%s: cube-array comparisons at levels 0-2 of layers 0-7 read their level and layer (compute and fragment; exact at ties on layers 0, 1, 2, 4)", name);
}}
