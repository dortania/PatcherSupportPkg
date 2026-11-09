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
    { uint4 w = uint4((uint)(!(v3 > (uint)(-(int)(2u & 0x7fffffffu)))), v3, vf((max((short4((short)(31612), (short)(-3092), (short)(-4143), (short)(-15542)) & short4((short)(0u), (short)(subsat(102u, 2359986809u)), (short)((uint)(pc[(in[(t * 4u + 0u)]) & 7u])), (short)((uint)(!(v5 > 191u))))), (short4((short)(-2106), (short)(-21362), (short)(-20994), (short)(25932)) / short4((short)(10328), (short)(20179), (short)(29045), (short)(8264)))))), v2); w[(0u) & 3u] = in[(t * 4u + 0u)]; v0 += w[((((v0 ^ t) / (v4 | 1u)) >> (mulhi(v3, v3) & 31u))) & 3u] ^ (w.y << 1u) ^ w.w; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[t * 8u + 0u] = v0;
}
