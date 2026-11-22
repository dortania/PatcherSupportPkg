// s76-coreimage-builtin-filters (sweep): every built-in Core Image filter rendered on the GPU under test and with Core
// Image's software renderer, with the same inputs, compared. A regression net for CoreImageOld.dylib and the GPU drivers
// under it, which Photos, Preview, Quick Look and any app with a CIFilter reach: a filter whose GPU output is missing,
// or differs from the CPU's beyond the tolerance, fails. Inputs: every CIImage input gets a 64x64 test pattern (smooth
// gradients, a hard edge, a checker, different per input), everything else its default. Both contexts work in linear
// float (RGBAf, no colour management) on a 64x64 region at the origin. Filters whose output depends on more than their
// inputs (random, text, face/ML models) or that Core Image renders differently on CPU and GPU by design are listed in
// kNotCompared and only checked for a GPU output. Filters whose GPU and CPU paths differ in Core Image itself (the same
// difference on the Iris Pro and the R9, two vendors' GPUs) are listed in kGPUvsCPU: on a Mac with a second GPU they are
// compared with it instead, else only checked for a GPU output. S76_VERBOSE=1 prints every filter's difference.
// Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <CoreImage/CoreImage.h>
#include <math.h>

static NSArray<NSString *> *kNotCompared(void) {
    return @[@"CIRandomGenerator", @"CITextImageGenerator", @"CIAttributedTextImageGenerator", @"CIDocumentEnhancer",
             @"CIPersonSegmentation", @"CIDepthBlurEffect", @"CIDepthToDisparity", @"CIDisparityToDepth",
             @"CIFaceBalance", @"CIQRCodeGenerator", @"CIAztecCodeGenerator", @"CIPDF417BarcodeGenerator",
             @"CICode128BarcodeGenerator", @"CIBarcodeGenerator", @"CIMeshGenerator", @"CICoreMLModelFilter",
             @"CIKMeans", @"CIAreaLogarithmicHistogram", @"CIConvertLabToRGB", @"CIConvertRGBtoLab"];
}

static NSArray<NSString *> *kGPUvsCPU(void) {
    return @[@"CICannyEdgeDetector", @"CIDisplacementDistortion", @"CIDroste", @"CIEdgeWork", @"CIHexagonalPixellate",
             @"CILabDeltaE", @"CIRoundedRectangleStrokeGenerator", @"CIStarShineGenerator", @"CIStretchCrop"];
}

static CIImage *pattern(int seed) {
    const int n = 64;
    NSMutableData *d = [NSMutableData dataWithLength:n * n * 4 * sizeof(float)];
    float *p = d.mutableBytes;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) {
        float *q = p + (y * n + x) * 4, u = x / 63.0f, v = y / 63.0f;
        q[0] = fmodf(u + 0.13f * seed, 1.0f);
        q[1] = 0.5f + 0.45f * sinf(6.2831853f * (v + 0.07f * seed));
        q[2] = ((x / 8 + y / 8 + seed) & 1) ? 0.85f : 0.15f;   // checker
        q[3] = x < 32 + seed ? 1.0f : 0.6f;                      // a hard alpha edge
        q[0] *= q[3]; q[1] *= q[3]; q[2] *= q[3];               // premultiplied
    }
    return [CIImage imageWithBitmapData:d bytesPerRow:n * 16 size:CGSizeMake(n, n) format:kCIFormatRGBAf colorSpace:nil];
}

static BOOL render(CIContext *ctx, CIImage *img, float *out) {
    if (!img) return NO;
    CGRect r = CGRectMake(0, 0, 64, 64);
    if (CGRectIsEmpty(CGRectIntersection(img.extent, r))) return NO;
    memset(out, 0, 64 * 64 * 16);
    [ctx render:img toBitmap:out rowBytes:64 * 16 bounds:r format:kCIFormatRGBAf colorSpace:nil];
    return YES;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s76-coreimage-builtin-filters";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    NSDictionary *opts = @{kCIContextWorkingColorSpace: [NSNull null], kCIContextOutputColorSpace: [NSNull null],
                           kCIContextWorkingFormat: @(kCIFormatRGBAf), kCIContextCacheIntermediates: @NO};
    CIContext *gpu = [CIContext contextWithMTLDevice:dev options:opts];
    NSMutableDictionary *cpuOpts = [opts mutableCopy]; cpuOpts[kCIContextUseSoftwareRenderer] = @YES;
    CIContext *cpu = [CIContext contextWithOptions:cpuOpts];
    NSArray *notCompared = kNotCompared(), *gpuVsCpu = kGPUvsCPU();
    id<MTLDevice> other = nil;  // a second GPU, for the filters whose CPU path differs
    for (id<MTLDevice> d in MTLCopyAllDevices()) if (d.registryID != dev.registryID) other = d;
    CIContext *otherCtx = other ? [CIContext contextWithMTLDevice:other options:opts] : nil;
    int againstOther = 0;
    float *a = malloc(64 * 64 * 16), *b = malloc(64 * 64 * 16);
    int compared = 0, same = 0, onlyGPUChecked = 0, neither = 0;
    NSMutableArray *bad = [NSMutableArray array];
    BOOL verbose = getenv("S76_VERBOSE") != NULL;
    for (NSString *name in [[CIFilter filterNamesInCategory:kCICategoryBuiltIn] sortedArrayUsingSelector:@selector(compare:)]) {
        @autoreleasepool {
            CIFilter *f = [CIFilter filterWithName:name];
            [f setDefaults];
            int seed = 0;
            for (NSString *key in f.inputKeys) {
                NSDictionary *attr = f.attributes[key];
                if ([attr[kCIAttributeClass] isEqual:@"CIImage"]) [f setValue:pattern(seed++) forKey:key];
            }
            CIImage *outImg = nil;
            @try { outImg = f.outputImage; } @catch (NSException *e) { outImg = nil; }
            BOOL g = NO, c = NO;
            @try { g = render(gpu, outImg, a); } @catch (NSException *e) { g = NO; }
            if ([notCompared containsObject:name]) {
                @try { c = render(cpu, outImg, b); } @catch (NSException *e) { c = NO; }
                if (c && !g) [bad addObject:[NSString stringWithFormat:@"%@ (no GPU output)", name]];
                onlyGPUChecked++;
                continue;
            }
            BOOL vsOther = [gpuVsCpu containsObject:name];
            if (vsOther && !otherCtx) {
                if (!g) [bad addObject:[NSString stringWithFormat:@"%@ (no GPU output)", name]];
                onlyGPUChecked++;
                continue;
            }
            @try { c = render(vsOther ? otherCtx : cpu, outImg, b); } @catch (NSException *e) { c = NO; }
            if (vsOther) againstOther++;
            if (!g && !c) { neither++; continue; }
            if (g != c) { [bad addObject:[NSString stringWithFormat:@"%@ (%s output only)", name, g ? "GPU" : "CPU"]]; continue; }
            float maxd = 0; int far = 0;
            for (int i = 0; i < 64 * 64 * 4; i++) {
                float x = isfinite(a[i]) ? a[i] : 1e9f, y = isfinite(b[i]) ? b[i] : 1e9f, d = x == y ? 0 : fabsf(x - y);
                if (d > maxd) maxd = d;
                if (d > 0.02f * fmaxf(1.0f, fabsf(y))) far++;   // relative where values exceed 1 (HDR generators)
            }
            compared++;
            // most filters agree to rounding; a few resample, so a handful of pixels may differ near edges
            // thresholded and HDR filters flip a few values on rounding between two GPUs: up to 3% then, else 1%
            BOOL ok = maxd <= 0.004f || far <= 64 * 64 * 4 * (vsOther ? 3 : 1) / 100;
            if (ok) same++; else [bad addObject:[NSString stringWithFormat:@"%@ (max diff %.3f from %s, %d of %d values off by > 2%%)", name, maxd,
                                                  vsOther ? other.name.UTF8String : "the software renderer", far, 64 * 64 * 4]];
            if (verbose) printf("  %-40s max %.4f far %d%s\n", name.UTF8String, maxd, far, ok ? "" : "  <- differs");
        }
    }
    free(a); free(b);
    if (bad.count) {
        printf("  %s\n", [[bad componentsJoinedByString:@"\n  "] UTF8String]);
        return FAIL(bug, "%s: %lu of %d built-in filters differ from the software renderer or have no GPU output (%d agree, %d only checked for output, %d give no output in either)",
                    dev.name.UTF8String, (unsigned long)bad.count, compared + onlyGPUChecked, same, onlyGPUChecked, neither);
    }
    return PASS(bug, "%s: %d built-in filters render on the GPU as with the software renderer (%d of them compared with %s instead), %d more only checked for a GPU output, %d give no output with default inputs",
                dev.name.UTF8String, same, againstOther, other ? other.name.UTF8String : "no other GPU", onlyGPUChecked, neither);
}}
