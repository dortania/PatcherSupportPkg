// n36-kepler-saturated-product: a saturating add or subtract of a product must saturate right; the back end folded the
// multiply in and got it wrong. Fix: GeForceAIRCompat NVAIR_SATURATED_PRODUCT_FIX. Checks: signed and unsigned forms
// and a uint2, 256 threads against the CPU. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint4 *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint4 v = in[t];\n"
    "    uint p = (uint)(uchar)(v.x) * 213u;\n"
    "    int q = (int)(uchar)(v.x) * 213;\n"
    "    out[t * 8 + 0] = subsat(0xffffffffu, p);\n"
    "    out[t * 8 + 1] = subsat(0xffffffffu, (v.y & 0xff00u) * 3u);\n"
    "    out[t * 8 + 2] = (uint)subsat(2147483647, q);\n"
    "    out[t * 8 + 3] = (uint)subsat((int)(v.z), q);\n"
    "    out[t * 8 + 4] = (uint)addsat((int)(v.z), q);\n"
    "    out[t * 8 + 5] = (uint)addsat(q, (int)(v.w));\n"
    "    uint2 r = subsat(uint2(0xffffffffu, v.w | 0x80000000u), uint2(p, (uint)(uchar)(v.y) * 77u));\n"
    "    out[t * 8 + 6] = r.x; out[t * 8 + 7] = r.y;\n"
    "}\n";

static uint32_t subsatU(uint32_t a, uint32_t b) { return a >= b ? a - b : 0; }
static int32_t clampS(int64_t v) { return v > INT32_MAX ? INT32_MAX : v < INT32_MIN ? INT32_MIN : (int32_t)v; }

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n36-kepler-saturated-product";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSString *why = nil;
    id<MTLComputePipelineState> ps = reproComputePipeline(dev, src, nil, &why);
    if (!ps) return FAIL(bug, "%s", why.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t *p = in.contents, x = 74u * 2654435761u + 12345u;
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x; }
    for (int t = 0; t < T; t += 8) { p[t * 4] &= ~0xffu; p[t * 4 + 1] &= ~0xff00u; p[t * 4 + 1] &= ~0xffu; }  // zero products
    memset(out.contents, 0xcd, out.length);
    if (!reproDispatch([dev newCommandQueue], ps, @[in, out], MTLSizeMake(T / 64, 1, 1), MTLSizeMake(64, 1, 1))) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *r = out.contents;
    static const char *what[8] = {"subsat(~0u, byte * 213)", "subsat(~0u, (y & 0xff00) * 3)", "subsat(INT_MAX, byte * 213)", "subsat(int z, byte * 213)",
                                  "addsat(int z, byte * 213)", "addsat(byte * 213, int w)", "uint2 subsat, lane x", "uint2 subsat, lane y"};
    for (int t = 0; t < T; t++) {
        uint32_t vx = p[t * 4], vy = p[t * 4 + 1], vz = p[t * 4 + 2], vw = p[t * 4 + 3];
        uint32_t pu = (vx & 0xffu) * 213u;
        int32_t q = (int32_t)((vx & 0xffu) * 213u);
        uint32_t want[8] = {subsatU(0xffffffffu, pu), subsatU(0xffffffffu, (vy & 0xff00u) * 3u), (uint32_t)clampS((int64_t)INT32_MAX - q),
                            (uint32_t)clampS((int64_t)(int32_t)vz - q), (uint32_t)clampS((int64_t)(int32_t)vz + q), (uint32_t)clampS((int64_t)q + (int32_t)vw),
                            subsatU(0xffffffffu, pu), subsatU(vw | 0x80000000u, (vy & 0xffu) * 77u)};
        for (int k = 0; k < 8; k++)
            if (r[t * 8 + k] != want[k]) return FAIL(bug, "%s: %s, thread %d: %#x, want %#x", name, what[k], t, r[t * 8 + k], want[k]);
    }
    return PASS(bug, "%s: saturating adds and subtracts of products are right", name);
}}
