// n27-kepler-cube-gradient-level: cube samples with gradients in vertex and fragment functions must pick OpenGL's
// level; Kepler's was wrong for gradients along the major axis. Fix: GeForceAIRCompat NVAIR_CUBE_GRADIENT_FIX. Checks:
// levels 0-4 at k - 0.25, k and k + 0.25, in both stages. Argument: GPU name (default: NVIDIA).
#import "repro.h"
#include <math.h>

enum { COLS = 15, SHAPES = 5 };
static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "constexpr sampler sm(filter::nearest, mip_filter::nearest);\n"
    "struct G { float4 p; float4 dx[5]; float4 dy[5]; float4 scale[15]; };\n"
    "struct VO { float4 p [[position]]; int v [[flat]]; float size [[point_size]]; };\n"
    "vertex VO vc(uint i [[vertex_id]], uint s [[instance_id]], texturecube<int> t [[texture(0)]], constant G &g [[buffer(0)]]) {\n"
    "    VO o; o.p = float4((float(i) + 0.5) / 15.0 * 2.0 - 1.0, 1.0 - (float(s) + 0.5) / 5.0 * 2.0, 0, 1); o.size = 1;\n"
    "    float k = g.scale[i].x;\n"
    "    o.v = t.sample(sm, g.p.xyz, gradientcube(g.dx[s].xyz * k, g.dy[s].xyz * k)).x; return o; }\n"
    "fragment int pass(VO in [[stage_in]]) { return in.v; }\n"
    "struct FO { float4 p [[position]]; };\n"
    "vertex FO full(uint i [[vertex_id]]) { float2 c[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; FO o; o.p = float4(c[i], 0, 1); return o; }\n"
    "fragment int fc(FO in [[stage_in]], texturecube<int> t [[texture(0)]], constant G &g [[buffer(0)]]) {\n"
    "    uint i = uint(in.p.x), s = uint(in.p.y); float k = g.scale[i].x;\n"
    "    return t.sample(sm, g.p.xyz, gradientcube(g.dx[s].xyz * k, g.dy[s].xyz * k)).x; }\n";

typedef struct { float p[4]; float dx[SHAPES][4]; float dy[SHAPES][4]; float scale[COLS][4]; } G;

// OpenGL's level for cube gradients dx, dy at direction p, face size 32: on the major axis' face coordinates
static double cubeLevel(const float *p, const float *dx, const float *dy) {
    int m = fabsf(p[0]) >= fabsf(p[1]) && fabsf(p[0]) >= fabsf(p[2]) ? 0 : fabsf(p[1]) >= fabsf(p[2]) ? 1 : 2;
    int u = m == 0 ? 1 : 0, v = m == 2 ? 1 : 2;
    double ma = fabs(p[m]), sign = p[m] < 0 ? -1 : 1, r[2];
    const float *d[2] = {dx, dy};
    for (int j = 0; j < 2; j++) {
        double dma = sign * d[j][m];
        double du = (d[j][u] * ma - p[u] * dma) / (2 * ma * ma), dv = (d[j][v] * ma - p[v] * dma) / (2 * ma * ma);
        r[j] = (du * du + dv * dv) * 32.0 * 32.0;
    }
    return 0.5 * log2(fmax(r[0], r[1]));
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n27-kepler-cube-gradient-level";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    const char *shapes[SHAPES] = {"dPdx along the major axis", "dPdy along the major axis", "dPdx diagonal (1, 1, 1)", "dPdx (1, 0, 1)",
                                  "dPdx within the face"};
    float raw[SHAPES][2][3] = {{{1, 0, 0}, {0, 0, 0}}, {{0, 0, 0}, {1, 0, 0}}, {{1, 1, 1}, {0, 0, 0}}, {{1, 0, 1}, {0, 0, 0}}, {{0, 1, 0}, {0, 0, 0}}};
    G g = {{1.0f, 0.3f, 0.2f, 0}};
    for (int s = 0; s < SHAPES; s++) {  // unit gradients: exact level 0, so scale 2^lambda gives level lambda
        float dx[3], dy[3];
        for (int k = 0; k < 3; k++) dx[k] = raw[s][0][k], dy[k] = raw[s][1][k];
        float f = (float)exp2(-cubeLevel(g.p, dx, dy));
        for (int k = 0; k < 3; k++) g.dx[s][k] = dx[k] * f, g.dy[s][k] = dy[k] * f;
    }
    for (int c = 0; c < COLS; c++) g.scale[c][0] = (float)exp2(c / 3 + (c % 3 - 1) * 0.25);  // level c/3 - 0.25, c/3, c/3 + 0.25
    MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatR32Sint size:32 mipmapped:YES];
    id<MTLTexture> cube = [dev newTextureWithDescriptor:td];
    for (NSUInteger level = 0; level < cube.mipmapLevelCount; level++) {
        NSUInteger w = MAX(32u >> level, 1u);
        int32_t *data = malloc(w * w * 4);
        for (NSUInteger i = 0; i < w * w; i++) data[i] = (int32_t)level;
        for (NSUInteger face = 0; face < 6; face++)
            [cube replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:level slice:face withBytes:data bytesPerRow:w * 4 bytesPerImage:w * w * 4];
        free(data);
    }
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    for (int stage = 0; stage < 2; stage++) {
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Sint;
        rd.vertexFunction = [lib newFunctionWithName:stage ? @"full" : @"vc"];
        rd.fragmentFunction = [lib newFunctionWithName:stage ? @"fc" : @"pass"];
        if (!stage) rd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Sint width:COLS height:SHAPES mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget;
        od.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:od];
        id<MTLBuffer> pixels = [dev newBufferWithLength:COLS * SHAPES * 4 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:ps];
        [re setVertexBytes:&g length:sizeof g atIndex:0];
        [re setFragmentBytes:&g length:sizeof g atIndex:0];
        [re setVertexTexture:cube atIndex:0];
        [re setFragmentTexture:cube atIndex:0];
        if (stage) [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        else [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:COLS instanceCount:SHAPES];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(COLS, SHAPES, 1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:COLS * 4 destinationBytesPerImage:COLS * SHAPES * 4];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const int32_t *got = pixels.contents;
        for (int s = 0; s < SHAPES; s++)
            for (int c = 0; c < COLS; c++)
                if (got[s * COLS + c] != c / 3)
                    return FAIL(bug, "%s: %s function, %s, exact level %.2f: sampled level %d, want %d", name, stage ? "fragment" : "vertex",
                                shapes[s], c / 3 + (c % 3 - 1) * 0.25, got[s * COLS + c], c / 3);
    }
    return PASS(bug, "%s: cube samples with gradients pick OpenGL's level in vertex and fragment functions", name);
}}
