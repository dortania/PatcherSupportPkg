// i42-intel-folded-bitcast (Intel adapter, INTEL_CONSTANT_CALL_FIX): a vector bitcast of an integer function of
// constants. i36 folds `min(194u, 253u)` to 194; `as_type<short2>` of it is then a bitcast of a constant, which the
// 3802 LLVM leaves as a constant expression instead of two lanes, and the adapter's own folding of the `& short2(15)`
// and shift that follow read it lane by lane and crashed the compiler (mslfuzz2 VEC=1 seed 734, reduced). Such
// bitcasts are folded to their lanes now, and vectors that aren't plain constant data (a zeroinitializer, a constant
// vector with an undef lane) are no longer read lane by lane. And `clz` / `ctz` of constants, which AIR calls with a
// second, i1 operand, weren't folded at all: iCBE folded them itself and unpacked `as_type<ushort2>(clz(1827419243u))`
// as (1, 1) instead of (1, 0), the byte-reading bug of i36, so a vector lane picked with it was the wrong one in every
// thread (mslfuzz2 VEC=1 seed 896). Expected values computed here, as on the CPU. Fixed: PASS. Argument: GPU name
// substring (default: Intel).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    short2 s = as_type<short2>(char4((char)115, (char)-29, (char)-119, (char)-18)) >> (as_type<short2>(min(194u, 253u)) & short2(15));\n"
    "    out[t * 8u + 0u] = as_type<uint>(s) ^ in[t];\n"
    "    ushort2 z = as_type<ushort2>(in[t]) << (as_type<ushort2>(max(0u, 0u)) & ushort2(15));\n"
    "    out[t * 8u + 1u] = as_type<uint>(z);\n"
    "    uchar4 b = as_type<uchar4>(in[t]) >> (as_type<uchar4>(clamp(0x07050301u, 0u, 0xffffffffu)) & uchar4(7));\n"
    "    out[t * 8u + 2u] = as_type<uint>(b);\n"
    "    out[t * 8u + 3u] = as_type<uint>(as_type<short2>(min(0x80017fffu, 0xffffffffu)) >> short2(1, 15));\n"
    "    ushort2 h = as_type<ushort2>(clz(1827419243u));\n"
    "    out[t * 8u + 4u] = (uint(h.x) + in[t]) ^ (uint(h.y) << 16);\n"
    "    out[t * 8u + 5u] = ctz(0x1000u) + in[t];\n"
    "}\n";

static void reference(uint32_t x, uint32_t *out) {  // out[0..5]
    // as_type<short2>(char4(115, -29, -119, -18)) = (0xe373, 0xee89); shifts (194 & 15, 0) = (2, 0), arithmetic
    int16_t s0 = (int16_t)0xe373 >> 2, s1 = (int16_t)0xee89;
    out[0] = ((uint32_t)(uint16_t)s0 | (uint32_t)(uint16_t)s1 << 16) ^ x;
    out[1] = x;  // shifts of 0
    uint32_t b = 0;
    const unsigned shifts[4] = {1, 3, 5, 7};
    for (int k = 0; k < 4; k++) b |= (uint32_t)(uint8_t)((uint8_t)(x >> (8 * k)) >> shifts[k]) << (8 * k);
    out[2] = b;
    int16_t h0 = (int16_t)0x7fff >> 1, h1 = (int16_t)0x8001 >> 15;
    out[3] = (uint32_t)(uint16_t)h0 | (uint32_t)(uint16_t)h1 << 16;
    out[4] = 1 + x;   // clz(1827419243) = 1: as ushort2 (1, 0)
    out[5] = 12 + x;  // ctz(0x1000)
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i42-intel-folded-bitcast";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) return FAIL(bug, "pipeline: %s", err.localizedDescription.UTF8String);
    enum { T = 64 };
    id<MTLBuffer> input = [dev newBufferWithLength:T * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
    uint32_t x = 2654435761u, *in = input.contents;
    for (int i = 0; i < T; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; in[i] = x; }
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:input offset:0 atIndex:0];
    [ce setBuffer:output offset:0 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(T, 1, 1)];
    [ce endEncoding];
    if (!reproRun(cb)) return FAIL(bug, "command buffer failed");
    for (int t = 0; t < T; t++) {
        uint32_t want[6], *got = (uint32_t *)output.contents + 8 * t;
        reference(in[t], want);
        for (int w = 0; w < 6; w++)
            if (got[w] != want[w]) return FAIL(bug, "thread %d, out[%d]: %08x, want %08x", t, w, got[w], want[w]);
    }
    return PASS(bug, "bitcasts of folded integer functions compile and compute right");
}}
