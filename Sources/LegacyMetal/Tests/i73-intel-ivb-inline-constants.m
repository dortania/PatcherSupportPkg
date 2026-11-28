// i73-intel-ivb-inline-constants: program-scope constants in render functions must read their own data; OCLP's Ivy
// Bridge plugin left them unbound (read the app's buffer 0). Fix: IntelTextureAtomics INTEL_IVB_INLINE_CONSTANT_FIX.
// Checks: a volatile constant, a constant table at a run-time index; other GPUs always pass. Argument: GPU name.
#import "repro.h"

static uint32_t draw(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *fn, id<MTLBuffer> junk, id<MTLBuffer> sel, NSError **err) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:fn];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
    id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:pd error:err];
    if (!rp) return 0xffffffffu;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = rt;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpd];
    [re setRenderPipelineState:rp];
    [re setFragmentBuffer:junk offset:0 atIndex:0];
    [re setFragmentBuffer:sel offset:0 atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be synchronizeResource:rt];
    [be endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t px[4];
    [rt getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    return px[0];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i73-intel-ivb-inline-constants";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "volatile constexpr constant uint kMagic = 0x2468ace1u;\n"
            "constant uint kTable[4] = {0x11111111u, 0x22222222u, 0x33333333u, 0x44444444u};\n"
            "struct VO { float4 p [[position]]; };\n"
            "vertex VO vs(uint vid [[vertex_id]]) { float2 q[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; VO o; o.p = float4(q[vid], 0, 1); return o; }\n"
            "fragment uint4 scalar(VO in [[stage_in]]) { return uint4(kMagic, 0, 0, 1); }\n"
            "fragment uint4 table(VO in [[stage_in]], constant uint &sel [[buffer(1)]]) { return uint4(kTable[sel & 3], 0, 0, 1); }\n"
            options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t junkValues[4] = {0xdead0000u, 0xdead0001u, 0xdead0002u, 0xdead0003u}, index = 2;
        id<MTLBuffer> junk = [dev newBufferWithBytes:junkValues length:sizeof junkValues options:0];
        id<MTLBuffer> sel = [dev newBufferWithBytes:&index length:sizeof index options:0];
        uint32_t s = draw(dev, lib, @"scalar", junk, sel, &err);
        if (s != 0x2468ace1u) return FAIL(bug, "%s: volatile program-scope constant read %#x in a fragment function, want 0x2468ace1", dev.name.UTF8String, s);
        uint32_t t = draw(dev, lib, @"table", junk, sel, &err);
        if (t != 0x33333333u) return FAIL(bug, "%s: kTable[2] read %#x in a fragment function, want 0x33333333", dev.name.UTF8String, t);
        return PASS(bug, "%s: program-scope constants read right in fragment functions with a buffer bound at index 0", dev.name.UTF8String);
    }
}
