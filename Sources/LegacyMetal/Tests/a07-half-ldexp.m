// a07-half-ldexp (AMD adapter): ldexp on half is broken in libAMDIL902 at every width. half, half2 and half4 compile but
// return wrong values (0, inf). half3 crashes MTLCompilerService: the plugin renames air.ldexp.* to air.fast_ldexp.*, then
// widens vec3 intrinsics to vec4 by name, and its intrinsic table has no air.fast_ldexp.v4f16, so the pipeline fails with
// "Compiler encountered an internal error". (WebGPU CTS builtin,ldexp:f16.)
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k1(device half  *x [[buffer(0)]], constant int  *e [[buffer(1)]]) { half  a = x[0]; int  n = e[0]; x[1] = ldexp(a, n); }\n"
    "kernel void k2(device half2 *x [[buffer(0)]], constant int2 *e [[buffer(1)]]) { half2 a = x[0]; int2 n = e[0]; x[1] = ldexp(a, n); }\n"
    "kernel void k3(device half3 *x [[buffer(0)]], constant int3 *e [[buffer(1)]]) { half3 a = x[0]; int3 n = e[0]; x[1] = ldexp(a, n); }\n"
    "kernel void k4(device half4 *x [[buffer(0)]], constant int4 *e [[buffer(1)]]) { half4 a = x[0]; int4 n = e[0]; x[1] = ldexp(a, n); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a07-half-ldexp";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        const __fp16 in[8] = {1.5f, -2.5f, 0.75f, 3.0f};
        const __fp16 want[4] = {12.0f, -5.0f, 0.1875f, 3.0f};
        const int exponents[4] = {3, 1, -2, 0};
        const int outIndex[5] = {0, 1, 2, 4, 4};  // where x[1] starts, in halfs: half3 takes the space of half4
        id<MTLCommandQueue> q = [dev newCommandQueue];
        char problems[400] = "";
        for (int width = 1; width <= 4; width++) {
            NSString *name = [NSString stringWithFormat:@"k%d", width];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&err];
            if (!ps) {
                snprintf(problems + strlen(problems), sizeof problems - strlen(problems), " width %d: pipeline: %s;", width, err.localizedDescription.UTF8String);
                continue;
            }
            id<MTLBuffer> x = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
            id<MTLBuffer> e = [dev newBufferWithBytes:exponents length:sizeof exponents options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:ps]; [enc setBuffer:x offset:0 atIndex:0]; [enc setBuffer:e offset:0 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [enc endEncoding];
            reproRun(cb);
            const __fp16 *out = (const __fp16 *)x.contents + outIndex[width];
            for (int c = 0; c < width; c++)
                if (out[c] != want[c]) {
                    snprintf(problems + strlen(problems), sizeof problems - strlen(problems), " width %d: ldexp(%g, %d) = %g, want %g;",
                             width, (float)in[c], exponents[c], (float)out[c], (float)want[c]);
                    break;
                }
        }
        if (problems[0]) return FAIL(bug, "%s:%s", dev.name.UTF8String, problems);
        return PASS(bug, "%s: ldexp on half, half2, half3 and half4 compiles and returns the right values", dev.name.UTF8String);
    }
}
