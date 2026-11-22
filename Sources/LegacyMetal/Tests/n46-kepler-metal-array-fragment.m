// n46-kepler-metal-array-fragment (Kepler adapter, NVAIR_ARRAY_STRUCT_FIX): n31-kepler-fragment-private-constant-loads's kernel with its private arrays written as
// metal::array<T, N>, as ANGLE writes every GLSL array (Chrome, Safari, Firefox WebGL): a struct holding the array, which
// reaches the back end as alloca {[N x T]} with GEPs (s, 0, 0, i) and slipped past the private-array fixes made for C
// arrays; they now see it as the plain array. Without the fix the original's bug is back.
// The original test's description follows.
// n31-kepler-fragment-private-constant-loads (Kepler adapter, NVAIR_PRIVATE_CONSTANT_GRAPHICS_FIX): n26's bug (loads of a
// private array at a constant index, merged across its variable-index stores) in a fragment function, where the fix had no thread position to make its opaque index from (mslfuzz2.py FRAG=1 seed 2136,
// the same body as the kernel of n26's seed, reduced). Fragment and vertex functions now make it from their position
// (the bits of position.x, a float of at least 0) or vertex_id. The reduced fragment function run as the fuzzer runs it
// (a full-screen triangle on a 256x1 target, one pixel per thread, t = position.x; the fuzzer's inputs, seed 1; compiled
// without fast math): each thread's 8 output words against the CPU reference (cpuref.py), as one FNV-1a hash per thread.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vfull(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); return float4(q * 2.0 - 1.0, 0.0, 1.0); }\n"
    "fragment float4 k(float4 pos [[position]], device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "    uint t = uint(pos.x);\n"
    "    metal::array<uint, 8> p;\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    metal::array<uchar, 8> pc;\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    pc[(((uint)((ushort)(((v3 ^ t) ^ v0))) * (uint)((ushort)(rotate(v3, (v4 ^ t)))))) & 7u] = (uchar)(max((uint)((int)(in[(t * 4u + 1u)]) / (int)((v5 | 1u) & 0x7fffffffu)), v4));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v5 = (uint)(pc[(256u) & 7u]);\n"
    "        if (((((((uint)((ushort)(in[(t * 4u + 1u)])) * (uint)((ushort)(in[(t * 4u + 3u)]))) % (addsat(1859741407u, in[(t * 4u + 0u)]) | 1u)))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        if (max((in[(t * 4u + 2u)] >> (v1 & 31u)), (v2 ^ t)) > (v0 ^ t)) {\n"
    "            v0 = (uint)(pc[((uint)((int)(popcount(2878952183u)) >> (int)(min(27u, 65535u) & 31u))) & 7u]);\n"
    "            pc[((uint)(-(int)(((v5 ^ t) >= v4 ? 224u : v3) & 0x7fffffffu))) & 7u] = (uchar)(madhi(((int)(v3) <= (int)(181u) ? in[(t * 4u + 0u)] : 90u), (uint)((short)((v3 ^ t))), madsat(in[(t * 4u + 1u)], (v3 ^ t), v2)));\n"
    "            v3 = rotate(((mulhi(in[(t * 4u + 3u)], in[(t * 4u + 0u)]) & 1u) != 0u ? (uint)((bool)(in[(t * 4u + 0u)] & (v3 ^ t))) : mulhi(in[(t * 4u + 2u)], in[(t * 4u + 3u)])), (uint)((uchar)((uint)(!(147u > (v3 ^ t)))) ^ (uchar)((uint)(select((int)(v3), (int)(v0), (2147483648u & 2u) != 0u)))));\n"
    "        } else {\n"
    "        }\n"
    "        if ((((extract_bits((v5 ^ t), (uint)(1u & 15u), (uint)(in[(t * 4u + 1u)] & 15u)) / ((uint)(!(in[(t * 4u + 1u)] > (v3 ^ t))) | 1u))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    v1 = (uint)((int)((uint)((int)((~in[(t * 4u + 2u)])) % (int)((in[(t * 4u + 3u)] | 1u) & 0x7fffffffu))) % (int)((((uint)(!((v4 ^ t) > in[(t * 4u + 2u)])) >> (madhi(2u, in[(t * 4u + 3u)], (v3 ^ t)) & 31u)) | 1u) & 0x7fffffffu));\n"
    "    pc[((v5 - (in[(t * 4u + 1u)] > in[(t * 4u + 1u)] ? in[(t * 4u + 2u)] : v1))) & 7u] = (uchar)(((in[(t * 4u + 1u)] % ((uint)((uchar)(171u) - (uchar)(v0)) | 1u))));\n"
    "    if ((((in[(t * 4u + 1u)] <= in[(t * 4u + 1u)] ? (v4 ^ t) : v4) & 1u) != 0u ? (uint)((int)(256u) / (int)(((v2 ^ t) | 1u) & 0x7fffffffu)) : ((int)(v0) >= (int)(in[(t * 4u + 2u)]) ? v2 : v4)) != ((v5 == (v0 ^ t) ? 200u : v1) > (v3 ^ t) ? (uint)((bool)(v5 & v5)) : (uint)((ushort)(v4) ^ (ushort)((v3 ^ t))))) {\n"
    "        v5 = (uint)((char)(rotate((uint)((uchar)((v1 ^ t)) >> (v5 & 7u)), (uint)(max((int)(215u), (int)(v1))))));\n"
    "    } else {\n"
    "    }\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        for (uint i1 = 0; i1 < 3u; i1++) {\n"
    "            pc[((uint)(!((uint)(!1u) > (uint)(min((int)(1488584632u), (int)(in[(t * 4u + 1u)])))))) & 7u] = (uchar)((uint)((ushort)((uint)(pc[(in[(t * 4u + 2u)]) & 7u])) >> ((v0 / ((v1 ^ t) | 1u)) & 7u)));\n"
    "            v1 = median3((uint)((int)(hadd(in[(t * 4u + 0u)], v4)) >> (int)(v2 & 31u)), (uint)(pc[((uint)((int)(164u) >> (int)((v1 ^ t) & 31u))) & 7u]), 597146317u);\n"
    "        }\n"
    "        if (((insert_bits(madsat((v0 ^ t), in[(t * 4u + 1u)], (v0 ^ t)), (4294967295u / (v4 | 1u)), (uint)(2160603766u & 15u), (uint)(((v3 ^ t) >> (3760739648u & 31u)) & 15u))) & 3u) == 0u) break; } v5 += n0; }\n"
    "    { uint4 w = uint4((((uint)((bool)(1559481389u & (v4 ^ t))) & 1u) != 0u ? 59u : ((v5 ^ t) << (in[(t * 4u + 1u)] & 31u))), v4, in[(t * 4u + 2u)], v3); w[((uint)((int)((uint)(-(int)(in[(t * 4u + 3u)] & 0x7fffffffu))) >> (int)((625942970u | in[(t * 4u + 0u)]) & 31u))) & 3u] = reverse_bits(max3(112u, in[(t * 4u + 3u)], v3)); v3 += w[((uint)(-(int)(((uint)((ushort)(118u)) * (uint)((ushort)((v1 ^ t)))) & 0x7fffffffu))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    // end\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = 0u;\n"
    "    return float4(0.0);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this function and input seed 1
static const uint32_t want[256] = {
    0xf8117831u, 0x26b7c0e1u, 0xf2a10935u, 0x04aa628au, 0x6dfd4a28u, 0x2ca495f1u, 0xaf72058bu, 0x99710423u,
    0xa90331ebu, 0xc771a35bu, 0xfaad0dc8u, 0x9ca5e3b8u, 0x339c7084u, 0x3602e0d9u, 0x724bc1bbu, 0x7adac050u,
    0x93869ddcu, 0x834ce252u, 0xe7c09c23u, 0x2b3eb88du, 0x6e7793ebu, 0xe738eddbu, 0xb53d2325u, 0x9df36af8u,
    0xf4f21f06u, 0xbe5ec2cfu, 0x7d8c1ec6u, 0x7c2fb4ceu, 0x765de990u, 0x90048ee5u, 0x3871f4e0u, 0x34471cc2u,
    0x3cea14e1u, 0x13478f76u, 0x5cabe04fu, 0x61fee6aau, 0xc10db019u, 0xc07a0e56u, 0x9c36269bu, 0xde11325du,
    0xa7d90d48u, 0x46f36839u, 0xba0ac0efu, 0x280baa0bu, 0x31d2435eu, 0xd7ef791bu, 0x54eea3aau, 0x6402187eu,
    0xc5d80fc6u, 0x404c6d2au, 0xd1b1c337u, 0x89fc73b3u, 0xb54dfdb9u, 0xc0696917u, 0x04f6be9du, 0x1bb6a55au,
    0xf5dbe3eau, 0xfef38c84u, 0x63dadfe7u, 0x6a76b369u, 0xf3ecbcbfu, 0x844a5ccau, 0x70ed43c5u, 0xb72e7ff0u,
    0xbb656407u, 0x6fe34b41u, 0x58d5f4eeu, 0xc04be9fbu, 0xe7af1377u, 0x7aaa9f85u, 0x14e713e7u, 0x5c0fdf66u,
    0x312343b0u, 0x88505091u, 0xdea2ea2cu, 0x460706fdu, 0xad4f3205u, 0x9b0c00f3u, 0x82b6c384u, 0x9913b163u,
    0x096ef272u, 0x60f8fb18u, 0x3583f28du, 0xb10748cbu, 0x0378a348u, 0x35c20b7fu, 0x4637d272u, 0x6cfde0d9u,
    0x304dca3cu, 0xf56234cau, 0xd7440cf2u, 0xe1552f7cu, 0x95e298bau, 0x7ddb8876u, 0x51180466u, 0xf9812aebu,
    0x37d63147u, 0xae480248u, 0x396eb200u, 0x1e11ece5u, 0x6effe8b8u, 0x4d970afdu, 0xdcfb0653u, 0x69103a9eu,
    0x226575f3u, 0xb1484800u, 0xd10910d4u, 0x04721d0cu, 0xfc73c2bfu, 0x90d9406cu, 0xbf0f830fu, 0x610e2e5bu,
    0x8969b3aeu, 0x680c8089u, 0x9bdfe8a0u, 0xfe6e61e1u, 0x10980894u, 0x371d6c14u, 0x45a18fc7u, 0x082d2d47u,
    0x2271cbdeu, 0x6deae435u, 0xfb7e2ee1u, 0x5c7bfc1cu, 0x5c307d98u, 0x4882fd18u, 0xf47a9e55u, 0x88301966u,
    0x11d2e105u, 0xfdb6c608u, 0x1ff99992u, 0xa5f6b8bcu, 0x031f79c7u, 0xb2822235u, 0xa9d8eaa1u, 0x06104e95u,
    0x2af726e5u, 0x314f1d7eu, 0xefce0d56u, 0xe89b02f4u, 0x0a84a8b6u, 0x84353bd7u, 0x1b9f02ebu, 0x84dba600u,
    0xcde88e19u, 0x0135980eu, 0x6ac4e125u, 0x9818fe43u, 0x46248550u, 0x6b1104cfu, 0x8d28b26au, 0xc4f37ca3u,
    0x61a72babu, 0xb26728cau, 0x6f53728fu, 0xb66581f1u, 0x9fdd79acu, 0x7b66aceeu, 0x2e8ba264u, 0x4266304du,
    0xd88da147u, 0x2b50c772u, 0x2a286e56u, 0x09c99cfcu, 0xd89fb35du, 0x33d0ac30u, 0x808b0d84u, 0x6d6e1f8cu,
    0xa5e5f742u, 0xb9d4a681u, 0xc53bb756u, 0x5b91d7e4u, 0x03294eeeu, 0x05b10361u, 0xe10adb53u, 0xde0dbebeu,
    0xbea887b3u, 0x08150c4au, 0x2be24917u, 0x474baaebu, 0x34c17b7cu, 0xc8c5ac25u, 0x2f976388u, 0x06e4737au,
    0x3b7c1d4au, 0x72e0ee5du, 0x22ebe7bfu, 0x632efe3bu, 0x8255132eu, 0xd99e67c4u, 0x099479a7u, 0x6983f4d2u,
    0x901d073du, 0xad3094e2u, 0x9fabe357u, 0xb0fa020au, 0xbffb7342u, 0x0147970fu, 0x52d1c90au, 0x2d5f2c97u,
    0x9143615du, 0x2a525a09u, 0x235cf22fu, 0xe066a5fcu, 0xb8135b44u, 0xb0357749u, 0x8768f0f2u, 0x5abafea1u,
    0x72cd06c3u, 0x9ae212d8u, 0x13fd9ddau, 0x761d70deu, 0xfe31e38bu, 0xca0a4d1fu, 0xbd785aefu, 0x56ea4317u,
    0x9a8a0653u, 0xd887cd43u, 0x0da1bd94u, 0xb79b20a0u, 0x5109a43eu, 0x2b250d27u, 0x7021ae52u, 0xe66bbe81u,
    0x62b1a82fu, 0x0fcd1749u, 0x699d34d3u, 0x27766844u, 0xb05738a6u, 0x1459a31fu, 0x610c5cf1u, 0x116abf2bu,
    0xe623f5e4u, 0xcf1d4230u, 0x4e6cc25fu, 0xaae6536au, 0xf86f26feu, 0x2b202c2bu, 0xa5d4e941u, 0x1bbd2745u,
    0x6ea4e841u, 0xaf48fdbeu, 0x1f50b207u, 0xa81f24b9u, 0xc54e7020u, 0x99f42643u, 0x648edb9bu, 0x15352766u,
    0xa2592457u, 0x40cb19e6u, 0x808016f8u, 0x32af2fe0u, 0xbf65039au, 0x22201fc3u, 0xdb09f57eu, 0x56a5ea51u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n46-kepler-metal-array-fragment";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;  // as the fuzzer compiles
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vfull"];
    rd.fragmentFunction = [lib newFunctionWithName:@"k"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t x = 1u * 2654435761u + 12345u;  // the fuzzer's inputs, seed 1
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:T height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    [re setRenderPipelineState:ps];
    [re setFragmentBuffer:in offset:0 atIndex:0];
    [re setFragmentBuffer:out offset:0 atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *o = out.contents;
    int wrong = 0, first = -1;
    for (int t = 0; t < T; t++) {
        uint32_t h = 2166136261u;
        for (int w = 0; w < 8; w++)
            for (int b = 0; b < 4; b++) { h ^= (o[t * 8 + w] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != want[t]) { wrong++; if (first < 0) first = t; }
    }
    if (wrong) return FAIL(bug, "%s: %d of %d pixels differ from the CPU reference (first: pixel %d)", name, wrong, T, first);
    return PASS(bug, "%s: constant-index accesses of a private array in a fragment function see its variable-index stores", name);
}}
