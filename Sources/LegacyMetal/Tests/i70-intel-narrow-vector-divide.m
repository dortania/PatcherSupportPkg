// i70-intel-narrow-vector-divide (Intel adapter, IntelTextureAtomics.dylib): division, remainder, min and max of byte
// and halfword vectors made with as_type in fragment functions with the 3802 Intel compiler. The 8/16-bit division and
// min / max fixes (i31, i22) widen the operands to 32-bit lanes, and a whole-vector extension of an as_type vector went
// wrong there: as_type<uchar4>(x) % uchar4(41, 23, 33, 100) and / crashed the compiler service, as_type<char4>(x) %
// char4(41, -23, 33, 100) came out as the unsigned remainder, and a signed max(char4, as_type<char4>(y)) was wrong.
// Vectors put together lane by lane, and compute functions, were right. Found by fragment fuzzing with as_type (seeds 55,
// 165, 205: crashes; 245: the max). Each pixel of a 256x1 target writes eight results for its
// own inputs to a buffer. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "  uint p = uint(pos.x), x = w[p * 4u], y = w[p * 4u + 1u], z = w[p * 4u + 2u], q = w[p * 4u + 3u];\n"
    "  device uint *o = out + p * 8u;\n"
    "  o[0] = as_type<uint>(as_type<uchar4>(x) % uchar4(41, 23, 33, 100));\n"
    "  o[1] = as_type<uint>(as_type<uchar4>(y) / uchar4(41, 23, 3, 100));\n"
    "  o[2] = as_type<uint>(as_type<char4>(z) % char4(41, -23, 33, 100));\n"
    "  o[3] = as_type<uint>(as_type<char4>(q) / char4(-7, 23, 3, -100));\n"
    "  o[4] = as_type<uint>(as_type<uchar4>(x ^ y) % (as_type<uchar4>(z) | uchar4(1)));\n"
    "  o[5] = as_type<uint>(as_type<ushort2>(y) % ushort2(1000, 7)) ^ as_type<uint>(as_type<short2>(q) / short2(-300, 9));\n"
    "  o[6] = as_type<uint>(as_type<char4>(x + z) / (as_type<char4>(q) | char4(1)));\n"
    "  o[7] = as_type<uint>(max(char4((char)x, (char)0, (char)(-73), (char)z), as_type<char4>(y)) ^ min(as_type<char4>(q), as_type<char4>(z)));\n"
    "  return uint4(p);\n"
    "}\n";

enum { W = 256, kWords = 8 };

static uint8_t byteOf(uint32_t w, int k) { return (uint8_t)(w >> (8 * k)); }
static uint32_t pack(const uint8_t b[4]) { return b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24; }

static void reference(const uint32_t *in, uint32_t r[kWords]) {
    uint32_t x = in[0], y = in[1], z = in[2], q = in[3];
    static const uint8_t m0[4] = {41, 23, 33, 100}, m1[4] = {41, 23, 3, 100};
    static const int8_t s2[4] = {41, -23, 33, 100}, s3[4] = {-7, 23, 3, -100};
    uint8_t t[4];
    for (int k = 0; k < 4; k++) t[k] = byteOf(x, k) % m0[k];
    r[0] = pack(t);
    for (int k = 0; k < 4; k++) t[k] = byteOf(y, k) / m1[k];
    r[1] = pack(t);
    for (int k = 0; k < 4; k++) t[k] = (uint8_t)(int8_t)((int8_t)byteOf(z, k) % s2[k]);
    r[2] = pack(t);
    for (int k = 0; k < 4; k++) t[k] = (uint8_t)(int8_t)((int8_t)byteOf(q, k) / s3[k]);
    r[3] = pack(t);
    for (int k = 0; k < 4; k++) t[k] = byteOf(x ^ y, k) % (byteOf(z, k) | 1);
    r[4] = pack(t);
    uint16_t h[2];
    static const uint16_t u5[2] = {1000, 7};
    static const int16_t s5[2] = {-300, 9};
    for (int k = 0; k < 2; k++) h[k] = (uint16_t)((uint16_t)(y >> 16 * k) % u5[k]) ^ (uint16_t)(int16_t)((int16_t)(q >> 16 * k) / s5[k]);
    r[5] = h[0] | (uint32_t)h[1] << 16;
    for (int k = 0; k < 4; k++) t[k] = (uint8_t)(int8_t)((int8_t)byteOf(x + z, k) / (int8_t)(byteOf(q, k) | 1));
    r[6] = pack(t);
    int8_t c7[4] = {(int8_t)x, 0, -73, (int8_t)z};
    for (int k = 0; k < 4; k++) {
        int8_t a = c7[k], b = (int8_t)byteOf(y, k), c = (int8_t)byteOf(q, k), d = (int8_t)byteOf(z, k);
        t[k] = (uint8_t)((a > b ? a : b) ^ (c < d ? c : d));
    }
    r[7] = pack(t);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i70-intel-narrow-vector-divide";
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
        uint32_t *in = words.contents, x = 2654435761u + 70u;  // xorshift, every 7th word a byte
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
        static const char *const kWhat[kWords] = {"uchar4 % constants", "uchar4 / constants", "char4 % constants", "char4 / constants", "uchar4 % uchar4", "ushort2 % / short2 /", "char4 / char4", "char4 max / min of as_type"};
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
        return PASS(bug, "%s: division, remainder, min and max of as_type byte and halfword vectors in a fragment function compile and are right (%d pixels)",
                    dev.name.UTF8String, W);
    }
}
