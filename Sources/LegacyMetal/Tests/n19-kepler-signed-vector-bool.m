// n19-kepler-signed-vector-bool (Kepler adapter, NVAIR_SIGNED_BOOL_FIX): bool2 / bool3 / bool4 of vectors of signed
// integers. Kepler gave false for INT_MIN (and the minimum of char and short vectors): the plugin's library tests each
// lane as (x & INT_MAX) != 0, the rule for a float lane, so that -0.0 is false (WebGPU CTS unary bool_conversion:i32,
// vec2-vec4; scalars and unsigned vectors are right). int2 / int3 / int4, short4 and char4 lanes of minimum, -1, 0, 1 and
// maximum, from a buffer; float4 with -0.0 and 0.0 still false.
// Stock OCLP on Kepler: FAIL. Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void i2(device const int2 *in [[buffer(0)]], device uint2 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = select(uint2(0), uint2(1), bool2(in[i])); }\n"
    "kernel void i3(device const packed_int3 *in [[buffer(0)]], device packed_uint3 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = packed_uint3(select(uint3(0), uint3(1), bool3(int3(in[i])))); }\n"
    "kernel void i4(device const int4 *in [[buffer(0)]], device uint4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = select(uint4(0), uint4(1), bool4(in[i])); }\n"
    "kernel void s4(device const short4 *in [[buffer(0)]], device uint4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = select(uint4(0), uint4(1), bool4(in[i])); }\n"
    "kernel void c4(device const char4 *in [[buffer(0)]], device uint4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = select(uint4(0), uint4(1), bool4(in[i])); }\n"
    "kernel void f4(device const float4 *in [[buffer(0)]], device uint4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = select(uint4(0), uint4(1), bool4(in[i])); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n19-kepler-signed-vector-bool";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // 12 lanes for each kind; want[] is whether a lane is nonzero
    int32_t ints[12] = {INT32_MIN, -1, 0, 1, INT32_MAX, INT32_MIN + 1, 0, INT32_MIN, 5, 0, -7, INT32_MIN};
    int16_t shorts[12] = {INT16_MIN, -1, 0, 1, INT16_MAX, INT16_MIN + 1, 0, INT16_MIN, 5, 0, -7, INT16_MIN};
    int8_t chars[12] = {INT8_MIN, -1, 0, 1, INT8_MAX, INT8_MIN + 1, 0, INT8_MIN, 5, 0, -7, INT8_MIN};
    float floats[12] = {-0.0f, 0.0f, -1.0f, 1e-30f, -0.0f, INFINITY, 0.0f, -2.5f, NAN, -0.0f, 0.0f, 3.0f};
    struct { const char *k, *what; const void *data; NSUInteger lanes, size; BOOL isFloat; } kinds[] = {
        {"i2", "int2", ints, 2, 4, NO}, {"i3", "int3", ints, 3, 4, NO}, {"i4", "int4", ints, 4, 4, NO},
        {"s4", "short4", shorts, 4, 2, NO}, {"c4", "char4", chars, 4, 1, NO}, {"f4", "float4", floats, 4, 4, YES}};
    for (int k = 0; k < 6; k++) {
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kinds[k].k)] error:&err];
        if (!ps) return FAIL(bug, "%s: %s: pipeline: %s", name, kinds[k].what, err.localizedDescription.UTF8String);
        id<MTLBuffer> in = [dev newBufferWithBytes:kinds[k].data length:12 * kinds[k].size options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:12 * 4 options:MTLResourceStorageModeShared];
        memset(out.contents, 0xee, out.length);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:in offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(12 / kinds[k].lanes, 1, 1) threadsPerThreadgroup:MTLSizeMake(12 / kinds[k].lanes, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, kinds[k].what);
        for (int i = 0; i < 12; i++) {
            BOOL nonzero = kinds[k].isFloat ? floats[i] != 0.0f || isnan(floats[i])
                         : kinds[k].size == 4 ? ints[i] != 0 : kinds[k].size == 2 ? shorts[i] != 0 : chars[i] != 0;
            uint32_t got = ((uint32_t *)out.contents)[i];
            if (got != (uint32_t)nonzero) {
                long long v = kinds[k].size == 4 ? (kinds[k].isFloat ? 0 : ints[i]) : kinds[k].size == 2 ? shorts[i] : chars[i];
                if (kinds[k].isFloat)
                    return FAIL(bug, "%s: %s lane %d (%g) converted to %s, want %s", name, kinds[k].what, i, floats[i], got ? "true" : "false", nonzero ? "true" : "false");
                return FAIL(bug, "%s: %s lane %d (%lld) converted to %s, want %s", name, kinds[k].what, i, v, got ? "true" : "false", nonzero ? "true" : "false");
            }
        }
    }
    return PASS(bug, "%s: bool vectors of int2-int4, short4 and char4 are true for every nonzero lane, minimums too (and float4's -0.0 stays false)", name);
}}
