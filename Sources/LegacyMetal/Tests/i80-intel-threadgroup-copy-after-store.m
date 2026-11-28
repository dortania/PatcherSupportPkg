// i80-intel-threadgroup-copy-after-store: a threadgroup struct copied out whole after a store through a pointer must
// have the store; on the HD 4000 the copy had the old value. Fix: IntelTextureAtomics INTEL_COPY_EXPAND_FIX.
// Checks: *pa += *pb twice in a helper, then a whole copy; threadgroup, device, private memory. Argument: GPU name.
#import "repro.h"

enum { BIG = 32, WORDS = 2 + 4 + 4 + BIG };  // ints in Data: x, y, arr[4], s, big[32]

static NSString *const src = @  // the threadgroup kernel is Dawn's (Tint's) MSL for the CTS case, names shortened
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct S { int a; int b; int c; int d; };\n"
    "struct Data { int x; int y; array<int, 4> arr; S s; array<int, 32> big; };\n"
    "struct In { Data a; Data b; array<int, 8> p; };\n"
    "struct Out { array<int, 4> r; Data a; Data b; };\n"
    "struct Vars { const device In *input; device Out *output; threadgroup Data *A; threadgroup Data *B; };\n"
    "struct Group { Data A; Data B; };\n"
    "int f(threadgroup int *const pa, threadgroup int *const pb, int va, int vb, int n) {\n"
    "    *pa = as_type<int>(as_type<uint>(*pa) + as_type<uint>(*pb));\n"
    "    *pa = as_type<int>(as_type<uint>(*pa) + as_type<uint>(*pb));\n"
    "    return *pa;\n"
    "}\n"
    "void inner(uint index, Vars v) {\n"
    "    if (index < 1u) { v.A->x = 0; v.A->y = 0; v.A->s = S{}; v.B->x = 0; v.B->y = 0; v.B->s = S{}; }\n"
    "    for (uint idx = index; idx < 4u; idx++) { v.A->arr[idx] = 0; v.B->arr[idx] = 0; }\n"
    "    for (uint idx = index; idx < 32u; idx++) { v.A->big[idx] = 0; v.B->big[idx] = 0; }\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "    *v.A = v.input->a;\n"
    "    *v.B = v.input->b;\n"
    "    v.output->r[0] = f(&v.A->x, &v.B->x, v.input->p[0], v.input->p[1], v.input->p[2]);\n"
    "    v.output->a = *v.A;\n"
    "    v.output->b = *v.B;\n"
    "}\n"
    "[[max_total_threads_per_threadgroup(1)]]\n"
    "kernel void group(uint index [[thread_index_in_threadgroup]], const device In *input [[buffer(0)]], device Out *output [[buffer(1)]],\n"
    "                  threadgroup Group *g [[threadgroup(0)]]) {\n"
    "    inner(index, Vars{input, output, &g->A, &g->B});\n"
    "}\n"
    "template <typename P> int h(P pa, P pb) {\n"
    "    *pa = as_type<int>(as_type<uint>(*pa) + as_type<uint>(*pb));\n"
    "    *pa = as_type<int>(as_type<uint>(*pa) + as_type<uint>(*pb));\n"
    "    return *pa;\n"
    "}\n"
    "kernel void privateCopy(const device In *input [[buffer(0)]], device Out *output [[buffer(1)]]) {\n"
    "    Data A = input->a, B = input->b;\n"
    "    output->r[0] = h(&A.x, &B.x);\n"
    "    output->a = A;\n"
    "    output->b = B;\n"
    "}\n"
    "kernel void deviceCopy(device In *io [[buffer(0)]], device Out *output [[buffer(1)]]) {\n"
    "    output->r[0] = h(&io->a.x, &io->b.x);\n"
    "    output->a = io->a;\n"
    "    output->b = io->b;\n"
    "}\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "i80-intel-threadgroup-copy-after-store";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "%s: compile: %s", name, err.localizedDescription.UTF8String);
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const char *kernels[3] = {"group", "privateCopy", "deviceCopy"}, *where[3] = {"threadgroup", "private", "device"};
    for (int k = 0; k < 3; k++) {
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(kernels[k])] error:&err];
        if (!ps) return FAIL(bug, "%s: %s pipeline: %s", name, where[k], err.localizedDescription.UTF8String);
        int32_t in[WORDS * 2 + 8];
        for (int i = 0; i < WORDS * 2 + 8; i++) in[i] = i + 1;
        in[0] = 10, in[WORDS] = 100;  // A.x, B.x
        id<MTLBuffer> ib = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
        id<MTLBuffer> ob = [dev newBufferWithLength:(4 + WORDS * 2) * 4 options:MTLResourceStorageModeShared];
        memset(ob.contents, 0xee, ob.length);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:ib offset:0 atIndex:0];
        [ce setBuffer:ob offset:0 atIndex:1];
        if (k == 0) [ce setThreadgroupMemoryLength:WORDS * 2 * 4 atIndex:0];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];
        if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", name, where[k]);
        const int32_t *o = ob.contents;
        if (o[0] != 210) return FAIL(bug, "%s: %s: the helper returned %d, want 210", name, where[k], o[0]);
        if (o[4] != 210) return FAIL(bug, "%s: %s: A copied out after the store through a pointer: A.x = %d, want 210", name, where[k], o[4]);
        for (int i = 1; i < WORDS; i++)
            if (o[4 + i] != in[i] || o[4 + WORDS + i] != in[WORDS + i])
                return FAIL(bug, "%s: %s: word %d of the copies: %d / %d, want %d / %d", name, where[k], i, o[4 + i], o[4 + WORDS + i], in[i], in[WORDS + i]);
        if (o[4 + WORDS] != 100) return FAIL(bug, "%s: %s: B.x = %d, want 100", name, where[k], o[4 + WORDS]);
    }
    return PASS(bug, "%s: a struct copied out after a store through a pointer to one of its fields has the stored value (threadgroup, private and device memory)", name);
}}
