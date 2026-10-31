// s13-new-air-metallib (MetalOldCompat item 13, root cause only): a precompiled metallib built for macOS 15.4 or later
// (AIR target air64_v27-apple-macosx15.4.0, as Safari's WebKit ships ANGLE's internal shaders) on this stack. The
// library loads, but specializing a function with function constants or building a pipeline from it fails with
// "incompatible module ... not compatible with the target (air64-apple-macosx14.2.0)". In Safari every WebGL context
// that needs one of those shaders failed and WebKit's GPU process hung.
// The shim works around it for WebKit's ANGLE only (it compiles ANGLE's internal-shader source instead), so this
// generic check FAILs on stock OCLP and with the shim; the metallib built for macOS 14 is the control.
// Inputs: s13-air-macos14.metallib and s13-air-macos15.4.metallib (build.sh makes them with Xcode's metal compiler).
// Argument: GPU name substring (default: AMD).
#import "repro.h"

static const char *tryLibrary(id<MTLDevice> dev, NSString *path) {
    static char problem[512];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return "missing";
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&err];
    if (!lib) { snprintf(problem, sizeof problem, "load: %s", err.localizedDescription.UTF8String); return problem; }
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    bool flip = true;
    [cv setConstantValue:&flip type:MTLDataTypeBool withName:@"kFlip"];
    id<MTLFunction> f = [lib newFunctionWithName:@"k" constantValues:cv error:&err];
    if (!f) { snprintf(problem, sizeof problem, "specialize: %s", err.localizedDescription.UTF8String); return problem; }
    if (![dev newComputePipelineStateWithFunction:f error:&err]) { snprintf(problem, sizeof problem, "pipeline: %s", err.localizedDescription.UTF8String); return problem; }
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
        return PASS(bug, "%s: metallibs for macOS 14 and 15.4 both specialize and build pipelines", dev.name.UTF8String);
    }
}
