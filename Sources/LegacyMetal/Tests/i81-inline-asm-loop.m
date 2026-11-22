// i81-inline-asm-loop (Intel adapter, IntelTextureAtomics.dylib; Kepler adapter, GeForceAIRCompat.dylib): loop bodies with
// __asm__(""), which ANGLE writes into every loop it translates so the front end can't take the loop for one that ends
// (Chromium 142's, in Electron 39: Skia's blur shader is such a loop). It reaches the 3802 back ends as
// `call void asm sideeffect "", ""()`, a call without a called function, whose name they read: IGILInstructionCleanup on
// Intel and GeForceAIRPlugin on Kepler dereference null (Value::getName), MTLCompilerService crashes, MetalOld sends the
// request again, and the window that drew a shadow stays blank (OpenVPN Connect 3.9.1). The adapters drop the call. A
// vertex, a fragment and a kernel function each have such a loop; the kernel's sum is checked.
// Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel; NVIDIA for Kepler).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i81-inline-asm-loop";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 position [[position]]; float2 uv; };\n"
            "vertex V v(uint id [[vertex_id]], constant float4 *k [[buffer(0)]]) {\n"
            "    float4 sum = 0;\n"
            "    for (int i = 0; i < 4; i++) { __asm__(\"\"); sum += k[i]; }\n"
            "    V o; o.position = float4(float2((id << 1) & 2, id & 2) * 2 - 1, 0, 1); o.uv = sum.xy; return o;\n"
            "}\n"
            "fragment float4 f(V in [[stage_in]], constant float4 *k [[buffer(0)]]) {\n"
            "    float4 sum = 0;\n"
            "    for (int i = 0; i < 4; i++) { __asm__(\"\"); sum += k[i] * in.uv.x; }\n"
            "    return sum;\n"
            "}\n"
            "kernel void c(device float4 *out [[buffer(0)]], constant float4 *k [[buffer(1)]], uint id [[thread_position_in_grid]]) {\n"
            "    float4 sum = 0;\n"
            "    uint i = 0;\n"
            "    while (i < 4) { __asm__(\"\"); sum += k[i]; i++; }\n"
            "    out[id] = sum;\n"
            "}\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: front end: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (![dev newRenderPipelineStateWithDescriptor:pd error:&error])
            return FAIL(bug, "%s: vertex and fragment functions with __asm__(\"\") in a loop: no pipeline (%s)", dev.name.UTF8String,
                        error.localizedDescription.UTF8String);
        id<MTLComputePipelineState> compute = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"c"] error:&error];
        if (!compute)
            return FAIL(bug, "%s: kernel with __asm__(\"\") in a loop: no pipeline (%s)", dev.name.UTF8String, error.localizedDescription.UTF8String);
        const float k[16] = {1, 2, 3, 4, 10, 20, 30, 40, 100, 200, 300, 400, 1000, 2000, 3000, 4000};
        id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> in = [dev newBufferWithBytes:k length:sizeof k options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:compute];
        [e setBuffer:out offset:0 atIndex:0];
        [e setBuffer:in offset:0 atIndex:1];
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [e endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: the kernel's command buffer failed", dev.name.UTF8String);
        const float *sum = out.contents;
        if (sum[0] != 1111 || sum[1] != 2222 || sum[2] != 3333 || sum[3] != 4444)
            return FAIL(bug, "%s: the loop's sum is %g %g %g %g, want 1111 2222 3333 4444", dev.name.UTF8String, sum[0], sum[1], sum[2], sum[3]);
        return PASS(bug, "%s: vertex, fragment and kernel functions with __asm__(\"\") in their loops build, and the kernel's loop sums right",
                    dev.name.UTF8String);
    }
}
