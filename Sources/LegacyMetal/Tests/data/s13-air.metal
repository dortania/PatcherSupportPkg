// s13: function constants compiled to metallibs for macOS 14 (control) and macOS 15.4 (AIR 2.7). kp's buffer(1) exists
// only when kScale is defined: AIR 2.7 expresses that predicate as an implicit function constant
// (__metal_implicit_fc_pred_0, set by a static initializer), as iMovie's video viewer shader does.
#include <metal_stdlib>
using namespace metal;
constant bool kFlip [[function_constant(0)]];
constant float kScale [[function_constant(1)]];
constant bool kScaleDefined = is_function_constant_defined(kScale);
kernel void k(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = kFlip ? -float(i) : float(i); }
kernel void kp(device float *out [[buffer(0)]], constant float &offset [[buffer(1), function_constant(kScaleDefined)]],
               uint i [[thread_position_in_grid]]) {
    out[i] = kScaleDefined ? kScale * float(i) + offset : float(i);
}
