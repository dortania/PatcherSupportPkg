// s03-shader-atomic-usage: a texture with MTLTextureUsageShaderAtomic must be made; MetalOld's validation rejected it
// (Blender EEVEE). Fix: MetalOldCompat item 3.
// Checks: the texture is created, in a child process. Argument: GPU name.
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
