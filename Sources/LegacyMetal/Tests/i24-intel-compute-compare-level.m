// i24-intel-compute-compare-level (Intel adapter, IntelTextureAtomics.dylib, with MetalOldCompat item 40): sample_compare
// with level(0) in a compute kernel whose coordinates come from a constant buffer. The IGIL writer builds the sample's
// message in one register (coordinates in xyz, the LOD in w) and then names the coordinate register as the operand;
// iCBE takes the LOD from its w, which held whatever the register last held, so the sample came from a random mip level
// (blended, with a linear mip filter) and the results changed from run to run (WebGPU CTS textureSampleCompareLevel in
// compute: 160 cases). A 16x16 Depth32Float texture with 3 levels of different random depths is compared (less, 0.5)
// at 50 texel centres per run, 10 runs, nearest and linear filters; every result must be level 0's.
// Stock OCLP: FAIL (item 40 missing: every comparison is "never"). The PR without this fix: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Call { float2 coords; float2 unused; float ref; float pad[3]; };\n"
    "kernel void k(depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Call *calls [[buffer(0)]],\n"
    "              device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "    Call c = calls[min(i, 49u)];\n"
    "    out[i] = float4(t.sample_compare(s, c.coords, c.ref, level(0)));\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i24-intel-compute-compare-level";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        uint32_t x = 2463534242u;
        for (int run = 0; run < 20; run++) {
            bool linear = run & 1;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:YES];
            td.mipmapLevelCount = 3;
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
            float levels[3][256];
            for (int l = 0; l < 3; l++)
                for (int i = 0; i < 256; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; levels[l][i] = (x % 1000) / 1000.0f; }
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
            sd.compareFunction = MTLCompareFunctionLess;
            sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sd.mipFilter = linear ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
            id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
            struct { float coords[2], unused[2], ref, pad[3]; } calls[50] = {{{0}}};
            int texel[50];
            for (int c = 0; c < 50; c++) {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                texel[c] = x % 256;
                calls[c].coords[0] = (texel[c] % 16 + 0.5f) / 16, calls[c].coords[1] = (texel[c] / 16 + 0.5f) / 16, calls[c].ref = 0.5f;
            }
            id<MTLBuffer> callBuffer = [dev newBufferWithBytes:calls length:sizeof calls options:MTLResourceStorageModeShared];
            id<MTLBuffer> out = [dev newBufferWithLength:50 * 16 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            for (int l = 0; l < 3; l++) {
                int w = 16 >> l;
                id<MTLBuffer> upload = [dev newBufferWithBytes:levels[l] length:w * w * 4 options:MTLResourceStorageModeShared];
                [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * w * 4 sourceSize:MTLSizeMake(w, w, 1)
                           toTexture:texture destinationSlice:0 destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            [blit endEncoding];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setTexture:texture atIndex:0];
            [ce setSamplerState:sampler atIndex:0];
            [ce setBuffer:callBuffer offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake(50, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            const float *o = out.contents;
            for (int c = 0; c < 50; c++) {
                float want = 0.5f < levels[0][texel[c]] ? 1.0f : 0.0f;
                if (o[c * 4] != want)
                    return FAIL(bug, "%s: run %d (%s): sample_compare(less, 0.5, level(0)) at texel (%d, %d) gave %g, want %g (level 0 holds %.3f, level 1 %.3f)",
                                name, run, linear ? "linear" : "nearest", texel[c] % 16, texel[c] / 16, o[c * 4], want, levels[0][texel[c]],
                                levels[1][(texel[c] / 32) * 8 + (texel[c] % 16) / 2]);
            }
        }
        return PASS(bug, "%s: compute sample_compare with level(0) reads level 0 (20 runs of 50 texel centres, nearest and linear)", name);
    }
}
