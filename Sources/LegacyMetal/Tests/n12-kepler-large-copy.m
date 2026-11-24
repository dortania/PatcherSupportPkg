// n12-kepler-large-copy: a pipeline copying large structs must build in seconds; the back end's time is cubic in a
// memcpy's size (minutes). Fix: GeForceAIRCompat NVAIR_LARGE_COPY_LOOP. Checks: 232-byte struct copies and a swap
// through pointers: built in under 10 s, every word right. Argument: GPU name (default: NVIDIA).
#import "repro.h"
#include <mach/mach_time.h>

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct S { int a, b, c, d; };\n"
    "struct Data { int x; int y; array<int, 4> arr; S s; array<int, 48> big; };\n"
    "struct In { Data a; Data b; array<int, 8> p; };\n"
    "struct Out { array<int, 4> r; Data a; Data b; };\n"
    "static int f(device int *pa, device int *pb) { int a = *pa, b = *pb; *pa = b; *pb = a; return b; }\n"
    "kernel void k(const device In *input [[buffer(0)]], device Out *output [[buffer(1)]], device Data *A [[buffer(2)]],\n"
    "              device Data *B [[buffer(3)]]) {\n"
    "    *A = input->a; *B = input->b; output->r[0] = f(&A->x, &B->x); output->a = *A; output->b = *B; }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n12-kepler-large-copy";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t t0 = mach_absolute_time();
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    double seconds = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;
    if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    const int dataWords = 58, inWords = 2 * dataWords + 8, outWords = 4 + 2 * dataWords;
    id<MTLBuffer> in = [dev newBufferWithLength:inWords * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:outWords * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> A = [dev newBufferWithLength:dataWords * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> B = [dev newBufferWithLength:dataWords * 4 options:MTLResourceStorageModeShared];
    int32_t *pi = in.contents;
    for (int i = 0; i < inWords; i++) pi[i] = 1000 + i * 7;
    memset(out.contents, 0xee, outWords * 4);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:in offset:0 atIndex:0];
    [ce setBuffer:out offset:0 atIndex:1];
    [ce setBuffer:A offset:0 atIndex:2];
    [ce setBuffer:B offset:0 atIndex:3];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
    int32_t a[58], b[58];
    memcpy(a, pi, sizeof a);
    memcpy(b, pi + dataWords, sizeof b);
    int32_t ax = a[0], bx = b[0];
    a[0] = bx, b[0] = ax;
    const int32_t *po = out.contents;
    if (po[0] != bx) return FAIL(bug, "%s: r[0] = %d, want %d", name, po[0], bx);
    for (int i = 0; i < dataWords; i++)
        if (po[4 + i] != a[i] || po[4 + dataWords + i] != b[i])
            return FAIL(bug, "%s: output word %d of a / b wrong (%d / %d, want %d / %d)", name, i, po[4 + i], po[4 + dataWords + i], a[i], b[i]);
    if (seconds > 10) return FAIL(bug, "%s: the pipeline took %.1f s to build (results right)", name, seconds);
    return PASS(bug, "%s: 232-byte struct copies build in %.1f s and copy right", name, seconds);
}}
