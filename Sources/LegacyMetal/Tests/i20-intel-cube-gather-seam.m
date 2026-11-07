// i20-intel-cube-gather-seam (Intel adapter, IntelTextureAtomics.dylib, with MetalOldCompat item 30): a cube gather at a
// face edge, through a sampler whose filters are nearest, in a fragment function. Item 30 gives nearest samplers clamped
// instead of seamless cube addressing (integer cubes with tiny faces need it), and a gather's 2x2 footprint spans the
// edge, so all four texels came from one face (WebGPU CTS textureGather sampled_3d_coords, nearest: 330 cases). The
// adapter gives cube gathers a linear constexpr sampler, which item 30 leaves seamless (a gather doesn't filter).
// Gathers an 8x8 R32Float cube whose faces hold 10, 20, ... 60 at a direction a quarter texel into +X from its +Z edge:
// two texels must come from +X (10) and two from +Z (50).
// Stock OCLP with the PR's shim: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment float4 f(texturecube<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float3 &dir [[buffer(0)]]) {\n"
    "    return t.gather(s, dir);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i20-intel-cube-gather-seam";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatR32Float size:8 mipmapped:NO];
        id<MTLTexture> cube = [dev newTextureWithDescriptor:cd];
        for (int face = 0; face < 6; face++) {
            float texels[64];
            for (int i = 0; i < 64; i++) texels[i] = 10 * (face + 1);
            [cube replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:face withBytes:texels bytesPerRow:32 bytesPerImage:0];
        }
        id<MTLSamplerState> nearest = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        // +X face: s = -z / x, so z = 0.9375 puts the sample 0.25 texels from the face's edge with +Z (a footprint of
        // columns -1 and 0); y = 0 keeps the rows inside the face
        float dir[4] = {1.0f, 0.0f, 0.9375f, 0};
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentTexture:cube atIndex:0];
        [enc setFragmentSamplerState:nearest atIndex:0];
        [enc setFragmentBytes:dir length:sizeof dir atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        float g[4];
        [target getBytes:g bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        int fromX = 0, fromZ = 0;
        for (int k = 0; k < 4; k++) fromX += g[k] == 10, fromZ += g[k] == 50;
        if (fromX != 2 || fromZ != 2)
            return FAIL(bug, "%s: nearest-sampler cube gather across the +X/+Z edge: %g %g %g %g, want two 10s (+X) and two 50s (+Z)", name, g[0], g[1],
                        g[2], g[3]);
        return PASS(bug, "%s: a nearest-sampler cube gather at a face edge takes texels from both faces", name);
    }
}
