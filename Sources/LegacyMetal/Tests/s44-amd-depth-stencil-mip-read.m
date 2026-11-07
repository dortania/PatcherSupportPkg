// s44-amd-depth-stencil-mip-read (AMDBronzeCompat item 10): shader reads of the depth of a mipmapped depth-stencil
// texture on the 12.5 AMD driver. The driver lays out the depth plane of Depth24Unorm_Stencil8 and Depth32Float_Stencil8
// with addrlib's stencil padding, which the texture unit doesn't follow, so levels 4 or fewer texels wide (among others)
// read from the wrong place: WebGL's depth24_stencil8 shadow lookups (dEQP textureshadow 2d and 2d_array, 32x64) and
// texture storage checks. Depth32Float is laid out without the padding and reads right.
// Uploads a different depth to every texel of every level the way ANGLE does (a buffer-to-texture blit per level with
// DepthFromDepthStencil, and the stencil with StencilFromDepthStencil), reads each level back with depth2d::read in a
// compute kernel, then checks that the stencil of each level still reads back through a blit and passes a stencil test,
// except at levels 16 tall and 8 or fewer wide, where the stencil plane can't follow the unpadded depth plane (as in
// radeonsi). 32x64 and 64x64, both formats.
// Stock OCLP: FAIL (small levels read other levels' depth). Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void rd(depth2d<float, access::read> t [[texture(0)]], device float *o [[buffer(0)]],\n"
    "               constant uint &level [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {\n"
    "    uint w = t.get_width(level), h = t.get_height(level);\n"
    "    if (p.x < w && p.y < h) o[p.y * w + p.x] = t.read(p, level);\n"
    "}\n"
    "vertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0.5, 1); }\n"
    "fragment float f() { return 1.0; }\n";

static float depthAt(int level, int i, int count) { return (level + 1) * 0.1f + (float)i / count * 0.05f; }
static uint8_t stencilAt(int level) { return (uint8_t)(level * 16 + 1); }

// NULL if every level reads back, else what went wrong first.
static NSString *check(id<MTLDevice> dev, id<MTLLibrary> lib, MTLPixelFormat format, int width, int height) {
    NSError *err = nil;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    pd.depthAttachmentPixelFormat = format;
    pd.stencilAttachmentPixelFormat = format;
    id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!read || !draw) return [NSString stringWithFormat:@"pipeline: %s", err.localizedDescription.UTF8String];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
    sd.stencilCompareFunction = MTLCompareFunctionEqual;
    dd.frontFaceStencil = sd;
    dd.backFaceStencil = sd;
    id<MTLDepthStencilState> stencilEqual = [dev newDepthStencilStateWithDescriptor:dd];

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:YES];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    int levels = (int)tex.mipmapLevelCount;
    BOOL is24 = format == MTLPixelFormatDepth24Unorm_Stencil8;

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (int l = 0; l < levels; l++) {
        int w = MAX(width >> l, 1), h = MAX(height >> l, 1), n = w * h;
        id<MTLBuffer> depth = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> stencil = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        for (int i = 0; i < n; i++) {
            float d = depthAt(l, i, n);
            if (is24) ((uint32_t *)depth.contents)[i] = (uint32_t)lrintf(d * 16777215.0f);  // Metal wants the low 24 bits
            else ((float *)depth.contents)[i] = d;
            ((uint8_t *)stencil.contents)[i] = stencilAt(l);
        }
        [blit copyFromBuffer:depth sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:n * 4 sourceSize:MTLSizeMake(w, h, 1)
                   toTexture:tex destinationSlice:0 destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)
                     options:MTLBlitOptionDepthFromDepthStencil];
        [blit copyFromBuffer:stencil sourceOffset:0 sourceBytesPerRow:w sourceBytesPerImage:n sourceSize:MTLSizeMake(w, h, 1)
                   toTexture:tex destinationSlice:0 destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)
                     options:MTLBlitOptionStencilFromDepthStencil];
    }
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    for (int l = 0; l < levels; l++) {
        int w = MAX(width >> l, 1), h = MAX(height >> l, 1), n = w * h;
        uint32_t level = l;
        id<MTLBuffer> out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> stencil = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        id<MTLBuffer> passed = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:w height:h mipmapped:NO];
        cd.storageMode = MTLStorageModePrivate;
        cd.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
        cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:read];
        [ce setTexture:tex atIndex:0];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce setBytes:&level length:4 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(MIN(w, 8), MIN(h, 8), 1)];
        [ce endEncoding];
        blit = [cb blitCommandEncoder];
        [blit copyFromTexture:tex sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                     toBuffer:stencil destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:n
                      options:MTLBlitOptionStencilFromDepthStencil];
        [blit endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = color;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.depthAttachment.texture = tex;
        rp.depthAttachment.level = l;
        rp.depthAttachment.loadAction = MTLLoadActionLoad;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.stencilAttachment.texture = tex;
        rp.stencilAttachment.level = l;
        rp.stencilAttachment.loadAction = MTLLoadActionLoad;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:draw];
        [re setDepthStencilState:stencilEqual];
        [re setStencilReferenceValue:stencilAt(l)];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        blit = [cb blitCommandEncoder];
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                     toBuffer:passed destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:n];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        int wrongDepth = 0, first = -1, wrongStencil = 0, failedTest = 0;
        for (int i = 0; i < n; i++) {
            if (fabsf(((float *)out.contents)[i] - depthAt(l, i, n)) > 1e-4f && wrongDepth++ == 0) first = i;
            wrongStencil += ((uint8_t *)stencil.contents)[i] != stencilAt(l);
            failedTest += ((uint8_t *)passed.contents)[i] != 255;
        }
        if (wrongDepth)
            return [NSString stringWithFormat:@"level %d (%dx%d): shader read %d of %d depths wrong (first %.5f, want %.5f)", l, w, h,
                                              wrongDepth, n, ((float *)out.contents)[first], depthAt(l, first, n)];
        BOOL conflict = h == 16 && w <= 8;  // see the header
        if (!conflict && (wrongStencil || failedTest))
            return [NSString stringWithFormat:@"level %d (%dx%d): stencil: %d wrong through a blit, stencil test failed in %d", l, w, h,
                                              wrongStencil, failedTest];
    }
    return nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s44-amd-depth-stencil-mip-read";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        if (!dev.depth24Stencil8PixelFormatSupported) return SKIP(bug, "%s: no Depth24Unorm_Stencil8", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        const struct { MTLPixelFormat format; const char *name; int width, height; } cases[] = {
            {MTLPixelFormatDepth24Unorm_Stencil8, "Depth24Unorm_Stencil8", 32, 64},
            {MTLPixelFormatDepth24Unorm_Stencil8, "Depth24Unorm_Stencil8", 64, 64},
            {MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8", 32, 64},
            {MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8", 64, 64},
        };
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            NSString *problem = check(dev, lib, cases[i].format, cases[i].width, cases[i].height);
            if (problem) return FAIL(bug, "%s: %s %dx%d: %s", dev.name.UTF8String, cases[i].name, cases[i].width, cases[i].height, problem.UTF8String);
        }
        return PASS(bug, "%s: every level of 32x64 and 64x64 Depth24Unorm_Stencil8 / Depth32Float_Stencil8 reads its own depth in a shader",
                    dev.name.UTF8String);
    }
}
