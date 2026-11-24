// s59-metal4-texture-reads: texture reads in a Metal 4.0 library (Xcode 26) must build; Tahoe's compiler crashed
// forever or failed. Fix: MetalOldCompat item 45 __XPC_MTLSHIM_READ_SAMPLER. SKIP before macOS 26.
// Checks: 15 kernels read a texel of each texture type, from build.sh's s59-metal4.metallib. Argument: GPU name.
#import "repro.h"

enum { N = 8 };
static float texel(int x, int y, int slice, int level) { return 1000.0f * level + 100.0f * slice + 10.0f * y + x; }

static id<MTLTexture> colorTexture(id<MTLDevice> dev, MTLTextureType type, int depth, int slices, int levels) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = type, d.pixelFormat = MTLPixelFormatR32Float, d.width = N;
    d.height = type == MTLTextureType1D ? 1 : N, d.depth = depth, d.mipmapLevelCount = levels;
    d.arrayLength = type == MTLTextureTypeCubeArray ? slices / 6 : type == MTLTextureType2DArray ? slices : 1;
    d.usage = MTLTextureUsageShaderRead, d.storageMode = MTLStorageModeManaged;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    float values[N * N * N];
    for (int level = 0; level < levels; level++) {
        int w = N >> level, h = type == MTLTextureType1D ? 1 : N >> level;
        for (int slice = 0; slice < slices; slice++) {
            for (int z = 0; z < depth; z++)
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++) values[(z * h + y) * w + x] = texel(x, y, depth > 1 ? z : slice, level);
            [t replaceRegion:MTLRegionMake3D(0, 0, 0, w, h, depth) mipmapLevel:level slice:slice withBytes:values
                 bytesPerRow:w * 4 bytesPerImage:w * h * 4];
        }
    }
    return t;
}

static id<MTLTexture> depthTexture(id<MTLDevice> dev, id<MTLCommandQueue> q, MTLTextureType type, int slices) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = type, d.pixelFormat = MTLPixelFormatDepth32Float, d.width = d.height = N;
    d.arrayLength = type == MTLTextureType2DArray ? slices : 1;
    d.usage = MTLTextureUsageShaderRead, d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    id<MTLBuffer> staging = [dev newBufferWithLength:N * N * 4 * slices options:MTLResourceStorageModeShared];
    float *values = staging.contents;
    for (int slice = 0; slice < slices; slice++)
        for (int i = 0; i < N * N; i++) values[slice * N * N + i] = texel(i % N, i / N, slice, 0) / 10000.0f;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (int slice = 0; slice < slices; slice++)
        [blit copyFromBuffer:staging sourceOffset:slice * N * N * 4 sourceBytesPerRow:N * 4 sourceBytesPerImage:N * N * 4
                  sourceSize:MTLSizeMake(N, N, 1) toTexture:t destinationSlice:slice destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    reproRun(cb);
    return t;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s59-metal4-texture-reads";
        id<MTLDevice> dev = reproDevice(argc, argv, "AMD");
        if (!dev) return SKIP(bug, "no such GPU");
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26)
            return SKIP(bug, "apps built for macOS 26, the only ones with such libraries, don't run on this macOS");
        NSString *path = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"s59-metal4.metallib"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return SKIP(bug, "s59-metal4.metallib not built (build.sh needs Xcode 26's metal compiler)");
        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithData:dispatch_data_create(data.bytes, data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&error];
        if (!lib) return SKIP(bug, "%s: this macOS doesn't load Metal 4.0 libraries: %s", dev.name.UTF8String, error.localizedDescription.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> elements = [dev newBufferWithLength:16 * 4 options:MTLResourceStorageModeShared];
        for (int i = 0; i < 16; i++) ((float *)elements.contents)[i] = texel(i, 0, 0, 0);
        MTLTextureDescriptor *bd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Float width:16
                                                                                resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
        NSUInteger rowBytes = MAX(16 * 4, [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Float]);
        struct { const char *kernel; id<MTLTexture> texture; float want; } cases[] = {
            {"read1d", colorTexture(dev, MTLTextureType1D, 1, 1, 1), texel(2, 0, 0, 0)},
            {"read1dShort", colorTexture(dev, MTLTextureType1D, 1, 1, 1), texel(3, 0, 0, 0)},
            {"read2dLevel", colorTexture(dev, MTLTextureType2D, 1, 1, 4), texel(1, 2, 0, 1)},
            {"read2dShort", colorTexture(dev, MTLTextureType2D, 1, 1, 1), texel(3, 1, 0, 0)},
            {"read2dArray", colorTexture(dev, MTLTextureType2DArray, 1, 2, 1), texel(1, 2, 1, 0)},
            {"read3d", colorTexture(dev, MTLTextureType3D, 4, 1, 1), texel(1, 2, 3, 0)},
            {"read3dShort", colorTexture(dev, MTLTextureType3D, 4, 1, 1), texel(2, 1, 1, 0)},
            {"readCube", colorTexture(dev, MTLTextureTypeCube, 1, 6, 1), texel(1, 2, 4, 0)},
            {"readCubeShort", colorTexture(dev, MTLTextureTypeCube, 1, 6, 1), texel(2, 3, 5, 0)},
            {"readCubeArray", colorTexture(dev, MTLTextureTypeCubeArray, 1, 12, 1), texel(1, 2, 10, 0)},
            {"readDepth", depthTexture(dev, q, MTLTextureType2D, 1), texel(1, 2, 0, 0) / 10000.0f},
            {"readDepthShort", depthTexture(dev, q, MTLTextureType2D, 1), texel(3, 1, 0, 0) / 10000.0f},
            {"readDepthArray", depthTexture(dev, q, MTLTextureType2DArray, 2), texel(1, 2, 1, 0) / 10000.0f},
            {"readDepthCube", depthTexture(dev, q, MTLTextureTypeCube, 6), texel(1, 2, 4, 0) / 10000.0f},
            {"readBuffer", [elements newTextureWithDescriptor:bd offset:0 bytesPerRow:rowBytes], texel(5, 0, 0, 0)},
        };
        int count = sizeof cases / sizeof cases[0], wrong = 0;
        char report[1024] = "";
        for (int c = 0; c < count; c++) {
            id<MTLFunction> f = [lib newFunctionWithName:@(cases[c].kernel)];
            __block id<MTLComputePipelineState> pipeline = nil;
            __block NSError *pipelineError = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *e = nil;
                pipeline = [dev newComputePipelineStateWithFunction:f error:&e];
                pipelineError = e;
                dispatch_semaphore_signal(done);
            });
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC)))
                return FAIL(bug, "%s: %s: the compile never returned (the compiler service crashed and the request is sent again)",
                            dev.name.UTF8String, cases[c].kernel);
            if (!pipeline)
                return FAIL(bug, "%s: %s: no pipeline: %s", dev.name.UTF8String, cases[c].kernel,
                            [pipelineError.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
            id<MTLBuffer> out = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
            *(float *)out.contents = -1;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pipeline];
            [enc setTexture:cases[c].texture atIndex:0];
            [enc setBuffer:out offset:0 atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [enc endEncoding];
            if (!reproRun(cb)) return FAIL(bug, "%s: %s: command buffer failed", dev.name.UTF8String, cases[c].kernel);
            float got = *(float *)out.contents;
            if (fabsf(got - cases[c].want) > 1e-6f * fmaxf(1, fabsf(cases[c].want))) {
                wrong++;
                size_t used = strlen(report);
                snprintf(report + used, sizeof report - used, "%s%s read %g, want %g", used ? "; " : "", cases[c].kernel, got, cases[c].want);
            }
        }
        if (wrong) return FAIL(bug, "%s: %d of %d reads wrong: %s", dev.name.UTF8String, wrong, count, report);
        return PASS(bug, "%s: all %d texture reads of a Metal 4.0 library build and read the right texel", dev.name.UTF8String, count);
    }
}
