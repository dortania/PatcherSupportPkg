// s35-intel-encoder-lod-clamp: LOD clamps passed to encoders must hold; the 12.x Intel driver wrapped them modulo 16
// (ANGLE's 1000 read as 8). Fix: MetalOldCompat item 31.
// Checks: an 11-level texture at LOD 10, 2 and 9 with clamps (0, 1000), (-3, 1000), (0, 100). Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s35-intel-encoder-lod-clamp";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
            "fragment float4 f(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], float4 pos [[position]], constant float &l [[buffer(0)]]) {\n"
            "  return float4(l < 0 ? t.sample(s, float2(pos.x, 0.5)).x : t.sample(s, float2(0.5), level(l)).x); }\n"  // 1024 texels a pixel: LOD 10
            "kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *out [[buffer(0)]]) {\n"
            "  out[0] = t.sample(s, float2(0.5), level(9)).x; }\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> ps = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
        id<MTLComputePipelineState> cs = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error] : nil;
        if (!ps || !cs) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1024 height:1 mipmapped:YES];
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        static float texels[1024];
        for (int level = 0, n = 1024; n; level++, n /= 2) {
            for (int i = 0; i < n; i++) texels[i] = level;
            [t replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:level withBytes:texels bytesPerRow:4 * n];
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.mipFilter = MTLSamplerMipFilterNearest;
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:1 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const struct { const char *how; float min, max, level; BOOL range; float want; } kCases[] = {
            {"implicit LOD 10, clamps (0, 1000)", 0, 1000, -1, NO, 10},
            {"level(10), clamps (0, 1000) through a range", 0, 1000, 10, YES, 10},
            {"level(2), clamps (-3, 1000)", -3, 1000, 2, NO, 2},
        };
        for (size_t c = 0; c < sizeof kCases / sizeof *kCases; c++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:ps];
            [enc setFragmentTexture:t atIndex:0];
            if (kCases[c].range) {
                id __unsafe_unretained samplers[1] = {sampler};
                float mins[1] = {kCases[c].min}, maxs[1] = {kCases[c].max};
                [enc setFragmentSamplerStates:samplers lodMinClamps:mins lodMaxClamps:maxs withRange:NSMakeRange(0, 1)];
            } else {
                [enc setFragmentSamplerState:sampler lodMinClamp:kCases[c].min lodMaxClamp:kCases[c].max atIndex:0];
            }
            float level = kCases[c].level;
            [enc setFragmentBytes:&level length:sizeof level atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:target];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            float got;
            [target getBytes:&got bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 0, 1, 1) mipmapLevel:0];
            if (got != kCases[c].want)
                return FAIL(bug, "%s: fragment function, %s: read level %g, want %g", dev.name.UTF8String, kCases[c].how, got, kCases[c].want);
        }
        id<MTLBuffer> out = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:cs];
        [enc setTexture:t atIndex:0];
        [enc setSamplerState:sampler lodMinClamp:0 lodMaxClamp:100 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float got = *(float *)out.contents;
        if (got != 9) return FAIL(bug, "%s: compute function, level(9), clamps (0, 100): read level %g, want 9", dev.name.UTF8String, got);
        return PASS(bug, "%s: encoder LOD clamps (0, 1000), (-3, 1000) and (0, 100) don't wrap (fragment and compute, one sampler and a range)",
                    dev.name.UTF8String);
    }
}
