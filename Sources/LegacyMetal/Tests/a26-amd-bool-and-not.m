// a26-amd-bool-and-not (AMD adapter): `bool(~b & uint(bool(a))) | (a & 0xffff)` must compile.
// The IR, or (and (zext (a != 0)), ~b), (and a, 0xffff), sends libAMDIL902's bit-field-insert combine
// (ILTargetLowering::AnalyzeBFICombine) to read the operands of an operand that has none: "Compiler encountered an
// internal error" (found by fuzzing with narrow vectors: uint((ushort)uint(bool(~b & uint(bool(a)))) | (ushort)a)).
// The adapter builds that and as `select (a != 0), (~b & 1), 0`.
// Checked: the ushort and uchar forms, against the CPU on 256 threads.
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

enum { kThreads = 256 };
static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    "  uint a = in[2 * t] + t, b = in[2 * t + 1] * 3u + t;\n"
    "  out[2 * t] = (uint)((ushort)((uint)((bool)((~b) & (uint)((bool)a)))) | (ushort)a);\n"
    "  out[2 * t + 1] = (uint)((uchar)((uint)((bool)((~a) & (uint)((bool)b)))) | (uchar)b);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "a26-amd-bool-and-not";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "%s: compile: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        if (!ps) return FAIL(bug, "%s: pipeline: %s", dev.name.UTF8String, err.localizedDescription.UTF8String);
        uint32_t input[kThreads * 2], s = 0x27d4eb2fu;
        for (int i = 0; i < kThreads * 2; i++) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; input[i] = i % 7 == 0 ? 0 : s; }
        id<MTLBuffer> in = [dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:kThreads * 8 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:ps]; [e setBuffer:in offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(kThreads, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [e endEncoding];
        reproRun(cb);
        const uint32_t *got = out.contents;
        for (int t = 0; t < kThreads; t++) {
            uint32_t a = input[2 * t] + t, b = input[2 * t + 1] * 3 + t;
            uint32_t want0 = (uint16_t)((~b & (uint32_t)(a != 0)) != 0) | (uint16_t)a;
            uint32_t want1 = (uint8_t)((~a & (uint32_t)(b != 0)) != 0) | (uint8_t)b;
            if (got[2 * t] != want0 || got[2 * t + 1] != want1)
                return FAIL(bug, "%s: thread %d: %08x %08x, want %08x %08x", dev.name.UTF8String, t, got[2 * t], got[2 * t + 1], want0, want1);
        }
        return PASS(bug, "%s: bools and'ed with a not, or'ed with a narrow value, compile and compute right", dev.name.UTF8String);
    }
}
