// s53-coreimageold-portrait-kernels (MetalOldCompat item 41): CIDepthBlurEffect, the filter behind Photos' portrait
// editing, applied twice and rendered on the GPU. CoreImageOld.dylib (the 14.0 beta 3 Core Image the 3802 payloads
// install) loads its portrait kernels from a static NSData that it never retains: once an autorelease pool drains, the
// next portrait kernel gets a dangling pointer and the process crashes in -[CIKernelLibrary initWithData:error:] (OCLP
// issue #1008, "Photos app failing to edit portrait photos", on Intel and AMD alike). Skips without CoreImageOld.
// Stock OCLP: crash (FAIL). Fixed: PASS (the filter renders; MetalOld can't list the functions of Sequoia's portrait
// metallibs, so the blur itself is not applied). Argument: GPU name substring (default: Intel).
#import "repro.h"
#import <CoreImage/CoreImage.h>
#include <unistd.h>

static CIImage *depthBlur(CGRect r) {
    CIImage *checker = [[CIFilter filterWithName:@"CICheckerboardGenerator" withInputParameters:@{@"inputWidth": @24}].outputImage imageByCroppingToRect:r];
    CIImage *disparity = [[CIFilter filterWithName:@"CIRadialGradient" withInputParameters:@{
        @"inputCenter": [CIVector vectorWithX:r.size.width / 2 Y:r.size.height / 2], @"inputRadius0": @40, @"inputRadius1": @160,
        @"inputColor0": [CIColor colorWithRed:1 green:1 blue:1], @"inputColor1": [CIColor colorWithRed:0 green:0 blue:0]}].outputImage imageByCroppingToRect:r];
    CIFilter *f = [CIFilter filterWithName:@"CIDepthBlurEffect"];
    [f setValue:checker forKey:kCIInputImageKey];
    [f setValue:disparity forKey:@"inputDisparityImage"];
    [f setValue:@8.0 forKey:@"inputAperture"];
    [f setValue:[CIVector vectorWithCGRect:CGRectInset(r, r.size.width / 3, r.size.height / 3)] forKey:@"inputFocusRect"];
    return [f.outputImage imageByCroppingToRect:r];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s53-coreimageold-portrait-kernels";
        if (access("/System/Library/Frameworks/CoreImage.framework/Versions/A/CoreImageOld.dylib", F_OK)) return SKIP(bug, "no CoreImageOld.dylib");
        id<MTLDevice> dev = reproDevice(argc, argv, "Intel");
        if (!dev) return SKIP(bug, "no such GPU");
        const char *name = dev.name.UTF8String;
        CGRect r = CGRectMake(0, 0, 256, 192);
        CIContext *context = [CIContext contextWithMTLDevice:dev];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        uint8_t *pixels = malloc(256 * 192 * 4);
        for (int pass = 0; pass < 2; pass++) @autoreleasepool {  // the second pass runs after the first one's pool drained
            CIImage *out = depthBlur(r);
            if (!out) return FAIL(bug, "%s: CIDepthBlurEffect produced no image (pass %d)", name, pass + 1);
            [context render:out toBitmap:pixels rowBytes:256 * 4 bounds:r format:kCIFormatRGBA8 colorSpace:cs];
        }
        return PASS(bug, "%s: CIDepthBlurEffect builds its portrait kernels and renders twice without crashing", name);
    }
}
