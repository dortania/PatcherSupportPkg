// n13-kepler-half-constant (Kepler adapter, NVAIR_HALF_CONSTANT_FIX): a constant array of half2x2 (what WGSL `const`
// f16 matrices become: WebGPU CTS shader,execution,expression,constructor,non_zero) reaches Kepler's compiler with each
// half2 column spelled as a constant expression, bitcast (<1 x i32> <i32 bits> to <2 x half>), and its constant lowering
// crashes on that (a null dereference): the compiler service died on every try, and the app's next compile then waited
// on it forever. A kernel copies the constant half2x2 {11, 12, 21, 22} to a buffer.
// Stock OCLP on Kepler: FAIL (the compiler crashes). Fixed: PASS. Argument: GPU name substring (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Output { half2x2 value; };\n"
    "constant array<half2x2, 1> v = array<half2x2, 1>{half2x2(half2(11.0h, 12.0h), half2(21.0h, 22.0h))};\n"
    "kernel void k(device array<Output, 1> *outputs [[buffer(0)]], constant uint &n [[buffer(1)]]) {\n"
    "    for (uint i = 0; i < n; i++) (*outputs)[i].value = v[i]; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n13-kepler-half-constant";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    id<MTLBuffer> out = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    memset(out.contents, 0, 8);
    uint32_t n = 1;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce setBytes:&n length:4 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    const __fp16 *h = out.contents;
    if (h[0] != 11 || h[1] != 12 || h[2] != 21 || h[3] != 22)
        return FAIL(bug, "%s: the constant half2x2 read back (%g, %g, %g, %g), want (11, 12, 21, 22)", name, (float)h[0], (float)h[1], (float)h[2], (float)h[3]);
    return PASS(bug, "%s: a constant array of half2x2 compiles and reads back right", name);
}}
