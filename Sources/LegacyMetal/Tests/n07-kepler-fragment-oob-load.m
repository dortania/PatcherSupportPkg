// n07-kepler-fragment-oob-load: fragment helper lanes loading at a wrapped index must not fault; Kepler's driver then
// failed a later command buffer (ANGLE's PBO uploads lost Chrome's WebGL). Fix: GeForceAIRCompat
// NVAIR_FRAGMENT_LOAD_GUARD. Checks: four such draws, each followed by a command buffer; all complete and the texels
// are right. Argument: GPU name (default: NVIDIA).
#import "repro.h"

static NSString *const src = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct B2TParams { uint bufferStartOffset; uint pixelSize; uint bufferRowPitch; uint bufferDepthPitch; uint2 textureOffset; };\n"
    "vertex float4 vs(uint vid [[vertex_id]]) {\n"
    "    float4 o; o.xy = select(float2(-1.0f), float2(1.0f), bool2(vid & uint2(2, 1))); o.zw = float2(0.0, 1.0); return o; }\n"
    "fragment float4 unpack4444(float4 position [[position]], constant B2TParams &options [[buffer(0)]],\n"
    "                           const device uchar *buffer [[buffer(1)]]) {\n"
    "    uint2 p = uint2(position.xy) - options.textureOffset;\n"
    "    uint i = options.bufferStartOffset + p.y * options.bufferRowPitch + p.x * options.pixelSize;\n"
    "    ushort v = ushort(buffer[i]) | (ushort(buffer[i + 1]) << 8);\n"
    "    return float4((v >> 12) & 15, (v >> 8) & 15, (v >> 4) & 15, v & 15) / 15.0; }\n"
    "fragment float4 plain(float4 position [[position]]) { return float4(0.25, 0.5, 0.75, 1.0); }\n";

int main(int argc, char **argv) { @autoreleasepool {
    const char *bug = "n07-kepler-fragment-oob-load";
    id<MTLDevice> dev = reproDevice(argc, argv, "NVIDIA");
    if (!dev) return SKIP(bug, "no such GPU");
    const char *name = dev.name.UTF8String;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[reproUniqueComment() stringByAppendingString:src] options:nil error:&err];
    if (!lib) return FAIL(bug, "compile: %s", err.localizedDescription.UTF8String);
    id<MTLRenderPipelineState> pipes[2];
    for (int k = 0; k < 2; k++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:k ? @"plain" : @"unpack4444"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (!(pipes[k] = [dev newRenderPipelineStateWithDescriptor:pd error:&err])) return FAIL(bug, "%s: pipeline: %s", name, err.localizedDescription.UTF8String);
    }
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    enum { W = 13, H = 7, X = 3, Y = 5, Row = 28, Offset = 16 };
    id<MTLBuffer> pixels = [dev newBufferWithLength:Offset + Row * H + 64 options:MTLResourceStorageModeShared];
    uint8_t *s = pixels.contents;
    for (NSUInteger i = 0; i < pixels.length; i++) s[i] = (uint8_t)(i * 37 + 11);
    struct { uint32_t off, psize, row, depth, ox, oy; } params = {Offset, 2, Row, Row * H, X, Y};
    for (int pass = 0; pass < 4; pass++) {
        BOOL unpack = !(pass & 1);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:16 mipmapped:NO];
        td.storageMode = MTLStorageModeManaged;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;  // ANGLE's
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:pipes[unpack ? 0 : 1]];
        [re setFragmentBuffer:pixels offset:0 atIndex:1];
        [re setFragmentBytes:&params length:sizeof params atIndex:0];
        [re setViewport:(MTLViewport){X, Y, W, H, 0, 1}];
        [re setScissorRect:(MTLScissorRect){X, Y, W, H}];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be synchronizeResource:t];
        [be endEncoding];
        if (!reproRun(cb))
            return FAIL(bug, "%s: pass %d (%s) failed: %s", name, pass + 1, unpack ? "the unpack draw" : "a plain draw after it",
                        cb.error.localizedDescription.UTF8String);
        if (unpack) {  // the uploaded 4-4-4-4 texels
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    uint8_t got[4];
                    [t getBytes:got bytesPerRow:4 fromRegion:MTLRegionMake2D(X + x, Y + y, 1, 1) mipmapLevel:0];
                    unsigned v = s[Offset + y * Row + x * 2] | (s[Offset + y * Row + x * 2 + 1] << 8);
                    unsigned want[4] = {(v >> 12) & 15, (v >> 8) & 15, (v >> 4) & 15, v & 15};
                    for (int c = 0; c < 4; c++)
                        if (abs((int)got[c] - (int)(want[c] * 17)) > 1)
                            return FAIL(bug, "%s: texel (%d, %d) channel %d: %u, want %u", name, x, y, c, got[c], want[c] * 17);
                }
        }
    }
    return PASS(bug, "%s: a fragment load at a wrapped index (helper lanes) faults nothing, and the uploaded texels are right", name);
}}
