// i62-intel-halfword-bytes (Intel adapter, IntelTextureAtomics.dylib): as_type<uchar4>(ushort2) and
// as_type<char4>(short2) in vertex and fragment functions with the 3802 Intel compiler. That bitcast <2 x i16> -> <4 x i8>
// aborted the compile ("IGILTargetLowering::ReplaceNodeResults(): need to lower this!" on a v4i8 node), so the render
// pipeline failed with "Compiler encountered an internal error"; compute functions were right. Found by fuzzing fragment
// functions. The vertex function unpacks halfwords of a constant buffer and passes the bytes on (flat); the fragment
// function does the same with halfwords of a device buffer; each casts unsigned and signed, and the four results go to an
// RGBA32Uint target. Stock OCLP: FAIL (no pipeline). Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "static uint mixu(uchar4 b) { return uint(b.x) + uint(b.y) * 3u + uint(b.z) * 5u + uint(b.w) * 7u + (uint(uchar(b.x ^ b.w)) << 16); }\n"
    "static uint mixs(char4 c) { return uint(int(c.x) + int(c.y) * 3 + int(c.z) * 5 + int(c.w) * 7) ^ (uint(uchar(c.y)) << 16); }\n"
    "struct V { float4 pos [[position]]; uint u [[flat]]; uint s [[flat]]; };\n"
    "vertex V v(uint id [[vertex_id]], constant uint *w [[buffer(0)]]) {\n"
    "  V o; o.pos = float4(float(id & 1) * 4 - 1, float(id >> 1) * 4 - 1, 0, 1);\n"
    "  o.u = mixu(as_type<uchar4>(ushort2(ushort(w[0]), ushort(w[1]))));\n"
    "  o.s = mixs(as_type<char4>(short2(short(w[2]), short(w[3])))); return o; }\n"
    "fragment uint4 f(V in [[stage_in]], device const uint *w [[buffer(0)]]) {\n"
    "  uint i = uint(in.pos.x) * 4u;\n"
    "  return uint4(in.u, in.s, mixu(as_type<uchar4>(ushort2(ushort(w[i + 1]), ushort(w[i])))),\n"
    "               mixs(as_type<char4>(short2(short(w[i + 3]), short(w[i + 2]))))); }\n";

static const uint32_t kWords[4] = {0x1234ABCD, 0x00008001, 0xFFFF80FF, 0x0000017F};

static uint32_t mixu(const uint8_t b[4]) { return b[0] + b[1] * 3u + b[2] * 5u + b[3] * 7u + ((uint32_t)(b[0] ^ b[3]) << 16); }
static uint32_t mixs(const uint8_t b[4]) {
    int8_t c[4] = {(int8_t)b[0], (int8_t)b[1], (int8_t)b[2], (int8_t)b[3]};
    return (uint32_t)(c[0] + c[1] * 3 + c[2] * 5 + c[3] * 7) ^ ((uint32_t)b[1] << 16);
}
static void bytesOf(uint32_t lo, uint32_t hi, uint8_t b[4]) {  // as_type<uchar4>(ushort2(lo, hi))
    b[0] = (uint8_t)lo, b[1] = (uint8_t)(lo >> 8), b[2] = (uint8_t)hi, b[3] = (uint8_t)(hi >> 8);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i62-intel-halfword-bytes";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *src = [kSource stringByAppendingString:reproUniqueComment()];
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLBuffer> words = [dev newBufferWithBytes:kWords length:sizeof kWords options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:words offset:0 atIndex:0];
        [enc setFragmentBuffer:words offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
        uint32_t got[4] = {0};
        [target getBytes:got bytesPerRow:sizeof got fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        uint8_t b[4][4];
        bytesOf(kWords[0], kWords[1], b[0]), bytesOf(kWords[2], kWords[3], b[1]);
        bytesOf(kWords[1], kWords[0], b[2]), bytesOf(kWords[3], kWords[2], b[3]);
        uint32_t want[4] = {mixu(b[0]), mixs(b[1]), mixu(b[2]), mixs(b[3])};
        static const char *const kWhere[4] = {"vertex uchar4", "vertex char4", "fragment uchar4", "fragment char4"};
        for (int i = 0; i < 4; i++)
            if (got[i] != want[i])
                return FAIL(bug, "%s: %s from halfwords: %08x, not %08x", dev.name.UTF8String, kWhere[i], got[i], want[i]);
        return PASS(bug, "%s: as_type<uchar4>(ushort2) and as_type<char4>(short2) compile and are right in vertex and fragment functions",
                    dev.name.UTF8String);
    }
}
