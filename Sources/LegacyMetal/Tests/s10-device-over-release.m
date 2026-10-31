// s10-device-over-release (MetalOldCompat item 10): a client releases an MTLDevice once more than it retained it
// (Chromium's GPU process does, in ANGLE's default-device check). Apple's Metal tolerates that; MetalOld frees the
// device while its device list still points to it, and the next MTLCopyAllDevices copies the freed object: the GPU
// process crashes and Chrome falls back to software. The child runs with MallocScribble so the use-after-free is
// deterministic.
// Stock OCLP: FAIL (child crashes). Fixed: PASS. No arguments.
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
    setenv("MallocScribble", "1", 1);
    int status = reproRunChild(argc, argv, "release");
    if (status == 0) return PASS("s10-device-over-release", "devices still valid after an over-release");
    return FAIL("s10-device-over-release", "MTLCopyAllDevices after an over-release: %s", status == 8 ? "device without a name" : reproChildStatus(status));
}
