// s13-new-air-metallib (MetalOldCompat item 25; Safari's case also item 13): a precompiled metallib built for macOS
// 15.4 or later (AIR target air64_v27-apple-macosx15.4.0, as iMovie 10.4.4 and Safari's WebKit ship) on this stack. The
// library loads, but specializing a function with function constants or building a pipeline from it fails with
// "incompatible module ... not compatible with the target (air64-apple-macosx14.2.0)"; past that, the AIR 2.6 target
// rejects !air.version 2.7, and predicated arguments' implicit function constants stay unresolved. iMovie's viewer
// stayed black; in Safari every WebGL context that needs one of WebKit's internal shaders failed.
// Two kernels per metallib, run and checked: k (a plain function constant) and kp (a buffer argument predicated on
// is_function_constant_defined, run with the constant set and unset). The metallib built for macOS 14 is the control.
// Inputs: s13-air-macos14.metallib and s13-air-macos15.4.metallib (build.sh makes them with Xcode's metal compiler).
// The compiler runs in MTLCompilerService, so the shim under test must be loaded there too (verify.sh passes it with
// __XPC_DYLD_INSERT_LIBRARIES). Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring (default: AMD).
#import "repro.h"

// Builds kernel `name` with the given constants, runs it over 64 threads and compares out[i] with want(i).
static const char *runKernel(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv,
                             float offset, float (^want)(unsigned)) {
    static char problem[512];
    NSError *err = nil;
    id<MTLFunction> f = [lib newFunctionWithName:name constantValues:cv error:&err];
    if (!f) { snprintf(problem, sizeof problem, "%s: specialize: %s", name.UTF8String, err.localizedDescription.UTF8String); return problem; }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&err];
    if (!ps) { snprintf(problem, sizeof problem, "%s: pipeline: %s", name.UTF8String, err.localizedDescription.UTF8String); return problem; }
    id<MTLBuffer> out = [dev newBufferWithLength:64 * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps];
    [e setBuffer:out offset:0 atIndex:0];
    [e setBytes:&offset length:sizeof offset atIndex:1];
    [e dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e endEncoding];
    reproRun(cb);
    const float *got = out.contents;
    for (unsigned i = 0; i < 64; i++)
        if (got[i] != want(i)) {
            snprintf(problem, sizeof problem, "%s: out[%u] = %g, want %g", name.UTF8String, i, got[i], want(i));
            return problem;
        }
    return NULL;
}

static const char *tryLibrary(id<MTLDevice> dev, NSString *path) {
    static char problem[512];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return "missing";
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
    if (!lib) { snprintf(problem, sizeof problem, "load: %s", err.localizedDescription.UTF8String); return problem; }
    MTLFunctionConstantValues *flip = [MTLFunctionConstantValues new], *scaled = [MTLFunctionConstantValues new];
    bool yes = true;
    float scale = 3;
    [flip setConstantValue:&yes type:MTLDataTypeBool withName:@"kFlip"];
    [scaled setConstantValue:&scale type:MTLDataTypeFloat withName:@"kScale"];
    const char *r = runKernel(dev, lib, @"k", flip, 0, ^float(unsigned i) { return -(float)i; });
    if (!r) r = runKernel(dev, lib, @"kp", scaled, 5, ^float(unsigned i) { return 3 * (float)i + 5; });
    if (!r) r = runKernel(dev, lib, @"kp", [MTLFunctionConstantValues new], 5, ^float(unsigned i) { return (float)i; });
    if (r) { snprintf(problem, sizeof problem, "%s", r); return problem; }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s13-new-air-metallib";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        NSString *dir = [@(argv[0]) stringByDeletingLastPathComponent];
        const char *control = tryLibrary(dev, [dir stringByAppendingPathComponent:@"s13-air-macos14.metallib"]);
        const char *latest = tryLibrary(dev, [dir stringByAppendingPathComponent:@"s13-air-macos15.4.metallib"]);
        if ((control && !strcmp(control, "missing")) || (latest && !strcmp(latest, "missing")))
            return SKIP(bug, "metallibs not built (build.sh needs Xcode's metal compiler)");
        if (control) return FAIL(bug, "%s: even the macOS 14 metallib fails: %s", dev.name.UTF8String, control);
        if (latest) return FAIL(bug, "%s: macOS 14 metallib OK, macOS 15.4 metallib: %s", dev.name.UTF8String, latest);
        return PASS(bug, "%s: metallibs for macOS 14 and 15.4 both specialize, build and compute right (incl. predicated argument)", dev.name.UTF8String);
    }
}
