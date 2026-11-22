// s77: a [[stitchable]] Core Image colour kernel, linked against CoreImage (macOS 12 and later).
#include <CoreImage/CoreImage.h>
[[stitchable]] float4 s77_stitchable(coreimage::sample_t s) { return float4(s.rgb * 0.5 + 0.25 * s.a, s.a); }
