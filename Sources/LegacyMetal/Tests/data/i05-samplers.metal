// i05-intel-constexpr-sampler: constexpr samplers, built into a metallib for macOS 14 (one-word sampler states) and for
// macOS 15.4 (AIR 2.7: two-word sampler states). t is 4x4 R32Float holding 10 * y + x; each line reads one texel.
#include <metal_stdlib>
using namespace metal;

kernel void k(texture2d<float> t [[texture(0)]], device float *out [[buffer(0)]]) {
    constexpr sampler edge(coord::pixel, address::clamp_to_edge, filter::nearest);
    constexpr sampler wrap(address::repeat, filter::nearest);
    constexpr sampler mirror(address::mirrored_repeat, filter::nearest);
    constexpr sampler border(address::clamp_to_border, border_color::opaque_white, filter::nearest);
    constexpr sampler linear(coord::pixel, filter::linear);
    out[0] = t.sample(edge, float2(-1.5, 1.5), level(0)).x;             // clamped to texel (0, 1): 10
    out[1] = t.sample(wrap, float2(1.125, 2.375), level(0)).x;          // wraps to texel (0, 1): 10
    out[2] = t.sample(mirror, float2(1.125, 0.625), level(0)).x;        // mirrored to texel (3, 2): 23
    out[3] = t.sample(border, float2(1.5, 0.5), level(0)).x;            // outside: the border, 1
    out[4] = t.sample(linear, float2(2.0, 1.5), level(0)).x;            // halfway between (1, 1) and (2, 1): 11.5
}
