// i83-intel-argument-buffer-references: buffers an argument buffer holds as references must be bound on Haswell; they
// read zeros and lost writes (Safari WebGPU). Fix: IntelTextureAtomics INTEL_EMULATED_REFERENCE_FIX.
// Checks: refs with pointers, two argument buffers, plain buffers around one, WebKit bind groups. Argument: GPU name.
#import "repro.h"

static NSString *const source = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Mixed { device float4 *p0 [[id(0)]]; device array<float4, 1> &r1 [[id(1)]]; device float4 *p2 [[id(2)]];\n"
    "               device array<float4, 1> &r3 [[id(3)]]; };\n"
    "kernel void mixed(constant Mixed &b [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    b.p0[i] = float4(1, i, 0, 0); b.r1[i] = float4(2, i, 0, 0); b.p2[i] = float4(3, i, 0, 0); b.r3[i] = float4(4, i, 0, 0);\n"
    "}\n"
    "struct Pair { device float4 *p [[id(0)]]; device array<float4, 1> &r [[id(1)]]; };\n"
    "kernel void two(constant Pair &x [[buffer(0)]], constant Pair &y [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "    x.p[i] = float4(1, i, 0, 0); x.r[i] = float4(2, i, 0, 0); y.p[i] = float4(3, i, 0, 0); y.r[i] = float4(4, i, 0, 0);\n"
    "}\n"
    "kernel void between(device float4 *d [[buffer(0)]], constant Pair &x [[buffer(1)]], device float4 *e [[buffer(2)]],\n"
    "                    uint i [[thread_position_in_grid]]) {\n"
    "    d[i] = float4(1, i, 0, 0); x.p[i] = float4(2, i, 0, 0); x.r[i] = float4(3, i, 0, 0); e[i] = float4(4, i, 0, 0);\n"
    "}\n"
    "struct Group { texture2d<float> t [[id(0)]]; device array<float4, 1> &out [[id(1)]]; uint outLength [[id(2)]];\n"
    "               sampler s [[id(3)]]; };\n"
    "kernel void group(constant Group &b [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    b.out[min(i, b.outLength / 16u - 1u)] = float4(b.t.read(uint2(i % 2u, i / 2u)).rgb, float(b.outLength));\n"
    "}\n"
    "struct Tinted { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; const constant float4 &tint [[id(2)]]; };\n"
    "struct VOut { float4 position [[position]]; };\n"
    "vertex VOut fullscreen(uint v [[vertex_id]]) {\n"
    "    VOut o; o.position = float4(v == 1 ? 3.0 : -1.0, v == 2 ? 3.0 : -1.0, 0, 1); return o;\n"
    "}\n"
    "fragment float4 tinted(VOut in [[stage_in]], constant Tinted &b [[buffer(0)]]) {\n"
    "    return b.tint * b.t.sample(b.s, float2(0.5));\n"
    "}\n";

enum { N = 4 };

static id<MTLBuffer> zeroed(id<MTLDevice> dev, NSUInteger length) {
    id<MTLBuffer> b = [dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    memset(b.contents, 0, length);
    return b;
}

// out[k][i] must be (k + 1, i, 0, 0); NULL if so
static const char *checkFour(id<MTLBuffer> const out[4], const char *const names[4]) {
    static char why[256];
    for (int k = 0; k < 4; k++) {
        const float *o = out[k].contents;
        for (int i = 0; i < N; i++)
            if (o[i * 4] != k + 1 || o[i * 4 + 1] != i) {
                snprintf(why, sizeof why, "%s: element %d = (%g, %g), want (%d, %d)", names[k], i, o[i * 4], o[i * 4 + 1], k + 1, i);
                return why;
            }
    }
    return NULL;
}

static id<MTLBuffer> encodePair(id<MTLDevice> dev, id<MTLFunction> f, NSUInteger index, id<MTLBuffer> p, id<MTLBuffer> r) {
    id<MTLArgumentEncoder> e = [f newArgumentEncoderWithBufferIndex:index];
    id<MTLBuffer> ab = zeroed(dev, MAX(e.encodedLength, (NSUInteger)16));
    [e setArgumentBuffer:ab offset:0];
    [e setBuffer:p offset:0 atIndex:0];
    [e setBuffer:r offset:0 atIndex:1];
    return ab;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i83-intel-argument-buffer-references";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: compile: %s", name, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLComputePipelineState> ps[4];
        id<MTLFunction> fn[4];
        const char *kernels[4] = {"mixed", "two", "between", "group"};
        for (int k = 0; k < 4; k++) {
            fn[k] = [lib newFunctionWithName:@(kernels[k])];
            if (!(ps[k] = [dev newComputePipelineStateWithFunction:fn[k] error:&error]))
                return FAIL(bug, "%s: %s: pipeline: %s", name, kernels[k], error.localizedDescription.UTF8String);
        }

        // 1-3: four buffers each, written through pointers, references and plain buffer arguments
        for (int k = 0; k < 3; k++) {
            id<MTLBuffer> out[4];
            for (int j = 0; j < 4; j++) out[j] = zeroed(dev, N * 16);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps[k]];
            if (k == 0) {
                id<MTLArgumentEncoder> e = [fn[0] newArgumentEncoderWithBufferIndex:0];
                id<MTLBuffer> ab = zeroed(dev, MAX(e.encodedLength, (NSUInteger)16));
                [e setArgumentBuffer:ab offset:0];
                for (int j = 0; j < 4; j++) [e setBuffer:out[j] offset:0 atIndex:j];
                [ce setBuffer:ab offset:0 atIndex:0];
            } else if (k == 1) {
                [ce setBuffer:encodePair(dev, fn[1], 0, out[0], out[1]) offset:0 atIndex:0];
                [ce setBuffer:encodePair(dev, fn[1], 1, out[2], out[3]) offset:0 atIndex:1];
            } else {
                [ce setBuffer:out[0] offset:0 atIndex:0];
                [ce setBuffer:encodePair(dev, fn[2], 1, out[1], out[2]) offset:0 atIndex:1];
                [ce setBuffer:out[3] offset:0 atIndex:2];
            }
            for (int j = 0; j < 4; j++) [ce useResource:out[j] usage:MTLResourceUsageWrite];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, kernels[k]);
            static const char *const names[3][4] = {
                {"pointer id(0)", "reference id(1)", "pointer id(2)", "reference id(3)"},
                {"first argument buffer's pointer", "first argument buffer's reference", "second argument buffer's pointer",
                 "second argument buffer's reference"},
                {"plain buffer(0)", "argument buffer(1)'s pointer", "argument buffer(1)'s reference", "plain buffer(2)"},
            };
            const char *why = checkFour(out, names[k]);
            if (why) return FAIL(bug, "%s: %s: %s", name, kernels[k], why);
        }

        // 4: a WebKit bind group: texture, reference, constant, sampler
        static const uint8_t texels[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}};
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
        id<MTLTexture> image = [dev newTextureWithDescriptor:td];
        [image replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = zeroed(dev, N * 16);
        id<MTLArgumentEncoder> ge = [fn[3] newArgumentEncoderWithBufferIndex:0];
        id<MTLBuffer> group = zeroed(dev, MAX(ge.encodedLength, (NSUInteger)16));
        [ge setArgumentBuffer:group offset:0];
        [ge setTexture:image atIndex:0];
        [ge setBuffer:out offset:0 atIndex:1];
        *(uint32_t *)[ge constantDataAtIndex:2] = N * 16;
        [ge setSamplerState:sampler atIndex:3];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps[3]];
        [ce setBuffer:group offset:0 atIndex:0];
        [ce useResource:image usage:MTLResourceUsageRead];
        [ce useResource:out usage:MTLResourceUsageWrite];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: group: command buffer failed", name);
        const float *o = out.contents;
        for (int i = 0; i < N; i++)
            for (int c = 0; c < 4; c++) {
                float want = c < 3 ? texels[i][c] / 255.0f : N * 16;
                if (fabsf(o[i * 4 + c] - want) > 0.01f)
                    return FAIL(bug, "%s: group (texture, reference id(1), constant, sampler): element %d = (%g, %g, %g, %g), want (%g, %g, %g, %g)",
                                name, i, o[i * 4], o[i * 4 + 1], o[i * 4 + 2], o[i * 4 + 3], texels[i][0] / 255.0, texels[i][1] / 255.0,
                                texels[i][2] / 255.0, (double)(N * 16));
            }

        // 5: a fragment function reads a constant reference after a texture and a sampler
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"fullscreen"];
        id<MTLFunction> tinted = [lib newFunctionWithName:@"tinted"];
        rd.fragmentFunction = tinted;
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:rd error:&error];
        if (!rp) return FAIL(bug, "%s: tinted: pipeline: %s", name, error.localizedDescription.UTF8String);
        MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        id<MTLTexture> white = [dev newTextureWithDescriptor:wd];
        static const uint8_t whiteTexel[4] = {255, 255, 255, 255};
        [white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:whiteTexel bytesPerRow:4];
        id<MTLBuffer> tint = zeroed(dev, 16);
        static const float tintValue[4] = {0.25f, 0.5f, 0.75f, 1.0f};
        memcpy(tint.contents, tintValue, 16);
        id<MTLArgumentEncoder> te = [tinted newArgumentEncoderWithBufferIndex:0];
        id<MTLBuffer> bindings = zeroed(dev, MAX(te.encodedLength, (NSUInteger)16));
        [te setArgumentBuffer:bindings offset:0];
        [te setTexture:white atIndex:0];
        [te setSamplerState:sampler atIndex:1];
        [te setBuffer:tint offset:0 atIndex:2];
        enum { W = 4 };
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:W mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget;
        cd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> target = [dev newTextureWithDescriptor:cd];
        id<MTLBuffer> pixels = zeroed(dev, W * W * 4);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:rp];
        [re setFragmentBuffer:bindings offset:0 atIndex:0];
        [re useResource:white usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re useResource:tint usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: tinted: command buffer failed", name);
        const uint8_t *px = pixels.contents;
        for (int i = 0; i < W * W; i++)
            for (int c = 0; c < 4; c++)
                if (abs(px[i * 4 + c] - (int)lroundf(tintValue[c] * 255)) > 1)
                    return FAIL(bug, "%s: fragment function, constant reference id(2) after a texture and a sampler: pixel %d = (%d, %d, %d, %d), "
                                "want (64, 128, 191, 255)", name, i, px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3]);

        return PASS(bug, "%s: buffers held as references in argument buffers (mixed with pointers, in two argument buffers, between plain "
                    "buffers, in a bind group with a texture, a constant and a sampler, and read by a fragment function) each get their own "
                    "buffer", name);
    }
}
