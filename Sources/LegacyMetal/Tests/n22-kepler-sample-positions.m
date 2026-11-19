// n22-kepler-sample-positions (MetalOldCompat item 71): getDefaultSamplePositions:count: must give each sample's real
// position. Kepler's 2x and 8x patterns use the standard positions in another order than the one Metal reported (2x:
// samples 0 and 1 swapped; 8x: sample 0 at (0.0625, 0.4375), which Metal gave as sample 5's), so anything matching sample
// indices to positions (custom resolves, per-sample techniques) got the wrong sample; 4x was right. Each sample's position
// is measured on a 1x1 multisampled target: a rectangle covering x < X (then y < Y) for X in steps of 1/64, offset by half
// a step so no edge passes through a sample; a sample's position is where it first gets covered. At 2x, 4x and 8x.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 v(uint i [[vertex_id]], constant float2 &e [[buffer(0)]]) {\n"
    // e.x: the edge in window units of the 1-pixel target; e.y: 0 = covers window x < e.x, 1 = covers window y < e.x
    "    float a = e.x * 2.0 - 1.0, b = 1.0 - e.x * 2.0;\n"
    "    float2 lo = e.y < 0.5 ? float2(-4, -4) : float2(-4, b), hi = e.y < 0.5 ? float2(a, 4) : float2(4, 4);\n"
    "    float2 c[6] = {lo, float2(hi.x, lo.y), hi, lo, hi, float2(lo.x, hi.y)};\n"
    "    return float4(c[i], 0.5, 1); }\n"
    "fragment uint f() { return 1; }\n"
    "kernel void r(texture2d_ms<uint> t [[texture(0)]], device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    o[i] = t.read(uint2(0), i).x; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n22-kepler-sample-positions";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> rp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"r"] error:&err];
    if (!rp) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    int tested = 0;
    for (NSUInteger count = 2; count <= 8; count *= 2) {
        if (![dev supportsTextureSampleCount:count]) continue;
        tested++;
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"v"];
        rd.fragmentFunction = [lib newFunctionWithName:@"f"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
        rd.rasterSampleCount = count;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
        if (!ps) return FAIL(bug, "%s: %lux pipeline: %s", name, (unsigned long)count, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:1 height:1 mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = count;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        float measured[2][8];
        for (int axis = 0; axis < 2; axis++) {
            id<MTLBuffer> covered = [dev newBufferWithLength:64 * count * 4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            for (int step = 0; step < 64; step++) {
                id<MTLTexture> t = [dev newTextureWithDescriptor:td];
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = t;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
                float e[2] = {(step + 0.5f) / 64.0f, (float)axis};
                [re setRenderPipelineState:ps];
                [re setVertexBytes:e length:sizeof e atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [re endEncoding];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:rp];
                [ce setTexture:t atIndex:0];
                [ce setBuffer:covered offset:step * count * 4 atIndex:0];
                [ce dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(count, 1, 1)];
                [ce endEncoding];
            }
            if (!reproRun(cb)) return FAIL(bug, "%s: %lux: command buffer failed", name, (unsigned long)count);
            for (NSUInteger s = 0; s < count; s++) {
                measured[axis][s] = -1;
                for (int step = 0; step < 64 && measured[axis][s] < 0; step++)
                    if (((const uint32_t *)covered.contents)[step * count + s]) measured[axis][s] = step / 64.0f;
                if (measured[axis][s] < 0)
                    return FAIL(bug, "%s: %lux: sample %lu never covered by the %s sweep", name, (unsigned long)count, (unsigned long)s, axis ? "y" : "x");
            }
        }
        MTLSamplePosition reported[8];
        [dev getDefaultSamplePositions:reported count:count];
        for (NSUInteger s = 0; s < count; s++)
            if (fabsf(measured[0][s] - reported[s].x) > 1.0f / 128 || fabsf(measured[1][s] - reported[s].y) > 1.0f / 128)
                return FAIL(bug, "%s: %lux: sample %lu is at (%.4f, %.4f), getDefaultSamplePositions says (%.4f, %.4f)", name, (unsigned long)count,
                            (unsigned long)s, measured[0][s], measured[1][s], reported[s].x, reported[s].y);
    }
    if (!tested) return SKIP(bug, "%s: no multisample counts", name);
    return PASS(bug, "%s: every sample of the 2x, 4x and 8x patterns is where getDefaultSamplePositions says", name);
}}
