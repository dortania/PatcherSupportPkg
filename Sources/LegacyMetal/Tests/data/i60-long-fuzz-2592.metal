#include <metal_stdlib>
using namespace metal;
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
    switch (((uint)((((0u) | (ulong)((uint)(select((int)((v4 ^ t)), (int)(3870044968u), (in[(t * 4u + 1u)] & 2u) != 0u))))) / (1u))) & 3u) {
    case 0u: {
        v2 = (uint)(-(int)(((int)(0u) >= (int)((uint)((bool)(in[(t * 4u + 0u)] & (v5 ^ t)))) ? (uint)((int)((v1 ^ t)) / (int)((3695561914u | 1u) & 0x7fffffffu)) : (uint)((bool)(87u & in[(t * 4u + 2u)]))) & 0x7fffffffu));
        }
    case 1u: {
        { uint n1 = 0u; while (n1 < 8u) { n1++;
            v0 = ((rotate((((v4 ^ t) % (in[(t * 4u + 3u)] | 1u))), ((v4 % (18u | 1u)))) % (insert_bits((uint)((int)((v4 ^ t)) >> (int)(2313157118u & 31u)), (in[(t * 4u + 3u)] * (v3 ^ t)), (uint)((1290106643u << (v2 & 31u)) & 15u), (uint)((uint)((int)(v2) % (int)((65535u | 1u) & 0x7fffffffu)) & 15u)) | 1u)));
            if (0u) break; } v1 += n1; }
        break; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    out[t * 8u + 0u] = v0;
}
