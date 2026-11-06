// i02-intel-vertex-signed-subword (Intel adapter, IntelTextureAtomics.dylib): signed bytes and halfwords in vertex
// functions with the 3802 Intel compiler. The sign-extended top lane of a word read from a constant buffer comes from the
// first word of its 16 bytes when it isn't that word: char4(x).w, short2(x).y, unpack_snorm4x8_to_float(x).w and
// unpack_snorm2x16_to_float(x).y (fragment and compute functions are right). ANGLE's vertex shaders unpack their Y flip,
// at byte 12 of their uniform block, with unpack_snorm4x8_to_float(...).w, so on a Haswell / Ivy Bridge GPU every WebGL
// draw collapsed and drew nothing. Each case is one conversion of a word at byte 0 or 12 of a constant buffer whose other
// words differ, as in ANGLE's shaders: a vertex function passes the result as a varying, which a fragment function
// writes to an R32Float target; a compute function does the same as the control.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

// One library per case and word position, with the field read directly: function constants are resolved after the
// front end, which then emits a different access (selecting between loads) that the back end gets right.
static NSString *source(const char *expression, const char *field) {
    return [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Words { uint a, b, c, d; };\n"
        "static float convert(uint w) { return %s; }\n"
        "struct In { float2 position [[attribute(0)]]; };\n"
        "struct Out { float4 position [[position]]; float size [[point_size]]; float value [[flat]]; };\n"
        "vertex Out v(In in [[stage_in]], constant Words &words [[buffer(17)]]) {\n"
        "    Out o; o.position = float4(in.position, 0, 1); o.size = 1; o.value = convert(words.%s); return o;\n"
        "}\n"
        "fragment float4 f(Out in [[stage_in]]) { return float4(in.value); }\n"
        "kernel void k(constant Words &words [[buffer(17)]], device float *out [[buffer(1)]]) { *out = convert(words.%s); }\n",
        expression, field, field];
}
static const char *const kExpressions[8] = {"float(as_type<char4>(w).y)", "float(as_type<char4>(w).w)", "float(int4(as_type<char4>(w)).z)",
                                            "float(as_type<short2>(w).y)", "unpack_snorm4x8_to_float(w).w", "unpack_snorm4x8_to_float(w).y",
                                            "unpack_snorm2x16_to_float(w).y", "float(unpack_snorm4x8_to_half(w).z)"};

static const uint32_t kWords[4] = {0x817F00FF, 0x80C04001, 0xFFFF8000, 0x12345678};
static const char *const kCases[8] = {"char4(x).y", "char4(x).w", "int4(char4(x)).z", "short2(x).y", "unpack_snorm4x8_to_float(x).w",
                                      "unpack_snorm4x8_to_float(x).y", "unpack_snorm2x16_to_float(x).y", "unpack_snorm4x8_to_half(x).z"};

static float reference(unsigned c, uint32_t w) {
    int8_t b[4] = {(int8_t)w, (int8_t)(w >> 8), (int8_t)(w >> 16), (int8_t)(w >> 24)};
    int16_t h1 = (int16_t)(w >> 16);
    switch (c) {
        case 0: return b[1];
        case 1: return b[3];
        case 2: return b[2];
        case 3: return h1;
        case 4: return fmaxf(b[3] / 127.0f, -1.0f);
        case 5: return fmaxf(b[1] / 127.0f, -1.0f);
        case 6: return fmaxf(h1 / 32767.0f, -1.0f);
        default: return fmaxf(b[2] / 127.0f, -1.0f);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i02-intel-vertex-signed-subword";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *error = nil;
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> fromCompute = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        static const float point[2] = {0, 0};
        unsigned wrong = 0, total = 0;
        char first[200] = "";
        for (uint32_t c = 0; c < 8; c++)
            for (uint32_t slot = 0; slot < 4; slot += 3) {
                NSString *text = [source(kExpressions[c], slot ? "d" : "a") stringByAppendingString:reproUniqueComment()];
                id<MTLLibrary> lib = [dev newLibraryWithSource:text options:nil error:&error];
                if (!lib) return FAIL(bug, "%s: %s: compile failed: %s", dev.name.UTF8String, kCases[c], error.localizedDescription.UTF8String);
                MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
                pd.vertexFunction = [lib newFunctionWithName:@"v"];
                pd.fragmentFunction = [lib newFunctionWithName:@"f"];
                MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];  // a vertex attribute, as ANGLE's shaders have
                vd.attributes[0].format = MTLVertexFormatFloat2;
                vd.attributes[0].bufferIndex = 0;  // ANGLE's buffer indices: vertex data 0, uniforms 17
                vd.layouts[0].stride = 8;
                pd.vertexDescriptor = vd;
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
                id<MTLRenderPipelineState> render = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
                id<MTLComputePipelineState> compute =
                    [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
                if (!render || !compute) return FAIL(bug, "%s: %s: pipeline failed: %s", dev.name.UTF8String, kCases[c], error.localizedDescription.UTF8String);
                for (int word = 0; word < 4; word++) {
                    // the other slots hold different values: the wrong result is the same lane of another slot
                    uint32_t words[4] = {0x01020304, 0x00000000, 0x3F800000, 0x7F7F7F7F};
                    words[slot] = kWords[word];
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = target;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(NAN, 0, 0, 0);
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                    [enc setRenderPipelineState:render];
                    [enc setVertexBytes:words length:sizeof words atIndex:17];
                    [enc setVertexBytes:point length:sizeof point atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
                    [enc endEncoding];
                    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                    [ce setComputePipelineState:compute];
                    [ce setBytes:words length:sizeof words atIndex:17];
                    [ce setBuffer:fromCompute offset:0 atIndex:1];
                    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    [ce endEncoding];
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit synchronizeResource:target];
                    [blit endEncoding];
                    if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
                    float vertexValue = NAN, computeValue = *(const float *)fromCompute.contents, want = reference(c, kWords[word]);
                    [target getBytes:&vertexValue bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
                    float tolerance = c == 7 ? 1e-3f : 1e-6f;  // half
                    if (!(fabsf(computeValue - want) <= tolerance))
                        return FAIL(bug, "%s: compute function (the control): %s of 0x%08x = %g, want %g", dev.name.UTF8String, kCases[c],
                                    kWords[word], computeValue, want);
                    total++;
                    if (!(fabsf(vertexValue - want) <= tolerance) && wrong++ == 0)
                        snprintf(first, sizeof first, "%s of 0x%08x at byte %u = %g, want %g", kCases[c], kWords[word], 4 * slot, vertexValue, want);
                }
            }
        if (wrong) return FAIL(bug, "%s: %u of %u vertex conversions wrong (compute right), first: %s", dev.name.UTF8String, wrong, total, first);
        return PASS(bug, "%s: %u signed byte / halfword conversions right in vertex functions", dev.name.UTF8String, total);
    }
}
