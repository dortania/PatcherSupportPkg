// i47-intel-narrow-private-array (Intel adapter, INTEL_NARROW_PRIVATE_ARRAY_FIX): a private uchar array read after the
// rewrites. The array (uchar pc[8]) is stored with truncating stores and read with extending loads, and after i07's and
// i35's rewrites the back end forwarded a stored 32-bit value to such a load without its mask, so pc[2] read in a
// ushort2 compare kept the bits above its byte and the atomic sum came out wrong in 34 of 256 threads (mslfuzz2 VEC=1
// seed 1497, reduced; the stock compiler is wrong there too, differently). Private arrays of 8- and 16-bit integers
// reached only through element loads and stores are done on 32-bit words. Expected values from the CPU reference
// (cpuref.py) on the fuzzer's input. Fixed: PASS. Argument: GPU name substring (default: Intel).
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
    "    switch ((in[(t * 4u + 3u)]) & 3u) {\n"
    "    case 1u: {\n"
    "        v3 = (uint)((uchar)((uint)((short)((uint)((uchar)((v5 ^ t)) >> ((v1 ^ t) & 7u))))) / (uchar)(insert_bits(in[(t * 4u + 1u)], (in[(t * 4u + 1u)] * 2147483647u), (uint)(((80u % (32u | 1u))) & 15u), (uint)((uint)((ushort)(2u)) & 15u)) | 1u));\n"
    "        }\n"
    "    }\n"
    "    for (uint i0 = 0; i0 < 3u; i0++) {\n"
    "        v2 -= (uint)((uchar)(mulhi((uint)((short)((v2 ^ t))), in[(t * 4u + 3u)])) >> (median3(subsat((v3 ^ t), in[(t * 4u + 2u)]), 2u, ((int)(3226576549u) < (int)(v1) ? v2 : (v3 ^ t))) & 7u));\n"
    "    }\n"
    "    v2 += (uint)((int)(addsat(rhadd(0u, v0), madsat(v4, 2u, 248u))) % (int)(((~(uint)((int)(2u) % (int)((4075531808u | 1u) & 0x7fffffffu))) | 1u) & 0x7fffffffu));\n"
    "    pc[(vf((as_type<short2>((~in[(t * 4u + 2u)]))))) & 7u] = (uchar)(((uint)((ushort)((in[(t * 4u + 0u)] / (in[(t * 4u + 1u)] | 1u)))) * (uint)((ushort)((uint)((int)(in[(t * 4u + 1u)]) / (int)((335208786u | 1u) & 0x7fffffffu))))));\n"
    "    atomic_fetch_add_explicit(&ta, ((uint)(any((ushort2((ushort)(v2), (ushort)((uint)(pc[(2u) & 7u]))) >> ((ushort2((ushort)(min3((v5 ^ t), 61u, (v5 ^ t))), (ushort)((in[(t * 4u + 3u)] != in[(t * 4u + 2u)] ? 32u : 551473954u)))) & ushort2((ushort)(15), (ushort)(15)))) > ushort2((ushort)((862129290u / (v0 | 1u))), (ushort)(256u))))) & 255u, memory_order_relaxed);\n"
    "    { tg[l] = vf((max((short4((short)(13197), (short)(-25412), (short)(-29476), (short)(25245)) & short4((short)(-31940), (short)(22382), (short)(-31134), (short)(7174))), (short4((short)((uint)(!(in[(t * 4u + 3u)] > (v3 ^ t)))), (short)(((v4 ^ t) >> ((v4 ^ t) & 31u))), (short)((uint)(max((int)((v0 ^ t)), (int)(in[(t * 4u + 2u)])))), (short)((uint)(pc[(123u) & 7u]))) & short4((short)(3962), (short)(3264), (short)(8856), (short)(12644)))))); threadgroup_barrier(mem_flags::mem_threadgroup); v4 += tg[(rotate(((int)(in[(t * 4u + 2u)]) < (int)((v4 ^ t)) ? v3 : in[(t * 4u + 0u)]), v3)) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 4u] = v4;\n"
    "}\n";

// out[t * 8 + 4] for each thread t, from the CPU reference (cpuref.py) on the same input
static const uint32_t kExpected[256] = {
    0x06144073u, 0x2a7f0075u, 0x9f36b0aau, 0xa98026f0u, 0x8ec15b75u, 0x7da65419u, 0xf651aed7u, 0x209c51f8u,
    0x8abed5e4u, 0x8d093d8au, 0x96a48deau, 0x47d1a77fu, 0x7b40a696u, 0xbb33cd13u, 0x268cc8a1u, 0x220a5d14u,
    0x877c0fa9u, 0xd0bcb7a6u, 0x26a2668du, 0x21bde4e0u, 0x11727a77u, 0x209475c2u, 0x13f328c4u, 0xf203cb4bu,
    0xb3216608u, 0x19babb5du, 0xc117a4e2u, 0x29cb7df9u, 0x26342aa2u, 0x067eddd1u, 0x53fff7ecu, 0x8dca8a3eu,
    0xbd9d9064u, 0xed3de378u, 0x335ef2b7u, 0x401429d7u, 0x3841eeceu, 0xb5d1c7bcu, 0xe78fdc48u, 0x12995c78u,
    0x09207a5cu, 0x59271d0eu, 0x2413a59fu, 0x1ac78628u, 0x0fba2680u, 0xeb45d99bu, 0x8a9d9a91u, 0xf939ef29u,
    0x16b75995u, 0x240c7f25u, 0x747d407eu, 0x0379100eu, 0x38654c4fu, 0x62fe0219u, 0x2e3de430u, 0xcb3e6807u,
    0x66848109u, 0xe511cf23u, 0x31cef53du, 0x81f5f9d4u, 0x8c23f546u, 0x4bd236e8u, 0x9e6d0a01u, 0x40142b7fu,
    0xcdab4adeu, 0x3b1b0827u, 0x4668e1d1u, 0x7573543cu, 0x871f5ecfu, 0x4abed118u, 0x4284ac60u, 0x7a5ec3bau,
    0x01d6be80u, 0x11619e1fu, 0x6b8f9405u, 0xdc3122eeu, 0x59222b0eu, 0x040c4845u, 0xcc13baddu, 0x7d8fad55u,
    0x7f38f426u, 0x7722ac42u, 0x3be41356u, 0x8ecf7f96u, 0x040c4831u, 0x05f8ffb1u, 0xb677f44bu, 0x8f4baacbu,
    0xbccdffb1u, 0x38dfd0a8u, 0xd6038ea4u, 0x040c4733u, 0xbe192a3cu, 0xda228680u, 0x9a183f41u, 0xd35b9dacu,
    0x19520120u, 0x66d5f64au, 0x040c4782u, 0x73a0a07cu, 0xda24c44cu, 0x32e6999du, 0x22564569u, 0x2e5587e3u,
    0x9338867du, 0x44932370u, 0x2b47cfcfu, 0xa0df7d3eu, 0x19200c2cu, 0x326caba2u, 0x3ca1641eu, 0xad920706u,
    0x040c4322u, 0x87c2b3e5u, 0x71cb5918u, 0xdd5f290eu, 0xe2a17b2cu, 0x9ac109b3u, 0x0ee1a41au, 0x6494c903u,
    0xe111fc8cu, 0x6bee09a9u, 0x08a34706u, 0xe81e220au, 0xbd340e82u, 0xec051e0eu, 0x040c427cu, 0x560e48a5u,
    0x462fcb8cu, 0x5295645bu, 0xb1a17c3bu, 0xe3a50ec5u, 0x80c3822fu, 0x2413ab49u, 0xdabe3cefu, 0xdda16eb7u,
    0x16778f65u, 0xd6f97741u, 0xeed95716u, 0x01ce950fu, 0x060ccb6cu, 0x2fec92bdu, 0xbf28c2d2u, 0x5289bd7bu,
    0x336b5a28u, 0xbcf51528u, 0x4b379065u, 0x060ccaecu, 0x013c24ceu, 0xa30caa7fu, 0x39d0c0b4u, 0x9b2a8e60u,
    0xb21c3165u, 0x1ae86bb7u, 0x060ccdb1u, 0x15a81d15u, 0x824d34dcu, 0x4550a567u, 0xc6010982u, 0xfb26c703u,
    0x56fa7744u, 0x40932c7bu, 0x7be08d17u, 0xf9bd3933u, 0xf3084073u, 0x6d93b301u, 0x6a07c38cu, 0x19e8132du,
    0x261c1f74u, 0xbcf89615u, 0xb571b7b0u, 0xe3472a19u, 0xa0646588u, 0x432524a3u, 0xeaa37cfcu, 0x06b501a0u,
    0x5492f758u, 0xe45ec2eeu, 0x02d9affbu, 0x1c78d25eu, 0x1eee9c26u, 0x161919b6u, 0x661c78adu, 0x8913d064u,
    0xf779ead9u, 0x6b4112bau, 0x6b36b6a6u, 0x13ac8813u, 0x24ed5f7du, 0x060cc7b6u, 0x0f54797bu, 0xdbd4f984u,
    0x99126ecdu, 0x2ae0034eu, 0x3f5b3252u, 0xf9f1d523u, 0x041ba0c6u, 0x2ddb3c1cu, 0x941698d7u, 0x6a5c2d56u,
    0x1e88c7fcu, 0x5381ac2eu, 0x11c956f3u, 0x6094cd74u, 0x096b8f79u, 0x2aa3d2c8u, 0xf775d6b6u, 0xc778ab76u,
    0x3ac6a396u, 0x97c524a9u, 0x02043131u, 0x67279468u, 0xe37775b3u, 0x4d4d7159u, 0x848eb59eu, 0x6f2dee7au,
    0xab0c0434u, 0x6403ce6eu, 0x0b6924b2u, 0x4b78b23fu, 0xf8d37c28u, 0x7649b2c7u, 0xd21e21dbu, 0x312cad05u,
    0x649d04d3u, 0x4aa56e88u, 0xc40f3a7cu, 0x0eb9b536u, 0xcccb8194u, 0x8489f4f7u, 0x3ff61f5cu, 0x400b3b7eu,
    0x6f7a9684u, 0x8427646eu, 0x48e1e77cu, 0x0e7b5f78u, 0x1329504fu, 0xf808dcc4u, 0x649d041bu, 0x679dbb54u,
    0xa3465220u, 0xf3c3b660u, 0x3d7148edu, 0x5ff4547du, 0xbe9de146u, 0x60842a5du, 0x805778d3u, 0x2366e5e2u,
    0x95622a39u, 0x3374fd75u, 0x437f17e6u, 0x3fdc093fu, 0x069c0b37u, 0xdb60c99au, 0x6d3ededbu, 0xefde3405u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i47-intel-narrow-private-array";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    uint32_t x = 2654435761u + 12345u, *w = in.contents;  // the differential fuzzer's input, seed 1
    for (int i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; w[i] = (i % 7 == 0) ? (x & 0xff) : x; }
    memset(out.contents, 0xcd, T * 32);
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
    for (int t = 0; t < T; t++) if (o[t * 8 + 4] != kExpected[t] && !wrong++) first = t;
    if (wrong) return FAIL(bug, "%s: %d of 256 results wrong (thread %d: %08x, want %08x)", name, wrong, first, o[first * 8 + 4], kExpected[first]);
    return PASS(bug, "%s: every result of the 256 threads matches the CPU reference", name);
}}
