// i65-intel-sum-sign-compare (Intel adapter, IntelTextureAtomics.dylib): signed compares of a sum with zero in fragment
// functions with the 3802 Intel compiler. iCBE folds the constant of an add into the compare as if the add couldn't
// overflow, (x + C) < 0 into x < -C and (x + C) > 0 into x > -C, but MSL's unsigned add wraps, so where x + C wrapped past
// the sign bit the compare went the wrong way. In `if (c) v += (int)(x + 902107310u) < 0 ? y % 1000 : 777u` the pixels
// whose x was in [2^31 - C, 2^31) got 777. Found by fuzzing fragment functions (compute functions are right). Each pixel
// of a 256x1 RGBA32Uint target does three such compares (< 0 and > 0 with that constant, < 0 with its negation) inside
// branches on its own inputs. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]]) {\n"
    "  uint i = uint(pos.x) * 4u, x = w[i], y = w[i + 1u], z = w[i + 2u], q = w[i + 3u], r0 = 1u, r1 = 2u, r2 = 3u;\n"
    "  if ((y & 3u) == 0u) r0 = (int)(z + 902107310u) < 0 ? (uint)((int)(q ^ x) % 1000) : 777u;\n"
    "  if ((y & 12u) != 4u) r1 = (int)(z + 902107310u) > 0 ? 555u : (uint)((int)(q ^ x) % 1000);\n"
    "  if ((y & 48u) != 16u) r2 = (int)(z - 902107310u) < 0 ? (uint)((int)(q ^ y) % 999) : 333u;\n"
    "  return uint4(r0, r1, r2, 0u);\n"
    "}\n";

enum { W = 256 };

static void reference(const uint32_t *w, uint32_t r[4]) {
    uint32_t x = w[0], y = w[1], z = w[2], q = w[3];
    r[0] = 1, r[1] = 2, r[2] = 3, r[3] = 0;
    if ((y & 3) == 0) r[0] = (int32_t)(z + 902107310u) < 0 ? (uint32_t)((int32_t)(q ^ x) % 1000) : 777u;
    if ((y & 12) != 4) r[1] = (int32_t)(z + 902107310u) > 0 ? 555u : (uint32_t)((int32_t)(q ^ x) % 1000);
    if ((y & 48) != 16) r[2] = (int32_t)(z - 902107310u) < 0 ? (uint32_t)((int32_t)(q ^ y) % 999) : 333u;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i65-intel-sum-sign-compare";
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
        static const char *const kWhat[3] = {"(x + C) < 0", "(x + C) > 0", "(x - C) < 0"};
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
                return FAIL(bug, "%s: %s in a branch wrong in %d of %d pixels (pixel %d: %u, want %u)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * 4 + k], want[k]);
            }
        }
        return PASS(bug, "%s: signed compares of a sum with zero in a fragment function are right where the sum wraps (%d pixels)", dev.name.UTF8String, W);
    }
}
