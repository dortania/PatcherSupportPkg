// n17-kepler-bc-edge-upload: an upload into a BC texture's last, partial row of blocks must land; Kepler wrote nothing.
// Fix: MetalOldCompat item 67. Checks: the edge row, the corner and a 7x3 level, BC1 and BC3, against a full readback.
// Argument: GPU name (default: NVIDIA).
#import "repro.h"

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n17-kepler-bc-edge-upload";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    if (![dev supportsBCTextureCompression]) return SKIP(bug, "%s: no BC texture compression", dev.name.UTF8String);
    const char *name = dev.name.UTF8String;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { MTLPixelFormat format; NSUInteger block; const char *what; } formats[] = {{MTLPixelFormatBC1_RGBA, 8, "BC1"}, {MTLPixelFormatBC3_RGBA, 16, "BC3"}};
    struct { NSUInteger w, h; MTLOrigin origin; MTLSize size; const char *what; } cases[] = {
        {13, 13, {0, 12, 0}, {13, 1, 1}, "13x13 level, edge row 13x1 at y 12"},
        {13, 13, {12, 12, 0}, {1, 1, 1}, "13x13 level, edge corner 1x1 at (12, 12)"},
        {13, 13, {0, 12, 0}, {12, 1, 1}, "13x13 level, 12x1 at y 12"},
        {7, 3, {0, 0, 0}, {7, 3, 1}, "7x3 level, the whole of it"}};
    for (int f = 0; f < 2; f++)
        for (int c = 0; c < 4; c++) {
            NSUInteger bb = formats[f].block, bw = (cases[c].w + 3) / 4, bh = (cases[c].h + 3) / 4, row = bw * bb;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[f].format width:cases[c].w height:cases[c].h mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            // first the whole level with blocks A, then the region with blocks B (different bytes everywhere)
            id<MTLBuffer> a = [dev newBufferWithLength:row * bh options:MTLResourceStorageModeShared];
            for (NSUInteger i = 0; i < row * bh; i++) ((uint8_t *)a.contents)[i] = (uint8_t)(i * 7 + 1 + 40 * f + 9 * c);
            MTLOrigin o = cases[c].origin;
            MTLSize s = cases[c].size;
            NSUInteger rbx = o.x / 4, rby = o.y / 4, rbw = (s.width + 3) / 4, rbh = (s.height + 3) / 4, rrow = rbw * bb;
            id<MTLBuffer> b = [dev newBufferWithLength:rrow * rbh options:MTLResourceStorageModeShared];
            for (NSUInteger i = 0; i < rrow * rbh; i++) ((uint8_t *)b.contents)[i] = (uint8_t)(~(i * 7 + 1 + 40 * f + 9 * c) ^ 0x5a);
            id<MTLBuffer> back = [dev newBufferWithLength:row * bh options:MTLResourceStorageModeShared];
            memset(back.contents, 0, back.length);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:a sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:0 sourceSize:MTLSizeMake(cases[c].w, cases[c].h, 1)
                     toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];
            be = [cb blitCommandEncoder];
            [be copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:rrow sourceBytesPerImage:0 sourceSize:s toTexture:tex destinationSlice:0 destinationLevel:0
             destinationOrigin:o];
            [be endEncoding];
            be = [cb blitCommandEncoder];
            [be copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(cases[c].w, cases[c].h, 1)
                       toBuffer:back destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * bh];
            [be endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, formats[f].what);
            for (NSUInteger by = 0; by < bh; by++)
                for (NSUInteger bx = 0; bx < bw; bx++) {
                    BOOL inRegion = bx >= rbx && bx < rbx + rbw && by >= rby && by < rby + rbh;
                    const uint8_t *want = inRegion ? (const uint8_t *)b.contents + (by - rby) * rrow + (bx - rbx) * bb : (const uint8_t *)a.contents + by * row + bx * bb;
                    if (memcmp((const uint8_t *)back.contents + by * row + bx * bb, want, bb))
                        return FAIL(bug, "%s: %s %s: block (%lu, %lu) %s", name, formats[f].what, cases[c].what, (unsigned long)bx, (unsigned long)by,
                                    inRegion ? "kept its old contents: the upload into it didn't land" : "changed, outside the upload");
                }
        }
    return PASS(bug, "%s: uploads into BC edge rows and corners short of a whole block (BC1, BC3) land, and nothing else changes", name);
}}
