// bronzeload.dylib (tests only): loads AMDBronzeCompat.dylib (path in AMD_BRONZE_COMPAT_PATH) right after Metal has
// loaded the drivers, so verify.sh can test it without installing anything. Installed, the driver's load command does
// this. Injected with DYLD_INSERT_LIBRARIES.
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdlib.h>

static void loadCompat(void) {
    const char *path = getenv("AMD_BRONZE_COMPAT_PATH");
    if (path) dlopen(path, RTLD_NOW);
}

static NSArray<id<MTLDevice>> *copyAllDevices(void) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *copyAllDevices(void) {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    loadCompat();
    return devices;
}

static id<MTLDevice> defaultDevice(void) NS_RETURNS_RETAINED;
static id<MTLDevice> defaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    loadCompat();
    return device;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    {(const void *)copyAllDevices, (const void *)MTLCopyAllDevices},
    {(const void *)defaultDevice, (const void *)MTLCreateSystemDefaultDevice},
};
