// AMDBronzeCompat.dylib: fixes for bugs in OCLP's 12.5 AMD Metal driver (AMDMTLBronzeDriver: GCN), in every process
// that uses the driver. It's loaded by a weak load command added to the driver itself, so it reaches every Mac and macOS
// that runs this driver, whether or not OCLP's MetalOld wrapper is installed (AMD-only Macs such as the MacPro6,1 don't
// have the wrapper). The driver is the same code in all of PatcherSupportPkg's copies (12.5, 12.5-24, 12.5-25,
// 12.5-GCN-SKL-*); each hook checks for what it relies on and stays out otherwise.
//   1. stencil through texture views of mip 1+ (written to the wrong level and slice; shaders read the wrong place)
//   2. sRGB mipmaps (the driver's blit averages the encoded bytes)
//   3. trilinear filtering (blends between mip levels only in the middle of the interval)
//   4. sRGB MSAA resolve (the hardware resolve averages the encoded bytes); on 12.5-24 its shader read of the samples
//      needs the AMD adapter's FMASK fix (AMDTextureAtomics.dylib), without which it resets the GPU
//   5. depth or stencil copied to a buffer with row pitch 0 (nothing gets written)
//   6. WebKit's one-vertex pipelines, whose stride the driver refuses (Safari's GPU process crashes on the draw)
//   7. WebKit's sample mask of 0 (the driver draws every sample)
//   8. memoryless textures (only Apple GPUs have them, and Metal's texture validation aborts the process)
//   9. MSL 3.2 device coherence on buffers (the driver's compiler fails the pipeline: MoltenVK's coherent buffers)
//  10. depth of mipmapped depth-stencil textures read by shaders (small levels come from the wrong place)
// 1 and 2 come from riptidewave93's bronzefix, found and tested on Tahoe with a MacPro6,1's FirePro D700s.
// AMD_BRONZE_COMPAT=0 turns everything off for a process, AMD_EXACT_TRILINEAR=0 only item 3,
// AMD_BRONZE_SRGB_RESOLVE=0 only item 4, AMD_BRONZE_MEMORYLESS=0 only item 8, AMD_BRONZE_DEPTH_MIPS=0 only item 10,
// AMD_BRONZE_STENCIL_VIEW=0 only item 1's stencil view descriptors;
// AMD_BRONZE_VERBOSE=1 logs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL verbose(void) {
    static int v = -1;
    if (v < 0) {
        const char *setting = getenv("AMD_BRONZE_VERBOSE");
        v = setting && strcmp(setting, "0");
    }
    return v;
}

static BOOL disabled(const char *name) {
    const char *setting = getenv(name);
    return setting && !strcmp(setting, "0");
}

// True if the class itself (not a superclass) implements the method.
static BOOL definesMethod(Class c, SEL selector) {
    unsigned count = 0;
    Method *methods = c ? class_copyMethodList(c, &count) : NULL;
    BOOL found = NO;
    for (unsigned i = 0; i < count && !found; i++) found = method_getName(methods[i]) == selector;
    free(methods);
    return found;
}

static IMP swizzle(Class c, SEL selector, IMP replacement) {
    return definesMethod(c, selector) ? method_setImplementation(class_getInstanceMethod(c, selector), replacement) : NULL;
}

// ---- 1. Stencil through texture views ----------------------------------------------------------------------------
// -[BronzeMtlTexture initWithTexture:pixelFormat:textureType:levels:slices:swizzle:resourceIndex:] advances the view's
// mip table by levels.location and also subtracts it from the stencil-plane index (m_members+8, bits 21-25), so the view
// counts its first level twice: a stencil attachment that is a view of mip 1+ writes level 0 / slice 0, over existing
// data, or nothing where the test looks (wgpu zero_init, Dawn DepthStencilCopyTests, WebGPU CTS). After the original init,
// the parent's stencil index is put back when the field shows exactly that subtraction. Stencil8 views also ignore their
// base slice in the depth/stencil setup, so a Stencil8 attachment that is a view is attached as its parent with the
// view's level and slice added. Test: s17.
// The same init computes the image descriptor of a stencil view of a depth-stencil texture (X32_Stencil8 or
// X24_Stencil8 of Depth32Float_Stencil8 / Depth24Unorm_Stencil8) from that subtracted index and adds the first slice's
// offset as well, while the descriptor's BASE_LEVEL and BASE_ARRAY already select the view's level and slice: shaders
// reading such a view of level 1+ or slice 1+ read level 0 / slice 0 or somewhere else (Dawn backs WebGPU's stencil8 with
// Depth32Float_Stencil8 and reads it through such views). Its base address is set back to the stencil plane's start,
// which is what a view of the whole texture has, and copied to the device's descriptor table again. Test: s43.
//
// init methods consume self and return +1, so this hook stays outside ARC (void *): no retain or release gets added.
typedef void *(*ViewInitIMP)(void *, SEL, void *, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels,
                             NSUInteger);
static ViewInitIMP origViewInit;
static ptrdiff_t membersOffset, resOffset = -1;
// amdMtlBronzeDeviceSetGlobalSRD(device, table, index, dwords, descriptor, flag): the init's last step
// (amdMtlBronzeTextureCommonPostInit) copies the descriptor into the device's global table at m_members+0x50.
static void (*setGlobalSRD)(void *device, unsigned table, unsigned index, unsigned dwords, const void *descriptor, bool flag);

// A stencil view of a depth-stencil texture: point its image descriptor (MTLIOAccelResource _res, dword 0: address >> 8)
// at the start of the root texture's stencil plane, as -initWithTexture:pixelFormat:resourceIndex: does for a view of the
// whole texture: (table[stencil index].offset + resource address) >> 8 | the view's m_members+0x1c.
static void stencilViewBase(void *view, void *parent, MTLPixelFormat format) {
    if (resOffset < 0 || (format != MTLPixelFormatX32_Stencil8 && format != MTLPixelFormatX24_Stencil8 && format != MTLPixelFormatStencil8)) return;
    id root = (__bridge id)parent;
    while ([root parentTexture]) root = [root parentTexture];
    MTLPixelFormat rootFormat = [(id<MTLTexture>)root pixelFormat];
    if ((rootFormat != MTLPixelFormatDepth32Float_Stencil8 && rootFormat != MTLPixelFormatDepth24Unorm_Stencil8) ||
        object_getClass(root) != object_getClass((__bridge id)view))
        return;
    uint8_t *rootMembers = (uint8_t *)(__bridge void *)root + membersOffset, *table = *(uint8_t **)rootMembers;
    unsigned index = (*(uint64_t *)(rootMembers + 8) >> 21) & 31;
    if (!table || !index) return;
    uint64_t address = *(uint64_t *)((uint8_t *)(__bridge void *)root + resOffset + 0x48) + *(uint64_t *)(table + 64 * index + 8);
    uint32_t *descriptor = (uint32_t *)((uint8_t *)view + resOffset), base = (uint32_t)(address >> 8) | *(uint16_t *)((uint8_t *)view + membersOffset + 0x1c);
    if (descriptor[0] == base) return;
    unsigned slot = (unsigned)*(uint64_t *)((uint8_t *)view + membersOffset + 0x50);
    if (!setGlobalSRD || !slot) return;  // the copy the GPU reads couldn't be updated: leave both as they are
    if (verbose()) fprintf(stderr, "[bronzecompat] stencil view: descriptor base %08x -> %08x (slot %u)\n", descriptor[0], base, slot);
    descriptor[0] = base;
    setGlobalSRD((__bridge void *)[(__bridge id)view device], 0, slot, 8, descriptor, false);
}

static void *viewInit(void *self, SEL _cmd, void *parent, MTLPixelFormat format, MTLTextureType type, NSRange levels,
                      NSRange slices, MTLTextureSwizzleChannels swizzleChannels, NSUInteger resourceIndex) {
    void *view = origViewInit(self, _cmd, parent, format, type, levels, slices, swizzleChannels, resourceIndex);
    if (!view || !parent || object_getClass((__bridge id)parent) != object_getClass((__bridge id)view)) return view;
    if ((levels.location || slices.location || [(__bridge id)parent parentTexture]) && !disabled("AMD_BRONZE_STENCIL_VIEW"))
        stencilViewBase(view, parent, format);
    uint8_t *parentMembers = (uint8_t *)parent + membersOffset, *viewMembers = (uint8_t *)view + membersOffset;
    uint64_t parentField = *(uint64_t *)(parentMembers + 8), *viewField = (uint64_t *)(viewMembers + 8);
    unsigned parentIndex = (parentField >> 21) & 31, viewIndex = (*viewField >> 21) & 31;
    unsigned subtracted = *(uint16_t *)(parentMembers + 0x14) + (unsigned)levels.location;  // parent's relative level + first
    // The view's table starts levels.location entries into the parent's, and the index shows the subtraction
    if (!parentIndex || !subtracted || *(uint8_t **)viewMembers != *(uint8_t **)parentMembers + 64 * levels.location ||
        viewIndex != ((parentIndex - subtracted) & 31))
        return view;
    *viewField = (*viewField & ~(31ull << 21)) | ((uint64_t)parentIndex << 21);
    if (verbose()) fprintf(stderr, "[bronzecompat] view of level %lu slice %lu: stencil index %u -> %u\n",
                           (unsigned long)levels.location, (unsigned long)slices.location, viewIndex, parentIndex);
    return view;
}

static MTLRenderPassDescriptor *stencilViewToParent(MTLRenderPassDescriptor *descriptor) {
    id<MTLTexture> view = descriptor.stencilAttachment.texture;
    if (!origViewInit || view.pixelFormat != MTLPixelFormatStencil8 || !view.parentTexture) return descriptor;
    NSUInteger level = descriptor.stencilAttachment.level, slice = descriptor.stencilAttachment.slice;
    id<MTLTexture> root = view;
    while (root.parentTexture && root.parentTexture.pixelFormat == root.pixelFormat) {
        level += root.parentRelativeLevel;
        slice += root.parentRelativeSlice;
        root = root.parentTexture;
    }
    if (root == view || root.textureType == MTLTextureType3D) return descriptor;
    MTLRenderPassDescriptor *rewritten = [descriptor copy];
    rewritten.stencilAttachment.texture = root;
    rewritten.stencilAttachment.level = level;
    rewritten.stencilAttachment.slice = slice;
    if (verbose()) fprintf(stderr, "[bronzecompat] Stencil8 view attachment -> parent, level %lu slice %lu\n",
                           (unsigned long)level, (unsigned long)slice);
    return rewritten;
}

// The view init's `shl $0x15,%eax ; sub %eax,%edx`, at the same __TEXT offset in every copy of the driver.
static BOOL hasViewBug(const struct mach_header_64 *driver) {
    static const uint32_t kOffset = 0xa8233;
    static const uint8_t kCode[] = {0xc1, 0xe0, 0x15, 0x29, 0xc2};
    const struct load_command *command = (const struct load_command *)(driver + 1);
    for (uint32_t i = 0; i < driver->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        if (strcmp(segment->segname, SEG_TEXT)) continue;
        return segment->fileoff == 0 && segment->vmsize > kOffset + sizeof kCode &&
               !memcmp((const uint8_t *)driver + kOffset, kCode, sizeof kCode);
    }
    return NO;
}

static void installViewFix(const struct mach_header_64 *driver) {
    if (!hasViewBug(driver)) return;
    Class texture = objc_getClass("BronzeMtlTexture");
    Ivar members = texture ? class_getInstanceVariable(texture, "m_members") : NULL;
    if (!members) return;
    membersOffset = ivar_getOffset(members);
    Ivar res = class_getInstanceVariable(objc_getClass("MTLIOAccelResource"), "_res");
    if (res) resOffset = ivar_getOffset(res);
    setGlobalSRD = dlsym(RTLD_DEFAULT, "_Z30amdMtlBronzeDeviceSetGlobalSRDP15BronzeMtlDevicejjjPKvb");
    origViewInit = (ViewInitIMP)swizzle(texture, sel_registerName("initWithTexture:pixelFormat:textureType:levels:slices:swizzle:resourceIndex:"),
                                        (IMP)viewInit);
}

// ---- 2. sRGB mipmaps ---------------------------------------------------------------------------------------------
// -[BronzeMtlBlitCmdEncoder generateMipmapsForTexture:] runs the driver's stretch blit per level, which reads and writes
// sRGB texels as UNORM, so every level below 0 comes out too dark (WebGL 2 conformance tex-srgb-mipmap,
// MTKTextureLoader, Blender). The driver's blit stays and, when that encoder ends, levels 1..n of those textures are done
// again with one render pass per level and slice: sampling the sRGB source decodes, the linear filter averages the 2x2
// texels, the sRGB target encodes. Textures without RenderTarget|ShaderRead usage go through a temporary texture. Views
// and 3D textures stay as the driver left them, and a later blit in the same encoder still sees the driver's levels.
// Test: s12.
typedef void (*GenerateMipmapsIMP)(id, SEL, id);
typedef void (*EndEncodingIMP)(id, SEL);
static GenerateMipmapsIMP origGenerateMipmaps;
static EndEncodingIMP origEndEncoding;
static const void *kPendingMips = &kPendingMips;

static BOOL needsMipFix(id<MTLTexture> t) {
    MTLPixelFormat f = t.pixelFormat;
    MTLTextureType type = t.textureType;
    return (f == MTLPixelFormatRGBA8Unorm_sRGB || f == MTLPixelFormatBGRA8Unorm_sRGB) && t.mipmapLevelCount > 1 &&
           !t.parentTexture && !t.buffer && t.sampleCount == 1 &&
           (type == MTLTextureType2D || type == MTLTextureType2DArray || type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray);
}

static id<MTLRenderPipelineState> srgbPipeline(id<MTLDevice> device, MTLPixelFormat format, NSString *fragment) {
    static NSMutableDictionary *pipelines;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = [NSString stringWithFormat:@"%p-%lu-%@", device, (unsigned long)format, fragment];
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
        "}\n"
        "fragment float4 srgbResolveFragment(float4 position [[position]], texture2d_ms<float> source [[texture(0)]]) {\n"
        "    float4 sum = 0;\n"
        "    for (uint i = 0; i < source.get_num_samples(); i++) sum += source.read(uint2(position.xy), i);\n"
        "    return sum / source.get_num_samples();\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"srgbMipVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragment];
    descriptor.colorAttachments[0].pixelFormat = format;
    pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline) {
        if (verbose()) fprintf(stderr, "[bronzecompat] %s pipeline: %s\n", fragment.UTF8String, error.localizedDescription.UTF8String ?: "?");
        return nil;
    }
    os_unfair_lock_lock(&lock);
    if (!pipelines) pipelines = [NSMutableDictionary dictionary];
    pipelines[key] = pipeline;
    os_unfair_lock_unlock(&lock);
    return pipeline;
}

static void redoMips(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture) {
    id<MTLRenderPipelineState> pipeline = srgbPipeline(texture.device, texture.pixelFormat, @"srgbMipFragment");
    if (!pipeline) return;
    BOOL cube = texture.textureType == MTLTextureTypeCube || texture.textureType == MTLTextureTypeCubeArray;
    NSUInteger slices = texture.arrayLength * (cube ? 6 : 1), levels = texture.mipmapLevelCount;
    MTLTextureUsage needed = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> work = texture;
    if ((texture.usage & needed) != needed) {  // work in a temporary copy, then copy levels 1..n back
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
        descriptor.textureType = texture.textureType;
        descriptor.pixelFormat = texture.pixelFormat;
        descriptor.width = texture.width;
        descriptor.height = texture.height;
        descriptor.arrayLength = texture.arrayLength;
        descriptor.mipmapLevelCount = levels;
        descriptor.usage = needed;
        descriptor.storageMode = MTLStorageModePrivate;
        work = [texture.device newTextureWithDescriptor:descriptor];
        if (!work) return;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 toTexture:work destinationSlice:0 destinationLevel:0
                   sliceCount:slices levelCount:1];
        [blit endEncoding];
    }
    for (NSUInteger level = 1; level < levels; level++)
        for (NSUInteger slice = 0; slice < slices; slice++) {
            id<MTLTexture> source = [work newTextureViewWithPixelFormat:work.pixelFormat textureType:MTLTextureType2D
                                                                  levels:NSMakeRange(level - 1, 1) slices:NSMakeRange(slice, 1)];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = work;
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
    if (work != texture || texture.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (work != texture)
            [blit copyFromTexture:work sourceSlice:0 sourceLevel:1 toTexture:texture destinationSlice:0 destinationLevel:1
                       sliceCount:slices levelCount:levels - 1];
        if (texture.storageMode == MTLStorageModeManaged) [blit synchronizeResource:texture];  // one in the encoder saw old levels
        [blit endEncoding];
    }
}

static void generateMipmaps(id self, SEL _cmd, id<MTLTexture> texture) {
    origGenerateMipmaps(self, _cmd, texture);
    if (!needsMipFix(texture)) return;
    NSMutableArray *pending = objc_getAssociatedObject(self, kPendingMips);
    if (!pending) objc_setAssociatedObject(self, kPendingMips, pending = [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pending addObject:texture];
}

static void blitEndEncoding(id self, SEL _cmd) {
    NSArray *pending = objc_getAssociatedObject(self, kPendingMips);
    id<MTLCommandBuffer> commandBuffer = pending.count && [self respondsToSelector:@selector(commandBuffer)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(commandBuffer)) : nil;
    origEndEncoding(self, _cmd);
    if (!pending.count) return;
    objc_setAssociatedObject(self, kPendingMips, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!commandBuffer) return;
    if (verbose()) fprintf(stderr, "[bronzecompat] sRGB mipmaps redone for %lu texture(s)\n", (unsigned long)pending.count);
    for (id<MTLTexture> texture in pending) redoMips(commandBuffer, texture);
}

static void installMipFix(void) {
    Class blit = objc_getClass("BronzeMtlBlitCmdEncoder");
    if (!definesMethod(blit, @selector(generateMipmapsForTexture:)) || !definesMethod(blit, @selector(endEncoding))) return;
    origGenerateMipmaps = (GenerateMipmapsIMP)swizzle(blit, @selector(generateMipmapsForTexture:), (IMP)generateMipmaps);
    origEndEncoding = (EndEncodingIMP)swizzle(blit, @selector(endEncoding), (IMP)blitEndEncoding);
}

// ---- 3. Trilinear filtering --------------------------------------------------------------------------------------
// -[BronzeMtlSampler initWithDevice:samplerDescriptor:] sets SQ_IMG_SAMP_WORD1.PERF_MIP = 6 in every sampler, so with
// mipFilter Linear the GPU reads a single level near whole levels and blends only in between (a sample at level 0.25
// returns 0.19 of the way to the next level, at 0.75 0.81). Apple's GPUs blend linearly, and Blender EEVEE's horizon scan
// relies on it: it samples its depth pyramid just above a whole level, and with the sharpened blend the light of bright
// emitters went missing on nearby surfaces. PERF_MIP is cleared and the descriptor registered again in the driver's
// global table, which the GPU reads it from: samplers with a resource index (argument buffers) own their slot, the
// others share a slot per distinct descriptor. Samples near whole levels now read two levels: a kernel that does nothing
// but sample textures takes up to ~12% longer (more only if nearly every sample sits just above a whole level); Blender's
// render times didn't change. Test: s19.
//
// Outside ARC for the same reason as the view init.
typedef void *(*SamplerInitIMP)(void *, SEL, void *, void *);
static SamplerInitIMP origSamplerInit;
static uint64_t (*setSharedSamplerSRD)(void *device, unsigned kind, unsigned dwords, const unsigned *srd);
static void (*setSamplerSRD)(void *device, unsigned kind, unsigned index, unsigned dwords, const void *srd, bool unique);
static ptrdiff_t samplerConstsOffset, samplerIndexOffset;
enum { kPerfMipMask = 0x0f000000 };  // SQ_IMG_SAMP_WORD1 bits 24-27

static void *samplerInit(void *self, SEL _cmd, void *device, void *descriptor) {
    self = origSamplerInit(self, _cmd, device, descriptor);
    if (!self) return self;
    uint32_t *srd = (uint32_t *)((char *)self + samplerConstsOffset);
    if (!(srd[1] & kPerfMipMask)) return self;
    srd[1] &= ~(uint32_t)kPerfMipMask;
    id samplerDescriptor = (__bridge id)descriptor;
    SEL resourceIndexSelector = sel_registerName("resourceIndex");
    NSUInteger resourceIndex = [samplerDescriptor respondsToSelector:resourceIndexSelector]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(samplerDescriptor, resourceIndexSelector) : 0;
    if (resourceIndex)
        setSamplerSRD(device, 1, (unsigned)resourceIndex, 4, srd, true);
    else
        *(uint64_t *)((char *)self + samplerIndexOffset) = setSharedSamplerSRD(device, 1, 4, srd);
    return self;
}

static void installTrilinearFix(const char *driverPath) {
    Class sampler = objc_getClass("BronzeMtlSampler");
    Ivar consts = sampler ? class_getInstanceVariable(sampler, "m_samplerConsts") : NULL;
    Ivar resourceIndex = sampler ? class_getInstanceVariable(sampler, "rsrcIndex") : NULL;
    void *driver = dlopen(driverPath, RTLD_NOLOAD | RTLD_LAZY);
    setSharedSamplerSRD = driver ? dlsym(driver, "_Z39amdMtlBronzeDeviceSetNonUniqueGlobalSrdP15BronzeMtlDevicejjPKj") : NULL;
    setSamplerSRD = driver ? dlsym(driver, "_Z30amdMtlBronzeDeviceSetGlobalSRDP15BronzeMtlDevicejjjPKvb") : NULL;
    if (!consts || !resourceIndex || !setSharedSamplerSRD || !setSamplerSRD || strcmp(ivar_getTypeEncoding(resourceIndex), "Q") ||
        !strstr(ivar_getTypeEncoding(consts), "\"MIN_LOD\"b12\"MAX_LOD\"b12\"PERF_MIP\"b4\"PERF_Z\"b4"))
        return;
    samplerConstsOffset = ivar_getOffset(consts);
    samplerIndexOffset = ivar_getOffset(resourceIndex);
    origSamplerInit = (SamplerInitIMP)swizzle(sampler, sel_registerName("initWithDevice:samplerDescriptor:"), (IMP)samplerInit);
}

// ---- 4. sRGB MSAA resolve ------------------------------------------------------------------------------------------
// The driver's resolve averages the encoded bytes of an sRGB attachment instead of the linear values, so antialiased
// edges come out too dark (WebGPU conformance render_pass,resolve:render_pass_resolve). The resolve is taken off the pass,
// which stores its samples instead, and when the encoder ends one render pass per attachment reads the samples (decoded),
// averages them and writes the target (encoded). Only 2D multisample attachments whose store action is known when the
// pass starts; a deferred store action or a parallel encoder keeps the driver's resolve. Test: s25.
typedef id (*RenderEncoderIMP)(id, SEL, MTLRenderPassDescriptor *);
static RenderEncoderIMP origRenderEncoder;
static EndEncodingIMP origRenderEndEncoding;
static BOOL srgbResolveFix;
static const void *kPendingResolves = &kPendingResolves, *kResolveCommandBuffer = &kResolveCommandBuffer;
static MTLRenderPassDescriptor *routeDepthMipStencil(id<MTLCommandBuffer> commandBuffer, MTLRenderPassDescriptor *descriptor,
                                                     NSArray **route);  // item 10
static void finishDepthMipRoute(id<MTLCommandBuffer> commandBuffer, NSArray *route);
static const void *kDepthMipRoute = &kDepthMipRoute;
static BOOL depthMipFixInstalled(void);  // item 10

static MTLRenderPassDescriptor *takeSrgbResolves(MTLRenderPassDescriptor *descriptor, NSMutableArray **resolves) {
    MTLRenderPassDescriptor *rewritten = nil;
    for (NSUInteger i = 0; srgbResolveFix && i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *attachment = descriptor.colorAttachments[i];
        id<MTLTexture> texture = attachment.texture;
        MTLPixelFormat f = texture.pixelFormat;
        MTLStoreAction store = attachment.storeAction;
        if (!attachment.resolveTexture || texture.textureType != MTLTextureType2DMultisample ||
            (f != MTLPixelFormatRGBA8Unorm_sRGB && f != MTLPixelFormatBGRA8Unorm_sRGB) ||
            (store != MTLStoreActionMultisampleResolve && store != MTLStoreActionStoreAndMultisampleResolve) ||
            !srgbPipeline(texture.device, f, @"srgbResolveFragment"))
            continue;
        if (!rewritten) {
            rewritten = [descriptor copy];
            *resolves = [NSMutableArray array];
        }
        [*resolves addObject:[attachment copy]];
        rewritten.colorAttachments[i].resolveTexture = nil;
        rewritten.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    return rewritten ?: descriptor;
}

static id renderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    NSMutableArray *resolves = nil;
    NSArray *route = nil;
    MTLRenderPassDescriptor *fixed = takeSrgbResolves(stencilViewToParent(descriptor), &resolves);
    fixed = routeDepthMipStencil(self, fixed, &route);
    id encoder = origRenderEncoder(self, _cmd, fixed);
    if (encoder && (resolves || route)) {
        objc_setAssociatedObject(encoder, kPendingResolves, resolves, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder, kDepthMipRoute, route, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder, kResolveCommandBuffer, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

static void renderEndEncoding(id self, SEL _cmd) {
    NSArray *resolves = objc_getAssociatedObject(self, kPendingResolves);
    NSArray *route = objc_getAssociatedObject(self, kDepthMipRoute);
    id<MTLCommandBuffer> commandBuffer = objc_getAssociatedObject(self, kResolveCommandBuffer);
    origRenderEndEncoding(self, _cmd);
    if (!resolves && !route) return;
    objc_setAssociatedObject(self, kPendingResolves, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kDepthMipRoute, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kResolveCommandBuffer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (route) finishDepthMipRoute(commandBuffer, route);
    if (!resolves) return;
    if (verbose()) fprintf(stderr, "[bronzecompat] %lu sRGB attachment(s) resolved in a shader\n", (unsigned long)resolves.count);
    for (MTLRenderPassColorAttachmentDescriptor *attachment in resolves) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = attachment.resolveTexture;
        pass.colorAttachments[0].level = attachment.resolveLevel;
        pass.colorAttachments[0].slice = attachment.resolveSlice;
        pass.colorAttachments[0].depthPlane = attachment.resolveDepthPlane;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:srgbPipeline(attachment.texture.device, attachment.texture.pixelFormat, @"srgbResolveFragment")];
        [encoder setFragmentTexture:attachment.texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
}

static void installRenderPassHooks(void) {
    Class commandBuffer = objc_getClass("BronzeMtlCmdBuffer"), encoder = objc_getClass("BronzeMtlRenderCmdEncoder");
    if (!definesMethod(commandBuffer, @selector(renderCommandEncoderWithDescriptor:))) return;
    BOOL srgbResolve = !disabled("AMD_BRONZE_SRGB_RESOLVE");
    if (definesMethod(encoder, @selector(endEncoding)) && (srgbResolve || depthMipFixInstalled()))
        origRenderEndEncoding = (EndEncodingIMP)swizzle(encoder, @selector(endEncoding), (IMP)renderEndEncoding);
    srgbResolveFix = srgbResolve && origRenderEndEncoding;
    if (origViewInit || origRenderEndEncoding)
        origRenderEncoder = (RenderEncoderIMP)swizzle(commandBuffer, @selector(renderCommandEncoderWithDescriptor:), (IMP)renderEncoder);
}

// ---- 5. Depth or stencil to a buffer with row pitch 0 --------------------------------------------------------------
// wgpu passes destinationBytesPerRow 0 when WebGPU leaves bytesPerRow out, as it may for a single row. The driver takes that
// for colour, but for one aspect of a combined depth/stencil texture it writes nothing (WebGPU conformance
// render_pass,clear_value:stencil_clear_value in Firefox). A zero pitch becomes the tightly packed one. Test: s26.
typedef void (*CopyToBufferIMP)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger, MTLBlitOption);
static CopyToBufferIMP origCopyToBuffer;

static void copyToBuffer(id self, SEL _cmd, id texture, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size, id buffer,
                         NSUInteger offset, NSUInteger bytesPerRow, NSUInteger bytesPerImage, MTLBlitOption options) {
    NSUInteger bytes = options & MTLBlitOptionStencilFromDepthStencil ? 1 : options & MTLBlitOptionDepthFromDepthStencil ? 4 : 0;
    if (bytes && !bytesPerRow) bytesPerRow = size.width * bytes;
    if (bytes && !bytesPerImage) bytesPerImage = bytesPerRow * size.height;
    origCopyToBuffer(self, _cmd, texture, slice, level, origin, size, buffer, offset, bytesPerRow, bytesPerImage, options);
}

static void installCopyFix(void) {
    Class blit = objc_getClass("BronzeMtlBlitCmdEncoder");
    SEL selector = @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:options:);
    if (definesMethod(blit, selector)) origCopyToBuffer = (CopyToBufferIMP)swizzle(blit, selector, (IMP)copyToBuffer);
}

// ---- 6. Vertex strides that aren't a multiple of 4, in WebKit -----------------------------------------------------------
// For a draw of one vertex, WebKit's WebGPU (RenderPipeline::recomputeLastStrideAsStride) copies the pipeline with the stride
// set to the end of the last attribute, which can be any size: 2 for snorm8x2. This driver refuses that ("Buffer stride is
// not a multiple of 4 bytes"), WebKit then draws with no pipeline set, and the driver crashes on a null pointer, which takes
// down Safari's GPU process (WebGPU CTS api,validation,encoding,cmds,render,draw:vertex_buffer_OOB). The next multiple of 4
// fetches the same vertex. Only in WebKit: for anyone else the error is the API's answer. Test: s29.
typedef void (*SetStrideIMP)(id, SEL, NSUInteger);
static SetStrideIMP origSetStride;

static void setStride(id self, SEL _cmd, NSUInteger stride) {
    if (stride != NSUIntegerMax) stride = (stride + 3) & ~(NSUInteger)3;  // NSUIntegerMax: MTLBufferLayoutStrideDynamic
    origSetStride(self, _cmd, stride);
}

// WebKit's WebGPU sets GPUMultisampleState.mask with the descriptor's sample mask. This driver takes 0 to mean no mask and
// draws every sample, where nothing should be drawn (WebGPU CTS occlusionQuery sample_mask, sampleMask=0). A bit past the
// last sample of any target isn't 0 to the driver and covers no sample. Only WebKit calls this. Test: s30.
typedef void (*SetSampleMaskIMP)(id, SEL, NSUInteger);
static SetSampleMaskIMP origSetSampleMask;

static void setSampleMask(id self, SEL _cmd, NSUInteger mask) {
    origSetSampleMask(self, _cmd, mask ? mask : 0x100);
}

static void installWebKitFixes(void) {
    if (strncmp(getprogname(), "com.apple.WebKit", 16)) return;
    origSetStride = (SetStrideIMP)swizzle(objc_getClass("MTLVertexBufferLayoutDescriptorInternal"), @selector(setStride:), (IMP)setStride);
    origSetSampleMask = (SetSampleMaskIMP)swizzle(objc_getClass("MTLRenderPipelineDescriptorInternal"), @selector(setSampleMask:), (IMP)setSampleMask);
}

// ---- 8. Memoryless textures ------------------------------------------------------------------------------------------
// MTLStorageModeMemoryless needs tile memory, which only Apple GPUs have, and for this driver's device macOS 26's Metal aborts
// the process on it (-[MTLTextureDescriptorInternal validateWithDevice:], called by the driver's texture init). Apps check
// supportsFamily:Apple*, which this device answers NO, but some versions of WebKit's WebGPU asked for it for every transient
// attachment (WebGPU conformance render_pass,resolve). The driver gets a copy of the descriptor with private storage,
// so the app's descriptor stays as it was; the texture then takes video memory, as it would on any GPU but Apple's. Only
// newTextureWithDescriptor: is hooked: heap, buffer and IOSurface textures take their storage from what backs them. Test: s27.
typedef void *(*NewTextureIMP)(void *, SEL, void *);
static NewTextureIMP origNewTexture;
static BOOL memorylessFix;
static BOOL needsDepthMipLayout(MTLTextureDescriptor *descriptor);
static __thread BOOL creatingDepthMips;  // item 10
static __thread uint32_t changedDepthLevels;  // item 10: levels whose depth plane lost the stencil padding
static void markDepthMipTexture(void *texture, uint32_t levels);

static void *newTexture(void *self, SEL _cmd, void *descriptor) {
    MTLTextureDescriptor *requested = (__bridge MTLTextureDescriptor *)descriptor;
    if (memorylessFix && requested.storageMode == MTLStorageModeMemoryless) {
        requested = [requested copy];
        requested.storageMode = MTLStorageModePrivate;
        if (verbose()) fprintf(stderr, "[bronzecompat] memoryless texture made private\n");
    }
    BOOL outer = creatingDepthMips;
    uint32_t outerLevels = changedDepthLevels;
    creatingDepthMips = needsDepthMipLayout(requested);
    changedDepthLevels = 0;
    void *texture = origNewTexture(self, _cmd, (__bridge void *)requested);
    if (texture && creatingDepthMips && changedDepthLevels) markDepthMipTexture(texture, changedDepthLevels);
    creatingDepthMips = outer;
    changedDepthLevels = outerLevels;
    return texture;
}

static void installNewTextureHook(void) {
    origNewTexture = (NewTextureIMP)swizzle(objc_getClass("BronzeMtlDevice"), @selector(newTextureWithDescriptor:), (IMP)newTexture);
}

// ---- 9. MSL 3.2 device coherence ----------------------------------------------------------------------------------
// MSL 3.2 (macOS 15) added memory coherence, and SPIRV-Cross (MoltenVK) uses it for every Vulkan Coherent storage buffer
// (`coherent device T *`). This driver's compiler fails any buffer with device coherence when the pipeline is made
// ("Compiler encountered an internal error"), so the Vulkan pipeline isn't created. Metal implements coherence for
// Apple silicon only, so on these GPUs it means what volatile means in 3.1, which is how MetalOldCompat item 9 rewrites
// it on MetalOld. Here only the failing forms are rewritten (`coherent(device)` and `coherent device` -> `volatile`),
// in source compiled on this driver's device as MSL 3.2 or newer. Coherent textures and threadgroup coherence compile.
// Test: s09.
typedef id (*NewLibrarySyncIMP)(id, SEL, NSString *, MTLCompileOptions *, NSError **) __attribute__((ns_returns_retained));
typedef void (*NewLibraryAsyncIMP)(id, SEL, NSString *, MTLCompileOptions *, id);

static NSString *withoutDeviceCoherence(NSString *source, MTLCompileOptions *options) {
    if (!source || [source rangeOfString:@"coherent"].location == NSNotFound) return source;
    if (options && options.languageVersion < (MTLLanguageVersion)0x30002 /* 3.2; no options = the newest */) return source;
    static NSRegularExpression *qualifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        qualifier = [NSRegularExpression regularExpressionWithPattern:@"\\bcoherent(?:\\s*\\(\\s*device\\s*\\)|(?=\\s+device\\b))"
                                                              options:0 error:nil];
    });
    NSString *rewritten = [qualifier stringByReplacingMatchesInString:source options:0 range:NSMakeRange(0, source.length)
                                                         withTemplate:@"volatile"];
    if (verbose() && ![rewritten isEqualToString:source]) fprintf(stderr, "[bronzecompat] MSL device coherence compiled as volatile\n");
    return rewritten;
}

// Metal's _MTLDevice implements both; the driver's device gets its own, which call the inherited one.
static IMP inherited(SEL selector) {
    return class_getMethodImplementation(class_getSuperclass(objc_getClass("BronzeMtlDevice")), selector);
}

static id newLibrarySync(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, NSError **error) __attribute__((ns_returns_retained));
static id newLibrarySync(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, NSError **error) {
    return ((NewLibrarySyncIMP)inherited(_cmd))(self, _cmd, withoutDeviceCoherence(source, options), options, error);
}

static void newLibraryAsync(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, id handler) {
    ((NewLibraryAsyncIMP)inherited(_cmd))(self, _cmd, withoutDeviceCoherence(source, options), options, handler);
}

static BOOL installCoherenceFix(void) {
    Class device = objc_getClass("BronzeMtlDevice");
    return device &&
           class_addMethod(device, @selector(newLibraryWithSource:options:error:), (IMP)newLibrarySync, "@@:@@^@") &&
           class_addMethod(device, @selector(newLibraryWithSource:options:completionHandler:), (IMP)newLibraryAsync, "v@:@@@?");
}

// ---- 10. Depth of mipmapped depth-stencil textures read by shaders ------------------------------------------------
// For the depth plane of Depth24Unorm_Stencil8 and Depth32Float_Stencil8 the driver asks AMD's addrlib
// (AddrComputeSurfaceInfo) for a layout with a separate stencil plane (noStencil off). addrlib then pads the pitch of small
// levels to what the stencil plane needs, since the depth unit addresses both planes with one pitch, and warns in its own
// source that "this actually does not work for mipmap". The texture unit doesn't know about the padding, so shaders read
// the depth of levels 4 or fewer texels wide (and 8x1, 8x2, 8x4, 8x16) from the wrong place: in WebGL, depth24_stencil8
// shadow lookups and texture storage checks (dEQP textureshadow, texstorage*_format_depth_stencil). Render passes and
// blits agree with each other, so only shader reads show it. radeonsi does what this does: mipmapped depth-stencil
// surfaces get their depth plane without the padding ("Keep the depth mip-tail compatible with texturing", Mesa's
// ac_surface.c), here for textures made with ShaderRead usage through newTextureWithDescriptor:.
// What's left, as in radeonsi: at levels 16 tall and 8 or fewer wide the stencil plane needs a larger pitch than the depth
// plane now has, and the depth unit uses the depth plane's, so stencil written by render passes there reads back
// differently through blits and shaders (radeonsi copies stencil through the depth unit; WebGL never reads stencil back).
// The driver calls AddrComputeSurfaceInfo directly, so its entry is patched, after checking its first instructions (the
// same in every copy of the driver), to run the depth-plane call with noStencil set while such a texture is made.
// AMD_BRONZE_DEPTH_MIPS=0 turns it off. Test: s44.
typedef int (*AddrComputeSurfaceInfoFn)(void *, const void *, void *);
static AddrComputeSurfaceInfoFn origAddrComputeSurfaceInfo;  // a copy of the patched entry instructions, then a jump back

// ADDR_COMPUTE_SURFACE_INFO_INPUT (addrinterface.h): the fields used here.
enum { kAddrInputSize = 0x58, kAddrInputSamples = 0x10, kAddrInputFlags = 0x2c };
enum { kAddrFlagDepth = 1u << 1, kAddrFlagNoStencil = 1u << 10 };
enum { kAddrInputMipLevel = 0x24 };
// ADDR_COMPUTE_SURFACE_INFO_OUTPUT: size u32 @0, pitch @4, height @8.
enum { kAddrOutputPitch = 4, kAddrOutputHeight = 8, kAddrOutputMaxSize = 512 };

static BOOL needsDepthMipLayout(MTLTextureDescriptor *descriptor) {
    MTLPixelFormat format = descriptor.pixelFormat;
    return origAddrComputeSurfaceInfo && descriptor.mipmapLevelCount > 1 && descriptor.sampleCount <= 1 &&
           (descriptor.usage & MTLTextureUsageShaderRead) &&
           (format == MTLPixelFormatDepth24Unorm_Stencil8 || format == MTLPixelFormatDepth32Float_Stencil8);
}

static int addrComputeSurfaceInfo(void *lib, const void *in, void *out) {
    uint32_t size, flags, samples;
    if (creatingDepthMips && in) {
        memcpy(&size, in, 4);
        memcpy(&flags, (const char *)in + kAddrInputFlags, 4);
        memcpy(&samples, (const char *)in + kAddrInputSamples, 4);
        if (size == kAddrInputSize && (flags & kAddrFlagDepth) && !(flags & kAddrFlagNoStencil) && samples <= 1) {
            // The padded layout first, to know whether this level changes (see the routing below).
            uint32_t outSize, level, padded[2], plain[2];
            memcpy(&outSize, out, 4);
            memcpy(&level, (const char *)in + kAddrInputMipLevel, 4);
            char scratch[kAddrOutputMaxSize];
            BOOL compared = outSize >= kAddrOutputHeight + 4 && outSize <= sizeof scratch;
            if (compared) {
                memcpy(scratch, out, outSize);
                if (origAddrComputeSurfaceInfo(lib, in, scratch)) compared = NO;
                memcpy(padded, scratch + kAddrOutputPitch, 8);
            }
            char input[kAddrInputSize];
            memcpy(input, in, sizeof input);
            flags |= kAddrFlagNoStencil;
            memcpy(input + kAddrInputFlags, &flags, 4);
            int result = origAddrComputeSurfaceInfo(lib, input, out);
            memcpy(plain, (const char *)out + kAddrOutputPitch, 8);
            if (!result && level < 32 && (!compared || memcmp(padded, plain, 8))) changedDepthLevels |= 1u << level;
            return result;
        }
    }
    return origAddrComputeSurfaceInfo(lib, in, out);
}

// What the depth unit can't follow: it addresses the stencil plane with the depth plane's pitch and slice size, which
// match only while the depth plane keeps the padding. On a level that lost it, render passes would read and write
// stencil away from where blits and shaders have it (stencil tests against blitted stencil fail, from the first slice
// after 0, and at some levels already on slice 0). radeonsi works around the same thing by copying stencil through the
// depth unit; here a render pass whose stencil attachment is such a level goes through a one-level 2D texture of the same
// format: the subresource's depth and stencil are copied in (if the pass loads them), the pass renders there, and they are
// copied back when the encoder ends (if the pass stores them), each way through buffers, which use the stencil plane's own
// layout, as shaders do.
// Parallel render encoders aren't routed.
static const void *kDepthMipLevels = &kDepthMipLevels;

static BOOL depthMipFixInstalled(void) { return origAddrComputeSurfaceInfo != NULL; }

static void markDepthMipTexture(void *texture, uint32_t levels) {
    objc_setAssociatedObject((__bridge id)texture, kDepthMipLevels, @(levels), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Depth and stencil of one subresource into another, through buffers: a texture-to-texture copy writes depth-stencil
// through the depth unit, which on such a level doesn't put stencil where blits and shaders read it. Two encoders, so the
// copies into the buffers are done before the copies out of them.
static void copyDepthStencil(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> from, NSUInteger fromLevel, NSUInteger fromSlice,
                             id<MTLTexture> to, NSUInteger toLevel, NSUInteger toSlice, MTLSize size) {
    NSUInteger pixels = size.width * size.height;
    id<MTLBuffer> depth = [from.device newBufferWithLength:pixels * 4 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> stencil = [from.device newBufferWithLength:pixels options:MTLResourceStorageModePrivate];
    MTLOrigin zero = MTLOriginMake(0, 0, 0);
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:from sourceSlice:fromSlice sourceLevel:fromLevel sourceOrigin:zero sourceSize:size toBuffer:depth destinationOffset:0
        destinationBytesPerRow:size.width * 4 destinationBytesPerImage:pixels * 4 options:MTLBlitOptionDepthFromDepthStencil];
    [blit copyFromTexture:from sourceSlice:fromSlice sourceLevel:fromLevel sourceOrigin:zero sourceSize:size toBuffer:stencil destinationOffset:0
        destinationBytesPerRow:size.width destinationBytesPerImage:pixels options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding];
    blit = [commandBuffer blitCommandEncoder];
    [blit copyFromBuffer:depth sourceOffset:0 sourceBytesPerRow:size.width * 4 sourceBytesPerImage:pixels * 4 sourceSize:size toTexture:to
        destinationSlice:toSlice destinationLevel:toLevel destinationOrigin:zero options:MTLBlitOptionDepthFromDepthStencil];
    [blit copyFromBuffer:stencil sourceOffset:0 sourceBytesPerRow:size.width sourceBytesPerImage:pixels sourceSize:size toTexture:to
        destinationSlice:toSlice destinationLevel:toLevel destinationOrigin:zero options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding];
}

// route: @[temporary, texture, level, slice, size (NSValue of MTLSize), copy back]
static MTLRenderPassDescriptor *routeDepthMipStencil(id<MTLCommandBuffer> commandBuffer, MTLRenderPassDescriptor *descriptor,
                                                     NSArray **route) {
    MTLRenderPassStencilAttachmentDescriptor *stencil = descriptor.stencilAttachment;
    id<MTLTexture> texture = stencil.texture;
    if (!origAddrComputeSurfaceInfo || !texture) return descriptor;
    NSUInteger level = stencil.level, slice = stencil.slice;
    while (texture.parentTexture) {  // views: the texture that owns the layout
        level += texture.parentRelativeLevel;
        slice += texture.parentRelativeSlice;
        texture = texture.parentTexture;
    }
    NSNumber *levels = objc_getAssociatedObject(texture, kDepthMipLevels);
    if (!levels || level >= 32 || !(levels.unsignedIntValue & 1u << level)) return descriptor;
    MTLRenderPassDepthAttachmentDescriptor *depth = descriptor.depthAttachment;
    id<MTLTexture> depthTexture = depth.texture;
    if (depthTexture && (depthTexture != stencil.texture || depth.level != stencil.level || depth.slice != stencil.slice))
        return descriptor;  // depth from somewhere else: leave the pass as it is
    MTLSize size = MTLSizeMake(MAX(texture.width >> level, 1), MAX(texture.height >> level, 1), 1);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat width:size.width
                                                                                height:size.height mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> temporary = [texture.device newTextureWithDescriptor:td];
    if (!temporary) return descriptor;
    BOOL load = stencil.loadAction == MTLLoadActionLoad || (depthTexture && depth.loadAction == MTLLoadActionLoad);
    BOOL store = stencil.storeAction != MTLStoreActionDontCare || (depthTexture && depth.storeAction != MTLStoreActionDontCare);
    if (load) copyDepthStencil(commandBuffer, texture, level, slice, temporary, 0, 0, size);
    MTLRenderPassDescriptor *rewritten = [descriptor copy];
    rewritten.stencilAttachment.texture = temporary;
    rewritten.stencilAttachment.level = 0;
    rewritten.stencilAttachment.slice = 0;
    if (depthTexture) {
        rewritten.depthAttachment.texture = temporary;
        rewritten.depthAttachment.level = 0;
        rewritten.depthAttachment.slice = 0;
    }
    if (stencil.storeAction == MTLStoreActionUnknown) rewritten.stencilAttachment.storeAction = MTLStoreActionStore;
    if (depthTexture && depth.storeAction == MTLStoreActionUnknown) rewritten.depthAttachment.storeAction = MTLStoreActionStore;
    *route = @[temporary, texture, @(level), @(slice), [NSValue valueWithBytes:&size objCType:@encode(MTLSize)], @(store)];
    if (verbose()) fprintf(stderr, "[bronzecompat] depth-stencil level %lu slice %lu rendered through a temporary\n",
                           (unsigned long)level, (unsigned long)slice);
    return rewritten;
}

static void finishDepthMipRoute(id<MTLCommandBuffer> commandBuffer, NSArray *route) {
    if (![route[5] boolValue]) return;
    MTLSize size;
    [route[4] getValue:&size];
    copyDepthStencil(commandBuffer, route[0], 0, 0, route[1], [route[2] unsignedIntegerValue], [route[3] unsignedIntegerValue], size);
}

// push rbp; mov rbp, rsp; push r14; push rbx; mov r14, rdx; mov rbx, rsi: nothing in them depends on where they run.
static const uint8_t kAddrPrologue[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x56, 0x53, 0x49, 0x89, 0xd6, 0x48, 0x89, 0xf3};

static uint8_t *emitJump(uint8_t *p, const void *target) {  // mov rax, target; jmp rax
    p[0] = 0x48, p[1] = 0xb8;
    memcpy(p + 2, &target, 8);
    p[10] = 0xff, p[11] = 0xe0;
    return p + 12;
}

static void installDepthMipFix(const char *driverPath) {
    void *driver = dlopen(driverPath, RTLD_NOLOAD | RTLD_LAZY);
    uint8_t *entry = driver ? dlsym(driver, "AddrComputeSurfaceInfo") : NULL;
    if (!entry || memcmp(entry, kAddrPrologue, sizeof kAddrPrologue)) return;
    uint8_t *trampoline = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED) return;
    memcpy(trampoline, kAddrPrologue, sizeof kAddrPrologue);
    emitJump(trampoline + sizeof kAddrPrologue, entry + sizeof kAddrPrologue);
    if (mprotect(trampoline, vm_page_size, PROT_READ | PROT_EXEC)) return;
    vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) return;
    origAddrComputeSurfaceInfo = (AddrComputeSurfaceInfoFn)trampoline;
    uint8_t patch[12];
    emitJump(patch, (const void *)addrComputeSurfaceInfo);
    memcpy(entry, patch, sizeof patch);
    vm_protect(mach_task_self(), page, vm_page_size * 2, false, VM_PROT_READ | VM_PROT_EXECUTE);
}

// This library is a dependency of the driver, so its initializer runs after the driver is mapped and its classes are
// registered with the ObjC runtime, but before any driver code runs. No driver loaded: nothing to do.
__attribute__((constructor)) static void init(void) {
    if (disabled("AMD_BRONZE_COMPAT")) return;
    static const char kSuffix[] = "/AMDMTLBronzeDriver.bundle/Contents/MacOS/AMDMTLBronzeDriver";
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t length = name ? strlen(name) : 0;
        if (length < sizeof kSuffix - 1 || strcmp(name + length - (sizeof kSuffix - 1), kSuffix)) continue;
        installViewFix((const struct mach_header_64 *)_dyld_get_image_header(i));
        installMipFix();
        if (!disabled("AMD_BRONZE_DEPTH_MIPS")) installDepthMipFix(name);  // before the render pass hooks, which route for it
        installRenderPassHooks();
        installCopyFix();
        installWebKitFixes();
        memorylessFix = !disabled("AMD_BRONZE_MEMORYLESS");
        installNewTextureHook();
        if (!disabled("AMD_EXACT_TRILINEAR")) installTrilinearFix(name);
        BOOL coherence = installCoherenceFix();
        if (verbose()) fprintf(stderr, "[bronzecompat] view fix %s, sRGB mipmaps %s, trilinear %s, sRGB resolve %s, copy pitch %s, memoryless %s, "
                               "device coherence %s, depth mips %s\n",
                               origViewInit ? "on" : "off", origGenerateMipmaps ? "on" : "off", origSamplerInit ? "on" : "off",
                               srgbResolveFix ? "on" : "off", origCopyToBuffer ? "on" : "off",
                               origNewTexture && memorylessFix ? "on" : "off", coherence ? "on" : "off",
                               origNewTexture && origAddrComputeSurfaceInfo ? "on" : "off");
        return;
    }
}
