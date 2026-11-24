// s70-intel-depth-array-level-blits: blits at levels 1+ of mipmapped depth arrays and cubes must touch only their
// texels; Ivy Bridge garbled other slices. Fix: MetalOldCompat item 63 MTLSHIM_DEPTH_LEVEL_BLITS. Checks: a cube array
// and a 2D array: copies out and in, every texel read back; fence-ordered copies. Argument: GPU name.
#import "repro.h"
#include <math.h>

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct P { uint width, slice, level, at; };\n"
    "kernel void readCubeArray(depthcube_array<float> t [[texture(0)]], device float *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint w = p.width >> p.level; if (g.x < w && g.y < w) o[p.at + g.y * w + g.x] = t.read(g, p.slice % 6u, p.slice / 6u, p.level);\n"
    "}\n"
    "kernel void readArray(depth2d_array<float> t [[texture(0)]], device float *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint w = p.width >> p.level; if (g.x < w && g.y < w) o[p.at + g.y * w + g.x] = t.read(g, p.slice, p.level);\n"
    "}\n"
    "kernel void read2D(depth2d<float> t [[texture(0)]], device float *o [[buffer(0)]], constant P &p [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint w = p.width; if (g.x < w && g.y < w) o[p.at + g.y * w + g.x] = t.read(g);\n"
    "}\n";

enum { W = 64, LEVELS = 3 };
// Each level and slice's depth: exact in a float with few mantissa bits (render-pass clears of others can be off on Ivy
// Bridge, a known limitation) and spaced wider than Depth16Unorm's step
static float depthOf(int level, int slice) { return 0.0625f + 0.25f * level + 0.015625f * slice; }
static float stored(float v, BOOL sixteen) { return sixteen ? (float)lrintf(v * 65535.0f) / 65535.0f : v; }
static BOOL same(float got, float want, BOOL sixteen) { return sixteen ? fabsf(got - want) <= 1.5f / 65535.0f : got == want; }

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s70-intel-depth-array-level-blits";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    struct { MTLTextureType type; MTLPixelFormat format; int slices; const char *what, *reader; } kinds[] = {
        {MTLTextureTypeCubeArray, MTLPixelFormatDepth32Float, 12, "Depth32Float cube array", "readCubeArray"},
        {MTLTextureType2DArray, MTLPixelFormatDepth16Unorm, 6, "Depth16Unorm 2D array", "readArray"}};
    for (int k = 0; k < 2; k++) {
        BOOL sixteen = kinds[k].format == MTLPixelFormatDepth16Unorm;
        NSUInteger bpp = sixteen ? 2 : 4;
        const char *what = kinds[k].what;
        int slices = kinds[k].slices;
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = kinds[k].type;
        td.pixelFormat = kinds[k].format;
        td.width = td.height = W;
        td.mipmapLevelCount = LEVELS;
        td.arrayLength = kinds[k].type == MTLTextureTypeCubeArray ? slices / 6 : slices;
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *d2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kinds[k].format width:W >> 2 height:W >> 2 mipmapped:NO];
        d2.storageMode = MTLStorageModePrivate;
        d2.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> flat = [dev newTextureWithDescriptor:d2];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.depthAttachment.texture = tex;
                rp.depthAttachment.level = level;
                rp.depthAttachment.slice = slice;
                rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.storeAction = MTLStoreActionStore;
                rp.depthAttachment.clearDepth = depthOf(level, slice);
                rp.renderTargetWidth = rp.renderTargetHeight = W >> level;
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = flat;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.depthAttachment.clearDepth = 1.0;
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: clearing failed", name, what);

        // the blits: level 1 slice 3 and level 2 slice 4 (whole) into buffers at padded rows, a 4x4 patch into level 1
        // slice 5 at (8, 4), level 2 slice 1 into the 2D texture
        const int outLevel[2] = {1, 2}, outSlice[2] = {3, 4};
        const NSUInteger rowPad = 64;
        id<MTLBuffer> outs[2];
        id<MTLBuffer> patch = [dev newBufferWithLength:16 * 4 options:MTLResourceStorageModeShared];
        const float patchDepth = 0.875f;
        for (int i = 0; i < 16; i++) {
            if (sixteen) ((uint16_t *)patch.contents)[i] = (uint16_t)lrintf(patchDepth * 65535.0f);
            else ((float *)patch.contents)[i] = patchDepth;
        }
        cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        for (int i = 0; i < 2; i++) {
            NSUInteger w = W >> outLevel[i];
            outs[i] = [dev newBufferWithLength:(w * bpp + rowPad) * w + 256 options:MTLResourceStorageModeShared];
            memset(outs[i].contents, 0xab, outs[i].length);
            [be copyFromTexture:tex sourceSlice:outSlice[i] sourceLevel:outLevel[i] sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1)
                       toBuffer:outs[i] destinationOffset:256 destinationBytesPerRow:w * bpp + rowPad destinationBytesPerImage:(w * bpp + rowPad) * w];
        }
        [be copyFromBuffer:patch sourceOffset:0 sourceBytesPerRow:4 * bpp sourceBytesPerImage:16 * bpp sourceSize:MTLSizeMake(4, 4, 1)
                 toTexture:tex destinationSlice:5 destinationLevel:1 destinationOrigin:MTLOriginMake(8, 4, 0)];
        [be copyFromTexture:tex sourceSlice:1 sourceLevel:2 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W >> 2, W >> 2, 1)
                  toTexture:flat destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        // what follows the copies in the same encoder
        id<MTLBuffer> mirror = [dev newBufferWithLength:outs[0].length options:MTLResourceStorageModeShared];
        [be copyFromBuffer:outs[0] sourceOffset:0 toBuffer:mirror destinationOffset:0 size:outs[0].length];
        id<MTLBuffer> patchBack = [dev newBufferWithLength:16 * 4 options:MTLResourceStorageModeShared];
        [be copyFromTexture:tex sourceSlice:5 sourceLevel:1 sourceOrigin:MTLOriginMake(8, 4, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:patchBack
          destinationOffset:0 destinationBytesPerRow:4 * bpp destinationBytesPerImage:16 * bpp];
        NSUInteger mw = W >> 2;
        id<MTLBuffer> managed = [dev newBufferWithLength:mw * mw * bpp options:MTLResourceStorageModeManaged];
        [be copyFromTexture:tex sourceSlice:slices - 1 sourceLevel:2 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(mw, mw, 1) toBuffer:managed
          destinationOffset:0 destinationBytesPerRow:mw * bpp destinationBytesPerImage:mw * mw * bpp];
        [be synchronizeResource:managed];
        [be endEncoding];

        // then every texel by a compute kernel
        NSUInteger perSlice = 0;
        for (int level = 0; level < LEVELS; level++) perSlice += (W >> level) * (W >> level);
        id<MTLBuffer> texels = [dev newBufferWithLength:(perSlice * slices + (W >> 2) * (W >> 2)) * 4 options:MTLResourceStorageModeShared];
        id<MTLComputePipelineState> reader = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kinds[k].reader)] error:&err];
        id<MTLComputePipelineState> reader2D = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read2D"] error:&err];
        if (!reader || !reader2D) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:reader];
        [ce setTexture:tex atIndex:0];
        [ce setBuffer:texels offset:0 atIndex:0];
        NSUInteger at = 0;
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                uint32_t p[4] = {W, (uint32_t)slice, (uint32_t)level, (uint32_t)at};
                [ce setBytes:p length:sizeof p atIndex:1];
                [ce dispatchThreadgroups:MTLSizeMake(((W >> level) + 7) / 8, ((W >> level) + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                at += (W >> level) * (W >> level);
            }
        [ce setComputePipelineState:reader2D];
        [ce setTexture:flat atIndex:0];
        uint32_t p2[4] = {W >> 2, 0, 0, (uint32_t)at};
        [ce setBytes:p2 length:sizeof p2 atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, what);

        for (int i = 0; i < 2; i++) {
            NSUInteger w = W >> outLevel[i];
            float want = stored(depthOf(outLevel[i], outSlice[i]), sixteen);
            for (NSUInteger y = 0; y < w; y++)
                for (NSUInteger x = 0; x < w; x++) {
                    const char *texel = (const char *)outs[i].contents + 256 + y * (w * bpp + rowPad) + x * bpp;
                    float got = sixteen ? *(const uint16_t *)texel / 65535.0f : *(const float *)texel;
                    if (!same(got, want, sixteen))
                        return FAIL(bug, "%s: %s: level %d slice %d copied into a buffer: texel (%lu, %lu) is %.7g, want %.7g", name, what,
                                    outLevel[i], outSlice[i], (unsigned long)x, (unsigned long)y, got, want);
                }
        }
        for (NSUInteger i = 0; i < outs[0].length; i++)
            if (((const uint8_t *)mirror.contents)[i] != ((const uint8_t *)outs[0].contents)[i])
                return FAIL(bug, "%s: %s: a buffer copy after the read-back of level 1 in the same encoder saw byte %lu as %02x, the read-back wrote %02x",
                            name, what, (unsigned long)i, ((const uint8_t *)mirror.contents)[i], ((const uint8_t *)outs[0].contents)[i]);
        for (int i = 0; i < 16; i++) {
            float got = sixteen ? ((const uint16_t *)patchBack.contents)[i] / 65535.0f : ((const float *)patchBack.contents)[i];
            if (!same(got, stored(patchDepth, sixteen), sixteen))
                return FAIL(bug, "%s: %s: the patch copied back out of level 1 in the same encoder: texel %d is %.7g, want %.7g", name, what, i, got,
                            stored(patchDepth, sixteen));
        }
        for (NSUInteger i = 0; i < mw * mw; i++) {
            float got = sixteen ? ((const uint16_t *)managed.contents)[i] / 65535.0f : ((const float *)managed.contents)[i];
            if (!same(got, stored(depthOf(2, slices - 1), sixteen), sixteen))
                return FAIL(bug, "%s: %s: level 2 slice %d read back into a managed buffer and synchronized: texel %lu is %.7g, want %.7g", name, what,
                            slices - 1, (unsigned long)i, got, stored(depthOf(2, slices - 1), sixteen));
        }
        // the fence: an untracked buffer, so nothing but the fence orders the second encoder after the copy
        {
            NSUInteger w1 = W >> 1, length = w1 * w1 * bpp;
            id<MTLFence> fence = [dev newFence];
            id<MTLBuffer> untracked = [dev newBufferWithLength:length options:MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked];
            id<MTLBuffer> fenced = [dev newBufferWithLength:length options:MTLResourceStorageModeShared];
            memset(fenced.contents, 0xab, length);
            id<MTLCommandBuffer> fb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> first = [fb blitCommandEncoder];
            [first copyFromTexture:tex sourceSlice:2 sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w1, w1, 1) toBuffer:untracked
                 destinationOffset:0 destinationBytesPerRow:w1 * bpp destinationBytesPerImage:length];
            [first updateFence:fence];
            [first endEncoding];
            id<MTLBlitCommandEncoder> second = [fb blitCommandEncoder];
            [second waitForFence:fence];
            [second copyFromBuffer:untracked sourceOffset:0 toBuffer:fenced destinationOffset:0 size:length];
            [second endEncoding];
            if (!reproRun(fb)) return FAIL(bug, "%s: %s: the fence command buffer failed", name, what);
            float want1 = stored(depthOf(1, 2), sixteen);
            for (NSUInteger i = 0; i < w1 * w1; i++) {
                float got = sixteen ? ((const uint16_t *)fenced.contents)[i] / 65535.0f : ((const float *)fenced.contents)[i];
                if (!same(got, want1, sixteen))
                    return FAIL(bug, "%s: %s: level 1 slice 2 read back before updateFence:, copied on after waitForFence:: texel %lu is %.7g, want %.7g",
                                name, what, (unsigned long)i, got, want1);
            }
        }
        const float *t = texels.contents;
        at = 0;
        for (int level = 0; level < LEVELS; level++)
            for (int slice = 0; slice < slices; slice++) {
                NSUInteger w = W >> level;
                for (NSUInteger y = 0; y < w; y++)
                    for (NSUInteger x = 0; x < w; x++) {
                        BOOL patched = level == 1 && slice == 5 && x >= 8 && x < 12 && y >= 4 && y < 8;
                        float want = stored(patched ? patchDepth : depthOf(level, slice), sixteen), got = t[at + y * w + x];
                        if (!same(got, want, sixteen))
                            return FAIL(bug, "%s: %s after the blits: level %d slice %d texel (%lu, %lu) is %.7g, want %.7g", name, what, level, slice,
                                        (unsigned long)x, (unsigned long)y, got, want);
                    }
                at += w * w;
            }
        float want = stored(depthOf(2, 1), sixteen);
        for (int i = 0; i < (W >> 2) * (W >> 2); i++)
            if (!same(t[at + i], want, sixteen))
                return FAIL(bug, "%s: %s: level 2 slice 1 copied into a 2D texture: texel (%d, %d) is %.7g, want %.7g", name, what, i % (W >> 2),
                            i / (W >> 2), t[at + i], want);
    }
    return PASS(bug, "%s: blits out of and into levels 1-2 of mipmapped depth arrays copy the right texels, leave the rest alone and come before what follows them (fences too)", name);
}}
