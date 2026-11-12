// a29-amd-lane-trunc (AMD adapter): a byte or short cut from lane 1 or higher of a vector, with a uchar2 comparison in
// the same block. libAMDIL902's DAG combiner, run again after type legalization changed the block (the uchar2 compare),
// folds `trunc (extractelement v, k)` into an extract of v bitcast to narrower lanes, and builds that from the wrong bits
// of lane k: a byte of lane 1 of a ushort2 is read from its bits 16-23, so it comes out 0 (found by differential fuzzing
// with narrow vectors: `uchar(vf(max(ushort2(62847, 9125), u) << ushort2(12, 6)))` stored into a threadgroup array).
// The adapter cuts such lanes through extract_bits.
// Checked: lane 1 of a ushort2 from max with a constant and from max of two vectors, an as_type<uchar4> byte of a min
// (all three read 0 without the fix), and lane 3 of a clamped ushort4 and the low short of lane 1 of a uint2 max, which
// the fix also rewrites, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]],\n"
    "              uint l [[thread_position_in_threadgroup]]) {\n"
    "  threadgroup uchar t0[64], t1[64], t2[64], t3[64];\n"
    "  threadgroup ushort t4[64];\n"
    "  uint a = in[4 * t], b = in[4 * t + 1], c = in[4 * t + 2], d = in[4 * t + 3];\n"
    "  uint e = (uint)all(uchar2(uchar(a), uchar(b)) != uchar2(uchar(c), uchar(d)));\n"
    "  t0[l] = uchar((max(ushort2(62847, 9125), ushort2(ushort(c), ushort(b))) << ushort2(12, 6)).y);\n"
    "  t1[l] = uchar(uchar(max(ushort2(ushort(c), ushort(b)), ushort2(ushort(a), ushort(d))).y) << 6);\n"
    "  t2[l] = uchar(as_type<uchar4>(min(ushort2(ushort(a), ushort(b)), ushort2(ushort(c), ushort(d)))).z << 3);\n"
    "  t3[l] = uchar(uchar(clamp(ushort4(ushort(a), ushort(b), ushort(c), ushort(d)), ushort4(100), ushort4(60000)).w) << 2);\n"
    "  t4[l] = ushort(ushort(max(uint2(a, b), uint2(c, d)).y) << 5);\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  out[2 * t] = uint(t0[l]) | uint(t1[l]) << 8 | uint(t2[l]) << 16 | uint(t3[l]) << 24;\n"
    "  out[2 * t + 1] = uint(t4[l]) | e << 16;\n"
    "}\n";

static uint16_t max16(uint16_t x, uint16_t y) { return x > y ? x : y; }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a29-amd-lane-trunc";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 4], seed = 0x2545f491u;
        for (int i = 0; i < kThreads * 4; i++) { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; input[i] = seed; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps]; [enc setBuffer:in offset:0 atIndex:0]; [enc setBuffer:out offset:0 atIndex:1];
        [enc dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents;
        int wrong = 0, first = -1;
        uint32_t want[2] = {0};
        for (int t = 0; t < kThreads; t++) {
            uint32_t a = input[4 * t], b = input[4 * t + 1], c = input[4 * t + 2], d = input[4 * t + 3];
            uint32_t e = (uint8_t)a != (uint8_t)c && (uint8_t)b != (uint8_t)d;
            uint8_t b0 = (uint8_t)(uint16_t)(max16(9125, (uint16_t)b) << 6);
            uint8_t b1 = (uint8_t)((uint8_t)max16((uint16_t)b, (uint16_t)d) << 6);
            uint16_t lane1 = (uint16_t)b < (uint16_t)d ? (uint16_t)b : (uint16_t)d;
            uint8_t b2 = (uint8_t)((uint8_t)lane1 << 3);
            uint16_t w = (uint16_t)d < 100 ? 100 : (uint16_t)d > 60000 ? 60000 : (uint16_t)d;
            uint8_t b3 = (uint8_t)((uint8_t)w << 2);
            uint16_t s4 = (uint16_t)((uint16_t)(b > d ? b : d) << 5);
            uint32_t w0 = b0 | b1 << 8 | b2 << 16 | (uint32_t)b3 << 24, w1 = s4 | e << 16;
            if (got[2 * t] != w0 || got[2 * t + 1] != w1) {
                if (first < 0) { first = t; want[0] = w0; want[1] = w1; }
                wrong++;
            }
        }
        if (wrong)
            return FAIL(bug, "%s: %d of %d threads wrong (thread %d: %08x %08x, want %08x %08x)", dev.name.UTF8String, wrong, kThreads,
                        first, got[2 * first], got[2 * first + 1], want[0], want[1]);
        return PASS(bug, "%s: bytes and shorts cut from lanes 1-3 of vectors, with a uchar2 comparison in the block", dev.name.UTF8String);
    }
}
