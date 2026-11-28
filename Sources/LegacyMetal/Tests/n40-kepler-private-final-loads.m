// n40-kepler-private-final-loads: loads of a private array after its last store must stay plain; giving them n26's
// opaque index broke other values. Fix: GeForceAIRCompat NVAIR_PRIVATE_FINAL_LOADS_FIX. Checks: fuzz seed 3890's kernel
// against the CPU reference (cpuref.py), 256 threads. Argument: GPU name (default: NVIDIA).
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
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v3 ^= p[(((in[(t * 4u + 1u)] + v2) ^ (v0 ^ t))) & 7u];\n"
    "        if (((((uint)((int)((v5 ^ t)) % (int)((in[(t * 4u + 0u)] | 1u) & 0x7fffffffu)) <= (uint)((int)(in[(t * 4u + 2u)]) >> (int)(2891062351u & 31u)) ? ((47u & 1u) != 0u ? 65536u : 20u) : (uint)((uchar)((v4 ^ t)) >> (1069577004u & 7u)))) & 3u) == 0u) break; } v3 += n0; }\n"
    "    atomic_fetch_add_explicit(&ta, ((uint)((uchar)((uint)((bool)(in[(t * 4u + 3u)] & (v2 ^ t)))) - (uchar)(min(v0, in[(t * 4u + 3u)])))) & 255u, memory_order_relaxed);\n"
    "    v1 ^= (uint)(min((int)((~1u)), (int)(vf((char2((char)(-22), (char)(55)))))));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        switch (((uint)(any((uchar4((uchar)(insert_bits((v4 ^ t), (v1 ^ t), (uint)((v4 ^ t) & 15u), (uint)((v4 ^ t) & 15u))), (uchar)(((int)(2147483647u) > (int)(v4) ? 1153138714u : in[(t * 4u + 1u)])), (uchar)((v3 | v5)), (uchar)(((in[(t * 4u + 2u)] & 1u) != 0u ? (v0 ^ t) : in[(t * 4u + 0u)]))) & uchar4((uchar)(extract_bits(1u, (uint)(2860665401u & 15u), (uint)(v1 & 15u))), (uchar)(((v2 ^ t) / (2719006076u | 1u))), (uchar)((in[(t * 4u + 3u)] / (in[(t * 4u + 0u)] | 1u))), (uchar)(mulhi(2u, (v5 ^ t))))) <= as_type<uchar4>(ushort2((ushort)(mulhi(2131094439u, (v1 ^ t))), (ushort)(((v0 ^ t) / (2787165632u | 1u)))))))) & 3u) {\n"
    "        case 0u: {\n"
    "            { uint4 w = uint4(in[(t * 4u + 1u)], v4, ((ushort)(((102u % (in[(t * 4u + 2u)] | 1u)))) > (ushort)((v4 / (177u | 1u))) ? ((uint)((ushort)(in[(t * 4u + 1u)])) * (uint)((ushort)(109u))) : ((int)(v5) < (int)((v2 ^ t)) ? (v1 ^ t) : 1u)), v1); w[((uint)(!(mulhi(137u, (v0 ^ t)) > (65535u << (in[(t * 4u + 1u)] & 31u))))) & 3u] = vf((max((short3((short)(-24249), (short)(-20876), (short)(-32600)) ^ short3((short)(11453), (short)(-23488), (short)(-13341))), min(short3((short)(((in[(t * 4u + 0u)] & 1u) != 0u ? in[(t * 4u + 3u)] : in[(t * 4u + 3u)])), (short)(insert_bits((v5 ^ t), 256u, (uint)(in[(t * 4u + 0u)] & 15u), (uint)(v2 & 15u))), (short)((2147483647u / (in[(t * 4u + 0u)] | 1u)))), short3((short)(16218), (short)(-8790), (short)(-26606)))))); v0 += w[(extract_bits((uint)((int)(v5) >> (int)(4294967295u & 31u)), (uint)(popcount(v1) & 15u), (uint)(((v5 ^ t) * v3) & 15u))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "            break; }\n"
    "        default: {\n"
    "            atomic_fetch_add_explicit(&ta, (vf(((max(ushort3((ushort)(52830), (ushort)(3544), (ushort)(6815)), ushort3((ushort)(60047), (ushort)(16797), (ushort)(60273))) >> ushort3((ushort)(6), (ushort)(3), (ushort)(5)))))) & 255u, memory_order_relaxed);\n"
    "            break; }\n"
    "        }\n"
    "        p[(((uint)((ushort)((uint)(-(int)((v4 ^ t) & 0x7fffffffu)))) * (uint)((ushort)((uint)(select((int)(v1), (int)((v1 ^ t)), ((v0 ^ t) & 2u) != 0u)))))) & 7u] = absdiff(max(v1, v1), (21u == v4 ? v0 : 42u));\n"
    "        if ((((uint)(max((int)(((int)(v4) >= (int)((v2 ^ t)) ? in[(t * 4u + 0u)] : v0)), (int)((((v2 ^ t) % ((v4 ^ t) | 1u))))))) & 3u) == 0u) break; } v0 += n0; }\n"
    "    v2 = ((uint)((int)((ushort)((~(v0 ^ t))) >> (mulhi(v3, v5) & 15u))) / ((uint)((int)(in[(t * 4u + 2u)]) % (int)(((uint)((bool)(33u & 2147483648u)) | 1u) & 0x7fffffffu)) | 1u));\n"
    "    switch (((uint)((ushort)(((uint)((int)((char)(v4))) * (v1 ^ t))) >> (((v0 ^ t) << (v2 & 31u)) & 7u))) & 3u) {\n"
    "    case 0u: {\n"
    "        v2 = (uint)((uchar)(mulhi(popcount((v1 ^ t)), (uint)((bool)((v2 ^ t) & in[(t * 4u + 2u)])))) >> ((uint)((int)((uint)(pc[(162u) & 7u])) / (int)((((uint)((int)((short)(v2))) ^ in[(t * 4u + 3u)]) | 1u) & 0x7fffffffu)) & 7u));\n"
    "        break; }\n"
    "    default: {\n"
    "        pc[((uint)((int)((char)((uint)((bool)(1u & in[(t * 4u + 3u)]))) / (char)((180u & 127u) | 1u)))) & 7u] = (uchar)((hadd(in[(t * 4u + 0u)], (v5 ^ t)) >> (31u & 31u)));\n"
    "        break; }\n"
    "    }\n"
    "    v0 -= (uint)(all((char2((char)((~31u)), (char)((uint)((int)(in[(t * 4u + 1u)]) / (int)(((v5 ^ t) | 1u) & 0x7fffffffu)))) >> ((char2((char)((uint)((int)(in[(t * 4u + 1u)]) / (int)((v3 | 1u) & 0x7fffffffu))), (char)(210u))) & char2((char)(7), (char)(7)))) == (char2((char)(v0), (char)(subsat(0u, 1273965731u))) % ((char2((char)(insert_bits(v1, v3, (uint)(187u & 15u), (uint)((v4 ^ t) & 15u))), (char)((uint)(pc[((v4 ^ t)) & 7u])))) & char2((char)(127), (char)(127)) | char2((char)(1), (char)(1))))));\n"
    "    switch ((median3((uint)((int)((v1 ^ t)) / (int)((2u | 1u) & 0x7fffffffu)), ((uint)((ushort)(in[(t * 4u + 3u)])) * (uint)((ushort)((v0 ^ t)))), v4)) & 3u) {\n"
    "    case 0u: {\n"
    "        pc[((uint)((ushort)(((125u & 1u) != 0u ? v0 : (v1 ^ t))))) & 7u] = (uchar)((uint)((uchar)(v5) >> (((uint)((ushort)((v3 ^ t))) * (uint)((ushort)(in[(t * 4u + 3u)]))) & 7u)));\n"
    "        if (vf((((short2((short)(16520), (short)(-21654)) / ((short2((short)(((int)(79u) < (int)(2u) ? (v0 ^ t) : v1)), (short)((uint)(max((int)(in[(t * 4u + 3u)]), (int)(v5)))))) & short2((short)(32767), (short)(32767)) | short2((short)(1), (short)(1)))) % ((as_type<short2>(uchar4((uchar)(76), (uchar)(170), (uchar)(125), (uchar)(180)))) & short2((short)(32767), (short)(32767)) | short2((short)(1), (short)(1)))))) > (uint)((ushort)(insert_bits((v3 ^ t), 3927720960u, (uint)((v0 ^ t) & 15u), (uint)(v3 & 15u))) % (ushort)((uint)(-(int)(v3 & 0x7fffffffu)) | 1u))) {\n"
    "            v3 = v2;\n"
    "        }\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        v4 = ((uint)((ushort)((uint)(all((char2((char)(-25), (char)(40)) ^ char2((char)((uint)((int)(in[(t * 4u + 3u)]) / (int)(((v3 ^ t) | 1u) & 0x7fffffffu))), (char)((uint)((uchar)((v2 ^ t)) >> (106u & 7u))))) != char2((char)(-36), (char)(71)))))) * (uint)((ushort)(vf(((ushort3((ushort)(min(256u, 32u)), (ushort)(extract_bits(v5, (uint)(in[(t * 4u + 3u)] & 15u), (uint)((v1 ^ t) & 15u))), (ushort)((uint)(-(int)(in[(t * 4u + 2u)] & 0x7fffffffu)))) << ushort3((ushort)(7), (ushort)(4), (ushort)(15))))))));\n"
    "        break; }\n"
    "    default: {\n"
    "        v0 ^= p[(((uint)((int)(v2) >> (int)(v0 & 31u)) >> ((uint)((char)(v5)) & 31u))) & 7u];\n"
    "        break; }\n"
    "    }\n"
    "    p[(madsat((uint)(max((int)(in[(t * 4u + 1u)]), (int)(in[(t * 4u + 2u)]))), max(in[(t * 4u + 1u)], 4217046248u), 2147483648u)) & 7u] = (~((2147483647u & 1u) != 0u ? 1285454659u : 2872250483u));\n"
    "    if (v0 == subsat(((uint)((int)((short)(in[(t * 4u + 1u)]))) ^ 0u), in[(t * 4u + 2u)])) {\n"
    "        v4 ^= p[((max(4294967295u, 3552813020u) == (uint)((uchar)(v3) >> ((v3 ^ t) & 7u)) ? (uint)((ushort)(in[(t * 4u + 1u)])) : (uint)(-(int)(in[(t * 4u + 3u)] & 0x7fffffffu)))) & 7u];\n"
    "        pc[(vf(((char2((char)(extract_bits(1350840623u, (uint)(in[(t * 4u + 0u)] & 15u), (uint)(222u & 15u))), (char)(reverse_bits((v1 ^ t)))) ^ min(char2((char)((uint)((ushort)(v0) >> (v0 & 7u))), (char)(reverse_bits(744953140u))), char2((char)((~940872595u)), (char)(in[(t * 4u + 0u)]))))))) & 7u] = (uchar)((uint)(min((int)(max(v0, in[(t * 4u + 3u)])), (int)((((v5 ^ t) & 1u) != 0u ? 140u : v5)))));\n"
    "        for (uint i1 = 0; i1 < 3u; i1++) {\n"
    "            v5 += i1 * 8u;\n"
    "            p[((~((int)(in[(t * 4u + 3u)]) < (int)(in[(t * 4u + 3u)]) ? v1 : in[(t * 4u + 1u)]))) & 7u] = in[(t * 4u + 0u)];\n"
    "            pc[((uint)(all(select(ushort2((ushort)((~(v1 ^ t))), (ushort)(insert_bits(92u, (v2 ^ t), (uint)(in[(t * 4u + 0u)] & 15u), (uint)(in[(t * 4u + 0u)] & 15u)))), ushort2((ushort)(27752), (ushort)(8006)), ushort2((ushort)(33485), (ushort)(41736)) < ushort2((ushort)(32759), (ushort)(11385))) < (ushort2((ushort)(26474), (ushort)(4144)) >> ushort2((ushort)(2), (ushort)(1)))))) & 7u] = (uchar)(min((v2 & in[(t * 4u + 1u)]), median3(97u, (v0 ^ t), 65536u)));\n"
    "        }\n"
    "    }\n"
    "    v5 = (uint)((int)((uint)((int)((short)((uint)(-(int)(129u & 0x7fffffffu))) / (short)((rotate(in[(t * 4u + 0u)], v5) & 32767u) | 1u)))) >> (int)((uint)((char)(((uint)((int)((short)(77u))) ^ v5))) & 31u));\n"
    "    atomic_fetch_add_explicit(&ta, (max((uint)(min((int)(v0), (int)((v2 ^ t)))), (uint)(-(int)(in[(t * 4u + 1u)] & 0x7fffffffu)))) & 255u, memory_order_relaxed);\n"
    "    if ((uint)(pc[((uint)(pc[(in[(t * 4u + 3u)]) & 7u])) & 7u]) > (in[(t * 4u + 3u)] > (uint)((uchar)((v5 ^ t)) >> (v0 & 7u)) ? in[(t * 4u + 1u)] : (uint)((ushort)(497776376u) + (ushort)(3850002871u)))) {\n"
    "        { uint4 w = uint4((mulhi((v2 ^ t), v5) != max(v2, (v2 ^ t)) ? (~255u) : ((v0 ^ t) / (122u | 1u))), v2, vf((char2((char)(madsat(440005935u, (v0 ^ t), 1262271067u)), (char)(v5)))), v1); w[((uint)((int)((uint)((ushort)(150u) >> (v0 & 7u))) / (int)((31u | 1u) & 0x7fffffffu))) & 3u] = v3; v0 += w[((v1 ^ t)) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    }\n"
    "    { uint4 w = uint4((((uint)((int)(in[(t * 4u + 2u)]) % (int)((in[(t * 4u + 3u)] | 1u) & 0x7fffffffu)) & 1u) != 0u ? max(in[(t * 4u + 2u)], in[(t * 4u + 0u)]) : (uint)((char)(in[(t * 4u + 0u)]))), v0, ((int)((uint)(pc[((v5 ^ t)) & 7u])) >= (int)((v0 ^ t)) ? (118u | in[(t * 4u + 3u)]) : ((v3 ^ t) & in[(t * 4u + 2u)])), v1); w[((((uint)(select((int)(in[(t * 4u + 2u)]), (int)(v1), (in[(t * 4u + 1u)] & 2u) != 0u)) % (((v3 % (2147483647u | 1u))) | 1u)))) & 3u] = ((v3 ^ t) / ((uint)(select((int)(v5), (int)((v4 ^ t)), (v1 & 2u) != 0u)) | 1u)); v5 += w[((uint)((ushort)((uint)((ushort)((v1 ^ t)) ^ (ushort)(v5))) / (ushort)(reverse_bits(in[(t * 4u + 1u)]) | 1u))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    { uint4 w = uint4(vf((((short4((short)(((v0 ^ t) >> ((v4 ^ t) & 31u))), (short)((uint)(!(v5 > 255u))), (short)(madsat(0u, in[(t * 4u + 2u)], 3830944184u)), (short)(clz((v4 ^ t)))) / ((short4((short)(mulhi(96u, 186u)), (short)(((uint)((ushort)(in[(t * 4u + 3u)])) * (uint)((ushort)(in[(t * 4u + 2u)])))), (short)(((int)(v1) < (int)((v0 ^ t)) ? in[(t * 4u + 1u)] : 872155700u)), (short)((uint)((ushort)(v2) - (ushort)(in[(t * 4u + 1u)]))))) & short4((short)(32767), (short)(32767), (short)(32767), (short)(32767)) | short4((short)(1), (short)(1), (short)(1), (short)(1)))) >> ((select(short4((short)(max(in[(t * 4u + 2u)], in[(t * 4u + 1u)])), (short)(rhadd(v2, v2)), (short)(insert_bits((v2 ^ t), 81u, (uint)(32u & 15u), (uint)(in[(t * 4u + 2u)] & 15u))), (short)((uint)(select((int)(v3), (int)((v5 ^ t)), (0u & 2u) != 0u)))), short4((short)((uint)((int)((v1 ^ t)) >> (int)(in[(t * 4u + 1u)] & 31u))), (short)((uint)((ushort)(in[(t * 4u + 2u)]) - (ushort)(v2))), (short)((uint)((int)(v2) >> (int)(v2 & 31u))), (short)((uint)((int)(in[(t * 4u + 3u)]) / (int)(((v3 ^ t) | 1u) & 0x7fffffffu)))), short4((short)(rotate(in[(t * 4u + 2u)], 4209838602u)), (short)((uint)((int)(34u) / (int)((v5 | 1u) & 0x7fffffffu))), (short)((uint)(!(v4 > v5))), (short)((uint)((int)((v0 ^ t)) >> (int)(v1 & 31u)))) > short4((short)(2334), (short)(15810), (short)(-30142), (short)(-13197)))) & short4((short)(15), (short)(15), (short)(15), (short)(15)))))), v0, ((short)(in[(t * 4u + 0u)]) >= (short)((uint)((bool)(in[(t * 4u + 0u)] & (v5 ^ t)))) ? (uint)((int)((v0 ^ t)) / (int)(((v1 ^ t) | 1u) & 0x7fffffffu)) : mulhi(v4, in[(t * 4u + 1u)])), v0); w[(extract_bits((in[(t * 4u + 1u)] / (3171158919u | 1u)), (uint)((uint)(pc[(v5) & 7u]) & 15u), (uint)(in[(t * 4u + 2u)] & 15u))) & 3u] = ((((211u % (0u | 1u))) & 1u) != 0u ? v0 : (uint)(max((int)(v0), (int)(70u)))); v0 += w[(((uint)(pc[(221u) & 7u]) > (uint)(!(4195405377u > v2)) ? in[(t * 4u + 3u)] : (uint)(max((int)((v3 ^ t)), (int)(v1))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    { tc[l] = (uchar)(vf(((uchar2((uchar)(51), (uchar)(241)) % uchar2((uchar)(20), (uchar)(46)))))); threadgroup_barrier(mem_flags::mem_threadgroup); v1 += (uint)(tc[(((uint)(max((int)(65535u), (int)(158u))) / (((int)((v5 ^ t)) > (int)(v3) ? in[(t * 4u + 2u)] : in[(t * 4u + 2u)]) | 1u))) & 63u]) * 112u; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    v2 -= (uint)((bool)((uint)((uchar)(((int)((v5 ^ t)) > (int)(in[(t * 4u + 2u)]) ? v4 : 256u)) ^ (uchar)(rotate(in[(t * 4u + 2u)], v4))) & ((uint)((int)(67u) / (int)((in[(t * 4u + 1u)] | 1u) & 0x7fffffffu)) > ((uint)((int)((short)((v5 ^ t)))) * (v4 ^ t)) ? ((v0 ^ t) ^ in[(t * 4u + 3u)]) : (in[(t * 4u + 0u)] >= 2147483648u ? in[(t * 4u + 2u)] : v2))));\n"
    "    v5 ^= (uint)((int)((char)(extract_bits(max(in[(t * 4u + 1u)], in[(t * 4u + 2u)]), (uint)((~4294967295u) & 15u), (uint)(in[(t * 4u + 0u)] & 15u))) % (char)(((uint)((int)((char)((uint)((ushort)(in[(t * 4u + 1u)]) ^ (ushort)(in[(t * 4u + 3u)]))) >> ((uint)((int)(3671485861u) >> (int)(1713678969u & 31u)) & 7u))) & 127u) | 1u)));\n"
    "    pc[(absdiff(mulhi((v2 ^ t), (v3 ^ t)), ((61373575u & 1u) != 0u ? (v1 ^ t) : v4))) & 7u] = (uchar)((~(uint)((char)(v5))));\n"
    "    for (uint i0 = 0; i0 < 3u; i0++) {\n"
    "        v0 += i0 * 4u;\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v4 = (uint)((int)((char)(popcount((v5 ^ t))) % (char)((((((uint)((ushort)(113u)) * (uint)((ushort)((v2 ^ t)))) & 1u) != 0u ? min((v0 ^ t), 3664873032u) : madhi(v4, 2349869421u, in[(t * 4u + 1u)])) & 127u) | 1u)));\n"
    "            if ((((uint)(!(1u > (uint)(!(3574222096u > 2147483648u))))) & 3u) == 0u) break; } v2 += n1; }\n"
    "    }\n"
    "    v1 ^= vf((((short4((short)(22133), (short)(-5133), (short)(1936), (short)(-3979)) >> short4((short)(14), (short)(14), (short)(4), (short)(5))) & (short4((short)(-20475), (short)(22342), (short)(22171), (short)(31272)) & short4((short)((uint)(min((int)(v5), (int)(v4)))), (short)((uint)((uchar)((v5 ^ t)) ^ (uchar)(v0))), (short)(insert_bits(in[(t * 4u + 1u)], 2u, (uint)(v1 & 15u), (uint)(v3 & 15u))), (short)((uint)((int)(in[(t * 4u + 3u)]) >> (int)((v1 ^ t) & 31u))))))));\n"
    "    switch ((vf(((char2((char)(min(1u, (v3 ^ t))), (char)((uint)((bool)((v0 ^ t) & v2)))) | (char2((char)((uint)((int)((v3 ^ t)) / (int)(((v5 ^ t) | 1u) & 0x7fffffffu))), (char)((uint)((ushort)((v4 ^ t)) >> ((v5 ^ t) & 7u)))) >> ((char2((char)(v1), (char)((uint)(pc[(in[(t * 4u + 2u)]) & 7u])))) & char2((char)(7), (char)(7)))))))) & 3u) {\n"
    "    case 0u: {\n"
    "        v2 = ((uint)((uchar)((uint)(-(int)(0u & 0x7fffffffu))) >> (v0 & 7u)) / ((uint)((ushort)(subsat(in[(t * 4u + 3u)], in[(t * 4u + 2u)])) >> (231u & 7u)) | 1u));\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        v3 += min3((uint)((int)((char)((v1 ^ in[(t * 4u + 3u)])) >> (insert_bits(183u, v3, (uint)(65536u & 15u), (uint)(in[(t * 4u + 0u)] & 15u)) & 7u))), (uint)(max((int)((2147483647u * v3)), (int)(max(v3, in[(t * 4u + 3u)])))), vf(((uchar2((uchar)(108), (uchar)(53))).yx)));\n"
    "        break; }\n"
    "    case 2u: {\n"
    "        v1 -= (uint)((uchar)(vf((ushort4((ushort)(31136), (ushort)(49309), (ushort)(38751), (ushort)(29870))))) ^ (uchar)(((short)(((uint)((ushort)((v1 ^ t))) * (uint)((ushort)(165u)))) >= (short)((uint)((ushort)(v4) - (ushort)(v1))) ? (~(v5 ^ t)) : (in[(t * 4u + 2u)] & in[(t * 4u + 1u)]))));\n"
    "        v4 += max3((uint)((uchar)((in[(t * 4u + 0u)] != 3610165322u ? in[(t * 4u + 0u)] : (v3 ^ t))) >> ((256u ^ 2147483647u) & 7u)), (in[(t * 4u + 0u)] == ((1135663961u & 1u) != 0u ? in[(t * 4u + 1u)] : (v4 ^ t)) ? ((v0 ^ t) / (in[(t * 4u + 3u)] | 1u)) : (uint)((bool)(in[(t * 4u + 0u)] & 89u))), (v5 ^ t));\n"
    "        break; }\n"
    "    default: {\n"
    "        v3 = (uint)(max((int)((uint)(min((int)((uint)((int)(1583983570u) >> (int)((v3 ^ t) & 31u))), (int)((uint)((ushort)(256u)))))), (int)(((v2 & (v1 ^ t)) >> ((~(v1 ^ t)) & 31u)))));\n"
    "        break; }\n"
    "    }\n"
    "    v3 = (vf((char4((char)(-94), (char)(-50), (char)(17), (char)(-127)))) * (uint)(-(int)((v1 ^ t) & 0x7fffffffu)));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        p[((uint)(all((uchar3((uchar)(6), (uchar)(45), (uchar)(116)) * uchar3((uchar)(116), (uchar)(42), (uchar)(14))) <= select(uchar3((uchar)((32u << (v3 & 31u))), (uchar)(((int)(2147483647u) > (int)(in[(t * 4u + 1u)]) ? v4 : v3)), (uchar)(0u)), uchar3((uchar)((uint)((uchar)(in[(t * 4u + 1u)]) >> ((v5 ^ t) & 7u))), (uchar)(rotate(v2, (v3 ^ t))), (uchar)(insert_bits(v1, v1, (uint)(in[(t * 4u + 0u)] & 15u), (uint)(in[(t * 4u + 1u)] & 15u)))), uchar3((uchar)(0), (uchar)(3), (uchar)(233)) != uchar3((uchar)(v4), (uchar)((uint)((uchar)(256u) >> (v2 & 7u))), (uchar)((~181u))))))) & 7u] = vf((ushort3((ushort)(min(in[(t * 4u + 0u)], in[(t * 4u + 0u)])), (ushort)(mulhi(in[(t * 4u + 0u)], 32u)), (ushort)(((int)((v0 ^ t)) >= (int)((v0 ^ t)) ? (v0 ^ t) : 2147483648u)))));\n"
    "        if (((in[(t * 4u + 0u)]) & 3u) == 0u) break; } v5 += n0; }\n"
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
    0x238fd330u, 0x3ca194b2u, 0x4696f21du, 0x39b43851u, 0x1ea197beu, 0xe8ef31c1u, 0xa903f0a5u, 0x79dfcbefu,
    0x273b5e1du, 0xe3fd52c0u, 0xdaeeb149u, 0xd4227d0bu, 0x4263c073u, 0x80065d82u, 0xe1da1627u, 0x80a700b3u,
    0x969156adu, 0x20512b16u, 0x3176322cu, 0xad8197f5u, 0xfce0b208u, 0xa4481b7au, 0x5257c13eu, 0xf831b43au,
    0x11d1eb1eu, 0x2dbc26bdu, 0x5e91c50eu, 0x6bdec09bu, 0x4f8e72b9u, 0x0c9b70e1u, 0x6c0d8154u, 0x3ba542a0u,
    0xc9b825a2u, 0x90c37352u, 0xbfff66d8u, 0x22fb8a93u, 0x7002b7f6u, 0xff59f1b9u, 0x4d93084du, 0x22003c9au,
    0x12cd291bu, 0x72175908u, 0xd22ab3a3u, 0xf0c0bcb3u, 0x3d973b44u, 0xddf43615u, 0x342b79eau, 0xb9379672u,
    0x013d793bu, 0x3ebbf682u, 0x6e55e907u, 0x36296b24u, 0xe71a9df1u, 0x1ce4f61du, 0x254699cfu, 0x182232b8u,
    0x6e2f67c3u, 0x9b2b579fu, 0x6f6e4cc3u, 0x898be759u, 0x63b956b3u, 0xf0ee770cu, 0xcf4bff37u, 0xe146852cu,
    0x8936515fu, 0x1fe21d31u, 0x049fc028u, 0x398d26cau, 0xa350bda0u, 0xfaeef0ceu, 0x7a3bb0deu, 0x2efb8582u,
    0xb4f59e4du, 0x8c3830bau, 0xffe8db80u, 0x3e31247fu, 0xb36d6272u, 0x61015da3u, 0x92f2a669u, 0xb1fd2660u,
    0x1187baceu, 0xc8ccf3bdu, 0xa9e6dd52u, 0xe6f67b97u, 0x4e2f8a23u, 0x93343521u, 0xd3203b40u, 0x55112488u,
    0xb1faafdcu, 0x94c2b5dcu, 0xa501be82u, 0x3ac9354cu, 0xaf7f6f61u, 0xa73db49au, 0x10f68bcbu, 0xc5fcae0du,
    0x6bfc4518u, 0x7ff46af1u, 0x0550815fu, 0x7311da51u, 0xa6f114a2u, 0x2a704830u, 0x04fe1163u, 0xa8d150ddu,
    0x2c9fc44eu, 0x3788ed31u, 0xd0ba1dbfu, 0xb7148161u, 0x34d96f53u, 0xf6caddcau, 0x05d5ba12u, 0x1736a0f4u,
    0xd3d39839u, 0x7b0ff6ceu, 0x20917045u, 0x852f2fafu, 0x726bfe30u, 0xa7f16d6au, 0x5499c6b0u, 0xad89de20u,
    0x18ab5ee9u, 0xb2409f2cu, 0x95ad6eeau, 0xa380afebu, 0x9f3c7b21u, 0x3c12ae27u, 0x20d8d2beu, 0xa28942c0u,
    0xe1b1e33bu, 0xa6a55324u, 0x01e8f704u, 0xb4d38821u, 0xf5fe10dfu, 0x2d5e88f5u, 0x7c0739c1u, 0xc644996fu,
    0x1394048du, 0x79b5c264u, 0xb7957d23u, 0x6a6c5b0cu, 0x1ef5534eu, 0x3575d4f3u, 0x45d3a123u, 0xc6773787u,
    0xcea7b6aeu, 0x7aa52f37u, 0xcb6b08f8u, 0x8f33e6a7u, 0xb7912083u, 0x6fb8c99fu, 0x15ac1c83u, 0x654b127du,
    0x013efa5bu, 0x5467b70bu, 0x293a5298u, 0x39e74c8bu, 0xbc0278d9u, 0x24f38563u, 0x4ef81aa3u, 0x755ee9deu,
    0xa003e9fau, 0x24637a9bu, 0xa35bcc56u, 0xc5e7c61fu, 0xd19f523cu, 0xc93e3ea8u, 0x813ca73eu, 0x41e4b677u,
    0x11e0b11fu, 0x0610a2aau, 0xaeea165bu, 0x8557b72au, 0x3053ececu, 0xf1762f54u, 0x74216c93u, 0xfc269903u,
    0x260e1d79u, 0x5dd5826cu, 0x47ff79aau, 0xf511c361u, 0xdbe063f6u, 0x24d0c7c0u, 0x691a23aeu, 0x801c7bf9u,
    0x44277e1cu, 0xefe71019u, 0x1000b0ebu, 0x160bf65fu, 0xa5fd50f6u, 0x96fae2abu, 0xea16305bu, 0x4a2b03ffu,
    0xb3b11f7eu, 0x122b7f17u, 0xaf9d2d52u, 0xe5abd4fcu, 0x70759488u, 0x0fc02a57u, 0x9aec188du, 0xc73d9406u,
    0xf7111c0fu, 0x0a651fe1u, 0x05cded03u, 0x94ca1903u, 0xac78e433u, 0x055c6185u, 0x3feb58d9u, 0x5a0286b8u,
    0xeb920aa3u, 0x2aef23a0u, 0x608a3f96u, 0xf409a02eu, 0x351f2fa5u, 0x9dfa39c6u, 0x237ca797u, 0xa0079a15u,
    0x72c1fe45u, 0x2ae989c5u, 0x2afb295au, 0x6a12c5c1u, 0xbfc15aa5u, 0xff52b83au, 0x222c38ecu, 0x476a7b26u,
    0x81b556aau, 0xcc214295u, 0x9c2098d3u, 0xfe9cabb2u, 0xc9d713a2u, 0xf0716591u, 0xec523ab4u, 0x6a4bf4e5u,
    0x23d7372du, 0x67769d44u, 0x270ed441u, 0x8eb153d2u, 0x32c1f68bu, 0x0160279fu, 0x1ad1074cu, 0xa8c8c811u,
    0x9bfd48a5u, 0xd7020186u, 0x856be6e3u, 0xcd469a08u, 0x9410d70du, 0xbd9026d2u, 0x63ca686bu, 0xd38faf91u,
    0xbccf7368u, 0x267ef78bu, 0xfa62da9au, 0x5f5b2968u, 0x2e1452a9u, 0x703dba07u, 0x7c98821eu, 0xa9a85653u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n40-kepler-private-final-loads";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    return reproFuzzKernel(bug, dev, src, want, "a kernel's final loads of its private arrays leave the rest of it right");
}}
