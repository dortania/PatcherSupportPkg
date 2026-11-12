// s52-intel-integer-cube-compare-sampler (MetalOldCompat item 30): an integer cube texture with 1x1 faces sampled in a
// fragment function through a nearest sampler that has a compare function set. ANGLE passes GL's default compare
// function (LEQUAL) to every MTLSamplerDescriptor, comparison on or off, so WebGL's samplers all carry one. Item 30 gives
// nearest samplers programmed cube addressing (seamless addressing reads integer cubes with tiny faces as 0); for a while
// it left samplers with a compare function seamless (for WebGPU's compare gathers), and every WebGL integer cube read 0
// again (Khronos WebGL 2.0.1 integer-cubemap-texture-sampling, integer-cubemap-specification-order-bug, and the r8ui /
// rg8ui / rgb8ui / rgba8ui upload pages in Chrome). Reads each face of an R8Uint cube holding 11-16 through such a sampler.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], texturecube<uint> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "    const float3 dirs[6] = {float3(1, 0.1, 0.2), float3(-1, 0.1, 0.2), float3(0.1, 1, 0.2), float3(0.1, -1, 0.2),\n"
    "                            float3(0.1, 0.2, 1), float3(0.1, 0.2, -1)};\n"
    "    return t.sample(s, dirs[min(uint(pos.x), 5u)]);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s52-intel-integer-cube-compare-sampler";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatR8Uint size:1 mipmapped:NO];
        id<MTLTexture> cube = [dev newTextureWithDescriptor:cd];
        for (int face = 0; face < 6; face++) {
            uint8_t value = 11 + face;
            [cube replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:face withBytes:&value bytesPerRow:1 bytesPerImage:0];
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];  // nearest, as ANGLE's for integer textures
        sd.compareFunction = MTLCompareFunctionLessEqual;        // GL's default TEXTURE_COMPARE_FUNC, passed on by ANGLE
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:6 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentTexture:cube atIndex:0];
        [enc setFragmentSamplerState:sampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        uint32_t got[6];
        [target getBytes:got bytesPerRow:24 fromRegion:MTLRegionMake2D(0, 0, 6, 1) mipmapLevel:0];
        static const char *const faces[6] = {"+X", "-X", "+Y", "-Y", "+Z", "-Z"};
        for (int face = 0; face < 6; face++)
            if (got[face] != 11u + face)
                return FAIL(bug, "%s: R8Uint cube with 1x1 faces, nearest sampler with compare function LessEqual: face %s read %u, want %u", name,
                            faces[face], got[face], 11 + face);
        return PASS(bug, "%s: an integer cube with 1x1 faces reads every face through a nearest sampler that has a compare function", name);
    }
}
