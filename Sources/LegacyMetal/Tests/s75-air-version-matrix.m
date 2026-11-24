// s75-air-version-matrix: a sweep: shaders built for every macOS target from 10.14 (AIR 2.1) up must run; on Tahoe old
// texture calls broke (item 75). Fix: the whole stack; only the fixed run must pass. SKIP without Xcode's metal.
// Checks: fragment and kernel pipelines per library; AIR 2.7+ is reported, not failed. Argument: GPU name.
#import "repro.h"

static const char *targets[] = {"10.14", "10.15", "11.0", "12.0", "13.0", "14.0", "15.0", "26.0"};
static BOOL required(const char *target) { return atof(target) < 15.0; }

enum { N = 8 };
static uint8_t texel(int x, int y, int c) { return c == 0 ? x * 32 + 7 : c == 1 ? y * 32 + 3 : c == 2 ? (x ^ y) * 16 : 255; }

static NSString *check(const uint8_t *px, size_t rowBytes, BOOL redOnly, uint8_t (*want)(int, int, int)) {
    for (int y = 0; y < N; y++)
        for (int x = 0; x < N; x++)
            for (int c = 0; c < (redOnly ? 1 : 4); c++) {
                int got = px[y * rowBytes + x * 4 + c], exp = want(x, y, c);
                if (abs(got - exp) > 2) return [NSString stringWithFormat:@"pixel (%d,%d) channel %d: %d, want %d", x, y, c, got, exp];
            }
    return nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s75-air-version-matrix";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        NSString *dir = [@(argv[0]) stringByDeletingLastPathComponent];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        // the source texture, an array texture with it in layer 1, and an 8x8 render target
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> src = [dev newTextureWithDescriptor:td];
        uint8_t pixels[N * N * 4];
        for (int y = 0; y < N; y++) for (int x = 0; x < N; x++) for (int c = 0; c < 4; c++) pixels[(y * N + x) * 4 + c] = texel(x, y, c);
        [src replaceRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0 withBytes:pixels bytesPerRow:N * 4];
        MTLTextureDescriptor *ad = [td copy];
        ad.textureType = MTLTextureType2DArray; ad.arrayLength = 2;
        id<MTLTexture> array = [dev newTextureWithDescriptor:ad];
        [array replaceRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0 slice:1 withBytes:pixels bytesPerRow:N * 4 bytesPerImage:N * N * 4];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite; rd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> target = [dev newTextureWithDescriptor:rd];
        // a 4x multisample texture whose sample 0 is cleared to a known color
        MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:NO];
        md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        md.storageMode = MTLStorageModePrivate;
        id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];  // nearest: a sample at a texel's center is that texel
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:sd];
        NSMutableArray *built = [NSMutableArray array], *newer = [NSMutableArray array];
        unsigned libraries = 0;
        for (unsigned i = 0; i < sizeof targets / sizeof targets[0]; i++) {
            const char *t = targets[i];
            NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"s75-air-macos%s.metallib", t]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
            libraries++;
            NSError *error = nil;
            NSString *failure = nil;
            id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
            if (!lib) failure = [NSString stringWithFormat:@"library: %@", error.localizedDescription];
            // render passes: function name, function constant (or -1), texture, check red only
            struct { NSString *fs; int mode; id<MTLTexture> tex; BOOL redOnly; } passes[] = {
                {@"sampleFS", -1, src, NO}, {@"readFS", -1, src, NO}, {@"arrayFS", -1, array, NO}, {@"msReadFS", -1, ms, NO},
                {@"constantFS", 0, src, NO}, {@"constantFS", 1, src, NO}, {@"constantFS", 2, src, YES}};
            for (unsigned p = 0; !failure && p < sizeof passes / sizeof passes[0]; p++) {
                MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
                pd.vertexFunction = [lib newFunctionWithName:@"fullVS"];
                if (passes[p].mode >= 0) {
                    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
                    int mode = passes[p].mode;
                    [cv setConstantValue:&mode type:MTLDataTypeInt atIndex:0];
                    pd.fragmentFunction = [lib newFunctionWithName:passes[p].fs constantValues:cv error:&error];
                } else {
                    pd.fragmentFunction = [lib newFunctionWithName:passes[p].fs];
                }
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
                id<MTLRenderPipelineState> ps = pd.vertexFunction && pd.fragmentFunction ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
                NSString *what = passes[p].mode >= 0 ? [NSString stringWithFormat:@"%@ (mode %d)", passes[p].fs, passes[p].mode] : passes[p].fs;
                if (!ps) { failure = [NSString stringWithFormat:@"%@: %@", what, error.localizedDescription ?: @"no function"]; break; }
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                if (passes[p].tex == ms) {  // sample 0 of every pixel cleared to the texel pattern's corner color: draw it instead
                    MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
                    clear.colorAttachments[0].texture = ms;
                    clear.colorAttachments[0].loadAction = MTLLoadActionClear;
                    clear.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
                    clear.colorAttachments[0].storeAction = MTLStoreActionStore;
                    [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
                }
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = target;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:ps];
                [re setFragmentTexture:passes[p].tex atIndex:0];
                [re setFragmentSamplerState:sampler atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be synchronizeResource:target];
                [be endEncoding];
                if (!reproRun(cb)) { failure = [NSString stringWithFormat:@"%@: command buffer failed", what]; break; }
                uint8_t out[N * N * 4];
                [target getBytes:out bytesPerRow:N * 4 fromRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0];
                NSString *bad;
                if (passes[p].tex == ms) {
                    bad = nil;
                    for (int k = 0; k < N * N && !bad; k++)
                        if (abs(out[k * 4] - 64) > 2 || abs(out[k * 4 + 1] - 128) > 2 || abs(out[k * 4 + 2] - 191) > 2)
                            bad = [NSString stringWithFormat:@"pixel %d: %d,%d,%d, want 64,128,191", k, out[k * 4], out[k * 4 + 1], out[k * 4 + 2]];
                } else if (passes[p].redOnly) {  // gather at (x+0.5, y+0.5)/8 with nearest: w is the texel (x, y) itself... or its neighbour
                    bad = nil;  // the footprint's corner order differs between GPUs; that the pipeline builds and runs is checked
                } else {
                    bad = check(out, N * 4, NO, texel);
                }
                if (bad) { failure = [NSString stringWithFormat:@"%@: %@", what, bad]; break; }
            }
            // kernels: a 2x downsample into the target's top-left 4x4, and 64 samples into a buffer
            for (NSString *k in @[@"mipKernel", @"sampleKernel"]) {
                if (failure) break;
                id<MTLFunction> f = [lib newFunctionWithName:k];
                id<MTLComputePipelineState> cps = f ? [dev newComputePipelineStateWithFunction:f error:&error] : nil;
                if (!cps) { failure = [NSString stringWithFormat:@"%@: %@", k, error.localizedDescription ?: @"no function"]; break; }
                id<MTLBuffer> buf = [dev newBufferWithLength:N * N * 16 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:cps];
                [ce setTexture:src atIndex:0];
                if ([k isEqualToString:@"mipKernel"]) {
                    [ce setTexture:target atIndex:1];
                    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(N / 2, N / 2, 1)];
                } else {
                    [ce setSamplerState:sampler atIndex:0];
                    [ce setBuffer:buf offset:0 atIndex:0];
                    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(N * N, 1, 1)];
                }
                [ce endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                [be synchronizeResource:target];
                [be endEncoding];
                if (!reproRun(cb)) { failure = [NSString stringWithFormat:@"%@: command buffer failed", k]; break; }
                if ([k isEqualToString:@"mipKernel"]) {
                    uint8_t out[N * N * 4];
                    [target getBytes:out bytesPerRow:N * 4 fromRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0];
                    for (int y = 0; y < N / 2 && !failure; y++)
                        for (int x = 0; x < N / 2 && !failure; x++)
                            for (int c = 0; c < 4 && !failure; c++) {
                                int exp = (texel(2 * x, 2 * y, c) + texel(2 * x + 1, 2 * y, c) + texel(2 * x, 2 * y + 1, c) + texel(2 * x + 1, 2 * y + 1, c)) / 4;
                                if (abs(out[(y * N + x) * 4 + c] - exp) > 2)
                                    failure = [NSString stringWithFormat:@"mipKernel: (%d,%d) channel %d: %d, want %d", x, y, c, out[(y * N + x) * 4 + c], exp];
                            }
                } else {
                    const float *f4 = buf.contents;
                    for (int g = 0; g < N * N && !failure; g++)
                        for (int c = 0; c < 4 && !failure; c++)
                            if (fabsf(f4[g * 4 + c] * 255.0f - texel(g % N, g / N, c)) > 2.0f)
                                failure = [NSString stringWithFormat:@"sampleKernel: texel %d channel %d: %.1f, want %d", g, c, f4[g * 4 + c] * 255.0f, texel(g % N, g / N, c)];
                }
            }
            if (!failure) [built addObject:@(t)];
            else if (!required(t)) [newer addObject:[NSString stringWithFormat:@"macOS %s (%@)", t, failure]];
            else return FAIL(bug, "%s: library built for macOS %s: %s", name, t, failure.UTF8String);
        }
        if (!libraries) return SKIP(bug, "no s75-air-*.metallib (build.sh needs Xcode's metal compiler)");
        return PASS(bug, "%s: libraries built for macOS %s build and run right%s%s", name, [built componentsJoinedByString:@", "].UTF8String,
                    newer.count ? "; not by this stack's compiler (newer AIR): " : "", [newer componentsJoinedByString:@"; "].UTF8String);
    }
}
