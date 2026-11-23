// s86-intel-argument-buffer-textures (MetalOldCompat item 79 + Intel adapter INTEL_IVB_ARGUMENT_BUFFER_TEXTURES): textures and
// samplers inside argument buffers on the Ivy Bridge driver, which has no argument-buffer runtime (items 46, 47).
// WebKit's WebGPU puts every bind group in an argument buffer, textures and samplers too: a fragment function that
// samples `struct { texture2d<float, sample> global0 [[id(0)]]; sampler global1 [[id(1)]]; }` crashed the compiler
// service (IGILair_ldst_handling, a null intrinsic name: the back end can't load a texture from memory), so Safari's
// WebGPU render pipelines failed ("uncaptured error", device lost). Checked: (1) that fragment function samples a 2x2
// texture through such an argument buffer; (2) a texture the app bound itself at the index the shim borrows for it is
// back for the next draw that reads it (one encoder, three draws side by side); (3) a compute kernel reads and samples a
// texture and writes through a buffer reference of the same argument buffer; (4) the WebGPU CTS's texel readback kernel
// as WebKit writes it, which copies the texture into a local (`texture2d<float> t = ab.t;`, an i64 load of the
// metal::texture2d struct, then inttoptr), next to a `constant` struct reference and an unused sampler, and asks the
// texture's size: before the adapter followed such copies the pipeline failed ("Compilation failed"), so every CTS
// case that reads texels back on the GPU (BC and depth formats) compared against zeros. Stock OCLP: FAIL (pipeline
// creation fails or the compiler crashes). Fixed: PASS. On GPUs with argument buffers of their own (Haswell, GCN,
// Kepler) it checks their native path. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const source =
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 position [[position]]; float2 uv; };\n"
    "vertex VOut vs(uint vid [[vertex_id]]) {\n"
    "    float2 q = float2((vid << 1) & 2, vid & 2);\n"
    "    VOut o; o.position = float4(q * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(q.x, 1.0 - q.y); return o;\n"
    "}\n"
    "struct FragmentBindings { texture2d<float, access::sample> global0 [[id(0)]]; sampler global1 [[id(1)]]; };\n"
    "fragment float4 sampled(VOut in [[stage_in]], constant FragmentBindings &b [[buffer(0)]]) {\n"
    "    return b.global0.sample(b.global1, in.uv);\n"
    "}\n"
    "fragment float4 direct(VOut in [[stage_in]], texture2d<float> t [[texture(30)]]) { return t.read(uint2(0, 0)); }\n"
    "struct ComputeBindings {\n"
    "    texture2d<float> t [[id(0)]];\n"
    "    device array<float4, 1> &out [[id(1)]];\n"
    "    uint outLength [[id(2)]];\n"
    "    sampler s [[id(3)]];\n"
    "};\n"
    "kernel void k(constant ComputeBindings &b [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint i = g.y * 2u + g.x;\n"
    "    uint last = b.outLength / 16u - 1u;\n"
    "    b.out[min(2u * i, last)] = b.t.read(g);\n"
    "    b.out[min(2u * i + 1u, last)] = b.t.sample(b.s, (float2(g) + 0.5) / 2.0, level(0.0));\n"
    "}\n"
    "struct Params { uint perTexel; };\n"
    "struct ReadbackBindings {\n"
    "    const constant Params &params [[id(0)]];\n"
    "    texture2d<float, access::sample> t [[id(1)]];\n"
    "    sampler unused [[id(2)]];\n"
    "    device array<float4, 1> &out [[id(3)]];\n"
    "    uint paramsLength [[id(4)]];\n"
    "    uint outLength [[id(5)]];\n"
    "};\n"
    "kernel void readback(uint3 g [[thread_position_in_grid]], constant ReadbackBindings &ab [[buffer(0)]]) {\n"
    "    const constant Params &params = ab.params;\n"
    "    texture2d<float, access::sample> t = ab.t;\n"
    "    sampler unused = ab.unused;\n"
    "    uint outLength = ab.outLength;\n"
    "    device array<float4, 1> &out = ab.out;\n"
    "    (void)unused;\n"
    "    uint2 size = uint2(t.get_width(min(t.get_num_mip_levels(), 0u)), t.get_height(min(t.get_num_mip_levels(), 0u)));\n"
    "    uint i = g.z * size.x * size.y * params.perTexel + g.y * size.x * params.perTexel + g.x;\n"
    "    out[min(i, outLength / 16u - 1u)] = t.read(uint2(g.x / params.perTexel, g.y), 0);\n"
    "}\n";

static const uint8_t texels[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}};

static BOOL near(const uint8_t *a, const uint8_t *b) {
    for (int c = 0; c < 4; c++)
        if (abs((int)a[c] - (int)b[c]) > 2) return NO;
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s86-intel-argument-buffer-textures";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:source] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", name, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> image = [dev newTextureWithDescriptor:td];
        [image replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
        MTLTextureDescriptor *gd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        gd.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> gray = [dev newTextureWithDescriptor:gd];
        const uint8_t grayTexel[4] = {128, 128, 128, 255};
        [gray replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:grayTexel bytesPerRow:4];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];

        // 1 + 2: three 4x4 draws side by side in one encoder: direct (the app's texture at 30), sampled, direct again
        id<MTLFunction> sampledFn = [lib newFunctionWithName:@"sampled"];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        pd.fragmentFunction = sampledFn;
        id<MTLRenderPipelineState> sampledPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!sampledPipe) return FAIL(bug, "%s: pipeline sampling through an argument buffer: %s", name, error.localizedDescription.UTF8String);
        pd.fragmentFunction = [lib newFunctionWithName:@"direct"];
        id<MTLRenderPipelineState> directPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!directPipe) return FAIL(bug, "%s: pipeline with texture(30): %s", name, error.localizedDescription.UTF8String);
        id<MTLArgumentEncoder> fe = [sampledFn newArgumentEncoderWithBufferIndex:0];
        if (!fe) return FAIL(bug, "%s: no argument encoder for the fragment function", name);
        id<MTLBuffer> fragmentBindings = [dev newBufferWithLength:MAX(fe.encodedLength, (NSUInteger)16) options:MTLResourceStorageModeShared];
        [fe setArgumentBuffer:fragmentBindings offset:0];
        [fe setTexture:image atIndex:0];
        [fe setSamplerState:sampler atIndex:1];

        enum { W = 12, H = 4 };
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModeManaged;  // a discrete GPU renders into its own memory: managed + synchronize
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setFragmentTexture:gray atIndex:30];
        for (int d = 0; d < 3; d++) {
            [re setViewport:(MTLViewport){4.0 * d, 0, 4, 4, 0, 1}];
            if (d == 1) {
                [re setRenderPipelineState:sampledPipe];
                [re setFragmentBuffer:fragmentBindings offset:0 atIndex:0];
                [re useResource:image usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
            } else
                [re setRenderPipelineState:directPipe];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [re endEncoding];
        id<MTLBlitCommandEncoder> sync = [cb blitCommandEncoder];
        [sync synchronizeResource:target];
        [sync endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: draws: command buffer failed", name);
        uint8_t pixels[W * H * 4];
        [target getBytes:pixels bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                const uint8_t *p = pixels + (y * W + x) * 4, *want = x < 4 || x >= 8 ? grayTexel : texels[(y / 2) * 2 + (x - 4) / 2];
                if (!near(p, want))
                    return FAIL(bug, "%s: %s draw: pixel %d,%d = (%u, %u, %u, %u), want (%u, %u, %u, %u)%s", name,
                                x < 4 ? "first direct" : x < 8 ? "argument-buffer" : "second direct", x, y, p[0], p[1], p[2], p[3],
                                want[0], want[1], want[2], want[3],
                                x >= 8 ? " (the app's texture at index 30 wasn't put back after the argument-buffer draw)" : "");
            }

        // 3: a kernel reads and samples the texture and writes through a buffer reference of the same argument buffer
        id<MTLFunction> kernel = [lib newFunctionWithName:@"k"];
        id<MTLComputePipelineState> cp = [dev newComputePipelineStateWithFunction:kernel error:&error];
        if (!cp) return FAIL(bug, "%s: kernel: %s", name, error.localizedDescription.UTF8String);
        id<MTLArgumentEncoder> ce = [kernel newArgumentEncoderWithBufferIndex:0];
        if (!ce) return FAIL(bug, "%s: no argument encoder for the kernel", name);
        id<MTLBuffer> out = [dev newBufferWithLength:8 * 16 options:MTLResourceStorageModeShared];
        memset(out.contents, 0, out.length);
        id<MTLBuffer> computeBindings = [dev newBufferWithLength:MAX(ce.encodedLength, (NSUInteger)16) options:MTLResourceStorageModeShared];
        [ce setArgumentBuffer:computeBindings offset:0];
        [ce setTexture:image atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        *(uint32_t *)[ce constantDataAtIndex:2] = (uint32_t)out.length;
        [ce setSamplerState:sampler atIndex:3];
        cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> co = [cb computeCommandEncoder];
        [co setComputePipelineState:cp];
        [co setBuffer:computeBindings offset:0 atIndex:0];
        [co useResource:image usage:MTLResourceUsageRead];
        [co useResource:out usage:MTLResourceUsageWrite];
        [co dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [co endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: kernel: command buffer failed", name);
        const float *o = out.contents;
        for (int i = 0; i < 8; i++)
            for (int c = 0; c < 4; c++)
                if (fabsf(o[i * 4 + c] - texels[i / 2][c] / 255.0f) > 0.01f)
                    return FAIL(bug, "%s: kernel: %s of texel %d = (%g, %g, %g, %g), want (%g, %g, %g, %g)", name, i % 2 ? "sample" : "read", i / 2,
                                o[i * 4], o[i * 4 + 1], o[i * 4 + 2], o[i * 4 + 3], texels[i / 2][0] / 255.0, texels[i / 2][1] / 255.0,
                                texels[i / 2][2] / 255.0, texels[i / 2][3] / 255.0);

        // 4: WebKit's texel readback kernel (the texture copied into a local)
        id<MTLFunction> rk = [lib newFunctionWithName:@"readback"];
        id<MTLComputePipelineState> rp = [dev newComputePipelineStateWithFunction:rk error:&error];
        if (!rp) return FAIL(bug, "%s: readback kernel (texture copied out of the argument buffer): %s", name, error.localizedDescription.UTF8String);
        id<MTLArgumentEncoder> re4 = [rk newArgumentEncoderWithBufferIndex:0];
        if (!re4) return FAIL(bug, "%s: no argument encoder for the readback kernel", name);
        id<MTLBuffer> params = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        *(uint32_t *)params.contents = 1;
        id<MTLBuffer> texelsOut = [dev newBufferWithLength:4 * 16 options:MTLResourceStorageModeShared];
        memset(texelsOut.contents, 0, texelsOut.length);
        id<MTLBuffer> readbackBindings = [dev newBufferWithLength:MAX(re4.encodedLength, (NSUInteger)16) options:MTLResourceStorageModeShared];
        [re4 setArgumentBuffer:readbackBindings offset:0];
        [re4 setBuffer:params offset:0 atIndex:0];
        [re4 setTexture:image atIndex:1];
        [re4 setSamplerState:sampler atIndex:2];
        [re4 setBuffer:texelsOut offset:0 atIndex:3];
        *(uint32_t *)[re4 constantDataAtIndex:4] = 4;
        *(uint32_t *)[re4 constantDataAtIndex:5] = (uint32_t)texelsOut.length;
        cb = [queue commandBuffer];
        co = [cb computeCommandEncoder];
        [co setComputePipelineState:rp];
        [co setBuffer:readbackBindings offset:0 atIndex:0];
        [co dispatchThreads:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [co endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: readback kernel: command buffer failed", name);
        const float *r = texelsOut.contents;
        for (int i = 0; i < 4; i++)
            for (int c = 0; c < 4; c++)
                if (fabsf(r[i * 4 + c] - texels[i][c] / 255.0f) > 0.01f)
                    return FAIL(bug, "%s: readback kernel: texel %d = (%g, %g, %g, %g), want (%g, %g, %g, %g)", name, i, r[i * 4], r[i * 4 + 1],
                                r[i * 4 + 2], r[i * 4 + 3], texels[i][0] / 255.0, texels[i][1] / 255.0, texels[i][2] / 255.0, texels[i][3] / 255.0);

        return PASS(bug, "%s: a fragment function samples, a kernel reads and samples, and WebKit's readback kernel reads a texture "
                         "through argument buffers, and the app's own texture at the borrowed index is back for the next draw", name);
    }
}
