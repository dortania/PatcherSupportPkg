// s61-intel-argument-buffers (MetalOldCompat item 47 with the Intel adapter's INTEL_IVB_ARGUMENT_BUFFER_FIX): OCLP's
// 11.7.10 Ivy Bridge plugin reads an argument buffer's pointer members as offsets into the argument buffer itself, and a
// vertex or fragment function that dereferences one doesn't build ("Compilation failed"); the driver has no argument
// encoders (item 46). WebKit's ANGLE puts every WebGL 2 uniform block in an argument buffer. This program encodes two
// buffer pointers and a constant with the argument encoder of a fragment function, draws with it and reads a pixel back,
// does the same in a kernel (with two arrays of pointers, the second at id 4), then runs a kernel that reads a buffer the app bound at
// buffer index 30, which the first kernel's hidden bindings used, to check that the app's binding was put back. The values
// avoid rounding ties in the 8-bit target (0.375 -> 96); a second pass writes 0.5, an exact tie that Metal rounds to even
// (128). Kepler (GTX 600/700) writes 127 there, a known deviation in its fixed-function output (FIXES.md, known
// limitations), so on Kepler that check expects 127 and reports it.
// Stock OCLP on an HD 4000: FAIL (the encoder aborts, s60; with only item 46, no encoder). Fixed: PASS. Other GPUs have
// argument buffers of their own and pass either way. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s61-intel-argument-buffers";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct U { float4 c; };\n"
            "struct Blocks { constant U *u0 [[id(0)]]; constant U *u1 [[id(1)]]; float4 k [[id(2)]]; };\n"
            "struct Many { array<constant U *, 3> u [[id(0)]]; float4 k [[id(3)]]; array<constant U *, 2> w [[id(4)]]; };\n"
            "struct VOut { float4 pos [[position]]; };\n"
            "vertex VOut vs(uint vid [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VOut o; o.pos = float4(p[vid], 0, 1); return o; }\n"
            "fragment float4 fs(constant Blocks &b [[buffer(25)]]) { return b.u0->c + b.u1->c + b.k; }\n"
            "fragment float4 tie() { return float4(0.5); }\n"
            "kernel void many(constant Many &m [[buffer(20)]], device float4 *out [[buffer(0)]]) { out[0] = m.u[0]->c + m.u[2]->c + m.k; out[2] = m.w[1]->c; }\n"
            "kernel void plain(constant float4 *v [[buffer(30)]], device float4 *out [[buffer(0)]]) { out[1] = v[0]; }\n"
            options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLFunction> fs = [lib newFunctionWithName:@"fs"], many = [lib newFunctionWithName:@"many"];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = fs;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!rp) return FAIL(bug, "%s: render pipeline with an argument buffer: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> cpMany = [dev newComputePipelineStateWithFunction:many error:&err];
        if (!cpMany) return FAIL(bug, "%s: kernel with an array of pointers in an argument buffer: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> cpPlain = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"plain"] error:&err];
        id<MTLArgumentEncoder> fenc = [fs newArgumentEncoderWithBufferIndex:25], menc = [many newArgumentEncoderWithBufferIndex:20];
        if (!fenc || !menc) return FAIL(bug, "%s: no argument encoder", dev.name.UTF8String);
        float v0[4] = {0.25f, 0, 0, 0}, v1[4] = {0, 0.375f, 0, 0}, v2[4] = {0, 0, 0.125f, 0}, mine[4] = {7, 8, 9, 10};
        id<MTLBuffer> b0 = [dev newBufferWithBytes:v0 length:16 options:0], b1 = [dev newBufferWithBytes:v1 length:16 options:0];
        id<MTLBuffer> b2 = [dev newBufferWithBytes:v2 length:16 options:0], b3 = [dev newBufferWithBytes:mine length:16 options:0];
        id<MTLBuffer> fargs = [dev newBufferWithLength:fenc.encodedLength options:0], margs = [dev newBufferWithLength:menc.encodedLength options:0];
        [fenc setArgumentBuffer:fargs offset:0];
        [fenc setBuffer:b0 offset:0 atIndex:0];
        [fenc setBuffer:b1 offset:0 atIndex:1];
        float *k = [fenc constantDataAtIndex:2];
        if (k) k[0] = 0, k[1] = 0, k[2] = 0.75f, k[3] = 1;
        [menc setArgumentBuffer:margs offset:0];
        [menc setBuffer:b0 offset:0 atIndex:0];
        [menc setBuffer:b1 offset:0 atIndex:1];
        [menc setBuffer:b2 offset:0 atIndex:2];
        [menc setBuffer:b0 offset:0 atIndex:4];  // the second array, ids 4-5: element 1 must read b1, not b0
        [menc setBuffer:b1 offset:0 atIndex:5];
        float *mk = [menc constantDataAtIndex:3];
        if (mk) mk[0] = 0, mk[1] = 0.5f, mk[2] = 0, mk[3] = 1;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> out = [dev newBufferWithLength:48 options:0];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = rt;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpd];
        [re setRenderPipelineState:rp];
        [re setFragmentBuffer:fargs offset:0 atIndex:25];
        [re useResource:b0 usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re useResource:b1 usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setBuffer:b3 offset:0 atIndex:30];  // the app's own binding at an index the next kernel's hidden bindings take
        [ce setComputePipelineState:cpMany];
        [ce setBuffer:margs offset:0 atIndex:20];
        [ce setBuffer:out offset:0 atIndex:0];
        [ce useResource:b0 usage:MTLResourceUsageRead];
        [ce useResource:b2 usage:MTLResourceUsageRead];
        [ce useResource:b1 usage:MTLResourceUsageRead];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce setComputePipelineState:cpPlain];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:rt];
        [be endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted)
            return FAIL(bug, "%s: command buffer status %ld", dev.name.UTF8String, (long)cb.status);
        uint8_t px[4];
        [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        const float *o = out.contents;
        if (px[0] != 64 || px[1] != 96 || px[2] != 191 || px[3] != 255)
            return FAIL(bug, "%s: fragment function reading two blocks through an argument buffer: pixel %u %u %u %u, want 64 96 191 255",
                        dev.name.UTF8String, px[0], px[1], px[2], px[3]);
        if (o[0] != 0.25f || o[1] != 0.5f || o[2] != 0.125f || o[3] != 1)
            return FAIL(bug, "%s: kernel reading an array of pointers in an argument buffer: %g %g %g %g, want 0.25 0.5 0.125 1",
                        dev.name.UTF8String, o[0], o[1], o[2], o[3]);
        if (o[8] != 0 || o[9] != 0.375f || o[10] != 0 || o[11] != 0)
            return FAIL(bug, "%s: element 1 of a second array of pointers (ids 4-5) in an argument buffer: %g %g %g %g, want 0 0.375 0 0",
                        dev.name.UTF8String, o[8], o[9], o[10], o[11]);
        if (o[4] != 7 || o[5] != 8 || o[6] != 9 || o[7] != 10)
            return FAIL(bug, "%s: the app's buffer at index 30 after an argument-buffer dispatch: %g %g %g %g, want 7 8 9 10",
                        dev.name.UTF8String, o[4], o[5], o[6], o[7]);
        // 0.5 in an 8-bit unorm target: an exact tie, which Metal rounds to even (128); Kepler's color output writes 127
        pd.fragmentFunction = [lib newFunctionWithName:@"tie"];
        id<MTLRenderPipelineState> tp = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!tp) return FAIL(bug, "%s: render pipeline writing 0.5: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLTexture> tt = [dev newTextureWithDescriptor:td];
        cb = [[dev newCommandQueue] commandBuffer];
        rpd.colorAttachments[0].texture = tt;
        re = [cb renderCommandEncoderWithDescriptor:rpd];
        [re setRenderPipelineState:tp];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        be = [cb blitCommandEncoder];
        [be synchronizeResource:tt];
        [be endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint8_t tie[4];
        [tt getBytes:tie bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        BOOL kepler = [NSStringFromClass([dev class]) hasPrefix:@"NVMTL"];
        BOOL even = tie[0] == 128 && tie[1] == 128 && tie[2] == 128 && tie[3] == 128;
        BOOL keplerTie = kepler && tie[0] == 127 && tie[1] == 127 && tie[2] == 127 && tie[3] == 127;  // the known deviation
        if (!even && !keplerTie)
            return FAIL(bug, "%s: 0.5 written to an 8-bit unorm target came out %u %u %u %u, want 128 (round to even)%s", dev.name.UTF8String,
                        tie[0], tie[1], tie[2], tie[3], kepler ? " or Kepler's 127" : "");
        return PASS(bug, "%s: argument buffers encoded, drawn and dispatched with (pointers, two arrays of pointers, constants); 0.5 in "
                    "an 8-bit target: %u%s", dev.name.UTF8String, tie[0], keplerTie ? " (Kepler's known deviation from round-to-even, expected)" : "");
    }
}
