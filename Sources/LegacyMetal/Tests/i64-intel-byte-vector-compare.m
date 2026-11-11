// i64-intel-byte-vector-compare (Intel adapter, IntelTextureAtomics.dylib): compares and selects of uchar4 / char4 in
// fragment functions with the 3802 Intel compiler. The back end's type legalization of a compare between two byte
// vectors depends on how each was made: any(uchar4(a, b, c, d) <= as_type<uchar4>(x)) crashed the compiler service
// (SelectionDAG::getZeroExtendInReg), any(as_type<char4>(x) > as_type<char4>(y)) came out wrong, and a select of byte
// vectors by such a compare crashed, also on the bytes of as_type<uchar4>(ushort2) (i62). Compute functions are right.
// Found by fuzzing fragment functions. Each pixel of a 256x1 RGBA32Uint target gets the four cases for its own inputs.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]]) {\n"
    "  uint i = uint(pos.x) * 4u, x = w[i], y = w[i + 1u];\n"
    "  uchar4 a = uchar4((uchar)x, (uchar)y, (uchar)(x >> 8), (uchar)(y >> 8));\n"
    "  uint r1 = (uint)any(a <= as_type<uchar4>(x ^ y)) | ((uint)any(as_type<char4>(x ^ y) > as_type<char4>(y)) << 1);\n"
    "  uchar4 s3 = select(uchar4(119, 1, 9, 1), as_type<uchar4>(x), a <= as_type<uchar4>(y));\n"
    "  uchar4 s4 = select(a, uchar4(119, 1, 9, 1), as_type<uchar4>(x ^ 3u) <= as_type<uchar4>(short2((short)y, (short)(x >> 3))));\n"
    "  return uint4(r1, as_type<uint>(s3), uint(s4.x) + uint(s4.y) * 3u + uint(s4.z) * 5u + uint(s4.w) * 7u, 0u);\n"
    "}\n";

enum { W = 256 };

static void bytesOf(uint32_t w, uint8_t b[4]) { for (int k = 0; k < 4; k++) b[k] = (uint8_t)(w >> (8 * k)); }

static void reference(uint32_t x, uint32_t y, uint32_t r[4]) {
    uint8_t a[4] = {(uint8_t)x, (uint8_t)y, (uint8_t)(x >> 8), (uint8_t)(y >> 8)}, k[4] = {119, 1, 9, 1}, bx[4], by[4], bxy[4], bx3[4], bs[4];
    bytesOf(x, bx), bytesOf(y, by), bytesOf(x ^ y, bxy), bytesOf(x ^ 3u, bx3), bytesOf((y & 0xffff) | (((x >> 3) & 0xffff) << 16), bs);
    int any1 = 0, any2 = 0;
    for (int l = 0; l < 4; l++) any1 |= a[l] <= bxy[l], any2 |= (int8_t)bxy[l] > (int8_t)by[l];
    uint32_t s3 = 0, s4 = 0;
    for (int l = 0; l < 4; l++) s3 |= (uint32_t)(a[l] <= by[l] ? bx[l] : k[l]) << (8 * l);
    static const uint32_t m[4] = {1, 3, 5, 7};
    for (int l = 0; l < 4; l++) s4 += (bx3[l] <= bs[l] ? k[l] : a[l]) * m[l];
    r[0] = (uint32_t)any1 | ((uint32_t)any2 << 1), r[1] = s3, r[2] = s4, r[3] = 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i64-intel-byte-vector-compare";
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
        uint32_t *in = words.contents, x = 2654435761u + 12345u;  // xorshift, every 7th word a byte
        for (int i = 0; i < W * 4; i++) x ^= x << 13, x ^= x >> 17, x ^= x << 5, in[i] = i % 7 ? x : x & 0xff;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:W height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setFragmentBuffer:words offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        static uint32_t got[W * 4];
        [target getBytes:got bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, 1) mipmapLevel:0];
        static const char *const kWhat[3] = {"any() of the compares", "select by a compare", "select of as_type<uchar4>(ushort2) compares"};
        for (int k = 0; k < 3; k++) {
            int wrong = 0, first = -1;
            for (int p = 0; p < W; p++) {
                uint32_t want[4];
                reference(in[p * 4], in[p * 4 + 1], want);
                if (got[p * 4 + k] != want[k]) wrong++, first = first < 0 ? p : first;
            }
            if (wrong) {
                uint32_t want[4];
                reference(in[first * 4], in[first * 4 + 1], want);
                return FAIL(bug, "%s: %s wrong in %d of %d pixels (pixel %d: %08x, want %08x)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * 4 + k], want[k]);
            }
        }
        return PASS(bug, "%s: compares and selects of byte vectors in a fragment function compile and are right (%d pixels)", dev.name.UTF8String, W);
    }
}
