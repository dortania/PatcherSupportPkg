// i08-intel-kernel-integer-gradient (Intel adapter, IntelTextureAtomics.dylib): gradient samples from integer textures in
// compute functions crash the 3802 Intel compiler (a null dereference in IGILTargetLowering::LowerReadImage_Int), with or
// without a texel offset; vertex and fragment functions are right, and so are float textures. A compute function samples
// mipmapped integer textures (level n holding 1000 * n + 10 * y + x) with gradients that pick levels 0, 1 and 2, from 2D
// int, 2D uint, 2D array and 3D int textures, one with an offset. Stock OCLP: FAIL (no pipeline, or the in-process
// compiler crashes). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<int> i2 [[texture(0)]], texture2d<uint> u2 [[texture(1)]], texture2d_array<int> ia [[texture(2)]],\n"
    "              texture3d<int> i3 [[texture(3)]], sampler s [[sampler(0)]], device float *out [[buffer(0)]]) {\n"
    "    float2 c = float2(2.5) / 8.0;\n"
    "    out[0] = i2.sample(s, c, gradient2d(float2(0.1 / 8, 0), float2(0, 0.1 / 8))).x;\n"  // under a texel: level 0
    "    out[1] = i2.sample(s, c, gradient2d(float2(2.0 / 8, 0), float2(0, 1.0 / 8))).x;\n"  // 2 texels: level 1
    "    out[2] = u2.sample(s, c, gradient2d(float2(0, 4.0 / 8), float2(1.0 / 8, 0))).x;\n"  // 4 texels: level 2
    "    out[3] = i2.sample(s, c, gradient2d(float2(2.0 / 8, 0), float2(0, 2.0 / 8)), int2(1, 2)).x;\n"
    "    out[4] = ia.sample(s, c, 1, gradient2d(float2(2.0 / 8, 0), float2(0, 2.0 / 8))).x;\n"
    "    out[5] = i3.sample(s, float3(2.5, 2.5, 0.5) / float3(8, 8, 2), gradient3d(float3(2.0 / 8, 0, 0), float3(0, 2.0 / 8, 0))).x;\n"
    "}\n";
static const char *const kNames[6] = {"int 2D, level 0", "int 2D, level 1", "uint 2D, level 2", "int 2D, level 1, +(1,2)",
                                      "int 2D array, layer 1, level 1", "int 3D, level 1"};
static const float kWant[6] = {22, 1011, 2000, 1032, 100 + 1011, 1011};  // layer 1 adds 100

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i08-intel-kernel-integer-gradient";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        id<MTLComputePipelineState> pipeline = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error] : nil;
        if (!pipeline) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        // 8x8x2 textures with 3 levels (2D) or 2 (3D); texel (x, y[, z]) of level n holds 1000 * n + 10 * y + x (+ 100 * z)
        id<MTLTexture> textures[4];
        MTLPixelFormat formats[4] = {MTLPixelFormatR32Sint, MTLPixelFormatR32Uint, MTLPixelFormatR32Sint, MTLPixelFormatR32Sint};
        MTLTextureType types[4] = {MTLTextureType2D, MTLTextureType2D, MTLTextureType2DArray, MTLTextureType3D};
        for (int t = 0; t < 4; t++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[t] width:8 height:8 mipmapped:YES];
            td.textureType = types[t];
            if (t == 2) td.arrayLength = 2;
            if (t == 3) td.depth = 2;
            td.mipmapLevelCount = t == 3 ? 2 : 3;
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeManaged;
            textures[t] = [dev newTextureWithDescriptor:td];
            for (int level = 0, size = 8; level < (int)td.mipmapLevelCount; level++, size /= 2) {
                int depth = t == 3 ? (level ? 1 : 2) : 1, slices = t == 2 ? 2 : 1;
                int32_t texels[2 * 64];
                for (int z = 0; z < depth * slices; z++)
                    for (int i = 0; i < size * size; i++) texels[z * size * size + i] = 1000 * level + 100 * z + 10 * (i / size) + i % size;
                for (int slice = 0; slice < slices; slice++)
                    [textures[t] replaceRegion:MTLRegionMake3D(0, 0, 0, size, size, depth) mipmapLevel:level slice:slice
                                     withBytes:texels + slice * size * size bytesPerRow:4 * size bytesPerImage:4 * size * size];
            }
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];  // nearest
        sd.mipFilter = MTLSamplerMipFilterNearest;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [dev newBufferWithLength:sizeof kWant options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        [enc setTextures:textures withRange:NSMakeRange(0, 4)];
        [enc setSamplerState:sampler atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const float *got = out.contents;
        for (int i = 0; i < 6; i++)
            if (got[i] != kWant[i]) return FAIL(bug, "%s: %s read %g, want %g", dev.name.UTF8String, kNames[i], got[i], kWant[i]);
        return PASS(bug, "%s: integer gradient samples in a compute function pick levels 0, 1 and 2 (2D, 2D array, 3D, an offset)",
                    dev.name.UTF8String);
    }
}
