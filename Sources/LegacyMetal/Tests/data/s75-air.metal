// s75's shaders, compiled by build.sh for each macOS target from 10.14 (AIR 2.1, what Chromium's prebuilt ANGLE library
// is built for) up, as an app shipping a prebuilt metallib would: texture sampling, texel reads, multisample reads, an
// array texture and function constants in fragment functions, and a mipmap-style kernel and a sampling kernel.
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullVS(uint vid [[vertex_id]]) {
    float2 q = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(q * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(q.x, 1.0 - q.y);
    return o;
}

fragment float4 sampleFS(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv);
}

fragment float4 readFS(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    return t.read(uint2(in.pos.xy));
}

fragment float4 msReadFS(VOut in [[stage_in]], texture2d_ms<float> t [[texture(0)]]) {
    return t.read(uint2(in.pos.xy), 0);
}

fragment float4 arrayFS(VOut in [[stage_in]], texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv, 1);
}

constant int kMode [[function_constant(0)]];  // 0: sample, 1: read, 2: gather (red of the texel's own corner)
fragment float4 constantFS(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    if (kMode == 0) return t.sample(s, in.uv);
    if (kMode == 1) return t.read(uint2(in.pos.xy));
    float4 g = t.gather(s, in.uv);  // at a texel's center with nearest filtering: the 2x2 footprint around it
    return float4(g.w, 0.0, 0.0, 1.0);
}

kernel void mipKernel(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                      uint2 g [[thread_position_in_grid]]) {
    dst.write((src.read(g * 2) + src.read(g * 2 + uint2(1, 0)) + src.read(g * 2 + uint2(0, 1)) + src.read(g * 2 + uint2(1, 1))) * 0.25, g);
}

kernel void sampleKernel(texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]], device float4 *out [[buffer(0)]],
                         uint g [[thread_position_in_grid]]) {
    out[g] = src.sample(s, (float2(g % 8, g / 8) + 0.5) / 8.0, level(0));
}
