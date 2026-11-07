// s42-shim-owned-returns (MetalOldCompat): the shim's replacements for new- and init-family methods must hand back an
// owned object, as the methods they replace do. Annotated wrongly, ARC autoreleases what they return, and every texture,
// view or MTLCompileOptions made through them then lives until an autorelease pool drains, never in a process that drains
// none: dawn.node's WebGPU CTS image_copy had 15000 textures alive after 25 s and ran out of memory. Makes each kind of
// object through the paths the shim hooks (a plain texture, a depth texture with mip levels (item 22), a multisampled
// Stencil8 texture (item 36), texture views with and without a range, a view with a swizzle (item 32), MTLCompileOptions)
// and checks through a weak reference that it is freed as soon as it is released, with no pool drained in between.
// Passes on any stack that doesn't defer these releases (the no-op shim too). Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    const char *bug = "s42-shim-owned-returns";
    id<MTLDevice> dev;
    @autoreleasepool {
        dev = reproDevice(argc, argv, "Intel");
    }
    if (!dev) return SKIP(bug, "no such GPU");
    __weak id weak = nil;
    const char *kept = NULL;
#define CHECK(what, make) do { { id object = (make); weak = object; } if (weak) { kept = what; goto done; } } while (0)
    MTLTextureDescriptor *plain = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    plain.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    MTLTextureDescriptor *depth = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:YES];
    depth.storageMode = MTLStorageModePrivate;
    MTLTextureDescriptor *stencil = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:16 height:16 mipmapped:NO];
    stencil.textureType = MTLTextureType2DMultisample;
    stencil.sampleCount = 4;
    stencil.storageMode = MTLStorageModePrivate;
    stencil.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> base = [dev newTextureWithDescriptor:plain];
    CHECK("texture", [dev newTextureWithDescriptor:plain]);
    CHECK("depth texture with mip levels", [dev newTextureWithDescriptor:depth]);
    CHECK("multisampled Stencil8 texture", [dev newTextureWithDescriptor:stencil]);
    CHECK("texture view", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]);
    CHECK("texture view with a range", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                                     levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)]);
    MTLTextureSwizzleChannels identity = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    CHECK("texture view with a swizzle", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                                      levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1) swizzle:identity]);
    CHECK("MTLCompileOptions", [MTLCompileOptions new]);
done:
    if (kept) return FAIL(bug, "%s: a %s was still alive after its last release (deferred to an autorelease pool)", dev.name.UTF8String, kept);
    return PASS(bug, "%s: textures, views and compile options are freed when released, with no autorelease pool drained", dev.name.UTF8String);
}
