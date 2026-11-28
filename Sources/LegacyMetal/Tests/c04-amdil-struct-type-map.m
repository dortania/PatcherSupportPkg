// c04-amdil-struct-type-map: freeing a struct type must drop its own entry from libAMDIL902's struct map; a stale one
// crashed MTLCompilerService at random (Chrome's WebGPU CTS). Fix: the libAMDIL902 patch 5.
// Checks: an in-process compile of two buffers sharing a struct, then what's left in the map. Argument: GPU name.
#import "repro.h"
#include <libgen.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/stat.h>

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct S { int a; int b; array<int, 4> c; };\n"
    "struct A { S x; S y; };\n"
    "struct B { array<int, 4> z; S y; };\n"
    "kernel void k(constant A *a [[buffer(0)]], device B *b [[buffer(1)]]) { b->z[0] = a->x.a + a->y.c[1] + %d; b->y.b = a->y.a; }\n";

// The map's size in the libAMDIL902 loaded here, from its stock build's addresses. NULL: not loaded, or another build.
static const long *mapSize(void) {
    static const uint8_t stockUUID[16] = {0xd5, 0xcf, 0x00, 0x07, 0x89, 0x35, 0x31, 0x93, 0xb3, 0xf1, 0xd0, 0xb3, 0xdd, 0x0d, 0xcc, 0x91};
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!strstr(_dyld_get_image_name(i), "libAMDIL902")) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++, command = (const void *)((const char *)command + command->cmdsize))
            if (command->cmd == LC_UUID && !memcmp(((const struct uuid_command *)command)->uuid, stockUUID, 16))
                return (const long *)((const char *)header + (0x4FFA433FA378 - 0x4FFA0D370000));
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "c04-amdil-struct-type-map";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithFormat:src, getpid()] options:nil error:&err];
        if (!lib) return FAIL(bug, "front end: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        const long *size = mapSize();
        if (!size) {
            if (reproChildMode(argc, argv)) return SKIP(bug, "this libAMDIL902 isn't in the process, or isn't the 12.5 build");
            char self[1024], loader[1100];
            strlcpy(self, argv[0], sizeof self);
            snprintf(loader, sizeof loader, "%s/../tools/localcc.dylib", dirname(self));
            struct stat st;
            if (stat(loader, &st)) return SKIP(bug, "needs tools/localcc.dylib (build.sh builds it)");
            setenv("DYLD_INSERT_LIBRARIES", loader, 1);
            int status = reproRunChild(argc, argv, "in-process");
            if (status == 0 || status == 1 || status == 77) return status;
            // The service just compiled this shader, so the bug isn't what stopped it (the compiler can't run in a process on Tahoe).
            return SKIP(bug, "the compiler doesn't run in this process: %s", reproChildStatus(status));
        }
        if (*size) return FAIL(bug, "%s: %ld entries left in the struct type map after a compile", dev.name.UTF8String, *size);
        return PASS(bug, "%s: nothing left in the struct type map after a compile", dev.name.UTF8String);
    }
}
