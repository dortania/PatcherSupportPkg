// s09-msl-3.2 (MetalOldCompat item 9): MSL 3.2 source (MTLLanguageVersion3_2, macOS 15) on this stack. The front end
// that compiles source for MetalOld supports MSL up to 3.1, so every 3.2 request fails; MoltenVK and SPIRV-Cross assume
// 3.2 on macOS 15 and emit its memory-coherence qualifiers (`coherent(device)`, `memory_coherence_device` textures).
// Compiles and runs a kernel using them, requested as MSL 3.2.
// Stock OCLP: FAIL (compile error). Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(coherent(device) device uint *flags [[buffer(0)]],\n"
    "              texture2d<float, access::read_write, memory_coherence_device> t [[texture(0)]],\n"
    "              uint i [[thread_position_in_grid]]) {\n"
    "  flags[i] = i + 1u;\n"
    "  t.write(float4(0.5f), uint2(i, 0));\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s09-msl-3.2";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        if (@available(macOS 15.0, *)) {
            MTLCompileOptions *o = [MTLCompileOptions new];
            o.languageVersion = MTLLanguageVersion3_2;
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:o error:&err];
            if (!lib) return FAIL(bug, "%s: MSL 3.2 source: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
            id<MTLBuffer> b = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:1 mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:ps]; [e setBuffer:b offset:0 atIndex:0]; [e setTexture:[dev newTextureWithDescriptor:td] atIndex:0];
            [e dispatchThreads:MTLSizeMake(16, 1, 1) threadsPerThreadgroup:MTLSizeMake(16, 1, 1)];
            [e endEncoding];
            reproRun(cb);
            const uint32_t *p = b.contents;
            for (uint32_t i = 0; i < 16; i++) if (p[i] != i + 1) return FAIL(bug, "%s: wrong result at %u", dev.name.UTF8String, i);
            return PASS(bug, "%s: MSL 3.2 source with coherence qualifiers compiled and ran", dev.name.UTF8String);
        }
        return SKIP(bug, "needs macOS 15");
    }
}
