// c01-amdil-argument-buffer (libAMDIL902 parser fix, patch 1; AMD GCN on the 12.5 stack, every GCN generation):
// a kernel that reads textures, a sampler and a buffer through a Metal argument buffer. The 2022 libAMDIL902 parses
// argument metadata keys in a fixed order; the macOS 14+ compiler adds "air.address_space" (and "air.buffer_stride")
// before "air.struct_type_info", so the argument buffer's layout is never recorded and
// ILMetadataPropagation::initializeIABArgTypeSet crashes MTLCompilerService ("Compiler encountered an internal
// error"). Checks every value read through the argument buffer.
// Stock OCLP on Sequoia (12.5 libAMDIL902): FAIL (compiler crash). Fixed: PASS. OCLP's Tahoe build (12.5-GCN-25), which
// returns early from initializeIABArgTypeSet instead, also passes this test (but not c02).
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Resources {\n"
    "  texture2d<float> tex0 [[id(0)]];\n"
    "  texture2d<float> tex1 [[id(1)]];\n"
    "  sampler smp [[id(2)]];\n"
    "  device const float4 *tint [[id(3)]];\n"
    "};\n"
    "kernel void k(constant Resources &res [[buffer(0)]], device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  float2 uv = float2((i % 4) + 0.5, (i / 4) + 0.5) / 4.0;\n"
    "  out[i] = res.tex0.sample(res.smp, uv) * 0.5 + res.tex1.read(uint2(i % 4, i / 4)) * 0.25 + res.tint[0];\n"
    "}\n";

static id<MTLTexture> texture(id<MTLDevice> dev, float seed, float *values) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:4 height:4 mipmapped:NO];
    d.storageMode = MTLStorageModeManaged;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    for (int i = 0; i < 64; i++) values[i] = seed + i * 0.125f;
    [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:values bytesPerRow:64];
    return t;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "c01-amdil-argument-buffer";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLFunction> f = [lib newFunctionWithName:@"k"];
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline with an argument buffer: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        float v0[64], v1[64], tint[4] = {100, 200, 300, 400};
        id<MTLTexture> t0 = texture(dev, 1, v0), t1 = texture(dev, 50, v1);
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> tintBuf = [dev newBufferWithBytes:tint length:16 options:MTLResourceStorageModeShared];
        id<MTLArgumentEncoder> enc = [f newArgumentEncoderWithBufferIndex:0];
        id<MTLBuffer> args = [dev newBufferWithLength:enc.encodedLength options:MTLResourceStorageModeShared];
        [enc setArgumentBuffer:args offset:0];
        [enc setTexture:t0 atIndex:0]; [enc setTexture:t1 atIndex:1]; [enc setSamplerState:smp atIndex:2]; [enc setBuffer:tintBuf offset:0 atIndex:3];
        id<MTLBuffer> out = [dev newBufferWithLength:16 * 16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:args offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e useResource:t0 usage:MTLResourceUsageRead]; [e useResource:t1 usage:MTLResourceUsageRead]; [e useResource:tintBuf usage:MTLResourceUsageRead];
        [e dispatchThreads:MTLSizeMake(16, 1, 1) threadsPerThreadgroup:MTLSizeMake(16, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const float *o = out.contents;
        for (int i = 0; i < 16; i++) for (int c = 0; c < 4; c++) {
            float want = v0[i * 4 + c] * 0.5f + v1[i * 4 + c] * 0.25f + tint[c];
            if (fabsf(o[i * 4 + c] - want) > 1e-3f)
                return FAIL(bug, "%s: value %d.%d read through the argument buffer = %g, want %g", dev.name.UTF8String, i, c, o[i * 4 + c], want);
        }
        return PASS(bug, "%s: textures, sampler and buffer read correctly through an argument buffer", dev.name.UTF8String);
    }
}
