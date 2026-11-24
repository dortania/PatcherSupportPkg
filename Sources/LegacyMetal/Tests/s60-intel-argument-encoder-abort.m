// s60-intel-argument-encoder-abort: asking for an argument encoder on Ivy Bridge must not abort; MetalOld called
// abort() (Safari's GPU process died). Fix: MetalOldCompat item 46 MTLSHIM_ARGUMENT_ENCODER_GUARD, item 47
// MTLSHIM_IVB_ARGUMENT_BUFFERS. Checks: encoders from a function and from descriptors, in a child. Argument: GPU name.
#import "repro.h"

static int child(int argc, char **argv) {
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Blocks { constant float4 *block0 [[id(0)]]; constant float4 *block1 [[id(1)]]; };\n"
        "kernel void k(constant Blocks &blocks [[buffer(0)]], device float4 *out [[buffer(1)]]) { out[0] = blocks.block0[0] + blocks.block1[0]; }\n"
        options:nil error:&err];
    if (!lib) return 3;
    id<MTLArgumentEncoder> fromFunction = [[lib newFunctionWithName:@"k"] newArgumentEncoderWithBufferIndex:0];
    MTLArgumentDescriptor *a = [MTLArgumentDescriptor argumentDescriptor], *b = [MTLArgumentDescriptor argumentDescriptor];
    a.dataType = b.dataType = MTLDataTypePointer;
    a.index = 0;
    b.index = 1;
    id<MTLArgumentEncoder> fromDescriptors = [dev newArgumentEncoderWithArguments:@[a, b]];
    printf("encoders: function %s, descriptors %s\n", fromFunction ? "yes" : "nil", fromDescriptors ? "yes" : "nil");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s60-intel-argument-encoder-abort";
        if (reproChildMode(argc, argv)) return child(argc, argv);
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int status = reproRunChild(argc, argv, "encoders");
        if (status) return FAIL(bug, "%s: asking for an argument encoder: %s", dev.name.UTF8String, reproChildStatus(status));
        return PASS(bug, "%s: argument encoders requested from a function and from descriptors without ending the process",
                    dev.name.UTF8String);
    }
}
