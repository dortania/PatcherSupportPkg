// s97-haswell-moltenvk-argument-buffers: on a Mac with the Haswell driver, MoltenVK must not use Metal argument buffers
// by default; the driver's emulation lays a struct out by its members' types, so MoltenVK's padding (a texture pad where
// the descriptor set binds a buffer) made a texture slot read a buffer, and Godot's Mobile renderer lost its encoder
// ("-[MTLIGAccelBuffer textureType]: unrecognized selector" in a draw). Fix: MetalOldCompat item 94. Checks:
// MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS is 0 once Metal loads. SKIP on Macs without the Haswell driver, as item 94 then
// does nothing. Argument: GPU name (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s97-haswell-moltenvk-argument-buffers";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");  // loads Metal and the shim
        if (!dev) return SKIP(bug, "no such GPU");
        if (access("/System/Library/Extensions/AppleIntelHD5000GraphicsMTLDriver.bundle/Contents/MacOS/AppleIntelHD5000GraphicsMTLDriver", F_OK))
            return SKIP(bug, "%s: no Haswell driver on this Mac (item 94 needs it)", dev.name.UTF8String);
        const char *value = getenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS");
        if (!value || strcmp(value, "0"))
            return FAIL(bug, "%s: MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS is %s, want 0", dev.name.UTF8String, value ? value : "unset");
        return PASS(bug, "%s: MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0, so MoltenVK binds resources directly", dev.name.UTF8String);
    }
}
