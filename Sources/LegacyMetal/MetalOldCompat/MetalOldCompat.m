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
//      on Macs whose only GPU is family 1, that GPU as family 2, with ANGLE's fallbacks for what it lacks (and past
//      ANGLE's refusal of NVIDIA GPUs, for Kepler)
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
//  37. stencil copied between a buffer and a mip level 1+ or a slice 1+ on the 12.x Intel driver with a buffer offset or
//      bytesPerRow that isn't a multiple of 256 (texels taken from a neighbour, or none): through a level-0 temporary texture
//      (and on the Ivy Bridge driver, stencil copied into a buffer with padded rows, which kept only its first row: row by row)
//  38. stencil views (X32_Stencil8, X24_Stencil8) of depth/stencil textures on the 12.x Intel driver, which describe the
//      stencil plane with the depth plane's 4-texel mip alignment (levels 2+ read 0 for many widths): 8, as laid out
//  39. size queries (get_width/height) on writable 2D-array views that start at mip level 1+ in fragment functions on
//      the 12.x Intel driver (level 0's size): the view's render-target surface state gets the level as its min LOD too
//  40. depth comparisons (sample_compare, gather_compare) through a sampler argument in compute kernels on the 12.x
//      Intel driver, which always returned 0: the compute path drops the sampler's compare function; it is copied in
//  41. Photos' portrait editing (CIDepthBlurEffect, the portrait / SDOF filters) crashing in CoreImageOld.dylib, the
//      14.0 beta 3 Core Image the 3802 payloads install, on every legacy GPU: +[CIKernel / CIColorKernel
//      SDOFV2MetalKernelNamed:] and SDOFV3MetalKernelNamed: pass a static NSData that the library's once-block stores
//      without retaining, so once an autorelease pool drains it is freed and the next portrait kernel crashes in
//      -[CIKernelLibrary initWithData:error:]; NSData returns those metallibs from a cache that keeps them alive
//  42. viewports 1-15 on the 12.x Intel driver before the app sets a viewport (they cover nothing: primitives sent to them
//      with [[viewport_array_index]] draw nothing): each render encoder starts with the default viewport set explicitly
//  43. Metal Performance Shaders' NDArray matrix multiplication on the Haswell / Ivy Bridge GPUs, which encoded nothing
//      (MPSNDArrayMatrixMultiplication and MPSGraph's matmul left their results at 0): it gets the classic
//      MPSMatrixMultiplication it uses on the AMD GPU
//  44. MetalFX's temporal scaler on the Haswell / Ivy Bridge and Kepler GPUs, which said it was supported but whose pass
//      needs quad-group functions these family-1 GPUs don't have (its kernel failed to compile and the first encode
//      crashed the app): reported unsupported there, and not created
//  45. texture reads through Metal 4's read sampler (Xcode 26: every read of a Metal 4.0 library, and SceneKit's, VFX's
//      and CoreComposite's depth, cube and 1D reads on macOS 26) on Tahoe's compiler, which crashed on those with ushort
//      coordinates (SceneKit's temporal antialiasing) and passed the rest to back ends that can't build them: rebuilt in
//      the older form, without the sampler
//  46. argument encoders on the Ivy Bridge driver, which has none: MetalOld's abort() (Safari's GPU process at the first
//      WebGL 2 uniform block once item 14 had restored the encoders) becomes nil
//  47. argument buffers on the Ivy Bridge driver: layouts and encoders, and the buffers they point to bound at the
//      hidden indices the Intel adapter gives them (WebGL 2 uniform blocks)
//  48. direct draws after an indirect draw in the same render encoder on the Ivy Bridge driver, which kept the indirect
//      draw's base instance and base vertex: drawn through an indirect buffer of the shim's own
//  49. blits from or into texture views on the Ivy Bridge driver, which reached the parent's slice 0 and level 0 (cube
//      faces after ANGLE's generateMipmap): addressed through the view's parent at its slice and level
//  50. multisampled depth cleared by a render pass on the Ivy Bridge driver, which later render passes saw only in its
//      first quarter: a compute read after the pass makes the driver resolve all of it
//  51. stencil drawn with a sample mask on the Ivy Bridge driver, which wrote none when the render pass had no depth
//      attachment: a combined depth/stencil texture attached as stencil only is attached as depth too
//  52. reflection of [[stitchable]] functions (their return type and arguments), which aborted in MetalOld's
//      MTLStitchingReflectionReader on the reply of Sequoia's compiler service: the reader gets the MTLPSBIN section out of
//      the reply's newer container. With CoreImageOld's CIKernelReflection::reflect restored in the payload, precompiled
//      and stitchable Core Image kernels load again (Microsoft Office's picture corrections), and with its own
//      sections found again, kernels from Metal source (kernelsWithMetalString:, which aborted) and from kernel-language
//      source, which now take Core Image's Metal path, reflect too
//  53. small stencil uploads on the Kepler driver (GeForceMTLDriver), which weren't ordered before the blit encoder's next
//      command: a later copy out of the same texture could read it before the upload landed (zeros)
//  54. methods the Kepler driver lacks (swizzled texture views, indirect command buffers), which threw "unrecognized
//      selector": a view without a swizzle that changes nothing a shader can see, nil otherwise (as item 32); no ICB (nil)
//  55. MSAA resolves into mip level 1 or higher on the Kepler driver, which never arrived after a pass that draws: through a
//      temporary texture copied to the level, as item 15 on Intel
//  56. views of texture views on the Kepler driver, which lost the first view's offset: made from the root texture
//  57. MPSGraph's softmax over any axis but the last on Kepler, which came out wrong: done over the last axis between
//      two transposes
//  58. texture atomics on Kepler, which the compiler couldn't build: textures created for them are made linear in a
//      buffer of their own, bound at the hidden index where the Kepler adapter makes the atomics global atomics
//  59. visibility results on Kepler, which kept only the last draw's count (and left slots without draws as they were):
//      each draw counts into a slot of its own, summed into the app's slot when the encoder ends
//  60. new private buffers and counter sample buffers on Kepler, which came back with a freed buffer's contents: zero-filled
//  61. counter resolves on Kepler, which read a result buffer nothing made resident (GPU fault, device lost): the result
//      buffer is put in the command buffer's resources first
//  62. depth and stencil textures sampled through texture2d in ANGLE's shaders on Kepler, which gave (d, d, d, d): a mask of
//      depth / stencil bindings at the hidden index where the Kepler adapter makes them (d, 0, 0, 1)
//  63. blits at levels 1+ of mipmapped depth arrays and cubes on Ivy Bridge, which broke bands of other slices: done by a
//      compute read and item 27's render pass instead, the encoder's later commands after them in order
//  64. depth clears on Ivy Bridge of a level or slice above 0 of a mipmapped or cube depth texture, which were lost, and
//      clears to depths with more than 16 bits of mantissa (Haswell too): a draw writes the clear depth
//  65. copies between a buffer and several slices of a 3D texture on Kepler with a padded bytesPerImage, which put slices
//      1+ in the padding: done a slice at a time
//  66. occlusion queries on Kepler that counted no samples for a draw whose color attachments all have writeMask none and
//      no depth/stencil attachment: the first blendable attachment is written through a blend that keeps it (item 34's)
//  67. uploads into the last row of blocks of a BC texture on Kepler, at a height short of a whole block, which wrote
//      nothing: the copy's height is rounded up to the block
//  68. render passes at levels 1+ of mipmapped depth arrays and cubes on Ivy Bridge, after which fragment functions read
//      parts of other slices of level 0 wrong: an empty pass at level 0 slice 0 follows each
//  69. triangles across the edge of the viewport on Kepler, which the driver clipped there (a guard band no bigger than
//      the viewport) and drew as a fan, the pixels on its seams running the fragment function once per part with part
//      of the samples: the guard band 256 times the viewport, as on other drivers for this hardware; and wide points
//      centered outside the viewport, which it culled whole: the point guard band as wide
//  70. reversed viewport depth ranges (znear above zfar) on Kepler, which the driver mapped as if in order: the z scale
//      and translate it keeps for such a viewport are set to zfar - znear and znear
//  71. the sample positions Metal reports for Kepler's 2x and 8x patterns, which listed the standard positions in another
//      order than the hardware's: reported in the hardware's order
//  72. copies between a format and its sRGB variant on Ivy Bridge and Haswell, which converted the texels (BC: garbled): made
//      through a buffer
//  77. 2x multisampling on GPUs without it (Ivy Bridge, Haswell), which MetalOld's validation aborted on (Tahoe's Sequoia
//      wallpaper): 2 samples become 4 in textures, heap sizes, render pipelines and attachment-less passes
//  79. textures and samplers in item 47's argument buffers (Safari's WebGPU bind groups, whose fragment functions crashed
//      the compiler service): bound at the adapter's hidden texture / sampler indices around each draw or dispatch
// (The 12.5 AMD driver's own bugs are fixed in AMDBronzeCompat.dylib, which the driver loads: BronzeCompat/.)
// Loaded into every Metal client by a weak load command added to OCLP's Metal.framework wrapper; does nothing unless
// _MTLDevice comes from MetalOld.dylib. Set MTLSHIM_VERBOSE=1 to log what it does (to stderr; MTLSHIM_VERBOSE=oslog
// sends it to the unified log, for sandboxed XPC services such as WebKit's GPU process; MTLSHIM_DUMP_SOURCES=1 also writes
// every compiled source and every loaded metallib to the temporary directory). Build with build.sh.
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
#include <mach-o/nlist.h>
#include <mach-o/getsect.h>
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

// MetalOld's createVertexStage... hands back its pipeline retained (a +1 it doesn't autorelease, though "create" isn't an ARC
// family): taken for +0, every render pipeline was retained and autoreleased once more here, and lived until a pool drained.
typedef id (*VertexStageIMP)(id, SEL, void *, id, id, dispatch_data_t, id, id, NSUInteger, void *, id, id, id, void *, id) RETURNS_RETAINED;
static VertexStageIMP origVertexStage;

static id vertexStage(id self, SEL _cmd, void *fragment, id fragmentVariant, id vertexFunction, dispatch_data_t vertexDesc, id descriptor,
                      id archive, NSUInteger options, void *reflection, id stats, id fragmentTimeData, id archiverId, void *error, id handler) RETURNS_RETAINED;
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

// 77. 2x multisampling on GPUs without it. Ivy Bridge and Haswell have 4x and 8x only (supportsTextureSampleCount:2 is NO
// on the HD 4000 and the Iris Pro), and MetalOld's texture validation aborts on a 2x texture ("MTLTextureDescriptor
// sampleCount (2) is not supported by device."). Tahoe's Sequoia wallpaper (WallpaperSequoiaExtension) renders its
// scene into a 2x Depth16Unorm target without asking, so the extension crashed and the wallpaper fell back to Tahoe's
// default. Where the device itself says it has no 2x but has 4x, a sample count of 2 becomes 4 everywhere it can come in,
// together, so a pass and its pipelines keep agreeing: texture descriptors (in validation, which every texture path
// runs), heap sizing (heapTextureSizeAndAlignWithDescriptor:), render pipelines (adjustedPipeline) and the default raster
// sample count of passes without attachments (before item 73's stand-in target). supportsTextureSampleCount:2 still says
// NO, so apps that ask keep choosing 4x themselves. Shaders that read [[sample_id]], get_num_samples() or sample
// positions see 4 samples. MTLSHIM_MSAA2=0 turns it off. Test: s83 (and tools/wallpaper-check.sh builtin:sequoia).
static char kTwoSamplesKey;
static BOOL promotesTwoSamples(id<MTLDevice> device) {
    static int enabled = -1;
    if (enabled < 0) { const char *setting = getenv("MTLSHIM_MSAA2"); enabled = !(setting && !strcmp(setting, "0")); }
    if (!enabled || !device) return NO;
    NSNumber *known = objc_getAssociatedObject(device, &kTwoSamplesKey);
    if (known) return known.boolValue;
    BOOL promote = ![device supportsTextureSampleCount:2] && [device supportsTextureSampleCount:4];
    objc_setAssociatedObject(device, &kTwoSamplesKey, @(promote), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return promote;
}

static BOOL validateTexture(id self, SEL _cmd, id device) {
    MTLTextureDescriptor *desc = self;
    if (desc.sampleCount == 2 && promotesTwoSamples(device)) {  // item 77
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 2x multisampled texture made 4x (the device has no 2x)\n");
        desc.sampleCount = 4;
    }
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
// And fences: from MSL 3.2 SPIRV-Cross writes a SPIR-V memory barrier as atomic_thread_fence(flags, order, scope), which
// this front end doesn't have in any form (MoltenVK picks 3.2 on macOS 15 and 4.0 on 26 from the OS version alone; Godot
// 4.7's compute shaders failed to build). Before 3.2 it wrote threadgroup_barrier(flags), or simdgroup_barrier(flags) for
// a simdgroup or thread scope, and so does this rewrite: a barrier is a fence too, and SPIRV-Cross only writes fences in
// kernels, where barriers are allowed. A control barrier after the fence stays, as a second barrier. Test: s80.
static NSString *downgradeSource(NSString *source, id options) {
    if (!source || !options || !objc_getAssociatedObject(options, kNewerVersionRequested)) return source;
    if ([source rangeOfString:@"coheren"].location == NSNotFound && [source rangeOfString:@"atomic_thread_fence"].location == NSNotFound)
        return source;
    static NSArray<NSArray *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *patterns = @[
            @[@"\\s*,\\s*(?:memory_coherence\\s*::\\s*)?memory_coherence_(?:device|threadgroup)(?=\\s*>)", @""],
            @[@"\\bcoherent\\s*\\(\\s*device\\s*\\)", @"volatile"],
            @[@"\\bcoherent\\s*\\(\\s*threadgroup\\s*\\)\\s*", @""],
            @[@"\\bcoherent(?=\\s+(?:device|threadgroup)\\b)", @"volatile"],
            @[@"\\batomic_thread_fence\\s*\\(\\s*([^,;()]+?)\\s*,\\s*memory_order_\\w+\\s*,\\s*(?:metal::)?thread_scope_(?:simdgroup|thread)\\s*\\)",
              @"simdgroup_barrier($1)"],
            @[@"\\batomic_thread_fence\\s*\\(\\s*([^,;()]+?)\\s*,\\s*memory_order_\\w+\\s*(?:,\\s*(?:metal::)?thread_scope_\\w+\\s*)?\\)",
              @"threadgroup_barrier($1)"],
        ];
        NSMutableArray *compiled = [NSMutableArray array];
        for (NSArray *p in patterns)
            [compiled addObject:@[[NSRegularExpression regularExpressionWithPattern:p[0] options:0 error:nil], p[1]]];
        rules = compiled;
    });
    NSString *out = source;
    for (NSArray *rule in rules)
        out = [rule[0] stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:rule[1]];
    if (getenv("MTLSHIM_VERBOSE") && ![out isEqualToString:source]) shimLog("[mtlshim] MSL 3.2 coherence qualifiers / fences rewritten for 3.1\n");
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

// MTLSHIM_DUMP_SOURCES=1 (debugging): every source compiled through the hooks below is written to the temporary directory.
static void dumpSource(NSString *source) {
    if (!getenv("MTLSHIM_DUMP_SOURCES") || !source) return;
    static int n;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"mtlshim-src-%d-%d.metal", getpid(), __sync_fetch_and_add(&n, 1)]];
    [source writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    shimLog("[mtlshim] source written: %s\n", path.UTF8String);
}

static id newLibrarySync(id self, SEL _cmd, NSString *source, id options, NSError **error) __attribute__((ns_returns_retained));
static id newLibrarySync(id self, SEL _cmd, NSString *source, id options, NSError **error) {
    NSString *compiled = downgradeSource(source, options);
    dumpSource(compiled);
    NSError *failure = nil;
    id library = origNewLibrarySync(self, _cmd, compiled, options, &failure);
    if (!library) reportCompileFailure(compiled, failure);
    if (error) *error = failure;
    return library;
}

static void newLibraryAsync(id self, SEL _cmd, NSString *source, id options, id handler) {
    NSString *compiled = downgradeSource(source, options);
    dumpSource(compiled);
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

// The Kepler driver has each encoder class twice, once for each of its 3D classes, with the same code: _KEPLER_A for the
// GK104, GK106 and GK107 (GTX 650-770 and most other 600 / 700 cards) and _KEPLER_B for the GK110 and GK208 (GTX 780 and
// Titan, GT 710 / 720 / 730), and _KEPLER_COMPUTE_A / _B likewise. keplerSwizzle hooks a selector of an _A class and, when
// its _B twin defines it too, the twin, with the same hook; it returns the _A original, as swizzle does. A hook calls its
// original through NVO(orig) (NVOR(orig, receiver) for another receiver), which is that original for an _A encoder and
// the _B twin's for a _B one (a chained hook's "original" is the earlier hook, the same for both).
typedef struct { IMP a, b; } NVTwin;
static NVTwin nvTwins[64];
static int nvTwinCount;
static Class nvTwinClasses[8];
static int nvTwinClassCount;
static IMP keplerSwizzle(const char *cls, const char *sel, IMP imp) {
    IMP a = swizzle(cls, sel, imp);
    size_t length = strlen(cls);
    char twin[128];
    if (!a || length < 2 || length >= sizeof twin || strcmp(cls + length - 2, "_A") || nvTwinCount == 64) return a;
    memcpy(twin, cls, length + 1);
    twin[length - 1] = 'B';
    if (!definesMethod(twin, sel)) return a;
    IMP b = swizzle(twin, sel, imp);
    if (!b) return a;
    nvTwins[nvTwinCount++] = (NVTwin){a, b};
    Class c = objc_getClass(twin);
    int known = 0;
    for (int i = 0; i < nvTwinClassCount; i++) known |= nvTwinClasses[i] == c;
    if (!known && nvTwinClassCount < 8) nvTwinClasses[nvTwinClassCount++] = c;
    return a;
}
static BOOL nvIsKeplerB(__unsafe_unretained id object) {
    Class c = object ? object_getClass(object) : Nil;
    for (int depth = 0; c && depth < 3; depth++, c = class_getSuperclass(c))  // the driver's _Statistics etc. subclasses too
        for (int i = 0; i < nvTwinClassCount; i++)
            if (c == nvTwinClasses[i]) return YES;
    return NO;
}
static IMP nvOriginal(__unsafe_unretained id receiver, IMP a) {
    if (!nvTwinCount || !nvIsKeplerB(receiver)) return a;
    for (int i = 0; i < nvTwinCount; i++)
        if (nvTwins[i].a == a) return nvTwins[i].b;
    return a;
}
#define NVOR(orig, receiver) ((__typeof__(orig))nvOriginal((receiver), (IMP)(orig)))
#define NVO(orig) NVOR(orig, self)

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

// 46. Argument encoders on the Ivy Bridge driver (OCLP's 11.7.10 AppleIntelHD4000GraphicsMTLDriver), which has no
// argument-buffer layouts or encoders of its own (the 12.x Intel driver has MTLIGEmulationIndirectArgumentEncoder): the
// request ends in MetalOld's -[MTLIOAccelDevice newIndirectArgumentEncoderWithLayout:], which is abort(). With item 14
// that took down Safari's GPU process at the first WebGL 2 draw with a uniform block, and every WebGL context of the
// page with it, where the wrapper's stub had given ANGLE nil. MetalOld's abort becomes nil (drivers that implement the
// method themselves never reach it). MTLSHIM_ARGUMENT_ENCODER_GUARD=0 turns it off. (s60)
static id nilIndirectArgumentEncoder(id self, SEL _cmd, id layout) __attribute__((ns_returns_retained));
static id nilIndirectArgumentEncoder(id self, SEL _cmd, id layout) {
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] %s has no argument encoders: nil instead of MetalOld's abort\n", class_getName(object_getClass(self)));
    return nil;
}

static void guardArgumentEncoders(void) {
    const char *setting = getenv("MTLSHIM_ARGUMENT_ENCODER_GUARD");
    Method m = class_getInstanceMethod(objc_getClass("MTLIOAccelDevice"), sel_registerName("newIndirectArgumentEncoderWithLayout:"));
    if ((setting && !strcmp(setting, "0")) || !m || !definesMethod("MTLIOAccelDevice", "newIndirectArgumentEncoderWithLayout:") ||
        !fromMetalOld(method_getImplementation(m)))
        return;
    method_setImplementation(m, (IMP)nilIndirectArgumentEncoder);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MetalOld's argument-encoder abort guarded\n");
}

// 47. Argument buffers on the Ivy Bridge driver. Its plugin doesn't emulate them and its driver has no argument-buffer
// runtime (item 46): WebGL 2 uniform blocks, which WebKit's ANGLE puts in an argument buffer, couldn't work at all. The
// Intel adapter (IntelTextureAtomics, INTEL_IVB_ARGUMENT_BUFFER_FIX) makes each pointer member of an argument buffer a
// hidden buffer parameter, at a buffer index the function doesn't use, counted down from 30 over every pointer member
// in order of argument buffer index and id (vertex functions keep 0-16 for vertex buffers). Here:
//  - the device gets argument-buffer layouts (the struct's C layout, which the compiled shaders read constants by) and
//    encoders: a pointer member holds a token (buffer id << 32 | offset; ids name buffers weakly), constants their data;
//  - each pipeline gets that index assignment worked out from its reflection, which lists every buffer argument
//    (unused ones too) and each argument buffer's struct;
//  - before each draw or dispatch, the buffers the bound argument buffers point to are bound at their hidden indices
//    with the driver's own setters, and whatever the app had bound there is put back afterwards.
// Nested argument buffers, arrays of textures or samplers and tessellation draws aren't covered.
// Ivy Bridge driver only (a device class without argument encoders of its own). MTLSHIM_IVB_ARGUMENT_BUFFERS=0 turns it
// off. (s61)
// 79. Textures and samplers in those argument buffers. WebKit's WebGPU puts each bind group in an argument buffer,
// textures and samplers included, and fills it with an argument encoder; a fragment function that sampled one crashed
// the compiler service, so Safari's WebGPU render pipelines failed (device lost). The adapter
// (INTEL_IVB_ARGUMENT_BUFFER_TEXTURES) makes each texture or sampler member a hidden texture / sampler parameter, at a
// texture index counted down from 30 / a sampler index counted down from 15 over the ones the function doesn't use, in
// the same order as the buffers. Here the encoder writes a token for each (the object's id, as for buffers), the
// pipeline gets those indices from its reflection, and each draw or dispatch binds them with the driver's setters and
// puts back what the app had bound there (samplers with their LOD clamps). MTLSHIM_IVB_ARGUMENT_BUFFER_TEXTURES=0 turns
// it off. (s86)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // MetalOld has only the macOS 12 reflection API (MTLArgument)
@interface _MTLIndirectArgumentBufferLayout : NSObject
- (void)setStructType:(MTLStructType *)structType withDevice:(id<MTLDevice>)device;
@end
@interface _MTLIndirectArgumentEncoder : NSObject
- (instancetype)initWithLayout:(id)layout device:(id<MTLDevice>)device;
@end

enum { kABConstant, kABPointer, kABTexture, kABSampler };
typedef struct { uint32_t id, offset, kind; } ABSlot;                            // a member: [[id]], byte offset, kAB*
typedef struct { uint8_t stage, argument, hidden, kind; uint32_t offset; } ABBinding;  // stage: 0 vertex, 1 fragment, 2 compute
static BOOL ivbArgumentBuffersOn, abTexturesOn;
static uint32_t abSlotKind(MTLDataType t) {
    return t == MTLDataTypePointer ? kABPointer : t == MTLDataTypeTexture ? kABTexture : t == MTLDataTypeSampler ? kABSampler : kABConstant;
}

static NSUInteger abAlignUp(NSUInteger v, NSUInteger a) { return a > 1 ? (v + a - 1) / a * a : v; }
static void abSizeAlign(MTLDataType t, NSUInteger *size, NSUInteger *align) {
    NSUInteger s = 8, a = 8;  // pointers, textures, samplers and other handles
    switch (t) {
        case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: s = a = 1; break;
        case MTLDataTypeBool2: case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort:
        case MTLDataTypeHalf: s = a = 2; break;
        case MTLDataTypeBool3: case MTLDataTypeBool4: case MTLDataTypeChar3: case MTLDataTypeChar4: case MTLDataTypeUChar3:
        case MTLDataTypeUChar4: case MTLDataTypeShort2: case MTLDataTypeUShort2: case MTLDataTypeHalf2: case MTLDataTypeFloat:
        case MTLDataTypeInt: case MTLDataTypeUInt: s = a = 4; break;
        case MTLDataTypeShort3: case MTLDataTypeShort4: case MTLDataTypeUShort3: case MTLDataTypeUShort4: case MTLDataTypeHalf3:
        case MTLDataTypeHalf4: case MTLDataTypeFloat2: case MTLDataTypeInt2: case MTLDataTypeUInt2: case MTLDataTypeLong:
        case MTLDataTypeULong: s = a = 8; break;
        case MTLDataTypeFloat3: case MTLDataTypeFloat4: case MTLDataTypeInt3: case MTLDataTypeInt4: case MTLDataTypeUInt3:
        case MTLDataTypeUInt4: case MTLDataTypeLong2: case MTLDataTypeULong2: s = a = 16; break;
        case MTLDataTypeLong3: case MTLDataTypeLong4: case MTLDataTypeULong3: case MTLDataTypeULong4: s = a = 32; break;
        case MTLDataTypeFloat2x2: s = 16; a = 8; break;
        case MTLDataTypeFloat2x3: case MTLDataTypeFloat2x4: s = 32; a = 16; break;
        case MTLDataTypeFloat3x2: s = 24; a = 8; break;
        case MTLDataTypeFloat3x3: case MTLDataTypeFloat3x4: s = 48; a = 16; break;
        case MTLDataTypeFloat4x2: s = 32; a = 8; break;
        case MTLDataTypeFloat4x3: case MTLDataTypeFloat4x4: s = 64; a = 16; break;
        case MTLDataTypeHalf2x2: s = 8; a = 4; break;
        case MTLDataTypeHalf2x3: case MTLDataTypeHalf2x4: s = 16; a = 8; break;
        case MTLDataTypeHalf3x2: s = 12; a = 4; break;
        case MTLDataTypeHalf3x3: case MTLDataTypeHalf3x4: s = 24; a = 8; break;
        case MTLDataTypeHalf4x2: s = 16; a = 4; break;
        case MTLDataTypeHalf4x3: case MTLDataTypeHalf4x4: s = 32; a = 8; break;
        default: break;
    }
    *size = s;
    *align = a;
}

// The C layout of an argument buffer's struct (the offsets its shaders read), as slots; ids of nested members count
// from their parent's.
static void abFlatten(MTLStructType *type, NSUInteger idBase, NSMutableData *slots, NSUInteger *outSize, NSUInteger *outAlign) {
    NSUInteger offset = 0, maxAlign = 1;
    for (MTLStructMember *m in type.members) {
        NSUInteger size, align, id = idBase + m.argumentIndex;
        if (m.dataType == MTLDataTypeStruct) {
            NSMutableData *inner = [NSMutableData data];
            abFlatten(m.structType, id, inner, &size, &align);
            offset = abAlignUp(offset, align);
            ABSlot *s = inner.mutableBytes;
            for (NSUInteger k = 0; k < inner.length / sizeof(ABSlot); k++) {
                s[k].offset += (uint32_t)offset;
                [slots appendBytes:&s[k] length:sizeof(ABSlot)];
            }
        } else if (m.dataType == MTLDataTypeArray) {
            MTLArrayType *array = m.arrayType;
            NSUInteger elementSize, elementAlign;
            if (array.elementType == MTLDataTypeStruct) {
                NSMutableData *ignored = [NSMutableData data];
                abFlatten(array.elementStructType, id, ignored, &elementSize, &elementAlign);
            } else
                abSizeAlign(array.elementType, &elementSize, &elementAlign);
            elementSize = abAlignUp(elementSize, elementAlign);
            offset = abAlignUp(offset, elementAlign);
            if (array.elementType != MTLDataTypeStruct)
                for (NSUInteger j = 0; j < array.arrayLength; j++) {
                    ABSlot s = {(uint32_t)(id + j * MAX(array.argumentIndexStride, (NSUInteger)1)), (uint32_t)(offset + j * elementSize),
                                abSlotKind(array.elementType)};
                    [slots appendBytes:&s length:sizeof s];
                }
            size = elementSize * array.arrayLength;
            align = elementAlign;
        } else {
            abSizeAlign(m.dataType, &size, &align);
            offset = abAlignUp(offset, align);
            ABSlot s = {(uint32_t)id, (uint32_t)offset, abSlotKind(m.dataType)};
            [slots appendBytes:&s length:sizeof s];
        }
        offset += size;
        maxAlign = MAX(maxAlign, align);
    }
    *outSize = abAlignUp(offset, maxAlign);
    *outAlign = maxAlign;
}

// Buffers named by tokens: a weak table, so a token left behind by a freed buffer names nothing.
static os_unfair_lock abLock = OS_UNFAIR_LOCK_INIT;
static NSPointerArray *abBuffers;
static const void *kABBufferIdKey = &kABBufferIdKey;
static uint32_t abBufferId(id buffer) {
    if (!buffer) return 0;
    os_unfair_lock_lock(&abLock);
    NSNumber *known = objc_getAssociatedObject(buffer, kABBufferIdKey);
    uint32_t i = known.unsignedIntValue;
    if (!known) {
        if (!abBuffers) {
            abBuffers = [NSPointerArray weakObjectsPointerArray];
            [abBuffers addPointer:NULL];  // id 0 is no buffer
        }
        i = (uint32_t)abBuffers.count;
        [abBuffers addPointer:(__bridge void *)buffer];
        objc_setAssociatedObject(buffer, kABBufferIdKey, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&abLock);
    return i;
}
static id abBufferForId(uint32_t i) {
    os_unfair_lock_lock(&abLock);
    id buffer = i && i < abBuffers.count ? (__bridge id)[abBuffers pointerAtIndex:i] : nil;
    os_unfair_lock_unlock(&abLock);
    return buffer;
}

@interface MTLShimArgumentLayout : _MTLIndirectArgumentBufferLayout {
  @public
    NSData *slots;
    NSUInteger size, align;
}
@end
@implementation MTLShimArgumentLayout
- (void)setStructType:(MTLStructType *)structType withDevice:(id<MTLDevice>)device {
    [super setStructType:structType withDevice:device];
    NSMutableData *flat = [NSMutableData data];
    NSUInteger s = 0, a = 1;
    abFlatten(structType, 0, flat, &s, &a);
    slots = flat;
    size = MAX(s, (NSUInteger)8);
    align = MAX(a, (NSUInteger)8);
}
- (NSUInteger)encodedLength { return size; }
- (NSUInteger)alignment { return align; }
- (BOOL)bufferLayoutMatchesFrontEndLayout { return YES; }
- (const ABSlot *)slotForId:(NSUInteger)i kind:(uint32_t)kind {
    const ABSlot *s = slots.bytes;
    for (NSUInteger k = 0; k < slots.length / sizeof(ABSlot); k++)
        if (s[k].id == i && s[k].kind == kind) return &s[k];
    return NULL;
}
- (NSUInteger)constantOffsetAtIndex:(NSUInteger)i {
    const ABSlot *s = [self slotForId:i kind:kABConstant];
    return s ? s->offset : NSNotFound;
}
@end

@interface MTLShimArgumentEncoder : _MTLIndirectArgumentEncoder {
    MTLShimArgumentLayout *abLayout;
    id<MTLBuffer> abBuffer;
    NSUInteger abOffset;
}
@end
@implementation MTLShimArgumentEncoder
- (instancetype)initWithLayout:(id)layout device:(id<MTLDevice>)device {
    if ((self = [super initWithLayout:layout device:device])) abLayout = layout;
    return self;
}
- (NSUInteger)encodedLength { return abLayout->size; }
- (NSUInteger)alignment { return abLayout->align; }
- (void)setArgumentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset {
    abBuffer = buffer;
    abOffset = offset;
}
- (void)setArgumentBuffer:(id<MTLBuffer>)buffer startOffset:(NSUInteger)start arrayElement:(NSUInteger)element {
    abBuffer = buffer;
    abOffset = start + element * abAlignUp(abLayout->size, abLayout->align);
}
- (void)writeToken:(uint64_t)token kind:(uint32_t)kind atIndex:(NSUInteger)index {
    const ABSlot *s = [abLayout slotForId:index kind:kind];
    uint8_t *p = abBuffer.contents;
    if (!s || !p || abOffset + s->offset + 8 > abBuffer.length) return;
    memcpy(p + abOffset + s->offset, &token, sizeof token);
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    [self writeToken:buffer ? (uint64_t)abBufferId(buffer) << 32 | (uint32_t)offset : 0 kind:kABPointer atIndex:index];
}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained[])buffers offsets:(const NSUInteger[])offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void *)constantDataAtIndex:(NSUInteger)index {
    const ABSlot *s = [abLayout slotForId:index kind:kABConstant];
    uint8_t *p = abBuffer.contents;
    return s && p && abOffset + s->offset < abBuffer.length ? p + abOffset + s->offset : NULL;
}
- (void)unsupported:(const char *)what {
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] argument buffer on the Ivy Bridge GPU: %s not supported\n", what);
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {  // item 79: the texture's id, as for buffers
    if (!abTexturesOn) return [self unsupported:"textures"];
    [self writeToken:(uint64_t)abBufferId(texture) << 32 kind:kABTexture atIndex:index];
}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained[])textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setTexture:textures[i] atIndex:range.location + i];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (!abTexturesOn) return [self unsupported:"samplers"];
    [self writeToken:(uint64_t)abBufferId(sampler) << 32 kind:kABSampler atIndex:index];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained[])samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setSamplerState:samplers[i] atIndex:range.location + i];
}
- (id<MTLArgumentEncoder>)newArgumentEncoderForBufferAtIndex:(NSUInteger)index { return nil; }
@end

static id ivbNewArgumentLayout(id self, SEL _cmd, MTLStructType *type) __attribute__((ns_returns_retained));
static id ivbNewArgumentLayout(id self, SEL _cmd, MTLStructType *type) {
    MTLShimArgumentLayout *layout = [[MTLShimArgumentLayout alloc] init];
    [layout setStructType:type withDevice:self];
    return layout;
}
static id ivbNewArgumentEncoder(id self, SEL _cmd, id layout) __attribute__((ns_returns_retained));
static id ivbNewArgumentEncoder(id self, SEL _cmd, id layout) {
    return [layout isKindOfClass:[MTLShimArgumentLayout class]] ? [[MTLShimArgumentEncoder alloc] initWithLayout:layout device:self] : nil;
}

// The adapter's hidden indices for one stage, from its reflection arguments: buffers counted down from 30 (17 the
// lowest in a vertex function), textures from 30 and samplers (item 79) from 15, over the indices the function uses.
static void abStageBindings(NSArray<MTLArgument *> *arguments, uint8_t stage, NSMutableData *out) {
    BOOL used[4][31] = {{NO}};  // by kAB* kind
    typedef struct { NSUInteger kind, buffer, id, offset; } Pointer;
    NSMutableData *pointers = [NSMutableData data];
    for (MTLArgument *a in arguments) {
        int kind = a.type == MTLArgumentTypeBuffer ? kABPointer : a.type == MTLArgumentTypeTexture ? kABTexture
                   : a.type == MTLArgumentTypeSampler ? kABSampler : kABConstant;
        if (kind == kABConstant) continue;
        for (NSUInteger k = 0; k < MAX(a.arrayLength, (NSUInteger)1); k++)
            if (a.index + k < 31) used[kind][a.index + k] = YES;
        MTLStructType *type = kind == kABPointer ? a.bufferStructType : nil;
        if (!type || a.index >= 31) continue;
        // the members the adapter rewrites: pointers, metal::array structs of pointers, and (item 79) textures and samplers
        NSMutableIndexSet *ids = [NSMutableIndexSet indexSet], *handles = [NSMutableIndexSet indexSet];
        for (MTLStructMember *m in type.members) {
            if (m.dataType == MTLDataTypePointer) [ids addIndex:m.argumentIndex];
            if (abTexturesOn && (m.dataType == MTLDataTypeTexture || m.dataType == MTLDataTypeSampler)) [handles addIndex:m.argumentIndex];
            if (m.dataType != MTLDataTypeStruct || m.structType.members.count != 1) continue;
            MTLStructMember *inner = m.structType.members.firstObject;
            if (inner.dataType != MTLDataTypeArray || inner.arrayType.elementType != MTLDataTypePointer) continue;
            for (NSUInteger j = 0; j < inner.arrayType.arrayLength; j++)
                [ids addIndex:m.argumentIndex + inner.argumentIndex + j * MAX(inner.arrayType.argumentIndexStride, (NSUInteger)1)];
        }
        if (!ids.count && !handles.count) continue;
        NSMutableData *flat = [NSMutableData data];
        NSUInteger size, align;
        abFlatten(type, 0, flat, &size, &align);
        const ABSlot *s = flat.bytes;
        for (NSUInteger k = 0; k < flat.length / sizeof(ABSlot); k++)
            if ((s[k].kind == kABPointer && [ids containsIndex:s[k].id]) ||
                ((s[k].kind == kABTexture || s[k].kind == kABSampler) && [handles containsIndex:s[k].id])) {
                Pointer p = {s[k].kind, a.index, s[k].id, s[k].offset};
                [pointers appendBytes:&p length:sizeof p];
            }
    }
    NSUInteger n = pointers.length / sizeof(Pointer);
    if (!n) return;
    Pointer *p = pointers.mutableBytes;
    qsort_b(p, n, sizeof(Pointer), ^int(const void *x, const void *y) {
        const Pointer *a = x, *b = y;
        if (a->buffer != b->buffer) return a->buffer < b->buffer ? -1 : 1;
        return a->id < b->id ? -1 : a->id > b->id;
    });
    int next[4] = {0, 30, 30, 15}, lowest[4] = {0, stage == 0 ? 17 : 0, 0, 0};
    NSMutableData *bindings = [NSMutableData data];
    for (NSUInteger k = 0; k < n; k++) {
        NSUInteger kind = p[k].kind;
        while (next[kind] >= lowest[kind] && used[kind][next[kind]]) next[kind]--;
        if (next[kind] < lowest[kind]) return;  // the adapter left this function alone
        ABBinding b = {stage, (uint8_t)p[k].buffer, (uint8_t)next[kind]--, (uint8_t)kind, (uint32_t)p[k].offset};
        [bindings appendBytes:&b length:sizeof b];
    }
    [out appendData:bindings];
}

static const void *kABBindingsKey = &kABBindingsKey;
static void abAttach(id pipeline, NSArray *vertex, NSArray *fragment, NSArray *compute) {
    if (!pipeline) return;
    NSMutableData *bindings = [NSMutableData data];
    abStageBindings(vertex, 0, bindings);
    abStageBindings(fragment, 1, bindings);
    abStageBindings(compute, 2, bindings);
    if (!bindings.length) return;
    objc_setAssociatedObject(pipeline, kABBindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] pipeline with %lu argument-buffer pointer(s)/handle(s) bound at hidden indices\n",
                                           (unsigned long)(bindings.length / sizeof(ABBinding)));
}

static BOOL abDevice(id device) {
    static Class intel;
    if (!intel) intel = objc_getClass("MTLIGAccelDevice");
    return ivbArgumentBuffersOn && intel && [device isKindOfClass:intel];
}
static const MTLPipelineOption kABReflection = MTLPipelineOptionArgumentInfo | MTLPipelineOptionBufferTypeInfo;

typedef id (*ABReflMsgIMP)(id, SEL, id, MTLPipelineOption, id *, NSError **) RETURNS_RETAINED;  // the reflection variants, by message
typedef id (*ABRenderReflIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **) RETURNS_RETAINED;
typedef void (*ABRenderOptAsyncIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLNewRenderPipelineStateWithReflectionCompletionHandler);
typedef id (*ABComputeFnReflIMP)(id, SEL, id<MTLFunction>, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection *, NSError **) RETURNS_RETAINED;
typedef id (*ABComputeDescReflIMP)(id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection *, NSError **) RETURNS_RETAINED;
typedef void (*ABComputeFnOptAsyncIMP)(id, SEL, id<MTLFunction>, MTLPipelineOption, MTLNewComputePipelineStateWithReflectionCompletionHandler);
typedef void (*ABComputeDescOptAsyncIMP)(id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption, MTLNewComputePipelineStateWithReflectionCompletionHandler);
static ABRenderReflIMP abOrigRenderRefl;
static ABRenderOptAsyncIMP abOrigRenderOptAsync;
static ABComputeFnReflIMP abOrigComputeFnRefl;
static ABComputeDescReflIMP abOrigComputeDescRefl;
static ABComputeFnOptAsyncIMP abOrigComputeFnOptAsync;
static ABComputeDescOptAsyncIMP abOrigComputeDescOptAsync;

static id abRenderRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                       MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) __attribute__((ns_returns_retained));
static id abRenderRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                       MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) {
    if (!abDevice(self)) return abOrigRenderRefl(self, _cmd, d, options, reflection, error);
    MTLAutoreleasedRenderPipelineReflection r = nil;
    NSError *failure = nil;
    id pipeline = abOrigRenderRefl(self, _cmd, d, options | kABReflection, &r, &failure);
    if (error) *error = failure;
    if (!pipeline && getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] render pipeline failed (vertex %s, fragment %s): %.600s\n", d.vertexFunction.name.UTF8String ?: "-",
                d.fragmentFunction.name.UTF8String ?: "-", failure.localizedDescription.UTF8String ?: "?");
    abAttach(pipeline, r.vertexArguments, r.fragmentArguments, nil);
    if (reflection) *reflection = r;
    return pipeline;
}
static id abRender(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, NSError **error) __attribute__((ns_returns_retained));
static id abRender(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, NSError **error) {
    return ((ABReflMsgIMP)objc_msgSend)(
        self, sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:"), d, MTLPipelineOptionNone, NULL, error);
}
static void abRenderOptAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                             MTLNewRenderPipelineStateWithReflectionCompletionHandler handler) {
    if (!abDevice(self)) return abOrigRenderOptAsync(self, _cmd, d, options, handler);
    abOrigRenderOptAsync(self, _cmd, d, options | kABReflection, ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) {
        abAttach(p, r.vertexArguments, r.fragmentArguments, nil);
        handler(p, r, e);
    });
}
static void abRenderAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLNewRenderPipelineStateCompletionHandler handler) {
    ((void (*)(id, SEL, id, MTLPipelineOption, id))objc_msgSend)(
        self, sel_registerName("newRenderPipelineStateWithDescriptor:options:completionHandler:"), d, MTLPipelineOptionNone,
        ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) { handler(p, e); });
}
static id abComputeFnRefl(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                          MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) __attribute__((ns_returns_retained));
static id abComputeFnRefl(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                          MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) {
    if (!abDevice(self)) return abOrigComputeFnRefl(self, _cmd, f, options, reflection, error);
    MTLAutoreleasedComputePipelineReflection r = nil;
    id pipeline = abOrigComputeFnRefl(self, _cmd, f, options | kABReflection, &r, error);
    abAttach(pipeline, nil, nil, r.arguments);
    if (reflection) *reflection = r;
    return pipeline;
}
static id abComputeFn(id self, SEL _cmd, id<MTLFunction> f, NSError **error) __attribute__((ns_returns_retained));
static id abComputeFn(id self, SEL _cmd, id<MTLFunction> f, NSError **error) {
    return ((ABReflMsgIMP)objc_msgSend)(
        self, sel_registerName("newComputePipelineStateWithFunction:options:reflection:error:"), f, MTLPipelineOptionNone, NULL, error);
}
static id abComputeDescRefl(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                            MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) __attribute__((ns_returns_retained));
static id abComputeDescRefl(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                            MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) {
    if (!abDevice(self)) return abOrigComputeDescRefl(self, _cmd, d, options, reflection, error);
    MTLAutoreleasedComputePipelineReflection r = nil;
    id pipeline = abOrigComputeDescRefl(self, _cmd, d, options | kABReflection, &r, error);
    abAttach(pipeline, nil, nil, r.arguments);
    if (reflection) *reflection = r;
    return pipeline;
}
static void abComputeFnOptAsync(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                                MTLNewComputePipelineStateWithReflectionCompletionHandler handler) {
    if (!abDevice(self)) return abOrigComputeFnOptAsync(self, _cmd, f, options, handler);
    abOrigComputeFnOptAsync(self, _cmd, f, options | kABReflection, ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) {
        abAttach(p, nil, nil, r.arguments);
        handler(p, r, e);
    });
}
static void abComputeFnAsync(id self, SEL _cmd, id<MTLFunction> f, MTLNewComputePipelineStateCompletionHandler handler) {
    ((void (*)(id, SEL, id, MTLPipelineOption, id))objc_msgSend)(
        self, sel_registerName("newComputePipelineStateWithFunction:options:completionHandler:"), f, MTLPipelineOptionNone,
        ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) { handler(p, e); });
}
static void abComputeDescOptAsync(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                                  MTLNewComputePipelineStateWithReflectionCompletionHandler handler) {
    if (!abDevice(self)) return abOrigComputeDescOptAsync(self, _cmd, d, options, handler);
    abOrigComputeDescOptAsync(self, _cmd, d, options | kABReflection, ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) {
        abAttach(p, nil, nil, r.arguments);
        handler(p, r, e);
    });
}

// What an encoder has bound, per stage (0 vertex, 1 fragment, 2 compute), and its pipeline's hidden bindings.
@interface MTLShimABState : NSObject {
  @public
    __strong id buffers[3][31];
    NSUInteger offsets[3][31];
    __strong NSData *bytes[3][31];
    __strong id textures[3][31], samplers[3][16];  // item 79
    float lodMin[3][16], lodMax[3][16];
    BOOL clamped[3][16];
    __strong NSData *bindings;
}
@end
@implementation MTLShimABState
@end
static const void *kABStateKey = &kABStateKey;
static MTLShimABState *abState(id encoder) {
    MTLShimABState *s = objc_getAssociatedObject(encoder, kABStateKey);
    if (!s) {
        s = [MTLShimABState new];
        objc_setAssociatedObject(encoder, kABStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

typedef void (*ABSetBufferIMP)(id, SEL, id, NSUInteger, NSUInteger);
typedef void (*ABSetOffsetIMP)(id, SEL, NSUInteger, NSUInteger);
typedef void (*ABSetBuffersIMP)(id, SEL, const id __unsafe_unretained *, const NSUInteger *, NSRange);
typedef void (*ABSetBytesIMP)(id, SEL, const void *, NSUInteger, NSUInteger);
typedef void (*ABSetPipelineIMP)(id, SEL, id);
static ABSetBufferIMP abOrigSetBuffer[3];
static ABSetOffsetIMP abOrigSetOffset[3];
static ABSetBuffersIMP abOrigSetBuffers[3];
static ABSetBytesIMP abOrigSetBytes[3];
static ABSetPipelineIMP abOrigSetRenderPipeline, abOrigSetComputePipeline;
static SEL abSetBufferSel[3], abSetBytesSel[3];

static void abRecordBuffer(id encoder, int stage, id buffer, NSUInteger offset, NSUInteger index) {
    if (index >= 31) return;
    MTLShimABState *s = abState(encoder);
    s->buffers[stage][index] = buffer;
    s->offsets[stage][index] = offset;
    s->bytes[stage][index] = nil;
}
#define AB_STAGE_HOOKS(name, stage)                                                                                     \
    static void abSetBuffer##name(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger index) {                   \
        abRecordBuffer(self, stage, buffer, offset, index);                                                              \
        abOrigSetBuffer[stage](self, _cmd, buffer, offset, index);                                                       \
    }                                                                                                                    \
    static void abSetOffset##name(id self, SEL _cmd, NSUInteger offset, NSUInteger index) {                              \
        if (index < 31) abState(self)->offsets[stage][index] = offset;                                                   \
        abOrigSetOffset[stage](self, _cmd, offset, index);                                                               \
    }                                                                                                                    \
    static void abSetBuffers##name(id self, SEL _cmd, const id __unsafe_unretained *buffers, const NSUInteger *offsets,  \
                                   NSRange range) {                                                                      \
        for (NSUInteger i = 0; i < range.length; i++) abRecordBuffer(self, stage, buffers[i], offsets[i], range.location + i); \
        abOrigSetBuffers[stage](self, _cmd, buffers, offsets, range);                                                    \
    }                                                                                                                    \
    static void abSetBytes##name(id self, SEL _cmd, const void *bytes, NSUInteger length, NSUInteger index) {            \
        if (index < 31) {                                                                                                \
            MTLShimABState *s = abState(self);                                                                           \
            s->buffers[stage][index] = nil;                                                                              \
            s->bytes[stage][index] = length <= 4096 ? [NSData dataWithBytes:bytes length:length] : nil;                   \
        }                                                                                                                \
        abOrigSetBytes[stage](self, _cmd, bytes, length, index);                                                         \
    }
AB_STAGE_HOOKS(Vertex, 0)
AB_STAGE_HOOKS(Fragment, 1)
AB_STAGE_HOOKS(Compute, 2)

// item 79: what the app binds at texture and sampler indices, to put back after a draw that borrowed them
typedef void (*ABSetTextureIMP)(id, SEL, id, NSUInteger);
typedef void (*ABSetTexturesIMP)(id, SEL, const id __unsafe_unretained *, NSRange);
typedef void (*ABSetSamplerLodIMP)(id, SEL, id, float, float, NSUInteger);
typedef void (*ABSetSamplersLodIMP)(id, SEL, const id __unsafe_unretained *, const float *, const float *, NSRange);
static ABSetTextureIMP abOrigSetTexture[3], abOrigSetSampler[3];
static ABSetTexturesIMP abOrigSetTextures[3], abOrigSetSamplers[3];
static ABSetSamplerLodIMP abOrigSetSamplerLod[3];
static ABSetSamplersLodIMP abOrigSetSamplersLod[3];
static SEL abSetTextureSel[3], abSetSamplerSel[3], abSetSamplerLodSel[3];
static void abRecordTexture(id encoder, int stage, id texture, NSUInteger index) {
    if (index < 31) abState(encoder)->textures[stage][index] = texture;
}
static void abRecordSampler(id encoder, int stage, id sampler, BOOL clamped, float min, float max, NSUInteger index) {
    if (index >= 16) return;
    MTLShimABState *s = abState(encoder);
    s->samplers[stage][index] = sampler;
    s->clamped[stage][index] = clamped;
    s->lodMin[stage][index] = min;
    s->lodMax[stage][index] = max;
}
#define AB_HANDLE_HOOKS(name, stage)                                                                                    \
    static void abSetTexture##name(id self, SEL _cmd, id texture, NSUInteger index) {                                     \
        abRecordTexture(self, stage, texture, index);                                                                    \
        abOrigSetTexture[stage](self, _cmd, texture, index);                                                             \
    }                                                                                                                    \
    static void abSetTextures##name(id self, SEL _cmd, const id __unsafe_unretained *textures, NSRange range) {           \
        for (NSUInteger i = 0; i < range.length; i++) abRecordTexture(self, stage, textures[i], range.location + i);      \
        abOrigSetTextures[stage](self, _cmd, textures, range);                                                           \
    }                                                                                                                    \
    static void abSetSampler##name(id self, SEL _cmd, id sampler, NSUInteger index) {                                     \
        abRecordSampler(self, stage, sampler, NO, 0, 0, index);                                                          \
        abOrigSetSampler[stage](self, _cmd, sampler, index);                                                             \
    }                                                                                                                    \
    static void abSetSamplers##name(id self, SEL _cmd, const id __unsafe_unretained *samplers, NSRange range) {           \
        for (NSUInteger i = 0; i < range.length; i++) abRecordSampler(self, stage, samplers[i], NO, 0, 0, range.location + i); \
        abOrigSetSamplers[stage](self, _cmd, samplers, range);                                                           \
    }                                                                                                                    \
    static void abSetSamplerLod##name(id self, SEL _cmd, id sampler, float min, float max, NSUInteger index) {            \
        abRecordSampler(self, stage, sampler, YES, min, max, index);                                                     \
        abOrigSetSamplerLod[stage](self, _cmd, sampler, min, max, index);                                                \
    }                                                                                                                    \
    static void abSetSamplersLod##name(id self, SEL _cmd, const id __unsafe_unretained *samplers, const float *mins,      \
                                       const float *maxs, NSRange range) {                                               \
        for (NSUInteger i = 0; i < range.length; i++)                                                                    \
            abRecordSampler(self, stage, samplers[i], mins != NULL, mins ? mins[i] : 0, maxs ? maxs[i] : 0, range.location + i); \
        abOrigSetSamplersLod[stage](self, _cmd, samplers, mins, maxs, range);                                            \
    }
AB_HANDLE_HOOKS(Vertex, 0)
AB_HANDLE_HOOKS(Fragment, 1)
AB_HANDLE_HOOKS(Compute, 2)

static void abSetRenderPipeline(id self, SEL _cmd, id pipeline) {
    abState(self)->bindings = objc_getAssociatedObject(pipeline, kABBindingsKey);
    abOrigSetRenderPipeline(self, _cmd, pipeline);
}
static void abSetComputePipeline(id self, SEL _cmd, id pipeline) {
    abState(self)->bindings = objc_getAssociatedObject(pipeline, kABBindingsKey);
    abOrigSetComputePipeline(self, _cmd, pipeline);
}

// Binds what the bound argument buffers point to (restore NO), or puts back what the app had bound there (YES).
static void abBind(id encoder, BOOL restore) {
    MTLShimABState *s = objc_getAssociatedObject(encoder, kABStateKey);
    if (!s || !s->bindings) return;
    const ABBinding *b = s->bindings.bytes;
    for (NSUInteger k = 0; k < s->bindings.length / sizeof(ABBinding); k++) {
        int st = b[k].stage, h = b[k].hidden;
        if (restore && b[k].kind == kABTexture) {
            if (s->textures[st][h]) abOrigSetTexture[st](encoder, abSetTextureSel[st], s->textures[st][h], h);
            continue;
        }
        if (restore && b[k].kind == kABSampler) {
            if (s->samplers[st][h] && s->clamped[st][h])
                abOrigSetSamplerLod[st](encoder, abSetSamplerLodSel[st], s->samplers[st][h], s->lodMin[st][h], s->lodMax[st][h], h);
            else if (s->samplers[st][h])
                abOrigSetSampler[st](encoder, abSetSamplerSel[st], s->samplers[st][h], h);
            continue;
        }
        if (restore) {
            if (s->buffers[st][b[k].hidden])
                abOrigSetBuffer[st](encoder, abSetBufferSel[st], s->buffers[st][b[k].hidden], s->offsets[st][b[k].hidden], b[k].hidden);
            else if (s->bytes[st][b[k].hidden])
                abOrigSetBytes[st](encoder, abSetBytesSel[st], s->bytes[st][b[k].hidden].bytes, s->bytes[st][b[k].hidden].length, b[k].hidden);
            continue;
        }
        id argumentBuffer = s->buffers[st][b[k].argument];
        const uint8_t *p = NULL;
        NSUInteger length = 0, base = 0;
        if (argumentBuffer) {
            p = [argumentBuffer contents];
            length = [argumentBuffer length];
            base = s->offsets[st][b[k].argument];
        } else if (s->bytes[st][b[k].argument]) {
            p = s->bytes[st][b[k].argument].bytes;
            length = s->bytes[st][b[k].argument].length;
        }
        if (!p || base + b[k].offset + 8 > length) continue;
        uint64_t token;
        memcpy(&token, p + base + b[k].offset, sizeof token);
        id target = abBufferForId((uint32_t)(token >> 32));
        if (!target) continue;
        if (b[k].kind == kABTexture) abOrigSetTexture[st](encoder, abSetTextureSel[st], target, h);
        else if (b[k].kind == kABSampler) abOrigSetSampler[st](encoder, abSetSamplerSel[st], target, h);
        else abOrigSetBuffer[st](encoder, abSetBufferSel[st], target, (uint32_t)token, h);
    }
}

#define AB_DRAW(name, params, args)                                                                                     \
    typedef void (*ABDraw##name##IMP) params;                                                                            \
    static ABDraw##name##IMP abOrigDraw##name;                                                                           \
    static void abDraw##name params {                                                                                   \
        abBind(self, NO);                                                                                                \
        abOrigDraw##name args;                                                                                           \
        abBind(self, YES);                                                                                               \
    }
AB_DRAW(P, (id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c), (self, _cmd, t, s, c))
AB_DRAW(PI, (id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i), (self, _cmd, t, s, c, i))
AB_DRAW(PIB, (id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i, NSUInteger b), (self, _cmd, t, s, c, i, b))
AB_DRAW(PInd, (id self, SEL _cmd, NSUInteger t, id ib, NSUInteger o), (self, _cmd, t, ib, o))
AB_DRAW(X, (id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, id ib, NSUInteger io), (self, _cmd, t, c, it, ib, io))
AB_DRAW(XI, (id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, id ib, NSUInteger io, NSUInteger i), (self, _cmd, t, c, it, ib, io, i))
AB_DRAW(XIB, (id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi),
        (self, _cmd, t, c, it, ib, io, i, bv, bi))
AB_DRAW(XInd, (id self, SEL _cmd, NSUInteger t, NSUInteger it, id ib, NSUInteger io, id indirect, NSUInteger o), (self, _cmd, t, it, ib, io, indirect, o))
AB_DRAW(DG, (id self, SEL _cmd, MTLSize g, MTLSize t), (self, _cmd, g, t))
AB_DRAW(DT, (id self, SEL _cmd, MTLSize g, MTLSize t), (self, _cmd, g, t))
AB_DRAW(DInd, (id self, SEL _cmd, id indirect, NSUInteger o, MTLSize t), (self, _cmd, indirect, o, t))

static void installIvbArgumentBuffers(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_IVB_ARGUMENT_BUFFERS");
    Class device = objc_getClass("MTLIGAccelDevice");
    if (done || !device || (setting && !strcmp(setting, "0")) || definesMethod("MTLIGAccelDevice", "newArgumentEncoderWithLayout:") ||
        definesMethod("MTLIGAccelDevice", "newIndirectArgumentBufferLayoutWithStructType:"))
        return;  // not the Ivy Bridge driver (the 12.x driver has argument buffers of its own), or switched off
    done = YES;
    static const char *const kRender = "MTLIGAccelRenderCommandEncoder", *const kCompute = "MTLIGAccelComputeCommandEncoder";
    const char *const stageClass[3] = {kRender, kRender, kCompute};
    const char *const setBuffer[3] = {"setVertexBuffer:offset:atIndex:", "setFragmentBuffer:offset:atIndex:", "setBuffer:offset:atIndex:"};
    const char *const setOffset[3] = {"setVertexBufferOffset:atIndex:", "setFragmentBufferOffset:atIndex:", "setBufferOffset:atIndex:"};
    const char *const setBuffers[3] = {"setVertexBuffers:offsets:withRange:", "setFragmentBuffers:offsets:withRange:", "setBuffers:offsets:withRange:"};
    const char *const setBytes[3] = {"setVertexBytes:length:atIndex:", "setFragmentBytes:length:atIndex:", "setBytes:length:atIndex:"};
    for (int st = 0; st < 3; st++)
        if (!definesMethod(stageClass[st], setBuffer[st]) || !definesMethod(stageClass[st], setOffset[st]) ||
            !definesMethod(stageClass[st], setBuffers[st]) || !definesMethod(stageClass[st], setBytes[st]))
            return;
    if (!definesMethod(kRender, "setRenderPipelineState:") || !definesMethod(kCompute, "setComputePipelineState:")) return;
    class_addMethod(device, sel_registerName("newIndirectArgumentBufferLayoutWithStructType:"), (IMP)ivbNewArgumentLayout, "@@:@");
    class_addMethod(device, sel_registerName("newArgumentEncoderWithLayout:"), (IMP)ivbNewArgumentEncoder, "@@:@");
    const IMP bufferHooks[3] = {(IMP)abSetBufferVertex, (IMP)abSetBufferFragment, (IMP)abSetBufferCompute};
    const IMP offsetHooks[3] = {(IMP)abSetOffsetVertex, (IMP)abSetOffsetFragment, (IMP)abSetOffsetCompute};
    const IMP buffersHooks[3] = {(IMP)abSetBuffersVertex, (IMP)abSetBuffersFragment, (IMP)abSetBuffersCompute};
    const IMP bytesHooks[3] = {(IMP)abSetBytesVertex, (IMP)abSetBytesFragment, (IMP)abSetBytesCompute};
    for (int st = 0; st < 3; st++) {
        abSetBufferSel[st] = sel_registerName(setBuffer[st]);
        abSetBytesSel[st] = sel_registerName(setBytes[st]);
        abOrigSetBuffer[st] = (ABSetBufferIMP)swizzle(stageClass[st], setBuffer[st], bufferHooks[st]);
        abOrigSetOffset[st] = (ABSetOffsetIMP)swizzle(stageClass[st], setOffset[st], offsetHooks[st]);
        abOrigSetBuffers[st] = (ABSetBuffersIMP)swizzle(stageClass[st], setBuffers[st], buffersHooks[st]);
        abOrigSetBytes[st] = (ABSetBytesIMP)swizzle(stageClass[st], setBytes[st], bytesHooks[st]);
    }
    abOrigSetRenderPipeline = (ABSetPipelineIMP)swizzle(kRender, "setRenderPipelineState:", (IMP)abSetRenderPipeline);
    abOrigSetComputePipeline = (ABSetPipelineIMP)swizzle(kCompute, "setComputePipelineState:", (IMP)abSetComputePipeline);
    // item 79: textures and samplers, when the driver has every setter this needs
    const char *const setTexture[3] = {"setVertexTexture:atIndex:", "setFragmentTexture:atIndex:", "setTexture:atIndex:"};
    const char *const setTextures[3] = {"setVertexTextures:withRange:", "setFragmentTextures:withRange:", "setTextures:withRange:"};
    const char *const setSampler[3] = {"setVertexSamplerState:atIndex:", "setFragmentSamplerState:atIndex:", "setSamplerState:atIndex:"};
    const char *const setSamplers[3] = {"setVertexSamplerStates:withRange:", "setFragmentSamplerStates:withRange:", "setSamplerStates:withRange:"};
    const char *const setSamplerLod[3] = {"setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:",
                                          "setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:", "setSamplerState:lodMinClamp:lodMaxClamp:atIndex:"};
    const char *const setSamplersLod[3] = {"setVertexSamplerStates:lodMinClamps:lodMaxClamps:withRange:",
                                           "setFragmentSamplerStates:lodMinClamps:lodMaxClamps:withRange:",
                                           "setSamplerStates:lodMinClamps:lodMaxClamps:withRange:"};
    const char *handles = getenv("MTLSHIM_IVB_ARGUMENT_BUFFER_TEXTURES");
    BOOL texturesOn = !(handles && !strcmp(handles, "0"));
    for (int st = 0; st < 3 && texturesOn; st++)
        if (!definesMethod(stageClass[st], setTexture[st]) || !definesMethod(stageClass[st], setTextures[st]) ||
            !definesMethod(stageClass[st], setSampler[st]) || !definesMethod(stageClass[st], setSamplers[st]) ||
            !definesMethod(stageClass[st], setSamplerLod[st]) || !definesMethod(stageClass[st], setSamplersLod[st]))
            texturesOn = NO;
    if (texturesOn) {
        const IMP textureHooks[3] = {(IMP)abSetTextureVertex, (IMP)abSetTextureFragment, (IMP)abSetTextureCompute};
        const IMP texturesHooks[3] = {(IMP)abSetTexturesVertex, (IMP)abSetTexturesFragment, (IMP)abSetTexturesCompute};
        const IMP samplerHooks[3] = {(IMP)abSetSamplerVertex, (IMP)abSetSamplerFragment, (IMP)abSetSamplerCompute};
        const IMP samplersHooks[3] = {(IMP)abSetSamplersVertex, (IMP)abSetSamplersFragment, (IMP)abSetSamplersCompute};
        const IMP samplerLodHooks[3] = {(IMP)abSetSamplerLodVertex, (IMP)abSetSamplerLodFragment, (IMP)abSetSamplerLodCompute};
        const IMP samplersLodHooks[3] = {(IMP)abSetSamplersLodVertex, (IMP)abSetSamplersLodFragment, (IMP)abSetSamplersLodCompute};
        for (int st = 0; st < 3; st++) {
            abSetTextureSel[st] = sel_registerName(setTexture[st]);
            abSetSamplerSel[st] = sel_registerName(setSampler[st]);
            abSetSamplerLodSel[st] = sel_registerName(setSamplerLod[st]);
            abOrigSetTexture[st] = (ABSetTextureIMP)swizzle(stageClass[st], setTexture[st], textureHooks[st]);
            abOrigSetTextures[st] = (ABSetTexturesIMP)swizzle(stageClass[st], setTextures[st], texturesHooks[st]);
            abOrigSetSampler[st] = (ABSetTextureIMP)swizzle(stageClass[st], setSampler[st], samplerHooks[st]);
            abOrigSetSamplers[st] = (ABSetTexturesIMP)swizzle(stageClass[st], setSamplers[st], samplersHooks[st]);
            abOrigSetSamplerLod[st] = (ABSetSamplerLodIMP)swizzle(stageClass[st], setSamplerLod[st], samplerLodHooks[st]);
            abOrigSetSamplersLod[st] = (ABSetSamplersLodIMP)swizzle(stageClass[st], setSamplersLod[st], samplersLodHooks[st]);
        }
        abTexturesOn = YES;
    }
    const struct { const char *cls, *sel; IMP imp; IMP *orig; } draws[] = {
        {kRender, "drawPrimitives:vertexStart:vertexCount:", (IMP)abDrawP, (IMP *)&abOrigDrawP},
        {kRender, "drawPrimitives:vertexStart:vertexCount:instanceCount:", (IMP)abDrawPI, (IMP *)&abOrigDrawPI},
        {kRender, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", (IMP)abDrawPIB, (IMP *)&abOrigDrawPIB},
        {kRender, "drawPrimitives:indirectBuffer:indirectBufferOffset:", (IMP)abDrawPInd, (IMP *)&abOrigDrawPInd},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", (IMP)abDrawX, (IMP *)&abOrigDrawX},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", (IMP)abDrawXI, (IMP *)&abOrigDrawXI},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",
         (IMP)abDrawXIB, (IMP *)&abOrigDrawXIB},
        {kRender, "drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:", (IMP)abDrawXInd,
         (IMP *)&abOrigDrawXInd},
        {kCompute, "dispatchThreadgroups:threadsPerThreadgroup:", (IMP)abDrawDG, (IMP *)&abOrigDrawDG},
        {kCompute, "dispatchThreads:threadsPerThreadgroup:", (IMP)abDrawDT, (IMP *)&abOrigDrawDT},
        {kCompute, "dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:", (IMP)abDrawDInd, (IMP *)&abOrigDrawDInd},
    };
    for (size_t i = 0; i < sizeof draws / sizeof *draws; i++)
        if (definesMethod(draws[i].cls, draws[i].sel)) *draws[i].orig = swizzle(draws[i].cls, draws[i].sel, draws[i].imp);
    const struct { const char *sel; IMP imp; IMP *orig; } pipelines[] = {
        {"newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)abRenderRefl, (IMP *)&abOrigRenderRefl},
        {"newRenderPipelineStateWithDescriptor:options:completionHandler:", (IMP)abRenderOptAsync, (IMP *)&abOrigRenderOptAsync},
        {"newComputePipelineStateWithFunction:options:reflection:error:", (IMP)abComputeFnRefl, (IMP *)&abOrigComputeFnRefl},
        {"newComputePipelineStateWithDescriptor:options:reflection:error:", (IMP)abComputeDescRefl, (IMP *)&abOrigComputeDescRefl},
        {"newComputePipelineStateWithFunction:options:completionHandler:", (IMP)abComputeFnOptAsync, (IMP *)&abOrigComputeFnOptAsync},
        {"newComputePipelineStateWithDescriptor:options:completionHandler:", (IMP)abComputeDescOptAsync, (IMP *)&abOrigComputeDescOptAsync},
    };
    for (size_t i = 0; i < sizeof pipelines / sizeof *pipelines; i++)
        if (definesMethod("_MTLDevice", pipelines[i].sel)) *pipelines[i].orig = swizzle("_MTLDevice", pipelines[i].sel, pipelines[i].imp);
    // the variants without reflection go through the ones above (item 21 wraps the render ones first; those stay)
    if (abOrigRenderRefl) {
        swizzle("_MTLDevice", "newRenderPipelineStateWithDescriptor:error:", (IMP)abRender);
        if (abOrigRenderOptAsync) swizzle("_MTLDevice", "newRenderPipelineStateWithDescriptor:completionHandler:", (IMP)abRenderAsync);
    }
    if (abOrigComputeFnRefl) {
        swizzle("_MTLDevice", "newComputePipelineStateWithFunction:error:", (IMP)abComputeFn);
        if (abOrigComputeFnOptAsync) swizzle("_MTLDevice", "newComputePipelineStateWithFunction:completionHandler:", (IMP)abComputeFnAsync);
    }
    ivbArgumentBuffersOn = YES;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] argument buffers on the Ivy Bridge GPU: encoders and hidden bindings installed\n");
}
#pragma clang diagnostic pop

// 48. Direct draws after an indirect draw on the Ivy Bridge driver: once a render encoder has drawn through an indirect
// buffer, every later direct draw in it keeps that draw's base instance, and in vertex functions that read
// [[vertex_id]] (the Intel adapter declares BASE_VERTEX_ID for them, i13) its base or start vertex too: [[instance_id]]
// and [[vertex_id]] come out as the indirect draw's. Setting the pipeline again doesn't reset it; a new encoder does.
// MoltenVK and WebGPU mix both kinds of draw in one pass. Indirect draws are right whatever came before, so once an
// encoder has drawn indirectly, its direct draws go through an indirect buffer of the shim's own (20 bytes a draw, in
// 4 KB shared buffers the command buffer keeps until it completes). Ivy Bridge driver only.
// MTLSHIM_IVB_DRAW_PARAMETERS=0 turns it off. (i13)
@interface MTLShimDrawArguments : NSObject {
@public
    id<MTLBuffer> buffer;
    NSUInteger used;
}
@end
@implementation MTLShimDrawArguments
@end

static const void *const kDrawArgumentsKey = &kDrawArgumentsKey;
static BOOL ipIndirectSeen;  // any indirect draw yet: until then the direct draws don't look anything up
typedef void (*IPDrawPIndIMP)(id, SEL, MTLPrimitiveType, id<MTLBuffer>, NSUInteger);
typedef void (*IPDrawXIndIMP)(id, SEL, MTLPrimitiveType, MTLIndexType, id<MTLBuffer>, NSUInteger, id<MTLBuffer>, NSUInteger);
typedef void (*IPDrawPIMP)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
typedef void (*IPDrawPIIMP)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
typedef void (*IPDrawPIBIMP)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
typedef void (*IPDrawXIMP)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id<MTLBuffer>, NSUInteger);
typedef void (*IPDrawXIIMP)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id<MTLBuffer>, NSUInteger, NSUInteger);
typedef void (*IPDrawXIBIMP)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id<MTLBuffer>, NSUInteger, NSUInteger, NSInteger, NSUInteger);
static IPDrawPIndIMP ipOrigDrawPInd;
static IPDrawXIndIMP ipOrigDrawXInd;
static IPDrawPIMP ipOrigDrawP;
static IPDrawPIIMP ipOrigDrawPI;
static IPDrawPIBIMP ipOrigDrawPIB;
static IPDrawXIMP ipOrigDrawX;
static IPDrawXIIMP ipOrigDrawXI;
static IPDrawXIBIMP ipOrigDrawXIB;

static void ipMarkIndirect(id encoder) {
    if (objc_getAssociatedObject(encoder, kDrawArgumentsKey)) return;
    objc_setAssociatedObject(encoder, kDrawArgumentsKey, [MTLShimDrawArguments new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ipIndirectSeen = YES;
}

// the arguments copied into this encoder's argument buffer, or nil while the encoder hasn't drawn indirectly
static id<MTLBuffer> ipArguments(id encoder, const void *arguments, NSUInteger length, NSUInteger *offset) {
    if (!ipIndirectSeen) return nil;
    MTLShimDrawArguments *s = objc_getAssociatedObject(encoder, kDrawArgumentsKey);
    if (!s) return nil;
    if (!s->buffer || s->used + length > s->buffer.length) {
        id<MTLCommandBuffer> commandBuffer = [encoder commandBuffer];
        id<MTLBuffer> buffer = [[encoder device] newBufferWithLength:4096
                                                            options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        if (!buffer || !commandBuffer) return nil;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)buffer; }];  // kept until the GPU is done with it
        s->buffer = buffer;
        s->used = 0;
    }
    memcpy((char *)s->buffer.contents + s->used, arguments, length);
    *offset = s->used;
    s->used += (length + 3) & ~(NSUInteger)3;
    return s->buffer;
}

static void ipDrawPInd(id self, SEL _cmd, MTLPrimitiveType type, id<MTLBuffer> indirect, NSUInteger offset) {
    ipOrigDrawPInd(self, _cmd, type, indirect, offset);
    ipMarkIndirect(self);
}

static void ipDrawXInd(id self, SEL _cmd, MTLPrimitiveType type, MTLIndexType indexType, id<MTLBuffer> indexBuffer,
                       NSUInteger indexOffset, id<MTLBuffer> indirect, NSUInteger offset) {
    ipOrigDrawXInd(self, _cmd, type, indexType, indexBuffer, indexOffset, indirect, offset);
    ipMarkIndirect(self);
}

static BOOL ipDrawPrimitives(id self, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger baseInstance) {
    MTLDrawPrimitivesIndirectArguments a = {(uint32_t)count, (uint32_t)instances, (uint32_t)start, (uint32_t)baseInstance};
    NSUInteger offset;
    id<MTLBuffer> buffer = ipArguments(self, &a, sizeof a, &offset);
    if (!buffer) return NO;
    ipOrigDrawPInd(self, @selector(drawPrimitives:indirectBuffer:indirectBufferOffset:), type, buffer, offset);
    return YES;
}

static BOOL ipDrawIndexed(id self, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, id<MTLBuffer> indexBuffer,
                          NSUInteger indexOffset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    NSUInteger size = indexType == MTLIndexTypeUInt16 ? 2 : 4, first = 0;
    if (indexOffset % size == 0) first = indexOffset / size, indexOffset = 0;
    MTLDrawIndexedPrimitivesIndirectArguments a = {(uint32_t)count, (uint32_t)instances, (uint32_t)first, (int32_t)baseVertex, (uint32_t)baseInstance};
    NSUInteger offset;
    id<MTLBuffer> buffer = ipArguments(self, &a, sizeof a, &offset);
    if (!buffer) return NO;
    ipOrigDrawXInd(self, @selector(drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:),
                   type, indexType, indexBuffer, indexOffset, buffer, offset);
    return YES;
}

static void ipDrawP(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count) {
    if (!ipDrawPrimitives(self, type, start, count, 1, 0)) ipOrigDrawP(self, _cmd, type, start, count);
}

static void ipDrawPI(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances) {
    if (!ipDrawPrimitives(self, type, start, count, instances, 0)) ipOrigDrawPI(self, _cmd, type, start, count, instances);
}

static void ipDrawPIB(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger baseInstance) {
    if (!ipDrawPrimitives(self, type, start, count, instances, baseInstance)) ipOrigDrawPIB(self, _cmd, type, start, count, instances, baseInstance);
}

static void ipDrawX(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, id<MTLBuffer> indexBuffer, NSUInteger indexOffset) {
    if (!ipDrawIndexed(self, type, count, indexType, indexBuffer, indexOffset, 1, 0, 0)) ipOrigDrawX(self, _cmd, type, count, indexType, indexBuffer, indexOffset);
}

static void ipDrawXI(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, id<MTLBuffer> indexBuffer,
                     NSUInteger indexOffset, NSUInteger instances) {
    if (!ipDrawIndexed(self, type, count, indexType, indexBuffer, indexOffset, instances, 0, 0))
        ipOrigDrawXI(self, _cmd, type, count, indexType, indexBuffer, indexOffset, instances);
}

static void ipDrawXIB(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, id<MTLBuffer> indexBuffer,
                      NSUInteger indexOffset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    if (!ipDrawIndexed(self, type, count, indexType, indexBuffer, indexOffset, instances, baseVertex, baseInstance))
        ipOrigDrawXIB(self, _cmd, type, count, indexType, indexBuffer, indexOffset, instances, baseVertex, baseInstance);
}

static void ivbDrawParameters(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_IVB_DRAW_PARAMETERS");
    static const char *const kRender = "MTLIGAccelRenderCommandEncoder";
    Class encoder = objc_getClass(kRender);
    const char *image = encoder ? class_getImageName(encoder) : NULL;
    if (done || !image || !strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") || (setting && !strcmp(setting, "0"))) return;
    const struct { const char *sel; IMP imp; IMP *orig; } draws[] = {
        {"drawPrimitives:indirectBuffer:indirectBufferOffset:", (IMP)ipDrawPInd, (IMP *)&ipOrigDrawPInd},
        {"drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:", (IMP)ipDrawXInd, (IMP *)&ipOrigDrawXInd},
        {"drawPrimitives:vertexStart:vertexCount:", (IMP)ipDrawP, (IMP *)&ipOrigDrawP},
        {"drawPrimitives:vertexStart:vertexCount:instanceCount:", (IMP)ipDrawPI, (IMP *)&ipOrigDrawPI},
        {"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", (IMP)ipDrawPIB, (IMP *)&ipOrigDrawPIB},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", (IMP)ipDrawX, (IMP *)&ipOrigDrawX},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", (IMP)ipDrawXI, (IMP *)&ipOrigDrawXI},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", (IMP)ipDrawXIB,
         (IMP *)&ipOrigDrawXIB},
    };
    for (size_t i = 0; i < sizeof draws / sizeof *draws; i++)
        if (!definesMethod(kRender, draws[i].sel)) return;
    done = YES;
    for (size_t i = 0; i < sizeof draws / sizeof *draws; i++) *draws[i].orig = swizzle(kRender, draws[i].sel, draws[i].imp);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Ivy Bridge: direct draws after an indirect draw go through an indirect buffer\n");
}

static BOOL patched;

// 21. Depth-only render pipelines on the 12.x Intel driver: a pipeline without a fragment function leaves its depth
// attachment unusable: a later draw of the same triangles with compare Equal passes nowhere, single- or multisampled
// (WebGPU CTS copyTextureToTexture copy_depth_stencil / copy_multisampled_depth, rendering/stencil). With an empty
// fragment function the same pipeline writes correct depth, so on the Intel GPU a rasterizing pipeline with no
// fragment function, no color attachments and a depth or stencil attachment gets one (compiled once per device).
// Pipelines with color attachments are left as they are.
static const void *kEmptyFragmentKey = &kEmptyFragmentKey;
typedef id (*NewRenderPipelineIMP)(id, SEL, MTLRenderPipelineDescriptor *, NSError **) RETURNS_RETAINED;
typedef id (*NewRenderPipelineReflIMP)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption,
                                       MTLAutoreleasedRenderPipelineReflection *, NSError **) RETURNS_RETAINED;
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
// 66. The Kepler driver counts no samples at all for such a pipeline: a draw with every color attachment at writeMask
// none (a blendable format: an integer one still counts) and no depth or stencil attachment leaves an occlusion query at
// 0, at any sample count (GTX 770; WebGPU CTS occlusionQuery basic, reuse and scissor with writeMask 0). On Kepler such
// pipelines get the same blend that keeps the attachment. MTLSHIM_NV_MASKED_DRAWS=0 turns it off. Test: n16 on the GTX 770.
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
    static Class intel, kepler;
    if (!intel) intel = objc_getClass("MTLIGAccelDevice");
    if (!kepler) kepler = objc_getClass("NVMTLDevice");
    BOOL onIntel = intel && [(id)device isKindOfClass:intel], onKepler = !onIntel && kepler && [(id)device isKindOfClass:kepler];
    if ((!onIntel && !onKepler) || !descriptor || !descriptor.fragmentFunction || !descriptor.rasterizationEnabled ||
        descriptor.depthAttachmentPixelFormat != MTLPixelFormatInvalid || descriptor.stencilAttachmentPixelFormat != MTLPixelFormatInvalid ||
        (onIntel && descriptor.rasterSampleCount <= 1 && !descriptor.alphaToCoverageEnabled))  // item 66: any sample count on Kepler
        return descriptor;
    const char *setting = getenv(onKepler ? "MTLSHIM_NV_MASKED_DRAWS" : "MTLSHIM_COVERAGE_WRITE");
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

// 73. Rendering without attachments: a render pipeline with no color, depth or stencil attachment, drawn in a pass that
// has only a render target size (Vulkan subpasses without attachments, which MoltenVK always takes Metal to support; Godot
// 4.7's editor makes them at start). On the family-1 GPUs MetalOld's validation aborts the app when such a pipeline is
// made ("No valid pixelFormats set"; Kepler, and the 12.x Intel driver). Such pipelines get a color attachment 0 of
// R8Unorm with writeMask none, and such passes a private R8Unorm texture of the render target's size, layer count and
// sample count (kept per device), loaded and stored as don't-care. The fragment function, its buffer and texture writes
// and visibility results stay as they are (item 66 makes Kepler count samples for the masked attachment). Family-2 GPUs
// are left alone. MTLSHIM_NO_ATTACHMENTS=0 turns it off. Test: s79.
static BOOL familyTwo(const void *device);
static BOOL attachmentsEmulated(id<MTLDevice> device) {
    static int setting;  // 1 on, -1 off
    if (!setting) {
        const char *value = getenv("MTLSHIM_NO_ATTACHMENTS");
        setting = value && !strcmp(value, "0") ? -1 : 1;
    }
    return setting > 0 && device && !familyTwo((__bridge const void *)device);
}

static MTLRenderPipelineDescriptor *withDummyAttachment(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    if (!descriptor || !descriptor.rasterizationEnabled || descriptor.depthAttachmentPixelFormat != MTLPixelFormatInvalid ||
        descriptor.stencilAttachmentPixelFormat != MTLPixelFormatInvalid)
        return descriptor;
    for (NSUInteger i = 0; i < 8; i++)
        if (descriptor.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid) return descriptor;
    if (!attachmentsEmulated(device)) return descriptor;
    MTLRenderPipelineDescriptor *copy = [descriptor copy];
    copy.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
    copy.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] render pipeline without attachments: a masked R8Unorm color attachment added\n");
    return copy;
}

static const void *kDummyTargetsKey = &kDummyTargetsKey;
static MTLRenderPassDescriptor *withDummyTarget(id<MTLCommandBuffer> buffer, MTLRenderPassDescriptor *descriptor) {
    if (!descriptor || !descriptor.renderTargetWidth || !descriptor.renderTargetHeight || descriptor.depthAttachment.texture ||
        descriptor.stencilAttachment.texture)
        return descriptor;
    for (NSUInteger i = 0; i < 8; i++)
        if (descriptor.colorAttachments[i].texture) return descriptor;
    id<MTLDevice> device = buffer.device;
    if (!attachmentsEmulated(device)) return descriptor;
    NSUInteger width = descriptor.renderTargetWidth, height = descriptor.renderTargetHeight;
    NSUInteger layers = MAX(descriptor.renderTargetArrayLength, 1), samples = MAX(descriptor.defaultRasterSampleCount, 1);
    NSString *key = [NSString stringWithFormat:@"%lux%lux%lux%lu", (unsigned long)width, (unsigned long)height, (unsigned long)layers, (unsigned long)samples];
    NSCache *cache;
    @synchronized((id)device) {
        cache = objc_getAssociatedObject(device, kDummyTargetsKey);
        if (!cache) {
            cache = [NSCache new];
            cache.countLimit = 8;
            objc_setAssociatedObject(device, kDummyTargetsKey, cache, OBJC_ASSOCIATION_RETAIN);
        }
    }
    id<MTLTexture> target = [cache objectForKey:key];
    if (!target) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.pixelFormat = MTLPixelFormatR8Unorm;
        td.width = width;
        td.height = height;
        td.arrayLength = layers;
        td.sampleCount = samples;
        td.textureType = samples > 1 ? (layers > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample)
                                     : (layers > 1 ? MTLTextureType2DArray : MTLTextureType2D);
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        target = [device newTextureWithDescriptor:td];
        if (!target) return descriptor;
        [cache setObject:target forKey:key];
    }
    MTLRenderPassDescriptor *copy = [descriptor copy];
    copy.colorAttachments[0].texture = target;
    copy.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    copy.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] render pass without attachments: an R8Unorm target of %s added\n", key.UTF8String);
    return copy;
}

// Item 77 for render pipelines: rasterSampleCount 2 becomes 4 on a device without 2x.
static MTLRenderPipelineDescriptor *withFourSamples(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    if (!descriptor || descriptor.rasterSampleCount != 2 || !promotesTwoSamples(device)) return descriptor;
    MTLRenderPipelineDescriptor *copy = [descriptor copy];
    copy.rasterSampleCount = 4;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 2x render pipeline made 4x (the device has no 2x)\n");
    return copy;
}

// Item 77 for passes without attachments: defaultRasterSampleCount 2 becomes 4 on a device without 2x.
static MTLRenderPassDescriptor *passWithFourSamples(id<MTLCommandBuffer> buffer, MTLRenderPassDescriptor *descriptor) {
    if (!descriptor || descriptor.defaultRasterSampleCount != 2 || !promotesTwoSamples(buffer.device)) return descriptor;
    MTLRenderPassDescriptor *copy = [descriptor copy];
    copy.defaultRasterSampleCount = 4;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] 2x render pass made 4x (the device has no 2x)\n");
    return copy;
}

static MTLRenderPipelineDescriptor *adjustedPipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor) {
    return withCoverageWrite(device, withEmptyFragment(device, withDummyAttachment(device, withFourSamples(device, descriptor))));  // items 77, 73, 21 and 34
}

static id newRenderPipeline(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error) RETURNS_RETAINED;
static id newRenderPipeline(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error) {
    return origNewRenderPipeline(self, _cmd, adjustedPipeline(self, descriptor), error);
}

static id newRenderPipelineRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options,
                                MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) RETURNS_RETAINED;
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
    guardArgumentEncoders();
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
// Chromium's ANGLE loads the same shaders built for macOS 10.14 (isTooOldANGLELibrary). When ANGLE loads that metallib,
// compile ANGLE's internal-shader source (ANGLEInternalShaders.h, generated by make_angle_shaders.py from WebKit's
// mtl_internal_shaders_autogen.metal) and return that library if it has every function of the prebuilt one, with the same
// function type and function constants (functions only the source has are fine: ANGLE asks for the names it knows; Chromium
// 120's library lacks saturateDepth, and its blits aborted the compiler on Tahoe, s74 on the Iris Pro); otherwise the
// prebuilt library is returned as before. Safari 18.6 on Sequoia has an older ANGLE (early
// 2025), whose library targets air64-apple-macosx15.8.0 (AIR 2.7: "air version set to 2.7.0, but expecting 2.6") and
// does texture/buffer copies with kernels the newer source replaced (readFromBufferToFloatTexture, ...): every
// antialiased WebGL context failed its multisample resolve, so nothing drew. That library gets the source of WebKit's
// matching ANGLE (ANGLEInternalShadersSafari18.h, WebKit 23cdc2123a51) instead.
#include "ANGLEInternalShaders.h"
#include "ANGLEInternalShadersSafari18.h"
static BOOL fromChromium(const void *returnAddress);

static BOOL isTooNewANGLELibrary(dispatch_data_t data) {
    const void *bytes = NULL;
    size_t size = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &size);
    BOOL found = NO;
    // ANGLE's internal library: its source file's name, or (Safari 18.6 on Sequoia) only its rx::mtl_shader symbols
    if (memmem(bytes, size, "mtl_internal_shaders_autogen", 28) || memmem(bytes, size, "rx10mtl_shader", 14)) {
        // AIR 2.7 or newer: "air64_v27"..., or a target triple of macOS 15.4 or later ("air64-apple-macosx15.8.0")
        for (const char *p = bytes, *end = p + size; !found && (p = memmem(p, end - p, "air64_v", 7)); p += 7)
            found = p + 9 <= end && isdigit(p[7]) && isdigit(p[8]) && (p[7] - '0') * 10 + (p[8] - '0') >= 27;
        for (const char *p = bytes, *end = p + size; !found && (p = memmem(p, end - p, "air64-apple-macosx", 18)); p += 18) {
            int major = 0, minor = 0;
            const char *q = p + 18;
            while (q < end && isdigit(*q)) major = major * 10 + (*q++ - '0');
            if (q < end && *q == '.') for (q++; q < end && isdigit(*q); q++) minor = minor * 10 + (*q - '0');
            found = major > 15 || (major == 15 && minor >= 4);
        }
    }
    (void)map;
    return found;
}

// Chromium's ANGLE (Chrome, Electron apps) ships the same library built for macOS 10.14 (air64-apple-macosx10.14.0, AIR 2.1),
// whose texture reads and samples return the texel alone, where the 14.2 front end's own modules (AIR 2.6) have them return
// { texel, i8 }. Tahoe's compiler for this stack can't take such a library down to the 3802 back ends: OCLP's libLLVM
// wrapper (libLLVM_helper's fixIr) relabels every module the front end reads AIR 2.5 / macOS 13.2 without touching its
// calls, specializing makes that 2.6, and the downgrade then rewrites calls that already have the old form (an insertvalue
// into a <4 x float>, an argument dropped). The 3802 reader aborts MTLCompilerService on what was written ("INSERTVAL:
// Invalid type", "Invalid record"), three times per pipeline. Functions without function constants (the mipmap kernels) go
// to the downgrade as they are and come out the same way. Every blit pipeline ANGLE builds fails. Such a library gets the
// source too. MTLSHIM_OLD_ANGLE_LIBRARY=0 turns it off.
static BOOL isTooOldANGLELibrary(dispatch_data_t data) {
    const void *bytes = NULL;
    size_t size = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &size);
    BOOL found = NO;
    if (memmem(bytes, size, "mtl_internal_shaders_autogen", 28) || memmem(bytes, size, "rx10mtl_shader", 14)) {
        const char *p = memmem(bytes, size, "air64-apple-macosx", 18), *end = (const char *)bytes + size;
        int major = 0;
        for (const char *q = p ? p + 18 : end; q < end && isdigit(*q); q++) major = major * 10 + (*q - '0');
        found = p && major > 0 && major < 13;
    }
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

static BOOL hasFunctionsOf(id<MTLLibrary> compiled, id<MTLLibrary> prebuilt) {  // every function of prebuilt, the same way
    NSSet *names = [NSSet setWithArray:compiled.functionNames];
    for (NSString *name in prebuilt.functionNames) {
        if (![names containsObject:name]) return NO;
        if (![functionSignature([prebuilt newFunctionWithName:name]) isEqualToString:functionSignature([compiled newFunctionWithName:name])]) return NO;
    }
    return YES;
}

static id newLibraryData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
    id library = origNewLibraryData(self, _cmd, data, error);
    if (getenv("MTLSHIM_VERBOSE")) {
        Dl_info info;
        const char *caller = dladdr(__builtin_return_address(0), &info) && info.dli_fname ? info.dli_fname : "?";
        shimLog("[mtlshim] newLibraryWithData: %zu bytes from %s: %s, Chromium/WebKit caller %d, too new for this compiler %d, too old %d\n",
                dispatch_data_get_size(data), strrchr(caller, '/') ? strrchr(caller, '/') + 1 : caller, library ? "loaded" : "failed",
                fromChromium(__builtin_return_address(0)), isTooNewANGLELibrary(data), isTooOldANGLELibrary(data));
        if (getenv("MTLSHIM_DUMP_SOURCES")) {
            const void *bytes = NULL;
            size_t size = 0;
            dispatch_data_t map = dispatch_data_create_map(data, &bytes, &size);
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mtlshim-lib-%d-%zu.metallib", getpid(), size]];
            [[NSData dataWithBytes:bytes length:size] writeToFile:path atomically:NO];
            (void)map;
            shimLog("[mtlshim] library written: %s\n", path.UTF8String);
        }
    }
    const char *oldSetting = getenv("MTLSHIM_OLD_ANGLE_LIBRARY");
    BOOL tooNew = isTooNewANGLELibrary(data), tooOld = !tooNew && !(oldSetting && !strcmp(oldSetting, "0")) && isTooOldANGLELibrary(data);
    if (!library || !fromChromium(__builtin_return_address(0)) || !(tooNew || tooOld)) return library;
    NSError *failure = nil;
    BOOL safari18 = [((id<MTLLibrary>)library).functionNames containsObject:@"readFromBufferToFloatTexture"];  // a kernel there
    id<MTLLibrary> compiled = [self newLibraryWithSource:@(safari18 ? kANGLEInternalShadersSafari18 : kANGLEInternalShaders)
                                                 options:[MTLCompileOptions new] error:&failure];
    BOOL usable = compiled && hasFunctionsOf(compiled, library);
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] ANGLE internal shaders: prebuilt library too %s; source-compiled one (%s) %s%s\n", tooNew ? "new" : "old", safari18 ? "Safari 18" : "current",
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
// takes its own fallbacks. On Kepler (GTX 600/700, family 1 too) ANGLE also refuses the GPU by vendor
// (disableMetalOnNvidia: "the Metal display didn't initialize", no WebGL in Firefox or Safari), so that feature goes on
// the same list. MTLSHIM_ANGLE_MAC2=0 turns this part off.
// ANGLE also turns its MTLSharedEvent syncs (feature hasEvents) off on NVIDIA ("Fence sync is flaky on Nvidia",
// crbug.com/1136673), which takes GL_ARB_sync, GL_OES_EGL_sync, GL_NV_fence and EGL_KHR_fence_sync away. Safari 18's WebKit
// requires GL_ARB_sync for every WebGL context (GraphicsContextGLCocoa::platformInitializeExtensions), so on Kepler every
// WebGL and WebGL 2 context was created lost: getContext returned a context whose isContextLost() was already true
// (CONTEXT_LOST_WEBGL), with nothing logged. On this stack Kepler's shared events and ANGLE's fences on them work (s69:
// hundreds of glFenceSync/glClientWaitSync, flush-and-poll and EGL fences, none timed out), so when WebKit (WebCore,
// WebKit or its libANGLE-shared.dylib) is the caller, hasEvents goes on ANGLE_FEATURE_OVERRIDES_ENABLED (a no-op on Intel,
// where it's on already). Chromium and Firefox keep ANGLE's choice. MTLSHIM_ANGLE_EVENTS=0 turns this part off.
typedef void (*EndEncodingIMP)(id, SEL);

// 15. MSAA resolves on the 12.x Intel driver (Haswell / Ivy Bridge): IGRenderPass::generateResolveOptions always resolves
// into level 0, slice 0 of the resolve texture. It ignores resolveLevel/resolveSlice and a view's offset into its parent
// (nothing reaches the intended level or slice) and crashes in generateResourceOptions when resolveLevel isn't 0 (wgpu
// render_target::resolve_to_2d_view; browsers/resolveview). For a color attachment that resolves anywhere else, the
// pass resolves into a temporary 2D texture instead, which a blit copies to the real level/slice when the encoder ends.
// Store actions left unknown at encoder creation and parallel render encoders are not changed.
static const void *kPendingResolveCopies = &kPendingResolveCopies;
static const void *kPendingDepthTouch = &kPendingDepthTouch;  // item 50
static BOOL ivbDepthTouch;

// 51. Stencil written by a fragment function that writes [[sample_mask]] on the Ivy Bridge driver: when the render pass
// has no depth attachment, none of its stencil writes land (a Depth32Float_Stencil8 or Stencil8 stencil attachment, at
// 1x and 4x alike); with the same Depth32Float_Stencil8 texture attached as depth too, they do. ANGLE's fragment
// functions write the sample mask whenever they render multisampled, and a multisampled GL_STENCIL_INDEX8 renderbuffer
// is a stencil-only attachment (item 36 makes it Depth32Float_Stencil8), so every draw's stencil was lost: dEQP
// fbomultisample stencil_index8 in Chrome, Safari and Firefox resolved stencil 0 everywhere. A pass with a combined
// depth/stencil texture as its stencil attachment and no depth attachment gets the same texture as its depth attachment
// (loaded and stored, so the depth plane keeps its contents), and its depth/stencil states are swapped for copies that
// write no depth and compare Always, except a Never compare, which stays: that's what a pass without a depth attachment
// does on Apple's GPUs (measured on an M3 Pro: Never rejects every fragment, the other compares pass them, and the depth
// plane is left alone). A Stencil8 texture can't be attached
// as depth, so a single-sample Stencil8 stencil-only pass drawn with a sample mask still loses its stencil (ANGLE only
// writes the mask when multisampled). MTLSHIM_STENCIL_WITH_DEPTH=0 turns it off. (s67)
static const void *kDepthAddedForStencil = &kDepthAddedForStencil;
static const void *kDepthStencilDescriptor = &kDepthStencilDescriptor;
static const void *kWithoutDepthTest = &kWithoutDepthTest;
static BOOL ivbStencilWithDepth;
typedef id (*NewDepthStencilStateIMP)(id, SEL, MTLDepthStencilDescriptor *) RETURNS_RETAINED;
typedef void (*SetDepthStencilStateIMP)(id, SEL, id);
static NewDepthStencilStateIMP origIGNewDepthStencilState;
static SetDepthStencilStateIMP origIGSetDepthStencilState;
static id igNewDepthStencilState(id self, SEL _cmd, MTLDepthStencilDescriptor *descriptor) RETURNS_RETAINED;
static id igNewDepthStencilState(id self, SEL _cmd, MTLDepthStencilDescriptor *descriptor) {
    id state = origIGNewDepthStencilState(self, _cmd, descriptor);
    if (state && descriptor) objc_setAssociatedObject(state, kDepthStencilDescriptor, [descriptor copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}
static void igSetDepthStencilState(id self, SEL _cmd, id state) {
    if (state && objc_getAssociatedObject(self, kDepthAddedForStencil)) {
        id variant = objc_getAssociatedObject(state, kWithoutDepthTest);
        MTLDepthStencilDescriptor *d = variant ? nil : objc_getAssociatedObject(state, kDepthStencilDescriptor);
        BOOL never = d.depthCompareFunction == MTLCompareFunctionNever;
        if (d && ((!never && d.depthCompareFunction != MTLCompareFunctionAlways) || d.depthWriteEnabled)) {
            MTLDepthStencilDescriptor *copy = [d copy];
            if (!never) copy.depthCompareFunction = MTLCompareFunctionAlways;
            copy.depthWriteEnabled = NO;
            variant = [[(id<MTLRenderCommandEncoder>)self device] newDepthStencilStateWithDescriptor:copy];
            if (variant) objc_setAssociatedObject(state, kWithoutDepthTest, variant, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (variant) state = variant;
    }
    origIGSetDepthStencilState(self, _cmd, state);
}
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
// r8unorm/rg8unorm). Such a clear also goes through a temporary texture, of the level's size. So does one of a
// BGRA8Unorm(_sRGB) 2D or cube texture at level 2 or higher (Ivy Bridge and Haswell) when those levels don't start on a 16-texel
// column of the mip layout, i.e. level 1's width rounded up to 4 isn't a multiple of 16 (base widths 8-24, 40-56, 80,
// 100...): nothing landed there, first clear or not, while RGBA8 and the other formats, blits and draws were right.
static BOOL clearsNarrowFormatMip(MTLRenderPassColorAttachmentDescriptor *a, id<MTLTexture> *root, NSUInteger *level, NSUInteger *slice) {
    if (!a.texture || a.loadAction != MTLLoadActionClear || a.texture.sampleCount > 1) return NO;
    *level = a.level;
    *slice = a.slice;
    *root = rootTexture(a.texture, level, slice);
    MTLPixelFormat format = (*root).pixelFormat;
    if (*level > 0 && (format == MTLPixelFormatR8Unorm || format == MTLPixelFormatRG8Unorm)) return YES;
    if (*level < 2 || (format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatBGRA8Unorm_sRGB) || (*root).textureType == MTLTextureType3D) return NO;
    NSUInteger column = (MAX((*root).width >> 1, 1) + 3) & ~(NSUInteger)3;  // where levels 2+ start: level 1's width, aligned
    return column % 16 != 0;
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

// 42. Until the app sets a viewport, Metal's default viewport covers the render target, in every one of the 16 viewport
// slots on Apple GPUs. The 12.x Intel driver sets that up only for slot 0: slots 1-15 cover nothing until setViewport:
// or setViewports:count:, so primitives sent to one with [[viewport_array_index]] are dropped (the 12.5 AMD driver does
// the same: AMDBronzeCompat item 13). The driver's setViewport: fills every slot, so each encoder starts with the
// default viewport set explicitly: renderTargetWidth/Height when given, otherwise the smallest attachment, as on Apple
// GPUs (for attachments of different sizes the driver's own slot 0 took the first color attachment's).
// MTLSHIM_DEFAULT_VIEWPORTS=0 turns this off. Test: s56.
static void setDefaultViewport(id<MTLRenderCommandEncoder> encoder, MTLRenderPassDescriptor *descriptor) {
    static int enabled = -1;
    if (enabled < 0) enabled = !(getenv("MTLSHIM_DEFAULT_VIEWPORTS") && !strcmp(getenv("MTLSHIM_DEFAULT_VIEWPORTS"), "0"));
    if (!enabled) return;
    NSUInteger width = descriptor.renderTargetWidth, height = descriptor.renderTargetHeight;
    if (!width || !height) {
        width = height = NSUIntegerMax;
        MTLRenderPassAttachmentDescriptor *attachments[10] = {descriptor.depthAttachment, descriptor.stencilAttachment};
        for (NSUInteger i = 0; i < 8; i++) attachments[2 + i] = descriptor.colorAttachments[i];
        for (NSUInteger i = 0; i < 10; i++) {
            id<MTLTexture> texture = attachments[i].texture;
            if (!texture) continue;
            width = MIN(width, MAX(texture.width >> attachments[i].level, 1));
            height = MIN(height, MAX(texture.height >> attachments[i].level, 1));
        }
        if (width == NSUIntegerMax) return;
    }
    [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
}

// 64. Depth clears on Ivy Bridge. A render-pass clear of a level above 0 or a slice above 0 of a mipmapped, cube or
// cube-array depth texture (Depth16Unorm, Depth32Float, Depth32Float_Stencil8) doesn't land once that subresource has
// been written, unless slice 0 is cleared in the same command buffer: it keeps what it held (a point-light shadow cube
// whose faces 1-5 were updated without face 0 kept their old depth wherever nothing was drawn; a mip level 1 likewise;
// single-level 2D arrays and plain 2D textures are right). And where a clear
// does land on Depth32Float, it keeps about 16 bits of mantissa (0.05 became 0.0499999523; 0, 1, 0.5 and 0.25 are exact),
// on every slice of Depth32Float_Stencil8 too. Haswell's driver keeps the same 16 bits on single-level 2D and multisampled
// 2D Depth32Float and Depth32Float_Stencil8 textures (the Iris Pro; its re-clears all land), and the R9 gets both right.
// These textures keep HiZ on Ivy Bridge (item 22), and draws there are right, so after such a clear the pass starts with
// a full-screen draw that writes the clear depth exactly (compare always; color and stencil untouched), and the encoder's
// depth state and viewport are put back as they were. MTLSHIM_DEPTH_CLEAR_DRAW=0 turns it off. Test: s71.
static BOOL ivbDepthClearDraw, hswDepthClearDraw;
static BOOL depthClearNeedsDraw(MTLRenderPassDescriptor *pass) {
    MTLRenderPassDepthAttachmentDescriptor *dp = pass.depthAttachment;
    if ((!ivbDepthClearDraw && !hswDepthClearDraw) || !dp.texture || dp.loadAction != MTLLoadActionClear || pass.renderTargetArrayLength > 1)
        return NO;
    NSUInteger level = dp.level, slice = dp.slice;
    id<MTLTexture> root = rootTexture(dp.texture, &level, &slice);
    MTLPixelFormat format = root.pixelFormat;
    if (format != MTLPixelFormatDepth16Unorm && format != MTLPixelFormatDepth32Float && format != MTLPixelFormatDepth32Float_Stencil8) return NO;
    BOOL cube = root.textureType == MTLTextureTypeCube || root.textureType == MTLTextureTypeCubeArray;
    if (ivbDepthClearDraw && (level || slice) && (root.mipmapLevelCount > 1 || cube)) return YES;  // the clear would be lost
    float value = (float)dp.clearDepth;
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    if (format == MTLPixelFormatDepth16Unorm || !(bits & 0xFF)) return NO;  // no more mantissa than the clear keeps
    return ivbDepthClearDraw || (root.mipmapLevelCount == 1 &&
                                 (root.textureType == MTLTextureType2D || root.textureType == MTLTextureType2DMultisample));
}
static id<MTLRenderPipelineState> depthClearPipeline(id<MTLDevice> device, MTLRenderPassDescriptor *pass) {
    static NSMutableDictionary *pipelines;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    MTLPixelFormat depth = pass.depthAttachment.texture.pixelFormat, stencil = pass.stencilAttachment.texture.pixelFormat;
    NSUInteger samples = pass.depthAttachment.texture.sampleCount;
    NSMutableString *key = [NSMutableString stringWithFormat:@"%p-%lu-%lu-%lu", device, (unsigned long)depth, (unsigned long)stencil, (unsigned long)samples];
    for (NSUInteger i = 0; i < 8; i++) [key appendFormat:@"-%lu", (unsigned long)pass.colorAttachments[i].texture.pixelFormat];
    os_unfair_lock_lock(&lock);
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    id<MTLRenderPipelineState> pipeline = pipelines[key];
    os_unfair_lock_unlock(&lock);
    if (pipeline) return pipeline;
    static id<MTLLibrary> library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 fullScreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2 - 1, 0, 1); }\n"
            "struct Depth { float value [[depth(any)]]; };\n"
            "fragment Depth clearDepth(constant float &value [[buffer(0)]]) { return { value }; }\n";
        library = [device newLibraryWithSource:source options:nil error:nil];
    });
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"fullScreen"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"clearDepth"];
    descriptor.depthAttachmentPixelFormat = depth;
    descriptor.stencilAttachmentPixelFormat = stencil;
    descriptor.rasterSampleCount = samples;
    for (NSUInteger i = 0; i < 8; i++) {
        descriptor.colorAttachments[i].pixelFormat = pass.colorAttachments[i].texture.pixelFormat;
        descriptor.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
    }
    NSError *error = nil;
    pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth clear pipeline: %s\n", error.localizedDescription.UTF8String);
    os_unfair_lock_lock(&lock);
    if (pipeline) pipelines[key] = pipeline;
    os_unfair_lock_unlock(&lock);
    return pipeline;
}
static void drawDepthClear(id<MTLRenderCommandEncoder> encoder, MTLRenderPassDescriptor *pass, MTLRenderPassDescriptor *original) {
    id<MTLTexture> depth = pass.depthAttachment.texture;
    id<MTLRenderPipelineState> pipeline = depthClearPipeline(depth.device, pass);
    if (!pipeline) return;
    static id<MTLDepthStencilState> write, none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
        d.depthCompareFunction = MTLCompareFunctionAlways;
        none = [depth.device newDepthStencilStateWithDescriptor:d];  // Metal's state before an app sets one
        d.depthWriteEnabled = YES;
        write = [depth.device newDepthStencilStateWithDescriptor:d];
    });
    NSUInteger level = pass.depthAttachment.level;
    float value = (float)pass.depthAttachment.clearDepth;
    [encoder setViewport:(MTLViewport){0, 0, (double)MAX(depth.width >> level, 1), (double)MAX(depth.height >> level, 1), 0, 1}];
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:write];
    [encoder setFragmentBytes:&value length:sizeof value atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder setDepthStencilState:none];
    setDefaultViewport(encoder, original);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth clear to %.9g written by a draw\n", value);
}

// 68. Render passes at levels 1+ of mipmapped depth arrays on Ivy Bridge. After any render pass with a depth attachment at
// level 1 or higher of a Depth16Unorm or Depth32Float 2D-array, cube or cube-array texture with several levels (even one
// that only loads and stores), fragment functions sampling level 0 read parts of some other slices wrong (a 57x13x7 array
// with 6 levels: slice 3 after a pass at level 2 or 3, slices 4 and 5 after one at level 1, whichever slice the pass was
// on; a cube: face 1). The texels themselves are right: compute read() sees them, and so does sampling once a pass at
// level 0 has run. Plain 2D textures with mips are right. Item 63's own render passes into such levels (in place of the
// blits) hit it: WebKit's ANGLE fills depth arrays and cubes level by level, which failed dEQP texstorage2d/3d
// format_depth_stencil (cube, 2d_array) and textureformat sized_depth_stencil in Safari. Such textures keep HiZ on
// Ivy Bridge (item 22). When such a pass ends, an empty pass at level 0 slice 0 (load and store) follows it.
// MTLSHIM_DEPTH_LEVEL_REPAIR=0 turns it off. Test: s72 on the HD 4000.
static BOOL ivbDepthLevelRepair;
static const void *kPendingDepthLevelRepair = &kPendingDepthLevelRepair;
static id<MTLTexture> depthLevelPassTexture(MTLRenderPassDescriptor *pass) {
    MTLRenderPassDepthAttachmentDescriptor *dp = pass.depthAttachment;
    if (!ivbDepthLevelRepair || !dp.texture) return nil;
    NSUInteger level = dp.level, slice = dp.slice;
    id<MTLTexture> root = rootTexture(dp.texture, &level, &slice);
    if (!level || root.mipmapLevelCount < 2 || root.sampleCount > 1) return nil;
    MTLTextureType type = root.textureType;
    if (type != MTLTextureType2DArray && type != MTLTextureTypeCube && type != MTLTextureTypeCubeArray) return nil;
    return root.pixelFormat == MTLPixelFormatDepth16Unorm || root.pixelFormat == MTLPixelFormatDepth32Float ? root : nil;
}
static void repairDepthLevels(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> t) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = t;  // level 0, slice 0
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    [[commandBuffer renderCommandEncoderWithDescriptor:pass] endEncoding];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth pass at a level above 0: empty pass at level 0 after it\n");
}

static id igRenderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    descriptor = withDummyTarget(self, passWithFourSamples(self, descriptor));  // items 77 and 73
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
    // Item 51: a combined depth/stencil texture attached as stencil only is attached as depth too.
    BOOL depthAdded = NO;
    {
        MTLRenderPassDescriptor *current = redirected ?: descriptor;
        MTLRenderPassStencilAttachmentDescriptor *st = current.stencilAttachment;
        MTLPixelFormat format = st.texture.pixelFormat;
        if (ivbStencilWithDepth && st.texture && !current.depthAttachment.texture &&
            (format == MTLPixelFormatDepth32Float_Stencil8 || format == MTLPixelFormatDepth24Unorm_Stencil8)) {
            if (!redirected) redirected = [descriptor copy];
            MTLRenderPassDepthAttachmentDescriptor *dp = redirected.depthAttachment;
            dp.texture = st.texture;
            dp.level = st.level;
            dp.slice = st.slice;
            dp.depthPlane = st.depthPlane;
            dp.loadAction = MTLLoadActionLoad;
            dp.storeAction = MTLStoreActionStore;
            depthAdded = YES;
            if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil-only pass: depth attached as well\n");
        }
    }
    id encoder = origIGRenderEncoder(self, _cmd, redirected ?: descriptor);
    if (encoder && depthAdded) objc_setAssociatedObject(encoder, kDepthAddedForStencil, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoder) setDefaultViewport(encoder, descriptor);
    if (encoder && depthClearNeedsDraw(descriptor)) drawDepthClear(encoder, redirected ?: descriptor, descriptor);  // item 64
    id<MTLTexture> levelPass = encoder ? depthLevelPassTexture(redirected ?: descriptor) : nil;  // item 68
    if (levelPass) objc_setAssociatedObject(encoder, kPendingDepthLevelRepair, @[self, levelPass], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLTexture> depth = descriptor.depthAttachment.texture;  // item 50
    if (encoder && ivbDepthTouch && depth && depth.textureType == MTLTextureType2DMultisample && (depth.usage & MTLTextureUsageShaderRead) &&
        descriptor.depthAttachment.loadAction == MTLLoadActionClear)
        objc_setAssociatedObject(encoder, kPendingDepthTouch, @[self, depth], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoder && copies.count) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %lu attachment(s) copied out of temporary textures at the end\n", (unsigned long)copies.count);
        objc_setAssociatedObject(encoder, kPendingResolveCopies, @[self, copies], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

// 50. Multisampled depth cleared by a render pass on the Ivy Bridge driver: the clear is a fast clear, and before a later
// render pass samples the texture the driver resolves only its first width/2 x height/2 texels (single-sample extents
// on the 4x surface); the rest reads 0. Ahead of a compute dispatch it resolves all of it. ANGLE resolves a multisampled
// depth renderbuffer for glBlitFramebuffer by sampling it in a fragment shader, so cleared depth copied out of one came
// out as 0 (WebGL CTS multisampled-depth-renderbuffer-initialization; three.js resolves the depth of multisampled render
// targets that way). After a pass that clears a sampleable multisampled depth attachment, a one-thread compute dispatch
// reads the texture. MTLSHIM_MSAA_DEPTH_RESOLVE=0 turns it off. (s66)
static void touchMultisampledDepth(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture) {
    static id<MTLComputePipelineState> pipeline;
    static id<MTLBuffer> scratch;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!pipeline || pipeline.device != texture.device) {
        id<MTLLibrary> library = [texture.device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void touch(texture2d_ms<float> t [[texture(0)]], device float *o [[buffer(0)]]) { o[0] = t.read(uint2(0, 0), 0).r; }\n"
                                                              options:nil error:nil];
        id<MTLFunction> function = [library newFunctionWithName:@"touch"];
        pipeline = function ? [texture.device newComputePipelineStateWithFunction:function error:nil] : nil;
        scratch = [texture.device newBufferWithLength:16 options:MTLResourceStorageModePrivate];
    }
    id<MTLComputePipelineState> p = pipeline;
    id<MTLBuffer> b = scratch;
    os_unfair_lock_unlock(&lock);
    if (!p || !b) return;
    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    [compute setComputePipelineState:p];
    [compute setTexture:texture atIndex:0];
    [compute setBuffer:b offset:0 atIndex:0];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [compute endEncoding];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] cleared multisampled depth resolved by a compute read\n");
}

// Copies each {temporary, destination, level, slice, depth plane} of an encoder's pending list to its destination (items 15, 55).
static void copyOutOfTemporaries(NSArray *pending) {
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

static void igRenderEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingResolveCopies);
    NSArray *touch = objc_getAssociatedObject(self, kPendingDepthTouch);
    NSArray *repair = objc_getAssociatedObject(self, kPendingDepthLevelRepair);
    origIGRenderEndEncoding(self, _cmd);
    if (touch) {  // item 50
        objc_setAssociatedObject(self, kPendingDepthTouch, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        touchMultisampledDepth(touch[0], touch[1]);
    }
    if (repair) {  // item 68
        objc_setAssociatedObject(self, kPendingDepthLevelRepair, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        repairDepthLevels(repair[0], repair[1]);
    }
    if (!pending) return;
    objc_setAssociatedObject(self, kPendingResolveCopies, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    copyOutOfTemporaries(pending);
}

// 55. MSAA resolves into mip level 1 or higher on the Kepler driver (GeForceMTLDriver): after a pass that draws, nothing
// reaches the level (any slice, RGBA8 and sRGB alike; the target keeps what it held); level 0, every slice, and a pass
// that only clears are right (GTX 770; s25's level 1 resolve read 255 from an uninitialized texture). As item 15 does on
// Intel, such a color attachment resolves into a temporary 2D texture of the level's size, which a blit copies to the
// level and slice when the encoder ends. Store actions unknown at encoder creation and parallel render encoders are
// not changed. MTLSHIM_NV_RESOLVE_LEVEL=0 turns it off. Test: s25 on the GTX 770.
static RenderEncoderIMP origNVRenderEncoder;
static EndEncodingIMP origNVRenderEndEncoding;
static BOOL nvResolveLevels;  // item 55 on
static id nvRenderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    descriptor = withDummyTarget(self, passWithFourSamples(self, descriptor));  // items 77 and 73
    MTLRenderPassDescriptor *redirected = nil;
    NSMutableArray *copies = nil;  // {temporary, destination, level, slice, depth plane}
    for (NSUInteger i = 0; descriptor && nvResolveLevels && i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = descriptor.colorAttachments[i];
        id<MTLTexture> resolve = a.resolveTexture;
        if (!resolve || (a.storeAction != MTLStoreActionMultisampleResolve && a.storeAction != MTLStoreActionStoreAndMultisampleResolve))
            continue;
        NSUInteger level = a.resolveLevel, slice = a.resolveSlice;
        id<MTLTexture> target = rootTexture(resolve, &level, &slice);
        if (!level) continue;
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
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] resolve into level %lu slice %lu through a temporary texture\n", (unsigned long)level, (unsigned long)slice);
    }
    id encoder = origNVRenderEncoder(self, _cmd, redirected ?: descriptor);
    if (encoder && copies.count) objc_setAssociatedObject(encoder, kPendingResolveCopies, @[self, copies], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return encoder;
}
static void nvRenderEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingResolveCopies);
    NVO(origNVRenderEndEncoding)(self, _cmd);
    if (!pending) return;
    objc_setAssociatedObject(self, kPendingResolveCopies, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    copyOutOfTemporaries(pending);
}
static void keplerResolveLevels(void) {
    static const char *const kBuffer = "NVMTLCommandBuffer", *const kEncoder = "NVMTLRenderCommandEncoder_KEPLER_A";
    const char *setting = getenv("MTLSHIM_NV_RESOLVE_LEVEL");
    if (origNVRenderEncoder || !definesMethod(kBuffer, "renderCommandEncoderWithDescriptor:") || !definesMethod(kEncoder, "endEncoding"))
        return;
    nvResolveLevels = !(setting && !strcmp(setting, "0"));  // the hook stays for item 73
    origNVRenderEndEncoding = (EndEncodingIMP)keplerSwizzle(kEncoder, "endEncoding", (IMP)nvRenderEndEncoding);
    origNVRenderEncoder = (RenderEncoderIMP)swizzle(kBuffer, "renderCommandEncoderWithDescriptor:", (IMP)nvRenderEncoder);
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

// 40. Compute kernels get their samplers' hardware state from CHAL_INTEL::ChalContext::PatchSamplerObject, which copies
// the filters, address modes and LOD clamps of the app's MTLIGSampler into the kernel's sampler-state template but keeps
// the template's low byte of DW1, where the shadow (compare) function is: an argument sampler's compare function never
// reaches the hardware, so every sample_compare and gather_compare in a compute kernel compared with "never" and returned
// 0 (WebGPU CTS textureGatherCompare in compute: 300 cases, textureSampleCompareLevel too). Constexpr samplers don't go
// through it and were right; vertex and fragment functions are too. The function is wrapped (an inline hook on its
// standard 12-byte prologue, the first 42 bytes checked against this driver's) to copy DW1 bits 3:1 from the sampler
// object afterwards. The Ivy Bridge driver's build of the function (its own 40 bytes checked, a 17-byte prologue, the
// packet's heap at 0x1f0) has the same template and the same bug. MTLSHIM_COMPUTE_SAMPLER_COMPARE=0 turns it off. Test: s50.
// The same template has LOD PreClamp Enable (DW0 bit 28) clear, so the hardware chose between the min and mag filters
// on the unclamped LOD: a level at or below 0 magnified (base level only) even with a lodMinClamp of 0.25, which should
// have blended a quarter of level 1 in (WebGPU CTS textureSampleLevel lodClamp in compute, linear filter: 90 cases).
// The bit is copied from the sampler object too. MTLSHIM_COMPUTE_LOD_PRECLAMP=0 leaves it. Test: s51.
typedef void (*PatchSamplerObjectFn)(void *, const void *, const void *, void *, const void *);
static PatchSamplerObjectFn origPatchSamplerObject;
static ptrdiff_t igSamplerStateIvarOffset;
static bool computeLodPreClamp;
static ptrdiff_t chalPacketHeapOffset = 0x1d8;  // tagCHALCommandPacket's state heap: 0x1f0 in the Ivy Bridge driver

static void computePatchSamplerObject(void *context, const void *patchInfo, const void *samplerArgument, void *packet,
                                      const void *textures) {
    origPatchSamplerObject(context, patchInfo, samplerArgument, packet, textures);
    char *sampler = samplerArgument ? *(char *const *)samplerArgument : NULL;
    char *heap = packet ? *(char **)((char *)packet + chalPacketHeapOffset) : NULL;
    if (!sampler || !heap) return;
    uint32_t *hardware = (uint32_t *)(heap + *(const uint32_t *)((const char *)patchInfo + 0xc));
    const uint32_t *state = (const uint32_t *)(sampler + igSamplerStateIvarOffset);
    hardware[1] = (hardware[1] & ~0xeu) | (state[1] & 0xeu);  // ShadowFunction
    if (computeLodPreClamp) hardware[0] = (hardware[0] & ~(1u << 28)) | (state[0] & (1u << 28));  // LODPreClampEnable
}

// entry -> replacement, for a function whose first `length` (>= 12) bytes are whole position-independent instructions
// (checked by the caller): returns a trampoline running those bytes and continuing after them
static void *hookPrologue(unsigned char *entry, size_t length, void *replacement) {
    unsigned char *stub = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (stub == MAP_FAILED || length < 12 || length > 64) return NULL;
    unsigned char *p = stub;
    memcpy(p, entry, length), p += length;
    *p++ = 0x48, *p++ = 0xb8;  // mov rax, entry + length
    uint64_t back = (uint64_t)(entry + length);
    memcpy(p, &back, 8), p += 8;
    *p++ = 0xff, *p++ = 0xe0;  // jmp rax
    if (mprotect(stub, 4096, PROT_READ | PROT_EXEC)) return NULL;
    vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size * 2, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return NULL;
    unsigned char patch[12] = {0x48, 0xb8};
    uint64_t target = (uint64_t)replacement;
    memcpy(patch + 2, &target, 8);
    patch[10] = 0xff, patch[11] = 0xe0;
    memcpy(entry, patch, sizeof patch);
    vm_protect(mach_task_self(), page, vm_page_size * 2, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return stub;
}

// hookPrologue for a function starting push rbp; mov rbp, rsp; push r15; push r14; push r13; push r12 (12 bytes)
static void *hookStandardPrologue(unsigned char *entry, void *replacement) { return hookPrologue(entry, 12, replacement); }

static void computeSamplerCompare(void) {
    static const unsigned char kExpected[42] = {
        0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x53, 0xff, 0x87, 0x6c, 0x06, 0x00, 0x00, 0x4c, 0x8b,
        0x1a, 0x4d, 0x85, 0xdb, 0x0f, 0x84, 0x13, 0x04, 0x00, 0x00, 0x4c, 0x8b, 0x89, 0xd8, 0x01, 0x00, 0x00, 0x44, 0x8b, 0x56, 0x0c};
    const char *setting = getenv("MTLSHIM_COMPUTE_SAMPLER_COMPARE");
    if (origPatchSamplerObject || (setting && !strcmp(setting, "0"))) return;
    Class c = objc_getClass("MTLIGSampler");
    Ivar state = c ? class_getInstanceVariable(c, "samplerState") : NULL;
    if (!state || !strstr(ivar_getTypeEncoding(state), "\"SamplerDisable\"b1\"CubeSurfaceControlMode\"b1\"ShadowFunction\"b3")) return;
    unsigned char *entry = dlsym(RTLD_DEFAULT, "_ZN10CHAL_INTEL11ChalContext18PatchSamplerObjectEPKNS_20tagArgumentPatchInfoERK16"
                                               "sSamplerArgumentPNS_20tagCHALCommandPacketEPK16sTextureArgument");
    // the Ivy Bridge driver's: push rbp; mov rbp, rsp; push r15; push r14; push r12; push rbx; inc [rdi+0x664] (17 bytes)
    static const unsigned char kExpectedIVB[40] = {
        0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x54, 0x53, 0xff, 0x87, 0x64, 0x06, 0x00, 0x00, 0x4c, 0x8b, 0x12,
        0x4d, 0x85, 0xd2, 0x0f, 0x84, 0xf9, 0x03, 0x00, 0x00, 0x4c, 0x8b, 0x89, 0xf0, 0x01, 0x00, 0x00, 0x44, 0x8b, 0x5e, 0x0c};
    BOOL ivb = entry && !memcmp(entry, kExpectedIVB, sizeof kExpectedIVB);
    if (!entry || (!ivb && memcmp(entry, kExpected, sizeof kExpected))) return;
    if (ivb) chalPacketHeapOffset = 0x1f0;
    igSamplerStateIvarOffset = ivar_getOffset(state);
    const char *preclamp = getenv("MTLSHIM_COMPUTE_LOD_PRECLAMP");
    computeLodPreClamp = !(preclamp && !strcmp(preclamp, "0")) && strstr(ivar_getTypeEncoding(state), "\"LODPreClampEnable\"b1\"TextureBorderColorMode\"b1\"\"b1\"SamplerDisable\"b1");
    origPatchSamplerObject = (PatchSamplerObjectFn)(ivb ? hookPrologue(entry, 17, (void *)computePatchSamplerObject)
                                                        : hookStandardPrologue(entry, (void *)computePatchSamplerObject));
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] compute sampler compare functions: %s%s\n", origPatchSamplerObject ? "hooked" : "hook failed",
                computeLodPreClamp ? ", LOD pre-clamp" : "");
}

// 39. A texture view that starts at mip level L carries two surface states: the sampler's (min LOD L) and, for writes,
// a render-target one, where the LOD field is L and the min LOD 0. Typed writes use the LOD field; the sampler's
// resinfo (get_width / get_height) uses the min LOD. In fragment functions the driver binds the render-target state
// for writable 2D-array views, so their size queries returned level 0's size (WebGPU CTS textureDimensions storage:
// write, 2d-array, base level 1-2, every format: 40 cases; compute functions and 2D views got the sampler's). The
// render-target state's min LOD is set to its LOD, which only the sampler reads. MTLSHIM_TARGET_MIN_LOD=0 turns it off.
// Test: s45. The same goes for the layer count of a 2D-array view whose first layer isn't 0: the render-target state
// keeps the whole texture's Depth (array size - 1; the sampler's has the view's, with Minimum Array Element as the offset),
// so get_array_size() on such a writable view in a fragment function returned the texture's layer count (WebGPU CTS
// textureNumLayers storage, write, partial views: 40 cases). The sampler's Depth is copied in; typed writes still land at
// Minimum Array Element + index (they don't bound-check against Depth). MTLSHIM_TARGET_DEPTH=0 turns that off. Test: s49.
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
static void targetDepth(id self) {
    static int enabled = -1;
    if (enabled < 0) { const char *setting = getenv("MTLSHIM_TARGET_DEPTH"); enabled = !(setting && !strcmp(setting, "0")); }
    if (!enabled) return;
    uint32_t *sampler = (uint32_t *)((uint8_t *)(__bridge void *)self + igSurfaceStateOffset), *target = sampler + 8;
    uint32_t samplerDepth = sampler[3] >> 21, targetDepth = target[3] >> 21, minimumElement = (sampler[4] >> 18) & 0x7ff;
    if (!minimumElement || targetDepth <= samplerDepth || (sampler[0] >> 29) != 1 /* SURFTYPE_2D */) return;
    target[3] = (target[3] & 0x1fffff) | (samplerDepth << 21);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] render-target surface state of a view from layer %u: depth %u\n", minimumElement, samplerDepth);
}

static void igInitSurfaceState(id self, SEL _cmd) {
    origIGInitSurfaceState(self, _cmd);
    targetMinLod(self);  // item 39
    targetDepth(self);
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
    // The Ivy Bridge driver's SGfxSurfaceState_Gen7: the same fields up to here and in dwords 0-5 (the fixes here use
    // bits of dwords 0, 2, 4 and 5), 32 bytes, so hwSurfaceStateTarget follows at the same offset.
    static const char kLayoutIVB[] = "{MTLIGAccelTextureInfo=\"hwSurfaceState\"{SGfxSurfaceState_Gen7=\"CubeFaceEnablesPositiveZ\"b1"
        "\"CubeFaceEnablesNegativeZ\"b1\"CubeFaceEnablesPositiveY\"b1\"CubeFaceEnablesNegativeY\"b1\"CubeFaceEnablesPositiveX\"b1"
        "\"CubeFaceEnablesNegativeX\"b1\"MediaBoundaryPixelMode\"b2\"RenderCacheReadWriteMode\"b1\"\"b1\"SurfaceArraySpacing\"b1"
        "\"VerticalLineStrideOffset\"b1\"VerticalLineStride\"b1\"TileWalk\"b1\"TiledSurface\"b1\"SurfaceHorizontalAlignment\"b1";
    const char *setting = getenv("MTLSHIM_STENCIL_VIEW_ALIGN");
    Class texture = objc_getClass("MTLIGAccelTexture");
    Ivar info = texture ? class_getInstanceVariable(texture, "m_Info") : NULL;
    const char *encoding = info ? ivar_getTypeEncoding(info) : "";
    BOOL haswell = !strncmp(encoding, kLayout, sizeof kLayout - 1) && strstr(encoding, "}\"hwSurfaceStateTarget\"{SGfxSurfaceState=");
    BOOL ivyBridge = !strncmp(encoding, kLayoutIVB, sizeof kLayoutIVB - 1) && strstr(encoding, "}\"hwSurfaceStateTarget\"{SGfxSurfaceState_Gen7=");
    if (origIGInitSurfaceState || (setting && !strcmp(setting, "0")) || !info || !(haswell || ivyBridge) ||
        !definesMethod("MTLIGAccelTexture", "initializeHWSurfaceState"))
        return;
    igSurfaceStateOffset = ivar_getOffset(info);
    origIGInitSurfaceState = (InitSurfaceStateIMP)swizzle("MTLIGAccelTexture", "initializeHWSurfaceState", (IMP)igInitSurfaceState);
}

typedef void (^BlitCommand)(id<MTLBlitCommandEncoder>);
static BOOL deferBlit(id encoder, BlitCommand command);  // item 63: YES if `command` waits for the encoder's end

// 20. Buffer fills on the 12.x Intel driver: -[MTLIGAccelBlitCommandEncoder fillBuffer:range:value:] fills the wrong
// bytes when the length is exactly 8 and the offset is 4 mod 8: it fills the 8-aligned bytes below (offset 4 -> 0..7).
// Other lengths and offsets are right. wgpu (Firefox's WebGPU) zero-fills buffer tails this way: a 4-byte copy into
// a 12-byte buffer was wiped by the clear of bytes 4..11 (WebGPU CTS clearBuffer, copyBufferToBuffer). Such a fill is
// issued as two 4-byte fills.
typedef void (*FillBufferIMP)(id, SEL, id, NSRange, uint8_t);
static FillBufferIMP origIGFillBuffer;

static void igFillBuffer(id self, SEL _cmd, id buffer, NSRange range, uint8_t value) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { [e fillBuffer:buffer range:range value:value]; })) return;  // item 63
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
// Item 77 for heaps: a 2x texture is sized as the 4x texture it becomes.
typedef MTLSizeAndAlign (*HeapTextureSizeIMP)(id, SEL, MTLTextureDescriptor *);
static HeapTextureSizeIMP origIGHeapTextureSize;
static MTLSizeAndAlign igHeapTextureSize(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    if (descriptor.sampleCount != 2 || !promotesTwoSamples(self)) return origIGHeapTextureSize(self, _cmd, descriptor);
    MTLTextureDescriptor *copy = [descriptor copy];
    copy.sampleCount = 4;
    return origIGHeapTextureSize(self, _cmd, copy);
}
static void intelDepthWithoutHiZ(void) {
    Class device = objc_getClass("MTLIGAccelDevice");
    Ivar hiz = device ? class_getInstanceVariable(device, "bHizDisable") : NULL;
    if (origIGNewTexture || !definesMethod("MTLIGAccelDevice", "newTextureWithDescriptor:")) return;
    if (hiz && !strcmp(ivar_getTypeEncoding(hiz), "B")) igHizDisableOffset = ivar_getOffset(hiz);
    origIGNewTexture = (NewTextureIMP)swizzle("MTLIGAccelDevice", "newTextureWithDescriptor:", (IMP)igNewTexture);
    if (definesMethod("MTLIGAccelDevice", "heapTextureSizeAndAlignWithDescriptor:"))  // item 77
        origIGHeapTextureSize = (HeapTextureSizeIMP)swizzle("MTLIGAccelDevice", "heapTextureSizeAndAlignWithDescriptor:", (IMP)igHeapTextureSize);
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
// depth output, stencil cleared and then set one bit per draw (these GPUs have no stencil output). On the Ivy Bridge
// driver, which keeps HiZ on depth textures with several levels or slices (item 22 can't create them without it there),
// depth blitted into those is rewritten the same way. Tests: s32, s22 on the HD 4000.
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
// 49. Blits through texture views on the Ivy Bridge driver: a blit from or into a view (between textures, or with a
// buffer) ignores the view's offset into its parent and reaches the parent's slice 0 and level 0; shaders reach the right
// subresource through the same view. ANGLE copies a cube's faces through single-face 2D views when generateMipmap gives
// the texture a mip chain, so every face became +X's (WebGL CTS texture-size-cube-maps, texture-sub-image-cube-maps,
// texture-mips). Such blits address the view's parent (of the same pixel format) at the view's slice and level instead.
// MTLSHIM_VIEW_BLITS=0 turns it off. (s65)
static BOOL ivbViewBlits;
static id<MTLTexture> viewBlitTarget(id<MTLTexture> t, NSUInteger *slice, NSUInteger *level) {
    return ivbViewBlits && t.parentTexture ? rootTexture(t, level, slice) : t;
}

// 37. Stencil copied between a buffer and mip level 1 or higher on the 12.x Intel driver, when the buffer offset or
// bytesPerRow isn't a multiple of 256: some texels come from their left neighbour (at mip 2 of a 20x16 texture, the 5th
// texel of each row reads or writes as the 4th), for Stencil8 and the stencil of depth/stencil formats alike. Dawn
// copies a tight buffer's last row on its own with bytesPerRow = its width, so WebGPU CTS
// image_copy rowsPerImage_and_bytesPerRow_depth_stencil lost the last texel (9 cases). Slice 1+ of a Stencil8 array goes
// wrong the same way: with such a buffer offset, a copy out of it reads 0 and a copy into it with such a bytesPerRow
// writes nothing (wgpu's copy_unaligned_rows). Copies at level 0 / slice 0, and texture to texture copies at any level
// and slice, are right. Such copies go through a level-0 temporary texture of the same format: out of
// the level by a texture copy, then to the buffer; or into the temporary (filled from the level first, which keeps the
// depth of a depth/stencil texture) and back by a texture copy, which item 27 sees. The Ivy Bridge driver writes only
// the first row of any stencil copy into a buffer whose bytesPerRow isn't the region's width, at every level and slice
// (copies into textures, and depth, are right): WebGPU's bytesPerRow is a multiple of 256, so every stencil read-back
// there lost all but its first row. There such a copy is made one row at a time, each row tight at its own offset.
// MTLSHIM_STENCIL_COPY=0 turns both off. Tests: s41, s55, s62 on the HD 4000.
typedef void (*TextureToBufferIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger);
typedef void (*TextureToBufferOptionsIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger,
                                          MTLBlitOption);
static TextureToBufferIMP origIGTextureToBuffer;
static TextureToBufferOptionsIMP origIGTextureToBufferOptions;

static id<MTLTexture> stencilCopyTemporary(id<MTLTexture> t, NSUInteger slice, NSUInteger level, NSUInteger offset, NSUInteger bytesPerRow,
                                          MTLSize size, MTLBlitOption options) {
    if ((!level && !slice) || !t || t.parentTexture || t.sampleCount > 1 || size.depth != 1 || (!(offset % 256) && !(bytesPerRow % 256))) return nil;
    MTLPixelFormat f = t.pixelFormat;
    BOOL stencil = f == MTLPixelFormatStencil8 || ((options & MTLBlitOptionStencilFromDepthStencil) &&
                                                   (f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8));
    const char *setting = getenv("MTLSHIM_STENCIL_COPY");
    if (!stencil || (setting && !strcmp(setting, "0"))) return nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:size.width height:size.height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> temporary = [t.device newTextureWithDescriptor:d];
    if (temporary && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil copy at level %lu slice %lu through a level-0 temporary\n", (unsigned long)level, (unsigned long)slice);
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
    id<MTLTexture> temporary = stencilCopyTemporary(t, slice, level, offset, row, size, options);
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
static BOOL ivbStencilRows;  // the Ivy Bridge driver: stencil copied into a buffer with bytesPerRow != width keeps its first row only
static BOOL depthLevelCopyOut(id encoder, id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id<MTLBuffer> buffer,
                              NSUInteger offset, NSUInteger bytesPerRow, MTLBlitOption options);  // item 63
static BOOL depthLevelCopyIn(id encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow, MTLSize size, id<MTLTexture> t,
                             NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options);
static BOOL depthLevelCopyBetween(id encoder, id<MTLTexture> from, NSUInteger fromSlice, NSUInteger fromLevel, MTLOrigin fromOrigin, MTLSize size,
                                  id<MTLTexture> to, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options);
// The driver's copy into a buffer; on Ivy Bridge a stencil region with padded rows goes one row at a time.
static void textureToBuffer(id self, SEL _cmd, id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size,
                            id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLBlitOption options, BOOL withOptions) {
    MTLPixelFormat f = t.pixelFormat;
    BOOL stencil = f == MTLPixelFormatStencil8 || ((options & MTLBlitOptionStencilFromDepthStencil) &&
                                                   (f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8));
    NSUInteger rows = ivbStencilRows && stencil && size.depth == 1 && size.height > 1 && row != size.width ? size.height : 1;
    for (NSUInteger y = 0; y < rows; y++) {
        MTLOrigin o = origin;
        MTLSize s = size;
        NSUInteger r = row, i = image;
        if (rows > 1) o.y += y, s.height = 1, r = i = size.width;
        if (withOptions) origIGTextureToBufferOptions(self, _cmd, t, slice, level, o, s, buffer, offset + y * row, r, i, options);
        else origIGTextureToBuffer(self, _cmd, t, slice, level, o, s, buffer, offset + y * row, r, i);
    }
    if (rows > 1 && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil copied out in %lu rows (bytesPerRow %lu)\n", (unsigned long)rows, (unsigned long)row);
}
static void igTextureToBuffer(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                              NSUInteger offset, NSUInteger row, NSUInteger image) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:buffer destinationOffset:offset
                destinationBytesPerRow:row destinationBytesPerImage:image];
        }))
        return;
    t = viewBlitTarget(t, &slice, &level);  // item 49
    id<MTLTexture> temporary = stencilCopyTemporary(t, slice, level, offset, row, size, MTLBlitOptionNone);
    if (!temporary) {
        if (depthLevelCopyOut(self, t, slice, level, origin, size, buffer, offset, row, MTLBlitOptionNone)) return;  // item 63
        return textureToBuffer(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image, MTLBlitOptionNone, NO);
    }
    textureCopy(self, t, slice, level, origin, size, temporary, 0, 0, MTLOriginMake(0, 0, 0));
    textureToBuffer(self, _cmd, temporary, 0, 0, MTLOriginMake(0, 0, 0), size, buffer, offset, row, image, MTLBlitOptionNone, NO);
}
static void igTextureToBufferOptions(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                                     NSUInteger offset, NSUInteger row, NSUInteger image, MTLBlitOption options) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromTexture:t sourceSlice:slice sourceLevel:level sourceOrigin:origin sourceSize:size toBuffer:buffer destinationOffset:offset
                destinationBytesPerRow:row destinationBytesPerImage:image options:options];
        }))
        return;
    t = viewBlitTarget(t, &slice, &level);  // item 49
    id<MTLTexture> temporary = stencilCopyTemporary(t, slice, level, offset, row, size, options);
    if (!temporary) {
        if (depthLevelCopyOut(self, t, slice, level, origin, size, buffer, offset, row, options)) return;  // item 63
        return textureToBuffer(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image, options, YES);
    }
    textureCopy(self, t, slice, level, origin, size, temporary, 0, 0, MTLOriginMake(0, 0, 0));
    textureToBuffer(self, _cmd, temporary, 0, 0, MTLOriginMake(0, 0, 0), size, buffer, offset, row, image, options, YES);
}
// 53. Small stencil uploads on the Kepler driver: a copy from a buffer into Stencil8, or into the stencil of a depth/stencil
// texture (MTLBlitOptionStencilFromDepthStencil), of at most 16 KB isn't ordered before the blit encoder's next command,
// so a copy out of the same texture right after it can run first and read the old contents (zeros in a new texture).
// Measured on a GTX 770 (Sequoia, OCLP's 11.0 Beta 3 GeForceMTLDriver), 30 runs per size, read-back in the same encoder:
// 4x3 to 128x128 fail 10% to 83% of runs, 256x256 and up never; colour and Depth32Float uploads never. Any command in
// between orders it (a new encoder too): after every stencil upload a 4-byte fillBuffer into a scratch buffer of the
// device follows, which made all sizes 30 of 30. MTLSHIM_NV_STENCIL_ORDER=0 turns it off. Test: s62 on the GTX 770.
static BufferToTextureIMP origNVBufferToTexture;
static BufferToTextureOptionsIMP origNVBufferToTextureOptions;
static const void *kNVOrderScratch = &kNVOrderScratch;
static void nvOrderStencilUpload(id encoder, id<MTLTexture> t, MTLBlitOption options) {
    MTLPixelFormat f = t.pixelFormat;
    BOOL stencil = f == MTLPixelFormatStencil8 || ((options & MTLBlitOptionStencilFromDepthStencil) &&
                                                   (f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8 ||
                                                    f == MTLPixelFormatX32_Stencil8 || f == MTLPixelFormatX24_Stencil8));
    if (!stencil) return;
    id<MTLDevice> device = t.device;
    id<MTLBuffer> scratch = objc_getAssociatedObject(device, kNVOrderScratch);
    if (!scratch) {
        scratch = [device newBufferWithLength:4 options:MTLResourceStorageModePrivate];
        if (!scratch) return;
        objc_setAssociatedObject(device, kNVOrderScratch, scratch, OBJC_ASSOCIATION_RETAIN);
    }
    [(id<MTLBlitCommandEncoder>)encoder fillBuffer:scratch range:NSMakeRange(0, 4) value:0];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stencil upload ordered (format %lu)\n", (unsigned long)f);
}
static void nvBufferToTexture(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                              NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    NVO(origNVBufferToTexture)(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin);
    nvOrderStencilUpload(self, t, MTLBlitOptionNone);
}
static void nvBufferToTextureOptions(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                                     NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    NVO(origNVBufferToTextureOptions)(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin, options);
    nvOrderStencilUpload(self, t, options);
}
static void nvStencilUploadOrder(void) {
    static const char *const kEncoder = "NVMTLBlitCommandEncoder_KEPLER_A", *const kBufferToTexture =
        "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";
    char withOptions[256];
    const char *setting = getenv("MTLSHIM_NV_STENCIL_ORDER");
    if (origNVBufferToTexture || (setting && !strcmp(setting, "0")) || !definesMethod(kEncoder, kBufferToTexture)) return;
    origNVBufferToTexture = (BufferToTextureIMP)keplerSwizzle(kEncoder, kBufferToTexture, (IMP)nvBufferToTexture);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kBufferToTexture);
    if (definesMethod(kEncoder, withOptions))
        origNVBufferToTextureOptions = (BufferToTextureOptionsIMP)keplerSwizzle(kEncoder, withOptions, (IMP)nvBufferToTextureOptions);
}
// 65. 3D copies with a padded image stride on the Kepler driver. A copy between a buffer and more than one slice of a 3D
// texture whose bytesPerImage is more than bytesPerRow x height read or wrote slice n at n x bytesPerRow x height, in
// the padding instead of the next image: all formats, both directions (GTX 770; WebGPU CTS image_copy
// rowsPerImage_and_bytesPerRow, all 114 failing cases 3D; Dawn copies 2D arrays a slice at a time, and those were right).
// Such a copy is done a slice at a time. MTLSHIM_NV_VOLUME_COPY=0 turns it off. Test: n15 on the GTX 770.
// 67. Uploads into the last row of blocks of a block-compressed texture on the Kepler driver. A copy from a buffer into a
// BC texture whose region ends at the level's bottom edge with a height that isn't a whole number of blocks (13x1 at
// y = 12 of a 13-texel level: the edge row, 1 texel high) wrote nothing, as if the block rows were rounded down; edge
// columns, whole levels and copies out were right (GTX 770; WebGPU CTS image_copy compressed_textures,
// unaligned_mip_level_0, all BC formats). Such a copy's height is rounded up to the block: the level's memory holds whole
// blocks, and the driver takes the size. MTLSHIM_NV_BLOCK_EDGE=0 turns it off. Test: n17 on the GTX 770.
static BOOL nvVolumeOn, nvBlockEdgeOn;
static BufferToTextureIMP origNVVolumeB2T;
static BufferToTextureOptionsIMP origNVVolumeB2TOptions;
static TextureToBufferIMP origNVVolumeT2B;
static TextureToBufferOptionsIMP origNVVolumeT2BOptions;
static BOOL nvVolumeSplit(id<MTLTexture> t, MTLSize size, NSUInteger row, NSUInteger image) {
    return nvVolumeOn && t.textureType == MTLTextureType3D && size.depth > 1 && image != row * size.height;
}
static MTLSize nvBlockEdge(id<MTLTexture> t, NSUInteger level, MTLOrigin origin, MTLSize size) {  // item 67
    if (!nvBlockEdgeOn || !(size.height & 3)) return size;
    MTLPixelFormat f = t.pixelFormat;
    BOOL bc = (f >= MTLPixelFormatBC1_RGBA && f <= MTLPixelFormatBC3_RGBA_sRGB) || (f >= MTLPixelFormatBC4_RUnorm && f <= MTLPixelFormatBC5_RGSnorm) ||
              (f >= MTLPixelFormatBC6H_RGBFloat && f <= MTLPixelFormatBC7_RGBAUnorm_sRGB);
    NSUInteger height = MAX(t.height >> level, (NSUInteger)1);
    if (bc && origin.y + size.height == height) size.height = (size.height + 3) & ~(NSUInteger)3;
    return size;
}
static void nvVolumeB2T(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                        NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    size = nvBlockEdge(t, level, origin, size);
    if (!nvVolumeSplit(t, size, row, image)) return NVO(origNVVolumeB2T)(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin);
    for (NSUInteger z = 0; z < size.depth; z++)
        NVO(origNVVolumeB2T)(self, _cmd, buffer, offset + z * image, row, image, MTLSizeMake(size.width, size.height, 1), t, slice, level,
                        MTLOriginMake(origin.x, origin.y, origin.z + z));
}
static void nvVolumeB2TOptions(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                               NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    size = nvBlockEdge(t, level, origin, size);
    if (!nvVolumeSplit(t, size, row, image))
        return NVO(origNVVolumeB2TOptions)(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin, options);
    for (NSUInteger z = 0; z < size.depth; z++)
        NVO(origNVVolumeB2TOptions)(self, _cmd, buffer, offset + z * image, row, image, MTLSizeMake(size.width, size.height, 1), t, slice, level,
                               MTLOriginMake(origin.x, origin.y, origin.z + z), options);
}
static void nvVolumeT2B(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                        NSUInteger offset, NSUInteger row, NSUInteger image) {
    if (!nvVolumeSplit(t, size, row, image)) return NVO(origNVVolumeT2B)(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image);
    for (NSUInteger z = 0; z < size.depth; z++)
        NVO(origNVVolumeT2B)(self, _cmd, t, slice, level, MTLOriginMake(origin.x, origin.y, origin.z + z), MTLSizeMake(size.width, size.height, 1),
                        buffer, offset + z * image, row, image);
}
static void nvVolumeT2BOptions(id self, SEL _cmd, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                               NSUInteger offset, NSUInteger row, NSUInteger image, MTLBlitOption options) {
    if (!nvVolumeSplit(t, size, row, image))
        return NVO(origNVVolumeT2BOptions)(self, _cmd, t, slice, level, origin, size, buffer, offset, row, image, options);
    for (NSUInteger z = 0; z < size.depth; z++)
        NVO(origNVVolumeT2BOptions)(self, _cmd, t, slice, level, MTLOriginMake(origin.x, origin.y, origin.z + z),
                               MTLSizeMake(size.width, size.height, 1), buffer, offset + z * image, row, image, options);
}
static void nvVolumeCopies(void) {  // items 65 and 67; after item 53, whose buffer-to-texture hook it calls
    static const char *const kEncoder = "NVMTLBlitCommandEncoder_KEPLER_A", *const kBufferToTexture =
        "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",
                             *const kTextureToBuffer =
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:";
    char withOptions[256];
    const char *volume = getenv("MTLSHIM_NV_VOLUME_COPY"), *edge = getenv("MTLSHIM_NV_BLOCK_EDGE");
    nvVolumeOn = !(volume && !strcmp(volume, "0"));
    nvBlockEdgeOn = !(edge && !strcmp(edge, "0"));
    if (origNVVolumeB2T || (!nvVolumeOn && !nvBlockEdgeOn) || !definesMethod(kEncoder, kBufferToTexture)) return;
    origNVVolumeB2T = (BufferToTextureIMP)keplerSwizzle(kEncoder, kBufferToTexture, (IMP)nvVolumeB2T);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kBufferToTexture);
    if (definesMethod(kEncoder, withOptions))
        origNVVolumeB2TOptions = (BufferToTextureOptionsIMP)keplerSwizzle(kEncoder, withOptions, (IMP)nvVolumeB2TOptions);
    if (definesMethod(kEncoder, kTextureToBuffer))
        origNVVolumeT2B = (TextureToBufferIMP)keplerSwizzle(kEncoder, kTextureToBuffer, (IMP)nvVolumeT2B);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kTextureToBuffer);
    if (definesMethod(kEncoder, withOptions))
        origNVVolumeT2BOptions = (TextureToBufferOptionsIMP)keplerSwizzle(kEncoder, withOptions, (IMP)nvVolumeT2BOptions);
}
static void stencilCopies(void) {
    static const char *const kTextureToBuffer =
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:";
    char withOptions[256];
    if (origIGTextureToBuffer || !definesMethod("MTLIGAccelBlitCommandEncoder", kTextureToBuffer)) return;
    const char *setting = getenv("MTLSHIM_STENCIL_COPY"), *image = class_getImageName(objc_getClass("MTLIGAccelBlitCommandEncoder"));
    ivbStencilRows = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(setting && !strcmp(setting, "0"));
    origIGTextureToBuffer = (TextureToBufferIMP)swizzle("MTLIGAccelBlitCommandEncoder", kTextureToBuffer, (IMP)igTextureToBuffer);
    snprintf(withOptions, sizeof withOptions, "%soptions:", kTextureToBuffer);
    if (definesMethod("MTLIGAccelBlitCommandEncoder", withOptions))
        origIGTextureToBufferOptions = (TextureToBufferOptionsIMP)swizzle("MTLIGAccelBlitCommandEncoder", withOptions, (IMP)igTextureToBufferOptions);
}

static const void *kBlitCommandBuffer = &kBlitCommandBuffer, *kPendingDepthStencil = &kPendingDepthStencil;
static const void *kDeferRest = &kDeferRest;  // item 63: later commands of the encoder wait for its end
enum { kRewriteDepth = 1, kRewriteStencil = 2 };

// Item 22 creates depth textures with several levels or slices without HiZ, where the driver has bHizDisable. The Ivy
// Bridge driver has no such switch, so there they keep it, and blits into their levels and slices are rewritten here too
// (s22 on the HD 4000: depth copied into level 2 failed every later depth test against it).
static BOOL keepsHiZ(id<MTLTexture> t) {
    return !origIGNewTexture || !igHizDisableOffset || (t.mipmapLevelCount == 1 && t.arrayLength == 1 && t.textureType == MTLTextureType2D);
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
    // loaded by a blit (item 33), and the rewrite's own render passes there would break them. The depth of such a
    // Depth32Float_Stencil8 texture goes through that temporary too, so it never meets the texture's own HiZ (and its
    // rewrite would end in item 33's copy back, a blit into it again).
    if (t.mipmapLevelCount > 1 || t.arrayLength > 1) {
        what &= ~kRewriteStencil;
        if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) what &= ~kRewriteDepth;
    }
    if (!what || !size.width || !size.height || !objc_getAssociatedObject(encoder, kBlitCommandBuffer)) return;
    NSMutableArray *pending = objc_getAssociatedObject(encoder, kPendingDepthStencil);
    if (!pending) objc_setAssociatedObject(encoder, kPendingDepthStencil, pending = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *last = [pending.lastObject isKindOfClass:[NSArray class]] ? pending.lastObject : nil;  // the driver's variant without options may call the one with them
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
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromBuffer:buffer sourceOffset:offset sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:size toTexture:t
                destinationSlice:slice destinationLevel:level destinationOrigin:origin];
        }))
        return;
    t = viewBlitTarget(t, &slice, &level);  // item 49
    if (stencilCopyIn(self, buffer, offset, row, image, size, t, slice, level, origin, MTLBlitOptionNone, NO)) return;  // item 37
    if (depthLevelCopyIn(self, buffer, offset, row, size, t, slice, level, origin, MTLBlitOptionNone)) return;  // item 63
    origIGBufferToTexture(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin);
    noteDepthStencilWrite(self, t, slice, level, origin, size, MTLBlitOptionNone);
}
static void igBufferToTextureOptions(id self, SEL _cmd, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLSize size, id t,
                                     NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromBuffer:buffer sourceOffset:offset sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:size toTexture:t
                destinationSlice:slice destinationLevel:level destinationOrigin:origin options:options];
        }))
        return;
    t = viewBlitTarget(t, &slice, &level);  // item 49
    if (stencilCopyIn(self, buffer, offset, row, image, size, t, slice, level, origin, options, YES)) return;  // item 37
    if (depthLevelCopyIn(self, buffer, offset, row, size, t, slice, level, origin, options)) return;  // item 63
    origIGBufferToTextureOptions(self, _cmd, buffer, offset, row, image, size, t, slice, level, origin, options);
    noteDepthStencilWrite(self, t, slice, level, origin, size, options);
}
// 72. Copies between a format and its sRGB variant on Ivy Bridge and Haswell. copyFromTexture:...toTexture: from RGBA8Unorm to
// RGBA8Unorm_sRGB (and back, and BGRA8, BC1, BC3) doesn't copy the bytes, as Metal says it does: RGBA8 and BGRA8 texels
// come out converted (a 1 became 13, the sRGB encoding of 1/255; the other way 3 became 0), and BC blocks garbled, at
// every level (the HD 4000 and the Iris Pro; the R9 is right). Copies within one format, and between textures and buffers,
// are right. WebGPU's copyTextureToTexture between rgba8unorm and rgba8unorm-srgb (and bgra8 and the BC pairs) failed
// (WebGPU CTS copyTextureToTexture color_textures; Dawn copies through a view of the other format, which goes wrong the
// same way). Such copies, through
// views too, go through a temporary buffer between the root textures: out of the source, then into the destination.
// MTLSHIM_SRGB_COPY=0 turns it off. Test: s73 on the HD 4000 and the Iris Pro.
static BOOL ivbSrgbCopies;
static BOOL srgbPairLayout(MTLPixelFormat f, NSUInteger *block, NSUInteger *bytes) {
    switch (f) {
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
            *block = 1, *bytes = 4; return YES;
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:
            *block = 4, *bytes = 8; return YES;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB: case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
            *block = 4, *bytes = 16; return YES;
        default:
            return NO;
    }
}
static BOOL srgbPairCopy(id encoder, id<MTLTexture> source, NSUInteger sourceSlice, NSUInteger sourceLevel, MTLOrigin sourceOrigin, MTLSize size,
                         id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    if (!ivbSrgbCopies || !source || !t || source.sampleCount > 1 || t.sampleCount > 1 || !size.width || !size.height || !size.depth) return NO;
    // through views too (Dawn copies through a view of the other format): the bytes go between the root textures,
    // whatever their format (rootTexture stops at a parent of another format)
    id<MTLTexture> (^rawRoot)(id<MTLTexture>, NSUInteger *, NSUInteger *) = ^(id<MTLTexture> texture, NSUInteger *lv, NSUInteger *sl) {
        while (texture.parentTexture) *lv += texture.parentRelativeLevel, *sl += texture.parentRelativeSlice, texture = texture.parentTexture;
        return texture;
    };
    id<MTLTexture> sourceRoot = rawRoot(source, &sourceLevel, &sourceSlice), root = rawRoot(t, &level, &slice);
    MTLPixelFormat formats[4] = {source.pixelFormat, t.pixelFormat, sourceRoot.pixelFormat, root.pixelFormat};
    if (formats[0] == formats[1] && formats[1] == formats[2] && formats[2] == formats[3]) return NO;
    NSUInteger block, bytes, block2, bytes2;
    if (!srgbPairLayout(formats[0], &block, &bytes)) return NO;
    for (int i = 1; i < 4; i++)
        if (!srgbPairLayout(formats[i], &block2, &bytes2) || block != block2 || bytes != bytes2) return NO;
    source = sourceRoot, t = root;
    NSUInteger row = (size.width + block - 1) / block * bytes, image = row * ((size.height + block - 1) / block);
    id<MTLBuffer> temporary = [t.device newBufferWithLength:image * size.depth options:MTLResourceStorageModePrivate];
    if (!temporary) return NO;
    id<MTLBlitCommandEncoder> e = encoder;
    [e copyFromTexture:source sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:size toBuffer:temporary
     destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:image];
    [e copyFromBuffer:temporary sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:size toTexture:t destinationSlice:slice
     destinationLevel:level destinationOrigin:origin];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] copy between a format and its sRGB variant made through a buffer\n");
    return YES;
}

static void igTextureToTexture(id self, SEL _cmd, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, MTLOrigin sourceOrigin, MTLSize size,
                               id t, NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            [e copyFromTexture:source sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:size toTexture:t
              destinationSlice:slice destinationLevel:level destinationOrigin:origin];
        }))
        return;
    source = viewBlitTarget(source, &sourceSlice, &sourceLevel);  // item 49
    t = viewBlitTarget(t, &slice, &level);
    if (srgbPairCopy(self, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin)) return;  // item 72
    if (depthLevelCopyBetween(self, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin, MTLBlitOptionNone)) return;  // item 63
    origIGTextureToTexture(self, _cmd, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin);
    noteDepthStencilWrite(self, t, slice, level, origin, size, MTLBlitOptionNone);
}
static void igTextureToTextureOptions(id self, SEL _cmd, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, MTLOrigin sourceOrigin,
                                      MTLSize size, id t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) {
            ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption))objc_msgSend)(
                e, _cmd, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin, options);
        }))
        return;
    source = viewBlitTarget(source, &sourceSlice, &sourceLevel);  // item 49
    t = viewBlitTarget(t, &slice, &level);
    if (srgbPairCopy(self, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin)) return;  // item 72
    if (depthLevelCopyBetween(self, source, sourceSlice, sourceLevel, sourceOrigin, size, t, slice, level, origin, options)) return;  // item 63
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

// 63. Blits at levels 1+ of mipmapped depth arrays on Ivy Bridge. Any blit that reads or writes level 1 or higher of a
// Depth16Unorm or Depth32Float 2D-array, cube or cube-array texture with several levels (into or out of a buffer or another
// texture, even 4x4 texels) left bands of the whole texture wrong: rows of other slices zeroed or overwritten with another
// level's (in a 2-layer, 3-level 64x64 cube array, a copy out of level 1 face 0 broke parts of 13 other slices), and the copy
// itself read or wrote the same wrong layout. Shader reads before the blit were right, and blits at level 0 change nothing
// (Ivy Bridge only: the Iris Pro and the R9 read every slice right). Such textures keep HiZ on Ivy Bridge (item 22), and
// the driver's resolve for a blit at a lower level seems to use a layout of its own. These copies no longer reach the
// driver: when the blit encoder ends, in order with item 22's rewrites, a compute pass reads the texels with read() (into
// the destination buffer, or into a temporary one), and texels for the texture are written by item 22's render pass from a
// temporary buffer, filled in place by a buffer copy (or by the driver's copy out of a texture the bug doesn't touch). The
// encoder's later commands (copies, buffer copies, fills, synchronizes, mipmap generation) then wait too and run after it
// in order, so a copy of the destination or a synchronize of a managed buffer sees the result. Copies of
// Depth32Float_Stencil8 go this way only with MTLBlitOptionDepthFromDepthStencil. MTLSHIM_DEPTH_LEVEL_BLITS=0 turns it off.
// Test: s70 on the HD 4000.
static BOOL ivbDepthLevelBlits;
static NSString *const kDepthCopy = @"depth copy";

static BOOL depthLevelBlit(id<MTLTexture> t, NSUInteger level, MTLBlitOption options) {
    if (!ivbDepthLevelBlits || !level || !t || t.parentTexture || t.sampleCount > 1 || t.mipmapLevelCount < 2) return NO;
    MTLTextureType type = t.textureType;
    if (type != MTLTextureType2DArray && type != MTLTextureTypeCube && type != MTLTextureTypeCubeArray) return NO;
    switch (t.pixelFormat) {
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
            return YES;
        case MTLPixelFormatDepth32Float_Stencil8:
            return (options & MTLBlitOptionDepthFromDepthStencil) != 0;
        default:
            return NO;
    }
}
static NSUInteger depthBytes(id<MTLTexture> t) { return t.pixelFormat == MTLPixelFormatDepth16Unorm ? 2 : 4; }

// Queues a copy for the encoder's end. From texture `from` (slice, level, origin) or from `data`, a tight buffer already
// filled (rows of size.width texels); to `buffer` at offset/bytesPerRow, or to texture `to` at toSlice, toLevel, toOrigin.
static BOOL queueDepthCopy(id encoder, id<MTLTexture> from, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size,
                           id<MTLBuffer> data, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow, id<MTLTexture> to,
                           NSUInteger toSlice, NSUInteger toLevel, MTLOrigin toOrigin) {
    if (!objc_getAssociatedObject(encoder, kBlitCommandBuffer)) return NO;
    NSMutableArray *pending = objc_getAssociatedObject(encoder, kPendingDepthStencil);
    if (!pending) objc_setAssociatedObject(encoder, kPendingDepthStencil, pending = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder, kDeferRest, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // [0] marker, [1] slice, [2] level, [3] origin, [4] size (as item 22's entries, whose dedup reads [3] and [4]), then the rest
    [pending addObject:@[kDepthCopy, @(slice), @(level), [NSValue valueWithBytes:&origin objCType:@encode(MTLOrigin)],
                         [NSValue valueWithBytes:&size objCType:@encode(MTLSize)], from ?: (id)NSNull.null, data ?: (id)NSNull.null,
                         buffer ?: (id)NSNull.null, @(offset), @(bytesPerRow), to ?: (id)NSNull.null, @(toSlice), @(toLevel),
                         [NSValue valueWithBytes:&toOrigin objCType:@encode(MTLOrigin)]]];
    return YES;
}

// The hooks' entry points; YES if the copy was taken over.
static BOOL depthLevelCopyOut(id encoder, id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id<MTLBuffer> buffer,
                              NSUInteger offset, NSUInteger bytesPerRow, MTLBlitOption options) {
    if (!depthLevelBlit(t, level, options) || size.depth != 1 || !size.width || !size.height) return NO;
    return queueDepthCopy(encoder, t, slice, level, origin, size, nil, buffer, offset, bytesPerRow, nil, 0, 0, MTLOriginMake(0, 0, 0));
}
static id<MTLBuffer> tightCopy(id encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow, MTLSize size, NSUInteger bpp) {
    NSUInteger row = size.width * bpp;
    id<MTLBuffer> data = [buffer.device newBufferWithLength:row * size.height options:MTLResourceStorageModePrivate];
    if (!data) return nil;
    if (bytesPerRow == row)
        [(id<MTLBlitCommandEncoder>)encoder copyFromBuffer:buffer sourceOffset:offset toBuffer:data destinationOffset:0 size:row * size.height];
    else
        for (NSUInteger y = 0; y < size.height; y++)
            [(id<MTLBlitCommandEncoder>)encoder copyFromBuffer:buffer sourceOffset:offset + y * bytesPerRow toBuffer:data destinationOffset:y * row size:row];
    return data;
}
static BOOL depthLevelCopyIn(id encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow, MTLSize size, id<MTLTexture> t,
                             NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    if (!depthLevelBlit(t, level, options) || size.depth != 1 || !size.width || !size.height || !objc_getAssociatedObject(encoder, kBlitCommandBuffer))
        return NO;
    id<MTLBuffer> data = tightCopy(encoder, buffer, offset, bytesPerRow, size, depthBytes(t));
    return data && queueDepthCopy(encoder, nil, 0, 0, MTLOriginMake(0, 0, 0), size, data, nil, 0, 0, t, slice, level, origin);
}
static BOOL depthLevelCopyBetween(id encoder, id<MTLTexture> from, NSUInteger fromSlice, NSUInteger fromLevel, MTLOrigin fromOrigin, MTLSize size,
                                  id<MTLTexture> to, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    BOOL out = depthLevelBlit(from, fromLevel, options), in = depthLevelBlit(to, level, options);
    if ((!out && !in) || size.depth != 1 || !size.width || !size.height || !objc_getAssociatedObject(encoder, kBlitCommandBuffer)) return NO;
    if (out) return queueDepthCopy(encoder, from, fromSlice, fromLevel, fromOrigin, size, nil, nil, 0, 0, to, slice, level, origin);
    // into such a level from a texture the bug doesn't touch: its texels into a tight buffer now, with the driver's copy
    NSUInteger bpp = depthBytes(to), row = size.width * bpp;
    id<MTLBuffer> data = [to.device newBufferWithLength:row * size.height options:MTLResourceStorageModePrivate];
    if (!data) return NO;
    BOOL combined = from.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    [(id<MTLBlitCommandEncoder>)encoder copyFromTexture:from sourceSlice:fromSlice sourceLevel:fromLevel sourceOrigin:fromOrigin sourceSize:size
                                               toBuffer:data destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * size.height
                                                options:combined ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
    return queueDepthCopy(encoder, nil, 0, 0, MTLOriginMake(0, 0, 0), size, data, nil, 0, 0, to, slice, level, origin);
}

// Compute pipelines reading depth from a 2D-array / cube / cube-array texture into a float or ushort buffer region
static id<MTLComputePipelineState> depthReader(id<MTLDevice> device, MTLTextureType type, BOOL sixteen) {
    static NSMutableDictionary *pipelines;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%p-%lu-%d", device, (unsigned long)type, sixteen];
    os_unfair_lock_lock(&lock);
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    id<MTLComputePipelineState> pipeline = pipelines[key];
    os_unfair_lock_unlock(&lock);
    if (pipeline) return pipeline;
    static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Copy { uint x, y, width, height, slice, level, offset, bytesPerRow; };\n"
        "static void put(device uchar *o, constant Copy &c, uint2 g, float v, bool sixteen) {\n"
        "    device uchar *at = o + c.offset + g.y * c.bytesPerRow;\n"
        "    if (sixteen) ((device ushort *)at)[g.x] = ushort(rint(v * 65535.0f));\n"
        "    else ((device float *)at)[g.x] = v;\n"
        "}\n"
        "#define READER(name, T, READ, sixteen) \\\n"
        "kernel void name(T t [[texture(0)]], device uchar *o [[buffer(0)]], constant Copy &c [[buffer(1)]], uint2 g [[thread_position_in_grid]]) { \\\n"
        "    if (g.x >= c.width || g.y >= c.height) return; \\\n"
        "    uint2 p = uint2(c.x + g.x, c.y + g.y); \\\n"
        "    put(o, c, g, READ, sixteen); \\\n"
        "}\n"
        "READER(array32, depth2d_array<float>, t.read(p, c.slice, c.level), false)\n"
        "READER(array16, depth2d_array<float>, t.read(p, c.slice, c.level), true)\n"
        "READER(cube32, depthcube<float>, t.read(p, c.slice, c.level), false)\n"
        "READER(cube16, depthcube<float>, t.read(p, c.slice, c.level), true)\n"
        "READER(cubeArray32, depthcube_array<float>, t.read(p, c.slice % 6u, c.slice / 6u, c.level), false)\n"
        "READER(cubeArray16, depthcube_array<float>, t.read(p, c.slice % 6u, c.slice / 6u, c.level), true)\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    NSString *name = [NSString stringWithFormat:@"%@%d", type == MTLTextureTypeCube ? @"cube" : type == MTLTextureTypeCubeArray ? @"cubeArray" : @"array",
                      sixteen ? 16 : 32];
    id<MTLFunction> function = [library newFunctionWithName:name];
    pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
    if (!pipeline && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] depth level copy pipeline: %s\n", error.localizedDescription.UTF8String);
    os_unfair_lock_lock(&lock);
    if (pipeline) pipelines[key] = pipeline;
    os_unfair_lock_unlock(&lock);
    return pipeline;
}

static id<MTLRenderPipelineState> depthStencilWriter(id<MTLDevice> device, MTLPixelFormat format, int kind);
static id<MTLDepthStencilState> depthStencilWriteState(id<MTLDevice> device, BOOL depth, uint32_t stencilMask);

// Writes depth from a tight buffer (rows of size.width texels) into a region of `t`, with item 22's render pass
static void writeDepthRegion(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> t, NSUInteger slice, NSUInteger level, MTLOrigin origin,
                             MTLSize size, id<MTLBuffer> data) {
    id<MTLRenderPipelineState> pipeline = depthStencilWriter(t.device, t.pixelFormat, kRewriteDepth);
    if (!pipeline) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = t;
    pass.depthAttachment.level = level;
    pass.depthAttachment.slice = slice;
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
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
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:depthStencilWriteState(t.device, YES, 0)];
    [encoder setFragmentBuffer:data offset:0 atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

static void runDepthCopy(id<MTLCommandBuffer> commandBuffer, NSArray *entry) {
    NSUInteger slice = [entry[1] unsignedIntegerValue], level = [entry[2] unsignedIntegerValue];
    MTLOrigin origin, toOrigin;
    MTLSize size;
    [entry[3] getValue:&origin];
    [entry[4] getValue:&size];
    [entry[13] getValue:&toOrigin];
    id<MTLTexture> from = entry[5] == NSNull.null ? nil : entry[5], to = entry[10] == NSNull.null ? nil : entry[10];
    id<MTLBuffer> data = entry[6] == NSNull.null ? nil : entry[6], buffer = entry[7] == NSNull.null ? nil : entry[7];
    NSUInteger toSlice = [entry[11] unsignedIntegerValue], toLevel = [entry[12] unsignedIntegerValue];
    if (from) {  // read with the sampler, into the destination buffer or a tight temporary
        BOOL sixteen = from.pixelFormat == MTLPixelFormatDepth16Unorm;
        NSUInteger offset = [entry[8] unsignedIntegerValue], bytesPerRow = [entry[9] unsignedIntegerValue];
        id<MTLComputePipelineState> pipeline = depthReader(from.device, from.textureType, sixteen);
        if (!pipeline) return;
        if (!buffer) {
            buffer = data = [from.device newBufferWithLength:size.width * size.height * depthBytes(from) options:MTLResourceStorageModePrivate];
            offset = 0, bytesPerRow = size.width * depthBytes(from);
            if (!buffer) return;
        }
        const uint32_t copy[8] = {(uint32_t)origin.x, (uint32_t)origin.y, (uint32_t)size.width, (uint32_t)size.height, (uint32_t)slice,
                                  (uint32_t)level, (uint32_t)offset, (uint32_t)bytesPerRow};
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:from atIndex:0];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder setBytes:copy length:sizeof copy atIndex:1];
        [encoder dispatchThreadgroups:MTLSizeMake((size.width + 7) / 8, (size.height + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];
    }
    if (to && data) {
        if (depthLevelBlit(to, toLevel, MTLBlitOptionDepthFromDepthStencil)) writeDepthRegion(commandBuffer, to, toSlice, toLevel, toOrigin, size, data);
        else {  // a destination the bug doesn't touch: a blit, which goes through the hooks (item 22 rewrites it where needed)
            NSUInteger row = size.width * depthBytes(to);
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromBuffer:data sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * size.height sourceSize:size toTexture:to
                destinationSlice:toSlice destinationLevel:toLevel destinationOrigin:toOrigin
                         options:to.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
            [blit endEncoding];
        }
    }
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] depth copy %s level %lu (%lux%lu) done with %s\n", from ? "out of" : "into", (unsigned long)(from ? level : toLevel),
                (unsigned long)size.width, (unsigned long)size.height, from ? "a compute pass" : "a render pass");
}

// Once an encoder has a copy queued for its end, every later command of it waits too and runs then, in order, on a blit
// encoder of the shim's own (whose copies go through these hooks again): a copy out of the destination, a synchronize of
// a managed buffer or a fill must see the queued copy done.
static BOOL deferBlit(id encoder, BlitCommand command) {
    if (!objc_getAssociatedObject(encoder, kDeferRest)) return NO;
    NSMutableArray *pending = objc_getAssociatedObject(encoder, kPendingDepthStencil);
    if (!pending) return NO;
    [pending addObject:[command copy]];
    return YES;
}
typedef void (*BufferToBufferIMP)(id, SEL, id, NSUInteger, id, NSUInteger, NSUInteger);
static BufferToBufferIMP origIGBufferToBuffer;
static void igBufferToBuffer(id self, SEL _cmd, id from, NSUInteger fromOffset, id to, NSUInteger toOffset, NSUInteger size) {
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { [e copyFromBuffer:from sourceOffset:fromOffset toBuffer:to destinationOffset:toOffset size:size]; }))
        return;
    origIGBufferToBuffer(self, _cmd, from, fromOffset, to, toOffset, size);
}
// The other commands, by signature; each hook finds the driver's method by selector.
enum { kWaitingMax = 16 };
static struct { SEL selector; IMP original; } waitingOriginals[kWaitingMax];
static IMP waitingOriginal(SEL selector) {
    for (int k = 0; k < kWaitingMax && waitingOriginals[k].selector; k++)
        if (waitingOriginals[k].selector == selector) return waitingOriginals[k].original;
    return NULL;
}
static void igWaitingObject(id self, SEL _cmd, id a) {  // synchronizeResource:, updateFence:, waitForFence:, ...
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { ((void (*)(id, SEL, id))objc_msgSend)(e, _cmd, a); })) return;
    ((void (*)(id, SEL, id))waitingOriginal(_cmd))(self, _cmd, a);
}
static void igWaitingSliceLevel(id self, SEL _cmd, id a, NSUInteger slice, NSUInteger level) {  // synchronizeTexture:slice:level:, ...
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(e, _cmd, a, slice, level); })) return;
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))waitingOriginal(_cmd))(self, _cmd, a, slice, level);
}
static void igWaitingRange(id self, SEL _cmd, id a, NSRange range) {  // resetCommandsInBuffer:withRange:, ...
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { ((void (*)(id, SEL, id, NSRange))objc_msgSend)(e, _cmd, a, range); })) return;
    ((void (*)(id, SEL, id, NSRange))waitingOriginal(_cmd))(self, _cmd, a, range);
}
static void igWaitingSample(id self, SEL _cmd, id a, NSUInteger index, BOOL barrier) {  // sampleCountersInBuffer:atSampleIndex:withBarrier:
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { ((void (*)(id, SEL, id, NSUInteger, BOOL))objc_msgSend)(e, _cmd, a, index, barrier); })) return;
    ((void (*)(id, SEL, id, NSUInteger, BOOL))waitingOriginal(_cmd))(self, _cmd, a, index, barrier);
}
static void igWaitingRangeTo(id self, SEL _cmd, id a, NSRange range, id b, NSUInteger index) {  // resolveCounters:..., copyIndirectCommandBuffer:...
    if (deferBlit(self, ^(id<MTLBlitCommandEncoder> e) { ((void (*)(id, SEL, id, NSRange, id, NSUInteger))objc_msgSend)(e, _cmd, a, range, b, index); }))
        return;
    ((void (*)(id, SEL, id, NSRange, id, NSUInteger))waitingOriginal(_cmd))(self, _cmd, a, range, b, index);
}

static void rewriteDepthStencil(id<MTLCommandBuffer> commandBuffer, NSArray *pending) {
    id<MTLBlitCommandEncoder> replay = nil;  // item 63: commands that waited, run in a row on one encoder
    for (NSArray *entry in pending) {
        if (![entry isKindOfClass:[NSArray class]]) {
            if (!replay) replay = [commandBuffer blitCommandEncoder];
            ((BlitCommand)entry)(replay);
            continue;
        }
        if (replay) [replay endEncoding], replay = nil;
        if (entry[0] == kDepthCopy) {  // item 63
            runDepthCopy(commandBuffer, entry);
            continue;
        }
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
    if (replay) [replay endEncoding];
}

static void igBlitEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingDepthStencil);
    id<MTLCommandBuffer> commandBuffer = objc_getAssociatedObject(self, kBlitCommandBuffer);
    origIGBlitEndEncoding(self, _cmd);
    objc_setAssociatedObject(self, kBlitCommandBuffer, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, kDeferRest, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!pending) return;
    objc_setAssociatedObject(self, kPendingDepthStencil, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (commandBuffer) rewriteDepthStencil(commandBuffer, pending);
}

static void blitsIntoDepthStencil(void) {
    static const char *const kBufferToTexture =
        "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";
    static const char *const kTextureToTexture =
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";
    const char *views = getenv("MTLSHIM_VIEW_BLITS"), *image = class_getImageName(objc_getClass("MTLIGAccelBlitCommandEncoder"));
    ivbViewBlits = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(views && !strcmp(views, "0"));  // item 49
    const char *clearDraw = getenv("MTLSHIM_DEPTH_CLEAR_DRAW");
    ivbDepthClearDraw = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(clearDraw && !strcmp(clearDraw, "0"));  // item 64
    hswDepthClearDraw = image && strstr(image, "/AppleIntelHD5000GraphicsMTLDriver.bundle/") && !(clearDraw && !strcmp(clearDraw, "0"));
    const char *levelBlits = getenv("MTLSHIM_DEPTH_LEVEL_BLITS");
    ivbDepthLevelBlits = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(levelBlits && !strcmp(levelBlits, "0"));  // item 63
    const char *levelRepair = getenv("MTLSHIM_DEPTH_LEVEL_REPAIR");
    ivbDepthLevelRepair = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(levelRepair && !strcmp(levelRepair, "0"));  // item 68
    const char *srgbCopy = getenv("MTLSHIM_SRGB_COPY");
    ivbSrgbCopies = image && (strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") || strstr(image, "/AppleIntelHD5000GraphicsMTLDriver.bundle/")) &&
                    !(srgbCopy && !strcmp(srgbCopy, "0"));  // item 72 (Ivy Bridge and Haswell)
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
    // item 63: the commands that wait behind a queued copy (fillBuffer: waits in item 20's hook)
    if (definesMethod("MTLIGAccelBlitCommandEncoder", "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:"))
        origIGBufferToBuffer = (BufferToBufferIMP)swizzle("MTLIGAccelBlitCommandEncoder", "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:",
                                                          (IMP)igBufferToBuffer);
    static const struct { const char *selector; IMP replacement; } waiting[] = {
        {"synchronizeResource:", (IMP)igWaitingObject},
        {"generateMipmapsForTexture:", (IMP)igWaitingObject},
        {"updateFence:", (IMP)igWaitingObject},
        {"waitForFence:", (IMP)igWaitingObject},
        {"optimizeContentsForGPUAccess:", (IMP)igWaitingObject},
        {"optimizeContentsForCPUAccess:", (IMP)igWaitingObject},
        {"synchronizeTexture:slice:level:", (IMP)igWaitingSliceLevel},
        {"optimizeContentsForGPUAccess:slice:level:", (IMP)igWaitingSliceLevel},
        {"optimizeContentsForCPUAccess:slice:level:", (IMP)igWaitingSliceLevel},
        {"resetCommandsInBuffer:withRange:", (IMP)igWaitingRange},
        {"optimizeIndirectCommandBuffer:withRange:", (IMP)igWaitingRange},
        {"sampleCountersInBuffer:atSampleIndex:withBarrier:", (IMP)igWaitingSample},
        {"resolveCounters:inRange:destinationBuffer:destinationOffset:", (IMP)igWaitingRangeTo},
        {"copyIndirectCommandBuffer:sourceRange:destination:destinationIndex:", (IMP)igWaitingRangeTo}};
    int used = 0;
    for (size_t k = 0; k < sizeof waiting / sizeof *waiting && used < kWaitingMax; k++)
        if (definesMethod("MTLIGAccelBlitCommandEncoder", waiting[k].selector)) {
            SEL selector = sel_registerName(waiting[k].selector);
            waitingOriginals[used].original = swizzle("MTLIGAccelBlitCommandEncoder", waiting[k].selector, waiting[k].replacement);
            waitingOriginals[used++].selector = selector;
        }
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
// about 2400 failures in Chrome and Safari). A nearest gather's 2x2 footprint does span face edges, so the Intel adapter
// gives cube gathers a linear constexpr sampler, which this leaves seamless (i20). Samplers with a compare function get
// the programmed addressing too: ANGLE passes GL's default compare function (LEQUAL) to every sampler, comparison on or
// off, so leaving those seamless (as tried for WebGPU's compare gathers) broke every WebGL integer cube again (s52). A
// cube gather_compare at a face edge through a nearest compare sampler therefore reads one face (WebGPU CTS
// textureGatherCompare, 60 cases), the smaller loss. MTLSHIM_NEAREST_CUBE_CLAMP=0 turns it off.
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
    // the 12.x driver's sampler state, and the Ivy Bridge driver's, the same fields under another name
    static const char kLayout[] = "{SGfxSamplerState=\"AnisotropicAlgorithm\"b1\"TextureLODBias\"b13\"MinModeFilter\"b3\"MagModeFilter\"b3";
    static const char kLayoutIVB[] = "{SGfxSamplerState_Gen7=\"AnisotropicAlgorithm\"b1\"TextureLODBias\"b13\"MinModeFilter\"b3\"MagModeFilter\"b3";
    const char *setting = getenv("MTLSHIM_NEAREST_CUBE_CLAMP");
    Class c = objc_getClass("MTLIGSampler");
    Ivar state = c ? class_getInstanceVariable(c, "samplerState") : NULL;
    if (origIGInitSamplerState || (setting && !strcmp(setting, "0")) || !state ||
        (strncmp(ivar_getTypeEncoding(state), kLayout, sizeof kLayout - 1) &&
         strncmp(ivar_getTypeEncoding(state), kLayoutIVB, sizeof kLayoutIVB - 1)) ||
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
static BOOL swizzleChangesNothing(MTLPixelFormat format, MTLTextureSwizzleChannels swizzle) {  // items 32 and 54
    int channels = channelCount(format);
    BOOL r001 = swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleOne);
    return swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha) ||
           (r001 && (channels == 1 || depthOrStencil(format))) ||
           (channels == 2 && swizzleIs(swizzle, MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleZero, MTLTextureSwizzleOne));
}
static id igSwizzleView(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) {
    format = sampleableStencilView(self, format);  // item 36
    id view = origIGSwizzleView(self, _cmd, format, type, levels, slices, swizzle);
    if (view) return view;
    if (!swizzleChangesNothing(format, swizzle)) return nil;
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

// 54. Methods the Kepler driver (GeForceMTLDriver) lacks, which MetalOld's classes don't provide either, so calling them threw
// "unrecognized selector" and aborted the process:
//   - -[NVMTLTexture newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:]. Kepler is family 1 (no swizzle), but
//     on a Mac whose only GPU it is, item 11 makes it family 2 for Chromium, whose Dawn makes its depth/stencil views with
//     the swizzle (R, 0, 0, 1). As item 32 on Intel: a swizzle that changes nothing a shader can see makes the view without
//     it, any other gets nil (what a driver without swizzle returns).
//   - -[NVMTLDevice newIndirectCommandBufferWithDescriptor:maxCount:options:], which MetalOld's
//     newIndirectCommandBufferWithDescriptor:maxCommandCount:options: calls for every driver. Kepler has no indirect command
//     buffers (not Mac2): nil, as for other GPUs without them (wgpu asks for one on any GPU).
// MTLSHIM_KEPLER_METHODS=0 turns it off. Tests: s36, s42 and s54 on the GTX 770.
static id nvSwizzleView(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) RETURNS_RETAINED;
static id nvSwizzleView(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices, MTLTextureSwizzleChannels swizzle) {
    if (!swizzleChangesNothing(format, swizzle)) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] swizzled texture view on Kepler: swizzle not supported, nil\n");
        return nil;
    }
    return ((NewViewRangeIMP)objc_msgSend)(
        self, @selector(newTextureViewWithPixelFormat:textureType:levels:slices:), format, type, levels, slices);
}
static id nvNoIndirectCommandBuffer(id self, SEL _cmd, id descriptor, NSUInteger count, MTLResourceOptions options) RETURNS_RETAINED;
static id nvNoIndirectCommandBuffer(id self, SEL _cmd, id descriptor, NSUInteger count, MTLResourceOptions options) {
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] indirect command buffer on Kepler: not supported, nil\n");
    return nil;
}
static void keplerMissingMethods(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_KEPLER_METHODS");
    Class texture = objc_getClass("NVMTLTexture"), device = objc_getClass("NVMTLDevice");
    if (done || (setting && !strcmp(setting, "0")) || !texture || !device ||
        !class_respondsToSelector(texture, @selector(newTextureViewWithPixelFormat:textureType:levels:slices:)))
        return;
    done = YES;
    struct objc_method_description view = protocol_getMethodDescription(
        @protocol(MTLTexture), @selector(newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:), YES, YES);
    MethodEntry viewMethod[] = {{"newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:", (IMP)nvSwizzleView, view.types}};
    MethodEntry icbMethod[] = {{"newIndirectCommandBufferWithDescriptor:maxCount:options:", (IMP)nvNoIndirectCommandBuffer, "@@:@QQ"}};
    if (view.types) addMethods(texture, "Kepler texture", viewMethod, 1);
    addMethods(device, "Kepler device", icbMethod, 1);
}

// 56. Views of views on the Kepler driver: a view made from a texture view of levels 1+ and slices 1+ dropped the first
// view's offset into its parent (a stencil view of a depth-stencil view of level 2, slice 2 read level 1's or slice 1's
// texels: s46; Dawn reads WebGPU's stencil8 through such views). Views of the texture itself are right. A view of a view
// is made from the root texture with the offsets added, which is what Metal defines it as. MTLSHIM_NV_VIEW_OF_VIEW=0 turns
// it off. Test: s46 on the GTX 770.
static NewViewRangeIMP origNVNewViewRange;
static id nvNewViewRange(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) RETURNS_RETAINED;
static id nvNewViewRange(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) {
    if (!((id<MTLTexture>)self).parentTexture) return origNVNewViewRange(self, _cmd, format, type, levels, slices);
    NSUInteger level = levels.location, slice = slices.location;
    id<MTLTexture> root = rootTexture(self, &level, &slice);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] view of a view made from the root texture (level %lu, slice %lu)\n", (unsigned long)level, (unsigned long)slice);
    return origNVNewViewRange(root, _cmd, format, type, NSMakeRange(level, levels.length), NSMakeRange(slice, slices.length));
}
static void keplerViewsOfViews(void) {
    static const char *const kTexture = "NVMTLTexture", *const kView = "newTextureViewWithPixelFormat:textureType:levels:slices:";
    const char *setting = getenv("MTLSHIM_NV_VIEW_OF_VIEW");
    if (origNVNewViewRange || (setting && !strcmp(setting, "0")) || !definesMethod(kTexture, kView)) return;
    origNVNewViewRange = (NewViewRangeIMP)swizzle(kTexture, kView, (IMP)nvNewViewRange);
}

// 58. Texture atomics on the Kepler driver. MSL 3.1 texture atomics (atomic_fetch_add etc. on a read_write
// texture2d<uint> / <int>) have no body in GeForceAIRPlugin's library, and the GPU's surface atomics can't be reached
// from it: the compile crashed the compiler (a01; Blender assumes texture atomics on every macOS 14+ Mac). Kepler can
// do them as global atomics if the texels are in a buffer: each R32Uint / R32Sint 2D texture of one level, one sample
// and no render-target use that is created with MTLTextureUsageShaderAtomic (which Metal requires for texture atomics,
// and which item 3 drops for the driver) is made a linear texture in a buffer of its own, after a 256-byte header
// {magic, row pitch in words, width, height} (written by a blit for private storage). The Kepler adapter
// (GeForceAIRCompat, NVAIR_TEXTURE_ATOMICS) turns each texture atomic into a global atomic on a hidden buffer
// parameter; its index is worked out here the same way from the pipeline's reflection: each read_write
// texture2d<uint> / <int> argument (not arrays), in order of its index, gets one, counted down from 30 over the buffer
// indices the function doesn't use (vertex functions keep 0-16 for vertex buffers). Before each draw or dispatch with
// such a pipeline, the buffer of the texture bound at that texture index (through views too) is bound at the hidden
// index, or a dummy without the header for any other texture (the atomics then land on a word of the dummy, as they
// do for coordinates outside the texture), and whatever the app had bound there is put back afterwards. 2D arrays, 3D
// and 1D textures have no linear form on Kepler (supportsLinearTexture2DArray is NO) and textures from heaps aren't
// covered: their atomics do nothing. The encoders keep track of their bindings only once a pipeline with such a texture
// argument exists (until then the hooks cost a branch: tracking every bind cost ~100 ns a call): an encoder that was
// already recording then can't know what it had bound before. MTLSHIM_NV_TEXTURE_ATOMICS=0 turns it off. Test: a01 and
// n04 on the GTX 770.
static BOOL ktaOn;
static volatile BOOL ktaTracking;  // a pipeline with hidden bindings exists
static const uint32_t kKTAMagic = 0x4154564E;  // "NVTA", as GeForceAIRCompat's kTexAtomicMagic
static const void *kKTABufferKey = &kKTABufferKey, *kKTABindingsKey = &kKTABindingsKey, *kKTAStateKey = &kKTAStateKey,
                  *kKTADummyKey = &kKTADummyKey, *kKTAQueueKey = &kKTAQueueKey;
typedef struct { uint8_t stage, hidden; uint16_t texture; } KTABinding;  // stage: 0 vertex, 1 fragment, 2 compute
enum { kKTADepthMask = 0xFFFF };  // KTABinding.texture of item 62's depth / stencil mask
static BOOL ktaDepthChannels;      // item 62 on

static BOOL ktaDevice(id device) {
    static Class nv;
    if (!nv) nv = objc_getClass("NVMTLDevice");
    return ktaOn && nv && [device isKindOfClass:nv];
}
static id ktaDeviceObject(id device, const void *key, id (^make)(void)) {  // one per device, made on first use
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    id object = objc_getAssociatedObject(device, key);
    if (!object) {
        object = make();
        if (object) objc_setAssociatedObject(device, key, object, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
    return object;
}
static id<MTLBuffer> ktaBacking(id<MTLTexture> texture) {  // the buffer item 58 made for it, or for the texture it views
    for (id<MTLTexture> t = texture; t; t = t.parentTexture) {
        id<MTLBuffer> buffer = objc_getAssociatedObject(t, kKTABufferKey);
        if (buffer) return buffer;
    }
    return nil;
}

typedef id (*KTANewTextureIMP)(id, SEL, MTLTextureDescriptor *) RETURNS_RETAINED;  // a new-family method: +1, as s42 checks
static KTANewTextureIMP ktaOrigNewTexture;
static id ktaNewTexture(id self, SEL _cmd, MTLTextureDescriptor *d) RETURNS_RETAINED;
static id ktaNewTexture(id self, SEL _cmd, MTLTextureDescriptor *d) {
    if (!ktaOn || !(d.usage & MTLTextureUsageShaderAtomic) || d.textureType != MTLTextureType2D || d.mipmapLevelCount != 1 ||
        d.sampleCount != 1 || (d.usage & MTLTextureUsageRenderTarget) || !d.width || !d.height ||
        (d.pixelFormat != MTLPixelFormatR32Uint && d.pixelFormat != MTLPixelFormatR32Sint))
        return ktaOrigNewTexture(self, _cmd, d);
    id<MTLDevice> device = self;
    NSUInteger align = MAX([device minimumLinearTextureAlignmentForPixelFormat:d.pixelFormat], (NSUInteger)4);
    NSUInteger row = (d.width * 4 + align - 1) / align * align, header = MAX(align, (NSUInteger)256);
    MTLStorageMode mode = d.storageMode == MTLStorageModeMemoryless ? MTLStorageModePrivate : d.storageMode;
    MTLResourceOptions options = (d.resourceOptions & ~MTLResourceStorageModeMask) | (mode << MTLResourceStorageModeShift);
    id<MTLBuffer> buffer = [device newBufferWithLength:header + row * d.height options:options];
    MTLTextureDescriptor *linear = [d copy];
    linear.usage = (d.usage & ~MTLTextureUsageShaderAtomic) | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    linear.storageMode = mode;
    id<MTLTexture> texture = buffer ? [buffer newTextureWithDescriptor:linear offset:header bytesPerRow:row] : nil;
    const uint32_t words[4] = {kKTAMagic, (uint32_t)(row / 4), (uint32_t)d.width, (uint32_t)d.height};
    BOOL written = NO;
    if (texture && mode != MTLStorageModePrivate) {
        memcpy(buffer.contents, words, sizeof words);
        if (mode == MTLStorageModeManaged) [buffer didModifyRange:NSMakeRange(0, sizeof words)];
        written = YES;
    } else if (texture) {  // private: a blit from a shared copy, finished before the app can use the texture
        id<MTLCommandQueue> queue = ktaDeviceObject(device, kKTAQueueKey, ^id { return [device newCommandQueue]; });
        id<MTLBuffer> staging = [device newBufferWithBytes:words length:sizeof words options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 toBuffer:buffer destinationOffset:0 size:sizeof words];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        written = cb.status == MTLCommandBufferStatusCompleted;
    }
    if (!written) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] texture atomics: no linear texture for %lux%lu, a tiled one instead\n",
                                               (unsigned long)d.width, (unsigned long)d.height);
        return ktaOrigNewTexture(self, _cmd, d);
    }
    objc_setAssociatedObject(texture, kKTABufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] texture atomics: %lux%lu texture made linear (%lu bytes a row)\n",
                                           (unsigned long)d.width, (unsigned long)d.height, (unsigned long)row);
    return texture;
}

// The adapter's hidden indices for one stage, from its reflection arguments.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // MetalOld has only the macOS 12 reflection API (MTLArgument)
static void ktaStageBindings(NSArray<MTLArgument *> *arguments, uint8_t stage, NSMutableData *out) {
    BOOL used[31] = {NO};
    NSMutableArray<MTLArgument *> *textures = [NSMutableArray array];
    for (MTLArgument *a in arguments) {
        if (a.type == MTLArgumentTypeBuffer) {
            if (stage == 0 && [a.name hasPrefix:@"vertexBuffer."]) continue;  // the vertex descriptor's: not arguments to the adapter
            for (NSUInteger k = 0; k < MAX(a.arrayLength, (NSUInteger)1); k++)
                if (a.index + k < 31) used[a.index + k] = YES;
        } else if (a.type == MTLArgumentTypeTexture && a.textureType == MTLTextureType2D && a.access == MTLArgumentAccessReadWrite &&
                   (a.textureDataType == MTLDataTypeUInt || a.textureDataType == MTLDataTypeInt) && a.arrayLength <= 1 && a.index < 0x10000) {
            [textures addObject:a];
        }
    }
    [textures sortUsingComparator:^NSComparisonResult(MTLArgument *x, MTLArgument *y) {
        return x.index < y.index ? NSOrderedAscending : x.index > y.index ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableData *bindings = [NSMutableData data];
    int next = 30, lowest = stage == 0 ? 17 : 0;
    for (MTLArgument *t in textures) {
        while (next >= lowest && used[next]) next--;
        if (next < lowest) return;  // the adapter left this function alone
        KTABinding b = {stage, (uint8_t)next--, (uint16_t)t.index};
        [bindings appendBytes:&b length:sizeof b];
    }
    // item 62: an ANGLE function (its ANGLE_angleUniforms argument) with a texture argument that isn't a depth texture
    // gets the depth / stencil mask at the next index, as the adapter (NVAIR_DEPTH_CHANNELS) works it out
    if (ktaDepthChannels && stage < 2) {
        BOOL angle = NO, texture = NO;
        for (MTLArgument *a in arguments) {
            angle |= a.type == MTLArgumentTypeBuffer && [a.name isEqualToString:@"ANGLE_angleUniforms"];
            texture |= a.type == MTLArgumentTypeTexture && !a.isDepthTexture;
        }
        while (angle && texture && next >= lowest && used[next]) next--;
        if (angle && texture && next >= lowest) {
            KTABinding b = {stage, (uint8_t)next--, kKTADepthMask};
            [bindings appendBytes:&b length:sizeof b];
        }
    }
    [out appendData:bindings];
}
static void ktaAttach(id pipeline, NSArray *vertex, NSArray *fragment, NSArray *compute) {
    if (!pipeline) return;
    NSMutableData *bindings = [NSMutableData data];
    ktaStageBindings(vertex, 0, bindings);
    ktaStageBindings(fragment, 1, bindings);
    ktaStageBindings(compute, 2, bindings);
    if (!bindings.length) return;
    objc_setAssociatedObject(pipeline, kKTABindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ktaTracking = YES;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] texture atomics: pipeline with %lu atomic-capable texture(s) at hidden buffer indices\n",
                                           (unsigned long)(bindings.length / sizeof(KTABinding)));
}

static const MTLPipelineOption kKTAReflection = MTLPipelineOptionArgumentInfo;
static ABRenderReflIMP ktaOrigRenderRefl;
static ABRenderOptAsyncIMP ktaOrigRenderOptAsync;
static ABComputeFnReflIMP ktaOrigComputeFnRefl;
static ABComputeDescReflIMP ktaOrigComputeDescRefl;
static ABComputeFnOptAsyncIMP ktaOrigComputeFnOptAsync;
static ABComputeDescOptAsyncIMP ktaOrigComputeDescOptAsync;
static id ktaRenderRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                        MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) RETURNS_RETAINED;
static id ktaRenderRefl(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                        MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) {
    if (!ktaDevice(self)) return ktaOrigRenderRefl(self, _cmd, d, options, reflection, error);
    MTLAutoreleasedRenderPipelineReflection r = nil;
    id pipeline = ktaOrigRenderRefl(self, _cmd, d, options | kKTAReflection, &r, error);
    ktaAttach(pipeline, r.vertexArguments, r.fragmentArguments, nil);
    if (reflection) *reflection = r;
    return pipeline;
}
static void ktaRenderOptAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options,
                              MTLNewRenderPipelineStateWithReflectionCompletionHandler handler) {
    if (!ktaDevice(self)) return ktaOrigRenderOptAsync(self, _cmd, d, options, handler);
    ktaOrigRenderOptAsync(self, _cmd, d, options | kKTAReflection, ^(id<MTLRenderPipelineState> p, MTLRenderPipelineReflection *r, NSError *e) {
        ktaAttach(p, r.vertexArguments, r.fragmentArguments, nil);
        handler(p, r, e);
    });
}
static id ktaComputeFnRefl(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                           MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) RETURNS_RETAINED;
static id ktaComputeFnRefl(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                           MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) {
    if (!ktaDevice(self)) return ktaOrigComputeFnRefl(self, _cmd, f, options, reflection, error);
    MTLAutoreleasedComputePipelineReflection r = nil;
    id pipeline = ktaOrigComputeFnRefl(self, _cmd, f, options | kKTAReflection, &r, error);
    ktaAttach(pipeline, nil, nil, r.arguments);
    if (reflection) *reflection = r;
    return pipeline;
}
static id ktaComputeDescRefl(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                             MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) RETURNS_RETAINED;
static id ktaComputeDescRefl(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                             MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) {
    if (!ktaDevice(self)) return ktaOrigComputeDescRefl(self, _cmd, d, options, reflection, error);
    MTLAutoreleasedComputePipelineReflection r = nil;
    id pipeline = ktaOrigComputeDescRefl(self, _cmd, d, options | kKTAReflection, &r, error);
    ktaAttach(pipeline, nil, nil, r.arguments);
    if (reflection) *reflection = r;
    return pipeline;
}
static void ktaComputeFnOptAsync(id self, SEL _cmd, id<MTLFunction> f, MTLPipelineOption options,
                                 MTLNewComputePipelineStateWithReflectionCompletionHandler handler) {
    if (!ktaDevice(self)) return ktaOrigComputeFnOptAsync(self, _cmd, f, options, handler);
    ktaOrigComputeFnOptAsync(self, _cmd, f, options | kKTAReflection, ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) {
        ktaAttach(p, nil, nil, r.arguments);
        handler(p, r, e);
    });
}
static void ktaComputeDescOptAsync(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options,
                                   MTLNewComputePipelineStateWithReflectionCompletionHandler handler) {
    if (!ktaDevice(self)) return ktaOrigComputeDescOptAsync(self, _cmd, d, options, handler);
    ktaOrigComputeDescOptAsync(self, _cmd, d, options | kKTAReflection, ^(id<MTLComputePipelineState> p, MTLComputePipelineReflection *r, NSError *e) {
        ktaAttach(p, nil, nil, r.arguments);
        handler(p, r, e);
    });
}
#pragma clang diagnostic pop

// What a Kepler encoder has bound, per stage, and its pipeline's hidden bindings.
enum { kKTATextures = 128 };
@interface MTLShimKTAState : NSObject {
  @public
    __strong id buffers[3][31];
    NSUInteger offsets[3][31];
    __strong NSData *bytes[3][31];
    __strong id textures[3][kKTATextures];
    __strong NSData *bindings;
}
@end
@implementation MTLShimKTAState
@end
static MTLShimKTAState *ktaState(__unsafe_unretained id encoder) {
    MTLShimKTAState *s = objc_getAssociatedObject(encoder, kKTAStateKey);
    if (!s) {
        s = [MTLShimKTAState new];
        objc_setAssociatedObject(encoder, kKTAStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}
typedef void (*KTASetTextureIMP)(id, SEL, id, NSUInteger);
typedef void (*KTASetTexturesIMP)(id, SEL, const id __unsafe_unretained *, NSRange);
static ABSetBufferIMP ktaOrigSetBuffer[3];
static ABSetOffsetIMP ktaOrigSetOffset[3];
static ABSetBuffersIMP ktaOrigSetBuffers[3];
static ABSetBytesIMP ktaOrigSetBytes[3];
static KTASetTextureIMP ktaOrigSetTexture[3];
static KTASetTexturesIMP ktaOrigSetTextures[3];
static ABSetPipelineIMP ktaOrigSetRenderPipeline, ktaOrigSetComputePipeline;
static SEL ktaSetBufferSel[3], ktaSetBytesSel[3];
static void ktaRecordBuffer(__unsafe_unretained id encoder, int stage, __unsafe_unretained id buffer, NSUInteger offset, NSUInteger index) {
    if (index >= 31) return;
    MTLShimKTAState *s = ktaState(encoder);
    s->buffers[stage][index] = buffer;
    s->offsets[stage][index] = offset;
    s->bytes[stage][index] = nil;
}
#define KTA_STAGE_HOOKS(name, stage)                                                                                    \
    static void ktaSetBuffer##name(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id buffer, NSUInteger offset, NSUInteger index) {                  \
        if (ktaTracking) ktaRecordBuffer(self, stage, buffer, offset, index);                                            \
        NVO(ktaOrigSetBuffer[stage])(self, _cmd, buffer, offset, index);                                                      \
    }                                                                                                                    \
    static void ktaSetOffset##name(__unsafe_unretained id self, SEL _cmd, NSUInteger offset, NSUInteger index) {                             \
        if (ktaTracking && index < 31) ktaState(self)->offsets[stage][index] = offset;                                   \
        NVO(ktaOrigSetOffset[stage])(self, _cmd, offset, index);                                                              \
    }                                                                                                                    \
    static void ktaSetBuffers##name(__unsafe_unretained id self, SEL _cmd, const id __unsafe_unretained *buffers, const NSUInteger *offsets, \
                                    NSRange range) {                                                                     \
        for (NSUInteger i = 0; ktaTracking && i < range.length; i++)                                                     \
            ktaRecordBuffer(self, stage, buffers[i], offsets[i], range.location + i);                                    \
        NVO(ktaOrigSetBuffers[stage])(self, _cmd, buffers, offsets, range);                                                   \
    }                                                                                                                    \
    static void ktaSetBytes##name(__unsafe_unretained id self, SEL _cmd, const void *bytes, NSUInteger length, NSUInteger index) {           \
        if (ktaTracking && index < 31) {                                                                                 \
            MTLShimKTAState *s = ktaState(self);                                                                         \
            s->buffers[stage][index] = nil;                                                                              \
            s->bytes[stage][index] = length <= 4096 ? [NSData dataWithBytes:bytes length:length] : nil;                   \
        }                                                                                                                \
        NVO(ktaOrigSetBytes[stage])(self, _cmd, bytes, length, index);                                                        \
    }                                                                                                                    \
    static void ktaSetTexture##name(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id texture, NSUInteger index) {                                   \
        if (ktaTracking && index < kKTATextures) ktaState(self)->textures[stage][index] = texture;                       \
        NVO(ktaOrigSetTexture[stage])(self, _cmd, texture, index);                                                            \
    }                                                                                                                    \
    static void ktaSetTextures##name(__unsafe_unretained id self, SEL _cmd, const id __unsafe_unretained *textures, NSRange range) {         \
        MTLShimKTAState *s = ktaTracking ? ktaState(self) : nil;                                                         \
        for (NSUInteger i = 0; s && i < range.length; i++)                                                               \
            if (range.location + i < kKTATextures) s->textures[stage][range.location + i] = textures[i];                 \
        NVO(ktaOrigSetTextures[stage])(self, _cmd, textures, range);                                                          \
    }
KTA_STAGE_HOOKS(Vertex, 0)
KTA_STAGE_HOOKS(Fragment, 1)
KTA_STAGE_HOOKS(Compute, 2)
static void ktaSetRenderPipeline(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id pipeline) {
    if (!ktaTracking) return NVO(ktaOrigSetRenderPipeline)(self, _cmd, pipeline);
    NSData *bindings = objc_getAssociatedObject(pipeline, kKTABindingsKey);
    MTLShimKTAState *s = bindings ? ktaState(self) : objc_getAssociatedObject(self, kKTAStateKey);
    if (s) s->bindings = bindings;
    NVO(ktaOrigSetRenderPipeline)(self, _cmd, pipeline);
}
static void ktaSetComputePipeline(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id pipeline) {
    if (!ktaTracking) return NVO(ktaOrigSetComputePipeline)(self, _cmd, pipeline);
    NSData *bindings = objc_getAssociatedObject(pipeline, kKTABindingsKey);
    MTLShimKTAState *s = bindings ? ktaState(self) : objc_getAssociatedObject(self, kKTAStateKey);
    if (s) s->bindings = bindings;
    NVO(ktaOrigSetComputePipeline)(self, _cmd, pipeline);
}
static BOOL ktaDepthOrStencil(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float: case MTLPixelFormatStencil8:
        case MTLPixelFormatDepth24Unorm_Stencil8: case MTLPixelFormatDepth32Float_Stencil8:
        case MTLPixelFormatX32_Stencil8: case MTLPixelFormatX24_Stencil8: return YES;
        default: return NO;
    }
}
// Binds each atomic-capable texture's buffer at its hidden index (restore NO), or puts back what the app had bound there.
static void ktaBind(__unsafe_unretained id encoder, BOOL restore) {
    if (!ktaTracking) return;
    MTLShimKTAState *s = objc_getAssociatedObject(encoder, kKTAStateKey);
    if (!s || !s->bindings) return;
    const KTABinding *b = s->bindings.bytes;
    id<MTLBuffer> dummy = nil;
    for (NSUInteger k = 0; k < s->bindings.length / sizeof(KTABinding); k++) {
        int st = b[k].stage, h = b[k].hidden;
        if (restore) {
            if (s->buffers[st][h]) NVOR(ktaOrigSetBuffer[st], encoder)(encoder, ktaSetBufferSel[st], s->buffers[st][h], s->offsets[st][h], h);
            else if (s->bytes[st][h]) NVOR(ktaOrigSetBytes[st], encoder)(encoder, ktaSetBytesSel[st], s->bytes[st][h].bytes, s->bytes[st][h].length, h);
            continue;
        }
        if (b[k].texture == kKTADepthMask) {  // item 62: bit n set when texture n has a depth or stencil format
            uint32_t mask[kKTATextures / 32] = {0};
            for (int t = 0; t < kKTATextures; t++)
                if (s->textures[st][t] && ktaDepthOrStencil([(id<MTLTexture>)s->textures[st][t] pixelFormat])) mask[t / 32] |= 1u << (t % 32);
            NVOR(ktaOrigSetBytes[st], encoder)(encoder, ktaSetBytesSel[st], mask, sizeof mask, h);
            continue;
        }
        id<MTLBuffer> buffer = b[k].texture < kKTATextures ? ktaBacking(s->textures[st][b[k].texture]) : nil;  // (beyond: not tracked)
        if (!buffer) {
            if (!dummy) {
                id<MTLDevice> device = [encoder device];
                dummy = ktaDeviceObject(device, kKTADummyKey, ^id {  // zeros: no magic
                    id<MTLBuffer> d = [device newBufferWithLength:256 options:MTLResourceStorageModeManaged];
                    memset(d.contents, 0, 256);
                    [d didModifyRange:NSMakeRange(0, 256)];
                    return d;
                });
            }
            buffer = dummy;
        }
        if (buffer) NVOR(ktaOrigSetBuffer[st], encoder)(encoder, ktaSetBufferSel[st], buffer, 0, h);
    }
}
#define KTA_DRAW(name, params, args)                                                                                    \
    typedef void (*KTADraw##name##IMP) params;                                                                           \
    static KTADraw##name##IMP ktaOrigDraw##name;                                                                         \
    static void ktaDraw##name params {                                                                                  \
        ktaBind(self, NO);                                                                                               \
        NVO(ktaOrigDraw##name) args;                                                                                          \
        ktaBind(self, YES);                                                                                              \
    }
KTA_DRAW(P, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c), (self, _cmd, t, s, c))
KTA_DRAW(PI, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i), (self, _cmd, t, s, c, i))
KTA_DRAW(PIB, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i, NSUInteger b), (self, _cmd, t, s, c, i, b))
KTA_DRAW(PInd, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, __unsafe_unretained id ib, NSUInteger o), (self, _cmd, t, ib, o))
KTA_DRAW(X, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io), (self, _cmd, t, c, it, ib, io))
KTA_DRAW(XI, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, NSUInteger i), (self, _cmd, t, c, it, ib, io, i))
KTA_DRAW(XIB, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi),
         (self, _cmd, t, c, it, ib, io, i, bv, bi))
KTA_DRAW(XInd, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, __unsafe_unretained id indirect, NSUInteger o), (self, _cmd, t, it, ib, io, indirect, o))
KTA_DRAW(DG, (__unsafe_unretained id self, SEL _cmd, MTLSize g, MTLSize t), (self, _cmd, g, t))
KTA_DRAW(DT, (__unsafe_unretained id self, SEL _cmd, MTLSize g, MTLSize t), (self, _cmd, g, t))
KTA_DRAW(DInd, (__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id indirect, NSUInteger o, MTLSize t), (self, _cmd, indirect, o, t))

// 62. Kepler's sampler returns a depth texture's depth in all four channels, (d, d, d, d), and a stencil view's value as
// (s, s, s, s), sampling and reading through texture2d<float> / <uint>, where OpenGL ES wants (d, 0, 0, 1) and (s, 0, 0, 1).
// Metal leaves those channels undefined, and ANGLE puts them right with swizzled views, which it only makes on GPU
// family Mac2 (and this driver's swizzled views come out empty): WebGL's depth texture tests failed in Chrome and
// Firefox (Khronos WebGL 2.0.1: depth texture formats, fboinvalidate unbind_read_*, about 12 pages). In ANGLE's shaders
// (the functions with an ANGLE_angleUniforms argument), the Kepler adapter (NVAIR_DEPTH_CHANNELS) makes each sample or read
// of a texture argument (x, 0, 0, 1) when bit n of a mask at a hidden buffer index is set; the index is the next one
// after item 58's, worked out here from the pipeline's reflection the same way, and before each draw the mask gets a bit
// for each depth or stencil texture bound (item 58's bindings and tracking). MTLSHIM_NV_DEPTH_CHANNELS=0 turns it off.
// Test: n11 on the GTX 770.
static void keplerTextureAtomics(void) {
    static BOOL done;
    static const char *const kDevice = "NVMTLDevice", *const kRender = "NVMTLRenderCommandEncoder_KEPLER_A",
                             *const kCompute = "NVMTLComputeCommandEncoder_KEPLER_COMPUTE_A";
    const char *setting = getenv("MTLSHIM_NV_TEXTURE_ATOMICS");
    if (done || (setting && !strcmp(setting, "0")) || !definesMethod(kDevice, "newTextureWithDescriptor:")) return;
    const char *const stageClass[3] = {kRender, kRender, kCompute};
    const char *const setBuffer[3] = {"setVertexBuffer:offset:atIndex:", "setFragmentBuffer:offset:atIndex:", "setBuffer:offset:atIndex:"};
    const char *const setOffset[3] = {"setVertexBufferOffset:atIndex:", "setFragmentBufferOffset:atIndex:", "setBufferOffset:atIndex:"};
    const char *const setBuffers[3] = {"setVertexBuffers:offsets:withRange:", "setFragmentBuffers:offsets:withRange:", "setBuffers:offsets:withRange:"};
    const char *const setBytes[3] = {"setVertexBytes:length:atIndex:", "setFragmentBytes:length:atIndex:", "setBytes:length:atIndex:"};
    const char *const setTexture[3] = {"setVertexTexture:atIndex:", "setFragmentTexture:atIndex:", "setTexture:atIndex:"};
    const char *const setTextures[3] = {"setVertexTextures:withRange:", "setFragmentTextures:withRange:", "setTextures:withRange:"};
    for (int st = 0; st < 3; st++)
        if (!definesMethod(stageClass[st], setBuffer[st]) || !definesMethod(stageClass[st], setOffset[st]) ||
            !definesMethod(stageClass[st], setBuffers[st]) || !definesMethod(stageClass[st], setBytes[st]) ||
            !definesMethod(stageClass[st], setTexture[st]) || !definesMethod(stageClass[st], setTextures[st]))
            return;  // not the Kepler driver these hooks know
    if (!definesMethod(kRender, "setRenderPipelineState:") || !definesMethod(kCompute, "setComputePipelineState:")) return;
    done = YES;
    const char *depth = getenv("MTLSHIM_NV_DEPTH_CHANNELS");
    ktaDepthChannels = !(depth && !strcmp(depth, "0"));  // item 62 rides on these hooks
    const IMP bufferHooks[3] = {(IMP)ktaSetBufferVertex, (IMP)ktaSetBufferFragment, (IMP)ktaSetBufferCompute};
    const IMP offsetHooks[3] = {(IMP)ktaSetOffsetVertex, (IMP)ktaSetOffsetFragment, (IMP)ktaSetOffsetCompute};
    const IMP buffersHooks[3] = {(IMP)ktaSetBuffersVertex, (IMP)ktaSetBuffersFragment, (IMP)ktaSetBuffersCompute};
    const IMP bytesHooks[3] = {(IMP)ktaSetBytesVertex, (IMP)ktaSetBytesFragment, (IMP)ktaSetBytesCompute};
    const IMP textureHooks[3] = {(IMP)ktaSetTextureVertex, (IMP)ktaSetTextureFragment, (IMP)ktaSetTextureCompute};
    const IMP texturesHooks[3] = {(IMP)ktaSetTexturesVertex, (IMP)ktaSetTexturesFragment, (IMP)ktaSetTexturesCompute};
    for (int st = 0; st < 3; st++) {
        ktaSetBufferSel[st] = sel_registerName(setBuffer[st]);
        ktaSetBytesSel[st] = sel_registerName(setBytes[st]);
        ktaOrigSetBuffer[st] = (ABSetBufferIMP)keplerSwizzle(stageClass[st], setBuffer[st], bufferHooks[st]);
        ktaOrigSetOffset[st] = (ABSetOffsetIMP)keplerSwizzle(stageClass[st], setOffset[st], offsetHooks[st]);
        ktaOrigSetBuffers[st] = (ABSetBuffersIMP)keplerSwizzle(stageClass[st], setBuffers[st], buffersHooks[st]);
        ktaOrigSetBytes[st] = (ABSetBytesIMP)keplerSwizzle(stageClass[st], setBytes[st], bytesHooks[st]);
        ktaOrigSetTexture[st] = (KTASetTextureIMP)keplerSwizzle(stageClass[st], setTexture[st], textureHooks[st]);
        ktaOrigSetTextures[st] = (KTASetTexturesIMP)keplerSwizzle(stageClass[st], setTextures[st], texturesHooks[st]);
    }
    ktaOrigSetRenderPipeline = (ABSetPipelineIMP)keplerSwizzle(kRender, "setRenderPipelineState:", (IMP)ktaSetRenderPipeline);
    ktaOrigSetComputePipeline = (ABSetPipelineIMP)keplerSwizzle(kCompute, "setComputePipelineState:", (IMP)ktaSetComputePipeline);
    const struct { const char *cls, *sel; IMP imp; IMP *orig; } draws[] = {
        {kRender, "drawPrimitives:vertexStart:vertexCount:", (IMP)ktaDrawP, (IMP *)&ktaOrigDrawP},
        {kRender, "drawPrimitives:vertexStart:vertexCount:instanceCount:", (IMP)ktaDrawPI, (IMP *)&ktaOrigDrawPI},
        {kRender, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", (IMP)ktaDrawPIB, (IMP *)&ktaOrigDrawPIB},
        {kRender, "drawPrimitives:indirectBuffer:indirectBufferOffset:", (IMP)ktaDrawPInd, (IMP *)&ktaOrigDrawPInd},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", (IMP)ktaDrawX, (IMP *)&ktaOrigDrawX},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", (IMP)ktaDrawXI, (IMP *)&ktaOrigDrawXI},
        {kRender, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",
         (IMP)ktaDrawXIB, (IMP *)&ktaOrigDrawXIB},
        {kRender, "drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:", (IMP)ktaDrawXInd,
         (IMP *)&ktaOrigDrawXInd},
        {kCompute, "dispatchThreadgroups:threadsPerThreadgroup:", (IMP)ktaDrawDG, (IMP *)&ktaOrigDrawDG},
        {kCompute, "dispatchThreads:threadsPerThreadgroup:", (IMP)ktaDrawDT, (IMP *)&ktaOrigDrawDT},
        {kCompute, "dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:", (IMP)ktaDrawDInd, (IMP *)&ktaOrigDrawDInd},
    };
    for (size_t i = 0; i < sizeof draws / sizeof *draws; i++)
        if (definesMethod(draws[i].cls, draws[i].sel)) *draws[i].orig = keplerSwizzle(draws[i].cls, draws[i].sel, draws[i].imp);
    const struct { const char *sel; IMP imp; IMP *orig; } pipelines[] = {
        {"newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)ktaRenderRefl, (IMP *)&ktaOrigRenderRefl},
        {"newRenderPipelineStateWithDescriptor:options:completionHandler:", (IMP)ktaRenderOptAsync, (IMP *)&ktaOrigRenderOptAsync},
        {"newComputePipelineStateWithFunction:options:reflection:error:", (IMP)ktaComputeFnRefl, (IMP *)&ktaOrigComputeFnRefl},
        {"newComputePipelineStateWithDescriptor:options:reflection:error:", (IMP)ktaComputeDescRefl, (IMP *)&ktaOrigComputeDescRefl},
        {"newComputePipelineStateWithFunction:options:completionHandler:", (IMP)ktaComputeFnOptAsync, (IMP *)&ktaOrigComputeFnOptAsync},
        {"newComputePipelineStateWithDescriptor:options:completionHandler:", (IMP)ktaComputeDescOptAsync, (IMP *)&ktaOrigComputeDescOptAsync},
    };
    for (size_t i = 0; i < sizeof pipelines / sizeof *pipelines; i++)
        if (definesMethod("_MTLDevice", pipelines[i].sel)) *pipelines[i].orig = swizzle("_MTLDevice", pipelines[i].sel, pipelines[i].imp);
    // the variants without reflection go through the ones above (item 47 does this already on a Mac with both drivers)
    if (!ivbArgumentBuffersOn && ktaOrigRenderRefl) {
        swizzle("_MTLDevice", "newRenderPipelineStateWithDescriptor:error:", (IMP)abRender);
        if (ktaOrigRenderOptAsync) swizzle("_MTLDevice", "newRenderPipelineStateWithDescriptor:completionHandler:", (IMP)abRenderAsync);
    }
    if (!ivbArgumentBuffersOn && ktaOrigComputeFnRefl) {
        swizzle("_MTLDevice", "newComputePipelineStateWithFunction:error:", (IMP)abComputeFn);
        if (ktaOrigComputeFnOptAsync) swizzle("_MTLDevice", "newComputePipelineStateWithFunction:completionHandler:", (IMP)abComputeFnAsync);
    }
    ktaOrigNewTexture = (KTANewTextureIMP)swizzle(kDevice, "newTextureWithDescriptor:", (IMP)ktaNewTexture);
    ktaOn = YES;
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] texture atomics on the Kepler GPU: linear textures and hidden bindings installed\n");
}

// 59. Visibility results on the Kepler driver (GeForceMTLDriver): each draw made while a visibility result mode is set
// writes its own sample count (0 included) to the slot, replacing what the slot held, so the slot ends up with the LAST
// draw's count, not the sum over the pass's draws that Metal specifies (two draws, the second outside the scissor or
// behind earlier depth: 0, on a GTX 770). WebGL occlusion queries in Chrome reported visible targets invisible (Khronos
// WebGL 2.0.1 deqp occlusionquery_strict / _conservative: two target draws per query). A render pass with a visibility
// result buffer gets a private buffer of the shim's instead: while a mode is set, every draw gets a slot of its own
// there, and when the encoder ends, a compute pass on the same command buffer writes each app slot the sum of its draws
// (a slot a mode was set on without any draw gets 0, as Apple's GPUs write it; the driver leaves such slots as they were,
// and WebGPU's empty occlusion queries read old values). MTLSHIM_NV_VISIBILITY_SUM=0 turns it off. Test: n08 on the GTX 770.
enum { kVisSlots = 16384 };
static id (*visDriverNewBuffer)(id, SEL, NSUInteger, MTLResourceOptions) RETURNS_RETAINED;  // set by item 60
@interface MTLShimVisState : NSObject {
@public
    id<MTLBuffer> app, slots;
    id commandBuffer;
    MTLVisibilityResultMode mode;
    NSUInteger appOffset, used;
    NSMutableData *records;  // uint32_t pairs: app slot index, draw slot index (~0: no draw, the app slot just gets 0)
    NSMutableIndexSet *touched, *drawn;  // app slots a mode was set on / that got a draw
}
@end
@implementation MTLShimVisState
@end
static const void *const kVisStateKey = &kVisStateKey;
static RenderEncoderIMP visOrigEncoder;
static EndEncodingIMP visOrigEndEncoding;
typedef void (*VisModeIMP)(id, SEL, MTLVisibilityResultMode, NSUInteger);
static VisModeIMP visOrigMode;
static id visRenderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    id<MTLBuffer> app = descriptor.visibilityResultBuffer;
    if (!app) return visOrigEncoder(self, _cmd, descriptor);
    id<MTLDevice> device = ((id<MTLCommandBuffer>)self).device;  // the driver's own method: every slot gets written, no zero fill (item 60)
    id<MTLBuffer> slots = visDriverNewBuffer ? visDriverNewBuffer(device, @selector(newBufferWithLength:options:), kVisSlots * 8, MTLResourceStorageModePrivate)
                                             : [device newBufferWithLength:kVisSlots * 8 options:MTLResourceStorageModePrivate];
    if (!slots) return visOrigEncoder(self, _cmd, descriptor);
    MTLRenderPassDescriptor *redirected = [descriptor copy];
    redirected.visibilityResultBuffer = slots;
    id encoder = visOrigEncoder(self, _cmd, redirected);
    if (encoder) {
        MTLShimVisState *state = [MTLShimVisState new];
        state->app = app;
        state->slots = slots;
        state->commandBuffer = self;
        state->mode = MTLVisibilityResultModeDisabled;
        state->records = [NSMutableData data];
        state->touched = [NSMutableIndexSet indexSet];
        state->drawn = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(encoder, kVisStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}
static void visSetMode(__unsafe_unretained id self, SEL _cmd, MTLVisibilityResultMode mode, NSUInteger offset) {
    MTLShimVisState *state = objc_getAssociatedObject(self, kVisStateKey);
    if (!state) { NVO(visOrigMode)(self, _cmd, mode, offset); return; }
    state->mode = mode;
    state->appOffset = offset;
    if (mode == MTLVisibilityResultModeDisabled) NVO(visOrigMode)(self, _cmd, mode, 0);  // the draws set their slots
    else [state->touched addIndex:offset / 8];
}
static inline void visBeforeDraw(__unsafe_unretained id self) {
    MTLShimVisState *state = objc_getAssociatedObject(self, kVisStateKey);
    if (!state || state->mode == MTLVisibilityResultModeDisabled) return;
    NSUInteger slot = state->used < kVisSlots ? state->used++ : kVisSlots - 1;
    NVO(visOrigMode)(self, @selector(setVisibilityResultMode:offset:), state->mode, slot * 8);
    uint32_t record[2] = {(uint32_t)(state->appOffset / 8), (uint32_t)slot};
    [state->records appendBytes:record length:sizeof record];
    [state->drawn addIndex:state->appOffset / 8];
}
#define VIS_DRAW(name, params, args)                                                                                    \
    typedef void (*VisDraw##name##IMP) params;                                                                           \
    static VisDraw##name##IMP visOrigDraw##name;                                                                         \
    static void visDraw##name params {                                                                                  \
        visBeforeDraw(self);                                                                                             \
        NVO(visOrigDraw##name) args;                                                                                     \
    }
VIS_DRAW(P, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c), (self, _cmd, t, s, c))
VIS_DRAW(PI, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i), (self, _cmd, t, s, c, i))
VIS_DRAW(PIB, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger s, NSUInteger c, NSUInteger i, NSUInteger b), (self, _cmd, t, s, c, i, b))
VIS_DRAW(PInd, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, __unsafe_unretained id ib, NSUInteger o), (self, _cmd, t, ib, o))
VIS_DRAW(X, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io), (self, _cmd, t, c, it, ib, io))
VIS_DRAW(XI, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, NSUInteger i), (self, _cmd, t, c, it, ib, io, i))
VIS_DRAW(XIB, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger c, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, NSUInteger i, NSInteger bv, NSUInteger bi),
         (self, _cmd, t, c, it, ib, io, i, bv, bi))
VIS_DRAW(XInd, (__unsafe_unretained id self, SEL _cmd, NSUInteger t, NSUInteger it, __unsafe_unretained id ib, NSUInteger io, __unsafe_unretained id indirect, NSUInteger o), (self, _cmd, t, it, ib, io, indirect, o))
static NSString *const kVisSumSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    // 64-bit values as uint2 (low, high): app slots first set to 0, then each draw slot added to its app slot
    "kernel void shimVisibilitySum(device const uint2 *slots [[buffer(0)]], device const uint2 *records [[buffer(1)]],\n"
    "                              device uint2 *app [[buffer(2)]], constant uint &count [[buffer(3)]], uint i [[thread_position_in_grid]]) {\n"
    "    if (i != 0) return;\n"
    "    for (uint r = 0; r < count; r++) app[records[r].x] = uint2(0);\n"
    "    for (uint r = 0; r < count; r++) {\n"
    "        if (records[r].y == 0xffffffffu) continue;\n"
    "        uint2 a = app[records[r].x], b = slots[records[r].y];\n"
    "        uint lo = a.x + b.x;\n"
    "        app[records[r].x] = uint2(lo, a.y + b.y + (lo < a.x ? 1u : 0u));\n"
    "    }\n"
    "}\n";
static id<MTLComputePipelineState> visSumPipeline(id<MTLDevice> device) {
    static const void *const kKey = &kKey;
    id<MTLComputePipelineState> pipeline = objc_getAssociatedObject(device, kKey);
    if (pipeline) return pipeline;
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kVisSumSource options:nil error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"shimVisibilitySum"];
    pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
    if (pipeline) objc_setAssociatedObject(device, kKey, pipeline, OBJC_ASSOCIATION_RETAIN);
    else if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] visibility sums: no pipeline (%s)\n", error.localizedDescription.UTF8String);
    return pipeline;
}
static void visEndEncoding(id self, SEL _cmd) {
    MTLShimVisState *state = objc_getAssociatedObject(self, kVisStateKey);
    NVO(visOrigEndEncoding)(self, _cmd);
    if (!state) return;
    objc_setAssociatedObject(self, kVisStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state->touched removeIndexes:state->drawn];
    [state->touched enumerateIndexesUsingBlock:^(NSUInteger appSlot, BOOL *stop) {
        uint32_t record[2] = {(uint32_t)appSlot, 0xffffffffu};
        [state->records appendBytes:record length:sizeof record];
    }];
    uint32_t count = (uint32_t)(state->records.length / 8);
    if (!count) return;
    id<MTLCommandBuffer> commandBuffer = state->commandBuffer;
    id<MTLComputePipelineState> pipeline = visSumPipeline(commandBuffer.device);
    if (!pipeline) return;
    id<MTLBuffer> records = [commandBuffer.device newBufferWithBytes:state->records.bytes length:state->records.length options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:state->slots offset:0 atIndex:0];
    [encoder setBuffer:records offset:0 atIndex:1];
    [encoder setBuffer:state->app offset:0 atIndex:2];
    [encoder setBytes:&count length:sizeof count atIndex:3];
    [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] visibility results: %u draw(s) and empty slot(s) written\n", count);
}
// 60. New private buffers on the Kepler driver aren't zero-filled: a freed private buffer's memory comes back, as it was,
// in the next private buffer of the same size (a 1 MB one read all 0xAB after one filled with 0xAB was released; fresh
// sizes were 0). Metal documents newBufferWithLength:options: as clearing the buffer, and Dawn relies on it instead of
// clearing WebGPU buffers itself: the WebGPU CTS read old values from unused query slots (queries, occlusionQuery
// initial and timestampQuery unused_slots_are_zero), and a buffer could show data another part of the app had freed.
// Every private buffer it makes is filled with zeros by a blit on a queue of the shim's, waited for before it is
// returned (some 0.2-0.3 ms per buffer); so is a new counter sample buffer's result buffer (below). Heap buffers keep
// their undefined contents, as Metal specifies.
// MTLSHIM_NV_ZERO_BUFFERS=0 turns it off. Test: n09 on the GTX 770.
typedef id (*NVNewBufferIMP)(id, SEL, NSUInteger, MTLResourceOptions) RETURNS_RETAINED;
static NVNewBufferIMP origNVNewBuffer;
static id<MTLCommandQueue> zeroQueue(id device) {  // the shim's own queue on the device, for the fills
    static const void *const kQueueKey = &kQueueKey;
    id<MTLCommandQueue> queue;
    @synchronized(device) {
        queue = objc_getAssociatedObject(device, kQueueKey);
        if (!queue) {
            queue = [(id<MTLDevice>)device newCommandQueue];
            if (queue) objc_setAssociatedObject(device, kQueueKey, queue, OBJC_ASSOCIATION_RETAIN);
        }
    }
    return queue;
}
static void zeroFill(id<MTLCommandQueue> queue, id<MTLBuffer> buffer, NSUInteger length) {  // waited for
    NSUInteger size = MIN((length + 3) & ~(NSUInteger)3, MAX(buffer.allocatedSize, length));
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit fillBuffer:buffer range:NSMakeRange(0, size & ~(NSUInteger)3) value:0];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}
static id nvNewBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) RETURNS_RETAINED;
static id nvNewBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) {
    id<MTLBuffer> buffer = origNVNewBuffer(self, _cmd, length, options);
    if (!buffer || !length || (options & MTLResourceStorageModeMask) != MTLResourceStorageModePrivate) return buffer;
    id<MTLCommandQueue> queue = zeroQueue(self);
    if (!queue) return buffer;
    zeroFill(queue, buffer, length);
    return buffer;
}
// Counter sample buffers keep their samples in a private buffer the driver allocates itself (counterResultBuffer), and a
// freed one's samples came back in the next one: unsampled slots resolved to old timestamps (Metal: an error value;
// fresh ones here: 0), and the WebGPU CTS read them from unused timestamp query slots (unused_slots_are_zero).
typedef id (*NVNewCounterBufferIMP)(id, SEL, id, NSError **) RETURNS_RETAINED;
static NVNewCounterBufferIMP origNVNewCounterBuffer;
static id nvNewCounterBuffer(id self, SEL _cmd, id descriptor, NSError **error) RETURNS_RETAINED;
static id nvNewCounterBuffer(id self, SEL _cmd, id descriptor, NSError **error) {
    id sampleBuffer = origNVNewCounterBuffer(self, _cmd, descriptor, error);
    SEL resultSel = sel_registerName("counterResultBuffer");
    if (!sampleBuffer || ![sampleBuffer respondsToSelector:resultSel]) return sampleBuffer;
    id<MTLBuffer> results = ((id (*)(id, SEL))objc_msgSend)(sampleBuffer, resultSel);
    id<MTLCommandQueue> queue = zeroQueue(self);
    if (results && queue) zeroFill(queue, results, results.length);
    return sampleBuffer;
}
static void keplerZeroBuffers(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_NV_ZERO_BUFFERS");
    if (done || (setting && !strcmp(setting, "0")) || !definesMethod("NVMTLDevice", "newBufferWithLength:options:")) return;
    done = YES;
    origNVNewBuffer = (NVNewBufferIMP)swizzle("NVMTLDevice", "newBufferWithLength:options:", (IMP)nvNewBuffer);
    visDriverNewBuffer = origNVNewBuffer;
    if (definesMethod("NVMTLDevice", "newCounterSampleBufferWithDescriptor:error:"))
        origNVNewCounterBuffer = (NVNewCounterBufferIMP)swizzle("NVMTLDevice", "newCounterSampleBufferWithDescriptor:error:", (IMP)nvNewCounterBuffer);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Kepler private buffers: zero-filled at creation\n");
}
// 61. The Kepler driver's -resolveCounters:inRange:destinationBuffer:destinationOffset: reads the samples from the sample
// buffer's own result buffer (counterResultBuffer, 16 bytes a sample) but leaves it out of the command buffer's resources,
// so nothing makes it resident: when its pages aren't mapped the GPU faults (kernel log: "Access Violation Error (MMU
// Error 2)", FAULT_PTE) and the driver kills the context, failing the next command buffer with
// kIOAccelCommandBufferCallbackErrorInvalidResource. WebGPU's resolveQuerySet of timestamp queries hit it in Chrome
// (device lost in the CTS's timestampQuery resolve_unused_slots); whether a process faults depends on its allocations.
// Each resolve first copies 4 bytes of the result buffer to a small buffer of the shim's in the same encoder, which puts
// the result buffer in the command buffer's resources. MTLSHIM_NV_RESOLVE_RESIDENCY=0 turns it off.
typedef void (*NVResolveCountersIMP)(id, SEL, id, NSRange, id, NSUInteger);
static NVResolveCountersIMP origNVResolveCounters;
static void nvResolveCounters(id self, SEL _cmd, id sampleBuffer, NSRange range, id destination, NSUInteger offset) {
    SEL resultSel = sel_registerName("counterResultBuffer");
    if ([sampleBuffer respondsToSelector:resultSel]) {
        id<MTLBuffer> results = ((id (*)(id, SEL))objc_msgSend)(sampleBuffer, resultSel);
        id<MTLDevice> device = results.device;
        static const void *const kScratchKey = &kScratchKey;
        id<MTLBuffer> scratch = nil;
        if (device) @synchronized(device) {
            scratch = objc_getAssociatedObject(device, kScratchKey);
            if (!scratch) {
                scratch = [device newBufferWithLength:16 options:MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked];
                if (scratch) objc_setAssociatedObject(device, kScratchKey, scratch, OBJC_ASSOCIATION_RETAIN);
            }
        }
        if (results.length >= 4 && scratch)
            [(id<MTLBlitCommandEncoder>)self copyFromBuffer:results sourceOffset:0 toBuffer:scratch destinationOffset:0 size:4];
    }
    NVO(origNVResolveCounters)(self, _cmd, sampleBuffer, range, destination, offset);
}
static void keplerResolveResidency(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_NV_RESOLVE_RESIDENCY");
    static const char *const kClass = "NVMTLBlitCommandEncoder_KEPLER_A", *const kSel = "resolveCounters:inRange:destinationBuffer:destinationOffset:";
    if (done || (setting && !strcmp(setting, "0")) || !definesMethod(kClass, kSel)) return;
    done = YES;
    origNVResolveCounters = (NVResolveCountersIMP)keplerSwizzle(kClass, kSel, (IMP)nvResolveCounters);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Kepler counter resolves: result buffer made resident\n");
}

// Item 69's other half. The driver keeps drawing inside the viewport only through that tight guard band: the pixel clip
// rectangle it gives the GPU (VIEWPORT_HORIZ / VERT, methods 0xc00 / 0xc04) is the render target, not the viewport (nouveau
// sets it to the viewport). With the guard band widened, a triangle or wide point reaching past a viewport smaller than
// the target drew outside the viewport (a full-screen triangle through an 8x8 viewport in a 16x16 target: 44 pixels
// outside). So the scissor rectangles the driver gets are the app's (none: unbounded) intersected with the viewports',
// the pixels whose centers are inside; a fragment outside its viewport is scissored as clipping would have removed it.
typedef struct {
    MTLViewport viewports[16];
    MTLScissorRect scissors[16];
    NSUInteger viewportCount, scissorCount;  // 0: not set by the app
} NVClipState;
typedef void (*ClipSetViewportIMP)(id, SEL, MTLViewport);
typedef void (*ClipSetViewportsIMP)(id, SEL, const MTLViewport *, NSUInteger);
typedef void (*ClipSetScissorIMP)(id, SEL, MTLScissorRect);
typedef void (*ClipSetScissorsIMP)(id, SEL, const MTLScissorRect *, NSUInteger);
static ClipSetViewportIMP origClipSetViewport;
static ClipSetViewportsIMP origClipSetViewports;
static ClipSetScissorIMP origClipSetScissor;
static ClipSetScissorsIMP origClipSetScissors;
static NVClipState *nvClipState(__unsafe_unretained id encoder) {
    static const void *const kKey = &kKey;
    NSMutableData *data = objc_getAssociatedObject(encoder, kKey);
    if (!data) {
        data = [NSMutableData dataWithLength:sizeof(NVClipState)];
        objc_setAssociatedObject(encoder, kKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return data.mutableBytes;
}
static void nvClipSpan(double origin, double size, NSUInteger *lo, NSUInteger *hi) {  // the pixels whose centers are inside
    double a = ceil(origin - 0.5), b = ceil(origin + size - 0.5);
    a = fmin(fmax(a, 0), 16384), b = fmin(fmax(b, a), 16384);
    *lo = (NSUInteger)a, *hi = (NSUInteger)b;
}
static void nvClipApply(__unsafe_unretained id self, const NVClipState *st) {
    MTLScissorRect out[16];
    NSUInteger n = st->viewportCount;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger x0, x1, y0, y1;
        nvClipSpan(st->viewports[i].originX, st->viewports[i].width, &x0, &x1);
        nvClipSpan(st->viewports[i].originY, st->viewports[i].height, &y0, &y1);
        if (st->scissorCount) {  // a single app rectangle serves every viewport, as the driver repeats slot 0
            MTLScissorRect r = st->scissors[i < st->scissorCount ? i : st->scissorCount - 1];
            x0 = MAX(x0, r.x), y0 = MAX(y0, r.y), x1 = MIN(x1, r.x + r.width), y1 = MIN(y1, r.y + r.height);
        }
        out[i] = (MTLScissorRect){x0, y0, x1 > x0 ? x1 - x0 : 0, y1 > y0 ? y1 - y0 : 0};
    }
    if (n == 1) NVO(origClipSetScissor)(self, @selector(setScissorRect:), out[0]);
    else if (n > 1) NVO(origClipSetScissors)(self, @selector(setScissorRects:count:), out, n);
}
static void clipSetViewport(__unsafe_unretained id self, SEL _cmd, MTLViewport viewport) {
    NVO(origClipSetViewport)(self, _cmd, viewport);
    NVClipState *st = nvClipState(self);
    st->viewports[0] = viewport, st->viewportCount = 1;
    nvClipApply(self, st);
}
static void clipSetViewports(__unsafe_unretained id self, SEL _cmd, const MTLViewport *viewports, NSUInteger count) {
    NVO(origClipSetViewports)(self, _cmd, viewports, count);
    if (!viewports || !count) return;
    NVClipState *st = nvClipState(self);
    st->viewportCount = MIN(count, (NSUInteger)16);
    memcpy(st->viewports, viewports, st->viewportCount * sizeof *viewports);
    nvClipApply(self, st);
}
static void clipSetScissor(__unsafe_unretained id self, SEL _cmd, MTLScissorRect rect) {
    NVClipState *st = nvClipState(self);
    st->scissors[0] = rect, st->scissorCount = 1;
    if (st->viewportCount) nvClipApply(self, st);
    else NVO(origClipSetScissor)(self, _cmd, rect);
}
static void clipSetScissors(__unsafe_unretained id self, SEL _cmd, const MTLScissorRect *rects, NSUInteger count) {
    NVClipState *st = nvClipState(self);
    if (rects && count) {
        st->scissorCount = MIN(count, (NSUInteger)16);
        memcpy(st->scissors, rects, st->scissorCount * sizeof *rects);
    }
    if (st->viewportCount && rects && count) nvClipApply(self, st);
    else NVO(origClipSetScissors)(self, _cmd, rects, count);
}

// 69. Triangles across the edge of the viewport on the Kepler driver. The driver sets SET_VIEWPORT_CLIP_CONTROL (method
// 0x193c) to 0x49d with its depth clip mode's bits (0xc9d before a viewport is set), and bit 7 of that makes the
// geometry guard band the viewport itself: a triangle that crosses the viewport's edge is clipped to it, and the
// polygon left is drawn as a fan of triangles. With multisampling, a pixel on a seam of the fan runs the fragment
// function once for each part, each time with only that part's samples in [[sample_mask]] (WebGPU CTS fragment_builtins
// inputs,sample_mask: 7 then 8 for a pixel with all 4 samples covered, every case with an edge of the triangle inside
// the target), and a fragment function's writes to buffers and atomics happen twice there (the usual full-screen
// triangle at 4x: 20 runs for 16 pixels). With bit 7 clear the guard band is 256 times the viewport, as nouveau has it
// on this hardware: such triangles are rasterized whole, and clipped only beyond it. Depth clipping doesn't depend on
// it (still done for each triangle that crosses the near or far plane). The value is an immediate in the driver's code,
// the same instruction pair in 10 places for each of the two; those 20 bytes are patched once the driver is in, if all
// 20 are there. MTLSHIM_NV_GUARD_BAND=0 turns it off.
// Bit 10 does the same for the line and point cull guard band: a point whose center was outside the viewport was culled,
// with the part of a wide point that's inside (Khronos WebGL clipping-wide-points: 8-pixel points centered just past an
// edge drew nothing; nouveau leaves it clear too). It's cleared in the same immediates; MTLSHIM_NV_POINT_GUARD_BAND=0
// keeps it.
static void keplerGuardBand(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_NV_GUARD_BAND"), *pointSetting = getenv("MTLSHIM_NV_POINT_GUARD_BAND");
    BOOL geometry = !(setting && !strcmp(setting, "0")), points = !(pointSetting && !strcmp(pointSetting, "0"));
    Class device = objc_getClass("NVMTLDevice");
    Dl_info info;
    static const char *const kRender = "NVMTLRenderCommandEncoder_KEPLER_A";
    if (done || (!geometry && !points) || !device || !dladdr((__bridge const void *)device, &info) ||
        !strstr(info.dli_fname, "/GeForceMTLDriver.bundle/") || !definesMethod(kRender, "setViewport:") ||
        !definesMethod(kRender, "setViewports:count:") || !definesMethod(kRender, "setScissorRect:") ||
        !definesMethod(kRender, "setScissorRects:count:"))
        return;  // without the scissor half the wider guard bands would draw outside smaller viewports
    done = YES;
    unsigned long size = 0;
    unsigned char *text = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__TEXT", "__text", &size);
    // movl $0x49d, %eax; orl 0xad0(%rdi), %eax  /  movl $0xc9d, %eax; movq 0x20(%rdi), %r8
    static const unsigned char kViewport[7] = {0xb8, 0x9d, 0x04, 0x00, 0x00, 0x0b, 0x87}, kDefault[7] = {0xb8, 0x9d, 0x0c, 0x00, 0x00, 0x4c, 0x8b};
    unsigned char *sites[20];
    int viewport = 0, fallback = 0;
    for (unsigned long i = 0; text && i + sizeof kViewport <= size; i++) {
        BOOL v = !memcmp(text + i, kViewport, sizeof kViewport), d = !v && !memcmp(text + i, kDefault, sizeof kDefault);
        if (!v && !d) continue;
        if (viewport + fallback == 20) return;  // more than the driver builds we know: leave it
        sites[viewport + fallback] = text + i;
        v ? viewport++ : fallback++;
    }
    if (viewport != 10 || fallback != 10) return;
    int patched = 0;
    for (int i = 0; i < 20; i++) {
        vm_address_t page = (vm_address_t)(sites[i] + 1) & ~(vm_address_t)(vm_page_size - 1);
        if (vm_protect(mach_task_self(), page, vm_page_size * 2, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
        if (geometry) sites[i][1] &= (unsigned char)~0x80;  // 0x49d -> 0x41d, 0xc9d -> 0xc1d
        if (points) sites[i][2] &= (unsigned char)~0x04;    // and -> 0x01d, 0x81d
        vm_protect(mach_task_self(), page, vm_page_size * 2, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        patched++;
    }
    const char *scissor = getenv("MTLSHIM_NV_VIEWPORT_SCISSOR");  // =0 only to see what the scissor half prevents
    if (patched && !(scissor && !strcmp(scissor, "0"))) {
        origClipSetViewport = (ClipSetViewportIMP)keplerSwizzle(kRender, "setViewport:", (IMP)clipSetViewport);
        origClipSetViewports = (ClipSetViewportsIMP)keplerSwizzle(kRender, "setViewports:count:", (IMP)clipSetViewports);
        origClipSetScissor = (ClipSetScissorIMP)keplerSwizzle(kRender, "setScissorRect:", (IMP)clipSetScissor);
        origClipSetScissors = (ClipSetScissorsIMP)keplerSwizzle(kRender, "setScissorRects:count:", (IMP)clipSetScissors);
    }
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Kepler guard band: viewport clip control patched at %d of 20 places\n", patched);
}

// 70. Reversed viewport depth ranges on the Kepler driver. Its setViewport: and setViewports:count: keep each viewport's
// transform as six floats in the encoder's state (scale x, y, z and translate x, y, z, 0x18 bytes apart from 0x950),
// which the next draw sends to the GPU, and take z as scale |zfar - znear| and translate min(znear, zfar): a viewport
// with znear above zfar, which Metal allows ("which you can flip", in setViewport:'s documentation) and MoltenVK passes
// on from Vulkan, wasn't reversed (znear 1, zfar 0 stored a z of 0.25 as 0.25, not 0.75). After the driver's setter,
// such a viewport's z scale becomes zfar - znear and its translate znear. The state is the driver's own ivar, at the
// offset its setter reads first; both setters' code is checked for the stores this relies on. Depth clamping (to
// [0, 1] on this driver) is unchanged. MTLSHIM_NV_REVERSED_DEPTH=0 turns it off.
typedef void (*NVSetViewportIMP)(id, SEL, MTLViewport);
typedef void (*NVSetViewportsIMP)(id, SEL, const MTLViewport *, NSUInteger);
static NVSetViewportIMP origNVSetViewport;
static NVSetViewportsIMP origNVSetViewports;
static ptrdiff_t nvRenderStateOffset = -1, nvRenderStateOffsetB = -1;  // _KEPLER_A, _KEPLER_B
static void nvReverseDepth(id self, const MTLViewport *viewports, NSUInteger count) {
    ptrdiff_t offset = nvIsKeplerB(self) ? nvRenderStateOffsetB : nvRenderStateOffset;
    if (offset < 0) return;
    char *state = *(char **)((char *)(__bridge void *)self + offset);
    for (NSUInteger i = 0; state && viewports && i < count && i < 16; i++)
        if (viewports[i].znear > viewports[i].zfar) {
            float *transform = (float *)(state + 0x950 + 0x18 * i);
            transform[2] = (float)(viewports[i].zfar - viewports[i].znear);
            transform[5] = (float)viewports[i].znear;
        }
}
static void nvSetViewport(id self, SEL _cmd, MTLViewport viewport) {
    NVO(origNVSetViewport)(self, _cmd, viewport);
    nvReverseDepth(self, &viewport, 1);
}
static void nvSetViewports(id self, SEL _cmd, const MTLViewport *viewports, NSUInteger count) {
    NVO(origNVSetViewports)(self, _cmd, viewports, count);
    nvReverseDepth(self, viewports, count);
}
// The ivar offset a Kepler setter loads first (push rbp; mov rbp, rsp; mov disp(%rip), %rax; mov (%rdi,%rax), %rax), if
// its first `length` bytes also hold every one of `stores`; -1 otherwise
static ptrdiff_t nvSetterStateOffset(const char *cls, const char *sel, size_t length, const unsigned char (*stores)[9], int storeCount) {
    Method m = class_getInstanceMethod(objc_getClass(cls), sel_registerName(sel));
    const unsigned char *code = m ? (const unsigned char *)method_getImplementation(m) : NULL;
    Dl_info info;
    static const unsigned char kHead[7] = {0x55, 0x48, 0x89, 0xe5, 0x48, 0x8b, 0x05}, kLoad[4] = {0x48, 0x8b, 0x04, 0x07};
    if (!code || !dladdr(code, &info) || !strstr(info.dli_fname, "/GeForceMTLDriver.bundle/") || memcmp(code, kHead, 7) ||
        memcmp(code + 11, kLoad, 4))
        return -1;
    for (int s = 0; s < storeCount; s++) {
        BOOL found = NO;
        for (size_t i = 15; !found && i + 9 <= length; i++) found = !memcmp(code + i, stores[s], 9);
        if (!found) return -1;
    }
    int32_t displacement;
    memcpy(&displacement, code + 7, 4);
    return *(const ptrdiff_t *)(code + 11 + displacement);
}
static void keplerReversedDepth(void) {
    static BOOL done;
    static const char *const kClass = "NVMTLRenderCommandEncoder_KEPLER_A";
    const char *setting = getenv("MTLSHIM_NV_REVERSED_DEPTH");
    if (done || (setting && !strcmp(setting, "0")) || !definesMethod(kClass, "setViewport:") || !definesMethod(kClass, "setViewports:count:"))
        return;
    done = YES;
    // movupd %xmm0, 0x950(%rax) / movss %xmm1, 0x964(%rax) (padded to 9 with the next instruction's first byte), and the
    // array forms movupd %xmm2, 0x950(%rax,%rdi) / movss %xmm0, 0x964(%rax,%rdi)
    static const unsigned char kOne[2][9] = {{0x66, 0x0f, 0x11, 0x80, 0x50, 0x09, 0x00, 0x00, 0xf3}, {0xf3, 0x0f, 0x11, 0x88, 0x64, 0x09, 0x00, 0x00, 0xc6}};
    static const unsigned char kMany[2][9] = {{0x66, 0x0f, 0x11, 0x94, 0x38, 0x50, 0x09, 0x00, 0x00}, {0xf3, 0x0f, 0x11, 0x84, 0x38, 0x64, 0x09, 0x00, 0x00}};
    ptrdiff_t one = nvSetterStateOffset(kClass, "setViewport:", 0xb7, kOne, 2), many = nvSetterStateOffset(kClass, "setViewports:count:", 0xe8, kMany, 2);
    if (one < 0 || one != many) return;
    nvRenderStateOffset = one;
    static const char *const kClassB = "NVMTLRenderCommandEncoder_KEPLER_B";  // checked the same way; its setters are left as they are if not
    ptrdiff_t oneB = nvSetterStateOffset(kClassB, "setViewport:", 0xb7, kOne, 2), manyB = nvSetterStateOffset(kClassB, "setViewports:count:", 0xe8, kMany, 2);
    if (oneB >= 0 && oneB == manyB) nvRenderStateOffsetB = oneB;
    origNVSetViewport = (NVSetViewportIMP)keplerSwizzle(kClass, "setViewport:", (IMP)nvSetViewport);
    origNVSetViewports = (NVSetViewportsIMP)keplerSwizzle(kClass, "setViewports:count:", (IMP)nvSetViewports);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Kepler reversed viewport depth ranges: setters wrapped\n");
}

// 71. Sample positions of Kepler's 2x and 8x patterns. The hardware uses the standard positions, but in another order
// than the one Metal reports (getDefaultSamplePositions:count:, which only MetalOld's _MTLDevice defines): at 2x samples
// 0 and 1 are swapped, at 8x sample 0 is at (0.0625, 0.4375), which Metal gave as sample 5's, and so on (4x is right). So
// anything that matches sample indices to positions (a custom resolve, a per-sample technique) got the wrong sample.
// NVMTLDevice gets its own getDefaultSamplePositions:count:, with the order measured on a GTX 770 for 2 and 8 samples
// (n22) and MetalOld's for any other count. MTLSHIM_NV_SAMPLE_POSITIONS=0 turns it off.
typedef void (*SamplePositionsIMP)(id, SEL, MTLSamplePosition *, NSUInteger);
static SamplePositionsIMP origSamplePositions;
static void nvSamplePositions(id self, SEL _cmd, MTLSamplePosition *positions, NSUInteger count) {
    static const MTLSamplePosition k2[2] = {{0.25f, 0.25f}, {0.75f, 0.75f}};
    static const MTLSamplePosition k8[8] = {{0.0625f, 0.4375f}, {0.3125f, 0.1875f}, {0.1875f, 0.8125f}, {0.4375f, 0.6875f},
                                            {0.5625f, 0.3125f}, {0.9375f, 0.0625f}, {0.6875f, 0.9375f}, {0.8125f, 0.5625f}};
    if (positions && count == 2) memcpy(positions, k2, sizeof k2);
    else if (positions && count == 8) memcpy(positions, k8, sizeof k8);
    else origSamplePositions(self, _cmd, positions, count);
}
static void keplerSamplePositions(void) {
    static BOOL done;
    const char *setting = getenv("MTLSHIM_NV_SAMPLE_POSITIONS");
    Class device = objc_getClass("NVMTLDevice");
    SEL sel = sel_registerName("getDefaultSamplePositions:count:");
    Method inherited = device ? class_getInstanceMethod(device, sel) : NULL;
    if (done || (setting && !strcmp(setting, "0")) || !inherited || definesMethod("NVMTLDevice", "getDefaultSamplePositions:count:") ||
        !definesMethod("NVMTLRenderCommandEncoder_KEPLER_A", "setViewport:"))
        return;
    done = YES;
    origSamplePositions = (SamplePositionsIMP)method_getImplementation(inherited);
    if (class_addMethod(device, sel, (IMP)nvSamplePositions, method_getTypeEncoding(inherited)) && getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] Kepler 2x / 8x sample positions: reported in the hardware's order\n");
}
static void keplerVisibilitySums(void) {
    static BOOL done;
    static const char *const kBuffer = "NVMTLCommandBuffer", *const kRender = "NVMTLRenderCommandEncoder_KEPLER_A";
    const char *setting = getenv("MTLSHIM_NV_VISIBILITY_SUM");
    if (done || (setting && !strcmp(setting, "0")) || !definesMethod(kBuffer, "renderCommandEncoderWithDescriptor:") ||
        !definesMethod(kRender, "endEncoding") || !definesMethod(kRender, "setVisibilityResultMode:offset:"))
        return;
    done = YES;
    struct { const char *sel; IMP hook; IMP *orig; } draws[] = {
        {"drawPrimitives:vertexStart:vertexCount:", (IMP)visDrawP, (IMP *)&visOrigDrawP},
        {"drawPrimitives:vertexStart:vertexCount:instanceCount:", (IMP)visDrawPI, (IMP *)&visOrigDrawPI},
        {"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", (IMP)visDrawPIB, (IMP *)&visOrigDrawPIB},
        {"drawPrimitives:indirectBuffer:indirectBufferOffset:", (IMP)visDrawPInd, (IMP *)&visOrigDrawPInd},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", (IMP)visDrawX, (IMP *)&visOrigDrawX},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", (IMP)visDrawXI, (IMP *)&visOrigDrawXI},
        {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", (IMP)visDrawXIB, (IMP *)&visOrigDrawXIB},
        {"drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:", (IMP)visDrawXInd, (IMP *)&visOrigDrawXInd},
    };
    for (unsigned i = 0; i < sizeof draws / sizeof *draws; i++)
        if (definesMethod(kRender, draws[i].sel)) *draws[i].orig = keplerSwizzle(kRender, draws[i].sel, draws[i].hook);
    visOrigMode = (VisModeIMP)keplerSwizzle(kRender, "setVisibilityResultMode:offset:", (IMP)visSetMode);
    visOrigEndEncoding = (EndEncodingIMP)keplerSwizzle(kRender, "endEncoding", (IMP)visEndEncoding);
    visOrigEncoder = (RenderEncoderIMP)swizzle(kBuffer, "renderCommandEncoderWithDescriptor:", (IMP)visRenderEncoder);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Kepler visibility results: per-draw slots summed at the end of each pass\n");
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
    if (patched) ivbDrawParameters();  // item 48, under item 47's draw hooks
    if (patched) installIvbArgumentBuffers();  // item 47: once the driver's classes are loaded
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!origIGRenderEncoder && definesMethod("MTLIGAccelCommandBuffer", "renderCommandEncoderWithDescriptor:") &&
        definesMethod("MTLIGAccelRenderCommandEncoder", "endEncoding")) {
        const char *touch = getenv("MTLSHIM_MSAA_DEPTH_RESOLVE"), *image = class_getImageName(objc_getClass("MTLIGAccelRenderCommandEncoder"));
        ivbDepthTouch = image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(touch && !strcmp(touch, "0"));  // item 50
        const char *withDepth = getenv("MTLSHIM_STENCIL_WITH_DEPTH");  // item 51
        if (image && strstr(image, "/AppleIntelHD4000GraphicsMTLDriver.bundle/") && !(withDepth && !strcmp(withDepth, "0")) &&
            definesMethod("MTLIGAccelDevice", "newDepthStencilStateWithDescriptor:") &&
            definesMethod("MTLIGAccelRenderCommandEncoder", "setDepthStencilState:")) {
            origIGNewDepthStencilState = (NewDepthStencilStateIMP)swizzle("MTLIGAccelDevice", "newDepthStencilStateWithDescriptor:", (IMP)igNewDepthStencilState);
            origIGSetDepthStencilState = (SetDepthStencilStateIMP)swizzle("MTLIGAccelRenderCommandEncoder", "setDepthStencilState:", (IMP)igSetDepthStencilState);
            ivbStencilWithDepth = origIGNewDepthStencilState && origIGSetDepthStencilState;
        }
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
    keplerMissingMethods();  // item 54
    keplerResolveLevels();  // item 55
    keplerViewsOfViews();  // item 56
    keplerTextureAtomics();  // item 58
    keplerVisibilitySums();  // item 59
    keplerZeroBuffers();  // item 60
    keplerResolveResidency();  // item 61
    keplerReversedDepth();  // item 70, before item 69's viewport hooks: it checks the driver's own setters
    keplerGuardBand();  // item 69
    keplerSamplePositions();  // item 71
    mpsStatisticsWidth();
    stencilCopies();
    nvStencilUploadOrder();  // item 53
    nvVolumeCopies();  // item 65, after item 53
    stencilViewAlignment();
    computeSamplerCompare();
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

// ANGLE's callers: a Chromium framework image ("<Product> Framework"), WebKit's libANGLE-shared.dylib / WebGPU.framework
// and WebCore / WebKit, which pick the device they hand to ANGLE (MTLCreateSystemDefaultDevice: the Intel iGPU under
// automatic graphics switching, and ANGLE can't run WebGL on family 1), or ANGLE's own libGLESv2.dylib (Firefox's
// WebGL, which failed with FEATURE_FAILURE_NO_DISPLAY on these Macs).
static BOOL fromChromium(const void *returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return NO;
    const char *base = strrchr(info.dli_fname, '/');
    base = base ? base + 1 : info.dli_fname;
    size_t n = strlen(base);
    if (!strcmp(base, "libANGLE-shared.dylib") || !strcmp(base, "WebGPU") || !strcmp(base, "WebCore") || !strcmp(base, "WebKit"))
        return YES;  // WebKit's ANGLE, WebGPU and the WebKit frameworks that choose their GPU
    if (!strcmp(base, "libGLESv2.dylib"))
        return YES;  // ANGLE's own build: Firefox's WebGL (Firefox.app/Contents/MacOS), apps that bundle ANGLE
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

// Test only: MTLSHIM_TEST_IGPU_ONLY=1 makes a Mac with an AMD or NVIDIA card look, to ANGLE's and Dawn's callers, like one
// whose only GPU is the Intel one: they get the iGPU, as family 2 (item 11), so the Intel path of Chromium and WebKit can
// be tested on a dual-GPU Mac too (Chromium runs on the Iris Pro on a MacBookPro11,3, but on the R9 on a MacBookPro11,5).
// Off by default.
static BOOL testIGPUOnly(void) {
    static int state = -1;
    if (state < 0) state = getenv("MTLSHIM_TEST_IGPU_ONLY") && strcmp(getenv("MTLSHIM_TEST_IGPU_ONLY"), "0");
    return state;
}

static CFArrayRef familyTwoOnly(CFArrayRef all) {  // consumes all; unchanged if no device qualifies (with MTLSHIM_TEST_IGPU_ONLY: the others)
    if (!all) return all;
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++)
        if (familyTwo(CFArrayGetValueAtIndex(all, i)) != testIGPUOnly()) CFArrayAppendValue(out, CFArrayGetValueAtIndex(all, i));
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
    if (testIGPUOnly()) return NO;
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
        // disableMetalOnNvidia: ANGLE turns its Metal display off on NVIDIA GPUs (upstream had none to test on), and on this
        // stack there is no other backend for WebGL in Firefox and Safari; Kepler (GTX 770) passes s63 and s64 with it off.
        // ANGLE only reads it for NVIDIA GPUs.
        // allowRenderpassWithoutAttachment only when item 73 is off: with it, passes and pipelines without attachments get
        // a dummy target, and ANGLE needs them for WEBGL_shader_pixel_local_storage (Chrome 158 offers it; its planes are
        // read_write textures here, so a PLS draw has no attachment, and ANGLE refused the pipeline and lost the context).
        static const char kLacking[] = "hasTextureSwizzle:hasStencilAutoResolve:allowSamplerCompareGradient:disableMetalOnNvidia";
        const char *attachments = getenv("MTLSHIM_NO_ATTACHMENTS");
        BOOL emulated = !(attachments && !strcmp(attachments, "0"));
        const char *set = getenv("ANGLE_FEATURE_OVERRIDES_DISABLED");
        char *value = NULL;
        if (asprintf(&value, "%s%s%s%s", set && *set ? set : "", set && *set ? ":" : "", kLacking,
                     emulated ? "" : ":allowRenderpassWithoutAttachment") < 0)
            value = NULL;
        setenv("ANGLE_FEATURE_OVERRIDES_DISABLED", value ? value : kLacking, 1);
        free(value);
        if (getenv("MTLSHIM_VERBOSE"))
            shimLog("[mtlshim] ANGLE on a family-1 GPU: ANGLE_FEATURE_OVERRIDES_DISABLED=%s\n", getenv("ANGLE_FEATURE_OVERRIDES_DISABLED"));
    });
}

// Item 11: WebKit's ANGLE gets its MTLSharedEvent fences (hasEvents) back on NVIDIA; Safari's WebGL needs GL_ARB_sync.
// ANGLE reads ANGLE_FEATURE_OVERRIDES_ENABLED when a display sets up its features (WebKit's build at every display, other
// builds may read it once), and WebCore asks supportsFamily:Mac2 before each display, so it's set before the first one.
static void enableEventsForWebKit(const void *returnAddress) {
    static dispatch_once_t once;
    const char *image = callerImage(returnAddress);
    if (strcmp(image, "libANGLE-shared.dylib") && strcmp(image, "WebCore") && strcmp(image, "WebKit")) return;
    dispatch_once(&once, ^{
        const char *setting = getenv("MTLSHIM_ANGLE_EVENTS");
        if (setting && !strcmp(setting, "0")) return;
        const char *set = getenv("ANGLE_FEATURE_OVERRIDES_ENABLED");
        char *value = NULL;
        if (set && *set && asprintf(&value, "%s:hasEvents", set) < 0) value = NULL;
        setenv("ANGLE_FEATURE_OVERRIDES_ENABLED", value ? value : "hasEvents", 1);
        free(value);
        if (getenv("MTLSHIM_VERBOSE"))
            shimLog("[mtlshim] WebKit's ANGLE on a family-1 GPU: ANGLE_FEATURE_OVERRIDES_ENABLED=%s\n", getenv("ANGLE_FEATURE_OVERRIDES_ENABLED"));
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
    enableEventsForWebKit(__builtin_return_address(0));
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
    if (familyOneAsTwo()) {
        disableFeaturesFamilyOneLacks();
        enableEventsForWebKit(__builtin_return_address(0));
    }
    static const char model[] = "MacBookPro13,3";  // past ANGLE's gate (MacBookPro >= 13,1)
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Chromium: IOPlatformExpertDevice model -> %s\n", model);
    CFRelease(value);
    return CFDataCreate(allocator, (const UInt8 *)model, sizeof model);
}

// 41. Metal's validation layers. Sequoia's and Tahoe's MetalTools (MTL_DEBUG_LAYER=1, Xcode's API validation) and their
// shader validation (MTL_SHADER_VALIDATION=1) are built for the OS's own Metal. On MetalOld, API validation reads the
// pipeline states' internals by the new layout and reports nonsense (a render pipeline's sample count 1065353216, the
// bits of 1.0f, and the wrong pixel format) before aborting the process, calls functions the Metal wrapper only exports
// as placeholder data (validateDispatchThreadsPerThreadgroupWithRTPTG: every compute dispatch crashed) and passes its
// feature numbers to MetalOld's MTLValidateFeatureSupport, which numbers them differently ("Bicubic filtering of 16-bit
// normalized values is not supported" on an indirect command buffer). Shader validation instruments shaders with the
// OS's compiler, whose AIR the legacy compiler rejects, and throws on a missing pipeline-descriptor method first. So
// both are switched off, with a note on stderr, before a device is made: at load for the launch environment, and in
// MTLCreateSystemDefaultDevice / MTLCopyAllDevices for programs that set them at run time (wgpu's GPU tests). The
// program then runs without validation instead of aborting. MTLSHIM_VALIDATION=1 leaves them on. Test s54.
static void dropValidationLayers(void) {
    const char *keep = getenv("MTLSHIM_VALIDATION");
    if (keep && strcmp(keep, "0")) return;
    static const char *const names[] = {"MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        const char *value = getenv(names[i]);
        if (!value || !strcmp(value, "0")) continue;
        unsetenv(names[i]);
        fprintf(stderr, "MetalOldCompat: %s ignored: Metal's validation layers need the OS's own Metal, not the legacy Metal "
                        "this Mac runs (MTLSHIM_VALIDATION=1 keeps them)\n", names[i]);
    }
}

static void installMPSMatmulFallback(void);  // item 43
static void installMPSGraphSoftMax(void);  // item 57
static void installMetalFXTemporalLimit(void);  // item 44

static id<MTLDevice> compatCreateSystemDefaultDevice(void) {
    dropValidationLayers();
    installMPSMatmulFallback();
    installMPSGraphSoftMax();
    installMetalFXTemporalLimit();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MTLCreateSystemDefaultDevice from %s -> %s\n", callerImage(__builtin_return_address(0)), device.name.UTF8String);
    pinDevice((__bridge const void *)device);
    if (device && fromChromium(__builtin_return_address(0)) && familyTwo((__bridge const void *)device) == testIGPUOnly()) {
        for (id<MTLDevice> other in MTLCopyAllDevices())
            if (familyTwo((__bridge const void *)other) != testIGPUOnly()) {
                pinDevice((__bridge const void *)other);
                if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] Chromium: default device %s -> %s\n", device.name.UTF8String, other.name.UTF8String);
                return other;
            }
    }
    return device;
}

static CFArrayRef compatCopyAllDevices(void) {
    dropValidationLayers();
    installMPSMatmulFallback();
    installMPSGraphSoftMax();
    installMetalFXTemporalLimit();
    CFArrayRef all = (__bridge_retained CFArrayRef)MTLCopyAllDevices();
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MTLCopyAllDevices from %s\n", callerImage(__builtin_return_address(0)));
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) pinDevice(CFArrayGetValueAtIndex(all, i));
    return fromChromium(__builtin_return_address(0)) ? familyTwoOnly(all) : all;
}

static CFArrayRef compatCopyAllDevicesWithObserver(id<NSObject> __strong *observer, MTLDeviceNotificationHandler handler) {
    dropValidationLayers();
    installMPSMatmulFallback();
    installMPSGraphSoftMax();
    installMetalFXTemporalLimit();
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
            // __DATA_CONST starts writable (initprot) but dyld makes it read-only once its fixups are done
            bool writable = (segment->initprot & VM_PROT_WRITE) && strcmp(segment->segname, "__DATA_CONST") &&
                            strcmp(segment->segname, "__AUTH_CONST");
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

// The process that runs the GPU compiler, where items 25, 75 and the read sampler rewrite go: MTLCompilerService, or a
// test that runs it in-process (Tests/tools/localcc.dylib, which verify.sh uses). Called from the constructor of every
// process that loads Metal, WindowServer at boot included: no dlsym there, only the list of loaded images.
static bool hostsCompiler(void) {
    if (!strcmp(getprogname(), "MTLCompilerService")) return true;
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const char *name = _dyld_get_image_name(i), *slash = name ? strrchr(name, '/') : NULL;
        if (slash && !strcmp(slash + 1, "localcc.dylib")) return true;
    }
    return false;
}

static void installAIR27Retargeting(void) {
    const char *setting = getenv("MTLSHIM_AIR27");
    if ((setting && !strcmp(setting, "0")) || !hostsCompiler()) return;
    _dyld_register_func_for_add_image(interposeCompilerImage);  // also called for the images already loaded
}

// 75. Shader libraries built for macOS 13.1 or older, on Tahoe. Tahoe's compiler for this stack (the macOS 14.2 front end,
// installed as GPUCompiler 31001) reads every module through OCLP's libLLVM wrapper, whose libLLVM_helper fixIr()
// relabels it air64-apple-macosx13.2.0 / AIR 2.5 so that Tahoe's AIR 2.8 libraries load. On an older module that hides
// its version from 31001's own upgrade pass (MTLCompilerObject::upgradeAIRModule, which runs on every module a request
// reads, the downgrade request's too): it takes the module for AIR 2.5 and leaves its texture calls in their AIR 2.1-era
// form (the texel alone, where AIR 2.6 returns { texel, i8 }), which the downgrade for the 3802 back ends then rewrites
// into invalid IR ("INSERTVAL: Invalid type", "Invalid record") and the 3802 reader aborts MTLCompilerService. So any
// app's library built for macOS 10.14 that reads textures crashed the compiler service on Intel and Kepler (s75), and
// so did Chromium's prebuilt ANGLE library, which item 13 replaces for that reason too (s74); Gabriel-AGH traced the
// mechanism. fixIr now returns modules whose triple is older than macOS 13.2 as they are, and the upgrade pass converts
// them. Hooked by pointing the wrapper's import slot for fixIr (in its __got) at a wrapper, fixIr resolved with dlsym (no
// link-time dependency). MTLSHIM_OLD_AIR=0 turns this off.
static NSData *(*origFixIr)(NSData *);
static const char kLLVMWrapper31001[] = "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/libLLVM.dylib";

static bool olderThanMacOS132(NSData *module) {  // the "-apple-macosxMAJOR.MINOR" of the module's triple
    static const char key[] = "-apple-macosx";
    const char *p = module.bytes, *end = p + module.length;
    for (const char *q = p; q + sizeof key + 4 < end; q++) {
        if (*q != '-' || memcmp(q, key, sizeof key - 1)) continue;
        const char *version = q + sizeof key - 1, *dot = memchr(version, '.', (size_t)(end - version));
        int major = atoi(version), minor = dot ? atoi(dot + 1) : 0;
        return major < 13 || (major == 13 && minor < 2);
    }
    return false;
}

static NSData *fixIrKeepingOldModules(NSData *module) {
    if (module && olderThanMacOS132(module)) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] module older than macOS 13.2 left as it is for the upgrade pass\n");
        return module;
    }
    return origFixIr(module);
}

// The address of `name` in an image's symbol table (LC_SYMTAB in its __LINKEDIT), without dyld: the add-image callback
// runs under dyld's lock, where dlopen or dlsym on these privately opened (RTLD_LOCAL) libraries hangs or finds nothing.
static const void *symbolInImage(const struct mach_header *mh, intptr_t slide, const char *name) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const struct load_command *command = (const struct load_command *)(header + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT))
            linkedit = (const struct segment_command_64 *)command;
        else if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
    }
    if (!linkedit || !symtab) return NULL;
    const char *base = (const char *)(linkedit->vmaddr + slide - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = base + symtab->stroff;
    for (uint32_t i = 0; i < symtab->nsyms; i++)
        if ((symbols[i].n_type & N_TYPE) == N_SECT && symbols[i].n_un.n_strx && !strcmp(strings + symbols[i].n_un.n_strx, name))
            return (const void *)(symbols[i].n_value + slide);
    return NULL;
}

// The wrapper and libLLVM_helper (which OCLP's wrapper names by a relative path) can arrive in either order.
static struct { const struct mach_header *mh; intptr_t slide; } llvmWrapper31001, llvmHelper31001;
static void interposeLLVMWrapper(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    if (!strcmp(info.dli_fname, kLLVMWrapper31001)) llvmWrapper31001.mh = mh, llvmWrapper31001.slide = slide;
    else if (strstr(info.dli_fname, "GPUCompiler.framework/Versions/31001/Libraries/libLLVM_helper.dylib"))
        llvmHelper31001.mh = mh, llvmHelper31001.slide = slide;
    else return;
    if (origFixIr || !llvmWrapper31001.mh || !llvmHelper31001.mh) return;
    origFixIr = (NSData *(*)(NSData *))symbolInImage(llvmHelper31001.mh, llvmHelper31001.slide, "__Z5fixIrP6NSData");
    if (!origFixIr) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] old modules past fixIr: no fixIr in libLLVM_helper\n");
        return;
    }
    int slots = rebindImports(llvmWrapper31001.mh, llvmWrapper31001.slide, (const void *)origFixIr, (const void *)fixIrKeepingOldModules);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] old modules past fixIr: %d import slot(s) in libLLVM 31001\n", slots);
}

static void installOldAIRPassThrough(void) {
    const char *setting = getenv("MTLSHIM_OLD_AIR");
    if ((setting && !strcmp(setting, "0")) || !hostsCompiler()) return;
    _dyld_register_func_for_add_image(interposeLLVMWrapper);  // also called for the images already loaded
}

// 76. MetalOld's function cache with the AMD GPUs' compiler. The 14.2-era compiler that compiles for them returns a
// reflection block with every render stage, where the 13.2 compiler MetalOld was written for returned one only when the
// app asked for reflection. -[MTLCompiler cacheCompilerData:cachedData:hashMap:libraryData:functionCache:] stores every
// block it got under hashMap[type], and MetalOld computes a reflection key only for reflection it asked for: operator[]
// then adds a key that isn't initialized, mostly on the memory of the key freed just before, which is the linking key of
// the fragment stage compiled for the same pipeline. So the vertex stage's reflection replaced the fragment stage's
// fragment-input list in the cache, and the next pipeline that took that fragment stage from the cache sent the
// reflection block as its input list: the compiler's parser wrote past a fixed array and MTLCompilerService crashed
// (Chrome for Testing 124's WebGL on the R9). Only blocks whose type had a key are cached now, and each app's function
// caches, which may hold such entries, are cleared once. MTLSHIM_CACHE_KEYS=0 turns this off.
typedef void (*CacheCompilerDataIMP)(id, SEL, void *, void *, void *, void *, const void *);
typedef void (*AddCompiledOutputIMP)(id, SEL, id, id, id, id, const void *, int, const void *);
static CacheCompilerDataIMP origCacheCompilerData;
static AddCompiledOutputIMP origAddCompiledOutput;
static __thread unsigned cacheableTypes;
static __thread bool inCacheCompilerData;

static void cacheCompilerData(id self, SEL _cmd, void *outputs, void *cached, void *hashMap, void *libraryData, const void *functionCache) {
    // hashMap is a std::unordered_map<CompilerOutputType, MTLMultiHashKey>; libc++ keeps its first node at +0x10, and
    // each node is {next, hash, key (u32) at +0x10, value}
    unsigned types = 0;
    for (void *const *node = hashMap ? *(void *const *const *)((const char *)hashMap + 0x10) : NULL; node; node = *node) {
        unsigned type = *(const unsigned *)((const char *)node + 0x10);
        if (type < 32) types |= 1u << type;
    }
    unsigned savedTypes = cacheableTypes;
    bool savedIn = inCacheCompilerData;
    cacheableTypes = types, inCacheCompilerData = true;
    origCacheCompilerData(self, _cmd, outputs, cached, hashMap, libraryData, functionCache);
    cacheableTypes = savedTypes, inCacheCompilerData = savedIn;
}

static void addCompiledOutput(id self, SEL _cmd, id output, id cachedOutput, id symbols, id libraries, const void *hashKey, int type,
                              const void *functionCache) {
    if (inCacheCompilerData && (type < 0 || type >= 32 || !(cacheableTypes & (1u << type)))) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] function cache: block type %d had no key, not cached\n", type);
        return;
    }
    origAddCompiledOutput(self, _cmd, output, cachedOutput, symbols, libraries, hashKey, type, functionCache);
}

// <user cache folder>/<bundle id>/com.apple.metal/<GPU>/functions.{data,list}; a marker file records that it was done.
// Not from the constructor: it runs in WindowServer and loginwindow at boot, where confstr's lookup of the user's cache
// folder (dirhelper, opendirectoryd) and file work may wait on services that aren't up yet (the HD 4000's Tahoe stopped
// booting where WindowServer starts). It runs on the process's first compile request instead, before that request reads
// the cache, and only in apps run by a user (bundle id, uid 501 and up): the Chrome case, not system daemons.
static void clearFunctionCachesOnce(void) {
    if (getuid() < 501) return;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    char dir[PATH_MAX];
    if (!bundle || !confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof dir)) return;
    NSString *root = [[@(dir) stringByAppendingPathComponent:bundle] stringByAppendingPathComponent:@"com.apple.metal"];
    NSString *marker = [root stringByAppendingPathComponent:@"mtlshim-function-cache-keys"];
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![files fileExistsAtPath:root isDirectory:&isDir] || !isDir || [files fileExistsAtPath:marker]) return;
    int cleared = 0;
    for (NSString *gpu in [files contentsOfDirectoryAtPath:root error:nil])
        for (NSString *name in @[@"functions.data", @"functions.list"])
            cleared += [files removeItemAtPath:[[root stringByAppendingPathComponent:gpu] stringByAppendingPathComponent:name] error:nil];
    [files createFileAtPath:marker contents:nil attributes:nil];
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] function cache: %d file(s) cleared in %s\n", cleared, root.UTF8String);
}

typedef void (*CompileRequestIMP)(id, SEL, id, BOOL, unsigned long long, BOOL, id);
static CompileRequestIMP origCompileRequest;
static void compileRequest(id self, SEL _cmd, id request, BOOL frameworkLinking, unsigned long long linkDataSize, BOOL reflectionOnly,
                           id handler) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ clearFunctionCachesOnce(); });
    origCompileRequest(self, _cmd, request, frameworkLinking, linkDataSize, reflectionOnly, handler);
}

static void installFunctionCacheKeys(void) {
    const char *setting = getenv("MTLSHIM_CACHE_KEYS");
    if (setting && !strcmp(setting, "0")) return;
    Class compiler = objc_getClass("MTLCompiler");
    Method store = class_getInstanceMethod(compiler, sel_registerName("cacheCompilerData:cachedData:hashMap:libraryData:functionCache:"));
    Method add = class_getInstanceMethod(compiler,
        sel_registerName("addCompiledOutput:cachedCompiledOutput:importedSymbols:importedLibraries:hashKey:type:functionCache:"));
    if (!store || !add) return;
    origAddCompiledOutput = (AddCompiledOutputIMP)method_setImplementation(add, (IMP)addCompiledOutput);
    origCacheCompilerData = (CacheCompilerDataIMP)method_setImplementation(store, (IMP)cacheCompilerData);
    Method request = class_getInstanceMethod(compiler,
        sel_registerName("compileFunctionRequestInternal:frameworkLinking:linkDataSize:reflectionOnly:completionHandler:"));
    if (request) origCompileRequest = (CompileRequestIMP)method_setImplementation(request, (IMP)compileRequest);
}

// 45. Texture reads through the read sampler. Xcode 26's front end builds every texture read of a Metal 4.0 library, and
// depth, cube and 1D reads in some of macOS 26's own libraries (SceneKit, VFX, CoreComposite), as
// air.read_<texture>(texture, air.get_read_sampler(), ...): the older form's arguments with the sampler second and, for
// 2D, 2D-array, 3D and depth 2D(-array) textures, a texel offset after the coordinates (or the layer). Tahoe's compiler
// on this stack (the macOS 14.2 front end, installed as GPUCompiler 31001) predates the form: its
// AIR16BitTextureCoordinateEmulationPass, which widens ushort coordinates for these GPUs, takes the sampler for the
// coordinates and crashes MTLCompilerService on such a read with ushort coordinates (SceneKit's temporal_aa, behind
// SCNView's temporal antialiasing; any Metal 4.0 kernel reading with a ushort thread position), and MetalOld resends the
// request forever. The other reads reach the back ends as they are, and libAMDIL902 can't build them ("SC compilation
// failure There is a call to an undefined label": SceneKit's HDR exposure adaptation, cube and depth copies). A read takes
// no sampler state, so before that pass every such call is rebuilt in the older form, the one the runtime compiler
// emits: without the sampler, the offset added to the coordinates. The pass is wrapped by an inline hook (its 14-byte
// prologue checked), the module edited through the C API of the same libLLVM. MTLSHIM_READ_SAMPLER=0 turns it off.
// Test: s59.
static struct {
    LLVMRef (*getNamedFunction)(LLVMRef module, const char *name);
    LLVMRef (*firstFunction)(LLVMRef module);
    LLVMRef (*nextFunction)(LLVMRef function);
    const char *(*valueName)(LLVMRef value, size_t *length);
    void (*setValueName)(LLVMRef value, const char *name, size_t length);
    LLVMRef (*firstUse)(LLVMRef value);
    LLVMRef (*nextUse)(LLVMRef use);
    LLVMRef (*user)(LLVMRef use);
    LLVMRef (*isACallInst)(LLVMRef value);
    LLVMRef (*calledValue)(LLVMRef call);
    LLVMRef (*operand)(LLVMRef user, unsigned i);
    LLVMRef (*globalValueType)(LLVMRef global);
    LLVMRef (*returnType)(LLVMRef functionType);
    unsigned (*paramCount)(LLVMRef functionType);
    void (*paramTypes)(LLVMRef functionType, LLVMRef *out);
    int (*typeKind)(LLVMRef type);
    unsigned (*pointerAddressSpace)(LLVMRef type);
    LLVMRef (*functionType)(LLVMRef result, LLVMRef *params, unsigned count, int varArg);
    LLVMRef (*addFunction)(LLVMRef module, const char *name, LLVMRef type);
    LLVMRef (*moduleContext)(LLVMRef module);
    LLVMRef (*createBuilder)(LLVMRef context);
    void (*positionBefore)(LLVMRef builder, LLVMRef instruction);
    LLVMRef (*buildAdd)(LLVMRef builder, LLVMRef lhs, LLVMRef rhs, const char *name);
    LLVMRef (*buildCall)(LLVMRef builder, LLVMRef type, LLVMRef function, LLVMRef *args, unsigned count, const char *name);
    void (*disposeBuilder)(LLVMRef builder);
    void (*replaceAllUses)(LLVMRef old, LLVMRef replacement);
    void (*eraseInstruction)(LLVMRef instruction);
    void (*deleteFunction)(LLVMRef function);
    int (*isNull)(LLVMRef value);
    unsigned (*attributeCount)(LLVMRef function, unsigned index);
    void (*attributes)(LLVMRef function, unsigned index, LLVMRef *out);
    void (*addAttribute)(LLVMRef function, unsigned index, LLVMRef attribute);
    unsigned (*callAttributeCount)(LLVMRef call, unsigned index);
    void (*callAttributes)(LLVMRef call, unsigned index, LLVMRef *out);
    void (*addCallAttribute)(LLVMRef call, unsigned index, LLVMRef attribute);
} llvmFE;
_Static_assert(sizeof llvmFE == 35 * sizeof(void *), "one slot per name in installReadSamplerRewrite");
enum { kLLVMPointerTypeKind = 12, kLLVMFunctionIndex = ~0u, kReadArguments = 12 };
typedef void *(*PassRunFn)(void *result, void *pass, void *module, void *analyses);  // PreservedAnalyses returned in memory
static PassRunFn origCoordinateEmulationRun;

// The function-level attributes (nounwind, memory effects) of `from` on `to`: a declaration, or a call site.
static void copyFunctionAttributes(LLVMRef from, LLVMRef to, bool calls) {
    unsigned count = calls ? llvmFE.callAttributeCount(from, kLLVMFunctionIndex) : llvmFE.attributeCount(from, kLLVMFunctionIndex);
    LLVMRef attributes[32];
    if (count > 32) return;
    if (calls) llvmFE.callAttributes(from, kLLVMFunctionIndex, attributes);
    else llvmFE.attributes(from, kLLVMFunctionIndex, attributes);
    for (unsigned i = 0; i < count; i++)
        if (calls) llvmFE.addCallAttribute(to, kLLVMFunctionIndex, attributes[i]);
        else llvmFE.addAttribute(to, kLLVMFunctionIndex, attributes[i]);
}

// One read intrinsic in the newer form -> the older one; returns the calls rebuilt (0 if any use isn't such a call).
static unsigned plainReadFunction(LLVMRef module, LLVMRef read, const char *name) {
    static const struct { const char *prefix; unsigned coord, offset; } kOffsets[] = {
        {"air.read_texture_2d.", 2, 3}, {"air.read_texture_2d_array.", 2, 4}, {"air.read_texture_3d.", 2, 3},
        {"air.read_depth_2d.", 3, 4},   {"air.read_depth_2d_array.", 3, 5},
    };
    unsigned coord = 0, offset = 0;
    for (size_t k = 0; k < sizeof kOffsets / sizeof *kOffsets; k++)
        if (!strncmp(name, kOffsets[k].prefix, strlen(kOffsets[k].prefix))) coord = kOffsets[k].coord, offset = kOffsets[k].offset;
    LLVMRef type = llvmFE.globalValueType(read), params[kReadArguments], kept[kReadArguments];
    unsigned count = llvmFE.paramCount(type), keptCount = 0;
    if (count < 3 || count > kReadArguments) return 0;
    llvmFE.paramTypes(type, params);
    if (llvmFE.typeKind(params[1]) != kLLVMPointerTypeKind || llvmFE.pointerAddressSpace(params[1]) != 2) return 0;
    if (offset && (offset >= count || params[offset] != params[coord])) return 0;
    unsigned calls = 0;
    for (LLVMRef use = llvmFE.firstUse(read); use; use = llvmFE.nextUse(use), calls++) {
        LLVMRef call = llvmFE.user(use);
        if (!llvmFE.isACallInst(call) || llvmFE.calledValue(call) != read) return 0;
    }
    if (!calls) return 0;
    LLVMRef *found = malloc(calls * sizeof *found);
    if (!found) return 0;
    unsigned n = 0;
    for (LLVMRef use = llvmFE.firstUse(read); use; use = llvmFE.nextUse(use)) found[n++] = llvmFE.user(use);
    for (unsigned a = 0; a < count; a++)
        if (a != 1 && (!offset || a != offset)) kept[keptCount++] = params[a];
    LLVMRef plainType = llvmFE.functionType(llvmFE.returnType(type), kept, keptCount, 0);
    char *saved = strdup(name);
    llvmFE.setValueName(read, "", 0);  // the older form takes the name
    LLVMRef plain = llvmFE.addFunction(module, saved, plainType);
    free(saved);
    copyFunctionAttributes(read, plain, false);
    LLVMRef builder = llvmFE.createBuilder(llvmFE.moduleContext(module));
    for (unsigned c = 0; c < calls; c++) {
        LLVMRef call = found[c], args[kReadArguments];
        unsigned argCount = 0;
        llvmFE.positionBefore(builder, call);
        for (unsigned a = 0; a < count; a++) {
            if (a == 1 || (offset && a == offset)) continue;
            LLVMRef value = llvmFE.operand(call, a);
            if (offset && a == coord && !llvmFE.isNull(llvmFE.operand(call, offset)))
                value = llvmFE.buildAdd(builder, value, llvmFE.operand(call, offset), "");
            args[argCount++] = value;
        }
        LLVMRef rebuilt = llvmFE.buildCall(builder, plainType, plain, args, argCount, "");
        copyFunctionAttributes(call, rebuilt, true);
        llvmFE.replaceAllUses(call, rebuilt);
        llvmFE.eraseInstruction(call);
    }
    llvmFE.disposeBuilder(builder);
    free(found);
    llvmFE.deleteFunction(read);
    return calls;
}

static unsigned plainReads(LLVMRef module) {
    LLVMRef sampler = llvmFE.getNamedFunction(module, "air.get_read_sampler");
    if (!sampler) return 0;
    LLVMRef reads[64];
    unsigned count = 0, rebuilt = 0;
    for (LLVMRef f = llvmFE.firstFunction(module); f && count < 64; f = llvmFE.nextFunction(f)) {
        size_t length = 0;
        const char *name = llvmFE.valueName(f, &length);
        if (name && (!strncmp(name, "air.read_texture_", 17) || !strncmp(name, "air.read_depth_", 15))) reads[count++] = f;
    }
    for (unsigned i = 0; i < count; i++) {
        size_t length = 0;
        char name[128];
        const char *current = llvmFE.valueName(reads[i], &length);
        if (!current || length >= sizeof name) continue;
        memcpy(name, current, length), name[length] = 0;
        rebuilt += plainReadFunction(module, reads[i], name);
    }
    LLVMRef *dead = NULL;
    unsigned deadCount = 0;
    for (LLVMRef use = llvmFE.firstUse(sampler); use; use = llvmFE.nextUse(use)) {  // read-sampler calls left unused
        LLVMRef call = llvmFE.user(use);
        if (!llvmFE.isACallInst(call) || llvmFE.firstUse(call)) continue;
        LLVMRef *grown = realloc(dead, (deadCount + 1) * sizeof *dead);
        if (!grown) break;
        dead = grown, dead[deadCount++] = call;
    }
    for (unsigned i = 0; i < deadCount; i++) llvmFE.eraseInstruction(dead[i]);
    free(dead);
    if (!llvmFE.firstUse(sampler)) llvmFE.deleteFunction(sampler);
    if (rebuilt && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %u texture read(s) rebuilt without the read sampler\n", rebuilt);
    return rebuilt;
}

static void *coordinateEmulationRun(void *result, void *pass, void *module, void *analyses) {
    plainReads(module);
    return origCoordinateEmulationRun(result, pass, module, analyses);
}

static const char kGPUCompiler31001[] = "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/";

static void hookCoordinateEmulation(const struct mach_header *mh, intptr_t slide) {
    static const unsigned char kPrologue[14] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x56, 0x53, 0x48, 0x83, 0xec, 0x10, 0x49, 0x89, 0xd6};
    Dl_info info;
    const size_t dirLength = sizeof kGPUCompiler31001 - 1;
    (void)slide;
    if (origCoordinateEmulationRun || !dladdr(mh, &info) || !info.dli_fname || strncmp(info.dli_fname, kGPUCompiler31001, dirLength) ||
        strcmp(info.dli_fname + dirLength, "libGPUCompilerImpl.dylib"))
        return;
    void *impl = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY);
    char path[256];
    snprintf(path, sizeof path, "%slibLLVM_real.dylib", kGPUCompiler31001);
    void *llvm = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
    unsigned char *entry = impl ? dlsym(impl, "_ZN4llvm3air38AIR16BitTextureCoordinateEmulationPass3runERNS_6ModuleERNS_15AnalysisManagerIS2_JEEE") : NULL;
    if (!llvm || !entry || memcmp(entry, kPrologue, sizeof kPrologue)) {
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] read sampler rewrite: compiler not as expected, left alone\n");
        return;
    }
    const char *names[] = {"LLVMGetNamedFunction", "LLVMGetFirstFunction", "LLVMGetNextFunction", "LLVMGetValueName2",
                           "LLVMSetValueName2", "LLVMGetFirstUse", "LLVMGetNextUse", "LLVMGetUser", "LLVMIsACallInst",
                           "LLVMGetCalledValue", "LLVMGetOperand", "LLVMGlobalGetValueType", "LLVMGetReturnType",
                           "LLVMCountParamTypes", "LLVMGetParamTypes", "LLVMGetTypeKind", "LLVMGetPointerAddressSpace",
                           "LLVMFunctionType", "LLVMAddFunction", "LLVMGetModuleContext", "LLVMCreateBuilderInContext",
                           "LLVMPositionBuilderBefore", "LLVMBuildAdd", "LLVMBuildCall2", "LLVMDisposeBuilder",
                           "LLVMReplaceAllUsesWith", "LLVMInstructionEraseFromParent", "LLVMDeleteFunction", "LLVMIsNull",
                           "LLVMGetAttributeCountAtIndex", "LLVMGetAttributesAtIndex", "LLVMAddAttributeAtIndex",
                           "LLVMGetCallSiteAttributeCount", "LLVMGetCallSiteAttributes", "LLVMAddCallSiteAttribute"};
    _Static_assert(sizeof names / sizeof *names == sizeof llvmFE / sizeof(void *), "one name per slot");
    void **slots = (void **)&llvmFE;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (!(slots[i] = dlsym(llvm, names[i]))) return;
    origCoordinateEmulationRun = (PassRunFn)hookPrologue(entry, sizeof kPrologue, (void *)coordinateEmulationRun);
    if (getenv("MTLSHIM_VERBOSE"))
        shimLog("[mtlshim] read sampler rewrite: %s\n", origCoordinateEmulationRun ? "installed" : "hook failed");
}

static void installReadSamplerRewrite(void) {
    const char *setting = getenv("MTLSHIM_READ_SAMPLER");
    if ((setting && !strcmp(setting, "0")) || !hostsCompiler()) return;
    _dyld_register_func_for_add_image(hookCoordinateEmulation);  // also called for the images already loaded
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

// ---- 41. CoreImageOld's portrait kernel library data ------------------------------------------------------------------
// CoreImageOld.dylib (OCLP's 14.0 beta 3 Core Image for the 3802 stack) loads the Metal kernels of its portrait / SDOF
// filters through +[CIKernel SDOFV2MetalKernelNamed:] (and SDOFV3, and the same pair on CIColorKernel). Each reads a
// static NSData that a once-block fills with [NSData dataWithContentsOfURL:] of CoreImage.framework's
// CIPortraitBlur[Stitchable]V2/V3.metallib and stores without retaining it (non-ARC code). The first portrait filter
// uses it while it is still alive; once an autorelease pool drains it is freed, and the next one passes a dangling
// pointer to -[CIKernelLibrary initWithData:error:], which crashes in objc_retain: CIDepthBlurEffect, Photos' portrait
// editing, on the Iris Pro and the R9 M370X alike. +[NSData dataWithContentsOfURL:] returns those four files from a
// cache that keeps them alive, so the static stays valid. (MetalOld lists no functions in Sequoia's metallibs; it finds
// them by name, but CIKernelLibrary builds its table from functionNames, so the portrait kernels still come back nil
// and CIDepthBlurEffect returns its input without the blur instead of crashing.) Installed only where
// CoreImageOld.dylib exists. MTLSHIM_SDOF_LIBRARY=0 turns it off.
static IMP origDataWithContentsOfURL;
static id keptPortraitLibrary(id self, SEL _cmd, NSURL *url) {
    NSString *file = url.isFileURL ? url.lastPathComponent : nil;
    if (self != [NSData class] || ![file hasPrefix:@"CIPortraitBlur"] || ![file.pathExtension isEqualToString:@"metallib"])
        return ((id (*)(id, SEL, NSURL *))origDataWithContentsOfURL)(self, _cmd, url);
    static NSMutableDictionary<NSString *, NSData *> *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableDictionary dictionary]; });
    @synchronized(kept) {
        NSData *data = kept[url.path];
        if (!data) {
            data = ((id (*)(id, SEL, NSURL *))origDataWithContentsOfURL)(self, _cmd, url);
            if (data) kept[url.path] = data;
            if (data && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] %s kept alive for CoreImageOld (item 41)\n", file.UTF8String);
        }
        return data;
    }
}
static void keepPortraitLibraries(void) {
    const char *setting = getenv("MTLSHIM_SDOF_LIBRARY");
    if ((setting && !strcmp(setting, "0")) || access("/System/Library/Frameworks/CoreImage.framework/Versions/A/CoreImageOld.dylib", F_OK)) return;
    Method m = class_getClassMethod([NSData class], @selector(dataWithContentsOfURL:));
    if (m) origDataWithContentsOfURL = method_setImplementation(m, (IMP)keptPortraitLibrary);
}

// ---- 52. Reflection of stitchable functions ---------------------------------------------------------------------------
// MetalOld reflects a [[stitchable]] function (its return type and arguments, filled in by -[_MTLFunctionInternal
// initializeStitchableFunctionMetadata] when something asks for them) with a reflection-only request to
// MTLCompilerService, whose reply MTLStitchingReflectionReader reads. 13.2.1's reader takes the reply to be the reflection
// itself, an "MTLPSBIN" section, or a section without that header. Sequoia's compiler service puts the section in a newer
// container: a 0x50-byte header (a 0xef13c710 magic, then the offset and size of each of four sections), so the reader
// read a header word as the first argument's kind (0x50000000 where it wants 0x14) and called abort(). The section inside
// is in a format the reader knows (version 2.0, which it reads as 1.2 or later: the same argument records). Core Image
// reflects every kernel it loads from a metallib this way, through CIKernelReflection::reflect, and OCLP's CoreImageOld.dylib
// (the 14.0 beta 3 Core Image of the 3802 payloads) has reflect stubbed out to avoid that abort, which also made every
// precompiled Core Image kernel an app makes come back nil without an error: +[CIKernel kernelWithFunctionName:
// fromMetalLibraryData:error:], behind Microsoft Office's picture corrections, colour and artistic effects (Oimg.metallib).
// The payload's CoreImageOld has reflect back (tools/make_coreimage_fix.py), and here the reply handler of
// -[MTLCompiler reflectionWithFunction:options:sync:pipelineLibrary:binaryArchives:completionHandler:], which the other
// reflectionWithFunction: variants call, gets just the MTLPSBIN section when the reply is such a container. Precompiled
// and stitchable Core Image kernels then build and render on the Iris Pro and the R9 M370X, the 237 built-in filters render
// the same pixels as before, and CIDepthBlurEffect's portrait kernels (item 41), which are stitchable, reflect instead of
// aborting, as they would with reflect restored alone. Replies in any other form are passed on as they are.
// MTLSHIM_STITCHING_REFLECTION=0 turns it off (with the payload's CoreImageOld, stitchable kernels then abort again).
// Test: s68.
typedef void (^ReflectionHandler)(NSUInteger status, dispatch_data_t reflection, NSString *error);
typedef void (*ReflectionIMP)(id, SEL, id function, NSUInteger options, BOOL sync, id pipelineLibrary, id binaryArchives,
                              ReflectionHandler handler);
static ReflectionIMP origReflectionWithFunction;
static dispatch_data_t stitchingReflectionSection(dispatch_data_t reply) {
    const void *bytes = NULL;
    size_t size = 0;
    dispatch_data_t map = reply ? dispatch_data_create_map(reply, &bytes, &size) : nil;
    if (!map || size < 0x50 || *(const uint32_t *)bytes != 0xef13c710u) return reply;
    for (size_t entry = 0x10; entry < 0x50; entry += 0x10) {
        uint64_t offset, length;
        memcpy(&offset, (const char *)bytes + entry, 8);
        memcpy(&length, (const char *)bytes + entry + 8, 8);
        if (offset < 0x50 || offset > size || length < 12 || length > size - offset || memcmp((const char *)bytes + offset, "MTLPSBIN", 8))
            continue;
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] stitchable function reflection: MTLPSBIN section of the reply's container (%zu -> %llu bytes)\n", size, length);
        return dispatch_data_create_subrange(reply, offset, length);
    }
    return reply;
}
static void reflectionWithFunction(id self, SEL _cmd, id function, NSUInteger options, BOOL sync, id pipelineLibrary,
                                   id binaryArchives, ReflectionHandler handler) {
    ReflectionHandler unwrapping = handler ? ^(NSUInteger status, dispatch_data_t reflection, NSString *error) {
        handler(status, stitchingReflectionSection(reflection), error);
    } : nil;
    origReflectionWithFunction(self, _cmd, function, options, sync, pipelineLibrary, binaryArchives, unwrapping);
}
static void installStitchingReflection(void) {
    const char *setting = getenv("MTLSHIM_STITCHING_REFLECTION");
    if (setting && !strcmp(setting, "0")) return;
    Method m = class_getInstanceMethod(objc_getClass("MTLCompiler"),
                                       sel_registerName("reflectionWithFunction:options:sync:pipelineLibrary:binaryArchives:completionHandler:"));
    if (m && !strcmp(method_getTypeEncoding(m), "v60@0:8@16Q24c32@36@44@?52"))
        origReflectionWithFunction = (ReflectionIMP)method_setImplementation(m, (IMP)reflectionWithFunction);
}

// ---- 43. MPS NDArray matrix multiplication on the Intel GPU --------------------------------------------------------
// MPSNDArrayMatrixMultiplication (and through it MPSGraph's matrixMultiplication, the matmul of anything built on
// MPSGraph) multiplies with its own NDArray kernels on GPUs that MPSCore's device record types as 18-24, and with an
// MPSMatrixMultiplication it creates in -initWithDevice:sourceCount: (its _mmul) on the others. MPSCore types the
// Haswell / Ivy Bridge GPUs 24 (the R9 M370X 26), so on them no _mmul is made, and the NDArray path has no kernel for
// these family-1 GPUs: the encode opens and closes a compute encoder with no dispatch, and every result stays 0 (any
// size, transposed, batched, float16, with a bias). MPSMatrixMultiplication itself runs right there: MPS's classic API
// uses its MatrixMultiplyNN kernels on the Iris Pro. So before an encode on such a GPU, an
// MPSNDArrayMatrixMultiplication without _mmul gets the same MPSMatrixMultiplication it creates on the AMD GPU, and
// then takes the AMD GPU's path. Installed (an override of the encode method it inherits from
// MPSNDArrayMultiaryKernel, through which the public encodes and MPSGraph's both pass) once MPSNDArray is loaded, from
// this library's initializer and the device calls that come before any MPS kernel. Only the class itself (not its
// gather / quantized subclasses) on the 12.x Intel driver's devices. MTLSHIM_MPS_MATMUL=0 turns it off. Test: s57.
@interface NSObject (MetalOldCompatMPSMatmul)  // MPSMatrixMultiplication's initializer (this library doesn't link MPS)
- (instancetype)initWithDevice:(id)device transposeLeft:(BOOL)transposeLeft transposeRight:(BOOL)transposeRight resultRows:(NSUInteger)rows
                 resultColumns:(NSUInteger)columns interiorColumns:(NSUInteger)interior alpha:(double)alpha beta:(double)beta;
@end
typedef void (*MPSEncodeIMP)(id, SEL, void *, void *, void *, void *, void *, void *);
static MPSEncodeIMP inheritedMPSEncode;
static Class mpsMatmulClass;
static ptrdiff_t mpsMatmulFallbackOffset;

static void encodeMatmulWithFallback(id self, SEL _cmd, void *encoder, void *commandBuffer, void *sources, void *state, void *destination,
                                     void *dag) {
    void **fallback = (void **)((char *)(__bridge void *)self + mpsMatmulFallbackOffset);
    if (object_getClass(self) == mpsMatmulClass && !*fallback) {
        id device = ((id (*)(id, SEL))objc_msgSend)(self, @selector(device));
        Class matmul = objc_getClass("MPSMatrixMultiplication");
        if (matmul && device && !strncmp(object_getClassName(device), "MTLIGAccel", 10)) {
            id kernel = [[matmul alloc] initWithDevice:device transposeLeft:NO transposeRight:NO resultRows:1 resultColumns:1 interiorColumns:1
                                                 alpha:1 beta:0];
            if (kernel) *fallback = (__bridge_retained void *)kernel;  // owned by the object, as its own _mmul would be
            if (kernel && getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MPSNDArrayMatrixMultiplication: classic MPSMatrixMultiplication added\n");
        }
    }
    inheritedMPSEncode(self, _cmd, encoder, commandBuffer, sources, state, destination, dag);
}

// ---- 57. MPSGraph's softmax on Kepler --------------------------------------------------------------------------------
// -[MPSGraph softMaxWithTensor:axis:name:] over any axis but the last came out wrong on the GTX 770: over axis 0 of a 100x16
// tensor it wrote only element [0][0] and left the rest 0 (i71), over axes 0 and 1 of an 8x10x6 one every element was
// wrong. Over the last axis it's right, and so is every operation a softmax is made of, alone and composed in separate
// graphs; built from them in one graph, MPSGraph fuses them back into the same kernels (the same wrong values). So where a
// Kepler device is present (GeForceMTLDriver's NVMTLDevice), a softmax over another axis of a tensor of static shape is
// done over the last axis between two transposes, which MPSGraph keeps. MTLSHIM_MPSGRAPH_SOFTMAX=0 turns it off.
// Test: i71 on the GTX 770.
typedef id (*SoftMaxIMP)(id, SEL, id, NSInteger, id);
static SoftMaxIMP origSoftMax;
static BOOL anyKeplerDevice(void);
static id compositeSoftMax(id self, SEL _cmd, id tensor, NSInteger axis, id name) {
    if (!anyKeplerDevice()) return origSoftMax(self, _cmd, tensor, axis, name);  // decided at the first softmax, not at load
    // the rank, from a static shape only
    NSArray *shape = ((NSArray *(*)(id, SEL))objc_msgSend)(tensor, @selector(shape));
    NSInteger rank = shape ? (NSInteger)shape.count : 0, last = rank - 1, a = axis < 0 ? axis + rank : axis;
    if (rank < 2 || a < 0 || a >= last) return origSoftMax(self, _cmd, tensor, axis, name);
    typedef id (*Transpose)(id, SEL, id, NSUInteger, NSUInteger, id);
    SEL transpose = @selector(transposeTensor:dimension:withDimension:name:);
    id moved = ((Transpose)objc_msgSend)(self, transpose, tensor, (NSUInteger)a, (NSUInteger)last, nil);
    id soft = moved ? origSoftMax(self, _cmd, moved, last, nil) : nil;
    if (!soft) return origSoftMax(self, _cmd, tensor, axis, name);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MPSGraph softmax over axis %ld of %ld done over the last axis\n", (long)a, (long)rank);
    return ((Transpose)objc_msgSend)(self, transpose, soft, (NSUInteger)a, (NSUInteger)last, name);
}
static BOOL anyKeplerDevice(void) {
    static dispatch_once_t once;
    static BOOL any;
    dispatch_once(&once, ^{
        for (id<MTLDevice> device in MTLCopyAllDevices())
            if (!strncmp(object_getClassName(device), "NVMTL", 5)) any = YES;
    });
    return any;
}
static void installMPSGraphSoftMax(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static BOOL done;
    if (done) return;
    os_unfair_lock_lock(&lock);
    const char *setting = getenv("MTLSHIM_MPSGRAPH_SOFTMAX");
    Class graph = objc_getClass("MPSGraph");
    if (done || (setting && !strcmp(setting, "0"))) done = YES;
    else if (graph) {
        done = YES;  // one try once the class is there
        Method m = class_getInstanceMethod(graph, @selector(softMaxWithTensor:axis:name:));
        if (m && !strcmp(method_getTypeEncoding(m), "@40@0:8@16q24@32") &&
            class_getInstanceMethod(graph, @selector(reductionMaximumWithTensor:axis:name:)) &&
            class_getInstanceMethod(graph, @selector(reductionSumWithTensor:axis:name:))) {
            origSoftMax = (SoftMaxIMP)method_setImplementation(m, (IMP)compositeSoftMax);
            if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MPSGraph softmax hook installed (active where a Kepler GPU is)\n");
        }
    }
    os_unfair_lock_unlock(&lock);
}

static void installMPSMatmulFallback(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static BOOL done;
    if (done) return;
    os_unfair_lock_lock(&lock);
    const char *setting = getenv("MTLSHIM_MPS_MATMUL");
    Class matmul = objc_getClass("MPSNDArrayMatrixMultiplication");
    if (done || (setting && !strcmp(setting, "0"))) done = YES;
    else if (matmul) {
        done = YES;  // one try once the class is there
        SEL encode = sel_registerName("encodeToMPSCommandEncoder:commandBuffer:sourceArrays:resultState:destinationArray:kernelDAGObject:");
        Method inherited = class_getInstanceMethod(class_getSuperclass(matmul), encode);
        Ivar fallback = class_getInstanceVariable(matmul, "_mmul");
        const char *type = fallback ? ivar_getTypeEncoding(fallback) : "";
        if (inherited && fallback && type[0] == '@' && !strcmp(method_getTypeEncoding(inherited), "v64@0:8@16@24@32@40@48@56")) {
            inheritedMPSEncode = (MPSEncodeIMP)method_getImplementation(inherited);
            mpsMatmulClass = matmul;
            mpsMatmulFallbackOffset = ivar_getOffset(fallback);
            BOOL added = class_addMethod(matmul, encode, (IMP)encodeMatmulWithFallback, method_getTypeEncoding(inherited));
            if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MPS NDArray matmul fallback %s\n", added ? "installed" : "not installed (the class has its own encode)");
        }
    }
    os_unfair_lock_unlock(&lock);
}

// ---- 44. MetalFX's temporal scaler on the Intel and Kepler GPUs --------------------------------------------------------
// +[MTLFXTemporalScalerDescriptor supportsDevice:] says yes for the Haswell / Ivy Bridge GPUs, but the temporal pass
// (unified_pass_tile / unified_pass_kern) uses quad_shuffle_xor and quad_sum, which these family-1 GPUs don't have: the
// IGIL back end's built-in inliner aborts on them (the stock compiler too), MetalFX keeps going without the pipeline
// and the first -encodeToCommandBuffer: crashes the app in the driver's setKernel. Emulating quad operations would need
// threadgroup memory and barriers at every use, which is only safe in uniform control flow. So on the 12.x Intel
// driver's devices the temporal scaler is reported unsupported and not created (nil, as for any unsupported device),
// and apps take their path without it; the spatial scaler works there. The same on Kepler (below).
// MTLSHIM_METALFX_TEMPORAL=0 turns this off. Test: s58.
typedef BOOL (*SupportsDeviceIMP)(id, SEL, id);
typedef id (*NewTemporalIMP)(id, SEL, id) RETURNS_RETAINED;
typedef id (*NewTemporalCompilerIMP)(id, SEL, id, id) RETURNS_RETAINED;
static SupportsDeviceIMP origTemporalSupportsDevice;
static NewTemporalIMP origNewTemporalScaler;
static NewTemporalCompilerIMP origNewTemporalScalerCompiler;

// The 12.x Intel driver's devices, and Kepler's (GeForceMTLDriver): its back end, GeForceAIRPlugin, fails quad_shuffle_xor,
// quad_sum and simd_sum with "Unhandled constant" (simd_shuffle_xor compiles), and MetalFX's first encode segfaulted in
// the driver.
static BOOL noQuadGroupDevice(id device) {
    const char *name = device ? object_getClassName(device) : "";
    return !strncmp(name, "MTLIGAccel", 10) || !strncmp(name, "NVMTL", 5);
}

static BOOL temporalSupportsDevice(id self, SEL _cmd, id device) {
    return noQuadGroupDevice(device) ? NO : origTemporalSupportsDevice(self, _cmd, device);
}
static id newTemporalScaler(id self, SEL _cmd, id device) RETURNS_RETAINED;
static id newTemporalScaler(id self, SEL _cmd, id device) {
    if (!noQuadGroupDevice(device)) return origNewTemporalScaler(self, _cmd, device);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MetalFX temporal scaler: not on this GPU (no quad-group functions)\n");
    return nil;
}
static id newTemporalScalerCompiler(id self, SEL _cmd, id device, id compiler) RETURNS_RETAINED;
static id newTemporalScalerCompiler(id self, SEL _cmd, id device, id compiler) {
    return noQuadGroupDevice(device) ? nil : origNewTemporalScalerCompiler(self, _cmd, device, compiler);
}

static void installMetalFXTemporalLimit(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static BOOL done;
    if (done) return;
    os_unfair_lock_lock(&lock);
    const char *setting = getenv("MTLSHIM_METALFX_TEMPORAL");
    Class descriptor = objc_getClass("MTLFXTemporalScalerDescriptor");
    if (done || (setting && !strcmp(setting, "0"))) done = YES;
    else if (descriptor) {
        done = YES;
        Method supports = class_getClassMethod(descriptor, @selector(supportsDevice:));
        Method create = class_getInstanceMethod(descriptor, @selector(newTemporalScalerWithDevice:));
        Method createCompiler = class_getInstanceMethod(descriptor, sel_registerName("newTemporalScalerWithDevice:compiler:"));
        if (supports && !strcmp(method_getTypeEncoding(supports), "c24@0:8@16"))
            origTemporalSupportsDevice = (SupportsDeviceIMP)method_setImplementation(supports, (IMP)temporalSupportsDevice);
        if (create && !strcmp(method_getTypeEncoding(create), "@24@0:8@16"))
            origNewTemporalScaler = (NewTemporalIMP)method_setImplementation(create, (IMP)newTemporalScaler);
        if (createCompiler && !strcmp(method_getTypeEncoding(createCompiler), "@32@0:8@16@24"))
            origNewTemporalScalerCompiler = (NewTemporalCompilerIMP)method_setImplementation(createCompiler, (IMP)newTemporalScalerCompiler);
        if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MetalFX temporal scaler limit installed\n");
    }
    os_unfair_lock_unlock(&lock);
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
// 74. MoltenVK 1.4.0 and 1.4.1 (Godot 4.7, apps built with Vulkan SDK 1.4.3xx) take every Mac GPU for a family-2 one and
// put Vulkan memory in placement heaps, which the family-1 GPUs don't have: MetalOld's validation aborts the app at the
// first allocation ("Placement heap type is not supported"; Kepler, Ivy Bridge, Haswell). MoltenVK 1.4.2 asks the GPU
// again, and keeps heaps off on AMD by default. On this stack every GPU is one or the other, so MVK_CONFIG_USE_MTLHEAP
// gets the value 0 (never) unless the environment sets it. Test: s81.
static void preferNoMTLHeaps(void) {
    if (getenv("MVK_CONFIG_USE_MTLHEAP")) return;
    setenv("MVK_CONFIG_USE_MTLHEAP", "0", 0);
    if (getenv("MTLSHIM_VERBOSE")) shimLog("[mtlshim] MoltenVK: MVK_CONFIG_USE_MTLHEAP=0 (no placement heaps on these GPUs)\n");
}

__attribute__((constructor)) static void init(void) {
#ifndef METALOLDCOMPAT_NOOP
    if (onMetalOld()) dropValidationLayers(), preferNoMTLHeaps();
    patchDeviceBase();
    installAIR27Retargeting();
    installOldAIRPassThrough();
    installReadSamplerRewrite();
    installWebKitRouting();
    keepPortraitLibraries();
    if (onMetalOld()) installMPSMatmulFallback(), installMPSGraphSoftMax(), installMetalFXTemporalLimit(), installStitchingReflection();
    if (onMetalOld()) installFunctionCacheKeys();
#else
    (void)dropValidationLayers;
    (void)preferNoMTLHeaps;
    (void)keepPortraitLibraries;
    (void)installStitchingReflection;
    (void)installMPSMatmulFallback;
    (void)installMPSGraphSoftMax;
    (void)installMetalFXTemporalLimit;
    (void)installWebKitRouting;
    (void)patchDeviceBase;
    (void)installAIR27Retargeting;
    (void)installOldAIRPassThrough;
    (void)installFunctionCacheKeys;
    (void)installReadSamplerRewrite;
#endif
}
