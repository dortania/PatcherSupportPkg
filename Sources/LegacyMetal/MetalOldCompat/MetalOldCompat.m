// MetalOldCompat.dylib: fixes for OCLP's Metal 3802 stack (MetalOld.dylib = Metal from macOS 13.2, used for every GPU
// on Macs that also have a Haswell/Ivy Bridge iGPU) when apps built for macOS 15 drive a GPU whose shaders are compiled
// by the newer MTLCompiler (the AMD GCN dGPU of MacBookPro11,5 / iMac15,1):
//   1. MTLDevice methods from the macOS 13.3+/15 SDK that MetalOld lacks ("unrecognized selector" crashes)
//   2. reflection data wrapped in the newer CompilerOutputReflectionBlock container, which MetalOld can't read
//   3. MTLTextureUsageShaderAtomic, which MetalOld rejects in texture validation
//   7. serialized vertex descriptors, whose layout records changed size between MetalOld and the newer compiler
//   8. properties and encoder calls from the macOS 13.3-15 SDKs (MTLCompileOptions.mathMode, shaderValidation, ...;
//      object/mesh stage bindings on GPUs without mesh shaders)
//   9. MSL 3.2 requests (compiled as 3.1, the newest this stack's front end has; also the default; 3.2's coherence
//      qualifiers rewritten to their 3.1 equivalents)
//  10. Metal devices pinned against over-release (Chromium's GPU process)
//  11. ANGLE (Chromium, Safari's WebKit): past ANGLE's pre-2016-Mac gate, and only family-2 GPUs (the AMD dGPU) for it
//  12. sRGB mipmaps on the 12.5 AMD driver (its blit averages the encoded bytes)
//  13. Safari's ANGLE: its prebuilt internal-shader metallib (too new for this stack) replaced by the same shaders
//      compiled from source
//  14. argument encoders in Safari's processes (OCLP's wrapper stubs them out; WebGL 2 uniform blocks need them)
//  15. 12.x Intel driver: MSAA resolves into a mip level / array slice other than 0 (lost, or a crash); fast clears of
//      color targets at most 2 texels wide (rows missed)
//  16. 2D-array texture views that don't start at slice 0 on the 12.x Intel driver (most of their layers unreachable)
//  17. depth/stencil attachments that are views of mip 1+ on the 12.5 AMD driver (nothing rendered): parent attached
//  18. pipeline cache keys that ignore the pipeline descriptor (a compute pipeline's maxTotalThreadsPerThreadgroup):
//      MetalOld told to key by the driver's function key
// Loaded into every Metal client by a weak load command added to OCLP's Metal.framework wrapper; does nothing unless
// _MTLDevice comes from MetalOld.dylib. Set MTLSHIM_VERBOSE=1 to log what it does (to stderr; MTLSHIM_VERBOSE=oslog
// sends it to the unified log, for sandboxed XPC services such as WebKit's GPU process). Build with build.sh.
// Methods are only added if the class doesn't already implement them (class_addMethod never overrides).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <dlfcn.h>
#include <os/lock.h>
#import <IOKit/IOKitLib.h>
#include <os/log.h>
#include <stdarg.h>

static void shimLog(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void shimLog(const char *format, ...) {
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    const char *mode = getenv("MTLSHIM_VERBOSE");
    if (mode && !strcmp(mode, "oslog")) os_log(OS_LOG_DEFAULT, "%{public}s", line);
    else fputs(line, stderr);
}

static char kMaximizeKey;

static void setShouldMaximize(id self, SEL _cmd, BOOL value) {
    objc_setAssociatedObject(self, &kMaximizeKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL shouldMaximize(id self, SEL _cmd) {
    return [objc_getAssociatedObject(self, &kMaximizeKey) boolValue];
}

// MetalOld has no concurrency knob, so the flag is a no-op hint; report a plausible task count either way.
static NSUInteger maxConcurrentTasks(id self, SEL _cmd) {
    return shouldMaximize(self, _cmd) ? NSProcessInfo.processInfo.activeProcessorCount : 2;
}

// Private capability query Sequoia's MetalTools (MTL_DEBUG_LAYER=1) asks the device it wraps. NO is the truth here:
// the attributeStride encoder calls below are accepted but use the pipeline's strides.
static BOOL no(id self, SEL _cmd) { return NO; }

static id unsupported(id self, SEL _cmd, id descriptor, NSError **error) {
    if (error)
        *error = [NSError errorWithDomain:@"MTLDeviceErrorDomain" code:1 userInfo:@{
            NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%s is not supported on this device", sel_getName(_cmd)]}];
    return nil;
}

// The native (Sequoia) MTLCompiler wraps reflection in a CompilerOutputReflectionBlock container that MetalOld's
// readers predate. Layout: u32 magic 0xEF13C710, u32 8 (entry count), u64 version 20230418, then 4 x (u64 offset,
// u64 size): [0] classic MTLPSBIN reflection (always at 0x50), [1]/[2] AIR reflection flatbuffers, [3] extra data.
// MetalOld only understands [0], so hand it that and drop the rest.
enum { kReflBlockMagic = 0xEF13C710, kReflBlockEntries = 8, kReflBlockHeaderSize = 0x50 };

static dispatch_data_t unwrapReflection(dispatch_data_t data) {
    if (!data || dispatch_data_get_size(data) < kReflBlockHeaderSize) return data;
    const void *buf = NULL;
    size_t size = 0;
    dispatch_data_t header = dispatch_data_create_map(dispatch_data_create_subrange(data, 0, kReflBlockHeaderSize), &buf, &size);
    const uint32_t *h32 = buf;
    const uint64_t *h64 = buf;
    if (!header || h32[0] != kReflBlockMagic || h32[1] != kReflBlockEntries) return data;
    uint64_t offset = h64[2], length = h64[3], total = dispatch_data_get_size(data);
    if (offset < kReflBlockHeaderSize || offset > total || length > total - offset) return data;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] unwrapped reflection block (%llu bytes at 0x%llx of %llu)\n", length, offset, total);
    return dispatch_data_create_subrange(data, offset, length);
}

// Serialized vertex descriptors: MetalOld writes layout records of 12 bytes {u32 bufferIndex|stepFunction<<5,
// u32 stepRate, u32 stride}; the 14.2-era MTLCompiler that compiles for the AMD GPU reads 16-byte records with a u64
// stride at +8. Header (u16 size, u16 counts: layouts in bits 6-10 and attributes in bits 11+, u16 layout table
// offset, u16 attribute table offset) and the 8-byte attribute records are the same in both. Only the first layout
// happens to parse correctly in the old format, so every multi-buffer vertex descriptor breaks.
enum { kVDHeaderSize = 8, kVDOldLayoutSize = 12, kVDNewLayoutSize = 16, kVDAttributeSize = 8 };

// The descriptor may follow a prefix (the vertex-stage request starts with 12 bytes of other data); find it by its
// self-describing header: total size equal to the bytes remaining and the layout table right after the header.
static BOOL findVertexDescriptor(const uint8_t *buf, size_t size, size_t *offset) {
    for (size_t off = 0; off + kVDHeaderSize <= size && off <= 32; off += 4) {
        const uint16_t *h = (const uint16_t *)(buf + off);
        if (h[0] == size - off && h[2] == kVDHeaderSize && h[3] <= h[0]) { *offset = off; return YES; }
    }
    return NO;
}

static dispatch_data_t convertVertexDescriptor(dispatch_data_t data, BOOL toNew) {
    if (!data || dispatch_data_get_size(data) < kVDHeaderSize) return data;
    const uint8_t *buf = NULL;
    size_t total = 0, off = 0;
    dispatch_data_t map = dispatch_data_create_map(data, (const void **)&buf, &total);
    if (!map || !findVertexDescriptor(buf, total, &off)) return data;
    const uint8_t *src = buf + off;
    size_t size = total - off;
    uint16_t counts = *(const uint16_t *)(src + 2), attrsOff = *(const uint16_t *)(src + 6);
    unsigned layouts = (counts >> 6) & 0x1f;
    unsigned from = toNew ? kVDOldLayoutSize : kVDNewLayoutSize, to = toNew ? kVDNewLayoutSize : kVDOldLayoutSize;
    if (layouts == 0 || attrsOff != kVDHeaderSize + layouts * from) return data;  // empty, or already in target format
    size_t tail = size - attrsOff;  // attribute records (and anything after them) are copied unchanged
    size_t outSize = off + kVDHeaderSize + layouts * to + tail;
    uint8_t *out = calloc(1, outSize);
    memcpy(out, buf, off + kVDHeaderSize);  // prefix and header
    uint8_t *dst = out + off;
    for (unsigned i = 0; i < layouts; i++) {
        const uint8_t *l = src + kVDHeaderSize + i * from;
        uint8_t *o = dst + kVDHeaderSize + i * to;
        memcpy(o, l, 8);  // bufferIndex|stepFunction, stepRate
        if (toNew) *(uint64_t *)(o + 8) = *(const uint32_t *)(l + 8);
        else *(uint32_t *)(o + 8) = (uint32_t)*(const uint64_t *)(l + 8);
    }
    memcpy(dst + kVDHeaderSize + layouts * to, src + attrsOff, tail);
    *(uint16_t *)(dst + 0) = (uint16_t)(outSize - off);
    *(uint16_t *)(dst + 6) = (uint16_t)(kVDHeaderSize + layouts * to);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] vertex descriptor (%u layouts, at +%zu) converted to %s format\n", layouts, off, toNew ? "14.2" : "13.2");
    return dispatch_data_create(out, outSize, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
}

// Only requests for the 14.2-era compiler need the new format; the Intel 3802 compiler expects MetalOld's.
static BOOL compilerUsesNewVertexDescriptorFormat(id compiler) {
    Ivar ivar = class_getInstanceVariable(object_getClass(compiler), "_pluginPath");
    NSString *plugin = ivar ? object_getIvar(compiler, ivar) : nil;
    return [plugin isKindOfClass:[NSString class]] && [plugin containsString:@"AMDShared.bundle"];
}

typedef id (*VertexStageIMP)(id, SEL, void *, id, id, dispatch_data_t, id, id, NSUInteger, void *, id, id, id, void *, id);
static VertexStageIMP origVertexStage;

static id vertexStage(id self, SEL _cmd, void *fragment, id fragmentVariant, id vertexFunction, dispatch_data_t vertexDesc, id descriptor,
                      id archive, NSUInteger options, void *reflection, id stats, id fragmentTimeData, id archiverId, void *error, id handler) {
    if (getenv("MTLSHIM_VERBOSE")) {
        const uint8_t *b = NULL; size_t s = 0;
        dispatch_data_t m = vertexDesc ? dispatch_data_create_map(vertexDesc, (const void **)&b, &s) : nil;
        shimLog("[mtlshim] vertex stage: new-format compiler=%d descriptor=%s %zu bytes, header %02x%02x %02x%02x %02x%02x %02x%02x\n",
                compilerUsesNewVertexDescriptorFormat(self), vertexDesc ? object_getClassName(vertexDesc) : "nil", s,
                s > 7 ? b[0] : 0, s > 7 ? b[1] : 0, s > 7 ? b[2] : 0, s > 7 ? b[3] : 0, s > 7 ? b[4] : 0, s > 7 ? b[5] : 0, s > 7 ? b[6] : 0, s > 7 ? b[7] : 0);
        if (getenv("MTLSHIM_DUMPVD")) { shimLog("[mtlshim]   bytes:"); for (size_t i = 0; i < s; i++) fprintf(stderr, "%s%02x", i % 4 ? "" : " ", b[i]); fprintf(stderr, "\n"); }
        (void)m;
    }
    if (compilerUsesNewVertexDescriptorFormat(self)) vertexDesc = convertVertexDescriptor(vertexDesc, YES);
    return origVertexStage(self, _cmd, fragment, fragmentVariant, vertexFunction, vertexDesc, descriptor, archive, options, reflection, stats,
                           fragmentTimeData, archiverId, error, handler);
}

typedef id (*InitVFIMP)(id, SEL, dispatch_data_t, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger);
typedef id (*InitOMFIMP)(id, SEL, dispatch_data_t, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger);
typedef id (*InitTileIMP)(id, SEL, dispatch_data_t, NSUInteger, id, NSUInteger, NSUInteger);
typedef id (*InitComputeIMP)(id, SEL, dispatch_data_t, id, NSUInteger, NSUInteger);
typedef id (*InitComputeStageIMP)(id, SEL, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger);
typedef id (*InitFunctionIMP)(id, SEL, id, dispatch_data_t, NSUInteger, NSUInteger);

static InitVFIMP origVF;
static InitOMFIMP origOMF;
static InitTileIMP origTile;
static InitComputeIMP origCompute;
static InitComputeStageIMP origComputeStage;
static InitFunctionIMP origFunction;

static id initVF(id self, SEL _cmd, dispatch_data_t vertex, dispatch_data_t fragment, dispatch_data_t vertexDesc, id device, NSUInteger options, NSUInteger flags) {
    // MetalOld's own reflection reader still needs the 13.2 vertex descriptor layout.
    return origVF(self, _cmd, unwrapReflection(vertex), unwrapReflection(fragment), convertVertexDescriptor(vertexDesc, NO), device, options, flags);
}

static id initOMF(id self, SEL _cmd, dispatch_data_t object, dispatch_data_t mesh, dispatch_data_t fragment, id device, NSUInteger options, NSUInteger flags) {
    return origOMF(self, _cmd, unwrapReflection(object), unwrapReflection(mesh), unwrapReflection(fragment), device, options, flags);
}

static id initTile(id self, SEL _cmd, dispatch_data_t tile, NSUInteger functionType, id device, NSUInteger options, NSUInteger flags) {
    return origTile(self, _cmd, unwrapReflection(tile), functionType, device, options, flags);
}

static id initCompute(id self, SEL _cmd, dispatch_data_t data, id device, NSUInteger options, NSUInteger flags) {
    return origCompute(self, _cmd, unwrapReflection(data), device, options, flags);
}

static id initComputeStage(id self, SEL _cmd, dispatch_data_t data, dispatch_data_t stageDesc, id device, NSUInteger options, NSUInteger flags) {
    return origComputeStage(self, _cmd, unwrapReflection(data), stageDesc, device, options, flags);
}

static id initFunction(id self, SEL _cmd, id device, dispatch_data_t data, NSUInteger functionType, NSUInteger options) {
    return origFunction(self, _cmd, device, unwrapReflection(data), functionType, options);
}

// MetalOld predates MTLTextureUsageShaderAtomic (macOS 14) and rejects it in validation. The legacy drivers can't
// back MSL texture atomics either, so drop the bit (the texture keeps read/write access) instead of aborting.
typedef BOOL (*ValidateTextureIMP)(id, SEL, id);
static ValidateTextureIMP origValidateTexture;

static BOOL validateTexture(id self, SEL _cmd, id device) {
    MTLTextureDescriptor *desc = self;
    if (desc.usage & MTLTextureUsageShaderAtomic) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] dropped MTLTextureUsageShaderAtomic (usage 0x%lx)\n", (unsigned long)desc.usage);
        desc.usage = (desc.usage & ~MTLTextureUsageShaderAtomic) | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    }
    return origValidateTexture(self, _cmd, device);
}

// 8. Properties and encoder calls from the macOS 13.3-15 SDKs that MetalOld (13.2) lacks; apps built for macOS 15 set
// them unconditionally (Chromium's ANGLE: -[MTLCompileOptions setMathMode:], an "unrecognized selector" abort).
// Stored values are kept as associated objects; mathMode also drives MetalOld's fastMathEnabled (Fast = on; Safe and
// Relaxed = off, the precise side), and the attributeStride encoder calls use the static vertex layout stride.
static char kMathModeKey;

static void setMathMode(id self, SEL _cmd, NSUInteger mode) {
    objc_setAssociatedObject(self, &kMathModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setFastMathEnabled:), mode == 2 /* MTLMathModeFast */);
}

static NSUInteger mathMode(id self, SEL _cmd) {
    NSNumber *mode = objc_getAssociatedObject(self, &kMathModeKey);
    if (mode) return mode.unsignedIntegerValue;
    return ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(fastMathEnabled)) ? 2 : 0;
}

// A stored NSUInteger/BOOL property: getter and setter blocks sharing one key.
static void addStoredProperty(Class c, const char *getter, NSUInteger defaultValue, BOOL isBool) {
    if (!c) return;
    char setter[128];
    snprintf(setter, sizeof setter, "set%c%s:", toupper(getter[0]), getter + 1);
    const void *key = sel_registerName(getter);
    IMP get = imp_implementationWithBlock(^NSUInteger(id self) {
        NSNumber *v = objc_getAssociatedObject(self, key);
        return v ? v.unsignedIntegerValue : defaultValue;
    });
    IMP set = imp_implementationWithBlock(^(id self, NSUInteger value) {
        objc_setAssociatedObject(self, key, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    BOOL a = class_addMethod(c, sel_registerName(getter), get, isBool ? "B@:" : "Q@:");
    BOOL b = class_addMethod(c, sel_registerName(setter), set, isBool ? "v@:B" : "v@:Q");
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %s %s: %s\n", class_getName(c), getter, a || b ? "added" : "already present");
}

static NSUInteger shaderValidationDefault(id self, SEL _cmd) { return 0; /* MTLShaderValidationDefault */ }

static void setVertexBufferStride(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setVertexBuffer:offset:atIndex:), buffer, offset, index);
}
static void setVertexBufferOffsetStride(id self, SEL _cmd, NSUInteger offset, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setVertexBufferOffset:atIndex:), offset, index);
}
static void setVertexBuffersStrides(id self, SEL _cmd, const id *buffers, const NSUInteger *offsets, const NSUInteger *strides, NSRange range) {
    ((void (*)(id, SEL, const id *, const NSUInteger *, NSRange))objc_msgSend)(self, @selector(setVertexBuffers:offsets:withRange:), buffers, offsets, range);
}
static void setVertexBytesStride(id self, SEL _cmd, const void *bytes, NSUInteger length, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setVertexBytes:length:atIndex:), bytes, length, index);
}
static void setBufferStride(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setBuffer:offset:atIndex:), buffer, offset, index);
}
static void setBufferOffsetStride(id self, SEL _cmd, NSUInteger offset, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setBufferOffset:atIndex:), offset, index);
}
static void setBuffersStrides(id self, SEL _cmd, const id *buffers, const NSUInteger *offsets, const NSUInteger *strides, NSRange range) {
    ((void (*)(id, SEL, const id *, const NSUInteger *, NSRange))objc_msgSend)(self, @selector(setBuffers:offsets:withRange:), buffers, offsets, range);
}
static void setBytesStride(id self, SEL _cmd, const void *bytes, NSUInteger length, NSUInteger stride, NSUInteger index) {
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))objc_msgSend)(self, @selector(setBytes:length:atIndex:), bytes, length, index);
}

// MSL language version: the shader front end behind MetalOld accepts up to metal3.1, so a 3.2 request ("-std=metal3.2",
// what apps built for macOS 15 ask for, e.g. Firefox's wgpu) fails every compile. Compile those as 3.1 (3.2 adds
// features on top of 3.1; shaders that use them get a normal compile error), and make 3.1 the default, as the newest
// version this stack has (MetalOld's own default is 3.0, which hides 3.1 features such as texture atomics).
enum { kNewestLanguageVersion = 0x30001 /* MTLLanguageVersion3_1 */ };
typedef void (*SetLanguageVersionIMP)(id, SEL, NSUInteger);
static SetLanguageVersionIMP origSetLanguageVersion;
typedef id (*InitIMP)(id, SEL);
static InitIMP origCompileOptionsInit;

static const void *kNewerVersionRequested = &kNewerVersionRequested;

static void setLanguageVersion(id self, SEL _cmd, NSUInteger version) {
    BOOL newer = version > kNewestLanguageVersion;
    if (newer) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MSL %lu.%lu requested, compiling as 3.1\n", (unsigned long)(version >> 16), (unsigned long)(version & 0xffff));
        version = kNewestLanguageVersion;
    }
    objc_setAssociatedObject(self, kNewerVersionRequested, newer ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    origSetLanguageVersion(self, _cmd, version);
}

// The 3.2 feature translators generate most: memory coherence (MSL 4.8). Metal implements it for Apple silicon only, so
// on these GPUs 3.1 code means the same; rewrite it the way SPIRV-Cross (MoltenVK) writes Coherent for MSL < 3.2:
// `coherent device` / `coherent(device)` -> `volatile`, `coherent(threadgroup)` (the default) and the texture argument
// `memory_coherence_device` / `_threadgroup` dropped.
static NSString *downgradeSource(NSString *source, id options) {
    if (!source || !options || !objc_getAssociatedObject(options, kNewerVersionRequested)) return source;
    if ([source rangeOfString:@"coheren"].location == NSNotFound) return source;
    static NSArray<NSArray *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *patterns = @[
            @[@"\\s*,\\s*(?:memory_coherence\\s*::\\s*)?memory_coherence_(?:device|threadgroup)(?=\\s*>)", @""],
            @[@"\\bcoherent\\s*\\(\\s*device\\s*\\)", @"volatile"],
            @[@"\\bcoherent\\s*\\(\\s*threadgroup\\s*\\)\\s*", @""],
            @[@"\\bcoherent(?=\\s+(?:device|threadgroup)\\b)", @"volatile"],
        ];
        NSMutableArray *compiled = [NSMutableArray array];
        for (NSArray *p in patterns)
            [compiled addObject:@[[NSRegularExpression regularExpressionWithPattern:p[0] options:0 error:nil], p[1]]];
        rules = compiled;
    });
    NSString *out = source;
    for (NSArray *rule in rules)
        out = [rule[0] stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rule[1]];
    if (getenv("MTLSHIM_VERBOSE") && ![out isEqualToString:source]) shimLog("[mtlshim] MSL 3.2 coherence qualifiers rewritten for 3.1\n");
    return out;
}

// new... methods return a +1 object; ARC must know that for the hooks and the originals they call.
typedef id (*NewLibrarySyncIMP)(id, SEL, NSString *, id, NSError **) __attribute__((ns_returns_retained));
typedef void (*NewLibraryAsyncIMP)(id, SEL, NSString *, id, id);
static NewLibrarySyncIMP origNewLibrarySync;
static NewLibraryAsyncIMP origNewLibraryAsync;
typedef id (*NewLibraryDataIMP)(id, SEL, dispatch_data_t, NSError **) __attribute__((ns_returns_retained));  // item 13
static NewLibraryDataIMP origNewLibraryData;
static id newLibraryData(id self, SEL _cmd, dispatch_data_t data, NSError **error) __attribute__((ns_returns_retained));

// MTLSHIM_VERBOSE: log failed source compiles, and save the source to the temporary directory (sandboxed processes).
static void reportCompileFailure(NSString *source, NSError *error) {
    if (!getenv("MTLSHIM_VERBOSE") || !error) return;
    static int n;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"mtlshim-failed-%d-%d.metal", getpid(), __sync_fetch_and_add(&n, 1)]];
    [[NSString stringWithFormat:@"/* %@ */\n%@", error.localizedDescription, source] writeToFile:path atomically:NO
                                                                                         encoding:NSUTF8StringEncoding error:nil];
    shimLog("[mtlshim] compile failed (%s): %.700s\n", path.UTF8String, error.localizedDescription.UTF8String ?: "?");
}

static id newLibrarySync(id self, SEL _cmd, NSString *source, id options, NSError **error) __attribute__((ns_returns_retained));
static id newLibrarySync(id self, SEL _cmd, NSString *source, id options, NSError **error) {
    NSString *compiled = downgradeSource(source, options);
    NSError *failure = nil;
    id library = origNewLibrarySync(self, _cmd, compiled, options, &failure);
    if (!library) reportCompileFailure(compiled, failure);
    if (error) *error = failure;
    return library;
}

static void newLibraryAsync(id self, SEL _cmd, NSString *source, id options, id handler) {
    NSString *compiled = downgradeSource(source, options);
    void (^done)(id, NSError *) = handler;
    origNewLibraryAsync(self, _cmd, compiled, options, ^(id library, NSError *error) {
        if (!library) reportCompileFailure(compiled, error);
        if (done) done(library, error);
    });
}

static id compileOptionsInit(id self, SEL _cmd) {
    self = origCompileOptionsInit(self, _cmd);
    if (self && ((NSUInteger (*)(id, SEL))objc_msgSend)(self, @selector(languageVersion)) < kNewestLanguageVersion)
        origSetLanguageVersion(self, @selector(setLanguageVersion:), kNewestLanguageVersion);
    return self;
}

typedef struct { const char *sel; IMP imp; const char *types; } MethodEntry;

static void addMethods(Class c, const char *what, const MethodEntry *methods, size_t count) {
    if (!c) return;
    for (size_t i = 0; i < count; i++) {
        BOOL added = class_addMethod(c, sel_registerName(methods[i].sel), methods[i].imp, methods[i].types);
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %s %s: %s\n", what, methods[i].sel, added ? "added" : "already present");
    }
}

// Object/mesh stage bindings (macOS 13): MetalOld's _MTLCommandEncoder has them as stubs that throw (unrecognized
// selector) for drivers to override, and the 12.5 AMD and 13.2 Intel drivers don't. These GPUs can't make mesh
// pipelines (no Metal 3), so a binding call has nothing to bind to; callers that set immediates for every stage (wgpu)
// would crash. Draw calls keep the throwing stub.
static void ignoreBinding(id self, SEL _cmd) {}
static BOOL definesMethod(const char *cls, const char *sel);
static IMP swizzle(const char *cls, const char *sel, IMP imp);

static void ignoreMeshStageBindings(void) {
    static const char *bindings[] = {
        "setObjectBytes:length:atIndex:", "setObjectBuffer:offset:atIndex:", "setObjectBufferOffset:atIndex:",
        "setObjectBuffers:offsets:withRange:", "setObjectTexture:atIndex:", "setObjectTextures:withRange:",
        "setObjectSamplerState:atIndex:", "setObjectSamplerStates:withRange:",
        "setObjectSamplerState:lodMinClamp:lodMaxClamp:atIndex:", "setObjectSamplerStates:lodMinClamps:lodMaxClamps:withRange:",
        "setObjectThreadgroupMemoryLength:atIndex:",
        "setMeshBytes:length:atIndex:", "setMeshBuffer:offset:atIndex:", "setMeshBufferOffset:atIndex:",
        "setMeshBuffers:offsets:withRange:", "setMeshTexture:atIndex:", "setMeshTextures:withRange:",
        "setMeshSamplerState:atIndex:", "setMeshSamplerStates:withRange:",
        "setMeshSamplerState:lodMinClamp:lodMaxClamp:atIndex:", "setMeshSamplerStates:lodMinClamps:lodMaxClamps:withRange:",
    };
    for (size_t i = 0; i < sizeof bindings / sizeof *bindings; i++)
        if (definesMethod("_MTLCommandEncoder", bindings[i])) swizzle("_MTLCommandEncoder", bindings[i], (IMP)ignoreBinding);
}

static void addNewerSDKAPI(void) {
    Class options = objc_getClass("MTLCompileOptionsInternal");
    const MethodEntry math[] = {
        {"setMathMode:", (IMP)setMathMode, "v@:Q"}, {"mathMode", (IMP)mathMode, "Q@:"},
    };
    addMethods(options, "MTLCompileOptions", math, 2);
    addStoredProperty(options, "mathFloatingPointFunctions", 0, NO);
    addStoredProperty(options, "allowReferencingUndefinedSymbols", 0, YES);
    addStoredProperty(options, "compileSymbolVisibility", 0, NO);
    addStoredProperty(options, "maxTotalThreadsPerThreadgroup", 0, NO);
    addStoredProperty(options, "enableLogging", 0, YES);
    const char *pipelineDescriptors[] = {"MTLRenderPipelineDescriptorInternal", "MTLComputePipelineDescriptorInternal",
                                         "MTLTileRenderPipelineDescriptorInternal", "MTLMeshRenderPipelineDescriptor"};
    for (size_t i = 0; i < sizeof pipelineDescriptors / sizeof *pipelineDescriptors; i++) {
        addStoredProperty(objc_getClass(pipelineDescriptors[i]), "shaderValidation", 0, NO);
        // Sequoia's MetalTools (MTL_DEBUG_LAYER=1, Xcode API validation) reads the descriptor's internal state too.
        addStoredProperty(objc_getClass(pipelineDescriptors[i]), "shaderValidationState", 0, NO);
    }
    Class icb = objc_getClass("MTLIndirectCommandBufferDescriptor");
    addStoredProperty(icb, "maxKernelThreadgroupMemoryBindCount", 0, NO);
    addStoredProperty(icb, "maxObjectThreadgroupMemoryBindCount", 0, NO);
    addStoredProperty(icb, "supportDynamicAttributeStride", 0, YES);
    const MethodEntry validation[] = {{"shaderValidation", (IMP)shaderValidationDefault, "Q@:"}};
    addMethods(objc_getClass("_MTLRenderPipelineState"), "_MTLRenderPipelineState", validation, 1);
    addMethods(objc_getClass("_MTLComputePipelineState"), "_MTLComputePipelineState", validation, 1);
    const MethodEntry render[] = {
        {"setVertexBuffer:offset:attributeStride:atIndex:", (IMP)setVertexBufferStride, "v@:@QQQ"},
        {"setVertexBufferOffset:attributeStride:atIndex:", (IMP)setVertexBufferOffsetStride, "v@:QQQ"},
        {"setVertexBuffers:offsets:attributeStrides:withRange:", (IMP)setVertexBuffersStrides, "v@:^@^Q^Q{_NSRange=QQ}"},
        {"setVertexBytes:length:attributeStride:atIndex:", (IMP)setVertexBytesStride, "v@:^vQQQ"},
    };
    const MethodEntry compute[] = {
        {"setBuffer:offset:attributeStride:atIndex:", (IMP)setBufferStride, "v@:@QQQ"},
        {"setBufferOffset:attributeStride:atIndex:", (IMP)setBufferOffsetStride, "v@:QQQ"},
        {"setBuffers:offsets:attributeStrides:withRange:", (IMP)setBuffersStrides, "v@:^@^Q^Q{_NSRange=QQ}"},
        {"setBytes:length:attributeStride:atIndex:", (IMP)setBytesStride, "v@:^vQQQ"},
    };
    // The driver encoders (BronzeMtl*, MTLIGAccel*) derive from these MetalOld classes.
    addMethods(objc_getClass("MTLIOAccelRenderCommandEncoder"), "MTLIOAccelRenderCommandEncoder", render, 4);
    addMethods(objc_getClass("MTLIOAccelComputeCommandEncoder"), "MTLIOAccelComputeCommandEncoder", compute, 4);
}

static BOOL definesMethod(const char *cls, const char *sel) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(objc_getClass(cls), &count);
    BOOL found = NO;
    for (unsigned i = 0; i < count && !found; i++) found = method_getName(methods[i]) == sel_registerName(sel);
    free(methods);
    return found;
}

static IMP swizzle(const char *cls, const char *sel, IMP imp) {
    Method m = class_getInstanceMethod(objc_getClass(cls), sel_registerName(sel));
    if (!m) return NULL;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] hooked -[%s %s]\n", cls, sel);
    return method_setImplementation(m, imp);
}

// 14. OCLP's Metal wrapper replaces -[_MTLFunction newArgumentEncoderWithBufferIndex:reflection:functionReflection:] and
// -[_MTLDevice newArgumentEncoderWithBufferBinding:] with stubs that return nil in every process whose path contains
// "Safari" (Safari and its WebKit XPC services). MetalOld aborts the process (_MTLReportFailure, "bufferIndex N does not
// identify an argument buffer") when asked for an encoder for an index that is not a buffer argument of the function
// (so does macOS 12.7's own Metal on a MacBookPro11,4); the stubs avoid that, but they also leave WebKit's ANGLE without
// the argument encoder it puts every WebGL 2 uniform block in, so each draw with a uniform block fails. MetalOld's
// implementations are saved here (this library's initializer runs before the wrapper's, which loads it) and put back
// behind a check that returns nil instead of aborting, once more when the first device is created (after the wrapper).
typedef id (*FunctionEncoderIMP)(id, SEL, NSUInteger, id *, id) __attribute__((ns_returns_retained));
typedef id (*BindingEncoderIMP)(id, SEL, id) __attribute__((ns_returns_retained));
static FunctionEncoderIMP origFunctionEncoder;
static BindingEncoderIMP origBindingEncoder;
static const char *const kFunctionEncoderSel = "newArgumentEncoderWithBufferIndex:reflection:functionReflection:";
static const char *const kBindingEncoderSel = "newArgumentEncoderWithBufferBinding:";

static id functionEncoder(id self, SEL _cmd, NSUInteger index, id *reflection, id functionReflection) __attribute__((ns_returns_retained));
static id functionEncoder(id self, SEL _cmd, NSUInteger index, id *reflection, id functionReflection) {
    for (id<MTLBinding> argument in [functionReflection arguments])  // MetalOld's MTLArguments
        if (argument.type == MTLBindingTypeBuffer && argument.index == index)
            return origFunctionEncoder(self, _cmd, index, reflection, functionReflection);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] no argument encoder: buffer %lu is not an argument of %s\n", (unsigned long)index,
                                           [[self name] UTF8String] ?: "?");
    return nil;
}

static id bindingEncoder(id self, SEL _cmd, id binding) __attribute__((ns_returns_retained));
static id bindingEncoder(id self, SEL _cmd, id binding) {
    return binding ? origBindingEncoder(self, _cmd, binding) : nil;
}

static BOOL fromMetalOld(IMP imp) {
    Dl_info info;
    return imp && dladdr((const void *)imp, &info) && info.dli_fname && strstr(info.dli_fname, "/MetalOld.dylib");
}

// Saves MetalOld's implementations (first call) and installs the checked ones where something else replaced them.
static void restoreArgumentEncoders(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    const struct { const char *cls, *sel; IMP imp; IMP *orig; } hooks[] = {
        {"_MTLFunction", kFunctionEncoderSel, (IMP)functionEncoder, (IMP *)&origFunctionEncoder},
        {"_MTLDevice", kBindingEncoderSel, (IMP)bindingEncoder, (IMP *)&origBindingEncoder},
    };
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        Method m = class_getInstanceMethod(objc_getClass(hooks[i].cls), sel_registerName(hooks[i].sel));
        IMP current = m ? method_getImplementation(m) : NULL;
        if (!*hooks[i].orig && fromMetalOld(current)) *hooks[i].orig = current;
        if (!*hooks[i].orig || current == hooks[i].imp) continue;
        if (getenv("MTLSHIM_VERBOSE") && !fromMetalOld(current))
            shimLog("[mtlshim] -[%s %s] was replaced (wrapper stub); MetalOld's put back\n", hooks[i].cls, hooks[i].sel);
        swizzle(hooks[i].cls, hooks[i].sel, hooks[i].imp);
    }
    os_unfair_lock_unlock(&lock);
}

static BOOL patched;

// MetalOld keys its shader cache for AMD/Intel GPUs (target cpuType 0x1000013-15) by an AIRNT "function id": the
// bitcode hash plus hashes of the pipeline script: its own framework hash (all zero for compute), GPUCompiler 31001's
// libGPUCompilerUtils hash (weak-linked and absent on Sequoia: zero) and the driver's vendor plugin id (the 12.x drivers
// have none: zero). Every compute pipeline of a function then shares one cache entry whatever its descriptor says: Blender's recompile
// with maxTotalThreadsPerThreadgroup = 1024 got the cached 768-thread variant back and its 1024-thread dispatches hung
// the GPU. With MTL_USE_AIRNT_BA=0 MetalOld keys by the driver's own function key, as the 12.x Metal framework did.
static void useDriverPipelineKeys(void) {
    setenv("MTL_USE_AIRNT_BA", "0", 0);  // read once, at the first compile; an explicit setting is kept
}

static void patchDeviceBase(void) {
    Class base = objc_getClass("_MTLDevice");
    if (!base || patched) return;
    patched = YES;
    const char *image = class_getImageName(base);
    if (!image || !strstr(image, "MetalOld")) return;  // native Metal: nothing to fix
    useDriverPipelineKeys();
    origVF = (InitVFIMP)swizzle("MTLRenderPipelineReflectionInternal", "initWithVertexData:fragmentData:serializedVertexDescriptor:device:options:flags:", (IMP)initVF);
    origOMF = (InitOMFIMP)swizzle("MTLRenderPipelineReflectionInternal", "initWithObjectData:meshData:fragmentData:device:options:flags:", (IMP)initOMF);
    origTile = (InitTileIMP)swizzle("MTLRenderPipelineReflectionInternal", "initWithTileData:functionType:device:options:flags:", (IMP)initTile);
    origCompute = (InitComputeIMP)swizzle("MTLComputePipelineReflectionInternal", "initWithSerializedData:device:options:flags:", (IMP)initCompute);
    origComputeStage = (InitComputeStageIMP)swizzle("MTLComputePipelineReflectionInternal", "initWithSerializedData:serializedStageInputDescriptor:device:options:flags:", (IMP)initComputeStage);
    origFunction = (InitFunctionIMP)swizzle("MTLFunctionReflectionInternal", "initWithDevice:reflectionData:functionType:options:", (IMP)initFunction);
    origValidateTexture = (ValidateTextureIMP)swizzle("MTLTextureDescriptorInternal", "validateWithDevice:", (IMP)validateTexture);
    origVertexStage = (VertexStageIMP)swizzle("MTLCompiler",
        "createVertexStageAndLinkPipelineWithFragment:fragmentVariant:vertexFunction:serializedVertexDescriptor:descriptor:"
        "destinationArchive:options:reflection:compileStatistics:fragmentCompileTimeData:pipelineArchiverId:error:completionHandler:",
        (IMP)vertexStage);
    struct { const char *sel; IMP imp; const char *types; } methods[] = {
        {"setShouldMaximizeConcurrentCompilation:", (IMP)setShouldMaximize, "v@:B"},
        {"shouldMaximizeConcurrentCompilation", (IMP)shouldMaximize, "B@:"},
        {"maximumConcurrentCompilationTaskCount", (IMP)maxConcurrentTasks, "Q@:"},
        {"newLogStateWithDescriptor:error:", (IMP)unsupported, "@@:@^@"},
        {"newResidencySetWithDescriptor:error:", (IMP)unsupported, "@@:@^@"},
        {"supportsDynamicAttributeStride", (IMP)no, "B@:"},
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        BOOL added = class_addMethod(base, sel_registerName(methods[i].sel), methods[i].imp, methods[i].types);
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] _MTLDevice %s: %s\n", methods[i].sel, added ? "added" : "already present");
    }
    addNewerSDKAPI();
    ignoreMeshStageBindings();
    restoreArgumentEncoders();
    // Only methods the class defines itself: swizzling an inherited -init would change -[NSObject init].
    if (definesMethod("MTLCompileOptionsInternal", "setLanguageVersion:") && definesMethod("MTLCompileOptionsInternal", "init")) {
        origSetLanguageVersion = (SetLanguageVersionIMP)swizzle("MTLCompileOptionsInternal", "setLanguageVersion:", (IMP)setLanguageVersion);
        origCompileOptionsInit = (InitIMP)swizzle("MTLCompileOptionsInternal", "init", (IMP)compileOptionsInit);
        if (definesMethod("_MTLDevice", "newLibraryWithData:error:"))
            origNewLibraryData = (NewLibraryDataIMP)swizzle("_MTLDevice", "newLibraryWithData:error:", (IMP)newLibraryData);
        if (definesMethod("_MTLDevice", "newLibraryWithSource:options:error:"))
            origNewLibrarySync = (NewLibrarySyncIMP)swizzle("_MTLDevice", "newLibraryWithSource:options:error:", (IMP)newLibrarySync);
        if (definesMethod("_MTLDevice", "newLibraryWithSource:options:completionHandler:"))
            origNewLibraryAsync = (NewLibraryAsyncIMP)swizzle("_MTLDevice", "newLibraryWithSource:options:completionHandler:", (IMP)newLibraryAsync);
    }
}

// 13. Safari's ANGLE (WebKit) ships its internal shaders (blits, clears, index conversion, mipmaps) as a metallib built
// with the macOS 27 SDK, AIR target air64_v27-apple-macosx15.4.0. This stack loads it, but specializing or linking its
// functions fails ("incompatible module ... not compatible with the target (air64-apple-macosx14.2.0)"), so every WebGL
// context that needs one (alpha:false, multisample resolves, canvas copies) fails, and WebKit's GPU process hangs.
// Chromium's ANGLE compiles the same shaders from source at runtime. When libANGLE-shared.dylib loads that metallib,
// compile ANGLE's internal-shader source (ANGLEInternalShaders.h, generated by make_angle_shaders.py from WebKit's
// mtl_internal_shaders_autogen.metal) and return that library if it has the same functions with the same function
// constants; otherwise the prebuilt library is returned as before.
#include "ANGLEInternalShaders.h"
static BOOL fromChromium(const void *returnAddress);

static BOOL isTooNewANGLELibrary(dispatch_data_t data) {
    const void *bytes = NULL;
    size_t size = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &size);
    BOOL found = NO;
    if (memmem(bytes, size, "mtl_internal_shaders_autogen", 28))
        for (const char *p = bytes, *end = p + size; !found && (p = memmem(p, end - p, "air64_v", 7)); p += 7)
            found = p + 9 <= end && isdigit(p[7]) && isdigit(p[8]) && (p[7] - '0') * 10 + (p[8] - '0') >= 27;
    (void)map;
    return found;
}

static NSString *functionSignature(id<MTLFunction> function) {
    NSMutableArray *constants = [NSMutableArray array];
    for (NSString *name in [function.functionConstantsDictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        MTLFunctionConstant *c = function.functionConstantsDictionary[name];
        [constants addObject:[NSString stringWithFormat:@"%@:%lu@%lu", name, (unsigned long)c.type, (unsigned long)c.index]];
    }
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)function.functionType, [constants componentsJoinedByString:@" "]];
}

static BOOL sameFunctions(id<MTLLibrary> a, id<MTLLibrary> b) {
    if (![[NSSet setWithArray:a.functionNames] isEqualToSet:[NSSet setWithArray:b.functionNames]]) return NO;
    for (NSString *name in a.functionNames)
        if (![functionSignature([a newFunctionWithName:name]) isEqualToString:functionSignature([b newFunctionWithName:name])]) return NO;
    return YES;
}

static id newLibraryData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
    id library = origNewLibraryData(self, _cmd, data, error);
    if (!library || !fromChromium(__builtin_return_address(0)) || !isTooNewANGLELibrary(data)) return library;
    NSError *failure = nil;
    id<MTLLibrary> compiled = [self newLibraryWithSource:@(kANGLEInternalShaders) options:[MTLCompileOptions new] error:&failure];
    BOOL usable = compiled && sameFunctions(library, compiled);
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] ANGLE internal shaders: prebuilt library too new; source-compiled one %s%s\n",
                usable ? "used" : compiled ? "differs, kept the prebuilt one" : "failed: ",
                compiled ? "" : failure.localizedDescription.UTF8String ?: "?");
    return usable ? compiled : library;
}

// 10. Metal devices are pinned (one extra retain the first time a process sees each). MetalOld's devices can be freed
// when a client over-releases one, which Apple's Metal tolerates; Chromium's GPU process does (ANGLE's default-device
// check), and its next MTLCopyAllDevices then copies MetalOld's device list with the freed device in it (crash).
// 11. ANGLE in Chromium (Chrome, Chromium, Edge, Electron apps, ...) and WebKit (Safari): ANGLE, the only GL backend
// current Chromium has on macOS and the one Safari's WebGL uses,
// disables its Metal renderer on Macs older than 2016 by IOPlatformExpertDevice "model" (MacBookPro < 13,1, ...), so
// these Macs get no GPU acceleration at all; and ANGLE can't create an OpenGL ES 3 context on a Metal family-1 GPU
// (Haswell / Ivy Bridge), which automatic graphics switching often makes the active one. For calls from a Chromium
// framework image ("<Product> Framework") or WebKit's ANGLE: report a post-2015 model, and list only family-2 GPUs (the
// AMD dGPU) to ANGLE, Skia Graphite and Dawn. Everything else in the process sees the real model and all GPUs.
// 12. sRGB mipmaps on the 12.5 AMD driver: -[BronzeMtlBlitCmdEncoder generateMipmapsForTexture:] averages the encoded
// bytes of RGBA8/BGRA8Unorm_sRGB textures (its stretch blit treats them as linear), so every level below 0 is off
// (WebGL 2 conformance tex-srgb-mipmap). Keep the driver's blit and, when that encoder ends, redo levels 1..n of those
// textures with one render pass per level and slice: sampling the sRGB source decodes, the linear filter averages the
// 2x2 texels, the sRGB render target encodes. Textures without MTLTextureUsageRenderTarget, and 3D ones, are unchanged.
static const void *kPendingSRGBMips = &kPendingSRGBMips;
typedef void (*GenerateMipmapsIMP)(id, SEL, id);
typedef void (*EndEncodingIMP)(id, SEL);
static GenerateMipmapsIMP origGenerateMipmaps;
static EndEncodingIMP origBlitEndEncoding;

static BOOL needsSRGBMipFix(id<MTLTexture> texture) {
    MTLPixelFormat f = texture.pixelFormat;
    MTLTextureType t = texture.textureType;
    return (f == MTLPixelFormatRGBA8Unorm_sRGB || f == MTLPixelFormatBGRA8Unorm_sRGB) && texture.mipmapLevelCount > 1 &&
           (texture.usage & MTLTextureUsageRenderTarget) &&
           (t == MTLTextureType2D || t == MTLTextureType2DArray || t == MTLTextureTypeCube || t == MTLTextureTypeCubeArray);
}

static void generateMipmaps(id self, SEL _cmd, id<MTLTexture> texture) {
    origGenerateMipmaps(self, _cmd, texture);
    if (!needsSRGBMipFix(texture)) return;
    NSMutableArray *pending = objc_getAssociatedObject(self, kPendingSRGBMips);
    if (!pending) {
        pending = [NSMutableArray array];
        objc_setAssociatedObject(self, kPendingSRGBMips, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pending addObject:texture];
}

static id<MTLRenderPipelineState> srgbMipPipeline(id<MTLDevice> device, MTLPixelFormat format) {
    static NSMutableDictionary *pipelines;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%p-%lu", device, (unsigned long)format];
    os_unfair_lock_lock(&lock);
    id<MTLRenderPipelineState> pipeline = pipelines[key];
    os_unfair_lock_unlock(&lock);
    if (pipeline) return pipeline;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 position [[position]]; float2 uv; };\n"
        "vertex V srgbMipVertex(uint id [[vertex_id]]) {\n"
        "    float2 p = float2((id << 1) & 2, id & 2);\n"
        "    return { float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p };\n"
        "}\n"
        "fragment float4 srgbMipFragment(V in [[stage_in]], texture2d<float> source [[texture(0)]]) {\n"
        "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
        "    return source.sample(s, in.uv);\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"srgbMipVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"srgbMipFragment"];
    descriptor.colorAttachments[0].pixelFormat = format;
    pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline) {
        shimLog("[mtlshim] sRGB mipmap pipeline: %s\n", error.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    os_unfair_lock_lock(&lock);
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    pipelines[key] = pipeline;
    os_unfair_lock_unlock(&lock);
    return pipeline;
}

static void regenerateSRGBMips(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture) {
    id<MTLRenderPipelineState> pipeline = srgbMipPipeline(texture.device, texture.pixelFormat);
    if (!pipeline) return;
    BOOL cube = texture.textureType == MTLTextureTypeCube || texture.textureType == MTLTextureTypeCubeArray;
    NSUInteger slices = texture.arrayLength * (cube ? 6 : 1);
    for (NSUInteger level = 1; level < texture.mipmapLevelCount; level++)
        for (NSUInteger slice = 0; slice < slices; slice++) {
            id<MTLTexture> source = [texture newTextureViewWithPixelFormat:texture.pixelFormat textureType:MTLTextureType2D
                                                                     levels:NSMakeRange(level - 1, 1) slices:NSMakeRange(slice, 1)];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].level = level;
            pass.colorAttachments[0].slice = slice;
            pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:pipeline];
            [encoder setFragmentTexture:source atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
        }
    if (texture.storageMode == MTLStorageModeManaged) {  // a synchronizeResource: in the original encoder saw old levels
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit synchronizeResource:texture];
        [blit endEncoding];
    }
}

static void blitEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingSRGBMips);
    id<MTLCommandBuffer> commandBuffer = pending.count ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(commandBuffer)) : nil;
    origBlitEndEncoding(self, _cmd);
    if (!pending.count) return;
    objc_setAssociatedObject(self, kPendingSRGBMips, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] sRGB mipmaps regenerated for %lu texture(s)\n", (unsigned long)pending.count);
    for (id<MTLTexture> texture in pending) regenerateSRGBMips(commandBuffer, texture);
}

// 15. MSAA resolves on the 12.x Intel driver (Haswell / Ivy Bridge): IGRenderPass::generateResolveOptions always resolves
// into level 0, slice 0 of the resolve texture. It ignores resolveLevel/resolveSlice and a view's offset into its parent
// (nothing reaches the intended level or slice) and crashes in generateResourceOptions when resolveLevel isn't 0 (wgpu
// render_target::resolve_to_2d_view; browsers/resolveview). For a color attachment that resolves anywhere else, the
// pass resolves into a temporary 2D texture instead, which a blit copies to the real level/slice when the encoder ends.
// Store actions left unknown at encoder creation and parallel render encoders are not changed.
static const void *kPendingResolveCopies = &kPendingResolveCopies;
typedef id (*RenderEncoderIMP)(id, SEL, MTLRenderPassDescriptor *);
static RenderEncoderIMP origIGRenderEncoder;
static EndEncodingIMP origIGRenderEndEncoding;

// The texture a view renders into, with the view's level/slice added (same pixel format only).
static id<MTLTexture> rootTexture(id<MTLTexture> texture, NSUInteger *level, NSUInteger *slice) {
    while (texture.parentTexture && texture.parentTexture.pixelFormat == texture.pixelFormat) {
        *level += texture.parentRelativeLevel;
        *slice += texture.parentRelativeSlice;
        texture = texture.parentTexture;
    }
    return texture;
}

// The same driver's fast clear (all channels 0 or 1) of a color target at most 2 texels wide misses half of the rows
// below row 16 (bands of 16; formats of 4+ bytes per texel; wgpu zero_init copy_texture_to_buffer_unaligned_offset_row_
// padding_init on a 1x512 texture; browsers/t2bpad/narrowclear.m). Blits and sampling see the texture the same way, so
// such a target is cleared through a 4-texel-wide temporary texture (where the clear works) and a blit, and the pass
// loads it instead.
static BOOL clearsNarrowly(MTLRenderPassColorAttachmentDescriptor *a, id<MTLTexture> *root, NSUInteger *level, NSUInteger *slice) {
    if (!a.texture || a.loadAction != MTLLoadActionClear || a.texture.sampleCount > 1) return NO;
    *level = a.level;
    *slice = a.slice;
    *root = rootTexture(a.texture, level, slice);
    if (((*root).width >> *level) > 2 || ((*root).height >> *level) <= 16) return NO;
    MTLClearColor c = a.clearColor;
    double channels[] = {c.red, c.green, c.blue, c.alpha};
    for (int i = 0; i < 4; i++)
        if (channels[i] != 0 && channels[i] != 1) return NO;  // not a fast clear
    return YES;
}

static void clearThroughWideTexture(id<MTLCommandBuffer> commandBuffer, MTLRenderPassColorAttachmentDescriptor *a, id<MTLTexture> root,
                                    NSUInteger level, NSUInteger slice) {
    NSUInteger width = MAX(root.width >> level, 1), height = MAX(root.height >> level, 1);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:root.pixelFormat width:4 height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> wide = [commandBuffer.device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = wide;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = a.clearColor;
    [origIGRenderEncoder(commandBuffer, @selector(renderCommandEncoderWithDescriptor:), pass) endEncoding];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:wide sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                toTexture:root destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, a.depthPlane)];
    [blit endEncoding];
}

static id igRenderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    MTLRenderPassDescriptor *redirected = nil;
    NSMutableArray *copies = nil;  // {temporary, destination, level, slice, depth plane}
    for (NSUInteger i = 0; descriptor && i < 8; i++) {
        id<MTLTexture> root = nil;
        NSUInteger level = 0, slice = 0;
        if (!clearsNarrowly(descriptor.colorAttachments[i], &root, &level, &slice)) continue;
        clearThroughWideTexture(self, descriptor.colorAttachments[i], root, level, slice);
        if (!redirected) {
            redirected = [descriptor copy];
            copies = [NSMutableArray array];
        }
        redirected.colorAttachments[i].loadAction = MTLLoadActionLoad;
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] narrow color target cleared through a 4-wide texture\n");
    }
    for (NSUInteger i = 0; descriptor && i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = descriptor.colorAttachments[i];
        id<MTLTexture> resolve = a.resolveTexture;
        if (!resolve || (a.storeAction != MTLStoreActionMultisampleResolve && a.storeAction != MTLStoreActionStoreAndMultisampleResolve))
            continue;
        NSUInteger level = a.resolveLevel, slice = a.resolveSlice;
        id<MTLTexture> target = rootTexture(resolve, &level, &slice);
        if (!level && !slice && !a.resolveDepthPlane) continue;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:resolve.pixelFormat
            width:MAX(target.width >> level, 1) height:MAX(target.height >> level, 1) mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> temporary = [((id<MTLCommandBuffer>)self).device newTextureWithDescriptor:td];
        if (!temporary) continue;
        if (!redirected) {
            redirected = [descriptor copy];
            copies = [NSMutableArray array];
        }
        MTLRenderPassColorAttachmentDescriptor *r = redirected.colorAttachments[i];
        r.resolveTexture = temporary;
        r.resolveLevel = r.resolveSlice = r.resolveDepthPlane = 0;
        [copies addObject:@[temporary, target, @(level), @(slice), @(a.resolveDepthPlane)]];
    }
    id encoder = origIGRenderEncoder(self, _cmd, redirected ?: descriptor);
    if (encoder && copies.count) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %lu MSAA resolve(s) redirected through a temporary texture\n", (unsigned long)copies.count);
        objc_setAssociatedObject(encoder, kPendingResolveCopies, @[self, copies], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

static void igRenderEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingResolveCopies);
    origIGRenderEndEncoding(self, _cmd);
    if (!pending) return;
    objc_setAssociatedObject(self, kPendingResolveCopies, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLBlitCommandEncoder> blit = [(id<MTLCommandBuffer>)pending[0] blitCommandEncoder];
    for (NSArray *copy in pending[1]) {
        id<MTLTexture> temporary = copy[0], target = copy[1];
        NSUInteger level = [copy[2] unsignedIntegerValue], slice = [copy[3] unsignedIntegerValue], plane = [copy[4] unsignedIntegerValue];
        [blit copyFromTexture:temporary sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(temporary.width, temporary.height, 1) toTexture:target destinationSlice:slice
             destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, plane)];
    }
    [blit endEncoding];
}

// 16. 2D-array texture views on the 12.x Intel driver: a view whose first slice isn't 0 can only reach slices below its
// layer count (the base slice + count - 1 limit is set to count - 1), so with count > base slice its other layers read
// as 0 (read) or as the first one (sample) (Dawn TextureViewSamplingTest.Texture2DArrayView*; browsers/arrayview: views
// of 6 layers, base 1-2). -[MTLIGAccelTexture initializeHWSurfaceState] builds the sampler state from _arrayLength and
// m_Info.relativeSlice; after the driver initializes such a view it is run once more with _arrayLength = base slice +
// count, which makes every layer reachable, and _arrayLength is put back. Only if m_Info.relativeLevel / relativeSlice
// are where this driver keeps them (the view's base level and slice, checked against the parent's).
typedef void *(*InitViewIMP)(void *, SEL, void *, MTLPixelFormat, MTLTextureType, NSRange, NSRange);  // init: no ARC
static InitViewIMP origIGInitView;
static ptrdiff_t igInfoOffset = -1, igArrayLengthOffset = -1;
enum { kIGRelativeLevel = 0xf8, kIGRelativeSlice = 0xfc };  // m_Info fields (uint16_t)

static void *igInitView(void *self, SEL _cmd, void *parent, MTLPixelFormat format, MTLTextureType type, NSRange levels,
                        NSRange slices) {
    void *view = origIGInitView(self, _cmd, parent, format, type, levels, slices);
    if (!view || !parent || type != MTLTextureType2DArray || igInfoOffset < 0 || igArrayLengthOffset < 0) return view;
    const uint8_t *from = (const uint8_t *)parent + igInfoOffset;
    uint8_t *info = (uint8_t *)view + igInfoOffset;
    uint16_t baseLevel = *(uint16_t *)(info + kIGRelativeLevel), baseSlice = *(uint16_t *)(info + kIGRelativeSlice);
    if (!baseSlice || baseLevel != *(const uint16_t *)(from + kIGRelativeLevel) + levels.location ||
        baseSlice != *(const uint16_t *)(from + kIGRelativeSlice) + slices.location)
        return view;
    NSUInteger *arrayLength = (NSUInteger *)((uint8_t *)view + igArrayLengthOffset), count = *arrayLength;
    if (count != slices.length) return view;
    *arrayLength = baseSlice + count;
    ((void (*)(void *, SEL))objc_msgSend)(view, sel_registerName("initializeHWSurfaceState"));
    *arrayLength = count;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 2D-array view (slices %u..%u) surface state rebuilt\n", baseSlice,
                                           (unsigned)(baseSlice + count - 1));
    return view;
}

// 17. Depth/stencil attachments that are texture views on the 12.5 AMD driver: rendering stencil through a 2D view of mip
// level 1+ of a texture writes nothing (wgpu zero_init "Stencil8 store to mip 1, layer 1 of a D2 view";
// browsers/stencilslice/stencilview.m); attaching the texture itself with that level/slice works. Such attachments are
// rewritten to the view's parent texture with the view's level/slice added (what rendering to the view means).
static RenderEncoderIMP origBronzeRenderEncoder;

static void attachRoot(MTLRenderPassAttachmentDescriptor *a) {
    NSUInteger level = a.level, slice = a.slice;
    id<MTLTexture> root = rootTexture(a.texture, &level, &slice);
    if (root == a.texture || root.textureType == MTLTextureType3D) return;
    a.texture = root;
    a.level = level;
    a.slice = slice;
}

static id bronzeRenderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    if (!descriptor.depthAttachment.texture.parentTexture && !descriptor.stencilAttachment.texture.parentTexture)
        return origBronzeRenderEncoder(self, _cmd, descriptor);
    MTLRenderPassDescriptor *rewritten = [descriptor copy];
    attachRoot(rewritten.depthAttachment);
    attachRoot(rewritten.stencilAttachment);
    if (getenv("MTLSHIM_VERBOSE")) {
        id<MTLTexture> d = descriptor.depthAttachment.texture, s = descriptor.stencilAttachment.texture;
        shimLog("[mtlshim] depth/stencil views -> parent: depth %s type %lu fmt %lu -> level %lu slice %lu; stencil %s type %lu fmt %lu "
                "-> level %lu slice %lu\n", d.parentTexture ? "view" : "texture", (unsigned long)d.textureType, (unsigned long)d.pixelFormat,
                (unsigned long)rewritten.depthAttachment.level, (unsigned long)rewritten.depthAttachment.slice, s.parentTexture ? "view" : "texture",
                (unsigned long)s.textureType, (unsigned long)s.pixelFormat, (unsigned long)rewritten.stencilAttachment.level,
                (unsigned long)rewritten.stencilAttachment.slice);
    }
    return origBronzeRenderEncoder(self, _cmd, rewritten);
}

static BOOL definesMethod(const char *cls, const char *sel);
static IMP swizzle(const char *cls, const char *sel, IMP imp);

// Driver classes come from the driver bundles, which load with the first device: patched when a device is first seen.
static void patchDriverClasses(void) {
    if (patched) restoreArgumentEncoders();  // item 14: after the wrapper's initializer
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!origGenerateMipmaps && definesMethod("BronzeMtlBlitCmdEncoder", "generateMipmapsForTexture:") &&
        definesMethod("BronzeMtlBlitCmdEncoder", "endEncoding")) {
        origGenerateMipmaps = (GenerateMipmapsIMP)swizzle("BronzeMtlBlitCmdEncoder", "generateMipmapsForTexture:", (IMP)generateMipmaps);
        origBlitEndEncoding = (EndEncodingIMP)swizzle("BronzeMtlBlitCmdEncoder", "endEncoding", (IMP)blitEndEncoding);
    }
    if (!origIGRenderEncoder && definesMethod("MTLIGAccelCommandBuffer", "renderCommandEncoderWithDescriptor:") &&
        definesMethod("MTLIGAccelRenderCommandEncoder", "endEncoding")) {
        origIGRenderEncoder = (RenderEncoderIMP)swizzle("MTLIGAccelCommandBuffer", "renderCommandEncoderWithDescriptor:", (IMP)igRenderEncoder);
        origIGRenderEndEncoding = (EndEncodingIMP)swizzle("MTLIGAccelRenderCommandEncoder", "endEncoding", (IMP)igRenderEndEncoding);
    }
    if (!origBronzeRenderEncoder && definesMethod("BronzeMtlCmdBuffer", "renderCommandEncoderWithDescriptor:"))
        origBronzeRenderEncoder = (RenderEncoderIMP)swizzle("BronzeMtlCmdBuffer", "renderCommandEncoderWithDescriptor:", (IMP)bronzeRenderEncoder);
    Class igTexture = objc_getClass("MTLIGAccelTexture");
    Ivar info = igTexture ? class_getInstanceVariable(igTexture, "m_Info") : NULL;
    Ivar arrayLength = igTexture ? class_getInstanceVariable(igTexture, "_arrayLength") : NULL;
    if (!origIGInitView && info && arrayLength && !strcmp(ivar_getTypeEncoding(arrayLength), "Q") &&
        strstr(ivar_getTypeEncoding(info), "\"relativeLevel\"S\"relativeLevelRange\"S\"relativeSlice\"S") &&
        definesMethod("MTLIGAccelTexture", "initWithTexture:pixelFormat:textureType:levels:slices:") &&
        definesMethod("MTLIGAccelTexture", "initializeHWSurfaceState")) {
        igInfoOffset = ivar_getOffset(info);
        igArrayLengthOffset = ivar_getOffset(arrayLength);
        origIGInitView = (InitViewIMP)swizzle("MTLIGAccelTexture", "initWithTexture:pixelFormat:textureType:levels:slices:", (IMP)igInitView);
    }
    os_unfair_lock_unlock(&lock);
}

static void pinDevice(const void *device) {
    static const void *pinned[16];
    static int count;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    if (!device) return;
    os_unfair_lock_lock(&lock);
    BOOL seen = NO;
    for (int i = 0; i < count && !seen; i++) seen = pinned[i] == device;
    if (!seen && count < 16) {
        pinned[count++] = device;
        CFRetain(device);
    }
    os_unfair_lock_unlock(&lock);
    if (!seen) patchDriverClasses();
}

// ANGLE's callers: a Chromium framework image ("<Product> Framework"), or WebKit's libANGLE-shared.dylib / WebGPU.framework
// and WebCore / WebKit, which pick the device they hand to ANGLE (MTLCreateSystemDefaultDevice: the Intel iGPU under
// automatic graphics switching, and ANGLE can't run WebGL on family 1).
static BOOL fromChromium(const void *returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return NO;
    const char *base = strrchr(info.dli_fname, '/');
    base = base ? base + 1 : info.dli_fname;
    size_t n = strlen(base);
    if (!strcmp(base, "libANGLE-shared.dylib") || !strcmp(base, "WebGPU") || !strcmp(base, "WebCore") || !strcmp(base, "WebKit"))
        return YES;  // WebKit's ANGLE, WebGPU and the WebKit frameworks that choose their GPU
    return n > 10 && !strcmp(base + n - 10, " Framework") && strstr(info.dli_fname, ".framework/") != NULL;
}

static BOOL familyTwo(const void *device) {
    return ((BOOL (*)(const void *, SEL, NSInteger))objc_msgSend)(device, @selector(supportsFamily:), MTLGPUFamilyMac2);
}

static CFArrayRef familyTwoOnly(CFArrayRef all) {  // consumes all; unchanged if no device qualifies
    if (!all) return all;
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++)
        if (familyTwo(CFArrayGetValueAtIndex(all, i))) CFArrayAppendValue(out, CFArrayGetValueAtIndex(all, i));
    if (!CFArrayGetCount(out)) {
        CFRelease(out);
        return all;
    }
    CFRelease(all);
    return out;
}

static const char *callerImage(const void *returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return "?";
    const char *base = strrchr(info.dli_fname, '/');
    return base ? base + 1 : info.dli_fname;
}

// ANGLE can only run on Metal where there is a family-2 GPU. Macs whose only GPU is a Haswell / Ivy Bridge iGPU (family 1)
// keep their real model, so ANGLE stays on its OpenGL backend instead of picking Metal and then rejecting the GPU.
static BOOL anyFamilyTwo(void) {
    static dispatch_once_t once;
    static BOOL any;
    dispatch_once(&once, ^{
        CFArrayRef all = (__bridge_retained CFArrayRef)MTLCopyAllDevices();
        for (CFIndex i = 0; all && i < CFArrayGetCount(all) && !any; i++) any = familyTwo(CFArrayGetValueAtIndex(all, i));
        if (all) CFRelease(all);
    });
    return any;
}

static CFTypeRef compatRegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (getenv("MTLSHIM_VERBOSE") && key && CFStringCompare(key, CFSTR("model"), 0) == kCFCompareEqualTo)
        shimLog("[mtlshim] IORegistryEntryCreateCFProperty(model) from %s\n", callerImage(__builtin_return_address(0)));
    if (!value || !key || CFGetTypeID(value) != CFDataGetTypeID() || CFStringCompare(key, CFSTR("model"), 0) != kCFCompareEqualTo)
        return value;
    io_name_t cls;
    if (IOObjectGetClass(entry, cls) != KERN_SUCCESS || strcmp(cls, "IOPlatformExpertDevice") || !fromChromium(__builtin_return_address(0)) ||
        !anyFamilyTwo())
        return value;
    static const char model[] = "MacBookPro13,3";  // past ANGLE's gate (MacBookPro >= 13,1)
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Chromium: IOPlatformExpertDevice model -> %s\n", model);
    CFRelease(value);
    return CFDataCreate(allocator, (const UInt8 *)model, sizeof model);
}

static id<MTLDevice> compatCreateSystemDefaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MTLCreateSystemDefaultDevice from %s -> %s\n", callerImage(__builtin_return_address(0)), device.name.UTF8String);
    pinDevice((__bridge const void *)device);
    if (device && fromChromium(__builtin_return_address(0)) && !familyTwo((__bridge const void *)device)) {
        for (id<MTLDevice> other in MTLCopyAllDevices())
            if (familyTwo((__bridge const void *)other)) {
                pinDevice((__bridge const void *)other);
                if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Chromium: default device %s -> %s\n", device.name.UTF8String, other.name.UTF8String);
                return other;
            }
    }
    return device;
}

static CFArrayRef compatCopyAllDevices(void) {
    CFArrayRef all = (__bridge_retained CFArrayRef)MTLCopyAllDevices();
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MTLCopyAllDevices from %s\n", callerImage(__builtin_return_address(0)));
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) pinDevice(CFArrayGetValueAtIndex(all, i));
    return fromChromium(__builtin_return_address(0)) ? familyTwoOnly(all) : all;
}

static CFArrayRef compatCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler) {
    CFArrayRef all = (__bridge_retained CFArrayRef)MTLCopyAllDevicesWithObserver(observer, handler);
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) pinDevice(CFArrayGetValueAtIndex(all, i));
    return fromChromium(__builtin_return_address(0)) ? familyTwoOnly(all) : all;
}

// Interposed for every image loaded with this one (it is a launch-time dependency of Metal.framework). The device
// functions only apply on MetalOld: with native Metal the originals are returned unchanged.
static BOOL onMetalOld(void) {
    static int state;
    if (!state) {
        const char *image = class_getImageName(objc_getClass("_MTLDevice"));
        state = image && strstr(image, "MetalOld") ? 1 : -1;
    }
    return state > 0;
}
__attribute__((unused)) static CFTypeRef interposedRegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef k, CFAllocatorRef a, IOOptionBits o) {
    return onMetalOld() ? compatRegistryEntryCreateCFProperty(e, k, a, o) : IORegistryEntryCreateCFProperty(e, k, a, o);
}
__attribute__((unused)) static void *interposedCreateSystemDefaultDevice(void) {
    return onMetalOld() ? (__bridge_retained void *)compatCreateSystemDefaultDevice() : (__bridge_retained void *)MTLCreateSystemDefaultDevice();
}
__attribute__((unused)) static CFArrayRef interposedCopyAllDevices(void) {
    return onMetalOld() ? compatCopyAllDevices() : (__bridge_retained CFArrayRef)MTLCopyAllDevices();
}
__attribute__((unused)) static CFArrayRef interposedCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler) {
    return onMetalOld() ? compatCopyAllDevicesWithObserver(observer, handler) : (__bridge_retained CFArrayRef)MTLCopyAllDevicesWithObserver(observer, handler);
}
#ifndef METALOLDCOMPAT_NOOP
__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    {(const void *)interposedRegistryEntryCreateCFProperty, (const void *)IORegistryEntryCreateCFProperty},
    {(const void *)interposedCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice},
    {(const void *)interposedCopyAllDevices, (const void *)MTLCopyAllDevices},
    {(const void *)interposedCopyAllDevicesWithObserver, (const void *)MTLCopyAllDevicesWithObserver},
};
#endif

// This library links MetalOld.dylib, so dyld has registered MetalOld's classes and run its initializers before this
// one; patching here needs no dyld callbacks (calling into the ObjC runtime from those risks lock-order deadlocks).
// Build with -DMETALOLDCOMPAT_NOOP for a copy that loads the same way but changes nothing.
__attribute__((constructor)) static void init(void) {
#ifndef METALOLDCOMPAT_NOOP
    patchDeviceBase();
#else
    (void)patchDeviceBase;
#endif
}
