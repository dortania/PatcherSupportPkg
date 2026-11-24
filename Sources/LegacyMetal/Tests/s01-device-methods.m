// s01-device-methods: MTLDevice methods from the macOS 13.3-15 SDKs must exist; MetalOld lacked them and apps died with
// "unrecognized selector" (Blender). Fix: MetalOldCompat item 1.
// Checks: the methods called in a child process. Argument: GPU name.
#import "repro.h"

static int child(int argc, char **argv) {
    for (id<MTLDevice> dev in MTLCopyAllDevices()) {
        if (argc > 1 && strcmp(argv[1], "--child") && [dev.name rangeOfString:@(argv[1]) options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        dev.shouldMaximizeConcurrentCompilation = YES;                         // macOS 13.3
        (void)dev.shouldMaximizeConcurrentCompilation;
        (void)dev.maximumConcurrentCompilationTaskCount;                       // macOS 13.3
        NSError *err = nil;
        if (@available(macOS 15.0, *)) {                                       // macOS 15: may fail, must not crash
            (void)[dev newLogStateWithDescriptor:[MTLLogStateDescriptor new] error:&err];
            (void)[dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&err];
        }
        if (![dev newLibraryWithSource:@"kernel void k(device float *x [[buffer(0)]]) { x[0] = 1; }" options:nil error:&err]) {
            fprintf(stderr, "compile after setting it failed: %s\n", err.localizedDescription.UTF8String);
            return 3;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (reproChildMode(argc, argv)) return child(argc, argv);
        int status = reproRunChild(argc, argv, "calls");
        if (status == 0) return PASS("s01-device-methods", "shouldMaximizeConcurrentCompilation, maximumConcurrentCompilationTaskCount, newLogState/newResidencySet answered");
        return FAIL("s01-device-methods", "calling macOS 13.3+ MTLDevice methods: %s", reproChildStatus(status));
    }
}
