// s92-kepler-moltenvk-argument-buffers: on a Mac with the Kepler driver, MoltenVK must not use Metal argument buffers
// by default; with them the driver failed Godot's Mobile-renderer command buffers (Invalid Resource: the device was
// lost, glow on, as in its editor). Fix: MetalOldCompat item 89. Checks: MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS is 0
// once Metal loads. SKIP on Macs without the Kepler driver, as item 89 then does nothing. Argument: GPU name (default:
// NVIDIA).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s92-kepler-moltenvk-argument-buffers";
        id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");  // loads Metal and the shim
        if (!dev) return SKIP(bug, "no such GPU");
        if (access("/System/Library/Extensions/GeForceMTLDriver.bundle/Contents/MacOS/GeForceMTLDriver", F_OK))
            return SKIP(bug, "%s: no Kepler driver on this Mac (item 89 needs it)", dev.name.UTF8String);
        const char *value = getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS");
        if (!value || strcmp(value, "0"))
            return FAIL(bug, "%s: MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS is %s, want 0", dev.name.UTF8String, value ? value : "unset");
        return PASS(bug, "%s: MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0, so MoltenVK binds resources directly", dev.name.UTF8String);
    }
}
