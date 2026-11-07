// i05-intel-constexpr-sampler (Intel adapter, IntelTextureAtomics.dylib): constexpr samplers from a metallib built for
// macOS 15 or later on the 3802 Intel compiler. Such libraries (AIR 2.7, reaching this compiler through MetalOldCompat
// item 25) store each constexpr sampler as a [2 x i64] constant, where older ones and the runtime compiler store one
// i64; IGILInlineSamplerLowering reads it as an integer and dereferences null, which kills MTLCompilerService. iMovie
// 10.4.4's viewer shader (Flexo's textureSamplingShader) is one, so its viewer stays black. A compute kernel reads a
// 4x4 R32Float texture holding 10 * y + x through five constexpr samplers (clamp to edge in pixel coordinates, repeat,
// mirrored repeat, clamp to an opaque white border, linear filtering), from a metallib built for macOS 15.4 and from
// one built for macOS 14 (one-word samplers, the control).
// Inputs: i05-air-macos14.metallib and i05-air-macos15.4.metallib (build.sh makes them with Xcode's metal compiler from
// data/i05-samplers.metal). Stock OCLP: FAIL (no pipeline; in-process compiler: crash). Fixed: PASS.
// On the AMD GPU (the AMD adapter, AMD_SAMPLER_STATE_FIX), libAMDIL902 builds the pipeline but reads such a sampler as 0:
// stock FAIL (the clamp-to-edge read returns 0), fixed PASS.
// Argument: GPU name substring (default: Intel).
#import "repro.h"

static const char *const kNames[5] = {"clamp to edge (pixel coordinates)", "repeat", "mirrored repeat",
                                      "clamp to an opaque white border", "linear filter (pixel coordinates)"};
static const float kWant[5] = {10, 10, 23, 1, 11.5f};

static const char *tryLibrary(id<MTLDevice> dev, id<MTLTexture> texture, NSString *path) {
    static char problem[512];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return "missing";
    dispatch_data_t dd = dispatch_data_create(data.bytes, data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&error];
    if (!lib) { snprintf(problem, sizeof problem, "load: %s", error.localizedDescription.UTF8String); return problem; }
    id<MTLComputePipelineState> pipeline = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
    if (!pipeline) { snprintf(problem, sizeof problem, "no pipeline: %s", error.localizedDescription.UTF8String); return problem; }
    id<MTLBuffer> out = [dev newBufferWithLength:sizeof kWant options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    [enc setTexture:texture atIndex:0];
    [enc setBuffer:out offset:0 atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    if (!reproRun(cb)) return "command buffer failed";
    const float *got = out.contents;
    for (int i = 0; i < 5; i++)
        if (got[i] != kWant[i]) {
            snprintf(problem, sizeof problem, "%s read %g, want %g", kNames[i], got[i], kWant[i]);
            return problem;
        }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "i05-intel-constexpr-sampler";
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        float texels[16];
        for (int i = 0; i < 16; i++) texels[i] = 10 * (i / 4) + i % 4;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> texture = [dev newTextureWithDescriptor:td];
        [texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
        NSString *dir = [@(argv[0]) stringByDeletingLastPathComponent];
        const char *control = tryLibrary(dev, texture, [dir stringByAppendingPathComponent:@"i05-air-macos14.metallib"]);
        const char *latest = tryLibrary(dev, texture, [dir stringByAppendingPathComponent:@"i05-air-macos15.4.metallib"]);
        if ((control && !strcmp(control, "missing")) || (latest && !strcmp(latest, "missing")))
            return SKIP(bug, "metallibs not built (build.sh needs Xcode's metal compiler)");
        if (control) return FAIL(bug, "%s: even the macOS 14 metallib fails: %s", dev.name.UTF8String, control);
        if (latest) return FAIL(bug, "%s: macOS 14 metallib OK, macOS 15.4 metallib: %s", dev.name.UTF8String, latest);
        return PASS(bug, "%s: constexpr samplers from metallibs for macOS 14 and 15.4 build and sample right", dev.name.UTF8String);
    }
}
