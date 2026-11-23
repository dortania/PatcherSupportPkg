// i84-intel-argument-buffer-render-offsets (Intel adapter, IntelTextureAtomics.dylib, INTEL_IVB_ARGUMENT_BUFFER_OFFSETS):
// constants after buffer, texture and sampler members of an argument buffer, read in vertex and fragment functions on
// the Ivy Bridge driver. There the 11.7.10 back end laid the struct out with 4-byte pointers, where the C layout (which
// compute kernels read, and MetalOldCompat's encoder writes) has 8: each constant came from 4 bytes early per pointer
// before it, the high half of a pointer's token. WebKit's WebGPU keeps each storage buffer's length right after it,
// and its fragment functions clamp their writes with it, so once a buffer's token held a 4 or more every write went to
// element 0 (CTS rendering,draw:vertex_attributes,basic, from a page's fourth pipeline on). Checked: a vertex function
// reads two constants after a buffer reference and a pointer, and a fragment function reads constants after a
// reference, a texture and a sampler (WebKit's bind group shape), each passing what it read on to a buffer the test
// reads back. Stock OCLP: FAIL (no argument buffers). Without the fix: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VertexBindings {\n"
    "    device array<uint, 1> &unused [[id(0)]];\n"
    "    constant uint4 *table [[id(1)]];\n"
    "    uint a [[id(2)]];\n"
    "    uint b [[id(3)]];\n"
    "};\n"
    "struct VOut { float4 position [[position]]; uint a [[flat]]; uint b [[flat]]; uint t [[flat]]; };\n"
    "vertex VOut vs(constant VertexBindings &v [[buffer(29)]]) {\n"
    "    VOut o; o.position = float4(0.0, 0.0, 0.5, 1.0); o.a = v.a; o.b = v.b; o.t = v.table[0].y; return o;\n"
    "}\n"
    "struct FragmentBindings {\n"
    "    device array<uint, 1> &out [[id(0)]];\n"
    "    texture2d<float> image [[id(1)]];\n"
    "    sampler smp [[id(2)]];\n"
    "    uint outLength [[id(3)]];\n"
    "    uint c [[id(4)]];\n"
    "};\n"
    "fragment void fs(VOut in [[stage_in]], constant FragmentBindings &f [[buffer(0)]]) {\n"
    "    uint last = f.outLength / 4u - 1u;\n"
    "    f.out[min(0u, last)] = in.a;\n"
    "    f.out[min(1u, last)] = in.b;\n"
    "    f.out[min(2u, last)] = in.t;\n"
    "    f.out[min(3u, last)] = f.c;\n"
    "    f.out[min(4u, last)] = f.outLength;\n"
    "    f.out[min(5u, last)] = uint(f.image.sample(f.smp, float2(0.5)).r * 255.0 + 0.5);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i84-intel-argument-buffer-render-offsets";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: compile: %s", name, error.localizedDescription.UTF8String);
        id<MTLFunction> vf = [lib newFunctionWithName:@"vs"], ff = [lib newFunctionWithName:@"fs"];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf;
        pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
        pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, error.localizedDescription.UTF8String);

        enum { N = 8 };
        id<MTLBuffer> out = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
        memset(out.contents, 0xee, out.length);
        id<MTLBuffer> unused = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        const uint32_t table[4] = {5, 4242, 7, 8};
        id<MTLBuffer> tableBuffer = [dev newBufferWithBytes:table length:sizeof table options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> image = [dev newTextureWithDescriptor:td];
        const uint8_t texel[4] = {200, 0, 0, 255};
        [image replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:texel bytesPerRow:4];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];

        id<MTLArgumentEncoder> ve = [vf newArgumentEncoderWithBufferIndex:29], fe = [ff newArgumentEncoderWithBufferIndex:0];
        if (!ve || !fe) return FAIL(bug, "%s: no argument encoder", name);
        id<MTLBuffer> vb = [dev newBufferWithLength:MAX(ve.encodedLength, (NSUInteger)32) options:MTLResourceStorageModeShared];
        id<MTLBuffer> fb = [dev newBufferWithLength:MAX(fe.encodedLength, (NSUInteger)48) options:MTLResourceStorageModeShared];
        [ve setArgumentBuffer:vb offset:0];
        [ve setBuffer:unused offset:0 atIndex:0];
        [ve setBuffer:tableBuffer offset:0 atIndex:1];
        *(uint32_t *)[ve constantDataAtIndex:2] = 1111;
        *(uint32_t *)[ve constantDataAtIndex:3] = 2222;
        [fe setArgumentBuffer:fb offset:0];
        [fe setBuffer:out offset:0 atIndex:0];
        [fe setTexture:image atIndex:1];
        [fe setSamplerState:smp atIndex:2];
        *(uint32_t *)[fe constantDataAtIndex:3] = N * 4;
        *(uint32_t *)[fe constantDataAtIndex:4] = 3333;

        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModePrivate;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = [dev newTextureWithDescriptor:rd];
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:ps];
        [re setVertexBuffer:vb offset:0 atIndex:29];
        [re setFragmentBuffer:fb offset:0 atIndex:0];
        [re useResource:unused usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [re useResource:tableBuffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [re useResource:out usage:MTLResourceUsageWrite stages:MTLRenderStageFragment];
        [re useResource:image usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
        [re endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);

        const uint32_t *o = out.contents;
        const struct { const char *what; uint32_t want; } checks[] = {
            {"vertex: constant a after a reference and a pointer", 1111},
            {"vertex: constant b", 2222},
            {"vertex: table[0].y through the pointer", 4242},
            {"fragment: constant c after a reference, a texture, a sampler and the length", 3333},
            {"fragment: the length after a reference, a texture and a sampler", N * 4},
            {"fragment: the texture's texel", 200},
        };
        for (int i = 0; i < 6; i++)
            if (o[i] != checks[i].want)
                return FAIL(bug, "%s: %s read %u, want %u (out = %u %u %u %u %u %u)", name, checks[i].what, o[i], checks[i].want, o[0], o[1],
                            o[2], o[3], o[4], o[5]);
        return PASS(bug, "%s: vertex and fragment functions read constants after buffer, texture and sampler members of argument buffers right", name);
    }
}
