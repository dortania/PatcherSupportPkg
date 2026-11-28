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
    uint p[8];
    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;
    uchar pc[8];
    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);
    uint v0 = in[(0u)] * 1u + t;
    uint v1 = in[(0u)] * 3u + t;
    uint v2 = in[(t * 4u + 2u)] * 5u + t;
    uint v3 = in[(t * 4u + 3u)] * 7u + t;
    uint v4 = in[(t * 4u + 0u)] * 9u + t;
    uint v5 = in[(t * 4u + 1u)] * 11u + t;
    { uint4 w = uint4(0u); w[(0u) & 3u] = ((short)(rotate((v4 ^ t), in[(t * 4u + 1u)])) == (short)(0u) ? (uint)(pc[((v4 ^ t)) & 7u]) : (0u)); v2 += w[(((int)(v3) >= (int)(0u) ? (0u) : rotate(3397348150u, in[(t * 4u + 2u)]))) & 3u] ^ (w.y << 1u) ^ w.w; }
    switch ((mulhi((0u), in[(t * 4u + 2u)])) & 3u) {
    case 0u: {
        break; }
    case 1u: {
        break; }
    case 2u: {
        { uint n1 = 0u; while (n1 < 8u) { n1++;
            if (((((mulhi(v2, v4) & 1u) != 0u ? (uint)(1u) : (0u))) & 3u) == 0u) break; } v3 += n1; }
        break; }
    default: {
        v2 ^= p[(0u) & 7u];
        break; }
    }
    v0 = 0u;
    switch (((uint)((int)((short)(90u) % (short)((v2 & 32767u) | 1u)))) & 3u) {
    case 2u: {
        break; }
    default: {
        v5 = rotate(((uint)(1u) > extract_bits(255u, (uint)(v2 & 15u), (uint)(v5 & 15u)) ? (uint)(pc[((v0 ^ t)) & 7u]) : in[(t * 4u + 1u)]), 224u);
        break; }
    }
    if (((uint)(min((int)((v3 ^ t)), (int)(v3))) >= (uint)(1u) ? ((uint)((int)((char)((v5 ^ t)))) * (v3 ^ t)) : ((uint)(1u) * (uint)((ushort)(in[(t * 4u + 1u)])))) > ((uint)(0u) == min(v1, v2) ? (uint)(max((int)(214u), (int)(4294967295u))) : (v5 ^ t))) {
        v5 = min3(((uchar)(0u) == (uchar)(v5) ? (uint)(0u) : clz((v1 ^ t))), max(min(11u, v0), (uint)(0u)), (uint)(0u));
    }
    out[t * 8u + 5u] = v5;
}
