// a08-integer-gather (AMD adapter): gather on integer textures must return the four texels around the coordinate.
// libAMDIL902 compiles it to fetch4 with unnormalized coordinates but passes the shader's normalized ones, so it always
// returns the texels at the texture's corner. GCN also forces nearest filtering on integer formats, which leaves gather
// half a texel off once the coordinates are normalized. (WebGPU CTS builtin,textureGather: every integer format.)
// The 3802 Intel compiler gets the plain cases right but ignores the offset (as for samples, i04); the Intel adapter
// moves it into the coordinates.
// Checked: 2D and 2D array, 8 and 32 bit, clamp, repeat and mirrored repeat, with and without an offset.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"
#include <math.h>

enum { kSize = 8, kCoords = 200, kLayer = 1 };
#define KERNELS(name, mode, offsetValue) \
    "kernel void " name "(texture2d<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]], constant float2 *c [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n" \
    "  constexpr sampler s(filter::nearest, address::" mode "); o[i] = t.gather(s, c[i], " offsetValue ", component::x); }\n" \
    "kernel void " name "_a(texture2d_array<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]], constant float2 *c [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n" \
    "  constexpr sampler s(filter::nearest, address::" mode "); o[i] = t.gather(s, c[i], 1, " offsetValue ", component::x); }\n"
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    KERNELS("clamp", "clamp_to_edge", "int2(0)") KERNELS("wrap", "repeat", "int2(0)") KERNELS("mirror", "mirrored_repeat", "int2(0)") KERNELS("offset", "clamp_to_edge", "int2(1, -2)");

// Texel coordinate after the address mode: 0 clamp, 1 repeat, 2 mirrored repeat.
static int address(int i, int mode) {
    if (mode == 0) return i < 0 ? 0 : i >= kSize ? kSize - 1 : i;
    int m = ((i % (2 * kSize)) + 2 * kSize) % (2 * kSize);
    if (mode == 1) return m % kSize;
    return m < kSize ? m : 2 * kSize - 1 - m;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a08-integer-gather";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        float coords[kCoords][2];
        srand48(11);
        for (int i = 0; i < kCoords; i++) { coords[i][0] = drand48() * 3 - 1; coords[i][1] = drand48() * 3 - 1; }
        id<MTLBuffer> c = [dev newBufferWithBytes:coords length:sizeof coords options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { MTLPixelFormat format; int bytes; const char *name; } formats[] = {{MTLPixelFormatR8Uint, 1, "r8uint"}, {MTLPixelFormatR32Uint, 4, "r32uint"}};
        struct { const char *kernel; int mode, dx, dy; } cases[] = {{"clamp", 0, 0, 0}, {"wrap", 1, 0, 0}, {"mirror", 2, 0, 0}, {"offset", 0, 1, -2}};
        for (int f = 0; f < 2; f++)
        for (int array = 0; array < 2; array++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor new];
            td.pixelFormat = formats[f].format; td.width = td.height = kSize; td.storageMode = MTLStorageModeManaged; td.usage = MTLTextureUsageShaderRead;
            td.textureType = array ? MTLTextureType2DArray : MTLTextureType2D; td.arrayLength = array ? 2 : 1;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            for (int layer = 0; layer <= array; layer++) {
                uint32_t texels[kSize * kSize];
                uint8_t narrow[kSize * kSize];
                for (int y = 0; y < kSize; y++)
                    for (int x = 0; x < kSize; x++) texels[y * kSize + x] = narrow[y * kSize + x] = 2 * (y * kSize + x) + 1 + (layer == kLayer ? 128 : 0);
                [tex replaceRegion:MTLRegionMake2D(0, 0, kSize, kSize) mipmapLevel:0 slice:layer withBytes:formats[f].bytes == 1 ? (void *)narrow : (void *)texels
                       bytesPerRow:kSize * formats[f].bytes bytesPerImage:0];
            }
            for (int k = 0; k < 4; k++) {
                NSString *name = [NSString stringWithFormat:@"%s%s", cases[k].kernel, array ? "_a" : ""];
                id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&err];
                if (!ps) return FAIL(bug, "%s: pipeline %s: %s", dev.name.UTF8String, name.UTF8String, err.localizedDescription.UTF8String);
                id<MTLBuffer> o = [dev newBufferWithLength:sizeof(uint32_t) * 4 * kCoords options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps]; [e setTexture:tex atIndex:0]; [e setBuffer:o offset:0 atIndex:0]; [e setBuffer:c offset:0 atIndex:1];
                [e dispatchThreads:MTLSizeMake(kCoords, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [e endEncoding];
                reproRun(cb);
                const uint32_t (*got)[4] = o.contents;
                for (int i = 0; i < kCoords; i++) {
                    int x0 = (int)floorf(coords[i][0] * kSize - 0.5f) + cases[k].dx, y0 = (int)floorf(coords[i][1] * kSize - 0.5f) + cases[k].dy;
                    int xs[2] = {address(x0, cases[k].mode), address(x0 + 1, cases[k].mode)}, ys[2] = {address(y0, cases[k].mode), address(y0 + 1, cases[k].mode)};
                    uint32_t base = array ? 129 : 1, want[4];
                    want[0] = 2 * (ys[1] * kSize + xs[0]) + base;
                    want[1] = 2 * (ys[1] * kSize + xs[1]) + base;
                    want[2] = 2 * (ys[0] * kSize + xs[1]) + base;
                    want[3] = 2 * (ys[0] * kSize + xs[0]) + base;
                    if (memcmp(want, got[i], sizeof want))
                        return FAIL(bug, "%s: %s %s gather(%.3f, %.3f) = %u %u %u %u, want %u %u %u %u", dev.name.UTF8String, formats[f].name, name.UTF8String, coords[i][0], coords[i][1],
                                    got[i][0], got[i][1], got[i][2], got[i][3], want[0], want[1], want[2], want[3]);
                }
            }
        }
        return PASS(bug, "%s: gather on integer 2D and 2D array textures returns the right texels", dev.name.UTF8String);
    }
}
