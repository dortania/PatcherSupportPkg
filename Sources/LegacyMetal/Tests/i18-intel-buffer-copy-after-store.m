// i18-intel-buffer-copy-after-store: a buffer copied out whole after a store through an int view (Tint's bufferView)
// must have that store; the back end reused an earlier load. Fix: IntelTextureAtomics INTEL_TYPE_PUN_FIX.
// Checks: load, store through the view and whole copy, on threadgroup and device memory. Argument: GPU name.
#import "repro.h"

static NSString *const src = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "typedef int __attribute__((__may_alias__)) aliased_int;\n"
    "typedef array<int, 32> __attribute__((__may_alias__)) aliased_words;\n"
    "struct Words { array<int, 32> w; };\n"
    "kernel void groupCopy(device const Words *in [[buffer(0)]], device Words *out [[buffer(1)]], device int *r [[buffer(2)]],\n"
    "                      threadgroup array<uchar, 128> *bytes [[threadgroup(0)]]) {\n"
    "    threadgroup aliased_words *all = reinterpret_cast<threadgroup array<int, 32> *>(reinterpret_cast<threadgroup char *>(bytes));\n"
    "    *all = in->w;\n"
    "    threadgroup aliased_int *p = reinterpret_cast<threadgroup int *>(reinterpret_cast<threadgroup char *>(bytes) + 16u);\n"
    "    int before = *p;\n"
    "    *p = r[1];\n"
    "    r[0] = *p - before;\n"
    "    out->w = *all;\n"
    "}\n"
    "kernel void deviceCopy(device const Words *in [[buffer(0)]], device Words *out [[buffer(1)]], device int *r [[buffer(2)]],\n"
    "                       device array<uchar, 128> *bytes [[buffer(3)]]) {\n"
    "    device aliased_words *all = reinterpret_cast<device array<int, 32> *>(reinterpret_cast<device char *>(bytes));\n"
    "    *all = in->w;\n"
    "    device aliased_int *p = reinterpret_cast<device int *>(reinterpret_cast<device char *>(bytes) + 16u);\n"
    "    int before = *p;\n"
    "    *p = r[1];\n"
    "    r[0] = *p - before;\n"
    "    out->w = *all;\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i18-intel-buffer-copy-after-store";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
        if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
        const char *kernels[] = {"groupCopy", "deviceCopy"}, *what[] = {"threadgroup", "device"};
        for (int k = 0; k < 2; k++) {
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kernels[k])] error:&err];
            if (!ps) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
            id<MTLBuffer> in = [dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
            id<MTLBuffer> out = [dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
            id<MTLBuffer> r = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bytes = [dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
            for (int i = 0; i < 32; i++) ((int *)in.contents)[i] = 10 + i;
            ((int *)r.contents)[1] = 2000;
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps];
            [ce setBuffer:in offset:0 atIndex:0];
            [ce setBuffer:out offset:0 atIndex:1];
            [ce setBuffer:r offset:0 atIndex:2];
            [ce setBuffer:bytes offset:0 atIndex:3];
            [ce setThreadgroupMemoryLength:128 atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [ce endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: command buffer failed", name);
            const int *o = out.contents, *rr = r.contents;
            if (rr[0] != 2000 - 14) return FAIL(bug, "%s: %s: store through the view then reload: difference %d, want %d", name, what[k], rr[0], 2000 - 14);
            for (int i = 0; i < 32; i++)
                if (o[i] != (i == 4 ? 2000 : 10 + i))
                    return FAIL(bug, "%s: %s buffer copied out after a store through an int view: word %d is %d, want %d", name, what[k], i, o[i],
                                i == 4 ? 2000 : 10 + i);
        }
        return PASS(bug, "%s: a store through an int view reaches the buffer's later aggregate copy (threadgroup and device)", name);
    }
}
