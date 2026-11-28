// s20-intel-fill-buffer: an 8-byte buffer fill at an offset of 4 mod 8 must fill those bytes; the 12.x Intel driver
// filled the 8 bytes below (wgpu's zero-fills). Fix: MetalOldCompat item 20.
// Checks: every 4-aligned offset and length up to 32 in a 64-byte buffer, and the bytes around. Argument: GPU name.
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s20-intel-fill-buffer";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        int wrong = 0, cases = 0;
        char first[96] = "";
        for (int offset = 0; offset <= 28; offset += 4)
            for (int length = 4; length <= 32; length += 4) {
                uint8_t init[64];
                for (int i = 0; i < 64; i++) init[i] = 0x80 | i;
                id<MTLBuffer> b = [dev newBufferWithBytes:init length:64 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
                [e fillBuffer:b range:NSMakeRange(offset, length) value:0];
                [e endEncoding];
                reproRun(cb);
                uint8_t want[64];
                memcpy(want, init, 64);
                memset(want + offset, 0, length);
                cases++;
                if (memcmp(b.contents, want, 64)) {
                    if (!wrong++) {
                        const uint8_t *got = b.contents;
                        int lo = 0, hi = 0;
                        for (int i = 0; i < 64; i++) if (!got[i]) { if (!hi) lo = i; hi = i + 1; }
                        snprintf(first, sizeof first, "offset %d length %d filled bytes %d..%d", offset, length, lo, hi - 1);
                    }
                }
            }
        if (wrong) return FAIL(bug, "%s: %d of %d fills wrong (e.g. %s)", dev.name.UTF8String, wrong, cases, first);
        return PASS(bug, "%s: all %d fills (offsets 0-28, lengths 4-32) hit exactly their range", dev.name.UTF8String, cases);
    }
}
