// s48-amd-stencil8-levels-slices (AMDBronzeCompat item 11): a Stencil8 texture with several levels and slices must hold
// what each kind of access puts there. The 12.5 AMD driver lays such a texture out 1D tiled but describes it as 2D
// tiled, so blits, the depth unit and shaders disagree past level 0 / slice 0; AMDBronzeCompat makes it as
// Depth32Float_Stencil8 and keeps the Stencil8 API working around that.
// A 32x16 Stencil8 2D array with 3 levels and 2 slices gets a value per texel, level and slice by blits without options.
// Then: blits back to a buffer without options; a compute kernel reads every subresource from the texture itself and
// level 1 / slice 1 through a Stencil8 view; a REPLACE draw writes 0x5A through a Stencil8 view of level 1 / slice 1 as
// the stencil attachment; copies to and from a single-level Stencil8 texture (both ways, region and level copies).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 v(uint id [[vertex_id]]) { float2 t = float2((id << 1) & 2, id & 2); return float4(t * 2 - 1, 0, 1); }\n"
    "fragment float4 f() { return float4(1); }\n"
    "kernel void readArray(texture2d_array<uint> s [[texture(0)]], device uchar *o [[buffer(0)]], constant uint2 &ls [[buffer(1)]],\n"
    "                      uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width(ls.x) && g.y < s.get_height(ls.x)) o[g.y * 32 + g.x] = s.read(g, ls.y, ls.x).x;\n"
    "}\n"
    "kernel void read2D(texture2d<uint> s [[texture(0)]], device uchar *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x < s.get_width() && g.y < s.get_height()) o[g.y * 32 + g.x] = s.read(g).x;\n"
    "}\n";

enum { W = 32, H = 16, L = 3, S = 2 };
static uint8_t expected(int level, int slice, int x, int y) { return (uint8_t)(0x10 * (level + 1) + 0x40 * slice + (x + 3 * y) % 16); }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s48-amd-stencil8-levels-slices";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> readArray = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readArray"] error:&err];
        id<MTLComputePipelineState> read2D = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read2D"] error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
        id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!readArray || !read2D || !draw) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        dsd.backFaceStencil = dsd.frontFaceStencil;
        id<MTLDepthStencilState> replace = [dev newDepthStencilStateWithDescriptor:dsd];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W height:H mipmapped:YES];
        td.mipmapLevelCount = L;
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = S;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W / 2 height:H / 2 mipmapped:NO];
        sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        sd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> single = [dev newTextureWithDescriptor:sd];
        if (!t || !single) return FAIL(bug, "%s: no texture", name);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        id<MTLBuffer> in = [dev newBufferWithLength:W * H * L * S options:MTLResourceStorageModeShared];
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++) {
                int w = W >> l, h = H >> l, offset = W * H * (l * S + s);
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++) ((uint8_t *)in.contents)[offset + y * w + x] = expected(l, s, x, y);
                [b copyFromBuffer:in sourceOffset:offset sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
                    destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
        id<MTLBuffer> back = [dev newBufferWithLength:W * H * L * S options:MTLResourceStorageModeShared];
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++) {
                int w = W >> l, h = H >> l;
                [b copyFromTexture:t sourceSlice:s sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:back
                    destinationOffset:W * H * (l * S + s) destinationBytesPerRow:w destinationBytesPerImage:w * h];
            }
        [b endEncoding];
        // shader reads: every subresource from the texture, level 1 / slice 1 through a Stencil8 view
        id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatStencil8 textureType:MTLTextureType2D levels:NSMakeRange(1, 1)
                                                        slices:NSMakeRange(1, 1)];
        if (!view) return FAIL(bug, "%s: no Stencil8 view", name);
        id<MTLBuffer> reads = [dev newBufferWithLength:32 * 16 * (L * S + 1) options:MTLResourceStorageModeShared];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:readArray];
        [ce setTexture:t atIndex:0];
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++) {
                uint32_t ls[2] = {(uint32_t)l, (uint32_t)s};
                [ce setBuffer:reads offset:32 * 16 * (l * S + s) atIndex:0];
                [ce setBytes:ls length:sizeof ls atIndex:1];
                [ce dispatchThreads:MTLSizeMake(W >> l, H >> l, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            }
        [ce setComputePipelineState:read2D];
        [ce setTexture:view atIndex:0];
        [ce setBuffer:reads offset:32 * 16 * L * S atIndex:0];
        [ce dispatchThreads:MTLSizeMake(W >> 1, H >> 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        for (int l = 0; l < L; l++)
            for (int s = 0; s < S; s++)
                for (int y = 0; y < (H >> l); y++)
                    for (int x = 0; x < (W >> l); x++) {
                        uint8_t want = expected(l, s, x, y), blit = ((uint8_t *)back.contents)[W * H * (l * S + s) + y * (W >> l) + x],
                                shader = ((uint8_t *)reads.contents)[32 * 16 * (l * S + s) + y * 32 + x];
                        if (blit != want) return FAIL(bug, "%s: level %d slice %d (%d,%d) copied back as %u, want %u", name, l, s, x, y, blit, want);
                        if (shader != want) return FAIL(bug, "%s: level %d slice %d (%d,%d) read by a shader as %u, want %u", name, l, s, x, y, shader, want);
                    }
        for (int y = 0; y < (H >> 1); y++)
            for (int x = 0; x < (W >> 1); x++)
                if (((uint8_t *)reads.contents)[32 * 16 * L * S + y * 32 + x] != expected(1, 1, x, y))
                    return FAIL(bug, "%s: level 1 slice 1 (%d,%d) read through a Stencil8 view as %u, want %u", name, x, y,
                                ((uint8_t *)reads.contents)[32 * 16 * L * S + y * 32 + x], expected(1, 1, x, y));
        // copies with a single-level Stencil8 texture: level 1 / slice 1 -> single (region), single -> level 1 / slice 0 (levels)
        cb = [queue commandBuffer];
        b = [cb blitCommandEncoder];
        [b copyFromTexture:t sourceSlice:1 sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W / 2, H / 2, 1) toTexture:single
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b copyFromTexture:single sourceSlice:0 sourceLevel:0 toTexture:t destinationSlice:0 destinationLevel:1 sliceCount:1 levelCount:1];
        [b endEncoding];
        // REPLACE 0x5A through a Stencil8 view of level 1 / slice 1 as the stencil attachment
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W / 2 height:H / 2 mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget;
        cd.storageMode = MTLStorageModePrivate;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:cd];
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        rp.stencilAttachment.texture = view;
        rp.stencilAttachment.loadAction = MTLLoadActionLoad;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:draw];
        [enc setDepthStencilState:replace];
        [enc setStencilReferenceValue:0x5A];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBuffer> after = [dev newBufferWithLength:W * H * 2 options:MTLResourceStorageModeShared];
        b = [cb blitCommandEncoder];
        [b copyFromTexture:single sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W / 2, H / 2, 1) toBuffer:after
            destinationOffset:0 destinationBytesPerRow:W / 2 destinationBytesPerImage:W * H / 4];
        for (int s = 0; s < 2; s++)
            [b copyFromTexture:t sourceSlice:s sourceLevel:1 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W / 2, H / 2, 1) toBuffer:after
                destinationOffset:W * H / 4 * (s + 1) destinationBytesPerRow:W / 2 destinationBytesPerImage:W * H / 4];
        [b endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint8_t *a = after.contents;
        for (int y = 0; y < H / 2; y++)
            for (int x = 0; x < W / 2; x++) {
                int i = y * (W / 2) + x;
                if (a[i] != expected(1, 1, x, y)) return FAIL(bug, "%s: level 1 slice 1 copied to a Stencil8 texture: (%d,%d) is %u, want %u", name, x, y, a[i], expected(1, 1, x, y));
                if (a[W * H / 4 + i] != expected(1, 1, x, y))
                    return FAIL(bug, "%s: a Stencil8 texture copied to level 1 slice 0: (%d,%d) is %u, want %u", name, x, y, a[W * H / 4 + i], expected(1, 1, x, y));
                if (a[W * H / 2 + i] != 0x5A) return FAIL(bug, "%s: REPLACE through a Stencil8 view of level 1 slice 1: (%d,%d) is %u, want 0x5A", name, x, y, a[W * H / 2 + i]);
            }
        return PASS(bug, "%s: a 3-level, 2-slice Stencil8 texture keeps what blits, shaders, views, copies and render passes put there", name);
    }
}
