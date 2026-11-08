// i16-intel-type-punned-buffer (Intel adapter, IntelTextureAtomics.dylib): a buffer viewed as two element types through
// casts of one byte pointer (as Tint does for WGSL's bufferArrayView) must keep its loads and stores in order. The 3802
// back end reorders or forwards an access of one type past an access of the other to the same address: "load int,
// store float2 there, load int" returned the first value (WebGPU CTS bufferArrayView mixed_types_aliasing, 285 cases,
// storage and workgroup buffers). Runs that sequence on a device buffer and on threadgroup memory. Also checks what
// the fix must leave alone: a buffer copied whole into a private variable (as Tint writes `var v = input;`), whose only
// cast is the copy's own byte pointer; marking that copy volatile lost the mat2x2<f16> values (WebGPU CTS memory_layout
// read_layout array_mat2x2h_stride, function and private address spaces).
// Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: Intel).
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void punDevice(device char *bytes [[buffer(0)]], device uint *out [[buffer(1)]], constant uint &zero [[buffer(2)]]) {\n"
    "    device int *ints = reinterpret_cast<device int *>(bytes);\n"
    "    device float2 *pairs = reinterpret_cast<device float2 *>(bytes);\n"
    "    int before = ints[zero];\n"
    "    pairs[zero] = float2(2000.0f, 3.0f);\n"
    "    int after = ints[zero];\n"
    "    out[0] = uint(before); out[1] = uint(after);\n"
    "}\n"
    "kernel void punThreadgroup(device uint *out [[buffer(1)]], constant uint &zero [[buffer(2)]]) {\n"
    "    threadgroup char bytes[16];\n"
    "    threadgroup int *ints = reinterpret_cast<threadgroup int *>(bytes);\n"
    "    threadgroup float2 *pairs = reinterpret_cast<threadgroup float2 *>(bytes);\n"
    "    ints[zero] = 7;\n"
    "    int before = ints[zero];\n"
    "    pairs[zero] = float2(2000.0f, 3.0f);\n"
    "    int after = ints[zero];\n"
    "    out[2] = uint(before); out[3] = uint(after);\n"
    "}\n"
    "struct HalfMatrices { half2x2 m[2]; };\n"
    "kernel void copyPrivate(const device HalfMatrices *in [[buffer(3)]], device uint *out [[buffer(1)]]) {\n"
    "    HalfMatrices v = {};\n"
    "    v = *in;\n"
    "    out[4] = uint(clamp(v.m[1][0][0], 0.0h, 65504.0h));\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i16-intel-type-punned-buffer";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        id<MTLComputePipelineState> device = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"punDevice"] error:&err];
        id<MTLComputePipelineState> group = device ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"punThreadgroup"] error:&err] : nil;
        id<MTLComputePipelineState> copy = group ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copyPrivate"] error:&err] : nil;
        if (!copy) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
        id<MTLBuffer> bytes = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        ((int *)bytes.contents)[0] = 7;
        id<MTLBuffer> out = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
        id<MTLBuffer> halves = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        const uint16_t h[8] = {0x4400, 0x4500, 0x4600, 0x4700, 0x5640 /* 100.0 */, 0x4800, 0x4880, 0x4900};  // m[1][0][0] = 100
        memcpy(halves.contents, h, sizeof h);
        uint32_t zero = 0;
        id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setBuffer:bytes offset:0 atIndex:0];
        [ce setBuffer:out offset:0 atIndex:1];
        [ce setBytes:&zero length:4 atIndex:2];
        [ce setComputePipelineState:device];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce setComputePipelineState:group];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce setBuffer:halves offset:0 atIndex:3];
        [ce setComputePipelineState:copy];
        [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
        const uint32_t *o = out.contents;
        float f = 2000.0f;
        uint32_t want = 0;
        memcpy(&want, &f, 4);
        if (o[0] != 7 || o[1] != want)
            return FAIL(bug, "%s: device buffer: int before %u (want 7), after a float2 store there %08x (want %08x; the buffer holds %08x)", name, o[0], o[1],
                        want, ((const uint32_t *)bytes.contents)[0]);
        if (o[2] != 7 || o[3] != want)
            return FAIL(bug, "%s: threadgroup memory: int before %u (want 7), after a float2 store there %08x (want %08x)", name, o[2], o[3], want);
        if (o[4] != 100)
            return FAIL(bug, "%s: half2x2 array copied into a private variable: element read back as %u (want 100)", name, o[4]);
        return PASS(bug, "%s: int / float2 views of one buffer stay in order (device and threadgroup); a private copy reads right", name);
    }
}
