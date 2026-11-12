// i10-intel-num-samples (Intel adapter, IntelTextureAtomics.dylib): get_num_samples() returns 1 in a fragment function
// that takes a buffer argument, at any sample count (without one it's right). Every ANGLE fragment shader takes buffers,
// and ANGLE's alpha-to-coverage emulation (on for every non-Apple GPU) picks its pattern by sample count: in Chrome and
// Safari, coverage didn't grow with alpha (dEQP multisample.fbo_*.proportionality_alpha_to_coverage). A fragment function
// with a buffer argument writes get_num_samples() into 1x, 4x and 8x targets. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i10-intel-num-samples";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint id [[vertex_id]]) { float2 t = float2(id & 1, id >> 1); return float4(t * 2 - 1, 0, 1); }\n"
            "fragment uint4 f(constant uint &bias [[buffer(0)]]) { return uint4(get_num_samples() + bias); }\n"
            "kernel void k(texture2d_ms<uint> t [[texture(0)]], device uint *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 1), 0).x; }\n"
            "kernel void k1(texture2d<uint> t [[texture(0)]], device uint *out [[buffer(0)]]) { out[0] = t.read(uint2(1, 1)).x; }\n"
            stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: no library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> out = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        for (NSUInteger samples = 1; samples <= 8; samples *= 2) {
            if (![dev supportsTextureSampleCount:samples]) continue;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
            if (samples > 1) td.textureType = MTLTextureType2DMultisample, td.sampleCount = samples;
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> target = [dev newTextureWithDescriptor:td];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"v"];
            pd.fragmentFunction = [lib newFunctionWithName:@"f"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
            pd.rasterSampleCount = samples;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            id<MTLComputePipelineState> cs = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:samples > 1 ? @"k" : @"k1"] error:&error];
            if (!ps || !cs) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:ps];
            uint32_t bias = 0;
            [enc setFragmentBytes:&bias length:sizeof bias atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [enc endEncoding];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:cs];
            [ce setTexture:target atIndex:0];
            [ce setBuffer:out offset:0 atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            uint32_t got = *(uint32_t *)out.contents;
            if (got != samples)
                return FAIL(bug, "%s: get_num_samples() in a fragment function with a buffer argument, %lux target: %u", dev.name.UTF8String,
                            (unsigned long)samples, got);
        }
        return PASS(bug, "%s: get_num_samples() right with a buffer argument (1x, 4x, 8x)", dev.name.UTF8String);
    }
}
