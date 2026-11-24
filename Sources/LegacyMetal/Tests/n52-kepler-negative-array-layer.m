// n52-kepler-negative-array-layer (GeForceAIRCompat, NVAIR_ARRAY_LAYER_CLAMP): a texture-array sample or gather at a
// negative layer must clamp to layer 0, as WebGPU specifies and Apple's GPUs do. Kepler's plugin passes the i32 layer
// straight to the texture instruction, which takes it as unsigned, so layer -1 of an 8-layer 2D array sampled layer 7;
// Safari's WebGPU passes WGSL's layer to Metal unclamped (CTS textureSampleLevel sampled_array_2d_coords, arrayIndex -1,
// in WebKit). Checked in a kernel, at layers -1 and -5: sample, sample at a level and gather of a 2D array of 8 layers
// (layer L filled with (L + 1) * 20), and sample of a cube array of 2 cubes; every one must read layer 0 (and layers 0,
// 3, 7 and 9 their own or the last one). Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring
// (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "n52-kepler-negative-array-layer";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void k(texture2d_array<float> t [[texture(0)]], texturecube_array<float> c [[texture(1)]], sampler s [[sampler(0)]],\n"
             "              device const int *layers [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
             "  int layer = layers[i];\n"
             "  o[i * 4 + 0] = t.sample(s, float2(0.5), layer).r;\n"
             "  o[i * 4 + 1] = t.sample(s, float2(0.5), layer, level(0)).r;\n"
             "  o[i * 4 + 2] = t.gather(s, float2(0.5), layer).x;\n"
             "  o[i * 4 + 3] = c.sample(s, float3(1, 0, 0), layer).r; }" options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", name, error.localizedDescription.UTF8String);
        id<MTLComputePipelineState> pipeline = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        if (!pipeline) return FAIL(bug, "%s: pipeline: %s", name, error.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType2DArray;
        td.pixelFormat = MTLPixelFormatR8Unorm;
        td.width = 4;
        td.height = 4;
        td.arrayLength = 8;
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> array = [dev newTextureWithDescriptor:td];
        uint8_t texels[16];
        for (NSUInteger layer = 0; layer < 8; layer++) {
            memset(texels, (int)(layer + 1) * 20, sizeof texels);
            [array replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:layer withBytes:texels bytesPerRow:4 bytesPerImage:0];
        }
        td.textureType = MTLTextureTypeCubeArray;
        td.arrayLength = 2;
        id<MTLTexture> cubes = [dev newTextureWithDescriptor:td];
        for (NSUInteger face = 0; face < 12; face++) {  // cube n's faces are filled with (n + 1) * 20
            memset(texels, (int)(face / 6 + 1) * 20, sizeof texels);
            [cubes replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:face withBytes:texels bytesPerRow:4 bytesPerImage:0];
        }
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        const int layers[6] = {-1, -5, 0, 3, 7, 9};
        const int want2d[6] = {0, 0, 0, 3, 7, 7}, wantCube[6] = {0, 0, 0, 1, 1, 1};
        id<MTLBuffer> in = [dev newBufferWithBytes:layers length:sizeof layers options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:6 * 4 * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:array atIndex:0];
        [encoder setTexture:cubes atIndex:1];
        [encoder setSamplerState:sampler atIndex:0];
        [encoder setBuffer:in offset:0 atIndex:0];
        [encoder setBuffer:out offset:0 atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(6, 1, 1) threadsPerThreadgroup:MTLSizeMake(6, 1, 1)];
        [encoder endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const float *o = out.contents;
        const char *const what[4] = {"2D array sample", "2D array sample at level 0", "2D array gather", "cube array sample"};
        for (int i = 0; i < 6; i++)
            for (int k = 0; k < 4; k++) {
                int got = (int)lroundf(o[i * 4 + k] * 255.0f / 20.0f) - 1, want = k == 3 ? wantCube[i] : want2d[i];
                if (got != want)
                    return FAIL(bug, "%s: %s at layer %d read layer %d, want %d", name, what[k], layers[i], got, want);
            }
        return PASS(bug, "%s: texture-array samples and gathers at negative layers read layer 0 (2D array sample, at a level, gather; "
                         "cube array sample)", name);
    }
}
