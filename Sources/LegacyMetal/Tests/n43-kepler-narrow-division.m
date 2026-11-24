// n43-kepler-narrow-division: divisions and remainders of 8- and 16-bit values must be right; the back end got them
// wrong. Fix: GeForceAIRCompat NVAIR_NARROW_DIVISION_FIX. Checks: the reduced fuzz kernel (seed 4339) against the CPU
// reference (cpuref.py), 256 threads. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "static uint vf(uchar2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(uchar4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(char3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(ushort2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(ushort3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(ushort4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(short3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }\n"
    "static uint vf(short4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    uint dbg0 = 0xdeadu, dbg1 = 0xdeadu;\n"
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
    "    if ((uint)((int)((ushort)(in[(t * 4u + 1u)]) >> (popcount(v2) & 15u))) < extract_bits((uint)(!(v2 > 124u)), (uint)(((v3 ^ t) * 2451535531u) & 15u), (uint)((uint)(select((int)((v3 ^ t)), (int)((v5 ^ t)), (in[(t * 4u + 2u)] & 2u) != 0u)) & 15u))) {\n"
    "        v5 ^= p[((uint)((int)((short)((uint)((ushort)(v2) - (ushort)((v3 ^ t)))) / (short)((((v4 ^ t) < v4 ? in[(t * 4u + 1u)] : 65536u) & 32767u) | 1u)))) & 7u];\n"
    "        pc[((uint)(any((uchar2((uchar)(extract_bits(in[(t * 4u + 1u)], (uint)(1466008005u & 15u), (uint)((v5 ^ t) & 15u))), (uchar)(mulhi(v3, 2147483647u))) - uchar2((uchar)(ctz((v2 ^ t))), (uchar)(v1))) >= (uchar2((uchar)(24), (uchar)(167))).yx))) & 7u] = (uchar)(popcount(addsat((v0 ^ t), v5)));\n"
    "        if (((uint)((int)((short)((uint)(select((int)(v4), (int)(1870689297u), (1931496821u & 2u) != 0u))))) + (uint)(!(in[(t * 4u + 3u)] > v4))) > (((uint)((int)((v0 ^ t)) % (int)(((v2 ^ t) | 1u) & 0x7fffffffu)) & 1u) != 0u ? ((uint)((int)((char)(v4))) - 2147483647u) : (~v4))) {\n"
    "            atomic_fetch_add_explicit(&ta, (vf(((max(ushort2((ushort)(1240), (ushort)(12807)), ushort2((ushort)(48038), (ushort)(44363))) & as_type<ushort2>(uchar4((uchar)((uint)(-(int)(2114508870u & 0x7fffffffu))), (uchar)((uint)(!((v2 ^ t) > in[(t * 4u + 3u)]))), (uchar)((uint)((int)(v4) >> (int)(in[(t * 4u + 3u)] & 31u))), (uchar)((in[(t * 4u + 1u)] | in[(t * 4u + 0u)])))))))) & 255u, memory_order_relaxed);\n"
    "            v2 = 2u;\n"
    "            p[((uint)(((long)((((ulong)(((in[(t * 4u + 1u)] & 1u) != 0u ? v5 : 222u)) << 32) | (ulong)((uint)(!(v3 > in[(t * 4u + 3u)]))))) > (long)((((ulong)(hadd(in[(t * 4u + 3u)], (v2 ^ t))) << 32) | (ulong)(max((v1 ^ t), v3))))) ? ((((ulong)(((in[(t * 4u + 1u)] & 1u) != 0u ? v5 : 222u)) << 32) | (ulong)((uint)(!(v3 > in[(t * 4u + 3u)]))))) >> 7 : ((((ulong)(hadd(in[(t * 4u + 3u)], (v2 ^ t))) << 32) | (ulong)(max((v1 ^ t), v3)))) >> 11)) & 7u] = (((uint)((ushort)(v4)) * (uint)((ushort)(in[(t * 4u + 0u)]))) / ((in[(t * 4u + 2u)] != 162u ? 193u : v3) | 1u));\n"
    "        }\n"
    "    } else {\n"
    "        v1 ^= p[((uint)((ushort)(popcount(36u)) >> ((uint)(min((int)(0u), (int)(in[(t * 4u + 2u)]))) & 7u))) & 7u];\n"
    "        for (uint i1 = 0; i1 < 3u; i1++) {\n"
    "            v0 += i1 * 8u;\n"
    "            v2 ^= (vf((((uchar4((uchar)((v5 < (v0 ^ t) ? in[(t * 4u + 1u)] : in[(t * 4u + 0u)])), (uchar)((uint)(pc[((v5 ^ t)) & 7u])), (uchar)(rotate(32u, v1)), (uchar)((uint)((bool)(in[(t * 4u + 3u)] & v1)))) - uchar4((uchar)(((int)(in[(t * 4u + 2u)]) <= (int)(1358991056u) ? in[(t * 4u + 3u)] : (v3 ^ t))), (uchar)(in[(t * 4u + 3u)]), (uchar)((uint)(pc[(v4) & 7u])), (uchar)(subsat(in[(t * 4u + 2u)], v4)))) % ((select(uchar4((uchar)(v0), (uchar)(median3(v5, v0, (v1 ^ t))), (uchar)(((v0 % (3727813120u | 1u)))), (uchar)(((int)((v0 ^ t)) >= (int)(v1) ? v5 : in[(t * 4u + 1u)]))), uchar4((uchar)((uint)((int)(v4) >> (int)((v4 ^ t) & 31u))), (uchar)(reverse_bits(3819757851u)), (uchar)(rotate(110u, v0)), (uchar)((uint)(!(65536u > 2147483648u)))), uchar4((uchar)(178), (uchar)(144), (uchar)(66), (uchar)(23)) >= uchar4((uchar)(max3(v5, v3, (v3 ^ t))), (uchar)((uint)((bool)(12u & in[(t * 4u + 0u)]))), (uchar)(((3242554179u & 1u) != 0u ? (v5 ^ t) : 69u)), (uchar)((uint)(max((int)(in[(t * 4u + 2u)]), (int)((v4 ^ t)))))))) | uchar4((uchar)(1), (uchar)(1), (uchar)(1), (uchar)(1)))))) / ((uint)((((((ulong)((uint)(select((int)(31u), (int)(v0), (v1 & 2u) != 0u))) << 32) | (ulong)((in[(t * 4u + 2u)] == v1 ? (v4 ^ t) : in[(t * 4u + 1u)])))) % (((((ulong)((uint)(min((int)(in[(t * 4u + 0u)]), (int)(v0)))) << 32) | (ulong)((uint)(min((int)(in[(t * 4u + 0u)]), (int)(v0)))))) | 1ul)) >> 22) | 1u));\n"
    "        }\n"
    "    }\n"
    "    dbg0 = v0 ^ (v1 * 0x9e3779b1u) ^ (v2 * 0x85ebca6bu); dbg1 = v3 ^ (v4 * 0x9e3779b1u) ^ (v5 * 0x85ebca6bu);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = dbg0;\n"
    "    out[t * 8u + 6u] = dbg1;\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
    "}\n";

// FNV-1a of each thread's 8 words (bytes in little-endian order), from cpuref.py's output for this kernel and input seed 1
static const uint32_t want[256] = {
    0x3fada15cu, 0xed7b30f6u, 0x25997beau, 0xa5b35979u, 0x34f0d34bu, 0x36f8354cu, 0xb437e464u, 0x3f0f467eu,
    0x6a69c6b5u, 0xf1b87cabu, 0x83f3d797u, 0xb4d2d2e6u, 0x77e3909au, 0x8fb129bdu, 0x33c89538u, 0x435bdc89u,
    0x06a35a4fu, 0x92c6c1f6u, 0xa16e2d82u, 0x8d758c1fu, 0x5d73ec70u, 0xd66ca166u, 0xd4d0fb1eu, 0x2f397601u,
    0x12a9e63fu, 0xa9417426u, 0xf1bf5d09u, 0x2d67b195u, 0x104fd830u, 0xd88133a6u, 0xd00f16d0u, 0xceca93c1u,
    0x8b3972eeu, 0x823d7661u, 0xd5962c6bu, 0x3def2c0fu, 0x8f6d1a86u, 0x666cff71u, 0x269baeb9u, 0x658fa561u,
    0x2483e5eeu, 0x04ecf86cu, 0xfef04100u, 0x18e98726u, 0x0b0b11c3u, 0xcbb8b97du, 0x5cb00496u, 0xd42d6005u,
    0xb939acb1u, 0x4e064f37u, 0x3f6b810cu, 0x9255d057u, 0xefc0b7e5u, 0xa7e33c7fu, 0xaadb4626u, 0x22c12f71u,
    0xba0b957du, 0x82da4332u, 0x4788884du, 0x57730cecu, 0xef7dd683u, 0x103beb78u, 0x302aa315u, 0xcf58e020u,
    0xbcfceefbu, 0xc62665acu, 0xa0f31c84u, 0xc9fb2942u, 0x7afc752cu, 0xc2dab363u, 0x07bef44fu, 0x2e1baffau,
    0xca56b37bu, 0xa1281b2au, 0x8596f5b8u, 0xf68f2ecdu, 0x413715eeu, 0x761522cbu, 0x966272ebu, 0xbd46817eu,
    0xf2ea0ec0u, 0x06be5a4fu, 0xc29cc4b4u, 0xb846d84cu, 0xb1a9c607u, 0xf44941cbu, 0xa9ce50aeu, 0xe901ae70u,
    0x3479f9c0u, 0x9a41af90u, 0x96636c0bu, 0xd8693081u, 0xba8deb14u, 0xd06ae974u, 0xcf0f7ae6u, 0x59beac2fu,
    0xe341039fu, 0x323271e5u, 0x9c2c9c52u, 0xb70487b1u, 0x54461ae4u, 0xdaaadeebu, 0x432e27fbu, 0x9d99354eu,
    0x32cba96au, 0x05d1275cu, 0xbc2a4be0u, 0x0128fe7du, 0x3e6624ebu, 0xb646320cu, 0xd9874823u, 0x746fc91eu,
    0xbc97ace8u, 0xf9573a15u, 0xc8d481dfu, 0x9a23cd36u, 0x679f1b56u, 0xdf2365eau, 0xb1554210u, 0xd3651106u,
    0x9dae9a35u, 0x5bae1c60u, 0x014f3c29u, 0xd3738d7eu, 0x1564ac6cu, 0x18361279u, 0x97acd336u, 0xed704835u,
    0x6de0008au, 0x2f9cd9fcu, 0xce40e5fcu, 0x460049e6u, 0x4e85b298u, 0xd27765dfu, 0x5f029691u, 0x4b7ec3bcu,
    0xb2fbef95u, 0x6eafcee8u, 0xa547ef0bu, 0x439021e9u, 0x742e4569u, 0x7a68be25u, 0xf23289a2u, 0xb8ce1b42u,
    0xb650ccb6u, 0x527d5c0cu, 0xc6211c39u, 0x5e90680fu, 0x72896bc3u, 0x95f9eb4eu, 0x12b922dau, 0x19c4ae72u,
    0x2951ec98u, 0x7dc1202eu, 0xaac7e8cau, 0x6d80c678u, 0x7c22b261u, 0x2c3abe4du, 0x747f1d82u, 0x5ed4a20eu,
    0x69037fa2u, 0xa9811ff5u, 0x393deeceu, 0x061ef991u, 0xe49bd1b9u, 0xbdccdef5u, 0x8a59715eu, 0x66e715b8u,
    0x1fd2189eu, 0x5ff3f075u, 0x9185414fu, 0xb03430e2u, 0x9cdd2ed8u, 0xb92f7556u, 0x216281ecu, 0x0ea3cad2u,
    0x84d4109du, 0x3bd46f98u, 0x65c118ceu, 0xdfd7520cu, 0x2d1a2e0bu, 0x31abfa7cu, 0xda54a780u, 0x7c2b0efeu,
    0xf748dfccu, 0x4db40e68u, 0x3dbd2e26u, 0x857c57f7u, 0xae9c8bccu, 0xb759e6acu, 0xddb21e34u, 0x219fd083u,
    0x0c38beaeu, 0x2eccae22u, 0xcf3f56a5u, 0xdc3cea64u, 0xdc8ce6cau, 0xfe303617u, 0x3862e049u, 0x168980b8u,
    0xd4c12285u, 0x7e29a244u, 0xddea235du, 0x4440dba2u, 0x732f5b4bu, 0xa710cf85u, 0x83c37e05u, 0x5aa74edbu,
    0x7a3cc736u, 0x5dd30a9cu, 0x2a327f46u, 0x8113aae2u, 0x9638241eu, 0xde4ddb47u, 0x4e6718e4u, 0x0ad76076u,
    0x19fa0e48u, 0x739e3737u, 0x32aad6dcu, 0x077827fau, 0xea39203bu, 0xac996183u, 0x9b117587u, 0x17d629e5u,
    0x82240a40u, 0xd3cb56edu, 0x2e158b0du, 0x70138a74u, 0xfd4e1005u, 0x11e90e9du, 0x1dfc2781u, 0xd27f6b19u,
    0xb0026dedu, 0xee65f7ddu, 0xa7c1ebbbu, 0x7799a062u, 0xb8c74b18u, 0x8873692eu, 0x5194fa76u, 0x9c4bcb51u,
    0x60241aa2u, 0xeb9d41f2u, 0x5aac6f55u, 0x140d2a70u, 0x7f3cb939u, 0xb7f045aeu, 0x01c319f1u, 0x27a84314u,
    0xff3828dfu, 0x051e27e6u, 0x11380deau, 0xbff7f783u, 0x50920582u, 0x35cd26adu, 0x99169482u, 0x572b4a37u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n43-kepler-narrow-division";
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
    return PASS(bug, "%s: divisions and remainders of 8-bit lanes are right in a loop", name);
}}
