// s77-coreimage-kernel-kinds (sweep, with the payload's CoreImageOld.dylib): precompiled Core Image kernels of every kind
// (colour, warp, blend, general, and [[stitchable]] colour), from libraries built for every macOS target an app may have
// shipped (10.13 to 26.0: AIR 2.0 to 2.8), loaded with +kernelWithFunctionName:fromMetalLibraryData:error: as third-party
// apps do and rendered on the GPU under test; each pixel is checked against the value computed here. Office's picture
// corrections (s68) took one kind from two targets; this covers the rest of the public loading path. Libraries a newer
// compiler than the stack's is needed for are reported, not failed. Inputs: s77-ci-<target>.metallib and
// s77-ci-stitchable-<target>.metallib (build.sh, with Xcode's metal); none present: SKIP.
// Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <CoreImage/CoreImage.h>
#import <mach-o/dyld.h>
#include <libgen.h>
#include <math.h>

static float in0[64 * 64 * 4], in1[64 * 64 * 4];

static CIImage *pattern(float *p, int seed) {
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
        float *q = p + (y * 64 + x) * 4;
        q[3] = x < 30 + seed ? 1.0f : 0.5f;
        q[0] = fmodf(x / 63.0f + 0.2f * seed, 1.0f) * q[3];
        q[1] = (0.5f + 0.4f * sinf(0.3f * y + seed)) * q[3];
        q[2] = (((x / 4) + (y / 4) + seed) & 1 ? 0.9f : 0.1f) * q[3];
    }
    NSData *d = [NSData dataWithBytes:p length:64 * 64 * 16];
    return [CIImage imageWithBitmapData:d bytesPerRow:64 * 16 size:CGSizeMake(64, 64) format:kCIFormatRGBAf colorSpace:nil];
}

// the value each kernel should give at pixel (x, y), channel c; NAN where the kernel reads outside the image
static float expected(const char *kind, int x, int y, int c) {
    const float *p = in0 + (y * 64 + x) * 4;
    if (!strcmp(kind, "color") || !strcmp(kind, "stitchable")) return c < 3 ? p[c] * 0.5f + 0.25f * p[3] : p[3];
    if (!strcmp(kind, "warp")) return x >= 3 ? in0[(y * 64 + x - 3) * 4 + c] : NAN;
    if (!strcmp(kind, "blend")) { const float *b = in1 + (y * 64 + x) * 4; return p[c] + b[c] * (1.0f - p[3]); }
    if (!strcmp(kind, "general")) return x < 63 ? 0.5f * (p[c] + in0[(y * 64 + x + 1) * 4 + c]) : NAN;
    return NAN;
}

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "s77-coreimage-kernel-kinds";
    id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
    if (!dev) return SKIP(bug, "no such GPU");
    char exe[4096]; uint32_t size = sizeof exe; _NSGetExecutablePath(exe, &size);
    NSString *dir = @(dirname(exe));
    CIContext *ctx = [CIContext contextWithMTLDevice:dev options:@{kCIContextWorkingColorSpace: [NSNull null],
        kCIContextOutputColorSpace: [NSNull null], kCIContextWorkingFormat: @(kCIFormatRGBAf), kCIContextCacheIntermediates: @NO}];
    CIImage *a = pattern(in0, 0), *b = pattern(in1, 1);
    NSArray *targets = @[@"10.13", @"10.14", @"10.15", @"11.0", @"12.0", @"13.0", @"14.0", @"15.0", @"26.0"];
    int checked = 0, found = 0; NSMutableArray *bad = [NSMutableArray array], *newer = [NSMutableArray array];
    static float out[64 * 64 * 4];
    for (NSString *t in targets) for (NSString *kind in @[@"color", @"warp", @"blend", @"general", @"stitchable"]) {
        BOOL st = [kind isEqual:@"stitchable"];
        NSString *file = [dir stringByAppendingPathComponent:st ? [NSString stringWithFormat:@"s77-ci-stitchable-%@.metallib", t]
                                                                 : [NSString stringWithFormat:@"s77-ci-%@.metallib", t]];
        NSData *lib = [NSData dataWithContentsOfFile:file];
        if (!lib) continue;
        found++;
        NSString *fn = [@"s77_" stringByAppendingString:kind];
        NSError *err = nil; CIImage *img = nil; CIKernel *k = nil;
        @try {
            if ([kind isEqual:@"color"] || st) k = [CIColorKernel kernelWithFunctionName:fn fromMetalLibraryData:lib error:&err];
            else if ([kind isEqual:@"warp"]) k = [CIWarpKernel kernelWithFunctionName:fn fromMetalLibraryData:lib error:&err];
            else if ([kind isEqual:@"blend"]) k = [CIBlendKernel kernelWithFunctionName:fn fromMetalLibraryData:lib error:&err];
            else k = [CIKernel kernelWithFunctionName:fn fromMetalLibraryData:lib error:&err];
            if ([kind isEqual:@"color"] || st) img = [(CIColorKernel *)k applyWithExtent:a.extent arguments:@[a]];
            else if ([kind isEqual:@"warp"]) img = [(CIWarpKernel *)k applyWithExtent:a.extent roiCallback:^CGRect(int i, CGRect r) { return CGRectInset(r, -4, -1); } inputImage:a arguments:@[]];
            else if ([kind isEqual:@"blend"]) img = [(CIBlendKernel *)k applyWithForeground:a background:b];
            else img = [k applyWithExtent:a.extent roiCallback:^CGRect(int i, CGRect r) { return CGRectInset(r, -2, -1); } arguments:@[a]];
        } @catch (NSException *e) { err = [NSError errorWithDomain:@"s77" code:1 userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}]; }
        if (!k || !img) {
            NSString *why = err.localizedDescription ?: @"nil kernel, no error";
            if ([why containsString:@"newer"] || [why containsString:@"not compatible"]) [newer addObject:[NSString stringWithFormat:@"%@ %@", kind, t]];
            else [bad addObject:[NSString stringWithFormat:@"%@ from %@: %@ (%@)", kind, t, k ? @"no output image" : @"no kernel", why]];
            continue;
        }
        memset(out, 0, sizeof out);
        [ctx render:img toBitmap:out rowBytes:64 * 16 bounds:CGRectMake(0, 0, 64, 64) format:kCIFormatRGBAf colorSpace:nil];
        float worst = 0; int wx = 0, wy = 0, wc = 0;
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) for (int c = 0; c < 4; c++) {
            float e = expected(kind.UTF8String, x, y, c); if (isnan(e)) continue;
            float d = fabsf(out[(y * 64 + x) * 4 + c] - e); if (!(d <= worst)) { worst = d; wx = x; wy = y; wc = c; }
        }
        checked++;
        if (!(worst <= 0.002f))
            [bad addObject:[NSString stringWithFormat:@"%@ from %@: pixel (%d, %d) channel %d is %.4f, want %.4f", kind, t, wx, wy, wc,
                            out[(wy * 64 + wx) * 4 + wc], expected(kind.UTF8String, wx, wy, wc)]];
    }
    if (!found) return SKIP(bug, "no s77-ci-*.metallib next to the test (build.sh needs Xcode's metal compiler)");
    NSString *note = newer.count ? [NSString stringWithFormat:@"; need a newer compiler (reported): %@", [newer componentsJoinedByString:@", "]] : @"";
    if (bad.count) {
        printf("  %s\n", [[bad componentsJoinedByString:@"\n  "] UTF8String]);
        return FAIL(bug, "%s: %lu of %d precompiled Core Image kernels wrong or not loaded%s", dev.name.UTF8String, (unsigned long)bad.count, found, note.UTF8String);
    }
    return PASS(bug, "%s: %d precompiled Core Image kernels (colour, warp, blend, general, stitchable; macOS 10.13 to 26.0 libraries) load and compute right%s",
                dev.name.UTF8String, checked, note.UTF8String);
}}
