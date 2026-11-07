// s43-intel-stencil-view-mips (MetalOldCompat item 38): a shader must read the stencil of Depth32Float_Stencil8 at mip
// level 2 through an X32_Stencil8 view. On the 12.x Intel driver the view's surface state takes the depth plane's
// horizontal mip alignment (4) while the stencil plane is laid out with 8, so levels 2+ read 0 for many widths (level 2
// of 20x16 here; Dawn backs WebGPU's stencil8 with this format). Writes 5x4 distinct stencil bytes into level 2 with a
// blit and reads them back in a compute kernel through a view of the whole texture and through a view of level 2 alone.
// The AMD driver gets the same reads wrong another way: a stencil view of level 1+ or slice 1+ gets an image descriptor
// whose base address already points past level 0 / slice 0 while BASE_LEVEL / BASE_ARRAY add them again (level 2 reads
// level 0's stencil); AMDBronzeCompat item 1 sets it back.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void readStencil(texture2d<uint> s [[texture(0)]], device uchar *o [[buffer(0)]], constant uint &level [[buffer(1)]],\n"
    "                        uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width(level) && g.y < s.get_height(level)) o[g.y * 8 + g.x] = s.read(g, level).x;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s43-intel-stencil-view-mips";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readStencil"] error:&err];
        if (!read) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:20 height:16 mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        id<MTLTexture> whole = [t newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
        id<MTLTexture> level2 = [t newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8 textureType:MTLTextureType2D levels:NSMakeRange(2, 1) slices:NSMakeRange(0, 1)];
        if (!t || !whole || !level2) return FAIL(bug, "%s: no texture or view", name);
        uint8_t want[4][5];
        id<MTLBuffer> in = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) ((uint8_t *)in.contents)[256 * y + x] = want[y][x] = (uint8_t)(y * 40 + x * 7 + 3);
        id<MTLBuffer> outWhole = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
        id<MTLBuffer> outLevel = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(5, 4, 1)
                toTexture:t destinationSlice:0 destinationLevel:2 destinationOrigin:MTLOriginMake(0, 0, 0) options:MTLBlitOptionStencilFromDepthStencil];
        [b endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:read];
        uint32_t two = 2, zero = 0;
        [ce setTexture:whole atIndex:0]; [ce setBuffer:outWhole offset:0 atIndex:0]; [ce setBytes:&two length:4 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(5, 4, 1) threadsPerThreadgroup:MTLSizeMake(5, 4, 1)];
        [ce setTexture:level2 atIndex:0]; [ce setBuffer:outLevel offset:0 atIndex:0]; [ce setBytes:&zero length:4 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(5, 4, 1) threadsPerThreadgroup:MTLSizeMake(5, 4, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint8_t *w = outWhole.contents, *l = outLevel.contents;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) {
            if (w[y * 8 + x] != want[y][x])
                return FAIL(bug, "%s: level 2 through a view of the whole texture, texel (%d,%d) reads %u, want %u", name, x, y, w[y * 8 + x], want[y][x]);
            if (l[y * 8 + x] != want[y][x])
                return FAIL(bug, "%s: level 2 through a view of that level, texel (%d,%d) reads %u, want %u", name, x, y, l[y * 8 + x], want[y][x]);
        }
        return PASS(bug, "%s: stencil of Depth32Float_Stencil8 reads right at mip level 2 through X32_Stencil8 views", name);
    }
}
