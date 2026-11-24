// n04-kepler-texture-atomics: MSL 3.1 texture atomics must work; the plugin has none (the compiler crashed). Fix:
// MetalOldCompat item 58 + GeForceAIRCompat NVAIR_TEXTURE_ATOMICS. Checks: every operation on a managed R32Uint
// texture, signed ones with ushort coordinates beside an app buffer at index 30, a private texture, a fragment
// function, an R32Sint view, and no fault without ShaderAtomic usage. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void ops(texture2d<uint, access::read_write> t [[texture(0)]], device uint *r [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i >= 333u) return;\n"
    "    uint2 c = uint2(i % 37u, i / 37u);\n"
    "    device uint *o = r + i * 16u;\n"
    "    o[0] = t.atomic_fetch_add(c, 5u).x; o[1] = t.atomic_fetch_sub(c, 2u).x;\n"
    "    o[2] = t.atomic_fetch_max(c, 7000u).x; o[3] = t.atomic_fetch_min(c, 6500u).x;\n"
    "    o[4] = t.atomic_fetch_and(c, 0xff0fu).x; o[5] = t.atomic_fetch_or(c, 0x30u).x;\n"
    "    o[6] = t.atomic_fetch_xor(c, 5u).x; o[7] = t.atomic_exchange(c, i * 3u).x;\n"
    "    uint4 e = uint4(i * 3u); o[8] = t.atomic_compare_exchange_weak(c, &e, i * 3u + 1u) ? 1u : 0u; o[9] = e.x;\n"
    "    uint4 f = uint4(12345u); o[10] = t.atomic_compare_exchange_weak(c, &f, 9u) ? 1u : 0u; o[11] = f.x;\n"
    "    o[12] = t.atomic_load(c).x; t.atomic_store(uint4(i + 77u), c); o[13] = t.atomic_load(c).x;\n"
    "    t.atomic_fetch_add(uint2(37u + i, 0u), 1u); t.atomic_fetch_add(uint2(0u, 9u + i), 1u);\n"  // outside the texture
    "}\n"
    "kernel void sops(texture2d<int, access::read_write> t [[texture(1)]], device int *r [[buffer(2)]], ushort2 g [[thread_position_in_grid]]) {\n"
    "    if (g.x >= 37 || g.y >= 9) return;\n"
    "    uint i = uint(g.y) * 37u + uint(g.x);\n"
    "    device int *o = r + i * 3u;\n"
    "    o[0] = t.atomic_fetch_min(g, -int(i)).x; o[1] = t.atomic_fetch_max(g, int(i) - 100).x; o[2] = t.atomic_fetch_add(g, -7).x;\n"
    "}\n"
    "kernel void readback(device const uint *x [[buffer(30)]], device uint *o [[buffer(3)]]) { o[0] = x[0]; }\n"
    "kernel void hot(texture2d<uint, access::read_write> t [[texture(0)]], device uint *old [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
    "    uint i = g.y * 64u + g.x;\n"
    "    old[i] = t.atomic_fetch_add(uint2(i & 1u, (i >> 1) & 1u), 1u).x;\n"
    "}\n"
    "kernel void viewadd(texture2d<int, access::read_write> t [[texture(0)]], uint i [[thread_position_in_grid]]) { t.atomic_fetch_add(uint2(1u, 0u), -3); }\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V o; float2 u = float2(float((i << 1) & 2u), float(i & 2u)); o.p = float4(u * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<uint, access::read_write> t [[texture(0)]]) {\n"
    "    t.atomic_fetch_add(uint2(0u, 0u), 1u); t.atomic_fetch_max(uint2(1u, 0u), uint(in.p.x));\n"
    "    return float4(1.0);\n"
    "}\n";

enum { W = 37, H = 9 };
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;

static id<MTLTexture> atomicTexture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLStorageMode mode, BOOL atomic) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (@available(macOS 14.0, *)) if (atomic) td.usage |= MTLTextureUsageShaderAtomic;
    td.storageMode = mode;
    return [dev newTextureWithDescriptor:td];
}
static id<MTLComputePipelineState> kernel(id<MTLLibrary> lib, NSString *name, NSError **err) {
    id<MTLFunction> f = [lib newFunctionWithName:name];
    return f ? [dev newComputePipelineStateWithFunction:f error:err] : nil;
}
static void readTexels(id<MTLTexture> t, uint32_t *out, NSUInteger w, NSUInteger h) {  // managed texture
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:t];
    [b endEncoding];
    reproRun(cb);
    [t getBytes:out bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n04-kepler-texture-atomics";
    dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    if (@available(macOS 14.0, *)) {} else return SKIP(bug, "texture atomics are MSL 3.1 (macOS 14)");
    queue = [dev newCommandQueue];
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:options error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ops = kernel(lib, @"ops", &err), sops = kernel(lib, @"sops", &err), readback = kernel(lib, @"readback", &err),
                                hot = kernel(lib, @"hot", &err), viewadd = kernel(lib, @"viewadd", &err);
    if (!ops || !sops || !readback || !hot || !viewadd) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);

    // 1. every operation
    uint32_t init[W * H], got[W * H];
    for (uint32_t k = 0; k < W * H; k++) init[k] = (k % W) + 1000u * (k / W);
    id<MTLTexture> t1 = atomicTexture(MTLPixelFormatR32Uint, W, H, MTLStorageModeManaged, YES);
    [t1 replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:init bytesPerRow:W * 4];
    id<MTLBuffer> r1 = [dev newBufferWithLength:333 * 64 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ops];
    [ce setTexture:t1 atIndex:0];
    [ce setBuffer:r1 offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(352, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: every-operation dispatch failed", dev.name.UTF8String);
    readTexels(t1, got, W, H);
    static const char *const kOp[14] = {"fetch_add", "fetch_sub", "fetch_max", "fetch_min", "fetch_and", "fetch_or", "fetch_xor", "exchange",
                                        "compare_exchange (match)", "its expected", "compare_exchange (no match)", "its expected", "load", "load after store"};
    const uint32_t *g1 = r1.contents;
    for (uint32_t i = 0; i < 333; i++) {
        uint32_t v = init[i], want[14];
        want[0] = v; v += 5; want[1] = v; v -= 2; want[2] = v; v = v > 7000 ? v : 7000; want[3] = v; v = v < 6500 ? v : 6500;
        want[4] = v; v &= 0xff0f; want[5] = v; v |= 0x30; want[6] = v; v ^= 5; want[7] = v;
        want[8] = 1; want[9] = i * 3; want[10] = 0; want[11] = i * 3 + 1; want[12] = i * 3 + 1; want[13] = i + 77;
        for (int k = 0; k < 14; k++)
            if (g1[i * 16 + k] != want[k])
                return FAIL(bug, "%s: %s on texel %u returned %u, want %u", dev.name.UTF8String, kOp[k], i, g1[i * 16 + k], want[k]);
        if (got[i] != i + 77) return FAIL(bug, "%s: texel %u is %u after the operations, want %u", dev.name.UTF8String, i, got[i], i + 77);
    }

    // 2. signed, ushort coordinates, texture(1); the app's buffer at the hidden index survives
    int32_t sinit[W * H];
    for (int k = 0; k < W * H; k++) sinit[k] = k - 50;
    id<MTLTexture> t2 = atomicTexture(MTLPixelFormatR32Sint, W, H, MTLStorageModeManaged, YES);
    [t2 replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:sinit bytesPerRow:W * 4];
    id<MTLBuffer> r2 = [dev newBufferWithLength:333 * 12 options:MTLResourceStorageModeShared];
    uint32_t mark = 0xC0FFEE;
    id<MTLBuffer> app = [dev newBufferWithBytes:&mark length:4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> seen = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    cb = [queue commandBuffer];
    ce = [cb computeCommandEncoder];
    [ce setBuffer:app offset:0 atIndex:30];
    [ce setComputePipelineState:sops];
    [ce setTexture:t2 atIndex:1];
    [ce setBuffer:r2 offset:0 atIndex:2];
    [ce dispatchThreads:MTLSizeMake(40, 9, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce setComputePipelineState:readback];
    [ce setBuffer:seen offset:0 atIndex:3];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: signed dispatch failed", dev.name.UTF8String);
    const int32_t *g2 = r2.contents;
    for (int i = 0; i < 333; i++) {
        int v = i - 50, want[3];
        want[0] = v; v = v < -i ? v : -i; want[1] = v; v = v > i - 100 ? v : i - 100; want[2] = v;
        for (int k = 0; k < 3; k++)
            if (g2[i * 3 + k] != want[k])
                return FAIL(bug, "%s: signed %s on texel %d returned %d, want %d", dev.name.UTF8String, k == 0 ? "fetch_min" : k == 1 ? "fetch_max" : "fetch_add",
                            i, g2[i * 3 + k], want[k]);
    }
    if (*(uint32_t *)seen.contents != mark)
        return FAIL(bug, "%s: after the atomics, buffer 30 read %#x, not the app's buffer (%#x)", dev.name.UTF8String, *(uint32_t *)seen.contents, mark);

    // 3. private storage, 4096 adds on 4 texels
    id<MTLTexture> t3 = atomicTexture(MTLPixelFormatR32Uint, 2, 2, MTLStorageModePrivate, YES);
    id<MTLBuffer> zero = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared], out3 = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> old = [dev newBufferWithLength:4096 * 4 options:MTLResourceStorageModeShared];
    cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromBuffer:zero sourceOffset:0 sourceBytesPerRow:8 sourceBytesPerImage:16 sourceSize:MTLSizeMake(2, 2, 1) toTexture:t3
      destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
    ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:hot];
    [ce setTexture:t3 atIndex:0];
    [ce setBuffer:old offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce endEncoding];
    be = [cb blitCommandEncoder];
    [be copyFromTexture:t3 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(2, 2, 1) toBuffer:out3
      destinationOffset:0 destinationBytesPerRow:8 destinationBytesPerImage:16];
    [be endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: private-texture dispatch failed", dev.name.UTF8String);
    const uint32_t *s3 = out3.contents, *o3 = old.contents;
    static uint8_t seen3[4][1024];
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t texel = (i & 1) | (((i >> 1) & 1) << 1);
        if (o3[i] >= 1024 || seen3[texel][o3[i]]++)
            return FAIL(bug, "%s: private texture: thread %u got old value %u twice or out of range", dev.name.UTF8String, i, o3[i]);
    }
    if (s3[0] != 1024 || s3[1] != 1024 || s3[2] != 1024 || s3[3] != 1024)
        return FAIL(bug, "%s: private texture: sums %u %u %u %u, want 1024 each", dev.name.UTF8String, s3[0], s3[1], s3[2], s3[3]);

    // 4. a fragment function
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vs"];
    rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!rps) return FAIL(bug, "%s: render pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    cd.usage = MTLTextureUsageRenderTarget;
    cd.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:cd];
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLTexture> t4 = atomicTexture(MTLPixelFormatR32Uint, 2, 1, MTLStorageModeManaged, YES);
    uint32_t z4[2] = {0, 0}, g4[2];
    [t4 replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:z4 bytesPerRow:8];
    cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:rps];
    [re setFragmentTexture:t4 atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: render pass failed", dev.name.UTF8String);
    readTexels(t4, g4, 2, 1);
    if (g4[0] != 256 || g4[1] != 15)
        return FAIL(bug, "%s: fragment atomics over 16x16 pixels: count %u (want 256), largest x %u (want 15)", dev.name.UTF8String, g4[0], g4[1]);

    // 5. through a view of another pixel format
    id<MTLTexture> t5 = atomicTexture(MTLPixelFormatR32Uint, 2, 1, MTLStorageModeManaged, YES);
    uint32_t i5[2] = {1000, 1000}, g5[2];
    [t5 replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:i5 bytesPerRow:8];
    id<MTLTexture> view = [t5 newTextureViewWithPixelFormat:MTLPixelFormatR32Sint];
    cb = [queue commandBuffer];
    ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:viewadd];
    [ce setTexture:view atIndex:0];
    [ce dispatchThreads:MTLSizeMake(100, 1, 1) threadsPerThreadgroup:MTLSizeMake(50, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: view dispatch failed", dev.name.UTF8String);
    readTexels(t5, g5, 2, 1);
    if (g5[0] != 1000 || g5[1] != 700)
        return FAIL(bug, "%s: 100 adds of -3 through an R32Sint view: texels %u %u, want 1000 700", dev.name.UTF8String, g5[0], g5[1]);

    // 6. a texture without the atomic usage: no fault
    id<MTLTexture> t6 = atomicTexture(MTLPixelFormatR32Uint, 2, 2, MTLStorageModeManaged, NO);
    cb = [queue commandBuffer];
    ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:hot];
    [ce setTexture:t6 atIndex:0];
    [ce setBuffer:old offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "%s: atomics on a texture made without MTLTextureUsageShaderAtomic faulted the command buffer", dev.name.UTF8String);

    return PASS(bug, "%s: every texture atomic right (managed, private, R32Sint, ushort coordinates, fragment function, view), the app's "
                "buffer at the hidden index kept, no fault without the atomic usage", dev.name.UTF8String);
}}
