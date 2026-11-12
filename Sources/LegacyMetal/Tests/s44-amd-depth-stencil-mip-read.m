// s44-amd-depth-stencil-mip-read (AMDBronzeCompat item 10): mipmapped depth-stencil textures on the 12.5 AMD driver.
// The driver lays out the depth plane of Depth24Unorm_Stencil8 and Depth32Float_Stencil8 with addrlib's stencil padding,
// which the texture unit doesn't follow, so shaders read the depth of levels 4 or fewer texels wide (among others) from the
// wrong place: WebGL's depth24_stencil8 shadow lookups (dEQP textureshadow 2d and 2d_array, 32x64) and texture storage
// checks. Without the padding, the depth unit (render passes) no longer finds stencil where blits and shaders have it on
// those levels, which item 10 handles by rendering them through a temporary; so this test checks both.
//   1. Depth: a different value per texel on every level (and slice) of 32x64 and 64x64 2D textures and a 32x64x2 2D
//      array, uploaded the way ANGLE does (buffer-to-texture blits with DepthFromDepthStencil), read back with
//      depth2d(_array)::read in a compute kernel.
//   2. Stencil: a different value per texel on every level and slice of a 32x64 2D texture (7 levels) and a 32x16x2 2D
//      array (3 levels), uploaded with StencilFromDepthStencil blits, read back three ways: a blit to a buffer, a shader
//      through a stencil view, and the depth unit (a stencil-EQUAL draw per value, each writing the value to an R8Uint
//      target). Then a render pass per level and slice replaces the stencil there with a value of its own, and blits and
//      the shader must read exactly those values everywhere (a pass that wrote into another level or slice shows up).
// Both formats. Stock OCLP: FAIL (small levels read other levels' depth). Item 10 without its render-pass routing: FAIL
// (the depth unit misses stencil from slice 1 of level 1 on). Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void rd(depth2d_array<float, access::read> t [[texture(0)]], device float *o [[buffer(0)]],\n"
    "               constant uint2 &ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {\n"
    "    uint w = t.get_width(ls.x), h = t.get_height(ls.x);\n"
    "    if (p.x < w && p.y < h) o[p.y * w + p.x] = t.read(p, ls.y, ls.x);\n"
    "}\n"
    "kernel void rs(texture2d_array<uint, access::read> t [[texture(0)]], device uchar *o [[buffer(0)]],\n"
    "               constant uint2 &ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {\n"
    "    uint w = t.get_width(ls.x), h = t.get_height(ls.x);\n"
    "    if (p.x < w && p.y < h) o[p.y * w + p.x] = t.read(p, ls.y, ls.x).r;\n"
    "}\n"
    "vertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0.5, 1); }\n"
    "fragment uint f(constant uint &value [[buffer(0)]]) { return value; }\n";

typedef struct {
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> readDepth, readStencil;
} Ctx;

static float depthAt(int level, int slice, int i, int count) { return (level + 1) * 0.1f + slice * 0.02f + (float)i / count * 0.01f; }
static uint8_t stencilAt(int x, int y, int level, int slice) { return (uint8_t)((x * 7 + y * 13 + level * 29 + slice * 53) & 0xff) | 1; }
static int levelSize(int size, int level) { return MAX(size >> level, 1); }

static id<MTLTexture> makeTexture(Ctx *c, MTLPixelFormat format, int width, int height, int levels, int slices) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:YES];
    td.mipmapLevelCount = levels;
    if (slices > 1) {
        td.textureType = MTLTextureType2DArray;
        td.arrayLength = slices;
    }
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    return [c->dev newTextureWithDescriptor:td];
}

static id<MTLTexture> arrayView(id<MTLTexture> t, MTLPixelFormat format) {
    return [t newTextureViewWithPixelFormat:format textureType:MTLTextureType2DArray levels:NSMakeRange(0, t.mipmapLevelCount)
                                     slices:NSMakeRange(0, t.textureType == MTLTextureType2DArray ? t.arrayLength : 1)];
}

static void dispatchRead(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> ps, id<MTLTexture> view, id<MTLBuffer> out, int l, int s, int w, int h) {
    uint32_t ls[2] = {(uint32_t)l, (uint32_t)s};
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:view atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce setBytes:ls length:sizeof ls atIndex:1];
    [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(MIN(w, 8), MIN(h, 8), 1)];
    [ce endEncoding];
}

// 1. Depth read by a shader. NULL if right.
static NSString *checkDepth(Ctx *c, MTLPixelFormat format, int width, int height, int slices) {
    int levels = (int)log2(MAX(width, height)) + 1;
    id<MTLTexture> t = makeTexture(c, format, width, height, levels, slices);
    BOOL is24 = format == MTLPixelFormatDepth24Unorm_Stencil8;
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            int w = levelSize(width, l), h = levelSize(height, l), n = w * h;
            id<MTLBuffer> b = [c->dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
            for (int i = 0; i < n; i++) {
                float d = depthAt(l, s, i, n);
                if (is24) ((uint32_t *)b.contents)[i] = (uint32_t)lrintf(d * 16777215.0f);  // Metal wants the low 24 bits
                else ((float *)b.contents)[i] = d;
            }
            [blit copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:n * 4 sourceSize:MTLSizeMake(w, h, 1)
                       toTexture:t destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)
                         options:MTLBlitOptionDepthFromDepthStencil];
        }
    [blit endEncoding];
    if (!reproRun(cb)) return @"upload failed";
    id<MTLTexture> view = arrayView(t, format);
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            int w = levelSize(width, l), h = levelSize(height, l), n = w * h;
            id<MTLBuffer> out = [c->dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
            cb = [c->queue commandBuffer];
            dispatchRead(cb, c->readDepth, view, out, l, s, w, h);
            if (!reproRun(cb)) return @"read failed";
            int wrong = 0, first = -1;
            for (int i = 0; i < n; i++)
                if (fabsf(((float *)out.contents)[i] - depthAt(l, s, i, n)) > 1e-4f && wrong++ == 0) first = i;
            if (wrong)
                return [NSString stringWithFormat:@"depth: level %d slice %d (%dx%d): shader read %d of %d wrong (first %.5f, want %.5f)", l, s, w,
                                                  h, wrong, n, ((float *)out.contents)[first], depthAt(l, s, first, n)];
        }
    return nil;
}

// What the depth unit sees as the stencil of one level and slice: a stencil-EQUAL draw per value.
static BOOL depthUnitStencil(Ctx *c, id<MTLRenderPipelineState> draw, id<MTLDepthStencilState> equal, id<MTLTexture> t, int l, int s,
                             int w, int h, id<MTLBuffer> out) {
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint width:w height:h mipmapped:NO];
    cd.storageMode = MTLStorageModePrivate;
    cd.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> color = [c->dev newTextureWithDescriptor:cd];
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = color;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    for (MTLRenderPassAttachmentDescriptor *a in @[rp.depthAttachment, rp.stencilAttachment]) {
        a.texture = t;
        a.level = l;
        a.slice = s;
        a.loadAction = MTLLoadActionLoad;
        a.storeAction = MTLStoreActionStore;
    }
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:draw];
    [re setDepthStencilState:equal];
    for (uint32_t v = 1; v < 256; v++) {
        [re setStencilReferenceValue:v];
        [re setFragmentBytes:&v length:4 atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [re endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
        destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:w * h];
    [blit endEncoding];
    return reproRun(cb);
}

// Stencil of one level and slice through a blit and through the shader. Returns the first texel that isn't `want`
// (want(x, y) or, with replaced >= 0, that value), or nil.
static NSString *readStencilBack(Ctx *c, id<MTLTexture> t, id<MTLTexture> view, int l, int s, int w, int h, int replaced, const char *after) {
    int n = w * h;
    id<MTLBuffer> blitOut = [c->dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    id<MTLBuffer> shaderOut = [c->dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:s sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:blitOut
        destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:n options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding];
    dispatchRead(cb, c->readStencil, view, shaderOut, l, s, w, h);
    if (!reproRun(cb)) return @"stencil read failed";
    const char *names[2] = {"blit", "shader"};
    const uint8_t *outs[2] = {blitOut.contents, shaderOut.contents};
    for (int k = 0; k < 2; k++) {
        int wrong = 0, fx = 0, fy = 0;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                uint8_t want = replaced >= 0 ? (uint8_t)replaced : stencilAt(x, y, l, s);
                if (outs[k][y * w + x] != want && wrong++ == 0) fx = x, fy = y;
            }
        if (wrong)
            return [NSString stringWithFormat:@"stencil%s: level %d slice %d (%dx%d): %s read %d of %d wrong (first at %d,%d)", after, l, s, w, h,
                                              names[k], wrong, n, fx, fy];
    }
    return nil;
}

// 2. Stencil, three readers, then render-pass writes. NULL if right.
static NSString *checkStencil(Ctx *c, id<MTLLibrary> lib, MTLPixelFormat format, int width, int height, int levels, int slices) {
    NSError *err = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Uint;
    pd.depthAttachmentPixelFormat = format;
    pd.stencilAttachmentPixelFormat = format;
    id<MTLRenderPipelineState> draw = [c->dev newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
    pd.fragmentFunction = nil;
    id<MTLRenderPipelineState> stencilOnly = [c->dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!draw || !stencilOnly) return [NSString stringWithFormat:@"pipeline: %s", err.localizedDescription.UTF8String];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
    sd.stencilCompareFunction = MTLCompareFunctionEqual;
    dd.frontFaceStencil = sd;
    dd.backFaceStencil = sd;
    id<MTLDepthStencilState> equal = [c->dev newDepthStencilStateWithDescriptor:dd];
    sd.stencilCompareFunction = MTLCompareFunctionAlways;
    sd.depthStencilPassOperation = MTLStencilOperationReplace;
    dd.frontFaceStencil = sd;
    dd.backFaceStencil = sd;
    id<MTLDepthStencilState> replace = [c->dev newDepthStencilStateWithDescriptor:dd];

    id<MTLTexture> t = makeTexture(c, format, width, height, levels, slices);
    id<MTLTexture> view = arrayView(t, format == MTLPixelFormatDepth24Unorm_Stencil8 ? MTLPixelFormatX24_Stencil8 : MTLPixelFormatX32_Stencil8);
    id<MTLCommandBuffer> cb = [c->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            int w = levelSize(width, l), h = levelSize(height, l);
            id<MTLBuffer> b = [c->dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) ((uint8_t *)b.contents)[y * w + x] = stencilAt(x, y, l, s);
            [blit copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w sourceBytesPerImage:w * h sourceSize:MTLSizeMake(w, h, 1) toTexture:t
                destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0) options:MTLBlitOptionStencilFromDepthStencil];
        }
    [blit endEncoding];
    if (!reproRun(cb)) return @"stencil upload failed";
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            int w = levelSize(width, l), h = levelSize(height, l);
            NSString *problem = readStencilBack(c, t, view, l, s, w, h, -1, "");
            if (problem) return problem;
            id<MTLBuffer> seen = [c->dev newBufferWithLength:w * h options:MTLResourceStorageModeShared];
            if (!depthUnitStencil(c, draw, equal, t, l, s, w, h, seen)) return @"stencil test pass failed";
            int wrong = 0, fx = 0, fy = 0;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (((uint8_t *)seen.contents)[y * w + x] != stencilAt(x, y, l, s) && wrong++ == 0) fx = x, fy = y;
            if (wrong)
                return [NSString stringWithFormat:@"stencil: level %d slice %d (%dx%d): the depth unit sees %d of %d texels wrong (first at %d,%d)", l,
                                                  s, w, h, wrong, w * h, fx, fy];
        }
    // Render-pass writes: each level and slice gets a value of its own.
    cb = [c->queue commandBuffer];
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            for (MTLRenderPassAttachmentDescriptor *a in @[rp.depthAttachment, rp.stencilAttachment]) {
                a.texture = t;
                a.level = l;
                a.slice = s;
                a.loadAction = MTLLoadActionLoad;
                a.storeAction = MTLStoreActionStore;
            }
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:stencilOnly];
            [re setDepthStencilState:replace];
            [re setStencilReferenceValue:200 + l * 4 + s];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
        }
    if (!reproRun(cb)) return @"stencil replace passes failed";
    for (int l = 0; l < levels; l++)
        for (int s = 0; s < slices; s++) {
            NSString *problem = readStencilBack(c, t, view, l, s, levelSize(width, l), levelSize(height, l), 200 + l * 4 + s,
                                                " after render-pass writes");
            if (problem) return problem;
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
        Ctx c = {dev, [dev newCommandQueue]};
        c.readDepth = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&err];
        c.readStencil = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rs"] error:&err];
        if (!c.readDepth || !c.readStencil) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        const struct { MTLPixelFormat format; const char *name; } formats[] = {
            {MTLPixelFormatDepth24Unorm_Stencil8, "Depth24Unorm_Stencil8"}, {MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8"}};
        for (size_t f = 0; f < 2; f++) {
            const struct { int w, h, slices; } depthCases[] = {{32, 64, 1}, {64, 64, 1}, {32, 64, 2}};
            for (size_t i = 0; i < 3; i++) {
                NSString *problem = checkDepth(&c, formats[f].format, depthCases[i].w, depthCases[i].h, depthCases[i].slices);
                if (problem)
                    return FAIL(bug, "%s: %s %dx%dx%d: %s", dev.name.UTF8String, formats[f].name, depthCases[i].w, depthCases[i].h,
                                depthCases[i].slices, problem.UTF8String);
            }
            const struct { int w, h, levels, slices; } stencilCases[] = {{32, 64, 7, 1}, {32, 16, 3, 2}};
            for (size_t i = 0; i < 2; i++) {
                NSString *problem = checkStencil(&c, lib, formats[f].format, stencilCases[i].w, stencilCases[i].h, stencilCases[i].levels,
                                                 stencilCases[i].slices);
                if (problem)
                    return FAIL(bug, "%s: %s %dx%dx%d: %s", dev.name.UTF8String, formats[f].name, stencilCases[i].w, stencilCases[i].h,
                                stencilCases[i].slices, problem.UTF8String);
            }
        }
        return PASS(bug, "%s: depth reads in shaders and stencil through blits, shaders and the depth unit agree on every level and slice "
                         "(2D and 2D array, both formats)", dev.name.UTF8String);
    }
}
