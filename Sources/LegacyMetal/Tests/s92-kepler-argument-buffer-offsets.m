// s92-kepler-argument-buffer-offsets: two argument buffers packed into one buffer at the argument encoder's alignment,
// as MoltenVK packs its descriptor sets, must each read their own resources when bound at their offsets. Kepler binds a
// constant buffer in 256-byte steps (it rounds an offset down) but its encoder reported 8-byte alignment, so the second
// set read the first one's bytes; in Godot (whose first set was empty) texture handle 0: a GPU fault at address 0, the
// next command buffer failed (Invalid Resource) and the device was lost with glow on. Fix: MetalOldCompat item 89.
// Checks: set 0 holds a red texture, set 1 at encodedLength rounded up to the alignment a green one; set 1 is sampled in
// a compute kernel and in a fragment function and must read green. Prints the encoder's alignment and the offset.
// Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct AB { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
    "kernel void k(constant AB &ab [[buffer(1)]], device float4 *out [[buffer(0)]]) { out[0] = ab.t.sample(ab.s, float2(0.5), level(0)); }\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V v(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
    "fragment float4 f(V in [[stage_in]], constant AB &ab [[buffer(1)]]) { return ab.t.sample(ab.s, float2(0.5)); }\n";

static id<MTLTexture> solid(id<MTLDevice> dev, uint8_t r, uint8_t g) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint8_t px[64];
    for (int i = 0; i < 16; i++) px[i * 4] = r, px[i * 4 + 1] = g, px[i * 4 + 2] = 0, px[i * 4 + 3] = 255;
    [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
    return t;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s92-kepler-argument-buffer-offsets";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
    id<MTLTexture> red = solid(dev, 255, 0), green = solid(dev, 0, 255);
    NSUInteger align = 0, offset = 0;
    for (int way = 0; way < 2; way++) {
        const char *what = way ? "fragment function" : "compute kernel";
        id<MTLFunction> fn = [lib newFunctionWithName:way ? @"f" : @"k"];
        id<MTLArgumentEncoder> enc = [fn newArgumentEncoderWithBufferIndex:1];
        align = enc.alignment ? enc.alignment : 1;
        offset = (enc.encodedLength + align - 1) / align * align;
        id<MTLBuffer> ab = [dev newBufferWithLength:offset + enc.encodedLength options:MTLResourceStorageModeShared];
        [enc setArgumentBuffer:ab offset:0];
        [enc setTexture:red atIndex:0];
        [enc setSamplerState:sampler atIndex:1];
        [enc setArgumentBuffer:ab offset:offset];
        [enc setTexture:green atIndex:0];
        [enc setSamplerState:sampler atIndex:1];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLTexture> target = nil;
        if (!way) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&err];
            if (!ps) return FAIL(bug, "%s: compute pipeline: %s", name, err.localizedDescription.UTF8String);
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:ab offset:offset atIndex:1];
            [ce setBuffer:out offset:0 atIndex:0];
            [ce useResource:red usage:MTLResourceUsageRead];
            [ce useResource:green usage:MTLResourceUsageRead];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [ce endEncoding];
        } else {
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"v"];
            rd.fragmentFunction = fn;
            rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
            if (!ps) return FAIL(bug, "%s: render pipeline: %s", name, err.localizedDescription.UTF8String);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeManaged;
            target = [dev newTextureWithDescriptor:td];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:ps];
            [re setFragmentBuffer:ab offset:offset atIndex:1];
            [re useResource:red usage:MTLResourceUsageRead];
            [re useResource:green usage:MTLResourceUsageRead];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be synchronizeResource:target];
            [be endEncoding];
        }
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed: %s", name, what, cb.error.localizedDescription.UTF8String ?: "");
        float got[4];
        if (target) [target getBytes:got bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        else memcpy(got, out.contents, sizeof got);
        if (fabsf(got[0]) > 0.01f || fabsf(got[1] - 1) > 0.01f || fabsf(got[2]) > 0.01f || fabsf(got[3] - 1) > 0.01f)
            return FAIL(bug, "%s: %s: the argument buffer at offset %lu (encoder alignment %lu, encodedLength %lu) read (%.2f, %.2f, %.2f, %.2f), want green "
                        "(0, 1, 0, 1)%s", name, what, (unsigned long)offset, (unsigned long)align, (unsigned long)enc.encodedLength, got[0], got[1], got[2], got[3],
                        got[0] > 0.99f ? ": the first one's texture" : "");
    }
    return PASS(bug, "%s: the second of two argument buffers packed at the encoder's alignment (%lu, offset %lu) reads its own texture, compute and render",
                name, (unsigned long)align, (unsigned long)offset);
}}
