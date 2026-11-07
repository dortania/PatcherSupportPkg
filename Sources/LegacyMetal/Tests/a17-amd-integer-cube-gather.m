// a17-amd-integer-cube-gather (AMD adapter): gather on integer cube textures must return the bilinear footprint's four
// texels, from the neighbouring face where the footprint crosses an edge. GCN forces nearest filtering on integer
// formats, so the hardware returns the footprint that starts at the texel holding the point (a08's half-texel shift, in
// 2D), and integer fetch4 doesn't cross face edges, so no shifted direction fixes it on cubes. The adapter turns such a
// gather into 4 nearest samples at the footprint's texel centres. (WebGPU CTS builtin,textureGather sampled_3d_coords
// and sampled_array_3d_coords: every integer format, 252 cases.)
// Checked: cube and cube array, uint and int, 8, 16 and 32 bit, every component, faces of 8 and 64 texels, random
// directions and points within half a texel of an edge (corners and points within 1/64 texel of a texel boundary skipped).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"
#include <math.h>

enum { kPoints = 1024 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "constexpr sampler s(filter::nearest);\n"
    "kernel void u(texturecube<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]], constant float4 *d [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  float3 v = d[i].xyz; o[4 * i] = t.gather(s, v, component::x); o[4 * i + 1] = t.gather(s, v, component::y);\n"
    "  o[4 * i + 2] = t.gather(s, v, component::z); o[4 * i + 3] = t.gather(s, v, component::w); }\n"
    "kernel void si(texturecube<int> t [[texture(0)]], device uint4 *o [[buffer(0)]], constant float4 *d [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  o[4 * i] = uint4(t.gather(s, d[i].xyz, component::x)); o[4 * i + 1] = o[4 * i + 2] = o[4 * i + 3] = uint4(0); }\n"
    "kernel void ua(texturecube_array<uint> t [[texture(0)]], device uint4 *o [[buffer(0)]], constant float4 *d [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  o[4 * i] = t.gather(s, d[i].xyz, 1, component::x); o[4 * i + 1] = t.gather(s, d[i].xyz, 1, component::w); o[4 * i + 2] = o[4 * i + 3] = uint4(0); }\n";

static int N;
static uint32_t texel(int layer, int face, int x, int y, int channel) {
    return (((uint32_t)(layer * 6 + face) * 4096u + (uint32_t)y * 64u + (uint32_t)x) * 4u + (uint32_t)channel) * 7u + 3u;
}
// Face selection and face coordinates as Metal (and Vulkan) define them.
static int faceOf(const float d[3], float *s, float *t) {
    float ax = fabsf(d[0]), ay = fabsf(d[1]), az = fabsf(d[2]), sc, tc, ma;
    int f;
    if (ax >= ay && ax >= az) { f = d[0] >= 0 ? 0 : 1; ma = ax; sc = d[0] >= 0 ? -d[2] : d[2]; tc = -d[1]; }
    else if (ay >= az) { f = d[1] >= 0 ? 2 : 3; ma = ay; sc = d[0]; tc = d[1] >= 0 ? d[2] : -d[2]; }
    else { f = d[2] >= 0 ? 4 : 5; ma = az; sc = d[2] >= 0 ? d[0] : -d[0]; tc = -d[1]; }
    *s = (sc / ma + 1) * 0.5f;
    *t = (tc / ma + 1) * 0.5f;
    return f;
}
static void dirOf(int f, float s, float t, float d[3]) {  // a direction to (s, t) on face f
    float sc = 2 * s - 1, tc = 2 * t - 1;
    switch (f) {
        case 0: d[0] = 1; d[2] = -sc; d[1] = -tc; break;
        case 1: d[0] = -1; d[2] = sc; d[1] = -tc; break;
        case 2: d[1] = 1; d[0] = sc; d[2] = tc; break;
        case 3: d[1] = -1; d[0] = sc; d[2] = -tc; break;
        case 4: d[2] = 1; d[0] = sc; d[1] = -tc; break;
        default: d[2] = -1; d[0] = -sc; d[1] = -tc; break;
    }
}
// Texel (i, j) of face f, one of them possibly one past an edge: then the neighbouring face's edge texel.
static void fetchFace(int f, int i, int j, int *face, int *x, int *y) {
    float d[3], s, t;
    dirOf(f, (i + 0.5f) / N, (j + 0.5f) / N, d);
    *face = faceOf(d, &s, &t);
    *x = (int)floorf(s * N); *y = (int)floorf(t * N);
    if (*x < 0) *x = 0; if (*x >= N) *x = N - 1; if (*y < 0) *y = 0; if (*y >= N) *y = N - 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a17-amd-integer-cube-gather";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { MTLPixelFormat format; int channels, bytes; const char *kernel, *name; BOOL array; } cases[] = {
            {MTLPixelFormatR8Uint, 1, 1, "u", "r8uint", NO}, {MTLPixelFormatRGBA16Uint, 4, 2, "u", "rgba16uint", NO},
            {MTLPixelFormatR32Sint, 1, 4, "si", "r32sint", NO}, {MTLPixelFormatR16Uint, 1, 2, "ua", "r16uint array", YES}};
        int checked = 0;
        for (int size = 8; size <= 64; size *= 8)
        for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
            N = size;
            int layers = cases[c].array ? 2 : 1, channels = cases[c].channels, bytes = cases[c].bytes;
            MTLTextureDescriptor *td = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:cases[c].format size:N mipmapped:NO];
            if (cases[c].array) { td.textureType = MTLTextureTypeCubeArray; td.arrayLength = layers; }
            td.storageMode = MTLStorageModeManaged; td.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            uint8_t *data = calloc((size_t)N * N * channels, bytes);
            uint32_t mask = bytes == 1 ? 0xff : bytes == 2 ? 0xffff : 0xffffffff;
            for (int layer = 0; layer < layers; layer++)
            for (int f = 0; f < 6; f++) {
                for (int y = 0; y < N; y++)
                for (int x = 0; x < N; x++)
                for (int ch = 0; ch < channels; ch++) {
                    uint32_t v = texel(layer, f, x, y, ch) & mask;
                    size_t at = ((size_t)(y * N + x) * channels + ch) * bytes;
                    if (bytes == 1) data[at] = v; else if (bytes == 2) memcpy(data + at, &(uint16_t){v}, 2); else memcpy(data + at, &v, 4);
                }
                [tex replaceRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0 slice:layer * 6 + f withBytes:data
                       bytesPerRow:N * channels * bytes bytesPerImage:0];
            }
            free(data);
            float (*dirs)[4] = calloc(kPoints, sizeof *dirs);
            srand48(17 + size);
            for (int k = 0; k < kPoints; k++) {
                if (k < kPoints / 2) { for (int a = 0; a < 3; a++) dirs[k][a] = drand48() * 2 - 1; continue; }
                int f = k % 6;  // within half a texel of an edge
                float s = drand48(), t = drand48(), e = drand48() * 0.5f / N;
                switch (k / 6 % 4) { case 0: s = e; break; case 1: s = 1 - e; break; case 2: t = e; break; default: t = 1 - e; break; }
                dirOf(f, s, t, dirs[k]);
            }
            id<MTLBuffer> d = [dev newBufferWithBytes:dirs length:kPoints * sizeof *dirs options:MTLResourceStorageModeShared];
            id<MTLBuffer> o = [dev newBufferWithLength:kPoints * 4 * 16 options:MTLResourceStorageModeShared];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(cases[c].kernel)] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:ps]; [e setTexture:tex atIndex:0]; [e setBuffer:o offset:0 atIndex:0]; [e setBuffer:d offset:0 atIndex:1];
            [e dispatchThreads:MTLSizeMake(kPoints, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [e endEncoding];
            reproRun(cb);
            const uint32_t (*got)[4] = o.contents;
            // Components checked per kernel: u all 4 (missing channels read 0, alpha 1), si x, ua x and w.
            int comps[4] = {0, 1, 2, 3}, ncomps = cases[c].kernel[0] == 's' ? 1 : cases[c].array ? 2 : 4;
            if (cases[c].array) comps[1] = 3;
            for (int k = 0; k < kPoints; k++) {
                float s, t;
                int f = faceOf(dirs[k], &s, &t);
                float u = s * N - 0.5f, v = t * N - 0.5f, fu = u - floorf(u), fv = v - floorf(v);
                if (fu < 1.0f / 64 || fu > 63.0f / 64 || fv < 1.0f / 64 || fv > 63.0f / 64) continue;  // texel boundary
                int i0 = (int)floorf(u), j0 = (int)floorf(v);
                int is[4] = {i0, i0 + 1, i0 + 1, i0}, js[4] = {j0 + 1, j0 + 1, j0, j0};
                BOOL corner = NO;
                for (int n = 0; n < 4; n++) corner |= (is[n] < 0 || is[n] >= N) && (js[n] < 0 || js[n] >= N);
                if (corner) continue;
                for (int m = 0; m < ncomps; m++) {
                    int ch = comps[m];
                    uint32_t want[4];
                    for (int n = 0; n < 4; n++) {
                        int face, x, y;
                        fetchFace(f, is[n], js[n], &face, &x, &y);
                        want[n] = ch < channels ? texel(layers - 1, face, x, y, ch) & mask : ch == 3 ? 1 : 0;
                        if (cases[c].format == MTLPixelFormatR32Sint) want[n] = (uint32_t)(int32_t)want[n];
                    }
                    const uint32_t *g = got[4 * k + m];
                    if (memcmp(want, g, sizeof want))
                        return FAIL(bug, "%s: %s, faces of %d: gather(%.4f, %.4f, %.4f) component %d (face %d, s %.4f t %.4f) = %u %u %u %u, want %u %u %u %u",
                                    dev.name.UTF8String, cases[c].name, N, dirs[k][0], dirs[k][1], dirs[k][2], ch, f, s, t,
                                    g[0], g[1], g[2], g[3], want[0], want[1], want[2], want[3]);
                    checked++;
                }
            }
            free(dirs);
        }
        return PASS(bug, "%s: %d gathers on integer cube and cube array textures return the right texels", dev.name.UTF8String, checked);
    }
}
