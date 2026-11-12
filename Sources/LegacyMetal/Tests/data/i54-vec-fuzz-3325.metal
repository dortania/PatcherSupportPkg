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
    if (1u) {
        { uint n1 = 0u; while (n1 < 8u) { n1++;
            v1 = ((int)(((hadd(in[(t * 4u + 0u)], 2147483648u) & 1u) != 0u ? (0u) : (uint)((int)(in[(t * 4u + 3u)]) >> (int)(256u & 31u)))) < (int)(0u) ? vf((uchar3((uchar)(0u), (uchar)(0u), (uchar)(in[(t * 4u + 3u)])))) : vf((((ushort3((ushort)((uint)(pc[(176u) & 7u])), (ushort)(7u), (ushort)((uint)(min((int)(in[(t * 4u + 2u)]), (int)(781038397u))))) << ushort3((ushort)(7), (ushort)(5), (ushort)(14))) >> ushort3((ushort)(11), (ushort)(13), (ushort)(15))))));
            if (0u) break; } v1 += n1; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[t * 8u + 1u] = v1;
}
