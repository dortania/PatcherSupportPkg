// a21-amd-wide-bit-branches (AMD adapter): branches on one bit of a 64-bit value must compile.
// libAMDIL902's DAG combiner turns a branch on `(x >> k) & 1` of a ulong (an if, or the bit-0 split of a switch on
// `uint(x >> k) & 3`) into a compare of the 64-bit `and` with 0, whose result is i64 here, and no brcond pattern takes
// it: "LLVM ERROR: Cannot select: brcond (i64 setcc ...)" (found by fuzzing with 64-bit integers; which branches reach
// that combine depends on the code around them). The adapter tests such conditions through extract_bits, which the
// combiner doesn't look into. A bool of high-half bits of a 64-bit product that is sign-extended or selected on meets
// the same i64 setcc, there in a select, which no select pattern takes either (k3).
// Checked: the fuzzed form (a ?: on bit 16 of a ulong remainder, then a ulong division using its result), a switch on
// bits of a ulong min and `d - bool(uint(x * y >> 32) & 229)` (three kernels), against the CPU on 256 threads.
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
        uint32_t input[kThreads * 4], s = 0x9e3779b9u;
        for (int i = 0; i < kThreads * 4; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out3 = [dev newBufferWithLength:kThreads * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps2];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e setComputePipelineState:ps3]; [e setBuffer:out3 offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents, *got3 = out3.contents;
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
        }
        return PASS(bug, "%s: branches, a switch and a sign-extended bool on bits of 64-bit values", dev.name.UTF8String);
    }
}
