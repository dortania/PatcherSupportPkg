// r02-amd-short3-bounds-load (regression test for the AMD adapter's a16 fix; AMD GCN on the 12.5 stack): a signed
// comparison with a short3 loaded from constant memory must read the vector's own three lanes. a16 does signed narrow
// comparisons in 32 bits; zero-extending the loaded short3 whole let libAMDIL902 fold the extension into the load as a
// <3 x i32> one, which fetched lane 2 at byte 8, past the short3, from the struct's padding. MPS's image kernels bound-
// check their thread position like this against a short3 size in parameters whose padding MPS doesn't clear, so
// MPSImageAdd and MPSImageMultiply wrote nothing whenever a leftover pointer's bits there read as a negative depth (about
// half the calls). The kernel here returns early when any(size <= short3(thread position)), with size (64, 48, 1) and the
// padding bytes 0x80, so lane 2 read from the padding would be -32640 and every thread would return.
// Expected: PASS with no a16 fix and with a correct one; FAIL with the whole-vector extension (AMD_NARROW_LOAD3_FIX=0).
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct P { float4 scale; short3 size; float4 bias; };\n"
    "kernel void k(constant P &p [[buffer(0)]], device uint *out [[buffer(1)]], ushort3 gid [[thread_position_in_grid]]) {\n"
    "  if (any(p.size <= short3(gid))) return;\n"
    "  out[gid.y * 64 + gid.x] = 1u + uint(p.scale.x + p.bias.x);\n"
    "}\n";

enum { W = 64, H = 48 };

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "r02-amd-short3-bounds-load";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        uint8_t params[48];  // scale at 0, size at 16 (bytes 22-31 padding), bias at 32
        memset(params, 0x80, sizeof params);
        memset(params, 0, 16);
        memset(params + 32, 0, 16);
        const int16_t size[3] = {W, H, 1};
        memcpy(params + 16, size, sizeof size);
        id<MTLBuffer> out = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
        memset(out.contents, 0, W * H * 4);
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setBytes:params length:sizeof params atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc dispatchThreadgroups:MTLSizeMake(W / 16, H / 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        int written = 0;
        for (int i = 0; i < W * H; i++) written += ((const uint32_t *)out.contents)[i] == 1;
        if (written != W * H)
            return FAIL(bug, "%s: a bounds check against a short3 size passed for %d of %d threads (lane 2 read from the padding?)",
                        dev.name.UTF8String, written, W * H);
        return PASS(bug, "%s: a signed comparison with a loaded short3 reads its own three lanes (%d threads)", dev.name.UTF8String, W * H);
    }
}
