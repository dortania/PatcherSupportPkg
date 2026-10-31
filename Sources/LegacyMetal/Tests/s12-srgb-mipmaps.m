// s12-srgb-mipmaps (MetalOldCompat item 12): -[MTLBlitCommandEncoder generateMipmapsForTexture:] on an RGBA8Unorm_sRGB
// texture with the 12.5 AMD driver. The driver averages the sRGB-encoded bytes instead of the linear values, so every
// level below 0 is too dark (WebGL 2 conformance: conformance2/textures/misc/tex-srgb-mipmap). Level 0 is a
// black/white checkerboard: the correct level 1 is linear 0.5 = sRGB byte 188; averaging the bytes gives 128.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s12-srgb-mipmaps";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:16 height:16 mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;  // as WebGL textures are created
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        uint8_t px[16 * 16 * 4];
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
            uint8_t v = ((x ^ y) & 1) ? 255 : 0;
            uint8_t *p = px + (y * 16 + x) * 4;
            p[0] = p[1] = p[2] = v; p[3] = 255;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:px bytesPerRow:64];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b generateMipmapsForTexture:t];
        [b synchronizeResource:t];
        [b endEncoding];
        reproRun(cb);
        uint8_t level1[8 * 8 * 4];
        [t getBytes:level1 bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:1];
        int r = level1[(3 * 8 + 3) * 4];
        if (abs(r - 188) > 3) return FAIL(bug, "%s: level 1 of a black/white sRGB checkerboard = %d, want 188 (128 = encoded bytes averaged)", dev.name.UTF8String, r);
        return PASS(bug, "%s: sRGB mip level 1 = %d (linear average)", dev.name.UTF8String, r);
    }
}
