// s68: a precompiled Core Image color kernel, built with -fcikernel (the kind Microsoft Office's Oimg.metallib holds).
#include <CoreImage/CoreImage.h>
extern "C" { namespace coreimage {
    float4 s68_brightness(sample_t s, float amount) { return float4(s.rgb + amount, s.a); }
}}
