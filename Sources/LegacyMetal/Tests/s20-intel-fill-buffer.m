// s20-intel-fill-buffer (shim item 20): buffer fills on the 12.x Intel driver. -[MTLIGAccelBlitCommandEncoder
// fillBuffer:range:value:] fills the wrong bytes when the length is exactly 8 and the offset is 4 mod 8: it fills the
// 8-aligned bytes below (offset 4 -> bytes 0..7). wgpu (Firefox's WebGPU) zero-fills buffer tails this way, so a 4-byte
// copy into a 12-byte buffer was wiped (WebGPU CTS clearBuffer, copyBufferToBuffer). Fills every 4-aligned
// offset/length pair up to 32 bytes inside a 64-byte buffer and checks the bytes around them too.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
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
