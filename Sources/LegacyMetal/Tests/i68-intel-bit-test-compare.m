// i68-intel-bit-test-compare (Intel adapter, IntelTextureAtomics.dylib): branches on a compare of a 0/1 value with 1 in
// fragment functions with the 3802 Intel compiler. In `if (((x & 1u) & y) != 1u) v = min(...)` the back end took the
// `& 1` out of the and as redundant for the compare and then tested the whole register (IGIL: AND r, x, y; IF_CND.z r),
// so pixels where x & y had bits above bit 0 set went the wrong way. Compares with 0 and selects are right; compute
// functions are right. Found by fuzzing fragment functions (VEC=1 seed 1248, through mulhi and insert_bits). Each pixel
// of a 256x1 RGBA32Uint target does three such branches (the and of two values, of a mulhi, and of an insert_bits) with
// a call in each so that they stay branches. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]]) {\n"
    "  uint i = uint(pos.x) * 4u, x = w[i], y = w[i + 1u], z = w[i + 2u], q = w[i + 3u], r0 = 1u, r1 = 2u, r2 = 3u;\n"
    "  if (((x & 1u) & y) != 1u) r0 = (uint)min((int)x, (int)y);\n"
    "  if (((z & 1u) & mulhi(x, q)) != 1u) r1 = (uint)max((int)z, (int)q);\n"
    "  if (((insert_bits(y, x, 1u, q & 15u) & 1u) & (z ^ q)) != 1u) r2 = (uint)clamp((int)q, -5, (int)(x >> 1));\n"
    "  return uint4(r0, r1, r2, 0u);\n"
    "}\n";

enum { W = 256 };

static uint32_t insertBits(uint32_t base, uint32_t insert, uint32_t offset, uint32_t count) {
    uint32_t mask = count >= 32 ? ~0u : ((1u << count) - 1) << offset;
    return (base & ~mask) | ((insert << offset) & mask);
}
static int32_t imin(int32_t a, int32_t b) { return a < b ? a : b; }
static int32_t imax(int32_t a, int32_t b) { return a > b ? a : b; }

static void reference(const uint32_t *w, uint32_t r[4]) {
    uint32_t x = w[0], y = w[1], z = w[2], q = w[3];
    r[0] = 1, r[1] = 2, r[2] = 3, r[3] = 0;
    if (((x & 1) & y) != 1) r[0] = (uint32_t)imin((int32_t)x, (int32_t)y);
    if (((z & 1) & (uint32_t)(((uint64_t)x * q) >> 32)) != 1) r[1] = (uint32_t)imax((int32_t)z, (int32_t)q);
    if (((insertBits(y, x, 1, q & 15) & 1) & (z ^ q)) != 1) r[2] = (uint32_t)imin(imax((int32_t)q, -5), (int32_t)(x >> 1));
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i68-intel-bit-test-compare";
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
        uint32_t *in = words.contents, x = 2654435761u + 1248u;  // xorshift, every 7th word a byte
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
        static const char *const kWhat[3] = {"((x & 1) & y) != 1", "((z & 1) & mulhi) != 1", "((insert_bits & 1) & v) != 1"};
        for (int k = 0; k < 3; k++) {
            int wrong = 0, first = -1;
            for (int p = 0; p < W; p++) {
                uint32_t want[4];
                reference(in + p * 4, want);
                if (got[p * 4 + k] != want[k]) wrong++, first = first < 0 ? p : first;
            }
            if (wrong) {
                uint32_t want[4];
                reference(in + first * 4, want);
                return FAIL(bug, "%s: branch on %s wrong in %d of %d pixels (pixel %d: %u, want %u)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * 4 + k], want[k]);
            }
        }
        return PASS(bug, "%s: branches on a compare of a 0/1 value with 1 in a fragment function are right (%d pixels)", dev.name.UTF8String, W);
    }
}
