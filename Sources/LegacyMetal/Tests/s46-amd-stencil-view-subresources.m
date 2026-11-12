// s46-amd-stencil-view-subresources (AMDBronzeCompat item 1): shaders must read the stencil of a depth-stencil texture
// right through X32_Stencil8 / X24_Stencil8 views of any level and slice. The 12.5 AMD driver gives such a view an image
// descriptor whose base address already points past level 0 / slice 0 (from the stencil index it miscounts, plus the
// first slice's offset) while the descriptor's BASE_LEVEL and BASE_ARRAY select the level and slice again: a view of
// level 2 reads level 0's stencil, a view of slice 2 reads somewhere in slice 0 / 1. Dawn backs WebGPU's stencil8 with
// Depth32Float_Stencil8 and reads it through such views.
// Writes a distinct stencil byte per texel, level and slice with blits into 2D-array textures (20x16 with 3 levels and
// 33x17 with 6, 3 slices, both formats), then reads every subresource in a compute kernel through a one-level,
// one-slice array view of it, through a view of levels 1+ and slices 1+, and through a stencil view of a depth-stencil
// view of levels 1+ and slices 1+. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void readStencil(texture2d_array<uint> s [[texture(0)]], device uchar *o [[buffer(0)]], constant uint2 &ls [[buffer(1)]],\n"
    "                        uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width(ls.x) && g.y < s.get_height(ls.x)) o[g.y * 64 + g.x] = s.read(g, ls.y, ls.x).x;\n"
    "}\n";

static uint8_t expected(int level, int slice, int x, int y) { return (uint8_t)(0x10 * (level + 1) + 0x40 * slice + (x + 3 * y) % 16); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s46-amd-stencil-view-subresources";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readStencil"] error:&err];
        if (!read) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        static const struct { MTLPixelFormat format, view; const char *name; } kFormats[] = {
            {MTLPixelFormatDepth32Float_Stencil8, MTLPixelFormatX32_Stencil8, "Depth32Float_Stencil8"},
            {MTLPixelFormatDepth24Unorm_Stencil8, MTLPixelFormatX24_Stencil8, "Depth24Unorm_Stencil8"},
        };
        static const struct { int width, height, levels; } kSizes[] = {{20, 16, 3}, {33, 17, 6}};
        enum { S = 3 };
        int reads = 0;
        for (int f = 0; f < 2; f++) {
            if (f == 1 && !dev.depth24Stencil8PixelFormatSupported) continue;
            for (int z = 0; z < 2; z++) {
                int W = kSizes[z].width, H = kSizes[z].height, L = kSizes[z].levels;
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kFormats[f].format width:W height:H mipmapped:YES];
                td.mipmapLevelCount = L;
                td.textureType = MTLTextureType2DArray;
                td.arrayLength = S;
                td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
                td.storageMode = MTLStorageModePrivate;
                id<MTLTexture> t = [dev newTextureWithDescriptor:td];
                if (!t) return FAIL(bug, "%s: no %s texture", name, kFormats[f].name);
                id<MTLBuffer> in = [dev newBufferWithLength:64 * 64 * L * S options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                for (int l = 0; l < L; l++)
                    for (int s = 0; s < S; s++) {
                        int w = MAX(W >> l, 1), h = MAX(H >> l, 1), offset = 64 * 64 * (l * S + s);
                        for (int y = 0; y < h; y++)
                            for (int x = 0; x < w; x++) ((uint8_t *)in.contents)[offset + y * w + x] = expected(l, s, x, y);
                        [b copyFromBuffer:in sourceOffset:offset sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1)
                                toTexture:t destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)
                                  options:MTLBlitOptionStencilFromDepthStencil];
                    }
                [b endEncoding];
                // (view, lod, slice in the view, level, slice in the texture)
                struct { id<MTLTexture> view; int lod, slice, level, textureSlice; const char *how; } cases[64];
                int n = 0;
                for (int l = 0; l < L; l++)
                    for (int s = 0; s < S; s++)
                        cases[n++] = (typeof(cases[0])){[t newTextureViewWithPixelFormat:kFormats[f].view textureType:MTLTextureType2DArray
                                                                                  levels:NSMakeRange(l, 1) slices:NSMakeRange(s, 1)], 0, 0, l, s,
                                                        "a view of that level and slice"};
                id<MTLTexture> range = [t newTextureViewWithPixelFormat:kFormats[f].view textureType:MTLTextureType2DArray
                                                                 levels:NSMakeRange(1, L - 1) slices:NSMakeRange(1, S - 1)];
                for (int l = 1; l < L; l++)
                    for (int s = 1; s < S; s++) cases[n++] = (typeof(cases[0])){range, l - 1, s - 1, l, s, "a view of levels 1+ and slices 1+"};
                id<MTLTexture> depthView = [t newTextureViewWithPixelFormat:kFormats[f].format textureType:MTLTextureType2DArray
                                                                     levels:NSMakeRange(1, L - 1) slices:NSMakeRange(1, S - 1)];
                cases[n++] = (typeof(cases[0])){[depthView newTextureViewWithPixelFormat:kFormats[f].view textureType:MTLTextureType2DArray
                                                                                 levels:NSMakeRange(1, 1) slices:NSMakeRange(1, 1)], 0, 0, 2, 2,
                                                "a stencil view of a depth-stencil view"};
                id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * n options:MTLResourceStorageModeShared];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:read];
                for (int c = 0; c < n; c++) {
                    if (!cases[c].view) return FAIL(bug, "%s: no view", name);
                    uint32_t ls[2] = {(uint32_t)cases[c].lod, (uint32_t)cases[c].slice};
                    [ce setTexture:cases[c].view atIndex:0];
                    [ce setBuffer:out offset:64 * 64 * c atIndex:0];
                    [ce setBytes:ls length:sizeof ls atIndex:1];
                    [ce dispatchThreads:MTLSizeMake(MAX(W >> cases[c].level, 1), MAX(H >> cases[c].level, 1), 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                }
                [ce endEncoding];
                if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
                for (int c = 0; c < n; c++) {
                    int w = MAX(W >> cases[c].level, 1), h = MAX(H >> cases[c].level, 1), wrong = 0, fx = -1, fy = -1;
                    for (int y = 0; y < h; y++)
                        for (int x = 0; x < w; x++)
                            if (((uint8_t *)out.contents)[64 * 64 * c + y * 64 + x] != expected(cases[c].level, cases[c].textureSlice, x, y) && wrong++ == 0) {
                                fx = x;
                                fy = y;
                            }
                    reads++;
                    if (wrong)
                        return FAIL(bug, "%s: %s %dx%d, level %d slice %d through %s: %d of %d texels wrong (first (%d,%d) reads %u, want %u)", name,
                                    kFormats[f].name, W, H, cases[c].level, cases[c].textureSlice, cases[c].how, wrong, w * h, fx, fy,
                                    ((uint8_t *)out.contents)[64 * 64 * c + fy * 64 + fx], expected(cases[c].level, cases[c].textureSlice, fx, fy));
                }
            }
        }
        return PASS(bug, "%s: stencil reads right through views of every level and slice, range views and views of views (%d reads)", name, reads);
    }
}
