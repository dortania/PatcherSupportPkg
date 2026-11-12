// i66-intel-byte-vector-arithmetic (Intel adapter, IntelTextureAtomics.dylib): arithmetic and bitwise operations on
// uchar4 / char4 / ushort2 / short2 / uchar3 in fragment functions with the 3802 Intel compiler. The back end's type
// legalization of these operations on vectors made with as_type crashed the compiler service (as_type<uchar4>(x) ^
// as_type<uchar4>(y), as_type<char4>(x) | select(...)), and on vectors put together lane by lane they could leave nearby
// code wrong (a signed min in a branch on char2(a, b) & (char2(3, 5) & char2(c, d))). Compute functions are right. Found
// by fuzzing fragment functions. Each pixel of a 256x1 target writes eight results for its own inputs to a buffer: xor,
// or with a select, add / mul / sub, the three shifts, halfword vectors, the branch, uchar3, and a loop carrying a uchar4.
// Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "  uint p = uint(pos.x), x = w[p * 4u], y = w[p * 4u + 1u], z = w[p * 4u + 2u], q = w[p * 4u + 3u];\n"
    "  device uint *o = out + p * 8u;\n"
    "  o[0] = as_type<uint>(as_type<uchar4>(x) ^ as_type<uchar4>(y * 3u));\n"
    "  o[1] = as_type<uint>(as_type<char4>(x) | select(char4(98, 1, 1, 1), char4((char)y, (char)x, 2, 3), char4((char)(x >> 3), 1, 2, 3) <= char4((char)y, 0, 0, 0)));\n"
    "  uchar4 a = uchar4((uchar)x, (uchar)y, (uchar)(x >> 8), (uchar)(y >> 8));\n"
    "  o[2] = as_type<uint>((a + as_type<uchar4>(z)) * uchar4(3, 5, 7, 9) - a);\n"
    "  char4 s = as_type<char4>(x);\n"
    "  uchar4 u = as_type<uchar4>(z);\n"
    "  o[3] = as_type<uint>(as_type<uchar4>(s >> (as_type<char4>(y) & char4(7))) ^ (u >> (as_type<uchar4>(q) & uchar4(7))) ^ (u << (as_type<uchar4>(y >> 3) & uchar4(7))));\n"
    "  o[4] = as_type<uint>(as_type<ushort2>(x) * as_type<ushort2>(y) + (ushort2((ushort)z, (ushort)(z >> 16)) ^ as_type<ushort2>(q)))\n"
    "       ^ as_type<uint>(as_type<short2>(z) >> (as_type<short2>(y) & short2(15)));\n"
    "  uint b = q;\n"
    "  if (any((char2((char)x, (char)y) & (char2(3, 5) & char2((char)z, (char)q))) != char2(0))) b = (uint)min((int)x, (int)y);\n"
    "  o[5] = b;\n"
    "  uchar3 c = uchar3(as_type<uchar4>(x).xyz) + uchar3((uchar)y, 7, (uchar)(z >> 4));\n"
    "  c ^= uchar3((uchar)q);\n"
    "  o[6] = uint(c.x) | uint(c.y) << 8 | uint(c.z) << 16;\n"
    "  uchar4 acc = as_type<uchar4>(x);\n"
    "  for (uint k = 0; k < (y & 3u) + 1u; k++) acc = (acc ^ as_type<uchar4>(z + k)) + uchar4(1, 2, 3, 4);\n"
    "  o[7] = as_type<uint>(acc);\n"
    "  return uint4(p);\n"
    "}\n";

enum { W = 256, kWords = 8 };

static uint8_t byteOf(uint32_t w, int k) { return (uint8_t)(w >> (8 * k)); }
static uint32_t pack(const uint8_t b[4]) { return b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24; }

static void reference(const uint32_t *in, uint32_t r[kWords]) {
    uint32_t x = in[0], y = in[1], z = in[2], q = in[3];
    uint8_t t[4];
    for (int k = 0; k < 4; k++) t[k] = byteOf(x, k) ^ byteOf(y * 3u, k);
    r[0] = pack(t);
    int8_t sel[4] = {98, 1, 1, 1}, alt[4] = {(int8_t)y, (int8_t)x, 2, 3}, lhs[4] = {(int8_t)(x >> 3), 1, 2, 3}, rhs[4] = {(int8_t)y, 0, 0, 0};
    for (int k = 0; k < 4; k++) t[k] = byteOf(x, k) | (uint8_t)(lhs[k] <= rhs[k] ? alt[k] : sel[k]);
    r[1] = pack(t);
    uint8_t a[4] = {(uint8_t)x, (uint8_t)y, (uint8_t)(x >> 8), (uint8_t)(y >> 8)}, m[4] = {3, 5, 7, 9};
    for (int k = 0; k < 4; k++) t[k] = (uint8_t)((uint8_t)((uint8_t)(a[k] + byteOf(z, k)) * m[k]) - a[k]);
    r[2] = pack(t);
    for (int k = 0; k < 4; k++) {
        int8_t s = (int8_t)byteOf(x, k);
        uint8_t u = byteOf(z, k);
        t[k] = (uint8_t)(int8_t)(s >> (byteOf(y, k) & 7)) ^ (uint8_t)(u >> (byteOf(q, k) & 7)) ^ (uint8_t)(u << (byteOf(y >> 3, k) & 7));
    }
    r[3] = pack(t);
    uint16_t h[2];
    for (int k = 0; k < 2; k++) {
        uint16_t xs = (uint16_t)(x >> 16 * k), ys = (uint16_t)(y >> 16 * k), zs = (uint16_t)(z >> 16 * k), qs = (uint16_t)(q >> 16 * k);
        h[k] = (uint16_t)((uint16_t)(xs * ys) + (uint16_t)(zs ^ qs)) ^ (uint16_t)(int16_t)((int16_t)zs >> (ys & 15));
    }
    r[4] = h[0] | (uint32_t)h[1] << 16;
    int8_t c2[2] = {(int8_t)((int8_t)x & (3 & (int8_t)z)), (int8_t)((int8_t)y & (5 & (int8_t)q))};
    r[5] = c2[0] || c2[1] ? (uint32_t)((int32_t)x < (int32_t)y ? (int32_t)x : (int32_t)y) : q;
    uint8_t c[3] = {(uint8_t)(byteOf(x, 0) + (uint8_t)y), (uint8_t)(byteOf(x, 1) + 7), (uint8_t)(byteOf(x, 2) + (uint8_t)(z >> 4))};
    for (int k = 0; k < 3; k++) c[k] ^= (uint8_t)q;
    r[6] = c[0] | (uint32_t)c[1] << 8 | (uint32_t)c[2] << 16;
    uint8_t acc[4] = {byteOf(x, 0), byteOf(x, 1), byteOf(x, 2), byteOf(x, 3)};
    for (uint32_t k = 0; k < (y & 3u) + 1u; k++)
        for (int l = 0; l < 4; l++) acc[l] = (uint8_t)((acc[l] ^ byteOf(z + k, l)) + l + 1);
    r[7] = pack(acc);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i66-intel-byte-vector-arithmetic";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLBuffer> words = [dev newBufferWithLength:W * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> results = [dev newBufferWithLength:W * kWords * 4 options:MTLResourceStorageModeShared];
        uint32_t *in = words.contents, x = 2654435761u + 777u;  // xorshift, every 7th word a byte
        for (int i = 0; i < W * 4; i++) x ^= x << 13, x ^= x >> 17, x ^= x << 5, in[i] = i % 7 ? x : x & 0xff;
        memset(results.contents, 0xA5, W * kWords * 4);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:W height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentBuffer:words offset:0 atIndex:0];
        [enc setFragmentBuffer:results offset:0 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const uint32_t *got = results.contents;
        static const char *const kWhat[kWords] = {"uchar4 xor of casts", "char4 or of a select", "uchar4 add / mul / sub", "char4 / uchar4 shifts",
                                                  "ushort2 / short2 operations", "signed min in a branch on char2 ands", "uchar3 add / xor",
                                                  "uchar4 carried through a loop"};
        for (int k = 0; k < kWords; k++) {
            int wrong = 0, first = -1;
            for (int p = 0; p < W; p++) {
                uint32_t want[kWords];
                reference(in + p * 4, want);
                if (got[p * kWords + k] != want[k]) wrong++, first = first < 0 ? p : first;
            }
            if (wrong) {
                uint32_t want[kWords];
                reference(in + first * 4, want);
                return FAIL(bug, "%s: %s wrong in %d of %d pixels (pixel %d: %08x, want %08x)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * kWords + k], want[k]);
            }
        }
        return PASS(bug, "%s: arithmetic and bitwise operations on byte and halfword vectors in a fragment function compile and are right (%d pixels)",
                    dev.name.UTF8String, W);
    }
}
