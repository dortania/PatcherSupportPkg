// s24-intel-narrow-mip-clear: R8Unorm / RG8Unorm clears at level 1+, and some BGRA8 ones at level 2+, must land; the
// 12.x Intel driver skipped them. Fix: MetalOldCompat item 24.
// Checks: 32x32 R8/RG8 textures cleared at levels 1-3, a 40x40 BGRA8Unorm(_sRGB) at level 2+. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s24-intel-narrow-mip-clear";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        const struct { MTLPixelFormat format; const char *name; int bytes, size; } formats[] = {
            {MTLPixelFormatR8Unorm, "R8Unorm", 1, 32}, {MTLPixelFormatRG8Unorm, "RG8Unorm", 2, 32},
            {MTLPixelFormatBGRA8Unorm, "BGRA8Unorm 40x40", 4, 40}, {MTLPixelFormatBGRA8Unorm_sRGB, "BGRA8Unorm_sRGB 40x40", 4, 40}};
        char first[128] = "";
        int bad = 0, cases = 0;
        for (int f = 0; f < 4; f++)
            for (int level = 1; level <= 3; level++) {
                int size = formats[f].size;
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[f].format width:size height:size mipmapped:YES];
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModeManaged;
                id<MTLTexture> t = [dev newTextureWithDescriptor:td];
                NSMutableData *ones = [NSMutableData dataWithLength:size * size * 4];
                memset(ones.mutableBytes, 0xff, ones.length);
                for (NSUInteger l = 0; l < t.mipmapLevelCount; l++) {
                    NSUInteger w = MAX((NSUInteger)size >> l, 1u);
                    [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l withBytes:ones.bytes bytesPerRow:w * formats[f].bytes];
                }
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = t;
                pass.colorAttachments[0].level = level;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b synchronizeResource:t];
                [b endEncoding];
                reproRun(cb);
                int w = size >> level, n = w * w * formats[f].bytes, stale = 0;
                uint8_t px[20 * 20 * 4];
                [t getBytes:px bytesPerRow:w * formats[f].bytes fromRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:level];
                for (int i = 0; i < n; i++) stale += px[i] != 0;
                cases++;
                if (stale && !bad++)
                    snprintf(first, sizeof first, "%s level %d: %d of %d bytes not cleared", formats[f].name, level, stale, n);
            }
        if (bad) return FAIL(bug, "%s: %d of %d mip-level clears incomplete (e.g. %s)", dev.name.UTF8String, bad, cases, first);
        return PASS(bug, "%s: R8Unorm, RG8Unorm and 40x40 BGRA8Unorm(_sRGB) clears of levels 1-3 clear every byte", dev.name.UTF8String);
    }
}
