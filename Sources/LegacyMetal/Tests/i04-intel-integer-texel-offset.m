// i04-intel-integer-texel-offset (Intel adapter, IntelTextureAtomics.dylib): texel offsets on integer textures with the
// 3802 Intel compiler. sample(s, coord, offset) on an integer texture ignores the offset and returns the texel at the
// coordinate; float textures are right. GLSL textureOffset / textureLodOffset / textureProjOffset on isampler and
// usampler compile to that (dEQP shadertexturefunction *offset: 6 pages fail), and so do textureGradOffset and
// textureProjGradOffset (gradient samples). A compute function samples 8x8 textures holding 10 * y + x at texel (2, 2)
// with offsets, from 2D int, 2D uint (explicit level), 2D array and 3D int textures, and from a 2D float texture as the
// control; a fragment function does the same with gradients from 2D int and 2D array textures (integer gradient samples
// crash the back end in compute functions, offset or not), and samples level 1 of a mipmapped 2D int texture (1000 + 10 * y
// + x there) with offsets, picked by gradients and by the derivatives of a minified coordinate. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<int> i2 [[texture(0)]], texture2d<uint> u2 [[texture(1)]], texture2d_array<int> ia [[texture(2)]],\n"
    "              texture3d<int> i3 [[texture(3)]], texture2d<float> f2 [[texture(4)]], sampler s [[sampler(0)]],\n"
    "              device float *out [[buffer(0)]]) {\n"
    "    float2 c = float2(2.5) / 8.0;\n"
    "    out[0] = f2.sample(s, c, int2(1, 0)).x;\n"
    "    out[1] = f2.sample(s, c, int2(-1, 3)).x;\n"
    "    out[2] = i2.sample(s, c, int2(1, 0)).x;\n"
    "    out[3] = i2.sample(s, c, int2(-1, 3)).x;\n"
    "    out[4] = u2.sample(s, c, level(0), int2(0, 1)).x;\n"
    "    out[5] = ia.sample(s, c, 1, int2(2, 1)).x;\n"
    "    out[6] = i3.sample(s, float3(2.5, 2.5, 0.5) / float3(8, 8, 2), int3(1, 1, 1)).x;\n"
    "}\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "fragment float4 f(texture2d<int> i2 [[texture(0)]], texture2d_array<int> ia [[texture(2)]], texture2d<int> m [[texture(5)]],\n"
    "                  sampler s [[sampler(0)]], sampler mip [[sampler(1)]], float4 pos [[position]]) {\n"
    "    float2 c = float2(2.5) / 8.0;\n"
    "    return float4(i2.sample(s, c, gradient2d(float2(0), float2(0)), int2(1, 2)).x,\n"
    "                  ia.sample(s, c, 1, gradient2d(float2(0), float2(0)), int2(-2, 1)).x,\n"
    "                  m.sample(mip, c, gradient2d(float2(0.25, 0), float2(0, 0.25)), int2(1, 1)).x,\n"
    "                  m.sample(mip, pos.xy / 4, int2(3, 2)).x);\n"  // a 4x4 target: 2 texels of level 0 per pixel
    "}\n";
static const char *const kNames[11] = {"float 2D +(1,0) (the control)", "float 2D +(-1,3) (the control)", "int 2D +(1,0)",
                                      "int 2D +(-1,3)", "uint 2D level(0) +(0,1)", "int 2D array, layer 1, +(2,1)", "int 3D +(1,1,1)",
                                      "int 2D gradient +(1,2)", "int 2D array, layer 1, gradient +(-2,1)",
                                      "int 2D level 1 by gradients, +(1,1)", "int 2D level 1 by derivatives, +(3,2)"};
static const float kWant[11] = {23, 51, 23, 51, 32, 100 + 34, 100 + 33, 43, 100 + 30, 1022, 1023};  // layer / slice 1 adds 100

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i04-intel-integer-texel-offset";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        id<MTLComputePipelineState> pipeline = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error] : nil;
        if (!pipeline) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> render = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!render) return FAIL(bug, "%s: no render pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        int32_t ints[2][64];
        float floats[64];
        for (int z = 0; z < 2; z++)
            for (int i = 0; i < 64; i++) ints[z][i] = 100 * z + 10 * (i / 8) + i % 8;
        for (int i = 0; i < 64; i++) floats[i] = ints[0][i];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Sint width:8 height:8 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> i2 = [dev newTextureWithDescriptor:td];
        [i2 replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:ints[0] bytesPerRow:32];
        td.pixelFormat = MTLPixelFormatR32Uint;
        id<MTLTexture> u2 = [dev newTextureWithDescriptor:td];
        [u2 replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:ints[0] bytesPerRow:32];
        td.pixelFormat = MTLPixelFormatR32Float;
        id<MTLTexture> f2 = [dev newTextureWithDescriptor:td];
        [f2 replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:floats bytesPerRow:32];
        td.pixelFormat = MTLPixelFormatR32Sint;
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = 2;
        id<MTLTexture> ia = [dev newTextureWithDescriptor:td];
        for (int z = 0; z < 2; z++)
            [ia replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:z withBytes:ints[z] bytesPerRow:32 bytesPerImage:256];
        td.textureType = MTLTextureType3D;
        td.arrayLength = 1;
        td.depth = 2;
        id<MTLTexture> i3 = [dev newTextureWithDescriptor:td];
        [i3 replaceRegion:MTLRegionMake3D(0, 0, 0, 8, 8, 2) mipmapLevel:0 slice:0 withBytes:ints bytesPerRow:32 bytesPerImage:256];
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];  // nearest
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.mipFilter = MTLSamplerMipFilterNearest;
        id<MTLSamplerState> mipSampler = [dev newSamplerStateWithDescriptor:sd];
        MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Sint width:8 height:8 mipmapped:YES];
        md.usage = MTLTextureUsageShaderRead;
        md.storageMode = MTLStorageModeManaged;
        id<MTLTexture> m = [dev newTextureWithDescriptor:md];
        [m replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:ints[0] bytesPerRow:32];
        for (int level = 1, size = 4; size; level++, size /= 2) {
            int32_t texels[16];
            for (int i = 0; i < size * size; i++) texels[i] = 1000 * level + 10 * (i / size) + i % size;
            [m replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:level withBytes:texels bytesPerRow:4 * size];
        }
        id<MTLBuffer> out = [dev newBufferWithLength:sizeof kWant options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:4 height:4 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        id<MTLTexture> textures[5] = {i2, u2, ia, i3, f2};
        [enc setTextures:textures withRange:NSMakeRange(0, 5)];
        [enc setSamplerState:sampler atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> draw = [cb renderCommandEncoderWithDescriptor:rp];
        [draw setRenderPipelineState:render];
        [draw setFragmentTextures:textures withRange:NSMakeRange(0, 3)];
        [draw setFragmentTexture:m atIndex:5];
        [draw setFragmentSamplerState:sampler atIndex:0];
        [draw setFragmentSamplerState:mipSampler atIndex:1];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [draw endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        float got[11], pixel[4];
        memcpy(got, out.contents, 7 * sizeof(float));
        [target getBytes:pixel bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        got[7] = pixel[0], got[8] = pixel[1], got[9] = pixel[2], got[10] = pixel[3];
        for (int i = 0; i < 11; i++)
            if (got[i] != kWant[i])
                return FAIL(bug, "%s: %s read %g, want %g%s", dev.name.UTF8String, kNames[i], got[i], kWant[i],
                            i == 9 && got[i] == 1011    ? " (the offset was ignored or taken in level-0 texels)"
                            : i == 10 && got[i] == 1012 ? " (the offset was taken in level-0 texels)"
                            : i >= 2 && got[i] == (i == 5 || i == 6 || i == 8 ? 122 : i == 10 ? 1000 : 22) ? " (the offset was ignored)" : "");
        return PASS(bug, "%s: texel offsets right on integer 2D, 2D array and 3D textures, with gradients and on level 1", dev.name.UTF8String);
    }
}
