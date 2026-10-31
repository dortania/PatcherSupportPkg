// s03-shader-atomic-usage (MetalOldCompat item 3): MTLTextureUsageShaderAtomic (macOS 14) in a texture descriptor.
// MetalOld predates it and rejects the descriptor in its texture validation; apps that ask for texture atomics
// (Blender EEVEE's shadow and volume textures) can't create their textures.
// Stock OCLP: FAIL (child aborted / nil texture). Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static int child(int argc, char **argv) {
    id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageShaderAtomic;
    td.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:td] ? 0 : 5;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (reproChildMode(argc, argv)) return child(argc, argv);
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP("s03-shader-atomic-usage", "no such GPU");
        int status = reproRunChild(argc, argv, "texture");
        if (status == 0) return PASS("s03-shader-atomic-usage", "%s: texture with MTLTextureUsageShaderAtomic created", dev.name.UTF8String);
        return FAIL("s03-shader-atomic-usage", "%s: %s", dev.name.UTF8String, status == 5 ? "newTextureWithDescriptor returned nil" : reproChildStatus(status));
    }
}
