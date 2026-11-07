// a16-amd-narrow-constants (AMD adapter, AMDTextureAtomics.dylib): 8- and 16-bit integer division and remainder. The
// front end narrows 32-bit code to i8 / i16 when the values fit (`136u / (b | 1u)` with b a uchar becomes
// `udiv i8 -120, b`), and libAMDIL902 doesn't clear or extend the upper bits of narrow values: it widens the narrow
// constant by sign extension (0xFFFFFF88) before dividing the zero-extended operand (kernel k), and divides a uchar it
// computed as ~x, kept in a register once the adapter has made a uchar array registers, with its upper bits set
// (kernel garbage; kernel vectors: the same in a uchar4 lane). The quotient, remainder, shift or comparison comes out
// wrong (found by
// differential fuzzing). uchar and ushort values read from private arrays (what lets the front end narrow), each operation against 136 / 200 / 0x8001 / 0xF000,
// 256 threads, checked against the same code on the CPU. Stock OCLP: FAIL. Fixed: PASS.
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar c[8];\n"
    "    ushort h[4];\n"
    "    for (uint j = 0; j < 8u; j++) c[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    for (uint j = 0; j < 4u; j++) h[j] = ushort(in[t * 4u + j] >> (j + 8u));\n"
    "    out[t * 8u + 0u] = 136u / (uint(c[1]) | 1u);\n"
    "    out[t * 8u + 1u] = 200u % (uint(c[2]) | 1u);\n"
    "    out[t * 8u + 2u] = uint(136 % int(uint(c[3]) | 1u));\n"
    "    out[t * 8u + 3u] = 0x8001u / (uint(h[0]) | 1u);\n"
    "    out[t * 8u + 4u] = 0xF000u % (uint(h[1]) | 1u);\n"
    "    out[t * 8u + 5u] = 200u >> (uint(c[5]) & 7u);\n"
    "    out[t * 8u + 6u] = uint(c[6] == uchar(0x88u)) | (uint(c[7] < uchar(200u)) << 1u) | (uint(h[2] > ushort(0x8001u)) << 2u);\n"
    "    out[t * 8u + 7u] = 0x8001u >> (uint(h[3]) & 15u);\n"
    "}\n"
    "kernel void garbage(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar c[8];\n"
    "    for (uint j = 0; j < 8u; j++) c[j] = uchar(in[t * 4u + (j & 3u)] >> j);\n"
    "    c[1] = uchar(~in[t * 4u + 2u]);\n"
    "    out[t * 8u + 0u] = uint(c[in[t * 4u] & 7u]) / (uint(c[in[t * 4u + 3u] & 7u]) | 1u);\n"
    "    out[t * 8u + 1u] = uint(c[in[t * 4u + 1u] & 7u]) % (uint(c[1]) | 1u);\n"
    "    for (uint w = 2u; w < 8u; w++) out[t * 8u + w] = 0u;\n"
    "}\n"
    "kernel void vectors(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "    uchar4 c0 = as_type<uchar4>(in[t * 4u]), c1 = as_type<uchar4>(in[t * 4u + 1u]);\n"
    "    ushort2 h0 = as_type<ushort2>(in[t * 4u + 2u]);\n"
    "    uchar4 m = c1;\n"
    "    m.y = uchar(~in[t * 4u]);\n"
    "    bool4 eq = c1 == uchar4(0x88), lt = c0 < uchar4(200);\n"
    "    out[t * 8u + 0u] = as_type<uint>(uchar4(136) / (c0 | uchar4(1)));\n"
    "    out[t * 8u + 1u] = as_type<uint>(ushort2(0x8001) % (h0 | ushort2(1)));\n"
    "    out[t * 8u + 2u] = as_type<uint>(m / (c0 | uchar4(1)));\n"
    "    out[t * 8u + 3u] = uint(eq.x) | uint(eq.y) << 1u | uint(lt.z) << 2u | uint(lt.w) << 3u;\n"
    "    for (uint w = 4u; w < 8u; w++) out[t * 8u + w] = 0u;\n"
    "}\n";

static void vectorsReference(const uint32_t *in, uint32_t t, uint32_t out[8]) {
    uint8_t c0[4], c1[4], m[4];
    uint16_t h0[2];
    memset(out, 0, 8 * sizeof *out);
    for (int k = 0; k < 4; k++) {
        c0[k] = (uint8_t)(in[t * 4] >> (8 * k));
        c1[k] = m[k] = (uint8_t)(in[t * 4 + 1] >> (8 * k));
    }
    m[1] = (uint8_t)~in[t * 4];
    for (int k = 0; k < 2; k++) h0[k] = (uint16_t)(in[t * 4 + 2] >> (16 * k));
    for (int k = 0; k < 4; k++) out[0] |= (uint32_t)(uint8_t)(136 / (c0[k] | 1)) << (8 * k);
    for (int k = 0; k < 2; k++) out[1] |= (uint32_t)(uint16_t)(0x8001 % (h0[k] | 1)) << (16 * k);
    for (int k = 0; k < 4; k++) out[2] |= (uint32_t)(uint8_t)(m[k] / (c0[k] | 1)) << (8 * k);
    out[3] = (c1[0] == 0x88) | (c1[1] == 0x88) << 1 | (c0[2] < 200) << 2 | (c0[3] < 200) << 3;
}

static void garbageReference(const uint32_t *in, uint32_t t, uint32_t out[8]) {
    uint8_t c[8];
    for (uint32_t j = 0; j < 8; j++) c[j] = (uint8_t)(in[t * 4 + (j & 3)] >> j);
    c[1] = (uint8_t)~in[t * 4 + 2];
    memset(out, 0, 8 * sizeof *out);
    out[0] = c[in[t * 4] & 7] / (c[in[t * 4 + 3] & 7] | 1u);
    out[1] = c[in[t * 4 + 1] & 7] % (c[1] | 1u);
}

static void reference(const uint32_t *in, uint32_t t, uint32_t out[8]) {
    uint8_t c[8];
    uint16_t h[4];
    for (uint32_t j = 0; j < 8; j++) c[j] = (uint8_t)(in[t * 4 + (j & 3)] >> j);
    for (uint32_t j = 0; j < 4; j++) h[j] = (uint16_t)(in[t * 4 + j] >> (j + 8));
    out[0] = 136u / (c[1] | 1u);
    out[1] = 200u % (c[2] | 1u);
    out[2] = (uint32_t)(136 % (int)(c[3] | 1u));
    out[3] = 0x8001u / (h[0] | 1u);
    out[4] = 0xF000u % (h[1] | 1u);
    out[5] = 200u >> (c[5] & 7);
    out[6] = (c[6] == 0x88) | ((c[7] < 200) << 1) | ((h[2] > 0x8001) << 2);
    out[7] = 0x8001u >> (h[3] & 15);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a16-amd-narrow-constants";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[src stringByAppendingString:reproUniqueComment()] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: library: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        enum { T = 256 };
        id<MTLBuffer> in = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        uint32_t x = 2654435761u + 12345u, *words = in.contents;
        for (int i = 0; i < T * 4; i++) {  // the fuzzer's input: xorshift, every 7th word small
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            words[i] = i % 7 == 0 ? (x & 0xff) : x;
        }
        words[4 + 2] = 0x88u << 6;  // thread 1: c[6] == 0x88
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        static const char *const names[3][8] = {{"136 / uchar", "200 % uchar", "136 % int(uchar)", "0x8001 / ushort", "0xF000 % ushort",
                                                 "200 >> n", "uchar / ushort compares", "0x8001 >> n"},
                                                {"uchar / uchar", "uchar % uchar(~x)", "", "", "", "", "", ""},
                                                {"uchar4(136) / uchar4", "ushort2(0x8001) % ushort2", "uchar4 with uchar(~x) / uchar4", "uchar4 compares",
                                                 "", "", "", ""}};
        char report[700] = "";
        for (int k = 0; k < 3; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:k == 2 ? @"vectors" : k ? @"garbage" : @"k"]
                                                                                 error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:T * 32 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", dev.name.UTF8String);
            for (int i = 0; i < 8; i++) {
                int wrong = 0, first = -1;
                uint32_t got = 0, want = 0;
                for (uint32_t t = 0; t < T; t++) {
                    uint32_t w[8];
                    if (k == 2) vectorsReference(words, t, w); else if (k) garbageReference(words, t, w); else reference(words, t, w);
                    uint32_t g = ((uint32_t *)out.contents)[t * 8 + i];
                    if (g != w[i] && wrong++ == 0) { first = (int)t; got = g; want = w[i]; }
                }
                if (wrong) {
                    char line[140];
                    snprintf(line, sizeof line, "%s%s: %d of %d wrong (thread %d: %u, want %u)", report[0] ? "; " : "", names[k][i], wrong, T, first, got, want);
                    strlcat(report, line, sizeof report);
                }
            }
        }
        if (report[0]) return FAIL(bug, "%s: %s", dev.name.UTF8String, report);
        return PASS(bug, "%s: uchar / ushort division, remainder, shifts and compares (scalars and vectors) come out right", dev.name.UTF8String);
    }
}
