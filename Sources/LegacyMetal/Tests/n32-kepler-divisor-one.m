// n32-kepler-divisor-one (Kepler adapter, NVAIR_DIVISOR_ONE_FIX): the remainder by a divisor that turns out to be 1, in
// a big kernel. 0xffffffff % b with b = (31 * x) | 1 equal to 1 came out as 766 instead of 0 for one thread
// (mslfuzz2.py VEC=1 seed 3841, unreduced: reducing it swapped in another miscompile that the fix doesn't touch); the same
// kernel with the operands written out was right. A select on b == 1
// fixes it and the same select on b == 2 doesn't: the divisor-1 path of Kepler's division, which always takes its final
// correction step. The kernel on the fuzzer's inputs (seed 1, 256 threads in groups of 64, compiled without fast
// math, as the fuzzer does): each thread's 8 output words against the CPU reference (cpuref.py), as one FNV-1a hash per
// thread.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
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
    "    switch ((subsat(insert_bits(in[(t * 4u + 0u)], 227u, (uint)(in[(t * 4u + 3u)] & 15u), (uint)(99u & 15u)), (uint)(!(0u > in[(t * 4u + 1u)])))) & 3u) {\n"
    "    case 0u: {\n"
    "        p[(((uint)((ushort)((uint)((bool)((v4 ^ t) & in[(t * 4u + 0u)])))) * (uint)((ushort)((uint)((char)(256u)))))) & 7u] = subsat((uint)(pc[(90812343u) & 7u]), 137u);\n"
    "        if ((uint)(all((short3((short)(7375), (short)(14143), (short)(22848))).zxy >= short3((short)(reverse_bits((v4 ^ t))), (short)(v3), (short)(absdiff(2147483648u, in[(t * 4u + 3u)]))))) != (uint)((int)((short)(((v4 % (v3 | 1u)))) >> (insert_bits((v2 ^ t), 56u, (uint)(in[(t * 4u + 3u)] & 15u), (uint)(in[(t * 4u + 1u)] & 15u)) & 15u)))) {\n"
    "            v4 = madhi(insert_bits(min((v4 ^ t), v4), (uint)((int)(in[(t * 4u + 0u)]) / (int)((in[(t * 4u + 2u)] | 1u) & 0x7fffffffu)), (uint)((uint)((ushort)(0u) - (ushort)(1877674488u)) & 15u), (uint)(min(65536u, 32u) & 15u)), (uint)((ushort)((v4 ^ t))), max((uint)((int)((v4 ^ t)) % (int)((in[(t * 4u + 3u)] | 1u) & 0x7fffffffu)), ((v5 ^ t) >> (1793496753u & 31u))));\n"
    "        } else {\n"
    "            v1 -= (uint)(all((uchar3((uchar)((uint)(min((int)((v1 ^ t)), (int)(205u)))), (uchar)(((v4 ^ t) >> (v5 & 31u))), (uchar)(absdiff(v5, (v4 ^ t))))).zxy >= min(uchar3((uchar)(min3(v3, (v0 ^ t), v2)), (uchar)(max3(v5, v2, in[(t * 4u + 2u)])), (uchar)((uint)(pc[(1123019218u) & 7u]))), uchar3((uchar)(16), (uchar)(109), (uchar)(103)))));\n"
    "            v0 = popcount(((uint)((ushort)((uint)((int)(v3) >> (int)(in[(t * 4u + 0u)] & 31u)))) * (uint)((ushort)((uint)((bool)((v2 ^ t) & in[(t * 4u + 0u)]))))));\n"
    "        }\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        { uint4 w = uint4(((int)((uint)((int)(226u) >> (int)((v5 ^ t) & 31u))) <= (int)(v4) ? (uint)((int)((v3 ^ t)) >> (int)(v5 & 31u)) : 2520722754u), v5, vf(((select(ushort2((ushort)(5281), (ushort)(7486)), ushort2((ushort)(34743), (ushort)(65169)), ushort2((ushort)(14296), (ushort)(56499)) <= ushort2((ushort)(64802), (ushort)(35023))) & as_type<ushort2>(char4((char)(-59), (char)(-39), (char)(-117), (char)(-61)))))), v4); w[(((uint)((uchar)(in[(t * 4u + 0u)]) >> (v0 & 7u)) / (v1 | 1u))) & 3u] = (uint)((ushort)(extract_bits((v5 ^ t), (uint)((v4 ^ t) & 15u), (uint)((v0 ^ t) & 15u))) + (ushort)((uint)(!(108u > in[(t * 4u + 0u)])))); v5 += w[((~(uint)((uchar)(90u) >> (v0 & 7u)))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        v1 = ((uint)((int)((char)(vf((as_type<uchar4>(ushort2((ushort)((uint)(pc[(v0) & 7u])), (ushort)((uint)((int)(176u) / (int)((v5 | 1u) & 0x7fffffffu)))))))))) + ((uint)(-(int)(256u & 0x7fffffffu)) / ((((v1 ^ t) & 1u) != 0u ? (v3 ^ t) : v2) | 1u)));\n"
    "        }\n"
    "    case 2u: {\n"
    "        { uint4 w = uint4((v0 ^ t), v1, rotate((uint)((bool)(1191389825u & (v5 ^ t))), (23u * v4)), v0); w[((uint)(min((int)((uint)((int)((v4 ^ t)) >> (int)(v0 & 31u))), (int)((uint)(select((int)(32u), (int)(1619487733u), (v3 & 2u) != 0u)))))) & 3u] = (uint)(select((int)((uint)((int)(805935084u) / (int)(((v3 ^ t) | 1u) & 0x7fffffffu))), (int)((uint)((ushort)((v4 ^ t)))), (rotate(153u, in[(t * 4u + 1u)]) & 2u) != 0u)); v2 += w[(reverse_bits((uint)(max((int)(v1), (int)(in[(t * 4u + 0u)]))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        break; }\n"
    "    default: {\n"
    "        v2 = (uint)((uchar)(((char)(min(32u, (v1 ^ t))) != (char)((in[(t * 4u + 2u)] < v0 ? v3 : (v2 ^ t))) ? rotate((v5 ^ t), (v5 ^ t)) : ((uint)((ushort)(4294967295u)) * (uint)((ushort)(v4))))) % (uchar)(min3((uint)((uchar)(v5) >> (in[(t * 4u + 2u)] & 7u)), (uint)(!((v4 ^ t) > v0)), ((v4 ^ t) / (v5 | 1u))) | 1u));\n"
    "        break; }\n"
    "    }\n"
    "    atomic_fetch_add_explicit(&ta, (in[(t * 4u + 2u)]) & 255u, memory_order_relaxed);\n"
    "    v5 ^= (uint)((ushort)(rotate((uint)((uchar)((v4 ^ t)) - (uchar)((v5 ^ t))), ((uint)((ushort)(255u)) * (uint)((ushort)(396614887u))))) >> ((uint)((int)((uchar)((v3 ^ t)) >> (((3152142273u % (v4 | 1u))) & 7u))) & 7u));\n"
    "    { tg[l] = ((int)((uint)((int)(in[(t * 4u + 3u)]) >> (int)((v2 ^ t) & 31u))) >= (int)(rhadd((v0 ^ t), (v0 ^ t))) ? (uint)((ushort)((v1 ^ t)) >> (in[(t * 4u + 0u)] & 7u)) : mulhi(in[(t * 4u + 1u)], v0)); threadgroup_barrier(mem_flags::mem_threadgroup); v3 += tg[(rotate((in[(t * 4u + 3u)] == (v0 ^ t) ? 1326152688u : v5), (uint)(select((int)(3920244664u), (int)(v4), (v1 & 2u) != 0u)))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    { tg[l] = (uint)((int)((char)((in[(t * 4u + 2u)] / ((v2 ^ t) | 1u))) % (char)(((uint)(min((int)((v4 ^ t)), (int)(in[(t * 4u + 1u)]))) & 127u) | 1u))); threadgroup_barrier(mem_flags::mem_threadgroup); v2 += tg[((uint)(select((int)(insert_bits((v2 ^ t), (v0 ^ t), (uint)(v3 & 15u), (uint)(117u & 15u))), (int)((~v2)), ((2782437556u | (v3 ^ t)) & 2u) != 0u))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    p[(((uint)((ushort)(((v0 & 1u) != 0u ? v4 : in[(t * 4u + 1u)]))) * (uint)((ushort)((107u >> ((v1 ^ t) & 31u)))))) & 7u] = (uint)((ushort)((uint)((short)(in[(t * 4u + 1u)]))) + (ushort)(addsat(65u, (v1 ^ t))));\n"
    "    switch (((uint)((int)((v5 >= (v1 ^ t) ? 2770962999u : 0u)) / (int)((((v2 ^ t) >> (203u & 31u)) | 1u) & 0x7fffffffu))) & 3u) {\n"
    "    case 0u: {\n"
    "        { uint4 w = uint4(((ushort)(((v2 % (3373626653u | 1u)))) > (ushort)((uint)((uchar)(in[(t * 4u + 2u)]) * (uchar)(114u))) ? extract_bits(in[(t * 4u + 3u)], (uint)(2792785950u & 15u), (uint)(49u & 15u)) : ((246u % (4294967295u | 1u)))), v5, ((uint)((int)((short)((uint)(min((int)(in[(t * 4u + 3u)]), (int)(in[(t * 4u + 0u)])))))) - in[(t * 4u + 0u)]), v0); w[(extract_bits((~4250167165u), (uint)((uint)(select((int)(v1), (int)(v4), (v1 & 2u) != 0u)) & 15u), (uint)((uint)(!(in[(t * 4u + 1u)] > 2929151956u)) & 15u))) & 3u] = (v3 ^ t); v1 += w[((uint)((int)((130u / (v2 | 1u))) / (int)(((v4 >= 65536u ? 141u : v0) | 1u) & 0x7fffffffu))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        v2 = vf((short2((short)(-6993), (short)(-15594))));\n"
    "        break; }\n"
    "    case 1u: {\n"
    "        atomic_fetch_add_explicit(&ta, ((uint)((uchar)((uint)((int)(31u) % (int)((in[(t * 4u + 3u)] | 1u) & 0x7fffffffu))) - (uchar)((uint)((ushort)(51u) >> ((v0 ^ t) & 7u))))) & 255u, memory_order_relaxed);\n"
    "        { uint4 w = uint4(in[(t * 4u + 1u)], v5, (uint)(all(select(ushort4((ushort)(34221), (ushort)(2736), (ushort)(11596), (ushort)(22076)), ushort4((ushort)((uint)((bool)(v5 & 429645168u))), (ushort)((v3 ^ t)), (ushort)(256u), (ushort)(insert_bits(v4, in[(t * 4u + 2u)], (uint)(v1 & 15u), (uint)(v2 & 15u)))), ushort4((ushort)(16266), (ushort)(15038), (ushort)(60744), (ushort)(13282)) <= ushort4((ushort)(21187), (ushort)(5973), (ushort)(23933), (ushort)(50438))) > (ushort4((ushort)((uint)(max((int)(in[(t * 4u + 0u)]), (int)(in[(t * 4u + 3u)])))), (ushort)((~212u)), (ushort)(extract_bits(v3, (uint)(v5 & 15u), (uint)(v1 & 15u))), (ushort)(extract_bits(in[(t * 4u + 2u)], (uint)(in[(t * 4u + 3u)] & 15u), (uint)(31u & 15u)))) & ushort4((ushort)((107u * in[(t * 4u + 3u)])), (ushort)(((in[(t * 4u + 1u)] % ((v3 ^ t) | 1u)))), (ushort)((uint)((short)((v2 ^ t)))), (ushort)(insert_bits(in[(t * 4u + 1u)], 32u, (uint)(v0 & 15u), (uint)((v2 ^ t) & 15u))))))), v4); w[((uint)((uchar)((uint)((ushort)(v2) >> ((v0 ^ t) & 7u))) / (uchar)(min((v2 ^ t), v5) | 1u))) & 3u] = (uint)(select((int)(insert_bits(199u, 1u, (uint)((v5 ^ t) & 15u), (uint)(1709084883u & 15u))), (int)(in[(t * 4u + 3u)]), ((uint)((uchar)(31u) >> ((v3 ^ t) & 7u)) & 2u) != 0u)); v3 += w[(vf((as_type<short2>((char4((char)((uint)((int)((v0 ^ t)) % (int)(((v3 ^ t) | 1u) & 0x7fffffffu))), (char)((uint)(pc[(in[(t * 4u + 2u)]) & 7u])), (char)((uint)((int)(v0) % (int)((v0 | 1u) & 0x7fffffffu))), (char)(madsat(v1, in[(t * 4u + 0u)], (v3 ^ t)))) >> char4((char)(0), (char)(7), (char)(4), (char)(6))))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        break; }\n"
    "    case 2u: {\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            p[((uint)((int)((short)((uint)(max((int)(v3), (int)(in[(t * 4u + 0u)])))) / (short)((((v2 ^ t) / ((v5 ^ t) | 1u)) & 32767u) | 1u)))) & 7u] = (uint)((int)((uint)((ushort)((v0 ^ t)) - (ushort)(in[(t * 4u + 0u)]))) / (int)((132234534u | 1u) & 0x7fffffffu));\n"
    "            if ((((uint)((uchar)(v1) / (uchar)(rotate(in[(t * 4u + 2u)], in[(t * 4u + 0u)]) | 1u))) & 3u) == 0u) break; } v4 += n1; }\n"
    "        }\n"
    "    default: {\n"
    "        atomic_fetch_add_explicit(&ta, ((uint)(all(uchar3((uchar)((uint)((ushort)(2147483647u) >> (in[(t * 4u + 0u)] & 7u))), (uchar)(extract_bits(26u, (uint)(in[(t * 4u + 1u)] & 15u), (uint)((v3 ^ t) & 15u))), (uchar)((uint)((int)((v1 ^ t)) >> (int)(161u & 31u)))) <= uchar3((uchar)((uint)(!((v1 ^ t) > 126u))), (uchar)((v1 ^ t)), (uchar)((uint)(pc[(4094496893u) & 7u])))))) & 255u, memory_order_relaxed);\n"
    "        break; }\n"
    "    }\n"
    "    { tc[l] = (uchar)(vf((((short4((short)(11239), (short)(23068), (short)(-4658), (short)(-5868)) & short4((short)((uint)((uchar)((v1 ^ t)))), (short)(insert_bits(in[(t * 4u + 1u)], 107u, (uint)(in[(t * 4u + 0u)] & 15u), (uint)(in[(t * 4u + 2u)] & 15u))), (short)((uint)((ushort)(in[(t * 4u + 3u)]) >> ((v3 ^ t) & 7u))), (short)((uint)((int)(v1) >> (int)(4294967295u & 31u))))) ^ short4((short)((uint)(select((int)(in[(t * 4u + 1u)]), (int)((v3 ^ t)), (v0 & 2u) != 0u))), (short)((uint)((int)(v0) >> (int)(65536u & 31u))), (short)(v2), (short)(min3(in[(t * 4u + 0u)], 2682233542u, 31u))))))); threadgroup_barrier(mem_flags::mem_threadgroup); v4 += (uint)(tc[((v3 ^ t)) & 63u]) * 134u; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    pc[(reverse_bits(((v1 % (in[(t * 4u + 1u)] | 1u))))) & 7u] = (uchar)((~(uint)((int)((v0 ^ t)) % (int)((2u | 1u) & 0x7fffffffu))));\n"
    "    { uint4 w = uint4(v4, v2, ((uint)(min((int)(v1), (int)(v0))) > (uint)(!(1380220709u > in[(t * 4u + 0u)])) ? madsat((v3 ^ t), in[(t * 4u + 1u)], (v0 ^ t)) : (uint)((char)((v0 ^ t)))), v5); w[(mulhi(((in[(t * 4u + 0u)] & 1u) != 0u ? v0 : v4), (uint)((int)((v4 ^ t)) % (int)(((v2 ^ t) | 1u) & 0x7fffffffu)))) & 3u] = in[(t * 4u + 2u)]; v5 += w[((uint)((int)((short)((uint)(max((int)((v4 ^ t)), (int)(in[(t * 4u + 2u)])))) >> ((uint)((int)(v1) / (int)((v1 | 1u) & 0x7fffffffu)) & 15u)))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    { uint4 w = uint4((((((v0 ^ t) & 1u) != 0u ? (v1 ^ t) : (v5 ^ t)) & 1u) != 0u ? (403465768u << (4294967295u & 31u)) : (uint)(min((int)((v4 ^ t)), (int)(in[(t * 4u + 3u)])))), v0, (uint)(max((int)(median3(v5, (v0 ^ t), (v4 ^ t))), (int)(madhi(in[(t * 4u + 1u)], (v2 ^ t), v3)))), v2); w[(vf((((ushort3((ushort)(41243), (ushort)(63786), (ushort)(397))).zxy << ((select(ushort3((ushort)(59843), (ushort)(22610), (ushort)(21812)), ushort3((ushort)((uint)((int)(2u) / (int)((in[(t * 4u + 3u)] | 1u) & 0x7fffffffu))), (ushort)(((uint)((int)((char)((v4 ^ t)))) - v0)), (ushort)((uint)((ushort)(v3) + (ushort)((v4 ^ t))))), ushort3((ushort)(rotate(v0, v0)), (ushort)(popcount(v5)), (ushort)((v2 / ((v3 ^ t) | 1u)))) <= ushort3((ushort)(25926), (ushort)(60066), (ushort)(56354)))) & ushort3((ushort)(15), (ushort)(15), (ushort)(15))))))) & 3u] = ((uint)((ushort)((v4 << ((v0 ^ t) & 31u)))) * (uint)((ushort)(min(v0, v3)))); v3 += w[(vf((((uchar2((uchar)(rotate((v1 ^ t), (v0 ^ t))), (uchar)(((v1 % ((v5 ^ t) | 1u))))) & uchar2((uchar)(185), (uchar)(11))) << uchar2((uchar)(2), (uchar)(7)))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    v1 ^= (((uint)((int)((short)(rotate((v5 ^ t), v0)) / (short)((256u & 32767u) | 1u))) % (((uint)((ushort)(31u)) * (uint)((ushort)(((int)((v0 ^ t)) <= (int)(32u) ? (v2 ^ t) : 179u)))) | 1u)));\n"
    "    v1 ^= p[((uint)(any((char2((char)(v0), (char)(((v3 ^ t) == 722663695u ? in[(t * 4u + 2u)] : (v0 ^ t)))) % char2((char)(34), (char)(80))) <= min(char2((char)(-95), (char)(-88)), char2((char)(78), (char)(-120)))))) & 7u];\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v3 = (uint)((int)(vf((min((short4((short)((~129u)), (short)(rotate(1985374054u, in[(t * 4u + 1u)])), (short)(v2), (short)((in[(t * 4u + 0u)] / (v5 | 1u)))) / ((short4((short)(20176), (short)(-25566), (short)(-19240), (short)(-30085))) & short4((short)(32767), (short)(32767), (short)(32767), (short)(32767)) | short4((short)(1), (short)(1), (short)(1), (short)(1)))), short4((short)(mulhi(256u, v5)), (short)((uint)(-(int)(57u & 0x7fffffffu))), (short)((uint)(pc[((v1 ^ t)) & 7u])), (short)((uint)(pc[(in[(t * 4u + 0u)]) & 7u]))))))) % (int)((((1u & in[(t * 4u + 2u)]) ^ (in[(t * 4u + 0u)] / (1u | 1u))) | 1u) & 0x7fffffffu));\n"
    "        switch ((vf(((char2((char)(94), (char)(89))).yx))) & 3u) {\n"
    "        case 0u: {\n"
    "            v1 = vf(((select(char2((char)(45), (char)(49)), char2((char)((((v5 ^ t) & 1u) != 0u ? 40u : in[(t * 4u + 2u)])), (char)(extract_bits(256u, (uint)(in[(t * 4u + 1u)] & 15u), (uint)((v0 ^ t) & 15u)))), char2((char)(-24), (char)(22)) != char2((char)((uint)(-(int)(in[(t * 4u + 3u)] & 0x7fffffffu))), (char)((uint)((int)((v5 ^ t)) / (int)((in[(t * 4u + 2u)] | 1u) & 0x7fffffffu)))))).yx));\n"
    "            break; }\n"
    "        default: {\n"
    "            p[(popcount(((int)(3616195475u) > (int)((v0 ^ t)) ? in[(t * 4u + 3u)] : 2147483648u))) & 7u] = (uint)((ushort)(max3((v4 ^ t), (v3 ^ t), in[(t * 4u + 2u)])) >> ((uint)((uchar)(v3) - (uchar)(in[(t * 4u + 2u)])) & 7u));\n"
    "            break; }\n"
    "        }\n"
    "        if (((((uint)((uchar)(in[(t * 4u + 1u)]) >> (v0 & 7u)) & ((v4 ^ t) << (v1 & 31u)))) & 3u) == 0u) break; } v1 += n0; }\n"
    "    v5 -= ((uint)((ushort)(vf((uchar3((uchar)(131), (uchar)(3), (uchar)(29)))))) * (uint)((ushort)(hadd((v1 ^ t), ((uint)((ushort)(in[(t * 4u + 0u)])) * (uint)((ushort)(3362596366u)))))));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v0 = (uint)((int)((short)((uint)((int)((v0 / ((v4 ^ t) | 1u))) / (int)(((uint)(min((int)(in[(t * 4u + 2u)]), (int)((v4 ^ t)))) | 1u) & 0x7fffffffu))) >> ((((uint)((uchar)(70u) >> ((v2 ^ t) & 7u)) % (((int)(3167758867u) > (int)(4010735100u) ? (v5 ^ t) : v4) | 1u))) & 15u)));\n"
    "            v5 = (uint)(any(uchar4((uchar)(ctz(31u)), (uchar)((uint)((ushort)(200u) >> (204u & 7u))), (uchar)((uint)((int)(in[(t * 4u + 0u)]) % (int)((179u | 1u) & 0x7fffffffu))), (uchar)((v5 | 143u))) < (uchar4((uchar)(v3), (uchar)((v2 ^ t)), (uchar)(142u), (uchar)(((184u & 1u) != 0u ? v4 : (v4 ^ t)))) & uchar4((uchar)(16), (uchar)(188), (uchar)(163), (uchar)(98)))));\n"
    "            if ((((uint)((int)((uint)((int)(in[(t * 4u + 1u)]) / (int)(((v4 ^ t) | 1u) & 0x7fffffffu))) >> (int)((~1041470397u) & 31u))) & 3u) == 0u) break; } v1 += n1; }\n"
    "        if ((((in[(t * 4u + 1u)] / ((((v3 ^ t) & 1u) != 0u ? (v4 ^ t) : (v4 ^ t)) | 1u))) & 3u) == 0u) break; } v3 += n0; }\n"
    "    v4 -= vf((uchar3((uchar)((uint)(pc[((v4 ^ t)) & 7u])), (uchar)(255u), (uchar)(((v2 & 1u) != 0u ? 11u : 3414423916u)))));\n"
    "    pc[((uint)((uchar)((uint)(min((int)(in[(t * 4u + 1u)]), (int)(231u)))))) & 7u] = (uchar)((uint)(max((int)(popcount(in[(t * 4u + 3u)])), (int)((uint)(select((int)(v1), (int)((v1 ^ t)), (v5 & 2u) != 0u))))));\n"
    "    v4 -= (uint)(-(int)(min(mulhi(133u, in[(t * 4u + 3u)]), extract_bits(1148503705u, (uint)(v3 & 15u), (uint)(in[(t * 4u + 0u)] & 15u))) & 0x7fffffffu));\n"
    "    v2 ^= p[(vf((as_type<char4>((ushort2((ushort)(rotate(v5, 2820870678u)), (ushort)(252u)) << ((ushort2((ushort)(((in[(t * 4u + 3u)] & 1u) != 0u ? 174u : 4294967295u)), (ushort)(clz(in[(t * 4u + 3u)])))) & ushort2((ushort)(15), (ushort)(15)))))))) & 7u];\n"
    "    v4 ^= vf((char3((char)(((v4 ^ t) == v4 ? (v3 ^ t) : (v3 ^ t))), (char)(v2), (char)((uint)((int)(196u) / (int)((v4 | 1u) & 0x7fffffffu))))));\n"
    "    { tc[l] = (uchar)((uint)((int)((uchar)(mulhi(in[(t * 4u + 0u)], v3)) >> (rotate(2195765117u, 3320023998u) & 7u)))); threadgroup_barrier(mem_flags::mem_threadgroup); v3 += (uint)(tc[(((uint)((ushort)(3u) | (ushort)((v3 ^ t))) & (uint)(pc[(v4) & 7u]))) & 63u]) * 16u; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    v0 += (((uint)(!(4172375616u > (uint)((bool)(v3 & v2)))) & 1u) != 0u ? (v5 ^ t) : vf((ushort3((ushort)(37052), (ushort)(35529), (ushort)(16451)))));\n"
    "    switch (((uint)((bool)((94u >> (in[(t * 4u + 2u)] & 31u)) & ((v4 ^ t) << ((v5 ^ t) & 31u))))) & 3u) {\n"
    "    case 0u: {\n"
    "        if ((uint)(select((int)((v5 / (in[(t * 4u + 2u)] | 1u))), (int)((~v0)), ((uint)((int)((v4 ^ t)) >> (int)((v0 ^ t) & 31u)) & 2u) != 0u)) < min((3346948594u + (v1 ^ t)), (uint)((int)(v2) >> (int)(in[(t * 4u + 3u)] & 31u)))) {\n"
    "            v3 = (((uint)(-(int)(85u & 0x7fffffffu)) % (extract_bits(insert_bits(in[(t * 4u + 1u)], 167571508u, (uint)(in[(t * 4u + 0u)] & 15u), (uint)(v4 & 15u)), (uint)((uint)(min((int)(in[(t * 4u + 3u)]), (int)(in[(t * 4u + 3u)]))) & 15u), (uint)((uint)(pc[(1946791036u) & 7u]) & 15u)) | 1u)));\n"
    "            v1 += (~(uint)((ushort)(hadd((v4 ^ t), in[(t * 4u + 0u)])) / (ushort)(((32u % (2147483647u | 1u))) | 1u)));\n"
    "            v0 = (uint)((uchar)(((uint)(pc[(in[(t * 4u + 0u)]) & 7u]) | (in[(t * 4u + 0u)] / (2u | 1u)))) + (uchar)(vf((ushort3((ushort)(32751), (ushort)(55162), (ushort)(11993))))));\n"
    "        } else {\n"
    "            v0 = in[(t * 4u + 0u)];\n"
    "        }\n"
    "        v2 -= vf((uchar4((uchar)(mulhi((v0 ^ t), 2147483648u)), (uchar)((uint)((int)(in[(t * 4u + 2u)]) / (int)((in[(t * 4u + 1u)] | 1u) & 0x7fffffffu))), (uchar)((uint)((int)(in[(t * 4u + 2u)]) / (int)((v2 | 1u) & 0x7fffffffu))), (uchar)(mulhi(65535u, v1)))));\n"
    "        break; }\n"
    "    default: {\n"
    "        if (vf(((min(char4((char)(rhadd(65536u, in[(t * 4u + 0u)])), (char)(((uint)((int)((char)(2u))) * 1484157511u)), (char)(v3), (char)((uint)((bool)(in[(t * 4u + 1u)] & v1)))), char4((char)(79), (char)(-16), (char)(-39), (char)(72))) / (((char4((char)(rotate(v0, (v1 ^ t))), (char)(v1), (char)((21u > (v5 ^ t) ? in[(t * 4u + 3u)] : v4)), (char)((uint)(select((int)(in[(t * 4u + 3u)]), (int)(in[(t * 4u + 0u)]), (in[(t * 4u + 3u)] & 2u) != 0u)))) & char4((char)(-15), (char)(-78), (char)(-101), (char)(-125)))) & char4((char)(127), (char)(127), (char)(127), (char)(127)) | char4((char)(1), (char)(1), (char)(1), (char)(1)))))) < rotate(((v2 ^ t) << (2148924106u & 31u)), subsat(97u, (v5 ^ t)))) {\n"
    "            atomic_fetch_add_explicit(&ta, (((uint)((ushort)((uint)(-(int)(32u & 0x7fffffffu)))) * (uint)((ushort)((~107u))))) & 255u, memory_order_relaxed);\n"
    "            pc[(rotate((v5 >> (in[(t * 4u + 3u)] & 31u)), median3(v3, 31u, (v1 ^ t)))) & 7u] = (uchar)(140u);\n"
    "            v5 = extract_bits(rotate((uint)(select((int)(23u), (int)(182u), (73u & 2u) != 0u)), (v4 + v3)), (uint)(mulhi((uint)((ushort)(v3)), (v0 ^ t)) & 15u), (uint)(v2 & 15u));\n"
    "        }\n"
    "        break; }\n"
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
    0xfc052a1eu, 0x2d0c268fu, 0x3f4e4802u, 0xcaf77c5cu, 0x056f57bbu, 0x046144f3u, 0x6174ab3eu, 0x09d2a4d8u,
    0x3e602f7du, 0xf1eadcf3u, 0x655488d2u, 0xf2ed476au, 0x0e6faecdu, 0x4551e234u, 0x8cbf8282u, 0xc0dfc339u,
    0x0de629c0u, 0x1ec14c38u, 0x923887f3u, 0x795f12fau, 0x27d9153au, 0x398a2bcau, 0x5dd87db4u, 0x61e0d951u,
    0x6658478eu, 0x081e3028u, 0xd0dd1471u, 0xcb4592f7u, 0x1d14453bu, 0x09cc6ecdu, 0xbae37d78u, 0x917cc893u,
    0x6f7cdf59u, 0x72d0e13du, 0xc8e10eaau, 0x83c8b317u, 0x74749d95u, 0x364a3cbau, 0x5e268558u, 0xc62dea32u,
    0x57061a5du, 0x7e8be3fcu, 0x533cfc70u, 0x65e5eaebu, 0x4006e93au, 0xb72b9b6bu, 0x0f1aabc3u, 0x2088c615u,
    0xc9658140u, 0x23a97bccu, 0x7a93df5bu, 0x9e1fb44fu, 0x3ee084d8u, 0xe8c02dcfu, 0x51108e89u, 0xdae0c534u,
    0x4be469c0u, 0x77a39269u, 0xf204fedfu, 0x3153869eu, 0x3d794f77u, 0x8875b394u, 0x3790bdccu, 0x43a49be1u,
    0xf7c264fau, 0xcef5bb2cu, 0x9eb02d75u, 0x198162dcu, 0x41c47e94u, 0x678349feu, 0x0b231b2fu, 0x6831d082u,
    0xc97e47c1u, 0x565ff0e7u, 0xc0c63f60u, 0xc2a9e720u, 0x02284416u, 0x9f0f85a5u, 0xde747196u, 0xcd021413u,
    0xe51fb2dfu, 0x53dceab1u, 0x8cc9c91du, 0xec5860deu, 0x7d75ea6du, 0x0aae22b2u, 0xe3077834u, 0x72c2df1fu,
    0x595241a1u, 0x43efe8e2u, 0x63dc3e8cu, 0x4bad7b24u, 0xa1b23d8au, 0x33336fcdu, 0x671fe9cau, 0x3966b058u,
    0xbda5d82fu, 0xa0d47f89u, 0x16f8cf04u, 0x4bf60fedu, 0x8f8b3176u, 0x2cf4adfbu, 0x4800485cu, 0xb1844165u,
    0x0dd3888cu, 0x6765379eu, 0x1b26d030u, 0xcd0fed2bu, 0x23ff5c3bu, 0x3cf8e772u, 0xe63cc9dcu, 0xe717c853u,
    0x10687919u, 0x42804901u, 0x9a585ecbu, 0xadc51e42u, 0x045dced7u, 0x61c110ccu, 0x6d847703u, 0x39ca792du,
    0x6e1b803eu, 0x608cf392u, 0x51d41d7eu, 0x5ba450edu, 0x793635f2u, 0x73bac110u, 0xbaef609eu, 0xe8c10756u,
    0xf98bbc52u, 0xca17ce7eu, 0xc2ee479fu, 0x9bd7f0a8u, 0xd8bcb447u, 0x76a6bde0u, 0x6f5dc8eeu, 0xb9d73535u,
    0x804051dfu, 0x7d170b5eu, 0x8ac868b5u, 0x4b02b661u, 0xb6541d97u, 0x11c94852u, 0x786a7bd7u, 0xa8cd45b2u,
    0xdd9507e2u, 0x059f31e9u, 0x3c25586fu, 0x9ea98f82u, 0xdf1bc144u, 0xcf44306bu, 0x11d1518fu, 0x7fce0ff1u,
    0x417c46d9u, 0xcc938a9eu, 0xe08b335cu, 0xd69d11d0u, 0x312521fau, 0xedc362dcu, 0x7649d095u, 0x7ccac86du,
    0x8ce80f19u, 0x930f4c7au, 0x2f585592u, 0xe341c519u, 0xc44fa64cu, 0x37b98717u, 0x16cf4477u, 0xc01daf05u,
    0xf3e2fec4u, 0x79f0db90u, 0x15bc38abu, 0xfb70ac4cu, 0x5ff0e0e0u, 0xdd082e7fu, 0xd1f59328u, 0xabb61644u,
    0xfe4bd699u, 0xa1628356u, 0x8767b788u, 0x9385e248u, 0x60747c50u, 0xc61c621eu, 0x921465e7u, 0x36ed6744u,
    0x72204451u, 0x7cbe3635u, 0x13af5717u, 0x0dfa5a74u, 0x7261b824u, 0x22d5d121u, 0xdb0c8c00u, 0x9e5f3cdcu,
    0xafd57604u, 0x8f714421u, 0x6ef68d53u, 0xd9bde242u, 0xeac61929u, 0x4d96573fu, 0xb79cd9c0u, 0xd9fdbfddu,
    0xcee160e4u, 0xb27197e7u, 0xf1cfc3ffu, 0x205f832fu, 0x1a8d11b7u, 0x45a05b40u, 0x02df737au, 0x20be587eu,
    0x6f051240u, 0x00b2d6dcu, 0xa8bf2d95u, 0x04686761u, 0xa1d939e0u, 0xf41f50a4u, 0xf1720d0au, 0x5c918898u,
    0x2c2213d3u, 0x7ff59afbu, 0x38052964u, 0xb7fcd681u, 0xa6be7fffu, 0x78e55c83u, 0x6de7df2au, 0xa04dbfe0u,
    0xcbcba983u, 0x32eac574u, 0xdb95698du, 0x31b24ef7u, 0xf3b9f0f8u, 0x0c5a1742u, 0xfc4d5e58u, 0x787ddd43u,
    0x92c1df22u, 0x85c82475u, 0x1a0afe6du, 0x970e26a4u, 0x9b1769b7u, 0xcb22fdb4u, 0x2d5b5eddu, 0x5b4b7ab7u,
    0x963da898u, 0x63937a84u, 0x3a2f7e2eu, 0xf673d9e0u, 0x80a2faa1u, 0x0e97b428u, 0x6765248fu, 0x6158c810u,
    0xb1145b27u, 0x0f72547cu, 0x61843f43u, 0x66a75093u, 0x3350b230u, 0x9e5b97c7u, 0x7b828245u, 0x0c27beeau
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n32-kepler-divisor-one";
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
    return PASS(bug, "%s: the remainder by a divisor of 1 is right in a big kernel too", name);
}}
