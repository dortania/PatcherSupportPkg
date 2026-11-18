// n05-kepler-gradient-compare (Kepler adapter, NVAIR_COMPARE_GRADIENT_FIX): sample_compare with gradients (gradient2d,
// gradientcube) on OCLP's Kepler compiler (GeForceAIRPlugin). Its library compares on 2D, 2D-array, cube and cube-array
// depth textures at a level or with a bias only; the gradient forms stayed bare declarations and the pipeline failed to
// build ("Unhandled constant"). Kepler compares only at level 0, so the adapter makes the comparison there, which is exact
// for shadow maps of one level.
// A one-level Depth32Float cube holds a different depth on each face (0.10, 0.25, ... 0.85); for each face, a compare
// (less) with the reference just below that depth must pass and one just above must fail: in a compute kernel through a
// sampler argument, and in a fragment function through a constexpr sampler with screen-space gradients. Then 2D (a depth
// per column, read with and without a constant texel offset), 2D-array (layer 1) and cube-array comparisons with gradients.
// The R9 M370X's compiler has no gradient comparison either (SC: "a call to an undefined label"; fragment functions fail
// too), and ANGLE doesn't use one there (deqp's textureGrad, textureGradOffset and textureProjGrad shadow cases pass in
// Chrome and Firefox), so on AMD the test SKIPs (FIXES.md, known limitations).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "constant float3 kFace[6] = {float3(1, 0.1, -0.2), float3(-1, 0.2, 0.1), float3(0.1, 1, 0.2), float3(-0.2, -1, 0.1),\n"
    "                            float3(0.2, -0.1, 1), float3(0.1, 0.2, -1)};\n"
    "kernel void k(depthcube<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i >= 6u) return;\n"
    "    float depth = 0.10 + 0.15 * float(i);\n"
    "    o[i * 2u] = t.sample_compare(s, kFace[i], depth - 0.05, gradientcube(float3(0.01), float3(0.02)));\n"
    "    o[i * 2u + 1u] = t.sample_compare(s, kFace[i], depth + 0.05, gradientcube(float3(0.01), float3(0.02)));\n"
    "}\n"
    "kernel void k2(depth2d<float> t2 [[texture(0)]], depth2d_array<float> ta [[texture(1)]], depthcube_array<float> tc [[texture(2)]],\n"
    "               sampler s [[sampler(0)]], device float *o [[buffer(0)]]) {\n"
    "    float2 c = float2(1.5 / 4.0, 0.5); gradient2d g(float2(0.01), float2(0.02));\n"
    "    o[0] = t2.sample_compare(s, c, 0.25, g); o[1] = t2.sample_compare(s, c, 0.35, g);\n"  // column 1: 0.3
    "    o[2] = t2.sample_compare(s, c, 0.45, g, int2(1, 0)); o[3] = t2.sample_compare(s, c, 0.55, g, int2(1, 0));\n"  // column 2: 0.5
    "    o[4] = ta.sample_compare(s, c, 1u, 0.65, g); o[5] = ta.sample_compare(s, c, 1u, 0.75, g);\n"  // layer 1: 0.7
    "    gradientcube gc(float3(0.01), float3(0.02));\n"
    "    o[6] = tc.sample_compare(s, float3(1, 0.1, 0.1), 0u, 0.35, gc); o[7] = tc.sample_compare(s, float3(1, 0.1, 0.1), 0u, 0.45, gc);\n"  // 0.4
    "}\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 u = float2(float((i << 1) & 2u), float(i & 2u)); o.p = float4(u * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
    "fragment float4 fs(V in [[stage_in]], depthcube<float> t [[texture(0)]]) {\n"
    "    constexpr sampler cs(compare_func::less, filter::nearest);\n"
    "    uint face = min(uint(in.p.x), 5u);\n"
    "    float3 c = kFace[face] + float3(0.001 * in.p.y);\n"
    "    float depth = 0.10 + 0.15 * float(face);\n"
    "    float below = t.sample_compare(cs, c, depth - 0.05, gradientcube(dfdx(c), dfdy(c)));\n"
    "    float above = t.sample_compare(cs, c, depth + 0.05, gradientcube(dfdx(c), dfdy(c)));\n"
    "    return float4(below, above, 0.0, 1.0);\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n05-kepler-gradient-compare";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    if ([dev.name containsString:@"AMD"])
        return SKIP(bug, "%s: AMD's compiler has no depth comparison with gradients (a known limitation; ANGLE doesn't use one)", dev.name.UTF8String);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!cps) return FAIL(bug, "%s: compute pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vs"];
    rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!rps) return FAIL(bug, "%s: render pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);

    enum { S = 4 };  // a one-level cube, one depth per face
    MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatDepth32Float size:S mipmapped:NO];
    cd.usage = MTLTextureUsageShaderRead;
    cd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> cube = [dev newTextureWithDescriptor:cd];
    id<MTLBuffer> depths = [dev newBufferWithLength:6 * S * S * 4 options:MTLResourceStorageModeShared];
    float *d = depths.contents;
    for (int face = 0; face < 6; face++)
        for (int k = 0; k < S * S; k++) d[face * S * S + k] = 0.10f + 0.15f * face;
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.compareFunction = MTLCompareFunctionLess;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    id<MTLBuffer> out = [dev newBufferWithLength:12 * 4 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:6 height:2 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];

    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int face = 0; face < 6; face++)
        [be copyFromBuffer:depths sourceOffset:face * S * S * 4 sourceBytesPerRow:S * 4 sourceBytesPerImage:S * S * 4 sourceSize:MTLSizeMake(S, S, 1)
                 toTexture:cube destinationSlice:face destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:cps];
    [ce setTexture:cube atIndex:0];
    [ce setSamplerState:sampler atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(6, 1, 1) threadsPerThreadgroup:MTLSizeMake(6, 1, 1)];
    [ce endEncoding];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, -1, -1, -1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:rps];
    [re setFragmentTexture:cube atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    be = [cb blitCommandEncoder];
    [be synchronizeResource:target];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);

    const float *o = out.contents;
    for (int face = 0; face < 6; face++)
        if (o[face * 2] != 1.0f || o[face * 2 + 1] != 0.0f)
            return FAIL(bug, "%s: compute kernel, face %d (depth %.2f): compare below %.3f (want 1), above %.3f (want 0)", dev.name.UTF8String,
                        face, 0.10 + 0.15 * face, o[face * 2], o[face * 2 + 1]);
    float px[2][6][4];
    [target getBytes:px bytesPerRow:6 * 16 fromRegion:MTLRegionMake2D(0, 0, 6, 2) mipmapLevel:0];
    for (int y = 0; y < 2; y++)
        for (int face = 0; face < 6; face++)
            if (px[y][face][0] != 1.0f || px[y][face][1] != 0.0f)
                return FAIL(bug, "%s: fragment function, face %d (depth %.2f): compare below %.3f (want 1), above %.3f (want 0)", dev.name.UTF8String,
                            face, 0.10 + 0.15 * face, px[y][face][0], px[y][face][1]);
    // 2D (a depth per column), 2D array (layer 1) and cube array, with gradients
    id<MTLComputePipelineState> k2 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k2"] error:&err];
    if (!k2) return FAIL(bug, "%s: 2D / array pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    MTLTextureDescriptor *d2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
    d2.usage = MTLTextureUsageShaderRead;
    d2.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t2 = [dev newTextureWithDescriptor:d2];
    d2.textureType = MTLTextureType2DArray;
    d2.arrayLength = 2;
    id<MTLTexture> ta = [dev newTextureWithDescriptor:d2];
    MTLTextureDescriptor *dc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatDepth32Float size:4 mipmapped:NO];
    dc.textureType = MTLTextureTypeCubeArray;
    dc.arrayLength = 1;
    dc.usage = MTLTextureUsageShaderRead;
    dc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tc = [dev newTextureWithDescriptor:dc];
    id<MTLBuffer> fill = [dev newBufferWithLength:4 * 64 options:MTLResourceStorageModeShared];
    float *fv = fill.contents;  // [0]: columns 0.1 0.3 0.5 0.7; [1]: 0.2; [2]: 0.7; [3]: 0.4
    for (int k = 0; k < 16; k++) fv[k] = 0.1f + 0.2f * (k % 4), fv[16 + k] = 0.2f, fv[32 + k] = 0.7f, fv[48 + k] = 0.4f;
    id<MTLBuffer> out2 = [dev newBufferWithLength:8 * 4 options:MTLResourceStorageModeShared];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    id<MTLSamplerState> nearest = [dev newSamplerStateWithDescriptor:sd];
    cb = [queue commandBuffer];
    be = [cb blitCommandEncoder];
    MTLSize four = MTLSizeMake(4, 4, 1);
    MTLOrigin zero = MTLOriginMake(0, 0, 0);
    [be copyFromBuffer:fill sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:four toTexture:t2 destinationSlice:0 destinationLevel:0 destinationOrigin:zero];
    [be copyFromBuffer:fill sourceOffset:64 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:four toTexture:ta destinationSlice:0 destinationLevel:0 destinationOrigin:zero];
    [be copyFromBuffer:fill sourceOffset:128 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:four toTexture:ta destinationSlice:1 destinationLevel:0 destinationOrigin:zero];
    for (int face = 0; face < 6; face++)
        [be copyFromBuffer:fill sourceOffset:192 sourceBytesPerRow:16 sourceBytesPerImage:64 sourceSize:four toTexture:tc destinationSlice:face destinationLevel:0 destinationOrigin:zero];
    [be endEncoding];
    ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:k2];
    [ce setTexture:t2 atIndex:0];
    [ce setTexture:ta atIndex:1];
    [ce setTexture:tc atIndex:2];
    [ce setSamplerState:nearest atIndex:0];
    [ce setBuffer:out2 offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: 2D / array command buffer failed", dev.name.UTF8String);
    static const char *const kWhat[4] = {"2D", "2D with a texel offset", "2D array (layer 1)", "cube array"};
    const float *o2 = out2.contents;
    for (int k = 0; k < 4; k++)
        if (o2[k * 2] != 1.0f || o2[k * 2 + 1] != 0.0f)
            return FAIL(bug, "%s: %s comparison with gradients: below %.3f (want 1), above %.3f (want 0)", dev.name.UTF8String, kWhat[k], o2[k * 2], o2[k * 2 + 1]);
    return PASS(bug, "%s: sample_compare with gradients compares right on one-level depth cubes (all six faces, compute kernel and "
                "fragment function), 2D (with and without a texel offset), 2D arrays and cube arrays", dev.name.UTF8String);
}}
