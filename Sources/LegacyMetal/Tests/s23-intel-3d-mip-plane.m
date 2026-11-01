// s23-intel-3d-mip-plane (shim item 23): rendering into one depth plane of a 3D texture's mip level 1 or higher on the
// 12.x Intel driver. A pass on plane 0 also writes plane 1, and one on plane 1 writes neither (clears and draws, also
// through views; WebGPU CTS 3d_texture_slices with mip levels). Level 0 and blits are right. A zeroed 3D texture
// (R8Unorm and BGRA8Unorm, 8x8x4 with 2 levels) is cleared one plane at a time at level 1, and each time only that
// plane may change.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s23-intel-3d-mip-plane";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        const struct { MTLPixelFormat format; const char *name; int bytes; } formats[] = {
            {MTLPixelFormatR8Unorm, "R8Unorm", 1}, {MTLPixelFormatBGRA8Unorm, "BGRA8Unorm", 4}};
        char first[160] = "";
        int bad = 0;
        for (int f = 0; f < 2; f++)
            for (int plane = 0; plane < 2; plane++) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor new];
                td.textureType = MTLTextureType3D;
                td.pixelFormat = formats[f].format;
                td.width = td.height = 8;
                td.depth = 4;
                td.mipmapLevelCount = 2;
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModeManaged;
                id<MTLTexture> t = [dev newTextureWithDescriptor:td];
                NSMutableData *zero = [NSMutableData dataWithLength:8 * 8 * 4 * formats[f].bytes];
                for (int level = 0; level < 2; level++) {
                    int w = 8 >> level, d = 4 >> level;
                    [t replaceRegion:MTLRegionMake3D(0, 0, 0, w, w, d) mipmapLevel:level slice:0 withBytes:zero.bytes
                         bytesPerRow:w * formats[f].bytes bytesPerImage:w * w * formats[f].bytes];
                }
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = t;
                pass.colorAttachments[0].level = 1;
                pass.colorAttachments[0].depthPlane = plane;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b synchronizeResource:t];
                [b endEncoding];
                reproRun(cb);
                uint8_t px[4 * 4 * 2 * 4];  // level 1: 4x4x2
                int planeBytes = 4 * 4 * formats[f].bytes;
                [t getBytes:px bytesPerRow:4 * formats[f].bytes bytesPerImage:planeBytes fromRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 2)
                    mipmapLevel:1 slice:0];
                int cleared = 0, other = 0;
                for (int i = 0; i < planeBytes; i++) {
                    cleared += px[plane * planeBytes + i] == 0xff;
                    other += px[(1 - plane) * planeBytes + i] != 0;
                }
                if (cleared != planeBytes || other) {
                    if (!bad++)
                        snprintf(first, sizeof first, "%s level 1 plane %d: %d/%d bytes of the plane cleared, %d bytes of the other plane changed",
                                 formats[f].name, plane, cleared, planeBytes, other);
                }
            }
        if (bad) return FAIL(bug, "%s: %d of 4 clears hit the wrong planes (e.g. %s)", dev.name.UTF8String, bad, first);
        return PASS(bug, "%s: clears of each depth plane of level 1 change exactly that plane (R8Unorm, BGRA8Unorm)", dev.name.UTF8String);
    }
}
