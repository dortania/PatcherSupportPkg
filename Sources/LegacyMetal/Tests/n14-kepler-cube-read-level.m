// n14-kepler-cube-read-level: read() of a cube or cube array at a level above 0 must read that level; Kepler read level
// 0. Fix: GeForceAIRCompat NVAIR_CUBE_READ_LEVEL. Checks: every texel of 3 levels of an R32Uint cube, an R32Uint cube
// array and a Depth32Float cube array. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct P { uint width, face, layer, level, at; };\n"
    "kernel void cubeUint(texturecube<uint> t [[texture(0)]], device uint *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < p.width && g.y < p.width) o[p.at + g.y * p.width + g.x] = t.read(g, p.face, p.level).x; }\n"
    "kernel void cubeArrayUint(texturecube_array<uint> t [[texture(0)]], device uint *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < p.width && g.y < p.width) o[p.at + g.y * p.width + g.x] = t.read(g, p.face, p.layer, p.level).x; }\n"
    "kernel void cubeArrayDepth(depthcube_array<float> t [[texture(0)]], device uint *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < p.width && g.y < p.width) o[p.at + g.y * p.width + g.x] = as_type<uint>(t.read(g, p.face, p.layer, p.level)); }\n";

enum { W = 16, LEVELS = 3 };
// each texel's own value: unique, and for depth exact in a float
static uint32_t texelValue(BOOL depth, int level, int slice, uint32_t x, uint32_t y) {
    uint32_t n = ((uint32_t)level << 12 | (uint32_t)slice << 8 | y << 4 | x) + 1;
    if (!depth) return n;
    float f = (float)n / 65536.0f;
    uint32_t bits;
    memcpy(&bits, &f, 4);
    return bits;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n14-kepler-cube-read-level";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { MTLTextureType type; MTLPixelFormat format; int layers; const char *what, *kernel; } kinds[] = {
        {MTLTextureTypeCube, MTLPixelFormatR32Uint, 1, "R32Uint cube", "cubeUint"},
        {MTLTextureTypeCubeArray, MTLPixelFormatR32Uint, 2, "R32Uint cube array", "cubeArrayUint"},
        {MTLTextureTypeCubeArray, MTLPixelFormatDepth32Float, 2, "Depth32Float cube array", "cubeArrayDepth"}};
    for (int k = 0; k < 3; k++) {
        BOOL depth = kinds[k].format == MTLPixelFormatDepth32Float;
        int slices = 6 * kinds[k].layers;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = kinds[k].type;
        td.pixelFormat = kinds[k].format;
        td.width = td.height = W;
        td.mipmapLevelCount = LEVELS;
        if (kinds[k].type == MTLTextureTypeCubeArray) td.arrayLength = kinds[k].layers;
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        if (!tex) return FAIL(bug, "%s: %s: no texture", name, kinds[k].what);
        NSUInteger total = 0;
        for (int level = 0; level < LEVELS; level++) total += (NSUInteger)(W >> level) * (W >> level) * slices;
        id<MTLBuffer> in = [dev newBufferWithLength:total * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:total * 4 options:MTLResourceStorageModeShared];
        memset(out.contents, 0xab, total * 4);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        NSUInteger at = 0;
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                uint32_t w = W >> level, *v = (uint32_t *)in.contents + at;
                for (uint32_t y = 0; y < w; y++)
                    for (uint32_t x = 0; x < w; x++) v[y * w + x] = texelValue(depth, level, slice, x, y);
                [be copyFromBuffer:in sourceOffset:at * 4 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * w * 4 sourceSize:MTLSizeMake(w, w, 1)
                         toTexture:tex destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
                at += w * w;
            }
        [be endEncoding];
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kinds[k].kernel)] error:&err];
        if (!ps) return FAIL(bug, "%s: %s: pipeline: %s", name, kinds[k].what, err.localizedDescription.UTF8String);
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setTexture:tex atIndex:0];
        [ce setBuffer:out offset:0 atIndex:0];
        at = 0;
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                uint32_t w = W >> level, p[5] = {w, (uint32_t)(slice % 6), (uint32_t)(slice / 6), (uint32_t)level, (uint32_t)at};
                [ce setBytes:p length:sizeof p atIndex:1];
                [ce dispatchThreadgroups:MTLSizeMake((w + 7) / 8, (w + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                at += w * w;
            }
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, kinds[k].what);
        at = 0;
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                uint32_t w = W >> level;
                const uint32_t *got = (const uint32_t *)out.contents + at, *want = (const uint32_t *)in.contents + at;
                for (uint32_t i = 0; i < w * w; i++)
                    if (got[i] != want[i]) {
                        // which texel it read, if it is one of the texture's
                        int fl = -1, fs = -1; uint32_t fx = 0, fy = 0;
                        for (int l2 = 0; l2 < LEVELS && fl < 0; l2++)
                            for (int s2 = 0; s2 < slices && fl < 0; s2++)
                                for (uint32_t y2 = 0; y2 < (uint32_t)(W >> l2) && fl < 0; y2++)
                                    for (uint32_t x2 = 0; x2 < (uint32_t)(W >> l2); x2++)
                                        if (texelValue(depth, l2, s2, x2, y2) == got[i]) { fl = l2, fs = s2, fx = x2, fy = y2; break; }
                        char seen[96] = "no texel's value";
                        if (fl >= 0) snprintf(seen, sizeof seen, "level %d face %d layer %d texel (%u, %u)'s value", fl, fs % 6, fs / 6, fx, fy);
                        return FAIL(bug, "%s: %s: level %d face %d layer %d texel (%u, %u) read %s", name, kinds[k].what, level, slice % 6,
                                    slice / 6, i % w, i / w, seen);
                    }
                at += w * w;
            }
    }
    return PASS(bug, "%s: every texel of every level, face and layer of an R32Uint cube, an R32Uint cube array and a Depth32Float cube array reads back right", name);
}}
