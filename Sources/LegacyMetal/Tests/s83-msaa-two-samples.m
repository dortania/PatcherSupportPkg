// s83-msaa-two-samples (MetalOldCompat item 77): 2x multisampling on a GPU without it (Ivy Bridge and Haswell have 4x and
// 8x only: supportsTextureSampleCount:2 is NO). Tahoe's Sequoia wallpaper (WallpaperSequoiaExtension) makes a 2x
// Depth16Unorm render target without asking, and MetalOld's validation aborted the extension ("MTLTextureDescriptor
// sampleCount (2) is not supported by device."), so the wallpaper fell back to Tahoe's default. Everything here asks for
// 2 samples: the wallpaper's depth target (Depth16Unorm, 2DMultisample, private, render target) and an RGBA8 color target
// are made; a 2x pipeline draws the left half of the target with a depth test, resolved into a single-sample texture
// (left half drawn, right half the clear color); a heap sized with heapTextureSizeAndAlignWithDescriptor: for the 2x
// texture holds it; and a 2x pass without attachments runs a 2x pipeline once per pixel (a device atomic counts).
// SKIP where the GPU has 2x (nothing to do there). Stock: crash (abort). Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

static const char *source =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 half_vs(uint vid [[vertex_id]]) {\n"  // the left half of the target, as two triangles
    "    const float2 p[6] = { float2(-1, -1), float2(0, -1), float2(-1, 1), float2(0, -1), float2(0, 1), float2(-1, 1) };\n"
    "    return float4(p[vid], 0.5, 1.0);\n"
    "}\n"
    "fragment float4 red_fs() { return float4(1.0, 0.0, 0.0, 1.0); }\n"
    "vertex float4 full_vs(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); return float4(q * 2.0 - 1.0, 0.0, 1.0); }\n"
    "fragment void count_fs(device atomic_uint *count [[buffer(0)]]) { atomic_fetch_add_explicit(count, 1u, memory_order_relaxed); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s83-msaa-two-samples";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        if ([dev supportsTextureSampleCount:2]) return SKIP(bug, "%s has 2x multisampling: nothing to do", name);
        if (![dev supportsTextureSampleCount:4]) return SKIP(bug, "%s has neither 2x nor 4x multisampling", name);
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(source) options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", name, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        enum { W = 32, H = 16 };

        // 1. the wallpaper's depth target, and a color target, at 2 samples
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:W height:H mipmapped:NO];
        dd.textureType = MTLTextureType2DMultisample;
        dd.sampleCount = 2;
        dd.storageMode = MTLStorageModePrivate;
        dd.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        cd.textureType = MTLTextureType2DMultisample;
        cd.sampleCount = 2;
        cd.storageMode = MTLStorageModePrivate;
        cd.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
        if (!depth || !color) return FAIL(bug, "%s: no 2x %s target", name, depth ? "color" : "depth");
        NSUInteger made = depth.sampleCount;

        // 2. a 2x pipeline draws the left half, with a depth test, resolved into a single-sample texture
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"half_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"red_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
        pd.rasterSampleCount = 2;
        id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!draw) return FAIL(bug, "%s: 2x pipeline: %s", name, error.localizedDescription.UTF8String);
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dsd];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> resolved = [dev newTextureWithDescriptor:rd];
        id<MTLBuffer> pixels = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].resolveTexture = resolved;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 1.0;
        pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:draw];
        [re setDepthStencilState:ds];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:resolved sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: 2x draw: command buffer failed", name);
        const uint8_t *p = pixels.contents;
        for (NSUInteger y = 0; y < H; y++)
            for (NSUInteger x = 0; x < W; x++) {
                const uint8_t *t = p + (y * W + x) * 4;
                BOOL left = x < W / 2;
                if (left ? (t[0] != 255 || t[2] != 0) : (t[0] != 0 || t[2] != 255))
                    return FAIL(bug, "%s: 2x draw resolved to (%u, %u, %u) at %lu,%lu, want %s", name, t[0], t[1], t[2],
                                (unsigned long)x, (unsigned long)y, left ? "red" : "the blue clear color");
            }

        // 3. a heap sized for the 2x texture holds it
        MTLSizeAndAlign two = [dev heapTextureSizeAndAlignWithDescriptor:dd];
        MTLTextureDescriptor *dd4 = [dd copy];
        dd4.sampleCount = 4;
        MTLSizeAndAlign four = [dev heapTextureSizeAndAlignWithDescriptor:dd4];
        if (two.size < four.size)
            return FAIL(bug, "%s: heap size of the 2x texture %lu, below the 4x texture's %lu", name, (unsigned long)two.size, (unsigned long)four.size);
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.size = two.size + two.align;
        hd.storageMode = MTLStorageModePrivate;
        id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
        id<MTLTexture> fromHeap = heap ? [heap newTextureWithDescriptor:dd] : nil;
        if (!fromHeap) return FAIL(bug, "%s: a heap of %lu bytes didn't make the 2x texture", name, (unsigned long)hd.size);

        // 4. a 2x pass without attachments runs a 2x pipeline once per pixel
        MTLRenderPipelineDescriptor *qd = [MTLRenderPipelineDescriptor new];
        qd.vertexFunction = [lib newFunctionWithName:@"full_vs"];
        qd.fragmentFunction = [lib newFunctionWithName:@"count_fs"];
        qd.rasterSampleCount = 2;
        id<MTLRenderPipelineState> countPipe = [dev newRenderPipelineStateWithDescriptor:qd error:&error];
        if (!countPipe) return FAIL(bug, "%s: 2x pipeline without attachments: %s", name, error.localizedDescription.UTF8String);
        id<MTLBuffer> count = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        *(uint32_t *)count.contents = 0;
        MTLRenderPassDescriptor *empty = [MTLRenderPassDescriptor renderPassDescriptor];
        empty.renderTargetWidth = W;
        empty.renderTargetHeight = H;
        empty.defaultRasterSampleCount = 2;
        cb = [queue commandBuffer];
        re = [cb renderCommandEncoderWithDescriptor:empty];
        [re setRenderPipelineState:countPipe];
        [re setFragmentBuffer:count offset:0 atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: 2x pass without attachments: command buffer failed", name);
        uint32_t n = *(uint32_t *)count.contents;
        if (n != W * H) return FAIL(bug, "%s: 2x pass without attachments ran the fragment function %u times, want %u", name, n, W * H);

        return PASS(bug, "%s: 2x targets (made as %lux), a 2x depth-tested draw and resolve, a heap sized for 2x, and a 2x pass "
                         "without attachments all work", name, (unsigned long)made);
    }
}
