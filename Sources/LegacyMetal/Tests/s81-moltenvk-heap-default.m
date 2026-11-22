// s81-moltenvk-heap-default (MetalOldCompat item 74): MoltenVK 1.4.0 and 1.4.1 take every Mac GPU for a family-2 one and
// put Vulkan memory into placement heaps, which MetalOld refuses on the family-1 GPUs by aborting the app (Godot 4.7 on
// the GTX 770: "Placement heap type is not supported"). The shim sets MVK_CONFIG_USE_MTLHEAP=0 unless the environment
// has it. Checked: once Metal is loaded the setting is 0, and on a family-1 GPU a placement heap is indeed unavailable
// (MetalOld would abort on one, so this only checks the family, not the heap).
// Stock: FAIL (not set). Fixed: PASS. Argument: GPU name substring (default: the system default GPU).
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
