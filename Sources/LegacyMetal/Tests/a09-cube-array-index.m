// a09-cube-array-index (AMD adapter): a cube array index out of range must read the same face of the nearest cube.
// GCN clamps the slice, 8 * index + face, so -1 reads the first face of the first cube whatever the direction. WebKit passes
// WGSL's array index on as it is. (WebGPU CTS builtin,textureSample and the others in Safari: every cube array case with a
// negative index.)
// Checked: color, unsigned and depth textures, sample, gather and compare, the whole texture and a view of its last two cubes.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"
#include <math.h>

enum { kSize = 4, kCubes = 3, kFaces = 6, kReads = 8 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texturecube_array<float> t [[texture(0)]], depthcube_array<float> d [[texture(1)]], texturecube_array<uint> u [[texture(2)]],\n"
    "              device float *o [[buffer(0)]], constant int &i [[buffer(1)]], constant float3 &p [[buffer(2)]]) {\n"
    "  constexpr sampler s(filter::nearest), c(filter::nearest, compare_func::greater);\n"
    "  o[0] = t.sample(s, p, i, level(0.0)).x;\n"
    "  o[1] = t.sample(s, p, i, gradientcube(float3(0), float3(0))).x;\n"
    "  o[2] = t.gather(s, p, i).x;\n"
    "  o[3] = float(u.sample(s, p, i, level(0.0)).x);\n"
    "  o[4] = d.sample(s, p, i, level(0));\n"
    "  o[5] = d.gather(s, p, i).x;\n"
    "  o[6] = d.sample_compare(c, p, i, 0.5, level(0));\n"
    "  o[7] = d.gather_compare(c, p, i, 0.5).x;\n"
    "}\n";

// Every layer has its own value, so the result names the layer that was read.
static float layerValue(int layer) { return (layer + 1) / 32.0f; }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a09-cube-array-index";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);

        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureTypeCubeArray;
        td.width = td.height = kSize;
        td.arrayLength = kCubes;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        td.pixelFormat = MTLPixelFormatRGBA8Unorm;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> color = [dev newTextureWithDescriptor:td];
        td.pixelFormat = MTLPixelFormatRGBA8Uint;
        id<MTLTexture> uints = [dev newTextureWithDescriptor:td];
        td.pixelFormat = MTLPixelFormatDepth32Float;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:td];

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> staging = [dev newBufferWithLength:kSize * kSize * sizeof(float) options:MTLResourceStorageModeShared];
        for (int layer = 0; layer < kCubes * kFaces; layer++) {
            uint8_t unorm[kSize * kSize * 4], whole[kSize * kSize * 4];
            for (int i = 0; i < kSize * kSize; i++) {
                unorm[i * 4] = (uint8_t)(layerValue(layer) * 255 + 0.5f);
                whole[i * 4] = layer + 1;
                unorm[i * 4 + 1] = unorm[i * 4 + 2] = whole[i * 4 + 1] = whole[i * 4 + 2] = 0;
                unorm[i * 4 + 3] = whole[i * 4 + 3] = 255;
                ((float *)staging.contents)[i] = layerValue(layer);
            }
            MTLRegion all = MTLRegionMake2D(0, 0, kSize, kSize);
            [color replaceRegion:all mipmapLevel:0 slice:layer withBytes:unorm bytesPerRow:kSize * 4 bytesPerImage:0];
            [uints replaceRegion:all mipmapLevel:0 slice:layer withBytes:whole bytesPerRow:kSize * 4 bytesPerImage:0];
            id<MTLCommandBuffer> fill = [q commandBuffer];
            id<MTLBlitCommandEncoder> blit = [fill blitCommandEncoder];
            [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:kSize * 4 sourceBytesPerImage:kSize * kSize * 4
                      sourceSize:MTLSizeMake(kSize, kSize, 1) toTexture:depth destinationSlice:layer destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            reproRun(fill);
        }

        static const float kDirections[kFaces][3] = {{1, .1f, .1f}, {-1, .1f, .1f}, {.1f, 1, .1f}, {.1f, -1, .1f}, {.1f, .1f, 1}, {.1f, .1f, -1}};
        static const char *const kNames[kReads] = {"sample", "sample grad", "gather", "uint sample", "depth sample", "depth gather", "compare", "gather compare"};
        id<MTLBuffer> o = [dev newBufferWithLength:kReads * sizeof(float) options:MTLResourceStorageModeShared];
        for (int firstCube = 0; firstCube < 2; firstCube++) {
            NSRange levels = NSMakeRange(0, 1), layers = NSMakeRange(firstCube * kFaces, (kCubes - firstCube) * kFaces);
            id<MTLTexture> c = [color newTextureViewWithPixelFormat:color.pixelFormat textureType:MTLTextureTypeCubeArray levels:levels slices:layers];
            id<MTLTexture> u = [uints newTextureViewWithPixelFormat:uints.pixelFormat textureType:MTLTextureTypeCubeArray levels:levels slices:layers];
            id<MTLTexture> d = [depth newTextureViewWithPixelFormat:depth.pixelFormat textureType:MTLTextureTypeCubeArray levels:levels slices:layers];
            for (int index = -2; index <= kCubes + 1; index++)
            for (int face = 0; face < kFaces; face++) {
                int cubes = kCubes - firstCube, cube = index < 0 ? 0 : index >= cubes ? cubes - 1 : index;
                int layer = (firstCube + cube) * kFaces + face;
                float direction[4] = {kDirections[face][0], kDirections[face][1], kDirections[face][2], 0};
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps];
                [e setTexture:c atIndex:0]; [e setTexture:d atIndex:1]; [e setTexture:u atIndex:2];
                [e setBuffer:o offset:0 atIndex:0];
                [e setBytes:&index length:sizeof index atIndex:1];
                [e setBytes:direction length:sizeof direction atIndex:2];
                [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [e endEncoding];
                reproRun(cb);
                const float *got = o.contents;
                float unorm = (int)(layerValue(layer) * 255 + 0.5f) / 255.0f, value = layerValue(layer);
                const float want[kReads] = {unorm, unorm, unorm, (float)(layer + 1), value, value, 0.5f > value ? 1 : 0, 0.5f > value ? 1 : 0};
                for (int r = 0; r < kReads; r++)
                    if (fabsf(got[r] - want[r]) > 0.002f)
                        return FAIL(bug, "%s: %s, view from cube %d, index %d, face %d: got %.4f, want %.4f", dev.name.UTF8String, kNames[r],
                                    firstCube, index, face, got[r], want[r]);
            }
        }
        return PASS(bug, "%s: cube array indices out of range read the same face of the nearest cube", dev.name.UTF8String);
    }
}
