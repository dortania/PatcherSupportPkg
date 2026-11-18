// i78-intel-gradient-compare-level (Intel adapter, INTEL_COMPARE_GRADIENT_FIX): depth comparisons with gradients on
// mipmapped depth textures. The Intel compilers failed on sample_compare with gradient2d / gradientcube (n05); the adapter
// makes such a comparison in the level form, at the level the gradients select (nearest mip filter). Each level of a 2D
// (64x64, 4 levels), a 2D-array (layer 1) and a cube (32x32, 3 levels) Depth32Float texture is cleared to its own depth
// (0.2, 0.4, 0.6, 0.8); for each level k, gradients of 2^k texels (cube: of the face coordinates) must select level k: a
// comparison (less) with a reference just below that level's depth passes and one just above fails. Level 0 for every
// gradient, as on Kepler, passes only k = 0.
// Stock OCLP: FAIL (the compiler fails). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(depth2d<float> t2 [[texture(0)]], depth2d_array<float> ta [[texture(1)]], depthcube<float> tc [[texture(2)]],\n"
    "              sampler s [[sampler(0)]], device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    uint level = i / 2; float below = (i & 1) ? 0.05 : -0.05;\n"
    "    float ref = 0.2 * float(level + 1) + below;\n"
    "    float g = float(1u << level) / 64.0, gc = float(2u << level) / 32.0;\n"
    "    out[i] = t2.sample_compare(s, float2(0.5), ref, gradient2d(float2(g, 0), float2(0, g)));\n"
    "    out[8 + i] = ta.sample_compare(s, float2(0.5), 1, ref, gradient2d(float2(g, 0), float2(0, g)));\n"
    "    out[16 + i] = level < 3 ? tc.sample_compare(s, float3(0, 0, 1), ref, gradientcube(float3(gc, 0, 0), float3(0, gc, 0))) : 2.0;\n"
    "}\n";

static id<MTLTexture> depthTexture(id<MTLDevice> dev, MTLTextureType type, NSUInteger size, NSUInteger levels, NSUInteger slices) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = type;
    d.pixelFormat = MTLPixelFormatDepth32Float;
    d.width = d.height = size;
    d.mipmapLevelCount = levels;
    if (type == MTLTextureType2DArray) d.arrayLength = slices;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:d];
}

static void clearLevels(id<MTLCommandQueue> queue, id<MTLTexture> t, NSUInteger levels, NSUInteger slices) {
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    for (NSUInteger level = 0; level < levels; level++)
        for (NSUInteger slice = 0; slice < slices; slice++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = t;
            rp.depthAttachment.level = level;
            rp.depthAttachment.slice = slice;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = 0.2 * (double)(level + 1);
            rp.renderTargetWidth = t.width >> level;
            rp.renderTargetHeight = t.height >> level;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
    [cb commit];
    [cb waitUntilCompleted];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i78-intel-gradient-compare-level";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLTexture> t2 = depthTexture(dev, MTLTextureType2D, 64, 4, 1), ta = depthTexture(dev, MTLTextureType2DArray, 64, 4, 2),
                   tc = depthTexture(dev, MTLTextureTypeCube, 32, 3, 6);
    clearLevels(queue, t2, 4, 1);
    clearLevels(queue, ta, 4, 2);
    clearLevels(queue, tc, 3, 6);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    sd.compareFunction = MTLCompareFunctionLess;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    id<MTLBuffer> out = [dev newBufferWithLength:24 * sizeof(float) options:MTLResourceStorageModeShared];
    memset(out.contents, 0xff, 24 * sizeof(float));
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:t2 atIndex:0];
    [ce setTexture:ta atIndex:1];
    [ce setTexture:tc atIndex:2];
    [ce setSamplerState:sampler atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(8, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const float *o = out.contents;
    static const char *const kKind[3] = {"2D", "2D array", "cube"};
    for (int kind = 0; kind < 3; kind++)
        for (int i = 0; i < 8; i++) {
            int level = i / 2;
            if (kind == 2 && level >= 3) continue;
            float want = (i & 1) ? 0.0f : 1.0f;  // ref below the level's depth: less passes (1); above: fails (0)
            if (o[8 * kind + i] != want)
                return FAIL(bug, "%s: %s comparison with gradients selecting level %d, reference %s its depth: %g, want %g", name, kKind[kind],
                            level, (i & 1) ? "above" : "below", o[8 * kind + i], want);
        }
    return PASS(bug, "%s: comparisons with gradients select their level on 2D, 2D-array and cube depth textures (levels 0-3)", name);
}}
