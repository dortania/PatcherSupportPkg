// i19-intel-kernel-gather-offset (Intel adapter, IntelTextureAtomics.dylib): textureGather with a texel offset in a compute
// kernel. The 3802 back end adds the offset to the normalized coordinate as is (FADD coord, 1.0 for an offset of 1), so
// each texel of offset moves the gather a whole texture width: on an 8x8 texture an offset of (1, 0) gathers column 8,
// clamped to 7 (WebGPU CTS textureGather sampled_2d_coords with offsets in compute, 639 cases; vertex and fragment
// functions are right). Gathers an 8x8 R32Float texture whose texels hold x + 10 * y at three coordinates with eight
// offsets, clamp to edge, and checks the four texels returned.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <math.h>

static const int kOffsets[][2] = {{0, 0}, {-2, -3}, {1, 0}, {0, 1}, {-1, 0}, {0, -1}, {3, 2}, {-8, 7}};
static const float kCoords[][2] = {{1.75f, 3.75f}, {4.5f, 4.5f}, {2.2f, 5.9f}};
enum { kNumOffsets = sizeof kOffsets / sizeof kOffsets[0], kNumCoords = sizeof kCoords / sizeof kCoords[0], kN = kNumOffsets * kNumCoords };

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i19-intel-kernel-gather-offset";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device const float2 *c [[buffer(0)]],\n"
            "              device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n    switch (i % "];
        [src appendFormat:@"%d) {\n", kNumOffsets];
        for (int k = 0; k < kNumOffsets; k++)  // gather offsets must be constant expressions
            [src appendFormat:@"    case %d: out[i] = t.gather(s, c[i], int2(%d, %d)); break;\n", k, kOffsets[k][0], kOffsets[k][1]];
        [src appendString:@"    }\n}\n"];
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:8 height:8 mipmapped:YES];
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        for (int level = 0; level < (int)td.mipmapLevelCount; level++) {
            int w = 8 >> level;
            float texels[64];
            for (int y = 0; y < w; y++) for (int x = 0; x < w; x++) texels[y * w + x] = x + 10 * y + 100 * level;
            [tex replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:level withBytes:texels bytesPerRow:w * 4];
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        float coords[kN][2];
        for (int i = 0; i < kN; i++) {
            coords[i][0] = kCoords[i / kNumOffsets][0] / 8;
            coords[i][1] = kCoords[i / kNumOffsets][1] / 8;
        }
        id<MTLBuffer> cb = [dev newBufferWithBytes:coords length:sizeof coords options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kN * 16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setTexture:tex atIndex:0];
        [ce setSamplerState:sampler atIndex:0];
        [ce setBuffer:cb offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(kN, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cmd)) return FAIL(bug, "%s: command buffer failed", name);
        const float *got = out.contents;
        for (int i = 0; i < kN; i++) {
            const int *o = kOffsets[i % kNumOffsets];
            int i0 = (int)floorf(coords[i][0] * 8 - 0.5f) + o[0], j0 = (int)floorf(coords[i][1] * 8 - 0.5f) + o[1];
            int x[2] = {MIN(MAX(i0, 0), 7), MIN(MAX(i0 + 1, 0), 7)}, y[2] = {MIN(MAX(j0, 0), 7), MIN(MAX(j0 + 1, 0), 7)};
            float want[4] = {x[0] + 10.f * y[1], x[1] + 10.f * y[1], x[1] + 10.f * y[0], x[0] + 10.f * y[0]};
            for (int c = 0; c < 4; c++)
                if (got[i * 4 + c] != want[c])
                    return FAIL(bug, "%s: gather at texel (%.2f, %.2f) with offset (%d, %d) in a kernel: %g %g %g %g, want %g %g %g %g", name,
                                coords[i][0] * 8, coords[i][1] * 8, o[0], o[1], got[i * 4], got[i * 4 + 1], got[i * 4 + 2], got[i * 4 + 3],
                                want[0], want[1], want[2], want[3]);
        }
        return PASS(bug, "%s: compute-kernel gathers with texel offsets fetch the offset texels (8 offsets, 3 coordinates)", name);
    }
}
