// n10-kepler-discard-demote: a discarded fragment must stay a helper for its quad's derivatives (Metal 2.3, WGSL);
// Kepler ended the lane and later derivatives were 0. Fix: GeForceAIRCompat NVAIR_DEMOTE_DISCARD. Checks: dfdx and dfdy
// after a discard; discarded pixels neither store, count nor write color. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VO { float4 p [[position]]; };\n"
    "vertex VO vs(uint vid [[vertex_id]]) {\n"
    "    float2 c[6] = {float2(-1, -1), float2(-1, 1), float2(1, -1), float2(-1, 1), float2(1, 1), float2(1, -1)};\n"
    "    VO o; o.p = float4(c[vid], 0, 1); return o; }\n"
    "fragment float4 fs(VO in [[stage_in]], device float2 *out [[buffer(0)]], device atomic_uint *count [[buffer(1)]]) {\n"
    "    int2 l = int2(in.p.xy) & 1;\n"
    "    if (((l.x | l.y) & 1) == 0) discard_fragment();\n"
    "    float v = l.x == 0 ? (l.y == 0 ? 4.0 : 7.0) : (l.y == 0 ? 1.0 : 4.0);\n"
    "    uint i = uint(in.p.y) * 16 + uint(in.p.x);\n"
    "    out[i] = float2(dfdx(v), dfdy(v));\n"
    "    atomic_fetch_add_explicit(count, 1, memory_order_relaxed);\n"
    "    return float4(1.0); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n10-kepler-discard-demote";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> out = [dev newBufferWithLength:256 * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> count = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    float *o = out.contents;
    for (int i = 0; i < 512; i++) o[i] = 99;
    *(uint32_t *)count.contents = 0;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re setFragmentBuffer:out offset:0 atIndex:0];
    [re setFragmentBuffer:count offset:0 atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [re endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be synchronizeResource:target];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    uint8_t px[16 * 16 * 4];
    [target getBytes:px bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
    for (int y = 0; y < 16; y++)
        for (int x = 0; x < 16; x++) {
            const float *p = o + (y * 16 + x) * 2;
            bool discarded = ((x | y) & 1) == 0;
            uint8_t alpha = px[(y * 16 + x) * 4 + 3];
            if (discarded && (p[0] != 99 || p[1] != 99))
                return FAIL(bug, "%s: discarded pixel (%d,%d) stored (%g, %g)", name, x, y, p[0], p[1]);
            if (discarded && alpha) return FAIL(bug, "%s: discarded pixel (%d,%d) was written", name, x, y);
            if (!discarded && (p[0] != -3 || p[1] != 3))
                return FAIL(bug, "%s: pixel (%d,%d) after a discard in its quad: dfdx %g, dfdy %g, want -3, 3", name, x, y, p[0], p[1]);
            if (!discarded && alpha != 255) return FAIL(bug, "%s: pixel (%d,%d) not written", name, x, y);
        }
    uint32_t counted = *(uint32_t *)count.contents;
    if (counted != 192) return FAIL(bug, "%s: %u fragments counted themselves, want the 192 not discarded", name, counted);
    return PASS(bug, "%s: derivatives after a discard come from the helper; discarded pixels store, count and write nothing", name);
}}
