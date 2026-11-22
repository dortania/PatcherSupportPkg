// s74-chromium-angle-libraries (MetalOldCompat item 13 for old ANGLE libraries): the prebuilt ANGLE internal-shader library of
// every Chromium-based app installed (Chrome, Edge, Brave, Electron apps such as VS Code, anything bundling libGLESv2.dylib),
// loaded as ANGLE loads it, with each of the pipelines ANGLE builds from it: the clear, the blits for every color type and
// source texture type, the depth blit and the mipmap kernels. Chromium ships that library built for macOS 10.14 (AIR 2.1);
// on Tahoe's compiler for this stack every blit pipeline and mipmap kernel built from it aborted MTLCompilerService three
// times ("Invalid record", "INSERTVAL: Invalid type") and failed, so a Chromium app's GPU process got stuck or drew without
// its blits (OpenVPN Connect, VS Code, Chrome 158; reported on the PR by Gabriel-AGH with a patch). The shim compiles
// WebKit's ANGLE source in its place. On Sequoia the prebuilt library builds either way. SKIP when no such app is installed;
// it searches Tests/apps (tools/fetch-apps.sh fills it), /Applications and ~/Applications, or S74_APPS=<dir>[:<dir>...].
// Stock OCLP on Tahoe: FAIL. Fixed: PASS. Argument: GPU name substring (default: the system default GPU).
#import "repro.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

// ANGLE's internal library inside one binary: an MTLB container with ANGLE's source name or symbols in it
static void scanBinary(NSString *path, NSString *app, NSMutableArray *found, NSMutableSet *seen) {
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (file.length < 64) return;
    const uint8_t *bytes = file.bytes, *end = bytes + file.length;
    for (const uint8_t *p = bytes; (p = memmem(p, end - p, "MTLB\x01\x80", 6)); p += 6) {
        if (end - p < 0x18) break;
        uint64_t size;
        memcpy(&size, p + 0x10, 8);
        if (size < 1024 || size > (uint64_t)(end - p)) continue;
        if (!memmem(p, size, "mtl_internal_shaders_autogen", 28) && !memmem(p, size, "rx10mtl_shader", 14)) continue;
        NSData *library = [NSData dataWithBytes:p length:size];
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(library.bytes, (CC_LONG)library.length, digest);
        NSData *key = [NSData dataWithBytes:digest length:sizeof digest];
        if ([seen containsObject:key]) continue;  // the other slice of a universal binary, or another app's copy
        [seen addObject:key];
        [found addObject:@[app, library]];
    }
}

static void scanApps(NSString *dir, NSMutableArray *found, NSMutableSet *seen) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name hasSuffix:@".app"]) continue;
        NSString *frameworks = [[dir stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Contents/Frameworks"];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:frameworks error:nil]) {
            NSString *path = [frameworks stringByAppendingPathComponent:entry];
            if ([entry hasSuffix:@".framework"]) {  // Google Chrome Framework, Electron Framework, Microsoft Edge Framework, ...
                NSString *binary = [path stringByAppendingPathComponent:[entry stringByDeletingPathExtension]];
                if ([fm fileExistsAtPath:binary]) scanBinary(binary.stringByResolvingSymlinksInPath, name, found, seen);
                NSString *gles = [path stringByAppendingPathComponent:@"Libraries/libGLESv2.dylib"];
                if ([fm fileExistsAtPath:gles]) scanBinary(gles.stringByResolvingSymlinksInPath, name, found, seen);
            } else if ([entry isEqualToString:@"libGLESv2.dylib"]) {
                scanBinary(path, name, found, seen);
            }
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s74-chromium-angle-libraries";
        id<MTLDevice> dev = argc > 1 ? reproDevice(argc, argv, "") : MTLCreateSystemDefaultDevice();
        if (!dev) return SKIP(bug, "no such GPU");
        NSMutableArray *found = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSArray *dirs = getenv("S74_APPS") ? [@(getenv("S74_APPS")) componentsSeparatedByString:@":"]
                                           : @[[[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../apps"],  // tools/fetch-apps.sh
                                               @"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
        for (NSString *dir in dirs) scanApps(dir, found, seen);
        if (!found.count) return SKIP(bug, "no Chromium-based app with a prebuilt ANGLE library installed");
        NSString *helper = [[@(argv[0]) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../tools/angle-caller/libANGLE-shared.dylib"];
        void *caller = dlopen(helper.UTF8String, RTLD_NOW);
        id (*load)(id<MTLDevice>, NSData *, NSError **) = caller ? dlsym(caller, "s63LoadAngleLibrary") : NULL;
        if (!load) return SKIP(bug, "no %s", helper.UTF8String);
        NSMutableArray *apps = [NSMutableArray array];
        unsigned pipelines = 0;
        for (NSArray *entry in found) {
            NSString *app = entry[0];
            NSError *error = nil;
            id<MTLLibrary> library = load(dev, entry[1], &error);
            if (!library) return FAIL(bug, "%s: %s's ANGLE library didn't load: %s", dev.name.UTF8String, app.UTF8String, error.localizedDescription.UTF8String);
            [apps addObject:app];
            // function constants of ANGLE's blit and clear shaders: 0 kNumColorOutputs, 1-3 premultiply / unmultiply / linear to
            // sRGB, 4 kSourceTextureType (2D, 2D multisample, 2D array, cube, 3D)
            MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
            uint32_t one = 1;
            bool no = false;
            [constants setConstantValue:&one type:MTLDataTypeUInt atIndex:0];
            for (NSUInteger i = 1; i <= 3; i++) [constants setConstantValue:&no type:MTLDataTypeBool atIndex:i];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [library newFunctionWithName:@"clearVS" constantValues:constants error:&error];
            pd.fragmentFunction = pd.vertexFunction ? [library newFunctionWithName:@"clearFloatFS" constantValues:constants error:&error] : nil;
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            if (!pd.fragmentFunction || ![dev newRenderPipelineStateWithDescriptor:pd error:&error])
                return FAIL(bug, "%s: %s's ANGLE clear pipeline: %s", dev.name.UTF8String, app.UTF8String, error.localizedDescription.UTF8String);
            pipelines++;
            id<MTLFunction> blitVS = [library newFunctionWithName:@"blitVS"];
            if (!blitVS) return FAIL(bug, "%s: %s's ANGLE library has no blitVS", dev.name.UTF8String, app.UTF8String);
            struct { NSString *fs; MTLPixelFormat color, depth; } blits[] = {
                {@"blitFloatFS", MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid}, {@"blitIntFS", MTLPixelFormatRGBA8Sint, MTLPixelFormatInvalid},
                {@"blitUIntFS", MTLPixelFormatRGBA8Uint, MTLPixelFormatInvalid}, {@"blitDepthFS", MTLPixelFormatInvalid, MTLPixelFormatDepth32Float}};
            static const char *types[] = {"2D", "2D multisample", "2D array", "cube", "3D"};
            for (unsigned b = 0; b < sizeof blits / sizeof blits[0]; b++) {
                if (![library.functionNames containsObject:blits[b].fs]) continue;
                for (int type = 0; type < 5; type++) {
                    [constants setConstantValue:&type type:MTLDataTypeInt atIndex:4];
                    MTLRenderPipelineDescriptor *bd = [MTLRenderPipelineDescriptor new];
                    bd.vertexFunction = blitVS;
                    bd.fragmentFunction = [library newFunctionWithName:blits[b].fs constantValues:constants error:&error];
                    bd.colorAttachments[0].pixelFormat = blits[b].color;
                    bd.depthAttachmentPixelFormat = blits[b].depth;
                    if (!bd.fragmentFunction || ![dev newRenderPipelineStateWithDescriptor:bd error:&error])
                        return FAIL(bug, "%s: %s's ANGLE %s, %s source: %s", dev.name.UTF8String, app.UTF8String, blits[b].fs.UTF8String,
                                    types[type], error.localizedDescription.UTF8String);
                    pipelines++;
                }
            }
            for (NSString *kernel in @[@"generate3DMipmaps", @"generate2DMipmaps", @"generateCubeMipmaps", @"generate2DArrayMipmaps"]) {
                id<MTLFunction> function = [library newFunctionWithName:kernel];
                if (!function) continue;
                if (![dev newComputePipelineStateWithFunction:function error:&error])
                    return FAIL(bug, "%s: %s's ANGLE %s: %s", dev.name.UTF8String, app.UTF8String, kernel.UTF8String, error.localizedDescription.UTF8String);
                pipelines++;
            }
        }
        return PASS(bug, "%s: %u pipelines (clear, blits for every source type, depth blit, mipmap kernels) build from the ANGLE "
                         "library of %s", dev.name.UTF8String, pipelines, [apps componentsJoinedByString:@", "].UTF8String);
    }
}
