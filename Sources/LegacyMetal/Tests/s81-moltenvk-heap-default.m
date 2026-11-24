// s81-moltenvk-heap-default: MoltenVK 1.4.0/1.4.1 must not use placement heaps on family-1 GPUs; MetalOld aborted
// (Godot on the GTX 770). Fix: MetalOldCompat item 74.
// Checks: MVK_CONFIG_USE_MTLHEAP is 0 once Metal loads, and family 1 lacks placement heaps. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s81-moltenvk-heap-default";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();  // loads Metal and the shim
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        BOOL familyTwo = [dev supportsFamily:MTLGPUFamilyMac2];
        const char *value = getenv("MVK_CONFIG_USE_MTLHEAP");
        if (!value || strcmp(value, "0"))
            return FAIL(bug, "%s (Metal family %d): MVK_CONFIG_USE_MTLHEAP is %s, want 0", name, familyTwo ? 2 : 1, value ? value : "unset");
        return PASS(bug, "%s (Metal family %d): MVK_CONFIG_USE_MTLHEAP=0, so MoltenVK makes no placement heaps", name, familyTwo ? 2 : 1);
    }
}
