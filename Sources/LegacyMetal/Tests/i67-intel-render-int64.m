// i67-intel-render-int64 (Intel adapter, IntelTextureAtomics.dylib): 64-bit division, remainder and shifts by a variable
// amount in fragment functions with the 3802 Intel compiler. ulong / ulong, long / long, % and ulong >> (y & 63) crashed
// the compiler service in a vertex or fragment function (compute functions are right; 64-bit add, mul and shifts by a
// constant were fine). Found by fuzzing fragment functions with 64-bit values. Each pixel of a 256x1 target writes 32
// words for its own inputs to a buffer: unsigned and signed quotients and remainders (divisors with high words of 0, a
// few bits, all bits and the top bit, small negative ones, a constant), the three shifts by every amount 0-63, and ulong2
// division and shifts. Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { return float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1); }\n"
    "void put(device uint *o, ulong v) { o[0] = (uint)v; o[1] = (uint)(v >> 32); }\n"
    "fragment uint4 f(float4 pos [[position]], device const uint *w [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "  uint p = uint(pos.x), x = w[p * 4u], y = w[p * 4u + 1u], z = w[p * 4u + 2u], q = w[p * 4u + 3u];\n"
    "  device uint *o = out + p * 32u;\n"
    "  uint dh = (q & 3u) == 0u ? 0u : (q & 3u) == 1u ? q >> 28 : (q & 3u) == 2u ? q : q | 0x80000000u;\n"
    "  ulong a = (ulong)x << 32 | y, d = (ulong)dh << 32 | (z | 1u);\n"
    "  long sa = (long)a, sd = (long)d, small = (long)(int)(z | 1u);\n"
    "  uint s = p < 64u ? p : y & 63u;\n"
    "  put(o, a / d); put(o + 2, a % d);\n"
    "  put(o + 4, (ulong)(sa / sd)); put(o + 6, (ulong)(sa % sd));\n"
    "  put(o + 8, (ulong)(sa / small)); put(o + 10, (ulong)(sa % small));\n"
    "  put(o + 12, a << s); put(o + 14, a >> s); put(o + 16, (ulong)(sa >> s));\n"
    "  put(o + 18, a / 1000003ul);\n"
    "  ulong2 v = ulong2(a, d) / ulong2(d, (ulong)(q | 1u));\n"
    "  put(o + 20, v.x); put(o + 22, v.y);\n"
    "  ulong2 t = ulong2(a, d) >> ulong2(s, (ulong)(q & 63u));\n"
    "  put(o + 24, t.x); put(o + 26, t.y);\n"
    "  put(o + 28, (ulong)(sa >> (long)(z & 63u)) ^ (a << (ulong)(q >> 26)));\n"
    "  put(o + 30, (a % (ulong)(q | 1u)) + (a / (ulong)(q | 1u)));\n"
    "  return uint4(p);\n"
    "}\n";

enum { W = 256, kWords = 32 };

static void put(uint32_t *o, uint64_t v) { o[0] = (uint32_t)v, o[1] = (uint32_t)(v >> 32); }

static void reference(int p, const uint32_t *in, uint32_t r[kWords]) {
    uint32_t x = in[0], y = in[1], z = in[2], q = in[3];
    uint32_t dh = (q & 3) == 0 ? 0 : (q & 3) == 1 ? q >> 28 : (q & 3) == 2 ? q : q | 0x80000000u;
    uint64_t a = (uint64_t)x << 32 | y, d = (uint64_t)dh << 32 | (z | 1u);
    int64_t sa = (int64_t)a, sd = (int64_t)d, small = (int64_t)(int32_t)(z | 1u);
    uint32_t s = p < 64 ? (uint32_t)p : y & 63;
    put(r, a / d), put(r + 2, a % d);
    put(r + 4, (uint64_t)(sa / sd)), put(r + 6, (uint64_t)(sa % sd));
    put(r + 8, (uint64_t)(sa / small)), put(r + 10, (uint64_t)(sa % small));
    put(r + 12, a << s), put(r + 14, a >> s), put(r + 16, (uint64_t)(sa >> s));
    put(r + 18, a / 1000003u);
    put(r + 20, a / d), put(r + 22, d / (uint64_t)(q | 1u));
    put(r + 24, a >> s), put(r + 26, d >> (q & 63));
    put(r + 28, (uint64_t)(sa >> (z & 63)) ^ (a << (q >> 26)));
    put(r + 30, a % (uint64_t)(q | 1u) + a / (uint64_t)(q | 1u));
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i67-intel-render-int64";
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
        uint32_t *in = words.contents, x = 2654435761u + 4242u;  // xorshift, every 7th word a byte
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
        static const char *const kWhat[kWords / 2] = {"ulong /", "ulong %", "long /", "long %", "long / small negative", "long % small negative",
                                                      "ulong << variable", "ulong >> variable", "long >> variable", "ulong / constant",
                                                      "ulong2 / (x)", "ulong2 / (y)", "ulong2 >> (x)", "ulong2 >> (y)", "long >> and ulong <<",
                                                      "ulong % and / together"};
        for (int k = 0; k < kWords / 2; k++) {
            int wrong = 0, first = -1;
            for (int p = 0; p < W; p++) {
                uint32_t want[kWords];
                reference(p, in + p * 4, want);
                if (got[p * kWords + 2 * k] != want[2 * k] || got[p * kWords + 2 * k + 1] != want[2 * k + 1]) wrong++, first = first < 0 ? p : first;
            }
            if (wrong) {
                uint32_t want[kWords];
                reference(first, in + first * 4, want);
                return FAIL(bug, "%s: %s wrong in %d of %d pixels (pixel %d: %08x%08x, want %08x%08x)", dev.name.UTF8String, kWhat[k], wrong, W, first,
                            got[first * kWords + 2 * k + 1], got[first * kWords + 2 * k], want[2 * k + 1], want[2 * k]);
            }
        }
        return PASS(bug, "%s: 64-bit division, remainder and variable shifts in a fragment function compile and are right (%d pixels)",
                    dev.name.UTF8String, W);
    }
}
