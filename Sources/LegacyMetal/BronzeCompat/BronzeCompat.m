// AMDBronzeCompat.dylib: fixes for bugs in OCLP's 12.5 AMD Metal driver (AMDMTLBronzeDriver: GCN), in every process
// that uses the driver. It's loaded by a weak load command added to the driver itself, so it reaches every Mac and macOS
// that runs this driver, whether or not OCLP's MetalOld wrapper is installed (AMD-only Macs such as the MacPro6,1 don't
// have the wrapper). The driver is the same code in all of PatcherSupportPkg's copies (12.5, 12.5-24, 12.5-25,
// 12.5-GCN-SKL-*); each hook checks for what it relies on and stays out otherwise.
//   1. stencil through texture views of mip 1+ (written to the wrong level and slice)
//   2. sRGB mipmaps (the driver's blit averages the encoded bytes)
//   3. trilinear filtering (blends between mip levels only in the middle of the interval)
//   4. sRGB MSAA resolve (the hardware resolve averages the encoded bytes)
//   5. depth or stencil copied to a buffer with row pitch 0 (nothing gets written)
// 1 and 2 come from riptidewave93's bronzefix, found and tested on Tahoe with a MacPro6,1's FirePro D700s.
// AMD_BRONZE_COMPAT=0 turns everything off for a process, AMD_EXACT_TRILINEAR=0 only item 3; AMD_BRONZE_VERBOSE=1 logs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/lock.h>
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
//
// init methods consume self and return +1, so this hook stays outside ARC (void *): no retain or release gets added.
typedef void *(*ViewInitIMP)(void *, SEL, void *, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels,
                             NSUInteger);
static ViewInitIMP origViewInit;
static ptrdiff_t membersOffset;

static void *viewInit(void *self, SEL _cmd, void *parent, MTLPixelFormat format, MTLTextureType type, NSRange levels,
                      NSRange slices, MTLTextureSwizzleChannels swizzleChannels, NSUInteger resourceIndex) {
    void *view = origViewInit(self, _cmd, parent, format, type, levels, slices, swizzleChannels, resourceIndex);
    if (!view || !parent || object_getClass((__bridge id)parent) != object_getClass((__bridge id)view)) return view;
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
static const void *kPendingResolves = &kPendingResolves, *kResolveCommandBuffer = &kResolveCommandBuffer;

static MTLRenderPassDescriptor *takeSrgbResolves(MTLRenderPassDescriptor *descriptor, NSMutableArray **resolves) {
    MTLRenderPassDescriptor *rewritten = nil;
    for (NSUInteger i = 0; origRenderEndEncoding && i < 8; i++) {
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
    MTLRenderPassDescriptor *fixed = takeSrgbResolves(stencilViewToParent(descriptor), &resolves);
    id encoder = origRenderEncoder(self, _cmd, fixed);
    if (encoder && resolves) {
        objc_setAssociatedObject(encoder, kPendingResolves, resolves, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder, kResolveCommandBuffer, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

static void renderEndEncoding(id self, SEL _cmd) {
    NSArray *resolves = objc_getAssociatedObject(self, kPendingResolves);
    id<MTLCommandBuffer> commandBuffer = objc_getAssociatedObject(self, kResolveCommandBuffer);
    origRenderEndEncoding(self, _cmd);
    if (!resolves) return;
    objc_setAssociatedObject(self, kPendingResolves, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kResolveCommandBuffer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    if (definesMethod(encoder, @selector(endEncoding)))
        origRenderEndEncoding = (EndEncodingIMP)swizzle(encoder, @selector(endEncoding), (IMP)renderEndEncoding);
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
        installRenderPassHooks();
        installCopyFix();
        if (!disabled("AMD_EXACT_TRILINEAR")) installTrilinearFix(name);
        if (verbose()) fprintf(stderr, "[bronzecompat] view fix %s, sRGB mipmaps %s, trilinear %s, sRGB resolve %s, copy pitch %s\n", origViewInit ? "on" : "off",
                               origGenerateMipmaps ? "on" : "off", origSamplerInit ? "on" : "off", origRenderEndEncoding ? "on" : "off",
                               origCopyToBuffer ? "on" : "off");
        return;
    }
}
