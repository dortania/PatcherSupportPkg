// s68-coreimage-metal-kernels (MetalOldCompat item 52, with the payload's CoreImageOld.dylib): Core Image kernels an
// app loads from a metallib, and the reflection of [[stitchable]] functions under them. OCLP's CoreImageOld.dylib (the
// 14.0 beta 3 Core Image of the 3802 payloads) has CIKernelReflection::reflect stubbed out, so +[CIKernel
// kernelWithFunctionName:fromMetalLibraryData:error:] returned nil, without an error, for every precompiled kernel:
// Microsoft Office's picture corrections, colour and artistic effects (Gabriel-AGH, PR #22). The stub kept stitchable
// kernels away from MetalOld's MTLStitchingReflectionReader, which aborted on the reflection replies of Sequoia's compiler
// service. Two checks, each in a child process (both abort or fail on an unfixed stack):
//  1. a [[stitchable]] function's return type (float4), which MetalOld reflects through the compiler service: the
//     stitchable kernel of s68-ci-stitchable.metallib, or without it one compiled from source. Stock OCLP: abort in
//     MTLStitchingReflectionReader::deserializeArguments. (A run that aborted can leave an empty reply in Metal's shader
//     cache, which later runs get back as no reflection, and the check then skips: clear the cache.)
//  2. Core Image: the same brightness kernel (+0.25 on (102,128,153)) as a precompiled color kernel built for macOS
//     14.0 and for 15.0 (AIR 2.7, as Office 16.115 ships; item 25 compiles it), and as a stitchable kernel, each loaded
//     with kernelWithFunctionName:fromMetalLibraryData:error: and rendered on the GPU. Stock OCLP: nil kernels. Then
//     two kernels in one Core Image kernel language string (+[CIKernel kernelsWithString:]; stock: nil, OCLP stubbed
//     it) and a stitchable kernel in Metal source (+[CIKernel kernelsWithMetalString:error:]; stock: abort, because
//     CoreImageOld looked for its Metal header in OCLP's CoreImage wrapper). The payload's CoreImageOld fixes both.
//     Inputs: s68-ci-macos14.metallib, s68-ci-macos15.metallib, s68-ci-stitchable.metallib (build.sh makes them with
//     Xcode's metal compiler); without them, or while the loaded CoreImageOld still has OCLP's stub (the payload isn't
//     installed), only check 1 decides, and the line says so.
// Check 1 asks MTLCompilerService, so the shim under test must be loaded there too (verify.sh passes it with
// __XPC_DYLD_INSERT_LIBRARIES). Skips without MetalOld. Stock OCLP: FAIL. Fixed: PASS. Argument: GPU name substring
// (default: Intel).
#import "repro.h"
#import <CoreImage/CoreImage.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#include <libgen.h>

static NSString *testDir;

// 1. Return type of a stitchable function: 0 float4, 9 another type, 10 no reflection.
static int stitchableReturnType(id<MTLDevice> dev) {
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfFile:[testDir stringByAppendingPathComponent:@"s68-ci-stitchable.metallib"]];
    id<MTLFunction> f = nil;
    if (data) {
        dispatch_data_t d = dispatch_data_create(data.bytes, data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        f = [[dev newLibraryWithData:d error:&err] newFunctionWithName:@"s68_brightness"];
    } else {
        NSString *src = [reproUniqueComment() stringByAppendingString:@"#include <metal_stdlib>\nusing namespace metal;\n"
                         "[[stitchable]] float4 scale(float4 v, float k, device const float *table) { return v * k + table[0]; }\n"];
        f = [[dev newLibraryWithSource:src options:nil error:&err] newFunctionWithName:@"scale"];
    }
    if (!f) { fprintf(stderr, "s68: no function: %s\n", err.localizedDescription.UTF8String); return 10; }
    if (![(id)f respondsToSelector:sel_registerName("returnType")]) return 10;
    MTLType *type = ((MTLType *(*)(id, SEL))objc_msgSend)(f, sel_registerName("returnType"));
    if (!type) return 10;
    return type.dataType == MTLDataTypeFloat4 ? 0 : 9;
}

// OCLP's stub at CoreImageOld's CIKernelReflection::reflect (its __TEXT starts at offset 0; the function is at 0xb30a).
static bool coreImageOldStubbed(void) {
    static const unsigned char stub[11] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xc3};
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t n = strlen(name);
        if (n > 19 && !strcmp(name + n - 19, "/CoreImageOld.dylib"))
            return !memcmp((const char *)_dyld_get_image_header(i) + 0xb30a, stub, sizeof stub);
    }
    return false;
}

// Renders kernel k with argument 0.25 on (102,128,153) and compares with want (±3): 0 right, 1 wrong.
static int renderCheck(CIContext *ctx, CGColorSpaceRef srgb, CIImage *in, CIColorKernel *k, const int want[4], const char *what) {
    CIImage *out = [k applyWithExtent:in.extent arguments:@[in, @0.25f]];
    uint8_t px[4] = {0};
    [ctx render:out toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:srgb];
    for (int c = 0; c < 4; c++)
        if (abs(px[c] - want[c]) > 3) {
            fprintf(stderr, "s68: %s: (%u,%u,%u,%u), want (%d,%d,%d,%d)\n", what, px[0], px[1], px[2], px[3], want[0], want[1], want[2], want[3]);
            return 1;
        }
    return 0;
}

// 2. Core Image kernels: 0 all render right, 20+i kernel i nil, 30+i kernel i rendered wrong (i: the three metallibs,
// 3 kernelsWithString, 4 kernelsWithMetalString), 77 no metallibs, 78 CoreImageOld still stubbed.
static int coreImageKernels(id<MTLDevice> dev) {
    NSArray<NSString *> *files = @[@"s68-ci-macos14.metallib", @"s68-ci-macos15.metallib", @"s68-ci-stitchable.metallib"];
    NSMutableArray<NSData *> *libraries = [NSMutableArray array];
    for (NSString *file in files) {
        NSData *data = [NSData dataWithContentsOfFile:[testDir stringByAppendingPathComponent:file]];
        if (!data) return 77;
        [libraries addObject:data];
    }
    [CIImage emptyImage];  // loads Core Image (CoreImageOld behind OCLP's wrapper)
    if (coreImageOldStubbed()) return 78;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIContext *ctx = [CIContext contextWithMTLDevice:dev options:@{kCIContextWorkingColorSpace: (__bridge id)srgb,
                                                                   kCIContextOutputColorSpace: (__bridge id)srgb}];
    CIImage *in = [[CIImage imageWithColor:[CIColor colorWithRed:102 / 255.0 green:128 / 255.0 blue:153 / 255.0]]
                   imageByCroppingToRect:CGRectMake(0, 0, 4, 4)];
    const int brighter[4] = {166, 192, 217, 255};
    for (NSUInteger i = 0; i < libraries.count; i++) {
        NSError *err = nil;
        CIKernel *k = [CIKernel kernelWithFunctionName:@"s68_brightness" fromMetalLibraryData:libraries[i] error:&err];
        if (![k isKindOfClass:[CIColorKernel class]]) {
            fprintf(stderr, "s68: %s: no color kernel (%s)\n", files[i].UTF8String, err ? err.localizedDescription.UTF8String : "no error");
            return 20 + (int)i;
        }
        if (renderCheck(ctx, srgb, in, (CIColorKernel *)k, brighter, files[i].UTF8String)) return 30 + (int)i;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<CIKernel *> *cikl = [CIKernel kernelsWithString:
        @"kernel vec4 s68_brighter(__sample s, float k) { return vec4(s.rgb + k, s.a); }\n"
         "kernel vec4 s68_darker(__sample s, float k) { return vec4(s.rgb - k, s.a); }\n"];
#pragma clang diagnostic pop
    if (cikl.count != 2 || ![cikl[0] isKindOfClass:[CIColorKernel class]] || ![cikl[1] isKindOfClass:[CIColorKernel class]]) {
        fprintf(stderr, "s68: kernelsWithString: %lu kernels\n", (unsigned long)cikl.count);
        return 23;
    }
    const int darker[4] = {38, 64, 89, 255};
    if (renderCheck(ctx, srgb, in, (CIColorKernel *)cikl[0], brighter, "kernelsWithString: s68_brighter") ||
        renderCheck(ctx, srgb, in, (CIColorKernel *)cikl[1], darker, "kernelsWithString: s68_darker")) return 33;
    NSError *err = nil;
    NSArray<CIKernel *> *metal = [CIKernel kernelsWithMetalString:
        @"#include <CoreImage/CoreImage.h>\nextern \"C\" { namespace coreimage {\n"
         "[[stitchable]] float4 s68_metal(sample_t s, float k) { return float4(s.rgb + k, s.a); }\n}}\n" error:&err];
    if (metal.count != 1 || ![metal[0] isKindOfClass:[CIColorKernel class]]) {
        fprintf(stderr, "s68: kernelsWithMetalString: %lu kernels (%s)\n", (unsigned long)metal.count,
                err ? err.description.UTF8String : "no error");
        return 24;
    }
    if (renderCheck(ctx, srgb, in, (CIColorKernel *)metal[0], brighter, "kernelsWithMetalString")) return 34;
    CGColorSpaceRelease(srgb);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s68-coreimage-metal-kernels";
        char self[1024];
        strlcpy(self, argv[0], sizeof self);
        testDir = @(dirname(self));
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        const char *mode = reproChildMode(argc, argv);
        if (mode) return !dev ? 77 : !strcmp(mode, "stitchable") ? stitchableReturnType(dev) : coreImageKernels(dev);
        if (!dev) return SKIP(bug, "no such GPU");
        if (!reproOnMetalOld()) return SKIP(bug, "not on OCLP's legacy Metal (MetalOld)");
        const char *gpu = dev.name.UTF8String;
        int stitchable = reproRunChild(argc, argv, "stitchable");
        if (stitchable == 10) return SKIP(bug, "%s: no reflection for stitchable functions here", gpu);
        if (stitchable)
            return FAIL(bug, "%s: return type of a [[stitchable]] function: %s", gpu, stitchable == 9 ? "not float4" : reproChildStatus(stitchable));
        int ci = reproRunChild(argc, argv, "ci");
        static const char *kinds[] = {"precompiled (macOS 14.0)", "precompiled (macOS 15.0, AIR 2.7)", "stitchable",
                                      "kernel language (kernelsWithString:)", "Metal source (kernelsWithMetalString:)"};
        if (ci >= 20 && ci < 25) return FAIL(bug, "%s: %s Core Image kernel came back nil", gpu, kinds[ci - 20]);
        if (ci >= 30 && ci < 35) return FAIL(bug, "%s: %s Core Image kernel rendered the wrong pixel", gpu, kinds[ci - 30]);
        if (ci == 77) return PASS(bug, "%s: stitchable function reflected (float4); Core Image not checked: no s68-ci-*.metallib (build.sh)", gpu);
        if (ci == 78) return PASS(bug, "%s: stitchable function reflected (float4); Core Image not checked: CoreImageOld still has OCLP's reflect stub", gpu);
        if (ci) return FAIL(bug, "%s: Core Image kernels: %s", gpu, reproChildStatus(ci));
        return PASS(bug, "%s: stitchable function reflected (float4); precompiled (macOS 14.0 and 15.0), stitchable, kernel language and Metal source Core Image kernels load and render", gpu);
    }
}
