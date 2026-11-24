// s71-intel-depth-clears: depth clears at level or slice 1+ must land, exactly; Ivy Bridge kept the old depth, and
// Depth32Float kept ~16 mantissa bits. Fix: MetalOldCompat item 64 MTLSHIM_DEPTH_CLEAR_DRAW. Checks: a cube shadow map
// over two frames, repeated clears, exact 2D, 4x and depth-stencil clears. Argument: GPU name.
#import "repro.h"
#include <math.h>

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void readCube(depthcube<float> t [[texture(0)]], device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i < 12u) o[i] = t.read(i & 1u ? uint2(12, 12) : uint2(2, 2), i / 2u);\n"  // even: occluder, odd: background
    "}\n"
    "kernel void readLevel1(depth2d<float> t [[texture(0)]], device float *o [[buffer(0)]]) { o[0] = t.read(uint2(3, 3), 1); }\n"
    "kernel void readFace3(depthcube<float> t [[texture(0)]], device float *o [[buffer(0)]]) { o[0] = t.read(uint2(5, 1), 3); }\n"
    "kernel void read2D(depth2d<float> t [[texture(0)]], device float *o [[buffer(0)]]) { o[0] = t.read(uint2(7, 9)); }\n"
    "kernel void readMS(depth2d_ms<float> t [[texture(0)]], device float *o [[buffer(0)]]) { o[0] = t.read(uint2(7, 9), 3); }\n"
    "kernel void readColor(texture2d<float> t [[texture(0)]], device float4 *o [[buffer(0)]]) { o[0] = t.read(uint2(12, 12)); }\n"
    "vertex float4 quarter(uint v [[vertex_id]]) { float2 c[4] = { float2(-1, 1), float2(0, 1), float2(-1, 0), float2(0, 0) }; return float4(c[v], 0.5, 1); }\n"
    "fragment float4 white() { return float4(1); }\n";

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> lib;

static id<MTLTexture> texture(MTLTextureType type, MTLPixelFormat format, NSUInteger levels, NSUInteger samples) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = format;
    td.width = td.height = 16;
    td.mipmapLevelCount = levels;
    td.sampleCount = samples;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:td];
}
static void clearPass(id<MTLCommandBuffer> cb, id<MTLTexture> t, NSUInteger level, NSUInteger slice, double depth) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t;
    rp.depthAttachment.level = level;
    rp.depthAttachment.slice = slice;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.depthAttachment.clearDepth = depth;
    if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
        rp.stencilAttachment.texture = t;
        rp.stencilAttachment.level = level;
        rp.stencilAttachment.slice = slice;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
    }
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
}
// Runs kernel `name` on texture t into a fresh buffer of `bytes`, in its own command buffer, and returns the buffer
static id<MTLBuffer> readBack(NSString *name, id<MTLTexture> t, NSUInteger threads, NSUInteger bytes) {
    NSError *err = nil;
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&err];
    id<MTLBuffer> out = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    memset(out.contents, 0xff, bytes);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setTexture:t atIndex:0];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
    [ce endEncoding];
    reproRun(cb);
    return out;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s71-intel-depth-clears";
    dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    queue = [dev newCommandQueue];

    // the shadow cube
    id<MTLTexture> cube = texture(MTLTextureTypeCube, MTLPixelFormatDepth32Float, 1, 1);
    id<MTLTexture> color = texture(MTLTextureType2D, MTLPixelFormatRGBA8Unorm, 1, 1);
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [lib newFunctionWithName:@"quarter"];
    rpd.fragmentFunction = [lib newFunctionWithName:@"white"];
    rpd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> occluder = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!occluder) return FAIL(bug, "%s: render pipeline: %s", name, err.localizedDescription.UTF8String);
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    dsd.depthCompareFunction = MTLCompareFunctionLess;
    dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> less = [dev newDepthStencilStateWithDescriptor:dsd];
    // like a renderer's frames: the shadow passes and the pass that samples the cube in one command buffer
    id<MTLComputePipelineState> cubeReader = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readCube"] error:&err];
    id<MTLBuffer> faceBuffer = [dev newBufferWithLength:48 options:MTLResourceStorageModeShared];
    for (int frame = 0; frame < 2; frame++) {
        id<MTLCommandBuffer> fb = [queue commandBuffer];
        for (NSUInteger face = frame ? 1 : 0; face < 6; face++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.depthAttachment.texture = cube;
            rp.depthAttachment.slice = face;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = frame ? 1.0 : 0.25;
            id<MTLRenderCommandEncoder> re = [fb renderCommandEncoderWithDescriptor:rp];
            if (frame) {
                [re setRenderPipelineState:occluder];
                [re setDepthStencilState:less];
                [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
            [re endEncoding];
        }
        id<MTLComputeCommandEncoder> ce = [fb computeCommandEncoder];
        [ce setComputePipelineState:cubeReader];
        [ce setTexture:cube atIndex:0];
        [ce setBuffer:faceBuffer offset:0 atIndex:0];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(12, 1, 1)];
        [ce endEncoding];
        if (!reproRun(fb)) return FAIL(bug, "%s: shadow frame %d failed", name, frame + 1);
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *cp = [MTLRenderPassDescriptor renderPassDescriptor];
    cp.colorAttachments[0].texture = color;
    cp.colorAttachments[0].loadAction = MTLLoadActionClear;
    cp.colorAttachments[0].storeAction = MTLStoreActionStore;
    cp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 0.8);
    [[cb renderCommandEncoderWithDescriptor:cp] endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: color clear failed", name);
    const float *faces = faceBuffer.contents;
    for (int i = 0; i < 12; i++) {
        float want = i < 2 ? 0.25f : i & 1 ? 1.0f : 0.5f;
        if (faces[i] != want)
            return FAIL(bug, "%s: shadow cube face %d (faces 1-5 cleared to 1.0 again, occluder at 0.5): %s reads %.9g, want %g", name, i / 2,
                        i & 1 ? "the cleared background" : "the occluder", faces[i], want);
    }
    // a pass with a color target: the clear's draw mustn't touch it
    cb = [queue commandBuffer];
    MTLRenderPassDescriptor *withColor = [MTLRenderPassDescriptor renderPassDescriptor];
    withColor.colorAttachments[0].texture = color;
    withColor.colorAttachments[0].loadAction = MTLLoadActionLoad;
    withColor.colorAttachments[0].storeAction = MTLStoreActionStore;
    withColor.depthAttachment.texture = cube;
    withColor.depthAttachment.slice = 2;
    withColor.depthAttachment.loadAction = MTLLoadActionClear;
    withColor.depthAttachment.storeAction = MTLStoreActionStore;
    withColor.depthAttachment.clearDepth = 0.875;
    [[cb renderCommandEncoderWithDescriptor:withColor] endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: color pass failed", name);
    faces = readBack(@"readCube", cube, 12, 48).contents;
    if (faces[5] != 0.875f || faces[4] != 0.875f) return FAIL(bug, "%s: face 2 cleared to 0.875 with a color target reads %.9g / %.9g", name, faces[4], faces[5]);
    const float *rgba = readBack(@"readColor", color, 1, 16).contents;
    const float wantColor[4] = {0.2f, 0.4f, 0.6f, 0.8f};
    for (int c = 0; c < 4; c++)
        if (fabsf(rgba[c] - wantColor[c]) > 0.5f / 255)
            return FAIL(bug, "%s: the color target of the pass clearing face 2 changed: channel %d is %g, want %g", name, c, rgba[c], wantColor[c]);

    // re-clears of a mip level and of a Depth16 face
    id<MTLTexture> mips = texture(MTLTextureType2D, MTLPixelFormatDepth32Float, 2, 1);
    id<MTLTexture> cube16 = texture(MTLTextureTypeCube, MTLPixelFormatDepth16Unorm, 1, 1);
    cb = [queue commandBuffer];
    clearPass(cb, mips, 1, 0, 0.25);
    for (NSUInteger face = 0; face < 6; face++) clearPass(cb, cube16, 0, face, 0.25);
    if (!reproRun(cb)) return FAIL(bug, "%s: first clears failed", name);
    readBack(@"readLevel1", mips, 1, 4);
    readBack(@"readFace3", cube16, 1, 4);
    cb = [queue commandBuffer];
    clearPass(cb, mips, 1, 0, 0.75);
    clearPass(cb, cube16, 0, 3, 0.75);
    if (!reproRun(cb)) return FAIL(bug, "%s: second clears failed", name);
    float level1 = *(const float *)readBack(@"readLevel1", mips, 1, 4).contents;
    if (level1 != 0.75f) return FAIL(bug, "%s: level 1 of a mipmapped Depth32Float texture cleared to 0.75 again reads %.9g", name, level1);
    float face3 = *(const float *)readBack(@"readFace3", cube16, 1, 4).contents, want16 = (float)lrint(0.75 * 65535) / 65535.0f;
    if (fabsf(face3 - want16) > 0.5f / 65535) return FAIL(bug, "%s: face 3 of a Depth16Unorm cube cleared to 0.75 again reads %.9g, want %.9g", name, face3, want16);

    // exact clear depths
    struct { id<MTLTexture> t; double depth; NSString *reader; const char *what; } exact[] = {
        {texture(MTLTextureType2D, MTLPixelFormatDepth32Float, 1, 1), 0.05, @"read2D", "Depth32Float 2D"},
        {texture(MTLTextureType2DMultisample, MTLPixelFormatDepth32Float, 1, 4), 0.3, @"readMS", "4x multisampled Depth32Float"},
        {texture(MTLTextureType2D, MTLPixelFormatDepth32Float_Stencil8, 1, 1), 0.7, @"read2D", "Depth32Float_Stencil8 2D"}};
    for (int k = 0; k < 3; k++) {
        cb = [queue commandBuffer];
        clearPass(cb, exact[k].t, 0, 0, exact[k].depth);
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: clear failed", name, exact[k].what);
        float got = *(const float *)readBack(exact[k].reader, exact[k].t, 1, 4).contents;
        if (got != (float)exact[k].depth)
            return FAIL(bug, "%s: %s cleared to %g reads %.9g, want %.9g", name, exact[k].what, exact[k].depth, got, (float)exact[k].depth);
    }
    return PASS(bug, "%s: depth clears land on cube faces and mip levels cleared again, at their exact depth, and leave color alone", name);
}}
