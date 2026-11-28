// s68: the same kernel as a stitchable Core Image kernel (linked with -framework CoreImage).
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" [[stitchable]] float4 s68_brightness(coreimage::sample_t s, float amount) { return float4(s.rgb + amount, s.a); }
