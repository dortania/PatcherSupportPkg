// s13: a kernel with a function constant, compiled to metallibs for macOS 14 (control) and macOS 15.4 (AIR v27).
#include <metal_stdlib>
using namespace metal;
constant bool kFlip [[function_constant(0)]];
kernel void k(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = kFlip ? -float(i) : float(i); }
