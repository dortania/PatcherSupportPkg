// s33-intel-nil-argument-buffer (MetalOldCompat item 28): nil buffers in argument buffers on the 12.x Intel driver. Its
// argument buffers are emulated (tier 1), and the emulated encoder's setBuffer:offset:atIndex: and
// setBuffers:offsets:withRange: read the buffer's GPU address without checking for nil, so encoding nil into an unused
// slot, which Metal allows, dereferences null. Cycles (Blender 3.6's GPU renderer) does that before every kernel, so a
// GPU render crashed Blender. An encoder with four buffer slots gets nil in slot 0 with setBuffer, and nil in slot 2
// with setBuffers; a kernel then reads the buffers in slots 1 and 3.
// Stock OCLP: FAIL (crash). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Slots { device float *a [[id(0)]]; device float *b [[id(1)]]; device float *c [[id(2)]]; device float *d [[id(3)]]; };\n"
    "kernel void k(constant Slots &slots [[buffer(0)]], device float *out [[buffer(1)]]) {\n"
    "    out[0] = slots.b[0];\n"
    "    out[1] = slots.d[1];\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s33-intel-nil-argument-buffer";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        id<MTLFunction> f = [lib newFunctionWithName:@"k"];
        id<MTLComputePipelineState> pipeline = f ? [dev newComputePipelineStateWithFunction:f error:&error] : nil;
        if (!pipeline) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLArgumentEncoder> encoder = [f newArgumentEncoderWithBufferIndex:0];
        id<MTLBuffer> slots = [dev newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
        const float b[1] = {42}, d[2] = {0, 7};
        id<MTLBuffer> bb = [dev newBufferWithBytes:b length:sizeof b options:MTLResourceStorageModeShared];
        id<MTLBuffer> db = [dev newBufferWithBytes:d length:sizeof d options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:2 * sizeof(float) options:MTLResourceStorageModeShared];
        [encoder setArgumentBuffer:slots offset:0];
        [encoder setBuffer:nil offset:0 atIndex:0];  // the driver crashed here
        [encoder setBuffer:bb offset:0 atIndex:1];
        __unsafe_unretained id<MTLBuffer> pair[2] = {nil, db};
        const NSUInteger offsets[2] = {0, 0};
        [encoder setBuffers:pair offsets:offsets withRange:NSMakeRange(2, 2)];  // and here
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        [enc setBuffer:slots offset:0 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc useResource:bb usage:MTLResourceUsageRead];
        [enc useResource:db usage:MTLResourceUsageRead];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const float *got = out.contents;
        if (got[0] != 42 || got[1] != 7)
            return FAIL(bug, "%s: slots 1 and 3 read %g and %g, want 42 and 7", dev.name.UTF8String, got[0], got[1]);
        return PASS(bug, "%s: nil buffers encoded into argument buffer slots 0 and 2, slots 1 and 3 read right", dev.name.UTF8String);
    }
}
