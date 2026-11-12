// a21-amd-wide-bit-branches (AMD adapter): branches on one bit of a 64-bit value must compile.
// libAMDIL902's DAG combiner turns a branch on `(x >> k) & 1` of a ulong (an if, or the bit-0 split of a switch on
// `uint(x >> k) & 3`) into a compare of the 64-bit `and` with 0, whose result is i64 here, and no brcond pattern takes
// it: "LLVM ERROR: Cannot select: brcond (i64 setcc ...)" (found by fuzzing with 64-bit integers; which branches reach
// that combine depends on the code around them). The adapter tests such conditions through extract_bits, which the
// combiner doesn't look into. A bool of high-half bits of a 64-bit product that is sign-extended or selected on meets
// the same i64 setcc, there in a select, which no select pattern takes either (k3). So does such a bool worked out in an
// earlier block: k4's f, from a 64-bit and tested != 0 (which the adapter's wide-compare fix splits into 32-bit halves),
// is sign-extended after a loop, where the combiner folded the halves back into an i64 compare (seed 3227).
// Checked: the fuzzed form (a ?: on bit 16 of a ulong remainder, then a ulong division using its result), a switch on
// bits of a ulong min, `d - bool(uint(x * y >> 32) & 229)` and k4 (four kernels), against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
// k is the fuzzed form as reduced: the branch only survives to instruction selection while the loads in the ?: arm are
// used nowhere else (else they are hoisted, and the ?: becomes a select), so k doesn't use c. k2: a switch.
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], d = in[4 * t + 3];\n"
    "  uint v = b * 11u + t;\n"
    "  v = ((uint)((((ulong)max(v ^ t, d) | 1ul) % ((((ulong)(uint)(char)(a ^ t)) << 32) | (ulong)(uint)(short)b | 1ul)) >> 16) & 1u) != 0u\n"
    "      ? (((int)v > (int)in[4 * t + 2] ? in[4 * t + 3] : 1u) & 15u) : ~0u;\n"
    "  v ^= (uint)(0x100000001ul / ((((ulong)insert_bits(in[4 * t + 3], b ^ t, 1u, in[4 * t + 3] & 15u)) << 32) | (ulong)(v ^ t) | 1ul));\n"
    "  out[2 * t] = v;\n"
    "}\n"
    "kernel void k2(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  ulong w = (ulong(a) << 32) | ulong(b), x = (ulong(c) << 32) | ulong(d);\n"
    "  uint u = c;\n"
    "  switch (uint(min(w, x) >> 16) & 3u) {\n"
    "  case 0u: u += 1u; break;\n"
    "  case 1u: u ^= 0x10u; break;\n"
    "  case 2u: u -= 5u; break;\n"
    "  default: u *= 3u; break;\n"
    "  }\n"
    "  out[2 * t + 1] = u;\n"
    "}\n"
    "kernel void k3(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  ulong x = (ulong(a) << 32) | b, y = (ulong(c) << 32) | d;\n"
    "  out[t] = d + (uint)(-(int)(((uint)((x * y) >> 32) & 229u) != 0u));\n"
    "}\n"
    "kernel void k4(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint v0 = in[4 * t] + t, v1 = in[4 * t + 1] * 3u + t, v2 = in[4 * t + 2] * 5u + t, v3 = in[4 * t + 3] * 7u + t;\n"
    "  uint v4 = in[4 * t] * 9u + t, p[8], n = 0u;\n"
    "  for (uint j = 0u; j < 8u; j++) p[j] = in[4 * t + (j & 3u)] + j;\n"
    "  uint f = (uint)(bool)((uint)(((((ulong)v0 << 32) | (ulong)v2) << (v1 & 31u)) >> 32) & (uint)(((ulong)v4 << 32) / ((ulong)v3 | 1ul)));\n"
    "  while (n < 8u) { n++; if (((v3 >> n) & 3u) == 0u) break; }\n"
    "  v1 += n;\n"
    "  v4 ^= p[((uint)(ushort)((ushort)v3 - (ushort)f) >> (v1 & 7u)) & 7u];\n"
    "  ulong a = ((ulong)(f ^ t) << 32) | (ulong)f, b = ((ulong)v2 << 32) | (ulong)v1;\n"
    "  v1 = v2 ^ (uint)((long)a > (long)b ? a >> 7 : 0ul);\n"
    "  p[((v4 & 1u) != 0u ? 192u / (v1 | 1u) : v2) & 7u] = 0u;\n"
    "  out[t] = v1 ^ v4 ^ (f << 31) ^ p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];\n"
    "}\n";

static uint32_t insertBits(uint32_t base, uint32_t insert, uint32_t offset, uint32_t bits) {
    uint32_t mask = bits >= 32 ? ~0u : (1u << bits) - 1;
    return (base & ~(mask << offset)) | ((insert & mask) << offset);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a21-amd-wide-bit-branches";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps2 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k2"] error:&err];
        if (!ps2) return FAIL(bug, "%s: pipeline k2: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps3 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k3"] error:&err];
        if (!ps3) return FAIL(bug, "%s: pipeline k3: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps4 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k4"] error:&err];
        if (!ps4) return FAIL(bug, "%s: pipeline k4: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], s = 0x9e3779b9u;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out3 = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out4 = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps2];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps3]; [e setBuffer:out3 offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps4]; [e setBuffer:out4 offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents, *got3 = out3.contents, *got4 = out4.contents;
        for (int t = 0; t < kThreads; t++) {
            uint32_t a = input[4 * t], b = input[4 * t + 1], c = input[4 * t + 2], d = input[4 * t + 3];
            uint32_t v = b * 11 + t, m = (v ^ t) > d ? (v ^ t) : d;
            uint64_t num = (uint64_t)m | 1, den = ((uint64_t)(uint32_t)(int32_t)(int8_t)(a ^ t) << 32) | (uint64_t)(uint32_t)(int32_t)(int16_t)b | 1;
            v = ((uint32_t)((num % den) >> 16) & 1) ? (((int32_t)v > (int32_t)c ? d : 1u) & 15) : ~0u;
            v ^= (uint32_t)(0x100000001ull / (((uint64_t)insertBits(d, b ^ t, 1, d & 15) << 32) | (uint64_t)(v ^ t) | 1));
            uint64_t w = ((uint64_t)a << 32) | b, x = ((uint64_t)c << 32) | d;
            uint32_t u = c;
            switch ((uint32_t)((w < x ? w : x) >> 16) & 3) {
            case 0: u += 1; break;
            case 1: u ^= 0x10; break;
            case 2: u -= 5; break;
            default: u *= 3; break;
            }
            if (got[2 * t] != v || got[2 * t + 1] != u)
                return FAIL(bug, "%s: thread %d: %08x %08x, want %08x %08x", dev.name.UTF8String, t, got[2 * t], got[2 * t + 1], v, u);
            uint32_t s3 = d + (uint32_t)(-(int32_t)((((uint32_t)((w * x) >> 32)) & 229) != 0));
            if (got3[t] != s3) return FAIL(bug, "%s: k3 thread %d: %08x, want %08x", dev.name.UTF8String, t, got3[t], s3);
            uint32_t v0 = a + t, v1 = b * 3 + t, v2 = c * 5 + t, v3 = d * 7 + t, v4 = a * 9 + t, p[8], n = 0;
            for (uint32_t j = 0; j < 8; j++) p[j] = input[4 * t + (j & 3)] + j;
            uint32_t f = ((uint32_t)(((((uint64_t)v0 << 32) | v2) << (v1 & 31)) >> 32) & (uint32_t)(((uint64_t)v4 << 32) / ((uint64_t)v3 | 1))) != 0;
            while (n < 8) { n++; if (((v3 >> n) & 3) == 0) break; }
            v1 += n;
            v4 ^= p[((uint32_t)(uint16_t)((uint16_t)v3 - (uint16_t)f) >> (v1 & 7)) & 7];
            uint64_t a4 = ((uint64_t)(f ^ (uint32_t)t) << 32) | f, b4 = ((uint64_t)v2 << 32) | v1;
            v1 = v2 ^ (uint32_t)((int64_t)a4 > (int64_t)b4 ? a4 >> 7 : 0);
            p[((v4 & 1) ? 192 / (v1 | 1) : v2) & 7] = 0;
            uint32_t s4 = v1 ^ v4 ^ (f << 31) ^ p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4] ^ p[5] ^ p[6] ^ p[7];
            if (got4[t] != s4) return FAIL(bug, "%s: k4 thread %d: %08x, want %08x", dev.name.UTF8String, t, got4[t], s4);
        }
        return PASS(bug, "%s: branches, a switch and sign-extended bools on bits of 64-bit values, one from an earlier block", dev.name.UTF8String);
    }
}
