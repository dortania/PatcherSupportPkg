// i01-intel-array-struct-arg (Intel adapter; libMTLIntelCompilerPlugin, Haswell / Ivy Bridge): buffer arguments that
// point to an array of plain structs, as naga (wgpu, Firefox WebGPU) writes WGSL `array<T, N>` storage bindings. The
// current front end gives such an argument the struct's air.struct_type_info; the plugin's argument-buffer emulation
// (MetadataParser::parseArgument) assumes the pointee then IS a struct and asserts (isa<StructType>(elementType)),
// taking MTLCompilerService down: Firefox low-power WebGPU lost its device on the first pipeline. Two shapes, each in
// a child process: naga's wrapper (`struct type_N { T inner[N]; }`, `device type_N&`) and a reference to an array
// (`device T (&)[N]`), with a nested plain struct as in wgpu's timestamp normalization (array<{Uint64 {low, high}, ...}>).
// Stock OCLP: FAIL (pipeline creation fails / compiler aborts). Fixed: PASS. Argument: GPU (default: Intel).
#import "repro.h"

static NSString *const common = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Uint64 { uint low; uint high; };\n"
    "struct Timestamp { Uint64 t; uint a; uint b; };\n"
    "struct type_3 { Timestamp inner[8]; };\n";
static NSString *const wrapped = @"kernel void k(device type_3& ts [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
    "  ts.inner[i].t.low = i; ts.inner[i].t.high = i + 100u; ts.inner[i].a = 2u * i; ts.inner[i].b = 7u; }\n";
static NSString *const arrayRef = @"kernel void k(device Timestamp (&ts [[buffer(0)]])[8], uint i [[thread_position_in_grid]]) {\n"
    "  ts[i].t.low = i; ts[i].t.high = i + 100u; ts[i].a = 2u * i; ts[i].b = 7u; }\n";

static int child(int argc, char **argv, const char *mode) {
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    NSError *err = nil;
    NSString *src = [common stringByAppendingString:strcmp(mode, "wrapped") ? arrayRef : wrapped];
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) { printf("%s: compile: %s\n", mode, err.localizedDescription.UTF8String); return 3; }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    if (!ps) { printf("%s: pipeline: %s\n", mode, err.localizedDescription.UTF8String); return 4; }
    id<MTLBuffer> ts = [dev newBufferWithLength:8 * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps]; [e setBuffer:ts offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(8, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 1, 1)];
    [e endEncoding];
    reproRun(cb);
    const uint32_t *t = ts.contents;
    for (uint32_t i = 0; i < 8; i++)
        if (t[i * 4] != i || t[i * 4 + 1] != i + 100 || t[i * 4 + 2] != 2 * i || t[i * 4 + 3] != 7) return 5;
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i01-intel-array-struct-arg", *mode = reproChildMode(argc, argv);
        if (mode) return child(argc, argv, mode);
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        int a = reproRunChild(argc, argv, "wrapped"), b = reproRunChild(argc, argv, "arrayref");
        if (!a && !b) return PASS(bug, "%s: struct-array buffer arguments (naga wrapper and array reference) compile and run", dev.name.UTF8String);
        const char *why[] = {"ok", "", "", "compile failed", "pipeline failed (compiler)", "wrong values"};
        return FAIL(bug, "%s: naga wrapper struct: %s; `device T (&)[N]`: %s", dev.name.UTF8String,
                    a <= 5 ? why[a] : reproChildStatus(a), b <= 5 ? why[b] : reproChildStatus(b));
    }
}
