// s77: one Core Image kernel of each kind (build.sh builds it for every macOS target from 10.13 to 26.0 with
// metal -fcikernel and metallib -cikernel; s77-coreimage-kernel-kinds.m checks each against computed values).
#include <CoreImage/CoreImage.h>
extern "C" { namespace coreimage {
    float4 s77_color(sample_t s) { return float4(s.rgb * 0.5 + 0.25 * s.a, s.a); }          // halve and lift
    float2 s77_warp(destination dest) { return dest.coord() + float2(-3.0, 0.0); }            // read 3 px to the left
    float4 s77_blend(sample_t fg, sample_t bg) { return fg + bg * (1.0 - fg.a); }             // source over
    float4 s77_general(sampler src) {                                                          // a pixel and its right neighbour
        float2 c = src.coord();
        return 0.5 * (src.sample(c) + src.sample(c + src.transform(float2(1.0, 0.0)) - src.transform(float2(0.0, 0.0))));
    }
}}
