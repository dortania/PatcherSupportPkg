// i63-intel-late-saturation (Intel adapter, IntelTextureAtomics.dylib): saturating adds and subtracts whose operands
// become constant only when the Intel compiler unrolls a loop. The back end folds addsat / subsat of two constants as a
// plain add / subtract (i38 folds the ones with constant operands in the source), and in loops with a constant trip
// count addsat(i, ...) has constant operands in every unrolled copy of the body. Signed addsat and subsat came out
// unsaturated, and an unsigned addsat picking a private array element (p[addsat(i, -i) & 7]) made a value read in the
// same iteration take its next value. Found by fuzzing fragment functions (compute functions are the same). Each thread
// runs three such loops: the unsigned one next to that read, a signed addsat and a signed subsat that saturate from the
// third iteration on. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const kSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void ka(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    uint v0 = in[t * 4u] + t, v2 = in[t * 4u + 2u] * 5u + t, v3 = in[t * 4u + 3u] * 7u + t;\n"
    "    uint v4 = in[t * 4u] * 9u + t, v5 = in[t * 4u + 1u] * 11u + t;\n"
    "    for (uint i = 0; i < 5u; i++) {\n"
    "        v3 = (v5 ^ t) & 15u;\n"
    "        v5 ^= p[addsat(i, (uint)(-(int)i)) & 7u];\n"
    "    }\n"
    "    out[t * 8u] = v0; out[t * 8u + 1u] = 0u; out[t * 8u + 2u] = v2; out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4; out[t * 8u + 5u] = v5; out[t * 8u + 6u] = 0u; out[t * 8u + 7u] = 0u;\n"
    "}\n"
    "kernel void kb(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uint p[8];\n"
    "    for (uint j = 0; j < 8u; j++) p[j] = in[t * 4u + (j & 3u)] + j;\n"
    "    uint b = 0u, c = 0u;\n"
    "    for (uint i = 0; i < 5u; i++) b = b * 3u + p[(uint)addsat((int)i + 2147483643, 2) & 7u];\n"
    "    for (uint i = 0; i < 5u; i++) c = c * 5u + p[(uint)subsat(-(int)i - 2147483645, 2) & 7u];\n"
    "    out[t * 8u] = b; out[t * 8u + 1u] = c;\n"
    "    for (uint j = 2; j < 8u; j++) out[t * 8u + j] = 0u;\n"
    "}\n";

enum { N = 256 };

static uint32_t addsatU(uint32_t a, uint32_t b) { return a + b < a ? 0xffffffffu : a + b; }
static int32_t addsatS(int32_t a, int32_t b) { int64_t s = (int64_t)a + b; return s > INT32_MAX ? INT32_MAX : s < INT32_MIN ? INT32_MIN : (int32_t)s; }
static int32_t subsatS(int32_t a, int32_t b) { int64_t s = (int64_t)a - b; return s > INT32_MAX ? INT32_MAX : s < INT32_MIN ? INT32_MIN : (int32_t)s; }

static void reference(const uint32_t *in, uint32_t t, uint32_t a[8], uint32_t b8[8]) {
    uint32_t p[8];
    for (uint32_t j = 0; j < 8; j++) p[j] = in[t * 4 + (j & 3)] + j;
    uint32_t v0 = in[t * 4] + t, v2 = in[t * 4 + 2] * 5 + t, v3 = in[t * 4 + 3] * 7 + t, v4 = in[t * 4] * 9 + t;
    uint32_t v5 = in[t * 4 + 1] * 11 + t, b = 0, c = 0;
    for (uint32_t i = 0; i < 5; i++) {
        v3 = (v5 ^ t) & 15;
        v5 ^= p[addsatU(i, (uint32_t)-(int32_t)i) & 7];
    }
    for (int32_t i = 0; i < 5; i++) b = b * 3 + p[(uint32_t)addsatS(i + 2147483643, 2) & 7];
    for (int32_t i = 0; i < 5; i++) c = c * 5 + p[(uint32_t)subsatS(-i - 2147483645, 2) & 7];
    uint32_t ra[8] = {v0, 0, v2, v3, v4, v5, 0, 0}, rb[8] = {b, c, 0, 0, 0, 0, 0, 0};
    memcpy(a, ra, sizeof ra), memcpy(b8, rb, sizeof rb);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i63-intel-late-saturation";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.fastMathEnabled = NO;  // the fuzzer's compile options, inputs and dispatch, under which it was found
        id<MTLLibrary> lib = [dev newLibraryWithSource:[kSource stringByAppendingString:reproUniqueComment()] options:options error:&err];
        if (!lib) return FAIL(bug, "front end: %s", err.localizedDescription.UTF8String);
        id<MTLBuffer> in = [dev newBufferWithLength:N * 16 options:MTLResourceStorageModeShared];
        uint32_t *words = in.contents, x = 2654435761u + 12345u;  // xorshift, every 7th word a byte
        for (int i = 0; i < N * 4; i++) x ^= x << 13, x ^= x >> 17, x ^= x << 5, words[i] = i % 7 ? x : x & 0xff;
        static const char *const kWhat[2][8] = {{"", "", "", "a value read next to p[addsat(i, -i)]", "", "the unsigned loop's value"},
                                                {"the signed addsat loop", "the signed subsat loop"}};
        for (int which = 0; which < 2; which++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:which ? @"kb" : @"ka"] error:&err];
            if (!ps) return FAIL(bug, "%s: no pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:N * 32 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:ps];
            [enc setBuffer:in offset:0 atIndex:0];
            [enc setBuffer:out offset:0 atIndex:1];
            [enc dispatchThreadgroups:MTLSizeMake(N / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            const uint32_t *got = out.contents;
            int wrong[8] = {0}, first[8] = {-1, -1, -1, -1, -1, -1, -1, -1};
            for (uint32_t t = 0; t < N; t++) {
                uint32_t want[2][8];
                reference(words, t, want[0], want[1]);
                for (int k = 0; k < 8; k++)
                    if (got[t * 8 + k] != want[which][k]) wrong[k]++, first[k] = first[k] < 0 ? (int)t : first[k];
            }
            for (int k = 0; k < 8; k++)
                if (wrong[k]) {
                    uint32_t want[2][8];
                    reference(words, (uint32_t)first[k], want[0], want[1]);
                    return FAIL(bug, "%s: %s wrong in %d of %d threads (thread %d: %08x, want %08x)", dev.name.UTF8String,
                                kWhat[which][k][0] ? kWhat[which][k] : "a value outside the loop", wrong[k], N, first[k],
                                got[first[k] * 8 + k], want[which][k]);
                }
        }
        return PASS(bug, "%s: addsat / subsat with operands made constant by unrolling are exact (%d threads)", dev.name.UTF8String, N);
    }
}
