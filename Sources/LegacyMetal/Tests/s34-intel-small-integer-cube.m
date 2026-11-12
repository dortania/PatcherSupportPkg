// s34-intel-small-integer-cube (MetalOldCompat item 30): integer cube textures with 1x1 or 2x2 faces, sampled in a
// fragment function on the 12.x Intel driver, read 0 (1x1: every direction; 2x2: near the face centre). The driver's sampler
// state asks for seamless cube addressing, which the sampler can't do for integer formats on faces this small; float
// formats and compute kernels are right. The WebGL suite uploads such faces from canvases and ImageData
// (integer-cubemap-texture-sampling and the tex-2d-*ui-*_integer-* pages). A fragment function samples R8Uint cube
// textures of 1x1, 2x2 and 4x4 (each face filled with its own value) with a nearest sampler, in eight directions per face.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s34-intel-small-integer-cube";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
            "fragment float4 f(texturecube<uint> t [[texture(0)]], sampler s [[sampler(0)]], constant float3 &dir [[buffer(0)]]) {\n"
            "  return float4(float(t.sample(s, dir).x)); }\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> ps = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];  // nearest
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget;
        cd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:cd];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const float kAxes[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
        static const float kOffsets[8][2] = {{0, 0}, {0.001f, 0}, {0, 0.001f}, {0.2f, 0.2f}, {-0.2f, 0.5f}, {0.5f, 0}, {0.5f, 0.5f}, {-0.7f, -0.3f}};
        for (int size = 1; size <= 4; size *= 2) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatR8Uint size:size mipmapped:NO];
            td.storageMode = MTLStorageModeManaged;
            id<MTLTexture> cube = [dev newTextureWithDescriptor:td];
            for (int face = 0; face < 6; face++) {
                uint8_t texels[16];
                memset(texels, 10 * (face + 1), sizeof texels);
                [cube replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 slice:face withBytes:texels bytesPerRow:size bytesPerImage:0];
            }
            for (int face = 0; face < 6; face++)
                for (int o = 0; o < 8; o++) {
                    float dir[4] = {kAxes[face][0], kAxes[face][1], kAxes[face][2], 0};
                    int u = kAxes[face][0] != 0 ? 1 : 0, w = kAxes[face][2] != 0 ? 1 : 2;  // two axes across the face
                    dir[u] += kOffsets[o][0];
                    dir[w] += kOffsets[o][1];
                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = target;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLCommandBuffer> cb = [q commandBuffer];
                    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                    [enc setRenderPipelineState:ps];
                    [enc setFragmentTexture:cube atIndex:0];
                    [enc setFragmentSamplerState:sampler atIndex:0];
                    [enc setFragmentBytes:dir length:sizeof dir atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    [enc endEncoding];
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit synchronizeResource:target];
                    [blit endEncoding];
                    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
                    float got;
                    [target getBytes:&got bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
                    if (got != 10 * (face + 1))
                        return FAIL(bug, "%s: %dx%d faces, direction (%g, %g, %g) read %g, want %d", dev.name.UTF8String, size, size, dir[0], dir[1],
                                    dir[2], got, 10 * (face + 1));
                }
        }
        return PASS(bug, "%s: R8Uint cube textures of 1x1, 2x2 and 4x4 sample right in a fragment function", dev.name.UTF8String);
    }
}
