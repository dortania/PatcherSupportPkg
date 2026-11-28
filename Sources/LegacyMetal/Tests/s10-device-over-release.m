// s10-device-over-release: an MTLDevice released once too often (Chromium's GPU process) must survive; MetalOld freed
// it and the next MTLCopyAllDevices crashed. Fix: MetalOldCompat item 10.
// Checks: the over-release, in a child with MallocScribble.
#import "repro.h"

static int child(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CFRelease((__bridge CFTypeRef)dev);  // the over-release
    }
    @autoreleasepool {
        for (int round = 0; round < 3; round++)
            for (id<MTLDevice> d in MTLCopyAllDevices()) if (!d.name.length) return 8;
        if (!MTLCreateSystemDefaultDevice().name.length) return 8;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (reproChildMode(argc, argv)) return child();
    if (!reproOnMetalOld()) return SKIP("s10-device-over-release", "MetalOldCompat needs OCLP's MetalOld wrapper");
    setenv("MallocScribble", "1", 1);
    int status = reproRunChild(argc, argv, "release");
    if (status == 0) return PASS("s10-device-over-release", "devices still valid after an over-release");
    return FAIL("s10-device-over-release", "MTLCopyAllDevices after an over-release: %s", status == 8 ? "device without a name" : reproChildStatus(status));
}
