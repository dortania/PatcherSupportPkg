// n37-kepler-narrow-vector-loop-exit: a loop ending on all(a != b) for char4 vectors must stop at the right iteration;
// the back end's packed vectors went wrong. Fix: GeForceAIRCompat NVAIR_NARROW_VECTOR_FIX. Checks: the reduced fuzz
// kernel against the CPU reference (cpuref.py), 256 threads. Argument: GPU name (default: NVIDIA).
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
    "    for (uint i0 = 0; i0 < 5u; i0++) {\n"
    "        v4 += i0 * 5u;\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v2 = rotate(hadd(insert_bits(in[(t * 4u + 1u)], 545035835u, (uint)(32u & 15u), (uint)(1u & 15u)), (v4 & in[(t * 4u + 3u)])), ((min3(v2, (v2 ^ t), 3403509597u) % ((uint)((uchar)(1u) - (uchar)(v5)) | 1u))));\n"
    "            if ((((uint)(all((char4((char)(1u), (char)(1u), (char)(1u), (char)((uint)((int)(in[(t * 4u + 2u)]) / (int)(((v1 ^ t) | 1u) & 0x7fffffffu)))) % ((char4((char)(5), (char)(-39), (char)(69), (char)(-44))) & char4((char)(127), (char)(127), (char)(127), (char)(127)) | char4((char)(1u), (char)(1u), (char)(1u), (char)(1u)))) != (char4((char)((uint)((int)((v2 ^ t)) % (int)((in[(t * 4u + 2u)] | 1u) & 0x7fffffffu))), (char)(1u), (char)(1u), (char)(1u)) & char4((char)(1u), (char)(v5), (char)((uint)(select((int)(v1), (int)(v4), ((v1 ^ t) & 2u) != 0u))), (char)((uint)((uchar)((v5 ^ t)) * (uchar)(1u)))))))) & 3u) == 0u) break; } v0 += n1; }\n"
    "    }\n"
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
    0x5854b0d3u, 0xcc44ac69u, 0xdefcc05fu, 0x2c6d8e2au, 0xf6ce8441u, 0x7dbb3c6bu, 0x8b18c339u, 0x9c62ce6fu,
    0x3f1295bcu, 0x68ab1cf2u, 0x007dd1dfu, 0x7f77e3b0u, 0x289214e1u, 0x3384e802u, 0xb41d850bu, 0x2130e798u,
    0x05b2cd91u, 0x56f90d09u, 0x5ca13745u, 0xf6e0e51cu, 0xcd056183u, 0x1d39ab77u, 0x8e2798bfu, 0xa3e89dabu,
    0x1803a090u, 0xa7419ff9u, 0x468bf484u, 0x85aaa203u, 0xca13012cu, 0xc732522cu, 0xeee180a2u, 0xd7548a54u,
    0x1ddd905eu, 0x047db469u, 0x3eea3afeu, 0xdb5ef8f1u, 0xeb5248e2u, 0x137d2620u, 0xe2091e23u, 0xaad51bb7u,
    0xbe942631u, 0xcb14dc09u, 0xc36f475fu, 0x819e4b86u, 0x136069f5u, 0xdf13a482u, 0xf884715du, 0xba584704u,
    0x3913f949u, 0xf51388beu, 0x84833bbfu, 0x6b4c92c0u, 0x71f7a62eu, 0x8c2683c4u, 0x6a897418u, 0xcd937818u,
    0xf3c7f46fu, 0x151eddbfu, 0xe45b1368u, 0x1d4cba8du, 0x4bcd8ea2u, 0x6674deecu, 0x20b95ac7u, 0x2e2ebe47u,
    0xc17b0106u, 0x0a5a94b1u, 0xc2bc3b0fu, 0xe5ee929cu, 0xb6123f79u, 0x3d952d05u, 0x49587129u, 0xc7a0fe0eu,
    0xea80166eu, 0x723ebfefu, 0x21ea8730u, 0x0e8f80ffu, 0x0709d34cu, 0x35763687u, 0x04956735u, 0xe4a29905u,
    0x2dc9a13au, 0x79ad073du, 0xea37fc8fu, 0x4f92876bu, 0x28241904u, 0x6619c1f1u, 0xb5cfcd0du, 0x1d11d885u,
    0x183a9bb7u, 0xf9f5066au, 0x6eeff316u, 0xcfb21c32u, 0xd381e744u, 0xf4a1de72u, 0x8db4642du, 0x6ae6940cu,
    0xd8523af8u, 0xac680286u, 0x7f2696dfu, 0xc9f6fc17u, 0xd4bbb6d8u, 0x722b2b89u, 0x97de485cu, 0xc4d13217u,
    0xe6126bc2u, 0x75a91ee7u, 0x637387c6u, 0x942704ffu, 0x25ae7734u, 0xe9d67d71u, 0xa63ee86eu, 0x95f1d1f0u,
    0x824a7cbfu, 0x320dad81u, 0x2bdab3e0u, 0xae5a4588u, 0x990c8d3cu, 0x87337aeeu, 0x5e805d16u, 0xfcf3b7a3u,
    0x39699b65u, 0x0a07c801u, 0x5d0bbc0cu, 0x5ff72449u, 0xac4667ebu, 0xe6fd37a6u, 0x121dc78au, 0x2aa3be9au,
    0x9eda40d8u, 0x88d0ca3fu, 0x0d8ce000u, 0x38168946u, 0x4b9c7a4au, 0x54407b2bu, 0x7ef60ef1u, 0x032aa81cu,
    0xf5f33968u, 0x2c8976dbu, 0xa5be9ec6u, 0x4441cb39u, 0xd87f39e2u, 0x7baef1cfu, 0x67463110u, 0xa2c86a81u,
    0xebb702c0u, 0x94c63433u, 0xd9f14fdfu, 0xa75a04abu, 0xa927de62u, 0x7e3be8ddu, 0x1df0947cu, 0xa424297eu,
    0x73c37f67u, 0x3b059976u, 0xa6a64734u, 0x2fb00df5u, 0xcf34d88au, 0x5402228eu, 0x078d47c8u, 0xc33398e7u,
    0x05f86effu, 0xb3ec16b7u, 0x693cff0du, 0x7fbc112fu, 0xb19d711cu, 0x0571aa30u, 0x8d469abeu, 0x5f2b120du,
    0x2d0593a9u, 0x5bbf191du, 0xfc6f123bu, 0x4f04d74bu, 0xd91cd2d3u, 0xc3d1cfe2u, 0xa3f57223u, 0x81aa3482u,
    0x7278db6du, 0xffca7f98u, 0x30736625u, 0x5d7e991eu, 0x066e8dcdu, 0x8e38a33du, 0xc16b9fe8u, 0x8f9e3c9cu,
    0xa7aa8973u, 0x922a2fcbu, 0x50de5541u, 0x8be8f474u, 0x9ebb2bfau, 0x5ce8696eu, 0x42374412u, 0x6d004c54u,
    0xff20c459u, 0x3247264bu, 0xf9ed271au, 0xcc912716u, 0x7600a580u, 0xdbe0a8bcu, 0x98e9ec05u, 0x988b8102u,
    0x047fc066u, 0x40d1673bu, 0xfc82708bu, 0x397af75eu, 0xeef3293fu, 0xd04470deu, 0x5eaea356u, 0x85576f4au,
    0x6e0d7a86u, 0xc61a951du, 0x169062d2u, 0x482fd8d9u, 0xe0815ff1u, 0x405358fbu, 0xc3709024u, 0xed377d29u,
    0x985fe590u, 0xa27d5c96u, 0xa123b51au, 0xc562f5ceu, 0xd752c3d5u, 0xcfa231edu, 0xc15a77afu, 0xcb985bd5u,
    0x515702a5u, 0xa0f21256u, 0xd5527afbu, 0x1b22400cu, 0x37ec7ec8u, 0x1e253f70u, 0x07ee54a1u, 0xf67b8497u,
    0xbd8a2835u, 0xdadac0f2u, 0x2c7a290fu, 0xc9aaab12u, 0x10c439b6u, 0x24ff43c6u, 0xe25aba11u, 0x23cc0b92u,
    0x447f4d07u, 0xe8b85a6au, 0x3bf5f7b2u, 0xc2cac00eu, 0xf347be64u, 0xcf636294u, 0x1e247cc0u, 0x0189c751u,
    0x14f8cb36u, 0x9580f243u, 0xb3c1867fu, 0xa3b12eeeu, 0x139f81d8u, 0x4635dbc9u, 0x6610a57au, 0xc4aec74au
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n37-kepler-narrow-vector-loop-exit";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    return reproFuzzKernel(bug, dev, src, want, "a loop that ends on a compare of narrow vectors stops at the right iteration");
}}
