// a01-texture-atomics (AMD and Intel texture-atomics adapters; Blender upstream note): MSL 3.1 texture atomics
// (atomic_fetch_add etc. on read_write R32Uint textures) on the legacy AMD (12.5) and Intel (12.x) drivers. They
// compile, but the drivers have no texture-atomic instructions behind them: the atomics do nothing (the texels stay 0).
// Blender assumes texture atomics on every macOS 14+ Mac, so EEVEE's shadow maps stay empty (no shadows). The adapters
// lower texture atomics to the GPUs' image atomic instructions. 64x64 threads add 1 into 4 texels (1024 each) and
// record the old values they got back (every value 0..1023 exactly once per texel).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD; run with Intel for the Intel adapter).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(texture2d<uint, access::read_write> t [[texture(0)]], device uint *old [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "  uint i = g.y * 64u + g.x;\n"
    "  old[i] = t.atomic_fetch_add(uint2(i & 1u, (i >> 1) & 1u), 1u).x;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a01-texture-atomics";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_1;  // texture atomics are MSL 3.1
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:2 height:2 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        uint32_t zero[4] = {0};
        [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:zero bytesPerRow:8];
        id<MTLBuffer> old = [dev newBufferWithLength:4096 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setTexture:t atIndex:0]; [e setBuffer:old offset:0 atIndex:0];
        [e dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [e endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b synchronizeResource:t];
        [b endEncoding];
        reproRun(cb);
        uint32_t sums[4];
        [t getBytes:sums bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
        static uint8_t seen[4][1024];
        const uint32_t *o = old.contents;
        int dupes = 0;
        for (uint32_t i = 0; i < 4096; i++) {
            uint32_t texel = (i & 1) | (((i >> 1) & 1) << 1);
            if (o[i] >= 1024 || seen[texel][o[i]]++) dupes++;
        }
        if (sums[0] != 1024 || sums[1] != 1024 || sums[2] != 1024 || sums[3] != 1024 || dupes)
            return FAIL(bug, "%s: texel sums %u %u %u %u (want 1024 each), %d returned old values wrong or repeated", dev.name.UTF8String,
                        sums[0], sums[1], sums[2], sums[3], dupes);
        return PASS(bug, "%s: 4096 texture atomic adds: sums 1024 each, returned values unique", dev.name.UTF8String);
    }
}
