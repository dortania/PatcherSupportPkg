// n08-kepler-visibility-sum (MetalOldCompat item 59): visibility results with more than one draw counted into a slot.
// Kepler's driver (GeForceMTLDriver) writes each draw's own sample count to the slot, replacing what it held, so the
// slot ends up with the LAST draw's count, not the sum over the draws that Metal specifies. WebGL occlusion queries in
// Chrome reported visible targets invisible (Khronos WebGL 2.0.1 deqp occlusionquery_strict / _conservative, two target
// draws per query, the second hidden). It also leaves a slot a mode was set on without any draw as it was, where Metal
// writes 0 (the WebGPU CTS's occlusionQuery empty / initial read old values). Counting and Boolean modes; a 64x64 target,
// halves of 2048 samples each; the visibility buffer starts filled with 0xAB.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
    "    float2 c = select(r.xy, r.zw, bool2(vid & uint2(2, 1))); return float4(c, 0.5, 1.0); }\n"
    "fragment float4 fs() { return float4(1.0, 0.0, 0.0, 1.0); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n08-kepler-visibility-sum";
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
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    static float left[4] = {-1, -1, 0, 1}, right[4] = {0, -1, 1, 1}, outside[4] = {2, 2, 3, 3};
    struct { const char *what; float *draws[3]; int count; uint64_t samples; } cases[] = {
        {"left, right", {left, right}, 2, 4096},
        {"left, then a draw outside the target", {left, outside}, 2, 2048},
        {"left, right, outside", {left, right, outside}, 3, 4096},
        {"outside, left", {outside, left}, 2, 2048},
        {"none (the mode set, no draw)", {0}, 0, 0},
    };
    for (int boolean = 0; boolean < 2; boolean++)
        for (unsigned c = 0; c < sizeof cases / sizeof *cases; c++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageRenderTarget;
            id<MTLBuffer> vis = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
            memset(vis.contents, 0xAB, 64);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.visibilityResultBuffer = vis;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps];
            [re setVisibilityResultMode:boolean ? MTLVisibilityResultModeBoolean : MTLVisibilityResultModeCounting offset:8];
            for (int i = 0; i < cases[c].count; i++) {
                [re setVertexBytes:cases[c].draws[i] length:16 atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
            [re setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
            [re endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            uint64_t got = ((uint64_t *)vis.contents)[1];
            BOOL ok = boolean ? (got != 0) == (cases[c].samples != 0) : got == cases[c].samples;
            if (!ok)
                return FAIL(bug, "%s: %s mode, draws %s: %llu samples, want %llu", name, boolean ? "Boolean" : "Counting", cases[c].what,
                            (unsigned long long)got, (unsigned long long)cases[c].samples);
        }
    return PASS(bug, "%s: a visibility slot sums every draw counted into it, and is 0 with none (Counting and Boolean)", name);
}}
