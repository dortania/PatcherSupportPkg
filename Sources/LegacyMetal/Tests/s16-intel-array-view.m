// s16-intel-array-view (MetalOldCompat item 16; also Apple's own Intel driver 18.8.16 on macOS 12.7.6): a 2D-array
// texture view whose first slice isn't 0, on the 12.x Intel driver. Its surface state limits the view to the parent's
// slices below (first slice + view length) counted from the view, so only the first (length - first) layers are
// reachable; the rest read layer 0 / the last valid layer. (WebGL 2 texture arrays and wgpu views of layers 2+.)
// A 6-layer texture holds 10 * layer in every texel; a 3-layer view of layers 2..4 is read at layers 0..2.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s16-intel-array-view";
        id<MTLDevice> d = reproDevice(argc, argv, "Intel");
        if (!d) return SKIP(bug, "no such GPU");
        NSUInteger base = 2, count = 3;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType2DArray; td.pixelFormat = MTLPixelFormatRGBA8Unorm; td.width = td.height = 16;
        td.arrayLength = 6; td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [d newTextureWithDescriptor:td];
        for (NSUInteger layer = 0; layer < 6; layer++) {
            uint8_t px[16 * 16 * 4];
            for (int i = 0; i < 16 * 16; i++) { px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = 0; px[i * 4 + 3] = (uint8_t)(10 * layer); }
            [t replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 slice:layer withBytes:px bytesPerRow:64 bytesPerImage:sizeof px];
        }
        id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2DArray
                                                        levels:NSMakeRange(0, 1) slices:NSMakeRange(base, count)];
        NSError *e = nil;
        id<MTLLibrary> lib = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(texture2d_array<float> t [[texture(0)]], device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
            "  constexpr sampler s(filter::nearest);\n"
            "  out[i] = t.read(uint2(0), i).a; out[i + 4] = t.sample(s, float2(0.5), i).a; }\n" options:nil error:&e];
        id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e];
        id<MTLBuffer> out = [d newBufferWithLength:64 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
        [c setComputePipelineState:ps]; [c setTexture:view atIndex:0]; [c setBuffer:out offset:0 atIndex:0];
        [c dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(count, 1, 1)];
        [c endEncoding];
        reproRun(cb);
        const float *r = out.contents;
        char got[128] = "";
        int bad = 0;
        for (NSUInteger i = 0; i < count; i++) {
            int read = (int)(r[i] * 255 + 0.5f), sampled = (int)(r[i + 4] * 255 + 0.5f), want = (int)(10 * (base + i));
            bad += read != want || sampled != want;
            snprintf(got + strlen(got), sizeof got - strlen(got), " %d/%d", read, sampled);
        }
        if (bad) return FAIL(bug, "%s: view of layers 2..4 read/sampled at layers 0..2:%s, want 20 30 40", d.name.UTF8String, got);
        return PASS(bug, "%s: every layer of a view starting at layer 2 reachable (read and sample)", d.name.UTF8String);
    }
}
