// i03-intel-shadow-compare-bias (Intel adapter, IntelTextureAtomics.dylib): depth comparisons with an LOD bias and the
// 3802 Intel compiler. sample_compare(s, coord, ref, bias(b)), which ANGLE emits for GLSL's texture(sampler2DShadow,
// coord, bias), aborts MTLCompilerService ("Cannot select"), and in Chrome that takes the GPU process with it. The
// compiler can't compute an LOD either, so the adapter drops the bias. A fragment function compares a one-level depth
// texture holding 0.25 with 0.125 (LessEqual: 0.125 <= 0.25 passes) with a bias read from a buffer, for 2D, 2D array
// and cube textures.
// Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static const struct { const char *name, *type, *expression; MTLTextureType textureType; } kCases[] = {
    {"2D", "depth2d<float>", "t.sample_compare(s, float2(0.5), 0.125, bias(b))", MTLTextureType2D},
    {"2D array", "depth2d_array<float>", "t.sample_compare(s, float2(0.5), 0, 0.125, bias(b))", MTLTextureType2DArray},
    {"cube", "depthcube<float>", "t.sample_compare(s, float3(1, 0, 0), 0.125, bias(b))", MTLTextureTypeCube},
};

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i03-intel-shadow-compare-bias";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.compareFunction = MTLCompareFunctionLessEqual;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        for (size_t c = 0; c < sizeof kCases / sizeof *kCases; c++) {
            NSString *source = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
                "vertex float4 v(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
                "fragment float4 f(%s t [[texture(0)]], sampler s [[sampler(0)]], constant float &b [[buffer(0)]]) { return float4(%s); }\n%@",
                kCases[c].type, kCases[c].expression, reproUniqueComment()];
            NSError *error = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&error];
            if (!lib) return FAIL(bug, "%s: %s: front end: %s", dev.name.UTF8String, kCases[c].name, error.localizedDescription.UTF8String);
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"v"];
            pd.fragmentFunction = [lib newFunctionWithName:@"f"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
            if (!pipeline)
                return FAIL(bug, "%s: %s depth comparison with a bias: no pipeline (%s)", dev.name.UTF8String, kCases[c].name,
                            error.localizedDescription.UTF8String);

            MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
            dd.textureType = kCases[c].textureType;
            dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            dd.storageMode = MTLStorageModePrivate;
            id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
            MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
            cd.usage = MTLTextureUsageRenderTarget;
            cd.storageMode = MTLStorageModeManaged;
            id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            for (NSUInteger slice = 0; slice < (kCases[c].textureType == MTLTextureTypeCube ? 6 : 1); slice++) {  // depth 0.25
                MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
                clear.depthAttachment.texture = depth;
                clear.depthAttachment.slice = slice;
                clear.depthAttachment.loadAction = MTLLoadActionClear;
                clear.depthAttachment.clearDepth = 0.25;
                clear.depthAttachment.storeAction = MTLStoreActionStore;
                [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
            }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = color;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            const float bias = 1.5f;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pipeline];
            [enc setFragmentTexture:depth atIndex:0];
            [enc setFragmentSamplerState:sampler atIndex:0];
            [enc setFragmentBytes:&bias length:sizeof bias atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:color];
            [blit endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", dev.name.UTF8String, kCases[c].name);
            uint8_t px[4];
            [color getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
            if (px[0] != 255)
                return FAIL(bug, "%s: %s: 0.125 compared with depth 0.25 (LessEqual) gave %d, want 255", dev.name.UTF8String, kCases[c].name, px[0]);
        }
        return PASS(bug, "%s: depth comparisons with an LOD bias compile and compare right (2D, 2D array, cube)", dev.name.UTF8String);
    }
}
