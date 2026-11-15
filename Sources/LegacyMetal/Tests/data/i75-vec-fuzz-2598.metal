#include <metal_stdlib>
using namespace metal;
static uint vf(uchar2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(uchar3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(uchar4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(char3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(ushort2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(ushort3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(ushort4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }
static uint vf(short3 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u); }
static uint vf(short4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }
kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],
              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {
    threadgroup uint tg[64];
    threadgroup uchar tc[64];
    threadgroup atomic_uint ta;
    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint p[8];
    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;
    uchar pc[8];
    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);
    uint v0 = in[(t * 4u + 0u)] * 1u + t;
    uint v1 = in[(t * 4u + 1u)] * 3u + t;
    uint v2 = in[(t * 4u + 2u)] * 5u + t;
    uint v3 = in[(t * 4u + 3u)] * 7u + t;
    uint v4 = in[(t * 4u + 0u)] * 9u + t;
    uint v5 = in[(t * 4u + 1u)] * 11u + t;
    atomic_fetch_add_explicit(&ta, (((uint)((int)((char)(v0))) * 1u)) & 255u, memory_order_relaxed);
    atomic_fetch_add_explicit(&ta, ((uint)((int)((char)((uint)((ushort)(65535u))) >> ((uint)((uchar)(in[(t * 4u + 0u)]) + (uchar)(v0)) & 7u)))) & 255u, memory_order_relaxed);
    atomic_fetch_add_explicit(&ta, ((uint)(max((int)(min(v3, (v1 ^ t))), (int)(((uint)((int)((short)(1717385302u))) * (v3 ^ t)))))) & 255u, memory_order_relaxed);
    if ((uint)((char)((uint)((int)((v0 ^ t)) % (int)(((v1 ^ t) | 1u) & 0x7fffffffu)))) > v2) {
        { uint n1 = 0u; while (n1 < 8u) { n1++;
            v2 = (uint)((bool)((uint)(any(uchar2((uchar)((uint)(min((int)(v4), (int)(1u)))), (uchar)(((v2 ^ t) >> (in[(t * 4u + 3u)] & 31u)))) < max(uchar2((uchar)(251), (uchar)(25)), uchar2((uchar)((((v4 ^ t) & 1u) != 0u ? v5 : in[(t * 4u + 3u)])), (uchar)((v4 ^ t)))))) & (uint)((int)(((v4 ^ t) / (v3 | 1u))) / (int)(((32u < 158u ? (v1 ^ t) : in[(t * 4u + 1u)]) | 1u) & 0x7fffffffu))));
            if (((min((((v1 ^ t) & 1u) != 0u ? in[(t * 4u + 3u)] : (v2 ^ t)), ((3390914628u % (1492682855u | 1u))))) & 3u) == 0u) break; } v2 += n1; }
        v1 -= vf((max(as_type<uchar4>(ushort2((ushort)(2014836626u), (ushort)(madhi(v3, v1, v0)))), (uchar4((uchar)(184), (uchar)(111), (uchar)(14), (uchar)(199)) & uchar4((uchar)((~v3)), (uchar)((uint)((short)(in[(t * 4u + 1u)]))), (uchar)((uint)((int)((v2 ^ t)) / (int)((v4 | 1u) & 0x7fffffffu))), (uchar)(((uint)((ushort)(31u)) * (uint)((ushort)((v1 ^ t))))))))));
    }
    switch (((v1 ^ t)) & 3u) {
    case 0u: {
        p[((uint)((int)((char)((uint)((int)((v4 ^ t)) % (int)(((v2 ^ t) | 1u) & 0x7fffffffu))) >> ((uint)(-(int)((v0 ^ t) & 0x7fffffffu)) & 7u)))) & 7u] = (uint)((uchar)((uint)((int)(4294967295u) >> (int)(2147483648u & 31u))) + (uchar)(((uint)((ushort)(v5)) * (uint)((ushort)((v2 ^ t))))));
        break; }
    case 1u: {
        v1 ^= (((uint)((ushort)((uint)((int)(v0) >> (int)(in[(t * 4u + 2u)] & 31u)))) * (uint)((ushort)(((v2 ^ t) == (v1 ^ t) ? (v4 ^ t) : (v3 ^ t))))) ^ extract_bits((uint)(select((int)(2795071905u), (int)(4226169550u), (3641403040u & 2u) != 0u)), (uint)((((v2 ^ t) % (2246178650u | 1u))) & 15u), (uint)((uint)(pc[(in[(t * 4u + 1u)]) & 7u]) & 15u)));
        break; }
    default: {
        v5 = (uint)((ushort)(((uint)((ushort)((uint)((int)(in[(t * 4u + 0u)]) / (int)((4294967295u | 1u) & 0x7fffffffu)))) * (uint)((ushort)(1649636233u)))) / (ushort)(vf((short3((short)(-4175), (short)(-4201), (short)(32214)))) | 1u));
        break; }
    }
    { tg[l] = (uint)((int)((394522020u + v1)) % (int)((((int)(1u) >= (int)(654405518u) ? in[(t * 4u + 0u)] : 2u) | 1u) & 0x7fffffffu)); threadgroup_barrier(mem_flags::mem_threadgroup); v1 += tg[((~1u)) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }
    atomic_fetch_add_explicit(&ta, ((uint)((uchar)((uint)((ushort)((v2 ^ t)) | (ushort)(v2))) >> ((uint)(pc[(in[(t * 4u + 2u)]) & 7u]) & 7u))) & 255u, memory_order_relaxed);
    pc[(vf(((short4((short)(((in[(t * 4u + 2u)] % ((v4 ^ t) | 1u)))), (short)((uint)((bool)(1056708459u & v2))), (short)(hadd((v4 ^ t), 3092649309u)), (short)(((v5 & 1u) != 0u ? (v3 ^ t) : (v3 ^ t)))) & max(short4((short)(insert_bits(4294967295u, (v1 ^ t), (uint)(2147483648u & 15u), (uint)(v1 & 15u))), (short)((v1 ^ t)), (short)(insert_bits((v0 ^ t), v4, (uint)((v4 ^ t) & 15u), (uint)(v2 & 15u))), (short)(v5)), short4((short)(15175), (short)(-29175), (short)(32004), (short)(19288))))))) & 7u] = (uchar)(vf((uchar2((uchar)(162), (uchar)(79)))));
    atomic_fetch_add_explicit(&ta, ((uint)((int)(extract_bits(v3, (uint)(in[(t * 4u + 1u)] & 15u), (uint)(v5 & 15u))) / (int)(((uint)((int)(v0) >> (int)(v2 & 31u)) | 1u) & 0x7fffffffu))) & 255u, memory_order_relaxed);
    v5 -= min((uint)(max((int)(extract_bits(v0, (uint)((v4 ^ t) & 15u), (uint)(in[(t * 4u + 0u)] & 15u))), (int)((uint)((uchar)(233u) - (uchar)(in[(t * 4u + 2u)]))))), vf((min((char3((char)((v5 ^ t)), (char)(min((v1 ^ t), in[(t * 4u + 3u)])), (char)(v2))).zxy, (char3((char)(107), (char)(42), (char)(-63)) >> ((char3((char)((v2 == in[(t * 4u + 0u)] ? v5 : in[(t * 4u + 1u)])), (char)((((v0 ^ t) % ((v1 ^ t) | 1u)))), (char)((~v0)))) & char3((char)(7), (char)(7), (char)(7))))))));
    for (uint i0 = 0; i0 < 5u; i0++) {
        v1 += i0 * 8u;
        switch (((uint)(min((int)((uint)((bool)(in[(t * 4u + 3u)] & 1150347496u))), (int)((151u < in[(t * 4u + 0u)] ? 1627314255u : (v2 ^ t)))))) & 3u) {
        case 0u: {
            v3 = vf((as_type<short2>((uchar4((uchar)((uint)((short)(in[(t * 4u + 2u)]))), (uchar)((uint)((int)(in[(t * 4u + 2u)]) >> (int)(v1 & 31u))), (uchar)((uint)((ushort)(v5) >> ((v4 ^ t) & 7u))), (uchar)(mulhi(0u, (v4 ^ t)))) << ((uchar4((uchar)((uint)((char)(in[(t * 4u + 3u)]))), (uchar)((uint)(!((v4 ^ t) > v2))), (uchar)(((106u % (in[(t * 4u + 1u)] | 1u)))), (uchar)((uint)(!(v5 > 48971462u))))) & uchar4((uchar)(7), (uchar)(7), (uchar)(7), (uchar)(7)))))));
            break; }
        default: {
            v5 ^= p[((uint)((uchar)((uint)((bool)(in[(t * 4u + 0u)] & v3))))) & 7u];
            break; }
        }
        atomic_fetch_add_explicit(&ta, ((uint)((ushort)((((v3 ^ t) % (3779835113u | 1u)))) - (ushort)((uint)(select((int)(v3), (int)(137u), (in[(t * 4u + 3u)] & 2u) != 0u))))) & 255u, memory_order_relaxed);
    }
    if ((~(uint)(pc[(v1) & 7u])) == (uint)((uchar)(1355623094u) / (uchar)(v0 | 1u))) {
        v4 = ((uint)((ushort)((uint)((int)((ushort)(max(3297088821u, 2u)) >> ((uint)(min((int)((v0 ^ t)), (int)((v3 ^ t)))) & 15u))))) * (uint)((ushort)(max(((int)((v4 ^ t)) > (int)(v2) ? 4294967295u : 149u), (uint)((int)(in[(t * 4u + 3u)]) / (int)((561072388u | 1u) & 0x7fffffffu))))));
    } else {
        v1 -= vf((as_type<uchar4>((short2((short)(((v2 ^ t) & (v2 ^ t))), (short)((uint)((ushort)((v3 ^ t)))))).yx)));
    }
    { tc[l] = (uchar)((uint)(any((short2((short)(22585), (short)(17073)) | short2((short)(ctz((v5 ^ t))), (short)(((v0 ^ t) > in[(t * 4u + 2u)] ? v2 : v4)))) < max(short2((short)(10693), (short)(-81)), short2((short)((uint)((int)((v1 ^ t)) / (int)((v3 | 1u) & 0x7fffffffu))), (short)(popcount(in[(t * 4u + 1u)]))))))); threadgroup_barrier(mem_flags::mem_threadgroup); v4 += (uint)(tc[((uint)(any(ushort3((ushort)(31964), (ushort)(49289), (ushort)(12123)) <= min(ushort3((ushort)(insert_bits(203u, (v0 ^ t), (uint)(v2 & 15u), (uint)((v2 ^ t) & 15u))), (ushort)((uint)((int)(in[(t * 4u + 2u)]) / (int)((139u | 1u) & 0x7fffffffu))), (ushort)((v0 >> (v4 & 31u)))), ushort3((ushort)(24758), (ushort)(57386), (ushort)(55354)))))) & 63u]) * 106u; threadgroup_barrier(mem_flags::mem_threadgroup); }
    for (uint i0 = 0; i0 < 4u; i0++) {
        v5 += i0 * 5u;
        v4 += vf(((min(short3((short)(((uint)((ushort)((v1 ^ t))) * (uint)((ushort)(in[(t * 4u + 1u)])))), (short)(min3(v0, in[(t * 4u + 0u)], 0u)), (short)((v1 / ((v4 ^ t) | 1u)))), short3((short)((uint)((bool)(v3 & 318622505u))), (short)((uint)(max((int)(in[(t * 4u + 0u)]), (int)((v2 ^ t))))), (short)((uint)(!(v3 > in[(t * 4u + 3u)])))))).zxy));
        atomic_fetch_add_explicit(&ta, ((uint)(select((int)((uint)(!(v3 > 185u))), (int)((v3 & 651115165u)), (min(in[(t * 4u + 2u)], in[(t * 4u + 2u)]) & 2u) != 0u))) & 255u, memory_order_relaxed);
    }
    switch ((vf((((short4((short)((uint)(min((int)(in[(t * 4u + 2u)]), (int)(v1)))), (short)(v4), (short)((uint)(-(int)(2147483647u & 0x7fffffffu))), (short)((uint)(select((int)((v3 ^ t)), (int)(1087899607u), (in[(t * 4u + 2u)] & 2u) != 0u)))) & short4((short)(-31761), (short)(-16859), (short)(-25224), (short)(32198))) % short4((short)(6729), (short)(30713), (short)(32384), (short)(8724)))))) & 3u) {
    case 0u: {
        { uint n1 = 0u; while (n1 < 8u) { n1++;
            v0 = (rotate((uint)(min((int)((v2 ^ t)), (int)(in[(t * 4u + 0u)]))), (uint)(select((int)(v5), (int)((v2 ^ t)), (v5 & 2u) != 0u))) != ((uint)((ushort)((v4 ^ t)) ^ (ushort)(170u)) / ((uint)(!(2u > v3)) | 1u)) ? clz(((int)((v3 ^ t)) > (int)(in[(t * 4u + 2u)]) ? (v5 ^ t) : v4)) : median3((((v4 ^ t) % (170u | 1u))), extract_bits((v1 ^ t), (uint)(212u & 15u), (uint)(31u & 15u)), ((v4 ^ t) == v4 ? in[(t * 4u + 3u)] : (v5 ^ t))));
            if (((((uint)(!(in[(t * 4u + 0u)] > v0)) / (((int)(76u) > (int)(in[(t * 4u + 0u)]) ? v4 : v3) | 1u))) & 3u) == 0u) break; } v0 += n1; }
        { uint4 w = uint4(rhadd(insert_bits(in[(t * 4u + 2u)], in[(t * 4u + 0u)], (uint)(31u & 15u), (uint)(v3 & 15u)), (uint)((ushort)((v2 ^ t)) + (ushort)(in[(t * 4u + 3u)]))), v2, (uint)((int)((uchar)((uint)(min((int)(v3), (int)((v5 ^ t))))) >> ((uint)((ushort)((v2 ^ t)) >> (v2 & 7u)) & 7u))), v1); w[((((uint)(!(in[(t * 4u + 3u)] > v1)) & 1u) != 0u ? ((uint)((int)((char)((v4 ^ t)))) * 784259788u) : ((in[(t * 4u + 1u)] & 1u) != 0u ? 19u : in[(t * 4u + 1u)]))) & 3u] = (uint)((int)(((uint)((int)((char)(in[(t * 4u + 0u)]))) + 65536u)) / (int)(((uint)(-(int)(202u & 0x7fffffffu)) | 1u) & 0x7fffffffu)); v1 += w[((uint)(all((short4((short)(-4320), (short)(-16749), (short)(23962), (short)(-23137)) / ((short4((short)(22028), (short)(31726), (short)(3729), (short)(26229))) & short4((short)(32767), (short)(32767), (short)(32767), (short)(32767)) | short4((short)(1), (short)(1), (short)(1), (short)(1)))) == max(short4((short)(-24154), (short)(32202), (short)(-25645), (short)(-12788)), short4((short)(((uint)((int)((short)((v4 ^ t)))) ^ in[(t * 4u + 3u)])), (short)((uint)(select((int)((v5 ^ t)), (int)((v4 ^ t)), (255u & 2u) != 0u))), (short)(((v4 ^ t) / (in[(t * 4u + 2u)] | 1u))), (short)((uint)(pc[(3104779421u) & 7u]))))))) & 3u] ^ (w.y << 1u) ^ w.w; }
        break; }
    case 1u: {
        if ((uint)(max((int)((uint)(pc[(v5) & 7u])), (int)((uint)((bool)(v0 & in[(t * 4u + 2u)]))))) > ((uint)((ushort)(((v4 ^ t) >= in[(t * 4u + 3u)] ? in[(t * 4u + 0u)] : in[(t * 4u + 0u)]))) * (uint)((ushort)(rotate(in[(t * 4u + 0u)], v4))))) {
            v4 = min((insert_bits(in[(t * 4u + 2u)], (v5 ^ t), (uint)(v2 & 15u), (uint)(in[(t * 4u + 1u)] & 15u)) >= (uint)(-(int)(in[(t * 4u + 3u)] & 0x7fffffffu)) ? subsat(in[(t * 4u + 3u)], in[(t * 4u + 0u)]) : (uint)(pc[(2117927651u) & 7u])), v0);
        } else {
            p[(vf((as_type<ushort2>((char4((char)((uint)(-(int)((v2 ^ t) & 0x7fffffffu))), (char)((145u >> (in[(t * 4u + 0u)] & 31u))), (char)(2931918613u), (char)(((v4 % ((v0 ^ t) | 1u))))) & char4((char)(108), (char)(56), (char)(10), (char)(21))))))) & 7u] = vf((max(ushort4((ushort)((uint)((ushort)((v0 ^ t)) >> (in[(t * 4u + 0u)] & 7u))), (ushort)(3883656152u), (ushort)((uint)((ushort)((v5 ^ t)))), (ushort)((v4 >> (v1 & 31u)))), (ushort4((ushort)(58044), (ushort)(56543), (ushort)(44726), (ushort)(54933)) / ((ushort4((ushort)(27044), (ushort)(54258), (ushort)(13400), (ushort)(41900))) | ushort4((ushort)(1), (ushort)(1), (ushort)(1), (ushort)(1)))))));
        }
        for (uint i1 = 0; i1 < 2u; i1++) {
            v2 += i1 * 2u;
            v2 = (uint)(!(((int)((uint)((char)(in[(t * 4u + 3u)]))) <= (int)(((uint)((int)((char)((v1 ^ t)))) + in[(t * 4u + 3u)])) ? (~3151316883u) : ctz((v3 ^ t))) > ((int)((uint)((int)(in[(t * 4u + 0u)]) >> (int)(v0 & 31u))) > (int)((uint)((bool)(v4 & in[(t * 4u + 0u)]))) ? (uint)((uchar)(in[(t * 4u + 3u)]) >> (in[(t * 4u + 0u)] & 7u)) : popcount(v3))));
            v3 = reverse_bits(v5);
        }
        break; }
    case 2u: {
        { uint4 w = uint4((uint)((short)(mulhi((v0 ^ t), in[(t * 4u + 1u)]))), v3, (uint)((bool)(((v2 ^ t) >> (1u & 31u)) & mulhi(2147483647u, (v4 ^ t)))), v5); w[(insert_bits(rotate(v4, v2), (v5 / (in[(t * 4u + 1u)] | 1u)), (uint)((((v0 ^ t) & 1u) != 0u ? v1 : in[(t * 4u + 0u)]) & 15u), (uint)(median3(in[(t * 4u + 0u)], (v2 ^ t), v4) & 15u))) & 3u] = (uint)(any((ushort2((ushort)((uint)(select((int)(v5), (int)(2147483647u), (2588864394u & 2u) != 0u))), (ushort)((v3 < (v3 ^ t) ? in[(t * 4u + 0u)] : (v0 ^ t)))) % ((ushort2((ushort)(max(in[(t * 4u + 3u)], v0)), (ushort)((uint)(max((int)(v2), (int)(146u)))))) | ushort2((ushort)(1), (ushort)(1)))) > (ushort2((ushort)(30247), (ushort)(21038)) << ushort2((ushort)(15), (ushort)(4))))); v1 += w[(vf((char3((char)(65), (char)(-22), (char)(63))))) & 3u] ^ (w.y << 1u) ^ w.w; }
        break; }
    default: {
        v0 ^= ((((int)(((uint)((int)((short)((v1 ^ t)))) ^ (v4 ^ t))) < (int)((uint)((uchar)((v1 ^ t)) * (uchar)(in[(t * 4u + 3u)]))) ? (v3 / (125u | 1u)) : (uint)(min((int)((v4 ^ t)), (int)(v0)))) & 1u) != 0u ? rotate(max3(186u, (v1 ^ t), 2738534581u), (v0 - 20u)) : (uint)(any((uchar2((uchar)(231), (uchar)(169)) | uchar2((uchar)((uint)((ushort)(in[(t * 4u + 3u)]) + (ushort)(v0))), (uchar)(((int)((v4 ^ t)) >= (int)(v4) ? (v5 ^ t) : v3)))) < (uchar2((uchar)(81), (uchar)(240))).yx)));
        break; }
    }
    v5 -= (uint)((ushort)(vf(((max(char4((char)(-28), (char)(-123), (char)(21), (char)(89)), char4((char)(((0u & 1u) != 0u ? in[(t * 4u + 1u)] : (v4 ^ t))), (char)((uint)((uchar)(in[(t * 4u + 1u)]) >> (160u & 7u))), (char)(insert_bits((v3 ^ t), (v5 ^ t), (uint)(v4 & 15u), (uint)(v2 & 15u))), (char)((uint)(select((int)((v3 ^ t)), (int)((v0 ^ t)), (108u & 2u) != 0u))))) ^ as_type<char4>(((uint)((int)((char)(v1))) + in[(t * 4u + 0u)])))))) / (ushort)((uint)(pc[(((int)(v5) < (int)(v1) ? v4 : (v1 ^ t))) & 7u]) | 1u));
    { tg[l] = ((uint)((int)((char)(((2u % ((v5 ^ t) | 1u)))))) - (in[(t * 4u + 2u)] <= v1 ? in[(t * 4u + 3u)] : v0)); threadgroup_barrier(mem_flags::mem_threadgroup); v1 += tg[(subsat((v2 ^ t), (uint)(min((int)((v2 ^ t)), (int)(in[(t * 4u + 3u)]))))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }
    { tc[l] = (uchar)(addsat(hadd((v3 ^ t), in[(t * 4u + 2u)]), ((v5 ^ t) <= (v4 ^ t) ? (v0 ^ t) : in[(t * 4u + 1u)]))); threadgroup_barrier(mem_flags::mem_threadgroup); v4 += (uint)(tc[(mulhi(v2, (uint)(-(int)((v1 ^ t) & 0x7fffffffu)))) & 63u]) * 289u; threadgroup_barrier(mem_flags::mem_threadgroup); }
    v1 += ((int)((uint)((ushort)((uint)(min((int)((v5 ^ t)), (int)(v3)))) ^ (ushort)((uint)((int)(in[(t * 4u + 3u)]) / (int)((v3 | 1u) & 0x7fffffffu))))) <= (int)((uint)((bool)((v0 ^ t) & (uint)((int)((v3 ^ t)) % (int)((v1 | 1u) & 0x7fffffffu))))) ? (uint)(all((short2((short)(-28386), (short)(10024)) & short2((short)(1161), (short)(-17589))) <= as_type<short2>(char4((char)((uint)(select((int)((v4 ^ t)), (int)(v5), ((v1 ^ t) & 2u) != 0u))), (char)(((v2 & 1u) != 0u ? 2147483648u : v0)), (char)(((uint)((int)((short)(65535u))) - in[(t * 4u + 2u)])), (char)(((in[(t * 4u + 2u)] % (in[(t * 4u + 3u)] | 1u)))))))) : (uint)((int)((uint)((int)(141u) / (int)((v5 | 1u) & 0x7fffffffu))) / (int)(((uint)((uchar)(in[(t * 4u + 0u)]) - (uchar)((v0 ^ t))) | 1u) & 0x7fffffffu)));
    pc[((uint)((int)((in[(t * 4u + 3u)] >= (v2 ^ t) ? (v3 ^ t) : (v4 ^ t))) % (int)(((uint)((int)(v3) / (int)(((v1 ^ t) | 1u) & 0x7fffffffu)) | 1u) & 0x7fffffffu))) & 7u] = (uchar)((uint)((uchar)(addsat(in[(t * 4u + 0u)], v2)) >> ((v5 ^ t) & 7u)));
    { uint4 w = uint4(rotate((uint)((uchar)((v0 ^ t))), ((uint)((ushort)((v4 ^ t))) * (uint)((ushort)((v5 ^ t))))), v5, vf((uchar3((uchar)(14), (uchar)(55), (uchar)(90)))), v5); w[(((uint)((int)((char)((uint)((ushort)(v3) - (ushort)(13u))))) + 256u)) & 3u] = vf((select((ushort2((ushort)(50758), (ushort)(61802)) / ushort2((ushort)(23440), (ushort)(15475))), as_type<ushort2>(char4((char)((v0 == v3 ? v0 : 1158826972u)), (char)((uint)((int)(v3) % (int)((in[(t * 4u + 0u)] | 1u) & 0x7fffffffu))), (char)(min(1u, (v0 ^ t))), (char)((uint)(-(int)(160712602u & 0x7fffffffu))))), as_type<ushort2>(char4((char)(-5), (char)(23), (char)(-13), (char)(27))) > as_type<ushort2>((uint)((short)(1665051442u)))))); v4 += w[((uint)((int)((uint)(pc[((v2 ^ t)) & 7u])) % (int)((max3((v3 ^ t), 65535u, 2147483648u) | 1u) & 0x7fffffffu))) & 3u] ^ (w.y << 1u) ^ w.w; }
    if ((uint)(pc[((200u & (v0 ^ t))) & 7u]) < ((uint)((int)(201u) >> (int)(v3 & 31u)) / (min3((v5 ^ t), 79u, 2154619759u) | 1u))) {
        v4 = vf(((short2((short)((uint)((int)(in[(t * 4u + 1u)]) >> (int)(v4 & 31u))), (short)(rotate((v5 ^ t), (v5 ^ t))))).yx));
    } else {
        v2 ^= (uint)(-(int)(vf((((char3((char)((in[(t * 4u + 3u)] <= (v5 ^ t) ? in[(t * 4u + 0u)] : in[(t * 4u + 0u)])), (char)(max((v4 ^ t), (v3 ^ t))), (char)((uint)(pc[(217u) & 7u]))) >> ((char3((char)(-4), (char)(-126), (char)(-19))) & char3((char)(7), (char)(7), (char)(7)))) >> char3((char)(1), (char)(0), (char)(5))))) & 0x7fffffffu));
    }
    pc[(in[(t * 4u + 3u)]) & 7u] = (uchar)(((((in[(t * 4u + 3u)] & 1u) != 0u ? (v3 ^ t) : v5) % ((uint)(min((int)(in[(t * 4u + 1u)]), (int)(v0))) | 1u))));
    { uint n0 = 0u; while (n0 < 8u) { n0++;
        v5 += vf((((char2((char)(103), (char)(-94)) % ((char2((char)((uint)((int)((v2 ^ t)) / (int)((v2 | 1u) & 0x7fffffffu))), (char)(insert_bits(2726809985u, 123u, (uint)(v3 & 15u), (uint)((v5 ^ t) & 15u))))) & char2((char)(127), (char)(127)) | char2((char)(1), (char)(1)))) >> ((select(char2((char)((v2 << ((v3 ^ t) & 31u))), (char)(rhadd(in[(t * 4u + 3u)], 67u))), char2((char)((~v0)), (char)((uint)(-(int)(in[(t * 4u + 0u)] & 0x7fffffffu)))), char2((char)(-23), (char)(-57)) >= char2((char)(mulhi(in[(t * 4u + 2u)], v3)), (char)(((v5 ^ t) >> (20u & 31u)))))) & char2((char)(7), (char)(7))))));
        switch ((vf((((uchar3((uchar)(v4), (uchar)(((v1 ^ t) - (v4 ^ t))), (uchar)(1135014187u)) & uchar3((uchar)((v5 ^ t)), (uchar)(in[(t * 4u + 0u)]), (uchar)((uint)(!((v5 ^ t) > in[(t * 4u + 1u)])))))).zxy))) & 3u) {
        case 0u: {
            pc[(vf((select((uchar3((uchar)(179), (uchar)(45), (uchar)(47)) * uchar3((uchar)(insert_bits(v1, v4, (uint)(in[(t * 4u + 3u)] & 15u), (uint)((v5 ^ t) & 15u))), (uchar)(insert_bits((v1 ^ t), 2147483647u, (uint)(v3 & 15u), (uint)(v1 & 15u))), (uchar)((uint)((bool)(in[(t * 4u + 0u)] & v1))))), (uchar3((uchar)(219), (uchar)(82), (uchar)(120)) / ((uchar3((uchar)((in[(t * 4u + 0u)] != 743257588u ? 202u : in[(t * 4u + 3u)])), (uchar)(mulhi(in[(t * 4u + 0u)], in[(t * 4u + 0u)])), (uchar)(insert_bits(v0, 1496273320u, (uint)(4287601730u & 15u), (uint)(in[(t * 4u + 2u)] & 15u))))) | uchar3((uchar)(1), (uchar)(1), (uchar)(1)))), uchar3((uchar)(21), (uchar)(249), (uchar)(155)) <= (uchar3((uchar)((uint)(min((int)(v3), (int)((v2 ^ t))))), (uchar)((uint)((int)(v4) >> (int)(221u & 31u))), (uchar)(249u)) % ((uchar3((uchar)(150), (uchar)(4), (uchar)(126))) | uchar3((uchar)(1), (uchar)(1), (uchar)(1)))))))) & 7u] = (uchar)(vf((((short4((short)(-25044), (short)(-7186), (short)(-32440), (short)(-8439)) ^ short4((short)((in[(t * 4u + 0u)] >= v0 ? in[(t * 4u + 2u)] : 1840298914u)), (short)(in[(t * 4u + 3u)]), (short)((uint)((bool)((v1 ^ t) & v3))), (short)((uint)(select((int)((v3 ^ t)), (int)(in[(t * 4u + 1u)]), ((v1 ^ t) & 2u) != 0u))))) & (short4((short)(-12571), (short)(-29241), (short)(-3087), (short)(-20068)) & short4((short)((uint)(pc[(in[(t * 4u + 1u)]) & 7u])), (short)(((2278033722u % (1u | 1u)))), (short)((uint)((ushort)(in[(t * 4u + 2u)]) >> (v2 & 7u))), (short)((((v2 ^ t) % (18u | 1u))))))))));
            v5 ^= vf((((short4((short)(insert_bits(v4, 2147483647u, (uint)((v2 ^ t) & 15u), (uint)((v2 ^ t) & 15u))), (short)((uint)(min((int)(1644472426u), (int)((v3 ^ t))))), (short)((uint)(-(int)(in[(t * 4u + 1u)] & 0x7fffffffu))), (short)((in[(t * 4u + 0u)] >> (in[(t * 4u + 1u)] & 31u)))) & short4((short)(madsat(v3, (v1 ^ t), in[(t * 4u + 3u)])), (short)((uint)((uchar)((v4 ^ t)) + (uchar)((v3 ^ t)))), (short)(in[(t * 4u + 0u)]), (short)((v4 + v4)))) | select(short4((short)((uint)(-(int)(in[(t * 4u + 0u)] & 0x7fffffffu))), (short)(insert_bits(in[(t * 4u + 3u)], (v4 ^ t), (uint)(130u & 15u), (uint)((v1 ^ t) & 15u))), (short)(((uint)((ushort)(in[(t * 4u + 1u)])) * (uint)((ushort)(in[(t * 4u + 3u)])))), (short)(((int)(v4) < (int)(4294967295u) ? (v0 ^ t) : (v2 ^ t)))), short4((short)((uint)(pc[((v1 ^ t)) & 7u])), (short)(mulhi(255u, 3832740216u)), (short)(((v1 ^ t) / (v2 | 1u))), (short)(clz(v0))), short4((short)(reverse_bits(v3)), (short)(rotate(v4, in[(t * 4u + 1u)])), (short)(((in[(t * 4u + 3u)] % (in[(t * 4u + 2u)] | 1u)))), (short)(rhadd((v2 ^ t), v3))) > short4((short)((((v3 ^ t) & 1u) != 0u ? in[(t * 4u + 1u)] : 2818734960u)), (short)((uint)((ushort)(1731286870u))), (short)((uint)(select((int)(in[(t * 4u + 3u)]), (int)(in[(t * 4u + 3u)]), (v4 & 2u) != 0u))), (short)((uint)(max((int)((v2 ^ t)), (int)(1659111837u)))))))));
            break; }
        default: {
            { uint4 w = uint4(vf((select((char3((char)(v1), (char)((1u / ((v2 ^ t) | 1u))), (char)((v3 > 54u ? in[(t * 4u + 2u)] : v1))) >> ((char3((char)(71), (char)(120), (char)(-76))) & char3((char)(7), (char)(7), (char)(7)))), (char3((char)((uint)((bool)(v3 & 147u))), (char)((in[(t * 4u + 3u)] > in[(t * 4u + 3u)] ? (v5 ^ t) : in[(t * 4u + 2u)])), (char)((uint)((ushort)(4287767486u) + (ushort)(v4)))) | char3((char)(mulhi(in[(t * 4u + 3u)], in[(t * 4u + 2u)])), (char)((uint)(select((int)(75u), (int)(3147676669u), ((v4 ^ t) & 2u) != 0u))), (char)(((v2 ^ t) > 4017882942u ? in[(t * 4u + 0u)] : in[(t * 4u + 1u)])))), (char3((char)(((v3 ^ t) << (in[(t * 4u + 0u)] & 31u))), (char)((uint)((int)(v4) >> (int)(4115817894u & 31u))), (char)(insert_bits(750670940u, v5, (uint)(v4 & 15u), (uint)(v3 & 15u)))) % char3((char)(21), (char)(38), (char)(101))) < char3((char)((uint)(min((int)(v0), (int)(in[(t * 4u + 1u)])))), (char)(((uint)((int)((char)(2331557274u))) + 81u)), (char)(popcount(in[(t * 4u + 0u)])))))), v5, ((((in[(t * 4u + 3u)] % (0u | 1u))) & 1u) != 0u ? madsat((v4 ^ t), (v3 ^ t), 146u) : (uint)(-(int)(31u & 0x7fffffffu))), v2); w[(vf(((short2((short)(-8467), (short)(2942)) & (short2((short)(((in[(t * 4u + 0u)] & 1u) != 0u ? (v1 ^ t) : in[(t * 4u + 2u)])), (short)(extract_bits(in[(t * 4u + 2u)], (uint)(in[(t * 4u + 0u)] & 15u), (uint)(v2 & 15u))))).yx)))) & 3u] = vf(((char3((char)(100), (char)(37), (char)(-125)) >> (((char3((char)(-12), (char)(-113), (char)(111)) >> char3((char)(2), (char)(7), (char)(7)))) & char3((char)(7), (char)(7), (char)(7)))))); v1 += w[((uint)((int)((char)(((int)(84u) < (int)(2147483647u) ? in[(t * 4u + 3u)] : v5)) / (char)(((uint)((uchar)(2u)) & 127u) | 1u)))) & 3u] ^ (w.y << 1u) ^ w.w; }
            break; }
        }
        if (((max(rotate((v3 ^ t), (v0 ^ t)), 779062005u)) & 3u) == 0u) break; } v3 += n0; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[t * 8u + 0u] = v0;
    out[t * 8u + 1u] = v1;
    out[t * 8u + 2u] = v2;
    out[t * 8u + 3u] = v3;
    out[t * 8u + 4u] = v4;
    out[t * 8u + 5u] = v5;
    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);
    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);
}
