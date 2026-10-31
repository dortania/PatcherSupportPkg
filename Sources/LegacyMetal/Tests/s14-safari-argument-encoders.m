// s14-safari-argument-encoders (MetalOldCompat item 14): OCLP's Metal.framework wrapper (13.2.1-24) replaces
// -[MTLFunction newArgumentEncoderWithBufferIndex:...] and -[MTLDevice newArgumentEncoderWithBufferBinding:] with
// stubs returning nil in every process whose path contains "Safari". WebKit's ANGLE puts every WebGL 2 uniform block in
// an argument buffer, so each such draw fails (GL_OUT_OF_MEMORY, blank canvases). This program copies itself into a
// directory named "Safari" and asks for an argument encoder there (and, as the control, from its own path).
// Stock OCLP: FAIL (nil encoder in the Safari path). Fixed: PASS. Argument: GPU name substring (default: Intel: on the
// AMD GPU the argument-buffer compile itself also needs the libAMDIL902 fix, c01).
#import "repro.h"

static int child(int argc, char **argv) {
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Blocks { constant float4 *block0 [[id(0)]]; constant float4 *block1 [[id(1)]]; };\n"
        "kernel void k(constant Blocks &blocks [[buffer(0)]], device float4 *out [[buffer(1)]]) { out[0] = blocks.block0[0] + blocks.block1[0]; }\n"
        options:nil error:&err];
    if (!lib) return 3;
    id<MTLArgumentEncoder> enc = [[lib newFunctionWithName:@"k"] newArgumentEncoderWithBufferIndex:0];
    return enc && enc.encodedLength > 0 ? 0 : 9;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s14-safari-argument-encoders";
        if (reproChildMode(argc, argv)) return child(argc, argv);
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int control = reproRunChild(argc, argv, "here");
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Safari-s14"];
        NSString *copy = [dir stringByAppendingPathComponent:@"s14-in-Safari"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:copy error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:@(argv[0]) toPath:copy error:nil];
        char *args[] = {(char *)copy.fileSystemRepresentation, argc > 1 ? argv[1] : (char *)"Intel"};
        int safari = reproRunChild(2, args, "safari");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        if (control) return FAIL(bug, "%s: argument encoder failed even outside a Safari path: %s", dev.name.UTF8String, reproChildStatus(control));
        if (safari) return FAIL(bug, "%s: newArgumentEncoderWithBufferIndex: in a process under .../Safari-s14/: %s", dev.name.UTF8String,
                                safari == 9 ? "nil encoder" : reproChildStatus(safari));
        return PASS(bug, "%s: argument encoder created in a process whose path contains \"Safari\"", dev.name.UTF8String);
    }
}
