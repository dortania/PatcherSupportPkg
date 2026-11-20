// n30-kepler-saturating-multiply-add (Kepler adapter, NVAIR_MAD_SAT_FIX): madsat(a, b, c) in a big kernel. With a = 0,
// b = 0xfffffffe it came out saturated (0xffffffff) instead of c, for one thread of 256 (mslfuzz2.py LONG=1 seed 2245,
// reduced: v0 ^= rotate(madsat(a, (uint)(-2), rotate(187855064u, 0xffffffffu)), ...)). The plugin's own body did it, and
// so did a plain i64 a * b + c: the high word came out nonzero for a product of 0, as a carry into it would make it,
// while every small kernel with the same operands was right. The reduced kernel on the fuzzer's inputs (seed 1, 256
// threads in groups of 64, compiled without fast math, as the fuzzer does): each thread's 8 output words against the CPU
// reference (cpuref.py), as one FNV-1a hash per thread.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup uint tg[64];\n"
    "    threadgroup uchar tc[64];\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    { uint4 w = uint4((uint)(!(rotate((v3 ^ t), (v4 ^ t)) > ((uint)((ushort)(3628925667u)) * (uint)((ushort)(v5))))), v4, (uint)(mulhi((((ulong)((uint)(pc[(93u) & 7u])) << 32) | (ulong)(rhadd(255u, (v5 ^ t)))), (((ulong)(1u) << 32) | (ulong)(rotate((v5 ^ t), 39u)))) >> 10), v5); w[(((uint)((ushort)(median3(in[(t * 4u + 1u)], in[(t * 4u + 2u)], in[(t * 4u + 1u)]))) * (uint)((ushort)(((uint)((int)((short)(v4))) + (v5 ^ t)))))) & 3u] = ((uint)((bool)((v5 ^ t) & 107u)) | in[(t * 4u + 2u)]); v0 += w[((uint)((long)((((ulong)((uint)(pc[(v3) & 7u])) << 32) | (ulong)((uint)(select((int)((v2 ^ t)), (int)((v2 ^ t)), ((v3 ^ t) & 2u) != 0u))))) >> (((uint)((ushort)(v5)) * (uint)((ushort)(in[(t * 4u + 0u)]))) & 63u))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    v5 -= (uint)(min((((ulong)(madsat((((v0 ^ t) & 1u) != 0u ? in[(t * 4u + 0u)] : v4), (in[(t * 4u + 2u)] << (5391092u & 31u)), ((v5 ^ t) > (v0 ^ t) ? in[(t * 4u + 3u)] : 234u))) << 32) | (ulong)(in[(t * 4u + 0u)])), (((ulong)((((((ulong)(max(v1, in[(t * 4u + 2u)])) << 32) | (ulong)(((v4 ^ t) < (v1 ^ t) ? (v4 ^ t) : (v3 ^ t))))) > ((((ulong)((uint)((int)((v0 ^ t)) / (int)(((v3 ^ t) | 1u) & 0x7fffffffu))) << 32) | (ulong)((uint)((int)(v4) >> (int)(2147483647u & 31u))))) ? ((uint)((int)((short)((v0 ^ t)))) * (v4 ^ t)) : (v1 / ((v2 ^ t) | 1u)))) << 32) | (ulong)(min3((uint)((int)((v3 ^ t)) % (int)((2147483647u | 1u) & 0x7fffffffu)), ((uint)((ushort)(693710130u)) * (uint)((ushort)(155u))), (v0 ^ t))))) >> 10);\n"
    "    v4 = ((uint)((int)((char)((uint)(((long)((((ulong)((uint)(pc[(4294967295u) & 7u])) << 32) | (ulong)(((uint)((int)((short)(255u))) - 65536u)))) >= (long)((((ulong)((v5 ^ t)) << 32) | (ulong)(popcount(in[(t * 4u + 2u)]))))) ? ((((ulong)((uint)(pc[(4294967295u) & 7u])) << 32) | (ulong)(((uint)((int)((short)(255u))) - 65536u)))) >> 7 : ((((ulong)((v5 ^ t)) << 32) | (ulong)(popcount(in[(t * 4u + 2u)])))) >> 11)))) + (uint)((((((ulong)((v5 < in[(t * 4u + 1u)] ? in[(t * 4u + 1u)] : (v0 ^ t))) << 32) | (ulong)(insert_bits(v0, 509156597u, (uint)(v3 & 15u), (uint)((v0 ^ t) & 15u))))) * ((((ulong)((in[(t * 4u + 0u)] >= 3443890763u ? in[(t * 4u + 3u)] : 1044657421u)) << 32) | (ulong)((uint)((ushort)(96u) | (ushort)(31u)))))) >> 53));\n"
    "    v0 = (uint)((((((ulong)((~max3(4u, (v4 ^ t), in[(t * 4u + 0u)]))) << 32) | (ulong)((uint)((int)(in[(t * 4u + 1u)]) / (int)((256u | 1u) & 0x7fffffffu))))) * ((((ulong)((((((ulong)((uint)((uchar)(1195291410u) >> (128u & 7u))) << 32) | (ulong)((uint)(min((int)(v4), (int)(v3)))))) <= ((((ulong)((((v1 ^ t) & 1u) != 0u ? (v1 ^ t) : v1)) << 32) | (ulong)((((v4 ^ t) & 1u) != 0u ? 0u : in[(t * 4u + 1u)])))) ? (uint)(min((int)(v5), (int)(11u))) : (uint)((int)(v0) / (int)(((v1 ^ t) | 1u) & 0x7fffffffu)))) << 32) | (ulong)(subsat(max(in[(t * 4u + 2u)], in[(t * 4u + 0u)]), (uint)((int)(173u) / (int)(((v2 ^ t) | 1u) & 0x7fffffffu))))))) >> 60);\n"
    "    v5 = (uint)((((((ulong)((uint)((bool)((v3 ^ t) & ((in[(t * 4u + 1u)] % ((v3 ^ t) | 1u)))))) << 32) | (ulong)(rotate((182u / (v0 | 1u)), (uint)((uchar)((v1 ^ t)) >> (in[(t * 4u + 2u)] & 7u)))))) % (((((ulong)((uint)((short)((uint)((ushort)((v2 ^ t)))))) << 32) | (ulong)((((int)(v0) > (int)((v2 ^ t)) ? (v0 ^ t) : in[(t * 4u + 0u)]) << ((uint)((int)((v2 ^ t)) % (int)((in[(t * 4u + 2u)] | 1u) & 0x7fffffffu)) & 31u))))) | 1ul)) >> 0);\n"
    "    v0 ^= rotate(madsat(((uint)((int)((char)((v4 ^ t)))) + (v4 ^ t)), (uint)(-(int)(2u & 0x7fffffffu)), rotate(187855064u, 4294967295u)), ((uint)((int)((v4 ^ t)) / (int)((130u | 1u) & 0x7fffffffu)) > max3((v2 ^ t), v2, in[(t * 4u + 2u)]) ? insert_bits((v3 ^ t), 3444842203u, (uint)(in[(t * 4u + 3u)] & 15u), (uint)((v4 ^ t) & 15u)) : rotate(786195382u, 3419594621u)));\n"
    "    v2 += (uint)((long)((((ulong)(v3) << 32) | (ulong)(max(max(v2, 65536u), ((uint)((ushort)(v3)) * (uint)((ushort)(in[(t * 4u + 0u)]))))))) / (long)((((((ulong)(reverse_bits((uint)((bool)((v3 ^ t) & 0u)))) << 32) | (ulong)(median3(rhadd(v0, (v2 ^ t)), (uint)(pc[(v3) & 7u]), rotate(in[(t * 4u + 3u)], v2))))) & 0x7ffffffffffffffful) | 1ul));\n"
    "    v4 += ((uint)((long)((((ulong)((uint)((uchar)((v2 ^ t)) >> ((v1 ^ t) & 7u))) << 32) | (ulong)((uint)(select((int)((v4 ^ t)), (int)(v4), (93u & 2u) != 0u))))) >> ((uint)((uchar)(404443119u) >> (57u & 7u)) & 63u)) >= (uint)((int)((uint)(!(3604496540u > in[(t * 4u + 1u)]))) >> (int)(min(in[(t * 4u + 2u)], in[(t * 4u + 0u)]) & 31u)) ? ((extract_bits(255u, (uint)(v5 & 15u), (uint)(v2 & 15u)) % ((uint)((int)(v0) >> (int)(v0 & 31u)) | 1u))) : (uint)(mulhi((((ulong)(v3) << 32) | (ulong)(((int)(38u) >= (int)(in[(t * 4u + 2u)]) ? 103u : 3117507755u))), (((ulong)(((int)(v0) > (int)((v3 ^ t)) ? in[(t * 4u + 0u)] : in[(t * 4u + 0u)])) << 32) | (ulong)((uint)((int)(v0) / (int)((v5 | 1u) & 0x7fffffffu))))) >> 2));\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0x4bf7ab69u, 0x2f0864f7u, 0x35650ad1u, 0xc06a10a1u, 0xf53780feu, 0xae0427e6u, 0x1e98b59au, 0x844a40a9u,
    0xae76f5ebu, 0x89721faau, 0x47555cbbu, 0x3bdc8702u, 0x9af993d4u, 0xb8868cd0u, 0xf4193687u, 0xa281cabcu,
    0xce49c3fau, 0xd95ca3a5u, 0xabcd2e79u, 0x87d97a2eu, 0xb5be7b30u, 0x9deac317u, 0x7c44057eu, 0xabef6869u,
    0x71489be0u, 0xeec24c4au, 0xc36f30f6u, 0xf0ad61cfu, 0x86b055c9u, 0xd1331e4cu, 0x7d92a0ccu, 0x85af13d2u,
    0x0b99e026u, 0x86be12f4u, 0x21e2f368u, 0xc1d00246u, 0x2677002eu, 0x78b1610bu, 0x6dc14ac4u, 0xc2e00fa8u,
    0x707647a5u, 0xe874f8e5u, 0xd596954cu, 0xd7d2c87fu, 0x4e45c953u, 0x7852c47eu, 0xc80bbc56u, 0x6f5a9816u,
    0xde55e186u, 0x0ae68580u, 0x133ad1b5u, 0xe3c91685u, 0xe0ded44bu, 0x0e5102e0u, 0x01cc12c4u, 0x8649e8a7u,
    0x560281f3u, 0xf38aee10u, 0xd43e9406u, 0x3e8c8952u, 0x1c8c01beu, 0x189dd55du, 0xc13d028cu, 0xd46c1fdcu,
    0xd68c750eu, 0x49cefa1eu, 0x4b424fbdu, 0xe31b2656u, 0x247ae79cu, 0x0bf3622cu, 0x303a4831u, 0x39771b07u,
    0x9437c4f8u, 0x1eb9564du, 0xb14261d3u, 0x84597e06u, 0x3de36a0bu, 0x339ab53fu, 0x9ea6d6bdu, 0x0b20c9f9u,
    0xc6400c1cu, 0x40bb1e45u, 0xcf86c1c3u, 0xe70e8ebbu, 0x549bbaacu, 0xa713c63eu, 0x0a369687u, 0xb7380e56u,
    0x4b8f0ac8u, 0x92f0ef8au, 0x729458ccu, 0x2a74f474u, 0xaaeaa27cu, 0xe9545e30u, 0x931ffd31u, 0x510a2b15u,
    0xe43ad268u, 0x997150d1u, 0x91eb42ebu, 0xa1535715u, 0x80157c0fu, 0x48c6698du, 0x50d22ad7u, 0xd53b4a3cu,
    0xa19d68bau, 0x01e1475au, 0x4f4218fau, 0xf1017147u, 0x097b7f02u, 0x2c52005au, 0xd34849eeu, 0x2acac3ceu,
    0x01956517u, 0x802b63f3u, 0x867ab0a6u, 0x7b51f317u, 0x277046deu, 0xc1683dfdu, 0x78b499d5u, 0x8a005e57u,
    0x68f41336u, 0x3ac20e0du, 0xf541f572u, 0xd16c58cdu, 0x448bc007u, 0x4f3e4662u, 0x7377f9dbu, 0x9c8d32d2u,
    0xc3ffbff8u, 0xa9d8db8cu, 0x6eb9e241u, 0x2f211d01u, 0x1d75a9f9u, 0x69003233u, 0xc6e03504u, 0x76bfabb5u,
    0x63be399bu, 0x679c05cau, 0xa5cc43dcu, 0xb09a6de2u, 0xd7736cf7u, 0xd855070cu, 0xc4faeb36u, 0x5a058ed7u,
    0x041448ccu, 0x2180c1a1u, 0xa2b939e1u, 0xc441b091u, 0xb816b9edu, 0xc54a2c5au, 0x6fd6605cu, 0x1c835e3bu,
    0x0a78df7cu, 0xf68cfb2au, 0x1b4527a2u, 0xa0b241d9u, 0x1f3bafdbu, 0x98058ca2u, 0xfb3a0c7cu, 0x35d2e33bu,
    0x0260abd8u, 0xf9334414u, 0xd24f9b98u, 0xc205a9ebu, 0xa22b7211u, 0x46581e66u, 0xec7f4a25u, 0x48e18db8u,
    0x570c9214u, 0x7e8def58u, 0xb501d5d3u, 0x45d92aa7u, 0xadcb1ab0u, 0xb8d6167fu, 0x5274e8b3u, 0x4f922b53u,
    0xfe6d3411u, 0x03aa8863u, 0xf986ad2fu, 0x8285a2bbu, 0x22cd5aa1u, 0x2a881da9u, 0x02c78f0cu, 0x8ff5473au,
    0xde86dc2bu, 0x13b50b70u, 0x9492b6b7u, 0x617d30b7u, 0xc20e3f44u, 0xc817924fu, 0xaf76d86eu, 0x8ba33a7bu,
    0xf139700cu, 0x9e243c8au, 0x7553d0dbu, 0x2ccdf56du, 0xdc5f807eu, 0x4ad05d9eu, 0xae4d43a8u, 0xd586a42cu,
    0xd2db48e6u, 0xb56a7a5du, 0x987ad96bu, 0x169c388bu, 0xfd60931du, 0xf91dec37u, 0x86b31b6fu, 0x123abbabu,
    0xbb5c0389u, 0x8593039bu, 0x5ced129cu, 0x07ce2bc1u, 0xe0e11b45u, 0x7ae421c6u, 0x5386f22du, 0xdb3044abu,
    0xf4362ae9u, 0xab7a8c75u, 0x89c26ff9u, 0x6b018ecdu, 0x122ab068u, 0x98c6ee94u, 0x0a149c82u, 0x324613f7u,
    0x32c4ea60u, 0x78924484u, 0x120eba36u, 0x92386df7u, 0x26efd3c4u, 0x072fcadbu, 0xd25907b1u, 0x329111c2u,
    0x5732353cu, 0xc57cc751u, 0x1e542e58u, 0x883e16a2u, 0x13b8d0dau, 0xdf8a33dfu, 0x2bb71540u, 0x0ce944bdu,
    0x5f3a3f5eu, 0x69e8c768u, 0x00e51aebu, 0xe7972c1bu, 0x3e85cc6du, 0x5883db12u, 0x54316bf3u, 0xa528a972u,
    0x8e4c1f98u, 0x063a4c1bu, 0x12e8e7bcu, 0x0c7b0e92u, 0xb1f467c0u, 0x2237cc68u, 0xd10f57b1u, 0xf160f56au
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n30-kepler-saturating-multiply-add";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;  // as the fuzzer compiles
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 4 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 8 * 4 options:MTLResourceStorageModeShared];
    uint32_t x = 1u * 2654435761u + 12345u;  // the fuzzer's inputs, seed 1
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint32_t *)in.contents)[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, out.length);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:in offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(T / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const uint32_t *o = out.contents;
    int wrong = 0, first = -1;
    for (int t = 0; t < T; t++) {
        uint32_t h = 2166136261u;
        for (int w = 0; w < 8; w++)
            for (int b = 0; b < 4; b++) { h ^= (o[t * 8 + w] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != want[t]) { wrong++; if (first < 0) first = t; }
    }
    if (wrong) return FAIL(bug, "%s: %d of %d threads differ from the CPU reference (first: thread %d)", name, wrong, T, first);
    return PASS(bug, "%s: madsat gives a * b + c clamped, in a big kernel too", name);
}}
