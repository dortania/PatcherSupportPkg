// a18-amd-bitcast-lanes (AMD adapter): bytes taken out of a ushort2 reinterpreted as uchar4 must be just those bytes.
// libAMDIL902 leaves the other byte of lane 1 in the register of the narrow lanes 2 and 3, so storing one into a uchar
// array the compiler keeps in registers (four elements packed into one) also changes its neighbours. The same bitcast
// comes from the front end itself when only the low bytes of a ushort2's lanes are used (uchar(x.x ^ x.y * 257)), also
// with a constant mask applied in byte lanes before the store into a threadgroup array (found by differential fuzzing
// with narrow vectors: 29 of 400 random kernels). The adapter builds such bitcasts lane by lane.
// Checked: as_type<uchar4>(ushort2) bytes 2 and 3, as_type<char4>(short2), the low-byte form, private arrays at constant
// and run-time indices, a threadgroup array.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void privateBytes(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  uchar pc[8];\n"
    "  for (uint j = 0; j < 8u; j++) pc[j] = uchar(in[4 * t + (j & 3u)] >> j);\n"
    "  ushort2 v = ushort2(ushort(a), ushort(b)) & ushort2(ushort(c), ushort(d));\n"
    "  pc[(d >> 8) & 7u] = as_type<uchar4>(v).z;\n"
    "  pc[3] = as_type<uchar4>(ushort2(ushort(a), ushort(c)) | ushort2(ushort(b), ushort(d))).w;\n"
    "  pc[5] = uchar(as_type<char4>(short2(short(a), short(b)) ^ short2(short(d), short(c))).z);\n"
    "  pc[6] = uchar(uint(v.x) ^ uint(v.y) * 257u);\n"
    "  out[2 * t] = uint(pc[0]) | uint(pc[1]) << 8 | uint(pc[2]) << 16 | uint(pc[3]) << 24;\n"
    "  out[2 * t + 1] = uint(pc[4]) | uint(pc[5]) << 8 | uint(pc[6]) << 16 | uint(pc[7]) << 24;\n"
    "}\n"
    "kernel void sharedBytes(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]],\n"
    "                        uint l [[thread_position_in_threadgroup]]) {\n"
    "  threadgroup uchar tc[64];\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  ushort2 v = ushort2(56852, 61515) & (ushort2(ushort(a), ushort(b)) / (ushort2(ushort(c), ushort(d)) | ushort2(1)));\n"
    "  tc[l] = uchar(uint(v.x) ^ uint(v.y) * 257u);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  out[2 * t] = uint(tc[l]) | uint(tc[(l + 1) & 63u]) << 8 | uint(tc[(l + 7) & 63u]) << 16;\n"
    "  out[2 * t + 1] = 0;\n"
    "}\n";

static uint8_t sharedByte(const uint32_t *x) {
    uint16_t vx = 56852 & (uint16_t)((uint16_t)x[0] / (uint16_t)((uint16_t)x[2] | 1));
    uint16_t vy = 61515 & (uint16_t)((uint16_t)x[1] / (uint16_t)((uint16_t)x[3] | 1));
    return (uint8_t)(vx ^ vy * 257u);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a18-amd-bitcast-lanes";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], seed = 0x9e3779b9u;
        for (int i = 0; i < kThreads * 4; i++) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; input[i] = seed; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const char *kernels[] = {"privateBytes", "sharedBytes"};
        for (int k = 0; k < 2; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kernels[k])] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline %s: %s", dev.name.UTF8String, kernels[k], err.localizedDescription.UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
            [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [e endEncoding];
            reproRun(cb);
            const uint32_t *got = out.contents;
            int wrong = 0, first = -1;
            uint32_t want[2] = {0};
            for (int t = 0; t < kThreads; t++) {
                const uint32_t *x = input + 4 * t;
                uint32_t w[2];
                if (k == 0) {
                    uint8_t pc[8];
                    for (int j = 0; j < 8; j++) pc[j] = (uint8_t)(x[j & 3] >> j);
                    uint16_t vx = (uint16_t)x[0] & (uint16_t)x[2], vy = (uint16_t)x[1] & (uint16_t)x[3];
                    pc[(x[3] >> 8) & 7] = (uint8_t)vy;                                            // byte 2: low byte of lane 1
                    pc[3] = (uint8_t)(((uint16_t)x[2] | (uint16_t)x[3]) >> 8);                     // byte 3: high byte of lane 1
                    pc[5] = (uint8_t)((uint16_t)x[1] ^ (uint16_t)x[2]);                            // char4 byte 2
                    pc[6] = (uint8_t)(vx ^ vy * 257u);
                    w[0] = pc[0] | pc[1] << 8 | pc[2] << 16 | (uint32_t)pc[3] << 24;
                    w[1] = pc[4] | pc[5] << 8 | pc[6] << 16 | (uint32_t)pc[7] << 24;
                } else {
                    int l = t % 64, base = t - l;
                    w[0] = sharedByte(input + 4 * t) | sharedByte(input + 4 * (base + ((l + 1) & 63))) << 8 |
                           sharedByte(input + 4 * (base + ((l + 7) & 63))) << 16;
                    w[1] = 0;
                }
                if (got[2 * t] != w[0] || got[2 * t + 1] != w[1]) {
                    if (first < 0) { first = t; want[0] = w[0]; want[1] = w[1]; }
                    wrong++;
                }
            }
            if (wrong)
                return FAIL(bug, "%s: %s wrong in %d of %d threads (thread %d: %08x %08x, want %08x %08x)", dev.name.UTF8String, kernels[k],
                            wrong, kThreads, first, got[2 * first], got[2 * first + 1], want[0], want[1]);
        }
        return PASS(bug, "%s: bytes of reinterpreted ushort2 / short2 vectors stored into private and threadgroup uchar arrays", dev.name.UTF8String);
    }
}
