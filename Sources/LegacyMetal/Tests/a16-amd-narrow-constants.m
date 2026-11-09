// a16-amd-narrow-constants (AMD adapter, AMDTextureAtomics.dylib): 8- and 16-bit integer division and remainder. The
// front end narrows 32-bit code to i8 / i16 when the values fit (`136u / (b | 1u)` with b a uchar becomes
// `udiv i8 -120, b`), and libAMDIL902 doesn't clear or extend the upper bits of narrow values: it widens the narrow
// constant by sign extension (0xFFFFFF88) before dividing the zero-extended operand (kernel k), and divides a uchar it
// computed as ~x, kept in a register once the adapter has made a uchar array registers, with its upper bits set
// (kernel garbage; kernel vectors: the same in a uchar4 lane). The quotient, remainder, shift or comparison comes out
// wrong. Kernel loadedvec (the fuzzed form as reduced, seed 675): a char4 loaded from the buffer, compared and also used
// as an integer; the fix's zero extension of the load became an extending <4 x i32> load that the combiner left the
// integer use on ("Cannot select: i32 = bitcast"), so such loaded vectors are widened lane by lane (found by
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
    "}\n"
    "static uint vf(char2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "static uint vf(char4 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u) ^ (uint(v.z) * 65599u) ^ (uint(v.w) * 16777619u); }\n"
    "static uint vf(short2 v) { return (uint(v.x) * 1u) ^ (uint(v.y) * 257u); }\n"
    "kernel void loadedvec(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],\n"
    "              uint t [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]) {\n"
    "    threadgroup uint tg[64];\n"
    "    threadgroup uchar tc[64];\n"
    "    threadgroup atomic_uint ta;\n"
    "    if (l == 0) atomic_store_explicit(&ta, 0u, memory_order_relaxed);\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
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
    "    { tg[l] = vf((((short2((short)(1), (short)(1))).yx / short2((short)(1), (short)(1))))); threadgroup_barrier(mem_flags::mem_threadgroup); v2 += tg[(((uchar)(v1) <= (uchar)(1u) ? (uint)(pc[(v1) & 7u]) : (1u))) & 63u]; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
    "    switch ((v1) & 3u) {\n"
    "    case 0u: {\n"
    "        { uint n1 = 0u; while (n1 < 8u) { n1++;\n"
    "            v5 = vf((select(char4((char)(1), (char)(1), (char)(1), (char)(1)), (char4((char)(1), (char)(1), (char)(1), (char)(1)) % char4((char)(1), (char)(1), (char)(1), (char)(1))), char4((char)(1), (char)(1), (char)(1), (char)(1)) != as_type<char4>(in[(t * 4u + 0u)]))));\n"
    "            if (((vf((select(char2((char)(1), (char)(1)), (char2((char)(1u), (char)(((uint)((ushort)((v2 ^ t))) * (uint)((ushort)(in[(t * 4u + 0u)])))))).yx, char2((char)(1), (char)(1)) != (char2((char)(1), (char)(1)) / ((char2((char)(1u), (char)(max(1u, (v5 ^ t))))) & char2((char)(v1), (char)(v1)) | char2((char)(1), (char)(1)))))))) & 3u) == 0u) break; } v1 += n1; }\n"
    "        break; }\n"
    "    }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    out[t * 8u + 0u] = v0;\n"
    "    out[t * 8u + 1u] = v1;\n"
    "    out[t * 8u + 2u] = v2;\n"
    "    out[t * 8u + 3u] = v3;\n"
    "    out[t * 8u + 4u] = v4;\n"
    "    out[t * 8u + 5u] = v5;\n"
    "    out[t * 8u + 6u] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ (uint(pc[0]) | (uint(pc[1]) << 8u) | (uint(pc[2]) << 16u) | (uint(pc[3]) << 24u)) ^ (uint(pc[4]) * 3u + uint(pc[5]) * 5u + uint(pc[6]) * 7u + uint(pc[7]) * 11u);\n"
    "    out[t * 8u + 7u] = atomic_load_explicit(&ta, memory_order_relaxed);\n"
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

// loadedvec: the fuzzed kernel as reduced (seed 675). Its threadgroup step adds vf(short2(1, 1)) = 256 to v2, and its loop
// always leaves after one pass (the break test is vf(char2(1, 1)) & 3 == 0), so only case 0 of the switch changes v5 and v1.
static uint32_t vf4(const int8_t v[4]) { return (uint32_t)(int32_t)v[0] ^ (uint32_t)(int32_t)v[1] * 257u ^ (uint32_t)(int32_t)v[2] * 65599u ^ (uint32_t)(int32_t)v[3] * 16777619u; }
static void loadedvecReference(const uint32_t *in, uint32_t t, uint32_t out[8]) {
    uint32_t p[8];
    uint8_t pc[8];
    for (uint32_t j = 0; j < 8; j++) { p[j] = in[t * 4 + (j & 3)] + j; pc[j] = (uint8_t)(in[t * 4 + (j & 3)] >> j); }
    uint32_t v0 = in[t * 4] + t, v1 = in[t * 4 + 1] * 3 + t, v2 = in[t * 4 + 2] * 5 + t, v3 = in[t * 4 + 3] * 7 + t;
    uint32_t v4 = in[t * 4] * 9 + t, v5 = in[t * 4 + 1] * 11 + t;
    v2 += 256;
    if ((v1 & 3) == 0) {
        int8_t lanes[4];
        for (int k = 0; k < 4; k++) lanes[k] = (int8_t)(in[t * 4] >> (8 * k)) != 1 ? 0 : 1;
        v5 = vf4(lanes);
        v1 += 1;
    }
    out[0] = v0; out[1] = v1; out[2] = v2; out[3] = v3; out[4] = v4; out[5] = v5;
    out[6] = p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7] ^ ((uint32_t)pc[0] | (uint32_t)pc[1] << 8 | (uint32_t)pc[2] << 16 | (uint32_t)pc[3] << 24) ^
             (pc[4] * 3u + pc[5] * 5u + pc[6] * 7u + pc[7] * 11u);
    out[7] = 0;
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
        static const char *const names[4][8] = {{"136 / uchar", "200 % uchar", "136 % int(uchar)", "0x8001 / ushort", "0xF000 % ushort",
                                                 "200 >> n", "uchar / ushort compares", "0x8001 >> n"},
                                                {"uchar / uchar", "uchar % uchar(~x)", "", "", "", "", "", ""},
                                                {"uchar4(136) / uchar4", "ushort2(0x8001) % ushort2", "uchar4 with uchar(~x) / uchar4", "uchar4 compares",
                                                 "", "", "", ""},
                                                {"loadedvec v0", "loadedvec v1", "loadedvec v2", "loadedvec v3", "loadedvec v4",
                                                 "loadedvec v5", "loadedvec arrays", "loadedvec atomic"}};
        char report[700] = "";
        for (int k = 0; k < 4; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:k == 3 ? @"loadedvec" : k == 2 ? @"vectors" : k ? @"garbage" : @"k"]
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
                    if (k == 3) loadedvecReference(words, t, w); else if (k == 2) vectorsReference(words, t, w); else if (k) garbageReference(words, t, w); else reference(words, t, w);
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
