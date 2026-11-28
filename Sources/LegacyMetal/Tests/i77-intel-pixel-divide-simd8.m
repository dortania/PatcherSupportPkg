// i77-intel-pixel-divide-simd8: an integer divide in a branch of a SIMD16 pixel kernel must see earlier stores; split
// in two, a moved read saw the value before the store. Fix: IntelTextureAtomics INTEL_PIXEL_DIVIDE_SIMD8_FIX.
// Checks: a reduced fragment kernel, one pixel per input of a 256x1 target, hash vs the CPU. Argument: GPU name.
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "vertex float4 vfull(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); return float4(q * 2.0 - 1.0, 0.0, 1.0); }\n"
    "fragment float4 k(float4 pos [[position]], device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "    uint t = uint(pos.x);\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[(t * 4u + (j & 3u))] + j;\n"
    "    uchar pc[8];\n"
    "    for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[(t * 4u + (j & 3u))] >> j);\n"
    "    uint v0 = in[(t * 4u + 0u)] * 1u + t;\n"
    "    uint v1 = in[(t * 4u + 1u)] * 3u + t;\n"
    "    uint v2 = in[(t * 4u + 2u)] * 5u + t;\n"
    "    uint v3 = in[(t * 4u + 3u)] * 7u + t;\n"
    "    uint v4 = in[(t * 4u + 0u)] * 9u + t;\n"
    "    uint v5 = in[(t * 4u + 1u)] * 11u + t;\n"
    "    for (uint i0 = 0; i0 < 5u; i0++) {\n"
    "        v5 += i0 * 6u;\n"
    "        { uint4 w = uint4((uint)(!((~v4) > ((in[(t * 4u + 3u)] & 1u) != 0u ? 3156069697u : 11u))), v2, (uint)(min((int)(((uint)((int)((char)((v2 ^ t)))) * 891124867u)), (int)(((v2 ^ t) > v3 ? (v2 ^ t) : (v2 ^ t))))), v1); w[(((mulhi((v0 ^ t), (v0 ^ t)) % ((1u != 0u ? (v0 ^ t) : in[(t * 4u + 1u)]) | 1u)))) & 3u] = rotate(insert_bits((v5 ^ t), in[(t * 4u + 1u)], (uint)(31u & 15u), (uint)(in[(t * 4u + 2u)] & 15u)), in[(t * 4u + 2u)]); v0 += w[(popcount((in[(t * 4u + 1u)] >> (v3 & 31u)))) & 3u] ^ (w.y << 1u) ^ w.w; }\n"
    "        v2 ^= extract_bits((v1 ^ t), (uint)(extract_bits(((uint)((int)((char)(v4))) * 244u), (uint)(insert_bits((v5 ^ t), v0, (uint)(178u & 15u), (uint)(48u & 15u)) & 15u), (uint)((uint)(-(int)(102u & 0x7fffffffu)) & 15u)) & 15u), (uint)((uint)(!((uint)((int)(127u) % (int)(((v2 ^ t) | 1u) & 0x7fffffffu)) > extract_bits(in[(t * 4u + 3u)], (uint)(in[(t * 4u + 3u)] & 15u), (uint)(in[(t * 4u + 2u)] & 15u)))) & 15u));\n"
    "    }\n"
    "    switch (((uint)((ushort)(((uint)((int)((char)(v5))) ^ in[(t * 4u + 3u)])))) & 3u) {\n"
    "    case 0u: {\n"
    "        v5 -= (v0 / ((uint)((ushort)(rhadd(93u, in[(t * 4u + 0u)])) | (ushort)((uint)(-(int)1u))) | 1u));\n"
    "        break; }\n"
    "    }\n"
    "    v0 = in[(t * 4u + 2u)];\n"
    "    v2 += (uint)((int)((uint)(pc[(((v2 % ((v5 ^ t) | 1u)))) & 7u])) % (int)(((uint)(select((int)(((v2 ^ t) != v3 ? in[(t * 4u + 1u)] : (v4 ^ t))), (int)((uint)((short)(v1))), ((((v3 ^ t) & 1u) != 0u ? in[(t * 4u + 3u)] : v5) & 2u) != 0u)) | 1u) & 0x7fffffffu));\n"
    "    // end\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = 0u;\n"
    "    return float4(0.0);\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i77-intel-pixel-divide-simd8";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:options error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vfull"];
    pd.fragmentFunction = [lib newFunctionWithName:@"k"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 256 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:T height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    // FNV-1a of the 2048 output bytes' words, from the shader run on the CPU (the fuzzer's cpuref.py, FRAG=1) on inputs 1-3
    const uint32_t expected[] = {0x33c100f4, 0x1d3c9b35, 0x2ff774f5};
    for (unsigned s = 0; s < 3; s++) {
        uint32_t x = (s + 1) * 2654435761u + 12345u, *in = input.contents;
        for (unsigned i = 0; i < T * 4; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = i % 7 == 0 ? x & 255u : x; }
        memset(output.contents, 0xcd, T * 32);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re setFragmentBuffer:input offset:0 atIndex:0];
        [re setFragmentBuffer:output offset:0 atIndex:1];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "command buffer failed");
        uint32_t h = 2166136261u;
        const uint32_t *o = output.contents;
        for (unsigned i = 0; i < T * 8; i++)
            for (unsigned b = 0; b < 4; b++) { h ^= (o[i] >> (8 * b)) & 0xff; h *= 16777619u; }
        if (h != expected[s]) return FAIL(bug, "%s: input %u: output hash %08x, the CPU's %08x", dev.name.UTF8String, s + 1, h, expected[s]);
    }
    return PASS(bug, "%s: a pixel shader dividing in a branch after a run-time lane store: matches the CPU on 3 inputs", dev.name.UTF8String);
}}
