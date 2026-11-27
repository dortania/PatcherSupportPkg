// s95-intel-vertex-buffer-moves: a vertex buffer at an index item 47's hidden argument-buffer bindings take (MoltenVK
// binds vertex buffers from 30 down) must still feed stage_in; on Ivy Bridge the vertex function read the argument
// buffer's pointees there (Godot drew nothing). Fix: MetalOldCompat item 92 MTLSHIM_IVB_VERTEX_BUFFER_MOVES.
// Checks: positions from index 30 and from 29 next to an argument buffer of two pointers, and the app's own buffer at the
// index a layout moved to is put back for the next draw. Argument: GPU name.
#import "repro.h"

enum { Side = 8, MovedTo = 28 };  // the moves take the highest free index: 28 next to the hidden 30 and 29
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Tint { float4 c; };\n"
    "struct Set0 { constant void *pad [[id(0)]]; constant Tint *tint [[id(1)]]; };\n"  // MoltenVK pads unused bindings
    "struct VIn { float2 p [[attribute(0)]]; };\n"
    "struct VOut { float4 pos [[position]]; float4 c; };\n"
    "vertex VOut tinted(VIn in [[stage_in]], constant Set0 &s0 [[buffer(0)]]) { return { float4(in.p, 0, 1), s0.tint->c }; }\n"
    "vertex VOut blue(VIn in [[stage_in]]) { return { float4(in.p, 0, 1), float4(0, 0, 1, 1) }; }\n"
    "fragment float4 colour(VOut in [[stage_in]]) { return in.c; }\n";

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *vertex, NSUInteger vertexBufferIndex, NSError **err) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2;
    vd.attributes[0].bufferIndex = vertexBufferIndex;
    vd.layouts[vertexBufferIndex].stride = 8;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:vertex];
    pd.fragmentFunction = [lib newFunctionWithName:@"colour"];
    pd.vertexDescriptor = vd;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    return [dev newRenderPipelineStateWithDescriptor:pd error:err];
}
static MTLArgumentDescriptor *pointerArgument(NSUInteger index) {
    MTLArgumentDescriptor *d = [MTLArgumentDescriptor argumentDescriptor];
    d.dataType = MTLDataTypePointer;
    d.index = index;
    d.access = MTLBindingAccessReadOnly;
    return d;
}
static void pixel(id<MTLTexture> t, NSUInteger x, NSUInteger y, uint8_t px[4]) {
    [t getBytes:px bytesPerRow:Side * 4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s95-intel-vertex-buffer-moves";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLRenderPipelineState> blue = pipeline(dev, lib, @"blue", MovedTo, &err);
    if (!blue) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    const float fullScreen[6] = {-1, -1, 3, -1, -1, 3}, corner[6] = {-1, -1, -0.5f, -1, -1, -0.5f}, green[4] = {0, 1, 0, 1};
    id<MTLBuffer> fullBuffer = [dev newBufferWithBytes:fullScreen length:sizeof fullScreen options:MTLResourceStorageModeShared];
    id<MTLBuffer> cornerBuffer = [dev newBufferWithBytes:corner length:sizeof corner options:MTLResourceStorageModeShared];
    id<MTLBuffer> tint = [dev newBufferWithBytes:green length:sizeof green options:MTLResourceStorageModeShared];
    id<MTLArgumentEncoder> encoder = [dev newArgumentEncoderWithArguments:@[pointerArgument(0), pointerArgument(1)]];
    if (!encoder) return FAIL(bug, "%s: no argument encoder", name);
    id<MTLBuffer> arguments = [dev newBufferWithLength:encoder.encodedLength options:MTLResourceStorageModeShared];
    [encoder setArgumentBuffer:arguments offset:0];
    [encoder setBuffer:tint offset:0 atIndex:1];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    for (NSUInteger index = 30; index >= 29; index--) {
        id<MTLRenderPipelineState> tinted = pipeline(dev, lib, @"tinted", index, &err);
        if (!tinted) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:Side height:Side mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setVertexBuffer:cornerBuffer offset:0 atIndex:MovedTo];  // the app's own, for the blue draw after
        [re setRenderPipelineState:tinted];
        [re setVertexBuffer:fullBuffer offset:0 atIndex:index];
        [re setVertexBuffer:arguments offset:0 atIndex:0];
        [re useResource:tint usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re setRenderPipelineState:blue];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:target];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: vertex buffer at %lu: command buffer failed", name, (unsigned long)index);
        uint8_t centre[4], bottomLeft[4];
        pixel(target, Side / 2, Side / 2, centre);
        pixel(target, 0, Side - 1, bottomLeft);
        if (centre[0] != 0 || centre[1] != 255 || centre[2] != 0)
            return FAIL(bug, "%s: positions from vertex buffer %lu next to an argument buffer: centre (%u, %u, %u), want green", name,
                        (unsigned long)index, centre[0], centre[1], centre[2]);
        if (bottomLeft[2] != 255 || bottomLeft[1] != 0)
            return FAIL(bug, "%s: the app's vertex buffer at %d after that draw: corner (%u, %u, %u), want blue", name, MovedTo,
                        bottomLeft[0], bottomLeft[1], bottomLeft[2]);
    }
    return PASS(bug, "%s: stage_in reads vertex buffers at 30 and 29 next to an argument buffer's hidden bindings, and the app's at %d is put back",
                name, MovedTo);
}}
