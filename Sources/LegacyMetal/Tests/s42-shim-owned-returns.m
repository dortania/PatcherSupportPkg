// s42-shim-owned-returns (MetalOldCompat): the shim's replacements for new- and init-family methods must hand back an
// owned object, as the methods they replace do. Annotated wrongly, ARC autoreleases what they return, and every texture,
// view or MTLCompileOptions made through them then lives until an autorelease pool drains, never in a process that drains
// none: dawn.node's WebGPU CTS image_copy had 15000 textures alive after 25 s and ran out of memory. Makes each kind of
// object through the paths the shim hooks (a plain texture, a depth texture with mip levels (item 22), a multisampled
// Stencil8 texture (item 36), texture views with and without a range, a view with a swizzle (item 32), MTLCompileOptions,
// an R32Uint texture for atomics (item 58), render and compute pipelines with and without reflection (items 21, 47, 58),
// a depth/stencil state (item 51))
// and checks through a weak reference that it is freed as soon as it is released, with no pool drained in between.
// Passes on any stack that doesn't defer these releases (the no-op shim too). Argument: GPU name substring (default: Intel).
#import "repro.h"

int main(int argc, char **argv) {
    const char *bug = "s42-shim-owned-returns";
    id<MTLDevice> dev;
    @autoreleasepool {
        dev = reproDevice(argc, argv, "Intel");
    }
    if (!dev) return SKIP(bug, "no such GPU");
    __weak id weak = nil;
    const char *kept = NULL;
#define CHECK(what, make) do { { id object = (make); weak = object; } if (weak) { kept = what; goto done; } } while (0)
    MTLTextureDescriptor *plain = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    plain.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    MTLTextureDescriptor *depth = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:YES];
    depth.storageMode = MTLStorageModePrivate;
    MTLTextureDescriptor *stencil = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:16 height:16 mipmapped:NO];
    stencil.textureType = MTLTextureType2DMultisample;
    stencil.sampleCount = 4;
    stencil.storageMode = MTLStorageModePrivate;
    stencil.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    MTLTextureDescriptor *atomic = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:16 height:16 mipmapped:NO];
    atomic.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (@available(macOS 14.0, *)) atomic.usage |= MTLTextureUsageShaderAtomic;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(float(i), 0.0, 0.0, 1.0); }\n"
        "fragment float4 f() { return float4(1.0); }\n"
        "kernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }\n" options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"v"];
    rd.fragmentFunction = [lib newFunctionWithName:@"f"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLFunction> kf = [lib newFunctionWithName:@"k"];
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
    cd.computeFunction = kf;
    MTLAutoreleasedRenderPipelineReflection rr = nil;
    MTLAutoreleasedComputePipelineReflection cr = nil;
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    id<MTLTexture> base = [dev newTextureWithDescriptor:plain];
    CHECK("texture", [dev newTextureWithDescriptor:plain]);
    CHECK("depth texture with mip levels", [dev newTextureWithDescriptor:depth]);
    CHECK("multisampled Stencil8 texture", [dev newTextureWithDescriptor:stencil]);
    CHECK("texture view", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]);
    CHECK("texture view with a range", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                                     levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)]);
    MTLTextureSwizzleChannels identity = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    CHECK("texture view with a swizzle", [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                                      levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1) swizzle:identity]);
    CHECK("MTLCompileOptions", [MTLCompileOptions new]);
    CHECK("texture for atomics", [dev newTextureWithDescriptor:atomic]);
    CHECK("render pipeline", [dev newRenderPipelineStateWithDescriptor:rd error:&err]);
    CHECK("render pipeline with reflection", [dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionNone reflection:&rr error:&err]);
    CHECK("compute pipeline", [dev newComputePipelineStateWithFunction:kf error:&err]);
    CHECK("compute pipeline with reflection", [dev newComputePipelineStateWithFunction:kf options:MTLPipelineOptionNone reflection:&cr error:&err]);
    CHECK("compute pipeline from a descriptor", [dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone reflection:&cr error:&err]);
    CHECK("depth/stencil state", [dev newDepthStencilStateWithDescriptor:dd]);
done:
    if (kept) return FAIL(bug, "%s: a %s was still alive after its last release (deferred to an autorelease pool)", dev.name.UTF8String, kept);
    return PASS(bug, "%s: textures, views, compile options, pipelines and depth/stencil states are freed when released, with no autorelease pool drained", dev.name.UTF8String);
}
