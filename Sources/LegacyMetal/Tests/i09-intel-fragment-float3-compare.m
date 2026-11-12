// i09-intel-fragment-float3-compare (Intel adapter, IntelTextureAtomics.dylib): in a fragment function, the z of a float3
// input given straight to sample_compare as the reference value is compared with the input's x instead (3802 Intel
// compiler; float2 and float4 inputs, and any arithmetic on the value, are right). ANGLE passes sampler2DShadow
// coordinates as a vec3 varying that way: dEQP texture.sampler2dshadow_fragment and the like fail in Chrome and Safari.
// A fragment function compares a float3 varying (2 + t, 3 + t, t), t going 0 to 1 across the target, against Depth16Unorm
// and Depth32Float textures of 1.0 with compare function less: every comparison passes when z is the reference, none when
// x is. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i09-intel-fragment-float3-compare";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 pos [[position]]; float3 uvw; };\n"
            "vertex V v(uint id [[vertex_id]]) { float2 t = float2(id & 1, id >> 1); V o; o.pos = float4(t * 2 - 1, 0, 1);\n"
            "  o.uvw = float3(2 + t.x, 3 + t.x, t.x); return o; }\n"
            "fragment float4 f(V in [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
            "  return float4(t.sample_compare(s, float2(0.3), in.uvw.z)); }\n" stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        id<MTLRenderPipelineState> ps = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.compareFunction = MTLCompareFunctionLess;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        enum { W = 64 };
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:W height:2 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget;
        rd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        MTLPixelFormat formats[2] = {MTLPixelFormatDepth16Unorm, MTLPixelFormatDepth32Float};
        const char *names[2] = {"Depth16Unorm", "Depth32Float"};
        for (int fi = 0; fi < 2; fi++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[fi] width:16 height:16 mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
            size_t bpp = fi ? 4 : 2;
            id<MTLBuffer> ones = [dev newBufferWithLength:16 * 16 * bpp options:MTLResourceStorageModeShared];
            for (int i = 0; i < 16 * 16; i++) {
                if (fi) ((float *)ones.contents)[i] = 1;
                else ((uint16_t *)ones.contents)[i] = 0xffff;
            }
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> upload = [cb blitCommandEncoder];
            [upload copyFromBuffer:ones sourceOffset:0 sourceBytesPerRow:16 * bpp sourceBytesPerImage:16 * 16 * bpp sourceSize:MTLSizeMake(16, 16, 1)
                         toTexture:depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [upload endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:ps];
            [enc setFragmentTexture:depth atIndex:0];
            [enc setFragmentSamplerState:sampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:target];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            float got[W];
            [target getBytes:got bytesPerRow:sizeof got fromRegion:MTLRegionMake2D(0, 0, W, 1) mipmapLevel:0];
            int failed = 0;
            for (int x = 0; x < W; x++) failed += got[x] != 1;
            if (failed)
                return FAIL(bug, "%s: %s: %d of %d comparisons of a float3 varying's z (0..1) with 1.0 failed%s", dev.name.UTF8String, names[fi],
                            failed, W, failed == W ? " (its x, 2..3, was compared)" : "");
        }
        return PASS(bug, "%s: a float3 varying's z compares as the reference value (Depth16Unorm, Depth32Float)", dev.name.UTF8String);
    }
}
