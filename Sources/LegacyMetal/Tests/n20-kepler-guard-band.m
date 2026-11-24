// n20-kepler-guard-band: triangles crossing the viewport edge must shade each pixel once with its whole sample mask;
// Kepler drew them as fans that split pixels. Fix: MetalOldCompat item 69. Checks: three triangles at 4x MSAA on a 4x4
// target: sample masks and invocation counts. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 v(uint i [[vertex_id]], constant float2 *p [[buffer(0)]]) { return float4(p[i], 0, 1); }\n"
    "fragment uint f(uint mask [[sample_mask]]) { return mask; }\n"
    "fragment uint c(device atomic_uint *count [[buffer(0)]]) { atomic_fetch_add_explicit(count, 1, memory_order_relaxed); return 1; }\n"
    "kernel void r(texture2d_ms<uint> t [[texture(0)]], device uint *o [[buffer(0)]], uint3 g [[thread_position_in_grid]]) {\n"
    "    o[(g.y * 4 + g.x) * 4 + g.z] = t.read(uint2(g.xy), g.z).x; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n20-kepler-guard-band";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"v"];
    rd.fragmentFunction = [lib newFunctionWithName:@"f"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
    rd.rasterSampleCount = 4;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    rd.fragmentFunction = [lib newFunctionWithName:@"c"];
    id<MTLRenderPipelineState> counting = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    id<MTLComputePipelineState> rp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"r"] error:&err];
    if (!ps || !counting || !rp) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { const char *what; float p[6]; } tris[] = {
        {"CTS x=-1 y=-2 triangle (-0.8,2) (1.2,-2) (-0.8,-2)", {-0.8f, 2, 1.2f, -2, -0.8f, -2}},
        {"CTS x=-1 y=-1 triangle (-0.8,1) (1.2,-1) (-0.8,-1)", {-0.8f, 1, 1.2f, -1, -0.8f, -1}},
        {"full-screen triangle (-1,-1) (3,-1) (-1,3)", {-1, -1, 3, -1, -1, 3}}};
    for (int k = 0; k < 3; k++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = 4;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> samples = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> count = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        memset(samples.contents, 0xee, samples.length);
        memset(count.contents, 0, 4);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}];
        [re setRenderPipelineState:ps];
        [re setVertexBytes:tris[k].p length:sizeof tris[k].p atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
        re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}];
        [re setRenderPipelineState:counting];
        [re setVertexBytes:tris[k].p length:sizeof tris[k].p atIndex:0];
        [re setFragmentBuffer:count offset:0 atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:rp];
        [ce setTexture:target atIndex:0];
        [ce setBuffer:samples offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(4, 4, 4) threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, tris[k].what);
        const uint32_t *s = samples.contents;
        uint32_t pixels = 0;
        for (int px = 0; px < 16; px++) {
            uint32_t covered = 0;
            for (int i = 0; i < 4; i++) if (s[px * 4 + i]) covered |= 1u << i;
            if (covered) pixels++;
            for (int i = 0; i < 4; i++)
                if (s[px * 4 + i] && s[px * 4 + i] != covered)
                    return FAIL(bug, "%s: %s: pixel (%d, %d), samples %#x covered: sample %d's fragment saw sample_mask %#x (masks per sample %x %x %x %x)",
                                name, tris[k].what, px % 4, px / 4, covered, i, s[px * 4 + i], s[px * 4], s[px * 4 + 1], s[px * 4 + 2], s[px * 4 + 3]);
        }
        uint32_t invocations = *(const uint32_t *)count.contents;
        if (invocations != pixels)
            return FAIL(bug, "%s: %s: the fragment function ran %u times for %u covered pixels", name, tris[k].what, invocations, pixels);
    }
    return PASS(bug, "%s: triangles across the viewport's edge give every fragment the pixel's whole coverage in sample_mask, and run the fragment function once per pixel", name);
}}
