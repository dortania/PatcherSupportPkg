// i50-intel-rg32-green-gather (Intel adapter, INTEL_GATHER_GREEN_FIX): gathers of the green component from R32G32
// textures. Haswell's gather4 returns red for green on R32G32 formats, a hardware erratum (Mesa gives such gathers a
// separate surface state); the shader can't tell the format, so the adapter checks a green gather against a red one and
// samples the four texels where they agree (WebGPU CTS textureGather rg32float: 252 cases). Gathers green from an 8x8
// rg32float texture, layer 1 of a 2-layer rg32float array and an rg32uint texture, with and without texel offsets, at
// seven coordinates (some outside the texture) through clamp-to-edge, repeat and mirrored-repeat samplers, plus red from
// the first, and checks the four texels of each against the texels it should have read.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"
#include <math.h>

static const float kCoords[][2] = {{1.75f, 3.75f}, {4.5f, 4.5f}, {2.2f, 5.9f}, {-2.25f, 0.75f}, {7.75f, 9.3f}, {9.6f, -1.4f}, {0.6f, 7.4f}};
enum { kN = sizeof kCoords / sizeof kCoords[0], kGathers = 6 };
static const int kOffsets[kGathers][2] = {{0, 0}, {1, -2}, {0, 0}, {-1, 1}, {0, 0}, {0, 0}};
static const char *const kWhat[kGathers] = {"rg32float green", "rg32float green, offset (1, -2)", "rg32float array layer 1 green",
                                            "rg32float array layer 1 green, offset (-1, 1)", "rg32uint green", "rg32float red"};

static float texel(int gather, int x, int y) {
    switch (gather) {
    case 0: case 1: return 1000 + 3 * x + 70 * y;
    case 2: case 3: return 2000 + 3 * x + 70 * y;
    case 4: return 50000 + 5 * x + 11 * y;
    default: return x + 10 * y;
    }
}
static int address(int i, MTLSamplerAddressMode mode) {
    if (mode == MTLSamplerAddressModeClampToEdge) return MIN(MAX(i, 0), 7);
    if (mode == MTLSamplerAddressModeRepeat) return ((i % 8) + 8) % 8;
    int m = ((i % 16) + 16) % 16;  // mirrored repeat
    return m < 8 ? m : 15 - m;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i50-intel-rg32-green-gather";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void k(texture2d<float> t [[texture(0)]], texture2d_array<float> ta [[texture(1)]], texture2d<uint> tu [[texture(2)]],\n"
        "              sampler s [[sampler(0)]], device const float2 *c [[buffer(0)]], device float4 *out [[buffer(1)]],\n"
        "              uint i [[thread_position_in_grid]]) {\n"
        "    float2 p = c[i];\n"
        "    out[i * 6 + 0] = t.gather(s, p, int2(0), component::y);\n"
        "    out[i * 6 + 1] = t.gather(s, p, int2(1, -2), component::y);\n"
        "    out[i * 6 + 2] = ta.gather(s, p, 1, int2(0), component::y);\n"
        "    out[i * 6 + 3] = ta.gather(s, p, 1, int2(-1, 1), component::y);\n"
        "    out[i * 6 + 4] = float4(tu.gather(s, p, int2(0), component::y));\n"
        "    out[i * 6 + 5] = t.gather(s, p, int2(0), component::x);\n"
        "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:8 height:8 mipmapped:NO];
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    td.textureType = MTLTextureType2DArray;
    td.arrayLength = 2;
    id<MTLTexture> array = [dev newTextureWithDescriptor:td];
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Uint width:8 height:8 mipmapped:NO];
    id<MTLTexture> utex = [dev newTextureWithDescriptor:td];
    float texels[64][2], layer0[64][2], layer1[64][2];
    uint32_t utexels[64][2];
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++) {
            int i = y * 8 + x;
            texels[i][0] = texel(5, x, y), texels[i][1] = texel(0, x, y);
            layer0[i][0] = -1, layer0[i][1] = -2;
            layer1[i][0] = texel(5, x, y), layer1[i][1] = texel(2, x, y);
            utexels[i][0] = 7, utexels[i][1] = (uint32_t)texel(4, x, y);
        }
    [tex replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:texels bytesPerRow:64];
    [array replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:0 withBytes:layer0 bytesPerRow:64 bytesPerImage:512];
    [array replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:1 withBytes:layer1 bytesPerRow:64 bytesPerImage:512];
    [utex replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:utexels bytesPerRow:64];
    float coords[kN][2];
    for (int i = 0; i < kN; i++) coords[i][0] = kCoords[i][0] / 8, coords[i][1] = kCoords[i][1] / 8;
    id<MTLBuffer> cbuf = [dev newBufferWithBytes:coords length:sizeof coords options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const MTLSamplerAddressMode modes[3] = {MTLSamplerAddressModeClampToEdge, MTLSamplerAddressModeRepeat, MTLSamplerAddressModeMirrorRepeat};
    const char *const modeNames[3] = {"clamp to edge", "repeat", "mirrored repeat"};
    for (int m = 0; m < 3; m++) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = sd.tAddressMode = modes[m];
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [dev newBufferWithLength:kN * kGathers * 16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setTexture:tex atIndex:0];
        [ce setTexture:array atIndex:1];
        [ce setTexture:utex atIndex:2];
        [ce setSamplerState:sampler atIndex:0];
        [ce setBuffer:cbuf offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(kN, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cmd)) return FAIL(bug, "%s: command buffer failed", name);
        const float *got = out.contents;
        for (int i = 0; i < kN; i++)
            for (int g = 0; g < kGathers; g++) {
                int i0 = (int)floorf(coords[i][0] * 8 - 0.5f) + kOffsets[g][0], j0 = (int)floorf(coords[i][1] * 8 - 0.5f) + kOffsets[g][1];
                int x[2] = {address(i0, modes[m]), address(i0 + 1, modes[m])}, y[2] = {address(j0, modes[m]), address(j0 + 1, modes[m])};
                float want[4] = {texel(g, x[0], y[1]), texel(g, x[1], y[1]), texel(g, x[1], y[0]), texel(g, x[0], y[0])};
                const float *v = got + (i * kGathers + g) * 4;
                for (int c = 0; c < 4; c++)
                    if (v[c] != want[c])
                        return FAIL(bug, "%s: %s gather at texel (%.2f, %.2f), %s: %g %g %g %g, want %g %g %g %g", name, kWhat[g],
                                    kCoords[i][0], kCoords[i][1], modeNames[m], v[0], v[1], v[2], v[3], want[0], want[1], want[2], want[3]);
            }
    }
    return PASS(bug, "%s: green gathers from rg32float, rg32float array and rg32uint textures read green (7 coordinates, 3 address modes, offsets)", name);
}}
