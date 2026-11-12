// i72-intel-half-green-gather (Intel adapter, IntelTextureAtomics.dylib; regression test for i50): a green gather
// through a texture2d<half> must compile and return the texels' green values. i50 compares a green gather with a red
// one to catch Haswell's R32G32 erratum; it bitcast both to <4 x i32>, which is invalid for half4, so the compiler
// service aborted ("Compiler encountered an internal error") on any half green gather: MetalFX's spatial scaler
// (MFX_Scale) gathers half4, and MTLFXSpatialScaler came back nil on the Iris Pro although supportsDevice said yes.
// Gathers green from a 4x4 RG32Float texture (the erratum's format) through texture2d<half> in a compute kernel, at the
// centre of each 2x2 footprint, and checks the four values against the texels.
// Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<half> t [[texture(0)]], sampler s [[sampler(0)]], device half4 *out [[buffer(0)]],\n"
    "              uint2 id [[thread_position_in_grid]]) {\n"
    "  float2 uv = (float2(id) * 2.0 + 1.0) / 4.0;  // the middle of footprint (2 id.x, 2 id.y)\n"
    "  out[id.y * 2 + id.x] = t.gather(s, uv, int2(0), component::y);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i72-intel-half-green-gather";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
        if (!ps) return FAIL(bug, "%s: no pipeline for a half green gather: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        float texels[4 * 4 * 2];
        for (int y = 0; y < 4; y++)
            for (int x = 0; x < 4; x++) texels[(y * 4 + x) * 2] = 0.25f * x, texels[(y * 4 + x) * 2 + 1] = 0.125f * (y * 4 + x);  // red, green
        [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:4 * 8];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [dev newBufferWithLength:4 * 8 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setTexture:t atIndex:0];
        [enc setSamplerState:s atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [enc endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        const __fp16 *o = out.contents;
        static const int kOrder[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};  // gather order: (u, v) of x, y, z, w
        for (int fy = 0; fy < 2; fy++)
            for (int fx = 0; fx < 2; fx++)
                for (int k = 0; k < 4; k++) {
                    int x = fx * 2 + kOrder[k][0], y = fy * 2 + kOrder[k][1];
                    float want = 0.125f * (y * 4 + x), got = o[(fy * 2 + fx) * 4 + k];
                    if (fabsf(got - want) > 1e-3f)
                        return FAIL(bug, "%s: footprint (%d,%d) component %d: %g, want the green %g (red there: %g)", dev.name.UTF8String, fx * 2,
                                    fy * 2, k, got, want, 0.25f * x);
                }
        return PASS(bug, "%s: a green gather through texture2d<half> compiles and returns green (RG32Float)", dev.name.UTF8String);
    }
}
