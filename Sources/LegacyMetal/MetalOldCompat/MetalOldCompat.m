// MetalOldCompat.dylib: fixes for OCLP's Metal 3802 stack (MetalOld.dylib = Metal from macOS 13.2, used for every GPU
// on Macs that also have a Haswell/Ivy Bridge iGPU) when apps built for macOS 15 drive a GPU whose shaders are compiled
// by the newer MTLCompiler (the AMD GCN dGPU of MacBookPro11,5 / iMac15,1):
//   1. MTLDevice methods from the macOS 13.3+/15 SDK that MetalOld lacks ("unrecognized selector" crashes)
//   2. reflection data wrapped in the newer CompilerOutputReflectionBlock container, which MetalOld can't read
//   3. MTLTextureUsageShaderAtomic and memoryless storage, which MetalOld rejects in texture validation
//   7. serialized vertex descriptors, whose layout records changed size between MetalOld and the newer compiler
//   8. properties and encoder calls from the macOS 13.3-15 SDKs (MTLCompileOptions.mathMode, shaderValidation, ...;
//      object/mesh stage bindings on GPUs without mesh shaders)
//   9. MSL 3.2 requests (compiled as 3.1, the newest this stack's front end has; also the default; 3.2's coherence
//      qualifiers rewritten to their 3.1 equivalents)
//  10. Metal devices pinned against over-release (Chromium's GPU process)
//  11. ANGLE (Chromium, Safari's WebKit): past ANGLE's pre-2016-Mac gate, and only family-2 GPUs (the AMD dGPU) for it;
//      on Macs whose only GPU is family 1, that GPU as family 2, with ANGLE's fallbacks for what it lacks
//  13. Safari's ANGLE: its prebuilt internal-shader metallib (too new for this stack) replaced by the same shaders
//      compiled from source
//  14. argument encoders in Safari's processes (OCLP's wrapper stubs them out; WebGL 2 uniform blocks need them)
//  15. 12.x Intel driver: MSAA resolves into a mip level / array slice other than 0 (lost, or a crash); fast clears of
//      color targets at most 2 texels wide (rows missed)
//  16. 2D-array texture views that don't start at slice 0 on the 12.x Intel driver (most of their layers unreachable)
//  18. pipeline cache keys that ignore the pipeline descriptor (a compute pipeline's maxTotalThreadsPerThreadgroup):
//      MetalOld told to key by the driver's function key
//  20. 8-byte buffer fills at an offset of 4 mod 8 on the 12.x Intel driver (filled the 8 bytes below instead)
//  21. depth-only render pipelines on the 12.x Intel driver: without a fragment function they write no usable depth;
//      they get an empty one
//  22. HiZ on the 12.x Intel driver for depth textures with several mip levels or slices: blits leave it out of step
//      with the depth data; such textures are created without HiZ
//  23. rendering into a depth plane of a 3D texture's mip level 1+ on the 12.x Intel driver (wrong planes written):
//      through a temporary 2D texture
//  24. clears of R8Unorm / RG8Unorm targets at mip level 1+ on the 12.x Intel driver (nothing cleared): through a
//      temporary texture
//  25. precompiled libraries built for macOS 15.4+ (AIR 2.7, e.g. iMovie's): retargeted to AIR 2.6 in the compiler
//      service, as MetallibSupportPkg does for the system's metallibs
//  26. divide by zero in WebKit's WebGPU, which only traps on Intel Macs (kills Safari's GPU process): gives the result
//      Apple silicon gets
//  27. blits into depth or stencil that later render passes don't see on the 12.x Intel driver: written again by a
//      render pass
//  28. nil buffers encoded into argument buffers on the 12.x Intel driver (a null dereference; Blender's Cycles): the
//      slot cleared instead
//  29. a sample mask of 0 from WebKit's WebGPU on the 12.x Intel driver (every sample drawn): a mask that covers none
//  30. integer cube textures with 1x1 / 2x2 faces sampled in vertex and fragment functions on the 12.x Intel driver (0):
//      nearest samplers get programmed instead of seamless cube addressing
//  31. LOD clamps passed to the 12.x Intel driver's encoders (setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex: and
//      the like) wrap modulo 16 (ANGLE's 1000 reads as 8: WebGL never sampled a mip level above 8): clamped to [0, 15.996]
//  33. stencil attachments on textures with several mip levels or slices on the 12.x Intel driver (passes don't see
//      what's there and overwrite what blits wrote): rendered through a temporary texture, copied in and out by blits
//  32. texture views with a swizzle on the 12.x Intel driver (nil: family 1 has no swizzle; Dawn, told the iGPU is family 2
//      by item 11, makes every depth/stencil view with one and loses the device): a plain view where the swizzle changes
//      nothing a shader can see
//  34. coverage from a fragment function (sample_mask output, alpha-to-coverage) in a pipeline with no depth/stencil and
//      every color writeMask none on the 12.x Intel driver (dropped: occlusion queries count every sample): the first
//      blendable color attachment is written through a blend that keeps it
//  35. Metal Performance Shaders' statistics reductions (compute_final_*_statistics) dispatched with 16 threads on these
//      Intel GPUs, which those kernels can't handle (min/max, mean and variance wrong): 32 threads
//  36. multisampled Stencil8 textures on the 12.x Intel driver, which shaders read wrong (most of the right half reads
//      the left half): created as Depth32Float_Stencil8, whose stencil reads right, with Stencil8 views made X32_Stencil8
//  37. stencil copied between a buffer and a mip level 1+ on the 12.x Intel driver with a buffer offset or bytesPerRow
//      that isn't a multiple of 256 (a texel of each row taken from its neighbour): through a level-0 temporary texture
//  38. stencil views (X32_Stencil8, X24_Stencil8) of depth/stencil textures on the 12.x Intel driver, which describe the
//      stencil plane with the depth plane's 4-texel mip alignment (levels 2+ read 0 for many widths): 8, as laid out
//  39. size queries (get_width/height) on writable 2D-array views that start at mip level 1+ in fragment functions on
//      the 12.x Intel driver (level 0's size): the view's render-target surface state gets the level as its min LOD too
// (The 12.5 AMD driver's own bugs are fixed in AMDBronzeCompat.dylib, which the driver loads: BronzeCompat/.)
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
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <os/lock.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <pthread.h>
#import <IOKit/IOKitLib.h>
#include <os/log.h>
// Replacements for methods of the new / copy / init families return an owned (+1) object like the methods they replace,
// and init replacements consume self: without these annotations ARC treats them as returning +0, retains and autoreleases
// what they return, and every such object then lives until an autorelease pool drains, never in a process that drains
// none (dawn.node, command-line tools: 15000 textures in 25 s of WebGPU CTS image_copy).
#define RETURNS_RETAINED __attribute__((ns_returns_retained))
#define CONSUMED __attribute__((ns_consumed))
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

typedef id (*InitVFIMP)(CONSUMED id, SEL, dispatch_data_t, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger) RETURNS_RETAINED;
typedef id (*InitOMFIMP)(CONSUMED id, SEL, dispatch_data_t, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger) RETURNS_RETAINED;
typedef id (*InitTileIMP)(CONSUMED id, SEL, dispatch_data_t, NSUInteger, id, NSUInteger, NSUInteger) RETURNS_RETAINED;
typedef id (*InitComputeIMP)(CONSUMED id, SEL, dispatch_data_t, id, NSUInteger, NSUInteger) RETURNS_RETAINED;
typedef id (*InitComputeStageIMP)(CONSUMED id, SEL, dispatch_data_t, dispatch_data_t, id, NSUInteger, NSUInteger) RETURNS_RETAINED;
typedef id (*InitFunctionIMP)(CONSUMED id, SEL, id, dispatch_data_t, NSUInteger, NSUInteger) RETURNS_RETAINED;

static InitVFIMP origVF;
static InitOMFIMP origOMF;
static InitTileIMP origTile;
static InitComputeIMP origCompute;
static InitComputeStageIMP origComputeStage;
static InitFunctionIMP origFunction;

static id initVF(CONSUMED id self, SEL _cmd, dispatch_data_t vertex, dispatch_data_t fragment, dispatch_data_t vertexDesc, id device, NSUInteger options, NSUInteger flags) RETURNS_RETAINED;
static id initVF(CONSUMED id self, SEL _cmd, dispatch_data_t vertex, dispatch_data_t fragment, dispatch_data_t vertexDesc, id device, NSUInteger options, NSUInteger flags) {
    // MetalOld's own reflection reader still needs the 13.2 vertex descriptor layout.
    return origVF(self, _cmd, unwrapReflection(vertex), unwrapReflection(fragment), convertVertexDescriptor(vertexDesc, NO), device, options, flags);
}

static id initOMF(CONSUMED id self, SEL _cmd, dispatch_data_t object, dispatch_data_t mesh, dispatch_data_t fragment, id device, NSUInteger options, NSUInteger flags) RETURNS_RETAINED;
static id initOMF(CONSUMED id self, SEL _cmd, dispatch_data_t object, dispatch_data_t mesh, dispatch_data_t fragment, id device, NSUInteger options, NSUInteger flags) {
    return origOMF(self, _cmd, unwrapReflection(object), unwrapReflection(mesh), unwrapReflection(fragment), device, options, flags);
}

static id initTile(CONSUMED id self, SEL _cmd, dispatch_data_t tile, NSUInteger functionType, id device, NSUInteger options, NSUInteger flags) RETURNS_RETAINED;
static id initTile(CONSUMED id self, SEL _cmd, dispatch_data_t tile, NSUInteger functionType, id device, NSUInteger options, NSUInteger flags) {
    return origTile(self, _cmd, unwrapReflection(tile), functionType, device, options, flags);
}

static id initCompute(CONSUMED id self, SEL _cmd, dispatch_data_t data, id device, NSUInteger options, NSUInteger flags) RETURNS_RETAINED;
static id initCompute(CONSUMED id self, SEL _cmd, dispatch_data_t data, id device, NSUInteger options, NSUInteger flags) {
    return origCompute(self, _cmd, unwrapReflection(data), device, options, flags);
}

static id initComputeStage(CONSUMED id self, SEL _cmd, dispatch_data_t data, dispatch_data_t stageDesc, id device, NSUInteger options, NSUInteger flags) RETURNS_RETAINED;
static id initComputeStage(CONSUMED id self, SEL _cmd, dispatch_data_t data, dispatch_data_t stageDesc, id device, NSUInteger options, NSUInteger flags) {
    return origComputeStage(self, _cmd, unwrapReflection(data), stageDesc, device, options, flags);
}

static id initFunction(CONSUMED id self, SEL _cmd, id device, dispatch_data_t data, NSUInteger functionType, NSUInteger options) RETURNS_RETAINED;
static id initFunction(CONSUMED id self, SEL _cmd, id device, dispatch_data_t data, NSUInteger functionType, NSUInteger options) {
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
    // Only Apple GPUs have memoryless storage, and MetalOld aborts on it. Safari 27's WebGPU asks for it for transient attachments.
    if (desc.storageMode == MTLStorageModeMemoryless) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] memoryless texture made private\n");
        desc.storageMode = MTLStorageModePrivate;
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
typedef id (*InitIMP)(CONSUMED id, SEL) RETURNS_RETAINED;
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

// OCLP's Tahoe wrapper makes setLanguageVersion: a no-op when it loads, which is after this library's initializer. Apps then can't
// pick an older version than the default, and shaders only valid there stop compiling (Blender's EEVEE has a variable called
// ray_data, a keyword since MSL 2.3). The hook goes back in here, before anyone can call the setter.
static id compileOptionsInit(CONSUMED id self, SEL _cmd) RETURNS_RETAINED;
static id compileOptionsInit(CONSUMED id self, SEL _cmd) {
    Method setter = class_getInstanceMethod(object_getClass(self), @selector(setLanguageVersion:));
    if (setter && method_getImplementation(setter) != (IMP)setLanguageVersion) method_setImplementation(setter, (IMP)setLanguageVersion);
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

// 21. Depth-only render pipelines on the 12.x Intel driver: a pipeline without a fragment function leaves its depth
// attachment unusable: a later draw of the same triangles with compare Equal passes nowhere, single- or multisampled
// (WebGPU CTS copyTextureToTexture copy_depth_stencil / copy_multisampled_depth, rendering/stencil). With an empty
// fragment function the same pipeline writes correct depth, so on the Intel GPU a rasterizing pipeline with no
// fragment function, no color attachments and a depth or stencil attachment gets one (compiled once per device).
// Pipelines with color attachments are left as they are.
static const void *kEmptyFragmentKey = &kEmptyFragmentKey;
typedef id (*NewRenderPipelineIMP)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
typedef id (*NewRenderPipelineReflIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption,
                                       MTLAutoreleasedRenderPipelineReflection *, NSError **);
typedef void (*NewRenderPipelineAsyncIMP)(id, SEL, MTLRenderPipelineDescriptor *, id);
typedef void (*NewRenderPipelineOptAsyncIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, id);
static NewRenderPipelineIMP origNewRenderPipeline;
static NewRenderPipelineReflIMP origNewRenderPipelineRefl;
static NewRenderPipelineAsyncIMP origNewRenderPipelineAsync;
static NewRenderPipelineOptAsyncIMP origNewRenderPipelineOptAsync;

static MTLRenderPipelineDescriptor *withEmptyFragment(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    static Class intel;
    if (!intel) intel = objc_getClass("MTLIGAccelDevice");
    if (!intel || ![(id)device isKindOfClass:intel] || !descriptor || descriptor.fragmentFunction || !descriptor.rasterizationEnabled ||
        (descriptor.depthAttachmentPixelFormat == MTLPixelFormatInvalid && descriptor.stencilAttachmentPixelFormat == MTLPixelFormatInvalid))
        return descriptor;
    for (NSUInteger i = 0; i < 8; i++)
        if (descriptor.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid) return descriptor;
    id<MTLFunction> empty;
    @synchronized((id)device) {
        empty = objc_getAssociatedObject(device, kEmptyFragmentKey);
        if (!empty) {
            id<MTLLibrary> library = [device newLibraryWithSource:@"fragment void mtlshim_empty_fragment() {}" options:nil error:nil];
            empty = [library newFunctionWithName:@"mtlshim_empty_fragment"];
            if (empty) objc_setAssociatedObject(device, kEmptyFragmentKey, empty, OBJC_ASSOCIATION_RETAIN);
        }
    }
    if (!empty) return descriptor;
    MTLRenderPipelineDescriptor *copy = [descriptor copy];
    copy.fragmentFunction = empty;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth-only render pipeline given an empty fragment function\n");
    return copy;
}

// 34. Coverage that a fragment function computes (a [[sample_mask]] output, or its alpha with alpha-to-coverage) travels
// with the color write on the 12.x Intel driver. In a pipeline with no depth or stencil attachment whose color attachments
// all have writeMask none, the fragment function runs but its coverage is dropped: every sample counts as drawn, and
// occlusion queries count them all (WebGPU CTS occlusionQuery sample_mask and alpha_to_coverage with writeMask 0; Dawn
// does GPUMultisampleState.mask with a sample_mask output). Discards and buffer writes are unaffected. On the Intel GPU,
// such pipelines with several samples or alpha-to-coverage write their first blendable color attachment through a blend
// that keeps what's there (source x 0 + destination x 1). Test: s38. MTLSHIM_COVERAGE_WRITE=0 turns it off.
static BOOL blendableFormat(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
    case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint:
    case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatInvalid:
        return NO;
    default:
        return YES;
    }
}

static MTLRenderPipelineDescriptor *withCoverageWrite(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    static Class intel;
    if (!intel) intel = objc_getClass("MTLIGAccelDevice");
    if (!intel || ![(id)device isKindOfClass:intel] || !descriptor || !descriptor.fragmentFunction || !descriptor.rasterizationEnabled ||
        descriptor.depthAttachmentPixelFormat != MTLPixelFormatInvalid || descriptor.stencilAttachmentPixelFormat != MTLPixelFormatInvalid ||
        (descriptor.rasterSampleCount <= 1 && !descriptor.alphaToCoverageEnabled))
        return descriptor;
    const char *setting = getenv("MTLSHIM_COVERAGE_WRITE");
    if (setting && !strcmp(setting, "0")) return descriptor;
    int target = -1;
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *a = descriptor.colorAttachments[i];
        if (a.pixelFormat == MTLPixelFormatInvalid) continue;
        if (a.writeMask != MTLColorWriteMaskNone) return descriptor;
        if (target < 0 && blendableFormat(a.pixelFormat)) target = (int)i;
    }
    if (target < 0) return descriptor;
    MTLRenderPipelineDescriptor *copy = [descriptor copy];
    MTLRenderPipelineColorAttachmentDescriptor *a = copy.colorAttachments[target];
    a.writeMask = MTLColorWriteMaskAll;
    a.blendingEnabled = YES;
    a.rgbBlendOperation = a.alphaBlendOperation = MTLBlendOperationAdd;
    a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = MTLBlendFactorZero;
    a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor = MTLBlendFactorOne;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] render pipeline without writes: color attachment %d written through a blend that keeps it\n", target);
    return copy;
}

static MTLRenderPipelineDescriptor *adjustedPipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    return withCoverageWrite(device, withEmptyFragment(device, descriptor));  // items 21 and 34
}

static id newRenderPipeline(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error) {
    return origNewRenderPipeline(self, _cmd, adjustedPipeline(self, descriptor), error);
}

static id newRenderPipelineRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options,
                                MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) {
    return origNewRenderPipelineRefl(self, _cmd, adjustedPipeline(self, descriptor), options, reflection, error);
}

static void newRenderPipelineAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, id handler) {
    origNewRenderPipelineAsync(self, _cmd, adjustedPipeline(self, descriptor), handler);
}

static void newRenderPipelineOptAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options,
                                      id handler) {
    origNewRenderPipelineOptAsync(self, _cmd, adjustedPipeline(self, descriptor), options, handler);
}

static void fillEmptyFragments(void) {
    if (definesMethod("_MTLDevice", "newRenderPipelineStateWithDescriptor:error:"))
        origNewRenderPipeline = (NewRenderPipelineIMP)swizzle("_MTLDevice", "newRenderPipelineStateWithDescriptor:error:", (IMP)newRenderPipeline);
    if (definesMethod("_MTLDevice", "newRenderPipelineStateWithDescriptor:options:reflection:error:"))
        origNewRenderPipelineRefl = (NewRenderPipelineReflIMP)swizzle(
            "_MTLDevice", "newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)newRenderPipelineRefl);
    if (definesMethod("_MTLDevice", "newRenderPipelineStateWithDescriptor:completionHandler:"))
        origNewRenderPipelineAsync = (NewRenderPipelineAsyncIMP)swizzle(
            "_MTLDevice", "newRenderPipelineStateWithDescriptor:completionHandler:", (IMP)newRenderPipelineAsync);
    if (definesMethod("_MTLDevice", "newRenderPipelineStateWithDescriptor:options:completionHandler:"))
        origNewRenderPipelineOptAsync = (NewRenderPipelineOptAsyncIMP)swizzle(
            "_MTLDevice", "newRenderPipelineStateWithDescriptor:options:completionHandler:", (IMP)newRenderPipelineOptAsync);
}

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
    fillEmptyFragments();
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
// these Macs get no GPU acceleration at all; and ANGLE refuses a Metal family-1 GPU (Haswell / Ivy Bridge: no Mac2),
// which automatic graphics switching often makes the active one. For calls from a Chromium
// framework image ("<Product> Framework") or WebKit's ANGLE: report a post-2015 model, and list only family-2 GPUs (the
// AMD dGPU) to ANGLE, Skia Graphite and Dawn. Everything else in the process sees the real model and all GPUs.
// Where no GPU is family 2 (Macs with only the Intel iGPU), those callers are told the iGPU supports
// MTLGPUFamilyMac2. ANGLE built for macOS 13 or later (Chrome, Safari) asks Mac2 for its family-1 checks too, such as
// format capabilities and the number of color attachments. Of what ANGLE then expects from family 2, the 12.x Intel
// driver lacks three: swizzled texture views (it returns nil), stencil MSAA resolves (nothing is written) and render
// pipelines without attachments (MetalOld's validation aborts). Its compiler also can't build a depth comparison with
// gradients (sample_compare(..., gradient2d(...)) aborts MTLCompilerService), which ANGLE uses for textureGrad on shadow
// samplers. Before ANGLE sets up its features, all four are added to ANGLE_FEATURE_OVERRIDES_DISABLED (hasTextureSwizzle,
// hasStencilAutoResolve, allowRenderpassWithoutAttachment, allowSamplerCompareGradient), which ANGLE reads once, so it
// takes its own fallbacks. MTLSHIM_ANGLE_MAC2=0 turns this part off.
typedef void (*EndEncodingIMP)(id, SEL);

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

// 24. The same driver doesn't clear R8Unorm or RG8Unorm targets at mip level 1 or higher at all (fast or slow clear;
// draws to those levels work, as do level 0 and the other formats, R8Uint and RG8Snorm included; WebGPU CTS texture_zero
// r8unorm/rg8unorm). Such a clear also goes through a temporary texture, of the level's size.
static BOOL clearsNarrowFormatMip(MTLRenderPassColorAttachmentDescriptor *a, id<MTLTexture> *root, NSUInteger *level, NSUInteger *slice) {
    if (!a.texture || a.loadAction != MTLLoadActionClear || a.texture.sampleCount > 1) return NO;
    *level = a.level;
    *slice = a.slice;
    *root = rootTexture(a.texture, level, slice);
    MTLPixelFormat format = (*root).pixelFormat;
    return *level > 0 && (format == MTLPixelFormatR8Unorm || format == MTLPixelFormatRG8Unorm);
}

static void clearThroughTemporary(id<MTLCommandBuffer> commandBuffer, MTLRenderPassColorAttachmentDescriptor *a, id<MTLTexture> root,
                                  NSUInteger level, NSUInteger slice, NSUInteger temporaryWidth) {
    NSUInteger width = MAX(root.width >> level, 1), height = MAX(root.height >> level, 1);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:root.pixelFormat width:temporaryWidth
                                                                                 height:height mipmapped:NO];
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
        BOOL narrow = clearsNarrowly(descriptor.colorAttachments[i], &root, &level, &slice);
        if (!narrow && !clearsNarrowFormatMip(descriptor.colorAttachments[i], &root, &level, &slice)) continue;
        clearThroughTemporary(self, descriptor.colorAttachments[i], root, level, slice, narrow ? 4 : MAX(root.width >> level, 1));
        if (!redirected) {
            redirected = [descriptor copy];
            copies = [NSMutableArray array];
        }
        redirected.colorAttachments[i].loadAction = MTLLoadActionLoad;
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] color target cleared through a temporary texture\n");
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
    // 23. A 3D color target at mip level 1 or higher on the same driver: a pass on depth plane 0 also writes plane 1,
    // and one on plane 1 writes neither (clears and draws; through views too; WebGPU CTS 3d_texture_slices with mip
    // levels; browsers/... view3d.m). Level 0 and blits are right. The pass renders into a temporary 2D texture of the
    // level's size instead, loaded from the plane first if the pass loads, and copied to the plane when the encoder ends.
    for (NSUInteger i = 0; descriptor && i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = (redirected ?: descriptor).colorAttachments[i];
        NSUInteger level = a.level, slice = a.slice;
        id<MTLTexture> root = a.texture ? rootTexture(a.texture, &level, &slice) : nil;
        if (!root || root.textureType != MTLTextureType3D || !level) continue;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:root.pixelFormat
            width:MAX(root.width >> level, 1) height:MAX(root.height >> level, 1) mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> temporary = [((id<MTLCommandBuffer>)self).device newTextureWithDescriptor:td];
        if (!temporary) continue;
        NSUInteger plane = a.depthPlane;
        if (a.loadAction == MTLLoadActionLoad) {
            id<MTLBlitCommandEncoder> blit = [(id<MTLCommandBuffer>)self blitCommandEncoder];
            [blit copyFromTexture:root sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, plane)
                       sourceSize:MTLSizeMake(temporary.width, temporary.height, 1) toTexture:temporary destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        }
        if (!redirected) {
            redirected = [descriptor copy];
            copies = [NSMutableArray array];
        }
        MTLRenderPassColorAttachmentDescriptor *r = redirected.colorAttachments[i];
        r.texture = temporary;
        r.level = r.slice = r.depthPlane = 0;
        if (a.storeAction == MTLStoreActionStore) [copies addObject:@[temporary, root, @(level), @0, @(plane)]];
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 3D target (level %lu, plane %lu) rendered through a 2D texture\n", (unsigned long)level, (unsigned long)plane);
    }
    // 33. Stencil textures with several mip levels or array slices on the same driver: render passes on them and blits
    // into them don't agree. A pass at a level or slice other than 0 doesn't load what's there (a stencil test against
    // it fails, and so does a write that has to read first: write masks, INCR) unless a color target is at the same
    // level and slice; and a pass that loads and stores level 0 / slice 0 makes every subresource read back by a shader
    // as what that pass saw, overwriting what blits wrote. Blits and shader reads agree everywhere, and so do clears and
    // REPLACE draws made through a single-level texture copied in by a blit (WebGPU CTS copyTextureToTexture
    // copy_depth_stencil and image_copy *_depth_stencil; s17). A render pass with a stencil attachment on such a texture,
    // or a depth attachment on a Depth32Float_Stencil8 one (written by these blits too), renders into a temporary texture
    // of the subresource's size instead (depth and stencil together, as they share the texture), copied
    // from the subresource by a blit first if the pass loads either, and back to it when the encoder ends if it stores
    // either. MTLSHIM_STENCIL_SUBRESOURCE=0 turns it off.
    {
        MTLRenderPassDescriptor *current = redirected ?: descriptor;
        MTLRenderPassStencilAttachmentDescriptor *st = current.stencilAttachment;
        MTLRenderPassDepthAttachmentDescriptor *dp = current.depthAttachment;
        // the stencil attachment, or a depth attachment on a Depth32Float_Stencil8 texture (written by blits here too)
        BOOL useStencil = st.texture != nil;
        NSUInteger level = useStencil ? st.level : dp.level, slice = useStencil ? st.slice : dp.slice;
        id<MTLTexture> attached = useStencil ? st.texture : dp.texture;
        id<MTLTexture> root = attached ? rootTexture(attached, &level, &slice) : nil;
        const char *setting = getenv("MTLSHIM_STENCIL_SUBRESOURCE");
        BOOL separateStencil = root && (root.pixelFormat == MTLPixelFormatStencil8 || root.pixelFormat == MTLPixelFormatDepth32Float_Stencil8);
        BOOL sharedDepth = dp.texture && (!useStencil || (dp.texture == st.texture && dp.level == st.level && dp.slice == st.slice));
        if (separateStencil && (root.mipmapLevelCount > 1 || root.arrayLength > 1) && !(setting && !strcmp(setting, "0")) &&
            (!dp.texture || sharedDepth) && root.textureType != MTLTextureType3D) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:root.pixelFormat
                width:MAX(root.width >> level, 1) height:MAX(root.height >> level, 1) mipmapped:NO];
            if (root.sampleCount > 1) td.textureType = MTLTextureType2DMultisample, td.sampleCount = root.sampleCount;
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> temporary = [((id<MTLCommandBuffer>)self).device newTextureWithDescriptor:td];
            if (temporary) {
                BOOL loads = (useStencil && st.loadAction == MTLLoadActionLoad) || (sharedDepth && dp.loadAction == MTLLoadActionLoad);
                BOOL stores = (useStencil && st.storeAction == MTLStoreActionStore) || (sharedDepth && dp.storeAction == MTLStoreActionStore);
                if (loads) {
                    id<MTLBlitCommandEncoder> blit = [(id<MTLCommandBuffer>)self blitCommandEncoder];
                    [blit copyFromTexture:root sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(temporary.width, temporary.height, 1) toTexture:temporary destinationSlice:0
                         destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [blit endEncoding];
                }
                if (!redirected) {
                    redirected = [descriptor copy];
                    copies = [NSMutableArray array];
                }
                if (useStencil) {
                    redirected.stencilAttachment.texture = temporary;
                    redirected.stencilAttachment.level = redirected.stencilAttachment.slice = redirected.stencilAttachment.depthPlane = 0;
                }
                if (sharedDepth) {
                    redirected.depthAttachment.texture = temporary;
                    redirected.depthAttachment.level = redirected.depthAttachment.slice = redirected.depthAttachment.depthPlane = 0;
                }
                if (stores) [copies addObject:@[temporary, root, @(level), @(slice), @0]];
                if (getenv("MTLSHIM_VERBOSE"))
                    shimLog("[mtlshim] stencil at level %lu slice %lu rendered through a temporary texture\n", (unsigned long)level, (unsigned long)slice);
            }
        }
    }
    id encoder = origIGRenderEncoder(self, _cmd, redirected ?: descriptor);
    if (encoder && copies.count) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %lu attachment(s) copied out of temporary textures at the end\n", (unsigned long)copies.count);
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

// 38. Stencil views of depth/stencil textures on the 12.x Intel driver: shaders reading the stencil of
// Depth32Float_Stencil8 (or Depth24Unorm_Stencil8) through an X32_Stencil8 view read 0 at mip level 2 and above for
// many widths (20, 24, 36: level 2 of a 20x16 texture; 12, 16, 28, 32 were right). The view's surface state takes the
// depth plane's horizontal mip alignment (4), but the stencil plane is laid out with 8, like a Stencil8 texture (whose
// views read right): levels 2+, placed to the right of level 1 at its width rounded up to the alignment, are looked
// for where level 1's width rounds differently. After the driver builds a stencil view's surface state
// (-[MTLIGAccelTexture initializeHWSurfaceState]), its horizontal alignment is set to 8. Dawn backs WebGPU's stencil8
// with Depth32Float_Stencil8. Only if m_Info.hwSurfaceState has the Gen7 SURFACE_STATE layout this expects.
// MTLSHIM_STENCIL_VIEW_ALIGN=0 turns it off. Test: s43.
typedef void (*InitSurfaceStateIMP)(id, SEL);
static InitSurfaceStateIMP origIGInitSurfaceState;
static ptrdiff_t igSurfaceStateOffset = -1;

// 39. A texture view that starts at mip level L carries two surface states: the sampler's (min LOD L) and, for writes,
// a render-target one, where the LOD field is L and the min LOD 0. Typed writes use the LOD field; the sampler's
// resinfo (get_width / get_height) uses the min LOD. In fragment functions the driver binds the render-target state
// for writable 2D-array views, so their size queries returned level 0's size (WebGPU CTS textureDimensions storage:
// write, 2d-array, base level 1-2, every format: 40 cases; compute functions and 2D views got the sampler's). The
// render-target state's min LOD is set to its LOD, which only the sampler reads. MTLSHIM_TARGET_MIN_LOD=0 turns it off.
// Test: s45.
static void targetMinLod(id self) {
    static int enabled = -1;
    if (enabled < 0) { const char *setting = getenv("MTLSHIM_TARGET_MIN_LOD"); enabled = !(setting && !strcmp(setting, "0")); }
    if (!enabled) return;
    uint32_t *dword5 = (uint32_t *)((uint8_t *)(__bridge void *)self + igSurfaceStateOffset + 32 + 20);  // hwSurfaceStateTarget
    uint32_t lod = *dword5 & 0xf, minLod = (*dword5 >> 4) & 0xf;
    if (!lod || minLod) return;
    *dword5 |= lod << 4;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] render-target surface state of a view at level %u: min LOD %u\n", lod, lod);
}

static void igInitSurfaceState(id self, SEL _cmd) {
    origIGInitSurfaceState(self, _cmd);
    targetMinLod(self);  // item 39
    MTLPixelFormat f = ((id<MTLTexture>)self).pixelFormat;
    if (f != MTLPixelFormatX32_Stencil8 && f != MTLPixelFormatX24_Stencil8) return;
    uint32_t *dword0 = (uint32_t *)((uint8_t *)(__bridge void *)self + igSurfaceStateOffset);
    if (*dword0 & (1u << 15)) return;
    *dword0 |= 1u << 15;  // SurfaceHorizontalAlignment: HALIGN_8
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil view: surface horizontal alignment 8\n");
}

static void stencilViewAlignment(void) {
    // m_Info starts with hwSurfaceState, a Gen7 SURFACE_STATE whose dword 0 has SurfaceHorizontalAlignment at bit 15
    static const char kLayout[] = "{MTLIGAccelTextureInfo=\"hwSurfaceState\"{SGfxSurfaceState=\"CubeFaceEnablesPositiveZ\"b1"
        "\"CubeFaceEnablesNegativeZ\"b1\"CubeFaceEnablesPositiveY\"b1\"CubeFaceEnablesNegativeY\"b1\"CubeFaceEnablesPositiveX\"b1"
        "\"CubeFaceEnablesNegativeX\"b1\"MediaBoundaryPixelMode\"b2\"RenderCacheReadWriteMode\"b1\"\"b1\"SurfaceArraySpacing\"b1"
        "\"VerticalLineStrideOffset\"b1\"VerticalLineStride\"b1\"TileWalk\"b1\"TiledSurface\"b1\"SurfaceHorizontalAlignment\"b1";
    const char *setting = getenv("MTLSHIM_STENCIL_VIEW_ALIGN");
    Class texture = objc_getClass("MTLIGAccelTexture");
    Ivar info = texture ? class_getInstanceVariable(texture, "m_Info") : NULL;
    if (origIGInitSurfaceState || (setting && !strcmp(setting, "0")) || !info || strncmp(ivar_getTypeEncoding(info), kLayout, sizeof kLayout - 1) ||
        !strstr(ivar_getTypeEncoding(info), "}\"hwSurfaceStateTarget\"{SGfxSurfaceState=") ||
        !definesMethod("MTLIGAccelTexture", "initializeHWSurfaceState"))
        return;
    igSurfaceStateOffset = ivar_getOffset(info);
    origIGInitSurfaceState = (InitSurfaceStateIMP)swizzle("MTLIGAccelTexture", "initializeHWSurfaceState", (IMP)igInitSurfaceState);
}

// 20. Buffer fills on the 12.x Intel driver: -[MTLIGAccelBlitCommandEncoder fillBuffer:range:value:] fills the wrong
// bytes when the length is exactly 8 and the offset is 4 mod 8: it fills the 8-aligned bytes below (offset 4 -> 0..7).
// Other lengths and offsets are right. wgpu (Firefox's WebGPU) zero-fills buffer tails this way: a 4-byte copy into
// a 12-byte buffer was wiped by the clear of bytes 4..11 (WebGPU CTS clearBuffer, copyBufferToBuffer). Such a fill is
// issued as two 4-byte fills.
typedef void (*FillBufferIMP)(id, SEL, id, NSRange, uint8_t);
static FillBufferIMP origIGFillBuffer;

static void igFillBuffer(id self, SEL _cmd, id buffer, NSRange range, uint8_t value) {
    if (range.length != 8 || (range.location & 7) != 4) {
        origIGFillBuffer(self, _cmd, buffer, range, value);
        return;
    }
    origIGFillBuffer(self, _cmd, buffer, NSMakeRange(range.location, 4), value);
    origIGFillBuffer(self, _cmd, buffer, NSMakeRange(range.location + 4, 4), value);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 8-byte fill at offset %lu split in two\n", (unsigned long)range.location);
}

// 22. HiZ on the 12.x Intel driver: for a depth texture with more than one mip level or slice, blits don't keep the
// hierarchical depth buffer in step with the depth data of levels and slices other than 0. Depth copied into such a
// level fails every later depth test against it, and a depth clear there isn't seen by a later copy out (WebGPU CTS
// copy_depth_stencil, texture_zero with depth formats). The driver creates a texture without HiZ while its device's
// bHizDisable is set (read at creation), and these depth textures are created that way. Single-level depth buffers,
// almost every renderer's main depth buffer, keep HiZ. Multisampled depth has the same problem with blits but is left
// alone: copying it is rare, and HiZ matters most to multisampled rendering.
typedef id (*NewTextureIMP)(id, SEL, MTLTextureDescriptor *) RETURNS_RETAINED;
static NewTextureIMP origIGNewTexture, origIGHeapNewTexture;
static ptrdiff_t igHizDisableOffset;

static BOOL needsNoHiZ(MTLTextureDescriptor *descriptor) {
    switch (descriptor.pixelFormat) {
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
        case MTLPixelFormatDepth24Unorm_Stencil8:
        case MTLPixelFormatDepth32Float_Stencil8:
            break;
        default:
            return NO;
    }
    MTLTextureType type = descriptor.textureType;
    return descriptor.sampleCount <= 1 && (descriptor.mipmapLevelCount > 1 || descriptor.arrayLength > 1 ||
                                           type == MTLTextureType2DArray || type == MTLTextureTypeCube ||
                                           type == MTLTextureTypeCubeArray || type == MTLTextureType3D);
}

// Item 22: while `device`'s bHizDisable is set; returns the lock's previous value to restore with endWithoutHiZ.
static pthread_mutex_t *hizLock(void) {
    static pthread_mutex_t lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pthread_mutexattr_t attributes;
        pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&lock, &attributes);
    });
    return &lock;
}
static bool beginWithoutHiZ(id device) {
    bool *hizDisable = (bool *)((char *)(__bridge void *)device + igHizDisableOffset);
    pthread_mutex_lock(hizLock());
    bool saved = *hizDisable;
    *hizDisable = true;
    return saved;
}
static void endWithoutHiZ(id device, bool saved) {
    *(bool *)((char *)(__bridge void *)device + igHizDisableOffset) = saved;
    pthread_mutex_unlock(hizLock());
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth texture with several levels/slices created without HiZ\n");
}

// 36. Multisampled Stencil8 textures on the 12.x Intel driver: render passes write their stencil right, but shaders read
// it wrong. The sampler addresses only part of the surface: past the largest power of two below the width, most rows read
// the left half again (a 4x 256x128 texture: 14464 of 32768 texels wrong). ANGLE reads it that way to resolve or blit a
// GL_STENCIL_INDEX8 multisampled renderbuffer (dEQP fbomultisample stencil_index8). The stencil of
// Depth32Float_Stencil8 reads right at every size, also as a stencil-only attachment drawn with a pipeline that says
// Stencil8, so multisampled Stencil8 textures made on the device are created as Depth32Float_Stencil8 (5 bytes a sample
// instead of 1), and Stencil8 views of them become X32_Stencil8 views. The texture reports Depth32Float_Stencil8; ANGLE
// then makes its stencil view from that by itself. Heap textures are left alone (the heap was sized for Stencil8).
// MTLSHIM_MSAA_STENCIL8=0 turns it off. Test: s40.
static MTLTextureDescriptor *sampleableStencilStandIn(MTLTextureDescriptor *descriptor) {
    if (descriptor.pixelFormat != MTLPixelFormatStencil8 || descriptor.sampleCount <= 1) return nil;
    const char *setting = getenv("MTLSHIM_MSAA_STENCIL8");
    if (setting && !strcmp(setting, "0")) return nil;
    MTLTextureDescriptor *standIn = [descriptor copy];
    standIn.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    standIn.usage |= MTLTextureUsagePixelFormatView;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] multisampled Stencil8 texture created as Depth32Float_Stencil8\n");
    return standIn;
}
static MTLPixelFormat sampleableStencilView(id texture, MTLPixelFormat format) {
    if (format != MTLPixelFormatStencil8) return format;
    id<MTLTexture> t = texture;
    return t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && t.sampleCount > 1 ? MTLPixelFormatX32_Stencil8 : format;
}

static id igNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) RETURNS_RETAINED;
static id igNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    MTLTextureDescriptor *standIn = sampleableStencilStandIn(descriptor);
    if (standIn) return origIGNewTexture(self, _cmd, standIn);
    if (!igHizDisableOffset || !needsNoHiZ(descriptor)) return origIGNewTexture(self, _cmd, descriptor);
    bool saved = beginWithoutHiZ(self);
    id texture = origIGNewTexture(self, _cmd, descriptor);
    endWithoutHiZ(self, saved);
    return texture;
}

static id igHeapNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) RETURNS_RETAINED;
static id igHeapNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    id device = [(id<MTLHeap>)self device];
    if (!igHizDisableOffset || !needsNoHiZ(descriptor) || ![device isKindOfClass:objc_getClass("MTLIGAccelDevice")])
        return origIGHeapNewTexture(self, _cmd, descriptor);
    bool saved = beginWithoutHiZ(device);
    id texture = origIGHeapNewTexture(self, _cmd, descriptor);
    endWithoutHiZ(device, saved);
    return texture;
}

// Items 22 and 36 (texture creation); 36's views below.
typedef id (*NewViewIMP)(id, SEL, MTLPixelFormat) RETURNS_RETAINED;
typedef id (*NewViewRangeIMP)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange) RETURNS_RETAINED;
static NewViewIMP origIGNewView;
static NewViewRangeIMP origIGNewViewRange;
static id igNewView(id self, SEL _cmd, MTLPixelFormat format) RETURNS_RETAINED;
static id igNewView(id self, SEL _cmd, MTLPixelFormat format) {
    return origIGNewView(self, _cmd, sampleableStencilView(self, format));
}
static id igNewViewRange(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) RETURNS_RETAINED;
static id igNewViewRange(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) {
    return origIGNewViewRange(self, _cmd, sampleableStencilView(self, format), type, levels, slices);
}
static void intelDepthWithoutHiZ(void) {
    Class device = objc_getClass("MTLIGAccelDevice");
    Ivar hiz = device ? class_getInstanceVariable(device, "bHizDisable") : NULL;
    if (origIGNewTexture || !definesMethod("MTLIGAccelDevice", "newTextureWithDescriptor:")) return;
    if (hiz && !strcmp(ivar_getTypeEncoding(hiz), "B")) igHizDisableOffset = ivar_getOffset(hiz);
    origIGNewTexture = (NewTextureIMP)swizzle("MTLIGAccelDevice", "newTextureWithDescriptor:", (IMP)igNewTexture);
    if (igHizDisableOffset && definesMethod("MTLIGAccelHeap", "newTextureWithDescriptor:"))
        origIGHeapNewTexture = (NewTextureIMP)swizzle("MTLIGAccelHeap", "newTextureWithDescriptor:", (IMP)igHeapNewTexture);
    if (definesMethod("MTLIGAccelTexture", "newTextureViewWithPixelFormat:"))
        origIGNewView = (NewViewIMP)swizzle("MTLIGAccelTexture", "newTextureViewWithPixelFormat:", (IMP)igNewView);
    if (definesMethod("MTLIGAccelTexture", "newTextureViewWithPixelFormat:textureType:levels:slices:"))
        origIGNewViewRange = (NewViewRangeIMP)swizzle("MTLIGAccelTexture", "newTextureViewWithPixelFormat:textureType:levels:slices:", (IMP)igNewViewRange);
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] Intel textures: HiZ fix %s, multisampled Stencil8 stand-in on, views %s/%s\n", igHizDisableOffset ? "on" : "off",
                origIGNewView ? "on" : "off", origIGNewViewRange ? "on" : "off");
}

static BOOL definesMethod(const char *cls, const char *sel);
static IMP swizzle(const char *cls, const char *sel, IMP imp);

// Driver classes come from the driver bundles, which load with the first device: patched when a device is first seen.
// 27. Blits into depth and stencil on the 12.x Intel driver: render passes don't see what a blit wrote there. Stencil
// copied in (copyFromBuffer:...toTexture: with StencilFromDepthStencil, copyFromTexture:...toTexture:) reads back right
// with a blit, but a later render pass still tests against the old stencil; depth copied into a small texture that keeps
// HiZ (item 22; 4x4 here, 8x8 and larger were right) after a render pass cleared it still tests as the cleared value. ANGLE copies stencil that way on Intel GPUs,
// so glBlitFramebuffer lost it. When a blit encoder that wrote into such a texture (a single-sample render target) ends,
// each region is read back into a buffer with a blit and written again by a render pass: depth by a fragment function's
// depth output, stencil cleared and then set one bit per draw (these GPUs have no stencil output). Test: s32.
typedef id (*BlitEncoderIMP)(id, SEL);
typedef void (*BufferToTextureIMP)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
typedef void (*BufferToTextureOptionsIMP)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin,
                                          MTLBlitOption);
typedef void (*TextureToTextureIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
typedef void (*TextureToTextureOptionsIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin,
                                           MTLBlitOption);
static BlitEncoderIMP origIGBlitEncoder;
static EndEncodingIMP origIGBlitEndEncoding;
static BufferToTextureIMP origIGBufferToTexture;
static BufferToTextureOptionsIMP origIGBufferToTextureOptions;
static TextureToTextureIMP origIGTextureToTexture;
static TextureToTextureOptionsIMP origIGTextureToTextureOptions;
// 37. Stencil copied between a buffer and mip level 1 or higher on the 12.x Intel driver, when the buffer offset or
// bytesPerRow isn't a multiple of 256: some texels come from their left neighbour (at mip 2 of a 20x16 texture, the 5th
// texel of each row reads or writes as the 4th), for Stencil8 and the stencil of depth/stencil formats alike. Dawn
// copies a tight buffer's last row on its own with bytesPerRow = its width, so WebGPU CTS
// image_copy rowsPerImage_and_bytesPerRow_depth_stencil lost the last texel (9 cases). Copies at level 0, and texture to
// texture copies at any level, are right. Such copies go through a level-0 temporary texture of the same format: out of
// the level by a texture copy, then to the buffer; or into the temporary (filled from the level first, which keeps the
// depth of a depth/stencil texture) and back by a texture copy, which item 27 sees. MTLSHIM_STENCIL_COPY=0 turns it off.
// Test: s41.
typedef void (*TextureToBufferIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger);
typedef void (*TextureToBufferOptionsIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger,
                                          MTLBlitOption);
static TextureToBufferIMP origIGTextureToBuffer;
static TextureToBufferOptionsIMP origIGTextureToBufferOptions;

static id<MTLTexture> stencilCopyTemporary(id<MTLTexture> t, NSUInteger level, NSUInteger offset, NSUInteger bytesPerRow, MTLSize size,
                                          MTLBlitOption options) {
    if (!level || !t || t.parentTexture || t.sampleCount > 1 || size.depth != 1 || (!(offset % 256) && !(bytesPerRow % 256))) return nil;
    MTLPixelFormat f = t.pixelFormat;
    BOOL stencil = f == MTLPixelFormatStencil8 || ((options & MTLBlitOptionStencilFromDepthStencil) &&
                                                   (f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8));
    const char *setting = getenv("MTLSHIM_STENCIL_COPY");
    if (!stencil || (setting && !strcmp(setting, "0"))) return nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:size.width height:size.height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> temporary = [t.device newTextureWithDescriptor:d];
    if (temporary && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil copy at level %lu through a level-0 temporary\n", (unsigned long)level);
    return temporary;
}
static void textureCopy(id encoder, id<MTLTexture> from, NSUInteger fromSlice, NSUInteger fromLevel, MTLOrigin fromOrigin, MTLSize size,
                        id<MTLTexture> to, NSUInteger toSlice, NSUInteger toLevel, MTLOrigin toOrigin) {
    [(id<MTLBlitCommandEncoder>)encoder copyFromTexture:from sourceSlice:fromSlice sourceLevel:fromLevel sourceOrigin:fromOrigin sourceSize:size
                                               toTexture:to destinationSlice:toSlice destinationLevel:toLevel destinationOrigin:toOrigin];
}
// Buffer to texture (item 27's hooks call this first): YES if done here.
static BOOL stencilCopyIn(id self, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id<MTLTexture> t,
                          NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options, BOOL withOptions) {
    id<MTLTexture> temporary = stencilCopyTemporary(t, level, offset, row, size, options);
    if (!temporary) return NO;
    const MTLOrigin zero = MTLOriginMake(0, 0, 0);
    textureCopy(self, t, slice, level, origin, size, temporary, 0, 0, zero);
    if (withOptions) origIGBufferToTextureOptions(self, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:),
                                                  buffer, offset, row, image, size, temporary, 0, 0, zero, options);
    else origIGBufferToTexture(self, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                               buffer, offset, row, image, size, temporary, 0, 0, zero);
    textureCopy(self, temporary, 0, 0, zero, size, t, slice, level, origin);
    return YES;
}
static void igTextureToBuffer(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                              NSUInteger offset, NSUInteger row, NSUInteger image) {
    id<MTLTexture> temporary = stencilCopyTemporary(t, level, offset, row, size, MTLBlitOptionNone);
    if (!temporary) return origIGTextureToBuffer(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image);
    textureCopy(self, t, slice, level, origin, size, temporary, 0, 0, MTLOriginMake(0, 0, 0));
    origIGTextureToBuffer(self, _cmd, temporary, 0, 0, MTLOriginMake(0, 0, 0), size, buffer, offset, row, image);
}
static void igTextureToBufferOptions(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                                     NSUInteger offset, NSUInteger row, NSUInteger image, MTLBlitOption options) {
    id<MTLTexture> temporary = stencilCopyTemporary(t, level, offset, row, size, options);
    if (!temporary) return origIGTextureToBufferOptions(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image, options);
    textureCopy(self, t, slice, level, origin, size, temporary, 0, 0, MTLOriginMake(0, 0, 0));
    origIGTextureToBufferOptions(self, _cmd, temporary, 0, 0, MTLOriginMake(0, 0, 0), size, buffer, offset, row, image, options);
}
static void stencilCopies(void) {
    static const char *const kTextureToBuffer =
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:";
    char withOptions[256];
    if (origIGTextureToBuffer || !definesMethod("MTLIGAccelBlitCommandEncoder", kTextureToBuffer)) return;
    origIGTextureToBuffer = (TextureToBufferIMP)swizzle("MTLIGAccelBlitCommandEncoder", kTextureToBuffer, (IMP)igTextureToBuffer);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kTextureToBuffer);
    if (definesMethod("MTLIGAccelBlitCommandEncoder", withOptions))
        origIGTextureToBufferOptions = (TextureToBufferOptionsIMP)swizzle("MTLIGAccelBlitCommandEncoder", withOptions, (IMP)igTextureToBufferOptions);
}

static const void *kBlitCommandBuffer = &kBlitCommandBuffer, *kPendingDepthStencil = &kPendingDepthStencil;
enum { kRewriteDepth = 1, kRewriteStencil = 2 };

static BOOL keepsHiZ(id<MTLTexture> t) {  // item 22 creates these depth textures without it
    return !origIGNewTexture || (t.mipmapLevelCount == 1 && t.arrayLength == 1 && t.textureType == MTLTextureType2D);
}

// What a blit into `t` with `options` needs rewritten (kRewriteDepth | kRewriteStencil), 0 for nothing
static unsigned depthStencilRewrite(id<MTLTexture> t, MTLBlitOption options) {
    if (!t || t.parentTexture || t.sampleCount > 1 || !(t.usage & MTLTextureUsageRenderTarget) || t.textureType == MTLTextureType3D) return 0;
    switch (t.pixelFormat) {
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
            return keepsHiZ(t) ? kRewriteDepth : 0;
        case MTLPixelFormatStencil8:
            return kRewriteStencil;
        case MTLPixelFormatDepth32Float_Stencil8: {
            BOOL depth = !(options & MTLBlitOptionStencilFromDepthStencil), stencil = !(options & MTLBlitOptionDepthFromDepthStencil);
            return (depth && keepsHiZ(t) ? kRewriteDepth : 0) | (stencil ? kRewriteStencil : 0);
        }
        default:
            return 0;
    }
}

static void noteDepthStencilWrite(id encoder, id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size,
                                  MTLBlitOption options) {
    unsigned what = depthStencilRewrite(t, options);
    // Not for stencil textures with several levels or slices: render passes on those go through a temporary texture
    // loaded by a blit (item 33), and the rewrite's own render passes there would break them.
    if (t.mipmapLevelCount > 1 || t.arrayLength > 1) what &= ~kRewriteStencil;
    if (!what || !size.width || !size.height || !objc_getAssociatedObject(encoder, kBlitCommandBuffer)) return;
    NSMutableArray *pending = objc_getAssociatedObject(encoder, kPendingDepthStencil);
    if (!pending) objc_setAssociatedObject(encoder, kPendingDepthStencil, pending = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *last = pending.lastObject;  // the driver's variant without options may call the one with them
    MTLOrigin lastOrigin;
    MTLSize lastSize;
    if (last) [last[3] getValue:&lastOrigin], [last[4] getValue:&lastSize];
    if (last && last[0] == t && [last[1] unsignedIntegerValue] == slice && [last[2] unsignedIntegerValue] == level &&
        !memcmp(&lastOrigin, &origin, sizeof origin) && !memcmp(&lastSize, &size, sizeof size)) {
        pending[pending.count - 1] = @[t, @(slice), @(level), last[3], last[4], @([last[5] unsignedIntValue] | what)];
        return;
    }
    [pending addObject:@[t, @(slice), @(level), [NSValue valueWithBytes:&origin objCType:@encode(MTLOrigin)],
                         [NSValue valueWithBytes:&size objCType:@encode(MTLSize)], @(what)]];
}

static id igBlitEncoder(id self, SEL _cmd) {
    id encoder = origIGBlitEncoder(self, _cmd);
    if (encoder) objc_setAssociatedObject(encoder, kBlitCommandBuffer, self, OBJC_ASSOCIATION_ASSIGN);  // ends before its buffer
    return encoder;
}
static void igBufferToTexture(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                              NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    if (stencilCopyIn(self, buffer, offset, row, image, size, t, slice, level, origin, MTLBlitOptionNone, NO)) return;  // item 37
    origIGBufferToTexture(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin);
    noteDepthStencilWrite(self, t, slice, level, origin, size, MTLBlitOptionNone);
}
static void igBufferToTextureOptions(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                                     NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    if (stencilCopyIn(self, buffer, offset, row, image, size, t, slice, level, origin, options, YES)) return;  // item 37
    origIGBufferToTextureOptions(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin, options);
    noteDepthStencilWrite(self, t, slice, level, origin, size, options);
}
static void igTextureToTexture(id self, SEL _cmd, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, MTLOrigin sourceOrigin, MTLSize size,
                               id t, NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    origIGTextureToTexture(self, _cmd, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin);
    noteDepthStencilWrite(self, t, slice, level, origin, size, MTLBlitOptionNone);
}
static void igTextureToTextureOptions(id self, SEL _cmd, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, MTLOrigin sourceOrigin,
                                      MTLSize size, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    origIGTextureToTextureOptions(self, _cmd, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin, options);
    noteDepthStencilWrite(self, t, slice, level, origin, size, options);
}

// Pipelines writing depth (from a float or ushort buffer) or one stencil bit (from a byte buffer) per pixel of a region
// at buffer(0) {x, y, width}; key: kind | pixel format << 8.
static id<MTLRenderPipelineState> depthStencilWriter(id<MTLDevice> device, MTLPixelFormat format, int kind) {
    static NSMutableDictionary *pipelines;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%p-%lu-%d", device, (unsigned long)format, kind];
    os_unfair_lock_lock(&lock);
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    id<MTLRenderPipelineState> pipeline = pipelines[key];
    os_unfair_lock_unlock(&lock);
    if (pipeline) return pipeline;
    static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Region { uint x, y, width; };\n"
        "struct Depth { float value [[depth(any)]]; };\n"
        "vertex float4 fullScreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
        "static uint at(float4 p, constant Region &r) { return (uint(p.y) - r.y) * r.width + (uint(p.x) - r.x); }\n"
        "fragment Depth depth32(float4 p [[position]], constant Region &r [[buffer(0)]], device const float *d [[buffer(1)]]) { return { d[at(p, r)] }; }\n"
        "fragment Depth depth16(float4 p [[position]], constant Region &r [[buffer(0)]], device const ushort *d [[buffer(1)]]) {\n"
        "    return { float(d[at(p, r)]) / 65535.0f };\n"
        "}\n"
        "fragment void stencilBit(float4 p [[position]], constant Region &r [[buffer(0)]], device const uchar *s [[buffer(1)]],\n"
        "                         constant int &bit [[buffer(2)]]) {\n"
        "    if (bit >= 0 && !((s[at(p, r)] >> bit) & 1)) discard_fragment();\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"fullScreen"];
    descriptor.fragmentFunction = [library newFunctionWithName:kind == kRewriteStencil ? @"stencilBit"
                                                               : format == MTLPixelFormatDepth16Unorm ? @"depth16" : @"depth32"];
    if (format != MTLPixelFormatStencil8) descriptor.depthAttachmentPixelFormat = format;
    if (format == MTLPixelFormatStencil8 || format == MTLPixelFormatDepth32Float_Stencil8) descriptor.stencilAttachmentPixelFormat = format;
    pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth/stencil rewrite pipeline: %s\n", error.localizedDescription.UTF8String);
    os_unfair_lock_lock(&lock);
    if (pipeline) pipelines[key] = pipeline;
    os_unfair_lock_unlock(&lock);
    return pipeline;
}

static id<MTLDepthStencilState> depthStencilWriteState(id<MTLDevice> device, BOOL depth, uint32_t stencilMask) {
    MTLDepthStencilDescriptor *descriptor = [MTLDepthStencilDescriptor new];
    descriptor.depthCompareFunction = MTLCompareFunctionAlways;
    descriptor.depthWriteEnabled = depth;
    if (stencilMask) {
        MTLStencilDescriptor *stencil = [MTLStencilDescriptor new];
        stencil.stencilCompareFunction = MTLCompareFunctionAlways;
        stencil.depthStencilPassOperation = MTLStencilOperationReplace;
        stencil.writeMask = stencilMask;
        descriptor.frontFaceStencil = descriptor.backFaceStencil = stencil;
    }
    return [device newDepthStencilStateWithDescriptor:descriptor];
}

static void rewriteDepthStencil(id<MTLCommandBuffer> commandBuffer, NSArray *pending) {
    for (NSArray *entry in pending) {
        id<MTLTexture> t = entry[0];
        NSUInteger slice = [entry[1] unsignedIntegerValue], level = [entry[2] unsignedIntegerValue];
        MTLOrigin origin;
        MTLSize size;
        [entry[3] getValue:&origin];
        [entry[4] getValue:&size];
        unsigned what = [entry[5] unsignedIntValue];
        id<MTLDevice> device = t.device;
        BOOL combined = t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
        NSUInteger depthBytes = t.pixelFormat == MTLPixelFormatDepth16Unorm ? 2 : 4;
        id<MTLRenderPipelineState> depthPipeline = what & kRewriteDepth ? depthStencilWriter(device, t.pixelFormat, kRewriteDepth) : nil;
        id<MTLRenderPipelineState> stencilPipeline = what & kRewriteStencil ? depthStencilWriter(device, t.pixelFormat, kRewriteStencil) : nil;
        id<MTLBuffer> depth = depthPipeline ? [device newBufferWithLength:size.width * size.height * depthBytes options:MTLResourceStorageModePrivate] : nil;
        id<MTLBuffer> stencil = stencilPipeline ? [device newBufferWithLength:size.width * size.height options:MTLResourceStorageModePrivate] : nil;
        if (!depth && !stencil) continue;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (depth)
            [blit copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:depth destinationOffset:0
                destinationBytesPerRow:size.width * depthBytes destinationBytesPerImage:size.width * size.height * depthBytes
                               options:combined ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
        if (stencil)
            [blit copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:stencil destinationOffset:0
                destinationBytesPerRow:size.width destinationBytesPerImage:size.width * size.height
                               options:combined ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionNone];
        [blit endEncoding];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (t.pixelFormat != MTLPixelFormatStencil8) {
            pass.depthAttachment.texture = t;
            pass.depthAttachment.level = level;
            pass.depthAttachment.slice = slice;
            pass.depthAttachment.loadAction = MTLLoadActionLoad;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (t.pixelFormat == MTLPixelFormatStencil8 || combined) {
            pass.stencilAttachment.texture = t;
            pass.stencilAttachment.level = level;
            pass.stencilAttachment.slice = slice;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        const uint32_t region[3] = {(uint32_t)origin.x, (uint32_t)origin.y, (uint32_t)size.width};
        [encoder setScissorRect:(MTLScissorRect){origin.x, origin.y, size.width, size.height}];
        [encoder setFragmentBytes:region length:sizeof region atIndex:0];
        if (depth) {
            [encoder setRenderPipelineState:depthPipeline];
            [encoder setDepthStencilState:depthStencilWriteState(device, YES, 0)];
            [encoder setFragmentBuffer:depth offset:0 atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        if (stencil) {
            [encoder setRenderPipelineState:stencilPipeline];
            [encoder setFragmentBuffer:stencil offset:0 atIndex:1];
            for (int bit = -1; bit < 8; bit++) {  // -1: clear the region, then one bit per draw
                [encoder setDepthStencilState:depthStencilWriteState(device, NO, bit < 0 ? 0xFF : 1u << bit)];
                [encoder setStencilReferenceValue:bit < 0 ? 0 : 0xFF];
                [encoder setFragmentBytes:&bit length:sizeof bit atIndex:2];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
        }
        [encoder endEncoding];
        if (getenv("MTLSHIM_VERBOSE"))
            shimLog("[mtlshim] blit into %s: %lux%lu region written again by a render pass\n",
                    what == (kRewriteDepth | kRewriteStencil) ? "depth and stencil" : what == kRewriteDepth ? "depth" : "stencil",
                    (unsigned long)size.width, (unsigned long)size.height);
    }
}

static void igBlitEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingDepthStencil);
    id<MTLCommandBuffer> commandBuffer = objc_getAssociatedObject(self, kBlitCommandBuffer);
    origIGBlitEndEncoding(self, _cmd);
    objc_setAssociatedObject(self, kBlitCommandBuffer, nil, OBJC_ASSOCIATION_ASSIGN);
    if (!pending) return;
    objc_setAssociatedObject(self, kPendingDepthStencil, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (commandBuffer) rewriteDepthStencil(commandBuffer, pending);
}

static void blitsIntoDepthStencil(void) {
    static const char *const kBufferToTexture =
        "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";
    static const char *const kTextureToTexture =
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";
    char withOptions[256];
    const char *setting = getenv("MTLSHIM_DEPTH_STENCIL_BLITS");
    if (origIGBlitEndEncoding || (setting && !strcmp(setting, "0"))) return;
    if (!definesMethod("MTLIGAccelCommandBuffer", "blitCommandEncoder") || !definesMethod("MTLIGAccelBlitCommandEncoder", "endEncoding") ||
        !definesMethod("MTLIGAccelBlitCommandEncoder", kBufferToTexture) || !definesMethod("MTLIGAccelBlitCommandEncoder", kTextureToTexture))
        return;
    origIGBlitEncoder = (BlitEncoderIMP)swizzle("MTLIGAccelCommandBuffer", "blitCommandEncoder", (IMP)igBlitEncoder);
    origIGBlitEndEncoding = (EndEncodingIMP)swizzle("MTLIGAccelBlitCommandEncoder", "endEncoding", (IMP)igBlitEndEncoding);
    origIGBufferToTexture = (BufferToTextureIMP)swizzle("MTLIGAccelBlitCommandEncoder", kBufferToTexture, (IMP)igBufferToTexture);
    origIGTextureToTexture = (TextureToTextureIMP)swizzle("MTLIGAccelBlitCommandEncoder", kTextureToTexture, (IMP)igTextureToTexture);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kBufferToTexture);
    if (definesMethod("MTLIGAccelBlitCommandEncoder", withOptions))
        origIGBufferToTextureOptions = (BufferToTextureOptionsIMP)swizzle("MTLIGAccelBlitCommandEncoder", withOptions, (IMP)igBufferToTextureOptions);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kTextureToTexture);
    if (definesMethod("MTLIGAccelBlitCommandEncoder", withOptions))
        origIGTextureToTextureOptions = (TextureToTextureOptionsIMP)swizzle("MTLIGAccelBlitCommandEncoder", withOptions, (IMP)igTextureToTextureOptions);
}

// 28. Argument buffers on the 12.x Intel driver are emulated (tier 1), and the emulated encoder's
// setBuffer:offset:atIndex: and setBuffers:offsets:withRange: read the buffer's GPU address without checking for nil:
// encoding nil into an unused slot, which Metal allows, dereferences null. Cycles (Blender 3.6's GPU renderer) does that
// before every kernel, so a GPU render crashed Blender. A nil buffer gets a cleared slot instead (no buffer, offset 0,
// GPU address 0), what the driver's slot holds before anything is encoded. Textures and samplers store only the object,
// so nil is already fine there.
typedef void (*ArgSetBufferIMP)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*ArgSetBuffersIMP)(id, SEL, const __unsafe_unretained id *, const NSUInteger *, NSRange);
static ArgSetBufferIMP origIGArgSetBuffer;
static ArgSetBuffersIMP origIGArgSetBuffers;
static ptrdiff_t igArgDestinationOffset;
static Ivar igArgLayout;

static void clearArgumentBufferSlot(id self, NSUInteger index) {
    char *destination = *(char **)((char *)(__bridge void *)self + igArgDestinationOffset);
    id layout = object_getIvar(self, igArgLayout);
    if (!destination || !layout) return;  // no argument buffer set: the driver would crash on a real buffer too
    NSUInteger offset = ((NSUInteger (*)(id, SEL, NSUInteger))objc_msgSend)(layout, sel_registerName("offsetForBuffer:"), index);
    memset(destination + offset, 0, 3 * sizeof(uint64_t));  // buffer, offset, GPU address
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] nil buffer encoded into argument buffer slot %lu\n", (unsigned long)index);
}

static void igArgSetBuffer(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger index) {
    if (buffer) origIGArgSetBuffer(self, _cmd, buffer, offset, index);
    else clearArgumentBufferSlot(self, index);
}

static void igArgSetBuffers(id self, SEL _cmd, const __unsafe_unretained id *buffers, const NSUInteger *offsets, NSRange range) {
    bool anyNil = false;
    for (NSUInteger i = 0; i < range.length; i++) anyNil |= !buffers[i];
    if (!anyNil) {
        origIGArgSetBuffers(self, _cmd, buffers, offsets, range);
        return;
    }
    for (NSUInteger i = 0; i < range.length; i++) {
        if (buffers[i]) origIGArgSetBuffer(self, @selector(setBuffer:offset:atIndex:), buffers[i], offsets[i], range.location + i);
        else clearArgumentBufferSlot(self, range.location + i);
    }
}

static void nilArgumentBuffers(void) {
    static const char *const kClass = "MTLIGEmulationIndirectArgumentEncoder";
    Class c = objc_getClass(kClass);
    Ivar destination = c ? class_getInstanceVariable(c, "_destination") : NULL;
    Ivar layout = c ? class_getInstanceVariable(c, "_emulationLayout") : NULL;
    if (origIGArgSetBuffer || !destination || !layout || strcmp(ivar_getTypeEncoding(destination), "*") ||
        ivar_getTypeEncoding(layout)[0] != '@' || !definesMethod(kClass, "setBuffer:offset:atIndex:") ||
        !definesMethod(kClass, "setBuffers:offsets:withRange:"))
        return;
    igArgDestinationOffset = ivar_getOffset(destination);
    igArgLayout = layout;
    origIGArgSetBuffer = (ArgSetBufferIMP)swizzle(kClass, "setBuffer:offset:atIndex:", (IMP)igArgSetBuffer);
    origIGArgSetBuffers = (ArgSetBuffersIMP)swizzle(kClass, "setBuffers:offsets:withRange:", (IMP)igArgSetBuffers);
}

// 30. Integer cube textures with 1x1 or 2x2 faces sample as 0 in vertex and fragment functions on the 12.x Intel driver
// (compute kernels and float formats are right). The driver's sampler state asks for seamless cube addressing
// (CubeSurfaceControlMode = override), and the sampler can't do that for integer formats on faces this small. Integer
// textures are only sampled with nearest filtering, where seamless addressing changes nothing (a nearest texel never
// spans a face edge), so samplers whose min and mag filters are nearest get the programmed (clamped) addressing. The
// WebGL suite uploads such faces from canvases and ImageData (integer-cubemap-texture-sampling, tex-2d-*ui-*_integer-*:
// about 2400 failures in Chrome and Safari). MTLSHIM_NEAREST_CUBE_CLAMP=0 turns it off.
typedef void (*InitSamplerStateIMP)(id, SEL, id);
static InitSamplerStateIMP origIGInitSamplerState;
static ptrdiff_t igSamplerStateOffset = -1;

static void igInitSamplerState(id self, SEL _cmd, id descriptor) {
    origIGInitSamplerState(self, _cmd, descriptor);
    uint32_t *state = (uint32_t *)((char *)(__bridge void *)self + igSamplerStateOffset);
    BOOL nearest = !((state[0] >> 14) & 7) && !((state[0] >> 17) & 7);  // MinModeFilter, MagModeFilter
    if (nearest && (state[1] & 1)) {
        state[1] &= ~1u;  // CubeSurfaceControlMode: programmed
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] nearest sampler: programmed cube addressing\n");
    }
}

static void nearestCubeClamp(void) {
    static const char kLayout[] = "{SGfxSamplerState=\"AnisotropicAlgorithm\"b1\"TextureLODBias\"b13\"MinModeFilter\"b3\"MagModeFilter\"b3";
    const char *setting = getenv("MTLSHIM_NEAREST_CUBE_CLAMP");
    Class c = objc_getClass("MTLIGSampler");
    Ivar state = c ? class_getInstanceVariable(c, "samplerState") : NULL;
    if (origIGInitSamplerState || (setting && !strcmp(setting, "0")) || !state ||
        strncmp(ivar_getTypeEncoding(state), kLayout, sizeof kLayout - 1) ||
        !strstr(ivar_getTypeEncoding(state), "\"SamplerDisable\"b1\"CubeSurfaceControlMode\"b1") || !definesMethod("MTLIGSampler", "initializeSamplerState:"))
        return;
    igSamplerStateOffset = ivar_getOffset(state);
    origIGInitSamplerState = (InitSamplerStateIMP)swizzle("MTLIGSampler", "initializeSamplerState:", (IMP)igInitSamplerState);
}

// 31. The 12.x Intel driver's encoders pack the LOD clamps of setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex: and
// the like (vertex, fragment, tile and compute stages, one sampler or a range) into the sampler state's 4.8 fixed-point
// LOD fields without saturating them, so they wrap modulo 16: 1000 reads as 8, 20 as 4, -3 as 13. Sampler descriptors'
// clamps are saturated (newSamplerStateWithDescriptor:). ANGLE binds every texture's sampler with GL's TEXTURE_MIN_LOD /
// TEXTURE_MAX_LOD this way, by default 0 and 1000, so in Chrome and Safari WebGL never sampled a mip level above 8
// (textures over 256 texels, minified: conformance2/glsl3/texture-bias.html). The clamps are clamped to the fields' range
// [0, 4095 / 256] first. MTLSHIM_ENCODER_LOD_CLAMP=0 turns it off. Test: s35.
typedef void (*SetSamplerLodIMP)(id, SEL, id, float, float, NSUInteger);
typedef void (*SetSamplersLodIMP)(id, SEL, const id __unsafe_unretained *, const float *, const float *, NSRange);
enum { kLodVertex, kLodFragment, kLodTile, kLodCompute, kLodStages };
static SetSamplerLodIMP origIGSamplerLod[kLodStages];
static SetSamplersLodIMP origIGSamplersLod[kLodStages];

static float lodField(float lod) {  // NaN: 0
    return lod > 0 ? (lod < 4095.0f / 256 ? lod : 4095.0f / 256) : 0;
}
static void igSamplersLod(int stage, id self, SEL _cmd, const id __unsafe_unretained *samplers, const float *mins, const float *maxs,
                          NSRange range) {
    float clampedMins[32], clampedMaxs[32];
    if (!mins || !maxs || range.length > 32) return origIGSamplersLod[stage](self, _cmd, samplers, mins, maxs, range);
    for (NSUInteger i = 0; i < range.length; i++) clampedMins[i] = lodField(mins[i]), clampedMaxs[i] = lodField(maxs[i]);
    origIGSamplersLod[stage](self, _cmd, samplers, clampedMins, clampedMaxs, range);
}
#define LOD_CLAMP_HOOKS(stage)                                                                                                      \
    static void igSamplerLod##stage(id self, SEL _cmd, id sampler, float min, float max, NSUInteger index) {                     \
        origIGSamplerLod[stage](self, _cmd, sampler, lodField(min), lodField(max), index);                                         \
    }                                                                                                                               \
    static void igSamplersLod##stage(id self, SEL _cmd, const id __unsafe_unretained *samplers, const float *mins, const float *maxs, \
                                     NSRange range) {                                                                               \
        igSamplersLod(stage, self, _cmd, samplers, mins, maxs, range);                                                              \
    }
LOD_CLAMP_HOOKS(kLodVertex)
LOD_CLAMP_HOOKS(kLodFragment)
LOD_CLAMP_HOOKS(kLodTile)
LOD_CLAMP_HOOKS(kLodCompute)

static void encoderLodClamps(void) {
    static const struct { const char *cls, *one, *range; IMP hookOne, hookRange; } kHooks[kLodStages] = {
        {"MTLIGAccelRenderCommandEncoder", "setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:",
         "setVertexSamplerStates:lodMinClamps:lodMaxClamps:withRange:", (IMP)igSamplerLodkLodVertex, (IMP)igSamplersLodkLodVertex},
        {"MTLIGAccelRenderCommandEncoder", "setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:",
         "setFragmentSamplerStates:lodMinClamps:lodMaxClamps:withRange:", (IMP)igSamplerLodkLodFragment, (IMP)igSamplersLodkLodFragment},
        {"MTLIGAccelRenderCommandEncoder", "setTileSamplerState:lodMinClamp:lodMaxClamp:atIndex:",
         "setTileSamplerStates:lodMinClamps:lodMaxClamps:withRange:", (IMP)igSamplerLodkLodTile, (IMP)igSamplersLodkLodTile},
        {"MTLIGAccelComputeCommandEncoder", "setSamplerState:lodMinClamp:lodMaxClamp:atIndex:",
         "setSamplerStates:lodMinClamps:lodMaxClamps:withRange:", (IMP)igSamplerLodkLodCompute, (IMP)igSamplersLodkLodCompute},
    };
    const char *setting = getenv("MTLSHIM_ENCODER_LOD_CLAMP");
    if (setting && !strcmp(setting, "0")) return;
    for (int stage = 0; stage < kLodStages; stage++) {
        if (!origIGSamplerLod[stage] && definesMethod(kHooks[stage].cls, kHooks[stage].one))
            origIGSamplerLod[stage] = (SetSamplerLodIMP)swizzle(kHooks[stage].cls, kHooks[stage].one, kHooks[stage].hookOne);
        if (!origIGSamplersLod[stage] && definesMethod(kHooks[stage].cls, kHooks[stage].range))
            origIGSamplersLod[stage] = (SetSamplersLodIMP)swizzle(kHooks[stage].cls, kHooks[stage].range, kHooks[stage].hookRange);
    }
}

// 32. The 12.x Intel driver returns nil from newTextureViewWithPixelFormat:textureType:levels:slices:swizzle: (family 1 has
// no texture swizzle). Item 11 tells Chromium that a lone Intel iGPU is family 2, which Dawn (WebGPU) takes to mean
// swizzled views work, and Dawn makes every depth/stencil view it needs (a stencil-only view of Depth32Float_Stencil8,
// which backs stencil8; depth textures bound to shaders) with the swizzle (R, 0, 0, 1): nil, and the device is lost
// ("Failed to create MTLTexture view"). ANGLE is told not to use swizzles (item 11). Where the driver says nil and the
// swizzle changes nothing a shader can see, the view is made without it: the identity; a format's own channels (R001 for
// one-channel formats, RG01 for two); and R001 for depth and stencil formats, which shaders read in R only (sampling
// one as float, G, B and A then come from the driver instead of 0, 0, 1). Other swizzles still get nil.
// MTLSHIM_SWIZZLE_VIEW=0 turns it off. Test: s36.
typedef id (*SwizzleViewIMP)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels) RETURNS_RETAINED;
static SwizzleViewIMP origIGSwizzleView;

static int channelCount(MTLPixelFormat f) {  // 1, 2, or 0 (other / not known)
    switch (f) {
        case MTLPixelFormatA8Unorm: return 0;
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint:
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float:
            return 1;
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float:
            return 2;
        default:
            return 0;
    }
}
static BOOL depthOrStencil(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float: case MTLPixelFormatStencil8: case MTLPixelFormatDepth24Unorm_Stencil8:
        case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatX32_Stencil8: case MTLPixelFormatX24_Stencil8:
            return YES;
        default:
            return NO;
    }
}
static BOOL swizzleIs(MTLTextureSwizzleChannels s, MTLTextureSwizzle r, MTLTextureSwizzle g, MTLTextureSwizzle b, MTLTextureSwizzle a) {
    return s.red == r && s.green == g && s.blue == b && s.alpha == a;
}
static id igSwizzleView(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) RETURNS_RETAINED;
static id igSwizzleView(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) {
    format = sampleableStencilView(self, format);  // item 36
    id view = origIGSwizzleView(self, _cmd, format, type, levels, slices, swizzle);
    if (view) return view;
    int channels = channelCount(format);
    BOOL r001 = swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleOne);
    BOOL harmless = swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha) ||
                    (r001 && (channels == 1 || depthOrStencil(format))) ||
                    (channels == 2 && swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleZero, MTLTextureSwizzleOne));
    if (!harmless) return nil;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] swizzled texture view: made without the swizzle\n");
    return ((NewViewRangeIMP)objc_msgSend)(
        self, @selector(newTextureViewWithPixelFormat:textureType:levels:slices:), format, type, levels, slices);
}

static void swizzledViews(void) {
    const char *setting = getenv("MTLSHIM_SWIZZLE_VIEW");
    if (origIGSwizzleView || (setting && !strcmp(setting, "0")) ||
        !definesMethod("MTLIGAccelTexture", "newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:"))
        return;
    origIGSwizzleView = (SwizzleViewIMP)swizzle("MTLIGAccelTexture", "newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:",
                                                (IMP)igSwizzleView);
}

// 35. Metal Performance Shaders' image statistics (MPSImageStatisticsMinAndMax and MeanAndVariance; Core Image's
// CIAreaMinMax and the filters built on it) finish with a compute_final_*_statistics kernel that reduces one value per
// thread through threadgroup memory and always folds in tg[tid + 16], tg[tid + 8], ...: it assumes at least 32 threads.
// MPS dispatches it with the pipeline's threadExecutionWidth threads and memory for that many, which on these Intel GPUs
// is 16: the first step reads past the threadgroup memory as 0, so minimums came out 0, maximums of negative data 0 and
// means and variances wrong. On the Intel GPU, a pipeline MPS labels compute_final_..._statistics that is dispatched with
// fewer than 32 threads in one row gets 32, and its threadgroup memory grows to match (the kernels loop over any width).
// Test: s39. MTLSHIM_MPS_STATISTICS=0 turns it off.
typedef void (*SetComputePipelineIMP)(id, SEL, id);
typedef void (*SetThreadgroupMemoryIMP)(id, SEL, NSUInteger, NSUInteger);
typedef void (*DispatchThreadgroupsIMP)(id, SEL, MTLSize, MTLSize);
static SetComputePipelineIMP origIGSetComputePipeline;
static SetThreadgroupMemoryIMP origIGSetThreadgroupMemory;
static DispatchThreadgroupsIMP origIGDispatchThreadgroups;
static __thread void *statisticsEncoder;           // the encoder whose pipeline is such a kernel, on this thread
static __thread NSUInteger statisticsMemory[4];     // the threadgroup memory lengths it set at indices 0-3

static BOOL mpsStatisticsKernel(id<MTLComputePipelineState> pipeline) {
    NSString *label = pipeline.label;
    return label && [label hasPrefix:@"compute_final_"] && [label hasSuffix:@"_statistics"];
}

static void igSetComputePipeline(id self, SEL _cmd, id pipeline) {
    if (pipeline && mpsStatisticsKernel(pipeline)) {
        if (statisticsEncoder != (__bridge void *)self) memset(statisticsMemory, 0, sizeof statisticsMemory);
        statisticsEncoder = (__bridge void *)self;
    } else if (statisticsEncoder == (__bridge void *)self) {
        statisticsEncoder = NULL;
    }
    origIGSetComputePipeline(self, _cmd, pipeline);
}

static void igSetThreadgroupMemory(id self, SEL _cmd, NSUInteger length, NSUInteger index) {
    if (statisticsEncoder == (__bridge void *)self && index < 4) statisticsMemory[index] = length;
    origIGSetThreadgroupMemory(self, _cmd, length, index);
}

static void igDispatchThreadgroups(id self, SEL _cmd, MTLSize groups, MTLSize threads) {
    if (statisticsEncoder == (__bridge void *)self && threads.width && threads.width < 32 && threads.height == 1 && threads.depth == 1) {
        for (NSUInteger i = 0; i < 4; i++)
            if (statisticsMemory[i]) origIGSetThreadgroupMemory(self, @selector(setThreadgroupMemoryLength:atIndex:), (statisticsMemory[i] * 32 / threads.width + 15) & ~(NSUInteger)15, i);
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MPS statistics reduction dispatched with %lu threads: 32\n", (unsigned long)threads.width);
        threads.width = 32;
    }
    origIGDispatchThreadgroups(self, _cmd, groups, threads);
}

static void mpsStatisticsWidth(void) {
    const char *setting = getenv("MTLSHIM_MPS_STATISTICS");
    if ((setting && !strcmp(setting, "0")) || origIGDispatchThreadgroups) return;
    const char *cls = "MTLIGAccelComputeCommandEncoder";
    if (!definesMethod(cls, "setComputePipelineState:") || !definesMethod(cls, "setThreadgroupMemoryLength:atIndex:") ||
        !definesMethod(cls, "dispatchThreadgroups:threadsPerThreadgroup:"))
        return;
    origIGSetComputePipeline = (SetComputePipelineIMP)swizzle(cls, "setComputePipelineState:", (IMP)igSetComputePipeline);
    origIGSetThreadgroupMemory = (SetThreadgroupMemoryIMP)swizzle(cls, "setThreadgroupMemoryLength:atIndex:", (IMP)igSetThreadgroupMemory);
    origIGDispatchThreadgroups = (DispatchThreadgroupsIMP)swizzle(cls, "dispatchThreadgroups:threadsPerThreadgroup:", (IMP)igDispatchThreadgroups);
}

// 29. WebKit's WebGPU sets GPUMultisampleState.mask with the render pipeline descriptor's sample mask. The 12.x Intel driver
// takes 0 to mean no mask and draws every sample, where nothing should be drawn (WebGPU CTS occlusionQuery sample_mask,
// sampleMask=0), as the 12.5 AMD driver does (AMDBronzeCompat item 7, which only loads with the AMD driver). A bit past the
// last sample of any target isn't 0 to the driver and covers no sample. Only WebKit calls this SPI. Test: s30.
typedef void (*SetSampleMaskIMP)(id, SEL, NSUInteger);
static SetSampleMaskIMP origSetSampleMask;

static void compatSetSampleMask(id self, SEL _cmd, NSUInteger mask) {
    origSetSampleMask(self, _cmd, mask ? mask : 0x100);
}

static void patchDriverClasses(void) {
    if (patched) restoreArgumentEncoders();  // item 14: after the wrapper's initializer
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!origIGRenderEncoder && definesMethod("MTLIGAccelCommandBuffer", "renderCommandEncoderWithDescriptor:") &&
        definesMethod("MTLIGAccelRenderCommandEncoder", "endEncoding")) {
        origIGRenderEncoder = (RenderEncoderIMP)swizzle("MTLIGAccelCommandBuffer", "renderCommandEncoderWithDescriptor:", (IMP)igRenderEncoder);
        origIGRenderEndEncoding = (EndEncodingIMP)swizzle("MTLIGAccelRenderCommandEncoder", "endEncoding", (IMP)igRenderEndEncoding);
    }
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
    intelDepthWithoutHiZ();
    blitsIntoDepthStencil();
    nilArgumentBuffers();
    nearestCubeClamp();
    encoderLodClamps();
    swizzledViews();
    mpsStatisticsWidth();
    stencilCopies();
    stencilViewAlignment();
    // item 29, once the Intel driver is in (WebKit's processes are named by then)
    if (!origSetSampleMask && !strncmp(getprogname(), "com.apple.WebKit", 16) && definesMethod("MTLRenderPipelineDescriptorInternal", "setSampleMask:"))
        origSetSampleMask = (SetSampleMaskIMP)swizzle("MTLRenderPipelineDescriptorInternal", "setSampleMask:", (IMP)compatSetSampleMask);
    if (!origIGFillBuffer && definesMethod("MTLIGAccelBlitCommandEncoder", "fillBuffer:range:value:"))
        origIGFillBuffer = (FillBufferIMP)swizzle("MTLIGAccelBlitCommandEncoder", "fillBuffer:range:value:", (IMP)igFillBuffer);
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

// OCLP's Tahoe wrapper makes supportsFamily: say yes to Mac2 for every GPU in WebKit's processes, when it loads. This library's
// initializer runs first and keeps the real one (then replaces it with compatSupportsFamily).
static BOOL (*realSupportsFamily)(id, SEL, NSInteger);

static BOOL familyTwo(const void *device) {
    SEL selector = @selector(supportsFamily:);
    id object = (__bridge id)device;
    // Metal's API validation layer (MTL_DEBUG_LAYER=1) hands out its own device objects, which aren't _MTLDevices
    if (realSupportsFamily && [object isKindOfClass:objc_getClass("_MTLDevice")]) return realSupportsFamily(object, selector, MTLGPUFamilyMac2);
    return ((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, MTLGPUFamilyMac2);
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

// Macs whose only GPU is a Haswell / Ivy Bridge iGPU (family 1): ANGLE's callers get it as family 2 (item 11).
static BOOL familyOneAsTwo(void) {
    static int state;  // 0 not decided yet, 1 yes, -1 no
    if (!state) {
        const char *setting = getenv("MTLSHIM_ANGLE_MAC2");
        state = (setting && !strcmp(setting, "0")) || anyFamilyTwo() ? -1 : 1;
    }
    return state > 0;
}

// ANGLE reads this when it sets up its Metal features, which comes after its family checks and its model check.
static void disableFeaturesFamilyOneLacks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char kLacking[] = "hasTextureSwizzle:hasStencilAutoResolve:allowRenderpassWithoutAttachment:allowSamplerCompareGradient";
        const char *set = getenv("ANGLE_FEATURE_OVERRIDES_DISABLED");
        char *value = NULL;
        if (set && *set && asprintf(&value, "%s:%s", set, kLacking) < 0) value = NULL;
        setenv("ANGLE_FEATURE_OVERRIDES_DISABLED", value ? value : kLacking, 1);
        free(value);
        if (getenv("MTLSHIM_VERBOSE"))
            shimLog("[mtlshim] ANGLE on a family-1 GPU: ANGLE_FEATURE_OVERRIDES_DISABLED=%s\n", getenv("ANGLE_FEATURE_OVERRIDES_DISABLED"));
    });
}

// Dawn (Chromium's WebGPU) asks `supportsFamily:Apple6 || supportsFamily:Mac2` before it offers the subgroups feature, which
// these GPUs' compiler can't build (simd_sum, simd_ballot and the like abort MTLCompilerService, and Chrome's GPU process
// went down with it during the WebGPU CTS subgroup tests). Right after that it asks Apple7 from the same function, then
// `supportsFamily:Mac2 || supportsFamily:Apple2` (whether to offer texture-component-swizzle); this driver makes no
// swizzled views (item 32 covers only those that change nothing), so pages that used the feature got no texture. Those
// two Mac2 questions get the real answer: one that comes right after an Apple6 question on the same thread from code a
// few bytes away, and one that comes right after such an Apple6, Mac2, Apple7 run. ANGLE asks Apple 1-3 or 7 and then
// Mac2 (its Mac 1 check), from two helper functions far apart, and keeps getting yes.
static __thread NSInteger familiesAsked[3] = {-1, -1, -1};  // the last three questions on this thread, newest first
static __thread uintptr_t familyCallers[3];
static BOOL near(uintptr_t a, uintptr_t b) { return (a > b ? a - b : b - a) < 256; }
static BOOL compatSupportsFamily(id self, SEL _cmd, NSInteger family) {
    BOOL real = realSupportsFamily(self, _cmd, family);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    NSInteger previous = familiesAsked[0];
    uintptr_t previousCaller = familyCallers[0];
    BOOL swizzleCheck = previous == MTLGPUFamilyApple7 && familiesAsked[1] == MTLGPUFamilyMac2 && familiesAsked[2] == MTLGPUFamilyApple6 &&
                        near(familyCallers[0], familyCallers[1]) && near(familyCallers[1], familyCallers[2]);
    for (int i = 2; i > 0; i--) familiesAsked[i] = familiesAsked[i - 1], familyCallers[i] = familyCallers[i - 1];
    familiesAsked[0] = family, familyCallers[0] = caller;
    if (getenv("MTLSHIM_FAMILY_LOG")) {  // debugging: every question, with the one before it on this thread
        Dl_info info;
        BOOL found = dladdr((const void *)caller, &info) && info.dli_fname;
        shimLog("[mtlshim] supportsFamily:%ld (previous %ld) from %s+0x%lx: %d\n", (long)family, (long)previous,
                found ? callerImage((const void *)caller) : "?", found ? (unsigned long)(caller - (uintptr_t)info.dli_fbase) : 0ul, real);
    }
    if (real || family != MTLGPUFamilyMac2 || !fromChromium(__builtin_return_address(0)) || !familyOneAsTwo()) return real;
    if (previous == MTLGPUFamilyApple6 && near(caller, previousCaller)) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Mac2 asked right after Apple6 (Dawn's subgroups check): no\n");
        return real;
    }
    if (swizzleCheck) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Mac2 asked after Dawn's Apple7 check (its texture swizzle check): no\n");
        return real;
    }
    disableFeaturesFamilyOneLacks();
    return YES;
}

static CFTypeRef compatRegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (getenv("MTLSHIM_VERBOSE") && key && CFStringCompare(key, CFSTR("model"), 0) == kCFCompareEqualTo)
        shimLog("[mtlshim] IORegistryEntryCreateCFProperty(model) from %s\n", callerImage(__builtin_return_address(0)));
    if (!value || !key || CFGetTypeID(value) != CFDataGetTypeID() || CFStringCompare(key, CFSTR("model"), 0) != kCFCompareEqualTo)
        return value;
    io_name_t cls;
    if (IOObjectGetClass(entry, cls) != KERN_SUCCESS || strcmp(cls, "IOPlatformExpertDevice") || !fromChromium(__builtin_return_address(0)) ||
        (!anyFamilyTwo() && !familyOneAsTwo()))
        return value;
    if (familyOneAsTwo()) disableFeaturesFamilyOneLacks();
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
// 25. Precompiled libraries built for macOS 15.4 or later (AIR 2.7: iMovie 10.4.4, Safari's ANGLE, apps built with
// Xcode 16.3+). This stack's compiler service runs Sequoia's own compiler (GPUCompiler 32023), which reads AIR 2.7, but
// MetalOld asks it for the macOS 14.2 target (AIR 2.6), so it rejects such a module: "incompatible module ... not
// compatible with the target", then "air version set to 2.7.0 ... but expecting 2.6", and function-constant
// predicates of predicated arguments (__metal_implicit_fc_pred_*) stay unresolved while the triple says 2.7. In
// MTLCompilerService, each AIR 2.7 module is retargeted when the compiler first looks at it (upgradeAIRModule reads
// !air.version first): triple air64_v26-apple-macosx14.0.0, !air.version 2.6.0, !air.language_version Metal 3.1, the
// same changes dortania/MetallibSupportPkg makes when it rebuilds Sequoia's system metallibs for these GPUs. Hooked by
// pointing the 32023 libGPUCompilerImpl images' import slots for llvm::Module::getNamedMetadata at a wrapper (these
// libraries come extracted from a shared cache, with their imports in a "dsce.got" segment that dyld's own
// interposing doesn't reach), LLVM resolved with dlsym (no link-time dependency on libLLVM). MTLSHIM_AIR27=0 turns
// this off.
typedef struct { const char *data; size_t length; } LLVMStringRef;
typedef void *LLVMRef;
static struct {
    LLVMRef (*getNamedMetadata)(const void *module, const void *name);  // llvm::Module::getNamedMetadata(Twine const&)
    LLVMStringRef (*nodeName)(const void *node);                          // llvm::NamedMDNode::getName()
    unsigned (*nodeOperandCount)(const void *node);
    LLVMRef (*nodeOperand)(const void *node, unsigned i);
    void (*setNodeOperand)(void *node, unsigned i, LLVMRef md);
    const char *(*getTarget)(const void *module);                        // LLVM C API from here on
    void (*setTarget)(void *module, const char *triple);
    LLVMRef (*moduleContext)(const void *module);
    LLVMRef (*metadataAsValue)(LLVMRef context, LLVMRef md);
    LLVMRef (*valueAsMetadata)(LLVMRef value);
    unsigned (*mdNodeOperandCount)(LLVMRef value);
    void (*mdNodeOperands)(LLVMRef value, LLVMRef *out);
    LLVMRef (*isAConstantInt)(LLVMRef value);
    unsigned long long (*constIntValue)(LLVMRef value);
    LLVMRef (*constInt)(LLVMRef type, unsigned long long n, int signExtend);
    LLVMRef (*int32Type)(LLVMRef context);
    LLVMRef (*mdNode)(LLVMRef context, LLVMRef *mds, size_t count);
} llvm32023;
_Static_assert(sizeof llvm32023 == 17 * sizeof(void *), "one slot per name in resolveLLVM32023");
static const char kGPUCompiler32023[] =
    "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/";

static bool resolveLLVM32023(void) {
    static int resolved;  // 0 not yet, 1 ok, -1 failed
    if (resolved) return resolved > 0;
    char path[256];
    snprintf(path, sizeof path, "%slibLLVM.dylib", kGPUCompiler32023);
    void *h = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
    const char *names[] = {"_ZNK4llvm6Module16getNamedMetadataERKNS_5TwineE", "_ZNK4llvm11NamedMDNode7getNameEv",
                           "_ZNK4llvm11NamedMDNode14getNumOperandsEv", "_ZNK4llvm11NamedMDNode10getOperandEj",
                           "_ZN4llvm11NamedMDNode10setOperandEjPNS_6MDNodeE", "LLVMGetTarget", "LLVMSetTarget",
                           "LLVMGetModuleContext", "LLVMMetadataAsValue", "LLVMValueAsMetadata",
                           "LLVMGetMDNodeNumOperands", "LLVMGetMDNodeOperands", "LLVMIsAConstantInt",
                           "LLVMConstIntGetZExtValue", "LLVMConstInt", "LLVMInt32TypeInContext",
                           "LLVMMDNodeInContext2"};
    void **slots = (void **)&llvm32023;
    resolved = 1;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (!h || !(slots[i] = dlsym(h, names[i]))) resolved = -1;
    return resolved > 0;
}

// Operand 0 of a named node {..., major, minor, ...} (integers from `first` on): minor `from` -> `to`, subminor 0.
static void lowerVersionNode(const void *module, void *node, unsigned first, unsigned major, unsigned from,
                             unsigned to) {
    if (llvm32023.nodeOperandCount(node) < 1) return;
    LLVMRef context = llvm32023.moduleContext(module);
    LLVMRef value = llvm32023.metadataAsValue(context, llvm32023.nodeOperand(node, 0));
    unsigned count = llvm32023.mdNodeOperandCount(value);
    LLVMRef ops[8], mds[8];
    if (count < first + 2 || count > 8) return;
    llvm32023.mdNodeOperands(value, ops);
    if (!llvm32023.isAConstantInt(ops[first]) || !llvm32023.isAConstantInt(ops[first + 1]) ||
        llvm32023.constIntValue(ops[first]) != major || llvm32023.constIntValue(ops[first + 1]) != from)
        return;
    for (unsigned i = 0; i < count; i++) mds[i] = llvm32023.valueAsMetadata(ops[i]);
    LLVMRef i32 = llvm32023.int32Type(context);
    mds[first + 1] = llvm32023.valueAsMetadata(llvm32023.constInt(i32, to, 0));
    if (count > first + 2 && llvm32023.isAConstantInt(ops[first + 2]))
        mds[first + 2] = llvm32023.valueAsMetadata(llvm32023.constInt(i32, 0, 0));
    llvm32023.setNodeOperand(node, 0, llvm32023.mdNode(context, mds, count));
}

static LLVMRef retargetingGetNamedMetadata(const void *module, const void *name) {
    LLVMRef node = llvm32023.getNamedMetadata(module, name);
    if (!node) return node;
    LLVMStringRef nodeName = llvm32023.nodeName(node);
    if (nodeName.length != 11 || memcmp(nodeName.data, "air.version", 11)) return node;
    const char *triple = llvm32023.getTarget(module);
    static const char kAIR27[] = "air64_v27-apple-macosx";
    if (!triple || strncmp(triple, kAIR27, sizeof kAIR27 - 1)) return node;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] AIR 2.7 module (%s) retargeted to AIR 2.6 / macOS 14\n", triple);
    llvm32023.setTarget((void *)module, "air64_v26-apple-macosx14.0.0");
    lowerVersionNode(module, node, 0, 2, 7, 6);
    // Twine("air.language_version"): a C string on the left, nothing on the right (CStringKind / EmptyKind). This
    // LLVM's Twine children are 16 bytes (pointer + length), so the kinds sit at +32, where the compiler writes them.
    struct { const char *lhs; size_t lhsLength; const void *rhs; size_t rhsLength; unsigned char lhsKind, rhsKind; }
        language = {"air.language_version", 0, NULL, 0, 3, 1};
    LLVMRef languageNode = llvm32023.getNamedMetadata(module, &language);
    if (languageNode) lowerVersionNode(module, languageNode, 1, 3, 2, 1);
    return node;
}

// Points every import slot of `mh` (outside __TEXT/__LINKEDIT) that holds `from` at `to`; returns how many.
static int rebindImports(const struct mach_header *mh, intptr_t slide, const void *from, const void *to) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const struct load_command *command = (const struct load_command *)(header + 1);
    int count = 0;
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        if (!strcmp(segment->segname, SEG_TEXT) || !strcmp(segment->segname, SEG_LINKEDIT)) continue;
        const void **slot = (const void **)(segment->vmaddr + slide), **end = slot + segment->vmsize / sizeof(void *);
        for (; slot < end; slot++) {
            if (*slot != from) continue;
            uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
            bool writable = segment->initprot & VM_PROT_WRITE;
            if (!writable && mprotect((void *)page, getpagesize(), PROT_READ | PROT_WRITE)) continue;
            *slot = to;
            if (!writable) mprotect((void *)page, getpagesize(), PROT_READ);
            count++;
        }
    }
    return count;
}
static void interposeCompilerImage(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    const size_t dirLength = sizeof kGPUCompiler32023 - 1;
    if (!dladdr(mh, &info) || !info.dli_fname || strncmp(info.dli_fname, kGPUCompiler32023, dirLength) ||
        strncmp(info.dli_fname + dirLength, "libGPUCompilerImpl", 18) || !resolveLLVM32023())
        return;
    int slots = rebindImports(mh, slide, (const void *)llvm32023.getNamedMetadata, (const void *)retargetingGetNamedMetadata);
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] AIR 2.7 retargeting: %d import slot(s) in %s\n", slots, info.dli_fname + dirLength);
}

static void installAIR27Retargeting(void) {
    const char *setting = getenv("MTLSHIM_AIR27");
    if ((setting && !strcmp(setting, "0")) || strcmp(getprogname(), "MTLCompilerService")) return;
    _dyld_register_func_for_add_image(interposeCompilerImage);  // also called for the images already loaded
}

// Item 11 for WebKit in the dyld shared cache, which is where it lives on Tahoe (Sequoia's Safari has its own copy on disk) and for
// WKWebView apps: __interpose doesn't reach calls made from there, and ANGLE would run WebGL on the Intel iGPU. Those calls go
// through __stubs and import slots outside the images, which several images can share; the replacements leave other callers alone.
static void rebindStubs(const struct mach_header *mh, intptr_t slide, const void *from, const void *to) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64 || strcmp(((const struct segment_command_64 *)command)->segname, SEG_TEXT)) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t k = 0; k < segment->nsects; k++, section++) {
            if (strcmp(section->sectname, "__stubs")) continue;
            const uint8_t *code = (const uint8_t *)(section->addr + slide);
            for (uint64_t at = 0; at + 6 <= section->size; at += 6) {
                if (code[at] != 0xff || code[at + 1] != 0x25) continue;  // jmp *disp32(%rip)
                const void **slot = (const void **)(code + at + 6 + *(const int32_t *)(code + at + 2));
                if (*slot != from) continue;
                vm_address_t page = (vm_address_t)slot & ~(vm_address_t)(getpagesize() - 1);
                if (vm_protect(mach_task_self(), page, getpagesize(), FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
                *slot = to;
                vm_protect(mach_task_self(), page, getpagesize(), FALSE, VM_PROT_READ);
                if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] WebKit in the shared cache: import slot %p rebound\n", slot);
            }
        }
    }
}

static void routeWebKitImage(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!(mh->flags & MH_DYLIB_IN_CACHE) || !dladdr(mh, &info) || !info.dli_fname) return;
    const char *base = strrchr(info.dli_fname, '/');
    base = base ? base + 1 : info.dli_fname;
    if (strcmp(base, "libANGLE-shared.dylib") && strcmp(base, "WebGPU") && strcmp(base, "WebCore") && strcmp(base, "WebKit")) return;
    rebindStubs(mh, slide, (const void *)MTLCreateSystemDefaultDevice, (const void *)interposedCreateSystemDefaultDevice);
    rebindStubs(mh, slide, (const void *)MTLCopyAllDevices, (const void *)interposedCopyAllDevices);
    rebindStubs(mh, slide, (const void *)MTLCopyAllDevicesWithObserver, (const void *)interposedCopyAllDevicesWithObserver);
    rebindStubs(mh, slide, (const void *)IORegistryEntryCreateCFProperty, (const void *)interposedRegistryEntryCreateCFProperty);
}

// Item 26. WebKit's WebGPU divides by zero on Intel Macs: CommandEncoder::beginRenderPass rounds up to a multiple of
// Texture::renderTargetPixelByteAlignment(format), which is 0 when the attachment has no usable format, such as a canvas
// texture destroyed by a resize (WebGPU CTS web_platform,canvas,getCurrentTexture:resize). On Apple silicon `udiv` by zero
// gives 0 and validation goes on to report the error; on x86 `div` traps, the SIGFPE kills the GPU process, and every page
// gets a null adapter from then on. So give the Apple silicon result. All of this framework's divides have register operands.
static uintptr_t webGPUTextStart, webGPUTextEnd;

// Back to the interrupted code. Returning from the handler doesn't work there: sigreturn fails in WebKit's GPU process and
// _sigtramp ends in ud2. Leaves the red zone alone. The handler uses no floating point registers, so those need no restoring.
__attribute__((naked, noreturn)) static void resumeThread(const _STRUCT_X86_THREAD_STATE64 *state) {
    __asm__("movq 0x38(%rdi), %rax\n"   // rsp
            "subq $144, %rax\n"
            "movq 0x88(%rdi), %rcx\n"   // rflags
            "movq %rcx, (%rax)\n"
            "movq 0x80(%rdi), %rcx\n"   // rip
            "movq %rcx, 8(%rax)\n"
            "movq %rax, %rsp\n"
            "movq 0x00(%rdi), %rax\n"
            "movq 0x08(%rdi), %rbx\n"
            "movq 0x10(%rdi), %rcx\n"
            "movq 0x18(%rdi), %rdx\n"
            "movq 0x28(%rdi), %rsi\n"
            "movq 0x30(%rdi), %rbp\n"
            "movq 0x40(%rdi), %r8\n"
            "movq 0x48(%rdi), %r9\n"
            "movq 0x50(%rdi), %r10\n"
            "movq 0x58(%rdi), %r11\n"
            "movq 0x60(%rdi), %r12\n"
            "movq 0x68(%rdi), %r13\n"
            "movq 0x70(%rdi), %r14\n"
            "movq 0x78(%rdi), %r15\n"
            "movq 0x20(%rdi), %rdi\n"
            "popfq\n"
            "retq $128\n");
}

static void webGPUDivideByZero(int number, siginfo_t *info, void *context) {
    _STRUCT_X86_THREAD_STATE64 *s = &((ucontext_t *)context)->uc_mcontext->__ss;
    if (s->__rip >= webGPUTextStart && s->__rip < webGPUTextEnd) {
        const uint8_t *code = (const uint8_t *)s->__rip;
        unsigned rex = (code[0] & 0xf0) == 0x40 ? code[0] : 0;
        uint8_t opcode = code[rex ? 1 : 0], modrm = code[rex ? 2 : 1];
        if (opcode == 0xf7 && modrm >= 0xf0) {  // div or idiv of a register
            // Thread state order, indexed by x86 register number: rax rcx rdx rbx rsp rbp rsi rdi r8-r15
            static const uint8_t kSlot[16] = {0, 2, 3, 1, 7, 6, 5, 4, 8, 9, 10, 11, 12, 13, 14, 15};
            uint64_t divisor = (&s->__rax)[kSlot[(modrm & 7) | (rex & 1) << 3]];
            if (!(rex & 8)) divisor = (uint32_t)divisor;
            if (!divisor) {
                s->__rax = s->__rdx = 0;
                s->__rip += rex ? 3 : 2;
                resumeThread(s);
            }
        }
    }
    signal(SIGFPE, SIG_DFL);  // not this case: the instruction traps again, and the process crashes as it would have
}

static void guardWebGPUImage(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (webGPUTextStart || !dladdr(mh, &info) || !info.dli_fname) return;
    const char *base = strrchr(info.dli_fname, '/');
    if (!base || strcmp(base + 1, "WebGPU")) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64 || strcmp(((const struct segment_command_64 *)command)->segname, SEG_TEXT)) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        webGPUTextStart = segment->vmaddr + slide;
        webGPUTextEnd = webGPUTextStart + segment->vmsize;
        struct sigaction action = {.sa_flags = SA_SIGINFO | SA_NODEFER};  // SA_NODEFER: resumeThread doesn't unblock SIGFPE
        action.sa_sigaction = webGPUDivideByZero;
        sigaction(SIGFPE, &action, NULL);
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] WebGPU: divide by zero handled like Apple silicon\n");
    }
}

static void installWebKitRouting(void) {
    Method supportsFamily = class_getInstanceMethod(objc_getClass("_MTLDevice"), @selector(supportsFamily:));
    if (supportsFamily) realSupportsFamily = (BOOL (*)(id, SEL, NSInteger))method_getImplementation(supportsFamily);
    if (supportsFamily && onMetalOld()) method_setImplementation(supportsFamily, (IMP)compatSupportsFamily);
    if (strncmp(getprogname(), "com.apple.WebKit", 16)) return;
    _dyld_register_func_for_add_image(routeWebKitImage);
    _dyld_register_func_for_add_image(guardWebGPUImage);
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
    installAIR27Retargeting();
    installWebKitRouting();
#else
    (void)installWebKitRouting;
    (void)patchDeviceBase;
    (void)installAIR27Retargeting;
#endif
}
