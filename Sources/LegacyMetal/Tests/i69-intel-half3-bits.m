// i69-intel-half3-bits (Intel adapter, IntelTextureAtomics.dylib): bitwise operations on the bits of a half3 in fragment
// functions with the 3802 Intel compiler. as_type<ushort3>(half3) & ushort3(0x7FFF) (and | of sign bits, >> 3) crashed
// the compiler service: a 48-bit vector made with as_type, which the byte/halfword-vector rewrite (i66) extended as a whole.
// RenderBox (SwiftUI's renderer) has exactly this in its resolve shaders (a sign-preserving color transfer), so those
// pipeline variants failed with "Compiler encountered an internal error". Found by scanning the system's metallibs for
// the IR the Intel fixes act on. Each pixel of a 256x1 target writes the abs, the sign-copied and the shifted bits of
// its own half3 to a buffer. Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "  uint p = uint(pos.x), x = w[p * 4u], y = w[p * 4u + 1u], z = w[p * 4u + 2u];\n"
    "  half3 c = half3(float3(float(x & 1023u), float(y & 1023u), float(z & 1023u)) * 0.125f - 64.0f);\n"
    "  ushort3 u = as_type<ushort3>(c), s = as_type<ushort3>(c.zxy);\n"
    "  half3 a = as_type<half3>(u & ushort3(0x7FFF));\n"
    "  half3 m = as_type<half3>((u & ushort3(0x7FFF)) | (s & ushort3(0x8000)));\n"
    "  ushort3 h = u >> 3;\n"
    "  device uint *o = out + p * 8u;\n"
    "  o[0] = as_type<uint>(half2(a.xy)); o[1] = uint(as_type<ushort>(a.z));\n"
    "  o[2] = as_type<uint>(half2(m.xy)); o[3] = uint(as_type<ushort>(m.z));\n"
    "  o[4] = uint(h.x) | (uint(h.y) << 16); o[5] = uint(h.z); o[6] = 0u; o[7] = 0u;\n"
    "  return uint4(p);\n"
    "}\n";

enum { W = 256, kWords = 8 };

static uint16_t halfBits(float f) { __fp16 h = (__fp16)f; uint16_t b; memcpy(&b, &h, 2); return b; }

static void reference(const uint32_t *in, uint32_t r[kWords]) {
    uint16_t u[3], s[3], a[3], m[3], h[3];
    for (int k = 0; k < 3; k++) u[k] = halfBits((float)(in[k] & 1023) * 0.125f - 64.0f);
    s[0] = u[2], s[1] = u[0], s[2] = u[1];
    for (int k = 0; k < 3; k++) a[k] = u[k] & 0x7FFF, m[k] = (u[k] & 0x7FFF) | (s[k] & 0x8000), h[k] = u[k] >> 3;
    r[0] = a[0] | (uint32_t)a[1] << 16, r[1] = a[2], r[2] = m[0] | (uint32_t)m[1] << 16, r[3] = m[2];
    r[4] = h[0] | (uint32_t)h[1] << 16, r[5] = h[2], r[6] = 0, r[7] = 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i69-intel-half3-bits";
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
        uint32_t *in = words.contents, x = 2654435761u + 69u;
        for (int i = 0; i < W * 4; i++) x ^= x << 13, x ^= x >> 17, x ^= x << 5, in[i] = x;
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
        static const char *const kWhat[3] = {"abs of the bits", "sign copied from another lane", "bits shifted right"};
        for (int k = 0; k < 3; k++) {
            int wrong = 0, first = -1;
            for (int p = 0; p < W; p++) {
                uint32_t want[kWords];
                reference(in + p * 4, want);
                if (got[p * kWords + 2 * k] != want[2 * k] || got[p * kWords + 2 * k + 1] != want[2 * k + 1]) wrong++, first = first < 0 ? p : first;
            }
            if (wrong) {
                uint32_t want[kWords];
                reference(in + first * 4, want);
                return FAIL(bug, "%s: %s wrong in %d of %d pixels (pixel %d: %08x %04x, want %08x %04x)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * kWords + 2 * k], got[first * kWords + 2 * k + 1], want[2 * k], want[2 * k + 1]);
            }
        }
        return PASS(bug, "%s: bitwise operations on the bits of a half3 in a fragment function compile and are right (%d pixels)", dev.name.UTF8String, W);
    }
}
