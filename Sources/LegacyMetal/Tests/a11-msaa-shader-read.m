// a11-msaa-shader-read (AMD adapter): shaders must read the samples of a 4x MSAA texture. On the 12.5-24 Bronze driver
// the FMASK descriptor table (API slot 13) is unset for render stages, so a fragment shader's texture2d_ms read loads its
// FMASK descriptor from GPU address 0 and the GPU resets (Safari's WebGL resolves antialiased canvases this way); a
// compute read gets a stale table and wrong samples. Fixed by the adapter's identity FMASK map (AMD_FMASK_FIX).
// The compute read runs first; the fragment read only runs once it is right, so an unfixed stack fails without a reset.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 fullScreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
    "struct Half { float4 color [[color(0)]]; uint mask [[sample_mask]]; };\n"
    "fragment Half whiteInSamples01() { return { float4(1), 3 }; }\n"
    "kernel void readSamples(texture2d_ms<float> s [[texture(0)]], device float *o [[buffer(0)]]) {\n"
    "    for (uint i = 0; i < 4; i++) o[i] = s.read(uint2(8, 8), i).r;\n"
    "}\n"
    "fragment float4 averageSamples(float4 position [[position]], texture2d_ms<float> s [[texture(0)]]) {\n"
    "    float4 sum = 0;\n"
    "    for (uint i = 0; i < 4; i++) sum += s.read(uint2(position.xy), i);\n"
    "    return sum / 4;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a11-msaa-shader-read";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        MTLPixelFormat fmt = MTLPixelFormatRGBA8Unorm;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"fullScreen"];
        pd.fragmentFunction = [lib newFunctionWithName:@"whiteInSamples01"];
        pd.colorAttachments[0].pixelFormat = fmt;
        pd.rasterSampleCount = 4;
        id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!draw) return FAIL(bug, "%s: draw pipeline: %s", name, err.localizedDescription.UTF8String);
        pd.fragmentFunction = [lib newFunctionWithName:@"averageSamples"];
        pd.rasterSampleCount = 1;
        id<MTLRenderPipelineState> average = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!average) return FAIL(bug, "%s: average pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"readSamples"] error:&err];
        if (!read) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);

        // Samples 0 and 1 white, 2 and 3 cleared to black.
        MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:16 height:16 mipmapped:NO];
        md.textureType = MTLTextureType2DMultisample;
        md.sampleCount = 4;
        md.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        md.storageMode = MTLStorageModePrivate;
        id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = ms;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:draw];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];

        id<MTLBuffer> samples = [dev newBufferWithLength:4 * sizeof(float) options:MTLResourceStorageModeShared];
        memset(samples.contents, 0xff, 4 * sizeof(float));
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:read];
        [ce setTexture:ms atIndex:0];
        [ce setBuffer:samples offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: compute read: command buffer failed", name);
        const float *s = samples.contents;
        if (s[0] != 1 || s[1] != 1 || s[2] != 0 || s[3] != 0)
            return FAIL(bug, "%s: compute read: samples %g %g %g %g, want 1 1 0 0 (fragment read not run: it resets the GPU "
                        "on this stack)", name, s[0], s[1], s[2], s[3]);

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        cb = [q commandBuffer];
        rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:average];
        [re setFragmentTexture:ms atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:target];
        [be endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: fragment read: command buffer failed (GPU reset?)", name);
        uint8_t px[4];
        [target getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(8, 8, 1, 1) mipmapLevel:0];
        if (px[0] < 127 || px[0] > 128) return FAIL(bug, "%s: fragment read: average %d, want 128", name, px[0]);
        return PASS(bug, "%s: compute and fragment shaders read every sample of a 4x MSAA texture", name);
    }
}
