// s82-function-cache-reuse: MetalOld's function cache must hold no unrequested reflection; AMD's crashed
// MTLCompilerService. Fix: MetalOldCompat item 76. Checks: none cached; cached varyings exact. Argument: GPU name.
// Info.plist: org.oclp.legacymetal.s82
#import "repro.h"

static NSString *const kSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 position [[position]]; float4 a; float2 b; float c; float3 d; };\n"
    "vertex V s82_vertex(uint vid [[vertex_id]]) {\n"
    "    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);\n"
    "    V v; v.position = float4(p, 0, 1);\n"
    "    v.a = float4(0.25, 0.5, 0.75, 1.0); v.b = float2(0.125, 0.375); v.c = 0.625; v.d = float3(0.0625, 0.875, 0.3125);\n"
    "    return v;\n"
    "}\n"
    "fragment float4 s82_fragment(V v [[stage_in]]) { return float4(v.a.x + v.b.x, v.a.y * v.b.y * 4.0, v.c * v.d.y, v.d.x + v.d.z); }\n";

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> dev, NSError **err) {
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:err];
    if (!lib) return nil;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"s82_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"s82_fragment"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    return [dev newRenderPipelineStateWithDescriptor:d error:err];
}

// Makes the pipeline, draws a full-screen triangle and checks every pixel; NULL if right, else what went wrong.
static const char *drawAndCheck(id<MTLDevice> dev, int copies) {
    static char why[512];
    NSError *err = nil;
    id<MTLRenderPipelineState> ps = nil;
    for (int i = 0; i < copies; i++)
        if (!(ps = pipeline(dev, &err))) {
            snprintf(why, sizeof why, "pipeline %d: %s", i + 1, err.localizedDescription.UTF8String ?: "nil");
            return why;
        }
    enum { W = 16 };
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:W mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> out = [dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1)
               toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [be endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { snprintf(why, sizeof why, "command buffer: %s", cb.error.localizedDescription.UTF8String); return why; }
    const float want[4] = {0.25f + 0.125f, 0.5f * 0.375f * 4.0f, 0.625f * 0.875f, 0.0625f + 0.3125f};
    const uint8_t *px = out.contents;
    int bad = 0, first = -1;
    for (int i = 0; i < W * W; i++)
        for (int c = 0; c < 4; c++)
            if (fabsf(px[i * 4 + c] / 255.0f - want[c]) > 1.5f / 255.0f) { bad++; if (first < 0) first = i; break; }
    if (!bad) return NULL;
    snprintf(why, sizeof why, "%d of %d pixels wrong, first (%d, %d) = %d %d %d %d, want %.0f %.0f %.0f %.0f (varyings mixed up)", bad, W * W,
             first % W, first / W, px[first * 4], px[first * 4 + 1], px[first * 4 + 2], px[first * 4 + 3], want[0] * 255, want[1] * 255,
             want[2] * 255, want[3] * 255);
    return why;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bug = "s82-function-cache-reuse";
        // the function cache is what this checks: runners that turn it off (MTL_SHADER_CACHE_SIZE=0) don't apply here
        if (getenv("MTL_SHADER_CACHE_SIZE")) { unsetenv("MTL_SHADER_CACHE_SIZE"); execv(argv[0], argv); }
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        char dir[PATH_MAX];
        if (!bundle || !confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof dir)) return SKIP(bug, "built without its bundle id (build.sh embeds it)");
        NSString *root = [@(dir) stringByAppendingPathComponent:bundle];
        const char *child = reproChildMode(argc, argv);
        id<MTLDevice> dev = argc > 1 && strcmp(argv[1], "--child") ? reproDevice(argc, argv, "")
                                                                  : (reproDevice(argc, argv, "AMD") ?: MTLCreateSystemDefaultDevice());
        if (!dev) return SKIP(bug, "no such GPU");
        if (child) return drawAndCheck(dev, 1) ? 1 : 0;
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        const char *name = dev.name.UTF8String;
        const char *why = drawAndCheck(dev, 2);
        if (why) return FAIL(bug, "%s: the same pipeline made twice: %s", name, why);
        // every GPU's functions.data: a CompilerOutputReflectionBlock starts with u32 0xEF13C710, u32 8
        static const uint8_t magic[8] = {0x10, 0xc7, 0x13, 0xef, 0x08, 0, 0, 0};
        int blocks = 0;
        NSString *metal = [root stringByAppendingPathComponent:@"com.apple.metal"];
        for (NSString *gpu in [NSFileManager.defaultManager contentsOfDirectoryAtPath:metal error:nil]) {
            NSData *data = [NSData dataWithContentsOfFile:[[metal stringByAppendingPathComponent:gpu] stringByAppendingPathComponent:@"functions.data"]];
            for (NSUInteger i = 0; i + 8 <= data.length; i += 4) if (!memcmp((const uint8_t *)data.bytes + i, magic, 8)) blocks++;
        }
        if (blocks)
            return FAIL(bug, "%s: %d reflection block(s) in the function cache though no pipeline asked for reflection: cached under keys "
                        "MetalOld never computed, they replace other entries", name, blocks);
        int status = reproRunChild(argc, argv, "draw");
        if (status) return FAIL(bug, "%s: the same pipeline in a new process, from the function cache: %s", name,
                                status == 1 ? "wrong pixels or a compiler failure" : reproChildStatus(status));
        return PASS(bug, "%s: the same pipeline made twice, then in a new process from the function cache, draws right; no "
                    "unrequested reflection cached", name);
    }
}
