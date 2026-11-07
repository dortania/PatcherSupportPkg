// i06-intel-vertex-float3-input (Intel adapter, IntelTextureAtomics.dylib): a component of a float3 vertex input copied
// straight to an output with the 3802 Intel compiler. The back end declares the input but drops its move into a register,
// so the output comes from one nothing set: 0 or garbage. Float2 and float4 inputs and any arithmetic on the input are
// right. ANGLE's vertex shaders do that copy for `out0 = in0.x` on a vec3 attribute (dEQP swizzles_vec3 *_vertex,
// conversions_vector_to_scalar vec3_to_float_vertex: wrong values in Chrome and Safari).
// Vertex functions write in.a.x, .y or .z of a float3 input (Float3 at attribute 1 after a float4, Float3 at attribute 0,
// Half3 read as float3) to a varying, and the fragment function writes it to an R32Float target.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static float draw(id<MTLDevice> dev, id<MTLCommandQueue> q, int first, char component, MTLVertexFormat format, NSError **error) {
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct In { %s };\nstruct V { float4 p [[position]]; float o; };\n"
        "vertex V v(In in [[stage_in]]) { V r; r.p = in.pos; r.o = in.a.%c; return r; }\n"
        "fragment float4 f(V in [[stage_in]]) { return float4(in.o, 0, 0, 1); }\n%@",
        first ? "float3 a [[attribute(0)]]; float4 pos [[attribute(1)]];" : "float4 pos [[attribute(0)]]; float3 a [[attribute(1)]];",
        component, reproUniqueComment()];
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:error];
    if (!lib) return NAN;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    int pos = first ? 1 : 0, a = first ? 0 : 1;
    vd.attributes[pos].format = MTLVertexFormatFloat4;
    vd.attributes[pos].bufferIndex = 0;
    vd.attributes[a].format = format;
    vd.attributes[a].bufferIndex = 1;
    vd.layouts[0].stride = 16;
    vd.layouts[1].stride = format == MTLVertexFormatHalf3 ? 8 : 12;  // Metal on macOS (the AMD driver) wants multiples of 4
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f"];
    pd.vertexDescriptor = vd;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:error];
    if (!ps) return NAN;
    const float positions[12] = {-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1};
    float floats[9];
    __fp16 halves[12] = {0};  // x, y, z and a pad half per vertex
    for (int i = 0; i < 9; i++) floats[i] = halves[i / 3 * 4 + i % 3] = 0.25f * (i % 3 + 1);  // x 0.25, y 0.5, z 0.75
    id<MTLBuffer> pb = [dev newBufferWithBytes:positions length:sizeof positions options:MTLResourceStorageModeShared];
    id<MTLBuffer> ab = format == MTLVertexFormatHalf3 ? [dev newBufferWithBytes:halves length:sizeof halves options:MTLResourceStorageModeShared]
                                                      : [dev newBufferWithBytes:floats length:sizeof floats options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:NO];
    cd.usage = MTLTextureUsageRenderTarget;
    cd.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [dev newTextureWithDescriptor:cd];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:ps];
    [enc setVertexBuffer:pb offset:0 atIndex:0];
    [enc setVertexBuffer:ab offset:0 atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:target];
    [blit endEncoding];
    if (!reproRun(cb)) return NAN;
    float value;
    [target getBytes:&value bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    return value;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i06-intel-vertex-float3-input";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const struct { int first; char component; MTLVertexFormat format; const char *name; } kCases[] = {
            {0, 'x', MTLVertexFormatFloat3, "Float3 at attribute 1, .x"}, {0, 'y', MTLVertexFormatFloat3, "Float3 at attribute 1, .y"},
            {0, 'z', MTLVertexFormatFloat3, "Float3 at attribute 1, .z"}, {1, 'x', MTLVertexFormatFloat3, "Float3 at attribute 0, .x"},
            {1, 'z', MTLVertexFormatFloat3, "Float3 at attribute 0, .z"}, {0, 'y', MTLVertexFormatHalf3, "Half3 as float3, .y"},
        };
        for (size_t i = 0; i < sizeof kCases / sizeof *kCases; i++) {
            NSError *error = nil;
            float want = 0.25f * (kCases[i].component - 'x' + 1);
            float got = draw(dev, q, kCases[i].first, kCases[i].component, kCases[i].format, &error);
            if (isnan(got)) return FAIL(bug, "%s: %s: no pipeline or draw: %s", dev.name.UTF8String, kCases[i].name, error.localizedDescription.UTF8String);
            if (got != want) return FAIL(bug, "%s: %s copied to an output gave %g, want %g", dev.name.UTF8String, kCases[i].name, got, want);
        }
        return PASS(bug, "%s: float3 vertex input components copied to outputs arrive (Float3 at attributes 0 and 1, Half3)", dev.name.UTF8String);
    }
}
