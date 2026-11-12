// ubo.random.basic_types.19 (deqp WebGL2) as ANGLE translated it, as compute kernels: fill writes the blocks with the
// expected values (MSL layout), checkDirect/checkArg compare them read as constant buffers / through an argument buffer.
#include <metal_stdlib>
using namespace metal;

struct BlockB { float3 a; uint b; float c; float2 d; };
struct BlockC { int2 e; };
struct BlockD { bool3 f; };
struct BlockE { float2x3 g; uint3 h; float3x4 i; bool4 j; };
struct BlockF { float2x2 k; float3x3 l; uint2 m; int2 n; };

struct Blocks { constant BlockB *b [[id(0)]]; constant BlockC *c [[id(1)]]; constant BlockD *d [[id(2)]];
                constant BlockE *e [[id(3)]]; constant BlockF *f [[id(4)]]; };

kernel void fill(device BlockB &b [[buffer(1)]], device BlockC &c [[buffer(2)]], device BlockD &d [[buffer(3)]],
                 device BlockE &e [[buffer(4)]], device BlockF &f [[buffer(5)]]) {
    b.a = float3(-1, 7, -1); b.b = 4; b.c = -4; b.d = float2(8, 4);
    c.e = int2(-1, 9);
    d.f = bool3(false, true, true);
    e.g = float2x3(-7, 2, 2, -6, -2, 9); e.h = uint3(1, 4, 9); e.i = float3x4(-5, -6, 2, -5, 4, 7, 7, -1, -1, 3, 0, 8);
    e.j = bool4(true, true, true, true);
    f.k = float2x2(6, 5, 9, 0); f.l = float3x3(-3, -7, 7, 0, 4, 3, -6, 4, -3); f.m = uint2(9, 8); f.n = int2(3, -4);
}

static float cmp(float a, float b) { return abs(a - b) < 0.05 ? 1 : 0; }
template <typename T, int N> static float cmpv(vec<T, N> a, vec<T, N> b) { return all(a == b) ? 1 : 0; }
template <int N> static float cmpf(vec<float, N> a, vec<float, N> b) { return all(abs(a - b) < 0.05) ? 1 : 0; }

static void check(constant BlockB &b, constant BlockC &c, constant BlockD &d, constant BlockE &e, constant BlockF &f,
                  device float *out) {
    out[0] = cmpf(b.a, float3(-1, 7, -1));
    out[1] = b.b == 4u ? 1 : 0;
    out[2] = cmp(b.c, -4);
    out[3] = cmpf(b.d, float2(8, 4));
    out[4] = cmpv(c.e, int2(-1, 9));
    out[5] = cmpv(d.f, bool3(false, true, true));
    out[6] = cmpf(e.g[0], float3(-7, 2, 2)) * cmpf(e.g[1], float3(-6, -2, 9));
    out[7] = cmpv(e.h, uint3(1, 4, 9));
    out[8] = cmpf(e.i[0], float4(-5, -6, 2, -5)) * cmpf(e.i[1], float4(4, 7, 7, -1)) * cmpf(e.i[2], float4(-1, 3, 0, 8));
    out[9] = cmpv(e.j, bool4(true, true, true, true));
    out[10] = cmpf(f.k[0], float2(6, 5)) * cmpf(f.k[1], float2(9, 0));
    out[11] = cmpf(f.l[0], float3(-3, -7, 7)) * cmpf(f.l[1], float3(0, 4, 3)) * cmpf(f.l[2], float3(-6, 4, -3));
    out[12] = cmpv(f.m, uint2(9, 8));
    out[13] = cmpv(f.n, int2(3, -4));
}

kernel void checkDirect(device float *out [[buffer(0)]], constant BlockB &b [[buffer(1)]], constant BlockC &c [[buffer(2)]],
                        constant BlockD &d [[buffer(3)]], constant BlockE &e [[buffer(4)]], constant BlockF &f [[buffer(5)]]) {
    check(b, c, d, e, f, out);
}

kernel void checkArg(device float *out [[buffer(0)]], constant Blocks &blocks [[buffer(6)]]) {
    check(*blocks.b, *blocks.c, *blocks.d, *blocks.e, *blocks.f, out);
}
