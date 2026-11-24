// n35-kepler-vector-lane-constants: constant masks and per-lane constant shifts of 4-lane 8- and 16-bit vectors must
// keep every bit; lane x lost one. Fix: GeForceAIRCompat NVAIR_VECTOR_CONSTANT_FIX. Checks: uchar4 and ushort4 forms,
// 256 threads against the CPU. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint4 *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint4 v = in[t];\n"
    "    uchar4 a = (uchar4(201, uchar(v.x), uchar(v.y), uchar(v.z)) << uchar4(0, 7, 2, 5)) & uchar4(78, 137, 22, 80);\n"
    "    out[t * 4 + 0] = uint(a.x ^ a.y);\n"
    "    uchar4 b = (uchar4(201, uchar(v.y), uchar(v.z), uchar(v.w)) << uchar4(0, 7, 0, 0)) & uchar4(78, 137, 22, 80);\n"
    "    out[t * 4 + 1] = uint(b.x ^ b.y);\n"
    "    ushort4 c = (ushort4(51201, ushort(v.z), ushort(v.w), ushort(v.x)) << ushort4(0, 15, 0, 0)) & ushort4(20046, 35209, 22, 80);\n"
    "    out[t * 4 + 2] = uint(c.x ^ c.y);\n"
    "    uchar4 d = (uchar4(201, uchar(v.w >> 8), uchar(v.x >> 3), uchar(v.y >> 5)) << uchar4(0, 7, 2, 5)) & uchar4(78, 137, 22, 80);\n"
    "    out[t * 4 + 3] = ((uint(d.x) * 1u) ^ (uint(d.y) * 257u) ^ (uint(d.z) * 65599u) ^ (uint(d.w) * 16777619u)) & 63u;\n"
    "}\n";

static uint8_t sh8(uint32_t x, int s) { return (uint8_t)((uint8_t)x << s); }
static uint16_t sh16(uint32_t x, int s) { return (uint16_t)((uint16_t)x << s); }

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n35-kepler-vector-lane-constants";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSString *why = nil;
    id<MTLComputePipelineState> ps = reproComputePipeline(dev, src, nil, &why);
    if (!ps) return FAIL(bug, "%s", why.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    uint32_t *p = in.contents, x = 7232u * 2654435761u + 12345u;
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x; }
    memset(out.contents, 0xcd, out.length);
    if (!reproDispatch([dev newCommandQueue], ps, @[in, out], MTLSizeMake(T / 64, 1, 1), MTLSizeMake(64, 1, 1))) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *r = out.contents;
    static const char *what[4] = {"uchar4 << <0,7,2,5> & mask, x ^ y", "uchar4 << <0,7,0,0> & mask, x ^ y", "ushort4 << <0,15,0,0> & mask, x ^ y",
                                  "uchar4 << <0,7,2,5> & mask, lanes folded & 63"};
    for (int t = 0; t < T; t++) {
        uint32_t vx = p[t * 4], vy = p[t * 4 + 1], vz = p[t * 4 + 2], vw = p[t * 4 + 3];
        uint8_t a0 = sh8(201, 0) & 78, a1 = sh8(vx, 7) & 137;
        uint8_t b0 = sh8(201, 0) & 78, b1 = sh8(vy, 7) & 137;
        uint16_t c0 = sh16(51201, 0) & 20046, c1 = sh16(vz, 15) & 35209;
        uint8_t d0 = sh8(201, 0) & 78, d1 = sh8(vw >> 8, 7) & 137, d2 = sh8(vx >> 3, 2) & 22, d3 = sh8(vy >> 5, 5) & 80;
        uint32_t want[4] = {(uint32_t)(a0 ^ a1), (uint32_t)(b0 ^ b1), (uint32_t)(c0 ^ c1),
                            (((uint32_t)d0 * 1u) ^ ((uint32_t)d1 * 257u) ^ ((uint32_t)d2 * 65599u) ^ ((uint32_t)d3 * 16777619u)) & 63u};
        for (int k = 0; k < 4; k++)
            if (r[t * 4 + k] != want[k]) return FAIL(bug, "%s: %s, thread %d: %#x, want %#x", name, what[k], t, r[t * 4 + k], want[k]);
    }
    return PASS(bug, "%s: masked and shifted vectors with a constant lane are right", name);
}}
