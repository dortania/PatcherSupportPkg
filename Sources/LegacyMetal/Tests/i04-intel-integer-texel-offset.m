// i04-intel-integer-texel-offset (Intel adapter, IntelTextureAtomics.dylib): texel offsets on integer textures with the
// 3802 Intel compiler. sample(s, coord, offset) on an integer texture ignores the offset and returns the texel at the
// coordinate; float textures are right. GLSL textureOffset / textureLodOffset / textureProjOffset on isampler and
// usampler compile to that (dEQP shadertexturefunction *offset: 6 pages fail). A compute function samples 8x8 textures
// holding 10 * y + x at texel (2, 2) with offsets, from 2D int, 2D uint (explicit level), 2D array and 3D int textures,
// and from a 2D float texture as the control. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
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
    "}\n";
static const char *const kNames[7] = {"float 2D +(1,0) (the control)", "float 2D +(-1,3) (the control)", "int 2D +(1,0)",
                                      "int 2D +(-1,3)", "uint 2D level(0) +(0,1)", "int 2D array, layer 1, +(2,1)", "int 3D +(1,1,1)"};
static const float kWant[7] = {23, 51, 23, 51, 32, 100 + 34, 100 + 33};  // layer / slice 1 adds 100

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i04-intel-integer-texel-offset";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        id<MTLComputePipelineState> pipeline = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error] : nil;
        if (!pipeline) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
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
        id<MTLBuffer> out = [dev newBufferWithLength:sizeof kWant options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        id<MTLTexture> textures[5] = {i2, u2, ia, i3, f2};
        [enc setTextures:textures withRange:NSMakeRange(0, 5)];
        [enc setSamplerState:sampler atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const float *got = out.contents;
        for (int i = 0; i < 7; i++)
            if (got[i] != kWant[i])
                return FAIL(bug, "%s: %s from texel (2, 2) read %g, want %g%s", dev.name.UTF8String, kNames[i], got[i], kWant[i],
                            i >= 2 && got[i] == (i >= 5 ? 122 : 22) ? " (the offset was ignored)" : "");
        return PASS(bug, "%s: texel offsets right on integer 2D, 2D array and 3D textures", dev.name.UTF8String);
    }
}
