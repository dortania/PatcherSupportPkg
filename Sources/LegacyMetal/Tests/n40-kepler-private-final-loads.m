// n40-kepler-private-final-loads (Kepler adapter, NVAIR_PRIVATE_FINAL_LOADS_FIX): loads of a private array at constant
// indexes after its last store. The fix for two loads of one element being taken for one value (n26) gave every
// constant-index load of such an array an index the back end can't fold, and with that on the 16 loads of the fuzzer's
// final hash of p[] and pc[], this kernel (mslfuzz2.py VEC=1 ASTYPE=1 seed 14028) came out wrong on 207 of 256 threads,
// values that never touch the arrays (v0, v2, v5) included; with the hash written as 0, or the n26 fix off, it is right.
// Loads in the returning block with no store to the array after them now keep their constant index: no store can come
// after them for the back end to take them past. The kernel on the fuzzer's inputs (seed 1, 256 threads in groups of 64,
// compiled without fast math, as the fuzzer does): each thread's 8 output words against the CPU reference (cpuref.py), as
// one FNV-1a hash per thread.
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
    "    p[(insert_bits(insert_bits((v3 ^ t), in[(t * 4u + 0u)], (uint)((v1 ^ t) & 15u), (uint)((v4 ^ t) & 15u)), (uint)((int)(31u) >> (int)(1u & 31u)), (uint)((uint)(select((int)(v5), (int)((v3 ^ t)), (in[(t * 4u + 1u)] & 2u) != 0u)) & 15u), (uint)(madhi(2408411999u, in[(t * 4u + 0u)], 120u) & 15u))) & 7u] = rotate(extract_bits(in[(t * 4u + 3u)], (uint)(v0 & 15u), (uint)(v3 & 15u)), in[(t * 4u + 3u)]);\n"
    "    v4 ^= (uint)((ushort)(in[(t * 4u + 0u)]) >> (vf(((uchar3((uchar)((uint)((bool)((v1 ^ t) & v2))), (uchar)(((v5 % ((v1 ^ t) | 1u)))), (uchar)((uint)((int)(v5) / (int)(((v4 ^ t) | 1u) & 0x7fffffffu)))) >> ((uchar3((uchar)(203), (uchar)(208), (uchar)(41))) & uchar3((uchar)(7), (uchar)(7), (uchar)(7)))))) & 7u));\n"
    "    pc[(hadd(insert_bits(in[(t * 4u + 0u)], in[(t * 4u + 3u)], (uint)(v5 & 15u), (uint)(in[(t * 4u + 0u)] & 15u)), (v1 == 1u ? (v5 ^ t) : in[(t * 4u + 2u)]))) & 7u] = (uchar)((uint)((int)((uint)((ushort)(1u) >> (v4 & 7u))) / (int)(((uint)((bool)(in[(t * 4u + 2u)] & v0)) | 1u) & 0x7fffffffu)));\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        v0 ^= ((char)((uint)((char)(((int)(1168483603u) >= (int)(65536u) ? 65535u : in[(t * 4u + 3u)])))) < (char)((((uint)((int)((char)(v1))) - in[(t * 4u + 1u)]) / ((in[(t * 4u + 2u)] / (in[(t * 4u + 1u)] | 1u)) | 1u))) ? (uint)((char)((in[(t * 4u + 1u)] <= v0 ? in[(t * 4u + 2u)] : in[(t * 4u + 0u)]))) : 1u);\n"
    "        if ((((ctz((v3 ^ t)) / (hadd(in[(t * 4u + 2u)], v0) | 1u))) & 3u) == 0u) break; } v4 += n0; }\n"
    "    for (uint i0 = 0; i0 < 2u; i0++) {\n"
    "        v5 += i0 * 8u;\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v1 = vf(((ushort4((ushort)((v5 ^ t)), (ushort)((uint)((int)(in[(t * 4u + 0u)]) / (int)((v2 | 1u) & 0x7fffffffu))), (ushort)(max(256u, in[(t * 4u + 3u)])), (ushort)((11u / (in[(t * 4u + 1u)] | 1u)))) % (((ushort4((ushort)(max(in[(t * 4u + 0u)], v1)), (ushort)((uint)(max((int)(148u), (int)(v1)))), (ushort)((uint)(pc[(v0) & 7u])), (ushort)(((uint)((ushort)(170u)) * (uint)((ushort)((v1 ^ t)))))) & ushort4((ushort)(3088), (ushort)(18629), (ushort)(16845), (ushort)(41090)))) | ushort4((ushort)(1), (ushort)(1), (ushort)(1), (ushort)(1))))));\n"
    "            v2 = addsat(((uint)((int)((short)((uint)(max((int)(in[(t * 4u + 3u)]), (int)(31u)))))) ^ (v3 ^ t)), vf((((char2((char)(-55), (char)(48)) & char2((char)((uint)(min((int)((v3 ^ t)), (int)(in[(t * 4u + 3u)])))), (char)(max((v1 ^ t), in[(t * 4u + 3u)])))) & char2((char)((uint)((int)((v4 ^ t)) / (int)((990588973u | 1u) & 0x7fffffffu))), (char)(rhadd(v2, 2835140211u)))))));\n"
    "            if ((((uint)((bool)(extract_bits(v4, (uint)(2710022647u & 15u), (uint)((v3 ^ t) & 15u)) & ((v3 ^ t) << ((v3 ^ t) & 31u))))) & 3u) == 0u) break; } v3 += n1; }\n"
    "    }\n"
    "    v4 = in[(t * 4u + 3u)];\n"
    "    v2 ^= p[((uint)(any((char2((char)(18), (char)(-29)) & char2((char)(-79), (char)(44))) != max(char2((char)(-125), (char)(18)), char2((char)((uint)((bool)((v0 ^ t) & in[(t * 4u + 2u)]))), (char)((in[(t * 4u + 2u)] >> ((v2 ^ t) & 31u)))))))) & 7u];\n"
    "    v0 = (uint)((uchar)((uint)((int)((short)((uint)((bool)((v2 ^ t) & 254u))) >> ((v0 >= 2378931076u ? 2u : 231u) & 15u)))) >> ((insert_bits(in[(t * 4u + 1u)], v4, (uint)(2u & 15u), (uint)(in[(t * 4u + 3u)] & 15u)) == v1 ? (in[(t * 4u + 0u)] + 2147483648u) : ((v5 ^ t) > v5 ? 197u : 3951817342u)) & 7u));\n"
    "    if (((uint)((ushort)(v5) >> (73u & 7u)) >> ((uint)(-(int)(207u & 0x7fffffffu)) & 31u)) == rotate((uint)(max((int)(v4), (int)(155u))), (in[(t * 4u + 2u)] >> (403464066u & 31u)))) {\n"
    "        switch (((uint)((bool)(((uint)((ushort)(v1)) * (uint)((ushort)((v1 ^ t)))) & ((v4 & 1u) != 0u ? in[(t * 4u + 3u)] : v2)))) & 3u) {\n"
    "        case 0u: {\n"
    "            atomic_fetch_add_explicit(&ta, ((uint)(pc[(rotate(3284057863u, in[(t * 4u + 2u)])) & 7u])) & 255u, memory_order_relaxed);\n"
    "            break; }\n"
    "        default: {\n"
    "            { uint4 w = uint4(vf(((as_type<char4>((uint)((int)(65536u) % (int)((246u | 1u) & 0x7fffffffu))) % (((char4((char)((uint)((short)(v2))), (char)(subsat(v0, 1793440642u)), (char)(reverse_bits((v2 ^ t))), (char)((in[(t * 4u + 0u)] << (in[(t * 4u + 3u)] & 31u)))) & char4((char)((3899478409u ^ v0)), (char)((uint)((ushort)(2147483647u) - (ushort)(23u))), (char)(((v2 ^ t) / (4294967295u | 1u))), (char)((uint)(pc[((v1 ^ t)) & 7u]))))) & char4((char)(127), (char)(127), (char)(127), (char)(127)) | char4((char)(1), (char)(1), (char)(1), (char)(1)))))), v1, mulhi((1522700719u + (v2 ^ t)), (((v1 ^ t) & 1u) != 0u ? 1u : in[(t * 4u + 3u)])), v0); w[((uint)((int)((char)(median3(0u, in[(t * 4u + 2u)], v1)) >> (((v0 ^ t) << (in[(t * 4u + 2u)] & 31u)) & 7u)))) & 3u] = (uint)(-(int)(min(2147483647u, in[(t * 4u + 0u)]) & 0x7fffffffu)); v3 += w[(rotate((((v1 ^ t) & 1u) != 0u ? (v1 ^ t) : 2706234198u), ((uint)((int)((char)(193115277u))) + v1))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "            break; }\n"
    "        }\n"
    "        v1 = (uint)(all(ushort3((ushort)(19532), (ushort)(22154), (ushort)(63602)) <= max(ushort3((ushort)((uint)((bool)(v0 & in[(t * 4u + 3u)]))), (ushort)((uint)((ushort)(178u) >> (v2 & 7u))), (ushort)(mulhi(v5, in[(t * 4u + 2u)]))), ushort3((ushort)(16450), (ushort)(33156), (ushort)(60439)))));\n"
    "    } else {\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v3 = (v5 ^ t);\n"
    "            v2 ^= p[(vf((as_type<ushort2>((uint)((int)((v5 ^ t)) % (int)((v5 | 1u) & 0x7fffffffu)))))) & 7u];\n"
    "            if (((vf((((uchar3((uchar)(69), (uchar)(55), (uchar)(235)) ^ uchar3((uchar)((uint)((uchar)(v1) - (uchar)((v4 ^ t)))), (uchar)((uint)(select((int)(46u), (int)(172u), (in[(t * 4u + 3u)] & 2u) != 0u))), (uchar)((uint)((uchar)((v0 ^ t)) >> ((v1 ^ t) & 7u))))) * uchar3((uchar)(30), (uchar)(38), (uchar)(215)))))) & 3u) == 0u) break; } v5 += n1; }\n"
    "    }\n"
    "    v5 = (uint)(pc[(((uint)((uchar)(in[(t * 4u + 3u)]) - (uchar)(v4)) / (((in[(t * 4u + 2u)] & 1u) != 0u ? in[(t * 4u + 1u)] : 2108683575u) | 1u))) & 7u]);\n"
    "    p[(in[(t * 4u + 1u)]) & 7u] = (uint)((int)((uint)((int)(v2) >> (int)(256u & 31u))) / (int)(((uint)((ushort)(89u) ^ (ushort)((v3 ^ t))) | 1u) & 0x7fffffffu));\n"
    "    v1 -= vf((((ushort3((ushort)((v2 / (111u | 1u))), (ushort)(v5), (ushort)(rotate(in[(t * 4u + 2u)], v3))) % ((ushort3((ushort)(42158), (ushort)(45999), (ushort)(27718))) | ushort3((ushort)(1), (ushort)(1), (ushort)(1)))) % (((ushort3((ushort)(((uint)((ushort)((v3 ^ t))) * (uint)((ushort)(in[(t * 4u + 2u)])))), (ushort)(((uint)((ushort)(v3)) * (uint)((ushort)(1275949558u)))), (ushort)((v1 ^ t))) % ushort3((ushort)(24848), (ushort)(25073), (ushort)(17353)))) | ushort3((ushort)(1), (ushort)(1), (ushort)(1))))));\n"
    "    switch ((ctz((uint)((int)((v1 ^ t)) % (int)(((v1 ^ t) | 1u) & 0x7fffffffu)))) & 3u) {\n"
    "    case 0u: {\n"
    "        pc[(((uint)(-(int)(v3 & 0x7fffffffu)) - (v3 ^ t))) & 7u] = (uchar)(((ushort)((v3 ^ t)) != (ushort)((uint)((int)(in[(t * 4u + 0u)]) % (int)((v2 | 1u) & 0x7fffffffu))) ? (uint)((int)((v1 ^ t)) % (int)((v3 | 1u) & 0x7fffffffu)) : insert_bits(in[(t * 4u + 2u)], in[(t * 4u + 0u)], (uint)(32u & 15u), (uint)(in[(t * 4u + 1u)] & 15u))));\n"
    "        }\n"
    "    default: {\n"
    "        v0 ^= p[(((uint)((int)((char)(((v3 ^ t) >> (in[(t * 4u + 0u)] & 31u))))) + (uint)((int)((v0 ^ t)) >> (int)(in[(t * 4u + 2u)] & 31u)))) & 7u];\n"
    "        break; }\n"
    "    }\n"
    "    v5 ^= p[((((uint)((int)((short)(in[(t * 4u + 1u)]))) * (v3 ^ t)) | ((uint)((int)((char)(1440573216u))) * v0))) & 7u];\n"
    "    v0 ^= p[(v3) & 7u];\n"
    "    v5 ^= p[((uint)((uchar)((uint)(-(int)(2809722253u & 0x7fffffffu))) / (uchar)(((uint)((ushort)(v3)) * (uint)((ushort)(584050763u))) | 1u))) & 7u];\n"
    "    v5 = vf((select(select(uchar2((uchar)(60), (uchar)(91)), uchar2((uchar)(236), (uchar)(165)), uchar2((uchar)(209), (uchar)(36)) > uchar2((uchar)((uint)((bool)(in[(t * 4u + 0u)] & v0))), (uchar)(max(4294967295u, v0)))), max(uchar2((uchar)(71), (uchar)(14)), uchar2((uchar)(99), (uchar)(56))), (uchar2((uchar)(max((v5 ^ t), in[(t * 4u + 1u)])), (uchar)(min(2147483648u, 2147483647u))) * uchar2((uchar)(244), (uchar)(227))) >= (uchar2((uchar)((uint)((int)(in[(t * 4u + 2u)]) >> (int)(v0 & 31u))), (uchar)(((uint)((int)((short)((v0 ^ t)))) + in[(t * 4u + 1u)]))) << uchar2((uchar)(6), (uchar)(3))))));\n"
    "    v1 = (uint)((int)((uchar)(vf((ushort2((ushort)(27697), (ushort)(20849))))) >> ((in[(t * 4u + 0u)] << ((uint)(select((int)((v4 ^ t)), (int)(126u), ((v3 ^ t) & 2u) != 0u)) & 31u)) & 7u)));\n"
    "    p[(((((v1 & 1u) != 0u ? v3 : (v1 ^ t)) % ((uint)((int)((v3 ^ t)) / (int)(((v1 ^ t) | 1u) & 0x7fffffffu)) | 1u)))) & 7u] = (((v5 % (v2 | 1u))) / (((v3 ^ t) / (in[(t * 4u + 2u)] | 1u)) | 1u));\n"
    "    pc[(vf(((as_type<char4>(ushort2((ushort)(30012), (ushort)(63986))) & (char4((char)(((v3 ^ t) / (in[(t * 4u + 0u)] | 1u))), (char)(in[(t * 4u + 3u)]), (char)(in[(t * 4u + 1u)]), (char)((((v4 ^ t) & 1u) != 0u ? (v4 ^ t) : 3934718978u))) & char4((char)(28), (char)(-125), (char)(20), (char)(100))))))) & 7u] = (uchar)((uint)((int)((uint)((int)((v4 ^ t)) >> (int)(392953322u & 31u))) / (int)(((uint)((int)(65536u) >> (int)(407786636u & 31u)) | 1u) & 0x7fffffffu)));\n"
    "    { uint4 w = uint4(in[(t * 4u + 1u)], v0, ((uint)((uchar)(31u) >> ((v3 ^ t) & 7u)) | 2392354930u), v1); w[(median3(((v3 % ((v3 ^ t) | 1u))), (uint)(pc[((v3 ^ t)) & 7u]), (uint)((uchar)(v3) >> (in[(t * 4u + 1u)] & 7u)))) & 3u] = ((uint)((ushort)((uint)((ushort)(2712848932u) >> (v2 & 7u)))) * (uint)((ushort)((uint)((bool)(v3 & (v0 ^ t)))))); v5 += w[((uint)(any((uchar2((uchar)(mulhi(in[(t * 4u + 2u)], (v1 ^ t))), (uchar)(v5)) >> uchar2((uchar)(0), (uchar)(2))) <= uchar2((uchar)(55), (uchar)(179))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "    atomic_fetch_add_explicit(&ta, (insert_bits((uint)((uchar)(667474395u) - (uchar)(v1)), (uint)((bool)(0u & in[(t * 4u + 0u)])), (uint)(((uint)((int)((char)(156u))) + 2147483648u) & 15u), (uint)(popcount(2147483648u) & 15u))) & 255u, memory_order_relaxed);\n"
    "    { uint n0 = 0u; while (n0 < 8u) { n0++;\n"
    "        { uint4 w = uint4(((int)((uint)((bool)(in[(t * 4u + 2u)] & 24u))) <= (int)((v0 ^ t)) ? in[(t * 4u + 2u)] : 63u), v5, (uint)(all((ushort3((ushort)(34887), (ushort)(25888), (ushort)(20952)) >> ushort3((ushort)(4), (ushort)(8), (ushort)(2))) != select(ushort3((ushort)((uint)(!(in[(t * 4u + 0u)] > 65536u))), (ushort)((uint)(min((int)((v2 ^ t)), (int)(155u)))), (ushort)((uint)(!(2147483647u > in[(t * 4u + 0u)])))), ushort3((ushort)((uint)(min((int)(in[(t * 4u + 0u)]), (int)((v3 ^ t))))), (ushort)(mulhi(in[(t * 4u + 1u)], 1u)), (ushort)((uint)(!(v1 > (v3 ^ t))))), ushort3((ushort)(insert_bits(in[(t * 4u + 0u)], (v1 ^ t), (uint)(v2 & 15u), (uint)(1234381894u & 15u))), (ushort)((in[(t * 4u + 1u)] != v5 ? in[(t * 4u + 3u)] : (v3 ^ t))), (ushort)(mulhi(in[(t * 4u + 2u)], (v1 ^ t)))) >= ushort3((ushort)(9256), (ushort)(65180), (ushort)(42667))))), v3); w[((v5 ^ t)) & 3u] = ((uint)((ushort)(((uint)((ushort)((v2 ^ t))) * (uint)((ushort)(in[(t * 4u + 0u)]))))) * (uint)((ushort)(3364248384u))); v2 += w[(vf((((char2((char)((uint)(max((int)((v0 ^ t)), (int)(v5)))), (char)(in[(t * 4u + 1u)])) & char2((char)((uint)((bool)(in[(t * 4u + 3u)] & (v1 ^ t)))), (char)(mulhi(1188367161u, (v2 ^ t))))) % char2((char)(35), (char)(21)))))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        if ((((uint)((uchar)(((v4 ^ t) >> (in[(t * 4u + 0u)] & 31u))))) & 3u) == 0u) break; } v4 += n0; }\n"
    "    if ((uint)((short)(reverse_bits(in[(t * 4u + 3u)]))) > (~v4)) {\n"
    "        atomic_fetch_add_explicit(&ta, (((uint)((uchar)((v0 ^ t)) >> (65536u & 7u)) >> (((uint)((int)((short)(v3))) * (v3 ^ t)) & 31u))) & 255u, memory_order_relaxed);\n"
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
    0xca2977c3u, 0xfc842e33u, 0x0f927ab4u, 0x4d4e8403u, 0x8221258fu, 0x9e853f71u, 0xdd7b8112u, 0x58885967u,
    0x0f8d3e04u, 0x49f0640du, 0xe116952du, 0xadfcaf19u, 0x7eca2736u, 0x40b169f2u, 0xbe52412au, 0x2eadc2c4u,
    0xb1cbf9c8u, 0xd44b62cfu, 0x3baa9f01u, 0x347ac5a9u, 0x5be5f123u, 0x954e369du, 0x0d97569eu, 0xaf1d0b89u,
    0xec0fd41du, 0x6b73f699u, 0xa36759c4u, 0x03d12eddu, 0x2868b5eau, 0x1fe3e284u, 0x9078759bu, 0x9aa359aau,
    0x120eb973u, 0x15c02259u, 0x9c05c056u, 0xeaf37d78u, 0xedb9089du, 0x9088c919u, 0xab08713bu, 0x43aeb2cbu,
    0x3f1f9c9bu, 0x804c5e9fu, 0x7f1d86aeu, 0x3dd09d12u, 0x5d78d865u, 0x9e5d115bu, 0x43f75cd5u, 0x559b4973u,
    0x8034e48cu, 0xec637d53u, 0x895af654u, 0xe14794feu, 0x8741f20fu, 0xf38b9878u, 0x06c3e3b4u, 0xf601b7beu,
    0x2dd0cfe4u, 0xf092187cu, 0xeff74e8au, 0xab8b18dcu, 0x5d8dc4f0u, 0x75bf7990u, 0x116c27eau, 0xf9de1f47u,
    0x5b5eef2bu, 0xed5d4ad7u, 0x34a85aebu, 0x4b0f73ecu, 0x3b802ee0u, 0xb2f70bd3u, 0x40fc4d55u, 0x8d0ebd4fu,
    0x319f4902u, 0xa37ac943u, 0xc433ea4eu, 0x2b147005u, 0x783acc8eu, 0xa68ff3b6u, 0xef33cd34u, 0x05e97dbdu,
    0x5e0817e0u, 0x1128bfcau, 0xcc395e93u, 0x9df741f3u, 0xe8b3965du, 0xe93d1893u, 0x2539ccf6u, 0xa8bccc6fu,
    0x81b29fa4u, 0xe23f6369u, 0xa909eb2du, 0x76f95d1au, 0x23da081bu, 0x8ce8c6f3u, 0xe36e14f2u, 0xa98b7419u,
    0xd09f3fedu, 0x72e19c5cu, 0xca7466fbu, 0x3de6ae28u, 0x3511702du, 0x867edc08u, 0x9f951d5au, 0x1dcaf301u,
    0x113642c9u, 0x2eecd58eu, 0xbeaa15bau, 0x10d3a8f6u, 0xbc85b605u, 0xc33b934au, 0x9bfdce95u, 0xc34ed3f6u,
    0x9d46b2e2u, 0xaab2372cu, 0x67129ee3u, 0x8a39f84cu, 0x4407fc84u, 0xd322ad70u, 0x340e1c5bu, 0x0a6ab990u,
    0x3b5b314bu, 0xa4d94c9eu, 0x3e48da5du, 0xc72c61f9u, 0x57af7f6eu, 0x78896953u, 0x589bf248u, 0x2370f7ecu,
    0x6da6a66bu, 0x43805e35u, 0x12f6aa7cu, 0x2620ddfdu, 0x489bb54fu, 0x84dfade7u, 0xf88276d3u, 0xfe4575afu,
    0xf780f56au, 0x87af573au, 0x58daf8bcu, 0x1ebfd2e4u, 0xab68c5dau, 0x36ab9df0u, 0x9fef6274u, 0x11ae3e0fu,
    0x4cf4169cu, 0x5bd76c95u, 0x42089936u, 0xe69c4039u, 0xfb85645eu, 0x18159ea6u, 0x56e27601u, 0x8255e954u,
    0x23fba346u, 0x167fb71du, 0x5a4f65f0u, 0xd52a987du, 0xd71c6d47u, 0x06ed958bu, 0xe00e3555u, 0x8526bd63u,
    0xd6e1f38au, 0x02e44583u, 0x88a9eaf1u, 0xc54a00e3u, 0x710acef2u, 0x8a346bcau, 0x91f6d79cu, 0x48f16512u,
    0x7d2f7008u, 0xda894681u, 0x684b3fc8u, 0xaec12f9du, 0x2f71fd28u, 0x3c73ba87u, 0x19c5ae7eu, 0x1c850500u,
    0xfc689236u, 0xf23b10f6u, 0x6712064cu, 0x193e8f3cu, 0xf1285ed9u, 0xb6cd2470u, 0x586ea139u, 0x604cbc3au,
    0xb03375b9u, 0x24ebdac6u, 0xdd6946dcu, 0x94a105b8u, 0x4cc7a1d1u, 0x096b1cc7u, 0x3c53df9cu, 0x2a7bea25u,
    0x8cfed2f0u, 0x270c6f2au, 0x353c251eu, 0x291f5d71u, 0xf8086d61u, 0xe8661907u, 0xfc3dda28u, 0x3926d781u,
    0x392c361bu, 0x4c9b4f5bu, 0x785f871eu, 0x66b907bcu, 0x54df66f6u, 0x09aa4a2fu, 0x00d26d96u, 0x5f34873fu,
    0xc94e9298u, 0xe5e4bcd8u, 0x72a0fae1u, 0xac7a0a2fu, 0x17fb0f46u, 0xe600eb7du, 0x233319ddu, 0x3f021408u,
    0xaf464b67u, 0xb625d7d0u, 0xdb22f6c3u, 0x03e0e451u, 0xd167a37fu, 0x71989bedu, 0x3c47d139u, 0x98d57e7cu,
    0xa28bed9bu, 0x88a65ad1u, 0x314d788fu, 0x1a21ed18u, 0x519ab2b3u, 0xa61f660fu, 0xd94c1061u, 0x9d7a4084u,
    0x721d7cfbu, 0x79177dc9u, 0xb32df743u, 0xaa3e7f8bu, 0xbcffea21u, 0x9506c2d6u, 0x8afcf036u, 0x5273df8du,
    0xe4d37161u, 0xe5924b4fu, 0x03d1e000u, 0x750a8197u, 0xb00672afu, 0x25f148e4u, 0x6d07debbu, 0x44a97752u,
    0xe59212d7u, 0x513ee4a0u, 0x3705de95u, 0x0d3ff324u, 0xdac85379u, 0xe1571fcau, 0x9e5eee28u, 0x6b6e6601u
};

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n40-kepler-private-final-loads";
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
    return PASS(bug, "%s: a kernel's final loads of its private arrays leave the rest of it right", name);
}}
